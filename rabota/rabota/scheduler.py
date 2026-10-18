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
   then started with ``systemd-run``, once ``scripts/gh-route`` has said which gh config dir its cwd
   routes to. A route that cannot be resolved starts nothing and is settled like a failed
   ``systemd-run``: one ``could-not-run`` attempt, retried, because a stalled fork heals and a broken
   table is news within ``RETRY_DELAY``. At most ``MAX_RUNNING_COMMANDS`` command units run at once
   per tenant, counting those still running from earlier ticks: a due command past the cap is
   DEFERRED (``COMMAND_DEFERRAL``) and a later tick starts it. An agent row is never dispatched
   (DO-820 brings its executor): it is DEFERRED with ``AGENT_DEFERRAL``. A deferral is not an
   attempt, so the row stays visible in ``schedule list`` with its reason and, if it never gets to
   start, expires and escalates by the ordinary path.

**Crash recovery.** The claim is written before ``systemd-run``, so the tick can die anywhere after
it without losing the run. The next tick finds a ``running`` row and asks systemd about its unit. A
live unit is left alone. One that finished is settled from what it left: adopted, not re-run. One
that never started, or whose ``systemd-run`` failed, left no exit status, and settles as one
``could-not-run`` attempt. Nothing is re-dispatched blind: a new attempt has a new unit name, and
systemd refuses a duplicate.

**The command executor** (§7) is a transient ``rabota-sched-<tenant>-<id>-a<n>.service`` under
``MemoryMax``, ``RuntimeMaxSec``, ``Nice=10`` and ``KillMode=control-group``, with ``PATH`` set to
include ``~/.local/bin`` (DO-712: a transient unit gets the user manager's minimal one). It is
routed to a GitHub account the way the shell routes its cwd (DO-829). The user manager's
environment has no gh routing, so gh used its default config dir. Without a token every config
dir authenticates as the keyring's one host-keyed account, whichever that is at the time; on
2026-10-18 it was not the work account. ``scripts/gh-route`` answers from the
same tables and the same ``_gh_route_for`` as an interactive shell. A routed unit gets
``GH_CONFIG_DIR`` and ``LoadCredential=gh-token:<that route's file in the shell's token cache>``:
the file's PATH, never its contents. Where no route applies it gets neither, exactly as the shell
exports neither there. A route that cannot be resolved, or whose cached token is missing, starts
nothing, and the attempt is ``could-not-run``: never a silent fallback to another account. No token
appears in the unit's properties or argv, and nothing from the tick's environment is passed. It
gets no seat and passes no budget gate. It runs the FROZEN script through ``WRAPPER``, a fixed
``/bin/sh`` line. The tick tells it, as an argument, whether the unit was routed. A routed unit's
wrapper exports the credential as ``GH_TOKEN`` into the script's process alone, and never prints
it. If the credential is absent or empty, it runs nothing and leaves 2 (``could-not-run``) rather
than run the script as another account. Its other job is to write the script's exit status into
the out_dir, atomically, once it exits. Every value reaches the wrapper as an argument, never as script text, and
``--expand-environment=no`` stops systemd rewriting a ``$`` in any of them. A ``RuntimeMaxSec`` or
``MemoryMax`` kill takes the wrapper with it and leaves no exit status, which is the
``could-not-run`` the design asks for.

**A routed run's token is redacted.** ``secrets.redact`` knows only the environment's values and
``REGISTERED_VALUES``, and a script can print its ``GH_TOKEN``. So before a routed attempt is
settled, the tick reads the cached token named in the attempt's out_dir into memory and registers
it. Dispatch leaves that path and the token's sha256 there. If the file cannot be read, or no
longer holds the token the attempt started with, the output tails are withheld from ``result.md``
and the record.

**The record** (§6 step 3) gets one section per settled attempt, keyed
``<!-- rabota-schedule:<id>:<attempt> -->`` (``expired``, ``refused`` or ``decided:<esc>`` in place
of the attempt for a section that is not one), and skipped when the key is already there. It goes
immediately BEFORE a ``<!-- rabota-schedule-results -->`` marker when the file has one, through
``emit.replace_file`` (an atomic rewrite), so results stay in the order they happened and the marker
stays where the next one goes. Otherwise it goes at the end, through ``emit.append_file``. Both
guard the text. The command's output arrives redacted (``secrets.redact``, over the whole of
``result.md``), so a script that prints a protected value still leaves its section, and no ``<!--`` survives in a body, so output can never
forge a key or move the marker. A record that git tracks by now is not written: ``add``'s rule,
asked again. A record that cannot be written fails the tick (exit 4), and on a final outcome it
turns even a ``pass`` into an escalation, because otherwise that result would be lost with nothing
to show for it. A retried attempt raises nothing, so its lost section is reported by the tick's
failure alone; the outcome its retries end in escalates as usual.

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
tick, every ``add`` and ``cancel``, and every answer to a scheduled run, under one lock all tenants
share. It covers every tenant, each read from its own store, which is never created or migrated. It is versioned and redacted field by field. It carries
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
import time
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
# How long a writer waits for a lock another holds before giving up. Every holder is a short
# read-modify-write, so running out means something is stuck, and the caller reports it.
TICK_LOCK_WAIT = 60.0          # cancel and answer, for a tick in progress
EXPORT_LOCK_WAIT = 30.0        # an export rewrite, for another tenant's
RECORD_LOCK_WAIT = 30.0        # a record write, for another in the same directory
AGENT_DEFERRAL = ("deferred: agent runs have no executor until phase 2 (DO-820); it stays pending, "
                  "so it expires and escalates if none arrives in time")
