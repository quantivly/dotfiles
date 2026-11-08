# Resource Pulse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One small, opt-in GNOME Shell 50 extension in this repo that draws live CPU and memory as two mini
graphs in the top bar and a detailed "quiet card" on the desktop, both fed by one sampler.

**Architecture:**
- **`lib/` modules hold all the logic** (parsing, maths, naming, formatting) and have no Shell imports.
- **`sampler.js`** does the async Gio reads and the timing. It uses Gio and GLib only.
- **Pure-logic tests.** `lib/` and the sampler both run under plain `gjs -m` against fixture trees, in CI.
- **Shell glue.** `extension.js`, `indicator.js` and `card.js` are thin, and are verified in a nested
  shell.
- **Repo wiring.** A dotbot link, an opt-in `genable_extension` helper, `gnome-status`, docs.

**Tech Stack:**
- GJS ESM (GNOME Shell 50, St/Clutter, Cairo), with Gio async IO;
- bash for the state table and repo wiring;
- GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-07-resource-pulse-design.md`. Read it first. Its "Every number,
defined" table is the correctness contract, and this plan copies its values.

## Global Constraints

**Version and identity:**
- GNOME Shell 50 only: `metadata.json` has `"shell-version": ["50"]` and no `session-modes` key.
- UUID `resource-pulse@dotfiles`. The extension lives in `gnome-shell/extensions/resource-pulse@dotfiles/`
  and its tests in `gnome-shell/tests/`.

**Code rules:**
- **The extension never blocks the shell.**
  - No `Gio.Subprocess`, `GLib.spawn*` or `Util.spawn`.
  - No GTop.
  - No synchronous file IO (`load_contents(`, `GLib.file_get_contents`).
  - No network.
- **`lib/`, `sampler.js` and `graph.js` never import `resource:///`.**
- **Constants and names:**
  - every tunable is a named constant with its unit, in `lib/constants.js`;
  - names are explicit;
  - every function gets JSDoc.
  - These are the user's code rules in their global CLAUDE.md.

**Values from the spec (verbatim):**
- **Timing and history:** `SAMPLE_INTERVAL_SECONDS = 2`, `APP_SCAN_INTERVAL_SECONDS = 6`. Top bar
  history 30 samples, card history 150.
- **Pressure:** PSI meter bands are `< 10`, `10–25`, `25–50` and `≥ 50` (%), using `some avg10`.
- **Display:**
  - GiB with one decimal, whole-number percents;
  - app CPU is a share of the whole machine;
  - the first sample is *no data*, never 0%;
  - **stale numbers are never drawn as live.**
- **Logging:** the journal prefix is `resource-pulse:`, with each distinct message logged at most once per
  10 minutes.

**Rollout and repo rules:**
- **Opt-in.** Nothing enables the extension except a `genable_extension resource-pulse@dotfiles` line in
  `~/.gnome-settings.local`.
- **CLAUDE.md:** the net byte change is ≤ 0. There are 154 bytes of headroom (`scripts/check-claude-md.sh`
  reported size 45636, ceiling 45790).
- **CI:** every apt install goes through `./.github/actions/apt-install`.
- **Git:**
  - never `git stash`;
  - commits are imperative and end with the `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
    trailer;
  - work stays in this worktree (`zvi/gnome-customization`);
  - **never run `./install` from a worktree.**
- **Read GNOME 50's real source; don't guess an API.** Run
  `gresource extract /usr/lib/gnome-shell/libshell-18.so /org/gnome/shell/ui/<file>.js`, for example on
  `panelMenu.js`, `panel.js`, `layout.js`, `dash.js` (for the label style) or `screenShield.js`.

## Review Focus

These are failure modes the spec implies but would otherwise go untested. Each now has a test in its
owning task.

1. **The screen locks while a read is in flight.** The lock disables the extension, and the late promise
   must not notify listeners or push history. Pinned in Task 5.
2. **Docking or undocking a monitor.** The card must land inside the primary monitor's work area, never
   off screen. Pinned in Task 4 (`cardPosition`) and wired in Task 7.
3. **Long app names**, such as `gnome-session-manager` or a long snap name, must not stretch the card.
   Names are ellipsized to `APP_NAME_MAX_CHARS = 18`. Pinned in Task 4.
4. **A cluster with offline CPUs.** If some CPUs have no `cpuN` line, the cluster % comes from the
   present CPUs. With none present, it is `null` and the suffix is omitted. Pinned in Task 2.
5. **The extension sits in `disabled-extensions`.** That key takes precedence over `enabled-extensions` in
   GNOME 50 (`extensionSystem.js` `_getEnabledExtensions`), so `genable_extension` must remove it there.
   Otherwise it reports success while nothing loads. Pinned in Task 8.

---

### Task 1: Test harness, fixtures, parsers and the CI job

**Files:**
- Create: `gnome-shell/extensions/resource-pulse@dotfiles/lib/procParsers.js`
- Create: `gnome-shell/extensions/resource-pulse@dotfiles/lib/cgroupParsers.js`
- Create: `gnome-shell/tests/harness.js`, `gnome-shell/tests/run.js`, `gnome-shell/tests/parsers.test.js`
- Create: `gnome-shell/tests/fixtures/real/` holds captures from this laptop: `proc-stat`, `meminfo`,
  `pressure-cpu`, `zram-mm_stat`. Copy them with `cat` and commit them. They hold no identifying data.
- Create: `scripts/test-resource-pulse.sh`, executable.
- Modify: `.github/workflows/ci.yml`, adding a new job after `dock-wifi-test`.

**Interfaces:**
- Produces, in `harness.js`:
  - `test(name: string, body: () => (void|Promise<void>)): void`;
  - `assertEqual(actual, expected, detail?: string): void`, which uses JSON comparison for
    objects/arrays/Maps converted to arrays;
  - `assertClose(actual: number, expected: number, epsilon: number): void`;
  - `runAll(): Promise<{passCount: number, failCount: number}>`.
- Produces, in `run.js`:
  - it imports every `*.test.js` **by a static list**, so a missing file is an import error, never a
    silently smaller run;
  - it runs `runAll()` inside an explicit `GLib.MainLoop`. Top-level await alone is not relied on, because
    CI's gjs is 1.80;
  - it prints one row per test (`  ✓ <name>` or `  ✗ <name> — <detail>`) and then exactly one line,
    `JS-TALLY pass=<n> fail=<n>`;
  - it exits 1 on any failure.
- Produces, in `procParsers.js`:
  - `parseProcStat(text) → {aggregate: CpuTimes, perCpu: Map<number, CpuTimes>}`;
  - `CpuTimes = {user, nice, system, idle, iowait, irq, softirq, steal, guest, guestNice}`;
  - `parseMeminfo(text) → Map<string, number>`, converting kB to **bytes**;
  - `parsePressureSomeAvg10(text) → number|null`;
  - `parseZramMmStat(text) → {storedBytes, ramBytes}|null`, where stored is field 1 and ram is field 3
    (`mem_used_total`);
  - `parseUid(statusText) → number|null`, the first field of `Uid:`.
- Produces, in `cgroupParsers.js`:
  - `parseCpuStatUsageUsec(text) → number|null`;
  - `parseMemoryStatReclaimableBytes(text) → number|null`, which is `active_file + inactive_file`;
  - `parseSingleNumber(text) → number|null`, used for `memory.current`.

- [ ] **Step 1: Write the harness, `run.js` and the failing parser tests.** Rows, with exact values:

```js
test('mm_stat: RAM cost is mem_used_total (field 3), not compr_data_size (field 2)', () => {
    const zram = parseZramMmStat('1567870976 386016017 397680640        0 397688832     2083     3855     2147     2687\n');
    assertEqual(zram, {storedBytes: 1567870976, ramBytes: 397680640});
});
test('meminfo: kB values become bytes', () =>
    assertEqual(parseMeminfo('MemTotal:       32000000 kB\nMemAvailable:   12000000 kB\n').get('MemAvailable'), 12000000 * 1024));
test('PSI: reads the some line avg10, ignores the full line', () =>
    assertEqual(parsePressureSomeAvg10('some avg10=4.70 avg60=5.19 avg300=4.63 total=1\nfull avg10=9.00 avg60=0 avg300=0 total=0\n'), 4.7));
test('/proc/stat: guest and guest_nice parse into their own fields', () => {
    const {aggregate} = parseProcStat('cpu  100 0 100 700 100 0 0 0 50 7\ncpu0 100 0 100 700 100 0 0 0 50 7\n');
    assertEqual([aggregate.guest, aggregate.guestNice], [50, 7]);
});
test('/proc/stat: the real capture yields 8 per-CPU entries', () => /* fixtures/real/proc-stat */ assertEqual(parsed.perCpu.size, 8));
test('malformed lines yield null, never NaN', () => assertEqual(parseZramMmStat('garbage\n'), null));
test('memory.stat: reclaimable = active_file + inactive_file', () =>
    assertEqual(parseMemoryStatReclaimableBytes('anon 10\nactive_file 300\ninactive_file 200\nshmem 5\n'), 500));
test('cpu.stat: usage_usec', () => assertEqual(parseCpuStatUsageUsec('usage_usec 89812225000\nuser_usec 1\n'), 89812225000));
test('status: Uid', () => assertEqual(parseUid('Name:\tgnome-shell\nUid:\t1000\t1000\t1000\t1000\n'), 1000));
```

- [ ] **Step 2: Write `scripts/test-resource-pulse.sh`.**
  - Copy the shape of `scripts/test-dock-wifi.sh`: `ok`/`bad`/`check`/`fatal`, `PASS`/`FAIL`, and a final
    `EXPECTED_ROWS=<n>` total check.
  - It runs `gjs -m gnome-shell/tests/run.js`, echoes its output, and adds the anchored tally line
    (`^JS-TALLY pass=([0-9]+) fail=([0-9]+)$`) to `PASS`/`FAIL`.
  - **A missing tally line, or a missing `gjs`, is `fatal` (exit 2), never a pass.**
- [ ] **Step 3: Run it.** `scripts/test-resource-pulse.sh`. Expected: it fails, because the parsers are
  undefined. The output must show an import error, not a tally of 0 passes.
- [ ] **Step 4: Implement both parser modules.** A line that cannot be parsed yields `null`.
- [ ] **Step 5: Run it.** Expected: every row passes, and `EXPECTED_ROWS` equals the number of rows. Set
  it now, and every later task bumps it by the rows it adds.
- [ ] **Step 6: Add the CI job.**
  - The job is `resource-pulse-test`, named "Resource Pulse State Table", on `ubuntu-latest`.
  - Its steps: checkout, then `./.github/actions/apt-install` with `packages: gjs`, then
    `./scripts/test-resource-pulse.sh`.
  - Run `scripts/check-workflow-apt.sh` and `scripts/check-state-table-totals.sh`. Both must pass.
- [ ] **Step 7: Commit.** "Add Resource Pulse parsers and their state table".

---

### Task 2: CPU, memory, pressure and history maths

**Files:**
- Create: `gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js`
- Create: `.../lib/cpu.js`, `.../lib/memory.js`, `.../lib/pressure.js`, `.../lib/history.js`
- Test: `gnome-shell/tests/math.test.js`, added to `run.js`'s static list.

**Interfaces:**
- Consumes `CpuTimes` (Task 1).
- Produces, in `cpu.js`:
  - `cpuBusyFraction(previous: CpuTimes|null, current: CpuTimes|null) → number|null`. The total is
    user+nice+system+idle+iowait+irq+softirq+steal, so guest is excluded; idle is idle+iowait. A missing
    `previous`, or Δtotal ≤ 0, gives `null`.
  - `clusterBusyFraction(previousPerCpu: Map, currentPerCpu: Map, cpus: number[]) → number|null` sums the
    deltas over the CPUs present in both maps, and gives `null` when none are present.
  - `parseCpuList(text) → number[]` parses forms like `"0-3,6,8-9"`.
  - `buildClusterMap({corePmuCpus, atomPmuCpus, capacities: Map<number, number>, cpuCount}) →
    {performanceCpus, efficiencyCpus}|null`. The order of preference:
    - the PMU lists, when both are non-empty;
    - otherwise capacities: P = capacity ≥ `PERFORMANCE_CAPACITY_RATIO` (0.9) × max, and E = the rest;
    - otherwise, or when E would be empty, `null`.

    This clarifies the spec's "group by distinct cpu_capacity": this laptop's P cores read 1024 and 1005,
    and must stay one cluster.
- Produces, in `memory.js`:
  - `memoryUsage(meminfo) → {usedBytes, totalBytes}|null`, where used = MemTotal − MemAvailable;
  - `swapSummary(meminfo, zramDevices: Array<{storedBytes, ramBytes}>) → {swappedBytes, zramStoredBytes,
    zramRamBytes, diskBytes}|null`, where disk = max(0, swapped − Σstored).
- Produces, in `pressure.js`:
  - `pressureBand(avg10Percent: number|null) → 0|1|2|3|null`, using
    `PRESSURE_BAND_THRESHOLDS_PERCENT = [10, 25, 50]`.
- Produces, in `history.js`:
  - `class RingBuffer`, with `constructor(capacity)`, `push(value: number|null)`,
    `values() → Array<number|null>` (oldest first), `lastValues(count)` and `clear()`.
- Produces, in `constants.js`:
  - `SAMPLE_INTERVAL_SECONDS = 2`, `APP_SCAN_INTERVAL_SECONDS = 6`, `APP_SCAN_EVERY_N_TICKS = 3`;
  - `TOPBAR_HISTORY_SAMPLES = 30`, `CARD_HISTORY_SAMPLES = 150`;
  - `PRESSURE_BAND_THRESHOLDS_PERCENT`, `PERFORMANCE_CAPACITY_RATIO`;
  - `ERROR_LOG_REPEAT_INTERVAL_USEC = 600_000_000`;
  - `APP_NAME_MAX_CHARS = 18`, `CARD_MARGIN_PX = 24`;
  - `RESOURCES_APP_IDS = ['net.nokyan.Resources.desktop', 'org.gnome.SystemMonitor.desktop']`;
  - `HOVER_LABEL_DELAY_MS = 300`;
  - `LOG_PREFIX = 'resource-pulse:'`.

- [ ] **Step 1: Write the failing tests.** Each row fails under one specific wrong formula:

```js
const times = (user, system, idle, iowait, guest = 0) =>
    ({user, nice: 0, system, idle, iowait, irq: 0, softirq: 0, steal: 0, guest, guestNice: 0});
test('CPU busy excludes guest from the total (counting it gives 64%)', () =>
    assertClose(cpuBusyFraction(times(100, 100, 700, 100, 50), times(200, 150, 800, 100, 80)), 0.6, 1e-9));
test('iowait counts as idle (counting it busy gives 67%)', () =>
    assertClose(cpuBusyFraction(times(0, 0, 0, 0), times(50, 0, 50, 50)), 1 / 3, 1e-9));
test('first sample is no data, not 0', () => assertEqual(cpuBusyFraction(null, times(1, 1, 1, 1)), null));
test('no delta is no data, not NaN', () => assertEqual(cpuBusyFraction(times(1, 1, 1, 1), times(1, 1, 1, 1)), null));
test('a cluster uses only the CPUs present (offline CPUs have no line)', /* cpus [0,1,2,3], only 0 and 1 present */ ...);
test('a cluster with no CPU present is null', ...);
test('cluster map: hybrid PMU wins', () =>
    assertEqual(buildClusterMap({corePmuCpus: [0, 1, 2, 3], atomPmuCpus: [4, 5, 6, 7], capacities: new Map(), cpuCount: 8}),
        {performanceCpus: [0, 1, 2, 3], efficiencyCpus: [4, 5, 6, 7]}));
test('cluster map: capacity fallback keeps 1024 and 1005 together', () =>
    assertEqual(buildClusterMap({corePmuCpus: [], atomPmuCpus: [],
        capacities: new Map([[0, 1024], [1, 1024], [2, 1005], [3, 1005], [4, 676], [5, 676], [6, 676], [7, 676]]), cpuCount: 8}),
        {performanceCpus: [0, 1, 2, 3], efficiencyCpus: [4, 5, 6, 7]}));
test('cluster map: equal capacities → single cluster (null)', ...);
test('memory used = MemTotal − MemAvailable, not MemTotal − MemFree', () =>
    assertEqual(memoryUsage(new Map([['MemTotal', 32000000 * 1024], ['MemFree', 1000000 * 1024], ['MemAvailable', 12000000 * 1024]])).usedBytes,
        20000000 * 1024));
test('swap on disk = swapped − zram stored', () =>
    assertEqual(swapSummary(new Map([['SwapTotal', 24000000 * 1024], ['SwapFree', 22000000 * 1024]]),
        [{storedBytes: 1536000000, ramBytes: 400000000}]).diskBytes, 2048000000 - 1536000000));
test('no zram: all swap is on disk', ...);
test('PSI bands at the edges', () =>
    assertEqual([9.99, 10, 24.99, 25, 49.99, 50, null].map(pressureBand), [0, 1, 1, 2, 2, 3, null]));
test('ring buffer drops the oldest and keeps null gaps', ...);
```

- [ ] **Step 2: Run it.** `scripts/test-resource-pulse.sh`. Expected: the new rows fail.
- [ ] **Step 3: Implement the four modules and `constants.js`.**
- [ ] **Step 4: Run it.** Expected: everything passes, with `EXPECTED_ROWS` bumped.
- [ ] **Step 5: Commit.** "Add Resource Pulse CPU, memory and pressure maths".

---

### Task 3: Naming, grouping and ranking apps

**Files:**
- Create: `gnome-shell/extensions/resource-pulse@dotfiles/lib/apps.js`
- Test: `gnome-shell/tests/apps.test.js`

**Interfaces:**
- `unescapeSystemdName(name) → string` turns `\x2d` into `-` (every `\xNN`).
- `describeCgroup(leafName) → {groupKey, kind: 'app'|'snap'|'unit'|'docker', appId?, fallbackName}`. The
  rules, in order:
  - `app-[<launcher>-]<appId>-<digits>.scope`, with launcher ∈ {gnome, flatpak, kde, dbus, systemd}, gives
    kind `app` and its `appId`;
  - `snap.<name>.*` gives kind `snap` and `<name>`;
  - `docker-*.scope` gives kind `docker` and "docker";
  - `<unit>[@<instance>].service|.scope` gives kind `unit`. The name is the unit minus its instance and
    suffix, passed through `UNIT_DISPLAY_ALIASES`:
    `{'herdr-server': 'herdr agents', 'org.gnome.Shell': 'GNOME Shell'}`.
  - `groupKey` is `${kind}:${appId ?? name}`, so two Chrome scopes are summed.
- `displayNameFor(description, resolveAppName: (appId) => string|null) → string`. For an `app`:
  - the resolver's answer for `${appId}.desktop`;
  - otherwise the appId's last dot-segment, capitalised ('org.chromium.Chromium' → 'Chromium',
    'alacritty' → 'Alacritty').

  Every other kind uses `fallbackName`.
- `rankApps({previousUsageUsec: Map<cgroupPath, number>, currentUsageUsec: Map, memoryBytesByCgroup: Map,
  elapsedUsec, cpuCount, rootCpuDeltaUsec: number|null, memoryUsedBytes: number|null,
  nameOfCgroup: (cgroupPath) => {groupKey, name}}) → {topCpu: {name, cpuPercent}|null, topMemory: {name,
  memoryBytes}|null}`.
  - An app's CPU % = ΣΔusage / (elapsedUsec × cpuCount) × 100. A cgroup absent from `previousUsageUsec`
    has no delta and is left out of the CPU ranking only.
  - **"kernel & other"** (`KERNEL_AND_OTHER_LABEL`) is a pseudo-app:
    - CPU = max(0, rootCpuDeltaUsec − ΣleafΔ);
    - memory = max(0, memoryUsedBytes − Σapp memory);
    - it ranks like any app.

- [ ] **Step 1: Write the failing tests.** Exact rows:

```js
test('Chromium scope → app org.chromium.Chromium', () =>
    assertEqual(describeCgroup('app-org.chromium.Chromium-50164.scope').appId, 'org.chromium.Chromium'));
test('gnome launcher with an escaped id', () =>
    assertEqual(describeCgroup('app-gnome-aws\\x2dvpn\\x2dclient-59401.scope').appId, 'aws-vpn-client'));
test('snap scope → snap name', () =>
    assertEqual(describeCgroup('snap.slack.slack-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope').fallbackName, 'slack'));
test('herdr service → "herdr agents"', () => assertEqual(describeCgroup('herdr-server.service').fallbackName, 'herdr agents'));
test('templated unit drops its instance', () =>
    assertEqual(describeCgroup('gnome-session-manager@ubuntu.service').fallbackName, 'gnome-session-manager'));
test('docker scopes group as one "docker"', () =>
    assertEqual(describeCgroup('docker-0123abcd.scope').groupKey, describeCgroup('docker-89ef.scope').groupKey));
test('display name falls back to the capitalised last id segment', () =>
    assertEqual(displayNameFor(describeCgroup('app-org.chromium.Chromium-1.scope'), () => null), 'Chromium'));
test('app CPU is a share of the whole machine (top-style would be 400%)', /* Δ 8_000_000 over elapsed 2_000_000 × 8 CPUs */ () =>
    assertEqual(ranking.topCpu, {name: 'herdr agents', cpuPercent: 50}));
test('two scopes of one app are summed', ...);
test('a cgroup new this scan is left out of CPU but counted in memory', ...);
test('"kernel & other" tops CPU when the scanned leaves are small', /* root Δ 12_000_000, leaves Δ 1_000_000 */ ...);
test('"kernel & other" memory is clamped at 0', ...);
```

- [ ] **Step 2: Run it.** Expected: the new rows fail.
- [ ] **Step 3: Implement `apps.js`.**
- [ ] **Step 4: Run it.** Expected: everything passes, with `EXPECTED_ROWS` bumped.
- [ ] **Step 5: Commit.** "Name and rank apps for Resource Pulse from cgroups".

---

### Task 4: Formatting and layout helpers

**Files:**
- Create: `.../lib/format.js`, `.../lib/layout.js`
- Test: `gnome-shell/tests/format.test.js`

**Interfaces.** Every string the UI shows is built here, never in the Shell glue.
- `formatGibibytes(bytes) → string` gives one decimal, with no unit.
- `formatWholePercent(percent) → string` gives `'23%'`, using `Math.round`.
- `memoryLine(memory|null) → string` gives `'19.1 of 30.5 GiB'`, or `'no data'`.
- `swapLine(swap|null) → string` gives one of:
  - `'swap 1.9 GiB (0.4 in RAM)'`;
  - `'swap 1.9 GiB (0.4 in RAM) + 0.5 on disk'`;
  - `'swap none'`;
  - `'swap no data'`.
- `clusterSuffix(clusters|null) → string` gives `'P 80 · E 40'`, or `''`.
- `pressureMeter(band|null) → string` gives one of `'▯▯▯'`, `'▮▯▯'`, `'▮▮▯'`, `'▮▮▮'` or `'···'`.
- `waitingOnLine({cpu, memory, io}) → string` gives `'CPU ▮▯▯  mem ▯▯▯  io ▯▯▯'`.
- `ellipsize(name, maxChars) → string` cuts to `maxChars − 1` characters plus `'…'`.
- `heaviestLine(apps|null) → string` gives `'Chromium 31% · herdr agents 15.7 GiB'`, collapses to
  `'herdr agents 31% · 15.7 GiB'` when one app tops both, and gives `'—'` with no data.
- `hoverLabel(snapshot|null, lastGoodClockLabel|null) → string` gives `'cpu 23% · mem 16.4 of 30.3 GiB'`,
  or `'no data since 14:02'`.
- `cardPosition(workArea: {x, y, width, height}, cardWidth, marginPx) → {x, y}` places the card top-right,
  inset by `marginPx`. It clamps x to ≥ `workArea.x`.

- [ ] **Step 1: Write the failing tests,** with these values:
  - `memoryLine({usedBytes: 20480000000, totalBytes: 32768000000})` gives `'19.1 of 30.5 GiB'`.
  - The `swapLine` cases come from Task 2's numbers:
    - 2048000000 swapped, 1536000000 stored and 400000000 in RAM give `'swap 1.9 GiB (0.4 in RAM) + 0.5 on
      disk'`;
    - 0 swapped gives `'swap none'`.
  - `heaviestLine` covers both forms, plus `ellipsize` at 18 characters for a 25-character name (Review
    Focus 3).
  - `cardPosition({x: 0, y: 32, width: 1536, height: 928}, 340, 24)` gives `{x: 1172, y: 56}`. A second
    monitor layout with `x: 1536` gives `{x: 2708, y: 56}`, and a card wider than the work area clamps to
    `x = workArea.x` (Review Focus 2).
  - `hoverLabel(null, '14:02')` gives `'no data since 14:02'`.
- [ ] **Step 2: Run it.** Expected: the new rows fail.
- [ ] **Step 3: Implement `format.js` and `layout.js`.**
- [ ] **Step 4: Run it.** Expected: everything passes, with `EXPECTED_ROWS` bumped.
- [ ] **Step 5: Commit.** "Add Resource Pulse display strings and card placement".

---

### Task 5: The Sampler

**Files:**
- Create: `gnome-shell/extensions/resource-pulse@dotfiles/sampler.js`, using Gio and GLib only. Its
  `Gio._promisify` calls go at module scope.
- Create fixture roots under `gnome-shell/tests/fixtures/`:
  - **`root-a/` and `root-b/`** are two ticks of a 2-CPU machine (cpu0 = P, cpu1 = E):
    - `proc/stat` holds exactly the lines below;
    - `proc/meminfo`, `proc/pressure/{cpu,memory,io}` and `proc/self/status` (`Uid: 1000`);
    - `sys/block/zram0/mm_stat`;
    - `sys/devices/cpu_core/cpus` = `0` and `sys/devices/cpu_atom/cpus` = `1`;
    - `sys/fs/cgroup/cpu.stat`, plus the cgroup leaves below, each with `cpu.stat`, `memory.current` and
      `memory.stat`.
  - **`root-no-psi/`** is root-a without `proc/pressure`.
  - **`root-no-stat/`** is root-a without `proc/stat`.
  - **`root-vanished/`** is root-b where `app.slice/herdr-server.service/` holds only `cpu.stat`. Its
    `memory.current` is gone, as if the cgroup vanished mid-scan.
  - **The fixture cgroup names are synthetic.** The repo is public, and real app scopes don't belong in it.
- Test: `gnome-shell/tests/sampler.test.js`

**Interfaces:**
- `new Sampler({fsRoot = '/', resolveAppName = () => null, nowUsec = () => GLib.get_monotonic_time(),
  clockLabel = () => GLib.DateTime.new_now_local().format('%H:%M'), log = message => console.warn(message),
  sampleIntervalSeconds = SAMPLE_INTERVAL_SECONDS} = {})`.
  - `fsRoot` is a public property, and tests reassign it between ticks.
- The methods:
  - `async initialize()` reads the cluster map, the CPU count and the uid once.
  - `start()` and `stop()` add and remove one `GLib.timeout_add_seconds` source.
  - `destroy()` calls stop, drops all listeners, and marks the sampler destroyed.
  - `setPaused(isPaused)` and `setAppScanEnabled(isEnabled)`.
  - `addListener(callback: (snapshot) => void) → number` and `removeListener(id)`.
  - `async runTick(tickNumber)` samples, and scans apps when `isAppScanEnabled && tickNumber %
    APP_SCAN_EVERY_N_TICKS === 0`.
  - `async sampleOnce() → Snapshot|null` gives `null` when skipped (already in flight) or destroyed.
  - `async scanAppsOnce() → AppRanking|null`.
  - The getters `latestSnapshot`, `lastGoodClockLabel` and `cpuHistory`/`memoryHistory`, which are
    `RingBuffer(CARD_HISTORY_SAMPLES)` of fractions 0–1 or `null`.
- **`Snapshot`** (a JSDoc typedef) has these fields:
  - `takenAtUsec` and `takenAtClockLabel`;
  - `cpuBusyPercent: number|null`;
  - `cpuClusters: {performancePercent, efficiencyPercent}|null`;
  - `memory: {usedBytes, totalBytes}|null`;
  - `swap`;
  - `pressureAvg10: {cpu, memory, io}`, each `number|null`;
  - `apps: AppRanking|null`, the latest scan;
  - `isComplete: boolean`.
- **Cgroups scanned:** the children of `sys/fs/cgroup/user.slice/user-<uid>.slice/user@<uid>.service/`
  `{app,session,background}.slice`, plus `sys/fs/cgroup/system.slice`. A child that is a `.slice` is
  descended one level more.
  - Use `enumerate_children_async` and `next_files_async` at `GLib.PRIORITY_LOW`.
  - **Memory is read for every leaf.** Read `memory.stat` only for leaves whose `memory.current` exceeds
    `APP_MEMORY_STAT_MIN_BYTES = 64 MiB`, and treat the rest as uncorrected. This decides the spec's
    "top-N" builder question.
- **On error:**
  - any failed read makes that part `null` and sets `isComplete = false`;
  - the message, prefixed `resource-pulse:`, is logged through `log` at most once per distinct message
    per `ERROR_LOG_REPEAT_INTERVAL_USEC`, measured by `nowUsec`;
  - a read error never throws out of `runTick`.

Fixture `proc/stat`:
- **root-a:**
  - `cpu  300 0 100 1500 100 0 0 0 0 0`
  - `cpu0 200 0 50 700 50 0 0 0 0 0`
  - `cpu1 100 0 50 800 50 0 0 0 0 0`
- **root-b:**
  - `cpu  500 0 200 1700 100 0 0 0 0 0`
  - `cpu0 350 0 100 750 50 0 0 0 0 0`
  - `cpu1 150 0 100 950 50 0 0 0 0 0`

The expected busy figures are: total 60%, P 80%, E 40%.

Fixture `meminfo` and `zram`, the same in both roots:
- MemTotal 32000000 kB, MemFree 1000000 kB, MemAvailable 12000000 kB;
- SwapTotal 24000000 kB, SwapFree 22000000 kB;
- `mm_stat` = `1536000000 380000000 400000000 0 400000000 0 0 0 0`.

Fixture PSI: `cpu` = `some avg10=12.50 …` (band 1), and `memory` and `io` = `some avg10=0.00 …`.

Fixture cgroups. All `usage_usec` deltas are root-b minus root-a:

| Leaf | Δ usage_usec | memory.current | active_file + inactive_file |
|---|---|---|---|
| root `cpu.stat` | 12,000,000 | — | — |
| `app.slice/herdr-server.service` | 6,000,000 | 16,000,000,000 | 1,000,000,000 |
| `app.slice/app-org.chromium.Chromium-1.scope` | 2,000,000 | 4,500,000,000 | 500,000,000 |
| `app.slice/app-com.google.Chrome-2.scope` | 500,000 | 600,000,000 | 100,000,000 |
| `app.slice/app-com.google.Chrome-3.scope` | 500,000 | 600,000,000 | 100,000,000 |
| `system.slice/docker-abc.scope` | 1,000,000 | 300,000,000 | 0 |
| `session.slice/org.gnome.Shell@ubuntu.service` | 500,000 | 300,000,000 | 0 |

The scans run at `nowUsec` 0 and then 6,000,000.

- [ ] **Step 1: Write the failing tests.** Rows:
  - root-a then root-b gives `cpuBusyPercent` 60, with clusters P 80 and E 40.
  - The first `sampleOnce` gives `cpuBusyPercent === null`, with memory present.
  - Memory used is 20000000×1024 bytes.
  - Swap disk bytes are 512000000.
  - PSI cpu is 12.5.
  - root-no-psi gives every pressure value `null`, no throw, and memory still present.
  - root-no-stat gives `cpuBusyPercent === null` and `isComplete === false`. `log` is called **once** with a
    message starting `resource-pulse:`, and a second tick inside 10 min does not log. After advancing
    `nowUsec` past 600,000,000 µs, it logs again.
  - Reentrancy: `const first = sampler.sampleOnce(); const second = sampler.sampleOnce();` gives
    `await second === null`, `await first !== null`, and history grows by 1.
  - **Destroy in flight (Review Focus 1):** `const pending = sampler.sampleOnce(); sampler.destroy();`
    gives `await pending === null`, no listener call, and unchanged history.
  - The app scan, root-a then root-b, gives `topCpu` `{name: 'herdr agents', cpuPercent: 50}` and
    `topMemory` `{name: 'herdr agents', memoryBytes: 15000000000}`. The two Chrome scopes count as one.
  - In `root-vanished/`, the herdr cgroup is skipped and the scan succeeds. `topMemory` is then
    `{name: 'Chromium', memoryBytes: 4000000000}`.
  - `runTick(0)` with app scan disabled leaves `latestSnapshot.apps === null`. With it enabled, apps is
    non-null.
  - Timers, with `sampleIntervalSeconds: 1`:
    - start, wait 2.5 s, then stop gives ≥ 1 listener call; a further 1.5 s adds none;
    - `setPaused(true)` before start gives 0 calls in 2.5 s.
- [ ] **Step 2: Run it.** Expected: the new rows fail.
- [ ] **Step 3: Implement `sampler.js`.**
  - Set the in-flight flag **synchronously, before the first `await`**.
  - Check `isDestroyed` after every `await`, before touching state.
  - Read the fast-tick files concurrently with `Promise.allSettled`, so one missing file nulls only its own
    part.
- [ ] **Step 4: Run it.** Expected: everything passes, with `EXPECTED_ROWS` bumped.
- [ ] **Step 5: Commit.** "Add the Resource Pulse sampler".

---

### Task 6: Extension skeleton, graphs and the top-bar indicator

**Files:**
- Create: `gnome-shell/extensions/resource-pulse@dotfiles/metadata.json`. It holds `uuid`, `name`
  "Resource Pulse", `description` "Live CPU and memory in the top bar and on the desktop.",
  `"shell-version": ["50"]` and `url` `https://github.com/quantivly/dotfiles`.
- Create: `.../extension.js`, `.../graph.js` (Cairo only), `.../indicator.js`, `.../stylesheet.css`.
- Test: bash rows in `scripts/test-resource-pulse.sh`, plus `gnome-shell/tests/graph.test.js`.

**Interfaces:**
- `graph.js`:
  - `drawAreaGraph(cr, widthPx, heightPx, fractions: Array<number|null>, fillRgba: number[4],
    baselineRgba: number[4])`. Values are clamped to 0–1, and a `null` is a gap.
  - `drawUsedBar(cr, widthPx, heightPx, fraction|null, fillRgba, trackRgba)`.
  - Colours are constants in `lib/constants.js`: `CPU_GRAPH_RGBA` (starting at teal `#2190a4`),
    `MEMORY_GRAPH_RGBA` (starting at purple `#9141ac`) and `BASELINE_RGBA`. Tuning them is left to the
    builder per the spec.
- `indicator.js`: `PulseIndicator = GObject.registerClass(class extends PanelMenu.Button)`.
  - `_init(sampler)` calls `super._init(0.0, 'Resource Pulse', true)`, so there is no menu.
  - **Graphs:** two `St.DrawingArea`s, CPU then memory, each drawing
    `sampler.cpuHistory.lastValues(TOPBAR_HISTORY_SAMPLES)`, or the memory equivalent.
  - **Hover label:** an `St.Label` added with `Main.layoutManager.addTopChrome`, styled after the dash
    labels. It shows `hoverLabel(...)` after `HOVER_LABEL_DELAY_MS` and hides on leave.
  - **Click:** activates the first app in `RESOURCES_APP_IDS` that `Shell.AppSystem` finds, or does
    nothing.
  - **Teardown:** `destroy()` removes the label and every timeout and listener.
- `extension.js`: `export default class ResourcePulseExtension extends Extension`.
  - **`enable()`:**
    - creates the Sampler with `resolveAppName` (through `Shell.AppSystem.get_default().lookup_app(id)
      ?.get_name()`) and awaits `initialize()`;
    - creates the indicator and adds it with `Main.panel.addToStatusArea(this.uuid, indicator, index,
      'right')`. The index is that of `Main.panel.statusArea.quickSettings.container` in its parent, or 0;
    - starts the sampler.
  - **`disable()`** destroys, in order: the sampler, the indicator, then nulls every field.
  - **An `enable()` that rejects** logs once and leaves nothing behind. Guard every step with "if
    disabled meanwhile, return".
  - **Pause on a blank screen:** `Main.screenShield?.connectObject('active-changed', …)` calls
    `sampler.setPaused(Main.screenShield.active)`. That is the "display off" signal in GNOME 50; Mutter 18's
    typelib exposes `power-save-mode-changed` but no readable mode.

- [ ] **Step 1: Write the failing bash rows** in `scripts/test-resource-pulse.sh`:
  - For each of `extension.js`, `indicator.js` and `card.js`, run `gjs -m <file>`. The output contains
    `resource:///org/gnome/shell` and does **not** contain `SyntaxError`. Both shapes were verified on gjs
    1.88: a Shell import fails with `ImportError: Unable to load file from: resource:///…`, and a parse
    error says `SyntaxError`. `card.js` gets a placeholder now: it imports
    `resource:///org/gnome/shell/ui/main.js` and exports an empty `PulseCard`. Task 7 replaces it.
  - No file under `lib/`, nor `sampler.js` or `graph.js`, contains `resource:///`.
  - No file in the extension matches `Gio.Subprocess|GLib.spawn|Util.spawn|load_contents\(|file_get_contents`.
  - In `metadata.json`: `uuid` equals the directory name, `shell-version` is exactly `["50"]`, and there is
    no `session-modes` key. Read it with `gjs -c` / `JSON.parse`, not grep.
  - JS rows in `graph.test.js`: on a 30×16 `Cairo.ImageSurface`, `drawAreaGraph` must not throw for `[]`,
    all-`null`, mixed values, or values > 1. `import Cairo from 'cairo'` works in plain gjs (verified).
- [ ] **Step 2: Run it.** Expected: the new rows fail.
- [ ] **Step 3: Implement** `metadata.json`, `graph.js`, `indicator.js`, `extension.js` and the indicator's
  part of `stylesheet.css`.
- [ ] **Step 4: Run it.** Expected: everything passes, with `EXPECTED_ROWS` bumped.
- [ ] **Step 5: Commit.** "Add the Resource Pulse top-bar indicator".

---

### Task 7: The desktop card

**Files:**
- Modify: `.../card.js` (replacing the placeholder), `.../extension.js` and `.../stylesheet.css`.

**Interfaces:**
- `PulseCard = GObject.registerClass(class extends St.BoxLayout)`, vertical, with style class
  `resource-pulse-card` and `reactive: false`.
- `update(snapshot, lastGoodClockLabel)` sets these rows:
  - `CPU <percent>` with a 150-sample `drawAreaGraph` and a dim `clusterSuffix`;
  - `MEM <memoryLine>` with `drawUsedBar`;
  - `swapLine`;
  - `waiting on:  <waitingOnLine>`;
  - `heaviest:  <heaviestLine>`.

  Every string comes from `lib/format.js`.
- `placeOnPrimaryMonitor()` applies `cardPosition(Main.layoutManager.getWorkAreaForMonitor(primaryIndex),
  this.width, CARD_MARGIN_PX)`.
- Wiring in `extension.js`:
  - `Main.layoutManager._backgroundGroup.add_child(card)`;
  - placement on `Main.layoutManager` `monitors-changed`, `global.display` `workareas-changed` and the
    card's `notify::width`;
  - `Main.overview` `showing`/`hidden` call `sampler.setAppScanEnabled(false/true)`;
  - `disable()` destroys the card.
- Style:
  - the surface is `rgba(30, 30, 30, 0.78)`, with a 1 px `rgba(255,255,255,0.08)` border and 16 px
    radius;
  - Ubuntu Sans with `font-feature-settings: "tnum"`;
  - labels are muted at 60% opacity and values are full.
  - The spec rules out live blur.

- [ ] **Step 1: Run the state table.** `scripts/test-resource-pulse.sh`. Expected: the card row from
  Task 6 still passes on the placeholder.
- [ ] **Step 2: Implement `card.js`, the wiring and the styles.**
- [ ] **Step 3: Run the state table.** Expected: everything passes, with no row count change.
- [ ] **Step 4: Commit.** "Add the Resource Pulse desktop card".

---

### Task 8: Repo wiring: link, opt-in, status, cost script, docs

**Files:**
- Modify: `install.conf.yaml`, adding to the `link:` block:
  `~/.local/share/gnome-shell/extensions/resource-pulse@dotfiles: gnome-shell/extensions/resource-pulse@dotfiles`.
- Modify: `scripts/apply-gnome-settings.sh`, adding `genable_extension <uuid>` next to `gset`.
- Modify: `examples/gnome-settings.local.template`, adding a commented `# genable_extension
  resource-pulse@dotfiles` block with a one-line description.
- Modify: `zsh/functions/system.sh`, adding to `gnome-status` a `Resource Pulse:` line that shows linked
  yes/no, enabled yes/no, and the State from `gnome-extensions info`.
- Create: `scripts/resource-pulse-cost.sh`, with these modes:
  - `--cpu-percent <seconds>`;
  - `--rss-kib`;
  - `--rss-check <baseline_kib>`, which exits 0 when growth ≤ `RSS_GROWTH_TOLERANCE_MIB=64` and 1 otherwise,
    printing both numbers.

  It finds gnome-shell by scanning `$PROC_ROOT/[0-9]*/comm == gnome-shell` owned by `id -u`.
  `GNOME_SHELL_PID` overrides that, and more than one candidate is exit 2. It never reads `cmdline` or
  `environ`.
- Modify: `docs/GNOME_CONFIGURATION_GUIDE.md`.
  - The intro's "no third-party extensions" stays true.
  - "Extensions — left as-is" becomes "Extensions — one of our own".
  - A new "Resource Pulse" section holds:
    - the spec's definitions table, verbatim;
    - how to enable it, via the template line, then `gnome-apply`, then one logout and login;
    - `gnome-status`;
    - the nested-shell recipe from Task 9;
    - the cost script;
    - the sentence `` `scripts/test-resource-pulse.sh` (N checks) ``.
- Modify: `CLAUDE.md` line 565 and `README.md` line 470. Reword them to "no third-party extensions; one
  in-repo, opt-in extension (Resource Pulse)". In CLAUDE.md, trim the same number of bytes elsewhere in
  the GNOME section, so the net change is ≤ 0.
- Modify: `CHANGELOG.md`, adding an `[Unreleased] → Added` entry.

**`genable_extension` semantics.** It runs only when the schema `org.gnome.shell` is present, warning and
skipping otherwise.
- It appends the uuid to `enabled-extensions` if it is absent. It handles `@as []` and a non-empty list,
  and keeps every other entry and their order.
- It removes the uuid from `disabled-extensions` if present. That key wins in GNOME 50.
- It prints a `log WARNING` naming `disable-user-extensions` when that is `true`, because then nothing
  user-installed loads.
- It is idempotent: no change means no `✓` line.

- [ ] **Step 1: Write the failing bash rows.** They use a stateful `gsettings` stub on `PATH` (values under
  `$T/gsettings/<schema>/<key>`, plus a configurable `list-schemas`), `XDG_CURRENT_DESKTOP=GNOME`, and
  `GNOME_LOCAL_OVERRIDES` pointing at a fixture holding `genable_extension resource-pulse@dotfiles`. The
  rows:
  - `@as []` becomes `['resource-pulse@dotfiles']`;
  - `['ding@rastersoft.com']` becomes `['ding@rastersoft.com', 'resource-pulse@dotfiles']`;
  - already present: unchanged, and the output has no `enabled-extensions →` line;
  - `disabled-extensions` `['resource-pulse@dotfiles', 'x@y']` becomes `['x@y']` (Review Focus 5);
  - `disable-user-extensions` `true` gives a WARNING line containing `disable-user-extensions`;
  - the `org.gnome.shell` schema absent gives the `Schema 'org.gnome.shell' not found` warning and no
    write;
  - `install.conf.yaml` has the exact link line;
  - the template has the commented `genable_extension resource-pulse@dotfiles` line;
  - cost script, against a fake `PROC_ROOT` with one `gnome-shell` (`status` VmRSS 400000 kB):
    - `--rss-check 380000` exits 0;
    - `--rss-check 300000` exits 1 and prints both numbers;
    - two candidates exit 2;
    - no candidate exits 2;
  - **docs claim:** `docs/GNOME_CONFIGURATION_GUIDE.md` says `` `scripts/test-resource-pulse.sh` ($EXPECTED_ROWS checks ``,
    copying `docs_claim` from `test-dock-wifi.sh`.
- [ ] **Step 2: Run it.** Expected: the new rows fail.
- [ ] **Step 3: Implement** the wiring, the helper, the status line, the cost script and the docs.
- [ ] **Step 4: Run every check.**
  - `scripts/test-resource-pulse.sh` passes, with its final `EXPECTED_ROWS` and the docs claim in
    agreement;
  - `shellcheck -x scripts/test-resource-pulse.sh scripts/resource-pulse-cost.sh scripts/apply-gnome-settings.sh`;
  - `zsh -n zsh/functions/system.sh`;
  - `./scripts/check-claude-md.sh` passes, with size ≤ 45636;
  - `pre-commit run --all-files`.
- [ ] **Step 5: Commit.** "Wire Resource Pulse into the dotfiles as an opt-in extension".

---

### Task 9: Nested-shell verification (before anything goes live)

- [ ] **Step 1: Ask the user** to run `sudo apt install mutter-dev-bin` in a real terminal. `sudo` fails in
  the Bash tool. Wait for confirmation.
- [ ] **Step 2: Record the live state.** Run `gsettings get org.gnome.shell enabled-extensions` and keep
  the output.
- [ ] **Step 3: Run the nested shell with isolated config and data.**
  - Use `NESTED=$(mktemp -d)`.
  - Create `$NESTED/{config,data/gnome-shell/extensions,cache}`.
  - Symlink the **worktree's** extension dir into `$NESTED/data/gnome-shell/extensions/`.
  - Then run
    `env XDG_CONFIG_HOME=$NESTED/config XDG_DATA_HOME=$NESTED/data XDG_CACHE_HOME=$NESTED/cache dbus-run-session -- bash -c "gsettings set org.gnome.shell enabled-extensions \"['resource-pulse@dotfiles']\" && gnome-shell --devkit --wayland"`.
  - Capture its output to a file.
- [ ] **Step 4: Verify.**
  - The live `enabled-extensions` is byte-identical to Step 2. **If it changed, stop and report.**
  - Both surfaces render and the graphs move.
  - The hover label shows the numbers.
  - A click opens Resources inside the nested session, or nothing if it is not found there.
  - The output contains no `JS ERROR` and no `resource-pulse:` lines.
  - Disabling and re-enabling via Looking Glass (`Alt+F2` → `lg`, inside the nested window) 10 times
    leaves no duplicate indicator or card.
- [ ] **Step 5: Fix any finding with a test first.** A test where one can exist; otherwise a commit that
  names what the nested run showed.

---

### Task 10: Merge, deploy, enable, live checks

- [ ] **Step 1: Push and open the PR.** The repo rejects `@claude`, so review locally. Rewrite the title
  and body to the final diff.
- [ ] **Step 2: Watch CI.** `gh pr checks` can show a stale run, so match `headSha` to HEAD. **Squash-merge
  without `--admin`.**
- [ ] **Step 3: Deploy.**
  - `git -C ~/.dotfiles fetch origin main`;
  - check that `git -C ~/.dotfiles diff --name-only HEAD..origin/main` names no dirty path;
  - `git -C ~/.dotfiles merge --ff-only origin/main`;
  - then `bash ~/.dotfiles/install`, which creates the link. **Surface the `install.conf.yaml` diff** to
    the user, as the standing deploy permission requires.
- [ ] **Step 4: Opt in.** Add `genable_extension resource-pulse@dotfiles` to `~/.gnome-settings.local` and
  run `gnome-apply`. Then ask the user to log out and back in once; GNOME on Wayland discovers new
  extensions at login.
- [ ] **Step 5: Check correctness live.**
  - `gnome-status` says the extension is ACTIVE.
  - The card agrees, within rounding, with Resources, `free -b`, `cat /proc/pressure/*` and
    `/sys/block/zram0/mm_stat`.
  - **CPU load:** `stress-ng --cpu 4 --timeout 60` raises the total and the P/E figures, and "heaviest"
    names the stress process's app.
  - **Memory:** a 4 GiB allocation raises MEM by about 4.0 GiB.
- [ ] **Step 6: Lifecycle.**
  - 20 lock and unlock cycles;
  - a dock and undock;
  - the overview in and out.

  After these, `gnome-extensions info resource-pulse@dotfiles` says ACTIVE, and
  `journalctl --user -b -g resource-pulse` is empty.
- [ ] **Step 7: Cost.**
  - Run `scripts/resource-pulse-cost.sh --cpu-percent 600` with the extension disabled
    (`gnome-extensions disable`), then enabled. The difference must be < 0.5.
  - Record `--rss-kib` 10 minutes after enabling.
  - Then schedule the 24 h check with the `run-later` skill:
    `rabota schedule add --command "~/.dotfiles/scripts/resource-pulse-cost.sh --rss-check <baseline>"`.
- [ ] **Step 8: Report.** Give the PR link, the measured cost, and the scheduled check's id.
