# Resource Pulse performance: profiling report and design

**Status:** approved by the owner on 2026-11-11. **Stage one is built** (plan:
[2026-11-11-resource-pulse-performance-stage-one.md](../plans/2026-11-11-resource-pulse-performance-stage-one.md));
what the build changed, and what it measured, is under "Stage one as built". Stage two is not started.
**Measured:** 2026-11-10.
**Measured on** `origin/main` at 0b873b8. `main` has since merged the cockpit's data side (#375) and its
drawing-side plan (#376); "Order of work" below says what that changes.
**Builds on** [2026-11-08-resource-pulse-service-design.md](2026-11-08-resource-pulse-service-design.md) (v2) and
[2026-11-09-desktop-cockpit-design.md](2026-11-09-desktop-cockpit-design.md) (the cockpit). Where this document
reopens a decision of theirs it says so; everything it does not mention stands.

## Summary

- **The extension costs about 0.28% of one core in the state it is in all day** in the nested shell (card
  covered, top bar on) and 0.34% with the card visible, against a budget of 0.1%. On the live shell it adds
  0.39–0.54% and 0.45–0.73%. The originating session's numbers reproduce.
- **Most of that is not drawing.** About half of the cycles are the JavaScript engine itself, and the compositor's
  own painting is about a tenth.
- **The largest single cause was not on anyone's list:** every Sample makes GJS schedule a forced, full,
  non-incremental garbage collection on the compositor thread. On the live shell that is a burst of 22–56 ms
  every 10 seconds for as long as the extension is enabled: two or three missed frames each time.
  *Corrected 2026-11-11: that holds in the nested shell. On the live shell most of those bursts are the
  stock shell's own and continue with the extension disabled; see "Measured on the live shell".*
- **Two periodic 2-second timers** cost about as much as handling the Sample.
- **A covered card is still painted.** Under a window that repaints, the frozen card beneath it costs more than
  everything else: 0.8 points on the live shell at only 15 frames a second. Drawing the card through an offscreen
  texture removes that, and does not change how it looks.
- **Throwaway variants without those causes measured a fifth of today's cost at idle and a third to a half
  under load,** with the same look and the same numbers on screen, and no change to the service.
- **End to end, the service is then the larger half.** Three quarters of the gjs sampler's cost is its runtime.
  A compiled sampler doing the same reads measured a quarter of the CPU and a fifteenth of the memory.
- **So the design has two stages:** the shell side now, with no service change; and a compiled sampler as its
  own project, which the owner has asked for.
- **The 0.1% budget holds at idle and cannot hold under load** while the top bar redraws every 2 seconds. This
  document proposes a budget per state.

## Why

Resource Pulse v2 moved the sampling out of the shell and set an in-shell budget of under 0.1% of one core. The
first live reading (2026-11-10) put the extension at about 0.45%. The owner asked for the architecture to be right,
the profiling to be complete and accurate, and every method to be weighed, before anything is built; and for a
design that still holds when the cockpit adds a grid of cards.

## Decided by the owner (2026-11-10 and 2026-11-11)

1. **This work goes before the cockpit's drawing side,** starting from current `main`. The cockpit's
   drawing-side plan is amended for the four conflicts listed under "The cockpit"; that amendment goes through him.
2. **Five ride-along items are in and three are out, with faster reveal out too,** as proposed under "Ride-along
   items". None of the eight may be lost track of: each one in gets its own task in the plan, and each one out is
   listed under "Follow-ups" and in the pull request's description.
3. **The live reading** ran on his word the same evening, with `perf stat` and the repainting-window phase he
   allowed. Finding 12 has it.
4. **"As long as it's safe, we need to make sure this works as optimally as possible end to end, leveraging
   whatever architectural designs, technologies, or languages we need."** So the design weighs options outside
   GJS and outside the shell, and covers the service as well as the extension.
5. **This document is approved** (2026-11-11): stage one as designed, and the budgets as proposed.
6. **Stage two is wanted: "No problem transitioning to Rust. The priority is to have a minimal footprint and
   optimal performance and UX."** It gets its own design and plan after stage one.

## Method, and what each tool can and cannot see

Everything ran in the isolated nested shell (`scripts/resource-pulse-nested.sh`) on `origin/main` (0b873b8):
GNOME Shell 50.1, mutter 50.1, GJS 1.88.0, a 3072×1920 virtual monitor at scale 1, on the reference laptop (Core
Ultra 7 258V, four P cores and four E cores). The live desktop was only read, except in the one live reading the
owner agreed to (finding 12).

| Tool | What it shows | What it cannot show |
|---|---|---|
| Scheduler counters, `/proc/<pid>/task/*/schedstat` | Exact CPU time per thread over a window, to the nanosecond; per-interval series, so the steady cost (median) is told from bursts (mean). | What the time was spent on. |
| `perf stat` | Cycles and instructions: whether a burst is slow because the clock is slow or because the caches are cold. | Attribution. |
| `perf record` with frame pointers | Cycles by library and by exported function, kernel against user. | Names inside SpiderMonkey and the kernel (no debug symbols; `kptr_restrict` hides kernel names), and JIT frames. |
| mutter's trace marks (the `org.gnome.Sysprof3.Profiler` interface) | The wall time of each stage of each frame: dispatch, relayout, paint, swap. | Anything between frames, and CPU as opposed to wall time. |
| GJS sampling profiler (`GJS_TRACE_FD`) | JavaScript time by function, collections and JIT compilation, at 1 ms. | Time in C with no JavaScript above it; it also slows the shell, so its totals are not costs. |
| SpiderMonkey's GC log (`JS_GC_PROFILE`) | Every collection: when, why, how long. | Which object caused it. |
| Hot loops in the shell | The floor of each step, run 2,000 times back to back. | The cost in place, which is several times higher. |
| State matrix and throwaway variants | What each layer, and each change, is worth in place. | Nothing below about 0.03 points: single 60–100 s windows differ by that much. |

Three cautions apply to every number here:
- **The nested shell is headless.** It has no KMS thread and no page flip, and its monitor is at scale 1, where
  the live panel is at 1.25. The live reading is what covers that.
- **The in-shell counters cost something.** They run JavaScript on every frame. Readings marked "clean" were
  taken without them.
- **The first minute after a shell starts is not representative.** Later runs wait 40 s before measuring.

## Findings

### 1. The originating numbers reproduce

CPU of the nested shell, % of one core, two passes of 100 s:

| State | Originating session | This session |
|---|---|---|
| Extension disabled | 0.03 | 0.028, 0.015 |
| Card visible, top bar on | 0.36 | 0.316, 0.365 |
| Card covered, top bar on | 0.35 | 0.303, 0.283 |
| Card covered, top bar hidden | 0.17 | 0.180, 0.189 |
| Card visible, top bar hidden | 0.24 | 0.303, 0.267 |

The last row differs. The two passes here differ from each other by as much, so it is within the spread.

### 2. Where the time goes, by layer

Three more states strip the extension one layer at a time (means of the two passes, ms of CPU per 2 s tick):

| Layer | Cost per tick | State that isolates it |
|---|---|---|
| The two 2-second timers (stale check, cover re-check) | 1.3 ms | service paused |
| Receiving the D-Bus signal with no JavaScript handler | 0.5 ms | handler disconnected |
| The JavaScript handler: unpack, parse, record | 0.8 ms | listeners removed |
| The listeners: cover check, the top bar's draws while hidden | 0.7 ms | card covered, top bar hidden |
| The top bar on screen: its frame and textures | 2.2 ms | card covered, top bar on |
| The card on screen, on top of a frame that already happens | 1.0 ms | card visible |

The "listeners removed" state uses its first pass only: a run of long collections landed in the second.

Two rows hide a larger cost, which the next finding names: "receiving the signal" is not free even with no
handler, and the timers cost far more than their few lines.

### 3. A forced full collection every 10 seconds

- **What happens.** With the extension enabled the GC log shows a major collection every 10.0 s, reason
  `MEM_PRESSURE`, which is how SpiderMonkey prints GJS's own reason "Big Hammer". With it disabled they stop.
  Each is full and non-incremental, on the compositor thread.
- **How long.** In the nested shell, whose JavaScript heap is 6 MiB, each takes 4–17 ms, and 54–110 ms was seen
  while the machine was loaded. That is 35–47 ms per minute. The live shell's heap is much larger, so its
  collections are longer: 22–56 ms each (finding 12).
- **Why.** GJS schedules that collection 10 s after any wrapped GObject drops to its last reference
  (`ObjectInstance::toggle_down` in `gi/object.cpp`, which calls `schedule_gc()`). A wrapper is tracked that way
  only once JavaScript has attached state to it, such as a signal handler. The extension's `Gio.DBusProxy` is such
  an object: it is owned only by JavaScript, it has handlers, and GDBus takes and drops a reference to it for
  every incoming signal. So every Sample re-arms the hammer.
- **The proof.** Stripping layers: with the handler disconnected but the proxy still receiving, four collections
  in 45 s; with the service paused, one; disabled, one. A bare proxy with no handlers, a subscription on the
  shared connection, and a plain timer each gave one or two, the idle shell's own rate.
- **What else it costs.** A full collection can discard compiled code, so the next ticks run in the interpreter
  and compile again. The sampling profile shows compilation recurring all session: 18–23 ms in each 120 s.
- **The sampler service does not have this problem.** Alone for 70 s it logged one such collection at start-up,
  then only its own planned ones, 1–2 ms each.
- *Added 2026-11-11: "with it disabled they stop" is the nested shell. The live shell forces the same
  collection by itself, from its own objects; see "Measured on the live shell".*

### 4. Cold execution: in place costs about seven times the hot loop

| Step, run 2,000 times back to back | CPU each |
|---|---|
| `JSON.parse` of a 696-byte Sample | 3 µs |
| Unpacking the GVariant | 7 µs |
| The cover check | 11 µs |
| One top-bar graph, `queue_repaint()` | 29 µs |
| The card's CPU graph, `queue_repaint()` | 99 µs |
| `card.update()` | 106 µs |
| The whole Sample path, all listeners | 226 µs |

In place the same path costs 1.5–2 ms. `perf stat` says why: the bursts run at 3.4–4.0 GHz, so the clock is not
slow, but at about 1.0 instruction per cycle on a P core and 0.5–0.7 on an E core. After 2 s asleep the caches
hold other programs' data, and the forced collections keep the code uncompiled.

### 5. Half of the cycles are the JavaScript engine

`perf record`, card visible, 120 s:

| Component | Share of cycles |
|---|---|
| JavaScript engine: SpiderMonkey, GJS, JIT code, introspection | 51% |
| Kernel | 18% |
| GLib, GObject, GIO, libc | 17% |
| The compositor: Clutter, Cogl, mutter, St | 5% |
| Mesa's GL driver | 5% |
| Text: Pango, HarfBuzz | 2% |
| cairo, pixman | 2% |

The covered-state recording was taken while a window was still starting and is not used here.

### 6. Which core it lands on matters

| Shell pinned to | Card covered, top bar on | Card visible |
|---|---|---|
| A P core | 0.183% | 0.217% |
| An E core | 0.301% | not usable (a burst landed in the window) |
| Not pinned | 0.283–0.303% | 0.316–0.365% |

Nothing in this design pins anything. The table is here so that a reading on one machine is not compared with
a budget set on another.

### 7. The frame itself

- **`St.DrawingArea.queue_repaint()` is synchronous** (`src/st/st-drawing-area.c`, GNOME Shell 50.1). It drops
  its pixel buffer, allocates a new one, maps it, runs the JavaScript paint handler through cairo and returns.
  The next paint makes a new texture from it. It does all of that while the actor is hidden too: the counters
  show 60 top-bar paints a minute with the top bar hidden.
- **One frame, measured from mutter's own marks:** 1.0 ms of dispatch with only the top bar drawn (paint
  0.3 ms, flush 0.5 ms) and 1.5 ms with the card too. A relayout came with 13 of 31 card frames and took 0.1 ms,
  and once 18.7 ms.
