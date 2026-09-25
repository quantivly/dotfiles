"""``brief`` runs the whole read-only cycle — preflight, rank, brief — in one process (DO-716).

Line order: a staleness warning when the sequence is older than ``STALE_AFTER_MIN`` (the
30-minute pre-compute timer has then missed at least once), the ranked items, one line per
failed source, one line per stale ``needs`` source, the inbox summary, and ``brief: <path>``.
Everything counts toward the cap, and ``--max-lines`` lets a wrapper such as ``sol brief``
prepend its own line and still show twelve. On a same-day rerun only ``+``/``-`` deltas print,
or ``no change since HH:MM``.

The cap applies on EVERY path, the no-change one included (review finding k4: it was never
sliced, so ``--max-lines 1`` printed two lines). ``--max-lines 0`` is a usage error, not an
empty brief — a zero-line brief is not a brief — and so is a negative cap. A ``generated_at``
that does not parse is a usage error naming the file, never an unhandled ``ValueError``.

**Move 1 (one process).** ``run_brief`` now runs ``preflight`` first — exactly the same
``preflight.run_command`` the standalone ``rabota preflight`` command calls, so a failed
identity pin still exits 3, still prints the report, and still records a ``runs`` row. Only
then does it rank (if needed) and compose the brief. ``preflight`` and ``rank`` stay separate
commands for their other callers (the timer, `rabota preflight` on its own); ``brief`` just
calls them in-process instead of a wrapper spending a model round-trip between each.

**Move 2 (``needs``, not a failure).** ``slack`` and ``calendar`` are never fetched by the CLI
itself (``sync.FETCHED_SOURCES`` is ``linear``/``github``/``fireflies`` — those are the 30-minute
timer's job, and a stale one of those is a job for ``precompute``/``sync``, not for an agent to
hand-fetch; Fireflies moved from here to that set in DO-746, once a static per-user API key made
it fetchable the same way as Linear). For the other two, ``run_brief`` computes ``needs``: one
entry per source that is either missing a snapshot entirely or older than
``STALE_AFTER_MIN`` — deliberately the SAME number that ages the brief itself, not a third
unrelated one, because both answer the same question ("how old is too old for today's brief?").
"never fetched" and "stale (N min old)" are distinguished in the entry's ``reason`` because they
are different facts — the CLI does not know a source's cadence, so it must not claim staleness
about one it has literally never seen. A source the tenant does not list in ``sources`` is
skipped, exactly as ``preflight`` already skips Linear for a tenant that does not use it.

``needs`` ACCOMPANIES the brief, never replaces it: ``run_brief`` still prints and writes
whatever is actually in today's ``sequence.json``, and each stale/missing source gets one
``! <source> needs a fetch — <reason>`` terminal line — the same ``!``-line vocabulary
``failed_sources`` already uses, not a second one. The full instruction for each — the exact
query string and the exact path to write it to (``<state_dir>/ingest-<source>.json``, matching
the ``rabota`` skill's step 2) — travels only in the JSON return (``{"needs": [...]}``).
``needs`` is not itself a failure: the CLI did its job and is naming what would make the answer
better, so it does not change the exit code (0), the same way a failed source already does not.

**Move 6 (Fireflies reaches classification without a fetch, DO-746 fix round finding F1).**
``29ab0d3`` moved Fireflies into ``sync.FETCHED_SOURCES`` but left nothing reading
``sources/fireflies.json`` for classification: ``reconcile.build_tracked_index`` projects only
Linear and GitHub, and turn 2 of the skill cycle only ever ran when ``needs`` was non-empty for
Slack/Calendar. So a Fireflies action item could sync forever and never reach the model that
classifies it — silently, because nothing failed. The fix reuses turn 2 rather than adding a new
path: ``compute_needs`` appends a ``{"source": "fireflies", "items": [...], "fetched": True}``
entry — no ``query``, because there is nothing left to fetch — whenever the snapshot holds action
items not yet classified. ``_alert_lines`` and the skill's step 2 both key off ``fetched`` rather
than the source name, so this degrades to the ordinary fetch-needed shape for anything else.

"Not yet classified" is tracked in ``<state_dir>/fireflies-classified.json``
(``_fireflies_classified_ids`` / ``_mark_fireflies_classified``). ``last-brief-shown.json`` at the
state-dir root — cross-day, unlike the day-scoped ``last-brief.json`` — is still written at the
same "shown, not merely computed" gate as before, and ``commands.sync.fireflies_since`` still reads
it to derive its fetch window from the invariant rather than a fixed number of days. What changed
in the fix round below is *what* gets marked classified, and *when*.

**Fix round 2, finding A (keyed by item, not by transcript).** Fireflies fills a transcript's
``action_items`` in over time (the parser's own docstring says so), so keying the classified set on
the bare transcript id made every item appended to an already-classified transcript invisible
forever — a real regression, not a hypothetical one. ``_fireflies_item_key`` keys on
``(transcript_id, digest(speaker, item text))`` instead; the digest excludes ``timestamp``, since
the parser already treats it as sometimes-absent and Fireflies can fill one in on revision without
that being a new item. The file is bounded exactly as before: the stored set is intersected with
the keys the current snapshot still holds before anything new is unioned in, so it cannot grow
past what one fetch window covers.

**Fix round 2, finding D (marking is an explicit acknowledgement, not a side effect of being
shown).** The old gate — mark whatever ``needs`` handed out the moment *any* brief with
``text=True`` or empty ``needs`` was produced — could not tell turn 2's classifying call from a
bare ``rabota --text brief`` typed by @zvi or by anything outside the skill's turn 2: either one
passed the gate and marked every pending item classified, even though the reader only ever saw the
one-line alert, never the items. Classification is now a separate act: ``run_brief`` takes a
``classified`` list, and only ``"fireflies" in classified`` marks anything. Turn 1 (the JSON call)
records exactly the item set it is handing out in ``<state_dir>/fireflies-pending.json``
(``_write_fireflies_pending``) — a plain snapshot of "what turn 2 was just given", overwritten by
each subsequent JSON call and left untouched by a ``--text`` call, acknowledging or not, so a
meeting that lands between turn 1 and turn 2 cannot sneak into what the acknowledgement marks.
The acknowledging call (``rabota --text brief --max-lines 11 --classified fireflies``) reads that
file, marks exactly those items, and clears it — nothing else ever reads or writes it. Marking
happens before ``needs``/alert lines are built for that same call, which is what fixes **finding
B** (the final screen no longer says "needs classifying" about items this very call just marked).

**Move 5 (``--dry-run`` writes nothing, DO-742).** ``run_brief`` used to ignore ``ctx.dry_run``
outright — the global flag every subcommand either honours or silently ignores — so a dry run
wrote ``brief.md``, ``last-brief.json`` and (via the implicit ``run_rank``) ``sequence.json``
exactly as a real run does. That is worse than a no-op: because ``last-brief.json`` is what makes
the NEXT call print a delta instead of the ranked list, a dry run changed what tomorrow's real
run would show, invisibly — the first symptom would be a live brief reading
``no change since HH:MM`` with nothing under it.

With ``ctx.dry_run`` set, ``run_brief`` still computes and prints exactly the lines a real run
would (via ``rank.compute_sequence`` when today's ``sequence.json`` does not exist yet, instead of
``run_rank``, which would write it), and says so with one ``dry-run: nothing written`` line — a
dry run that prints nothing would be safe and useless, not just safe. What it skips is only the
writes: ``sequence.json``/``.md``, ``brief.md``, and ``last-brief.json``.

**Preflight still runs on the dry path, deliberately.** It is read-only (three ``GET``-shaped
identity checks), but it is not free — it is three real API calls as @zvi and it records a
``runs`` row regardless of ``--dry-run`` (``preflight.run_command`` does not read ``dry_run``
either; unchanged here, and out of scope for this change per the audit). The argument for keeping
it: a dry run that skipped the identity pin could show a brief the REAL run would then refuse to
produce (exit 3) — a dry run whose answer the following real run cannot reproduce is a worse lie
than the extra API calls. Skipping it would only be right if "what would this print" and "is
identity still pinned" were different questions; they are not, because a failed pin is exactly
what stops the real ``brief`` from printing anything at all.
"""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from rabota import cli, emit, errors, reconcile, snapshots
from rabota.commands import preflight as preflight_cmd
from rabota.commands import rank as rank_cmd
from rabota.commands.rank import run_rank
from rabota.context import Context

