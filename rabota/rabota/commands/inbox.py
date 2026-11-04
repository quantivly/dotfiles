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
    # Staleness is a question about instants, not calendar dates: use the real clock, never
    # ctx.today (b6 — combining ctx.today's date with the UTC clock's time-of-day put "now" up
    # to 24h off whenever the two disagreed about what day it is).
    now_dt = datetime.now(timezone.utc)
    fetched_at = lin.get("fetched_at")
    try:
        fetched = snapshots.parse_fetched_at(fetched_at)
    except (TypeError, ValueError) as e:
        raise errors.Refused(f"sources/linear.json has an unusable fetched_at ({fetched_at!r}): {e}")
    age = (now_dt - fetched).total_seconds()
    if age > MAX_AGE_S and not allow_stale:
        raise errors.Refused(f"sources/linear.json is {int(age // 3600)} h old; run `rabota sync` or pass --allow-stale")
    return lin


def _compute_plan(ctx: Context, allow_stale: bool = False) -> dict:
    lin = _fresh_linear(ctx, allow_stale)
    return buckets.classify(lin, snapshots.read(ctx.state_dir, "github"), ctx.tenant, ctx.today)


def run_plan(ctx: Context, allow_stale: bool = False) -> dict:
    plan = _compute_plan(ctx, allow_stale)
    emit.write_file(_plan_path(ctx), json.dumps(plan, indent=1), dry_run=ctx.dry_run)
    emit.write_file(_summary_path(ctx), buckets.summary_line(plan, None) + "\n", dry_run=ctx.dry_run)
    out = {"path": str(_plan_path(ctx)), "unread_total": plan["unread_total"], "totals": plan["totals"],
           "batches": {k: len(v["issues"]) for k, v in plan["batches"].items()}}
    if ctx.dry_run:
        out["dry_run"] = "nothing written (inbox-plan.json, inbox-summary.txt)"
    return out


def run_apply(ctx: Context, tier: str, batch: str | None, confirmed: bool, client=None, dry_run: bool = False) -> dict:
    # Not `if missing: run_plan(ctx)` then re-read the file: with `ctx.dry_run` set, `run_plan`
    # (DO-753) no longer writes `inbox-plan.json` at all, so a plan computed but not yet persisted
    # would otherwise leave this reading a file that was never created. Computing the plan directly
    # here works whether or not a plan was ever written, dry run or not.
    plan = json.loads(_plan_path(ctx).read_text()) if _plan_path(ctx).exists() else _compute_plan(ctx)
    if tier == "auto":
        if client is None and not dry_run: client = LinearClient.from_context(ctx)
        rep = apply.apply_auto(plan, client, ctx.store, ctx.tenant, dry_run=dry_run)
        # DO-877: the answers Sol recorded ride the same tick, after the auto tier, with the same client.
        rep["answers"] = apply.apply_answers(plan, client, ctx.store, ctx.tenant, dry_run=dry_run)
        emit.write_file(_summary_path(ctx), buckets.summary_line(plan, rep) + "\n", dry_run=dry_run)
        return rep
    if tier == "propose":
        if batch == "due_policy":
            if confirmed is not True:
                raise errors.Refused("due_policy needs --confirmed after the user's typed OK")
            if client is None and not dry_run: client = LinearClient.from_context(ctx)
            return apply.apply_due_policy(plan, client, ctx.store, ctx.tenant, confirmed=confirmed, dry_run=dry_run)
        if batch == "stale_backlog":
            ids = [i["identifier"] for i in plan["batches"]["stale_backlog"]["issues"]]
            raise errors.Refused("stale_backlog: cancel is not automated in v2.0; identifiers: " + " ".join(ids))
        raise errors.Usage("--batch must be due_policy or stale_backlog")
    raise errors.Usage("--tier must be auto or propose")


