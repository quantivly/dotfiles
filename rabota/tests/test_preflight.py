import argparse, contextlib, io, tempfile, time, unittest
from dataclasses import dataclass, field
from pathlib import Path
from rabota import context, errors, secrets
from rabota.commands import preflight
from rabota.runner import FakeRunner, Result

FIX = Path(__file__).parent / "fixtures" / "config"
VIEWER = "00000000-0000-0000-0000-000000000001"

class FakeGh:
    def __init__(self, login, pin_ok=True): self.login, self.pin_ok = login, pin_ok
    def whoami(self): return self.login
    def api(self, path, **kw):
        if not self.pin_ok: raise preflight.errors.RabotaError("404")
        return {"full_name": path.split("repos/")[1]}

class FakeLinear:
    def __init__(self, vid): self.vid = vid
    def viewer(self): return {"id": self.vid, "name": "z"}

class CountingGh(FakeGh):
    """Records every ``api`` call so a test can assert a skipped source never runs one at all."""
    def __init__(self, login, pin_ok=True):
        super().__init__(login, pin_ok); self.api_calls = []
    def api(self, path, **kw):
        self.api_calls.append(path); return super().api(path, **kw)

class RaisingGh:
    """whoami() itself raises — the exception path, distinct from a wrong-but-returned login."""
    def whoami(self): raise preflight.errors.RabotaError("boom")
    def api(self, path, **kw): return {"full_name": path.split("repos/")[1]}

class RaisingLinear:
    def viewer(self): raise preflight.errors.RabotaError("linear boom")

class DelayedGh:
    """Answers after ``delay`` seconds, so a test can control which leg of the fan-out finishes last."""
    def __init__(self, login, delay=0.0, pin_ok=True): self.login, self.delay, self.pin_ok = login, delay, pin_ok
    def whoami(self):
        time.sleep(self.delay); return self.login
    def api(self, path, **kw):
        if not self.pin_ok: raise preflight.errors.RabotaError("404")
        return {"full_name": path.split("repos/")[1]}

class DelayedLinear:
    def __init__(self, vid, delay=0.0): self.vid, self.delay = vid, delay
    def viewer(self):
        time.sleep(self.delay); return {"id": self.vid, "name": "z"}

@dataclass
class DelayedRunner:
    """Wraps a runner and sleeps before delegating, so ``ssh-add`` can be made the fastest or slowest leg."""
    inner: FakeRunner
    delay: float = 0.0

    def run(self, argv, **kw):
        time.sleep(self.delay)
        return self.inner.run(argv, **kw)

    @property
    def calls(self): return self.inner.calls

