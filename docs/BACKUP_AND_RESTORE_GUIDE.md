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
[`examples/backup-excludes.txt`](../examples/backup-excludes.txt). These are **templates**:
restic reads its files verbatim (no `$HOME` expansion), so `backup-setup` renders the
`__BACKUP_HOME__` placeholder via [`scripts/backup-render.sh`](../scripts/backup-render.sh)
when installing them to `/etc/restic/` — the same setup works for any user on any machine.
To change what's backed up, edit the repo templates and re-run `backup-setup`
(`backup-doctor` compares the live files against the *rendered* templates).

| Backed up | Excluded (regenerable) |
|-----------|------------------------|
| All of your home directory (incl. `~/.ssh`, `~/.gnupg`, `~/.config`, keyring, `~/.dotfiles`) | `~/.cache`, `~/.npm`, `~/.local/share/mise`, `~/.oh-my-zsh` |
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
2. **Backblaze B2** — create an account and a private bucket (e.g. `<hostname>-backup`).
   Note the bucket's **S3 endpoint** (e.g. `s3.us-west-002.backblazeb2.com`).
3. **External HDD** — any drive (the filesystem type is read off the disk, not
   assumed). Set `BACKUP_EXTERNAL_REPO` to `<mountpoint>/restic`; restic stores its repo
   in that subfolder *alongside* your existing files (non-destructive). Modern udisks
   mounts removable drives at `/run/media/<user>/<label>` (older setups:
   `/media/<user>/<label>`) — confirm with `findmnt /dev/sdXN` and match the config to it.
   No need to LUKS-encrypt the drive: restic encrypts the repo and the emergency kit is
   age-encrypted.

   > **Get the depth right.** The mount point is derived as `dirname
   > $BACKUP_EXTERNAL_REPO`, and it is what goes into `/etc/fstab`. A repo path one level
   > too shallow (the drive's mount point itself, rather than a directory on it) resolves
   > to `/run/media/<user>`, and a typo can resolve to your home directory — which would
   > mean the external disk mounted over it at every boot, hiding everything in it.
   > `backup-setup` refuses those: a non-absolute, unnormalised (`/./` included) or
   > symlinked path, `$HOME`, `/media`, `/run/media`, the usual system directories, and any
   > existing directory that is not already a mount point and is either non-empty or
   > unreadable. It also refuses `/home/<x>`, `/media/<x>` and `/run/media/<x>` whenever
   > `<x>` is the name of a **login account** on the machine — those are the per-user
   > directories the system creates and mounts removable media inside, and they are empty
   > exactly when no drive is docked, so nothing about their contents gives them away.
   > Only accounts whose uid falls inside `UID_MIN`–`UID_MAX` from `/etc/login.defs` count,
   > so `/media/backup` is fine (`backup` is a stock system account, uid 34), as are
   > `/media/backup-hdd` and `/mnt/store`. `root` is outside that range too, so
   > `/media/root` is accepted — a deliberate carve-out rather than a claim about udisks,
   > which does use that name for a mount a uid-0 session started; `backup-setup` refuses to
   > run as root, so a supported install cannot reach the case. If the lookup cannot be
   > *answered* — unreachable directory server, or no `getent` — the path is refused with a
   > message saying so, because the correct mount point is one component under `/media` too,
   > so guessing would wave through the dangerous spelling just as readily; that particular
   > refusal deliberately leaves an already-installed udev rule alone, since the fix is
   > name-service resolution rather than `BACKUP_EXTERNAL_REPO`. The same
   > check gates every step that uses the mount point — the `/etc/fstab` entry, the udev
   > rule, `restic init`, and the unit's `ConditionPathExists`.

   **Also set `BACKUP_EXTERNAL_UUID`** (`lsblk -o NAME,UUID,LABEL`). `backup-setup`
   uses it for two things: an `/etc/fstab` entry so the drive mounts at boot (with
   `nofail`, so an undocked drive can never break boot), and a udev rule so it
   *remounts whenever it reappears*. The second matters on a laptop: a drive behind
   a docking station leaves and returns with every dock cycle, and fstab alone only
   covers boot. Leave the UUID blank and you are relying on the desktop to mount the
   drive — see the warning under *Scheduling* below.

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
| `backup-now [b2\|external\|full]` | Back up now (default both; b2 first; external skipped if the HDD isn't docked) |
| `backup-status` | Targets reachable? timers armed? latest snapshot? |
| `backup-doctor` | Full-chain **health assertion** — perms, config drift, env drop-in, snapshot age, B2 repo size/churn/prune-staleness, inert alerting, stale recovery assets, disk space. Non-zero exit on any failure. |
| `backup-drill [b2\|external]` | Prove the backup is **complete + restorable** (content + restore canary, then an integrity check) — the data half of a DR drill |
| `backup-snapshots [b2\|external]` | List snapshots |
| `backup-check [b2\|external]` | Verify repository integrity |
| `backup-restore [b2\|external]` | Guided restore to `~/restore-<ts>/` |
| `backup-restore-system [b2\|external] [--in-place]` | **Guarded** restore of the `/etc` slice + AWS VPN client; always excludes `fstab`/`crypttab`/`machine-id`/`ssh_host_*` so it can't break boot |
| `backup-mount [b2\|external]` | Browse a repo via FUSE (`~/backup-mnt`) |
| `backup-unlock [b2\|external] [--force]` | Clear stale restic locks after an interrupted run (`--force` removes all — only when idle) |
| `backup-prune` | Prune B2 with the offline full key |
| `backup-luks-header` | Re-take the LUKS header backup |
| `backup-kit` | Emergency-kit status + reminder |

**Automation**

- **Cloud (B2):** a 2-hourly (08:00–22:00) systemd timer (generated by resticprofile,
  `Persistent=true` so it catches up missed runs after sleep/boot), plus a weekly
  integrity check.
- **External HDD:** a 6-hourly timer ([`systemd/restic-backup-external.timer`](../systemd/restic-backup-external.timer))
  drives a `ConditionPathExists`-gated service, so it backs up **only when the drive is
  docked** and is a clean no-op otherwise. For an immediate backup after docking, run
  `backup-now external`. (A `.path` "exists" trigger is deliberately avoided — `PathExists`
  retriggers a oneshot service in a tight loop while the file exists.)

  > **The gate is silent by design, so make sure the drive actually mounts.** An
  > unmet `ConditionPathExists` makes systemd *skip* the unit, and a skipped unit is
  > not a failed one: no error, nothing in `--state=failed`, no desktop notification,
  > and no healthchecks ping. An attached-but-unmounted drive therefore looks exactly
  > like "no backup was due". Set `BACKUP_EXTERNAL_UUID` so `backup-setup` writes the
  > `/etc/fstab` entry, set `BACKUP_HC_URL_EXTERNAL` so an overdue run is externally
  > visible, and run `backup-doctor` — it reports an attached-but-unmounted drive as a
  > hard failure and warns when the UUID is set but missing from `/etc/fstab`.

  **Three things keep the drive mounted, and they cover different windows.** The
  `/etc/fstab` entry covers **boot** (`nofail` + `x-systemd.device-timeout=10s`, so an
  undocked drive can never break or stall it). [`udev/99-backup-external.rules`](../udev/99-backup-external.rules)
  covers **dock cycles**, which on a laptop outnumber boots — it starts the
  fstab-generated `.mount` unit whenever that partition reappears, so it can never mount
  anything `/etc/fstab` would not. And a `restic-backup-external.service.d/10-external-mount.conf`
  drop-in orders the run `After=` that mount unit, because `nofail` deliberately takes the
  mount *out* of `local-fs.target`'s ordering — without it, the timer's `Persistent=true`
  catch-up at boot can fire while the USB disk is still enumerating (measured at 18–21s
  here) and be skipped. That ordering is `After=` only: `Requires=`/`RequiresMountsFor=`
  would turn an undocked drive into a **failed** unit every six hours, which is exactly the
  false alarm the `ConditionPathExists` design exists to avoid.

  `backup-setup` installs all three from `BACKUP_EXTERNAL_UUID` and re-runs safely;
  `backup-doctor` checks each one, comparing the live udev rule against the rendered repo
  template rather than grepping it for the UUID (the load-bearing half is the
  `systemd-escape`'d mount unit name, which goes stale the moment the repo path changes
  and leaves a rule that still contains the UUID, still passes `udevadm verify`, and never
  fires). Every path on which `backup-setup` declines to install the udev rule also
  **removes** one an earlier run left behind, and `backup-doctor` reports a leftover rule
  even when no external drive is configured at all — otherwise a rule naming a UUID that
  now belongs to a different disk simply persists, unmentioned by anything.

  Both the `/etc/fstab` lookup and `backup-doctor` ask for the UUID **twice**: once as
  `UUID=<uuid>` and once as the literal `/dev/disk/by-uuid/<uuid>`. `findmnt -S UUID=…`
  resolves the tag through `/dev/disk/by-uuid`, so on its own it matches an entry written
  in the second form — the form Ubuntu's own installer uses — only while the disk is
  attached. Undocked, which is the state this whole mechanism exists for, a perfectly
  correct `/etc/fstab` would read as having no entry at all.

  [`scripts/test-backup-external.sh`](../scripts/test-backup-external.sh) exercises the
  install and doctor decisions against a fake fstab, with no root and no real disk, and
  **runs in CI** (`backup-external-test`) so a regression cannot merge green. Run it
  locally after touching any of this.
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
  session by [`scripts/restic-notify.sh`](../scripts/restic-notify.sh)). **Failures notify
  on state change** (first failure, then a daily reminder while stuck — a wedged target
  runs every 2h, and dozens of identical criticals just train you to ignore them), plus
  one **"recovered"** popup when it succeeds again. Successes are otherwise silent unless
  you set `BACKUP_NOTIFY_SUCCESS=1` — the healthcheck ping (which fires every run,
  undeduped) is the success signal.

## Capacity & pruning (B2)

The B2 repo is **append-only by design** (the stored key can't delete; there is no
`[b2.retention]`), so it **grows monotonically between manual prunes**. Left unattended
it will eventually hit the Backblaze **storage cap** — and a hit cap doesn't degrade
gracefully: restic can't even write its lock file, so **every backup and check fails
outright** (`client.PutObject: Cannot upload files, storage cap exceeded`) until the cap
is raised or the repo shrinks.

- **True live size:** `restic stats --mode raw-data --no-lock` (what `backup-doctor`
  reads). The **B2 console figure lags**: restic deletions via S3 become *hide* markers
  that the bucket lifecycle rule (`daysFromHidingToDeleting=30`) only reaps ~30 days
  later, so billed usage stays high for up to a month after a prune. That lag **is** the
  ransomware-undo window — don't hard-delete versions to speed it up.
- **Cap sizing rule:** cap ≥ **~3× the expected raw repo size** — it must absorb
  append-only growth between prunes, the prune's own repack *uploads*, and the 30-day
  hidden-version lag. Set `BACKUP_B2_SIZE_WARN_GB` (in `~/.backup.local`) to ~60% of the
  cap so `backup-doctor` warns long before Backblaze does.
- **Prune cadence:** when `backup-doctor` warns on size or prune staleness
  (`BACKUP_B2_PRUNE_REMIND_DAYS`, default 120), run `backup-prune` with the offline full
  key. **Raise the cap before pruning if it's already tight — prune uploads during
  repack.**
- **Churn guard:** `backup-doctor` also warns when the last scheduled run stored more
  than `BACKUP_B2_CHURN_WARN_MB` — the early signal that some app started rewriting big
  blobs (Chrome component updates and per-release tool binaries have both done this) and
  the excludes need a new entry.

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
  *correct* (perms, config drift, the env drop-in, snapshot age, B2 repo size vs the warn
  threshold, last-run churn, prune staleness, that alerting is actually wired,
  recovery-asset freshness, disk space). Run it after any change to the backup setup.
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
| External backup doesn't run when docked | Start with `backup-doctor` — it separates "not attached" from "attached but NOT MOUNTED", which is the state that looks like success. The service skips (condition not met) unless `<BACKUP_EXTERNAL_REPO>/config` exists, so confirm the drive is mounted where `~/.backup.local` expects (modern udisks uses `/run/media/<user>/<label>`). Then `systemctl status restic-backup-external.timer` and `journalctl -u restic-backup-external.service`. Force one now: `backup-now external`. |
| `backup-setup` says "another /etc/fstab entry already targets …" or reports a mount-point mismatch | Two entries want the same mount point, or `/etc/fstab` mounts the UUID somewhere other than `dirname $BACKUP_EXTERNAL_REPO`. `backup-setup` refuses rather than guessing: inspect with `findmnt --fstab`, remove the stale entry, re-run. |
| `backup-setup` says "refusing to mount the external HDD over …" | The mount point derived from `BACKUP_EXTERNAL_REPO` is a system directory or your home. The repo path is one level too shallow, or has a typo — it must name a directory **on** the drive, e.g. `/run/media/<user>/<label>/restic`. |
| `backup-setup` says "… already contains files and is not a mount point" | The derived mount point is a real directory on the internal disk holding real data; mounting over it would hide it at every boot. Point `BACKUP_EXTERNAL_REPO` at the drive's actual mount point, or empty/rename that directory first. |
| `backup-doctor` says a udev rule exists "but no external HDD is configured" | A rule left over from an earlier install, naming a UUID that may now belong to a different disk. Re-run `backup-setup` — it removes the stale rule. |
| B2 backup fails (`AccessDenied`) | The append-only key can't prune — ensure no `[b2.retention]` is set; for pruning use `backup-prune` with the full key. |
| B2 backup fails (`storage cap exceeded`) | The Backblaze storage cap is hit; every run fails at the lock write until fixed. In order: **(1)** raise the cap in the B2 console (Caps & Alerts) — prune *uploads*, so this comes first; **(2)** fix whatever grew (check `backup-doctor`'s churn warning; add excludes, redeploy with `backup-setup`); **(3)** `backup-now b2` for a fresh lean snapshot; **(4)** `backup-prune` with the offline full key; **(5)** `sudo systemctl reset-failed 'resticprofile-*@profile-b2.service'`; **(6)** `backup-doctor`. Console usage stays high ~30 days after prune (hidden versions) — see [Capacity & pruning](#capacity--pruning-b2). |
| `restic init` fails on external | Dock the drive first; re-run `backup-setup` (it inits then, or it inits on the first dock backup). |
| Config parse error | `resticprofile -c /etc/resticprofile/profiles.toml show` to validate after edits. |
| No desktop notification | Expected when logged out; check the healthchecks ping and `journalctl` instead. |
| Restored files are root-owned | Restores run as root; `backup-restore`/`backup-restore-system` chown `~/restore-*` back to you automatically. |
| `backup-doctor` reports "config drift" | The live `/etc` copy diverged from `~/.dotfiles` (e.g. you `git pull`ed a policy change but didn't redeploy). Re-run `backup-setup` to resync, or commit the local edit. |
| `backup-doctor` warns "alerting INERT" | `BACKUP_HC_URL_B2`/`BACKUP_HC_URL_VERIFY` are blank — create checks at healthchecks.io and set them in `~/.backup.local`, then re-run `backup-setup`. |
| Verification failed (`restic-verify`) | A critical path fell out of the snapshot (regressed exclude) or a restore failed. `journalctl -u restic-verify.service`, then `backup-drill` to reproduce. A genuine completeness regression — fix the include/exclude and re-run `backup-now`. |
| `backup-drill` says "repo is busy" / lock error | A real backup was running (`restic check` needs an exclusive lock; backups run every 2h). Harmless — the content + restore canary already passed. The drill waits 2 min; re-run when idle, or rely on the scheduled weekly `[b2.check]`. The canary itself is `--no-lock`, so it never causes this. If a lock lingers after an interrupted run, clear it with `backup-unlock` (or `backup-unlock <target> --force` when you're sure nothing's running). |

## See also

- [`resticprofile/profiles.toml`](../resticprofile/profiles.toml) — the backup policy (source of truth)
- [`scripts/setup-backup.sh`](../scripts/setup-backup.sh) — the one-time installer
- [`scripts/backup-verify.sh`](../scripts/backup-verify.sh) — the weekly content + restore canary
- [`examples/backup.local.template`](../examples/backup.local.template) — machine-specific config
- [GNOME_CONFIGURATION_GUIDE.md](GNOME_CONFIGURATION_GUIDE.md) — the sibling reproducible-config feature
- [resticprofile docs](https://creativeprojects.github.io/resticprofile/) · [restic docs](https://restic.readthedocs.io/) · [Backblaze B2 + restic](https://www.backblaze.com/docs/cloud-storage-integrate-restic-with-backblaze-b2)
