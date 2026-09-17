import argparse, json, sqlite3, tempfile, unittest
from datetime import datetime, timezone
from pathlib import Path
from rabota import context, errors, secrets, snapshots
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

MINTED = "minted-gho-token-0123456789abcdef"

class LeakyGh(FakeGh):
    """gh's stderr echoed the minted token; the wrapper folds stderr into the error text."""
    def review_requests(self): raise errors.RabotaError(f"gh api search/issues failed: HTTP 401 — token {MINTED} rejected")


def db_bytes(state_dir):
    """Every byte sqlite has on disk for rabota.db, WAL included — a fresh reader's view is not enough."""
    return b"".join(p.read_bytes() for p in Path(state_dir).glob("rabota.db*"))

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

    def test_registered_value_in_a_gh_error_is_redacted_before_it_reaches_rabota_db(self):
        # k2, the store route: a gh stderr carrying the minted token flows into source_syncs.error.
        # The row must survive — brief reads ok=0 to say "! github failed — list is partial" — so
        # the value is REPLACED with a marker, not refused; refusing would drop the failure record
        # and brief would rank as if github were fine (the k5 shape by another door).
        secrets.register_value(MINTED); self.addCleanup(secrets.REGISTERED_VALUES.discard, MINTED)
        ctx = self.ctx()
        with self.assertRaises(errors.Partial) as cm:
            sync.run_sync(ctx, ["linear", "github"], lin=FakeLin(), gh=LeakyGh())
        self.assertEqual(cm.exception.failed, ["github"])
        row = ctx.store.last_sync("quantivly", "github")
        self.assertEqual(row["ok"], 0)
        self.assertNotIn(MINTED, row["error"])
        self.assertIn("HTTP 401", row["error"]); self.assertIn("[redacted:", row["error"])   # shape kept, value gone
        fresh = sqlite3.connect(ctx.state_dir / "rabota.db").execute("SELECT error FROM source_syncs WHERE source='github'").fetchone()[0]
        self.assertNotIn(MINTED, fresh)
        self.assertFalse(MINTED.encode() in db_bytes(ctx.state_dir), "rabota.db* carries the value in the clear")
        self.assertNotIn(MINTED, str(cm.exception))

    def test_every_store_write_redacts_protected_values(self):
        # "or any other row": every text column a store method writes goes through the same scrub,
        # so the invariant is on rabota.db as a whole, not on one column.
        secrets.register_value(MINTED); self.addCleanup(secrets.REGISTERED_VALUES.discard, MINTED)
        ctx = self.ctx(); st = ctx.store; t = "quantivly"
        st.record_sync(t, "github", False, f"e {MINTED}", "")
        run = st.begin_run(t, f"mode {MINTED}"); st.finish_run(run, True, notes=f"notes {MINTED}")
        st.insert_lane({"id": "L1", "tenant": t, "kind": "work", "brief": f"brief {MINTED}", "status": "running"})
        st.update_lane("L1", held_reason=f"held {MINTED}")
        esc = st.add_escalation(t, f"q {MINTED}", f"ev {MINTED}", [f"opt {MINTED}"])
        st.answer_escalation(esc, f"label {MINTED}", resolution=f"res {MINTED}")
        st.record_gate(t, f"subj {MINTED}", f"label {MINTED}")
        st.record_decision("b1", t, "T1", "reply", "issue", "i1", "archive", {"prior": MINTED})
        st.set_pin(t, "K-1", 2, f"rationale {MINTED}")
        self.assertFalse(MINTED.encode() in db_bytes(ctx.state_dir), "rabota.db* carries the value in the clear")
        self.assertEqual(st.pins(t)[0]["rationale"], "rationale [redacted:minted-token]")
        self.assertEqual(st.get_lane("L1")["held_reason"], "held [redacted:minted-token]")
        self.assertEqual(st.escalation(esc)["options"], ["opt [redacted:minted-token]"])
        self.assertEqual(st.decisions("b1")[0]["prior"], {"prior": "[redacted:minted-token]"})

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
