# Resource Pulse: live CPU and memory in the top bar and on the desktop — design

**Status:** approved by Zvi 2026-11-08 (brainstorm, research, builder check and his answers recorded below). Implementation plan: docs/superpowers/plans/2026-11-08-resource-pulse.md.

**Amended 2026-11-08 (build):** the app scan runs every 10 s, not 6 s, and skips .mount/.socket/.swap/.automount/.path/.timer/.device leaves — measured cost 0.86% → ~0.42% of one core; see docs/GNOME_CONFIGURATION_GUIDE.md.

**Amended 2026-11-08 (nested run):** test in a nested shell only with scripts/resource-pulse-nested.sh — the plain --devkit recipe in Verification §2 reaches the live session (crash-guard file, logind, GDM, GeoClue, extensions.gnome.org). Every idle blank in GNOME 50 pushes the unlock-dialog session mode, so the extension is disabled on every blank as well as every lock (not only paused, as "Display off" below says), and its histories restart after either; by the user's decision they are not persisted.

**Amended 2026-11-08 (user decisions):** the memory half of "heaviest" names real apps only — "kernel & other" stays a candidate for the CPU half (kernel CPU such as reclaim and compression is a real "why slow" answer) but never for memory, and unattributed memory still counts in the MEM total. The "waiting on" meters are drawn cells (three per meter, a dash for no data), not ▮▯ glyphs, which are not in Ubuntu Sans and fell back to DejaVu Sans.

**Amended 2026-11-08 (final review):** swap is read from /proc/swaps — zram used = Σ Used of /dev/zram* entries, on disk = Σ Used of the others; zram orig_data_size under-counts zram's swap share (same_pages, slot use), so the original formula reported phantom disk swap.

**Amended 2026-11-08 (v2 architecture):** sampling moves out of gnome-shell into a systemd user service, and the extension only draws; "kernel & other" splits into "kernel" and "short jobs"; histories survive lock and blank. [2026-11-08-resource-pulse-service-design.md](2026-11-08-resource-pulse-service-design.md) wins wherever it disagrees with this document.

## Context

The user wants live CPU and memory state on this laptop: a **minimal** indicator in the top bar and a
**detailed** view on the desktop background, built to be correct, reliable and beautiful. The display is for
two human moments:

- **"Why is it slow?"**: name the bottleneck resource and the app causing it, within seconds.
- **Ambient pulse**: a calm, good-looking sense of state that never has to be asked for.

It is **not** for capacity planning. "Is there room for another agent?" and "is memory about to run out?"
are answered by the agent orchestration (rabota/hspawn gates), so this design adds **no alerts, no
notifications and no threshold alarms**.

Research found nothing off the shelf that meets the user's four deal-breakers. All four are
deal-breakers: desktop instability, wrong or laggy numbers, measurable cost, upkeep.

- **GNOME's own System Monitor extension:**
  - text only, and the user wants graphs;
  - hidden unless `gnome-system-monitor` is installed, and 26.04 ships Resources instead;
  - reads its stats synchronously on the shell's main thread.
- **Graph-capable third-party extensions:** Astra Monitor has open SIGABRT shell crashes. TopHat has an
  open bug where shell CPU grows over a session. system-monitor-next has an open "constantly freezing" bug.
- **Conky:** there is no native Wayland path on Mutter (no layer-shell), and under XWayland windows
  sometimes never appear on 26.04.
- **Re-rendering the wallpaper:** a 1 s crossfade plus a full 3072×1920 reload on every update.
- **azclock / Desktop Widgets:** text only, and it starts one subprocess per update.

The decision is therefore **one small extension of our own, in this repo, drawing both surfaces from one
sampler.**

## Decided by the user

1. **Desktop look: the "quiet card".** One small translucent card in a corner, holding:
   - big numbers with thin sparklines;
   - a "waiting on" line;
   - a "heaviest" line.

   **Build to this mockup.** It is the one the user picked, verbatim, rough ASCII:
   ```
   ╭─────────────────────────────╮
   │ CPU   23%   ▁▂▂▃▅▃▂▁▁▂▃▂▁▁▂  │
   │ MEM   16.4 of 30 GiB  ▕██████░░░▏│
   │ swap  1.6 GiB (0.4 in RAM)   │
   │                              │
   │ waiting on:  CPU ▮▯▯  mem ▯▯▯ │
   │ heaviest:  chrome · 6 claude │
   ╰─────────────────────────────╯
   ```
