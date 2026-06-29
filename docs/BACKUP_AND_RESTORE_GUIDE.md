# Backup & Restore Guide

Reproducible, encrypted **3-2-1 backups** for this workstation using **restic** (the
engine) orchestrated by **resticprofile** (declarative scheduling, retention, checks).
Backs up to an **external HDD** (when docked) and **Backblaze B2** (offsite), with an
**offline emergency kit** so a future brick is a quick, complete recovery — not a
from-memory rebuild.

This is the data-and-recovery layer. The *toolchain* is already reproduced by
`quantivly/dev-setup` + this dotfiles repo; backups cover what those don't: credentials,
unpushed work, app/desktop state, network/VPN secrets, and personal files.

## Quick start

```bash
backup-init                 # create ~/.backup.local from the template
${EDITOR:-vim} ~/.backup.local   # fill in repo paths, B2 keys, healthcheck URLs
backup-setup                # one-time guided install (restic, repos, timers, kit)

backup-now                  # run a backup now (both targets; b2 first, external skipped if undocked)
backup-status               # targets reachable? timers armed? latest snapshot?
backup-doctor               # is the whole chain CORRECT? (perms, drift, alerting, freshness)
backup-drill                # prove the backup is complete + restorable
backup-restore              # guided restore of a snapshot to ~/restore-<ts>/
```

## Architecture — three layers

| Layer | Tool | Protects against |
|-------|------|------------------|
| **1. Data (spine)** | restic + resticprofile → external HDD + Backblaze B2 | Disk failure, theft, fire, ransomware, accidental deletion |
| **2. Root-of-trust** | Bitwarden (online) + an age-encrypted **offline emergency kit** | The cold-start lockout (see below) |
| **3. System rollback** | Timeshift (rsync) + LUKS header backup | A bad apt upgrade / broken `/etc`; a corrupt LUKS header |

**3-2-1:** 3 copies (laptop SSD + external HDD + B2), on 2 media, with 1 offsite (B2).

**Why restic + resticprofile:** restic is the most established encrypted/deduplicated
engine that speaks both local disk and B2 natively. resticprofile is the declarative
orchestrator — a versioned [`resticprofile/profiles.toml`](../resticprofile/profiles.toml)
defines the policy (sources, excludes, retention, checks, schedule) and *generates* the
systemd timers, so there is almost no bespoke shell to maintain.

**The cold-start paradox (why the emergency kit is mandatory):** to restore from restic
you need the repo password + B2 keys → those live in Bitwarden → Bitwarden needs its
master password + 2FA + a network → your WiFi/VPN secrets are *inside the backup you
can't open yet* → cloning the private `dev-setup` repo needs SSH → SSH keys are in
Bitwarden. The offline kit lives entirely outside this loop and breaks it.

## What is backed up vs. regenerated

The backup runs **as root** (so it can read `/etc` and the GNOME keyring). Sources and
excludes live in [`examples/backup-includes.txt`](../examples/backup-includes.txt) and
[`examples/backup-excludes.txt`](../examples/backup-excludes.txt) (installed to `/etc/restic/`).

| Backed up | Excluded (regenerable) |
|-----------|------------------------|
| All of `/home/zvi` (incl. `~/.ssh`, `~/.gnupg`, `~/.config`, keyring, `~/.dotfiles`) | `~/.cache`, `~/.npm`, `~/.local/share/mise`, `~/.oh-my-zsh` |
| `/etc/NetworkManager/system-connections` (WiFi/VPN secrets) | `**/node_modules`, `**/.venv`, `**/__pycache__`, build dirs |
| `/etc` slice: `hosts`, `sysctl.d`, `apt` repos+keyrings, custom systemd units | browser `Cache`/`Code Cache`/`GPUCache` (profiles kept) |
| `/opt/awsvpnclient` (AWS VPN Client) | `~/.vscode/extensions` (list captured in the manifest) |
| A **system manifest** (`/var/backups/system-manifest.txt`) | `/swap.img`, `/tmp`, pseudo-filesystems |

> **Regenerate, do NOT restore** onto a fresh install: `/etc/fstab`, `/etc/crypttab`
> (new LUKS/LVM UUIDs), `/etc/machine-id`, `/etc/ssh/ssh_host_*`. They are captured for
> *reference* only — restoring them yields an unbootable system.

