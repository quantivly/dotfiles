"""``rabota schedule tick``, and everything that happens to a run after it is declared (DO-817).

Design: ``docs/superpowers/specs/2026-10-11-scheduled-agent-runs-design.md`` — §4 firing, §6 the
consumer, §7 command runs. ``commands/schedule.py`` DECLARES a run; this module fires, settles,
records, escalates and exports it. ``rabota-schedule@<tenant>.timer`` calls ``run_tick`` every ten
minutes, and ``rabota answer`` calls ``run_answer`` for an escalation the tick raised.

THE TICK takes an ``flock`` and works in four steps, in this order. Each row is isolated: one that
fails is reported, the others still move, and the tick exits 4.

1. **Settle.** A ``running`` command row whose unit is no longer live is settled from its out_dir,
   from the exit status the unit's wrapper left there: 0 ``pass``, 1 ``fail``, anything else, or
   none at all, ``could-not-run``. When ``systemctl`` cannot say which units are live, nothing is
   settled: not knowing is not finished.
2. **Process the outcome**, ordered so that everything before the row write is idempotent. A crash
   anywhere re-runs the step on the next tick and changes nothing twice: ``result.md`` into the
   out_dir, the keyed section into the record, the escalation (looked up by kind, subject and
   evidence before a new one is raised), and LAST the conditional row write. A ``could-not-run``
   below ``max_attempts`` goes back to ``pending`` at ``now + RETRY_DELAY`` and raises nothing.
   ``fail`` is a result, never re-run.
3. **Expire** every ``pending`` row past ``expires_at``, and escalate each, naming its last reason.
4. **Dispatch** every due ``pending`` row. A command row is checked first: its frozen payload must
   sit in its own schedule directory and still hash to the declared sha256, and its cwd must exist.
   A row that fails a check is REFUSED, terminally, with a critical escalation, because neither
   fault heals itself and a retry would only delay the news. A row that passes is CLAIMED in one
   ``BEGIN IMMEDIATE`` conditional write that stores its attempt, unit name and out_dir, and only
   then started with ``systemd-run``. An agent row is never dispatched (DO-820 brings its
   executor): it is DEFERRED with ``AGENT_DEFERRAL`` as its ``last_reason``. A deferral is not an
   attempt, so the row stays visible in ``schedule list`` and, if no executor arrives in time,
   expires and escalates by the ordinary path.

**Crash recovery.** The claim is written before ``systemd-run``, so the tick can die anywhere after
it without losing the run. The next tick finds a ``running`` row and asks systemd about its unit. A
live unit is left alone. One that finished is settled from what it left: adopted, not re-run. One
that never started, or whose ``systemd-run`` failed, left no exit status, and settles as one
``could-not-run`` attempt. Nothing is re-dispatched blind: a new attempt has a new unit name, and
systemd refuses a duplicate.

**The command executor** (§7) is a transient ``rabota-sched-<tenant>-<id>-a<n>.service`` under
``MemoryMax``, ``RuntimeMaxSec``, ``Nice=10`` and ``KillMode=control-group``, with ``PATH`` set to
include ``~/.local/bin`` (DO-712: a transient unit gets the user manager's minimal one). It gets no
seat and passes no budget gate. It runs the FROZEN script through ``WRAPPER``, a fixed ``/bin/sh``
line whose only job is to write the script's exit status into the out_dir, atomically, once it
exits. Every value reaches the wrapper as an argument, never as script text, and
``--expand-environment=no`` stops systemd rewriting a ``$`` in any of them. A ``RuntimeMaxSec`` or
``MemoryMax`` kill takes the wrapper with it and leaves no exit status, which is the
``could-not-run`` the design asks for.

**The record** (§6 step 3) gets one section per settled attempt, keyed
``<!-- rabota-schedule:<id>:<attempt> -->`` (``expired``, ``refused`` or ``decided:<esc>`` in place
of the attempt for a section that is not one), and skipped when the key is already there. It goes
immediately BEFORE a ``<!-- rabota-schedule-results -->`` marker when the file has one, through
``emit.replace_file`` (an atomic rewrite), so results stay in the order they happened and the marker
stays where the next one goes. Otherwise it goes at the end, through ``emit.append_file``. Both
guard the text. The command's output arrives redacted (``secrets.redact``), so a script that prints
a protected value still leaves its section, and no ``<!--`` survives in a body, so output can never
forge a key or move the marker. A record that git tracks by now is not written: ``add``'s rule,
asked again. A record that cannot be written fails the tick and turns even a ``pass`` into an
escalation, because otherwise its result would be lost with nothing to show for it.

**Escalations** (§6 step 4). ``OUTCOMES`` maps each of the six outcomes to the status it leaves and
the urgency of its escalation. ``pass`` raises none; ``fail``, ``denied``, ``expired`` and
``could-not-run`` are critical; ``inconclusive`` is normal. "Exactly one decision per outcome" is
therefore a table, not a branch. ``escalate.run_escalate`` notifies once, at creation, and this
module reaches it at most once per escalation, because the lookup before it turns a repeat into a
read.

**Answers** (§6 step 5). An option executes its DECLARED action and nothing else:

- ``rerun[:+<n>]`` enqueues exactly one new run. It is a fresh row, due ``now + <n>``, whose payload
  is frozen again from this run's frozen copy after that copy's hash is checked.
- ``cancel-followups`` cancels every pending run whose payload was frozen from one of this run's
  files (a rerun, or DO-820's ``--then-prompt`` child), and clears ``then_on``.
- ``none``, and any label the declaration does not map, executes nothing.

The action is looked up from the stored declaration by label. The label's text is never parsed, so
an option that reads "rerun" or spells a rollback command executes nothing. The action's rows and
the answer commit in one transaction, after every refusal has been asked.

**The export** (§6), ``~/.local/state/rabota/schedule-export.json``, is rewritten atomically by every
tick, every ``add`` and ``cancel``, and every answer to a scheduled run. It covers every tenant, each
read from its own store and none created. It is versioned and redacted field by field. It carries
titles, statuses, outcomes, reasons, and each escalation's question and options, and never a result
body or a path to one.
"""
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from rabota import census, emit, errors, secrets, store
from rabota.commands import escalate
from rabota.commands import schedule as decl

