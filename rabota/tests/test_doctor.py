import argparse, hashlib, json, os, shutil, sqlite3, subprocess, sys, tempfile, unittest
from datetime import datetime, timedelta, timezone
from unittest import mock
from pathlib import Path
from rabota import context, errors, store
from rabota.commands import doctor, lane
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


def pin_tenant_root(case, ctx, *repos):
    """Point ``ctx.tenant.root`` at a fresh tree holding ``repos`` as git checkouts.

    DO-776 gave ``run_doctor`` a row about the tenant's own ``root``, and the fixture tenants
    name ``~/quantivly`` and ``~/toysim`` — real directories, holding a real ``hub``, on the
    machine this suite was written on. Left unpinned, every row asserting ``report["ok"]``
    answers from the runner's filesystem: green here, red on a CI runner with no such tree, and
    green for the wrong reason either way. Pinning the local side is the same fix
    ``test_lane_recipe``'s ``LOCAL_HOME`` makes one level down (DO-669).
    """
    tmp = tempfile.TemporaryDirectory(); case.addCleanup(tmp.cleanup)
    root = Path(tmp.name)
    for r in repos:
        (root / r).mkdir(parents=True)
        (root / r / ".git").mkdir()
    ctx.tenant.root = root
    return root


def pin_tenant_stores(case, ctx):
    """Point every OTHER fixture tenant's ``state_dir`` at a fresh, empty directory.

    DO-818's scheduler checks read every tenant's store, and the fixture tenants' state dirs
    expand to real paths under ``~`` -- which hold this user's live stores on the machine this
    suite was written on. Left unpinned, a row answers from those: the same trap
    ``pin_tenant_root`` closes for the tenant's ``root``. The caller's own tenant is read from
    ``ctx.state_dir``, which every builder here already points into a temp dir.
    """
    tmp = tempfile.TemporaryDirectory(); case.addCleanup(tmp.cleanup)
    for name, t in ctx.cfg.tenants.items():
        if name != ctx.tenant.name:
            t.state_dir = Path(tmp.name) / name
    return Path(tmp.name)


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
        pin_tenant_root(self, ctx, "widgets")
        pin_tenant_stores(self, ctx)
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
                pin_tenant_stores(self, ctx)
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
        # "hub" is the one repo key the quantivly fixture's [machines.dev].repos declares; the
        # toysim fixture declares none, and any checkout answers its row.
        pin_tenant_root(self, ctx, "hub")
        pin_tenant_stores(self, ctx)
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
    """The seat CLAUDE_TENANT_MACHINE_ID DECLARES, against the account that machine really bills."""

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
        # The fix it names is the table that declares the seat (DO-811), not the tenant TOML,
        # where a `profile` key is refused outright since DO-665.
        self.assertIn("CLAUDE_TENANT_MACHINE_ID", detail)
        self.assertNotIn(".toml", detail)

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


