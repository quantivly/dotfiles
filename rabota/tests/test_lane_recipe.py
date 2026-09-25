import argparse, json, os, shutil, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
from rabota import context, errors
from rabota.commands import lane
from rabota.lanes import brief as lanes_brief
from rabota.runner import FakeRunner, Result
from tests.support import last_json
from tests.test_cli import install_fixture_home, run_cli

RESOLVE_MARKER = "---RABOTA-RESOLVE---"


def framed(home="/home/ubuntu", path="/usr/bin:/bin", claude="/home/ubuntu/.local/bin/claude",
           *, before=""):
    """A `resolve_remote` reply as the remote actually prints it: anything the login shell emitted
    (``before``), then the marker, then exactly the three values -- an absent claude being an
    EMPTY line, not a missing one. Every fixture builds its reply through here, so the framing is
    written down once and a change to it cannot leave a row asserting the old shape."""
    return f"{before}{RESOLVE_MARKER}\n{home}\n{path}\n{claude}\n"

# DO-669: a local $HOME no machine has. Many rows in the LocalRecipeTests hierarchy build a
# command for a machine that is NOT this one, against fixtures whose remote home is dev's real
# `/home/ubuntu`. On dev the two homes coincide, so "the resolved remote value reached the argv"
# and "the tenant's home-relative default was expanded LOCALLY" render the same string. That
# inverted two rows outright (they asserted `/home/ubuntu` was absent from commands that name it
# by design) and hollowed four more. Pinning the LOCAL side — rather than moving the remote
# sentinel off dev's measured values — separates the two on every machine, so a row's verdict no
# longer depends on who runs it.
#
# The genuinely local rows are pinned too (`test_the_seat_is_pinned_by_config_dir`,
# `test_a_local_recipe_sets_claude_config_dir_to_the_seat_path`), and the fiction costs them
# nothing: each computes its expected value through the same `lane.seat_config_dir` call it
# asserts against, so it is self-referential either way.
LOCAL_HOME = "/nonexistent-local-home"


def pin_local_home(test):
    """Pin this process's ``$HOME`` to :data:`LOCAL_HOME` for the life of ``test``, and return what
    ``Path.home()`` then answers.

    :class:`LocalRecipeTests` calls this in ``setUp``, so the pin is in force before any row builds
    a context and every class in that hierarchy inherits it.

    The refusal is the point. Were the patch not to take, this would hand the caller the RUNNER's
    own home as its needle — which is exactly the pre-DO-669 assertion: machine-dependent, passing
    off dev and inverting on it. Raising says so at once rather than silently reinstating it.
    """
    patcher = patch.dict(os.environ, {"HOME": LOCAL_HOME})
    patcher.start(); test.addCleanup(patcher.stop)
    home = str(Path.home())
    if home != LOCAL_HOME:
        raise AssertionError(f"$HOME pin did not take: Path.home() is {home!r}, not {LOCAL_HOME!r}")
    return home

FIX = Path(__file__).parent / "fixtures"


class UnitNameTests(unittest.TestCase):
    def test_unit_name_is_prefixed_and_unique(self):
        a = lane.unit_name("quantivly", "smoke")
        b = lane.unit_name("quantivly", "smoke")
        self.assertTrue(a.startswith("rabota-lane-quantivly-smoke-"))
        self.assertTrue(a.endswith(".service"))
        self.assertNotEqual(a, b)

    def test_a_slug_is_reduced_to_safe_characters(self):
        self.assertIn("rabota-lane-quantivly-a-b-", lane.unit_name("quantivly", "a/b; rm -rf"))

    def test_an_all_punctuation_slug_falls_back_to_lane(self):
        # Every character in the slug is stripped by SAFE, so ``s`` is empty and must hit the
        # ``or "lane"`` fallback rather than producing a double-dashed, empty-slug name.
        self.assertIn("rabota-lane-quantivly-lane-", lane.unit_name("quantivly", ";;;"))


class LocalRecipeTests(unittest.TestCase):
    def setUp(self):
        # DO-669. Measured, not assumed — and the counts are PER SUBSTITUTION, not a total.
        # Replacing either half of `run_recipe`'s resolved remote answer with this process's own
        # home — `claude_bin = None` (so the tenant's home-relative default is expanded here) or
        # `home = str(Path.home())` — is killed by 3 rows each under a neutral $HOME. Without this
        # pin each scores ZERO net kills on dev: the substitution is invisible there, and the two
        # rows that are red on dev regardless are red with or without it, so they prove nothing
        # about it. With the pin it is 3 and 3 on dev too. The two kill-sets share one row, so 5
        # distinct rows rest on this, plus `test_an_explicit_config_dir_...` on the build_local side.
        self.local_home = pin_local_home(self)

    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        c = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner,
                                           env={"PATH": "/bin"}, cwd=Path("/"))
        # RunRecipeTests (below) opens ctx.store; matches the pattern in test_census.py etc. so a
        # lazily-opened sqlite connection is not left for the garbage collector to close.
        self.addCleanup(lambda: c._store and c._store.close())
        return c

    def argv(self, ctx=None, **overrides):
        """Build the local argv; ``**overrides`` replaces any ``build_local`` kwarg, ``ctx`` an
        already-built context (e.g. one with a field poked for a single test)."""
        ctx = ctx or self.ctx(FakeRunner([]))
        kwargs = dict(worktree="/w/t", out_dir="/o/d",
                      brief="/o/d/brief.md", model="claude-sonnet-5", effort="medium",
                      unit="rabota-lane-x.service")
        kwargs.update(overrides)
        return lane.build_local(ctx, **kwargs)

    def claude_bin(self):
        # build_local expands the configured claude_bin (DO-652 correction 6: the config default
        # is home-relative, expanded only at call time), so the argv holds the EXPANDED path.
        return str(Path(self.ctx(FakeRunner([])).tenant.lanes.claude_bin).expanduser())

    def assert_pair(self, argv, flag, value):
        """The flag is present AND its value is the very next element."""
        self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index(flag) + 1], value, f"{flag} value")

    def test_it_is_a_systemd_run_user_unit(self):
        a = self.argv()
        self.assertEqual(a[0], "systemd-run")
        self.assertIn("--user", a)
        self.assertIn("--collect", a)
        self.assertIn("--unit=rabota-lane-x.service", a)

    def test_stdout_and_stderr_are_appended_to_files_not_only_the_journal(self):
        a = self.argv()
        self.assertIn("-p", a)
        self.assertIn("StandardOutput=append:/o/d/stream.jsonl", a)
        self.assertIn("StandardError=append:/o/d/stream.err", a)

    def test_the_seat_is_pinned_by_config_dir(self):
        # Fix round 4: measured 2026-09-20 — ~/.claude-quantivly-1 does not exist on this
        # machine. scripts/claude-account-dirs.sh (ROOT ~/.local/state/claude-account-dirs) is
        # what actually builds these dirs, one per seat, and that path is what this pins.
        #
        # Fix round 5: build_local no longer defaults config_dir to seat_config_dir(seat) — a
        # caller (run_recipe's LOCAL branch) must now say so explicitly, which is what this row
        # does. A row asserting CLAUDE_CONFIG_DIR should name which value it means.
        config_dir = lane.seat_config_dir("quantivly-1")
        self.assertIn(f"--setenv=CLAUDE_CONFIG_DIR={config_dir}", self.argv(config_dir=config_dir))

    def test_the_agent_is_told_to_read_the_brief(self):
        a = self.argv()
        self.assertIn("Read /o/d/brief.md and execute.", a)
        self.assertIn("--permission-mode", a)
        self.assertIn("auto", a)

    def test_the_prompt_never_carries_the_brief_contents(self):
        self.assertNotIn("brief body", " ".join(self.argv()))

    def test_the_lane_carries_a_memory_cap(self):
        # Without MemoryMax the unit runs uncapped, outside the host's memory budget — which is
        # the reason a lane is a systemd unit rather than a bare process.
        self.assertIn(f"MemoryMax={self.ctx(FakeRunner([])).tenant.lanes.memory_max}", self.argv())

    def test_the_claude_binary_comes_from_config_not_a_literal(self):
        # Spec §4.4: resolve the binary rather than hardcoding it — dev's path is version-pinned,
        # so a literal breaks every stored recipe at the next upgrade and is wrong on any machine
        # whose layout differs from this one's.
        ctx = self.ctx(FakeRunner([]))
        ctx.tenant.lanes.claude_bin = "/opt/claude/2.1.278/claude"
        argv = lane.build_local(ctx, worktree="/w/t",
                                out_dir="/o/d", brief="/o/d/brief.md", model="claude-sonnet-5",
                                effort="medium", unit="rabota-lane-x.service")
        self.assertIn("/opt/claude/2.1.278/claude", argv)

    def test_the_working_directory_is_the_worktree(self):
        self.assertIn("--working-directory=/w/t", self.argv())

    def test_the_output_is_streamed_json_and_verbose(self):
        a = self.argv()
        self.assert_pair(a, "--output-format", "stream-json")
        self.assertIn("--verbose", a)

    def test_the_model_and_effort_are_not_hardcoded(self):
        # Non-default values: the fixture's own default_model/default_effort ("claude-sonnet-5",
        # "medium") are also what self.argv() happens to pass, so a hardcoded literal matching
        # those would pass unnoticed. These values cannot.
        a = self.argv(model="claude-opus-5", effort="high")
        self.assert_pair(a, "--model", "claude-opus-5")
        self.assert_pair(a, "--effort", "high")

    def test_the_out_dir_is_added_for_the_agent_to_read(self):
        self.assert_pair(self.argv(), "--add-dir", "/o/d")

    def test_the_permission_mode_comes_from_config_not_a_literal(self):
        # Same defect class as claude_bin: "auto" is simultaneously the fixture's config value,
        # LaneDefaults's own default, and what a hardcoded literal would produce. A non-default
        # value is the only way to tell them apart.
        ctx = self.ctx(FakeRunner([]))
        ctx.tenant.lanes.permission_mode = "plan"
        self.assert_pair(self.argv(ctx=ctx), "--permission-mode", "plan")

    def test_an_explicit_session_id_reaches_the_argv(self):
        self.assert_pair(self.argv(session_id="fixed-session-id"), "--session-id", "fixed-session-id")

    def test_systemd_properties_precede_the_command_and_agent_flags_follow_it(self):
        # systemd-run reads -p properties only before the command; everything after the command is
        # handed to claude, not to systemd. A reordering leaves a plausible argv in which the
        # memory cap silently becomes an argument to the agent instead of a unit property.
        a = self.argv()
        binary = a.index(self.claude_bin())
        for prop in ("StandardOutput=", "StandardError=", "MemoryMax="):
            i = next(n for n, v in enumerate(a) if v.startswith(prop))
            self.assertLess(i, binary, prop)
        for flag in ("--output-format", "--session-id", "--model", "--effort",
                     "--permission-mode", "--add-dir"):
            self.assertGreater(a.index(flag), binary, flag)


