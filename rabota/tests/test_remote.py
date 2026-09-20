import shlex
import unittest
from rabota import remote
from rabota.config import Machine
from rabota.runner import FakeRunner, Result

LOADAVG = "0.20 0.28 0.27 1/900 12345\n"
MEMINFO = "MemTotal: 64000000 kB\nMemAvailable: 13631488 kB\nSwapTotal: 16000000 kB\nSwapFree: 16000000 kB\n"
UNITS = "rabota-lane-quantivly-smoke-9b221b43.service loaded active running lane\n"
RESULT = '{"type":"result","is_error":false,"total_cost_usd":0.42}'


def payload(*, units=UNITS, streams=(("/home/ubuntu/out/smoke", RESULT),)):
    parts = [LOADAVG, MEMINFO, "16\n", units]
    for out_dir, line in streams:
        parts.append(f"{out_dir}\n{line}\n")
    return remote.MARKER.join(parts)


MACHINE = Machine(name="dev", ssh="dev", tenants=["quantivly"], state_dir="~/.local/state/rabota")


class RemoteArgvTests(unittest.TestCase):
    def test_argv_is_batch_mode_and_names_the_host(self):
        argv = remote.build_argv(MACHINE, [])
        self.assertEqual(argv[0], "ssh")
        self.assertIn("BatchMode=yes", argv)
        self.assertIn("dev", argv)

    def test_out_dirs_are_single_quoted_into_the_script(self):
        argv = remote.build_argv(MACHINE, ["/home/ubuntu/o ne"])
        self.assertIn("'/home/ubuntu/o ne'", argv[-1])

    def test_a_quote_in_an_out_dir_cannot_break_out(self):
        # The property is "a shell sees exactly one token, identical to the input". Assert it with
        # a real POSIX lexer; un-escaping the string by hand tests the un-escaping, not the quoting.
        evil = "/tmp/a'; touch PWNED; '"
        self.assertEqual(shlex.split(remote.shquote(evil)), [evil])
        self.assertIn(remote.shquote(evil), remote.build_argv(MACHINE, [evil])[-1])


class RemoteParseTests(unittest.TestCase):
    def test_parses_a_full_reading(self):
        r = remote.parse("dev", payload())
        self.assertTrue(r["reachable"])
        self.assertEqual((r["load1"], r["ncpu"]), (0.20, 16))
        self.assertAlmostEqual(r["mem_available_gib"], 13.0, places=1)
        self.assertEqual(r["swap_used_pct"], 0)
        self.assertEqual(r["units"][0]["name"], "rabota-lane-quantivly-smoke-9b221b43.service")
        self.assertEqual(r["units"][0]["state"], "active")
        self.assertEqual(r["units"][0]["machine"], "dev")
        self.assertEqual(r["streams"]["/home/ubuntu/out/smoke"], RESULT)

    def test_no_units_is_an_empty_list_not_a_failure(self):
        r = remote.parse("dev", payload(units=""))
        self.assertTrue(r["reachable"])
        self.assertEqual(r["units"], [])


class RemoteReadTests(unittest.TestCase):
    def test_read_returns_the_parsed_reading(self):
        runner = FakeRunner([(["ssh"], Result(0, payload(), ""))])
        r = remote.read(runner, MACHINE, ["/home/ubuntu/out/smoke"])
        self.assertTrue(r["reachable"])
        self.assertEqual(r["name"], "dev")

    def test_ssh_failure_is_unreachable_not_zero(self):
        runner = FakeRunner([(["ssh"], Result(255, "", "connection refused"))])
        r = remote.read(runner, MACHINE, [])
        self.assertFalse(r["reachable"])
        self.assertIn("connection refused", r["error"])
        self.assertNotIn("load1", r)

    def test_timeout_is_unreachable(self):
        runner = FakeRunner([(["ssh"], Result(124, "", "timeout after 30s"))])
        self.assertFalse(remote.read(runner, MACHINE, [])["reachable"])

    def test_garbled_output_is_unreachable(self):
        runner = FakeRunner([(["ssh"], Result(0, "not a payload", ""))])
        r = remote.read(runner, MACHINE, [])
        self.assertFalse(r["reachable"])

    def test_an_empty_loadavg_section_is_unreachable_not_a_crash(self):
        # The script joins with `;`, so a failed `cat /proc/loadavg` still emits every marker and
        # still exits 0 — the section is just empty. sysinfo.read indexes split()[0] and raises
        # IndexError; uncaught, that takes down the whole census instead of one machine's row.
        broken = remote.MARKER.join(["", MEMINFO, "16\n", UNITS])
        r = remote.read(FakeRunner([(["ssh"], Result(0, broken, ""))]), MACHINE, [])
        self.assertFalse(r["reachable"])
        self.assertIn("IndexError", r["error"])

    def test_a_marker_inside_a_result_line_refuses_rather_than_reframing(self):
        # A lane's result line is arbitrary agent-transcript JSON, and a lane working on rabota
        # itself can emit the literal MARKER. With a bare separator that silently reframes the
        # payload into a plausible-looking wrong reading; the exact section count makes it loud.
        poisoned = payload(streams=(("/home/ubuntu/out/smoke",
                                     '{"type":"result","note":"' + remote.MARKER + '"}'),))
        r = remote.read(FakeRunner([(["ssh"], Result(0, poisoned, ""))]), MACHINE,
                        ["/home/ubuntu/out/smoke"])
        self.assertFalse(r["reachable"])
        self.assertIn("sections", r["error"])