class TenantRootTests(unittest.TestCase):
    """DO-776: the tenant's own ``root``, and which of its expected repos are checked out there.

    ``lane recipe`` refuses a local ``--repo`` it cannot reach; this is the same question asked
    for the whole tenant, before any lane. Every row builds the tree it asserts against — the
    fixture roots are real directories on the machine this was written on (see
    :func:`pin_tenant_root`), so an unpinned row is green for the runner's filesystem rather than
    for the code.
    """

    def ctx(self, tenant="quantivly", *, repos=(), plain=(), root=None):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name) / "state"),
                                text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]),
                                             env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        base = Path(tmp.name) / "root"
        base.mkdir()
        for r in repos:
            (base / r).mkdir(); (base / r / ".git").mkdir()
        for d in plain:
            (base / d).mkdir()
        ctx.tenant.root = base if root is None else root
        return ctx

    def row(self, **kw):
        rows = doctor.tenant_repos(self.ctx(**kw))
        self.assertEqual(len(rows), 1, rows)   # exactly one row per tenant, pass or fail
        return rows[0]

    def test_a_root_holding_the_declared_repo_passes_and_names_it(self):
        name, ok, detail = self.row(repos=("hub",))
        self.assertEqual(name, "quantivly")
        self.assertTrue(ok, detail)
        self.assertIn("resolves 1 of the 1 repo key", detail)
        self.assertIn("'hub'", detail)

    def test_a_root_that_is_not_a_directory_fails_and_names_the_consequence(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        name, ok, detail = self.row(root=Path(tmp.name) / "no-such-root")
        self.assertFalse(ok)
        self.assertIn("is not a directory", detail)
        self.assertIn("every local lane", detail)
        self.assertIn("tenants/quantivly.toml", detail)

    def test_a_root_resolving_no_declared_repo_fails_rather_than_passing_quietly(self):
        # The root EXISTS and holds a checkout — just not the one the tenant's machines declare.
        # "root is there" is not the question; "can this tenant reach what it expects" is.
        name, ok, detail = self.row(repos=("unrelated",))
        self.assertFalse(ok)
        self.assertIn("no declared repo resolves", detail)
        self.assertIn("'hub'", detail)

    def test_a_partial_answer_passes_and_names_what_is_missing(self):
        """A repo declared for a remote machine need not also be cloned on this one — that is the
        normal state of a laptop against dev — so FAIL is "reaches nothing", not "reaches less
        than everything". The fixture declares one key, so the partial case is built by hand."""
        ctx = self.ctx(repos=("hub",))
        ctx.tenant.machines["dev"].repos["extra"] = "~/quantivly/extra"
        name, ok, detail = doctor.tenant_repos(ctx)[0]
        self.assertTrue(ok, detail)
        self.assertIn("resolves 1 of the 2 repo keys", detail)
        self.assertIn("not checked out here: ['extra']", detail)

    def test_a_declared_repo_counts_on_is_dir_exactly_as_the_lane_refusal_accepts_it(self):
        """The lane's own guard accepts a directory, not a git checkout (``lane.local_repo_path``
        says why). If doctor asked the stricter question it would FAIL a tenant whose lanes all
        start fine — two answers to one question, which is the defect class this issue is in."""
        name, ok, detail = self.row(plain=("hub",))
        self.assertTrue(ok, detail)

    def test_a_tenant_declaring_no_machine_repos_falls_back_to_any_checkout(self):
        name, ok, detail = self.row(tenant="toysim", repos=("widgets",))
        self.assertEqual(name, "toysim")
        self.assertTrue(ok, detail)
        self.assertIn("1 git checkout", detail)
        self.assertIn("widgets", detail)

    def test_a_tenant_declaring_no_machine_repos_fails_on_an_empty_root(self):
        name, ok, detail = self.row(tenant="toysim", plain=("notes",))
        self.assertFalse(ok)
        self.assertIn("holds no git checkout", detail)

    def test_an_unlistable_root_is_unmeasured_not_empty(self):
        """``local_repos`` answers ``None`` rather than ``[]`` when ``iterdir`` raises, and the
        row must carry that distinction through: a root nobody could read reported as "holds no
        git checkout" sends the reader to clone what may already be there."""
        ctx = self.ctx(tenant="toysim", repos=("widgets",))
        with mock.patch.object(Path, "iterdir", side_effect=PermissionError(13, "denied")):
            name, ok, detail = doctor.tenant_repos(ctx)[0]
        self.assertFalse(ok)
        self.assertIn("UNMEASURED", detail)
        self.assertNotIn("holds no git checkout", detail)

    def test_the_check_touches_no_machine(self):
        ctx = self.ctx(repos=("hub",))
        doctor.tenant_repos(ctx)
        self.assertEqual(ctx.runner.calls, [])


class DeclaredReposTests(unittest.TestCase):
    """DO-773: a tenant declaring ``[repos]`` is checked against that table, not against its root.

    The two vocabularies must be the SAME two ``lane.local_repo_path`` uses. A doctor that asked
    the stricter question would FAIL a tenant whose lanes all start fine, and one that asked the
    looser would pass a tenant whose every lane refuses — both are the defect this issue is about,
    reappearing in the check written to catch it.
    """

    def ctx(self, **repos):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name) / "state"),
                                text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]),
                                             env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        base = Path(tmp.name) / "elsewhere"
        base.mkdir()
        # A root that holds NOTHING. Every row here passes or fails on the table alone, so a
        # root still being weighed would show up as a row that cannot be satisfied.
        ctx.tenant.root = Path(tmp.name) / "unused-root"
        ctx.tenant.root.mkdir()
        ctx.tenant.repos = {}
        for key, present in repos.items():
            path = base / key
            if present:
                path.mkdir(); (path / ".git").mkdir()
            ctx.tenant.repos[key] = str(path)
        return ctx

    def row(self, **repos):
        rows = doctor.tenant_repos(self.ctx(**repos))
        self.assertEqual(len(rows), 1, rows)
        return rows[0]

    def test_all_declared_repos_present_passes_and_counts_them(self):
        name, ok, detail = self.row(dotfiles=True, hub=True)
        self.assertTrue(ok, detail)
        self.assertIn("declares 2 repos", detail)
        self.assertIn("2 of them here", detail)

    def test_a_partial_answer_passes_and_names_the_missing_path(self):
        name, ok, detail = self.row(dotfiles=True, hub=False)
        self.assertTrue(ok, detail)
        self.assertIn("not a directory here", detail)
        self.assertIn("hub -> ", detail)          # the PATH, which is what the reader must fix
        self.assertNotIn("dotfiles -> ", detail)  # and not the one that is fine

    def test_nothing_reachable_by_EITHER_route_fails(self):
        """The row follows the lane: a tenant fails only when neither the table nor the root can
        give it a --repo. Here the table resolves nothing and the root is empty."""
        name, ok, detail = self.row(dotfiles=False, hub=False)
        self.assertFalse(ok)
        self.assertIn("not a directory here", detail)
        self.assertIn("nothing it can be given", detail)

    def test_a_missing_root_does_not_fail_a_tenant_whose_table_reaches_something(self):
        """A root that is not there and a tenant that is fine: its declared repo resolves, so its
        lanes start. Failing it here would be doctor disagreeing with the command it checks."""
        ctx = self.ctx(dotfiles=True)
        ctx.tenant.root = Path("/no/such/root/anywhere")
        name, ok, detail = doctor.tenant_repos(ctx)[0]
        self.assertTrue(ok, detail)
        self.assertIn("nothing needs it", detail)

    def test_a_key_the_table_resolved_is_not_ALSO_reported_missing_from_the_root(self):
        """Found on the live machine the day DO-773 deployed. The quantivly row read
        ``1 of them here: ['dotfiles'] ... not checked out here: ['dotfiles']`` — a PASSING row
        naming a reachable repo as missing, which is this repo's "a derived complaint printed
        beside its own cause" shape and sends a reader to fix what is already right.

        The fixture is the real shape: a machine declares ``dotfiles`` as a repo KEY, the tenant's
        ``[repos]`` table resolves it to a path outside the root, and the root does not and never
        will contain it.
        """
        ctx = self.ctx(dotfiles=True)
        ctx.tenant.machines["dev"].repos["dotfiles"] = "~/elsewhere/dotfiles"
        name, ok, detail = doctor.tenant_repos(ctx)[0]
        self.assertTrue(ok, detail)
        self.assertIn("1 of them here: ['dotfiles']", detail)
        # THE SEGMENT, not a fixed rendering of the whole list. The first cut of this row
        # asserted `not in` against "not checked out here: ['dotfiles']", which only matches when
        # that list has exactly one element — the fixture also leaves 'hub' unresolved, so the
        # mutant printed "['dotfiles', 'hub']", the needle missed, and the row passed against the
        # very defect it was written for. Caught by mutation, not by the suite.
        missing_segment = detail.split("not checked out here:", 1)[-1] if \
            "not checked out here:" in detail else ""
        self.assertNotIn("dotfiles", missing_segment, f"reported as missing although resolved: {detail}")

    def test_a_key_NEITHER_side_resolves_is_still_reported_once(self):
        """The paired half, so the fix cannot be "stop reporting missing keys at all"."""
        ctx = self.ctx(dotfiles=False)
        ctx.tenant.machines["dev"].repos["dotfiles"] = "~/elsewhere/dotfiles"
        name, ok, detail = doctor.tenant_repos(ctx)[0]
        self.assertIn("not a directory here", detail)      # the [repos] side says so
        self.assertIn("'dotfiles'", detail)

    def test_the_row_agrees_with_what_the_lane_would_actually_do(self):
        """The coupling itself, asserted rather than assumed: for each declared key, doctor's
        verdict and ``lane.local_repo_path`` must agree about whether it is reachable."""
        ctx = self.ctx(dotfiles=True, hub=False)
        for key, reachable in (("dotfiles", True), ("hub", False)):
            with self.subTest(key=key):
                try:
                    lane.local_repo_path(ctx.tenant, key)
                    lane_ok = True
                except errors.Refused:
                    lane_ok = False
                self.assertEqual(lane_ok, reachable)
        self.assertTrue(doctor.tenant_repos(ctx)[0][1])   # one resolves, so the row passes