The **system manifest** (refreshed before each snapshot by
[`scripts/backup-manifest.sh`](../scripts/backup-manifest.sh)) records `apt-mark
showmanual`, third-party apt repos, `snap list` + connections, VS Code/GNOME extensions,
`mise ls`, and disk UUIDs — turning post-brick reconfiguration into a diffable checklist.

## One-time setup

**Prerequisites**

1. **Bitwarden** — your existing vault is the root-of-trust (it already serves your SSH
   keys). You'll store the restic repo key there.
2. **Backblaze B2** — create an account and a private bucket (e.g. `cilantro-backup`).
   Note the bucket's **S3 endpoint** (e.g. `s3.us-west-002.backblazeb2.com`).
3. **External HDD** — any **ext4** drive. Set `BACKUP_EXTERNAL_REPO` to
   `<mountpoint>/restic`; restic stores its repo in that subfolder *alongside* your
   existing files (non-destructive). Modern udisks mounts removable drives at
   `/run/media/<user>/<label>` (older setups: `/media/<user>/<label>`) — confirm with
   `findmnt /dev/sdXN` and match the config to it. No need to LUKS-encrypt the drive:
   restic encrypts the repo and the emergency kit is age-encrypted.

**Two B2 application keys** (ransomware resistance):

| Key | Capabilities | Lives where | Used by |
|-----|--------------|-------------|---------|
| **Append-only** | `listBuckets,listFiles,readFiles,writeFiles` (NO `deleteFiles`) | `~/.backup.local` (on-disk) | the daily timer |
| **Full access** | read + delete | **emergency kit only** (offline) | restore & `backup-prune` |

Add a **lifecycle rule** to the bucket (reaps versions restic "hides", giving a 30-day
tamper window):

```bash
b2 bucket update <bucket> allPrivate \
  --lifecycleRule '{"daysFromHidingToDeleting":30,"daysFromUploadingToHiding":null,"fileNamePrefix":""}'
```

> Do **not** enable B2 Object Lock — it conflicts with restic's deduplication and breaks
> `prune`. The append-only key + lifecycle rule is the supported pattern.

**Run it**

```bash
backup-init                       # ~/.backup.local from template
${EDITOR:-vim} ~/.backup.local    # repo paths, the APPEND-ONLY B2 key, healthcheck URLs
backup-setup                      # installs restic+resticprofile, inits repos, timers,
                                  # Timeshift, LUKS header backup, emergency kit
```

`backup-setup` is idempotent — re-run it any time you edit `~/.backup.local`.

## Daily operation

It's automatic. The timers and the dock trigger run backups for you; the commands below
are for on-demand use and inspection.

