import argparse, json, os, tempfile, unittest
from pathlib import Path
from rabota import census, context
from rabota.runner import FakeRunner, Result
from tests.test_remote import payload

FIX = Path(__file__).parent / "fixtures"

def fake_proc(root: Path, pid: int, comm: str, cwd: str, cgroup: str, utime: int = 10):
    d = root / str(pid); d.mkdir(parents=True)
    (d / "comm").write_text(comm + "\n")
    (d / "cgroup").write_text(f"0::{cgroup}\n")
    fields = ["0"] * 52; fields[13], fields[14], fields[21] = str(utime), "0", "100"
    (d / "stat").write_text(f"{pid} ({comm}) S " + " ".join(fields[3:]) + "\n")
    os.symlink(cwd, d / "cwd")

class CensusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.proc = Path(self.tmp.name) / "proc"
        (self.proc).mkdir()
        (self.proc / "uptime").write_text("1000.0 800.0\n"); (self.proc / "loadavg").write_text("1.9 2.0 2.0 1/10 1\n")
        (self.proc / "meminfo").write_text("MemTotal: 31457280 kB\nMemAvailable: 18000000 kB\nSwapTotal: 24117248 kB\nSwapFree: 18000000 kB\n")
        fake_proc(self.proc, 111, "claude", "/home/zvi/quantivly/hub", "/user.slice/user-1000.slice/user@1000.service/app.slice/herdr-server.service")
        fake_proc(self.proc, 222, "claude", "/home/zvi/.nanoclaw/orchestrate/lanes/IMP-1", "/user.slice/user-1000.slice/user@1000.service/app.slice/nanoclaw-orchestrate.service")
        fake_proc(self.proc, 333, "claude", "/home/zvi/.nanoclaw/orchestrate/lanes/IMP-2", "/user.slice/user-1000.slice/user@1000.service/session-3.scope")  # attached user session in a lane cwd
        fake_proc(self.proc, 444, "claude", "/home/zvi/.local/state/rabota/worktrees/quantivly/smoke", "/user.slice/user-1000.slice/user@1000.service/app.slice/rabota-lane-quantivly-smoke-9b221b43.service")
        fake_proc(self.proc, 555, "node", "/x", "/user.slice/x")
        # A headless lane execs the VERSIONED binary, so its comm is the version string, not "claude"
        # (measured 2026-09-16: this lane's own process was `2.1.273` inside rabota-impl-ws4p.service).
        fake_proc(self.proc, 666, "2.1.273", "/home/zvi/.local/state/rabota-impl/ws4p", "/user.slice/user-1000.slice/user@1000.service/app.slice/rabota-impl-ws4p.service")
        fake_proc(self.proc, 777, "2.1", "/y", "/user.slice/y")          # not a version triple: not claude
        self.runner = FakeRunner([
            (["systemctl", "--user", "list-units"], Result(0, (FIX / "census" / "units.json").read_text(), "")),
            (["clauth", "status", "--json"], Result(0, (FIX / "census" / "clauth_status.json").read_text(), "")),
            (["wt-gc", "--tsv"], Result(0, (FIX / "census" / "wt_gc.tsv").read_text(), "")),
            # No lane is registered as "started" on the quantivly.toml fixture's "dev" machine in
            # this setUp, so census.machines() asks remote.read for zero out_dirs and no stream
            # section — streams=() keeps the reply's section count matching that request.
            (["ssh"], Result(0, payload(streams=()), "")),
        ])
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(self.tmp.name) / "s"), text=False, dry_run=False)
        self.ctx = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=self.runner, env={"PATH": "/bin"}, cwd=Path("/"))
        # Close the store this context opens: an unclosed sqlite connection is a ResourceWarning that
        # `python -m unittest` prints into whatever stderr is current — including another test's capture.
        self.addCleanup(lambda: self.ctx._store and self.ctx._store.close())

    def test_owner_by_cgroup_not_cwd(self):
        self.assertEqual(census.owner_of(self.proc, 222), "sol")
        self.assertEqual(census.owner_of(self.proc, 333), "user")
        self.assertEqual(census.owner_of(self.proc, 444), "rabota")
        self.assertEqual(census.owner_of(self.proc, 111), "user")
        # No such pid: not an error, and NOT a guess either — a process whose cgroup could not be
        # read has no owner this function can name (fix brief ws4p-fix, defect 3).
        self.assertEqual(census.owner_of(self.proc, 999), "unknown")

    def test_gather_shape_counts_seats_unavailable(self):
        c = census.gather(self.ctx, proc=self.proc, sample_seconds=0.01, sleeper=lambda s: None)
        self.assertEqual(c["schema"], 1)
        self.assertEqual(c["counts"], {"sessions": 5, "user": 2, "sol": 1, "rabota": 2, "unknown": 0, "units_active": 1})
        self.assertEqual({s["pid"] for s in c["sessions"]}, {111, 222, 333, 444, 666})   # 555/777 are not claude
        by_pid = {s["pid"]: s for s in c["sessions"]}
        self.assertEqual(by_pid[444]["unit"], "rabota-lane-quantivly-smoke-9b221b43.service")
        self.assertEqual(by_pid[222]["unit"], "nanoclaw-orchestrate.service")
        self.assertIsNone(by_pid[111]["unit"])
        self.assertEqual((by_pid[666]["owner"], by_pid[666]["unit"]), ("rabota", "rabota-impl-ws4p.service"))
        self.assertEqual(by_pid[111]["age_s"], 999)
        self.assertEqual(c["units"][0]["name"], "rabota-lane-quantivly-smoke-9b221b43.service")
        q1 = next(s for s in c["seats"] if s["name"] == "quantivly-1")
        self.assertEqual((q1["tier"], q1["five_h_pct"], q1["seven_d_pct"], q1["stale"]), ("Team", 38, 46, False))
        self.assertEqual(q1["resets_at"], "2026-09-16T17:59:59+00:00")
        q0 = next(s for s in c["seats"] if s["name"] == "quantivly-0")
        self.assertEqual((q0["stale"], q0["seven_d_pct"]), (True, None))
        self.assertIn("seat:quantivly-0:stale", c["unavailable"])
        self.assertIn("deferred:sol", c["unavailable"]); self.assertNotIn("deferred:machines", c["unavailable"])
        self.assertEqual(c["machine"]["ncpu"] > 0, True)
        self.assertEqual(c["machine"]["swap_used_pct"], 25)
        self.assertEqual(c["worktrees"][0]["verdict"], "KEEP")
        self.assertTrue((Path(self.tmp.name) / "s" / "census.json").exists())
        self.assertEqual(json.loads((Path(self.tmp.name) / "s" / "census.json").read_text())["counts"], c["counts"])
        for s in c["sessions"]: self.assertNotIn("argv", s); self.assertNotIn("env", s)

    def test_gather_writes_machines_into_the_contract_file(self):
        c = census.gather(self.ctx, proc=self.proc, sample_seconds=0.01, sleeper=lambda s: None)
        self.assertEqual([m["name"] for m in c["machines"]], ["dev"])
        self.assertTrue(c["machines"][0]["reachable"])
        # budget reads census.json, not gather()'s return value, so the key must survive the write.
        written = json.loads((Path(self.tmp.name) / "s" / "census.json").read_text())
        self.assertEqual(written["machines"], c["machines"])

    def test_an_unreachable_machine_reaches_the_contract_files_unavailable(self):
        # Prepended so it wins FakeRunner's prefix match over setUp's successful ssh reply.
        self.runner.responses.insert(0, (["ssh"], Result(255, "", "no route to host")))
        c = census.gather(self.ctx, proc=self.proc, sample_seconds=0.01, sleeper=lambda s: None)
        self.assertFalse(c["machines"][0]["reachable"])
        self.assertIn("machine:dev", c["unavailable"])
        written = json.loads((Path(self.tmp.name) / "s" / "census.json").read_text())
        self.assertIn("machine:dev", written["unavailable"])

    # A failing per-pid reader must never GUESS (fix brief ws4p-fix, defect 3; review attack a5).
    # The evaluator reached these with chmod 000 on a fixture; on this box they are latent (no
    # hidepid), but "an unmeasured dimension is a refusal, never a zero" (design §4.2) applies to
    # a session's owner as much as to a seat's window. The shape is one count per reader:
    # `sessions:<n>:<reader>` — per-pid entries would flood unavailable[] on a hidepid=1 box,
    # where every other user's process is an unreadable comm.
    def _gather(self):
        return census.gather(self.ctx, proc=self.proc, sample_seconds=0.01, sleeper=lambda s: None)

    @unittest.skipIf(os.geteuid() == 0, "root reads a mode-000 file; the fixture cannot fail")
    def test_unreadable_cgroup_is_unknown_and_named_not_user(self):
        fake_proc(self.proc, 888, "claude", "/home/zvi/z", "/user.slice/user-1000.slice/user@1000.service/app.slice/rabota-lane-quantivly-z-1.service")
        cg = self.proc / "888" / "cgroup"
        cg.chmod(0); self.addCleanup(cg.chmod, 0o644)
        self.assertEqual(census.owner_of(self.proc, 888), "unknown")
        c = self._gather()
        by_pid = {s["pid"]: s for s in c["sessions"]}
        self.assertIn(888, by_pid)                                    # carried, not dropped
        self.assertEqual((by_pid[888]["owner"], by_pid[888]["unit"]), ("unknown", None))
        self.assertIn("sessions:1:cgroup", c["unavailable"])
        self.assertEqual(c["counts"]["unknown"], 1)
        self.assertEqual(c["counts"]["sessions"], 6)
        self.assertEqual((c["counts"]["user"], c["counts"]["rabota"]), (2, 2))   # the guess is not counted anywhere

    @unittest.skipIf(os.geteuid() == 0, "root reads a mode-000 directory; the fixture cannot fail")
    def test_unreadable_proc_dir_is_counted_not_silently_dropped(self):
        fake_proc(self.proc, 889, "claude", "/home/zvi/z", "/user.slice/x")
        d = self.proc / "889"
        d.chmod(0); self.addCleanup(d.chmod, 0o755)
        c = self._gather()
        self.assertNotIn(889, {s["pid"] for s in c["sessions"]})     # its comm could not be read, so it is not known to be claude
        self.assertIn("sessions:1:comm", c["unavailable"])
        self.assertEqual(c["counts"]["sessions"], 5)

    def test_unreadable_cwd_is_counted_not_silently_dropped(self):
        fake_proc(self.proc, 890, "claude", "/home/zvi/z", "/user.slice/x")
        (self.proc / "890" / "cwd").unlink(); (self.proc / "890" / "cwd").write_text("not a link\n")   # readlink -> EINVAL
        c = self._gather()
        self.assertNotIn(890, {s["pid"] for s in c["sessions"]})
        self.assertIn("sessions:1:cwd", c["unavailable"])

    def test_a_vanished_pid_is_not_a_failure(self):
        # Between listing and reading, a process may exit: that is a vanish, not an unmeasured
        # dimension, and must not put a phantom entry into unavailable[].
        real = census._stat
        def stat_then_vanish(proc, pid):
            if pid == 111:
                raise FileNotFoundError(f"{proc}/{pid}/stat")
            return real(proc, pid)
        census._stat = stat_then_vanish; self.addCleanup(setattr, census, "_stat", real)
        c = self._gather()
        self.assertNotIn(111, {s["pid"] for s in c["sessions"]})
        self.assertEqual([u for u in c["unavailable"] if u.startswith("sessions:")], [])

    def test_seats_unavailable_when_clauth_fails(self):
        runner = FakeRunner([(["clauth", "status", "--json"], Result(127, "", "not found"))])
        seats, unavailable = census.seats(runner)
        self.assertEqual(seats, []); self.assertEqual(unavailable, ["seats"])
        runner = FakeRunner([(["clauth", "status", "--json"], Result(0, "{not json", ""))])
        self.assertEqual(census.seats(runner), ([], ["seats"]))

    def test_units_and_worktrees_unavailable_on_failure(self):
        self.assertEqual(census.units(FakeRunner([(["systemctl"], Result(1, "", "Failed to connect to bus"))])), ([], ["units"]))
        self.assertEqual(census.worktrees(FakeRunner([(["wt-gc"], Result(127, "", "not found"))])), ([], ["worktrees"]))

    # F24: a cheap mode that skips the worktree dimension entirely — that is where the minute goes
    # in the pre-compute chain (wt-gc shells out to `gh` per worktree).
    def test_cheap_mode_makes_no_wt_gc_call(self):
        c = census.gather(self.ctx, proc=self.proc, sample_seconds=0.01, sleeper=lambda s: None, include_worktrees=False)
        self.assertFalse(any(argv[0] == "wt-gc" for argv in self.runner.calls), self.runner.calls)

    def test_cheap_mode_returns_empty_worktrees_with_skip_marker(self):
        c = census.gather(self.ctx, proc=self.proc, sample_seconds=0.01, sleeper=lambda s: None, include_worktrees=False)
        self.assertEqual(c["worktrees"], [])
        self.assertIn("skipped:worktrees", c["unavailable"])
        self.assertNotIn("worktrees", c["unavailable"])   # the skip marker, never the failure marker

    def test_default_mode_is_unchanged_still_calls_wt_gc_and_populates_worktrees(self):
        c = census.gather(self.ctx, proc=self.proc, sample_seconds=0.01, sleeper=lambda s: None)
        self.assertTrue(any(argv[0] == "wt-gc" for argv in self.runner.calls), self.runner.calls)
        self.assertEqual(c["worktrees"][0]["verdict"], "KEEP")
        self.assertNotIn("skipped:worktrees", c["unavailable"])

    def test_failed_wt_gc_in_default_mode_keeps_the_failure_marker_distinct_from_skip(self):
        runner = FakeRunner([
            (["systemctl", "--user", "list-units"], Result(0, (FIX / "census" / "units.json").read_text(), "")),
            (["clauth", "status", "--json"], Result(0, (FIX / "census" / "clauth_status.json").read_text(), "")),
            (["wt-gc", "--tsv"], Result(127, "", "not found")),
        ])
        ctx = self.ctx
        ctx.runner = runner
        c = census.gather(ctx, proc=self.proc, sample_seconds=0.01, sleeper=lambda s: None)
        self.assertEqual(c["worktrees"], [])
        self.assertIn("worktrees", c["unavailable"])
        self.assertNotIn("skipped:worktrees", c["unavailable"])

    def test_settle_finished_reads_result_line(self):
        out = Path(self.tmp.name) / "out" / "smoke"; out.mkdir(parents=True)
        (out / "stream.jsonl").write_text((FIX / "census" / "stream.jsonl").read_text())
        self.ctx.store.insert_lane({"id": "smoke", "tenant": "quantivly", "kind": "work", "brief": "b", "repo": "r", "worktree": "w",
                                    "out_dir": str(out), "machine": "local", "unit": "rabota-lane-quantivly-smoke-dead.service",
                                    "session_id": "s", "model": "m", "status": "started", "started_at": "2026-09-16T10:00:00Z",
                                    "seat": "quantivly-1", "effort": "high", "five_h_pct_at_start": 30})
        settled = census.settle_finished(self.ctx, units=[], seats=[{"name": "quantivly-1", "five_h_pct": 41}])
        self.assertEqual(settled, ["smoke"])
        row = self.ctx.store.get_lane("smoke")
        self.assertEqual((row["status"], row["cost_usd"], row["five_h_pct_at_end"]), ("done", 1.23, 41))
        self.assertIsNotNone(row["ended_at"])

    def test_cli_no_worktrees_flag_produces_the_cheap_shape(self):
        from rabota.commands import census as cmd
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(self.tmp.name) / "s2"), text=False,
                                dry_run=False, sample_seconds=0.01, no_worktrees=True)
        runner = FakeRunner([
            (["systemctl", "--user", "list-units"], Result(0, (FIX / "census" / "units.json").read_text(), "")),
            (["clauth", "status", "--json"], Result(0, (FIX / "census" / "clauth_status.json").read_text(), "")),
        ])
        c = cmd._run(ns, cfg_base=FIX / "config", runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))
        self.assertEqual(c["worktrees"], [])
        self.assertIn("skipped:worktrees", c["unavailable"])
        self.assertFalse(any(argv[0] == "wt-gc" for argv in runner.calls), runner.calls)

    def test_cli_plain_census_still_calls_wt_gc(self):
        from rabota.commands import census as cmd
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(self.tmp.name) / "s3"), text=False,
                                dry_run=False, sample_seconds=0.01, no_worktrees=False)
        runner = FakeRunner([
            (["systemctl", "--user", "list-units"], Result(0, (FIX / "census" / "units.json").read_text(), "")),
            (["clauth", "status", "--json"], Result(0, (FIX / "census" / "clauth_status.json").read_text(), "")),
            (["wt-gc", "--tsv"], Result(0, (FIX / "census" / "wt_gc.tsv").read_text(), "")),
        ])
        c = cmd._run(ns, cfg_base=FIX / "config", runner=runner, env={"PATH": "/bin"}, cwd=Path("/"))
        self.assertNotIn("skipped:worktrees", c["unavailable"])
        self.assertTrue(any(argv[0] == "wt-gc" for argv in runner.calls), runner.calls)

    def test_settle_leaves_live_units_and_streams_without_a_result_alone(self):
        out = Path(self.tmp.name) / "out" / "live"; out.mkdir(parents=True)
        (out / "stream.jsonl").write_text((FIX / "census" / "stream.jsonl").read_text())
        base = {"tenant": "quantivly", "kind": "work", "brief": "b", "repo": "r", "worktree": "w", "out_dir": str(out),
                "machine": "local", "session_id": "s", "model": "m", "status": "started", "started_at": "2026-09-16T10:00:00Z", "seat": "quantivly-1"}
        self.ctx.store.insert_lane({**base, "id": "live", "unit": "rabota-lane-quantivly-live-1.service"})
        norun = Path(self.tmp.name) / "out" / "norun"; norun.mkdir(parents=True)
        (norun / "stream.jsonl").write_text('{"type":"assistant","message":{}}\n')
        self.ctx.store.insert_lane({**base, "id": "norun", "out_dir": str(norun), "unit": "rabota-lane-quantivly-norun-1.service"})
        settled = census.settle_finished(self.ctx, units=[{"name": "rabota-lane-quantivly-live-1.service", "state": "active"}], seats=[])
        self.assertEqual(settled, [])
        self.assertEqual(self.ctx.store.get_lane("live")["status"], "started")
        self.assertEqual(self.ctx.store.get_lane("norun")["status"], "started")

    def test_gather_settles_a_remote_lane_end_to_end(self):
        # gather() must pass its OWN machines() reading into settle_finished — not call it bare —
        # or a lane that ran on "dev" never settles even though gather() just fetched its stream.
        self.ctx.store.insert_lane({"id": "remote1", "tenant": "quantivly", "kind": "work", "brief": "b",
                                    "repo": "hub", "worktree": "/w", "out_dir": "/home/ubuntu/out/smoke",
                                    "machine": "dev", "unit": "rabota-lane-quantivly-remote-dead.service",
                                    "status": "started", "seat": "quantivly-1"})
        # Overrides setUp's zero-out_dirs ssh reply: this store now has one started lane on "dev",
        # so machines() requests one out_dir, and payload()'s default carries exactly one stream
        # section for it, with a result line distinct from the lane's own (non-matching) unit name.
        self.runner.responses.insert(0, (["ssh"], Result(0, payload(), "")))
        self._gather()
        row = self.ctx.store.get_lane("remote1")
        self.assertEqual(row["status"], "done")
        self.assertAlmostEqual(row["cost_usd"], 0.42)


