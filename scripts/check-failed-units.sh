#!/usr/bin/env bash
#
# scripts/check-failed-units.sh
# =============================
#
# Report what check-timer-health.sh's ownership list cannot see: any failed unit
# in the SYSTEM manager, any failed USER unit nobody else judged, and a backup
# that has stopped succeeding. Root-free, so it can run from a shell prompt.
#
# WHY THIS EXISTS. From 2026-09-20 both b2 backup units sat in `systemctl
# --failed` for 54 days. check-timer-health.sh, and the first-prompt warning it
# feeds, read only the USER units this checkout links, so the one alarm on this
# machine that speaks without being asked had nothing to say. backup-doctor would
# have, and needs sudo and someone to think of running it. The same blind spot
# covered every user unit not linked from the checkout: nanoclaw-fleet-agent
# failed 212 times in three days in the same week.
#
# WHAT IT READS, all without root:
#   - `systemctl list-units --state=failed`, system and user.
#   - /var/lib/restic-notify/<profile>-<command>.state, which restic-notify
#     writes world-readable: "success <epoch>" on every success, "fail <epoch>"
#     while failing. A unit that never STARTED writes nothing, so a state that
#     still says "success" proves little by itself; its AGE is what is judged.
#
# A backup's age is judged only on a machine that has been up for a day: a
# laptop that was switched off has an old backup and nothing wrong with it.
#
# WHAT IT CANNOT SEE. A unit that fails and then succeeds leaves no failed state
# behind. And only states that a success rewrites are judged: resticprofile's
# check profile has a failure hook and no success hook, so `b2-check.state` can
# say "fail" for months after the check recovered (it has read `fail` since
# 2026-08-30 on cilantro). It is stated, not counted.
#
# Usage: scripts/check-failed-units.sh
#
# Environment:
#   FAILED_UNITS_JUDGED_ELSEWHERE   newline-separated user units another checker
#                                   already judged; not reported again here
#   BACKUP_STALE_HOURS_<NAME>       the age limit for one state, NAME being the
#                                   state's name in capitals with _ for - (for
#                                   example BACKUP_STALE_HOURS_EXTERNAL_BACKUP).
#                                   0 = do not judge its age
#   BACKUP_STALE_MIN_UPTIME_HOURS   default 24
#   FAILED_UNITS_STATE_DIR, FAILED_UNITS_UPTIME_FILE, FAILED_UNITS_NOW
#                                   only scripts/test-check-failed-units.sh sets these
#
# Exit: 0 nothing failed and nothing is stale (or there was nothing to read,
#         said so with ○ and never with ✓);
#       1 a unit is failed, or a backup is failing or stale;
#       2 could not run: a bad argument or a setting that is not a whole number.

set -uo pipefail

readonly EXIT_HEALTHY=0
readonly EXIT_FAULT=1
readonly EXIT_COULD_NOT_RUN=2
readonly SECONDS_PER_HOUR=3600
readonly HOURS_PER_DAY=24
readonly AGE_NOT_JUDGED=0
readonly DEFAULT_MIN_UPTIME_HOURS=24

readonly STATE_DIR="${FAILED_UNITS_STATE_DIR:-/var/lib/restic-notify}"
readonly UPTIME_FILE="${FAILED_UNITS_UPTIME_FILE:-/proc/uptime}"
readonly STATE_FILE_SUFFIX=".state"

# How old a state's last success may be, in hours. Only states listed here are
# judged at all; see WHAT IT CANNOT SEE in the header for why the rest are not.
declare -rA DEFAULT_STALE_HOURS=(
  [b2-backup]=48          # scheduled every two hours through the day
  [external-backup]=336   # 14 days: the disk is docked now and then
  [verify-canary]=360     # weekly, so 15 days is two missed runs
)
# What to do about a stale state, when it is not "run backup-doctor".
declare -rA STALE_HINT=(
  [external-backup]="dock the external disk"
)
readonly DEFAULT_STALE_HINT="run backup-doctor"

