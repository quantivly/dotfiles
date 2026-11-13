#!/usr/bin/env bash
#
# scripts/test-backup-verify.sh
# =============================
#
# State table for the FRESHNESS check in scripts/backup-verify.sh.
#
# The row this file exists for is "a 60-day-old snapshot on a machine that has
# been running for days: exit 1". From 2026-09-20 the b2 backup failed on every
# run, and the weekly verification went on restoring the same September snapshot
# and printing "verification passed" on 2026-11-02 and 2026-11-09. Both canaries
# read `latest`, whatever its age.
#
# The other rows stop the check lying in either direction: it must not cry wolf
# at a laptop that was simply off, and it must never turn "I could not tell how
# old this is" into a tick.
#
# Hermetic and root-free: restic, the notify hook and the uptime file are stubs.
#
# MUTANTS. Each was applied to a copy of the script and run through this table
# (VERIFY=<copy>); the rows named are the ones that fail.
#   M1  drop the "machine was off" excuse        -> "stale, up for 2h: exit 0"
#   M2  an unreadable snapshot time passes       -> "no snapshot time readable: exit 1"
#   M3  take the first snapshot, not the newest  -> "newest of several, old one first: exit 0"
#   M4  flip the age comparison                  -> "fresh: exit 0", "stale, up for days: exit 1"
#   M5  judge the external target like b2        -> "external, stale: exit 0"
#   M6  an unreadable uptime excuses the age     -> "stale, uptime unreadable: exit 1"
#   M7  accept a non-numeric limit               -> "non-numeric limit: exit 2"
#   M8  never run the freshness check            -> "stale, up for days: exit 1"
#   M9  take the last snapshot read, not the     -> "newest of several, old one last: exit 0"
#       newest
#
# Usage: scripts/test-backup-verify.sh

# SC2016: the stub scripts below are literal text; nothing in them expands here.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${VERIFY:-$HERE/backup-verify.sh}"
BASH_BIN="$(command -v bash)"

PASS=0; FAIL=0
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1 — output lacked '$3'"; fi; }
[[ -r "$VERIFY" ]] || { printf 'FATAL: cannot read %s\n' "$VERIFY" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB_BIN="$TMP/bin"
SNAPSHOTS_JSON="$TMP/snapshots.json"
UPTIME_FILE="$TMP/uptime"
HOOK_RECORD="$TMP/hook-record"
MANIFEST_PATH="/var/backups/system-manifest.txt"
mkdir -p "$STUB_BIN"

readonly SECONDS_PER_HOUR=3600
readonly UPTIME_OF_DAYS_SECONDS=$(( 72 * SECONDS_PER_HOUR ))
readonly UPTIME_OF_TWO_HOURS_SECONDS=$(( 2 * SECONDS_PER_HOUR ))

# A restic that is reachable, holds every canary path, restores the manifest,
# and reports whatever snapshots the row wrote to $SNAPSHOTS_JSON.
cat > "$STUB_BIN/restic" <<STUB
#!/bin/sh
case "\$1" in
  cat) exit 0 ;;
  ls) printf 'present\n' ;;
  snapshots) cat "$SNAPSHOTS_JSON" 2>/dev/null ;;
  restore)
    while [ \$# -gt 0 ]; do
      case "\$1" in --target) restore_target="\$2"; shift ;; esac
      shift
    done
    mkdir -p "\$restore_target\$(dirname "$MANIFEST_PATH")"
    printf 'manifest\n' > "\$restore_target$MANIFEST_PATH"
    ;;
esac
STUB
cat > "$STUB_BIN/notify-hook" <<STUB
#!/bin/sh
printf '%s %s %s\n' "\$PROFILE_NAME" "\$PROFILE_COMMAND" "\$*" >> "$HOOK_RECORD"
STUB
chmod +x "$STUB_BIN/restic" "$STUB_BIN/notify-hook"

# Write the snapshot list: one JSON object per argument, each "<hours ago>".
snapshots_aged_hours() {
  local hours_ago separator="" snapshot_time
  printf '[' > "$SNAPSHOTS_JSON"
  for hours_ago in "$@"; do
    snapshot_time="$(date -d "-${hours_ago} hours" --iso-8601=seconds)"
    printf '%s{"time":"%s","hostname":"h","paths":["/home"],"id":"abc"}' "$separator" "$snapshot_time" >> "$SNAPSHOTS_JSON"
    separator=","
  done
  printf ']\n' >> "$SNAPSHOTS_JSON"
}
uptime_seconds() { printf '%s.00 0.00\n' "$1" > "$UPTIME_FILE"; }

