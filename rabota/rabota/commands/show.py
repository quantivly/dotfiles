"""``rabota show``: print the current sequence and inbox plan with their stamps (DO-872).

nanoclaw's laptop agent reads rabota only through read-only subcommands (``escalations --open``
is the precedent, DO-815), never through rabota's files, and until this command nothing printed
the newest ``sequence.json`` or ``inbox-plan.json`` without recomputing them: ``rank`` and
``inbox plan`` both write. This printer is the bridge's contract for the Sol Linear workspace
design (nanoclaw ``docs/superpowers/specs/2026-11-03-sol-linear-workspace-design.md`` §2.1):
the server shows rabota's rank with its age and never ranks on its own.

It is a pure reader. Both files were written through ``emit.write_file``, which refuses a secret
rather than redacting, so nothing is redacted here; nothing is written, nothing notifies, there
is no network and no model. The one process it runs is ``systemctl --user show`` for the
precompute timer's next elapse, the way ``doctor`` reads units, so the server learns rabota's
window from the push rather than from a mirrored constant.

The sequence is the newest dated directory that holds a ``sequence.json``, verbatim with its
own ``generated_at``: on a Sunday that is Friday's rank with Friday's stamp, which the server
shows as age. No such directory is an explicit arm, never an error. Items print once per key,
first occurrence first (bucket 1 held one row per notification on a thread, 83 rows over 28
keys on 2026-11-03; DO-876 gives the rank the same rule), and the per-bucket counts count what
is printed.
"""
import json
import re
from datetime import datetime
from pathlib import Path

from rabota import cli, errors
from rabota.commands.doctor import parse_show
from rabota.context import Context
from rabota.snapshots import FETCHED_AT_FORMAT
from rabota.store import now

SCHEMA = 1

# The same cap nanoclaw's wire applies per tenant (``RABOTA_MAX_ROWS_PER_TENANT``); the agent cuts
# text to its own caps and records the cut, so this printer cuts rows only, never text.
MAX_ROWS = 25

SEQUENCE_FILE = "sequence.json"
PLAN_FILE = "inbox-plan.json"
DAY_DIR = re.compile(r"\d{4}-\d{2}-\d{2}")

# The arms a reader must handle before any field: the day directory or the plan is absent.
NO_SEQUENCE = {"unavailable": "no-sequence"}
NO_PLAN = {"unavailable": "no-plan"}

# Exactly ``rank._item``'s keys, named here so a field rank adds later does not travel unseen.
SEQUENCE_ROW_FIELDS = ("bucket", "key", "title", "url", "waiting_on", "why_now", "rationale", "source")
# A subset of ``inbox.buckets.Item``: what a triage decision on the phone needs, nothing more.
PLAN_ROW_FIELDS = ("notification_id", "issue_identifier", "type", "bucket", "tier", "reason", "url",
                   "created_at", "title")
# The plan's buckets whose rows are decisions (spec §2.1); the rest cross as totals only.
DECISION_BUCKETS = ("confirm_required", "project_prompt", "assignment_new")
BATCHES = ("due_policy", "stale_backlog")

TIMER_SHOW_PROPERTY = "NextElapseUSecRealtime"
# ``systemctl show --timestamp=utc`` prints ``Wed 2026-11-04 05:00:40 UTC``; the weekday is dropped
# before parsing so the locale's day names never decide whether the stamp parses.
TIMER_STAMP_FORMAT = "%Y-%m-%d %H:%M:%S UTC"


def timer_unit(tenant: str) -> str:
    return f"rabota-precompute@{tenant}.timer"


def timer_show_argv(tenant: str) -> list[str]:
    return ["systemctl", "--user", "show", timer_unit(tenant), "-p", TIMER_SHOW_PROPERTY, "--timestamp=utc"]


def parse_timer_stamp(value: str) -> str | None:
    """``Wed 2026-11-04 05:00:40 UTC`` → ``2026-11-04T05:00:40Z``; anything else (an absent or
    inactive unit prints an empty value) is ``None``, which the server reads as "nothing known
    about the timer"."""
    _weekday, _sep, rest = value.strip().partition(" ")
    try:
        return datetime.strptime(rest, TIMER_STAMP_FORMAT).strftime(FETCHED_AT_FORMAT)
    except ValueError:
        return None


def next_elapse(ctx: Context) -> str | None:
    """The precompute timer's next elapse as a UTC stamp, or ``None`` when the unit is absent,
    inactive, or ``systemctl`` cannot be asked."""
    res = ctx.runner.run(timer_show_argv(ctx.tenant.name))
    if not res.ok:
        return None
    return parse_timer_stamp(parse_show(res.out).get(TIMER_SHOW_PROPERTY, ""))


def newest_sequence_path(state_dir: Path) -> Path | None:
    """The ``sequence.json`` of the newest dated directory that has one, or ``None``."""
    if not state_dir.is_dir():
        return None
    days = sorted((d for d in state_dir.iterdir() if d.is_dir() and DAY_DIR.fullmatch(d.name)), reverse=True)
    for day in days:
        if (day / SEQUENCE_FILE).is_file():
            return day / SEQUENCE_FILE
    return None