COMMAND_DEFERRAL = (f"deferred: {decl.MAX_RUNNING_COMMANDS} command runs are already running for this "
                    f"tenant (MAX_RUNNING_COMMANDS); a later tick starts it once one ends")
GH_CREDENTIAL = "gh-token"          # the LoadCredential= id a routed unit's token arrives under
NO_CREDENTIAL = "-"                 # the wrapper's credential argument for an unrouted unit
TOKEN_PATH = "gh-token-path"        # in a routed attempt's out_dir: which cached token to redact
# $0 names the process, $1 is the exit-status path, $2 the credential the unit was routed with (or
# NO_CREDENTIAL), the rest is the frozen script and its args. The tick, not the environment, says
# whether a token is due, so a routed unit whose credential is absent or empty fails closed: it runs
# nothing and leaves 2, could-not-run, never the script under another account. A token becomes
# GH_TOKEN in the SCRIPT's environment only (a prefix assignment, not an export).
WRAPPER = (r'f=$1; c=$2; shift 2; if [ "$c" = "' + NO_CREDENTIAL + r'" ]; then "$@"; '
           r'elif [ -n "${CREDENTIALS_DIRECTORY:-}" ] && t=$(cat -- "$CREDENTIALS_DIRECTORY/$c") && [ -n "$t" ]; '
           r'then GH_TOKEN=$t "$@"; else (exit 2); fi; rc=$?; printf "%s\n" "$rc" > "$f.tmp" && mv -f "$f.tmp" "$f"')

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


# Relative to this module, not ~/.dotfiles, for tenants.ROUTER's reason: a worktree or a test
# checkout routes through its own copy. A ROUTED state carries a config dir and a token file;
# an UNROUTED one, neither.
GH_ROUTER = Path(__file__).resolve().parents[2] / "scripts" / "gh-route"
GH_ROUTE_TIMEOUT = 15           # a cold `zsh -f` fork plus one git call; tenants.TIMEOUT's bound
GH_ROUTED, GH_UNROUTED = ("matched", "default"), ("none", "no-repo", "no-remotes")


