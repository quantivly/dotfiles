import argparse, io, json, os, shutil, tempfile, unittest, unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from datetime import date, datetime, timezone
from pathlib import Path
from rabota import cli, context, errors, secrets, snapshots
from rabota.commands import brief
from rabota.commands import rank as rank_cmd
from rabota.runner import FakeRunner, Result
from tests.test_preflight import VIEWER, FakeGh, FakeLinear

FIX = Path(__file__).parent / "fixtures" / "config"
SSH_OK = (["ssh-add", "-l"], Result(0, "256 SHA256:abc key (ED25519)\n", ""))

def seq(keys, generated_at="2026-09-16T08:00:00Z"):
    return {"tenant": "quantivly", "generated_at": generated_at, "failed_sources": [],
            "items": [{"bucket": 1, "key": k, "title": "title " * 20, "waiting_on": "benoit", "why_now": "now", "rationale": "r", "url": "u", "source": "linear"} for k in keys],
            "triage": [], "decisions": []}

def seq_for(ctx, keys, generated_at="2026-09-16T08:00:00Z"):
    """``seq()`` stamped with ``ctx``'s CURRENT inputs signature (DO-738), so writing this fixture
    to disk does not itself read as "an input moved" the moment ``run_brief`` checks it. Call this
    AFTER every snapshot/pin/plan the test means to have in place before ``run_brief`` runs — the
    ones after this call are exactly what the test means to have moved.
    """
    s = seq(keys, generated_at)
    s["inputs"] = rank_cmd.inputs_signature(ctx)
    return s

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
    def ctx(self, dry_run=False):
        # `brief` now runs preflight first (DO-716 move 1): the quantivly fixture pins gh_login
        # "work-login" and linear_viewer VIEWER, so a passing preflight needs fakes matching both,
        # plus the ssh-add response preflight's own agent check makes on every call.
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=dry_run)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([SSH_OK]), env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 9, 16))
        self.addCleanup(ctx.close)
        self.gh, self.lin = FakeGh("work-login"), FakeLinear(VIEWER)
        return ctx

    def _write_seq(self, ctx, keys):
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq_for(ctx, keys)))
        return day

    def test_run_brief_writes_brief_md_and_last_brief_and_honours_max_lines(self):
        ctx = self.ctx()
        now = datetime(2026, 9, 16, 8, 10, tzinfo=timezone.utc)
        # Fresh connector snapshots so `needs` is empty: `last-brief.json` records what the reader
        # was SHOWN, and with `needs` non-empty a JSON caller prints nothing (see
        # test_a_brief_that_printed_nothing_does_not_record_itself_as_shown).
        # Review finding, recorded so nobody mistakes this row for coverage: adding that
        # precondition makes this row pass identically against the pre-#240 unconditional write, so
        # it does NOT exercise the guard. The two rows named above are what do.
        #
        # Written BEFORE the sequence fixture (DO-738): `slack` is one of `rank`'s own inputs (not
        # just a `needs` source), so writing it after would itself look like a moved input and
        # trigger a real re-rank, which is a different test (see BriefRerankTests).
        for source in brief.NEEDS_SOURCES:
            snapshots.write(ctx.state_dir, source, {"ok": True, "error": None, "items": [],
                                                    "fetched_at": "2026-09-16T08:05:00Z"})
        day = self._write_seq(ctx, [f"K-{i}" for i in range(30)])
        lines = brief.run_brief(ctx, text=True, max_lines=11, now=now, gh=self.gh, lin=self.lin)
        self.assertLessEqual(len(lines), 11)
        self.assertEqual(lines[-1], f"brief: {day / 'brief.md'}")
        self.assertTrue((day / "brief.md").exists())
        self.assertEqual(json.loads((day / "last-brief.json").read_text())["keys"][:2], ["K-0", "K-1"])
        out = brief.run_brief(ctx, text=False, now=now, gh=self.gh, lin=self.lin)
        self.assertEqual(out["brief_path"], str(day / "brief.md"))
        self.assertTrue(out["lines"][0].startswith("no change since 08:00"), out["lines"])

    def test_run_brief_json_mode_carries_the_tracked_index_text_mode_does_not(self):
        # DO-716 move 4: the tracked-side index rides in the same JSON reply as `needs` -- turn 1's
        # only call -- so reconcile never has to open sources/linear.json or sources/github.json
        # itself. `--text` (human/terminal) has no line shape for it and does not build it at all.
        ctx = self.ctx(); self._write_seq(ctx, ["K-1"])
        snapshots.write(ctx.state_dir, "linear", {"ok": True, "error": None, "viewer": {}, "issues": [
            {"identifier": "HUB-1", "title": "t", "url": "u", "state": {"name": "Todo", "type": "unstarted"},
             "priorityLabel": "P2", "dueDate": None, "updatedAt": "t", "blockedBy": [], "blocks": []}],
            "notifications": []})
        now = datetime(2026, 9, 16, 8, 10, tzinfo=timezone.utc)
        out = brief.run_brief(ctx, text=False, now=now, gh=self.gh, lin=self.lin)
        self.assertEqual(out["tracked"]["linear"]["issues"][0]["key"], "HUB-1")
        self.assertTrue(out["tracked"]["github"]["ok"] is False)  # never synced in this test
        lines = brief.run_brief(ctx, text=True, now=now, gh=self.gh, lin=self.lin)
        self.assertIsInstance(lines, list)   # no dict, no "tracked" key reachable at all in --text mode

    def test_run_brief_reports_staleness_from_the_clock(self):
        ctx = self.ctx(); self._write_seq(ctx, ["K-1"])
        lines = brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc), gh=self.gh, lin=self.lin)
        self.assertTrue(lines[0].startswith("! brief is 90 min old"), lines)

    def test_run_brief_ranks_first_when_no_sequence_exists(self):
        ctx = self.ctx()
        lines = brief.run_brief(ctx, text=True, now=datetime(2026, 9, 16, 8, 0, tzinfo=timezone.utc), gh=self.gh, lin=self.lin)
        self.assertTrue((ctx.state_dir / "2026-09-16" / "sequence.json").exists())
        self.assertTrue(lines[-1].startswith("brief: "))

    def test_dry_run_writes_nothing_when_no_sequence_exists_yet(self):
        # DO-742: the sequence has to be computed to print the same lines a real run would, but
        # it must not be persisted -- this is the branch that used to call the writing `run_rank`
        # unconditionally. Reverting the `elif ctx.dry_run: ... compute_sequence` branch back to
        # always calling `run_rank(ctx)` makes this row fail: sequence.json exists afterwards.
        ctx = self.ctx(dry_run=True)
        now = datetime(2026, 9, 16, 8, 0, tzinfo=timezone.utc)
        lines = brief.run_brief(ctx, text=True, now=now, gh=self.gh, lin=self.lin)
        day = ctx.state_dir / "2026-09-16"
        self.assertFalse((day / "sequence.json").exists())
        self.assertFalse((day / "brief.md").exists())
        self.assertTrue(any(l.startswith("dry-run: nothing written") for l in lines), lines)

    def test_dry_run_writes_nothing_when_a_sequence_already_exists(self):
        ctx = self.ctx(dry_run=True); day = self._write_seq(ctx, ["K-1"])
        now = datetime(2026, 9, 16, 8, 10, tzinfo=timezone.utc)
        lines = brief.run_brief(ctx, text=True, now=now, gh=self.gh, lin=self.lin)
        self.assertFalse((day / "brief.md").exists())
        self.assertFalse((day / "last-brief.json").exists())
        self.assertTrue(any(l.startswith("dry-run: nothing written") for l in lines), lines)
        # The ranked item is still shown -- a dry run that prints nothing is useless, not safe.
        self.assertTrue(any(l.startswith("1. K-1") for l in lines), lines)

    def test_dry_run_json_mode_reports_no_brief_path_but_still_computes_needs_and_tracked(self):
        ctx = self.ctx(dry_run=True); self._write_seq(ctx, ["K-1"])
        now = datetime(2026, 9, 16, 8, 10, tzinfo=timezone.utc)
        out = brief.run_brief(ctx, text=False, now=now, gh=self.gh, lin=self.lin)
        self.assertIsNone(out["brief_path"])
        self.assertTrue(any(l.startswith("1. K-1") for l in out["lines"]), out["lines"])
        self.assertTrue(any(n["source"] == "slack" for n in out["needs"]))  # never ingested in this test

    def test_dry_run_does_not_change_what_the_next_real_run_prints(self):
        # The bug this issue exists to fix: a dry run wrote last-brief.json, so the FOLLOWING real
        # run saw a same-day rerun and printed a delta (or "no change") instead of the ranked list.
        ctx = self.ctx(dry_run=True); day = self._write_seq(ctx, ["K-1"])
        now = datetime(2026, 9, 16, 8, 10, tzinfo=timezone.utc)
        brief.run_brief(ctx, text=True, now=now, gh=self.gh, lin=self.lin)
        ctx.dry_run = False
        lines = brief.run_brief(ctx, text=True, now=now, gh=self.gh, lin=self.lin)
        self.assertTrue(any(l.startswith("1. K-1") for l in lines), lines)
        self.assertFalse(any(l.startswith("no change since") for l in lines), lines)

    def test_registered_value_in_the_sequence_never_reaches_brief_md(self):
        # k2: a protected value in the ranked data used to reach brief.md through a file write that
        # skipped the guard. A secret on disk is worse than one on a terminal, so the write must not
        # happen at all. The carrier is a sequence.json written outside rabota (an older rabota, a
        # hand edit): the sync-error route this test first used is now redacted at the store, below.
        minted = "minted-gho-token-0123456789abcdef"
        secrets.register_value(minted); self.addCleanup(secrets.REGISTERED_VALUES.discard, minted)
        ctx = self.ctx(); day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        s = seq_for(ctx, ["K-1"]); s["items"][0]["title"] = f"gh said: token {minted} rejected"
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
    """DO-716 move 2: a stale/missing slack or calendar snapshot produces `needs`
    (fireflies moved to sync.FETCHED_SOURCES in DO-746 and no longer appears here)."""

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
        self.assertEqual(set(by_source), {"slack", "calendar"})
        self.assertEqual(by_source["slack"]["reason"], "never fetched")
        self.assertEqual(by_source["slack"]["query"], "to:me")
        self.assertEqual(by_source["calendar"]["query"], "free blocks for today")
        self.assertEqual(by_source["slack"]["write_to"], str(ctx.state_dir / "ingest-slack.json"))

    def test_fresh_snapshot_is_not_in_needs(self):
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "slack", {"ok": True, "items": [], "fetched_at": "2026-09-16T08:30:00Z"})
        needs = brief.compute_needs(ctx, self.NOW)
        self.assertNotIn("slack", {n["source"] for n in needs})

    def test_stale_snapshot_is_needs_with_stale_reason_and_age_and_delta_query(self):
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "slack", {"ok": True, "items": [], "fetched_at": "2026-09-16T07:00:00Z"})
        needs = brief.compute_needs(ctx, self.NOW)
        by_source = {n["source"]: n for n in needs}
        self.assertEqual(by_source["slack"]["reason"], "stale (120 min old)")
        self.assertEqual(by_source["slack"]["query"], "to:me after:2026-09-16")

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
        # a tenant without Slack or Calendar must never be told to fetch either, mirroring
        # preflight's rule for a source the tenant does not list.
        ctx = self.ctx("toysim")
        self.assertEqual(brief.compute_needs(ctx, self.NOW), [])

    def test_a_brief_that_printed_nothing_does_not_record_itself_as_shown(self):
        """Measured regression, found by timing a real `/rabota brief` (2026-09-25): with `needs`
        non-empty the caller prints nothing, fetches, and calls `brief` again -- but turn 1 had
        already written `last-brief.json`, so the second call was a same-day rerun and the only
        screen the reader got was `no change since HH:MM` with **no ranked items at all**. The
        record is of what was SHOWN, so it is written only when these lines were the screen."""
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        # needs non-empty (nothing fetched yet) -> nothing shown -> nothing recorded
        first = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertTrue(first["needs"])
        last = ctx.state_dir / "2026-09-16" / "last-brief.json"
        self.assertFalse(last.exists(), "recorded a brief the caller was told not to print")
        # the follow-up call must therefore still be a first-run: ranked lines, not a delta
        second = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertFalse(any(l.startswith("no change since") for l in second["lines"]), second["lines"])
        # and once nothing is stale, the record IS written, so a genuine rerun still shows a delta
        for source in brief.NEEDS_SOURCES:
            snapshots.write(ctx.state_dir, source, {"ok": True, "error": None, "items": [],
                                                    "fetched_at": "2026-09-16T08:55:00Z"})
        third = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertEqual(third["needs"], [])
        self.assertTrue(last.exists(), "a brief that WAS the screen must be recorded")
        fourth = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertTrue(any(l.startswith("no change since") for l in fourth["lines"]), fourth["lines"])

    def test_a_printed_text_brief_is_recorded_even_while_a_connector_stays_broken(self):
        """Review finding on #240: gating the record on `needs` alone was the mirror image of the bug
        it fixed. A connector with no session support -- `calendar` has had none since 2026-09-23 --
        keeps `needs` non-empty forever, so the `--text` screen the cycle calls
        "the only screen `/rabota brief` prints on a stale morning" was never recorded, and every
        later call that day re-ran the whole two-round-trip cycle instead of settling to a delta."""
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        # slack fetched fine; calendar stays a recorded failure, as it is in the live tenant
        snapshots.write(ctx.state_dir, "slack", {"ok": True, "error": None, "items": [],
                                                 "fetched_at": "2026-09-16T08:55:00Z"})
        snapshots.write(ctx.state_dir, "calendar", {"ok": False, "error": "no connector", "items": [],
                                                     "fetched_at": "2026-09-16T08:55:00Z"})
        last = ctx.state_dir / "2026-09-16" / "last-brief.json"
        # turn 1 (JSON, needs non-empty because calendar failed): prints nothing, records nothing
        first = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertTrue(first["needs"])
        self.assertFalse(last.exists())
        # turn 2's final call (--text): IS printed, so it must be recorded even though needs stands
        lines = brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin)
        self.assertFalse(any(l.startswith("no change since") for l in lines), lines)
        self.assertTrue(last.exists(), "the screen that was shown went unrecorded")
        # so a later call the same day settles to a delta instead of re-running the cycle
        again = brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin)
        self.assertTrue(any(l.startswith("no change since") for l in again), again)

    def test_the_dry_run_notice_cannot_be_cut_by_max_lines(self):
        """Review finding: the notice was appended to `head` AFTER the staleness warning, and
        `_assemble` slices `head[:budget]` in order -- so at `--max-lines 1` with a stale sequence it
        was dropped, and the one surviving line read exactly like a real run's. Of the two, this is
        the one that must survive: a reader who cannot tell a dry run from a real one may act on it,
        while the staleness warning is about the stored state and returns on the next real run."""
        stale_seq = {"tenant": "quantivly", "generated_at": "2026-09-16T05:00:00Z", "failed_sources": [],
                     "items": [{"bucket": 1, "key": "K-1", "title": "t", "waiting_on": "b", "why_now": "now"}],
                     "triage": [], "decisions": []}
        for max_lines in (1, 2, 3, 12):
            with self.subTest(max_lines=max_lines):
                lines = brief.terminal_lines(stale_seq, "inbox: x", None, max_lines=max_lines,
                                              brief_path="/p/brief.md", now=self.NOW, dry_run=True)
                self.assertLessEqual(len(lines), max_lines)
                self.assertTrue(lines[0].startswith("dry-run:"), lines)
        # and the staleness warning is still there the moment there is room for it
        two = brief.terminal_lines(stale_seq, None, None, max_lines=2, brief_path=None,
                                   now=self.NOW, dry_run=True)
        self.assertTrue(two[0].startswith("dry-run:"), two)
        self.assertTrue(two[1].startswith("! brief is "), two)

    def test_an_unreadable_snapshot_is_needs_not_the_end_of_the_brief(self):
        """Review finding, and a deliberate reversal of this row's first version. It used to assert
        `errors.Usage` for a malformed `fetched_at` -- which cost the brief entirely, and which two
        other shapes did not even reach: a file that was not JSON raised an unhandled
        `JSONDecodeError` and a JSON list an unhandled `AttributeError`. A file we cannot read is
        precisely one whose fetch time we do not know, which is what needing a fetch means, and
        "needs accompanies the brief, never replaces it" has to hold for a broken file too."""
        for label, payload in (("bad fetched_at", '{"ok": true, "items": [], "fetched_at": "not-a-timestamp"}'),
                                ("not json", "{oops"),
                                ("a json list", "[]"),
                                ("no fetched_at", '{"ok": true, "items": []}')):
            with self.subTest(label=label):
                ctx = self.ctx()
                (ctx.state_dir / "sources").mkdir(parents=True, exist_ok=True)
                (ctx.state_dir / "sources" / "calendar.json").write_text(payload)
                needs = {n["source"]: n for n in brief.compute_needs(ctx, self.NOW)}
                self.assertIn("calendar", needs, label)
                self.assertTrue(needs["calendar"]["reason"].startswith("unreadable"), needs["calendar"])

    def test_a_recorded_failure_needs_a_fetch_however_fresh_it_is(self):
        """Review finding: `compute_needs` ignored `ok`, so a snapshot recorded five minutes ago as
        a FAILED fetch -- `items: []` by construction -- was reported as needing nothing. It also
        reaches the reader as a `failed` line, but only through `sequence.json`, which a same-day
        rerun does not regenerate, so that line can be stale where this one cannot."""
        ctx = self.ctx()
        snapshots.write(ctx.state_dir, "calendar",
                        {"ok": False, "error": "connector timed out", "items": [],
                         "fetched_at": "2026-09-16T08:55:00Z"})      # 5 minutes before NOW
        needs = {n["source"]: n for n in brief.compute_needs(ctx, self.NOW)}
        self.assertIn("calendar", needs)
        self.assertIn("last fetch failed", needs["calendar"]["reason"])
        self.assertIn("connector timed out", needs["calendar"]["reason"])

    def test_a_text_needs_line_carries_the_query_and_the_file_to_write(self):
        """Review finding: `query` and `write_to` were in the JSON return only, and the skill's
        output contract runs `rabota --text brief`. So in the form actually documented, the half of
        `needs` a caller can act on was unreachable without a second call -- the very round-trip
        this change exists to remove."""
        ctx = self.ctx()
        lines = brief.terminal_lines({"tenant": "quantivly", "generated_at": "2026-09-16T08:00:00Z",
                                       "failed_sources": [], "items": [], "triage": [], "decisions": []},
                                      None, None, brief_path="/p/brief.md",
                                      needs=brief.compute_needs(ctx, self.NOW))
        slack = next(l for l in lines if l.startswith("! slack "))
        self.assertIn("ingest-slack.json", slack)
        self.assertIn("to:me", slack)
        self.assertTrue(all(len(l) <= 120 for l in lines), lines)

    def test_a_no_change_rerun_still_prints_every_alert(self):
        """Review finding, and pre-existing on `main` for `failed_sources` alone: the no-change path
        returned `footer[-1:]`, so on the path most likely to be taken twice in a morning a failed
        source printed no line at all -- while the module docstring says it gets one."""
        seq = {"tenant": "quantivly", "generated_at": "2026-09-16T08:00:00Z",
               "failed_sources": ["linear"], "items": [{"bucket": 1, "key": "K-1", "title": "t",
                                                         "waiting_on": "b", "why_now": "now"}],
               "triage": [], "decisions": []}
        previous = {"keys": ["K-1"], "generated_at": "2026-09-16T08:00:00Z"}
        lines = brief.terminal_lines(seq, "inbox: 3 archived", previous, brief_path="/p/brief.md",
                                      needs=[{"source": "slack", "reason": "never fetched",
                                              "query": "to:me", "write_to": "/s/ingest-slack.json"}])
        self.assertIn("no change since 08:00", lines[0])
        self.assertTrue(any(l.startswith("! linear failed") for l in lines), lines)
        self.assertTrue(any(l.startswith("! slack needs a fetch") for l in lines), lines)
        self.assertEqual(lines[-1], "brief: /p/brief.md")

    def test_an_overflowing_footer_keeps_the_brief_path_and_counts_the_alerts(self):
        """Review finding: a blind `[:max_lines]` slice dropped `brief: <path>` -- the only route to
        what did not fit -- and two of three alerts, with nothing saying so. The path is reserved
        now, and alerts that cannot all fit collapse into one counted line instead of vanishing."""
        seq = {"tenant": "quantivly", "generated_at": "2026-09-16T08:00:00Z", "failed_sources": [],
               "items": [], "triage": [], "decisions": []}
        needs = [{"source": s, "reason": "never fetched", "query": "q", "write_to": f"/s/ingest-{s}.json"}
                  for s in ("slack", "calendar", "fireflies")]
        two = brief.terminal_lines(seq, None, None, max_lines=2, brief_path="/p/brief.md", needs=needs)
        self.assertEqual(len(two), 2)
        self.assertEqual(two[-1], "brief: /p/brief.md")
        self.assertIn("3 source alerts", two[0])
        for s in ("slack", "calendar", "fireflies"):
            self.assertIn(s, two[0])
        one = brief.terminal_lines(seq, None, None, max_lines=1, brief_path="/p/brief.md", needs=needs)
        self.assertEqual(one, ["brief: /p/brief.md"])      # the escape hatch is the last thing cut

    def test_run_brief_carries_needs_in_json_and_as_bang_lines_in_text(self):
        # Two fresh contexts (not two calls on one): a second same-day call hits the no-change
        # rerun path, which — like `failed_sources` today — keeps only the last footer line.
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx()
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq_for(ctx, ["K-1"])))
        out = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertEqual({n["source"] for n in out["needs"]}, {"slack", "calendar"})
        for n in out["needs"]:
            self.assertEqual(set(n), {"source", "reason", "query", "write_to"})
        ctx2 = self.ctx()
        day2 = ctx2.state_dir / "2026-09-16"; day2.mkdir(parents=True, exist_ok=True)
        (day2 / "sequence.json").write_text(json.dumps(seq_for(ctx2, ["K-1"])))
        lines = brief.run_brief(ctx2, text=True, now=self.NOW, gh=gh, lin=lin)
        for source in ("slack", "calendar"):
            self.assertTrue(any(l.startswith(f"! {source} needs a fetch —") for l in lines), lines)

    def test_needs_does_not_replace_the_brief_or_change_the_exit_code(self):
        # The strong recommendation in DO-716: `needs` accompanies the brief, never replaces it,
        # and is not itself a failure — same exit code (0) as a brief with no needs at all.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq_for(ctx, ["K-1"])))
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


