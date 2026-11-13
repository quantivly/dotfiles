# Resource Pulse stage two: a compiled sampler

**Status:** approved by the owner on 2026-11-13. Proposed 2026-11-12 and revised 2026-11-13. Nothing is
built. The plan for its first two pull requests:
[2026-11-13-resource-pulse-compiled-sampler.md](../plans/2026-11-13-resource-pulse-compiled-sampler.md).
**Read twice before it reached him:** a builder check (seven points) and an independent review ("sound with
changes": no critical finding, eight important, twelve minor). Both are folded in and marked under "My calls".
The review's report: `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-12-stage-two/design-review/`.
**Builds on** [2026-11-10-resource-pulse-performance-design.md](2026-11-10-resource-pulse-performance-design.md)
(the performance design: its "Stage two" section, finding 13 and follow-ups 7, 8, 9, 11 and 12),
[2026-11-08-resource-pulse-service-design.md](2026-11-08-resource-pulse-service-design.md) (v2) and
[2026-11-09-desktop-cockpit-design.md](2026-11-09-desktop-cockpit-design.md) (the cockpit). Where this document
reopens a decision of theirs it says so; everything it does not mention stands. It is written against the
`main` that has the cockpit's drawing side (#382).

## Summary

- **The sampler service becomes a Rust program.** The same reads, the same definitions, the same
  `ResourcePulse1` on the bus. The extension does not change for it, and no login is needed.
- **What it is worth is the service, all day.** Side by side on the loaded machine, twice, the gjs sampler read
  0.207 and 0.122 % of one core where a Rust spike doing the same reads on D-Bus read 0.055 and 0.087. The gjs
  unit is charged 16.6 MiB; the spike's private memory was 1.3 MiB. So the machine gets back about 0.04 to
  0.15 % of one core and about 15 MiB.
- **It does not lower what the extension costs inside the shell on a busy machine.** That is the frame each
  Sample draws and the stock shell's own collections. The owner has accepted that cost (follow-up 11).
- **One message is added afterwards:** a slow signal every 30 s, which the extension listens to in place of the
  2 s one while a fullscreen window hides the top bar and every card. That closes follow-up 9.
- **The gjs sampler is deleted,** once the Rust one has proved equal on the fixtures and has run live for a day.
  There is one sampler at the end, not two. Its D-Bus face stays, as the one test double.
- **It lands as five pull requests:** a one-line change to today's sampler; the program, unused; the switch;
  the deletion; the slow signal.
- **The two points the review left to the owner are decided:** a missing program is a failed unit, and the
  watchdog is 120 s.

## Why

The owner's priority for this stage: "The priority is to have a minimal footprint and optimal performance and
UX." Stage one took the extension's own cost down. End to end, the service is now the larger half (finding 13):
three quarters of the gjs sampler's cycles are its runtime, not its work.

## Decided by the owner

On 2026-11-11:

1. **Stage two is wanted, in Rust,** as its own design and plan after stage one.

On 2026-11-12, each asked once:

2. **The messages:** port first with `ResourcePulse1` as it is. Then one slow signal for the state where
   nothing of Resource Pulse is visible. That closes follow-up 9, and it settles the build's ruling that the
   Sample subscription is not dropped while a covered card must stay fresh.
3. **The on-change top-bar signal is held** until a live reading at rest shows what it would win. "Approaches"
   says why.
4. **The cockpit service is not part of this design.** The Rust code leaves room for a cockpit program to join
   later.
5. **The live cost is accepted** (follow-up 11): no code change, and the top bar keeps moving every 2 s.
6. **A live reading on the machine at rest, wired and charged:** yes, on his word.
7. **The stock shell's own collections are reported upstream** (follow-up 12): drafted for him to file, after
   this design merges.
8. **A machine without cargo gets no sampler.** In his words, "1 for now, but potentially 3 if it proves itself
   useful": Rust only, with no gjs fallback; a prebuilt binary from CI is a possible later step.

On 2026-11-13, after the independent review ("As recommended to both. Approved."):

9. **A missing program is a failed unit,** not a skipped one. "The two choices the review left" has both
   options.
10. **The watchdog is 120 s.**
11. **This document is approved.**

## The two choices the review left

The independent review marked these two as choices, not corrections. The owner took the recommended option
of each (decisions 9 and 10); the others are kept here for the record.

1. **What a missing program looks like: a failed unit, or a skipped one.** The program is missing on a machine
   without cargo, and on this one after a first `./install` offline or a cleaned `~/.local/lib`.
   - *Failed (chosen).* The unit has no condition. Its start fails, the start limit parks it in `failed`,
     and it shows in `systemctl --user --failed` and in `verify-tools.sh`. The extension does not change.
   - *Skipped.* `ConditionPathExists=` on the program. A skipped start is a success to systemd, so nothing is
     failed anywhere, and the refresh step's restart prints its green tick with nothing running. To be honest
     it needs the extension to read the unit's condition, as the cockpit's client does: an extension change,
     and a login.
   - *Why failed:* "not built" is a fault for someone who opted in, and this repository's own rule says a
     skipped unit reads as healthy. For the cockpit, "not configured" is a normal state; here it is not.
2. **The watchdog: 120 s, 30 s, or none.**
   - *120 s (chosen).* A hung sampler is restarted by systemd. Nobody sees the difference from 30 s: the
     extension shows "no data" after 6 s either way.
   - *30 s.* The same, with a quarter of the margin against killing a healthy sampler. Around a suspend,
     systemd freezes the user's whole session, user manager included, and the watchdog's clock keeps running
     while the machine is frozen but still awake.
   - *None.* As today: a hung sampler stays hung until someone restarts it. Nothing on record says the gjs
     sampler ever hung.
   - *Why 120 s:* it keeps the goal at no visible cost. This laptop's journal has 18 suspends in the last 30
     days and none since 2026-10-28, so the false kill is unlikely here, and the short limit buys nothing.

## Goals, non-goals, anti-goals

- **Goals:**
  - the same numbers and names on the bus as the gjs sampler gives for the same input;
  - the service inside the budgets below, measured;
  - the port live with no login;
  - a hung sampler restarted by systemd, not noticed by a person;
  - almost nothing spent in the shell while nothing of Resource Pulse is visible;
  - one sampler to keep.
- **Non-goals:**
  - the cockpit service in Rust;
  - a Sample sent only when the top bar would change;
  - the top bar rendered to pixels by the service;
  - faster reveal (follow-up 4 of the performance design);
  - prebuilt binaries;
  - histories that survive a restart of the service.
- **Anti-goals:**
  - a number or a name that differs from the gjs sampler's with nobody having decided it;
  - two samplers kept in step for good;
  - a build, a test or a deploy step that touches the live session bus or swaps a running program's file;
  - a second copy of the program taking the bus name from the running one;
  - a sampler that is missing while nothing anywhere says failed;
  - a crash where the gjs sampler would have shown "no data" for one field;
  - a deploy that restarts the sampler when the sampler did not change;
  - a stale number drawn as live, in the new slow state as everywhere else.

## Constraints

- **The four deal-breakers,** all binding: desktop instability, wrong or laggy numbers, cost, upkeep.
- **The live desktop is the owner's.** Every check in this design runs on a private bus or reads `/proc` and
  `/sys`. The two that need the live session are named under "Live checks", and each waits for his word.
- **The cockpit's drawing side is on `main`** since 2026-11-13 (#382), so nothing here waits for another
  branch. It rewrote `scripts/test-resource-pulse.sh` (1,213 rows now), `scripts/resource-pulse-nested.sh`,
  `serviceLink.js`, `pulseClient.js`, `lib/constants.js` and the guide. It did not touch `service/main.js`,
  `service/sampler.js`, `service/dbusService.js`, the sampler's unit, `install.conf.yaml`, the refresh script
  or CI. It is deployed, and loaded since the owner's login of 2026-11-13.
- **Version skew stays additive** within `ResourcePulse1`, as v2 set it.
- **House rules:** every new guard ships with a state table that asserts its own row total and a mutation
  sweep; `grep` here is ugrep and `awk` is mawk; CI installs through `.github/actions/apt-install`; builds
  and tests run under the worker caps of `zsh/zshrc.buildlimits`.

## Measured for this design (2026-11-12)

A throwaway spike, on a private bus: the reads of the performance design's Rust floor (the fast tick every 2 s,
a scan of every leaf every 20 s as if watched), with a Sample of real size (2.2 kB) sent each tick and the three
methods served. One program per library, run side by side with the floor for 120 s, twice. The machine was at a
load of 3.5 to 6.8.

