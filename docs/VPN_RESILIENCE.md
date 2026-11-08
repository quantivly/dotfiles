# VPN resilience — setup and daily operation

**Guide.** For someone setting this up or operating it. The evidence behind every rule here — the
33 days of measurements, the three designs that were killed, and the traps found while building it
— is in [VPN_INTERNALS.md](VPN_INTERNALS.md).

## What problem this solves

The AWS Client VPN on this machine drops several times a day. Two things then happen, and the
second is the expensive one.

**API calls hang instead of failing.** The client pushes routes to the Quantivly servers via
`tun0` (a full tunnel, `0.0.0.0/1` + `128.0.0.0/1`, until 2026-11-08; a split tunnel with one `/32`
per allowlisted host plus the VPC range since). On a drop it *deletes them*, the LAN default
silently takes over, and packets aimed at a Quantivly server leave the machine from an
unauthorised source address. The security groups drop them with no RST and no ICMP, so nothing
fails — it hangs, for about 127 seconds on a new connection and up to 15 minutes on an
established one.

**Nobody is told.** After the client's own 600-second SAML timeout the connection sits
Disconnected and *nothing retries it*. Measured gap from that timeout to the next connection
attempt, 16 occurrences: 3.5s, 6.8s, 11.2s … 19625s, 24074s, **31750s — 8.8 hours**. The short
ones are someone noticing. The long ones are nobody telling him.

Those are the same problem. Making the tunnel-down state *fail* is what makes it visible.

