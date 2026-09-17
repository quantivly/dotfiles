import argparse, json, tempfile, unittest
from datetime import date, datetime, timezone
from pathlib import Path
from rabota import cli, context, errors, secrets, snapshots
from rabota.commands import brief
from rabota.runner import FakeRunner

FIX = Path(__file__).parent / "fixtures" / "config"

def seq(keys, generated_at="2026-09-16T08:00:00Z"):
    return {"tenant": "quantivly", "generated_at": generated_at, "failed_sources": [],
            "items": [{"bucket": 1, "key": k, "title": "title " * 20, "waiting_on": "benoit", "why_now": "now", "rationale": "r", "url": "u", "source": "linear"} for k in keys],
            "triage": [], "decisions": []}

class BriefTests(unittest.TestCase):
    def test_caps_at_twelve_lines_including_footer(self):
        lines = brief.terminal_lines(seq([f"K-{i}" for i in range(30)]), "inbox: 3 archived", None)
        self.assertLessEqual(len(lines), 12)
        self.assertTrue(lines[-1].startswith("brief:") or lines[-1].startswith("inbox:"))
        self.assertTrue(all(len(l) <= 120 for l in lines))

    def test_line_format_names_key_title_waiting_and_why(self):
        lines = brief.terminal_lines(seq(["K-1"]), None, None, brief_path="/p/brief.md")
        self.assertTrue(lines[0].startswith("1. K-1 — title title"), lines[0])
        self.assertIn(" · waiting: benoit · now", lines[0])
        self.assertEqual(lines[-1], "brief: /p/brief.md")

    def test_failed_source_gets_one_line(self):
        s = seq(["K-1"]); s["failed_sources"] = ["calendar"]
        lines = brief.terminal_lines(s, None, None)
        self.assertTrue(any(l.startswith("! calendar failed") for l in lines))

    def test_rerun_prints_delta_only(self):
        prev = {"keys": ["K-1", "K-2"], "generated_at": "2026-09-16T07:00:00Z"}
        lines = brief.terminal_lines(seq(["K-2", "K-3"]), None, prev)
        self.assertIn("+ K-3", "\n".join(lines)); self.assertIn("- K-1", "\n".join(lines))
        self.assertFalse(any("K-2" in l and not l.startswith(("+", "-")) for l in lines[:-1]))

    def test_rerun_no_change(self):
        prev = {"keys": ["K-1"], "generated_at": "2026-09-16T07:00:00Z"}
        lines = brief.terminal_lines(seq(["K-1"]), None, prev)
        self.assertTrue(lines[0].startswith("no change since"))

    def test_staleness_line_fires_past_max_age_and_names_the_tenant(self):
        now = datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc)      # 90 minutes after generated_at
        line = brief.staleness_line(seq(["K-1"]), now)
        self.assertEqual(line, "! brief is 90 min old — timer failed? run: rabota --tenant quantivly precompute")
        self.assertIsNone(brief.staleness_line(seq(["K-1"]), datetime(2026, 9, 16, 8, 59, tzinfo=timezone.utc)))
        self.assertIsNotNone(brief.staleness_line(seq(["K-1"]), datetime(2026, 9, 16, 8, 31, tzinfo=timezone.utc), max_age_min=30))

    def test_stale_brief_is_the_first_line_and_counts_toward_the_cap(self):
        now = datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc)
        lines = brief.terminal_lines(seq([f"K-{i}" for i in range(30)]), "inbox: 0", None, now=now)
        self.assertTrue(lines[0].startswith("! brief is 90 min old"))
        self.assertEqual(len(lines), 12)
        prev = {"keys": ["K-1"], "generated_at": "2026-09-16T07:00:00Z"}
        rerun = brief.terminal_lines(seq(["K-1"]), None, prev, now=now)
        self.assertTrue(rerun[0].startswith("! brief is 90 min old")); self.assertTrue(rerun[1].startswith("no change since"))

    def test_max_lines_is_honoured(self):
        lines = brief.terminal_lines(seq([f"K-{i}" for i in range(30)]), "inbox: 0", None, max_lines=11)
        self.assertEqual(len(lines), 11)

    def test_compose_markdown_lists_sources_items_and_inbox(self):
        s = seq(["K-1"]); s["decisions"] = [{"key": "DO-9", "why": "Urgent in Backlog", "url": "u9"}]
        syncs = [{"source": "linear", "ok": 1, "fetched_at": "t", "error": None},
                 {"source": "calendar", "ok": 0, "fetched_at": "t", "error": "timed out"}]
        md = brief.compose_markdown(s, {"totals": {"archived": 3}}, syncs)
        for needle in ("- linear: ok", "- calendar: FAILED at t — timed out", "1. [1] K-1", "DO-9", "- archived: 3"):
            self.assertIn(needle, md)


