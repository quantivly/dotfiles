import argparse, json, tempfile, unittest
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
        return context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner,
                                              env={"PATH": "/bin"}, cwd=Path("/"))

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
        return self.ctx(FakeRunner([])).tenant.lanes.claude_bin

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
        self.assertIn("--setenv=CLAUDE_CONFIG_DIR=" + str(Path.home() / ".claude-quantivly-1"), self.argv())

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
