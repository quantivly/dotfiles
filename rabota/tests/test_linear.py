import ast, copy, json, re, shutil, tempfile, unittest
from pathlib import Path
from rabota import errors
from rabota.cli import COMMAND_MODULES
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
    after the assignment and the k7 bug before it). Enumerating the node — ``keys()``, ``items()``,
    ``values()``, iteration — is noted as ``COPIED`` too: it hands the code every key, including ones
    the fixture does not carry, so nothing about it can be checked. ``json.dumps``, ``copy.copy`` and
    ``copy.deepcopy`` all walk a dict subclass through ``items()`` and are therefore copies (E-B/E-D).
    The one legitimate serialiser in the tracked region is the snapshot write, and it is a boundary,
    not a read: a test that routes nodes through it wraps the writer with ``plain``.
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
    def items(self):
        self._seen.add(self._prefix + COPIED); return super().items()
    def values(self):
        self._seen.add(self._prefix + COPIED); return super().values()
    def copy(self):
        self._seen.add(self._prefix + COPIED); return dict(super().items())

    @classmethod
    def plain(cls, value):
        """``value`` with every Recording node replaced by a plain dict, noting nothing — the serialiser boundary."""
        if isinstance(value, dict):
            return {k: cls.plain(v) for k, v in dict.items(value)}
        if isinstance(value, list):
            return [cls.plain(v) for v in value]
        return value


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
# Envelope handlers: they read the GraphQL reply (``data``, ``nodes``, ``pageInfo``), never a node's
# fields, and they serve every query at once. The dynamic rows still route Recording nodes through them.
ENVELOPE_FUNCTIONS = {"query", "paginate"}
SNAPSHOT_KEY = "notifications"          # the key a consumer reads the nodes off (the snapshot, or sync's payload)
SOURCE_FUNCTION = "inbox_notifications"  # the one function that builds them


def _literal_key_reads(func_or_module) -> list[tuple[int, str, str]]:
    """``(lineno, key, spelling)`` for every string-literal key read in the AST node: ``x["k"]``, ``x.get("k")``,
    ``x.setdefault("k")``, ``x.pop("k")``, ``dict.get(x, "k")``, ``"k" in x`` — whatever the receiver is
    (``dict(n).get`` included)."""
    out = []
    for node in ast.walk(func_or_module):
        if isinstance(node, ast.Subscript) and isinstance(node.slice, ast.Constant) and isinstance(node.slice.value, str) \
                and isinstance(node.ctx, ast.Load):
            out.append((node.lineno, node.slice.value, "[]"))
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ("get", "setdefault", "pop"):
            # the key is args[0] in ``n.get("k")`` and args[1] in the unbound ``dict.get(n, "k")`` (E-C): take the
            # first string literal among the first two positionals — a bound call's string default is only
            # reached when there is no literal key before it, which is exactly the unbound shape.
            key = next((a.value for a in node.args[:2] if isinstance(a, ast.Constant) and isinstance(a.value, str)), None)
            if key is not None:
                out.append((node.lineno, key, f".{node.func.attr}()"))
        elif isinstance(node, ast.Compare) and isinstance(node.left, ast.Constant) and isinstance(node.left.value, str) \
                and any(isinstance(op, (ast.In, ast.NotIn)) for op in node.ops):
            out.append((node.lineno, node.left.value, "in"))
    return out


def _literal_key_writes(func_or_module) -> set[str]:
    return {n.slice.value for n in ast.walk(func_or_module) if isinstance(n, ast.Subscript) and isinstance(n.ctx, ast.Store)
            and isinstance(n.slice, ast.Constant) and isinstance(n.slice.value, str)}


def _mentions_notifications(node: ast.AST) -> bool:
    """Does this code name the notifications — the snapshot key, or a call to the source function?"""
    for n in ast.walk(node):
        if isinstance(n, ast.Constant) and n.value == SNAPSHOT_KEY:
            return True
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == SOURCE_FUNCTION:
            return True
    return False


def _callee(call: ast.Call) -> str | None:
    return call.func.attr if isinstance(call.func, ast.Attribute) else getattr(call.func, "id", None)