class PreflightTests(unittest.TestCase):
    def ctx(self, tenant, env, ssh_ok=True):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ssh = Result(0, "256 SHA256:abc key (ED25519)\n", "") if ssh_ok else Result(1, "", "The agent has no identities.")
        runner = FakeRunner([(["ssh-add", "-l"], ssh)])
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env=env, cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

    def test_all_pins_positive(self):
        ctx = self.ctx("quantivly", {"PATH": "/bin", "HERDR_ENV": "1", "CLAUDE_CONFIG_DIR": "/x/quantivly-1"})
        r = preflight.run_preflight(ctx, gh=FakeGh("work-login"), lin=FakeLinear(VIEWER))
        self.assertTrue(r["ok"], r["failures"])
        self.assertEqual(r["profile"], "quantivly-1")
        self.assertTrue(r["herdr"]); self.assertTrue(r["ssh_agent"])
        self.assertEqual(r["gh_pin"], {"repo": "org/pin-repo", "ok": True})

    def test_the_github_client_is_built_on_the_calling_thread(self):
        # DO-730 review: building GhClient mints a token and registers it with `secrets`
        # (module-global). That must happen on the calling thread, never inside a worker.
        import threading
        from unittest import mock
        seen = []
        def build(ctx):
            seen.append(threading.current_thread() is threading.main_thread())
            return FakeGh("work-login")
        ctx = self.ctx("quantivly", {"PATH": "/bin"})
        with mock.patch.object(preflight.GhClient, "from_context", side_effect=build):
            r = preflight.run_preflight(ctx, lin=FakeLinear(VIEWER))
        self.assertTrue(r["ok"], r["failures"])
        self.assertEqual(seen, [True])

    def test_a_client_that_cannot_be_built_is_reported_once_and_never_retried(self):
        from unittest import mock
        ctx = self.ctx("quantivly", {"PATH": "/bin"})
        with mock.patch.object(preflight.GhClient, "from_context",
                               side_effect=errors.RabotaError("no token for work-login")) as build:
            r = preflight.run_preflight(ctx, lin=FakeLinear(VIEWER))
        self.assertEqual(build.call_count, 1)
        self.assertEqual(r["gh"], {"ok": False, "error": "no token for work-login"})
        self.assertEqual(r["gh_pin"], {})
        self.assertIn("gh identity check failed: no token for work-login", r["failures"])

    def test_wrong_identity_fails_loud(self):
        ctx = self.ctx("quantivly", {"PATH": "/bin"})
        r = preflight.run_preflight(ctx, gh=FakeGh("ZviBaratz"), lin=FakeLinear(VIEWER))
        self.assertFalse(r["ok"])
        self.assertTrue(any("gh identity" in f for f in r["failures"]))
        self.assertIsNone(r["profile"]); self.assertFalse(r["herdr"])

    def test_tenant_without_linear_skips_it(self):
        ctx = self.ctx("toysim", {"PATH": "/bin"})
        r = preflight.run_preflight(ctx, gh=FakeGh("personal-login"), lin=None)
        self.assertTrue(r["linear"]["skipped"])
        self.assertTrue(r["ok"], r["failures"])

    def test_unreachable_pin_repo_and_wrong_viewer_and_empty_agent_each_fail(self):
        ctx = self.ctx("quantivly", {"PATH": "/bin"}, ssh_ok=False)
        r = preflight.run_preflight(ctx, gh=FakeGh("work-login", pin_ok=False), lin=FakeLinear("someone-else"))
        self.assertFalse(r["ok"])
        self.assertFalse(r["gh_pin"]["ok"]); self.assertFalse(r["linear"]["ok"]); self.assertFalse(r["ssh_agent"])
        self.assertEqual(len(r["failures"]), 3, r["failures"])

    def test_command_records_a_run_row_and_refuses_on_failure(self):
        ctx = self.ctx("quantivly", {"PATH": "/bin"})
        with self.assertRaises(errors.Refused) as cm, contextlib.redirect_stdout(io.StringIO()) as out:
            preflight.run_command(ctx, gh=FakeGh("ZviBaratz"), lin=FakeLinear(VIEWER))
        self.assertIn('"ok": false', out.getvalue())          # the report is printed before the refusal
        self.assertIn("gh identity", str(cm.exception))
        runs = ctx.store._rows("SELECT * FROM runs")
        self.assertEqual((len(runs), runs[0]["mode"], runs[0]["preflight_ok"]), (1, "preflight", 0))
        self.assertIsNotNone(runs[0]["finished_at"])

    def test_dry_run_command_records_no_run_row(self):
        # DO-753 hazard 1: the standalone `preflight` command passes record_run=not ctx.dry_run;
        # a passing preflight still refuses nothing, but records no `runs` row.
        ctx = self.ctx("quantivly", {"PATH": "/bin", "HERDR_ENV": "1", "CLAUDE_CONFIG_DIR": "/x/quantivly-1"})
        report = preflight.run_command(ctx, gh=FakeGh("work-login"), lin=FakeLinear(VIEWER), record_run=False)
        self.assertTrue(report["ok"], report["failures"])
        self.assertEqual(ctx.store._rows("SELECT * FROM runs"), [])

    def test_record_run_default_is_unchanged_for_an_existing_caller_like_brief(self):
        # `commands.brief.run_brief` calls `run_command(ctx, gh=gh, lin=lin)` with no `record_run`
        # argument at all, on every path including its own dry one (Move 5, DO-742, deliberately
        # out of scope for DO-753) -- the default must still record, so that caller is unaffected.
        ctx = self.ctx("quantivly", {"PATH": "/bin", "HERDR_ENV": "1", "CLAUDE_CONFIG_DIR": "/x/quantivly-1"})
        preflight.run_command(ctx, gh=FakeGh("work-login"), lin=FakeLinear(VIEWER))
        self.assertEqual(len(ctx.store._rows("SELECT * FROM runs")), 1)

    # DO-730: concurrency ------------------------------------------------------------------

    def test_skipped_source_never_becomes_a_task_that_runs(self):
        """toysim lists no gh_pin_repo: the pin task must never be submitted, not merely discarded."""
        gh = CountingGh("personal-login")
        ctx = self.ctx("toysim", {"PATH": "/bin"})
        r = preflight.run_preflight(ctx, gh=gh, lin=None)
        self.assertTrue(r["ok"], r["failures"])
        self.assertEqual(gh.api_calls, [])
        self.assertEqual(r["gh_pin"], {})

    def test_exception_inside_a_future_is_reported_not_swallowed(self):
        """whoami() raising (not just returning a wrong login) must still surface through .result()."""
        ctx = self.ctx("quantivly", {"PATH": "/bin"})
        r = preflight.run_preflight(ctx, gh=RaisingGh(), lin=FakeLinear(VIEWER))
        self.assertFalse(r["ok"])
        self.assertEqual(r["gh"], {"ok": False, "error": "boom"})
        self.assertTrue(any("gh identity check failed: boom" in f for f in r["failures"]))

    def test_linear_exception_inside_a_future_is_reported_not_swallowed(self):
        ctx = self.ctx("quantivly", {"PATH": "/bin"})
        r = preflight.run_preflight(ctx, gh=FakeGh("work-login"), lin=RaisingLinear())
        self.assertFalse(r["ok"])
        self.assertEqual(r["linear"]["error"], "linear boom")
        self.assertTrue(any("Linear: linear boom" in f for f in r["failures"]))

    def test_failure_order_is_stable_regardless_of_which_call_answers_first(self):
        """Three legs (github, linear, ssh) all fail; drive them with reversed completion order
        (ssh fastest, linear middle, github slowest, and the mirror image) and show the report —
        including the order of ``failures`` — comes out byte-identical either way."""
        def result_with(gh_delay, lin_delay, ssh_delay):
            ctx = self.ctx("quantivly", {"PATH": "/bin"})
            ctx.runner = DelayedRunner(FakeRunner([(["ssh-add", "-l"], Result(1, "", "no identities"))]), ssh_delay)
            return preflight.run_preflight(ctx, gh=DelayedGh("someone-else", delay=gh_delay),
                                            lin=DelayedLinear("someone-else-id", delay=lin_delay))

        forward = result_with(gh_delay=0.0, lin_delay=0.05, ssh_delay=0.1)     # gh finishes first
        reversed_ = result_with(gh_delay=0.1, lin_delay=0.05, ssh_delay=0.0)   # ssh finishes first
        self.assertEqual(forward, reversed_)
        self.assertEqual(forward["failures"], [
            "gh identity is 'someone-else', expected 'work-login'",
            "Linear viewer id does not match the tenant pin",
            "ssh-agent has no keys (ssh-add -l failed)",
        ])

    def test_github_half_and_linear_half_and_ssh_all_overlap_in_wall_time(self):
        """Three independent 0.3s legs: serial would be ~0.9s (plus a 4th 0.3s for the concurrent
        gh pin call, ~1.2s total); concurrent must land near one round trip (~0.3-0.4s)."""
        delay = 0.5   # long enough that scheduling noise on a loaded CI runner is small beside it
        ctx = self.ctx("quantivly", {"PATH": "/bin"})
        ctx.runner = DelayedRunner(FakeRunner([(["ssh-add", "-l"], Result(0, "ok\n", ""))]), delay)
        start = time.perf_counter()
        r = preflight.run_preflight(ctx, gh=DelayedGh("work-login", delay=delay),
                                     lin=DelayedLinear(VIEWER, delay=delay))
        elapsed = time.perf_counter() - start
        self.assertTrue(r["ok"], r["failures"])
        # Under 2x: a version that ran the two GitHub calls one after the other would take 2x and
        # fail here, while 0.8x of slack absorbs a loaded runner (DO-730 review).
        self.assertLess(elapsed, delay * 1.8)
        self.assertGreaterEqual(elapsed, delay)  # never faster than the slowest single leg

    def test_real_gh_client_shared_between_whoami_and_pin_is_race_free(self):
        """GhClient is built once and its ``whoami``/``api`` calls run concurrently against the
        same instance; stress it over several iterations against the real class (not a fake) to
        catch a race in the shared ``env``/``runner``."""
        self.addCleanup(secrets.REGISTERED_VALUES.discard, "minted-token")
        for _ in range(10):
            runner = FakeRunner([
                (["gh", "auth", "token"], Result(0, "minted-token\n", "")),
                (["gh", "api", "user", "--jq", ".login"], Result(0, "work-login\n", "")),
                (["gh", "api", "repos/org/pin-repo"], Result(0, '{"full_name": "org/pin-repo"}', "")),
                (["ssh-add", "-l"], Result(0, "ok\n", "")),
            ])
            ns = argparse.Namespace(tenant="quantivly", state_dir=None, text=False, dry_run=False)
            tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
            ns.state_dir = str(Path(tmp.name))
            ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner,
                                                  env={"PATH": "/bin"}, cwd=Path("/"))
            self.addCleanup(ctx.close)
            r = preflight.run_preflight(ctx, lin=FakeLinear(VIEWER))
            self.assertTrue(r["ok"], r["failures"])
            self.assertEqual(r["gh"], {"login": "work-login", "expected": "work-login", "ok": True})
            self.assertEqual(r["gh_pin"], {"repo": "org/pin-repo", "ok": True})
