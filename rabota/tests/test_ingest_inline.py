"""DO-740: the inline (``--stdin``) form of ``rabota ingest``.

Unit-level rows exercise ``run_ingest_inline``/``run_ingest_many`` directly against
``rabota.commands.ingest``, the same way ``tests/test_sync.py`` exercises the file form. CLI-level
rows drive the real subprocess entrypoint (``python3 -m rabota``) with an actual bash heredoc on
stdin, because the hazard the brief calls out — quotes, backticks, ``$``, a literal ``EOF`` line,
newlines, emoji, a 100 KB payload — is a claim about what a *shell* does to those bytes before
Python ever sees them, and ``unittest`` alone (patching ``sys.stdin`` in-process) cannot exercise
shell quoting at all.
"""
import argparse
import json
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from rabota import context, errors, snapshots
from rabota.commands import ingest
from rabota.runner import FakeRunner

FIX = Path(__file__).parent / "fixtures" / "config"
REPO = Path(__file__).parent.parent


class IngestInlineUnitTests(unittest.TestCase):
    def ctx(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(ctx.close)
        return ctx

    # ---- shared validation (claim: same schema, same code, as the file form) --------------------

    def test_inline_writes_and_records_exactly_like_the_file_form(self):
        ctx = self.ctx()
        data = {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi", "from": "benoit"}]}
        rep = ingest.run_ingest_inline(ctx, "slack", data)
        snap = snapshots.read(ctx.state_dir, "slack")
        self.assertEqual(snap["items"][0]["from"], "benoit")
        self.assertEqual((snap["ok"], snap["error"], snap["fetched_at"]), (True, None, "2026-09-16T07:00:00Z"))
        self.assertEqual(rep, {"source": "slack", "ok": True, "error": None, "items": 1,
                                "path": str(ctx.state_dir / "sources" / "slack.json")})
        self.assertTrue(ctx.store.last_sync("quantivly", "slack")["ok"])

    def test_inline_failed_fetch_records_failure_without_raising(self):
        ctx = self.ctx()
        rep = ingest.run_ingest_inline(ctx, "calendar", {"fetched_at": "2026-09-16T07:00:00Z", "ok": False,
                                                          "error": "connector timed out"})
        snap = snapshots.read(ctx.state_dir, "calendar")
        self.assertEqual((snap["ok"], snap["error"], snap["items"]), (False, "connector timed out", []))
        self.assertFalse(rep["ok"])

    def test_inline_ok_must_be_a_json_boolean_same_rule_as_the_file_form(self):
        ctx = self.ctx()
        for bad, typename in (("false", "str"), (1, "int"), (None, "NoneType")):
            with self.assertRaises(errors.Usage, msg=f"ok={bad!r}") as cm:
                ingest.run_ingest_inline(ctx, "slack", {"fetched_at": "2026-09-16T07:00:00Z", "ok": bad, "items": []})
            self.assertIn("'ok'", str(cm.exception)); self.assertIn(typename, str(cm.exception))
        self.assertIsNone(snapshots.read(ctx.state_dir, "slack"))

    def test_inline_missing_fetched_at_or_bad_source_is_usage(self):
        ctx = self.ctx()
        with self.assertRaises(errors.Usage):
            ingest.run_ingest_inline(ctx, "slack", {"ok": True, "items": []})
        with self.assertRaises(errors.Usage):
            ingest.run_ingest_inline(ctx, "linear", {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []})

    def test_fireflies_is_refused_inline_too(self):
        # Same refusal as the file form (DO-746 F4): the inline form must not reopen the hole.
        ctx = self.ctx()
        with self.assertRaises(errors.Usage):
            ingest.run_ingest_inline(ctx, "fireflies", {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []})
        with self.assertRaises(errors.Usage):
            ingest.run_ingest_many(ctx, [("fireflies", {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []})])

    # ---- hazard 2: mixed forms ---------------------------------------------------------------

    def test_run_ingest_many_accepts_a_mix_of_file_and_inline_specs(self):
        ctx = self.ctx(); ctx.state_dir.mkdir(parents=True, exist_ok=True)
        f = ctx.state_dir / "slack-in.json"
        f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi"}]}))
        specs = [("slack", f), ("calendar", {"fetched_at": "2026-09-16T07:00:00Z", "ok": True,
                                              "items": [{"title": "standup"}]})]
        rep = ingest.run_ingest_many(ctx, specs)
        self.assertEqual(set(rep), {"slack", "calendar"})
        self.assertTrue(rep["slack"]["ok"]); self.assertTrue(rep["calendar"]["ok"])
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "slack"))
        self.assertIsNotNone(snapshots.read(ctx.state_dir, "calendar"))

    def test_run_ingest_many_refuses_a_source_named_in_both_forms(self):
        # DO-727 already refuses a duplicate within one form; the inline form must not open a
        # side door where naming a source once per form escapes that refusal.
        ctx = self.ctx(); ctx.state_dir.mkdir(parents=True, exist_ok=True)
        f = ctx.state_dir / "slack-in.json"
        f.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []}))
        specs = [("slack", f), ("slack", {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []})]
        with self.assertRaises(errors.Usage) as cm:
            ingest.run_ingest_many(ctx, specs)
        self.assertIn("slack", str(cm.exception))
        self.assertIsNone(snapshots.read(ctx.state_dir, "slack"))   # refused before anything was written


