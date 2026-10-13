"""DO-815: open escalations surface in ``brief`` and ``rabota escalations``, and creation notifies
the desktop exactly once.

Every runner here is a ``FakeRunner`` (or a stand-in for one): ``notify-send`` and ``herdr`` are
never executed. The CLI rows patch ``rabota.context.SubprocessRunner`` for the same reason.
"""
import argparse, io, json, os, shutil, tempfile, unittest, unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from datetime import date, datetime, timezone
from pathlib import Path

from rabota import cli, context, errors, secrets, snapshots
from rabota.commands import brief, close, escalate, escalations
from rabota.runner import FakeRunner, Result
from tests.test_brief import seq, seq_for
from tests.test_preflight import VIEWER, FakeGh, FakeLinear

FIX = Path(__file__).parent / "fixtures" / "config"
SKILL = Path(__file__).parents[2] / "claude" / "skills" / "rabota" / "SKILL.md"
HERDR_OK = (["herdr", "notification", "show"], Result(0, "", ""))
NOTIFY_OK = (["notify-send"], Result(0, "", ""))
SSH_OK = (["ssh-add", "-l"], Result(0, "256 SHA256:abc key (ED25519)\n", ""))
NOW = datetime(2026, 9, 16, 8, 10, tzinfo=timezone.utc)


def desktop_calls(runner):
    return [c for c in runner.calls if c[0] == "notify-send"]


def herdr_calls(runner):
    return [c for c in runner.calls if c[0] == "herdr"]


class Base(unittest.TestCase):
    def ctx(self, runner=None, dry_run=False, tenant="quantivly", state_dir=None):
        if state_dir is None:
            tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
            state_dir = Path(tmp.name)
        ns = argparse.Namespace(tenant=tenant, state_dir=str(state_dir), text=False, dry_run=dry_run)
        c = context.Context.from_namespace(ns, cfg_base=FIX, runner=runner or FakeRunner([HERDR_OK, NOTIFY_OK]),
                                            env={"PATH": "/bin"}, cwd=Path("/"), today=date(2026, 9, 16))
        self.addCleanup(c.close)
        return c


