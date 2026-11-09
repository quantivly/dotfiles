# Desktop Cockpit, data side: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything stage one of the cockpit needs *outside* the shell: the sampler's longer app ranking, a second
systemd user service (`cockpit.service`, bus name `io.github.quantivly.dotfiles.Cockpit1`) serving the sessions,
network and mounts sources and the layout read from a personal config file, its unit, install wiring,
`gnome-status` line, cost mode, tests and docs. It deploys live with no logout and is cost-measured before any
card is drawn. The drawing side (the extension's client, grid, cards, tooltips, click, dropdown, ding off) is the
next plan.

**Architecture:** The sampler service is untouched except for one additive field. A new entry point
`service/cockpit.js` owns `Cockpit1` on the session bus, reads `~/.config/resource-pulse/cockpit.json`, and runs
three source modules on their own cadences (watched or not, tripled on battery); each source publishes an
allowlisted object through pure `lib/` modules that run and are tested under plain gjs. The D-Bus face mirrors
`service/dbusService.js`: watches counted per caller and dropped on disconnect, additive-only JSON.

**Tech Stack:** GJS (gjs 1.88, GLib/Gio, GioUnix), systemd user units, the repo's plain-gjs state table
(`gnome-shell/tests/*.test.js` + `scripts/test-resource-pulse.sh`), bash, zsh (`gnome-status`).

**Spec:** `docs/superpowers/specs/2026-11-09-desktop-cockpit-design.md` (the cockpit design); it builds on
`docs/superpowers/specs/2026-11-08-resource-pulse-service-design.md` (v2). The spec travels with this plan: every
implementer reads both.

## Global Constraints

- The four deal-breakers are binding: desktop instability; wrong or laggy numbers; cost (CPU, memory, battery);
  upkeep.
- **No file IO and no subprocess in the shell** (unchanged). The static check scans every file under the extension
  directory; files under `service/` are scanned for subprocess calls only, and **the cockpit service spawns no
  subprocess either**: herdr is reached over its socket, pids over `pane.process_info`.
- **Additive-only JSON** on both interfaces: unknown fields ignored at any depth; a missing or mistyped field is
  null for that field alone; a breaking change is a new interface name.
- **A stale number is never drawn as live:** every source object carries `sampledAtUsec` and `intervalSeconds`,
  and a source older than `COCKPIT_SOURCE_STALE_INTERVALS = 3` of its intervals is stale.
- **Secrets:** a source publishes only the fields its schema lists (enum, number, id, short name). It never opens
  anything under `~/.aws`, `~/.ssh`, `~/.clauth/profiles/*/.credentials*`, `~/.claude/.credentials.json`,
  `~/.zshrc.local`, `~/.gitconfig.local`, `~/.backup.local`; `stat` is allowed. It publishes no free text from
  another program. A name longer than `COCKPIT_NAME_MAX_CHARS = 64` or matching a secret shape is replaced by
  `COCKPIT_REDACTED_NAME = '—'`.
- **Budgets:** cockpit service under 0.05% of one core unwatched, under 0.1% watched, RSS at most 48 MiB flat;
  unit caps `CPUQuota=10%`, `MemoryHigh=64M`, `MemoryMax=96M`. Nothing polls that can be told (NetworkManager,
  `Gio.UnixMountMonitor`, `GFileMonitor`, UPower signal).
- **Cadences:** sessions 10 s watched / 60 s unwatched; route table 10 s; ssh sockets and mounts 30 s (plus the
  mount monitor's signal); on battery every cadence × 3.
- **Units:** no `[Install]`; never `enable`/`reenable`; `PartOf=graphical-session.target`, `Restart=on-failure`,
  `RestartSec=5`, `StartLimitIntervalSec=300`, `StartLimitBurst=5`, `Slice=background.slice`, `Nice=10`,
  `Type=dbus`; `ConditionPathExists=%h/.config/resource-pulse/cockpit.json`.
- **Nothing in the repo is personal:** the config file is a template under `examples/`; the user's copy lives at
  `~/.config/resource-pulse/cockpit.json`, never created by `./install`.
- **Repo rules:** a new guard ships with rows; "could not run" is exit 2, never a pass; `EXPECTED_ROWS` and the
  guide's "(N checks" claim move together; `command -v` one name per call; every CI apt install goes through
  `.github/actions/apt-install`; commit messages in the imperative mood, with the trailer
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Names follow the repo's style: explicit, units in the name (`_SECONDS`, `_MS`, `_BYTES`), constants in
  `lib/constants.js`, Numpy-style JSDoc on every new function, `describeError` for error text.

## Review Focus

Inputs the spec implies but no task's rows would otherwise exercise, most likely to bite first:

1. **herdr's socket accepts the connection and never answers** (herdr busy or hung): the sessions source must
   time out at `HERDR_REQUEST_TIMEOUT_MS = 2000`, mark itself stale, and the other sources must publish on time.
   Pinned in Task 8 (fake server that never replies) and Task 9 (scheduler row).
2. **A registry slug or workspace label that is a token-shaped string or 300 characters long**: the published
   name is `—`, the row is kept. Pinned in Task 5 and Task 6.
3. **A tunnel interface present but with no gateway route** (`tun0` listed, flags without `RTF_GATEWAY`): VPN
   reads down, not up. Pinned in Task 7.
4. **`cockpit.json` present but malformed, or naming a card id nobody knows**: `layout` is null, `configError`
   names the reason, and the three sources keep publishing. Pinned in Task 4 and Task 10.
5. **A pane whose claude process is gone between the snapshot and the `/proc` read, or whose process-info holds
   no claude process at all**: the row is kept with `memoryBytes: null`, never dropped and never 0. Pinned in
   Task 6 and Task 9.

---

## File structure

**Create**

- `gnome-shell/extensions/resource-pulse@dotfiles/lib/jsonFields.js`: the typed JSON readers both protocols share
  (moved out of `lib/protocol.js`).
- `lib/cockpitProtocol.js`: `Cockpit1`'s names, interface XML, payload builders and skew-tolerant parsers.
- `lib/cockpitConfig.js`: parsing and validating the layout config.
- `lib/nameGuard.js`: the display-name allowlist (length and secret shapes).
- `lib/sessions.js`: pure session-row logic (naming, state mapping, idle age, sorting, counts).
- `lib/network.js`: pure route-table and NetworkManager-value logic.
- `lib/mounts.js`: pure mount filtering and row building.
- `service/herdrSocket.js`: an async JSON client for herdr's unix socket.
- `service/sources/sessions.js`, `service/sources/network.js`, `service/sources/mounts.js`: the three sources
  (IO glue around the pure modules, each with injectable readers).
- `service/cockpitSources.js`: the scheduler (cadence per source, watched flag, battery multiplier, staleness).
- `service/cockpitDbusService.js`: the `Cockpit1` D-Bus face.
- `service/cockpit.js`: the entry point (`gjs -m`), the config file monitor, bus-name ownership.
- `systemd/cockpit.service`, `examples/resource-pulse-cockpit.json.template`.
- Tests: `gnome-shell/tests/jsonFields.test.js`, `cockpitProtocol.test.js`, `cockpitConfig.test.js`,
  `nameGuard.test.js`, `sessions.test.js`, `network.test.js`, `mounts.test.js`, `herdrSocket.test.js`,
  `cockpitSources.test.js`, `cockpit-dbus.test.js` (private bus), and fixtures under
  `gnome-shell/tests/fixtures/cockpit/`.

**Modify**

- `lib/protocol.js` (import the shared readers; read the longer ranking), `lib/apps.js` (return the rankings),
  `service/sampler.js` (typedef), `lib/constants.js` (the new constants).
- `gnome-shell/tests/run.js`, `run-private-bus.js` (static import lists), `apps.test.js`, `protocol.test.js`,
  `imports.test.js` (`PURE_TOP_LEVEL_FILE_NAMES` stays; service files are pure-gjs too but are not listed there).
- `scripts/test-resource-pulse.sh` (new bash rows, `EXPECTED_ROWS`), `scripts/resource-pulse-service-refresh.sh`
  (two units), `scripts/resource-pulse-cost.sh` (`--cockpit`), `scripts/resource-pulse-nested.sh` (start the
  cockpit service too), `zsh/functions/system.sh` (`gnome-status` cockpit line), `install.conf.yaml` (the link),
  `examples/gnome-settings.local.template` (commented background lines), `docs/GNOME_CONFIGURATION_GUIDE.md`,
  `CHANGELOG.md`.

The extension directory is `gnome-shell/extensions/resource-pulse@dotfiles/`; relative paths below are inside
it unless they start with `gnome-shell/tests/`, `scripts/`, `systemd/`, `examples/`, `zsh/` or `docs/`. Run every
test command from the repo root. The full table: `scripts/test-resource-pulse.sh`; the plain-gjs rows alone:
`gjs -m gnome-shell/tests/run.js`.

---

### Task 1: Shared JSON field readers

**Files:**
- Create: `lib/jsonFields.js`
- Modify: `lib/protocol.js:169-245` (the private helpers move out)
- Test: `gnome-shell/tests/jsonFields.test.js`, `gnome-shell/tests/run.js`

**Interfaces:**
- Produces (all exported from `lib/jsonFields.js`, each `(value: *) => T|null`): `parseJsonObject(text)`,
  `isPlainObject(value)` (boolean), `finiteNumberOrNull`, `nonNegativeNumberOrNull`, `fractionOrNull`,
  `countOrNull`, `stringOrNull`, `booleanOrNull`, and `enumOrNull(value, allowedValues: string[])` (the value when
  it is one of the strings; null otherwise). Semantics are exactly protocol.js's today; `enumOrNull` is new.

- [ ] **Step 1: Write the failing rows** in `gnome-shell/tests/jsonFields.test.js`, imported through a namespace
  (`import * as jsonFields from '../extensions/resource-pulse@dotfiles/lib/jsonFields.js'`):

```javascript
test('jsonFields: parseJsonObject reads an object and rejects a list, a scalar and bad JSON', () => {
    assertEqual(jsonFields.parseJsonObject('{"a":1}'), {a: 1});
    assertEqual(jsonFields.parseJsonObject('[1]'), null);
    assertEqual(jsonFields.parseJsonObject('7'), null);
    assertEqual(jsonFields.parseJsonObject('{nope'), null);
    assertEqual(jsonFields.parseJsonObject(42), null);
});
test('jsonFields: countOrNull keeps whole numbers of zero or more only', () => {
    assertEqual(jsonFields.countOrNull(3), 3);
    assertEqual(jsonFields.countOrNull(0), 0);
    assertEqual(jsonFields.countOrNull(-1), null);
    assertEqual(jsonFields.countOrNull(1.5), null);
    assertEqual(jsonFields.countOrNull(2 ** 53), null);
});
test('jsonFields: enumOrNull keeps a listed string only', () => {
    assertEqual(jsonFields.enumOrNull('working', ['idle', 'working']), 'working');
    assertEqual(jsonFields.enumOrNull('Working', ['idle', 'working']), null);
    assertEqual(jsonFields.enumOrNull(1, ['1']), null);
});
```
  Add one row each for `fractionOrNull` (0, 1, 1.01 → null, -0.1 → null), `nonNegativeNumberOrNull`
  (`Infinity` → null), `stringOrNull`, `booleanOrNull`, `isPlainObject` (null, array → false).

- [ ] **Step 2: Add `import './jsonFields.test.js';` to `gnome-shell/tests/run.js`** after `./harness.test.js`, run
  `gjs -m gnome-shell/tests/run.js` and confirm the import error (the module does not exist).

- [ ] **Step 3: Create `lib/jsonFields.js`** by moving the helper functions out of `lib/protocol.js` (lines
  169–245: `parseJsonObject`, `isPlainObject`, `finiteNumberOrNull`, `nonNegativeNumberOrNull`,
  `fractionOrNull`, `countOrNull`, `stringOrNull`, `booleanOrNull`) as exports, and adding
  `export function enumOrNull(value, allowedValues)`. Keep their JSDoc. `lib/protocol.js` imports them from
  `./jsonFields.js`; its exports do not change.

- [ ] **Step 4: Run `gjs -m gnome-shell/tests/run.js`**: every row passes, including protocol.test.js's existing
  rows (they pin the behaviour that moved).

- [ ] **Step 5: Run `scripts/test-resource-pulse.sh`**, note the new tally, and set `EXPECTED_ROWS` and the guide's
  "(N checks" sentence (`docs/GNOME_CONFIGURATION_GUIDE.md`, the `docs_claim` row names the line) to it.

- [ ] **Step 6: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/lib/jsonFields.js gnome-shell/extensions/resource-pulse@dotfiles/lib/protocol.js gnome-shell/tests/jsonFields.test.js gnome-shell/tests/run.js scripts/test-resource-pulse.sh docs/GNOME_CONFIGURATION_GUIDE.md
git commit -m "Move the typed JSON readers out of protocol.js so a second protocol can share them"
```

---

### Task 2: The sampler publishes a longer app ranking (the only sampler change)

**Files:**
- Modify: `lib/apps.js:220-258` (`rankApps`), `lib/constants.js`, `lib/protocol.js:280-310` (`parseRankedApp`,
  `parseAppRanking`), `service/sampler.js:97-104` (the `AppRanking` typedef)
- Test: `gnome-shell/tests/apps.test.js`, `gnome-shell/tests/protocol.test.js`

**Interfaces:**
- Produces: `rankApps(scan)` returns `{topCpu, topMemory, cpuRanking, memoryRanking}` where `cpuRanking` is
  `Array<{groupKey, name, cpuPercent}>` and `memoryRanking` is `Array<{groupKey, name, memoryBytes}>`, each sorted
  largest first, at most `APP_RANKING_LENGTH = 10` entries, `[]` when nothing ranks (`cpuRanking` is `[]` whenever
  `topCpu` is null). The memory ranking holds real apps only (never `pseudo:*` groups), as `topMemory` does.
  `parseAppRanking` reads the two lists (an entry `parseRankedApp` rejects is dropped; a missing or non-array list
  is `null`, so an old service reads as "no list"). Published inside `snapshot.apps` on both `GetState` and
  `Sample`; nothing else in the payload moves.

- [ ] **Step 1: Write the failing rows** in `apps.test.js`, next to the existing `rankApps` rows, reusing their
  scan fixtures:

```javascript
test('apps: rankApps lists every group by CPU and by memory, largest first, at most APP_RANKING_LENGTH', () => {
    const ranking = rankApps(scanWithGroups(12));   // a helper in the file building 12 leaves with distinct usage
    assertEqual(ranking.cpuRanking.length, APP_RANKING_LENGTH);
    assertEqual(ranking.cpuRanking[0], ranking.topCpu);
    assertEqual(ranking.cpuRanking.every((entry, i) => i === 0 || entry.cpuPercent <= ranking.cpuRanking[i - 1].cpuPercent), true);
    assertEqual(ranking.memoryRanking[0], ranking.topMemory);
});
test('apps: the memory ranking never names kernel or short jobs', () => {
    const ranking = rankApps(scanWithUnattributedCpu());   // the existing kernel/short-jobs fixture
    assertEqual(ranking.memoryRanking.some(entry => entry.groupKey.startsWith('pseudo:')), false);
    assertEqual(ranking.cpuRanking.some(entry => entry.groupKey === 'pseudo:short-jobs'), true);
});
test('apps: rankApps with nothing to rank gives empty lists', () => {
    const ranking = rankApps(emptyScan());
    assertEqual(ranking.cpuRanking, []);
    assertEqual(ranking.memoryRanking, []);
});
```
  And in `protocol.test.js`, extend `FULL_SNAPSHOT.apps` with both lists (two entries each) and add:

```javascript
test('protocol: parseStatePayload reads the app rankings and drops a malformed entry', () => {
    const apps = {...FULL_SNAPSHOT.apps, cpuRanking: [FULL_SNAPSHOT.apps.topCpu, {name: 'no key'}]};
    const parsed = parseStatePayload(buildStatePayload({...fullState(), snapshot: {...FULL_SNAPSHOT, apps}}));
    assertEqual(parsed.snapshot.apps.cpuRanking, [FULL_SNAPSHOT.apps.topCpu]);
});
test('protocol: a payload from before the rankings reads them as null', () => {
    const {cpuRanking, memoryRanking, ...oldApps} = FULL_SNAPSHOT.apps;
    const parsed = parseStatePayload(buildStatePayload({...fullState(), snapshot: {...FULL_SNAPSHOT, apps: oldApps}}));
    assertEqual(parsed.snapshot.apps.cpuRanking, null);
    assertEqual(parsed.snapshot.apps.topCpu, FULL_SNAPSHOT.apps.topCpu);
});
```

- [ ] **Step 2: Run `gjs -m gnome-shell/tests/run.js`**: the new rows fail (`cpuRanking` undefined).

- [ ] **Step 3: Implement.** In `lib/constants.js` add `export const APP_RANKING_LENGTH = 10;`. In `rankApps`,
  sort `cpuDeltaByGroup.values()` and `memoryByGroup.values()` by `value` descending (stable; ties by `groupKey`),
  take `APP_RANKING_LENGTH`, map to the same entry shape as `topCpu`/`topMemory`; `cpuRanking` is `[]` when
  `!canRankCpu`. In `lib/protocol.js` add `parseRankedAppList(value, valueFieldName)` (array → entries that
  `parseRankedApp` accepts; non-array → null) and read `cpuRanking`/`memoryRanking` in `parseAppRanking`. Update
  the `AppRanking` typedef in `service/sampler.js`. `service-sampler.test.js`'s existing fixture rows must still
  pass unchanged (they compare `topCpu`/`topMemory` only).

- [ ] **Step 4: Run `gjs -m gnome-shell/tests/run.js`**: all pass. Run `scripts/test-resource-pulse.sh`: all pass
  (the private-bus rows see the longer payload and ignore the new fields).

- [ ] **Step 5: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/lib/apps.js gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js gnome-shell/extensions/resource-pulse@dotfiles/lib/protocol.js gnome-shell/extensions/resource-pulse@dotfiles/service/sampler.js gnome-shell/tests/apps.test.js gnome-shell/tests/protocol.test.js
git commit -m "Publish the top 10 apps by CPU and by memory as an additive field"
```

---

### Task 3: The Cockpit1 protocol module

**Files:**
- Create: `lib/cockpitProtocol.js`
- Modify: `lib/constants.js`
- Test: `gnome-shell/tests/cockpitProtocol.test.js`, `gnome-shell/tests/run.js`

**Interfaces:**
- Produces, exported constants: `COCKPIT_PROTOCOL_VERSION = 1`,
  `COCKPIT_BUS_NAME = 'io.github.quantivly.dotfiles.Cockpit1'`, `COCKPIT_INTERFACE_NAME` (the same),
  `COCKPIT_OBJECT_PATH = '/io/github/quantivly/dotfiles/Cockpit1'`, `COCKPIT_GET_STATE_METHOD_NAME = 'GetState'`,
  `COCKPIT_WATCH_METHOD_NAME = 'WatchCockpit'`, `COCKPIT_UNWATCH_METHOD_NAME = 'UnwatchCockpit'`,
  `COCKPIT_FOCUS_SESSION_METHOD_NAME = 'FocusSession'`, `COCKPIT_CHANGED_SIGNAL_NAME = 'Changed'`,
  `COCKPIT_CHANGED_SIGNAL_SIGNATURE = '(s)'`, `COCKPIT_INTERFACE_XML` (GetState → s; WatchCockpit(); UnwatchCockpit();
  FocusSession(s sessionId) → s reply; signal Changed(s changed)), `COCKPIT_SOURCE_NAMES = ['sessions', 'network',
  'mounts']`, `SESSION_STATES = ['working', 'blocked', 'idle', 'done', 'unknown']`, `UPLINK_KINDS = ['wired', 'wifi',
  'none']`, `CONNECTIVITY_STATES = ['full', 'limited', 'portal', 'none', 'unknown']`, `MOUNT_KINDS = ['network',
  'removable']`.
- Builders: `buildCockpitStatePayload({layout, configError, sources, serviceStartedAtUsec, latestPublishedAtUsec})
  → string`; `buildChangedPayload({publishedAtUsec, sources}) → string` (only the changed sources);
  `buildFocusSessionReply({focused, windowPid, error}) → string`. **Every builder runs each source object and
  the layout through its own reader before stringifying**, so a field no reader lists can never leave the
  service, whatever a source module put in its object (the secrets allowlist is enforced here, once).
- Parsers (skew-tolerant as `lib/protocol.js`): `parseCockpitStatePayload(text)` →
  `{protocol, serviceStartedAtUsec, latestPublishedAtUsec, layout, configError, sources: {sessions, network,
  mounts}}|null`; `parseChangedPayload(text)` → `{publishedAtUsec, sources}|null`; `parseFocusSessionReply(text)`
  → `{focused: boolean|null, windowPid: number|null, error: string|null}|null`; and the per-source readers
  `parseSessionsSource`, `parseNetworkSource`, `parseMountsSource`, `parseLayout` (each `(value) => object|null`).
- **The source shapes** (every reader rebuilds exactly these fields; anything else is dropped):
  - common: `sampledAtUsec` (finite number), `intervalSeconds` (count);
  - `sessions`: `herdrRunning` (boolean), `totalMemoryBytes` (non-negative or null), `counts` (`{working, idle,
    blocked, done, unknown}` counts), `rows` (array of `{id: string, name: string, state: SESSION_STATES,
    idleSeconds: count|null, idleFromProcessAge: boolean, memoryBytes: non-negative|null, workspaceId: string|null,
    paneId: string|null, account: string|null, contextPercent: non-negative|null}`; a row missing `id`, `name` or a
    valid `state` is dropped);
  - `network`: `uplink: {kind: UPLINK_KINDS|null, connectivity: CONNECTIVITY_STATES|null, wifiEnabled:
    boolean|null}`, `vpn: {isUp: boolean|null, interfaceName: string|null}`, `sshMasterCount: count|null`;
  - `mounts`: `rows` (array of `{mountPoint: string, label: string, kind: MOUNT_KINDS, filesystemType: string,
    freeBytes: non-negative|null, totalBytes: non-negative|null}`);
  - `layout`: `{monitor: {vendor: string|null, product: string|null}, groups: Array<{id: string, caption: string,
    columns: count, cards: string[]}>}` or null.

- [ ] **Step 1: Write the failing rows** in `cockpitProtocol.test.js` (namespace import), with a `FULL_STATE`
  fixture holding every field (two session rows, one of each state across rows, one mount of each kind):

```javascript
test('cockpitProtocol: the names and the interface', () => {
    assertEqual(cockpitProtocol.COCKPIT_BUS_NAME, 'io.github.quantivly.dotfiles.Cockpit1');
    assertEqual(cockpitProtocol.COCKPIT_OBJECT_PATH, '/io/github/quantivly/dotfiles/Cockpit1');
    const nodeInfo = Gio.DBusNodeInfo.new_for_xml(cockpitProtocol.COCKPIT_INTERFACE_XML);
    const iface = nodeInfo.lookup_interface(cockpitProtocol.COCKPIT_INTERFACE_NAME);
    assertEqual(iface.methods.map(m => m.name).sort(), ['FocusSession', 'GetState', 'UnwatchCockpit', 'WatchCockpit']);
    assertEqual(iface.signals.map(s => s.name), ['Changed']);
});
test('cockpitProtocol: a full state round-trips', () => {
    assertEqual(cockpitProtocol.parseCockpitStatePayload(cockpitProtocol.buildCockpitStatePayload(FULL_STATE)),
        {protocol: 1, ...FULL_STATE});
});
test('cockpitProtocol: an unknown field is ignored and a mistyped one is null for itself alone', () => {
    const text = JSON.stringify({...JSON.parse(cockpitProtocol.buildCockpitStatePayload(FULL_STATE)), extra: 1,
        sources: {...FULL_STATE.sources, network: {...FULL_STATE.sources.network, sshMasterCount: 'two'}}});
    const parsed = cockpitProtocol.parseCockpitStatePayload(text);
    assertEqual(parsed.extra, undefined);
    assertEqual(parsed.sources.network.sshMasterCount, null);
    assertEqual(parsed.sources.network.vpn, FULL_STATE.sources.network.vpn);
});
test('cockpitProtocol: a session row with an unlisted state is dropped, the others kept', () => {
    const rows = [...FULL_STATE.sources.sessions.rows, {...FULL_STATE.sources.sessions.rows[0], id: 'x', state: 'napping'}];
    const parsed = cockpitProtocol.parseSessionsSource({...FULL_STATE.sources.sessions, rows});
    assertEqual(parsed.rows.length, FULL_STATE.sources.sessions.rows.length);
});
test('cockpitProtocol: Changed carries only the sources named', () => {
    const changed = cockpitProtocol.parseChangedPayload(cockpitProtocol.buildChangedPayload(
        {publishedAtUsec: 5, sources: {mounts: FULL_STATE.sources.mounts}}));
    assertEqual(Object.keys(changed.sources), ['mounts']);
    assertEqual(changed.sources.mounts, FULL_STATE.sources.mounts);
});
test('cockpitProtocol: a FocusSession reply with nothing known reads as all null', () => {
    assertEqual(cockpitProtocol.parseFocusSessionReply('{}'), {focused: null, windowPid: null, error: null});
});
test('cockpitProtocol: a field no reader lists never leaves the builder', () => {
    const sessions = {...FULL_STATE.sources.sessions, lastText: 'model prose', rows: [{...FULL_STATE.sources.sessions.rows[0], cwd: '/home/x'}]};
    const text = cockpitProtocol.buildCockpitStatePayload({...FULL_STATE, sources: {...FULL_STATE.sources, sessions}});
    assertEqual(text.includes('lastText'), false);
    assertEqual(text.includes('"cwd"'), false);
});
test('cockpitProtocol: text that is not a JSON object parses to null as a whole', () => {
    assertEqual(cockpitProtocol.parseCockpitStatePayload('[]'), null);
});
```

- [ ] **Step 2: Add `import './cockpitProtocol.test.js';` to `run.js`**, run it, confirm the import error.

- [ ] **Step 3: Implement `lib/cockpitProtocol.js`** with the readers from `lib/jsonFields.js`; write the top-level
  numbers (`protocol`, `serviceStartedAtUsec`, `latestPublishedAtUsec`) before `layout` and `sources` in the
  state JSON, as `buildStatePayload` does, because `gnome-status` pattern-reads them from the text before
  `"sources"`. Add to `lib/constants.js`: `COCKPIT_SOURCE_STALE_INTERVALS = 3`, `COCKPIT_NAME_MAX_CHARS = 64`,
  `COCKPIT_REDACTED_NAME = '—'`, `COCKPIT_LOG_PREFIX = 'cockpit:'`.

- [ ] **Step 4: Run `gjs -m gnome-shell/tests/run.js`**: all pass.

- [ ] **Step 5: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js gnome-shell/tests/cockpitProtocol.test.js gnome-shell/tests/run.js
git commit -m "Add the Cockpit1 protocol: names, interface and skew-tolerant payloads"
```

---

### Task 4: The layout config

**Files:**
- Create: `lib/cockpitConfig.js`, `examples/resource-pulse-cockpit.json.template`
- Modify: `lib/constants.js`
- Test: `gnome-shell/tests/cockpitConfig.test.js`, `gnome-shell/tests/run.js`

**Interfaces:**
- Produces: `parseCockpitConfig(text) → {layout: Layout|null, error: string|null}`; a config is valid when it is
  a JSON object with `version` 1, an optional `monitor` object (`vendor` and `product` strings, both optional),
  and `groups`, a non-empty array of `{id, caption, columns (1 or 2), cards}` where `cards` is a non-empty array of
  ids from `COCKPIT_CARD_IDS = ['system', 'apps', 'connections', 'sessions', 'health', 'seats', 'sol', 'work']`,
  no card id repeated across groups, no group id repeated, and `columns` summing to at most
  `COCKPIT_GRID_COLUMNS = 4`. Every error names the first offending field (`"groups[1].cards[0]: unknown card id
  'weather'"`). `layout` is the parsed `{monitor: {vendor, product}, groups}` with `vendor`/`product` null when
  absent. Also `COCKPIT_CONFIG_RELATIVE_PATH = 'resource-pulse/cockpit.json'` (under `XDG_CONFIG_HOME`) and
  `cockpitConfigPath(configHome) → string`.

- [ ] **Step 1: Write the failing rows**:

```javascript
const TEMPLATE_PATH = GLib.build_filenamev([REPO_ROOT, 'examples', 'resource-pulse-cockpit.json.template']);
test('cockpitConfig: the shipped template parses to the spec layout', () => {
    const {layout, error} = cockpitConfig.parseCockpitConfig(readSource(TEMPLATE_PATH));
    assertEqual(error, null);
    assertEqual(layout.monitor, {vendor: 'DEL', product: 'DELL U2723QE'});
    assertEqual(layout.groups.map(g => [g.id, g.columns, g.cards]), [
        ['machine', 2, ['system', 'apps', 'connections', 'health']],
        ['agents', 1, ['sessions', 'seats']],
        ['work', 1, ['sol', 'work']],
    ]);
});
test('cockpitConfig: an unknown card id is an error naming the field', () => {
    const text = JSON.stringify({version: 1, groups: [{id: 'g', caption: 'G', columns: 1, cards: ['weather']}]});
    assertEqual(cockpitConfig.parseCockpitConfig(text), {layout: null, error: "groups[0].cards[0]: unknown card id 'weather'"});
});
test('cockpitConfig: a card repeated across groups is an error', () => { /* 'system' twice → error names groups[1].cards[0] */ });
test('cockpitConfig: columns above the grid width is an error', () => { /* 2 + 2 + 1 → error names groups[2].columns */ });
test('cockpitConfig: malformed JSON and a wrong version are errors, never a throw', () => {
    assertEqual(cockpitConfig.parseCockpitConfig('{').layout, null);
    assertEqual(cockpitConfig.parseCockpitConfig('{"version": 2, "groups": []}').error, "version: expected 1, got 2");
});
test('cockpitConfig: cockpitConfigPath joins the config home and the relative path', () => {
    assertEqual(cockpitConfig.cockpitConfigPath('/tmp/xdg'), '/tmp/xdg/resource-pulse/cockpit.json');
});
```

- [ ] **Step 2: Add the import to `run.js`**, run, confirm failure.

- [ ] **Step 3: Implement** `lib/cockpitConfig.js` and write the template (the spec's three groups, the monitor
  by vendor and product, a header comment is not possible in JSON, so the template's first key is
  `"_comment": "Copy to ~/.config/resource-pulse/cockpit.json; see docs/GNOME_CONFIGURATION_GUIDE.md"` and the
  parser ignores keys starting with `_`). Add `COCKPIT_CARD_IDS`, `COCKPIT_GRID_COLUMNS` and
  `COCKPIT_CONFIG_RELATIVE_PATH` to `lib/constants.js`.

- [ ] **Step 4: Run `gjs -m gnome-shell/tests/run.js`**: all pass.

- [ ] **Step 5: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/lib/cockpitConfig.js gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js examples/resource-pulse-cockpit.json.template gnome-shell/tests/cockpitConfig.test.js gnome-shell/tests/run.js
git commit -m "Add the cockpit layout config parser and its template"
```

---

### Task 5: The display-name guard

**Files:**
- Create: `lib/nameGuard.js`
- Test: `gnome-shell/tests/nameGuard.test.js`, `gnome-shell/tests/run.js`

**Interfaces:**
- Produces: `guardDisplayName(name: *) → string` (the name when it is a string of 1 to `COCKPIT_NAME_MAX_CHARS`
  characters with no control characters and matching no secret shape; `COCKPIT_REDACTED_NAME` otherwise), and
  `SECRET_SHAPE_PATTERNS: Array<{name: string, pattern: RegExp}>`, ported one-to-one from the **shape** rule set of
  `scripts/redact-secrets.sh` (read that script; each rule there becomes one entry here with the same name).

- [ ] **Step 1: Write the failing rows**, one per shape in `scripts/redact-secrets.sh` plus:

```javascript
test('nameGuard: an ordinary slug, a branch and a label pass through', () => {
    for (const name of ['host-sync', 'zvi/cockpit-stage-1', 'DO-894 host sync', 'teammate 2.1.259'])
        assertEqual(nameGuard.guardDisplayName(name), name);
});
test('nameGuard: a name over 64 characters is redacted', () => {
    assertEqual(nameGuard.guardDisplayName('a'.repeat(65)), '—');
    assertEqual(nameGuard.guardDisplayName('a'.repeat(64)), 'a'.repeat(64));
});
test('nameGuard: a non-string, an empty string and a control character are redacted', () => {
    assertEqual(nameGuard.guardDisplayName(null), '—');
    assertEqual(nameGuard.guardDisplayName(''), '—');
    assertEqual(nameGuard.guardDisplayName('a\u001bb'), '—');
});
test('nameGuard: every shape rule in scripts/redact-secrets.sh has a pattern here with the same name', () => {
    // read the script, extract its shape rule names with the pattern its own test uses, compare the sorted lists
});
```
  For each shape, a row with a synthetic string in that shape (a GitHub token prefix followed by the right
  number of characters, an AWS key id, a JWT-shaped string, a private-key header) expecting `'—'`. Use made-up
  characters; never a real credential.

- [ ] **Step 2: Add the import to `run.js`**, run, confirm failure.

- [ ] **Step 3: Implement `lib/nameGuard.js`.** Port each shape from `scripts/redact-secrets.sh` as a JS `RegExp`
  (no `g` flag), test in order, and keep the rule names.

- [ ] **Step 4: Run `gjs -m gnome-shell/tests/run.js`**: all pass.

- [ ] **Step 5: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/lib/nameGuard.js gnome-shell/tests/nameGuard.test.js gnome-shell/tests/run.js
git commit -m "Add the display-name guard: length and the redactor's secret shapes"
```

---

### Task 6: Session rows, pure

**Files:**
- Create: `lib/sessions.js`, fixtures `gnome-shell/tests/fixtures/cockpit/herdr-snapshot.json`,
  `gnome-shell/tests/fixtures/cockpit/hspawn-registry/wL_p1.json` (and two more entries),
  `gnome-shell/tests/fixtures/cockpit/proc-status-claude.txt`
- Modify: `lib/constants.js`
- Test: `gnome-shell/tests/sessions.test.js`, `gnome-shell/tests/run.js`

**Interfaces:**
- Consumes: `guardDisplayName` (Task 5), `SESSION_STATES` (Task 3).
- Produces:
  - `sessionStateFromAgentStatus(agentStatus: *) → SESSION_STATES[number]`: `'working'`, `'blocked'`, `'idle'`,
    `'done'` map to themselves; anything else (including `undefined`) is `'unknown'`.
  - `displayNameForSession({registryEntry, workspaceLabel, cwd}) → string`: the registry's `slug`, else its
    `branch`, else `workspaceLabel`, else the last path segment of `cwd`, each through `guardDisplayName`; `'—'`
    when none.
  - `idleAgeForSession({transcriptMtimeUsec, processStartedAtUsec, nowUsec}) → {idleSeconds: number|null,
    idleFromProcessAge: boolean}`: the transcript age when known, else the process age flagged, else `null`/false.
  - `transcriptPathCandidates({cwd, sessionId, homeDirectory}) → string[]`: `~/.claude/projects/<cwd with every /
    and . replaced by ->/<sessionId>.jsonl` first (hreap's mangling, `zsh/zshrc.herdr:3786`), then the glob
    roots under `~/.clauth/profiles/*/runtime-*/projects/` (returned as directory prefixes the IO layer searches).
  - `memoryBytesFromProcStatus(text) → number|null`: `VmRSS` + `VmSwap` in bytes from `/proc/<pid>/status`
    text (kB lines); null when `VmRSS` is absent.
  - `buildSessionsSource({agents, registryEntriesByPaneId, workspaceLabelsById, transcriptMtimeUsecBySessionId,
    processInfoByPaneId, memoryBytesByPaneId, nowUsec, sampledAtUsec, intervalSeconds, herdrRunning}) → sessions
    object` (Task 3's shape): one row per agent whose `agent` is `'claude'`, sorted by `memoryBytes` descending
    (nulls last, then by name), `counts` by state, `totalMemoryBytes` the sum of known memory; `account` and
    `contextPercent` read from the agent's `tokens` (`acct`, and the `ctx_*` token hreap's sidebar publishes;
    read the token names from `claude/hooks/session-statusline.sh`), through `guardDisplayName` for the account.
  - `SESSION_IDLE_DIM_SECONDS = 1800` in `lib/constants.js` (the drawing side reads it; defined here with the
    rest).

- [ ] **Step 1: Write the fixtures.** `herdr-snapshot.json`: a **synthetic** snapshot in the live shape
  (`{"id":"cli:api:snapshot","result":{"snapshot":{"agents":[...],"workspaces":[...]}}}`) with five agents:
  working with a registry slug; blocked with a branch only; idle with a workspace label only; done with a cwd
  only; `unknown` (no `agent_status`) with no transcript; plus one non-claude agent that must not appear. Use
  made-up ids and paths (`/home/user/...`). Registry entries carry the field set the live ones do (`branch`,
  `created_at`, `creator_session`, `name`, `pane_id`, `path`, `profile`, `repo`, `slug`, `workspace_id`).

- [ ] **Step 2: Write the failing rows**:

```javascript
test('sessions: herdr statuses map one-to-one and anything else is unknown', () => {
    for (const status of ['working', 'blocked', 'idle', 'done'])
        assertEqual(sessions.sessionStateFromAgentStatus(status), status);
    assertEqual(sessions.sessionStateFromAgentStatus(undefined), 'unknown');
    assertEqual(sessions.sessionStateFromAgentStatus('Working'), 'unknown');
});
test('sessions: the name falls through slug, branch, label, cwd', () => {
    assertEqual(sessions.displayNameForSession({registryEntry: {slug: 'host-sync', branch: 'b'}, workspaceLabel: 'L', cwd: '/x/y'}), 'host-sync');
    assertEqual(sessions.displayNameForSession({registryEntry: {branch: 'zvi/b'}, workspaceLabel: 'L', cwd: '/x/y'}), 'zvi/b');
    assertEqual(sessions.displayNameForSession({registryEntry: null, workspaceLabel: 'L', cwd: '/x/y'}), 'L');
    assertEqual(sessions.displayNameForSession({registryEntry: null, workspaceLabel: null, cwd: '/x/y'}), 'y');
    assertEqual(sessions.displayNameForSession({registryEntry: {slug: 'ghp_' + 'A'.repeat(36)}, workspaceLabel: null, cwd: null}), '—');
});
test('sessions: idle age prefers the transcript and flags the process age', () => {
    assertEqual(sessions.idleAgeForSession({transcriptMtimeUsec: 90e6, processStartedAtUsec: 10e6, nowUsec: 100e6}), {idleSeconds: 10, idleFromProcessAge: false});
    assertEqual(sessions.idleAgeForSession({transcriptMtimeUsec: null, processStartedAtUsec: 10e6, nowUsec: 100e6}), {idleSeconds: 90, idleFromProcessAge: true});
    assertEqual(sessions.idleAgeForSession({transcriptMtimeUsec: null, processStartedAtUsec: null, nowUsec: 100e6}), {idleSeconds: null, idleFromProcessAge: false});
});
test('sessions: the transcript path mangles the cwd as hreap does', () => {
    assertEqual(sessions.transcriptPathCandidates({cwd: '/home/u/.dotfiles', sessionId: 'abc', homeDirectory: '/home/u'})[0],
        '/home/u/.claude/projects/-home-u--dotfiles/abc.jsonl');
});
test('sessions: memory is VmRSS plus VmSwap in bytes, null without VmRSS', () => {
    assertEqual(sessions.memoryBytesFromProcStatus(readFixture('proc-status-claude.txt')), (3_100_000 + 200_000) * 1024);
    assertEqual(sessions.memoryBytesFromProcStatus('Name:\tclaude\n'), null);
});
test('sessions: the source lists claude agents only, largest memory first, with counts and a total', () => {
    const source = sessions.buildSessionsSource(fixtureInputs());
    assertEqual(source.rows.map(r => r.state), ['working', 'blocked', 'idle', 'done', 'unknown']);
    assertEqual(source.counts, {working: 1, blocked: 1, idle: 1, done: 1, unknown: 1});
    assertEqual(source.rows.at(-1).memoryBytes, null);           // the process vanished: kept, null
    assertEqual(source.rows.at(-1).idleFromProcessAge, true);
    assertEqual(source.totalMemoryBytes, 4 * 1024 ** 3);
});
test('sessions: every row passes the protocol reader unchanged', () => {
    const source = sessions.buildSessionsSource(fixtureInputs());
    assertEqual(cockpitProtocol.parseSessionsSource(JSON.parse(JSON.stringify(source))), source);
});
```

- [ ] **Step 3: Add the import to `run.js`**, run, confirm failure.

- [ ] **Step 4: Implement `lib/sessions.js`.** Pure: no Gio, no GLib file calls. Read the token names for account
  and context from `claude/hooks/session-statusline.sh` before writing the two lookups.

- [ ] **Step 5: Run `gjs -m gnome-shell/tests/run.js`**: all pass.

- [ ] **Step 6: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/lib/sessions.js gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js gnome-shell/tests/sessions.test.js gnome-shell/tests/fixtures/cockpit gnome-shell/tests/run.js
git commit -m "Add the pure session-row logic: naming, states, idle age, memory, sorting"
```

---

### Task 7: Network and mounts, pure

**Files:**
- Create: `lib/network.js`, `lib/mounts.js`, fixtures `gnome-shell/tests/fixtures/cockpit/proc-net-route-tunnel.txt`,
  `proc-net-route-no-gateway.txt`, `proc-net-route-plain.txt`
- Modify: `lib/constants.js`
- Test: `gnome-shell/tests/network.test.js`, `gnome-shell/tests/mounts.test.js`, `gnome-shell/tests/run.js`

**Interfaces:**
- Produces, `lib/network.js`:
  - `parseRouteTable(text) → Array<{interfaceName, destinationHex, gatewayHex, flags}>` from `/proc/net/route`
    (header line skipped; `flags` the parsed hex number).
  - `tunnelFromRoutes(routes) → {isUp: boolean, interfaceName: string|null}`: up when a route whose interface
    name starts with one of `TUNNEL_INTERFACE_PREFIXES = ['tun', 'tap', 'wg']` carries `RTF_GATEWAY` (`0x0002`)
    or has destination `00000000` (a default route); the interface named is the first such.
  - `uplinkFromNetworkManager({primaryConnectionType, connectivity, wirelessEnabled}) → {kind, connectivity,
    wifiEnabled}`: `'802-3-ethernet'` → `'wired'`, `'802-11-wireless'` → `'wifi'`, null/other → `'none'`;
    NetworkManager's `NMConnectivityState` numbers (0 unknown, 1 none, 2 portal, 3 limited, 4 full) → the
    `CONNECTIVITY_STATES` strings; `wifiEnabled` passed through as boolean or null.
- Produces, `lib/mounts.js`:
  - `mountRowsFrom(entries: Array<{mountPoint, filesystemType, devicePath, label: string|null, freeBytes,
    totalBytes}>) → rows` (Task 3's mount shape): kind `'network'` for filesystem types in
    `NETWORK_FILESYSTEM_TYPES = ['cifs', 'smb3', 'nfs', 'nfs4', 'fuse.sshfs', 'fuse.rclone', 'davfs', 'afp']`,
    `'removable'` for a mount point under `/media/`, `/run/media/` or `/mnt/`; anything else dropped; label =
    the entry's label, else the mount point's last segment, through `guardDisplayName`; sorted by mount point.

- [ ] **Step 1: Write the fixtures** (`/proc/net/route` text with its tab-separated header; the tunnel one with a
  `tun0` row carrying flags `0003`; the no-gateway one with `tun0` flags `0001` and a non-default destination).

- [ ] **Step 2: Write the failing rows**:

```javascript
test('network: a tunnel with a gateway route is up, one without is down, no tunnel is down', () => {
    assertEqual(network.tunnelFromRoutes(network.parseRouteTable(readFixture('proc-net-route-tunnel.txt'))), {isUp: true, interfaceName: 'tun0'});
    assertEqual(network.tunnelFromRoutes(network.parseRouteTable(readFixture('proc-net-route-no-gateway.txt'))), {isUp: false, interfaceName: 'tun0'});
    assertEqual(network.tunnelFromRoutes(network.parseRouteTable(readFixture('proc-net-route-plain.txt'))), {isUp: false, interfaceName: null});
});
test('network: an empty or headerless table is no routes, never a throw', () => {
    assertEqual(network.parseRouteTable(''), []);
});
test('network: NetworkManager values map to the uplink enums', () => {
    assertEqual(network.uplinkFromNetworkManager({primaryConnectionType: '802-3-ethernet', connectivity: 4, wirelessEnabled: false}), {kind: 'wired', connectivity: 'full', wifiEnabled: false});
    assertEqual(network.uplinkFromNetworkManager({primaryConnectionType: null, connectivity: 1, wirelessEnabled: null}), {kind: 'none', connectivity: 'none', wifiEnabled: null});
    assertEqual(network.uplinkFromNetworkManager({primaryConnectionType: '802-11-wireless', connectivity: 9, wirelessEnabled: true}).connectivity, 'unknown');
});
test('mounts: network shares and removable disks are kept, the rest dropped, labels guarded', () => {
    const rows = mounts.mountRowsFrom([
        {mountPoint: '/', filesystemType: 'ext4', devicePath: '/dev/nvme0n1p2', label: null, freeBytes: 1, totalBytes: 2},
        {mountPoint: '/media/user/Backup', filesystemType: 'ext4', devicePath: '/dev/sda1', label: 'Backup', freeBytes: 10, totalBytes: 20},
        {mountPoint: '/mnt/nas', filesystemType: 'cifs', devicePath: '//nas/share', label: null, freeBytes: null, totalBytes: null},
    ]);
    assertEqual(rows.map(r => [r.kind, r.label]), [['removable', 'Backup'], ['network', 'nas']]);
});
```

- [ ] **Step 3: Add both imports to `run.js`**, run, confirm failure.

- [ ] **Step 4: Implement** both modules; add `TUNNEL_INTERFACE_PREFIXES`, `NETWORK_FILESYSTEM_TYPES`,
  `REMOVABLE_MOUNT_PREFIXES = ['/media/', '/run/media/', '/mnt/']`, `ROUTE_FLAG_GATEWAY = 0x0002` to
  `lib/constants.js`.

- [ ] **Step 5: Run `gjs -m gnome-shell/tests/run.js`**: all pass.

- [ ] **Step 6: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/lib/network.js gnome-shell/extensions/resource-pulse@dotfiles/lib/mounts.js gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js gnome-shell/tests/network.test.js gnome-shell/tests/mounts.test.js gnome-shell/tests/fixtures/cockpit gnome-shell/tests/run.js
git commit -m "Add the pure network and mounts logic for the connections card"
```

---

### Task 8: The herdr socket client

**Files:**
- Create: `service/herdrSocket.js`
- Modify: `lib/constants.js`
- Test: `gnome-shell/tests/herdrSocket.test.js`, `gnome-shell/tests/run.js`

**Interfaces:**
- Produces: `class HerdrSocketClient` with `constructor({socketPath, timeoutMs = HERDR_REQUEST_TIMEOUT_MS,
  nowUsec})`, `request(kind: string, params: object) → Promise<object>` (resolves with the reply's `result`;
  rejects with an `Error` whose message starts with `'herdr: '` on a missing socket, a refused connection, a
  timeout, a malformed reply or a reply carrying `error`), and `close()`. One connection per request is
  acceptable (herdr's CLI does the same); never a subprocess. Also `herdrSocketPath(configHome) → string` =
  `<configHome>/herdr/herdr.sock` (`HERDR_SOCKET_RELATIVE_PATH = 'herdr/herdr.sock'`).
- **The wire framing is the builder's to establish** from `herdr api schema --json` (its `protocol` field and
  `schemas.request`) and, read-only, from how `herdr api snapshot` prints `{"id": …, "result": …}`; pin the
  framing with the fake server below so a change in herdr fails a row rather than a desktop. Do not read any
  file outside the repo for this except the schema the CLI prints.

- [ ] **Step 1: Write the failing rows** with a fake server (`Gio.SocketListener` on a path under a temp dir
  from `GLib.dir_make_tmp`), the harness's async `test` bodies:

```javascript
test('herdrSocket: a request gets its result back', async () => {
    const server = await startFakeHerdr({snapshot: {agents: []}});   // answers 'snapshot' with that result
    const client = new HerdrSocketClient({socketPath: server.path});
    assertEqual(await client.request('snapshot', {}), {snapshot: {agents: []}});
    server.stop();
});
test('herdrSocket: a server that never answers rejects at the timeout', async () => {
    const server = await startFakeHerdr(null);   // accepts, never writes
    const client = new HerdrSocketClient({socketPath: server.path, timeoutMs: 50});
    assertEqual(await client.request('snapshot', {}).then(() => 'resolved', e => e.message.startsWith('herdr: ')), true);
    server.stop();
});
test('herdrSocket: no socket file rejects at once with a herdr: error', async () => { /* path in an empty dir */ });
test('herdrSocket: a reply carrying error rejects with its text', async () => { /* {"id":..,"error":{"message":"nope"}} */ });
test('herdrSocket: herdrSocketPath joins the config home', () => {
    assertEqual(herdrSocket.herdrSocketPath('/tmp/c'), '/tmp/c/herdr/herdr.sock');
});
```

- [ ] **Step 2: Add the import to `run.js`**, run, confirm failure.

- [ ] **Step 3: Implement `service/herdrSocket.js`** with `Gio.SocketClient.connect_async` on a
  `Gio.UnixSocketAddress`, async writes and reads (`write_all_async`, `read_line_async` or the framing the schema
  requires), a `GLib.timeout_add` that cancels the `Gio.Cancellable` at `timeoutMs`. Add
  `HERDR_REQUEST_TIMEOUT_MS = 2000` and `HERDR_SOCKET_RELATIVE_PATH` to `lib/constants.js`.

- [ ] **Step 4: Run `gjs -m gnome-shell/tests/run.js`**: all pass. Run `scripts/test-resource-pulse.sh`: the static
  no-IO row still passes (the client is under `service/`, where only subprocess calls are forbidden, and it
  spawns none).

- [ ] **Step 5: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/service/herdrSocket.js gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js gnome-shell/tests/herdrSocket.test.js gnome-shell/tests/run.js
git commit -m "Add an async client for herdr's unix socket, with a request timeout"
```

---

### Task 9: The three sources and their scheduler

**Files:**
- Create: `service/sources/sessions.js`, `service/sources/network.js`, `service/sources/mounts.js`,
  `service/cockpitSources.js`
- Modify: `lib/constants.js`
- Test: `gnome-shell/tests/cockpitSources.test.js`, `gnome-shell/tests/run.js`

**Interfaces:**
- Consumes: Tasks 6, 7, 8.
- Every source is a class with the same face: `constructor(dependencies)` (all IO injectable with real
  defaults), `get name()` (`'sessions'` | `'network'` | `'mounts'`), `sample() → Promise<object>` (the source
  object of Task 3's shape, with `sampledAtUsec` and `intervalSeconds` filled by the scheduler), `watchChanges(
  onChange: () => void) → void` (subscribe to the thing's own signal: NetworkManager's `PropertiesChanged` on
  `org.freedesktop.NetworkManager` (`PrimaryConnection`, `Connectivity`, `WirelessEnabled`),
  `Gio.UnixMountMonitor.get().connect('mounts-changed')`; the sessions source subscribes to nothing in stage one),
  `destroy()`.
  - `SessionsSource({herdrClient, configHome, stateHome, homeDirectory, readFile, statFile, listDirectory,
    nowUsec})`: `snapshot` request, then one `pane.process_info` request per claude agent (sequentially, so herdr
    is asked one thing at a time), the registry dir listed once per sample, transcripts stat'ed (candidates from
    Task 6, the glob roots listed at most once per sample), `/proc/<pid>/status` read for the pid whose `comm` or
    argv basename is `claude` or a path under `/claude/versions/` (hreap's rule, `zsh/zshrc.herdr:3780`);
    `herdrRunning` false and `rows: []` when the socket is absent (not an error).
  - `NetworkSource({connection, readFile, listDirectory, homeDirectory})`: NetworkManager over `connection`
    (a `Gio.DBusProxy` with `DO_NOT_AUTO_START`; absent NetworkManager → `uplink` all null), `/proc/net/route`
    read, `~/.ssh/sockets` listed and counted (**never opened**, and a missing directory is 0).
  - `MountsSource({mountMonitor, queryFilesystem})`: `GioUnix.mounts_get` (or `Gio.unix_mounts_get`, whichever
    the running GLib exports; prefer `GioUnix`), label from `GioUnix.mount_guess_name`, free and total from
    `Gio.File.query_filesystem_info_async` with `filesystem::free,filesystem::size` (null on any error; network
    mounts are queried with the same 2 s timeout cancellable so a hung share cannot stall the tick).
- `class CockpitSources` (`service/cockpitSources.js`): `constructor({sources, timeouts, nowUsec, isOnBattery,
  logWriter})` where `isOnBattery` is a function (default: a UPower proxy's `OnBattery`, false when UPower is
  absent); `start()`, `destroy()`, `setWatched(isWatched)`, `addListener(cb(changedSourceNames: string[],
  sourcesByName)) → id`, `removeListener(id)`, `get sourcesByName()` (latest objects), `sampleNow(name)`.
  Cadence per source: `SESSIONS_WATCHED_INTERVAL_SECONDS = 10`, `SESSIONS_UNWATCHED_INTERVAL_SECONDS = 60`,
  `NETWORK_INTERVAL_SECONDS = 10`, `MOUNTS_INTERVAL_SECONDS = 30`, each × `BATTERY_CADENCE_MULTIPLIER = 3` while
  on battery; a `watchChanges` signal samples that source at once, at most once per
  `SOURCE_SIGNAL_COOLDOWN_SECONDS = 2`. A source whose `sample()` rejects keeps its previous object and gets
  `error: <describeError text>` logged (rate-limited, key per source); the listener is called only when a
  source's object changed (deep compare of the JSON text); `intervalSeconds` in the object is the effective one.
  A `sample()` still pending when its interval comes again is skipped, never queued.

- [ ] **Step 1: Write the failing rows** with fake sources (`{name, sample: async () => ..., watchChanges, destroy}`)
  and fake timeouts (the `timeouts` injection pattern of `pulseClient.js`: `{addSeconds(seconds, cb) → id,
  remove(id)}` driven by hand):

```javascript
test('cockpitSources: each source samples at its own interval, and watched sessions sample at 10 s', async () => {
    const {sources, clock, calls} = fakeSetup({watched: true});   // calls.<name> counts sample() calls
    sources.start(); await clock.advanceSeconds(60);               // the fake timeouts fire in order
    assertEqual(calls, {sessions: 7, network: 7, mounts: 3});      // 1 at start + 60/10, 60/10, 60/30
});
test('cockpitSources: unwatched sessions sample at 60 s', async () => {
    const {sources, clock, calls} = fakeSetup({watched: false});
    sources.start(); await clock.advanceSeconds(120);
    assertEqual(calls.sessions, 3);                                 // 1 at start + 120/60
});
test('cockpitSources: on battery every interval triples', async () => {
    const {sources, clock, calls} = fakeSetup({watched: true, onBattery: true});
    sources.start(); await clock.advanceSeconds(90);
    assertEqual(calls, {sessions: 4, network: 4, mounts: 2});      // 30 s, 30 s, 90 s
    assertEqual(sources.sourcesByName.sessions.intervalSeconds, 30);
});
test('cockpitSources: a source that rejects keeps its last object and does not stop the others', async () => {
    const sources = new CockpitSources({sources: [failingSessions, okNetwork], timeouts, nowUsec, isOnBattery: () => false, logWriter});
    sources.start(); await settle();
    assertEqual(sources.sourcesByName.network.uplink.kind, 'wired');
    assertEqual(sources.sourcesByName.sessions, null);
    assertEqual(loggedLines.some(l => l.startsWith('cockpit: sessions: herdr: ')), true);
});
test('cockpitSources: a pending sample is skipped when its interval comes again, never queued', async () => { /* sample() that resolves late */ });
test('cockpitSources: a signal from a source samples it at once, once per cooldown', async () => { /* fire watchChanges twice within 2 s → one extra sample */ });
test('cockpitSources: the listener fires only for a changed source', async () => { /* same object twice → one call */ });
test('SessionsSource: the socket absent is herdrRunning false with no rows and no error', async () => { /* herdrClient.request rejects 'herdr: no socket'; readFile never called */ });
test('SessionsSource: a pid with no claude process gives memoryBytes null and keeps the row', async () => { /* process_info without claude */ });
test('SessionsSource: nothing under ~/.ssh or ~/.aws is ever opened', async () => { /* readFile spy: every path starts with /proc/ or the state home or the claude projects dirs */ });
test('NetworkSource: ~/.ssh/sockets is listed and never opened; missing dir is 0 masters', async () => { /* listDirectory spy; readFile spy sees /proc/net/route only */ });
test('MountsSource: a filesystem query that fails gives null sizes, the row kept', async () => { /* queryFilesystem rejects */ });
```

- [ ] **Step 2: Add the import to `run.js`**, run, confirm failure.

- [ ] **Step 3: Implement** the three sources and the scheduler. Reuse `readFileToEnd` and
  `listSubdirectoryNames` from `service/sampler.js` for file reads (synchronous, as v2 decided for the service),
  and `RateLimitedLogger` with `COCKPIT_LOG_PREFIX`. Add the cadence constants to `lib/constants.js`.

- [ ] **Step 4: Run `gjs -m gnome-shell/tests/run.js`**: all pass. Run `scripts/test-resource-pulse.sh`: the
  subprocess row still passes for `service/`.

- [ ] **Step 5: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/service/sources gnome-shell/extensions/resource-pulse@dotfiles/service/cockpitSources.js gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js gnome-shell/tests/cockpitSources.test.js gnome-shell/tests/run.js
git commit -m "Add the sessions, network and mounts sources and their scheduler"
```

---

### Task 10: The Cockpit1 D-Bus face and the service entry point

**Files:**
- Create: `service/cockpitDbusService.js`, `service/cockpit.js`
- Test: `gnome-shell/tests/cockpit-dbus.test.js`, `gnome-shell/tests/run-private-bus.js`,
  `scripts/test-resource-pulse.sh` (the real-entry driver rows)

**Interfaces:**
- Consumes: Task 3 (names, builders), Task 4 (`parseCockpitConfig`, `cockpitConfigPath`), Task 9
  (`CockpitSources`), Task 8 (`HerdrSocketClient` for `FocusSession`).
- Produces: `class CockpitDBusService` mirroring `ResourcePulseDBusService` (`service/dbusService.js`):
  `constructor(cockpit, connection, {serviceStartedAtUsec, nowRealUsec, nowUsec, logWriter})` where `cockpit` is
  anything with `layout`, `configError`, `sourcesByName`, `addListener(cb(changedSourceNames: string[],
  sourcesByName)) → id` (the scheduler's signature, Task 9; a layout change is reported as the pseudo-name
  `'layout'` in `changedSourceNames`, and `Changed` then carries `layout` and `configError` beside the sources),
  `removeListener(id)`, `setWatched(bool)`, `focusSession(id) → Promise<{focused, windowPid, error}>`; `GetState` answers
  `buildCockpitStatePayload(...)`; every listener call emits one `Changed` with the changed sources; `WatchCockpit`
  / `UnwatchCockpit` counted per sender and dropped on vanish (copy the mechanism, do not generalise it in this
  task); `FocusSessionAsync` answers the reply JSON, and a thrown error becomes `{focused: false, windowPid: null,
  error}` rather than a D-Bus error. `get watchCount`, `destroy()`.
- `service/cockpit.js`: `class CockpitServiceProcess` mirroring `ResourcePulseServiceProcess`: owns
  `COCKPIT_BUS_NAME` with `DO_NOT_QUEUE`; reads the config at `cockpitConfigPath(GLib.get_user_config_dir())`,
  watches it with `Gio.File.monitor_file` and re-reads on change (a deleted file → `layout: null`,
  `configError: 'missing'`; the service keeps serving sources); builds `CockpitSources` with the real sources;
  `focusSession(id)` sends `workspace.focus` then `pane.focus` over the herdr client with the ids the latest
  sessions row for `id` carries, and answers `windowPid` null in this plan (the drawing plan decides what the
  reply needs to carry once the window mapping is known); logs `cockpit: serving … (protocol 1)` on name
  acquired; exit statuses as `main.js`. The entry: `System.exit(new CockpitServiceProcess().run())`.

- [ ] **Step 1: Write the failing private-bus rows** in `cockpit-dbus.test.js`, reusing
  `requirePrivateBusAddress`, `openPrivateBusConnection`, `waitUntil` from `service-dbus.test.js` and a
  `FakeCockpit` (layout, sources, listener, `focusSession` recording its id):

```javascript
test('cockpit-dbus: GetState answers the layout and every source', async () => { /* parse with parseCockpitStatePayload; protocol 1, layout from the fixture config, sources.mounts.rows.length */ });
test('cockpit-dbus: a listener call becomes one Changed naming only the changed sources', async () => { /* subscribe to the signal, fake.publish(['network']) */ });
test('cockpit-dbus: WatchCockpit is counted per caller and dropped when the caller vanishes', async () => { /* as service-dbus.test.js's watch row: close the connection, wait ≤ 2 s, watchCount 0, setWatched(false) seen */ });
test('cockpit-dbus: FocusSession hands the id to the cockpit and answers its reply', async () => { /* reply JSON parses to {focused: true, windowPid: null, error: null}; fake saw 'wL:p1' */ });
test('cockpit-dbus: FocusSession with an unknown id answers focused false and an error, not a D-Bus error', async () => {});
```
  Add `import './cockpit-dbus.test.js';` to `run-private-bus.js`.

- [ ] **Step 2: Run `scripts/test-resource-pulse.sh`**: the private-bus run fails on the import.

- [ ] **Step 3: Implement `service/cockpitDbusService.js`** and run the table: the rows pass.

- [ ] **Step 4: Write the failing real-entry rows** in `scripts/test-resource-pulse.sh`, next to the sampler's
  driver (T:1151-1283), under a private bus with `XDG_CONFIG_HOME` set to a temp dir holding
  `resource-pulse/cockpit.json` copied from the template, `XDG_STATE_HOME` to an empty temp dir, and `HOME` to a
  temp dir (so no herdr socket, no `~/.ssh`): `gjs -m …/service/cockpit.js` starts and owns the name within 15 s;
  a `GetState` probe (`gdbus call … --method io.github.quantivly.dotfiles.Cockpit1.GetState`) answers protocol
  1, a layout with three groups, `sessions.herdrRunning` false, `mounts.rows` a list; a second copy exits 1; with
  the config file overwritten by `{` the next `GetState` (poll up to 3 s) answers `layout: null` and a
  `configError` naming the parse failure while `sources.mounts` is still an object; with the file deleted,
  `configError` is `missing`; SIGTERM ends it with exit 0 and no engine warning; the service's log holds
  `cockpit: serving`.

- [ ] **Step 5: Implement `service/cockpit.js`**, run the table: all rows pass. Update `EXPECTED_ROWS` and the
  guide's claim.

- [ ] **Step 6: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/service/cockpitDbusService.js gnome-shell/extensions/resource-pulse@dotfiles/service/cockpit.js gnome-shell/tests/cockpit-dbus.test.js gnome-shell/tests/run-private-bus.js scripts/test-resource-pulse.sh docs/GNOME_CONFIGURATION_GUIDE.md
git commit -m "Serve Cockpit1 on the session bus from a second service entry point"
```

---

### Task 11: The unit, the install link, the refresh step and the cost mode

**Files:**
- Create: `systemd/cockpit.service`
- Modify: `install.conf.yaml:38-42`, `scripts/resource-pulse-service-refresh.sh:60-63` and its `main`,
  `scripts/resource-pulse-cost.sh`, `scripts/test-resource-pulse.sh` (unit, install, refresh and cost rows)

**Interfaces:**
- Produces: `systemd/cockpit.service` with the header comment style of `resource-pulse.service` and exactly
  these settings: `[Unit]` `Description=Cockpit sources: sessions, network and mounts for the GNOME Shell
  extension`, `PartOf=graphical-session.target`, `StartLimitIntervalSec=300`, `StartLimitBurst=5`,
  `ConditionPathExists=%h/.config/resource-pulse/cockpit.json`; `[Service]` `Type=dbus`,
  `BusName=io.github.quantivly.dotfiles.Cockpit1`, `ExecStart=/usr/bin/gjs -m
  %h/.dotfiles/gnome-shell/extensions/resource-pulse@dotfiles/service/cockpit.js`, `Restart=on-failure`,
  `RestartSec=5`, `Slice=background.slice`, `Nice=10`, `CPUQuota=10%`, `MemoryHigh=64M`, `MemoryMax=96M`; no
  `[Install]`.
- `install.conf.yaml`: `~/.config/systemd/user/cockpit.service: systemd/cockpit.service` under the existing unit
  link with a two-line comment (inert without the config file).
- `scripts/resource-pulse-service-refresh.sh`: the unit and entry module become a list of pairs,
  `SERVICE_UNITS=(resource-pulse.service:service/main.js cockpit.service:service/cockpit.js)`; `main` runs the
  existing decision per pair after one `daemon-reload`; an inactive or **condition-skipped** unit
  (`ActiveState=inactive`) is silent; output lines name the unit. The environment overrides keep their names.
- `scripts/resource-pulse-cost.sh`: `--cockpit` selects `cockpit.service`'s `MainPID` the way `--service`
  selects the sampler's; `COCKPIT_RSS_BUDGET_MIB=48`; `--rss-kib` under `--cockpit` prints the budget line with
  that figure.

- [ ] **Step 1: Write the failing rows** in `scripts/test-resource-pulse.sh`, mirroring the sampler's (T:1285-1361
  unit rows, T:1023 install row, T:1379-1583 refresh rows, T:1584-1739 cost rows): `EXPECTED_COCKPIT_UNIT_SETTINGS`
  as the exact set above; no `[Install]`; `ConditionPathExists` present exactly once; `ExecStart` resolves to
  `service/cockpit.js` in the checkout; `systemd-analyze --user verify` on a sed-pointed copy; the install link
  line present once; the refresh step try-restarts `cockpit.service` when `service/cockpit.js` is newer than its
  start and leaves `resource-pulse.service` alone (and the reverse); an inactive cockpit unit is silent; the cost
  script's `--cockpit --rss-kib` reads the cockpit pid's status under a fake proc root. Plus one static row:
  no file under `service/` or `lib/` contains any of the strings `.credentials`, `.aws/`, `.zshrc.local`,
  `.gitconfig.local`, `.backup.local`, `~/.ssh/` outside `lib/constants.js`'s `STAT_ONLY_PATH_SUFFIXES` list
  (which the sources use only to refuse an `open`), with a fixture tree proving the row fails on a planted
  `load_contents` of such a path.

- [ ] **Step 2: Run the table**: the new rows fail.

- [ ] **Step 3: Implement** the unit, the link, the refresh generalisation and the cost mode.

- [ ] **Step 4: Run `scripts/test-resource-pulse.sh`** (all pass), `pre-commit run --files` on the touched
  scripts (shellcheck), and `scripts/check-state-table-totals.sh` if it is wired to this table. Update
  `EXPECTED_ROWS` and the guide's claim.

- [ ] **Step 5: Commit**

```bash
git add systemd/cockpit.service install.conf.yaml scripts/resource-pulse-service-refresh.sh scripts/resource-pulse-cost.sh scripts/test-resource-pulse.sh docs/GNOME_CONFIGURATION_GUIDE.md
git commit -m "Add cockpit.service, its install link, and extend the refresh step and cost script to it"
```

---

### Task 12: gnome-status reports the cockpit service

**Files:**
- Modify: `zsh/functions/system.sh:2373-2672` (the Resource Pulse block), `examples/gnome-settings.local.template`,
  `scripts/test-resource-pulse.sh` (gnome-status rows, T:567-1020 style)

**Interfaces:**
- Produces, under the existing `  service:` line, one `  cockpit:` line:
  - `  cockpit: skipped (no ~/.config/resource-pulse/cockpit.json)` when the unit's `LoadState=loaded`,
    `ActiveState=inactive` and `ConditionResult=no` (`systemctl --user show -p LoadState -p ActiveState -p
    SubState -p ConditionResult cockpit.service`; read `LoadState` first: `not-found` is `not installed`);
  - `  cockpit: active, protocol 1, last publish N s ago, stale: none` (or `stale: sessions, mounts`) from a
    `GetState` call with the same `gdbus` wrapper, reading `protocol` and `latestPublishedAtUsec` from the text
    before `"sources"`, and each source's `sampledAtUsec` and `intervalSeconds` with a pattern anchored on the
    source's name (stale when older than 3 intervals);
  - `  cockpit: failed` / `restarting` / `not running` / `no answer` with the same remedies as the service line,
    plus `⚠ cockpit: config invalid: <configError>` when `GetState` carries one;
  - a `⚠` when the cockpit unit **runs older code** than the checkout, computed with the closure helper from
    `service/cockpit.js`, as the sampler's is from `service/main.js`.
- `examples/gnome-settings.local.template`: after the Resource Pulse block, a commented block "Cockpit (optional)":
  the `gset org.gnome.desktop.background picture-options 'none'`, `primary-color '#121a1a'` and
  `org.gnome.desktop.screensaver` lines, commented, with a one-line pointer to copying the cockpit template to
  `~/.config/resource-pulse/cockpit.json`.

- [ ] **Step 1: Write the failing rows** with the existing `systemctl`/`gdbus` stubs: the skipped line; the active
  line with no stale source; the active line with one stale source (fixture JSON with an old `sampledAtUsec`);
  the config-invalid warning; `not installed`; the older-code warning for `service/cockpit.js`; and
  `gnome_status_run` making exactly one more `gdbus` call than before.

- [ ] **Step 2: Run the table**: the new rows fail.

- [ ] **Step 3: Implement** in `zsh/functions/system.sh` (reuse `rp_describe_running_service`'s helpers:
  `rp_unescaped_gvariant_string`, `rp_first_number_after`; add `rp_cockpit_*` locals beside the `rp_*` ones) and
  the template lines. `zsh -n zsh/functions/system.sh` must pass; `zsh/*` files get `zsh -n`, not shellcheck.

- [ ] **Step 4: Run `scripts/test-resource-pulse.sh`**: all pass. Update `EXPECTED_ROWS` and the claim.

- [ ] **Step 5: Commit**

```bash
git add zsh/functions/system.sh examples/gnome-settings.local.template scripts/test-resource-pulse.sh docs/GNOME_CONFIGURATION_GUIDE.md
git commit -m "Report the cockpit service in gnome-status and add the background lines to the template"
```

---

### Task 13: The nested harness starts the cockpit service; docs and changelog

**Files:**
- Modify: `scripts/resource-pulse-nested.sh:96-97, 967-1015` (`start_nested_service`, `wait_for_nested_service`),
  `scripts/test-resource-pulse.sh` (nested rows, T:2294-2461 style), `docs/GNOME_CONFIGURATION_GUIDE.md` (the
  Resource Pulse section), `CHANGELOG.md`, `docs/superpowers/specs/2026-11-09-desktop-cockpit-design.md` (a
  one-line "data side built: <plan path>" note under Status)

**Interfaces:**
- Produces: the harness starts both services on its private bus (`COCKPIT_MAIN_RELATIVE_PATH`,
  `COCKPIT_BUS_NAME` constants beside the existing two; `start_nested_service` takes the pair; the run's
  `XDG_CONFIG_HOME` gets `resource-pulse/cockpit.json` from the template; `stop` ends both); a cockpit that fails
  to appear is a harness failure, as the sampler's is.
- Guide: a **Cockpit service** subsection after "The dropdown": what it serves, the config file and its template,
  the condition (skipped, not failed, and what `gnome-status` says), the cadences and budgets, the secrets rule
  (allowlist, stat-only paths, the name guard), "nothing is drawn yet: the drawing side is the next plan", and
  the two new `gnome-status` lines. The "Every number, defined" table gains rows for the session row's fields,
  `VPN up`, `uplink`, `mounts`. The checks claim is updated.
- `CHANGELOG.md`: an entry under the next release for the data side.

- [ ] **Step 1: Write the failing hermetic nested rows** (`nested_constant` reads the two new constants; the
  supervise stub records two service starts; a missing cockpit entry fails the start).

- [ ] **Step 2: Run the table**: the rows fail.

- [ ] **Step 3: Implement** the harness change and write the docs.

- [ ] **Step 4: Run** `scripts/test-resource-pulse.sh`, `./scripts/check-claude-md.sh`, `scripts/check-doc-tokens.sh`,
  `pre-commit run --all-files`: all pass. Update `EXPECTED_ROWS` and the claim one last time.

- [ ] **Step 5: Commit**

```bash
git add scripts/resource-pulse-nested.sh scripts/test-resource-pulse.sh docs/GNOME_CONFIGURATION_GUIDE.md CHANGELOG.md docs/superpowers/specs/2026-11-09-desktop-cockpit-design.md
git commit -m "Start the cockpit service in the nested harness and document the data side"
```

---

## After the last task (the controller, not an implementer)

1. Open the PR; CI green; squash-merge (never `--admin`), the title and body rewritten to the final diff.
2. ff-deploy `~/.dotfiles` only with Zvi's go-ahead for this stage (the handoff froze the live checkout for the
   design session; the deploy is data-side only and restarts the sampler once for its new field).
3. Create `~/.config/resource-pulse/cockpit.json` from the template by hand (Zvi's machine only), then
   `systemctl --user start cockpit.service` by hand once (the extension does not know the unit yet), and check
   `gnome-status`.
4. Cost: `scripts/resource-pulse-cost.sh --cockpit --cpu-percent 600` unwatched and, with a watch held by a
   `gdbus` call in a second shell, watched; `--cockpit --rss-kib` now and in 24 h through `rabota schedule add`.
   The budgets: under 0.05% / 0.1% of one core, 48 MiB.
5. Then the drawing-side plan.
