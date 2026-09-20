"""``rabota lane recipe``: render (and optionally run) exactly one lane unit.

The whole lifecycle this command owns is "start it and record one row". No polling, no retire,
no attach: ``census`` observes the unit and settles the row, ``reap`` abandons a stale one.

It is the ONE door a headless lane comes through, which is why every spawner shares
``claude-pick --gate`` beneath it (``rabota budget``). A second door that skips the gate is how
a window gets spent unmetered.

This module supplies both the local form (``unit_name``, ``build_local``) and the remote/dev form
(``build_remote``, ``send_brief``, ``create_worktree_remote``, ``resolve_claude_bin``) plus the
entry point that ties them together, ``run_recipe``, and its ``rabota lane recipe`` registration.
"""
import re
import uuid
from pathlib import Path

from rabota import budget as budget_mod
from rabota import cli, errors, remote, store
from rabota.commands import budget as budget_cmd
from rabota.context import Context

SAFE = re.compile(r"[^A-Za-z0-9._-]+")


def unit_name(tenant: str, slug: str) -> str:
    """``rabota-lane-<tenant>-<slug>-<uuid8>.service``, with the slug reduced to safe characters."""
    s = SAFE.sub("-", slug).strip("-").lower() or "lane"
    return f"rabota-lane-{tenant}-{s}-{uuid.uuid4().hex[:8]}.service"


def seat_config_dir(seat: str) -> str:
    """The account dir a lane bills. One per seat, as claude() builds them."""
    return str(Path.home() / f".claude-{seat}")


def build_local(ctx, *, seat, repo, worktree, out_dir, brief, model, effort, unit,
                session_id: str | None = None, claude_bin: str | None = None) -> list[str]:
    """The systemd-run argv for a lane on this machine. Every value is an argv element, never a string.

    ``claude_bin`` overrides ``ctx.tenant.lanes.claude_bin``; either way the value is expanded with
    ``Path.expanduser()`` HERE, at call time, never earlier — the config default is home-relative,
    and only the machine this argv will actually run on may resolve what ``~`` means. A remote lane
    passes an already-resolved absolute path (``resolve_claude_bin``), for which expansion is a
    no-op.
    """
    bin_path = str(Path(claude_bin if claude_bin is not None else ctx.tenant.lanes.claude_bin).expanduser())
    return [
        "systemd-run", "--user", "--collect", f"--unit={unit}",
        f"--working-directory={worktree}",
        f"--setenv=CLAUDE_CONFIG_DIR={seat_config_dir(seat)}",
        "-p", f"StandardOutput=append:{out_dir}/stream.jsonl",
        "-p", f"StandardError=append:{out_dir}/stream.err",
        "-p", f"MemoryMax={ctx.tenant.lanes.memory_max}",
        bin_path,
        "-p", f"Read {brief} and execute.",
        "--output-format", "stream-json", "--verbose",
        "--session-id", session_id or str(uuid.uuid4()),
        "--model", model, "--effort", effort,
        "--permission-mode", ctx.tenant.lanes.permission_mode,
        "--add-dir", out_dir,
    ]


def build_remote(ctx, machine, local_argv: list[str]) -> list[str]:
    """Wrap a local lane argv in one ssh call.

    Every element is POSIX single-quoted, not ``printf %q``: dev's login shell is zsh, where an
    unquoted leading ``=`` undergoes equals expansion (measured 2026-09-20: ``=ls`` became
    ``/usr/bin/ls``). Single quotes are literal in sh, bash and zsh alike.

    ``--slice=agents.slice`` is what puts the lane inside the host's memory budget; without it
    the lane runs in the ssh session scope, outside every cap.
    """
    argv = list(local_argv)
    argv.insert(1, "--slice=agents.slice")
    cmd = " ".join(remote.shquote(a) for a in argv)
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", machine.ssh, cmd]


def send_brief(ctx, machine, remote_path: str, text: str) -> None:
    """Write ``text`` to ``remote_path`` on ``machine``, with the content on ssh's STDIN.

    Nothing but a path rabota generated crosses the remote command line. A failure raises rather
    than returning, because a lane whose brief never arrived starts and then reads nothing.
    """
    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", machine.ssh,
            f"cat > {remote.shquote(remote_path)}"]
    res = ctx.runner.run(argv, input=text)
    if not res.ok:
        raise errors.RabotaError(f"could not write the brief to {machine.name}: {(res.err or res.out).strip()}")


def create_worktree_remote(ctx, machine, repo_path: str, worktree: str, base: str | None) -> None:
    """``git worktree add`` on ``machine``. Every value is single-quoted for the remote shell."""
    parts = ["git", "-C", repo_path, "worktree", "add", worktree]
    if base:
        parts.append(base)
    cmd = " ".join(remote.shquote(p) for p in parts)
    res = ctx.runner.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--",
                          machine.ssh, cmd])
    if not res.ok:
        raise errors.RabotaError(f"could not create the worktree on {machine.name}: "
                                 f"{(res.err or res.out).strip()}")


def resolve_claude_bin(ctx, machine) -> str:
    """The absolute claude path ON ``machine``, proven to exist. Never a guess.

    The configured value is home-relative and this process's home is not the remote's, so the
    remote shell expands it and hands the answer back. A path that cannot be resolved is an
    unmeasured dimension like any other: it refuses, rather than dispatching a lane that will
    fail at exec time inside a unit whose error nobody reads.
    """
    script = 'p="$HOME"/.local/bin/claude; [ -x "$p" ] && printf %s "$p"'
    res = ctx.runner.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--",
                          machine.ssh, script])
    path = (res.out or "").strip()
    if not res.ok or not path.startswith("/"):
        raise errors.Refused(
            f"could not resolve an executable claude on {machine.name}: "
            f"{(res.err or res.out or 'no path returned').strip()}")
    return path


