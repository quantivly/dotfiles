"""Machine readers: loadavg and meminfo from a /proc-shaped tree. Nothing else.

Takes the proc root as a parameter so the state table hands it a fixture tree; the
default is the real ``/proc``. Seats are NOT read here — they come from
``clauth status --json`` in ``census``.
"""
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class SysInfo:
    load1: float
    ncpu: int
    mem_available_gib: float
    swap_total_kib: int
    swap_free_kib: int

    @property
    def swap_used_pct(self) -> int:
        """Whole-percent swap in use; a machine with no swap is 0, which is a measurement, not an absence."""
        if not self.swap_total_kib:
            return 0
        return round(100 * (self.swap_total_kib - self.swap_free_kib) / self.swap_total_kib)


def _meminfo(path: Path) -> dict[str, int]:
    out = {}
    for line in path.read_text().splitlines():
        k, _, v = line.partition(":")
        if v.strip():
            out[k.strip()] = int(v.split()[0])
    return out


def read(proc: Path = Path("/proc"), ncpu: int | None = None) -> SysInfo:
    """Read load1, MemAvailable and swap from ``proc``; ``ncpu`` defaults to this host's count."""
    load1 = float((proc / "loadavg").read_text().split()[0])
    mem = _meminfo(proc / "meminfo")
    return SysInfo(load1=load1, ncpu=ncpu or os.cpu_count() or 1,
                   mem_available_gib=mem.get("MemAvailable", 0) / 1048576,
                   swap_total_kib=mem.get("SwapTotal", 0), swap_free_kib=mem.get("SwapFree", 0))
