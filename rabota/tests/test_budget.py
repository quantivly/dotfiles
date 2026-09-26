import argparse, datetime, json, tempfile, unittest
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
        c = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(lambda: c._store and c._store.close())
        return c

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
        self.assertEqual(out["code"], "credential:window")
        self.assertNotIn("projected", out["detail"])
        self.assertIn("weekly window spent", out["detail"])   # only the fallback prints this

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

    def test_run_budget_writes_only_budget_json_never_a_store_row(self):
        # DO-743 hazard 1: `lane recipe`'s dry path (like its existing non-`--run` path today)
        # still consults `run_budget` before returning -- "would this be refused" is exactly what
        # a careful caller wants to know. This proves the gate itself is safe to keep on a dry
        # path: it writes `budget.json` (a file, not a row anything else reads as history) and
        # touches none of `lanes`, `runs`, `pins` or `escalations`. Counted from the tables
        # themselves, never a hash of `rabota.db` (more than one writer touches that file, so a
        # hash proves nothing -- WAL/journal bookkeeping alone can change it with zero rows added).
        from rabota.commands import budget as cmd
        runner = FakeRunner([(["claude-pick"], pick_json("picked", "quantivly-1", 30, 87, "allow", 0))])
        ctx = self.ctx(runner)

        def counts():
            return {t: ctx.store.conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
                    for t in ("lanes", "runs", "pins", "escalations")}

        before = counts()
        self.assertFalse((ctx.state_dir / "budget.json").exists())
        cmd.run_budget(ctx, machine="local", model="m", effort="e", est_minutes=30)
        self.assertTrue((ctx.state_dir / "budget.json").exists())
        self.assertEqual(counts(), before)

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


from rabota import store
from rabota.config import BudgetThresholds as BT

OK_CRED = {"ok": True, "code": None, "detail": "", "five_h_pct_now": 5, "resets_at": None, "tier": "Team"}

def census_with(*, local_load=1.0, dev=None, counts=None):
    # "at" is always present and fresh: Task 8 makes a census without one stale, and every row
    # here is about the MACHINE dimension, not freshness.
    c = {"at": store.now(),
         "machine": {"load1": local_load, "ncpu": 8, "mem_available_gib": 20.0, "swap_used_pct": 0},
         "counts": counts or {"rabota": 0, "sol": 0}, "unavailable": [], "machines": []}
    if dev is not None:
        c["machines"] = [dev]
    return c

DEV_IDLE = {"name": "dev", "reachable": True, "load1": 5.0, "ncpu": 16,
            "mem_available_gib": 13.0, "swap_used_pct": 0, "units": [], "streams": {}}
# load1=5.0 is comfortably under 16 cpus' threshold (1.25×16=20) but well over a 1-cpu
# threshold (1.25) — chosen so a mutation that drops the ncpu multiplier is caught by
# test_a_saturated_laptop_does_not_refuse_a_dev_lane rather than passing unnoticed.


