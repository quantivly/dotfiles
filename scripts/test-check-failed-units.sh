#!/usr/bin/env bash
#
# scripts/test-check-failed-units.sh
# ==================================
#
# State table for scripts/check-failed-units.sh.
#
# The rows this file exists for are "a failed SYSTEM unit: exit 1" and "the b2
# backup last succeeded 60 days ago on a machine up for days: exit 1". Both were
# true on cilantro for 54 days from 2026-09-20 and the one alarm that speaks
# unasked said nothing, because it read only the user units this checkout links.
#
# The rest keep the checker honest in both directions: it must not cry wolf at a
# laptop that was off, a manager it cannot reach, or a state nothing rewrites on
# success; and it must never turn "I could not read this" into a tick.
#
# Hermetic: systemctl is a stub, and the state directory, the uptime file and
# "now" are all supplied by the row.
#
# MUTANTS. Each was applied to a copy of the checker and run through this table
# (CHECK=<copy>); the rows named are the ones that fail.
#   M1  never list the system manager             -> "a failed system unit: exit 1"
#   M2  an unreachable manager reads as clean      -> "system manager unreachable: says not checked"
#   M3  ignore FAILED_UNITS_JUDGED_ELSEWHERE       -> "a user unit judged elsewhere: exit 0"
#   M4  skip units judged elsewhere in the SYSTEM  -> "the same name in the system manager is still reported"
#       manager too
#   M5  drop the "laptop was off" excuse           -> "stale b2, up for 2h: exit 0"
#   M6  an unreadable uptime excuses the age       -> "stale b2, uptime unreadable: exit 1"
#   M7  a recorded failure is read as an age       -> "b2 failing, up for 2h: exit 1"
#   M8  an unreadable state file passes            -> "unreadable state: exit 1"
#   M9  judge a state nothing rewrites on success  -> "b2-check says fail: exit 0"
#   M10 accept a non-numeric limit                 -> "non-numeric limit: exit 2"
#   M11 flip the age comparison                    -> "fresh b2: exit 0"
#
# Usage: scripts/test-check-failed-units.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${CHECK:-$HERE/check-failed-units.sh}"
BASH_BIN="$(command -v bash)"

PASS=0; FAIL=0
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1 — output lacked '$3'"; fi; }
hasnt(){ if grep -qF -- "$3" <<<"$2"; then bad "$1 — output contained '$3'"; else ok "$1"; fi; }
[[ -x "$CHECK" ]] || { printf 'FATAL: not executable: %s\n' "$CHECK" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB_BIN="$TMP/bin"
STATE_DIR="$TMP/restic-notify"
UPTIME_FILE="$TMP/uptime"
SYSTEM_FAILED="$TMP/system-failed"
USER_FAILED="$TMP/user-failed"
mkdir -p "$STUB_BIN"

readonly NOW=2000000000
readonly SECONDS_PER_HOUR=3600
readonly SECONDS_PER_DAY=86400
readonly UPTIME_OF_DAYS_SECONDS=$(( 72 * SECONDS_PER_HOUR ))
readonly UPTIME_OF_TWO_HOURS_SECONDS=$(( 2 * SECONDS_PER_HOUR ))
readonly MANAGER_UNREACHABLE="unreachable"

# systemctl: prints the row's failed-unit listing for the manager asked, or
# fails outright when the row marked that manager unreachable.
cat > "$STUB_BIN/systemctl" <<STUB
#!/bin/sh
listing="$SYSTEM_FAILED"
case " \$* " in *" --user "*) listing="$USER_FAILED" ;; esac
[ "\$(cat "\$listing" 2>/dev/null)" = "$MANAGER_UNREACHABLE" ] && exit 1
cat "\$listing" 2>/dev/null
exit 0
STUB
chmod +x "$STUB_BIN/systemctl"

