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
# And one failure mode BOTH canaries share, because both read `latest`:
#
#   0. Freshness        — how old is the snapshot being verified? From 2026-09-20
#                         the b2 backup failed on every run, and this script went
#                         on restoring the same September snapshot each week and
#                         printing "verification passed" for seven weeks. A snapshot
#                         past the limit, on a machine that has been running long
#                         enough to have backed up, is a FAIL.
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
#
# Environment (all optional; the first two belong in ~/.backup.local):
#   BACKUP_VERIFY_MAX_AGE_HOURS      how old `latest` may be. 0 = do not judge.
#                                    Default: 48 for b2; 0 for external, where a
#                                    disk undocked for weeks is normal.
#   BACKUP_VERIFY_MIN_UPTIME_HOURS   a machine up for less than this is not judged
#                                    on age (default 24): it may simply have been
#                                    off, which the backup timers' own healthchecks
#                                    already cover.
#   BACKUP_VERIFY_ENV_FILE, BACKUP_VERIFY_NOTIFY_HOOK, BACKUP_VERIFY_UPTIME_FILE
#                                    only scripts/test-backup-verify.sh sets these.
#
# Exit: 0 verified (or the repo is unreachable); 1 an assertion failed;
#       2 a usage or configuration error.

set -uo pipefail

readonly EXIT_CONFIGURATION_ERROR=2
readonly SECONDS_PER_HOUR=3600
readonly DEFAULT_MAX_AGE_HOURS_B2=48
readonly AGE_NOT_JUDGED=0
readonly DEFAULT_MIN_UPTIME_HOURS=24

TARGET="${1:-b2}"
ENV_FILE="${BACKUP_VERIFY_ENV_FILE:-/etc/restic/backup.local}"
NOTIFY="${BACKUP_VERIFY_NOTIFY_HOOK:-/usr/local/bin/restic-notify}"
UPTIME_FILE="${BACKUP_VERIFY_UPTIME_FILE:-/proc/uptime}"
MANIFEST="${BACKUP_MANIFEST_FILE:-/var/backups/system-manifest.txt}"

# --- load config (repo URLs, creds, NOTIFY_USER, canary overrides) ----------
# shellcheck source=/dev/null
[[ -r "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; } 2>/dev/null
: "${RESTIC_PASSWORD_FILE:=/etc/restic/repo.key}"
export RESTIC_PASSWORD_FILE

case "$TARGET" in
  external) export RESTIC_REPOSITORY="${BACKUP_EXTERNAL_REPO:?external repo not configured}"
            default_max_age_hours="$AGE_NOT_JUDGED" ;;
  b2)       export RESTIC_REPOSITORY="${BACKUP_B2_REPO:?b2 repo not configured}"
            default_max_age_hours="$DEFAULT_MAX_AGE_HOURS_B2" ;;
  *) echo "unknown target: $TARGET (use b2 or external)" >&2; exit "$EXIT_CONFIGURATION_ERROR" ;;
esac

# Set-but-empty falls back to the default, like unset: an empty line in
# ~/.backup.local must not read as "0, do not judge".
max_age_hours="${BACKUP_VERIFY_MAX_AGE_HOURS:-$default_max_age_hours}"
min_uptime_hours="${BACKUP_VERIFY_MIN_UPTIME_HOURS:-$DEFAULT_MIN_UPTIME_HOURS}"
for hours_setting in "$max_age_hours" "$min_uptime_hours"; do
  if [[ ! "$hours_setting" =~ ^[0-9]+$ ]]; then
    echo "BACKUP_VERIFY_MAX_AGE_HOURS and BACKUP_VERIFY_MIN_UPTIME_HOURS must be whole numbers (got '$hours_setting')" >&2
    exit "$EXIT_CONFIGURATION_ERROR"
  fi
done

# Desktop user → resolve their home so the default critical paths are correct
# (this script runs as root, so $HOME is /root).
vuser="${NOTIFY_USER:-$(id -un 1000 2>/dev/null || true)}"
vhome=""
if [[ -n "$vuser" ]]; then
  vhome="$(getent passwd "$vuser" 2>/dev/null | cut -d: -f6)"
  : "${vhome:=/home/$vuser}"
fi