def gh_route_for(ctx, cwd: str) -> tuple[str, str] | None:
    """``(GH_CONFIG_DIR, token file)`` the shell's gh routing gives ``cwd``, or None where no route applies.

    The token file is that route's file in the shell's token cache, as ``scripts/gh-route`` names
    it. Only its path is handled here. Raises ``RabotaError`` when the route cannot be resolved:
    the router failing, or answering anything but a state it promises with the paths that state
    promises. None never means "could not tell", because a unit with no route gets gh's default.
    The router gets ``HOME`` and the unit's ``PATH`` and nothing else, so no value from the tick's
    environment can reach its answer.
    """
    res = ctx.runner.run([str(GH_ROUTER), cwd], env={"HOME": str(Path.home()), "PATH": unit_path()},
                         timeout=GH_ROUTE_TIMEOUT)
    if not res.ok:
        raise errors.RabotaError(f"{GH_ROUTER.name} exited {res.code}: "
                                 f"{(res.err or res.out).strip()[:300] or 'no message'}")
    try:
        data = json.loads(res.out)
    except json.JSONDecodeError:
        data = None
    got = [data.get(k) for k in ("state", "dir", "token_file")] if isinstance(data, dict) else [None] * 3
    state, d, tok = got
    if state in GH_ROUTED and _absolute(d) and _absolute(tok) and not re.search(r"[\s%]", tok):
        return d, tok
    if state in GH_UNROUTED and d == "" and tok == "":
        return None
    raise errors.RabotaError(f"{GH_ROUTER.name} answered {res.out.strip()[:200]!r}, which is not a "
                             f"state it promises with the paths that state promises")


def _absolute(p) -> bool:
    """An absolute path with no control character. The token file must also have no whitespace or
    ``%``: as a ``LoadCredential=`` property, systemd would split on one and expand the other as a
    specifier. The config dir travels as a ``--setenv=`` argv element under
    ``--expand-environment=no``, where neither happens."""
    return isinstance(p, str) and p.startswith("/") and not re.search(r"[\x00-\x1f\x7f]", p)


def read_route_token(path: str) -> str:
    """The token cached at ``path``, into memory only. Raises a ``RabotaError`` that names the
    file and what is wrong with it, never its contents."""
    p = Path(path)
    try:
        if not p.is_file():
            raise errors.RabotaError(f"{p} is {'not a regular file' if p.exists() else 'missing'}")
        token = p.read_text().strip()
    except (OSError, ValueError) as e:      # ValueError: bytes that are not UTF-8
        raise errors.RabotaError(f"{p} cannot be read ({getattr(e, 'strerror', None) or type(e).__name__})") from None
    if not token:
        raise errors.RabotaError(f"{p} is empty")
    return token


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


def _acquire(fd: int, wait: float) -> bool:
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.05)


@contextlib.contextmanager
def _flock(path: Path, wait: float = 0, directory: bool = False):
    """Yield whether an exclusive lock on ``path`` was taken within ``wait`` seconds (0: at once).

    ``directory`` locks the directory itself, a path no atomic rename can replace under the lock.
    """
    if not directory:
        path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY) if directory else os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        yield _acquire(fd, wait)
    finally:
        os.close(fd)        # closing the descriptor releases the lock


@contextlib.contextmanager
def tick_lock(ctx, what: str):
    """The tick's own lock, for a writer that must not interleave with one: ``cancel`` and ``answer``.

    The tick raises an escalation before the row write that records it. A cancel landing between
    the two would leave an escalation no row points at, offering actions nothing would execute.
    """
    with _flock(ctx.state_dir / LOCK, wait=TICK_LOCK_WAIT) as held:
        if not held:
            raise errors.Refused(f"a schedule tick for {ctx.tenant.name} has held its lock for "
                                 f"{TICK_LOCK_WAIT:g} s, so {what} was not done; try again")
        yield


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
        # The CLI prints only the failures, so the message says what the tick still did.
        moved = "; ".join(f"{k} {', '.join(r['id'] for r in rep[k])}"
                          for k in ("settled", "expired", "refused", "dispatched", "deferred") if rep[k])
        raise errors.Partial(f"schedule tick for {ctx.tenant.name}: {len(rep['errors'])} failure(s)"
                             + (f"; it still {moved}" if moved else ""), rep["errors"])
    return rep


