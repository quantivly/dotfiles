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

A top-bar CPU / memory / pressure indicator and a desktop card that answers "why is this machine slow
right now". It lives in `gnome-shell/extensions/resource-pulse@dotfiles/` (GNOME Shell 50 only) and
runs inside the shell without ever blocking it: no subprocess, no synchronous file read, no network.
It samples every 2 s (`SAMPLE_INTERVAL_SECONDS`) and scans per-app cgroups every 10 s
(`APP_SCAN_INTERVAL_SECONDS`, every 5th tick), skipping leaves whose unit type never hosts an app
(`.mount .socket .swap .automount .path .timer .device`). The top bar keeps 30 samples, the card 150.
The first sample is *no data*, never 0%, and stale numbers are never drawn as live.

GNOME 50 turns the extension off on every lock **and on every idle screen blank**: a blank enters the
lock screen's session mode even when locking is disabled, and an extension without that mode is
disabled there. So nothing samples while the screen is blanked or locked, and both histories (the top
bar's 60 s, the card's 5 minutes) start over afterwards. That is by decision: the histories are not
kept across a blank or a lock.

### Every number, defined

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

"kernel & other" also absorbs the unit types the app scan skips and any cgroup that started or ended
between two scans.

### Enabling it

`./install` links the extension into `~/.local/share/gnome-shell/extensions/`, which does nothing by
itself. To turn it on:

1. Put `genable_extension resource-pulse@dotfiles` in `~/.gnome-settings.local` (the template has it
   commented; `gnome-init` creates the file).
2. Run `gnome-apply`. The helper appends the uuid to `enabled-extensions` (keeping every other entry),
   removes it from `disabled-extensions` (which wins over `enabled-extensions` in GNOME 50) and warns
   when `disable-user-extensions` is true, since then nothing user-installed loads.
3. Log out and back in once: GNOME on Wayland discovers a new extension only at login.

To turn it off, remove the line and `gnome-extensions disable resource-pulse@dotfiles`.

### Checking that it runs

`gnome-status` prints `Resource Pulse: linked=… enabled=… state=…`. The state is the shell's own
verdict (`ACTIVE`, `ERROR`, `OUT OF DATE`), so a failure after a GNOME update is visible. Problems
are logged to the journal under `resource-pulse:` (each distinct message at most once per 10 minutes):
`journalctl --user -b -g resource-pulse`.

### Trying changes in a nested shell

Never restart the live shell to test a change, and never use the plain
`dbus-run-session gnome-shell --devkit --wayland` recipe: even with its own config, data and cache it
writes the live session's crash-guard file, takes a logind inhibitor and sets the live session's
locked hint, registers with GDM and GeoClue, and posts your extension list to extensions.gnome.org.
Use `scripts/resource-pulse-nested.sh`, which starts a headless nested shell that can reach none of
that, with a copy of the checkout's extension enabled:

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
for extension updates, and the extension-update apps masked. Unsafe mode (which `eval` and
`screenshot` need) comes from a throwaway helper extension that exists only in that directory and
refuses to act anywhere else, and `eval` and `screenshot` refuse a run whose supervisor and
recorded gnome-shell are not both running in its own session. A run lives at most 20 minutes
(`setsid timeout`), and `stop` signals only processes in the run's own session. Any isolation step
that fails stops the run with exit 2. It needs gnome-shell and a GPU, so CI does not run it; its
hermetic rows are in the suite below.

### What it costs

`scripts/resource-pulse-cost.sh` measures gnome-shell, which is where the extension's cost lands.
Take a reading with the extension off and one with it on:

```bash
scripts/resource-pulse-cost.sh --cpu-percent 60      # gnome-shell CPU over 60 s, % of one core
scripts/resource-pulse-cost.sh --rss-kib             # resident memory
scripts/resource-pulse-cost.sh --rss-check <kib>     # exit 1 if it grew more than 64 MiB since <kib>
```

It reads only `comm`, `stat` and `status` under `/proc`. Measured on the reference laptop, the app
scan went from 0.86% to about 0.42% of one core when it moved from every 6 s to every 10 s with the
skipped unit types.

### Tests

`scripts/test-resource-pulse.sh` (197 checks) runs the `gjs -m` unit tests of the pure modules
against fixtures, parses the Shell glue, enforces the no-blocking and `metadata.json` rules, and
exercises `genable_extension` and the cost script against a stateful `gsettings` stub. It is
hermetic: it never touches the real session.

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
