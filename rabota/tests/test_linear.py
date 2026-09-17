import ast, json, re, unittest
from pathlib import Path
from rabota import errors
from rabota.sources import linear

FIX = Path(__file__).parent / "fixtures" / "linear"
_TOKEN = re.compile(r"\.\.\.\s+on\s+\w+|[{}]|[A-Za-z_]\w*")
DERIVED = {"pullRequestUrl"}      # keys the code ADDS to a node (assigned, never read off the raw reply)


def _parse_selection(text: str) -> tuple[dict, dict]:
    """``(tree, owners)`` for a GraphQL selection set.

    ``tree`` is ``{field: subtree | None}`` with inline fragments transparent; ``owners`` maps each
    top-level field declared inside ``... on <Type> { … }`` to that type, so a fixture node can be
    built the way Linear answers — an ``IssueNotification`` carries no ``pullRequest`` key at all.
    """
    root: dict = {}
    stack = [root]
    frames: list = []        # per open brace: the fragment type it opened, or None
    owners: dict = {}
    pending_fragment = None
    last = None
    for tok in _TOKEN.findall(text):
        if tok.startswith("..."):
            pending_fragment = tok.split()[-1]
        elif tok == "{":
            if pending_fragment:
                frames.append(pending_fragment); pending_fragment = None
            else:
                child = stack[-1][last] = stack[-1][last] or {}
                stack.append(child); frames.append(None)
        elif tok == "}":
            if frames.pop() is None:
                stack.pop()
        else:
            stack[-1].setdefault(tok, None); last = tok
            if len(stack) == 1:
                frag = next((f for f in reversed(frames) if f), None)
                if frag:
                    owners[tok] = frag
    return root, owners


def selection_tree(text: str) -> dict:
    """Parse a GraphQL selection set into ``{field: subtree | None}``; inline fragments are transparent.

    Driven from the selection set itself so a fixture cannot be richer than the query: a field
    that appears here is one Linear was asked for, and nothing else may appear in a test node.
    """
    return _parse_selection(text)[0]


def selection_owners(text: str) -> dict:
    """``{top-level field: fragment type}`` for the fields that only one concrete type carries."""
    return _parse_selection(text)[1]


def tree_paths(tree: dict, prefix: str = "") -> set[str]:
    out = set()
    for k, sub in tree.items():
        out.add(prefix + k)
        if sub:
            out |= tree_paths(sub, prefix + k + ".")
    return out


def tree_names(tree: dict) -> set[str]:
    """Every field name at any depth — what a static scan can compare a literal key against."""
    return {p.rsplit(".", 1)[-1] for p in tree_paths(tree)}


COPIED = "*"      # recorded when code copies the whole node: reads on the copy cannot be seen


class Recording(dict):
    """A node that records every key path the code under test reads off it, however it is spelled.

    Reads through ``[]``, ``.get``, ``.setdefault``, ``.pop`` and ``in`` are noted, and the value a
    read returns is wrapped so a chained read (``n.setdefault("issue", {}).get("x")``) is noted
    too. Copying the node — ``dict(n)``, ``{**n}``, ``n.copy()`` — is noted as ``COPIED``, because a
    read off a plain copy is invisible and the test must fail rather than not know. A key the code
    itself assigned is not a raw read when read back (that is how ``pullRequestUrl`` is legitimate
    after the assignment and the k7 bug before it). ``items()`` is deliberately NOT overridden:
    ``json.dumps`` walks a dict subclass through it, and a snapshot write is not a read.
    """
    def __init__(self, data, seen: set, prefix=""):
        super().__init__(data); self._seen, self._prefix, self._written = seen, prefix, set()
    def _note(self, key):
        if key not in self._written:
            self._seen.add(self._prefix + str(key))
    def _wrap(self, key, value):
        if isinstance(value, dict) and not isinstance(value, Recording):
            value = Recording(value, self._seen, f"{self._prefix}{key}.")
            super().__setitem__(key, value)      # so the same wrapped child is handed back next time
        return value
    def __getitem__(self, key):
        self._note(key); return self._wrap(key, super().__getitem__(key))
    def get(self, key, default=None):
        self._note(key); return self._wrap(key, super().get(key, default))
    def setdefault(self, key, default=None):
        self._note(key); return self._wrap(key, super().setdefault(key, default))
    def pop(self, key, *default):
        self._note(key); return super().pop(key, *default)
    def __contains__(self, key):
        self._note(key); return super().__contains__(key)
    def __setitem__(self, key, value):
        self._written.add(key); super().__setitem__(key, value)
    def keys(self):
        self._seen.add(self._prefix + COPIED); return super().keys()
    def __iter__(self):
        self._seen.add(self._prefix + COPIED); return super().__iter__()
    def copy(self):
        self._seen.add(self._prefix + COPIED); return dict(super().items())