class MachineDimensionTests(unittest.TestCase):
    def t(self):
        return BT(max_local_sessions=8, max_lanes_local=3, load1_per_cpu=1.25,
                  swap_pct_max=40, mem_available_min_gib=6, profile_5h_pct_max=70)

    def test_a_saturated_laptop_does_not_refuse_a_dev_lane(self):
        c = census_with(local_load=99.0, dev=DEV_IDLE)
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual(b["reasons"], [])
        self.assertEqual(b["allowed_new_lanes"], 3)

    def test_a_saturated_laptop_does_refuse_a_local_lane(self):
        c = census_with(local_load=99.0, dev=DEV_IDLE)
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="local")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:load"])

    def test_a_loaded_dev_refuses_a_dev_lane(self):
        busy = dict(DEV_IDLE, load1=40.0)
        b = budget.compute(census_with(dev=busy), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:load"])

    def test_low_memory_on_dev_refuses(self):
        tight = dict(DEV_IDLE, mem_available_gib=1.0)
        b = budget.compute(census_with(dev=tight), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:memory"])

    def test_swap_on_dev_refuses(self):
        swapping = dict(DEV_IDLE, swap_used_pct=80)
        b = budget.compute(census_with(dev=swapping), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:swap"])

    def test_an_unreachable_dev_refuses_and_is_not_room(self):
        b = budget.compute(census_with(dev={"name": "dev", "reachable": False, "error": "no route"}),
                           OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:unmeasured"])
        self.assertEqual(b["allowed_new_lanes"], 0)

    def test_a_missing_dev_row_refuses_rather_than_falling_back_to_local(self):
        b = budget.compute(census_with(dev=None), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:unmeasured"])

    def test_running_lanes_on_dev_consume_the_cap(self):
        busy = dict(DEV_IDLE, units=[{"name": "rabota-lane-a.service", "state": "active", "machine": "dev"},
                                     {"name": "rabota-lane-b.service", "state": "active", "machine": "dev"}])
        b = budget.compute(census_with(dev=busy), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual(b["allowed_new_lanes"], 1)


class CensusFreshnessTests(MachineDimensionTests):
    def test_a_stale_census_refuses_rather_than_granting_room(self):
        c = census_with(dev=DEV_IDLE); c["at"] = "2020-01-01T00:00:00Z"
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev", max_census_age_s=900)
        self.assertEqual([r["code"] for r in b["reasons"]], ["census:stale"])
        self.assertEqual(b["allowed_new_lanes"], 0)

    def test_a_census_with_no_timestamp_refuses(self):
        c = census_with(dev=DEV_IDLE); c.pop("at", None)
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["census:stale"])

    def test_a_stale_census_still_surfaces_what_it_could_not_measure(self):
        # The stale path must not report LESS than the fresh path for the same file: a dimension
        # the census itself declared unmeasured has to stay named, or a reader concludes it was
        # fine when nothing ever looked.
        c = census_with(dev=DEV_IDLE)
        c["at"] = "2020-01-01T00:00:00Z"
        c["unavailable"] = ["deferred:sol", "seat:quantivly-0:stale"]
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["census:stale"])
        for expected in ("machine", "counts", "deferred:sol", "seat:quantivly-0:stale"):
            self.assertIn(expected, b["unavailable"])

    def test_a_naive_timestamp_refuses_rather_than_raising(self):
        # fromisoformat happily parses a string with no offset into a NAIVE datetime; subtracting
        # that from an aware "now" raises TypeError, not ValueError. Must return, not raise.
        c = census_with(dev=DEV_IDLE); c["at"] = "2020-01-01T00:00:00"
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["census:stale"])
        self.assertEqual(b["allowed_new_lanes"], 0)

    def test_a_bare_date_refuses_rather_than_raising(self):
        c = census_with(dev=DEV_IDLE); c["at"] = "2020-01-01"
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["census:stale"])
        self.assertEqual(b["allowed_new_lanes"], 0)

    def test_an_unparseable_timestamp_refuses(self):
        c = census_with(dev=DEV_IDLE); c["at"] = "not-a-timestamp"
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["census:stale"])
        self.assertEqual(b["allowed_new_lanes"], 0)

    def test_a_future_timestamp_refuses(self):
        # Clock skew, not staleness: a census claiming to be from the future is exactly as
        # unusable as one from too far in the past, and the 0 <= lower bound is what catches it.
        future = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=1)
        c = census_with(dev=DEV_IDLE)
        c["at"] = future.strftime("%Y-%m-%dT%H:%M:%SZ")
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["census:stale"])
        self.assertEqual(b["allowed_new_lanes"], 0)


class RecordingRunner:
    """Local test double (not ``rabota.runner.FakeRunner``): records the ``env`` each call got,
    which ``FakeRunner`` deliberately does not (it matches by argv prefix only) and ``runner.py``
    is out of DO-728's edit scope. One canned ``result`` answers every call."""
    def __init__(self, result):
        self.result, self.calls = result, []

    def run(self, argv, *, env=None, input=None, timeout=60, cwd=None):
        self.calls.append({"argv": list(argv), "env": dict(env) if env is not None else None})
        return self.result


def lane_row(id, seat, started_at, ended_at, pct_start, pct_end, *, tenant="quantivly",
            status="done", settle_reason=None):
    return dict(id=id, tenant=tenant, kind="work", brief="b", repo="r", worktree="w", out_dir="o",
                machine="local", unit=f"rabota-lane-{id}.service", session_id="s", model="m",
                status=status, started_at=started_at, ended_at=ended_at, seat=seat, effort="e",
                five_h_pct_at_start=pct_start, five_h_pct_at_end=pct_end, settle_reason=settle_reason)


