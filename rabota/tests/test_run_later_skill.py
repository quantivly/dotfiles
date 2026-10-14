"""``claude/skills/run-later/SKILL.md`` agrees with the scheduler it teaches (DO-821).

The skill is how every agent on this laptop learns that ``rabota schedule add`` exists (design §8),
so a skill that drifted from the CLI teaches a command that fails, or one that "succeeds" and never
runs. Precedent: ``test_skill_matches_cli.py`` for the rabota skill. Each row is written to fail on
a specific drift, and reads the fact from the code rather than restating it: a flag from the real
parser, a limit from its constant, an exit code from ``command_outcome``. Nothing here executes
``systemctl``, ``git`` or the secret guard: the rows that drive ``add`` and the tick use the
``FakeRunner`` fixtures of ``test_schedule.py`` and ``test_schedule_tick.py``.
"""
import argparse
import functools
import re
import shlex
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path

from rabota import cli, scheduler
from rabota.commands import schedule
from tests.test_schedule import ScheduleBase
from tests.test_schedule_tick import DUE, TickBase

REPO = Path(__file__).parents[2]
SKILL = REPO / "claude" / "skills" / "run-later" / "SKILL.md"


@functools.cache
def _text() -> str:
    return SKILL.read_text()


def _flat() -> str:
    """The skill with every run of whitespace collapsed, so a check reads prose, not line wrapping."""
    return re.sub(r"\s+", " ", _text())


def _frontmatter() -> dict:
    m = re.match(r"---\n(.*?)\n---\n", _text(), re.S)
    assert m, "SKILL.md has no frontmatter"
    name = re.search(r"(?m)^name: (.+)$", m.group(1)).group(1).strip()
    desc = re.sub(r"\s+", " ", m.group(1).split("description:", 1)[1]).strip(" >")
    return {"name": name, "description": desc}


def _commands() -> list[str]:
    """Every ``rabota …`` command line the skill shows: fenced lines (joined across ``\\``) and
    inline code spans. A fenced comment or a span that does not start with ``rabota `` is not one."""
    found = []
    for block in re.findall(r"```\w*\n(.*?)```", _text(), re.S):
        for line in block.replace("\\\n", " ").splitlines():
            if line.strip().startswith("rabota "):
                found.append(line.strip())
    prose = re.sub(r"```\w*\n.*?```", "", _text(), flags=re.S)
    found += [c for c in re.findall(r"`([^`\n]+)`", prose) if c.startswith("rabota ")]
    return found


def _is_invocation(command: str) -> bool:
    """A span with a flag or a ``<placeholder>`` is a command to run; ``rabota schedule add`` alone
    is the verb's NAME in prose, which argparse would reject for its missing required flags."""
    return any(t.startswith(("-", "<")) for t in shlex.split(command)[1:])


@functools.cache
def _parser():
    cli._load_command_modules()
    return cli.build_parser()


def _subparsers(parser):
    return next((a for a in parser._actions if isinstance(a, argparse._SubParsersAction)), None)


def _check(command: str):
    """An invocation goes through the REAL top-level parser; a name must name real subcommands.
    Either way a failure says which line and why."""
    words = shlex.split(command)[1:]
    if not _is_invocation(command):
        parser = _parser()
        for w in words:
            sub = _subparsers(parser)
            if sub is None:
                break
            if w not in sub.choices:
                raise AssertionError(f"the skill's `{command}` names {w!r}, which is not a subcommand")
            parser = sub.choices[w]
        return None
    err = StringIO()
    try:
        with redirect_stderr(err):
            return _parser().parse_args(words)
    except SystemExit:
        raise AssertionError(f"the skill's `{command}` does not parse: {err.getvalue().strip()}") from None


def _scheduler_commands():
    return [c for c in _commands() if re.match(r"rabota (?:--\S+ )*(?:schedule|escalations|answer)\b", c)]