# Start a row from a clean machine: nothing failed, no backup state, up for days.
clean_machine() {
  : > "$SYSTEM_FAILED"; : > "$USER_FAILED"
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
  printf '%s.00 0.00\n' "$UPTIME_OF_DAYS_SECONDS" > "$UPTIME_FILE"
}
# Record a backup state: $1 = name, $2 = success|fail, $3 = how long ago, in seconds.
backup_state() { printf '%s %s\n' "$2" "$(( NOW - $3 ))" > "$STATE_DIR/$1.state"; }
uptime_seconds() { printf '%s.00 0.00\n' "$1" > "$UPTIME_FILE"; }

# Run the checker; arguments are VAR=value overrides.
run_check() {
  env -i PATH="$STUB_BIN:/usr/bin:/bin" \
    FAILED_UNITS_STATE_DIR="$STATE_DIR" FAILED_UNITS_UPTIME_FILE="$UPTIME_FILE" FAILED_UNITS_NOW="$NOW" \
    "$@" "$BASH_BIN" "$CHECK" 2>&1
}
run_rc() { run_check "$@" >/dev/null; printf '%s' "$?"; }

echo
echo "=== failed units ==="

clean_machine
out="$(run_check)"
check "nothing failed: exit 0" "$(run_rc)" "0"
has   "nothing failed: says the system manager is clean" "$out" "no failed system units"

clean_machine
printf 'resticprofile-backup@profile-b2.service loaded failed failed resticprofile backup\n' > "$SYSTEM_FAILED"
out="$(run_check)"
check "a failed system unit: exit 1" "$(run_rc)" "1"
has   "a failed system unit: names it" "$out" "system unit failed: resticprofile-backup@profile-b2.service"

clean_machine
printf 'a.service loaded failed failed A\nb.service loaded failed failed B\n' > "$SYSTEM_FAILED"
check "two failed system units: both are counted" "$(run_check | grep -c 'system unit failed')" "2"

# Some systemctl versions lead a failed unit's line with a bullet.
clean_machine
printf '● bulleted.service loaded failed failed Bulleted\n' > "$SYSTEM_FAILED"
has   "a bullet before the unit name is not taken for the name" "$(run_check)" "system unit failed: bulleted.service"

clean_machine
printf 'nanoclaw-fleet-agent.service loaded failed failed fleet agent\n' > "$USER_FAILED"
out="$(run_check)"
check "a failed user unit: exit 1" "$(run_rc)" "1"
has   "a failed user unit: names it, with the --user journal command" "$out" "journalctl --user -u nanoclaw-fleet-agent.service"

clean_machine
printf 'wt-gc-sweep.service loaded failed failed sweep\n' > "$USER_FAILED"
check "a user unit judged elsewhere: exit 0" "$(run_rc FAILED_UNITS_JUDGED_ELSEWHERE="wt-gc-sweep.service")" "0"
printf 'wt-gc-sweep.service loaded failed failed sweep\n' > "$SYSTEM_FAILED"
check "the same name in the system manager is still reported" \
  "$(run_rc FAILED_UNITS_JUDGED_ELSEWHERE="wt-gc-sweep.service")" "1"

clean_machine
printf '%s\n' "$MANAGER_UNREACHABLE" > "$SYSTEM_FAILED"
out="$(run_check)"
check "system manager unreachable: exit 0" "$(run_rc)" "0"
has   "system manager unreachable: says not checked" "$out" "the system manager is not reachable"
hasnt "system manager unreachable: does not claim it is clean" "$out" "no failed system units"

clean_machine
check "no systemctl at all: exit 0" \
  "$(env -i PATH="$TMP/no-such-bin" FAILED_UNITS_STATE_DIR="$STATE_DIR" FAILED_UNITS_UPTIME_FILE="$UPTIME_FILE" FAILED_UNITS_NOW="$NOW" "$BASH_BIN" "$CHECK" >/dev/null 2>&1; printf '%s' "$?")" "0"

echo
echo "=== backup freshness ==="