**And the client itself crashed.** AWS VPN Client 5.x died 24 times between August and November
2026, and the tunnel died with it. Recovery took a median of 3.3 hours, because nothing restarts
it. Its route listener crashes on IPv4 reject-route events, and until November this fail-fast
toggled exactly such routes on every reconnect, so it was the trigger in 15 of 17 crashes. The
fail-fast now uses static policy rules the listener never sees, and 6.x no longer contains that
listener. Upgrade the client ([Keeping the client current](#keeping-the-client-current)); the
evidence is in [VPN_INTERNALS.md](VPN_INTERNALS.md) §11.

## What gets installed

| piece | what it is | installed by |
|---|---|---|
| `vpn-failfast.service` | **system** unit (root, `CAP_NET_ADMIN`). Installs two policy rules per VPN-only destination, once: through the tunnel while it is up, `ENETUNREACH` at once while it is down. Nothing changes when the tunnel does. Also converges the IPv6 block | `vpn-setup` |
| `/etc/vpn-failfast.conf` | the destination list | `vpn-setup`, from `~/.vpn-failfast.conf` |
| `/etc/sysctl.d/99-vpn-acs-port.conf` | keeps port 35001 out of the ephemeral range | `vpn-setup` |
| `vpn-notify.service` | **user** unit. Persistent critical notification when the tunnel has been down past a threshold | `./install` links it; **you** enable it |
| `vpn-failfast.service.d/ipv6-block.conf` | drop-in arming the IPv6 block. **Absent by default** — its absence is the normal, supported, disarmed state | `vpn-setup --block-ipv6` |

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

## Blocking the IPv6 leak (DO-704)

**Superseded on 2026-11-08.** The endpoint is a split tunnel since then: IPv4 internet traffic
leaves via the ISP as well, so there is no leak and nothing for this block to close. It is disarmed
on this machine (`vpn-setup --no-block-ipv6`) and kept for full-tunnel endpoints. The rest of this
section describes the full-tunnel era; the "split tunnel would break SSH" objection below was
answered by giving every allowlisted server a fixed public address and a `/32` route.

The tunnel is a full tunnel **for IPv4 only**. The client installs `0.0.0.0/1` + `128.0.0.0/1` over
`tun0` and nothing at all for IPv6, so while you are connected every v6 packet still leaves via
your ISP — and with no family flag, name resolution prefers v6, so on a dual-stack network that is
the *default* path. Measured on a connected client: `curl -4 ifconfig.me` gives the VPN's NAT
gateway, `curl -6` gives your home address.

Neither obvious fix is available: split tunnel would break SSH/HTTPS/RDP for all six users (nine
security groups allowlist the VPN egress IP, and the servers are reached over public IPs), and the
VPC has no IPv6 CIDR to dual-stack with. So the fix is on this machine only: while the tunnel is
up, install `unreachable ::/1` and `unreachable 8000::/1` and turn a silent bypass into an
immediate, loud failure.

**It is off by default.** Arming is a typed command:

```bash
vpn-setup --block-ipv6             # arm
vpn-doctor                         # every line should be green
vpn-setup --no-block-ipv6          # disarm; IPv4 fail-fast keeps working
```

Neither flag is the default — a plain `vpn-setup` re-run after a `git pull` leaves the arming state
exactly as it was, so a routine update can never silently disarm the machine.

**Both flags take effect immediately**, on the already-running unit, not at the next boot. That
needs saying because it is not what you would get for free: `systemctl enable --now` runs `start`,
and `start` on an already-active unit is a *no-op* that never re-reads the environment. So the
installer issues a `try-restart` whenever the arming state changed — `try-restart` rather than
`restart` because it refuses to start a unit that is deliberately stopped — and issues nothing at
all when it did not.

### What stops working, and what does not

While the tunnel is **up**:

| | |
|---|---|
| **Blocked** | everything this host originates to a globally-routable IPv6 address, plus NAT64. Sites with AAAA records get an immediate `EHOSTUNREACH` and fall back to v4 via Happy Eyeballs — tens of milliseconds, not a hang. Sites reachable **only** over IPv6 become unreachable. |
| **Not blocked** | loopback `::1`; link-local `fe80::/10`; all multicast (it is in `table local`); the on-link LAN `/64`, so IPv6 LAN neighbours still work; and **Tailscale's `fd7a:115c:a1e0::/48`**, which resolves via table 52 at rule 5270, *before* the main table. The tailnet is unaffected. |

Two more, stated honestly because they are easy to be surprised by:

- **Tailscale's underlay** loses its IPv6 path. Measured before the block: `tailscale netcheck`
  reports `IPv6: yes, [2a06:c701:9cec:a100:...]`, so there is a real v6 path to lose. `tailscale0`
  itself is untouched — the tailnet resolves via table 52 at rule 5270 — but WireGuard UDP to peers
  and DERP fall back to IPv4. That costs one NAT-traversal candidate, not a disconnection, and an
  exit node would still work.
- **DNS is unaffected.** `tun0` carries the catch-all routing domain `~.`, so general name
  resolution already goes *through* the tunnel: `resolvectl query github.com` reports `link: tun0`,
  and the tunnel's own resolver `208.67.222.222` routes via `tun0`. The ISP's IPv6 resolvers stay
  on the LAN links but are only consulted for the `home` domain — and a query to one returns
  `EHOSTUNREACH` *synchronously* under the block, no packet and no timer, so resolved rotates
  within the same event-loop iteration rather than stalling.

While the tunnel is **down**, nothing is blocked at all and IPv6 works normally. That is the
polarity: there is no leak to close when there is no tunnel to leak around.

### Two things it deliberately does not promise

**There is a leak window of up to 5 seconds on every connect and every resume.** The daemon watches
`ip monitor link`, but the transition that matters is a *route* appearing on `tun0`, so the block
lands on the next poll rather than on the event. The poll is the correctness guarantee by design;
the window is the price.

**There is no automatic expiry.** `expires` is *accepted* on an `unreachable` IPv6 route and the
attribute is then never attached — measured, against a control route given the identical flag in
the same namespace, which *did* carry it. A dead-man switch built on it would be a safety claim
that is not true. Withdrawal comes from four
things instead: `ExecStopPost`, the clear at start, the boot-time start, and `vpn-doctor`.

### If something goes wrong

**The tunnel came up and an app hung.** An IPv6 TCP connection that was already established when
the block landed is *not* torn down. `EHOSTUNREACH` on a retransmit is a soft error Linux ignores
outside `SYN_SENT`, so it retries to `tcp_retries2` — about 15 minutes. **Restart the app.** An
nftables reject rule would behave identically; this is TCP, not the mechanism.

**A site is unreachable and it is IPv6-only.** That is the block doing its job. Disarm if you need
it: `vpn-setup --no-block-ipv6`.

**`vpn-doctor` says IPv6 is leaking.** Armed, tunnel up, block not installed — the daemon is not
converging. `sudo systemctl restart vpn-failfast`.

**`vpn-doctor` reports an orphaned IPv6 block.** A block left installed with the tunnel down, or
with the feature disarmed, blackholes *all* global IPv6 — the v6 twin of the stale-route risk
above, and worse, because it is the whole address family rather than one host:

```bash
sudo systemctl restart vpn-failfast          # it clears orphans at start
sudo /usr/local/bin/vpn-failfast.sh --clear  # or by hand, both families
```

**`vpn-doctor` reports VERSION SKEW.** A `git pull` plus a plain `vpn-setup` updates the
daemon and preserves the drop-in, but an *older* daemon ignores the knob entirely: armed, healthy,
and blocking nothing, with no file difference for a drift check to see. Re-run `vpn-setup`.

**Checking it by hand.** `vpn-doctor` makes all of these judgements itself and is the thing to
trust, but the raw commands read cleanly once:

```bash
ip -6 route show proto 66              # expect both halves, dev lo, metric 4242
ip -6 route get 2606:4700:4700::1111   # expect rc 2, "No route to host"
ip -6 route get 64:ff9b::1             # expect rc 2 — the NAT64 case
ip -6 route get fd7a:115c:a1e0::53     # expect rc 0, "dev tailscale0 table 52" (control)
```

Read **stderr**, not stdout: when the block wins, `route get` prints nothing on stdout and exits 2.
And use `route get`, not `route show` — only `get` asks the kernel which route *wins*, which is the
one question a more-specific route from an RA or a v6-enabled Docker network would change.

## Daily operation

```bash
vpn-status     # is the tunnel up, what is installed, are the units running?
vpn-doctor     # assert the whole chain; non-zero on FAIL
vpn-sweeps     # the offline report (default: 7 days).  --days N  --json
```

`vpn-doctor` is where to start. `vpn-status` answers "what is true now"; `vpn-doctor` answers "is
all of it *correct*", including the things that look fine and are not.

## If something goes wrong

**A host is unreachable and the tunnel is up.** Two things can do that, and `vpn-doctor` names
both as FAILs:

- a **legacy `unreachable` route** left by the old route toggle. A /32 beats the tunnel's /1, so it
  blackholes its host. `ip route show proto 66` lists them; the new daemon removes them at start.
- a destination with a **reject rule and no tunnel rule** (`reject-only` in the doctor). The
  daemon never leaves that state itself: it adds the tunnel rule first and removes it last.

```bash
sudo systemctl restart vpn-failfast     # reconciles the rules, clears legacy routes
ip rule show | grep 'proto 66'          # the rules: two per destination, at 6600 and 6601
ip route get <dst>                      # which way it ACTUALLY goes (no root needed)
```

Everything this tool owns carries protocol **66**. A rule is also identified by its priority, and
nothing is ever deleted except by that identity, so a rule or route that you or anything else
installed is never touched. Tailscale's rules sit at 5210–5270, before ours, so the tailnet is
never affected.

**The unit will not start.** Almost always a config it refuses. `sudo systemctl status
vpn-failfast` and `journalctl -u vpn-failfast -e`; the refusal names the file, the line and the
reason. Fix `~/.vpn-failfast.conf` and re-run `vpn-setup`.

**You got a notification but the VPN Client looks connected — or is not on screen at all.**
On 5.x this was usually the crash described at the top of this page. On 6.x the tunnel lives in a
root daemon (`aws-client-vpn-daemon.service`), so the GUI exiting no longer drops it; check with
`aws-vpn-client get-connection-status --profile-name Quantivly`. On 5.x, check whether the client
is still *running*:

```bash
systemctl --user list-units --all 'app-gnome-awsvpnclient-*'   # the GUI application
pgrep acvc-openvpn                                             # the tunnel worker
```

Both verified on this machine, and both deliberately avoid `ps`/`pgrep -a`, which
`claude/hooks/secret-emission-guard.sh` refuses. Note the process is **not** called
`awsvpnclient` — `pgrep awsvpnclient` finds nothing even while the client is running, which
reads as "it is dead" when it is not.

The client can exit and take the tunnel with it, and then there is no GUI to contradict the
notification. That has happened here:
the application quit after 7h15m and the tunnel was dead for 36 minutes in complete silence, with
no log lines and no `AUTH_FAILED`, because there was no process left to write them. Relaunch the
client; the notification's "Reconnect the AWS VPN Client" is the right advice for that case too.
The detail is in [VPN_INTERNALS.md](VPN_INTERNALS.md) §3.

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

## Keeping the client current

AWS supports only recent client versions, and 5.x is listed as "No longer supported". Run
`vpn-doctor`. It WARNs on a 5.x client, on an available update, and on an **expired apt signing
key**. That last one is how this machine stayed on 5.4.0 from June to November 2026: AWS rotated
its key, the old one expired on 2026-09-05, and every `apt update` dropped the AWS repo without
anyone noticing.

The fix is the current key, scoped to that one source rather than trusted for every repo:

```bash
curl -fsS -o /tmp/awsvpnclient.asc \
  https://d20adtppz83p9s.cloudfront.net/GTK/latest/debian-repo/awsvpnclient_public_key.asc
gpg --show-keys --with-colons /tmp/awsvpnclient.asc | awk -F: '/^fpr:/{print $10; exit}'
#   expect F3DACFA438D147D81BCA38B3CA08BD64C7EFCC8B (the key signing the repo since 2026-09-25)
sudo install -D -m 0644 /tmp/awsvpnclient.asc /etc/apt/keyrings/awsvpnclient.asc
# then, in /etc/apt/sources.list.d/aws-vpn-client.sources:
#   Signed-By: /etc/apt/keyrings/awsvpnclient.asc
sudo rm /etc/apt/trusted.gpg.d/awsvpnclient_public_key.asc     # the expired one
sudo apt-get update --allow-releaseinfo-change-origin --allow-releaseinfo-change-label
apt-cache policy awsvpnclient
```

Both `--allow-releaseinfo-change-*` flags are needed once. When AWS re-signed the repo it also
renamed its `Origin` and `Label` (`AWS VPN Client Repository` → `AWS VPN Client`), and apt
refuses a release-info change until it is accepted explicitly. With only the key fixed,
`apt-get update` still fails, on that. Accept exactly those two fields, never the blanket
`--allow-releaseinfo-change`.

Check the package's sha256 against the [release notes](https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux-release-notes.html)
before installing. They are on docs.aws.amazon.com, a different channel from the CloudFront host
that serves both the key and the package. After a 5.x → 6.x upgrade:

- Check that the tunnel is still `tun0` (`ip -j route show 0.0.0.0/1`). Both daemons here assume
  it.
- If the profile did not migrate, re-import it with `aws-vpn-client import-profile`.
- The tunnel lives in `aws-client-vpn-daemon.service` (root, `Restart=always`), which logs to
  `/var/log/awsvpnclient/`. That directory is root-owned, unlike both 5.x log directories.
  `vpn-sweeps` reads it alongside the old ones, so a window spanning the upgrade is one
  history.

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

`vpn-sweeps` is the instrument. It leads with **client crashes** and crash → reconnect time,
the numbers the November fix targets: 12 crashes in the 14 days to 2026-11-02, and the target is
0. The number the original work targets is **SAML timeout → next attempt**. Compare each against
itself a week apart:

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