| | CPU, % of one core | Resident | Private | Threads | Binary | Crates compiled in | Last release |
|---|---|---|---|---|---|---|---|
| Floor: the reads, no D-Bus | 0.054, 0.074 | 2.3 MiB | 0.5 MiB | 1 | 0.37 MB | 0 | — |
| `zbus` 6.2.1, with its object server | 0.055, 0.087 | 3.3 MiB | 1.3 MiB | 2 | 1.18 MB | 27 | 2026-11-01 |
| `rustbus` 0.19.3 | 0.050, 0.082 | 2.5 MiB | 0.6 MiB | 1 | 0.49 MB | 15 | 2023-08-29 |
| The live gjs sampler, same windows | 0.207, 0.122 | 30.5 MiB | 15.5 MiB | 12 | — | — | — |
| `zbus` 6.3.0 as this design uses it, measured in the build: the bus layer alone, no reads (its Sample is about 20 bytes, not the spike's 2.2 kB, so do not compare its figure with the spike's rows) | 0.008, 0.007 | 3.3 MiB | 1.3 MiB | 3 | 1.28 MB | 27 | 2026-11-13 |

- **D-Bus costs nothing that can be measured in CPU.** Both libraries read the same as the floor; the two runs
  differ from each other by more than the libraries do.
- **The spike's `zbus` row is not the configuration this design uses.** The spike declared the interface to
  `zbus`'s object server, which answers calls on the library's own thread. The design answers them on the
  sampling thread, with no object server ("The program"). The table's last row is that configuration,
  measured in the build on 2026-11-13.
- **The library is final: `zbus`.** Both orders held three runs in a row. The reply order was checked over
  about 8,000 state replies and 500 Samples a run at 20 ms ticks, and each row or test was seen failing under a
  change that breaks its rule. Used this way the program has three threads, not two (one of its own only
  receives), holds 3.3 MiB, and its bus layer is 301 lines of code. The build locked version 6.3.0,
  released after the spike; the two versions do not differ in anything the four rules rest on. Record:
  `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-12-stage-two/library-decision/result.md`.
- **The live sampler's memory:** 30.5 MiB resident counts shared library pages. Its unit is charged 16.6 MiB.
  Its two CPU figures differ because its watch state differed; it was not read.
- **A libdbus binding was not built:** the C headers are not installed here, and needing them is the cost the
  performance design already named.

The floor's cost by cadence: three copies side by side for 180 s, at a load of 5.

| The floor with | CPU, % of one core | Each |
|---|---|---|
| The fast tick only | 0.011 | 0.21 ms a tick |
| A scan every 60 s, as with no watch | 0.022 | 6.6 ms a scan |
| A scan every 20 s, as with a watch held | 0.042 | 6.2 ms a scan |

- **A scan is about 6 ms and a tick about 0.2 ms.** Five scans a minute, the burst rate finding 13 measured,
  would then be about 0.065 %: inside the watched budget.