# Critical paths to assert in the latest snapshot. Override with BACKUP_CANARY_PATHS
# (whitespace/newline-separated absolute paths) in ~/.backup.local.
if [[ -n "${BACKUP_CANARY_PATHS:-}" ]]; then
  read -r -a CANARY_PATHS <<<"$BACKUP_CANARY_PATHS"
elif [[ -n "$vhome" ]]; then
  CANARY_PATHS=(
    "$vhome/.ssh"
    "$vhome/.config"
    "$vhome/.local/share/keyrings"
    "$vhome/.dotfiles"
    "/etc/NetworkManager/system-connections"
    "$MANIFEST"
  )
else
  # No desktop user resolvable (NOTIFY_USER unset and no UID-1000 account):
  # fall back to the system-level canaries rather than asserting /home/ paths
  # that don't exist — but say so, since home coverage is the point.
  echo "WARNING: no desktop user resolved (set NOTIFY_USER in ~/.backup.local) — home canaries skipped" >&2
  CANARY_PATHS=(
    "/etc/NetworkManager/system-connections"
    "$MANIFEST"
  )
fi

fails=0
say()  { printf '%s\n' "$*"; }
pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }                 # ✓
note() { printf '  \xc2\xb7 %s\n' "$*"; }                     # · — stated, not judged
fail() { printf '  \xe2\x9c\x97 %s\n' "$*" >&2; fails=$((fails+1)); }

# Print the newest snapshot's time as epoch seconds, or nothing when no snapshot
# time can be read. `--latest 1` returns one snapshot per host-and-paths group,
# so there can be several; the newest of them is the one `latest` resolves to.
newest_snapshot_epoch() {
  local snapshot_time snapshot_epoch newest_epoch=""
  while IFS= read -r snapshot_time; do
    snapshot_epoch="$(date -d "$snapshot_time" +%s 2>/dev/null)" || continue
    if [[ -z "$newest_epoch" ]] || (( snapshot_epoch > newest_epoch )); then
      newest_epoch="$snapshot_epoch"
    fi
  done < <(restic snapshots --no-lock --latest 1 --json 2>/dev/null \
             | grep -o '"time"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
  printf '%s' "$newest_epoch"
}

# Print how many whole hours this machine has been up, or nothing when that
# cannot be read.
uptime_hours() {
  local uptime_seconds
  read -r uptime_seconds _ < "$UPTIME_FILE" 2>/dev/null || return 0
  uptime_seconds="${uptime_seconds%%.*}"
  [[ "$uptime_seconds" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$(( uptime_seconds / SECONDS_PER_HOUR ))"
}

# Judge the age of the snapshot every other check reads. An age that cannot be
# read is a FAIL, never a pass: "I could not tell" must not print a tick.
check_freshness() {
  local newest_epoch snapshot_age_hours machine_uptime_hours
  newest_epoch="$(newest_snapshot_epoch)"
  if [[ -z "$newest_epoch" ]]; then
    fail "could not read the time of the latest snapshot — its age is UNKNOWN"
    return
  fi
  snapshot_age_hours=$(( ($(date +%s) - newest_epoch) / SECONDS_PER_HOUR ))

  if (( max_age_hours == AGE_NOT_JUDGED )); then
    note "latest snapshot is ${snapshot_age_hours}h old (age is not judged for $TARGET)"
    return
  fi
  if (( snapshot_age_hours <= max_age_hours )); then
    pass "latest snapshot is ${snapshot_age_hours}h old (limit ${max_age_hours}h)"
    return
  fi

  # Past the limit. A laptop that was switched off is the innocent explanation,
  # and it only holds while the machine has not yet been up for a day's schedule.
  # An uptime that cannot be read excuses nothing.
  machine_uptime_hours="$(uptime_hours)"
  if [[ -n "$machine_uptime_hours" ]] && (( machine_uptime_hours < min_uptime_hours )); then
    note "latest snapshot is ${snapshot_age_hours}h old, over the ${max_age_hours}h limit — not judged: this machine has been up for only ${machine_uptime_hours}h and may simply have been off"
    return
  fi
  fail "latest snapshot is ${snapshot_age_hours}h old, over the ${max_age_hours}h limit, on a machine up for ${machine_uptime_hours:-an unknown number of }h — backups are not running"
}

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

# --- 0. freshness -----------------------------------------------------------
say "Freshness (the age of the snapshot everything below is checked against):"
check_freshness

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