ESC_KIND = "scheduled-run"
LOCK = "schedule-tick.lock"
EXIT_FILE, STDOUT, STDERR, RESULT = "exit-status", "stdout.log", "stderr.log", "result.md"
MARKER = "<!-- rabota-schedule-results -->"
TAIL_BYTES = 4096                 # of each output stream, into result.md and the record
# ActiveState values a unit is still running in. `deactivating` counts: a RuntimeMaxSec kill sits
# there for up to TimeoutStopSec, and settling it then would read an exit status not yet written.
LIVE = ("active", "activating", "deactivating", "reloading", "refreshing")
EXPORT_VERSION = 1
EXPORT_WINDOW = timedelta(days=30)   # a settled row stays in the export this long after it ended
AGENT_DEFERRAL = ("deferred: agent runs have no executor until phase 2 (DO-820); it stays pending, "
                  "so it expires and escalates if none arrives in time")
# $0 names the process, $1 is the exit-status path, the rest is the frozen script and its args.
WRAPPER = r'f=$1; shift; "$@"; rc=$?; printf "%s\n" "$rc" > "$f.tmp" && mv -f "$f.tmp" "$f"'

# outcome -> (the status it leaves the row in, its escalation's urgency; None raises none)
OUTCOMES = {"pass": ("done", None), "fail": ("done", "critical"), "inconclusive": ("done", "normal"),
            "denied": ("done", "critical"), "could-not-run": ("failed", "critical"),
            "expired": ("expired", "critical")}


def command_outcome(code: int | None) -> str:
    """§7: 0 is pass, 1 is fail, and 2, any other code, or no exit status at all is could-not-run."""
    return {0: "pass", 1: "fail"}.get(code, "could-not-run")


def command_unit(tenant: str, sched_id: str, attempt: int) -> str:
    return f"rabota-sched-{tenant}-{sched_id}-a{attempt}.service"


def unit_path() -> str:
    """A command unit's whole PATH. systemd has no prepend, so ``~/.local/bin`` is written in (DO-712)."""
    return f"{Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin"


def export_path() -> Path:
    return Path.home() / ".local" / "state" / "rabota" / "schedule-export.json"


