"""``rabota lane list|status|retire``: reads and one transition over the ``lanes`` table.

Every test builds its own ``Context`` against a tempdir ``state_dir`` (finding F23) — never the
real tenant state dir — and drives ``FakeRunner([])``, which raises on any unmatched call. That
makes "no runner call" an assertion on ``runner.calls == []``, not an inference.
"""
import argparse
import json
import tempfile
import unittest
from pathlib import Path

from rabota import census, context, errors
from rabota.commands import lane
from rabota.runner import FakeRunner, Result
from tests.test_remote import FIXED_MARKER, patch_uuid, payload

FIX = Path(__file__).parent / "fixtures"


def _run_text(tmp_name, tenant, lane_id):
    ns = argparse.Namespace(tenant=tenant, state_dir=tmp_name, text=True, dry_run=False,
                            lane_cmd="status", lane_id=lane_id)
    return lane._run(ns, cfg_base=FIX / "config", runner=FakeRunner([]),
                     env={"PATH": "/bin"}, cwd=Path("/"))


class LaneStateTests(unittest.TestCase):
    def ctx(self, runner=None, tenant="quantivly", dry_run=False):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=dry_run)
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

    def test_text_status_with_no_settle_reason_is_one_line(self):
        # F2: `lane status --text` used to print only id and status, so a lane settled `failed`
        # with a `settle_reason` (DO-747) was unreachable from the workflow -- a caller had to
        # fetch the JSON row instead. A settled `done` row (no reason recorded) must still print
        # exactly its old one-line shape.
        ctx = self.ctx()
        ctx.store.insert_lane(self.row(id="a1", status="done"))
        # `self.ctx()` opens its own tempdir; reuse ITS state_dir for `_run` below rather than a
        # second tempdir, so the row inserted above is the one `_run` reads back.
        lines = _run_text(str(ctx.state_dir), "quantivly", "a1")
        self.assertEqual(lines, ["a1 done"])

    def test_text_status_prints_settle_reason_when_set(self):
        ctx = self.ctx()
        ctx.store.insert_lane(self.row(id="a1", status="failed"))
        ctx.store.update_lane("a1", settle_reason=census.NO_OUTPUT_REASON)
        lines = _run_text(str(ctx.state_dir), "quantivly", "a1")
        self.assertEqual(lines, ["a1 failed", census.NO_OUTPUT_REASON])

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
        # AMENDED (DO-713): retire now tries to settle a `started` row itself, so a bare
        # `FakeRunner([])` no longer reproduces this case -- it raises AssertionError on the
        # `systemctl --user list-units` call `_settle_started_lane` makes rather than reaching
        # `errors.Refused` at all. This fails against `main` with exactly that AssertionError; the
        # fix is to give the runner a real "unit still active" answer, which is what the row
        # SHOULD do when the unit genuinely has not finished.
        row = self.row(id="a1", status="started")
        runner = FakeRunner([
            (["systemctl", "--user", "list-units"], Result(0, json.dumps(
                [{"unit": row["unit"], "load": "loaded", "active": "active", "sub": "running",
                  "description": "x"}]), "")),
            (["clauth", "status", "--json"], Result(0, "{}", "")),
        ])
        ctx = self.ctx(runner)
        ctx.store.insert_lane(row)
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

    # --- retire, --dry-run (DO-743) ---

    def test_a_dry_run_retire_leaves_the_row_untouched(self):
        ctx = self.ctx(dry_run=True)
        ctx.store.insert_lane(self.row(id="a1", status="done"))
        row = lane.run_retire(ctx, "a1")
        # The returned row still SAYS retired-would-happen via `dry_run`, but the STORED row
        # (what census/reap would see) must be exactly what it was before the call.
        self.assertEqual(row["dry_run"], "nothing retired")
        self.assertEqual(ctx.store.get_lane("a1")["status"], "done")

    def test_a_dry_run_retire_still_refuses_a_still_running_lane(self):
        # The status check is a read, not a write -- it must still run and still refuse, so a
        # dry run answers "would this be refused" honestly rather than always returning ok.
        # AMENDED (DO-713), same reason as test_retire_a_still_running_lane_refuses above: this
        # now needs a runner that actually answers the settle attempt's calls; against `main` it
        # fails with AssertionError, not errors.Refused.
        row = self.row(id="a1", status="started")
        runner = FakeRunner([
            (["systemctl", "--user", "list-units"], Result(0, json.dumps(
                [{"unit": row["unit"], "load": "loaded", "active": "active", "sub": "running",
                  "description": "x"}]), "")),
            (["clauth", "status", "--json"], Result(0, "{}", "")),
        ])
        ctx = self.ctx(runner, dry_run=True)
        ctx.store.insert_lane(row)
        with self.assertRaises(errors.Refused):
            lane.run_retire(ctx, "a1")
        self.assertEqual(ctx.store.get_lane("a1")["status"], "started")

    def test_a_dry_run_retire_of_an_already_retired_lane_carries_no_dry_run_key(self):
        # The already-retired no-op path returns the row unchanged either way; it never touches
        # the store, so there is nothing for `dry_run` to announce.
        ctx = self.ctx(dry_run=True)
        ctx.store.insert_lane(self.row(id="a1", status="retired"))
        row = lane.run_retire(ctx, "a1")
        self.assertEqual(row["status"], "retired")
        self.assertNotIn("dry_run", row)