class TenantRootWiringTests(unittest.TestCase):
    """The row reaches the report body AND the exit status — a check nothing wires in is decoration."""

    def make_ctx(self, runner, tenant="toysim"):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name) / "state"),
                                text=False, dry_run=False, command="doctor")
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env={"PATH": "/bin"},
                                             cwd=Path("/"))
        self.addCleanup(ctx.close)
        pin_tenant_stores(self, ctx)
        return ctx

    def test_a_healthy_root_reports_a_passing_row_and_does_not_fail_the_report(self):
        ctx = self.make_ctx(healthy_runner())
        pin_tenant_root(self, ctx, "widgets")
        report = doctor.run_doctor(ctx)
        self.assertTrue(report["ok"], report["problems"])
        self.assertEqual([(r["tenant"], r["ok"]) for r in report["tenant_repos"]], [("toysim", True)])

    def test_an_unreachable_root_fails_the_whole_report_and_is_named_in_problems(self):
        ctx = self.make_ctx(healthy_runner())
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ctx.tenant.root = Path(tmp.name) / "no-such-root"
        report = doctor.run_doctor(ctx)
        self.assertFalse(report["ok"])
        self.assertEqual([r["ok"] for r in report["tenant_repos"]], [False])
        self.assertTrue(any("tenant repos" in p for p in report["problems"]), report["problems"])

    def test_the_root_problem_is_reported_ahead_of_the_cross_machine_ones(self):
        """``problems`` is joined into the refusal text, so its order is what a reader sees first.
        A tenant that can reach no repo explains every machine row under it — a laptop with no
        checkout still fails its slice and seat checks — and putting it last buries the cause
        under three consequences. Every row here is red, so the order is the only thing asserted.
        """
        # The install link and the timer are HEALTHY: they are checked before any of the row
        # checks and would otherwise sit at the head of `problems` and satisfy nothing about it.
        runner = FakeRunner(healthy_runner().responses + [
            (["claude-pick"], Result(5, "", "no clauth")),
            (["ssh"], Result(1, "", "unreachable")),
        ])
        ctx = self.make_ctx(runner, tenant="quantivly")
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ctx.tenant.root = Path(tmp.name) / "no-such-root"
        problems = doctor.run_doctor(ctx, clauth_profiles=clauth_tree(self))["problems"]
        kinds = [p.split(":")[0] for p in problems]
        self.assertEqual(kinds[0], "tenant repos for 'quantivly'")
        for later in ("seat cache for machine 'dev'", "lane memory budget on machine 'dev'",
                      "declared seat on machine 'dev'"):
            self.assertIn(later, kinds)


