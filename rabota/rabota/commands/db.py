"""``rabota db import-v1``: bring a v1 ``escalations.jsonl`` into the v2 store.

An open v1 row becomes a new escalation; a later row sharing an earlier row's ``firstSeen`` and
carrying a ``disposition`` resolves it. ``kind`` is carried through when the v1 row has one and
defaults to ``"finding"`` (§3.1's own default) when it does not — v1 rows never had a ``kind``
column, so most real rows lack it; dropping it instead of defaulting it would be silent data loss
(design §4.2 requires ``kind`` in the field set). ``kind`` is only ever set from the row that
*creates* the escalation; a later resolving row's own kind (if any) is not consulted, matching
``store.add_escalation``'s "never back-filled" rule.

Counters, defined precisely because they are not disjoint: ``imported`` counts every row that
creates a NEW escalation (one per distinct ``firstSeen`` never seen before, in this file or in an
earlier import); ``resolved`` counts every row that carries a truthy ``disposition`` and lands an
``answer_escalation`` call — including a row that both creates an escalation AND carries its own
disposition, which increments both counters for that one row. Real v1 data does exactly this
(measured: 3 imported, 7 resolved, because 5 of 7 rows are single-row question+answer pairs with an
immediate disposition), so a stricter "disjoint" definition would not match what is on disk. Offset
timestamps (``+03:00``, the shape every real ``firstSeen`` uses) are stored as-is; nothing on this
path parses or normalises them.

**Atomic and idempotent (F2, F5, F6)**, because WS5 5.4 points this at Zvi's real
``escalations.jsonl`` and a second run must be safe. ``firstSeen`` is the record's identity — it is
the only field a v1 row always carries in some form (``firstSeen`` or, failing that, ``ts``) and it
is what ties an open row to the later row that resolves it, so treating two rows with the same
``firstSeen`` as "the same record" and a rerun of the same file as a no-op both fall out of the one
rule. The whole file is parsed and validated (JSON shape, a ``firstSeen``/``ts``, a ``question`` key,
no row silently colliding with an open record under the same ``firstSeen``) before any row is
written; a bad row raises ``Usage`` (exit 2) naming the line, and nothing is imported — a
damaged file must be fixed and re-run as a whole, never "the rows before line N are already
in, importing the rest". Once validated, every write for the run lands in one
``store.transaction()``: not a row is committed unless all of them are. Re-running the same file
adds nothing new: ``firstSeen`` values already in the store are neither re-created (checked against
``store.escalations_by_first_seen``, not just this run's own rows) nor re-resolved (an already
``resolved_at`` row is left alone, matching the F4 "an escalation resolves once" rule) — so
``imported``/``resolved`` on a full rerun both come back 0.
"""
import json
from pathlib import Path

from rabota import cli, errors
from rabota.context import Context


def run_import_v1(ctx: Context, jsonl: Path) -> dict:
    path = Path(jsonl)
    try:
        text = path.read_text()
    except FileNotFoundError:
        # F9 (low): a missing --jsonl is bad input, not an internal error — Usage (exit 2),
        # not the generic "unexpected FileNotFoundError" (exit 5) it fell through to before.
        raise errors.Usage(f"no such file: {path}") from None
    rows, open_first_seens_in_file = [], set()
    for lineno, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as e:
            raise errors.Usage(f"{path}:{lineno}: invalid JSON: {e}") from None
        fs = row.get("firstSeen") or row.get("ts")
        if not fs:
            raise errors.Usage(f"{path}:{lineno}: row has neither firstSeen nor ts")
        if "question" not in row:
            raise errors.Usage(f"{path}:{lineno}: row has no question")
        if fs in open_first_seens_in_file and not row.get("disposition"):
            # F6/F5: a second OPEN row sharing an earlier open row's firstSeen used to be dropped,
            # uncounted, by the old elif chain — refuse instead of guessing which one was meant.
            raise errors.Usage(f"{path}:{lineno}: duplicate open firstSeen {fs!r}")
        if not row.get("disposition"):
            open_first_seens_in_file.add(fs)
        rows.append((fs, row))

    existing = ctx.store.escalations_by_first_seen(ctx.tenant.name)
    ids = {fs: e["id"] for fs, e in existing.items()}
    resolved_already = {fs for fs, e in existing.items() if e["resolved_at"]}
    imported = resolved = 0
    with ctx.store.transaction():
        for fs, row in rows:
            if fs not in ids:
                ids[fs] = ctx.store.add_escalation(
                    ctx.tenant.name, row.get("question", ""), row.get("evidence", ""), row.get("options", []),
                    first_seen=fs, kind=row.get("kind") or "finding")
                imported += 1
            if row.get("disposition") and fs not in resolved_already:
                ctx.store.answer_escalation(ids[fs], row["disposition"], row.get("resolution"))
                resolved_already.add(fs)
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
