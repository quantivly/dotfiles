import argparse, tempfile, unittest
from datetime import date
from pathlib import Path

from rabota import cli, context
from rabota.commands import gate as gate_cmd
from rabota.commands import pin as pin_cmd
from rabota.runner import FakeRunner
from tests.test_cli import run_cli

FIX = Path(__file__).parent / "fixtures" / "config"


class PinGateCmdTests(unittest.TestCase):
    def setUp(self):
        # The usage-error rows below drive `run_cli` and are safe ONLY while argparse rejects
        # before `Context.from_namespace` runs. Remove that guard and they write rabota.db into
        # the tenant's CONFIGURED state dir — the real one (finding F23, DO-680a review, which
        # measured exactly that). A fixture $HOME makes them safe by construction instead.
        from tests.test_cli import install_fixture_home
        install_fixture_home(self)

    def ctx(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"},
                                              cwd=Path("/"), today=date(2026, 9, 16))
        self.addCleanup(ctx.close)
        return ctx

    # pin

    def test_pin_happy_path_persists_bucket_and_rationale(self):
        ctx = self.ctx()
        out = pin_cmd.run_pin(ctx, "HUB-1", 2, "promised Thursday")
        self.assertEqual(out["item_key"], "HUB-1")
        self.assertEqual(out["bucket"], 2)
        self.assertEqual(out["rationale"], "promised Thursday")
        row = ctx.store.pins("quantivly")[0]
        self.assertEqual(row["item_key"], "HUB-1")
        self.assertEqual(row["bucket"], 2)
        self.assertEqual(row["rationale"], "promised Thursday")

    def test_rerunning_same_key_upserts_rather_than_duplicating(self):
        ctx = self.ctx()
        pin_cmd.run_pin(ctx, "HUB-1", 2, "first rationale")
        pin_cmd.run_pin(ctx, "HUB-1", 3, "revised rationale")
        rows = ctx.store.pins("quantivly")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["bucket"], 3)
        self.assertEqual(rows[0]["rationale"], "revised rationale")

    def test_dry_run_pin_writes_no_row(self):
        ctx = self.ctx(); ctx.dry_run = True
        out = pin_cmd.run_pin(ctx, "HUB-1", 2, "promised Thursday")
        self.assertEqual(ctx.store.pins("quantivly"), [])
        self.assertEqual(out["dry_run"], "nothing written (pins row)")

    def test_missing_required_flag_is_usage_error(self):
        # argparse itself raises ``SystemExit(2)`` for a required subcommand argument on this
        # interpreter — a subparser's ``error()`` is never routed through ``cli.py``'s
        # ``parser.error`` override, so missing ``--file`` on ``ingest`` behaves the same way.
        with self.assertRaises(SystemExit) as cm:
            run_cli(["--tenant", "quantivly", "--state-dir", str(self.home / "s"),
                     "pin", "HUB-1", "--rationale", "why"])
        self.assertEqual(cm.exception.code, 2)

    def test_bad_bucket_refuses_rather_than_coercing(self):
        with self.assertRaises(SystemExit) as cm:
            run_cli(["--tenant", "quantivly", "--state-dir", str(self.home / "s"),
                     "pin", "HUB-1", "--bucket", "not-an-int", "--rationale", "why"])
        self.assertEqual(cm.exception.code, 2)

    # gate

    def test_gate_happy_path_persists_subject_and_label(self):
        ctx = self.ctx()
        out = gate_cmd.run_gate(ctx, "post reply HUB-6247", "approved")
        self.assertEqual(out["subject"], "post reply HUB-6247")
        self.assertEqual(out["label"], "approved")
        row = ctx.store.gates("quantivly")[0]
        self.assertEqual(row["subject"], "post reply HUB-6247")
        self.assertEqual(row["label"], "approved")

    def test_gate_record_carries_no_identity(self):
        ctx = self.ctx()
        gate_cmd.run_gate(ctx, "merge PR 42", "go ahead")
        row = ctx.store.gates("quantivly")[0]
        self.assertEqual(set(row.keys()), {"id", "tenant", "ts", "subject", "label"})

    def test_rerunning_same_gate_records_a_second_answer(self):
        ctx = self.ctx()
        gate_cmd.run_gate(ctx, "merge PR 42", "go ahead")
        gate_cmd.run_gate(ctx, "merge PR 42", "go ahead")
        rows = ctx.store.gates("quantivly")
        self.assertEqual(len(rows), 2)
        self.assertEqual([r["label"] for r in rows], ["go ahead", "go ahead"])

    def test_dry_run_gate_writes_no_row(self):
        ctx = self.ctx(); ctx.dry_run = True
        out = gate_cmd.run_gate(ctx, "merge PR 42", "go ahead")
        self.assertEqual(ctx.store.gates("quantivly"), [])
        self.assertEqual(out["dry_run"], "nothing written (gate_answers row)")

    def test_gate_missing_required_flag_is_usage_error(self):
        with self.assertRaises(SystemExit) as cm:
            run_cli(["--tenant", "quantivly", "gate", "--label", "approved"])
        self.assertEqual(cm.exception.code, 2)


