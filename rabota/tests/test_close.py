import argparse, json, tempfile, unittest
from pathlib import Path

from rabota import context, errors, secrets
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

    def test_a_secret_in_evidence_still_raises_even_though_notify_is_on(self):
        """The ``except Exception`` around the herdr call must not reach ``_project``.

        Gate 2 (WS2 2.7, 2026-09-18) found that widening that ``try`` by one line to also wrap
        ``_project`` left the whole suite green — so nothing pinned its scope. A secret in
        ``evidence`` would then be swallowed into ``notified: False`` and the call would report
        success, which is the write guard's entire failure class re-entered through the handler
        that round added. ``notify=True`` and a runner that WOULD succeed are both load-bearing
        here: they are what makes the widened form look healthy.
        """
        value = "sk-test-secret-value-not-real-0000"
        secrets.register_value(value)
        self.addCleanup(secrets.REGISTERED_VALUES.discard, value)
        ctx = self.ctx()                                   # FakeRunner([HERDR_OK]) — the call succeeds
        with self.assertRaises(errors.SecretLeak):
            escalate.run_escalate(ctx, "q", f"token is {value}", ["a"], notify=True)
        self.assertFalse((ctx.state_dir / "escalations.jsonl").exists())
        # F3: the store row from before the leaked projection must not survive either, or `close`
        # would list an escalation that is absent from Sol's jsonl.
        self.assertEqual(ctx.store.open_escalations("quantivly"), [])

    def test_answer_secret_leak_rolls_back_to_unresolved(self):
        """F3, the ``answer`` direction: a leak on the projection must undo the store's resolution.

        Unlike a fresh ``escalate``, the escalation itself may already be visible to a caller (its
        id was already returned), so the rollback is "make it look never-answered" rather than
        deleting it.
        """
        value = "sk-test-secret-value-not-real-0000"
        secrets.register_value(value)
        self.addCleanup(secrets.REGISTERED_VALUES.discard, value)
        ctx = self.ctx()
        eid = escalate.run_escalate(ctx, "q", "e", ["a", "b"], notify=False)["id"]
        with self.assertRaises(errors.SecretLeak):
            escalate.run_answer(ctx, eid, "a", resolution=f"leaked: {value}")
        stored = ctx.store.escalation(eid)
        self.assertIsNone(stored["resolved_at"])
        self.assertIsNone(stored["disposition"])
        # A clean answer afterwards must succeed — the rollback really put it back to "open".
        escalate.run_answer(ctx, eid, "a")
        self.assertEqual(ctx.store.escalation(eid)["disposition"], "a")

    def test_answer_refuses_an_already_resolved_escalation(self):
        """F4: a second ``answer`` on a resolved escalation must not overwrite the first resolution."""
        ctx = self.ctx()
        eid = escalate.run_escalate(ctx, "q", "e", ["a", "b"], notify=False)["id"]
        escalate.run_answer(ctx, eid, "a", resolution="first")
        with self.assertRaises(errors.Refused):
            escalate.run_answer(ctx, eid, "b", resolution="second")
        stored = ctx.store.escalation(eid)
        self.assertEqual(stored["disposition"], "a")
        self.assertEqual(stored["resolution"], "first")
        rows = [json.loads(l) for l in (ctx.state_dir / "escalations.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 2)  # escalate + the one answer that stuck, no second resolution row

    def test_answer_unknown_id_raises_usage(self):
        """Guard-kill row for F6: nothing else in the suite calls ``answer`` on a missing id."""
        ctx = self.ctx()
        with self.assertRaises(errors.Usage):
            escalate.run_answer(ctx, 99, "a")

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
        ctx.store.update_lane("l1", status="started", held_reason=None)
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

    def _jsonl(self, *lines):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        p = Path(tmp.name) / "v1.jsonl"
        p.write_text("\n".join(lines) + "\n")
        return p

    def test_import_v1_is_idempotent_on_rerun(self):
        """F2: re-importing the same file must add nothing — the identity is ``firstSeen``."""
        ctx = self.ctx()
        db.run_import_v1(ctx, FIX / "v1" / "escalations.jsonl")
        rep = db.run_import_v1(ctx, FIX / "v1" / "escalations.jsonl")
        self.assertEqual((rep["imported"], rep["resolved"]), (0, 0))
        self.assertEqual(len(ctx.store.escalations_by_first_seen("quantivly")), 4)

    def test_import_v1_is_atomic_on_a_damaged_file(self):
        """F2: a bad line must not leave the rows before it committed."""
        ctx = self.ctx()
        p = self._jsonl(
            '{"firstSeen": "T1", "question": "A?", "evidence": "a", "disposition": null}',
            "not json",
        )
        with self.assertRaises(errors.Usage):
            db.run_import_v1(ctx, p)
        self.assertEqual(ctx.store.open_escalations("quantivly"), [])

    def test_import_v1_refuses_a_row_with_no_firstseen_or_ts(self):
        """F5: a row that identifies nothing must not silently key on ``None``."""
        ctx = self.ctx()
        p = self._jsonl('{"question": "A?", "evidence": "a", "disposition": null}')
        with self.assertRaises(errors.Usage):
            db.run_import_v1(ctx, p)

    def test_import_v1_refuses_a_row_with_no_question(self):
        """F5: a missing ``question`` must not silently import as ``""``."""
        ctx = self.ctx()
        p = self._jsonl('{"firstSeen": "T1", "evidence": "a", "disposition": null}')
        with self.assertRaises(errors.Usage):
            db.run_import_v1(ctx, p)

    def test_import_v1_refuses_a_duplicate_open_firstseen(self):
        """F5/F6 guard-kill row: a second open row sharing an earlier open row's firstSeen used to
        be dropped uncounted; it must now be refused instead."""
        ctx = self.ctx()
        p = self._jsonl(
            '{"ts": "T1", "firstSeen": "T1", "question": "C?", "evidence": "c", "disposition": null}',
            '{"ts": "T2", "firstSeen": "T1", "question": "D?", "evidence": "d", "disposition": null}',
        )
        with self.assertRaises(errors.Usage):
            db.run_import_v1(ctx, p)

    def test_import_v1_missing_file_is_usage_not_internal_error(self):
        """F9 (low, optional — fixed because it was cheap): a bad --jsonl path is bad input."""
        ctx = self.ctx()
        with self.assertRaises(errors.Usage):
            db.run_import_v1(ctx, ctx.state_dir / "does-not-exist.jsonl")

    def test_import_v1_tolerates_blank_lines(self):
        """F6 guard-kill row: the blank-line skip must still let a real file with blank lines import."""
        ctx = self.ctx()
        p = self._jsonl(
            "",
            '{"ts": "T1", "firstSeen": "T1", "question": "A?", "evidence": "a", "disposition": null}',
            "   ",
        )
        rep = db.run_import_v1(ctx, p)
        self.assertEqual(rep["imported"], 1)


if __name__ == "__main__":
    unittest.main()
