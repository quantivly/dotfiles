"""``rabota ingest``: store connector results the skill fetched in-session.

Single-source form (unchanged): ``ingest {slack,calendar} --file F``. Multi-source form
(DO-727): ``ingest --file slack=F1 --file calendar=F2`` — the skill fetches both
connectors in one in-session round-trip, so one ``ingest`` call replaces two, each a full
model round-trip in an agent loop.

Inline form (DO-740): ``ingest --stdin < payload.json``, where the payload is one JSON object
keyed by source, e.g. ``{"slack": {...}, "calendar": {...}}`` — each value the same shape a
``--file`` would point at. This drops the step where the agent writes ``sources/<source>.json``
files to disk before calling ``ingest``, which was one full model round-trip (a tool call whose
only purpose was producing the next tool call's argument) per ``/rabota brief`` run.

**Stdin JSON, not a repeated ``--json SOURCE=PAYLOAD`` flag.** A command-line argument is
shell-quoted by whatever emits it; a heredoc on stdin is not. Real Slack/Calendar items carry
`"`, `'`, backticks, `$`, newlines and non-ASCII text, and a payload that must survive as one
shell *argument* needs the model to get argument-quoting exactly right on every call, with a
silent wrong-output failure mode when it doesn't (a backtick or `$(...)` left unescaped executes;
a stray unescaped quote merges two arguments or truncates the payload). A heredoc handed to
stdin (`rabota ingest --stdin <<'EOF' ... EOF`) carries all of that verbatim: the shell does not
tokenize or expand anything inside a quoted heredoc, so the only requirement left is valid JSON,
which the model is already good at emitting. This is proven in ``tests/test_ingest_inline.py``,
which drives the inline form with quotes, backticks, `$`, a literal `EOF` line, newlines, emoji
and a 100 KB payload through an actual heredoc-fed stdin and asserts byte-for-byte survival.

The inline and file forms combine in one call (``--stdin`` plus ``--file SOURCE=PATH``) and share
the duplicate-source refusal: a source named in both is refused before anything is written, the
same as a source named twice within one form (see ``run_ingest_many``).

Four decisions govern the multi-source form; each is load-bearing and each is tested:

**Fireflies is not in ``ALLOWED`` (DO-746 fix round, finding F4).** It moved to
``sync.FETCHED_SOURCES`` in DO-746: the timer fetches it server-side into
``sources/fireflies.json`` with a ``{"transcripts": [...]}`` shape. Before this fix, a manual
``ingest fireflies --file F`` was still accepted and wrote ``{"items": [...]}`` instead — a
different shape, at the same path, with nothing to notice the mismatch — silently discarding the
timer's snapshot until the next sync tick. There is no legitimate caller for it any more: the
skill never fetches Fireflies in-session (see ``commands.brief``'s ``compute_needs``), so the only
way to reach this path was a stale habit or a hand-typed command, and it is refused outright now.

1. **A bad file among good ones is reported, not silently dropped, and the good ones still land.**
   Refusing the whole call whenever one of three files is malformed would waste the other two
   connectors' already-completed fetches for no gain in safety — the good files are self-contained
   and independent, so writing them is exactly as safe as it is in three separate ``ingest`` calls.
   What is NOT allowed is a return that reads as "all three ok": ``run_ingest_many`` always raises
   ``errors.Partial`` (exit 4, like ``sync.run_sync``) naming every source that did not land,
   once every source has been attempted — never before, and never silently swallowed. "Did
   not land" covers any failure, not only a validation one: a read or write error on one
   source must not abandon the others, whose files are already fetched and independent of it.
2. **The return shape is a dict keyed by source**, one entry per source, each entry exactly the dict
   ``run_ingest`` already returns for a valid source (or an ``{"ok": False, "error": ...}`` stand-in
   for a refused one) — the same shape ``sync.run_sync`` already uses for the same reason: a caller
   reading `report["slack"]["ok"]` does not care whether it arrived via the single- or multi-source
   form. The single-source form's return (one un-keyed dict) is untouched.
3. **A source named twice in one call is refused outright, before any file is touched or written.**
   Last-write-wins would let a duplicate ``slack=`` silently shadow the first one — exactly the
   silent coercion this module refuses everywhere else (see the ``ok`` rule below).
4. **No half-written state.** ``_load_file``/``_validate`` fully read and validate a file or an
   inline payload in memory before ``_store`` writes anything, so a refused source never leaves a
   partial ``sources/<source>.json`` or a stray ``record_sync`` row — this was already true of the
   single-source form and multi-source ingest calls ``run_ingest``/``run_ingest_inline`` once per
   source unchanged, so it inherits the guarantee rather than re-implementing it.

The file itself is ``{"fetched_at": "<UTC Z>", "ok": true|false, "error": str|null, "items": [...]}``.
``ok`` must be a JSON boolean: a string ``"false"`` is truthy, so coercing it recorded a failed
source as a success and ``brief`` stayed silent (review finding k5). Anything that is not
``true``/``false`` — a string, a number, ``null``, absent — is ``Usage`` naming the type it got;
a file that cannot state success or failure unambiguously has not stated it.
A failed fetch (``ok: false``) is still recorded — the snapshot is written with ``items: []``
and ``source_syncs`` gets ``ok=0`` with the error — so ``brief`` can say
``! <source> failed — list is partial`` instead of silently ranking without it. This validation is
unchanged by DO-727 and out of scope for it.
"""
import json
import sys
from pathlib import Path

