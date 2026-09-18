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
    def __init__(self, notifications, issues):
        self.n = {x["id"]: dict(x) for x in notifications}; self.i = {x["id"]: dict(x) for x in issues}; self.calls = []
    def archive_notification(self, nid): self.calls.append(("archive", nid)); self.n[nid]["archivedAt"] = "now"; return {"success": True}
    def unarchive_notification(self, nid): self.calls.append(("unarchive", nid)); self.n[nid]["archivedAt"] = None; return {"success": True}
    def inbox_notifications(self): return [x for x in self.n.values() if not x["archivedAt"]]
    def set_due_date(self, iid, due): self.calls.append(("due", iid, due)); self.i[iid]["dueDate"] = due; return {"success": True, "issue": {"id": iid, "dueDate": due}}
    def issue_state_and_due(self, iid): return {"id": iid, "dueDate": self.i[iid]["dueDate"], "state": {"type": self.i[iid]["state"]["type"]}}


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

    def test_dry_run_records_nothing(self):
        rep = apply.apply_auto(self.plan, self.client, self.store, T, dry_run=True)
        self.assertEqual(self.client.calls, []); self.assertEqual(rep["archived"], 0)

    def test_rollback_unarchives(self):
        rep = apply.apply_auto(self.plan, self.client, self.store, T)
        rb = apply.rollback(rep["batch_id"], self.client, self.store)
        self.assertEqual(rb["restored"], 4)
        self.assertIsNone(self.client.n["n1"]["archivedAt"])
        self.assertIsNotNone(self.store.decisions(rep["batch_id"])[0]["rolled_back_at"])

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