def node_from_selection(tree: dict, typename: str | None = None, owners: dict | None = None, **override) -> dict:
    """A notification whose every key is one the query requests; leaves are ``<name>`` sentinels.

    With ``typename`` (``IssueNotification`` …) the fragment fields of OTHER types are left out, as
    Linear leaves them out. An override key the query never requests is a ``KeyError`` — the point
    of generating fixtures is that one physically cannot carry such a key.
    """
    owners = owners or {}
    extra = set(override) - set(tree)
    if extra:
        raise KeyError(f"fixture override names fields the selection set never requests: {sorted(extra)}")
    node = {k: node_from_selection(sub) if sub else f"<{k}>" for k, sub in tree.items()
            if typename is None or owners.get(k) in (None, typename)}
    node.update({k: v for k, v in override.items() if k in node or owners.get(k) in (None, typename)})
    return node


def notification_pages(tree: dict, owners: dict, per_page: list[list[tuple[str, str, str]]]) -> list[dict]:
    """GraphQL reply pages built from the selection set: ``per_page`` is ``[(id, type, typename), …]`` per page."""
    pages = []
    for i, specs in enumerate(per_page):
        last = i == len(per_page) - 1
        nodes = [node_from_selection(tree, typename, owners, id=nid, type=ntype, archivedAt=None) for nid, ntype, typename in specs]
        pages.append({"data": {"notifications": {"nodes": nodes, "pageInfo": {"hasNextPage": not last, "endCursor": None if last else f"c{i + 1}"}}}})
    return pages


def assert_within_selection(tc, node: dict, tree: dict, where="fixture"):
    """A fixture may not contain a key the query does not ask for — that is how k7 hid."""
    extra = {k for k in node if k not in tree}
    tc.assertFalse(extra, f"{where} carries keys the selection set never requests: {sorted(extra)}")
    for k, sub in tree.items():
        if sub and isinstance(node.get(k), dict):
            assert_within_selection(tc, node[k], sub, f"{where}.{k}")


# ---- static half: every consumer, every spelling ---------------------------------------------
PKG = Path(__file__).resolve().parent.parent / "rabota"
# Where a notification node is consumed. A function name scopes the scan to that function plus
# every same-module function it calls (transitively); ``None`` scans the whole module.
CONSUMERS = [
    (PKG / "sources" / "linear.py", "inbox_notifications"),
    (PKG / "commands" / "sync.py", None),
]
# Envelope handlers: they read the GraphQL reply (``data``, ``nodes``, ``pageInfo``), never a node's
# fields, and they serve every query at once. The dynamic rows still route Recording nodes through them.
ENVELOPE_FUNCTIONS = {"query", "paginate"}


def _literal_key_reads(func_or_module) -> list[tuple[int, str, str]]:
    """``(lineno, key, spelling)`` for every string-literal key read in the AST node: ``x["k"]``, ``x.get("k")``,
    ``x.setdefault("k")``, ``x.pop("k")``, ``"k" in x`` — whatever the receiver is (``dict(n).get`` included)."""
    out = []
    for node in ast.walk(func_or_module):
        if isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Constant) and isinstance(node.slice.value, str) \
                and isinstance(node.ctx, ast.Load):
            out.append((node.lineno, node.slice.value, "[]"))
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ("get", "setdefault", "pop") \
                and node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str):
            out.append((node.lineno, node.args[0].value, f".{node.func.attr}()"))
        elif isinstance(node, ast.Compare) and isinstance(node.left, ast.Constant) and isinstance(node.left.value, str) \
                and any(isinstance(op, (ast.In, ast.NotIn)) for op in node.ops):
            out.append((node.lineno, node.left.value, "in"))
    return out


