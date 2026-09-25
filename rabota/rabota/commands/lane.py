"""``rabota lane recipe``: render (and optionally run) exactly one lane unit.

The whole lifecycle this command owns is "start it and record one row". No polling, no retire,
no attach: ``census`` observes the unit and settles the row, ``reap`` abandons a stale one.

It is the ONE door a headless lane comes through, which is why every spawner shares
``claude-pick --gate`` beneath it (``rabota budget``). A second door that skips the gate is how
a window gets spent unmetered.

This module supplies both the local form (``unit_name``, ``build_local``) and the remote/dev form
(``build_remote``, ``send_brief``, ``create_worktree_remote``, ``resolve_default_branch_remote``,
``resolve_remote``, ``expand_remote``) plus the entry point that ties them together,
``run_recipe``, and its ``rabota lane recipe`` registration.
"""
import re
import uuid
from pathlib import Path

from rabota import budget as budget_mod
from rabota import cli, errors, remote, store
from rabota.commands import budget as budget_cmd
from rabota.context import Context
from rabota.lanes import brief as lanes_brief
from rabota.lanes import verdict as lanes_verdict

SAFE = re.compile(r"[^A-Za-z0-9._-]+")

# The cgroup slice every remote lane joins explicitly (``--slice=``), and therefore the slice
# whose memory cap bounds it. Shared rather than written twice: ``rabota doctor`` asserts the
# admission cap fits inside THIS slice's MemoryMax on the machine, and a doctor that measured a
# different slice than the lane joins would report a budget nothing is subject to.
LANE_SLICE = "agents.slice"


def unit_name(tenant: str, slug: str) -> str:
    """``rabota-lane-<tenant>-<slug>-<uuid8>.service``, with the slug reduced to safe characters."""
    s = SAFE.sub("-", slug).strip("-").lower() or "lane"
    return f"rabota-lane-{tenant}-{s}-{uuid.uuid4().hex[:8]}.service"


def seat_config_dir(seat: str) -> str:
    """The account dir a LOCAL lane bills. One per seat, so several accounts can run side by side
    on this laptop.

    Built by ``scripts/claude-account-dirs.sh`` (a dotfiles reconciler, not ``claude()`` itself —
    an earlier docstring here claimed otherwise and was wrong), which mirrors its own ``ROOT``:
    ``${CLAUDE_ACCOUNT_DIRS_ROOT:-$HOME/.local/state/claude-account-dirs}/<profile>`` (that
    script's line ~101). This function renders a recipe for a lane the reconciler will already
    have prepared at the DEFAULT root — it does not read ``CLAUDE_ACCOUNT_DIRS_ROOT`` itself, and
    a non-default root is unsupported here; that limitation is deliberate, so it stays visible
    rather than being silently wrong the way the previous path was (measured 2026-09-20:
    ``~/.claude-quantivly-1`` does not exist; ``~/.local/state/claude-account-dirs/quantivly-1``
    does).

    This is deliberately NOT used for a remote lane (see ``resolve_remote``'s docstring) — a
    remote machine like dev is single-account, and using this function's per-seat scheme there
    would build a path that machine never has and never will.
    """
    return f"{Path.home()}/.local/state/claude-account-dirs/{seat}"


