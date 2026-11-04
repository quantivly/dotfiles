"""Mutations with a rollback row before each write and a re-fetch after the batch."""
import time
from datetime import datetime, timezone
from rabota import errors

AUTO_BUCKETS = ("dead_issue", "own_pr_merged", "due_reminder")
# Linear's read-after-write is not strongly consistent: a re-read immediately after a
# successful write can still return the pre-write value. Retrying a few times with a short
# backoff absorbs the ordinary replication lag; an issue still unconfirmed after these is
# reported as `unconfirmed`, never as `failed` -- the write itself raised no error, so
# folding it into `failed` would report a real success as a real failure (DO-707).
VERIFY_ATTEMPTS = 3
VERIFY_DELAY_S = 0.5


def new_batch_id(prefix: str) -> str:
    return f"{prefix}-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"


def apply_auto(plan: dict, client, store, tenant, dry_run: bool = False) -> dict:
    batch = new_batch_id("auto")
    todo = [i for b in AUTO_BUCKETS for i in plan["buckets"].get(b, []) if i["tier"] == "auto"]
    if dry_run:
        return {"batch_id": batch, "archived": 0, "by_bucket": {}, "verified": 0, "failed": [],
                "would_archive": [i["notification_id"] for i in todo]}
    return archive_notifications(batch, "auto", [(i["bucket"], i["notification_id"]) for i in todo], client, store, tenant)


def archive_notifications(batch: str, tier: str, rows: list[tuple[str, str]], client, store, tenant) -> dict:
    """Archive each ``(bucket, notification id)``: a rollback row before every write, one re-fetch
    after the batch to verify. The auto tier's archive and DO-877's dismissal share it."""
    rep = {"batch_id": batch, "archived": 0, "by_bucket": {}, "verified": 0, "failed": []}
    for bucket, nid in rows:
        store.record_decision(batch, tenant.name, tier, bucket, "notification", nid, "archive", {"archivedAt": None})
        try:
            r = client.archive_notification(nid)
            if not r.get("success"): raise errors.RabotaError("success=false")
            rep["archived"] += 1; rep["by_bucket"][bucket] = rep["by_bucket"].get(bucket, 0) + 1
        except errors.RabotaError as e:
            rep["failed"].append({"id": nid, "error": str(e)})
    still_inbox = {n["id"] for n in client.inbox_notifications()}
    failed = {f["id"] for f in rep["failed"]}
    for _bucket, nid in rows:
        if nid not in still_inbox and nid not in failed:
            store.mark_verified(batch, nid); rep["verified"] += 1
    return rep


# The answer kinds `inbox answer` records (DO-877); each names the write the tick makes for it.
ANSWER_DUE_POLICY = "due_policy"
ANSWER_PROJECT_PROMPT = "project_prompt"
ANSWER_KINDS = (ANSWER_DUE_POLICY, ANSWER_PROJECT_PROMPT)


def apply_answers(plan: dict, client, store, tenant, dry_run: bool = False) -> dict:
    """DO-877: apply every pending answer recorded from Sol through the writes the typed commands
    make -- a ``due_policy`` confirmation clears the due dates of the issues it covered that are
    STILL in the batch (the propose tier's clear, a rollback row per issue; an issue that joined
    the batch after the phone saw it is not touched), and a ``project_prompt`` dismissal archives
    each listed notification (a rollback row per id, one re-fetch verify). A row is stamped
    applied with its batch once attempted, so no tick applies it twice; its outcome is the batch's
    decision rows and ``rollback <batch_id>`` undoes either. Dry run: names what it would apply
    and stamps nothing."""
    pending = store.pending_inbox_answers(tenant.name)
    if dry_run:
        return {"applied": [], "would_apply": [{"id": a["id"], "kind": a["kind"], "ids": a["ids"]} for a in pending]}
    rep = {"applied": []}
    for answer in pending:
        if answer["kind"] == ANSWER_DUE_POLICY:
            covered = set(answer["ids"])
            issues = [i for i in plan["batches"]["due_policy"]["issues"] if i["identifier"] in covered]
            outcome = (apply_due_policy({"batches": {"due_policy": {"issues": issues}}}, client, store, tenant, confirmed=True)
                       if issues else None)
        elif answer["kind"] == ANSWER_PROJECT_PROMPT:
            outcome = archive_notifications(new_batch_id("dismiss"), "decision",
                                            [(ANSWER_PROJECT_PROMPT, nid) for nid in answer["ids"]], client, store, tenant)
        else:
            continue   # a kind this rabota does not apply: left pending, never stamped as done
        batch = outcome["batch_id"] if outcome else None
        store.mark_inbox_answer_applied(answer["id"], batch)
        rep["applied"].append({"id": answer["id"], "kind": answer["kind"], "batch_id": batch, "outcome": outcome})
    return rep


