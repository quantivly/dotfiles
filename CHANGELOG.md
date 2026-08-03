# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`system_health` now reports memory-pressure kills** (earlyoom / systemd-oomd /
  kernel OOM killer) over the last 7 days, with the most recent victim. These are
  worth surfacing because the damage is *silent*: a process killed mid-pipeline
  still lets the pipeline exit 0 with empty output, so the result is a confident
  wrong answer rather than an error. Observed on 2026-08-03, when a 16 GB search
  was shed this way and its empty output was read as "no matches". The match
  pattern requires `sending SIG… to process` — earlyoom's startup banner
  (`sending SIGTERM when mem avail <= 10.00%`) otherwise counts as a kill on every
  boot.
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
