"""The tracked-side index reconcile needs, built from ``sources/linear.json`` and ``sources/github.json``
(DO-716 move 4).

**Why this exists.** Turn 1 of ``/rabota brief`` cannot know a commitment's tracked counterpart —
Slack and Calendar are not fetched yet (see ``commands.brief.compute_needs``), and Fireflies,
though fetched server-side by the timer since DO-746, is not yet classified: its items reach
``needs`` unclassified, the same way a stale Slack/Calendar entry does. So pairing a commitment
with what Linear/GitHub say has to wait for turn 2, where the agent has just fetched or been
handed the connector items — and it can only cost 0 further round trips if what it needs is
already sitting in turn 1's ``brief`` reply. This module builds exactly that: a slim projection of
the two snapshots the 30-minute ``precompute`` timer already keeps fresh, so building it costs a
re-read of two small files already on disk, never a new fetch.

**What it is not.** It does not fetch anything itself, and it does not do the classification —
that stays model judgement (``reconcile.md``). It is the haystack, not the needle.

**Size — measured, not assumed.** No description prose, no notifications, no ``review_requests``
(none of the six classes in ``reconcile.md`` need them — see ``build_tracked_index``'s docstring).
Even so, ``tests/test_reconcile_index.py`` measures a realistic tenant (25 open Linear issues, 8
open + 5 merged PRs) at **~9 KB**, roughly 2x the lane-artifact ``max_verdict_bytes`` discipline
(4096 bytes, ``2026-09-16-rabota-v2-design.md`` line 232) cited here as the reference point for
"small," not a bar this module claims to clear. At ~280 bytes/issue and ~215 bytes/PR, the 4 KB
line falls at roughly 15 tracked items total, and a working tenant's assigned-or-created-open
Linear queue alone routinely exceeds that. The honest tradeoff: still far smaller than re-reading
both raw snapshots whole (notifications and ``review_requests`` are the bulk of what is dropped),
but not small in the lane-artifact sense — a caller with an unusually large backlog pays for it
in context every morning, and that cost was not reduced further here (see the verdict for this
being named rather than papered over, per the brief's finding-worth-reporting instruction).

**Missing or unreadable snapshots.** Following the precedent ``compute_needs`` set (#237): an
unreadable or absent snapshot is an empty side of the index plus a ``reason``, never an exception —
the brief must still print. A *stale* snapshot is not the same thing: the data is still the best
the CLI has, so it is returned as-is with a ``reason`` noting its age, not suppressed.
"""
from datetime import datetime, timezone

from rabota import snapshots
from rabota.snapshots import STALE_AFTER_MIN
# One definition, in `snapshots` -- see the comment there for why it is not restated here.


def _linear_side(state_dir, now: datetime) -> dict:
    """``{"ok", "reason", "issues"}`` — one slim record per Linear issue, or an empty list plus a reason."""
    try:
        snap = snapshots.read(state_dir, "linear")
    except Exception as e:  # noqa: BLE001 — an unreadable file must not cost the whole brief; see module docstring
        return {"ok": False, "reason": f"unreadable ({type(e).__name__})", "issues": []}
    if snap is None:
        return {"ok": False, "reason": "never synced", "issues": []}
    if not isinstance(snap, dict) or not isinstance(snap.get("issues"), list):
        return {"ok": False, "reason": "unreadable (not the expected shape)", "issues": []}
    issues = [{"key": i.get("identifier"), "title": i.get("title"), "url": i.get("url"),
               "state": (i.get("state") or {}).get("name"), "state_type": (i.get("state") or {}).get("type"),
               "priority_label": i.get("priorityLabel"), "due_date": i.get("dueDate"),
               "updated_at": i.get("updatedAt"), "blocked_by": i.get("blockedBy") or [],
               "blocks": i.get("blocks") or []}
              for i in snap["issues"]]
    fresh_ok, reason = _age_verdict(snap, now)
    ok = bool(snap.get("ok", True)) and fresh_ok
    if not snap.get("ok", True):
        reason = snap.get("error") or "last sync failed"
    return {"ok": ok, "reason": reason, "issues": issues}


def _github_side(state_dir, now: datetime) -> dict:
    """``{"ok", "reason", "own_prs", "merged_recent"}`` — the two lists that carry review/merge state."""
    try:
        snap = snapshots.read(state_dir, "github")
    except Exception as e:  # noqa: BLE001 — same reasoning as `_linear_side`
        return {"ok": False, "reason": f"unreadable ({type(e).__name__})", "own_prs": [], "merged_recent": []}
    if snap is None:
        return {"ok": False, "reason": "never synced", "own_prs": [], "merged_recent": []}
    if not isinstance(snap, dict) or not isinstance(snap.get("own_prs"), list) or not isinstance(snap.get("merged_recent"), list):
        return {"ok": False, "reason": "unreadable (not the expected shape)", "own_prs": [], "merged_recent": []}
    own_prs = [{"key": f"{p.get('repo')}#{p.get('number')}", "url": p.get("url"), "title": p.get("title"),
                "review_decision": p.get("reviewDecision"), "mergeable": p.get("mergeable"),
                "approved_by": p.get("approved_by") or []}
               for p in snap["own_prs"]]
    merged = [{"key": f"{p.get('repo')}#{p.get('number')}", "url": p.get("url"), "merged_at": p.get("mergedAt")}
              for p in snap["merged_recent"]]
    fresh_ok, reason = _age_verdict(snap, now)
    ok = bool(snap.get("ok", True)) and fresh_ok
    if not snap.get("ok", True):
        reason = snap.get("error") or "last sync failed"
    return {"ok": ok, "reason": reason, "own_prs": own_prs, "merged_recent": merged}


