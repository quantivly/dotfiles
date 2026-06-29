#!/usr/bin/env bash
#
# scripts/setup-backup.sh
# =======================
#
# One-time, guided, IDEMPOTENT installer for the cilantro backup system
# (restic + resticprofile → external HDD + Backblaze B2). Run it via `backup-setup`.
#
# This is the sudo-using counterpart to ./install (which stays sudo-free and only
# drops the ~/.backup.local template). Everything here is re-runnable: each step
# detects "already done" and skips. Run it again after editing ~/.backup.local.
#
# What it does:
#   1.  Install restic (root PATH) + resticprofile (the orchestrator)
#   2.  Generate the restic repo key  → /etc/restic/repo.key  (+ store in Bitwarden)
#   3.  Lay down /etc/restic + /etc/resticprofile (configs COPIED, never symlinked)
#   4.  restic init the external + B2 repositories
#   5.  Install systemd timers (via `resticprofile schedule`) + the dock trigger
#   6.  Guide the ransomware-resistant B2 key + lifecycle setup
#   7.  Install Timeshift (local file-level rollback)
#   8.  Back up the LUKS header
#   9.  Build the offline emergency kit (age)
#   10. Validate + dry-run
#
# See docs/BACKUP_AND_RESTORE_GUIDE.md for the full picture.

set -euo pipefail

# --- paths ------------------------------------------------------------------
DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ETC_RESTIC="/etc/restic"
REPO_KEY="${ETC_RESTIC}/repo.key"
ENV_FILE="${ETC_RESTIC}/backup.local"
RP_DIR="/etc/resticprofile"
RP_CONFIG="${RP_DIR}/profiles.toml"
USER_CONFIG="${HOME}/.backup.local"