def options_of(row: dict) -> list[dict]:
    """The declared ``[{"label", "action"}]``, or the §6 defaults when the declaration names none."""
    return row["options"] or [dict(o) for o in decl.DEFAULT_OPTIONS]


def _parse(iso: str) -> datetime:
    return datetime.fromisoformat(iso.replace("Z", "+00:00"))


def _redact(value):
    return secrets.redact(value, os.environ) if isinstance(value, str) else value


def _neutral(text: str) -> str:
    """No HTML comment can open inside a section body: output cannot forge a key or a marker."""
    return text.replace("<!--", "<! --")


def _error(e: Exception) -> str:
    return str(e) if isinstance(e, errors.RabotaError) else f"{type(e).__name__}: {e}"


@contextlib.contextmanager
def _flock(path: Path):
    """Yield True holding an exclusive lock on ``path``, or False at once if another tick holds it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        os.close(fd)        # closing the descriptor releases the lock


# --- the tick ----------------------------------------------------------------------------------

def run_tick(ctx, now: datetime | None = None) -> dict:
    """The timer's entry point: settle, expire, dispatch, export. ``now`` is a test seam."""
    if ctx.dry_run:
        raise errors.Usage("schedule tick has no --dry-run: it is the timer's entry point and every step "
                           "it takes writes; `rabota schedule list` shows the queue")
    now = now or datetime.now(timezone.utc)
    rep = {"tenant": ctx.tenant.name, "at": decl._iso(now), "settled": [], "expired": [], "refused": [],
           "dispatched": [], "deferred": [], "errors": []}
    with _flock(ctx.state_dir / LOCK) as held:
        if not held:
            return {**rep, "locked": "another tick holds the lock, so this one did nothing"}
        _settle(ctx, now, rep)
        _expire(ctx, now, rep)
        _dispatch(ctx, now, rep)
        try:
            rep["export"] = write_export(ctx.cfg, now, own=(ctx.tenant.name, ctx.state_dir))
        except Exception as e:      # noqa: BLE001 -- reported; the queue itself has moved
            rep["errors"].append({"step": "export", "id": None, "error": _error(e)})
    if rep["errors"]:
        raise errors.Partial(f"schedule tick for {ctx.tenant.name}: {len(rep['errors'])} failure(s)", rep["errors"])
    return rep


def _isolated(rep, step, sched_id, fn, *args):
    """Run one row's step; a failure is reported and never stops the next row."""
    try:
        fn(*args)
    except Exception as e:      # noqa: BLE001 -- see the docstring; the tick exits 4 on any of these
        rep["errors"].append({"step": step, "id": sched_id, "error": _error(e)})


def _settle(ctx, now, rep):
    running = ctx.store.list_schedules(ctx.tenant.name, "running")
    if not running:
        return
    units, unavailable = census.units(ctx.runner)
    if unavailable:
        rep["errors"].append({"step": "settle", "id": None,
                              "error": "systemctl --user could not list units, so no running run was "
                                       "settled: not knowing is not finished"})
        return
    live = {u["name"] for u in units if u.get("state") in LIVE}
    for row in running:
        if row["kind"] != "command":
            rep["errors"].append({"step": "settle", "id": row["id"],
                                  "error": "an agent run is running, and nothing settles one before DO-820"})
        elif row["unit"] not in live:
            _isolated(rep, "settle", row["id"], _settle_command, ctx, row, now, rep)


def _exit_status(out_dir: Path, now: datetime):
    """``(code, detail, ended)`` from the wrapper's exit-status file; ``code`` None when there is none."""
    p = out_dir / EXIT_FILE
    try:
        text, mtime = p.read_text().strip(), p.stat().st_mtime
    except FileNotFoundError:
        return None, None, now
    ended = datetime.fromtimestamp(mtime, timezone.utc)
    if not re.fullmatch(r"\d{1,3}", text):
        return None, f"its exit-status file holds {text[:40]!r}, not an exit code", ended
    return int(text), f"exit {int(text)}", ended


