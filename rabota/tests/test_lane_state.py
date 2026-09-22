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


class LaneCliWiringTests(unittest.TestCase):
    """The argparse -> run_* wiring, which the behaviour rows above cannot see.

    Those rows call ``run_list``/``run_status``/``run_retire`` directly, so the dispatch in
    ``_run`` is untested: hardcoding ``status=None`` there left all 553 tests passing (DO-680b
    review). These drive ``cli.main`` end to end, which is the only path a user takes.
    """

    def setUp(self):
        # `cli.main` resolves the tenant config from $HOME/.dotfiles-local/rabota, NOT from a
        # cfg_base the caller passes — so unlike the rows above, these need a fixture $HOME or
        # they read the developer's real config and pass only on a machine that has one. They
        # did exactly that: green locally, exit 5 on every CI runner (DO-680b, caught by CI).
        from tests.test_cli import install_fixture_home
        install_fixture_home(self)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = str(Path(self.tmp.name))
        from rabota import store as store_mod
        s = store_mod.Store.open(Path(self.state))
        for lid, st in (("A1", "started"), ("B2", "done")):
            s.insert_lane({"id": lid, "tenant": "quantivly", "kind": "work", "brief": "/b",
                           "repo": "hub", "worktree": "/w", "out_dir": "/o", "machine": "dev",
                           "unit": f"{lid}.service", "session_id": "s", "status": st,
                           "started_at": "2026-09-22T00:00:00Z"})

    def run_cli(self, *args):
        """``(code, parsed)`` — both streams captured, since a refusal prints to stderr."""
        import contextlib, io, json as _json
        from rabota import cli
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["--tenant", "quantivly", "--state-dir", self.state, *args])
        raw = out.getvalue().strip() or err.getvalue().strip()
        return code, (_json.loads(raw) if raw.startswith(("{", "[")) else raw)

    def test_status_flag_reaches_the_query(self):
        """Pins the dispatch: with --status hardcoded away, this row is what fails."""
        code, body = self.run_cli("lane", "list", "--status", "started")
        self.assertEqual(code, 0)
        self.assertEqual([l["id"] for l in body["lanes"]], ["A1"])

    def test_no_status_flag_lists_every_lane(self):
        code, body = self.run_cli("lane", "list")
        self.assertEqual(code, 0)
        self.assertEqual(sorted(l["id"] for l in body["lanes"]), ["A1", "B2"])

    def test_an_empty_status_is_a_usage_error_not_no_filter(self):
        """`--status "$WANT"` with WANT unset must not quietly list everything."""
        code, body = self.run_cli("lane", "list", "--status", "")
        self.assertEqual(code, 2)
        self.assertIn("must not be empty", body["error"]["message"])

    def test_the_id_reaches_status_and_retire(self):
        code, body = self.run_cli("lane", "status", "B2")
        self.assertEqual((code, body["id"]), (0, "B2"))
        code, _ = self.run_cli("lane", "retire", "B2")
        self.assertEqual(code, 0)
        code, body = self.run_cli("lane", "status", "B2")
        self.assertEqual(body["status"], "retired")
