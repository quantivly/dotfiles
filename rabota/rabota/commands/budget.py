"""``rabota budget``: how many new lanes the seat and the box allow; exit 3 when zero."""
import json
import os
from rabota import budget as budget_mod, cli, emit, errors, secrets
from rabota.context import Context


def run_budget(ctx: Context, machine: str, model: str, effort: str, est_minutes: int,
               seat: str | None = None, raise_on_zero: bool = False, dry_run: bool = False) -> dict:
    """Compute and write ``<state_dir>/budget.json``; with ``raise_on_zero`` a zero budget is ``Refused``.

    A seat-rule refusal happens BEFORE anything is measured or written, so ``budget.json`` may not
    exist afterwards. A zero-lanes refusal happens after the write and carries the budget on the
    exception (``e.budget``) so the CLI can print it without re-reading the file.

    ``dry_run`` is a caller-controlled parameter, NOT read from ``ctx.dry_run`` automatically
    (DO-753): ``lane recipe``'s own dry path (DO-743, ``commands/lane.py``) calls this same
    function to gate capacity and its docstring documents, deliberately, that the one write a dry
    lane recipe still makes IS this refresh of ``budget.json`` — that call site leaves this
    parameter at its default (``False``) and is unaffected. Only the standalone ``rabota budget``
    command passes ``dry_run=ctx.dry_run`` explicitly.
    """
    seat = budget_mod.seat_for(ctx.tenant, machine, override=seat)
    rate, rate_source = budget_mod.measured_rate(ctx.store, ctx.tenant.name, seat)
    running_minutes, running_detail = budget_mod.running_lanes_minutes(ctx.store, ctx.tenant.name, seat, rate)
    cred = budget_mod.credential_gate(ctx.runner, seat, model, effort, est_minutes,
                                      env=ctx.env, rate=rate, rate_source=rate_source,
                                      running_minutes=running_minutes, running_detail=running_detail)
    census_path = ctx.state_dir / "census.json"
    census = json.loads(census_path.read_text()) if census_path.exists() else None
    b = budget_mod.compute(census, cred, ctx.tenant.budget, ctx.tenant.budget.max_lanes_local, machine=machine)
    b["seat_pick"] = seat
    if not dry_run:
        ctx.state_dir.mkdir(parents=True, exist_ok=True)
        # Written through the same guard emit applies to stdout: a contract file is output too.
        text = secrets.assert_clean(json.dumps(b, indent=1, sort_keys=True) + "\n", os.environ)
        (ctx.state_dir / "budget.json").write_text(text)
    else:
        b["dry_run"] = "nothing written (budget.json)"
    if raise_on_zero and b["allowed_new_lanes"] == 0:
        e = errors.Refused("; ".join(f"{r['code']}: {r['detail']}" for r in b["reasons"]) or "no lane capacity")
        e.budget = b
        raise e
    return b


def _build(sub):
    p = sub.add_parser("budget", help="lanes the seat and the box allow; exit 3 when zero")
    p.add_argument("--machine", default="local", choices=["local", "dev"])
    p.add_argument("--seat", help="override the tenant's seat for this machine (still checked)")
    p.add_argument("--model", default=None, help="default: the tenant's lanes.default_model")
    p.add_argument("--effort", default=None, help="default: the tenant's lanes.default_effort")
    p.add_argument("--est-minutes", type=int, default=30)


def _run(ns, **ctx_kw):
    ctx = Context.from_namespace(ns, **ctx_kw)
    model = ns.model or ctx.tenant.lanes.default_model
    effort = ns.effort or ctx.tenant.lanes.default_effort
    try:
        b = run_budget(ctx, ns.machine, model, effort, ns.est_minutes, seat=ns.seat, raise_on_zero=True,
                       dry_run=ctx.dry_run)
    except errors.Refused as e:
        b = getattr(e, "budget", None)
        if b is not None:   # the budget was computed and written; show it, then the refusal
            emit.text_out([budget_mod.text_line(b)]) if ns.text else emit.json_out(b)
        raise
    return [budget_mod.text_line(b)] if ns.text else b


cli.register("budget", _build, _run)