- **The size of the redrawn region does not matter.** A bare redraw every 2 s, with no extension code, cost the
  same for a 30×16 patch of the top bar, a card-sized patch and the whole 3072×1920 stage: 0.7–1.1 ms a tick.
- **Clipped redraws are on** in the nested shell and on a real output alike (`meta-stage-impl.c`).

### 8. The live desktop is rarely idle, and the top bar always has something to draw

- Forty minutes of the live shell's own counters while the owner worked (read from `/proc`, nothing touched): a
  median 3.85% of one core, and at least 20 frames a second in 79% of the 10-second intervals. The extension's
  frame mostly joins frames that happen anyway.
- Five minutes of the live service's real history: CPU between 17% and 71%. Quantised to whole pixels, the
  top-bar CPU graph changed on 120 of 120 ticks. "Draw only when something changed" therefore saves nothing
  during work hours; it pays when the machine is idle.

### 9. What the throwaway variants measured

The same extension with a replay service publishing fixed input: **idle** (CPU 1–4%, inside one pixel),
**light** (2–14%) and **busy** (a random walk, 15–90%). Each fix was added on top of the one before:

1. Sample taken through a subscription on the shared connection, not through the proxy.
2. The two 2-second timers gone (slowed to 60 s for the measurement).
3. A lean tick: while only the top bar is seen, a Sample is read for the two history values and nothing else.
4. The top bar's graphs drawn only when a column changes by a whole pixel, and only while mapped.

Then three ways to draw the top bar, each with fixes 1 to 3: the cairo graphs of today drawn on change (fix 4);
graphs painted from JavaScript as GPU rectangles; and the service rendering the graphs to pixels that the shell
only shows.

**One shell at a time, clean, 60 s windows after a 40 s warm-up, % of one core:**

| Variant | Covered, idle | Covered, light | Covered, busy | Visible, busy | Visible, idle | Forced collections a minute |
|---|---|---|---|---|---|---|
| As shipped | 0.283 | 0.284 | 0.281 | 0.343 | 0.336 | 6 |
| Fix 1 only (with the in-shell counters on) | 0.276 | 0.256 | 0.254 | 0.235 | 0.239 | 1–2 |
| Fixes 1 to 4, cairo drawn on change | 0.042 | 0.116 | 0.113 | 0.195 | 0.148 | 1 |
| Fixes 1 to 3, graphs painted from JavaScript | 0.053 | 0.144 | 0.139 | 0.218 | 0.180 | 1 |

**All four in four shells at once, so every reading shares the same minutes; two rounds:**

