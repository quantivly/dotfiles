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
        snapshots.write(self.ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "t", "url": "u", "state": {"name": "Todo", "type": "unstarted"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": []}],
            "notifications": []})
        out = tracked_cmd.run_tracked(self.ctx, ["HUB-1", "HUB-2"])
        by_key = {r["key"]: r for r in out["results"]}
        self.assertEqual(by_key["HUB-1"]["status"], "found")
        self.assertEqual(by_key["HUB-2"]["status"], "not_found")

    def test_text_mode_names_status_for_each_key(self):
        lines = tracked_cmd._text_line({"key": "HUB-9", "status": "not_found"})
        self.assertIn("HUB-9", lines)
        self.assertIn("not found", lines)
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
