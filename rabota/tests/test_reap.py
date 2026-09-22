"""``rabota reap``: abandoned lane rows, idle-session hints, wt-gc delegation, remote lane worktrees.

Every test builds its own ``Context`` against a tempdir ``state_dir`` (finding F23) — never the
real tenant state dir — and drives ``FakeRunner``, which raises on any unmatched call. ``reap``
must never reach the real machine or start a real removal: these tests are the proof.
"""
import argparse
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from rabota import context, errors
from rabota.commands import reap
from rabota.runner import FakeRunner, Result

FIX = Path(__file__).parent / "fixtures"
FIXED_UUID = __import__("uuid").UUID("11111111-2222-3333-4444-555555555555")


def patch_uuid():
    """``_remove_remote_worktrees`` mints a fresh nonce marker per call; fix it so a test's
    canned ``Result`` can be built with the exact marker the code is about to use."""
    return mock.patch("rabota.commands.reap.uuid.uuid4", return_value=FIXED_UUID)


class ReapTestCase(unittest.TestCase):
    def ctx(self, runner=None, tenant="quantivly"):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        c = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner or FakeRunner([]),
                                           env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(lambda: c._store and c._store.close())
        return c

    def lane_row(self, **over):
        base = dict(id="old", tenant="quantivly", kind="work", brief="b", repo="r", worktree="w",
                    out_dir="o", machine="local", unit="rabota-lane-quantivly-old-1.service",
                    session_id="s", model="m", status="started", started_at="2026-09-16T00:00:00Z")
        base.update(over)
        return base

    def census(self, **over):
        base = {"sessions": [{"pid": 1, "cwd": "/a", "owner": "user", "age_s": 3 * 86400, "cpu_pct_5s": 0.2, "unit": None},
                             {"pid": 2, "cwd": "/b", "owner": "user", "age_s": 600, "cpu_pct_5s": 0.0, "unit": None},
                             {"pid": 3, "cwd": "/c", "owner": "sol", "age_s": 3 * 86400, "cpu_pct_5s": 0.0, "unit": "nanoclaw-orchestrate.service"}],
                "units": [], "worktrees": [{"path": "/w1", "repo": "r", "branch": "b", "verdict": "REAP", "reason": "merged"}],
                "machines": [], "unavailable": []}
        base.update(over)
        return base


