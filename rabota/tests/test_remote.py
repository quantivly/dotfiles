import re
import shlex
import unittest
import uuid
from unittest import mock
from rabota import remote
from rabota.config import Machine
from rabota.runner import FakeRunner, Result

LOADAVG = "0.20 0.28 0.27 1/900 12345\n"
MEMINFO = "MemTotal: 64000000 kB\nMemAvailable: 13631488 kB\nSwapTotal: 16000000 kB\nSwapFree: 16000000 kB\n"
UNITS = "rabota-lane-quantivly-smoke-9b221b43.service loaded active running lane\n"
RESULT = '{"type":"result","is_error":false,"total_cost_usd":0.42}'

# read() now mints a fresh marker (MARKER + uuid4().hex) on every call, so a test that goes
# through read() (rather than calling parse() directly) needs the FakeRunner's canned payload to
# use the SAME marker read() is about to generate. Patching uuid.uuid4() to this fixed value makes
# that marker predictable without weakening the real code's randomness.
FIXED_UUID = uuid.UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
FIXED_MARKER = remote.MARKER + FIXED_UUID.hex


def patch_uuid():
    """Context manager: read() will mint FIXED_MARKER instead of a random one."""
    return mock.patch("rabota.remote.uuid.uuid4", return_value=FIXED_UUID)


def payload(*, units=UNITS, streams=(("/home/ubuntu/out/smoke", RESULT),),
            marker=None, units_ok=True):
    marker = remote.MARKER if marker is None else marker
    units_s = units + (remote.UNITS_OK if units_ok else "")
    parts = [LOADAVG, MEMINFO, "16\n", units_s]
    for out_dir, line in streams:
        parts.append(f"{out_dir}\n{line}\n")
    return marker.join(parts)


def marker_in_argv(argv) -> str:
    """Extract the live marker read() embedded in the built ssh script."""
    m = re.search(r"printf %s '([^']*)'", argv[-1])
    assert m, f"no marker found in {argv[-1]!r}"
    return m.group(1)


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
        with patch_uuid():
            runner = FakeRunner([(["ssh"], Result(0, payload(marker=FIXED_MARKER), ""))])
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
        with patch_uuid():
            broken = FIXED_MARKER.join(["", MEMINFO, "16\n", UNITS + remote.UNITS_OK])
            r = remote.read(FakeRunner([(["ssh"], Result(0, broken, ""))]), MACHINE, [])
        self.assertFalse(r["reachable"])
        self.assertIn("IndexError", r["error"])

    def test_a_marker_inside_a_result_line_no_longer_breaks_a_read(self):
        # A lane's result line is arbitrary agent-transcript JSON, and a lane working on rabota
        # itself can emit the literal MARKER constant. With a per-call nonce marker the LIVE
        # separator is never that constant string, so the poisoned line can no longer collide
        # with the framing — this used to permanently stall the whole machine (finding 2): the
        # section-count mismatch made read() report unreachable forever, which meant
        # settle_finished never settled the poisoned lane either, so census kept re-requesting
        # its out_dir on every later run.
        note = '{"type":"result","note":"' + remote.MARKER + '"}'
        with patch_uuid():
            poisoned = payload(marker=FIXED_MARKER, streams=(("/home/ubuntu/out/smoke", note),))
            r = remote.read(FakeRunner([(["ssh"], Result(0, poisoned, ""))]), MACHINE,
                            ["/home/ubuntu/out/smoke"])
        self.assertTrue(r["reachable"])
        self.assertEqual(r["streams"]["/home/ubuntu/out/smoke"], note)

    def test_the_live_marker_repeated_still_refuses(self):
        # The exact-section-count check stays even with a per-call nonce: it is what still
        # catches genuine framing corruption. Here the LIVE marker itself (not the MARKER
        # constant) shows up twice — vanishingly unlikely for a random 128-bit nonce, but this
        # proves the count check, not the nonce, is what would catch it.
        note = '{"type":"result","note":"' + FIXED_MARKER + '"}'
        with patch_uuid():
            poisoned = payload(marker=FIXED_MARKER, streams=(("/home/ubuntu/out/smoke", note),))
            r = remote.read(FakeRunner([(["ssh"], Result(0, poisoned, ""))]), MACHINE,
                            ["/home/ubuntu/out/smoke"])
        self.assertFalse(r["reachable"])
        self.assertIn("sections", r["error"])

    def test_two_read_calls_use_different_markers(self):
        runner = FakeRunner([(["ssh"], Result(255, "", "connection refused"))])
        remote.read(runner, MACHINE, [])
        remote.read(runner, MACHINE, [])
        self.assertEqual(len(runner.calls), 2)
        marker1, marker2 = marker_in_argv(runner.calls[0]), marker_in_argv(runner.calls[1])
        self.assertNotEqual(marker1, marker2)
        self.assertTrue(marker1.startswith(remote.MARKER))
        self.assertTrue(marker2.startswith(remote.MARKER))

    def test_missing_unit_list_sentinel_is_unreachable(self):
        # A `systemctl --user` that failed or never ran must not read as "zero units" — that
        # would grant the full local lane cap while lanes are actually running (finding 1).
        with patch_uuid():
            broken = payload(marker=FIXED_MARKER, units_ok=False)
            r = remote.read(FakeRunner([(["ssh"], Result(0, broken, ""))]), MACHINE,
                            ["/home/ubuntu/out/smoke"])
        self.assertFalse(r["reachable"])
        self.assertIn("unit list", r["error"])

    def test_empty_but_successful_unit_list_is_room_not_a_failure(self):
        # Zero lanes and an unreadable lane list are different answers; only the sentinel tells
        # them apart from an empty section.
        with patch_uuid():
            empty = payload(marker=FIXED_MARKER, units="", units_ok=True, streams=())
            r = remote.read(FakeRunner([(["ssh"], Result(0, empty, ""))]), MACHINE, [])
        self.assertTrue(r["reachable"])
        self.assertEqual(r["units"], [])
