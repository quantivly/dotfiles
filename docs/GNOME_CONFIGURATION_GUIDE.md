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
ding off, tooltips and a focus click): [the cockpit design](superpowers/specs/2026-11-09-desktop-cockpit-design.md).
Its data side is built ([The cockpit service](#the-cockpit-service)); nothing of it is drawn yet.

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

**Nothing on a timer.** While samples flow the shell side wakes for nothing else: the sample is the tick.
The top bar's graphs are redrawn only when a column changes by a whole device pixel, and only while the
top bar is shown. The card is drawn through an offscreen texture, so a window drawing over it does not
repaint it. Whether the card is covered is checked again on window changes, on the covering window's own
moves, and on a sample: every one while the card is visible, every fifteenth while it is covered. Only
while the service is silent and the card covered does a
10-second check run. The budgets, and the request that checks them: [What it costs](#what-it-costs).

**The dropdown.** Clicking the top-bar graphs opens a dropdown holding a second card, live while it is
open, and an **Open Resources** button (Resources, else System Monitor; hidden when neither is
installed). Resting the pointer on the graphs shows a one-line summary, never while the dropdown is
open.

### The cockpit service

A third part, opt-in: the data side of [the cockpit design](superpowers/specs/2026-11-09-desktop-cockpit-design.md),
built from [its plan](superpowers/plans/2026-11-09-desktop-cockpit-data-side.md). **Nothing is drawn yet: the
drawing side is the next plan.** Until it lands, nothing starts the service but you, and nothing reads it but
`gnome-status`.

**What it serves.** `cockpit.service` (`gjs -m service/cockpit.js`) is a second systemd user unit, apart
from the sampler, so a cockpit deploy never restarts the sampler or resets its histories. It serves JSON on
the session bus as `io.github.quantivly.dotfiles.Cockpit1` (protocol 1), at
`/io/github/quantivly/dotfiles/Cockpit1`:

- `GetState`: the layout, the config error (null when there is none), and three sources, each stamped with
  when it was sampled (`sampledAtUsec`) and its interval (`intervalSeconds`): `sessions` (the Claude Code
  sessions in herdr), `network` (the uplink, the VPN tunnel and the SSH control masters) and `mounts`
  (network shares and removable disks). Their fields are defined in
  [Every number, defined](#every-number-defined).
- `Changed`: the sources, or the layout, that changed; never sent on a timer.
- `WatchCockpit` / `UnwatchCockpit`: held while the cockpit can be seen. Watches are counted per caller and
  dropped when the caller leaves the bus, as the sampler's are.
- `FocusSession(id)`: focuses that session's herdr workspace, then its pane, and answers whether it did. A
  failure is an answer, never a D-Bus error: `focused: false` and an `error` code, one of `unknown-session`
  (no row has that id), `no-pane` (the row has no herdr pane), `herdr-rejected` (herdr refused, or its
  reply could not be read), `herdr-unreachable` (no socket, a refused connection, or no reply in 2 s) and
  `internal` (a fault in the service). herdr's own message goes to the journal, never to the bus:
  `cockpit: focus: <id>: <message>`. Once herdr focused the pane, the answer also names
  `windowPidCandidates`, for the shell to bring the window showing herdr forward: herdr's API lists no
  clients, so the service finds them in `/proc` (a `herdr` process with a controlling terminal; the server
  has none) and names each client's pid and its parents' (pid 1 left out, at most 64). A failure names none,
  and so does a fault while naming them, which is logged: the pane stays focused.

**Fixture mode.** With `RESOURCE_PULSE_COCKPIT_FIXTURE` naming a JSON file, the service runs no source,
reads no config and never asks herdr: it serves the file's `state` (re-read on change, as the config is) and
answers every `FocusSession` with its `focusReply`, and logs `cockpit: serving a fixture (<path>)`. The
file is read through the cockpit's refusing reader, so a path under a stat-only directory is never opened:
the service exits 1 instead. It is for the nested harness alone; the unit unsets the variable
(`UnsetEnvironment=`), so a user manager that carries it cannot make the unit serve a fixture.

**Stale.** The service sends `Changed` only when something changed, so a quiet source is not a dead one.
A source is stale once its `sampledAtUsec` is older than 3 of its own `intervalSeconds`
(`COCKPIT_SOURCE_STALE_INTERVALS`); the drawing side will pull `GetState` once before drawing one stale.

It runs in `background.slice` at `Nice=10`, capped at `CPUQuota=10%`, `MemoryHigh=64M` and
`MemoryMax=96M`; systemd restarts it 5 s after a crash, at most 5 times in 5 minutes. Its budgets are in
[What it costs](#what-it-costs). It logs to `journalctl --user -u cockpit.service`, every line prefixed
`cockpit:`. `./install` try-restarts it when `service/cockpit.js`, a module it imports, or its unit file
changed after it started, as it does the sampler; a cockpit that is not running is left alone, silently.

**Opt-in by file: `~/.config/resource-pulse/cockpit.json`** (under `$XDG_CONFIG_HOME` instead when that is
set). `./install` links the unit for everyone and enables it for no one: it has no `[Install]` section. Its
`ConditionPathExists` (on `%E`, which is `$XDG_CONFIG_HOME` or `~/.config`, where the service reads the
file too) makes systemd skip every start while that file is absent. The unit stays inactive, and that is
not a failure. To opt in, copy the template and start the service once by hand: nothing starts it yet.

```bash
mkdir -p ~/.config/resource-pulse
cp ~/.dotfiles/examples/resource-pulse-cockpit.json.template ~/.config/resource-pulse/cockpit.json
systemctl --user start cockpit.service
gnome-status        # cockpit: active, protocol 1, last publish …
```

The file names the monitor the cockpit will be drawn on (`monitor`, by `vendor` and `product`) and its card
groups (`groups`). Each group has an `id`, a `caption`, 1 or 2 `columns` and its `cards`, from `system`,
`apps`, `connections`, `sessions`, `health`, `seats`, `sol` and `work`; the groups' columns add up to at
most 4. `version` must be 1. Keys it does not know, such as the template's `_comment`, are ignored.

The service watches the file. An edit, a save that renames into place, a move or a delete is read again
200 ms after its first event, with no restart. A malformed file publishes no layout, and a `configError`
that names its first fault (`config: malformed JSON` for text that is not JSON at all); a deleted one
publishes the `configError` `missing`. The sources are served either way.

**Cadence.** Each source samples once at start, then on its own interval:

| Source | Interval | Also sampled at once on |
|---|---|---|
| `sessions` | 10 s while a watch is held, 60 s otherwise | nothing |
| `network` | 10 s | a change to NetworkManager's primary connection, its type, the connectivity or whether Wi-Fi is enabled |
| `mounts` | 30 s | a mount or an unmount (the mount monitor's `mounts-changed`) |

- `network` reads the route table and lists the SSH control sockets together, every 10 s: one cadence for
  both, so the listing costs one directory read per 10 s.
- On battery (UPower's `OnBattery`), every interval triples.
- A signal within 2 s of a source's last signal-driven sample gives one more sample at the end of those 2 s,
  not one per signal, counted on the monotonic clock so that setting the clock cannot stretch them.
- A signal while the source's sample is still running gives one more sample once that one ends, and at the
  earliest 1 s after the signal: a change made mid-sample does not wait for the next interval.
- A source whose signal cannot be watched logs one line and is still sampled on its interval.
- A sample still running when the next one is due is not started twice.
- A source that fails keeps its last object, stamp included, and logs one line; the others go on.
- Each request to herdr gives up after 2 s. With no herdr socket (`~/.config/herdr/herdr.sock`), or one that
  refuses connections, `sessions` has no rows and `herdrRunning` is false; that is not an error.

**The secrets rule.** The service hands the drawing side only fields it chose:

- **An allowlist.** Every source, the layout and every reply pass through a reader in
  `lib/cockpitProtocol.js`, and each builder writes only what its reader returns. A field no reader lists
  never leaves the service. The readers cap lengths too: a herdr workspace or pane id longer than 128
  characters reads as null, and a mount whose mount point is longer than 1024 is dropped.
- **Stat, never open.** The sources' file reader refuses, before opening it, any path holding `/.aws/`,
  `/.ssh/`, `/.credentials`, `/.zshrc.local`, `/.gitconfig.local` or `/.backup.local`
  (`STAT_ONLY_PATH_FRAGMENTS`). Those may be stat'ed, or listed when a directory: the SSH control sockets are
  counted, never opened, and a transcript is only stat'ed. It matches the path as given, so it is a guard,
  not a boundary. A table row also forbids those names anywhere in `service/` and `lib/` outside that list.
- **The name guard.** Every name published (a session name, an account, a mount label, a value quoted in a
  config error) is replaced by `—` when it is empty, longer than 64 characters, holds a control character,
  or matches one of `scripts/redact-secrets.sh`'s secret shapes (`lib/nameGuard.js`).

**What `gnome-status` says.** Under the `service:` line, one `cockpit:` line. The two you will usually see:

```
  cockpit: skipped (no ~/.config/resource-pulse/cockpit.json)
  cockpit: active, protocol 1, last publish 4 s ago, stale: none
```

- `skipped` needs the unit loaded and inactive with its condition unmet, **and** the file absent, because a
  unit that never ran also reads `ConditionResult=no`. With the file there and the unit never started, the
  line is `inactive (not running)`, and a ⚠ says to start it.
- `active` comes from `GetState`. The last publish is the latest `Changed`, or the start, so a quiet
  service's can be long ago, which is no fault. `stale:` names each stale source (`stale: sessions, mounts`).
- These come with a ⚠ naming the remedy:
  - `failed (not running)` and `activating (auto-restart: restarting after a failure)`: its journal;
  - `active, no answer`, when `GetState` did not answer within 3 s: its journal;
  - while the file exists: `inactive (not running)` (start it), `not installed (LoadState=not-found)`
    (run `./install`), `cannot load (…)` (`systemctl --user status`), and any other state, such as
    `activating (start)` (its journal). Without the file, none of these four warns;
  - `cockpit: config invalid: <configError>`, while the service runs: fix the file, which it rereads;
  - it **runs older code**: a module `service/cockpit.js` runs changed after it started (`systemctl --user
    try-restart cockpit.service`).
- These have no ⚠: `unknown (no systemd user manager answered)`;
  `active (gdbus not found, so not asked)`, an active unit not asked for `GetState` for want of `gdbus`;
  and `inactive (not running)` while the file is absent and `ConditionResult` is not `no`, a unit whose
  last start found the file (stopped since, and the file deleted).

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
| Heaviest | **One line**, as in the mockup: the top entry by CPU (an app, "kernel" or "short jobs"), then the top real app by memory, for example `Chromium 31% · herdr agents 15.7 GiB`. Names ellipsize to fit the card's fixed width; the numbers are never cut. When the top CPU entry is below 1% of the machine the CPU half reads `idle`. The halves collapse into one (`herdr agents 31% · 15.7 GiB`) only when they are the same group, never merely the same name: `docker.service` and `docker-x.scope` stay separate. The service also publishes the first 10 of each ranking (`cpuRanking`, `memoryRanking`, `APP_RANKING_LENGTH`) for the cockpit's apps card, which is not drawn yet. | the two rankings above |
| Names | The launcher prefix is matched before unescaping, so `app-gnome\x2dcalculator-1234.scope` is the app `gnome-calculator`. `org.gnome.SettingsDaemon.Power.service` is `gsd-power`; any other reverse-DNS unit drops its first two segments (`org.freedesktop.IBus.session.GNOME.service` is `IBus.session.GNOME`). A snap is named through `<snap>_<app>.desktop` when that exists, else by its snap name. | cgroup names |
| Session state | herdr's `agent_status` for the session's Claude agent: `working`, `blocked`, `idle` or `done`; anything else, or none, is `unknown`. A session is one herdr agent whose `agent` is `claude`. The source also counts the sessions in each state. | herdr's `session.snapshot`, over its socket |
| Session name | The first that is set of: the hspawn registry entry's `slug`, its `branch`, the herdr workspace's label, and the last segment of the session's cwd, through the name guard ([The cockpit service](#the-cockpit-service)). | `~/.local/state/hspawn/*.json` (by `pane_id`), herdr's snapshot |
| Session idle | `idleSeconds`: the age of the session's transcript, which Claude Code appends to while it works, in whole seconds. With no transcript found it is the age of the session's Claude process instead, and `idleFromProcessAge` is true: that is an upper bound. Null when neither is known. The transcript is stat'ed at `~/.claude/projects/<project>/<session id>.jsonl`, where `<project>` is the cwd with every `/` and `.` turned into `-`, else looked for in every `~/.claude/projects/*` and `~/.clauth/profiles/*/runtime-*/projects/*` (each directory listed at most once per sample). It is never opened. | the transcript's mtime; `/proc/<pid>/stat` field 22 and `/proc/stat` `btime` |
| Session memory | `memoryBytes`: VmRSS + VmSwap of the pane's Claude process, picked from herdr's `pane.process_info` as `hreap` picks it (its `argv[0]`'s file name is `claude`, or its `argv[0]` holds `/claude/versions/`, or its name is `claude`). Null when that process is gone. Sessions sort by it, largest first, and the source's total is the sum of the known ones. | `/proc/<pid>/status` |
| Session account | `account`: the session's `acct` sidebar token (the status-line hook publishes it), through the name guard. Null without one. | herdr's snapshot |
| Session context | `contextPercent`: the percent in whichever of the `ctx_ok`, `ctx_warn` and `ctx_crit` sidebar tokens the session has (`▅ 62%` gives 62). Null without one. | herdr's snapshot |
| VPN up | True when a route on a tunnel interface (`tun*`, `tap*`, `wg*`) goes via a gateway or is a default route. The interface named is the first tunnel interface in the table, up or not. | `/proc/net/route` |
| Uplink | `kind`: `wired` when NetworkManager's primary connection is `802-3-ethernet`, `wifi` when it is `802-11-wireless`, `none` otherwise. `connectivity`: NetworkManager's own verdict, `full`, `limited`, `portal` or `none`, and `unknown` for anything else. Beside them, whether Wi-Fi is enabled. With no NetworkManager on the system bus, all three are null. | NetworkManager's `PrimaryConnectionType`, `Connectivity`, `WirelessEnabled` |
| SSH masters | The number of entries in `~/.ssh/sockets`, listed and never opened: 0 when the directory is missing, null when it cannot be listed. | the directory's names |
| Mounts | Network shares (a filesystem type of `cifs`, `smb3`, `nfs`, `nfs4`, `fuse.sshfs`, `fuse.rclone`, `davfs` or `afp`) and removable disks (mounted under `/media/`, `/run/media/` or `/mnt/`); a network type wins. Sorted by mount point. The label is GIO's guess at the mount's name, else the mount point's last segment, through the name guard. Free and total are the filesystem's own, from a query that counts as failed after 2 s, as on a hung share: that row's sizes are then null, and the row stays. One query per mount point runs at a time. | the mount table (`GioUnix`), `filesystem::free` and `filesystem::size` |

The rows from Session state on are the cockpit service's, in `GetState`; nothing draws them yet.

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
  cockpit: skipped (no ~/.config/resource-pulse/cockpit.json)
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
- `cockpit:` is the cockpit service's line; its forms are in [The cockpit service](#the-cockpit-service).
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
that, with a copy of the checkout's extension enabled and its sampler and cockpit services on the same
private bus:

```bash
scripts/resource-pulse-nested.sh start        # prints the nested shell's private bus address
scripts/resource-pulse-nested.sh start --gc-log --replay   # or: collections logged to log/shell.log, fixed input
scripts/resource-pulse-nested.sh eval 'Main.extensionManager.lookup("resource-pulse@dotfiles").state'
scripts/resource-pulse-nested.sh screenshot card.png 2600 40 470 200   # x y width height, optional
scripts/resource-pulse-nested.sh scenario idle   # with --replay: idle, light or busy (busy until asked)
scripts/resource-pulse-nested.sh stop         # logs and screenshots stay in the run directory
```

Everything it creates is in one 0700 run directory under `$XDG_RUNTIME_DIR` (the path is
printed; `RESOURCE_PULSE_NESTED_BASE` picks another base, which must be yours with no group or
other access): a private runtime dir, HOME and XDG dirs, a private session bus that can activate
only dconf and a fake empty system bus with a fake GDM, both on path sockets inside the run
directory (never abstract sockets, which any local process could reach), an `env -i` allowlist (no
tokens, no live display or bus), nested settings that never lock, blank, use the network or check
for extension updates, and the extension-update apps masked. The run's own copies of the sampler
service and then the cockpit service start on the private session bus before the shell, with the same
allowlist, and the run refuses to go on when either does not own its name within 15 s (their logs are
`log/service.log` and `log/cockpit.log`, their pids `service=` and `cockpit=` in `state/run.values`).
The cockpit reads the config template, copied into the run's config home as
`resource-pulse/cockpit.json`; it finds no herdr there, and no NetworkManager or UPower on the fake
system bus. The extension's `StartUnit` finds no systemd there; that is expected, since it draws from
the service's samples whatever `StartUnit` answers. Unsafe mode (which
`eval` and `screenshot` need) comes from a throwaway helper extension that exists only in that
directory and refuses to act anywhere else, and `eval` and `screenshot` refuse a run whose
supervisor and recorded gnome-shell are not both running in its own session. A run lives at most 20
minutes (`setsid timeout`). `stop` ends the shell and both services, and signals only processes in the
run's own session, only while that session is still led by the run's own `timeout`: a run that
already ended is just cleaned up, since its session id may since belong to something else. Any
isolation step that fails stops the run with exit 2, and a shell whose unsafe-mode helper did not
load is reported within 15 s. It needs gnome-shell and a GPU, so CI does not run it; its hermetic
rows are in the suite below.

### What it costs

**Inside gnome-shell.** The extension runs in the compositor, so its cost is budgeted per state: what it
adds over the same shell with it disabled, in % of one core.

| State | Budget |
|---|---|
| card covered, top bar on, idle machine | 0.08 |
| card covered, top bar on, busy machine | 0.20 |
| card visible | 0.25 |
| card covered, under a window redrawing 60 times a second | 0.3 |
| the main thread's median per 2 s tick, card covered: idle, busy | 1 ms, 3 ms |

A percentage moves with the machine's load, so a change to the drawing side is gated on counts, which do
not. In a 60 s window:

| Count | Budget |
|---|---|
| major collections with the extension disabled | at most 4: more means something outlives `disable()` |
| major collections in any enabled state | at most one more than disabled |
| frames in any enabled state | at most the Samples, plus the disabled state's frames, plus 2 |
| frames with the card covered and idle input | at most the disabled state's frames plus 3 |
| top-bar paints while the top bar is hidden | none |
| the card's offscreen redirect | always |

`scripts/resource-pulse-nested.sh perf` measures both, in the isolated nested shell and never on the live
desktop:

```bash
scripts/resource-pulse-nested.sh start --gc-log --replay
scripts/resource-pulse-nested.sh perf   # about 9 minutes; exit 1 names every count budget it found broken
scripts/resource-pulse-nested.sh stop
```

- **What it does.** It opens one `gnome-calculator` window in the nested session and measures five states,
  each after its own `scenario` request and 40 s to settle, over one 60 s window: disabled; covered with idle
  input; covered with busy input; top bar hidden and covered; visible with busy input. It prints one line a
  state (CPU, the median per tick, collections, frames, Samples, top-bar paints, the card's redirect) and
  then a verdict. It needs `gnome-calculator` and `jq`; a count it could not take is exit 2, never a pass.
- **How to read it.** Run it three times. The counts must pass each time. The percentages are reported, not
  gated: take the median, and on a busy machine read them against the shipped extension measured at the same
  moment, not against the table. A collections budget broken by one, in one state of one run, can be
  chance (an idle shell makes one or two a minute): run it again.
- **Why these budgets.** `docs/superpowers/specs/2026-11-10-resource-pulse-performance-design.md` has the
  measurements behind each. Three things cost most: a D-Bus proxy object owned only by JavaScript made GJS
  force a full collection after every Sample; two 2-second timers cost as much as the Sample itself; and the
  top bar and a covered card were redrawn when no pixel had changed. The counts above guard the first and
  the third. No count moves for a timer that draws nothing, so the timers are guarded in the suite below:
  a row pins every timeout the shell side adds, by file and count, and a new one fails it until it is
  counted there on purpose.
- **Not budgeted yet: nothing visible.** With the top bar hidden and the card covered the extension still
  receives Samples, since a card judged covered may still be seen through a translucent window and is kept
  fresh. That state is `perf`'s fourth line; taking it to zero is stage two's.

**The services and memory,** at idle:

| What | Budget |
|---|---|
| the service, with a detail watch held | under 0.25% of one core |
| the service, with no watch | under 0.1% of one core |
| the service's resident memory | at most 64 MiB, flat over 24 h |
| the cockpit service, with a cockpit watch held | under 0.1% of one core |
| the cockpit service, with no watch | under 0.05% of one core |
| the cockpit service's resident memory | at most 48 MiB, flat over 24 h |
| gnome-shell's resident memory | flat over 24 h |

`scripts/resource-pulse-cost.sh` measures them, and is what `perf` reads the nested shell with. On the
live desktop it reads gnome-shell as a whole, so take a reading with the extension off and one with it on;
`--service` measures the service itself, found by its unit's `MainPID`. Read the service once with a
detail watch held (the card visible, or the dropdown open) and once with none (the card covered), each
over 10 idle minutes:

```bash
scripts/resource-pulse-cost.sh --cpu-percent 600            # gnome-shell CPU over 10 min, % of one core
scripts/resource-pulse-cost.sh --tick-median 120            # its main thread's median CPU per 2 s tick, ms
scripts/resource-pulse-cost.sh --service --cpu-percent 600  # the service's
scripts/resource-pulse-cost.sh --service --rss-kib          # the service's resident memory: at most 65536
scripts/resource-pulse-cost.sh --cockpit --cpu-percent 600  # the cockpit service's
scripts/resource-pulse-cost.sh --cockpit --rss-kib          # the cockpit's resident memory: at most 49152
scripts/resource-pulse-cost.sh --rss-kib                    # gnome-shell's resident memory
scripts/resource-pulse-cost.sh --rss-check <kib>            # exit 1 if gnome-shell grew more than 64 MiB since <kib>
```

It reads only `comm`, `status` and each thread's `schedstat` under `/proc`: CPU comes from the scheduler's
nanosecond counters, since `stat`'s clock ticks resolve only about 0.02% of one core over a minute, and a
counter it cannot read is exit 2, never 0%. `--cockpit` measures the cockpit service by
its unit's `MainPID`, as `--service` does the sampler. Either may stand anywhere on the line; the two
together are a usage error, and so is any other word left over (exit 2), never ignored. `--rss-check` is
gnome-shell's growth tripwire alone: `--cockpit --rss-check` (or `--service --rss-check`) is a usage error
too, which names that service's absolute budget, the figure its `--rss-kib` must stay under. To meet these
budgets the app scan's interval moved from v1's 10 s to 20 s while a detail watch is held and 60 s with
none. Over a budget, the remedy is a longer interval, or pruning slices that cannot beat the current
leader; never a shorter history. Before the service existed the sampling ran inside gnome-shell, measured in plain
`gjs` at about 0.5% of one core on the reference laptop: that work is the service's now. In plain
`gjs`, a full garbage collection after every scan held the service's resident memory flat at about
52 MB, where natural collection let it pile up to about 480 MB.

### Tests

`scripts/test-resource-pulse.sh` (1083 checks) runs the `gjs -m` unit tests of `lib/`, of the
service's sampler (synchronous reads against fixtures), of `PulseClient` (its JSON handling and
version-skew rows), of `CockpitClient` (the skipped-unit rule and pull-on-suspicion, on fakes) and of the
cockpit's herdr socket client (against a fake herdr speaking herdr's
framing on a socket in a temp dir). Those rows run only in a process started with no reachable bus and a config
home that cannot exist (`gnome-shell/tests/liveSessionBarrier.js`: `run.js` started any other way runs itself again
behind it), so a fake a row leaves out reaches no bus and no herdr socket, never the live session or system bus or
the live herdr. On a private bus of its own
(`dbus-run-session`, never the live session bus) it runs the service's D-Bus face, the client against it, the real `service/main.js`, the cockpit's D-Bus
face, the cockpit client against it and against a fake systemd that answers its StartUnit and unit read, and the real
`service/cockpit.js` (under a temp home, with no system bus, and a fake herdr and a
fake herdr client, a process named `herdr` in a terminal of its own, for `FocusSession`; then with a fault
injected into its `/proc` scan; then in fixture mode). It parses the Shell glue, enforces the no-blocking and `metadata.json` rules, and
covers `genable_extension`, `gnome-status`, the unit and its install step, the cost script and the
nested harness against stubs. It never touches the live session, but it is **not fully hermetic**: the
`service/main.js` rows sample this machine's real `/proc` and `/sys`, and the `service/cockpit.js` rows
its real mount and route tables and its processes' `/proc/<pid>/stat` lines. It needs `gjs`, `zsh`, `find`, `timeout`, `dbus-run-session`
(package `dbus-daemon`), `gdbus` (`libglib2.0-bin`) and util-linux's `script` (`bsdutils`): without any of them it
stops with exit 2. The card-width row also needs Pango's typelibs (`gir1.2-pango-1.0`) and the card's font,
Ubuntu Sans (`fonts-ubuntu`), and the row on the nested `perf` request's probe answers needs `jq`: without them
those rows fail. None is ever a pass.

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