from rabota import cli, errors, snapshots
from rabota.context import Context

ALLOWED = ("slack", "calendar")


def _validate(data: object, label: str) -> dict:
    """Validate an already-parsed ingest payload; every fault in it is ``Usage`` naming ``label``.

    Shared by the file form (``label`` is the path) and the inline form (``label`` names the
    source, e.g. ``"stdin:slack"``) — the schema a caller must satisfy does not depend on how the
    bytes arrived, and this is the one place that schema is written down.
    """
    if not isinstance(data, dict) or "fetched_at" not in data:
        raise errors.Usage(f"{label}: ingest payload must be an object with 'fetched_at' (and 'items' when ok)")
    try:
        snapshots.parse_fetched_at(str(data["fetched_at"]))
    except ValueError:
        raise errors.Usage(f"{label}: fetched_at must be UTC like 2026-09-16T07:00:00Z") from None
    ok = data.get("ok")
    if not isinstance(ok, bool):
        got = "absent" if "ok" not in data else f"{type(ok).__name__} {ok!r}"
        raise errors.Usage(f"{label}: 'ok' must be a JSON boolean (true or false), got {got}")
    if ok and not isinstance(data.get("items"), list):
        raise errors.Usage(f"{label}: a successful ingest payload needs an 'items' list")
    return data


