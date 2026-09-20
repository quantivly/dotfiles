"""Census's own remote reading, plus the ssh mechanics every caller shares: load, memory, lane
units, and each lane's last result line.

The ONLY module that knows an ssh invocation's shape (``ssh_argv``) or single-quotes a path for
one (``shquote``) — dev's login shell is zsh, and bash's ``printf %q`` is not zsh-safe (a leading
``=`` undergoes equals expansion there), so POSIX single-quoting is used rather than any shell's
own quoter. Every other module that talks to a remote machine (``commands/lane.py``) builds its
own SCRIPT text but never its own ssh flags — it calls ``ssh_argv`` for those, so the batch mode,
timeout and ``--`` separator live in exactly one place.

Unreachable is a measurement, never a zero: a caller that reads a missing key as room is the
bug this module's shape exists to prevent.
"""
import tempfile
import uuid
from pathlib import Path

from rabota import sysinfo

MARKER = "---RABOTA---"

# Printed only when `systemctl --user list-units` actually completed. An empty unit-list section
# (no XDG_RUNTIME_DIR on a non-interactive ssh, user manager stopped, lingering off) must not read
# as "zero units" — that grants the full local lane cap while lanes are actually running on the
# machine. Zero lanes and an unreadable lane list are different answers, so parse() requires this
# sentinel even for a genuinely empty (but successfully listed) unit list.
UNITS_OK = "---RABOTA-UNITS-OK---"


def shquote(s: str) -> str:
    """POSIX single-quoting: literal in sh, bash and zsh alike."""
    return "'" + s.replace("'", "'\\''") + "'"


def ssh_argv(machine, script: str) -> list[str]:
    """The one shared ssh invocation shape: batch mode, a short connect timeout, ``--`` before the
    host so a hostname that starts with ``-`` can never be read as another ssh option.

    ``script`` is the caller's problem to quote — this only wraps it, it inspects nothing.
    """
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", machine.ssh, script]


def build_argv(machine, lane_out_dirs: list[str], marker: str = MARKER) -> list[str]:
    """The one ssh invocation. Sections are separated by ``marker``, in parse()'s order."""
    script = [
        "cat /proc/loadavg", f"printf %s {shquote(marker)}",
        "cat /proc/meminfo", f"printf %s {shquote(marker)}",
        "nproc", f"printf %s {shquote(marker)}",
        # No `|| true`: that would let a failed `systemctl --user` (no XDG_RUNTIME_DIR on a
        # non-interactive ssh, user manager stopped, lingering off) produce an empty section that
        # reads as "zero units" instead of "unreadable". UNITS_OK prints only once systemctl has
        # actually succeeded; parse() then refuses a units section missing that sentinel.
        'systemctl --user list-units --plain --no-legend "rabota-lane-*" 2>/dev/null'
        f' && printf %s {shquote(UNITS_OK)}',
    ]
    for d in lane_out_dirs:
        q = shquote(d)
        script += [f"printf %s {shquote(marker)}", f"printf '%s\\n' {q}",
                   f"grep -h '\"type\":\"result\"' {q}/stream.jsonl 2>/dev/null | tail -1 || true"]
    return ssh_argv(machine, "; ".join(script))


def parse(name: str, out: str, expected_sections: int | None = None, marker: str = MARKER) -> dict:
    """Split the payload into a machines[] row. Raises ValueError on anything unexpected.

    ``marker`` is the separator ``build_argv`` used for this same call — ``read()`` generates a
    fresh one per call (MARKER plus a UUID4) so a lane's own result line, which is arbitrary
    agent-transcript JSON and can contain the literal MARKER string, cannot collide with the
    framing. ``expected_sections``, when given, is the exact number of sections the caller asked
    for; that check is kept even with a per-call marker — the nonce makes a *collision* with a
    lane's own output impossible, but the count check still catches genuine framing corruption
    (a truncated payload, a doubled section) unrelated to any poisoned content.
    """
    parts = out.split(marker)
    if len(parts) < 4:
        raise ValueError(f"expected at least 4 sections, got {len(parts)}")
    if expected_sections is not None and len(parts) != expected_sections:
        raise ValueError(f"expected exactly {expected_sections} sections, got {len(parts)}")
    loadavg, meminfo, ncpu_s, units_s = parts[0], parts[1], parts[2], parts[3]
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "loadavg").write_text(loadavg)
        (root / "meminfo").write_text(meminfo)
        si = sysinfo.read(root, ncpu=int(ncpu_s.strip()))
    if not units_s.endswith(UNITS_OK):
        # Empty or truncated: `systemctl --user list-units` failed or never completed. Reading
        # that as "zero units" would grant the full local lane cap while lanes are actually
        # running on the machine, so this refuses like every other unreadable dimension.
        raise ValueError("unit list: missing success sentinel (systemctl did not complete)")
    units_s = units_s[: -len(UNITS_OK)]
    units = []
    for line in units_s.splitlines():
        f = line.split()
        if len(f) >= 3 and f[0].startswith("rabota-lane-"):
            units.append({"name": f[0], "state": f[2], "machine": name})
    streams = {}
    for chunk in parts[4:]:
        lines = chunk.splitlines()
        if lines:
            streams[lines[0]] = lines[1] if len(lines) > 1 else ""
    return {"name": name, "reachable": True, "load1": si.load1, "ncpu": si.ncpu,
            "mem_available_gib": round(si.mem_available_gib, 1),
            "swap_used_pct": si.swap_used_pct, "units": units, "streams": streams}


def read(runner, machine, lane_out_dirs: list[str], timeout: float = 30) -> dict:
    """Measure ``machine``. Any failure is ``reachable: False`` with an ``error``, never a zero."""
    marker = MARKER + uuid.uuid4().hex
    res = runner.run(build_argv(machine, lane_out_dirs, marker=marker), timeout=timeout)
    if not res.ok:
        return {"name": machine.name, "reachable": False,
                "error": (res.err or res.out or f"exit {res.code}").strip()}
    try:
        return parse(machine.name, res.out, expected_sections=4 + len(lane_out_dirs), marker=marker)
    except Exception as e:  # noqa: BLE001
        # Deliberately broad. Everything parse() touches is output from another host, and the
        # contract above this line is that any shape it cannot read becomes a measurement of
        # "unreachable" rather than an exception in the caller. A narrow tuple has already been
        # wrong once here: sysinfo.read raises IndexError on an empty loadavg section, which the
        # original (ValueError, KeyError) let through. The type name is kept in the message so a
        # genuine bug in parse() is still diagnosable from the row.
        return {"name": machine.name, "reachable": False,
                "error": f"unparseable reading: {type(e).__name__}: {e}"}
