import argparse, hashlib, json, os, shutil, sqlite3, subprocess, sys, tempfile, unittest
from unittest import mock
from pathlib import Path
from rabota import context
from rabota.commands import doctor
from rabota.runner import FakeRunner, Result
from rabota.store import SCHEMA_VERSION
from tests.support import last_json

FIX = Path(__file__).parent / "fixtures" / "config"

# The fixture tenant declares one seated machine (dev) with max_lanes_local 3 and the default
# lanes.memory_max of 6G, so 3 x 6 GiB = 18 GiB is what every slice row below is weighed against.
SSH_HEAD = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", "dev"]
SLICE_SCRIPT = "systemctl --user show 'agents.slice' -p MemoryMax -p MemoryHigh -p FragmentPath"
SLICE_CALL = SSH_HEAD + [SLICE_SCRIPT]

GIB = 1024 ** 3
DECLARED_UUID = "00000000-0000-0000-0000-00000000dev0"
DECLARED_DIGEST = hashlib.sha256(DECLARED_UUID.encode()).hexdigest()
OTHER_DIGEST = hashlib.sha256(b"some-other-account").hexdigest()


def slice_result(memory_max, memory_high="8589934592", fragment="/etc/systemd/user/agents.slice"):
    return Result(0, f"MemoryMax={memory_max}\nMemoryHigh={memory_high}\nFragmentPath={fragment}\n", "")


def account_result(digest=DECLARED_DIGEST, fetched="2026-09-20T15:00:00Z"):
    return Result(0, f"{digest}\n{fetched}\n", "")


def clauth_tree(case, uuid=DECLARED_UUID, profile="quantivly-0"):
    """A fixture clauth profiles root holding one profile's account_id.json."""
    tmp = tempfile.TemporaryDirectory(); case.addCleanup(tmp.cleanup)
    root = Path(tmp.name)
    (root / profile).mkdir(parents=True)
    (root / profile / "account_id.json").write_text(json.dumps(uuid))
    return root


def remote_ok():
    """Healthy answers for both of doctor's per-machine ssh calls.

    The slice call is matched on its EXACT argv, so any change to that script text falls through
    to the second entry and yields an account payload instead of a slice one -- which fails the
    row rather than passing it. Anything else doctor sends over ssh is the account probe.
    """
    return [(SLICE_CALL, slice_result(20 * GIB)), (["ssh"], account_result())]


def healthy_runner():
    return FakeRunner([
        (["readlink", "-f"], Result(0, str(Path.home() / ".dotfiles/scripts/rabota") + "\n", "")),
        (["systemctl", "--user", "is-enabled"], Result(0, "enabled\n", "")),
    ])