def _tainted_names(func: ast.AST, in_scope: set[str], params_tainted: bool) -> set[str]:
    """Names in ``func`` bound from a notification source: a ``"notifications"`` read, a call to an
    in-scope function, or another such name — through assignment, ``for`` and comprehension targets."""
    def tainted(expr: ast.AST) -> bool:
        return any((isinstance(n, ast.Name) and n.id in names)
                   or (isinstance(n, ast.Call) and _callee(n) in in_scope) for n in ast.walk(expr)) or _mentions_notifications(expr)
    def targets(t: ast.AST) -> set[str]:
        return {n.id for n in ast.walk(t) if isinstance(n, ast.Name)}
    names = {a.arg for a in ast.walk(func) if isinstance(a, ast.arg)} if params_tainted else set()
    while True:
        before = len(names)
        for n in ast.walk(func):
            if isinstance(n, (ast.Assign, ast.AnnAssign, ast.AugAssign)) and n.value is not None and tainted(n.value):
                names |= set().union(*(targets(t) for t in (n.targets if isinstance(n, ast.Assign) else [n.target])))
            elif isinstance(n, (ast.For, ast.AsyncFor, ast.comprehension)) and tainted(n.iter):
                names |= targets(n.target)
        if len(names) == before:
            return names


def _notification_scopes(module: ast.Module) -> list[ast.AST]:
    """The AST nodes that can hold a notification node, so the only ones whose literal key reads are
    the guard's business. Entries are the functions that name the notifications (the snapshot key or
    the source function); the scope grows upward to every function that calls one, transitively, and
    downward to every function handed a name bound from such a source. A function that never holds a
    notification — a renderer reading ``plan.get("totals")`` — is left alone, which is what makes the
    scan runnable over every command module without a list of exceptions. A module whose top-level
    code names the key is scanned whole."""
    defs = {n.name: n for n in ast.walk(module) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
    top_level = [s for s in ast.walk(module) if isinstance(s, (ast.Module, ast.ClassDef))
                 for s in s.body if not isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))]
    if any(_mentions_notifications(s) for s in top_level):
        return [module]
    entries = {name for name, d in defs.items() if name not in ENVELOPE_FUNCTIONS and _mentions_notifications(d)}
    up, down = set(entries), set()
    while True:
        before = (len(up), len(down))
        for name, d in defs.items():                                  # callers of an entry or of a caller
            if name not in up and name not in ENVELOPE_FUNCTIONS and any(_callee(c) in up for c in ast.walk(d) if isinstance(c, ast.Call)):
                up.add(name)
        for name in list(up | down):                                  # callees handed a notification-derived name
            tainted = _tainted_names(defs[name], up | down, params_tainted=name in down)
            for c in ast.walk(defs[name]):
                if isinstance(c, ast.Call) and _callee(c) in defs and _callee(c) not in ENVELOPE_FUNCTIONS \
                        and any(isinstance(n, ast.Name) and n.id in tainted for a in c.args for n in ast.walk(a)):
                    down.add(_callee(c))
        if (len(up), len(down)) == before:
            return [defs[n] for n in sorted(up | down, key=lambda n: defs[n].lineno)]


def scanned_consumers(pkg: Path = PKG) -> list[tuple[Path, list[ast.AST]]]:
    """``(module path, scopes)`` for every module that may hold a notification: the source that builds
    them and every command module on disk — discovered, never listed, so a new consumer cannot be
    missed by omission (k7 round 4). The registry is a subset of the disk by construction; a test pins it."""
    paths = [pkg / "sources" / "linear.py", *sorted(p for p in (pkg / "commands").glob("*.py") if p.name != "__init__.py")]
    return [(path, _notification_scopes(ast.parse(path.read_text(), str(path)))) for path in paths]


def notification_field_reads_outside_selection(tree: dict, pkg: Path = PKG) -> list[str]:
    """Every literal key read in a consumer that is neither requested nor assigned by that consumer."""
    allowed = tree_names(tree)
    bad = []
    for path, scopes in scanned_consumers(pkg):
        derived = set().union(*(_literal_key_writes(s) for s in scopes)) if scopes else set()
        for scope in scopes:
            for lineno, key, spelling in _literal_key_reads(scope):
                if key not in allowed and key not in derived:
                    bad.append(f"{path.relative_to(pkg)}:{lineno}: {spelling} reads {key!r}")
    return bad