def run_answer(ctx: Context, batch: str | None, bucket: str | None, ids: list[str], confirmed: bool,
               dismiss: bool) -> dict:
    """DO-877: record an answer from Sol for the tick to apply. It writes the ``inbox_answers`` row
    and nothing else: no Linear client is built (the fleet agent that runs this holds no rabota
    secret), no file is written, and the plan is only READ -- to name the issues a ``due_policy``
    confirmation covers, so the tick clears exactly those and nothing that joined the batch later.
    A repeat of a still-pending answer is the same row, reported ``duplicate``."""
    if batch == apply.ANSWER_DUE_POLICY:
        if bucket or ids or dismiss:
            raise errors.Usage("--batch due_policy takes --confirmed and nothing else")
        if confirmed is not True:
            raise errors.Refused("due_policy is a propose-tier batch; pass --confirmed after the user's OK")
        if not _plan_path(ctx).exists():
            raise errors.Refused("no inbox-plan.json to confirm against; the precompute tick writes it")
        plan = json.loads(_plan_path(ctx).read_text())
        covered = [i["identifier"] for i in plan["batches"]["due_policy"]["issues"]]
        if not covered:
            raise errors.Refused("the due_policy batch is empty; nothing to confirm")
        kind = apply.ANSWER_DUE_POLICY
    elif bucket == apply.ANSWER_PROJECT_PROMPT:
        if batch or confirmed:
            raise errors.Usage("--bucket project_prompt takes --ids and --dismiss and nothing else")
        if not dismiss:
            raise errors.Usage("--bucket project_prompt needs --dismiss; dismissal is its one answer")
        if not ids:
            raise errors.Usage("--ids must name at least one notification id")
        covered, kind = list(ids), apply.ANSWER_PROJECT_PROMPT
    else:
        raise errors.Usage("pass --batch due_policy --confirmed, or --bucket project_prompt --ids <id,...> --dismiss")
    if ctx.dry_run:
        return {"kind": kind, "ids": covered, "dry_run": "nothing written (inbox_answers row)"}
    row = ctx.store.record_inbox_answer(ctx.tenant.name, kind, covered)
    return {"id": row["id"], "kind": row["kind"], "ids": row["ids"], "recorded_at": row["recorded_at"],
            "duplicate": row["duplicate"]}


def split_ids(text: str | None) -> list[str]:
    """``--ids a,b, c`` → ``["a", "b", "c"]``; an empty flag is no ids."""
    return [i.strip() for i in (text or "").split(",") if i.strip()]


def run_rollback(ctx: Context, batch_id: str, client=None, dry_run: bool = False) -> dict:
    # No client is ever built on a dry path -- mirroring `run_apply` above -- so a rollback that
    # would mutate Linear (DO-753's "most urgent" finding) cannot reach the network at all, rather
    # than relying solely on `LinearClient.mutate`'s own dry-run guard as the only backstop.
    client = client or (None if dry_run else LinearClient.from_context(ctx))
    return apply.rollback(batch_id, client, ctx.store, dry_run=dry_run)


def _build(sub):
    p = sub.add_parser("inbox", help="Linear inbox triage")
    s = p.add_subparsers(dest="inbox_command", required=True)
    pl = s.add_parser("plan"); pl.add_argument("--allow-stale", action="store_true")
    ap = s.add_parser("apply"); ap.add_argument("--tier", required=True, choices=["auto", "propose"])
    ap.add_argument("--batch", choices=["due_policy", "stale_backlog"]); ap.add_argument("--confirmed", action="store_true")
    rb = s.add_parser("rollback"); rb.add_argument("batch_id")
    s.add_parser("summary")
    an = s.add_parser("answer", help="record an answer from Sol for the tick to apply (writes the row only)")
    an.add_argument("--batch", choices=[apply.ANSWER_DUE_POLICY]); an.add_argument("--confirmed", action="store_true")
    an.add_argument("--bucket", choices=[apply.ANSWER_PROJECT_PROMPT]); an.add_argument("--ids", help="comma-separated notification ids")
    an.add_argument("--dismiss", action="store_true")


def _run(ns):
    ctx = Context.from_namespace(ns)
    if ns.inbox_command == "plan": return run_plan(ctx, ns.allow_stale)
    if ns.inbox_command == "apply": return run_apply(ctx, ns.tier, ns.batch, ns.confirmed, dry_run=ns.dry_run)
    if ns.inbox_command == "rollback": return run_rollback(ctx, ns.batch_id, dry_run=ns.dry_run)
    if ns.inbox_command == "answer":
        return run_answer(ctx, ns.batch, ns.bucket, split_ids(ns.ids), ns.confirmed, ns.dismiss)
    if ns.inbox_command == "summary":
        p = _summary_path(ctx); return [p.read_text().strip()] if p.exists() else ["inbox: no plan yet"]


cli.register("inbox", _build, _run)
