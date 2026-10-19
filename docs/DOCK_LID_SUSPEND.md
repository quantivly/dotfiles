# Dock lid suspend guard

**Guide + maintainer's record.** What stops a lid closed while the Thunderbolt dock is still
connecting from suspending into it, how to install and check it, and the evidence behind it.
The operative rule is the `dock-lid-setup` line in [CLAUDE.md](../CLAUDE.md).

## What it guards against

On 2026-10-19 the lid of this ThinkPad X1 Carbon Gen 13 (kernel 7.0.0-38, `s2idle` only) was
closed 1.8 s after plugging it into the Lenovo ThinkPad Thunderbolt 4 Dock. logind could see
neither the dock nor its power yet, so it treated the lid as an undocked lid-close and
suspended. The dock finished enumerating *during* the suspend, the suspend never completed, and
the machine sat unresponsive until a forced power-off 2.5 h later.

| time | journal |
|---|---|
| 11:02:36.48 | `thinkpad_acpi: undocked from hotplug port replicator` — logged on every **plug-in** on this machine, not only on unplug |
| 11:02:38.29 | `systemd-logind: Lid closed.` → `Suspending...` |
| 11:02:39.01 | `thunderbolt 0-1: Lenovo ThinkPad Thunderbolt 4 Dock`, then the dock's USB hub on `usb 3-2` |
| 11:02:39 | `systemd-sleep: Performing sleep operation 'suspend'...` — the last line of the boot |

Every suspend that completed in that boot logged the kernel's `PM: suspend entry (s2idle)`
right after `Performing sleep operation`; this one never did. Nothing reached pstore and the
firmware recorded no hardware error at the next boot: a hang, not a panic or a hardware fault.

## The two guards

| guard | files | covers a lid closed from |
|---|---|---|
| lid on external power does nothing | `logind/lid-on-power.conf` → `/etc/systemd/logind.conf.d/` | ~1.8 s after the cable connects |
| every USB-C plug-in holds off lid handling for 30 s | `udev/90-dock-lid-holdoff.rules` → `/etc/udev/rules.d/`, `systemd/dock-lid-holdoff@.service` → `/etc/systemd/system/` | ~0.1 s after the cable connects |

**The holdoff.** udev starts one instance of `dock-lid-holdoff@.service` per `typec_partner`
add, through `SYSTEMD_WANTS`. The instance is named `<kernel name>-<SEQNUM>`. Each instance
takes a **block** lock on `handle-lid-switch` with `systemd-inhibit` for 30 s, and logind
ignores the lid while any lock is held. When the last one lapses, logind re-checks a lid that is
still closed and acts then: nothing if docked or on power, suspend on battery. Its own
`HoldoffTimeoutSec=` uses the same mechanism after boot and resume, and 30 s matches that
default.

**One instance per plug-in, not one unit.** Starting a unit that is already active does
nothing, so with a single unit a re-plug late in the window would keep the *first* plug-in's
expiry. The lock could then lapse before the re-plugged dock's power is visible. A boot with the
dock attached starts an instance too, because coldplug replays the `add`.

**The power-loss re-check.** With the lid on external power ignored, pulling the charger while
the lid is already closed changes nothing that logind watches: it monitors input, graphics and
seat devices, not power supplies. The laptop would stay awake until some unrelated logind event.
The second udev rule makes one: on a Mains or USB supply going offline it pings logind over
D-Bus, and logind re-checks a closed lid after every event it handles.

It pings **twice**, at once and 5 s later from a transient systemd timer. logind counts as "on
battery" only a battery whose status reads `Discharging`. The ACPI battery driver caches that
status for 1 s, so the first ping can still see `Not charging`, and the flip may come with no
uevent of its own.

Closing the lid on **any** charger, not only the dock, no longer suspends. That is intended.

## Install, check, remove

```bash
cd ~/.dotfiles && dock-lid-setup          # install or resync; reloads systemd, udev and logind; checks
dock-lid-setup --check                    # read-only: see below
journalctl -u 'dock-lid-holdoff@*' -b     # one Started / Deactivated pair, 30 s apart, per plug-in
```

All three files are **copied** root-owned, never symlinked: root's logind, systemd and udevd
read them. Editing the repo copy changes nothing until `dock-lid-setup` is re-run. The
installer refuses to run from a worktree (`DOCK_LID_SETUP_ALLOW_WORKTREE=1` overrides it, to
test a branch). It validates first with `udevadm verify` and `systemd-analyze verify`, and
prints the parser's own explanation on a rejection.

A warning that names the unit counts as a rejection: `systemd-analyze` reports an unknown key
and then exits 0. A warning about an *unrelated* unit does not count. `systemd-analyze` loads
the unit's whole dependency closure (sysinit, basic, every enabled socket and timer) and reports
on those too, so it runs with `--recursive-errors=no` and only lines naming this unit count.

`--check`, which the installer also runs last, fails on any of these:

- **A copy that is a symlink.** Root would then read a file you can write.
- **A copy that is not root-owned 0644, or differs from the checkout.**
- **A template systemd cannot load.** It reads `LoadState` of an instance, because a template
  cannot be asked about.
- **A logind not running with `HandleLidSwitchExternalPower=ignore`.**

It does not read `NeedDaemonReload`: a never-started instance is loaded fresh on every query,
so it always answers `no`. Every new instance reads the file on disk anyway.

