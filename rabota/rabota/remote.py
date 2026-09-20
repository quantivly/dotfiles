"""One ssh call per machine: load, memory, lane units, and each lane's last result line.

The ONLY module that knows a remote shell exists. Everything it sends is either a literal
this file wrote or a path single-quoted by ``shquote`` — dev's login shell is zsh, and bash's
``printf %q`` is not zsh-safe (a leading ``=`` undergoes equals expansion there), so POSIX
single-quoting is used rather than any shell's own quoter.

Unreachable is a measurement, never a zero: a caller that reads a missing key as room is the
bug this module's shape exists to prevent.
"""
import tempfile
from pathlib import Path

from rabota import sysinfo

MARKER = "---RABOTA---"


def shquote(s: str) -> str:
    """POSIX single-quoting: literal in sh, bash and zsh alike."""
    return "'" + s.replace("'", "'\\''") + "'"


def build_argv(machine, lane_out_dirs: list[str]) -> list[str]:
    """The one ssh invocation. Sections are separated by MARKER, in parse()'s order."""
    script = [
        "cat /proc/loadavg", f"printf %s {shquote(MARKER)}",
        "cat /proc/meminfo", f"printf %s {shquote(MARKER)}",
        "nproc", f"printf %s {shquote(MARKER)}",
        'systemctl --user list-units --plain --no-legend "rabota-lane-*" 2>/dev/null || true',
    ]
    for d in lane_out_dirs:
        q = shquote(d)
        script += [f"printf %s {shquote(MARKER)}", f"printf '%s\\n' {q}",
                   f"grep -h '\"type\":\"result\"' {q}/stream.jsonl 2>/dev/null | tail -1 || true"]
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--",
            machine.ssh, "; ".join(script)]


def parse(name: str, out: str) -> dict:
    """Split the payload into a machines[] row. Raises ValueError on anything unexpected."""
    parts = out.split(MARKER)
    if len(parts) < 4:
        raise ValueError(f"expected at least 4 sections, got {len(parts)}")
    loadavg, meminfo, ncpu_s, units_s = parts[0], parts[1], parts[2], parts[3]
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "loadavg").write_text(loadavg)
        (root / "meminfo").write_text(meminfo)
        si = sysinfo.read(root, ncpu=int(ncpu_s.strip()))
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
    res = runner.run(build_argv(machine, lane_out_dirs), timeout=timeout)
    if not res.ok:
        return {"name": machine.name, "reachable": False,
                "error": (res.err or res.out or f"exit {res.code}").strip()}
    try:
        return parse(machine.name, res.out)
    except (ValueError, KeyError) as e:
        return {"name": machine.name, "reachable": False, "error": f"unparseable reading: {e}"}
