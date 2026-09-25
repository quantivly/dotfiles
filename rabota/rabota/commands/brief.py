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

**Move 2 (``needs``, not a failure).** ``slack``, ``calendar`` and ``fireflies`` are never
fetched by the CLI itself (``sync.FETCHED_SOURCES`` is only ``linear``/``github`` — those two
are the 30-minute timer's job, and a stale one of those is a job for ``precompute``/``sync``,
not for an agent to hand-fetch). For the other three, ``run_brief`` computes ``needs``: one
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
"""
import json
from datetime import datetime, timezone
from pathlib import Path

from rabota import cli, emit, errors, reconcile, snapshots
from rabota.commands import preflight as preflight_cmd
from rabota.commands.rank import run_rank
from rabota.context import Context

MAX_LINES = 12
STALE_AFTER_MIN = 60          # twice the pre-compute timer's 30-minute period; also the "needs" staleness rule below
TITLE_MAX = 60
LINE_MAX = 120
NEEDS_SOURCES = ("slack", "calendar", "fireflies")    # never fetched by the CLI itself; see module docstring


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
    """
    lines = [f"! {s} failed — list is partial" for s in seq.get("failed_sources", [])]
    for n in (needs or []):
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
                   needs: list[dict] | None = None) -> list[str]:
    """The ≤``max_lines`` terminal lines; with ``previous`` (last-brief.json) only the deltas print.

    One ``!`` line per failed source and per ``needs`` entry (see ``compute_needs`` and
    ``_alert_lines``), reusing one vocabulary rather than two. What gets sacrificed when the lines
    do not fit is ``_assemble``'s job, and the no-change rerun goes through it too -- it used to
    return ``footer[-1:]``, which swallowed every alert on the path most likely to be taken twice
    in a morning.
    """
    check_max_lines(max_lines)
    head = []
    if now is not None:
        stale = staleness_line(seq, now)
        if stale:
            head.append(stale)
    alerts = _alert_lines(seq, needs)
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
    if source == "fireflies":
        return f"action items since {snap['fetched_at']}" if snap else "action items"
    raise ValueError(f"no needs query for {source!r}")


def compute_needs(ctx: Context, now: datetime) -> list[dict]:
    """``needs``: one ``{"source", "reason", "query", "write_to"}`` per stale-or-missing ``NEEDS_SOURCES`` entry.

    See the module docstring for why only ``slack``/``calendar``/``fireflies`` can appear, why the
    staleness rule is ``STALE_AFTER_MIN`` and not a new number, and why "never fetched" and "stale"
    are distinguished. A source the tenant does not list is skipped, never requested.
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
    return needs


def run_brief(ctx: Context, text: bool, max_lines: int = MAX_LINES, now: datetime | None = None, gh=None, lin=None):
    """Preflight, rank (if needed) and compose today's brief in one call; return lines or
    ``{"lines", "brief_path", "needs", "tracked"}``.

    ``gh``/``lin`` let a test substitute preflight's identity clients, exactly as ``preflight.run_preflight``
    already allows; left ``None`` (the CLI wiring), real clients are built and a failed pin exits 3.

    **Move 4 (``tracked``).** The tracked-side index reconcile needs (``reconcile.build_tracked_index``)
    rides in the same JSON reply as ``needs`` — turn 1's ``brief`` call, the only one that can afford
    it (see ``rabota.reconcile``'s module docstring). It costs a re-read of the two small snapshot
    files already on disk, never a fetch, so it is built unconditionally in JSON mode; ``--text`` is
    the human/terminal path and has no line shape for structured data, so it skips the read entirely.
    """
    check_max_lines(max_lines)                  # a usage error must not leave a brief.md behind
    preflight_cmd.run_command(ctx, gh=gh, lin=lin)   # exit 3 on a failed identity pin, exactly as `rabota preflight`
    day = ctx.state_dir / ctx.today.isoformat()
    day.mkdir(parents=True, exist_ok=True)
    seq_path = day / "sequence.json"
    if not seq_path.exists():
        run_rank(ctx)
    seq = json.loads(seq_path.read_text())
    plan = _read_json(ctx.state_dir / "inbox-plan.json")
    summary_path = ctx.state_dir / "inbox-summary.txt"
    inbox_summary = summary_path.read_text().strip() if summary_path.exists() else None
    brief_path = day / "brief.md"
    last_path = day / "last-brief.json"
    previous = _read_json(last_path)
    now = now or datetime.now(timezone.utc)
    needs = compute_needs(ctx, now)     # before any write: a half-rewritten brief.md is worse than none
    emit.write_file(brief_path, compose_markdown(seq, plan, _syncs(ctx)))     # guarded: a sync error may echo a token
    lines = terminal_lines(seq, inbox_summary, previous, max_lines=max_lines, brief_path=str(brief_path),
                           now=now, needs=needs)
    emit.write_file(last_path, json.dumps({"keys": [i["key"] for i in seq["items"]], "generated_at": seq["generated_at"]}))
    if text:
        return lines
    tracked = reconcile.build_tracked_index(ctx, now)
    return {"lines": lines, "brief_path": str(brief_path), "needs": needs, "tracked": tracked}


def _build(sub):
    p = sub.add_parser("brief", help="≤12 next actions; narrative to brief.md")
    p.add_argument("--max-lines", type=int, default=MAX_LINES,
                   help=f"cap on printed lines, at least 1 (default {MAX_LINES}); a wrapper that prepends a line passes one fewer")


cli.register("brief", _build, lambda ns: run_brief(Context.from_namespace(ns), ns.text, ns.max_lines))
