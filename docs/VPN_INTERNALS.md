# VPN resilience — the maintainer's record

**Record.** The evidence behind [VPN_RESILIENCE.md](VPN_RESILIENCE.md) and behind the one-line
rules in [CLAUDE.md](../CLAUDE.md). Everything here was measured read-only on `cilantro` on
2026-09-23 over 33 days of AWS Client VPN logs. The tunnel was never touched and no drop was ever
forced.

**Add new evidence here, not to CLAUDE.md.**

---

## 1. What the drops actually cost

`~/.config/AWSVPNClient/logs/`, 33 days: 152 `AUTH_FAILED` in the openvpn stream and 122 in the
app stream (the 30-event difference is retention — the app logs begin six days later, not a loss).
Restricting to the 10-day window with full coverage and excluding two overnight idle windows:

| | |
|---|---|
| in-use outages, 10 days | **41** (≈4/day) |
| total in-use downtime | **211 min** (≈21 min/day) |
| p50 / p75 / p90 outage | **34s / 270s / 647s** |
| self-healed with no SAML | 17 of 41, p50 **10s** |
| needed a SAML re-auth | 24 of 41 — **95% of the downtime** |

## 2. Why API calls hang for 2–3 minutes

Full tunnel: `0.0.0.0/1` and `128.0.0.0/1` via `tun0`. On a drop the client deletes both and the
LAN default takes over, so traffic reaches AWS from an unauthorised source address and the
security groups drop it silently. Measured with the tunnel **up**, using `SO_BINDTODEVICE` to
reproduce the tunnel-down path without touching the tunnel:

```
dev    54.166.22.221:22   via tunnel             CONNECTED in 0.16s
dev    54.166.22.221:22   forced out wlp0s20f3   NO RESPONSE (timeout at 6.0s)
github 140.82.121.3:443   forced out wlp0s20f3   CONNECTED in 0.06s
```

`tcp_syn_retries = 6` → retransmits at 1/2/4/8/16/32/64s, `ETIMEDOUT` at **≈127s**. An
established socket uses `tcp_retries2 = 15`, about 15 minutes. That is the 2–3 minutes exactly.

**Use this probe to verify the fix**, not a forced disconnect: after the routes are installed the
same connect must fail immediately. **`EHOSTUNREACH` (errno 113, "No route to host"), not
`ENETUNREACH`** — an `unreachable` route gives the host form, and an earlier draft of this page
said otherwise. Measured below.

## 3. Where the recoverable time is — after two wrong answers

### Wrong answer 1: "nobody notices the failure"

The client logs the re-auth URL and calls `xdg-open` on it **11ms later**, on 122 of 122 events.
`Attempting to open browser with URL` occurs 122 times, **exactly 1:1 with `AUTH_FAILED`**. In all
25 events that never recovered, the client's own open count is **1, never 0**. There is no event
in 33 days where a watcher's open would have been the first.

### Wrong answer 2: "it opens in the wrong Chrome profile"

Chrome history showed every SAML chain ending at `/v3/signin/accountchooser`, and the default
https handler is plain `google-chrome.desktop` pointed at the personal profile.

**That was a query artifact.** The history query was filtered to `accounts.google.com`, so the
final hop *could not appear*. Chrome also does not chain the ACS delivery at all — it is a form
POST — so **0 of 88** SAML chains in either history DB reach `127.0.0.1:35001`, and every chain
dead-ends at the account chooser whether it succeeded or not.

> **This artifact produced two wrong root causes in one planning session.** A `vpn-sweeps` metric
> built on Chrome history would read 0% forever and look like a regression. Ground truth is
> `SAML ACS received a request` and `Succesfully retrieved and validated assertion` in the app
> log — note the vendor's spelling of "Succesfully", matched exactly.

### The measured answer

Of 122 re-auths, **109 got an ACS POST and 97 (80%) completed with no human at all.**
Client-own-open → ACS-POST latency:

| min | p25 | p50 | p75 | p90 | max |
|---|---|---|---|---|---|
| 2.5s | 9.0s | 22.8s | 78.4s | **577.7s** | 3433s |

28% finish in ≤10s. Nothing opens a browser and clicks in 2.5s, so the fast half is genuinely
hands-free. The cost is in two places:

1. **The 25 that never complete.** 19 of 25 end at exactly **600.0s**, the client's
   `SAML_LOGIN_START_TIMEOUT`. 8 of 25 begin 6–16s after a kernel `PM: suspend exit`, and 7 of
   those log `RECONNECTING,network-unreachable` in the same window — the client opened a browser
   tab at a machine whose Wi-Fi had not reassociated yet.
2. **What happens next: nothing.** After `SamlSessionTimedOutException` (57 occurrences) the
   connection sits Disconnected and is never retried. Gap to the next attempt, 16 observed:
   `3.5, 6.8, 11.2, 16.4, 28.4, 33.6, 47.1, 486.7, 868.2, 945.5, 2823.6, 3478.3, 5584.0,
   19625.2, 24073.9, 31750.5` seconds. A fresh attempt then usually succeeds in seconds
   (09-23: attempt 07:39:59 → assertion 07:40:08.673, 8.5s).

**So the recoverable downtime is not a missing click. It is a missing signal.**

### It worked, on the first real outage

Not a drill and not a forced drop — the tunnel went down on its own on **2026-09-23**, a few
minutes after the unit was armed, and `vpn-doctor` reported four `unreachable` routes installed.
Measured during that outage:

