#!/usr/bin/env bash
#
# scripts/test-backup-units.sh
# ============================
#
# State table for the two things that let the offsite backup fail for 54 days
# with no signal (2026-09-20 to 2026-11-13):
#
#   1. The scheduled units ran from a directory that could be removed.
#      `resticprofile schedule` records its current directory as WorkingDirectory;
#      it was run from a worktree, the worktree went away, and every run failed at
#      CHDIR. Pinned here: the drop-in setup-backup.sh installs, and the directory
#      rp() runs resticprofile from.
#   2. A unit that fails before resticprofile starts runs none of its hooks, so
#      nothing reported it. Pinned here: the OnFailure= wiring and
#      scripts/restic-unit-failed.sh, the reporter it starts.
#
# Hermetic and root-free: sudo, resticprofile, systemctl and the notify hook are
# stubs, and every file is written under a temp dir.
#
# MUTANTS. Each was applied to a copy of the code and run through this table
# (SETUP=<copy> or REPORTER=<copy>); the rows named are the ones that fail.
#   M1  drop the 20-workdir.conf install       -> "<template>: working directory is pinned to /"
#   M2  pin the working directory to $PWD      -> the same two rows
#   M3  OnFailure= names %p instead of %n      -> "<template>: a failure starts the reporter…"
#   M4  drop `cd /` from rp()                  -> "rp runs resticprofile from /"
#   M5  install_drop_in ignores a failed       -> "a drop-in that cannot be installed: non-zero"
#       install
#   M6  install_schedule_drop_ins carries on   -> "a drop-in that cannot be installed: non-zero"
#       after a failed drop-in
#   M7  the reporter swaps profile and command -> every "reports as …" row
#   M8  the reporter skips its executable check-> "hook not executable: exit 1", "…says UNREPORTED"
#   M9  the reporter reports `success`         -> every "reports as …" row
#   M10 the external unit loses OnFailure=     -> "restic-backup-external.service names the reporter"
#   M11 the reporter unit gains a key systemd  -> "systemd accepts the reporter unit under a failed
#       does not know                             unit's full name"
#
# Requires: systemd (systemd-analyze). No sudo.
#
# Usage: scripts/test-backup-units.sh

# SC2016: the stub scripts and the grep needle below are literal text on purpose;
#         nothing in those single quotes is meant to expand here.
# SC2317, SC2329: the `sudo` stubs are called by the functions under test, not by
#         name here. Two codes because the pinned pre-commit shellcheck (0.9) and a
#         current one (0.11) report the same thing under different numbers.
# shellcheck disable=SC2016,SC2317,SC2329
set -uo pipefail

REPO_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${SETUP:-$REPO_ROOT_DIR/scripts/setup-backup.sh}"
REPORTER="${REPORTER:-$REPO_ROOT_DIR/scripts/restic-unit-failed.sh}"
UNIT_SOURCE_DIR="${UNIT_SOURCE_DIR:-$REPO_ROOT_DIR/systemd}"
BASH_BIN="$(command -v bash)"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1 — output lacked '$3'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

command -v systemd-analyze >/dev/null || fatal "systemd-analyze is required"

# Source the installer without running it (main is guarded).
# shellcheck source=/dev/null
source "$SETUP" || fatal "could not source $SETUP"
# The installer's own `set -euo pipefail` is now live in THIS shell. A suite that
# runs things expected to fail cannot have errexit: `got="$(returns_1)"` would
# end the run mid-table with no failure count. Restore this file's own options.
set +e
set -uo pipefail

# Absence is what a suite that sourced nothing produces, so assert the code under
# test is loaded before asserting anything about what it does.
for function_name in install_drop_in install_schedule_drop_ins rp; do
  declare -F "$function_name" >/dev/null || fatal "$function_name is not defined after sourcing $SETUP"
done

# Run a command as the test user, dropping the ownership flags only root can honour.
run_without_ownership_flags() {
  local argument kept_arguments=() skip_next=0
  for argument in "$@"; do
    if (( skip_next )); then skip_next=0; continue; fi
    case "$argument" in -o|-g) skip_next=1; continue ;; esac
    kept_arguments+=("$argument")
  done
  "${kept_arguments[@]}"
}

# --- 1. the drop-ins --------------------------------------------------------

echo
echo "=== the drop-ins setup-backup.sh installs for the generated units ==="

SYSTEMD_SYSTEM_DIR="$TMPROOT/systemd-healthy"
mkdir -p "$SYSTEMD_SYSTEM_DIR"
sudo() { run_without_ownership_flags "$@"; }
install_schedule_drop_ins >/dev/null 2>&1
check "every drop-in installed: returns 0" "$?" "0"