class CrossMachineWiringTests(unittest.TestCase):
    """Both new checks reach the report body AND the exit status."""

    def make_ctx(self, runner, tenant="quantivly"):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name) / "state"),
                                text=False, dry_run=False, command="doctor")
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        # "hub" is the one repo key the quantivly fixture's [machines.dev].repos declares; the
        # toysim fixture declares none, and any checkout answers its row.
        pin_tenant_root(self, ctx, "hub")
        pin_tenant_stores(self, ctx)
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


# --- the scheduler's queue (DO-818) -------------------------------------------------------------

S_NOW = datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc)
S_MIN = timedelta(minutes=1)
READLINK = (["readlink", "-f"], Result(0, str(Path.home() / ".dotfiles/scripts/rabota") + "\n", ""))
PRECOMPUTE = (["systemctl", "--user", "is-enabled", "rabota-precompute@toysim.timer"], Result(0, "enabled\n", ""))
ENABLED = Result(0, "enabled\n", "")

# One needle per row kind, each in that kind's text and in no other's (test_needles_are_unique).
NEEDLES = {"timer-armed": "timer is enabled", "timer-disarmed": "is NOT enabled",
           "timer-idle": "has nothing to fire", "timer-unmeasured": "doctor does not migrate",
           "overdue-pass": "no pending run is more than", "overdue-fail": "and is still pending",
           "stuck-pass": "no running run is past its timeout", "stuck-fail": "has been running",
           "stuck-unmeasured": "is running with no started_at"}


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def sched(sid, tenant="toysim", status="pending", due=S_NOW - 5 * S_MIN, started=None, timeout_s=900,
          last_reason=None, title="count refusals", kind="command"):
    """One schedules row, as the store returns it and as ``insert_schedule`` takes it."""
    return {"id": sid, "tenant": tenant, "kind": kind, "title": title, "cwd": "/tmp",
            "payload_path": f"/x/schedules/{sid}/script", "payload_sha256": "0" * 64,
            "not_before": _iso(due), "expires_at": _iso(due + timedelta(hours=48)),
            "timeout_s": timeout_s, "memory_max": "1G", "max_attempts": 2, "status": status,
            "attempt": 1 if status == "running" else 0, "last_reason": last_reason,
            "unit": f"rabota-sched-{tenant}-{sid}-a1.service" if status == "running" else None,
            "started_at": _iso(started) if started else None, "created_at": _iso(S_NOW - timedelta(days=1))}


