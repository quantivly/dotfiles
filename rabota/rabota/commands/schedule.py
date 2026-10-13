"""``rabota schedule``: declare a run for later, as a row rabota owns (DO-816).

Design: ``docs/superpowers/specs/2026-10-11-scheduled-agent-runs-design.md`` — §3 for the fields,
§8 for the verbs. This module is the DECLARATION half only: ``add``, ``list``, ``show`` and
``cancel``. Nothing here runs anything; the tick that fires a due row, the command executor and
the ``rabota-schedule@`` units are DO-817, and agent-run execution is phase 2 (DO-819, DO-820).

``add`` freezes the payload — the prompt, or the script — into ``<state_dir>/schedules/<id>/``
with a ``SHA256SUMS`` beside it, so editing or deleting the source cannot change what runs. It
prints the whole declaration, including the effective permissions, so the scheduling session's
own transcript shows exactly what will run unattended.

``add`` REFUSES (exit 3), each by name, and checks them in this order:

- a past ``--at``; an ``--expires`` not after ``--at``; an ``--at`` beyond ``MAX_HORIZON``;
- a ``--cwd`` that contains the run's ``out_dir`` (``out_root``);
- a command script, or its arguments, that invokes ``claude`` — a command must not be a back
  door around the seat gate, so the caller is pointed at ``--kind agent``;
- a ``--record`` that git tracks (the live dotfiles checkout IS the deployment), or that the
  secret guard protects — both asked of the tools themselves, never of a copied list;
- a tenant whose ``rabota-schedule@<tenant>.timer`` is not enabled, so a run can never sit in a
  queue that nothing reads.

THE TIMER CHECK IS LAST, AND ``--dry-run`` REFUSES ON IT EXACTLY AS ``add`` DOES. A dry run
validates a declaration and prints it without storing it (§8); one that exited 0 while the real
``add`` would refuse is a green answer to the wrong question. Because it runs after every other
check, its refusal also says that the declaration itself is valid, which is all a dry run against
a disarmed tenant can usefully tell its caller. Every check a dry run makes is a read:
``systemctl --user is-enabled``, ``git ls-files`` and the guard hook on a synthetic payload.

THE TENANT COMES FROM ``Context.from_namespace``, as for every other rabota command
(``--tenant`` → ``$CLAUDE_ACCOUNT_TENANT`` → ``tenant-route`` on the process cwd). ``--cwd`` is
where the run starts, not what decides who it bills.
"""
import argparse
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from rabota import budget as budget_mod
from rabota import cli, config, emit, errors, store
from rabota.context import Context

# --- Defaults: design §11 decision 5, which @zvi confirms. One constant each, one line to change. ---
DEFAULT_EXPIRY = timedelta(hours=48)        # expires_at = not_before + this, unless --expires
MAX_HORIZON = timedelta(days=30)            # --at may be at most this far ahead
MAX_ATTEMPTS = 2
COMMAND_TIMEOUT = timedelta(minutes=15)
COMMAND_MEMORY_MAX = "1G"
AGENT_TIMEOUT = timedelta(minutes=20)
AGENT_MAX_BUDGET_USD = 3.0
# An agent run's memory_max is the tenant's own [lanes] memory_max: a tenant setting, not a default.

KINDS = ("agent", "command")
STATUSES = ("pending", "running", "done", "failed", "expired", "cancelled")
CANCELLABLE = ("pending",)

# The placeholder a run's out_dir is written as until dispatch fixes it — the same spelling a lane
# brief's `{out_dir}` substitution uses (DO-683). The directory is `out_root(ctx)/<lane_id>`.
OUT_DIR = "{out_dir}"

# --- Effective permissions of an agent run: design §5. DO-819 builds the run's settings.json from
# `effective_permissions`, so the shape is the contract: a settings.json body with OUT_DIR unfilled.
# Path rules: `//x` is absolute, `~/x` home-relative, `**/x` anywhere (code.claude.com/docs/en/permissions).
CREDENTIAL_PATHS = ("~/.clauth/profiles/**", "**/.credentials.json",
                    # the files claude/hooks/secret-emission-guard.sh refuses a read of
                    "~/.zshrc.local", "~/.gitconfig.local", "~/.backup.local")
DENIED_COMMANDS = ("clauth", "claude", "rabota lane", "rabota schedule add", "rabota answer",
                   "systemctl --user start", "systemctl --user stop", "systemctl --user restart",
                   "systemctl --user enable", "systemctl --user disable", "git push", "gh")
