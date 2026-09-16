"""Output helpers: JSON on stdout, JSON errors on stderr, ``--text`` lines."""
import json
import sys


def json_out(obj, stream=None):
    """Write ``obj`` as indented JSON followed by a newline to ``stream`` (default stdout)."""
    stream = stream or sys.stdout
    json.dump(obj, stream, indent=2, sort_keys=True, default=str)
    stream.write("\n")


def text_out(lines, stream=None):
    """Write each item of ``lines`` on its own line to ``stream`` (default stdout)."""
    stream = stream or sys.stdout
    for line in lines:
        stream.write(f"{line}\n")


def json_err(code_name, message, **extra):
    """Write ``{"error": {"code": ..., "message": ..., **extra}}`` to stderr."""
    json.dump({"error": {"code": code_name, "message": message, **extra}}, sys.stderr, default=str)
    sys.stderr.write("\n")