class IngestInlineCliTests(unittest.TestCase):
    """CLI wiring for ``--stdin``, in-process (``cli.main`` with ``sys.stdin`` patched)."""

    def test_stdin_wiring_writes_both_sources_in_one_call(self):
        from tests.test_cli import run_cli, install_fixture_home
        import io
        from unittest.mock import patch
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        payload = json.dumps({
            "slack": {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi"}]},
            "calendar": {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"title": "standup"}]},
        })
        with patch("sys.stdin", io.StringIO(payload)):
            code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest", "--stdin"])
        self.assertEqual(code, 0, out + err)
        body = json.loads(out)
        self.assertTrue(body["slack"]["ok"]); self.assertTrue(body["calendar"]["ok"])
        self.assertIsNotNone(snapshots.read(state, "slack"))
        self.assertIsNotNone(snapshots.read(state, "calendar"))

    def test_stdin_combines_with_file_form_mixed(self):
        # Hazard 2: --file slack=... plus inline calendar on stdin, in one call.
        from tests.test_cli import run_cli, install_fixture_home
        import io
        from unittest.mock import patch
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        slack = state / "slack-in.json"
        slack.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi"}]}))
        payload = json.dumps({"calendar": {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []}})
        with patch("sys.stdin", io.StringIO(payload)):
            code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest",
                                       "--file", f"slack={slack}", "--stdin"])
        self.assertEqual(code, 0, out + err)
        body = json.loads(out)
        self.assertTrue(body["slack"]["ok"]); self.assertTrue(body["calendar"]["ok"])

    def test_stdin_same_source_on_both_sides_is_refused(self):
        from tests.test_cli import run_cli, install_fixture_home
        import io
        from unittest.mock import patch
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        slack = state / "slack-in.json"
        slack.write_text(json.dumps({"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []}))
        payload = json.dumps({"slack": {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": []}})
        with patch("sys.stdin", io.StringIO(payload)):
            code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest",
                                       "--file", f"slack={slack}", "--stdin"])
        self.assertEqual(code, 2, out + err)
        self.assertIn("slack", out + err)
        self.assertIsNone(snapshots.read(state, "slack"))

    def test_stdin_rejected_with_positional_single_source_form(self):
        from tests.test_cli import run_cli, install_fixture_home
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest",
                                   "slack", "--stdin"])
        self.assertEqual(code, 2, out + err)
        self.assertIn("cannot be combined with the single-source form", out + err)

    def test_stdin_not_an_object_is_usage(self):
        from tests.test_cli import run_cli, install_fixture_home
        import io
        from unittest.mock import patch
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        with patch("sys.stdin", io.StringIO(json.dumps(["not", "an", "object"]))):
            code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest", "--stdin"])
        self.assertEqual(code, 2, out + err)
        self.assertIn("must be an object keyed by source", out + err)

    def test_stdin_invalid_json_is_usage(self):
        from tests.test_cli import run_cli, install_fixture_home
        import io
        from unittest.mock import patch
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        with patch("sys.stdin", io.StringIO("{not json")):
            code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest", "--stdin"])
        self.assertEqual(code, 2, out + err)
        self.assertIn("--stdin: invalid JSON", out + err)

    def test_a_terminal_on_stdin_is_refused_not_read(self):
        # DO-740 review F1: with nothing piped, json.load(sys.stdin) blocked forever on a tty.
        from tests.test_cli import run_cli, install_fixture_home
        import io
        from unittest.mock import patch
        class Tty(io.StringIO):
            def isatty(self): return True
            def read(self, *a): raise AssertionError("a terminal must not be read")
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        with patch("sys.stdin", Tty()):
            code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest", "--stdin"])
        self.assertEqual(code, 2, out + err)
        self.assertIn("nothing is piped in", out + err)

    def test_invalid_utf8_on_stdin_is_refused_like_the_file_form(self):
        # DO-740 review F2: stdin decoded with surrogateescape stored mangled text and exited 0,
        # where the same bytes through --file were refused.
        from tests.test_cli import run_cli, install_fixture_home
        import io
        from unittest.mock import patch
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        raw = b'{"slack": {"fetched_at": "2026-09-16T07:00:00Z", "ok": true, "error": null, "items": [{"text": "\xff\xfe"}]}}'
        with patch("sys.stdin", io.TextIOWrapper(io.BytesIO(raw), encoding="utf-8", errors="surrogateescape")):
            code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "ingest", "--stdin"])
        self.assertEqual(code, 2, out + err)
        self.assertIn("not valid UTF-8", out + err)
        self.assertFalse((state / "sources" / "slack.json").exists())

    def test_dry_run_gates_the_inline_form_too(self):
        # DO-753 (amends the DO-742-era row this replaced, which asserted the opposite -- that
        # `ingest` ignored `--dry-run` and wrote anyway, "explicitly out of scope" at the time).
        # `ingest` is one of DO-753's named commands: --dry-run must now mean nothing is written,
        # and the inline form must inherit that exactly as it inherited the old gap.
        from tests.test_cli import run_cli, install_fixture_home
        import io
        from unittest.mock import patch
        install_fixture_home(self)
        state = self.home / "s"; state.mkdir(parents=True)
        payload = json.dumps({"slack": {"fetched_at": "2026-09-16T07:00:00Z", "ok": True, "items": [{"text": "hi"}]}})
        with patch("sys.stdin", io.StringIO(payload)):
            code, out, err = run_cli(["--tenant", "quantivly", "--state-dir", str(state), "--dry-run",
                                       "ingest", "--stdin"])
        self.assertEqual(code, 0, out + err)
        self.assertIsNone(snapshots.read(state, "slack"))   # nothing written under --dry-run


