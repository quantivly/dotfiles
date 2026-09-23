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
    def ctx(self, runner=None, tenant="quantivly", dry_run=False):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=dry_run)
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

    def test_a_malformed_started_at_is_named_unavailable_not_a_crash_for_the_whole_tenant(self):
        """A single row with an unparseable started_at used to raise ValueError out of
        plan_reap, failing every other row's bookkeeping too. It must instead be named as an
        unmeasured dimension while the rest of the tenant's rows are still processed."""
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(id="bad", unit="rabota-lane-quantivly-bad-1.service",
                                            started_at="not-a-date"))
        ctx.store.insert_lane(self.lane_row(id="old", unit="rabota-lane-quantivly-old-2.service",
                                            started_at="2026-09-16T00:00:00Z"))
        plan = reap.plan_reap(ctx, self.census())
        self.assertEqual(ctx.store.get_lane("bad")["status"], "started")
        self.assertEqual(ctx.store.get_lane("old")["status"], "abandoned")
        self.assertIn("reap:started_at:bad:unmeasured", plan["unavailable"])

    def test_an_absent_started_at_is_never_immortal(self):
        """An empty/absent started_at used to return 0.0 hours, so such a row could never age
        past abandoned_hours no matter how long it ran. It must be named unavailable instead of
        silently treated as always-fresh."""
        ctx = self.ctx()
        ctx.store.insert_lane(self.lane_row(id="noage", unit="rabota-lane-quantivly-noage-1.service",
                                            started_at=""))
        plan = reap.plan_reap(ctx, self.census(), abandoned_hours=0)
        self.assertEqual(ctx.store.get_lane("noage")["status"], "started")
        self.assertIn("reap:started_at:noage:unmeasured", plan["unavailable"])

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
        path = "/home/ubuntu/wt/old"
        out = (f"\n{marker}\n{len(path)}\n{path}\n0\n"
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
        out = (f"\n{marker}\n5\n/w/ok\n0\nremoved\n"
              f"{marker}\n6\n/w/bad\n1\nfatal: '/w/bad' is dirty, use --force to override\n")
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

    def test_dry_run_removes_nothing_local_or_remote(self):
        """ctx.dry_run used to be read nowhere in this module: apply_reap still ran wt-gc --apply
        and still issued remote removals with --dry-run set. FakeRunner([]) raises loudly if
        either is attempted, so this fails without the fix rather than passing vacuously."""
        ctx = self.ctx(FakeRunner([]), dry_run=True)
        ctx.store.insert_lane(self.lane_row(machine="dev", repo="hub", worktree="/w/old", status="done"))
        rep = reap.apply_reap(ctx, reap.plan_reap(ctx, self.census()), {"worktrees"})
        self.assertTrue(rep["dry_run"])
        self.assertIsNone(rep["worktrees"])
        self.assertEqual(rep["remote_worktrees"], {"removed": [], "failed": []})
        self.assertEqual(ctx.runner.calls, [])


class RunTargetTests(ReapTestCase):
    """``_run`` is the only place the ``--apply`` no-target default lived; ``apply_reap`` itself
    is never handed an empty target set by the CLI in practice, so these drive ``_run`` directly
    with ``gather``/``Context.from_namespace`` patched rather than duplicating plan/apply coverage.
    """

    def _ns(self, **over):
        base = dict(tenant="quantivly", state_dir="/unused", text=False, dry_run=False,
                    apply=False, sessions=False, spaces=False, worktrees=False,
                    idle_hours=24, abandoned_hours=6)
        base.update(over)
        return argparse.Namespace(**base)

    def test_apply_with_no_target_refuses_and_touches_nothing(self):
        ctx = self.ctx(FakeRunner([]))
        with mock.patch("rabota.commands.reap.Context.from_namespace", return_value=ctx), \
             mock.patch("rabota.commands.reap.gather", return_value=self.census()):
            with self.assertRaises(errors.Usage) as cm:
                reap._run(self._ns(apply=True))
        self.assertIn("--worktrees", str(cm.exception))
        self.assertIn("1 worktree", str(cm.exception))
        self.assertEqual(ctx.runner.calls, [])

    def test_apply_with_worktrees_target_still_acts(self):
        runner = FakeRunner([(["wt-gc", "--apply"], Result(0, "reaped /w1\n", ""))])
        ctx = self.ctx(runner)
        with mock.patch("rabota.commands.reap.Context.from_namespace", return_value=ctx), \
             mock.patch("rabota.commands.reap.gather", return_value=self.census()):
            rep = reap._run(self._ns(apply=True, worktrees=True))
        self.assertIn("reaped /w1", rep["worktrees"])

    def test_dry_run_with_no_target_still_prints_the_full_plan(self):
        ctx = self.ctx(FakeRunner([]))
        with mock.patch("rabota.commands.reap.Context.from_namespace", return_value=ctx), \
             mock.patch("rabota.commands.reap.gather", return_value=self.census()):
            plan = reap._run(self._ns())
        self.assertEqual(len(plan["worktrees"]), 1)
        self.assertEqual(ctx.runner.calls, [])


class RemovalFramingTests(unittest.TestCase):
    """Runs ``_removal_script`` through a REAL shell (a stub ``git`` on ``PATH``) rather than
    hand-building canned output — the newline-delimited framing this replaces parsed fine against
    a hand-written string but broke against what a real shell actually prints for a path
    containing a literal newline; only a real round trip catches that.
    """

    def _run_script(self, items):
        import os
        import subprocess
        import sys

        marker = "---TEST-MARKER---"
        script = reap._removal_script(items, marker)
        with tempfile.TemporaryDirectory() as td:
            stub = Path(td) / "git"
            stub.write_text("#!/bin/sh\necho stub-git-ran\nexit 0\n")
            stub.chmod(0o755)
            env = dict(os.environ, PATH=f"{td}:{os.environ.get('PATH', '/usr/bin:/bin')}")
            r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, f"stub script failed: {r.stderr}")
        return reap._parse_removal_output(r.stdout, marker)

    def test_a_newline_in_a_worktree_path_does_not_lose_its_outcome(self):
        """Confirmed regression: of ['/tmp/wt\\nnl', '/tmp/plain'], the newline-delimited framing
        recovered only /tmp/plain — the newline inside the first path shifted every field after
        it, and int(code_s) then raised inside _parse_removal_output, dropping that item
        entirely."""
        items = [{"path": "/tmp/wt\nnl", "repo_path": "/tmp/repo", "lane_id": "a"},
                 {"path": "/tmp/plain", "repo_path": "/tmp/repo", "lane_id": "b"}]
        by_path = self._run_script(items)
        self.assertEqual(set(by_path), {"/tmp/wt\nnl", "/tmp/plain"})
        self.assertEqual(by_path["/tmp/wt\nnl"]["code"], 0)
        self.assertEqual(by_path["/tmp/plain"]["code"], 0)


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