def _add_example():
    adds = [c for c in _scheduler_commands()
            if re.match(r"rabota (?:--\S+ )*schedule add\b", c) and _is_invocation(c)]
    assert len(adds) == 1, f"expected exactly one `schedule add` invocation, found {adds}"
    return adds[0], _check(adds[0])


def _add_flags() -> set[str]:
    add = _subparsers(_subparsers(_parser()).choices["schedule"]).choices["add"]
    return {s for a in add._actions for s in a.option_strings}


class RunLaterSkillTests(unittest.TestCase):

    def test_frontmatter_names_the_skill_after_its_directory(self):
        # Claude Code resolves a skill by its frontmatter name; one that differs from the directory
        # install.conf.yaml links is a skill nobody's `/run-later` reaches.
        self.assertEqual(_frontmatter()["name"], SKILL.parent.name)

    def test_install_links_the_skill_into_every_account_dir(self):
        # §8: `~/.claude/skills/` is what every account dir's `skills/` resolves to. Without this
        # line the file exists in the repo and no agent ever loads it.
        conf = (REPO / "install.conf.yaml").read_text()
        self.assertRegex(conf, r"(?m)^\s+~/\.claude/skills/run-later: claude/skills/run-later\s*$")

    def test_description_wins_over_the_cloud_schedule_skill_for_local_work(self):
        # The built-in `schedule` skill claims one-time runs too ("remind me to check X tomorrow").
        # The description has to claim local work by name and send the rest back to it.
        desc = _frontmatter()["description"]
        self.assertIn("rabota schedule add", desc)
        self.assertIn("this laptop's files, credentials or tools", desc)
        self.assertRegex(desc, r"INSTEAD of the built-in cloud `schedule` skill")
        dont = desc.split("Do NOT use", 1)
        self.assertEqual(len(dont), 2, "the description has no `Do NOT use` clause")
        self.assertRegex(dont[1], r"recurring[^.]*`schedule`")

    def test_every_scheduler_command_the_skill_shows_parses(self):
        # A renamed flag, a global flag written after the subcommand (`schedule add --dry-run` is
        # an argparse error), an unbuilt one (`--then-prompt`) or a renamed verb fails here, naming
        # the line.
        cmds = _scheduler_commands()
        self.assertGreaterEqual(sum(map(_is_invocation, cmds)), 5,
                                f"too few scheduler invocations found to mean anything: {cmds}")
        for c in cmds:
            with self.subTest(command=c):
                _check(c)

    def test_the_add_example_is_a_dry_run_command_run_that_add_accepts(self):
        line, ns = _add_example()
        self.assertTrue(ns.dry_run, "the add example is not a dry run; the skill says dry-run first")
        self.assertIsNotNone(ns.script, "the add example is not a --command run")
        self.assertIsNone(ns.prompt_file, "the add example declares an agent run, which never runs yet")
        for flag in ("--record", "--ask", "--option", "--cwd"):
            self.assertIn(flag, line)

    def test_names_every_flag_the_issue_asks_it_to_show(self):
        flat = _flat()
        for flag in ("--command", "--allow", "--read", "--record", "--ask", "--option", "--cwd", "--at",
                     "--expires", "--timeout"):
            with self.subTest(flag=flag):
                self.assertIn(flag, _add_flags(), f"{flag} is not an add flag")
                self.assertIn(f"`{flag}", flat)

    def test_then_prompt_is_not_offered_while_add_has_no_such_flag(self):
        # Design §6 sketches `--then-prompt`; DO-820 builds it. Until `add` accepts it, the skill
        # must not mention it at all — an agent reads a flag in a skill as an instruction.
        if "--then-prompt" not in _add_flags():
            self.assertNotIn("--then-prompt", _text())
            self.assertNotIn("--then-on", _text())

    def test_exit_codes_match_command_outcome(self):
        flat = _flat()
        for code, word in ((0, "pass"), (1, "fail"), (2, "could-not-run")):
            with self.subTest(code=code):
                self.assertEqual(scheduler.command_outcome(code), word)
                self.assertIn(f"{code} `{word}`", flat)
        self.assertEqual(scheduler.command_outcome(3), "could-not-run")
        self.assertIn("any other code", flat)

    def test_limits_match_the_constants(self):
        # Each number the skill quotes, rebuilt from the constant that enforces it.
        flat = _flat()
        h = lambda td: int(td.total_seconds() // 3600)
        m = lambda td: int(td.total_seconds() // 60)
        claims = {
            "MAX_RUNNING_COMMANDS": f"At most {schedule.MAX_RUNNING_COMMANDS} command runs run at once per tenant",
            "MAX_HORIZON (--at)": f"at most {schedule.MAX_HORIZON.days} days ahead",
            "MAX_HORIZON (--expires)": f"at most {schedule.MAX_HORIZON.days} days after `--at`",
            "DEFAULT_EXPIRY": f"defaults to due + {h(schedule.DEFAULT_EXPIRY)} h",
            "MAX_TIMEOUT": f"at most {h(schedule.MAX_TIMEOUT)} h",
            "COMMAND_TIMEOUT": f"default {m(schedule.COMMAND_TIMEOUT)} min",
            "COMMAND_MEMORY_MAX": f"memory ({schedule.COMMAND_MEMORY_MAX})",
            "RETRY_DELAY": f"retried once, {m(scheduler.decl.RETRY_DELAY)} minutes later",
            "TAIL_BYTES": f"The last {scheduler.TAIL_BYTES // 1024} KiB of stdout and of stderr",
        }
        self.assertEqual(schedule.MAX_ATTEMPTS, 2, "the skill says `retried once`; MAX_ATTEMPTS moved")
        for const, claim in claims.items():
            with self.subTest(constant=const):
                self.assertIn(claim, flat)

    def test_names_every_launcher_add_refuses(self):
        words = re.search(r"\(\?:([^)]*)\)", schedule.CLAUDE_WORD.pattern).group(1).split("|")
        self.assertIn("claude", words)
        flat = _flat()
        for w in words:
            with self.subTest(word=w):
                self.assertIn(f"`{w}`", flat)

    def test_default_options_and_marker_match_the_code(self):
        flat = _flat()
        for o in schedule.DEFAULT_OPTIONS:
            with self.subTest(option=o["label"]):
                self.assertIn(f"*{o['label']}*", flat)
        self.assertIn(f"`{scheduler.MARKER}`", flat)

    def test_answer_and_tick_are_only_ever_forbidden(self):
        # `rabota answer` is @zvi's and `schedule tick` is the timer's (design §6). Every sentence that
        # names either must forbid it; a reworded "run `rabota answer`" fails here.
        sentences = re.split(r"(?<=[.:])\s", _flat())
        hits = [s for s in sentences if "rabota answer" in s or "schedule tick" in s]
        self.assertGreaterEqual(len(hits), 2)
        for s in hits:
            with self.subTest(sentence=s):
                self.assertRegex(s, r"\bNever\b")

    def test_a_disarmed_timer_is_reported_never_armed(self):
        flat = _flat()
        self.assertIn("is not enabled", flat)
        self.assertIn("Never arm the timer yourself", flat)

    def test_a_workspace_root_cwd_is_steered_to_a_repo(self):
        self.assertIn("--cwd <a repo or other directory>", _flat())

    def test_tenant_resolution_matches_the_resolver(self):
        # config.resolve_tenant: --tenant, then $CLAUDE_ACCOUNT_TENANT, then whatever owns the cwd.
        # Review finding: "your session's tenant" named a mechanism nothing exports.
        flat = _flat()
        self.assertIn("The tenant** is `--tenant`, else `$CLAUDE_ACCOUNT_TENANT`, else whatever owns your cwd", flat)
        self.assertIn("never `--cwd`", flat)

    def test_a_run_that_cannot_start_is_not_promised_a_retry(self):
        # scheduler._cannot_start refuses a gone cwd or a changed payload terminally (review finding).
        self.assertIn("A run that cannot start at all, because its `--cwd` is gone or its frozen script "
                      "changed, is `could-not-run` at once and never retried", _flat())

    def test_a_record_must_stay_untracked_not_only_be_untracked_at_add(self):
        # The tick re-asks git at every write (scheduler module docstring); a record in a repo that
        # commits its notes passes `add` and is lost later (review finding).
        self.assertIn("must not be tracked by git, then or later", _flat())

    def test_a_disarmed_timer_hands_over_the_add_line(self):
        # The refusal stores nothing, so the declaration survives only as the line itself (review).
        self.assertIn("Nothing was stored and no id exists", _flat())
        self.assertIn("hand over the exact `add` line", _flat())


class RunLaterExampleAddsTests(ScheduleBase):
    """The add example, run through the real ``run_add`` (dry run, ``FakeRunner``). Parsing proves the
    flags exist; this proves the example's own FLAGS are accepted together, e.g. that it puts no agent
    flag on a command run and no option `add` refuses. Its paths and time are placeholders, so
    ``--at``, ``--cwd``, ``--command`` and ``--record`` come from the fixture, not from the skill."""

    def test_the_example_script_is_one_add_accepts(self):
        # The fenced script is what agents copy: it needs a shebang (it is executed directly) and
        # must not trip the claude refusal. The add example's own script argument is checked too.
        (script,) = [b for b in re.findall(r"```bash\n(.*?)```", _text(), re.S) if b.startswith("#!")]
        self.assertRegex(script, r"^#!/")
        self.assertIsNone(schedule._claude_hit(script))
        line, ns = _add_example()
        self.assertFalse(schedule.CLAUDE_WORD.search(ns.script), ns.script)
        # The verdict is the script's exit code, so its LAST command is a test. Checked on the code
        # before the comment: asserting the trailing `# 0 pass, 1 fail` comment let a script ending
        # in `echo` pass (mutation sweep, M37).
        last = script.rstrip().splitlines()[-1].split("#", 1)[0].strip()
        self.assertRegex(last, r"^\[ .+ \]$", f"the script's last command {last!r} is not its verdict")

    def test_the_add_example_validates_with_its_own_options(self):
        _, ns = _add_example()
        ctx = self.ctx(dry_run=True)
        out = self.add(ctx, title=ns.title, args=ns.args, record=str(self.record), allow=ns.allow,
                       read=ns.read, ask=ns.ask, options=ns.option, timeout=ns.timeout, seat=ns.seat,
                       model=ns.model, effort=ns.effort, max_budget_usd=ns.max_budget_usd)
        self.assertIn("nothing written", out["dry_run"])
        self.assertEqual(out["kind"], "command")
        self.assertEqual(len(out["options"]), len(ns.option))
        self.assertTrue(any(o["action"].startswith("rerun") for o in out["options"]),
                        "the example shows no rerun option, the only way a check recurs")


class RunLaterDeferralTests(TickBase):
    """Both directions, from what the tick DOES with an agent row, not from a constant existing
    (review finding: DO-820 might keep ``AGENT_DEFERRAL`` for a fallback). While the tick defers an
    agent run, the skill must say so, or an agent schedules a run that silently expires; once it
    dispatches one, this fails until the skill stops saying it."""

    def test_agent_runs_are_called_deferred_exactly_while_the_tick_defers_them(self):
        ctx = self.tctx(); sid = self.declare(ctx, prompt_file=str(self.prompt))
        rep = self.tick(ctx, DUE)
        deferred = sid in [d["id"] for d in rep["deferred"]]
        says = "agent runs are not dispatched yet" in _flat()
        self.assertEqual(says, deferred, f"the tick {'defers' if deferred else 'dispatches'} agent runs; "
                                         f"the skill says they are {'not ' if says else ''}dispatched yet")
        if deferred:
            self.assertIn("DO-820", _flat())


if __name__ == "__main__":
    unittest.main()