MAX_LINES = 12
STALE_AFTER_MIN = snapshots.STALE_AFTER_MIN    # one definition, in `snapshots`; never restate it here
TITLE_MAX = 60
LINE_MAX = 120
NEEDS_SOURCES = ("slack", "calendar")    # never fetched by the CLI itself; see module docstring
LAST_SHOWN_FILE = snapshots.LAST_SHOWN_FILE    # one definition, in `snapshots`; commands.sync reads it for F2
FIREFLIES_CLASSIFIED_FILE = "fireflies-classified.json"
CLASSIFIABLE_SOURCES = ("fireflies",)    # the only source whose handed-out items `--classified` can acknowledge


def check_classified(classified: list[str] | None, text: bool) -> None:
    """Refuse an acknowledgement that cannot be honest (DO-746 review round 4).

    ``--classified`` marks items as classified; an unknown name would silently acknowledge nothing,
    and one on a JSON call would mark items on a screen nobody was shown -- finding D's own bug,
    reached by a path the CLI allowed. Both are usage errors, raised before anything is written.
    """
    unknown = [s for s in (classified or []) if s not in CLASSIFIABLE_SOURCES]
    if unknown:
        raise errors.Usage(f"--classified accepts only {', '.join(CLASSIFIABLE_SOURCES)}; got {', '.join(unknown)}")
    if classified and not text:
        raise errors.Usage("--classified requires --text: it acknowledges items on the screen the reader is shown")
