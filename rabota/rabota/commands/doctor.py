"""``rabota doctor``: install link, config parse, store schema, pre-compute timer, seat-cache coupling."""
import json
from pathlib import Path

from rabota import cli, emit, errors
from rabota.context import Context
from rabota.store import SCHEMA_VERSION

EXPECTED_LINK = Path.home() / ".dotfiles" / "scripts" / "rabota"


def seat_cache_age(ctx, max_age_s: int = 600) -> list[tuple[str, bool, str]]:
    """Per machine with a seat: is this box's usage cache for that seat fresh enough to gate on?

    A dev lane's credential dimension is answered HERE, from this machine's monitoring grant for
    the remote seat (the window is server-side, so any grant on the account reports it). If clauth
    stops polling, the gate goes unmeasured and dev lanes refuse even though dev is fine. That
    coupling is invisible from either machine, so it is asserted rather than assumed.

    ``[machines.<m>].profile`` only DECLARES which seat a machine's lane bills; nothing here reads
    the remote machine's own login, so a mismatch between the declared seat and the account
    actually signed in there bills the wrong window silently. Every row says NOT VERIFIED, naming
    that consequence, rather than implying a check this machine cannot make.
    """
    rows = []
    for name, m in sorted(ctx.tenant.machines.items()):
        if not m.profile:
            continue
        unverified = (f"remote login on {name!r} is NOT VERIFIED against declared seat {m.profile!r}; "
                     "a mismatch bills the wrong account silently")
        res = ctx.runner.run(["claude-pick", "--json", "--profile", m.profile])
        if not res.ok:
            rows.append((name, False, f"claude-pick exited {res.code} for {m.profile}; {unverified}"))
            continue
        try:
            age = json.loads(res.out)["usage"]["cache_age_s"]
            ok = age <= max_age_s
        except (json.JSONDecodeError, KeyError, TypeError):
            rows.append((name, False, f"claude-pick printed no usage.cache_age_s for {m.profile}; {unverified}"))
            continue
        rows.append((name, ok, f"declared seat {m.profile}: usage cache is {age}s old"
                     + ("" if ok else f"; lanes on {name} will refuse with credential:unmeasured "
                                      "until clauth polls it")
                     + f"; {unverified}"))
    return rows


def run_doctor(ctx: Context) -> dict:
    """Return the doctor report; ``ok`` is false whenever ``problems`` is non-empty."""
    problems = []
    link = ctx.runner.run(["readlink", "-f", str(Path.home() / ".local/bin/rabota")])
    link_ok = link.ok and link.out.strip() == str(EXPECTED_LINK)
    if not link_ok:
        problems.append("~/.local/bin/rabota is not linked to ~/.dotfiles/scripts/rabota (run dotfiles install)")
    timer = ctx.runner.run(["systemctl", "--user", "is-enabled", f"rabota-precompute@{ctx.tenant.name}.timer"])
    timer_state = timer.out.strip() if timer.ok else "missing"
    if timer_state != "enabled":
        problems.append(f"rabota-precompute@{ctx.tenant.name}.timer is {timer_state} (WS5 installs it)")
    try:
        schema = ctx.store.schema_version()
    except errors.Refused as e:      # a newer DB: the store refuses to open it (both numbers in the text)
        schema = None
        problems.append(str(e))
    else:
        if schema != SCHEMA_VERSION:
            problems.append(f"rabota.db schema is {schema}, this rabota expects {SCHEMA_VERSION} "
                            "(no migration is defined for it yet)")
    seat_rows = seat_cache_age(ctx)
    for name, ok, detail in seat_rows:
        if not ok:
            problems.append(f"seat cache for machine {name!r}: {detail}")
    return {"tenant": ctx.tenant.name, "state_dir": str(ctx.state_dir), "config_ok": True,
            "db_schema": schema, "links": {"rabota": link_ok}, "timer": {"state": timer_state},
            "seat_cache": [{"machine": n, "ok": ok, "detail": d} for n, ok, d in seat_rows],
            "ok": not problems, "problems": problems}


def _build(sub):
    sub.add_parser("doctor", help="check install, config, store, timer")


def _run(ns):
    ctx = Context.from_namespace(ns)
    report = run_doctor(ctx)
    if not report["ok"]:
        emit.json_out(report)   # the caller sees the report and then the refusal
        raise errors.Refused("; ".join(report["problems"]))
    return report


cli.register("doctor", _build, _run)