def apply_due_policy(plan: dict, client, store, tenant, confirmed: bool, dry_run: bool = False,
                      verify_attempts: int = VERIFY_ATTEMPTS, verify_delay: float = VERIFY_DELAY_S,
                      sleeper=time.sleep) -> dict:
    if confirmed is not True:
        raise errors.Refused("due_policy is a propose-tier batch; pass --confirmed after the user's typed OK")
    batch = new_batch_id("due")
    issues = plan["batches"]["due_policy"]["issues"]
    rep = {"batch_id": batch, "cleared": 0, "verified": 0, "unconfirmed": [], "read_errors": [], "failed": []}
    if dry_run:
        rep["would_clear"] = [i["identifier"] for i in issues]; return rep
    for i in issues:
        store.record_decision(batch, tenant.name, "propose", "due_policy", "issue", i["id"], "clear_due_date", {"dueDate": i["dueDate"]})
        # Only the write is allowed to put an issue in `failed`. Review finding: with the verify
        # read inside this same `try`, a read that RAISED landed the issue in `failed` having
        # already counted it in `cleared` -- one issue in two buckets, and a write that actually
        # succeeded reported as a failure. That is the exact untruth DO-707 exists to remove.
        try:
            r = client.set_due_date(i["id"], None)
            if not r.get("success"): raise errors.RabotaError("success=false")
        except errors.RabotaError as e:
            rep["failed"].append({"id": i["identifier"], "error": str(e)})
            continue
        rep["cleared"] += 1
        cleared_read_back, read_error = False, None
        for attempt in range(verify_attempts):
            try:
                if client.issue_state_and_due(i["id"]).get("dueDate") is None:
                    cleared_read_back = True
                    break
            except errors.RabotaError as e:
                read_error = str(e)          # a read that errors is still only a read
            if attempt < verify_attempts - 1:
                sleeper(verify_delay)
        if cleared_read_back:
            store.mark_verified(batch, i["id"]); rep["verified"] += 1
        else:
            if read_error is not None:
                # Recorded rather than swallowed: "we could not look" and "we looked and it was
                # stale" are different things to a reader deciding whether to re-run. One entry
                # per issue, the last error seen -- a transient read that a later attempt fixed
                # is not news. `unconfirmed` still carries the issue either way.
                rep["read_errors"].append({"id": i["identifier"], "error": read_error})
            # The write succeeded (no RabotaError raised) but the re-read never caught up --
            # a stale read, not a failed write, so it belongs apart from `failed`.
            rep["unconfirmed"].append(i["identifier"])
    return rep


def rollback(batch_id: str, client, store, dry_run: bool = False) -> dict:
    """Undo a batch's writes from its recorded ``prior`` values.

    ``dry_run`` (DO-753, "most urgent"): a rollback mutates Linear (unarchiving a notification,
    restoring a due date), so a ``--dry-run`` rollback must send nothing — this returns before
    ``client`` is ever touched or ``store.mark_rolled_back`` is called, naming what it would have
    restored instead of restoring it. ``store.decisions`` itself is a read: it costs nothing to
    compute the ``would_restore`` list from the same rows a real rollback would act on.
    """
    decisions = store.decisions(batch_id)
    if dry_run:
        return {"batch_id": batch_id, "would_restore": [d["entity_id"] for d in decisions]}
    rep = {"batch_id": batch_id, "restored": 0, "failed": []}
    for d in decisions:
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
