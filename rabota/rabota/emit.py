"""Output helpers: JSON on stdout, JSON errors on stderr, ``--text`` lines, and files.

This module is the one choke point for anything that leaves the process. Each
helper renders its whole output to a string, checks it with
``secrets.assert_clean`` against the REAL environment, and only then writes —
so a protected value raises ``errors.SecretLeak`` and nothing partial is
printed. Write through here, never to ``sys.stdout``/``sys.stderr`` directly.

Files count as leaving the process. A secret on disk is worse than one on a
terminal — nothing downstream can catch it — so ``write_file`` is the sanctioned
way to write any text the state dir keeps (``brief.md``, ``last-brief.json``,
``sequence.json``, ``sequence.md``), and ``snapshots.write`` guards its payload
the same way. The third "write path that skipped the guard" in this epic (WS1
D1, WS4′ ``write_text``, WS2 k2 — twice) is why this exists; a ``Path.write_text``
in a command module is a defect, and ``tests/test_write_guard.py`` greps the
package for every spelling of one so the fourth round cannot happen. What is
PERSISTED into ``rabota.db`` is redacted rather than refused (``secrets.redact``,
``Store._exec``), because a row is a record and dropping it hides the failure.
"""
import json
import os
import sys
from pathlib import Path

from rabota import secrets


def _guard(text: str) -> str:
    return secrets.assert_clean(text, os.environ)


def json_out(obj, stream=None):
    """Write ``obj`` as indented JSON followed by a newline to ``stream`` (default stdout)."""
    text = _guard(json.dumps(obj, indent=2, sort_keys=True, default=str) + "\n")
    (stream or sys.stdout).write(text)


def text_out(lines, stream=None):
    """Write each item of ``lines`` on its own line to ``stream`` (default stdout)."""
    text = _guard("".join(f"{line}\n" for line in lines))
    (stream or sys.stdout).write(text)


def json_err(code_name, message, **extra):
    """Write ``{"error": {"code": ..., "message": ..., **extra}}`` to stderr."""
    text = _guard(json.dumps({"error": {"code": code_name, "message": message, **extra}}, default=str) + "\n")
    sys.stderr.write(text)


def write_file(path, text: str) -> Path:
    """Guard ``text`` with ``assert_clean`` and only then write it to ``path``; nothing is written on a leak."""
    text = _guard(text)
    path = Path(path)
    path.write_text(text)
    return path


def append_file(path, text: str) -> Path:
    """Guard ``text`` with ``assert_clean`` and only then append it to ``path``; nothing is appended on a leak."""
    text = _guard(text)
    path = Path(path)
    with path.open("a") as f:
        f.write(text)
    return path