def _settle_command(ctx, row, now, rep):
    code, detail, ended = _exit_status(Path(row["out_dir"]), now)
    if row["started_at"]:
        ended = max(ended, _parse(row["started_at"]))     # never ended before it began (census's clamp)
    if detail is None:
        detail = (f"{row['unit']} is gone and left no exit status: killed by RuntimeMaxSec or MemoryMax, "
                  f"crashed, or never started")
    if row["last_reason"]:       # on a running row, only a failed systemd-run writes one
        detail += f" ({row['last_reason']})"
    _finish_attempt(ctx, row, command_outcome(code), detail, ended, now, rep)


def _finish_attempt(ctx, row, outcome, detail, ended, now, rep):
    attempt, most = row["attempt"], row["max_attempts"]
    retry = outcome == "could-not-run" and attempt < most
    out_dir = Path(row["out_dir"])
    out_dir.mkdir(parents=True, exist_ok=True)      # absent when the tick died between claim and start
    body = _result_md(row, outcome, detail, retry, ended, now)
    emit.write_file(out_dir / RESULT, body)
    heading = (f"{decl._local(decl._iso(ended))} scheduled run {row['id']}: {outcome}"
               + (f" (attempt {attempt} of {most}, retrying)" if retry else ""))
    record, record_error = _record_step(ctx, row, f"{row['id']}:{attempt}", f"## {heading}\n\n{body}", rep)
    eid = None
    if not retry:
        eid = _escalate_once(ctx, row, outcome, str(out_dir / RESULT), detail, record_error)
    if retry:
        fields = {"status": "pending", "not_before": decl._iso(now + decl.RETRY_DELAY),
                  "last_reason": f"attempt {attempt} of {most} could not run: {detail}; retrying"}
    else:
        fields = {"status": OUTCOMES[outcome][0], "outcome": outcome, "ended_at": decl._iso(ended),
                  "last_reason": detail, "escalation_id": eid}
    if not ctx.store.update_schedule_where(row["id"], {"status": "running", "unit": row["unit"]}, **fields):
        raise errors.RabotaError(f"{row['id']} stopped being running under {row['unit']} while it was "
                                 f"settled, so its row was left as it was")
    rep["settled"].append({"id": row["id"], "attempt": attempt, "outcome": outcome, "retry": retry,
                           "escalation": eid, "record": record})


def _tail(p: Path) -> tuple[str, bool]:
    """The last ``TAIL_BYTES`` of ``p``, decoded and redacted, and whether anything was cut."""
    try:
        size = p.stat().st_size
        with p.open("rb") as f:
            f.seek(max(0, size - TAIL_BYTES))
            data = f.read()
    except FileNotFoundError:
        return "", False
    return _redact(data.decode("utf-8", errors="replace")), size > TAIL_BYTES


def _fence(text: str) -> str:
    run = max((len(m) for m in re.findall(r"`+", text)), default=0)
    fence = "`" * max(3, run + 1)
    return f"{fence}text\n{text.rstrip()}\n{fence}"


def _result_md(row, outcome, detail, retry, ended, now) -> str:
    """``result.md`` for a command attempt: what ran, how it ended, and the tail of each stream."""
    out_dir = Path(row["out_dir"])
    nxt = f"; the next starts after {decl._local(decl._iso(now + decl.RETRY_DELAY))}" if retry else ""
    lines = [f"- **{outcome}**: {detail}",
             f"- attempt {row['attempt']} of {row['max_attempts']}{nxt}",
             f"- title: {row['title']}",
             f"- ran `{shlex.join([row['payload_path'], *(row['args'] or [])])}` in `{row['cwd']}` as "
             f"{row['unit']}, ended {decl._local(decl._iso(ended))}",
             f"- full output: {out_dir / STDOUT}, {out_dir / STDERR}"]
    parts = ["\n".join(lines)]
    for name in (STDOUT, STDERR):
        text, cut = _tail(out_dir / name)
        if text.strip():
            parts.append(f"{name}{f' (last {TAIL_BYTES} bytes)' if cut else ''}:\n\n{_fence(text)}")
    return _neutral("\n\n".join(parts)) + "\n"


def _expire(ctx, now, rep):
    for row in ctx.store.list_schedules(ctx.tenant.name, "pending"):
        if _parse(row["expires_at"]) <= now:
            _isolated(rep, "expire", row["id"], _expire_one, ctx, row, now, rep)


