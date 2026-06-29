#!/usr/bin/env bash
#
# scripts/backup-verify.sh
# ========================
#
# Proves a backup repository is not just INTACT but COMPLETE and RESTORABLE —
# the two failure modes `restic check` cannot see:
#
#   1. Content canary   — assert a curated set of CRITICAL paths is still present
#                         in the latest snapshot. Catches a regressed include/
#                         exclude that silently stops capturing (e.g.) ~/.ssh while
#                         every backup keeps "succeeding".
#   2. Restore canary   — actually restore one small file (the system manifest) to
#                         a temp dir and confirm it decrypts + extracts non-empty.
#                         The closest thing to continuous proof that restore works.
#
# Runs as ROOT (it reads /etc/restic/repo.key + the B2 creds). Invoked two ways:
#   - scheduled: systemd/restic-verify.timer → restic-verify.service (weekly)
#   - on demand: `backup-drill` (zsh/functions/system.sh), via sudo
#
# On ANY failed assertion it pings healthchecks.io /fail and pops a desktop alert
# (reusing restic-notify with PROFILE_NAME=verify → BACKUP_HC_URL_VERIFY) and exits
# non-zero. On success it pings the verify healthcheck (a dead-man's switch that
# also catches "verification stopped running").
#
# Usage:
#   sudo ./scripts/backup-verify.sh [b2|external]      (default: b2)

set -uo pipefail

TARGET="${1:-b2}"
ENV_FILE="/etc/restic/backup.local"
NOTIFY="/usr/local/bin/restic-notify"
MANIFEST="${BACKUP_MANIFEST_FILE:-/var/backups/system-manifest.txt}"

# --- load config (repo URLs, creds, NOTIFY_USER, canary overrides) ----------
# shellcheck source=/dev/null
[[ -r "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; } 2>/dev/null
: "${RESTIC_PASSWORD_FILE:=/etc/restic/repo.key}"
export RESTIC_PASSWORD_FILE

case "$TARGET" in
  external) export RESTIC_REPOSITORY="${BACKUP_EXTERNAL_REPO:?external repo not configured}" ;;
  b2)       export RESTIC_REPOSITORY="${BACKUP_B2_REPO:?b2 repo not configured}" ;;
  *) echo "unknown target: $TARGET (use b2 or external)" >&2; exit 2 ;;
esac

# Desktop user → resolve their home so the default critical paths are correct
# (this script runs as root, so $HOME is /root).
vuser="${NOTIFY_USER:-$(id -un 1000 2>/dev/null || echo zvi)}"
vhome="$(getent passwd "$vuser" 2>/dev/null | cut -d: -f6)"; : "${vhome:=/home/$vuser}"

# Critical paths to assert in the latest snapshot. Override with BACKUP_CANARY_PATHS
# (whitespace/newline-separated absolute paths) in ~/.backup.local.
if [[ -n "${BACKUP_CANARY_PATHS:-}" ]]; then
  read -r -a CANARY_PATHS <<<"$BACKUP_CANARY_PATHS"
else
  CANARY_PATHS=(
    "$vhome/.ssh"
    "$vhome/.config"
    "$vhome/.local/share/keyrings"
    "$vhome/.dotfiles"
    "/etc/NetworkManager/system-connections"
    "$MANIFEST"
  )
fi

fails=0
say()  { printf '%s\n' "$*"; }
pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }                 # ✓
fail() { printf '  \xe2\x9c\x97 %s\n' "$*" >&2; fails=$((fails+1)); }

say "=== backup-verify ($TARGET) — $(date -Is) ==="

# Repo unreachable (offline / HDD not docked) is NOT a verification failure —
# skip silently so the weekly timer doesn't cry wolf on a plane. The backup
# timers' own healthchecks already alert when backups themselves go overdue.
# Every restic call here is READ-ONLY and uses --no-lock: the canary must not
# take a repo lock, or it would block a concurrent `restic check` (e.g. the one
# backup-drill runs right after) and the integrity check would be skipped.
if ! restic cat config --no-lock >/dev/null 2>&1; then
  say "repo unreachable (offline / not docked) — skipping verification (not a failure)."
  exit 0
fi

# --- 1. content canary ------------------------------------------------------
say "Content canary (critical paths present in latest snapshot):"
for p in "${CANARY_PATHS[@]}"; do
  if [[ -n "$(restic ls --no-lock latest "$p" 2>/dev/null | head -1)" ]]; then
    pass "$p"
  else
    fail "$p MISSING from latest snapshot"
  fi
done

# --- 2. restore canary ------------------------------------------------------
say "Restore canary (restore + verify one file):"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/backup-verify.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
if restic restore --no-lock latest --include "$MANIFEST" --target "$tmp" >/dev/null 2>&1 \
     && [[ -s "$tmp$MANIFEST" ]]; then
  pass "restored $MANIFEST ($(wc -c <"$tmp$MANIFEST" | tr -d ' ') bytes)"
else
  fail "could not restore $MANIFEST from latest snapshot"
fi

# --- verdict + notify -------------------------------------------------------
if [[ "$fails" -eq 0 ]]; then
  say "✓ verification passed ($TARGET)"
  [[ -x "$NOTIFY" ]] && PROFILE_NAME=verify PROFILE_COMMAND=canary "$NOTIFY" success
  exit 0
else
  say "✗ verification FAILED ($TARGET): $fails problem(s) above"
  [[ -x "$NOTIFY" ]] && PROFILE_NAME=verify PROFILE_COMMAND=canary "$NOTIFY" fail
  exit 1
fi