if __name__ == "__main__":
    unittest.main()


class PinGateCliWiringTests(unittest.TestCase):
    """The registration line and the argparse -> run_* dispatch, which the rows above cannot see.

    Those rows call ``run_pin``/``run_gate`` directly and import the command modules, which
    registers them regardless of ``cli.COMMAND_MODULES`` — so deleting both names from that list
    left the whole suite green while the CLI answered ``invalid choice: 'pin'`` (DO-680a review).
    Hardcoding ``bucket=2`` in ``pin._run``, or swapping subject and label in ``gate._run``,
    survived just as quietly. These drive ``cli.main``, the only path a user takes.
    """

    def setUp(self):
        from tests.test_cli import install_fixture_home
        install_fixture_home(self)
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.state = str(Path(tmp.name))

    def run_cli(self, *args):
        """``(code, parsed)`` — both streams, since a refusal prints to stderr, and a strict
        interpreter may print a warning ahead of the JSON."""
        import contextlib, io, json as _json, re as _re
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["--tenant", "quantivly", "--state-dir", self.state, *args])
        raw = out.getvalue() + err.getvalue()
        m = _re.search(r"\{[\s\S]*\}", raw)
        return code, (_json.loads(m.group(0)) if m else raw)

    def test_the_command_modules_entry_is_what_registers_them(self):
        """A SUBPROCESS, deliberately — this is the only row that can see the registration line.

        Every in-process row imports ``rabota.commands.pin``/``gate``, and importing a command
        module calls ``cli.register`` on it, so the subcommand exists whether or not
        ``cli.COMMAND_MODULES`` names it. Dropping both names left all 571 tests green while
        ``rabota pin`` answered ``invalid choice`` (DO-680a review). A fresh interpreter imports
        only what ``_load_command_modules`` walks, which is the thing under test.
        """
        import os, subprocess, sys
        for cmd in ("pin", "gate"):
            with self.subTest(cmd=cmd):
                r = subprocess.run([sys.executable, "-m", "rabota", "--tenant", "quantivly",
                                    "--state-dir", self.state, cmd, "--help"],
                                   capture_output=True, text=True,
                                   cwd=str(Path(__file__).resolve().parents[1]),
                                   env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1])})
                self.assertEqual(r.returncode, 0, f"{cmd}: {r.stderr[:200]}")
                self.assertNotIn("invalid choice", r.stderr)

    def test_pin_is_registered_and_its_flags_reach_the_command(self):
        """The dispatch: hardcode `bucket=2` in `pin._run` and this row is what fails."""
        code, body = self.run_cli("pin", "ENG-7", "--bucket", "2", "--rationale", "promised Thursday")
        self.assertEqual(code, 0)
        self.assertEqual((body["item_key"], body["bucket"], body["rationale"]),
                         ("ENG-7", 2, "promised Thursday"))

    def test_gate_is_registered_and_subject_and_label_are_not_swapped(self):
        code, body = self.run_cli("gate", "--subject", "merge #202", "--label", "yes")
        self.assertEqual(code, 0)
        self.assertEqual((body["subject"], body["label"]), ("merge #202", "yes"))

    def test_a_bucket_rank_never_reads_is_refused(self):
        """A pin in bucket 3 is stored and never scheduled — a silent no-op, so refuse it."""
        code, body = self.run_cli("pin", "ENG-8", "--bucket", "3", "--rationale", "why")
        self.assertEqual(code, 2)
        self.assertIn("not read by rank", body["error"]["message"])

    def test_empty_values_are_refused(self):
        for args in (("pin", "  ", "--bucket", "2", "--rationale", "why"),
                     ("pin", "ENG-9", "--bucket", "2", "--rationale", "  "),
                     ("gate", "--subject", " ", "--label", "yes"),
                     ("gate", "--subject", "s", "--label", " ")):
            with self.subTest(args=args):
                code, _ = self.run_cli(*args)
                self.assertEqual(code, 2)