# --- retire settles a `started` row itself (DO-713) ---


class LaneRetireSettleTests(unittest.TestCase):
    """``lane retire`` on a `started` row: settle it from its own machine, then retire it if that
    leaves it terminal. Reuses ``LaneStateTests``'s fixtures rather than subclassing, since the
    two classes' `ctx`/`row` helpers are identical and duplicating a base class here would be the
    kind of abstraction this repo's own style guidance (CLAUDE.md) asks not to add for two users.
    """

    def ctx(self, runner=None, tenant="quantivly", dry_run=False):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=dry_run)
        c = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner or FakeRunner([]),
                                           env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(lambda: c._store and c._store.close())
        return c

    def row(self, out_dir, **over):
        base = dict(id="a1", tenant="quantivly", kind="work", brief="b", repo="r", worktree="w",
                    out_dir=str(out_dir), machine="local", unit="rabota-lane-quantivly-a1.service",
                    session_id="s", model="m", status="started", started_at="2026-09-16T00:00:00Z",
                    seat="quantivly-1")
        base.update(over)
        return base

    def out_dir(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return Path(tmp.name)

    def local_runner(self, *, active=False, unit="rabota-lane-quantivly-a1.service"):
        units = [{"unit": unit, "load": "loaded", "active": "active", "sub": "running",
                 "description": "x"}] if active else []
        return FakeRunner([
            (["systemctl", "--user", "list-units"], Result(0, json.dumps(units), "")),
            (["clauth", "status", "--json"], Result(0, (FIX / "census" / "clauth_status.json").read_text(), "")),
        ])

    def test_settles_and_retires_a_finished_local_lane_in_one_call(self):
        out = self.out_dir()
        (out / "stream.jsonl").write_text((FIX / "census" / "stream.jsonl").read_text())
        (out / "verdict.json").write_text("{}")
        ctx = self.ctx(self.local_runner(active=False))
        ctx.store.insert_lane(self.row(out))
        row = lane.run_retire(ctx, "a1")
        self.assertEqual(row["status"], "retired")
        stored = ctx.store.get_lane("a1")
        self.assertEqual(stored["status"], "retired")
        self.assertEqual(stored["cost_usd"], 1.23)
        self.assertIsNone(stored["settle_reason"])
        self.assertIsNotNone(stored["ended_at"])

    def test_a_finished_local_lane_with_no_output_file_settles_failed_then_stays_started_at_terminal_check(self):
        # No `*.json` file was ever written -- DO-747's rule settles this `failed` regardless of
        # `is_error`, and `failed` IS terminal, so the same call also retires it.
        out = self.out_dir()
        (out / "stream.jsonl").write_text((FIX / "census" / "stream.jsonl").read_text())
        ctx = self.ctx(self.local_runner(active=False))
        ctx.store.insert_lane(self.row(out))
        row = lane.run_retire(ctx, "a1")
        self.assertEqual(row["status"], "retired")
        stored = ctx.store.get_lane("a1")
        self.assertEqual(stored["settle_reason"], census.NO_OUTPUT_REASON)

    def test_retire_produces_the_same_row_census_would_have(self):
        # Hazard 1: settling via `retire` must be indistinguishable from settling the same lane
        # via a full `census` -- same result parsing, same output-file rule, same ended_at.
        out_a, out_b = self.out_dir(), self.out_dir()
        for out in (out_a, out_b):
            (out / "stream.jsonl").write_text((FIX / "census" / "stream.jsonl").read_text())
            (out / "verdict.json").write_text("{}")
        ctx = self.ctx(self.local_runner(active=False, unit="rabota-lane-quantivly-a1.service"))
        ctx.store.insert_lane(self.row(out_a, id="via-retire", unit="rabota-lane-quantivly-a1.service"))
        ctx.store.insert_lane(self.row(out_b, id="via-census", unit="rabota-lane-quantivly-b1.service"))
        lane.run_retire(ctx, "via-retire")
        settled = census.settle_finished(ctx, units=[], seats=[{"name": "quantivly-1", "five_h_pct": 38}])
        self.assertEqual(settled, ["via-census"])
        via_retire = ctx.store.get_lane("via-retire")
        via_census = ctx.store.get_lane("via-census")
        for key in ("cost_usd", "settle_reason", "five_h_pct_at_end"):
            self.assertEqual(via_retire[key], via_census[key], key)
        # `retire` additionally moves the row on to `retired`; `census` never does.
        self.assertEqual(via_retire["status"], "retired")
        self.assertEqual(via_census["status"], "done")

    def test_retire_of_a_still_active_local_lane_refuses_as_today(self):
        out = self.out_dir()
        ctx = self.ctx(self.local_runner(active=True))
        ctx.store.insert_lane(self.row(out))
        with self.assertRaises(errors.Refused) as cm:
            lane.run_retire(ctx, "a1")
        self.assertIn("started", str(cm.exception))
        self.assertEqual(ctx.store.get_lane("a1")["status"], "started")

    def test_a_dry_run_retire_settles_and_retires_nothing_but_says_so(self):
        out = self.out_dir()
        (out / "stream.jsonl").write_text((FIX / "census" / "stream.jsonl").read_text())
        (out / "verdict.json").write_text("{}")
        ctx = self.ctx(self.local_runner(active=False), dry_run=True)
        ctx.store.insert_lane(self.row(out))
        row = lane.run_retire(ctx, "a1")
        self.assertEqual(row["status"], "done")
        self.assertEqual(row["dry_run"], "nothing settled or retired")
        stored = ctx.store.get_lane("a1")
        self.assertEqual(stored["status"], "started")
        self.assertIsNone(stored["cost_usd"])

    # --- remote lane: one ssh call, never settled from a full census ---

    def test_retire_of_an_unreachable_remote_machine_refuses_naming_it(self):
        ctx = self.ctx(FakeRunner([
            (["clauth", "status", "--json"], Result(0, (FIX / "census" / "clauth_status.json").read_text(), "")),
            (["ssh"], Result(255, "", "no route to host")),
        ]))
        ctx.store.insert_lane(self.row("/home/ubuntu/out/dev-a1", machine="dev"))
        with self.assertRaises(errors.Refused) as cm:
            lane.run_retire(ctx, "a1")
        self.assertIn("dev", str(cm.exception))
        self.assertIn("unreachable", str(cm.exception))
        self.assertEqual(ctx.store.get_lane("a1")["status"], "started")

    def test_retire_of_a_still_active_remote_unit_refuses_as_today(self):
        out_dir = "/home/ubuntu/out/dev-a1"
        with patch_uuid():
            ctx = self.ctx(FakeRunner([
                (["clauth", "status", "--json"], Result(0, (FIX / "census" / "clauth_status.json").read_text(), "")),
                (["ssh"], Result(0, payload(
                    marker=FIXED_MARKER,
                    units="rabota-lane-quantivly-a1.service loaded active running lane\n",
                    streams=((out_dir, ""),)), "")),
            ]))
            ctx.store.insert_lane(self.row(out_dir, machine="dev"))
            with self.assertRaises(errors.Refused) as cm:
                lane.run_retire(ctx, "a1")
        self.assertIn("started", str(cm.exception))
        self.assertEqual(ctx.store.get_lane("a1")["status"], "started")

    def test_settles_and_retires_a_finished_remote_lane_with_one_ssh_call(self):
        out_dir = "/home/ubuntu/out/dev-a1"
        result_line = '{"type":"result","is_error":false,"total_cost_usd":2.5}'
        with patch_uuid():
            runner = FakeRunner([
                (["clauth", "status", "--json"], Result(0, (FIX / "census" / "clauth_status.json").read_text(), "")),
                (["ssh"], Result(0, payload(
                    marker=FIXED_MARKER, units="",
                    streams=((out_dir, result_line, "1700000000"),)), "")),
            ])
            ctx = self.ctx(runner)
            ctx.store.insert_lane(self.row(out_dir, machine="dev", started_at="2020-01-01T00:00:00Z"))
            row = lane.run_retire(ctx, "a1")
        ssh_calls = [c for c in runner.calls if c[0] == "ssh"]
        self.assertEqual(len(ssh_calls), 1)
        self.assertEqual(row["status"], "retired")
        stored = ctx.store.get_lane("a1")
        self.assertEqual(stored["cost_usd"], 2.5)
        self.assertEqual(stored["ended_at"], "2023-11-14T22:13:20Z")


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
        # CLOSED, not left to the GC. CI's 3.13 job runs with ResourceWarning as an error, so an
        # unclosed sqlite connection is a failure there and invisible everywhere else — which is
        # exactly how this row first went red (F17 class).
        self.addCleanup(s.close)
        for lid, st in (("A1", "started"), ("B2", "done")):
            s.insert_lane({"id": lid, "tenant": "quantivly", "kind": "work", "brief": "/b",
                           "repo": "hub", "worktree": "/w", "out_dir": "/o", "machine": "dev",
                           "unit": f"{lid}.service", "session_id": "s", "status": st,
                           "started_at": "2026-09-22T00:00:00Z"})

    def run_cli(self, *args):
        """``(code, parsed)`` — both streams captured, since a refusal prints to stderr, and a
        stray warning (e.g. a ResourceWarning from an unrelated leaked connection) may print
        ahead of the JSON reply (DO-750)."""
        import contextlib, io, json as _json, re as _re
        from rabota import cli
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["--tenant", "quantivly", "--state-dir", self.state, *args])
        raw = out.getvalue() + err.getvalue()
        m = _re.search(r"\{[\s\S]*\}", raw)
        return code, (_json.loads(m.group(0)) if m else raw.strip())

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

    def test_the_global_dry_run_flag_reaches_retire_and_transitions_nothing(self):
        """``--dry-run`` is a GLOBAL flag (before the subcommand, per ``cli.build_parser``); this
        is the one row that proves it actually reaches ``run_retire`` through ``Context.dry_run``
        rather than only being tested against the function directly (DO-743)."""
        from rabota import cli
        import contextlib, io, json as _json
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["--tenant", "quantivly", "--state-dir", self.state, "--dry-run",
                             "lane", "retire", "B2"])
        self.assertEqual(code, 0)
        body = _json.loads(out.getvalue())
        self.assertEqual(body["dry_run"], "nothing retired")
        code, status_body = self.run_cli("lane", "status", "B2")
        self.assertEqual(status_body["status"], "done", "a dry-run retire must not have transitioned the row")
