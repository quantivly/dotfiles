# Fingerprint: beside the password on the lock screen, after it in sudo

The fingerprint reader is wired in without ever putting a fingerprint wait in front of a
password. That is the one hard requirement, and it decides where the reader is used and where it
is not.

| Surface | Lid open | Lid closed (docked) |
|---|---|---|
| Lock screen | touch **or** type, at the same time | type |
| Login screen at cold boot | password only | password only |
| `sudo` / `sudo -i` in a terminal | type the password, **or** press Enter on the empty prompt, then touch | type the password; Enter just asks again |
| `sudo` with no terminal (agents, Claude Code's `!`) | password only, as before | password only |
| GNOME admin dialogs, `pkexec`, `run0`, Bitwarden unlock, `su`, TTY login, ssh | password only (untouched) | password only |

## Set it up

You need `fprintd` and `libpam-fprintd`, which Ubuntu installs by default, and a terminal of your
own: `sudo` cannot run from a Claude Code session.

1. **Open a root shell in a second tab first** (`sudo -i`) and leave it open. It is the safety
   net if anything in the PAM stack goes wrong.
2. Run `fingerprint-setup`. It prints what it installs and finishes with the same verdict as
   `fingerprint-setup --check`. From a worktree, it refuses unless you set
   `FINGERPRINT_SETUP_ALLOW_WORKTREE=1`.
3. Enrol two fingers. Use **Settings → System → Users → Fingerprint Login**, or run
   `fprintd-enroll -f right-index-finger`, then `fprintd-enroll -f left-index-finger`. Lift
   fully between touches and shift a little each time. Confirm each finger with
   `fprintd-verify -f <finger>`: with no `-f`, it checks only the first finger enrolled. sudo
   accepts any of them.
4. Try it with `sudo -k; sudo true`. Press Enter at the password prompt, and touch the reader
   when it asks.

The lock screen needs nothing beyond step 3. The greeter change takes effect at the next cold
boot.

## Using it

- **sudo asks for the password first, and it works at once.** To use the reader instead, press
  Enter on the empty prompt (a wrong password does the same). sudo then says "Place your finger
  on the fingerprint reader".
- **Ctrl+C at the finger prompt:** sudo asks for the password again.
- **Each detour costs one of sudo's three tries.** Ctrl+C, a finger that fails twice, and an
  Enter while docked each end that try, and sudo's next try asks for the password again.
  Nothing re-asks inside a single try: `common-auth` re-checks the same password, as
  "The stanza, through the real libpam" below shows.
- **Docked, the reader is never offered:** with the lid closed, Enter on the empty prompt just
  uses up that try, and sudo asks again.
- **The lock screen takes either one, whichever comes first.**
- **Each decision is logged** with the reason: `journalctl -t fingerprint-gate`. Expect lines
  such as `offer: lid open, terminal attached`, `skip: lid closed` and `skip: no terminal`.
- **Each switch to the reader logs one `pam_unix` "authentication failure"** in the journal,
  because the empty password really did fail. That is expected.

## Check, remove, repair

```bash
fingerprint-setup --check    # read-only, no sudo; exit 1 on any drift
fingerprint-setup --remove   # takes it all out; the edited files return byte-identical
```

`--check` verifies the installed state, not the install's exit status:

- The gate and the stanza are root-owned regular files, byte-identical to this checkout.
- `sudo` and `sudo-i` include the stanza exactly once, immediately before
  `@include common-auth`.
- **The installed sudo stack loads through the real libpam and accepts a correct password.**
  This catches a stanza that matches its checkout but cannot be parsed: one misspelled keyword
  makes libpam refuse every sudo. The install runs the same test on the stack it *would* leave,
  and refuses to write anything that fails it.
- **`common-auth` runs only modules a password checked first may skip.** The stanza checks the
  password *before* `common-auth`, so a lockout (`pam_faillock`) or a second factor added there
  later would be passed over. The install refuses, and `--check` fails, on anything outside the
  known set.
- The greeter key is set by this setup's line alone, and gdm has recompiled it.
- **No effective PAM service except `gdm-fingerprint` and this stanza runs `pam_fprintd`.** This
  last check is the requirement, as a check. The stock `pam-auth-update --enable fprintd` puts
  the reader in front of the password in `common-auth`, which means every service.

**After a `sudo-common` or `gdm3` upgrade, run `--check`.** `/etc/pam.d/sudo` and `sudo-i` are
conffiles, so an upgrade that ships a new one asks whether to keep yours. Taking the maintainer's
version only drops the include, and sudo simply goes back to password-only. Re-run
`fingerprint-setup` to put it back.

**If `--check` says sudo "refuses everyone"**, either the stanza is gone while `sudo` still
includes it, or libpam cannot load the stack. Either way every sudo fails before it asks for
anything. polkit is untouched, so repair it from a GNOME dialog:

```bash
pkexec sed -i '/^@include sudo-fingerprint$/d' /etc/pam.d/sudo /etc/pam.d/sudo-i
```

## What is not covered

- **GNOME's admin dialogs, and so Bitwarden's "unlock with biometrics".** That dialog runs one
  serial PAM conversation and will not submit an empty password (below), so a fingerprint there
  could only come first, and wait. Bitwarden's unlock goes through polkit, so it asks for the
  login password.
- **Chrome passkeys (WebAuthn).** Linux has no biometric platform authenticator.
- **`su`, TTY login and ssh.** They stay on the password. `pam_fprintd` refuses remote sessions
  anyway.
- **Firmware.** The sensor runs `10.01.4234207`. fwupd's cached metadata had nothing newer on
  2026-11-13. `fwupdmgr refresh && fwupdmgr get-updates` checks again.
- **"Storage full" on enrolment.** The sensor keeps templates on the chip, and old prints (from
  Windows, say) can fill it. Delete them with `fprintd-delete $USER` and enrol again.

## Evidence

### The machine, 2026-11-13

- **Hardware:** ThinkPad X1 Carbon Gen 13. The sensor is a Synaptics Prometheus,
  match-on-chip, USB `06cb:0123`.
- **Driver:** `06cb:0123` is in libfprint's own hwdb
  (`/usr/lib/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb`), and `fprintd-list` finds
  "Synaptics Sensors". Stock libfprint 1.95 drives it, with no TOD or vendor driver.
- **Software:** Ubuntu 26.04.1, GNOME Shell 50.1. sudo is **sudo-rs 0.2.13**.
- **Auth stack:** `common-auth` is `pam_unix` then `pam_sss`. SSSD is installed and inactive;
  the account is local. `capability.conf` is `none *`, so `pam_cap`, which the stanza's success
  path skips, grants nothing either way.
- **Before this:** nothing used the reader except GDM's own `gdm-fingerprint` service.

### Why it cannot be parallel in sudo or polkit

`pam_fprintd(8)`, LIMITATIONS: "The PAM stack is by design a serialised authentication, so it
is not possible for pam_fprintd to allow authentication through passwords and fingerprints at
the same time. It is up to the application using the PAM services to implement separate PAM
processes." GDM does exactly that: `gdm-password` and `gdm-fingerprint` are separate stacks,
which is why the lock screen takes either.

sudo and polkit run one stack each. Two third-party modules claim to run both at once in one
stack; neither belongs in a root authentication path:

- **pam-fprint-grosshack**, a fork of `pam_fprintd`, was last updated 2022-07-27. Its author
  warns: "This code may have major security flaws or other unforeseen bugs."
- **pam-any**, a 42-star Rust crate, starts one thread per method and drops their join handles
  when the first succeeds, which leaves a thread blocked in the password prompt. Its module code
  calls `unwrap()` and `todo!()`, so a panic takes down sudo or polkit with it.

The usual answer, which the Arch wiki gives, is to put the **password first** and have an empty
Enter move on to the fingerprint. That is what sudo does here. It cannot work in GNOME's polkit
dialog: GNOME Shell 50's `ui/components/polkitAgent.js` enables OK only on a non-empty entry
(line 156), and `_onEntryActivate` returns on an empty one (line 220). A Shell extension could
lift that, but `AuthenticationDialog` is not exported (line 26, against `export
{AuthenticationAgent as Component}` at line 472). It would have to patch a live instance at
runtime and be re-checked on every GNOME release. So polkit stays password-only.

### Why sudo is gated

**CVE-2024-37408 concerns a fingerprint offered with no "security attention mechanism".** Any
process that runs sudo can then claim a touch the user meant for something else. The fprintd
maintainers name GDM and GNOME's polkit dialog as the frontends that do ensure attention, and
treat sudo as a policy decision for distributions and administrators. Here, many agents run
unattended under this user.

`fingerprint-should-skip` therefore offers the reader only when all four of these hold:

- **The service is `sudo` or `sudo-i`.**
- **`PAM_USER` is a local account** (a line of `/etc/passwd`). The stanza's first check is
  `pam_unix`, which knows only local accounts. For a domain (SSSD) account, a *correct*
  password fails it, and only `common-auth`'s `pam_sss` would accept that password, after the
  reader. That is a fingerprint wait in front of a correct password, which this skip prevents.
- **`PAM_TTY` is a real terminal.** A tty-less sudo cannot read a password, and without this
  gate that failure falls straight through to a fingerprint wait. That is the CVE's shape,
  exactly.
- **The lid is open.** Docked, the reader cannot be touched, and `pam_fprintd` would only wait
  out its timeout.

Anything the gate cannot determine counts as a skip, because the password always works.

**The terminal check is a papercut guard, not a boundary.**

- **It stops the accidental case.** Claude Code's Bash tool and `!`, cron and background jobs
  have no terminal, and their sudo never reaches the reader.
- **It does not stop a process that sets out to get a terminal.** `script`, `expect` or a tmux
  pane each present a real `/dev/pts/N`. From there, an empty password sent down that pty
  reaches the reader, with the prompt shown where you cannot see it.
- **Nothing here can tell those terminals apart.** An automated review of this change
  suggested asking logind, but logind registers no session for an Alacritty pty or a `script`
  one, so to logind they look the same.
- **What bounds the risk:** such a process runs as you, so it could already take your sudo by
  aliasing it in your shell. With the password first, it must also fail a password before the
  reader is even asked.

If that trade is wrong for you, `fingerprint-setup --remove` restores password-only sudo, and the
lock screen keeps the fingerprint.

### Why the greeter is password-only, and the lock screen is not

A fingerprint login leaves the GNOME keyring locked, and on this machine the keyring holds gh's
tokens and Chrome's Safe Storage key. Once you are logged in the keyring stays unlocked, so the
lock screen loses nothing.

**One key can split the two.** GNOME Shell's `ShellUserVerifier` (`gdm/util.js`, lines 185 and
858) reads `org.gnome.login-screen enable-fingerprint-authentication` through a plain
`Gio.Settings`:

