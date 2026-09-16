import argparse, tempfile, unittest
from pathlib import Path
from rabota import context
from rabota.commands import doctor
from rabota.runner import FakeRunner, Result

FIX = Path(__file__).parent / "fixtures" / "config"

class DoctorTests(unittest.TestCase):
    def make_ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="toysim", state_dir=str(Path(tmp.name) / "state"), text=False, dry_run=False, command="doctor")
        return context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))

    def test_reports_ok_when_links_and_timer_fine(self):
        runner = FakeRunner([
            (["readlink", "-f"], Result(0, str(Path.home() / ".dotfiles/scripts/rabota") + "\n", "")),
            (["systemctl", "--user", "is-enabled", "rabota-precompute.timer"], Result(0, "enabled\n", "")),
        ])
        report = doctor.run_doctor(self.make_ctx(runner))
        self.assertEqual(report["tenant"], "toysim")
        self.assertEqual(report["db_schema"], 1)
        self.assertTrue(report["ok"], report["problems"])

    def test_missing_timer_is_a_problem_not_a_crash(self):
        runner = FakeRunner([
            (["readlink", "-f"], Result(0, str(Path.home() / ".dotfiles/scripts/rabota") + "\n", "")),
            (["systemctl", "--user", "is-enabled", "rabota-precompute.timer"], Result(1, "", "Failed to get unit file state")),
        ])
        report = doctor.run_doctor(self.make_ctx(runner))
        self.assertFalse(report["ok"])
        self.assertTrue(any("timer" in p for p in report["problems"]))
