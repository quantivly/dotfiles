"""Linear over raw GraphQL, with an injectable ``post`` so tests use fixtures.

Schema notes (WS2 task 2.1 step 1). The notification selection set was checked against
Linear's live schema on 2026-09-17 with ``__type`` introspection, which answers HTTP 200
with no Authorization header at all (output in ``out/ws2/FIX-ACCEPTANCE.md``):

- ``url``, ``title``, ``subtitle`` and ``groupingKey`` are fields of the ``Notification``
  interface, so every concrete type carries them. The first version of this module never
  selected them, and a fixture that supplied them kept the suite green while every live
  notification came back with ``pullRequestUrl``/``url``/``title`` null (review finding k7).
- ``PullRequestNotification`` exposes ``pullRequest { url title number }``;
  ``IssueNotification`` exposes ``issue`` and ``ProjectNotification`` exposes ``project``.
  ``pullRequestUrl`` is the PR object's ``url`` and nothing else: measured live, every
  ``pullRequest*`` notification carries the object, and the notification's own ``url`` is
  Linear's inbox link (``linear.app/…/review/…``), not the GitHub PR.
- Relation direction is still the plan's reading, unverified against a known pair: an
  ``IssueRelation`` of type ``blocks`` on issue A with ``relatedIssue`` B is read as "A blocks
  B", so A's ``relations`` are what A blocks and A's ``inverseRelations`` are what blocks A.
  If a live check says otherwise, swap the two comprehensions in ``relations``.

DO-735: ``attachments`` (checked against Linear's published GraphQL docs, not the live API — see
that issue for why). ``linear.app/developers/attachments`` documents ``url``, ``title``,
``subtitle`` and a free-form ``metadata`` object as the fields every attachment carries, and says
metadata is "key-value... any string or number... related to your integration" with no schema
Linear commits to for its own GitHub integration's PRs — so a PR's merged/open/closed state is
NOT reliably in it, and this module does not select or read it. ``sourceType`` (confirmed via a
real ``attachment(id)`` query shown in third-party API docs, alongside ``source``) is the one
reliable discriminator for "this attachment came from the GitHub integration"; PR vs. plain GitHub
Issue is then read off the URL path (``/pull/<n>`` vs. ``/issues/<n>``), never off metadata.
``ISSUE_FIELDS`` selects only ``url`` and ``sourceType`` — enough to tell "a PR is linked" and
which one, never enough to tell its state; ``reconcile.py`` fills state in from ``sources/github.json``
where it can (see that module) and otherwise reports "linked, state unknown" rather than guessing.
Review finding F1: ``reconcile._pr_links`` no longer reads ``sourceType`` to decide whether an
attachment is a PR link at all — the URL path alone (``/pull/<n>``) is sourceType-agnostic and
sufficient, since a live tenant has GitHub ``/pull/`` attachments whose ``sourceType`` is ``api``
or ``oauthClient``, not ``github``. ``sourceType`` is kept selected here only as descriptive
metadata on the raw snapshot (e.g. telling a plain GitHub Issue link apart from a Sentry one at a
glance); nothing in this codebase reads it for a decision any more.

Review finding F3: ``attachments`` has no ``first:`` argument, so Linear's default page size (50)
silently caps a very-attached issue with no signal that it happened. ``first: 50`` makes that cap
explicit rather than accidental, and ``pageInfo { hasNextPage }`` is selected so ``_flatten`` can
record when it was reached (``attachments_capped``) rather than reading a truncated list as
complete — cheap because it costs one more field in the same request, never a second network call
per issue. Measured live, the most any issue carries is 2, so the cap is not expected to bite; if
it ever does, the fix is genuine pagination, not a bigger arbitrary number.

The key is passed only as an HTTP header. It is never logged, never formatted into an
exception, and never part of a reply; ``query`` raises with Linear's own messages only.
"""
import json
import urllib.error
import urllib.request
from typing import Callable

from rabota import errors

ENDPOINT = "https://api.linear.app/graphql"
PAGE_SIZE = 100
TIMEOUT_SECONDS = 60

