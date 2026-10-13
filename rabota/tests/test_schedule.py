"""``rabota schedule add|list|show|cancel`` (DO-816): the declaration half of scheduled runs.

Hermetic. ``systemctl`` and ``git`` are answered by ``FakeRunner``; the secret guard is answered by
``GuardFake`` below, whose claim about the real hook is pinned by the one row that runs the real
hook (``RealGuardTests``). Each refusal row asserts a needle that appears in that refusal's message
and in no other message this module can produce.
"""
import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from rabota import cli, context, errors, store
from rabota.commands import schedule
from rabota.runner import FakeRunner, Result, SubprocessRunner
from tests.support import last_json
from tests.test_cli import install_fixture_home, run_cli

FIX = Path(__file__).parent / "fixtures" / "config"
NOW = datetime(2026, 10, 13, 12, 0, tzinfo=timezone.utc)
AT = "2026-10-14 09:00+00:00"
ENABLED = (["systemctl", "--user", "is-enabled"], Result(0, "enabled\n", ""))
UNTRACKED = (["git"], Result(1, "", "error: pathspec 'x' did not match any file(s) known to git"))
DENY = json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                          "permissionDecisionReason": "`cat` on `x`, which holds credentials. Pipe it"}})

# One needle per refusal; `test_needles_are_unique` proves no message carries another's -- including
# the two "could not ask" refusals, whose wording once contained the tracked needle and let a row
# that disabled the tracked check pass on the wrong refusal (mutation sweep, tracked-off).
NEEDLES = {"past": "is in the past", "expiry": "is not after --at", "horizon": "the maximum horizon",
           "tracked": "is tracked by git", "guarded": "a path the secret guard protects",
           "cwd": "contains the run's out_dir", "claude": "invokes `claude`", "timer": "is not enabled",
           "git-unknown": "could not ask git about", "guard-unknown": "did not refuse its own control path"}


class GuardFake(FakeRunner):
    """``FakeRunner``, with the secret guard answered from its INPUT, which FakeRunner cannot route on.

    Denies a ``cat`` of any of the hook's four file names, like the real one; ``RealGuardTests``
    holds it to that. ``guard_works=False`` models the hook failing open (no jq): silence for all.
    """
    NAMES = (".zshrc.local", ".gitconfig.local", ".backup.local", ".credentials.json")

    def __init__(self, responses, guard_works=True, guard_code=0):
        super().__init__(responses)
        self.guard_works, self.guard_code, self.guard_inputs = guard_works, guard_code, []

    def run(self, argv, *, env=None, input=None, timeout=60, cwd=None):
        if list(argv) == ["bash", str(schedule.GUARD)]:
            self.calls.append(list(argv)); self.guard_inputs.append(input)
            cmd = json.loads(input)["tool_input"]["command"]
            hit = self.guard_works and any(n in cmd for n in self.NAMES)
            return Result(self.guard_code, DENY if hit else "", "")
        return super().run(argv, env=env, input=input, timeout=timeout, cwd=cwd)


class ScheduleBase(unittest.TestCase):
    def setUp(self):
        install_fixture_home(self)        # the tenant's state_dir, and so out_root, live in here
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name) / "work"; self.work.mkdir()     # a cwd outside every state dir
        self.script = self.work / "check.sh"
        self.script.write_text("#!/bin/sh\njournalctl --user -u x --since -1d | grep -c refused\n")
        self.prompt = self.work / "prompt.md"
        self.prompt.write_text("Check that the thing held. The bar: zero refusals.\n")
        self.record = self.work / "results.md"; self.record.write_text("# results\n")

    def ctx(self, responses=None, tenant="quantivly", dry_run=False, **kw):
        runner = kw.pop("runner", None) or GuardFake(list(responses or []) + [ENABLED, UNTRACKED], **kw)
        ns = argparse.Namespace(tenant=tenant, state_dir=None, text=False, dry_run=dry_run)
        ctx = context.Context.from_namespace(ns, cfg_base=self.base, runner=runner,
                                             env={"PATH": "/bin", "CLAUDE_CODE_SESSION_ID": "sess-1"}, cwd=self.work)
        self.addCleanup(ctx.close)
        return ctx

    def add(self, ctx, **kw):
        base = {"at": AT, "title": "count refusals", "command": str(self.script), "cwd": str(self.work),
                "now": NOW, "caller_cwd": str(self.work)}
        base.update(kw)
        if "prompt_file" in kw and "command" not in kw:
            base.pop("command")
        return schedule.run_add(ctx, **base)

    def refused(self, needle, ctx, **kw):
        with self.assertRaises(errors.Refused) as cm:
            self.add(ctx, **kw)
        self.assertIn(needle, str(cm.exception))
        self.assertEqual(ctx.store.list_schedules(), [])          # a refusal stores nothing
        self.assertFalse((ctx.state_dir / "schedules").exists())  # ...and freezes nothing
        return str(cm.exception)


