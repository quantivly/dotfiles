# Desktop Cockpit, drawing side: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw stage one of the cockpit: a `CockpitClient` beside `PulseClient`, a grid of four cards (system,
apps, connections, sessions) on the cockpit monitor behind Super+D, tooltips, a session row click that takes the
owner to the pane, the sessions card in the dropdown, ding off through the local layer, the nested harness able to
prove it, and the docs. The data side (merged as #375) stays as it is apart from one additive reply field
(`windowPidCandidates`) and a fixture mode the harness alone uses.

**Architecture:** The shell never does IO: `cockpitClient.js` (pure Gio, mirroring `pulseClient.js`) starts
`cockpit.service`, treats a condition-skipped unit as "not configured" (no retries), caches the layout, consumes
`Changed`, pulls `GetState` once on suspicion of staleness (ruling R14), and forwards `FocusSession`. Every
decision is a pure function in `lib/` with rows (grid geometry, monitor rule, staleness, watch wanted, interaction
gating, window pick, text). Glue files (`cockpitLayer.js`, `cockpitCards.js`, `cockpitTooltip.js`) hold St/Clutter
code only and are pinned by text-read rows, as `card.js` is. The one shell-side action is activating a `Meta.Window`
whose pid the service names.

**Tech Stack:** GJS under GNOME Shell 50 (St, Clutter, Meta, Gio), the repo's plain-gjs state table
(`gnome-shell/tests/*.test.js` + `scripts/test-resource-pulse.sh`), the nested shell harness
(`scripts/resource-pulse-nested.sh`, headless Wayland, one virtual monitor), bash, zsh.

**Spec:** `docs/superpowers/specs/2026-11-09-desktop-cockpit-design.md` (sections "Where it is seen", "Background",
"Layout", "The cards, stage one", "Interaction", "Architecture", "The dropdown", "Testing"); it builds on
`docs/superpowers/specs/2026-11-08-resource-pulse-service-design.md`. The data-side rulings this plan must honour are
in the build ledger copied to `~/Projects/handoffs/cockpit-data-side-build-records/progress.md`: R14 (pull before
declaring stale), R17 (a never-started unit reads `ConditionResult=no`), R18 (`FocusSession.error` is a code), R20
(cap the composite row `id`).

## Global Constraints

- The four deal-breakers are binding: desktop instability; wrong or laggy numbers; cost (CPU, memory, battery);
  upkeep.
- **No file IO and no subprocess in the shell** (the static scan forbids the synchronous-IO and subprocess patterns
  in every file outside `service/`); D-Bus calls are the only IO, and every one is asynchronous with
  `DBUS_CALL_TIMEOUT_MS = 2000`.
- **Meaning is never carried by colour alone:** every state has its own symbolic icon (`St.Icon`, never a glyph);
  colour comes from a CSS class per state.
- **Additive-only JSON:** unknown fields ignored at any depth; a missing field blanks only its row; cards the
  extension does not know are skipped; sources it knows but the service does not send show "no data".
- **A stale number is never drawn as live:** a source is stale when its `sampledAtUsec` (wall clock) is older than
  `COCKPIT_SOURCE_STALE_INTERVALS = 3` × its `intervalSeconds` **and** one `GetState` pull, rate-limited to once per
  interval per source, still answers an old stamp (R14); then the card shows `no data since HH:MM`.
- **Secrets:** the shell draws only what the readers in `lib/cockpitProtocol.js` return; `FocusSession.error` is one
  of `COCKPIT_FOCUS_ERROR_CODES` and is never drawn, only logged; `mountPoint` is drawn only in a tooltip, truncated by
  the label's ellipsize, never in a row title.
- **Stylesheet:** add classes, never rename or restyle an existing one (`V1_STYLESHEET_CLASS_NAMES` pins them); new
  classes carry the `rp-cockpit-` prefix.
- **Reactivity:** cards are reactive only while no window of type `Meta.WindowType.DESKTOP` is above the layer on
  the cockpit monitor (a colleague with ding on sees display-only cards that behave exactly as v2's card); a click
  runs one safe action or nothing; there is no action that destroys, closes or sends.
- **Watch:** `WatchCockpit` is held while a cockpit card is visible and the overview is hidden, or while the dropdown
  is open; dropped otherwise and on disable (`UnwatchCockpit` uncancellable, as `PulseClient` does for the detail
  watch).
- **Lifecycle:** `enable()` calls `StartUnit` for both units; a cockpit `StartUnit` accepted with no name within
  `START_CONFIRMATION_TIMEOUT_SECONDS = 15` reads the unit's `ConditionResult` and `ConditionTimestampMonotonic` over
  systemd's D-Bus: `false` with a non-zero timestamp is SKIPPED (no retry, no warning, nothing drawn beyond v2, asked
  again on the next `enable()`); any other answer keeps v2's retry chain. A service that ran and then vanished is
  never restarted by the client (v2's rule). The last layout received is kept on the extension object across
  `enable`/`disable` (as `_lastGoodClockLabel` is) so a re-enable after a blank rebuilds the grid at once.
- **Budgets:** gnome-shell under 0.1 % of one core at idle, added by the whole extension; no repaint except on
  hover, on `Changed` and on the 30 s frozen repaint; gnome-shell RSS flat over 24 h.
- **Repo rules:** a new glue file goes into `GLUE_FILE_NAMES` (`gnome-shell/tests/imports.test.js`) and the table's
  glue-parse loop; a new pure top-level file into `PURE_TOP_LEVEL_FILE_NAMES` and `PURE_MODULE_PATHS`;
  `EXPECTED_SHELL_CLOSURE` is an exact string and changes with every module the shell newly imports; the pinned
  counts of `BEFORE_REDRAW`, `get_laters().remove(` and `notify::width` per glue file change with the glue; "could not
  run" is exit 2, never a pass; `EXPECTED_ROWS` and the guide's "(N checks" claim move together; commit messages in
  the imperative mood with the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; names explicit,
  units in the name, constants in `lib/constants.js`, Numpy-style JSDoc on every new function.
- **Nothing here changes the live session:** no `gsettings set`, no `gnome-extensions` enable or disable, no
  `./install`, no `systemctl --user` on either unit; the nested shell is the only place anything runs before the
  owner's deploy and login.

## Review Focus

Inputs the spec implies but no task's rows would otherwise exercise, most likely to bite first:

1. **The cockpit monitor disappears mid-session (undock) and the only monitor left is the primary:** the layer
   moves to it and the v2 card does not appear twice (top-right and in the system cell). Pinned in Task 1 (rule)
   and Task 8 (placement rows).
2. **A `Changed` arrives for a card the dropdown is showing while the desktop copy is frozen under a window:** the
   dropdown copy repaints, the desktop copy does not, and no repaint is queued twice. Pinned in Task 8 and Task 9.
3. **`FocusSession` succeeds in herdr but no window matches the candidate pids:** the pane is focused, nothing is
   activated, the dropdown still closes, one journal line at most per minute. Pinned in Task 2 (pick) and Task 10.
4. **The layout file names a card id this extension does not know** (a newer service): the cell stays empty, the
   caption still draws, nothing throws. Pinned in Task 1 and Task 8.
5. **The service answers `GetState` with a layout and then dies:** the grid stays, every cockpit card shows
   `no data since HH:MM`, the system card keeps drawing from the sampler, the client never restarts the service.
   Pinned in Task 5.

---

## File structure

**Create**

- `gnome-shell/extensions/resource-pulse@dotfiles/lib/cockpitGrid.js`: grid geometry from a work area and the
  layout's groups (pure).
- `lib/cockpitMonitor.js`: the monitor rule (pure).
- `lib/cockpitStaleness.js`: per-source freshness and the pull-on-suspicion decision (pure).
- `lib/cockpitInteraction.js`: watch wanted, interaction gating, window pick (pure).
- `lib/cockpitFormat.js`: every string the four cards and their tooltips draw (pure).
- `lib/processTree.js`: `/proc/<pid>/stat` parsing, herdr client detection, ancestor chains (pure; used by the
  service).
- `cockpitClient.js`: the `Cockpit1` client (pure Gio/GLib, no Shell import).
- `cockpitTooltip.js`: one tooltip actor shared by every card (glue).
- `cockpitCards.js`: the four card classes (glue).
- `cockpitLayer.js`: the layer per cockpit monitor: captions, cells, cover logic (glue).
- Tests: `gnome-shell/tests/cockpitGrid.test.js`, `cockpitMonitor.test.js`, `cockpitStaleness.test.js`,
  `cockpitInteraction.test.js`, `cockpitFormat.test.js`, `processTree.test.js`, `cockpitClient.test.js` (fixtures),
  `cockpit-client-dbus.test.js` (private bus), `cockpitGlue.test.js` (text-read rows for the three glue files),
  fixtures under `gnome-shell/tests/fixtures/cockpit/` (`proc-stat/`, `nested-state.json`).

**Modify**

- `lib/cockpitProtocol.js` (the reply gains `windowPidCandidates`), `lib/constants.js`, `service/cockpit.js`
  (candidates; fixture mode), `extension.js`, `indicator.js`, `card.js` (cell sizing only), `stylesheet.css`,
  `metadata.json` (unchanged: no `session-modes`, pinned).
- `gnome-shell/tests/run.js`, `run-private-bus.js`, `imports.test.js`, `visibility.test.js` (the counts rows move
  to `cockpitGlue.test.js` only if they are there; otherwise the table), `scripts/test-resource-pulse.sh`
  (closure pin, count rows, new rows, `EXPECTED_ROWS`), `scripts/resource-pulse-nested.sh` (`window`, `pointer`,
  `check`, the fixture), `scripts/apply-gnome-settings.sh` (`gdisable_extension`),
  `examples/gnome-settings.local.template`, `docs/GNOME_CONFIGURATION_GUIDE.md`, `CHANGELOG.md`, the spec's Status
  line.

The extension directory is `gnome-shell/extensions/resource-pulse@dotfiles/`; paths below are inside it unless they
start with `gnome-shell/tests/`, `scripts/`, `examples/` or `docs/`. Run every test command from the repo root. The
plain-gjs rows: `gjs -m gnome-shell/tests/run.js`; the full table: `scripts/test-resource-pulse.sh` (about a minute;
701 rows at the start of this plan).

---

### Task 1: Grid geometry and the monitor rule, pure

**Files:**
- Create: `lib/cockpitGrid.js`, `lib/cockpitMonitor.js`
- Modify: `lib/constants.js`
- Test: `gnome-shell/tests/cockpitGrid.test.js`, `cockpitMonitor.test.js`, `gnome-shell/tests/run.js`

**Interfaces:**
- Produces, `lib/cockpitGrid.js`:
  - `COCKPIT_GRID_REFERENCE = Object.freeze({widthPx: 1920, heightPx: 1080, marginPx: 52, innerGutterPx: 24,
    groupGapPx: 48, captionHeightPx: 28, rowGutterPx: 24, columns: 4, rows: 3})` (the spec's numbers at 1920×1080
    logical; in `lib/constants.js`).
  - `cockpitGridGeometry({workArea: {x, y, width, height}, groups: Array<{id, caption, columns, cards: string[]}>})
    → {captions: Array<{groupId, text, x, y, width, height}>, cells: Array<{cardId, groupId, column, row, x, y,
    width, height}>}`: margins, gutters and the caption height scale by `min(width / 1920, height / 1080)` (never
    below `COCKPIT_GRID_MIN_SCALE = 0.5`); the four columns share the remaining width evenly; the three rows share the
    remaining height evenly; groups sit left to right, each `columns` cells wide, separated by the group gap; a
    group's cards fill its columns left to right, then the next row; every card id in the layout gets a cell, known
    or not; the caption spans its group's width above its first row; all numbers are floored integers.
  - `isKnownCockpitCard(cardId)`: true for the ids this plan draws, `COCKPIT_DRAWN_CARD_IDS = ['system', 'apps',
    'connections', 'sessions']` (in `lib/constants.js`).
- Produces, `lib/cockpitMonitor.js`:
  - `chooseCockpitMonitorIndex({monitors: Array<{index, x, y, width, height, isPrimary, vendor: string|null,
    product: string|null}>, rule: {vendor, product}|null}) → number|null`: the monitor whose `vendor` and `product`
    both equal the rule's (case-sensitive) when present; else the only monitor when there is one; else the largest
    non-primary monitor by `width × height` (ties: the lowest index); null when `monitors` is empty.
  - `monitorDescriptorsFromDisplayConfig(currentStateVariantUnpacked) → Array<{connector, vendor, product}>` and
    `matchDescriptorsToMonitors({monitors, logicalMonitors, descriptors})`: the pure half of reading
    `org.gnome.Mutter.DisplayConfig.GetCurrentState` (its `monitors` array's first tuple element is
    `(connector, vendor, product, serial)`; its `logical-monitors` carry `x, y, scale, transform, is-primary` and the
    connectors they show), matching a logical monitor to a `Main.layoutManager.monitors[i]` by `x`/`y`. The builder
    confirms the tuple layout in the nested shell; the rows use a fixture copied from a real
    `gdbus call … GetCurrentState` with the serial blanked.

- [ ] **Step 1: Write the failing rows** (namespace imports; the harness's `assertEqual`):

```javascript
test('cockpitGrid: the spec grid at 1920x1080 has 420-wide cells, 300-tall rows and a 28 px caption row', () => {
    const geometry = cockpitGrid.cockpitGridGeometry({workArea: {x: 0, y: 0, width: 1920, height: 1080}, groups: TEMPLATE_GROUPS});
    const system = geometry.cells.find(c => c.cardId === 'system');
    assertEqual([system.x, system.y, system.width, system.height], [52, 80, 420, 300]);
    assertEqual(geometry.cells.find(c => c.cardId === 'connections').row, 1);
    assertEqual(geometry.cells.find(c => c.cardId === 'sessions').x, 52 + 2 * 420 + 24 + 48);
    assertEqual(geometry.captions.map(c => c.text), ['MACHINE', 'AGENTS', 'WORK']);
});
test('cockpitGrid: a work area offset and a smaller monitor scale the gutters, never the cell count', () => { /* 1280x720 at x=1920: every cell inside the work area; 8 cells; scale 2/3 → margin 34 */ });
test('cockpitGrid: an unknown card id still gets a cell', () => {
    const groups = [{id: 'g', caption: 'G', columns: 1, cards: ['weather']}];
    assertEqual(cockpitGrid.cockpitGridGeometry({workArea: FULL_HD, groups}).cells.length, 1);
    assertEqual(cockpitGrid.isKnownCockpitCard('weather'), false);
});
test('cockpitMonitor: the named monitor wins, the only monitor is the fallback, then the largest non-primary', () => {
    const dell = {index: 1, x: 1920, y: 0, width: 1920, height: 1080, isPrimary: false, vendor: 'DEL', product: 'DELL U2723QE'};
    const samsung = {index: 0, x: 0, y: 0, width: 1920, height: 1080, isPrimary: true, vendor: 'SAM', product: 'S24C650'};
    const rule = {vendor: 'DEL', product: 'DELL U2723QE'};
    assertEqual(cockpitMonitor.chooseCockpitMonitorIndex({monitors: [samsung, dell], rule}), 1);
    assertEqual(cockpitMonitor.chooseCockpitMonitorIndex({monitors: [samsung], rule}), 0);
    assertEqual(cockpitMonitor.chooseCockpitMonitorIndex({monitors: [samsung, {...dell, vendor: 'LG', product: 'x', width: 2560}], rule}), 1);
    assertEqual(cockpitMonitor.chooseCockpitMonitorIndex({monitors: [], rule}), null);
});
test('cockpitMonitor: DisplayConfig descriptors match layout monitors by position', () => { /* fixture: two monitors; the Dell at x=1920 → index 1 */ });
```

- [ ] **Step 2: Add both imports to `run.js`**, run `gjs -m gnome-shell/tests/run.js`, confirm the import errors.
- [ ] **Step 3: Implement both modules and the constants.** Pure: no Gio, GLib or Shell import.
- [ ] **Step 4: Run `gjs -m gnome-shell/tests/run.js`**: all pass. Run the table; set `EXPECTED_ROWS` and the guide's
  claim together (every task below does the same; it is not repeated).
- [ ] **Step 5: Commit**

```bash
git add gnome-shell/extensions/resource-pulse@dotfiles/lib/cockpitGrid.js gnome-shell/extensions/resource-pulse@dotfiles/lib/cockpitMonitor.js gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js gnome-shell/tests/cockpitGrid.test.js gnome-shell/tests/cockpitMonitor.test.js gnome-shell/tests/fixtures/cockpit gnome-shell/tests/run.js scripts/test-resource-pulse.sh docs/GNOME_CONFIGURATION_GUIDE.md
git commit -m "Add the cockpit grid geometry and the monitor rule as pure functions"
```

---

### Task 2: Staleness, watch, interaction gating and the window pick, pure

**Files:**
- Create: `lib/cockpitStaleness.js`, `lib/cockpitInteraction.js`
- Modify: `lib/constants.js`
- Test: `gnome-shell/tests/cockpitStaleness.test.js`, `cockpitInteraction.test.js`, `run.js`

**Interfaces:**
- Produces, `lib/cockpitStaleness.js`:
  - `sourceFreshness({sampledAtUsec, intervalSeconds, nowRealUsec, lastPullRequestedAtUsec, lastPullCompletedAtUsec})
    → {isStale: boolean, shouldPull: boolean, ageSeconds: number|null}`: `ageSeconds = (nowRealUsec −
    sampledAtUsec) / 1e6`; suspicion when `ageSeconds > COCKPIT_SOURCE_STALE_INTERVALS × intervalSeconds`;
    `shouldPull` when suspicious and (`lastPullRequestedAtUsec` is null or older than `intervalSeconds`);
    `isStale` when suspicious and a pull completed after the stamp (`lastPullCompletedAtUsec > sampledAtUsec`) without
    refreshing it; a null `sampledAtUsec` (never sampled, or the source absent) is `isStale: true, shouldPull: false,
    ageSeconds: null`; `intervalSeconds` null or 0 counts as `COCKPIT_FALLBACK_INTERVAL_SECONDS = 60`.
  - `noDataSinceLabel(sampledAtUsec, formatClock)`: `no data since HH:MM` using the injected formatter (the glue
    passes `GLib.DateTime`-based formatting; the rows pass a stub).
- Produces, `lib/cockpitInteraction.js`:
  - `isCockpitWatchWanted({isAnyCockpitCardVisible, isDropdownOpen, isOverviewVisible})`: `(isAnyCockpitCardVisible
    && !isOverviewVisible) || isDropdownOpen`.
  - `isDesktopInteractive({windowsOnMonitor: Array<{windowType, isShowing}>})`: false when any showing window has
    `windowType === 'desktop'` (the glue maps `Meta.WindowType.DESKTOP` to that string), true otherwise.
  - `pickWindowToActivate({windows: Array<{pid: number, stackIndex: number, isOnActiveWorkspace: boolean,
    isMinimized: boolean}>, candidatePids: number[]}) → number|null` (the `stackIndex` of the window to activate): among
    windows whose `pid` is in `candidatePids`, prefer the active workspace, then the highest `stackIndex`; null when
    none.
  - `focusSessionOutcome({reply: {focused, error, windowPidCandidates}, pickedStackIndex})
    → {activateWindow: boolean, logLine: string|null}`: activate when `focused` and a window was picked; a log line
    (`cockpit: focus: <error code>` or `cockpit: focus: no window for pids [..]`) otherwise; never both.

- [ ] **Step 1: Write the failing rows**:

```javascript
test('cockpitStaleness: fresh, suspicious-but-unpulled, pulled-and-still-old', () => {
    const base = {sampledAtUsec: 0, intervalSeconds: 10, lastPullRequestedAtUsec: null, lastPullCompletedAtUsec: null};
    assertEqual(staleness.sourceFreshness({...base, nowRealUsec: 20e6}), {isStale: false, shouldPull: false, ageSeconds: 20});
    assertEqual(staleness.sourceFreshness({...base, nowRealUsec: 31e6}), {isStale: false, shouldPull: true, ageSeconds: 31});
    assertEqual(staleness.sourceFreshness({...base, nowRealUsec: 31e6, lastPullRequestedAtUsec: 25e6}), {isStale: false, shouldPull: false, ageSeconds: 31});
    assertEqual(staleness.sourceFreshness({...base, nowRealUsec: 31e6, lastPullRequestedAtUsec: 30.5e6, lastPullCompletedAtUsec: 30.6e6}), {isStale: true, shouldPull: false, ageSeconds: 31});
    assertEqual(staleness.sourceFreshness({...base, sampledAtUsec: null, nowRealUsec: 1}), {isStale: true, shouldPull: false, ageSeconds: null});
});
test('cockpitInteraction: the watch is wanted while a card is visible outside the overview or the dropdown is open', () => { /* four combinations */ });
test('cockpitInteraction: a showing DESKTOP window makes the desktop display-only', () => {
    assertEqual(interaction.isDesktopInteractive({windowsOnMonitor: [{windowType: 'desktop', isShowing: true}]}), false);
    assertEqual(interaction.isDesktopInteractive({windowsOnMonitor: [{windowType: 'normal', isShowing: true}]}), true);
    assertEqual(interaction.isDesktopInteractive({windowsOnMonitor: []}), true);
});
test('cockpitInteraction: the window pick prefers the active workspace, then the topmost, and is null without a match', () => {
    const windows = [{pid: 10, stackIndex: 0, isOnActiveWorkspace: false, isMinimized: false}, {pid: 10, stackIndex: 2, isOnActiveWorkspace: true, isMinimized: true}, {pid: 11, stackIndex: 3, isOnActiveWorkspace: true, isMinimized: false}];
    assertEqual(interaction.pickWindowToActivate({windows, candidatePids: [10, 99]}), 2);
    assertEqual(interaction.pickWindowToActivate({windows, candidatePids: [42]}), null);
});
test('cockpitInteraction: the outcome activates on focused + picked, logs otherwise, never both', () => { /* three cases incl. error code 'herdr-unreachable' */ });
```

- [ ] **Step 2: Add the imports to `run.js`**, run, confirm failure.
- [ ] **Step 3: Implement** both modules; add `COCKPIT_FALLBACK_INTERVAL_SECONDS = 60` to `lib/constants.js`.
- [ ] **Step 4: Run the rows and the table**: all pass.
- [ ] **Step 5: Commit** (`Add the cockpit staleness, watch, interaction and window-pick rules`).

---

### Task 3: Card text and tooltip text, pure

**Files:**
- Create: `lib/cockpitFormat.js`
- Modify: `lib/constants.js`
- Test: `gnome-shell/tests/cockpitFormat.test.js`, `run.js`

**Interfaces:**
- Consumes: `lib/format.js` (`formatGibibytes`, `formatWholePercent`), `SESSION_IDLE_DIM_SECONDS`,
  `COCKPIT_REDACTED_NAME`.
- Produces (every function returns plain strings or arrays of them; no St):
  - `sessionsHeader(sessions) → {title: 'SESSIONS', count: string, counts: Array<{state, count}>, totalMemory: string}`
    (`counts` in `SESSION_STATES` order, zero counts included; `totalMemory` via `formatGibibytes`, `'—'` when null).
  - `sessionRows(sessions, {nowRealUsec}) → Array<{id, state, name, idleText, isLongIdle, memoryText, memoryFraction,
    isWaiting}>` sorted as published (the service sorts), at most `SESSIONS_CARD_ROW_LIMIT = 6` rows, plus
    `overflowText` (`'+N more'` or null); `idleText` is `'12m'`, `'2h'`, `'3d'` (one unit, rounded down), with a
    trailing `*` when `idleFromProcessAge`; `isLongIdle` when `idleSeconds ≥ SESSION_IDLE_DIM_SECONDS` and the state is
    idle or done; `memoryText` `'1.2G'`/`'340M'`; `memoryFraction` = row memory / the largest row memory (0 when null);
    `isWaiting` when `state === 'blocked'`.
  - `sessionTooltip(row, {account, contextPercent, paneId}) → string[]` (lines: the state word, `pane <id>`,
    `account <acct>` when known, `context <N>%` when known, `memory: process only; MCP servers and tool shells not
    counted`).
  - `appsRows(apps, {limit: APPS_CARD_ROW_LIMIT = 6}) → {cpu: Array<{name, cpuText, cpuFraction}>, memory:
    Array<{name, memoryText, memoryFraction}>}` from `cpuRanking`/`memoryRanking` (null lists → empty arrays).
  - `connectionsRows(network, mounts) → Array<{kind: 'uplink'|'vpn'|'ssh'|'mount', icon: string, text: string,
    tooltip: string[], fraction: number|null}>`: uplink `'wired · wifi off'` / `'wifi'` / `'offline'` with the
    connectivity word in the tooltip; VPN `'VPN up (tun0)'` / `'VPN down'`; `'N live ssh masters'` (`'no ssh
    masters'` for 0); one mount row per mount: label, `'120G free'` (free of total in the tooltip, with the mount
    point), `fraction` = used share (null when sizes unknown). Icon names are the constants in
    `COCKPIT_ICON_NAMES` (see Task 6).
  - `noDataText(sampledAtUsec, formatClock)`: delegates to `noDataSinceLabel`; `herdrNotRunningText = 'herdr not
    running'`.
  - `stateIconName(state)` and `stateStyleClass(state)` for the five session states (icon names from
    `COCKPIT_ICON_NAMES`; classes `rp-cockpit-state-<state>`).

- [ ] **Step 1: Write the failing rows** against a `FULL_STATE` fixture shared with `cockpitProtocol.test.js` (import
  its builder or copy the object): header counts in order; six rows and `'+2 more'` from eight; idle text at 59 s,
  61 s, 2 h, 3 d, with the `*`; long-idle only for idle/done; memory fraction 1 for the largest; the tooltip lines
  with and without account/context; apps rows capped at six with null lists empty; the four connection row kinds
  with their texts; `noDataText` through a stub clock; a name of `'—'` passes through unchanged.
- [ ] **Step 2: Add the import to `run.js`**, run, confirm failure.
- [ ] **Step 3: Implement**; add `SESSIONS_CARD_ROW_LIMIT`, `APPS_CARD_ROW_LIMIT` and the idle unit thresholds to
  `lib/constants.js`.
- [ ] **Step 4: Run the rows and the table**: all pass.
- [ ] **Step 5: Commit** (`Add the pure text of the cockpit cards and their tooltips`).

---

### Task 4: `FocusSession` names the window; a fixture mode for the harness (data side)

**Files:**
- Create: `lib/processTree.js`, fixtures `gnome-shell/tests/fixtures/cockpit/proc-stat/<pid>` (five synthetic
  `/proc/<pid>/stat` lines: a herdr server with no tty, a herdr client with a tty, its shell, its terminal, pid 1),
  `gnome-shell/tests/fixtures/cockpit/nested-state.json`
- Modify: `lib/cockpitProtocol.js`, `lib/constants.js`, `service/cockpit.js`, `scripts/test-resource-pulse.sh`
  (real-entry rows)
- Test: `gnome-shell/tests/processTree.test.js`, `cockpitProtocol.test.js`, `cockpit-dbus.test.js`, `run.js`

**Interfaces:**
- Produces, `lib/processTree.js`: `parseProcStat(text) → {pid, comm, ppid, ttyNr}|null` (the comm is the
  parenthesised field, which may hold spaces; fields 4 and 7 after the closing parenthesis),
  `herdrClientPids(statByPid: Map<number, ProcStat>) → number[]` (comm `'herdr'` and `ttyNr !== 0`, ascending),
  `ancestorChain(pid, statByPid, maxDepth = PROCESS_ANCESTOR_MAX_DEPTH = 16) → number[]` (the pid first, then each
  parent, stopping at 1 or a missing entry).
- `lib/cockpitProtocol.js`: the reply gains `windowPidCandidates: number[]` (counts, at most
  `FOCUS_WINDOW_PID_CANDIDATES_MAX = 64`, missing → `[]`); `windowPid` stays and stays null. Additive.
- `service/cockpit.js`: after a successful `pane.focus`, `focusSession` reads `/proc` (the directory listed through
  the sources' refusing reader; `/proc/<pid>/stat` for every numeric entry), builds the candidates as the chains of
  every herdr client pid, concatenated client by client, deduplicated, bounded; a `/proc` read failure leaves `[]`
  and one rate-limited log line. **Fixture mode:** when the environment variable
  `RESOURCE_PULSE_COCKPIT_FIXTURE` names a readable JSON file, the process serves that file's `state` (through
  `buildCockpitStatePayload`) instead of running the sources, re-reads it on change like the config, and answers
  `FocusSession` with the file's `focusReply` (through the reader); the log says `cockpit: serving a fixture
  (<path>)`. The unit never sets the variable; only the harness does.

- [ ] **Step 1: Write the failing rows**: the parser on each fixture line (a comm with a space); the client pids
  (server excluded); the chain from the client to pid 1 and its bound; the reader's `windowPidCandidates` (missing
  → `[]`, over the bound → truncated, a non-count entry dropped); the private-bus row "FocusSession answers the
  candidates the cockpit object returns"; real-entry rows: with `RESOURCE_PULSE_COCKPIT_FIXTURE` set to
  `nested-state.json`, `GetState` answers the fixture's layout and sources and `FocusSession('w1:p1')` answers
  `focused: true` with `windowPidCandidates [4242]`; without the variable the fixture is ignored (the existing rows).
- [ ] **Step 2: Add the import to `run.js`**, run, confirm failure.
- [ ] **Step 3: Implement**; constants `PROCESS_ANCESTOR_MAX_DEPTH`, `FOCUS_WINDOW_PID_CANDIDATES_MAX`,
  `COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE = 'RESOURCE_PULSE_COCKPIT_FIXTURE'`.
- [ ] **Step 4: Run the table**: all pass, including the stat-only row (`/proc` paths carry no fragment).
- [ ] **Step 5: Commit** (`Let FocusSession name the herdr client's windows and serve a fixture state for the harness`).

---

### Task 5: `CockpitClient`

**Files:**
- Create: `cockpitClient.js`
- Modify: `lib/constants.js`, `gnome-shell/tests/imports.test.js` (`PURE_TOP_LEVEL_FILE_NAMES`),
  `scripts/test-resource-pulse.sh` (`PURE_MODULE_PATHS`)
- Test: `gnome-shell/tests/cockpitClient.test.js` (fixtures: `FakeTimeouts`, `FakeProxy`, `FakeServiceStarter`
  copied from `client.test.js`, plus a `FakeSystemdUnit` answering `ConditionResult`/`ConditionTimestampMonotonic`),
  `gnome-shell/tests/cockpit-client-dbus.test.js` (private bus against a `FakeCockpit` from `cockpit-dbus.test.js`),
  `run.js`, `run-private-bus.js`

**Interfaces:**
- Consumes: `lib/cockpitProtocol.js` (names, parsers), `lib/cockpitStaleness.js`, `lib/wiring.js`
  (`nextStartRetryDelaySeconds`), `lib/errorLog.js`.
- Produces: `class CockpitClient` mirroring `PulseClient`:
  - `constructor({busType, connection, startUnit, createProxy, readUnitCondition, nowUsec, nowRealUsec, timeouts,
    errorLog, cachedLayout})`: every dependency injectable with a real default; `readUnitCondition(connection,
    cancellable) → Promise<{conditionResult: boolean|null, conditionTimestampMonotonic: number|null,
    activeState: string|null}>` reads `org.freedesktop.systemd1` `GetUnit('cockpit.service')` then the three
    properties (`DO_NOT_AUTO_START`, 2 s timeout).
  - `get state`: one of `CockpitClientState = {STARTING, SKIPPED, LIVE, VANISHED}`; `get layout` (the cached layout,
    seeded from `cachedLayout`); `get configError`; `get sourcesByName`; `sourceFreshness(name)` (Task 2's result for
    the stored stamp).
  - `start()`: `StartUnit('cockpit.service', 'replace')` with v2's chain; on an accepted job with no name within 15 s,
    `readUnitCondition`: `conditionResult === false && conditionTimestampMonotonic > 0` → `SKIPPED` (chain ends, one
    `info` line, no warning); anything else → v2's retry schedule. The name appearing → `GetState` → `LIVE`.
  - `destroy()`: `UnwatchCockpit` uncancellable, cancel, timeouts removed, proxy disconnected, listeners cleared.
  - `setWatchWanted(isWanted)`: sends `WatchCockpit`/`UnwatchCockpit` only on change and only to an owner; re-asserts
    when the owner appears.
  - `addListener(cb(event)) → id`, `removeListener(id)`; events: `{type: 'state'}` (client state changed),
    `{type: 'layout'}` (layout or configError changed), `{type: 'sources', names: string[]}` (from `Changed`, or from
    a pull that refreshed stamps).
  - `pullIfSuspicious(name)`: applies `sourceFreshness`; when `shouldPull`, one `GetState` (rate-limited per source
    by the stored `lastPullRequestedAtUsec`), updating stamps and emitting `sources`.
  - `focusSession(id) → Promise<reply>` (parsed; a D-Bus failure resolves to `{focused: false, windowPid: null,
    error: 'internal', windowPidCandidates: []}` and logs once per minute).
  - On the owner vanishing: `VANISHED`, stamps untouched (every source will read stale on the next pull), no
    `StartUnit`.

- [ ] **Step 1: Write the failing fixture rows** (the `client.test.js` style): start → StartUnit → name appears →
  GetState → LIVE with the layout and sources; accepted-but-skipped → `readUnitCondition` false/non-zero →
  SKIPPED, no retry timer armed, `cachedLayout` kept; accepted-but-absent with `conditionResult` true → the retry
  schedule 5/30/300; `Changed` with `['mounts']` → one `sources` event naming mounts only; `Changed` carrying
  `layout`/`configError` → a `layout` event; `pullIfSuspicious('mounts')` at 100 s with a 30 s interval → one
  GetState, a second call at 110 s → none, at 131 s → one; after a pull that answers the same old stamp,
  `sourceFreshness('mounts').isStale` is true; owner vanishes → VANISHED, no StartUnit, `UnwatchCockpit` not sent
  (nothing to send to); `setWatchWanted(true)` before the owner exists → sent once it appears; `destroy()` sends
  `UnwatchCockpit` when held; `focusSession` rejection → the `internal` reply. Private-bus rows: GetState round trip,
  one `Changed` → one event, the watch counted on the fake and dropped on `destroy()`, `FocusSession` reply parsed.
- [ ] **Step 2: Register the file** in `PURE_TOP_LEVEL_FILE_NAMES` and `PURE_MODULE_PATHS`; add the imports to
  `run.js` and `run-private-bus.js`; run, confirm failure.
- [ ] **Step 3: Implement `cockpitClient.js`** (pure Gio/GLib; the same `connectObject`-free, callback style as
  `pulseClient.js`); constants `COCKPIT_UNIT_NAME = 'cockpit.service'`, the systemd property names.
- [ ] **Step 4: Run the rows and the table**: all pass (the shell closure is unchanged until Task 8 imports the client).
- [ ] **Step 5: Commit** (`Add the Cockpit1 client with the skipped-unit rule and pull-on-suspicion`).

---

### Task 6: The tooltip actor, the icon names and the stylesheet classes (glue)

**Files:**
- Create: `cockpitTooltip.js`
- Modify: `stylesheet.css`, `lib/constants.js`, `lib/layout.js`, `gnome-shell/tests/imports.test.js`
  (`GLUE_FILE_NAMES`), `scripts/test-resource-pulse.sh` (glue-parse loop)
- Test: `gnome-shell/tests/cockpitGlue.test.js` (text-read rows), `layout.test.js` or `visibility.test.js` (the
  placement row), `run.js`

**Interfaces:**
- Produces: `class CockpitTooltip` (an `St.Label` with class `rp-cockpit-tooltip`, in top chrome via
  `Main.layoutManager.addTopChrome`, hidden by default): `showFor(anchorActor, lines: string[])` after
  `HOVER_LABEL_DELAY_MS` (300, reused), fade in `HOVER_LABEL_FADE_IN_MS`; `hide()` (fade out, cancels a pending
  show); `destroy()`; placement through the new pure `tooltipPosition({anchorRect, labelWidthPx, labelHeightPx,
  gapPx, monitorRect}) → {x, y}` in `lib/layout.js` (below the anchor, clamped into the monitor, above it when
  there is no room below). One instance per layer and one per dropdown.
- `COCKPIT_ICON_NAMES` (`lib/constants.js`): session states `working: 'media-playback-start-symbolic'`, `blocked:
  'dialog-warning-symbolic'`, `idle: 'media-playback-pause-symbolic'`, `done: 'emblem-ok-symbolic'`, `unknown:
  'dialog-question-symbolic'`; connections `wired: 'network-wired-symbolic'`, `wifi: 'network-wireless-symbolic'`,
  `offline: 'network-offline-symbolic'`, `vpn: 'network-vpn-symbolic'`, `ssh: 'utilities-terminal-symbolic'`,
  `mountRemovable: 'drive-removable-media-symbolic'`, `mountNetwork: 'folder-remote-symbolic'`.
- `stylesheet.css` (additive, after the existing rules, under a comment naming this release): `.rp-cockpit-layer`,
  `.rp-cockpit-caption` (uppercase, `rgba(255,255,255,.6)`, letter-spacing), `.rp-cockpit-cell` (the card fills its
  cell: no fixed width; padding as `.resource-pulse-card`), `.rp-cockpit-row`, `.rp-cockpit-row-bar` (the faint bar:
  `rgba(255,255,255,.08)` fill), `.rp-cockpit-row:hover` (`rgba(255,255,255,.04)` background), `.rp-cockpit-state-
  working` (teal `#2190a4`), `-blocked` (amber `#e5a50a`), `-idle` (`rgba(255,255,255,.45)`), `-done` (green
  `#26a269`), `-unknown` (`rgba(255,255,255,.45)`), `.rp-cockpit-name-waiting` (the amber tint), `.rp-cockpit-row-
  long-idle` (opacity .55), `.rp-cockpit-tooltip` (as `.resource-pulse-hover-label`, left-aligned, multi-line),
  `.rp-cockpit-no-data`.

- [ ] **Step 1: Write the failing rows**: `tooltipPosition` (below when room, above when not, clamped at the right
  edge); text-read rows on `cockpitTooltip.js` (imports `Main` from the shell; uses `addTopChrome`; one
  `GLib.timeout_add` named `[resource-pulse] show the cockpit tooltip`; removes it in `destroy`), on the stylesheet
  (every class above present once; every `V1_STYLESHEET_CLASS_NAMES` rule unchanged: reuse the existing row), on
  `COCKPIT_ICON_NAMES` (every state and connection kind has a `-symbolic` name).
- [ ] **Step 2: Register `cockpitTooltip.js`** in `GLUE_FILE_NAMES` and the table's glue-parse loop; add the import to
  `run.js`; run, confirm failure.
- [ ] **Step 3: Implement** the actor (the hover-label mechanism of `indicator.js`, generalised), the constants, the
  CSS, `tooltipPosition`.
- [ ] **Step 4: Run the rows and the table**: all pass (the no-IO scan covers the new file).
- [ ] **Step 5: Commit** (`Add the cockpit tooltip actor, the icon names and the cockpit stylesheet classes`).

---

### Task 7: The four cards (glue)

**Files:**
- Create: `cockpitCards.js`
- Modify: `card.js` (cell sizing), `gnome-shell/tests/imports.test.js`, `scripts/test-resource-pulse.sh` (glue loop)
- Test: `gnome-shell/tests/cockpitGlue.test.js`, `run.js`

**Interfaces:**
- Consumes: Task 3's text functions, Task 6's tooltip and classes, `PulseCard` (`card.js`), `CardRepaintPlanner`
  (`lib/cardRepaint.js`) for the frozen state.
- Produces (each `GObject.registerClass`, extends `St.BoxLayout` vertical, style classes `resource-pulse-card
  rp-cockpit-cell`, created `reactive: false`):
  - `class CockpitCardBase`: `constructor({tooltip, onRowActivated})`; `setCellSize(width, height)`; `setFrozen(bool)`
    (dims via the `frozen` pseudo-class, stops row repaints); `setInteractive(bool)` (sets `reactive` on the card and
    every row; a non-interactive card shows no hover state and takes no click); `showNoData(text)` /
    `showHerdrNotRunning()`; `update(state, nowRealUsec)`; `destroy()`. Rows are `St.BoxLayout` with class
    `rp-cockpit-row`, built once per visible row index (`SESSIONS_CARD_ROW_LIMIT`) and reused: an `St.Icon`
    (`icon_size: COCKPIT_ROW_ICON_SIZE_PX = 16`), a name label (ellipsize END), two value labels (tabular), and the faint
    bar as an `St.Widget` whose width is set from `fraction` (no cairo). Hover: `enter-event` → `tooltip.showFor(row,
    lines)`, `leave-event` → `tooltip.hide()`; click: `button-release-event` with button 1 → `onRowActivated(rowId)`.
  - `class SystemCockpitCard`: wraps a `PulseCard` (the v2 card) in the cell; `update` forwards the sampler's
    snapshot; its click runs the existing "open Resources" action: the body of `indicator.js`'s `_openResources`
    moves to an exported `openResourcesApp()` in `cockpitCards.js`, which `indicator.js` then calls (that direction
    has no import cycle: `indicator.js` imports `cockpitCards.js` in Task 9, never the reverse); tooltip: none.
  - `class AppsCockpitCard`: six CPU rows then a divider and six memory rows, from `appsRows`; no click; tooltip per
    row with the group key.
  - `class ConnectionsCockpitCard`: one row per `connectionsRows` entry; no click; tooltip from the row.
  - `class SessionsCockpitCard`: header (`SESSIONS N`, the five state icons with counts, the bucket total), six rows
    from `sessionRows`, `+N more`; row icon and class from `stateIconName`/`stateStyleClass`; long-idle rows get
    `rp-cockpit-row-long-idle`, a waiting row's name `rp-cockpit-name-waiting`; click → `onRowActivated(row.id)`;
    tooltip from `sessionTooltip`; `showHerdrNotRunning()` when `herdrRunning` is false.
- `card.js`: `PulseCard` gains `setCellSize(width, height)` (removes the `rp-card-fixed` class and sets the size) and
  keeps `placeOnPrimaryMonitor()` for the skipped case; no other change.

- [ ] **Step 1: Write the failing text-read rows** on `cockpitCards.js`: the four classes exported; every row-building
  path uses `St.Icon` with a name from `COCKPIT_ICON_NAMES` (no literal `-symbolic` string elsewhere); `reactive:
  false` at construction; `setInteractive` touches `reactive` only; no `St.DrawingArea` in the new cards (bars are
  widgets); every `connect(` has a matching disconnect or `connectObject`; no IO pattern (the table's scan); the
  `rp-cockpit-` classes used exist in the stylesheet (cross-check with Task 6's list); `card.js` exports
  `setCellSize` and keeps `placeOnPrimaryMonitor`.
- [ ] **Step 2: Register the glue file**; run, confirm failure.
- [ ] **Step 3: Implement.** Builders decide the row widgets' exact packing; the plan fixes the classes, the icon
  names, the row limit and the events.
- [ ] **Step 4: Run the rows and the table.**
- [ ] **Step 5: Commit** (`Add the four cockpit cards: system, apps, connections and sessions`).

---

### Task 8: The layer and the extension wiring (glue)

**Files:**
- Create: `cockpitLayer.js`
- Modify: `extension.js`, `scripts/test-resource-pulse.sh` (`EXPECTED_SHELL_CLOSURE`, the count rows, the
  `_lastGoodClockLabel`-style row), `gnome-shell/tests/imports.test.js`, `visibility.test.js` if it holds the count
  rows
- Test: `gnome-shell/tests/cockpitGlue.test.js`, the table

**Interfaces:**
- Produces: `class CockpitLayer` (an `St.Widget` with class `rp-cockpit-layer` in `Main.layoutManager._backgroundGroup`,
  below ding's DESKTOP window if any): `constructor({cockpitClient, pulseClient, tooltip, onSessionActivated})`;
  `placeOnMonitor(monitorIndex, workArea)` (geometry from `cockpitGridGeometry`; captions and known cards created
  once, repositioned on each call; unknown ids leave their cells empty); `setInteractive(bool)`; `cardRects()` (for
  the cover check, one rect per drawn card); `setCardFrozen(cardId, bool)`; `get isAnyCardVisible`; `destroy()`.
  It listens to the cockpit client's events (layout → rebuild; sources → `update` the cards that consume them;
  state VANISHED → every cockpit card `showNoData`) and to the pulse client (system card).
- `extension.js`:
  - `enable()`: after the `PulseClient`, `new CockpitClient({errorLog, cachedLayout: this._lastCockpitLayout})`; the
    layer is created only when the client reports a layout (`LIVE`, or the cached layout before the first answer);
    while the cockpit client is `SKIPPED` or has no layout, v2's card sits top-right on the primary exactly as today;
    when a layout is known, the v2 card moves into the system cell (`setCellSize`) and the primary's desktop goes
    bare. `_lastCockpitLayout` is saved in `_tearDown()` before the client is destroyed, as `_lastGoodClockLabel` is.
  - The monitor: `Main.layoutManager.monitors` plus the DisplayConfig descriptors (one asynchronous `GetCurrentState`
    call on enable and on `monitors-changed`, through the connection, 2 s timeout; absent answer → descriptors
    empty, so the rule falls back) → `chooseCockpitMonitorIndex`; `getWorkAreaForMonitor(index)`; re-placed on
    `monitors-changed` and `workareas-changed` through the existing coalesced `BEFORE_REDRAW` later (the count rows
    move: `extension.js:3/3/2` or whatever the implementation yields, pinned deliberately).
  - Cover: `_isCardCovered` generalised to `(monitor, rect)`; each cockpit card is checked with its own rect against
    the covering windows of the cockpit monitor; `setCardFrozen` per card; `isAnyCardVisible` feeds the watch.
  - Interaction: on `restacked`, `monitors-changed` and `window-created`/`window-left-monitor`, compute
    `isDesktopInteractive` from `global.display.list_all_windows()` on the cockpit monitor and call
    `layer.setInteractive`.
  - Watch: `_syncCockpitWatch()` → `cockpitClient.setWatchWanted(isCockpitWatchWanted({...}))`, called where
    `_syncDetailWatch` is.
  - Suspicion: the cover re-check timer (already every `SAMPLE_INTERVAL_SECONDS` while covered) and the frozen
    repaint call `cockpitClient.pullIfSuspicious(name)` for every drawn source once per tick; a visible card's
    update path calls it on each `Changed` for the sources it did not receive.
  - Teardown: the new steps join `runEveryStep` in `_tearDown` (layer before cards' clients; `UnwatchCockpit` by the
    client's `destroy`); the destroy-order row is updated to `layer card indicator cockpitClient client` or the
    order the builder settles, pinned.

- [ ] **Step 1: Write the failing rows**: text-read rows on `cockpitLayer.js` (in `_backgroundGroup`; uses
  `cockpitGridGeometry` and `isKnownCockpitCard`; no IO; `destroy` removes every child and listener) and on
  `extension.js` (`CockpitClient` constructed with `cachedLayout`; `_lastCockpitLayout` saved in `_tearDown` before
  the client destroy; `chooseCockpitMonitorIndex` and `getWorkAreaForMonitor` used; `isCockpitWatchWanted` used;
  `pullIfSuspicious` called from the re-check timeout; `setInteractive` wired to `restacked`); the updated
  `EXPECTED_SHELL_CLOSURE` (the new modules: `cockpitClient.js`, `cockpitLayer.js`, `cockpitCards.js`,
  `cockpitTooltip.js`, `lib/cockpitProtocol.js`, `lib/cockpitGrid.js`, `lib/cockpitMonitor.js`,
  `lib/cockpitStaleness.js`, `lib/cockpitInteraction.js`, `lib/cockpitFormat.js`, and whatever they import) with the
  pin comment's counts corrected; the count rows.
- [ ] **Step 2: Register the glue file**; run the table; the closure row and the count rows fail (by design) until
  Step 3.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the table**: all pass; `pre-commit run --files` on the touched files.
- [ ] **Step 5: Commit** (`Draw the cockpit layer on the chosen monitor and wire the cockpit client into the extension`).

---

### Task 9: The sessions card in the dropdown

**Files:**
- Modify: `indicator.js`, `extension.js` (watch), `stylesheet.css` (`.rp-cockpit-menu-sessions-item`, additive)
- Test: `gnome-shell/tests/cockpitGlue.test.js`, the table (`notify::(width|scale-factor)` count row)

**Interfaces:**
- `PulseIndicator` constructor gains `cockpitClient`; `_buildDropdown()` adds, under the system card item, a
  `PopupBaseMenuItem({reactive: false, can_focus: false, style_class: 'rp-cockpit-menu-sessions-item'})` holding a
  `SessionsCockpitCard` with its own `CockpitTooltip` and `onRowActivated: id => this._onSessionActivated(id)`;
  `setInteractive(true)` always in the dropdown (the menu is above every window); frozen while the menu is closed
  (as the dropdown's system card is), updated while open; `_onSessionActivated(id)` closes the menu then calls the
  extension's activation path (Task 10). `isCockpitWatchWanted` already counts `isDropdownOpen`.

- [ ] **Step 1: Write the failing rows**: text-read rows (the item class present in CSS and in `indicator.js`; the
  sessions card frozen on close and thawed on open; `menu.close()` before the activation call; the count row updated).
- [ ] **Step 2: Run the table**, confirm failure. **Step 3: Implement.** **Step 4: Run the table.**
- [ ] **Step 5: Commit** (`Show the sessions card in the top-bar dropdown`).

---

### Task 10: Take me there: the click activates the pane's window

**Files:**
- Modify: `extension.js` (`_activateSession(id)`), `cockpitLayer.js`/`indicator.js` (pass the handler)
- Test: `gnome-shell/tests/cockpitGlue.test.js`, the table

**Interfaces:**
- `extension.js` `_activateSession(sessionId)`: `cockpitClient.focusSession(sessionId)` → on reply, build
  `windows` from `global.display.list_all_windows()` (pid via `window.get_pid()`, `stackIndex` from
  `global.display.sort_windows_by_stacking`, `isOnActiveWorkspace`, `isMinimized`) → `pickWindowToActivate` →
  `focusSessionOutcome` → `Main.activateWindow(window)` (which unminimizes and raises it, ending show-desktop) or
  one rate-limited log line. Never throws into the event handler; a second click while one is in flight is ignored
  (`_isActivationInFlight`).

- [ ] **Step 1: Write the failing rows**: text-read rows (`focusSession` awaited inside a try; `pickWindowToActivate`
  and `focusSessionOutcome` used; `Main.activateWindow` is the only activation call; the in-flight guard).
- [ ] **Step 2–4:** run, implement, run.
- [ ] **Step 5: Commit** (`Activate the herdr window a clicked session row names`).

---

### Task 11: ding off through the local layer

**Files:**
- Modify: `scripts/apply-gnome-settings.sh` (`gdisable_extension`), `examples/gnome-settings.local.template`,
  `scripts/test-resource-pulse.sh` (rows beside the `genable_extension` ones)

**Interfaces:**
- `gdisable_extension <uuid>`: the counterpart of `genable_extension`: appends the uuid to `org.gnome.shell`
  `disabled-extensions` (the key that wins in GNOME 50) when absent, removes it from `enabled-extensions` when
  present, logs `SUCCESS`/`INFO` lines in the same style, warns when the schema is absent; idempotent.
- Template: after the Cockpit block, a commented line `# gdisable_extension ding@rastersoft.com` with a two-line
  comment: the cockpit's cards take hover and click only without ding's desktop window; losing ding costs the
  desktop right-click menu.

- [ ] **Step 1: Write the failing rows** with the stateful `gsettings` stub: disable adds to `disabled-extensions`
  once (a second call changes nothing), removes from `enabled-extensions`, warns on a missing schema; the template
  line present and commented.
- [ ] **Step 2–4:** run, implement, run (`pre-commit` shellcheck on the script).
- [ ] **Step 5: Commit** (`Add gdisable_extension so the local layer can turn ding off for the cockpit`).

---

### Task 12: The nested harness proves it

**Files:**
- Modify: `scripts/resource-pulse-nested.sh` (`window`, `pointer`, `check` subcommands; the fixture for the cockpit),
  `scripts/test-resource-pulse.sh` (hermetic rows), `gnome-shell/tests/fixtures/cockpit/nested-state.json` (Task 4)

**Interfaces:**
- `start` also exports `RESOURCE_PULSE_COCKPIT_FIXTURE=<run>/state/cockpit-fixture.json` to the cockpit service,
  written from `nested-state.json` with `windowPidCandidates` left empty until a window exists (the fixture is
  re-read on change, Task 4).
- `window <title>`: opens a Gtk 4 window in the run (`gjs` with `Gtk-4.0`, `GDK_BACKEND=wayland`, the run's
  `WAYLAND_DISPLAY`), records its pid at `state/windows/<title>.pid`, rewrites the fixture's `focusReply` with
  `windowPidCandidates: [<pid>]`; `stop` kills it. Refuses without a run.
- `pointer <x> <y> [click]`: through `eval`, a `Clutter` virtual pointer device (`global.backend.get_default_seat()
  .create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE)`, `notify_absolute_motion`, `notify_button`) at
  logical coordinates; the builder verifies the headless backend accepts it.
- `check cockpit`: a scripted sequence printing `ok`/`bad` lines and exiting non-zero on any `bad`: the extension
  ACTIVE; one `CockpitLayer` child in the background group on monitor 0 (the only-monitor rule); four cards; the
  layer interactive (no DESKTOP window); pointer over the first sessions row → the tooltip label visible after 400
  ms; `window herdr-probe` then click the row → `global.display.focus_window.get_pid()` equals the probe's pid;
  show-desktop (every window minimized through `eval`) then click → the probe unminimized and focused; `screenshot
  cockpit.png`; the shell log holds no `resource-pulse:` or `cockpit:` error.
- Hermetic rows: usage of the three subcommands; `window` refuses without a run and records the pid file; the
  fixture path exported to the cockpit start; `check cockpit` with a stubbed `eval` answering the expected values
  passes and with one wrong answer fails naming the step.

- [ ] **Step 1: Write the failing hermetic rows.** **Step 2: Run the table**, confirm failure.
- [ ] **Step 3: Implement**, then run the real nested shell once from this worktree (`scripts/resource-pulse-nested.sh
  start`, `check cockpit`, `stop`) and paste the `ok` lines and the screenshot path into the task report; the live
  `enabled-extensions` must be proven unchanged before and after (`gsettings get org.gnome.shell enabled-extensions`
  is a read).
- [ ] **Step 4: Run the table.** **Step 5: Commit** (`Teach the nested harness to open a window, move the pointer and check the cockpit`).

---

### Task 13: Docs, changelog, spec

**Files:**
- Modify: `docs/GNOME_CONFIGURATION_GUIDE.md`, `CHANGELOG.md`, `docs/superpowers/specs/2026-11-09-desktop-cockpit-design.md`
  (Status line), `scripts/test-resource-pulse.sh` (the claim)

- Guide: a **Drawing the cockpit** subsection after "The cockpit service": the monitor rule and the config's
  `monitor` block, the grid and groups, the four cards and what each row and tooltip shows, "take me there", the
  dropdown, ding off and `gdisable_extension`, the background lines, the watch and staleness rules in one paragraph,
  the lock screen, what a colleague without the file sees; remove "nothing is drawn yet" from the intro, the service
  section and the numbers table; "Trying changes in a nested shell" gains `window`, `pointer` and `check cockpit`;
  "What it costs" gains the in-shell reading for the cockpit; the checks claim updated.
- `CHANGELOG.md`: the drawing-side entry under Unreleased. Spec Status line: "data side built 2026-11-10 (#375);
  drawing side built <date> from `…drawing-side.md`".

- [ ] **Step 1–3:** write, `./scripts/check-claude-md.sh`, `scripts/check-doc-tokens.sh`, `pre-commit run --all-files`.
- [ ] **Step 4: Commit** (`Document the drawn cockpit`).

---

## After the last task (the controller, not an implementer)

1. The whole-branch review, one fix wave, the PR; CI green; squash-merge (never `--admin`); the
   `install.conf.yaml` diff, if any, shown to the owner first (this plan touches no link).
2. **The owner's steps, in order, only with his go-ahead:** ff-deploy `~/.dotfiles`; `./install`; add
   `gdisable_extension ding@rastersoft.com` and the two background `gset` lines to `~/.gnome-settings.local`;
   `gnome-apply`; log out and in once (the drawing code loads at login; ding's disable also applies then).
3. Verification from the spec: the background solid on both screens and the lock screen; Super+D reveals the cockpit
   on the 27"; each card agrees with `hreap`, `nmcli`, `vpn-doctor`, `findmnt` and Resources within rounding; hover
   shows tooltips; a row click focuses the pane and brings the terminal forward; covering a card freezes and dims
   it; 20 lock/unlock cycles, a dock and undock, overview in and out; `gnome-extensions info resource-pulse@dotfiles`
   says ACTIVE; the journal holds no `resource-pulse:` or `cockpit:` errors.
4. Cost: the in-shell reading (`scripts/resource-pulse-cost.sh --cpu-percent 600` for gnome-shell) under 0.1 %;
   the cockpit's watched reading with the cockpit revealed; gnome-shell RSS now and in 24 h through `rabota schedule
   add`.
5. Then stage two (Sol) gets its own design pass and mockup.
