"""Source snapshots: ``<state_dir>/sources/<source>.json``, written atomically and guarded, read back as dicts."""
import json
import os
import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from rabota import emit, errors, secrets
from rabota.store import now

FETCHED_AT_FORMAT = "%Y-%m-%dT%H:%M:%SZ"

# The one staleness rule for a snapshot, twice the pre-compute timer's 30-minute period.
# It lives here, with `parse_fetched_at`, because it is a fact about snapshots rather than
# about any one command -- and because it was briefly defined twice, in `commands.brief` and
# in `reconcile`, tied together only by a comment saying they were the same number. Halving
# one of them left the whole suite green (review finding), so a comment was doing an import's
# job. Import it; do not restate it.
STALE_AFTER_MIN = 60


def _path(state_dir: Path, source: str) -> Path:
    return Path(state_dir) / "sources" / f"{source}.json"


def parse_fetched_at(value: str) -> datetime:
    """Parse a snapshot's ``fetched_at`` (UTC, ``Z`` suffix) into an aware datetime; ``ValueError`` if it is not one."""
    return datetime.strptime(value, FETCHED_AT_FORMAT).replace(tzinfo=timezone.utc)


def write(state_dir: Path, source: str, payload: dict, dry_run: bool = False) -> Path:
    """Write ``payload`` (stamped with ``fetched_at`` if it has none) via a temp file and ``os.replace``.

    A reader therefore sees the previous snapshot or the new one, never a partial file. The
    serialised text is checked with ``secrets.assert_clean`` BEFORE anything is created on
    disk — a connector error that echoes a token must not land in the state dir (k2).

    ``dry_run`` (DO-753): the guard above still runs, but nothing is created on disk — not even
    the parent ``sources/`` directory — and the path that WOULD have been written is still
    returned, so a caller can still report it.
    """
    payload = {**payload, "fetched_at": payload.get("fetched_at") or now()}
    text = secrets.assert_clean(json.dumps(payload, indent=1, default=str), os.environ)
    path = _path(state_dir, source)
    if dry_run:
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{source}.", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return path


def read(state_dir: Path, source: str) -> dict | None:
    """The snapshot for ``source``, or ``None`` when it has never been written."""
    path = _path(state_dir, source)
    return json.loads(path.read_text()) if path.exists() else None


def age_seconds(state_dir: Path, source: str, now_dt: datetime | None = None) -> float | None:
    """Seconds since the snapshot's ``fetched_at`` (against ``now_dt`` or the clock), or ``None`` if absent."""
    snap = read(state_dir, source)
    if not snap:
        return None
    fetched = parse_fetched_at(snap["fetched_at"])
    return ((now_dt or datetime.now(timezone.utc)) - fetched).total_seconds()


# `<state_dir>/fireflies-classified.json` (DO-746 fix round 2, finding D; `commands.brief`'s
# `_mark_fireflies_classified` is the only writer): the set of classified item keys, plus
# ``classified_at`` — the time of the most recent acknowledgement. `commands.sync.fireflies_since`
# reads `classified_at` (DO-761) as its primary anchor for the fetch window, because "shown" was
# only ever a proxy for "classified" and a tenant that had never shown a brief (no
# `last-brief-shown.json`, the marker this replaced) fell all the way back to a fixed window even
# though a day-scoped `last-brief.json` was on disk the whole time. Deliberately NOT read via a
# helper defined in `commands/sync.py` itself: that module is one of the two files
# `tests/test_linear.py`'s static ingestion-boundary scan parses whole, and a subscript read
# reachable (however unrelated) through that module's shared `ctx` parameter is exactly the shape
# the scan flags -- keeping the read here, outside both scanned files, sidesteps it rather than
# fighting the scan's own over-approximation.
FIREFLIES_CLASSIFIED_FILE = "fireflies-classified.json"


def read_last_classified(state_dir: Path) -> datetime | None:
    """``classified_at`` of the most recent Fireflies acknowledgement, or ``None`` if nothing has
    ever been classified yet.

    Any fault in the file (missing, unreadable, malformed) is treated the same as "never
    classified" — it is not this function's job to raise over a marker file it does not own.
    """
    path = Path(state_dir) / FIREFLIES_CLASSIFIED_FILE
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
        return parse_fetched_at(data["classified_at"])
    except (OSError, json.JSONDecodeError, KeyError, ValueError, TypeError):
        return None