class DoctorTests(unittest.TestCase):
    def make_ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.state_dir = Path(tmp.name) / "state"
        ns = argparse.Namespace(tenant="toysim", state_dir=str(self.state_dir), text=False, dry_run=False, command="doctor")
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)   # nothing else owns it: the test builds it, so the test closes it
        return ctx

    def _stamp(self, version):
        """Write ``version`` into an existing rabota.db under the fixture state dir."""
        conn = sqlite3.connect(self.state_dir / "rabota.db")
        conn.execute("UPDATE schema_version SET version=?", (version,)); conn.commit(); conn.close()

    def test_reports_ok_when_links_and_timer_fine(self):
        runner = FakeRunner([
            (["readlink", "-f"], Result(0, str(Path.home() / ".dotfiles/scripts/rabota") + "\n", "")),
            (["systemctl", "--user", "is-enabled"], Result(0, "enabled\n", "")),
        ])
        report = doctor.run_doctor(self.make_ctx(runner))
        self.assertEqual(report["tenant"], "toysim")
        self.assertEqual(report["db_schema"], SCHEMA_VERSION)
        self.assertTrue(report["ok"], report["problems"])

    def test_timer_name_is_scoped_to_the_tenant(self):
        # §3.3 Step 1b: the unit is per-tenant (rabota-precompute@<tenant>.timer), not the
        # single shared name doctor.py used to check.
        #
        # Item 3 (WS5 fix round 2): asserting a single tenant here is satisfied by a
        # hardcoded literal — FakeRunner matches by argv *prefix*, so the canned
        # `["systemctl", "--user", "is-enabled"]` response fires no matter what tenant
        # suffix is passed. Only a name that varies with the tenant can pass this table.
        for tenant in ("quantivly", "toysim", "personal"):
            with self.subTest(tenant=tenant):
                tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
                runner = FakeRunner([
                    (["readlink", "-f"], Result(0, str(Path.home() / ".dotfiles/scripts/rabota") + "\n", "")),
                    (["systemctl", "--user", "is-enabled"], Result(0, "enabled\n", "")),
                    # quantivly is the only fixture tenant with a seated machine (dev); the
                    # others never call claude-pick or ssh, so these are unused for them.
                    (["claude-pick"], Result(0, json.dumps({"usage": {"cache_age_s": 30}}), "")),
                ] + remote_ok())
                ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name) / "state"),
                                        text=False, dry_run=False, command="doctor")
                ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))
                self.addCleanup(ctx.close)
                doctor.run_doctor(ctx, clauth_profiles=clauth_tree(self))
                timer_call = next(c for c in runner.calls if c[:3] == ["systemctl", "--user", "is-enabled"])
                self.assertEqual(timer_call[-1], f"rabota-precompute@{tenant}.timer")

    def test_schema_drift_is_a_problem(self):
        ctx = self.make_ctx(healthy_runner())
        ctx.store.close(); ctx._store = None     # create the DB, then age it behind the context's back
        self._stamp(0)
        report = doctor.run_doctor(ctx)
        self.assertFalse(report["ok"])
        self.assertEqual(report["db_schema"], 0)
        drift = [p for p in report["problems"] if "schema" in p]
        self.assertEqual(len(drift), 1, report["problems"])
        self.assertIn("0", drift[0]); self.assertIn(str(SCHEMA_VERSION), drift[0])

    def test_newer_schema_is_a_problem_not_a_crash(self):
        ctx = self.make_ctx(healthy_runner())
        ctx.store.close(); ctx._store = None
        self._stamp(SCHEMA_VERSION + 1)
        report = doctor.run_doctor(ctx)
        self.assertFalse(report["ok"])
        self.assertIsNone(report["db_schema"])
        drift = [p for p in report["problems"] if "schema" in p]
        self.assertEqual(len(drift), 1, report["problems"])
        self.assertIn(str(SCHEMA_VERSION + 1), drift[0]); self.assertIn(str(SCHEMA_VERSION), drift[0])

    def test_missing_timer_is_a_problem_not_a_crash(self):
        runner = FakeRunner([
            (["readlink", "-f"], Result(0, str(Path.home() / ".dotfiles/scripts/rabota") + "\n", "")),
            (["systemctl", "--user", "is-enabled"], Result(1, "", "Failed to get unit file state")),
        ])
        report = doctor.run_doctor(self.make_ctx(runner))
        self.assertFalse(report["ok"])
        self.assertTrue(any("timer" in p for p in report["problems"]))