| target | before (§2, same probe) | with fail-fast armed |
|---|---|---|
| `dev` 54.166.22.221:22 | NO RESPONSE, timeout at 6.0s (ETIMEDOUT at ≈127s) | `EHOSTUNREACH` in **0.158s** |
| `staging` 44.221.89.155:22 | — | `EHOSTUNREACH` in **0.366s** |
| github.com:443 (control) | CONNECTED 0.06s | **CONNECTED 0.250s** |

So the hang is gone, the failure is immediate and correctly typed, and the internet is untouched
— which is the whole design in one table. The routes were withdrawn when the tunnel returned.

### The outage that was not a drop: the client PROCESS died

Three hours after the first one, on **2026-09-23**, a second real outage arrived — and it was a
harder case than anything the plan anticipated. The design was built for *"the tunnel drops and
the client sits Disconnected without retrying"*. This was **the client not being there at all**:

```
14:09:08  tunnel CONNECTED
16:47:13  the AWS VPN Client APPLICATION EXITED
          (app-gnome-awsvpnclient-3157043.scope: consumed 7h15m, then gone)
16:47:31  tun0 activated -> unmanaged (removed); vpn-failfast installs 4 routes THE SAME SECOND
          ... 30 minutes of nothing: no client, no GUI, no log lines, no AUTH_FAILED ...
17:17:44  vpn-notify enabled (it had not been armed until then)
17:19:18  NOTIFICATION FIRES, 94s after it could first observe anything
17:23:22  a new awsvpnclient launched by gnome-shell
17:23:47  CONNECTED
17:23:51  all 4 routes withdrawn
```

**36 minutes 15 seconds of dead tunnel, in total silence.** The operator's own report was "VPN
was connected" — which is exactly right from where he was sitting, because there was no client
left to say otherwise.

**This is the strongest argument for the kernel-state invariant, and it is not the security one.**
§4 rejects log reading because both log directories are attacker-writable. This outage rejects it
for a simpler reason: *there were no logs*. A log-tailing watcher — the first design, killed
during planning — would have seen **nothing at all**, because there was no process writing. It
would not have been wrong; it would have been silent, which is worse. `ip -j link` and
`ip -j route` do not care whether the vendor's process still exists, and the fail-fast unit
reacted in the same second the interface disappeared.

**A prediction this page got wrong, corrected by checking.** The expectation was that
`vpn-sweeps` would MISS this outage: it walks `>STATE` transitions out of the client log, and the
client was dead, so there should have been none to walk. It counts it correctly —
`16:47:31 → 17:23:46, 2175s`, the longest span of the day. The reason is the two-stream join in
§"THE JOIN": `>STATE` also lands in `/var/log/aws-vpn-client/<user>/`, written by the **root**
service, which outlived the GUI. That join was built to fix a 1 ms timestamp mismatch; what it
actually bought was an instrument that survives the thing it measures.

**What it cost, and what it would have cost.** The notifier was only armed 30 minutes into the
outage, so it fired 94 s after it could first see anything. Had it been running at 16:47:31 it
would have fired at about 16:49 — turning a 36-minute silent outage into a two-minute one. That
is the 8.8-hour tail of §3, caught live, on the day it was armed.

One incidental confirmation: the notification body — a compile-time constant reading *"Reconnect
the AWS VPN Client"* — happens to be correct advice for this case too, where the fix is to
relaunch the application rather than wait for a retry. It was written that way because nothing
derived from anything may go in it, not because anyone foresaw this.

---

## 4. The invariant: no runtime component reads a client log

Neither log directory is a trustworthy source:

```
~/.config/AWSVPNClient/logs   drwxrwxr-x zvi:zvi     (the GUI runs as uid 1000, umask 0002)
/var/log/aws-vpn-client/zvi   drwx------ zvi:root
```

Both are **writable by any process running as this user**, and `vpn-failfast.service` runs as
**root**. A root daemon acting on a line any unprivileged process can append is a
privilege-escalation primitive given away for free.

So both daemons read `ip -j link` and `ip -j route` only, which a non-root process cannot forge.
That single decision deletes the entire attack surface two adversarial reviews mapped for the
log-reading designs: assertion theft by squatting `127.0.0.1:35001`, host-allowlist bypass,
counter poisoning, notification markup injection and `E2BIG` restart loops. Nothing acts on
attacker-writable input, so none of them has anywhere to land.

`scripts/vpn-log-report.py` is the deliberate exception: a human runs it, on demand, and it only
counts and prints.

### The notification body is a compile-time constant

GNOME's notification daemon advertises `body-markup` and renders `<a href="…">`. Any log-derived
text in a body would therefore be a phishing sink rendered by a trusted desktop component. Nothing
derived from anything goes in it — no profile name, no timestamp, no URL, no interface name. The
state table asserts the body is byte-identical across two tunnel states and two configs, and
separately that it contains no URL and no markup.

---

## 5. Designs that were killed, so nobody re-derives them

- **A log-tailing re-auth opener.** Duplicate of vendor behaviour (§3). Two independent
  adversarial reviews reached this separately.
- **A default-browser profile shim.** The premise was the query artifact in §3. It also turned out
  to carry a critical flaw of its own: as the system `x-scheme-handler/https` it would move an
  attacker-reachable URL from an *unauthenticated* context into an *authenticated* Workspace
  session, and the `SAMLRequest` is an **unsigned** AuthnRequest (verified across 152 samples:
  the query carries exactly `{idpid, SAMLRequest}`, no `SigAlg`, no `Signature`). And `%h` **is
  not a Desktop Entry field code** — GLib drops unknown macros silently, so the shim's `$0` became
  `/.local/bin/vpn-saml-browser`, `[ -x ]` was false, plain Chrome opened, and the feature would
  never have fired, ever, with no symptom.
