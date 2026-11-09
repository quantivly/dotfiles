# Resource Pulse v2: a sampler service and a drawing-only extension

**Amends** [2026-11-07-resource-pulse-design.md](2026-11-07-resource-pulse-design.md). Where they disagree, this
document wins. Everything it does not mention stands. **Date:** 2026-11-08.

## Why

An independent review of v1 (a9ed51e) found nothing that could destabilise the desktop. Its verdicts are in
`~/Projects/handoffs/2026-11-08-resource-pulse-review.md`. It did show that one choice causes most of v1's cost and
UX limits: **the sampling runs inside gnome-shell, and on GNOME the shell is the compositor.** Every 10 s v1 reads
about 236 files with roughly 1,000 async completions on the thread that draws the screen. The consequences:

- its CPU time and memory churn land on frame rendering;
- GNOME disables extensions on every lock and screen blank, so the history resets and "heaviest" warms up from
  scratch each time;
- extension code loads once per login, so every change needs a logout, and the owner cannot log out regularly.

## Decided by the owner (2026-11-08)

1. **Stay on GNOME.** Keep the data side portable, so another desktop needs only a new drawing layer.
2. **Split** into a sampler service, a systemd user unit outside the shell, and an extension that only draws.
3. **Clicking the top-bar graphs opens the card as a dropdown,** with an "Open Resources" button inside it. Before,
   the click launched Resources directly.
4. **"kernel & other" becomes two entries,** "kernel" and "short jobs" (definitions below).
5. **A card fully covered by a window stops updating.** The owner also asked: "we'll need to work towards improving
   that". So the reveal must be as fast as this design can make it, and faster reveal stays a named follow-up.

## Goals, non-goals, anti-goals

- **Goals:**
  - the same look and the same numbers, as amended below;
  - no sampling work inside gnome-shell;
  - histories that survive lock and blank;
  - data-side changes that go live on deploy with no logout;
  - measured cost and memory budgets.
- **Non-goals:**
  - frontends for other desktops (the interface allows them later);
  - per-session agent cgroups (still a separate follow-up);
  - alerts or notifications.
- **Anti-goals:**
  - the shell ever waiting on the service;
  - a stale number drawn as live, across the process boundary as within it;
  - the service costing more than its caps;
  - a version mismatch between service and extension that does anything worse than show "no data".

## Architecture

### The service

- **Location:** `gnome-shell/extensions/resource-pulse@dotfiles/service/main.js`, run as `gjs -m` by
  `systemd/resource-pulse.service`.
  - It lives inside the extension tree because ES-module imports cannot leave the extension directory through the
    install symlink, and the shared `lib/` must be importable from both sides.
  - GNOME loads only `extension.js` and what it imports, so `service/` is never loaded into the shell.
- **What it owns:**
  - all sampling: the fast tick and the app scan;
  - the histories: the top-bar 30 samples and the card's 150;
  - the app ranking;
  - app naming, through `Gio.DesktopAppInfo`, since `Shell.AppSystem` is not available outside the shell.
- **How it reads:** it reuses `lib/` unchanged where it can. Its file reads are **synchronous**
  (`Gio.File.load_contents`, which reads to EOF whatever size kernfs reports). It is a separate process, so a slow
  read delays only its own next sample, and the async stream machinery v1 needed (about 4 completions per file) buys
  nothing here. Fewer wrappers also means less garbage.
- **Garbage collection:** it runs a full collection after every app scan. Measured in plain gjs, collecting every
  scan holds RSS flat at about 52 MB. Natural collection let native memory pile up to about 480 MB.

### The extension

- **Display only:** the top-bar indicator, the desktop card, and the card inside the dropdown.
- **`PulseClient`** replaces the in-shell `Sampler`. It keeps the interface the card and indicator already use:
  `cpuHistory`, `memoryHistory`, `addListener`, `removeListener` and the latest snapshot. Behind it is an
  asynchronous D-Bus proxy, and the card and indicator change only as the UX below needs.
- **No file IO and no subprocess in the shell.** The static check keeps forbidding both everywhere in the extension
  except `service/`, and the patterns grow to cover the calls the review found missing.

### Interface (session bus)

- **Name, object path and interface:** `io.github.quantivly.dotfiles.ResourcePulse1`, at object path
  `/io/github/quantivly/dotfiles/ResourcePulse1`.
- **`GetState() → s`:** JSON holding:
  - `protocol` (1);
  - `serviceStartedAtUsec`;
  - the latest snapshot;
  - both histories (fractions 0–1, `null` for no data, oldest first).
- **Signal `Sample(s)`:** JSON, once per fast tick. It carries the newest snapshot and the history values to append.
  Each payload has `sampledAtUsec` (real time) and a `sequence` number that grows within one service run.
- **`WatchDetail()` / `UnwatchDetail()`:**
  - A client holds a detail watch while the desktop card is visible or the dropdown is open.
  - The service counts watches per caller and drops a caller's watches when that caller's bus connection closes,
    so a shell crash or restart cannot leave a watch held.