def _read_json_object(path: Path, required: tuple[str, ...]) -> dict:
    """``path`` parsed as a JSON object carrying every ``required`` key; anything else is an
    error naming the file and the reason (exit 5), never a traceback and never a partial print."""
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as e:
        raise errors.RabotaError(f"{path}: unparseable: {e}") from None
    if not isinstance(data, dict):
        raise errors.RabotaError(f"{path}: unparseable: not a JSON object")
    missing = [k for k in required if k not in data]
    if missing:
        raise errors.RabotaError(f"{path}: unparseable: missing {', '.join(missing)}")
    return data


def _project(row: dict, fields: tuple[str, ...]) -> dict:
    return {f: row.get(f) for f in fields}


def sequence_part(path: Path | None) -> dict:
    if path is None:
        return dict(NO_SEQUENCE)
    seq = _read_json_object(path, ("generated_at", "items", "decisions"))
    distinct, seen = [], set()
    for row in seq["items"]:
        if not isinstance(row, dict) or row.get("key") in seen:
            continue
        seen.add(row.get("key"))
        distinct.append(_project(row, SEQUENCE_ROW_FIELDS))
    counts: dict[str, int] = {}
    for row in distinct:
        bucket = str(row["bucket"])
        counts[bucket] = counts.get(bucket, 0) + 1
    return {"generated_at": seq["generated_at"], "failed_sources": list(seq.get("failed_sources") or []),
            "counts": counts, "decisions": len(seq["decisions"]), "items": distinct[:MAX_ROWS]}


def plan_part(path: Path) -> dict:
    if not path.is_file():
        return dict(NO_PLAN)
    plan = _read_json_object(path, ("generated_at", "unread_total", "totals", "buckets", "batches"))
    buckets = {}
    for name in DECISION_BUCKETS:
        rows = [r for r in (plan["buckets"].get(name) or []) if isinstance(r, dict)]
        buckets[name] = {"rows": [_project(r, PLAN_ROW_FIELDS) for r in rows[:MAX_ROWS]],
                         "omitted": max(0, len(rows) - MAX_ROWS)}
    batches = {}
    for name in BATCHES:
        issues = (plan["batches"].get(name) or {}).get("issues") or []
        identifiers = [i.get("identifier") for i in issues if isinstance(i, dict)]
        batches[name] = {"count": len(identifiers), "identifiers": identifiers[:MAX_ROWS]}
    return {"generated_at": plan["generated_at"], "unread_total": plan["unread_total"],
            "totals": dict(plan["totals"]), "buckets": buckets, "batches": batches}


def answers_part() -> dict:
    """Pending and applied answers recorded from Sol: DO-877's rows. Until it lands there is
    nothing to record and both lists are empty, so the field set is already the contract's."""
    return {"pending": [], "applied": []}


def run_show(ctx: Context) -> dict:
    return {"schema": SCHEMA, "at": now(), "next_elapse": next_elapse(ctx),
            "sequence": sequence_part(newest_sequence_path(ctx.state_dir)),
            "plan": plan_part(ctx.state_dir / PLAN_FILE),
            "answers": answers_part()}


def _sequence_lines(sequence: dict, next_run: str | None) -> list[str]:
    if "unavailable" in sequence:
        return [f"sequence: {sequence['unavailable']}"]
    head = f"ranked {sequence['generated_at']}"
    if next_run:
        head += f" · next run {next_run}"
    if sequence["failed_sources"]:
        head += f" · failed: {', '.join(sequence['failed_sources'])}"
    counts = " · ".join(f"bucket {b}: {n}" for b, n in sorted(sequence["counts"].items()))
    lines = [head, f"{counts} · {sequence['decisions']} decisions" if counts else f"{sequence['decisions']} decisions"]
    for i, row in enumerate(sequence["items"], 1):
        who = f" (waiting on {row['waiting_on']})" if row.get("waiting_on") else ""
        lines.append(f"{i}. [b{row['bucket']}] {row['key']} — {row['title']}{who}: {row['why_now']}")
    return lines


def _plan_lines(plan: dict) -> list[str]:
    if "unavailable" in plan:
        return [f"plan: {plan['unavailable']}"]
    buckets = " · ".join(f"{b} {plan['buckets'][b]['omitted'] + len(plan['buckets'][b]['rows'])}" for b in DECISION_BUCKETS)
    batches = " · ".join(f"{b} {plan['batches'][b]['count']}" for b in BATCHES)
    return [f"plan {plan['generated_at']} · {plan['unread_total']} unread · {buckets} · {batches}"]


def lines(report: dict) -> list[str]:
    answers = report["answers"]
    return (_sequence_lines(report["sequence"], report["next_elapse"]) + _plan_lines(report["plan"])
            + [f"answers: {len(answers['pending'])} pending · {len(answers['applied'])} applied"])


def _build(sub):
    p = sub.add_parser("show", help="print the current sequence and inbox plan (read-only; never writes)")
    # The default already is JSON. The flag exists so a scripted caller's argv states the contract
    # it depends on, the way nanoclaw's agent pins its argv list by test.
    p.add_argument("--json", action="store_true", help="JSON (the default; named for scripted callers)")


def _run(ns):
    report = run_show(Context.from_namespace(ns))
    return lines(report) if ns.text else report


cli.register("show", _build, _run)
