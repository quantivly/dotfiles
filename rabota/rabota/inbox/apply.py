"""Mutations with a rollback row before each write and a re-fetch after the batch."""
from datetime import datetime, timezone
from rabota import errors

AUTO_BUCKETS = ("dead_issue", "own_pr_merged", "due_reminder")


def new_batch_id(prefix: str) -> str:
    return f"{prefix}-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"


def apply_auto(plan: dict, client, store, tenant, dry_run: bool = False) -> dict:
    batch = new_batch_id("auto")
    todo = [i for b in AUTO_BUCKETS for i in plan["buckets"].get(b, []) if i["tier"] == "auto"]
    rep = {"batch_id": batch, "archived": 0, "by_bucket": {}, "verified": 0, "failed": []}
    if dry_run:
        rep["would_archive"] = [i["notification_id"] for i in todo]; return rep
    for i in todo:
        store.record_decision(batch, tenant.name, "auto", i["bucket"], "notification", i["notification_id"], "archive", {"archivedAt": None})
        try:
            r = client.archive_notification(i["notification_id"])
            if not r.get("success"): raise errors.RabotaError("success=false")
            rep["archived"] += 1; rep["by_bucket"][i["bucket"]] = rep["by_bucket"].get(i["bucket"], 0) + 1
        except errors.RabotaError as e:
            rep["failed"].append({"id": i["notification_id"], "error": str(e)})
    still_inbox = {n["id"] for n in client.inbox_notifications()}
    for i in todo:
        if i["notification_id"] not in still_inbox and not any(f["id"] == i["notification_id"] for f in rep["failed"]):
            store.mark_verified(batch, i["notification_id"]); rep["verified"] += 1
    return rep


def apply_due_policy(plan: dict, client, store, tenant, confirmed: bool, dry_run: bool = False) -> dict:
    if confirmed is not True:
        raise errors.Refused("due_policy is a propose-tier batch; pass --confirmed after the user's typed OK")
    batch = new_batch_id("due")
    issues = plan["batches"]["due_policy"]["issues"]
    rep = {"batch_id": batch, "cleared": 0, "verified": 0, "failed": []}
    if dry_run:
        rep["would_clear"] = [i["identifier"] for i in issues]; return rep
    for i in issues:
        store.record_decision(batch, tenant.name, "propose", "due_policy", "issue", i["id"], "clear_due_date", {"dueDate": i["dueDate"]})
        try:
            r = client.set_due_date(i["id"], None)
            if not r.get("success"): raise errors.RabotaError("success=false")
            rep["cleared"] += 1
            if client.issue_state_and_due(i["id"]).get("dueDate") is None:
                store.mark_verified(batch, i["id"]); rep["verified"] += 1
        except errors.RabotaError as e:
            rep["failed"].append({"id": i["identifier"], "error": str(e)})
    return rep


def rollback(batch_id: str, client, store) -> dict:
    rep = {"batch_id": batch_id, "restored": 0, "failed": []}
    for d in store.decisions(batch_id):
        try:
            if d["action"] == "archive":
                client.unarchive_notification(d["entity_id"])
            elif d["action"] == "clear_due_date":
                client.set_due_date(d["entity_id"], d["prior"].get("dueDate"))
            else:
                raise errors.RabotaError(f"no rollback for action {d['action']}")
            rep["restored"] += 1
        except errors.RabotaError as e:
            rep["failed"].append({"id": d["entity_id"], "error": str(e)})
    store.mark_rolled_back(batch_id)
    return rep
