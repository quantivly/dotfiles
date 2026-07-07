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
# Placeholders:
#   __BACKUP_HOME__      → invoking user's $HOME
#   __BACKUP_USER__      → invoking user's name (id -un)
#   __BACKUP_HOSTNAME__  → this machine's hostname
#
# Usage: backup-render.sh <template-file>
# Test overrides: BACKUP_RENDER_HOME / BACKUP_RENDER_USER / BACKUP_RENDER_HOSTNAME

set -euo pipefail

tpl="${1:?usage: backup-render.sh <template-file>}"
home="${BACKUP_RENDER_HOME:-$HOME}"
user="${BACKUP_RENDER_USER:-$(id -un)}"
host="${BACKUP_RENDER_HOSTNAME:-$(hostname)}"

# Parameter expansion (not sed) so replacement values containing |, &, or
# backslashes can never corrupt the output. $(cat) strips the trailing
# newline; printf restores exactly one — byte-stable for our templates.
content="$(cat "$tpl")"
content="${content//__BACKUP_HOME__/$home}"
content="${content//__BACKUP_USER__/$user}"
content="${content//__BACKUP_HOSTNAME__/$host}"
printf '%s\n' "$content"
