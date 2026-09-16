"""``rabota doctor``: install link, config parse, store schema, pre-compute timer."""
from pathlib import Path

from rabota import cli, emit, errors
from rabota.context import Context

EXPECTED_LINK = Path.home() / ".dotfiles" / "scripts" / "rabota"


def run_doctor(ctx: Context) -> dict:
    """Return the doctor report; ``ok`` is false whenever ``problems`` is non-empty."""
    problems = []
    link = ctx.runner.run(["readlink", "-f", str(Path.home() / ".local/bin/rabota")])
    link_ok = link.ok and link.out.strip() == str(EXPECTED_LINK)
    if not link_ok:
        problems.append("~/.local/bin/rabota is not linked to ~/.dotfiles/scripts/rabota (run dotfiles install)")
    timer = ctx.runner.run(["systemctl", "--user", "is-enabled", "rabota-precompute.timer"])
    timer_state = timer.out.strip() if timer.ok else "missing"
    if timer_state != "enabled":
        problems.append(f"rabota-precompute.timer is {timer_state} (WS5 installs it)")
    schema = ctx.store.schema_version()
    return {"tenant": ctx.tenant.name, "state_dir": str(ctx.state_dir), "config_ok": True,
            "db_schema": schema, "links": {"rabota": link_ok}, "timer": {"state": timer_state},
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
