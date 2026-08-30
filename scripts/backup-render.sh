#!/usr/bin/env bash
#
# scripts/backup-render.sh
# ========================
#
# Render a backup config template to stdout — the SINGLE source of truth for
# the __BACKUP_*__ placeholder substitution (DO-459). Used by:
#   - setup-backup.sh   when installing templates into /etc and systemd
#   - backup-init       when creating ~/.backup.local from the template
#   - backup-doctor     when comparing live /etc files against the repo
#     (drift check) — it must render EXACTLY like the install did
#
# Why placeholders at all: restic (--files-from/--exclude-file) and systemd
# (EnvironmentFile) read their files VERBATIM — no $HOME/$USER expansion — and
# /home/*-style globs would change semantics (back up every user's home). So
# the repo copies stay generic and the machine identity is baked in here, at
# install time.
#
# Placeholders (machine identity — always available):
#   __BACKUP_HOME__      → invoking user's $HOME
#   __BACKUP_USER__      → invoking user's name (id -un)
#   __BACKUP_HOSTNAME__  → this machine's hostname
#
# Placeholders (external drive — supplied by the caller, blank otherwise):
#   __BACKUP_EXTERNAL_UUID__        → BACKUP_RENDER_EXTERNAL_UUID
#   __BACKUP_EXTERNAL_MOUNT_UNIT__  → BACKUP_RENDER_EXTERNAL_MOUNT_UNIT
#     (the systemd-escape'd .mount unit for the drive's mount point)
#
# Any placeholder left unresolved is a hard error, not a blank: an empty
# ID_FS_UUID== in the udev rule would match every device that has no UUID.
#
# Usage: backup-render.sh <template-file>
# Test overrides: BACKUP_RENDER_HOME / BACKUP_RENDER_USER / BACKUP_RENDER_HOSTNAME

set -euo pipefail

tpl="${1:?usage: backup-render.sh <template-file>}"
home="${BACKUP_RENDER_HOME:-$HOME}"
user="${BACKUP_RENDER_USER:-$(id -un)}"
host="${BACKUP_RENDER_HOSTNAME:-$(hostname)}"
extuuid="${BACKUP_RENDER_EXTERNAL_UUID:-}"
extunit="${BACKUP_RENDER_EXTERNAL_MOUNT_UNIT:-}"

# Parameter expansion (not sed) so replacement values containing |, &, or
# backslashes can never corrupt the output. $(cat) strips the trailing
# newline; printf restores exactly one — byte-stable for our templates.
content="$(cat "$tpl")"
content="${content//__BACKUP_HOME__/$home}"
content="${content//__BACKUP_USER__/$user}"
content="${content//__BACKUP_HOSTNAME__/$host}"
# Substituted only when the caller supplied a value, so that an unset one is
# caught by the leftover check below instead of quietly becoming "".
if [[ -n "$extuuid" ]]; then content="${content//__BACKUP_EXTERNAL_UUID__/$extuuid}"; fi
if [[ -n "$extunit" ]]; then content="${content//__BACKUP_EXTERNAL_MOUNT_UNIT__/$extunit}"; fi

# Refuse to emit a half-rendered file. A blanked value is not a degraded
# result, it is a different and sometimes dangerous one — ENV{ID_FS_UUID}==""
# matches every device without a UUID — and it would otherwise install
# silently and read as correct forever.
leftover="$(printf '%s\n' "$content" | grep -o '__BACKUP_[A-Z_]*__' | sort -u | tr '\n' ' ' || true)"
if [[ -n "${leftover// /}" ]]; then
  printf '%s: unresolved placeholder(s): %s\n' "$tpl" "${leftover% }" >&2
  exit 1
fi

printf '%s\n' "$content"