class DoctorEndToEndTests(unittest.TestCase):
    """The real CLI, real subprocess children: a child that prints a protected value must not
    get that value onto either of rabota's streams (the WS1 review gate's reproduced leak)."""

    def test_child_output_carrying_a_protected_value_never_reaches_either_stream(self):
        canary = "lin_api_" + "canary" + "0123456789"   # assembled at runtime; not a real key
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        home = Path(tmp.name) / "home"
        shutil.copytree(FIX, home / ".dotfiles-local" / "rabota")
        fakebin = Path(tmp.name) / "bin"; fakebin.mkdir()
        fake = fakebin / "systemctl"
        fake.write_text(f"#!{sys.executable}\nimport os, sys\n"
                        "sys.stdout.write(os.environ.get('LINEAR_API_KEY', '') + '\\n')\n")
        fake.chmod(0o755)
        # The quantivly fixture declares machine dev, so doctor's two per-machine checks now
        # shell out to ssh. This is the ONE test in the file that runs the real CLI with a real
        # SubprocessRunner, so without a stub it would attempt a network connection from the
        # suite. It exits non-zero, which is a FAIL row — this test asserts the leak guard, not
        # the rows.
        stub_ssh = fakebin / "ssh"
        stub_ssh.write_text("#!/bin/sh\nexit 1\n")
        stub_ssh.chmod(0o755)
        env = {"HOME": str(home), "PATH": f"{fakebin}:/usr/bin:/bin", "LINEAR_API_KEY": canary}
        p = subprocess.run([sys.executable, "-m", "rabota", "--tenant", "quantivly",
                            "--state-dir", str(Path(tmp.name) / "state"), "doctor"],
                           cwd=Path(__file__).resolve().parents[1], env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertNotIn(canary, p.stdout)
        self.assertNotIn(canary, p.stderr)
        self.assertEqual(p.returncode, 5, p.stderr)
        self.assertEqual(last_json(p.stderr)["error"]["code"], "secret_leak")
        self.assertIn("LINEAR_API_KEY", p.stderr)
        self.assertNotIn("Traceback", p.stderr)


class SeatCacheAgeTests(unittest.TestCase):
    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner,
                                             env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

    def pick(self, age):
        return Result(0, json.dumps({"usage": {"five_hour": 5, "cache_age_s": age}}), "")

    def test_a_fresh_cache_passes(self):
        rows = doctor.seat_cache_age(self.ctx(FakeRunner([(["claude-pick"], self.pick(30))])))
        self.assertEqual([(n, ok) for n, ok, _ in rows], [("dev", True)])

    def test_a_stale_cache_fails_and_names_the_consequence(self):
        rows = doctor.seat_cache_age(self.ctx(FakeRunner([(["claude-pick"], self.pick(4000))])))
        self.assertFalse(rows[0][1])
        self.assertIn("credential:unmeasured", rows[0][2])

    def test_claude_pick_failing_is_a_fail_not_a_pass(self):
        rows = doctor.seat_cache_age(self.ctx(FakeRunner([(["claude-pick"], Result(5, "", "no clauth"))])))
        self.assertFalse(rows[0][1])

    def test_missing_cache_age_is_a_fail_not_a_zero(self):
        runner = FakeRunner([(["claude-pick"], Result(0, json.dumps({"usage": {}}), ""))])
        rows = doctor.seat_cache_age(self.ctx(runner))
        self.assertFalse(rows[0][1])

    def test_null_cache_age_is_a_fail_not_a_crash(self):
        # Task 8 correction 1: the brief's own version extracts `age` inside the try and
        # compares it OUTSIDE, so a refusal's null cache_age_s (documented in claude-pick's own
        # source) raises an uncaught TypeError instead of failing cleanly. The comparison must
        # live inside the guard.
        runner = FakeRunner([(["claude-pick"], Result(0, json.dumps({"usage": {"cache_age_s": None}}), ""))])
        rows = doctor.seat_cache_age(self.ctx(runner))
        self.assertFalse(rows[0][1])

    def test_the_report_names_the_declared_seat_and_claims_nothing_about_the_remote_login(self):
        # Task 8 correction 3 put a "NOT VERIFIED" clause on every row here, because no check on
        # the remote machine's own login existed. DO-654 added one (remote_seat_identity), which
        # emits a row per seated machine pass or fail — so this row must name the seat and the
        # cache age and say nothing about identity, rather than contradicting the row beside it.
        rows = doctor.seat_cache_age(self.ctx(FakeRunner([(["claude-pick"], self.pick(30))])))
        name, ok, detail = rows[0]
        self.assertTrue(ok)
        self.assertIn("quantivly-0", detail)
        self.assertIn("30s old", detail)
        self.assertNotIn("VERIFIED", detail)

    def test_claude_pick_is_called_with_dry_run(self):
        # Final review Finding 1: a health check must not build or reconcile an account dir as a
        # side effect of running. claude-pick's account-dir builder only runs when --dry-run is
        # absent, so its presence in the argv is the whole guarantee — assert it directly.
        runner = FakeRunner([(["claude-pick"], self.pick(30))])
        doctor.seat_cache_age(self.ctx(runner))
        call = next(c for c in runner.calls if c[:1] == ["claude-pick"])
        self.assertIn("--dry-run", call)

    def test_a_machine_with_no_profile_produces_no_row_and_no_claude_pick_call(self):
        # Review Minor 1: every fixture tenant has either no machines or one WITH a profile, so
        # `if not m.profile: continue` is unexercised. Add an unseated machine in the test rather
        # than editing the shared fixture.
        from rabota.config import Machine
        ctx = self.ctx(FakeRunner([(["claude-pick"], self.pick(30))]))
        ctx.tenant.machines["staging"] = Machine(name="staging", ssh="staging", tenants=["quantivly"])
        rows = doctor.seat_cache_age(ctx)
        self.assertEqual([n for n, _, _ in rows], ["dev"])
        claude_pick_calls = [c for c in ctx.runner.calls if c[:1] == ["claude-pick"]]
        self.assertEqual(len(claude_pick_calls), 1)


class SeatCacheDoctorWiringTests(unittest.TestCase):
    """run_doctor wires seat_cache_age's rows into its report and its exit status."""

    def make_ctx(self, runner, tenant="quantivly"):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name) / "state"),
                                text=False, dry_run=False, command="doctor")
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

    def healthy_base(self):
        return [
            (["readlink", "-f"], Result(0, str(Path.home() / ".dotfiles/scripts/rabota") + "\n", "")),
            (["systemctl", "--user", "is-enabled"], Result(0, "enabled\n", "")),
        ]

    def test_a_stale_seat_cache_fails_the_whole_report(self):
        runner = FakeRunner(self.healthy_base() + [
            (["claude-pick"], Result(0, json.dumps({"usage": {"cache_age_s": 4000}}), "")),
        ] + remote_ok())
        report = doctor.run_doctor(self.make_ctx(runner), clauth_profiles=clauth_tree(self))
        self.assertFalse(report["ok"])
        self.assertTrue(any("seat cache" in p for p in report["problems"]), report["problems"])

    def test_a_fresh_seat_cache_does_not_fail_the_report_on_its_own(self):
        runner = FakeRunner(self.healthy_base() + [
            (["claude-pick"], Result(0, json.dumps({"usage": {"cache_age_s": 30}}), "")),
        ] + remote_ok())
        report = doctor.run_doctor(self.make_ctx(runner), clauth_profiles=clauth_tree(self))
        self.assertTrue(report["ok"], report["problems"])
        self.assertEqual([(r["machine"], r["ok"]) for r in report["seat_cache"]], [("dev", True)])

    def test_a_tenant_with_no_seated_machines_reports_no_seat_cache_rows(self):
        runner = FakeRunner(self.healthy_base())
        report = doctor.run_doctor(self.make_ctx(runner, tenant="toysim"))
        self.assertEqual(report["seat_cache"], [])