| Variant | Covered, idle | Covered, light | Covered, busy | Visible, busy | Visible, idle |
|---|---|---|---|---|---|
| As shipped | 0.362, 0.424 | 0.445, 0.425 | 0.422, 0.300 | 0.299, 0.293 | 0.485, 0.290 |
| Cairo drawn on change | 0.070, 0.086 | 0.210, 0.176 | 0.307, 0.112 | 0.182, 0.187 | 0.251, 0.141 |
| Graphs painted from JavaScript | 0.057, 0.096 | 0.189, 0.197 | 0.186, 0.103 | 0.177, 0.191 | 0.226, 0.115 |
| Service renders the top bar | 0.046, 0.016 | 0.153, 0.151 | 0.269, 0.081 | 0.190, 0.184 | 0.261, 0.142 |

The main thread's median per tick is steadier than the totals. Same runs, ms per 2 s:

| Variant | Covered, idle | Covered, light | Covered, busy |
|---|---|---|---|
| As shipped | 5.2, 4.1 | 5.8, 5.8 | 4.6, 2.5 |
| Cairo drawn on change | 0.48, 0.53 | 3.3, 2.6 | 2.7, 1.6 |
| Graphs painted from JavaScript | 0.40, 0.57 | 2.6, 2.7 | 2.3, 1.3 |
| Service renders the top bar | 0.00, 0.00 | 2.2, 2.5 | 2.7, 1.2 |

- **The fixes are worth a factor of about five at idle and two to three under load.** A disabled shell reads
  0.016–0.028 in this method.
- **The three ways to draw the top bar cannot be told apart under load.** Readings taken at different times, or
  with four shells competing, differ by more than the variants do.
- **At idle the service-rendered top bar does not wake the shell at all;** the others pay one wake a tick, about
  0.5 ms.
- **Graphs painted from JavaScript have a cost the others do not** (finding 10): they run JavaScript on every
  frame that touches them.
- Every variant loaded as ACTIVE and logged nothing.

### 10. A covered card is painted on every frame drawn over it

Mutter skips a covered actor only if it implements its cullable interface (`meta-cullable.c`). The card does
not, so every frame a window draws over the card's place repaints the card's two dozen actors beneath it. With a
maximized window repainting its whole surface 60 times a second, % of one core, two rounds of 50 s:

| State | Round 1 | Round 2 |
|---|---|---|
| Extension disabled | 2.68 | 2.57 |
| Card frozen beneath the window, as shipped | 3.89 | 3.84 |
| Card frozen and drawn once into an offscreen texture | 2.75 | 2.85 |
| Card hidden | 2.80 | 2.84 |
| Card hidden and top bar hidden | 2.73 | 2.77 |

- The frozen card costs 1.2 points under that window: about 0.02 for each frame a second. A terminal streaming
  agent output over the card is the same case at a lower rate.
- Either remedy removes it. Hidden and cached read the same within the spread.
- The top bar is outside the window's damage and costs nothing here.

A card that is only partly under such a window counts as visible, so it is not frozen, and it is painted on
every one of that window's frames too. The same window over the card's right 200 pixels, graph included:

| State | Shipped | Graphs painted from JavaScript |
|---|---|---|
| Window away from the card | 4.48, 4.74 | 4.07, 4.05 |
| Window over the card's graph | 5.07, 5.27 | 6.48, 5.14 |
| The same, the graph alone behind an offscreen redirect | 4.72, 5.19 | 5.12, 4.30 |
| The same, the whole card behind an offscreen redirect | 4.18, 4.61 | 4.26, 3.83 |

- The shipped card costs about 0.55 points there. A graph painted from JavaScript costs 1.1 to 2.4: its paint
  code then runs on every frame somebody else causes.
- With the whole card behind the redirect, both read the same as with the window away.
- **The redirect does not change the look.** At scale 1.333, the card captured both ways differs by more than
  16 of 255 in 5 of 137,112 pixels, and its edge contrast is the same (3.446 against 3.444).

### 11. A fractional scale changes nothing

The shipped code at scale 1.333 (the nearest to the live panel's 1.25 that the virtual monitor offers; the
graphs then draw at a resource scale of 2), clean: covered 0.244 and 0.195, visible 0.260 and 0.320. That is not
above scale 1.

### 12. The live reading

Taken on 2026-11-10 with the owner away: the live shell (the laptop panel at scale 1.25, the shipped v2 code),
the extension toggled with `gnome-extensions`, 130 s windows, % of one core for the whole shell.

| State | Enabled | Disabled | Added by the extension |
|---|---|---|---|
| Card visible (desktop showing) | 1.04, 1.00 | 0.31, 0.55 | 0.45–0.73 |
| Card covered by a static window, top bar on | 0.69, 0.74 | 0.30, 0.20 | 0.39–0.54 |
| Card covered by a window repainting 15 times a second | 4.89 | 3.60 | 1.29 |

- **It agrees with the originating session's 0.45%** for the covered state, and is higher than the nested shell's
  0.26: the live heap is larger, and a real output has a KMS thread.
- **The forced collection is plain to see.** Read every 0.2 s, the main thread shows a burst of 22–56 ms every
  10.0 s while the extension is enabled: 13 or 14 in each 130 s window. Disabled, such bursts come 3 to 8 times
  and irregularly. Each is two or three missed frames at 60 Hz. Together they are about 0.3 points, most of what
  the extension adds in the covered state.
  *Corrected 2026-11-11: this counted only bursts exactly 10.0 s apart. Counting every burst of 10 ms or more,
  the disabled windows of this reading have 8, 17, 11 and 8, of 21 to 38 ms each: the stock shell's own
  collections. "About 0.3 points, most of what the extension adds" was too much; see "Measured on the live
  shell".*
- **A frame costs more on a real output.** From the live shell's own marks: 1.7 ms of dispatch with only the top
  bar drawn and 3.4 ms with the card, against 1.0 and 1.5 in the nested shell, plus 0.3 ms on the KMS thread.
- **The frozen card under a repainting window costs about 0.8 points at 15 frames a second,** after the tick's
  own cost is taken off. That is about 0.05 for each frame a second, more than twice the nested shell's figure.
  A terminal streaming output over the card is this case all day.
- **The sampler service was over its budgets on the loaded machine:** 0.41 and 0.58 with a watch held (budget
  0.25) and 0.13–0.16 with none (budget 0.1). Finding 13 says why.

### 13. End to end, the service is the larger half once the shell is fixed

- **The gjs sampler's cycles** (`perf record`, a watch held): 47% the JavaScript engine, 30% GLib, GIO and libc,
  22% the kernel doing the reads. So about three quarters of its cost is the runtime, not the work.
- **A compiled floor.** A 120-line Rust program doing the same reads (the fast tick's files every 2 s, 113
  cgroup leaves every 20 s, a JSON line built, nothing published) beside the real service for the same 110 s:

  | | CPU, % of one core | Resident memory | Private memory |
  |---|---|---|---|
  | gjs service, watched | 0.291 | 38.4 MiB | 11.9 MiB |
  | gjs service, unwatched | 0.192 | 37.2 MiB | 10.7 MiB |
  | Rust floor, scanning as if watched | 0.074 | 2.5 MiB | 0.2 MiB |

  A real compiled service would add D-Bus to that floor. The gjs figures are higher than the 0.16 and 0.07 the
  v2 design recorded because the machine was loaded.
- **Bursts make a watched service scan more.** Replayed through `lib/cadence.js`, five minutes of the live
  machine's real CPU history fire 5 scans a minute, against 3 for the plain 20 s cadence.
