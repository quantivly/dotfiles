# Dock lid suspend guard

**Guide + maintainer's record.** What stops a lid closed while the Thunderbolt dock is still
connecting from suspending into it, how to install and check it, and the evidence behind it.
The operative rule is in [CLAUDE.md](../CLAUDE.md#dock-lid-guard).

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
| any USB-C plug-in holds off lid handling for 30 s | `udev/90-dock-lid-holdoff.rules` → `/etc/udev/rules.d/`, `systemd/dock-lid-holdoff.service` → `/etc/systemd/system/` | ~0.1 s after the cable connects |

The holdoff is a **block** lock on `handle-lid-switch`, taken by `systemd-inhibit` in a system
unit that udev pulls in through `SYSTEMD_WANTS` when a `typec_partner` device is added. While
it is held logind ignores the lid. When it lapses, logind re-checks a lid that is still closed —
the same mechanism its own `HoldoffTimeoutSec=` uses after boot and resume — and acts then:
nothing if docked or on power, suspend on battery. 30 s matches that default.

Closing the lid on **any** charger, not only the dock, no longer suspends. That is intended.

## Install, check, remove

```bash
cd ~/.dotfiles && dock-lid-setup   # install or resync; reloads logind and udev; then checks
dock-lid-setup --check             # read-only: copies match the checkout, logind runs with it
journalctl -u dock-lid-holdoff -b  # one Started / Deactivated pair, 30 s apart, per plug-in
```

All three files are **copied** root-owned, never symlinked: root's logind, systemd and udevd
read them. Editing the repo copy changes nothing until `dock-lid-setup` is re-run, and
`--check` reports the difference as drift. The installer refuses to run from a worktree
(`DOCK_LID_SETUP_ALLOW_WORKTREE=1` overrides it, to test a branch).

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
have caught it by about 0.6 s, on one measurement. The installed holdoff, on a real plug-in,
took its lock 0.49 s *before* the dock event and released it 30.02 s later, a margin of about
2.3 s on the same lid-close.

### It had happened before, and survived

On 2026-10-11 at 21:56 (kernel 7.0.0-34) the lid closed in the same second the dock
enumerated, and logind suspended while the dock's USB hub was still coming up. That suspend
completed and resumed. One hang against one survival does not implicate the kernel update; it is
a race.

### Designs not taken

- **`HoldoffTimeoutSec=`** applies only after boot and resume, never after a hotplug.
- **A `delay` lock** lets the suspend proceed when it lapses, even if the dock is up by then.
- **`HandleLidSwitch=ignore`** would stop the lid suspending on battery too, so a closed laptop
  in a bag stays awake.

### Tests

State table: `scripts/test-dock-lid.sh` (41 checks, hermetic, CI `dock-lid-test`). It stubs
`sudo`, `systemctl`, `busctl`, `udevadm` and `systemd-analyze`, runs `install` for real under a
prefix the stub confines it to, and checks the shipped rule and unit with the real
`udevadm verify` and `systemd-analyze verify`.

**Mutation sweep, 2026-10-19: 27 mutants, 27 killed.** 19 were in the installer, 8 in the
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