def _isolated(rep, step, sched_id, fn, *args):
    """Run one row's step and return what it returns; a failure is reported (None) and never stops the next row."""
    try:
        return fn(*args)
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
    body = _result_md(row, outcome, detail, retry, ended, now, withheld=_register_run_token(out_dir))
    emit.write_file(out_dir / RESULT, body)
    heading = (f"{decl._local(decl._iso(ended))} scheduled run {row['id']}: {outcome}"
               + (f" (attempt {attempt} of {most}, retrying)" if retry else ""))
    record, record_error = _record_step(ctx, row, f"{row['id']}:{attempt}", f"## {heading}\n\n{body}", rep)
    eid = sent = None
    if not retry:
        eid, sent = _escalate_once(ctx, row, outcome, str(out_dir / RESULT), detail, record_error)
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
                           "escalation": eid, "desktop_notified": sent, "record": record})


def _register_run_token(out_dir: Path) -> str | None:
    """Register the cached token a routed attempt ran with, so ``_redact`` replaces it.

    Returns None when there is nothing to redact, or when the token is registered. Otherwise it
    returns why the output cannot be shown redacted, and the caller withholds it: the note dispatch
    left cannot be read, the token file cannot be read, or it no longer holds the token the attempt
    started with (a rotation in between would leave the old one unregistered).
    """
    try:
        note = (out_dir / TOKEN_PATH).read_text().split()
    except FileNotFoundError:
        return None                         # an unrouted attempt, or one that never got that far
    except (OSError, ValueError) as e:
        return f"its {TOKEN_PATH} note cannot be read ({type(e).__name__})"
    if len(note) != 2:
        return f"its {TOKEN_PATH} note is not a token file and a sha256"
    path, want = note
    try:
        token = read_route_token(path)
    except errors.RabotaError as e:
        return f"its route's cached token could not be read to redact it: {e}"
    if _digest(token) != want:
        return f"{path} no longer holds the token this attempt started with, so that one cannot be redacted"
    secrets.register_value(token)
    return None


def _tail(p: Path) -> tuple[str, bool]:
    """The last ``TAIL_BYTES`` of ``p``, decoded, and whether anything was cut (``_result_md`` redacts)."""
    try:
        size = p.stat().st_size
        with p.open("rb") as f:
            f.seek(max(0, size - TAIL_BYTES))
            data = f.read()
    except FileNotFoundError:
        return "", False
    return data.decode("utf-8", errors="replace"), size > TAIL_BYTES


def _fence(text: str) -> str:
    run = max((len(m) for m in re.findall(r"`+", text)), default=0)
    fence = "`" * max(3, run + 1)
    return f"{fence}text\n{text.rstrip()}\n{fence}"


def _result_md(row, outcome, detail, retry, ended, now, withheld: str | None = None) -> str:
    """``result.md`` for a command attempt: what ran, how it ended, and the tail of each stream,
    unless ``withheld`` says why the streams cannot be shown redacted."""
    out_dir = Path(row["out_dir"])
    nxt = f"; the next starts after {decl._local(decl._iso(now + decl.RETRY_DELAY))}" if retry else ""
    lines = [f"- **{outcome}**: {detail}",
             f"- attempt {row['attempt']} of {row['max_attempts']}{nxt}",
             f"- title: {row['title']}",
             f"- ran `{shlex.join([row['payload_path'], *(row['args'] or [])])}` in `{row['cwd']}` as "
             f"{row['unit']}, ended {decl._local(decl._iso(ended))}",
             f"- full output: {out_dir / STDOUT}, {out_dir / STDERR}"]
    parts = ["\n".join(lines)]
    if withheld:
        parts.append(f"output withheld from this result and the record: {withheld}")
    for name in () if withheld else (STDOUT, STDERR):
        text, cut = _tail(out_dir / name)
        if text.strip():
            parts.append(f"{name}{f' (last {TAIL_BYTES} bytes)' if cut else ''}:\n\n{_fence(text)}")
    # The whole body, not just the streams: a title or ask stored before this environment held a
    # value is not redacted in the row, and a leak here would wedge the row in every tick after.
    return _redact(_neutral("\n\n".join(parts))) + "\n"


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
    eid, sent = _escalate_once(ctx, row, "expired", f"schedule {row['id']} expired at {row['expires_at']}", detail, record_error)
    if not ctx.store.update_schedule_where(row["id"], {"status": "pending", "attempt": row["attempt"]},
                                           status="expired", outcome="expired", ended_at=decl._iso(now),
                                           last_reason=detail, escalation_id=eid):
        raise errors.RabotaError(f"{row['id']} stopped being pending while it was expired; its row was left as it was")
    rep["expired"].append({"id": row["id"], "escalation": eid, "desktop_notified": sent})


