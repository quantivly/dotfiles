"""``rabota schedule tick`` and the consumer loop (DO-817): spec §10, every row that is not agent-only.

Hermetic. ``TickRunner`` answers ``systemctl``, ``systemd-run``, ``notify-send``, ``herdr``, ``git`` and
the secret guard; none of them is ever executed. A unit's run is simulated by writing what its
wrapper would leave in the out_dir (``finish``). The wrapper itself is pinned by the one row that runs
it under ``/bin/sh``, which starts no unit.
"""
import argparse
import configparser
import fcntl
import json
import os
import stat
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from rabota import errors, scheduler, store
from rabota.commands import brief, escalate, escalations, schedule
from rabota.runner import Result
from tests.support import last_json
from tests.test_brief import seq
from tests.test_cli import run_cli
from tests.test_schedule import ENABLED, NOW, GuardFake, ScheduleBase

REPO = Path(__file__).resolve().parents[2]
DUE = datetime(2026, 10, 14, 9, 0, tzinfo=timezone.utc)      # test_schedule.AT
MIN = timedelta(minutes=1)
CANARY = "sk-canary-tick-0123456789"
UNTRACKED = Result(1, "", "error: pathspec 'x' did not match any file(s) known to git")


class TickRunner(GuardFake):
    """One runner for a SEQUENCE of ticks: unit state, start results and git's answer are mutable.

    A unit ``systemd-run`` starts is live until the test ``finish``es it, as on a real machine.
    """

    def __init__(self):
        super().__init__([ENABLED, (["herdr"], Result(0, "", "")), (["notify-send"], Result(0, "", ""))])
        self.live, self.units_fail, self.tracked = set(), False, False
        self.states = {}            # unit -> ActiveState other than "active", for a listed unit
        self.start, self.on_start = Result(0, "Running as unit\n", ""), None

    def run(self, argv, *, env=None, input=None, timeout=60, cwd=None):
        argv = list(argv)
        if argv[:3] == ["systemctl", "--user", "list-units"]:
            self.calls.append(argv)
            if self.units_fail:
                return Result(1, "", "Failed to connect to bus")
            return Result(0, json.dumps([{"unit": u, "active": self.states.get(u, "active")} for u in sorted(self.live)]), "")
        if argv[0] == "systemd-run":
            self.calls.append(argv)
            if self.start.ok:
                self.live.add(argv[3].removeprefix("--unit="))
            if self.on_start:
                self.on_start(argv)
            return self.start
        if argv[0] == "git":
            self.calls.append(argv)
            return Result(0, "", "") if self.tracked else UNTRACKED
        return super().run(argv, env=env, input=input, timeout=timeout, cwd=cwd)

    def of(self, name):
        return [c for c in self.calls if c[0] == name]


class TickBase(ScheduleBase):
    def setUp(self):
        super().setUp()
        self.runner = TickRunner()

    def tctx(self, **kw):
        return self.ctx(runner=self.runner, **kw)

    def declare(self, ctx, **kw):
        return self.add(ctx, **kw)["id"]

    def tick(self, ctx, at):
        return scheduler.run_tick(ctx, now=at)

    def finish(self, ctx, sid, code, stdout="", stderr="", keep_live=False):
        """What the unit's wrapper leaves behind; ``code`` None is a unit killed before it wrote one."""
        row = ctx.store.get_schedule(sid)
        d = Path(row["out_dir"]); d.mkdir(parents=True, exist_ok=True)
        (d / scheduler.STDOUT).write_text(stdout); (d / scheduler.STDERR).write_text(stderr)
        if code is not None:
            (d / scheduler.EXIT_FILE).write_text(f"{code}\n")
        if not keep_live:
            self.runner.live.discard(row["unit"])
        return row

    def run_once(self, ctx, code, **kw):
        """Declare, dispatch at DUE, finish with ``code``, settle ten minutes later. Returns the id."""
        stdout = kw.pop("stdout", "")
        sid = self.declare(ctx, **kw)
        self.tick(ctx, DUE)
        self.finish(ctx, sid, code, stdout=stdout)
        self.tick(ctx, DUE + 10 * MIN)
        return sid

    def escs(self, ctx):
        return ctx.store.escalations("quantivly")