def _expire_one(ctx, row, now, rep):
    detail = f"it expired at {decl._local(row['expires_at'])} without a result"
    detail += (f"; last reason: {row['last_reason']}" if row["last_reason"]
               else "; it was never tried" if row["attempt"] == 0 else "")
    stamp = decl._local(decl._iso(now))
    _, record_error = _record_step(ctx, row, f"{row['id']}:expired",
                                   f"## {stamp} scheduled run {row['id']}: expired\n\n{_neutral(f'- **expired**: {detail}')}\n", rep)
    eid = _escalate_once(ctx, row, "expired", f"schedule {row['id']} expired at {row['expires_at']}", detail, record_error)
    if not ctx.store.update_schedule_where(row["id"], {"status": "pending", "attempt": row["attempt"]},
                                           status="expired", outcome="expired", ended_at=decl._iso(now),
                                           last_reason=detail, escalation_id=eid):
        raise errors.RabotaError(f"{row['id']} stopped being pending while it was expired; its row was left as it was")
    rep["expired"].append({"id": row["id"], "escalation": eid})


def _dispatch(ctx, now, rep):
    for row in ctx.store.list_schedules(ctx.tenant.name, "pending"):
        if _parse(row["not_before"]) > now or _parse(row["expires_at"]) <= now:
            continue        # not due yet; or past expiry, which step 3 has already reported
        if row["kind"] == "command":
            _isolated(rep, "dispatch", row["id"], _dispatch_command, ctx, row, now, rep)
        else:
            _isolated(rep, "dispatch", row["id"], _defer, ctx, row, AGENT_DEFERRAL, rep)


def _defer(ctx, row, reason, rep):
    """Leave the row pending with ``reason``; ``attempt`` is untouched, because a deferral is not one."""
    if row["last_reason"] != reason:
        ctx.store.update_schedule_where(row["id"], {"status": "pending"}, last_reason=reason)
    rep["deferred"].append({"id": row["id"], "reason": reason})


def _cannot_start(ctx, row) -> tuple[str, str] | None:
    """``(problem, the path it is about)`` when the row must not be started, else None."""
    p, home = Path(row["payload_path"]), ctx.state_dir / "schedules" / row["id"]
    if p.parent.resolve() != home.resolve():
        return f"its payload {p} is not in its own schedule directory {home}", str(p)
    try:
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
    except OSError as e:
        return f"its frozen payload {p} cannot be read ({e.strerror or e})", str(p)
    if digest != row["payload_sha256"]:
        return (f"its frozen payload {p} changed after it was frozen (sha256 {digest[:12]}, declared "
                f"{row['payload_sha256'][:12]}), so it was not run", str(p))
    if not Path(row["cwd"]).is_dir():
        return f"its cwd {row['cwd']} is not a directory", row["cwd"]
    return None


def command_argv(row: dict, unit: str, out_dir: Path) -> list[str]:
    """The ``systemd-run`` argv for one command attempt. Every value is an argv element, never text."""
    return ["systemd-run", "--user", "--collect", f"--unit={unit}", f"--working-directory={row['cwd']}",
            "--expand-environment=no", f"--setenv=PATH={unit_path()}",
            "-p", f"MemoryMax={row['memory_max']}", "-p", f"RuntimeMaxSec={row['timeout_s']}",
            "-p", "Nice=10", "-p", "KillMode=control-group",
            "-p", f"StandardOutput=append:{out_dir / STDOUT}", "-p", f"StandardError=append:{out_dir / STDERR}",
            "/bin/sh", "-c", WRAPPER, "rabota-sched", str(out_dir / EXIT_FILE),
            row["payload_path"], *(row["args"] or [])]