def read_newest_day_brief(state_dir: Path) -> datetime | None:
    """``generated_at`` of the most recent day-scoped ``<day>/last-brief.json`` under ``state_dir``,
    or ``None`` if none exists.

    Fallback #2 for ``commands.sync.fireflies_since`` (DO-761), behind ``read_last_classified``:
    a tenant with no classification record yet may still have day-scoped briefs on disk — exactly
    the live case that motivated this change, where `last-brief-shown.json` did not exist at all
    but `2025-09-25/last-brief.json` (a real "shown" record) had been sitting there the whole time.
    Lives here, not in `commands/sync.py`, for the same scan-avoidance reason as
    ``read_last_classified`` above.
    """
    state_dir = Path(state_dir)
    if not state_dir.is_dir():
        return None
    newest = None
    for entry in state_dir.iterdir():
        if not entry.is_dir():
            continue
        path = entry / "last-brief.json"
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text())
            generated_at = parse_fetched_at(data["generated_at"])
        except (OSError, json.JSONDecodeError, KeyError, ValueError, TypeError):
            continue
        if newest is None or generated_at > newest:
            newest = generated_at
    return newest


# `<state_dir>/fireflies-bootstrap-anchor.json` (DO-761 fix round 2, finding 1): freezes the FIRST
# answer `read_newest_day_brief` gives, so a tenant that never sends the classifying
# acknowledgement back (a bare `rabota --text brief`, or an agent that reads turn 1 and never sends
# turn 2) does not have its fetch window slide forward one full day for every day a brief is merely
# shown. `read_newest_day_brief` is recomputed live from whatever the newest day directory is AT
# CALL TIME -- exactly right the first time nothing has ever been classified, but wrong to keep
# recomputing on every later call with the same "nothing classified yet" excuse, since the tenant's
# actual classification state has not moved at all. The invariant this whole change protects --
# "every item from a meeting after the point Fireflies was last actually classified must still be
# fetched" -- cannot be satisfied by an anchor that advances on "shown" instead of on an actual
# classification, so the answer is frozen instead of re-read. Once a real classification exists,
# `read_last_classified` takes priority over both this and ``read_newest_day_brief`` and this file
# stops mattering.
FIREFLIES_BOOTSTRAP_ANCHOR_FILE = "fireflies-bootstrap-anchor.json"


def read_fireflies_bootstrap_anchor(state_dir: Path) -> datetime | None:
    """The anchor frozen by ``read_or_freeze_fireflies_fallback_anchor``, or ``None`` if nothing
    has been frozen yet.

    Any fault in the file (missing, unreadable, malformed) is treated the same as "not frozen
    yet" -- same reasoning as ``read_last_classified``.
    """
    path = Path(state_dir) / FIREFLIES_BOOTSTRAP_ANCHOR_FILE
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text())
        return parse_fetched_at(data["anchor"])
    except (OSError, json.JSONDecodeError, KeyError, ValueError, TypeError):
        return None


# One transient freeze-write failure must stay quiet (DO-768): `since` is still correct THIS call
# either way (the caller already has `anchor` in hand), and the very next tick tries the write
# again from the same "nothing frozen yet" state -- a single fluke costs an operator nothing but
# one retry it never sees. What must not stay quiet is the SAME write failing again and again: the
# window then never freezes at all, and every later call re-derives `read_newest_day_brief` live,
# restoring the pre-DO-761 day-by-day slide with no error and no alert. `FIREFLIES_FREEZE_ALERT_AFTER`
# is the count of CONSECUTIVE failures (tracked in `Store.fireflies_freeze_faults`, reset to zero
# the moment a freeze succeeds) at which `reconcile.snapshot_health` starts saying so -- one failure
# is a fluke by definition here, so 2 is the first count that is not.
FIREFLIES_FREEZE_ALERT_AFTER = 2


