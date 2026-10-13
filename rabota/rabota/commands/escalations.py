"""``rabota escalations [--open]``: list the tenant's escalations (DO-815).

Until this command, ``close`` was the only reader of open escalations, so a question raised by a
lane reached @zvi only if he happened to be looking at herdr when its notification fired. This is
the listing the rabota skill's ``/rabota status`` promises, and ``brief``'s "Needs you" section and
terminal line are built from the same rows and the same ``line`` below.

It is a pure reader: it never notifies. ``escalate`` notifies once, at creation, and a reader that
also did would notify again on every call — which is exactly what "once per escalation" rules out.
JSON is the stored row with ``options`` decoded; ``--text`` is one line per escalation.
"""
from rabota import cli
from rabota.context import Context


def one_line(text) -> str:
    """Free text collapsed onto one line, so a pasted multi-line question cannot break a list."""
    return " ".join(str(text or "").split())


def line(e: dict) -> str:
    """``ESC-<id> [<kind>] <subject> · since <date>: <question> — options: a | b`` (or ``— answered: x``)."""
    kind = f" [{e['kind']}]" if e.get("kind") else ""
    subject = f" {one_line(e['subject'])} ·" if e.get("subject") else ""
    head = f"ESC-{e['id']}{kind}{subject} since {(e.get('first_seen') or '')[:10]}: {one_line(e['question'])}"
    if e.get("resolved_at"):
        return f"{head} — answered: {e['disposition']}"
    options = " | ".join(one_line(o) for o in e.get("options") or [])
    return f"{head} — options: {options}" if options else head


def run_escalations(ctx: Context, open_only: bool = False, text: bool = False):
    rows = ctx.store.escalations(ctx.tenant.name, open_only=open_only)
    if text:
        return [line(e) for e in rows] or [f"no {'open ' if open_only else ''}escalations"]
    return {"escalations": rows}


def _build(sub):
    p = sub.add_parser("escalations", help="list escalations (read-only; never notifies)")
    p.add_argument("--open", action="store_true", help="only the unresolved ones")


cli.register("escalations", _build,
             lambda ns: run_escalations(Context.from_namespace(ns), open_only=ns.open, text=ns.text))
