# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Backups: the mount-point guard's last enumerated case is now a structural rule.**
  `external_mount_point_sane` refused `/media/$USER` and `/run/media/$USER` as literal
  strings, and both holes ever found in that guard were in exactly those two entries — an
  empty `$USER` collapsed them to `/media/`, and `/media/./<user>` resolved past them. That
  is not a coincidence: for every other entry on the deny-list the list is belt-and-braces,
  because `/etc`, `/usr` and `$HOME` are non-empty and the content checks refuse them
  unlisted. The udisks parents are the one dangerous directory that is *legitimately empty*
  whenever no drive is docked — and legitimately the parent of the correct answer — so
  there the string list was load-bearing and alone. `path_is_account_directory` replaces
  them: `<parent>/<leaf>` under `/home`, `/media` or `/run/media` is refused when
  `getent passwd` says `<leaf>` names a **regular login account** (uid within login.defs'
  `UID_MIN`..`UID_MAX`). It covers every account rather than just the current one, and it
  asks nothing about who is running the installer, so the `$USER` class of bug cannot recur
  in it. The literals stay as belt-and-braces but no longer carry the guard.
  The uid bound is the discriminator, not a detail: matching *any* passwd entry would
  refuse `/media/backup` — a plausible hand-made mount point, `backup` being a stock uid-34
  account — and that is not a harmless over-rejection, because `install_external_udev`
  treats an unusable mount point as a reason to **remove** the hotplug rule, so a working
  install would silently lose its remount-on-dock. It is also not a depth rule ("three
  components under `/media`"), which would reject `/media/backup-hdd`, `/media/external`
  and `/mnt/store`. The passwd *name* field is compared back so a numeric key
  (`getent passwd 1000`) does not make `/media/1000` look like a user directory, and the
  lookup runs under `timeout` so an unreachable NSS source cannot hang the installer.
  An **unanswered** lookup is not read as a clean "no": only `getent`'s exit 2 means "no
  such key", while `timeout`'s 124 and a missing `getent` (127) mean the question never
  ran, and folding those into "not an account" switched the whole rule off in silence on
  precisely the LDAP/SSSD hosts the timeout was added for. The guard now reports a third
  status for "could not determine" and refuses — a correct mount point is one component
  under `/media` too, so guessing would wave through `/media/<another-login-user>` just as
  readily — with a message that names the lookup rather than blaming the path, since the
  fix is name-service resolution and not `BACKUP_EXTERNAL_REPO`. `install_external_udev`
  keys on that status to leave an already-installed hotplug rule **alone**, so a transient
  NSS failure cannot delete a rule an earlier successful run got right; only a genuinely
  unusable mount point still removes it. 68 checks → 85, driven by a fake `getent` on PATH
  (a shell function is invisible to a lookup made through `timeout`, so a stub would have
  passed vacuously), and the two sub-shell probes now print a positive token so a broken
  probe fails loudly instead of asserting an absence it would produce anyway.

### Added
- **`bun` pinned in `.mise.toml`** (1.4.0) — runtime for the herdr `gh-pr` plugin. herdr's
  server PATH carries no mise shims, so it must also be reachable as `~/.local/bin/bun`
  (`ln -s "$(mise which bun)" ~/.local/bin/bun`).
- **[docs/HERDR_GUIDE.md](docs/HERDR_GUIDE.md)** — the team-facing guide to the recommended
  agentic dev setup: prerequisites and how to verify them, keymap with rationale, sidebar
  semantics, plugins, `hspawn`, troubleshooting, and criteria for who should use herdr at all
  (non-developers are pointed at Orca, with the evaluation's limits stated). Leads with the
  lesson that cost the most time: **every layer of this stack fails silently** — `config
  check: ok` means the file parses, nothing more.
- **`yazi` pinned in `.mise.toml`** (26.8.15) and added to `scripts/verify-tools.sh`. It was
  bound to `alt+y` with its config symlinked into `~/.config/yazi`, but the binary had never
  been installed, so the popup opened and closed instantly.
- **herdr chord-first keymap and coloured agent sidebar** (`config/herdr/config.toml`,
  `scripts/herdr-keyprobe.sh`, `hspawn` in `zsh/zshrc.company`, local `sidebar-icons`
  plugin). Root cause of the earlier "3-modifier chords don't work": GNOME's
  `grp:alt_shift_toggle` xkb option made Alt+Shift the layout switch and swallowed one
  modifier of every Alt+Shift chord — now cleared by `apply-gnome-settings.sh`
  (Super+space remains the switch).
- **`system_health` now reports memory-pressure kills** (earlyoom / systemd-oomd /
  kernel OOM killer) over the last 7 days, with the most recent victim. These are
  worth surfacing because the damage is *silent*: a process killed mid-pipeline
  still lets the pipeline exit 0 with empty output, so the result is a confident
  wrong answer rather than an error. Observed on 2026-08-03, when a 16 GB search
  was shed this way and its empty output was read as "no matches". The match
  pattern requires `sending SIG… to process` — earlyoom's startup banner
  (`sending SIGTERM when mem avail <= 10.00%`) otherwise counts as a kill on every
  boot. When the system journal can't be read at all (no `journalctl`; a user
  outside `adm`/`systemd-journal`, who sees only their own journal while these
  kills are logged by root units) the check reports `skipped` rather than a clean
  ✓ — a false all-clear would reproduce the exact failure mode it exists to catch.
  The journal read is narrowed to the `earlyoom`/`systemd-oomd`/`kernel`
  identifiers, which is the same answer in 0.3s instead of 3.3s.
- **Broadcast-kill audit tripwire** — a two-line auditd rule
  (`audit/99-logout-catch.rules`, installed root-owned by `audit-setup` /
  `scripts/setup-audit-rules.sh`) that records any real `kill(-1, sig)`: *"signal
  every process I may signal"*, which on a desktop is the whole graphical
  session. Motivated by three unexplained GNOME logouts (2026-08-02/03) in which
  a broadcast kill from a project test suite produced a completely orderly
  teardown — no crash, no OOM, no coredump, nothing in the journal — leaving the
  audit log as the only place the sender's identity could exist.
  - `audit-status` reports every way this instrumentation can go quiet as its own
    distinct failure, so that "nothing found" can only mean "nothing happened":
    a rejected rule field leaves zero rules loaded with no error; auditing
    switched off (`enabled 0`); **no daemon registered (`pid 0`)** — rules live in
    the kernel, so `auditctl -l` lists them happily while records go to the ring
    buffer instead of `/var/log/audit/audit.log`, leaving `ausearch` blind
    forever; a climbing `lost` counter dropping records; `/etc` drifted from
    `~/.dotfiles` (the file is *copied*, so editing the repo alone changes
    nothing); and auditd's `SUSPEND` disk actions, which stop logging quietly
    when `/var` runs low. Exits non-zero on the fatal ones.
  - `audit-sweeps [hours]` reads hits, encoding the fact that `ausearch -ts`
    takes the date and time as **two** arguments — quoting them as one string
    matches nothing and prints no error. It validates `hours`, and distinguishes
    ausearch's benign "no matches" from a real read failure rather than
    reporting both as an all-clear.
  - `audit-setup` asserts all three arms (rules loaded, auditing on, daemon
    recording) and fails loudly otherwise; it prompts before installing the
    auditd package, since that has a system-wide side effect (`--yes` to skip).
  - Scope is `kill(-1, …)` only; `audit/99-logout-catch.rules` documents why
    `kill(0, …)` and `kill(-pgid, …)` are deliberately excluded.
  - Note: installing auditd moves AppArmor denials out of `journalctl -k` into
    `sudo ausearch -m AVC`. See CLAUDE.md → Audit Tripwire and
    docs/TROUBLESHOOTING.md → "Desktop session suddenly logged out".
- **DO-449 — Backup hardening (verification, health checks, safe-restore guardrails)**:
  closes the *silent-failure* class for the backup system.
  - `backup-doctor` — full-chain correctness assertion (file perms, config drift vs.
    `~/.dotfiles`, the DO-448 EnvironmentFile drop-in, snapshot age, that healthcheck URLs are
    actually set, emergency-kit/LUKS-header freshness, disk space); non-zero exit on any failure.
  - Weekly verification — `scripts/backup-verify.sh` + `systemd/restic-verify.{service,timer}`
    run a **content canary** (critical paths still present in the latest snapshot, catching a
    regressed exclude) and a **restore canary** (one file actually restored), decoupled from the
    `[b2.check]` integrity check and skipping cleanly when offline. `backup-drill` is the
    on-demand equivalent. `restic check` proves *intact*; this proves *complete + restorable*.
  - `backup-restore-system` — guarded `/etc`-slice restore that always excludes
    `fstab`/`crypttab`/`machine-id`/`ssh_host_*`, so the bare-metal restore can't break boot.
  - `setup-backup.sh` now warns when `BACKUP_HC_URL_*` are blank (alerting would be inert),
    re-takes the LUKS header when stale, and points to `backup-doctor`. New
    `BACKUP_HC_URL_VERIFY` / `BACKUP_CANARY_PATHS` knobs; optional `timeshift-autosnap` apt hook.
  See [docs/BACKUP_AND_RESTORE_GUIDE.md](docs/BACKUP_AND_RESTORE_GUIDE.md).
- **Backup & restore workflow** — encrypted 3-2-1 backups via restic + resticprofile to an
  external HDD (dock-triggered) and Backblaze B2 (offsite, append-only key + lifecycle for
  ransomware resistance). Declarative policy in `resticprofile/profiles.toml`; machine config
  in `~/.backup.local` (template + `backup-init`); one-time installer `scripts/setup-backup.sh`
  (`backup-setup`) wires repos, systemd timers, the dock trigger, Timeshift, a LUKS header
  backup, and an age-encrypted offline emergency kit. New `backup-*` functions in
  `zsh/functions/system.sh`. See
  [docs/BACKUP_AND_RESTORE_GUIDE.md](docs/BACKUP_AND_RESTORE_GUIDE.md).

### Fixed
- **External-HDD auto-mount: the review follow-up to #87.** An independent xhigh review of
  the merged change found fifteen defects, all confirmed. The dangerous one: the `/etc/fstab`
  mount point was a blind `dirname` of the hand-edited `BACKUP_EXTERNAL_REPO`, with no floor
  at all — a repo path one level too shallow resolves to `/media/<user>` and a typo resolves
  to `$HOME`, and every check downstream passed, so the external disk would have been mounted
  over the user's home at every boot. `nofail` is no help there; the mount *succeeds*.
  `external_mount_point_sane` now refuses non-absolute, unnormalised (`/./` included) and
  symlinked paths, a deny-list of system directories (`$HOME`, `/media/$USER`,
  `/run/media/$USER`, … — the user resolved with `id -un`, never the login-set `$USER`,
  which is empty under `sudo -u`/`env -i`), and any existing directory that is not already a
  mount point and is either non-empty or unlistable. It gates the `/etc/fstab` write, the
  udev rule, `restic init` **and** the `ConditionPathExists`/`After=` wiring — the repo
  init is the step that would otherwise create the "external" repository on the internal
  disk for a `BACKUP_EXTERNAL_REPO` of `/restic`, since `/` is a mount point.
  - **`render … | sudo tee /etc/…` truncates on failure.** `backup-render.sh` became fallible
    when unresolved placeholders were made a hard error, but three call sites still piped it
    into `tee`, which empties the destination before the renderer's status is known — leaving
    a zero-byte `includes.txt` (restic backs up nothing) or `.service` (a unit that does
    nothing), both installed and reading as present. Replaced with `render_install`
    (render → temp → check → `install`), the pattern the udev step already used.
  - **`findmnt -S UUID=x` misses `/dev/disk/by-uuid/x` entries while the disk is undocked**,
    because it resolves the tag through `/dev/disk/by-uuid`. That is the form Ubuntu's
    installer writes (and what `/boot` uses here), so a correct `/etc/fstab` read as empty in
    exactly the state the feature exists for — producing a duplicate entry, a refused udev
    rule, and a false "will not mount after a reboot" warning. Both the installer and
    `backup-doctor` now query the literal device path as a second step.
  - **`findmnt`'s summary is translated.** Both `N parse errors, …` and `Success, no errors or
    warnings detected` are gettext-marked in util-linux; under a translated locale the parse
    returned the 999 "unusable" sentinel for every clean table and the step refused to install
    anything, permanently. Now read under `LC_ALL=C`.
  - **A failed mount no longer leaves a root-owned mount point behind** — udisks owns
    `/run/media/<user>` and creates it user-owned, and the leftover is precisely the
    directory that makes `test -e "$repo/config"` report a drive that is not there.
  - **Stale udev rules are removed and reported.** Every path on which the step declines to
    install now removes a rule an earlier run left, and `backup-doctor` checks for one even
    when nothing is configured — the check used to be gated on "is anything configured",
    which is how a rule naming a since-reassigned UUID stayed invisible.
  - `fstab_escape` covers the full fstab(5) set (`\011`, `\012`, `\134`, not just `\040`);
    `backup-status` reports "not configured" instead of asserting "not attached" for a disk
    it cannot know about; `backup-doctor` no longer warns twice about a single
    non-configuration; `_backup_external_attached` no longer treats *any* volume whose label
    matches the mount point's basename as the backup drive (a name coincidence was enough to
    raise a hard, non-zero-exit failure); the dead `_backup_external_mnt` helper and the
    unused `out_of` test helper are gone; and the udev template's own documentation header no
    longer names the placeholder tokens inline, which had the renderer replacing the
    explanation with the values in the only copy an administrator ever opens.
- **`scripts/test-backup-external.sh` now runs in CI** (`backup-external-test`) and checks its
  own harness first. Sourcing `setup-backup.sh` also runs that script's `set -euo pipefail`,
  so the suite re-declares `set +e` — without it the first expected-to-fail assignment killed
  the run mid-table with no failure count printed. It also aborts unless every function under
  test is defined and every required tool present: most of these assertions are "nothing was
  installed", which is exactly what a suite that loaded nothing produces. 27 checks → 68.

- **Backups: the external HDD stopped mounting, and every layer said it was fine.**
  `BACKUP_EXTERNAL_UUID` had been declared in `backup.local.template` since the backup
  system was written and nothing ever read it. Without an `/etc/fstab` entry the drive
  stays unmounted, `restic-backup-external.service` fails its `ConditionPathExists`, and
  systemd **skips** it — which is not a failure: no error, nothing in `--state=failed`, no
  notification, and no healthchecks ping, because a skipped unit pings nothing. On a laptop
  it compounds, since the drive leaves and returns with every dock cycle (twelve times in
  seven days on the machine this came from) and fstab alone only covers boot. `backup-doctor`
  reported all of it as a neutral note claiming `B2 covers offsite`, a reassurance it never
  checked — while B2 was simultaneously failing on a storage cap.

  `backup-setup` now installs three things from that key, covering three different windows:
  an `/etc/fstab` entry for **boot** (`nofail` + `x-systemd.device-timeout=10s`, so an absent
  disk can never break or stall it, and the filesystem type is read off the disk rather than
  assumed), [`udev/99-backup-external.rules`](udev/99-backup-external.rules) for **dock
  cycles**, and a `service.d` drop-in ordering the run `After=` the mount unit so the timer's
  `Persistent=true` catch-up cannot lose a race against USB enumeration at boot. The ordering
  is `After=` only — `Requires=`/`RequiresMountsFor=` would turn an undocked disk into a
  *failed* unit every six hours, which is the false alarm the `ConditionPathExists` design
  exists to avoid.

  `backup-status` and `backup-doctor` now distinguish **attached-but-unmounted** (a hard
  failure: it is the one external fault that looks exactly like "nothing was due") from
  genuinely absent, without depending on `BACKUP_EXTERNAL_UUID` being set — the population
  that has this bug is precisely the one that never set it. Both now test whether the mount
  point *is a mount point*, rather than whether a path under it exists: a leftover directory
  on the internal disk satisfied the old check, so "docked ✓" could be reported while writes
  landed on the root filesystem. `backup-doctor` also checks `BACKUP_HC_URL_EXTERNAL` (the
  external target's only possible dead-man's switch), that the unit's `ConditionPathExists`
  and the configured repo agree, and compares the live udev rule against the rendered repo
  template — its load-bearing half is the `systemd-escape`'d mount unit name, which goes
  stale on a repo-path change and leaves a rule that still contains the UUID, still passes
  `udevadm verify`, and never fires.

  [`scripts/test-backup-external.sh`](scripts/test-backup-external.sh) pins the install and
  doctor decisions against a fake fstab, with no root and no real disk. Two traps it exists
  to hold down: `findmnt --verify` reports "unreachable on boot" as an **error** for a
  `nofail` entry whenever the disk is undocked or its mount point directory is absent, so
  gating on its exit code rejects every correct entry in exactly the two states this fix
  targets; and a hardcoded `ext4` passes `findmnt --verify` (a type mismatch is only a
  warning) and then fails to mount, which `nofail` converts straight back into a silent
  non-mount.
- **herdr: `hspawn` never worked.** Both code paths failed on every invocation. It creates a
  fresh worktree each run, so Claude's trust-folder dialog is guaranteed, and neither path
  answered it: the profile path called `herdr agent wait` before herdr had detected any agent
  (`agent wait` resolves its target up front and cannot wait *for* detection, so it died with
  `agent_not_found`), and the no-profile path died with `agent_not_ready`. Now polls for
  detection first, then answers the dialog on the agent surface — sending the keys at the pane
  level as the dialog renders does not work, because Claude's TUI is not yet accepting input
  and the keys vanish without error. Both paths verified end to end.
- **herdr: `f12 v` and `f12 -` had been silently deleted.** `split_vertical` /
  `split_horizontal` were arrays that omitted the stock prefix defaults, and setting a key
  field replaces it wholesale — leaving the two splits as the only actions with no prefix
  escape hatch.
- **herdr: `ctrl+shift+o` (split down) was dead**, because *Alacritty* has a compiled-in
  default binding that consumes the key press; the keyprobe signature is a release event with
  no matching press. Fixed in `~/.config/alacritty/alacritty.toml` (not symlinked from this
  repo) with an explicit `{ key = "O", mods = "Control|Shift", action = "ReceiveChar" }`.
  A sweep of the other 15 bound chords found `o` the only casualty — "one letter works, so the
  class works" is an unsound inference, and `CLAUDE.md` has been corrected accordingly.
- **DO-452**: the verification canary (`backup-verify.sh`) now runs its read-only `restic ls`
  / `restore` with `--no-lock`, so it no longer takes a repo lock that blocked the structural
  `restic check` in `backup-drill` (the check was being skipped rather than run). Added a
  `backup-unlock [b2|external] [--force]` command to clear stale restic locks after an
  interrupted run.
- **DO-451**: `backup-drill` no longer reports a false "DRILL FAILED" when a backup is running
  concurrently. `restic check` needs an exclusive lock, which collides with the every-2h
  backup; the drill now passes `--retry-lock 2m` and treats a still-held lock as "repo busy /
  skipped" rather than an integrity failure (the content + restore canary already proves
  restorability).
- **DO-450**: `backup-doctor` fixes found in live verification — its disk-space check used
  `df` (aliased to `duf`) so it silently printed nothing; now uses `command df -P` to bypass
  the alias. Also stops false-warning when `emergency-kit.age` isn't in `$HOME` (it's meant to
  live offline on the USB / in the repo) — now a neutral note instead of a warning.
- **DO-155**: Fixed CI ShellCheck error suppression - Shell script errors now fail CI builds instead of being silently ignored
- **DO-160**: Fixed mise activation error suppression in install script
  - Replaced `|| true` with explicit error checking
  - Shows warning message when activation fails
  - Provides remediation instructions
  - Users now informed when mise tools unavailable
