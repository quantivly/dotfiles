"""Positive identity pins. An empty queue is indistinguishable from a 404 without them.

Every pin is a real request answered by the identity the tenant names: ``GET /user`` through
``GhClient`` (a token minted for ``gh_login``), the pin repo, Linear's ``viewer``. Nothing is
inferred from configuration, because that inference is the bug (F14). A source the tenant
does not list is skipped and counts as ok; a tenant without Linear is not a failure.
"""
from pathlib import Path

from rabota import cli, emit, errors
from rabota.context import Context
from rabota.sources.github import GhClient
from rabota.sources.linear import LinearClient


def _check_github(ctx: Context, gh, report: dict, failures: list[str]) -> None:
    """Pin the gh identity and the tenant's pin repo; a client that cannot be built is itself a failure."""
    t = ctx.tenant
    try:
        gh = gh or GhClient.from_context(ctx)
        login = gh.whoami()
    except errors.RabotaError as e:
        report["gh"] = {"ok": False, "error": str(e)}
        failures.append(f"gh identity check failed: {e}")
        return
    ok = login == t.gh_login
    report["gh"] = {"login": login, "expected": t.gh_login, "ok": ok}
    if not ok:
        failures.append(f"gh identity is {login!r}, expected {t.gh_login!r}")
    if not t.gh_pin_repo:
        return
    try:
        gh.api(f"repos/{t.gh_pin_repo}")
    except errors.RabotaError as e:
        report["gh_pin"] = {"repo": t.gh_pin_repo, "ok": False}
        failures.append(f"gh pin repo unreachable: {e}")
    else:
        report["gh_pin"] = {"repo": t.gh_pin_repo, "ok": True}


def _check_linear(ctx: Context, lin, report: dict, failures: list[str]) -> None:
    """Pin Linear's viewer to the tenant's ``linear_viewer``; skipped (and ok) when the tenant has no Linear."""
    t = ctx.tenant
    if "linear" not in t.sources:
        report["linear"] = {"ok": True, "skipped": True}
        return
    try:
        lin = lin or LinearClient.from_context(ctx)
        vid = lin.viewer()["id"]
    except errors.RabotaError as e:
        report["linear"] = {"ok": False, "skipped": False, "error": str(e)}
        failures.append(f"Linear: {e}")
        return
    ok = (t.linear_viewer is None) or (vid == t.linear_viewer)
    report["linear"] = {"viewer_id": vid, "expected": t.linear_viewer, "ok": ok, "skipped": False}
    if not ok:
        failures.append("Linear viewer id does not match the tenant pin")


def run_preflight(ctx: Context, gh=None, lin=None) -> dict:
    """Return the preflight report; ``ok`` is false whenever ``failures`` is non-empty."""
    failures: list[str] = []
    profile_dir = ctx.env.get("CLAUDE_CONFIG_DIR")
    report = {"gh": {}, "gh_pin": {}, "linear": {}, "ssh_agent": False, "herdr": bool(ctx.env.get("HERDR_ENV")),
              "profile": Path(profile_dir).name if profile_dir else None}
    _check_github(ctx, gh, report, failures)
    _check_linear(ctx, lin, report, failures)
    agent = ctx.runner.run(["ssh-add", "-l"], env=ctx.env)
    report["ssh_agent"] = agent.ok
    if not agent.ok:
        failures.append("ssh-agent has no keys (ssh-add -l failed)")
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