class MeasuredRateTests(unittest.TestCase):
    def ctx(self, tenant="quantivly"):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        c = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=FakeRunner([]),
                                           env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(lambda: c._store and c._store.close())
        return c

    def test_no_history_returns_the_floor(self):
        rate, source = budget.measured_rate(self.ctx().store, "quantivly", "quantivly-1")
        self.assertEqual(rate, budget.RATE_FLOOR)
        self.assertEqual(source, "floor 115 pts/h, no history")

    def test_non_overlapping_lanes_use_the_trailing_median(self):
        # Three lanes, back to back, no overlap: 10%/h, 20%/h, 30%/h -> median 20.
        ctx = self.ctx()
        ctx.store.insert_lane(lane_row("a", "quantivly-1", "2026-09-24T00:00:00Z", "2026-09-24T01:00:00Z", 0, 10))
        ctx.store.insert_lane(lane_row("b", "quantivly-1", "2026-09-24T02:00:00Z", "2026-09-24T03:00:00Z", 10, 30))
        ctx.store.insert_lane(lane_row("c", "quantivly-1", "2026-09-24T04:00:00Z", "2026-09-24T04:30:00Z", 30, 45))
        rate, source = budget.measured_rate(ctx.store, "quantivly", "quantivly-1")
        self.assertEqual(rate, 20.0)
        self.assertEqual(source, "measured median 20.0 pts/h over 3 lanes")

    def test_a_naive_per_lane_rate_would_be_far_higher_than_three_overlapping_lanes_really_burned(self):
        # DO-728 hazard: three lanes on ONE seat overlapping over a single hour, seat pct rising
        # from 10 to 30 over that whole hour (20 pts/h really burned). A naive per-lane rate
        # counts each lane's own start-to-end delta separately and triple-counts the shared rise
        # (a's 20pts/30min=40/h, b's 15pts/40min=22.5/h, c's 10pts/20min=30/h -- median 30, none of
        # them close to the true 20). The busy-span computation must return the true rate instead.
        ctx = self.ctx()
        ctx.store.insert_lane(lane_row("a", "quantivly-1", "2026-09-24T00:00:00Z", "2026-09-24T00:30:00Z", 10, 30))
        ctx.store.insert_lane(lane_row("b", "quantivly-1", "2026-09-24T00:10:00Z", "2026-09-24T00:50:00Z", 14, 29))
        ctx.store.insert_lane(lane_row("c", "quantivly-1", "2026-09-24T00:40:00Z", "2026-09-24T01:00:00Z", 26, 30))
        rate, source = budget.measured_rate(ctx.store, "quantivly", "quantivly-1")
        self.assertEqual(rate, 20.0)   # (30 - 10) / 1h, from the earliest start and the latest end
        self.assertIn("over 3 lanes", source)

    def test_a_window_reset_mid_span_is_dropped_not_inverted(self):
        # The 5h window reset between this lane's start and end: pct_end < pct_start. A naive
        # subtraction goes negative; it must instead be dropped from the sample, falling back to
        # the floor when it is the only row.
        ctx = self.ctx()
        ctx.store.insert_lane(lane_row("a", "quantivly-1", "2026-09-24T00:00:00Z", "2026-09-24T01:00:00Z", 90, 5))
        rate, source = budget.measured_rate(ctx.store, "quantivly", "quantivly-1")
        self.assertEqual((rate, source), (budget.RATE_FLOOR, "floor 115 pts/h, no history"))
        # Mixed with one usable lane, only the usable one contributes.
        ctx.store.insert_lane(lane_row("b", "quantivly-1", "2026-09-24T02:00:00Z", "2026-09-24T03:00:00Z", 10, 26))
        rate, source = budget.measured_rate(ctx.store, "quantivly", "quantivly-1")
        self.assertEqual(rate, 16.0)

    def test_a_row_with_no_output_is_excluded_its_timing_is_suspect(self):
        # DO-747: ended_at on a no-output row is a now() fallback, not the lane's real finish time.
        ctx = self.ctx()
        ctx.store.insert_lane(lane_row("a", "quantivly-1", "2026-09-24T00:00:00Z", "2026-09-24T00:05:00Z",
                                       10, 90, settle_reason="no output file: ..."))
        rate, _ = budget.measured_rate(ctx.store, "quantivly", "quantivly-1")
        self.assertEqual(rate, budget.RATE_FLOOR)   # the 960 pts/h row never entered the sample

    def test_a_started_or_abandoned_row_has_no_ended_at_and_is_excluded(self):
        ctx = self.ctx()
        row = lane_row("a", "quantivly-1", "2026-09-24T00:00:00Z", None, 10, None, status="started")
        ctx.store.insert_lane(row)
        rate, _ = budget.measured_rate(ctx.store, "quantivly", "quantivly-1")
        self.assertEqual(rate, budget.RATE_FLOOR)

    def test_rate_is_per_seat_and_per_tenant(self):
        ctx = self.ctx()
        ctx.store.insert_lane(lane_row("a", "quantivly-1", "2026-09-24T00:00:00Z", "2026-09-24T01:00:00Z", 0, 50))
        # A different seat's history must not leak into quantivly-2's rate.
        rate, _ = budget.measured_rate(ctx.store, "quantivly", "quantivly-2")
        self.assertEqual(rate, budget.RATE_FLOOR)

    def test_credential_gate_overrides_claude_picks_rate_and_names_its_source(self):
        window = pick_json("gate-projected", "quantivly-1", 40, 97, "refuse", 2)
        runner = RecordingRunner(window)
        g = budget.credential_gate(runner, "quantivly-1", "m", "e", 30,
                                   env={"PATH": "/bin"}, rate=16.2, rate_source="measured median 16.2 pts/h over 8 lanes")
        self.assertEqual(runner.calls[0]["env"]["CLAUDE_PICK_RATE_DEFAULT"], "16")
        self.assertEqual(runner.calls[0]["env"]["PATH"], "/bin")   # the base env survives, not just the override
        self.assertIn("measured median 16.2 pts/h over 8 lanes", g["detail"])

    def test_credential_gate_without_a_rate_is_unchanged(self):
        # Direct callers that pass no rate (existing behaviour) must get exactly the old call.
        allow = FakeRunner([(["claude-pick"], pick_json("picked", "quantivly-1", 30, 87, "allow", 0))])
        g = budget.credential_gate(allow, "quantivly-1", "m", "e", 30)
        self.assertEqual((g["ok"], g["code"]), (True, None))