FIXED_DENY = (tuple(f"{tool}({p})" for p in CREDENTIAL_PATHS for tool in ("Read", "Edit"))
              + tuple(f"Bash({c}:*)" for c in DENIED_COMMANDS))

# `claude` as a word: `claude -p`, `~/.local/bin/claude`, `claude-as`. Not `~/.claude/…` (a dot
# before it), not `…/claude/hooks` (a slash after it), not `CLAUDE_CONFIG_DIR` (case). Comments are
# NOT stripped first: over-refusing a script that merely mentions claude is the safe direction.
CLAUDE_WORD = re.compile(r"(?<![\w.-])claude(?![\w./])")

GUARD = Path(__file__).resolve().parents[3] / "claude" / "hooks" / "secret-emission-guard.sh"
# A file the guard is known to refuse a read of. Asked first: the hook FAILS OPEN (no jq, no
# payload, any error is silence, and silence is "allow"), so a guard that did not refuse this one
# cannot be read as having cleared the record either.
GUARD_CONTROL = "~/.zshrc.local"

_DURATION = re.compile(r"^(\d+)([smhd])$")
_UNITS = {"s": "seconds", "m": "minutes", "h": "hours", "d": "days"}
_RERUN = re.compile(r"^rerun(?::\+(\d+[mhd]))?$")


def timer_unit(tenant: str) -> str:
    return f"rabota-schedule@{tenant}.timer"


def out_root(ctx) -> Path:
    """The directory every run's out_dir sits directly under — ``run_recipe``'s own layout."""
    return Path(ctx.tenant.state_dir).expanduser() / "out" / ctx.tenant.name


def effective_permissions(allow: list[str], read: list[str], out_dir: str = OUT_DIR) -> dict:
    """The settings.json body an agent run gets: declared allow and read rules plus FIXED_DENY.

    ``dontAsk`` denies anything not allowed without prompting; deny always wins over allow, which
    is what neutralises the user's own allow rules that ``--settings`` merges in (§5).
    """
    return {"permissions": {"defaultMode": "dontAsk",
                            # `/` + an absolute path is the `//` absolute form
                            "allow": [f"Edit(/{out_dir}/**)", *allow, *(f"Read(/{p})" for p in read)],
                            "deny": list(FIXED_DENY)},
            "blockReadsOutsideWorkingDirectories": True}


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _local(iso: str) -> str:
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M %Z")


def parse_time(text: str, flag: str) -> datetime:
    """``YYYY-MM-DD HH:MM`` (or ISO-8601) in LOCAL time unless it carries an offset; returned in UTC."""
    try:
        dt = datetime.fromisoformat(text.strip())
    except ValueError:
        raise errors.Usage(f"{flag} {text!r} is not a time: give 'YYYY-MM-DD HH:MM' in local time, "
                           f"or ISO-8601 with an offset") from None
    if dt.tzinfo is None:
        dt = dt.astimezone()     # a naive time is this machine's wall clock
    return dt.astimezone(timezone.utc)


def parse_duration(text: str, flag: str) -> timedelta:
    m = _DURATION.match(text.strip())
    if not m or int(m.group(1)) == 0:
        raise errors.Usage(f"{flag} {text!r} is not a duration: give <n>s, <n>m, <n>h or <n>d, n > 0")
    return timedelta(**{_UNITS[m.group(2)]: int(m.group(1))})


def parse_option(text: str) -> dict:
    """``<label>[=none|rerun[:+<duration>]|cancel-followups]`` → ``{"label", "action"}`` (design §6.5).

    Any other text after ``=`` is a usage error rather than part of the label: an option whose
    action was mistyped would otherwise be stored as text, and executing nothing is exactly what a
    mistyped ``rerun`` must not silently do.
    """
    label, sep, action = text.partition("=")
    label, action = label.strip(), (action.strip() if sep else "none")
    if not label:
        raise errors.Usage(f"--option {text!r} has no label")
    if action not in ("none", "cancel-followups") and not _RERUN.match(action):
        raise errors.Usage(f"--option {text!r}: the action must be none, rerun, rerun:+<n>[mhd] "
                           f"or cancel-followups, not {action!r}")
    return {"label": label, "action": action}


