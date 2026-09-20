import argparse, json, shutil, tempfile, unittest
from pathlib import Path
from rabota import context, errors
from rabota.commands import lane
from rabota.runner import FakeRunner, Result

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
        kwargs = dict(seat="quantivly-1", repo="hub", worktree="/w/t", out_dir="/o/d",
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
        argv = lane.build_local(ctx, seat="quantivly-1", repo="hub", worktree="/w/t",
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
        local = lane.build_local(ctx, seat="quantivly-0", repo="hub", worktree="/w/t", out_dir="/o/d",
                                 brief="/o/d/brief.md", model="claude-sonnet-5", effort="medium",
                                 unit="rabota-lane-x.service")
        return lane.build_remote(ctx, ctx.tenant.machines["dev"], local)

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
        local = lane.build_local(ctx, seat="quantivly-0", repo="hub", worktree="/w/t", out_dir="/o/d",
                                 brief="=ls", model="claude-sonnet-5", effort="medium",
                                 unit="rabota-lane-x.service")
        self.assertIn("'Read =ls and execute.'", lane.build_remote(ctx, ctx.tenant.machines["dev"], local)[-1])

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
        ctx = self.ctx(FakeRunner([]))
        local = lane.build_local(ctx, seat="quantivly-0", repo="hub", worktree="/w/t", out_dir="/o/d",
                                 brief="/o/d/brief.md", model="claude-sonnet-5", effort="medium",
                                 unit="rabota-lane-x.service", config_dir="/home/ubuntu/.claude",
                                 claude_bin="/home/ubuntu/.local/bin/claude")
        cmd = lane.build_remote(ctx, ctx.tenant.machines["dev"], local)[-1]
        self.assertIn("'--setenv=CLAUDE_CONFIG_DIR=/home/ubuntu/.claude'", cmd)
        self.assertNotIn(str(Path.home()), cmd)


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

    def test_it_returns_home_and_the_claude_binary(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(
            0, "/home/ubuntu\n/home/ubuntu/.local/bin/claude", ""))]))
        self.assertEqual(lane.resolve_remote(ctx, ctx.tenant.machines["dev"]),
                         {"home": "/home/ubuntu", "claude_bin": "/home/ubuntu/.local/bin/claude"})

    def test_a_failed_ssh_refuses_rather_than_guessing(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(255, "", "no route"))]))
        with self.assertRaises(errors.Refused):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_a_reply_missing_the_claude_line_refuses(self):
        # A successful ssh that finds no executable claude prints nothing for that field (the
        # script's own `[ -x "$p" ] &&` guard) — not room for a fallback, an unmeasured machine.
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, "/home/ubuntu", ""))]))
        with self.assertRaises(errors.Refused):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_an_empty_reply_refuses(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, "", ""))]))
        with self.assertRaises(errors.Refused):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])

    def test_a_relative_home_refuses(self):
        # A first line not starting with "/" cannot be the proof this resolver promises; refuse
        # rather than trust an unexpected shell reply verbatim.
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, "home\n/home/ubuntu/.local/bin/claude", ""))]))
        with self.assertRaises(errors.Refused):
            lane.resolve_remote(ctx, ctx.tenant.machines["dev"])


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
    BRIEF_TEXT = "# Brief\nDo the thing.\n"

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
    # Fix round 5: resolve_remote no longer resolves or proves an account dir (nothing consumes
    # one for a remote lane any more), so its reply is back to two lines.
    RESOLVE_OUT = f"{RESOLVED_HOME}\n{RESOLVED_BIN}"

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
        runner = FakeRunner([(["ssh"], Result(0, self.RESOLVE_OUT, ""))])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw())
        self.assertNotIn("CLAUDE_CONFIG_DIR", out["shell"])
        self.assertNotIn(str(Path.home()), out["shell"])

    def test_a_dry_recipe_records_no_row(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, self.RESOLVE_OUT, ""))]))
        lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw())
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
        # DO-652 task-7 dispatch correction 6: a remote --run makes FOUR runner calls
        # (resolve, worktree, brief, unit), not three — the brief's own count is stale.
        # SequencedRunner (not FakeRunner) so ``.inputs`` is available for the brief-content check.
        ok = Result(0, self.RESOLVE_OUT, "")
        runner = SequencedRunner([ok, ok, ok, ok])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        joined = [" ".join(c) for c in runner.calls]
        self.assertEqual(len(runner.calls), 4)
        # Fix round 2, Critical 1: out_dir is created (mkdir -p) in the SAME call as the worktree
        # add, so the call count stays four — a shell `>` redirection does not create parent
        # directories, and systemd-run returns 0 once the transient unit is CREATED, so a missing
        # out_dir would otherwise fail invisibly AFTER a "started" row was already written.
        self.assertIn("'mkdir'", joined[1]); self.assertIn("'-p'", joined[1])
        self.assertIn(f"'{out['out_dir']}'", joined[1])
        # DO-652 task-7 dispatch, an additional bug found in the brief's own row (same class as
        # its already-flagged correction 7): once every argv element is POSIX single-quoted, a
        # phrase spanning two elements ("git -C", "worktree add") is never a contiguous substring
        # of the joined command — only a check against ONE quoted element survives shquote.
        self.assertIn("'git'", joined[1]); self.assertIn("'worktree'", joined[1]); self.assertIn("'add'", joined[1])
        self.assertIn("cat > ", joined[2])
        self.assertIn("systemd-run", joined[3])
        # Mutation 7: the resolved bin (not the locally-expanded config default) must be what
        # actually starts the unit.
        self.assertIn(self.RESOLVED_BIN, joined[3])
        # Fix round 2, Important 2: the brief's CONTENT (not just its path) must actually reach
        # call #3 — neither FakeRunner nor the old SequencedRunner recorded `input=`, so a
        # mutation that emptied the brief before sending it survived the whole suite.
        self.assertEqual(runner.inputs[2], self.BRIEF_TEXT)
        # ...and the path used to SEND the brief must be the exact path the agent is told to READ.
        remote_brief_path = f"{out['out_dir']}/brief.md"
        self.assertIn(f"cat > '{remote_brief_path}'", joined[2])
        self.assertIn(f"'Read {remote_brief_path} and execute.'", joined[3])
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

    def test_remote_paths_use_the_resolved_home_never_a_literal_tilde(self):
        # DO-652 task-7 fix round 1: the dev fixture's state_dir and repos.hub are both
        # ~-prefixed ("~/.local/state/rabota", "~/quantivly/hub" —
        # tests/fixtures/config/tenants/quantivly.toml, unchanged; it already matches the live
        # config's shape). build_remote single-quotes every argv element and POSIX single quotes
        # suppress tilde expansion, so a "~" sent as-is becomes a literal directory named "~" on
        # the remote. This proves the RESOLVED $HOME is what actually reaches both the returned
        # paths and the `git -C` argv, not the raw config value.
        ok = Result(0, self.RESOLVE_OUT, "")
        runner = SequencedRunner([ok, ok, ok, ok])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        self.assertNotIn("~", out["worktree"])
        self.assertNotIn("~", out["out_dir"])
        self.assertTrue(out["worktree"].startswith(self.RESOLVED_HOME + "/"), out["worktree"])
        self.assertTrue(out["out_dir"].startswith(self.RESOLVED_HOME + "/"), out["out_dir"])
        worktree_call = " ".join(runner.calls[1])
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
        # Fix round 2, Important 1: a worktree created in call #2 and orphaned by this failure is
        # invisible to every rabota command from then on (census/reap both work from lane rows),
        # so the fifth call here is best-effort cleanup — the call count is five, not four, and
        # that is the correct, INTENDED count for this exact failure path (a review round asked
        # for out_dir's mkdir to keep the SUCCESS-path count at four, which it does; it did not
        # ask for a failure path to skip cleanup just to keep matching that number).
        ok = Result(0, self.RESOLVE_OUT, "")
        runner = SequencedRunner([ok, ok, ok, Result(1, "", "Failed to start")])
        ctx = self.ctx(runner)
        with self.assertRaises(errors.RabotaError):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])
        self.assertEqual(len(runner.calls), 5)
        cleanup = " ".join(runner.calls[4])
        self.assertIn("'remove'", cleanup); self.assertIn("'--force'", cleanup)

    def test_a_failed_brief_send_removes_the_orphaned_worktree_and_still_raises(self):
        # Fix round 2, Important 1: the SAME cleanup, on the OTHER failure path (brief send,
        # call #3, rather than unit start, call #4) — and the ORIGINAL error (RabotaError from
        # send_brief) must still be what's raised, never masked by a cleanup outcome.
        runner = SequencedRunner([Result(0, self.RESOLVE_OUT, ""), Result(0, "", ""),
                                  Result(1, "", "no space left on device")])
        ctx = self.ctx(runner)
        with self.assertRaises(errors.RabotaError):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])
        self.assertEqual(len(runner.calls), 4)
        cleanup = " ".join(runner.calls[3])
        self.assertIn("'remove'", cleanup); self.assertIn("'--force'", cleanup)
