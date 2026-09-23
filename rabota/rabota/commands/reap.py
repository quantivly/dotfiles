"""``rabota reap``: mark abandoned lane rows, list idle user sessions, delegate laptop worktrees
to ``wt-gc``, and remove the REMOTE lane worktrees of settled lanes.

Dry-run by default (``--apply`` is required to act). Never kills a user session (locked decision,
spec §... — a session is only ever *listed* with a ``close_hint`` the human runs themselves).
Spaces wait on the herdr snapshot dimension and are deferred here: listed as ``[]`` and named in
``unavailable``.

A lane worktree on a REMOTE machine (``machines.dev`` and friends) is a full checkout that
accumulates on the machine a lane ran on — ``wt-gc`` only ever looks at the laptop. This module
removes those too, once their lane row is SETTLED (``done``/``failed``/``abandoned``/``retired``):
a ``started`` row's worktree is still in use. The lane's ``out_dir`` is never touched here — it
holds ``verdict.json``, the durable evidence, while the worktree is just a reproducible checkout.

``ctx.dry_run`` (the CLI-wide ``rabota --dry-run`` flag, distinct from this command's own
``--apply``) is honoured by ``apply_reap``: with it set, no ``wt-gc --apply`` call and no remote
removal ssh call are ever made, and the report says so (``{"dry_run": True}``). Marking a
``started`` row ``abandoned`` in ``plan_reap`` is local bookkeeping, not an action on a machine —
the same distinction ``precompute.py`` draws between its Linear-mutating ``auto`` step and its
local-state-writing steps — so ``ctx.dry_run`` does NOT suppress it; it already never runs without
independent evidence (the unit is gone) and already happens on every ``plan_reap`` call, apply or
not (see ``test_abandoned_marking_happens_without_apply``).
"""
import uuid
from datetime import datetime, timezone

from rabota import cli, errors, remote
from rabota.census import gather
from rabota.commands.lane import RETIRED_STATUS, TERMINAL_STATUSES
from rabota.context import Context
from rabota.store import now

SETTLED_STATUSES = set(TERMINAL_STATUSES) | {RETIRED_STATUS}

REAP_MARKER = "---RABOTA-REAP---"
REMOTE_REMOVE_TIMEOUT = 120  # seconds; one ssh call removing several worktrees on one machine


def _hours_since(ts: str | None) -> float | None:
    """``None`` means unmeasured — absent, empty, or unparseable — never a guess. A caller that
    read either case as ``0.0`` would make such a row immortal (never old enough to abandon); one
    that let ``strptime`` raise would kill ``plan_reap`` for the whole tenant over one bad row.
    """
    if not ts:
        return None
    try:
        then = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return (datetime.now(timezone.utc) - then).total_seconds() / 3600


def _live_units(census: dict) -> set[tuple[str, str]]:
    """``{(machine, unit_name)}`` for every unit census saw active or activating.

    Local units come from ``census["units"]``; a remote machine's own units live under its row in
    ``census["machines"]`` instead — reading local units only would read an active REMOTE lane as
    abandoned the moment ``abandoned_hours`` elapsed, since its unit never appears in the local
    list at all.
    """
    live = {("local", u["name"]) for u in census.get("units", []) if u.get("state") in ("active", "activating")}
    for m in census.get("machines", []) or []:
        if not m.get("reachable"):
            continue
        live |= {(m.get("name"), u.get("name")) for u in (m.get("units") or [])
                 if u.get("state") in ("active", "activating")}
    return live


def _remote_worktree_candidates(ctx) -> tuple[list[dict], list[str]]:
    """Settled remote lane rows whose worktree is a candidate for removal.

    A row naming a machine the tenant no longer declares, or a repo the machine no longer
    declares, is left out of the plan rather than guessed about — its id is named in
    ``unavailable`` instead.
    """
    items, unavailable = [], []
    for lane in ctx.store.list_lanes(ctx.tenant.name):
        machine = lane.get("machine")
        if not machine or machine == "local":
            continue
        if lane.get("status") not in SETTLED_STATUSES or not lane.get("worktree"):
            continue
        m = ctx.tenant.machines.get(machine)
        if m is None:
            unavailable.append(f"reap:worktree:{lane['id']}:unknown-machine")
            continue
        repo_path = m.repos.get(lane.get("repo"))
        if not repo_path:
            unavailable.append(f"reap:worktree:{lane['id']}:unknown-repo")
            continue
        items.append({"kind": "remote", "machine": machine, "path": lane["worktree"],
                      "repo_path": repo_path, "lane_id": lane["id"],
                      "reason": f"lane {lane['id']} is {lane['status']}"})
    return items, unavailable