class TimingTests(TickBase):
    """§10 "Timing: due, not due, expired"."""

    def test_a_run_not_yet_due_is_not_dispatched(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        rep = self.tick(ctx, DUE - MIN)
        self.assertEqual((rep["dispatched"], self.runner.of("systemd-run")), ([], []))
        self.assertEqual(ctx.store.get_schedule(sid)["status"], "pending")

    def test_a_due_run_is_claimed_with_its_unit_stored_before_systemd_run(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        seen = []
        self.runner.on_start = lambda argv: seen.append(ctx.store.get_schedule(sid))
        rep = self.tick(ctx, DUE)
        unit = f"rabota-sched-quantivly-{sid}-a1.service"
        self.assertEqual(rep["dispatched"], [{"id": sid, "attempt": 1, "unit": unit}])
        self.assertEqual(len(self.runner.of("systemd-run")), 1)
        before = seen[0]        # the row as systemd-run found it: already claimed, unit already named
        self.assertEqual((before["status"], before["attempt"], before["unit"]), ("running", 1, unit))
        self.assertEqual(before["out_dir"], str(schedule.out_root(ctx) / f"{sid}-a1"))
        self.assertTrue(Path(before["out_dir"]).is_dir())

    def test_a_run_past_expiry_expires_and_escalates_without_starting(self):
        ctx = self.tctx(); sid = self.declare(ctx, record=str(self.record))
        rep = self.tick(ctx, DUE + timedelta(hours=48))
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["outcome"], self.runner.of("systemd-run")), ("expired", "expired", []))
        self.assertIn("it was never tried", row["last_reason"])
        self.assertEqual(rep["expired"], [{"id": sid, "escalation": row["escalation_id"]}])
        (esc,) = self.escs(ctx)
        self.assertEqual((esc["kind"], esc["subject"]), ("scheduled-run", sid))
        argv = self.runner.of("notify-send")[0]
        self.assertEqual(argv[argv.index("--urgency") + 1], "critical")
        self.assertIn(f"<!-- rabota-schedule:{sid}:expired -->", self.record.read_text())
        self.assertIn(f"scheduled run {sid}: expired", self.record.read_text())

    def test_a_run_past_expiry_is_never_started_even_when_expiring_it_failed(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        with mock.patch.object(scheduler, "_expire_one", side_effect=OSError("disk full")):
            with self.assertRaises(errors.Partial):
                self.tick(ctx, DUE + timedelta(hours=48))
        self.assertEqual((ctx.store.get_schedule(sid)["status"], self.runner.of("systemd-run")), ("pending", []))

    def test_expiry_is_checked_before_dispatch_at_the_boundary(self):
        ctx = self.tctx(); sid = self.declare(ctx, expires="2026-10-14 09:10+00:00")
        self.tick(ctx, DUE + 10 * MIN)                         # due AND at expiry: expired, never started
        self.assertEqual((ctx.store.get_schedule(sid)["status"], self.runner.of("systemd-run")), ("expired", []))


class ExecutorTests(TickBase):
    """§7: the transient unit, its bounds, PATH, the frozen payload, and the refusals before a start."""

    def test_the_unit_is_bounded_runs_the_frozen_script_and_has_local_bin_on_path(self):
        ctx = self.tctx(); sid = self.declare(ctx, args=["--since", "$HOME"])
        self.tick(ctx, DUE)
        (argv,) = self.runner.of("systemd-run")
        row = ctx.store.get_schedule(sid)
        self.assertEqual(argv[:5], ["systemd-run", "--user", "--collect", f"--unit={row['unit']}",
                                    f"--working-directory={self.work.resolve()}"])
        self.assertIn("--expand-environment=no", argv)
        self.assertIn(f"--setenv=PATH={self.home}/.local/bin:/usr/local/bin:/usr/bin:/bin", argv)
        props = [argv[i + 1] for i, a in enumerate(argv) if a == "-p"]
        for p in ("MemoryMax=1G", "RuntimeMaxSec=900", "Nice=10", "KillMode=control-group",
                  f"StandardOutput=append:{row['out_dir']}/stdout.log", f"StandardError=append:{row['out_dir']}/stderr.log"):
            self.assertIn(p, props)
        tail = argv[argv.index("/bin/sh"):]
        self.assertEqual(tail, ["/bin/sh", "-c", scheduler.WRAPPER, "rabota-sched", f"{row['out_dir']}/exit-status",
                                row["payload_path"], "--since", "$HOME"])
        self.assertNotEqual(row["payload_path"], str(self.script))       # the frozen copy, never the source

    def test_a_command_run_gets_no_seat_and_passes_no_gate(self):
        ctx = self.tctx(); self.declare(ctx)
        self.tick(ctx, DUE)
        (argv,) = self.runner.of("systemd-run")
        self.assertFalse(any("CLAUDE_CONFIG_DIR" in a for a in argv))
        self.assertFalse([c for c in self.runner.calls if c[0] in ("claude-pick", "clauth", "claude")])

    def test_the_wrapper_writes_the_exit_status_and_passes_arguments_verbatim(self):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup); d = Path(tmp.name)
        script = d / "s.sh"; script.write_text('#!/bin/sh\nprintf "%s|" "$@"\nexit 3\n'); script.chmod(0o700)
        r = subprocess.run(["/bin/sh", "-c", scheduler.WRAPPER, "rabota-sched", str(d / "exit-status"), str(script),
                            "$HOME", "a b", "--x"], capture_output=True, text=True, timeout=10)
        self.assertEqual(r.stdout, "$HOME|a b|--x|")
        self.assertEqual((d / "exit-status").read_text(), "3\n")
        self.assertFalse((d / "exit-status.tmp").exists())

    def _refused(self, ctx, sid, needle):
        rep = self.tick(ctx, DUE)
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["outcome"], self.runner.of("systemd-run")), ("failed", "could-not-run", []))
        self.assertIn(needle, row["last_reason"])
        self.assertEqual([r["id"] for r in rep["refused"]], [sid])
        (esc,) = self.escs(ctx)
        self.assertEqual(esc["id"], row["escalation_id"])
        self.assertEqual(row["attempt"], 0)                    # nothing ran
        self.tick(ctx, DUE + 10 * MIN)                         # and nothing retries it
        self.assertEqual(self.runner.of("systemd-run"), [])

    def test_a_changed_frozen_payload_is_refused_never_run(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        p = Path(ctx.store.get_schedule(sid)["payload_path"]); p.chmod(0o700); p.write_text("#!/bin/sh\nexit 0\n")
        self._refused(ctx, sid, "changed after it was frozen")

    def test_a_payload_outside_its_own_schedule_directory_is_refused(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        ctx.store.update_schedule(sid, payload_path=str(self.script))     # right bytes, wrong place
        self._refused(ctx, sid, "is not in its own schedule directory")

    def test_a_missing_cwd_is_refused(self):
        sub = self.work / "gone"; sub.mkdir()
        ctx = self.tctx(); sid = self.declare(ctx, cwd=str(sub))
        sub.rmdir()
        self._refused(ctx, sid, "is not a directory")


class OutcomeTests(TickBase):
    """§10 "Outcomes and escalations", and "Deferral and retry" for command runs."""

    def test_exit_codes_map_to_outcomes(self):
        for code, outcome in ((0, "pass"), (1, "fail"), (2, "could-not-run"), (3, "could-not-run"),
                              (137, "could-not-run"), (None, "could-not-run")):
            self.assertEqual(scheduler.command_outcome(code), outcome, code)

    def test_each_outcome_maps_to_exactly_one_escalation_decision(self):
        self.assertEqual(scheduler.OUTCOMES, {
            "pass": ("done", None), "fail": ("done", "critical"), "inconclusive": ("done", "normal"),
            "denied": ("done", "critical"), "could-not-run": ("failed", "critical"), "expired": ("expired", "critical")})
        for outcome, (_, urgency) in scheduler.OUTCOMES.items():
            with self.subTest(outcome=outcome):
                runner = TickRunner(); ctx = self.ctx(runner=runner); sid = self.declare(ctx)
                row = {**ctx.store.get_schedule(sid), "id": sid}
                eid = scheduler._escalate_once(ctx, row, outcome, f"ev-{outcome}", "detail")
                self.assertEqual(eid is None, urgency is None)
                sent = runner.of("notify-send")
                self.assertEqual(len(sent), 0 if urgency is None else 1)
                if urgency:
                    self.assertEqual(sent[0][sent[0].index("--urgency") + 1], urgency)

    def test_a_clean_pass_is_recorded_and_raises_nothing(self):
        ctx = self.tctx(); sid = self.run_once(ctx, 0, record=str(self.record), stdout="0 refusals\n")
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["outcome"], row["escalation_id"]), ("done", "pass", None))
        self.assertEqual((self.escs(ctx), self.runner.of("notify-send")), ([], []))
        rec = self.record.read_text()
        self.assertIn(f"<!-- rabota-schedule:{sid}:1 -->\n## ", rec)
        self.assertIn(f"scheduled run {sid}: pass", rec)
        self.assertIn("0 refusals", rec)
        self.assertEqual((Path(row["out_dir"]) / "result.md").read_text().split("\n\n")[0],
                         rec.split(f"{sid}: pass\n\n", 1)[1].split("\n\n")[0])

    def test_a_fail_escalates_critically_and_is_never_retried(self):
        ctx = self.tctx(); sid = self.run_once(ctx, 1, ask="Ship it?", options=["yes", "again=rerun:+24h"])
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["outcome"], row["attempt"]), ("done", "fail", 1))
        (esc,) = self.escs(ctx)
        self.assertEqual((esc["options"], esc["evidence"]), (["yes", "again"], f"{row['out_dir']}/result.md"))
        self.assertTrue(esc["question"].startswith(f"{sid} count refusals: fail, exit 1"), esc["question"])
        self.assertTrue(esc["question"].endswith(". Ship it?"))
        for k in range(2, 12):
            self.tick(ctx, DUE + k * 10 * MIN)
        self.assertEqual(len(self.runner.of("systemd-run")), 1)

    def test_could_not_run_retries_after_the_delay_then_escalates(self):
        ctx = self.tctx(); sid = self.run_once(ctx, 2, record=str(self.record))
        row = ctx.store.get_schedule(sid)
        settled = DUE + 10 * MIN
        self.assertEqual((row["status"], row["attempt"], row["outcome"]), ("pending", 1, None))
        self.assertEqual(row["not_before"], schedule._iso(settled + schedule.RETRY_DELAY))
        self.assertIn("attempt 1 of 2 could not run: exit 2; retrying", row["last_reason"])
        self.assertEqual(self.escs(ctx), [])                     # a retry raises nothing
        self.tick(ctx, settled + schedule.RETRY_DELAY - MIN)
        self.assertEqual(len(self.runner.of("systemd-run")), 1)  # not before the delay
        self.tick(ctx, settled + schedule.RETRY_DELAY)
        self.assertEqual(len(self.runner.of("systemd-run")), 2)
        self.assertEqual(ctx.store.get_schedule(sid)["unit"], f"rabota-sched-quantivly-{sid}-a2.service")
        self.finish(ctx, sid, 2)
        self.tick(ctx, settled + schedule.RETRY_DELAY + 10 * MIN)
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["outcome"], row["attempt"]), ("failed", "could-not-run", 2))
        (esc,) = self.escs(ctx)
        self.assertEqual(esc["id"], row["escalation_id"])
        rec = self.record.read_text()
        self.assertIn(f"<!-- rabota-schedule:{sid}:1 -->", rec)
        self.assertIn(f"<!-- rabota-schedule:{sid}:2 -->", rec)
        self.assertIn("(attempt 1 of 2, retrying)", rec)

    def test_a_unit_that_left_no_exit_status_could_not_run(self):
        ctx = self.tctx(); sid = self.run_once(ctx, None)
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["attempt"]), ("pending", 1))
        self.assertIn("left no exit status", row["last_reason"])

    def test_a_notification_is_sent_once_per_escalation_never_per_tick(self):
        ctx = self.tctx(); self.run_once(ctx, 1)
        for k in range(2, 8):
            self.tick(ctx, DUE + k * 10 * MIN)
        self.assertEqual((len(self.runner.of("notify-send")), len(self.runner.of("herdr"))), (1, 1))

    def test_a_live_unit_is_never_settled_even_with_an_exit_status(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        self.tick(ctx, DUE)
        self.finish(ctx, sid, 0, keep_live=True)
        rep = self.tick(ctx, DUE + 10 * MIN)
        self.assertEqual((rep["settled"], ctx.store.get_schedule(sid)["status"]), ([], "running"))

    def test_a_deactivating_unit_is_still_live_and_an_inactive_one_is_not(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        self.tick(ctx, DUE)
        unit = self.finish(ctx, sid, 0, keep_live=True)["unit"]
        self.runner.states[unit] = "deactivating"            # a RuntimeMaxSec stop, still in progress
        self.assertEqual(self.tick(ctx, DUE + 10 * MIN)["settled"], [])
        self.runner.states[unit] = "inactive"                 # stopped but not yet collected
        self.assertEqual([r["id"] for r in self.tick(ctx, DUE + 20 * MIN)["settled"]], [sid])

    def test_unknown_unit_state_settles_nothing(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        self.tick(ctx, DUE)
        self.finish(ctx, sid, 0)
        self.runner.units_fail = True
        with self.assertRaises(errors.Partial) as cm:
            self.tick(ctx, DUE + 10 * MIN)
        self.assertIn("not knowing is not finished", cm.exception.failed[0]["error"])
        self.assertEqual(ctx.store.get_schedule(sid)["status"], "running")

    def test_a_tick_raised_escalation_is_listed_with_every_other_kind(self):
        ctx = self.tctx(); sid = self.run_once(ctx, 1)
        other = escalate.run_escalate(ctx, "merge?", "e", ["merge"], kind="decision")["id"]
        listed = escalations.run_escalations(ctx, open_only=True, text=True)
        self.assertTrue(any(l.startswith("ESC-") and f"[scheduled-run] {sid}" in l for l in listed), listed)
        self.assertTrue(any(l.startswith(f"ESC-{other} [decision]") for l in listed), listed)
        md = brief.compose_markdown(seq(["K-1"]), None, [], self.escs(ctx))
        needs_you = md.split("## Needs you\n", 1)[1].split("\n## ", 1)[0]
        self.assertIn(f"[scheduled-run] {sid} ·", needs_you)
        self.assertIn(f"ESC-{other} [decision]", needs_you)


class RecordTests(TickBase):
    """§6 step 3: keyed, idempotent, at the marker or the end, through emit, redacted, never forged."""

    def test_a_crash_before_the_row_write_repeats_nothing(self):
        ctx = self.tctx(); sid = self.declare(ctx, record=str(self.record))
        self.tick(ctx, DUE); self.finish(ctx, sid, 1)
        real = ctx.store.update_schedule_where
        calls = iter([RuntimeError("crash before the row write")])

        def once(*a, **kw):
            boom = next(calls, None)
            if boom is not None:
                raise boom
            return real(*a, **kw)
        with mock.patch.object(ctx.store, "update_schedule_where", side_effect=once):
            with self.assertRaises(errors.Partial):
                self.tick(ctx, DUE + 10 * MIN)
        self.assertEqual(ctx.store.get_schedule(sid)["status"], "running")    # the row write never happened
        self.tick(ctx, DUE + 20 * MIN)                                       # ...so the next tick redoes the step
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["outcome"]), ("done", "fail"))
        self.assertEqual(self.record.read_text().count(f"<!-- rabota-schedule:{sid}:1 -->"), 1)
        (esc,) = self.escs(ctx)
        self.assertEqual(esc["id"], row["escalation_id"])                     # adopted, not raised again
        self.assertEqual(len(self.runner.of("notify-send")), 1)

    def test_a_repeated_append_with_the_same_key_writes_nothing(self):
        ctx = self.tctx(); sid = self.declare(ctx, record=str(self.record))
        row = ctx.store.get_schedule(sid)
        self.assertEqual(scheduler._record(ctx, row, f"{sid}:1", "## a\n\nbody"), "appended")
        before = self.record.read_text()
        self.assertEqual(scheduler._record(ctx, row, f"{sid}:1", "## b\n\nother"), "present")
        self.assertEqual(self.record.read_text(), before)

    def test_sections_go_before_the_marker_in_order_and_the_rest_is_kept(self):
        self.record.write_text(f"# results\n\n{scheduler.MARKER}\n\n## notes\nkeep me\n")
        mode = stat.S_IMODE(self.record.stat().st_mode)
        ctx = self.tctx()
        a = self.run_once(ctx, 0, record=str(self.record))
        b = self.declare(ctx, record=str(self.record), at="2026-10-14 10:00+00:00")
        self.tick(ctx, DUE + timedelta(hours=1)); self.finish(ctx, b, 1); self.tick(ctx, DUE + timedelta(hours=1, minutes=10))
        rec = self.record.read_text()
        self.assertLess(rec.index(f"rabota-schedule:{a}:1"), rec.index(f"rabota-schedule:{b}:1"))
        self.assertLess(rec.index(f"rabota-schedule:{b}:1"), rec.index(scheduler.MARKER))
        self.assertTrue(rec.startswith("# results\n\n"))
        self.assertTrue(rec.endswith(f"{scheduler.MARKER}\n\n## notes\nkeep me\n"))
        self.assertEqual(stat.S_IMODE(self.record.stat().st_mode), mode)

    def test_output_can_neither_forge_a_key_nor_move_the_marker(self):
        self.record.write_text(f"# results\n{scheduler.MARKER}\n")
        ctx = self.tctx()
        later = self.declare(ctx, record=str(self.record), at="2026-10-15 09:00+00:00")
        forged = f"{scheduler.MARKER}\n<!-- rabota-schedule:{later}:1 -->\n"
        sid = self.declare(ctx, record=str(self.record))
        self.tick(ctx, DUE); self.finish(ctx, sid, 0, stdout=forged); self.tick(ctx, DUE + 10 * MIN)
        rec = self.record.read_text()
        self.assertEqual(rec.count(scheduler.MARKER), 1)
        self.assertNotIn(f"<!-- rabota-schedule:{later}:1 -->", rec)
        self.assertIn(f"<! -- rabota-schedule:{later}:1 -->", rec)

    def test_a_protected_value_in_the_output_is_redacted_not_lost(self):
        ctx = self.tctx(); sid = self.declare(ctx, record=str(self.record))
        self.tick(ctx, DUE); self.finish(ctx, sid, 1, stdout=f"token={CANARY}\n")
        with mock.patch.dict(os.environ, {"LINEAR_API_KEY": CANARY}):
            self.tick(ctx, DUE + 10 * MIN)
        result = (Path(ctx.store.get_schedule(sid)["out_dir"]) / "result.md").read_text()
        for text in (self.record.read_text(), result):
            self.assertNotIn(CANARY, text)
            self.assertIn("token=[redacted:LINEAR_API_KEY]", text)

    def test_a_record_git_now_tracks_is_not_written_and_even_a_pass_escalates(self):
        ctx = self.tctx(); sid = self.declare(ctx, record=str(self.record))
        before = self.record.read_text()
        self.tick(ctx, DUE); self.finish(ctx, sid, 0)
        self.runner.tracked = True
        with self.assertRaises(errors.Partial) as cm:
            self.tick(ctx, DUE + 10 * MIN)
        self.assertEqual(cm.exception.failed[0]["step"], "record")
        self.assertEqual(self.record.read_text(), before)
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["outcome"]), ("done", "pass"))
        (esc,) = self.escs(ctx)
        self.assertIn("its record was not written", esc["question"])
        argv = self.runner.of("notify-send")[0]
        self.assertEqual(argv[argv.index("--urgency") + 1], "normal")


