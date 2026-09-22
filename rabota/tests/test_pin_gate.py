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

    def test_missing_required_flag_is_usage_error(self):
        # argparse itself raises ``SystemExit(2)`` for a required subcommand argument on this
        # interpreter — a subparser's ``error()`` is never routed through ``cli.py``'s
        # ``parser.error`` override, so missing ``--file`` on ``ingest`` behaves the same way.
        with self.assertRaises(SystemExit) as cm:
            run_cli(["--tenant", "quantivly", "pin", "HUB-1", "--rationale", "why"])
        self.assertEqual(cm.exception.code, 2)

    def test_bad_bucket_refuses_rather_than_coercing(self):
        with self.assertRaises(SystemExit) as cm:
            run_cli(["--tenant", "quantivly", "pin", "HUB-1", "--bucket", "not-an-int", "--rationale", "why"])
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

    def test_gate_missing_required_flag_is_usage_error(self):
        with self.assertRaises(SystemExit) as cm:
            run_cli(["--tenant", "quantivly", "gate", "--label", "approved"])
        self.assertEqual(cm.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
