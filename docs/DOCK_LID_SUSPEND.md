# Lid close: lock, never suspend

**Guide + maintainer's record.** What closing the lid does on this ThinkPad X1 Carbon Gen 13:
it locks the screen and never suspends. This page covers the dock holdoff that keeps that lock
out of the way while docking, how to install and check both, and the evidence behind them. The
operative rule is the `dock-lid-setup` line in [CLAUDE.md](../CLAUDE.md). GNOME's idle suspend,
the other way the laptop slept unasked, is switched off by `gnome-apply`
([GNOME_CONFIGURATION_GUIDE.md](GNOME_CONFIGURATION_GUIDE.md)).

## What the lid does

| the lid closes | result |
|---|---|
| undocked, on battery or on a charger | the screen locks |
| docked (the dock, or any external display) | nothing |
| within 30 s of any USB-C plug-in | nothing: the holdoff |
| (already closed) the charger is pulled, or the dock unplugged | nothing: that is not a lid-close |

Nothing about the lid suspends. The laptop sleeps only when asked to: Suspend in the system
menu, or `systemctl suspend`.

## Why it never suspends

Agents run on this laptop for hours with nobody at the keyboard. From 2026-10-21 to 2026-10-28
the journal holds ten suspends, by three paths:

| path | journal | count |
|---|---|---|
| lid closed on battery | `Lid closed.` and `Suspending...` in the same second | 3 |
| charger pulled with the lid already closed | the power-loss `Ping` (below), then `Suspending...` in the same second | 2 |
| a `Suspend` call over D-Bus, lid open | `The system will suspend now!` | 5 |

The first two are logind's lid handling, as this page configured it on 2026-10-19: suspend on
battery, and re-check a closed lid when the charger goes. Neither logind nor GNOME logs which
client made a D-Bus call. GNOME's default on battery, `sleep-inactive-battery-timeout=900`,
suspends after 15 min with no keyboard or mouse input, and an agent's work is not input. The two
D-Bus suspends whose battery state upower recorded (10-26 13:58 and 10-28 22:40) were on battery.
Some of the five may have been the menu; either way the idle timer sleeps unasked, so it is off.

The fix, 2026-10-29:

- **`logind/lid-locks-never-suspends.conf`** sets `HandleLidSwitch=lock`,
  `HandleLidSwitchExternalPower=lock` and `HandleLidSwitchDocked=ignore`.
- **It replaces `lid-on-power.conf`** (`HandleLidSwitchExternalPower=ignore`), which
  `dock-lid-setup` removes. logind reads drop-ins in name order, a later one winning, so left
  behind it would override the new file, and a lid closed on a charger would not lock.
- **GNOME never suspends on idle**: `sleep-inactive-battery-type` and `sleep-inactive-ac-type`
  are `nothing` (`scripts/apply-gnome-settings.sh`).
- **The power-loss re-check is retired**, below.

**Why `lock` and not `ignore`.** A suspend locked the screen on the way down, so closing the lid
secured the laptop. `ignore` would drop that silently; `lock` keeps it. logind takes `lock` only
on the lid-close **edge**: in v259's `manager_handle_action()` a `HANDLE_LOCK` returns early when
`!is_edge`, after the `handle-lid-switch` inhibitor check. So the re-checks logind runs while
the lid stays closed never lock, and the holdoff suppresses the lock as it used to suppress the
suspend.

## The dock holdoff

| files | covers a lid closed from |
|---|---|
| `udev/90-dock-lid-holdoff.rules` → `/etc/udev/rules.d/`, `systemd/dock-lid-holdoff@.service` → `/etc/systemd/system/` | ~0.1 s after the cable connects |

udev starts one instance of `dock-lid-holdoff@.service` per `typec_partner` add, through
`SYSTEMD_WANTS`. The instance is named `<kernel name>-<SEQNUM>`. Each instance takes a **block**
lock on `handle-lid-switch` with `systemd-inhibit` for 30 s, and logind ignores the lid while
any lock is held. Its own `HoldoffTimeoutSec=` uses the same mechanism after boot and resume, and
30 s matches that default.