def _read_payload(path_text: str, flag: str) -> tuple[Path, bytes, str]:
    path = Path(path_text).expanduser()
    if not path.is_file():
        raise errors.Usage(f"{flag} {path_text!r} is not a file")
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise errors.Usage(f"{flag} {path_text!r} is not UTF-8 text; only a prompt or a script is frozen") from None
    if not text.strip():
        raise errors.Usage(f"{flag} {path_text!r} is empty")
    return path.resolve(), raw, text


def _claude_hit(text: str) -> str | None:
    for n, line in enumerate(text.splitlines(), 1):
        if CLAUDE_WORD.search(line):
            return f"line {n}: {line.strip()[:80]}"
    return None


def _refuse_tracked(ctx, paths: list[Path]) -> None:
    """Refuse when git tracks any of ``paths``; "could not tell" refuses too, never passes."""
    for p in paths:
        res = ctx.runner.run(["git", "-C", str(p.parent), "ls-files", "--error-unmatch", "--", p.name], timeout=15)
        if res.code == 0:
            raise errors.Refused(
                f"--record {p} is tracked by git: a scheduled run's result never lands in a tracked "
                f"file, because a live checkout is a deployment (the dotfiles one is). Use an "
                f"untracked file, e.g. under a handoffs directory")
        if res.code == 1 or (res.code == 128 and "not a git repository" in res.err):
            continue
        raise errors.Refused(f"could not tell whether --record {p} is tracked by git "
                             f"(exit {res.code}: {(res.err or res.out).strip()[:200]})")


def _guard_denies(ctx, command: str) -> str | None:
    """The guard's deny reason for a Bash ``command``, or None when it allows it."""
    if not GUARD.is_file():
        raise errors.Refused(f"the secret guard is missing ({GUARD}), so --record cannot be checked against it")
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    res = ctx.runner.run(["bash", str(GUARD)], input=payload, timeout=15)
    if not res.ok:
        raise errors.Refused(f"the secret guard exited {res.code}; --record cannot be checked against it")
    if not res.out.strip():
        return None
    try:
        hook = json.loads(res.out)["hookSpecificOutput"]
    except (json.JSONDecodeError, KeyError, TypeError):
        raise errors.Refused("the secret guard printed something other than its decision; "
                             "--record cannot be checked against it") from None
    if hook.get("permissionDecision") != "deny":
        return None
    return hook.get("permissionDecisionReason") or "denied"


def _refuse_guarded(ctx, paths: list[Path]) -> None:
    if _guard_denies(ctx, f"cat -- {GUARD_CONTROL}") is None:
        raise errors.Refused(
            f"the secret guard did not refuse its own control path ({GUARD_CONTROL}), so it cannot "
            f"vouch for --record either (it fails open, e.g. without jq)")
    why = _guard_denies(ctx, "cat -- " + " ".join(shlex.quote(str(p)) for p in paths))
    if why is not None:
        raise errors.Refused(f"--record {paths[0]} is a path the secret guard protects ({why.split('. ')[0]})")


def _refuse_disarmed(ctx) -> dict:
    unit = timer_unit(ctx.tenant.name)
    res = ctx.runner.run(["systemctl", "--user", "is-enabled", unit], timeout=15)
    state = (res.out.strip() or res.err.strip() or f"exit {res.code}").splitlines()[0]
    if not (res.ok and state == "enabled"):
        raise errors.Refused(
            f"{unit} is not enabled ({state}), so nothing would ever fire this run. The declaration "
            f"is otherwise valid; arming the timer is @zvi's step: "
            f"systemctl --user enable --now {unit}")
    return {"unit": unit, "state": state}


def declaration(row: dict) -> dict:
    """The whole row plus local-time renderings and its effective permissions — what add and show print."""
    out = dict(row)
    out["not_before_local"] = _local(row["not_before"])
    out["expires_at_local"] = _local(row["expires_at"])
    if row["kind"] == "agent":
        out["permissions"] = effective_permissions(row["allow"] or [], row["read"] or [])
    else:
        out["permissions"] = {"confinement": "none: the script runs as you, with your privileges, "
                                             "bounded by memory_max and timeout_s only"}
    return out