# --- pretty logging (mirrors scripts/apply-gnome-settings.sh) ---------------
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi
log() {
  local level="$1"; shift; local msg="$*"
  case "$level" in
    INFO)    echo -e "${BLUE}▶${RESET} $msg" ;;
    SUCCESS) echo -e "${GREEN}✓${RESET} $msg" ;;
    WARNING) echo -e "${YELLOW}⚠${RESET} $msg" >&2 ;;
    STEP)    echo -e "\n${CYAN}${BOLD}➜ $msg${RESET}" ;;
  esac
}
confirm() {
  local message="${1:-Proceed?}"; printf "%s [y/N] " "$message"; read -r r
  case "$r" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
has_command() { command -v "$1" &>/dev/null; }

# ===========================================================================
# 0. Preflight
# ===========================================================================
preflight() {
  log STEP "Preflight"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    log WARNING "Run as your normal user (it calls sudo as needed), not as root."
    exit 1
  fi
  if ! sudo -v; then
    log WARNING "sudo is required."
    exit 1
  fi
  if [[ ! -f "$USER_CONFIG" ]]; then
    log WARNING "$USER_CONFIG not found. Run 'backup-init' first, edit it, then re-run."
    exit 1
  fi
  # Load the user's machine config (repo URLs, B2 creds, UUID, notify settings).
  set -a; # shellcheck source=/dev/null
  source "$USER_CONFIG"; set +a
  log SUCCESS "Loaded $USER_CONFIG"
}

# ===========================================================================
# 1. Install restic + resticprofile
# ===========================================================================
install_tools() {
  log STEP "1. Install restic + resticprofile"

  if has_command restic; then
    log SUCCESS "restic present: $(restic version 2>/dev/null | head -1)"
  else
    log INFO "Installing restic via apt (reliable on root PATH for systemd)…"
    sudo apt-get update -qq && sudo apt-get install -y restic
  fi
  # Ensure restic is on the ROOT PATH (systemd runs as root). If only a mise shim
  # exists in the user's PATH, symlink the resolved binary into /usr/local/bin.
  if ! sudo test -x /usr/bin/restic && ! sudo test -x /usr/local/bin/restic; then
    local rbin; rbin="$(command -v restic || true)"
    [[ -n "$rbin" ]] && sudo ln -sf "$rbin" /usr/local/bin/restic
  fi

  if has_command resticprofile; then
    log SUCCESS "resticprofile present: $(resticprofile version 2>/dev/null | head -1)"
  else
    log INFO "Installing resticprofile to /usr/local/bin (official installer)…"
    if confirm "Download and run the resticprofile install script?"; then
      curl -fsSL https://raw.githubusercontent.com/creativeprojects/resticprofile/master/install.sh \
        | sudo sh -s -- -b /usr/local/bin
    else
      log WARNING "Skipped. Install resticprofile manually, then re-run."
      exit 1
    fi
  fi
}

# ===========================================================================
# 2. restic repo key (random) → /etc/restic/repo.key + Bitwarden
# ===========================================================================
setup_repo_key() {
  log STEP "2. restic repository key"
  sudo install -d -m 700 -o root -g root "$ETC_RESTIC"

  if sudo test -s "$REPO_KEY"; then
    log SUCCESS "$REPO_KEY already exists — keeping it."
    return 0
  fi

  local key; key="$(openssl rand -base64 48 2>/dev/null || head -c 36 /dev/urandom | base64)"
  echo
  log INFO "A new restic repository password has been generated. STORE IT FIRST:"
  echo "    ┌────────────────────────────────────────────────────────────┐"
  echo "    │  Bitwarden → new Secure Note: 'restic repo key — cilantro'   │"
  echo "    └────────────────────────────────────────────────────────────┘"
  echo
  echo "    $key"
  echo
  log WARNING "Without this key your backups are UNRECOVERABLE. Save it to Bitwarden"
  log WARNING "AND into the offline emergency kit (step 9) before continuing."
  if confirm "Saved the key to Bitwarden?"; then
    printf '%s' "$key" | sudo tee "$REPO_KEY" >/dev/null
    sudo chown root:root "$REPO_KEY"; sudo chmod 600 "$REPO_KEY"
    log SUCCESS "Wrote $REPO_KEY (root 0600)."
  else
    log WARNING "Aborted — nothing written. Re-run when ready to save the key."
    exit 1
  fi
}

# ===========================================================================
# 3. Lay down /etc configs (COPIED, root-owned — never symlinked)
# ===========================================================================
install_configs() {
  log STEP "3. Install /etc configs + helper scripts"

  sudo install -m 644 "$DOTFILES/examples/backup-includes.txt" "$ETC_RESTIC/includes.txt"
  sudo install -m 644 "$DOTFILES/examples/backup-excludes.txt" "$ETC_RESTIC/excludes.txt"
  log SUCCESS "includes.txt / excludes.txt → $ETC_RESTIC"

  # Root-readable copy of the secrets/URLs env file (the timers load this).
  sudo install -m 600 -o root -g root "$USER_CONFIG" "$ENV_FILE"
  log SUCCESS "$USER_CONFIG → $ENV_FILE (root 0600)"

  # resticprofile config — COPIED root-owned (root runs its hooks; a user-writable
  # config executed by root would be a privilege-escalation hole).
  sudo install -d -m 755 "$RP_DIR"
  sudo install -m 644 -o root -g root "$DOTFILES/resticprofile/profiles.toml" "$RP_CONFIG"
  log SUCCESS "profiles.toml → $RP_CONFIG (root-owned copy)"

  # Hook scripts on the root PATH.
  sudo install -m 755 "$DOTFILES/scripts/backup-manifest.sh" /usr/local/bin/backup-manifest.sh
  sudo install -m 755 "$DOTFILES/scripts/restic-notify.sh"   /usr/local/bin/restic-notify
  log SUCCESS "backup-manifest.sh / restic-notify → /usr/local/bin"
}

# Run resticprofile as root with the config env available (for {{ .Env.* }}).
# Source /etc/restic/backup.local INSIDE the root shell (already written by
# install_configs) rather than passing creds on the command line, so the B2
# secret never shows up in `ps`/`/proc`. Mirrors _backup_rp in system.sh.
rp() {
  sudo bash -c '
    set -a; . /etc/restic/backup.local 2>/dev/null; set +a
    : "${RESTIC_PASSWORD_FILE:=/etc/restic/repo.key}"
    : "${RESTIC_COMPRESSION:=auto}"
    export RESTIC_PASSWORD_FILE RESTIC_COMPRESSION
    cfg="$1"; shift
    exec resticprofile -c "$cfg" "$@"' _ "$RP_CONFIG" "$@"
}

# restic init helper (idempotent): $1 = label, $2 = repository.
# Sources the env file inside the root shell so the B2 secret stays out of argv;
# the repo URL ($1, not a secret) is passed positionally.
init_repo() {
  local label="$1" repo="$2"
  [[ -n "$repo" ]] || { log WARNING "$label repo not set in ~/.backup.local — skipping init."; return 0; }
  if sudo bash -c '
       set -a; . /etc/restic/backup.local 2>/dev/null; set +a
       : "${RESTIC_PASSWORD_FILE:=/etc/restic/repo.key}"; export RESTIC_PASSWORD_FILE
       export RESTIC_REPOSITORY="$1"
       restic cat config >/dev/null 2>&1' _ "$repo"; then
    log SUCCESS "$label repo already initialized."
  else
    log INFO "Initializing $label repo: $repo"
    if sudo bash -c '
       set -a; . /etc/restic/backup.local 2>/dev/null; set +a
       : "${RESTIC_PASSWORD_FILE:=/etc/restic/repo.key}"; export RESTIC_PASSWORD_FILE
       export RESTIC_REPOSITORY="$1"
       restic init --repository-version 2' _ "$repo"; then
      log SUCCESS "$label repo initialized."
    else
      log WARNING "$label init failed (repo unreachable / creds / drive not docked) — re-run later."
    fi
  fi
}

# ===========================================================================
# 4. Initialize repositories
# ===========================================================================
init_repos() {
  log STEP "4. Initialize restic repositories"
  # External: only if the drive is currently docked/mounted.
  if [[ -n "${BACKUP_EXTERNAL_REPO:-}" ]] && mountpoint -q "$(dirname "$BACKUP_EXTERNAL_REPO")" 2>/dev/null; then
    sudo install -d -o root -g root "$BACKUP_EXTERNAL_REPO" 2>/dev/null || true
    init_repo "external" "$BACKUP_EXTERNAL_REPO"
  else
    log INFO "External drive not docked — skipping external init (dock it and re-run, or it inits on first dock backup)."
  fi
  init_repo "b2" "${BACKUP_B2_REPO:-}"
}

# ===========================================================================
# 5. Install systemd timers + the dock trigger
# ===========================================================================
install_schedules() {
  log STEP "5. Install systemd timers + dock trigger"

  log INFO "Validating resticprofile config…"
  if rp profiles >/dev/null; then
    log SUCCESS "profiles.toml parses."
  else
    log WARNING "resticprofile could not parse $RP_CONFIG — fix and re-run."; return 1
  fi

  log INFO "Installing schedules (systemd timers, Persistent=true)…"
  if rp schedule --all; then
    log SUCCESS "Timers installed (see: systemctl list-timers)."
  else
    log WARNING "Scheduling failed — check 'resticprofile -c $RP_CONFIG schedule --all'."
  fi

  # resticprofile's systemd-drop-in-files does NOT reliably inject an EnvironmentFile
  # into its generated @-template units (DO-448), so wire it in explicitly — otherwise
  # the scheduled services run with an empty env and {{ .Env.* }} renders "<no value>"
  # ("repository does not exist").
  for tmpl in resticprofile-backup resticprofile-check; do
    sudo install -d -m 755 "/etc/systemd/system/${tmpl}@.service.d"
    printf '[Service]\nEnvironmentFile=%s\n' "$ENV_FILE" \
      | sudo tee "/etc/systemd/system/${tmpl}@.service.d/10-backup-env.conf" >/dev/null
  done
  sudo systemctl daemon-reload
  log SUCCESS "EnvironmentFile drop-in wired into scheduled backup/check services."

  # External backup: a timer drives a ConditionPathExists-gated oneshot, so it
  # backs up only when the drive is docked (loop-free; no .path unit).
  # Clean up the obsolete looping .path unit if a previous run installed it.
  sudo systemctl disable --now restic-backup-external.path 2>/dev/null || true
  sudo rm -f /etc/systemd/system/restic-backup-external.path
  sudo install -m 644 "$DOTFILES/systemd/restic-backup-external.service" /etc/systemd/system/restic-backup-external.service
  sudo install -m 644 "$DOTFILES/systemd/restic-backup-external.timer"   /etc/systemd/system/restic-backup-external.timer
  if [[ -n "${BACKUP_EXTERNAL_REPO:-}" ]]; then
    sudo sed -i "s|ConditionPathExists=.*|ConditionPathExists=${BACKUP_EXTERNAL_REPO}/config|" /etc/systemd/system/restic-backup-external.service
  fi
  sudo systemctl daemon-reload
  if sudo systemctl enable --now restic-backup-external.timer; then
    log SUCCESS "External timer armed (every 6h; runs only when docked). Immediate: backup-now external."
  else
    log WARNING "Could not enable restic-backup-external.timer."
  fi
}

# ===========================================================================
# 6. Ransomware-resistant B2 (guidance — append-only key + lifecycle)
# ===========================================================================
guide_b2_hardening() {
  log STEP "6. Ransomware-resistant B2 (append-only key + lifecycle)"
  cat <<'EOF'
  Do this once in the Backblaze console / b2 CLI (it cannot be safely automated here):

  a) BACKUP (timer) key — APPEND-ONLY (the key stored in ~/.backup.local):
       capabilities: listBuckets,listFiles,readFiles,writeFiles   (NO deleteFiles)
     A stolen laptop key then cannot destroy your cloud history.

  b) RESTORE/PRUNE key — FULL access (read+delete). Keep it ONLY in the offline
     emergency kit, never on this machine. Used by `backup-prune` and on restore day.

  c) Lifecycle rule on the bucket (reaps versions restic "hides", 30-day window):
       b2 bucket update <bucket> allPrivate \
         --lifecycleRule '{"daysFromHidingToDeleting":30,"daysFromUploadingToHiding":null,"fileNamePrefix":""}'

  NOTE: do NOT enable Object Lock — it conflicts with restic's dedup and breaks prune.