FIREFLIES_PENDING_FILE = "fireflies-pending.json"


def _truncate_suffix(s: str, budget: int) -> str:
    """Cut ``s`` to ``budget`` chars at a word boundary, with a trailing ``…`` — or drop it if there's no room."""
    if budget <= 0:
        return ""
    if len(s) <= budget:
        return s
    cut = s[:budget - 1].rstrip()
    space = cut.rfind(" ")
    if space > 0:
        cut = cut[:space]
    return cut + "…"


def _fmt(n: int, item: dict) -> str:
    """``N. KEY — title · waiting: who · why_now``, capped at ``LINE_MAX``.

    A blank title is left out rather than printed as a dangling ``—`` — the source had no title,
    and the line should say only what it knows. A ``why_now`` that is only whitespace counts as
    blank for the same reason.

    Over budget, the line is cut in order of what a reader can act without: ``why_now`` (prose)
    first, then ``waiting``, and only then the identifier itself. ``N. KEY — title`` is what the
    line exists to carry, so it is the last thing sacrificed — and when it alone exceeds
    ``LINE_MAX`` there is nothing left to give, so it is cut with a visible ``…`` rather than
    sliced silently. Review finding: the old trailing ``[:LINE_MAX]`` did exactly that silent
    slice whenever the head overran, which the docstring above it denied was possible — and a
    bare-URL key, the fallback this very change introduces, is long enough to trigger it.
    """
    title = (item["title"] or "").strip()
    if len(title) > TITLE_MAX:
        title = title[:TITLE_MAX - 3] + "…"
    head = f"{n}. {item['key']}" + (f" — {title}" if title else "")
    who = f" · waiting: {item['waiting_on']}" if item.get("waiting_on") else ""
    why = (item.get("why_now") or "").strip()
    line = head + who + (f" · {why}" if why else "")
    if len(line) <= LINE_MAX:
        return line
    why = _truncate_suffix(why, LINE_MAX - len(head) - len(who) - len(" · "))
    line = head + who + (f" · {why}" if why else "")
    if len(line) <= LINE_MAX:
        return line
    if len(head) <= LINE_MAX:            # drop `waiting` before touching the identifier
        return head
    return head[:LINE_MAX - 1] + "…"     # nothing left to cut but the identifier itself


