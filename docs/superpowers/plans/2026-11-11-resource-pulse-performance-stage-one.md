# Resource Pulse performance, stage one: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut what the extension costs inside gnome-shell to the budgets of the performance design, with the same
look and the same numbers on screen, and no change to the service or to `ResourcePulse1`.

**Architecture:** The client stops using a `Gio.DBusProxy` (the object that makes GJS force a full collection
every 10 s) and takes Samples through a subscription on the shared connection. Nothing repeats on a timer: a
watchdog re-armed by each Sample replaces the stale check, and the cover re-check rides on Samples and window
signals. While only the top bar is seen a Sample is read for its two history values only; the top bar draws when
a column changes by a whole device pixel; the card is drawn through an offscreen texture.

**Tech Stack:** GJS under GNOME Shell 50 (St, Clutter, Meta, Gio), the repo's plain-gjs state table
(`gnome-shell/tests/*.test.js` + `scripts/test-resource-pulse.sh`), the nested shell harness
(`scripts/resource-pulse-nested.sh`), bash.

**Spec:** `docs/superpowers/specs/2026-11-10-resource-pulse-performance-design.md` (sections "Design" up to and
including "Stage one: drawing", "Budgets", "Testing and the measurement harness", "Ride-along items",
"Follow-ups"). It builds on `docs/superpowers/specs/2026-11-08-resource-pulse-service-design.md`. Stage two (the
compiled sampler) is not in this plan.

## Global Constraints

