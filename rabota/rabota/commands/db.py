"""``rabota db import-v1``: bring a v1 ``escalations.jsonl`` into the v2 store.

Every row becomes its own escalation, keyed by ``(firstSeen, question)`` (DO-694) — ``firstSeen``
alone is not unique: v1 logs several distinct questions under one shared ``firstSeen`` within a
session, and keying on ``firstSeen`` alone folded them into one record and dropped the others'
``question`` text entirely. The pair is stable across re-imports (it depends on content, never on a
row's position in the file) and still ties a two-row question-then-answer pair together when v1
writes one (the "revoke token?" fixture shape: an open row and a later row sharing both the same
``firstSeen`` and the same ``question`` resolve the same escalation). ``question`` is normalized
(see ``_normalize_question``) for the **key** only, so a resolving row that reproduces its open
row's question with a whitespace difference still resolves the same escalation instead of
splitting into a second one; the stored ``question`` is always the row's own verbatim text.
``kind`` is carried through
when the v1 row has one and defaults to ``"finding"`` (§3.1's own default) when it does not — v1 rows
never had a ``kind`` column, so most real rows lack it; dropping it instead of defaulting it would be
silent data loss (design §4.2 requires ``kind`` in the field set). ``kind`` is only ever set from the
row that *creates* the escalation; a later resolving row's own kind (if any) is not consulted,
matching ``store.add_escalation``'s "never back-filled" rule.

**A disposition is open iff it is falsy or, case- and surrounding-whitespace-insensitively, the
string ``"open"``** (DO-694, follow-up) — that is the only spelling family v1 writes for an open
row (measured on the real file, plus ``"Open"``/``" open"`` variants seen since); every other value
(``"resolved"``, ``"resolved-invalid"``, and any other v1 spelling not yet seen) is treated as a
terminal disposition and stored verbatim, never guessed at or rejected — the row's own disposition
string is the record of what happened, so a reader is never left to guess. The original falsy-only
check read a v1 ``"open"`` row as resolved, because the string itself is truthy; the follow-up
case-sensitive exact match then let ``"Open"`` fall through the same way.

Counters, defined precisely because they are not disjoint: ``imported`` counts every row that
creates a NEW escalation (one per distinct ``(firstSeen, question)`` never seen before, in this file
or in an earlier import); ``resolved`` counts every row that is NOT open (see above) and lands an
``answer_escalation`` call — including a row that both creates an escalation AND carries its own
resolved disposition, which increments both counters for that one row. Offset timestamps
(``+03:00``, the shape every real ``firstSeen`` uses) are stored as-is; nothing on this path parses
or normalises them.

**Atomic and idempotent (F2, F5, F6)**, because WS5 5.4 points this at Zvi's real
``escalations.jsonl`` and a second run must be safe. The whole file is parsed and validated (JSON
shape, a ``firstSeen``/``ts``, a ``question`` key, no row silently colliding with an open record
under the same identity) before any row is written; a bad row raises ``Usage`` (exit 2) naming the
line, and nothing is imported — a damaged file must be fixed and re-run as a whole, never "the rows
before line N are already in, importing the rest". Once validated, every write for the run lands in
one ``store.transaction()``: not a row is committed unless all of them are. Re-running the same file
adds nothing new: identities already in the store are neither re-created (checked against
``store.escalations_by_identity``, not just this run's own rows) nor re-resolved (an already
``resolved_at`` row is left alone, matching the F4 "an escalation resolves once" rule) — so
``imported``/``resolved`` on a full rerun both come back 0.
"""
import json
from pathlib import Path

from rabota import cli, errors
from rabota.context import Context


def _normalize_question(question: str) -> str:
    """Fold whitespace drift out of a question for **keying only** (DO-694 follow-up).

    v1 has re-emitted the same question with a trailing space, or otherwise perturbed run text,
    on the resolving row of a pair that must still identify the same escalation as its open row —
    a byte-for-byte key treats that as two different escalations and leaves the original open
    forever. Both surrounding AND internal whitespace runs are collapsed (``"foo  bar"`` and
    ``"foo bar"`` key alike), because v1's drift has shown up as both. The stored ``question`` is
    always the row's own verbatim text; only the derived key is normalized.
    """
    return " ".join(question.split())


def _is_open(disposition) -> bool:
    """v1's only spelling for "still open" is a falsy value or the literal string ``"open"``,
    case- and surrounding-whitespace-insensitive (``"Open"``, ``" open"``) — DO-694 follow-up:
    a case-sensitive exact match let ``"Open"`` fall through as a terminal disposition and land
    with ``resolved_at`` set, silently, which is the original DO-694 bug reached by a different
    spelling. Every other disposition (``"resolved"``, ``"resolved-invalid"``, an unrecognised
    spelling not yet seen) is still treated as terminal and stored verbatim rather than guessed
    at or refused — the disposition string itself is the record of what happened, so a reader
    inspecting the row can always tell; nothing here invents an answer the row didn't give."""
    if not disposition:
        return True
    return isinstance(disposition, str) and disposition.strip().lower() == "open"


def run_import_v1(ctx: Context, jsonl: Path) -> dict:
    path = Path(jsonl)
    try:
        text = path.read_text()
    except FileNotFoundError:
        # F9 (low): a missing --jsonl is bad input, not an internal error — Usage (exit 2),
        # not the generic "unexpected FileNotFoundError" (exit 5) it fell through to before.
        raise errors.Usage(f"no such file: {path}") from None
    rows, open_keys_in_file = [], set()
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
        key = (fs, _normalize_question(row["question"]))
        is_open = _is_open(row.get("disposition"))
        if is_open:
            if key in open_keys_in_file:
                # F6/F5: a second OPEN row sharing an earlier open row's identity used to be
                # dropped, uncounted, by the old elif chain — refuse instead of guessing which
                # one was meant.
                raise errors.Usage(f"{path}:{lineno}: duplicate open firstSeen/question {key!r}")
            open_keys_in_file.add(key)
        else:
            # DO-694 follow-up: a resolving row closes out this identity's "open" slot, so a
            # later open row reopening the same (firstSeen, question) within the file is a
            # legitimate open->resolved->reopen sequence, not the true duplicate the guard above
            # exists to catch — leaving the key behind mislabelled that sequence as a duplicate.
            open_keys_in_file.discard(key)
        rows.append((key, fs, row))

    existing = ctx.store.escalations_by_identity(ctx.tenant.name)
    by_key = {(fs, _normalize_question(q)): e for (fs, q), e in existing.items()}
    ids = {key: e["id"] for key, e in by_key.items()}
    resolved_already = {key for key, e in by_key.items() if e["resolved_at"]}
    imported = resolved = 0
    with ctx.store.transaction():
        for key, fs, row in rows:
            if key not in ids:
                ids[key] = ctx.store.add_escalation(
                    ctx.tenant.name, row.get("question", ""), row.get("evidence", ""), row.get("options", []),
                    first_seen=fs, kind=row.get("kind") or "finding")
                imported += 1
            if not _is_open(row.get("disposition")) and key not in resolved_already:
                ctx.store.answer_escalation(ids[key], row["disposition"], row.get("resolution"))
                resolved_already.add(key)
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