class BriefFirefliesNeedsTests(unittest.TestCase):
    """DO-746 fix round, finding F1: Fireflies action items reach classification through `needs`
    — no query, `fetched: True`, no `write_to` — and exactly once."""

    def ctx(self, tenant="quantivly", dry_run=False):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(Path(tmp.name)), text=False, dry_run=dry_run)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([SSH_OK]), env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 9, 16))
        self.addCleanup(ctx.close)
        return ctx

    NOW = datetime(2026, 9, 16, 9, 0, tzinfo=timezone.utc)

    def _write_fireflies(self, ctx, transcripts, fetched_at="2026-09-16T08:30:00Z"):
        snapshots.write(ctx.state_dir, "fireflies",
                        {"ok": True, "error": None, "transcripts": transcripts, "fetched_at": fetched_at})

    def _fresh_needs_sources(self, ctx):
        for source in brief.NEEDS_SOURCES:
            snapshots.write(ctx.state_dir, source, {"ok": True, "error": None, "items": [],
                                                    "fetched_at": "2026-09-16T08:55:00Z"})

    def test_no_fireflies_snapshot_is_not_in_needs(self):
        ctx = self.ctx()
        self.assertNotIn("fireflies", {n["source"] for n in brief.compute_needs(ctx, self.NOW)})

    def test_a_tenant_that_does_not_use_fireflies_never_gets_an_entry(self):
        # toysim only lists `sources = ["github"]` (tests/fixtures/config/tenants/toysim.toml).
        ctx = self.ctx("toysim")
        self._write_fireflies(ctx, [{"id": "t1", "title": "x", "date": "d",
                                     "action_items": [{"speaker": None, "item": "x", "timestamp": None}]}])
        self.assertEqual(brief.compute_needs(ctx, self.NOW), [])

    def test_an_empty_transcripts_snapshot_is_not_in_needs(self):
        ctx = self.ctx()
        self._write_fireflies(ctx, [])
        self.assertNotIn("fireflies", {n["source"] for n in brief.compute_needs(ctx, self.NOW)})

    def test_a_transcript_with_no_action_items_contributes_nothing(self):
        ctx = self.ctx()
        self._write_fireflies(ctx, [{"id": "t1", "title": "x", "date": "d", "action_items": []}])
        self.assertNotIn("fireflies", {n["source"] for n in brief.compute_needs(ctx, self.NOW)})

    def test_an_unreadable_fireflies_snapshot_is_not_needs_and_does_not_crash(self):
        # Same precedent as `compute_needs`'s own unreadable-snapshot handling for slack/calendar:
        # a broken file is a reason to say nothing about Fireflies, never a reason to cost the brief.
        ctx = self.ctx()
        (ctx.state_dir / "sources").mkdir(parents=True, exist_ok=True)
        (ctx.state_dir / "sources" / "fireflies.json").write_text("{oops")
        self.assertNotIn("fireflies", {n["source"] for n in brief.compute_needs(ctx, self.NOW)})

    def test_unclassified_items_produce_a_needs_entry_that_carries_them_with_no_fetch(self):
        # F1's core claim: this is what lets a headless turn 2 classify without a fetch or ingest.
        # Revert `compute_needs` to drop the `_fireflies_need` call to see this row fail: with
        # `29ab0d3` alone, Fireflies never appears in `needs` at all, however stale its snapshot.
        ctx = self.ctx()
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        needs = {n["source"]: n for n in brief.compute_needs(ctx, self.NOW)}
        self.assertIn("fireflies", needs)
        entry = needs["fireflies"]
        self.assertTrue(entry["fetched"])
        self.assertNotIn("query", entry)
        self.assertNotIn("write_to", entry)
        self.assertEqual(entry["items"], [{"transcript_id": "t1", "meeting": "1:1", "date": "2026-09-16",
                                           "speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}])

    def test_alert_line_says_classify_not_fetch(self):
        # `_alert_lines` keys off `fetched`, not the source name (Move 6) -- a Fireflies alert must
        # never claim there is a fetch or a file to write, since there is neither.
        ctx = self.ctx()
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": None, "item": "x", "timestamp": None}]}])
        needs = brief.compute_needs(ctx, self.NOW)
        lines = brief.terminal_lines({"tenant": "quantivly", "generated_at": "2026-09-16T08:00:00Z",
                                      "failed_sources": [], "items": [], "triage": [], "decisions": []},
                                     None, None, needs=needs)
        line = next(l for l in lines if l.startswith("! fireflies "))
        self.assertIn("classify", line)
        self.assertNotIn("needs a fetch", line)

    def test_a_needs_empty_morning_can_still_be_caused_by_fireflies_alone(self):
        # The invariant's clause "whether or not Slack or Calendar need a fetch that morning":
        # fresh slack/calendar plus an unclassified Fireflies item must still make `needs`
        # non-empty, so turn 2 still runs and classifies it.
        ctx = self.ctx()
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        needs = brief.compute_needs(ctx, self.NOW)
        self.assertEqual({n["source"] for n in needs}, {"fireflies"})

    def test_run_brief_acknowledged_marks_items_classified_so_they_do_not_reappear(self):
        # "Exactly once", fix round 2 shape (finding D): turn 1 (JSON) hands the items out, and
        # only turn 2's EXPLICIT `--classified fireflies` acknowledgement marks them -- not merely
        # being shown. AMENDED from the fix-round-1 version of this test, which called
        # `run_brief(text=True)` alone and expected that bare call to mark items classified: that
        # was finding D's bug (a bare `--text brief` also passed the old gate). This version drives
        # the real two-call cycle and fails against the OLD gate-on-"shown" code, which marks on
        # ANY `text=True` call whether or not `--classified` is honoured.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        turn1 = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)   # turn 1: JSON, hands out
        self.assertIn("fireflies", {n["source"] for n in turn1["needs"]})
        classified_file = ctx.state_dir / brief.FIREFLIES_CLASSIFIED_FILE
        self.assertFalse(classified_file.exists())    # not yet -- only handed out, not acknowledged
        second = brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin, classified=["fireflies"])
        # The acknowledgement itself classifies t1, so THIS screen must not say fireflies still
        # needs classifying (finding B) -- see the dedicated test for that below.
        self.assertFalse(any("fireflies" in l for l in second), second)
        self.assertTrue(classified_file.exists())
        ids = json.loads(classified_file.read_text())["ids"]
        self.assertEqual(len(ids), 1)
        self.assertTrue(ids[0].startswith("t1:"))
        third = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertNotIn("fireflies", {n["source"] for n in third["needs"]})

    def test_a_bare_text_brief_never_marks_anything_classified(self):
        # Finding D's exact bug: `rabota --text brief` (no `--classified`), typed by @zvi or by
        # anything outside the skill's turn 2, must classify nothing -- the reader only ever saw
        # the one-line alert, never the items. Fails against the pre-fix-round-2 code, which marked
        # on any `text=True` call.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)    # turn 1: hands out
        lines = brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin)    # a BARE --text call
        self.assertTrue(any("fireflies" in l for l in lines), lines)
        self.assertFalse((ctx.state_dir / brief.FIREFLIES_CLASSIFIED_FILE).exists())
        # And the item is still there to classify on a later, real acknowledgement.
        needs = {n["source"]: n for n in brief.compute_needs(ctx, self.NOW)}
        self.assertIn("fireflies", needs)

    def test_a_meeting_landing_between_turn_1_and_turn_2_is_not_marked_by_the_ack(self):
        # Finding D's "what the acknowledgement marks must be exactly the items turn 1 handed
        # out" clause: a meeting that lands mid-turn must survive the very next acknowledgement
        # unmarked, or it is classified without ever having been seen.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)    # turn 1 hands out t1 only
        # A meeting lands mid-turn, independently of this call (sync's job, exercised elsewhere).
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]},
                                    {"id": "t2", "title": "standup", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "New thing", "timestamp": "02:00"}]}])
        brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin, classified=["fireflies"])
        classified_ids = json.loads((ctx.state_dir / brief.FIREFLIES_CLASSIFIED_FILE).read_text())["ids"]
        self.assertEqual(len(classified_ids), 1)
        self.assertTrue(classified_ids[0].startswith("t1:"))
        needs = {n["source"]: n for n in brief.compute_needs(ctx, self.NOW)}
        self.assertIn("fireflies", needs)      # t2 is still unclassified -- it was never handed out
        self.assertEqual([i["transcript_id"] for i in needs["fireflies"]["items"]], ["t2"])

    def test_two_json_briefs_in_a_row_refresh_the_pending_handout(self):
        # Two turn-1 calls with no acknowledgement between them: the second overwrites what the
        # first handed out (nothing was ever marked, so there is nothing to lose), and an
        # acknowledgement right after still marks everything currently pending.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin, classified=["fireflies"])
        ids = json.loads((ctx.state_dir / brief.FIREFLIES_CLASSIFIED_FILE).read_text())["ids"]
        self.assertEqual(len(ids), 1)

    def test_turn_2_dying_before_acknowledging_loses_nothing(self):
        # Turn 1 hands out t1; turn 2 "dies" (never called). The next day's turn 1 still finds t1
        # pending and hands it out again -- nothing about the missing acknowledgement drops it.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)   # turn 1; no turn 2 follows
        self.assertFalse((ctx.state_dir / brief.FIREFLIES_CLASSIFIED_FILE).exists())
        needs = {n["source"]: n for n in brief.compute_needs(ctx, self.NOW)}
        self.assertIn("fireflies", needs)
        self.assertEqual([i["transcript_id"] for i in needs["fireflies"]["items"]], ["t1"])

    def test_a_dry_run_acknowledgement_marks_nothing(self):
        # DO-742: `--dry-run` writes nothing, marking included, even when `--classified fireflies`
        # is passed.
        ctx = self.ctx(dry_run=True)
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin, classified=["fireflies"])
        self.assertFalse((ctx.state_dir / brief.FIREFLIES_CLASSIFIED_FILE).exists())
        self.assertFalse((ctx.state_dir / brief.FIREFLIES_PENDING_FILE).exists())

    def test_a_late_item_appended_to_an_already_classified_transcript_is_not_lost(self):
        # Finding A's core claim: Fireflies fills a transcript's action items in over time, and
        # keying classification on the bare transcript id made anything appended after the first
        # classification invisible forever. Revert `_fireflies_item_key` to return the bare
        # transcript id (dropping the digest) to see this row fail.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "First", "timestamp": "01:00"}]}])
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin, classified=["fireflies"])
        self.assertNotIn("fireflies", {n["source"] for n in brief.compute_needs(ctx, self.NOW)})
        # Fireflies fills in the SAME transcript with a second item later.
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "First", "timestamp": "01:00"},
                                                       {"speaker": "Zvi", "item": "SECOND-added-later", "timestamp": "05:00"}]}])
        needs = {n["source"]: n for n in brief.compute_needs(ctx, self.NOW)}
        self.assertIn("fireflies", needs)
        self.assertEqual([i["item"] for i in needs["fireflies"]["items"]], ["SECOND-added-later"])

    def test_a_brief_that_was_not_shown_does_not_mark_anything_classified(self):
        # Mirrors `test_a_brief_that_printed_nothing_does_not_record_itself_as_shown`: turn 1's
        # JSON call with `needs` non-empty (here, purely because of fireflies) prints nothing and
        # must not mark the items classified -- only an explicit acknowledgement may.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertFalse((ctx.state_dir / brief.FIREFLIES_CLASSIFIED_FILE).exists())

    def test_last_brief_shown_marker_is_written_cross_day_matching_the_sequence(self):
        # `commands.sync.fireflies_since` reads this file to derive its fetch window (F2); it must
        # exist at the state-dir root, not nested under today's day directory, so it survives a day
        # boundary the way the day-scoped `last-brief.json` cannot.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin)
        day_seq = json.loads((ctx.state_dir / "2026-09-16" / "sequence.json").read_text())
        marker = ctx.state_dir / brief.LAST_SHOWN_FILE
        self.assertTrue(marker.exists())
        self.assertEqual(json.loads(marker.read_text())["generated_at"], day_seq["generated_at"])

    def test_the_acknowledging_call_does_not_say_its_own_marking_still_needs_classifying(self):
        # Finding B: `terminal_lines` used to build the `! fireflies needs classifying` line from
        # `needs` computed BEFORE marking ran, so the one screen @zvi actually reads said an item
        # still needed classifying when this very call had just classified it. Marking now happens
        # before `needs` is (re)computed for this call's own lines -- see `run_brief`'s ordering.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)    # turn 1: hands t1 out
        lines = brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin, classified=["fireflies"])
        self.assertFalse(any("needs classifying" in l for l in lines), lines)
        self.assertTrue(json.loads((ctx.state_dir / brief.FIREFLIES_CLASSIFIED_FILE).read_text())["ids"])

    def test_classified_without_text_is_a_usage_error_and_marks_nothing(self):
        # Review round 4, F1: a JSON call carrying the acknowledgement would mark items classified
        # (and record the brief as shown) though nothing was printed.
        ctx = self.ctx()
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        self._fresh_needs_sources(ctx)
        self._write_fireflies(ctx, [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                     "action_items": [{"speaker": "Zvi", "item": "Do the thing", "timestamp": "01:00"}]}])
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        with self.assertRaises(errors.Usage):
            brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin, classified=["fireflies"])
        self.assertFalse((ctx.state_dir / brief.FIREFLIES_CLASSIFIED_FILE).exists())
        self.assertFalse((ctx.state_dir / brief.LAST_SHOWN_FILE).exists())

    def test_an_unknown_classified_source_is_a_usage_error(self):
        # Review round 4, F2: `Fireflies` or `slack` used to parse and acknowledge nothing, silently.
        ctx = self.ctx()
        for bad in (["Fireflies"], ["slack"], ["fireflies", "calendar"]):
            with self.assertRaises(errors.Usage, msg=bad):
                brief.run_brief(ctx, text=True, now=self.NOW, gh=FakeGh("work-login"),
                                lin=FakeLinear(VIEWER), classified=bad)