def is_enabled(tenant, result=ENABLED):
    """A response keyed on the WHOLE argv, so a call for any other unit falls through and fails."""
    return (["systemctl", "--user", "is-enabled", f"rabota-schedule@{tenant}.timer"], result)


def stamp(state_dir, version):
    conn = sqlite3.connect(Path(state_dir) / "rabota.db")
    conn.execute("UPDATE schema_version SET version=?", (version,)); conn.commit(); conn.close()


def stamped(state_dir):
    conn = sqlite3.connect(Path(state_dir) / "rabota.db")
    try:
        return conn.execute("SELECT version FROM schema_version").fetchone()[0]
    finally:
        conn.close()


class SchedulerHealthBase(unittest.TestCase):
    """The caller is toysim (no machines, so no ssh); personal and quantivly are the OTHER tenants."""

    def make_ctx(self, *responses):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.runner = FakeRunner([READLINK, PRECOMPUTE] + list(responses))
        ns = argparse.Namespace(tenant="toysim", state_dir=str(Path(tmp.name) / "state"),
                                text=False, dry_run=False, command="doctor")
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=self.runner, env={"PATH": "/bin"},
                                             cwd=Path("/"))
        self.addCleanup(ctx.close)
        pin_tenant_root(self, ctx, "widgets")
        pin_tenant_stores(self, ctx)
        return ctx

    def put(self, ctx, tenant, *rows):
        """Write ``rows`` into ``tenant``'s own store: the caller's through its context, any other's directly."""
        if tenant == ctx.tenant.name:
            for r in rows:
                ctx.store.insert_schedule(r)
            return ctx.state_dir
        state_dir = Path(ctx.cfg.tenants[tenant].state_dir)
        s = store.Store.open(state_dir)
        try:
            for r in rows:
                s.insert_schedule({**r, "tenant": tenant})
        finally:
            s.close()
        return state_dir

    def stores(self, **by_tenant):
        """A ``schedule_stores`` result built by hand, for the checks that only read it."""
        return {t: {"rows": rows, "why": None} for t, rows in sorted(by_tenant.items())}

    def unsched_calls(self):
        return [c for c in self.runner.calls if c[-1].startswith("rabota-schedule@")]


