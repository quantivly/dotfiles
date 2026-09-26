"""One fleet view, and the IMP-3189 push payload verbatim.

Owners come from cgroup membership, never from cwd (Zvi's own attached session in a lane worktree
is `user`). No argv and no environment is ever read: `comm`, `cwd`, `cgroup`, `stat` only. Every
dimension that could not be measured is named in ``unavailable[]``; none is ever reported as zero.
"""
import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path

from rabota import remote, secrets, sysinfo
from rabota.store import now

CLK_TCK = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
SOL_UNIT, RABOTA_PREFIX = "nanoclaw-orchestrate.service", "/rabota-"
UNIT_PREFIXES = ("rabota-", "orch-lane-")
DEFERRED = ["deferred:sol"]   # design §4.2: machines[] shipped by the remote-lanes plan
# A Claude Code process is named `claude` when started through the wrapper and by its VERSION when a
# headless lane execs the versioned binary directly (`.../claude/versions/2.1.273 -p …`) — which is
# exactly what `lane recipe` and the orchestrator's manual recipe do. Measured 2026-09-16: this
# lane's own process was `2.1.273` inside rabota-impl-ws4p.service, and a comm == "claude" filter
# reported `rabota 0` while it ran. herdmates teammates carry the same shape (CLAUDE.md).
CLAUDE_COMM = re.compile(r"^(claude|\d+\.\d+\.\d+)$")
# A process that exits between two reads raises one of these. That is a VANISH, not a reader
# failure: the design drops it and records nothing, because there is no session left to be
# unmeasured about. Every other OSError (EACCES under hidepid, EINVAL on a cwd that is not a link,
# EIO) is a session the census could not measure, and is named in ``unavailable[]`` — never
# guessed, never silently dropped (fix brief ws4p-fix, defect 3; design §4.2).
_GONE = (FileNotFoundError, ProcessLookupError)
READERS = ("comm", "stat", "cwd", "cgroup")


def _owner_from(cg: str) -> str:
    if SOL_UNIT in cg:
        return "sol"
    if RABOTA_PREFIX in cg:
        return "rabota"
    return "user"


def owner_of(proc: Path, pid: int) -> str:
    """``sol`` inside Sol's unit cgroup, ``rabota`` inside a ``rabota-*`` unit, ``user`` otherwise.

    ``unknown`` when the cgroup file cannot be read — not ``user``: a reader that fails must not
    answer with the most common value, because that is exactly the answer that hides the failure.
    """
    try:
        cg = (proc / str(pid) / "cgroup").read_text()
    except OSError:
        return "unknown"
    return _owner_from(cg)


def _unit_from(cg: str) -> str | None:
    """The lane or Sol unit named by a cgroup path, or None for anything else (herdr, a session scope)."""
    leaf = cg.strip().rsplit("/", 1)[-1]
    if not leaf.endswith((".service", ".scope")):
        return None
    return leaf if leaf.startswith(UNIT_PREFIXES) or leaf == SOL_UNIT else None


def _stat(proc: Path, pid: int):
    """(utime+stime ticks, starttime ticks) from /proc/<pid>/stat; the comm field may contain spaces."""
    text = (proc / str(pid) / "stat").read_text()
    rest = text[text.rindex(")") + 2:].split()      # rest[0] is field 3 (state)
    return int(rest[11]) + int(rest[12]), int(rest[19])   # fields 14+15, field 22


def _claude_pids(proc: Path, failed: dict) -> list[int]:
    """PIDs whose comm names Claude Code: `claude`, or a bare version triple (the versioned binary).

    A comm that cannot be read is a process the census cannot rule in OR out; it is counted in
    ``failed["comm"]`` rather than assumed to be something else.
    """
    pids = []
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if CLAUDE_COMM.match((entry / "comm").read_text().strip()):
                pids.append(int(entry.name))
        except _GONE:
            continue
        except OSError:
            failed["comm"] += 1
    return pids