- **The greeter** runs as the gdm user and reads GDM's compiled defaults.
- **The unlock dialog** runs in your session and reads your own dconf, where the key stays at
  its default, `true`.

**How the greeter's defaults are built on Ubuntu:** `/etc/gdm3/greeter.dconf-defaults` is
symlinked as `/usr/share/gdm/dconf/90-debian-settings`. `/usr/share/gdm/generate-config` compiles
that directory into `/var/lib/gdm3/greeter-dconf-defaults`. It runs as gdm.service's
`ExecStartPre` and as its `ExecReload`, so `systemctl reload gdm.service` recompiles and
nothing more. A gdm restart would end the session.

### The stanza, through the real libpam

```
auth  sufficient                  pam_unix.so nullok
auth  [success=1 default=ignore]  pam_exec.so quiet quiet_log /usr/local/libexec/fingerprint-should-skip
auth  sufficient                  pam_fprintd.so max-tries=2 timeout=10
```

These are libpam's semantics, measured rather than believed. `pam_start_confdir()` (Linux-PAM ≥
1.4) runs a stack from any directory unprivileged. The state table copies the **installed**
files there, with `pam_permit`/`pam_deny` standing in for a right or wrong password or finger,
and the installed gate still deciding. The results:

| case | result |
|---|---|
| right password first | success; the gate never runs |
| wrong password, terminal, lid open, finger right | success (`offer:` logged) |
| finger wrong, a later `common-auth` module accepts | success: a failed finger decides nothing |
| lid closed, finger *would* match, `common-auth` refuses | refused: the finger was never asked |
| lid closed, a later `common-auth` module accepts | success: the gate's success jump poisons nothing |
| no terminal, finger *would* match | refused (`skip: no terminal`) |
| stanza missing while sudo includes it | `pam_start` fails with `PAM_ABORT` (26) before any prompt |
| gate missing | pam_exec's failure reads as **offer**, lid closed or not |
| **real** `pam_unix` in both places, finger wrong | refused after **one** prompt |
| the same, with two `pam_authenticate` calls on one handle | refused after **two** prompts |