class RemoteRecipeTests(LocalRecipeTests):
    def remote_argv(self):
        ctx = self.ctx(FakeRunner([]))
        local = lane.build_local(ctx, worktree="/w/t", out_dir="/o/d",
                                 brief="/o/d/brief.md", model="claude-sonnet-5", effort="medium",
                                 unit="rabota-lane-x.service")
        return lane.build_remote(ctx.tenant.machines["dev"], local)

    def test_it_wraps_the_local_argv_in_one_ssh_call(self):
        a = self.remote_argv()
        self.assertEqual(a[0], "ssh")
        self.assertIn("BatchMode=yes", a)
        self.assertIn("dev", a)

    def test_a_remote_lane_joins_the_agents_slice(self):
        self.assertIn("--slice=agents.slice", self.remote_argv()[-1])

    def test_every_element_is_single_quoted_for_the_remote_shell(self):
        cmd = self.remote_argv()[-1]
        self.assertIn("'Read /o/d/brief.md and execute.'", cmd)

    def test_an_equals_leading_value_cannot_be_expanded_by_zsh(self):
        ctx = self.ctx(FakeRunner([]))
        local = lane.build_local(ctx, worktree="/w/t", out_dir="/o/d",
                                 brief="=ls", model="claude-sonnet-5", effort="medium",
                                 unit="rabota-lane-x.service")
        self.assertIn("'Read =ls and execute.'", lane.build_remote(ctx.tenant.machines["dev"], local)[-1])

    def test_the_brief_travels_on_stdin_never_on_a_command_line(self):
        runner = FakeRunner([(["ssh"], Result(0, "", ""))])
        ctx = self.ctx(runner)
        lane.send_brief(ctx, ctx.tenant.machines["dev"], "/o/d/brief.md", "BRIEF-SENTINEL-9f")
        self.assertNotIn("BRIEF-SENTINEL-9f", " ".join(runner.calls[0]))
        self.assertIn("cat > '/o/d/brief.md'", runner.calls[0][-1])

    def test_a_failed_brief_send_is_an_error_not_a_silent_skip(self):
        # NOTE (DO-652 task-7 dispatch, correction not explicitly numbered but required): the
        # brief's own text names ``errors.Error``, which does not exist anywhere in this package
        # (rabota/errors.py has RabotaError/Usage/Refused/Partial/SecretLeak). ``RabotaError`` is
        # the base "exit 5, unexpected failure" class and is what every other subprocess-failure
        # site in this codebase raises (see rabota/sources/github.py) — used here instead.
        ctx = self.ctx(FakeRunner([(["ssh"], Result(255, "", "no route"))]))
        with self.assertRaises(errors.RabotaError):
            lane.send_brief(ctx, ctx.tenant.machines["dev"], "/o/d/brief.md", "x")

    def test_an_explicit_config_dir_is_passed_through_verbatim_not_reconstructed(self):
        # Fix round 2, Critical 2, then fix round 3 (Zvi's decision), then fix round 5: this
        # exercises build_local's raw mechanism in isolation — when GIVEN a config_dir, it emits
        # that value verbatim rather than reconstructing it via seat_config_dir(seat) (which
        # would use THIS process's Path.home(), wrong for any other machine). No production
        # caller passes config_dir="/home/ubuntu/.claude" any more (round 5: run_recipe's remote
        # branch passes nothing at all, see test_a_remote_recipe_never_sets_claude_config_dir),
        # but the mechanism itself — "trust the given value, don't re-derive it" — still matters.
        # DO-669: the local home is PINNED (setUp) rather than read from the environment, because
        # the remote values here are dev's real ones and dev's real $HOME is /home/ubuntu — so on
        # dev this row used to assert /home/ubuntu was absent from a command that names it twice
        # by design — the CLAUDE_CONFIG_DIR value and the binary path, both passed in explicitly.
        ctx = self.ctx(FakeRunner([]))
        local = lane.build_local(ctx, worktree="/w/t", out_dir="/o/d",
                                 brief="/o/d/brief.md", model="claude-sonnet-5", effort="medium",
                                 unit="rabota-lane-x.service", config_dir="/home/ubuntu/.claude",
                                 claude_bin="/home/ubuntu/.local/bin/claude")
        cmd = lane.build_remote(ctx.tenant.machines["dev"], local)[-1]
        self.assertIn("'--setenv=CLAUDE_CONFIG_DIR=/home/ubuntu/.claude'", cmd)
        self.assertNotIn(self.local_home, cmd)


