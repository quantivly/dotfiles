import sqlite3, tempfile, unittest
from pathlib import Path
from rabota import errors
from rabota.store import Store, SCHEMA_VERSION

class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store.open(Path(self.tmp.name) / "handoffs" / "rabota")

    def tearDown(self):
        self.store.close(); self.tmp.cleanup()

    def test_creates_db_and_version(self):
        self.assertTrue((Path(self.tmp.name) / "handoffs" / "rabota" / "rabota.db").exists())
        self.assertEqual(self.store.schema_version(), SCHEMA_VERSION)

    def test_lane_roundtrip_and_update(self):
        self.store.insert_lane({"id": "l1", "tenant": "quantivly", "kind": "work", "brief": "/b.md",
                                "repo": "/r", "worktree": "/w", "out_dir": "/o", "machine": "local",
                                "unit": "rabota-lane-l1", "session_id": "s", "model": "m",
                                "status": "running", "started_at": "2026-09-16T08:00:00Z"})
        self.store.update_lane("l1", status="done", ended_at="2026-09-16T09:00:00Z")
        lane = self.store.get_lane("l1")
        self.assertEqual((lane["status"], lane["attached"]), ("done", 0))
        self.assertEqual([l["id"] for l in self.store.list_lanes(status="done")], ["l1"])
        with self.assertRaises(ValueError):
            self.store.update_lane("l1", bogus=1)

    def test_escalation_first_seen_is_immutable(self):
        eid = self.store.add_escalation("quantivly", "merge?", "evidence", ["yes", "no"], first_seen="2026-09-03T00:00:00Z")
        self.store.answer_escalation(eid, "yes")
        self.assertEqual(self.store.open_escalations("quantivly"), [])
        row = self.store.escalation(eid)
        self.assertEqual((row["first_seen"], row["disposition"], row["options"]), ("2026-09-03T00:00:00Z", "yes", ["yes", "no"]))

    def test_decisions_keep_prior_for_rollback(self):
        self.store.record_decision("b1", "quantivly", "auto", "dead_issue", "notification", "n1",
                                   "archive", {"archivedAt": None})
        self.store.mark_verified("b1", "n1")
        d = self.store.decisions("b1")[0]
        self.assertEqual((d["prior"]["archivedAt"], d["verified"]), (None, 1))
        self.store.mark_rolled_back("b1")
        self.assertIsNotNone(self.store.decisions("b1")[0]["rolled_back_at"])

    def test_gate_records_label_not_person(self):
        self.store.record_gate("quantivly", "post reply HUB-6247", "approved")
        self.assertEqual(self.store.gates("quantivly")[0]["label"], "approved")

    def test_sync_and_pins(self):
        self.store.record_sync("quantivly", "linear", True, None, "/s/linear.json")
        self.assertTrue(self.store.last_sync("quantivly", "linear")["ok"])
        self.store.set_pin("quantivly", "HUB-1", 1, "spoken promise")
        self.assertEqual(self.store.pins("quantivly")[0]["bucket"], 1)
        self.store.clear_pin("quantivly", "HUB-1")
        self.assertEqual(self.store.pins("quantivly"), [])

    def test_newer_on_disk_schema_is_refused_and_left_alone(self):
        # A DB written by a future rabota: this code cannot know its semantics, so it must not write.
        self.store.conn.execute("UPDATE schema_version SET version=?", (SCHEMA_VERSION + 1,))
        self.store.close()
        state_dir = Path(self.tmp.name) / "handoffs" / "rabota"
        with self.assertRaises(errors.Refused) as cm:
            Store.open(state_dir)
        self.assertIn(str(SCHEMA_VERSION + 1), str(cm.exception))
        self.assertIn(str(SCHEMA_VERSION), str(cm.exception))
        conn = sqlite3.connect(state_dir / "rabota.db")
        self.assertEqual(conn.execute("SELECT version FROM schema_version").fetchall(), [(SCHEMA_VERSION + 1,)])
        conn.close()
        self.store = Store(sqlite3.connect(":memory:"))   # tearDown closes something

    def test_older_on_disk_schema_opens_without_restamping(self):
        # No migration steps exist yet, so an old version is reported (by doctor), never silently bumped.
        self.store.conn.execute("UPDATE schema_version SET version=0")
        self.store.close()
        self.store = Store.open(Path(self.tmp.name) / "handoffs" / "rabota")
        self.assertEqual(self.store.schema_version(), 0)
