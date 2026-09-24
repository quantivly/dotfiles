"""The output contract, as code: ≤12 lines, deltas on rerun, narrative in ``brief.md``.

Line order: a staleness warning when the sequence is older than ``STALE_AFTER_MIN`` (the
30-minute pre-compute timer has then missed at least once), the ranked items, one line per
failed source, the inbox summary, and ``brief: <path>``. Everything counts toward the cap,
and ``--max-lines`` lets a wrapper such as ``sol brief`` prepend its own line and still show
twelve. On a same-day rerun only ``+``/``-`` deltas print, or ``no change since HH:MM``.

The cap applies on EVERY path, the no-change one included (review finding k4: it was never
sliced, so ``--max-lines 1`` printed two lines). ``--max-lines 0`` is a usage error, not an
empty brief — a zero-line brief is not a brief — and so is a negative cap. A ``generated_at``
that does not parse is a usage error naming the file, never an unhandled ``ValueError``.
"""
import json
from datetime import datetime, timezone
from pathlib import Path

from rabota import cli, emit, errors, snapshots
from rabota.commands.rank import run_rank
from rabota.context import Context

MAX_LINES = 12
STALE_AFTER_MIN = 60          # twice the pre-compute timer's 30-minute period
TITLE_MAX = 60
LINE_MAX = 120


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


def terminal_lines(seq: dict, inbox_summary: str | None, previous: dict | None, max_lines: int = MAX_LINES,
                   brief_path: str | None = None, now: datetime | None = None) -> list[str]:
    """The ≤``max_lines`` terminal lines; with ``previous`` (last-brief.json) only the deltas print."""
    check_max_lines(max_lines)
    head = []
    if now is not None:
        stale = staleness_line(seq, now)
        if stale:
            head.append(stale)
    footer = [f"! {s} failed — list is partial" for s in seq.get("failed_sources", [])]
    if inbox_summary:
        footer.append(inbox_summary)
    if brief_path:
        footer.append(f"brief: {brief_path}")
    keys = [i["key"] for i in seq["items"]]
    if previous is not None:
        added = [k for k in keys if k not in previous["keys"]]
        removed = [k for k in previous["keys"] if k not in keys]
        if not added and not removed:
            return (head + [f"no change since {previous['generated_at'][11:16]}"] + footer[-1:])[:max_lines]
        body = [f"+ {k}" for k in added] + [f"- {k}" for k in removed]
        return (head + body + footer)[:max_lines]
    room = max(0, max_lines - len(head) - len(footer))
    body = [_fmt(n, i) for n, i in enumerate(seq["items"][:room], 1)]
    return (head + body + footer)[:max_lines]


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


def run_brief(ctx: Context, text: bool, max_lines: int = MAX_LINES, now: datetime | None = None):
    """Write today's ``brief.md`` and ``last-brief.json``; return the lines (``--text``) or ``{"lines", "brief_path"}``."""
    check_max_lines(max_lines)                  # a usage error must not leave a brief.md behind
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
    emit.write_file(brief_path, compose_markdown(seq, plan, _syncs(ctx)))     # guarded: a sync error may echo a token
    last_path = day / "last-brief.json"
    previous = _read_json(last_path)
    lines = terminal_lines(seq, inbox_summary, previous, max_lines=max_lines, brief_path=str(brief_path),
                           now=now or datetime.now(timezone.utc))
    emit.write_file(last_path, json.dumps({"keys": [i["key"] for i in seq["items"]], "generated_at": seq["generated_at"]}))
    return lines if text else {"lines": lines, "brief_path": str(brief_path)}


def _build(sub):
    p = sub.add_parser("brief", help="≤12 next actions; narrative to brief.md")
    p.add_argument("--max-lines", type=int, default=MAX_LINES,
                   help=f"cap on printed lines, at least 1 (default {MAX_LINES}); a wrapper that prepends a line passes one fewer")


cli.register("brief", _build, lambda ns: run_brief(Context.from_namespace(ns), ns.text, ns.max_lines))