def _lines(d: dict) -> list[str]:
    lines = [f"{d['id']} {d['status']} {d['kind']}: {d['title']}",
             f"due {d['not_before_local']}, expires {d['expires_at_local']}",
             f"cwd {d['cwd']}",
             f"payload {d['payload_path']} sha256 {d['payload_sha256']}"
             + (f" args {shlex.join(d['args'])}" if d.get("args") else ""),
             f"limits timeout {d['timeout_s']}s, memory {d['memory_max']}, attempts {d['max_attempts']}"
             + (f", budget ${d['max_budget_usd']:g}" if d.get("max_budget_usd") is not None else "")]
    if d["kind"] == "agent":
        lines.append(f"agent seat {d['seat']}, model {d['model']}, effort {d['effort']}")
        perms = d["permissions"]["permissions"]
        lines += [f"allow {r}" for r in perms["allow"]] + [f"deny {r}" for r in perms["deny"]]
    else:
        lines.append(f"permissions {d['permissions']['confinement']}")
    if d.get("record"):
        lines.append(f"record {d['record']}")
    if d.get("ask"):
        lines.append(f"ask {d['ask']}")
    lines += [f"option {o['label']} = {o['action']}" for o in d.get("options") or []]
    if "payload_intact" in d:
        lines.append("payload intact" if d["payload_intact"] else "PAYLOAD CHANGED since it was frozen")
    if d.get("dry_run"):
        lines.insert(0, f"dry-run: {d['dry_run']}")
    return lines


def _freeze(ctx, sched_id: str, files: list[tuple[str, bytes, str, int]]) -> Path:
    """Write each ``(name, source bytes, text, mode)`` into the schedule's own directory, plus SHA256SUMS.

    Through ``emit.write_file``, so a prompt carrying a protected value is refused, not frozen. Each
    written file is read back and hashed against its SOURCE bytes, so the stored sha256 is a claim
    about both. Any failure removes the directory: a half-frozen payload is no payload.
    """
    d = ctx.state_dir / "schedules" / sched_id
    d.mkdir(parents=True)
    try:
        sums = []
        for name, raw, text, mode in files:
            emit.write_file(d / name, text)
            if hashlib.sha256((d / name).read_bytes()).digest() != hashlib.sha256(raw).digest():
                raise errors.RabotaError(f"frozen {name} differs from its source after writing")
            os.chmod(d / name, mode)
            sums.append(f"{hashlib.sha256(raw).hexdigest()}  {name}\n")
        emit.write_file(d / "SHA256SUMS", "".join(sums))
        os.chmod(d / "SHA256SUMS", 0o400)
    except BaseException:
        shutil.rmtree(d, ignore_errors=True)
        raise
    return d


