import argparse, json, tempfile, unittest
from pathlib import Path
from unittest import mock
from rabota import context, errors
from rabota.commands import precompute
from rabota.runner import FakeRunner

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