- **Version skew is the normal state.** After a deploy the service restarts with new code, while the shell keeps the
  extension it loaded at login. So within `ResourcePulse1`, JSON changes are **additive only**:
  - the extension ignores unknown fields;
  - a missing field makes only its own row show no data;
  - a breaking change needs a new interface, `ResourcePulse2`, served beside `1` until the extension that reads `1` is
    gone.
- **Staleness across the boundary:** the extension shows "no data since HH:MM" when no `Sample` has arrived within
  `SAMPLE_STALL_TICKS` intervals (6 s). It also shows no data when the service's `sequence` restarts, until a fresh
  `GetState` arrives.

### Lifecycle

- **Starting:**
  - The unit has **no `[Install]` section**, so nothing ever enables it.
  - The extension's `enable()` asks systemd over D-Bus (`org.freedesktop.systemd1.Manager.StartUnit`,
    `resource-pulse.service`, `replace`), asynchronously; this is idempotent.
  - Opting in is therefore still the one `genable_extension` line, and nothing runs for anyone who has not opted in.
  - If the start fails, both surfaces show no data, and the extension retries with backoff: 5 s, 30 s, then every
    5 min.
  - **The extension never stops the service, and never restarts one that was stopped on purpose.** systemd's
    `Restart=on-failure` covers crashes. If the bus name loses its owner while the extension runs, the surfaces
    show no data until it returns, and the next `enable()` (the next lock, blank or login) calls `StartUnit` again.
  - **The extension draws whenever `Sample` signals arrive,** whatever `StartUnit` returned. The nested harness
    relies on this, because it starts the service on its private bus without systemd.
  - **Opting out leaves the service running until logout,** at the no-watch cost. `systemctl --user stop
    resource-pulse.service` stops it at once. Telling an opt-out apart from GNOME's lock and blank disables would
    take a fragile session-mode check, and a misfire would destroy the histories this design exists to keep.
- **Unit settings:**
  - `PartOf=graphical-session.target`, so it stops at logout;
  - `Restart=on-failure` with `RestartSec=5`;
  - `Slice=background.slice`, so it is scanned and appears in "heaviest" like any app, which is honest;
  - `Nice=10`, not idle scheduling, because it must keep sampling in the "why is it slow?" moment;
  - hard caps `CPUQuota=10%`, `MemoryHigh=96M` and `MemoryMax=128M`, so a bug costs at most a tenth of a core.
- **Deploy:** `./install` runs `systemctl --user daemon-reload` after linking.
  - It try-restarts `resource-pulse.service` **only when a file under `service/` or `lib/` is newer than the unit's
    start time.** Deploys happen several times a day, and most leave the data side alone, so their history survives.
  - A merged data-side change is live within seconds. The extension sees the name owner change, re-reads
    `GetState`, and keeps drawing. That restart resets the history, which happens only on data-side changes.
- **Stylesheet skew:** GNOME re-reads an extension's stylesheet on every enable but its JS only at login. So a
  stylesheet change must keep working with the previous release's JS until the next login: add classes, and never
  rename or remove one that JS still sets.
- **Lock and blank:** GNOME disables the extension, and the service keeps sampling. On re-enable, `GetState` returns
  the full histories, so **histories no longer reset after a blank.** This supersedes that Task 9 decision.

### Cadence and cost

- **Fast tick, every 2 s, always:** `/proc/stat`, `meminfo`, `swaps`, `pressure/*`, and `mm_stat` only for the
  `/dev/zramN` devices `/proc/swaps` lists. There is no `/sys/block` listing.
- **App scan while a detail watch is held:**
  - every `APP_SCAN_INTERVAL_SECONDS = 20` (was 10);
  - **plus a burst scan at once** when CPU busy rises 15 or more points above its value at the last scan, or any
    pressure meter's band rises (cooldown: 2 ticks);
  - **plus a warm-up scan on the next tick** after any scan started by a watch or a burst. A CPU ranking then covers
    a short window within 2 s.
- **App scan with no watch:** every 60 s. This keeps a baseline, so a reveal never starts from nothing.
- **Reveal:** when a watch starts, the service scans at once and publishes, at most once per 2 ticks, so rapid
  cover and uncover cannot set off a storm of scans. Memory is exact, and CPU covers the
  window since the previous scan (at most 60 s). The warm-up scan sharpens it 2 s later. So "heaviest" appears the
  moment the card is uncovered, and the numbers and graphs are current at once, because the service never stopped
  sampling.
- **Budgets, at idle,** measured by `scripts/resource-pulse-cost.sh`, which gains a `--service` mode:

  | What | Budget |
  |---|---|
  | gnome-shell, added by the extension | under 0.1% of one core |
  | service, with a detail watch held | under 0.25% of one core |
  | service, with no watch | under 0.1% of one core |
  | service RSS | at most 64 MiB, flat over 24 h |
  | gnome-shell RSS | flat over 24 h (the existing tripwire) |

  Over budget, the remedy is a longer interval, or pruning slices that cannot beat the current leader. It is never a
  shorter history.

