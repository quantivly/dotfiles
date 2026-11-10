# GNOME Configuration Guide

A clean, modern, keyboard-friendly GNOME desktop, applied reproducibly from the
dotfiles repo and built on **stock Ubuntu/GNOME only** — no third-party extensions
or themes to add bulk or instability.

Tested on **Ubuntu 26.04 LTS / GNOME Shell 50 (Wayland)**.

## Quick Start

```bash
gnome-apply     # Apply the curated desktop config (idempotent; safe to re-run)
gnome-init      # Create ~/.gnome-settings.local for machine-specific tweaks
${EDITOR:-vim} ~/.gnome-settings.local   # Set your dock favorites / launch keys
gnome-apply     # Re-apply (now includes your local overrides)
```

`gnome-apply` also runs automatically during `./install` (only on GNOME — it
no-ops on servers / other desktops). **Log out and back in once** after the first
apply to guarantee the dock relayout (see [Wayland note](#wayland-notes)).

## What gets configured

Everything is set via `gsettings` (the schema-validated front end to dconf). The
**portable core** lives in [`scripts/apply-gnome-settings.sh`](../scripts/apply-gnome-settings.sh);
**machine-specific** bits live in `~/.gnome-settings.local` (not tracked in git).

### Appearance — dark, green-tinted
- `color-scheme = prefer-dark`, theme/icons `Yaru-prussiangreen-dark`, accent `teal`
- Crisp font rendering (`font-antialiasing=rgba`, `font-hinting=slight`)
- Weekday + battery percentage in the top bar
- Fonts stay stock **Ubuntu Sans** (purpose-built; your terminal font is set in Alacritty)

### Dock — floating, autohiding, bottom
- Centered floating pill at the **bottom**, hidden until you hover the edge or press `Super`
- `extend-height=false`, `dock-fixed=false`, `autohide=true`, `intellihide=true`
- Slimmer icons (40px), dynamic transparency, **no** mounts/trash clutter
- Pinned apps (favorites) are machine-specific → set them in `~/.gnome-settings.local`

### Desktop — no icons
- All `ding` desktop icons hidden (home/trash/volumes/network/link-emblem/drop-place)
- The lightweight `ding` extension stays enabled, just invisible (fully reversible)

### Keybindings — tmux-friendly
- GNOME workspace switching is moved **off** `Ctrl+Alt+Arrow` onto `Super`-based
  shortcuts, so tmux's `Ctrl+Alt+Arrow` pane-resize works (see
  [CLAUDE.md](../CLAUDE.md) → *Terminal gotchas*, and
  [TMUX_LEARNING_GUIDE.md](TMUX_LEARNING_GUIDE.md)):
  | Action | Shortcut |
  |--------|----------|
  | Workspace left / right | `Super+Alt+←` / `Super+Alt+→` |
  | Workspace up / down | `Super+PageUp` / `Super+PageDown` |

### Power — no idle suspend
- `sleep-inactive-battery-type` and `sleep-inactive-ac-type` are `nothing`: GNOME never suspends
  on idle, so agents keep running with nobody at the keyboard. Screen blanking and the idle lock
  are unchanged.
- The **lid** is logind's, not GNOME's, so it is set by `dock-lid-setup`, not here: closing it
  locks the screen and never suspends. See [DOCK_LID_SUSPEND.md](DOCK_LID_SUSPEND.md).

### Extensions — one of our own
No third-party extension is installed, and none of the stock ones is enabled or disabled: the
decluttered look comes purely from hiding visible items. All stock Canonical extensions stay exactly
as Ubuntu ships them (`ding`, `ubuntu-dock`, `tiling-assistant`, `ubuntu-appindicators`, snapd/web
search providers). The one addition is **Resource Pulse**, an in-repo extension that is linked for
everyone and **off until you opt in** — see [Resource Pulse](#resource-pulse).

## Resource Pulse

A top-bar CPU and memory indicator, and a desktop card that adds swap, pressure and the heaviest apps
to answer "why is this machine slow right now". It lives in
`gnome-shell/extensions/resource-pulse@dotfiles/` (GNOME Shell 50 only). The design, and why the
sampling left the shell: [the service design](superpowers/specs/2026-11-08-resource-pulse-service-design.md).
The approved design for growing it into a desktop cockpit (a second service, a grid of cards on the 27",
ding off, tooltips and a focus click): [the cockpit design](superpowers/specs/2026-11-09-desktop-cockpit-design.md);
nothing of it is built yet.

### How it runs

It has two parts:

- **The sampler service**, `resource-pulse.service`: `gjs -m service/main.js`, a systemd user unit
  outside the shell. It does all the sampling, keeps both histories, ranks the apps and serves the
  result as JSON on the session bus (`io.github.quantivly.dotfiles.ResourcePulse1`). Its reads are
  synchronous, in its own process, so a slow read delays only its own next sample. It runs in
  `background.slice` at `Nice=10`, capped at `CPUQuota=10%` and `MemoryMax=128M`; systemd restarts it
  5 s after a crash, at most 5 times in 5 minutes.
- **The extension**, which only draws: the top-bar graphs, the desktop card and the dropdown. It
  reads no file and starts no process, and each of its D-Bus calls is asynchronous with a 2 s timeout,
  so the shell never waits on the service.

**Started on demand, never enabled.** The unit has no `[Install]` section, so nothing can enable it.
The extension's `enable()` asks systemd to start it (`StartUnit`, which is idempotent). A start counts
only once the service owns its bus name, within 15 s; until then the extension retries after 5 s,
30 s, then every 5 minutes. The extension never stops the service: opting out leaves it running until
logout, and `systemctl --user stop resource-pulse.service` stops it at once.

**Deploys.** `./install` links the unit, runs `systemctl --user daemon-reload`, and restarts the
service only when a module it runs, or its unit file, changed after it started
(`scripts/resource-pulse-service-refresh.sh`, which warns on a failure and never fails the install).
Each side runs its entry and every module that imports, directly or not, as
`scripts/resource-pulse-module-closure.sh` lists them: the service `service/main.js`, the shell
`extension.js`. So:

- a **data-side** change (`service/`, or a `lib/` module the service imports, such as
  `lib/cadence.js`) is live within seconds, with no logout. The extension sees the service come back
  and reads its state again; the restart starts both histories over;
- a **drawing** change (`extension.js`, `card.js`, `indicator.js`, `graph.js`, `pulseClient.js`, or a
  `lib/` module only the shell imports, such as `lib/visibility.js`) waits for the next login, because
  the shell loads an extension's JS once per login, and never restarts the service. A `lib/` module both
  import (`lib/protocol.js`) is both: the service runs it at once, the shell at the next login.
  `gnome-status` says when the desktop runs an older copy of that code;
- a **stylesheet** change is live at the next enable (the next lock or blank), since GNOME re-reads
  the stylesheet at every enable, while the JS that sets its classes waits for the login. So the rule
  this repo follows is that a stylesheet change only adds classes, and never renames or removes one
  the previous release's JS still sets;
- every other deploy leaves the service, and its histories, alone.

**Lock and blank.** GNOME 50 turns the extension off on every lock **and on every idle screen blank**
(a blank enters the lock screen's session mode even with locking off). The service keeps sampling, and
the next enable reads both histories back, so **the histories survive a lock or a blank**.

**Cadence.** Every 2 s (`SAMPLE_INTERVAL_SECONDS`) the service reads `/proc/stat`, `meminfo`, `swaps`,
`pressure/*`, and `mm_stat` of the zram devices `/proc/swaps` lists. The per-app cgroup scan runs:

- every 20 s while a **detail watch** is held, that is while the card can be seen or the dropdown is
  open, and every 60 s otherwise, so a reveal never starts from nothing;
- at once when a watch starts, at most once per 2 ticks, so rapid cover and uncover cannot set off a
  storm of scans;
- while a watch is held, at once when CPU busy rises 15 points above its value at the last scan, or a
  pressure meter's band rises (a burst, also at most once per 2 ticks);
- once more on the tick after a watch or burst scan, to sharpen a CPU ranking taken over a short
  window. No CPU ranking covers less than 1 s.

It skips leaves whose unit type never hosts an app (`.mount .socket .swap .automount .path .timer
.device`), and runs a full garbage collection after every scan. The top bar keeps 30 samples (60 s),
the card 150 (5 minutes).

**No data, never a stale number.** The first sample is *no data*, never 0%. When no sample has
arrived for 6 s (`SAMPLE_STALL_TICKS` × 2 s), both surfaces show "no data since HH:MM" and each
history gets one gap; they recover by themselves when samples resume. A service that restarted (its
samples are numbered from 1 again) shows no data until its state has been read afresh, and one that
is down shows no data while the extension retries its start.

**The card** has a fixed width: names ellipsize, numbers are never cut. It counts as covered when one
normal or dialog window on the primary monitor's active workspace fully contains it, or that monitor
is fullscreen (ding's desktop window never counts, and partly covered counts as visible). While
covered it is **dimmed**, repaints only every 30 s (still dimmed, from the latest state) and releases
its detail watch, so a card wrongly judged covered reads as stale, never as live; on reveal it repaints
at once, undimmed, and takes the watch again. `Super+D` reveals it without waiting for a sample.

**The dropdown.** Clicking the top-bar graphs opens a dropdown holding a second card, live while it is
open, and an **Open Resources** button (Resources, else System Monitor; hidden when neither is
installed). Resting the pointer on the graphs shows a one-line summary, never while the dropdown is
open.

### Every number, defined

| Number | Definition | Source |
|---|---|---|
| CPU busy % (total) | `1 − Δ(idle+iowait) / Δtotal` over the interval. `total` = user+nice+system+idle+iowait+irq+softirq+steal. guest/guest_nice are excluded because the kernel already counts them in user. 100% = every core. | `/proc/stat` `cpu` line |
| P / E busy % | The same formula over the per-CPU lines of each cluster. | `/proc/stat` `cpuN` lines, cluster map below |
| Cluster map | The hybrid PMU (`/sys/devices/cpu_core/cpus`, `/sys/devices/cpu_atom/cpus`). Fallback: group by distinct `cpu_capacity`. Fallback: one cluster, and the P/E row is hidden. | sysfs, read once when the service starts |
| Memory used | `MemTotal − MemAvailable`, shown as "16.4 of 30.3 GiB". It already includes zram's RAM cost. | `/proc/meminfo` |
| Swap | "swap 1.6 GiB (0.4 in RAM)". The lead number is zram's swap alone: Σ `Used` of the `/dev/zram*` areas in `/proc/swaps`. In RAM = Σ zram `mem_used_total` of those same devices, the only `mm_stat` files read (a zram device that is not a swap area does not count, and `/sys/block` is never listed). **Swap on disk** = Σ `Used` of every other area. It is shown only when it is above 0, as a separate "+ X on disk" note that adds to the lead number, because paging to disk is a real "why slow" signal. With no zram swap in use the line is "swap X GiB on disk"; with nothing in use, "swap none"; with `/proc/swaps` unreadable, "swap no data". zram's `orig_data_size` is not used: it under-counts zram's share of swap (same-filled pages, slot use), and a formula built on it reported disk swap that did not exist. | `/proc/swaps`, `/sys/block/zram*/mm_stat` |
| Waiting on | PSI `some avg10` for cpu, memory and **io**. It is a 10 s average by definition, so it lags on purpose. Each is a drawn meter of three cells (not glyphs, which fell back to another font): none filled < 10%, one 10–25%, two 25–50%, all three ≥ 50%. The top band matches oomd's 50% kill limit. With no data the cells give way to a dash, so it never reads as calm. | `/proc/pressure/*` |
| App CPU | Each leaf cgroup's Δ`cpu.stat usage_usec` / (interval × ncpu), as a % of the whole machine, so it is comparable with the total. | cgroup v2 |
| App memory | Each leaf cgroup's memory **minus reclaimable page cache**: `memory.current − (active_file + inactive_file)`. This matches the MemAvailable semantics, so cache never counts as used. A leaf at or under 64 MiB (`APP_MEMORY_STAT_MIN_BYTES`) ranks by `memory.current` as it is: too small to top the ranking, so its `memory.stat` is not read. | cgroup v2 `memory.current`, `memory.stat` |
| "kernel" | A computed CPU-only entry: the root `/sys/fs/cgroup/cpu.stat` Δ minus the Σ of the scanned **parent slices'** Δ, clamped at 0. The parents are listed afresh every scan: every slice directly under `user@<uid>.service` (`app.slice`, `session.slice`, `background.slice`, and any a `systemd-run --user --slice=` job makes) and every top-level slice but `user.slice` (`system.slice`, `machine.slice`, and any other), so a VM, a rootless container or such a job is named, not counted here. That leaves kernel threads, irq, reclaim, zram compression, PID 1, the user managers and login-session scopes. It is ranked only when every parent has a delta and both listings succeeded: with none read, "root minus zero parents" would name the whole machine. It is **not a memory candidate** (the user's decision): the memory half of "heaviest" names real apps only, and unattributed memory still counts in the MEM total. | root and parent cgroups |
| "short jobs" | A computed CPU-only entry: Σ over the scanned parents of max(0, the parent's Δ minus the Σ of its leaves' Δ). These are units that started and ended between two scans (timers, oneshots); a parent whose leaves exceed its Δ (read skew) adds 0. A leaf whose counter went backwards (a unit recreated at the same path) counts its current value; a leaf absent from the previous scan counts its full usage only when its parent was listed in that scan. | parent cgroups |
| Heaviest | **One line**, as in the mockup: the top entry by CPU (an app, "kernel" or "short jobs"), then the top real app by memory, for example `Chromium 31% · herdr agents 15.7 GiB`. Names ellipsize to fit the card's fixed width; the numbers are never cut. When the top CPU entry is below 1% of the machine the CPU half reads `idle`. The halves collapse into one (`herdr agents 31% · 15.7 GiB`) only when they are the same group, never merely the same name: `docker.service` and `docker-x.scope` stay separate. | the two rankings above |
| Names | The launcher prefix is matched before unescaping, so `app-gnome\x2dcalculator-1234.scope` is the app `gnome-calculator`. `org.gnome.SettingsDaemon.Power.service` is `gsd-power`; any other reverse-DNS unit drops its first two segments (`org.freedesktop.IBus.session.GNOME.service` is `IBus.session.GNOME`). A snap is named through `<snap>_<app>.desktop` when that exists, else by its snap name. | cgroup names |


### Enabling it

`./install` links the extension into `~/.local/share/gnome-shell/extensions/` and the service's unit
into `~/.config/systemd/user/`, which does nothing by itself. To turn it on:

1. Put `genable_extension resource-pulse@dotfiles` in `~/.gnome-settings.local` (the template has it
   commented; `gnome-init` creates the file).
2. Run `gnome-apply`. The helper appends the uuid to `enabled-extensions` (keeping every other entry),
   removes it from `disabled-extensions` (which wins over `enabled-extensions` in GNOME 50) and warns
   when `disable-user-extensions` is true, since then nothing user-installed loads, or when
   `allow-extension-installation` is false, since GNOME 50 then skips the user extension directory
   where the extension is linked.
3. Log out and back in once: GNOME on Wayland discovers a new extension only at login. The extension
   then starts its service itself.

To turn it off, remove the line and `gnome-extensions disable resource-pulse@dotfiles`. The service
runs on until logout; `systemctl --user stop resource-pulse.service` ends it at once.

### Checking that it runs

`gnome-status` prints, for example:

```
Resource Pulse: linked=yes enabled=yes state=ACTIVE
  service: active, protocol 1, last sample 1 s ago
```

- `enabled=` reads `enabled-extensions` itself, and says `yes (starts at next login)` while the shell
  does not know the extension yet (after linking, before the next login).
- `state=` is the shell's own verdict (`ACTIVE`, `ERROR`, `OUT OF DATE`), so a failure after a GNOME
  update is visible. When `enabled-extensions` asks for it but it is not `ACTIVE`, the next line names
  what keeps it from loading: it is also in `disabled-extensions`, which wins in GNOME 50, or one of
  the two settings above.
- `service:` is the unit's state, from its `LoadState`, `ActiveState` and `SubState`: for an active
  service, also the protocol and the age of its last sample, asked with `GetState` through `gdbus`.
  Every call to `systemctl` and `gdbus` is bounded at 3 s ("no answer", or "unknown", otherwise).
- A ⚠ line follows, with its own remedy, for each of:
  - the service **failed**, or is **restarting after a failure** (`auto-restart`): its journal;
  - while the extension is enabled (and not also disabled), from the first login after linking on:
    the unit is **not installed** (merged without `./install`: run `./install`); it **cannot load**
    (`systemctl --user status`); it is **not running** (`systemctl --user start`), except while the
    desktop runs an older copy, which may be the previous release sampling by itself; or it is still
    **starting**;
  - it does **not answer**, or it has **not sampled for more than 6 s**, compared to the
    microsecond as the extension does (it shows no data then);
  - it **runs older code** than the checkout: a module it runs (`service/main.js` or one it imports)
    changed after it started, as when the deploy's restart failed (`systemctl --user try-restart
    resource-pulse.service`);
  - **the desktop runs an older copy**: a module the shell runs (`extension.js` or one it imports)
    changed after this login, and takes effect at the next. A module only the service imports does not
    count, and neither does a stylesheet change, since GNOME re-reads the stylesheet at every enable;
  - it **cannot tell** either of the two above, because what `extension.js` or `service/main.js`
    imports could not be worked out (the line names the helper to run, which says why).

The service logs to its unit's journal, `journalctl --user -u resource-pulse.service`; the extension
logs under `resource-pulse:` in the shell's, `journalctl --user -b -g resource-pulse`. Each distinct
message appears at most once per 10 minutes.

### Trying changes in a nested shell

Never restart the live shell to test a change, and never use the plain
`dbus-run-session gnome-shell --devkit --wayland` recipe: even with its own config, data and cache it
writes the live session's crash-guard file, takes a logind inhibitor and sets the live session's
locked hint, registers with GDM and GeoClue, and posts your extension list to extensions.gnome.org.
Use `scripts/resource-pulse-nested.sh`, which starts a headless nested shell that can reach none of
that, with a copy of the checkout's extension enabled and its sampler service on the same private bus:

```bash
scripts/resource-pulse-nested.sh start        # prints the nested shell's private bus address
scripts/resource-pulse-nested.sh eval 'Main.extensionManager.lookup("resource-pulse@dotfiles").state'
scripts/resource-pulse-nested.sh screenshot card.png 2600 40 470 200   # x y width height, optional
scripts/resource-pulse-nested.sh stop         # logs and screenshots stay in the run directory
```

Everything it creates is in one 0700 run directory under `$XDG_RUNTIME_DIR` (the path is
printed; `RESOURCE_PULSE_NESTED_BASE` picks another base, which must be yours with no group or
other access): a private runtime dir, HOME and XDG dirs, a private session bus that can activate
only dconf and a fake empty system bus with a fake GDM, both on path sockets inside the run
directory (never abstract sockets, which any local process could reach), an `env -i` allowlist (no
tokens, no live display or bus), nested settings that never lock, blank, use the network or check
for extension updates, and the extension-update apps masked. The run's own copy of the sampler
service starts on the private session bus before the shell, with the same allowlist, and the run
refuses to go on when it does not own its name within 15 s (its log is `log/service.log`, its pid
`service=` in `state/run.values`). The extension's `StartUnit` finds no systemd there; that is
expected, since it draws from the service's samples whatever `StartUnit` answers. Unsafe mode (which
`eval` and `screenshot` need) comes from a throwaway helper extension that exists only in that
directory and refuses to act anywhere else, and `eval` and `screenshot` refuse a run whose
supervisor and recorded gnome-shell are not both running in its own session. A run lives at most 20
minutes (`setsid timeout`). `stop` ends the shell and the service, and signals only processes in the
run's own session, only while that session is still led by the run's own `timeout`: a run that
already ended is just cleaned up, since its session id may since belong to something else. Any
isolation step that fails stops the run with exit 2, and a shell whose unsafe-mode helper did not
load is reported within 15 s. It needs gnome-shell and a GPU, so CI does not run it; its hermetic
rows are in the suite below.

### What it costs

The budgets, at idle:

| What | Budget |
|---|---|
| gnome-shell, added by the extension | under 0.1% of one core |
| the service, with a detail watch held | under 0.25% of one core |
| the service, with no watch | under 0.1% of one core |
| the service's resident memory | at most 64 MiB, flat over 24 h |
| gnome-shell's resident memory | flat over 24 h |

`scripts/resource-pulse-cost.sh` measures them. The extension's cost lands in gnome-shell, so take a
reading with the extension off and one with it on; `--service` measures the service itself, found by
its unit's `MainPID`. Read the service once with a detail watch held (the card visible, or the
dropdown open) and once with none (the card covered), each over 10 idle minutes:

```bash
scripts/resource-pulse-cost.sh --cpu-percent 600            # gnome-shell CPU over 10 min, % of one core
scripts/resource-pulse-cost.sh --service --cpu-percent 600  # the service's
scripts/resource-pulse-cost.sh --service --rss-kib          # the service's resident memory: at most 65536
scripts/resource-pulse-cost.sh --rss-kib                    # gnome-shell's resident memory
scripts/resource-pulse-cost.sh --rss-check <kib>            # exit 1 if gnome-shell grew more than 64 MiB since <kib>
```

It reads only `comm`, `stat` and `status` under `/proc`. `--service` may stand anywhere on the line,
and any other word left over is a usage error (exit 2), never ignored. To meet these budgets the app
scan's interval moved from v1's 10 s to 20 s while a detail watch is held and 60 s with none. Over a
budget, the remedy is a longer interval, or pruning slices that cannot beat the current leader; never a
shorter history. Before the service existed the sampling ran inside gnome-shell, measured in plain
`gjs` at about 0.5% of one core on the reference laptop: that work is the service's now. In plain
`gjs`, a full garbage collection after every scan held the service's resident memory flat at about
52 MB, where natural collection let it pile up to about 480 MB.

### Tests

`scripts/test-resource-pulse.sh` (507 checks) runs the `gjs -m` unit tests of `lib/`, of the
service's sampler (synchronous reads against fixtures) and of `PulseClient` (its JSON handling and
version-skew rows). On a private bus of its own (`dbus-run-session`, never the live session bus) it
runs the service's D-Bus face, the client against it, and the real `service/main.js`. It parses the
Shell glue, enforces the no-blocking and `metadata.json` rules, and covers `genable_extension`,
`gnome-status`, the unit and its install step, the cost script and the nested harness against stubs.
It never touches the live session, but it is **not fully hermetic**: the `service/main.js` rows sample
this machine's real `/proc` and `/sys`. It needs `gjs`, `zsh`, `find`, `timeout`, `dbus-run-session`
(package `dbus-daemon`) and `gdbus` (`libglib2.0-bin`): without any of them it stops with exit 2. The
card-width row also needs Pango's typelibs (`gir1.2-pango-1.0`) and the card's font, Ubuntu Sans
(`fonts-ubuntu`): without them that row fails. Neither is ever a pass.

## Keyboard-driven workflow (no extensions needed)

- **`Super`** — Activities overview; just start typing to launch/search (your launcher)
- **`Super+Tab`** / **`Alt+Tab`** — switch apps / windows
- **Tiling** (built-in `tiling-assistant`): `Super+←/→` half-tile, `Super+↑` maximize,
  `Super+↓` restore, corners via `Super` + keypad. Tile side-by-side without an extension.
- Pin only a handful of apps; reach everything else from the overview.

## Customizing

### Pinned dock apps
App IDs differ per machine (snaps are `name_name.desktop`, system apps are
`org.gnome.X.desktop`). List the current ones and edit your local file:
```bash
gsettings get org.gnome.shell favorite-apps
${EDITOR:-vim} ~/.gnome-settings.local   # edit the favorite-apps line
gnome-apply
```

### Custom launch key, peripherals, theme variant
`~/.gnome-settings.local` ships commented examples for a `Super+Return → Alacritty`
binding, laptop touchpad options, and a neutral-grey theme variant. Uncomment and
`gnome-apply`. The helper `gset <schema> <key> <value>` is available inside that file.

## Backup & restore

There is no first-party GNOME export/import; the committed `gsettings` script is the
source of truth. For a full personal snapshot (everything, including machine state):
```bash
gnome-backup                       # → ~/gnome-dconf-YYYY-MM-DD-HHMM.conf
gnome-restore <backup-file>        # load it back (asks for confirmation)
```
These use `dconf dump/load` over `/org/gnome/` and are **not** committed to git.

## Wayland notes

- GNOME 50 is Wayland-only. Appearance, dock, desktop and keybinding changes apply
  **immediately**. Dock relayout / any extension toggles are guaranteed after one
  **log out / log in**.
- Do **not** use `Alt+F2` → `r` or `Meta.restart` — those are X11-only and do nothing
  (or error) on Wayland.

## Troubleshooting

**A setting didn't take.** Confirm GNOME sees it:
```bash
gnome-status
gsettings get org.gnome.desktop.interface color-scheme   # expect 'prefer-dark'
```

**Theme looks wrong / variant missing.** The script warns and skips if a Yaru variant
is absent. Check availability:
```bash
ls /usr/share/themes | grep -i prussiangreen
```

**`gnome-apply` printed success but nothing changed.** This happens when a
snap-confined terminal (e.g. the Alacritty snap) exports `GIO_MODULE_DIR` pointing
at a private cache that lacks the dconf GSettings backend — `gsettings` then
silently writes to an in-memory backend that never reaches the real database. The
apply script and `gnome-status` already drop `GIO_MODULE_DIR` to avoid this. If you
run `gsettings set` **manually** from such a terminal, prefix it:
`env -u GIO_MODULE_DIR gsettings set …`. Tell-tale sign: `gsettings get` and
`dconf read <path>` disagree.

**Dock still full-height after apply.** Log out and back in (Wayland relayout).

**Want desktop icons back.** They're only hidden, not removed:
```bash
gsettings set org.gnome.shell.extensions.ding show-home true   # etc.
```

**Reset everything to GNOME defaults** for a subtree (then re-apply):
```bash
dconf reset -f /org/gnome/shell/extensions/dash-to-dock/
gnome-apply
```

## See also
- [`scripts/apply-gnome-settings.sh`](../scripts/apply-gnome-settings.sh) — the settings, commented
- [`examples/gnome-settings.local.template`](../examples/gnome-settings.local.template) — machine-specific template
- [CLAUDE.md](../CLAUDE.md) — repo conventions and terminal gotchas

## Maintainer's record: the mechanism, the layers and their traps

The bullets below are the record behind the **GNOME Desktop Configuration** rules in
[CLAUDE.md](../CLAUDE.md) — what is applied by what, and the one trap that made `gnome-apply` print
two ticks while silently undoing a setting it had just applied.

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-627), from the tree at `18c70fb`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 18c70fb:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

- **Mechanism:** curated `gsettings` script (schema-validated, idempotent, reviewable), **not** `dconf dump` (which drags in machine-specific cruft). GNOME has no first-party export/import.
- **Source of truth:** `scripts/apply-gnome-settings.sh` (portable core). Runs automatically during `./install` on GNOME only (no-op on servers / other desktops).
- **Machine-specific layer:** `~/.gnome-settings.local` (dock favorites, custom launch keys) — mirrors the `~/.zshrc.local` pattern, sourced by the apply script, never overwritten. Create with `gnome-init`. It runs LAST and silently wins, so a line here can undo one the portable layer just applied: `grp:alt_shift_toggle` was re-enabled that way on every run, killing all four of herdr's `alt+shift+arrow` bindings while `gnome-apply` printed two ✓ lines three apart and `gsettings get` showed the override as if it were the applied value. An overriding set now prints `(overrides <previous>, set above)` — a note, not a warning, since overriding is what the layer is for.
- **Tmux integration:** the script moves GNOME workspace switching off `Ctrl+Alt+Arrow` onto `Super`-based shortcuts so tmux pane-resize works (the previously-manual fix is now baked in).
- **XDG user-dir guard:** `scripts/repair-xdg-user-dirs.sh` (alias `xdg-repair`) keeps `~/Desktop`, `~/Documents`, … as real directories so `snapd-desktop-integration` can't turn them into broken self-referential symlinks. Idempotent; `./install` runs it on graphical workstations (gated on `$XDG_CURRENT_DESKTOP` + `xdg-user-dirs-update`, skipped on servers). See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
- **Wayland gotcha:** changes apply live; dock relayout is guaranteed after one log out / log in. `Alt+F2 r` / `Meta.restart` are X11-only — never use them.