def run_add(ctx, *, at: str, title: str, kind: str | None = None, prompt_file: str | None = None,
            command: str | None = None, args: list[str] | None = None, expires: str | None = None,
            cwd: str | None = None, record: str | None = None, allow: list[str] | None = None,
            read: list[str] | None = None, ask: str | None = None, options: list[str] | None = None,
            seat: str | None = None, model: str | None = None, effort: str | None = None,
            timeout: str | None = None, max_budget_usd: float | None = None,
            now: datetime | None = None, caller_cwd: str | None = None) -> dict:
    """Validate, freeze and store one declaration. ``now`` and ``caller_cwd`` are test seams."""
    args, allow, read, options = list(args or []), list(allow or []), list(read or []), list(options or [])
    now = now or datetime.now(timezone.utc)
    caller_cwd = caller_cwd or os.getcwd()

    # --- shape (usage errors) -------------------------------------------------------------------
    inferred = "agent" if prompt_file else "command" if command else None
    if prompt_file and command:
        raise errors.Usage("give --prompt-file (an agent run) or --command (a command run), not both")
    if not inferred:
        raise errors.Usage("give --prompt-file <file> for an agent run or --command <script> for a command run")
    if kind and kind != inferred:
        raise errors.Usage(f"--kind {kind} needs --{'prompt-file' if kind == 'agent' else 'command'}")
    kind = inferred
    if kind == "agent":
        if args:
            raise errors.Usage("arguments after -- belong to --command; an agent run takes none")
    else:
        stray = [f for f, v in (("--allow", allow), ("--read", read), ("--seat", seat), ("--model", model),
                                ("--effort", effort), ("--max-budget-usd", max_budget_usd)) if v]
        if stray:
            raise errors.Usage(f"{', '.join(stray)} configure an agent run; a command run takes none")
    title = (title or "").strip()
    if not title or "\n" in title:
        raise errors.Usage("--title must be one non-empty line; it is shown on every surface")
    if options and not ask:
        raise errors.Usage("--option needs --ask: an option answers a question")
    parsed_options = [parse_option(o) for o in options]
    labels = [o["label"] for o in parsed_options]
    if len(set(labels)) != len(labels):
        raise errors.Usage(f"--option labels must be unique: {labels}")
    for rule in allow:
        if not re.fullmatch(r"Bash\((?!\*?\))(?!:\*\)).+\)", rule):
            raise errors.Usage(f"--allow {rule!r} is not a Bash(...) rule; reads go in --read, "
                               f"and a run writes only its own out_dir")
    read_rules = []
    for r in read:
        p = Path(r).expanduser()
        if not p.is_absolute():
            raise errors.Usage(f"--read {r!r} must be an absolute path")
        read_rules.append(f"{p}/**" if p.is_dir() else str(p))
    if max_budget_usd is not None and not max_budget_usd > 0:
        raise errors.Usage("--max-budget-usd must be more than 0")

    # --- when (refusals) -----------------------------------------------------------------------
    not_before = parse_time(at, "--at")
    expires_at = parse_time(expires, "--expires") if expires else not_before + DEFAULT_EXPIRY
    if not_before < now:
        raise errors.Refused(f"--at {_local(_iso(not_before))} is in the past")
    if expires_at <= not_before:
        raise errors.Refused(f"--expires {_local(_iso(expires_at))} is not after --at {_local(_iso(not_before))}")
    if not_before - now > MAX_HORIZON:
        raise errors.Refused(f"--at {_local(_iso(not_before))} is more than {MAX_HORIZON.days} days "
                             f"ahead, the maximum horizon")

    # --- where ---------------------------------------------------------------------------------
    run_cwd = Path(cwd or caller_cwd).expanduser()
    if not run_cwd.is_absolute():
        run_cwd = Path(caller_cwd) / run_cwd
    run_cwd = run_cwd.resolve()
    if not run_cwd.is_dir():
        raise errors.Usage(f"--cwd {run_cwd} is not a directory")
    if out_root(ctx).resolve().is_relative_to(run_cwd):
        raise errors.Refused(
            f"--cwd {run_cwd} contains the run's out_dir (under {out_root(ctx)}): a run must not "
            f"start in a directory that holds its own and every other run's output")

    # --- what ----------------------------------------------------------------------------------
    source, raw, text = _read_payload(prompt_file or command, "--prompt-file" if kind == "agent" else "--command")
    if kind == "command":
        hit = _claude_hit(text) or next((f"argument {a!r}" for a in args if CLAUDE_WORD.search(a)), None)
        if hit:
            raise errors.Refused(
                f"--command {source} invokes `claude` ({hit}): a command run spends no seat and passes "
                f"no budget gate, so it must not start an agent. Schedule it with --kind agent")
        seat_pick = None
        timeout_s = int((parse_duration(timeout, "--timeout") if timeout else COMMAND_TIMEOUT).total_seconds())
        memory_max, budget = COMMAND_MEMORY_MAX, None
    else:
        seat_pick = budget_mod.seat_for(ctx.tenant, "local", override=seat)
        timeout_s = int((parse_duration(timeout, "--timeout") if timeout else AGENT_TIMEOUT).total_seconds())
        memory_max = ctx.tenant.lanes.memory_max
        budget = max_budget_usd if max_budget_usd is not None else AGENT_MAX_BUDGET_USD

    # --- the record ----------------------------------------------------------------------------
    record_path = None
    if record:
        given = Path(record).expanduser()
        if not given.is_absolute():
            given = Path(caller_cwd) / given
        if not given.is_file():
            raise errors.Usage(f"--record {record!r} must be an existing regular file")
        candidates = list(dict.fromkeys([given, given.resolve()]))   # the link AND what it points at
        _refuse_tracked(ctx, candidates)
        _refuse_guarded(ctx, candidates)
        record_path = str(given.resolve())

    # --- the queue is read (last: see the module docstring) ------------------------------------
    timer = _refuse_disarmed(ctx)

    sched_id = f"s-{uuid.uuid4().hex[:8]}"
    while ctx.store.get_schedule(sched_id) or (ctx.state_dir / "schedules" / sched_id).exists():
        sched_id = f"s-{uuid.uuid4().hex[:8]}"
    payload_name = "prompt.md" if kind == "agent" else "script"
    sched_dir = ctx.state_dir / "schedules" / sched_id
    stamp = _iso(now)
    row = {"id": sched_id, "tenant": ctx.tenant.name, "kind": kind, "title": title, "cwd": str(run_cwd),
           "payload_source": str(source), "payload_path": str(sched_dir / payload_name),
           "payload_sha256": hashlib.sha256(raw).hexdigest(), "args": args if kind == "command" else None,
           "not_before": _iso(not_before), "expires_at": _iso(expires_at),
           "seat": seat_pick,
           "model": (model or ctx.tenant.lanes.default_model) if kind == "agent" else None,
           "effort": (effort or ctx.tenant.lanes.default_effort) if kind == "agent" else None,
           "est_minutes": math.ceil(timeout_s / 60) if kind == "agent" else None,
           "allow": allow if kind == "agent" else None, "read": read_rules if kind == "agent" else None,
           "record": record_path, "ask": ask, "options": parsed_options or None,
           "timeout_s": timeout_s, "memory_max": memory_max, "max_budget_usd": budget,
           "max_attempts": MAX_ATTEMPTS, "status": "pending", "attempt": 0, "created_at": stamp,
           "updated_at": stamp, "created_from_cwd": caller_cwd,
           "created_from_session": ctx.env.get("CLAUDE_CODE_SESSION_ID")}
    if ctx.dry_run:
        return {**declaration(row), "timer": timer,
                "dry_run": f"nothing written (schedules row, frozen payload under {sched_dir})"}
    _freeze(ctx, sched_id, [(payload_name, raw, text, 0o400 if kind == "agent" else 0o500)])
    try:
        ctx.store.insert_schedule(row)
    except BaseException:
        shutil.rmtree(sched_dir, ignore_errors=True)
        raise
    return {**declaration(ctx.store.get_schedule(sched_id)), "timer": timer}