class AddRefusalTests(ScheduleBase):
    """Spec §10 "`add` refusals", plus the three the issue adds. One row per refusal."""

    def test_refuses_a_past_at(self):
        self.refused(NEEDLES["past"], self.ctx(), at="2026-10-13 11:59+00:00")
        self.assertEqual(self.add(self.ctx(), at="2026-10-13 12:00+00:00")["status"], "pending")   # now is not past

    def test_refuses_an_expiry_before_at(self):
        self.refused(NEEDLES["expiry"], self.ctx(), expires="2026-10-14 08:00+00:00")
        self.refused(NEEDLES["expiry"], self.ctx(), expires=AT)     # equal leaves no window either

    def test_refuses_a_horizon_over_30_days_and_accepts_exactly_30(self):
        self.refused(NEEDLES["horizon"], self.ctx(), at="2026-11-12 12:01+00:00")
        out = self.add(self.ctx(), at="2026-11-12 12:00+00:00")
        self.assertEqual(out["not_before"], "2026-11-12T12:00:00Z")

    def test_refuses_a_record_git_tracks(self):
        ctx = self.ctx([(["git", "-C", str(self.work)], Result(0, "results.md\n", ""))])
        self.refused(NEEDLES["tracked"], ctx, record=str(self.record))

    def test_refuses_a_symlinked_record_whose_target_git_tracks(self):
        # ~/.zshrc -> ~/.dotfiles/zshrc is the shape: the link is untracked, what it names is not.
        repo = self.work / "repo"; repo.mkdir(); target = repo / "tracked.md"; target.write_text("x\n")
        link = self.work / "link.md"; link.symlink_to(target)
        ctx = self.ctx([(["git", "-C", str(repo)], Result(0, "tracked.md\n", ""))])
        self.refused(NEEDLES["tracked"], ctx, record=str(link))

    def test_a_git_that_cannot_answer_refuses_and_outside_a_repo_is_untracked(self):
        ctx = self.ctx([(["git"], Result(129, "", "usage: git ls-files"))])
        self.refused("could not ask git about --record", ctx, record=str(self.record))
        ctx = self.ctx([(["git"], Result(128, "", "fatal: not a git repository (or any parent)"))])
        self.assertEqual(self.add(ctx, record=str(self.record))["record"], str(self.record))

    def test_refuses_a_record_the_secret_guard_protects(self):
        guarded = self.work / ".backup.local"; guarded.write_text("x\n")
        ctx = self.ctx()
        self.refused(NEEDLES["guarded"], ctx, record=str(guarded))
        self.assertIn("cat -- ~/.zshrc.local", ctx.runner.guard_inputs[0])   # the control was asked first

    def test_refuses_a_symlinked_record_whose_target_the_guard_protects(self):
        guarded = self.work / ".gitconfig.local"; guarded.write_text("x\n")
        link = self.work / "innocent.md"; link.symlink_to(guarded)
        self.refused(NEEDLES["guarded"], self.ctx(), record=str(link))

    def test_a_guard_that_fails_open_refuses_rather_than_clears(self):
        msg = self.refused("did not refuse its own control path", self.ctx(guard_works=False),
                           record=str(self.record))
        self.assertNotIn(NEEDLES["guarded"], msg)

    def test_a_guard_that_errors_refuses_rather_than_clears(self):
        msg = self.refused("the secret guard exited 2", self.ctx(guard_code=2), record=str(self.record))
        self.assertNotIn(NEEDLES["guarded"], msg)

    def test_refuses_a_cwd_that_contains_the_out_dir(self):
        ctx = self.ctx()
        self.refused(NEEDLES["cwd"], ctx, cwd=str(self.home))
        schedule.out_root(ctx).mkdir(parents=True)
        self.refused(NEEDLES["cwd"], ctx, cwd=str(schedule.out_root(ctx).parent))   # .../out
        self.refused(NEEDLES["cwd"], ctx, cwd=str(schedule.out_root(ctx)))          # .../out/<tenant>
        sibling = Path(ctx.tenant.state_dir).expanduser().parent / "elsewhere"; sibling.mkdir(parents=True)
        self.assertEqual(self.add(ctx, cwd=str(sibling))["cwd"], str(sibling.resolve()))

    def test_refuses_a_command_script_that_invokes_claude(self):
        for body in ("claude -p 'check it'\n", "~/.local/bin/claude --resume x\n", "x=1; claude-as personal\n"):
            with self.subTest(body=body):
                self.script.write_text("#!/bin/sh\n" + body)
                self.refused(NEEDLES["claude"], self.ctx())

    def test_refuses_a_command_whose_arguments_invoke_claude(self):
        sh = self.work / "run.sh"; sh.write_text('#!/bin/sh\nexec "$@"\n')
        self.refused(NEEDLES["claude"], self.ctx(), command=str(sh), args=["claude", "-p", "x"])

    def test_a_script_naming_claude_paths_or_variables_is_not_refused(self):
        self.script.write_text("#!/bin/sh\njq . ~/.claude/settings.json\necho $CLAUDE_CONFIG_DIR\n"
                               "ls ~/.dotfiles/claude/hooks\ndu -sh ~/.claude\nnoclaude=1\n")
        self.assertEqual(self.add(self.ctx())["status"], "pending")

    def test_refuses_a_tenant_whose_timer_is_not_enabled(self):
        for out in ("disabled\n", "not-found\n", "enabled-runtime\n", "linked\n"):
            with self.subTest(state=out.strip()):
                ctx = self.ctx([(["systemctl"], Result(0 if out.startswith("enabled") else 1, out, ""))])
                msg = self.refused(NEEDLES["timer"], ctx)
                self.assertIn("rabota-schedule@quantivly.timer", msg)
                self.assertIn(["systemctl", "--user", "is-enabled", "rabota-schedule@quantivly.timer"],
                              ctx.runner.calls)

    def test_dry_run_refuses_a_disarmed_timer_exactly_as_add_does(self):
        # The decision in the module docstring: a dry run that exited 0 here would tell an agent a
        # declaration the real add refuses was fine.
        ctx = self.ctx([(["systemctl"], Result(1, "disabled\n", ""))], dry_run=True)
        msg = self.refused(NEEDLES["timer"], ctx)
        self.assertIn("The declaration is otherwise valid", msg)

    def test_the_timer_is_asked_only_after_every_other_check(self):
        ctx = self.ctx([(["systemctl"], Result(1, "disabled\n", ""))])
        self.refused(NEEDLES["past"], ctx, at="2026-10-13 11:00+00:00")
        self.assertEqual(ctx.runner.calls, [])

    def test_needles_are_unique(self):
        msgs = {}
        for key, kw, responses in (
                ("past", {"at": "2026-10-13 11:00+00:00"}, []),
                ("expiry", {"expires": "2026-10-14 08:00+00:00"}, []),
                ("horizon", {"at": "2026-12-01 00:00+00:00"}, []),
                ("tracked", {"record": str(self.record)}, [(["git"], Result(0, "", ""))]),
                ("guarded", {"record": str(self.work / ".zshrc.local")}, []),
                ("cwd", {"cwd": str(self.home)}, []),
                ("claude", {"args": ["claude"]}, []),
                ("timer", {}, [(["systemctl"], Result(1, "disabled\n", ""))]),
                ("git-unknown", {"record": str(self.record)}, [(["git"], Result(129, "", "usage"))]),
                ("guard-unknown", {"record": str(self.record), "guard_works": False}, [])):
            (self.work / ".zshrc.local").write_text("x\n")
            ctx = self.ctx(responses, guard_works=kw.pop("guard_works", True))
            with self.assertRaises(errors.Refused) as cm:
                self.add(ctx, **kw)
            msgs[key] = str(cm.exception)
        for key, msg in msgs.items():
            self.assertEqual([k for k, n in NEEDLES.items() if n in msg], [key], msg)