fault_count=0
ok()          { printf '  ✓ %s\n' "$*"; }
not_checked() { printf '  ○ %s\n' "$*"; }
note()        { printf '  · %s\n' "$*"; }
fault()       { printf '  ✗ %s\n' "$*"; fault_count=$((fault_count + 1)); }

could_not_run() {
  printf 'check-failed-units: %s\n' "$*" >&2
  exit "$EXIT_COULD_NOT_RUN"
}

(( $# == 0 )) || could_not_run "unknown argument '$1'"

NOW="${FAILED_UNITS_NOW:-$(date +%s)}"
MIN_UPTIME_HOURS="${BACKUP_STALE_MIN_UPTIME_HOURS:-$DEFAULT_MIN_UPTIME_HOURS}"
[[ "$NOW" =~ ^[0-9]+$ ]] || could_not_run "FAILED_UNITS_NOW must be epoch seconds, got '$NOW'"
[[ "$MIN_UPTIME_HOURS" =~ ^[0-9]+$ ]] ||
  could_not_run "BACKUP_STALE_MIN_UPTIME_HOURS must be a whole number, got '$MIN_UPTIME_HOURS'"

# --- failed units -----------------------------------------------------------

# Is this user unit one another checker already judged?
#   $1 — unit name
judged_elsewhere() {
  local unit="$1" judged_unit
  while IFS= read -r judged_unit; do
    [[ "$judged_unit" == "$unit" ]] && return 0
  done <<<"${FAILED_UNITS_JUDGED_ELSEWHERE:-}"
  return 1
}

# Report the failed units of one systemd manager.
#   $1 — "system" or "user"
report_failed_units_of() {
  local manager="$1" listing unit marker_or_unit rest reported=0
  local -a manager_flag=() journal_flag=()
  if [[ "$manager" == "user" ]]; then
    manager_flag=(--user); journal_flag=(--user)
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    not_checked "no systemctl on this machine — failed $manager units not checked"
    return
  fi
  # A manager that cannot be reached is not a manager with nothing failed.
  if ! listing="$(systemctl "${manager_flag[@]}" list-units --state=failed --plain --no-legend 2>/dev/null)"; then
    not_checked "the $manager manager is not reachable — failed $manager units not checked"
    return
  fi

  while read -r marker_or_unit rest; do
    [[ -n "$marker_or_unit" ]] || continue
    # Without --plain, and on some versions with it, a failed unit's line starts
    # with a bullet. Take the unit name whichever column it is in.
    unit="$marker_or_unit"
    [[ "$unit" == "●" ]] && unit="${rest%% *}"
    if [[ "$manager" == "user" ]] && judged_elsewhere "$unit"; then
      continue
    fi
    fault "$manager unit failed: $unit — journalctl ${journal_flag[*]:+${journal_flag[*]} }-u $unit"
    reported=1
  done <<<"$listing"

  if (( ! reported )); then
    if [[ "$manager" == "user" ]]; then
      ok "no failed user units beyond the ones already judged"
    else
      ok "no failed system units"
    fi
  fi
}

# --- backup freshness -------------------------------------------------------

# Print how many whole hours this machine has been up, or nothing when that
# cannot be read.
uptime_hours() {
  local uptime_seconds
  read -r uptime_seconds _ < "$UPTIME_FILE" 2>/dev/null || return 0
  uptime_seconds="${uptime_seconds%%.*}"
  [[ "$uptime_seconds" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$(( uptime_seconds / SECONDS_PER_HOUR ))"
}

# Print the age limit, in hours, for a state name, or nothing when that state is
# not one this script judges. An override that is not a whole number stops the run.
#   $1 — state name, e.g. external-backup
stale_hours_for() {
  local state_name="$1" override_name override_value
  [[ -n "${DEFAULT_STALE_HOURS[$state_name]:-}" ]] || return 0
  override_name="BACKUP_STALE_HOURS_${state_name^^}"
  override_name="${override_name//-/_}"
  override_value="${!override_name:-${DEFAULT_STALE_HOURS[$state_name]}}"
  [[ "$override_value" =~ ^[0-9]+$ ]] || could_not_run "$override_name must be a whole number, got '$override_value'"
  printf '%s' "$override_value"
}

# Spell an age the way a person reads it: hours up to two days, then days.
#   $1 — age in hours
human_age() {
  local age_hours="$1"
  if (( age_hours < 2 * HOURS_PER_DAY )); then
    printf '%sh' "$age_hours"
  else
    printf '%s days' "$(( age_hours / HOURS_PER_DAY ))"
  fi
}

# Judge one state file.
#   $1 — path to <name>.state
report_backup_state() {
  local state_file="$1" state_name recorded_status recorded_epoch limit_hours age_hours machine_uptime_hours
  state_name="$(basename "$state_file" "$STATE_FILE_SUFFIX")"
  recorded_status=""; recorded_epoch=""
  read -r recorded_status recorded_epoch < "$state_file" 2>/dev/null || true

  # Resolved in THIS shell, never through $(...): a bad override must stop the
  # whole run, and an exit inside a command substitution ends only the subshell.
  local limit_file
  limit_file="$(mktemp)" || could_not_run "could not create a temp file"
  stale_hours_for "$state_name" > "$limit_file"
  limit_hours="$(<"$limit_file")"
  rm -f "$limit_file"

  if [[ -z "$limit_hours" ]]; then
    # Not a state a success rewrites, so neither its age nor its "fail" is evidence.
    if [[ "$recorded_status" == "fail" ]]; then
      note "backup $state_name: recorded a failure; nothing rewrites this state on success, so it is not judged (read the journal)"
    fi
    return
  fi
  if [[ "$recorded_status" != "success" && "$recorded_status" != "fail" ]] || [[ ! "$recorded_epoch" =~ ^[0-9]+$ ]]; then
    fault "backup $state_name: $state_file is unreadable — its state is UNKNOWN"
    return
  fi
  if [[ "$recorded_status" == "fail" ]]; then
    fault "backup $state_name: failing — ${STALE_HINT[$state_name]:-$DEFAULT_STALE_HINT}"
    return
  fi

  age_hours=$(( (NOW - recorded_epoch) / SECONDS_PER_HOUR ))
  if (( limit_hours == AGE_NOT_JUDGED )); then
    note "backup $state_name: last succeeded $(human_age "$age_hours") ago (its age is not judged)"
    return
  fi
  if (( age_hours <= limit_hours )); then
    ok "backup $state_name: last succeeded $(human_age "$age_hours") ago (limit $(human_age "$limit_hours"))"
    return
  fi
  # Past the limit. A laptop that was off is the innocent explanation, and it
  # holds only until the machine has been up for a day. An uptime that cannot be
  # read excuses nothing.
  machine_uptime_hours="$(uptime_hours)"
  if [[ -n "$machine_uptime_hours" ]] && (( machine_uptime_hours < MIN_UPTIME_HOURS )); then
    note "backup $state_name: last succeeded $(human_age "$age_hours") ago, over the $(human_age "$limit_hours") limit — not judged: up for only ${machine_uptime_hours}h"
    return
  fi
  fault "backup $state_name: last succeeded $(human_age "$age_hours") ago, limit $(human_age "$limit_hours") — ${STALE_HINT[$state_name]:-$DEFAULT_STALE_HINT}"
}

report_backup_freshness() {
  local state_file found_state=0
  if [[ ! -d "$STATE_DIR" ]]; then
    not_checked "no backup state in $STATE_DIR — backup freshness not checked"
    return
  fi
  for state_file in "$STATE_DIR"/*"$STATE_FILE_SUFFIX"; do
    [[ -f "$state_file" ]] || continue
    found_state=1
    report_backup_state "$state_file"
  done
  (( found_state )) || not_checked "$STATE_DIR holds no state — backup freshness not checked"
}

# --- main -------------------------------------------------------------------

report_failed_units_of system
report_failed_units_of user
report_backup_freshness

(( fault_count == 0 )) || exit "$EXIT_FAULT"
exit "$EXIT_HEALTHY"