class ResolveRemoteTests(LocalRecipeTests):
    """resolve_remote (fix rounds 1-5): $HOME and the claude binary — proven in one ssh call, or
    a refusal.

    Folded from the original ``resolve_claude_bin`` after the controller found that every OTHER
    remote path (``machine.state_dir``, ``machine.repos[...]``) was still being used unexpanded
    and then single-quoted — the exact ``~``-suppression bug correction 6 fixed for the claude
    binary alone.

    Round 3 (2026-09-20, Zvi's decision): a remote lane authenticates with the TARGET MACHINE'S
    OWN login (spec §4.2) — never a per-seat account dir; ``[machines.<m>].profile`` only
    DECLARES the seat a machine's usage bills, for the laptop's own budget gate.

    Round 5 (the first live smoke this plan ever ran): this used to also resolve and prove the
    account dir (``$HOME/.claude``) so it could be passed to ``CLAUDE_CONFIG_DIR``. The smoke
    showed that setting that variable to a DIRECTORY makes Claude Code look for
    ``<dir>/.claude.json``, while dev keeps that file at ``$HOME/.claude.json`` — so the lane
    authenticated but ran without its ``.claude.json`` state. The fix is to not set the variable
    for a remote lane at all (see ``build_local``'s docstring), so nothing here proves an account
    dir any more — proving a value nobody consumes is exactly the dead check this repo's own
    guard (a mutation surviving with no row to kill it) flags for retirement. See
    ``resolve_remote``'s docstring for the full reasoning.
    """

    def test_it_returns_home_the_path_and_the_claude_binary(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, framed(), ""))]))
        self.assertEqual(lane.resolve_remote(ctx, ctx.tenant.machines["dev"]),
                         {"home": "/home/ubuntu", "path": "/usr/bin:/bin",
                          "claude_bin": "/home/ubuntu/.local/bin/claude"})

    def test_a_failed_ssh_refuses_rather_than_guessing(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(255, "", "no route"))]))
        with self.assertRaises(errors.Refused):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_a_reply_missing_the_claude_line_refuses(self):
        # A successful ssh that finds no executable claude prints nothing for that field (the
        # script's own `[ -x "$p" ] &&` guard) — not room for a fallback, an unmeasured machine.
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, framed(claude=""), ""))]))
        with self.assertRaisesRegex(errors.Refused, "executable claude"):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_an_empty_reply_refuses(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, "", ""))]))
        with self.assertRaises(errors.Refused):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_a_relative_home_refuses(self):
        # A first line not starting with "/" cannot be the proof this resolver promises; refuse
        # rather than trust an unexpected shell reply verbatim. Every OTHER field is well-formed
        # here, so the row pins the home rule alone rather than passing on a second fault.
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, framed(home="home"), ""))]))
        with self.assertRaisesRegex(errors.Refused, r"\$HOME"):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_a_login_banner_on_stdout_refuses_instead_of_shifting_every_value(self):
        """Review lane, 2026-09-24. Under the original positional parse a banner line that itself
        began with `/` shifted all three values by one and EVERY check still passed: `$HOME`
        became the banner and the claude binary became the PATH string. Silent and wrong, which
        is the one outcome this module is shaped to refuse. The marker discards anything the
        login shell said before it."""
        for banner in ("/etc/motd says hi\n", "Welcome to dev\n", "a\nb\n"):
            with self.subTest(banner=banner):
                ctx = self.ctx(FakeRunner([(["ssh"], Result(0, framed(before=banner), ""))]))
                self.assertEqual(lane.resolve_remote(ctx, ctx.tenant.machines["dev"])["home"],
                                 "/home/ubuntu")

    def test_a_fourth_value_after_the_marker_refuses_rather_than_taking_a_slot(self):
        """The maintenance trap: a value added to the script later used to take `claude_bin`'s
        slot silently. Exactly three lines are expected, so a fourth of any origin refuses."""
        ctx = self.ctx(FakeRunner([(["ssh"], Result(
            0, framed() + "/etc/os-release\n", ""))]))
        with self.assertRaises(errors.Refused):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_a_newline_inside_the_path_refuses_rather_than_truncating_it(self):
        """Same class from the other side: an embedded newline used to make `claude_bin` a PATH
        fragment, which `build_local` would then emit as the binary to exec."""
        ctx = self.ctx(FakeRunner([(["ssh"], Result(
            0, framed(path="/opt/a\n/opt/b:/usr/bin"), ""))]))
        with self.assertRaises(errors.Refused):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_a_reply_with_no_marker_at_all_refuses(self):
        """A remote that answered without the framing -- an old script, a truncated stream -- is
        unmeasured, and unmeasured refuses. It is never read as a bare positional reply."""
        ctx = self.ctx(FakeRunner([(["ssh"], Result(
            0, "/home/ubuntu\n/usr/bin:/bin\n/home/ubuntu/.local/bin/claude\n", ""))]))
        with self.assertRaises(errors.Refused):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_a_failed_ssh_whose_payload_parses_still_names_something(self):
        """`', '.join(missing)` is EMPTY when res.ok is false but all three values parse, and the
        refusal then named nothing at all: "could not resolve  on dev: ...". A refusal that names
        no cause is the same defect DO-710 fixed in the verdict validator."""
        ctx = self.ctx(FakeRunner([(["ssh"], Result(255, framed(), "connection reset"))]))
        with self.assertRaises(errors.Refused) as cm:
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])
        self.assertNotIn("resolve  on", str(cm.exception))
        self.assertIn("ssh failed", str(cm.exception))

    def test_a_reply_missing_the_path_line_refuses(self):
        """DO-712. A lane's PATH is set from this value, and systemd has no "prepend" — so an
        empty answer here would be a unit started with PATH unset, which is strictly worse than
        the missing `~/.local/bin` it was added to fix. Unmeasured refuses; it is never room."""
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, framed(path=""), ""))]))
        with self.assertRaisesRegex(errors.Refused, r"\$PATH"):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])


class CreateWorktreeRemoteTests(LocalRecipeTests):
    """DO-657: ``create_worktree_remote`` fetches before ``worktree add``, in the same ssh call, and
    a caller that passes no ``--base`` gets the remote's own ``origin/HEAD`` rather than whatever
    the clone's local ``HEAD`` happened to be left at.
    """

    def machine(self, ctx):
        return ctx.tenant.machines["dev"]

    def test_the_fetch_is_present_and_ordered_before_worktree_add_in_the_same_command(self):
        runner = FakeRunner([(["ssh"], Result(0, "", ""))])
        ctx = self.ctx(runner)
        lane.create_worktree_remote(ctx, self.machine(ctx), "/repo", "/w/t", "/o/d", "origin/main")
        self.assertEqual(len(runner.calls), 1)  # one ssh call, not two
        cmd = runner.calls[0][-1]
        self.assertLess(cmd.index("'fetch'"), cmd.index("'worktree'"))
        self.assertIn("'origin'", cmd)

    def test_a_failing_fetch_refuses_and_creates_nothing(self):
        runner = FakeRunner([(["ssh"], Result(1, "", "fatal: unable to access repo"))])
        ctx = self.ctx(runner)
        with self.assertRaises(errors.Refused):
            lane.create_worktree_remote(ctx, self.machine(ctx), "/repo", "/w/t", "/o/d", "origin/main")
        # The one ssh call made is the fetch+worktree batch itself — no separate worktree-add
        # call was ever attempted after it.
        self.assertEqual(len(runner.calls), 1)

    def test_no_base_resolves_origin_head_and_uses_it_for_worktree_add(self):
        runner = SequencedRunner([Result(0, "main", ""), Result(0, "", "")])
        ctx = self.ctx(runner)
        lane.create_worktree_remote(ctx, self.machine(ctx), "/repo", "/w/t", "/o/d", None)
        self.assertEqual(len(runner.calls), 2)
        resolve_cmd = runner.calls[0][-1]
        self.assertIn("symbolic-ref", resolve_cmd)
        self.assertIn("refs/remotes/origin/HEAD", resolve_cmd)
        worktree_cmd = runner.calls[1][-1]
        self.assertIn("'main'", worktree_cmd)
        self.assertLess(worktree_cmd.index("'add'"), worktree_cmd.index("'main'"))

    def test_a_missing_origin_head_refuses_naming_the_repo(self):
        runner = FakeRunner([(["ssh"], Result(0, "", ""))])  # symbolic-ref found nothing
        ctx = self.ctx(runner)
        with self.assertRaises(errors.Refused) as cm:
            lane.create_worktree_remote(ctx, self.machine(ctx), "/repo", "/w/t", "/o/d", None)
        self.assertIn("/repo", str(cm.exception))
        self.assertIn("--base", str(cm.exception))
        # Refused before ever attempting the fetch+worktree-add call.
        self.assertEqual(len(runner.calls), 1)

    def test_a_failed_origin_head_lookup_refuses_naming_the_repo(self):
        runner = FakeRunner([(["ssh"], Result(255, "", "no route to host"))])
        ctx = self.ctx(runner)
        with self.assertRaises(errors.Refused) as cm:
            lane.create_worktree_remote(ctx, self.machine(ctx), "/repo", "/w/t", "/o/d", None)
        self.assertIn("/repo", str(cm.exception))