class MachinesTests(unittest.TestCase):
    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        c = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner,
                                           env={"PATH": "/bin"}, cwd=Path("/"))
        # Same hygiene as CensusTests.setUp: an unclosed sqlite connection is a ResourceWarning
        # that lands in whichever test happens to run next.
        self.addCleanup(lambda: c._store and c._store.close())
        return c

    def test_a_reachable_machine_becomes_a_row(self):
        # This ctx has no started lanes on "dev", so machines() asks remote.read for zero
        # out_dirs and remote.parse (Task 2) now enforces an EXACT section count — payload()'s
        # own default carries one stream section for a different caller's fixture and would
        # trip that check here, reading as unreachable. streams=() matches what this call
        # actually requests.
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, payload(streams=()), ""))]))
        rows, unavailable = census.machines(ctx)
        self.assertEqual([r["name"] for r in rows], ["dev"])
        self.assertTrue(rows[0]["reachable"])
        self.assertEqual(unavailable, [])

    def test_an_unreachable_machine_is_named_unavailable(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(255, "", "no route"))]))
        rows, unavailable = census.machines(ctx)
        self.assertFalse(rows[0]["reachable"])
        self.assertIn("machine:dev", unavailable)

    def test_deferred_no_longer_claims_machines(self):
        self.assertNotIn("deferred:machines", census.DEFERRED)


