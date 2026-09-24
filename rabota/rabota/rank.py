"""Pure ranking over the snapshots. Buckets: 1 people blocked on you, 2 dated promises,
3 genuine P0/P1, 4 own in-flight nearest landing, 5 new work. The standing corrections from
the plans-mining ledger are encoded, not narrated: a due date shared by ``BATCH_MIN_CLUSTER``
or more issues is a batch artifact and never a deadline; a P0/P1 sitting in Backlog is a
decision, not a schedule entry; an issue a live session already names is in flight and is
not scheduled again. Every item carries the one-line rationale that put it where it is.
"""
import re
from collections import Counter
from dataclasses import dataclass
from datetime import date

from rabota.store import now

BATCH_MIN_CLUSTER = 5
NEW_WORK_CAP = 3
HOT_PRIORITIES = ("Urgent", "High")
ISSUE_KEY = re.compile(r"\b([A-Z]{2,6})-?(\d{1,5})\b", re.I)
PR_URL = re.compile(r"github\.com/([^/\s]+/[^/\s]+)/pull/(\d+)")


@dataclass
class RankInputs:
    """Everything ``rank`` reads: snapshots (``None`` when never synced), the inbox plan, census, pins, tenant, today."""
    linear: dict | None
    github: dict | None
    slack: dict | None
    inbox_plan: dict | None
    census: dict | None
    pins: list[dict]
    tenant: object
    today: date


def batch_due_dates(issues: list[dict], min_cluster: int = BATCH_MIN_CLUSTER) -> set[str]:
    """Due dates shared by at least ``min_cluster`` issues — a bulk edit, not ``min_cluster`` real deadlines."""
    counts = Counter(i.get("dueDate") for i in issues if i.get("dueDate"))
    return {d for d, n in counts.items() if n >= min_cluster}


def in_flight_keys(census: dict | None) -> set[str]:
    """Issue identifiers named by live sessions (name or cwd) or lane briefs, normalised to ``TEAM-123``."""
    keys: set[str] = set()
    if not census:
        return keys
    texts = []
    for s in census.get("sessions", []):
        texts += [s.get("name") or "", s.get("cwd") or ""]
    texts += [lane.get("brief") or "" for lane in census.get("lanes", [])]
    for text in texts:
        for m in ISSUE_KEY.finditer(text):
            keys.add(f"{m.group(1).upper()}-{m.group(2)}")
    return keys


def _item(bucket, key, title, waiting_on, why_now, rationale, url, source) -> dict:
    return {"bucket": bucket, "key": key, "title": title, "waiting_on": waiting_on, "why_now": why_now,
            "rationale": rationale, "url": url, "source": source}


def _reply_key(n: dict) -> str:
    """A reader-facing identifier for a reply-queue item: the Linear issue, else the PR it names,
    else the bare URL, else the notification's own id — never invented, but a ``pull/123`` URL is
    not an identifier, so it is reduced to the ``org/repo#123`` a reader already recognises from
    bucket 4.

    The last fallback is not decoration. ``url`` is nullable on a Linear notification, and
    returning it unguarded made the key ``None``, which ``brief`` rendered as the literal line
    ``1. None`` — strictly worse than the bare URL this change set out to replace. Every
    notification has an id, so there is always something true to print.
    """
    if n.get("issue_identifier"):
        return n["issue_identifier"]
    m = PR_URL.search(n.get("pr_url") or n.get("url") or "")
    if m:
        return f"{m.group(1)}#{m.group(2)}"
    return n.get("url") or n.get("notification_id") or "?"


def _bucket_1(inp: RankInputs, reviews: list[dict], triage: list[dict]) -> list[dict]:
    """Reply queue plus individually requested reviews, oldest first; team-derived reviews go to triage or are dropped."""
    aged: list[tuple[str, dict]] = []
    for n in (inp.inbox_plan or {}).get("buckets", {}).get("reply_queue", []):
        since = n.get("created_at") or ""
        aged.append((since, _item(1, _reply_key(n), n.get("title", ""), n.get("actor", "?"),
                                  f"{n.get('type', 'mention')} {since[:10]}, unanswered",
                                  "bucket 1: a human asked on an alive item", n.get("url"), "linear")))
    owned_teams = inp.tenant.review_routing.team_owned
    for pr in reviews:
        key = f"{pr['repo']}#{pr['number']}"
        if pr["requested_individually"]:
            aged.append((pr["updatedAt"], _item(1, key, pr["title"], pr["author"],
                                                f"review requested by name, updated {pr['updatedAt'][:10]}",
                                                "bucket 1: individually requested review", pr["url"], "github")))
        elif not any(team in owned_teams for team in pr["via_teams"]):   # an owned team's reviews are someone else's
            triage.append({"key": key, "why": f"team-derived review request via {','.join(pr['via_teams'])}",
                           "url": pr["url"]})
    return [item for _, item in sorted(aged, key=lambda pair: pair[0])]


