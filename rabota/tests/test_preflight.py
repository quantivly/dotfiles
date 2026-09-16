import argparse, contextlib, io, tempfile, unittest
from pathlib import Path
from rabota import context, errors
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

class PreflightTests(unittest.TestCase):
    def ctx(self, tenant, env, ssh_ok=True):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ssh = Result(0, "256 SHA256:abc key (ED25519)\n", "") if ssh_ok else Result(1, "", "The agent has no identities.")
        runner = FakeRunner([(["ssh-add", "-l"], ssh)])
        return context.Context.from_namespace(ns, cfg_base=FIX, runner=runner, env=env, cwd=Path("/"))

    def test_all_pins_positive(self):
        ctx = self.ctx("quantivly", {"PATH": "/bin", "HERDR_ENV": "1", "CLAUDE_CONFIG_DIR": "/x/quantivly-1"})
        r = preflight.run_preflight(ctx, gh=FakeGh("work-login"), lin=FakeLinear(VIEWER))
        self.assertTrue(r["ok"], r["failures"])
        self.assertEqual(r["profile"], "quantivly-1")
        self.assertTrue(r["herdr"]); self.assertTrue(r["ssh_agent"])
        self.assertEqual(r["gh_pin"], {"repo": "org/pin-repo", "ok": True})

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
