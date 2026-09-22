# Remote Lanes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make `rabota lane recipe --machine dev --run` dispatch a measured agent lane to the dev box and close it, through the gate every spawner shares.

**Architecture:** rabota renders and runs everything from the laptop. A lane is a `systemd --user` unit on the target machine started by one `ssh` invocation; dev needs no rabota. Placement is gated credential → machine → counts, with the credential dimension answered locally from the laptop's monitoring grant for the remote seat.

**Tech Stack:** Python 3.11 stdlib only (no third-party imports, ever), `unittest`, `FakeRunner` for every subprocess, TOML config in `~/.dotfiles-local/rabota`, `systemd-run --user` and OpenSSH on the remote.

**Spec:** [`docs/superpowers/specs/2026-09-20-remote-lanes-design.md`](../specs/2026-09-20-remote-lanes-design.md) — read it before Task 1; this plan argues from it.

## Global Constraints

- **stdlib only.** `rabota` imports nothing outside the standard library. A new dependency is a design change, not an implementation detail.
- **Every subprocess goes through `ctx.runner`.** Never `subprocess.*` outside `rabota/runner.py`. Tests inject `FakeRunner`; a test that shells out for real is a broken test.
- **An unmeasured dimension refuses; it is never read as zero or as room.** `reachable: false` → `machine:unmeasured` → exit 3. Never fall back to local.
- **Exit codes:** `0` ok · `2` usage · `3` refused · `4` partial · `5` error.
- **Contract files carry `schema`, `at`, and `unavailable[]`.** Every writer names the dimensions it could not measure.
- **Everything written to a contract file or stdout passes `secrets.assert_clean`.**
- **Nothing crosses a remote command line but paths rabota generated.** File content travels on stdin. Dev's login shell is zsh 5.8.1 and bash `printf %q` is not zsh-safe (`=ls` → `/usr/bin/ls`).
- **Run the suite with** `python3 -m unittest discover -s tests -t .` from `rabota/`, or `scripts/test-rabota.sh`.
- **Commit trailer:** `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **Writes to `~/.dotfiles-local`, `~/.claude/settings.json`, and anything on dev need Zvi's typed OK.** Prepare the exact command, print it, wait.

---

## File structure

| File | Task | Responsibility |
|---|---|---|
| `~/.dotfiles-local/rabota/tenants/*.toml` | 1 | Live data: `[seats]`, `[machines.dev].profile`. No code. |
| `rabota/rabota/remote.py` | 2 | **New.** One ssh call per machine → `RemoteReading`. The only file that knows the remote shell exists. |
| `rabota/tests/test_remote.py` | 2 | **New.** |
| `rabota/rabota/census.py` | 3, 5 | `machines()`, wire into `gather()`, settle remote lanes. |
| `rabota/rabota/budget.py` | 4, 8 | `_machine_reasons` / `_running_lanes` per machine; census freshness. |
| `rabota/rabota/commands/budget.py` | 4 | Thread `--machine` into `compute`. |
| `rabota/rabota/commands/lane.py` | 6, 7 | **New.** `lane recipe [--run]`. |
| `rabota/tests/test_lane_recipe.py` | 6, 7 | **New.** |
| `rabota/rabota/commands/doctor.py` | 8 | Seat-cache-age assertion. |
| `~/.claude/settings.json` | 9 | `Bash(rabota lane recipe:*)`. Gated. |

---

## Task 1: Live config so `seat_for()` stops refusing

The dataclass fields (`Machine.profile`, `Tenant.seats`) and the test fixture
(`tests/fixtures/config/tenants/quantivly.toml`) already carry this shape — the suite passes today.
Only the live data in the private repo lags. **No code change, no new test.**

**Files:**
- Modify: `~/.dotfiles-local/rabota/tenants/quantivly.toml`
- Modify: `~/.dotfiles-local/rabota/tenants/personal.toml`, `~/.dotfiles-local/rabota/tenants/toysim.toml`

**Interfaces:**
- Consumes: nothing.
- Produces: `budget.seat_for(tenant, "local")` → `"quantivly-1"`; `budget.seat_for(tenant, "dev")` → `"quantivly-0"`.

- [ ] **Step 1: Show the before-state**

```bash
grep -n '^\[seats\]\|^\[machines\.dev\]\|^profile' ~/.dotfiles-local/rabota/tenants/quantivly.toml || echo "absent"
```
Expected: `absent` for `[seats]` and for `profile`; `[machines.dev]` present.

- [ ] **Step 2: Print the exact edit and WAIT for Zvi's typed OK** (private repo)

In `quantivly.toml`, add a top-level `[seats]` table before `[machines.dev]`, and one key inside `[machines.dev]`:

```toml
[seats]
local = "quantivly-1"
```
```toml
profile   = "quantivly-0"
```

In `personal.toml` and `toysim.toml`, add:

```toml
[seats]
local = "personal-0"
```

- [ ] **Step 3: Verify the refusal is gone**

Run: `rabota budget --machine dev --model claude-sonnet-5 --effort medium`
Expected: JSON with `"seat_pick": "quantivly-0"`. It may still refuse on `machine:unmeasured` (no census) — that is Task 3/4's job and is the correct behaviour now.

Run: `rabota budget --machine local --model claude-sonnet-5 --effort medium`
Expected: `"seat_pick": "quantivly-1"`.

- [ ] **Step 4: Commit** (in `~/.dotfiles-local`, Zvi's repo — ask before committing)

```bash
git -C ~/.dotfiles-local add rabota/tenants/quantivly.toml rabota/tenants/personal.toml rabota/tenants/toysim.toml
git -C ~/.dotfiles-local commit -m "rabota: declare the seat each machine bills (DO-635 remote lanes)"
```

---

## Task 2: `rabota/remote.py` — one ssh call per machine

**Files:**
- Create: `rabota/rabota/remote.py`
- Test: `rabota/tests/test_remote.py`

**Interfaces:**
- Consumes: `rabota.runner.Runner`/`Result`, `rabota.config.Machine`, `rabota.sysinfo.read`, `rabota.sysinfo.SysInfo`.
- Produces:
  - `remote.MARKER: str` — the section separator, `"---RABOTA---"`.
  - `remote.build_argv(machine: Machine, lane_out_dirs: list[str]) -> list[str]` — the ssh argv.
  - `remote.parse(name: str, out: str) -> dict` — `{"name", "reachable", "load1", "ncpu", "mem_available_gib", "swap_used_pct", "units", "streams"}`.
  - `remote.read(runner, machine: Machine, lane_out_dirs: list[str], timeout: float = 30) -> dict` — the same dict, with `reachable: False` and `"error"` on any non-zero exit.
  - `streams` is `{out_dir: last_result_line_or_""}`.

- [ ] **Step 1: Write the failing test**

Create `rabota/tests/test_remote.py`:

```python
import unittest
from rabota import remote
from rabota.config import Machine
from rabota.runner import FakeRunner, Result

LOADAVG = "0.20 0.28 0.27 1/900 12345\n"
MEMINFO = "MemTotal: 64000000 kB\nMemAvailable: 13631488 kB\nSwapTotal: 16000000 kB\nSwapFree: 16000000 kB\n"
UNITS = "rabota-lane-quantivly-smoke-9b221b43.service loaded active running lane\n"
RESULT = '{"type":"result","is_error":false,"total_cost_usd":0.42}'


def payload(*, units=UNITS, streams=(("/home/ubuntu/out/smoke", RESULT),)):
    parts = [LOADAVG, MEMINFO, "16\n", units]
    for out_dir, line in streams:
        parts.append(f"{out_dir}\n{line}\n")
    return remote.MARKER.join(parts)


MACHINE = Machine(name="dev", ssh="dev", state_dir="~/.local/state/rabota")


class RemoteArgvTests(unittest.TestCase):
    def test_argv_is_batch_mode_and_names_the_host(self):
        argv = remote.build_argv(MACHINE, [])
        self.assertEqual(argv[0], "ssh")
        self.assertIn("BatchMode=yes", argv)
        self.assertIn("dev", argv)

    def test_out_dirs_are_single_quoted_into_the_script(self):
        argv = remote.build_argv(MACHINE, ["/home/ubuntu/o ne"])
        self.assertIn("'/home/ubuntu/o ne'", argv[-1])

    def test_a_quote_in_an_out_dir_cannot_break_out(self):
        argv = remote.build_argv(MACHINE, ["/tmp/a'; touch PWNED; '"])
        self.assertNotIn("touch PWNED;", argv[-1].replace("'\\''", ""))


class RemoteParseTests(unittest.TestCase):
    def test_parses_a_full_reading(self):
        r = remote.parse("dev", payload())
        self.assertTrue(r["reachable"])
        self.assertEqual((r["load1"], r["ncpu"]), (0.20, 16))
        self.assertAlmostEqual(r["mem_available_gib"], 13.0, places=1)
        self.assertEqual(r["swap_used_pct"], 0)
        self.assertEqual(r["units"][0]["name"], "rabota-lane-quantivly-smoke-9b221b43.service")
        self.assertEqual(r["units"][0]["state"], "active")
        self.assertEqual(r["units"][0]["machine"], "dev")
        self.assertEqual(r["streams"]["/home/ubuntu/out/smoke"], RESULT)

    def test_no_units_is_an_empty_list_not_a_failure(self):
        r = remote.parse("dev", payload(units=""))
        self.assertTrue(r["reachable"])
        self.assertEqual(r["units"], [])


class RemoteReadTests(unittest.TestCase):
    def test_read_returns_the_parsed_reading(self):
        runner = FakeRunner([(["ssh"], Result(0, payload(), ""))])
        r = remote.read(runner, MACHINE, ["/home/ubuntu/out/smoke"])
        self.assertTrue(r["reachable"])
        self.assertEqual(r["name"], "dev")

    def test_ssh_failure_is_unreachable_not_zero(self):
        runner = FakeRunner([(["ssh"], Result(255, "", "connection refused"))])
        r = remote.read(runner, MACHINE, [])
        self.assertFalse(r["reachable"])
        self.assertIn("connection refused", r["error"])
        self.assertNotIn("load1", r)

    def test_timeout_is_unreachable(self):
        runner = FakeRunner([(["ssh"], Result(124, "", "timeout after 30s"))])
        self.assertFalse(remote.read(runner, MACHINE, [])["reachable"])

    def test_garbled_output_is_unreachable(self):
        runner = FakeRunner([(["ssh"], Result(0, "not a payload", ""))])
        r = remote.read(runner, MACHINE, [])
        self.assertFalse(r["reachable"])
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd rabota && python3 -m unittest tests.test_remote -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rabota.remote'`

- [ ] **Step 3: Write the implementation**

Create `rabota/rabota/remote.py`:

```python
"""One ssh call per machine: load, memory, lane units, and each lane's last result line.

The ONLY module that knows a remote shell exists. Everything it sends is either a literal
this file wrote or a path single-quoted by ``shquote`` — dev's login shell is zsh, and bash's
``printf %q`` is not zsh-safe (a leading ``=`` undergoes equals expansion there), so POSIX
single-quoting is used rather than any shell's own quoter.

Unreachable is a measurement, never a zero: a caller that reads a missing key as room is the
bug this module's shape exists to prevent.
"""
import tempfile
from pathlib import Path

from rabota import sysinfo

MARKER = "---RABOTA---"


def shquote(s: str) -> str:
    """POSIX single-quoting: literal in sh, bash and zsh alike."""
    return "'" + s.replace("'", "'\\''") + "'"


def build_argv(machine, lane_out_dirs: list[str]) -> list[str]:
    """The one ssh invocation. Sections are separated by MARKER, in parse()'s order."""
    script = [
        "cat /proc/loadavg", f"printf %s {shquote(MARKER)}",
        "cat /proc/meminfo", f"printf %s {shquote(MARKER)}",
        "nproc", f"printf %s {shquote(MARKER)}",
        'systemctl --user list-units --plain --no-legend "rabota-lane-*" 2>/dev/null || true',
    ]
    for d in lane_out_dirs:
        q = shquote(d)
        script += [f"printf %s {shquote(MARKER)}", f"printf '%s\\n' {q}",
                   f"grep -h '\"type\":\"result\"' {q}/stream.jsonl 2>/dev/null | tail -1 || true"]
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--",
            machine.ssh, "; ".join(script)]


def parse(name: str, out: str) -> dict:
    """Split the payload into a machines[] row. Raises ValueError on anything unexpected."""
    parts = out.split(MARKER)
    if len(parts) < 4:
        raise ValueError(f"expected at least 4 sections, got {len(parts)}")
    loadavg, meminfo, ncpu_s, units_s = parts[0], parts[1], parts[2], parts[3]
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "loadavg").write_text(loadavg)
        (root / "meminfo").write_text(meminfo)
        si = sysinfo.read(root, ncpu=int(ncpu_s.strip()))
    units = []
    for line in units_s.splitlines():
        f = line.split()
        if len(f) >= 3 and f[0].startswith("rabota-lane-"):
            units.append({"name": f[0], "state": f[2], "machine": name})
    streams = {}
    for chunk in parts[4:]:
        lines = chunk.splitlines()
        if lines:
            streams[lines[0]] = lines[1] if len(lines) > 1 else ""
    return {"name": name, "reachable": True, "load1": si.load1, "ncpu": si.ncpu,
            "mem_available_gib": round(si.mem_available_gib, 1),
            "swap_used_pct": si.swap_used_pct, "units": units, "streams": streams}


def read(runner, machine, lane_out_dirs: list[str], timeout: float = 30) -> dict:
    """Measure ``machine``. Any failure is ``reachable: False`` with an ``error``, never a zero."""
    res = runner.run(build_argv(machine, lane_out_dirs), timeout=timeout)
    if not res.ok:
        return {"name": machine.name, "reachable": False,
                "error": (res.err or res.out or f"exit {res.code}").strip()}
    try:
        return parse(machine.name, res.out)
    except (ValueError, KeyError) as e:
        return {"name": machine.name, "reachable": False, "error": f"unparseable reading: {e}"}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rabota && python3 -m unittest tests.test_remote -v`
Expected: PASS, 9 tests.

- [ ] **Step 5: Run the whole suite**

Run: `cd rabota && python3 -m unittest discover -s tests -t .`
Expected: OK, no regressions.

- [ ] **Step 6: Commit**

```bash
git add rabota/rabota/remote.py rabota/tests/test_remote.py
git commit -m "feat(rabota): read a remote machine's load, lanes and results in one ssh call"
```

---

## Task 3: `census.machines[]`

**Files:**
- Modify: `rabota/rabota/census.py` — add `machines()`, call it in `gather()`, narrow `DEFERRED`.
- Test: `rabota/tests/test_census.py` — add a `MachinesTests` class.

**Interfaces:**
- Consumes: `remote.read` from Task 2.
- Produces: `census.machines(ctx) -> tuple[list[dict], list[str]]` — rows and `unavailable` codes. `census.json` gains `machines[]`. `gather()` returns `{"machines": [...], ...}`.

- [ ] **Step 1: Write the failing test**

Append to `rabota/tests/test_census.py`:

```python
class MachinesTests(unittest.TestCase):
    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        return context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner,
                                              env={"PATH": "/bin"}, cwd=Path("/"))

    def test_a_reachable_machine_becomes_a_row(self):
        from tests.test_remote import payload
        ctx = self.ctx(FakeRunner([(["ssh"], Result(0, payload(), ""))]))
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd rabota && python3 -m unittest tests.test_census.MachinesTests -v`
Expected: FAIL — `AttributeError: module 'rabota.census' has no attribute 'machines'`

- [ ] **Step 3: Implement**

In `rabota/rabota/census.py`, change line 19 to:

```python
DEFERRED = ["deferred:sol"]   # design §4.2: machines[] shipped by the remote-lanes plan
```

Add `from rabota import remote` to the imports, and this function above `gather`:

```python
def machines(ctx) -> tuple[list[dict], list[str]]:
    """One row per machine this tenant declares, each measured in one ssh call.

    An unreachable machine still gets a row — with ``reachable: False`` — and its name in
    ``unavailable``. Readers must refuse on it; a missing row and a zeroed row are the two
    ways this becomes "plenty of room" by accident.
    """
    rows, unavailable = [], []
    for name, m in sorted(ctx.tenant.machines.items()):
        out_dirs = [l["out_dir"] for l in ctx.store.list_lanes(ctx.tenant.name, status="started")
                    if l.get("machine") == name and l.get("out_dir")]
        row = remote.read(ctx.runner, m, out_dirs)
        if not row.get("reachable"):
            unavailable.append(f"machine:{name}")
        rows.append(row)
    return rows, unavailable
```

In `gather()`, after the `worktrees` line, add `ms, u4 = machines(ctx)`; add `u4` to the
`unavailable +=` sum; and add `"machines": ms,` to the `out` dict.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rabota && python3 -m unittest tests.test_census -v`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `cd rabota && python3 -m unittest discover -s tests -t .`
Expected: OK. If a golden-file test fails on the new `machines` key, update the golden — `census.json` gaining a key is the intended change.

- [ ] **Step 6: Commit**

```bash
git add rabota/rabota/census.py rabota/tests/test_census.py
git commit -m "feat(rabota): census measures every declared machine, not only this one"
```

---

## Task 4: the machine and count dimensions, per machine

**Files:**
- Modify: `rabota/rabota/budget.py:82-105` — `compute`; replace the `_machine_reasons` and
  `_count_reasons` stubs. `_count_reasons` **goes away**: counting is per-machine and returns a
  number, not a reason list, so it becomes `_running_lanes`. Delete the old stub.
- Modify: `rabota/rabota/commands/budget.py:19-21` — pass the machine.
- Test: `rabota/tests/test_budget.py`.

**Interfaces:**
- Consumes: `census["machine"]`, `census["machines"]`, `BudgetThresholds` (`load1_per_cpu`, `swap_pct_max`, `mem_available_min_gib`, `max_lanes_local`).
- Produces:
  - `budget.compute(census, cred, t, max_lanes_local, machine="local") -> dict`
  - `budget._reading_for(census, machine) -> dict | None`
  - `budget._machine_reasons(m: dict, t) -> list[dict]`
  - `budget._running_lanes(census, machine) -> int`

- [ ] **Step 1: Write the failing test**

Append to `rabota/tests/test_budget.py`:

```python
from rabota import store
from rabota.config import BudgetThresholds as BT

OK_CRED = {"ok": True, "code": None, "detail": "", "five_h_pct_now": 5, "resets_at": None, "tier": "Team"}

def census_with(*, local_load=1.0, dev=None, counts=None):
    # "at" is always present and fresh: Task 8 makes a census without one stale, and every row
    # here is about the MACHINE dimension, not freshness.
    c = {"at": store.now(),
         "machine": {"load1": local_load, "ncpu": 8, "mem_available_gib": 20.0, "swap_used_pct": 0},
         "counts": counts or {"rabota": 0, "sol": 0}, "unavailable": [], "machines": []}
    if dev is not None:
        c["machines"] = [dev]
    return c

DEV_IDLE = {"name": "dev", "reachable": True, "load1": 0.2, "ncpu": 16,
            "mem_available_gib": 13.0, "swap_used_pct": 0, "units": [], "streams": {}}


class MachineDimensionTests(unittest.TestCase):
    def t(self):
        return BT(max_local_sessions=8, max_lanes_local=3, load1_per_cpu=1.25,
                  swap_pct_max=40, mem_available_min_gib=6, profile_5h_pct_max=70)

    def test_a_saturated_laptop_does_not_refuse_a_dev_lane(self):
        c = census_with(local_load=99.0, dev=DEV_IDLE)
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual(b["reasons"], [])
        self.assertEqual(b["allowed_new_lanes"], 3)

    def test_a_saturated_laptop_does_refuse_a_local_lane(self):
        c = census_with(local_load=99.0, dev=DEV_IDLE)
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="local")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:load"])

    def test_a_loaded_dev_refuses_a_dev_lane(self):
        busy = dict(DEV_IDLE, load1=40.0)
        b = budget.compute(census_with(dev=busy), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:load"])

    def test_low_memory_on_dev_refuses(self):
        tight = dict(DEV_IDLE, mem_available_gib=1.0)
        b = budget.compute(census_with(dev=tight), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:memory"])

    def test_swap_on_dev_refuses(self):
        swapping = dict(DEV_IDLE, swap_used_pct=80)
        b = budget.compute(census_with(dev=swapping), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:swap"])

    def test_an_unreachable_dev_refuses_and_is_not_room(self):
        b = budget.compute(census_with(dev={"name": "dev", "reachable": False, "error": "no route"}),
                           OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:unmeasured"])
        self.assertEqual(b["allowed_new_lanes"], 0)

    def test_a_missing_dev_row_refuses_rather_than_falling_back_to_local(self):
        b = budget.compute(census_with(dev=None), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["machine:unmeasured"])

    def test_running_lanes_on_dev_consume_the_cap(self):
        busy = dict(DEV_IDLE, units=[{"name": "rabota-lane-a.service", "state": "active", "machine": "dev"},
                                     {"name": "rabota-lane-b.service", "state": "active", "machine": "dev"}])
        b = budget.compute(census_with(dev=busy), OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual(b["allowed_new_lanes"], 1)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd rabota && python3 -m unittest tests.test_budget.MachineDimensionTests -v`
Expected: FAIL — `compute() got an unexpected keyword argument 'machine'`

- [ ] **Step 3: Implement**

In `rabota/rabota/budget.py`, replace `compute` and the two stubs:

```python
def compute(census: dict | None, cred: dict, t, max_lanes_local: int, machine: str = "local") -> dict:
    """Order: credential → machine → counts, for the machine the lane would run on."""
    reasons, unavailable = [], []
    if not cred["ok"]:
        reasons.append({"code": cred["code"], "detail": cred["detail"]})
    running = 0
    if census is None:
        unavailable.extend(["machine", "counts"])
        if not reasons:
            reasons.append({"code": "machine:unmeasured", "detail": "no census; run rabota census first"})
    else:
        m = _reading_for(census, machine)
        if m is None:
            reasons.append({"code": "machine:unmeasured",
                            "detail": f"census has no usable reading for machine {machine!r}"})
            unavailable.append("machine")
        else:
            reasons.extend(_machine_reasons(m, t))
            running = _running_lanes(census, machine)
        unavailable.extend(census.get("unavailable", []))
    allowed = 0 if reasons else max(0, max_lanes_local - running)
    return {"schema": 1, "at": now(), "allowed_new_lanes": allowed, "reasons": reasons,
            "seat_pick": None, "five_h_pct_now": cred.get("five_h_pct_now"), "resets_at": cred.get("resets_at"),
            "tier": cred.get("tier"), "unavailable": unavailable}


def _reading_for(census: dict, machine: str) -> dict | None:
    """The load/memory reading for ``machine``, or None when it was not measured.

    None and a zeroed row are the two ways an unmeasured machine becomes "room"; the caller
    turns None into a refusal, so neither can.
    """
    if machine == "local":
        return census.get("machine")
    for row in census.get("machines", []):
        if row.get("name") == machine:
            return row if row.get("reachable") else None
    return None


def _machine_reasons(m: dict, t) -> list[dict]:
    """Load, memory and swap against the tenant's thresholds. One named reason per breach."""
    out = []
    ncpu = m.get("ncpu") or 1
    if m["load1"] > t.load1_per_cpu * ncpu:
        out.append({"code": "machine:load",
                    "detail": f"load1 {m['load1']} over {t.load1_per_cpu}×{ncpu} cpus"})
    if m["mem_available_gib"] < t.mem_available_min_gib:
        out.append({"code": "machine:memory",
                    "detail": f"{m['mem_available_gib']} GiB available, floor {t.mem_available_min_gib}"})
    if m["swap_used_pct"] > t.swap_pct_max:
        out.append({"code": "machine:swap",
                    "detail": f"swap {m['swap_used_pct']}% over {t.swap_pct_max}%"})
    return out


def _running_lanes(census: dict, machine: str) -> int:
    """Lanes already running on ``machine`` — local counts owners, remote counts its units."""
    if machine == "local":
        c = census.get("counts", {})
        return c.get("rabota", 0) + c.get("sol", 0)
    for row in census.get("machines", []):
        if row.get("name") == machine:
            return sum(u.get("state") in ("active", "activating") for u in row.get("units", []))
    return 0
```

In `rabota/rabota/commands/budget.py`, change the `compute` call in `run_budget` to pass the machine:

```python
    b = budget_mod.compute(census, cred, ctx.tenant.budget, ctx.tenant.budget.max_lanes_local, machine=machine)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rabota && python3 -m unittest tests.test_budget -v`
Expected: PASS, including the existing `BudgetTests`.

- [ ] **Step 5: Mutation sweep** — for each, confirm it applies (`grep -c` the line = 1), apply, run, confirm the named rows fail, then `git checkout -- rabota/rabota/budget.py`:
  - `_reading_for`'s `return row if row.get("reachable") else None` → `return row`: "an unreachable dev refuses" fails.
  - `_reading_for`'s final `return None` → `return census.get("machine")`: "a missing dev row refuses rather than falling back to local" fails.
  - `_machine_reasons`'s `ncpu = m.get("ncpu") or 1` → `ncpu = 1`: "a saturated laptop does not refuse a dev lane" fails.
  - `_running_lanes`'s remote branch → `return 0`: "running lanes on dev consume the cap" fails.
  A mutation that leaves every row green is a hollow row: fix the row, not the tally.

- [ ] **Step 6: Run the whole suite and commit**

```bash
cd rabota && python3 -m unittest discover -s tests -t .
git add rabota/rabota/budget.py rabota/rabota/commands/budget.py rabota/tests/test_budget.py
git commit -m "feat(rabota): gate a lane on the machine it would run on, not on this one"
```

---

## Task 5: settle a lane that ran on another machine

`settle_finished` reads `Path(lane["out_dir"]) / "stream.jsonl"` from the local filesystem, so a
remote lane's row never settles. Task 2 already carries each lane's last result line in `streams`.

**Files:**
- Modify: `rabota/rabota/census.py:199-229` — `settle_finished`.
- Test: `rabota/tests/test_census.py`.

**Interfaces:**
- Consumes: `machines[]` rows from Task 3, each with `streams: {out_dir: last_result_line}`.
- Produces: `census.settle_finished(ctx, units, seats, machines=None) -> list[str]`.

- [ ] **Step 1: Write the failing test**

Append to `rabota/tests/test_census.py`:

```python
class SettleRemoteTests(unittest.TestCase):
    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        return context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner,
                                              env={"PATH": "/bin"}, cwd=Path("/"))

    def lane(self, ctx, machine, out_dir):
        ctx.store.add_lane({"id": "L1", "tenant": "quantivly", "kind": "work", "brief": "b",
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
        rows = [{"name": "dev", "reachable": False, "error": "no route"}]
        self.assertEqual(census.settle_finished(ctx, [], [], machines=rows), [])

    def test_a_still_running_remote_unit_is_left_alone(self):
        ctx = self.ctx(FakeRunner([]))
        self.lane(ctx, "dev", "/home/ubuntu/out/smoke")
        rows = [{"name": "dev", "reachable": True,
                 "units": [{"name": "rabota-lane-x.service", "state": "active", "machine": "dev"}],
                 "streams": {"/home/ubuntu/out/smoke": '{"type":"result","is_error":false,"total_cost_usd":1.0}'}}]
        self.assertEqual(census.settle_finished(ctx, [], [], machines=rows), [])
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd rabota && python3 -m unittest tests.test_census.SettleRemoteTests -v`
Expected: FAIL — `settle_finished() got an unexpected keyword argument 'machines'`

- [ ] **Step 3: Implement**

In `rabota/rabota/census.py`, replace `settle_finished` with:

```python
def settle_finished(ctx, units: list[dict], seats: list[dict], machines: list[dict] | None = None) -> list[str]:
    """A ``started`` row whose unit is gone and whose stream has a result line is settled from that line.

    ``ended_at``, ``cost_usd`` (``result.total_cost_usd``) and ``five_h_pct_at_end`` (the seat's
    current reading) are written; ``status`` becomes ``done`` or ``failed`` per ``is_error``. A row
    whose unit is still active, or whose stream has no result yet, is left alone (``reap`` handles
    abandonment). Returns the ids settled.

    A lane on another machine is settled from that machine's ``machines[]`` row — its stream lives
    there, so the local filesystem read below can never see it. An unreachable machine settles
    nothing: not knowing is not the same as finished.
    """
    by_name = {m["name"]: m for m in (machines or [])}
    live = {u["name"] for u in units if u.get("state") in ("active", "activating")}
    for m in by_name.values():
        live |= {u["name"] for u in m.get("units", []) if u.get("state") in ("active", "activating")}
    pct = {s["name"]: s.get("five_h_pct") for s in seats}
    settled = []
    for lane in ctx.store.list_lanes(ctx.tenant.name, status="started"):
        if lane.get("unit") in live:
            continue
        machine = lane.get("machine") or "local"
        if machine == "local":
            stream = Path(lane["out_dir"]) / "stream.jsonl"
            if not stream.exists():
                continue
            text = stream.read_text()
        else:
            row = by_name.get(machine)
            if not row or not row.get("reachable"):
                continue
            text = row.get("streams", {}).get(lane["out_dir"], "")
        result = None
        for line in text.splitlines():
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and obj.get("type") == "result":
                result = obj
        if result is None:
            continue
        ctx.store.update_lane(lane["id"], status="failed" if result.get("is_error") else "done", ended_at=now(),
                              cost_usd=result.get("total_cost_usd"), five_h_pct_at_end=pct.get(lane.get("seat")))
        settled.append(lane["id"])
    return settled
```

In `gather()`, change the call to `settle_finished(ctx, us, st, machines=ms)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rabota && python3 -m unittest tests.test_census -v`
Expected: PASS, including the pre-existing local settle tests.

- [ ] **Step 5: Run the whole suite and commit**

```bash
cd rabota && python3 -m unittest discover -s tests -t .
git add rabota/rabota/census.py rabota/tests/test_census.py
git commit -m "feat(rabota): settle a lane that ran on another machine"
```

---

## Task 6: `rabota lane recipe` — the local form

**Files:**
- Create: `rabota/rabota/commands/lane.py`
- Test: `rabota/tests/test_lane_recipe.py`
- Modify: `rabota/rabota/cli.py` — register the subcommand alongside the others.

**Interfaces:**
- Consumes: `budget.seat_for`, `budget_cmd.run_budget`, `remote.shquote`, `ctx.store.add_lane`.
- Produces:
  - `lane.unit_name(tenant: str, slug: str) -> str` → `rabota-lane-<tenant>-<slug>-<uuid8>.service`
  - `lane.build_local(ctx, seat, repo, worktree, out_dir, brief, model, effort, unit) -> list[str]`
  - `rabota lane recipe --brief P --repo R [--machine local|dev] [--base REF] [--seat S] [--model M] [--effort E] [--est-minutes N] [--run]`, JSON by default.

- [ ] **Step 1: Write the failing test**

Create `rabota/tests/test_lane_recipe.py`:

```python
import argparse, json, tempfile, unittest
from pathlib import Path
from rabota import context, errors
from rabota.commands import lane
from rabota.runner import FakeRunner, Result

FIX = Path(__file__).parent / "fixtures"


class UnitNameTests(unittest.TestCase):
    def test_unit_name_is_prefixed_and_unique(self):
        a = lane.unit_name("quantivly", "smoke")
        b = lane.unit_name("quantivly", "smoke")
        self.assertTrue(a.startswith("rabota-lane-quantivly-smoke-"))
        self.assertTrue(a.endswith(".service"))
        self.assertNotEqual(a, b)

    def test_a_slug_is_reduced_to_safe_characters(self):
        self.assertIn("rabota-lane-quantivly-a-b-", lane.unit_name("quantivly", "a/b; rm -rf"))


class LocalRecipeTests(unittest.TestCase):
    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        return context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner,
                                              env={"PATH": "/bin"}, cwd=Path("/"))

    def argv(self):
        return lane.build_local(self.ctx(FakeRunner([])), seat="quantivly-1", repo="hub",
                                worktree="/w/t", out_dir="/o/d", brief="/o/d/brief.md",
                                model="claude-sonnet-5", effort="medium", unit="rabota-lane-x.service")

    def test_it_is_a_systemd_run_user_unit(self):
        a = self.argv()
        self.assertEqual(a[0], "systemd-run")
        self.assertIn("--user", a)
        self.assertIn("--collect", a)
        self.assertIn("--unit=rabota-lane-x.service", a)

    def test_stdout_and_stderr_are_appended_to_files_not_only_the_journal(self):
        a = self.argv()
        self.assertIn("-p", a)
        self.assertIn("StandardOutput=append:/o/d/stream.jsonl", a)
        self.assertIn("StandardError=append:/o/d/stream.err", a)

    def test_the_seat_is_pinned_by_config_dir(self):
        self.assertIn("--setenv=CLAUDE_CONFIG_DIR=" + str(Path.home() / ".claude-quantivly-1"), self.argv())

    def test_the_agent_is_told_to_read_the_brief(self):
        a = self.argv()
        self.assertIn("Read /o/d/brief.md and execute.", a)
        self.assertIn("--permission-mode", a)
        self.assertIn("auto", a)

    def test_the_prompt_never_carries_the_brief_contents(self):
        self.assertNotIn("brief body", " ".join(self.argv()))
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd rabota && python3 -m unittest tests.test_lane_recipe -v`
Expected: FAIL — `ImportError: cannot import name 'lane' from 'rabota.commands'`

- [ ] **Step 3: Implement**

Create `rabota/rabota/commands/lane.py`:

```python
"""``rabota lane recipe``: render (and optionally run) exactly one lane unit.

The whole lifecycle this command owns is "start it and record one row". No polling, no retire,
no attach: ``census`` observes the unit and settles the row, ``reap`` abandons a stale one.

It is the ONE door a headless lane comes through, which is why every spawner shares
``claude-pick --gate`` beneath it (``rabota budget``). A second door that skips the gate is how
a window gets spent unmetered.
"""
import re
import uuid
from pathlib import Path

from rabota import emit, errors, remote
from rabota.commands import budget as budget_cmd
from rabota.context import Context

SAFE = re.compile(r"[^A-Za-z0-9._-]+")


def unit_name(tenant: str, slug: str) -> str:
    """``rabota-lane-<tenant>-<slug>-<uuid8>.service``, with the slug reduced to safe characters."""
    s = SAFE.sub("-", slug).strip("-").lower() or "lane"
    return f"rabota-lane-{tenant}-{s}-{uuid.uuid4().hex[:8]}.service"


def seat_config_dir(seat: str) -> str:
    """The account dir a lane bills. One per seat, as claude() builds them."""
    return str(Path.home() / f".claude-{seat}")


def build_local(ctx, *, seat, repo, worktree, out_dir, brief, model, effort, unit) -> list[str]:
    """The systemd-run argv for a lane on this machine. Every value is an argv element, never a string."""
    return [
        "systemd-run", "--user", "--collect", f"--unit={unit}",
        f"--working-directory={worktree}",
        f"--setenv=CLAUDE_CONFIG_DIR={seat_config_dir(seat)}",
        "-p", f"StandardOutput=append:{out_dir}/stream.jsonl",
        "-p", f"StandardError=append:{out_dir}/stream.err",
        "-p", f"MemoryMax={ctx.tenant.lanes.memory_max}",
        ctx.tenant.lanes.claude_bin,
        "-p", f"Read {brief} and execute.",
        "--output-format", "stream-json", "--verbose",
        "--session-id", str(uuid.uuid4()),
        "--model", model, "--effort", effort,
        "--permission-mode", ctx.tenant.lanes.permission_mode,
        "--add-dir", out_dir,
    ]
```

Add to `rabota/rabota/config.py`'s `LaneDefaults` dataclass two fields with defaults, so existing
configs keep working:

```python
    memory_max: str = "6G"
    claude_bin: str = str(Path.home() / ".local/bin/claude")
```

Register the subcommand in `rabota/rabota/cli.py` next to the others, following the existing
`_build(sub)` pattern used by `commands/budget.py`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rabota && python3 -m unittest tests.test_lane_recipe -v`
Expected: PASS.

- [ ] **Step 5: Run the whole suite and commit**

```bash
cd rabota && python3 -m unittest discover -s tests -t .
git add rabota/rabota/commands/lane.py rabota/rabota/config.py rabota/rabota/cli.py rabota/tests/test_lane_recipe.py
git commit -m "feat(rabota): lane recipe renders one local lane unit"
```

---

## Task 7: the dev form — ssh, the brief on stdin, and `agents.slice`

**Files:**
- Modify: `rabota/rabota/commands/lane.py` — `build_remote`, `send_brief`, `create_worktree_remote`, `run_recipe`.
- Test: `rabota/tests/test_lane_recipe.py`.

**Interfaces:**
- Consumes: `remote.shquote`, `build_local` and `unit_name` from Task 6, `budget.seat_for`.
- Produces:
  - `lane.build_remote(ctx, machine, local_argv: list[str]) -> list[str]` — the ssh argv.
  - `lane.send_brief(ctx, machine, remote_path: str, text: str) -> None` — content on **stdin**.
  - `lane.run_recipe(ctx, **kw) -> dict` — `{argv, shell, unit, session_id, seat, machine, est_minutes}`.

- [ ] **Step 1: Write the failing test**

Append to `rabota/tests/test_lane_recipe.py`:

```python
class RemoteRecipeTests(LocalRecipeTests):
    def remote_argv(self):
        ctx = self.ctx(FakeRunner([]))
        local = lane.build_local(ctx, seat="quantivly-0", repo="hub", worktree="/w/t", out_dir="/o/d",
                                 brief="/o/d/brief.md", model="claude-sonnet-5", effort="medium",
                                 unit="rabota-lane-x.service")
        return lane.build_remote(ctx, ctx.tenant.machines["dev"], local)

    def test_it_wraps_the_local_argv_in_one_ssh_call(self):
        a = self.remote_argv()
        self.assertEqual(a[0], "ssh")
        self.assertIn("BatchMode=yes", a)
        self.assertIn("dev", a)

    def test_a_remote_lane_joins_the_agents_slice(self):
        self.assertIn("--slice=agents.slice", self.remote_argv()[-1])

    def test_every_element_is_single_quoted_for_the_remote_shell(self):
        cmd = self.remote_argv()[-1]
        self.assertIn("'Read /o/d/brief.md and execute.'", cmd)

    def test_an_equals_leading_value_cannot_be_expanded_by_zsh(self):
        ctx = self.ctx(FakeRunner([]))
        local = lane.build_local(ctx, seat="quantivly-0", repo="hub", worktree="/w/t", out_dir="/o/d",
                                 brief="=ls", model="claude-sonnet-5", effort="medium",
                                 unit="rabota-lane-x.service")
        self.assertIn("'Read =ls and execute.'", lane.build_remote(ctx, ctx.tenant.machines["dev"], local)[-1])

    def test_the_brief_travels_on_stdin_never_on_a_command_line(self):
        runner = FakeRunner([(["ssh"], Result(0, "", ""))])
        ctx = self.ctx(runner)
        lane.send_brief(ctx, ctx.tenant.machines["dev"], "/o/d/brief.md", "BRIEF-SENTINEL-9f")
        self.assertNotIn("BRIEF-SENTINEL-9f", " ".join(runner.calls[0]))
        self.assertIn("cat > '/o/d/brief.md'", runner.calls[0][-1])

    def test_a_failed_brief_send_is_an_error_not_a_silent_skip(self):
        ctx = self.ctx(FakeRunner([(["ssh"], Result(255, "", "no route"))]))
        with self.assertRaises(errors.Error):
            lane.send_brief(ctx, ctx.tenant.machines["dev"], "/o/d/brief.md", "x")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd rabota && python3 -m unittest tests.test_lane_recipe.RemoteRecipeTests -v`
Expected: FAIL — `AttributeError: module 'rabota.commands.lane' has no attribute 'build_remote'`

- [ ] **Step 3: Implement**

Add to `rabota/rabota/commands/lane.py`:

```python
def build_remote(ctx, machine, local_argv: list[str]) -> list[str]:
    """Wrap a local lane argv in one ssh call.

    Every element is POSIX single-quoted, not ``printf %q``: dev's login shell is zsh, where an
    unquoted leading ``=`` undergoes equals expansion (measured 2026-09-20: ``=ls`` became
    ``/usr/bin/ls``). Single quotes are literal in sh, bash and zsh alike.

    ``--slice=agents.slice`` is what puts the lane inside the host's memory budget; without it
    the lane runs in the ssh session scope, outside every cap.
    """
    argv = list(local_argv)
    argv.insert(1, "--slice=agents.slice")
    cmd = " ".join(remote.shquote(a) for a in argv)
    return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", machine.ssh, cmd]


def send_brief(ctx, machine, remote_path: str, text: str) -> None:
    """Write ``text`` to ``remote_path`` on ``machine``, with the content on ssh's STDIN.

    Nothing but a path rabota generated crosses the remote command line. A failure raises rather
    than returning, because a lane whose brief never arrived starts and then reads nothing.
    """
    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", machine.ssh,
            f"cat > {remote.shquote(remote_path)}"]
    res = ctx.runner.run(argv, input=text)
    if not res.ok:
        raise errors.Error(f"could not write the brief to {machine.name}: {(res.err or res.out).strip()}")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rabota && python3 -m unittest tests.test_lane_recipe -v`
Expected: PASS.

- [ ] **Step 5: Write the failing test for the command entry point**

Append to `rabota/tests/test_lane_recipe.py`:

```python
class RunRecipeTests(LocalRecipeTests):
    def brief(self):
        p = Path(tempfile.mkdtemp()); self.addCleanup(lambda: None)
        f = p / "brief.md"; f.write_text("# Brief\nDo the thing.\n")
        return str(f)

    def kw(self, **over):
        base = dict(brief=self.brief(), repo="hub", machine="dev", base=None, seat=None,
                    model="claude-sonnet-5", effort="medium", est_minutes=30, run=False)
        base.update(over); return base

    def ok_budget(self):
        return {"allowed_new_lanes": 2, "reasons": [], "seat_pick": "quantivly-0"}

    def test_a_dry_recipe_runs_nothing(self):
        runner = FakeRunner([])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw())
        self.assertEqual(runner.calls, [])
        self.assertEqual(out["machine"], "dev")
        self.assertEqual(out["seat"], "quantivly-0")
        self.assertTrue(out["unit"].startswith("rabota-lane-quantivly-"))
        self.assertIn("--slice=agents.slice", out["shell"])

    def test_a_dry_recipe_records_no_row(self):
        ctx = self.ctx(FakeRunner([]))
        lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw())
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])

    def test_zero_budget_refuses_and_records_no_row(self):
        ctx = self.ctx(FakeRunner([]))
        zero = {"allowed_new_lanes": 0, "reasons": [{"code": "machine:load", "detail": "busy"}],
                "seat_pick": "quantivly-0"}
        with self.assertRaises(errors.Refused):
            lane.run_recipe(ctx, budget_fn=lambda **_: zero, **self.kw(run=True))
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])

    def test_an_unknown_repo_for_the_machine_refuses(self):
        ctx = self.ctx(FakeRunner([]))
        with self.assertRaises(errors.Refused):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(repo="nosuch"))

    def test_run_creates_the_worktree_sends_the_brief_then_starts_the_unit(self):
        runner = FakeRunner([(["ssh"], Result(0, "", ""))])
        ctx = self.ctx(runner)
        out = lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        joined = [" ".join(c) for c in runner.calls]
        self.assertEqual(len(runner.calls), 3)
        self.assertIn("git -C", joined[0]); self.assertIn("worktree add", joined[0])
        self.assertIn("cat > ", joined[1])
        self.assertIn("systemd-run", joined[2])
        self.assertEqual(ctx.store.list_lanes("quantivly")[0]["status"], "started")
        self.assertEqual(ctx.store.list_lanes("quantivly")[0]["unit"], out["unit"])

    def test_a_failed_unit_start_records_no_started_row(self):
        runner = FakeRunner([(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--", "dev",
                              "cat > "], Result(0, "", "")),
                             (["ssh"], Result(1, "", "Failed to start"))])
        ctx = self.ctx(runner)
        with self.assertRaises(errors.Error):
            lane.run_recipe(ctx, budget_fn=lambda **_: self.ok_budget(), **self.kw(run=True))
        self.assertEqual(ctx.store.list_lanes("quantivly"), [])
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd rabota && python3 -m unittest tests.test_lane_recipe.RunRecipeTests -v`
Expected: FAIL — `AttributeError: module 'rabota.commands.lane' has no attribute 'run_recipe'`

- [ ] **Step 7: Implement the entry point**

Add to `rabota/rabota/commands/lane.py`:

```python
def create_worktree_remote(ctx, machine, repo_path: str, worktree: str, base: str | None) -> None:
    """``git worktree add`` on ``machine``. Every value is single-quoted for the remote shell."""
    parts = ["git", "-C", repo_path, "worktree", "add", worktree]
    if base:
        parts.append(base)
    cmd = " ".join(remote.shquote(p) for p in parts)
    res = ctx.runner.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "--",
                          machine.ssh, cmd])
    if not res.ok:
        raise errors.Error(f"could not create the worktree on {machine.name}: "
                           f"{(res.err or res.out).strip()}")


def run_recipe(ctx, *, brief, repo, machine, base, seat, model, effort, est_minutes, run,
               budget_fn=None) -> dict:
    """Render one lane; with ``run``, create the worktree, send the brief and start the unit.

    Order matters and is asserted: budget BEFORE anything is created (a refusal writes no row and
    touches no machine), then worktree, then brief, then unit, then the row. The row is written
    only after the unit actually started — a ``started`` row for a unit that never started is a
    lie ``census`` would later try to settle.

    ``budget_fn`` exists so the tests can drive the gate without a clauth on the test machine; in
    production it is ``rabota budget``'s own ``run_budget``.
    """
    from rabota import budget as budget_mod
    m = ctx.tenant.machines.get(machine) if machine != "local" else None
    if machine != "local" and m is None:
        raise errors.Refused(f"tenant {ctx.tenant.name!r} declares no machine {machine!r}")

    seat_pick = budget_mod.seat_for(ctx.tenant, machine, override=seat)
    fn = budget_fn or (lambda **kw: budget_cmd.run_budget(ctx, **kw))
    b = fn(machine=machine, model=model, effort=effort, est_minutes=est_minutes, seat=seat_pick)
    if b["allowed_new_lanes"] <= 0:
        e = errors.Refused("; ".join(f"{r['code']}: {r['detail']}" for r in b["reasons"])
                           or "no lane capacity")
        e.budget = b
        raise e

    slug = Path(brief).stem
    unit = unit_name(ctx.tenant.name, slug)
    lane_id = unit.rsplit("-", 1)[-1].removesuffix(".service")
    if machine == "local":
        root = Path(ctx.tenant.state_dir).expanduser()
        repo_path = str(Path(ctx.tenant.root).expanduser() / repo)
    else:
        if repo not in m.repos:
            raise errors.Refused(f"machine {machine!r} declares no repo {repo!r} "
                                 f"([machines.{machine}].repos)")
        root = Path(m.state_dir)
        repo_path = m.repos[repo]
    worktree = str(root / "worktrees" / ctx.tenant.name / lane_id)
    out_dir = str(root / "out" / ctx.tenant.name / lane_id)
    remote_brief = f"{out_dir}/brief.md"

    argv = build_local(ctx, seat=seat_pick, repo=repo, worktree=worktree, out_dir=out_dir,
                       brief=remote_brief, model=model, effort=effort, unit=unit)
    if machine != "local":
        argv = build_remote(ctx, m, argv)
    out = {"argv": argv, "shell": " ".join(argv), "unit": unit, "seat": seat_pick,
           "machine": machine, "est_minutes": est_minutes, "worktree": worktree, "out_dir": out_dir}
    if not run:
        return out

    if machine == "local":
        raise errors.Refused("the local --run form is not implemented; use --machine dev")
    create_worktree_remote(ctx, m, repo_path, worktree, base)
    send_brief(ctx, m, remote_brief, Path(brief).read_text())
    res = ctx.runner.run(argv)
    if not res.ok:
        raise errors.Error(f"could not start {unit} on {machine}: {(res.err or res.out).strip()}")
    ctx.store.add_lane({"id": lane_id, "tenant": ctx.tenant.name, "kind": "work", "brief": brief,
                        "repo": repo, "worktree": worktree, "out_dir": out_dir, "machine": machine,
                        "unit": unit, "status": "started", "seat": seat_pick, "model": model,
                        "effort": effort, "five_h_pct_at_start": b.get("five_h_pct_now")})
    return out
```

Register it in `rabota/rabota/cli.py`. The existing pattern is one `_build(sub)` per command module,
collected in the command registry; add `lane` beside `budget` there, and in `lane.py`:

```python
def _build(sub):
    p = sub.add_parser("lane", help="render or run exactly one lane unit")
    s = p.add_subparsers(dest="lane_cmd", required=True)
    r = s.add_parser("recipe", help="print the lane argv; --run starts it")
    r.add_argument("--brief", required=True)
    r.add_argument("--repo", required=True)
    r.add_argument("--machine", default="local", choices=["local", "dev"])
    r.add_argument("--base", default=None)
    r.add_argument("--seat", default=None)
    r.add_argument("--model", default=None)
    r.add_argument("--effort", default=None)
    r.add_argument("--est-minutes", type=int, default=30)
    r.add_argument("--run", action="store_true")


def _run(ns, **ctx_kw):
    ctx = Context.from_namespace(ns, **ctx_kw)
    out = run_recipe(ctx, brief=ns.brief, repo=ns.repo, machine=ns.machine, base=ns.base,
                     seat=ns.seat, model=ns.model or ctx.tenant.lanes.default_model,
                     effort=ns.effort or ctx.tenant.lanes.default_effort,
                     est_minutes=ns.est_minutes, run=ns.run)
    return emit.emit(ctx, out, text=lambda o: f"{o['unit']}\n{o['shell']}\n")
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd rabota && python3 -m unittest tests.test_lane_recipe -v`
Expected: PASS.

- [ ] **Step 9: Mutation sweep** (apply, confirm the named rows fail, revert):
  - `remote.shquote(a)` → `a` in `build_remote`: "every element is single-quoted" and the `=ls` row fail.
  - Delete the `argv.insert(1, "--slice=agents.slice")` line: "a remote lane joins the agents slice" fails.
  - `ctx.runner.run(argv, input=text)` → `ctx.runner.run(argv + [text])`: "the brief travels on stdin" fails.
  - Replace `send_brief`'s `raise errors.Error(...)` with `return`: "a failed brief send is an error" fails.
  - Move the `add_lane` call above `res = ctx.runner.run(argv)`: "a failed unit start records no started row" fails.
  - Move the budget check below `create_worktree_remote`: "zero budget refuses and records no row" still passes, but "run creates the worktree… " changes its call count — if no row fails, the order is untested; add one.

- [ ] **Step 10: Run the whole suite and commit**

```bash
cd rabota && python3 -m unittest discover -s tests -t .
git add rabota/rabota/commands/lane.py rabota/rabota/cli.py rabota/tests/test_lane_recipe.py
git commit -m "feat(rabota): lane recipe dispatches to a remote machine, brief on stdin"
```

---

## Task 8: close the `--state-dir` seam and assert the cache coupling

`budget` reads `census.json` from `ctx.state_dir`, and `--state-dir` is a global flag — so a stale
or hand-written census could manufacture room. Separately, a dev lane cannot start when the
laptop's clauth cache for the remote seat is stale, and nothing says so.

**Files:**
- Modify: `rabota/rabota/budget.py` — census freshness.
- Modify: `rabota/rabota/commands/doctor.py` — seat-cache assertion.
- Test: `rabota/tests/test_budget.py`, `rabota/tests/test_doctor.py`.

**Interfaces:**
- Consumes: `census["at"]` (ISO-8601 from `store.now()`), `BudgetThresholds`.
- Produces: `budget.compute(..., max_census_age_s: int = 900)`; a `census:stale` reason code.

- [ ] **Step 1: Write the failing test**

Append to `rabota/tests/test_budget.py`:

```python
class CensusFreshnessTests(MachineDimensionTests):
    def test_a_stale_census_refuses_rather_than_granting_room(self):
        c = census_with(dev=DEV_IDLE); c["at"] = "2020-01-01T00:00:00Z"
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev", max_census_age_s=900)
        self.assertEqual([r["code"] for r in b["reasons"]], ["census:stale"])
        self.assertEqual(b["allowed_new_lanes"], 0)

    def test_a_census_with_no_timestamp_refuses(self):
        c = census_with(dev=DEV_IDLE); c.pop("at", None)
        b = budget.compute(c, OK_CRED, self.t(), 3, machine="dev")
        self.assertEqual([r["code"] for r in b["reasons"]], ["census:stale"])
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd rabota && python3 -m unittest tests.test_budget.CensusFreshnessTests -v`
Expected: FAIL — `compute() got an unexpected keyword argument 'max_census_age_s'`

- [ ] **Step 3: Implement**

In `compute`, add the parameter `max_census_age_s: int = 900` and, in the `else` branch before
`_reading_for`, insert:

```python
        if not _census_fresh(census, max_census_age_s):
            reasons.append({"code": "census:stale",
                            "detail": f"census.json is missing 'at' or older than {max_census_age_s}s; "
                                      "run rabota census"})
```

and add:

```python
def _census_fresh(census: dict, max_age_s: int) -> bool:
    """A census with no timestamp, or an unparseable one, is stale — never fresh by default.

    ``--state-dir`` lets a caller point ``budget`` at any directory, so the file's own age is the
    only thing standing between a hand-written census and manufactured room.
    """
    at = census.get("at")
    if not at:
        return False
    try:
        ts = datetime.datetime.fromisoformat(str(at).replace("Z", "+00:00"))
    except ValueError:
        return False
    age = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()
    return 0 <= age <= max_age_s
```

with `import datetime` at the top of `budget.py`.

Add to `rabota/rabota/commands/doctor.py` a check function following that file's existing shape,
returning `(ok: bool, detail: str)` per machine:

```python
def seat_cache_age(ctx, max_age_s: int = 600) -> list[tuple[str, bool, str]]:
    """Per machine with a seat: is this box's usage cache for that seat fresh enough to gate on?

    A dev lane's credential dimension is answered HERE, from this machine's monitoring grant for
    the remote seat (the window is server-side, so any grant on the account reports it). If clauth
    stops polling, the gate goes unmeasured and dev lanes refuse even though dev is fine. That
    coupling is invisible from either machine, so it is asserted rather than assumed.
    """
    rows = []
    for name, m in sorted(ctx.tenant.machines.items()):
        if not m.profile:
            continue
        res = ctx.runner.run(["claude-pick", "--json", "--profile", m.profile])
        if not res.ok:
            rows.append((name, False, f"claude-pick exited {res.code} for {m.profile}")); continue
        try:
            age = json.loads(res.out)["usage"]["cache_age_s"]
        except (json.JSONDecodeError, KeyError, TypeError):
            rows.append((name, False, f"claude-pick printed no usage.cache_age_s for {m.profile}")); continue
        ok = age <= max_age_s
        rows.append((name, ok, f"{m.profile}'s usage cache is {age}s old"
                     + ("" if ok else f"; lanes on {name} will refuse with credential:unmeasured "
                                      "until clauth polls it")))
    return rows
```

And the tests. Append to `rabota/tests/test_doctor.py`:

```python
class SeatCacheAgeTests(unittest.TestCase):
    def ctx(self, runner):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup)
        ns = argparse.Namespace(tenant="quantivly", state_dir=str(Path(tmp.name)), text=False, dry_run=False)
        return context.Context.from_namespace(ns, cfg_base=FIX / "config", runner=runner,
                                              env={"PATH": "/bin"}, cwd=Path("/"))

    def pick(self, age):
        return Result(0, json.dumps({"usage": {"five_hour": 5, "cache_age_s": age}}), "")

    def test_a_fresh_cache_passes(self):
        rows = doctor.seat_cache_age(self.ctx(FakeRunner([(["claude-pick"], self.pick(30))])))
        self.assertEqual([(n, ok) for n, ok, _ in rows], [("dev", True)])

    def test_a_stale_cache_fails_and_names_the_consequence(self):
        rows = doctor.seat_cache_age(self.ctx(FakeRunner([(["claude-pick"], self.pick(4000))])))
        self.assertFalse(rows[0][1])
        self.assertIn("credential:unmeasured", rows[0][2])

    def test_claude_pick_failing_is_a_fail_not_a_pass(self):
        rows = doctor.seat_cache_age(self.ctx(FakeRunner([(["claude-pick"], Result(5, "", "no clauth"))])))
        self.assertFalse(rows[0][1])

    def test_missing_cache_age_is_a_fail_not_a_zero(self):
        runner = FakeRunner([(["claude-pick"], Result(0, json.dumps({"usage": {}}), ""))])
        rows = doctor.seat_cache_age(self.ctx(runner))
        self.assertFalse(rows[0][1])
```

Wire `seat_cache_age` into `doctor`'s report alongside the existing checks, so a FAIL carries into
its exit status.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd rabota && python3 -m unittest tests.test_budget tests.test_doctor -v`
Expected: PASS.

- [ ] **Step 5: Run the whole suite and commit**

```bash
cd rabota && python3 -m unittest discover -s tests -t .
git add rabota/rabota/budget.py rabota/rabota/commands/doctor.py rabota/tests/test_budget.py rabota/tests/test_doctor.py
git commit -m "feat(rabota): refuse a stale census, and name the seat-cache coupling in doctor"
```

---

## Task 9: the permission rule and the live smoke (gated)

**Files:**
- Modify: `~/.claude/settings.json` (user-level, not in this repo)
- Modify: `docs/HERDR_GUIDE.md` §9

**Interfaces:**
- Consumes: everything above.
- Produces: nothing other code reads.

- [ ] **Step 1: Print the exact edit and WAIT for Zvi's typed OK**

Add `"Bash(rabota lane recipe:*)"` to `permissions.allow` in `~/.claude/settings.json`, then:

```bash
scripts/claude-account-dirs.sh --all
```

Rationale to state when asking: the classifier is non-deterministic (it refused
`ssh dev "systemd-run --user …"` twice in STATUS.md's Blocker A, and on 2026-09-20 refused and then
allowed an identical Linear write), so an explicit rule is the only durable answer. Machines and
seats resolve only from `~/.dotfiles-local/rabota/tenants/*.toml`; no environment variable or CLI
flag redirects the config base, so this rule pins what it appears to pin.

- [ ] **Step 2: Dry run first, and read it**

Run: `rabota lane recipe --brief <path> --repo hub --machine dev`
Expected: JSON with `seat: "quantivly-0"`, `machine: "dev"`, an `argv` whose last element contains
`--slice=agents.slice`, an absolute claude path, and no brief contents anywhere.

- [ ] **Step 3: One real lane**

Run: `rabota lane recipe --brief <path> --repo hub --machine dev --run`
Then: `ssh -o BatchMode=yes dev 'systemctl --user list-units --plain --no-legend "rabota-lane-*"'`
Expected: one active unit.
Then: `ssh -o BatchMode=yes dev 'systemctl --user show <unit> -p ControlGroup'`
Expected: a path containing `agents.slice`.

- [ ] **Step 4: Let it finish, then close the loop**

Run: `rabota census && rabota lane list --tenant quantivly` (or read `lanes` rows directly)
Expected: the row is `done`, with `ended_at`, `cost_usd` and `five_h_pct_at_end` populated.

- [ ] **Step 5: Document both doors in `docs/HERDR_GUIDE.md` §9**

Attended work on dev: open `dev (EC2)` in the machine sidebar and spawn with herdr-draft's popup.
Headless work on dev: `rabota lane recipe --machine dev --run`. Not `dev-spawn` — herdr-draft does
not run headless lanes, and a lane's cgroup, `MemoryMax`, journal and clean stop come from systemd.

- [ ] **Step 6: Run the guard and commit**

```bash
./scripts/check-claude-md.sh
git add docs/HERDR_GUIDE.md
git commit -m "docs(herdr): both doors for work on dev (DO-635)"
```

---

## Task 10: correct the documents that describe deleted or dangerous work

**Files:**
- Modify: `~/quantivly/handoffs/rabota-v2/2026-09-16-consolidation-plan.md` §3.4
- Modify: `~/quantivly/handoffs/rabota-v2/plans/WS6-remote-dev.md`
- Modify: `docs/superpowers/plans/2026-09-19-do-635-dev-box-offload.md`

- [ ] **Step 1: The dangerous one first.** In `consolidation-plan.md` §3.4 Task 6.3, replace (d) —
  `git config --global url."https://github.com/quantivly/".insteadOf git@github.com:quantivly/` on
  dev — with: "done by DO-639, in `~/.gitconfig.local`. **Never `--global` on dev:** `~/.gitconfig`
  there is a symlink into the tracked, public `~/.dotfiles/gitconfig`." Update Step 4's verification
  from `git config --global --get …` to `git config --file ~/.gitconfig.local --get …`.

- [ ] **Step 2:** In the same §3.4, strike (b) and (c) — rabota, the `python3.11` shim and tenant
  config on dev are not needed; the recipe is rendered on the laptop and only the `systemd-run`
  line crosses.

- [ ] **Step 3:** In `WS6-remote-dev.md`, replace the Goal line and delete Task 6.4 — `lane start`,
  `lanes/runtime.py` and `commands/lane.py`'s `run_start`/`run_status`/`run_retire` were deleted by
  consolidation-design §4.1/§7. Point at this plan instead.

- [ ] **Step 4:** In `docs/superpowers/plans/2026-09-19-do-635-dev-box-offload.md`, move "headless
  `claude -p` lanes" out of §4's **Move** list, change the `agents.slice` `Description=` to
  `herdr panes and rabota lanes`, and mark Part D superseded by this plan.

- [ ] **Step 5:** Also in that plan, apply the review's remaining corrections to Part B (DO-640) —
  F7 the real ceiling, F8 `timeout 120`, F9 what the restart kills, F10 the "23 behind" ref, and
  `"timeout": 5` on B2's hook entry — per
  `~/quantivly/handoffs/2026-09-20-do-635-plan-review.md` §6.

- [ ] **Step 6: Commit**

```bash
./scripts/check-claude-md.sh
git add docs/superpowers/plans/2026-09-19-do-635-dev-box-offload.md
git commit -m "docs: DO-635 Part D is superseded; correct the lane-related sections"
```

The two files under `~/quantivly/handoffs/` are not in this repo — commit them wherever that tree
is versioned, or hand the edits to Zvi.
