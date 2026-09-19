import argparse, io, json, os, tempfile, unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock
from rabota import cli, context, errors
from rabota.commands import precompute
from rabota.runner import FakeRunner
from tests.support import last_json
from tests.test_cli import install_fixture_home

FIX = Path(__file__).parent / "fixtures"


class PrecomputeTests(unittest.TestCase):
    def ctx(self, tenant="quantivly"):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

    def test_runs_all_steps_and_logs(self):
        ctx = self.ctx()
        calls = []
        fake = {name: (lambda n: (lambda *a, **k: calls.append(n) or {}))(name) for name in ("sync", "plan", "auto", "rank", "census")}
        rep = precompute.run_precompute(ctx, steps=fake)
        self.assertEqual(calls, ["sync", "plan", "auto", "rank", "census"])
        self.assertTrue(all(v["ok"] for v in rep["steps"].values()))
        self.assertEqual(len((ctx.state_dir / "precompute.log").read_text().splitlines()), 1)

    def test_step_failure_is_partial_not_crash(self):
        ctx = self.ctx()
        def boom(*a, **k): raise errors.RabotaError("linear down")
        fake = {"sync": boom, "plan": lambda *a, **k: {}, "auto": lambda *a, **k: {}, "rank": lambda *a, **k: {}, "census": lambda *a, **k: {}}
        with self.assertRaises(errors.Partial) as cm:
            precompute.run_precompute(ctx, steps=fake)
        self.assertEqual(cm.exception.failed, ["sync"])

    def test_tenant_without_linear_skips_inbox(self):
        ctx = self.ctx("toysim")
        calls = []
        fake = {name: (lambda n: (lambda *a, **k: calls.append(n) or {}))(name) for name in ("sync", "plan", "auto", "rank", "census")}
        precompute.run_precompute(ctx, steps=fake)
        self.assertEqual(calls, ["sync", "rank", "census"])

    def test_dry_run_reaches_run_apply(self):
        # L4: --dry-run is a global flag stored on ctx.dry_run; the default steps must pass it
        # through to run_apply so `rabota --dry-run precompute` cannot archive for real.
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=True)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        self.assertTrue(ctx.dry_run)
        with mock.patch("rabota.commands.inbox.run_apply") as fake_apply:
            fake_apply.return_value = {}
            steps = precompute._default_steps()
            steps["auto"](ctx)
        fake_apply.assert_called_once_with(ctx, tier="auto", batch=None, confirmed=False, dry_run=True)

    def test_middle_step_non_rabota_exception_does_not_abort_the_chain(self):
        # Item 1: run_precompute used to catch only errors.RabotaError, so a plain
        # KeyError/OSError/Exception from any step took the whole tick down uncaught —
        # auto/rank/census never ran and precompute.log was never written.
        for exc_cls, msg in [(KeyError, "boom"), (OSError, "disk full"), (Exception, "generic failure")]:
            with self.subTest(exc_cls=exc_cls):
                ctx = self.ctx()
                calls = []

                def boom(*a, **k):
                    raise exc_cls(msg)

                fake = {
                    "sync": lambda *a, **k: calls.append("sync") or {},
                    "plan": boom,
                    "auto": lambda *a, **k: calls.append("auto") or {},
                    "rank": lambda *a, **k: calls.append("rank") or {},
                    "census": lambda *a, **k: calls.append("census") or {},
                }
                with self.assertRaises(errors.Partial) as cm:
                    precompute.run_precompute(ctx, steps=fake)
                self.assertEqual(cm.exception.failed, ["plan"])
                self.assertEqual(calls, ["sync", "auto", "rank", "census"])
                log_lines = (ctx.state_dir / "precompute.log").read_text().splitlines()
                self.assertEqual(len(log_lines), 1)
                rep = json.loads(log_lines[0])
                self.assertFalse(rep["steps"]["plan"]["ok"])
                self.assertIn(exc_cls.__name__, rep["steps"]["plan"]["error"])
                self.assertIn(msg, rep["steps"]["plan"]["error"])

    def test_two_step_failures_are_both_recorded_in_order(self):
        ctx = self.ctx()

        def boom_key(*a, **k):
            raise KeyError("missing")

        def boom_os(*a, **k):
            raise OSError("disk")

        fake = {
            "sync": lambda *a, **k: {},
            "plan": boom_key,
            "auto": lambda *a, **k: {},
            "rank": boom_os,
            "census": lambda *a, **k: {},
        }
        with self.assertRaises(errors.Partial) as cm:
            precompute.run_precompute(ctx, steps=fake)
        self.assertEqual(cm.exception.failed, ["plan", "rank"])
        log_lines = (ctx.state_dir / "precompute.log").read_text().splitlines()
        self.assertEqual(len(log_lines), 1)
        rep = json.loads(log_lines[0])
        self.assertFalse(rep["steps"]["plan"]["ok"])
        self.assertFalse(rep["steps"]["rank"]["ok"])
        self.assertTrue(rep["steps"]["auto"]["ok"])
        self.assertTrue(rep["steps"]["census"]["ok"])

    def test_partial_failure_exits_4_through_cli_main(self):
        # Drives the real registered command, not run_precompute directly (WS3 round 1's
        # lesson): patches the actual step functions _default_steps() imports, so wiring
        # from `rabota precompute` through cli.main to a caught non-RabotaError is proven.
        install_fixture_home(self)
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        with mock.patch("rabota.commands.sync.run_sync", return_value={}), \
             mock.patch("rabota.commands.inbox.run_plan", side_effect=KeyError("boom")), \
             mock.patch("rabota.commands.inbox.run_apply", return_value={}), \
             mock.patch("rabota.commands.rank.run_rank", return_value={}), \
             mock.patch("rabota.census.gather", return_value={}):
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = cli.main(["--tenant", "quantivly", "--state-dir", tmp.name, "precompute"])
        self.assertEqual(code, 4, err.getvalue())
        payload = last_json(err.getvalue())
        self.assertEqual(payload["error"]["code"], "partial")
        self.assertEqual(payload["error"]["failed"], ["plan"])
        log = Path(tmp.name) / "precompute.log"
        self.assertTrue(log.exists())
        rep = json.loads(log.read_text().splitlines()[-1])
        self.assertFalse(rep["steps"]["plan"]["ok"])
        self.assertIn("KeyError", rep["steps"]["plan"]["error"])
        self.assertTrue(rep["steps"]["auto"]["ok"])
        self.assertTrue(rep["steps"]["rank"]["ok"])
        self.assertTrue(rep["steps"]["census"]["ok"])

    def test_census_step_calls_gather_with_include_worktrees_false(self):
        # F24: the timer's census step must ask for the cheap shape — drive this through the real
        # `_default_steps()` wiring (not by inspecting the lambda's source) so a future refactor of
        # the step's argument order or name is still caught.
        ctx = self.ctx()
        with mock.patch("rabota.census.gather", return_value={}) as fake_gather:
            steps = precompute._default_steps()
            steps["census"](ctx)
        fake_gather.assert_called_once_with(ctx, sample_seconds=2.0, include_worktrees=False)

    def test_secret_leak_from_log_write_still_propagates(self):
        # The write happens after the per-step loop, so a SecretLeak from it must escape
        # run_precompute unswallowed. Pinned so a later refactor cannot move the write
        # inside the per-step try/except.
        ctx = self.ctx()
        fake = {name: (lambda *a, **k: {}) for name in ("sync", "plan", "auto", "rank", "census")}
        with mock.patch("rabota.commands.precompute.emit.append_file", side_effect=errors.SecretLeak("nope")):
            with self.assertRaises(errors.SecretLeak):
                precompute.run_precompute(ctx, steps=fake)