ISSUE_FIELDS = """
  id identifier title url priority priorityLabel estimate dueDate createdAt updatedAt
  state { name type } team { key } project { name } assignee { id displayName } creator { id }
  labels { nodes { name } } attachments(first: 50) { nodes { url sourceType } pageInfo { hasNextPage } }
"""
NOTIFICATION_FIELDS = """
  id type createdAt readAt archivedAt snoozedUntilAt url title subtitle groupingKey
  actor { id displayName }
  ... on IssueNotification {
    issue { id identifier dueDate assignee { id } state { name type } team { key } }
  }
  ... on ProjectNotification { project { id name } }
  ... on PullRequestNotification { pullRequest { url title number } }
"""
Q_ASSIGNED = """query($after: String, $dead: [String!]) {
  issues(first: %d, after: $after, orderBy: updatedAt,
         filter: { assignee: { isMe: { eq: true } }, state: { type: { nin: $dead } } }) {
    nodes { %s } pageInfo { hasNextPage endCursor } } }""" % (PAGE_SIZE, ISSUE_FIELDS)
Q_CREATED = """query($after: String, $dead: [String!], $me: ID!) {
  issues(first: %d, after: $after, orderBy: updatedAt,
         filter: { creator: { id: { eq: $me } }, state: { type: { nin: $dead } } }) {
    nodes { %s } pageInfo { hasNextPage endCursor } } }""" % (PAGE_SIZE, ISSUE_FIELDS)
Q_NOTIFICATIONS = """query($after: String) {
  notifications(first: %d, after: $after) {
    nodes { %s } pageInfo { hasNextPage endCursor } } }""" % (PAGE_SIZE, NOTIFICATION_FIELDS)
Q_RELATIONS = """query($ids: [ID!]) {
  issues(first: %d, filter: { id: { in: $ids } }) {
    nodes { id relations { nodes { type relatedIssue { identifier } } }
            inverseRelations { nodes { type issue { identifier } } } } } }""" % PAGE_SIZE
Q_ISSUE_STATE = """query($id: String!) { issue(id: $id) { id dueDate state { type } } }"""
Q_VIEWER = "{ viewer { id name } }"
M_ARCHIVE_ALL = """mutation($issueId: String!) {
  notificationArchiveAll(input: { issueId: $issueId }) { success } }"""
M_ARCHIVE_ONE = """mutation($id: String!) { notificationArchive(id: $id) { success } }"""
M_UNARCHIVE_ONE = """mutation($id: String!) { notificationUnarchive(id: $id) { success } }"""
M_SET_DUE = """mutation($id: String!, $due: TimelessDate) {
  issueUpdate(id: $id, input: { dueDate: $due }) { success issue { id dueDate } } }"""