"A later `common-auth` module accepts" is a stand-in for `pam_sss` accepting a domain account.
It is **not** a second chance at a typed password. The last two rows, with the real
`pam_unix`, show why: `pam_unix` reads the password through `pam_get_authtok()`, which returns
the one already typed, so `common-auth` re-checks that same typo or empty Enter and fails it.
The new prompt after Ctrl+C, a failed finger, or a docked Enter is **sudo-rs retrying the whole
`pam_authenticate`**, and libpam clears the cached password between attempts. Each detour
therefore costs one of sudo's tries, and with `passwd_tries=1` a failed finger would end sudo.
An independent review of this branch found that; the first version of these docs claimed a
fresh prompt from `common-auth`.

The stanza-missing and gate-missing rows set the install order: the gate, then the stanza, then
the includes. Removal runs the other way.

**The install loads the stack through libpam before writing anything.**
`scripts/pam-stack-probe.py` runs the sudo stack the install *would* leave: this machine's PAM
files, the stanza from the checkout, and `sudo` with the include. `pam_permit` stands in for
`pam_unix` (a correct password) and for the gate, and `pam_deny` for `pam_fprintd`. The install
refuses unless that authenticates. One misspelled control keyword in the stanza (`sufficent`) makes
libpam refuse the whole stack with `PAM_PERM_DENIED`, correct password or not (measured). Copying
it would lock everyone out of sudo while `--check`'s byte comparison against the same checkout
stayed green. `--check` runs the same load test against the installed files.