## Definitions changed

- **kernel** (CPU) = the root's Δ minus the Σ of the scanned parents' Δ.
  - Scanned parents: `app.slice`, `session.slice` and `background.slice` under `user@<uid>.service`, plus
    `system.slice`.
  - **Ruling R22 (2026-11-09) replaces those four:** every `*.slice` directly under `user@<uid>.service` and every
    top-level `*.slice` but `user.slice`, listed each scan, so VMs (`machine.slice`), rootless containers and
    `systemd-run --user --slice=` jobs are named, not counted as kernel.
  - It covers kernel threads, irq, reclaim and zram compression, plus PID 1, the user managers and login-session
    scopes: system plumbing.
  - Its label is "kernel".
  - **"kernel" and "short jobs" are CPU-only entries.** The memory half of "heaviest" names real apps only, as the
    owner decided on 2026-11-08, and that decision stands. No figure for unattributed memory is shown.
- **short jobs** (CPU only) = the Σ over scanned parents of max(0, the parent's Δ minus the Σ of its leaves' Δ).
  These are units that started and ended between two scans: timers and oneshots. Measured 2026-11-08, it was 1.8–3.1%
  of the machine at idle, which v1 showed as "kernel & other". It ranks like an app, and it has no memory entry.
- **Leaf deltas:**
  - a counter that went backwards (a unit recreated at the same path) counts its current value;
  - a leaf absent from the previous scan counts its full usage, provided its parent was listed in the previous scan.
- **heaviest:**
  - the CPU half reads "idle" when the top entry is below 1%;
  - the two halves collapse into one only when they are the same group (`groupKey`), never merely the same name.
- **Names:**
  - the launcher prefix is matched before unescaping;
  - `org.gnome.SettingsDaemon.<X>` becomes `gsd-<x>` in lowercase;
  - any other reverse-DNS unit drops its first two segments;
  - a snap is named through `<snap>_<app>.desktop` when that exists.

## UX changed

- **Top bar:** it looks the same and hovers the same. A click opens a dropdown holding the card, a second card
  instance, with an "Open Resources" button. The fallback order is unchanged, and the button is hidden when neither
  app exists.
- **Card layout:** a fixed width. Names ellipsize by width (Pango); numbers are never cut. The desktop card stays
  display-only.
- **Covered:** the card counts as covered when one window on the primary monitor's active workspace fully contains
  its rectangle, or that monitor is fullscreen. Only normal and dialog windows count, so ding's desktop window,
  which spans the whole screen, never does. Partly covered counts as visible.
  - While covered, the extension stops repainting the card and releases its watch.
  - On reveal, it repaints at once from the latest state and takes the watch again. It checks every tick, and also
    on restack and minimize, so `Super+D` reveals without waiting for a tick.

## Testing

- **Service:**
  - the `lib/` rows, plus the sampler rows ported to synchronous reads against the same fixtures;
  - one D-Bus round trip on a private bus (`dbus-daemon --session` in CI): `GetState`, `Sample`, and a watch dropped
    when its caller disconnects;
  - the review's fixes, each with its row.
- **Extension:**
  - pure decision functions in `lib/`, each with a row: covered, watch wanted, paused under the shield, stale;
  - `PulseClient` JSON handling with skew rows: an unknown field is ignored, a missing field gives no data for that
    row only, and a sequence restart gives no data until a fresh state arrives;
  - the static checks.
- **Nested shell:**
  - the harness starts the service on its private bus, and the extension connects to it;
  - checks:
    - the overview and shield wiring;
    - reveal timing;
    - a pushed and popped lock mode, after which histories must survive;
    - the dropdown;
    - no extension errors in the log.
- **Cost:** `--service` readings over 10 idle minutes with a watch held and with none, plus the live in-shell reading
  after the owner's login.

## Repo wiring

- **`install.conf.yaml`:** one new link, `~/.config/systemd/user/resource-pulse.service`. It is never enabled, and it
  is inert until the extension starts it. `./install` reloads systemd and try-restarts the unit.
- **`gnome-status`:**
  - the Resource Pulse line also reports the service (active, protocol, age of the last sample);
  - it fixes v1's `enabled=no` before the first login;
  - it warns when the extension's files changed after the current login.
- **Docs:** the guide's definitions, cost and test sections; `CHANGELOG.md`; this amendment, linked from the v1
  spec.

## Left to the builder

- the JSON field names beyond those named here;
- the dropdown's styling;
- the backoff mechanics;
- whether slice pruning is needed (only if a budget is missed).

## Follow-ups (not in this project)

- Faster reveal, beyond "instant numbers, heaviest at once, sharpened in 2 s".
- A frontend for another desktop, if the owner ever moves.
- Per-session cgroups for agent sessions.
