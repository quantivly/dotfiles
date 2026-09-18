import argparse, json, tempfile, unittest
from datetime import date, datetime, timedelta, timezone
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

    def test_freshness_uses_the_real_clock_not_ctx_today(self):
        # b6: the old line built "now" from ctx.today (a date) + the UTC clock's time-of-day, so a
        # mismatch between the two flipped freshness by ~24h in either direction. Both directions must
        # come out right regardless of what ctx.today says.
        real_now = datetime.now(timezone.utc)
        utc_today = real_now.date()
        for ctx_today in (utc_today - timedelta(days=1), utc_today + timedelta(days=1)):
            ctx = self.ctx()
            ctx.today = ctx_today
            lin = snapshots.read(ctx.state_dir, "linear")

            lin["fetched_at"] = (real_now - timedelta(minutes=30)).strftime(snapshots.FETCHED_AT_FORMAT)
            (ctx.state_dir / "sources" / "linear.json").write_text(json.dumps(lin))
            cmd._fresh_linear(ctx, allow_stale=False)  # 30 min old must be accepted as fresh

            lin["fetched_at"] = (real_now - timedelta(hours=20)).strftime(snapshots.FETCHED_AT_FORMAT)
            (ctx.state_dir / "sources" / "linear.json").write_text(json.dumps(lin))
            with self.assertRaises(errors.Refused):
                cmd._fresh_linear(ctx, allow_stale=False)  # 20 h old must be refused

    def test_malformed_fetched_at_refuses_not_crashes(self):
        ctx = self.ctx()
        for bad in (None, "not-a-date", ""):
            lin = snapshots.read(ctx.state_dir, "linear"); lin["fetched_at"] = bad
            (ctx.state_dir / "sources" / "linear.json").write_text(json.dumps(lin))
            with self.assertRaises(errors.Refused):
                cmd.run_plan(ctx)

        lin = snapshots.read(ctx.state_dir, "linear"); del lin["fetched_at"]
        (ctx.state_dir / "sources" / "linear.json").write_text(json.dumps(lin))
        with self.assertRaises(errors.Refused):
            cmd.run_plan(ctx)

    def test_dry_run_apply_needs_no_credentials(self):
        ctx = self.ctx(); cmd.run_plan(ctx)  # ctx.env carries no Linear key
        rep = cmd.run_apply(ctx, tier="auto", batch=None, confirmed=False, dry_run=True)
        self.assertIn("would_archive", rep)

    def test_dry_run_due_policy_needs_no_credentials(self):
        ctx = self.ctx(); cmd.run_plan(ctx)
        rep = cmd.run_apply(ctx, tier="propose", batch="due_policy", confirmed=True, dry_run=True)
        self.assertIn("would_clear", rep)