Sources and raw output: `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-12-stage-two/dbus-spike/`.

## Approaches

### How far the messages change

1. **Port only.** `ResourcePulse1` untouched, the extension untouched. Follow-up 9 stays open: under a
   fullscreen window the shell still handles a Sample every 2 s (0.068 % added, nested).
2. **Port, then a slow signal for the nothing-visible state.** One added signal, one added field, and a
   subscription the client swaps. **Chosen by the owner.**
3. **Port, the slow signal, and a Sample only when the top bar would change.** Weighed and held:
   - *What it wins:* at most about 0.1 % of one core, and only while the top bar's whole 60 s window is flat to
     the pixel. The graph scrolls, so any change in the last minute redraws it on every tick. With agents
     running, that is most of the day (finding 8: the CPU graph changed on 120 of 120 ticks).
   - *What it needs:* the shell telling the service the graph's height in device pixels; a new path for the
     hover label, which shows numbers from every Sample; a new stall rule, since silence would be normal; and
     the cockpit's rule that a `Changed` is applied on the next Sample would lose its 2 s tick.
   - *What would reopen it:* the live reading at rest (decision 6). It measures the state this would improve.

### The D-Bus library

This design answers calls on the sampling thread ("The program" says why). Used that way, either library
leaves the same things to write by hand: telling the three methods apart, the introspection text, and an
error for a call it does not know. So the choice is narrower than the first draft made it.

1. **`zbus`.** Maintained: four releases in the last month. Against it: a helper thread, about 0.8 MiB and 12
   crates more than `rustbus`, a major version four weeks old, and a 0.x runtime crate under it. **Chosen
   (my call), on condition:** the plan's first task proves the two orders it must hold and measures it as
   used. *The condition was met on 2026-11-13: "Measured for this design".*
2. **`rustbus`.** One thread, the smallest footprint, and a loop that holds the order by construction. Not
   chosen: no release since 2023, built on a 2022 `nix`. If `zbus` fails the first task, this is the
   fallback, and the upkeep of an unreleased library becomes ours knowingly.
3. **A libdbus binding.** Needs C headers and a C library at build time, and gives up some of the safety.
4. **The wire protocol by hand.** No dependency at all, and several hundred lines of protocol code that would be
   ours to keep correct. Not chosen: the fourth deal-breaker.

### How the switch happens

1. **One pull request:** the program, the unit and the deletion together. Not chosen: a wrong number would
   reach the desktop with nothing to compare it against and nothing to go back to.
2. **Both samplers kept, chosen per machine.** Not chosen: decision 8, and two programs to keep equal.
3. **Separate pull requests:** one change to today's sampler, then the program unused, then the switch, then
   the deletion, then the slow signal. **Chosen (my call).** "Order of work" has the gates.

### How "the same numbers" is proved

1. **Byte-for-byte JSON,** as the performance design said. Not chosen: JavaScript and Rust print the same
   double differently (`12` against `12.0`, `1e-7` against `0.0000001`), and the client parses, it does not
   compare text.
2. **A live comparison only.** Not chosen: two programs sampling at different instants never agree exactly,
   so it cannot prove a definition.
3. **Golden files from the gjs sampler, compared as parsed values; every existing row carried over; a live
   shadow run for what fixtures cannot hold.** **Chosen (my call).**

## Design

### The program

- **Where it lives.** A Cargo crate in a top-level directory of the repository. Not under
  `gnome-shell/extensions/`: `./install` links that tree whole into GNOME's extension directory, and a build
  directory does not belong there. One crate, with the bus, the logging and the watchdog as modules; it
  becomes two crates when a second program exists to share them.
- **What is ported,** 2,699 lines of JavaScript with their comments:

  | From | What it is |
  |---|---|
  | `service/sampler.js` | the fast tick, the app scan, the histories, the publish |
  | `service/dbusService.js` | the interface, the sequence, watches per caller |
  | `service/main.js` | the name, start and stop, the exit statuses |
  | `lib/procParsers.js`, `lib/cgroupParsers.js` | the file parsers |
  | `lib/cpu.js`, `lib/memory.js` | busy fractions, the cluster map, memory and swap |
  | `lib/apps.js` | naming, grouping and ranking; "kernel" and "short jobs" |
  | `lib/cadence.js` | when a scan is due |
  | `lib/protocol.js` (the two builders) | the JSON of a Sample and of the state |

- **What it keeps exactly:**
  - every definition in v2's "Definitions changed", ruling R22 included;
  - the cadence: a tick every 2 s, a scan every 20 s watched and 60 s unwatched, the burst, warm-up and reveal
    rules, and their cooldowns;
  - every failure logged once per ten minutes by a stable key, with the same `resource-pulse:` prefix;
  - how each ending reads to systemd: clean for a stop and for a session that ended, a failure (exit 1) when
    the name was never owned;
  - `takenAtUsec` on `CLOCK_MONOTONIC` in microseconds, the clock the client compares it with;
  - the clock label: local time as `HH:MM`, read afresh for each label, so a time-zone change is followed;
  - a cgroup counts as vanished on "no such file" and on "no such device", and on nothing else;
  - arithmetic in doubles, operation for operation in the same order, so the same input gives the same bits.
- **The bus name is never taken from a running copy, and never given up.** The gjs service asks for the name
  with "do not queue" only. `zbus`'s default adds "replace the existing owner" and "allow replacement", so
  with the default a second copy takes the name and the first runs on without it: one mistyped command would
  put the desktop on a program systemd does not manage. The program asks with "do not queue" only. The deterministic tests in
  `resource-pulse-sampler/tests/bus_link.rs` pin the rule, and the row checks that the program as a whole holds
  it: a second copy exits 1, and the first still owns the name afterwards.
