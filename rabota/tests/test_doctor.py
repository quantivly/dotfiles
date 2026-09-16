import argparse, json, os, shutil, subprocess, sys, tempfile, unittest
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


class DoctorEndToEndTests(unittest.TestCase):
    """The real CLI, real subprocess children: a child that prints a protected value must not
    get that value onto either of rabota's streams (the WS1 review gate's reproduced leak)."""

    def test_child_output_carrying_a_protected_value_never_reaches_either_stream(self):
        canary = "lin_api_" + "canary" + "0123456789"   # assembled at runtime; not a real key
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        home = Path(tmp.name) / "home"
        shutil.copytree(FIX, home / ".dotfiles-local" / "rabota")
        fakebin = Path(tmp.name) / "bin"; fakebin.mkdir()
        fake = fakebin / "systemctl"
        fake.write_text(f"#!{sys.executable}\nimport os, sys\n"
                        "sys.stdout.write(os.environ.get('LINEAR_API_KEY', '') + '\\n')\n")
        fake.chmod(0o755)
        env = {"HOME": str(home), "PATH": f"{fakebin}:/usr/bin:/bin", "LINEAR_API_KEY": canary}
        p = subprocess.run([sys.executable, "-m", "rabota", "--tenant", "quantivly",
                            "--state-dir", str(Path(tmp.name) / "state"), "doctor"],
                           cwd=Path(__file__).resolve().parents[1], env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertNotIn(canary, p.stdout)
        self.assertNotIn(canary, p.stderr)
        self.assertEqual(p.returncode, 5, p.stderr)
        self.assertEqual(json.loads(p.stderr)["error"]["code"], "secret_leak")
        self.assertIn("LINEAR_API_KEY", p.stderr)
        self.assertNotIn("Traceback", p.stderr)
