import json, unittest
from datetime import date
from pathlib import Path
from rabota import config
from rabota.inbox import buckets
from tests.test_linear import selection_tree

FIX = Path(__file__).parent / "fixtures"
T = config.load(FIX / "config").tenants["quantivly"]
LIN = json.loads((FIX / "inbox" / "linear.json").read_text())
GH = json.loads((FIX / "inbox" / "github.json").read_text())

# top-level names the notification query actually requests, from rabota.sources.linear.NOTIFICATION_FIELDS,
# plus the one key inbox_notifications() derives (pullRequestUrl) — see L2 in the WS3 brief.
from rabota.sources import linear as _linear_mod
ALLOWED_NODE_KEYS = set(selection_tree(_linear_mod.NOTIFICATION_FIELDS)) | {"pullRequestUrl"}


class BucketTests(unittest.TestCase):
    def setUp(self):
        self.plan = buckets.classify(LIN, GH, T, date(2026, 9, 16))

    def by_bucket(self, name):
        return sorted(i["notification_id"] for i in self.plan["buckets"].get(name, []))

    def test_every_unread_lands_in_exactly_one_bucket(self):
        self.assertEqual(self.plan["unread_total"], 11)
        self.assertEqual(sum(self.plan["totals"].values()), 11)
        seen = [i["notification_id"] for b in self.plan["buckets"].values() for i in b]
        self.assertEqual(len(seen), len(set(seen)))
        self.assertNotIn("n11", seen)  # read notifications are ignored

    def test_bucket_assignments(self):
        self.assertEqual(self.by_bucket("dead_issue"), ["n1", "n12"])
        self.assertEqual(self.by_bucket("confirm_required"), ["n10", "n2"])   # SEC assignment; status change on someone else's issue
        self.assertEqual(self.by_bucket("reply_queue"), ["n3"])               # a mention on someone else's issue is still an ask
        self.assertEqual(self.by_bucket("own_pr_merged"), ["n4"])
        self.assertEqual(self.by_bucket("own_pr_approved_open"), ["n5"])
        self.assertEqual(self.by_bucket("due_reminder"), ["n6", "n7"])
        self.assertEqual(self.by_bucket("project_prompt"), ["n8"])
        self.assertEqual(self.by_bucket("other"), ["n9"])

    def test_due_reminder_tier_depends_on_issue_date(self):
        items = {i["notification_id"]: i for i in self.plan["buckets"]["due_reminder"]}
        self.assertEqual(items["n6"]["tier"], "auto")      # 2026-09-04 is past
        self.assertEqual(items["n7"]["tier"], "hold")      # 2026-09-25 is a live date

    def test_due_policy_batch_clears_backlog_and_shared_dates_only(self):
        ids = sorted(i["identifier"] for i in self.plan["batches"]["due_policy"]["issues"])
        self.assertEqual(ids, ["HUB-11", "HUB-12", "HUB-13", "HUB-14", "HUB-15"])   # HUB-20 real date kept; SEC-211 excluded

    def test_stale_backlog_batch(self):
        self.assertEqual([i["identifier"] for i in self.plan["batches"]["stale_backlog"]["issues"]], ["DCM-9"])

    def test_summary_line(self):
        line = buckets.summary_line(self.plan, applied={"archived": 2, "by_bucket": {"dead_issue": 1, "own_pr_merged": 1}})
        self.assertTrue(line.startswith("inbox: 2 archived"))
        self.assertIn("1 reply thread", line)

    def test_confirm_teams_dead_issue_collision(self):
        # Spec collision (WS3 brief): the Global Constraints say any issue in a confirm_teams team
        # (SEC) goes to confirm_required, absolutely — but the bucket table puts dead_issue first and
        # first match wins, so a notification about an ALREADY-CLOSED SEC issue (n12, SEC-99) lands
        # in dead_issue/auto instead. Implemented per the table, which is what the other tests here
        # are written against; flagged for Zvi in the verdict rather than resolved unilaterally.
        items = {i["notification_id"]: i for i in self.plan["buckets"]["dead_issue"]}
        self.assertIn("n12", items)
        self.assertEqual(items["n12"]["tier"], "auto")
        self.assertEqual(items["n12"]["issue_team"], "SEC")

    def test_pr_entries_missing_url_are_dropped_not_crashed(self):
        gh = {"own_prs": GH["own_prs"] + [{"repo": "o/r", "number": 99}],
              "merged_recent": GH["merged_recent"] + [{"repo": "o/r", "number": 98}]}
        plan = buckets.classify(LIN, gh, T, date(2026, 9, 16))  # must not raise KeyError
        self.assertEqual(sorted(i["notification_id"] for i in plan["buckets"]["own_pr_merged"]), ["n4"])
        self.assertEqual(sorted(i["notification_id"] for i in plan["buckets"]["own_pr_approved_open"]), ["n5"])

    def test_empty_string_url_does_not_match_empty_pull_request_url(self):
        # WS3 fix-brief round 2, item 3: round 1 dropped only `None` urls (`is not None`), so an
        # empty-string url in a merged_recent/own_prs entry still matched an empty-string
        # pullRequestUrl on a notification ('' == '') -- over-archiving, the one direction this
        # workstream must never fail in. Falsy urls (not just None) must be dropped from both sets.
        lin = json.loads(json.dumps(LIN))
        lin["notifications"].append({"id": "n14", "type": "pullRequestApproved", "issue": None, "readAt": None,
                                      "archivedAt": None, "actor": {"displayName": "x"}, "createdAt": "2026-09-16T00:00:00Z",
                                      "url": None, "title": None, "pullRequestUrl": ""})
        gh = {"own_prs": GH["own_prs"] + [{"repo": "o/r", "number": 99, "url": ""}],
              "merged_recent": GH["merged_recent"] + [{"repo": "o/r", "number": 98, "url": ""}]}
        plan = buckets.classify(lin, gh, T, date(2026, 9, 16))
        approved_open = [i["notification_id"] for i in plan["buckets"].get("own_pr_approved_open", [])]
        merged = [i["notification_id"] for i in plan["buckets"].get("own_pr_merged", [])]
        self.assertNotIn("n14", approved_open)
        self.assertNotIn("n14", merged)
        self.assertIn("n14", [i["notification_id"] for i in plan["buckets"]["other"]])

    def test_issue_due_with_null_issue_is_hold_not_auto(self):
        # b1: "no date to check" must not read as "date already passed" and auto-archive.
        lin = json.loads(json.dumps(LIN))
        lin["notifications"].append({"id": "n13", "type": "issueDue", "issue": None, "readAt": None,
                                      "archivedAt": None, "actor": None, "createdAt": "2026-09-16T00:00:00Z",
                                      "url": None, "title": None, "pullRequestUrl": None})
        plan = buckets.classify(lin, GH, T, date(2026, 9, 16))
        items = {i["notification_id"]: i for i in plan["buckets"]["due_reminder"]}
        self.assertEqual(items["n13"]["tier"], "hold")

    def test_fixture_notification_nodes_carry_no_key_outside_the_selection_set(self):
        # L2 in the WS3 brief: a fixture richer than the real API payload is how review finding k7
        # hid for four rounds. Every key on a notification node must be one the query actually asks
        # for (rabota.sources.linear.NOTIFICATION_FIELDS, top-level) or the one derived key the client
        # adds (pullRequestUrl).
        for n in LIN["notifications"]:
            extra = set(n) - ALLOWED_NODE_KEYS
            self.assertFalse(extra, f"notification {n['id']!r} has keys outside the selection set: {extra}")
