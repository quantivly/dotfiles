"""``rabota census``: one fleet view — sessions by owner, lane units, seats, worktrees."""
from rabota import census, cli
from rabota.context import Context


def _build(sub):
    p = sub.add_parser("census", help="one fleet view: sessions by owner, units, seats, worktrees")
    p.add_argument("--sample-seconds", type=float, default=3.0, help="CPU sampling window (default 3)")
    p.add_argument("--no-worktrees", action="store_true", help="skip the worktree scan (no wt-gc call)")


def text_lines(c: dict) -> list[str]:
    k, m = c["counts"], c["machine"]
    lines = [f"sessions {k['sessions']} (user {k['user']} · sol {k['sol']} · rabota {k['rabota']}) · "
             f"units active {k['units_active']} · load {m['load1']}/{m['ncpu']} · swap {m['swap_used_pct']}%"]
    lines += [f"  seat {s['name']} {s['tier']} 5h {'unknown' if s['five_h_pct'] is None else str(s['five_h_pct']) + '%'}"
              f"{' STALE' if s['stale'] else ''}" for s in c["seats"]]
    if c["unavailable"]:
        lines.append("  unavailable: " + ", ".join(c["unavailable"]))
    return lines


def _run(ns, **ctx_kw):
    ctx = Context.from_namespace(ns, **ctx_kw)
    c = census.gather(ctx, sample_seconds=ns.sample_seconds, include_worktrees=not ns.no_worktrees)
    return text_lines(c) if ns.text else c


cli.register("census", _build, _run)