class ParseSizeTests(unittest.TestCase):
    """systemd's size syntax. An unreadable value must raise, never become a number."""

    def test_the_measured_lane_cap_round_trips(self):
        # -p MemoryMax=6G showed as MemoryMax=6442450944 on dev, 2026-09-20. Base 1024, which is
        # what a base-1000 mutation gets wrong: 6e9 != 6442450944.
        self.assertEqual(doctor.parse_size("6G"), 6442450944)

    def test_each_suffix(self):
        for text, want in (("1048576", 1048576), ("512M", 512 * 1024 ** 2), ("2K", 2048),
                           ("1T", 1024 ** 4), ("6B", 6), ("6GB", 6 * 1024 ** 3), ("6g", 6 * 1024 ** 3)):
            with self.subTest(text=text):
                self.assertEqual(doctor.parse_size(text), want)

    def test_anything_unreadable_raises_value_error(self):
        # "inf"/"nan"/"1e3" are the ones float() would have swallowed, and int(float("inf"))
        # raises OverflowError rather than ValueError -- a different type, escaping the caller's
        # guard. A negative would have become a cap that every arithmetic check passes.
        for text in ("", "   ", "infinity", "inf", "nan", "1e3", "-5G", "G", "6X", "6 G B", "six"):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    doctor.parse_size(text)