class PlanReapTests(ReapTestCase):
    def test_plan_marks_abandoned_and_lists_idle_user_sessions_only(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(id="old", started_at="2026-09-16T00:00:00Z"))
        ctx.store.insert_lane(self.lane_row(id="fresh", unit="rabota-lane-quantivly-fresh-2.service",
                                            started_at=reap.now()))
        plan = reap.plan_reap(ctx, self.census())
        self.assertEqual([a["id"] for a in plan["abandoned"]], ["old"])
        self.assertEqual(ctx.store.get_lane("old")["status"], "abandoned")
        self.assertEqual(ctx.store.get_lane("fresh")["status"], "started")
        self.assertEqual([s["pid"] for s in plan["sessions"]], [1])       # sol's process is never listed; fresh is too young
        self.assertEqual(len(plan["worktrees"]), 1)
        self.assertEqual(plan["worktrees"][0]["kind"], "local")
        self.assertIn("deferred:spaces", plan["unavailable"])
        self.assertEqual(plan["spaces"], [])

    def test_abandoned_marking_happens_without_apply(self):
        """Bookkeeping about an already-gone unit, not an action on a machine — applies even in
        a dry-run plan() call, per the spec's locked decision."""
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row())
        reap.plan_reap(ctx, self.census())
        self.assertEqual(ctx.store.get_lane("old")["status"], "abandoned")
        self.assertIsNotNone(ctx.store.get_lane("old")["abandoned_at"])

    def test_a_lane_younger_than_abandoned_hours_is_left_started(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(started_at=reap.now()))
        reap.plan_reap(ctx, self.census(), abandoned_hours=6)
        self.assertEqual(ctx.store.get_lane("old")["status"], "started")

    def test_a_live_remote_unit_is_never_marked_abandoned(self):
        """A remote lane's unit shows up under census["machines"][i]["units"], never under the
        top-level census["units"] (that list is LOCAL only) — reading local units alone would
        abandon every active remote lane after abandoned_hours regardless of whether it is
        still running."""
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(machine="dev", unit="rabota-lane-quantivly-old-1.service",
                                            repo="hub", worktree="/remote/wt/old"))
        census = self.census(machines=[{"name": "dev", "reachable": True,
                                        "units": [{"name": "rabota-lane-quantivly-old-1.service", "state": "active"}]}])
        reap.plan_reap(ctx, census)
        self.assertEqual(ctx.store.get_lane("old")["status"], "started")

    def test_an_unreachable_machine_never_gets_its_lanes_marked_abandoned(self):
        """An unmeasured dimension is never room to act: census could not confirm the unit is
        gone on an unreachable machine, so its lanes are left alone rather than guessed at."""
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(machine="dev", unit="rabota-lane-quantivly-old-1.service",
                                            repo="hub", worktree="/remote/wt/old"))
        census = self.census(machines=[{"name": "dev", "reachable": False, "error": "no route"}])
        reap.plan_reap(ctx, census)
        self.assertEqual(ctx.store.get_lane("old")["status"], "started")

    def test_settled_remote_lane_worktree_is_a_removable_candidate(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(machine="dev", repo="hub", worktree="/home/ubuntu/wt/old",
                                            status="done"))
        plan = reap.plan_reap(ctx, self.census(worktrees=[]))
        remote_items = [w for w in plan["worktrees"] if w["kind"] == "remote"]
        self.assertEqual(len(remote_items), 1)
        self.assertEqual(remote_items[0]["machine"], "dev")
        self.assertEqual(remote_items[0]["path"], "/home/ubuntu/wt/old")
        self.assertEqual(remote_items[0]["repo_path"], "~/quantivly/hub")
        self.assertEqual(remote_items[0]["lane_id"], "old")

    def test_a_started_remote_lane_worktree_is_not_a_removable_candidate(self):
        """A started row's worktree is in use — and young enough that the abandon check above
        must not have swept it into "abandoned" first, which would make this test pass for the
        wrong reason."""
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(machine="dev", repo="hub", worktree="/home/ubuntu/wt/old",
                                            status="started", started_at=reap.now()))
        plan = reap.plan_reap(ctx, self.census(worktrees=[]))
        self.assertEqual([w for w in plan["worktrees"] if w["kind"] == "remote"], [])

    def test_a_local_lane_worktree_is_never_a_remote_candidate(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(machine="local", repo="r", worktree="/home/z/wt/old",
                                            status="done"))
        plan = reap.plan_reap(ctx, self.census(worktrees=[]))
        self.assertEqual([w for w in plan["worktrees"] if w["kind"] == "remote"], [])

    def test_a_settled_lane_on_an_undeclared_machine_is_named_in_unavailable_not_guessed(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(machine="gpu", repo="hub", worktree="/w/old", status="done"))
        plan = reap.plan_reap(ctx, self.census(worktrees=[]))
        self.assertEqual([w for w in plan["worktrees"] if w["kind"] == "remote"], [])
        self.assertIn("reap:worktree:old:unknown-machine", plan["unavailable"])

    def test_a_settled_lane_whose_repo_the_machine_no_longer_declares_is_named_not_guessed(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(machine="dev", repo="gone", worktree="/w/old", status="done"))
        plan = reap.plan_reap(ctx, self.census(worktrees=[]))
        self.assertEqual([w for w in plan["worktrees"] if w["kind"] == "remote"], [])
        self.assertIn("reap:worktree:old:unknown-repo", plan["unavailable"])


