# Dock Wi-Fi guard: a docked laptop keeps one uplink

**Guide + maintainer's record.** What the guard does and how to operate it, then the
measurements behind it and the trap its design closes.

## What it does

While a NetworkManager-managed ethernet device is `connected` (the dock's USB adapter, or a
tethered phone), the Wi-Fi radio is off. When none is, it is on. Three triggers, all running
the same pure function of NetworkManager's *current* state:

| trigger | file | why it exists |
|---|---|---|
| every link event (`up`, `down`, `connectivity-change`, `dhcp4-change`; other actions are a no-op) | `/etc/NetworkManager/dispatcher.d/50-dock-wifi` → `/usr/local/bin/dock-wifi.sh --dispatch` | docking and undocking |
| boot, after `network-online.target` | `/etc/systemd/system/dock-wifi-sync.service` (oneshot, `After=NetworkManager.service network-online.target`, `Wants=network-online.target`) | NetworkManager **persists** `radio wifi off` across reboots: shut down docked, boot undocked, and no link event will ever turn Wi-Fi on |
| resume, from any kind of sleep | the same unit, `WantedBy=` and `After=` `suspend.target hibernate.target suspend-then-hibernate.target hybrid-sleep.target` | the dock may have been unplugged while asleep |

`nmcli radio wifi on|off` is called only when the radio disagrees with the wired state, so the
`down` event the toggle itself causes re-enters harmlessly, and `nmcli` failing is exit 2 with
nothing touched.

```bash
dock-wifi-setup            # install all three, root-owned copies (needs sudo); converges the radio now
dock-wifi-setup --check    # read-only: files match, unit loads and is enabled, radio matches the wired state
dock-wifi-setup --remove   # uninstall, and turn the radio back ON
~/.dotfiles/scripts/dock-wifi.sh --status   # the deciding device, the radio, the wanted state
```

There is no per-session override: `nmcli radio wifi on` while docked makes a Wi-Fi profile
autoconnect, that is an `up` event, and the dispatcher turns the radio off again within seconds.
The two escapes are unplugging the wired link and `dock-wifi-setup --remove`. The guard also
cannot tell a wired link with no internet from a working one (`nmcli`'s per-device state is
plain `connected` either way), so a docked laptop on a dead wire stays single-homed until one of
those two.

**The grace period.** The boot and resume oneshot fires when NetworkManager is "active", which
is its bus name, not its devices: measured here, the dock's ethernet takes 10-15 s from carrier
to `connected` after a re-plug and 6 s or more after resume. In exactly one state, radio off, no
ethernet connected, an ethernet device present and not `unmanaged`, the decision waits, polling
once a second for up to 20 s (`DOCK_WIFI_GRACE_S`), for that device to connect. Undocked there
is no such device and Wi-Fi returns at once; with the radio already on there is nothing to
protect and the dock's own `up` event does the rest. At boot the unit also orders itself after
`network-online.target`. Without the wait, every docked resume would turn Wi-Fi on and off again
within 15 s: the very drop the guard exists to remove.

## The trade, stated honestly

Single-homing removes Wi-Fi as a failover when the dock's wired link flaps, and a VPN session
that came up over Wi-Fi before docking now drops deterministically at dock time (the radio goes
off, its source address with it, and the tunnel restarts 20 s later). Before the guard that drop
happened anyway, at the first Wi-Fi beacon loss while docked, followed by the next one and the
next; the guard moves it to the dock event and removes the later ones. Expected gain is bounded
by the laptop-side share of tunnel drops, about a third (docs/VPN_INTERNALS.md), and it moves
the same `vpn-sweeps` numbers as the two items that record's §8 holds back, so it ships alone and
is measured for a week before anything else in that list changes.

## The record

Measured 2026-10-27 over a fortnight of client logs and the NetworkManager and wpa_supplicant
journals: docked on the dock's USB ethernet (`enx8c3b4a256b7a`, metric 100) the laptop also kept
the home Wi-Fi up (metric 600), and the SSID band-hopped between 5180 MHz and 2412/2452 MHz with
`CTRL-EVENT-BEACON-LOSS` and `reason=4 locally_generated=1` disconnects. Four tunnel drops came
exactly 20 s after a Wi-Fi disassociation or beacon loss with the wired link up (21:40:32 and
21:44:52 on 2026-10-27 among them), the AWS-pushed `ping-restart 20` doing the rest. A UDP socket
connected over Wi-Fi keeps Wi-Fi's source address after the wired link appears, so docking alone
does not move the tunnel; only the Wi-Fi going away does, 20 s at a time.

**Why not markers.** The first design recorded "I turned it off" in `/run` and turned it back on
when the same interface went down. It fails closed: NetworkManager stores the radio state in
`/var/lib/NetworkManager/NetworkManager.state`, so a laptop powered off docked and powered on
undocked comes up with Wi-Fi off, the wired device never appears, no `down` event fires, and the
marker is gone with `/run`. A pure function re-evaluated at boot and at resume has no such state
to lose.

**Why `unmanaged` ethernet does not count.** Docker's `veth*` devices are `ethernet` to
NetworkManager and `unmanaged`; three were present on this box. NetworkManager routes nothing
through them, so they are not an uplink and must not turn the radio off.

**Why the files are copied.** Root executes the dispatcher shim and the script, and PID 1 reads
the unit. A symlink into a user-writable checkout hands root a file the user can edit, the hole
CLAUDE.md names for every root-consumed file here; `--check` refuses a symlink even when its
bytes match.

**State table.** `scripts/test-dock-wifi.sh` (100 checks, run in CI). `nmcli` is a **stateful
stub**, a device table and a radio state under a directory each row chooses, because a row that
reached the real one would cut this laptop's Wi-Fi mid-suite; `sudo`, `systemctl` and
`systemd-analyze` are the stubs of `scripts/test-dock-lid.sh`, with the sudo stub running
`install` and `rm` for real only under an absolute prefix. The last section runs the real
`systemd-analyze verify` against the shipped unit and asserts the shim's `exec` line and the
unit's `After=`/`WantedBy=` exactly: a wrong target verifies and never fires on resume.
Mutation sweep, 2026-10-28, eleven mutants, each diffed for applicability: inverted polarity,
`unmanaged` ethernet counted as wired, the idempotence check dropped, `suspend.target` dropped
from `WantedBy=`, `--remove` leaving the radio off, the dispatcher acting on every event, the
install not converging, `--check` accepting a symlink, `After=NetworkManager.service` dropped,
the shim without `exec`: all killed on the first pass. The eleventh, a failed device listing
treated as "no wired device", SURVIVED, because the stub failed every call and the radio read
failed with it; the stub gained a partial-failure mode and the row that kills it: the listing
alone failing is exit 2 with the radio untouched. A fresh-context review of the branch then found
the race the unit's ordering left open (NetworkManager "active" before its devices are), the
override the doc promised and the dispatcher took straight back, and a row that verified the
shipped unit against the real `systemd-analyze` and would have gone red on this laptop the
moment the guard was installed; all three are fixed above and pinned.