class ParseShowTests(unittest.TestCase):
    def test_an_empty_value_is_present_not_missing(self):
        # FragmentPath= with nothing after it is the whole signal that a unit has no unit file.
        d = doctor.parse_show("MemoryMax=infinity\nFragmentPath=\n")
        self.assertIn("FragmentPath", d)
        self.assertEqual(d["FragmentPath"], "")

    def test_no_output_yields_no_keys(self):
        self.assertEqual(doctor.parse_show(""), {})

    def test_a_line_with_no_separator_is_ignored(self):
        self.assertEqual(doctor.parse_show("Failed to connect\nMemoryMax=5\n"), {"MemoryMax": "5"})


class SliceHeadroomTests(unittest.TestCase):
    """max_lanes_local x lanes.memory_max against the lane slice's own MemoryMax, per machine."""

    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner,
                                             env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

    def rows(self, result):
        return doctor.slice_headroom(self.ctx(FakeRunner([(SLICE_CALL, result)])))

    def test_a_slice_large_enough_passes_and_shows_its_arithmetic(self):
        rows = self.rows(slice_result(20 * GIB))
        self.assertEqual([(n, ok) for n, ok, _ in rows], [("dev", True)])
        self.assertIn("3 lanes x 6G = 18.0 GiB", rows[0][2])
        self.assertIn("20.0 GiB", rows[0][2])

    def test_an_oversubscribed_slice_fails_and_names_both_knobs(self):
        # dev's real numbers, measured 2026-09-21: MemoryMax 10 GiB, MemoryHigh 8 GiB, against
        # 3 x 6G admissible.
        rows = self.rows(slice_result(10 * GIB, memory_high=str(8 * GIB)))
        name, ok, detail = rows[0]
        self.assertFalse(ok)
        self.assertIn("OVER by 8.0 GiB", detail)
        self.assertIn("max_lanes_local", detail)
        self.assertIn("lanes.memory_max", detail)
        self.assertIn("8.0 GiB", detail)          # MemoryHigh, where throttling starts

    def test_a_machine_with_no_slice_unit_file_fails_even_though_memorymax_reads_infinity(self):
        # Measured on this laptop 2026-09-21: systemctl --user show agents.slice -p MemoryMax
        # prints "infinity" with LoadState=loaded for a slice that HAS NO UNIT FILE. Reading
        # MemoryMax alone calls that "unbounded, fine"; FragmentPath is what tells them apart.
        rows = self.rows(slice_result("infinity", fragment=""))
        name, ok, detail = rows[0]
        self.assertFalse(ok)
        self.assertIn("no agents.slice unit file", detail)
        self.assertIn("inside no budget", detail)

    def test_a_real_slice_that_sets_no_cap_passes_and_says_so(self):
        rows = self.rows(slice_result("infinity"))
        name, ok, detail = rows[0]
        self.assertTrue(ok)
        self.assertIn("no collective cap", detail)

    def test_an_unreachable_machine_fails_rather_than_reading_as_unlimited(self):
        rows = doctor.slice_headroom(self.ctx(FakeRunner([(["ssh"], Result(255, "", "ssh: connect: timed out"))])))
        name, ok, detail = rows[0]
        self.assertFalse(ok)
        self.assertIn("could not read", detail)

    def test_an_incomplete_property_list_fails_rather_than_defaulting(self):
        # systemctl exiting 0 with a truncated answer is the UNITS_OK failure again: a missing
        # property must not be read as an absent limit.
        rows = self.rows(Result(0, "MemoryMax=10737418240\n", ""))
        name, ok, detail = rows[0]
        self.assertFalse(ok)
        self.assertIn("MemoryHigh", detail)
        self.assertIn("FragmentPath", detail)

    def test_a_nonnumeric_memorymax_fails_rather_than_crashing(self):
        rows = self.rows(slice_result("lots"))
        name, ok, detail = rows[0]
        self.assertFalse(ok)
        self.assertIn("neither a byte count nor", detail)

    def test_an_unreadable_memory_max_config_fails_and_touches_no_machine(self):
        runner = FakeRunner([(SLICE_CALL, slice_result(20 * GIB))])
        ctx = self.ctx(runner)
        ctx.tenant.lanes.memory_max = "six gigs"
        rows = doctor.slice_headroom(ctx)
        self.assertFalse(rows[0][1])
        self.assertIn("unreadable", rows[0][2])
        self.assertEqual(runner.calls, [])     # no ssh call was made on a config we cannot read

    def test_the_slice_read_is_the_slice_a_lane_actually_joins(self):
        # doctor asserting a budget no lane is subject to is a green tick for the wrong cgroup,
        # so both sides must follow lane.LANE_SLICE rather than repeat a literal. Moving the
        # constant must move BOTH; a hardcoded "agents.slice" in either one fails here.
        #
        # The substitute shares no substring with the default on purpose: "other-agents.slice"
        # CONTAINS "agents.slice", so a hardcoded literal would have satisfied assertIn and this
        # row would have proved nothing.
        from rabota.commands import lane
        with mock.patch.object(lane, "LANE_SLICE", "lanes-only.slice"):
            runner = FakeRunner([(["ssh"], slice_result(20 * GIB))])
            ctx = self.ctx(runner)
            doctor.slice_headroom(ctx)
            doctor_script = runner.calls[0][-1]
            lane_cmd = lane.build_remote(ctx.tenant.machines["dev"], ["systemd-run", "/bin/claude"])[-1]
        self.assertIn("lanes-only.slice", doctor_script)
        self.assertNotIn("agents.slice", doctor_script)
        self.assertIn("--slice=lanes-only.slice", lane_cmd)
        self.assertNotIn("agents.slice", lane_cmd)

    def test_a_tenant_with_no_machines_produces_no_rows(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="toysim", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]),
                                             env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        self.assertEqual(doctor.slice_headroom(ctx), [])


