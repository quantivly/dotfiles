"""``rabota lane recipe``: render (and optionally run) exactly one lane unit.

The whole lifecycle this command owns is "start it and record one row". No polling, no retire,
no attach: ``census`` observes the unit and settles the row, ``reap`` abandons a stale one.

It is the ONE door a headless lane comes through, which is why every spawner shares
``claude-pick --gate`` beneath it (``rabota budget``). A second door that skips the gate is how
a window gets spent unmetered.

This module supplies both the local form (``unit_name``, ``build_local``) and the remote/dev form
(``build_remote``, ``send_brief``, ``create_worktree_remote``, ``resolve_remote``,
``expand_remote``) plus the entry point that ties them together, ``run_recipe``, and its
``rabota lane recipe`` registration.
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


def seat_config_dir(seat: str, home: str | None = None) -> str:
    """The account dir a lane bills, on the machine whose ``$HOME`` this is. One per seat, as
    ``claude()`` builds them.

    ``home`` defaults to THIS process's home, which is correct only for a lane that will run on
    this machine. A remote lane must pass the REMOTE ``$HOME`` (``resolve_remote``'s ``home``) —
    this is the exact defect class corrections 6/10 fixed for ``claude_bin``/``state_dir``/
    ``repos``, on the value that decides which account a lane bills.
    """
    return f"{home or Path.home()}/.claude-{seat}"


def build_local(ctx, *, seat, repo, worktree, out_dir, brief, model, effort, unit,
                session_id: str | None = None, claude_bin: str | None = None,
                home: str | None = None) -> list[str]:
    """The systemd-run argv for a lane on this machine. Every value is an argv element, never a string.

    ``claude_bin`` overrides ``ctx.tenant.lanes.claude_bin``; either way the value is expanded with
    ``Path.expanduser()`` HERE, at call time, never earlier — the config default is home-relative,
    and only the machine this argv will actually run on may resolve what ``~`` means. A remote lane
    passes an already-resolved absolute path (``resolve_remote``), for which expansion is a
    no-op. ``home`` is threaded to ``seat_config_dir`` the same way, for the same reason.
    """
    bin_path = str(Path(claude_bin if claude_bin is not None else ctx.tenant.lanes.claude_bin).expanduser())
    return [
        "systemd-run", "--user", "--collect", f"--unit={unit}",
        f"--working-directory={worktree}",
        f"--setenv=CLAUDE_CONFIG_DIR={seat_config_dir(seat, home)}",
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
    return remote.ssh_argv(machine, cmd)


def send_brief(ctx, machine, remote_path: str, text: str) -> None:
    """Write ``text`` to ``remote_path`` on ``machine``, with the content on ssh's STDIN.

    Nothing but a path rabota generated crosses the remote command line. A failure raises rather
    than returning, because a lane whose brief never arrived starts and then reads nothing.
    """
    argv = remote.ssh_argv(machine, f"cat > {remote.shquote(remote_path)}")
    res = ctx.runner.run(argv, input=text)
    if not res.ok:
        raise errors.RabotaError(f"could not write the brief to {machine.name}: {(res.err or res.out).strip()}")


REMOTE_WORKTREE_TIMEOUT = 300  # seconds; git worktree add on a large repo can run well past 60s


def create_worktree_remote(ctx, machine, repo_path: str, worktree: str, out_dir: str,
                           base: str | None, *, timeout: float = REMOTE_WORKTREE_TIMEOUT) -> None:
    """``mkdir -p`` the lane's ``out_dir`` and ``git worktree add`` the worktree, in ONE ssh call.

    ``out_dir`` must exist before the brief is sent (a shell ``>`` redirection does not create
    parent directories) and before the unit starts (its ``StandardOutput``/``StandardError``
    targets live under it) — ``systemd-run`` returns 0 once the transient unit is CREATED, so a
    unit that then fails to open its own log files would otherwise be recorded as ``started``
    anyway. ``timeout`` defaults well above the runner's own 60s default: a timeout maps to the
    same ``Result`` shape as a real failure, and git on a large repo can legitimately run long.
    """
    mkdir = ["mkdir", "-p", out_dir]
    worktree_add = ["git", "-C", repo_path, "worktree", "add", worktree]
    if base:
        worktree_add.append(base)
    cmd = " && ".join(" ".join(remote.shquote(p) for p in parts) for parts in (mkdir, worktree_add))
    res = ctx.runner.run(remote.ssh_argv(machine, cmd), timeout=timeout)
    if not res.ok:
        raise errors.RabotaError(f"could not create the worktree on {machine.name}: "
                                 f"{(res.err or res.out).strip()}")


def _remove_worktree_remote(ctx, machine, repo_path: str, worktree: str) -> None:
    """Best-effort ``git worktree remove --force`` after a failed brief send or unit start.

    Never raises: the caller's ``except`` re-raises the ORIGINAL error, and a cleanup failure here
    must not replace it. Without this, a worktree created just before a brief-send or unit-start
    failure is invisible to every rabota command (``census`` and ``reap`` both work from lane
    rows, and this worktree never gets one) and accumulates in the remote repo's
    ``git worktree list`` forever.
    """
    cmd = " ".join(remote.shquote(p) for p in ["git", "-C", repo_path, "worktree", "remove",
                                                "--force", worktree])
    try:
        ctx.runner.run(remote.ssh_argv(machine, cmd))
    except Exception:  # noqa: BLE001 — deliberately swallowed; see docstring
        pass


def resolve_remote(ctx, machine, seat: str) -> dict:
    """``$HOME``, the absolute claude path, and ``seat``'s account dir ON ``machine`` — each
    proven, in one ssh call. Never a guess.

    Every path rabota stores for a machine is home-relative (``~/.local/state/rabota``,
    ``~/quantivly/hub``) and this process's home is not the remote's. ``shquote`` single-quotes
    every element and POSIX single quotes suppress tilde expansion, so a ``~`` sent as-is becomes
    a literal directory named ``~`` on the target. The remote expands its own home once and every
    other path is built from that answer (see ``expand_remote``, ``seat_config_dir``).

    The seat's account dir is resolved AND its existence is checked here too — not just
    constructed as a string — because ``CLAUDE_CONFIG_DIR`` decides which account a lane bills,
    and a lane started against a directory nobody provisioned either fails at exec time inside a
    unit whose error nobody reads, or silently falls back to whatever ``claude`` finds on its own.
    A machine that cannot answer any of the three refuses, like any other unmeasured dimension —
    dispatching a lane to a guessed path is worse than refusing outright.
    """
    config_dir_suffix = remote.shquote(f"/.claude-{seat}")
    script = ('printf "%s\\n" "$HOME"; '
              'p="$HOME"/.local/bin/claude; [ -x "$p" ] && printf "%s\\n" "$p" || printf "\\n"; '
              f'd="$HOME"{config_dir_suffix}; [ -d "$d" ] && printf %s "$d"')
    res = ctx.runner.run(remote.ssh_argv(machine, script))
    lines = (res.out or "").splitlines()
    home = lines[0].strip() if len(lines) > 0 else ""
    claude_bin = lines[1].strip() if len(lines) > 1 else ""
    config_dir = lines[2].strip() if len(lines) > 2 else ""
    if not res.ok or not home.startswith("/") or not claude_bin.startswith("/") or not config_dir.startswith("/"):
        missing = []
        if not home.startswith("/"):
            missing.append("$HOME")
        if not claude_bin.startswith("/"):
            missing.append("an executable claude")
        if not config_dir.startswith("/"):
            expected = f"{home}/.claude-{seat}" if home.startswith("/") else f"$HOME/.claude-{seat}"
            missing.append(f"the account dir {expected!r}")
        raise errors.Refused(
            f"could not resolve {', '.join(missing)} on {machine.name}: "
            f"{(res.err or res.out or 'no paths returned').strip()}")
    return {"home": home, "claude_bin": claude_bin, "config_dir": config_dir}


def expand_remote(path: str, home: str) -> str:
    """Expand a leading ``~`` against the REMOTE ``home``; never this process's.

    Only bare ``~`` and ``~/…`` are understood. A ``~user`` form refuses rather than passing
    through as a literal, because passing it through is how a path silently becomes a directory
    named ``~user`` on the target.
    """
    if path == "~":
        return home
    if path.startswith("~/"):
        return home + path[1:]
    if path.startswith("~"):
        raise errors.Refused(f"cannot expand {path!r} for a remote machine: only ~ and ~/ are supported")
    return path


def run_recipe(ctx, *, brief, repo, machine, base, seat, model, effort, est_minutes, run,
               budget_fn=None) -> dict:
    """Render one lane; with ``run``, create the worktree, send the brief and start the unit.

    Order matters and is asserted: budget BEFORE anything is created (a refusal writes no row and
    touches no machine), then worktree, then brief, then unit, then the row. The row is written
    only after the unit actually started — a ``started`` row for a unit that never started is a
    lie ``census`` would later try to settle.

    For a non-local machine, ``resolve_remote`` runs before the argv is even rendered (so the DRY
    form prints an absolute, resolved path too) — every configured path is home-relative and this
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
    home = None
    if machine == "local":
        root = Path(ctx.tenant.state_dir).expanduser()
        repo_path = str(Path(ctx.tenant.root).expanduser() / repo)
    else:
        if repo not in m.repos:
            raise errors.Refused(f"machine {machine!r} declares no repo {repo!r} "
                                 f"([machines.{machine}].repos)")
        info = resolve_remote(ctx, m, seat_pick)
        home = info["home"]
        root = Path(expand_remote(m.state_dir, home))
        repo_path = expand_remote(m.repos[repo], home)
        claude_bin = info["claude_bin"]
    worktree = str(root / "worktrees" / ctx.tenant.name / lane_id)
    out_dir = str(root / "out" / ctx.tenant.name / lane_id)
    remote_brief = f"{out_dir}/brief.md"

    argv = build_local(ctx, seat=seat_pick, repo=repo, worktree=worktree, out_dir=out_dir,
                       brief=remote_brief, model=model, effort=effort, unit=unit,
                       session_id=session_id, claude_bin=claude_bin, home=home)
    if machine != "local":
        argv = build_remote(ctx, m, argv)
    out = {"argv": argv, "shell": " ".join(argv), "unit": unit, "session_id": session_id,
           "seat": seat_pick, "machine": machine, "est_minutes": est_minutes,
           "worktree": worktree, "out_dir": out_dir}
    if not run:
        return out

    if machine == "local":
        raise errors.Refused("the local --run form is not implemented; use --machine dev")
    create_worktree_remote(ctx, m, repo_path, worktree, out_dir, base)
    try:
        send_brief(ctx, m, remote_brief, Path(brief).read_text())
        res = ctx.runner.run(argv)
        if not res.ok:
            raise errors.RabotaError(f"could not start {unit} on {machine}: {(res.err or res.out).strip()}")
    except Exception:
        # A worktree created just above and then orphaned by a brief-send or unit-start failure
        # is invisible to every rabota command from here on (census/reap both work from lane
        # rows, and none exists for it) — best-effort cleanup, then re-raise the ORIGINAL error.
        _remove_worktree_remote(ctx, m, repo_path, worktree)
        raise
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
