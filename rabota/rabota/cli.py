"""Argument parsing, command registry, and exception → exit-code mapping."""
import argparse
import importlib
import sqlite3
import sys

from rabota import __version__, context, emit, errors

COMMANDS = {}   # name -> (build, run)


def register(name, build, run):
    """Register a subcommand: ``build(subparsers)`` adds its parser, ``run(ns)`` executes it."""
    COMMANDS[name] = (build, run)


def _version_build(sub):
    sub.add_parser("version", help="print version")


def _version_run(ns):
    return {"version": __version__}


register("version", _version_build, _version_run)

# Command modules register themselves on import. Missing modules are fine
# while workstreams land; each module is imported by name and skipped if absent.
COMMAND_MODULES = ["doctor", "preflight", "sync", "ingest", "inbox", "rank", "brief",
                   "close", "escalate", "census", "budget", "lane", "reap", "db", "precompute"]


def _load_command_modules():
    for name in COMMAND_MODULES:
        try:
            importlib.import_module(f"rabota.commands.{name}")
        except ModuleNotFoundError as e:
            if e.name != f"rabota.commands.{name}":
                raise


class _ArgError(Exception):
    pass


def build_parser():
    """Build the top-level parser with every registered subcommand attached."""
    p = argparse.ArgumentParser(prog="rabota", description="work-day orchestrator substrate")
    p.add_argument("--tenant", help="tenant name; default resolved from cwd")
    p.add_argument("--state-dir", help="override the tenant state dir")
    p.add_argument("--text", action="store_true", help="human lines instead of JSON")
    p.add_argument("--dry-run", action="store_true")
    sub = p.add_subparsers(dest="command", metavar="<command>")
    for name, (build, _run) in COMMANDS.items():
        build(sub)
    return p


# Written only if even the leak report would itself contain a protected value. It
# interpolates nothing, so it cannot.
_LEAK_FALLBACK = '{"error": {"code": "secret_leak", "message": "output would contain a protected value"}}\n'


def _report(e):
    """Emit ``e`` as the error JSON and return its exit code.

    ``emit.json_err`` guards its own output, so a message that would leak a protected
    value raises ``SecretLeak`` here; that leak (which names only the variable) is
    reported in its place and its exit code wins.
    """
    extra = {"failed": e.failed} if isinstance(e, errors.Partial) else {}
    try:
        emit.json_err(e.name, str(e), **extra)
    except errors.SecretLeak as leak:
        try:
            emit.json_err(leak.name, str(leak))
        except errors.SecretLeak:
            sys.stderr.write(_LEAK_FALLBACK)
        return leak.code
    return e.code


def _close_contexts(opened):
    """Close every context the command built; a failing close must never mask the run's outcome.

    This runs in ``main``'s ``finally``, where a raised exception would replace the command's
    exit code (or its own exception). The connection is being abandoned at process exit either
    way, so a close that fails is swallowed rather than reported.
    """
    for ctx in opened:
        try:
            ctx.close()
        except sqlite3.Error:
            pass


def main(argv=None):
    """Parse ``argv``, run the chosen command, and return its exit code (never raises an Exception)."""
    _load_command_modules()
    parser = build_parser()

    def _error(msg):
        raise _ArgError(msg)
    parser.error = _error  # no SystemExit from argparse
    try:
        ns = parser.parse_args(argv)
    except _ArgError as e:
        sys.stderr.write(f"usage: {e}\n")
        return errors.Usage.code
    if not ns.command:
        parser.print_usage(sys.stderr)
        return errors.Usage.code
    _build, run = COMMANDS[ns.command]
    with context.track_contexts() as opened:
        try:
            result = run(ns)
            if result is None:
                return 0
            if ns.text:
                emit.text_out(result if isinstance(result, list) else [str(result)])
            else:
                emit.json_out(result)
            return 0
        except errors.RabotaError as e:
            return _report(e)
        except Exception as e:  # noqa: BLE001 — the last resort, spec C1: 5. SystemExit and
            # KeyboardInterrupt are BaseException, so they keep their own behaviour.
            return _report(errors.RabotaError(f"unexpected {type(e).__name__}: {e}"))
        finally:
            _close_contexts(opened)   # success, error, SystemExit and KeyboardInterrupt alike
