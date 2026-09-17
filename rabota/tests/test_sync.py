import argparse, json, tempfile, unittest
from datetime import datetime, timezone
from pathlib import Path
from rabota import context, errors, snapshots
from rabota.commands import sync, ingest
from rabota.runner import FakeRunner

FIX = Path(__file__).parent / "fixtures" / "config"

class FakeLin:
    def viewer(self): return {"id": "v", "name": "z"}
    def assigned_open(self, dead): return [{"id": "i1", "identifier": "HUB-1", "state": {"type": "backlog"}}]
    def created_open(self, me, dead): return [{"id": "i1", "identifier": "HUB-1", "state": {"type": "backlog"}},
                                              {"id": "i2", "identifier": "HUB-2", "state": {"type": "started"}}]
    def inbox_notifications(self): return [{"id": "n1", "type": "issueDue", "issue": {"id": "i1"}}]
    def relations(self, ids): return {"i1": {"blockedBy": ["CORE-1"], "blocks": []}}

class FakeGh:
    login = "work-login"
    def review_requests(self): return [{"repo": "o/r", "number": 1, "requested_individually": True, "via_teams": []}]
    def own_prs(self): return []
    def merged_recent(self, days=30): return []

class BoomGh(FakeGh):
    def review_requests(self): raise errors.RabotaError("gh down")

