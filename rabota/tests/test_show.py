"""DO-872: ``rabota show`` prints the newest sequence and the inbox plan with their stamps, and
writes nothing. It is the one read-only contract nanoclaw's laptop agent execs for the Sol Linear
workspace bridge, so the field set is pinned exactly: a key added or dropped here is a wire change
on the other side.
"""
import argparse, io, json, os, shutil, tempfile, unittest, unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from datetime import date
from pathlib import Path

from rabota import cli, context, errors
from rabota.commands import show
from rabota.runner import FakeRunner, Result
from tests.support import last_json

FIX = Path(__file__).parent / "fixtures" / "config"
TIMER_ARGV = show.timer_show_argv("quantivly")
TIMER_LIVE = (TIMER_ARGV, Result(0, "NextElapseUSecRealtime=Wed 2026-11-04 05:00:40 UTC\n", ""))
TIMER_ABSENT = (TIMER_ARGV, Result(0, "NextElapseUSecRealtime=\n", ""))
TIMER_NO_SYSTEMCTL = (TIMER_ARGV, Result(127, "", "not found: systemctl"))


def item(bucket, key, title="a title", waiting_on="", why_now="why", source="linear"):
    """One ``sequence.json`` row the way ``rank._item`` writes it (invented keys and titles)."""
    return {"bucket": bucket, "key": key, "title": title, "waiting_on": waiting_on, "why_now": why_now,
            "rationale": f"bucket {bucket}: invented", "url": f"https://example.invalid/{key}", "source": source}


def sequence(items, generated_at="2026-11-03T16:31:43Z", failed=("calendar",), decisions=2):
    return {"generated_at": generated_at, "tenant": "quantivly", "failed_sources": list(failed), "items": items,
            "triage": [], "decisions": [{"key": f"DEC-{i}", "why": "decide", "url": None} for i in range(decisions)],
            "inputs": {"linear": "abc"}}


def plan_row(n, bucket, tier="decision"):
    """One inbox-plan row the way ``inbox.buckets.Item.to_json`` writes it (invented)."""
    return {"notification_id": f"n-{bucket}-{n}", "type": "issueAssignedToYou", "bucket": bucket, "tier": tier,
            "reason": "invented", "issue_id": f"id-{n}", "issue_identifier": f"EX-{n}", "issue_team": "EX",
            "pr_url": None, "actor": "someone", "created_at": "2026-11-01T10:00:00Z",
            "url": f"https://example.invalid/EX-{n}", "title": f"title {n}"}


def plan(buckets, batches=None, generated_at="2026-11-03T16:31:39Z"):
    totals = {b: len(rows) for b, rows in buckets.items()}
    return {"generated_at": generated_at, "tenant": "quantivly", "unread_total": sum(totals.values()),
            "buckets": buckets, "totals": totals,
            "batches": batches or {"due_policy": {"issues": []}, "stale_backlog": {"issues": []}}}


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.state = Path(tmp.name) / "state"
        self.state.mkdir()

    def write_day(self, day, seq):
        (self.state / day).mkdir(exist_ok=True)
        (self.state / day / show.SEQUENCE_FILE).write_text(json.dumps(seq))

    def write_plan(self, p):
        (self.state / show.PLAN_FILE).write_text(json.dumps(p))

    def ctx(self, runner=None):
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(self.state), text=False, dry_run=False)
        c = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner or FakeRunner([TIMER_LIVE]),
                                            env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 11, 3))
        self.addCleanup(c.close)
        return c


