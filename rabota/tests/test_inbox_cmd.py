import argparse, json, tempfile, unittest
from datetime import date
from pathlib import Path
from rabota import context, errors, snapshots
from rabota.commands import inbox as cmd
from rabota.runner import FakeRunner

FIX = Path(__file__).parent / "fixtures"


class InboxCmdTests(unittest.TestCase):
    def ctx(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 9, 16))
        self.addCleanup(ctx.close)
        lin = json.loads((FIX / "inbox" / "linear.json").read_text()); lin["fetched_at"] = None
        snapshots.write(ctx.state_dir, "linear", lin)
        snapshots.write(ctx.state_dir, "github", json.loads((FIX / "inbox" / "github.json").read_text()))
        return ctx

    def test_plan_writes_files(self):
        ctx = self.ctx()
        out = cmd.run_plan(ctx)
        self.assertTrue((ctx.state_dir / "inbox-plan.json").exists())
        self.assertTrue((ctx.state_dir / "inbox-summary.txt").read_text().startswith("inbox:"))
        self.assertEqual(out["totals"]["dead_issue"], 2)

    def test_stale_snapshot_refused(self):
        ctx = self.ctx()
        lin = snapshots.read(ctx.state_dir, "linear"); lin["fetched_at"] = "2026-09-15T00:00:00Z"
        (ctx.state_dir / "sources" / "linear.json").write_text(json.dumps(lin))
        with self.assertRaises(errors.Refused):
            cmd.run_plan(ctx)
        cmd.run_plan(ctx, allow_stale=True)

    def test_propose_without_confirmed_refused(self):
        ctx = self.ctx(); cmd.run_plan(ctx)
        with self.assertRaises(errors.Refused):
            cmd.run_apply(ctx, tier="propose", batch="due_policy", confirmed=False, client=object())
