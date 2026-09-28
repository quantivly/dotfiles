"""``rabota sync``: fetch Linear, GitHub and Fireflies into ``sources/*.json`` and record each
outcome in ``source_syncs``.

Fireflies joined ``linear``/``github`` here in DO-746: a static per-user API key needs no
per-seat connector authorization, so the timer can fetch it exactly as it already fetches Linear.
A missing key is not a special case — there is no key on this machine yet — so
``FirefliesClient.from_context`` refuses (``errors.Refused``, a ``RabotaError``) exactly as
``LinearClient.from_context`` already does for an unset ``linear_key_env``, and ``run_sync``'s
existing per-source ``except errors.RabotaError`` records it as a failed source rather than
raising out of the loop: the other sources still sync, and ``precompute`` still finishes.

**The fetch window (DO-746 fix round, finding F2; re-keyed in DO-761).** A fixed
``FIREFLIES_LOOKBACK_DAYS = 2`` lost Friday afternoon's meetings on a Monday 07:00 tick: the
timer runs Mon-Fri, ``sync`` overwrites the snapshot rather than merging it, and a Monday tick
asking only "since Saturday 07:00" never sees Friday's transcripts again. The window is derived
from the invariant instead — every item from a meeting after the point Fireflies was last
actually classified must reach classification.

That point used to be read from ``last-brief-shown.json``, a marker only ``commands.brief.run_brief``
writes — but "shown" was only ever a proxy for "classified" (a bare ``rabota --text brief``
is shown and classifies nothing), and on a tenant that had never shown a single brief the file did
not exist at all, so the window fell all the way back to the fixed ``FIREFLIES_LOOKBACK_MIN_DAYS``
even on a machine with weeks of day-scoped briefs already on disk (DO-761). ``fireflies_since`` now
reads ``snapshots.read_last_classified`` — the classification record itself — first, falls back to
``snapshots.read_newest_day_brief`` (the newest day-scoped ``last-brief.json`` across every day
directory) when nothing has been classified yet, and only then to ``FIREFLIES_LOOKBACK_MIN_DAYS``.
Two bounds keep whichever anchor is used honest: ``FIREFLIES_LOOKBACK_MARGIN_HOURS`` covers clock
skew and a transcript that posts a little after its meeting ends, and ``FIREFLIES_LOOKBACK_MAX_DAYS``
stops a months-old or missing marker from asking Fireflies for a year of transcripts.

``fireflies_since`` also clamps the UPPER bound at ``now`` (fix round 2, finding C) -- an anchor
ahead of the clock this call reads otherwise pushed ``since`` past ``now``, so the fetch window
started in the future and a real unclassified meeting was never fetched at all.

**The day-brief fallback is frozen, not re-read (DO-761 fix round 2, finding 1).**
``read_newest_day_brief`` is recomputed live from whatever the newest day directory is AT CALL
TIME, and a tenant that only ever gets brief text -- a bare ``rabota --text brief``, or an agent
that reads turn 1 and never sends the classifying acknowledgement back -- never creates
``fireflies-classified.json``, so this fallback used to stay live forever rather than only at
bootstrap: the window start walked forward a full day for every day a brief was merely shown, and
because ``sync_fireflies`` overwrites (never merges) the snapshot, a transcript fetched on day N
and never acknowledged was silently dropped from every later window. ``fireflies_since`` now reads
``snapshots.read_or_freeze_fireflies_fallback_anchor`` in place of ``read_newest_day_brief``
directly: it freezes the first answer that function gives and every later call gets that same
frozen value back, however many newer day-scoped briefs land in the meantime, until a real
classification record exists and takes over as the primary anchor.
"""
import os
from datetime import datetime, timedelta, timezone

from rabota import cli, errors, secrets, snapshots
from rabota.context import Context
from rabota.sources.fireflies import FirefliesClient
from rabota.sources.github import GhClient
from rabota.sources.linear import LinearClient

FETCHED_SOURCES = ("linear", "github", "fireflies")
FIREFLIES_LOOKBACK_MIN_DAYS = 2                  # fallback: neither a classification record nor any day-scoped brief exists yet
FIREFLIES_LOOKBACK_MARGIN_HOURS = 6              # clock skew / a transcript posted after the fact
FIREFLIES_LOOKBACK_MAX_DAYS = 14                 # bound: a stale/missing anchor asks for 2 weeks, not a year


def fireflies_since(ctx: Context, now: datetime) -> datetime:
    """The fetch window start: since Fireflies was last actually classified, plus a margin,
    bounded above and below.

    See the module docstring for why this replaced a fixed ``FIREFLIES_LOOKBACK_DAYS`` and, in
    DO-761, replaced ``last-brief-shown.json`` with the classification record, and (fix round 2)
    why the day-brief fallback is frozen rather than re-read live. Reads both anchors through
    ``snapshots.read_last_classified``/``snapshots.read_or_freeze_fireflies_fallback_anchor``
    rather than inline — see those functions' comments for why the reads must not live in this
    file.

    **Finding C (DO-746 fix round 2), still honoured.** Only the lower bound
    (``FIREFLIES_LOOKBACK_MAX_DAYS``) used to be clamped; an anchor ahead of ``now`` -- multi-machine
    clock skew, or any ``generated_at``/``classified_at`` written ahead of this call's clock --
    pushed ``since`` past ``now``, so the window started in the future and every real meeting
    between the true anchor and now was silently never fetched. ``since`` is still also capped at
    ``now``, whichever anchor produced it.
    """
    earliest = now - timedelta(days=FIREFLIES_LOOKBACK_MAX_DAYS)
    anchor = snapshots.read_last_classified(ctx.state_dir)
    if anchor is None:
        anchor = snapshots.read_or_freeze_fireflies_fallback_anchor(ctx.state_dir, ctx.dry_run)
    if anchor is None:
        since = max(now - timedelta(days=FIREFLIES_LOOKBACK_MIN_DAYS), earliest)
    else:
        since = max(anchor - timedelta(hours=FIREFLIES_LOOKBACK_MARGIN_HOURS), earliest)
    return min(since, now)


