import argparse, json, tempfile, unittest
from pathlib import Path
from rabota import budget, context, errors
from rabota.config import BudgetThresholds
from rabota.runner import FakeRunner, Result

FIX = Path(__file__).parent / "fixtures"

def pick_json(state, profile, u5, projected, verdict, rc):
    return Result(rc, json.dumps({"state": state, "profile": profile if rc == 0 else None, "tier": "Team",
                                  "usage": {"five_hour": u5, "weekly": 10, "cache_age_s": 30},
                                  "resets_at": {"five_hour": "2026-09-16T20:00:00Z", "weekly": None},
                                  "gate": {"model": "m", "effort": "e", "est_minutes": 30, "rate": 115, "projected": projected, "max": 95, "verdict": verdict},
                                  "reason": None if rc == 0 else "projected", "exit_code": rc}), "")

class BudgetTests(unittest.TestCase):
    def ctx(self, runner, tenant="quantivly"):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        return context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))

    def test_seat_for_uses_tenant_config_and_refuses_the_console(self):
        ctx = self.ctx(FakeRunner([]))
        self.assertEqual(budget.seat_for(ctx.tenant, "local"), "quantivly-1")
        self.assertEqual(budget.seat_for(ctx.tenant, "dev"), "quantivly-0")
        with self.assertRaises(errors.Refused): budget.seat_for(ctx.tenant, "local", override="quantivly-3")
        with self.assertRaises(errors.Refused): budget.seat_for(ctx.tenant, "local", override="personal-0")

    def test_seat_for_refuses_when_unconfigured_and_cross_tenant(self):
        # personal.toml declares no [seats]: "no seat" is a refusal naming the key, never a guessed name
        p = self.ctx(FakeRunner([]), tenant="personal")
        with self.assertRaises(errors.Refused) as cm: budget.seat_for(p.tenant, "local")
        self.assertIn("[seats]", str(cm.exception))
        with self.assertRaises(errors.Refused): budget.seat_for(p.tenant, "local", override="quantivly-1")   # work seat, personal tenant
        self.assertEqual(budget.seat_for(p.tenant, "local", override="personal-0"), "personal-0")
        with self.assertRaises(errors.Refused): budget.seat_for(p.tenant, "dev")   # no [machines.dev] for personal

    def test_gate_allow_and_refusals_map_to_reason_codes(self):
        allow = FakeRunner([(["claude-pick"], pick_json("picked", "quantivly-1", 30, 87, "allow", 0))])
        g = budget.credential_gate(allow, "quantivly-1", "m", "e", 30)
        self.assertEqual((g["ok"], g["code"], g["five_h_pct_now"]), (True, None, 30))
        self.assertEqual(allow.calls[0][:3], ["claude-pick", "--profile", "quantivly-1"])
        self.assertIn("--gate", allow.calls[0]); self.assertIn("--dry-run", allow.calls[0])
        window = FakeRunner([(["claude-pick"], pick_json("gate-projected", "quantivly-1", 40, 97, "refuse", 2))])
        g = budget.credential_gate(window, "quantivly-1", "m", "e", 30)
        self.assertEqual((g["ok"], g["code"]), (False, "credential:window")); self.assertEqual(g["resets_at"], "2026-09-16T20:00:00Z")
        unmeasured = FakeRunner([(["claude-pick"], pick_json("gate-unmeasured", "quantivly-1", None, None, "refuse", 2))])
        self.assertEqual(budget.credential_gate(unmeasured, "quantivly-1", "m", "e", 30)["code"], "credential:unmeasured")
        absent = FakeRunner([(["claude-pick"], Result(5, "", "no clauth profile"))])
        self.assertEqual(budget.credential_gate(absent, "quantivly-1", "m", "e", 30)["code"], "credential:unmeasured")
        missing = FakeRunner([(["claude-pick"], Result(127, "", "not found"))])
        self.assertEqual(budget.credential_gate(missing, "quantivly-1", "m", "e", 30)["code"], "credential:unmeasured")

    def test_gate_spend_wall_is_a_measured_window_refusal(self):
        j = {
            "profile": None, "state": "gate-spend-wall",
            "reason": "q1's 7d fable window is 100% used (resets 2026-09-21T09:00:00Z) "
                      "and the seat has no spend headroom left ($252.17 of $250)",
            "usage": {"five_hour": 12, "weekly": 100, "cache_age_s": 4},
            "resets_at": {"five_hour": "2026-09-19T20:00:00Z", "weekly": "2026-09-21T09:00:00Z"},
            "gate": {"verdict": "refuse", "spend": "none", "bills_credits": None,
                     "model_window": {"label": "7d fable", "utilization": 100,
                                      "resets_at": "2026-09-21T09:00:00Z", "state": "live"}},
        }
        runner = FakeRunner([(["claude-pick"], Result(2, json.dumps(j), ""))])
        out = budget.credential_gate(runner, "q1", "claude-fable-5-1", "high", 30)
        self.assertEqual(out["ok"], False)
        self.assertEqual(out["code"], "credential:window")      # not "credential:unmeasured"
        self.assertIn("7d fable", out["detail"])

    def test_gate_spend_wall_detail_does_not_fall_back_to_the_5h_sentence(self):
        # The gate always sets a reason; if a future one does not, the fallback must
        # still name the wall that fired rather than a projection that never ran.
        j = {"state": "gate-spend-wall", "reason": "",
             "usage": {"five_hour": 12}, "gate": {"verdict": "refuse", "spend": "none"}}
        runner = FakeRunner([(["claude-pick"], Result(2, json.dumps(j), ""))])
        out = budget.credential_gate(runner, "q1", "claude-fable-5-1", "high", 30)
        self.assertNotIn("projected", out["detail"])
        self.assertIn("spend", out["detail"])

    def test_gate_never_reads_a_zero_exit_without_an_allow_as_ok(self):
        # exit 0 but no gate verdict (an older claude-pick without --gate, or --gate dropped): unmeasured, not ok
        r = pick_json("picked", "quantivly-1", 30, None, None, 0)
        j = json.loads(r.out); j["gate"] = None; r.out = json.dumps(j)
        g = budget.credential_gate(FakeRunner([(["claude-pick"], r)]), "quantivly-1", "m", "e", 30)
        self.assertEqual((g["ok"], g["code"]), (False, "credential:unmeasured"))
        garbage = FakeRunner([(["claude-pick"], Result(0, "not json", ""))])
        self.assertEqual(budget.credential_gate(garbage, "quantivly-1", "m", "e", 30)["code"], "credential:unmeasured")

    def test_compute_credential_dimension_only(self):
        b = budget.compute(None, {"ok": False, "code": "credential:window", "detail": "d", "five_h_pct_now": 40, "resets_at": "r", "tier": "Team"},
                           BudgetThresholds(), max_lanes_local=3)
        self.assertEqual(b["allowed_new_lanes"], 0); self.assertEqual(b["reasons"][0]["code"], "credential:window")
        self.assertEqual(b["schema"], 1); self.assertIn("machine", b["unavailable"])   # census not given → machine dimension unmeasured
        b = budget.compute(None, {"ok": True, "code": None, "detail": "", "five_h_pct_now": 30, "resets_at": "r", "tier": "Team"},
                           BudgetThresholds(), max_lanes_local=3)
        self.assertEqual(b["allowed_new_lanes"], 0)          # still 0: the machine dimension is unmeasured → refuse
        self.assertEqual(b["reasons"][0]["code"], "machine:unmeasured")

    def test_command_writes_budget_json_and_exits_3_on_zero(self):
        from rabota.commands import budget as cmd
        runner = FakeRunner([(["claude-pick"], pick_json("gate-projected", "quantivly-1", 40, 97, "refuse", 2))])
        ctx = self.ctx(runner)
        with self.assertRaises(errors.Refused) as cm:
            cmd.run_budget(ctx, machine="local", model="claude-fable-5-1", effort="high", est_minutes=30, raise_on_zero=True)
        self.assertIn("credential:window", str(cm.exception))
        self.assertTrue((ctx.state_dir / "budget.json").exists())
        b = json.loads((ctx.state_dir / "budget.json").read_text())
        self.assertEqual((b["schema"], b["seat_pick"], b["five_h_pct_now"]), (1, "quantivly-1", 40))

    def test_command_seat_refusal_before_any_write_is_a_clean_refusal(self):
        # the seat rule fires before claude-pick is asked or budget.json exists; the CLI must not trip over the missing file
        from rabota import cli
        from rabota.commands import budget as cmd
        ctx = self.ctx(FakeRunner([]))
        with self.assertRaises(errors.Refused):
            cmd.run_budget(ctx, machine="local", model="m", effort="e", est_minutes=30, seat="quantivly-3", raise_on_zero=True)
        self.assertFalse((ctx.state_dir / "budget.json").exists())
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(ctx.state_dir), text=True, dry_run=False, command="budget",
                                machine="local", seat="quantivly-3", model="m", effort="e", est_minutes=30)
        import contextlib, io
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(errors.Refused):
                cmd._run(ns, cfg_base=FIX / "config", runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))