class FieldSetTests(Base):
    """The contract: these exact keys, nothing more. nanoclaw projects them one by one."""

    def test_top_level_sequence_plan_and_answers_field_sets(self):
        self.write_day("2026-11-03", sequence([item(1, "EX-1", waiting_on="someone")]))
        self.write_plan(plan({"confirm_required": [plan_row(1, "confirm_required", "confirm")]},
                             {"due_policy": {"issues": [{"id": "x", "identifier": "EX-9", "dueDate": "2026-11-10", "reason": "r"}]},
                              "stale_backlog": {"issues": [{"id": "y", "identifier": "EX-8", "updatedAt": "2026-07-01T00:00:00Z"}]}}))
        rep = show.run_show(self.ctx())
        self.assertEqual(sorted(rep), ["answers", "at", "next_elapse", "plan", "schema", "sequence"])
        self.assertEqual(rep["schema"], 1)
        self.assertEqual(rep["next_elapse"], "2026-11-04T05:00:40Z")
        self.assertEqual(sorted(rep["sequence"]), ["counts", "decisions", "failed_sources", "generated_at", "items"])
        self.assertEqual(rep["sequence"]["generated_at"], "2026-11-03T16:31:43Z")
        self.assertEqual(rep["sequence"]["failed_sources"], ["calendar"])
        self.assertEqual(rep["sequence"]["counts"], {"1": 1})
        self.assertEqual(rep["sequence"]["decisions"], 2)
        self.assertEqual(tuple(rep["sequence"]["items"][0]), show.SEQUENCE_ROW_FIELDS)
        self.assertEqual(rep["sequence"]["items"][0]["waiting_on"], "someone")
        self.assertEqual(sorted(rep["plan"]), ["batches", "buckets", "generated_at", "totals", "unread_total"])
        self.assertEqual(sorted(rep["plan"]["buckets"]), sorted(show.DECISION_BUCKETS))
        self.assertEqual(sorted(rep["plan"]["buckets"]["confirm_required"]), ["omitted", "rows"])
        self.assertEqual(tuple(rep["plan"]["buckets"]["confirm_required"]["rows"][0]), show.PLAN_ROW_FIELDS)
        self.assertEqual(rep["plan"]["buckets"]["project_prompt"], {"rows": [], "omitted": 0})
        self.assertEqual(sorted(rep["plan"]["batches"]), sorted(show.BATCHES))
        self.assertEqual(rep["plan"]["batches"]["due_policy"], {"count": 1, "identifiers": ["EX-9"]})
        self.assertEqual(rep["plan"]["batches"]["stale_backlog"], {"count": 1, "identifiers": ["EX-8"]})
        self.assertEqual(rep["plan"]["totals"], {"confirm_required": 1})
        self.assertEqual(rep["answers"], {"pending": [], "applied": []})

    def test_a_plan_row_carries_no_actor_issue_id_team_or_pr_url(self):
        # The subset is the point: what a decision on the phone needs. A key the Item grows later
        # (or one of the four dropped here) does not travel unseen.
        self.write_plan(plan({"assignment_new": [plan_row(1, "assignment_new", "rank")]}))
        row = show.run_show(self.ctx())["plan"]["buckets"]["assignment_new"]["rows"][0]
        for dropped in ("actor", "issue_id", "issue_team", "pr_url"):
            self.assertNotIn(dropped, row)


class NewestSequenceTests(Base):
    def test_the_newest_dated_directory_with_a_sequence_wins_with_its_own_stamp(self):
        # A weekend read prints Friday's rank with Friday's stamp: the server shows the age.
        self.write_day("2026-10-30", sequence([item(3, "OLD-1")], generated_at="2026-10-30T16:30:00Z"))
        self.write_day("2026-11-02", sequence([item(3, "NEW-1")], generated_at="2026-11-02T16:30:00Z"))
        (self.state / "_history").mkdir()                       # not a day directory
        (self.state / "2026-11-03-bodies").mkdir()              # a dated NAME is not a day directory either
        rep = show.run_show(self.ctx())
        self.assertEqual(rep["sequence"]["generated_at"], "2026-11-02T16:30:00Z")
        self.assertEqual([r["key"] for r in rep["sequence"]["items"]], ["NEW-1"])

    def test_a_newer_day_directory_without_a_sequence_falls_back_to_the_one_that_has_it(self):
        self.write_day("2026-11-02", sequence([item(3, "HAS-1")], generated_at="2026-11-02T16:30:00Z"))
        (self.state / "2026-11-03").mkdir()                     # brief.md only, say
        self.assertEqual(show.run_show(self.ctx())["sequence"]["generated_at"], "2026-11-02T16:30:00Z")

    def test_no_day_directory_is_the_explicit_no_sequence_arm_not_an_error(self):
        rep = show.run_show(self.ctx())
        self.assertEqual(rep["sequence"], {"unavailable": "no-sequence"})
        self.assertEqual(rep["plan"], {"unavailable": "no-plan"})
        self.assertEqual(rep["answers"], {"pending": [], "applied": []})

    def test_a_missing_state_dir_is_the_same_arm(self):
        shutil.rmtree(self.state)
        self.assertEqual(show.run_show(self.ctx())["sequence"], {"unavailable": "no-sequence"})