class ExpandRemoteTests(unittest.TestCase):
    """expand_remote (DO-652 task-7 fix round 1): expand ``~`` against the REMOTE home only."""

    def test_bare_tilde_expands_to_home(self):
        self.assertEqual(lane.expand_remote("~", "/home/ubuntu"), "/home/ubuntu")

    def test_tilde_slash_expands_against_the_given_home(self):
        self.assertEqual(lane.expand_remote("~/quantivly/hub", "/home/ubuntu"),
                         "/home/ubuntu/quantivly/hub")

    def test_an_absolute_path_passes_through_unchanged(self):
        self.assertEqual(lane.expand_remote("/opt/x", "/home/ubuntu"), "/opt/x")

    def test_a_tilde_user_form_refuses_rather_than_passing_through(self):
        # Passing it through is exactly how a path silently becomes a literal directory named
        # "~otheruser" on the target instead of expanding — refuse instead of guessing.
        with self.assertRaises(errors.Refused):
            lane.expand_remote("~otheruser/x", "/home/ubuntu")


class SequencedRunner:
    """Answers calls in order, so a row can fail the Nth ssh and only the Nth.

    ``FakeRunner`` matches by argv *prefix*, first match wins — which is exactly why the brief's
    own "a failed unit start records no started row" row was hollow (task-7 dispatch correction
    7): a canned response meant for the LAST call matched every earlier call too, so nothing ever
    reached the point it claimed to be testing. This double stands in wherever a row needs
    call N to behave differently from call N+1.

    ``self.inputs`` records each call's ``input=`` (fix round 2, Important 2): neither this nor
    ``FakeRunner`` used to keep it, so a mutation that emptied the brief before sending it (``
    Path(brief).read_text()`` → ``""``) survived the whole suite — the sentinel row proved stdin-
    not-argv but called ``send_brief`` directly, bypassing ``run_recipe`` entirely.
    """
    def __init__(self, results):
        self.results, self.calls, self.inputs = list(results), [], []

    def run(self, argv, *, env=None, input=None, timeout=60, cwd=None):
        self.calls.append(list(argv))
        self.inputs.append(input)
        return self.results.pop(0) if self.results else Result(0, "", "")