class EscalateNotifiesTheDesktopTests(Base):
    def test_creation_sends_one_herdr_and_one_desktop_notification(self):
        runner = FakeRunner([HERDR_OK, NOTIFY_OK])
        out = escalate.run_escalate(self.ctx(runner), "merge HUB-1?", "e", ["merge", "wait"], kind="decision")
        self.assertEqual(len(herdr_calls(runner)), 1)          # the herdr notification stays
        self.assertEqual(len(desktop_calls(runner)), 1)
        self.assertEqual(out, {"id": out["id"], "notified": True, "desktop_notified": True})
        argv = desktop_calls(runner)[0]
        self.assertEqual(argv[:5], ["notify-send", "--app-name", "rabota", "--urgency", "normal"])
        self.assertEqual(argv[5], f"ESC-{out['id']} rabota decision: merge HUB-1?")

    def test_urgency_critical_reaches_notify_send(self):
        runner = FakeRunner([HERDR_OK, NOTIFY_OK])
        escalate.run_escalate(self.ctx(runner), "q", "e", [], urgency="critical")
        argv = desktop_calls(runner)[0]
        self.assertEqual(argv[argv.index("--urgency") + 1], "critical")

    def test_the_body_carries_no_free_text_because_gnome_renders_markup_there(self):
        runner = FakeRunner([HERDR_OK, NOTIFY_OK])
        question = 'click <a href="https://example.invalid">here</a> & go'
        out = escalate.run_escalate(self.ctx(runner), question, "e", [])
        body = desktop_calls(runner)[0][-1]
        self.assertEqual(body, f"ESC-{out['id']}: rabota --tenant quantivly --text escalations --open")
        self.assertNotIn("<", body)

    def test_the_summary_is_one_line_and_cannot_be_read_as_markup_by_any_daemon(self):
        runner = FakeRunner([HERDR_OK, NOTIFY_OK])
        out = escalate.run_escalate(self.ctx(runner), 'see <a href="x">this</a>\n& <b>that</b>', "e", [])
        summary = desktop_calls(runner)[0][-2]
        self.assertEqual(summary, f'ESC-{out["id"]} rabota finding: see ‹a href="x"›this‹/a› ＆ ‹b›that‹/b›')

    def test_an_unknown_urgency_is_usage_before_anything_is_written_or_sent(self):
        for dry_run in (False, True):
            runner = FakeRunner([HERDR_OK, NOTIFY_OK])
            ctx = self.ctx(runner, dry_run=dry_run)
            with self.assertRaises(errors.Usage):
                escalate.run_escalate(ctx, "q", "e", [], urgency="urgent")
            self.assertEqual(runner.calls, [])
            self.assertEqual(ctx.store.escalations("quantivly"), [])
            self.assertFalse((ctx.state_dir / "escalations.jsonl").exists())

    def test_a_failing_notify_send_still_returns_the_id_and_keeps_the_herdr_result(self):
        for failing in (Result(1, "", "no bus"), Result(127, "", "not found: notify-send")):
            runner = FakeRunner([HERDR_OK, (["notify-send"], failing)])
            ctx = self.ctx(runner)
            out = escalate.run_escalate(ctx, "q", "e", [])
            self.assertTrue(out["notified"])
            self.assertFalse(out["desktop_notified"])
            self.assertIsNotNone(ctx.store.escalation(out["id"]))

    def test_a_raising_herdr_does_not_cost_the_desktop_notification(self):
        class HerdrRaises:
            calls = []
            def run(self, argv, **kw):
                self.calls.append(list(argv))
                if argv[0] == "herdr":
                    raise OSError("herdr not installed")
                return Result(0, "", "")
        runner = HerdrRaises()
        out = escalate.run_escalate(self.ctx(runner), "q", "e", [])
        self.assertFalse(out["notified"])
        self.assertTrue(out["desktop_notified"])
        self.assertEqual(len(desktop_calls(runner)), 1)

    def test_no_notify_and_dry_run_send_neither_notification(self):
        runner = FakeRunner([])
        out = escalate.run_escalate(self.ctx(runner), "q", "e", [], notify=False)
        self.assertEqual((out["notified"], out["desktop_notified"]), (None, None))
        dry = escalate.run_escalate(self.ctx(runner, dry_run=True), "q", "e", [], urgency="critical")
        self.assertEqual((dry["notified"], dry["desktop_notified"]), (None, None))
        self.assertEqual(runner.calls, [])

    def test_a_secret_in_the_escalation_raises_before_any_notification(self):
        value = "sk-test-secret-value-not-real-1111"
        secrets.register_value(value)
        self.addCleanup(secrets.REGISTERED_VALUES.discard, value)
        runner = FakeRunner([HERDR_OK, NOTIFY_OK])
        with self.assertRaises(errors.SecretLeak):
            escalate.run_escalate(self.ctx(runner), f"is {value} live?", "e", [])
        self.assertEqual(runner.calls, [])


    def test_an_env_held_secret_in_the_question_reaches_no_notifier(self):
        # Orchestrator review: the notifiers must never carry a protected value. What actually
        # stops it today is `_project`'s guard, which refuses before either notifier runs, so the
        # escalation is not created at all; the notifiers reading the stored (redacted) question
        # is defence in depth behind that, and is not separately observable while it holds.
        value = "lin-api-not-real-value-0000000000"
        runner = FakeRunner([HERDR_OK, NOTIFY_OK])
        ctx = self.ctx(runner)
        with unittest.mock.patch.dict(os.environ, {"LINEAR_API_KEY": value}):
            with self.assertRaises(errors.SecretLeak):
                escalate.run_escalate(ctx, f"is {value} live?", "e", [])
        self.assertEqual(runner.calls, [])
        self.assertEqual(ctx.store.escalations("quantivly"), [])
        self.assertFalse((ctx.state_dir / "escalations.jsonl").exists())


