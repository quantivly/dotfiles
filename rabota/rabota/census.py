"""One fleet view, and the IMP-3189 push payload verbatim.

Owners come from cgroup membership, never from cwd (Zvi's own attached session in a lane worktree
is `user`). No argv and no environment is ever read: `comm`, `cwd`, `cgroup`, `stat` only. Every
dimension that could not be measured is named in ``unavailable[]``; none is ever reported as zero.
"""
import json
import os
import re
import time
from pathlib import Path

from rabota import secrets, sysinfo
from rabota.store import now

CLK_TCK = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
SOL_UNIT, RABOTA_PREFIX = "nanoclaw-orchestrate.service", "/rabota-"
UNIT_PREFIXES = ("rabota-", "orch-lane-")
DEFERRED = ["deferred:sol", "deferred:machines"]   # design §4.2: shipped at S1
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


def worktrees(runner) -> tuple[list[dict], list[str]]:
    """``wt-gc --tsv`` rows; a failed call is ``unavailable: worktrees``."""
    res = runner.run(["wt-gc", "--tsv"], timeout=120)
    if not res.ok:
        return [], ["worktrees"]
    rows = []
    for line in res.out.splitlines():
        parts = line.split("\t")
        if len(parts) >= 4 and parts[0] != "path":
            rows.append({"path": parts[0], "repo": parts[1], "branch": parts[2], "verdict": parts[3],
                         "reason": parts[4] if len(parts) > 4 else ""})
    return rows, []


def settle_finished(ctx, units: list[dict], seats: list[dict]) -> list[str]:
    """A ``started`` row whose unit is gone and whose stream has a result line is settled from that line.

    ``ended_at``, ``cost_usd`` (``result.total_cost_usd``) and ``five_h_pct_at_end`` (the seat's
    current reading) are written; ``status`` becomes ``done`` or ``failed`` per ``is_error``. A row
    whose unit is still active, or whose stream has no result yet, is left alone (``reap`` handles
    abandonment). Returns the ids settled.
    """
    live = {u["name"] for u in units if u.get("state") in ("active", "activating")}
    pct = {s["name"]: s.get("five_h_pct") for s in seats}
    settled = []
    for lane in ctx.store.list_lanes(ctx.tenant.name, status="started"):
        if lane.get("unit") in live:
            continue
        stream = Path(lane["out_dir"]) / "stream.jsonl"
        if not stream.exists():
            continue
        result = None
        for line in stream.read_text().splitlines():
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and obj.get("type") == "result":
                result = obj
        if result is None:
            continue
        ctx.store.update_lane(lane["id"], status="failed" if result.get("is_error") else "done", ended_at=now(),
                              cost_usd=result.get("total_cost_usd"), five_h_pct_at_end=pct.get(lane.get("seat")))
        settled.append(lane["id"])
    return settled


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
    unavailable += u0 + u1 + u2 + u3
    settle_finished(ctx, us, st)
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
           "sessions": sess, "units": us, "seats": st, "worktrees": wt, "counts": counts, "unavailable": unavailable}
    ctx.state_dir.mkdir(parents=True, exist_ok=True)
    # Written through the same guard emit applies to stdout: a contract file is output too.
    text = secrets.assert_clean(json.dumps(out, indent=1, sort_keys=True) + "\n", os.environ)
    (ctx.state_dir / "census.json").write_text(text)
    return out