class RunRecipeTests(LocalRecipeTests):
    # A CONTRACT-SHAPED brief, not "# Brief\nDo the thing.": DO-711 wired `lanes.brief.validate`
    # into `run_recipe`, which is where it always belonged and never was, so every row that
    # dispatches now goes through it.
    BRIEF_TEXT = ("# Brief\n## Common rules\nRead `_common-rules.md`, beside this brief.\n"
                  "## Role\nYou do the thing.\n## Assignment\n1. Do the thing.\n"
                  "## Ownership\nWrite only under out_dir.\n## Outputs\nout_dir: {out_dir}\n"
                  "## Summary\nOne line.\n")

    def brief(self):
        p = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, p, ignore_errors=True)
        f = p / "brief.md"; f.write_text(self.BRIEF_TEXT)
        return str(f)

    def kw(self, **over):
        base = dict(brief=self.brief(), repo="hub", machine="dev", base=None, seat=None,
                    model="claude-sonnet-5", effort="medium", est_minutes=30, run=False)
        base.update(over); return base

    def ok_budget(self):
        # five_h_pct_now (fix round 2, Minor 3): every OTHER budget stub omits it, so the
        # inserted row's five_h_pct_at_start column was None everywhere and a renamed/dropped key
        # would be invisible. This is the one stub that pins it.
        return {"allowed_new_lanes": 2, "reasons": [], "seat_pick": "quantivly-0", "five_h_pct_now": 42}

    RESOLVED_HOME = "/home/ubuntu"
    RESOLVED_BIN = "/home/ubuntu/.local/bin/claude"
    # dev's real one, measured 2026-09-24 -- note it does NOT contain ~/.local/bin, which is the
    # whole of DO-712's first half.
    RESOLVED_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
    # Fix round 5: resolve_remote no longer resolves or proves an account dir (nothing consumes
    # one for a remote lane any more). DO-712 added $PATH, so its reply is three lines; the
    # claude path stays LAST because it is the one printed without a trailing newline.
    RESOLVE_OUT = framed(RESOLVED_HOME, RESOLVED_PATH, RESOLVED_BIN)

    def test_a_dry_recipe_resolves_the_remote_claude_bin_and_runs_nothing_else(self):
        # DO-652 task-7 dispatch correction 6: a non-local recipe resolves the remote home and
        # claude binary BEFORE rendering, even on the dry (non ``--run``) path — Task 9's
        # verification reads an absolute, resolved path out of a dry run's printed argv. This
        # replaces the brief's own "runs nothing" row, which asserted zero runner calls; that
        # assertion is exactly what correction 6 says is no longer true.
        runner = FakeRunner([(["ssh"], Result(0, self.RESOLVE_OUT, ""))])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw())
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(out["machine"], "dev")
        self.assertEqual(out["seat"], "quantivly-0")
        self.assertTrue(out["unit"].startswith("rabota-lane-quantivly-"))
        self.assertIn("--slice=agents.slice", out["shell"])
        # Mutation 7 (skip the resolver, use the tenant's configured claude_bin instead): the
        # config default expands to THIS machine's home, never the resolved dev path, so this
        # assertion only holds when the resolver's answer is actually used.
        self.assertIn(self.RESOLVED_BIN, out["shell"])

    def test_a_remote_recipe_never_sets_claude_config_dir(self):
        # Fix round 5, Critical: the first live smoke this plan ever ran showed that setting
        # CLAUDE_CONFIG_DIR to a DIRECTORY (an earlier round's $HOME/.claude) makes Claude Code
        # look for <dir>/.claude.json, while dev keeps that file at $HOME/.claude.json — so the
        # lane authenticated but ran without its .claude.json state ("Claude configuration file
        # not found", printed twice on stderr). The fix is to not set the variable for a remote
        # lane AT ALL, so dev falls back to its own login's defaults. This asserts the substring
        # is absent from the WHOLE rendered command — not present-but-empty, not a local value.
        # DO-669: "not a local value" needs a local home that cannot BE the resolved remote one.
        # RESOLVED_HOME is dev's real /home/ubuntu, so on dev the second assertion inverted; the
        # setUp pin makes it hold everywhere, and makes it able to tell "the resolver's answer was
        # used" apart from "the tenant's home-relative claude_bin default was expanded locally",
        # which on dev produce the same string.
        runner = FakeRunner([(["ssh"], Result(0, self.RESOLVE_OUT, ""))])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw())
        self.assertNotIn("CLAUDE_CONFIG_DIR", out["shell"])
        self.assertNotIn(self.local_home, out["shell"])

    def test_a_dry_recipe_records_no_row(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, self.RESOLVE_OUT, ""))]))
        lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw())
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])

    # ---- DO-743: the global --dry-run flag must win over --run --------------------------

    def test_global_dry_run_wins_over_run_and_starts_nothing(self):
        # Before this change `ctx.dry_run` was never read here, so `--dry-run lane recipe --run`
        # ran the WHOLE dispatch: worktree, brief, unit, row. This proves the recipe still
        # renders (the read-only resolve above already ssh's, on this path too -- decision (b):
        # a dry run prints exactly what --run would execute rather than a placeholder) but
        # nothing past it happens. Only ONE runner call -- the resolve -- must be made; the
        # `resolve_default_branch_remote`/fetch+worktree/brief/unit calls a real --run would make
        # are absent entirely, so a `SequencedRunner` with only one canned reply is itself part
        # of the assertion: a second call raises IndexError (`.pop(0)` on an empty list).
        runner = SequencedRunner([Result(0, self.RESOLVE_OUT, "")])
        ctx = self.ctx(runner)
        ctx.dry_run = True
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        self.assertEqual(out["dry_run"], "nothing started (worktree, brief, unit, lane row)")
        self.assertEqual(len(runner.calls), 1)
        self.assertIn("systemd-run", out["shell"])            # the recipe is still rendered
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])

    def test_global_dry_run_without_run_also_carries_the_notice(self):
        # `--dry-run lane recipe` (no --run at all) was already a no-op before this change; this
        # pins that the notice appears there too, so a caller cannot tell "recipe only" from
        # "dry-run" apart by the dict shape alone -- both must say plainly that nothing started.
        runner = FakeRunner([(["ssh"], Result(0, self.RESOLVE_OUT, ""))])
        ctx = self.ctx(runner)
        ctx.dry_run = True
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=False))
        self.assertEqual(out["dry_run"], "nothing started (worktree, brief, unit, lane row)")

    def test_a_real_run_carries_no_dry_run_key(self):
        # The companion case: `ctx.dry_run=False` (the default) with --run must NOT gain a
        # `dry_run` key, so a caller can test for the key's presence rather than its value.
        ok = Result(0, self.RESOLVE_OUT, "")
        branch = Result(0, "main", "")
        runner = SequencedRunner([ok, branch, ok, ok, ok, ok])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        self.assertNotIn("dry_run", out)

    def test_dry_run_still_consults_the_budget_gate(self):
        # Hazard 1: "would this be refused" is exactly what a careful caller wants from a dry
        # run, so the gate must still run and a zero budget must still refuse -- even with
        # --dry-run set, even with --run set. `run_budget`'s own writes (only budget.json, never
        # a store row) are proven separately in test_budget.py.
        runner = SequencedRunner([Result(0, self.RESOLVE_OUT, "")])
        ctx = self.ctx(runner)
        ctx.dry_run = True
        zero = {"allowed_new_lanes": 0, "reasons": [{"code": "machine:load", "detail": "busy"}],
                "seat_pick": "quantivly-0"}
        with self.assertRaises(errors.Refused):
            lane.run_recipe(ctx, budget_fn=lambda **_: zero, **self.kw(run=True))
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])

    def test_zero_budget_refuses_and_records_no_row(self):
        runner = FakeRunner([])
        ctx = self.ctx(runner)
        zero = {"allowed_new_lanes": 0, "reasons": [{"code": "machine:load", "detail": "busy"}],
                "seat_pick": "quantivly-0"}
        with self.assertRaises(errors.Refused):
            lane.run_recipe(ctx, budget_fn=lambda **_: zero, **self.kw(run=True))
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])
        # The budget gate is BEFORE anything else — a refusal here touches no machine at all.
        self.assertEqual(runner.calls, [])

    def test_a_seat_mismatched_with_the_machines_declared_profile_refuses(self):
        # Finding 1 (final whole-branch review): --seat was validated against the tenant
        # family rule but nothing tied it to [machines.<m>].profile, so a lane on dev could
        # be told to bill quantivly-1 (a valid PERSONAL... no, a valid quantivly-family seat)
        # on the laptop's gate while dev's own login (the fixture's dev profile,
        # "quantivly-0") actually bills the work — two numbers wrong at once, silently. The
        # fixture's dev profile is "quantivly-0" (tests/fixtures/config/tenants/quantivly.toml).
        runner = FakeRunner([])
        ctx = self.ctx(runner)
        with self.assertRaises(errors.Refused):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                            **self.kw(seat="quantivly-1"))
        # The refusal must touch NO machine — it fires before resolve_remote's ssh call, and
        # before the budget gate. If this check ever moves after either, this row must fail.
        self.assertEqual(runner.calls, [])

    def test_a_seat_equal_to_the_declared_profile_is_harmless(self):
        # The companion case: an explicit --seat that agrees with the machine's declared
        # profile is not an override in spirit, and must still be allowed through.
        ok = Result(0, self.RESOLVE_OUT, "")
        runner = SequencedRunner([ok, ok, ok, ok])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                              **self.kw(run=True, seat="quantivly-0"))
        self.assertEqual(out["seat"], "quantivly-0")

    def test_an_unknown_repo_for_the_machine_refuses(self):
        ctx = self.ctx(FakeRunner([]))
        with self.assertRaises(errors.Refused):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(repo="nosuch"))

    def test_an_empty_machine_is_rejected_rather_than_written_to_a_row(self):
        # DO-652 task-7 dispatch correction 8: census's settle path reads an empty/missing
        # ``machine`` column as "local" (``lane.get("machine") or "local"``), so a blank value
        # here would silently route a dev lane's settle to the wrong filesystem. run_recipe is
        # the only writer of that column, so it is the one place this can be caught.
        ctx = self.ctx(FakeRunner([]))
        with self.assertRaises(errors.Usage):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(machine=""))

    def test_run_creates_the_worktree_sends_the_brief_then_starts_the_unit(self):
        # DO-657: a remote --run with no --base now makes FIVE runner calls (resolve,
        # resolve-default-branch, fetch+worktree, brief, unit) — one more than DO-652's four,
        # because resolving `origin/HEAD` for an unspecified --base is a real extra round trip
        # (see create_worktree_remote's docstring). SequencedRunner (not FakeRunner) so
        # ``.inputs`` is available for the brief-content check.
        ok = Result(0, self.RESOLVE_OUT, "")
        branch = Result(0, "main", "")
        runner = SequencedRunner([ok, branch, ok, ok, ok, ok])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        joined = [" ".join(c) for c in runner.calls]
        # Six since DO-711: resolve, resolve-default-branch, fetch+worktree, brief, RULES, unit.
        self.assertEqual(len(runner.calls), 6)
        self.assertIn("symbolic-ref", joined[1]); self.assertIn("origin/HEAD", joined[1])
        # Fix round 2, Critical 1: out_dir is created (mkdir -p) in the SAME call as the fetch and
        # the worktree add — a shell `>` redirection does not create parent directories, and
        # systemd-run returns 0 once the transient unit is CREATED, so a missing out_dir would
        # otherwise fail invisibly AFTER a "started" row was already written.
        self.assertIn("'mkdir'", joined[2]); self.assertIn("'-p'", joined[2])
        self.assertIn(f"'{out['out_dir']}'", joined[2])
        # DO-657: the fetch is ordered before the worktree add, in the same command.
        self.assertLess(joined[2].index("'fetch'"), joined[2].index("'worktree'"))
        # DO-652 task-7 dispatch, an additional bug found in the brief's own row (same class as
        # its already-flagged correction 7): once every argv element is POSIX single-quoted, a
        # phrase spanning two elements ("git -C", "worktree add") is never a contiguous substring
        # of the joined command — only a check against ONE quoted element survives shquote.
        self.assertIn("'git'", joined[2]); self.assertIn("'worktree'", joined[2]); self.assertIn("'add'", joined[2])
        self.assertIn("cat > ", joined[3])
        self.assertIn("cat > ", joined[4])
        self.assertIn("systemd-run", joined[5])
        # Mutation 7: the resolved bin (not the locally-expanded config default) must be what
        # actually starts the unit.
        self.assertIn(self.RESOLVED_BIN, joined[5])
        # Fix round 2, Important 2: the brief's CONTENT (not just its path) must actually reach
        # the brief-send call — neither FakeRunner nor the old SequencedRunner recorded `input=`,
        # so a mutation that emptied the brief before sending it survived the whole suite.
        self.assertEqual(runner.inputs[3], self.BRIEF_TEXT)
        # ...and the path used to SEND the brief must be the exact path the agent is told to READ.
        remote_brief_path = f"{out['out_dir']}/brief.md"
        self.assertIn(f"cat > '{remote_brief_path}'", joined[3])
        self.assertIn(f"'Read {remote_brief_path} and execute.'", joined[5])
        # DO-711: the rules travel WITH the lane, into the same directory as brief.md, which is
        # the one directory `--add-dir` grants it and the one a verbatim-shipped brief can name
        # without any substitution. Content checked too, not just the path — a mutation that sent
        # an empty rules file would otherwise look identical.
        self.assertIn(f"cat > '{out['out_dir']}/{lanes_brief.RULES.name}'", joined[4])
        self.assertEqual(runner.inputs[4], lanes_brief.RULES.read_text())
        row = ctx.store.list_lanes("quantivly")[0]
        self.assertEqual(row["status"], "started")
        self.assertEqual(row["unit"], out["unit"])
        # Mutation 9: started_at must be written (list_lanes orders by it; census's abandonment
        # rule is an age test against it).
        self.assertIsNotNone(row["started_at"])
        # Mutation 10: session_id must reach both the returned dict and the stored row, and they
        # must be the SAME id (task-7 dispatch correction 3 — generated once, in run_recipe).
        self.assertTrue(out["session_id"])
        self.assertEqual(row["session_id"], out["session_id"])
        # Fix round 2, Minor 3: the budget's five_h_pct_now must reach the stored row.
        self.assertEqual(row["five_h_pct_at_start"], 42)

    def test_an_explicit_base_is_appended_to_the_worktree_add_call(self):
        # Fix round 2, Minor: every OTHER row passes base=None, so dropping the append or
        # appending it in the wrong position survived undetected.
        ok = Result(0, self.RESOLVE_OUT, "")
        runner = SequencedRunner([ok, ok, ok, ok])
        ctx = self.ctx(runner)
        lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True, base="origin/main"))
        joined = " ".join(runner.calls[1])
        self.assertIn("'origin/main'", joined)
        self.assertLess(joined.index("'worktree'"), joined.index("'origin/main'"))
        self.assertLess(joined.index("'add'"), joined.index("'origin/main'"))

    def test_local_run_refuses_cleanly_rather_than_crashing(self):
        # Fix round 2, Minor: without this row, a local --run reaches
        # create_worktree_remote(ctx, None, ...) and dies on None.ssh as an exit-5 AttributeError
        # instead of the clean exit-3 refusal the message already promises.
        ctx = self.ctx(FakeRunner([]))
        with self.assertRaises(errors.Refused):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                            **self.kw(machine="local", run=True))

    def test_a_local_recipe_sets_claude_config_dir_to_the_seat_path(self):
        # Fix round 5: mutation 3 (make the local branch pass None) turned out to be HOLLOW —
        # no row exercised run_recipe's LOCAL branch and inspected the resulting
        # CLAUDE_CONFIG_DIR value; test_the_seat_is_pinned_by_config_dir only calls build_local
        # directly. This row closes that gap.
        ctx = self.ctx(FakeRunner([]))
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                              **self.kw(machine="local", repo="hub"))
        expected = lane.seat_config_dir(out["seat"])
        self.assertIn(f"CLAUDE_CONFIG_DIR={expected}", out["shell"])

    def test_remote_paths_use_the_resolved_home_never_a_literal_tilde(self):
        # DO-652 task-7 fix round 1: the dev fixture's state_dir and repos.hub are both
        # ~-prefixed ("~/.local/state/rabota", "~/quantivly/hub" —
        # tests/fixtures/config/tenants/quantivly.toml, unchanged; it already matches the live
        # config's shape). build_remote single-quotes every argv element and POSIX single quotes
        # suppress tilde expansion, so a "~" sent as-is becomes a literal directory named "~" on
        # the remote. This proves the RESOLVED $HOME is what actually reaches both the returned
        # paths and the `git -C` argv, not the raw config value.
        ok = Result(0, self.RESOLVE_OUT, "")
        branch = Result(0, "main", "")
        runner = SequencedRunner([ok, branch, ok, ok, ok])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        self.assertNotIn("~", out["worktree"])
        self.assertNotIn("~", out["out_dir"])
        self.assertTrue(out["worktree"].startswith(self.RESOLVED_HOME + "/"), out["worktree"])
        self.assertTrue(out["out_dir"].startswith(self.RESOLVED_HOME + "/"), out["out_dir"])
        # calls[1] is the origin/HEAD resolution, itself against the resolved (not tilde) repo
        # path — proven separately below; calls[2] is the fetch+worktree-add batch.
        self.assertNotIn("~", " ".join(runner.calls[1]))
        worktree_call = " ".join(runner.calls[2])
        self.assertNotIn("~", worktree_call)
        self.assertIn(f"'-C' '{self.RESOLVED_HOME}/quantivly/hub'", worktree_call)

    def test_a_failed_unit_start_records_no_started_row_and_removes_the_worktree(self):
        # DO-652 task-7 dispatch correction 7: the brief's own row here is hollow. FakeRunner
        # matches by argv PREFIX, first match wins, and its response for "the failing call" ended
        # with the literal element "cat > " — which never equals the generated command string
        # "cat > '/o/d/brief.md'", so it never matched; every ssh call fell through to the bare
        # ["ssh"] response instead, and the WORKTREE call (not the unit start) failed first. A
        # SequencedRunner replaces it: success for resolve/worktree/brief, failure only on the
        # unit start — the exact call this row claims to be testing.
        #
        # Fix round 2, Important 1: a worktree created in the fetch+worktree call and orphaned by
        # this failure is invisible to every rabota command from then on (census/reap both work
        # from lane rows), so the LAST call here is best-effort cleanup. DO-657 adds the
        # origin/HEAD resolution ahead of it, so the failure path is now six calls, not five —
        # resolve, resolve-default-branch, fetch+worktree, brief, the failing unit start, cleanup.
        ok = Result(0, self.RESOLVE_OUT, "")
        branch = Result(0, "main", "")
        runner = SequencedRunner([ok, branch, ok, ok, Result(1, "", "Failed to start")])
        ctx = self.ctx(runner)
        with self.assertRaises(errors.RabotaError):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])
        self.assertEqual(len(runner.calls), 6)
        cleanup = " ".join(runner.calls[5])
        self.assertIn("'remove'", cleanup); self.assertIn("'--force'", cleanup)

    def test_a_failed_brief_send_removes_the_orphaned_worktree_and_still_raises(self):
        # Fix round 2, Important 1: the SAME cleanup, on the OTHER failure path (brief send
        # fails rather than unit start) — and the ORIGINAL error (RabotaError from send_brief)
        # must still be what's raised, never masked by a cleanup outcome. DO-657: resolve,
        # resolve-default-branch and fetch+worktree must all succeed before the brief send is
        # even attempted, so this is five calls, not three.
        runner = SequencedRunner([Result(0, self.RESOLVE_OUT, ""), Result(0, "main", ""),
                                  Result(0, "", ""), Result(1, "", "no space left on device")])
        ctx = self.ctx(runner)
        with self.assertRaises(errors.RabotaError):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])
        self.assertEqual(len(runner.calls), 5)
        cleanup = " ".join(runner.calls[4])
        self.assertIn("'remove'", cleanup); self.assertIn("'--force'", cleanup)

    # ---- DO-711: the rules reach the lane, or nothing starts -----------------------------

    def test_a_missing_rules_source_refuses_before_anything_is_created(self):
        """The budget is not spent, no ssh is made, no worktree exists and no row is written —
        the same "refuse before you create" ordering `run_recipe` already promises for the gate.
        A lane that would have to run without its rails must cost nothing to refuse."""
        runner = SequencedRunner([])
        ctx = self.ctx(runner)
        gate = []
        with patch.object(lanes_brief, "RULES", Path("/nonexistent/_common-rules.md")):
            with self.assertRaises(errors.Refused):
                lane.run_recipe(ctx, budget_fn=lambda **kw: gate.append(kw) or self.ok_budget(),
                                **self.kw(run=True))
        self.assertEqual(runner.calls, [])
        self.assertEqual(gate, [], "the budget gate must not be consulted for a lane that cannot start")
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])

    def test_a_brief_that_breaks_the_contract_is_refused_before_the_budget_gate(self):
        """`brief.validate` existed, required `## Common rules`, and was called from NOTHING but
        the tests — which is how both shipped briefs came to name a path that exists on no machine
        a lane runs on. This row is the wiring."""
        bad = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, bad, ignore_errors=True)
        f = bad / "brief.md"; f.write_text("# Title only\n")
        runner = SequencedRunner([])
        gate = []
        with self.assertRaises(errors.Usage) as cm:
            lane.run_recipe(self.ctx(runner), budget_fn=lambda **kw: gate.append(kw) or self.ok_budget(),
                            **self.kw(run=True, brief=str(f)))
        self.assertIn("## Common rules", str(cm.exception))
        self.assertEqual(runner.calls, [])
        self.assertEqual(gate, [])

    def test_a_brief_naming_a_laptop_only_rules_path_is_refused_at_dispatch(self):
        """The DO-711 defect itself, at the door it came through."""
        bad = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, bad, ignore_errors=True)
        f = bad / "brief.md"
        f.write_text(self.BRIEF_TEXT.replace(
            "Read `_common-rules.md`, beside this brief.",
            "Read /home/zvi/quantivly/handoffs/rabota/_common-rules.md."))
        with self.assertRaisesRegex(errors.Usage, "/home/zvi/quantivly"):
            lane.run_recipe(self.ctx(SequencedRunner([])),
                            budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True, brief=str(f)))

    # ---- DO-712: the lane's PATH --------------------------------------------------------

    def test_a_remote_lane_prepends_the_machines_local_bin_to_its_own_path(self):
        """Measured on dev 2026-09-24: systemd 249's user manager PATH has no `~/.local/bin`, so
        `rabota version` inside a lane exited 127 although `~/.local/bin/rabota` was right there.
        The value is built from the PATH the machine ITSELF reported, so `/snap/bin` and anything
        else that machine has survives — a hardcoded list would silently drop them."""
        runner = FakeRunner([(["ssh"], Result(0, self.RESOLVE_OUT, ""))])
        out = lane.run_recipe(self.ctx(runner), budget_fn=lambda **_: self.ok_budget(), **self.kw())
        want = f"--setenv=PATH={self.RESOLVED_HOME}/.local/bin:{self.RESOLVED_PATH}"
        self.assertIn(f"'{want}'", out["shell"])
        # The prepend, not a replacement: the machine's own entries are still there, after.
        self.assertNotIn(f"--setenv=PATH={self.RESOLVED_HOME}/.local/bin'", out["shell"])

    def test_a_local_recipe_sets_no_path_at_all(self):
        """The paired half. `build_local` omits the flag when it has no proven value, exactly as
        it omits `CLAUDE_CONFIG_DIR` — never emitted empty, never guessed. Only the machine the
        argv will run on can say what its PATH is, and for a local lane nothing has asked it."""
        argv = self.argv()
        self.assertEqual([a for a in argv if a.startswith("--setenv=PATH")], [])