def sessions(proc: Path, sample_seconds: float, sleeper=time.sleep) -> tuple[list[dict], list[str]]:
    """Every ``claude`` process: pid, cwd, owner, age and a CPU sample over ``sample_seconds``.

    Returns ``(rows, unavailable)``. A process that vanishes between reads is dropped and nothing
    is recorded. A process a reader FAILS on is never guessed about: an unreadable ``cgroup``
    carries the row with ``owner: "unknown"``; an unreadable ``comm``, ``stat`` or ``cwd`` drops
    the row, since nothing else about it can be measured — and each is counted in ``unavailable``
    as ``sessions:<n>:<reader>``. Nothing here opens ``environ`` or ``cmdline``.
    """
    failed = dict.fromkeys(READERS, 0)
    uptime = float((proc / "uptime").read_text().split()[0])
    first = {}
    for pid in _claude_pids(proc, failed):
        try:
            ticks, start = _stat(proc, pid)
        except _GONE:
            continue
        except OSError:
            failed["stat"] += 1
            continue
        try:
            cwd = os.readlink(proc / str(pid) / "cwd")
        except _GONE:
            continue
        except OSError:
            failed["cwd"] += 1
            continue
        first[pid] = (ticks, int(uptime - start / CLK_TCK), cwd.replace(" (deleted)", ""))
    sleeper(sample_seconds)
    out = []
    for pid, (ticks, age, cwd) in first.items():
        try:
            ticks2, _ = _stat(proc, pid)
        except _GONE:
            continue
        except OSError:
            failed["stat"] += 1
            continue
        try:
            cg = (proc / str(pid) / "cgroup").read_text()
        except _GONE:
            continue
        except OSError:
            failed["cgroup"] += 1
            owner, unit = "unknown", None
        else:
            owner, unit = _owner_from(cg), _unit_from(cg)
        cpu = 100.0 * (ticks2 - ticks) / CLK_TCK / max(sample_seconds, 0.001)
        out.append({"pid": pid, "cwd": cwd, "owner": owner, "age_s": age,
                    "cpu_pct_5s": round(cpu, 1), "unit": unit})
    return out, [f"sessions:{n}:{reader}" for reader in READERS if (n := failed[reader])]


def units(runner) -> tuple[list[dict], list[str]]:
    """Lane units from ``systemctl --user``; a failed or unparseable call is ``unavailable: units``."""
    res = runner.run(["systemctl", "--user", "list-units", "--output=json", "--all", "rabota-*", "orch-lane-*"], timeout=15)
    if not res.ok:
        return [], ["units"]
    try:
        rows = json.loads(res.out or "[]")
    except json.JSONDecodeError:
        return [], ["units"]
    if not isinstance(rows, list):
        return [], ["units"]
    return [{"name": r["unit"], "state": r.get("active"), "machine": "local"} for r in rows if isinstance(r, dict) and "unit" in r], []


def seats(runner) -> tuple[list[dict], list[str]]:
    """Seat windows from ``clauth status --json``; a stale or non-fresh profile is named in ``unavailable``."""
    res = runner.run(["clauth", "status", "--json"], timeout=20)
    if not res.ok or not res.out.strip():
        return [], ["seats"]
    try:
        d = json.loads(res.out)
    except json.JSONDecodeError:
        return [], ["seats"]
    if not isinstance(d, dict):
        return [], ["seats"]
    out, unavailable = [], []
    for p in d.get("profiles", []) or []:
        if not isinstance(p, dict) or not p.get("name"):
            continue
        w = {x.get("label"): x for x in (p.get("windows") or []) if isinstance(x, dict)}
        five, seven = w.get("5h", {}), w.get("7d", {})
        stale = bool(p.get("stale")) or (p.get("fetch_status") not in (None, "Fresh"))
        if stale:
            unavailable.append(f"seat:{p['name']}:stale")
        out.append({"name": p["name"], "tier": p.get("tier"),
                    "five_h_pct": None if five.get("utilization_pct") is None else int(five["utilization_pct"]),
                    "seven_d_pct": None if seven.get("utilization_pct") is None else int(seven["utilization_pct"]),
                    "resets_at": five.get("resets_at"), "stale": stale})
    return out, unavailable


#: The leading token of a worktree row. wt-gc emits other row types in the same
#: stream — ``STRAY`` with two fields, ``DANGLING`` with five — so a row is
#: selected by this token and anything else is skipped.
WT_GC_VERDICTS = ("REAP", "REVIEW", "PRUNE", "HSPAWN", "KEEP")


def worktrees(runner) -> tuple[list[dict], list[str]]:
    """``wt-gc --tsv`` worktree rows; a failed call is ``unavailable: worktrees``.

    The schema is ``verdict path branch pr dirty unpushed age reason``, eight
    fields, with **no header line**. This function read it as
    ``path repo branch verdict reason`` until 2026-09-22, so every row recorded
    the verdict as the path and the path as the repo — and the fixture encoded
    that same wrong schema, which is why the tests passed the whole time. Select
    rows by their first field, never by position or column count: positioning
    mislabels every row silently the day a new row type appears, and this stream
    now has three.
    """
    res = runner.run(["wt-gc", "--tsv"], timeout=120)
    if not res.ok:
        return [], ["worktrees"]
    rows = []
    for line in res.out.splitlines():
        parts = line.split("\t")
        if len(parts) < 8 or parts[0] not in WT_GC_VERDICTS:
            continue
        rows.append({"verdict": parts[0], "path": parts[1], "branch": parts[2], "pr": parts[3],
                     "dirty": parts[4], "unpushed": parts[5], "age": parts[6], "reason": parts[7]})
    return rows, []