class ConcurrencyTests(TickBase):
    """§10 "Concurrency and crashes"."""

    def test_a_held_lock_makes_a_tick_do_nothing(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        fd = os.open(ctx.state_dir / scheduler.LOCK, os.O_RDWR | os.O_CREAT); self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX)
        rep = self.tick(ctx, DUE)
        self.assertIn("another tick holds the lock", rep["locked"])
        self.assertEqual((self.runner.of("systemd-run"), ctx.store.get_schedule(sid)["status"]), ([], "pending"))

    def test_a_duplicate_tick_claims_nothing_twice(self):
        ctx = self.tctx(); self.declare(ctx)
        self.tick(ctx, DUE); self.tick(ctx, DUE)
        self.assertEqual(len(self.runner.of("systemd-run")), 1)

    def test_a_claim_on_a_row_that_stopped_being_pending_starts_nothing(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        stale = ctx.store.get_schedule(sid)
        self.tick(ctx, DUE)                                      # the real claim
        real = ctx.store.list_schedules
        with mock.patch.object(ctx.store, "list_schedules",
                               side_effect=lambda t=None, s=None: [stale] if s == "pending" else real(t, s)):
            self.tick(ctx, DUE)                                  # dispatch reads the stale pending copy
        self.assertEqual(len(self.runner.of("systemd-run")), 1)
        self.assertEqual(ctx.store.get_schedule(sid)["attempt"], 1)

    def test_a_crash_after_systemd_run_is_adopted_not_rerun(self):
        ctx = self.tctx(); sid = self.declare(ctx)

        def crash(argv):
            raise KeyboardInterrupt("the tick dies the instant systemd-run returns")
        self.runner.on_start = crash
        with self.assertRaises(KeyboardInterrupt):
            self.tick(ctx, DUE)
        self.runner.on_start = None
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["attempt"]), ("running", 1))
        self.tick(ctx, DUE + 10 * MIN)                           # its unit is still running: left alone
        self.finish(ctx, sid, 0)
        self.tick(ctx, DUE + 20 * MIN)                           # it finished: settled from what it left
        self.assertEqual(ctx.store.get_schedule(sid)["outcome"], "pass")
        self.assertEqual(len(self.runner.of("systemd-run")), 1)

    def test_a_crash_before_systemd_run_settles_as_one_attempt_never_a_blind_rerun(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        with mock.patch.object(scheduler, "command_argv", side_effect=KeyboardInterrupt("dies before the start")):
            with self.assertRaises(KeyboardInterrupt):
                self.tick(ctx, DUE)
        self.assertEqual(ctx.store.get_schedule(sid)["status"], "running")
        rep = self.tick(ctx, DUE + 10 * MIN)
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["attempt"], rep["dispatched"]), ("pending", 1, []))
        self.assertEqual(self.runner.of("systemd-run"), [])

    def test_a_failed_systemd_run_is_reported_and_settled_by_the_next_tick(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        self.runner.start = Result(1, "", "Failed to start transient service unit: Unit already exists.")
        with self.assertRaises(errors.Partial) as cm:
            self.tick(ctx, DUE)
        self.assertIn("systemd-run failed (exit 1)", cm.exception.failed[0]["error"])
        self.runner.start = Result(0, "", "")
        self.tick(ctx, DUE + 10 * MIN)
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["attempt"]), ("pending", 1))
        self.assertIn("Unit already exists", row["last_reason"])

    def test_one_failing_row_does_not_stop_the_next(self):
        ctx = self.tctx(); bad = self.declare(ctx); good = self.declare(ctx)
        real = scheduler._dispatch_command

        def flaky(c, row, now, rep):
            if row["id"] == bad:
                raise OSError("disk full")
            return real(c, row, now, rep)
        with mock.patch.object(scheduler, "_dispatch_command", side_effect=flaky):
            with self.assertRaises(errors.Partial) as cm:
                self.tick(ctx, DUE)
        self.assertEqual([(f["step"], f["id"]) for f in cm.exception.failed], [("dispatch", bad)])
        self.assertEqual(ctx.store.get_schedule(good)["status"], "running")