# Run the verification. $1 = target; further arguments are VAR=value overrides.
verify() {
  local target="$1"; shift
  : > "$HOOK_RECORD"
  env -i PATH="$STUB_BIN:/usr/bin:/bin" TMPDIR="$TMP" \
    BACKUP_B2_REPO=stub-b2 BACKUP_EXTERNAL_REPO=stub-external \
    BACKUP_CANARY_PATHS="/etc/hosts" BACKUP_MANIFEST_FILE="$MANIFEST_PATH" \
    BACKUP_VERIFY_ENV_FILE="$TMP/no-env-file" \
    BACKUP_VERIFY_NOTIFY_HOOK="$STUB_BIN/notify-hook" \
    BACKUP_VERIFY_UPTIME_FILE="$UPTIME_FILE" \
    "$@" "$BASH_BIN" "$VERIFY" "$target" 2>&1
}
verify_rc() { verify "$@" >/dev/null; printf '%s' "$?"; }

echo
echo "=== a snapshot inside the limit ==="

snapshots_aged_hours 1; uptime_seconds "$UPTIME_OF_DAYS_SECONDS"
out="$(verify b2)"
check "fresh: exit 0" "$(verify_rc b2)" "0"
has   "fresh: states the age it verified" "$out" "latest snapshot is 1h old (limit 48h)"
check "fresh: reports success" "$(cat "$HOOK_RECORD")" "verify canary success"

snapshots_aged_hours 47
check "just inside the limit: exit 0" "$(verify_rc b2)" "0"

echo
echo "=== a snapshot past the limit ==="

snapshots_aged_hours 1440; uptime_seconds "$UPTIME_OF_DAYS_SECONDS"
out="$(verify b2)"
check "stale, up for days: exit 1" "$(verify_rc b2)" "1"
has   "stale, up for days: says backups are not running" "$out" "backups are not running"
check "stale, up for days: reports failure" "$(cat "$HOOK_RECORD")" "verify canary fail"

snapshots_aged_hours 49
check "just past the limit: exit 1" "$(verify_rc b2)" "1"

snapshots_aged_hours 1440; uptime_seconds "$UPTIME_OF_TWO_HOURS_SECONDS"
out="$(verify b2)"
check "stale, up for 2h: exit 0" "$(verify_rc b2)" "0"
has   "stale, up for 2h: says it was not judged, and why" "$out" "not judged: this machine has been up for only 2h"

# An uptime that cannot be read must not become the excuse.
snapshots_aged_hours 1440; rm -f "$UPTIME_FILE"
check "stale, uptime unreadable: exit 1" "$(verify_rc b2)" "1"
uptime_seconds "$UPTIME_OF_DAYS_SECONDS"

echo
echo "=== the limit is configuration ==="

snapshots_aged_hours 1440
out="$(verify b2 BACKUP_VERIFY_MAX_AGE_HOURS=0)"
check "limit 0: exit 0" "$(verify_rc b2 BACKUP_VERIFY_MAX_AGE_HOURS=0)" "0"
has   "limit 0: says the age is not judged" "$out" "age is not judged"

check "a longer limit covers it: exit 0" "$(verify_rc b2 BACKUP_VERIFY_MAX_AGE_HOURS=2000)" "0"
check "set but empty falls back to the default: exit 1" "$(verify_rc b2 BACKUP_VERIFY_MAX_AGE_HOURS=)" "1"
check "non-numeric limit: exit 2" "$(verify_rc b2 BACKUP_VERIFY_MAX_AGE_HOURS=two-days)" "2"

# The external disk is undocked for weeks at a time; an old snapshot there is normal.
check "external, stale: exit 0" "$(verify_rc external)" "0"
check "external, stale, with a limit set: exit 1" "$(verify_rc external BACKUP_VERIFY_MAX_AGE_HOURS=48)" "1"

echo
echo "=== reading the snapshot time ==="

# restic returns one snapshot per host-and-paths group; the newest is `latest`.
snapshots_aged_hours 1440 1
check "newest of several, old one first: exit 0" "$(verify_rc b2)" "0"
snapshots_aged_hours 1 1440
check "newest of several, old one last: exit 0" "$(verify_rc b2)" "0"

printf '[\n  {\n    "time": "%s",\n    "id": "abc"\n  }\n]\n' "$(date -d '-1 hours' --iso-8601=seconds)" > "$SNAPSHOTS_JSON"
check "indented JSON is read too: exit 0" "$(verify_rc b2)" "0"

printf '[]\n' > "$SNAPSHOTS_JSON"
out="$(verify b2)"
check "no snapshot time readable: exit 1" "$(verify_rc b2)" "1"
has   "no snapshot time readable: says the age is UNKNOWN" "$out" "its age is UNKNOWN"

printf '[{"time":"not-a-date","id":"abc"}]\n' > "$SNAPSHOTS_JSON"
check "an unparseable snapshot time: exit 1" "$(verify_rc b2)" "1"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
EXPECTED_ROWS=24
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mROW COUNT\033[0m: expected %d rows, %d ran — a check vanished or was added without updating EXPECTED_ROWS\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 1
fi
[[ "$FAIL" -eq 0 ]]