logind is **reloaded, never restarted** — a restart ends every session on the machine. Its unit
is `Type=notify-reload`, and SIGHUP re-reads `logind.conf.d`. Where a reload does not take, the
check fails and names the reboot.

To remove: delete the three files under `/etc`, then `sudo systemctl daemon-reload`,
`sudo udevadm control --reload` and `sudo systemctl reload systemd-logind`.

## What neither guard covers

- **The kernel bug itself.** A suspend that starts while a dock is enumerating can still hang the
  machine; the guards only keep the lid from starting one.
- **Other ways to suspend in the same seconds**: Suspend from the menu, or idle-suspend firing at
  the moment of plug-in.
- **The dock link dropping while the lid is already closed.** logind would see an undock and
  suspend before the re-plug's holdoff starts. Never observed in the logs.
- **A USB-C partner that flaps more often than every 30 s** keeps a lock held continuously, so a
  closed lid on battery would not suspend while it flaps.
- **A battery that takes more than 5 s to report `Discharging` after the charger is pulled, with
  no uevent when it does.** The laptop then waits, lid closed, for logind's next unrelated event.
  The timing on this machine has not been measured on a real unplug.

If the machine hangs again after a normal pause before closing the lid, suspect the kernel and
boot the previous one to compare.

## Evidence

### Timing of one plug-in, measured 2026-10-19

On the kernel's monotonic clock, from `udevadm monitor` and a 50 ms poll of `systemd-ac-power`
(the test logind itself applies):

| after the cable connects | signal |
|---|---|
| +0.00 s | `typec` `port1-partner` **add** — the earliest signal, and the holdoff's trigger |
| +0.58 s | `thinkpad_acpi` dock event |
| +1.78 s | `systemd-ac-power` says yes — `HandleLidSwitchExternalPower=` starts to apply |
| +3.05 s | Thunderbolt dock device added |

The 2026-10-19 lid-close came 1.81 s after the dock event, so the logind drop-in alone would
have caught it by about 0.6 s, on one measurement. The first, single-unit holdoff, on a real
plug-in, took its lock 0.49 s *before* the dock event and released it 30.02 s later, a margin of
about 2.3 s on the same lid-close.

### What the design rests on, read in systemd v259's source

A review read `src/login/` and `src/core/device.c` at tag v259 to check each claim the guards
depend on:

- **A closed lid is re-checked when a lock is released.** On `Lid closed` logind installs a
  post-event handler that stays until the lid opens. It re-runs the lid decision, with docked,
  external power and battery all evaluated afresh, after every event logind dispatches. The
  inhibitor's fifo closing is such an event, and so is a D-Bus call such as the power-loss
  `Ping`.
- **`handle-lid-switch` is honoured unconditionally.** `LidSwitchIgnoreInhibited=yes` (the
  default) bypasses only `sleep` locks.
- **`HandleLidSwitchDocked` is checked before `HandleLidSwitchExternalPower`.**
- **`systemctl reload systemd-logind` re-reads the configuration and drop-ins without touching
  sessions.**
- **A device unit's `Wants=` are started on every dead→plugged transition.** That is every
  re-plug. A unit already active is skipped, which is why the holdoff is per plug-in.
- **`$env{SEQNUM}` reads a real property.** sd-device stores a kernel uevent's `SEQNUM` as one
  (`device-private.c`). `udevadm test` builds its event from sysfs, without one, so there it
  substitutes as empty. That is why the instance name also carries `%k`: an empty SEQNUM still
  gives a valid name.

GNOME's gsd-power also holds a `handle-lid-switch` lock while an external monitor is attached,
but not in the first ~3 s of a plug-in, which is the window here.

### It had happened before, and survived

On 2026-10-11 at 21:56 (kernel 7.0.0-34) the lid closed in the same second the dock
enumerated, and logind suspended while the dock's USB hub was still coming up. That suspend
completed and resumed. One hang against one survival does not implicate the kernel update; it is
a race.

### Designs not taken

- **`HoldoffTimeoutSec=`** applies only after boot and resume, never after a hotplug.
- **A `delay` lock.** logind refuses one for any `handle-*` lock ("Delay inhibitors only
  supported for shutdown and sleep"), and a delay on `sleep` is capped by `InhibitDelayMaxSec=`.
- **A single holdoff unit.** A re-plug inside its window does not extend it (above).
- **`HandleLidSwitch=ignore`** would stop the lid suspending on battery too, so a closed laptop
  in a bag stays awake.

### Tests

State table: `scripts/test-dock-lid.sh` (57 checks, hermetic, CI `dock-lid-test`). It stubs
`sudo`, `systemctl`, `busctl`, `udevadm` and `systemd-analyze`, and runs `install` for real under
a prefix the stub confines it to.

The stubs model state rather than fixed answers, and only what the real tools do:

- **A logind reload snapshots the drop-in's value at that moment.** `busctl` answers from the
  snapshot, and only for `HandleLidSwitchExternalPower`. So reloading before copying, or reading
  the wrong property, fails a row.
- **`systemctl show -p LoadState` answers from the template on disk.** Real systemd needs no
  daemon-reload for that.
- **`systemd-analyze verify` names the file in a warning**, and fails on an unrelated unit's
  error unless `--recursive-errors=no` is given. The real
`udevadm verify` and `systemd-analyze verify` check the shipped rule and unit. Both rule lines
and the unit's `ExecStart` are asserted exactly, because `udevadm verify` accepts a rule that
never fires.

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