def plan_reap(ctx: Context, census: dict, idle_hours: float = 24, abandoned_hours: float = 6) -> dict:
    live = _live_units(census)
    unreachable = {m["name"] for m in (census.get("machines") or []) if not m.get("reachable")}
    abandoned, ts_unavailable = [], []
    for lane in ctx.store.list_lanes(ctx.tenant.name, status="started"):
        machine = lane.get("machine") or "local"
        if machine in unreachable:
            # Cannot tell abandoned from still-running on a machine census could not reach this
            # round: an unmeasured dimension is never room to act, so it is left for a later call.
            continue
        if (machine, lane.get("unit")) in live:
            continue
        hours = _hours_since(lane.get("started_at"))
        if hours is None:
            # An absent or unparseable started_at is an unmeasured dimension, not room to act
            # (never immortal) and not a reason to fail every other row (never a crash) — it is
            # named here so it is visible rather than silently skipped.
            ts_unavailable.append(f"reap:started_at:{lane['id']}:unmeasured")
            continue
        if hours > abandoned_hours:
            ctx.store.update_lane(lane["id"], status="abandoned", abandoned_at=now())
            abandoned.append({"id": lane["id"], "unit": lane.get("unit"), "reason": f"no unit for {hours:.0f} h"})
    sessions = [{"pid": s["pid"], "cwd": s["cwd"], "reason": f"idle, {s['age_s'] // 3600} h old",
                 "close_hint": f"kill -INT {s['pid']}  # only if you own it; rabota never does"}
                for s in census.get("sessions", []) if s.get("owner") == "user" and (s.get("cpu_pct_5s") or 0) < 1.0
                and (s.get("age_s") or 0) > idle_hours * 3600]
    worktrees = [dict(w, kind="local") for w in census.get("worktrees", []) if w.get("verdict") == "REAP"]
    remote_worktrees, wt_unavailable = _remote_worktree_candidates(ctx)
    worktrees += remote_worktrees
    return {"abandoned": abandoned, "sessions": sessions, "spaces": [], "worktrees": worktrees,
            "unavailable": ["deferred:spaces"] + list(census.get("unavailable", []))
                          + wt_unavailable + ts_unavailable}


def _repo_path_expr(config_value: str) -> str:
    """A shell expression for ``config_value`` that the REMOTE shell expands: a leading ``~``
    becomes a bare, unquoted ``$HOME`` (expanded by the remote's own shell — this process's home
    is never the remote's) immediately followed by the REST of the path, single-quoted so nothing
    else in it is ever interpreted. Anything without a leading ``~`` is single-quoted outright.
    """
    if config_value == "~":
        return "$HOME"
    if config_value.startswith("~/"):
        return "$HOME" + remote.shquote(config_value[1:])
    if config_value.startswith("~"):
        raise errors.Refused(f"cannot expand {config_value!r}: only ~ and ~/ are supported")
    return remote.shquote(config_value)


def _removal_script(items: list[dict], marker: str) -> str:
    """One shell script removing every worktree in ``items``, framed so ONE ssh call reports a
    result per item: each block starts with the (per-call, nonced) ``marker``, then the item's own
    path LENGTH on its own line, then exactly that many bytes of the path (no trailing newline of
    its own), then the removal's exit code on its own line, then its combined stdout+stderr. The
    length prefix is what makes the path field safe to contain a literal newline — a newline is
    just more path bytes, never a field separator, so nothing after it can be shifted the way a
    newline-delimited framing would shift it. Chaining with ``&&`` would hide every failure after
    the first; ``;`` alone would still leave one exit code covering the whole call. This is the
    same per-item framing idiom ``remote.build_argv``/``remote.parse`` use for census's own
    multi-section ssh call.
    """
    parts = []
    for it in items:
        path = it["path"]
        parts.append(f"printf '%s\\n' {remote.shquote(marker)}")
        parts.append(f"printf '%s\\n' {len(path)}")
        parts.append(f"printf '%s' {remote.shquote(path)}")
        repo_expr = _repo_path_expr(it["repo_path"])
        parts.append(
            f"out=$(git -C {repo_expr} worktree remove --force {remote.shquote(path)} 2>&1); "
            f"code=$?; printf '\\n%s\\n' \"$code\"; printf '%s' \"$out\"")
    return "; ".join(parts)


def _parse_removal_output(out: str, marker: str) -> dict[str, dict]:
    """``{path: {"code": int, "output": str}}`` from ``_removal_script``'s framing.

    The path is recovered by LENGTH, not by splitting on ``\\n`` — the length was computed in
    Python (character count of the same ``str`` this module sent to the shell) and is re-applied
    here against the decoded ``str`` the ssh call returned, so a path containing a literal newline
    is sliced out whole rather than truncated at its first line.
    """
    by_path = {}
    for chunk in out.split(marker)[1:]:
        body = chunk[1:] if chunk.startswith("\n") else chunk
        if "\n" not in body:
            continue
        len_s, rest = body.split("\n", 1)
        try:
            length = int(len_s.strip())
        except ValueError:
            continue
        if length < 0 or len(rest) < length + 1 or rest[length] != "\n":
            continue
        path, after = rest[:length], rest[length + 1:]
        if "\n" not in after:
            continue
        code_s, output = after.split("\n", 1)
        try:
            code = int(code_s.strip())
        except ValueError:
            continue
        by_path[path] = {"code": code, "output": output}
    return by_path


