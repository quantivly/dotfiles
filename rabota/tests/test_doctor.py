import argparse, json, os, shutil, sqlite3, subprocess, sys, tempfile, unittest
from pathlib import Path
from rabota import context
from rabota.commands import doctor
from rabota.runner import FakeRunner, Result
from rabota.store import SCHEMA_VERSION
from tests.support import last_json

FIX = Path(__file__).parent / "fixtures" / "config"

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
                    # others never call claude-pick, so this response is simply unused for them.
                    (["claude-pick"], Result(0, json.dumps({"usage": {"cache_age_s": 30}}), "")),
                ])
                ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name) / "state"),
                                        text=False, dry_run=False, command="doctor")
                ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))
                self.addCleanup(ctx.close)
                doctor.run_doctor(ctx)
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

    def test_the_report_names_the_declared_seat_and_marks_the_remote_login_unverified(self):
        # Task 8 correction 3: [machines.<m>].profile is a trusted DECLARATION, never enforced —
        # nothing here reads the remote machine's own login, so doctor must say so plainly rather
        # than imply a check that was never made.
        rows = doctor.seat_cache_age(self.ctx(FakeRunner([(["claude-pick"], self.pick(30))])))
        name, ok, detail = rows[0]
        self.assertTrue(ok)
        self.assertIn("quantivly-0", detail)
        self.assertIn("NOT VERIFIED", detail)

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
        ])
        report = doctor.run_doctor(self.make_ctx(runner))
        self.assertFalse(report["ok"])
        self.assertTrue(any("dev" in p for p in report["problems"]), report["problems"])

    def test_a_fresh_seat_cache_does_not_fail_the_report_on_its_own(self):
        runner = FakeRunner(self.healthy_base() + [
            (["claude-pick"], Result(0, json.dumps({"usage": {"cache_age_s": 30}}), "")),
        ])
        report = doctor.run_doctor(self.make_ctx(runner))
        self.assertTrue(report["ok"], report["problems"])
        self.assertEqual([(r["machine"], r["ok"]) for r in report["seat_cache"]], [("dev", True)])

    def test_a_tenant_with_no_seated_machines_reports_no_seat_cache_rows(self):
        runner = FakeRunner(self.healthy_base())
        report = doctor.run_doctor(self.make_ctx(runner, tenant="toysim"))
        self.assertEqual(report["seat_cache"], [])
