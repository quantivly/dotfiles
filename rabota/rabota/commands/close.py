"""``rabota close``: write ``YYYY-MM-DD/carry-forward.md`` and append the ``INDEX.md`` row.

Refuses (``errors.Refused``) while any lane is ``held`` — a held lane is something a human still
needs to look at, and closing the day would bury it. ``carry-forward.md`` and ``INDEX.md`` are
written through ``emit.write_file``/``emit.append_file`` rather than a direct file handle: both
files quote escalation questions and gate subjects verbatim, which is free text a user (or
evidence pasted from a leaked log) could have put anything in — exactly what the write guard
exists to check. ``store.record_gate`` stores a gate's *label* only, never who
answered it (Rule 0), so the "Gates answered" section below must never name a person either.
"""
from rabota import cli, emit, errors
from rabota.context import Context


def _index_cell(note: str) -> str:
    """Collapse a free-text ``--note`` onto one line for the INDEX.md table cell.

    Newlines (bare or ``\\r\\n``) become spaces and ``|`` is replaced outright — not
    backslash-escaped — because the row is read back by counting ``|`` characters, and an escaped
    pipe is still a pipe. ``carry-forward.md`` keeps the note's original text; only this cell is
    constrained.
    """
    note = note.replace("\r\n", " ").replace("\r", " ").replace("\n", " ")
    return note.replace("|", "/")


def run_close(ctx: Context, notes: list[str] | None = None) -> dict:
    held = ctx.store.list_lanes(ctx.tenant.name, status="held")
    if held:
        raise errors.Refused("lanes held: " + ", ".join(f"{l['id']} ({l['held_reason']})" for l in held))
    day = ctx.state_dir / ctx.today.isoformat()
    day.mkdir(parents=True, exist_ok=True)
    running = ctx.store.list_lanes(ctx.tenant.name, status="running")
    open_esc = ctx.store.open_escalations(ctx.tenant.name)
    corrections = [e for e in open_esc if e.get("kind") == "correction"]
    gates = ctx.store.gates(ctx.tenant.name)

    lines = ["# carry-forward", "",
             "This is a delta; the substance is on disk. Nothing below is load-bearing without its path.",
             "", "## Read first"]
    lines += [f"- {day / n}" for n in ("brief.md", "sequence.md")]
    lines += [f"- {ctx.state_dir / 'inbox-plan.json'}"]
    lines += ["", "## Running lanes"]
    lines += [f"- {l['id']} — brief {l['brief']} — out {l['out_dir']} — {l['machine']}" for l in running] or ["- none"]
    lines += ["", "## Awaiting the user"]
    lines += [f"- ESC-{e['id']} (since {e['first_seen'][:10]}): {e['question']}" for e in open_esc] or ["- nothing"]
    lines += ["", "## Gates answered"]
    lines += [f"- {g['subject']}: the gate was answered: {g['label']}" for g in gates] or ["- none"]
    lines += ["", "## Deliberately not done"]
    lines += [f"- {n}" for n in (notes or [])] or ["- nothing recorded"]
    lines += ["", "## Corrections carried forward"]
    lines += [f"- ESC-{e['id']} (since {e['first_seen'][:10]}): {e['question']}" for e in corrections] or ["- none"]

    cf = day / "carry-forward.md"
    emit.write_file(cf, "\n".join(lines) + "\n")

    index = ctx.state_dir / "INDEX.md"
    if not index.exists():
        emit.write_file(index, "| Date | Mode | Items | Lanes running | Open escalations | Notes |\n|---|---|---|---|---|---|\n")
    notes_cell = "; ".join(_index_cell(n) for n in (notes or []))
    row = f"| {ctx.today.isoformat()} | close | - | {len(running)} | {len(open_esc)} | {notes_cell} |"
    emit.append_file(index, row + "\n")
    return {"carry_forward": str(cf), "index_row": row}


def _build(sub):
    p = sub.add_parser("close", help="write carry-forward.md and the INDEX row")
    p.add_argument("--note", action="append", default=[], help="deliberately-not-done line; repeatable")


cli.register("close", _build, lambda ns: run_close(Context.from_namespace(ns), ns.note))
