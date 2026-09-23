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
same connect must return `ENETUNREACH` immediately.

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
