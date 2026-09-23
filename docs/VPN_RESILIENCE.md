# VPN resilience — setup and daily operation

**Guide.** For someone setting this up or operating it. The evidence behind every rule here — the
33 days of measurements, the three designs that were killed, and the traps found while building it
— is in [VPN_INTERNALS.md](VPN_INTERNALS.md).

## What problem this solves

The AWS Client VPN on this machine drops several times a day. Two things then happen, and the
second is the expensive one.

**API calls hang instead of failing.** It is a full tunnel (`redirect-gateway def1`): the client
installs `0.0.0.0/1` and `128.0.0.0/1` via `tun0`. On a drop it *deletes both*, the LAN default
silently takes over, and packets aimed at a Quantivly server leave the machine from an
unauthorised source address. The security groups drop them with no RST and no ICMP, so nothing
fails — it hangs, for about 127 seconds on a new connection and up to 15 minutes on an
established one.

**Nobody is told.** After the client's own 600-second SAML timeout the connection sits
Disconnected and *nothing retries it*. Measured gap from that timeout to the next connection
attempt, 16 occurrences: 3.5s, 6.8s, 11.2s … 19625s, 24074s, **31750s — 8.8 hours**. The short
ones are someone noticing. The long ones are nobody telling him.

Those are the same problem. Making the tunnel-down state *fail* is what makes it visible.

## What gets installed

| piece | what it is | installed by |
|---|---|---|
| `vpn-failfast.service` | **system** unit (root, `CAP_NET_ADMIN`). Installs `unreachable` routes for VPN-only destinations while the tunnel is down, withdraws them when it returns | `vpn-setup` |
| `/etc/vpn-failfast.conf` | the destination list | `vpn-setup`, from `~/.vpn-failfast.conf` |
| `/etc/sysctl.d/99-vpn-acs-port.conf` | keeps port 35001 out of the ephemeral range | `vpn-setup` |
| `vpn-notify.service` | **user** unit. Persistent critical notification when the tunnel has been down past a threshold | `./install` links it; **you** enable it |

Nothing here is installed by `./install` except the notifier *link* — `./install` never uses
`sudo`. The three root-owned files are **copied, never symlinked**, the same rule
`resticprofile/profiles.toml` and the audit rules follow: root reads them, and a symlink into a
working tree means a rebase changes what root runs.

## Setting it up

```bash
vpn-init      # create ~/.vpn-failfast.conf from the template
$EDITOR ~/.vpn-failfast.conf      # REVIEW IT — see the warning below
vpn-setup     # validate, install root-owned, apply the sysctl, enable
vpn-doctor    # assert the whole chain
```

Then, once you have seen a week of `vpn-sweeps` and are happy with the threshold:

```bash
systemctl --user enable --now vpn-notify.service
```

### Read the destination list before installing it

Every address in `/etc/vpn-failfast.conf` **fails instantly** while the tunnel is down. That is
the point, and it is also the only way this can hurt you. The list ships seeded with the four
`qmux` hosts (`dev`, `staging`, `demo`, `qspace`) and nothing else. The internet and video calls
keep working over the LAN — that is deliberate, and it is why this is a list of destinations
rather than a default route.

The validator refuses several things that `ip` itself accepts, each measured rather than assumed:

| entry | what `ip` does with it | what this does |
|---|---|---|
| `0.0.0.0/0` | **accepts it** — blackholes the entire internet | refused (nothing broader than `/8`) |
| `10.9.8.1/24` | **accepts it**, installs the whole `/24` | refused, and names the prefix you meant |
| `2001:db8::/32` | **accepts it**, silently into the v6 table | refused; IPv4 only |
| `127.0.0.1` | accepts it | refused |

A malformed entry means **nothing is installed** — not a partial set, and never a silent "no
destinations", which is indistinguishable from a healthy tunnel.

## Daily operation

```bash
vpn-status     # is the tunnel up, what is installed, are the units running?
vpn-doctor     # assert the whole chain; non-zero on FAIL
vpn-sweeps     # the offline report (default: 7 days).  --days N  --json
```