class EvaluateRecipeTests(LocalRecipeTests):
    """DO-670: ``--kind evaluate --of <lane_id>``. Reuses ``LocalRecipeTests.ctx()`` only — the
    inherited ``argv()``-based rows exist to exercise ``build_local`` directly and have nothing to
    do with the evaluate form, so (unlike ``RemoteRecipeTests`` et al.) this class does not
    subclass ``RunRecipeTests`` and rerun its whole work-lane suite a second time.
    """

    OF_ID = "of000001"
    MAX_VERDICT = 4096   # config.LaneDefaults.max_verdict_bytes; the fixture config does not override it
    VALID_VERDICT = {"lane": OF_ID, "status": "done",
                      "claims": [{"id": "c1", "text": "t",
                                  "evidence": {"cmd": "true", "expected": "0", "observed": "0"},
                                  "confidence": "high"}],
                      "deliverables": [], "followups": []}

    # A path on DEV. It must NOT exist on the box running these tests: the bug this class now
    # pins (DO-670 review) was a local Path.exists() against a remote out_dir, which every real
    # dev lane failed and every test passed — because the fixture paired machine="dev" with a
    # local tmpdir, so the file was there. A remote verdict is reached over ssh or not at all.
    REMOTE_OUT_ROOT = "/home/ubuntu/.local/state/rabota/out/quantivly"

    def of_out_dir(self):
        p = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, p, ignore_errors=True)
        return p

    def verdict_response(self, payload=None, *, raw=None):
        """What `head -c` on the evaluated lane's machine returns for a readable verdict."""
        return Result(0, raw if raw is not None else json.dumps(payload or self.VALID_VERDICT), "")

    NO_VERDICT = Result(1, "", "head: cannot open '.../verdict.json' for reading: No such file")

    def insert_of_lane(self, ctx, *, machine="dev", kind="work", out_dir=None, lane_id=None,
                       tenant="quantivly"):
        lane_id = lane_id or self.OF_ID
        if out_dir is None:
            out_dir = self.of_out_dir() if machine == "local" else f"{self.REMOTE_OUT_ROOT}/{lane_id}"
        ctx.store.insert_lane({
            "id": lane_id, "tenant": tenant, "kind": kind, "brief": "/b/brief.md",
            "repo": "hub", "worktree": "/w/t", "out_dir": str(out_dir), "machine": machine,
            "unit": f"rabota-lane-quantivly-{lane_id}.service", "session_id": "sess-of",
            "model": "claude-sonnet-5", "effort": "medium", "status": "done",
            "started_at": "2026-09-20T00:00:00Z",
        })
        return lane_id, out_dir

    def write_verdict(self, out_dir, payload=None, *, raw=None):
        p = Path(out_dir) / "verdict.json"
        p.write_text(raw if raw is not None else json.dumps(payload or self.VALID_VERDICT))
        return p

    def kw(self, **over):
        base = dict(brief=None, repo="hub", machine=None, base=None, seat=None,
                    model="claude-fable-5-1", effort="medium", est_minutes=30, run=False,
                    kind="evaluate", of=self.OF_ID)
        base.update(over); return base

    def ok_budget(self):
        return {"allowed_new_lanes": 2, "reasons": [], "seat_pick": "quantivly-0", "five_h_pct_now": 42}

    RESOLVE_OUT = framed(path="/usr/local/bin:/usr/bin:/bin")

    def test_an_unknown_of_lane_refuses(self):
        ctx = self.ctx(FakeRunner([]))
        with self.assertRaisesRegex(errors.Refused, "nosuchlane"):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(of="nosuchlane"))

    def test_of_without_kind_evaluate_is_a_usage_error(self):
        ctx = self.ctx(FakeRunner([]))
        self.insert_of_lane(ctx)
        with self.assertRaises(errors.Usage):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                            **self.kw(kind="work", brief="/b/brief.md"))

    def test_kind_evaluate_without_of_is_a_usage_error(self):
        ctx = self.ctx(FakeRunner([]))
        with self.assertRaises(errors.Usage):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(of=None))

    def test_a_brief_with_kind_evaluate_is_a_usage_error(self):
        # The template IS the brief (DO-670 assignment step 3) — a caller passing both means
        # something contradictory, not a preference to be silently overridden.
        ctx = self.ctx(FakeRunner([]))
        self.insert_of_lane(ctx)
        with self.assertRaises(errors.Usage):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(brief="/b/other.md"))

    def test_a_missing_verdict_refuses(self):
        runner = SequencedRunner([self.NO_VERDICT])
        ctx = self.ctx(runner)
        of_id, out_dir = self.insert_of_lane(ctx)
        with self.assertRaisesRegex(errors.Refused, of_id):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))

    def test_an_oversized_verdict_refuses(self):
        ctx = self.ctx(SequencedRunner([self.verdict_response(
            raw="x" * (self.MAX_VERDICT + 1))]))
        self.insert_of_lane(ctx)
        with self.assertRaisesRegex(errors.Refused, "bytes"):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))

    def test_an_invalid_verdict_shape_refuses(self):
        ctx = self.ctx(SequencedRunner([self.verdict_response(raw='{"lane": "x"}')]))
        self.insert_of_lane(ctx)
        with self.assertRaisesRegex(errors.Refused, "missing keys"):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))

    def test_the_verdict_is_read_from_the_evaluated_lanes_machine(self):
        """The row that would have caught the original defect: the verdict is fetched over ssh,
        bounded at the source, from the path on the machine that wrote it."""
        runner = SequencedRunner([self.verdict_response()] + [Result(0, self.RESOLVE_OUT, "")] * 4)
        ctx = self.ctx(runner)
        of_id, out_dir = self.insert_of_lane(ctx)
        lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                        **self.kw(run=True, base="origin/main"))
        first = " ".join(runner.calls[0])
        self.assertIn("ssh", first)
        self.assertIn(f"{out_dir}/verdict.json", first)
        self.assertIn(str(self.MAX_VERDICT + 1), first)   # head -c bounds it at the source

    def test_a_dry_render_still_refuses_a_missing_remote_verdict(self):
        """The dry form checks it too. `resolve_remote` already ssh's on this path to resolve the
        claude binary, so there is no quiet to preserve — and rendering a recipe for a verdict
        that is not there would print a command guaranteed to fail."""
        ctx = self.ctx(SequencedRunner([self.NO_VERDICT]))
        of_id, _ = self.insert_of_lane(ctx)
        with self.assertRaisesRegex(errors.Refused, of_id):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=False))

    def test_a_local_evaluated_lanes_verdict_is_read_on_this_machine(self):
        """The local path still validates from the filesystem, with no ssh at all."""
        runner = FakeRunner([])
        ctx = self.ctx(runner)
        _, out_dir = self.insert_of_lane(ctx, machine="local")
        self.write_verdict(out_dir, raw='{"lane": "x"}')
        with self.assertRaisesRegex(errors.Refused, "missing keys"):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=False))
        self.assertEqual(runner.calls, [])

    def test_an_of_lane_from_another_tenant_refuses(self):
        ctx = self.ctx(FakeRunner([]))
        self.insert_of_lane(ctx, tenant="toysim")
        with self.assertRaisesRegex(errors.Refused, "toysim"):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))

    def test_a_disagreeing_machine_refuses_before_touching_anything(self):
        runner = FakeRunner([])
        ctx = self.ctx(runner)
        self.insert_of_lane(ctx, machine="dev")
        # No verdict is staged at all: this refusal must land BEFORE anything reads one.
        with self.assertRaisesRegex(errors.Refused, "same machine"):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(machine="local"))
        self.assertEqual(runner.calls, [])

    def test_an_evaluate_lane_of_an_evaluate_lane_refuses(self):
        # Decision (DO-670): an evaluate lane may not itself be evaluated — see run_recipe's
        # docstring for why. This is the row that pins the decision.
        ctx = self.ctx(FakeRunner([]))
        self.insert_of_lane(ctx, kind="evaluate")
        with self.assertRaisesRegex(errors.Refused, "itself an evaluate lane"):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw())

    def test_the_rendered_brief_is_the_templates_output(self):
        ok = Result(0, self.RESOLVE_OUT, "")
        runner = SequencedRunner([self.verdict_response(), ok, ok, ok, ok])
        ctx = self.ctx(runner)
        _, out_dir = self.insert_of_lane(ctx)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                              **self.kw(run=True, base="origin/main"))
        sent = runner.inputs[3]  # verdict read, resolve, fetch+worktree, brief send, unit start
        of_lane = dict(ctx.store.get_lane(self.OF_ID))
        # The evaluate lane runs on dev and can only open the brief COPY in the evaluated lane's
        # out_dir — never the laptop path the original --brief named.
        of_lane["brief"] = f"{out_dir}/brief.md"
        expected = lanes_brief.render_evaluate(of_lane, Path(out_dir) / "verdict.json", out["out_dir"])
        self.assertEqual(sent, expected)
        self.assertIn(f"{out_dir}/brief.md", sent)
        self.assertNotIn("/b/brief.md", sent)

    def test_the_row_carries_kind_evaluate_and_of_lane(self):
        ok = Result(0, self.RESOLVE_OUT, "")
        runner = SequencedRunner([self.verdict_response(), ok, ok, ok, ok])
        ctx = self.ctx(runner)
        _, out_dir = self.insert_of_lane(ctx)
        lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                        **self.kw(run=True, base="origin/main"))
        rows = ctx.store.list_lanes("quantivly")
        new_row = next(r for r in rows if r["id"] != self.OF_ID)
        self.assertEqual(new_row["kind"], "evaluate")
        self.assertEqual(new_row["of_lane"], self.OF_ID)

    def test_the_machine_is_inherited_from_the_evaluated_lane_when_not_given(self):
        ok = Result(0, self.RESOLVE_OUT, "")
        runner = SequencedRunner([self.verdict_response(), ok, ok, ok, ok])
        ctx = self.ctx(runner)
        _, out_dir = self.insert_of_lane(ctx, machine="dev")
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                              **self.kw(run=True, base="origin/main", machine=None))
        self.assertEqual(out["machine"], "dev")

    def test_a_machine_agreeing_with_the_evaluated_lane_is_harmless(self):
        ok = Result(0, self.RESOLVE_OUT, "")
        runner = SequencedRunner([self.verdict_response(), ok, ok, ok, ok])
        ctx = self.ctx(runner)
        _, out_dir = self.insert_of_lane(ctx, machine="dev")
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(),
                              **self.kw(run=True, base="origin/main", machine="dev"))
        self.assertEqual(out["machine"], "dev")