**`common-auth` must hold only modules a password checked first may skip.** The stanza's
`pam_unix` returns success *before* `common-auth` runs. A correct password therefore never
reaches a `pam_faillock preauth` lockout, a second factor, or anything else `pam-auth-update`
later adds there. The known set is `pam_unix`, `pam_sss` (the gate skips non-local accounts),
`pam_deny`, `pam_permit` and `pam_cap` (`capability.conf` is `none *`). The install refuses
anything else, an `@include` too, and `--check` fails on it.

`quiet_log` is on the pam_exec line because "offer" is an exit 1. Without it, pam_exec would log
every offer as a failed command.

**The stanza is called `sudo-fingerprint`, with no "password" in its name, on purpose.**
`.gitignore`'s secret guard `**/*password*` silently ignores any such file, and `git add -A`
leaves it out of the commit without a word. Its first name did exactly that. Check a new file
with `git add --dry-run`.

### The gate's inputs

`pam_exec(8)` builds the child's environment from the PAM environment list plus the PAM items,
and warns that "the user can have control over the environment". Through the real libpam
(2026-11-13), a caller's own `PAM_TTY=/dev/pts/77` and `FOO=bar` did **not** reach the child. It
saw only `PAM_USER`, `PAM_TYPE`, `PAM_SERVICE` and the `PWD` that dash sets. The gate still sets
`PATH` and `IFS` itself, and its test seams (`--lid-dir`, `--log-file`) are arguments, which in
PAM a root-owned file fixes.

