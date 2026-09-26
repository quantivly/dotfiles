import sqlite3, tempfile, unittest
from unittest import mock
from pathlib import Path
from rabota import errors
from rabota.store import Store, SCHEMA_VERSION
from tests.support import connection_is_closed

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

    def test_pins_version_bumps_on_set_and_on_clear_never_from_another_tenant(self):
        # DO-738: `rank` needs a real "did the pins table change" signal. A row's own `ts` cannot
        # be it -- `clear_pin` deletes the row, so `MAX(ts)` over what is left is unchanged unless
        # the deleted row happened to hold the max, which a real caller has no way to arrange or
        # even know. `pins_version` is a counter bumped on every mutation, set OR clear, so it is
        # true of the change itself rather than merely correlated with it.
        self.assertEqual(self.store.pins_version("quantivly"), 0)
        self.store.set_pin("quantivly", "HUB-1", 1, "spoken promise")
        v1 = self.store.pins_version("quantivly")
        self.assertGreater(v1, 0)
        self.store.set_pin("quantivly", "HUB-2", 2, "another promise")
        v2 = self.store.pins_version("quantivly")
        self.assertGreater(v2, v1)
        # Deleting the OLDER row (never the max-ts one) is exactly the case a `ts`-derived
        # aggregate misses: MAX(ts) over the surviving row is unchanged, but the table did change.
        self.store.clear_pin("quantivly", "HUB-1")
        v3 = self.store.pins_version("quantivly")
        self.assertGreater(v3, v2)
        # A second tenant's pins are a wholly separate counter, starting fresh at 0.
        self.assertEqual(self.store.pins_version("toysim"), 0)
        self.store.set_pin("toysim", "T-1", 1, "promise")
        self.assertEqual(self.store.pins_version("quantivly"), v3, "an unrelated tenant's pin bumped this one")

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

    def test_migrate_v1_to_v2_adds_columns_and_restamps(self):
        from rabota.store import Store, SCHEMA_VERSION
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        db = Path(tmp.name) / "rabota.db"
        conn = sqlite3.connect(db, isolation_level=None)
        conn.executescript("""CREATE TABLE schema_version(version INTEGER NOT NULL); INSERT INTO schema_version VALUES (1);
            CREATE TABLE lanes(id TEXT PRIMARY KEY, tenant TEXT, kind TEXT, brief TEXT, repo TEXT, worktree TEXT, out_dir TEXT,
              machine TEXT, unit TEXT, session_id TEXT, model TEXT, status TEXT, started_at TEXT, ended_at TEXT, held_reason TEXT,
              of_lane TEXT, attached INTEGER DEFAULT 0);
            CREATE TABLE escalations(id INTEGER PRIMARY KEY, tenant TEXT, first_seen TEXT NOT NULL, ts TEXT, question TEXT,
              evidence TEXT, options TEXT, disposition TEXT, resolved_at TEXT, resolution TEXT);"""); conn.close()
        s = Store.open(Path(tmp.name))
        self.assertEqual(s.schema_version(), SCHEMA_VERSION)
        cols = {r[1] for r in s.conn.execute("PRAGMA table_info(lanes)")}
        self.assertTrue({"seat", "effort", "cost_usd", "five_h_pct_at_start", "five_h_pct_at_end", "abandoned_at"} <= cols)
        ecols = {r[1] for r in s.conn.execute("PRAGMA table_info(escalations)")}
        self.assertTrue({"kind", "subject"} <= ecols)
        s.close()
        s2 = Store.open(Path(tmp.name)); self.assertEqual(s2.schema_version(), 2)   # idempotent
        eid = s2.add_escalation("quantivly", "q", "e", ["a"], kind="decision", subject="PR #1")
        self.assertEqual((s2.escalation(eid)["kind"], s2.escalation(eid)["subject"]), ("decision", "PR #1"))
        s2.close()


class StoreOpenFailurePathTests(unittest.TestCase):
    """``Store.open`` must not leak the connection it just opened when a later step fails.

    Counted by recording every connection ``sqlite3.connect`` hands out, never by
    ``ResourceWarning``; see ``support.connection_is_closed``.
    """

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.state_dir = Path(tmp.name) / "state"
        self.opened, self.factory = [], None
        real_connect = sqlite3.connect

        def recording_connect(*args, **kwargs):
            if self.factory is not None:
                kwargs["factory"] = self.factory
            conn = real_connect(*args, **kwargs)
            self.opened.append(conn)
            return conn
        patcher = mock.patch("sqlite3.connect", recording_connect)
        patcher.start(); self.addCleanup(patcher.stop)
        self.addCleanup(lambda: [c.close() for c in self.opened])   # never leak from the test itself

    def unclosed(self):
        return [c for c in self.opened if not connection_is_closed(c)]

    def test_success_path_returns_a_usable_store_over_one_open_connection(self):
        store = Store.open(self.state_dir)
        self.assertEqual(store.schema_version(), SCHEMA_VERSION)
        self.assertEqual(len(self.opened), 1)
        self.assertEqual(len(self.unclosed()), 1)   # open() hands the connection to the caller
        store.close()
        self.assertEqual(self.unclosed(), [])

    def test_a_refused_migration_closes_the_connection_and_keeps_its_message(self):
        # A real newer-schema database, so the refusal is the production one, not a mock's.
        store = Store.open(self.state_dir)
        store.conn.execute("UPDATE schema_version SET version=?", (SCHEMA_VERSION + 1,))
        store.close()
        with self.assertRaises(errors.Refused) as cm:
            Store.open(self.state_dir)
        self.assertIn(f"schema is {SCHEMA_VERSION + 1}, newer than this rabota's {SCHEMA_VERSION}", str(cm.exception))
        self.assertEqual(len(self.opened), 2)
        self.assertEqual(self.unclosed(), [])

    def test_a_failing_pragma_closes_the_connection_and_keeps_its_exception(self):
        class PragmaRefusing(sqlite3.Connection):
            def execute(self, sql, *args):
                if sql.startswith("PRAGMA"):
                    raise sqlite3.OperationalError("pragma refused")
                return super().execute(sql, *args)
        self.factory = PragmaRefusing
        with self.assertRaises(sqlite3.OperationalError) as cm:
            Store.open(self.state_dir)
        self.assertEqual(str(cm.exception), "pragma refused")   # not wrapped, not replaced by a close error
        self.assertEqual(len(self.opened), 1)
        self.assertEqual(self.unclosed(), [])