class EvaluateModelDefaultTests(LocalRecipeTests):
    """DO-670 step 6: an evaluate lane defaults to ``ctx.tenant.lanes.evaluate_model``, not
    ``default_model`` — asserted at the ``_run`` (CLI-argument-defaulting) layer, since
    ``run_recipe`` itself always takes an already-resolved ``model``.
    """

    def ns(self, **over):
        base = dict(brief=None, repo="hub", machine=None, base=None, seat=None, model=None,
                    effort=None, est_minutes=30, run=False, kind="evaluate", of="of1",
                    text=False, tenant="quantivly", state_dir=None, dry_run=False)
        base.update(over)
        return argparse.Namespace(**base)

    def call(self, ns):
        # Never a real tenant state_dir (finding F23) — the fixture's own state_dir is
        # home-relative, so an explicit tempdir is pinned here even though run_recipe (which
        # would actually open the store) is patched out below and never touches it.
        captured = {}
        def fake_run_recipe(ctx, **kw):
            captured.update(kw)
            return {"unit": "u", "shell": "s"}
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns.state_dir = tmp.name
        with patch.object(lane, "run_recipe", fake_run_recipe):
            lane._run(ns, cfg_base=FIX / "config", runner=FakeRunner([]),
                      env={"PATH": "/bin"}, cwd=Path("/"))
        return captured

    def test_the_evaluate_model_default_applies_when_no_model_is_given(self):
        captured = self.call(self.ns())
        self.assertEqual(captured["model"], "claude-fable-5-1")

    def test_an_explicit_model_still_overrides_the_evaluate_default(self):
        captured = self.call(self.ns(model="claude-opus-5"))
        self.assertEqual(captured["model"], "claude-opus-5")

    def test_a_work_lane_still_defaults_to_default_model_not_evaluate_model(self):
        captured = self.call(self.ns(kind="work", of=None, brief="/b/brief.md"))
        self.assertEqual(captured["model"], "claude-sonnet-5")