class DistinctKeysAndCapsTests(Base):
    def test_items_print_once_per_key_in_rank_order_and_counts_count_what_is_printed(self):
        # Bucket 1 held one row per notification on a thread (83 rows over 28 keys on 2026-11-03).
        rows = [item(1, "EX-1", why_now="first"), item(1, "EX-2"), item(1, "EX-1", why_now="second"),
                item(3, "EX-3"), item(3, "EX-1", why_now="third"), item(4, "EX-4")]
        self.write_day("2026-11-03", sequence(rows))
        seq = show.run_show(self.ctx())["sequence"]
        self.assertEqual([(r["bucket"], r["key"]) for r in seq["items"]], [(1, "EX-1"), (1, "EX-2"), (3, "EX-3"), (4, "EX-4")])
        self.assertEqual(seq["items"][0]["why_now"], "first")   # the first occurrence is the one kept
        self.assertEqual(seq["counts"], {"1": 2, "3": 1, "4": 1})

    def test_items_are_capped_at_max_rows_after_dedup_and_counts_are_not(self):
        rows = [item(3, f"EX-{n}") for n in range(40)] + [item(3, "EX-0")]
        self.write_day("2026-11-03", sequence(rows))
        seq = show.run_show(self.ctx())["sequence"]
        self.assertEqual(len(seq["items"]), show.MAX_ROWS)
        self.assertEqual(seq["items"][-1]["key"], f"EX-{show.MAX_ROWS - 1}")
        self.assertEqual(seq["counts"], {"3": 40})

    def test_decision_buckets_only_capped_with_the_remainder_counted(self):
        buckets = {"confirm_required": [plan_row(n, "confirm_required", "confirm") for n in range(30)],
                   "project_prompt": [plan_row(n, "project_prompt") for n in range(3)],
                   "reply_queue": [plan_row(n, "reply_queue", "rank") for n in range(7)],
                   "other": [plan_row(n, "other", "list") for n in range(2)]}
        batches = {"due_policy": {"issues": [{"id": str(n), "identifier": f"EX-{n}", "dueDate": "d", "reason": "r"} for n in range(27)]},
                   "stale_backlog": {"issues": []}}
        self.write_plan(plan(buckets, batches))
        p = show.run_show(self.ctx())["plan"]
        self.assertEqual(sorted(p["buckets"]), ["assignment_new", "confirm_required", "project_prompt"])
        self.assertEqual(len(p["buckets"]["confirm_required"]["rows"]), show.MAX_ROWS)
        self.assertEqual(p["buckets"]["confirm_required"]["omitted"], 5)
        self.assertEqual(p["buckets"]["project_prompt"]["omitted"], 0)
        self.assertEqual(p["buckets"]["assignment_new"], {"rows": [], "omitted": 0})
        self.assertEqual(p["unread_total"], 42)
        self.assertEqual(p["totals"]["reply_queue"], 7)         # totals cross for every bucket; rows for the decision tier only
        self.assertEqual(p["batches"]["due_policy"]["count"], 27)
        self.assertEqual(len(p["batches"]["due_policy"]["identifiers"]), show.MAX_ROWS)
        self.assertEqual(p["batches"]["stale_backlog"], {"count": 0, "identifiers": []})


class NextElapseTests(Base):
    def test_is_read_from_the_timer_the_way_doctor_reads_units(self):
        runner = FakeRunner([TIMER_LIVE])
        self.assertEqual(show.run_show(self.ctx(runner))["next_elapse"], "2026-11-04T05:00:40Z")
        self.assertEqual(runner.calls, [TIMER_ARGV])
        self.assertIn("--timestamp=utc", TIMER_ARGV)            # never the local zone's abbreviation

    def test_is_null_for_an_absent_or_inactive_unit(self):
        # `systemctl show` of a unit that does not exist, or an inactive timer, prints the key with
        # an empty value and exits 0.
        self.assertIsNone(show.run_show(self.ctx(FakeRunner([TIMER_ABSENT])))["next_elapse"])

    def test_is_null_when_systemctl_cannot_be_asked(self):
        self.assertIsNone(show.run_show(self.ctx(FakeRunner([TIMER_NO_SYSTEMCTL])))["next_elapse"])

    def test_parse_timer_stamp(self):
        self.assertEqual(show.parse_timer_stamp("Wed 2026-11-04 05:00:40 UTC"), "2026-11-04T05:00:40Z")
        for bad in ("", "n/a", "Wed 2026-11-04 07:00:40 IST", "2026-11-04T05:00:40Z"):
            self.assertIsNone(show.parse_timer_stamp(bad), bad)


class ReadOnlyTests(Base):
    """``tests/test_write_guard.py``'s pattern, measured rather than assumed: the state dir after
    a run is byte for byte the state dir before it, the store is never opened, and the only
    process run is the timer read."""

    def _tree(self):
        return sorted((str(p.relative_to(self.state)), p.stat().st_size, p.stat().st_mtime_ns)
                      for p in self.state.rglob("*"))

    def test_show_writes_nothing_opens_no_store_and_runs_only_the_timer_read(self):
        self.write_day("2026-11-03", sequence([item(1, "EX-1")]))
        self.write_plan(plan({"confirm_required": [plan_row(1, "confirm_required", "confirm")]}))
        before = self._tree()
        runner = FakeRunner([TIMER_LIVE])
        c = self.ctx(runner)
        show.run_show(c)
        self.assertEqual(self._tree(), before)
        self.assertFalse((self.state / "rabota.db").exists())
        self.assertIsNone(c._store)
        self.assertEqual(runner.calls, [TIMER_ARGV])