EXPECTED_ENV_DROP_IN="[Service]
EnvironmentFile=/etc/restic/backup.local"
EXPECTED_WORKDIR_DROP_IN="[Service]
WorkingDirectory=/"
EXPECTED_ON_FAILURE_DROP_IN="[Unit]
OnFailure=restic-unit-failed@%n.service"

for template in resticprofile-backup resticprofile-check; do
  drop_in_dir="$SYSTEMD_SYSTEM_DIR/${template}@.service.d"
  check "$template: the environment file is wired in" \
    "$(cat "$drop_in_dir/10-backup-env.conf" 2>/dev/null)" "$EXPECTED_ENV_DROP_IN"
  check "$template: working directory is pinned to /" \
    "$(cat "$drop_in_dir/20-workdir.conf" 2>/dev/null)" "$EXPECTED_WORKDIR_DROP_IN"
  check "$template: a failure starts the reporter, named after the failed unit" \
    "$(cat "$drop_in_dir/30-on-failure.conf" 2>/dev/null)" "$EXPECTED_ON_FAILURE_DROP_IN"
done

# One drop-in cannot be installed. The run must say so and return non-zero: a
# half-wired unit that reads as wired is the failure this file exists for.
SYSTEMD_SYSTEM_DIR="$TMPROOT/systemd-failing"
mkdir -p "$SYSTEMD_SYSTEM_DIR"
sudo() {
  [[ "${*: -1}" == */20-workdir.conf ]] && return 1
  run_without_ownership_flags "$@"
}
failing_output="$(install_schedule_drop_ins 2>&1)"
failing_status=$?
check "a drop-in that cannot be installed: non-zero" "$failing_status" "1"
has   "a drop-in that cannot be installed: names it" "$failing_output" "could not install $SYSTEMD_SYSTEM_DIR/resticprofile-backup@.service.d/20-workdir.conf"

# --- 2. rp() ----------------------------------------------------------------

echo
echo "=== rp() runs resticprofile from a directory that cannot go away ==="

STUB_BIN="$TMPROOT/bin"
mkdir -p "$STUB_BIN" "$TMPROOT/a-worktree-that-will-be-removed"
printf '#!/bin/sh\nprintf "cwd=%%s args=%%s\\n" "$PWD" "$*"\n' > "$STUB_BIN/resticprofile"
chmod +x "$STUB_BIN/resticprofile"
sudo() { "$@"; }
rp_output="$(cd "$TMPROOT/a-worktree-that-will-be-removed" && PATH="$STUB_BIN:$PATH" rp schedule --all 2>&1)"
check "rp runs resticprofile from /" "${rp_output%% args=*}" "cwd=/"
check "rp passes the config and the arguments through" "${rp_output#* args=}" "-c /etc/resticprofile/profiles.toml schedule --all"

# --- 3. the reporter --------------------------------------------------------

echo
echo "=== restic-unit-failed.sh maps a failed unit onto restic-notify's keys ==="

[[ -x "$REPORTER" ]] || fatal "not executable: $REPORTER"

HOOK_RECORD="$TMPROOT/hook-record"
RECORDING_HOOK="$STUB_BIN/recording-notify-hook"
# A relative path would be resolved by the reporter's own working directory.
cat > "$RECORDING_HOOK" <<HOOK
#!/bin/sh
printf '%s %s %s\n' "\$PROFILE_NAME" "\$PROFILE_COMMAND" "\$*" >> "$HOOK_RECORD"
exit "\${HOOK_EXIT_STATUS:-0}"
HOOK
chmod +x "$RECORDING_HOOK"
# The reporter asks systemd why the unit failed; keep that off the real machine.
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/systemctl"
chmod +x "$STUB_BIN/systemctl"

# Run the reporter for a unit name; print what the hook was called with.
reported_as() {
  : > "$HOOK_RECORD"
  PATH="$STUB_BIN:$PATH" RESTIC_NOTIFY_HOOK="$RECORDING_HOOK" "$BASH_BIN" "$REPORTER" "$1" >/dev/null 2>&1
  cat "$HOOK_RECORD"
}

check "the b2 backup unit reports as b2 backup" \
  "$(reported_as 'resticprofile-backup@profile-b2.service')" "b2 backup fail"
check "the b2 check unit reports as b2 check" \
  "$(reported_as 'resticprofile-check@profile-b2.service')" "b2 check fail"
check "a profile name with a dash is kept whole" \
  "$(reported_as 'resticprofile-backup@profile-off-site.service')" "off-site backup fail"
check "the external unit reports as external backup" \
  "$(reported_as 'restic-backup-external.service')" "external backup fail"
check "the verify unit reports as verify canary, the key backup-verify.sh uses" \
  "$(reported_as 'restic-verify.service')" "verify canary fail"