class BriefRerankTests(unittest.TestCase):
    """DO-738: `brief` re-ranks when an input `rank` reads has moved since ``sequence.json`` was
    written, and — because re-ranking writes ``sequence.json``/``.md`` — never otherwise."""

    def ctx(self, dry_run=False):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=dry_run)
        ctx = context.Context.from_namespace(ns, cfg_base=FIX, runner=FakeRunner([SSH_OK]), env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 9, 16))
        self.addCleanup(ctx.close)
        return ctx

    NOW = datetime(2026, 9, 16, 8, 10, tzinfo=timezone.utc)

    def _fresh_needs_sources(self, ctx, at="2026-09-16T08:05:00Z"):
        for source in brief.NEEDS_SOURCES:
            snapshots.write(ctx.state_dir, source, {"ok": True, "error": None, "items": [], "fetched_at": at})

    def test_nothing_moved_does_not_rerank_or_rewrite_sequence_json(self):
        # Revert the DO-738 staleness check (always reuse an existing sequence.json) and this row
        # still passes -- it is `test_a_moved_pin_triggers_a_rerank...` below that fails then. This
        # row exists to prove the OTHER half: re-ranking is not free, so it must not happen on
        # every call, only on a real mismatch.
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx(); self._fresh_needs_sources(ctx)
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)     # first call: ranks (no sequence yet)
        seq_path = ctx.state_dir / "2026-09-16" / "sequence.json"
        written_once = seq_path.read_text()
        mtime = seq_path.stat().st_mtime_ns
        second = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertEqual(seq_path.read_text(), written_once, "sequence.json was rewritten with nothing moved")
        self.assertEqual(seq_path.stat().st_mtime_ns, mtime)
        self.assertTrue(any(l.startswith("no change since") for l in second["lines"]), second["lines"])

    def test_a_same_second_rewrite_with_new_content_still_reranks(self):
        # DO-738 review F1: the signature used each snapshot's `fetched_at`, which has one-second
        # resolution, so a rewrite with different content inside the same second went unnoticed.
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx(); self._fresh_needs_sources(ctx)
        linear = ctx.state_dir / "sources" / "linear.json"
        stamp = {"ok": True, "error": None, "fetched_at": "2026-09-16T08:05:00Z"}
        linear.write_text(json.dumps({**stamp, "issues": []}))
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        seq_path = ctx.state_dir / "2026-09-16" / "sequence.json"
        before = seq_path.read_text()
        linear.write_text(json.dumps({**stamp, "issues": [{"identifier": "HUB-1", "title": "new"}]}))
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertNotEqual(seq_path.read_text(), before,
                            "linear.json changed content under the same fetched_at, and nothing re-ranked")

    def test_an_unstamped_live_sequence_reranks_once_then_settles(self):
        # DO-738 review F2: every sequence.json the old code wrote carries no `inputs` key. The
        # first brief after deploy must re-rank once, then settle, not re-rank on every call.
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx(); self._fresh_needs_sources(ctx)
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True)
        seq_path = day / "sequence.json"
        seq_path.write_text(json.dumps(seq(["OLD-1"])))
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        first = seq_path.read_text()
        self.assertIn("inputs", json.loads(first), "the unstamped sequence was not re-ranked")
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertEqual(seq_path.read_text(), first, "re-ranked again with nothing moved")

    def test_a_moved_pin_triggers_a_rerank_with_a_truthful_delta(self):
        # A pin is the input DO-738's issue itself calls out, and the one furthest from a file --
        # `Store.pins_version` (see test_store.py) is what has to notice it moved.
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx(); self._fresh_needs_sources(ctx)
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        seq_path = ctx.state_dir / "2026-09-16" / "sequence.json"
        before = seq_path.read_text()
        ctx.store.set_pin("quantivly", "PROMISE-1", 2, "spoken promise to benoit")
        out = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertNotEqual(seq_path.read_text(), before, "the pin moved but sequence.json was not rewritten")
        self.assertEqual(json.loads(seq_path.read_text())["inputs"], rank_cmd.inputs_signature(ctx))
        # The delta is truthful: PROMISE-1 is genuinely new since the previous SHOWN brief.
        self.assertTrue(any(l.startswith("+ PROMISE-1") for l in out["lines"]), out["lines"])
        self.assertFalse(any(l.startswith("no change since") for l in out["lines"]), out["lines"])
        # And with nothing moved again, the NEXT call settles back to a truthful no-change.
        again = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertTrue(any(l.startswith("no change since") for l in again["lines"]), again["lines"])

    def test_dry_run_reranks_via_compute_sequence_without_writing(self):
        # DO-742 + DO-738: a dry run whose inputs moved must still compute the new ranking (through
        # `rank_cmd.compute_sequence`, never the writing `run_rank`) so the printed lines are not a
        # lie about what a real run would show -- but it must leave sequence.json exactly as it was.
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx(); self._fresh_needs_sources(ctx)
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)      # a real sequence.json exists
        seq_path = ctx.state_dir / "2026-09-16" / "sequence.json"
        before = seq_path.read_text()
        ctx.store.set_pin("quantivly", "PROMISE-1", 2, "spoken promise to benoit")
        ctx.dry_run = True
        lines = brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin)
        self.assertEqual(seq_path.read_text(), before, "a dry run rewrote sequence.json")
        self.assertTrue(any(l.startswith("dry-run: nothing written") for l in lines), lines)
        self.assertTrue(any(l.startswith("1. PROMISE-1") or l.startswith("+ PROMISE-1") for l in lines), lines)

    def test_staleness_and_a_moved_input_are_different_questions_and_can_both_print(self):
        # The staleness line is about `generated_at` vs the clock; a moved input is about content.
        # A re-rank stamps a FRESH `generated_at`, so the two cannot both be triggered by one call
        # here -- what this row proves instead is that they stay independent: a stale sequence with
        # NOTHING moved gets only the clock line, never a spurious rerank.
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx(); day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        old = seq_for(ctx, ["K-1"], generated_at="2026-09-16T05:00:00Z")
        (day / "sequence.json").write_text(json.dumps(old))
        lines = brief.run_brief(ctx, text=True, now=self.NOW, gh=gh, lin=lin)
        self.assertTrue(lines[0].startswith("! brief is "), lines)
        self.assertEqual(json.loads((day / "sequence.json").read_text())["generated_at"], "2026-09-16T05:00:00Z",
                         "an unmoved sequence was re-ranked just because it looked stale by the clock")

    def test_max_lines_one_two_three_stay_within_budget_while_reranking(self):
        # A re-rank happens on EVERY one of these calls (a fresh pin moves the input each time), so
        # this is `_assemble`'s cap exercised on the path that just rewrote sequence.json, not on a
        # cached one.
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx(); self._fresh_needs_sources(ctx)
        brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        for n, max_lines in enumerate((1, 2, 3)):
            ctx.store.set_pin("quantivly", f"PROMISE-{n}", 2, "spoken promise")
            before = (ctx.state_dir / "2026-09-16" / "sequence.json").read_text()
            lines = brief.run_brief(ctx, text=True, max_lines=max_lines, now=self.NOW, gh=gh, lin=lin)
            self.assertNotEqual((ctx.state_dir / "2026-09-16" / "sequence.json").read_text(), before,
                                f"max_lines={max_lines}: pin moved but no rerank happened")
            self.assertLessEqual(len(lines), max_lines)

    def test_full_cycle_after_ingest_reranks_without_a_separate_rank_call(self):
        """Drives the skill's actual two-turn cycle end to end, with no ``rank`` call anywhere
        (DO-738's whole point): turn 1 (JSON, ``needs`` non-empty on a fresh tempdir), an ingest of
        the sources ``needs`` named plus a reconciled pin (the real shape a Slack/Fireflies item
        takes once turn 2 has acted on it — see ``rabota`` skill step 2), then turn 2's exact final
        call, ``--text brief --max-lines 11 --classified fireflies``. The pin must be ranked and
        printed; the screen must not say ``no change``.

        Slack itself is deliberately NOT what makes the new item appear: `rank.rank` never reads
        `RankInputs.slack` (grep-verified; see `rank_cmd.inputs_signature`'s docstring), so an
        ingested Slack snapshot alone cannot move anything this test could observe in the ranked
        list. Fetching it still clears `needs` for that source, which is what unblocks the real
        cycle's final call in production -- the reconciled pin is the part of "the fetched item
        sits unranked" that a moved rank input can actually fix, and it is what this row checks.
        """
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        ctx = self.ctx()
        # Turn 1: needs is non-empty (nothing fetched yet), so nothing is printed or recorded.
        turn1 = brief.run_brief(ctx, text=False, now=self.NOW, gh=gh, lin=lin)
        self.assertTrue(turn1["needs"])
        self.assertFalse((ctx.state_dir / "2026-09-16" / "last-brief.json").exists())
        # Ingest: the Slack item this cycle fetched, plus calendar so `needs` clears, plus a
        # Fireflies action item so `--classified fireflies` has something real to acknowledge.
        snapshots.write(ctx.state_dir, "slack", {"ok": True, "error": None,
                                                 "items": [{"channel": "C1", "text": "can you review HUB-9?",
                                                            "user": "benoit", "ts": "2026-09-16T08:00:00Z"}],
                                                 "fetched_at": "2026-09-16T08:05:00Z"})
        snapshots.write(ctx.state_dir, "calendar", {"ok": True, "error": None, "items": [],
                                                     "fetched_at": "2026-09-16T08:05:00Z"})
        snapshots.write(ctx.state_dir, "fireflies", {"ok": True, "error": None, "fetched_at": "2026-09-16T08:05:00Z",
                                                     "transcripts": [{"id": "t1", "title": "1:1", "date": "2026-09-16",
                                                                     "action_items": [{"speaker": "benoit",
                                                                                       "item": "review HUB-9",
                                                                                       "timestamp": "01:00"}]}]})
        # Reconcile: the Slack item names a dated promise, so it becomes a pin -- exactly what the
        # skill's step 2 does with a fetched item before turn 2's final call.
        ctx.store.set_pin("quantivly", "HUB-9", 2, "review requested by benoit in Slack")
        # Turn 2's exact final call: `rabota --text brief --max-lines 11 --classified fireflies`,
        # with no `rank` call anywhere in this test -- the re-rank must happen inside `run_brief`
        # itself. `--max-lines 1/2/3` (the same rerank, driven with a tighter budget each time) is
        # covered separately in `test_max_lines_one_two_three_stay_within_budget_while_reranking`,
        # since varying the budget here would need a fresh pin per call to keep exercising a rerank
        # rather than the (equally real, separately tested) no-change path on an unmoved input.
        lines = brief.run_brief(ctx, text=True, max_lines=11, now=self.NOW, gh=gh, lin=lin,
                                classified=["fireflies"])
        self.assertLessEqual(len(lines), 11)
        self.assertFalse(any(l.startswith("no change since") for l in lines), lines)
        self.assertTrue(any(l.startswith("1. HUB-9") for l in lines), lines)