class RemoteSeatIdentityTests(unittest.TestCase):
    """The seat [machines.<m>].profile DECLARES, against the account that machine really bills."""

    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner,
                                             env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

    def rows(self, result, root=None):
        runner = FakeRunner([(["ssh"], result)])
        self.runner = runner
        return doctor.remote_seat_identity(self.ctx(runner), root if root is not None else clauth_tree(self))

    def test_the_declared_seat_matching_the_machines_own_login_passes(self):
        rows = self.rows(account_result())
        name, ok, detail = rows[0]
        self.assertTrue(ok, detail)
        self.assertIn("quantivly-0", detail)

    def test_a_different_account_is_a_mismatch_and_names_the_leak(self):
        rows = self.rows(account_result(digest=OTHER_DIGEST))
        name, ok, detail = rows[0]
        self.assertFalse(ok)
        self.assertIn("MISMATCH", detail)
        self.assertIn("window the gate never metered", detail)

    def test_no_row_ever_prints_the_account_id_or_its_digest(self):
        # The whole premise of the check: an identifier never reaches a transcript. Both sides
        # are hashed before they travel, and the verdict is the only thing emitted.
        for result in (account_result(), account_result(digest=OTHER_DIGEST)):
            with self.subTest(result=result.out.split()[0][:8]):
                detail = self.rows(result)[0][2]
                self.assertNotIn(DECLARED_UUID, detail)
                self.assertNotIn(DECLARED_DIGEST, detail)
                self.assertNotIn(OTHER_DIGEST, detail)

    def test_the_record_age_reaches_the_row_so_a_stale_match_is_visible(self):
        # oauthAccount is the account the machine LAST RECORDED, not a live token check; the row
        # says when that record was fetched rather than implying the stronger claim.
        detail = self.rows(account_result(fetched="2024-01-01T00:00:00Z"))[0][2]
        self.assertIn("2024-01-01T00:00:00Z", detail)
        self.assertIn("not a live check", detail)

    def test_a_machine_with_no_recorded_account_is_unverified_not_a_mismatch(self):
        # The remote script prints "NONE" when oauthAccount carries no accountUuid.
        #
        # `ok` alone cannot carry this row: an unreadable reply differs from the declared digest,
        # so the mismatch branch also returns False and the row would pass with the shape check
        # deleted. What the check buys is the RIGHT DIAGNOSIS -- "could not read" rather than a
        # confident, alarming and wrong "this machine is on another account".
        name, ok, detail = self.rows(Result(0, "NONE\nunknown\n", ""))[0]
        self.assertFalse(ok)
        self.assertIn("UNVERIFIED", detail)
        self.assertNotIn("MISMATCH", detail)

    def test_a_reply_that_is_not_a_digest_is_unverified_not_a_mismatch(self):
        for out in ("", "\n\n", "not-a-digest\n2026-01-01\n", DECLARED_DIGEST[:-1] + "\n",
                    DECLARED_DIGEST.upper() + "\n", "  " + DECLARED_DIGEST + "x\n"):
            with self.subTest(out=repr(out)):
                name, ok, detail = self.rows(Result(0, out, ""))[0]
                self.assertFalse(ok)
                self.assertIn("UNVERIFIED", detail)
                self.assertNotIn("MISMATCH", detail)

    def test_an_unreachable_machine_fails_rather_than_falling_silent(self):
        name, ok, detail = self.rows(Result(255, "", "ssh: connect: timed out"))[0]
        self.assertFalse(ok)
        self.assertIn("UNVERIFIED", detail)
        self.assertNotIn("MISMATCH", detail)

    def test_no_local_account_record_fails_and_touches_no_machine(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        runner = FakeRunner([(["ssh"], account_result())])
        rows = doctor.remote_seat_identity(self.ctx(runner), Path(tmp.name))
        self.assertFalse(rows[0][1])
        self.assertIn("no readable account id", rows[0][2])
        self.assertEqual(runner.calls, [])    # nothing to compare against, so nothing is asked

    def _with_local_record(self, payload):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        root = Path(tmp.name); (root / "quantivly-0").mkdir()
        (root / "quantivly-0" / "account_id.json").write_text(payload)
        runner = FakeRunner([(["ssh"], account_result())])
        return doctor.remote_seat_identity(self.ctx(runner), root)[0], runner

    def test_a_local_record_that_is_not_a_string_is_unverified_not_a_mismatch(self):
        # Read a JSON value's type before using it: json.loads of {} or 42 both decode fine, and
        # str(value).encode() would hash a repr and compare it happily.
        #
        # `ok` alone cannot carry this row either -- the repr's digest differs from the machine's,
        # so the MISMATCH branch also returns False and dropping the type check left all 417
        # green (mutation M15, the one survivor of the first sweep). A broken LOCAL record must
        # not be reported as "that machine is on another account": the diagnosis sends the reader
        # to the wrong machine.
        for payload in ("{}", "42", "null", '""', "[]", '{"id": "x"}'):
            with self.subTest(payload=payload):
                (name, ok, detail), runner = self._with_local_record(payload)
                self.assertFalse(ok)
                self.assertIn("no readable account id", detail)
                self.assertNotIn("MISMATCH", detail)
                self.assertEqual(runner.calls, [])

    def test_a_corrupt_local_record_is_unverified_not_a_mismatch(self):
        (name, ok, detail), runner = self._with_local_record("{not json")
        self.assertFalse(ok)
        self.assertIn("no readable account id", detail)
        self.assertNotIn("MISMATCH", detail)
        self.assertEqual(runner.calls, [])

    def test_a_machine_with_no_profile_produces_no_row_and_no_ssh_call(self):
        from rabota.config import Machine
        runner = FakeRunner([(["ssh"], account_result())])
        ctx = self.ctx(runner)
        ctx.tenant.machines["staging"] = Machine(name="staging", ssh="staging", tenants=["quantivly"])
        rows = doctor.remote_seat_identity(ctx, clauth_tree(self))
        self.assertEqual([n for n, _, _ in rows], ["dev"])
        self.assertEqual(len(runner.calls), 1)

    def test_the_remote_script_reads_the_file_a_remote_lane_itself_resolves(self):
        # build_local omits CLAUDE_CONFIG_DIR for a remote machine, so a lane there uses the
        # machine's own defaults, which pair ~/.claude as the dir with ~/.claude.json at HOME
        # level. Reading <home>/.claude/.claude.json instead would check a file no lane uses --
        # and dev really has a stale one of those, left by the first live smoke.
        self.rows(account_result())
        script = self.runner.calls[0][-1]
        self.assertIn('"~/.claude.json"', script)
        self.assertNotIn(".claude/.claude.json", script)
        self.assertIn("sha256", script)
        self.assertIn("accountUuid", script)


class CrossMachineWiringTests(unittest.TestCase):
    """Both new checks reach the report body AND the exit status."""

    def make_ctx(self, runner, tenant="quantivly"):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name) / "state"),
                                text=False, dry_run=False, command="doctor")
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

    def base(self, *extra):
        return FakeRunner([
            (["readlink", "-f"], Result(0, str(Path.home() / ".dotfiles/scripts/rabota") + "\n", "")),
            (["systemctl", "--user", "is-enabled"], Result(0, "enabled\n", "")),
            (["claude-pick"], Result(0, json.dumps({"usage": {"cache_age_s": 30}}), "")),
        ] + list(extra))

    def test_a_healthy_machine_reports_both_rows_and_stays_ok(self):
        report = doctor.run_doctor(self.make_ctx(self.base(*remote_ok())),
                                   clauth_profiles=clauth_tree(self))
        self.assertTrue(report["ok"], report["problems"])
        self.assertEqual([(r["machine"], r["ok"]) for r in report["slice_headroom"]], [("dev", True)])
        self.assertEqual([(r["machine"], r["ok"]) for r in report["remote_seat"]], [("dev", True)])

    def test_an_oversubscribed_slice_fails_the_whole_report(self):
        runner = self.base((SLICE_CALL, slice_result(10 * GIB)), (["ssh"], account_result()))
        report = doctor.run_doctor(self.make_ctx(runner), clauth_profiles=clauth_tree(self))
        self.assertFalse(report["ok"])
        self.assertTrue(any("lane memory budget" in p for p in report["problems"]), report["problems"])

    def test_a_seat_mismatch_fails_the_whole_report(self):
        runner = self.base((SLICE_CALL, slice_result(20 * GIB)),
                           (["ssh"], account_result(digest=OTHER_DIGEST)))
        report = doctor.run_doctor(self.make_ctx(runner), clauth_profiles=clauth_tree(self))
        self.assertFalse(report["ok"])
        self.assertTrue(any("declared seat" in p for p in report["problems"]), report["problems"])

    def test_a_tenant_with_no_machines_reports_both_as_empty(self):
        report = doctor.run_doctor(self.make_ctx(self.base(), tenant="toysim"))
        self.assertEqual(report["slice_headroom"], [])
        self.assertEqual(report["remote_seat"], [])