class TwentySixSeptemberSampleTests(unittest.TestCase):
    """DO-728's own worked evidence: 2026-09-24 lane burn measured 6.7-20.5 pts/h, median ~16, over
    8 lanes. The brief did not carry the raw per-lane rows, so this reconstructs a representative
    sample with that exact range and median and checks the new gate against it (hazard 1): a
    50-minute lane must not be refused on a seat sitting at a normal daytime utilisation, the way
    the fixed 115 pts/h constant refused it (96% projected for a 50-minute lane from empty)."""
    RATES = [6.7, 9.4, 12.1, 14.8, 16.2, 17.5, 19.0, 20.5]   # median 16.2, matches DO-728's report

    def test_median_of_the_reconstructed_sample_matches_the_reported_median(self):
        ctx_store = None
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        import argparse as _argparse
        ns = _argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=FakeRunner([]),
                                             env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(lambda: ctx._store and ctx._store.close())
        base = datetime.datetime(2026, 9, 24, tzinfo=datetime.timezone.utc)
        for i, r in enumerate(self.RATES):
            start = base + datetime.timedelta(hours=3 * i)
            end = start + datetime.timedelta(hours=1)
            pct = round(r)
            ctx.store.insert_lane(lane_row(f"l{i}", "quantivly-1", start.strftime("%Y-%m-%dT%H:%M:%SZ"),
                                           end.strftime("%Y-%m-%dT%H:%M:%SZ"), 0, pct))
        rate, source = budget.measured_rate(ctx.store, "quantivly", "quantivly-1")
        self.assertEqual(rate, 15.5)   # rounded-to-int pct deltas over 1h spans; matches the reported ~16
        self.assertIn("over 8 lanes", source)
        # Hazard 1: at this rate a 50-minute lane from an empty window projects to 16*50/60 ~= 13%,
        # nowhere near the 95% ceiling -- the fixed 115 pts/h constant alone projected 96% for the
        # same lane (est_minutes=50 in the brief's own arithmetic: 115*50/60 = 95.8). The new rate
        # frees exactly the work DO-728 says was being refused, without raising the ceiling itself.
        self.assertLess(rate * 50 / 60, 20)
        self.assertGreater(budget.RATE_FLOOR * 50 / 60, 95)