class DeferralTests(TickBase):
    """§10 "a deferral leaves attempt unchanged". In phase 1 the deferral is an agent row's."""

    def test_an_agent_run_is_deferred_never_dispatched_and_expires_naming_why(self):
        ctx = self.tctx(); sid = self.declare(ctx, prompt_file=str(self.prompt))
        for k in range(3):
            rep = self.tick(ctx, DUE + k * 10 * MIN)
            self.assertEqual(rep["deferred"], [{"id": sid, "reason": scheduler.AGENT_DEFERRAL}])
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["attempt"], row["last_reason"]), ("pending", 0, scheduler.AGENT_DEFERRAL))
        self.assertEqual(self.runner.of("systemd-run"), [])
        self.tick(ctx, DUE + timedelta(hours=48))
        row = ctx.store.get_schedule(sid)
        self.assertEqual((row["status"], row["attempt"]), ("expired", 0))
        (esc,) = self.escs(ctx)
        self.assertIn("no executor until phase 2", esc["question"])


class AnswerTests(TickBase):
    """§10 "Answers and follow-ups" (the non-agent rows), and answer's contract for everything else."""

    def failed(self, ctx, **kw):
        sid = self.run_once(ctx, 1, record=str(self.record), **kw)
        return sid, ctx.store.get_schedule(sid)["escalation_id"]

    def count(self, ctx):
        return len(ctx.store.list_schedules())

    def test_rerun_plus_24h_enqueues_exactly_one_run(self):
        ctx = self.tctx(); sid, eid = self.failed(ctx, ask="Ship it?", options=["yes", "again=rerun:+24h"])
        n, t0 = self.count(ctx), datetime.now(timezone.utc).replace(microsecond=0)
        out = escalate.run_answer(ctx, eid, "again")
        t1 = datetime.now(timezone.utc)
        self.assertEqual(self.count(ctx), n + 1)
        new = ctx.store.get_schedule(out["enqueued"])
        parent = ctx.store.get_schedule(sid)
        self.assertEqual((new["status"], new["attempt"], new["kind"], new["title"]), ("pending", 0, "command", parent["title"]))
        due = scheduler._parse(new["not_before"])
        self.assertTrue(t0 + timedelta(hours=24) <= due <= t1 + timedelta(hours=24), (t0, due, t1))
        self.assertEqual(new["payload_source"], parent["payload_path"])
        self.assertEqual(Path(new["payload_path"]).parent, ctx.state_dir / "schedules" / new["id"])
        self.assertEqual((new["payload_sha256"], Path(new["payload_path"]).read_bytes()),
                         (parent["payload_sha256"], Path(parent["payload_path"]).read_bytes()))
        self.assertEqual(new["options"], parent["options"])
        self.assertEqual(ctx.store.escalation(eid)["disposition"], "again")
        self.assertIn(f"decided: again, @zvi, ", self.record.read_text())
        self.assertIn(f"enqueued {new['id']}", self.record.read_text())
        jsonl = (ctx.state_dir / "escalations.jsonl").read_text().splitlines()
        self.assertEqual(json.loads(jsonl[-1])["disposition"], "again")
        with self.assertRaises(errors.Refused):
            escalate.run_answer(ctx, eid, "again")              # answered once; the second enqueues nothing
        self.assertEqual(self.count(ctx), n + 1)
        self.tick(ctx, due); self.tick(ctx, due)
        starts = [a for a in self.runner.of("systemd-run") if new["id"] in a[3]]
        self.assertEqual(len(starts), 1)
        self.assertIn(new["payload_path"], starts[0])

    def test_an_undeclared_or_textual_option_executes_nothing(self):
        ctx = self.tctx()
        sid, eid = self.failed(ctx, ask="Roll back?", options=["rerun:+1h", "systemctl --user restart x", "ack=none"])
        n = self.count(ctx)
        for label in ("rerun:+1h",):
            self.assertEqual(scheduler.action_for(ctx.store.get_schedule(sid), label), "none")
        out = escalate.run_answer(ctx, eid, "rerun:+1h")
        self.assertEqual((out["action"], out["enqueued"], out["cancelled"]), ("none", None, []))
        self.assertEqual(self.count(ctx), n)
        self.assertFalse([c for c in self.runner.calls if "restart" in c])
        self.assertIn("decided: rerun:+1h, @zvi, ", self.record.read_text())
        self.assertEqual(scheduler.action_for(ctx.store.get_schedule(sid), "not an option"), "none")

    def test_without_declared_options_the_defaults_are_offered_and_re_run_now_is_due_at_once(self):
        ctx = self.tctx(); sid, eid = self.failed(ctx)
        self.assertEqual(ctx.store.escalation(eid)["options"], ["acknowledge", "re-run now", "cancel follow-ups"])
        t0 = datetime.now(timezone.utc).replace(microsecond=0)
        new = ctx.store.get_schedule(escalate.run_answer(ctx, eid, "re-run now")["enqueued"])
        self.assertLessEqual(scheduler._parse(new["not_before"]) - t0, timedelta(seconds=5))

    def test_cancel_followups_cancels_pending_runs_frozen_from_this_one_and_clears_then_on(self):
        ctx = self.tctx(); sid, eid = self.failed(ctx)
        parent = ctx.store.get_schedule(sid)
        ctx.store.update_schedule(sid, then_on="fail")
        child = {**parent, "id": "s-0000000c", "status": "pending", "attempt": 0, "payload_source": parent["payload_path"],
                 "escalation_id": None, "unit": None, "out_dir": None, "outcome": None}
        ctx.store.insert_schedule(child)
        other = self.declare(ctx, at="2026-10-16 09:00+00:00")
        out = escalate.run_answer(ctx, eid, "cancel follow-ups")
        self.assertEqual((out["action"], out["cancelled"], out["enqueued"]), ("cancel-followups", ["s-0000000c"], None))
        self.assertEqual(ctx.store.get_schedule("s-0000000c")["status"], "cancelled")
        self.assertEqual(ctx.store.get_schedule(other)["status"], "pending")
        self.assertIsNone(ctx.store.get_schedule(sid)["then_on"])

    def test_rerun_refuses_a_changed_payload_and_leaves_the_escalation_open(self):
        ctx = self.tctx(); sid, eid = self.failed(ctx)
        p = Path(ctx.store.get_schedule(sid)["payload_path"]); p.chmod(0o700); p.write_text("#!/bin/sh\n")
        n = self.count(ctx)
        with self.assertRaises(errors.Refused) as cm:
            escalate.run_answer(ctx, eid, "re-run now")
        self.assertIn("changed after it was frozen", str(cm.exception))
        self.assertEqual((self.count(ctx), ctx.store.escalation(eid)["resolved_at"]), (n, None))

    def test_rerun_refuses_a_disarmed_timer(self):
        ctx = self.tctx(); sid, eid = self.failed(ctx)
        self.runner.responses.insert(0, (["systemctl", "--user", "is-enabled"], Result(1, "disabled\n", "")))
        with self.assertRaises(errors.Refused) as cm:
            escalate.run_answer(ctx, eid, "re-run now")
        self.assertIn("is not enabled", str(cm.exception))
        self.assertIsNone(ctx.store.escalation(eid)["resolved_at"])

    def test_a_rerun_horizon_past_30_days_is_refused_when_declared(self):
        with self.assertRaises(errors.Usage) as cm:
            schedule.parse_option("later=rerun:+31d")
        self.assertIn("horizon", str(cm.exception))
        self.assertEqual(schedule.parse_option("later=rerun:+30d")["action"], "rerun:+30d")

    def test_a_stored_rerun_past_the_horizon_is_refused_at_answer_time(self):
        ctx = self.tctx(); sid, eid = self.failed(ctx, ask="Again?", options=["far=rerun:+30d"])
        ctx.store.update_schedule(sid, options=[{"label": "far", "action": "rerun:+31d"}])   # stored before the check
        n = self.count(ctx)
        with self.assertRaises(errors.Refused) as cm:
            escalate.run_answer(ctx, eid, "far")
        self.assertIn("past the 30-day horizon", str(cm.exception))
        self.assertEqual((self.count(ctx), ctx.store.escalation(eid)["resolved_at"]), (n, None))

    def test_a_leak_in_the_answer_refuses_before_its_action_commits(self):
        ctx = self.tctx(); sid, eid = self.failed(ctx)
        before, n = self.record.read_text(), self.count(ctx)
        with mock.patch.dict(os.environ, {"LINEAR_API_KEY": CANARY}):
            with self.assertRaises(errors.SecretLeak):
                escalate.run_answer(ctx, eid, "re-run now", resolution=f"see {CANARY}")
        self.assertEqual((self.count(ctx), self.record.read_text()), (n, before))
        self.assertIsNone(ctx.store.escalation(eid)["resolved_at"])
        self.assertEqual(sorted(p.name for p in (ctx.state_dir / "schedules").iterdir()),
                         sorted(r["id"] for r in ctx.store.list_schedules()))     # no orphaned frozen copy

    def test_a_hand_made_scheduled_run_escalation_executes_nothing(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        eid = escalate.run_escalate(ctx, "q", "e", ["re-run now"], kind="scheduled-run", subject=sid)["id"]
        n = self.count(ctx)
        self.assertEqual(escalate.run_answer(ctx, eid, "re-run now"), {"id": eid, "disposition": "re-run now"})
        self.assertEqual(self.count(ctx), n)

    def test_answer_keeps_its_contract_for_every_other_escalation(self):
        ctx = self.tctx(); self.declare(ctx)
        eid = escalate.run_escalate(ctx, "merge HUB-1?", "e", ["merge", "wait"], kind="decision")["id"]
        calls, n = len(self.runner.calls), self.count(ctx)
        self.assertEqual(escalate.run_answer(ctx, eid, "merge"), {"id": eid, "disposition": "merge"})
        self.assertEqual((self.count(ctx), self.runner.calls[calls:]), (n, []))
        last = json.loads((ctx.state_dir / "escalations.jsonl").read_text().splitlines()[-1])
        self.assertEqual((last["disposition"], last["kind"]), ("merge", "decision"))

    def test_a_dry_run_answer_writes_nothing(self):
        ctx = self.tctx(); sid, eid = self.failed(ctx)
        before, n = self.record.read_text(), self.count(ctx)
        ctx.dry_run = True
        out = escalate.run_answer(ctx, eid, "re-run now")
        self.assertIn("nothing written", out["dry_run"])
        self.assertEqual((self.count(ctx), self.record.read_text()), (n, before))
        self.assertIsNone(ctx.store.escalation(eid)["resolved_at"])


class ExportTests(TickBase):
    """§6 "The export": every tenant, versioned, redacted, and never a result body."""

    def export(self):
        return json.loads(scheduler.export_path().read_text())

    def test_the_tick_exports_every_tenant_versioned_and_without_result_bodies(self):
        q = self.tctx(); sid = self.declare(q, ask="Ship it?", options=["yes"])
        t = self.ctx(tenant="toysim", runner=self.runner); tid = self.declare(t, at="2026-10-15 09:00+00:00")
        self.tick(q, DUE); self.finish(q, sid, 1, stdout=f"BODY-{CANARY}\n"); self.tick(q, DUE + 10 * MIN)
        doc = self.export()
        self.assertEqual(doc["version"], scheduler.EXPORT_VERSION)
        self.assertEqual({k: v["ok"] for k, v in doc["tenants"].items()}, {"personal": True, "quantivly": True, "toysim": True})
        rows = {r["id"]: r for r in doc["schedules"]}
        self.assertEqual(set(rows), {sid, tid})
        self.assertEqual((rows[sid]["status"], rows[sid]["outcome"]), ("done", "fail"))
        self.assertEqual(rows[sid]["escalation"]["options"], ["yes"])
        self.assertTrue(rows[sid]["escalation"]["open"])
        self.assertTrue(rows[sid]["escalation"]["question"].endswith("Ship it?"))
        text = scheduler.export_path().read_text()
        out_dir = q.store.get_schedule(sid)["out_dir"]
        for absent in ("BODY-", "result.md", out_dir, "stdout.log", str(self.work)):
            self.assertNotIn(absent, text)
        self.assertEqual(set(rows[sid]), set(scheduler.EXPORT_FIELDS) | {"escalation"})

    def test_add_cancel_and_an_answer_rewrite_the_export(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        self.assertEqual([r["status"] for r in self.export()["schedules"]], ["pending"])
        schedule.run_cancel(ctx, sid, now=NOW)
        self.assertEqual([r["status"] for r in self.export()["schedules"]], ["cancelled"])
        fid = self.run_once(ctx, 1)
        eid = ctx.store.get_schedule(fid)["escalation_id"]
        escalate.run_answer(ctx, eid, "acknowledge")
        self.assertFalse({r["id"]: r for r in self.export()["schedules"]}[fid]["escalation"]["open"])

    def test_the_export_is_redacted_field_by_field(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        ctx.store.update_schedule(sid, last_reason=f"reason with {CANARY}")     # stored before the env held it
        with mock.patch.dict(os.environ, {"LINEAR_API_KEY": CANARY}):
            scheduler.write_export(ctx.cfg, NOW)
        text = scheduler.export_path().read_text()
        self.assertNotIn(CANARY, text)
        self.assertIn("[redacted:LINEAR_API_KEY]", text)

    def test_an_unreadable_tenant_store_is_named_not_dropped_and_fails_no_tick(self):
        t = self.ctx(tenant="toysim", runner=self.runner); self.declare(t)
        t.store.conn.execute("UPDATE schema_version SET version=99"); t.close()
        q = self.tctx(); self.declare(q)
        rep = self.tick(q, DUE)
        self.assertEqual(rep["export"]["failed"], ["toysim"])
        self.assertFalse(self.export()["tenants"]["toysim"]["ok"])

    def test_a_settled_row_leaves_the_export_after_the_window(self):
        ctx = self.tctx(); sid = self.run_once(ctx, 0)
        ended = scheduler._parse(ctx.store.get_schedule(sid)["ended_at"])
        scheduler.write_export(ctx.cfg, ended + scheduler.EXPORT_WINDOW)
        self.assertEqual([r["id"] for r in self.export()["schedules"]], [sid])
        scheduler.write_export(ctx.cfg, ended + scheduler.EXPORT_WINDOW + timedelta(seconds=1))
        self.assertEqual(self.export()["schedules"], [])


class UnitAndCliTests(TickBase):
    """The units and their link, and the tick through ``cli.main``, the timer's own path."""

    def unit(self, name):
        p = configparser.ConfigParser(interpolation=None, strict=False)
        p.optionxform = str
        p.read(REPO / "systemd" / name)
        return p

    def test_the_units_exist_with_the_designed_settings(self):
        timer = self.unit("rabota-schedule@.timer")["Timer"]
        self.assertEqual((timer["OnCalendar"], timer["Persistent"], timer["RandomizedDelaySec"], timer["Unit"]),
                         ("*:0/10", "true", "30", "rabota-schedule@%i.service"))
        svc = self.unit("rabota-schedule@.service")["Service"]
        self.assertEqual((svc["Type"], svc["ExecStart"], svc["TimeoutStartSec"], svc["Nice"]),
                         ("oneshot", "%h/.local/bin/rabota --tenant %i schedule tick", "5min", "10"))
        self.assertIn("%h/.local/bin", svc["Environment"])
        self.assertEqual(schedule.timer_unit("quantivly"), "rabota-schedule@quantivly.timer")

    def test_install_links_both_units_and_enables_neither(self):
        conf = (REPO / "install.conf.yaml").read_text()
        for name in ("rabota-schedule@.service", "rabota-schedule@.timer"):
            self.assertIn(f"~/.config/systemd/user/{name}: systemd/{name}", conf)
        lines = [l for l in conf.splitlines() if "rabota-schedule" in l and not l.lstrip().startswith("#")]
        self.assertEqual(len(lines), 2, lines)

    def cli(self, *argv):
        with mock.patch("rabota.context.SubprocessRunner", lambda env: self.runner):
            return run_cli(["--tenant", "quantivly", *argv])

    def test_the_service_exec_start_is_a_command_cli_main_runs(self):
        code, out, err = self.cli("schedule", "tick")
        self.assertEqual(code, 0, err)
        self.assertEqual(last_json(out)["tenant"], "quantivly")
        code, out, err = self.cli("--text", "schedule", "tick")
        self.assertEqual(code, 0, err)
        self.assertRegex(out.splitlines()[0], r"^tick quantivly .*: 0 settled, 0 expired, 0 refused, 0 dispatched, 0 deferred$")

    def test_tick_refuses_dry_run(self):
        code, _, err = self.cli("--dry-run", "schedule", "tick")
        self.assertEqual(code, 2)
        self.assertIn("has no --dry-run", err)

    def test_a_failing_tick_exits_4(self):
        ctx = self.tctx(); sid = self.declare(ctx)
        ctx.store.update_schedule(sid, status="running", unit="rabota-sched-x.service", out_dir=str(self.work / "o"))
        ctx.close()
        self.runner.units_fail = True
        code, _, err = self.cli("schedule", "tick")
        self.assertEqual(code, 4)
        self.assertEqual(last_json(err)["error"]["code"], "partial")


if __name__ == "__main__":
    unittest.main()