class NotifiedOncePerEscalationTests(Base):
    """§10: "a notification is sent once per escalation, never once per tick" — every reader of an
    open escalation is run against the same store after creation, and none of them notifies."""

    def test_no_reader_notifies_again(self):
        runner = FakeRunner([HERDR_OK, NOTIFY_OK, SSH_OK])
        ctx = self.ctx(runner)
        escalate.run_escalate(ctx, "merge HUB-1?", "e", ["merge", "wait"], kind="decision")
        self.assertEqual(len(desktop_calls(runner)), 1)
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq_for(ctx, ["K-1"])))
        gh, lin = FakeGh("work-login"), FakeLinear(VIEWER)
        for _ in range(2):                                   # a re-read, and a second "tick"
            escalations.run_escalations(ctx)
            escalations.run_escalations(ctx, open_only=True, text=True)
            brief.run_brief(ctx, text=True, now=NOW, gh=gh, lin=lin)
            brief.run_brief(ctx, text=False, now=NOW, gh=gh, lin=lin)
            close.run_close(ctx)
        self.assertEqual(len(desktop_calls(runner)), 1)
        self.assertEqual(len(herdr_calls(runner)), 1)


class EscalationsCommandTests(Base):
    def _three(self, ctx):
        a = escalate.run_escalate(ctx, "merge HUB-1?", "approved", ["merge", "wait"], kind="decision", subject="HUB-1")["id"]
        b = escalate.run_escalate(ctx, "flaky\ntest?", "log", [], kind="incident")["id"]
        c = escalate.run_escalate(ctx, "done?", "e", ["yes", "no"], kind="verification")["id"]
        escalate.run_answer(ctx, c, "yes")
        return a, b, c

    def test_json_lists_every_escalation_and_open_lists_the_unresolved(self):
        ctx = self.ctx(); a, b, c = self._three(ctx)
        everything = escalations.run_escalations(ctx)["escalations"]
        self.assertEqual([e["id"] for e in everything], [a, b, c])
        self.assertEqual(everything[0]["options"], ["merge", "wait"])     # decoded, not a JSON string
        self.assertEqual(everything[2]["disposition"], "yes")
        opened = escalations.run_escalations(ctx, open_only=True)["escalations"]
        self.assertEqual([e["id"] for e in opened], [a, b])
        self.assertEqual({e["kind"] for e in opened}, {"decision", "incident"})

    def test_text_is_one_line_per_escalation(self):
        ctx = self.ctx(); a, b, c = self._three(ctx)
        lines = escalations.run_escalations(ctx, text=True)
        self.assertEqual(len(lines), 3)
        self.assertEqual(lines[0], f"ESC-{a} [decision] HUB-1 · since 2026-{lines[0].split('since 2026-')[1][:5]}: "
                                   "merge HUB-1? — options: merge | wait")
        self.assertIn(f"ESC-{b} [incident] since ", lines[1])
        self.assertTrue(lines[1].endswith(": flaky test?"), lines[1])     # newline collapsed, no options
        self.assertTrue(lines[2].endswith("done? — answered: yes"), lines[2])
        self.assertEqual(len(escalations.run_escalations(ctx, open_only=True, text=True)), 2)

    def test_empty_text_says_so_rather_than_printing_nothing(self):
        ctx = self.ctx()
        self.assertEqual(escalations.run_escalations(ctx, text=True), ["no escalations"])
        self.assertEqual(escalations.run_escalations(ctx, open_only=True, text=True), ["no open escalations"])
        self.assertEqual(escalations.run_escalations(ctx), {"escalations": []})

    def test_only_the_tenants_own_escalations_are_listed(self):
        ctx = self.ctx()
        ctx.store.add_escalation("personal", "theirs", "e", [])
        mine = escalate.run_escalate(ctx, "mine", "e", [])["id"]
        self.assertEqual([e["id"] for e in escalations.run_escalations(ctx)["escalations"]], [mine])

    def test_the_escalations_schema_and_version_are_unchanged(self):
        ctx = self.ctx()
        cols = [r["name"] for r in ctx.store._rows("PRAGMA table_info(escalations)")]
        self.assertEqual(cols, ["id", "tenant", "first_seen", "ts", "question", "evidence", "options",
                                "disposition", "resolved_at", "resolution", "kind", "subject"])


