"""Classify unread inbox notifications. First match wins; order is the spec table.

Bucket 2 (``confirm_required``) and bucket 1 (``dead_issue``) collide on a notification
about an already-closed issue in a ``confirm_teams`` team: the spec's Global Constraints
say such an issue "goes to confirm_required" absolutely, but the bucket table puts
``dead_issue`` first and first match wins. Implemented as the table orders it — a closed
issue is ``dead_issue``/auto regardless of its team — because archiving a notification
about an issue that is already closed is harmless and rollback-able, and the table (which
the tests are written against) is more specific than the prose. See
``test_confirm_teams_dead_issue_collision`` and the WS3 verdict's ``notes``.
"""
from collections import Counter
from dataclasses import dataclass, asdict
from datetime import date, datetime, timedelta
from rabota.store import now

HUMAN_ASK_TYPES = frozenset({"issueMention", "issueCommentMention", "issueNewComment", "pullRequestCommentMention",
                             "pullRequestCommented", "pullRequestReviewRequested", "pullRequestMention"})
PROJECT_TYPES = frozenset({"projectUpdatePrompt", "projectUpdateCreated"})
BUCKET_ORDER = ["dead_issue", "confirm_required", "own_pr_merged", "own_pr_approved_open", "reply_queue",
                "assignment_new", "due_reminder", "project_prompt", "other"]


@dataclass
class Item:
    notification_id: str
    type: str
    bucket: str
    tier: str
    reason: str
    issue_id: str | None
    issue_identifier: str | None
    issue_team: str | None
    pr_url: str | None
    actor: str | None
    created_at: str
    url: str | None
    title: str | None

    def to_json(self):
        return asdict(self)


def _item(n, bucket, tier, reason):
    iss = n.get("issue") or {}
    return Item(n["id"], n["type"], bucket, tier, reason, iss.get("id"), iss.get("identifier"),
                (iss.get("team") or {}).get("key"), n.get("pullRequestUrl"),
                (n.get("actor") or {}).get("displayName"), n.get("createdAt", ""), n.get("url"), n.get("title"))


def classify(linear: dict, github: dict | None, tenant, today: date) -> dict:
    """Bucket every unread notification, per the spec §C7 table (first match wins)."""
    me = (linear.get("viewer") or {}).get("id")
    rules = tenant.linear
    gh = github or {"own_prs": [], "merged_recent": []}
    merged_urls = {p["url"] for p in gh.get("merged_recent", [])}
    open_own_urls = {p["url"] for p in gh.get("own_prs", [])}
    issues_by_id = {i["id"]: i for i in linear.get("issues", [])}
    out = {b: [] for b in BUCKET_ORDER}
    unread = [n for n in linear.get("notifications", []) if not n.get("readAt") and not n.get("archivedAt")]
    for n in unread:
        t, iss = n["type"], n.get("issue")
        team = ((iss or {}).get("team") or {}).get("key")
        assignee = ((iss or {}).get("assignee") or {}).get("id")
        if iss and (iss.get("state") or {}).get("type") in rules.dead_state_types:
            out["dead_issue"].append(_item(n, "dead_issue", "auto", "issue is closed")); continue
        human_ask = t in HUMAN_ASK_TYPES and n.get("actor")
        if iss and team in rules.confirm_teams:
            out["confirm_required"].append(_item(n, "confirm_required", "confirm", f"team {team} needs confirmation")); continue
        if iss and assignee != me and not human_ask and rules.own_only_actions:
            out["confirm_required"].append(_item(n, "confirm_required", "confirm", "not your issue")); continue
        if t.startswith("pullRequest") and n.get("pullRequestUrl") in merged_urls:
            out["own_pr_merged"].append(_item(n, "own_pr_merged", "auto", "your PR is merged")); continue
        if t == "pullRequestApproved" and n.get("pullRequestUrl") in open_own_urls:
            out["own_pr_approved_open"].append(_item(n, "own_pr_approved_open", "rank", "approved; you merge")); continue
        if human_ask:
            out["reply_queue"].append(_item(n, "reply_queue", "rank", f"{t} by a human")); continue
        if t == "issueAssignedToYou":
            out["assignment_new"].append(_item(n, "assignment_new", "rank", "new assignment")); continue
        if t == "issueDue":
            live = issues_by_id.get((iss or {}).get("id"), iss or {})
            due = live.get("dueDate")
            past = due is None or date.fromisoformat(due) < today
            out["due_reminder"].append(_item(n, "due_reminder", "auto" if past else "hold",
                                             "date cleared or past" if past else f"live date {due}")); continue
        if t in PROJECT_TYPES:
            out["project_prompt"].append(_item(n, "project_prompt", "decision", "project update prompt")); continue
        out["other"].append(_item(n, "other", "list", "no rule"))
    plan = {"generated_at": now(), "tenant": tenant.name, "unread_total": len(unread),
            "buckets": {b: [i.to_json() for i in items] for b, items in out.items() if items},
            "totals": {b: len(items) for b, items in out.items() if items},
            "batches": _batches(linear, me, rules, today)}
    return plan


def _batches(linear, me, rules, today) -> dict:
    own = [i for i in linear.get("issues", []) if (i.get("assignee") or {}).get("id") == me
           and (i.get("team") or {}).get("key") not in rules.confirm_teams]
    shared = {d for d, n in Counter(i.get("dueDate") for i in own if i.get("dueDate")).items() if n >= 5}
    due_policy = []
    for i in own:
        if not i.get("dueDate"): continue
        if i["state"]["type"] == "backlog":
            due_policy.append({"id": i["id"], "identifier": i["identifier"], "dueDate": i["dueDate"], "reason": "Backlog with a due date"})
        elif i["dueDate"] in shared:
            due_policy.append({"id": i["id"], "identifier": i["identifier"], "dueDate": i["dueDate"], "reason": f"shared batch date {i['dueDate']}"})
    cutoff = (datetime.combine(today, datetime.min.time()) - timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ")
    stale = [{"id": i["id"], "identifier": i["identifier"], "updatedAt": i["updatedAt"]}
             for i in own if i["state"]["type"] == "backlog" and i["updatedAt"] < cutoff]
    return {"due_policy": {"issues": due_policy}, "stale_backlog": {"issues": stale}}


def summary_line(plan: dict, applied: dict | None) -> str:
    parts = []
    if applied and applied.get("archived"):
        detail = ", ".join(f"{n} {b.replace('_', ' ')}" for b, n in applied.get("by_bucket", {}).items())
        parts.append(f"{applied['archived']} archived ({detail})")
    proposals = [(k, len(v["issues"])) for k, v in plan.get("batches", {}).items() if v["issues"]]
    if proposals:
        parts.append(f"{len(proposals)} proposals pending (" + ", ".join(f"{n} {k.replace('_', ' ')}" for k, n in proposals) + ")")
    rq = plan["totals"].get("reply_queue", 0)
    parts.append(f"{rq} reply thread{'s' if rq != 1 else ''} ranked")
    cr = plan["totals"].get("confirm_required", 0)
    if cr: parts.append(f"{cr} need confirmation")
    return "inbox: " + ", ".join(parts)