class AddUsageTests(ScheduleBase):
    def usage(self, needle, **kw):
        with self.assertRaises(errors.Usage) as cm:
            self.add(self.ctx(), **kw)
        self.assertIn(needle, str(cm.exception))

    def test_shape_errors(self):
        self.usage("not both", prompt_file=str(self.prompt), command=str(self.script))
        self.usage("needs --command", kind="command", prompt_file=str(self.prompt))
        self.usage("a command run takes none", allow=["Bash(ls:*)"])
        self.usage("an agent run takes none", prompt_file=str(self.prompt), args=["x"])
        self.usage("one non-empty line", title="two\nlines")
        self.usage("--option needs --ask", options=["ok"])
        self.usage("the action must be", ask="q?", options=["ok=rerun:24h"])
        self.usage("labels must be unique", ask="q?", options=["a", "a=none"])
        self.usage("not a time", at="tomorrow")
        self.usage("not a duration", timeout="0m")
        self.usage("is not a file", command=str(self.work / "missing.sh"))
        self.usage("must be an existing regular file", record=str(self.work))

    def test_allow_takes_only_real_bash_rules(self):
        for rule in ("Edit(//etc/**)", "Bash", "Bash()", "Bash(*)", "Bash(:*)"):
            with self.subTest(rule=rule):
                self.usage("is not a Bash(...) rule", prompt_file=str(self.prompt), allow=[rule])
        out = self.add(self.ctx(), prompt_file=str(self.prompt), allow=["Bash(journalctl:*)"])
        self.assertEqual(out["allow"], ["Bash(journalctl:*)"])

    def test_option_parsing(self):
        self.assertEqual(schedule.parse_option("ack"), {"label": "ack", "action": "none"})
        self.assertEqual(schedule.parse_option("again=rerun:+24h"), {"label": "again", "action": "rerun:+24h"})
        self.assertEqual(schedule.parse_option("stop=cancel-followups")["action"], "cancel-followups")
        self.assertEqual(schedule.parse_option("now=rerun")["action"], "rerun")

    def test_a_naive_at_is_local_wall_time(self):
        with mock.patch.dict(os.environ, {"TZ": "Asia/Jerusalem"}):
            time.tzset(); self.addCleanup(time.tzset)
            out = self.add(self.ctx(), at="2026-10-14 09:00")
        self.assertEqual(out["not_before"], "2026-10-14T06:00:00Z")     # IDT is UTC+3 that day


