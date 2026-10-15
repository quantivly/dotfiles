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

**The desktop notification (DO-815).** Beside the herdr one, and best-effort the same way, creation
sends one ``notify-send`` — the surface @zvi actually reads when he is not looking at herdr. It is
sent HERE and nowhere else: no reader (``brief``, ``escalations``, ``close``) ever notifies, so
"once per escalation" holds by construction with no column recording that it was sent, and a
re-read sends nothing. Its urgency is the caller's, not the kind's: ``urgency`` (``--urgency``)
defaults to ``normal``, and a scheduled run's ``fail``/``denied``/``expired`` outcome passes
``critical`` (spec §6 step 4). It is validated before anything is written, and never stored —
the ``escalations`` schema is unchanged. Only the summary carries free text: GNOME renders markup
in the BODY (``docs/VPN_INTERNALS.md``), so the body is built from the id and tenant alone. Other
daemons (dunst, mako with markup on) render it in the summary too, so the question goes there
collapsed to one line with ``<``, ``>`` and ``&`` replaced by look-alikes (``_plain``): no daemon
can read it as markup, and a reader still sees what was asked. Its outcome rides
along as ``desktop_notified``, with the same ``True``/``False``/``None`` meaning as ``notified``.

**A critical one is loud (2026-10-14).** GNOME Shell 50.1 already gives critical urgency everything
a banner can have: it bypasses Do Not Disturb, never auto-hides, auto-expands and jumps a full queue
(``messageTray.js`` 929/1206/1166/944, read from the installed shell). It plays a sound only when the
notification carries a ``sound-name`` hint, and a critical banner's sound plays under DND too. So
critical adds ``CRITICAL_EXTRAS``: the freedesktop ``alarm-clock-elapsed`` sound, which nothing else
here uses, and a ``dialog-warning`` icon. ESC-11 went out without either and was silent. Lower
urgencies stay silent on purpose: a sound on every escalation would teach @zvi to ignore it.
"""
import json

from rabota import cli, emit, errors
from rabota.commands.escalations import one_line
from rabota.context import Context
from rabota.store import now

# `scheduled-run` (DO-817) is what the schedule tick raises, and the one kind whose answer can carry
# an action: `run_answer` hands it to `scheduler.run_answer`, which executes the declared rerun or
# cancel-followups only for the escalation the tick itself recorded on the schedule row.
KINDS = ("decision", "finding", "verification", "pr-blocked", "prereq", "incident", "correction", "commitment",
         "scheduled-run")
URGENCIES = ("low", "normal", "critical")     # notify-send's own levels; see the module docstring
# A critical one gets a sound nothing else on the machine uses and a warning icon, so it is told apart
# from vpn-notify's and nanoclaw's criticals; see the module docstring.
CRITICAL_EXTRAS = ("--icon", "dialog-warning", "--hint", "string:sound-name:alarm-clock-elapsed")


def _project(ctx: Context, row: dict):
    emit.append_file(ctx.state_dir / "escalations.jsonl", json.dumps(row) + "\n")


def _plain(text: str) -> str:
    """``text`` on one line with no character any notification daemon could read as markup."""
    return one_line(text).translate(str.maketrans({"<": "‹", ">": "›", "&": "＆"}))


def _notify_best_effort(ctx: Context, argv: list[str]) -> bool:
    try:
        return ctx.runner.run(argv, timeout=5).ok
    except Exception:
        return False


def run_escalate(ctx: Context, question: str, evidence: str, options: list[str], kind: str = "finding",
                  subject: str | None = None, notify: bool = True, urgency: str = "normal") -> dict:
    """Record and project an escalation, and (best-effort) notify on herdr and the desktop.

    ``ctx.dry_run`` (DO-753): no ``escalations`` row is written, nothing is projected to
    ``escalations.jsonl``, and no notification fires — there is no real escalation yet for a
    notification to be about.
    """
    if kind not in KINDS:
        raise errors.Usage(f"kind must be one of {KINDS}")
    if urgency not in URGENCIES:
        raise errors.Usage(f"urgency must be one of {URGENCIES}")
    if ctx.dry_run:
        return {"id": None, "notified": None, "desktop_notified": None,
                "dry_run": "nothing written (escalations row, escalations.jsonl)"}
    eid = ctx.store.add_escalation(ctx.tenant.name, question, evidence, options, kind=kind, subject=subject)
    row = ctx.store.escalation(eid)
    try:
        _project(ctx, {"ts": row["ts"], "firstSeen": row["first_seen"], "kind": kind, "subject": subject,
                       "tenant": ctx.tenant.name, "question": question, "evidence": evidence,
                       "options": options, "disposition": None})
    except errors.SecretLeak:
        ctx.store.delete_escalation(eid)
        raise
    notified = desktop_notified = None
    if notify:
        # Built from the STORED question (redacted by `Store._exec`), not the argument. Today the two
        # are always equal here -- `_project` refuses any value the store would redact, before this
        # point -- so this is defence in depth: it keeps holding if that order ever changes.
        stored = row["question"]
        notified = _notify_best_effort(ctx, ["herdr", "notification", "show", f"rabota {kind}: {stored[:100]}"])
        desktop_notified = _notify_best_effort(ctx, [
            "notify-send", "--app-name", "rabota", "--urgency", urgency,
            *(CRITICAL_EXTRAS if urgency == "critical" else ()),
            f"ESC-{eid} rabota {kind}: {_plain(stored)[:100]}",
            f"ESC-{eid}: rabota --tenant {ctx.tenant.name} --text escalations --open"])
    return {"id": eid, "notified": notified, "desktop_notified": desktop_notified}


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
    if row["kind"] == "scheduled-run":
        from rabota import scheduler     # not at the top: scheduler imports this module
        sched = scheduler.schedule_for(ctx, row)
        if sched is not None:
            return scheduler.run_answer(ctx, row, sched, label, resolution)
    if ctx.dry_run:
        return {"id": esc_id, "disposition": label, "dry_run": "nothing written (escalations row, escalations.jsonl)"}
    ctx.store.answer_escalation(esc_id, label, resolution)
    try:
        _project(ctx, answer_projection(ctx, row, label, resolution))
    except errors.SecretLeak:
        ctx.store.unresolve_escalation(esc_id)
        raise
    return {"id": esc_id, "disposition": label}


def answer_projection(ctx: Context, row: dict, label: str, resolution: str | None) -> dict:
    """The ``escalations.jsonl`` line an answer projects, read after ``answer_escalation`` committed."""
    stored = ctx.store.escalation(row["id"])
    return {"ts": now(), "firstSeen": row["first_seen"], "kind": row["kind"], "subject": row["subject"],
            "tenant": ctx.tenant.name, "question": row["question"], "evidence": row["evidence"],
            "options": row["options"], "disposition": label, "resolvedAt": stored["resolved_at"],
            "resolution": resolution}


def _build(sub):
    e = sub.add_parser("escalate", help="record a question for the user")
    e.add_argument("--question", required=True)
    e.add_argument("--evidence", required=True)
    e.add_argument("--option", action="append", default=[], help="repeatable")
    e.add_argument("--kind", choices=KINDS, default="finding")
    e.add_argument("--subject")
    e.add_argument("--no-notify", action="store_true", help="skip the herdr and desktop notifications")
    e.add_argument("--urgency", choices=URGENCIES, default="normal",
                   help="desktop notification urgency (default normal; critical for a failed scheduled run)")
    a = sub.add_parser("answer", help="resolve an escalation with an offered label")
    a.add_argument("id", type=int)
    a.add_argument("label")
    a.add_argument("--resolution")


def _run_escalate(ns):
    ctx = Context.from_namespace(ns)
    return run_escalate(ctx, ns.question, ns.evidence, ns.option, kind=ns.kind, subject=ns.subject,
                         notify=not ns.no_notify, urgency=ns.urgency)


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
