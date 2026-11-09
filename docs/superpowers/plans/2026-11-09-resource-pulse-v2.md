# Resource Pulse v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Resource Pulse's sampling out of gnome-shell into a systemd user service. The extension becomes a
drawing-only D-Bus client. Fold in the verified review fixes, the "kernel" / "short jobs" split, the covered-card
gating and the top-bar dropdown.

**Architecture:** `service/` (inside the extension tree) runs under `gjs -m` as `resource-pulse.service`. It samples
with synchronous reads, keeps the histories, ranks apps, and serves JSON over the session bus. The extension's
`PulseClient` mirrors the old `Sampler` interface (`cpuHistory`, `memoryHistory`, `addListener`, `removeListener`,
`latestSnapshot`), so the card and indicator change only where the UX changes. Pure decisions live in `lib/` with
rows.

**Tech Stack:** GJS 1.88 (ES modules), GNOME Shell 50 (St, Clutter, PanelMenu, PopupMenu), Gio D-Bus, systemd user
units, bash (state-table runner), CI on ubuntu-latest (26.04).

**Spec:** `docs/superpowers/specs/2026-11-08-resource-pulse-service-design.md`, which amends
`docs/superpowers/specs/2026-11-07-resource-pulse-design.md`. The amendment wins where they disagree. Verified review
findings: `~/Projects/handoffs/2026-11-08-resource-pulse-review.md`.

## Global Constraints

Extension directory `E` = `gnome-shell/extensions/resource-pulse@dotfiles`.

### Placement and IO

- **The shell side** (`E/*.js` except `E/service/`, and `E/lib/`) never does file IO or starts a subprocess. All
  of its D-Bus calls are asynchronous with a timeout.
- **`E/service/`** may read files synchronously. It still starts no subprocess.
- **`E/lib/`** stays pure: no `gi://Shell`, `St`, `Clutter` or `Meta` imports, so it runs under plain `gjs -m`. It
  is shared by both sides.

### The interface and the unit

- **D-Bus:** bus name and interface `io.github.quantivly.dotfiles.ResourcePulse1`, object path
  `/io/github/quantivly/dotfiles/ResourcePulse1`, `PROTOCOL_VERSION = 1`. The JSON is additive-only: a reader
  ignores unknown fields, and a missing field gives no data for its own row only.
- **The unit** is `resource-pulse.service`:
  - no `[Install]` section;
  - `Type=dbus`, `BusName=` set to the name above;
  - `PartOf=graphical-session.target`, `Restart=on-failure`, `RestartSec=5`;
  - `Slice=background.slice`, `Nice=10`, `CPUQuota=10%`, `MemoryHigh=96M`, `MemoryMax=128M`.

### Cadence and labels

| Constant | Value |
|---|---|
| `SAMPLE_INTERVAL_SECONDS` | 2 |
| `APP_SCAN_INTERVAL_SECONDS` | 20 (watched) |
| `APP_SCAN_UNWATCHED_INTERVAL_SECONDS` | 60 |
| `BURST_CPU_RISE_POINTS` | 15 |
| `BURST_COOLDOWN_TICKS` | 2 |
| `REVEAL_SCAN_COOLDOWN_TICKS` | 2 |
| `CPU_IDLE_THRESHOLD_PERCENT` | 1 |
| `START_RETRY_DELAYS_SECONDS` | `[5, 30, 300]` (the last repeats) |
| client staleness | `SAMPLE_STALL_TICKS` (3) × 2 s |
| `KERNEL_LABEL` | `'kernel'` |
| `SHORT_JOBS_LABEL` | `'short jobs'` |
| `CPU_IDLE_LABEL` | `'idle'` |

Every literal with a role is a named constant in `E/lib/constants.js`.

### Rules for every task

- **Names and docs:** explicit, accurate names, and JSDoc on every new or changed function. Do not rewrite untouched
  code for style.