- **The service does not have the forced-collection problem** (finding 3): its collections are its own planned
  ones, 24 ms in 115 s.

## Every method, weighed

| Method | Measured gain | Cost, risk, upkeep | Verdict |
|---|---|---|---|
| Take Samples through a subscription on the shared connection, not a proxy | Forced collections 6 → 1–2 a minute (an idle shell's own rate); on the live shell about 0.3 points and a 22–56 ms burst every 10 s *(corrected 2026-11-11: no gain measured on the live shell while it collects by itself, on Wi-Fi or battery; see "Measured on the live shell")* | Small: `signal_subscribe`, `bus_watch_name`, `connection.call` replace the proxy | **Do.** The largest single win, and it removes a periodic hitch. |
| No periodic timers | About 1.3 ms a tick | Small: a watchdog re-armed by each Sample; the cover re-check rides on Samples and window signals | **Do.** Also makes a hung service show after exactly 6 s. |
| A lean tick while only the top bar is seen | Part of the factor of two to three under load | The snapshot is parsed when something that shows it asks | **Do.** |
| Draw the top bar only on a visible change, in whole device pixels, and only while mapped | Idle: no frame, 4.1–5.2 ms a tick → 0.5. Under load: nothing | A comparison before `queue_repaint()`; `ceil`, so an idle CPU stays inside one pixel | **Do.** |
| Draw the card through an offscreen texture, always | Under a repainting window: 1.2 points → 0.1–0.3 covered; 0.55 → 0 partly covered; 0.8 points on the live shell at 15 frames a second | One property; about 1 MiB of texture; the look is unchanged | **Do.** |
| Drop the subscription while nothing is visible (fullscreen) | Not measured; by construction the cost of the disabled state | Resubscribe and `GetState` on return | **Do.** *Not built in stage one: it conflicts with keeping a covered card fresh. See "Stage one as built".* |
| Graphs painted from JavaScript as GPU rectangles | None that can be measured over cairo drawn on change | New widget; JavaScript on every frame that touches it, 1.1–2.4 points under a 60 fps window unless cached | **No.** |
| The service renders the top bar to pixels; the shell shows them | At idle the shell is not woken: about 0.5 ms a tick. Under load: none that can be measured | A second signal, the shell's geometry told to the service, staleness moved to a supervisor | **Not in stage one.** It fits a compiled service (stage two). |
| A compiled sampler service | Floor: 0.074% against 0.291%; 2.5 MiB against 38 MiB | A second language and a build; about 1,500 lines to port with their rows | **Stage two** (decided). See below. |
| Native code inside the shell (a C or Rust actor) | At most the JavaScript left in a tick, about 1 ms | A fault there takes the whole session down; Clutter's ABI changes with every GNOME release | **No:** the first deal-breaker. |
| Draw from a separate window, as ding does | Not measured | Window-management patches in the shell; the cockpit design turns ding off for that reason; the top bar cannot be done this way | **No.** |
| Let St reload a picture the service writes to a file (no JavaScript at all) | Not measured | Rests on an St internal, and a stale picture would look live | **No.** |
| Top bar every 4 s on 2 s data | Not measured; about half of the loaded figure | A number up to 4 s old under the pointer | **Owner's call.** Not needed for the budgets below. |
| The gjs service sends only when something visible changed | At most the 0.5 ms a tick left at idle | A second signal, a keep-alive, a stall rule to redo | **Not in stage one.** |
| Formatting moved into the service | Small: hot formatting is microseconds | A wider protocol | **Not for cost.** |
| A smaller or binary payload | None: parsing is 3 µs | — | **No.** |
| Fewer D-Bus messages, a direct socket | None seen: the bus thread is 0.006% | Upkeep | **No.** |
| Relax the budget and change nothing | — | Leaves the collection every 10 s | **No.** |

## Design

### Two stages

- **Stage one: the shell side.** Everything under "Stage one" below. It changes no field of `ResourcePulse1` and
  no line of the service, so it ships at one login.
- **Stage two: a compiled sampler.** Its own design and plan, which the owner has asked for. "Stage two" below
  says what it would be and what it is worth.

### Principles

1. **Nothing owned only by JavaScript is touched by C on a tick.** That is what schedules the forced collection.
2. **No periodic timer in the shell while Samples flow.** The Sample is the tick.
3. **One tick, at most one frame.** Every surface updates in the same main-loop turn.
4. **A surface asks for a frame only when its pixels change,** and never while it is not mapped.
5. **What is not seen is not computed, and is not painted.** A covered card records nothing but the raw Sample,
   and is one cached rectangle to the compositor.
6. **No JavaScript in the paint path.** Drawing happens when the data changes, into a texture the compositor
   re-uses.
7. **Version skew stays additive.**

### Stage one: the client

- `PulseClient` keeps its interface (`cpuHistory`, `memoryHistory`, `latestSnapshot`, `lastGoodClockLabel`,
  `addListener`, `removeListener`, `setDetailWatchWanted`). Behind it:
  - `Gio.bus_watch_name_on_connection` follows the name's owner;
  - `connection.signal_subscribe` delivers `Sample`;
  - `connection.call` makes `GetState`, `WatchDetail` and `UnwatchDetail`, and `StartUnit`, as today.
  No `Gio.DBusProxy`. The injectable seams the rows use stay, with the subscription in place of the proxy factory.
- **Two kinds of listener.** A *history listener* (the top bar) is told on every Sample and reads only the
  histories. A *snapshot listener* (the card, the dropdown card, the hover label while shown) is told only while
  a detail watch is wanted. `latestSnapshot` parses the newest raw Sample when first read, so nothing is ever
  stale: it is parsed late, not skipped.
- **Staleness without a periodic timer.** Each Sample re-arms one 6 s timeout; it fires only on silence, exactly
  `SAMPLE_STALL_TICKS` intervals after the last Sample. Today's check runs on a 2 s whole-second timer and fires
  6–9 s after.
- **While nothing is visible** (the card covered and the top bar unmapped) the client drops its subscription and
  its watchdog. On return it subscribes and calls `GetState`, whose histories are complete, as after an unlock.
  *Not built in stage one: see "Stage one as built". The client stays subscribed while the extension is enabled.*

### Stage one: the cover check

- **While the card is visible** it runs on each Sample and on the window signals, as today.
- **While it is covered** it runs on the window signals, on `position-changed` and `size-changed` of the windows
  that cover it (so a window moved from the keyboard is seen), and on every fifteenth Sample as a backstop. The
  backstop also makes R21's dimmed repaint every 30 s. No timer.
- **With the service down** no Sample comes, so the watchdog's firing starts a 10 s fallback check, and the next
  Sample stops it.

### Stage one: drawing

- **The graphs stay `St.DrawingArea` and cairo.** What changes is when they draw: `queue_repaint()` is called
  only when the columns, in whole device pixels, differ from the ones last drawn, and only while the graph is
  mapped. A graph that was skipped while unmapped draws once when it is mapped again.
- **The memory bar and the three meters** already draw only on change. They are left as they are.
- **Labels** stay as they are: set only when the text differs.
- **The card is drawn through an offscreen texture, always** (`Clutter.OffscreenRedirect.ALWAYS`), frozen or
  not. It is painted into its texture when its own content changes, at most once a tick, and every other frame
  that touches its place paints one rectangle. The texture is about 1 MiB at the live panel's scale.
- **A frozen card keeps ruling R21 as it is:** dimmed, repainted every 30 s, so a card misjudged as covered never
  shows stale numbers as live. The 30 s repaint refreshes the texture.
- **Hiding a covered card was measured and costs the same.** It is not taken, because it would change what a
  misjudged cover looks like, and a card behind a translucent window would vanish.

### Stage one: the cockpit

The cockpit's drawing-side plan merged as #376 while this was being measured, and it does not know these
findings. Where it already agrees: bars are St widgets, rows are made once and re-used, there is no cairo. Where
it conflicts:

- its `CockpitClient` is built on a `Gio.DBusProxy` with handlers, "mirroring `PulseClient`", so every `Changed`
  would re-arm the forced collection;
- its pull-on-suspicion rides the 2 s cover re-check timer, which this design removes;
- its cards are frozen and dimmed while covered, and so painted under every frame drawn over them;
- its budget line is 0.1% at idle for the whole extension.

These are the rules the cockpit should be built under:

- **`CockpitClient` follows the same client rules:** no proxy, no periodic timer, a subscription only.
- **It subscribes only while the cockpit layer or the dropdown is visible.** Covered, which is most of the day,
  it receives nothing: no wake, no parse. On reveal it subscribes and calls `GetState`. `Cockpit1` needs no
  change for this.
- **A `Changed` is applied on the next Sample,** at most 2 s later, so the sampler's tick stays the one frame. If
  no Sample comes within 3 s it is applied by itself.
- **Cards are fixed-size St widgets updated by difference.** Rows are made once and re-used; a row's label,
  icon and bar change only when their value does. No actor is made or destroyed on an update.
- **Hover and tooltips** may cost frames only while the pointer is over a card.
- **Every card is drawn through its own offscreen texture, as the system card is.** The cost of painting under a
  repainting window grows with the number of actors, so it matters more for a grid than for one card. One
  texture for the whole layer would be about 33 MiB on the 4K screen at scale 2; one per card is about 2 MiB.

### Stage two: a compiled sampler (decided: yes, after stage one)

- **What it is.** `resource-pulse.service` as a small Rust program: the same reads, the same definitions, the
  same `ResourcePulse1` on the bus. The extension does not change, and cannot tell.
- **What it is worth** (finding 13): about a quarter of the CPU and a fifteenth of the memory. On the loaded live
  machine the gjs service was reading 0.13–0.16% unwatched and 0.41–0.58% watched, and holds 38 MiB. The cockpit
  adds a second gjs service of the same size, which could follow the same way.
- **Why Rust.** A separate process under systemd's caps is where a second language is safe: a fault there costs a
  restart and five minutes of history, never the desktop. Rust is installed, memory-safe, and has a D-Bus library
  that needs no C headers. C would need GLib's headers and gives up the safety; Go and Python hold more memory.
- **How the numbers stay the same.** The gjs sampler's fixture trees become golden: for every fixture both
  programs must print the same JSON, byte for byte after sorting keys. Only when that holds for all of them does
  the gjs sampler go.
- **What comes with it, because a compiled service makes them cheap:**
  - the service renders the top bar's two graphs to pixels and sends them only when they change, so at idle the
    shell is not woken at all;
  - systemd's watchdog (`WatchdogSec=`) turns a hung sampler into a restart, so "stale" is decided by the
    supervisor and the shell needs no stall timer for the top bar;
  - a cap on burst scans: replayed through `lib/cadence.js`, the live machine's real load fires 5 scans a
    minute against 3 for the plain cadence.
- **What it costs.** A build step in `./install` for those who opt in, a toolchain in CI, about 1,500 lines to
  port with their rows, and two languages in one feature. `lib/` stays JavaScript for the extension; the protocol
  is pinned by fixtures both sides read.
- **Order.** After stage one, as its own design and plan. Stage one goes first because it removes the hitch,
  needs one login and risks nothing in the service.
- **For that design to settle,** given the owner's priority of a minimal footprint: whether the cockpit service
  moves to Rust too, and whether one program can then serve both interfaces without a cockpit deploy costing the
  sampler its histories (a small state file would carry them across a restart).

### Faster reveal (not in this work)

Relayed by the v2 session as a follow-up the owner wants. It needs a service-side change and its own measurement,
so it is not part of stage one; it belongs with stage two. With this design a reveal already shows current
numbers in the frame that uncovers the card. What lags is the CPU half of "heaviest", which covers the window
since the last scan. One way to shorten it, not measured here: the service reads `cpu.stat` for the previous
scan's five leaders on every tick, about ten small reads, so a reveal's ranking is at most 2 s old for them, and
the full scan still finds new leaders.

## Stage one as built (2026-11-11)

Stage one was built from the plan, task by task, each reviewed and each checked in the isolated nested shell.
This section records where the build departed from the design above, why, and what it measured. Everything
above that it does not mention was built as written.

### Not built: dropping the subscription while nothing is visible

The design says two things that cannot both hold. It keeps ruling R21 as it is: a card judged covered is
dimmed and repainted every 30 s, so a card wrongly judged covered never shows stale numbers. And it drops the
Sample subscription while the card is covered and the top bar unmapped.

- **Where they collide.** The cover test is geometric, a card is always placed, and this repository's own
  Alacritty template is 90% opaque. A fullscreen translucent window unmaps the top bar and covers a card that
  is still seen through it.
- **What the drop would do there.** The dimmed card's numbers freeze for as long as the window is fullscreen.
  Publishing "no data" at the drop instead is honest, but then leaving fullscreen can show one frame of "no
  data" before the state arrives, and the card behind a translucent terminal reads "no data" all day.
- **What keeping both costs.** A 30 s pull while unsubscribed needs a second timer, a pulse state and new
  teardown paths inside the compositor, to save a few hundredths of a percent of one core only while a window
  is fullscreen.
- **Decided.** The client stays subscribed while the extension is enabled. The "Nothing visible" budget moves
  to stage two, where the service can send a slow signal for a covered card (follow-up 9). The link's
  subscribe switch, which then had no caller, was removed.

### Decided during the build

Each was a point the design left open, or a defect a review or a nested check found.

- **Calls go to the service's unique owner,** as the proxy's did, not to the well-known name. A watch sent
  across a restart could otherwise be counted twice by the new service. With no owner a call is answered with
  an error at once and nothing is sent. The Sample subscription keeps the well-known name as its sender, and a
  row proves a Sample from any other connection is not delivered.
- **"No data since" stays exact with late parsing.** An unread Sample is parsed before a Sample that appended
  no number replaces it, and both `latestSnapshot` and `lastGoodClockLabel` resolve the unread Sample when
  read. Otherwise a service that starts publishing numberless snapshots while the card is unwatched would
  leave the label naming the minute the card was last watched.
- **The watchdog after a state covers only what is left of the stall,** counted from the state's snapshot
  time. A full 6 s after a state already 5 s old would show old numbers as live for 11 s.
- **The top bar compares at the height it last drew at.** St allows `get_surface_size()` only inside a
  `repaint` handler; outside one it logs a critical and gives 0. The first version read it on the tick, so the
  comparison never matched and both graphs still repainted on every Sample, with nothing visibly wrong. The
  review and the nested check each caught it. A row now fails if the surface or the context is read anywhere
  but the repaint handler.
- **The covered card's 30 s clock is checked on every Sample,** not only at the fifteenth-Sample backstop. A
  backstop landing a moment before the 30 s are up would have skipped the dimmed repaint to 60 s.
- **A covering window is followed by four signals:** `position-changed`, `size-changed`, `unmanaged` and
  `workspace-changed`. The last two were added in review: a covering window closed, or sent to another
  workspace, would otherwise be noticed only at the backstop, where the old timer caught it in 2 s. The
  connections change only when the covering set changes.
- **The cover check's later and the teardown's disconnect loop are each guarded,** since a covering window's
  drag now runs the later on every frame, and one bad window must not leave the rest connected.
- **The `perf` request's frame budgets count over the disabled state's frames in the same run.** The nested
  panel's clock alone draws a frame a minute, and the covered card's dimmed repaint two or three.
- **A sixth count budget: the disabled state may make at most 4 major collections a minute.** A counter-test
  planted the old proxy, never released, and `perf` passed it: the defect outlived `disable()`, the disabled
  state made six collections too, and the relative budget saw six against six. With the proxy released at
  `disable()`, as the shipped client's was, the relative budget fails it in all four enabled states.
- **The replay restarts on every `scenario` request,** also for the word already playing, so "busy" is the
  same input every run and not an offset of the shell's start time.
- **Timers are guarded by rows in the state table, not by `perf`.** "Budgets" below says `perf` fails on a
  repeating timer. It does not look for one, and no count moves for a timer that draws nothing. One row,
  with a planted twin, pins every timeout the shell side adds, by file and count (GLib's two calls and
  GJS's own `setTimeout` and `setInterval`), so a new one fails until it is counted there on purpose. Three
  more rows say what the known ones are: none of the Sample interval, the extension's one is the fallback's,
  and the client's only timeout while Samples flow is the watchdog. The whole-branch review found the gap.

### The deploy restarts the sampler once

The plan said a deploy of this work restarts no service, since nothing under `service/` changed. That was
wrong. `./install`'s refresh step try-restarts a running unit when a module in its import closure changed
after it started, and this work adds names to `lib/constants.js` (in both services' closures) and to
`lib/protocol.js` (in the sampler's). So at the deploy the sampler restarts, its histories start again and
refill within five minutes, and the extension still running shows "no data" for a moment; the cockpit
service restarts too if it is running. Both changes only add, so nothing else follows. The whole-branch
review found it. No code was moved to avoid it.

### Measured after the build

The machine was never idle during the build: other sessions held its load between 3 and 6 on 8 cores, and
higher at times. So the closing readings were taken side by side, the shipped extension (`main` at 4589006)
and the built one in two isolated nested shells at the same moment, with the tooling of the baseline: the
replay service's input, the collection log, no in-shell counters, 60 s windows after a 40 s warm-up. % of one
core for the whole nested shell, three rounds, the median in brackets.

| State | Shipped | Built |
|---|---|---|
| Card covered, top bar on, idle input | 0.326, 0.280, 0.330 (0.326) | 0.079, 0.064, 0.075 (0.075) |
| Card covered, top bar on, light input | 0.342, 0.285, 0.330 (0.330) | 0.142, 0.138, 0.170 (0.142) |
| Card covered, top bar on, busy input | 0.365, 0.255, 0.329 (0.329) | 0.150, 0.156, 0.165 (0.156) |
| Card visible, top bar on, busy input | 0.418, 0.441, 0.372 (0.418) | 0.226, 0.391, 0.264 (0.264) |
| Card visible, top bar on, idle input | 0.528, 0.726, 0.410 (0.528) | 0.221, 0.705, 0.288 (0.288) |
| The main thread's median per tick, covered and idle | 2.87 ms | 0.53 ms |
| Major collections a minute, every state | 6 | 1 |

The nested `perf` request passed three runs out of three on the built branch. What the extension adds over
the same run's disabled state, with the probe's own counting included, median of three:

| State | Budget | Added | The main thread's median per tick |
|---|---|---|---|
| Card covered, idle input | 0.08 | 0.049 | 0.47 ms (budget 1 ms) |
| Card covered, busy input | 0.20 | 0.155 | 2.85 ms (budget 3 ms) |
| Card visible, busy input | 0.25 | 0.180 | 3.19 ms |
| Top bar hidden and card covered, busy input | 0.01, moved to stage two | 0.068 | 0.60 ms |

- **The counts,** in every run: major collections 1 or 2 in every state, the disabled one included; 3 frames
  a minute with the card covered and idle input, and 31 or 32 for 30 or 31 Samples under busy input; no
  top-bar paint while the top bar was hidden; the card's offscreen redirect always.
- **The gate was tested against the defect it guards.** With a proxy owned only by JavaScript planted and
  released at `disable()`, `perf` fails on the relative collections budget in all four enabled states (5 or
  6 against 1). With the same proxy never released it fails on the disabled state's own bound (6, more than
  4).
- **Under a window redrawing at the display's rate** the card as built costs what a hidden card costs, inside
  the noise, and switching the redirect off adds 1.3 to 2.4 points in each of five rounds. The whole
  extension against that state's 0.3 budget is not resolved: four valid rounds read -0.17, +0.05, +0.33 and
  +0.71 over the disabled shell (median 0.19), a spread wider than the budget, because the state itself, about
  4% of a core for the window's own frames, moved by half a point with the load.
- **The live shell** was read the evening it was deployed: "Measured on the live shell", below.

Raw output, the scripts and the full tables: `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-11-stage-one/`
(`result.md`).

### Measured on the live shell (2026-11-11)

The second live reading (the first is finding 12): the deployed stage one, the same script and settings, the
owner away. Then two traces of the live shell, which the owner ran as root. The laptop was on Wi-Fi and on
battery, at a load of 8 to 10, so every Sample changed the top bar. % of one core for the whole live shell,
130 s windows.

| State | Enabled | Disabled | Added | The first reading added |
|---|---|---|---|---|
| Card visible (desktop showing) | 0.763, 0.775 | 0.295, 0.255 | 0.47, 0.52 | 0.45–0.73 |
| Card covered by a static window, top bar on | 0.610, 0.770 | 0.243, 0.212 | 0.37, 0.56 | 0.39–0.54 |
| Card covered by a window repainting 15 times a second | 3.649 | 3.220 | 0.43 | 1.29 |

- **Under a repainting window the extension costs a third of what it did.** That is the offscreen redirect.
- **Covered and visible cost what they did,** within the spread of two windows each. The main thread's median
  per tick fell from 8–11 ms to 5.5–7.5 ms, and the bursts did not change.
- **The extension triggers no forced collection on the live shell.** The traces put kernel uprobes on GJS's
  toggle-notify function and on `JS_GC` for 130 s each, with the extension enabled: 143 and 977 toggles, 9 and
  13 forced collections. No object of the extension is among the toggles.
- **The stock shell forces them by itself.** What toggled, by GType and native stack: the network indicator's
  `NMClient`, on NetworkManager's 6 s Wi-Fi poll; the power indicator's proxy, on every UPower update, which is
  every 30 s while the battery charges or discharges (UPower's own record has the same seconds); the clock,
  each minute; other D-Bus proxies of the shell and of ubuntu-appindicators; IBus tasks freed by one
  collection, which arm the next; the dock; the mixer.
- **The rule, exactly.** GJS keeps one 10 s timer. When it fires, it collects only if something toggled down
  since it last fired: 24 of 24 windows in the two traces. Every call from native code into JavaScript re-arms
  it (`Gjs::Closure::invoke`, `GjsCallbackTrampoline::callback_closure` and object construction are among the
  eight call sites of `schedule_gc_if_needed`). So with a Sample every 2 s it fires every 10.0 s, and without
  one it waits for the shell's next toggle: about every 12 s in the disabled windows.
- **So the shell collects with the extension off.** Every burst of 10 ms or more on the main thread, per
  window: 14, 9, 7 and 9 with the extension disabled (211 to 280 ms, 0.16 to 0.22 % of one core, 20 to 30 ms
  each), against 13 collections with it enabled.

What the extension adds on the live shell, by part:

| Part | About, % of one core | Evidence |
|---|---|---|
| One frame per Sample: the compositor's own work | 0.15 | 68 to 73 frames a window at 2.9 to 3.1 ms each, from mutter's marks: 0.9 to 1.0 ms to paint, 1.5 ms to swap |
| The shell's collections coming sooner, and the tick that lands in each | 0.08 to 0.15 | 13 a window against 7 to 14; 24 to 36 ms each against 20 to 30 |
| The extension's own JavaScript per Sample | 0.05 or less | the main thread outside the bursts rises by 200 to 290 ms a window, and the frames are 195 to 220 of it |

- **What that means for stage one.** Its gains are where the nested shell measured them: a machine at rest,
  where no pixel changes and no frame is drawn, and a shell that is quiet, where the removed proxy was the
  difference between a collection a minute and one every 10 s. Neither was the state of either live reading.
  On a busy machine on Wi-Fi or battery the live cost is the frame and the shell's own collections, and stage
  one changes neither.
- **What it means for the budgets.** The live figures are about twice the nested budgets. The nested shell
  under-reads the live one twice: its frame is cheaper, and its shell does not collect by itself. On this
  display, anything that changes the top bar every 2 s costs at least the frame, about 0.15. Follow-up 11.
- **What it means for `perf`.** It stays the regression gate for what the extension itself does: its counts
  hold on the live shell (no collection of the extension's, about one frame a Sample). Its percentages are
  the nested shell's.

The readings, both traces and the tools: `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-11-stage-one/`
(`result.md`, `live-reading-2/`, `live-trace/`).

## Budgets

Measured as this session did: the nested shell, one at a time, the replay service's input, three 60 s windows
per state after a 40 s warm-up, the median of the three, without the in-shell counters, the disabled shell
subtracted. % of one core, added by the extension.

| What | Budget | Today | The variant (cairo drawn on change) |
|---|---|---|---|
| Card covered, top bar on, idle machine | 0.08 | 0.26 | 0.02–0.07 |
| Card covered, top bar on, busy machine | 0.20 | 0.26 | 0.09–0.18, once 0.29 |
| Card visible | 0.25 | 0.32 | 0.12–0.23 |
| Cockpit visible: four cards, the top bar | 0.5 | — | not built |
| Nothing visible | 0.01, moved to stage two (see "Stage one as built") | 0.17 | not built |
| Card covered, under a window redrawing 60 times a second | 0.3 | 1.2–1.3 | 0.1–0.3 |
| The main thread's median per tick, covered: idle, busy | 1 ms, 3 ms | 4–5 ms, 2.5–4.6 ms | 0.5 ms, 1.5–2.7 ms |
| Forced collections the extension causes | none | 6 a minute | none beyond the idle shell's 1–2 |
| Periodic timers in the shell | none | 2 | none |
| Frames | one a tick at most; none when no pixel changed | one a tick always | as budgeted |
| The sampler service, stage one | unchanged: 0.1 unwatched, 0.25 watched, 64 MiB | over both on the loaded live machine | unchanged |
| The sampler service, stage two | 0.05 unwatched, 0.1 watched, 8 MiB | — | floor 0.074 scanning as if watched, 2.5 MiB |

- **Why not keep 0.1 everywhere.** One Sample handled and one frame drawn is 1.5–2.7 ms a tick even in the best
  variant, which is 0.08–0.14. Under load the top bar has a new column to draw on every tick, so that is the
  floor of "a live top bar every 2 s". At idle nothing is drawn and the old 0.1 holds with room.
- **Why 0.2 is acceptable under load.** It applies when the machine is busy. On a machine running agents at
  three to six cores, 0.2% of one core is about a two-thousandth of the load. What mattered more was the hitch
  every 10 s, which goes. *Corrected 2026-11-11: the extension's own goes. The stock shell's remains wherever
  it collects by itself; see "Measured on the live shell".*
- **What halves it.** A top bar drawn every 4 s. The owner said laggy numbers are a deal-breaker, so this
  design does not take it; it is one constant if he wants it.
- **On the live shell** the same states cost about 1.7 times the nested figures, since a real output's frame
  costs more. There is no live percentage to pass; "The live reading" says what the second reading must show.
  *Measured 2026-11-11: about twice the budgets, 0.37 to 0.56 added in the covered and visible states at a
  load of 8 to 10; see "Measured on the live shell" and follow-up 11.*
- **The count budgets are the ones to guard.** Collections, timers and frames are whole numbers a check can
  assert. The percentages move with the core type and the machine's load: readings of one variant taken at
  different times differed by up to 0.2 points.
- **What gates a merge.** The counts do: the nested `perf` request fails on a repeating timer, on a paint while
  unmapped, on more than one frame a tick, and on more forced collections than the disabled shell showed in the
  same run. The percentages are reported, not gated. A median more than 0.05 over its budget is raised with the
  owner before merging. *As built, `perf` does not look for a timer; a row of the state table counts the
  shell side's timeouts instead. See "Stage one as built".*

## Testing and the measurement harness

- **Pure rows** (`gnome-shell/tests/`): the client's two listener kinds and late parsing; the watchdog (armed by
  a Sample, fires on silence at exactly the stall, never while Samples flow); the subscription dropped and
  restored; the top bar's column comparison at scales 1, 1.25 and 2 (a change inside one pixel draws nothing, a
  change across one draws once); the cover backstop count.
- **Static rows** (`scripts/test-resource-pulse.sh`): no `Gio.DBusProxy` and no repeating `timeout_add` in
  shell-side code; no `vfunc_paint` or `vfunc_paint_node` in it either.
- **Nested shell:** a new `perf` request on `scripts/resource-pulse-nested.sh` that starts the run with the GC
  log on, plays the replay service's scenarios and asserts the count budgets: forced collections, frames per
  tick, paints while unmapped, and the card's redirect under a repainting window. The harness's environment
  allowlist gains the two GC-log variables, with rows.
- **What moves into the repo, and what does not.** The replay service (gjs) moves to `gnome-shell/tests/nested/`.
  The `perf` request is bash, like the rest of the harness: it reads the scheduler counters as
  `scripts/resource-pulse-cost.sh` does and counts collections in the shell's log. The session's Python tools
  (per-thread series, capture reader, variants) stay in the handoff directory as the profiling kit; nothing in
  the repo depends on them.
- **`scripts/resource-pulse-cost.sh`** reads the scheduler's nanosecond counters in place of clock ticks, and
  reports the median per tick beside the mean.
- **Docs:** the guide's "What it costs" takes the budget table and the method; the v2 design's budget table
  points here; `CHANGELOG.md`.

## Constraints

- The four deal-breakers, all binding: desktop instability, wrong or laggy numbers, cost, upkeep.
- Drawing-side changes take effect at the owner's next login. Stage one has no service-side change, so it
  ships at one login.
- Stylesheet skew: classes are added, never renamed or removed while older code may still set them.
- It does not edit the cockpit's files or branches. The cockpit rules above go to that work through the owner.

## Order of work

- **This goes before the cockpit's drawing side** (decided). Both edit `extension.js`, `indicator.js` and
  `card.js`, and the cockpit's client, cards and layer are built on the client rules and the cached card, not
  converted afterwards.
- **The cockpit's drawing-side plan is amended for the four conflicts above.** That goes to the cockpit work
  through the owner; this work does not edit its plan or its files.
- **The build starts from current `main`,** and its first task re-takes the shipped baseline there: #375 enlarged
  every Sample (the longer app ranking), and rewrote parts of the test table and the harness this work extends.

## Ride-along items

Relayed by the session that built v2. The owner confirmed the split (2026-11-10).

| # | Item | Where it goes |
|---|---|---|
| 1 | The closure helper drops an import on a line that starts with a block comment | In: its own task |
| 2 | `extension.js`'s header says the timer schedules no frame | In: replaced when that timer is rewritten |
| 3 | Four row titles in `scripts/test-resource-pulse.sh` still state the pre-R23 rule | In: its own task |
| 4 | `gnome-status`'s "runs older code" ignores a newer unit file; the CHANGELOG's ⚠ list lacks two entries | In: its own task |
| 5 | A hung service is detected 6–9 s after its last Sample | In: the watchdog makes it exactly 6 s |
| 6 | A seeded client flashes "no data since" for tens of ms after an unlock | Out: follow-up 1 |
| 7 | The dim shows during the menu's close fade and a maximize animation | Out: follow-up 2 |
| 8 | Frozen values end up dimmer than the muted labels | Out: follow-up 3 |

## Follow-ups (not in this work)

Each is open until the owner closes it. The plan's last task copies this list into the pull request's
description, so it travels with the merge.

1. **The "no data since" flash after an unlock.** Needs a decision on what a seeded client shows before its
   first state.
2. **The dim during the menu's close fade and a maximize animation.** Needs a decision on whether the dim waits
   for an animation to end.
3. **Frozen values dimmer than the muted labels.** Needs a decision on how dim frozen values should be.
4. **Faster reveal.** Needs a service-side change and its own measurement; see "Faster reveal" above.
5. **The cockpit's drawing-side plan,** amended for the four conflicts under "The cockpit".
6. **The second live reading,** after the login that loads stage one. The first is finding 12. *Taken
   2026-11-11, with two traces: "Measured on the live shell". For the owner to close.*
7. **Stage two, the compiled sampler** (decided): its own design and plan, after stage one.
8. **The watched service's burst scans** under a bursty load (finding 13). With stage two, or as one constant
   before it.
9. **Nothing visible: no Samples at all** (added 2026-11-11, during the build). Stage one keeps the
   subscription under a fullscreen window, so a covered card stays fresh. Taking that state to zero needs a
   way to keep the covered card's 30 s repaint fresh without the 2 s Samples: with stage two, from the service
   side (a slow signal for a covered card). See "Stage one as built".
10. **The glue checks, in the repository** (added 2026-11-11, by the whole-branch review). The shell-side
    glue cannot run under plain `gjs`; its behaviour was proved by four scripts run in the nested shell
    (listeners, the watchdog, the top bar's repaints, the cover check with a real window), which live with
    the measurement tools outside the repository. Bring the cover check in as a nested request when the
    cockpit adds cards, and teach `perf`'s probe the cockpit's objects.
11. **The live cost against the budgets** (added 2026-11-11, by the second live reading). On the live shell
    the extension adds 0.37 to 0.56 % of one core at a load of 8 to 10, about twice the budgets, and about
    0.15 of it is the frame each Sample draws. Needs the owner's decision: accept it as the price of a top
    bar that moves every 2 s, or draw the top bar every 4 s while the card is covered, which halves the
    frames. A live reading on a machine at rest, wired and charged, would show what stage one gains where
    it was designed to.
12. **The stock shell's own collections** (added 2026-11-11). Its network and power indicators make it
    force a full collection about every 10 s on Wi-Fi or battery, with no extension. Not this
    extension's to fix; worth a report to GJS and gnome-shell with the traces.

## My calls (for the owner to check)

- The budget figures, and setting them per state.
- Keeping cairo and `St.DrawingArea`, and drawing on change: not the rectangle graphs, not service-rendered
  pixels in stage one.
- Drawing the card through an offscreen texture always, not hiding it while covered.
- Keeping the 2 s top bar.
- The backstop every fifteenth Sample, and the 10 s fallback while the service is down.
- No change to `ResourcePulse1` in stage one.
- Two stages, and Rust for the second (he agreed).
- Counts gate a merge and percentages are reported, as "Budgets" says.
- The live reading does not gate the design, and is taken again after the login.
- How the eight ride-along items are tracked: a task each for the ones in, "Follow-ups" and the pull request's
  description for the ones out.
- The measurement harness living in the repo, with rows, as part of this work.

## Left to the builder

- The seams that let the rows fake the subscription, the name watch and the calls.
- How the top bar reads its resource scale before it is mapped.
- The exact window signals for a covering window, checked in the nested shell with a real window.
- The names of the new constants.

## Reproducing every number

The tools and raw results are in `~/Projects/handoffs/resource-pulse-perf-tools/2026-11-10-performance-session/`;
its `README.md` lists each tool, the command for each experiment and which result file holds which table.

| Finding | Tool | Results |
|---|---|---|
| 1, 2 | `matrix.sh` | `matrix-unpinned.{txt,jsonl}` |
| 3 | `gc_trigger.sh`, `gc_layers.sh`, the `profile` experiment | `gc-trigger.txt`, `gc-layers.txt`, `r2/prof-*`, `r3/` |
| 4, 6 | `microbench.js`, the `pinned` experiment | `r1/microbench-visible.json`, `r2/base-pinned.jsonl` |
| 5 | the `perfrecord` experiment | `r2/base-perf-*.data` |
| 7 | `after_matrix.sh` | `r1/marks-*.syscap`, `r1/after-matrix.jsonl` |
| 8 | `passive_live.py`, one `GetState` of the live service | `passive-live.*`, `live-history/` |
| 9 | `variants.py` with the `scenarios` experiment | `r4/`, `r5/`, `r8/`, `r10/` (the four at once) |
| 10 | `busy_redirect.sh`, `partial_busy.sh`, `redirect_sharpness.sh` | `r6/`, `r7/` |
| 11 | the `fractional` experiment | `r6/frac-fractional.jsonl` |
| 12 | `live/live_reading.sh` | `live-results/` |
| 13 | `rust-floor/sampler_floor.rs`, `simulate_cadence.js`, `perf record` of the service | `rust-floor/` |
| Measured on the live shell | `live/live_reading.sh`; `live-trace/trace_shell_toggles.sh` (root), `analyze_trace.py`, `symbolize_stacks.py` | `../2026-11-11-stage-one/live-reading-2/`, `../2026-11-11-stage-one/live-trace/run-*/` |

`perf` needed `kernel.perf_event_paranoid` at 1; the owner set it back to 4 the same evening. The traces need
root: the script refuses to attach unless the installed GJS, GLib and GObject are the builds its addresses
were read from.

Sources read: GNOME Shell 50.1 `src/st/st-drawing-area.c`; mutter 50.1 `src/backends/meta-stage-impl.c`,
`src/core/meta-profiler.c`, `src/compositor/meta-cullable.c`; GJS 1.88.0 `gi/object.cpp`, `gjs/context.cpp`.