- The four deal-breakers are binding: desktop instability; wrong or laggy numbers; cost; upkeep.
- **No service-side change:** nothing under `service/`, no field of `ResourcePulse1`, no unit file. A deploy of
  this work restarts no service. *(Wrong as built: it restarts the sampler once. See the note under "After the
  last task".)*
- **No cockpit file is edited:** `lib/cockpit*.js`, `service/cockpit*.js`, `service/sources/`,
  `systemd/cockpit.service` and the cockpit plans stay as they are.
- **The shell does no file IO and starts no subprocess;** every D-Bus call is asynchronous with
  `DBUS_CALL_TIMEOUT_MS = 2000`. The static scan that forbids the blocking patterns keeps passing.
- **Nothing owned only by JavaScript is touched by C on a tick:** no `Gio.DBusProxy` in shell-side code.
- **No periodic timer in the shell while Samples flow.** The one repeating timeout allowed is the 10 s cover
  fallback, and it runs only while the service is silent and the card is covered.
- **No JavaScript in the paint path:** no `vfunc_paint`, no `vfunc_paint_node` in shell-side code.
- **A stale number is never drawn as live:** silence for `SAMPLE_STALL_TICKS` × `SAMPLE_INTERVAL_SECONDS` = 6 s
  shows "no data since HH:MM" on every surface, exactly 6 s after the last Sample.
- **The look does not change:** the same strings, the same colours, the same card width, ruling R21's dim and
  30 s frozen repaint. Stylesheet: classes are added, never renamed or removed.
- **Budgets** (the spec's "Budgets", nested method): covered and idle 0.08, covered and busy 0.20, visible 0.25,
  % of one core added by the extension; no forced collection the extension causes; no periodic timer; one frame a
  tick at most and none when no pixel changed. Counts gate a merge; percentages are reported.
- **Repo rules:** a new pure top-level file goes into `PURE_TOP_LEVEL_FILE_NAMES`
  (`gnome-shell/tests/imports.test.js`) and `PURE_MODULE_PATHS` (`scripts/test-resource-pulse.sh`);
  `EXPECTED_SHELL_CLOSURE` is an exact string and changes with every module the shell newly imports; the pinned
  counts of `BEFORE_REDRAW`, `get_laters().remove(` and `notify::width` per glue file change with the glue;
  "could not run" is exit 2, never a pass; `EXPECTED_ROWS` and the guide's "(N checks" claim move together, in
  the commit that changes the row count; a new static check ships with a planted-violation row; names explicit,
  units in the name, constants in `lib/constants.js`, Numpy-style JSDoc on every new function; commit messages in
  the imperative mood with the trailer `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- **Shell pitfalls:** `awk` is mawk and `grep` is a ugrep shim here: no GNU extensions, and never
  `2>/dev/null || true` around a check.
- **Nothing here changes the live session:** no `gsettings set`, no `gnome-extensions` enable or disable, no
  `./install`, no `systemctl --user` on either unit. The nested shell is the only place anything runs before the
  owner's deploy and login. Never read `/proc/*/cmdline` or `environ`; never `git stash`.

## Review Focus

Conditions the spec implies but no task's rows would otherwise exercise, most likely to bite first:

1. **A lock or a blank lands while a watchdog, a fallback timer, a subscription or a covering window's signal is
   live:** `disable()` leaves none of them, and a second `disable()` is harmless. Pinned in Task 5 (client) and
   Task 8 (extension).
2. **The service restarts while the subscription is dropped** (a fullscreen window for an hour): on return the
   client reads `GetState` from the new owner and draws its histories, never the old ones. Pinned in Task 6.
3. **The top bar is mapped again after a long time unmapped:** it draws once, from the current columns. Pinned in
   Task 7.
4. **A covering window is closed while its signals are connected:** no handler runs against it afterwards, and the
   cover is checked again at once. Pinned in Task 8.
5. **A reveal's Sample, whose `appendedHistory` is null, arrives while only the top bar is seen:** no column is
   appended, the top bar is not told, and the snapshot is still the latest when the card is next shown. Pinned in
   Task 4.

**Row totals.** `EXPECTED_ROWS` starts at 701. Each task says by how much the table's total must move. A total
that moves by any other amount means a row did not run or ran twice: find out which before changing the number.

---

## File structure

All under `gnome-shell/extensions/resource-pulse@dotfiles/` unless a path says otherwise.

- `serviceLink.js` (new, pure Gio): the service on the bus without a proxy: owner watch, Sample subscription,
  method calls.
- `pulseClient.js`: uses the link; two listener kinds; late snapshot parsing; the watchdog; the subscription
  dropped while nothing is wanted.
- `lib/protocol.js`: the Sample read in two steps (envelope now, snapshot when asked).
- `lib/topbarColumns.js` (new, pure): the top bar's columns in whole device pixels.
- `lib/visibility.js`, `lib/wiring.js`, `lib/constants.js`: the cover backstop and fallback decisions, the
  subscription decision, the new constants.
- `indicator.js`: draws on a column change and only while mapped; tells the client whether it is mapped.
- `card.js`: the offscreen redirect.
- `extension.js`: the cover check without its timer; covering windows' signals; the fallback while the service is
  silent.
- `gnome-shell/tests/`: `client.test.js`, `client-dbus.test.js`, `protocol.test.js`, `topbarColumns.test.js`
  (new), `visibility.test.js`, `wiring.test.js`, `imports.test.js`, `run.js`.
- `gnome-shell/tests/nested/replay-service.js` (new): fixed idle, light and busy input for the nested shell.
- `scripts/resource-pulse-nested.sh`, `scripts/resource-pulse-cost.sh`, `scripts/resource-pulse-module-closure.sh`,
  `scripts/test-resource-pulse.sh`, `zsh/functions/system.sh` (`gnome-status`).
- `docs/GNOME_CONFIGURATION_GUIDE.md`, `CHANGELOG.md`,
  `docs/superpowers/specs/2026-11-08-resource-pulse-service-design.md`.

---

### Task 1: Re-take the shipped baseline on current `main` (the controller, no code)

**Files:**
- Create: `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-11-stage-one/baseline.md` (outside the repo)

**Interfaces:**
- Consumes: the session tools in `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-10-performance-session/`
  (`make_harness.py`, `variants.py`, `run_experiment.sh`, `gc_layers.sh`; its `README.md` has the commands).
- Produces: the shipped figures on this `main`, which Task 14 compares against.

- [ ] **Step 1:** Build a harness copy of this checkout with the GC log on and the replay service
  (`make_harness.py <worktree> <dir>`, `touch <dir>/gc-log`, `variants.py <dir> replay`).
- [ ] **Step 2:** Run `NO_PROBE=1 bash run_experiment.sh <dir> scenarios <results> shipped` three times, one at a
  time, with nothing else running.
- [ ] **Step 3:** Record in `baseline.md`, per state, the three totals, their median, the main thread's median per
  tick and the major collections a minute. Expected: covered about 0.28, visible about 0.34, six collections a
  minute. A covered figure under 0.15 means the run did not measure the shipped code: stop and find out why.

---

### Task 2: The Sample read in two steps

**Files:**
- Modify: `lib/protocol.js`
- Test: `gnome-shell/tests/protocol.test.js`

**Interfaces:**
- Produces:
  - `parseSampleEnvelope(text) → {sequence: number|null, sampledAtUsec: number|null,
    appendedHistory: AppendedHistory|null, rawSnapshot: *}|null`: `JSON.parse`, then the three small fields read
    as `parseSamplePayload` reads them today; `rawSnapshot` is the payload's `snapshot` value untouched. Null for
    text that is not a JSON object.
  - `parseEnvelopeSnapshot(rawSnapshot) → Snapshot|null`: exactly what `parseSamplePayload(text).snapshot` is
    today for the same payload.
  - `parseSamplePayload(text)` keeps its result, now built from the two.

- [ ] **Step 1: Write the failing rows** in `protocol.test.js`:
  - `protocol: a Sample's envelope carries its sequence, time and appended history, and its snapshot unread`:
    for `buildSamplePayload({snapshot: S, appendedHistory: {cpu: 0.5, memory: 0.25}, sequence: 8, sampledAtUsec: T})`,
    `parseSampleEnvelope` gives `sequence 8`, `sampledAtUsec T`, `appendedHistory {cpu: 0.5, memory: 0.25}`, and
    `parseEnvelopeSnapshot(envelope.rawSnapshot)` deep-equals `parseSamplePayload(text).snapshot`.
  - `protocol: an envelope's appended history out of range is a gap, and a missing one is null` (`{cpu: 1.5}` →
    `{cpu: null, memory: null}`; no field → `null`).
  - `protocol: an envelope of text that is not a JSON object is null` (`'[]'`, `'nope'`, `42`).
  - `protocol: a raw snapshot that is not an object parses to null` (`null`, `7`, `[]`).
- [ ] **Step 2:** Run `gjs -m gnome-shell/tests/run.js 2>&1 | tail -3`. Expected: four failures naming
  `parseSampleEnvelope`.
- [ ] **Step 3:** Implement both functions and rebuild `parseSamplePayload` from them.
- [ ] **Step 4:** Run the same command. Expected: `JS-TALLY pass=<n> fail=0`.
- [ ] **Step 5:** The total moves by +4: `EXPECTED_ROWS` 701 → 705, and the guide's "(701 checks" → "(705 checks".
  Run `bash scripts/test-resource-pulse.sh | tail -3`. Expected: `705 passed, 0 failed`.
- [ ] **Step 6: Commit** (`Read a Sample's envelope and its snapshot in two steps`).

---

### Task 3: The client follows the service without a proxy

Behaviour is unchanged in this task: only what carries the owner, the Samples and the calls.

**Files:**
- Create: `serviceLink.js`
- Modify: `pulseClient.js`, `gnome-shell/tests/imports.test.js` (`PURE_TOP_LEVEL_FILE_NAMES`),
  `gnome-shell/tests/client.test.js`, `gnome-shell/tests/client-dbus.test.js`, `scripts/test-resource-pulse.sh`
  (`PURE_MODULE_PATHS`, `EXPECTED_SHELL_CLOSURE`, two static rows)

**Interfaces:**
- Produces:
  - `serviceLink.js`: `createResourcePulseLink(connection, {onOwnerChanged, onSample}) → ResourcePulseLink`.
    - `onOwnerChanged(owner: string|null)`: from `Gio.bus_watch_name_on_connection` (`BusNameWatcherFlags.NONE`),
      the unique name when the service appears, null when it vanishes.
    - `onSample(parameters: GLib.Variant)`: from `connection.signal_subscribe(RESOURCE_PULSE_BUS_NAME,
      RESOURCE_PULSE_INTERFACE_NAME, SAMPLE_SIGNAL_NAME, RESOURCE_PULSE_OBJECT_PATH, null, DBusSignalFlags.NONE, …)`.
    - `link.call(methodName, cancellable, onAnswered(error|null, reply|null))`: `connection.call` on the bus name,
      `NO_AUTO_START`, `DBUS_CALL_TIMEOUT_MS`.
    - `link.setSampleSubscribed(isSubscribed)` (subscribed from creation), `link.isSampleSubscribed`,
      `link.destroy()` (unwatch, unsubscribe; safe twice).
  - `PulseClient`: constructor option `createLink(connection, callbacks) → link` replaces `createProxy`. Every
    other public member is as before.

- [ ] **Step 1: Port the fixtures.** In `client.test.js` replace `FakeProxy` with `FakeLink` (`setNameOwner(owner)`
  calls `onOwnerChanged`; `emitSample(parameters)` calls `onSample` only while subscribed; `calls`, `callsOf`,
  `answer`, `fail`, `isSampleSubscribed`, `isDestroyed`). Port the existing rows to it without changing what they
  assert. Delete the one row for a D-Bus signal of another name (a subscription delivers only `Sample`), and say
  so in the commit message.
- [ ] **Step 2: Write the failing rows:** in `client-dbus.test.js`, on the private bus against the real service,
  `link: the owner appears, GetState answers, a Sample arrives, and after destroy() no callback is called`. In
  the table, with a planted twin: `no shell-side file names Gio.DBusProxy` and `a planted Gio.DBusProxy.new( in
  a shell-side copy is found`. "Shell-side" is every `.js` of the extension outside `service/`.
- [ ] **Step 3:** Run `gjs -m gnome-shell/tests/run.js 2>&1 | tail -3`,
  `dbus-run-session -- gjs -m gnome-shell/tests/run-private-bus.js 2>&1 | tail -3` and the table. Expected: the
  ported rows fail to import `createLink`'s fake, the link row fails, and the first static row fails.
- [ ] **Step 4:** Implement `serviceLink.js`, then swap the client over to it. `stringOfVariant` reads the
  Sample's one string as today; a wrong signature is still logged and dropped.
- [ ] **Step 5:** Register `serviceLink.js` in `PURE_TOP_LEVEL_FILE_NAMES` and `PURE_MODULE_PATHS`; update
  `EXPECTED_SHELL_CLOSURE` (it gains `serviceLink.js`).
- [ ] **Step 6:** Run all three commands. Expected: no failures. The total moves by +2 (−1 row deleted, +1 link
  row, +2 static rows): 705 → 707 in `EXPECTED_ROWS` and in the guide.
- [ ] **Step 7: Commit** (`Follow the service through a name watch and a subscription, not a proxy`).

---

### Task 4: Two kinds of listener, and the snapshot parsed when asked

**Files:**
- Modify: `pulseClient.js`
- Test: `gnome-shell/tests/client.test.js`

**Interfaces:**
- Consumes: Task 2's `parseSampleEnvelope`, `parseEnvelopeSnapshot`; Task 3's link.
- Produces, on `PulseClient`:
  - `addHistoryListener(callback: () => void) → id`, `removeHistoryListener(id)`: told after every Sample that
    appended to the histories, after a state, and on no data.
  - `addListener(callback(snapshot))` is the snapshot listener: told on a state, on no data, on every Sample while
    the detail watch is wanted, and once at the moment the watch becomes wanted.
  - `latestSnapshot`: parsed from the newest Sample when first read after it arrived, then kept.
    `lastGoodClockLabel` stays right without a read: going to no data parses the newest Sample first.
  - `get isLive(): boolean`: true while drawing Samples.

- [ ] **Step 1: Write the failing rows:**
  - `client: a history listener is told on every Sample; a snapshot listener only while the watch is wanted`
    (two Samples unwatched → history calls 2, snapshot calls 0 beyond the state's; watch wanted, one more Sample →
    history 3, snapshot 1 more).
  - `client: wanting the detail watch tells snapshot listeners the latest snapshot at once` (two unwatched
    Samples, then `setDetailWatchWanted(true)` → one snapshot call whose `cpuBusyPercent` is the second Sample's).
  - `client: latestSnapshot is parsed when first read, and is the newest Sample's` (after an unwatched Sample with
    `cpuBusyPercent: 50`, `client.latestSnapshot.cpuBusyPercent === 50`, and a second read is the same object).
  - `client: a reveal's Sample, with no appended history, tells no history listener and is still the latest
    snapshot` (Review Focus 5).
  - `client: no data is told to both kinds of listener, and names the last unread Sample's clock label` (two
    unwatched Samples labelled 14:03 and 14:04, then the owner vanishes → one call each, and
    `lastGoodClockLabel === '14:04'`).
  - `client: isLive is true while Samples are drawn and false with no data`.
- [ ] **Step 2:** Run the JS rows. Expected: the six fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the JS rows and the table. The total moves by +6: 707 → 713.
- [ ] **Step 5: Commit** (`Tell history and snapshot listeners apart, and parse a snapshot when it is read`).

---

### Task 5: One watchdog in place of the 2 s stale check (ride-along item 5)

**Files:**
- Modify: `pulseClient.js`, `lib/constants.js`
- Test: `gnome-shell/tests/client.test.js`

**Interfaces:**
- Produces:
  - `lib/constants.js`: `SAMPLE_STALL_MS = SAMPLE_STALL_TICKS * SAMPLE_INTERVAL_SECONDS * 1000` (6000).
  - The client's `timeouts` seam gains `addMilliseconds(intervalMs, callback) → id`.
  - Each Sample applied, and each fresh state, removes the pending watchdog and adds one of `SAMPLE_STALL_MS`.
    Firing publishes no data once and returns `GLib.SOURCE_REMOVE`. A state already older than the stall goes
    stale at once, as today, and arms nothing. The repeating `SAMPLE_INTERVAL_SECONDS` stale check is gone, so a
    hung service shows after exactly 6 s, where it took 6–9 s.

- [ ] **Step 1:** Give `FakeTimeouts` `addMilliseconds`, `pendingIntervalsMs()` and `fireMs(intervalMs)`.
- [ ] **Step 2: Write the failing rows:**
  - `client: while Samples flow the watchdog is the only pending timeout, at 6000 ms`
    (`pendingIntervalsSeconds()` is `[]` and `pendingIntervalsMs()` is `[6000]`, after the state and after each
    of two Samples).
  - `client: 6000 ms of silence publishes no data once; the next Sample draws again and re-arms the watchdog`.
  - `client: a state already older than the stall shows no data at once and arms no watchdog`.
  - `client: destroy() unsubscribes, destroys the link, and leaves no pending timeout`, and `destroy() twice is
    harmless` (Review Focus 1).
- [ ] **Step 3:** Run the JS rows. Expected: the new rows fail; the existing stale-check rows are rewritten to the
  watchdog (they assert the same outcomes) or removed where the new rows say the same thing.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Run the JS rows and the table. The total moves by +5 minus the stale-check rows removed in
  step 3; write both numbers in the commit message.
- [ ] **Step 6: Commit** (`Re-arm one watchdog on each Sample in place of the 2 s stale check`).

---

### Task 6: Nothing subscribed while nothing is wanted

**Files:**
- Modify: `pulseClient.js`, `lib/wiring.js`
- Test: `gnome-shell/tests/wiring.test.js`, `gnome-shell/tests/client.test.js`

**Interfaces:**
- Consumes: Task 3's link; Task 5's watchdog.
- Produces:
  - `lib/wiring.js`: `isSampleSubscriptionWanted({isHistoryWanted, isDetailWatchWanted}) → boolean` (either).
  - `PulseClient.setHistoryWanted(isWanted: boolean)`: the top bar is mapped. Starts true, so a client nobody
    tells behaves as before this task.
  - When the subscription stops being wanted: `link.setSampleSubscribed(false)`, the watchdog removed, the data
    state back to "awaiting state", and no "no data" published (nothing is seen). When it is wanted again and the
    service has an owner: subscribe, then `GetState`.

- [ ] **Step 1: Write the failing rows:**
  - `wiring: a Sample subscription is wanted while the top bar is mapped or a detail watch is wanted` (the four
    combinations).
  - `client: with neither wanted the subscription and the watchdog are dropped, silently` (after
    `setHistoryWanted(false)` unwatched: `isSampleSubscribed` false, no pending timeout, no listener call).
  - `client: wanting either again subscribes and reads GetState, whose histories replace the client's`.
  - `client: a service that restarted while unsubscribed is read afresh on return` (the owner changes while
    unsubscribed; on `setHistoryWanted(true)` the `GetState` goes to the new owner and its histories are drawn)
    (Review Focus 2).
  - `client: with no owner, wanting the subscription subscribes and waits; the owner appearing reads GetState`.
- [ ] **Step 2:** Run the JS rows. Expected: the five fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the JS rows and the table. The total moves by +5.
- [ ] **Step 5: Commit** (`Drop the Sample subscription while nothing is seen`).

---

### Task 7: The top bar draws on a column change, and only while mapped

**Files:**
- Create: `lib/topbarColumns.js`, `gnome-shell/tests/topbarColumns.test.js`
- Modify: `indicator.js`, `gnome-shell/tests/run.js`, `scripts/test-resource-pulse.sh` (`EXPECTED_SHELL_CLOSURE`,
  text-read rows)

**Interfaces:**
- Consumes: Task 4's `addHistoryListener`; Task 6's `setHistoryWanted`.
- Produces:
  - `lib/topbarColumns.js`:
    - `GAP_COLUMN = -1`.
    - `quantisedColumns(slotFractions, heightPx, resourceScale) → number[]`: per slot,
      `Math.ceil(clamp01(fraction) * heightPx * Math.ceil(resourceScale))`, `GAP_COLUMN` for a gap. `ceil` so any
      non-zero value shows one pixel and an idle CPU stays inside one level.
    - `areColumnsEqual(first, second) → boolean`: false when either is null or the lengths differ.
    - `columnFractions(columns, heightPx, resourceScale) → Array<number|null>`: each level back as a fraction of
      the graph's height, a gap as null: what the painter draws, so what is compared is what is drawn.
  - `PulseIndicator`: listens with `addHistoryListener`; for each graph computes the columns of its newest
    `TOPBAR_HISTORY_SAMPLES` and calls `queue_repaint()` only when they differ from the ones last drawn and the
    indicator is mapped; unmapped, it records that a repaint is owed and draws once on `notify::mapped`. It calls
    `client.setHistoryWanted(this.mapped)` on `notify::mapped` and once at construction. `_paintGraph` draws
    `columnFractions(...)` of the columns it recorded. The hover label reads `client.latestSnapshot` on each tick
    while shown, as today.

- [ ] **Step 1: Write the failing rows** in `topbarColumns.test.js` (registered in `run.js`):
  - `columns: a value inside one pixel does not change its column` (height 16, scale 1: 0.01 and 0.06 → 1 and 1;
    0.07 → 2).
  - `columns: zero is 0, any other value at least 1, a gap is GAP_COLUMN, and values outside 0–1 are clamped`.
  - `columns: a fractional scale counts whole device pixels` (height 16, scale 1.25 → 32 levels; 0.5 → 16).
  - `columns: equal only when both exist, have one length and match slot for slot`.
  - `columns: the fractions drawn are the columns' own` (`columnFractions(quantisedColumns(f, 16, 1), 16, 1)` for
    `[0.5, null, 0.06]` is `[0.5, null, 0.0625]`).
- [ ] **Step 2:** Run the JS rows. Expected: the five fail.
- [ ] **Step 3:** Implement `lib/topbarColumns.js`, then the indicator.
- [ ] **Step 4: Text-read rows** in the table (the glue cannot run under plain gjs), each with a planted twin on a
  copy (`RESOURCE_PULSE_EXT_DIR`): `indicator.js calls queue_repaint( in one place, behind the column
  comparison`; `indicator.js connects notify::mapped and passes this.mapped to setHistoryWanted`. Update
  `EXPECTED_SHELL_CLOSURE` (it gains `lib/topbarColumns.js`).
- [ ] **Step 5:** Run the JS rows and the table. The total moves by +9.
- [ ] **Step 6: Nested check** (the controller): `scripts/resource-pulse-nested.sh start`; with `eval`, count
  the two graphs' `repaint` emissions over 30 s with the indicator shown and over 30 s after `_indicator.hide()`,
  then `show()`. Expected: none while hidden, one each on `show()` (Review Focus 3); the extension's state 1
  (ACTIVE) and no `resource-pulse:` line in `log/shell.log`. `stop`.
- [ ] **Step 7: Commit** (`Draw the top bar only when a column changes, and only while mapped`).

---

### Task 8: The cover check without a timer (ride-along item 2)

**Files:**
- Modify: `extension.js`, `lib/visibility.js`, `lib/constants.js`, `scripts/test-resource-pulse.sh`
- Test: `gnome-shell/tests/visibility.test.js`

**Interfaces:**
- Consumes: Task 4's `addHistoryListener`, `isLive`, `latestSnapshot`; `card.update`, `card.repaintFrozen`,
  `card.setFrozen`.
- Produces:
  - `lib/constants.js`: `COVER_BACKSTOP_TICKS = 15` (30 s of Samples, R21's repaint interval);
    `COVER_FALLBACK_INTERVAL_SECONDS = 10`.
  - `lib/visibility.js`:
    - `isCoverBackstopDue({isCovered, ticksSinceCoverCheck}) → boolean`: true on every tick while the card is
      visible; while covered, true from `COVER_BACKSTOP_TICKS` on.
    - `CoverFallbackTimerChange = {START, STOP, NONE}` and
      `coverFallbackTimerChange({isCovered, isServiceLive, isTimerRunning})`: `START` when covered, not live and
      not running; `STOP` when running and (visible or live); else `NONE`.
    - `coverRecheckTimerChange` and `CoverRecheckTimerChange` are removed with their rows.
  - `extension.js`: one history listener counts ticks and runs `_syncCardCover()` when `isCoverBackstopDue`; a
    covered card's backstop also makes the frozen repaint (`card.update(client.latestSnapshot,
    client.lastGoodClockLabel)` then `repaintFrozen()`, behind `isFrozenRepaintDue` as today). The windows that
    cover the card have `position-changed` and `size-changed` connected with `connectObject(..., this)`, replaced
    whenever the covering set changes, each queuing the coalesced cover check. The fallback timeout
    (`timeout_add_seconds`, `COVER_FALLBACK_INTERVAL_SECONDS`) runs exactly while `coverFallbackTimerChange` says
    so. The header comment describes this, and no longer says a 2 s timer runs or that it schedules no frame.

- [ ] **Step 1: Write the failing rows** in `visibility.test.js`:
  - `visibility: the cover is checked on every tick while the card is visible` (`{isCovered: false,
    ticksSinceCoverCheck: 0}` → true).
  - `visibility: a covered card is checked again from the fifteenth tick, not before` (14 → false, 15 → true,
    16 → true).
  - `visibility: the fallback timer starts for a covered card whose service is silent`, `stops when the service
    is live again or the card is revealed`, and `changes nothing otherwise` (the eight combinations between
    them).
- [ ] **Step 2:** Run the JS rows. Expected: the five fail. Remove the rows that name `coverRecheckTimerChange`,
  counting them.
- [ ] **Step 3:** Implement the pure functions, then `extension.js`.
- [ ] **Step 4: Static and text-read rows** in the table: with a planted twin, `no shell-side file adds a timeout
  of SAMPLE_INTERVAL_SECONDS` and `a planted one is found`; `extension.js's one timeout_add_seconds uses
  COVER_FALLBACK_INTERVAL_SECONDS`; `_tearDown removes the fallback timeout and disconnects the covering windows`
  (the step names in `runEveryStep`). Update the pinned counts the glue changes.
- [ ] **Step 5:** Run the JS rows and the table. The total moves by +9 minus the rows removed in step 2; write
  both numbers in the commit message.
- [ ] **Step 6: Nested check** (the controller), with a real window (`gnome-calculator`, started as the session's
  `matrix.sh` starts it): maximize it → `_card._repaintPlanner.isFrozen` true and the detail watch released;
  `Meta.Window.move_resize_frame` it off the card from `eval` → the card unfreezes within one frame, with no
  Sample needed; close it while it covers the card → the card unfreezes, and `log/shell.log` holds no error
  (Review Focus 4); disable and enable the extension twice while it is covered → state 1 and no error
  (Review Focus 1).
- [ ] **Step 7: Commit** (`Check the card's cover on Samples and window signals, with no timer`).

---

### Task 9: The card through an offscreen texture; no JavaScript in paint

**Files:**
- Modify: `card.js`, `scripts/test-resource-pulse.sh`

**Interfaces:**
- Produces: `PulseCard` sets `Clutter.OffscreenRedirect.ALWAYS` on itself at construction (the desktop card and
  the dropdown's card alike). Nothing else about the card changes.

- [ ] **Step 1: Rows** in the table, each with its planted twin: `card.js sets the offscreen redirect to ALWAYS
  in _init`; `no shell-side file overrides vfunc_paint or vfunc_paint_node`.
- [ ] **Step 2:** Run the table. Expected: the first fails; the second passes already and its twin proves it can
  fail.
- [ ] **Step 3:** Implement (one call).
- [ ] **Step 4:** Run the table. The total moves by +4.
- [ ] **Step 5: Nested check** (the controller): the session's `redirect_sharpness.sh` against this checkout's
  harness copy at scale 1.333: the card captured with the redirect off (`set_offscreen_redirect(0)` from `eval`)
  and on differs by more than 16 of 255 in fewer than 50 pixels. And `busy_redirect.sh`: the covered card under
  the 60 fps window reads within 0.3 of "card hidden".
- [ ] **Step 6: Commit** (`Draw the card through an offscreen texture`).

---

### Task 10: The harness can log collections and replay fixed input

**Files:**
- Create: `gnome-shell/tests/nested/replay-service.js`
- Modify: `scripts/resource-pulse-nested.sh`, `scripts/test-resource-pulse.sh`,
  `gnome-shell/tests/nestedHarness.test.js`

**Interfaces:**
- Produces:
  - `scripts/resource-pulse-nested.sh start [--gc-log] [--replay]`:
    - `--gc-log` adds exactly `JS_GC_PROFILE=0` and `JS_GC_PROFILE_NURSERY=0` to the nested gnome-shell's
      environment and records `gc-log=1` in `state/run.values`;
    - `--replay` starts `replay-service.js` on the private bus in place of the extension's `service/main.js` and
      records `replay=1`.
  - `scripts/resource-pulse-nested.sh scenario <idle|light|busy>`: writes the word to
    `<run dir>/run/rp-scenario` of a live `--replay` run; exit 2 for any other word or run.
  - `replay-service.js <extension dir>`: owns `RESOURCE_PULSE_BUS_NAME`, answers `GetState`, accepts
    `WatchDetail` and `UnwatchDetail`, and every `SAMPLE_INTERVAL_SECONDS` publishes a Sample from a seeded
    generator: `idle` CPU 1–4%, `light` 2–14%, `busy` a walk between 15% and 90%. A changed word refills both
    histories and restarts the sequence. It reads no `/proc` and no cgroup file. Port it from the session's
    `spike/replayService.js`, without the pixel signal and the samples-when-watched switch.

- [ ] **Step 1: Write the failing rows:** usage lists `--gc-log`, `--replay` and `scenario`; the nested
  environment has exactly the two GC variables with `--gc-log` and neither without (extend the
  `unexpected_env_names` rows); `scenario` refuses a word outside the three, a run without `replay=1` and a run
  that is not live, each exit 2; the stub-driven start rows show `replay-service.js` started with `--replay` and
  `service/main.js` without. In `nestedHarness.test.js`: the replay generator's first ten `idle` values lie in
  1–4, `light` in 2–14, `busy` in 15–90, and two runs give the same sequence.
- [ ] **Step 2:** Run the table and the JS rows. Expected: the new rows fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run both. The total moves by the rows step 1 added; write the number in the commit message.
- [ ] **Step 5: Nested check** (the controller): `start --gc-log --replay`; `scenario idle`; after 30 s
  `log/shell.log` holds `MajorGC:` lines and the card shows a CPU figure between 1% and 4%; `stop`.
- [ ] **Step 6: Commit** (`Let the nested harness log collections and replay fixed input`).

---

### Task 11: A `perf` request that asserts the count budgets

**Files:**
- Modify: `scripts/resource-pulse-nested.sh`, `scripts/resource-pulse-cost.sh`, `scripts/test-resource-pulse.sh`

**Interfaces:**
- Consumes: Task 10's `--gc-log`, `--replay`, `scenario`.
- Produces:
  - `scripts/resource-pulse-cost.sh`: CPU from the scheduler's nanosecond counters
    (`<proc>/<pid>/task/*/schedstat`, first field, summed) in place of `stat`'s ticks, for gnome-shell and for
    `--service` and `--cockpit` alike; and `--tick-median <seconds>`: the median of the main thread's CPU per 2 s
    tick over the window, in ms. `GNOME_SHELL_PID` and `PROC_ROOT` as today.
  - `scripts/resource-pulse-nested.sh perf`: needs a live run started with `--gc-log --replay` (else exit 2) and
    `gnome-calculator` (else exit 2). It opens one window, then for each state waits 40 s once and measures 60 s:
    disabled; covered and idle; covered and busy; top bar hidden and covered; visible and busy. It prints, per
    state, the CPU % (reported), the median per tick, the major collections, the frames, and the top bar's paints;
    and exits 1 when a count budget is broken:
    - major collections in an enabled state exceed the disabled state's by more than one;
    - frames exceed Samples by more than two in any state;
    - frames exceed three in the covered, idle state;
    - a top-bar paint happens while the top bar is hidden;
    - the card's `get_offscreen_redirect()` is not `ALWAYS`.

- [ ] **Step 1: Write the failing rows:** the cost script against a fake proc tree with two threads'
  `schedstat` (`4000000 0 1` and `6000000 0 1` before, each 5 ms later after) reports the right percent for the
  window; `--tick-median` of a scripted series; a missing `schedstat` is exit 2, never 0%; `perf` without a live
  run, without `gc-log=1`, without `replay=1` and without `gnome-calculator` on `PATH` is exit 2 each; `perf`'s
  verdict function (pure bash, called by the rows with scripted counts) gives 0 for counts inside the budgets and
  1 for each of the five breaches, naming it.
- [ ] **Step 2:** Run the table. Expected: the new rows fail.
- [ ] **Step 3:** Implement. The in-shell counters come from one `eval`'d probe, as the session's `probe.js`
  does; the windows are not measured while an `eval` runs.
- [ ] **Step 4:** Run the table. The total moves by the rows step 1 added; write the number in the commit message.
- [ ] **Step 5: Nested check** (the controller): `start --gc-log --replay` then `perf` on this branch. Expected:
  exit 0, and the reported figures inside the spec's budgets (covered and idle 0.08, covered and busy 0.20,
  visible 0.25, after subtracting the disabled state). Then check out `main`'s extension into a harness copy and
  run the same: expected exit 1, naming the collections.
- [ ] **Step 6: Commit** (`Add a perf request that asserts the count budgets, and read CPU in nanoseconds`).

---

### Task 12: Ride-along 1 and 3: the closure helper and the row titles

**Files:**
- Modify: `scripts/resource-pulse-module-closure.sh`, `scripts/test-resource-pulse.sh`

**Interfaces:**
- Produces: the helper follows an import that comes after a block comment closed on the same line
  (`/* note */ import {a} from './a.js';`). A line that is all comment is still skipped. Its header comment says
  so.

- [ ] **Step 1: Write the failing row:** `closure: an import after a block comment closed on its own line is
  followed` (a fixture module whose only import is written that way; the closure names the imported file), and
  `closure: a block comment that does not close on its line still hides the line`.
- [ ] **Step 2:** Run the table. Expected: the first fails.
- [ ] **Step 3:** Implement (strip a leading `/* … */` before the comment-line test).
- [ ] **Step 4: Row titles.** Reword every `check` title that still says a change "under service/ or lib/" where
  the rule is the unit's import closure (today the two `refresh:` rows near the phrase; find them with
  `grep -n 'service/ or lib/' scripts/test-resource-pulse.sh`, and leave the stat-only rows, whose rule is about
  those directories).
- [ ] **Step 5:** Run the table. The total moves by +2.
- [ ] **Step 6: Commit** (`Follow an import after a same-line block comment; reword two row titles`).

---

### Task 13: Ride-along 4: `gnome-status` and a newer unit file

**Files:**
- Modify: `zsh/functions/system.sh` (`rp_warn_when_unit_runs_older_code`), `scripts/test-resource-pulse.sh`,
  `CHANGELOG.md`

**Interfaces:**
- Produces: `gnome-status` also warns when the unit's own file (`systemd/<unit>`, through the link in the user's
  unit directory) changed after the active unit started: `"<unit> runs an older unit file: it changed after the
  unit started — systemctl --user daemon-reload && systemctl --user try-restart <unit>"`. It stays silent for a
  unit that is not running, as the older-code ⚠ does. The CHANGELOG's ⚠ list for `gnome-status` names the
  "cannot tell" ⚠ and says both older-code ⚠s are suppressed for a unit that is not running.

- [ ] **Step 1: Write the failing rows** with the existing `gnome_status_run` stubs: a unit file newer than the
  unit's start gives one ⚠ naming the remedy; an older one gives none; a unit that is not active gives none.
- [ ] **Step 2:** Run the table. Expected: the first fails.
- [ ] **Step 3:** Implement, for both units the function already serves.
- [ ] **Step 4:** Amend the CHANGELOG as above; run the table. The total moves by +3.
- [ ] **Step 5: Commit** (`Warn in gnome-status when a unit runs an older unit file`).

---

### Task 14: Docs, and the measurements that close the work (the controller)

**Files:**
- Modify: `docs/GNOME_CONFIGURATION_GUIDE.md` ("What it costs", "Tests"), `CHANGELOG.md`,
  `docs/superpowers/specs/2026-11-08-resource-pulse-service-design.md` (its budget table points to the
  performance design), `docs/superpowers/specs/2026-11-10-resource-pulse-performance-design.md` (status)

- [ ] **Step 1:** The guide's "What it costs" takes the spec's budget table and its method (the nested `perf`
  request, three windows, the median, counts gate and percentages are reported), and names the performance
  design. The v2 design's budget table gains one line pointing to it. `CHANGELOG.md` gains the entry.
- [ ] **Step 2:** Run `bash scripts/test-resource-pulse.sh | tail -3`, `pre-commit run --all-files` and
  `./scripts/check-claude-md.sh`. Expected: all pass, and the table's total equals `EXPECTED_ROWS`.
- [ ] **Step 3:** Repeat Task 1's three runs on this branch (`replay` only, no other variant), and
  `scripts/resource-pulse-nested.sh perf` three times. Record the medians beside Task 1's in
  `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-11-stage-one/result.md`. Expected: each state at or
  under its budget, `perf` exit 0 each time. A median more than 0.05 over its budget goes to the owner before
  merging.
- [ ] **Step 4:** Commit (`Document the performance budgets and how they are measured`), then open the pull
  request. Its description lists the spec's "Follow-ups" 1 to 8 as open, word for word, and the before and after
  medians.

## After the last task (the controller, not an implementer)

1. A whole-branch review, then the merge and the fast-forward deploy under the owner's standing rule (squash,
   never `--admin`; surface red CI). The deploy restarts no service: nothing under `service/` changed.
   *Wrong, found by the whole-branch review: the deploy restarts the sampler once, because two shared
   modules it loads changed. See the design's "Stage one as built".*
2. The drawing side takes effect at the owner's next login. After it: `gnome-status` shows no older-copy ⚠;
   `scripts/resource-pulse-cost.sh --tick-median 120` on the live shell with the card covered.
3. The second live reading, with the owner's word and while he is away, using the session's
   `live/live_reading.sh`. It must show no burst every 10 s on the main thread's series, and a smaller difference
   between enabled and disabled than finding 12's.
4. The 24 h memory check for gnome-shell, scheduled with `rabota schedule add` as v2's was.
5. Hand the cockpit session `~/Projects/handoffs/2026-11-10-cockpit-drawing-plan-amendments.md` through the owner,
   if he has not already.
6. Stage two's design starts from the spec's "Stage two" section.