def _dispatch_command(ctx, row, now, rep):
    problem = _cannot_start(ctx, row)
    if problem is not None:
        _refuse(ctx, row, *problem, now, rep)
        return
    n = row["attempt"] + 1
    unit = command_unit(ctx.tenant.name, row["id"], n)
    out_dir = decl.out_root(ctx) / f"{row['id']}-a{n}"
    stamp = decl._iso(now)
    with ctx.store.transaction(immediate=True):
        claimed = ctx.store.update_schedule_where(
            row["id"], {"status": "pending", "attempt": row["attempt"]}, status="running", attempt=n,
            unit=unit, out_dir=str(out_dir), started_at=stamp, ended_at=None, last_reason=None, updated_at=stamp)
    if not claimed:
        return          # cancelled, or claimed elsewhere, since it was read: nothing to start
    out_dir.mkdir(parents=True, exist_ok=True)
    res = ctx.runner.run(command_argv(row, unit, out_dir), timeout=30)
    if not res.ok:
        why = f"systemd-run failed (exit {res.code}): {(res.err or res.out).strip()[:200]}"
        ctx.store.update_schedule_where(row["id"], {"status": "running", "unit": unit}, last_reason=why)
        raise errors.RabotaError(f"{why}; the next tick settles it as an attempt that could not run")
    rep["dispatched"].append({"id": row["id"], "attempt": n, "unit": unit})


def _refuse(ctx, row, problem, evidence, now, rep):
    """Settle a pending row that must not start: failed, could-not-run, escalated, never retried."""
    detail = f"refused to start: {problem}"
    stamp = decl._local(decl._iso(now))
    _, record_error = _record_step(ctx, row, f"{row['id']}:refused",
                                   f"## {stamp} scheduled run {row['id']}: could-not-run\n\n{_neutral(f'- **could-not-run**: {detail}')}\n", rep)
    eid = _escalate_once(ctx, row, "could-not-run", evidence, detail, record_error)
    if not ctx.store.update_schedule_where(row["id"], {"status": "pending", "attempt": row["attempt"]},
                                           status="failed", outcome="could-not-run", ended_at=decl._iso(now),
                                           last_reason=detail, escalation_id=eid):
        raise errors.RabotaError(f"{row['id']} stopped being pending while it was refused; its row was left as it was")
    rep["refused"].append({"id": row["id"], "reason": detail, "escalation": eid})


# --- the record and the escalation -------------------------------------------------------------

def _record(ctx, row, key: str, text: str) -> str | None:
    """Put ``text`` under ``key`` in the row's record; ``appended``, ``present``, or None for no record."""
    if not row["record"]:
        return None
    p = Path(row["record"])
    decl._refuse_tracked(ctx, [p])
    current = p.read_text()
    tag = f"<!-- rabota-schedule:{key} -->"
    if tag in current:
        return "present"
    block = f"{tag}\n{text.rstrip()}\n\n"
    if MARKER in current:
        i = current.index(MARKER)
        emit.replace_file(p, current[:i] + block + current[i:])
    else:
        lead = "" if not current or current.endswith("\n\n") else "\n" if current.endswith("\n") else "\n\n"
        emit.append_file(p, lead + block)
    return "appended"


def _record_step(ctx, row, key, text, rep) -> tuple[str | None, str | None]:
    """``_record``, with a failure reported rather than raised: a record must not hold a result hostage."""
    try:
        return _record(ctx, row, key, text), None
    except Exception as e:      # noqa: BLE001 -- reported, and it escalates (see the module docstring)
        why = _error(e)
        rep["errors"].append({"step": "record", "id": row["id"], "error": why})
        return "failed", why


def _escalate_once(ctx, row, outcome, evidence, detail, record_error=None) -> int | None:
    """The escalation for this outcome, raised once: found again by kind, subject and evidence."""
    urgency = OUTCOMES[outcome][1] or ("normal" if record_error else None)
    if urgency is None:
        return None
    found = ctx.store.find_escalation(ctx.tenant.name, ESC_KIND, row["id"], evidence)
    if found is not None:
        return found["id"]
    question = f"{row['id']} {row['title']}: {outcome}, {detail}"
    if record_error:
        question += f"; its record was not written: {record_error}"
    if row["ask"]:
        question += f". {row['ask']}"
    labels = [o["label"] for o in options_of(row)]
    return escalate.run_escalate(ctx, question, evidence, labels, kind=ESC_KIND, subject=row["id"],
                                 urgency=urgency)["id"]


# --- the export --------------------------------------------------------------------------------

EXPORT_FIELDS = ("id", "tenant", "kind", "title", "status", "outcome", "attempt", "max_attempts",
                 "not_before", "expires_at", "last_reason", "started_at", "ended_at", "updated_at")


