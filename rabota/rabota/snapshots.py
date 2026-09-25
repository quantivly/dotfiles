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


def write(state_dir: Path, source: str, payload: dict) -> Path:
    """Write ``payload`` (stamped with ``fetched_at`` if it has none) via a temp file and ``os.replace``.

    A reader therefore sees the previous snapshot or the new one, never a partial file. The
    serialised text is checked with ``secrets.assert_clean`` BEFORE anything is created on
    disk — a connector error that echoes a token must not land in the state dir (k2).
    """
    payload = {**payload, "fetched_at": payload.get("fetched_at") or now()}
    text = secrets.assert_clean(json.dumps(payload, indent=1, default=str), os.environ)
    path = _path(state_dir, source)
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