class ScheduleTimerTests(SchedulerHealthBase):
    """Check 1: every tenant that has pending runs has its rabota-schedule@ timer enabled."""

    def test_pending_runs_and_an_enabled_timer_pass_asking_for_that_tenants_unit(self):
        ctx = self.make_ctx(is_enabled("toysim"))
        rows = doctor.schedule_timers(ctx, self.stores(toysim=[sched("s-1"), sched("s-2")]))
        self.assertEqual(rows, [("toysim", True, "'toysim' has 2 pending runs and "
                                                 "rabota-schedule@toysim.timer is enabled")])
        self.assertIn(NEEDLES["timer-armed"], rows[0][2])
        self.assertEqual(self.unsched_calls(), [["systemctl", "--user", "is-enabled", "rabota-schedule@toysim.timer"]])

    def test_pending_runs_and_a_timer_that_is_not_enabled_fail_naming_runs_state_and_remedy(self):
        # `static` exits 0 and is still not armed: the state is read, not just the exit code.
        for res, state in ((Result(1, "disabled\n", ""), "disabled"), (Result(4, "not-found\n", ""), "not-found"),
                           (Result(0, "static\n", ""), "static"), (Result(1, "", "Failed to connect to bus"),
                                                                    "Failed to connect to bus")):
            with self.subTest(state=state):
                ctx = self.make_ctx(is_enabled("toysim", res))
                [(name, ok, detail)] = doctor.schedule_timers(ctx, self.stores(toysim=[sched("s-1")]))
                self.assertEqual((name, ok), ("toysim", False))
                self.assertIn(NEEDLES["timer-disarmed"], detail)
                self.assertIn(f"({state})", detail)
                self.assertIn("(s-1)", detail)
                self.assertIn("systemctl --user enable --now rabota-schedule@toysim.timer", detail)

    def test_a_tenant_with_no_pending_run_passes_and_asks_systemd_nothing(self):
        ctx = self.make_ctx()        # no is-enabled response: a call would fail the row
        rows = doctor.schedule_timers(ctx, self.stores(
            toysim=[sched("s-1", status="running", started=S_NOW), sched("s-2", status="done")], personal=[]))
        self.assertEqual([(n, ok) for n, ok, _ in rows], [("personal", True), ("toysim", True)])
        self.assertTrue(all(NEEDLES["timer-idle"] in d for _, _, d in rows), rows)
        self.assertEqual(self.unsched_calls(), [])

    def test_another_tenants_pending_run_is_weighed_against_ITS_timer_and_fails_this_report(self):
        ctx = self.make_ctx(is_enabled("personal", Result(1, "disabled\n", "")))
        self.put(ctx, "personal", sched("s-p1"))
        report = doctor.run_doctor(ctx, now=S_NOW)
        self.assertFalse(report["ok"])
        self.assertEqual({r["tenant"]: r["ok"] for r in report["schedule_timers"]},
                         {"personal": False, "quantivly": True, "toysim": True})
        self.assertTrue(any(p.startswith("schedule timer for 'personal': ") for p in report["problems"]),
                        report["problems"])

    def test_a_store_older_than_the_schedules_table_holds_no_run_and_is_not_migrated(self):
        ctx = self.make_ctx()
        d = self.put(ctx, "personal")
        stamp(d, 4)
        got = doctor.schedule_stores(ctx)["personal"]
        self.assertEqual(got["rows"], [])
        [(_, ok, detail)] = [r for r in doctor.schedule_timers(ctx, {"personal": got})]
        self.assertTrue(ok)
        self.assertIn("schema 4, older than the schedules table", detail)
        self.assertEqual(stamped(d), 4)

    def test_a_newer_store_is_unmeasured_and_fails_and_is_not_migrated(self):
        ctx = self.make_ctx()
        d = self.put(ctx, "personal", sched("s-p1"))
        stamp(d, SCHEMA_VERSION + 1)
        report = doctor.run_doctor(ctx, now=S_NOW)
        [row] = [r for r in report["schedule_timers"] if r["tenant"] == "personal"]
        self.assertFalse(row["ok"])
        self.assertIn(NEEDLES["timer-unmeasured"], row["detail"])
        self.assertIn(f"is at schema {SCHEMA_VERSION + 1}", row["detail"])
        self.assertFalse(report["ok"])
        self.assertEqual(stamped(d), SCHEMA_VERSION + 1)
        self.assertEqual(self.unsched_calls(), [])

    def test_a_tenant_with_no_store_passes_and_none_is_created(self):
        ctx = self.make_ctx()
        got = doctor.schedule_stores(ctx)
        self.assertEqual(got["quantivly"]["rows"], [])
        self.assertIn("has no store at", got["quantivly"]["why"])
        self.assertFalse(Path(ctx.cfg.tenants["quantivly"].state_dir).exists())

    def test_the_callers_own_store_is_read_from_its_state_dir_override(self):
        ctx = self.make_ctx()
        ctx.tenant.state_dir = Path("/nonexistent/should-not-be-read")
        self.put(ctx, "toysim", sched("s-own"))
        self.assertEqual([r["id"] for r in doctor.schedule_stores(ctx)["toysim"]["rows"]], ["s-own"])

    def test_the_callers_own_unreadable_store_is_not_listed_twice(self):
        # The schema problem already names it; the timer row stays in the report, failing.
        ctx = self.make_ctx()
        ctx.store.close(); ctx._store = None
        stamp(ctx.state_dir, SCHEMA_VERSION + 1)
        report = doctor.run_doctor(ctx, now=S_NOW)
        [row] = [r for r in report["schedule_timers"] if r["tenant"] == "toysim"]
        self.assertFalse(row["ok"])
        self.assertEqual([p for p in report["problems"] if "schedule timer" in p], [])