class ApplyReapTests(ReapTestCase):
    def test_apply_sessions_is_usage_error(self):
        ctx = self.ctx()
        with self.assertRaises(errors.Usage):
            reap.apply_reap(ctx, reap.plan_reap(ctx, self.census()), {"sessions"})

    def test_apply_sessions_is_usage_error_even_combined_with_worktrees(self):
        ctx = self.ctx()
        with self.assertRaises(errors.Usage):
            reap.apply_reap(ctx, reap.plan_reap(ctx, self.census()), {"sessions", "worktrees"})

    def test_apply_worktrees_delegates_to_wt_gc(self):
        runner = FakeRunner([(["wt-gc", "--apply"], Result(0, "reaped /w1\n", ""))])
        ctx = self.ctx(runner)
        rep = reap.apply_reap(ctx, reap.plan_reap(ctx, self.census()), {"worktrees"})
        self.assertIn("reaped /w1", rep["worktrees"])

    def test_a_failed_wt_gc_call_is_reported_not_raised(self):
        runner = FakeRunner([(["wt-gc", "--apply"], Result(1, "", "wt-gc: boom"))])
        ctx = self.ctx(runner)
        rep = reap.apply_reap(ctx, reap.plan_reap(ctx, self.census()), {"worktrees"})
        self.assertIsNone(rep["worktrees"])
        self.assertEqual(rep["failed"], [{"worktrees": "wt-gc: boom"}])

    def test_apply_removes_remote_worktree_in_one_ssh_call(self):
        marker = reap.REAP_MARKER + FIXED_UUID.hex
        out = (f"\n{marker}\n/home/ubuntu/wt/old\n0\n"
              f"Removing worktrees/quantivly/old: gone\n")
        runner = FakeRunner([(["wt-gc", "--apply"], Result(0, "", "")),
                             (["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", "dev"], Result(0, out, ""))])
        ctx = self.ctx(runner)
        ctx.store.insert_lane(self.lane_row(machine="dev", repo="hub", worktree="/home/ubuntu/wt/old",
                                            status="done"))
        with patch_uuid():
            rep = reap.apply_reap(ctx, reap.plan_reap(ctx, self.census(worktrees=[])), {"worktrees"})
        self.assertEqual(rep["remote_worktrees"]["removed"],
                         [{"machine": "dev", "path": "/home/ubuntu/wt/old", "lane_id": "old"}])
        self.assertEqual(rep["remote_worktrees"]["failed"], [])

    def test_apply_reports_a_per_worktree_failure_without_losing_the_rest(self):
        marker = reap.REAP_MARKER + FIXED_UUID.hex
        out = (f"\n{marker}\n/w/ok\n0\nremoved\n"
              f"{marker}\n/w/bad\n1\nfatal: '/w/bad' is dirty, use --force to override\n")
        runner = FakeRunner([(["wt-gc", "--apply"], Result(0, "", "")),
                             (["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", "dev"], Result(0, out, ""))])
        ctx = self.ctx(runner)
        ctx.store.insert_lane(self.lane_row(id="ok", machine="dev", repo="hub", worktree="/w/ok", status="done"))
        ctx.store.insert_lane(self.lane_row(id="bad", machine="dev", repo="hub", worktree="/w/bad", status="failed",
                                            unit="rabota-lane-quantivly-bad-2.service"))
        with patch_uuid():
            rep = reap.apply_reap(ctx, reap.plan_reap(ctx, self.census(worktrees=[])), {"worktrees"})
        removed_paths = {r["path"] for r in rep["remote_worktrees"]["removed"]}
        failed_paths = {f["path"] for f in rep["remote_worktrees"]["failed"]}
        self.assertEqual(removed_paths, {"/w/ok"})
        self.assertEqual(failed_paths, {"/w/bad"})

    def test_an_unreachable_machine_fails_every_one_of_its_worktrees_but_others_proceed(self):
        runner = FakeRunner([(["wt-gc", "--apply"], Result(0, "", "")),
                             (["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", "dev"],
                              Result(255, "", "ssh: connect to host dev: Connection refused"))])
        ctx = self.ctx(runner)
        ctx.store.insert_lane(self.lane_row(machine="dev", repo="hub", worktree="/w/old", status="done"))
        with patch_uuid():
            rep = reap.apply_reap(ctx, reap.plan_reap(ctx, self.census(worktrees=[])), {"worktrees"})
        self.assertEqual(rep["remote_worktrees"]["removed"], [])
        self.assertEqual(len(rep["remote_worktrees"]["failed"]), 1)
        self.assertEqual(rep["remote_worktrees"]["failed"][0]["path"], "/w/old")
        self.assertIn("refused", rep["remote_worktrees"]["failed"][0]["error"].lower())

    def test_apply_without_worktrees_target_touches_nothing(self):
        ctx = self.ctx(FakeRunner([]))
        ctx.store.insert_lane(self.lane_row(machine="dev", repo="hub", worktree="/w/old", status="done"))
        rep = reap.apply_reap(ctx, reap.plan_reap(ctx, self.census(worktrees=[])), set())
        self.assertIsNone(rep["worktrees"])
        self.assertEqual(rep["remote_worktrees"], {"removed": [], "failed": []})
        self.assertEqual(ctx.runner.calls, [])


class ReapCliWiringTests(unittest.TestCase):
    """A SUBPROCESS, deliberately: ``reap`` is already listed in ``cli.COMMAND_MODULES`` while
    ``commands/reap.py`` did not exist before this change, and ``_load_command_modules`` silently
    swallows a ``ModuleNotFoundError`` for exactly that name — so an in-process test importing
    ``rabota.commands.reap`` directly would pass regardless of whether the CLI can ever reach it.
    """

    def test_reap_help_is_registered_and_exits_zero(self):
        import subprocess
        import sys
        r = subprocess.run([sys.executable, "-m", "rabota", "reap", "--help"],
                           capture_output=True, text=True,
                           cwd=str(Path(__file__).resolve().parents[1]),
                           env={"PATH": "/usr/bin:/bin", "PYTHONPATH": str(Path(__file__).resolve().parents[1])})
        self.assertEqual(r.returncode, 0, f"stderr: {r.stderr[:400]}")
        self.assertNotIn("invalid choice", r.stderr)
        self.assertIn("reap", r.stdout.lower())


if __name__ == "__main__":
    unittest.main()