- **Test-first:** show each new row red before the fix and green after.
- **Row counts:** `EXPECTED_ROWS` in `scripts/test-resource-pulse.sh` and the guide's "(N checks" in
  `docs/GNOME_CONFIGURATION_GUIDE.md` move in the same commit as the rows.
- **Before each commit:** `bash scripts/test-resource-pulse.sh`, `shellcheck` on any touched script, and
  `pre-commit run --files <touched>`.
- **Never touch the live GNOME session:** no `gsettings set`, `gnome-extensions`, `gnome-shell`,
  `scripts/resource-pulse-nested.sh`, `systemctl --user start|stop|restart resource-pulse`, or `./install`. Reading
  `/proc` and `/sys` is fine.
- **Git:** never `git stash`; don't push. The commit trailer is `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **The service is not running, or restarts mid-session:** both surfaces show "no data since HH:MM" within 6 s,
   and recover by themselves when the name returns (Task 5 rows).
2. **Version skew** (a new service with extra fields, or a payload missing a field): no crash, only the affected
   row shows no data (Task 4 and Task 5 rows).
3. **Rapid cover and uncover, and `Super+D`:** no storm of scans (the reveal cooldown), and the repaint is
   immediate on reveal (Task 2 and Task 6 rows).
4. **A client that vanishes while holding a watch** (shell crash, extension disabled): the service drops the watch
   and falls back to the unwatched cadence (Task 4 row).
5. **A unit recreated at the same path, or a new leaf whose parent listing failed:** never double-counted, "short
   jobs" never negative (Task 1 rows).

---

### Task 1: Ranking and naming fixes in `lib/` (kernel, short jobs, groups, names, idle)

**Files:** Modify `E/lib/apps.js`, `E/lib/format.js`, `E/lib/constants.js`. Test `gnome-shell/tests/apps.test.js`
and the format test file.

**Interfaces:**
- Produces:
  - **`rankApps(scan)`.** The `scan` object gains three inputs:
    - `parentOfLeaf: Map<string,string>`;
    - `parentsListedPreviously: Set<string>`;
    - `parentCpuDeltaUsec: Map<string, number>` (parents read in both scans).

    `rootCpuDeltaUsec` keeps its name. It returns `{topCpu: {groupKey, name, cpuPercent}|null, topMemory: {groupKey,
    name, memoryBytes}|null}`. The pseudo group keys are `'pseudo:kernel'` and `'pseudo:short-jobs'`.
  - **`heaviestParts(apps)`** returns `{cpuHalf: {name, valueText}|null, memoryHalf: {name, valueText}|null,
    isCollapsed: boolean}`.
    - The CPU half is `{name: CPU_IDLE_LABEL, valueText: ''}` when `topCpu.cpuPercent < CPU_IDLE_THRESHOLD_PERCENT`.
    - `heaviestLine(apps)` is rebuilt on top of `heaviestParts`.
  - `KERNEL_LABEL`, `SHORT_JOBS_LABEL`, `CPU_IDLE_LABEL` and `CPU_IDLE_THRESHOLD_PERCENT` in constants. Remove
    `KERNEL_AND_OTHER_LABEL`.