**Through sudo-rs 0.2.13 too:** run with no terminal and `PAM_TTY=/dev/pts/9` set in its
environment, the gate logged `tty=none` (verification step 8 below). A caller cannot hand the
gate a terminal by setting the variable.

### sudo-rs specifics

- **sudo-rs #1307:** `sudo -n` used to print the fingerprint prompt. Fixed in 0.2.9.
- **sudo-rs #1308, fixed by PR #1322 (merged 2025-11-07):** Ctrl+C at the fingerprint prompt now
  falls back to the password, as classic sudo's does, by masking SIGINT around PAM.
- **Not documented anywhere, so measured:** sudo-rs 0.2.13 passes an *empty* password through
  to PAM. An empty Enter therefore reaches the reader (step 3 below). Ubuntu's 0.2.13 also
  carries PR #1322: Ctrl+C at the finger prompt ends that try instead of sudo itself, and the
  next try asks for the password (step 5).
- **sudo-rs prints nothing between the two password checks.** A typo therefore looks like a
  password that was accepted and then asked for a finger. The first live run did exactly that,
  and `pam_unix`'s "authentication failure" line in the journal is how to tell.
- **No terminal, no PAM at all for the password:** with no tty, sudo-rs says "A terminal is
  required to authenticate" and exits at once (step 6).

### Live verification

Run on 2026-11-13, installed from this branch, on this machine with sudo-rs 0.2.13 and the lid
open unless stated.

1. **Install:** `fingerprint-setup --check` exits 0 at the end of the install.
2. **Enrolment:** both index fingers enrol (`enroll-completed`). About half the touches came
   back `enroll-retry-scan`, which is normal for this sensor. `fprintd-verify` with no `-f`
   checks only the first enrolled finger, so it reads a correct touch of the other finger as
   `verify-no-match`. Name the finger with `-f`.
3. **The typed password comes first:** `sudo -k; sudo true` with the password typed succeeds
   at once. The gate never runs, and nothing is logged.
4. **An empty Enter reaches the reader:** "Place your finger on the fingerprint reader", then
   the right index finger, succeeds. sudo accepts **any** enrolled finger, not just the first
   one `fprintd-verify` would check. The run took 6.4 s, almost all of it the human's.
5. **A typo, then Ctrl+C:** typing `x` and Enter brings up the finger prompt, and Ctrl+C brings
   back a password prompt that the real password then passes. That prompt is sudo-rs's next
   try (see the stanza section above).
6. **No terminal:** from Claude Code's Bash tool, `sudo true` fails in 0 s with "A terminal is
   required to authenticate". The journal says `skip: no terminal (service=sudo tty=none)`.
7. **`PAM_TTY` is sudo-rs's own:** every terminal run logs `tty=/dev/pts/22`.
8. **A forged `PAM_TTY=/dev/pts/9` with no terminal** fails the same way, and still logs
   `tty=none`.
9. **polkit is untouched:** `pkexec true` shows GNOME's dialog with the password field ready at
   once, and no fingerprint text.
10. **The lock screen** (Super+L) unlocks with a touch. It needed nothing beyond enrolment.
11. **Pending:** docked with the lid closed, an empty Enter should use up that try with no
    finger prompt, then sudo asks for the password again, and the journal logs
    `skip: lid closed`. At the next natural reboot, the greeter should be password-only and the
    keyring unlocked.

### Designs not taken

- **`pam-auth-update --enable fprintd`.** It puts the reader first in `common-auth`, and so in
  front of every password: sudo, su, login, `gdm-password`, polkit. `--check` fails on it.