# A lane's own output artifact (DO-747, amended DO-747 fix round): work-lane briefs are free
# text, and this project's own history has lanes told to write `fix-verdict.json`,
# `rebase-verdict.json`, `evaluation-2.json` and the like -- a fixed list of three names
# (`verdict.json`, `review.json`, `evaluation.json`) would settle any of those lanes `failed` with
# a wrong `settle_reason` even though the lane succeeded. The rule that cannot drift: a lane counts
# as having produced output when its out_dir holds ANY `*.json` file. `rabota` itself never writes
# one there -- a lane's out_dir carries only `brief.md`, `_common-rules.md`, `stream.jsonl` and
# `stream.err` (see `lane.py`'s `build_local`/`create_worktree_remote`/`send_brief` and this
# module's own `_ended_at`), so this glob can never true-positive on rabota's own scaffolding.
NO_OUTPUT_REASON = "no output file: no *.json file was written to out_dir before the lane's unit exited"


def _output_mtime_local(out_dir: str) -> float | None:
    """The newest mtime among ``out_dir``'s ``*.json`` files, or ``None`` if none exist.

    At most one is ever expected for a given lane; ``max`` over whichever are readable is so a
    stray leftover file from a prior lane reusing the directory can never make this return
    ``None`` when a real one is present, not a claim that more than one is normal. A missing
    ``out_dir`` glob-matches to nothing (no ``OSError``), same as a directory with no ``*.json``
    in it -- both mean "no output".
    """
    mtimes = [p.stat().st_mtime for p in Path(out_dir).glob("*.json")]
    return max(mtimes) if mtimes else None


def _ended_at(out_dir: str) -> str:
    """The lane's own end time: its output artifact's mtime, not when a later census run noticed it.

    DO-714: settling from ``now()`` gave every lane a census settled together the SAME
    ``ended_at`` -- the census's own timestamp, not theirs -- inflating durations by however
    long the lane sat finished before a census happened to run. The artifact is written once,
    when the lane actually finishes (spec §C6), so its mtime is the real end time. A lane with no
    readable output artifact here (settled from another machine's stream text, or no output at
    all) falls back to ``now()`` -- not knowing the real end time is not the same as it being now,
    but it is the least-wrong answer available locally.
    """
    mtime = _output_mtime_local(out_dir)
    if mtime is None:
        return now()
    return datetime.fromtimestamp(mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ended_at_remote(epoch_s: str) -> str:
    """As ``_ended_at``, but for a lane on another machine: the verdict mtime already rode back as
    an epoch-seconds string in this same census ssh call (DO-722; ``remote.parse``'s
    ``verdict_mtimes``), because the local ``stat`` that ``_ended_at`` does can never see a file
    on a machine this process is not running on. An empty string -- ``stat`` failed remotely (no
    verdict written yet, or none at all) -- gets the same honest ``now()`` fallback as the local
    case, and so does any value that is not a readable epoch at all. Not knowing the real end time
    is not the same as it being now, but it is the least-wrong answer available, and it is the only
    one that keeps another host's bytes from crashing the census that read them.
    """
    epoch_s = (epoch_s or "").strip()
    if not epoch_s:
        return now()
    try:
        return datetime.fromtimestamp(int(epoch_s), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OverflowError, OSError):
        # These bytes came off another host. `remote.read`'s broad catch is around `parse` building
        # the row, not around this -- so an exception here escapes `settle_finished` and crashes the
        # whole census run, which is exactly what `remote.py`'s contract says must never happen: a
        # shape it cannot read is a measurement of "unknown", never an exception in the caller.
        # `int()` alone raises ValueError, but a syntactically fine yet unbounded value
        # (`99999999999999999999`) reaches `fromtimestamp` and raises OverflowError or OSError
        # instead, depending on platform.
        return now()


def _settle_row(ctx, lane: dict, text: str, has_output: bool, ended_at: str, pct: dict,
                dry_run: bool) -> str | None:
    """Settle ONE ``started`` row from its already-read stream ``text``.

    The caller has already established the lane's unit is gone (``settle_finished``'s
    ``live``-set check across every started lane, or ``lane retire``'s single-unit check for just
    one) — this function does not check liveness itself, only what the two callers cannot share:
    parsing the stream's last ``result`` line, the DO-747 output-file rule, and the DO-722
    ``ended_at`` clamp. Split out of ``settle_finished`` (DO-713) precisely so ``lane retire`` can
    settle one lane with these exact semantics without reimplementing them — the row a lane gets
    from ``retire`` must be identical to the one ``census`` would have produced for it.

    Returns the status settled to (``"done"`` or ``"failed"``), or ``None`` when ``text`` carries
    no ``result`` line yet — the unit is gone but the CLI has not flushed one, which is not
    settleable now (``reap`` handles abandonment, not this).
    """
    result = None
    for line in text.splitlines():
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict) and obj.get("type") == "result":
            result = obj
    if result is None:
        return None
    started_at = lane.get("started_at")
    if started_at and ended_at < started_at:
        # A negative duration is a worse untruth than the one this whole change fixes -- clock
        # skew between machines, or a verdict mtime that predates the lane's own started_at
        # row, must never read as the lane having ended before it began.
        ended_at = started_at
    if has_output:
        status, settle_reason = ("failed" if result.get("is_error") else "done"), None
    else:
        status = "failed"
        settle_reason = NO_OUTPUT_REASON
    if not dry_run:   # DO-753 review: a dry census reports what would settle and writes no row
        ctx.store.update_lane(lane["id"], status=status, ended_at=ended_at, settle_reason=settle_reason,
                              cost_usd=result.get("total_cost_usd"), five_h_pct_at_end=pct.get(lane.get("seat")))
    return status