class RedactedOnReadTests(Base):
    """Review finding: a lane that escalated without holding a value the reader holds stored it
    unredacted, and the reader's output guard then refused the whole brief."""

    def _leaky(self, ctx):
        value = "minted-gho-token-not-real-4242"
        eid = escalate.run_escalate(ctx, f"is {value} live?", f"log: {value}", [f"revoke {value}"], notify=False)["id"]
        secrets.register_value(value); self.addCleanup(secrets.REGISTERED_VALUES.discard, value)
        return value, eid

    def test_brief_still_prints_and_brief_md_carries_the_marker(self):
        runner = FakeRunner([HERDR_OK, NOTIFY_OK, SSH_OK])
        ctx = self.ctx(runner)
        value, eid = self._leaky(ctx)
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq_for(ctx, ["K-1"])))
        lines = brief.run_brief(ctx, text=True, now=NOW, gh=FakeGh("work-login"), lin=FakeLinear(VIEWER))
        self.assertTrue(lines[0].startswith("needs you: 1 open escalation"), lines)
        md = (day / "brief.md").read_text()
        self.assertNotIn(value, md)
        self.assertIn("is [redacted:minted-token] live?", md)
        self.assertIn("evidence: log: [redacted:minted-token]", md)
        self.assertIn("options: revoke [redacted:minted-token]", md)

    def test_escalations_and_close_print_the_marker_not_the_value(self):
        ctx = self.ctx()
        value, eid = self._leaky(ctx)
        text = json.dumps(escalations.run_escalations(ctx)) + "\n".join(escalations.run_escalations(ctx, text=True))
        self.assertNotIn(value, text)
        self.assertIn("[redacted:minted-token]", text)
        cf = Path(close.run_close(ctx)["carry_forward"]).read_text()
        self.assertIn(f"ESC-{eid}", cf)
        self.assertNotIn(value, cf)

    def test_answer_still_validates_against_the_stored_option(self):
        # `rabota answer`'s contract is unchanged: it reads the row through `escalation()`, not
        # the redacting listing.
        ctx = self.ctx()
        value, eid = self._leaky(ctx)
        with self.assertRaises(errors.Refused):
            escalate.run_answer(ctx, eid, "revoke [redacted:minted-token]")


class CloseOneLineTests(Base):
    def test_a_multi_line_question_stays_one_list_item_in_carry_forward(self):
        ctx = self.ctx()
        eid = escalate.run_escalate(ctx, "first\nsecond", "e", [], kind="correction", notify=False)["id"]
        cf = Path(close.run_close(ctx)["carry_forward"]).read_text()
        self.assertEqual(cf.count(f"- ESC-{eid} (since "), 2)       # awaiting + corrections
        self.assertNotIn("first\nsecond", cf)
        self.assertIn(": first second\n", cf)


class EscalationsCliTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name) / "home"; shutil.copytree(FIX, self.home / ".dotfiles-local" / "rabota")
        self.state = Path(tmp.name) / "state"
        self.runner = FakeRunner([HERDR_OK, NOTIFY_OK])
        p = unittest.mock.patch("rabota.context.SubprocessRunner", lambda env: self.runner)
        p.start(); self.addCleanup(p.stop)

    def main(self, *argv):
        env = dict(os.environ); env["HOME"] = str(self.home)
        out, err = io.StringIO(), io.StringIO()
        with unittest.mock.patch.dict(os.environ, env, clear=True), redirect_stdout(out), redirect_stderr(err):
            code = cli.main(["--tenant", "quantivly", "--state-dir", str(self.state), *argv])
        return code, out.getvalue(), err.getvalue()

    def test_escalate_urgency_flag_reaches_notify_send_and_escalations_lists_it(self):
        code, out, err = self.main("escalate", "--question", "q?", "--evidence", "e", "--urgency", "critical")
        self.assertEqual(code, 0, err)
        argv = desktop_calls(self.runner)[0]
        self.assertEqual(argv[argv.index("--urgency") + 1], "critical")
        code, out, err = self.main("escalations", "--open")
        self.assertEqual(code, 0, err)
        self.assertEqual([e["question"] for e in json.loads(out)["escalations"]], ["q?"])
        code, out, err = self.main("--text", "escalations", "--open")
        self.assertEqual(code, 0, err)
        self.assertIn("q?", out)
        self.assertEqual(len(desktop_calls(self.runner)), 1)

    def test_escalate_defaults_to_normal_urgency_and_refuses_an_unknown_one(self):
        code, _out, err = self.main("escalate", "--question", "q", "--evidence", "e")
        self.assertEqual(code, 0, err)
        argv = desktop_calls(self.runner)[0]
        self.assertEqual(argv[argv.index("--urgency") + 1], "normal")
        # A bad subcommand choice exits through argparse itself, as `--kind bogus` already does.
        with self.assertRaises(SystemExit) as cm:
            self.main("escalate", "--question", "q", "--evidence", "e", "--urgency", "urgent")
        self.assertEqual(cm.exception.code, errors.Usage.code)
        self.assertEqual(len(desktop_calls(self.runner)), 1)