- **It listens before it is named.** The client calls `GetState` the instant the name has an owner, and
  systemd counts the unit started at the same instant. `zbus` drops a message that arrives while nothing is
  listening, and its builder asks for the name before the program can listen. So the connection is made
  without a name, the stream of incoming messages is opened, and only then is the name requested. The gjs
  service states the same rule in its header. The deterministic tests in `resource-pulse-sampler/tests/bus_link.rs`
  pin the rule, and the row checks that the program as a whole holds it: the program started many times, each time
  called from a handler of the name's appearance, with no call ever timing out.
- **One thread produces every message, replies included.** A state reply that carries sequence N leaves
  after Sample N and before Sample N+1. The gjs service gives that order by having one thread, and the
  client leans on it: while it waits for a state it drops Samples, because "the state includes this Sample",
  and a Sample whose sequence is not past its state's reads as a restart: no data, then `GetState` again
  (`pulseClient.js`, `_onSample`). With calls answered on one thread and Samples sent from another, nothing
  orders the two, and the cost is a flash of "no data" or a lost history column.
  - So the thread that samples also answers the calls, through the library's message-level API, and no
    interface is registered with the library's object server, which would answer in parallel. The review
    read `zbus`'s source for this: a send writes on the caller's own task, so one thread fixes the order.
    As built, a second thread of the program's own receives incoming messages and hands them over; it
    never sends.
  - Every call the program does not handle is answered with the standard "unknown method" error, and
    `Introspect` returns the interface's text, as the gjs service does today. Without that, a mistyped call
    or `gdbus introspect` waits out a 25 s timeout.
  - **The plan's first task proves both orders and measures the result** on a private bus: the reply order
    (`GetState` asked in a loop while ticks run fast), the start-up order (the row above), and the memory,
    threads and hand-written lines of the program as used. If `zbus` cannot hold either order, the library
    choice reopens.
  - No golden file can catch either order, so both rows stay in the table for good.
- **A fault costs one field or one tick, never the process.** The gjs sampler gets this from the language: a
  catch around each part and one around the whole tick, for the failure nobody foresaw. In Rust an
  unforeseen input is a panic, and the spike's build made a panic an abort: a crash loop, with no gjs sampler
  to return to. So:
  - a panic unwinds and is caught around each tick and each call, logged under a stable key like any other
    failure, and the next tick runs;
  - everything that can fail is worked out before any state changes, as today, so a caught failure leaves
    nothing half-written;
  - the CI job refuses the constructs that panic (unchecked unwraps, indexing and string slicing) in the
    sampler's code;
  - one row feeds the program a tree of truncated and garbage files and requires it to keep publishing, and
    the parsers get a small randomised test.
- **Ticks do not drift, and a missed one is skipped.** Ticks are scheduled against the monotonic clock. A tick
  missed while the program was stalled or frozen is not replayed: a burst of catch-up Samples, each over a
  near-zero interval, would be wrong numbers. GLib, which the gjs sampler runs on, never catches up either.
- **Leaves are taken in name order, in both programs.** Today the gjs sampler takes them as Gio lists a
  directory, which is by inode. A group takes the name of its first leaf, and the units of one snap can
  resolve to different names, so today's name for such a group rests on inode numbers. Rust's listing is in
  yet another order. So the gjs sampler is changed first, in a pull request of its own, to sort its leaves;
  the port does the same; a scenario with such a snap pins it. The order is JavaScript's default string
  order, which the port reproduces exactly. This is a change to today's behaviour, made on purpose: such a
  group's name can flip once, to another of its own names.
- **Three places where JavaScript's strings differ from Rust's, each kept as the gjs sampler has it:**
  - an escaped byte in a unit name becomes one character per byte, so a non-ASCII name comes out garbled
    today; the port garbles it the same way, and fixing it for both is a follow-up;
  - group keys are ordered as JavaScript orders strings;
  - a file that is not valid text is read with the bad bytes replaced, not refused.
  All three are invisible in ASCII, so one scenario has a unit name with an escaped non-ASCII byte and one
  row reads a file of invalid text.
- **App names without GLib.** The gjs sampler asks `Gio.DesktopAppInfo` for a `.desktop` id's name. The port
  reads the files itself, by GLib's rule, which the plan takes from the source of the GLib installed here
  (2.88) and not from this sentence. As I read it: the user's data directory first, then the system ones, the
  first that has the id winning, so a hidden entry there masks later ones; ids also formed from
  subdirectories; not hidden; of type Application; its `TryExec` present; then the name by GLib's own
  language order (`LANGUAGE` before the locale variables). Each id is looked up once per run, misses
  included, as today. This is the part most likely to drift, so it has its own rows and the shadow run
  compares every name the live machine produces.
- **No gettext catalogues.** Ubuntu's GLib also translates a name through a catalogue the file names (73 of
  the 95 files in `/usr/share/applications` here name one). The port reads the file's own `Name` keys only.
  Under `en_US`, as this session is, none of the 73 differs. Under `en_GB` four do ("Colour Management" and
  three others), and in a translated session more would: a known limit, said in the guide, and a row holds a
  file that names a catalogue.
- **Two switches for tests, as command-line flags, never as environment variables:** the filesystem root to
  read under (`/` by default), and a print mode that writes each publish as a line and opens no bus
  connection. A variable could reach the unit through the user manager's environment; a flag cannot, and a
  row pins the unit's `ExecStart` line exactly.

### What stays JavaScript

- The extension, and the `lib/` modules it imports. `lib/protocol.js` keeps its parsers and its two builders.
- The nested harness. Its real-service mode starts the worktree's own build of the program on the private
  bus, in place of `gjs -m service/main.js`.