class IngestInlineRealShellTests(unittest.TestCase):
    """Hazard 1: drive the inline form through an ACTUAL bash heredoc, the way the skill will."""

    def _run_heredoc(self, tmp_home: Path, state: Path, payload_text: str) -> subprocess.CompletedProcess:
        script = (
            f'cd {REPO} && '
            f'HOME={tmp_home} PYTHONPATH={REPO} {shlex.quote(sys.executable)} -m rabota '
            f'--tenant quantivly --state-dir {state} ingest --stdin <<\'RABOTA_EOF\'\n'
            f'{payload_text}\n'
            f'RABOTA_EOF\n'
        )
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name) / "home"
        base = self.home / ".dotfiles-local" / "rabota"
        import shutil
        shutil.copytree(FIX, base)
        self.state = Path(tmp.name) / "s"
        self.state.mkdir(parents=True)

    def test_quotes_backticks_dollar_literal_eof_newlines_and_emoji_survive_byte_for_byte(self):
        text = ("she said \"don't\" then `whoami` costs $HOME and a literal\nEOF\nline, "
                "plus emoji \U0001F600\U0001F680 and 日本語")
        payload = json.dumps({"slack": {"fetched_at": "2026-09-16T07:00:00Z", "ok": True,
                                         "items": [{"text": text}]}})
        proc = self._run_heredoc(self.home, self.state, payload)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        snap = snapshots.read(self.state, "slack")
        self.assertEqual(snap["items"][0]["text"], text)

    def test_100kb_payload_survives(self):
        big_text = "x" * (100 * 1024)
        payload = json.dumps({"slack": {"fetched_at": "2026-09-16T07:00:00Z", "ok": True,
                                         "items": [{"text": big_text}]}})
        proc = self._run_heredoc(self.home, self.state, payload)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        snap = snapshots.read(self.state, "slack")
        self.assertEqual(len(snap["items"][0]["text"]), len(big_text))
        self.assertEqual(snap["items"][0]["text"], big_text)


if __name__ == "__main__":
    unittest.main()