class BriefNeedsYouTests(Base):
    def _open(self, n):
        return [{"id": i, "kind": "finding", "subject": None, "first_seen": "2026-09-15T08:00:00Z",
                 "question": f"q{i}", "evidence": "e", "options": [], "resolved_at": None} for i in range(1, n + 1)]

    def test_the_needs_you_line_is_first_and_names_every_open_escalation(self):
        lines = brief.terminal_lines(seq(["K-1"]), None, None, brief_path="/p/brief.md",
                                     now=datetime(2026, 9, 16, 9, 30, tzinfo=timezone.utc),
                                     open_escalations=self._open(2))
        self.assertEqual(lines[0], "needs you: 2 open escalations — ESC-1, ESC-2 — rabota --tenant quantivly --text escalations --open")
        self.assertTrue(lines[1].startswith("! brief is "), lines)       # outranks the staleness warning

    def test_one_open_escalation_is_singular(self):
        line = brief.needs_you_line(self._open(1), "quantivly")
        self.assertEqual(line, "needs you: 1 open escalation — ESC-1 — rabota --tenant quantivly --text escalations --open")

    def test_no_open_escalation_prints_no_line(self):
        self.assertIsNone(brief.needs_you_line([], "quantivly"))
        self.assertIsNone(brief.needs_you_line(None, "quantivly"))
        lines = brief.terminal_lines(seq(["K-1"]), None, None, open_escalations=[])
        self.assertFalse(any(l.startswith("needs you") for l in lines))
        # Nothing open must not read the tenant: test_sync passes a sequence without one.
        self.assertEqual(brief.terminal_lines({"items": [], "failed_sources": []}, None, None), [])

    def test_the_line_survives_the_no_change_rerun(self):
        previous = {"keys": ["K-1"], "generated_at": "2026-09-16T08:00:00Z"}
        lines = brief.terminal_lines(seq(["K-1"]), None, previous, brief_path="/p/brief.md",
                                     open_escalations=self._open(1))
        self.assertTrue(lines[0].startswith("needs you: 1 open escalation"), lines)
        self.assertIn("no change since 08:00", lines[1])

    def test_many_ids_are_cut_never_the_count_or_the_command(self):
        line = brief.needs_you_line(self._open(40), "quantivly")
        self.assertLessEqual(len(line), brief.LINE_MAX)
        self.assertTrue(line.startswith("needs you: 40 open escalations — ESC-1, ESC-2"), line)
        self.assertTrue(line.endswith(", … — rabota --tenant quantivly --text escalations --open"), line)

    def _ids(self, *ids):
        return [{"id": i} for i in ids]

    def test_ids_that_exactly_fit_are_not_cut_and_one_more_char_is(self):
        # The budget boundary. Two ids whose digits sum to 24 fill the line to exactly LINE_MAX.
        exact = brief.needs_you_line(self._ids(10**11, 10**11 + 1), "quantivly")
        self.assertEqual(len(exact), brief.LINE_MAX)
        self.assertNotIn("…", exact)
        over = brief.needs_you_line(self._ids(10**11, 10**12), "quantivly")
        self.assertLessEqual(len(over), brief.LINE_MAX)
        self.assertIn(f"ESC-{10**11}, … — rabota", over)

    def test_a_first_id_too_long_for_the_line_leaves_only_the_marker(self):
        line = brief.needs_you_line(self._ids(10**60, 1), "quantivly")
        self.assertEqual(line, "needs you: 2 open escalations — … — rabota --tenant quantivly --text escalations --open")

    def test_the_cut_marker_itself_never_overruns_the_line(self):
        # Review of the first version: reserving 2 chars for the 3-char ", …" overran by one.
        for width in range(1, 30):
            for n in range(1, 25):
                line = brief.needs_you_line(self._ids(*[10**(width - 1) + k for k in range(n)]), "quantivly")
                self.assertLessEqual(len(line), brief.LINE_MAX, (width, n, line))
                self.assertTrue(line.endswith(" — rabota --tenant quantivly --text escalations --open"), line)
                self.assertTrue(line.startswith(f"needs you: {n} open escalation"), line)

    def test_the_dry_run_notice_still_comes_first(self):
        lines = brief.terminal_lines(seq(["K-1"]), None, None, dry_run=True, open_escalations=self._open(1))
        self.assertTrue(lines[0].startswith("dry-run:"))
        self.assertTrue(lines[1].startswith("needs you:"))

    def test_brief_md_opens_with_needs_you_listing_every_kind(self):
        rows = self._open(2)
        rows[0].update(kind="decision", subject="HUB-1", options=["merge", "wait"], evidence="line one\nline two")
        rows[1].update(kind="correction")
        md = brief.compose_markdown(seq(["K-1"]), None, [], rows)
        sections = [l for l in md.splitlines() if l.startswith("## ")]
        self.assertEqual(sections[0], "## Needs you")
        self.assertIn("- ESC-1 [decision] HUB-1 · since 2026-09-15: q1 — options: merge | wait", md)
        self.assertIn("  evidence: line one line two", md)
        self.assertIn("  answer: rabota --tenant quantivly answer 1 <label>", md)
        self.assertIn("- ESC-2 [correction] since 2026-09-15: q2", md)

    def test_brief_md_says_nothing_is_open_rather_than_dropping_the_section(self):
        md = brief.compose_markdown(seq(["K-1"]), None, [], [])
        self.assertIn("## Needs you\n- nothing open\n", md)

    def test_run_brief_reads_the_store_into_brief_md_and_the_terminal(self):
        runner = FakeRunner([HERDR_OK, NOTIFY_OK, SSH_OK])
        ctx = self.ctx(runner)
        kinds = ("decision", "finding", "incident")
        ids = [escalate.run_escalate(ctx, f"{k}?", "e", [], kind=k)["id"] for k in kinds]
        resolved = escalate.run_escalate(ctx, "gone?", "e", ["ok"], kind="prereq")["id"]
        escalate.run_answer(ctx, resolved, "ok")
        day = ctx.state_dir / "2026-09-16"; day.mkdir(parents=True, exist_ok=True)
        (day / "sequence.json").write_text(json.dumps(seq_for(ctx, ["K-1"])))
        lines = brief.run_brief(ctx, text=True, now=NOW, gh=FakeGh("work-login"), lin=FakeLinear(VIEWER))
        self.assertEqual(lines[0], f"needs you: 3 open escalations — {', '.join(f'ESC-{i}' for i in ids)}"
                                   " — rabota --tenant quantivly --text escalations --open")
        md = (day / "brief.md").read_text()
        needs_you = md.split("## Needs you\n", 1)[1].split("\n## ", 1)[0]
        for i, k in zip(ids, kinds):
            self.assertIn(f"- ESC-{i} [{k}]", needs_you)
        self.assertNotIn(f"ESC-{resolved}", needs_you)

    def test_a_dry_run_brief_still_shows_the_line(self):
        runner = FakeRunner([HERDR_OK, NOTIFY_OK, SSH_OK])
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        real = self.ctx(runner, state_dir=Path(tmp.name))
        eid = escalate.run_escalate(real, "q?", "e", [])["id"]
        dry = self.ctx(runner, dry_run=True, state_dir=Path(tmp.name))
        lines = brief.run_brief(dry, text=True, now=NOW, gh=FakeGh("work-login"), lin=FakeLinear(VIEWER))
        self.assertEqual(lines[1], f"needs you: 1 open escalation — ESC-{eid} — rabota --tenant quantivly --text escalations --open")


class SkillStatusRowTests(unittest.TestCase):
    def test_status_row_points_at_rabota_escalations_and_that_command_parses(self):
        row = next(l for l in SKILL.read_text().splitlines() if l.startswith("| `/rabota status`"))
        self.assertIn("`rabota --text escalations --open`", row)
        cli._load_command_modules()
        ns = cli.build_parser().parse_args(["--text", "escalations", "--open"])
        self.assertEqual((ns.command, ns.text, ns.open), ("escalations", True, True))


if __name__ == "__main__":
    unittest.main()