EOF
  if has_command b2; then
    confirm "Open the lifecycle docs reminder noted above is enough — continue?" || true
  fi
}

# ===========================================================================
# 7. Timeshift (local file-level rollback)
# ===========================================================================
install_timeshift() {
  log STEP "7. Timeshift (local file-level rollback)"
  if has_command timeshift; then
    log SUCCESS "Timeshift already installed."
  elif confirm "Install Timeshift (rsync mode) for quick local rollback of bad /etc or apt changes?"; then
    sudo apt-get install -y timeshift
    log SUCCESS "Timeshift installed."
  else
    log INFO "Skipped Timeshift."
    return 0
  fi
  log WARNING "Timeshift on this LVM-on-LUKS layout is for FILE-LEVEL rollback only —"
  log WARNING "do NOT rely on it for bare-metal restore (known LVM-on-LUKS restore bug)."
  log INFO "Configure snapshots + schedule in the Timeshift GUI (RSYNC mode; exclude the same caches)."
}

# ===========================================================================
# 8. LUKS header backup
# ===========================================================================
backup_luks_header() {
  log STEP "8. LUKS header backup"
  local dev
  dev="$(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print "/dev/"$1; exit}')"
  if [[ -z "$dev" ]]; then
    log WARNING "No crypto_LUKS device found — skipping (is this disk encrypted?)."
    return 0
  fi
  local out; out="/root/luks-header-$(hostname).img"
  if sudo test -s "$out"; then
    log SUCCESS "LUKS header backup already exists at $out."
  else
    log INFO "Backing up LUKS header of $dev → $out"
    if sudo cryptsetup luksHeaderBackup "$dev" --header-backup-file "$out"; then
      log SUCCESS "LUKS header saved."
    else
      log WARNING "Header backup failed."
    fi
  fi
  log WARNING "COPY $out into the offline emergency kit. A corrupt header = total data"
  log WARNING "loss even with the right passphrase. Re-take it after any passphrase change."
}