def _literal_key_writes(func_or_module) -> set[str]:
    return {n.slice.value for n in ast.walk(func_or_module) if isinstance(n, ast.Subscript) and isinstance(n.ctx, ast.Store)
            and isinstance(n.slice, ast.Constant) and isinstance(n.slice.value, str)}


def _scope(module: ast.Module, func_name: str | None) -> list[ast.AST]:
    """The AST nodes to scan: the whole module, or the named function plus its same-module callees."""
    if func_name is None:
        return [module]
    defs = {n.name: n for n in ast.walk(module) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
    todo, done = [func_name], []
    while todo:
        name = todo.pop()
        if name in done or name in ENVELOPE_FUNCTIONS or name not in defs:
            continue
        done.append(name)
        for call in ast.walk(defs[name]):
            if isinstance(call, ast.Call):
                callee = call.func.attr if isinstance(call.func, ast.Attribute) else getattr(call.func, "id", None)
                if callee in defs:
                    todo.append(callee)
    return [defs[n] for n in done]


def notification_field_reads_outside_selection(tree: dict) -> list[str]:
    """Every literal key read in a consumer that is neither requested nor assigned by that consumer."""
    allowed = tree_names(tree)
    bad = []
    for path, func in CONSUMERS:
        module = ast.parse(path.read_text(), str(path))
        scopes = _scope(module, func)
        assert scopes, f"{path.name}: nothing to scan for {func!r}"
        derived = set().union(*(_literal_key_writes(s) for s in scopes))
        for scope in scopes:
            for lineno, key, spelling in _literal_key_reads(scope):
                if key not in allowed and key not in derived:
                    bad.append(f"{path.relative_to(PKG)}:{lineno}: {spelling} reads {key!r}")
    return bad


class FakePost:
    def __init__(self, pages): self.pages, self.calls = list(pages), []
    def __call__(self, body):
        self.calls.append(body); return self.pages.pop(0)

class LinearClientTests(unittest.TestCase):
    def test_paginate_follows_cursor(self):
        tree, owners = _parse_selection(linear.NOTIFICATION_FIELDS)
        p1, p2 = notification_pages(tree, owners, [[("n1", "issueDue", "IssueNotification"), ("n2", "issueNewComment", "IssueNotification")],
                                                   [("n3", "issueMention", "IssueNotification"), ("n4", "pullRequestApproved", "PullRequestNotification")]])
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
        # k7, dynamic half. Nodes are GENERATED from the selection set, per concrete type, so a
        # fixture physically cannot carry a key the query never asks for; and the nodes record
        # every read however it is spelled — chained setdefault().get(), a read off a copy — so a
        # read of an unrequested field fails here wherever in the call chain it happens.
        tree, owners = _parse_selection(linear.NOTIFICATION_FIELDS)
        seen: set[str] = set()
        specs = [("n1", "pullRequestApproved", "PullRequestNotification"), ("n2", "issueDue", "IssueNotification"),
                 ("n3", "projectUpdateCreated", "ProjectNotification")]
        raw = [node_from_selection(tree, typename, owners, id=nid, type=ntype, archivedAt=None) for nid, ntype, typename in specs]
        self.assertNotIn("pullRequest", raw[1]); self.assertNotIn("issue", raw[0])     # shaped as Linear answers
        nodes = [Recording(dict(n), seen) for n in raw]
        page = {"data": {"notifications": {"nodes": nodes, "pageInfo": {"hasNextPage": False, "endCursor": None}}}}
        out = linear.LinearClient("k" * 20, post=FakePost([page])).inbox_notifications()
        self._assert_reads_within(seen, tree)
        # what comes out is what was requested: every requested leaf unchanged, derived keys from requested leaves
        for node, o in zip(raw, out):
            for k, v in node.items():
                self.assertEqual(o[k], v, f"{node['id']}.{k} was changed on the way out")
            self.assertEqual(o["pullRequestUrl"], (node.get("pullRequest") or {}).get("url"))
        self.assertEqual(out[0]["pullRequestUrl"], "<url>"); self.assertIsNone(out[1]["pullRequestUrl"])
        self.assertEqual((out[0]["title"], out[1]["title"]), ("<title>", "<title>"))

    def _assert_reads_within(self, seen: set, tree: dict):
        requested = tree_paths(tree)
        copied = sorted(k for k in seen if k.endswith(COPIED))
        self.assertFalse(copied, f"the notification was copied to a plain dict at {copied}; reads off a copy cannot be "
                                 "checked — read the node itself")
        unrequested = sorted(k for k in seen if k not in requested)
        self.assertFalse(unrequested, f"code reads notification fields the query never asks for: {unrequested}")

    def test_fixture_generator_refuses_a_key_the_query_never_requests(self):
        # k7: a fixture richer than the API is what hid the bug; the generator is the only fixture
        # source now, and it cannot be talked into an extra key.
        tree, owners = _parse_selection(linear.NOTIFICATION_FIELDS)
        with self.assertRaises(KeyError) as cm:
            node_from_selection(tree, "IssueNotification", owners, inboxUrl="https://linear.app/x/inbox")
        self.assertIn("inboxUrl", str(cm.exception))
        for n in node_from_selection(tree), node_from_selection(tree, "IssueNotification", owners, archivedAt=None):
            assert_within_selection(self, n, tree)

    def test_json_fixtures_stay_within_the_selection(self):
        # No notification page ships as a JSON file any more (they are generated), and one that is
        # re-added must still contain nothing the query does not request.
        tree = selection_tree(linear.NOTIFICATION_FIELDS)
        for path in sorted(FIX.glob("*.json")):
            data = json.loads(path.read_text())
            for node in (((data.get("data") or {}).get("notifications") or {}).get("nodes") or []):
                assert_within_selection(self, node, tree, f"{path.name}:{node.get('id')}")

    def test_selection_parser_sees_fragment_owners(self):
        tree, owners = _parse_selection(linear.NOTIFICATION_FIELDS)
        self.assertEqual(owners, {"issue": "IssueNotification", "project": "ProjectNotification", "pullRequest": "PullRequestNotification"})
        self.assertIn("url", tree["pullRequest"]); self.assertIsNone(tree["url"])

    def test_consumers_read_no_notification_field_outside_the_selection_by_any_spelling(self):
        # k7, static half: every literal key read in every consumer — linear.inbox_notifications
        # and the functions it calls, and the whole of commands/sync.py — spelled as x["k"],
        # x.get("k"), x.setdefault("k"), x.pop("k") or "k" in x, on ANY receiver (dict(n).get("k")
        # included), must be a requested field or one the consumer itself assigns.
        bad = notification_field_reads_outside_selection(selection_tree(linear.NOTIFICATION_FIELDS))
        self.assertFalse(bad, "reads of fields the notification query never requests:\n  " + "\n  ".join(bad))

    def test_static_scan_reaches_the_code_it_claims_to(self):
        # A scan over an empty scope passes vacuously; pin that it sees the real reads.
        module = ast.parse((PKG / "sources" / "linear.py").read_text())
        keys = {k for scope in _scope(module, "inbox_notifications") for _, k, _ in _literal_key_reads(scope)}
        self.assertTrue({"archivedAt", "issue", "project", "pullRequest", "url"} <= keys, keys)
        self.assertNotIn("nodes", keys)       # paginate is an envelope handler, not a consumer
        sync_mod = ast.parse((PKG / "commands" / "sync.py").read_text())
        self.assertIn("id", {k for _, k, _ in _literal_key_reads(sync_mod)})
        rec = Recording({"a": {"b": 1}}, s := set())
        rec.setdefault("a", {}).get("b"); dict(rec).get("zz"); rec["new"] = 1; rec["new"]
        self.assertEqual(s, {"a", "a.b", COPIED})

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