class AddTests(ScheduleBase):
    def test_a_command_run_is_frozen_stored_and_printed(self):
        ctx = self.ctx()
        out = self.add(ctx, args=["--since", "-1d"], record=str(self.record), ask="Ship it?",
                       options=["yes", "again=rerun:+24h"])
        row = ctx.store.get_schedule(out["id"])
        self.assertRegex(out["id"], r"^s-[0-9a-f]{8}$")
        self.assertEqual((row["status"], row["kind"], row["attempt"], row["tenant"]), ("pending", "command", 0, "quantivly"))
        self.assertEqual((row["not_before"], row["expires_at"]), ("2026-10-14T09:00:00Z", "2026-10-16T09:00:00Z"))
        self.assertEqual((row["timeout_s"], row["memory_max"], row["max_attempts"], row["max_budget_usd"]),
                         (900, "1G", 2, None))
        self.assertEqual((row["seat"], row["model"], row["allow"]), (None, None, None))
        self.assertEqual(row["args"], ["--since", "-1d"])
        self.assertEqual(row["options"], [{"label": "yes", "action": "none"}, {"label": "again", "action": "rerun:+24h"}])
        self.assertEqual((row["created_from_cwd"], row["created_from_session"]), (str(self.work), "sess-1"))
        frozen = Path(row["payload_path"])
        self.assertEqual(frozen, ctx.state_dir / "schedules" / out["id"] / "script")
        source_sha = hashlib.sha256(self.script.read_bytes()).hexdigest()
        self.assertEqual(row["payload_sha256"], source_sha)
        self.assertEqual((frozen.parent / "SHA256SUMS").read_text(), f"{source_sha}  script\n")
        self.assertEqual(stat.S_IMODE(frozen.stat().st_mode), 0o500)
        self.assertEqual(out["permissions"]["confinement"].split(":")[0], "none")
        self.assertEqual(out["timer"], {"unit": "rabota-schedule@quantivly.timer", "state": "enabled"})
        self.script.write_text("#!/bin/sh\nrm -rf /\n")           # editing the source changes nothing
        self.assertEqual(hashlib.sha256(frozen.read_bytes()).hexdigest(), source_sha)

    def test_an_agent_run_carries_defaults_and_its_effective_permissions(self):
        ctx = self.ctx()
        out = self.add(ctx, prompt_file=str(self.prompt), allow=["Bash(journalctl:*)"], read=[str(self.work)])
        row = ctx.store.get_schedule(out["id"])
        self.assertEqual((row["kind"], row["seat"], row["model"], row["effort"]),
                         ("agent", "quantivly-1", "claude-sonnet-5", "medium"))
        self.assertEqual((row["timeout_s"], row["est_minutes"], row["memory_max"], row["max_budget_usd"]),
                         (1200, 20, "6G", 3.0))
        self.assertEqual(Path(row["payload_path"]).name, "prompt.md")
        self.assertEqual(stat.S_IMODE(Path(row["payload_path"]).stat().st_mode), 0o400)
        perms = out["permissions"]
        self.assertEqual(perms["permissions"]["defaultMode"], "dontAsk")
        self.assertTrue(perms["blockReadsOutsideWorkingDirectories"])
        self.assertEqual(perms["permissions"]["allow"],
                         ["Edit(/{out_dir}/**)", "Bash(journalctl:*)", f"Read(/{self.work}/**)"])
        self.assertEqual(perms["permissions"]["deny"], list(schedule.FIXED_DENY))
        for rule in ("Bash(claude:*)", "Bash(rabota schedule add:*)", "Bash(gh:*)", "Bash(git push:*)",
                     "Read(~/.zshrc.local)", "Read(**/.credentials.json)", "Read(~/.clauth/profiles/**)"):
            self.assertIn(rule, perms["permissions"]["deny"])

    def test_an_agent_run_refuses_a_seat_the_tenant_rule_forbids(self):
        with self.assertRaises(errors.Refused) as cm:
            self.add(self.ctx(), prompt_file=str(self.prompt), seat="personal-1")
        self.assertIn("work never runs on a personal window", str(cm.exception))

    def test_dry_run_validates_prints_and_writes_nothing(self):
        ctx = self.ctx(dry_run=True)
        out = self.add(ctx, record=str(self.record))
        self.assertIn("nothing written", out["dry_run"])
        self.assertEqual(out["status"], "pending")
        self.assertFalse((ctx.state_dir / "rabota.db").exists())    # the store was not even opened
        self.assertEqual(ctx.store.list_schedules(), [])
        self.assertFalse((ctx.state_dir / "schedules").exists())
        self.assertIn(["systemctl", "--user", "is-enabled", "rabota-schedule@quantivly.timer"], ctx.runner.calls)

    def test_a_prompt_carrying_a_protected_value_is_refused_and_nothing_is_left(self):
        canary = "sk-canary-0123456789"
        self.prompt.write_text(f"use {canary}\n")
        ctx = self.ctx()
        with mock.patch.dict(os.environ, {"LINEAR_API_KEY": canary}):
            with self.assertRaises(errors.SecretLeak):
                self.add(ctx, prompt_file=str(self.prompt))
        self.assertEqual(ctx.store.list_schedules(), [])
        self.assertEqual(list((ctx.state_dir / "schedules").iterdir()), [])


