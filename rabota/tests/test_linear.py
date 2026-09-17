import json, re, unittest
from pathlib import Path
from rabota import errors
from rabota.sources import linear

FIX = Path(__file__).parent / "fixtures" / "linear"
_TOKEN = re.compile(r"\.\.\.\s+on\s+\w+|[{}]|[A-Za-z_]\w*")


def selection_tree(text: str) -> dict:
    """Parse a GraphQL selection set into ``{field: subtree | None}``; inline fragments are transparent.

    Driven from the selection set itself so a fixture cannot be richer than the query: a field
    that appears here is one Linear was asked for, and nothing else may appear in a test node.
    """
    root: dict = {}
    stack = [root]
    fragment_next = False
    frames = []          # True where the brace opened an inline fragment (no new level)
    last = None
    for tok in _TOKEN.findall(text):
        if tok.startswith("..."):
            fragment_next = True
        elif tok == "{":
            if fragment_next:
                frames.append(True); fragment_next = False
            else:
                child = stack[-1][last] = stack[-1][last] or {}
                stack.append(child); frames.append(False)
        elif tok == "}":
            if not frames.pop():
                stack.pop()
        else:
            stack[-1].setdefault(tok, None); last = tok
    return root


def tree_paths(tree: dict, prefix: str = "") -> set[str]:
    out = set()
    for k, sub in tree.items():
        out.add(prefix + k)
        if sub:
            out |= tree_paths(sub, prefix + k + ".")
    return out


class Recording(dict):
    """A node that records every key path the code under test reads off it."""
    def __init__(self, data, seen: set, prefix=""):
        super().__init__(data); self._seen, self._prefix = seen, prefix
    def _note(self, key):
        self._seen.add(self._prefix + str(key))
    def _wrap(self, key, value):
        return Recording(value, self._seen, f"{self._prefix}{key}.") if isinstance(value, dict) and not isinstance(value, Recording) else value
    def __getitem__(self, key):
        self._note(key); return self._wrap(key, super().__getitem__(key))
    def get(self, key, default=None):
        self._note(key); return self._wrap(key, super().get(key, default))
    def setdefault(self, key, default=None):
        self._note(key); return super().setdefault(key, default)
    def __contains__(self, key):
        self._note(key); return super().__contains__(key)


def node_from_selection(tree: dict, **override) -> dict:
    """A notification whose every key is one the query requests; leaves are sentinel strings."""
    node = {k: node_from_selection(sub) if sub else f"<{k}>" for k, sub in tree.items()}
    node.update(override)
    return node


def assert_within_selection(tc, node: dict, tree: dict, where="fixture"):
    """A fixture may not contain a key the query does not ask for — that is how k7 hid."""
    extra = {k for k in node if k not in tree}
    tc.assertFalse(extra, f"{where} carries keys the selection set never requests: {sorted(extra)}")
    for k, sub in tree.items():
        if sub and isinstance(node.get(k), dict):
            assert_within_selection(tc, node[k], sub, f"{where}.{k}")

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
        tree = selection_tree(linear.NOTIFICATION_FIELDS)
        nodes = [
            {"id": "n1", "type": "issueDue", "archivedAt": None, "issue": {"id": "i1"}},
            {"id": "n2", "type": "issueNewComment", "archivedAt": "2026-09-15T00:00:00Z"},
            {"id": "n3", "type": "pullRequestApproved", "archivedAt": None, "url": "https://github.com/o/r/pull/1"},
            {"id": "n4", "type": "pullRequestReviewRequested", "archivedAt": None, "url": "https://linear.app/x/inbox",
             "pullRequest": {"url": "https://github.com/o/r/pull/2", "title": "fix", "number": 2}},
        ]
        for n in nodes:
            assert_within_selection(self, n, tree, n["id"])
        page = {"data": {"notifications": {"nodes": nodes, "pageInfo": {"hasNextPage": False, "endCursor": None}}}}
        out = linear.LinearClient("k" * 20, post=FakePost([page])).inbox_notifications()
        self.assertEqual([n["id"] for n in out], ["n1", "n3", "n4"])
        self.assertIsNone(out[0]["pullRequestUrl"]); self.assertIsNone(out[0]["project"])
        self.assertIsNone(out[1]["pullRequestUrl"]); self.assertIsNone(out[1]["issue"])   # a notification's own url is Linear's inbox link, not the PR
        self.assertEqual(out[2]["pullRequestUrl"], "https://github.com/o/r/pull/2")   # only the pullRequest object names the PR

    def test_selection_requests_every_field_the_probe_confirmed(self):
        # Linear __type introspection, 2026-09-17 (out/ws2/FIX-ACCEPTANCE.md): these exist on the
        # Notification interface and PullRequestNotification.pullRequest is a PullRequest.
        paths = tree_paths(selection_tree(linear.NOTIFICATION_FIELDS))
        for want in ("id", "type", "url", "title", "subtitle", "groupingKey", "actor.displayName",
                     "issue.identifier", "project.name", "pullRequest.url", "pullRequest.title", "pullRequest.number"):
            self.assertIn(want, paths)

    def test_inbox_notifications_reads_only_fields_the_selection_requests(self):
        tree = selection_tree(linear.NOTIFICATION_FIELDS)
        seen: set[str] = set()
        nodes = [Recording(node_from_selection(tree, archivedAt=None, type="pullRequestApproved"), seen),
                 Recording(node_from_selection(tree, archivedAt=None, type="issueDue"), seen)]
        page = {"data": {"notifications": {"nodes": nodes, "pageInfo": {"hasNextPage": False, "endCursor": None}}}}
        out = linear.LinearClient("k" * 20, post=FakePost([page])).inbox_notifications()
        requested = tree_paths(tree)
        read_but_not_requested = {k for k in seen if k not in requested and k != "pullRequestUrl"}
        self.assertFalse(read_but_not_requested, f"inbox_notifications reads fields the query never asks for: {sorted(read_but_not_requested)}")
        self.assertEqual(out[0]["pullRequestUrl"], "<url>")      # from pullRequest.url — the sentinel the tree put there
        self.assertEqual((out[0]["title"], out[1]["title"]), ("<title>", "<title>"))

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