class ScheduleOverdueTests(SchedulerHealthBase):
    """Check 2: no run due more than 30 minutes ago is still pending; a failure names each and its last_reason."""

    def test_a_run_due_exactly_the_threshold_ago_passes_with_one_row_naming_the_stores_read(self):
        rows = doctor.schedule_overdue(self.stores(toysim=[sched("s-1", due=S_NOW - doctor.OVERDUE_AFTER)],
                                                   personal=[]), S_NOW)
        self.assertEqual(rows, [(None, True, "no pending run is more than 30 min past due "
                                             "(stores read: personal, toysim)")])
        self.assertIn(NEEDLES["overdue-pass"], rows[0][2])

    def test_each_overdue_run_fails_on_its_own_row_naming_its_last_reason(self):
        from rabota import scheduler
        late = S_NOW - doctor.OVERDUE_AFTER - S_MIN
        rows = doctor.schedule_overdue(self.stores(
            toysim=[sched("s-1", due=late, kind="agent", last_reason=scheduler.AGENT_DEFERRAL)],
            personal=[sched("s-2", due=late - timedelta(hours=2), last_reason=scheduler.COMMAND_DEFERRAL)]), S_NOW)
        self.assertEqual([(run, ok) for run, ok, _ in rows], [("s-2", False), ("s-1", False)])
        for (_, _, detail), reason, ago in zip(rows, (scheduler.COMMAND_DEFERRAL, scheduler.AGENT_DEFERRAL),
                                              ("151 min", "31 min")):
            self.assertIn(NEEDLES["overdue-fail"], detail)
            self.assertIn(f"{ago} later; last reason: {reason}", detail)

    def test_an_overdue_run_no_tick_ever_touched_says_so(self):
        [(_, ok, detail)] = doctor.schedule_overdue(
            self.stores(toysim=[sched("s-1", due=S_NOW - timedelta(hours=1))]), S_NOW)
        self.assertFalse(ok)
        self.assertIn("last reason: none, so no tick has reached it", detail)

    def test_only_a_pending_row_can_be_overdue(self):
        old = S_NOW - timedelta(days=2)
        rows = doctor.schedule_overdue(self.stores(toysim=[
            sched(f"s-{st}", status=st, due=old, started=S_NOW) for st in ("running", "done", "failed",
                                                                            "expired", "cancelled")]), S_NOW)
        self.assertEqual([ok for _, ok, _ in rows], [True])

    def test_an_unreadable_store_is_left_to_the_timer_check(self):
        rows = doctor.schedule_overdue({"personal": {"rows": None, "why": "x"},
                                        "toysim": {"rows": [], "why": None}}, S_NOW)
        self.assertEqual(rows, [(None, True, "no pending run is more than 30 min past due (stores read: toysim)")])


class ScheduleStuckTests(SchedulerHealthBase):
    """Check 3: no run has been running longer than its own timeout plus RUNNING_GRACE."""

    def test_a_run_at_exactly_its_timeout_plus_grace_passes(self):
        start = S_NOW - timedelta(seconds=900) - doctor.RUNNING_GRACE
        rows = doctor.schedule_stuck(self.stores(toysim=[sched("s-1", status="running", started=start)]), S_NOW)
        self.assertEqual(rows, [(None, True, "no running run is past its timeout plus 20 min (stores read: toysim)")])
        self.assertIn(NEEDLES["stuck-pass"], rows[0][2])

    def test_a_run_past_its_timeout_plus_grace_fails_naming_its_unit(self):
        start = S_NOW - timedelta(seconds=900) - doctor.RUNNING_GRACE - S_MIN
        [(run, ok, detail)] = doctor.schedule_stuck(
            self.stores(toysim=[sched("s-1", status="running", started=start)]), S_NOW)
        self.assertEqual((run, ok), ("s-1", False))
        self.assertIn(NEEDLES["stuck-fail"], detail)
        self.assertIn("running 36 min", detail)
        self.assertIn("past its 900 s timeout plus 20 min grace, as rabota-sched-toysim-s-1-a1.service", detail)

    def test_each_run_is_weighed_against_its_own_timeout(self):
        start = S_NOW - timedelta(minutes=40)       # past 15 min + 20, inside 60 min + 20
        rows = doctor.schedule_stuck(self.stores(toysim=[
            sched("s-short", status="running", started=start, timeout_s=900),
            sched("s-long", status="running", started=start, timeout_s=3600)]), S_NOW)
        self.assertEqual([(run, ok) for run, ok, _ in rows], [("s-short", False)])

    def test_a_running_row_with_no_start_time_is_unmeasured_not_clean(self):
        [(run, ok, detail)] = doctor.schedule_stuck(self.stores(toysim=[sched("s-1", status="running")]), S_NOW)
        self.assertEqual((run, ok), ("s-1", False))
        self.assertIn(NEEDLES["stuck-unmeasured"], detail)

    def test_only_a_running_row_can_be_stuck(self):
        old = S_NOW - timedelta(days=2)
        rows = doctor.schedule_stuck(self.stores(toysim=[
            sched(f"s-{st}", status=st, due=old, started=old) for st in ("pending", "done", "failed")]), S_NOW)
        self.assertEqual([ok for _, ok, _ in rows], [True])