check "an unmapped unit reports under its own name" \
  "$(reported_as 'something-else.service')" "unit something-else fail"

check "no unit name: exit 2" \
  "$(RESTIC_NOTIFY_HOOK="$RECORDING_HOOK" "$BASH_BIN" "$REPORTER" >/dev/null 2>&1; printf '%s' "$?")" "2"
: > "$HOOK_RECORD"
RESTIC_NOTIFY_HOOK="$RECORDING_HOOK" "$BASH_BIN" "$REPORTER" >/dev/null 2>&1
check "no unit name: the hook is not called" "$(cat "$HOOK_RECORD")" ""

unreported_output="$(PATH="$STUB_BIN:$PATH" RESTIC_NOTIFY_HOOK="$TMPROOT/no-such-hook" "$BASH_BIN" "$REPORTER" restic-verify.service 2>&1)"
unreported_status=$?
check "hook not executable: exit 1" "$unreported_status" "1"
has   "hook not executable: says UNREPORTED" "$unreported_output" "is UNREPORTED"

check "the reporter exits with the hook's status" \
  "$(PATH="$STUB_BIN:$PATH" HOOK_EXIT_STATUS=3 RESTIC_NOTIFY_HOOK="$RECORDING_HOOK" "$BASH_BIN" "$REPORTER" restic-verify.service >/dev/null 2>&1; printf '%s' "$?")" "3"

# --- 4. the unit files ------------------------------------------------------

echo
echo "=== the unit files agree with the installer and with systemd ==="

REPORTER_UNIT_FILE="$UNIT_SOURCE_DIR/restic-unit-failed@.service"
[[ -r "$REPORTER_UNIT_FILE" ]] || fatal "missing: $REPORTER_UNIT_FILE"

# Print the [Unit] section of a unit file, comments dropped.
unit_section_of() {
  awk '/^\[Unit\]/ { in_unit = 1; next } /^\[/ { in_unit = 0 } in_unit && !/^#/ && NF' "$1"
}

has "restic-verify.service names the reporter" \
  "$(unit_section_of "$UNIT_SOURCE_DIR/restic-verify.service")" "OnFailure=restic-unit-failed@%n.service"
has "restic-backup-external.service names the reporter" \
  "$(unit_section_of "$UNIT_SOURCE_DIR/restic-backup-external.service")" "OnFailure=restic-unit-failed@%n.service"
check "the reporter does not report itself" \
  "$(grep -c '^OnFailure=' "$REPORTER_UNIT_FILE")" "0"

reporter_template_name="${UNIT_FAILURE_ON_FAILURE#OnFailure=}"
reporter_template_name="${reporter_template_name/\%n.service/.service}"
check "the unit the installer's OnFailure= names is the one this repo ships" \
  "$([[ -r "$UNIT_SOURCE_DIR/$reporter_template_name" ]] && printf present || printf absent)" "present"
check "the reporter unit runs the path the installer installs the script to" \
  "$(grep '^ExecStart=' "$REPORTER_UNIT_FILE")" "ExecStart=$UNIT_FAILURE_REPORTER_BIN %i"
check "the installer installs the reporter script" \
  "$(grep -c -F 'scripts/restic-unit-failed.sh" "$UNIT_FAILURE_REPORTER_BIN"' "$SETUP")" "1"

# systemd must accept the reporter under the instance name OnFailure= gives it:
# a full unit name, with its own @ and .service, as the instance. The only
# complaint allowed is that the script is not installed on the machine running this.
#
# Only complaints that NAME this unit are read. `systemd-analyze verify` loads the
# whole unit set and also reports whatever is wrong with the machine's own units:
# on the GitHub runner that is a deprecation warning in system-xfs_scrub.slice,
# which failed the first version of this row and says nothing about this unit.
# A bad key in the unit, or a name systemd rejects, is reported with the unit's
# path or name in it, so those still land here.
verify_dir="$TMPROOT/verify"
mkdir -p "$verify_dir"
cp "$REPORTER_UNIT_FILE" "$verify_dir/"
verify_complaints="$(systemd-analyze verify "$verify_dir/restic-unit-failed@resticprofile-backup@profile-b2.service.service" 2>&1 \
  | grep -F "restic-unit-failed@" \
  | grep -v -F "$UNIT_FAILURE_REPORTER_BIN is not executable")"
check "systemd accepts the reporter unit under a failed unit's full name" "$verify_complaints" ""

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
EXPECTED_ROWS=29
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mROW COUNT\033[0m: expected %d rows, %d ran — a check vanished or was added without updating EXPECTED_ROWS\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 1
fi
[[ "$FAIL" -eq 0 ]]