- `service/fileIo.js`, which the cockpit service imports.
- **The gjs D-Bus face, as the one test double.** The client's private-bus rows (`client-dbus.test.js`) drive
  `PulseClient` against `service/dbusService.js` over a fake sampler that publishes on demand, and the
  cockpit's rows import helpers from `service-dbus.test.js`. Those rows need streams the real program cannot
  be made to send: a malformed Sample, a sequence that restarts. So `dbusService.js` moves under
  `gnome-shell/tests/` with those helpers and is no longer shipped or run by any unit.
  - The nested harness's replay service has a D-Bus server of its own today. In the deletion's pull request
    it serves through the same double, so the interface is written twice (the program and the double), not
    three times, and the slow signal is taught to two places.
  - One conformance row plays the same exchange against the double and against the real program and
    compares what a client sees, so the double cannot drift into a lie.
- **Deleted in the fourth pull request:** `service/main.js` and `service/sampler.js`; the six `lib/` modules
  only they import (`apps`, `cadence`, `cgroupParsers`, `cpu`, `memory`, `procParsers`); and their rows. The
  plan checks each import before deleting.

### How the numbers stay the same

- **Scenario files.** Each names a sequence of steps: a fixture root, a clock value, a clock label, a watch
  starting or ending, the names a `.desktop` id resolves to. Both programs read the same files.
- **Golden files.** A gjs script runs the real `ServiceSampler` and `ResourcePulseDBusService` through every
  scenario and writes what they publish: each Sample and the final state. The files are committed. One check
  fails when the gjs sampler no longer produces them; another fails when the Rust sampler does not.
- **What the golden files prove, and what they do not.** They run the sampler as a library, with the clock,
  the clock label, the app names and the file reader handed in, as the gjs sampler's own rows do. So they
  prove the definitions. They do not prove the program's wiring of the real clock, the real label, the real
  name lookup or the real reader. Those have rows of their own: the label under two time zones, the lookup
  against fixture `.desktop` files, a "no such device" handed in as an error, and the shadow run.
- **Equal means equal as parsed JSON:** the same keys, no extra and none missing, `null` where `null`, strings
  equal, and every number the same double bit for bit. Key order and number spelling do not count. The
  comparison parses with a correctly rounding parser (gjs's own, or the Rust library's exact mode), and the
  writer never prints a negative zero, which JavaScript prints as `0`.
- **The shell's parser reads the same files:** a row runs `parseSamplePayload` and `parseStatePayload` over
  every golden file, so the files are the protocol both sides are pinned to.
- **One reader takes the state as text, so its text is contract too.** `gnome-status` cuts the `GetState`
  reply at the first `"snapshot":` and reads the digits straight after `"protocol":` and
  `"latestSampledAtUsec":`; a miss prints "protocol unknown" and no warning. So the state is written
  compact, with `protocol`, the two times and the sequence before the snapshot, and whole numbers as plain
  digits. The row that proves it runs `gnome-status`'s own reader, over the program's reply from the switch
  on.
- **Every existing row is carried over.** The sampler's rows today are in six test files (about 180 rows:
  `service-sampler`, `service-dbus`, `parsers`, `math`, `apps`, `cadence`), and many build their trees in
  memory, which a golden file does not cover. The plan lists each row beside the Rust test that replaces it.
  A row with no counterpart must say why.
- **The round trip on a private bus:** the real program under `dbus-run-session`, reading a fixture root:
  `GetState`, a Sample, a reveal after `WatchDetail`, a watch dropped when its caller disconnects, an unknown
  method answered with an error, `Introspect`, and the two rows on the name.