def _dispatch(ctx, now, rep):
    # Command units already running (from an earlier tick, after step 1 settled what had ended),
    # plus each one this tick starts. Past the cap a due command is DEFERRED, never an attempt.
    running = sum(r["kind"] == "command" for r in ctx.store.list_schedules(ctx.tenant.name, "running"))
    for row in ctx.store.list_schedules(ctx.tenant.name, "pending"):
        if _parse(row["not_before"]) > now or _parse(row["expires_at"]) <= now:
            continue        # not due yet; or past expiry, which step 3 has already reported
        if row["kind"] != "command":
            _isolated(rep, "dispatch", row["id"], _defer, ctx, row, AGENT_DEFERRAL, rep)
        elif running >= decl.MAX_RUNNING_COMMANDS:
            _isolated(rep, "dispatch", row["id"], _defer, ctx, row, COMMAND_DEFERRAL, rep)
        elif _isolated(rep, "dispatch", row["id"], _dispatch_command, ctx, row, now, rep):
            running += 1


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


def command_argv(row: dict, unit: str, out_dir: Path, route: tuple | None = None) -> list[str]:
    """The ``systemd-run`` argv for one command attempt. Every value is an argv element, never text.

    ``route`` is ``_unit_route``'s answer, ``(config dir, token file, …)``. It adds ``GH_CONFIG_DIR``
    and a ``LoadCredential=`` naming the token file's PATH, and tells the wrapper a token is due.
    None adds neither.

    ``--expand-environment=`` is systemd 254 or later. The tick runs only on this laptop (design
    §13), which runs 259; an older systemd refuses the flag, and that surfaces as a could-not-run
    escalation naming the error, never as a run that silently did not happen.
    """
    return ["systemd-run", "--user", "--collect", f"--unit={unit}", f"--working-directory={row['cwd']}",
            "--expand-environment=no", f"--setenv=PATH={unit_path()}",
            *([f"--setenv=GH_CONFIG_DIR={route[0]}", "-p", f"LoadCredential={GH_CREDENTIAL}:{route[1]}"]
              if route else []),
            "-p", f"MemoryMax={row['memory_max']}", "-p", f"RuntimeMaxSec={row['timeout_s']}",
            "-p", "Nice=10", "-p", "KillMode=control-group",
            "-p", f"StandardOutput=append:{out_dir / STDOUT}", "-p", f"StandardError=append:{out_dir / STDERR}",
            "/bin/sh", "-c", WRAPPER, "rabota-sched", str(out_dir / EXIT_FILE), GH_CREDENTIAL if route else NO_CREDENTIAL,
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
    try:
        route = _unit_route(ctx, row)
    except errors.RabotaError as e:
        # Not started: gh's default, or another account, would be a silent wrong account. Recorded as
        # the failed systemd-run below is, so the next tick settles it as one could-not-run attempt.
        ctx.store.update_schedule_where(row["id"], {"status": "running", "unit": unit}, last_reason=str(e))
        raise errors.RabotaError(f"{e}; the next tick settles it as an attempt that could not run") from None
    if route:
        emit.write_file(out_dir / TOKEN_PATH, f"{route[1]}\n{route[2]}\n")     # path and sha256, for settle
    res = ctx.runner.run(command_argv(row, unit, out_dir, route), timeout=30)
    if not res.ok:
        why = f"systemd-run failed (exit {res.code}): {(res.err or res.out).strip()[:200]}"
        ctx.store.update_schedule_where(row["id"], {"status": "running", "unit": unit}, last_reason=why)
        raise errors.RabotaError(f"{why}; the next tick settles it as an attempt that could not run")
    rep["dispatched"].append({"id": row["id"], "attempt": n, "unit": unit})
    return True


def _unit_route(ctx, row) -> tuple[str, str, str] | None:
    """``gh_route_for`` the row's cwd plus the sha256 of its cached token, read before anything starts.

    The check is the tick's own, not systemd's: a ``LoadCredential=`` that cannot be read fails the
    start, but leaving that to systemd would also be a silent change if it ever stopped doing so.
    """
    try:
        route = gh_route_for(ctx, row["cwd"])
    except errors.RabotaError as e:
        raise errors.RabotaError(f"not started, because its gh account could not be routed: {e}") from None
    if route:
        try:
            token = read_route_token(route[1])
        except errors.RabotaError as e:
            raise errors.RabotaError(f"not started, because its gh route {route[0]} has no cached token: "
                                     f"{e}; `gh-refresh-tokens` refills the cache") from None
        return route[0], route[1], _digest(token)
    return route


def _digest(token: str) -> str:
    """Which token a routed attempt started with, without keeping it: settle compares the cache to it."""
    return hashlib.sha256(token.encode()).hexdigest()


def _refuse(ctx, row, problem, evidence, now, rep):
    """Settle a pending row that must not start: failed, could-not-run, escalated, never retried."""
    detail = f"refused to start: {problem}"
    stamp = decl._local(decl._iso(now))
    _, record_error = _record_step(ctx, row, f"{row['id']}:refused",
                                   f"## {stamp} scheduled run {row['id']}: could-not-run\n\n{_neutral(f'- **could-not-run**: {detail}')}\n", rep)
    eid, sent = _escalate_once(ctx, row, "could-not-run", evidence, detail, record_error)
    if not ctx.store.update_schedule_where(row["id"], {"status": "pending", "attempt": row["attempt"]},
                                           status="failed", outcome="could-not-run", ended_at=decl._iso(now),
                                           last_reason=detail, escalation_id=eid):
        raise errors.RabotaError(f"{row['id']} stopped being pending while it was refused; its row was left as it was")
    rep["refused"].append({"id": row["id"], "reason": detail, "escalation": eid, "desktop_notified": sent})


# --- the record and the escalation -------------------------------------------------------------

def _record(ctx, row, key: str, text: str) -> str | None:
    """Put ``text`` under ``key`` in the row's record; ``appended``, ``present``, or None for no record.

    The read, the key check and the write happen under a lock on the record's DIRECTORY, so two
    rabota writers (a tick and an answer, or two tenants' ticks sharing one file) cannot each read
    the old file and have the second rename drop the first one's section. An editor saving over
    the file at the same instant is outside any lock rabota can take.
    """
    if not row["record"]:
        return None
    p = Path(row["record"])
    decl._refuse_tracked(ctx, [p])
    with _flock(p.parent, wait=RECORD_LOCK_WAIT, directory=True) as held:
        if not held:
            raise errors.RabotaError(f"another writer held {p.parent} for {RECORD_LOCK_WAIT:g} s")
        current = p.read_text()
        tag = f"<!-- rabota-schedule:{key} -->"
        if tag in current:
            return "present"
        block = f"{tag}\n{_redact(text).rstrip()}\n\n"
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


def _escalate_once(ctx, row, outcome, evidence, detail, record_error=None) -> tuple[int | None, bool | None]:
    """The escalation for this outcome, raised once: found again by kind, subject and evidence.

    Returns ``(id, desktop_notified)``. ``desktop_notified`` is ``run_escalate``'s: whether the one
    ``notify-send`` went out. It is ``None`` when nothing was sent, either because no escalation is
    due or because it was found again. The tick puts it in its report, so the journal answers "was
    ESC-n ever on the desktop" (2026-10-14: nothing could say so for ESC-11).
    """
    urgency = OUTCOMES[outcome][1] or ("normal" if record_error else None)
    if urgency is None:
        return None, None
    found = ctx.store.find_escalation(ctx.tenant.name, ESC_KIND, row["id"], evidence)
    if found is not None:
        return found["id"], None
    question = f"{row['id']} {row['title']}: {outcome}, {detail}"
    if record_error:
        question += f"; its record was not written: {record_error}"
    if row["ask"]:
        question += f". {row['ask']}"
    labels = [o["label"] for o in options_of(row)]
    out = escalate.run_escalate(ctx, _redact(question), evidence, labels, kind=ESC_KIND, subject=row["id"],
                                urgency=urgency)
    return out["id"], out["desktop_notified"]


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
    ``--state-dir`` override, so the caller's own store is the one read for its tenant.

    Every tenant's tick writes the same file, and two timers can fire in the same second. The read
    and the write therefore happen under one lock, so the last export written is never one read
    before another writer's change: each tenant's own store write lands before its rewrite starts.
    """
    with _flock(export_path().with_name(".schedule-export.lock"), wait=EXPORT_LOCK_WAIT) as held:
        if not held:
            raise errors.RabotaError(f"another export rewrite held its lock for {EXPORT_LOCK_WAIT:g} s; "
                                     f"this one was skipped, and the next tick rewrites it")
        return _write_export(cfg, now or datetime.now(timezone.utc), own)


def _write_export(cfg, now, own) -> dict:
    tenants, rows = {}, []
    for name, tenant in sorted(cfg.tenants.items()):
        state_dir = Path(own[1]) if own and own[0] == name else Path(tenant.state_dir).expanduser()
        if not (state_dir / "rabota.db").is_file():
            tenants[name] = {"ok": True, "schedules": 0}
            continue
        s = None
        try:
            s = store.Store.open_current(state_dir)     # never creates or migrates another tenant's store
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
    if ctx.dry_run:
        return _answer(ctx, esc, row, label, resolution, now)
    with tick_lock(ctx, f"the answer to ESC-{esc['id']}"):
        out = _answer(ctx, esc, row, label, resolution, now)
    return _after_answer(ctx, esc, row, label, resolution, now, out)


def _answer(ctx, esc, row, label, resolution, now) -> dict:
    """Plan the label's action, ask every refusal, then commit the action and the answer as one."""
    action = action_for(row, label)
    plan = _plan_rerun(ctx, row, esc["id"], label, action, now) if decl._RERUN.match(action) else None
    followups = _followups(ctx, row) if action == "cancel-followups" else []
    out = {"id": esc["id"], "disposition": label, "action": action,
           "enqueued": plan["row"]["id"] if plan else None, "cancelled": [f["id"] for f in followups]}
    if ctx.dry_run:
        return {**out, "dry_run": "nothing written (escalations row, escalations.jsonl, schedules, record, export)"}
    # Asked again under the lock: two answers that both read "open" before either committed would
    # otherwise each execute the action, and a rerun would be enqueued twice.
    current = ctx.store.escalation(esc["id"])
    if current["resolved_at"]:
        raise errors.Refused(f"escalation {esc['id']} was answered {current['disposition']!r} while this answer ran")
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
    out["plan"] = plan
    return out


def _after_answer(ctx, esc, row, label, resolution, now, out) -> dict:
    """The projection, the record's ``decided`` line and the export, once the answer has committed."""
    plan, stamp, action = out.pop("plan"), decl._iso(now), out["action"]
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
