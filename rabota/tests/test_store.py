import tempfile, unittest
from pathlib import Path
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
