import argparse, json, tempfile, unittest
from pathlib import Path

from rabota import context, errors
from rabota.commands import escalate, close, db
from rabota.runner import FakeRunner, Result

FIX = Path(__file__).parent / "fixtures"
HERDR_OK = (["herdr", "notification", "show"], Result(0, "", ""))


class CloseTests(unittest.TestCase):
    def ctx(self, runner=None):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        c = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner or FakeRunner([HERDR_OK]),
                                            env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(c.close)
        return c

    # --- escalate / answer -------------------------------------------------

    def test_escalate_and_answer_project_to_jsonl(self):
        ctx = self.ctx()
        eid = escalate.run_escalate(ctx, "merge HUB-1?", "approved by alex", ["merge", "wait"])["id"]
        with self.assertRaises(errors.Refused):
            escalate.run_answer(ctx, eid, "yolo")
        escalate.run_answer(ctx, eid, "merge")
        rows = [json.loads(l) for l in (ctx.state_dir / "escalations.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["firstSeen"], rows[1]["firstSeen"])
        self.assertEqual(rows[1]["disposition"], "merge")
        # §3.1: kind/subject/tenant ride along on both rows, defaulting kind to "finding"
        for row in rows:
            self.assertEqual(row["kind"], "finding")
            self.assertIsNone(row["subject"])
            self.assertEqual(row["tenant"], "quantivly")

    def test_escalate_rejects_an_unknown_kind(self):
        ctx = self.ctx()
        with self.assertRaises(errors.Usage):
            escalate.run_escalate(ctx, "q", "e", [], kind="bogus")

    def test_escalate_notifies_once_per_call_with_the_kind_and_question(self):
        runner = FakeRunner([HERDR_OK, HERDR_OK])
        ctx = self.ctx(runner)
        escalate.run_escalate(ctx, "merge HUB-1?", "evidence", [], kind="decision", subject="HUB-1")
        self.assertEqual(len(runner.calls), 1)
        argv = runner.calls[0]
        self.assertEqual(argv[:3], ["herdr", "notification", "show"])
        self.assertIn("rabota decision: merge HUB-1?", argv[3])

    def test_escalate_no_notify_makes_no_herdr_call(self):
        runner = FakeRunner([])
        ctx = self.ctx(runner)
        escalate.run_escalate(ctx, "q", "e", [], notify=False)
        self.assertEqual(runner.calls, [])

    def test_answer_carries_kind_subject_tenant_from_the_stored_row(self):
        ctx = self.ctx()
        eid = escalate.run_escalate(ctx, "q", "e", ["a", "b"], kind="incident", subject="HUB-9")["id"]
        escalate.run_answer(ctx, eid, "a")
        rows = [json.loads(l) for l in (ctx.state_dir / "escalations.jsonl").read_text().splitlines()]
        self.assertEqual(rows[1]["kind"], "incident")
        self.assertEqual(rows[1]["subject"], "HUB-9")

    # --- item 1: a raising notification runner must not lose the id --------

    def test_escalate_notify_raising_oserror_still_returns_id_and_persists(self):
        class Raiser:
            def run(self, argv, **kw):
                raise OSError("herdr not installed")
        ctx = self.ctx(Raiser())
        out = escalate.run_escalate(ctx, "q", "e", [])
        self.assertIn("id", out)
        self.assertIsNotNone(ctx.store.escalation(out["id"]))
        rows = [json.loads(l) for l in (ctx.state_dir / "escalations.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 1)

    def test_escalate_notify_raising_bare_exception_still_returns_id_and_persists(self):
        class Raiser:
            def run(self, argv, **kw):
                raise Exception("boom")
        ctx = self.ctx(Raiser())
        out = escalate.run_escalate(ctx, "q", "e", [])
        self.assertIn("id", out)
        self.assertIsNotNone(ctx.store.escalation(out["id"]))
        rows = [json.loads(l) for l in (ctx.state_dir / "escalations.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 1)

    def test_escalate_notify_nonzero_exit_still_returns_id_and_persists(self):
        runner = FakeRunner([(["herdr"], Result(1, "", "no herdr"))])
        ctx = self.ctx(runner)
        out = escalate.run_escalate(ctx, "q", "e", [])
        self.assertIn("id", out)
        self.assertIsNotNone(ctx.store.escalation(out["id"]))
        rows = [json.loads(l) for l in (ctx.state_dir / "escalations.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 1)

    def test_escalate_notify_timeout_still_returns_id_and_persists(self):
        runner = FakeRunner([(["herdr"], Result(124, "", "timeout after 5s"))])
        ctx = self.ctx(runner)
        out = escalate.run_escalate(ctx, "q", "e", [])
        self.assertIn("id", out)
        self.assertIsNotNone(ctx.store.escalation(out["id"]))
        rows = [json.loads(l) for l in (ctx.state_dir / "escalations.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 1)

    # --- item 2: the answer projection must carry resolvedAt ---------------

    def test_answer_projects_resolvedAt_from_the_stored_row(self):
        ctx = self.ctx()
        eid = escalate.run_escalate(ctx, "q", "e", ["a", "b"], notify=False)["id"]
        escalate.run_answer(ctx, eid, "a")
        stored = ctx.store.escalation(eid)
        rows = [json.loads(l) for l in (ctx.state_dir / "escalations.jsonl").read_text().splitlines()]
        self.assertIn("resolvedAt", rows[1])
        self.assertEqual(rows[1]["resolvedAt"], stored["resolved_at"])
        self.assertNotIn("resolvedAt", rows[0])

    # --- close ---------------------------------------------------------

    def test_close_refuses_with_held_lane_and_writes_carry_forward(self):
        ctx = self.ctx()
        ctx.store.insert_lane({"id": "l1", "tenant": "quantivly", "kind": "work", "brief": "/b", "repo": "/r", "worktree": "/w",
                               "out_dir": "/o", "machine": "local", "unit": "u", "session_id": "s", "model": "m",
                               "status": "held", "started_at": "2026-09-16T08:00:00Z", "held_reason": "verdict oversize"})
        with self.assertRaises(errors.Refused):
            close.run_close(ctx)
        ctx.store.update_lane("l1", status="running", held_reason=None)
        ctx.store.record_gate("quantivly", "post reply HUB-6247", "approved")
        out = close.run_close(ctx, notes=["did not touch SEC-211"])
        cf = Path(out["carry_forward"]).read_text()
        self.assertIn("l1", cf)
        self.assertIn("the gate was answered: approved", cf)
        self.assertIn("SEC-211", cf)
        self.assertNotIn("Zvi approved", cf)
        self.assertTrue((ctx.state_dir / "INDEX.md").read_text().count("| close |") == 1)

    def test_close_sanitizes_newlines_and_pipes_in_the_index_row(self):
        ctx = self.ctx()
        out = close.run_close(ctx, notes=["line one\nline two", "has | a pipe", "crlf\r\nhere"])
        index_lines = [l for l in (ctx.state_dir / "INDEX.md").read_text().splitlines() if l]
        self.assertEqual(len(index_lines), 3)
        header_pipes = index_lines[0].count("|")
        data_row = index_lines[2]
        self.assertEqual(data_row.count("|"), header_pipes)
        self.assertNotIn("\n", data_row)
        self.assertNotIn("\r", data_row)
        cf = Path(out["carry_forward"]).read_text()
        self.assertIn("line one\nline two", cf)
        self.assertIn("has | a pipe", cf)

    def test_close_lists_open_corrections_separately(self):
        ctx = self.ctx()
        escalate.run_escalate(ctx, "revert bad merge?", "evidence", [], kind="correction", notify=False)
        escalate.run_escalate(ctx, "regular finding", "evidence", [], kind="finding", notify=False)
        out = close.run_close(ctx)
        cf = Path(out["carry_forward"]).read_text()
        self.assertIn("## Corrections carried forward", cf)
        self.assertIn("revert bad merge?", cf.split("## Corrections carried forward")[1].split("##")[0])
        self.assertNotIn("regular finding", cf.split("## Corrections carried forward")[1].split("##")[0])

    # --- db import-v1 ----------------------------------------------------

    def test_import_v1(self):
        ctx = self.ctx()
        rep = db.run_import_v1(ctx, FIX / "v1" / "escalations.jsonl")
        self.assertEqual((rep["imported"], rep["resolved"]), (4, 1))
        open_esc = ctx.store.open_escalations("quantivly")
        self.assertEqual(len(open_esc), 3)

    def test_import_v1_preserves_kind_when_present_and_defaults_when_absent(self):
        ctx = self.ctx()
        db.run_import_v1(ctx, FIX / "v1" / "escalations.jsonl")
        open_esc = ctx.store.open_escalations("quantivly")
        by_question = {e["question"]: e for e in open_esc}
        self.assertEqual(by_question["merge SEC-211?"]["kind"], "decision")
        self.assertEqual(by_question["HUB-5812: retarget?"]["kind"], "finding")

    def test_import_v1_preserves_offset_timestamps_verbatim(self):
        ctx = self.ctx()
        db.run_import_v1(ctx, FIX / "v1" / "escalations.jsonl")
        open_esc = ctx.store.open_escalations("quantivly")
        by_question = {e["question"]: e for e in open_esc}
        self.assertTrue(by_question["merge SEC-211?"]["first_seen"].endswith("+03:00"))


if __name__ == "__main__":
    unittest.main()