def _load_file(file: Path) -> dict:
    """Read and validate an ingest file; every fault in it is ``Usage`` naming the file."""
    try:
        data = json.loads(Path(file).read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise errors.Usage(f"cannot read {file}: {e}") from None
    return _validate(data, str(file))


def _store(ctx: Context, source: str, data: dict) -> dict:
    """Write ``sources/<source>.json`` from an already-validated payload; a failed fetch is recorded, not raised."""
    ok = data["ok"]                       # a bool, or the caller's validation already raised
    error = None if ok else str(data.get("error") or "unknown error")
    items = data["items"] if ok else []
    payload = {"ok": ok, "error": error, "fetched_at": data["fetched_at"], "items": items}
    path = snapshots.write(ctx.state_dir, source, payload)
    ctx.store.record_sync(ctx.tenant.name, source, ok, error, str(path))
    return {"source": source, "ok": ok, "error": error, "items": len(items), "path": str(path)}


def run_ingest(ctx: Context, source: str, file: Path) -> dict:
    """Validate ``file`` and write ``sources/<source>.json``; a failed fetch is recorded, not raised."""
    if source not in ALLOWED:
        raise errors.Usage(f"ingest accepts {ALLOWED}")
    return _store(ctx, source, _load_file(file))


def run_ingest_inline(ctx: Context, source: str, data: dict) -> dict:
    """Inline counterpart of ``run_ingest``: ``data`` is an already-parsed payload, not a file path.

    Same schema, same ``ok``-must-be-boolean rule, same recording of a failed fetch — ``_validate``
    and ``_store`` are exactly what the file form calls, so the two forms cannot silently drift.
    """
    if source not in ALLOWED:
        raise errors.Usage(f"ingest accepts {ALLOWED}")
    return _store(ctx, source, _validate(data, f"stdin:{source}"))


def run_ingest_many(ctx: Context, specs: list[tuple[str, object]]) -> dict:
    """Validate and store one entry per source in a single call; see the module docstring for why.

    ``specs`` pairs a source name with either a ``Path`` (file form) or an already-parsed ``dict``
    (inline form, from ``--stdin``) — the two forms are indistinguishable from here on, so a call
    mixing both (``--file slack=F`` plus a ``calendar`` key on stdin) is handled the same as a call
    using only one.

    Refuses the whole call, before touching any file, if ``specs`` names a source more than once —
    across the two forms, not only within one of them — or names one outside ``ALLOWED``.
    Otherwise dispatches each pair to ``run_ingest`` or ``run_ingest_inline`` depending on its
    type; a pair that fails — for ANY reason, not only a validation one — is recorded rather
    than raised immediately, so the sources after it are still attempted and the ones that did
    land still get written and recorded. Once every pair has been attempted, raises
    ``errors.Partial`` naming every source that did not land, with each one's reason in the
    message: raising discards the return value, so that message is the only place a caller can
    learn *why*. An empty ``failed`` list never reaches this point, so a caller who only checks
    the exit code cannot mistake a partial ingest for a complete one.

    Returns ``{source: report}`` for every source given, valid or not: a valid source's report is
    exactly what ``run_ingest``/``run_ingest_inline`` returns; a refused source's is
    ``{"source", "ok": False, "error", "items": 0, "path": ""}``.
    """
    sources = [s for s, _ in specs]
    dupes = sorted({s for s in sources if sources.count(s) > 1})
    if dupes:
        raise errors.Usage(f"source given twice in one ingest call: {', '.join(dupes)}")
    unknown = sorted({s for s in sources if s not in ALLOWED})
    if unknown:
        raise errors.Usage(f"ingest accepts {ALLOWED}, got {', '.join(unknown)}")
    report, failed = {}, []
    for source, spec in specs:
        try:
            report[source] = run_ingest(ctx, source, spec) if isinstance(spec, Path) \
                else run_ingest_inline(ctx, source, spec)
        except Exception as e:  # noqa: BLE001
            # Deliberately broad. Catching only `errors.Usage` meant an `OSError` from the snapshot
            # write escaped mid-loop: the sources after it were never attempted, though their files
            # were already fetched, valid and independent of it, and the exit named the exception
            # without saying what had landed and what had been skipped (review finding). Every
            # source given is attempted; what went wrong with each is in its own report entry. The
            # type name is kept for anything that is not one of ours, so a genuine bug here is still
            # diagnosable from the output rather than flattened into a message.
            msg = str(e) if isinstance(e, errors.RabotaError) else f"{type(e).__name__}: {e}"
            report[source] = {"source": source, "ok": False, "error": msg, "items": 0, "path": ""}
            failed.append(source)
    if failed:
        # Not "files invalid": a source can also fail to land on a read or write error, and a
        # message that names the wrong cause is the kind of small untruth that sends the reader to
        # the wrong file. The reason rides in the message because raising discards ``report`` --
        # `failed` stays a list of plain source names, the shape `cli.main` and `sync.run_sync`
        # already share, so this message is the only place a caller can learn *why*.
        why = "; ".join(f"{s} ({report[s]['error']})" for s in failed)
        raise errors.Partial(f"ingest did not land: {why}", failed=failed)
    return report


def _build(sub):
    p = sub.add_parser("ingest", help="store connector results fetched in-session")
    p.add_argument("source", nargs="?", choices=ALLOWED,
                    help="single-source form: paired with exactly one plain --file")
    p.add_argument("--file", action="append", default=[], metavar="PATH|SOURCE=PATH",
                    help="single-source form: --file PATH; multi-source form: repeat "
                         "--file SOURCE=PATH, once per source")
    p.add_argument("--stdin", action="store_true",
                    help="inline multi-source form: read one JSON object from stdin keyed by "
                         'source, e.g. {"slack": {...}, "calendar": {...}}; combines with '
                         "--file SOURCE=PATH")


def _read_stdin_specs() -> list[tuple[str, dict]]:
    """Parse ``--stdin``'s payload into ``(source, data)`` pairs; every fault is ``Usage``.

    A terminal on stdin is refused rather than read: with nothing piped, the read would block until
    something external killed the process (DO-740 review). The bytes are decoded strictly, as the
    file form's ``read_text`` does, so invalid UTF-8 is refused here too instead of being stored
    surrogate-escaped.
    """
    if sys.stdin is None or sys.stdin.isatty():
        raise errors.Usage("--stdin: nothing is piped in; feed the JSON object on stdin (e.g. a heredoc)")
    buf = getattr(sys.stdin, "buffer", None)
    try:
        text = buf.read().decode("utf-8") if buf is not None else sys.stdin.read()
    except UnicodeDecodeError as e:
        raise errors.Usage(f"--stdin: not valid UTF-8: {e}") from None
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise errors.Usage(f"--stdin: invalid JSON: {e}") from None
    if not isinstance(data, dict):
        raise errors.Usage("--stdin: JSON must be an object keyed by source, "
                            'e.g. {"slack": {...}, "calendar": {...}}')
    return list(data.items())


def _run(ns):
    ctx = Context.from_namespace(ns)
    if ns.source is not None:
        if ns.stdin:
            raise errors.Usage("--stdin cannot be combined with the single-source form; "
                                "drop the positional source to ingest inline")
        if len(ns.file) != 1:
            raise errors.Usage("single-source ingest (`ingest <source> --file PATH`) takes exactly one --file; "
                                "to ingest several sources, drop the positional source and repeat --file SOURCE=PATH")
        # Review finding: refusing every single-source `--file` containing `=` also refused a legal
        # path that happens to contain one, which `main` accepted -- "unchanged" has to mean
        # unchanged for the unusual inputs too. Only a prefix that is an actual source name can be
        # the mixed form, so only that is refused, and the message names the ambiguity rather than
        # letting a mistyped mixed form fail later as a missing file.
        head = ns.file[0].partition("=")[0]
        if "=" in ns.file[0] and head in ALLOWED:
            raise errors.Usage(f"ingest names a source twice: positional {ns.source!r} and --file {head}=...; "
                                f"use one form or the other")
        return run_ingest(ctx, ns.source, Path(ns.file[0]))
    if not ns.file and not ns.stdin:
        raise errors.Usage("ingest needs `<source> --file PATH`, repeated `--file SOURCE=PATH`, or --stdin")
    specs: list[tuple[str, object]] = []
    for arg in ns.file:
        if "=" not in arg:
            raise errors.Usage(f"multi-source ingest needs --file SOURCE=PATH, got {arg!r}")
        source, _, path = arg.partition("=")
        specs.append((source, Path(path)))
    if ns.stdin:
        specs.extend(_read_stdin_specs())
    return run_ingest_many(ctx, specs)


cli.register("ingest", _build, _run)