| Command | Does |
|---------|------|
| `backup-now [b2\|external\|cilantro]` | Back up now (default both; b2 first; external skipped if the HDD isn't docked) |
| `backup-status` | Targets reachable? timers armed? latest snapshot? |
| `backup-doctor` | Full-chain **health assertion** — perms, config drift, env drop-in, snapshot age, inert alerting, stale recovery assets, disk space. Non-zero exit on any failure. |
| `backup-drill [b2\|external]` | Prove the backup is **complete + restorable** (content + restore canary, then an integrity check) — the data half of a DR drill |
| `backup-snapshots [b2\|external]` | List snapshots |
| `backup-check [b2\|external]` | Verify repository integrity |
| `backup-restore [b2\|external]` | Guided restore to `~/restore-<ts>/` |
| `backup-restore-system [b2\|external] [--in-place]` | **Guarded** restore of the `/etc` slice + AWS VPN client; always excludes `fstab`/`crypttab`/`machine-id`/`ssh_host_*` so it can't break boot |
| `backup-mount [b2\|external]` | Browse a repo via FUSE (`~/backup-mnt`) |
| `backup-prune` | Prune B2 with the offline full key |
| `backup-luks-header` | Re-take the LUKS header backup |
| `backup-kit` | Emergency-kit status + reminder |

**Automation**

- **Cloud (B2):** a daily systemd timer (generated by resticprofile, `Persistent=true`
  so it catches up missed runs after sleep/boot), plus a weekly integrity check.
- **External HDD:** a 6-hourly timer ([`systemd/restic-backup-external.timer`](../systemd/restic-backup-external.timer))
  drives a `ConditionPathExists`-gated service, so it backs up **only when the drive is
  docked** and is a clean no-op otherwise. For an immediate backup after docking, run
  `backup-now external`. (A `.path` "exists" trigger is deliberately avoided — `PathExists`
  retriggers a oneshot service in a tight loop while the file exists.)
- **Weekly verification:** a separate timer
  ([`systemd/restic-verify.timer`](../systemd/restic-verify.timer)) runs
  [`scripts/backup-verify.sh`](../scripts/backup-verify.sh) — a **content canary** (asserts
  critical paths are still *in* the latest snapshot, catching a regressed exclude) plus a
  **restore canary** (restores one file to prove decrypt/extract works). It is deliberately
  decoupled from the `[b2.check]` integrity check so a verification failure can't abort it,
  and it **skips cleanly when offline** (offline ≠ failure). `restic check` proves the repo is
  *intact*; this proves it's *complete and restorable*. On demand: `backup-drill`.
- **Monitoring:** set `BACKUP_HC_URL_B2` / `BACKUP_HC_URL_EXTERNAL` / `BACKUP_HC_URL_VERIFY` to
  [healthchecks.io](https://healthchecks.io) check URLs. The hooks ping on success and `/fail`
  on failure, so you're **alerted when a backup or verification is overdue** (asleep /
  undocked / offline). This is the difference between "I have backups" and "I had backups until
  five weeks ago." **Leaving them blank makes the alerting silently inert — `backup-doctor`
  warns when they are.**
- **Desktop notifications** via `notify-send` (bridged from the root run into your GUI
  session by [`scripts/restic-notify.sh`](../scripts/restic-notify.sh)). **Failures always
  notify; successes are silent** unless you set `BACKUP_NOTIFY_SUCCESS=1` — the healthcheck
  ping is the success signal.

## Emergency kit (offline)

A single **age identity** is the only thing kept truly offline — printed on paper (or as
a QR) **and** on an offline USB. Everything else goes into one `emergency-kit.age` blob
(stored on the USB, inside the restic repo, and on the external HDD). To recover you need
only the age key → decrypt → get everything. `backup-setup` scaffolds this; `backup-kit`
shows its status. Contents:

- restic repo password; **B2 full-access key**; B2 account login + 2FA recovery codes
- Bitwarden master password + 2FA recovery code + a periodic encrypted vault export
- LUKS passphrase(s) + the header-backup file (`/root/luks-header-<host>.img`)
- home/office WiFi PSK; a GitHub **PAT** (HTTPS fallback to clone the private repos)
- this runbook; optionally tarballs of `dev-setup` + `dotfiles` and a static `restic` binary

## Disaster recovery runbook

Keep a tested **Ubuntu install USB** with the kit. Then:

1. **Reinstall** Ubuntu with LUKS (note the new passphrase).
2. **Network:** restore the WiFi PSK from the kit, or tether via phone/USB.
3. **Unlock secrets:** recover the **age key** from the kit → decrypt `emergency-kit.age`.
   Open Bitwarden (web/CLI via the encrypted export — don't wait on rebuilding the snap).
4. **Bootstrap:** clone `dev-setup` + `dotfiles` over **HTTPS + PAT** (SSH/Bitwarden-agent
   isn't up yet). Run `dev-setup`, then dotfiles `./install`.
5. **Restore data:** install restic, then restore the latest snapshot with the **full
   key**. For `/home`, use `backup-restore`. For the system slice, use
   **`backup-restore-system`** — it restores `/etc` + the AWS VPN client while *always*
   excluding `/etc/fstab`, `/etc/crypttab`, `/etc/machine-id`, `ssh_host_*`, so you can't
   produce an unbootable box (let the fresh install's own versions of those stand). Restore
   to a scratch dir and copy what you need, or `backup-restore-system --in-place` once you're
   sure.
6. **Re-auth from Bitwarden:** SSH agent, `gh auth login`, app logins. The restored GNOME
   keyring / Chrome passwords are **not** relied upon to unlock (Bitwarden is the source
   of truth). Reinstall the **AWS VPN Client** and restore `~/.config/AWSVPNClient`.
7. **Re-arm:** run `backup-setup` to reinstall the timers and re-take the LUKS header.

## Verification & drills

Backups you've never restored aren't backups. Maintain this regimen:

- **`backup-doctor` anytime** — the fastest confidence check: it asserts the whole chain is
  *correct* (perms, config drift, the env drop-in, snapshot age, that alerting is actually
  wired, recovery-asset freshness, disk space). Run it after any change to the backup setup.
- **`backup-drill` monthly-ish** — proves the data is *complete and restorable* (the content +
  restore canary plus an integrity check) in one command. The weekly `restic-verify.timer`
  does this automatically and alerts on failure; `backup-drill` is the on-demand version.
- **Quarterly restore drill** — run the whole runbook from the kit into a VM or spare
  disk. The real test is the *bootstrap* (network → vault → HTTPS clone), not just `restic
  restore`. `backup-drill` covers the data half; this covers the bootstrap half.
- **Weekly** `restic check`; **monthly** `restic check --read-data-subset=10%` (rotating —
  full coverage over ~10 weeks). Scheduled automatically for B2; on demand via `backup-check`.
- **Ransomware proof:** with the stored append-only key, `restic forget` must **fail**
  (deletion blocked); the kit's full key must succeed.
- **LUKS:** verify the header backup restores to a loop file
  (`cryptsetup luksHeaderRestore`); re-take it (`backup-luks-header`) after any passphrase change.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `backup-status` shows no timers | Run `backup-setup`; check `resticprofile -c /etc/resticprofile/profiles.toml schedule --all`. |
| External backup doesn't run when docked | Check `systemctl status restic-backup-external.timer` and `journalctl -u restic-backup-external.service`. The service skips (condition not met) unless `<BACKUP_EXTERNAL_REPO>/config` exists — confirm the drive is mounted where `~/.backup.local` expects (modern udisks uses `/run/media/<user>/<label>`). Force one now: `backup-now external`. |
| B2 backup fails (`AccessDenied`) | The append-only key can't prune — ensure no `[b2.retention]` is set; for pruning use `backup-prune` with the full key. |
| `restic init` fails on external | Dock the drive first; re-run `backup-setup` (it inits then, or it inits on the first dock backup). |
| Config parse error | `resticprofile -c /etc/resticprofile/profiles.toml show` to validate after edits. |
| No desktop notification | Expected when logged out; check the healthchecks ping and `journalctl` instead. |
| Restored files are root-owned | Restores run as root; `backup-restore`/`backup-restore-system` chown `~/restore-*` back to you automatically. |
| `backup-doctor` reports "config drift" | The live `/etc` copy diverged from `~/.dotfiles` (e.g. you `git pull`ed a policy change but didn't redeploy). Re-run `backup-setup` to resync, or commit the local edit. |
| `backup-doctor` warns "alerting INERT" | `BACKUP_HC_URL_B2`/`BACKUP_HC_URL_VERIFY` are blank — create checks at healthchecks.io and set them in `~/.backup.local`, then re-run `backup-setup`. |
| Verification failed (`restic-verify`) | A critical path fell out of the snapshot (regressed exclude) or a restore failed. `journalctl -u restic-verify.service`, then `backup-drill` to reproduce. A genuine completeness regression — fix the include/exclude and re-run `backup-now`. |

## See also

- [`resticprofile/profiles.toml`](../resticprofile/profiles.toml) — the backup policy (source of truth)
- [`scripts/setup-backup.sh`](../scripts/setup-backup.sh) — the one-time installer
- [`scripts/backup-verify.sh`](../scripts/backup-verify.sh) — the weekly content + restore canary
- [`examples/backup.local.template`](../examples/backup.local.template) — machine-specific config
- [GNOME_CONFIGURATION_GUIDE.md](GNOME_CONFIGURATION_GUIDE.md) — the sibling reproducible-config feature
- [resticprofile docs](https://creativeprojects.github.io/resticprofile/) · [restic docs](https://restic.readthedocs.io/) · [Backblaze B2 + restic](https://www.backblaze.com/docs/cloud-storage-integrate-restic-with-backblaze-b2)
