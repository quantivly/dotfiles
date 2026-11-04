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

DO-754: ``find_by_identifiers`` resolves the handful of Linear keys ``reconcile.lookup_tracked``
found missing from the open-issue snapshot (which fetches only ``assigned_open``/``created_open``)
-- a closed issue is not a nonexistent one, and this is the one place that tells them apart. See
that function for the batching and the "unknown, never not_found" rule on a failed call.
"""
import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Callable

from rabota import errors

ENDPOINT = "https://api.linear.app/graphql"
PAGE_SIZE = 100
TIMEOUT_SECONDS = 60

ISSUE_FIELDS = """
  id identifier title url priority priorityLabel estimate dueDate createdAt updatedAt
  state { name type } team { key } project { id name } assignee { id displayName } creator { id }
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
# DO-875: the inverse side also selects the blocker's state -- two more fields on a request that
# already names every blocker, so `blockers` costs no second call.
Q_RELATIONS = """query($ids: [ID!]) {
  issues(first: %d, filter: { id: { in: $ids } }) {
    nodes { id relations { nodes { type relatedIssue { identifier } } }
            inverseRelations { nodes { type issue { identifier state { name type } } } } } } }""" % PAGE_SIZE
BLOCKING_RELATION_TYPE = "blocks"
# DO-875, the picture. Field names checked against Linear's live schema by `__type` introspection
# on 2026-11-04 (no key needed): `CycleFilter.isActive`/`.team.key` and `NullableCycleFilter.id`
# take `in`; `Project.status { name type }` is the project's state (the schema has no `state`
# field on Project any more), `lastUpdate` is the newest ProjectUpdate, `health` an enum
# (onTrack/atRisk/offTrack) or null. Cycle membership is a FLAT `issues` query under the SAME
# predicate as the cycles query (active, those teams), not a nested `issues` connection on each
# cycle: a nested connection is capped at a page size with no cursor to follow, and the flat one
# pages through `pages` like everything else. Not `cycle: { id: { in: <the cycle ids> } }`,
# which was the first cut: measured live 2026-11-04, that filter also matched the issues of a
# team OUTSIDE the asked set whose own active cycle `inheritedFrom` an asked cycle (9 of 836
# rows), so the exact-id guard refused a reply Linear had filtered correctly. The shared
# predicate returned the same membership (827 rows, 9 pages) with no row outside the asked
# cycles, and the guard stands on it.
CYCLE_FIELDS = "id number name startsAt endsAt team { key }"
ACTIVE_CYCLE_FILTER = "{ isActive: { eq: true }, team: { key: { in: $keys } } }"
Q_ACTIVE_CYCLES = """query($after: String, $keys: [String!]) {
  cycles(first: %d, after: $after, filter: %s) {
    nodes { %s } pageInfo { hasNextPage endCursor } } }""" % (PAGE_SIZE, ACTIVE_CYCLE_FILTER, CYCLE_FIELDS)
Q_ACTIVE_CYCLE_ISSUES = """query($after: String, $keys: [String!]) {
  issues(first: %d, after: $after, filter: { cycle: %s }) {
    nodes { identifier cycle { id } } pageInfo { hasNextPage endCursor } } }""" % (PAGE_SIZE, ACTIVE_CYCLE_FILTER)
PROJECT_FIELDS = "id name status { name type } lead { id displayName } targetDate lastUpdate { createdAt } health"
Q_PROJECTS = """query($after: String, $ids: [ID!]) {
  projects(first: %d, after: $after, filter: { id: { in: $ids } }) {
    nodes { %s } pageInfo { hasNextPage endCursor } } }""" % (PAGE_SIZE, PROJECT_FIELDS)
# DO-754: IssueFilter has no direct "identifier" field (linear.app/developers/filtering) -- an
# identifier is a team key plus issue number, and the documented filter schema combines
# alternatives with `or`, so each requested identifier becomes its own `{team, number}` branch.
# `id: {in: [...]}` accepts identifiers ("DO-751") directly: measured live on 2026-09-26, 4 keys
# (2 real, 2 missing) in 0.57 s, the missing ones simply absent. The first version ORed one
# `{team, number}` branch per key, and Linear SILENTLY IGNORED the top-level `or`: it paged the
# whole org, 4647 issues in 30.5 s. `find_by_identifiers` now also refuses any reply larger than
# what it asked for, so a filter Linear drops again reads as `unknown`, never as a crawl.
Q_BY_IDENTIFIERS = """query($after: String, $ids: [ID!]) {
  issues(first: %d, after: $after, filter: { id: { in: $ids } }) {
    nodes { identifier state { name type } completedAt }
    pageInfo { hasNextPage endCursor } } }""" % PAGE_SIZE