class MachineArgvCliTests(unittest.TestCase):
    """Finding 4 (final whole-branch review): ``--machine`` used to hardcode
    ``choices=["local", "dev"]`` in ``lane._build``, while the declared source of truth is the
    tenant config and ``run_recipe`` already validates against it and raises a named
    ``errors.Refused``. Under the hardcoded choices, an undeclared machine name never reached
    that check at all — argparse itself refused it first, as a plain usage error (exit 2)
    rather than the informative, named refusal (exit 3). This exercises the real argv parser
    (``cli.main``), not ``run_recipe`` directly, because the defect lived in the parser layer.
    """

    def setUp(self):
        install_fixture_home(self)
        self.brief = self.home / "brief.md"
        # Contract-shaped since DO-711 wired `lanes.brief.validate` into the dispatch path: a
        # two-word stub would now be refused as a USAGE error (exit 2) before the machine name is
        # ever looked at, which is the very confusion this row exists to detect.
        self.brief.write_text(RunRecipeTests.BRIEF_TEXT)

    def test_an_undeclared_machine_is_a_named_refusal_not_an_argparse_usage_error(self):
        code, out, err = run_cli(["--tenant", "quantivly", "lane", "recipe",
                                  "--brief", str(self.brief), "--repo", "hub",
                                  "--machine", "nosuchmachine"])
        self.assertEqual(code, 3, err)
        payload = last_json(err)
        self.assertEqual(payload["error"]["code"], "refused")
        self.assertIn("nosuchmachine", payload["error"]["message"])

    def test_the_empty_machine_usage_guard_is_reachable_from_argv(self):
        # Finding 4 also names a second casualty of the hardcoded choices: run_recipe's own
        # empty-machine errors.Usage guard (see test_an_empty_machine_is_rejected_rather_than_
        # written_to_a_row above) was unreachable from real argv, since choices=[...] rejected
        # "" before run_recipe ever saw it. This proves it is reachable now.
        code, out, err = run_cli(["--tenant", "quantivly", "lane", "recipe",
                                  "--brief", str(self.brief), "--repo", "hub",
                                  "--machine", ""])
        self.assertEqual(code, 2, err)
        self.assertEqual(last_json(err)["error"]["code"], "usage")


class RunDryRunHelpTextTests(unittest.TestCase):
    """DO-743: the issue asks for the ``--run``/``--dry-run`` collision to be resolved in the
    help text, naming which one wins. This is the one row that reads the actual argparse help
    string rather than trusting the docstring/commit-message claim that it says so."""

    def test_the_run_flags_help_names_dry_run_as_the_winner(self):
        from rabota import cli
        parser = cli.build_parser()
        sub = next(a for a in parser._subparsers._group_actions if a.dest == "command")
        lane_parser = sub.choices["lane"]
        lane_sub = next(a for a in lane_parser._subparsers._group_actions if a.dest == "lane_cmd")
        recipe_parser = lane_sub.choices["recipe"]
        run_action = next(a for a in recipe_parser._actions if a.dest == "run")
        self.assertIn("--dry-run", run_action.help)
        self.assertIn("overrides", run_action.help)