def _tenant_row(ctx, sched_id: str) -> dict:
    row = ctx.store.get_schedule(sched_id)
    if row is None:
        raise errors.Usage(f"no schedule {sched_id!r}")
    if row["tenant"] != ctx.tenant.name:
        # --state-dir can point one tenant at another's store; acting across that line is refused.
        raise errors.Refused(f"schedule {sched_id!r} belongs to tenant {row['tenant']!r}, not {ctx.tenant.name!r}")
    return row


def run_show(ctx, sched_id: str) -> dict:
    """The declaration, plus whether the frozen payload still hashes to what was declared."""
    out = declaration(_tenant_row(ctx, sched_id))
    p = Path(out["payload_path"])
    out["payload_intact"] = p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest() == out["payload_sha256"]
    return out


def run_cancel(ctx, sched_id: str, now: datetime | None = None) -> dict:
    """A pending run becomes ``cancelled``. Anything else refuses: a terminal row is settled, and a
    running one has a live unit this command does not stop. The frozen payload is kept."""
    row = _tenant_row(ctx, sched_id)
    if row["status"] not in CANCELLABLE:
        raise errors.Refused(f"schedule {sched_id} is {row['status']}; only a "
                             f"{'/'.join(CANCELLABLE)} run can be cancelled")
    if ctx.dry_run:
        return {**row, "status": "cancelled", "dry_run": "nothing written (schedules row)"}
    stamp = _iso(now or datetime.now(timezone.utc))
    ctx.store.update_schedule(sched_id, status="cancelled", ended_at=stamp, updated_at=stamp,
                              last_reason="cancelled by rabota schedule cancel")
    return ctx.store.get_schedule(sched_id)


def _summary(row: dict) -> dict:
    return {k: row[k] for k in ("id", "tenant", "kind", "status", "title", "not_before", "expires_at",
                                "attempt", "last_reason")}


def _check_status(status):
    # An EMPTY --status is refused, not read as "no filter" — the reasoning in `lane list`.
    if status is not None and status not in STATUSES:
        raise errors.Usage(f"--status must be one of {STATUSES}, got {status!r}")


def run_list(ctx, status: str | None = None) -> dict:
    _check_status(status)
    return {"tenant": ctx.tenant.name,
            "schedules": [_summary(r) for r in ctx.store.list_schedules(ctx.tenant.name, status)]}