It was built on 2026-10-19 against a worse outcome than a lock: a lid closed 1.8 s after plugging
in suspended into a half-enumerated dock and hung the laptop (below). The lid no longer suspends,
so what it prevents now is the screen locking just as you dock, before logind can see the dock.

**One instance per plug-in, not one unit.** Starting a unit that is already active does
nothing, so with a single unit a re-plug late in the window would keep the *first* plug-in's
expiry. The lock could then lapse before the re-plugged dock is visible. A boot with the dock
attached starts an instance too, because coldplug replays the `add`.

## The power-loss re-check, retired 2026-10-29

A second udev rule pinged logind when a Mains or USB supply went offline, at once and 5 s later,
so that a lid already closed on a charger was re-checked, and suspended, once the laptop was on
battery: logind watches input, graphics and seat devices, not power supplies, and re-checks a
closed lid after every event it handles. With the lid set to `lock` a re-check does nothing, so
the rule is gone. It caused two of the ten suspends above. Should the lid ever suspend again, the
rule is in git history, with the reason it pinged twice (a battery status that lags the charger,
below).

## Install, check, remove

```bash
cd ~/.dotfiles && dock-lid-setup          # install or resync; reloads systemd, udev and logind; checks
dock-lid-setup --check                    # read-only: see below
journalctl -u 'dock-lid-holdoff@*' -b     # one Started / Deactivated pair, 30 s apart, per plug-in
gnome-apply                               # the idle-suspend half
```

All three files are **copied** root-owned, never symlinked: root's logind, systemd and udevd
read them. Editing the repo copy changes nothing until `dock-lid-setup` is re-run. The
installer refuses to run from a worktree (`DOCK_LID_SETUP_ALLOW_WORKTREE=1` overrides it, to
test a branch). It validates first with `udevadm verify` and `systemd-analyze verify`, and
prints the parser's own explanation on a rejection. It removes the replaced `lid-on-power.conf`
**before** reloading logind, which would otherwise read it once more.

A warning that names the unit counts as a rejection: `systemd-analyze` reports an unknown key
and then exits 0. A warning about an *unrelated* unit does not count. `systemd-analyze` loads
the unit's whole dependency closure (sysinit, basic, every enabled socket and timer) and reports
on those too, so it runs with `--recursive-errors=no` and only lines naming this unit count.

`--check`, which the installer also runs last, fails on any of these:

- **A copy that is a symlink.** Root would then read a file you can write.
- **A copy that is not root-owned 0644, or differs from the checkout.**
- **The replaced `lid-on-power.conf` still installed.** Every live value can still be right,
  because logind has not re-read it since; the next reload would undo the policy.
- **A template systemd cannot load.** It reads `LoadState` of an instance, because a template
  cannot be asked about.
- **A logind not running with every setting the drop-in makes**, each read back over D-Bus.

It does not read `NeedDaemonReload`: a never-started instance is loaded fresh on every query,
so it always answers `no`. Every new instance reads the file on disk anyway.

logind is **reloaded, never restarted** — a restart ends every session on the machine. Its unit
is `Type=notify-reload`, and SIGHUP re-reads `logind.conf.d`. Where a reload does not take, the
check fails and names the reboot.

To remove: delete the three files under `/etc`, then `sudo systemctl daemon-reload`,
`sudo udevadm control --reload` and `sudo systemctl reload systemd-logind`.

## What is not covered

- **A closed laptop in a bag keeps working, and heating.** Suspend it from the menu before
  packing it.
- **The battery running out.** UPower's critical action still fires at 2 %
  (`/etc/UPower/UPower.conf`). It is the one stop left that nobody asks for, and the
  alternative is the battery dying.
- **Pulling the charger or unplugging the dock with the lid already closed does not lock.** It
  is not a lid-close. GNOME's idle lock does, 5 min later (`idle-delay` 300 s, `lock-delay` 0).
