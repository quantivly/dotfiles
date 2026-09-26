import argparse, json, sqlite3, tempfile, unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path
from rabota import context, errors, secrets, snapshots
from rabota.commands import sync, ingest
from rabota.runner import FakeRunner
from rabota.sources import linear
from tests.test_linear import COPIED, FakePost, Recording, _parse_selection, node_from_selection, tree_paths

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


class FakeFf:
    def recent_transcripts(self, since):
        return [{"id": "t1", "title": "1:1", "date": "2026-09-02",
                 "action_items": [{"speaker": "Zvi Baratz", "item": "Do the thing", "timestamp": "16:52"}]}]


class BoomFf(FakeFf):
    def recent_transcripts(self, since): raise errors.RabotaError("fireflies down")


def db_bytes(state_dir):
    """Every byte sqlite has on disk for rabota.db, WAL included — a fresh reader's view is not enough."""
    return b"".join(p.read_bytes() for p in Path(state_dir).glob("rabota.db*"))

class SyncTests(unittest.TestCase):
    def ctx(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

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

    def test_dry_run_sync_fetches_but_writes_nothing(self):
        # DO-753: the connector read still happens (FakeLin/FakeGh are still invoked and their
        # counts still come back), but neither `sources/*.json` nor a `source_syncs` row lands.
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=True)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        rep = sync.run_sync(ctx, ["linear", "github"], lin=FakeLin(), gh=FakeGh())
        self.assertEqual(rep["linear"]["counts"], {"issues": 2, "notifications": 1})
        self.assertIsNone(snapshots.read(ctx.state_dir, "linear"))
        self.assertIsNone(snapshots.read(ctx.state_dir, "github"))
        self.assertIsNone(ctx.store.last_sync("quantivly", "linear"))
        self.assertIsNone(ctx.store.last_sync("quantivly", "github"))
        self.assertEqual(rep["dry_run"], "nothing written (sources/*.json, source_syncs rows)")

    def test_dry_run_sync_failure_also_records_nothing(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=True)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        with self.assertRaises(errors.Partial):
            sync.run_sync(ctx, ["github"], gh=BoomGh())
        self.assertIsNone(ctx.store.last_sync("quantivly", "github"))

    def test_sync_linear_reads_only_requested_notification_fields_wherever_the_read_happens(self):
        # k7: a read in sync.py is as much a read as one in linear.py. Route generated Recording
        # nodes through a REAL LinearClient into sync_linear and check what was read on the way.
        tree, owners = _parse_selection(linear.NOTIFICATION_FIELDS)
        seen: set[str] = set()
        nodes = [Recording(node_from_selection(tree, tn, owners, id=nid, type=t, archivedAt=None), seen)
                 for nid, t, tn in (("n1", "issueDue", "IssueNotification"), ("n2", "pullRequestApproved", "PullRequestNotification"))]
        empty = {"data": {"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}
        pages = [{"data": {"viewer": {"id": "v", "name": "z"}}}, empty, empty,
                 {"data": {"notifications": {"nodes": nodes, "pageInfo": {"hasNextPage": False, "endCursor": None}}}}]
        ctx = self.ctx()
        # The snapshot write is where the tracked region ENDS: serialising walks the node through
        # items(), which Recording notes as a copy (E-B/E-D). The boundary is explicit — the real
        # writer is wrapped with Recording.plain — so a copy anywhere BEFORE the write still fails.
        real_write = snapshots.write
        with mock.patch.object(snapshots, "write", lambda sd, src, payload, **kw: real_write(sd, src, Recording.plain(payload), **kw)):
            rep = sync.sync_linear(ctx, linear.LinearClient("k" * 20, post=FakePost(pages)))
        self.assertEqual(rep, {"issues": 0, "notifications": 2})
        self.assertFalse([k for k in seen if k.endswith(COPIED)], f"a notification was copied to a plain dict: {sorted(seen)}")
        unrequested = sorted(k for k in seen if k not in tree_paths(tree))
        self.assertFalse(unrequested, f"sync reads notification fields the query never asks for: {unrequested}")
        snap = snapshots.read(ctx.state_dir, "linear")
        self.assertEqual([n["pullRequestUrl"] for n in snap["notifications"]], [None, "<url>"])

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
        conn = sqlite3.connect(ctx.state_dir / "rabota.db"); self.addCleanup(conn.close)
        fresh = conn.execute("SELECT error FROM source_syncs WHERE source='github'").fetchone()[0]
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

    def test_fireflies_is_a_fetched_source(self):
        # DO-746: Fireflies joins linear/github in FETCHED_SOURCES, fetched by `rabota sync` like
        # the other two, with its action_items already parsed into (speaker, item, timestamp).
        self.assertEqual(sync.FETCHED_SOURCES, ("linear", "github", "fireflies"))
        ctx = self.ctx()
        rep = sync.run_sync(ctx, ["linear", "github", "fireflies"], lin=FakeLin(), gh=FakeGh(), ff=FakeFf())
        snap = snapshots.read(ctx.state_dir, "fireflies")
        self.assertTrue(snap["ok"]); self.assertIsNone(snap["error"])
        self.assertEqual(snap["transcripts"][0]["action_items"],
                         [{"speaker": "Zvi Baratz", "item": "Do the thing", "timestamp": "16:52"}])
        self.assertEqual(rep["fireflies"]["counts"], {"transcripts": 1})
        self.assertTrue(ctx.store.last_sync("quantivly", "fireflies")["ok"])

    def test_a_missing_fireflies_key_is_a_recorded_failed_source_not_a_crash(self):
        # Hazard 1 from the brief: there is no Fireflies API key on this machine, so this is the
        # DEFAULT path, not an edge case -- and it must not take `linear`/`github` down with it.
        # `FirefliesClient.from_context` is exercised for real here (no `ff=` override), so a
        # missing `FIREFLIES_API_KEY` in `ctx.env` is what actually triggers the refusal.
        ctx = self.ctx()
        with self.assertRaises(errors.Partial) as cm:
            sync.run_sync(ctx, ["linear", "github", "fireflies"], lin=FakeLin(), gh=FakeGh())
        self.assertEqual(cm.exception.failed, ["fireflies"])
        # the other two sources still synced and are on disk
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "linear"))
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "github"))
        self.assertTrue(ctx.store.last_sync("quantivly", "linear")["ok"])
        row = ctx.store.last_sync("quantivly", "fireflies")
        self.assertFalse(row["ok"])
        self.assertIn("FIREFLIES_API_KEY", row["error"])

    def test_a_fireflies_query_failure_is_recorded_like_any_other_source(self):
        ctx = self.ctx()
        with self.assertRaises(errors.Partial) as cm:
            sync.run_sync(ctx, ["fireflies"], ff=BoomFf())
        self.assertEqual(cm.exception.failed, ["fireflies"])
        row = ctx.store.last_sync("quantivly", "fireflies")
        self.assertFalse(row["ok"]); self.assertIn("fireflies down", row["error"])

    # ---- F2: the fetch window is derived from the last shown brief, not a fixed 2 days ----------

    NOW = datetime(2026, 9, 22, 7, 0, tzinfo=timezone.utc)   # a Monday 07:00Z timer tick

    def _write_last_shown(self, ctx, generated_at):
        ctx.state_dir.mkdir(parents=True, exist_ok=True)
        (ctx.state_dir / snapshots.LAST_SHOWN_FILE).write_text(json.dumps({"generated_at": generated_at}))

    def test_no_last_shown_marker_falls_back_to_the_old_fixed_window(self):
        # Revert `fireflies_since` to always return `now - FIREFLIES_LOOKBACK_MAX_DAYS` (or any
        # value that ignores the missing-marker branch) to see this row fail.
        ctx = self.ctx()
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertEqual(since, self.NOW - timedelta(days=sync.FIREFLIES_LOOKBACK_MIN_DAYS))

    def test_a_friday_shown_brief_still_covers_friday_on_the_monday_tick(self):
        # F2's actual regression: a Monday 07:00 tick that only asked "since Saturday 07:00" (a
        # fixed 2-day lookback) lost Friday afternoon's meetings, because `sync` overwrites the
        # snapshot rather than merging it. Friday's brief was shown at 2026-09-19T16:00:00Z; the
        # derived window must start at or before that, margin included -- unlike the old fixed
        # `now - 2 days`, which lands Saturday morning and misses Friday afternoon entirely.
        ctx = self.ctx()
        self._write_last_shown(ctx, "2026-09-19T16:00:00Z")
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertLessEqual(since, datetime(2026, 9, 19, 16, 0, tzinfo=timezone.utc))
        fixed_two_day_window = self.NOW - timedelta(days=2)
        self.assertLess(since, fixed_two_day_window, "the old fixed 2-day window would still miss Friday")

    def test_the_margin_is_applied_on_top_of_the_last_shown_time(self):
        ctx = self.ctx()
        self._write_last_shown(ctx, "2026-09-21T10:00:00Z")
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertEqual(since, datetime(2026, 9, 21, 10, 0, tzinfo=timezone.utc)
                          - timedelta(hours=sync.FIREFLIES_LOOKBACK_MARGIN_HOURS))

    def test_a_months_old_marker_is_bounded_not_asked_for_a_year(self):
        # Revert the `max(..., earliest)` clamp to see this row fail: a stale marker would then
        # ask Fireflies for months of transcripts on every tick.
        ctx = self.ctx()
        self._write_last_shown(ctx, "2026-01-01T00:00:00Z")
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertEqual(since, self.NOW - timedelta(days=sync.FIREFLIES_LOOKBACK_MAX_DAYS))

    def test_a_malformed_marker_falls_back_like_a_missing_one(self):
        ctx = self.ctx()
        for label, text in (("not json", "{oops"), ("no generated_at", "{}"),
                             ("bad timestamp", '{"generated_at": "not-a-timestamp"}')):
            with self.subTest(label=label):
                ctx.state_dir.mkdir(parents=True, exist_ok=True)
                (ctx.state_dir / snapshots.LAST_SHOWN_FILE).write_text(text)
                since = sync.fireflies_since(ctx, self.NOW)
                self.assertEqual(since, self.NOW - timedelta(days=sync.FIREFLIES_LOOKBACK_MIN_DAYS), label)

    def test_a_marker_ahead_of_now_does_not_push_since_into_the_future(self):
        # Finding C (DO-746 fix round 2): only the lower bound was clamped. A marker ahead of
        # `now` -- multi-machine clock skew, or any `generated_at` written ahead of this call's
        # clock -- pushed `since` past `now`, so the fetch window started in the future and a real
        # unclassified meeting between the true last-shown time and now was never fetched. Revert
        # the `min(since, now)` clamp to see this row fail.
        ctx = self.ctx()
        future = self.NOW + timedelta(days=1)
        self._write_last_shown(ctx, future.isoformat().replace("+00:00", "Z"))
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertLessEqual(since, self.NOW)

    def test_sync_fireflies_actually_uses_the_derived_window(self):
        # Not just `fireflies_since` in isolation -- `sync_fireflies` must pass its result to the
        # client. Revert `sync_fireflies` to its old `datetime.now(...) - timedelta(days=2)` to see
        # this row fail: with "now" being whenever the suite actually runs, a fixed 2-day window
        # lands long after this marker, while the derived window must not.
        ctx = self.ctx()
        self._write_last_shown(ctx, "2026-09-19T16:00:00Z")
        seen = {}

        class RecordingFf(FakeFf):
            def recent_transcripts(self, since):
                seen["since"] = since
                return super().recent_transcripts(since)

        sync.sync_fireflies(ctx, RecordingFf())
        self.assertLessEqual(seen["since"], datetime(2026, 9, 19, 16, 0, tzinfo=timezone.utc))

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

    def test_dry_run_ingest_writes_nothing(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=True)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        f = ctx.state_dir / "slack.json"; ctx.state_dir.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi"}]}))
        rep = ingest.run_ingest(ctx, "slack", f)
        self.assertEqual(rep["items"], 1)                                 # still validated and counted
        self.assertIsNone(snapshots.read(ctx.state_dir, "slack"))         # nothing written
        self.assertIsNone(ctx.store.last_sync("quantivly", "slack"))
        self.assertEqual(rep["dry_run"], "nothing written (sources/<source>.json, source_syncs row)")

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

    # ---- DO-727: multi-source ingest ----------------------------------------------------------

    def _write(self, ctx, name, **fields):
        ctx.state_dir.mkdir(parents=True, exist_ok=True)
        f = ctx.state_dir / f"{name}.json"
        f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", **fields}))
        return f

    def test_ingest_many_one_call_writes_and_records_both(self):
        ctx = self.ctx()
        files = [("slack", self._write(ctx, "slack-in", ok=True, items=[{"text": "hi"}])),
                  ("calendar", self._write(ctx, "calendar-in", ok=True, items=[{"title": "standup"}]))]
        rep = ingest.run_ingest_many(ctx, files)
        self.assertEqual(set(rep), {"slack", "calendar"})
        for source in ("slack", "calendar"):
            self.assertTrue(rep[source]["ok"], source)
            self.assertIsNotNone(snapshots.read(ctx.state_dir, source), source)
            self.assertTrue(ctx.store.last_sync("quantivly", source)["ok"], source)

    def test_fireflies_is_refused_by_ingest_now_that_the_timer_fetches_it(self):
        # F4 from the DO-746 fix-round brief: before this fix, `ingest fireflies --file F` was
        # still accepted and overwrote the timer's `{"transcripts": [...]}` snapshot with ingest's
        # `{"items": [...]}` shape at the same path, with nothing to notice the mismatch. Revert
        # `ALLOWED` to include "fireflies" to see this row fail (both single- and multi-source form
        # go straight through instead of refusing).
        ctx = self.ctx()
        f = self._write(ctx, "fireflies-in", ok=True, items=[{"title": "1:1"}])
        with self.assertRaises(errors.Usage):
            ingest.run_ingest(ctx, "fireflies", f)
        with self.assertRaises(errors.Usage):
            ingest.run_ingest_many(ctx, [("fireflies", f)])
        self.assertNotIn("fireflies", ingest.ALLOWED)

    def test_ingest_many_single_source_form_unchanged(self):
        # The positional/--file single-source call must still return the un-keyed dict, not a
        # {source: ...} wrapper — a contract change here would break every existing caller.
        ctx = self.ctx()
        f = self._write(ctx, "slack-in", ok=True, items=[{"text": "hi"}])
        rep = ingest.run_ingest(ctx, "slack", f)
        self.assertEqual(rep, {"source": "slack", "ok": True, "error": None, "items": 1,
                                "path": str(ctx.state_dir / "sources" / "slack.json")})

    def test_ingest_many_bad_file_among_good_ones_still_writes_the_good_ones(self):
        ctx = self.ctx()
        bad = self._write(ctx, "calendar-in", ok="false")     # k5 shape: truthy string, refused
        files = [("slack", self._write(ctx, "slack-in", ok=True, items=[{"text": "hi"}])),
                  ("calendar", bad)]
        with self.assertRaises(errors.Partial) as cm:
            ingest.run_ingest_many(ctx, files)
        self.assertEqual(cm.exception.failed, ["calendar"])
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "slack"))
        self.assertIsNone(snapshots.read(ctx.state_dir, "calendar"))          # refused file: nothing written
        self.assertIsNone(ctx.store.last_sync("quantivly", "calendar"))       # refused file: nothing recorded
        self.assertTrue(ctx.store.last_sync("quantivly", "slack")["ok"])

    def test_ingest_many_duplicate_source_refused_before_writing_anything(self):
        ctx = self.ctx()
        f1 = self._write(ctx, "slack-in-1", ok=True, items=[{"text": "first"}])
        f2 = self._write(ctx, "slack-in-2", ok=True, items=[{"text": "second"}])
        with self.assertRaises(errors.Usage) as cm:
            ingest.run_ingest_many(ctx, [("slack", f1), ("slack", f2)])
        self.assertIn("slack", str(cm.exception))
        self.assertIsNone(snapshots.read(ctx.state_dir, "slack"))
        self.assertIsNone(ctx.store.last_sync("quantivly", "slack"))

    def test_ingest_many_cli_wiring_source_equals_path(self):
        from tests.test_cli import run_cli, install_fixture_home
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        slack = state / "slack-in.json"; calendar = state / "calendar-in.json"
        slack.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi"}]}))
        calendar.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []}))
        code, out, _ = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest",
                                 "--file", f"slack={slack}", "--file", f"calendar={calendar}"])
        self.assertEqual(code, 0, out)
        body = json.loads(out)
        self.assertTrue(body["slack"]["ok"]); self.assertTrue(body["calendar"]["ok"])

    def test_single_source_form_still_takes_a_path_containing_an_equals_sign(self):
        # Review finding: refusing every single-source `--file` containing `=` (to catch the mixed
        # form) also refused a legal path that happens to contain one, which `main` accepted. The
        # brief's constraint was that this form keep working *unchanged*, and an unusual path is
        # still a path.
        from tests.test_cli import run_cli, install_fixture_home
        install_fixture_home(self)
        state = self.home / "s"; odd = state / "a=b"; odd.mkdir(parents=True)
        slack = odd / "slack-in.json"
        slack.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi"}]}))
        code, out, _ = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest",
                                 "slack", "--file", str(slack)])
        self.assertEqual(code, 0, out)
        self.assertTrue(json.loads(out)["ok"])

    def test_a_source_named_both_ways_is_refused_naming_the_ambiguity(self):
        # The other half of the row above: `ingest slack --file calendar=f.json` names a source
        # twice, and must still be refused -- but for saying so, not for containing an `=`.
        from tests.test_cli import run_cli, install_fixture_home
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        f = state / "calendar-in.json"
        f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []}))
        code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest",
                                   "slack", "--file", f"calendar={f}"])
        self.assertEqual(code, 2, out)
        self.assertIn("names a source twice", out + err)

    def test_repeating_file_with_a_positional_source_is_refused_not_last_wins(self):
        # `main` kept the last `--file` silently; this form now refuses. Untested until now, and an
        # untested refusal is one revert away from becoming last-write-wins again.
        from tests.test_cli import run_cli, install_fixture_home
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        a = state / "a.json"; b = state / "b.json"
        for f in (a, b):
            f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []}))
        code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest",
                                   "slack", "--file", str(a), "--file", str(b)])
        self.assertEqual(code, 2, out)
        self.assertIn("--file", out + err)
        # the behaviour, not the wording: nothing may be ingested from either file
        self.assertIsNone(snapshots.read(state, "slack"))

    def test_a_write_error_on_one_source_still_attempts_the_others(self):
        # Review finding: only `errors.Usage` was caught per source, so an OSError from the
        # snapshot write escaped mid-loop -- the sources after it were never attempted, though
        # their files were already fetched, valid, and independent of the one that blew up.
        ctx = self.ctx()
        files = [("calendar", self._write(ctx, "calendar-in", ok=True, items=[])),
                  ("slack", self._write(ctx, "slack-in", ok=True, items=[{"text": "hi"}]))]
        real = ingest.snapshots.write

        def boom(state_dir, source, payload, **kw):
            if source == "calendar":
                raise OSError("no space left on device")
            return real(state_dir, source, payload, **kw)

        ingest.snapshots.write = boom
        self.addCleanup(lambda: setattr(ingest.snapshots, "write", real))
        with self.assertRaises(errors.Partial) as cm:
            ingest.run_ingest_many(ctx, files)
        self.assertEqual(cm.exception.failed, ["calendar"])
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "slack"))   # attempted despite the blow-up
        self.assertIsNone(snapshots.read(ctx.state_dir, "calendar"))
        # raising discards the report, so the reason has to reach the reader through the message
        self.assertIn("OSError", str(cm.exception))
        self.assertIn("no space left on device", str(cm.exception))

    def test_ingest_cli_single_source_form_unchanged(self):
        from tests.test_cli import run_cli, install_fixture_home
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        slack = state / "slack-in.json"
        slack.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi"}]}))
        code, out, _ = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest",
                                 "slack", "--file", str(slack)])
        self.assertEqual(code, 0, out)
        body = json.loads(out)
        self.assertEqual(body["source"], "slack")
        self.assertTrue(body["ok"])


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

    def test_dry_run_writes_nothing_not_even_the_sources_directory(self):
        path = snapshots.write(self.state, "linear", {"ok": True, "items": []}, dry_run=True)
        self.assertEqual(path, self.state / "sources" / "linear.json")   # the path it WOULD use
        self.assertFalse((self.state / "sources").exists())
        self.assertIsNone(snapshots.read(self.state, "linear"))

    def test_read_and_age_of_missing_snapshot_are_none(self):
        self.assertIsNone(snapshots.read(self.state, "nope"))
        self.assertIsNone(snapshots.age_seconds(self.state, "nope"))

    def test_age_seconds_against_a_given_clock(self):
        snapshots.write(self.state, "github", {"fetched_at": "2026-09-16T07:00:00Z"})
        now = datetime(2026, 9, 16, 7, 30, tzinfo=timezone.utc)
        self.assertEqual(snapshots.age_seconds(self.state, "github", now), 1800.0)