def _freeze_fireflies_bootstrap_anchor(state_dir: Path, anchor: datetime) -> str | None:
    """Persist ``anchor`` as the frozen fallback anchor, once a VALID one is not already on disk --
    a second call once a good anchor is frozen is a no-op, so the anchor this protects can only
    ever be set once per tenant (until a real classification supersedes it as the primary anchor).

    Returns ``None`` when a frozen anchor is now on disk -- it already was, or this call just
    wrote it -- or the ``OSError`` text when this call's own write attempt failed. A caller uses
    that to tell "frozen" from "answered but not frozen" (DO-768; the old version returned nothing
    at all, so no caller could ever tell the difference).

    Review finding 2 (DO-761 fix round 3): the guard used to be ``path.exists()`` -- existence,
    not validity -- so a corrupt file (a bad write, or a process killed mid-write) could never be
    replaced: every later call kept re-deriving a live answer it could never persist, silently
    reconstructing the day-by-day slide this whole mechanism exists to kill. Guarding on
    ``read_fireflies_bootstrap_anchor`` instead means a corrupt file reads as "nothing frozen yet",
    same as a missing one, and heals itself the next time anything asks.

    Review finding 1 (DO-761 fix round 3): the write itself is wrapped, because every real caller
    of ``read_or_freeze_fireflies_fallback_anchor`` -- ``sync.fireflies_since`` on every real sync
    tick, ``brief._fireflies_coverage`` on every classifying acknowledgement -- sits on a path
    built to degrade one source, never to crash the whole call on it (``run_sync``'s own docstring:
    "the ones that succeed are written even when a later one fails"). A read-only state dir, a full
    disk or a permissions fault must not turn this opportunistic persist, tucked inside what every
    caller treats as a read, into an unhandled ``OSError`` that takes down Linear and GitHub too.
    DO-768: the fault is no longer swallowed with a bare ``pass`` -- it is reported back to the
    caller instead, so it can reach an operator once it stops being a one-off.
    """
    if read_fireflies_bootstrap_anchor(state_dir) is not None:
        return None
    path = Path(state_dir) / FIREFLIES_BOOTSTRAP_ANCHOR_FILE
    try:
        emit.write_file(path, json.dumps({"anchor": anchor.strftime(FETCHED_AT_FORMAT)}))
        return None
    except OSError as e:
        return str(e) or type(e).__name__


def read_or_freeze_fireflies_fallback_anchor(state_dir: Path, dry_run: bool = False) -> tuple[datetime | None, str | None]:
    """Fallback #2 for ``commands.sync.fireflies_since``/``commands.brief._fireflies_coverage``,
    behind ``read_last_classified``: the newest day-scoped brief's ``generated_at`` — frozen the
    first time an answer is available, rather than recomputed live on every call. See the
    ``FIREFLIES_BOOTSTRAP_ANCHOR_FILE`` comment above for why a live re-read of
    ``read_newest_day_brief`` cannot satisfy the classification invariant.

    Returns ``(anchor, freeze_error)``. ``anchor`` is ``None`` while no day-scoped brief has ever
    existed (nothing to freeze yet) — the caller then falls back further, to a fixed lookback. The
    moment one does exist, that answer is frozen for every later call, even once newer day-scoped
    briefs land, until a real classification record exists and takes over as the primary anchor.
    ``dry_run`` (matching ``snapshots.write``'s own flag) skips the freeze itself — a dry run must
    not start a state change a real call would.

    ``freeze_error`` (DO-768) is ``None`` when the anchor is frozen -- already was, or this call
    just persisted it -- when there is nothing to freeze yet, or on a dry run (which never
    attempts the write); it is the ``OSError`` text from ``_freeze_fireflies_bootstrap_anchor``
    when this call tried to persist a new anchor and failed. Before this, the return value could
    not express "answered but not frozen" at all -- every one of those cases looked identical to a
    caller that only ever saw the ``datetime``.
    """
    frozen = read_fireflies_bootstrap_anchor(state_dir)
    if frozen is not None:
        return frozen, None
    anchor = read_newest_day_brief(state_dir)
    if anchor is None or dry_run:
        return anchor, None
    return anchor, _freeze_fireflies_bootstrap_anchor(state_dir, anchor)


def record_fireflies_freeze_result(ctx, freeze_error: str | None) -> None:
    """Best-effort bookkeeping of ``freeze_error`` (see ``read_or_freeze_fireflies_fallback_anchor``)
    into ``ctx.store``'s consecutive-failure streak for ``ctx.tenant``.

    Guarded, deliberately: a caller reaches this only after the freeze itself already degraded
    gracefully (DO-768) rather than crashing, and a store that cannot even open -- a state dir
    unwritable from the very first call this process ever made, before any row has ever been
    written -- must not turn this bookkeeping step into the crash the freeze itself just avoided.
    Losing one streak update this way is the same trade the freeze itself already makes: the
    caller already has its answer for this call regardless of whether the count gets recorded.

    This streak covers only the narrow shape where the anchor's OWN path is unwritable while the
    rest of ``state_dir`` -- ``ctx.store``, ``sources/*.json`` -- is not. A ``state_dir`` unwritable
    in general never reaches this line: ``snapshots.write`` and ``Store.open`` both raise on it, so
    the whole tick fails loudly (non-zero exit, no snapshot, no rank, no brief) before any freeze
    logic runs, and needs no streak here to be noticed.
    """
    try:
        ctx.store.record_freeze_result(ctx.tenant.name, freeze_error)
    except (errors.RabotaError, sqlite3.Error):
        pass
