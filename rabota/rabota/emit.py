"""Output helpers: JSON on stdout, JSON errors on stderr, ``--text`` lines.

This module is the one choke point for anything that leaves the process. Each
helper renders its whole output to a string, checks it with
``secrets.assert_clean`` against the REAL environment, and only then writes —
so a protected value raises ``errors.SecretLeak`` and nothing partial is
printed. Write through here, never to ``sys.stdout``/``sys.stderr`` directly.
"""
import json
import os
import sys

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