class VerbTests(ScheduleBase):
    def test_list_is_tenant_scoped_and_filters_by_status(self):
        ctx = self.ctx()
        a = self.add(ctx)["id"]; b = self.add(ctx, at="2026-10-15 09:00+00:00")["id"]
        schedule.run_cancel(ctx, b, now=NOW)
        self.assertEqual([r["id"] for r in schedule.run_list(ctx)["schedules"]], [a, b])
        self.assertEqual([r["id"] for r in schedule.run_list(ctx, "cancelled")["schedules"]], [b])
        for bad in ("", "bogus"):
            with self.assertRaises(errors.Usage):
                schedule.run_list(ctx, bad)

    def test_list_all_tenants_reads_each_tenant_store_and_creates_none(self):
        q = self.ctx(); qid = self.add(q)["id"]
        t = self.ctx(tenant="toysim"); tid = self.add(t, at="2026-10-15 09:00+00:00")["id"]
        personal_state = self.home / "Projects" / "handoffs" / "rabota"
        from rabota import config
        cfg = config.load(self.base, seats_by_machine={})
        out = schedule.run_list_all(cfg)
        self.assertEqual([(r["id"], r["tenant"]) for r in out["schedules"]], [(qid, "quantivly"), (tid, "toysim")])
        self.assertFalse(personal_state.exists())    # no store there, and listing made none

    def test_list_all_tenants_fails_on_an_unreadable_store_rather_than_showing_it_empty(self):
        t = self.ctx(tenant="toysim"); self.add(t)
        t.store.conn.execute("UPDATE schema_version SET version=99"); t.close()
        from rabota import config
        with self.assertRaises(errors.Partial) as cm:
            schedule.run_list_all(config.load(self.base, seats_by_machine={}))
        self.assertEqual([f["tenant"] for f in cm.exception.failed], ["toysim"])

    def test_show_prints_the_declaration_and_checks_the_frozen_payload(self):
        ctx = self.ctx()
        sid = self.add(ctx, prompt_file=str(self.prompt))["id"]
        out = schedule.run_show(ctx, sid)
        self.assertTrue(out["payload_intact"])
        self.assertIn("Bash(claude:*)", out["permissions"]["permissions"]["deny"])
        p = Path(out["payload_path"]); p.chmod(0o600); p.write_text("tampered\n")
        self.assertFalse(schedule.run_show(ctx, sid)["payload_intact"])

    def test_show_and_cancel_refuse_an_unknown_id_and_another_tenants_row(self):
        ctx = self.ctx()
        sid = self.add(ctx)["id"]
        for fn in (schedule.run_show, schedule.run_cancel):
            with self.subTest(fn=fn.__name__):
                with self.assertRaises(errors.Usage):
                    fn(ctx, "s-00000000")
        ctx.store.update_schedule(sid, tenant="toysim")
        for fn in (schedule.run_show, schedule.run_cancel):
            with self.subTest(fn=fn.__name__):
                with self.assertRaises(errors.Refused) as cm:
                    fn(ctx, sid)
                self.assertIn("belongs to tenant 'toysim'", str(cm.exception))

    def test_cancel_moves_pending_to_cancelled_once(self):
        ctx = self.ctx()
        sid = self.add(ctx)["id"]
        out = schedule.run_cancel(ctx, sid, now=NOW)
        self.assertEqual((out["status"], out["ended_at"]), ("cancelled", "2026-10-13T12:00:00Z"))
        self.assertTrue(Path(out["payload_path"]).is_file())         # the frozen payload is kept
        with self.assertRaises(errors.Refused) as cm:
            schedule.run_cancel(ctx, sid)
        self.assertIn("is cancelled; only a pending run can be cancelled", str(cm.exception))
        ctx.store.update_schedule(sid, status="running")
        with self.assertRaises(errors.Refused):
            schedule.run_cancel(ctx, sid)

    def test_dry_run_cancel_writes_nothing(self):
        ctx = self.ctx(); sid = self.add(ctx)["id"]
        ctx.dry_run = True
        self.assertEqual(schedule.run_cancel(ctx, sid)["status"], "cancelled")
        self.assertEqual(ctx.store.get_schedule(sid)["status"], "pending")