- **Headless re-trigger of the connection.** The GUI owns `com.amazonaws.vpnclient` on the user
  bus, but `org.gtk.Actions.List` returns **`as 0` — zero actions**. There is no reconnect to call.
- **The root service's D-Bus** (`com.amazon.awsvpnclient.AwsVpnClientService`, root pid 2708).
  `BecomeMonitor` is `AccessDenied` for uid 1000 and the service returns malformed introspection
  XML, so neither monitoring nor enumeration works.
- **A vendor auto-reconnect setting.** None exists. `Preferences` is
  `{"Version":"1","IsMetricsEnabled":true}` in full, and those two are the only preference keys in
  the binaries.
- **DNS as the stall.** `tun0` carries `~.` with `Default Route: yes`, but `configure-dns` runs
  `resolvectl revert tun0` on the down path and its resolvers are public.
- **`--session-timeout-hours`.** 87 measured session lifetimes: min 1 min, p50 **1.94h**, max
  **27.6h** — a spread whose max exceeds the AWS ceiling of 24h, not the cliff a fixed timeout
  produces. Not the binding constraint. The driver is the server-pushed `ping 1 / ping-restart
  20`: a 20-second UDP gap tears the tunnel down, each restart re-presents the cached assertion,
  and once its window passes the re-auth fails.

### The ACS precondition is not a security control