- **Fingerprint first in sudo or polkit, behind the lid gate.** It still blocks the password
  for the timeout whenever the lid is open.
- **pam-fprint-grosshack and pam-any.** See above.
- **A GNOME Shell extension that lets the polkit dialog submit an empty Enter.** See above.
- **"Any wrong text + Enter" in polkit.** A typo would then wait on the reader in a dialog with
  no Ctrl+C.

### Tests

State table: `scripts/test-fingerprint.sh` (132 checks, hermetic, CI `fingerprint-test`). It
covers the following:

- **The gate**, run as pam_exec runs it: `env -i` plus the PAM items, with no PATH. Local
  accounts come from a passwd fixture.
- **The stanza**, exactly as shipped.
- **The installer**, under a prefix. A `sudo` stub runs `install`, `mv` and `rm` for real but
  confined to the prefix, and models `systemctl reload gdm.service` as gdm's `generate-config`.
- **Every `--check` drift and every install refusal**, byte for byte against Ubuntu 26.04's own
  `sudo`, `sudo-i`, `common-auth`, `polkit-1` and `greeter.dconf-defaults` text, including the
  trailing spaces in Ubuntu's greeter file.
- **The worktree guard.**
- **The installed stack through the real libpam** (the table above), using the same probe
  the install uses.
- **The install refusing a stanza libpam cannot load, and `--check` catching one already
  installed,** even when it matches its checkout.
- **`common-auth` gaining `pam_faillock` or an `@include`:** refused at install, and a failure
  in `--check`.

**The first mutation sweep (2026-11-13, at `d99a10e`) killed all 43 mutants.**

- **Coverage:** 14 mutants in the gate, 5 in the stanza and 24 in the installer.
- **Applicability:** none was not applicable. Each replaced exactly one text, and its diff
  was checked.
- **Stanza mutants:** every one but `quiet_log` fails the libpam rows as well as the
  exact-text row, so the semantics are pinned and not only the spelling.
- **Three installer mutants stop the suite rather than fail a row:** a gdm restart, a write
  in place, and no gate directory. Each breaks the install, the install rows fail, and the
  baseline install then ends the suite with "could not run".

**A second sweep over the review fixes (16 mutants) killed 14 at first.** Its two survivors were
real gaps in the suite, and rows now pin both:

- With nothing installed, `--check` could load plain `sudo` through libpam and wrongly report
  that libpam refuses a correct password.
- The probe could count an info message, such as "Place your finger", as a prompt. A `pam_echo`
  fixture now sends one.

Re-run, both are killed.

### Sources

- [pam_fprintd(8)](https://www.mankier.com/8/pam_fprintd), LIMITATIONS
- [CVE-2024-37408](https://bugzilla.redhat.com/show_bug.cgi?id=2291438) and the
  [fprintd maintainers' write-up](https://hackmd.io/@3v1n0/HJtDCtdBC)
- sudo-rs [#1307](https://github.com/trifectatechfoundation/sudo-rs/issues/1307) and
  [#1308](https://github.com/trifectatechfoundation/sudo-rs/issues/1308)
- [pam-fprint-grosshack](https://gitlab.com/mishakmak/pam-fprint-grosshack) and
  [pam-any](https://github.com/ChocolateLoverRaj/pam-any)
- [linux-pam #301](https://github.com/linux-pam/linux-pam/issues/301): parallel modules would
  need a redesign of the configuration format
- [Arch wiki, fprint](https://wiki.archlinux.org/title/Fprint): password first, an empty
  Enter for the reader
- [GNOME: disallow fingerprint login](https://help.gnome.org/system-admin-guide/login-fingerprint.html)
  and [Debian: fingerprint and the keyring](https://wiki.debian.org/SecurityManagement/fingerprint%20authentication)
- [The lid-closed sudo wait](https://community.frame.work/t/when-in-clamshell-mode-how-do-you-disable-fingerprint-prompts-for-sudo/21295)
