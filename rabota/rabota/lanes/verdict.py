"""Verdict contract validation (spec §C6)."""
import json
from pathlib import Path
from rabota import errors


class VerdictError(errors.RabotaError):
    name = "verdict"


REQUIRED = ("lane", "status", "claims", "deliverables", "followups")


def validate(path: Path, max_bytes: int) -> dict:
    """Validate the verdict file at ``path`` ON THIS MACHINE.

    A verdict that lives on another machine cannot be checked here — see
    ``validate_text``, which takes content someone else fetched. Every OSError becomes a
    ``VerdictError``: an unreadable file is a refusal like any other, not an exit-5 traceback
    (a mode-0 verdict used to escape as ``PermissionError``).
    """
    path = Path(path)
    if not path.exists():
        raise VerdictError(f"no verdict at {path}")
    try:
        size = path.stat().st_size
        if size > max_bytes:
            raise VerdictError(f"verdict is {size} bytes > {max_bytes} bytes")
        text = path.read_text()
    except OSError as e:
        raise VerdictError(f"verdict at {path} is unreadable: {e}") from e
    return validate_text(text, max_bytes, where=str(path))


def validate_text(text: str, max_bytes: int, *, where: str) -> dict:
    """The size and shape rules alone, over content already in hand.

    Split out so a verdict on a remote machine gets exactly the same rules as a local one; the
    only thing that differs between them is how the bytes were obtained. ``where`` names the
    source in any message, so a refusal still says which file on which machine.
    """
    size = len(text.encode())
    if size > max_bytes:
        raise VerdictError(f"verdict at {where} is {size} bytes > {max_bytes} bytes")
    try:
        v = json.loads(text)
    except json.JSONDecodeError as e:
        raise VerdictError(f"verdict at {where} is not JSON: {e}")
    missing = [k for k in REQUIRED if k not in v]
    if missing:
        raise VerdictError("verdict missing keys: " + ", ".join(missing))
    if v["status"] not in ("done", "failed"):
        raise VerdictError(f"status must be done|failed, got {v['status']!r}")
    for c in v["claims"]:
        if not all(k in c for k in ("id", "text", "evidence")) or "cmd" not in c["evidence"]:
            raise VerdictError(f"claim malformed: {c}")
    return v