class SyncTests(unittest.TestCase):
    def ctx(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        return context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))

    def test_sync_writes_snapshots_and_dedupes_issues(self):
        ctx = self.ctx()
        rep = sync.run_sync(ctx, ["linear", "github"], lin=FakeLin(), gh=FakeGh())
        lin = snapshots.read(ctx.state_dir, "linear")
        self.assertEqual([i["identifier"] for i in lin["issues"]], ["HUB-1", "HUB-2"])
        self.assertEqual(lin["issues"][0]["blockedBy"], ["CORE-1"])
        self.assertTrue(lin["ok"]); self.assertIsNone(lin["error"]); self.assertIn("fetched_at", lin)
        self.assertEqual(rep["github"]["counts"]["review_requests"], 1)
        self.assertEqual(rep["linear"]["counts"], {"issues": 2, "notifications": 1})
        self.assertTrue(ctx.store.last_sync("quantivly", "linear")["ok"])
        self.assertEqual(ctx.store.last_sync("quantivly", "github")["path"], rep["github"]["path"])

    def test_partial_failure_keeps_good_snapshot_and_raises_partial(self):
        ctx = self.ctx()
        with self.assertRaises(errors.Partial) as cm:
            sync.run_sync(ctx, ["linear", "github"], lin=FakeLin(), gh=BoomGh())
        self.assertEqual(cm.exception.failed, ["github"])
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "linear"))
        row = ctx.store.last_sync("quantivly", "github")
        self.assertFalse(row["ok"]); self.assertIn("gh down", row["error"])

    def test_unknown_source_is_usage(self):
        with self.assertRaises(errors.Usage):
            sync.run_sync(self.ctx(), ["slack"], lin=FakeLin(), gh=FakeGh())

    def test_ingest_validates_and_writes(self):
        ctx = self.ctx()
        f = ctx.state_dir / "slack.json"; ctx.state_dir.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi", "from": "benoit"}]}))
        rep = ingest.run_ingest(ctx, "slack", f)
        snap = snapshots.read(ctx.state_dir, "slack")
        self.assertEqual(snap["items"][0]["from"], "benoit")
        self.assertEqual((snap["ok"], snap["error"], snap["fetched_at"]), (True, None, "2026-09-16T07:00:00Z"))
        self.assertEqual(rep["items"], 1)
        self.assertTrue(ctx.store.last_sync("quantivly", "slack")["ok"])
        f.write_text("{}")
        with self.assertRaises(errors.Usage):
            ingest.run_ingest(ctx, "slack", f)

    def test_ingest_failed_fetch_records_failure_without_raising(self):
        ctx = self.ctx()
        f = ctx.state_dir / "calendar.json"; ctx.state_dir.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": False, "error": "connector timed out"}))
        rep = ingest.run_ingest(ctx, "calendar", f)
        snap = snapshots.read(ctx.state_dir, "calendar")
        self.assertEqual((snap["ok"], snap["error"], snap["items"]), (False, "connector timed out", []))
        row = ctx.store.last_sync("quantivly", "calendar")
        self.assertEqual((row["ok"], row["error"]), (0, "connector timed out"))
        self.assertFalse(rep["ok"])

    def test_ingest_missing_fetched_at_or_bad_source_or_unreadable_file_is_usage(self):
        ctx = self.ctx(); ctx.state_dir.mkdir(parents=True, exist_ok=True)
        f = ctx.state_dir / "slack.json"
        f.write_text(json.dumps({"ok": True, "items": []}))
        with self.assertRaises(errors.Usage):
            ingest.run_ingest(ctx, "slack", f)
        f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []}))
        with self.assertRaises(errors.Usage):
            ingest.run_ingest(ctx, "linear", f)
        with self.assertRaises(errors.Usage):
            ingest.run_ingest(ctx, "slack", ctx.state_dir / "missing.json")
        f.write_text("not json")
        with self.assertRaises(errors.Usage):
            ingest.run_ingest(ctx, "slack", f)
        f.write_text(json.dumps({"fetched_at": "yesterday", "ok": True, "items": []}))
        with self.assertRaises(errors.Usage):                        # must parse, or age_seconds dies later
            ingest.run_ingest(ctx, "slack", f)

    def test_ingest_ok_must_be_a_json_boolean(self):
        # k5: {"ok": "false"} is a truthy string, so a failed source was recorded as a success and
        # brief stayed silent. A file that cannot state success or failure unambiguously has not
        # stated it: no coercion, every non-boolean is Usage naming the field and the type it got.
        ctx = self.ctx(); ctx.state_dir.mkdir(parents=True, exist_ok=True)
        f = ctx.state_dir / "slack.json"
        for bad, typename in (("false", "str"), ("true", "str"), (1, "int"), (0, "int"), (None, "NoneType")):
            f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": bad, "error": "boom", "items": []}))
            with self.assertRaises(errors.Usage, msg=f"ok={bad!r}") as cm:
                ingest.run_ingest(ctx, "slack", f)
            self.assertIn("'ok'", str(cm.exception)); self.assertIn(typename, str(cm.exception))
        f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "items": []}))      # absent is not "true"
        with self.assertRaises(errors.Usage) as cm:
            ingest.run_ingest(ctx, "slack", f)
        self.assertIn("'ok'", str(cm.exception))
        self.assertIsNone(snapshots.read(ctx.state_dir, "slack"))                          # nothing was recorded
        self.assertIsNone(ctx.store.last_sync("quantivly", "slack"))


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.state = Path(tmp.name)

    def test_write_is_atomic_and_stamps_fetched_at(self):
        path = snapshots.write(self.state, "linear", {"ok": True, "items": []})
        self.assertEqual(path, self.state / "sources" / "linear.json")
        self.assertEqual([p.name for p in path.parent.iterdir()], ["linear.json"])   # no temp file left behind
        snap = snapshots.read(self.state, "linear")
        self.assertRegex(snap["fetched_at"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_write_keeps_a_given_fetched_at(self):
        snapshots.write(self.state, "slack", {"fetched_at": "2026-09-16T07:00:00Z", "items": []})
        self.assertEqual(snapshots.read(self.state, "slack")["fetched_at"], "2026-09-16T07:00:00Z")

    def test_read_and_age_of_missing_snapshot_are_none(self):
        self.assertIsNone(snapshots.read(self.state, "nope"))
        self.assertIsNone(snapshots.age_seconds(self.state, "nope"))

    def test_age_seconds_against_a_given_clock(self):
        snapshots.write(self.state, "github", {"fetched_at": "2026-09-16T07:00:00Z"})
        now = datetime(2026, 9, 16, 7, 30, tzinfo=timezone.utc)
        self.assertEqual(snapshots.age_seconds(self.state, "github", now), 1800.0)