def _export_row(s: store.Store, row: dict) -> dict:
    out = {k: _redact(row[k]) for k in EXPORT_FIELDS}
    esc = s.escalation(row["escalation_id"]) if row["escalation_id"] else None
    out["escalation"] = None if esc is None else {
        "id": esc["id"], "open": esc["resolved_at"] is None, "question": _redact(esc["question"]),
        "options": [_redact(o) for o in esc["options"]], "disposition": _redact(esc["disposition"]),
        "resolved_at": esc["resolved_at"]}
    return out


def _exported(e: dict, now: datetime) -> bool:
    if e["status"] in ("pending", "running") or (e["escalation"] and e["escalation"]["open"]):
        return True
    return (e["ended_at"] or e["updated_at"] or "") >= decl._iso(now - EXPORT_WINDOW)


def write_export(cfg, now: datetime | None = None, own: tuple[str, Path] | None = None) -> dict:
    """Rewrite the export from every tenant's store. ``own`` is ``(tenant, state_dir)`` for a
    ``--state-dir`` override, so the caller's own store is the one read for its tenant."""
    now = now or datetime.now(timezone.utc)
    tenants, rows = {}, []
    for name, tenant in sorted(cfg.tenants.items()):
        state_dir = Path(own[1]) if own and own[0] == name else Path(tenant.state_dir).expanduser()
        if not (state_dir / "rabota.db").is_file():
            tenants[name] = {"ok": True, "schedules": 0}
            continue
        s = None
        try:
            s = store.Store.open(state_dir)
            mine = [e for e in (_export_row(s, r) for r in s.list_schedules(name)) if _exported(e, now)]
        except (errors.RabotaError, sqlite3.Error) as e:
            tenants[name] = {"ok": False, "error": _redact(_error(e))}
            continue
        finally:
            if s is not None:
                s.close()
        tenants[name] = {"ok": True, "schedules": len(mine)}
        rows += mine
    doc = {"version": EXPORT_VERSION, "generated_at": decl._iso(now), "tenants": tenants,
           "schedules": sorted(rows, key=lambda r: (r["not_before"], r["id"]))}
    path = export_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    emit.replace_file(path, json.dumps(doc, indent=1, sort_keys=True) + "\n")
    return {"path": str(path), "schedules": len(rows), "failed": sorted(n for n, t in tenants.items() if not t["ok"])}


# --- answers -----------------------------------------------------------------------------------

def schedule_for(ctx, esc: dict) -> dict | None:
    """The schedule row whose tick raised ``esc``, or None. Only the escalation the row itself
    records can carry an action: one made by hand with ``--kind scheduled-run`` executes nothing."""
    if esc.get("kind") != ESC_KIND or not esc.get("subject"):
        return None
    row = ctx.store.get_schedule(esc["subject"])
    if row is None or row["tenant"] != ctx.tenant.name or row["escalation_id"] != esc["id"]:
        return None
    return row


def action_for(row: dict, label: str) -> str:
    """The declared action of ``label``; ``none`` for any label the declaration does not map."""
    return next((o["action"] for o in options_of(row) if o["label"] == label), "none")


def _plan_rerun(ctx, row, esc_id, label, action, now) -> dict:
    """The one row a ``rerun`` enqueues, and its payload; every refusal is asked here, before any write."""
    m = decl._RERUN.match(action)
    delay = decl.parse_duration(m.group(1), "rerun") if m and m.group(1) else timedelta(0)
    if delay > decl.MAX_HORIZON:
        raise errors.Refused(f"{label!r} re-runs {m.group(1)} from now, past the {decl.MAX_HORIZON.days}-day horizon")
    p = Path(row["payload_path"])
    try:
        raw = p.read_bytes()
    except OSError as e:
        raise errors.Refused(f"the frozen payload {p} cannot be read ({e.strerror or e}), so nothing is re-run") from None
    if hashlib.sha256(raw).hexdigest() != row["payload_sha256"]:
        raise errors.Refused(f"the frozen payload {p} changed after it was frozen, so it is not re-run; "
                             f"declare a new run with `rabota schedule add`")
    decl._refuse_disarmed(ctx)
    new_id = f"s-{uuid.uuid4().hex[:8]}"
    while ctx.store.get_schedule(new_id) or (ctx.state_dir / "schedules" / new_id).exists():
        new_id = f"s-{uuid.uuid4().hex[:8]}"
    stamp, due = decl._iso(now), now + delay
    new = {k: row[k] for k in store.SCHEDULE_FIELDS}
    new.update(id=new_id, payload_source=str(p), payload_path=str(ctx.state_dir / "schedules" / new_id / p.name),
               not_before=decl._iso(due), expires_at=decl._iso(due + decl.DEFAULT_EXPIRY), status="pending",
               attempt=0, last_reason=f"rerun of {row['id']}, answered {label!r} on ESC-{esc_id}", unit=None,
               lane_id=None, out_dir=None, outcome=None, cost_usd=None, escalation_id=None, started_at=None,
               ended_at=None, created_at=stamp, updated_at=stamp, created_from_cwd=os.getcwd(),
               created_from_session=ctx.env.get("CLAUDE_CODE_SESSION_ID"))
    return {"row": new, "raw": raw, "name": p.name, "mode": 0o500 if row["kind"] == "command" else 0o400}


