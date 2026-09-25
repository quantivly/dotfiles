"""Positive identity pins. An empty queue is indistinguishable from a 404 without them.

Every pin is a real request answered by the identity the tenant names: ``GET /user`` through
``GhClient`` (a token minted for ``gh_login``), the pin repo, Linear's ``viewer``. Nothing is
inferred from configuration, because that inference is the bug (F14). A source the tenant
does not list is skipped and counts as ok; a tenant without Linear is not a failure.
"""
import concurrent.futures
from pathlib import Path

from rabota import cli, emit, errors
from rabota.context import Context
from rabota.sources.github import GhClient
from rabota.sources.linear import LinearClient

GITHUB_WORKERS = 2   # whoami + the pin-repo read; independent, so they run side by side
TOP_LEVEL_WORKERS = 3   # the github half, the linear half, and ssh-add


def _check_github(ctx: Context, gh) -> tuple[dict, dict, list[str]]:
    """Pin the gh identity and the tenant's pin repo concurrently; return (gh, gh_pin, failures).

    Building the client (minting a token) must finish first since both calls need it; once it
    exists, ``whoami`` and the pin-repo read touch no shared mutable state (``GhClient.env`` is
    built once and never mutated) so they run in their own two-worker pool. A client that cannot
    be built is itself a failure and short-circuits both checks, exactly as before.
    """
    t = ctx.tenant
    failures: list[str] = []
    try:
        gh = gh or GhClient.from_context(ctx)
    except errors.RabotaError as e:
        failures.append(f"gh identity check failed: {e}")
        return {"ok": False, "error": str(e)}, {}, failures

    with concurrent.futures.ThreadPoolExecutor(max_workers=GITHUB_WORKERS) as ex:
        who_future = ex.submit(gh.whoami)
        pin_future = ex.submit(gh.api, f"repos/{t.gh_pin_repo}") if t.gh_pin_repo else None

        try:
            login = who_future.result()
        except errors.RabotaError as e:
            gh_report = {"ok": False, "error": str(e)}
            failures.append(f"gh identity check failed: {e}")
        else:
            ok = login == t.gh_login
            gh_report = {"login": login, "expected": t.gh_login, "ok": ok}
            if not ok:
                failures.append(f"gh identity is {login!r}, expected {t.gh_login!r}")

        if pin_future is None:
            return gh_report, {}, failures
        try:
            pin_future.result()
        except errors.RabotaError as e:
            pin_report = {"repo": t.gh_pin_repo, "ok": False}
            failures.append(f"gh pin repo unreachable: {e}")
        else:
            pin_report = {"repo": t.gh_pin_repo, "ok": True}
        return gh_report, pin_report, failures


def _check_linear(ctx: Context, lin) -> tuple[dict, list[str]]:
    """Pin Linear's viewer to the tenant's ``linear_viewer``; skipped (and ok) when the tenant has no Linear."""
    t = ctx.tenant
    if "linear" not in t.sources:
        return {"ok": True, "skipped": True}, []
    try:
        lin = lin or LinearClient.from_context(ctx)
        vid = lin.viewer()["id"]
    except errors.RabotaError as e:
        return {"ok": False, "skipped": False, "error": str(e)}, [f"Linear: {e}"]
    ok = (t.linear_viewer is None) or (vid == t.linear_viewer)
    report = {"viewer_id": vid, "expected": t.linear_viewer, "ok": ok, "skipped": False}
    return report, [] if ok else ["Linear viewer id does not match the tenant pin"]


def run_preflight(ctx: Context, gh=None, lin=None) -> dict:
    """Return the preflight report; ``ok`` is false whenever ``failures`` is non-empty.

    The github half, the linear half and the local ``ssh-add`` check touch no shared mutable
    state (``ctx.runner`` only reads its own ``env`` per call; each client owns its own state) so
    they run concurrently. Each half computes its own failures list and they are concatenated in
    a fixed order (github, then linear, then ssh) after every future resolves, so the report and
    ``failures`` never depend on which call answered first.
    """
    profile_dir = ctx.env.get("CLAUDE_CONFIG_DIR")
    report = {"herdr": bool(ctx.env.get("HERDR_ENV")),
              "profile": Path(profile_dir).name if profile_dir else None}

    with concurrent.futures.ThreadPoolExecutor(max_workers=TOP_LEVEL_WORKERS) as ex:
        gh_future = ex.submit(_check_github, ctx, gh)
        lin_future = ex.submit(_check_linear, ctx, lin)
        ssh_future = ex.submit(ctx.runner.run, ["ssh-add", "-l"], env=ctx.env)

        report["gh"], report["gh_pin"], gh_failures = gh_future.result()
        report["linear"], lin_failures = lin_future.result()
        agent = ssh_future.result()

    report["ssh_agent"] = agent.ok
    ssh_failures = [] if agent.ok else ["ssh-agent has no keys (ssh-add -l failed)"]

    failures = gh_failures + lin_failures + ssh_failures
    report["ok"], report["failures"] = not failures, failures
    return report


def run_command(ctx: Context, gh=None, lin=None) -> dict:
    """Record a ``runs`` row either way; on failure print the report, then refuse (exit 3)."""
    run_id = ctx.store.begin_run(ctx.tenant.name, "preflight")
    report = run_preflight(ctx, gh=gh, lin=lin)
    ctx.store.finish_run(run_id, report["ok"], "; ".join(report["failures"]))
    if not report["ok"]:
        emit.json_out(report)   # the caller sees the report and then the refusal
        raise errors.Refused("; ".join(report["failures"]))
    return report


def _build(sub):
    sub.add_parser("preflight", help="assert identity positively; exit 3 on any failure")


def _run(ns):
    return run_command(Context.from_namespace(ns))


cli.register("preflight", _build, _run)
