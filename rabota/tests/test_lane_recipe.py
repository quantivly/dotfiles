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


class LocalRecipeTests(unittest.TestCase):
    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        return context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner,
                                              env={"PATH": "/bin"}, cwd=Path("/"))

    def argv(self):
        return lane.build_local(self.ctx(FakeRunner([])), seat="quantivly-1", repo="hub",
                                worktree="/w/t", out_dir="/o/d", brief="/o/d/brief.md",
                                model="claude-sonnet-5", effort="medium", unit="rabota-lane-x.service")

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
