# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