def build_local(ctx, *, worktree, out_dir, brief, model, effort, unit,
                session_id: str | None = None, claude_bin: str | None = None,
                config_dir: str | None = None, path: str | None = None) -> list[str]:
    """The systemd-run argv for a lane on this machine. Every value is an argv element, never a string.

    ``claude_bin`` overrides ``ctx.tenant.lanes.claude_bin``; either way the value is expanded with
    ``Path.expanduser()`` HERE, at call time, never earlier — the config default is home-relative,
    and only the machine this argv will actually run on may resolve what ``~`` means. A remote lane
    passes an already-resolved absolute path (``resolve_remote``), for which expansion is a no-op.

    ``config_dir``, when given, emits ``--setenv=CLAUDE_CONFIG_DIR=<config_dir>``. When it is
    ``None`` (the default) the flag is OMITTED entirely — never emitted empty, never guessed.

    ``path`` behaves the same way and emits ``--setenv=PATH=<path>`` (DO-712). A transient unit
    inherits the USER MANAGER's environment, not a login shell's, so nothing in the target's
    ``.profile`` or ``.zshrc`` can reach a lane — and ``~/.local/bin`` only joined systemd's own
    default user PATH in v250, while dev runs 249. Measured on dev 2026-09-24: the manager's PATH
    is ``/usr/local/sbin:…:/snap/bin`` with no ``~/.local/bin``, so a lane could not invoke
    ``rabota`` (127) even though ``~/.local/bin/rabota`` is there. systemd has no "prepend", so
    the caller passes the whole value; ``run_recipe`` builds it from the PATH the machine itself
    reported (``resolve_remote``) rather than a hardcoded list, so ``/snap/bin`` and anything else
    that machine has survives.

    This is deliberately asymmetric between the two callers (fix round 5, the first live smoke
    this plan ever ran, 2026-09-20): ``run_recipe``'s LOCAL branch passes ``seat_config_dir(seat)``
    explicitly, because this laptop genuinely has a per-seat account-dir scheme. Its REMOTE branch
    passes nothing. Measured on dev: with ``CLAUDE_CONFIG_DIR`` set to a DIRECTORY, Claude Code
    looks for ``<dir>/.claude.json``; dev keeps that file at ``$HOME/.claude.json`` — HOME level,
    not inside ``.claude`` — so an earlier round's ``CLAUDE_CONFIG_DIR=$HOME/.claude`` made the
    lane authenticate (the credential resolved) but run WITHOUT the account's ``.claude.json``
    state, and Claude Code printed "Claude configuration file not found at:
    /home/ubuntu/.claude/.claude.json" on stderr, twice. Reading A — "a remote lane uses the
    machine's own login" — means the machine's own DEFAULTS too, and the faithful way to use dev's
    defaults is to not override the variable that points away from them at all.
    """
    bin_path = str(Path(claude_bin if claude_bin is not None else ctx.tenant.lanes.claude_bin).expanduser())
    argv = [
        "systemd-run", "--user", "--collect", f"--unit={unit}",
        f"--working-directory={worktree}",
    ]
    if config_dir is not None:
        argv.append(f"--setenv=CLAUDE_CONFIG_DIR={config_dir}")
    if path is not None:
        argv.append(f"--setenv=PATH={path}")
    argv += [
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
    return argv


def build_remote(machine, local_argv: list[str]) -> list[str]:
    """Wrap a local lane argv in one ssh call.

    Every element is POSIX single-quoted, not ``printf %q``: dev's login shell is zsh, where an
    unquoted leading ``=`` undergoes equals expansion (measured 2026-09-20: ``=ls`` became
    ``/usr/bin/ls``). Single quotes are literal in sh, bash and zsh alike.

    ``--slice=agents.slice`` is what puts the lane inside the host's memory budget; without it
    the lane runs in the ssh session scope, outside every cap.
    """
    argv = list(local_argv)
    argv.insert(1, f"--slice={LANE_SLICE}")
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


REMOTE_VERDICT_TIMEOUT = 60  # seconds; one `head -c` of at most a few KB over ssh
REMOTE_WORKTREE_TIMEOUT = 300  # seconds; git fetch + worktree add on a large repo can run well past 60s

REMOTE = "origin"  # every repo under [machines.dev].repos uses this remote name today; hardcoded
# rather than read from config because nothing in the schema declares a per-repo remote name, and
# adding one would be a config-shape change this defect does not call for.


def resolve_default_branch_remote(ctx, machine, repo_path: str) -> str:
    """The repo's default branch on ``machine``, read from ``origin/HEAD`` — never a guess.

    Called only when the caller passed no ``--base``. ``origin/HEAD`` is a symbolic ref set by
    ``git clone`` or ``git remote set-head``, not by ``fetch`` — a clone made without either (or
    one where it was pruned) has none, and falling back to the remote's local ``HEAD`` in that
    case is exactly the bug this function exists to refuse instead of committing: local ``HEAD``
    on a bare or freshly-cloned mirror is whatever branch happened to be checked out last, not
    necessarily the project's default.
    """
    script = f"git -C {remote.shquote(repo_path)} symbolic-ref -q --short refs/remotes/{REMOTE}/HEAD"
    res = ctx.runner.run(remote.ssh_argv(machine, script))
    branch = (res.out or "").strip()
    if not res.ok or not branch:
        raise errors.Refused(
            f"{repo_path} on {machine.name} has no {REMOTE}/HEAD set: pass --base explicitly")
    return branch


def create_worktree_remote(ctx, machine, repo_path: str, worktree: str, out_dir: str,
                           base: str | None, *, timeout: float = REMOTE_WORKTREE_TIMEOUT) -> None:
    """``mkdir -p`` the lane's ``out_dir``, fetch, and ``git worktree add`` the worktree — fetch
    and the add in ONE ssh call, ahead of the add, so refreshing the clone costs no extra round
    trip beyond the call this docstring already batches.

    A fetch failure REFUSES the lane rather than falling through to ``worktree add`` against
    whatever the clone last had — the same "an unmeasured dimension refuses, never as room" rule
    ``budget.py`` holds for its own gate: a stale clone that failed to refresh is not evidence the
    tree is current, so it must not be treated as room to proceed.

    When the caller passed no ``--base``, one resolves first (see
    ``resolve_default_branch_remote``) — a real extra round trip, since which branch is default is
    remote-only information this process cannot know in advance; it is not folded into this call
    because a refusal here must name the repo on its own, not share an exit code with an unrelated
    fetch failure.

    ``out_dir`` must exist before the brief is sent (a shell ``>`` redirection does not create
    parent directories) and before the unit starts (its ``StandardOutput``/``StandardError``
    targets live under it) — ``systemd-run`` returns 0 once the transient unit is CREATED, so a
    unit that then fails to open its own log files would otherwise be recorded as ``started``
    anyway. ``timeout`` defaults well above the runner's own 60s default: a timeout maps to the
    same ``Result`` shape as a real failure, and git on a large repo can legitimately run long.
    """
    if not base:
        base = resolve_default_branch_remote(ctx, machine, repo_path)
    mkdir = ["mkdir", "-p", out_dir]
    fetch = ["git", "-C", repo_path, "fetch", REMOTE]
    worktree_add = ["git", "-C", repo_path, "worktree", "add", worktree, base]
    cmd = " && ".join(" ".join(remote.shquote(p) for p in parts)
                      for parts in (mkdir, fetch, worktree_add))
    res = ctx.runner.run(remote.ssh_argv(machine, cmd), timeout=timeout)
    if not res.ok:
        raise errors.Refused(f"could not fetch or create the worktree on {machine.name}: "
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


def read_remote_verdict(ctx, machine, path: str, max_bytes: int) -> dict:
    """Fetch and validate a verdict that lives on ``machine``, in one ssh call.

    ``head -c max_bytes+1`` bounds the transfer at the source: an oversized verdict is refused on
    the byte after the limit rather than streamed across and measured here. A non-zero exit covers
    absent, unreadable and unreachable alike — all of which are "no verdict we can trust", which is
    a refusal, never room (the rule ``budget`` holds for an unmeasured dimension).
    """
    cmd = " ".join(remote.shquote(p) for p in ["head", "-c", str(max_bytes + 1), "--", path])
    res = ctx.runner.run(remote.ssh_argv(machine, cmd), timeout=REMOTE_VERDICT_TIMEOUT)
    if not res.ok:
        raise lanes_verdict.VerdictError(
            f"no readable verdict at {path} on {machine.name}: {(res.err or res.out).strip()[:160]}")
    return lanes_verdict.validate_text(res.out, max_bytes, where=f"{path} on {machine.name}")


def resolve_remote(ctx, machine) -> dict:
    """``$HOME``, ``$PATH`` and the absolute claude path ON ``machine`` — all proven, in one ssh
    call. Never a guess.

    Every path rabota stores for a machine is home-relative (``~/.local/state/rabota``,
    ``~/quantivly/hub``) and this process's home is not the remote's. ``shquote`` single-quotes
    every element and POSIX single quotes suppress tilde expansion, so a ``~`` sent as-is becomes
    a literal directory named ``~`` on the target. The remote expands its own home once and every
    other path is built from that answer (see ``expand_remote``).

    Decision (2026-09-20, Zvi): a remote lane authenticates with the TARGET MACHINE'S OWN login
    (spec §4.2: "the laptop's monitoring grant reports what dev's own login would… dev never
    needs clauth"), never a per-seat account dir — the machine registry only DECLARES the
    seat a machine's usage bills, for the laptop's own budget gate. This means the seat is
    TRUSTED rather than ENFORCED on a remote machine — ``rabota doctor`` is where that gets
    asserted (a later task).

    This function used to also resolve and prove the machine's account dir
    (``$HOME/.claude``, checked with ``[ -d ... ]``) so it could be passed to
    ``CLAUDE_CONFIG_DIR``. Fix round 5 removed that: the live smoke on dev showed that setting
    ``CLAUDE_CONFIG_DIR`` to a DIRECTORY makes Claude Code look for ``<dir>/.claude.json``, while
    dev keeps that file at ``$HOME/.claude.json`` (HOME level, not inside ``.claude``) — so the
    lane authenticated but ran without its ``.claude.json`` state ("Claude configuration file not
    found", printed twice). The fix is to not set the variable for a remote lane at all (see
    ``build_local``'s docstring) — nothing consumes an account dir here anymore, so nothing here
    proves one. Proving a directory nobody references is exactly the dead check this repo's own
    guard (a mutation surviving with no row to kill it) would flag as due for retirement.

    ``path`` joined this call in DO-712, so a lane's ``PATH`` is the target machine's own rather
    than a list written down here. It is the NON-INTERACTIVE ssh session's ``$PATH``, which is not
    quite the user manager's — measured on dev 2026-09-24 the two differ only by a duplicated
    ``/snap/bin`` — so a manager-only entry would be dropped by the ``--setenv=PATH`` that
    ``run_recipe`` builds from it. That is accepted rather than read from
    ``systemctl --user show-environment``, whose failure mode on a non-interactive ssh is the one
    ``remote.build_argv`` already documents (no ``XDG_RUNTIME_DIR``, user manager stopped,
    lingering off) and would arrive here as an empty string — a lane with no PATH at all, which is
    worse than the entry it was meant to preserve.

    THE REPLY FRAMES ITSELF, and the parse then demands EXACTLY three lines. An adversarial review
    lane (2026-09-24) showed why a bare positional parse is not enough: any stdout line of its own
    that happens to start with ``/`` -- a banner, an MOTD, a shell rc that echoes -- shifts all
    three values by one and every check still passes, so the lane starts with ``$HOME`` set to a
    banner and the claude binary set to the PATH string. A ``$PATH`` containing a newline does the
    same, and a fourth value added here later would silently take ``claude_bin``'s slot. All three
    are silent wrong answers, which is the failure mode this whole module is shaped to refuse.

    The marker is the technique ``remote.build_argv`` already uses for census, for the same reason.
    Everything before it is discarded; everything after it must be exactly the three lines this
    asked for, so a fourth of ANY origin refuses instead of shifting a value. An absent claude
    prints an EMPTY line rather than nothing -- the old "a short list means no claude" trick was a
    comment rather than a constraint, with no row pinning the position it depended on.
    """
    marker = "---RABOTA-RESOLVE---"
    script = (f'printf "%s\\n" {remote.shquote(marker)}; '
              'printf "%s\\n" "$HOME"; printf "%s\\n" "$PATH"; '
              'p="$HOME"/.local/bin/claude; if [ -x "$p" ]; then printf "%s\\n" "$p"; '
              'else printf "\\n"; fi')
    res = ctx.runner.run(remote.ssh_argv(machine, script))
    out = res.out or ""
    # Split on the marker's own LINE, so the newline that terminates it is not counted as a
    # fourth (empty) value by splitlines().
    head = marker + "\n"
    framed = out.split(head, 1)[1] if head in out else ""
    lines = framed.splitlines()
    if len(lines) == 3:
        home, path, claude_bin = (l.strip() for l in lines)
    else:
        home = path = claude_bin = ""
    if not res.ok or not home.startswith("/") or "/" not in path or not claude_bin.startswith("/"):
        missing = []
        if not home.startswith("/"):
            missing.append("$HOME")
        if "/" not in path:
            missing.append("$PATH")
        if not claude_bin.startswith("/"):
            missing.append("an executable claude")
        # `', '.join(missing)` is EMPTY when the ssh itself failed but the payload happened to
        # parse -- the message then named nothing at all ("could not resolve  on dev: ...").
        raise errors.Refused(
            f"could not resolve {', '.join(missing) or 'the machine (ssh failed)'} on "
            f"{machine.name}: {(res.err or res.out or 'no paths returned').strip()}")
    return {"home": home, "path": path, "claude_bin": claude_bin}


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
               kind="work", of=None, budget_fn=None) -> dict:
    """Render one lane; with ``run``, create the worktree, send the brief and start the unit.

    Order matters and is asserted: budget BEFORE anything is created (a refusal writes no row and
    touches no machine), then worktree, then brief, then unit, then the row. The row is written
    only after the unit actually started — a ``started`` row for a unit that never started is a
    lie ``census`` would later try to settle.

    For a non-local machine, ``resolve_remote`` runs before the argv is even rendered (so the DRY
    form prints an absolute, resolved path too) — every configured path is home-relative and this
    process's home is never the remote's.

    A remote machine authenticates with its OWN login; the machine registry only declares
    which seat that bills, for the laptop's budget gate. So a ``--seat`` override that disagrees
    with the declared profile is refused here, before any ssh call — passing it through would
    meter and record a seat that is not the one actually billing the work.

    ``kind="evaluate"`` builds an evaluate lane for the lane named by ``of`` instead of a work
    lane: ``brief`` is ignored (the evaluate template supplies it — DO-670), ``machine`` is
    forced to match ``of``'s own lane (remote-lanes design §4.5: the evaluated lane's
    ``verdict.json`` never crosses machines), and the row records ``kind`` and ``of_lane``. An
    evaluate lane of an evaluate lane is refused (see below) rather than silently chained.

    ``budget_fn`` exists so the tests can drive the gate without a clauth on the test machine; in
    production it is ``rabota budget``'s own ``run_budget``.
    """
    if kind not in ("work", "evaluate"):
        raise errors.Usage(f"--kind must be work or evaluate, got {kind!r}")
    if kind == "evaluate" and not of:
        raise errors.Usage("--kind evaluate requires --of <lane_id>")
    if kind != "evaluate" and of:
        raise errors.Usage("--of requires --kind evaluate")
    if kind == "evaluate" and brief:
        raise errors.Usage(
            "--brief and --kind evaluate together are a usage error: the evaluate template is the brief")
    if kind == "work" and not brief:
        raise errors.Usage("--brief is required for --kind work")
    if machine == "":
        raise errors.Usage("--machine must not be empty")

    of_lane = None
    verdict_path = None
    if kind == "evaluate":
        of_lane = ctx.store.get_lane(of)
        if of_lane is None:
            raise errors.Refused(f"no lane {of!r}: --of must name an existing lane row")
        if of_lane.get("tenant") != ctx.tenant.name:
            # `--state-dir` is overridable, so one tenant's store can be pointed at another's rows.
            # Evaluating across that line would bill THIS tenant's seat for another's work.
            raise errors.Refused(
                f"lane {of!r} belongs to tenant {of_lane.get('tenant')!r}, not {ctx.tenant.name!r}")
        if of_lane.get("kind") == "evaluate":
            # Decision (DO-670), taken by the implementing lane because the spec does not say
            # either way, and recorded here rather than left implicit: refused rather than allowed.
            # An evaluate lane's own verdict is about the THOROUGHNESS of its evaluation, not
            # a claim about the original work, so a further evaluate lane would have nothing
            # meaningful to re-derive against — and nothing here bounds how deep such a chain
            # could go. Refusing keeps "evaluate" one level deep, which is all remote-lanes design
            # §4.5 and the evaluate template (``rabota/briefs/evaluate.md.tmpl``) describe.
            raise errors.Refused(
                f"lane {of!r} is itself an evaluate lane: evaluating an evaluate lane is not supported")
        if machine is not None and machine != of_lane["machine"]:
            raise errors.Refused(
                f"--machine {machine!r} disagrees with lane {of!r}'s machine {of_lane['machine']!r}: "
                "an evaluate lane must run on the same machine as the lane it evaluates "
                "(remote-lanes design §4.5)")
        machine = of_lane["machine"]
        verdict_path = Path(of_lane["out_dir"]) / "verdict.json"
        # NOT validated here. `out_dir` is a path on `of_lane`'s OWN machine, so for a remote lane
        # this process cannot stat it — checking it locally refused every real dev lane and passed
        # only because a fixture paired machine="dev" with a local tmpdir (DO-670 review). The
        # check moved below, after the budget gate, where it may spend an ssh round trip.
    elif machine is None:
        machine = "local"

    if not machine:
        raise errors.Usage("--machine must not be empty")
    m = ctx.tenant.machines.get(machine) if machine != "local" else None
    if machine != "local" and m is None:
        raise errors.Refused(f"tenant {ctx.tenant.name!r} declares no machine {machine!r}")
    if machine != "local" and seat and seat != m.profile:
        raise errors.Refused(
            f"--seat {seat!r} does not match {machine!r}'s declared profile {m.profile!r}: "
            f"a remote machine bills its own login, so the seat cannot be overridden there")

    # BEFORE the budget gate, before any ssh, and on the dry path too: both are local file reads
    # that cost nothing, and a lane that cannot be given its rules must not consume a window or
    # leave a worktree behind to find that out. AFTER the machine and seat checks, so an
    # undeclared machine keeps its own named refusal rather than being pre-empted by a complaint
    # about the brief.
    #
    # `validate` had never been called from the dispatch path at all until DO-711 — it existed, it
    # required the `## Common rules` heading, and nothing ran it, which is why both shipped briefs
    # could name a rules path that exists on no machine a lane runs on.
    if kind == "work":
        lanes_brief.validate(brief)
    rules_text = lanes_brief.read_rules()

    seat_pick = budget_mod.seat_for(ctx.tenant, machine, override=seat)
    fn = budget_fn or (lambda **kw: budget_cmd.run_budget(ctx, **kw))
    b = fn(machine=machine, model=model, effort=effort, est_minutes=est_minutes, seat=seat_pick)
    if b["allowed_new_lanes"] <= 0:
        e = errors.Refused("; ".join(f"{r['code']}: {r['detail']}" for r in b["reasons"])
                           or "no lane capacity")
        e.budget = b
        raise e

    if kind == "evaluate":
        # AFTER the gate on purpose: a remote check is an ssh call, and nothing touches a machine
        # until the budget has allowed the lane. It runs for a DRY render too — `resolve_remote`
        # already ssh's on that path to print a resolved claude path, so withholding this one
        # would buy no quiet and would let `--kind evaluate` render a recipe for a verdict that
        # is not there.
        max_v = ctx.tenant.lanes.max_verdict_bytes
        try:
            if of_lane["machine"] == "local":
                lanes_verdict.validate(verdict_path, max_v)
            else:
                read_remote_verdict(ctx, m, str(verdict_path), max_v)
        except lanes_verdict.VerdictError as e:
            raise errors.Refused(f"lane {of!r} has no readable verdict: {e}") from e

    slug = Path(brief).stem if kind == "work" else f"evaluate-{of}"
    unit = unit_name(ctx.tenant.name, slug)
    lane_id = unit.rsplit("-", 1)[-1].removesuffix(".service")
    session_id = str(uuid.uuid4())
    claude_bin = None
    config_dir = None
    lane_path = None
    if machine == "local":
        root = Path(ctx.tenant.state_dir).expanduser()
        repo_path = str(Path(ctx.tenant.root).expanduser() / repo)
        config_dir = seat_config_dir(seat_pick)
    else:
        if repo not in m.repos:
            raise errors.Refused(f"machine {machine!r} declares no repo {repo!r} "
                                 f"([machines.{machine}].repos)")
        info = resolve_remote(ctx, m)
        home = info["home"]
        root = Path(expand_remote(m.state_dir, home))
        repo_path = expand_remote(m.repos[repo], home)
        claude_bin = info["claude_bin"]
        # ``~/.local/bin`` PREPENDED to the machine's own PATH, never replacing it (DO-712): the
        # user manager on dev (systemd 249) does not carry it, so `rabota` — and every other tool
        # installed there — exited 127 inside a lane.
        lane_path = f"{home}/.local/bin:{info['path']}"
        # config_dir stays None: dev uses its own login's defaults (fix round 5 — see
        # build_local's docstring for the measured evidence that setting it to a directory
        # relocates where Claude Code looks for .claude.json).
    worktree = str(root / "worktrees" / ctx.tenant.name / lane_id)
    out_dir = str(root / "out" / ctx.tenant.name / lane_id)
    remote_brief = f"{out_dir}/brief.md"
    if kind == "evaluate":
        # `of_lane["brief"]` is the path the ORIGINAL --brief named, which for a dev lane is a file
        # on the laptop. The evaluate lane runs on dev and cannot open it, so the template would
        # have pointed a reader at a path that does not exist there. Point it instead at the copy
        # `send_brief` wrote into the evaluated lane's own out_dir, which is on the same machine as
        # the evaluate lane by §4.5 and is the exact text that lane was given.
        of_for_template = dict(of_lane)
        of_for_template["brief"] = f"{of_lane['out_dir']}/brief.md"
        brief_text = lanes_brief.render_evaluate(of_for_template, verdict_path, out_dir)
        # The rendered text, not the template: substitution is what puts machine-specific absolute
        # paths into an evaluate brief, so the thing checked has to be the thing shipped.
        lanes_brief.validate_text(brief_text, where="the rendered evaluate brief")
    else:
        brief_text = None

    argv = build_local(ctx, worktree=worktree, out_dir=out_dir,
                       brief=remote_brief, model=model, effort=effort, unit=unit,
                       session_id=session_id, claude_bin=claude_bin, config_dir=config_dir,
                       path=lane_path)
    if machine != "local":
        argv = build_remote(m, argv)
    out = {"argv": argv, "shell": " ".join(argv), "unit": unit, "session_id": session_id,
           "seat": seat_pick, "machine": machine, "est_minutes": est_minutes,
           "worktree": worktree, "out_dir": out_dir}
    if ctx.dry_run:
        # --dry-run WINS over --run (DO-743): the recipe above is rendered exactly as a real
        # --run would build it -- the read-only `resolve_remote` (and, for an evaluate lane, the
        # verdict check) already ran, on this path too, so the printed argv is the real one, not
        # a placeholder -- but nothing past this point runs: no worktree, no brief sent, no unit
        # started, no lane row. Mirrors `brief.py`'s `dry-run: nothing written` line (DO-742),
        # adapted to this command's shape: `lane recipe` returns a dict that `emit` renders as
        # JSON (never lines), so the equivalent is one top-level string key rather than a head
        # line, and `_run` below turns it into the leading `--text` line.
        # The gate above is the one write a dry run still makes: `run_budget` refreshes
        # budget.json (nothing reads it back today), so the notice names it rather than claim
        # that nothing was written at all (DO-743 review).
        out["dry_run"] = "nothing started (worktree, brief, unit, lane row); the budget gate still refreshed budget.json"
        return out
    if not run:
        return out

    if machine == "local":
        raise errors.Refused("the local --run form is not implemented; use --machine dev")
    create_worktree_remote(ctx, m, repo_path, worktree, out_dir, base)
    try:
        send_brief(ctx, m, remote_brief, brief_text if kind == "evaluate" else Path(brief).read_text())
        # Beside brief.md, in the lane's own out_dir — the one directory `--add-dir` grants it, and
        # the one the brief can name without any substitution (a work brief is shipped verbatim,
        # DO-683). Inside this `try` so a failed rules send tears the worktree down like a failed
        # brief send does: a lane started without its rails is worse than a lane not started.
        send_brief(ctx, m, f"{out_dir}/{lanes_brief.RULES.name}", rules_text)
        res = ctx.runner.run(argv)
        if not res.ok:
            raise errors.RabotaError(f"could not start {unit} on {machine}: {(res.err or res.out).strip()}")
    except Exception:
        # A worktree created just above and then orphaned by a brief-send or unit-start failure
        # is invisible to every rabota command from here on (census/reap both work from lane
        # rows, and none exists for it) — best-effort cleanup, then re-raise the ORIGINAL error.
        _remove_worktree_remote(ctx, m, repo_path, worktree)
        raise
    ctx.store.insert_lane({"id": lane_id, "tenant": ctx.tenant.name, "kind": kind,
                        "brief": brief if kind == "work" else remote_brief,
                        "repo": repo, "worktree": worktree, "out_dir": out_dir, "machine": machine,
                        "unit": unit, "session_id": session_id, "status": "started", "seat": seat_pick,
                        "model": model, "effort": effort, "started_at": store.now(),
                        "of_lane": of, "five_h_pct_at_start": b.get("five_h_pct_now")})
    return out


TERMINAL_STATUSES = ("done", "failed", "abandoned")  # set by census.settle_finished / reap;
# a lane in one of these is settled and safe to retire. "started" is not: retiring it would
# discard the row a later `census` call still needs to settle from the unit's own stream.
RETIRED_STATUS = "retired"


def run_list(ctx, status: str | None = None) -> dict:
    """``{"lanes": [...]}``, tenant-scoped, optionally filtered to one ``status``.

    A pure read over ``ctx.store`` — no ssh, no unit inspection, no polling. With no ``status``
    this returns every row regardless of state: a live lane, a settled one and a retired one are
    all "a lane that exists", and narrowing that by default would hide exactly the settled rows a
    caller needs in order to decide what to retire. Filtering is opt-in via ``--status``, matching
    ``rabota lane list --status running`` in the v2 skill — though the vocabulary this store
    actually writes is ``started`` (``run_recipe``, ``census.settle_finished``), never
    ``running``; ``--status`` is a plain passthrough to the stored column, not an alias table, so
    a caller after live lanes wants ``--status started``.
    """
    return {"lanes": ctx.store.list_lanes(ctx.tenant.name, status=status)}


def _get_tenant_lane(ctx, lane_id: str) -> dict:
    """One row by id, scoped to ``ctx.tenant`` — an unknown id, or one belonging to another
    tenant, refuses by name rather than returning ``None`` or another tenant's row.
    """
    row = ctx.store.get_lane(lane_id)
    if row is None or row.get("tenant") != ctx.tenant.name:
        raise errors.Refused(f"no lane {lane_id!r}")
    return row


def run_status(ctx, lane_id: str) -> dict:
    """The one row for ``lane_id`` — the row itself, never a lane's prose. The skill reads only
    ``verdict.json``/``evaluation.json`` for content; this is the small, tenant-scoped projection
    of what the table already knows.
    """
    return _get_tenant_lane(ctx, lane_id)


def run_retire(ctx, lane_id: str) -> dict:
    """Transition a settled lane to ``status="retired"``; return the row as it ends up.

    Only a lane already in ``TERMINAL_STATUSES`` may retire — a still-``started`` lane refuses,
    because retiring it would throw away the row ``census`` still needs in order to settle it from
    the unit's own stream (there is no unit inspection here to re-derive that). Retiring an
    already-``retired`` lane is a defined no-op: it returns the row unchanged rather than refusing,
    so the skill's "as soon as evaluated" call site never has to check first.

    With ``ctx.dry_run`` set (DO-743, same audit as ``lane recipe``), a lane that WOULD retire
    changes no row: the status check above still runs (so a caller learns whether the retire would
    be refused), but ``store.update_lane`` is skipped and the row comes back unchanged plus a
    ``dry_run`` key, the same shape ``run_recipe`` uses.
    """
    row = _get_tenant_lane(ctx, lane_id)
    if row["status"] == RETIRED_STATUS:
        return row
    if row["status"] not in TERMINAL_STATUSES:
        raise errors.Refused(
            f"lane {lane_id!r} has status {row['status']!r}, not one of {TERMINAL_STATUSES}: "
            "only a settled lane may be retired")
    if ctx.dry_run:
        return {**row, "dry_run": "nothing retired"}
    ctx.store.update_lane(lane_id, status=RETIRED_STATUS)
    return _get_tenant_lane(ctx, lane_id)


def _build(sub):
    p = sub.add_parser("lane", help="render or run exactly one lane unit")
    s = p.add_subparsers(dest="lane_cmd", required=True)
    r = s.add_parser("recipe", help="print the lane argv; --run starts it")
    r.add_argument("--brief", default=None)
    r.add_argument("--repo", required=True)
    r.add_argument("--machine", default=None)
    r.add_argument("--base", default=None)
    r.add_argument("--seat", default=None)
    r.add_argument("--model", default=None)
    r.add_argument("--effort", default=None)
    r.add_argument("--est-minutes", type=int, default=30)
    r.add_argument("--run", action="store_true",
                   help="start the lane; the global --dry-run overrides this and only prints the recipe")
    r.add_argument("--kind", choices=["work", "evaluate"], default="work")
    r.add_argument("--of", default=None)
    l = s.add_parser("list", help="list lane rows, tenant-scoped")
    l.add_argument("--status", default=None)
    st = s.add_parser("status", help="print one lane row")
    st.add_argument("lane_id")
    rt = s.add_parser("retire", help="mark a settled lane retired")
    rt.add_argument("lane_id")


def _run(ns, **ctx_kw):
    ctx = Context.from_namespace(ns, **ctx_kw)
    # `getattr` with a "recipe" default, not `ns.lane_cmd` directly: several existing tests
    # (test_lane_recipe.py) build the Namespace by hand for the recipe path only and never set
    # this field, since `recipe` was the sole subcommand before this one grew siblings.
    lane_cmd = getattr(ns, "lane_cmd", "recipe")
    if lane_cmd == "list":
        # An EMPTY --status is a usage error, not "no filter". `store.list_lanes` tests
        # `if status:`, so "" is indistinguishable from None and lists every row — which is
        # exactly what `--status "$WANT"` expands to when WANT is unset. Silently listing
        # everything is the wrong answer to a filter the caller believed they set.
        if ns.status is not None and not ns.status.strip():
            raise errors.Usage("--status must not be empty; omit it to list every lane")
        out = run_list(ctx, status=ns.status)
        return ([f"{l['id']} {l['status']} {l['kind']} {l['machine']}" for l in out["lanes"]]
                if ns.text else out)
    if lane_cmd == "status":
        row = run_status(ctx, ns.lane_id)
        if not ns.text:
            return row
        lines = [f"{row['id']} {row['status']}"]
        if row.get("settle_reason"):
            lines.append(row["settle_reason"])
        return lines
    if lane_cmd == "retire":
        row = run_retire(ctx, ns.lane_id)
        lines = [f"{row['id']} {row['status']}"]
        if row.get("dry_run"):
            lines.insert(0, f"dry-run: {row['dry_run']}")
        return lines if ns.text else row
    default_model = (ctx.tenant.lanes.evaluate_model if ns.kind == "evaluate"
                     else ctx.tenant.lanes.default_model)
    out = run_recipe(ctx, brief=ns.brief, repo=ns.repo, machine=ns.machine, base=ns.base,
                     seat=ns.seat, model=ns.model or default_model,
                     effort=ns.effort or ctx.tenant.lanes.default_effort,
                     est_minutes=ns.est_minutes, run=ns.run, kind=ns.kind, of=ns.of)
    lines = [out["unit"], out["shell"]]
    if out.get("dry_run"):
        lines.insert(0, f"dry-run: {out['dry_run']}")
    return lines if ns.text else out


cli.register("lane", _build, _run)