- [ ] **Step 1: Write the failing rows** (each named for the rule it pins):
  - **Kernel:** kernel = root Δ − Σ parent Δ. Root 1000 ms with parents summing to 950 ms gives kernel 50 ms of
    machine time.
  - **A parent missing from `parentCpuDeltaUsec`:** neither kernel nor that parent's short jobs is ranked.
  - **Short jobs:** max(0, parent Δ − Σ its leaves' Δ), summed over parents.
    - A parent with 300 ms and leaves summing to 200 ms gives 100 ms.
    - A parent whose leaves sum above its Δ (read skew) contributes 0, never a negative number.
  - **Recreated leaf:** a counter that went backwards (prev 9 s, now 3 s) counts 3 s, not 0.
  - **New leaf:** a leaf absent from the previous scan counts its full usage when its parent is in
    `parentsListedPreviously`, and is skipped when it is not.
  - **Memory half:** never "kernel" or "short jobs", even when unattributed memory is huge.
  - **Collapse by group:** `docker.service` (CPU) and `docker-x.scope` (memory) share the name "docker" but are
    different groups, so they don't collapse. The same `groupKey` on both halves does collapse.
  - **Idle:** the top CPU entry at 0.6% gives the CPU half `idle`; at 1.0% it gives the name and percent.
  - **Naming:**
    - `app-gnome\x2dcalculator-1234.scope` gives app id `gnome-calculator`; the launcher is matched before
      unescaping;
    - `org.gnome.SettingsDaemon.Power.service` gives `gsd-power`;
    - `org.freedesktop.IBus.session.GNOME.service` gives `IBus.session.GNOME`;
    - `snap.slack.slack-<uuid>.scope` asks the resolver for `slack_slack.desktop` and falls back to `slack`.
- [ ] **Step 2: Run** `bash scripts/test-resource-pulse.sh`. Expected: the new rows fail.
- [ ] **Step 3: Implement** in `apps.js` and `format.js`. Update the in-shell `sampler.js` call sites only as needed
  to keep it compiling and passing: pass empty parent maps (and so no kernel or short-jobs entries). The service
  (Task 3) supplies the real inputs.
- [ ] **Step 4: Run the suite.** Expected: all rows pass, and the tally matches the new `EXPECTED_ROWS`.
- [ ] **Step 5: Update the guide's definitions table** for kernel, short jobs, idle and names, then commit.

### Task 2: Scan cadence as a pure decision (`lib/cadence.js`)

**Files:** Create `E/lib/cadence.js`. Modify `E/lib/constants.js`. Test `gnome-shell/tests/cadence.test.js`
(register it in the runner).

**Interfaces:**
- Produces **`decideAppScan(state)`**, which returns `{shouldScan: boolean, reason: 'first'|'interval'|'burst'|'watch-start'|'warm-up'|null}`.
  - `state` is `{isWatched, watchStartedThisTick, ticksSinceLastScan (null = never), warmUpPending,
    ticksSinceTriggeredScan (null = never), cpuBusyPercentNow, cpuBusyPercentAtLastScan, pressureBandsNow,
    pressureBandsAtLastScan}`.
  - Bands are arrays of band indexes for cpu, memory and io, with `null` meaning no data.
  - **Precedence:** first > watch-start > warm-up > burst > interval.
- Produces **`pressureBandIndex(percent)`**, which returns `0..3|null`, from `PRESSURE_BAND_THRESHOLDS_PERCENT`. Reuse
  `lib/pressure.js` if it already computes this.

- [ ] **Step 1: Write the failing rows:**
  - **First scan:** with no scan yet, scan with reason `first`.
  - **Intervals:** watched, scan at `ticksSinceLastScan === 10`, not at 9. Unwatched, scan at 30, not at 29.
  - **Watch start:** scan at once, except when `ticksSinceTriggeredScan < REVEAL_SCAN_COOLDOWN_TICKS` (2).
  - **Warm-up:** when `warmUpPending`, scan with reason `warm-up`.
  - **CPU burst (watched only):** CPU 40 → 55 scans; 40 → 54 does not; unwatched never bursts.
  - **Pressure burst:** a band rising (1 → 2) scans; a band falling or staying does not. A `null` band never
    triggers.
  - **Burst cooldown:** no burst while `ticksSinceTriggeredScan < BURST_COOLDOWN_TICKS`.
  - **No data:** a `null` CPU value never triggers a burst.
- [ ] **Step 2: Run.** Expected: the new rows fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: all rows pass.
- [ ] **Step 5: Commit.**

### Task 3: The service's sampler, with synchronous reads (`service/sampler.js`)

**Files:** Create `E/service/sampler.js`. Test `gnome-shell/tests/service-sampler.test.js` (register it), reusing
the existing fixtures. Leave `E/sampler.js` in place; Task 5 removes it.

**Interfaces:**
- Consumes `rankApps` (Task 1) and `decideAppScan` (Task 2).
- Produces **`ServiceSampler`**. Its constructor takes `{fsRoot, readFile, listDirectoryNames, nowUsec, clockLabel,
  resolveAppName, collectGarbage, logWriter}`. Each dependency is injectable and has a real default:
  - `readFile(path) → string`, through `Gio.File.load_contents`;
  - `listDirectoryNames(path) → string[]`;
  - `collectGarbage()`, through `System.gc()`;
  - `resolveAppName(desktopId) → string|null`, through `Gio.DesktopAppInfo`.

  Its methods:
  - `initialize()`, `start()`, `stop()`, `destroy()`;
  - `runTick(tickNumber)`, synchronous;
  - `setDetailWatched(isWatched)`;
  - `addListener(callback) → id`, `removeListener(id)`;
  - getters `latestSnapshot`, `cpuHistory` and `memoryHistory` (RingBuffers of `CARD_HISTORY_SAMPLES`; the top bar
    draws their newest `TOPBAR_HISTORY_SAMPLES`, as in v1) and `lastGoodClockLabel`.

  The snapshot keeps the v1 `Snapshot` typedef, with `apps` entries carrying `groupKey`.

- [ ] **Step 1: Port the rows.** Port every v1 `sampler.test.js` row that still applies to synchronous reads:
  - CPU deltas and no data on the first sample;
  - memory, swap from `/proc/swaps`, and PSI;
  - the cluster map;
  - no data on any failed read;
  - vanished cgroups (ENOENT and ENODEV);
  - publishing to listeners;
  - history gaps.

  Leave the async-only rows (stalls, in-flight, batching, priorities) for Task 5 to retire.
- [ ] **Step 2: Add the new rows:**
  - **zram:** only the `/dev/zramN` devices listed in `/proc/swaps` are read, with no `/sys/block` listing. A fake
    `listDirectoryNames` asserts it is never called with `/sys/block`.
  - **Parent reads:** the scan reads `cpu.stat` for the root and for each scanned parent (`app.slice`,
    `session.slice` and `background.slice` under `user@<uid>.service`, and `system.slice`). It passes them, with
    `parentOfLeaf` and `parentsListedPreviously`, to `rankApps`.
  - **Garbage collection:** `collectGarbage` is called once after each app scan, and never after a fast tick alone.
  - **Cadence:** `runTick` consults `decideAppScan`. Watched, the scan runs at ticks 0, 1 (warm-up), 10 and 20;
    unwatched, at 0, 1 and 30. `setDetailWatched(true)` scans on the next tick.
  - **Logging:** messages are rate-limited by template. 109 different cgroup paths failing with the same error log
    once per `ERROR_LOG_REPEAT_INTERVAL_USEC`, naming the count and the first path.
- [ ] **Step 3: Run.** Expected: the new rows fail.
- [ ] **Step 4: Implement** `service/sampler.js` from `E/sampler.js`, keeping its structure where it still fits.
  Drop the async readers, the batching, priorities and in-flight and stall machinery. A synchronous scan cannot be
  in flight across ticks.
- [ ] **Step 5: Run.** Expected: all rows pass. Then commit.

### Task 4: The service's D-Bus layer, the systemd unit and the install wiring

**Files:**
- Create:
  - `E/lib/protocol.js`;
  - `E/service/dbusService.js`;
  - `E/service/main.js`;
  - `systemd/resource-pulse.service`;
  - `gnome-shell/tests/protocol.test.js`;
  - `gnome-shell/tests/service-dbus.test.js`.
- Modify:
  - `install.conf.yaml` (one link, and a shell step);
  - `.github/workflows/ci.yml` (add whatever package provides `dbus-run-session` to the `resource-pulse-test` job,
    through `.github/actions/apt-install`);
  - `scripts/test-resource-pulse.sh`.

**Interfaces:**
- **`lib/protocol.js`:**
  - constants `PROTOCOL_VERSION`, `RESOURCE_PULSE_BUS_NAME`, `RESOURCE_PULSE_OBJECT_PATH` and
    `RESOURCE_PULSE_INTERFACE_XML`;
  - `buildStatePayload({snapshot, histories, serviceStartedAtUsec, sequence}) → string`;
  - `buildSamplePayload({snapshot, appendedHistory, sequence, sampledAtUsec}) → string`;
  - `parseStatePayload(text) → {protocol, snapshot, histories, serviceStartedAtUsec, sequence}|null`;
  - `parseSamplePayload(text) → {snapshot, appendedHistory, sequence, sampledAtUsec}|null`.

  `histories` is `{cpu, memory}`, each an array of numbers or nulls (up to `CARD_HISTORY_SAMPLES`), oldest first.
  `appendedHistory` is `{cpu, memory}`, the fractions appended this tick. The parsers are skew-tolerant: unknown
  fields are ignored, and a missing or mistyped field becomes `null` for that field only. A non-object or invalid
  JSON gives `null`.
- **`ResourcePulseDBusService(sampler, connection)`**:
  - exports `GetState() → s`, the `Sample(s)` signal (one per sampler publish), and `WatchDetail()` /
    `UnwatchDetail()`;
  - counts watches per sender, and drops a sender's watches when its name vanishes (`Gio.bus_watch_name_on_connection`
    on its unique name);
  - calls `sampler.setDetailWatched(totalWatches > 0)`.