class SchedulerHealthWiringTests(SchedulerHealthBase):
    """The three checks reach the report body, its problems and the exit status -- and nothing else moves."""

    def test_a_healthy_queue_reports_a_passing_row_for_each_check_and_stays_ok(self):
        ctx = self.make_ctx(is_enabled("toysim"))
        self.put(ctx, "toysim", sched("s-1"), sched("s-2", status="running", started=S_NOW - S_MIN))
        report = doctor.run_doctor(ctx, now=S_NOW)
        self.assertTrue(report["ok"], report["problems"])
        self.assertEqual([r["ok"] for r in report["schedule_timers"]], [True, True, True])
        self.assertEqual([(r["run"], r["ok"]) for r in report["schedule_overdue"]], [(None, True)])
        self.assertEqual([(r["run"], r["ok"]) for r in report["schedule_stuck"]], [(None, True)])

    def test_each_failure_is_named_in_problems_and_fails_the_report(self):
        ctx = self.make_ctx(is_enabled("toysim", Result(1, "disabled\n", "")))
        self.put(ctx, "toysim", sched("s-late", due=S_NOW - timedelta(hours=1)),
                 sched("s-hung", status="running", started=S_NOW - timedelta(hours=1)))
        report = doctor.run_doctor(ctx, now=S_NOW)
        self.assertFalse(report["ok"])
        kinds = [p.split(":")[0] for p in report["problems"]]
        self.assertEqual(kinds, ["schedule timer for 'toysim'", "overdue scheduled run s-late",
                                 "stuck scheduled run s-hung"])

    def test_a_scheduler_failure_exits_through_doctors_existing_refusal(self):
        # The CLI path, unchanged: a report that is not ok is printed and then refused (exit 3).
        ctx = self.make_ctx(is_enabled("toysim"))
        self.put(ctx, "toysim", sched("s-late", due=datetime(2020, 1, 1, tzinfo=timezone.utc)))
        ns = argparse.Namespace()
        with mock.patch.object(context.Context, "from_namespace", return_value=ctx), \
                mock.patch.object(doctor.emit, "json_out"):
            with self.assertRaises(errors.Refused) as cm:
                doctor._run(ns)
        self.assertIn("overdue scheduled run s-late", str(cm.exception))
        self.assertEqual(cm.exception.code, 3)

    def test_a_title_carrying_a_protected_value_is_redacted_in_every_row(self):
        canary = "lin_api_" + "canary" + "0123456789"
        ctx = self.make_ctx(is_enabled("toysim", Result(1, "disabled\n", "")))
        title = f"check {canary}"
        self.put(ctx, "toysim", sched("s-late", due=S_NOW - timedelta(hours=1), title=title),
                 sched("s-hung", status="running", started=S_NOW - timedelta(hours=1), title=title,
                       last_reason=canary))
        with mock.patch.dict(os.environ, {"LINEAR_API_KEY": canary}):
            report = doctor.run_doctor(ctx, now=S_NOW)
        text = json.dumps(report)
        self.assertNotIn(canary, text)
        self.assertIn("[redacted:LINEAR_API_KEY]", text)

    def test_needles_are_unique(self):
        ctx = self.make_ctx(is_enabled("a"), is_enabled("b", Result(1, "disabled\n", "")))
        late, start = S_NOW - timedelta(hours=1), S_NOW - timedelta(hours=1)
        texts = {
            "timer-armed": doctor.schedule_timers(ctx, self.stores(a=[sched("s-1")]))[0][2],
            "timer-disarmed": doctor.schedule_timers(ctx, self.stores(b=[sched("s-1")]))[0][2],
            "timer-idle": doctor.schedule_timers(ctx, self.stores(c=[]))[0][2],
            "timer-unmeasured": doctor.schedule_timers(ctx, {"d": {"rows": None, "why": "x"}})[0][2],
            "overdue-pass": doctor.schedule_overdue(self.stores(c=[]), S_NOW)[0][2],
            "overdue-fail": doctor.schedule_overdue(self.stores(c=[sched("s-1", due=late)]), S_NOW)[0][2],
            "stuck-pass": doctor.schedule_stuck(self.stores(c=[]), S_NOW)[0][2],
            "stuck-fail": doctor.schedule_stuck(self.stores(c=[sched("s-1", status="running", started=start)]),
                                                S_NOW)[0][2],
            "stuck-unmeasured": doctor.schedule_stuck(self.stores(c=[sched("s-1", status="running")]), S_NOW)[0][2],
        }
        for kind, needle in NEEDLES.items():
            self.assertEqual([k for k, t in texts.items() if needle in t], [kind], needle)