def sync_linear(ctx: Context, lin) -> dict:
    """Assigned-open ∪ created-by-me-open (deduped by id) with relations, plus every non-archived notification."""
    dead = ctx.tenant.linear.dead_state_types
    viewer = lin.viewer()
    issues = {i["id"]: i for i in lin.assigned_open(dead)}
    for i in lin.created_open(viewer["id"], dead):
        issues.setdefault(i["id"], i)
    for iid, rel in lin.relations(list(issues)).items():
        if iid in issues:
            issues[iid].update(rel)
    notifications = lin.inbox_notifications()
    payload = {"ok": True, "error": None, "viewer": viewer, "issues": list(issues.values()),
               "notifications": notifications}
    snapshots.write(ctx.state_dir, "linear", payload, dry_run=ctx.dry_run)
    return {"issues": len(issues), "notifications": len(notifications)}


def sync_github(ctx: Context, gh) -> dict:
    """Review requests (individual vs team resolved), own open PRs, and recently merged PRs."""
    payload = {"ok": True, "error": None, "login": gh.login, "review_requests": gh.review_requests(),
               "own_prs": gh.own_prs(), "merged_recent": gh.merged_recent()}
    snapshots.write(ctx.state_dir, "github", payload, dry_run=ctx.dry_run)
    return {k: len(payload[k]) for k in ("review_requests", "own_prs", "merged_recent")}


def sync_fireflies(ctx: Context, ff) -> dict:
    """Recent meeting transcripts, ``action_items`` already parsed into ``(speaker, item, timestamp)``.

    ``since`` (the window start this very fetch asked for) is stamped onto the payload alongside
    ``fetched_at`` (DO-761 fix round): a classifying acknowledgement can vouch for coverage only up
    to what the snapshot it read actually asked Fireflies for, never for the moment of the
    acknowledgement itself, and only the snapshot can say what that was. See
    ``commands.brief._mark_fireflies_classified``.
    """
    since = fireflies_since(ctx, datetime.now(timezone.utc))
    transcripts = ff.recent_transcripts(since)
    payload = {"ok": True, "error": None, "transcripts": transcripts,
               "since": since.strftime(snapshots.FETCHED_AT_FORMAT)}
    snapshots.write(ctx.state_dir, "fireflies", payload, dry_run=ctx.dry_run)
    return {"transcripts": len(transcripts)}


def _sync_one(ctx: Context, source: str, lin, gh, ff) -> dict:
    if source == "linear":
        return sync_linear(ctx, lin or LinearClient.from_context(ctx))
    if source == "github":
        return sync_github(ctx, gh or GhClient.from_context(ctx))
    if source == "fireflies":
        return sync_fireflies(ctx, ff or FirefliesClient.from_context(ctx))
    raise errors.Usage(f"sync does not fetch {source!r}; use `rabota ingest`")


def run_sync(ctx: Context, sources: list[str], lin=None, gh=None, ff=None) -> dict:
    """Sync each source in turn; the ones that succeed are written even when a later one fails.

    Returns ``{source: {"ok", "error", "path", "counts"}}`` and raises ``errors.Partial`` naming
    the failed sources after every source has been attempted and recorded.

    ``ctx.dry_run`` (DO-753): each connector is still fetched for real (a network READ), and
    ``sync_linear``/``sync_github``/``sync_fireflies`` still compute the full payload, but
    ``snapshots.write`` (called inside each of those) skips the write, and the ``source_syncs``
    row below is skipped too — no state file, no store row, on either the success or the failure
    path.
    """
    report, failed = {}, []
    for source in sources:
        path = str(ctx.state_dir / "sources" / f"{source}.json")
        try:
            counts = _sync_one(ctx, source, lin, gh, ff)
        except errors.Usage:
            raise
        except errors.RabotaError as e:
            # gh's stderr is folded into the error text and can echo the minted token (k2). The
            # store redacts again on its own; redacting here too keeps the terminal report
            # printable, so the caller gets `partial` naming the source instead of `secret_leak`.
            msg = secrets.redact(str(e), os.environ)
            if not ctx.dry_run:
                ctx.store.record_sync(ctx.tenant.name, source, False, msg, "")
            report[source] = {"ok": False, "error": msg, "path": "", "counts": {}}
            failed.append(source)
            continue
        if not ctx.dry_run:
            ctx.store.record_sync(ctx.tenant.name, source, True, None, path)
        report[source] = {"ok": True, "error": None, "path": path, "counts": counts}
    if ctx.dry_run:
        report["dry_run"] = "nothing written (sources/*.json, source_syncs rows)"
    if failed:
        raise errors.Partial(f"sources failed: {', '.join(failed)}", failed=failed)
    return report


def _build(sub):
    p = sub.add_parser("sync", help="fetch Linear, GitHub and Fireflies into sources/*.json")
    p.add_argument("--source", default=",".join(FETCHED_SOURCES), help="comma list: linear,github,fireflies")


def _run(ns):
    ctx = Context.from_namespace(ns)
    wanted = [s for s in ns.source.split(",") if s in ctx.tenant.sources and s in FETCHED_SOURCES]
    return run_sync(ctx, wanted)


cli.register("sync", _build, _run)