2. **Top bar: two mini graphs** (CPU, memory) with no numbers. The numbers appear on hover.
3. **Deal-breakers, all four:**
   - desktop instability;
   - wrong or laggy numbers;
   - cost (CPU, memory or battery);
   - upkeep.
4. **Change the extension rule.** "No extensions are enabled or disabled" becomes **"no third-party
   extensions"**, with one in-repo extension of our own.
5. **It lives in this dotfiles repo** and is **opt-in**. The repo is public under `quantivly`, and
   colleagues adopt it through `dev-setup`, so it must not switch itself on for them. It could be split
   out later with `git subtree split` if it is ever published.

6. **Agents stay one bucket in v1:** "herdr agents", with Resources one click away for process-level
   detail. Per-session cgroups are a **separate follow-up with its own design** (see the end of this
   plan).
7. **App CPU is a share of the whole machine:** 100% = all 8 cores, the same scale as the CPU total.
8. **The "waiting on" line includes `io`** next to CPU and memory.

The user did not correct either of these playback guesses:
- the indicator goes in the top bar, because the dock autohides;
- clicking it opens Resources.

## Facts this design rests on (measured on this machine, 2026-11-07)

- **Platform:** Ubuntu 26.04.1 LTS, GNOME Shell 50.1, Wayland only. Fractional scaling is on
  (`scale-monitor-framebuffer`, `xwayland-native-scaling`). The panel is 3072×1920.
- **The LTS freezes GNOME at 50.x**, so the extension targets `shell-version: ["50"]` and needs a port only
  at the next LTS. A mismatched shell refuses to load it, which is safe; the status check must make that
  visible.
- **CPU:** an Intel Core Ultra 7 258V, 8 cores, no SMT.
  - The core types come from the hybrid PMU: `/sys/devices/cpu_core/cpus` = `0-3` (P) and
    `/sys/devices/cpu_atom/cpus` = `4-7` (E).
  - `cpu_capacity` is 1024/1024/1005/1005/676×4, so an E core is about ⅔ of a P core.
- **Memory:** 30 GiB RAM. Swap is mostly **zram**: `/dev/zram0` is 15.2 GiB, zstd, priority 100, plus an
  8 GiB `/swap.img`. zswap is off.
  - At the time of measuring, 1.57 GB stored in zram occupied 398 MB of RAM (`mm_stat`).
  - `systemd-oomd` watches `user@1000.service` with a memory-pressure limit of 50% over 20 s.
- **PSI is available:** `/proc/pressure/{cpu,memory,io}`. CPU `some` avg10 sits at about 5% at rest.
- **Apps are already grouped into cgroups.** Ranking leaf cgroups gives app-level names cheaply: about 90
  cgroups, against 722 processes.
  - At the time of measuring: `app.slice/herdr-server.service` 15.7 GiB (all agent sessions; herdr makes
    no per-pane cgroups), Chromium scope 4.3 GiB, then nanoclaw, Slack, Chrome.
- **Resources is installed:** `net.nokyan.Resources.desktop`. `gnome-system-monitor` is not.
- **`show-desktop` is already bound** to `<Super>d` and others. That is the way to reveal the card when
  windows cover it.
- **ding** is enabled with all icons hidden. Its DESKTOP-type window has a background of
  `rgba(0,0,0,0.005)`: the card shows through it, and **ding receives every click**. So the card must be
  display-only.
- **Placement:** actors added to `Main.layoutManager._backgroundGroup` sit above the wallpaper, including
  after a wallpaper change. They are hidden in the overview, because `window_group` is hidden there.
- **Lock screen:** without the `unlock-dialog` session mode, an extension is disabled on lock and enabled
  again on unlock, so it must tear down completely.