def _remove_remote_worktrees(ctx, machine, items: list[dict]) -> dict:
    """Remove every worktree in ``items`` (all on ``machine``) with ONE ssh call.

    An unreachable machine, or a call whose framing could not be parsed, fails every item in the
    batch rather than guessing at a partial result — the caller still gets one entry per
    worktree, naming it as not removed.
    """
    marker = REAP_MARKER + uuid.uuid4().hex
    script = _removal_script(items, marker)
    res = ctx.runner.run(remote.ssh_argv(machine, script), timeout=REMOTE_REMOVE_TIMEOUT)
    if not res.ok:
        err = (res.err or res.out or f"exit {res.code}").strip()[:200]
        return {"removed": [], "failed": [{"path": it["path"], "lane_id": it["lane_id"], "error": err}
                                          for it in items]}
    by_path = _parse_removal_output(res.out, marker)
    removed, failed = [], []
    for it in items:
        r = by_path.get(it["path"])
        if r is None:
            failed.append({"path": it["path"], "lane_id": it["lane_id"], "error": "no result reported"})
        elif r["code"] == 0:
            removed.append(it["path"])
        else:
            failed.append({"path": it["path"], "lane_id": it["lane_id"], "error": r["output"].strip()[:200]})
    return {"removed": removed, "failed": failed}


def apply_reap(ctx: Context, plan: dict, targets: set[str]) -> dict:
    if "sessions" in targets:
        raise errors.Usage("rabota never kills user sessions; use the close hints yourself")
    rep = {"worktrees": None, "remote_worktrees": {"removed": [], "failed": []}, "failed": []}
    if "worktrees" in targets:
        if ctx.dry_run:
            # --dry-run on the most destructive command in the CLI: neither wt-gc nor a remote
            # removal ssh call is ever invoked. See the module docstring for what --dry-run does
            # and does not suppress here.
            rep["dry_run"] = True
            return rep
        res = ctx.runner.run(["wt-gc", "--apply"], timeout=600)
        rep["worktrees"] = res.out[-2000:] if res.ok else None
        if not res.ok:
            rep["failed"].append({"worktrees": res.err[:200]})

        remote_items = [w for w in plan["worktrees"] if w.get("kind") == "remote"]
        by_machine = {}
        for it in remote_items:
            by_machine.setdefault(it["machine"], []).append(it)
        # One machine's ssh call failing (unreachable, or every item refused) does not stop the
        # others: each machine's outcome is independent, and the report below still names every
        # worktree on every machine as removed or not.
        for machine_name, items in sorted(by_machine.items()):
            m = ctx.tenant.machines.get(machine_name)
            if m is None:
                rep["remote_worktrees"]["failed"] += [
                    {"machine": machine_name, "path": it["path"], "lane_id": it["lane_id"],
                     "error": f"tenant declares no machine {machine_name!r}"} for it in items]
                continue
            result = _remove_remote_worktrees(ctx, m, items)
            by_path_lane = {it["path"]: it["lane_id"] for it in items}
            rep["remote_worktrees"]["removed"] += [
                {"machine": machine_name, "path": p, "lane_id": by_path_lane.get(p)} for p in result["removed"]]
            rep["remote_worktrees"]["failed"] += [dict(f, machine=machine_name) for f in result["failed"]]
    return rep


def _build(sub):
    p = sub.add_parser("reap", help="mark abandoned lanes, list idle sessions, "
                                    "reap laptop and remote lane worktrees (dry-run by default)")
    p.add_argument("--apply", action="store_true")
    for t in ("sessions", "spaces", "worktrees"):
        p.add_argument(f"--{t}", action="store_true")
    p.add_argument("--idle-hours", type=float, default=24)
    p.add_argument("--abandoned-hours", type=float, default=6)


def _no_target_message(plan: dict) -> str:
    """Names what ``--apply`` with no target flag would have done, not just the flag it wants —
    an operator who nearly reaped the wrong thing needs to see what they nearly did, not just be
    told the syntax.
    """
    n = len(plan["worktrees"])
    if n:
        machines = sorted({w.get("machine", "local") for w in plan["worktrees"]})
        return (f"--apply requires an explicit target: would have removed {n} "
                f"worktree{'s' if n != 1 else ''} ({', '.join(machines)}); pass --worktrees to do it")
    return "--apply requires an explicit target: nothing to reap right now; pass --worktrees to act anyway"


def _run(ns):
    ctx = Context.from_namespace(ns)
    census = gather(ctx, sample_seconds=2.0)
    plan = plan_reap(ctx, census, ns.idle_hours, ns.abandoned_hours)
    targets = {t for t in ("sessions", "spaces", "worktrees") if getattr(ns, t)}
    if not ns.apply:
        if ns.text:
            lines = [f"abandoned {a['id']}: {a['reason']}" for a in plan["abandoned"]]
            lines += [f"session pid {s['pid']} {s['cwd']}: {s['reason']} -> {s['close_hint']}"
                     for s in plan["sessions"]]
            lines += [f"worktree {w['path']} ({w.get('machine', 'local')}): {w.get('reason') or w.get('verdict', '')}"
                     for w in plan["worktrees"]]
            return lines or ["nothing to reap"]
        return plan
    if not targets:
        raise errors.Usage(_no_target_message(plan))
    return apply_reap(ctx, plan, targets)


cli.register("reap", _build, _run)
