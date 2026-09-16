import io, json, unittest
from contextlib import redirect_stdout, redirect_stderr
from rabota import cli, errors

class CliTests(unittest.TestCase):
    def run_cli(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = cli.main(argv)
        return code, out.getvalue(), err.getvalue()

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
