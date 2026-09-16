import json, unittest
from pathlib import Path
from rabota import errors
from rabota.sources import linear

FIX = Path(__file__).parent / "fixtures" / "linear"

class FakePost:
    def __init__(self, pages): self.pages, self.calls = list(pages), []
    def __call__(self, body):
        self.calls.append(body); return self.pages.pop(0)

class LinearClientTests(unittest.TestCase):
    def test_paginate_follows_cursor(self):
        p1, p2 = json.loads((FIX / "page1.json").read_text()), json.loads((FIX / "page2.json").read_text())
        post = FakePost([p1, p2])
        c = linear.LinearClient("k" * 20, post=post)
        nodes = c.paginate(linear.Q_NOTIFICATIONS, ["notifications"])
        self.assertEqual(len(nodes), 4)
        self.assertEqual(post.calls[1]["variables"]["after"], p1["data"]["notifications"]["pageInfo"]["endCursor"])

    def test_error_reply_raises_without_key(self):
        post = FakePost([{"errors": [{"message": "bad selection"}]}])
        c = linear.LinearClient("supersecretkey123", post=post)
        with self.assertRaises(errors.RabotaError) as cm:
            c.query("{ viewer { id } }")
        self.assertNotIn("supersecretkey123", str(cm.exception))

    def test_from_context_refuses_without_key(self):
        class T: linear_key_env = "LINEAR_API_KEY"
        class Ctx: tenant = T(); env = {}
        with self.assertRaises(errors.Refused):
            linear.LinearClient.from_context(Ctx())

    def test_assigned_open_excludes_dead_types_in_filter(self):
        post = FakePost([{"data": {"issues": {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}])
        linear.LinearClient("k" * 20, post=post).assigned_open(["completed", "canceled", "duplicate"])
        self.assertEqual(post.calls[0]["variables"]["dead"], ["completed", "canceled", "duplicate"])

    def test_inbox_notifications_drops_archived_and_marks_pr_mirrors(self):
        page = {"data": {"notifications": {"nodes": [
            {"id": "n1", "type": "issueDue", "archivedAt": None, "issue": {"id": "i1"}},
            {"id": "n2", "type": "issueNewComment", "archivedAt": "2026-09-15T00:00:00Z"},
            {"id": "n3", "type": "pullRequestApproved", "archivedAt": None, "url": "https://github.com/o/r/pull/1"},
        ], "pageInfo": {"hasNextPage": False, "endCursor": None}}}}
        out = linear.LinearClient("k" * 20, post=FakePost([page])).inbox_notifications()
        self.assertEqual([n["id"] for n in out], ["n1", "n3"])
        self.assertIsNone(out[0]["pullRequestUrl"]); self.assertIsNone(out[0]["project"])
        self.assertEqual(out[1]["pullRequestUrl"], "https://github.com/o/r/pull/1"); self.assertIsNone(out[1]["issue"])

    def test_relations_map_blocks_and_blocked_by(self):
        page = {"data": {"issues": {"nodes": [
            {"id": "a", "relations": {"nodes": [{"type": "blocks", "relatedIssue": {"identifier": "HUB-2"}},
                                                {"type": "related", "relatedIssue": {"identifier": "HUB-3"}}]},
                        "inverseRelations": {"nodes": [{"type": "blocks", "issue": {"identifier": "CORE-1"}}]}}]}}}
        rel = linear.LinearClient("k" * 20, post=FakePost([page])).relations(["a"])
        self.assertEqual(rel, {"a": {"blockedBy": ["CORE-1"], "blocks": ["HUB-2"]}})

    def test_flattened_issue_has_label_names_and_relation_defaults(self):
        page = {"data": {"issues": {"nodes": [{"id": "i1", "identifier": "HUB-1", "labels": {"nodes": [{"name": "bug"}]}}],
                                    "pageInfo": {"hasNextPage": False, "endCursor": None}}}}
        issues = linear.LinearClient("k" * 20, post=FakePost([page])).assigned_open(["completed"])
        self.assertEqual(issues[0]["labels"], ["bug"])
        self.assertEqual((issues[0]["blockedBy"], issues[0]["blocks"]), ([], []))
