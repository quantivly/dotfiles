#!/usr/bin/env bash
#
# scripts/restic-unit-failed.sh
# =============================
#
# OnFailure= handler for the backup units (runs as ROOT, started by systemd as
# restic-unit-failed@<failed unit>.service). Reports a backup unit that FAILED,
# through the same channel a failed backup already uses: restic-notify, so the
# healthchecks.io /fail ping, the desktop alert and its dedup state all apply.
#
# WHY THIS EXISTS. profiles.toml's `run-after-fail = restic-notify fail` is run
# BY resticprofile. A unit that fails before resticprofile starts never reaches
# it. From 2026-09-20 both b2 units failed at CHDIR (their WorkingDirectory had
# been removed) on every scheduled run, 398 times over 54 days: no ping, no
# alert, and /var/lib/restic-notify/b2-backup.state still read "success". The
# same is true of any pre-exec failure: a missing binary (203/EXEC), an
# unreadable EnvironmentFile, a bad User=.
#
# A unit that fails AFTER resticprofile ran its own hook reaches restic-notify
# twice. That is harmless: the ping is idempotent and the alert is deduplicated
# on state change.
#
# Usage (invoked by systemd): restic-unit-failed <failed unit name>
#
# Environment:
#   RESTIC_NOTIFY_HOOK — the hook to call; only scripts/test-backup-units.sh sets it.
#
# Exit: the hook's own status; 2 on a usage error; 1 when the hook cannot be run
#       (a reporter that cannot report must not look like one that did).

set -uo pipefail

readonly EXIT_USAGE=2
readonly EXIT_CANNOT_REPORT=1
readonly NOTIFY_HOOK="${RESTIC_NOTIFY_HOOK:-/usr/local/bin/restic-notify}"

# The units resticprofile generates are named resticprofile-<command>@profile-<profile>.service.
readonly GENERATED_UNIT_PREFIX="resticprofile-"
readonly GENERATED_INSTANCE_PREFIX="profile-"
readonly UNIT_SUFFIX=".service"
# What restic-notify is told for a unit this script has no mapping for: it then
# keeps a state file and alerts under the unit's own name, and pings nothing.
readonly UNMAPPED_PROFILE_NAME="unit"

failed_unit="${1:-}"
if [[ -z "$failed_unit" ]]; then
  printf 'usage: restic-unit-failed <failed unit name>\n' >&2
  exit "$EXIT_USAGE"
fi

# Map the failed unit to the (profile, command) pair restic-notify keys on: its
# healthcheck URL, its state file and the words in its alert.
case "$failed_unit" in
  "${GENERATED_UNIT_PREFIX}"*"@${GENERATED_INSTANCE_PREFIX}"*"${UNIT_SUFFIX}")
    command_and_instance="${failed_unit#"$GENERATED_UNIT_PREFIX"}"
    command_name="${command_and_instance%%@*}"
    instance_name="${failed_unit#*@}"
    profile_name="${instance_name#"$GENERATED_INSTANCE_PREFIX"}"
    profile_name="${profile_name%"$UNIT_SUFFIX"}"
    ;;
  restic-backup-external.service)
    profile_name="external"; command_name="backup" ;;
  restic-verify.service)
    # backup-verify.sh reports under verify/canary; keep one state file for both.
    profile_name="verify"; command_name="canary" ;;
  *)
    profile_name="$UNMAPPED_PROFILE_NAME"; command_name="${failed_unit%"$UNIT_SUFFIX"}" ;;
esac

# For the journal: why the unit failed, as systemd recorded it. Best-effort; the
# report below must go out whether or not this can be read.
failure_detail="$(systemctl show "$failed_unit" --property=Result --property=ExecMainStatus 2>/dev/null | tr '\n' ' ')"
printf 'restic-unit-failed: %s failed (%s) — reporting as %s %s\n' \
  "$failed_unit" "${failure_detail:-no detail available}" "$profile_name" "$command_name"

if [[ ! -x "$NOTIFY_HOOK" ]]; then
  printf 'restic-unit-failed: %s is not executable — the failure of %s is UNREPORTED\n' "$NOTIFY_HOOK" "$failed_unit" >&2
  exit "$EXIT_CANNOT_REPORT"
fi

PROFILE_NAME="$profile_name" PROFILE_COMMAND="$command_name" exec "$NOTIFY_HOOK" fail