- **`service/main.js`:** owns the bus name, starts the sampler, runs a `GLib.MainLoop`, and exits cleanly on SIGTERM
  (`GLib.unix_signal_add`).
- **`install.conf.yaml`:**
  - links `~/.config/systemd/user/resource-pulse.service` → `systemd/resource-pulse.service`;
  - adds a shell step: `systemctl --user daemon-reload`, then `try-restart resource-pulse.service` only when a file
    under `E/service/` or `E/lib/` is newer than the unit's `ActiveEnterTimestamp`. It does nothing when the unit is
    inactive, and is silent and successful when there is no user manager (a server).

- [ ] **Step 1: Write the failing rows:**
  - **Protocol round trip:** state and sample payloads round-trip.
  - **Protocol skew:** an unknown top-level and nested field is ignored; a missing `snapshot.swap` gives
    `swap: null`; `"not json"` gives `null`.
  - **D-Bus, on a private bus** (`dbus-run-session -- gjs -m`, a fake-sampler service):
    - `GetState` returns `protocol: 1` and the histories;
    - a `Sample` signal arrives after a publish;
    - `WatchDetail` from one connection, then closing that connection, calls `setDetailWatched(false)` within 2 s;
    - two watches from one sender need two unwatches.
  - **The unit file:** its keys equal the Global Constraints; it has no `[Install]` section; and `ExecStart`
    resolves to `E/service/main.js` (static rows).