- **CI and tooling:** `gjs` is installed locally. Every CI apt install must go through
  `.github/actions/apt-install`.
- **Nested-shell testing:** `gnome-shell --devkit` exists, but `mutter-dev-bin` (which provides
  `mutter-devkit`) is not installed. Installing it needs `sudo` in a real terminal.

## Design

### Every number, defined (the correctness contract)

These definitions go verbatim into the GNOME guide. The tests pin each of them.

| Number | Definition | Source |
|---|---|---|
| CPU busy % (total) | `1 − Δ(idle+iowait) / Δtotal` over the interval. `total` = user+nice+system+idle+iowait+irq+softirq+steal. guest/guest_nice are excluded because the kernel already counts them in user. 100% = every core. | `/proc/stat` `cpu` line |
| P / E busy % | The same formula over the per-CPU lines of each cluster. | `/proc/stat` `cpuN` lines, cluster map below |
| Cluster map | The hybrid PMU (`/sys/devices/cpu_core/cpus`, `/sys/devices/cpu_atom/cpus`). Fallback: group by distinct `cpu_capacity`. Fallback: one cluster, and the P/E row is hidden. | sysfs, read once at enable |
| Memory used | `MemTotal − MemAvailable`, shown as "16.4 of 30.3 GiB". It already includes zram's RAM cost. | `/proc/meminfo` |
| Swap | "1.6 GiB swapped (0.4 in RAM)". Stored = Σ zram `orig_data_size`. In RAM = Σ zram `mem_used_total`. **Swap on disk** = (SwapTotal − SwapFree) − Σ zram stored. It is shown only when it is above 0, as a separate "+ X on disk" note, because paging to disk is a real "why slow" signal. | `/proc/meminfo`, `/sys/block/zram*/mm_stat` |
| Waiting on | PSI `some avg10` for cpu, memory and **io**. It is a 10 s average by definition, so it lags on purpose. Meter bands: ▯▯▯ < 10%, ▮▯▯ 10–25%, ▮▮▯ 25–50%, ▮▮▮ ≥ 50%. The top band matches oomd's 50% kill limit. | `/proc/pressure/*` |
| App CPU | Each leaf cgroup's Δ`cpu.stat usage_usec` / (interval × ncpu), as a % of the whole machine, so it is comparable with the total. | cgroup v2 |
| App memory | Each leaf cgroup's memory **minus reclaimable page cache**: `memory.current − (active_file + inactive_file)`. This matches the MemAvailable semantics, so cache never counts as used. | cgroup v2 `memory.current`, `memory.stat` |
| "kernel & other" | A computed pseudo-app that ranks like any app. **CPU:** the root `/sys/fs/cgroup/cpu.stat` Δ minus the Σ of the scanned leaves. That covers kswapd, zram compression, writeback, `init.scope` and ssh `session-N.scope`. **Memory:** Memory used − the Σ of the scanned leaves' app memory. That covers kernel memory and zram's RAM, which no cgroup is charged for. It is clamped at 0. This keeps reclaim nameable, and the heaviest entries never silently add up to far less than the total. | root cgroup, `/proc/meminfo` |
| Heaviest | **One line**, as in the mockup: the top app by CPU, then the top app by memory, for example `Chromium 31% · herdr agents 15.7 GiB`. When the same app tops both, it collapses to `herdr agents 31% · 15.7 GiB`. | the two rankings above |

- **Units:** GiB with one decimal. Percentages are whole numbers.
- **First sample:** CPU needs a delta, so the first sample shows *no data*, never 0%.
- **Cgroups scanned:** the leaves of `user@<uid>.service/{app,session,background}.slice` and of
  `system.slice`, which covers docker and snapd.
