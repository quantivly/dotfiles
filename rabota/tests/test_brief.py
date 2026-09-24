import argparse, io, json, os, shutil, tempfile, unittest, unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from datetime import date, datetime, timezone
from pathlib import Path
from rabota import cli, context, errors, secrets, snapshots
from rabota.commands import brief
from rabota.runner import FakeRunner, Result
from tests.test_preflight import VIEWER, FakeGh, FakeLinear

FIX = Path(__file__).parent / "fixtures" / "config"
SSH_OK = (["ssh-add", "-l"], Result(0, "256 SHA256:abc key (ED25519)\n", ""))

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

    def test_blank_title_is_left_out_not_printed_as_a_dangling_dash(self):
        # DO-715 F6: a bare Linear URL with no title rendered as "1. <key> —  · waiting: ...",
        # a dash with nothing after it. A reader should see only what the source actually has.
        s = seq(["K-1"]); s["items"][0]["title"] = ""
        line = brief.terminal_lines(s, None, None)[0]
        self.assertEqual(line, "1. K-1 · waiting: benoit · now")
        self.assertNotIn(" — ", line)

    def test_truncation_cuts_why_now_never_the_key_or_title(self):
        # DO-715 F6: the old `[:LINE_MAX]` slice could land mid-word inside the trailing prose,
        # e.g. "... — CORE-50" — the last thing a reader sees should never be a severed word.
        s = seq(["K-1"])
        s["items"][0]["title"] = "a short, real title"
        s["items"][0]["why_now"] = "a very long reason that goes on and on and mentions CORE-500 " * 3
        line = brief.terminal_lines(s, None, None)[0]
        self.assertLessEqual(len(line), 120)
        self.assertTrue(line.startswith("1. K-1 — a short, real title · waiting: benoit · "), line)
        self.assertTrue(line.endswith("…"), line)
        self.assertFalse(line[:-1].endswith(" "))
        # cut at a word boundary: the last word standing must be whole, e.g. "CORE-500" or "very",
        # never a fragment like "CORE-5" that a whole-word source string never contained.
        cut_word = line[:-1].rsplit(" ", 1)[-1]
        self.assertIn(cut_word, s["items"][0]["why_now"].split())

    def test_an_over_long_identifier_is_cut_with_an_ellipsis_never_sliced_silently(self):
        # Review finding: the old trailing `[:LINE_MAX]` fired whenever `N. KEY — title` alone
        # overran, severing the identifier with no marker — while the docstring said the key was
        # "never sliced". A cut that the reader cannot see is the untruth; the cut itself is fine.
        s = seq(["K" * 150]); s["items"][0]["title"] = ""; s["items"][0]["why_now"] = ""
        line = brief.terminal_lines(s, None, None)[0]
        self.assertEqual(len(line), 120)
        self.assertTrue(line.endswith("…"), line)

    def test_waiting_is_dropped_before_the_identifier_when_the_line_is_over_budget(self):
        # A bare-URL key — the fallback this change introduces — plus `waiting:` overruns on its
        # own, with no why_now left to cut. The identifier is what the line exists to carry, so
        # `waiting` goes first and the url survives whole.
        url = "https://github.com/quantivly/some-really-long-repository-name/pull/123456/files#discussion_r1234567890123"
        s = seq([url]); s["items"][0]["title"] = ""; s["items"][0]["why_now"] = "mentions you"
        line = brief.terminal_lines(s, None, None)[0]
        self.assertLessEqual(len(line), 120)
        self.assertEqual(line, f"1. {url}")
        self.assertNotIn("waiting:", line)

    def test_a_whitespace_only_why_now_is_blank_not_a_dangling_separator(self):
        # `title` was stripped before the emptiness check and `why_now` was not, so a whitespace
        # why_now survived as truthy and collapsed under truncation to "· …" carrying nothing.
        s = seq(["K-1"]); s["items"][0]["title"] = "t"; s["items"][0]["why_now"] = " " * 200
        line = brief.terminal_lines(s, None, None)[0]
        self.assertEqual(line, "1. K-1 — t · waiting: benoit")

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

    def test_no_change_path_honours_the_cap(self):
        # k4: the no-change return was never sliced, so --max-lines 1 still printed two lines.
        prev = {"keys": ["K-1"], "generated_at": "2026-09-16T07:00:00Z"}
        s = seq(["K-1"]); s["failed_sources"] = ["calendar"]
        stale = datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc)
        for m in (1, 2):
            lines = brief.terminal_lines(s, "inbox: 0", prev, max_lines=m, brief_path="/p/brief.md", now=stale)
            self.assertEqual(len(lines), m, lines)
        self.assertTrue(brief.terminal_lines(s, None, prev, max_lines=1, now=stale)[0].startswith("! brief is"))
        self.assertTrue(brief.terminal_lines(s, None, prev, max_lines=1)[0].startswith("no change since"))

    def test_zero_or_negative_max_lines_is_usage(self):
        # A zero-line brief is not a brief: 0 is a usage error, as is any negative cap, on every path.
        prev = {"keys": ["K-1"], "generated_at": "2026-09-16T07:00:00Z"}
        for m in (0, -1, -12):
            for previous in (None, prev):
                with self.assertRaises(errors.Usage, msg=f"max_lines={m} previous={previous is not None}") as cm:
                    brief.terminal_lines(seq(["K-1"]), None, previous, max_lines=m)
                self.assertIn("max-lines", str(cm.exception))

    def test_malformed_generated_at_is_usage_not_a_traceback(self):
        for bad in ("yesterday-ish", "2026-09-16 08:00:00", "", None):
            s = seq(["K-1"], generated_at=bad)
            with self.assertRaises(errors.Usage, msg=repr(bad)) as cm:
                brief.staleness_line(s, datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc))
            self.assertIn("generated_at", str(cm.exception))
            with self.assertRaises(errors.Usage, msg=repr(bad)):
                brief.terminal_lines(s, None, None, now=datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc))
        with self.assertRaises(errors.Usage):
            brief.staleness_line({"tenant": "quantivly", "items": []}, datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc))

    def test_compose_markdown_lists_sources_items_and_inbox(self):
        s = seq(["K-1"]); s["decisions"] = [{"key": "DO-9", "why": "Urgent in Backlog", "url": "u9"}]
        syncs = [{"source": "linear", "ok": 1, "fetched_at": "t", "error": None},
                 {"source": "calendar", "ok": 0, "fetched_at": "t", "error": "timed out"}]
        md = brief.compose_markdown(s, {"totals": {"archived": 3}}, syncs)
        for needle in ("- linear: ok", "- calendar: FAILED at t — timed out", "1. [1] K-1", "DO-9", "- archived: 3"):
            self.assertIn(needle, md)