Q_ONE_ISSUE = """query($id: String!) { issue(id: $id) { identifier state { name type } completedAt } }"""
Q_ISSUE_STATE = """query($id: String!) { issue(id: $id) { id dueDate state { type } } }"""
Q_VIEWER = "{ viewer { id name } }"
M_ARCHIVE_ALL = """mutation($issueId: String!) {
  notificationArchiveAll(input: { issueId: $issueId }) { success } }"""
M_ARCHIVE_ONE = """mutation($id: String!) { notificationArchive(id: $id) { success } }"""
M_UNARCHIVE_ONE = """mutation($id: String!) { notificationUnarchive(id: $id) { success } }"""
M_SET_DUE = """mutation($id: String!, $due: TimelessDate) {
  issueUpdate(id: $id, input: { dueDate: $due }) { success issue { id dueDate } } }"""


@dataclass
class IssueRelations:
    """What ``LinearClient.relations`` reads in one pass (DO-875): ``by_issue`` maps an issue id to its
    ``{"blockedBy": [identifiers], "blocks": [identifiers]}``; ``blockers`` lists every issue that blocks
    one of them -- ``{"identifier", "state": {"name", "type"}}`` -- once each, in identifier order.
    Attributes, not keys: ``commands/sync.py`` is inside the static ingestion-boundary scan, which judges
    every literal key read in that function, and these are not notification fields."""
    by_issue: dict
    blockers: list


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

    def __init__(self, api_key: str, post: Callable[[dict], dict] | None = None, dry_run: bool = False):
        self._post = post or _urllib_post(api_key)
        self.dry_run = dry_run

    @classmethod
    def from_context(cls, ctx) -> "LinearClient":
        """Read the key named by the tenant's ``linear_key_env`` from ``ctx.env``; refuse when either is missing."""
        name = getattr(ctx.tenant, "linear_key_env", None)
        key = ctx.env.get(name) if name else None
        if not key:
            raise errors.Refused(f"tenant has no Linear key (env var {name or 'unset'})")
        return cls(key, dry_run=ctx.dry_run)

    def query(self, gql: str, variables: dict | None = None) -> dict:
        """POST one operation and return its ``data``; any ``errors`` in the reply is a ``RabotaError``."""
        reply = self._post({"query": gql, "variables": variables or {}})
        if "errors" in reply:
            msgs = "; ".join(str(e.get("message", "?")) for e in reply["errors"])
            raise errors.RabotaError(f"Linear query failed: {msgs}")
        if "data" not in reply:
            raise errors.RabotaError("Linear reply has neither data nor errors")
        return reply["data"]

    def pages(self, gql: str, path: list[str], variables: dict | None = None):
        """Yield each page's ``nodes`` from the connection at ``path``, following ``pageInfo.endCursor``
        until the last page -- so a caller can refuse a reply at its first page instead of after the
        walk (DO-875: a filter Linear drops must not be paged to the end of the org)."""
        after = None
        while True:
            data = self.query(gql, {**(variables or {}), "after": after})
            conn = data
            try:
                for key in path:
                    conn = conn[key]
                nodes = conn["nodes"]
                page = conn["pageInfo"]
            except (KeyError, TypeError):
                raise errors.RabotaError(f"Linear reply lacks a connection at {'.'.join(path)}") from None
            yield nodes
            if not page.get("hasNextPage"):
                return
            after = page.get("endCursor")

    def paginate(self, gql: str, path: list[str], variables: dict | None = None) -> list[dict]:
        """Collect ``nodes`` from every page of the connection at ``path``."""
        return [node for nodes in self.pages(gql, path, variables) for node in nodes]

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

    def relations(self, issue_ids: list[str]) -> IssueRelations:
        """The blocking relations of ``issue_ids`` in batches of ``PAGE_SIZE``; no ids, no call.

        ``blockers`` (DO-875) is read off the same reply that names each blocker, so "unblocked" is
        a fact of the snapshot rather than an ``issueUnblocked`` notification left in ``other``.
        """
        by_issue, blockers = {}, {}
        for start in range(0, len(issue_ids), PAGE_SIZE):
            batch = issue_ids[start:start + PAGE_SIZE]
            for node in self.query(Q_RELATIONS, {"ids": batch})["issues"]["nodes"]:
                blocks = [r["relatedIssue"]["identifier"] for r in node["relations"]["nodes"]
                          if r["type"] == BLOCKING_RELATION_TYPE]
                blocking = [r["issue"] for r in node["inverseRelations"]["nodes"] if r["type"] == BLOCKING_RELATION_TYPE]
                by_issue[node["id"]] = {"blockedBy": [b["identifier"] for b in blocking], "blocks": blocks}
                for blocker in blocking:
                    blockers[blocker["identifier"]] = {"identifier": blocker["identifier"], "state": blocker.get("state")}
        return IssueRelations(by_issue, [blockers[key] for key in sorted(blockers)])

    def active_cycles(self, team_keys: list[str]) -> list[dict]:
        """DO-875: the active cycle of each team in ``team_keys`` (distinct, sorted; none → no call),
        each carrying ``issue_identifiers``, every issue in it, in Linear's order.

        Two paged reads under one predicate: the cycles, then one flat ``issues`` query (see
        ``Q_ACTIVE_CYCLE_ISSUES`` for why neither a nested connection nor the cycle ids); no
        cycles, no second call. A cycle with no issues is still a cycle; a team without an active
        cycle has no row. A reply carrying a cycle of a team not asked for, or an issue outside
        the fetched cycles, means Linear dropped the filter (the DO-754 crawl, by another door)
        and is refused at that page.
        """
        keys = sorted(set(team_keys))
        if not keys:
            return []
        cycles = []
        for page in self.pages(Q_ACTIVE_CYCLES, ["cycles"], {"keys": keys}):
            for cycle in page:
                if (cycle.get("team") or {}).get("key") not in keys:
                    raise errors.RabotaError("Linear returned a cycle of a team not asked for: the team filter was not applied")
                cycles.append(dict(cycle, issue_identifiers=[]))
        by_id = {cycle["id"]: cycle for cycle in cycles}
        if not by_id:
            return cycles
        for page in self.pages(Q_ACTIVE_CYCLE_ISSUES, ["issues"], {"keys": keys}):
            for node in page:
                cycle = by_id.get((node.get("cycle") or {}).get("id"))
                if cycle is None:
                    raise errors.RabotaError("Linear returned an issue outside the asked cycles: the cycle filter was not applied")
                cycle["issue_identifiers"].append(node["identifier"])
        return cycles

    def projects_by_id(self, project_ids: list[str]) -> list[dict]:
        """DO-875: the projects with exactly these ids (distinct, sorted; none → no call), in
        batches of ``PAGE_SIZE`` ids, each flattened by ``_flatten_project``. A node outside the
        asked ids means Linear dropped the filter (the DO-754 crawl) and the reply is refused.
        """
        wanted = sorted(set(project_ids))
        out = []
        for start in range(0, len(wanted), PAGE_SIZE):
            batch = wanted[start:start + PAGE_SIZE]
            for page in self.pages(Q_PROJECTS, ["projects"], {"ids": batch}):
                for node in page:
                    if node.get("id") not in batch:
                        raise errors.RabotaError("Linear returned a project not asked for: the id filter was not applied")
                    out.append(_flatten_project(node))
        return out

    # mutations — callers record rollback rows before calling these
    def mutate(self, gql: str, variables: dict, result_key: str) -> dict:
        """Every Linear mutation goes through here (DO-753): with ``self.dry_run`` set, nothing is
        sent over the wire and a canned ``{"success": True}`` stands in for the reply. Callers do
        not usually need to touch this directly — it exists so a caller that DOES build a real
        client on a dry path (rather than skipping the client entirely, as ``inbox.py`` does) still
        cannot mutate Linear by accident.
        """
        if self.dry_run:
            return {"success": True}
        return self.query(gql, variables)[result_key]

    def archive_notifications_for_issue(self, issue_id: str) -> dict:
        return self.mutate(M_ARCHIVE_ALL, {"issueId": issue_id}, "notificationArchiveAll")

    def archive_notification(self, notification_id: str) -> dict:
        return self.mutate(M_ARCHIVE_ONE, {"id": notification_id}, "notificationArchive")

    def unarchive_notification(self, notification_id: str) -> dict:
        return self.mutate(M_UNARCHIVE_ONE, {"id": notification_id}, "notificationUnarchive")

    def set_due_date(self, issue_id: str, due_date: str | None) -> dict:
        return self.mutate(M_SET_DUE, {"id": issue_id, "due": due_date}, "issueUpdate")

    def issue_state_and_due(self, issue_id: str) -> dict:
        return self.query(Q_ISSUE_STATE, {"id": issue_id})["issue"]

    def find_by_identifiers(self, identifiers: list[str]) -> list[dict]:
        """DO-754: resolve exactly these Linear identifiers (``HUB-5812`` shape) in ONE batched,
        read-only query -- for a key ``sync``'s open-issue fetch left ``not_found``, telling
        "closed" apart from "never existed". Cost: one HTTP round trip no matter how many
        identifiers are asked for (a turn-2 classification pass names single digits of subjects at
        a time; pagination only bites past ``PAGE_SIZE`` matches, which this never approaches in
        practice). The identifiers go in one ``id: {in: [...]}`` filter -- see ``Q_BY_IDENTIFIERS``
        for why not an ``or`` of per-key branches. Returns one
        ``{"identifier", "state", "completedAt"}`` per issue Linear actually has; an identifier
        missing from the return really does not exist, as far as this query can tell."""
        if not identifiers:
            return []
        wanted = sorted(set(identifiers))
        data = self.query(Q_BY_IDENTIFIERS, {"ids": wanted, "after": None})
        conn = (data or {}).get("issues") or {}
        nodes = conn.get("nodes")
        if not isinstance(nodes, list):
            raise errors.RabotaError("Linear reply lacks issues.nodes")
        # One page is always enough for a handful of keys; more rows than keys, or another page,
        # means the filter was not applied, and the answer cannot be trusted.
        if len(nodes) > len(wanted) or (conn.get("pageInfo") or {}).get("hasNextPage"):
            raise errors.RabotaError(f"Linear returned {len(nodes)} issues for {len(wanted)} identifiers: "
                                     "the identifier filter was not applied")
        rec = lambda n, asked: {"identifier": n["identifier"], "asked": asked, "state": n["state"],
                                "completedAt": n.get("completedAt")}
        out = [rec(n, n["identifier"]) for n in nodes if n.get("identifier") in wanted]
        # A node under an identifier nobody asked for is an issue moved between teams, answering one
        # of the keys still unmatched (DO-754 review F2: dropping it made a moved-and-closed issue
        # read not_found). The batch cannot say which key it answers, so each unmatched key is
        # resolved with `issue(id:)`, which accepts an old identifier. This is only paid when a
        # moved issue actually appears. "Entity not found" is a real absence; any other error
        # propagates.
        if any(n.get("identifier") not in wanted for n in nodes):
            matched = {r["asked"] for r in out}
            for key in (k for k in wanted if k not in matched):
                reply = self._post({"query": Q_ONE_ISSUE, "variables": {"id": key}})
                errs = reply.get("errors") or []
                if any("not found" in str(e.get("message", "")).lower() for e in errs):
                    continue
                if errs or "data" not in reply:
                    raise errors.RabotaError(f"Linear lookup of {key} failed: "
                                             + "; ".join(str(e.get("message", "?")) for e in errs))
                if reply["data"].get("issue"):
                    out.append(rec(reply["data"]["issue"], key))
        return out


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


def _flatten_project(project: dict) -> dict:
    """Snapshot shape for a project: the selected fields verbatim, with ``lastUpdate { createdAt }``
    flattened to ``lastUpdateAt`` (null when the project has never had an update) so a reader has
    one key for "when was this last updated"."""
    project = dict(project)
    project["lastUpdateAt"] = (project.pop("lastUpdate", None) or {}).get("createdAt")
    return project
