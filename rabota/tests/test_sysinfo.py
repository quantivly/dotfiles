import unittest
from pathlib import Path
from rabota import sysinfo

FIX = Path(__file__).parent / "fixtures" / "proc"

class SysinfoTests(unittest.TestCase):
    def test_reads_proc(self):
        s = sysinfo.read(FIX, ncpu=8)
        self.assertEqual((s.load1, s.ncpu), (7.58, 8))
        self.assertAlmostEqual(s.mem_available_gib, 11.2, places=1)
        self.assertEqual(s.swap_used_pct, 48)

    def test_no_swap_is_zero_percent(self):
        s = sysinfo.SysInfo(1.0, 8, 10.0, 0, 0)
        self.assertEqual(s.swap_used_pct, 0)

    def test_ncpu_defaults_to_the_host_count(self):
        self.assertGreaterEqual(sysinfo.read(FIX).ncpu, 1)