Recorded here because it is tempting and wrong. At user privilege, "is the ACS listening?" proves
nothing: 35001 is bindable by any process running as this user, `/proc` attribution is
unavailable (the GUI runs as uid 1000 but its `/proc/<pid>/fd` is root-owned and unreadable —
`dumpable=0`, so `ss -ltnp` prints an empty Process column even for the user's own process), and
both anti-abuse counters a watcher might keep live in the same attacker-writable log that triggers
them, so they can be exhausted and reset.

---

## 6. Traps found while building this

### `ip` accepts things that destroy the machine

Measured against the real binary (a well-formed command reaches netlink and returns EPERM
unprivileged; a malformed one fails at parse, which is how these were told apart without root):

```
ip route add unreachable 0.0.0.0/0   proto 66 metric 4242  -> ACCEPTED (reaches netlink)
ip route add unreachable 10.9.8.1/24 proto 66 metric 4242  -> ACCEPTED (installs the whole /24)
ip route add unreachable ::1/128     proto 66 metric 4242  -> ACCEPTED (into the v6 table)
ip route add unreachable 300.1.2.3   proto 66 metric 4242  -> rejected at parse
ip route add unreachable 10.0.0.0/33 proto 66 metric 4242  -> rejected at parse
```

One typo blackholes the internet. Hence the validator, and hence: **every destination is validated
before any is installed**, so a bad entry can never leave a partial set.

`ip -j route show proto 66` works **unprivileged** and returns `[]` when nothing matches — which
is what lets `vpn-doctor` find an orphan without root.

### The tunnel-down test is "a route with a gateway", not "an interface"

With the tunnel healthy, `ip -j route show dev tun0` returns three entries — two with
`"gateway": "172.31.80.1"` (`0.0.0.0/1`, `128.0.0.0/1`) and the interface's own link-scope subnet
route, which has none. On a drop the client deletes the two forwarding routes while `tun0` itself
can **linger, still flagged UP**. So counting routes on the interface calls a dead tunnel healthy;
counting routes *with a gateway* does not. The state table's down-fixture has `tun0` present and
UP for exactly this reason.

### A pretty-printed `ip -j` would have silently disabled every withdrawal

`owned_routes()` originally matched `"dst":"…"` with no whitespace, which is what real `ip -j`
emits. `ip -p -j` pretty-prints. A parser that matches nothing there means **nothing is ever
withdrawn** — no error, no log line, the delete loop simply has nothing to iterate — and every
destination stays blackholed after the tunnel returns. That is the worst outcome this design has,
reachable through a formatting change nobody would connect to it. Found by the state table; the
parser is now whitespace-tolerant and a row feeds pretty-printed output.

### The reporter's two silent-zero bugs

Both were the same shape — a probe that finds nothing and reads as a clean result.

1. **`AUTH_FAILED` was counted three times per event.** The app stream logs each one twice
   (`CM received:` and `CM processsing:`, the vendor's spelling) carrying `>LOG:<epoch>,`; the
   openvpn stream logs it a third time carrying `[PID: …]` and an embedded wall clock. Joining on
   the **openvpn epoch** — never on the wall-clock string, whose millisecond fields differ by 1ms
   across streams on ~20 events — took 100 events over seven days to **50**. Verified:
   `>LOG:1790064100` is `2026-09-22 11:01:40 +03:00` exactly. The corrected count is then **1:1
   with the browser-open count**, which is the relationship measured independently in §3.
2. **The resume probe read only the current boot and then parsed nothing.** `journalctl -k`
   *implies* `-b`: 1 resume where there were 12 over the same ten days, and one resume is a
   perfectly plausible number. Then `-o short-iso` emits `+03:00` here while the regex demanded
   `+0300`, so every line was dropped and the report said **"0 kernel resumes" on a machine with
   nine**. Both now return NOT CHECKED rather than zero when the probe cannot answer, and the
   journal's own start is read from `--list-boots -o json` (`-n 1` returns the *newest* entry, an
   earlier draft used it and reported the journal as starting four minutes ago).

With the probe fixed, the split is visible and matches §3: opens within 120s of a resume have a
p50 of **64.3s** against **15.6s** away from one.

### The first real install pointed a ROOT unit at a worktree

Found on the first `vpn-setup`, from the installed unit itself:

```
ExecStart="/home/zvi/.herdr/worktrees/.dotfiles/zvi-do-692-vpn-resilience/scripts/vpn-failfast.sh"
```

`vpn-setup` resolves its checkout from `$PWD` when that looks like one — right for testing a
branch, wrong for a file root executes for months. **`wt-gc-sweep` deletes landed worktrees
daily**, so that unit was one sweep away from a root service pointing at nothing. It is the same
class as CLAUDE.md's "never run `./install` from a worktree", which this repo already knew about.

The fix is the house pattern, not a new one: a repo script that **root** runs is **copied** to
`/usr/local/bin`, exactly as `backup-verify.sh`, `backup-manifest.sh` and `restic-notify` already
are. `restic-verify.service` is the proof it works here — same `#!/usr/bin/env bash` shebang,
root system unit, `Result=success`. The unit is now static (no placeholder, no renderer), and
`scripts/vpn-render.sh` is deleted because nothing needed it any more.

Moving the script out of `/home` also bought back `ProtectHome=yes`, which had to be weakened to
`read-only` while `ExecStart` lived in the checkout.

**Resolved by removal, not by diagnosis — and the distinction matters.** That first install also
failed with:

```
vpn-failfast.sh[1109118]: coreutils: unknown program 'vpn-failfast'
```

uutils is the system coreutils on this box (`/usr/bin/env -> ../lib/cargo/bin/coreutils/env`), and
its multicall **strips the extension from `argv[0]`** — verified: a symlink named
`vpn-failfast.sh` pointing at `/usr/bin/coreutils` produces exactly that message, while one named
`cat.sh` behaves as `cat`. So something re-entered the dispatcher as `vpn-failfast.sh`. What the
trigger was is unknown: the script runs fine from that same path under systemd's PATH with a clean
environment, and a `systemd-run --user` bisect of every hardening directive reproduced nothing —
which proves little, because the user manager ignores several of them (see below). Reproducing it
needs root, which an agent tool does not have here.

Moving the daemon to `/usr/local/bin` fixed it: the very next install started clean
(**2026-09-23 16:27**, `ActiveState=active`, `NRestarts=0`, empty journal, and `ProtectHome=yes`
in force). So the class is gone and the specific trigger is now moot — but it was never
identified, and this is deliberately not written up as though it was. **A recurrence from
`/usr/local/bin` would be new information.**

### Two directives that would have made the unit unstartable

Both shipped in the first DO-692 PR and were caught by hand, one command before the first
`vpn-setup`. Neither is visible in a diff, and they fail in opposite ways.

**`StartLimitIntervalSec=` in `[Service]` is silently ignored.** systemd moved it to `[Unit]`
in v229; only the legacy `StartLimitBurst` spelling still parses in `[Service]`. So the burst
applied against the **default 10 s interval**, and with `RestartSec=5` five restarts span 20 s
— the limiter could never trip, and a broken unit would have restarted forever without ever
reaching `failed`. That is exactly the crash-loop `check_standalone_service()`'s `NRestarts`
guard was added for, shipped inside the unit that guard was added for.
`systemd-analyze verify` says so in one line; nothing else does. The repo's own
`rabota-precompute@.service` already had it right, in `[Unit]`.

**`ProtectHome=yes` with an `ExecStart` under `/home`.** `systemd.exec` is explicit: `/home`,
`/root` and `/run/user` are "made inaccessible and empty". The checkout **is** the deployment
here, so `ExecStart` is `/home/zvi/.dotfiles/scripts/vpn-failfast.sh` — and the unit could not
have executed its own script, 203/EXEC, on every start. Now `ProtectHome=read-only`, which is
sufficient: the daemon writes nothing under `/home`, and it is root, so this was always
defence-in-depth rather than a boundary.

> **`systemd-analyze verify` does NOT catch the second one.** Measured: with
> `ProtectHome=yes` restored it stayed completely silent, while complaining about the
> `StartLimit` key on the same file. That is why `scripts/test-vpn-failfast.sh` carries a
> dedicated ExecStart-vs-ProtectHome row rather than relying on the verifier.

And a caution about how *not* to test this: a `systemd-run --user -p ProtectHome=yes` probe
reported success, which proved nothing — the **user manager ignores `ProtectHome` entirely**.
Measured, `/home/zvi` held the same 115 entries with and without it. A probe that cannot apply
the setting it is testing returns the answer you wanted.

### DST will break a naive parser on 2026-10-25

Every log line carries an explicit offset. All 12,697 timestamped lines in the corpus carry
`+03:00`; `Asia/Jerusalem` goes to `+02:00` on **2026-10-25** — about four weeks after this was
written, and exactly when the week-later comparison runs. Anything pinning the literal offset
silently reports **zero events**, which reads as "the fix worked". The offset is parsed, never
matched (`%z` accepts both spellings), and `tests/fixtures/vpn/aws_vpn_client_dst.log` carries
both in one file, dated across that transition, with `>LOG:` and `>STATE:` epochs consistent with
their own wall clocks so a broken join cannot pass.

### `grep -c` on a missing file exits 2

Not 1. So `grep -c … || true` turns "the log is gone" into a pass. The suite's own row counter hit
the adjacent version of this: `grep -c . file || printf 0` returns `"0\n0"` on an *empty* file,
because grep prints `0` **and** exits 1, so the `||` fires as well.

### Shell traps on this box

`grep` is ugrep 7.8.4 and `awk` is mawk 1.3.4 (`gensub()` is undefined; `match()`/`RSTART`/
`RLENGTH` exist). `/bin/sh` is dash. `status` is read-only in zsh, so no `local status`. A
`REASON="…" \` continuation followed by another string is an assignment-prefixed **command**, not
a concatenation — shellcheck SC2288 caught three of those in the validator, where the second half
would have been executed and the reason silently truncated.

---

## 7. The ACS port reservation, and what it is not

`net.ipv4.ip_local_port_range` is `32768 60999` and `ip_local_reserved_ports` was **empty**, so
35001 — the port the client's SAML assertion-consumer listener needs — is inside the ephemeral
range. Any process calling `bind(127.0.0.1, 0)` can be handed it. The app log shows
`Acs did not stop correctly!` 51 times, which is *consistent with* contention but is **not proof
of it**.

`sysctl/99-vpn-acs-port.conf` reserves it, installed by `vpn-setup`.

> **This is an availability fix, not a security control.** It stops the kernel *handing out* the
> port. A deliberate `bind()` to a reserved port still succeeds, and `127.0.0.1` is bindable by
> any process running as this user. Nothing in this feature depends on it for safety.

`vpn-doctor` checks it as three separate things — file present, file matches the checkout, and the
port actually in `/proc/sys/net/ipv4/ip_local_reserved_ports` — because a file installed and never
applied looks exactly like success until the next reboot.

---

## 8. Handed over, deliberately not built

- **Sign the second Google account out of the Chrome profiles.** `account_info` has length **2 in
  every profile** (`Default`, `Profile 1`, `Profile 2`), and Google's account chooser fires on
  account *count*, not on which profile is in use. That interstitial is what a re-auth lands on
  when it does not sail through. Zero code, one minute.
- **Wi-Fi power save is on** (`/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf`,
  `wifi.powersave = 3`) with an excellent signal (−43 dBm, 1441 Mbit/s), so it is a cheap suspect
  for the 20-second gaps that trip `ping-restart 20`.
- **Ask the `cvpn-endpoint-079f88f0e29b41688` admin whether the pushed `ping-restart 20` can be
  relaxed.** Not the session timeout — §5 shows that is not the constraint.

The first two are kept out of this feature on purpose: **both move the same numbers `vpn-sweeps`
reports**, so shipping them together with the notifier would make neither measurable. Change one
at a time, a week apart.

---

## 9. Reading `vpn-sweeps` honestly

Its figures are **not** directly comparable to the ad-hoc numbers in §1 and §3. Those were
computed during planning with different filtering — in-use windows only, idle overnight windows
dropped — while `vpn-sweeps` counts every `>STATE` transition in the window. On the seven days to
2026-09-23 it reports 39 outages and 0 self-healed, and that zero is correct for that window:
every one of the 39 spans has an `AUTH_FAILED` strictly inside it, checked directly.

**Compare the tool to itself.** The number this work targets is *SAML timeout → next attempt*.

---

## 10. The IPv6 leak, and the block that closes it (DO-704)

The endpoint is `SplitTunnel=False`, but **only IPv4 is tunnelled**. The client installs the
classic `0.0.0.0/1` + `128.0.0.0/1` pair over `tun0` and *nothing at all* for IPv6, so the v6
default route still points at the ISP. Measured on a connected client: `curl -4 ifconfig.me`
returns the VPN's NAT gateway, `curl -6` returns the ISP address — and `curl` with no family flag
preferred v6, so on a dual-stack network the leak is the **default** path, not an edge case.

Both alternatives are closed. **Split tunnel** is ruled out: nine security groups allowlist the VPN
egress IP `34.230.137.243/32` (including production `Q-Proxy` with `IpProtocol: -1`) and the EC2
instances are reached over their *public* IPs, so split tunnel would break SSH/HTTPS/RDP for all
six users. **Dual-stacking** is impossible: `vpc-80a6c6fd` has no IPv6 CIDR and neither does the
VPN subnet, so there are no v6 routes to push. The fix is therefore client-side only, and it
changes nothing for the endpoint or the other five users.

### Why routes and not nftables, and not `ip rule`

`nft list table` **requires root**. `vpn-failfast.sh --status` and `vpn-doctor` are unprivileged by
contract, and the doctor's most valuable question is the orphan one — so a mechanism only root can
read would blind the check that matters most. A route is readable with `ip -6 route show proto 66`
and *evaluable* with `ip -6 route get`, both unprivileged.

`proto 66` is already the identity for "what this tool may remove", and the v6 filter genuinely
filters — verified on this box:

```
$ ip -6 route show proto 66 | wc -l      ->  0
$ ip -6 route show proto ra  | wc -l     ->  4
```

**`ip -6 rule show protocol 66` does NOT.** It silently ignores the filter and prints every rule
with rc 0:

```
$ ip -6 rule show protocol 66 | wc -l    ->  6      # every rule on the box
```

That is the whole reason the `ip rule` design was killed: a cleanup loop written against that
output would have deleted Tailscale's four rules. The trap does not apply to `route show`, which is
why one is used and the other is not.

A reject **route** has one more property a netfilter rule does not: it is visible to glibc's
RFC 6724 reachability probe (a UDP `connect()` that sends no packet), so v6 addresses sort *last*
and naive connect-the-first-result code never pays a failed v6 attempt.

### The destinations: `::/1` + `8000::/1`, never `2000::/3`

```
$ ip -6 route get 64:ff9b::1
64:ff9b::1 from :: via fe80::bed5:edff:fe4c:c652 dev enx8c3b4a256b7a proto ra ... metric 100
```

The well-known NAT64 prefix is in **`::/3`**, not `2000::/3`. On an IPv6-only hotspot with
PREF64+DNS64 every AAAA answer is a `64:ff9b::/96` address, and `2000::/3` would block **none** of
it. That is a prefix bug, not a mechanism bug — the nftables variant had it identically.

Nothing that should keep working is caught by the `/1` pair, measured rather than assumed:

| what | why it still works |
|---|---|
| multicast `ff00::/8` | lives in `table local` (17 entries), consulted by rule 0 before anything else |
| `fe80::/64` link-local | longest-prefix-match, metric 256/1024 |
| the on-link LAN `/64` | longest-prefix-match, metric 100/600 |
| Tailscale `fd7a:115c:a1e0::/48` | rule **5270 → table 52**, evaluated *before* `32766 → main` |

Verified: `ip -6 route get fd7a:115c:a1e0::53` → `dev tailscale0 table 52`. The pair is also the
exact mirror of the `0.0.0.0/1` + `128.0.0.0/1` the client installs for IPv4, which makes it
self-explanatory in a routing table.

### `expires` is ACCEPTED on an `unreachable` v6 route and silently not applied

This is the measurement the whole "no dead-man switch" decision rests on, and it was taken
first-hand rather than carried — see *How these were measured* below.

Both routes were created in the same namespace, by the same binary, in the same second:

```
SUBJECT  ip -6 route replace unreachable ::/1 proto 66 metric 4242 expires 5          -> rc 0
CONTROL  ip -6 route replace 2001:db8:aaaa::/48 via 2001:db8:1::2 dev dummy0 \
                             proto 66 metric 4242 expires 5                           -> rc 0

immediately:
  2001:db8:aaaa::/48 via 2001:db8:1::2 dev dummy0 metric 4242 expires 4sec pref medium
  unreachable ::/1 dev lo metric 4242 pref medium                  <- NO expires AT ALL

12 seconds later:
  2001:db8:aaaa::/48 via 2001:db8:1::2 dev dummy0 metric 4242 expires -7sec pref medium
  unreachable ::/1 dev lo metric 4242 pref medium                  <- still none
```

`expires` is **accepted with rc 0 and the attribute is never attached** to an `unreachable` route:
nothing in `show`, no `"expires"` key in `-j`, immediately or ever. The control is what makes that
conclusive rather than suggestive — the flag is plainly honoured and displayed on a nexthop route
in the identical environment.

**A correction to the planning note, which said the control "expired correctly".** It did not get
*deleted* within the window either; it went to `expires -7sec`, so the kernel's fib6 garbage
collector had simply not run. What the control demonstrates is **attachment**, which is the
sharper fact: there is nothing to expire on a reject route, rather than an expiry that is merely
slow. The conclusion — ship no dead-man switch — is unchanged and better supported.

A dead-man switch built on it would be a safety claim that silently is not true, which is the exact
shape this repo exists to prevent. It is not shipped. Withdrawal is guaranteed instead by four
named things, none of them automatic: `ExecStopPost=--clear` (systemd runs it on *every* stop,
including a killed main process), the clear-at-start on `--watch`, the boot-time start via
`WantedBy=multi-user.target`, and `vpn-doctor`'s orphan check.

### An observation, recorded but not investigated

`tailscale netcheck` reports the machine's IPv4 STUN result as **79.177.134.244** — the ISP's
address — while `curl -4 ifconfig.me` at the same moment returns **34.230.137.243**, the VPN's NAT
gateway. So ordinary TCP egresses through the tunnel on v4 while Tailscale's own UDP underlay
apparently does not. That is Tailscale's encrypted traffic to the user's own tailnet, not Quantivly
traffic, and it is outside DO-704's scope; it is written down because it was seen, not because it
was chased.

### How these were measured

`unshare -rn` is refused on this box — the kernel restricts unprivileged user namespaces
(`write failed /proc/self/uid_map: Operation not permitted`) — and bubblewrap gives a private
netns but cannot grant `CAP_NET_ADMIN`. The measurements above were therefore taken in a container
with `--network none`, which is an empty network namespace: only `lo`, no veth, no bridge
attachment, no nft rules, and the host's routing table and its five Docker networks untouched.

**The host's own `ip` was chrooted in rather than the image's**, and that mattered:

```bash
docker run --rm --network none --cap-add NET_ADMIN -v /:/hostfs:ro \
  --entrypoint sh postgres:16 -c 'chroot /hostfs /usr/bin/ip ...'
# ip utility, iproute2-6.19.0, libbpf 1.6.3   <- identical to the host's
```

Both local images that ship an `ip` (`iq-diag`, `semgrep/semgrep`) carry **BusyBox**, whose error
table is its own: for the same errno it prints `RTNETLINK answers: Host is unreachable`, not
`No route to host`. A measurement taken with it would have looked exactly like confirmation and
recorded the wrong string into a fixture that the whole canary design turns on.

### `ip -6 route get` semantics, which made the first canary design exactly backwards

Measured on iproute2-6.19.0:

| case | rc | stdout | stderr |
|---|---|---|---|
| reachable | 0 | the winning route | — |
| a reject route wins | 2 | **empty** | `RTNETLINK answers: No route to host` |
| no IPv6 at all | 2 | **empty** | `RTNETLINK answers: Network is unreachable` |

So `grep -q unreachable` on the output is **never** true for the blocked case and **always** true
for the no-IPv6 case — a green tick for a block that is not installed, on the machine least able to
notice. `_vpn_v6_probe` classifies rc and the message instead, and returns four states with
`no-v6` explicitly **not** a pass. Three further rules sit on top: `blocked` passes only if this
tool also owns both halves (otherwise the tick credits our block for somebody else's reject route),
`open` is the FAIL and prints the winning route verbatim, and anything unrecognised is `odd`.

`ip -6 route show` is **not** a substitute. It lists what exists; only `route get` asks the kernel
which route *wins*, and a more-specific route from an RA, a second VPN or a v6-enabled Docker
network beats ours without changing the list at all.

### Two accepted bypasses, both documented rather than fixed

- **A more-specific route silently wins.** An RFC 4191 RIO from the router, a second VPN, or a
  v6-enabled Docker network installs something longer than `/1` and takes precedence. Detected by
  the `ip -6 route get` canaries in `vpn-doctor`, which is why those are `route get` and not
  `route show`.
- **oif-pinned sockets bypass it on IPv6 but not IPv4.** A reject route's nexthop device is `lo`,
  and the v6 lookup backtracks on device mismatch; IPv4 runs its reject check *before* the oif
  comparison. So `SO_BINDTODEVICE`/`IPV6_PKTINFO` traffic escapes. Neither affects ordinary
  application traffic — and this is also why there is **no `SO_BINDTODEVICE` probe** in
  `vpn-doctor`: besides `CLAUDE.md` forbidding forcing a drop to test, it would report a *false*
  "not blocked" for a block that is working perfectly.

### A ≤5 s leak window on every connect and every resume

`run_watch` monitors `ip monitor link`, but the transition that matters is a *route* appearing on
`tun0`, not a link event. So the block lands on the next 5-second poll rather than on the event.
Keeping `link` is deliberate — route events are high-volume and the poll is the correctness
guarantee by design, not the optimisation — but the window is real and is written down here rather
than left to be discovered.

### Mutation sweep, 23 mutants

Measured against the four files the mutants touch, identified by content rather than by a commit
id — an amend rewrites the sha and would leave this paragraph naming a commit that no longer
exists, which is the shape of stale evidence this page exists to avoid:

```
3f6a5c1d…  scripts/vpn-failfast.sh
6c968cb2…  scripts/test-vpn-failfast.sh
542ac973…  scripts/setup-vpn-failfast.sh
5b3df058…  zsh/functions/system.sh
```

Every expected verdict was written down **before** the sweep ran, each mutant was dry-run for
applicability first (**23/23 matched exactly once** — a pattern that no longer applies reads
exactly like a survivor), each was diffed before its suite run, and each was restored by explicit
path with the tree asserted clean and re-sha'd afterwards.

**23/23 matched their expected verdict.**

| mutant | expected | got |
|---|---|---|
| invert the v6 polarity | KILLED | KILLED |
| `::/1`+`8000::/1` → `2000::/3` | KILLED | KILLED |
| drop the family from the v6 show | KILLED | KILLED |
| delete always with `-4` | KILLED | KILLED |
| add with the wrong family | KILLED | KILLED |
| gate the tunnel-down v6 clear on the arming switch | KILLED | KILLED |
| `clear_all` iterates v4 only | KILLED | KILLED |
| drop `clear_owned`'s re-read guard | KILLED | KILLED |
| put `metric` back into the v6 delete | KILLED | KILLED |
| swallow the v6 `add` exit status | **SURVIVE** | SURVIVED |
| unknown knob value treated as `block` | KILLED | KILLED |
| unknown knob value treated as `off` | KILLED | KILLED |
| let `--once` install the block | KILLED | KILLED |
| both-family `clear_owned` on the up-branch | KILLED | KILLED |
| doctor treats a tunnel-down orphan as ok | KILLED | KILLED |
| doctor classifies `no-v6` as blocked | KILLED | KILLED |
| doctor accepts `blocked` without the halves | KILLED | KILLED |
| doctor greps `unreachable` instead of classifying | KILLED | KILLED |
| drop the installer's drop-in value check | KILLED | KILLED |
| drop the installer's `try-restart` | KILLED | KILLED |
| make the `try-restart` unconditional | KILLED | KILLED |
| delete a row **and** lower `EXPECTED_ROWS` to match | **SURVIVE** | SURVIVED |
| let the `sudo` stub write outside `VPN_SETUP_PREFIX` | **SURVIVE** | SURVIVED |

**The three survivors are the informative rows, and each was predicted:**

- **Swallowing the v6 `add` status.** `converge()`'s rc on that path has no observer by
  construction: `--once` *refuses* the block so it never runs there, and `run_watch` swallows
  converge's rc deliberately — a transient route failure must not kill the daemon. The observable
  guarantee is the error *message*, which a row pins. Inventing a row for a dead rc would be
  decoration, so none was added.
- **Deleting a row and lowering the total to match.** This is what a row total does *not* catch,
  demonstrated rather than asserted. `check-state-table-totals.sh` says the same thing in prose;
  this is the measurement behind it.
- **Letting the `sudo` stub write outside the prefix.** A detector mutant with no fault present:
  no row puts the tree in the state that guard detects, so disabling it is unkillable *by
  construction*. Recorded rather than "fixed", because the alternative — a row that deliberately
  tries to write outside the prefix — would mean arming the exact failure the guard exists to
  prevent.

Two mutants exist only because earlier drafts would have failed them silently. **`M06`** (gating
the tunnel-down v6 clear on the arming switch) survived until a row was added that puts a v6 route
under our proto into a *disarmed* daemon's table **mid-run** — the start-clear cannot reach that
case, so every other row was blind to it. **`M17`** (accepting `blocked` without owning both
halves) survived while that guard lived inside `vpn-doctor`'s own `case`, reachable only with a
whole machine in the state it describes; extracting `_vpn_v6_canary_verdict` as a pure helper is
what made it killable.

### `sudo vpn-setup` cannot work, and it shipped in the doctor's own remedy

`vpn-setup`, `vpn-init`, `vpn-doctor` and `vpn-status` are zsh **functions**. `sudo` can only exec a
binary, so `sudo vpn-setup --block-ipv6` fails with `sudo: 'vpn-setup': command not found` before it
does anything at all. The function runs `bash scripts/setup-vpn-failfast.sh`, and *that* escalates
per-command — which is precisely why it needs no leading `sudo`.

DO-704's approved plan wrote `sudo vpn-setup` throughout, and it was copied into the guide, this
page and — worst — two of `vpn-doctor`'s own remedy lines, where it would have been the first thing
a user typed after being told something was wrong. The pre-existing setup section three screens
above had it right the whole time (`vpn-init` / `vpn-setup`, no `sudo`), which is the tell: a rule
this file already stated was contradicted by new prose written from a plan rather than from the
code.

A row now checks `system.sh` anywhere, and the two VPN pages **only inside fenced code blocks** —
because prose that names the broken form in order to document it is legitimate, and the first
version of the row failed on the heading immediately above this paragraph. A row that cannot tell a
remedy from a description of one would be paid for by deleting the explanation, which is the wrong
direction. Verified in all three directions rather than one: red on a doctor remedy, red on a docs
code fence, green on this prose.

It was CI that caught it, not the local run, and the reason is worth recording: the heading was
added *after* the last full suite run, and only the static checkers were re-run afterwards. Running
"the gate" is not the same as running the gate.

### `enable --now` does not re-read a drop-in on a unit that is already running

Found in the local review, before merge, and it would have made arming a no-op on the only machine
that matters. `setup-vpn-failfast.sh` ended with `systemctl daemon-reload` then
`systemctl enable --now`. `enable --now` runs `start`, and `start` on an **already-active** unit
does nothing — it does not re-read `Environment=`. vpn-failfast is active on this box with
`NRestarts=0`, so `vpn-setup --block-ipv6` would have installed the drop-in, reloaded,
reported success, and left the daemon running with `VPN_FAILFAST_IPV6` unset until the next reboot.

The pairing is what makes it nasty rather than merely wrong: the installer says *armed* and
`vpn-doctor`, reading the routing table, correctly says **IPv6 is LEAKING**. A green install next
to a red doctor is the shape that gets the doctor mistrusted.

The fix is `systemctl try-restart`, guarded on the arming state having actually changed.
`try-restart` restarts a unit only if it is already running and is a no-op otherwise, so it cannot
start a unit that `--no-enable` deliberately left stopped; the guard means a routine `vpn-setup`
after a `git pull` still bounces nothing — which matters, because that daemon may be holding
fail-fast routes for a tunnel that is currently down.

### A sort whose order was a property of the developer's locale, not the code

The first push went red on CI with four rows green locally:

```
✗ armed + UP: EXACTLY the two halves — expected '::/1 8000::/1 ', got '8000::/1 ::/1 '
```

`installed6()` piped through a bare `sort`. Under **en_US.UTF-8** collation punctuation is ignored,
so `::/1` sorts first; under **C/POSIX** it is byte order, `:` is `0x3A` and `8` is `0x38`, so
`8000::/1` sorts first. A developer machine is usually the former and a GitHub runner the latter,
so the expectation was a property of whoever ran the suite. The IPv4 expectations were unaffected
and hid it — those destinations are digits and dots, which collate identically both ways, which is
why this only surfaced once IPv6 destinations existed.

Every `sort` in this suite is now `LC_ALL=C sort`, and the expected strings are written in byte
order. Verified by running the whole table under both `LC_ALL=C` and `LC_ALL=en_US.UTF-8`: 235/235
either way.

**This is not unique to this file.** Ten other `scripts/test-*.sh` pipe through an unpinned `sort`.
Whether any of them is latently wrong depends on whether its data carries punctuation that collates
differently, which has not been audited here — it is a separate piece of work, named so that the
next person to be bitten finds this paragraph rather than re-deriving it.

### The state table was one successful `sudo` away from overwriting the running root daemon

`scripts/test-vpn-failfast.sh`'s installer rows set `VPN_SETUP_ALLOW_WORKTREE=1`, which is the
entire point of one of them. The guard at `setup-vpn-failfast.sh:93` therefore does **not** exit:
execution runs on through the readable-config check, `--check` and the placeholder grep, and
reaches

```
sudo install -m 755 -o root -g root "$SCRIPT_SRC" /usr/local/bin/vpn-failfast.sh
```

where `$SCRIPT_SRC` is the *branch's* script. The row's needle is printed thirty lines earlier and
the `|| true` swallows the status, so **the row passed whether or not an install happened**. Only
the absence of a usable `sudo` stopped it on a developer's machine; CI has passwordless sudo, so
the green history never once exercised the inert path — and `install(1)` writes **in place**, which
means rewriting the running root daemon's file underneath it. This file's own header claimed "No
sudo, no root"; that claim was part of the defect.

Confirmed by hand against a real `git worktree` fixture before the fix: the recorded escalation was
exactly the line above. A recording `sudo` stub now sits at the front of `PATH` on both rows. It
executes only `install`/`rm`/`rmdir`/`mkdir`, only inside `VPN_SETUP_PREFIX`, and refuses any
destination outside it with its own exit code — `systemctl` and `sysctl` are recorded and never
run, because the machine running the suite has a live system manager holding this very daemon.