def staleness_line(seq: dict, now: datetime, max_age_min: int = STALE_AFTER_MIN) -> str | None:
    """``! brief is N min old …`` when ``seq["generated_at"]`` is older than ``max_age_min`` minutes, else ``None``.

    An absent or unparseable ``generated_at`` is ``Usage`` naming the field (exit 2), not a traceback.
    """
    value = seq.get("generated_at")
    try:
        generated = snapshots.parse_fetched_at(value)
    except (ValueError, TypeError):
        raise errors.Usage(f"sequence.json: generated_at must be UTC like 2026-09-16T08:00:00Z, got {value!r}") from None
    age_min = int((now - generated).total_seconds() // 60)
    if age_min <= max_age_min:
        return None
    return f"! brief is {age_min} min old — timer failed? run: rabota --tenant {seq['tenant']} precompute"


def check_max_lines(max_lines) -> int:
    """``max_lines`` if it is a positive int, else ``Usage``; called before anything is written or printed."""
    if not isinstance(max_lines, int) or max_lines < 1:
        raise errors.Usage(f"--max-lines must be at least 1 (a zero-line brief is not a brief), got {max_lines!r}")
    return max_lines


def _alert_lines(seq: dict, needs: list[dict] | None) -> list[str]:
    """One ``!`` line per failed source and per ``needs`` entry, in that order.

    A ``needs`` line carries its query and the basename to write, because a ``--text`` caller gets
    only these lines and would otherwise have to make a second call for the instruction -- which is
    the round-trip this whole change exists to remove. The JSON form keeps the absolute
    ``write_to``; here the basename is enough, since the caller passed the state dir in.

    An entry with ``fetched: True`` (Move 6: Fireflies already has its items, nothing to fetch)
    gets a different line naming what is actually true of it — no fetch, no file to write, only
    classification — keyed off that flag rather than the source name, so any future source that
    reuses this shape gets the right words for free.
    """
    lines = [f"! {s} failed — list is partial" for s in seq.get("failed_sources", [])]
    for n in (needs or []):
        if n.get("fetched"):
            lines.append(f"! {n['source']} needs classifying — {n['reason']}, no fetch needed")
        else:
            lines.append(f"! {n['source']} needs a fetch — {n['reason']} → "
                         f"{Path(n['write_to']).name} ({n['query']})")
    return [line if len(line) <= LINE_MAX else line[:LINE_MAX - 1] + "…" for line in lines]


def _assemble(head: list[str], body: list[str], alerts: list[str], tail: list[str], max_lines: int) -> list[str]:
    """Lines in display order, capped at ``max_lines``, in a fixed order of what is sacrificed.

    ``tail``'s last entry is ``brief: <path>`` when there is one, and it is **reserved**: it is the
    only way to reach the narrative holding whatever did not fit, so dropping it is the one cut that
    loses information irrecoverably. Above it, the ranked/delta ``body`` gives up lines first, then
    the inbox summary, and the ``!`` alerts last -- and when even the alerts do not fit they are
    **collapsed into one counted line** rather than silently dropped. Review finding: a blind
    ``[:max_lines]`` slice dropped ``brief: <path>`` and two of three alerts at ``--max-lines 1``,
    and the no-change path dropped every alert unconditionally, so a failed source printed no line
    at all on the commonest path of the day -- which the module docstring above says it does.
    """
    # A `dry-run:` head line outranks even the reserved `brief: <path>`: a path is the escape hatch
    # to what did not fit, but on a dry run nothing was written for it to point at -- `run_brief`
    # passes `brief_path=None` there for that reason, so the two only ever compete when a caller
    # builds an unreachable combination. Ranking it here makes "no `max_lines` can drop the notice"
    # true unconditionally rather than by luck (review finding).
    if head and head[0].startswith("dry-run:"):
        return (head[:1] + _assemble(head[1:], body, alerts, tail, max_lines - 1))[:max_lines]
    reserved = tail[-1:] if tail and tail[-1].startswith("brief: ") else []
    rest_of_tail = tail[:-1] if reserved else list(tail)
    budget = max_lines - len(reserved)
    if budget <= 0:                                   # only room for the escape hatch
        return reserved[:max_lines]
    keep_head = head[:budget]
    budget -= len(keep_head)
    if len(alerts) > budget:
        # Collapse rather than drop: the count and the sources still say a list is incomplete.
        sources = ", ".join(a.split(" ", 2)[1] for a in alerts)
        one = f"! {len(alerts)} source alerts — {sources}"
        alerts = [one if len(one) <= LINE_MAX else one[:LINE_MAX - 1] + "…"][:budget]
    budget -= len(alerts)
    keep_tail = rest_of_tail[:budget]
    budget -= len(keep_tail)
    return keep_head + body[:max(0, budget)] + alerts + keep_tail + reserved


def terminal_lines(seq: dict, inbox_summary: str | None, previous: dict | None, max_lines: int = MAX_LINES,
                   brief_path: str | None = None, now: datetime | None = None,
                   needs: list[dict] | None = None, health: list[dict] | None = None,
                   dry_run: bool = False) -> list[str]:
    """The ≤``max_lines`` terminal lines; with ``previous`` (last-brief.json) only the deltas print.

    One ``!`` line per failed source and per ``needs`` entry (see ``compute_needs`` and
    ``_alert_lines``), reusing one vocabulary rather than two. What gets sacrificed when the lines
    do not fit is ``_assemble``'s job, and the no-change rerun goes through it too -- it used to
    return ``footer[-1:]``, which swallowed every alert on the path most likely to be taken twice
    in a morning.

    ``dry_run`` adds one ``head`` line saying plainly that nothing was written, **first**, ahead of
    the staleness warning — so no value of ``max_lines`` can drop it (DO-742: a dry run whose output
    carries no hint that it is hypothetical is indistinguishable from a real one, and the first
    version of this claimed the notice survived every cut while being appended where it did not).
    """
    check_max_lines(max_lines)
    head = []
    if dry_run:
        # FIRST, ahead of the staleness warning, so `head[:budget]` cannot drop it. Review finding:
        # appended second, it was cut at `--max-lines 1` whenever the sequence was also stale, and
        # the surviving line read exactly like a real run's. Of the two, this is the one that must
        # survive: a reader who cannot tell a dry run from a real one may act on it, while the
        # staleness warning is about the stored state and will still be there on the next real run.
        head.append("dry-run: nothing written (brief.md, last-brief.json, sequence.json)")
    if now is not None:
        stale = staleness_line(seq, now)
        if stale:
            head.append(stale)
    alerts = _alert_lines(seq, needs) + [f"! {h['source']} snapshot is unreliable — {h['reason']}"
                                         for h in (health or [])]
    tail = ([inbox_summary] if inbox_summary else []) + ([f"brief: {brief_path}"] if brief_path else [])
    keys = [i["key"] for i in seq["items"]]
    if previous is not None:
        added = [k for k in keys if k not in previous["keys"]]
        removed = [k for k in previous["keys"] if k not in keys]
        if not added and not removed:
            return _assemble(head + [f"no change since {previous['generated_at'][11:16]}"],
                             [], alerts, tail, max_lines)
        return _assemble(head, [f"+ {k}" for k in added] + [f"- {k}" for k in removed], alerts, tail, max_lines)
    room = max(0, max_lines - len(head) - len(alerts) - len(tail))
    return _assemble(head, [_fmt(n, i) for n, i in enumerate(seq["items"][:room], 1)], alerts, tail, max_lines)


def compose_markdown(seq: dict, inbox_plan: dict | None, syncs: list[dict]) -> str:
    """``brief.md``: source status, every ranked item with rationale and URL, decisions, triage, inbox totals."""
    lines = [f"# brief — {seq['tenant']} — {seq['generated_at']}", "", "## Sources"]
    for s in syncs:
        status = "ok" if s["ok"] else "FAILED"
        error = f" — {s['error']}" if s.get("error") else ""
        lines.append(f"- {s['source']}: {status} at {s['fetched_at']}{error}")
    lines += ["", "## Ranked"]
    for n, i in enumerate(seq["items"], 1):
        lines.append(f"{n}. [{i['bucket']}] {i['key']} — {i['title']} — {i['why_now']}  \n"
                     f"   {i['rationale']}  \n   {i['url'] or ''}")
    if seq["decisions"]:
        lines += ["", "## Decisions"] + [f"- {d['key']}: {d['why']} {d['url']}" for d in seq["decisions"]]
    if seq["triage"]:
        lines += ["", "## Team-derived reviews (triage, not ranked)"]
        lines += [f"- {x['key']}: {x['why']} {x['url']}" for x in seq["triage"]]
    if inbox_plan:
        lines += ["", "## Inbox"] + [f"- {b}: {n}" for b, n in inbox_plan.get("totals", {}).items()]
    return "\n".join(lines) + "\n"


def _read_json(path: Path) -> dict | None:
    return json.loads(path.read_text()) if path.exists() else None


def _syncs(ctx: Context) -> list[dict]:
    never = {"ok": False, "fetched_at": "-", "error": "never synced"}
    return [dict(ctx.store.last_sync(ctx.tenant.name, s) or {"source": s, **never}) for s in ctx.tenant.sources]


def _needs_query(source: str, snap: dict | None) -> str:
    """The exact fetch instruction for ``source``, matching the ``rabota`` skill's step 2 wording."""
    if source == "slack":
        return f"to:me after:{snap['fetched_at'][:10]}" if snap else "to:me"
    if source == "calendar":
        return "free blocks for today"          # today's calendar has no "since last fetch" delta
    raise ValueError(f"no needs query for {source!r}")


def _fireflies_classified_path(ctx: Context) -> Path:
    return ctx.state_dir / FIREFLIES_CLASSIFIED_FILE


def _fireflies_pending_path(ctx: Context) -> Path:
    return ctx.state_dir / FIREFLIES_PENDING_FILE


def _fireflies_item_key(transcript_id, item: dict) -> str:
    """Stable id for one Fireflies action item: ``transcript_id`` plus a digest of speaker+text.

    Fix round 2, finding A: keying on the bare transcript id alone made every item Fireflies
    appended to an already-classified transcript invisible forever. The digest deliberately
    excludes ``timestamp`` — the parser (``sources/fireflies.py``) already documents that field as
    sometimes absent, and a timestamp filled in on revision must not read as a new item.
    """
    basis = f"{item.get('speaker') or ''}\x1f{item.get('item') or ''}"
    digest = hashlib.sha256(basis.encode()).hexdigest()[:16]
    return f"{transcript_id}:{digest}"


def _fireflies_classified_ids(ctx: Context) -> set[str]:
    """The set of Fireflies item keys already marked classified (see ``_fireflies_item_key``)."""
    path = _fireflies_classified_path(ctx)
    if not path.exists():
        return set()
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return set()
    ids = data.get("ids") if isinstance(data, dict) else None
    return set(ids) if isinstance(ids, list) else set()


def _fireflies_transcripts(ctx: Context) -> list[dict] | None:
    """The current ``sources/fireflies.json`` snapshot's ``transcripts``, or ``None`` if there is
    nothing usable — absent, unreadable, or not the expected shape. Never raises: an unreadable
    Fireflies snapshot is not this function's failure to report, only its reason to say nothing."""
    try:
        snap = snapshots.read(ctx.state_dir, "fireflies")
    except Exception:  # noqa: BLE001 — same reasoning as the rest of `compute_needs`
        return None
    if not isinstance(snap, dict):
        return None
    transcripts = snap.get("transcripts")
    return transcripts if isinstance(transcripts, list) else None


def _fireflies_need(ctx: Context) -> dict | None:
    """A ``needs`` entry carrying every Fireflies action item not yet classified.

    See Move 6 in the module docstring. Unlike a Slack/Calendar entry, this one needs no fetch —
    the timer already fetched it — so it carries ``items`` directly and ``fetched: True``, and has
    no ``query``/``write_to``. ``None`` when there is nothing unclassified, so a tenant with no
    Fireflies key (or nothing new since last shown) gets no entry at all. Each item is now
    filtered by its own key (finding A), not by whether its transcript id has ever been seen, so a
    late item appended to an already-classified transcript still reaches this entry.
    """
    transcripts = _fireflies_transcripts(ctx)
    if not transcripts:
        return None
    classified = _fireflies_classified_ids(ctx)
    items = []
    for t in transcripts:
        tid = t.get("id")
        if tid is None:
            continue
        for action_item in (t.get("action_items") or []):
            if _fireflies_item_key(tid, action_item) in classified:
                continue
            items.append({"transcript_id": tid, "meeting": t.get("title"), "date": t.get("date"),
                         **action_item})
    if not items:
        return None
    return {"source": "fireflies", "reason": f"{len(items)} unclassified item(s)",
            "items": items, "fetched": True}


def _read_fireflies_pending(ctx: Context) -> list[dict]:
    """The item set the last turn-1 (JSON) call handed to turn 2, or ``[]``.

    See finding D in the module docstring: this is the ONLY input an acknowledgement marks
    classified, so a meeting that lands after turn 1 already ran cannot be swept in by turn 2's
    own, later recomputation of ``needs``.
    """
    path = _fireflies_pending_path(ctx)
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    items = data.get("items") if isinstance(data, dict) else None
    return items if isinstance(items, list) else []


def _write_fireflies_pending(ctx: Context, items: list[dict]) -> None:
    emit.write_file(_fireflies_pending_path(ctx), json.dumps({"items": items}))


def _mark_fireflies_classified(ctx: Context, items: list[dict]) -> None:
    """Record every Fireflies item in ``items`` as classified.

    ``items`` is exactly what an acknowledging call read from ``fireflies-pending.json`` (finding
    D) — never recomputed from the current snapshot, or a meeting landing mid-turn would be marked
    without ever being shown. The stored set is bounded to what the current snapshot still holds
    before the new items are unioned in, so it cannot grow past one fetch window's worth of items
    (finding A: this is now a set of item keys, not transcript ids).
    """
    transcripts = _fireflies_transcripts(ctx) or []
    current_keys = {_fireflies_item_key(t["id"], ai)
                    for t in transcripts if t.get("id") is not None
                    for ai in (t.get("action_items") or [])}
    ids = _fireflies_classified_ids(ctx) & current_keys
    ids |= {_fireflies_item_key(i["transcript_id"], i) for i in items if i.get("transcript_id") is not None}
    emit.write_file(_fireflies_classified_path(ctx), json.dumps({"ids": sorted(ids)}))


def compute_needs(ctx: Context, now: datetime) -> list[dict]:
    """``needs``: one entry per stale-or-missing ``NEEDS_SOURCES`` entry, plus one Fireflies entry
    when the snapshot holds action items not yet classified.

    See the module docstring for why only ``slack``/``calendar`` fetch through this loop, why
    Fireflies is appended separately with no ``query`` (Move 6), why the staleness rule is
    ``STALE_AFTER_MIN`` and not a new number, and why "never fetched" and "stale" are distinguished.
    A source the tenant does not list is skipped, never requested.
    """
    needs = []
    for source in NEEDS_SOURCES:
        if source not in ctx.tenant.sources:
            continue
        try:
            snap = snapshots.read(ctx.state_dir, source)
        except Exception as e:  # noqa: BLE001
            # Deliberately broad, and deliberately NOT a refusal. Review finding: a snapshot that
            # was not JSON raised an unhandled `JSONDecodeError`, and one that was a JSON list an
            # unhandled `AttributeError`, so a single corrupt connector file replaced the whole
            # morning brief with a traceback. "needs accompanies the brief, never replaces it" has
            # to hold for a broken file too -- and a file we cannot read is precisely one whose
            # fetch time we do not know, which is what needing a fetch means.
            snap, reason = None, f"unreadable ({type(e).__name__})"
        else:
            if snap is None:
                reason = "never fetched"
            elif not isinstance(snap, dict):
                snap, reason = None, f"unreadable (not an object: {type(snap).__name__})"
            else:
                try:
                    fetched = snapshots.parse_fetched_at(snap["fetched_at"])
                except (ValueError, TypeError, KeyError):
                    # Same reasoning: an unparseable `fetched_at` is an unknown fetch time, not a
                    # reason to refuse. It used to raise `Usage`, which cost the brief entirely.
                    snap, reason = None, "unreadable (fetched_at is not a UTC timestamp)"
                else:
                    age_min = (now - fetched).total_seconds() / 60
                    if not snap.get("ok", True):
                        # A recorded failure IS a reason to fetch again, however fresh it is: the
                        # snapshot is there but its `items` are empty by construction. It also
                        # reaches the reader as a `failed` line, but only via `sequence.json`, which
                        # a same-day rerun does not regenerate -- so that line can be stale where
                        # this one cannot.
                        reason = f"last fetch failed ({snap.get('error') or 'no reason recorded'})"
                    elif age_min <= STALE_AFTER_MIN:
                        continue
                    else:
                        reason = f"stale ({int(age_min)} min old)"
        needs.append({"source": source, "reason": reason, "query": _needs_query(source, snap),
                      "write_to": str(ctx.state_dir / f"ingest-{source}.json")})
    if "fireflies" in ctx.tenant.sources:
        fireflies_need = _fireflies_need(ctx)
        if fireflies_need is not None:
            needs.append(fireflies_need)
    return needs


def run_brief(ctx: Context, text: bool, max_lines: int = MAX_LINES, now: datetime | None = None, gh=None, lin=None,
             classified: list[str] | None = None):
    """Preflight, rank (if needed) and compose today's brief in one call; return lines or
    ``{"lines", "brief_path", "needs", "tracked"}``.

    ``gh``/``lin`` let a test substitute preflight's identity clients, exactly as ``preflight.run_preflight``
    already allows; left ``None`` (the CLI wiring), real clients are built and a failed pin exits 3.

    ``classified`` names sources whose handed-out items THIS call acknowledges as classified (fix
    round 2, finding D); currently only ``"fireflies"`` does anything with it. Ignored on a dry run
    — a dry run writes nothing, marking included. See the module docstring's finding-D section for
    why marking is this explicit rather than a side effect of a brief being shown.

    **Move 4 (``tracked``).** The tracked-side index reconcile needs (``reconcile.build_tracked_index``)
    rides in the same JSON reply as ``needs`` — turn 1's ``brief`` call, the only one that can afford
    it (see ``rabota.reconcile``'s module docstring). It costs a re-read of the two small snapshot
    files already on disk, never a fetch, so it is built unconditionally in JSON mode; ``--text`` is
    the human/terminal path and has no line shape for structured data, so it skips the read entirely.

    **Move 5 (``ctx.dry_run``, DO-742).** With it set, nothing is written — not ``sequence.json``/
    ``.md``, not ``brief.md``, not ``last-brief.json`` — and the JSON return's ``brief_path`` is
    ``None`` rather than a path to a file that does not exist. Everything else (the printed lines,
    ``needs``, ``tracked``) is computed exactly as a real run would compute it; see the module
    docstring for why preflight itself is not skipped.
    """
    check_max_lines(max_lines)                  # a usage error must not leave a brief.md behind
    check_classified(classified, text)          # likewise, before preflight or any write
    preflight_cmd.run_command(ctx, gh=gh, lin=lin)   # exit 3 on a failed identity pin, exactly as `rabota preflight`
    day = ctx.state_dir / ctx.today.isoformat()
    seq_path = day / "sequence.json"
    if seq_path.exists():
        seq = json.loads(seq_path.read_text())
    elif ctx.dry_run:
        # The same ranked answer `run_rank` would produce, without its writes (DO-742) -- a dry
        # run's line, `dry-run: nothing written`, would be false if this branch wrote sequence.json.
        seq = rank_cmd.compute_sequence(ctx)
    else:
        day.mkdir(parents=True, exist_ok=True)
        run_rank(ctx)
        seq = json.loads(seq_path.read_text())
    plan = _read_json(ctx.state_dir / "inbox-plan.json")
    summary_path = ctx.state_dir / "inbox-summary.txt"
    inbox_summary = summary_path.read_text().strip() if summary_path.exists() else None
    last_path = day / "last-brief.json"
    previous = _read_json(last_path)
    now = now or datetime.now(timezone.utc)

    # Finding D: acknowledge BEFORE `compute_needs` builds the entry that feeds this call's own
    # alert lines, so a call that just marked items classified does not turn around and tell the
    # reader they still need classifying (finding B). `_read_fireflies_pending` returns exactly
    # what the most recent turn-1 (JSON) call handed out -- never this call's own recomputation --
    # so a meeting landing between turn 1 and turn 2 cannot be marked by an ack that never saw it.
    acknowledge_fireflies = bool(classified) and "fireflies" in classified and not ctx.dry_run
    if acknowledge_fireflies:
        _mark_fireflies_classified(ctx, _read_fireflies_pending(ctx))
        _write_fireflies_pending(ctx, [])

    needs = compute_needs(ctx, now)     # before any write: a half-rewritten brief.md is worse than none

    if not ctx.dry_run and not acknowledge_fireflies and not text:
        # This is a turn-1 (JSON) call: record exactly the Fireflies item set it is handing out,
        # so a LATER acknowledgement marks only that set. A `--text` call -- acknowledging or not
        # -- must never write this file: turn 2's own recomputation of `needs` can already see a
        # meeting that landed mid-turn, and letting that call refresh "what was handed out" would
        # let the acknowledgement right after it mark an item nobody was ever shown.
        fireflies_entry = next((n for n in needs if n.get("source") == "fireflies" and n.get("fetched")), None)
        _write_fireflies_pending(ctx, fireflies_entry["items"] if fireflies_entry else [])

    health = reconcile.snapshot_health(ctx, now)     # in BOTH modes: see `snapshot_health`
    if ctx.dry_run:
        lines = terminal_lines(seq, inbox_summary, previous, max_lines=max_lines, brief_path=None,
                               now=now, needs=needs, health=health, dry_run=True)
        if text:
            return lines
        tracked = reconcile.build_tracked_index(ctx, now) if needs else None
        return {"lines": lines, "brief_path": None, "needs": needs, "tracked": tracked}
    day.mkdir(parents=True, exist_ok=True)
    brief_path = day / "brief.md"
    emit.write_file(brief_path, compose_markdown(seq, plan, _syncs(ctx)))     # guarded: a sync error may echo a token
    lines = terminal_lines(seq, inbox_summary, previous, max_lines=max_lines, brief_path=str(brief_path),
                           now=now, needs=needs, health=health)
    # `last-brief.json` records what the reader was SHOWN; it is what makes the next call print a
    # delta instead of the list. The CLI cannot see a caller's terminal, so it infers "shown" from
    # the two shapes the cycle actually has, and needs both halves:
    #
    #   * `--text` asks for lines for a human, so they are printed. Always record.
    #   * JSON asks for data, and the cycle prints its `lines` only when `needs` is empty -- with
    #     `needs` non-empty it prints nothing, fetches, and calls `brief` again.
    #
    # Measured regression (#240): recording on the JSON call with `needs` non-empty made that
    # second call a same-day rerun, so the one screen the reader got was `no change since HH:MM`
    # and NOT A SINGLE RANKED ITEM -- the brief had deleted itself. Review finding on that fix:
    # gating on `needs` alone was the mirror-image error. A connector with no session support keeps
    # `needs` non-empty forever, so the `--text` screen that WAS shown went unrecorded and every
    # later call re-ran the whole two-round-trip cycle instead of settling to a delta.
    if text or not needs:
        emit.write_file(last_path, json.dumps({"keys": [i["key"] for i in seq["items"]], "generated_at": seq["generated_at"]}))
        # Cross-day marker (Move 6): `commands.sync.fireflies_since` reads this to derive its fetch
        # window from the invariant instead of a fixed number of days (F2), and it needs to survive
        # a day boundary where the day-scoped `last_path` above does not exist yet. Written at the
        # exact same "this WAS shown" gate as `last_path`, for the same reason.
        emit.write_file(ctx.state_dir / LAST_SHOWN_FILE, json.dumps({"generated_at": seq["generated_at"]}))
        # Fireflies classification is NOT recorded here any more (fix round 2, finding D): being
        # shown used to be the proxy for "turn 2 actually classified these", but a bare
        # `rabota --text brief` is shown too, and never classified anything. Marking now happens
        # only via the explicit `classified` acknowledgement above.
    if text:
        return lines
    # `tracked` only when something is actually going to be reconciled. Reconcile classifies
    # commitments found in the CONNECTOR items, and those arrive only via a fetch that `needs`
    # asked for -- so with `needs` empty there is nothing new to classify, and the index would be
    # ~9 KB of context bought for nothing on every brief of an already-fetched morning (review
    # finding: it was built unconditionally, including on a "no change since HH:MM" rerun).
    tracked = reconcile.build_tracked_index(ctx, now) if needs else None
    return {"lines": lines, "brief_path": str(brief_path), "needs": needs, "tracked": tracked}


def _build(sub):
    p = sub.add_parser("brief", help="≤12 next actions; narrative to brief.md")
    p.add_argument("--max-lines", type=int, default=MAX_LINES,
                   help=f"cap on printed lines, at least 1 (default {MAX_LINES}); a wrapper that prepends a line passes one fewer")
    p.add_argument("--classified", action="append", default=[], choices=CLASSIFIABLE_SOURCES,
                   help="source(s) whose handed-out items this call acknowledges as classified "
                        "(fix round 2, finding D); requires --text")


cli.register("brief", _build,
             lambda ns: run_brief(Context.from_namespace(ns), ns.text, ns.max_lines, classified=ns.classified))
