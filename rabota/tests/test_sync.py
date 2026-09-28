import argparse, json, sqlite3, tempfile, unittest
from unittest import mock
from datetime import datetime, timedelta, timezone
from pathlib import Path
from rabota import context, errors, reconcile, secrets, snapshots, store
from rabota.commands import brief, sync, ingest
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

    # ---- F2/DO-761: the fetch window is derived from what has actually been classified, not a
    # fixed 2 days and not a "shown" marker only `brief` ever wrote --------------------------------

    NOW = datetime(2026, 9, 22, 7, 0, tzinfo=timezone.utc)   # a Monday 07:00Z timer tick

    def _write_classified(self, ctx, classified_at, ids=()):
        ctx.state_dir.mkdir(parents=True, exist_ok=True)
        (ctx.state_dir / snapshots.FIREFLIES_CLASSIFIED_FILE).write_text(
            json.dumps({"ids": list(ids), "classified_at": classified_at}))

    def _write_day_brief(self, ctx, day, generated_at):
        day_dir = ctx.state_dir / day
        day_dir.mkdir(parents=True, exist_ok=True)
        (day_dir / "last-brief.json").write_text(json.dumps({"keys": [], "generated_at": generated_at}))

    def test_no_classification_or_day_brief_falls_back_to_the_old_fixed_window(self):
        # Revert `fireflies_since` to always return `now - FIREFLIES_LOOKBACK_MAX_DAYS` (or any
        # value that ignores the missing-anchor branch) to see this row fail.
        ctx = self.ctx()
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertEqual(since, self.NOW - timedelta(days=sync.FIREFLIES_LOOKBACK_MIN_DAYS))

    def test_a_friday_classification_still_covers_friday_on_the_monday_tick(self):
        # F2's actual regression: a Monday 07:00 tick that only asked "since Saturday 07:00" (a
        # fixed 2-day lookback) lost Friday afternoon's meetings, because `sync` overwrites the
        # snapshot rather than merging it. Fireflies was last classified at 2026-09-19T16:00:00Z;
        # the derived window must start at or before that, margin included -- unlike the old fixed
        # `now - 2 days`, which lands Saturday morning and misses Friday afternoon entirely.
        ctx = self.ctx()
        self._write_classified(ctx, "2026-09-19T16:00:00Z")
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertLessEqual(since, datetime(2026, 9, 19, 16, 0, tzinfo=timezone.utc))
        fixed_two_day_window = self.NOW - timedelta(days=2)
        self.assertLess(since, fixed_two_day_window, "the old fixed 2-day window would still miss Friday")

    def test_the_margin_is_applied_on_top_of_the_last_classified_time(self):
        ctx = self.ctx()
        self._write_classified(ctx, "2026-09-21T10:00:00Z")
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertEqual(since, datetime(2026, 9, 21, 10, 0, tzinfo=timezone.utc)
                          - timedelta(hours=sync.FIREFLIES_LOOKBACK_MARGIN_HOURS))

    def test_a_months_old_classification_is_bounded_not_asked_for_a_year(self):
        # Revert the `max(..., earliest)` clamp to see this row fail: a stale anchor would then
        # ask Fireflies for months of transcripts on every tick.
        ctx = self.ctx()
        self._write_classified(ctx, "2026-01-01T00:00:00Z")
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertEqual(since, self.NOW - timedelta(days=sync.FIREFLIES_LOOKBACK_MAX_DAYS))

    def test_a_malformed_classification_record_falls_back_like_a_missing_one(self):
        ctx = self.ctx()
        for label, text in (("not json", "{oops"), ("no classified_at", "{}"),
                             ("bad timestamp", '{"classified_at": "not-a-timestamp"}')):
            with self.subTest(label=label):
                ctx.state_dir.mkdir(parents=True, exist_ok=True)
                (ctx.state_dir / snapshots.FIREFLIES_CLASSIFIED_FILE).write_text(text)
                since = sync.fireflies_since(ctx, self.NOW)
                self.assertEqual(since, self.NOW - timedelta(days=sync.FIREFLIES_LOOKBACK_MIN_DAYS), label)

    def test_a_classification_ahead_of_now_does_not_push_since_into_the_future(self):
        # Finding C (DO-746 fix round 2): only the lower bound was clamped. An anchor ahead of
        # `now` -- multi-machine clock skew, or any `classified_at` written ahead of this call's
        # clock -- pushed `since` past `now`, so the fetch window started in the future and a real
        # unclassified meeting between the true anchor and now was never fetched. Revert the
        # `min(since, now)` clamp to see this row fail.
        ctx = self.ctx()
        future = self.NOW + timedelta(days=1)
        self._write_classified(ctx, future.isoformat().replace("+00:00", "Z"))
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertLessEqual(since, self.NOW)

    def test_sync_fireflies_actually_uses_the_derived_window(self):
        # Not just `fireflies_since` in isolation -- `sync_fireflies` must pass its result to the
        # client. Revert `sync_fireflies` to its old `datetime.now(...) - timedelta(days=2)` to see
        # this row fail: with "now" being whenever the suite actually runs, a fixed 2-day window
        # lands long after this anchor, while the derived window must not.
        ctx = self.ctx()
        self._write_classified(ctx, "2026-09-19T16:00:00Z")
        seen = {}

        class RecordingFf(FakeFf):
            def recent_transcripts(self, since):
                seen["since"] = since
                return super().recent_transcripts(since)

        sync.sync_fireflies(ctx, RecordingFf())
        self.assertLessEqual(seen["since"], datetime(2026, 9, 19, 16, 0, tzinfo=timezone.utc))

    def test_no_classification_record_falls_back_to_the_newest_day_scoped_last_brief(self):
        # DO-761's own fallback #2: no `fireflies-classified.json` yet, but a day-scoped
        # `last-brief.json` is on disk. The older, no-longer-written `last-brief-shown.json` marker
        # is never involved -- this must work with nothing but the day-scoped file present.
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-19", "2026-09-19T16:00:00Z")
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertLessEqual(since, datetime(2026, 9, 19, 16, 0, tzinfo=timezone.utc))

    def test_the_newest_of_several_day_scoped_briefs_is_used(self):
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-18", "2026-09-18T09:00:00Z")
        self._write_day_brief(ctx, "2026-09-20", "2026-09-20T09:00:00Z")
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertEqual(since, datetime(2026, 9, 20, 9, 0, tzinfo=timezone.utc)
                          - timedelta(hours=sync.FIREFLIES_LOOKBACK_MARGIN_HOURS))

    def test_the_classification_record_takes_priority_over_a_day_scoped_last_brief(self):
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-19", "2026-09-19T16:00:00Z")
        self._write_classified(ctx, "2026-09-21T10:00:00Z")
        since = sync.fireflies_since(ctx, self.NOW)
        self.assertEqual(since, datetime(2026, 9, 21, 10, 0, tzinfo=timezone.utc)
                          - timedelta(hours=sync.FIREFLIES_LOOKBACK_MARGIN_HOURS))

    def test_the_live_do_761_case_no_marker_a_day_scoped_brief_and_a_monday_morning_now(self):
        # The exact regression measured against @zvi's laptop: no `fireflies-classified.json` and
        # no (removed) `last-brief-shown.json`, but the day-scoped `2026-09-25/last-brief.json` was
        # on disk the whole time. A Monday 2026-09-28T04:01:15Z tick asking the OLD fixed
        # `FIREFLIES_LOOKBACK_MIN_DAYS` window would start at 2026-09-26T04:01:15Z, missing the true
        # last-shown time of 2026-09-25T16:42:43Z entirely. Revert either fallback branch in
        # `fireflies_since` to see this row fail.
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-25", "2026-09-25T16:42:43Z")
        now = datetime(2026, 9, 28, 4, 1, 15, tzinfo=timezone.utc)
        since = sync.fireflies_since(ctx, now)
        self.assertLessEqual(since, datetime(2026, 9, 25, 16, 42, 43, tzinfo=timezone.utc))
        old_fixed_window = now - timedelta(days=sync.FIREFLIES_LOOKBACK_MIN_DAYS)
        self.assertLess(since, old_fixed_window,
                        "the old fixed lookback would still miss the true last-shown time")

    def test_the_fallback_anchor_freezes_instead_of_sliding_forward_on_shown(self):
        # Review finding 1 (DO-761 fix round 2): a tenant that only ever gets brief text -- a bare
        # `rabota --text brief`, or an agent that reads turn 1 and never sends `--classified
        # fireflies` back -- never creates `fireflies-classified.json`, so the day-brief fallback
        # used to stay live forever: `read_newest_day_brief` was read live, at call time, on every
        # tick, and a new day-scoped `last-brief.json` landing each day (from the brief simply
        # being shown) walked the window start forward a full day at a time -- the review measured
        # 2026-09-16T09:00Z -> 2026-09-25T09:00Z over ten such days, with no classification record
        # ever created and no alert. `fireflies_since` must now freeze at the FIRST day-brief it
        # ever sees and hold there. Fails on a167822, where `fireflies_since` reads
        # `snapshots.read_newest_day_brief` directly instead of the frozen fallback.
        ctx = self.ctx()
        day0 = datetime(2026, 9, 16, 9, 0, tzinfo=timezone.utc)
        first_since = None
        for i in range(10):
            day = day0 + timedelta(days=i)
            self._write_day_brief(ctx, day.date().isoformat(), day.strftime(snapshots.FETCHED_AT_FORMAT))
            since = sync.fireflies_since(ctx, day + timedelta(hours=1))
            if first_since is None:
                first_since = since
            self.assertEqual(since, first_since,
                             f"day {i}: the fallback anchor must freeze at the first day shown, not slide")
            self.assertFalse((ctx.state_dir / snapshots.FIREFLIES_CLASSIFIED_FILE).exists(),
                             f"day {i}: shown, never classified -- no classification record must ever appear")

    def test_a_write_failure_freezing_the_anchor_does_not_crash_the_caller(self):
        # Review finding 1 (DO-761 fix round 3): `_freeze_fireflies_bootstrap_anchor` called
        # `emit.write_file` with no try/except, and `read_or_freeze_fireflies_fallback_anchor`
        # calls it whenever nothing is frozen yet -- exactly the state a first-ever call to
        # `fireflies_since` is always in. A read-only state dir, a full disk or a permissions
        # fault therefore raised a bare `PermissionError`/`OSError` straight out of a nominal
        # "read" helper, crashing the whole `rabota sync` tick instead of degrading one source.
        # Fails on 4558e23: `fireflies_since` raises instead of returning a value.
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-19", "2026-09-19T16:00:00Z")
        ctx.state_dir.chmod(0o555)
        try:
            since = sync.fireflies_since(ctx, self.NOW)
        finally:
            ctx.state_dir.chmod(0o755)
        self.assertLessEqual(since, datetime(2026, 9, 19, 16, 0, tzinfo=timezone.utc))
        self.assertFalse((ctx.state_dir / snapshots.FIREFLIES_BOOTSTRAP_ANCHOR_FILE).exists(),
                         "a failed write must not leave a partial/phantom anchor file behind")

    def test_a_corrupt_bootstrap_anchor_heals_instead_of_sliding_forever(self):
        # Review finding 2 (DO-761 fix round 3): `_freeze_fireflies_bootstrap_anchor`'s guard used
        # to be `path.exists()` -- existence, not validity -- so a corrupt anchor file (a bad
        # write, or a process killed mid-write) could never be replaced: every call re-derives a
        # fresh, LIVE `read_newest_day_brief` answer it can never persist, silently reconstructing
        # the day-by-day slide this whole mechanism exists to kill, with no error and no alert.
        # Fails on 4558e23: `since` keeps advancing one day at a time forever instead of healing to
        # a fixed value starting the very next call after the corruption is first seen.
        ctx = self.ctx()
        ctx.state_dir.mkdir(parents=True, exist_ok=True)
        (ctx.state_dir / snapshots.FIREFLIES_BOOTSTRAP_ANCHOR_FILE).write_text("{not json")
        day0 = datetime(2026, 9, 16, 9, 0, tzinfo=timezone.utc)
        healed = None
        for i in range(5):
            day = day0 + timedelta(days=i)
            self._write_day_brief(ctx, day.date().isoformat(), day.strftime(snapshots.FETCHED_AT_FORMAT))
            since = sync.fireflies_since(ctx, day + timedelta(hours=1))
            if i == 0:
                healed = since
            else:
                self.assertEqual(since, healed, f"day {i}: the anchor must heal and hold, not keep sliding")
        self.assertIsNotNone(snapshots.read_fireflies_bootstrap_anchor(ctx.state_dir),
                             "the corrupt file must have been replaced by a valid one")

    # ---- DO-768: a PERSISTENT freeze-write fault must be loud, a transient one must stay quiet --

    def test_a_persistent_freeze_failure_is_told_through_the_existing_alert_shape(self):
        # `34d1787`'s `_freeze_fireflies_bootstrap_anchor` swallows the write's `OSError` with a
        # bare `pass` -- right for a ONE-TIME fault (`since` still answers correctly this call,
        # and the next call retries), wrong forever: nothing ever tells an operator the anchor
        # never landed, so every later call re-derives `read_newest_day_brief` live and the
        # window slides a day per day -- the pre-DO-761 behaviour, restored silently. Occupy the
        # anchor's OWN path with a directory, so every write attempt fails the SAME way on EVERY
        # one of several calls -- the persistent case, not a fluke.
        #
        # Fails on 34d1787: `reconcile.snapshot_health` never looks at Fireflies at all there, so
        # `health` stays empty and no `!` line about it ever prints, however many times
        # `fireflies_since` is called -- the exact "no error and no alert" this row exists to catch.
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-19", "2026-09-19T16:00:00Z")
        (ctx.state_dir / snapshots.FIREFLIES_BOOTSTRAP_ANCHOR_FILE).mkdir(parents=True)
        for i in range(3):
            since = sync.fireflies_since(ctx, self.NOW)
            self.assertLessEqual(since, datetime(2026, 9, 19, 16, 0, tzinfo=timezone.utc), f"call {i}")
            self.assertIsNone(snapshots.read_fireflies_bootstrap_anchor(ctx.state_dir),
                             f"call {i}: a directory occupying the path must never read back as a frozen anchor")

        health = reconcile.snapshot_health(ctx, self.NOW)
        fireflies_health = [h for h in health if h["source"] == "fireflies"]
        self.assertEqual(len(fireflies_health), 1,
                         "a freeze failure repeated across several calls must reach snapshot_health")

        lines = brief.terminal_lines({"items": [], "failed_sources": []}, None, None, health=health)
        self.assertTrue(any(l.startswith("! fireflies") for l in lines),
                        f"no `!` line names the stuck freeze: {lines}")

    def test_a_single_transient_freeze_failure_stays_quiet(self):
        # The distinction from the row above: exactly ONE failed attempt, not several in a row,
        # must cost an operator nothing -- the guard's whole point is that a moment's disk hiccup
        # is not an incident, since the very next tick just retries from the same "nothing frozen
        # yet" state. `Store.freeze_fault`/`record_freeze_result` do not exist before this change,
        # so this row does not merely assert an empty `health` (true on 34d1787 for every input,
        # since nothing there ever populates it) -- it asserts the actual streak the fix tracks,
        # which fails outright (`AttributeError`) against 34d1787's `Store`.
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-19", "2026-09-19T16:00:00Z")
        (ctx.state_dir / snapshots.FIREFLIES_BOOTSTRAP_ANCHOR_FILE).mkdir(parents=True)
        sync.fireflies_since(ctx, self.NOW)      # exactly one failed freeze attempt
        fault = ctx.store.freeze_fault("quantivly")
        self.assertIsNotNone(fault)
        self.assertEqual(fault["fails"], 1, "one fluke must count as one, not already read as a streak")
        health = reconcile.snapshot_health(ctx, self.NOW)
        self.assertFalse([h for h in health if h["source"] == "fireflies"],
                         "a single fluke must not reach an operator")

    def test_a_persistent_freeze_fault_does_not_take_down_syncs_other_sources(self):
        # The guard's whole point (`run_sync`'s own docstring: "the ones that succeed are written
        # even when a later one fails") -- a disk problem specific to one small bootstrap-anchor
        # file must not stop Linear, GitHub, or even Fireflies' OWN transcript fetch, from
        # landing. `store.freeze_fault` (absent on 34d1787: `AttributeError`) confirms the fault
        # was actually driven, so this row cannot pass vacuously just because nothing broke.
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-19", "2026-09-19T16:00:00Z")
        (ctx.state_dir / snapshots.FIREFLIES_BOOTSTRAP_ANCHOR_FILE).mkdir(parents=True)
        rep = sync.run_sync(ctx, ["linear", "github", "fireflies"], lin=FakeLin(), gh=FakeGh(), ff=FakeFf())
        self.assertTrue(rep["linear"]["ok"], rep); self.assertTrue(rep["github"]["ok"], rep)
        self.assertTrue(rep["fireflies"]["ok"], rep)
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "linear"))
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "github"))
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "fireflies"))
        fault = ctx.store.freeze_fault("quantivly")
        self.assertIsNotNone(fault, "the freeze fault must have been driven, not silently avoided")
        self.assertGreaterEqual(fault["fails"], 1)

    def test_dry_run_never_writes_a_freeze_fault_row_even_on_a_persistent_fault(self):
        # DO-753/DO-768: a dry run must not start a state change a real call would -- including
        # this new bookkeeping. `read_or_freeze_fireflies_fallback_anchor` already skips the
        # write itself on `dry_run`, so `fireflies_since` must never even ATTEMPT to record a
        # result for it.
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=True)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        ctx.state_dir.mkdir(parents=True, exist_ok=True)
        day_dir = ctx.state_dir / "2026-09-19"; day_dir.mkdir(parents=True, exist_ok=True)
        (day_dir / "last-brief.json").write_text(json.dumps({"keys": [], "generated_at": "2026-09-19T16:00:00Z"}))
        (ctx.state_dir / snapshots.FIREFLIES_BOOTSTRAP_ANCHOR_FILE).mkdir(parents=True)
        sync.fireflies_since(ctx, self.NOW)
        self.assertIsNone(ctx.store.freeze_fault("quantivly"), "a dry run must record no freeze-fault row")

    def test_a_read_only_state_dir_fails_loudly_before_any_freeze_logic_runs(self):
        # Independent review of #272 (`mergeable: false`): the freeze-fault streak lives in
        # `rabota.db` inside `state_dir`, and #272's own tests only simulate an unwritable
        # state dir by occupying the ANCHOR FILE's own path -- never the state dir itself -- so
        # the review read that as the alarm being unable to sound in the realistic failure it
        # exists to report. Driven here against a genuinely read-only state dir: the tick does
        # not slide silently, it fails outright, before `_freeze_fireflies_bootstrap_anchor` or
        # any freeze-fault bookkeeping is ever reached. `snapshots.write` raises the bare OSError
        # (a permissions fault is never this call's problem to degrade -- unlike the one small
        # bootstrap-anchor file, most callers of `snapshots.write` have nothing softer to fall
        # back to), and `Store.open` raises `errors.RabotaError` naming the state dir. The
        # freeze-fault streak being skipped in this shape is therefore unreachable, not
        # unreported -- see the comment at `fireflies_since`'s DO-768 paragraph in sync.py.
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        state_dir = Path(tmp.name) / "state"; state_dir.mkdir()
        state_dir.chmod(0o555)
        self.addCleanup(state_dir.chmod, 0o755)   # tempdir cleanup needs write access back
        with self.assertRaises(PermissionError):
            snapshots.write(state_dir, "linear", {"items": []})
        with self.assertRaises(errors.RabotaError) as cm:
            store.Store.open(state_dir)
        self.assertIn(str(state_dir), str(cm.exception))

    # ---- DO-768 fix round 2: the bookkeeping cannot depend on the disk it reports about --------

    def test_a_db_specific_fault_still_reaches_the_operator(self):
        # Adjudicated review of #272 (`mergeable: false` against 2094b11): the row above only pins
        # the case where the WHOLE `state_dir` is unwritable -- `Store.open` and `snapshots.write`
        # both raise before any freeze logic runs -- and the fix round reasoned from there that no
        # narrower gap exists. False: `rabota.db` is a single file inside `state_dir` that can be
        # unwritable on its OWN (chmod, a corrupt page forcing a read-only fallback, a full disk
        # hit specific to that file) while the anchor path and `sources/*.json` stay writable.
        # `Store.open` succeeds against a chmod-0o444 `rabota.db` (`migrate()` is a no-op once the
        # schema already matches, so no write is even attempted at open time -- verified directly),
        # the freeze write fails (anchor path occupied by a directory), and
        # `record_fireflies_freeze_result`'s own guard then swallows the DB write that would have
        # recorded THAT failure too -- the same swallow, for the same reason, producing the same
        # silence the row above exists to catch, just one file narrower.
        #
        # Fails on 2094b11: the streak lives only in `rabota.db`. `record_fireflies_freeze_result`'s
        # INSERT never lands against a read-only file, `Store.freeze_fault` stays `None` forever,
        # and `reconcile.snapshot_health` never has anything to alert on -- however many times the
        # loop below runs.
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-19", "2026-09-19T16:00:00Z")
        (ctx.state_dir / snapshots.FIREFLIES_BOOTSTRAP_ANCHOR_FILE).mkdir(parents=True)
        ctx.store   # force the lazy open now, so `rabota.db` exists before it is chmoded
        ctx.close()
        db_path = ctx.state_dir / "rabota.db"
        db_path.chmod(0o444)
        self.addCleanup(db_path.chmod, 0o644)   # tempdir cleanup needs write access back
        for i in range(5):
            anchor, freeze_error = snapshots.read_or_freeze_fireflies_fallback_anchor(ctx.state_dir, ctx.dry_run)
            self.assertIsNotNone(freeze_error, f"call {i}: the anchor write must still fail")
            snapshots.record_fireflies_freeze_result(ctx, freeze_error)
        self.assertIsNone(ctx.store.freeze_fault("quantivly"),
                          "the DB write itself must have failed too, against a read-only rabota.db")
        health = reconcile.snapshot_health(ctx, self.NOW)
        self.assertTrue([h for h in health if h["source"] == "fireflies"],
                        "a DB-specific fault must still reach the operator, through a path that "
                        "does not require the write that just failed")

    def test_a_locked_database_also_reaches_the_operator(self):
        # "A locked database is the everyday form of this" (review): the timer and an interactive
        # session open the same store concurrently by design, so a write can lose a real lock race
        # (`sqlite3.OperationalError: database is locked`, past `busy_timeout`) with no permission
        # bit involved at all -- a different shape than the chmod row above, and worth its own row
        # rather than trusting one failure mode to stand in for the other. Simulated directly on
        # `Store.record_freeze_result` rather than with a second real connection racing
        # `busy_timeout=5000ms`, which would make this row slow and still only probabilistically
        # exercise the lock.
        #
        # Fails on 2094b11 the same way the row above does: nothing but `Store.freeze_fault` is
        # ever consulted, and that streak never advances once every write to it raises.
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-19", "2026-09-19T16:00:00Z")
        (ctx.state_dir / snapshots.FIREFLIES_BOOTSTRAP_ANCHOR_FILE).mkdir(parents=True)
        with mock.patch.object(store.Store, "record_freeze_result",
                                side_effect=sqlite3.OperationalError("database is locked")):
            for i in range(3):
                anchor, freeze_error = snapshots.read_or_freeze_fireflies_fallback_anchor(ctx.state_dir, ctx.dry_run)
                self.assertIsNotNone(freeze_error, f"call {i}: the anchor write must still fail")
                snapshots.record_fireflies_freeze_result(ctx, freeze_error)
        health = reconcile.snapshot_health(ctx, self.NOW)
        self.assertTrue([h for h in health if h["source"] == "fireflies"],
                        "a locked rabota.db must still reach the operator")

    def test_a_persistent_fault_within_one_tick_crosses_the_threshold(self):
        # Fix round 2, finding 2: `FIREFLIES_FREEZE_ALERT_AFTER` counts consecutive failed
        # ATTEMPTS, not consecutive ticks -- `sync.fireflies_since` and `brief._fireflies_coverage`
        # are two independent CLI processes that each make their own attempt once per real
        # operational tick (a timer runs `rabota sync` then `rabota brief`), so a fault present for
        # exactly ONE tick already posts 2 consecutive attempts -- one from sync, one from brief --
        # and crosses the threshold within that one tick, not on a second tick. See the
        # `FIREFLIES_FREEZE_ALERT_AFTER` comment in snapshots.py for why the comment now says
        # "attempt", not "tick", rather than inventing a shared tick id neither process has.
        #
        # Driven through a DB-specific fault (this fix round's own new fallback channel) rather
        # than a working `rabota.db`, so this row also fails on 2094b11 -- not because the
        # attempts-vs-ticks semantics changed (they did not: two attempts already crossed the
        # threshold there too), but because a read-only `rabota.db` there silences BOTH attempts
        # the same way the row above shows, leaving nothing to alert on regardless of how the
        # threshold is counted.
        ctx = self.ctx()
        self._write_day_brief(ctx, "2026-09-19", "2026-09-19T16:00:00Z")
        (ctx.state_dir / snapshots.FIREFLIES_BOOTSTRAP_ANCHOR_FILE).mkdir(parents=True)
        ctx.store
        ctx.close()
        db_path = ctx.state_dir / "rabota.db"
        db_path.chmod(0o444)
        self.addCleanup(db_path.chmod, 0o644)
        sync.fireflies_since(ctx, self.NOW)                        # sync's own attempt, this tick
        self.assertFalse([h for h in reconcile.snapshot_health(ctx, self.NOW) if h["source"] == "fireflies"],
                         "one attempt alone must still be quiet")
        brief._fireflies_coverage(ctx, self.NOW)                   # brief's own attempt, the SAME tick
        health = reconcile.snapshot_health(ctx, self.NOW)
        self.assertTrue([h for h in health if h["source"] == "fireflies"],
                        "sync-then-brief within one tick is 2 consecutive attempts, matching what "
                        "the threshold actually counts")

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
