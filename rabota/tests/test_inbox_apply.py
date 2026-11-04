import json, tempfile, unittest
from datetime import date
from pathlib import Path
from rabota import config, errors
from rabota.inbox import apply, buckets
from rabota.store import Store

FIX = Path(__file__).parent / "fixtures"
T = config.load(FIX / "config").tenants["quantivly"]
LIN = json.loads((FIX / "inbox" / "linear.json").read_text())
GH = json.loads((FIX / "inbox" / "github.json").read_text())


class FakeClient:
    def __init__(self, notifications, issues, stale_reads=0):
        self.n = {x["id"]: dict(x) for x in notifications}; self.i = {x["id"]: dict(x) for x in issues}; self.calls = []
        # DO-707: Linear's read-after-write is not strongly consistent -- a re-read right after a
        # successful write can still return the pre-write value. `stale_reads` is how many times
        # EACH issue's `issue_state_and_due` answers with the value from before the write that is
        # in flight, before it catches up; 0 reproduces the old always-fresh fake.
        self.stale_reads = stale_reads; self._reads_since_write = {}
    def archive_notification(self, nid): self.calls.append(("archive", nid)); self.n[nid]["archivedAt"] = "now"; return {"success": True}
    def unarchive_notification(self, nid): self.calls.append(("unarchive", nid)); self.n[nid]["archivedAt"] = None; return {"success": True}
    def inbox_notifications(self): return [x for x in self.n.values() if not x["archivedAt"]]
    def set_due_date(self, iid, due):
        self.calls.append(("due", iid, due))
        prior = self.i[iid]["dueDate"]
        self._pending = getattr(self, "_pending", {}); self._pending[iid] = prior
        self._reads_since_write[iid] = 0
        self.i[iid]["dueDate"] = due
        return {"success": True, "issue": {"id": iid, "dueDate": due}}
    def issue_state_and_due(self, iid):
        n = self._reads_since_write.get(iid, self.stale_reads)
        due = self.i[iid]["dueDate"]
        if n < self.stale_reads:
            due = self._pending[iid]
            self._reads_since_write[iid] = n + 1
        return {"id": iid, "dueDate": due, "state": {"type": self.i[iid]["state"]["type"]}}


class ApplyTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.store = Store.open(Path(tmp.name)); self.addCleanup(self.store.close)
        self.plan = buckets.classify(LIN, GH, T, date(2026, 9, 16))
        self.client = FakeClient(LIN["notifications"], LIN["issues"])

    def test_auto_archives_only_auto_tier_and_verifies(self):
        rep = apply.apply_auto(self.plan, self.client, self.store, T)
        archived = sorted(nid for op, nid in self.client.calls if op == "archive")
        self.assertEqual(archived, ["n1", "n12", "n4", "n6"])    # dead (x2), merged PR, past due reminder; n7 (live date) untouched
        self.assertEqual((rep["archived"], rep["verified"], rep["failed"]), (4, 4, []))
        self.assertTrue(all(d["verified"] for d in self.store.decisions(rep["batch_id"])))

    # DO-877: the answers Sol recorded, applied at the tick through the same writes.

    def test_a_due_policy_answer_clears_only_the_issues_it_covered_that_are_still_in_the_batch(self):
        self.store.record_inbox_answer("quantivly", "due_policy", ["HUB-11", "HUB-12", "HUB-99"])   # HUB-99 left the batch
        rep = apply.apply_answers(self.plan, self.client, self.store, T)
        self.assertEqual([(a["kind"], a["outcome"]["cleared"]) for a in rep["applied"]], [("due_policy", 2)])
        self.assertEqual(sorted(c[1] for c in self.client.calls if c[0] == "due"), ["i-due1", "i-due2"])
        self.assertEqual(self.client.i["i-due3"]["dueDate"], "2026-09-04")   # in the batch, not covered: untouched
        batch = rep["applied"][0]["batch_id"]
        self.assertEqual([(d["entity_id"], d["action"], d["prior"]) for d in self.store.decisions(batch)],
                         [("i-due1", "clear_due_date", {"dueDate": "2026-09-04"}), ("i-due2", "clear_due_date", {"dueDate": "2026-09-04"})])
        self.assertEqual([r["batch_id"] for r in self.store.applied_inbox_answers("quantivly", 25)], [batch])
        self.assertEqual(self.store.pending_inbox_answers("quantivly"), [])

    def test_a_project_prompt_dismissal_archives_each_id_with_a_rollback_row_and_verifies(self):
        self.store.record_inbox_answer("quantivly", "project_prompt", ["n7", "n2"])
        rep = apply.apply_answers(self.plan, self.client, self.store, T)
        out = rep["applied"][0]["outcome"]
        self.assertEqual((out["archived"], out["verified"], out["failed"], out["by_bucket"]), (2, 2, [], {"project_prompt": 2}))
        self.assertEqual([c for c in self.client.calls if c[0] == "archive"], [("archive", "n7"), ("archive", "n2")])
        rows = self.store.decisions(out["batch_id"])
        self.assertEqual([(d["tier"], d["bucket"], d["entity_id"], d["action"], d["verified"]) for d in rows],
                         [("decision", "project_prompt", "n7", "archive", 1), ("decision", "project_prompt", "n2", "archive", 1)])
        self.assertTrue(out["batch_id"].startswith("dismiss-"))

    def test_rollback_undoes_either_kind_of_answer(self):
        self.store.record_inbox_answer("quantivly", "due_policy", ["HUB-11"])
        self.store.record_inbox_answer("quantivly", "project_prompt", ["n7"])
        rep = apply.apply_answers(self.plan, self.client, self.store, T)
        self.assertIsNone(self.client.i["i-due1"]["dueDate"]); self.assertEqual(self.client.n["n7"]["archivedAt"], "now")
        for a in rep["applied"]:
            self.assertEqual(apply.rollback(a["batch_id"], self.client, self.store)["failed"], [])
        self.assertEqual(self.client.i["i-due1"]["dueDate"], "2026-09-04"); self.assertIsNone(self.client.n["n7"]["archivedAt"])

    def test_an_applied_answer_is_never_applied_twice_and_an_emptied_one_is_stamped_without_a_batch(self):
        self.store.record_inbox_answer("quantivly", "due_policy", ["HUB-11"])
        self.store.record_inbox_answer("quantivly", "due_policy", ["HUB-99"])   # nothing it covered is still in the batch
        rep = apply.apply_answers(self.plan, self.client, self.store, T)
        self.assertEqual([(a["kind"], a["batch_id"] is None, a["outcome"] is None) for a in rep["applied"]],
                         [("due_policy", False, False), ("due_policy", True, True)])
        calls = list(self.client.calls)
        self.assertEqual(apply.apply_answers(self.plan, self.client, self.store, T), {"applied": []})
        self.assertEqual(self.client.calls, calls)

    def test_answers_dry_run_names_the_pending_rows_touches_no_client_and_stamps_nothing(self):
        self.store.record_inbox_answer("quantivly", "project_prompt", ["n7"])
        rep = apply.apply_answers(self.plan, None, self.store, T, dry_run=True)
        self.assertEqual(rep, {"applied": [], "would_apply": [{"id": 1, "kind": "project_prompt", "ids": ["n7"]}]})
        self.assertEqual(self.client.calls, [])
        self.assertEqual(len(self.store.pending_inbox_answers("quantivly")), 1)

    def test_dry_run_records_nothing(self):
        rep = apply.apply_auto(self.plan, self.client, self.store, T, dry_run=True)
        self.assertEqual(self.client.calls, []); self.assertEqual(rep["archived"], 0)

    def test_rollback_unarchives(self):
        rep = apply.apply_auto(self.plan, self.client, self.store, T)
        rb = apply.rollback(rep["batch_id"], self.client, self.store)
        self.assertEqual(rb["restored"], 4)
        self.assertIsNone(self.client.n["n1"]["archivedAt"])
        self.assertIsNotNone(self.store.decisions(rep["batch_id"])[0]["rolled_back_at"])

    def test_dry_run_rollback_never_touches_the_client_or_marks_rolled_back(self):
        # DO-753 "most urgent": a --dry-run rollback used to mutate Linear for real (unarchive,
        # restore a due date) because `apply.rollback` read no dry_run at all. `self.client` here
        # records every call it receives, so any mutation attempted at all fails this immediately.
        rep = apply.apply_auto(self.plan, self.client, self.store, T)
        calls_before = list(self.client.calls)
        rb = apply.rollback(rep["batch_id"], self.client, self.store, dry_run=True)
        self.assertEqual(self.client.calls, calls_before)          # nothing sent to Linear
        self.assertEqual(sorted(rb["would_restore"]),
                         sorted(d["entity_id"] for d in self.store.decisions(rep["batch_id"])))
        self.assertIsNone(self.store.decisions(rep["batch_id"])[0]["rolled_back_at"])   # not marked rolled back

    def test_due_policy_requires_confirmed_is_true_not_truthy(self):
        # k5's shape: a truthy-but-not-True confirmed must not pass. The CLI path is safe (argparse
        # produces a real bool); this guards the Python API a future caller (WS5) will use directly.
        for bad in ("false", "true", 1, 0, None):
            with self.assertRaises(errors.Refused):
                apply.apply_due_policy(self.plan, self.client, self.store, T, confirmed=bad)

    def test_due_policy_requires_confirmation_and_rolls_back_byte_for_byte(self):
        with self.assertRaises(errors.Refused):
            apply.apply_due_policy(self.plan, self.client, self.store, T, confirmed=False)
        rep = apply.apply_due_policy(self.plan, self.client, self.store, T, confirmed=True)
        self.assertEqual(rep["cleared"], 5)
        self.assertIsNone(self.client.i["i-due1"]["dueDate"])
        self.assertEqual(self.client.i["i-real"]["dueDate"], "2026-09-25")
        apply.rollback(rep["batch_id"], self.client, self.store)
        self.assertEqual(self.client.i["i-due1"]["dueDate"], "2026-09-04")

    def test_a_stale_read_after_write_is_retried_and_still_verifies(self):
        """DO-707: `inbox apply --batch due_policy` reported `verified: 38` then `verified: 37`
        against `cleared: 40` while every write had actually landed -- Linear's read-after-write
        is not strongly consistent, so the single immediate re-read sometimes caught the
        pre-write value. Every write here succeeds; a read that is stale for fewer attempts than
        the retry budget must still end up verified, not silently dropped from the count."""
        client = FakeClient(LIN["notifications"], LIN["issues"], stale_reads=2)
        rep = apply.apply_due_policy(self.plan, client, self.store, T, confirmed=True, sleeper=lambda s: None)
        self.assertEqual(rep["cleared"], 5)
        self.assertEqual(rep["verified"], 5)
        self.assertEqual(rep["unconfirmed"], [])
        self.assertEqual(rep["failed"], [])

    def test_a_verify_read_that_raises_is_unconfirmed_never_also_failed(self):
        """Review finding: the verify read sat inside the same `try` as the write, so a read that
        RAISED put the issue in `failed` having already counted it in `cleared` -- one issue in two
        buckets, and a write that actually succeeded reported as a failure. The four buckets must
        partition the issues: `failed` xor (`verified` xor `unconfirmed`), summing to the plan."""
        issues = self.plan["batches"]["due_policy"]["issues"]
        client = FakeClient(LIN["notifications"], LIN["issues"])
        client.issue_state_and_due = lambda iid: (_ for _ in ()).throw(errors.RabotaError("read blew up"))
        rep = apply.apply_due_policy(self.plan, client, self.store, T, confirmed=True,
                                      verify_attempts=2, sleeper=lambda s: None)
        self.assertEqual(rep["failed"], [])
        self.assertEqual(rep["verified"], 0)
        self.assertEqual(sorted(rep["unconfirmed"]), sorted(i["identifier"] for i in issues))
        self.assertEqual(rep["cleared"], len(issues))
        self.assertEqual(rep["verified"] + len(rep["unconfirmed"]) + len(rep["failed"]), len(issues))
        # the read error is recorded, not swallowed: one entry per issue, not one per attempt
        self.assertEqual(sorted(e["id"] for e in rep["read_errors"]), sorted(i["identifier"] for i in issues))
        self.assertTrue(all(e["error"] == "read blew up" for e in rep["read_errors"]))

    def test_a_write_that_fails_is_not_counted_as_cleared_and_is_never_read_back(self):
        """The other side of the same partition: a write that raises must not increment `cleared`,
        and must not be verified -- reading back an issue we never wrote can only mislead."""
        issues = self.plan["batches"]["due_policy"]["issues"]
        client = FakeClient(LIN["notifications"], LIN["issues"])
        client.set_due_date = lambda iid, due: {"success": False}
        client.issue_state_and_due = lambda iid: self.fail("a failed write must not be read back")
        rep = apply.apply_due_policy(self.plan, client, self.store, T, confirmed=True, sleeper=lambda s: None)
        self.assertEqual(rep["cleared"], 0)
        self.assertEqual(rep["verified"], 0)
        self.assertEqual(rep["unconfirmed"], [])
        self.assertEqual(rep["read_errors"], [])
        self.assertEqual(sorted(f["id"] for f in rep["failed"]), sorted(i["identifier"] for i in issues))

    def test_a_write_that_never_reads_back_is_unconfirmed_not_failed(self):
        """The other half of DO-707: `cleared: 40, verified: 37` reads like three writes silently
        failed. A write whose re-read never catches up within the retry budget must be reported
        as `unconfirmed` -- distinguishable from a genuine write failure -- never folded into
        `failed`, since the write itself raised no error."""
        client = FakeClient(LIN["notifications"], LIN["issues"], stale_reads=99)
        rep = apply.apply_due_policy(self.plan, client, self.store, T, confirmed=True,
                                      verify_attempts=2, sleeper=lambda s: None)
        self.assertEqual(rep["cleared"], 5)
        self.assertEqual(rep["verified"], 0)
        self.assertEqual(sorted(rep["unconfirmed"]), sorted(i["identifier"] for i in self.plan["batches"]["due_policy"]["issues"]))
        self.assertEqual(rep["failed"], [])