def _urllib_post(api_key: str) -> Callable[[dict], dict]:
    """Return a transport that POSTs a GraphQL body with ``api_key`` as the Authorization header.

    Transport failures come back as a reply carrying ``errors`` so that ``query`` has one
    failure path. Linear answers 400 with no ``errors`` array for a bad selection set, so
    the status code is what there is to report; the key is never part of the message.
    """
    def post(body: dict) -> dict:
        req = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(),
                                     headers={"Authorization": api_key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            return {"errors": [{"message": f"HTTP {e.code} from Linear (selection set or auth)"}]}
        except urllib.error.URLError as e:
            return {"errors": [{"message": f"cannot reach Linear: {e.reason}"}]}
        except json.JSONDecodeError as e:
            return {"errors": [{"message": f"Linear reply is not JSON: {e.msg}"}]}
    return post


class LinearClient:
    """One Linear identity: ``query`` and ``paginate`` over an injectable transport, plus the named reads and mutations."""

    def __init__(self, api_key: str, post: Callable[[dict], dict] | None = None):
        self._post = post or _urllib_post(api_key)

    @classmethod
    def from_context(cls, ctx) -> "LinearClient":
        """Read the key named by the tenant's ``linear_key_env`` from ``ctx.env``; refuse when either is missing."""
        name = getattr(ctx.tenant, "linear_key_env", None)
        key = ctx.env.get(name) if name else None
        if not key:
            raise errors.Refused(f"tenant has no Linear key (env var {name or 'unset'})")
        return cls(key)

    def query(self, gql: str, variables: dict | None = None) -> dict:
        """POST one operation and return its ``data``; any ``errors`` in the reply is a ``RabotaError``."""
        reply = self._post({"query": gql, "variables": variables or {}})
        if "errors" in reply:
            msgs = "; ".join(str(e.get("message", "?")) for e in reply["errors"])
            raise errors.RabotaError(f"Linear query failed: {msgs}")
        if "data" not in reply:
            raise errors.RabotaError("Linear reply has neither data nor errors")
        return reply["data"]

    def paginate(self, gql: str, path: list[str], variables: dict | None = None) -> list[dict]:
        """Collect ``nodes`` from the connection at ``path``, following ``pageInfo.endCursor`` until the last page."""
        nodes, after = [], None
        while True:
            data = self.query(gql, {**(variables or {}), "after": after})
            conn = data
            try:
                for key in path:
                    conn = conn[key]
                nodes.extend(conn["nodes"])
                page = conn["pageInfo"]
            except (KeyError, TypeError):
                raise errors.RabotaError(f"Linear reply lacks a connection at {'.'.join(path)}") from None
            if not page.get("hasNextPage"):
                return nodes
            after = page.get("endCursor")

    def viewer(self) -> dict:
        return self.query(Q_VIEWER)["viewer"]

    def assigned_open(self, dead_types: list[str]) -> list[dict]:
        """Issues assigned to the key's user whose state type is not in ``dead_types``."""
        return [_flatten(i) for i in self.paginate(Q_ASSIGNED, ["issues"], {"dead": dead_types})]

    def created_open(self, viewer_id: str, dead_types: list[str]) -> list[dict]:
        """Issues created by ``viewer_id`` whose state type is not in ``dead_types``."""
        return [_flatten(i) for i in self.paginate(Q_CREATED, ["issues"], {"dead": dead_types, "me": viewer_id})]

    def inbox_notifications(self) -> list[dict]:
        """Every non-archived notification, read or unread, normalised to the snapshot shape."""
        out = []
        for n in self.paginate(Q_NOTIFICATIONS, ["notifications"]):
            if n.get("archivedAt"):
                continue
            n.setdefault("issue", None)
            n.setdefault("project", None)
            n["pullRequestUrl"] = (n.setdefault("pullRequest", None) or {}).get("url")
            out.append(n)
        return out

    def relations(self, issue_ids: list[str]) -> dict[str, dict]:
        """Map issue id → ``{"blockedBy": [identifiers], "blocks": [identifiers]}`` in batches of ``PAGE_SIZE``."""
        rel = {}
        for start in range(0, len(issue_ids), PAGE_SIZE):
            batch = issue_ids[start:start + PAGE_SIZE]
            for node in self.query(Q_RELATIONS, {"ids": batch})["issues"]["nodes"]:
                blocks = [r["relatedIssue"]["identifier"] for r in node["relations"]["nodes"] if r["type"] == "blocks"]
                blocked_by = [r["issue"]["identifier"] for r in node["inverseRelations"]["nodes"] if r["type"] == "blocks"]
                rel[node["id"]] = {"blockedBy": blocked_by, "blocks": blocks}
        return rel

    # mutations — callers record rollback rows before calling these
    def archive_notifications_for_issue(self, issue_id: str) -> dict:
        return self.query(M_ARCHIVE_ALL, {"issueId": issue_id})["notificationArchiveAll"]

    def archive_notification(self, notification_id: str) -> dict:
        return self.query(M_ARCHIVE_ONE, {"id": notification_id})["notificationArchive"]

    def unarchive_notification(self, notification_id: str) -> dict:
        return self.query(M_UNARCHIVE_ONE, {"id": notification_id})["notificationUnarchive"]

    def set_due_date(self, issue_id: str, due_date: str | None) -> dict:
        return self.query(M_SET_DUE, {"id": issue_id, "due": due_date})["issueUpdate"]

    def issue_state_and_due(self, issue_id: str) -> dict:
        return self.query(Q_ISSUE_STATE, {"id": issue_id})["issue"]


def _flatten(issue: dict) -> dict:
    """Snapshot shape: ``labels`` as names, ``attachments`` as a plain list (plus
    ``attachments_capped``, F3 — ``True`` when the ``first: 50`` page has more attachments than
    were fetched, never guessed at from the list's length), and empty relation lists until
    ``relations`` fills them."""
    issue = dict(issue)
    issue["labels"] = [label["name"] for label in (issue.get("labels") or {}).get("nodes", [])]
    raw_attachments = issue.get("attachments") or {}
    issue["attachments_capped"] = bool((raw_attachments.get("pageInfo") or {}).get("hasNextPage"))
    issue["attachments"] = [{"url": a.get("url"), "sourceType": a.get("sourceType")}
                             for a in raw_attachments.get("nodes", [])]
    issue.setdefault("blockedBy", [])
    issue.setdefault("blocks", [])
    return issue
