import io, json, os, shutil, tempfile, unittest
from pathlib import Path
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch
from rabota import cli, errors
from rabota.context import Context

FIX = Path(__file__).parent / "fixtures" / "config"

# Assembled at runtime so no literal in this file looks like a credential (see test_secrets.py).
CANARY = "lin_api_" + "canary" + "0123456789"

def run_cli(argv):
    """Run ``cli.main`` with both streams captured; returns ``(code, stdout, stderr)``."""
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = cli.main(argv)
    return code, out.getvalue(), err.getvalue()


class CliTests(unittest.TestCase):
    def run_cli(self, argv):
        return run_cli(argv)

    def test_version_is_json(self):
        code, out, _ = self.run_cli(["version"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["version"], "2.0.0")

    def test_unknown_subcommand_is_usage(self):
        code, _, err = self.run_cli(["nope"])
        self.assertEqual(code, 2)
        self.assertIn("usage", err.lower())

    def test_refused_maps_to_3(self):
        def build(sub):
            sub.add_parser("boom")
        def run(ns):
            raise errors.Refused("identity not pinned")
        cli.register("boom", build, run)
        code, _, err = self.run_cli(["boom"])
        self.assertEqual(code, 3)
        self.assertEqual(json.loads(err)["error"]["code"], "refused")
        self.assertIn("identity not pinned", err)

    def test_text_flag_uses_text_out(self):
        def build(sub):
            sub.add_parser("lines")
        def run(ns):
            return ["a", "b"]
        cli.register("lines", build, run)
        code, out, _ = self.run_cli(["--text", "lines"])
        self.assertEqual(out, "a\nb\n")


class SecretGuardTests(unittest.TestCase):
    """Every string that leaves the process is checked against the real environment."""

    def _register(self, name, run):
        cli.register(name, lambda sub: sub.add_parser(name), run)

    def run_cli(self, argv):
        return run_cli(argv)

    def test_payload_with_protected_value_raises_not_prints(self):
        self._register("leaky", lambda ns: {"header": "Authorization: " + CANARY})
        with patch.dict(os.environ, {"LINEAR_API_KEY": CANARY}):
            code, out, err = self.run_cli(["leaky"])
        self.assertEqual(code, 5)
        self.assertEqual(out, "")                       # nothing partial reached stdout
        self.assertEqual(json.loads(err)["error"]["code"], "secret_leak")
        self.assertIn("LINEAR_API_KEY", err)            # the NAME is what the operator needs
        self.assertNotIn(CANARY, out + err)

    def test_text_payload_is_guarded_too(self):
        self._register("leakytext", lambda ns: ["fine", "bad " + CANARY])
        with patch.dict(os.environ, {"SLACK_TOKEN": CANARY}):
            code, out, err = self.run_cli(["--text", "leakytext"])
        self.assertEqual(code, 5)
        self.assertEqual(out, "")
        self.assertNotIn(CANARY, out + err)

    def test_error_message_carrying_a_protected_value_is_guarded(self):
        def run(ns):
            raise errors.Refused("bad key " + CANARY)
        self._register("leakyerr", run)
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": CANARY}):
            code, out, err = self.run_cli(["leakyerr"])
        self.assertEqual(code, 5)
        self.assertEqual(json.loads(err)["error"]["code"], "secret_leak")
        self.assertIn("ANTHROPIC_API_KEY", err)
        self.assertNotIn(CANARY, out + err)

    def test_partial_failed_list_is_guarded(self):
        def run(ns):
            raise errors.Partial("some failed", failed=[{"env": CANARY}])
        self._register("leakypartial", run)
        with patch.dict(os.environ, {"LINEAR_API_KEY": CANARY}):
            code, out, err = self.run_cli(["leakypartial"])
        self.assertEqual(code, 5)
        self.assertNotIn(CANARY, out + err)


class ExitCodeTests(unittest.TestCase):
    """Spec C1: nothing escapes as a traceback. Config faults are usage (2); the rest is error (5)."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name) / "home"
        self.base = self.home / ".dotfiles-local" / "rabota"
        shutil.copytree(FIX, self.base)
        home_patch = patch.dict(os.environ, {"HOME": str(self.home)})
        home_patch.start(); self.addCleanup(home_patch.stop)

    def run_cli(self, argv):
        code, out, err = run_cli(argv)
        self.assertNotIn("Traceback", err)
        return code, out, err

    def _usage(self, argv):
        code, out, err = self.run_cli(argv)
        self.assertEqual(code, 2, err)
        self.assertEqual(json.loads(err)["error"]["code"], "usage")
        return err

    def test_malformed_config_toml_is_usage(self):
        (self.base / "config.toml").write_text("default = \n")
        err = self._usage(["--tenant", "quantivly", "doctor"])
        self.assertIn("config.toml", err)

    def test_tenant_toml_missing_root_is_usage(self):
        path = self.base / "tenants" / "toysim.toml"
        path.write_text("\n".join(l for l in path.read_text().splitlines() if not l.startswith("root")) + "\n")
        err = self._usage(["--tenant", "quantivly", "doctor"])
        self.assertIn("toysim.toml", err)
        self.assertIn("root", err)

    def test_route_to_tenant_without_toml_is_usage(self):
        with (self.base / "config.toml").open("a") as f:
            f.write('\n[[route]]\nprefix = "~/ghost"\ntenant = "ghost"\n')
        err = self._usage(["--tenant", "quantivly", "doctor"])
        self.assertIn("ghost", err)
        self.assertIn("config.toml", err)

    def test_default_tenant_without_toml_is_usage(self):
        (self.base / "tenants" / "personal.toml").unlink()
        err = self._usage(["--tenant", "quantivly", "doctor"])
        self.assertIn("personal", err)

    def test_unusable_state_dir_is_error_not_traceback(self):
        def run(ns):
            return {"schema": Context.from_namespace(ns).store.schema_version()}
        cli.register("touchstore", lambda sub: sub.add_parser("touchstore"), run)
        blocker = self.home / "not-a-dir"; blocker.write_text("")
        code, out, err = self.run_cli(["--tenant", "quantivly", "--state-dir", str(blocker / "state"), "touchstore"])
        self.assertEqual(code, 5, err)
        self.assertEqual(json.loads(err)["error"]["code"], "error")
        self.assertIn("state dir", err)

    def test_unexpected_exception_is_error_5(self):
        def run(ns):
            raise ValueError("unknown lane fields {'bogus'}")
        cli.register("valueerror", lambda sub: sub.add_parser("valueerror"), run)
        code, out, err = self.run_cli(["valueerror"])
        self.assertEqual(code, 5)
        self.assertEqual(json.loads(err)["error"]["code"], "error")
        self.assertIn("ValueError", err)
        self.assertEqual(out, "")

    def test_unexpected_exception_message_is_guarded(self):
        def run(ns):
            raise ValueError("bad header " + CANARY)
        cli.register("leakyvalueerror", lambda sub: sub.add_parser("leakyvalueerror"), run)
        with patch.dict(os.environ, {"LINEAR_API_KEY": CANARY}):
            code, out, err = self.run_cli(["leakyvalueerror"])
        self.assertEqual(code, 5)
        self.assertEqual(json.loads(err)["error"]["code"], "secret_leak")
        self.assertNotIn(CANARY, out + err)

    def test_system_exit_and_interrupt_keep_their_own_behaviour(self):
        def exiting(ns):
            raise SystemExit(7)
        def interrupted(ns):
            raise KeyboardInterrupt
        cli.register("sysexit", lambda sub: sub.add_parser("sysexit"), exiting)
        cli.register("interrupt", lambda sub: sub.add_parser("interrupt"), interrupted)
        with self.assertRaises(SystemExit) as cm:
            run_cli(["sysexit"])
        self.assertEqual(cm.exception.code, 7)
        with self.assertRaises(KeyboardInterrupt):
            run_cli(["interrupt"])