class SettleRemoteTests(unittest.TestCase):
    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        c = context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner,
                                           env={"PATH": "/bin"}, cwd=Path("/"))
        self.addCleanup(lambda: c._store and c._store.close())
        return c

    def lane(self, ctx, machine, out_dir):
        ctx.store.insert_lane({"id": "L1", "tenant": "quantivly", "kind": "work", "brief": "b",
                               "repo": "hub", "worktree": "/w", "out_dir": out_dir, "machine": machine,
                               "unit": "rabota-lane-x.service", "status": "started", "seat": "quantivly-0"})

    def test_a_remote_lane_settles_from_the_machines_reading(self):
        ctx = self.ctx(FakeRunner([]))
        self.lane(ctx, "dev", "/home/ubuntu/out/smoke")
        rows = [{"name": "dev", "reachable": True,
                 "streams": {"/home/ubuntu/out/smoke": '{"type":"result","is_error":false,"total_cost_usd":0.42}'}}]
        settled = census.settle_finished(ctx, units=[], seats=[{"name": "quantivly-0", "five_h_pct": 12}],
                                         machines=rows)
        self.assertEqual(settled, ["L1"])
        row = ctx.store.list_lanes("quantivly")[0]
        self.assertEqual((row["status"], row["cost_usd"], row["five_h_pct_at_end"]), ("done", 0.42, 12))

    def test_a_remote_lane_with_no_result_yet_is_left_alone(self):
        ctx = self.ctx(FakeRunner([]))
        self.lane(ctx, "dev", "/home/ubuntu/out/smoke")
        rows = [{"name": "dev", "reachable": True, "streams": {"/home/ubuntu/out/smoke": ""}}]
        self.assertEqual(census.settle_finished(ctx, [], [], machines=rows), [])

    def test_an_unreachable_machine_settles_nothing(self):
        ctx = self.ctx(FakeRunner([]))
        self.lane(ctx, "dev", "/home/ubuntu/out/smoke")
        # A real unreachable row never carries "streams" (remote.py), so this also plants one with
        # a result line that WOULD settle if read: the row must be rejected on ``reachable`` alone,
        # not merely because a stream happens to be absent — otherwise this row is hollow against a
        # guard that reads unconditionally off a dict lacking the key it never sets.
        rows = [{"name": "dev", "reachable": False, "error": "no route",
                 "streams": {"/home/ubuntu/out/smoke": '{"type":"result","is_error":false,"total_cost_usd":9.9}'}}]
        self.assertEqual(census.settle_finished(ctx, [], [], machines=rows), [])
        self.assertEqual(ctx.store.get_lane("L1")["status"], "started")

    def test_a_still_running_remote_unit_is_left_alone(self):
        ctx = self.ctx(FakeRunner([]))
        self.lane(ctx, "dev", "/home/ubuntu/out/smoke")
        rows = [{"name": "dev", "reachable": True,
                 "units": [{"name": "rabota-lane-x.service", "state": "active", "machine": "dev"}],
                 "streams": {"/home/ubuntu/out/smoke": '{"type":"result","is_error":false,"total_cost_usd":1.0}'}}]
        self.assertEqual(census.settle_finished(ctx, [], [], machines=rows), [])

    def test_a_same_named_unit_on_another_machine_does_not_block_a_settle(self):
        # Unit names are unique per machine, not globally. A flat live-set would see this lane's
        # name still active locally and skip it forever, and reap would later abandon a lane that
        # had in fact finished — losing its cost with no error anywhere.
        ctx = self.ctx(FakeRunner([]))
        self.lane(ctx, "dev", "/home/ubuntu/out/smoke")
        local_units = [{"name": "rabota-lane-x.service", "state": "active", "machine": "local"}]
        rows = [{"name": "dev", "reachable": True, "units": [],
                 "streams": {"/home/ubuntu/out/smoke": '{"type":"result","is_error":false,"total_cost_usd":0.42}'}}]
        settled = census.settle_finished(ctx, local_units,
                                         [{"name": "quantivly-0", "five_h_pct": 12}], machines=rows)
        self.assertEqual(settled, ["L1"])
        self.assertEqual(ctx.store.get_lane("L1")["cost_usd"], 0.42)