- **Grouping by app:** scopes of the same app (for example two Chrome launches) are summed by app id.
- **App names:**
  - an `app-<appid>-<n>.scope` is named through `Shell.AppSystem` (its real name);
  - a `snap.<name>.*` cgroup is named after the snap;
  - a service is named after its unit, through a small alias table (`herdr-server.service` → "herdr
    agents");
  - a docker scope is named "docker".

### Top bar indicator

- **Two mini area-graphs side by side, no text:** CPU total, then memory used.
  - Each holds about 60 s of history (30 samples at 2 s).
  - They are drawn with `St.DrawingArea` and Cairo at the panel's scale factor.
  - CPU uses the theme accent (teal). Memory uses a second Yaru hue. Both carry a faint baseline so an
    empty graph still reads as an indicator.
- **Placement:** in the right box, just left of the system menu.
- **Hover:** after about 300 ms, a small label below the indicator reads `cpu 23% · mem 16.4 of 30.3 GiB`
  (styled like the dock's labels). It hides when the pointer leaves.
- **Click:** launches Resources. The fallback is `org.gnome.SystemMonitor.desktop`. If neither exists,
  the click does nothing, and hover still works.
- **No data:** the graphs show a gap or a muted flat line, and the hover label says "no data since HH:MM".
  **Stale numbers are never drawn as live.**

### Desktop card ("quiet card")

- **Placement:** the primary monitor, top-right of the work area, inset by a margin. It repositions on
  `monitors-changed` and work-area changes, which covers docking and undocking with external monitors.
- **Content, top to bottom.** It follows the mockup, with three small additions marked †:
  - **CPU:** the total %, with a 5-minute sparkline (150 samples).
    - † A dim `P 41 · E 6` suffix on the same line. It is not a separate row, so the card stays quiet.
  - **MEM:** "16.4 of 30.3 GiB" with a used bar.
  - **Swap:** "swap 1.6 GiB (0.4 in RAM)".
    - † "+ X on disk" when that is above 0.
  - **Waiting on:** "CPU ▮▯▯ mem ▯▯▯".
    - † An `io ▯▯▯` meter (the user's decision).
  - **Heaviest:** one line, as defined above.
- **Style:**
  - a translucent dark surface matching Yaru-prussiangreen-dark, with rounded corners and a 1 px subtle
    border;
  - **Ubuntu Sans with tabular numerals** (`font-feature-settings: "tnum"`), so digits don't jitter;
  - muted labels and bright values;
  - meaning is never carried by colour alone.
- **Display-only.** No reactive actors, because ding gets the clicks.
- **How it is seen:** on an empty desktop, or through `Super+D` (show desktop). It is not visible in the
  overview.

### Sampler, lifecycle, cost (the reliability contract)

- **One `Sampler` for the whole extension**, feeding both surfaces, so they always agree. It is created in
  `enable()` and fully destroyed in `disable()`, including every timeout, signal and actor. That makes
  lock and unlock cycles leak-free.
- **Fast tick, every `SAMPLE_INTERVAL_SECONDS = 2`:** reads `/proc/stat`, `/proc/meminfo`,
  `/proc/pressure/{cpu,memory,io}` and every `/sys/block/zram*/mm_stat`.
- **Slow tick, every `APP_SCAN_INTERVAL_SECONDS = 6`:** the cgroup scan.
  - It runs only while the card could be visible: not in the overview, not while the display is off.
- **All IO is asynchronous** through Gio, promisified.
  - No subprocesses, no GTop, no synchronous reads on the main loop, no network.
- **Reentrancy guard:** a tick is skipped, never queued, if the previous one is still in flight.
- **Display off (blanked, not locked):** sampling pauses. Lock disables the extension outright.
- **Errors:**
  - every tick is wrapped;
  - a failure becomes the *no data* state on both surfaces;
  - errors go to the journal, rate-limited (each distinct message at most once per 10 min), with a
    `resource-pulse:` prefix.
- **No preferences or GSettings schema in v1.** All tunables are named constants in one module.
- **Cost budget:**
  - **CPU:** gnome-shell CPU added by the extension averages **< 0.5% of one core** at idle.
  - **Memory:** gnome-shell RSS does not grow over 24 h, against a baseline.
  - **If the CPU budget is not met at 2 s:** lengthen the interval, never shorten the history.

### Repo integration

- **Code:** `gnome-shell/extensions/resource-pulse@dotfiles/`
  - `metadata.json` with `shell-version: ["50"]`;
  - `extension.js`, the Shell glue only;
  - `stylesheet.css`;
  - `lib/`: **pure modules with no Shell imports.** They cover the parsers, the cluster map, cgroup naming,
    the formatters and the PSI bands, so they run under plain `gjs -m`.
- **Link:** `install.conf.yaml` adds
  `~/.local/share/gnome-shell/extensions/resource-pulse@dotfiles` → the repo dir, for everyone. It is inert
  until enabled. GNOME on Wayland discovers it at the next login.
- **Enable (opt-in):**
  - a new `genable_extension <uuid>` helper in `scripts/apply-gnome-settings.sh` idempotently appends to
    `org.gnome.shell enabled-extensions` (the whole-value `gset` would clobber the list);
  - a commented line in `examples/gnome-settings.local.template` with a one-line description;
  - the user's own `~/.gnome-settings.local` gets the line uncommented.
- **Status:** `gnome-status` in `zsh/functions/system.sh` reports whether the extension is linked, whether
  it is enabled, and its `gnome-extensions info` State (ACTIVE / ERROR / OUT OF DATE). A silent failure
  after an update is then visible.
- **Tests:** `scripts/test-resource-pulse.sh` runs the `gjs -m` unit tests of `lib/` against fixtures.
  - Fixtures are this machine's real `/proc` and `/sys` captures, plus edge cases:
    - no zram, no hybrid PMU, one capacity;
    - the first sample with no delta, a counter that did not advance;
    - a cgroup that vanishes mid-scan, a malformed line, a missing PSI file;
    - disk swap in use.
  - It asserts its row total (`EXPECTED_ROWS`), per `scripts/check-state-table-totals.sh`.
  - The CI job installs `gjs` via `.github/actions/apt-install`.
- **Docs:**
  - **GNOME guide:** "Extensions — left as-is" becomes "Extensions — one of our own". Add a "Resource
    Pulse" section holding the definitions table, how to enable it, how to check it runs, and how to test
    in a nested shell.
  - **CLAUDE.md:** reword the GNOME line "stock GNOME/Yaru only — no third-party extensions or themes" to
    "no third-party extensions; one in-repo, opt-in extension". Spend no net bytes, and run
    `./scripts/check-claude-md.sh`.
  - **README.md:** around line 470 it has the same wording, so it gets the same rewording.
  - **Also:** a CHANGELOG entry, and this design committed as
    `docs/superpowers/specs/2026-11-07-resource-pulse-design.md`, satisfying the reachability guard
    (`docs/superpowers/` is working material; check what the guard requires).
- **No Linear issue.** Personal desktop work in this repo ships without a DO id (precedent: #337
  dock-wifi, #314 notifications). The branch is `zvi/gnome-customization`.

### My calls (flagged for the user to check)

- **Card placement:** top-right of the primary monitor only.
- **Intervals:** 2 s sampling, 6 s app scan, 60 s of top-bar history, 5 min of card history.
- **PSI meter bands** of 10/25/50%, to be tuned after a week of use.
- **No live blur** behind the card. A blur would re-render whenever windows move over it, so it is a
  solid translucent surface.
- **No preferences UI.**
- **Linked for everyone, enabled opt-in.**
- **Default session modes:** the extension is off on the lock screen and its history restarts after
  unlock.
- **A "kernel & other" pseudo-app** in both rankings.
- **One "heaviest" line, as in the mockup,** rather than separate "busiest" and "largest" lines.
- **The 24 h RSS rule.**
  - Baseline: gnome-shell RSS 10 min after enable.
  - **Pass** if growth after 24 h is ≤ 64 MiB.
  - Otherwise the check reports both numbers, and the follow-up is a day with the extension disabled to
    compare. It is a tripwire, not a proof.

### Left to the builder

- The exact palette within Yaru's hues.
- Graph rendering details.
- The hover-label mechanics.
- How to detect "display off" (for example `Meta.MonitorManager` power-save mode).
- Whether to read `memory.stat` for all cgroups or only the top-N by `memory.current`.
- The alias table's contents beyond herdr.
- The UUID and directory spelling.

## Implementation steps

**After approval:** this file is the design. The build starts by committing it as the spec, then turning it
into a task-by-task plan with `superpowers:writing-plans`, then executing that plan.

1. **Commit the design doc.** Run the reachability and budget guards.
2. **Write the `lib/` modules test-first,** against fixture captures:
   - parsers (stat, meminfo, PSI, mm_stat, cpu.stat, memory.stat);
   - the cluster map;
   - the delta math and its no-data rules;
   - cgroup → app naming and grouping;
   - formatters.
   Then `scripts/test-resource-pulse.sh` with `EXPECTED_ROWS`, and the CI job.
3. **The Sampler:** async reads, ticks, the reentrancy guard, pause and resume, error rate-limiting.
4. **The top-bar indicator:** graphs, hover label, click → Resources.
5. **The desktop card:** layout, styling, placement, and repositioning on monitor and work-area changes.
6. **Repo wiring:** the dotbot link, `genable_extension`, the template line, `gnome-status`, docs, the
   CLAUDE.md wording, the CHANGELOG.
7. **A nested-shell run** (below).
8. **Open the PR.** Squash-merge it once CI is green: never `--admin`, and rewrite the title and body to the
   final diff first. Then ff-deploy `~/.dotfiles`.
9. **Enable live on this laptop** via `~/.gnome-settings.local`, then one logout and login, then the live
   checks below.

## Follow-up (not in this project)

- **Per-session cgroups for agent sessions.** `claude()` / `hspawn` would start each session in its own
  `systemd-run --user --scope`, so the card names the session. It may also let `systemd-oomd` kill one
  session instead of the whole `herdr-server.service`; verify that before claiming it. This needs its own
  design, because it changes the agent launch path.

## Verification

1. **Unit tests and checks:**
   - `scripts/test-resource-pulse.sh` is green and its row total matches;
   - each definition has a row that one wrong formula would fail (for example counting cache as used, or
     counting guest twice);
   - `pre-commit run --all-files`;
   - `./scripts/check-claude-md.sh`;
   - `shellcheck` on the touched scripts.
2. **Nested shell before anything goes live,** from the worktree:
   - The user installs `mutter-dev-bin` in a real terminal (`sudo apt install mutter-dev-bin`).
   - Run `dbus-run-session gnome-shell --devkit --wayland` with an **isolated config and data**:
     - a temp `XDG_CONFIG_HOME` / dconf, so enabling the extension there cannot touch the live session's
       `enabled-extensions`;
     - a temp `XDG_DATA_HOME` whose `gnome-shell/extensions/` links to the **worktree's** extension dir.
       No live symlink points into a worktree.
   - Prove the isolation first: the live `gsettings get org.gnome.shell enabled-extensions` is unchanged
     afterwards.
   - Check that both surfaces render, hover and click work, and there are no JS errors in the nested
     shell's output.
*Steps 3–5 run after the merge and the ff-deploy, because the live link points at `~/.dotfiles` on `main`.
The extension is opt-in, so merging enables nothing until `~/.gnome-settings.local` says so.*

3. **Live correctness**, side by side with Resources, `free -b`, `cat /proc/pressure/*` and zram
   `mm_stat`, agreeing within rounding:
   - **CPU load:** a `stress-ng --cpu 4 --timeout 60` run must raise CPU total and the P/E rows plausibly,
     and "busiest" must name the app that holds the stress process (herdr agents, or Alacritty).
   - **Memory:** a 4 GiB allocation must raise MEM by about 4 GiB, and "largest" must follow it.
4. **Lifecycle:**
   - 20 lock and unlock cycles;
   - a dock and undock with an external monitor;
   - entering and leaving the overview.
   After all three, `gnome-extensions info resource-pulse@dotfiles` says ACTIVE and the journal holds no
   `resource-pulse:` errors.
5. **Cost:**
   - Measure gnome-shell `utime+stime` over 10 idle minutes with the extension disabled, then enabled. The
     added CPU must be < 0.5% of one core.
   - Record gnome-shell RSS, then **schedule the 24 h RSS re-check with `rabota schedule add`** (the
     run-later skill), never as a reminder for the user.
