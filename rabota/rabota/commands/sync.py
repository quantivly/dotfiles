"""``rabota sync``: fetch Linear and GitHub into ``sources/*.json`` and record each outcome in ``source_syncs``."""
import os

from rabota import cli, errors, secrets, snapshots
from rabota.context import Context
from rabota.sources.github import GhClient
from rabota.sources.linear import LinearClient

FETCHED_SOURCES = ("linear", "github")


def sync_linear(ctx: Context, lin) -> dict:
    """Assigned-open ∪ created-by-me-open (deduped by id) with relations, plus every non-archived notification."""
    dead = ctx.tenant.linear.dead_state_types
    viewer = lin.viewer()
    issues = {i["id"]: i for i in lin.assigned_open(dead)}
    for i in lin.created_open(viewer["id"], dead):
        issues.setdefault(i["id"], i)
    for iid, rel in lin.relations(list(issues)).items():
        if iid in issues:
            issues[iid].update(rel)
    notifications = lin.inbox_notifications()
    payload = {"ok": True, "error": None, "viewer": viewer, "issues": list(issues.values()),
               "notifications": notifications}
    snapshots.write(ctx.state_dir, "linear", payload)
    return {"issues": len(issues), "notifications": len(notifications)}


def sync_github(ctx: Context, gh) -> dict:
    """Review requests (individual vs team resolved), own open PRs, and recently merged PRs."""
    payload = {"ok": True, "error": None, "login": gh.login, "review_requests": gh.review_requests(),
               "own_prs": gh.own_prs(), "merged_recent": gh.merged_recent()}
    snapshots.write(ctx.state_dir, "github", payload)
    return {k: len(payload[k]) for k in ("review_requests", "own_prs", "merged_recent")}


def _sync_one(ctx: Context, source: str, lin, gh) -> dict:
    if source == "linear":
        return sync_linear(ctx, lin or LinearClient.from_context(ctx))
    if source == "github":
        return sync_github(ctx, gh or GhClient.from_context(ctx))
    raise errors.Usage(f"sync does not fetch {source!r}; use `rabota ingest`")


def run_sync(ctx: Context, sources: list[str], lin=None, gh=None) -> dict:
    """Sync each source in turn; the ones that succeed are written even when a later one fails.

    Returns ``{source: {"ok", "error", "path", "counts"}}`` and raises ``errors.Partial`` naming
    the failed sources after every source has been attempted and recorded.
    """
    report, failed = {}, []
    for source in sources:
        path = str(ctx.state_dir / "sources" / f"{source}.json")
        try:
            counts = _sync_one(ctx, source, lin, gh)
        except errors.Usage:
            raise
        except errors.RabotaError as e:
            # gh's stderr is folded into the error text and can echo the minted token (k2). The
            # store redacts again on its own; redacting here too keeps the terminal report
            # printable, so the caller gets `partial` naming the source instead of `secret_leak`.
            msg = secrets.redact(str(e), os.environ)
            ctx.store.record_sync(ctx.tenant.name, source, False, msg, "")
            report[source] = {"ok": False, "error": msg, "path": "", "counts": {}}
            failed.append(source)
            continue
        ctx.store.record_sync(ctx.tenant.name, source, True, None, path)
        report[source] = {"ok": True, "error": None, "path": path, "counts": counts}
    if failed:
        raise errors.Partial(f"sources failed: {', '.join(failed)}", failed=failed)
    return report


def _build(sub):
    p = sub.add_parser("sync", help="fetch Linear and GitHub into sources/*.json")
    p.add_argument("--source", default=",".join(FETCHED_SOURCES), help="comma list: linear,github")


def _run(ns):
    ctx = Context.from_namespace(ns)
    wanted = [s for s in ns.source.split(",") if s in ctx.tenant.sources and s in FETCHED_SOURCES]
    return run_sync(ctx, wanted)


cli.register("sync", _build, _run)