def run_list_all(cfg, status: str | None = None) -> dict:
    """Every tenant's runs, each from its own store. A tenant with no store has no runs and none is
    created for it; a store that cannot be read fails the listing (exit 4), never shows as empty."""
    _check_status(status)
    rows, failed = [], []
    for name, tenant in sorted(cfg.tenants.items()):
        state_dir = Path(tenant.state_dir).expanduser()
        if not (state_dir / "rabota.db").is_file():
            continue
        try:
            s = store.Store.open(state_dir)
        except errors.RabotaError as e:
            failed.append({"tenant": name, "error": str(e)}); continue
        try:
            rows += [_summary(r) for r in s.list_schedules(name, status)]
        finally:
            s.close()
    if failed:
        raise errors.Partial(f"could not read the schedules of {', '.join(f['tenant'] for f in failed)}", failed)
    return {"tenant": None, "schedules": sorted(rows, key=lambda r: (r["not_before"], r["id"]))}


def _build(sub):
    p = sub.add_parser("schedule", help="declare a run for later; list, show or cancel one")
    s = p.add_subparsers(dest="schedule_cmd", required=True)
    a = s.add_parser("add", help="declare a run (the global --dry-run validates and prints it only)")
    a.add_argument("--at", required=True, help="local time, 'YYYY-MM-DD HH:MM'")
    a.add_argument("--title", required=True)
    a.add_argument("--kind", choices=KINDS, default=None, help="inferred from --prompt-file/--command")
    a.add_argument("--prompt-file", default=None)
    # dest is NOT "command": the top-level parser keys the subcommand by that name, and an option
    # spelled the same overwrote it, so `cli.main` looked up the script path as a command.
    a.add_argument("--command", dest="script", default=None, help="a script file; its arguments go after --")
    a.add_argument("args", nargs="*", help=argparse.SUPPRESS)
    a.add_argument("--expires", default=None, help=f"local time; default --at + {DEFAULT_EXPIRY}")
    a.add_argument("--cwd", default=None, help="where the run starts; default the current directory")
    a.add_argument("--record", default=None, help="an existing untracked file the result is appended to")
    a.add_argument("--allow", action="append", default=[], help="a Bash(...) rule; repeatable")
    a.add_argument("--read", action="append", default=[], help="an absolute path; repeatable")
    a.add_argument("--ask", default=None)
    a.add_argument("--option", action="append", default=[], help="<label>[=none|rerun[:+24h]|cancel-followups]")
    a.add_argument("--seat", default=None)
    a.add_argument("--model", default=None)
    a.add_argument("--effort", default=None)
    a.add_argument("--timeout", default=None, help="<n>[smhd]")
    a.add_argument("--max-budget-usd", type=float, default=None)
    l = s.add_parser("list", help="list runs, tenant-scoped unless --all-tenants")
    l.add_argument("--status", default=None)
    l.add_argument("--all-tenants", action="store_true")
    sh = s.add_parser("show", help="print one run's whole declaration")
    sh.add_argument("id")
    c = s.add_parser("cancel", help="cancel a pending run")
    c.add_argument("id")


def _run(ns, **ctx_kw):
    cmd = ns.schedule_cmd
    if cmd == "list" and ns.all_tenants:
        if ns.tenant or ns.state_dir:
            raise errors.Usage("--all-tenants reads every tenant's own store; it takes no --tenant or --state-dir")
        out = run_list_all(config.load(ctx_kw.get("cfg_base")), ns.status)
    else:
        ctx = Context.from_namespace(ns, **ctx_kw)
        if cmd == "list":
            out = run_list(ctx, ns.status)
        elif cmd == "show":
            out = run_show(ctx, ns.id)
        elif cmd == "cancel":
            out = run_cancel(ctx, ns.id)
        else:
            out = run_add(ctx, at=ns.at, title=ns.title, kind=ns.kind, prompt_file=ns.prompt_file,
                          command=ns.script, args=ns.args, expires=ns.expires, cwd=ns.cwd, record=ns.record,
                          allow=ns.allow, read=ns.read, ask=ns.ask, options=ns.option, seat=ns.seat,
                          model=ns.model, effort=ns.effort, timeout=ns.timeout,
                          max_budget_usd=ns.max_budget_usd)
    if not ns.text:
        return out
    if cmd == "list":
        return [f"{r['id']} {r['status']} {r['kind']} {_local(r['not_before'])} {r['tenant']}: {r['title']}"
                for r in out["schedules"]] or ["no scheduled runs"]
    if cmd == "cancel":
        return [f"{out['id']} {out['status']}"] + ([f"dry-run: {out['dry_run']}"] if out.get("dry_run") else [])
    return _lines(out)


cli.register("schedule", _build, _run)