- **A lid closed within 30 s of plugging in any USB-C device**, a plain charger too, does not
  lock; nor does one closed while a USB-C partner flaps more often than every 30 s.
- **The kernel bug itself.** A suspend that starts while a dock is enumerating can still hang
  the machine. The lid no longer starts one, but Suspend from the menu in those seconds can.

## Evidence

### The hang that built the holdoff, 2026-10-19

The lid of this laptop (kernel 7.0.0-38, `s2idle` only) was closed 1.8 s after plugging it into
the Lenovo ThinkPad Thunderbolt 4 Dock. logind could see neither the dock nor its power yet, so
it treated the lid as an undocked lid-close and suspended. The dock finished enumerating
*during* the suspend, the suspend never completed, and the machine sat unresponsive until a
forced power-off 2.5 h later.

| time | journal |
|---|---|
| 11:02:36.48 | `thinkpad_acpi: undocked from hotplug port replicator` — logged on every **plug-in** on this machine, not only on unplug |
| 11:02:38.29 | `systemd-logind: Lid closed.` → `Suspending...` |
| 11:02:39.01 | `thunderbolt 0-1: Lenovo ThinkPad Thunderbolt 4 Dock`, then the dock's USB hub on `usb 3-2` |
| 11:02:39 | `systemd-sleep: Performing sleep operation 'suspend'...` — the last line of the boot |

Every suspend that completed in that boot logged the kernel's `PM: suspend entry (s2idle)`
right after `Performing sleep operation`; this one never did. Nothing reached pstore and the
firmware recorded no hardware error at the next boot: a hang, not a panic or a hardware fault.

### Timing of one plug-in, measured 2026-10-19

On the kernel's monotonic clock, from `udevadm monitor` and a 50 ms poll of `systemd-ac-power`
(the test logind itself applies):

| after the cable connects | signal |
|---|---|
| +0.00 s | `typec` `port1-partner` **add** — the earliest signal, and the holdoff's trigger |
| +0.58 s | `thinkpad_acpi` dock event |
| +1.78 s | `systemd-ac-power` says yes — `HandleLidSwitchExternalPower=` starts to apply |
| +3.05 s | Thunderbolt dock device added |

The 2026-10-19 lid-close came 1.81 s after the dock event, so the logind drop-in of the time
alone would have caught it by about 0.6 s, on one measurement. The first, single-unit holdoff,
on a real plug-in, took its lock 0.49 s *before* the dock event and released it 30.02 s later,
a margin of about 2.3 s on the same lid-close.

### What the design rests on, read in systemd v259's source

A review read `src/login/` and `src/core/device.c` at tag v259 to check each claim the guards
depend on:

- **A closed lid is re-checked when a lock is released.** On `Lid closed` logind installs a
  post-event handler that stays until the lid opens. It re-runs the lid decision, with docked,
  external power and battery all evaluated afresh, after every event logind dispatches. The
  inhibitor's fifo closing is such an event, and so is any D-Bus call.
- **`lock` is taken on the edge only** (read 2026-10-29, `logind-action.c`). The re-check
  above calls the lid decision with `is_edge` false, and `manager_handle_action()` returns
  before locking when it is. Every other action, `suspend` included, runs on a re-check too.
- **`handle-lid-switch` is honoured unconditionally.** `LidSwitchIgnoreInhibited=yes` (the
  default) bypasses only `sleep` locks.
- **`HandleLidSwitchDocked` is checked before `HandleLidSwitchExternalPower`**, and an unset
  `HandleLidSwitchExternalPower` falls through to `HandleLidSwitch`.
- **`systemctl reload systemd-logind` re-reads the configuration and drop-ins without touching
  sessions.**
- **A device unit's `Wants=` are started on every dead→plugged transition.** That is every
  re-plug. A unit already active is skipped, which is why the holdoff is per plug-in.
- **`$env{SEQNUM}` reads a real property.** sd-device stores a kernel uevent's `SEQNUM` as one
  (`device-private.c`). `udevadm test` builds its event from sysfs, without one, so there it
  substitutes as empty. That is why the instance name also carries `%k`: an empty SEQNUM still
  gives a valid name.

