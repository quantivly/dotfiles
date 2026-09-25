"""The timer's entry point: sync → inbox plan → inbox apply auto → rank → census. Each step isolated.

``--dry-run`` here means "do not mutate anything outward," not "do not write local state." It
suppresses only the Linear-mutating ``auto`` step (``run_apply`` is called with
``dry_run=ctx.dry_run``, so it plans but does not apply). ``sync``, ``plan``, ``rank`` and
``census`` write only local files under the tenant's own state dir — ``sources/*.json``,
``sequence.json``/``.md``, ``census.json``, and ``precompute.log`` itself — and always do,
dry-run or not: ``run_sync``, ``run_plan``, ``run_rank`` and ``census.gather`` take no
``dry_run`` parameter at all. Making ``--dry-run`` suppress those writes too would be a
CLI-wide semantics change affecting every subcommand, not a ``precompute``-local decision.
"""
import json, time
from rabota import cli, emit, errors
from rabota.context import Context
from rabota.store import now

DRY_RUN_NOTE = ("--dry-run suppresses only the Linear-mutating 'auto' step; sync, plan, rank and "
                 "census always write local state (sources/*.json, sequence.json/.md, census.json, "
                 "precompute.log) whether or not --dry-run is set.")


def _default_steps():
    from rabota.commands.sync import FETCHED_SOURCES, run_sync
    from rabota.commands.inbox import run_plan, run_apply
    from rabota.commands.rank import run_rank
    from rabota.census import gather
    # `FETCHED_SOURCES`, not a restated tuple (DO-746): a literal ("linear", "github") here kept
    # Fireflies out of every precompute tick even after it joined FETCHED_SOURCES, because this
    # step never reads that constant -- the one place that decides what the CLI itself fetches
    # would then disagree with the one place that actually calls it, silently.
    return {"sync": lambda ctx: run_sync(ctx, [s for s in FETCHED_SOURCES if s in ctx.tenant.sources]),
            "plan": lambda ctx: run_plan(ctx),
            "auto": lambda ctx: run_apply(ctx, tier="auto", batch=None, confirmed=False, dry_run=ctx.dry_run),
            "rank": lambda ctx: run_rank(ctx),
            "census": lambda ctx: gather(ctx, sample_seconds=2.0, include_worktrees=False)}


def run_precompute(ctx: Context, steps=None) -> dict:
    steps = steps or _default_steps()
    order = ["sync", "plan", "auto", "rank", "census"]
    if "linear" not in ctx.tenant.sources: order = ["sync", "rank", "census"]
    rep, failed = {"started_at": now(), "tenant": ctx.tenant.name, "steps": {}}, []
    for name in order:
        t0 = time.time()
        try:
            steps[name](ctx); rep["steps"][name] = {"ok": True, "error": None, "seconds": round(time.time() - t0, 1)}
        except Exception as e:
            err = str(e) if isinstance(e, errors.RabotaError) else f"{type(e).__name__}: {e}"
            rep["steps"][name] = {"ok": False, "error": err, "seconds": round(time.time() - t0, 1)}; failed.append(name)
    ctx.state_dir.mkdir(parents=True, exist_ok=True)
    emit.append_file(ctx.state_dir / "precompute.log", json.dumps(rep) + "\n")
    if failed: raise errors.Partial(f"precompute steps failed: {', '.join(failed)}", failed=failed)
    return rep


def _build(sub):
    sub.add_parser("precompute", help="timer entry: sync, inbox plan+auto, rank, census",
                    description="timer entry: sync, inbox plan+auto, rank, census", epilog=DRY_RUN_NOTE)


cli.register("precompute", _build, lambda ns: run_precompute(Context.from_namespace(ns)))
