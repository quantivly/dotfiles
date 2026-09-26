"""``rabota escalate``/``rabota answer``: record a question for the user and resolve it later.

Every escalation is projected to ``<state_dir>/escalations.jsonl`` through ``emit.append_file`` —
never a bare append-mode file handle — because the row can carry free-text ``evidence`` that a
user pasted, which is exactly the shape the write guard exists to check. Routing it through
``emit`` lets Sol and ``close`` read the contract file without touching sqlite. A notification is best-effort: ``herdr notification show`` takes its
title *positionally* (``herdr notification show [OPTIONS] <TITLE>``, confirmed against
``herdr notification show --help`` before this module was written), so the call is
``["herdr", "notification", "show", f"rabota {kind}: {question[:100]}"]`` with no other flags. A
failed or missing ``herdr`` binary is not an error here, and neither is one that raises instead of
returning a bad exit code — ``run_escalate`` catches ``Exception`` (not ``BaseException``) around
the call so the escalation's id always comes back once the rows are committed. The outcome rides
along as ``notified`` in the returned dict (``True``/``False``/``None`` when ``notify=False``
skipped it) so the failure is visible to the caller without being fatal; ``notified`` is
deliberately never projected into ``escalations.jsonl``, whose field set is fixed by design §4.2 /
acceptance 9.8.

The store write and the jsonl projection are not one transaction — sqlite and a text file cannot
share one — so each direction picks a side to roll back on the other's failure (F3): a fresh
``escalate`` deletes the row it just inserted if ``_project`` raises ``SecretLeak``, since deleting
an escalation nobody has seen yet is safe; an ``answer`` instead undoes the resolution back to
"open" on the same failure, since the escalation itself may already be visible (its id already
returned to a prior caller) and must not vanish. Either way the store and the jsonl file agree again
before the exception leaves, so ``close`` never lists an escalation Sol cannot see in the projection.
"""
import json

from rabota import cli, emit, errors
from rabota.context import Context
from rabota.store import now

KINDS = ("decision", "finding", "verification", "pr-blocked", "prereq", "incident", "correction", "commitment")


def _project(ctx: Context, row: dict):
    emit.append_file(ctx.state_dir / "escalations.jsonl", json.dumps(row) + "\n")


def run_escalate(ctx: Context, question: str, evidence: str, options: list[str], kind: str = "finding",
                  subject: str | None = None, notify: bool = True) -> dict:
    """Record and project an escalation, and (best-effort) notify.

    ``ctx.dry_run`` (DO-753): no ``escalations`` row is written, nothing is projected to
    ``escalations.jsonl``, and no notification fires — there is no real escalation yet for a
    notification to be about.
    """
    if kind not in KINDS:
        raise errors.Usage(f"kind must be one of {KINDS}")
    if ctx.dry_run:
        return {"id": None, "notified": None, "dry_run": "nothing written (escalations row, escalations.jsonl)"}
    eid = ctx.store.add_escalation(ctx.tenant.name, question, evidence, options, kind=kind, subject=subject)
    row = ctx.store.escalation(eid)
    try:
        _project(ctx, {"ts": row["ts"], "firstSeen": row["first_seen"], "kind": kind, "subject": subject,
                       "tenant": ctx.tenant.name, "question": question, "evidence": evidence,
                       "options": options, "disposition": None})
    except errors.SecretLeak:
        ctx.store.delete_escalation(eid)
        raise
    notified = None
    if notify:
        try:
            result = ctx.runner.run(["herdr", "notification", "show", f"rabota {kind}: {question[:100]}"],
                                     timeout=5)
            notified = result.ok
        except Exception:
            notified = False
    return {"id": eid, "notified": notified}


def run_answer(ctx: Context, esc_id: int, label: str, resolution: str | None = None) -> dict:
    """Resolve an open escalation.

    ``ctx.dry_run`` (DO-753): the escalation is still read and validated (an unknown id or an
    already-resolved one still refuses exactly as a real run would), but nothing is written —
    neither the store row nor the jsonl projection.
    """
    row = ctx.store.escalation(esc_id)
    if not row:
        raise errors.Usage(f"no escalation {esc_id}")
    if row["resolved_at"]:
        # F4: without this an already-resolved escalation could be answered again, overwriting its
        # disposition, wiping the first resolution to NULL, and appending a second resolution row
        # to the jsonl projection with no record the first ever happened.
        raise errors.Refused(f"escalation {esc_id} is already resolved as {row['disposition']!r}")
    if row["options"] and label not in row["options"]:
        raise errors.Refused(f"label {label!r} is not one of {row['options']}")
    if ctx.dry_run:
        return {"id": esc_id, "disposition": label, "dry_run": "nothing written (escalations row, escalations.jsonl)"}
    ctx.store.answer_escalation(esc_id, label, resolution)
    stored = ctx.store.escalation(esc_id)
    try:
        _project(ctx, {"ts": now(), "firstSeen": row["first_seen"], "kind": row["kind"], "subject": row["subject"],
                       "tenant": ctx.tenant.name, "question": row["question"], "evidence": row["evidence"],
                       "options": row["options"], "disposition": label, "resolvedAt": stored["resolved_at"],
                       "resolution": resolution})
    except errors.SecretLeak:
        ctx.store.unresolve_escalation(esc_id)
        raise
    return {"id": esc_id, "disposition": label}


def _build(sub):
    e = sub.add_parser("escalate", help="record a question for the user")
    e.add_argument("--question", required=True)
    e.add_argument("--evidence", required=True)
    e.add_argument("--option", action="append", default=[], help="repeatable")
    e.add_argument("--kind", choices=KINDS, default="finding")
    e.add_argument("--subject")
    e.add_argument("--no-notify", action="store_true", help="skip the herdr notification")
    a = sub.add_parser("answer", help="resolve an escalation with an offered label")
    a.add_argument("id", type=int)
    a.add_argument("label")
    a.add_argument("--resolution")


def _run_escalate(ns):
    ctx = Context.from_namespace(ns)
    return run_escalate(ctx, ns.question, ns.evidence, ns.option, kind=ns.kind, subject=ns.subject,
                         notify=not ns.no_notify)


def _run_answer(ns):
    return run_answer(Context.from_namespace(ns), ns.id, ns.label, ns.resolution)


# ``cli.main`` looks up the run function by ``ns.command`` (the subparser name), so this run
# function is only ever invoked when ``ns.command == "escalate"" — the dispatch below is not a
# branch, it is the only path.
cli.register("escalate", _build, _run_escalate)
# "answer" is deliberately absent from ``cli.COMMAND_MODULES``: its parser is added by
# ``escalate``'s ``_build`` above (called once, adds both parsers), and this registration's own
# build is a no-op so the parser is never added twice regardless of import/build order.
cli.register("answer", lambda sub: None, _run_answer)