class UnparseableTests(Base):
    def test_a_corrupt_sequence_is_an_error_naming_the_file(self):
        (self.state / "2026-11-03").mkdir()
        (self.state / "2026-11-03" / show.SEQUENCE_FILE).write_text("{not json")
        with self.assertRaises(errors.RabotaError) as cm:
            show.run_show(self.ctx())
        self.assertIn("sequence.json: unparseable", str(cm.exception))
        self.assertEqual(cm.exception.code, 5)

    def test_a_sequence_missing_its_items_is_unparseable_too(self):
        self.write_day("2026-11-03", {"generated_at": "2026-11-03T16:31:43Z"})
        with self.assertRaises(errors.RabotaError) as cm:
            show.run_show(self.ctx())
        self.assertIn("missing items, decisions", str(cm.exception))

    def test_a_corrupt_plan_is_an_error_naming_the_file(self):
        (self.state / show.PLAN_FILE).write_text("[]")
        with self.assertRaises(errors.RabotaError) as cm:
            show.run_show(self.ctx())
        self.assertIn("inbox-plan.json: unparseable: not a JSON object", str(cm.exception))


class TextTests(Base):
    def test_text_lines_carry_the_stamps_the_counts_and_one_line_per_item(self):
        self.write_day("2026-11-03", sequence([item(1, "EX-1", title="an invented title", waiting_on="someone", why_now="asked")]))
        self.write_plan(plan({"project_prompt": [plan_row(1, "project_prompt")]}))
        lines = show.lines(show.run_show(self.ctx()))
        self.assertEqual(lines[0], "ranked 2026-11-03T16:31:43Z · next run 2026-11-04T05:00:40Z · failed: calendar")
        self.assertEqual(lines[1], "bucket 1: 1 · 2 decisions")
        self.assertEqual(lines[2], "1. [b1] EX-1 — an invented title (waiting on someone): asked")
        self.assertEqual(lines[3], "plan 2026-11-03T16:31:39Z · 1 unread · confirm_required 0 · project_prompt 1 · assignment_new 0 · due_policy 0 · stale_backlog 0")
        self.assertEqual(lines[4], "answers: 0 pending · 0 applied")

    def test_text_names_the_arms(self):
        self.assertEqual(show.lines(show.run_show(self.ctx()))[:2], ["sequence: no-sequence", "plan: no-plan"])


class CliTests(unittest.TestCase):
    """End to end through ``cli.main``: the argv nanoclaw's agent hands rabota."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name) / "home"; shutil.copytree(FIX, self.home / ".dotfiles-local" / "rabota")
        self.state = Path(tmp.name) / "state"; self.state.mkdir()
        self.runner = FakeRunner([TIMER_LIVE])
        p = unittest.mock.patch("rabota.context.SubprocessRunner", lambda env: self.runner)
        p.start(); self.addCleanup(p.stop)

    def main(self, *argv):
        env = dict(os.environ); env["HOME"] = str(self.home)
        out, err = io.StringIO(), io.StringIO()
        with unittest.mock.patch.dict(os.environ, env, clear=True), redirect_stdout(out), redirect_stderr(err):
            code = cli.main(["--tenant", "quantivly", "--state-dir", str(self.state), *argv])
        return code, out.getvalue(), err.getvalue()

    def test_show_json_is_the_agents_argv_and_prints_the_contract(self):
        (self.state / "2026-11-03").mkdir()
        (self.state / "2026-11-03" / show.SEQUENCE_FILE).write_text(json.dumps(sequence([item(1, "EX-1")])))
        code, out, err = self.main("show", "--json")
        self.assertEqual(code, 0, err)
        rep = json.loads(out)
        self.assertEqual(rep["schema"], 1)
        self.assertEqual([r["key"] for r in rep["sequence"]["items"]], ["EX-1"])
        self.assertEqual(rep["plan"], {"unavailable": "no-plan"})
        self.assertEqual(self.runner.calls, [TIMER_ARGV])

    def test_text_form_prints_lines(self):
        code, out, err = self.main("--text", "show")
        self.assertEqual(code, 0, err)
        self.assertEqual(out.splitlines()[0], "sequence: no-sequence")

    def test_an_unparseable_file_exits_5_with_a_named_reason(self):
        (self.state / show.PLAN_FILE).write_text("{")
        code, out, err = self.main("show")
        self.assertEqual(code, 5)
        self.assertEqual(out, "")
        self.assertIn("inbox-plan.json: unparseable", last_json(err)["error"]["message"])

    def test_help_lists_show(self):
        cli._load_command_modules()
        self.assertIn("show", cli.build_parser().format_help())
