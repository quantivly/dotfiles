"""``rabota inbox``: plan / apply / rollback / summary over the Linear inbox loop.

Both files this module writes go through ``emit.write_file`` — never a bare path method:
``tests/test_write_guard.py`` greps the whole package for every spelling of a direct file
write and fails on any hit outside ``emit.py`` that is not on its allow-list — three earlier
rounds of this epic (WS1 D1, WS4' the ``Path`` method, WS2 k2 twice) each patched a module
that had skipped ``secrets.assert_clean``. ``emit.write_file`` calls it and only then writes.
"""
import json
from datetime import datetime, timezone
from rabota import cli, emit, errors, snapshots
from rabota.context import Context
from rabota.inbox import apply, buckets
from rabota.sources.linear import LinearClient

MAX_AGE_S = 6 * 3600


def _plan_path(ctx): return ctx.state_dir / "inbox-plan.json"
def _summary_path(ctx): return ctx.state_dir / "inbox-summary.txt"


def _fresh_linear(ctx, allow_stale):
    lin = snapshots.read(ctx.state_dir, "linear")
    if not lin: raise errors.Refused("no sources/linear.json — run `rabota sync` first")
    now_dt = datetime.combine(ctx.today, datetime.now(timezone.utc).time(), tzinfo=timezone.utc)
    age = snapshots.age_seconds(ctx.state_dir, "linear", now_dt)
    if age is not None and age > MAX_AGE_S and not allow_stale:
        raise errors.Refused(f"sources/linear.json is {int(age // 3600)} h old; run `rabota sync` or pass --allow-stale")
    return lin


def run_plan(ctx: Context, allow_stale: bool = False) -> dict:
    lin = _fresh_linear(ctx, allow_stale)
    plan = buckets.classify(lin, snapshots.read(ctx.state_dir, "github"), ctx.tenant, ctx.today)
    emit.write_file(_plan_path(ctx), json.dumps(plan, indent=1))
    emit.write_file(_summary_path(ctx), buckets.summary_line(plan, None) + "\n")
    return {"path": str(_plan_path(ctx)), "unread_total": plan["unread_total"], "totals": plan["totals"],
            "batches": {k: len(v["issues"]) for k, v in plan["batches"].items()}}


def run_apply(ctx: Context, tier: str, batch: str | None, confirmed: bool, client=None, dry_run: bool = False) -> dict:
    if not _plan_path(ctx).exists(): run_plan(ctx)
    plan = json.loads(_plan_path(ctx).read_text())
    if tier == "auto":
        client = client or LinearClient.from_context(ctx)
        rep = apply.apply_auto(plan, client, ctx.store, ctx.tenant, dry_run=dry_run)
        emit.write_file(_summary_path(ctx), buckets.summary_line(plan, rep) + "\n")
        return rep
    if tier == "propose":
        if batch == "due_policy":
            if not confirmed:
                raise errors.Refused("due_policy needs --confirmed after the user's typed OK")
            client = client or LinearClient.from_context(ctx)
            return apply.apply_due_policy(plan, client, ctx.store, ctx.tenant, confirmed=True, dry_run=dry_run)
        if batch == "stale_backlog":
            ids = [i["identifier"] for i in plan["batches"]["stale_backlog"]["issues"]]
            raise errors.Refused("stale_backlog: cancel is not automated in v2.0; identifiers: " + " ".join(ids))
        raise errors.Usage("--batch must be due_policy or stale_backlog")
    raise errors.Usage("--tier must be auto or propose")


def run_rollback(ctx: Context, batch_id: str, client=None) -> dict:
    return apply.rollback(batch_id, client or LinearClient.from_context(ctx), ctx.store)


def _build(sub):
    p = sub.add_parser("inbox", help="Linear inbox triage")
    s = p.add_subparsers(dest="inbox_command", required=True)
    pl = s.add_parser("plan"); pl.add_argument("--allow-stale", action="store_true")
    ap = s.add_parser("apply"); ap.add_argument("--tier", required=True, choices=["auto", "propose"])
    ap.add_argument("--batch", choices=["due_policy", "stale_backlog"]); ap.add_argument("--confirmed", action="store_true")
    rb = s.add_parser("rollback"); rb.add_argument("batch_id")
    s.add_parser("summary")


def _run(ns):
    ctx = Context.from_namespace(ns)
    if ns.inbox_command == "plan": return run_plan(ctx, ns.allow_stale)
    if ns.inbox_command == "apply": return run_apply(ctx, ns.tier, ns.batch, ns.confirmed, dry_run=ns.dry_run)
    if ns.inbox_command == "rollback": return run_rollback(ctx, ns.batch_id)
    if ns.inbox_command == "summary":
        p = _summary_path(ctx); return [p.read_text().strip()] if p.exists() else ["inbox: no plan yet"]


cli.register("inbox", _build, _run)
