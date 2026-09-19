"""``rabota db import-v1``: bring a v1 ``escalations.jsonl`` into the v2 store.

An open v1 row becomes a new escalation; a later row sharing an earlier row's ``firstSeen`` and
carrying a ``disposition`` resolves it. ``kind`` is carried through when the v1 row has one and
defaults to ``"finding"`` (§3.1's own default) when it does not — v1 rows never had a ``kind``
column, so most real rows lack it; dropping it instead of defaulting it would be silent data loss
(design §4.2 requires ``kind`` in the field set). ``kind`` is only ever set from the row that
*creates* the escalation; a later resolving row's own kind (if any) is not consulted, matching
``store.add_escalation``'s "never back-filled" rule.

Counters, defined precisely because they are not disjoint: ``imported`` counts every row that
creates a NEW escalation (one per distinct ``firstSeen`` never seen before); ``resolved`` counts
every row that carries a truthy ``disposition`` and lands an ``answer_escalation`` call — including
a row that both creates an escalation AND carries its own disposition, which increments both
counters for that one row. Real v1 data does exactly this (measured: 3 imported, 7 resolved, because
5 of 7 rows are single-row question+answer pairs with an immediate disposition), so a stricter
"disjoint" definition would not match what is on disk. Offset timestamps (``+03:00``, the shape
every real ``firstSeen`` uses) are stored as-is; nothing on this path parses or normalises them.
"""
import json
from pathlib import Path

from rabota import cli
from rabota.context import Context


def run_import_v1(ctx: Context, jsonl: Path) -> dict:
    by_first_seen, imported, resolved = {}, 0, 0
    for line in Path(jsonl).read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        fs = row.get("firstSeen") or row.get("ts")
        if fs in by_first_seen and row.get("disposition"):
            ctx.store.answer_escalation(by_first_seen[fs], row["disposition"], row.get("resolution"))
            resolved += 1
        elif fs not in by_first_seen:
            by_first_seen[fs] = ctx.store.add_escalation(
                ctx.tenant.name, row.get("question", ""), row.get("evidence", ""), row.get("options", []),
                first_seen=fs, kind=row.get("kind") or "finding")
            imported += 1
            if row.get("disposition"):
                ctx.store.answer_escalation(by_first_seen[fs], row["disposition"], row.get("resolution"))
                resolved += 1
    return {"imported": imported, "resolved": resolved}


def _build(sub):
    p = sub.add_parser("db", help="store maintenance")
    s = p.add_subparsers(dest="db_command", required=True)
    i = s.add_parser("import-v1")
    i.add_argument("--jsonl", required=True)


def _run(ns):
    ctx = Context.from_namespace(ns)
    if ns.db_command == "import-v1":
        return run_import_v1(ctx, Path(ns.jsonl))


cli.register("db", _build, _run)
