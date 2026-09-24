"""``rabota ingest``: store connector results the skill fetched in-session.

Single-source form (unchanged): ``ingest {slack,calendar,fireflies} --file F``. Multi-source form
(DO-727): ``ingest --file slack=F1 --file calendar=F2 --file fireflies=F3`` — the skill fetches all
three connectors in one in-session round-trip, so one ``ingest`` call replaces three, each a full
model round-trip in an agent loop. Four decisions govern the multi-source form; each is load-bearing
and each is tested:

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
4. **No half-written state.** ``_load`` fully reads and validates a file in memory before
   ``run_ingest`` writes anything, so a refused source never leaves a partial ``sources/<source>.json``
   or a stray ``record_sync`` row — this was already true of the single-source form and multi-source
   ingest calls ``run_ingest`` once per source unchanged, so it inherits the guarantee rather than
   re-implementing it.

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
from pathlib import Path

from rabota import cli, errors, snapshots
from rabota.context import Context

ALLOWED = ("slack", "calendar", "fireflies")


def _load(file: Path) -> dict:
    """Read and validate the ingest file; every fault in it is ``Usage`` naming the file."""
    try:
        data = json.loads(Path(file).read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise errors.Usage(f"cannot read {file}: {e}") from None
    if not isinstance(data, dict) or "fetched_at" not in data:
        raise errors.Usage(f"{file}: ingest file must be an object with 'fetched_at' (and 'items' when ok)")
    try:
        snapshots.parse_fetched_at(str(data["fetched_at"]))
    except ValueError:
        raise errors.Usage(f"{file}: fetched_at must be UTC like 2026-09-16T07:00:00Z") from None
    ok = data.get("ok")
    if not isinstance(ok, bool):
        got = "absent" if "ok" not in data else f"{type(ok).__name__} {ok!r}"
        raise errors.Usage(f"{file}: 'ok' must be a JSON boolean (true or false), got {got}")
    if ok and not isinstance(data.get("items"), list):
        raise errors.Usage(f"{file}: a successful ingest file needs an 'items' list")
    return data


def run_ingest(ctx: Context, source: str, file: Path) -> dict:
    """Validate ``file`` and write ``sources/<source>.json``; a failed fetch is recorded, not raised."""
    if source not in ALLOWED:
        raise errors.Usage(f"ingest accepts {ALLOWED}")
    data = _load(file)
    ok = data["ok"]                       # a bool, or _load raised
    error = None if ok else str(data.get("error") or "unknown error")
    items = data["items"] if ok else []
    payload = {"ok": ok, "error": error, "fetched_at": data["fetched_at"], "items": items}
    path = snapshots.write(ctx.state_dir, source, payload)
    ctx.store.record_sync(ctx.tenant.name, source, ok, error, str(path))
    return {"source": source, "ok": ok, "error": error, "items": len(items), "path": str(path)}


def run_ingest_many(ctx: Context, files: list[tuple[str, Path]]) -> dict:
    """Validate and store one file per source in a single call; see the module docstring for why.

    Refuses the whole call, before touching any file, if ``files`` names a source more than once
    or names one outside ``ALLOWED``. Otherwise calls ``run_ingest`` once per ``(source, file)``
    pair; a pair that fails — for ANY reason, not only a validation one — is recorded rather
    than raised immediately, so the sources after it are still attempted and the ones that did
    land still get written and recorded. Once every pair has been attempted, raises
    ``errors.Partial`` naming every source that did not land, with each one's reason in the
    message: raising discards the return value, so that message is the only place a caller can
    learn *why*. An empty ``failed`` list never reaches this point, so a caller who only checks
    the exit code cannot mistake a partial ingest for a complete one.

    Returns ``{source: report}`` for every source given, valid or not: a valid source's report is
    exactly what ``run_ingest`` returns; a refused source's is
    ``{"source", "ok": False, "error", "items": 0, "path": ""}``.
    """
    sources = [s for s, _ in files]
    dupes = sorted({s for s in sources if sources.count(s) > 1})
    if dupes:
        raise errors.Usage(f"source given twice in one ingest call: {', '.join(dupes)}")
    unknown = sorted({s for s in sources if s not in ALLOWED})
    if unknown:
        raise errors.Usage(f"ingest accepts {ALLOWED}, got {', '.join(unknown)}")
    report, failed = {}, []
    for source, file in files:
        try:
            report[source] = run_ingest(ctx, source, file)
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


def _run(ns):
    ctx = Context.from_namespace(ns)
    if ns.source is not None:
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
    if not ns.file:
        raise errors.Usage("ingest needs either `<source> --file PATH` or repeated `--file SOURCE=PATH`")
    files = []
    for arg in ns.file:
        if "=" not in arg:
            raise errors.Usage(f"multi-source ingest needs --file SOURCE=PATH, got {arg!r}")
        source, _, path = arg.partition("=")
        files.append((source, Path(path)))
    return run_ingest_many(ctx, files)


cli.register("ingest", _build, _run)