class FetchedAtTests(unittest.TestCase):
    """profileFetchedAt is a millisecond epoch, not the ISO string its name implies."""

    def test_the_measured_millisecond_epoch_renders_as_a_date(self):
        # Read off dev 2026-09-21. Every hermetic row here fed an ISO string, because that is the
        # shape the field NAME implies — the live run is what showed "fetched 1789895607090".
        self.assertEqual(doctor._fetched_at("1789895607090"), "2026-09-20T09:13:27Z")
        self.assertEqual(doctor._fetched_at(1789895607090), "2026-09-20T09:13:27Z")

    def test_a_seconds_epoch_is_not_scaled(self):
        self.assertEqual(doctor._fetched_at("1789895607"), "2026-09-20T09:13:27Z")

    def test_an_iso_string_passes_through(self):
        self.assertEqual(doctor._fetched_at("2026-09-20T15:00:00Z"), "2026-09-20T15:00:00Z")

    def test_anything_unrenderable_is_unknown_not_a_raw_number(self):
        for value in (None, "", "   ", [], {}, "9" * 40):
            with self.subTest(value=value):
                self.assertIn(doctor._fetched_at(value), ("unknown",))

    def test_the_row_carries_the_rendered_date_not_the_epoch(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        runner = FakeRunner([(["ssh"], account_result(fetched="1789895607090"))])
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner,
                                             env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        detail = doctor.remote_seat_identity(ctx, clauth_tree(self))[0][2]
        self.assertIn("2026-09-20T09:13:27Z", detail)
        self.assertNotIn("1789895607090", detail)
