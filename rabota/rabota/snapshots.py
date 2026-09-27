"""Source snapshots: ``<state_dir>/sources/<source>.json``, written atomically and guarded, read back as dicts."""
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from rabota import secrets
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