- [ ] **Step 2: Run.** Expected: the new rows fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, and also run `systemd-analyze --user verify` on a copy whose `ExecStart` points at a stand-in.
  Expected: all rows pass, and the verify is silent about our unit.
- [ ] **Step 5: Commit.**

### Task 5: The extension becomes a client (`PulseClient`, wiring and static checks)

**Files:**
- Create `E/pulseClient.js` and `E/lib/wiring.js`.
- Modify `E/extension.js`.
- Delete `E/sampler.js` and the async-only rows of `gnome-shell/tests/sampler.test.js`; move what remains to
  Task 3's file if Task 3 has not already.
- Modify `scripts/test-resource-pulse.sh` (static checks).
- Test `gnome-shell/tests/wiring.test.js` and `gnome-shell/tests/client.test.js`.

**Interfaces:**
- Consumes `lib/protocol.js` (Task 4).
- **`lib/wiring.js`:**
  - `isDetailWatchWanted({isCardVisible, isDropdownOpen, isOverviewVisible}) → boolean`: true when
    `(isCardVisible && !isOverviewVisible) || isDropdownOpen`;
  - `isSampleStale({lastSampleReceivedAtUsec, nowUsec}) → boolean`;
  - `nextStartRetryDelaySeconds(attemptNumber) → number`.
