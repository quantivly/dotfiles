"""``rabota lane list|status|retire``: reads and one transition over the ``lanes`` table.

Every test builds its own ``Context`` against a tempdir ``state_dir`` (finding F23) — never the
real tenant state dir — and drives ``FakeRunner([])``, which raises on any unmatched call. That
makes "no runner call" an assertion on ``runner.calls == []``, not an inference.
"""
import argparse
import tempfile
import unittest
from pathlib import Path

from rabota import context, errors
from rabota.commands import lane
from rabota.runner import FakeRunner

FIX = Path(__file__).parent / "fixtures"


class LaneStateTests(unittest.TestCase):
    def ctx(self, runner=None, tenant="quantivly"):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        c = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner or FakeRunner([]),
                                           env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(lambda: c._store and c._store.close())
        return c

    def row(self, **over):
        base = dict(id="a1", tenant="quantivly", kind="work", brief="b", repo="r", worktree="w",
                    out_dir="o", machine="local", unit="rabota-lane-quantivly-a1.service",
                    session_id="s", model="m", status="started", started_at="2026-09-16T00:00:00Z")
        base.update(over)
        return base

    # --- list ---

    def test_list_with_no_filter_returns_every_status(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.row(id="a1", status="started"))
        ctx.store.insert_lane(self.row(id="a2", status="done"))
        ctx.store.insert_lane(self.row(id="a3", status="retired"))
        out = lane.run_list(ctx)
        self.assertEqual(sorted(l["id"] for l in out["lanes"]), ["a1", "a2", "a3"])

    def test_list_with_status_filters(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.row(id="a1", status="started"))
        ctx.store.insert_lane(self.row(id="a2", status="done"))
        out = lane.run_list(ctx, status="done")
        self.assertEqual([l["id"] for l in out["lanes"]], ["a2"])

    def test_list_is_tenant_scoped(self):
        ctx = self.ctx(tenant="quantivly")
        ctx.store.insert_lane(self.row(id="mine", tenant="quantivly"))
        ctx.store.insert_lane(self.row(id="theirs", tenant="other-tenant"))
        out = lane.run_list(ctx)
        self.assertEqual([l["id"] for l in out["lanes"]], ["mine"])

    def test_list_makes_no_runner_call(self):
        runner = FakeRunner([])
        ctx = self.ctx(runner)
        ctx.store.insert_lane(self.row())
        lane.run_list(ctx)
        self.assertEqual(runner.calls, [])

    # --- status ---

    def test_status_returns_the_row(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.row(id="a1", status="done"))
        row = lane.run_status(ctx, "a1")
        self.assertEqual(row["id"], "a1")
        self.assertEqual(row["status"], "done")

    def test_status_on_unknown_id_refuses_by_name(self):
        ctx = self.ctx()
        with self.assertRaises(errors.Refused) as cm:
            lane.run_status(ctx, "nope")
        self.assertIn("nope", str(cm.exception))

    def test_status_on_another_tenants_row_refuses_by_name(self):
        ctx = self.ctx(tenant="quantivly")
        ctx.store.insert_lane(self.row(id="theirs", tenant="other-tenant"))
        with self.assertRaises(errors.Refused) as cm:
            lane.run_status(ctx, "theirs")
        self.assertIn("theirs", str(cm.exception))

    def test_status_makes_no_runner_call(self):
        runner = FakeRunner([])
        ctx = self.ctx(runner)
        ctx.store.insert_lane(self.row(id="a1", status="done"))
        lane.run_status(ctx, "a1")
        self.assertEqual(runner.calls, [])

    # --- retire ---

    def test_retire_transitions_a_settled_row(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.row(id="a1", status="done"))
        row = lane.run_retire(ctx, "a1")
        self.assertEqual(row["status"], "retired")
        self.assertEqual(ctx.store.get_lane("a1")["status"], "retired")

    def test_retire_a_failed_or_abandoned_row_also_transitions(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.row(id="f1", status="failed"))
        ctx.store.insert_lane(self.row(id="ab1", status="abandoned"))
        self.assertEqual(lane.run_retire(ctx, "f1")["status"], "retired")
        self.assertEqual(lane.run_retire(ctx, "ab1")["status"], "retired")

    def test_retire_a_still_running_lane_refuses(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.row(id="a1", status="started"))
        with self.assertRaises(errors.Refused) as cm:
            lane.run_retire(ctx, "a1")
        self.assertIn("started", str(cm.exception))
        self.assertEqual(ctx.store.get_lane("a1")["status"], "started")

    def test_a_second_retire_is_a_defined_no_op(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.row(id="a1", status="done"))
        first = lane.run_retire(ctx, "a1")
        second = lane.run_retire(ctx, "a1")
        self.assertEqual(first["status"], "retired")
        self.assertEqual(second["status"], "retired")

    def test_retire_on_unknown_id_refuses_by_name(self):
        ctx = self.ctx()
        with self.assertRaises(errors.Refused) as cm:
            lane.run_retire(ctx, "nope")
        self.assertIn("nope", str(cm.exception))

    def test_retire_makes_no_runner_call(self):
        runner = FakeRunner([])
        ctx = self.ctx(runner)
        ctx.store.insert_lane(self.row(id="a1", status="done"))
        lane.run_retire(ctx, "a1")
        self.assertEqual(runner.calls, [])


if __name__ == "__main__":
    unittest.main()