class BriefCommandTests(unittest.TestCase):
    def ctx(self):
        # `brief` now runs preflight first (DO-716 move 1): the quantivly fixture pins gh_login
        # "work-login" and linear_viewer VIEWER, so a passing preflight needs fakes matching both,
        # plus the ssh-add response preflight's own agent check makes on every call.
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([SSH_OK]), env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 9, 16))
        self.addCleanup(ctx.close)
        self.gh, self.lin = FakeGh("work-login"), FakeLinear(VIEWER)
        return ctx

    def _write_seq(self, ctx, keys):
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq(keys)))
        return day

    def test_run_brief_writes_brief_md_and_last_brief_and_honours_max_lines(self):
        ctx = self.ctx(); day = self._write_seq(ctx, [f"K-{i}" for i in range(30)])
        now = datetime(2026, 9, 16, 8, 10, tzinfo=timezone.utc)
        lines = brief.run_brief(ctx, text=True, max_lines=11, now=now, gh=self.gh, lin=self.lin)
        self.assertLessEqual(len(lines), 11)
        self.assertEqual(lines[-1], f"brief: {day / 'brief.md'}")
        self.assertTrue((day / "brief.md").exists())
        self.assertEqual(json.loads((day / "last-brief.json").read_text())["keys"][:2], ["K-0", "K-1"])
        out = brief.run_brief(ctx, text=False, now=now, gh=self.gh, lin=self.lin)
        self.assertEqual(out["brief_path"], str(day / "brief.md"))
        self.assertTrue(out["lines"][0].startswith("no change since 08:00"), out["lines"])

    def test_run_brief_reports_staleness_from_the_clock(self):
        ctx = self.ctx(); self._write_seq(ctx, ["K-1"])
        lines = brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc), gh=self.gh, lin=self.lin)
        self.assertTrue(lines[0].startswith("! brief is 90 min old"), lines)

    def test_run_brief_ranks_first_when_no_sequence_exists(self):
        ctx = self.ctx()
        lines = brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 8, 0, tzinfo=timezone.utc), gh=self.gh, lin=self.lin)
        self.assertTrue((ctx.state_dir / "2026-09-16" / "sequence.json").exists())
        self.assertTrue(lines[-1].startswith("brief: "))

    def test_registered_value_in_the_sequence_never_reaches_brief_md(self):
        # k2: a protected value in the ranked data used to reach brief.md through a file write that
        # skipped the guard. A secret on disk is worse than one on a terminal, so the write must not
        # happen at all. The carrier is a sequence.json written outside rabota (an older rabota, a
        # hand edit): the sync-error route this test first used is now redacted at the store, below.
        minted = "minted-gho-token-0123456789abcdef"
        secrets.register_value(minted); self.addCleanup(secrets.REGISTERED_VALUES.discard, minted)
        ctx = self.ctx(); day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        s = seq(["K-1"]); s["items"][0]["title"] = f"gh said: token {minted} rejected"
        (day / "sequence.json").write_text(json.dumps(s))
        with self.assertRaises(errors.SecretLeak) as cm:
            brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 8, 5, tzinfo=timezone.utc), gh=self.gh, lin=self.lin)
        self.assertNotIn(minted, str(cm.exception))
        self.assertFalse((day / "brief.md").exists(), "brief.md was written with a protected value in it")
        self.assertFalse((day / "last-brief.json").exists())

    def test_sync_error_carrying_a_registered_value_reaches_brief_as_a_marker(self):
        # The store route (k2, second round): the row keeps its shape, so brief still says the
        # source failed, and what it prints and writes carries the marker and never the value.
        minted = "minted-gho-token-0123456789abcdef"
        secrets.register_value(minted); self.addCleanup(secrets.REGISTERED_VALUES.discard, minted)
        ctx = self.ctx(); day = self._write_seq(ctx, ["K-1"])
        ctx.store.record_sync("quantivly", "github", False, f"gh: HTTP 401 — token {minted} rejected", "")
        lines = brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 8, 5, tzinfo=timezone.utc), gh=self.gh, lin=self.lin)
        text = "\n".join(lines) + (day / "brief.md").read_text()
        self.assertNotIn(minted, text)
        self.assertIn("token [redacted:minted-token] rejected", text)

    def test_snapshot_write_is_guarded_too(self):
        minted = "minted-gho-token-fedcba9876543210"
        secrets.register_value(minted); self.addCleanup(secrets.REGISTERED_VALUES.discard, minted)
        ctx = self.ctx()
        with self.assertRaises(errors.SecretLeak):
            snapshots.write(ctx.state_dir, "github", {"ok": False, "error": f"gh said {minted}", "items": []})
        self.assertIsNone(snapshots.read(ctx.state_dir, "github"))
        self.assertFalse(list((ctx.state_dir / "sources").glob(".*")) if (ctx.state_dir / "sources").exists() else [])

    def _main(self, argv, home):
        env = dict(os.environ); env["HOME"] = str(home)
        out, err = io.StringIO(), io.StringIO()
        with unittest.mock.patch.dict(os.environ, env, clear=True), redirect_stdout(out), redirect_stderr(err):
            code = cli.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_cli_refuses_max_lines_zero_and_negative_and_a_malformed_generated_at(self):
        # k4 at the CLI: exit 2 with a usage error, never 5 with an unhandled ValueError.
        # Preflight (DO-716 move 1) is stubbed ok: this test is about --max-lines/generated_at
        # usage errors, not identity pinning, which test_command_records_a_run_row_and_refuses_on_failure
        # and test_brief_exit_3_on_failed_preflight already cover against real client fakes.
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        home = Path(tmp.name) / "home"; shutil.copytree(FIX, home / ".dotfiles-local" / "rabota")
        state = Path(tmp.name) / "state"
        base = ["--tenant", "quantivly", "--state-dir", str(state), "--text", "brief"]
        with unittest.mock.patch("rabota.commands.preflight.run_command",
                                 return_value={"ok": True, "failures": []}):
            for extra in (["--max-lines", "0"], ["--max-lines", "-1"]):
                code, out, err = self._main(base + extra, home)
                self.assertEqual(code, 2, err); self.assertEqual(out, "")
                self.assertEqual(json.loads(err)["error"]["code"], "usage")
                self.assertIn("max-lines", json.loads(err)["error"]["message"])
            self.assertFalse(list(state.glob("*/brief.md")), "a usage error must not leave a brief.md behind")
            code, out, err = self._main(base + ["--max-lines", "1"], home)                  # first run ranks
            self.assertEqual((code, len(out.splitlines())), (0, 1), (out, err))
            code, out, err = self._main(base + ["--max-lines", "1"], home)                  # no-change path, still capped
            self.assertEqual((code, len(out.splitlines())), (0, 1), (out, err))
            day = state / date.today().isoformat()
            seq_doc = json.loads((day / "sequence.json").read_text()); seq_doc["generated_at"] = "yesterday-ish"
            (day / "sequence.json").write_text(json.dumps(seq_doc))
            code, out, err = self._main(base, home)
            self.assertEqual(code, 2, err)
            self.assertEqual(json.loads(err)["error"]["code"], "usage"); self.assertIn("generated_at", err)

    def test_brief_exit_3_on_failed_preflight_before_anything_is_written(self):
        # Move 1's core claim: a failed identity pin exits 3, exactly as `rabota preflight` does
        # today, and nothing past preflight runs — no sequence.json, no brief.md.
        ctx = self.ctx()
        with self.assertRaises(errors.Refused) as cm:
            brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 8, 0, tzinfo=timezone.utc),
                            gh=FakeGh("someone-else"), lin=self.lin)
        self.assertIn("gh identity", str(cm.exception))
        day = ctx.state_dir / "2026-09-16"
        self.assertFalse((day / "sequence.json").exists())
        self.assertFalse((day / "brief.md").exists())
        runs = ctx.store._rows("SELECT * FROM runs")
        self.assertEqual((len(runs), runs[0]["mode"], runs[0]["preflight_ok"]), (1, "preflight", 0))

    def test_cli_exposes_max_lines_with_default_twelve(self):
        ns = cli.build_parser().parse_args(["brief"])
        self.assertEqual(ns.max_lines, 12)
        self.assertEqual(cli.build_parser().parse_args(["brief", "--max-lines", "11"]).max_lines, 11)


