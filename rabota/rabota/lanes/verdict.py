"""Verdict contract validation (spec §C6)."""
import json
from pathlib import Path
from rabota import errors


class VerdictError(errors.RabotaError):
    name = "verdict"


REQUIRED = ("lane", "status", "claims", "deliverables", "followups")


def validate(path: Path, max_bytes: int) -> dict:
    path = Path(path)
    if not path.exists():
        raise VerdictError(f"no verdict at {path}")
    size = path.stat().st_size
    if size > max_bytes:
        raise VerdictError(f"verdict is {size} bytes > {max_bytes} bytes")
    try:
        v = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        raise VerdictError(f"verdict is not JSON: {e}")
    missing = [k for k in REQUIRED if k not in v]
    if missing:
        raise VerdictError("verdict missing keys: " + ", ".join(missing))
    if v["status"] not in ("done", "failed"):
        raise VerdictError(f"status must be done|failed, got {v['status']!r}")
    for c in v["claims"]:
        if not all(k in c for k in ("id", "text", "evidence")) or "cmd" not in c["evidence"]:
            raise VerdictError(f"claim malformed: {c}")
    return v
