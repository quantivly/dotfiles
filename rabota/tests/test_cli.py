import io, json, os, unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch
from rabota import cli, errors

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