- **`PulseClient`:**
  - constructor `({busType, startUnit, nowUsec})`, where `startUnit` is injectable;
  - `start()`, `destroy()`;
  - `setDetailWatchWanted(isWanted)`;
  - `addListener` / `removeListener`;
  - getters `cpuHistory`, `memoryHistory`, `latestSnapshot` and `lastGoodClockLabel`.

  How it behaves:
  - It calls `StartUnit('resource-pulse.service', 'replace')` on systemd's D-Bus asynchronously, with retry
    delays from `nextStartRetryDelaySeconds` on failure.
  - It follows the name owner. When an owner appears, it calls `GetState` (2 s timeout) and fills the
    RingBuffers.
  - On each `Sample` it appends to the histories and notifies listeners.
  - When stale, or when the `sequence` restarts, it publishes a no-data snapshot once, and stays in no data until a
    fresh `GetState`.
  - It re-asserts the watch after an owner change.
  - `destroy()` sends `UnwatchDetail` best-effort and cancels everything.
- **`extension.js`:**
  - builds a `PulseClient` instead of a `Sampler`;
  - follows the overview and the card's visibility through `isDetailWatchWanted`;
  - drops the shield pause, because the service keeps sampling and GNOME disables the extension on lock anyway.

- [ ] **Step 1: Write the failing rows:**
  - **Wiring:** every combination of `isDetailWatchWanted`;
  - **Staleness:** `isSampleStale` at exactly 6 s and at 6 s + 1 µs;
  - **Retries:** the delays are 5, 30, 300, 300;
  - **The client, with a fake proxy:**
    - no data before the first state;
    - histories filled from `GetState`;
    - a `Sample` appends and notifies;
    - a 6 s gap publishes no data once;
    - a sequence restart gives no data until `GetState`;
    - a failed `StartUnit` retries at 5 s;
    - a payload missing `swap` notifies with `swap: null` and the other rows intact;
    - the name losing its owner while the client runs publishes no data and does **not** call `StartUnit` (a
      deliberate stop stays stopped until the next `start()`);
    - `Sample` signals are drawn even when `StartUnit` failed, as in the nested harness, which has no systemd.
  - **Static checks:**
    - the no-sync-IO pattern covers the extension except `service/`, and is widened with `next_file(`,
      `next_files(`, `query_exists(`, `query_file_type(`, `GLib.file_test`, `read_all(`, `GLib.Dir.open`,
      `.read(null)`, `.close(null)` and `util_spawn`, each with a `FORBIDDEN_CALLS` row;
    - no file under `E/` except `service/` imports `service/`;
    - `service/` starts no subprocess.
- [ ] **Step 2: Run.** Expected: the new rows fail.
- [ ] **Step 3: Implement,** then delete `E/sampler.js` and the retired rows.
- [ ] **Step 4: Run.** Expected: all rows pass. Then commit.

### Task 6: Card UX: fixed width, covered gating, repaint on change

**Files:** Create `E/lib/visibility.js`. Modify `E/card.js`, `E/stylesheet.css` (additive classes only) and
`E/extension.js`. Test `gnome-shell/tests/visibility.test.js`.

**Interfaces:**
- Consumes `heaviestParts` (Task 1), `PulseClient` and `isDetailWatchWanted` (Task 5).
- **`lib/visibility.js`:** `isRectFullyCovered(cardRect, windowRects) → boolean`. Rects are `{x, y, width, height}`
  in stage pixels. It returns true only when one rect contains the whole card.
- **`PulseCard`:**
  - `setFrozen(isFrozen)`: while frozen, `update()` only records; unfreezing repaints at once from the client's
    latest state;
  - the heaviest row becomes two labels per half (name and value), with `clutter_text.ellipsize = END` on the names
    only;
  - a fixed width (a new class, `rp-card-fixed`);
  - the meters and the bar repaint only when their value changes.