class CliWiringTests(ScheduleBase):
    """Through ``cli.main``, the only path a user takes. ``SubprocessRunner`` is replaced, so no
    ``systemctl`` or ``git`` is ever executed."""

    def cli(self, *argv, runner=None):
        runner = runner or GuardFake([ENABLED, UNTRACKED])
        with mock.patch("rabota.context.SubprocessRunner", lambda env: runner), \
                mock.patch("rabota.commands.schedule.datetime") as dt:
            dt.now.return_value = NOW; dt.fromisoformat = datetime.fromisoformat
            return run_cli(["--tenant", "quantivly", *argv])

    def test_add_passes_arguments_after_double_dash_and_list_show_cancel_work(self):
        code, out, err = self.cli("schedule", "add", "--at", AT, "--title", "t", "--command", str(self.script),
                                  "--cwd", str(self.work), "--", "--since", "-1d")
        self.assertEqual(code, 0, err)
        sid = last_json(out)["id"]
        self.assertEqual(last_json(out)["args"], ["--since", "-1d"])
        code, out, _ = self.cli("schedule", "list")
        self.assertEqual([r["id"] for r in last_json(out)["schedules"]], [sid])
        code, out, _ = self.cli("--text", "schedule", "show", sid)
        self.assertIn(f"{sid} pending command: t", out)
        self.assertIn("payload intact", out)
        code, out, _ = self.cli("schedule", "cancel", sid)
        self.assertEqual((code, last_json(out)["status"]), (0, "cancelled"))

    def test_global_dry_run_reaches_add(self):
        code, out, err = self.cli("--dry-run", "schedule", "add", "--at", AT, "--title", "t",
                                  "--command", str(self.script), "--cwd", str(self.work))
        self.assertEqual(code, 0, err)
        self.assertIn("nothing written", last_json(out)["dry_run"])

    def test_a_refusal_exits_3(self):
        code, _, err = self.cli("schedule", "add", "--at", "2026-10-01 00:00+00:00", "--title", "t",
                                "--command", str(self.script), "--cwd", str(self.work))
        self.assertEqual(code, 3)
        self.assertIn(NEEDLES["past"], last_json(err)["error"]["message"])

    def test_all_tenants_takes_no_tenant(self):
        code, _, err = self.cli("schedule", "list", "--all-tenants")
        self.assertEqual(code, 2)
        self.assertIn("takes no --tenant", err)

    def test_the_command_modules_entry_is_what_registers_it(self):
        # A fresh interpreter imports only what `_load_command_modules` walks (see test_pin_gate).
        r = subprocess.run([sys.executable, "-m", "rabota", "schedule", "--help"], capture_output=True, text=True,
                           cwd=str(Path(__file__).resolve().parents[1]),
                           env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1])})
        self.assertEqual(r.returncode, 0, r.stderr[:200])
        self.assertIn("cancel", r.stdout)


class RealGuardTests(unittest.TestCase):
    """Pins ``GuardFake``'s claim against the REAL hook: same two commands, same two decisions.

    Runs ``bash`` on ``claude/hooks/secret-emission-guard.sh`` with a synthetic payload; the hook
    reads stdin and prints a decision, and touches nothing.
    """

    def test_the_real_guard_refuses_the_control_and_clears_an_ordinary_file(self):
        ctx = argparse.Namespace(runner=SubprocessRunner(dict(os.environ)))
        self.assertIsNotNone(schedule._guard_denies(ctx, f"cat -- {schedule.GUARD_CONTROL}"))
        self.assertIsNotNone(schedule._guard_denies(ctx, "cat -- /tmp/x/.backup.local"))
        self.assertIsNone(schedule._guard_denies(ctx, "cat -- /tmp/x/results.md"))


if __name__ == "__main__":
    unittest.main()