clean_machine; rmdir "$STATE_DIR"
out="$(run_check)"
check "no state directory: exit 0" "$(run_rc)" "0"
has   "no state directory: says freshness was not checked" "$out" "backup freshness not checked"

clean_machine; backup_state b2-backup success "$SECONDS_PER_HOUR"
out="$(run_check)"
check "fresh b2: exit 0" "$(run_rc)" "0"
has   "fresh b2: states its age and the limit" "$out" "backup b2-backup: last succeeded 1h ago (limit 2 days)"

clean_machine; backup_state b2-backup success "$(( 60 * SECONDS_PER_DAY ))"
out="$(run_check)"
check "stale b2, up for days: exit 1" "$(run_rc)" "1"
has   "stale b2, up for days: states the age" "$out" "backup b2-backup: last succeeded 60 days ago, limit 2 days"

uptime_seconds "$UPTIME_OF_TWO_HOURS_SECONDS"
out="$(run_check)"
check "stale b2, up for 2h: exit 0" "$(run_rc)" "0"
has   "stale b2, up for 2h: says it was not judged, and why" "$out" "not judged: up for only 2h"

rm -f "$UPTIME_FILE"
check "stale b2, uptime unreadable: exit 1" "$(run_rc)" "1"

# A recorded failure is a failure whatever the uptime: the backup RAN and failed.
clean_machine; backup_state b2-backup fail "$SECONDS_PER_HOUR"; uptime_seconds "$UPTIME_OF_TWO_HOURS_SECONDS"
out="$(run_check)"
check "b2 failing, up for 2h: exit 1" "$(run_rc)" "1"
has   "b2 failing: says so" "$out" "backup b2-backup: failing"

clean_machine; backup_state external-backup success "$(( 20 * SECONDS_PER_DAY ))"
out="$(run_check)"
check "external copy 20 days old: exit 1" "$(run_rc)" "1"
has   "external copy 20 days old: says what to do" "$out" "dock the external disk"

clean_machine; backup_state external-backup success "$(( 10 * SECONDS_PER_DAY ))"
check "external copy 10 days old: exit 0" "$(run_rc)" "0"

clean_machine; backup_state external-backup success "$(( 20 * SECONDS_PER_DAY ))"
check "a longer limit for one state covers it: exit 0" "$(run_rc BACKUP_STALE_HOURS_EXTERNAL_BACKUP=720)" "0"
check "limit 0 turns the age judgement off: exit 0" "$(run_rc BACKUP_STALE_HOURS_EXTERNAL_BACKUP=0)" "0"
check "non-numeric limit: exit 2" "$(run_rc BACKUP_STALE_HOURS_EXTERNAL_BACKUP=a-month)" "2"

# resticprofile's check profile has a failure hook and no success hook, so this
# state can read "fail" for months after the check recovered.
clean_machine; backup_state b2-check fail "$(( 75 * SECONDS_PER_DAY ))"
out="$(run_check)"
check "b2-check says fail: exit 0" "$(run_rc)" "0"
has   "b2-check says fail: stated, and said not to be judged" "$out" "backup b2-check: recorded a failure; nothing rewrites this state on success"

clean_machine; printf 'garbage\n' > "$STATE_DIR/b2-backup.state"
out="$(run_check)"
check "unreadable state: exit 1" "$(run_rc)" "1"
has   "unreadable state: says its state is UNKNOWN" "$out" "its state is UNKNOWN"

echo
echo "=== usage ==="

clean_machine
check "unknown argument: exit 2" "$(env -i PATH="$STUB_BIN:/usr/bin:/bin" "$BASH_BIN" "$CHECK" --bogus >/dev/null 2>&1; printf '%s' "$?")" "2"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
EXPECTED_ROWS=36
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mROW COUNT\033[0m: expected %d rows, %d ran — a check vanished or was added without updating EXPECTED_ROWS\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 1
fi
[[ "$FAIL" -eq 0 ]]