- **The covered check in `extension.js`:** it collects the frame rects of non-minimized `NORMAL` and `DIALOG`
  windows on the active workspace that overlap the primary monitor. It treats `primaryMonitor.inFullscreen` as
  covered. It runs on every client update, on `global.display` `restacked`, and on window-manager
  `minimize`/`unminimize`. When covered, the card is frozen and the watch is not wanted; when uncovered, the opposite.

- [ ] **Step 1: Write the failing rows:**
  - **Contained or not:** a maximized window rect containing the card is covered; a rect covering 99% of it is not.
  - **No windows:** not covered.
  - **Edges:** rects that only touch the card's edges, or a rect equal to the card, follow the stated rule; pick
    one and pin it.
  - **Static:** `card.js` sets ellipsize on the name labels only; `stylesheet.css` keeps every v1 class name
    (stylesheet skew).
- [ ] **Step 2: Run.** Expected: the new rows fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: all rows pass. Then commit.

### Task 7: Top-bar dropdown

**Files:** Modify `E/indicator.js`, `E/extension.js` and `E/stylesheet.css` (additive). Test the static rows in the
runner.

**Interfaces:**
- Consumes `PulseCard` (Task 6) and `PulseClient` (Task 5).
- **`PulseIndicator`** becomes a `PanelMenu.Button`. Its menu holds a `PopupBaseMenuItem` (non-reactive) containing
  a second `PulseCard`, and a `PopupMenuItem` "Open Resources". That item launches the first installed id in
  `RESOURCES_APP_IDS`, and is hidden when none exists.
  - The hover label is suppressed while the menu is open.
  - `menu` `open-state-changed` drives `isDropdownOpen`.
  - The dropdown's card is never frozen.

- [ ] **Step 1: Write the failing static rows:**
  - `indicator.js` extends `PanelMenu.Button`;
  - the old click handler that launched Resources directly is gone;
  - "Open Resources" uses `RESOURCES_APP_IDS`.
- [ ] **Step 2: Run.** Expected: the new rows fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: all rows pass. Then commit.

### Task 8: Status, cost, the nested harness and docs

**Files:** Modify:
- `zsh/functions/system.sh` (the `gnome-status` Resource Pulse block);
- `scripts/resource-pulse-cost.sh`;
- `scripts/resource-pulse-nested.sh`;
- `docs/GNOME_CONFIGURATION_GUIDE.md`;
- `CHANGELOG.md`;
- `examples/gnome-settings.local.template`, if its comment needs to change.

**Interfaces:** none new. The tasks above produce what this documents.

- [ ] **Step 1: `gnome-status`:**
  - `enabled` reads the `enabled-extensions` setting, with `(starts at next login)` when the shell does not yet know
    the extension;
  - a `service:` field shows the unit's ActiveState and the age of its last sample;
  - a warning appears when any file in `E/` (except `service/`) is newer than the gnome-shell process's start time:
    "the desktop runs an older copy; takes effect at next login".

  Add rows where the repo's state tables cover `gnome-status`, if they do.
- [ ] **Step 2: `resource-pulse-cost.sh`** gains `--service`. It reads the service's `/proc/<MainPID>/stat` (from
  `systemctl --user show -p MainPID`) the same way it reads gnome-shell's: CPU percent over a window and RSS. Add rows
  with a fake `/proc` and a stub `systemctl`.
- [ ] **Step 3: The nested harness** starts the service on its private session bus (`gjs -m E/service/main.js`, with
  the private `DBUS_SESSION_BUS_ADDRESS`) before the shell, and stops it on `stop`. Add rows in its existing state
  table.
- [ ] **Step 4: Docs.**
  - **The guide:** the definitions table; how it runs (service plus extension, deploy and restart, no logout for
    data changes); the cost section with the new budgets; the test counts.
  - **CHANGELOG:** extend the Unreleased Resource Pulse entry.
- [ ] **Step 5: Run** the suite, `shellcheck`, `pre-commit run --files`, `./scripts/check-claude-md.sh` and
  `./scripts/check-state-table-totals.sh`. Then commit.