def _followups(ctx, row) -> list[dict]:
    """Pending runs whose payload was frozen from one of ``row``'s own frozen files."""
    sources = {s for s in (row["payload_path"], row["then_prompt_path"]) if s}
    return [r for r in ctx.store.list_schedules(ctx.tenant.name, "pending") if r["payload_source"] in sources]


def run_answer(ctx, esc: dict, row: dict, label: str, resolution: str | None = None,
               now: datetime | None = None) -> dict:
    """Answer a tick-raised escalation: execute the label's declared action, record, export."""
    now = now or datetime.now(timezone.utc)
    action = action_for(row, label)
    plan = _plan_rerun(ctx, row, esc["id"], label, action, now) if decl._RERUN.match(action) else None
    followups = _followups(ctx, row) if action == "cancel-followups" else []
    out = {"id": esc["id"], "disposition": label, "action": action,
           "enqueued": plan["row"]["id"] if plan else None, "cancelled": [f["id"] for f in followups]}
    if ctx.dry_run:
        return {**out, "dry_run": "nothing written (escalations row, escalations.jsonl, schedules, record, export)"}
    # Everything the projection will carry is checked now, so a leak refuses before the action commits.
    secrets.assert_clean(json.dumps([esc["question"], esc["evidence"], esc["options"], label, resolution]), os.environ)
    frozen = decl._freeze(ctx, plan["row"]["id"], [(plan["name"], plan["raw"], plan["raw"].decode("utf-8"),
                                                     plan["mode"])]) if plan else None
    stamp = decl._iso(now)
    try:
        with ctx.store.transaction():
            if plan:
                ctx.store.insert_schedule(plan["row"])
            out["cancelled"] = [f["id"] for f in followups if ctx.store.cancel_schedule(
                f["id"], stamp, f"cancelled by ESC-{esc['id']}: cancel follow-ups of {row['id']}")]
            if action == "cancel-followups" and row["then_on"]:
                ctx.store.update_schedule(row["id"], then_on=None)
            ctx.store.answer_escalation(esc["id"], label, resolution)
    except BaseException:
        if frozen is not None:
            shutil.rmtree(frozen, ignore_errors=True)
        raise
    escalate._project(ctx, escalate.answer_projection(ctx, esc, label, resolution))
    effect = (f"; enqueued {out['enqueued']}, due {decl._local(plan['row']['not_before'])}" if plan
              else f"; cancelled {', '.join(out['cancelled']) or 'nothing pending'}" if action == "cancel-followups"
              else "")
    decided = _neutral(f"decided: {label}, @zvi, {decl._local(stamp)}{effect}")
    try:
        out["record"] = _record(ctx, row, f"{row['id']}:decided:{esc['id']}", decided)
    except Exception as e:      # noqa: BLE001 -- the answer has committed; say what was not written
        out["record"] = {"error": _error(e)}
    try:
        out["export"] = write_export(ctx.cfg, now, own=(ctx.tenant.name, ctx.state_dir))
    except Exception as e:      # noqa: BLE001 -- same: the next tick rewrites it
        out["export"] = {"error": _error(e)}
    return out