class BriefNeedsTests(unittest.TestCase):
    """DO-716 move 2: a stale/missing slack, calendar or fireflies snapshot produces `needs`."""

    def ctx(self, tenant="quantivly"):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([SSH_OK]), env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 9, 16))
        self.addCleanup(ctx.close)
        return ctx

    NOW = datetime(2026, 9, 16, 9, 0, tzinfo=timezone.utc)   # 2026-09-16T09:00:00Z

    def test_never_fetched_source_is_needs_with_never_fetched_reason(self):
        ctx = self.ctx()
        needs = brief.compute_needs(ctx, self.NOW)
        by_source = {n["source"]: n for n in needs}
        self.assertEqual(set(by_source), {"slack", "calendar", "fireflies"})
        self.assertEqual(by_source["slack"]["reason"], "never fetched")
        self.assertEqual(by_source["slack"]["query"], "to:me")
        self.assertEqual(by_source["calendar"]["query"], "free blocks for today")
        self.assertEqual(by_source["fireflies"]["query"], "action items")
        self.assertEqual(by_source["slack"]["write_to"], str(ctx.state_dir / "ingest-slack.json"))

    def test_fresh_snapshot_is_not_in_needs(self):
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "slack", {"ok": True, "items": [], "fetched_at": "2026-09-16T08:30:00Z"})
        needs = brief.compute_needs(ctx, self.NOW)
        self.assertNotIn("slack", {n["source"] for n in needs})

    def test_stale_snapshot_is_needs_with_stale_reason_and_age_and_delta_query(self):
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "slack", {"ok": True, "items": [], "fetched_at": "2026-09-16T07:00:00Z"})
        snapshots.write(ctx.state_dir, "fireflies", {"ok": True, "items": [], "fetched_at": "2026-09-16T07:00:00Z"})
        needs = brief.compute_needs(ctx, self.NOW)
        by_source = {n["source"]: n for n in needs}
        self.assertEqual(by_source["slack"]["reason"], "stale (120 min old)")
        self.assertEqual(by_source["slack"]["query"], "to:me after:2026-09-16")
        self.assertEqual(by_source["fireflies"]["query"], "action items since 2026-09-16T07:00:00Z")

    def test_exactly_at_the_boundary_is_not_stale(self):
        # STALE_AFTER_MIN is 60: a snapshot exactly that old is not yet stale, matching
        # staleness_line's own `age_min <= max_age_min` rule for the brief itself.
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "slack", {"ok": True, "items": [], "fetched_at": "2026-09-16T08:00:00Z"})
        self.assertNotIn("slack", {n["source"] for n in brief.compute_needs(ctx, self.NOW)})
        snapshots.write(ctx.state_dir, "slack", {"ok": True, "items": [], "fetched_at": "2026-09-16T07:59:59Z"})
        self.assertIn("slack", {n["source"] for n in brief.compute_needs(ctx, self.NOW)})

    def test_a_source_the_tenant_does_not_use_is_never_requested(self):
        # toysim only lists `sources = ["github"]` (see tests/fixtures/config/tenants/toysim.toml):
        # a tenant without Fireflies must never be told to fetch it, mirroring preflight's rule
        # for a source the tenant does not list.
        ctx = self.ctx("toysim")
        self.assertEqual(brief.compute_needs(ctx, self.NOW), [])

    def test_malformed_fetched_at_is_usage_not_a_traceback(self):
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "calendar", {"ok": True, "items": [], "fetched_at": "not-a-timestamp"})
        with self.assertRaises(errors.Usage) as cm:
            brief.compute_needs(ctx, self.NOW)
        self.assertIn("fetched_at", str(cm.exception))

    def test_run_brief_carries_needs_in_json_and_as_bang_lines_in_text(self):
        # Two fresh contexts (not two calls on one): a second same-day call hits the no-change
        # rerun path, which — like `failed_sources` today — keeps only the last footer line.
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx()
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq(["K-1"])))
        out = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertEqual({n["source"] for n in out["needs"]}, {"slack", "calendar", "fireflies"})
        for n in out["needs"]:
            self.assertEqual(set(n), {"source", "reason", "query", "write_to"})
        ctx2 = self.ctx()
        day2 = ctx2.state_dir / "2026-09-16"; day2.mkdir(parents=True, exist_ok=True)
        (day2 / "sequence.json").write_text(json.dumps(seq(["K-1"])))
        lines = brief.run_brief(ctx2, text=True, now=self.NOW, gh=gh, lin=lin)
        for source in ("slack", "calendar", "fireflies"):
            self.assertTrue(any(l.startswith(f"! {source} needs a fetch —") for l in lines), lines)

    def test_needs_does_not_replace_the_brief_or_change_the_exit_code(self):
        # The strong recommendation in DO-716: `needs` accompanies the brief, never replaces it,
        # and is not itself a failure — same exit code (0) as a brief with no needs at all.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq(["K-1"])))
        out = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertTrue(out["needs"])
        self.assertTrue((day / "brief.md").exists())
        self.assertTrue(any(l.startswith("1. K-1") for l in out["lines"]))

    def test_needs_line_budget_counts_toward_max_lines(self):
        s = seq([f"K-{i}" for i in range(30)])
        needs = [{"source": "slack", "reason": "never fetched", "query": "to:me", "write_to": "/p"}]
        lines = brief.terminal_lines(s, None, None, max_lines=12, brief_path="/p/brief.md", needs=needs)
        self.assertEqual(len(lines), 12)
        self.assertTrue(any(l.startswith("! slack needs a fetch —") for l in lines))