def run_recipe(ctx, *, brief, repo, machine, base, seat, model, effort, est_minutes, run,
               budget_fn=None) -> dict:
    """Render one lane; with ``run``, create the worktree, send the brief and start the unit.

    Order matters and is asserted: budget BEFORE anything is created (a refusal writes no row and
    touches no machine), then worktree, then brief, then unit, then the row. The row is written
    only after the unit actually started — a ``started`` row for a unit that never started is a
    lie ``census`` would later try to settle.

    For a non-local machine, ``resolve_claude_bin`` runs before the argv is even rendered (so the
    DRY form prints an absolute, resolved path too) — a config default is home-relative and this
    process's home is never the remote's.

    ``budget_fn`` exists so the tests can drive the gate without a clauth on the test machine; in
    production it is ``rabota budget``'s own ``run_budget``.
    """
    if not machine:
        raise errors.Usage("--machine must not be empty")
    m = ctx.tenant.machines.get(machine) if machine != "local" else None
    if machine != "local" and m is None:
        raise errors.Refused(f"tenant {ctx.tenant.name!r} declares no machine {machine!r}")

    seat_pick = budget_mod.seat_for(ctx.tenant, machine, override=seat)
    fn = budget_fn or (lambda **kw: budget_cmd.run_budget(ctx, **kw))
    b = fn(machine=machine, model=model, effort=effort, est_minutes=est_minutes, seat=seat_pick)
    if b["allowed_new_lanes"] <= 0:
        e = errors.Refused("; ".join(f"{r['code']}: {r['detail']}" for r in b["reasons"])
                           or "no lane capacity")
        e.budget = b
        raise e

    slug = Path(brief).stem
    unit = unit_name(ctx.tenant.name, slug)
    lane_id = unit.rsplit("-", 1)[-1].removesuffix(".service")
    session_id = str(uuid.uuid4())
    claude_bin = None
    if machine == "local":
        root = Path(ctx.tenant.state_dir).expanduser()
        repo_path = str(Path(ctx.tenant.root).expanduser() / repo)
    else:
        if repo not in m.repos:
            raise errors.Refused(f"machine {machine!r} declares no repo {repo!r} "
                                 f"([machines.{machine}].repos)")
        root = Path(m.state_dir)
        repo_path = m.repos[repo]
        claude_bin = resolve_claude_bin(ctx, m)
    worktree = str(root / "worktrees" / ctx.tenant.name / lane_id)
    out_dir = str(root / "out" / ctx.tenant.name / lane_id)
    remote_brief = f"{out_dir}/brief.md"

    argv = build_local(ctx, seat=seat_pick, repo=repo, worktree=worktree, out_dir=out_dir,
                       brief=remote_brief, model=model, effort=effort, unit=unit,
                       session_id=session_id, claude_bin=claude_bin)
    if machine != "local":
        argv = build_remote(ctx, m, argv)
    out = {"argv": argv, "shell": " ".join(argv), "unit": unit, "session_id": session_id,
           "seat": seat_pick, "machine": machine, "est_minutes": est_minutes,
           "worktree": worktree, "out_dir": out_dir}
    if not run:
        return out

    if machine == "local":
        raise errors.Refused("the local --run form is not implemented; use --machine dev")
    create_worktree_remote(ctx, m, repo_path, worktree, base)
    send_brief(ctx, m, remote_brief, Path(brief).read_text())
    res = ctx.runner.run(argv)
    if not res.ok:
        raise errors.RabotaError(f"could not start {unit} on {machine}: {(res.err or res.out).strip()}")
    ctx.store.insert_lane({"id": lane_id, "tenant": ctx.tenant.name, "kind": "work", "brief": brief,
                        "repo": repo, "worktree": worktree, "out_dir": out_dir, "machine": machine,
                        "unit": unit, "session_id": session_id, "status": "started", "seat": seat_pick,
                        "model": model, "effort": effort, "started_at": store.now(),
                        "five_h_pct_at_start": b.get("five_h_pct_now")})
    return out


def _build(sub):
    p = sub.add_parser("lane", help="render or run exactly one lane unit")
    s = p.add_subparsers(dest="lane_cmd", required=True)
    r = s.add_parser("recipe", help="print the lane argv; --run starts it")
    r.add_argument("--brief", required=True)
    r.add_argument("--repo", required=True)
    r.add_argument("--machine", default="local", choices=["local", "dev"])
    r.add_argument("--base", default=None)
    r.add_argument("--seat", default=None)
    r.add_argument("--model", default=None)
    r.add_argument("--effort", default=None)
    r.add_argument("--est-minutes", type=int, default=30)
    r.add_argument("--run", action="store_true")


def _run(ns, **ctx_kw):
    ctx = Context.from_namespace(ns, **ctx_kw)
    out = run_recipe(ctx, brief=ns.brief, repo=ns.repo, machine=ns.machine, base=ns.base,
                     seat=ns.seat, model=ns.model or ctx.tenant.lanes.default_model,
                     effort=ns.effort or ctx.tenant.lanes.default_effort,
                     est_minutes=ns.est_minutes, run=ns.run)
    return [out["unit"], out["shell"]] if ns.text else out


cli.register("lane", _build, _run)
