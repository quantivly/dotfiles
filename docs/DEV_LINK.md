# The dev link: ssh to dev over AWS SSM

**Guide + maintainer's record.** The first half is for someone operating the link; the second
is the evidence behind every rule in it, measured on 2026-10-27 from this laptop's own logs and
the AWS account.

## What the link is

`ssh dev` does not cross the Client VPN and does not open port 22 anywhere. The `Host dev` block
in `~/.ssh/config` (DO-758) names the EC2 instance id as `HostName` and runs

```
ProxyCommand aws ssm start-session --profile dev-ssm --region us-east-1 --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p
```

so every connection is an SSM Session Manager channel, authenticated by the AWS profile the
command pins, and then an ordinary ssh handshake inside it, authenticated by the ssh agent.
The link therefore has exactly three dependencies, and a failure is always one of them:

| dependency | fails as | the doctor's row |
|---|---|---|
| the AWS credential behind `--profile dev-ssm` | `Connection closed by UNKNOWN port 65535` (exit 255): the ProxyCommand died before the banner | 3, 4, 8 (`cause=proxy`) |
| the ssh agent and its key (Bitwarden's agent, vault timeout `onRestart`) | `Permission denied (publickey)`, or a hang on `ssh-add -l` after a reboot | 7, 8 (`cause=auth`) |
| the network, or dev itself (stopped, SSM agent down) | a timeout, `ConnectionLost` in SSM | 5, 8 (`cause=timeout`, `network`) |

The Client VPN is irrelevant to all three. While it is up its full tunnel carries the SSM
websocket like everything else, so a tunnel restart kills an open session, but a new one needs
nothing from it.

## Checking it: `dev-link-doctor`

```bash
dev-link-doctor              # the eleven rows below, exit non-zero on any ✗
dev-link-doctor --offline    # rows that need no AWS and no dev; skipped rows are NOTES, never ✓
dev-link-doctor staging      # another Host block (the rows about SSM apply only if it is one)
```

| row | asks | ✗ means |
|---|---|---|
| 1 | `aws`, `session-manager-plugin`, `ssh` on PATH | install them (mise has awscli; the plugin is a deb) |
| 2 | `ssh -G dev`: an SSM ProxyCommand pinning `--profile` | ⚠ with no `--profile`: the default profile is an `aws login` session, capped at 12 h by AWS |
| 3 | `sts get-caller-identity` as that profile is `user/<DEV_LINK_AWS_USER>` | the WRONG identity (an admin key here is what this row exists to catch); ⚠ unpinned until `DEV_LINK_AWS_USER` is set in the secrets file |
| 4 | the profile's own key is among that user's keys, and its age | not this user's key (the pin is wrong); ≥ 180 days (rotate); ⚠ ≥ 90 days, two active keys, or `ListAccessKeys` denied (UNVERIFIED, never ✓) |
| 5 | dev's SSM agent `PingStatus` | not `Online` (stopped instance, dead agent); unregistered; ⚠ denied |
| 6 | `~/.aws` is 700 and `credentials` is 600 | a group member could replace the key (the directory was 775 here, umask 002) |
| 7 | `ssh-add -l` answers within 2 s | unlock the Bitwarden vault; asked BEFORE the ssh row so a locked vault is never reported as a credential fault |
| 8 | one FRESH ssh: `ControlMaster=no ControlPath=none BatchMode=yes`, wrapped in a 40 s `timeout` | the cause, classified: ProxyCommand, agent/key, timeout, network |
| 9 | INFO: is a control master open? | a master answers plain `ssh dev` for 10 min after the credential dies |
| 10 | INFO: the VPN tunnel, and whether fail-fast blackholes dev's IP | irrelevant to SSM, printed so nobody chases it |
| 11 | `dev-link-probe.timer` linked, enabled, active, last run `success` | ⚠ not linked: `./install`; linked-not-enabled is a decision, spelled out |

The probes behind rows 2 to 5 and 8 are `scripts/dev-link-probe.sh` (`--resolve`, `--api`,
`--keys`, `--ssh`), so the doctor and the probe timer share one definition of each; the doctor
holds only the verdicts. The profile and the instance id are read from `ssh -G`, never carried
as constants, so the doctor cannot disagree with the ProxyCommand about which profile is in play.

After a fix, the order is `dev-link-doctor` → `rabota census` → `rabota budget --machine dev`:
`rabota/rabota/budget.py` refuses on `census:stale` and `machine:unmeasured` until a fresh census
has seen dev, by design.

## Watching it: `dev-link-probe.timer`

`./install` links `systemd/dev-link-probe.{service,timer}` and does not enable them; arming a
timer that opens an SSM session to dev every hour is a decision:

```bash
systemctl --user enable --now dev-link-probe.timer
scripts/dev-link-probe.sh --status      # the last 24 h by cause, and the current outage markers
journalctl --user -u dev-link-probe.service -e
```

Every 10 minutes the service runs `dev-link-probe.sh --once`: the API pair (identity, SSM
registration) every tick, the fresh ssh only when the last success is more than an hour old or
while the link is recorded as down (so recovery is seen within one tick, and a healthy day costs
24 SSM sessions, not 144). Each run appends one TSV line, `epoch api= ssh= ms= cause= detail=`,
to `~/.local/state/dev-link/probe.log` (kept to the last 2000 lines) and keeps two markers next
to it, `down-since` and `notified`. After 20 minutes down (the first failing tick anchors the
outage, the third failing tick, 20 minutes later, notifies) it raises one critical desktop
notification with a constant body, "Run dev-link-doctor for detail.", and
withdraws the markers on recovery so the next outage notifies again. A clock that went backwards
(a resume, an NTP step) re-anchors the outage instead of notifying early.

Three rules, each measured against a wrong version that looked right:

- **Dev being down is exit 0.** `check-timer-health.sh` reports a timer-activated unit that
  exits non-zero as the *timer* being broken, and so is a unit skipped by a `Condition*`. The
  service has no `Condition*` line (the state table asserts it); the only non-zero exit is 1
  when `notify-send` itself failed, and then the `notified` marker is not written so the next
  tick retries.
- **The body is a constant.** GNOME renders markup in notification bodies, so nothing derived
  from a log line, a hostname or an error goes in; the state table compares the argv of two
  separate outages byte for byte.
- **`Persistent=false`.** A laptop back from sleep must not replay the missed ticks into a burst
  of SSM sessions; the markers carry the outage across sleep.

A tick that cannot reach `sts` at all (no network, DNS failure, the 15 s timeout) is logged as
`cause=network`, never `credential`: a laptop on battery without a network must not book an
offline stretch against the key. The notification still fires after 20 minutes of it; whether an
offline laptop should be told its dev link is down is a decision not yet taken.

Row 11 of the doctor reports the timer: linked, enabled, active, and the last run's `Result`.

Two `aws` binaries live on this box: the timer's pinned `PATH` resolves `/usr/local/bin/aws`
(aws-cli 2.35.13, root-installed), the interactive shell resolves mise's 2.34.29. "One
definition of each probe" holds for the argv, not the binary; both are v2 and both pass the
doctor's row 1, and `scripts/verify-tools.sh` vets only the mise one.

## The credential (Phase A of the 2026-10-27 plan)

A dedicated IAM user whose only permission is opening an SSM session to the dev instance:
`ssm:StartSession` on the instance ARN and the `AWS-StartSSHSession` document ARN with
`ssm:SessionDocumentAccessCheck` set (without it the document ARN is not binding),
`TerminateSession`/`ResumeSession` on `session/${aws:username}-*`, and two read-only actions
for the doctor (`ssm:DescribeInstanceInformation`, `iam:ListAccessKeys` on itself). Its access
key lives in `~/.aws/credentials` under `[dev-ssm]`, which the secret-emission guard refuses to
print (docs/SECRET_EMISSION.md). The hand-run steps, the policy JSON and the negative controls
(another instance, another document, `ec2:DescribeInstances`, all AccessDenied) are in
`~/quantivly/handoffs/2026-10-27-dev-link/README.md`.

Why an explicit `--profile` and not `AWS_PROFILE`: with `--profile`, botocore drops the
environment credential provider, so a shell that exports `AWS_ACCESS_KEY_ID` (the backup
scripts do, inside `sudo bash -c`) cannot hijack the ProxyCommand. `AWS_PROFILE` alone does not.

Accepted trade: a long-lived key readable by every process as this user is a weaker credential
than a 12-hour console session. The scope (one action, one instance) and row 4's age check are
the controls; rotation is a doctor finding, not a calendar entry.

## The record: why it was built this way

**The symptom.** "I keep needing to reconnect the aws CLI a couple of times a day, and dev goes
dark." Measured 2026-10-27: the ProxyCommand used the `default` profile, which was
`login_session = …:user/AdminZvi`, the `aws login` console-session mechanism. AWS documents it
as a local-development login whose session is "valid for up to the set session duration of the
IAM principal (maximum of 12 hours), after which you must run `aws login` again"; the access
token in `~/.aws/login/cache/` is refreshed every 15 minutes until then. The account has no IAM
Identity Center (0 instances), so no longer-lived SSO session was available. Every new `ssh dev`
after the cap failed with `Connection closed by UNKNOWN port 65535`; the 30-minute census then
wrote dev unreachable with that text, every dev lane refused, and nothing said why. The identity
in the unattended path was a full administrator (`Administrators`, `QuantivlyIT`).

**Three ways it looked fine while broken.**
- `ControlPersist 10m`: an open master answered `ssh dev true` for ten minutes after the
  credential died, so an interactive check passed while the timer's fresh connection failed.
  Row 8 bypasses the mux; row 9 names an open master.
- `ssh-add -l` on the Bitwarden agent hangs when the vault is locked (5 s measured 2026-10-14),
  and a hung agent reads like a dead credential. Row 7 bounds it at 2 s and runs first.
- A key-age check that is *denied* looks like a key that is *fine* unless the row refuses to
  tick on AccessDenied. Row 4 never ticks on anything but a read it made.

**Rejected.** Keeping `aws login` (the cap is AWS's); Identity Center (absent); IAM Roles
Anywhere (needs a CA); Tailscale or WireGuard to dev (a new component on a company box, a
tailnet policy decision, and this laptop's own Tailscale coordination was already degraded by
the full-tunnel VPN).

**The VPN is a separate fault and stays separate.** The same investigation measured the AWS
Client VPN (endpoint `cvpn-endpoint-079f88f0e29b41688`): full tunnel, SAML-only, AWS-pushed
`ping 1 / ping-restart 20`. Over 23 log-days, 49 inactivity restarts and 24 `network-unreachable`
drops, 102 SAML challenges for 76 connects, and after the vendor client's 600 s SAML timeout no
retry, so unattended drops became outages of 6 to 43 hours. The endpoint's own connection log
showed every user re-logging in about four times a day and this laptop 26 times. None of that
touches the SSM path; the split-tunnel proposal for the endpoint is a team decision recorded in
`~/quantivly/handoffs/2026-10-27-dev-link/`, and docs/VPN_RESILIENCE.md covers the VPN layer.

**State table.** `scripts/test-dev-link.sh` (230 checks, run in CI, hermetic: `aws`, `ssh`,
`ssh-add`, `systemctl` and `ip` are recording stubs at the front of a PATH built from scratch,
and `$HOME` is a fixture, because this box has a real `aws` wired to live credentials and a real
`ssh dev` that would spend an SSM session). Mutation sweep, 2026-10-28: fourteen mutants, each
diffed for applicability before its run. Thirteen were killed on the first pass, among them
dropping `ControlPath=none` (row "the connection bypasses the control socket"), printing the
ARN whole (the no-account-id rows), reading a denied `ListAccessKeys` as ok, making the
counters global, and `--offline` still calling `aws`. The fourteenth, rows 7 and 8 swapped,
SURVIVED: the row meant to pin their order compared `grep -n`'s output with the same output
sorted, and `grep -n` prints in file order, so the two were always equal and the row could not
fail. It now compares the two line numbers, and the mutant dies on it. The one documented
survivor class is the totals guard's own blind spot: deleting a row and lowering
`EXPECTED_ROWS` cannot be caught by the suite that does it. The timer half's sweep, same day,
nine mutants, all killed: exit 1 while dev is down, notify every tick, a body that interpolates
the host and the time, no log truncation, a `Condition*` on the service, `Persistent=true` on
the timer, a fresh ssh every tick, a fresh ssh skipped while the link is down, and the
`notified` marker written although `notify-send` failed. A fresh-context review of the branch
then found that an offline tick was booked as `cause=credential`; classified and pinned since
(seven rows).