GNOME's gsd-power also holds a `handle-lid-switch` lock ("External monitor attached or
configuration changed recently") while an external monitor is attached, but not in the first
~3 s of a plug-in, which is the window here. It keeps the lock for a while *after* the monitors
go. gsd-power 50 does not read the `lid-close-ac-action` / `lid-close-battery-action` keys its
schema still lists: neither name is in the binary, so the lid is logind's alone.

### An undock with the lid closed, measured 2026-10-20

Under the suspend policy of the time. A 250 ms poll of what logind's lid decision reads: its own
`Docked` and `OnExternalPower` properties, and the supplies, battery and display connectors under
them. Times run from the kernel's `thunderbolt 0-1: device disconnected`, and each is the first
sample that showed the change, so an upper bound:

| after the dock disconnects | lid closed | lid open |
|---|---|---|
| dock monitors gone, `Docked` false | +0.35 s | +0.54 s |
| battery `Discharging`, `OnExternalPower` false | +0.77 s | +0.96 s |
| `Suspending...` | +12.9 s | — |

Each poll was a D-Bus call to logind, so logind re-checked the closed lid four times a second.
For 12 s it saw an undocked lid on battery and did not act. No holdoff instance was running, and
the only other `handle-lid-switch` lock on this machine is gsd-power's. A `handle-lid-switch`
lock is honoured whatever logind's settings, so this delay predates the guards. The journal's
suspend at 16:48 that day matches it: `undocked` at 16:48:32, `Suspending...` at 16:48:44. That
is why the count of unasked suspends above starts on 2026-10-21.

That explains an earlier replug test with the lid closed. The dock was back 6.7 s after
disconnecting, inside gsd-power's window, so the laptop never suspended, although the immediate and
the delayed power-loss pings had both fired. The battery read `Discharging` within 1 s on both
real unplugs measured; the delayed ping covered an ACPI driver that caches that status for 1 s.

### It had happened before, and survived

On 2026-10-11 at 21:56 (kernel 7.0.0-34) the lid closed in the same second the dock
enumerated, and logind suspended while the dock's USB hub was still coming up. That suspend
completed and resumed. One hang against one survival does not implicate the kernel update; it is
a race.

### The ten suspends, 2026-10-21 to 2026-10-28

From `journalctl -t systemd-logind`, with the battery state from upower's
`/var/lib/upower/history-charge-*.dat`, which starts on 2026-10-22:

| when | path | battery |
|---|---|---|
| 10-21 00:16, 14:34, 19:42 | D-Bus, lid open | not recorded |
| 10-22 20:22 | power-loss `Ping`; lid closed since 12:56 | charging at the last sample, 11:57 |
| 10-25 19:22 | lid | discharging from 19:22:10, charging at 19:18:52 |
| 10-26 13:58 | D-Bus, lid open | discharging |
| 10-28 12:45 | power-loss `Ping`; lid closed since 11:47 | charging at the last sample, 11:16 |
| 10-28 20:52 | lid | discharging |
| 10-28 22:40 | D-Bus, lid open | discharging, 15 % |
| 10-28 23:35 | lid | discharging from 23:32:25, charging at 23:28:46 |

upower writes a sample only when the charge changes, so a full battery on a charger leaves none.
At 22:40 the Bitwarden SSH agent had approved an `ssh-keygen` signature 3 s before the suspend:
something was working when the laptop slept.

### Designs not taken