# ===========================================================================
# 9. Offline emergency kit (age) — breaks the cold-start lockout
# ===========================================================================
build_emergency_kit() {
  log STEP "9. Offline emergency kit (age-encrypted)"
  if ! has_command age; then
    log INFO "age not found — installing via apt for the emergency kit…"
    sudo apt-get install -y age 2>/dev/null || true
  fi
  has_command age || { log WARNING "age unavailable — skipping kit. Install age (mise use age / apt install age), then re-run backup-setup."; return 0; }

  local id="${HOME}/.config/age/emergency-kit-identity.txt"
  if [[ -f "$id" ]]; then
    log SUCCESS "age identity already exists: $id"
  elif confirm "Generate an age identity for the emergency kit?"; then
    mkdir -p "$(dirname "$id")" && chmod 700 "$(dirname "$id")"
    age-keygen -o "$id" 2>/dev/null && chmod 600 "$id"
    log SUCCESS "age identity created: $id"
    log WARNING "PRINT this identity on paper (or QR) AND copy it to an OFFLINE USB."
    log WARNING "It is the ONLY thing that must live outside every encrypted/online system."
  fi

  local recipient=""; [[ -f "$id" ]] && recipient="$(age-keygen -y "$id" 2>/dev/null || true)"
  local kit="${HOME}/emergency-kit.txt"
  if [[ ! -f "$kit" && ! -f "${kit%.txt}.age" ]]; then
    cat >"$kit" <<EOF
EMERGENCY KIT — cilantro   (fill in, then encrypt, then SHRED this plaintext)
============================================================================
restic repo password        : (from Bitwarden 'restic repo key — cilantro')
B2 FULL-access key id/secret : (read+delete key — restore & prune)
B2 account login + 2FA codes :
Bitwarden master pw + 2FA recovery code :
LUKS passphrase(s)          :
LUKS header backup location : /root/luks-header-$(hostname).img (also copy to USB)
Home/office WiFi PSK        :
GitHub PAT (HTTPS clone)    :
Runbook                     : docs/BACKUP_AND_RESTORE_GUIDE.md (Disaster Recovery)
EOF
    chmod 600 "$kit"
    log SUCCESS "Kit template written: $kit"
    [[ -n "$recipient" ]] && {
      echo "  Fill it in, then encrypt and destroy the plaintext:"
      echo "      age -r $recipient -o ${kit%.txt}.age $kit && shred -u $kit"
      echo "  Store emergency-kit.age on the OFFLINE USB and inside the restic repo."
    }
  else
    log INFO "Emergency kit already present — leaving it."
  fi
}

# ===========================================================================
# 10. Validate + dry run
# ===========================================================================
final_checks() {
  log STEP "10. Validate + dry-run"
  if [[ -n "${BACKUP_B2_REPO:-}" && -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    log INFO "Dry-run backup to B2 (no data written)…"
    rp -n b2 backup --dry-run --verbose || log WARNING "Dry-run reported an issue — review above."
  fi
  echo
  log SUCCESS "Backup setup complete."
  log INFO "Next: dock the 'Backup' HDD (auto-runs external) • check 'backup-status' • 'systemctl list-timers'"
  log INFO "Finish the offline kit (step 9) and read docs/BACKUP_AND_RESTORE_GUIDE.md (run a restore drill!)."
}

main() {
  preflight
  install_tools
  setup_repo_key
  install_configs
  init_repos
  install_schedules
  guide_b2_hardening
  install_timeshift
  backup_luks_header
  build_emergency_kit
  final_checks
}

main "$@"