def _age_verdict(snap: dict, now: datetime) -> tuple[bool, str | None]:
    """``(trustworthy, reason)`` from a snapshot's ``fetched_at``.

    Review finding: ``ok`` used to be copied straight from the snapshot, so a side could come back
    ``ok: True`` with ``reason`` saying its timestamp was unreadable, and a ``fetched_at`` in the
    future came back with no reason at all. **``ok`` has to mean "you can rely on this"**, or a
    caller that checks only ``ok`` -- which is the cheap and obvious thing to check -- is misled.
    So an unreadable timestamp and a timestamp in the future are both ``False`` here: one means we
    cannot tell how old the data is, the other means a clock is wrong, and neither is a basis for
    relying on it. Merely stale stays trustworthy -- old data is still data, which is why it comes
    back with a reason rather than emptied.
    """
    try:
        fetched = snapshots.parse_fetched_at(snap["fetched_at"])
    except (ValueError, TypeError, KeyError):
        return False, "unreadable (fetched_at is not a UTC timestamp)"
    age_min = (now - fetched).total_seconds() / 60
    if age_min < 0:
        return False, f"fetched_at is {int(-age_min)} min in the future (clock skew?)"
    return True, (f"stale ({int(age_min)} min old)" if age_min > STALE_AFTER_MIN else None)


def build_tracked_index(ctx, now: datetime | None = None) -> dict:
    """``{"linear", "github"}``: the tracked-side facts reconcile's six classes ask for.

    Included because a class needs it: ``state``/``state_type`` (``state-contradiction``),
    ``blocked_by``/``blocks`` (``stale-blocked``), ``review_decision``/``mergeable`` (``tracked-satisfied``,
    the ``stale-blocked`` "BEHIND + REVIEW_REQUIRED" case), ``merged_recent`` (confirming a
    ``tracked-satisfied`` PR actually landed). Every Linear issue and PR title/key is also the
    haystack ``promised-untracked`` searches to confirm nothing tracks a commitment.

    Left out on purpose: issue descriptions (reconcile.md itself says relations outrank
    description prose), Linear notifications and GitHub ``review_requests`` (no class needs
    them — they answer "what's requesting MY attention", not "what does the tracked side say
    about a commitment"). A tenant that does not list a source gets that side back as
    ``{"ok": False, "reason": "tenant does not use this source", ...}`` — mirroring the skip
    ``compute_needs`` already applies to ``NEEDS_SOURCES``.

    ``spoken-already-done`` and ``question-owed`` never consult this index at all: both are
    verified against the connector artifact itself (a Slack ``ts``, a transcript id), never
    against Linear or GitHub. See the verdict for which of the six classes this index cannot
    fully decide.
    """
    now = now or datetime.now(timezone.utc)
    sources = getattr(ctx.tenant, "sources", [])
    # `skipped` rather than only a reason string: review finding, a source the tenant does not use
    # was indistinguishable from a real failure to a caller checking `ok` alone, which is the cheap
    # and obvious check. `preflight` already marks this case `{"ok": True, "skipped": True}`; the
    # flag is carried here too so the two agree, while `ok` stays False because there is no data.
    linear = (_linear_side(ctx.state_dir, now) if "linear" in sources
              else {"ok": False, "skipped": True, "reason": "tenant does not use this source", "issues": []})
    github = (_github_side(ctx.state_dir, now) if "github" in sources
              else {"ok": False, "skipped": True, "reason": "tenant does not use this source",
                    "own_prs": [], "merged_recent": []})
    return {"linear": linear, "github": github}


def snapshot_health(ctx, now: datetime | None = None) -> list[dict]:
    """``[{"source", "reason"}]`` for each of ``linear``/``github`` the CLI cannot rely on.

    Cheap on purpose: it reads the two files but projects nothing, so both ``--text`` and JSON can
    call it on every brief. Review finding: `--text` never noticed an unreadable
    ``sources/linear.json`` at all once the day's ``sequence.json`` existed -- only JSON mode's
    ``tracked`` revalidated it -- so the brief could rank on a corrupt snapshot and say nothing. A
    source the tenant does not use is not a health problem and is never reported.
    """
    now = now or datetime.now(timezone.utc)
    index = build_tracked_index(ctx, now)
    return [{"source": source, "reason": side["reason"] or "unreliable"}
            for source, side in index.items()
            if not side["ok"] and not side.get("skipped")]
