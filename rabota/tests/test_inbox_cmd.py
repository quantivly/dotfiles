import argparse, json, tempfile, unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from rabota import context, errors, snapshots
from rabota.commands import inbox as cmd
from rabota.runner import FakeRunner
from tests.test_inbox_apply import FakeClient

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

    def test_corrupt_snapshot_is_not_reported_as_a_fetched_at_problem(self):
        # n2: round 1 wrapped the whole snapshots.age_seconds(...) call in
        # `except (KeyError, TypeError, ValueError)` and re-raised as "unusable fetched_at".
        # age_seconds re-reads the snapshot file, and json.JSONDecodeError is a ValueError
        # subclass -- so a snapshot that becomes corrupt on disk between the two reads was
        # reported as a bad fetched_at, naming a value that was never the problem. A valid
        # fetched_at must be accepted even when age_seconds (which re-reads the file) would
        # blow up -- i.e. freshness must be computed from the snapshot dict already in hand,
        # not by re-reading the file and guessing at the failure's cause. A real fetched_at
        # parse failure must still refuse.
        ctx = self.ctx()
        lin = snapshots.read(ctx.state_dir, "linear")
        lin["fetched_at"] = datetime.now(timezone.utc).strftime(snapshots.FETCHED_AT_FORMAT)
        (ctx.state_dir / "sources" / "linear.json").write_text(json.dumps(lin))
        orig = snapshots.age_seconds

        def boom(*a, **k):
            raise json.JSONDecodeError("corrupt snapshot", "", 0)
        snapshots.age_seconds = boom
        try:
            try:
                cmd.run_plan(ctx)  # a corrupt re-read of age_seconds must not surface at all
            except errors.Refused as e:
                self.fail(f"a file-corruption fault must not be relabelled as a fetched_at problem: {e}")
        finally:
            snapshots.age_seconds = orig

        # a genuine bad fetched_at must still refuse
        lin["fetched_at"] = "not-a-date"
        (ctx.state_dir / "sources" / "linear.json").write_text(json.dumps(lin))
        with self.assertRaises(errors.Refused):
            cmd.run_plan(ctx)

    def test_dry_run_apply_needs_no_credentials(self):
        ctx = self.ctx(); cmd.run_plan(ctx)  # ctx.env carries no Linear key
        rep = cmd.run_apply(ctx, tier="auto", batch=None, confirmed=False, dry_run=True)
        self.assertIn("would_archive", rep)

    def test_dry_run_rollback_needs_no_credentials_and_mutates_nothing(self):
        # DO-753 "most urgent": `inbox rollback` used to ignore --dry-run entirely and build a
        # real LinearClient (`ctx.env` here carries none, so that would raise Refused before ever
        # reaching Linear -- proving no client was built at all, not merely that it did nothing).
        ctx = self.ctx(); cmd.run_plan(ctx)
        rep = cmd.run_rollback(ctx, "auto-does-not-exist", dry_run=True)
        self.assertEqual(rep, {"batch_id": "auto-does-not-exist", "would_restore": []})

    def test_dry_run_due_policy_needs_no_credentials(self):
        ctx = self.ctx(); cmd.run_plan(ctx)
        rep = cmd.run_apply(ctx, tier="propose", batch="due_policy", confirmed=True, dry_run=True)
        self.assertIn("would_clear", rep)

    def test_due_policy_confirmed_must_be_true_at_the_real_entry_point(self):
        # n1: round 1 strengthened apply_due_policy's guard to `confirmed is True`, but run_apply
        # never forwarded the caller's value — it hardcoded confirmed=True below its own truthiness
        # check. A truthy-but-not-True value (e.g. the string "false") sailed through run_apply's
        # `if not confirmed` and then satisfied the strengthened guard it never reached. Test at the
        # entry point WS5 will actually call, not at the helper round 1 tested against directly.
        ctx = self.ctx(); cmd.run_plan(ctx)
        lin = json.loads((FIX / "inbox" / "linear.json").read_text())
        for bad in ("false", "true", 1, 0, None, False):
            client = FakeClient(lin["notifications"], lin["issues"])
            with self.assertRaises(errors.Refused):
                cmd.run_apply(ctx, tier="propose", batch="due_policy", confirmed=bad, client=client)
            self.assertEqual(client.calls, [], f"confirmed={bad!r} must not mutate anything")

        client = FakeClient(lin["notifications"], lin["issues"])
        rep = cmd.run_apply(ctx, tier="propose", batch="due_policy", confirmed=True, client=client)
        self.assertEqual(rep["cleared"], 5)
