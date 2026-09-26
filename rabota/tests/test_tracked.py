"""``rabota tracked <key>...`` (DO-751) — the CLI entry point over ``reconcile.lookup_tracked``."""
import argparse
import json
import tempfile
import unittest
from datetime import date
from pathlib import Path

from rabota import context, errors, snapshots
from rabota.commands import tracked as tracked_cmd
from rabota.runner import FakeRunner
from tests.test_cli import install_fixture_home, run_cli

FIX = Path(__file__).parent / "fixtures" / "config"


class FakeLinLookup:
    """DO-754: a ``find_by_identifiers``-only double, same shape as ``tests.test_reconcile_index``'s."""
    def __init__(self, closed=None):
        self.closed = closed or {}
        self.calls: list[list[str]] = []

    def find_by_identifiers(self, identifiers):
        self.calls.append(list(identifiers))
        return [{"identifier": k, **v} for k, v in self.closed.items() if k in identifiers]


def _ctx(tenant="quantivly"):
    tmp = tempfile.TemporaryDirectory()
    ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
    ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"},
                                         cwd=Path("/"), today=date(2026, 9, 16))
    return tmp, ctx


class RunTrackedTests(unittest.TestCase):
    def setUp(self):
        self.tmp, self.ctx = _ctx()
        self.addCleanup(self.tmp.cleanup)

    def test_run_tracked_returns_a_result_per_key(self):
        # DO-754 amendment: HUB-2 now costs a batched Linear check before it is a final
        # `not_found`, so a `lin` double is injected (before DO-754 this row needed none — no
        # such call existed on `main`).
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "t", "url": "u", "state": {"name": "Todo", "type": "unstarted"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": []}],
            "notifications": []})
        lin = FakeLinLookup()
        out = tracked_cmd.run_tracked(self.ctx, ["HUB-1", "HUB-2"], lin=lin)
        by_key = {r["key"]: r for r in out["results"]}
        self.assertEqual(by_key["HUB-1"]["status"], "found")
        self.assertEqual(by_key["HUB-2"]["status"], "not_found")
        self.assertEqual(lin.calls, [["HUB-2"]])

    def test_run_tracked_reports_a_closed_linear_issue_as_found_closed(self):
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [],
                                                        "notifications": []})
        lin = FakeLinLookup({"DO-751": {"state": {"name": "Done", "type": "completed"},
                                        "completedAt": "2026-09-20T00:00:00Z"}})
        out = tracked_cmd.run_tracked(self.ctx, ["DO-751"], lin=lin)
        r = out["results"][0]
        self.assertEqual(r["status"], "found_closed")
        self.assertEqual(r["state"]["name"], "Done")
        self.assertEqual(r["completed_at"], "2026-09-20T00:00:00Z")

    def test_run_tracked_reports_an_unresolvable_check_as_unknown_not_not_found(self):
        # No `lin` injected and the fixture tenant's LINEAR_API_KEY is unset in this test's env
        # (`_ctx` below) -- `LinearClient.from_context` refuses before any request is made, and
        # that refusal must read `unknown`, never the `not_found` that would look like proof HUB-2
        # doesn't exist.
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [],
                                                        "notifications": []})
        out = tracked_cmd.run_tracked(self.ctx, ["HUB-2"])
        r = out["results"][0]
        self.assertEqual(r["status"], "unknown")
        self.assertIn("Linear lookup failed", r["reason"])

    def test_text_mode_names_status_for_each_key(self):
        lines = tracked_cmd._text_line({"key": "HUB-9", "status": "not_found", "kind": "linear"})
        self.assertIn("HUB-9", lines)
        self.assertIn("not found", lines)
        self.assertIn("open issues synced", lines)
        lines = tracked_cmd._text_line({"key": "o/r#9", "status": "not_found", "kind": "github"})
        self.assertIn("own open or recently merged PRs", lines)
        lines = tracked_cmd._text_line({"key": "HUB-9", "status": "found_closed", "kind": "linear",
                                         "state": {"name": "Done", "type": "completed"}, "completed_at": "d"})
        self.assertIn("found closed", lines)
        self.assertIn("Done", lines)
        lines = tracked_cmd._text_line({"key": "HUB-9", "status": "unknown", "reason": "never synced"})
        self.assertIn("never synced", lines)
        lines = tracked_cmd._text_line({"key": "C0A2FRLPA58", "status": "not_applicable"})
        self.assertIn("not applicable", lines)


class TrackedCliTests(unittest.TestCase):
    def setUp(self):
        install_fixture_home(self)

    def test_cli_call_returns_json_results(self):
        state_dir = self.home / "s"
        snapshots.write(state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "t", "url": "u", "state": {"name": "Todo", "type": "unstarted"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": []}],
            "notifications": []})
        code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state_dir), "tracked", "HUB-1"])
        self.assertEqual(code, 0, err)
        data = json.loads(out)
        self.assertEqual(data["results"][0]["status"], "found")

    def test_cli_call_with_no_keys_is_a_usage_error(self):
        with self.assertRaises(SystemExit) as cm:
            run_cli(["--tenant", "quantivly", "--state-dir", str(self.home / "s"), "tracked"])
        self.assertEqual(cm.exception.code, 2)

    def test_text_mode_prints_one_line_per_key(self):
        state_dir = self.home / "s"
        code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state_dir),
                                  "--text", "tracked", "HUB-1", "HUB-2"])
        self.assertEqual(code, 0, err)
        lines = out.strip("\n").split("\n")
        self.assertEqual(len(lines), 2)