- **`HoldoffTimeoutSec=`** applies only after boot and resume, never after a hotplug.
- **A `delay` lock.** logind refuses one for any `handle-*` lock ("Delay inhibitors only
  supported for shutdown and sleep"), and a delay on `sleep` is capped by `InhibitDelayMaxSec=`.
- **A single holdoff unit.** A re-plug inside its window does not extend it (above).
- **`HandleLidSwitch=ignore`.** It stops the lid suspending, as `lock` does, but leaves the
  screen unlocked. Until 2026-10-29 the lid was kept suspending on battery, so that a closed
  laptop in a bag would not stay awake; unattended agents made sleeping unasked the bigger cost.
- **GNOME's `lid-close-*-action` keys.** gsd-power 50 does not read them (above).

### Tests

State table: `scripts/test-dock-lid.sh` (65 checks, hermetic, CI `dock-lid-test`). It stubs
`sudo`, `systemctl`, `busctl`, `udevadm` and `systemd-analyze`, and runs `install` and `rm` for
real under a prefix the stub confines them to.

The stubs model state rather than fixed answers, and only what the real tools do:

- **A logind reload snapshots the drop-ins at that moment**, reading them in name order with a
  later file winning. `busctl` answers the three lid properties from the snapshot, falls back to
  logind's own defaults (`suspend`, `""`, `ignore`) for one no drop-in sets, and refuses any
  other. So reloading before copying, or before removing the replaced drop-in, fails a row, and
  so does a check that reads only one property.
- **`systemctl show -p LoadState` answers from the template on disk.** Real systemd needs no
  daemon-reload for that.
- **`systemd-analyze verify` names the file in a warning**, and fails on an unrelated unit's
  error unless `--recursive-errors=no` is given.

The real `udevadm verify` and `systemd-analyze verify` check the shipped rule and unit. The
rule line, the unit's `ExecStart` and the logind drop-in are asserted exactly, because
`udevadm verify` accepts a rule that never fires.

**First mutation sweep, 2026-10-19: 27 mutants, 27 killed.** 19 were in the installer, 8 in the
shipped files. Each mutant was checked to change its file before it ran. The first round left
two alive, both for one reason. **Bash suspends `set -e` inside a function called from an `||`
list.** The install path calls the check as `check_installed || exit 1`, so the row that removed
`busctl`'s `|| true` exercised a path where it could not matter. Only `--check`, a plain call,
can die silently there, and it now has its own row. The other survivor was `exit $?` after
that plain call. It was equivalent: under `set -e` a failed check had already exited. The code
now says so and ends in `exit 0`, and a mutant flipping that is killed.

**That sweep also found a hole in the suite's own confinement.** The mutant that skipped prefix
validation ran the installer with the relative prefix `relative/dir`. The `sudo` stub accepted
it, because `relative/dir/etc/…` is "inside" `relative/dir`, and wrote an `/etc` tree into the
worktree the sweep was started from. The stub now refuses a relative prefix (its own row), and
every row runs from inside the suite's temporary directory.

**The review found that suite still hollow, so a second sweep followed: 50 mutants, 48 killed, 2
expected survivors.** Seven of the reviewer's mutants had passed 41/41:

- reading `HandleLidSwitchDocked`, which also defaults to `ignore`;
- dropping or misspelling `TAG+="systemd"`;
- adding a match that never holds;
- `sleep 3` in place of `sleep 30`;
- reloading logind, or running `daemon-reload`, before the copies.

The stateful stubs and the exact-line assertions now kill all seven. The two survivors:

- **The real-root expected owner (`root:root 644`).** Under the test seam the copies belong to
  whoever runs the suite, and nothing can be chowned to root without root. The comparison it
  feeds is the one the test-seam owner's mutant exercises.
- **Dropping `-m 755` from `install -d`.** This is equivalent: GNU `install -d` defaults to 0755
  whatever the umask.

**A second review, of that fix, corrected the stubs themselves.** The `systemctl` stub had
modelled `NeedDaemonReload` turning `yes` after an edit. Real systemd does not do that for a
never-started instance, so the installer's check on it could never fire. The row and the branch
are gone, and with them the "daemon-reload before the copies" mutant, which is harmless for real.

The review also found two gaps, now fixed:

- **The power-loss ping needed a delayed second ping.** The battery-status lag above is why.
- **A strict verify blocked on any warning,** including one about an unrelated unit.

**Third sweep: 54 mutants, 51 killed, 3 expected survivors.** The two above, and "daemon-reload
before the copies". That one is equivalent too, for the reason just given.
