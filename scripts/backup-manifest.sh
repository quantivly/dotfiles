#!/usr/bin/env bash
#
# scripts/backup-manifest.sh
# ==========================
#
# Generate a self-documenting "system manifest" — the diffable inventory that
# turns post-brick reconfiguration from memory into a checklist. It captures the
# state that dev-setup + dotfiles do NOT fully reproduce (package selections,
# third-party apt repos, snap connections, VS Code extensions, disk identifiers).
#
# Written to /var/backups/system-manifest.txt and picked up by the restic backup
# (it is listed in examples/backup-includes.txt). Wired as the resticprofile
# `run-before` hook, so it refreshes immediately before every snapshot.
#
# Runs as ROOT (from the systemd timer). User-context tools (mise, code,
# gnome-extensions) are run as the desktop user via run_as_user().
#
# Always exits 0 — a manifest hiccup must never fail the backup.
#
# Usage:
#   sudo ./scripts/backup-manifest.sh            (normally invoked by resticprofile)

set -uo pipefail

OUT="${BACKUP_MANIFEST_FILE:-/var/backups/system-manifest.txt}"

# Pull NOTIFY_USER / config if present (scheduled runs already have it via the
# systemd EnvironmentFile drop-in; sourcing is harmless and helps manual runs).
# shellcheck source=/dev/null
[[ -r /etc/restic/backup.local ]] && { set -a; . /etc/restic/backup.local; set +a; } 2>/dev/null

# Desktop user = NOTIFY_USER, else the primary UID-1000 account, else "zvi".
BACKUP_USER="${NOTIFY_USER:-$(id -un 1000 2>/dev/null || echo zvi)}"

# Run a command in the desktop user's login environment (for mise shims etc.).
run_as_user() { sudo -u "$BACKUP_USER" -H bash -lc "$1" 2>/dev/null || true; }

# Section header helper.
section() { printf '\n===== %s =====\n' "$1"; }

mkdir -p "$(dirname "$OUT")"

{
  printf 'System manifest — generated %s\n' "$(date -Is)"
  printf 'Host: %s   Kernel: %s\n' "$(hostname)" "$(uname -r)"
  # shellcheck source=/dev/null
  [[ -r /etc/os-release ]] && { . /etc/os-release; printf 'OS: %s\n' "${PRETTY_NAME:-?}"; }

  section "apt: manually-installed packages (apt-mark showmanual)"
  apt-mark showmanual 2>/dev/null | sort

  section "apt: full selection state (dpkg --get-selections)"
  dpkg --get-selections 2>/dev/null

  section "apt: third-party repositories (/etc/apt/sources.list.d)"
  ls -1 /etc/apt/sources.list.d/ 2>/dev/null

  section "snap: installed"
  snap list 2>/dev/null

  section "snap: interface connections (incl. the Bitwarden ssh-agent grant)"
  snap connections 2>/dev/null

  section "flatpak: installed"
  flatpak list 2>/dev/null || echo "(flatpak not installed)"

  section "mise: tool versions"
  run_as_user "mise ls 2>/dev/null"

  section "VS Code: installed extensions"
  run_as_user "code --list-extensions --show-versions 2>/dev/null"

  section "GNOME: enabled extensions"
  run_as_user "gnome-extensions list --enabled 2>/dev/null"

  section "disks: lsblk -f"
  lsblk -f 2>/dev/null

  section "disks: blkid (UUIDs)"
  blkid 2>/dev/null

  section "reference: /etc/fstab (DO NOT restore onto a fresh install — new UUIDs)"
  cat /etc/fstab 2>/dev/null

  section "reference: /etc/crypttab (DO NOT restore onto a fresh install)"
  cat /etc/crypttab 2>/dev/null

  section "manual installs: /opt"
  ls -1 /opt 2>/dev/null

  section "manual installs: /usr/local/bin"
  ls -1 /usr/local/bin 2>/dev/null
} >"$OUT" 2>/dev/null

chmod 600 "$OUT" 2>/dev/null || true
exit 0