`vpn-doctor` is where to start. `vpn-status` answers "what is true now"; `vpn-doctor` answers "is
all of it *correct*", including the things that look fine and are not.

## If something goes wrong

**A host is unreachable and the tunnel is up.** This is the one real risk in the design: a stale
`unreachable` route blackholes a host permanently and looks exactly like a server outage.
`vpn-doctor` reports it as a FAIL and names the routes. Two ways out:

```bash
sudo systemctl restart vpn-failfast     # it clears orphans at start
sudo ip route del unreachable <dst> proto 66     # or by hand
```

Routes this tool owns all carry route protocol **66**, and nothing is ever deleted except by that
filter — so a route you or anything else installed is never touched, whatever its destination.
List them with `ip route show proto 66` (no root needed).

**The unit will not start.** Almost always a config it refuses. `sudo systemctl status
vpn-failfast` and `journalctl -u vpn-failfast -e`; the refusal names the file, the line and the
reason. Fix `~/.vpn-failfast.conf` and re-run `vpn-setup`.

**Notifications are too noisy, or never arrive.** The threshold is 90 seconds, chosen to clear
the self-healing outages (p50 34s, and 17 of 41 recovered with no re-auth at all). Tune it with
`VPN_NOTIFY_THRESHOLD` in `~/.zshrc.local` and restart the unit. If none arrive, check
`systemctl --user status vpn-notify` — a machine with no `/opt/awsvpnclient` **skips** the unit by
design, which is reported as a decision, not a failure.

**`vpn-doctor` reports config or unit drift.** The live copies are copies; nothing keeps them in
step with the checkout. Re-run `vpn-setup`.

**`vpn-doctor` reports something that contradicts what you can see on disk.** Your shell is
stale. `vpn-status`, `vpn-doctor` and the rest are zsh *functions*, loaded once when the shell
started — so a shell opened before a deploy keeps running the old ones however new the checkout
is. This bit on the first install: the doctor reported `does not render (unresolved
placeholder?)` about a renderer that had already been deleted, from a function loaded before the
merge. `source ~/.zshrc` (or `zshreload`), or open a new shell, then re-run. The same applies to
every `*-doctor` in this repo; "the checkout IS the deployment" moves files, not the functions a
running shell already holds.

## What this deliberately does not do

It does not reconnect, re-open a browser, or touch the tunnel. The client already opens the
re-auth tab itself — 1:1 with every `AUTH_FAILED`, within 11ms, measured — and 80% of re-auths
complete with no human at all. A second opener walks into the vendor's own error text
(*"Close any previously opened browser login windows and try again"*, 57 occurrences).

More importantly: **no runtime component reads a client log.** Both log directories are writable
by any process running as this user, and one of these components runs as root. The two daemons
read kernel state (`ip -j link`, `ip -j route`) only. Logs are read offline, by `vpn-sweeps`, for
reporting. [VPN_INTERNALS.md](VPN_INTERNALS.md) has the reasoning; do not reintroduce a log read
for convenience.

## Measuring whether it worked

`vpn-sweeps` is the instrument, and the number this work targets is **SAML timeout → next
attempt**. Compare it against itself a week apart:

```bash
vpn-sweeps --days 7 --json > /tmp/vpn-baseline.json
# ... a week later ...
vpn-sweeps --days 7 --json
```

Its figures are **not** directly comparable to the ad-hoc numbers in the planning notes — those
were computed with different filtering (in-use windows excluded, idle overnight windows dropped).
Compare this tool to this tool.

Two changes that move the same numbers are deliberately **not** in this feature, so that neither
masks the other: Wi-Fi power save (`wifi.powersave = 3`, a cheap suspect for the 20-second gaps
that trip the server-pushed `ping-restart 20`), and signing the second Google account out of the
Chrome profiles (the account chooser fires on account *count*, and every profile has two). Change
one at a time, a week apart, and read `vpn-sweeps` between them.