def _bucket_2(pins: list[dict]) -> list[dict]:
    return [_item(2, p["item_key"], p.get("title", p["item_key"]), p.get("waiting_on", ""), "dated promise",
                  p.get("rationale") or "bucket 2: dated promise", p.get("url"), "pin")
            for p in pins if p.get("bucket") == 2]


def _hot_issues(own: list[dict], batch: set[str], flight: set[str], decisions: list[dict]) -> list[dict]:
    """Bucket 3 (a real date or none) and the in-flight demotions; Backlog P0/P1 become decisions instead."""
    items = []
    for i in own:
        state, prio = i["state"]["type"], i.get("priorityLabel")
        if prio not in HOT_PRIORITIES:
            continue
        if state == "backlog":
            decisions.append({"key": i["identifier"], "why": f"{prio} in Backlog — decide, do not schedule", "url": i["url"]})
        elif state in ("unstarted", "started"):
            if i.get("dueDate") in batch:
                continue   # batch artifact, not a deadline
            if i["identifier"] in flight:
                items.append(_item(4, i["identifier"], i["title"], "", "already running",
                                   "in flight per census; not scheduled", i["url"], "linear"))
                continue
            due = f"due {i['dueDate']}" if i.get("dueDate") else "no date"
            items.append(_item(3, i["identifier"], i["title"], "", due,
                               f"bucket 3: {prio} {i['state']['name']} with a real date", i["url"], "linear"))
    return items


def _bucket_4(own_prs: list[dict], own: list[dict], placed: set[str]) -> list[dict]:
    """Approved, non-draft own PRs (authors merge their own) and started issues not already placed."""
    items = [_item(4, f"{pr['repo']}#{pr['number']}", pr["title"], "", "approved — you merge your own",
                   "bucket 4: approved own PR, authors merge", pr["url"], "github")
             for pr in own_prs if pr.get("reviewDecision") == "APPROVED" and not pr.get("isDraft")]
    for i in own:
        if i["state"]["type"] == "started" and i["identifier"] not in placed:
            items.append(_item(4, i["identifier"], i["title"], "", f"in progress since {i['updatedAt'][:10]}",
                               "bucket 4: own in-flight", i["url"], "linear"))
    return items


def _bucket_5(own: list[dict], flight: set[str], placed: set[str]) -> list[dict]:
    """Todo issues with a project, newest first, capped — new work goes into leftover capacity only."""
    todo = [i for i in own if i["state"]["type"] == "unstarted" and i.get("project")
            and i["identifier"] not in flight and i["identifier"] not in placed]
    todo.sort(key=lambda i: i["createdAt"], reverse=True)
    return [_item(5, i["identifier"], i["title"], "", "Todo with a project",
                  "bucket 5: new work into leftover capacity", i["url"], "linear") for i in todo[:NEW_WORK_CAP]]


def rank(inp: RankInputs) -> dict:
    """Produce the ``sequence.json`` shape: ranked ``items`` with rationales, plus ``triage`` and ``decisions``."""
    lin = inp.linear or {"issues": [], "viewer": {}}
    gh = inp.github or {"review_requests": [], "own_prs": []}
    me = (lin.get("viewer") or {}).get("id")
    own = [i for i in lin.get("issues", []) if (i.get("assignee") or {}).get("id") == me]
    batch = batch_due_dates(own)
    flight = in_flight_keys(inp.census)
    triage: list[dict] = []
    decisions: list[dict] = []

    items = _bucket_1(inp, gh.get("review_requests", []), triage)
    items += _bucket_2(inp.pins)
    items += _hot_issues(own, batch, flight, decisions)
    items += _bucket_4(gh.get("own_prs", []), own, {x["key"] for x in items})
    items += _bucket_5(own, flight, {x["key"] for x in items})
    items.sort(key=lambda i: i["bucket"])   # stable: order within a bucket is the order built above
    return {"generated_at": now(), "tenant": inp.tenant.name, "failed_sources": [],
            "items": items, "triage": triage, "decisions": decisions}


def to_markdown(seq: dict) -> str:
    """``sequence.md``: one line per item with its rationale beneath, then decisions and triage."""
    lines = [f"# sequence — {seq['tenant']} — {seq['generated_at']}", ""]
    for i in seq["items"]:
        who = f" (waiting: {i['waiting_on']})" if i["waiting_on"] else ""
        lines.append(f"- [{i['bucket']}] **{i['key']}** {i['title']}{who} — {i['why_now']}")
        lines.append(f"  - rationale: {i['rationale']}")
    if seq["decisions"]:
        lines += ["", "## Decisions (not scheduled)"] + [f"- {d['key']}: {d['why']}" for d in seq["decisions"]]
    if seq["triage"]:
        lines += ["", "## Team-derived reviews to triage"] + [f"- {x['key']}: {x['why']}" for x in seq["triage"]]
    return "\n".join(lines) + "\n"
