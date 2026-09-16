"""Argument parsing, command registry, and exception → exit-code mapping."""
import argparse
import importlib
import sys

from rabota import __version__, emit, errors

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
                   "close", "escalate", "census", "budget", "lane", "reap", "db"]


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


def main(argv=None):
    """Parse ``argv``, run the chosen command, and return its exit code (never raises RabotaError)."""
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
    try:
        result = run(ns)
    except errors.RabotaError as e:
        extra = {"failed": e.failed} if isinstance(e, errors.Partial) else {}
        emit.json_err(e.name, str(e), **extra)
        return e.code
    if result is None:
        return 0
    if ns.text:
        emit.text_out(result if isinstance(result, list) else [str(result)])
    else:
        emit.json_out(result)
    return 0