- **Constants both languages hold** (the interval, the history length, the bus names, the protocol version, the
  slow signal's interval) are compared by a row, so neither side can change one alone.
- **The shadow run,** before the switch, is about names: the one thing no fixture can hold. A gjs script
  names every leaf the machine has at that moment, with the real `lib/apps.js` and `Gio.DesktopAppInfo`;
  the Rust program names the same leaves. It opens no bus connection and reads `/sys` and `.desktop` files.
  - **It runs in the unit's environment, not the caller's.** Which directories are searched, which
    `TryExec` is found and which language wins are all environment, and a shell's differs from the user
    manager's. So both programs are given the user manager's values for those variables, and the run says
    which it used.
  - **It has a floor.** Each run reports how many leaves were named from a `.desktop` file and how many fell
    back, by kind (app scope, snap, flatpak), and every id it looked up with hit or miss. It fails when a
    kind present on the machine resolved no name at all: two programs that both find nothing agree, and
    prove nothing.
  - It passes when every leaf in both listings has the same group key and the same name, in each of several
    runs spread over a working day, so that different apps are seen. Numbers are not compared live; the
    golden files prove the definitions.
- **After the gjs sampler is deleted,** the golden files are the definition. A change to one is a deliberate
  edit in a reviewed pull request.

### Build and deploy

- **`./install` builds and installs the program** when the extension is opted in and cargo is found:
  `cargo build --release --locked` under the repository's build cap, then a copy to a fixed path under
  `~/.local/lib/`, written beside its final name and renamed over it. A running sampler keeps the file it
  started from; nothing in the checkout or in a worktree is ever the live program.
- **An install that changes nothing touches nothing.** The freshly built file is compared with the installed
  one, and an identical file is not renamed over it. Without that, every `./install` would give the program a
  new time, and the refresh step would restart the sampler and empty its histories on every deploy, also
  the ones that changed only a shell file. The row: a second `./install` with nothing changed renames
  nothing and restarts nothing.
- **Two questions, two answers.** "Is the unit running older code than is installed?" is answered by time,
  as today: the installed program, or the unit file, is newer than the unit's start, and the refresh step
  restarts it. "Is what is installed older than the checkout?" is answered by a hash the program carries of
  its own sources and `Cargo.lock`, never of the commit or the time, which `gnome-status` compares. The
  cockpit's unit keeps the closure rule.
- **The step's place and its exit.** It runs before the reload-and-refresh step. A failed build installs
  nothing, leaves the installed program as it was, says so loudly, and still exits 0: a failing step would
  stop the rest of `./install` for everyone. Never a pipe into the final path: a renderer that fails after
  the truncate is this repository's own lesson.
- **After a restart the refresh step looks.** It reads the unit's state after its restart and warns when the
  unit is not active. Today it prints its tick when `systemctl` returns 0, which is also what a start that
  did not happen returns.
- **Without cargo** `./install` says the sampler was not built and why (decision 8). The unit's start then
  fails, and after the start limit the unit is `failed`: visible in `systemctl --user --failed`, and asserted
  by `verify-tools.sh`, which also learns "sampler not built" and "installed older than the checkout".
  `gnome-status` says the same in its own line. The extension shows "no data" and keeps asking every five
  minutes, as it does today for a unit that will not start; that is also what starts the sampler after a
  later build. (Decision 9.)
- **Dependencies are pinned by `Cargo.lock`,** committed, and `--locked` refuses anything else. They are not
  vendored into the repository: the first build on a machine downloads them, and cargo checks each against the
  lockfile's checksum.
- **The toolchain is rustup's stable.** The crate states the oldest compiler it supports (`rust-version`,
  no lower than the library's own 1.89), and `./install` compares it with `cargo --version` before building.
  mise stays out of it, as `.mise.toml` already explains.
- **Worker caps.** `zsh/zshrc.buildlimits` caps cargo's build jobs already. It gains the cap for cargo's test
  threads, which default to one per core, and `./install`'s build takes the same cap explicitly, since it
  does not run under an interactive shell.
- **The build directory is never an untracked file in the primary checkout,** which is the deployment and is
  read by every guard that runs `git status`.
- **The owner's deploy does not change:** fetch, check, `merge --ff-only`, `bash ~/.dotfiles/install`. Between
  the merge and the install the running sampler is the previous build, which additive skew allows.
- **A side effect worth having:** the sampler leaves the JavaScript closure, so a change to a cockpit constant
  in `lib/constants.js` no longer restarts it and costs it its histories.
- **CI gets one job:** `cargo test --locked`, `cargo clippy` with warnings as errors, `cargo fmt --check`, the
  private-bus rows and the golden checks, on `ubuntu-latest`. Pre-commit must not require cargo of someone who
  never touches the sampler; CI is the gate.

### The unit

- `ExecStart` is the installed program, with no condition on it. `Type=dbus`, the bus name, `PartOf=`, the
  start limit, `Slice=`, `Nice=` and `CPUQuota=10%` stay as they are.
- **`WatchdogSec=120`.** The program tells systemd it is alive on every tick; after 120 s of silence systemd
  kills it, and `Restart=on-failure` starts it again. A hung sampler is then restarted by itself, where
  today it stays hung until someone looks; the client's own rule still shows "no data" after 6 s, as now.
  (Decision 10.)
  - *Why not shorter.* Around a suspend systemd freezes the user's session, the user manager with it. The
    watchdog's clock stops while the machine sleeps but runs while it is frozen and still awake, and on thaw
    nothing orders the sampler's first sign of life before the manager's check. A machine that is thrashing
    can stall a healthy sampler too. A sampler killed then loses its histories at the worst moment.
  - A reload does not arm the watchdog on a sampler that is already running: the interval is taken at start.
    So the switch's reload cannot kill the gjs sampler in the moment before its restart.
  - The notification is one datagram, written by hand, for both forms of address systemd may give; no
    libsystemd.
- **Memory caps come down with the deletion, not with the switch.** Caps apply to a running unit at a reload,
  and the gjs sampler is charged 16.6 MiB. Lowered at the switch, any reload between the merge and the
  install would squeeze it. Lowered once no gjs sampler can be running: `MemoryHigh=16M`, `MemoryMax=32M`.
- **A stop needs no handler.** The program holds nothing to flush, and systemd counts an exit on `SIGTERM` as
  clean.
- **`systemd-analyze verify` runs on a copy** whose `ExecStart` points at a file that exists; a separate row
  pins the real line. Verifying the shipped file passes here and fails on CI, where the program is not
  installed.

### The slow signal (the fifth pull request)

- **The signal.** `State(s)` on `ResourcePulse1`: the state JSON, exactly what `GetState` returns, sent every
  30 s on a tick. The service sends it always and keeps no state about who listens. An extension loaded
  before this never receives it: the link subscribes by signal name.
- **The field.** The state JSON gains `stateSignalIntervalSeconds`. A client goes slow only against a service
  whose last state carried it, so a service without the signal (a rollback) is heard as today.
- **The client has three states.** *Samples*, as today. *Slow*, while the top bar is not mapped, every card
  on the desktop is covered and the dropdown is closed: subscribed to `State` only. *Off*, while the
  extension is disabled.
- **"Every card" includes the cockpit's.** The cockpit's layer is paced by this client's listeners, so a
  cockpit card left visible while the client is slow would be drawn every 30 s. The nested check has a
  cockpit card visible on a second monitor with a fullscreen window on the first, and requires Samples.
- **In the slow state** each `State` is applied through the path a `GetState` reply already takes. It is the
  tick for the two things that today count Samples: the covered card's cover backstop, and ruling R21's dimmed
  repaint. The backstop runs on every `State`, where today it runs on every fifteenth Sample: the same 30 s.
  The dimmed repaint also runs on every `State`, without asking its 30 s clock. Today that clock is asked on
  every Sample; asked of a signal that itself comes every 30 s it would answer just under or just over, and
  the repaint would land at 30 or at 60 s, the defect stage one's build fixed.
  The stall rule is the same rule on the slow interval: two missed signals and the surfaces show no data.
- **On the way back** the client subscribes to `Sample` and then calls `GetState`, as after an owner change.
  The card stays as it was, dimmed, until the fresh state arrives, which is one round trip on the bus; it
  shows "no data" if none comes within the call's 2 s timeout. So the card shows neither an old number as
  live nor a flash of "no data". The top bar draws as soon as it is mapped, so for the frame or two before the
  answer its graphs can end up to 30 s short. They carry no number.
- **What it is worth.** Nested, the state costs 0.068 % of one core added and a 0.60 ms median per tick today.
  Slow, the shell handles 2 callbacks a minute where it handled 30. On the live shell the stock shell's own
  collections then come about every 12 s, where a Sample every 2 s holds them at every 10 s: a small gain,
  and only on Wi-Fi or battery.
- **The cockpit's pacing is not affected.** With any cockpit card on screen the client is not slow, so
  Samples flow at 2 s; the cockpit's own client is already unsubscribed while nothing of it is seen. The slow
  state is built on the link the cockpit generalised: `serviceLink.js` takes a descriptor per link and has
  `setSubscribed`.

### Burst scans (follow-up 8)

The cadence is ported unchanged, so that equality can be proved first. Then the watched service is measured
under the five minutes of real history that fire 5 scans a minute through `lib/cadence.js` (finding 13). If it
is inside the watched budget, the follow-up closes as measured, with no cap. If not, the cap is one constant:
the most triggered scans in a minute.

## Budgets

At idle, as v2 measured them, read by `scripts/resource-pulse-cost.sh --service`. % of one core.

| What | Budget | Today (gjs) | Measured for this design |
|---|---|---|---|
| The service, no watch held | 0.05 | 0.07 at idle; 0.12 to 0.19 loaded | 0.022 loaded (the floor, no D-Bus) |
| The service, a watch held | 0.1 | 0.16 at idle; 0.21 to 0.58 loaded | 0.055, 0.087 loaded (the spike, `zbus`) |
| The service's resident memory, flat over 24 h | 8 MiB | 30 to 38 MiB (16.6 MiB charged) | 3.3 MiB (the spike) |
| In the shell, nothing visible | 0.01 added | 0.068 added | not built |
| Callbacks into the shell a minute, nothing visible | 2 | 30 | not built |
| Everything else in the shell | as the performance design's "Budgets" | | unchanged |

- The spike does a little less than the real sampler will (no per-CPU split, no ranking), so its figures are a
  floor, taken on a loaded machine. The budgets are for an idle one. The gjs column's upper figures are from
  states the spike did not run (a burst of scans); the like-for-like pairs are in the summary.
- The percentages are reported and the counts are gated, as the performance design set it. A reading more than
  0.05 over its budget is raised with the owner before the switch.

## Testing

- **Rust:** unit tests carrying every existing row, the golden checks, the private-bus rows, the `.desktop`
  lookup rows against fixture files, the garbage-tree row and the randomised parser test, clippy and rustfmt.
- **A state table for the new guard,** with its asserted row total: the build step against a stub cargo
  (present, absent, too old, failing), the install by rename and the install that changes nothing, the unit's
  rows, the refresh rule and its look after a restart, `gnome-status` and `verify-tools.sh` against a stub
  systemctl. A stub is a claim about the real tool, so each is checked against the real one's output once.
- **A mutation sweep** over the Rust sampler and the new shell scripts, each mutant dry-run for applicability
  first, committed before it starts, one at a time with a timeout that kills the group, under the test cap.
- **The nested shell,** for the fifth pull request only: the `perf` request learns the nothing-visible
  state's counts (no Sample handled, at most 2 callbacks a minute, the dimmed repaint still every 30 s), and
  the double learns the signal and the field.
- **Row totals:** `scripts/test-resource-pulse.sh` asserts its total in every pull request. The switch
  rewrites the rows that pin the unit's `ExecStart` and the refresh rule. The deletion removes exactly the
  rows the plan lists against their Rust replacements; a row goes only when its replacement is named.

### Live checks, each on the owner's word

1. **The service's cost after the switch,** watched and unwatched. Reading it is passive; holding a watch for
   the watched reading is one `WatchDetail` call on the live bus.
2. **A 24 h check** after the switch, scheduled through rabota: the sampler at or under 8 MiB, no watchdog
   kill in the journal, and whether the machine suspended inside the window, since a window without a
   suspend says nothing about one.

The shadow run is not one of them: it reads `/sys` and `.desktop` files only.

## Order of work

| # | What lands | What a deploy of it does | Gate before the next |
|---|---|---|---|
| 1 | The gjs sampler sorts its leaves by name | The gjs sampler restarts once. A group whose leaves have different names can change its name once. No login. | — |
| 2 | The crate, scenario and golden files, the tests, the CI job, the build and install step, the test-thread cap | The program is built and installed, and nothing starts it. No restart, no login. | The two order rows and the golden checks green; the library final; the shadow run passes |
| 3 | The unit switches to the program: watchdog, the refresh rule, `gnome-status`, `verify-tools.sh`, the guide | The sampler restarts once; its histories refill within five minutes. No login. | The live cost inside budget; the 24 h check passes |
| 4 | The gjs sampler, its six `lib/` modules and their rows are deleted; its D-Bus face becomes the one double; the memory caps come down | The sampler restarts once, for its unit file. | — |
| 5 | The slow signal: the service sends it, the extension listens while nothing is visible | The service half is live at once; the extension half at the owner's next login. | The nested `perf` request, three runs |

- **Each starts from the `main` of its day** and waits only for its own gate.
- **The first is separate on purpose.** It changes live behaviour, and the golden files are then generated
  from a `main` that already sorts. A revert of it or of the second does not drag the other.
- **The second's first task** is the proof on a private bus that decides the library ("The program").
- **Going back** is a revert of the third pull request, for as long as the fourth has not merged.

## Risks

- **A name that differs.** The `.desktop` lookup is rewritten, not ported. The shadow run exists for it.
- **A library four weeks into a major version,** on a runtime crate still at 0.x. `Cargo.lock` pins what was
  tested; an upgrade is a pull request with the golden checks and the two order rows behind it.
- **A second language in one feature.** The golden files and the constants row are what keep the two sides
  from drifting; without them this would be the upkeep deal-breaker.
- **An input nobody foresaw.** The catch around each tick turns it into a logged failure. If it persists, the
  field it belongs to shows no data for as long as it lasts, as with the gjs sampler.
- **The first build needs the network.** A machine offline at its first `./install` gets "sampler not built",
  plainly, a failed unit, and a build at the next.
- **A watchdog that kills a healthy sampler.** Unlikely at 120 s, and the journal names every one. One in the
  24 h check is a reason to lengthen it, or drop it, before the deletion.

## Follow-ups (not in this work)

Each is open until the owner closes it.

1. **A Sample only when the top bar would change.** Held; the live reading at rest decides it.
2. **The live reading at rest, wired and charged** (decision 6). The script is prepared; it runs on his word.
3. **The upstream report** on the stock shell's collections (decision 7), after this design merges.
4. **A prebuilt binary from CI** (decision 8), if the Rust sampler proves itself.
5. **The cockpit service in Rust** (decision 4), after it has run live and been measured.
6. **Faster reveal.** Follow-up 4 of the performance design; cheaper to build once the scan is compiled.
7. **Histories across a restart,** by a small state file. Only worth it if restarts become common.
8. **Unit names with an escaped non-ASCII byte** come out garbled today, and the port keeps that. Fixing it
   changes a name on purpose, in both places at once.

Follow-ups 1 to 3, 5, 6 and 10 of the performance design stay there, untouched by this work.

## My calls (checked by the owner with the approval)

- `zbus`, on condition of the first task's proof; `rustbus` if it fails.
- Five pull requests, in that order, and the gates between them.
- Equality as parsed values with numbers bit for bit, in place of "byte for byte".
- Scenario and golden files, generated by the gjs sampler while it exists and edited deliberately afterwards.
- The program installed by copy and rename under `~/.local/lib/`, never run from the checkout.
- No signal handler, no vendored dependencies, no cargo requirement in pre-commit.
- The slow signal's shape: `State(s)` carrying the state JSON, every 30 s, sent always; the field that
  announces it; on the way back, a card that waits for the fresh state and a top bar that does not.
- Burst scans: measured first, capped only if over budget.
- The budgets for the service are the performance design's; the two new in-shell ones are mine.
- The two live checks, and that each waits for his word.
- Leaving out a state file for the histories, and faster reveal.

From the builder check (2026-11-13), each a question the first draft left open:

- **Builder check:** the thread that samples answers the calls, so replies and Samples keep today's order.
- **Builder check:** the gjs D-Bus face stays as a test double under the tests, with a conformance row
  against the real program.
- **Builder check:** the state's text is contract for `gnome-status`: compact, its top-level numbers first.
- **Builder check:** in the slow state the dimmed repaint runs on every `State`, not on its clock.
- **Builder check:** leaves in name order in both programs, which changes the gjs sampler now and can flip
  one multi-name group's name once.
- **Builder check:** no gettext catalogues; a translated session can show a name GNOME would translate.
- **Builder check:** the shadow run compares names leaf by leaf, opens no bus, and passes only when no leaf
  differs.

From the independent review (2026-11-13). The first draft was wrong or silent on each:

- **Review, important:** the bus name asked for with "do not queue" only; the library's default would let a
  second copy take it.
- **Review, important:** the library choice restated on its true terms, and measured as used before it is
  final; unknown calls and `Introspect` answered.
- **Review, important:** no condition on the unit; a missing program is a failed unit (decision 9).
- **Review, important:** the program listens before it is named, so the client's first call is never dropped.
- **Review, important:** an install that changes nothing renames nothing; the first draft's rule restarted the
  sampler on every deploy.
- **Review, important:** the shadow run in the unit's environment, with a floor on names actually looked up.
- **Review, important:** the watchdog at 120 s, not 30, and the 24 h check says whether a suspend happened
  (decision 10).
- **Review, important:** a panic is caught around each tick; the first draft promised "never a crash" with no
  mechanism.
- **Review, minor:** one crate, not two; the leaf sort in its own pull request; the install step's place and
  exit; the memory caps lowered with the deletion; one test double, not two; the clock label, "no such
  device" and the three string differences each with a rule and a row; the comparing parser named; the test
  switches as flags; the test-thread cap, the build directory and `verify-tools.sh`; the summary's figures
  like for like; `en_US` where the draft said "English"; the collections sentence cut to what was measured.

Not taken from the review: nothing. Three of its points it could not verify itself are carried into the plan
as checks: how long this machine stays frozen around a suspend, what `systemctl` returns for a restart whose
start does not happen, and the nested check with a cockpit card visible.

## Left to the builder

- The crate's directory and name, and the program's installed name.
- The module layout inside the sampler, and how the sampling thread waits for a call or the next tick.
- How the JSON is written, as long as the golden checks and the row for the state's text pass.
- The scenario file format, and which scenarios beyond one per fixture root.
- How the program carries the hash of its sources.
- Where cargo's build directory lives, within the rule under "Build and deploy".
- How `./install` tells that the extension is opted in.
- The signal systemd sends on a watchdog timeout, and which hardening directives the unit gains: only ones
  probed to work in a user manager here, each with a row.
- The slow state's exact window signals, and the name of every new constant.