def settle_finished(ctx, units: list[dict], seats: list[dict], machines: list[dict] | None = None,
                    dry_run: bool = False) -> list[str]:
    """A ``started`` row whose unit is gone and whose stream has a result line is settled from that line.

    ``ended_at``, ``cost_usd`` (``result.total_cost_usd``) and ``five_h_pct_at_end`` (the seat's
    current reading) are written; ``status`` becomes ``done`` or ``failed`` per ``is_error`` --
    UNLESS the lane's out_dir has no ``*.json`` file in it, in which case it settles ``failed``
    regardless of ``is_error``, with ``settle_reason`` naming the absence (DO-747: a headless lane
    that put its whole brief into a backgrounded subagent and ended its turn printed a clean
    ``is_error: false`` result with no ``review.json`` ever written, and the row settled ``done``).
    A row whose unit is still active, or whose stream has no result yet, is left alone (``reap``
    handles abandonment). Returns the ids settled. (The actual settle -- result parsing, the
    output-file rule, the ``ended_at`` clamp -- is ``_settle_row``, shared with ``lane retire``.)

    A lane on another machine is settled from that machine's ``machines[]`` row — its stream lives
    there, so the local filesystem read below can never see it. An unreachable machine settles
    nothing: not knowing is not the same as finished. Its ``ended_at`` (DO-722) and output presence
    both come from that same row's ``verdict_mtimes`` -- the remote machine's own measurement,
    ridden back in the one ssh call ``machines()`` already makes -- rather than a local ``stat``,
    which can never see a file on a machine this process is not running on. Either way ``ended_at``
    is clamped to never precede the lane's own ``started_at``.

    Timing: the output file, when a lane writes one at all, is written by a tool call strictly
    inside the agent's own turn -- before the CLI ever prints the terminating ``result`` line to
    ``stream.jsonl`` and exits. Because this function only reaches a lane once its unit is already
    gone (checked above) AND a ``result`` line is present, the file (if the lane wrote one) is
    already fully on disk by the time either the local ``stat`` or the remote ssh's ``stat`` runs
    -- both happen-after the same process exit that also produced the ``result`` line. There is no
    window where "unit gone, result line present, output not yet visible" is a live possibility for
    a lane that did write one; it is only ever genuinely absent.
    """
    by_name = {m["name"]: m for m in (machines or [])}
    # Keyed by (machine, unit) rather than unit alone: unit names are only unique per machine,
    # and a flat set lets an active unit on one machine suppress a finished lane's settle on
    # another — losing that lane's cost with no error anywhere.
    live = {("local", u["name"]) for u in units if u.get("state") in ("active", "activating")}
    for m in by_name.values():
        live |= {(m["name"], u["name"]) for u in m.get("units", [])
                 if u.get("state") in ("active", "activating")}
    pct = {s["name"]: s.get("five_h_pct") for s in seats}
    settled = []
    for lane in ctx.store.list_lanes(ctx.tenant.name, status="started"):
        machine = lane.get("machine") or "local"
        if (machine, lane.get("unit")) in live:
            continue
        if machine == "local":
            stream = Path(lane["out_dir"]) / "stream.jsonl"
            if not stream.exists():
                continue
            text = stream.read_text()
            ended_at = _ended_at(lane["out_dir"])
            has_output = _output_mtime_local(lane["out_dir"]) is not None
        else:
            row = by_name.get(machine)
            if not row or not row.get("reachable"):
                continue
            text = row.get("streams", {}).get(lane["out_dir"], "")
            mtime_s = row.get("verdict_mtimes", {}).get(lane["out_dir"], "")
            ended_at = _ended_at_remote(mtime_s)
            has_output = bool((mtime_s or "").strip())
        status = _settle_row(ctx, lane, text, has_output, ended_at, pct, dry_run)
        if status is not None:
            settled.append(lane["id"])
    return settled