# A throwaway consumer for the guard's own control — the round-4 gate's E-A/E-I shape. Never a real
# command: it is written into a COPY of the package by the test that uses it.
INBOXPEEK = '''\
"""Peek at the inbox: reads the snapshot's notifications (the guard's own control, not a command)."""
import json
from rabota import cli, snapshots
from rabota.context import Context


def _notes(snap):
    return snap["notifications"]                       # the only mention of the key: run_inboxpeek CALLS this


def inbox_link(n):
    return json.loads(json.dumps(n))["emailedAt"]     # E-I: a helper the consumer hands the node to, round trip first


def _render(plan):
    return plan.get("totals")                         # holds no notification: reads here are not the guard's business


def run_inboxpeek(ctx):
    snap = snapshots.read(ctx.state_dir, "linear")
    links = [(n.get("inboxUrl"), (n.get("issue") or {}).get("title"), inbox_link(n)) for n in _notes(snap)]
    return {"links": links, "unsnoozed": [n["unsnoozedAt"] for n in _notes(snap)], "plan": _render({})}


cli.register("inboxpeek", lambda sub: sub.add_parser("inboxpeek"), lambda ns: run_inboxpeek(Context.from_namespace(ns)))
'''


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

    def test_no_notification_page_ships_as_a_json_fixture(self):
        # k7 round 4: the JSON pages were deleted in round 3 and the row that checked them kept
        # globbing the absent directory — a check with nothing to check, passing on zero files. The
        # design decision it was standing in for is pinned directly instead: notification pages are
        # GENERATED from the selection set (``node_from_selection`` / ``notification_pages``), so a
        # fixture physically cannot carry a key the query never requests. A JSON page re-added here
        # fails this row, whatever it contains — a fixture richer than the API is how k7 hid.
        shipped = sorted(str(p.relative_to(FIX.parent)) for p in FIX.rglob("*.json")) if FIX.exists() else []
        self.assertEqual(shipped, [], "notification pages are generated from the selection set, never shipped as JSON: "
                                      f"remove {shipped} and build the page with notification_pages()")

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

    def test_static_scan_discovers_every_command_module_and_the_source(self):
        # k7 round 4 (E-A): the scan used to read a two-entry hand list, so a consumer the list did
        # not name was invisible by construction. It is discovered now — the source that builds
        # notification nodes plus every command module on disk — and the registry can never name a
        # module the scan misses.
        scanned = {path: scopes for path, scopes in scanned_consumers()}
        self.assertIn(PKG / "sources" / "linear.py", scanned)
        registered = {PKG / "commands" / f"{m}.py" for m in COMMAND_MODULES if (PKG / "commands" / f"{m}.py").exists()}
        self.assertTrue(registered, "no registered command module exists on disk — the coupling row has nothing to check")
        self.assertLessEqual(registered, set(scanned), "a registered command module is not scanned")
        on_disk = {p for p in (PKG / "commands").glob("*.py") if p.name != "__init__.py"}
        self.assertLessEqual(on_disk, set(scanned), "a command module on disk is not scanned")
        # and the scan reaches the code it must: not a vacuous scope over the two real consumers
        names = lambda path: {getattr(s, "name", "<module>") for s in scanned[path]}
        self.assertEqual(names(PKG / "sources" / "linear.py"), {"inbox_notifications"})
        self.assertLessEqual({"sync_linear", "_sync_one", "run_sync"}, names(PKG / "commands" / "sync.py"))

    def test_a_new_command_module_reading_an_unrequested_field_fails_the_guard(self):
        # k7 round 4, the control for E-A/E-I: a module dropped into commands/ that reads a field the
        # query never requests — in the function that loads the notifications, in a caller of it,
        # and in a helper it hands the node to after a json round trip — is caught by the static
        # half without anyone adding it to a list. A function that never holds a notification is
        # not scanned, so its reads of other shapes (``plan.get("totals")``) are not false positives.
        with tempfile.TemporaryDirectory() as tmp:
            pkg = Path(tmp) / "rabota"
            shutil.copytree(PKG, pkg, ignore=shutil.ignore_patterns("__pycache__"))
            (pkg / "commands" / "inboxpeek.py").write_text(INBOXPEEK)
            bad = notification_field_reads_outside_selection(selection_tree(linear.NOTIFICATION_FIELDS), pkg)
            peek = [b for b in bad if b.startswith("commands/inboxpeek.py:")]
            self.assertEqual(bad, peek, f"the real package must stay clean under the discovered scan: {bad}")
            self.assertTrue(any(".get() reads 'inboxUrl'" in b for b in peek), peek)      # E-A, in the caller of the loader
            self.assertTrue(any("[] reads 'unsnoozedAt'" in b for b in peek), peek)       # same function, [] spelling
            self.assertTrue(any("[] reads 'emailedAt'" in b for b in peek), peek)         # E-I, helper handed the node
            self.assertFalse([b for b in peek if "totals" in b], f"a function holding no notification was scanned: {peek}")

    def test_static_scan_sees_the_unbound_method_spelling(self):
        # k7 round 4 (E-C): ``dict.get(n, "inboxUrl")`` is the same read as ``n.get("inboxUrl")`` with
        # the receiver moved into the argument list, so the key is ``args[1]``; the matcher assumed
        # ``args[0]`` and let it through. Whichever positional argument is the string literal is the
        # key — but a bound call's string DEFAULT is not: ``n.get("type", "unknown")`` reads ``type``.
        src = ast.parse(
            'a = dict.get(n, "inboxUrl")\n'
            'b = Recording.setdefault(n, "emailedAt", {})\n'
            'c = dict.pop(n, "unsnoozedAt", None)\n'
            'd = n.get("type", "unknown")\n'
            'e = n.get(k, "fallback")\n')
        reads = {(k, sp) for _, k, sp in _literal_key_reads(src)}
        self.assertLessEqual({("inboxUrl", ".get()"), ("emailedAt", ".setdefault()"), ("unsnoozedAt", ".pop()"), ("type", ".get()")}, reads)
        self.assertNotIn(("unknown", ".get()"), reads, "a bound call's string default is not a key")
        self.assertIn(("fallback", ".get()"), reads, "with no literal key, the second literal is reported: it may be the unbound form")

    def test_recording_notes_enumeration_as_a_copy(self):
        # k7 round 4 (E-B/E-D): ``keys()`` and iteration were noted as a copy, ``items()`` and
        # ``values()`` were not — and ``json.dumps``, ``copy.copy`` and ``copy.deepcopy`` all walk a
        # dict subclass through ``items()``, so a round trip to a plain dict and a read off THAT was
        # invisible. Enumerating the node hands the code every key, including ones the fixture does
        # not carry, so it is noted as COPIED — the same verdict as ``keys()`` — and the dynamic
        # assertion fails rather than not know. Recording the iterated keys instead would be
        # vacuous: every key a generated node carries is requested, so nothing would ever be noted.
        tree, owners = _parse_selection(linear.NOTIFICATION_FIELDS)
        evasions = {
            "items": lambda n: [v for k, v in n.items() if k == "inboxUrl"],
            "next(iter(items))": lambda n: next(iter(n.items())),
            "values": lambda n: list(n.values()),
            "json round trip, computed key": lambda n: json.loads(json.dumps(n)).get("inbox" + "Url"),
            "copy.copy": lambda n: copy.copy(n).get("inboxUrl"),
            "copy.deepcopy": lambda n: copy.deepcopy(n).get("inboxUrl"),
        }
        for name, read in evasions.items():
            seen: set[str] = set()
            read(Recording(node_from_selection(tree, "IssueNotification", owners, id="n1"), seen))
            self.assertIn(COPIED, seen, f"{name}: enumerating the node was not noted as a copy")
            with self.assertRaises(AssertionError, msg=f"{name} passed the dynamic assertion"):
                self._assert_reads_within(seen, tree)
        # the nested wrapper reports its own path
        seen = set()
        list(Recording({"issue": {"id": 1}}, seen)["issue"].items())
        self.assertEqual(seen, {"issue", "issue." + COPIED})

    def test_recording_plain_is_the_serialiser_boundary_and_notes_nothing(self):
        # A snapshot write serialises the node, which is where the tracked region ENDS by design —
        # everything downstream reads plain dicts and is the static half's business. The boundary
        # is explicit: ``plain`` converts without noting a read, and a test that routes Recording
        # nodes through a real snapshot write wraps the writer with it. Nothing else may bypass the
        # wrapper: ``plain`` is the only way to enumerate a Recording node silently.
        seen: set[str] = set()
        node = Recording({"id": "n1", "issue": {"id": "i1", "state": {"type": "x"}}, "n": [{"k": 1}]}, seen)
        node["issue"]                                       # wrap the child first, so a nested Recording is exercised
        out = Recording.plain({"ok": True, "notifications": [node]})
        self.assertEqual(out, {"ok": True, "notifications": [{"id": "n1", "issue": {"id": "i1", "state": {"type": "x"}}, "n": [{"k": 1}]}]})
        self.assertEqual(seen, {"issue"})
        self.assertIs(type(out["notifications"][0]), dict); self.assertIs(type(out["notifications"][0]["issue"]), dict)

    def test_static_scan_reaches_the_code_it_claims_to(self):
        # A scan over an empty scope passes vacuously; pin that it sees the real reads.
        module = ast.parse((PKG / "sources" / "linear.py").read_text())
        keys = {k for scope in _notification_scopes(module) for _, k, _ in _literal_key_reads(scope)}
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
