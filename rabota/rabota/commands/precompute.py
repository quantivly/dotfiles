"""The timer's entry point: sync → inbox plan → inbox apply auto → rank → census. Each step isolated.

``--dry-run`` here means "do not mutate anything outward," not "do not write local state." It
suppresses only the Linear-mutating ``auto`` step (``run_apply`` is called with
``dry_run=ctx.dry_run``, so it plans but does not apply). ``sync``, ``plan``, ``rank`` and
``census`` write only local files under the tenant's own state dir — ``sources/*.json``,
``sequence.json``/``.md``, ``census.json``, and ``precompute.log`` itself — and always do,
dry-run or not.

**DO-753 made ``run_sync``/``run_plan``/``run_rank``/``census.gather`` themselves read
``ctx.dry_run``** (their standalone CLI commands' own meaning: "nothing is written"), which is
exactly the opposite of what this module needs from them — the timer's own point is to keep local
state current, and ``--dry-run`` here is a promise about Linear, never about the timer's own
bookkeeping. ``_local_write_step`` runs a step with ``ctx.dry_run`` forced ``False`` for its
duration, so those four functions still write local state on a ``precompute --dry-run`` tick
exactly as before, while the ``auto`` step (still reading the REAL ``ctx.dry_run``) is the only one
whose behaviour actually changes.
"""
import json, time
from rabota import cli, emit, errors
from rabota.context import Context
from rabota.store import now

DRY_RUN_NOTE = ("--dry-run suppresses only the Linear-mutating 'auto' step; sync, plan, rank and "
                 "census always write local state (sources/*.json, sequence.json/.md, census.json, "
                 "precompute.log) whether or not --dry-run is set.")


def _local_write_step(fn):
    """Wrap a step so it always writes its own local state, regardless of the global --dry-run.

    See the module docstring: DO-753 gave ``run_sync``/``run_plan``/``run_rank``/``census.gather``
    their own ``ctx.dry_run`` reading, and precompute's contract for those four steps is the
    opposite of that reading. Flipping ``ctx.dry_run`` for the duration of one step (restored in
    ``finally``, even if the step raises) is cheaper than building a second ``Context`` (which would
    open a second sqlite connection to the same store) and touches no other step.
    """
    def wrapped(ctx):
        saved, ctx.dry_run = ctx.dry_run, False
        try:
            return fn(ctx)
        finally:
            ctx.dry_run = saved
    return wrapped


def _default_steps():
    from rabota.commands.sync import FETCHED_SOURCES, run_sync
    from rabota.commands.inbox import run_plan, run_apply
    from rabota.commands.rank import run_rank
    from rabota.census import gather
    # `FETCHED_SOURCES`, not a restated tuple (DO-746): a literal ("linear", "github") here kept
    # Fireflies out of every precompute tick even after it joined FETCHED_SOURCES, because this
    # step never reads that constant -- the one place that decides what the CLI itself fetches
    # would then disagree with the one place that actually calls it, silently.
    return {"sync": _local_write_step(lambda ctx: run_sync(ctx, [s for s in FETCHED_SOURCES if s in ctx.tenant.sources])),
            "plan": _local_write_step(lambda ctx: run_plan(ctx)),
            "auto": lambda ctx: run_apply(ctx, tier="auto", batch=None, confirmed=False, dry_run=ctx.dry_run),
            "rank": _local_write_step(lambda ctx: run_rank(ctx)),
            "census": _local_write_step(lambda ctx: gather(ctx, sample_seconds=2.0, include_worktrees=False))}


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