def machines(ctx) -> tuple[list[dict], list[str]]:
    """One row per machine this tenant declares, each measured in one ssh call.

    An unreachable machine still gets a row — with ``reachable: False`` — and its name in
    ``unavailable``. Readers must refuse on it; a missing row and a zeroed row are the two
    ways this becomes "plenty of room" by accident.
    """
    rows, unavailable = [], []
    for name, m in sorted(ctx.tenant.machines.items()):
        out_dirs = [l["out_dir"] for l in ctx.store.list_lanes(ctx.tenant.name, status="started")
                    if l.get("machine") == name and l.get("out_dir")]
        row = remote.read(ctx.runner, m, out_dirs)
        if not row.get("reachable"):
            unavailable.append(f"machine:{name}")
        rows.append(row)
    return rows, unavailable


def gather(ctx, proc: Path = Path("/proc"), sample_seconds: float = 3.0, sleeper=time.sleep,
           include_worktrees: bool = True) -> dict:
    """Measure everything, settle finished lanes, write ``<state_dir>/census.json`` and return it.

    ``include_worktrees=False`` skips the ``wt-gc`` subprocess entirely (it is the slow dimension —
    a `gh` call per worktree) and reports ``"skipped:worktrees"`` in ``unavailable[]``, distinct from
    the ``"worktrees"`` marker a failed call still uses: a reader must be able to tell "we asked and
    it broke" from "we chose not to ask" (design §4.2).
    """
    unavailable = list(DEFERRED)
    sess, u0 = sessions(proc, sample_seconds, sleeper)
    us, u1 = units(ctx.runner); st, u2 = seats(ctx.runner)
    if include_worktrees:
        wt, u3 = worktrees(ctx.runner)
    else:
        wt, u3 = [], ["skipped:worktrees"]
    ms, u4 = machines(ctx)
    unavailable += u0 + u1 + u2 + u3 + u4
    settled = settle_finished(ctx, us, st, machines=ms, dry_run=ctx.dry_run)
    si = sysinfo.read(proc)
    # ``unknown`` is its own count, so user + sol + rabota do not silently sum to fewer than
    # sessions — the counts must not imply a certainty the readers did not have.
    counts = {"sessions": len(sess), "user": sum(s["owner"] == "user" for s in sess),
              "sol": sum(s["owner"] == "sol" for s in sess), "rabota": sum(s["owner"] == "rabota" for s in sess),
              "unknown": sum(s["owner"] == "unknown" for s in sess),
              "units_active": sum(u.get("state") == "active" for u in us)}
    out = {"schema": 1, "at": now(),
           "machine": {"load1": si.load1, "ncpu": si.ncpu, "mem_available_gib": round(si.mem_available_gib, 1),
                       "swap_used_pct": si.swap_used_pct},
           "sessions": sess, "units": us, "seats": st, "worktrees": wt, "machines": ms, "counts": counts,
           "unavailable": unavailable}
    # DO-753: the measurement above still runs on a dry census, but nothing is written: not
    # `census.json`, and not the lane rows `settle_finished` would have settled (review finding: it
    # used to flip them to done/failed under a message saying nothing was written). The lanes that
    # WOULD settle are reported instead, so a dry run still shows what a real one would do.
    if ctx.dry_run:
        return {**out, "would_settle": settled, "dry_run": "nothing written (census.json, lane rows)"}
    ctx.state_dir.mkdir(parents=True, exist_ok=True)
    # Written through the same guard emit applies to stdout: a contract file is output too.
    text = secrets.assert_clean(json.dumps(out, indent=1, sort_keys=True) + "\n", os.environ)
    (ctx.state_dir / "census.json").write_text(text)
    return out