class BriefCommandTests(unittest.TestCase):
    def ctx(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        return context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([]), env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 9, 16))

    def _write_seq(self, ctx, keys):
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq(keys)))
        return day

    def test_run_brief_writes_brief_md_and_last_brief_and_honours_max_lines(self):
        ctx = self.ctx(); day = self._write_seq(ctx, [f"K-{i}" for i in range(30)])
        now = datetime(2026, 9, 16, 8, 10, tzinfo=timezone.utc)
        lines = brief.run_brief(ctx, text=True, max_lines=11, now=now)
        self.assertLessEqual(len(lines), 11)
        self.assertEqual(lines[-1], f"brief: {day / 'brief.md'}")
        self.assertTrue((day / "brief.md").exists())
        self.assertEqual(json.loads((day / "last-brief.json").read_text())["keys"][:2], ["K-0", "K-1"])
        out = brief.run_brief(ctx, text=False, now=now)
        self.assertEqual(out["brief_path"], str(day / "brief.md"))
        self.assertTrue(out["lines"][0].startswith("no change since 08:00"), out["lines"])

    def test_run_brief_reports_staleness_from_the_clock(self):
        ctx = self.ctx(); self._write_seq(ctx, ["K-1"])
        lines = brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc))
        self.assertTrue(lines[0].startswith("! brief is 90 min old"), lines)

    def test_run_brief_ranks_first_when_no_sequence_exists(self):
        ctx = self.ctx()
        lines = brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 8, 0, tzinfo=timezone.utc))
        self.assertTrue((ctx.state_dir / "2026-09-16" / "sequence.json").exists())
        self.assertTrue(lines[-1].startswith("brief: "))

    def test_registered_value_in_a_sync_error_never_reaches_brief_md(self):
        # k2: gh stderr can echo the minted token; it flows into source_syncs.error and from there
        # into brief.md through a file write that skipped the guard. A secret on disk is worse than
        # one on a terminal, so the write must not happen at all.
        minted = "minted-gho-token-0123456789abcdef"
        secrets.register_value(minted); self.addCleanup(secrets.REGISTERED_VALUES.discard, minted)
        ctx = self.ctx(); day = self._write_seq(ctx, ["K-1"])
        ctx.store.record_sync("quantivly", "github", False, f"gh: HTTP 401 — token {minted} rejected", "")
        with self.assertRaises(errors.SecretLeak) as cm:
            brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 8, 5, tzinfo=timezone.utc))
        self.assertNotIn(minted, str(cm.exception))
        self.assertFalse((day / "brief.md").exists(), "brief.md was written with a protected value in it")
        self.assertFalse((day / "last-brief.json").exists())

    def test_snapshot_write_is_guarded_too(self):
        minted = "minted-gho-token-fedcba9876543210"
        secrets.register_value(minted); self.addCleanup(secrets.REGISTERED_VALUES.discard, minted)
        ctx = self.ctx()
        with self.assertRaises(errors.SecretLeak):
            snapshots.write(ctx.state_dir, "github", {"ok": False, "error": f"gh said {minted}", "items": []})
        self.assertIsNone(snapshots.read(ctx.state_dir, "github"))
        self.assertFalse(list((ctx.state_dir / "sources").glob(".*")) if (ctx.state_dir / "sources").exists() else [])

    def test_cli_exposes_max_lines_with_default_twelve(self):
        ns = cli.build_parser().parse_args(["brief"])
        self.assertEqual(ns.max_lines, 12)
        self.assertEqual(cli.build_parser().parse_args(["brief", "--max-lines", "11"]).max_lines, 11)
