#!/usr/bin/env bash
#
# scripts/resource-pulse-service-refresh.sh
# =========================================
#
# ./install's step for the two Resource Pulse services, each linked by
# install.conf.yaml and never enabled: the sampler (systemd/resource-pulse.service,
# which the GNOME Shell extension starts on demand) and the cockpit
# (systemd/cockpit.service, which systemd skips without
# ~/.config/resource-pulse/cockpit.json). It reloads systemd once, then restarts
# each service only when its own code changed after it started.
#
# Why only then: a restart resets the sampler's histories (the top-bar graph
# and the card's), and deploys happen several times a day, most of them leaving
# the data side alone. So each unit is try-restarted only when a module it runs
# has an mtime newer than that unit's ActiveEnterTimestamp: its entry
# (service/main.js for the sampler, service/cockpit.js for the cockpit), and
# every module that imports, directly or not, as
# scripts/resource-pulse-module-closure.sh lists them (ruling R23). A change to
# the drawing side (extension.js, card.js, a lib/ module only the shell
# imports, the stylesheet) never restarts either; the shell picks that up at
# its next login. A module two sides import counts for each of them: a lib/
# module the shell and a service share, or service/fileIo.js, which both
# services run. One only the sampler runs never restarts the cockpit, nor the
# reverse. Each unit's own file (systemd/<unit>) counts too, when it is newer
# than that unit's start: the daemon-reload loads it, but its [Service]
# settings (a cap, the ExecStart) apply only from the next start.
#
# What it does, in order, and what it says; every line names its unit:
#   - no systemctl, or no reachable user manager (a server, a container, CI):
#     nothing, silently, exit 0;
#   - systemctl --user daemon-reload, once, so the linked unit files are the
#     loaded ones;
#   - then, for each unit in SERVICE_UNITS, on its own:
#     - not active (inactive, failed, activating; systemd reports a unit
#       skipped on an unmet condition, as the cockpit is without its layout
#       file, and one not linked yet, as inactive): nothing more for it,
#       silently. A stopped service stays stopped: this step never starts one;
#     - active, no module it runs and not its unit file newer than its start:
#       silent;
#     - active, one newer: `systemctl --user try-restart <unit>`, one ✓ line.
# A failure (the reload, a state or start time it cannot read, modules it
# cannot work out, modules or a unit file it cannot search, the restart) prints
# a ⚠ line on stderr naming the unit, the step and what to run, restarts
# nothing it could not decide about (a partial answer never decides a restart),
# goes on to the next unit (a reload failure stops both, since neither can be
# decided on unloaded files), and still exits 0. It never fails the install:
# under `set -e` an exit 1 here would abort the rest of ./install for every
# desktop user, for a service that at worst keeps running its previous code,
# which is what reconcile-systemd-units.sh decides for its own failures too.
#
# Comparing times: the start time is read in whole seconds (@<epoch>), and
# `find -newermt @<epoch>` keeps files strictly newer than that second's start.
# So a change made after a service started is never missed; one made earlier
# in that same second restarts it once more than needed, which only costs the
# histories once.
#
# Test overrides: RESOURCE_PULSE_EXTENSION_DIR, the extension directory
# (default: this checkout's gnome-shell/extensions/resource-pulse@dotfiles);
# RESOURCE_PULSE_UNIT_FILE, the sampler's unit file (default: this checkout's
# systemd/resource-pulse.service); and RESOURCE_PULSE_COCKPIT_UNIT_FILE, the
# cockpit's (default: this checkout's systemd/cockpit.service). The state table
# is in scripts/test-resource-pulse.sh, against a systemctl stub.
#
# Usage: scripts/resource-pulse-service-refresh.sh

set -uo pipefail

# Each unit this step looks after, with the module it runs, as <unit>:<entry>.
# Only the code a service runs, its entry and what that imports (the closure
# helper below), decides its restart: the drawing side is the shell's, read at
# login.
SERVICE_UNITS=(resource-pulse.service:service/main.js cockpit.service:service/cockpit.js)
SAMPLER_UNIT="resource-pulse.service"
COCKPIT_UNIT="cockpit.service"
ACTIVE_STATE="active"
START_TIME_PATTERN='^@([0-9]+)$'
# Pure bash, no dirname: the script must run with no tool on PATH at all, as in a
# container, where it has nothing to do and must say nothing.
SCRIPT_PATH="${BASH_SOURCE[0]}"
if [[ "$SCRIPT_PATH" == */* ]]; then
  SCRIPT_DIRECTORY="${SCRIPT_PATH%/*}"
else
  SCRIPT_DIRECTORY="."
fi
DEFAULT_EXTENSION_DIR="$SCRIPT_DIRECTORY/../gnome-shell/extensions/resource-pulse@dotfiles"
EXTENSION_DIR="${RESOURCE_PULSE_EXTENSION_DIR:-$DEFAULT_EXTENSION_DIR}"
MODULE_CLOSURE_SCRIPT="$SCRIPT_DIRECTORY/resource-pulse-module-closure.sh"
DEFAULT_UNIT_DIRECTORY="$SCRIPT_DIRECTORY/../systemd"
# The test overrides of a unit's own file; an empty or absent one means the
# checkout's systemd/<unit>.
declare -A UNIT_FILE_OVERRIDES=(
  ["$SAMPLER_UNIT"]="${RESOURCE_PULSE_UNIT_FILE:-}"
  ["$COCKPIT_UNIT"]="${RESOURCE_PULSE_COCKPIT_UNIT_FILE:-}"
)
# What a restart costs, said on its ✓ line: only the sampler keeps histories.
declare -A RESTART_NOTES=(
  ["$SAMPLER_UNIT"]=" (its histories start again)"
)
# How the ✓ line names a changed unit file.
UNIT_FILE_LABEL="its unit file"

# warn <unit or units> <message>: one ⚠ line on stderr.
warn() {
  local warned_about="$1"
  shift
  printf '  ⚠ %s: %s\n' "$warned_about" "$*" >&2
}

# have_user_manager: systemctl exists and a systemd user manager answers it.
have_user_manager() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

# unit_property <unit> <property>: one property of the unit, its value only.
unit_property() {
  systemctl --user show "$1" -p "$2" --value
}

# unit_started_at_epoch <unit>: the unit's ActiveEnterTimestamp in whole seconds
# since the epoch; fails (printing nothing) when it cannot be read as one.
unit_started_at_epoch() {
  local started_at
  started_at="$(systemctl --user show "$1" -p ActiveEnterTimestamp --value --timestamp=unix)" || return 1
  [[ "$started_at" =~ $START_TIME_PATTERN ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# service_module_list <entry module>: the modules a service runs, one per line,
# relative to EXTENSION_DIR: its entry and what that imports, from the closure
# helper (run by this same bash). Fails, with nothing on stdout, when the helper
# cannot say; its reason goes straight to this script's stderr.
service_module_list() {
  "$BASH" "$MODULE_CLOSURE_SCRIPT" "$EXTENSION_DIR" "$1"
}

# first_change_since <epoch> <module list> <unit file>: prints the first of
# those modules, then the unit file, modified after that second began: a module
# relative to EXTENSION_DIR, the unit file as UNIT_FILE_LABEL; or nothing. Fails
# when any of them cannot be searched, whatever it found in the others. find's
# stderr goes straight to this script's stderr, never into the list, so a
# warning from find can never pass for a changed file.
first_change_since() {
  local started_at_epoch="$1" module_list="$2" unit_file="$3" module_path changed_files first_changed_path
  local -a watched_paths=()
  while IFS= read -r module_path; do
    watched_paths+=("$EXTENSION_DIR/$module_path")
  done <<<"$module_list"
  watched_paths+=("$unit_file")
  changed_files="$(find "${watched_paths[@]}" -maxdepth 0 -type f -newermt "@$started_at_epoch")" || return 1
  first_changed_path="${changed_files%%$'\n'*}"
  if [[ "$first_changed_path" == "$unit_file" ]]; then
    printf '%s\n' "$UNIT_FILE_LABEL"
  else
    printf '%s\n' "${first_changed_path#"$EXTENSION_DIR"/}"
  fi
}

# refresh_unit <unit> <entry module>: the decision for one unit, after the
# reload: try-restart it when it is active and a module it runs, or its unit
# file, changed after it started. Every failure warns, naming the unit, and
# returns 0: see the header.
refresh_unit() {
  local unit="$1" entry_module="$2" unit_file="${UNIT_FILE_OVERRIDES[$1]:-$DEFAULT_UNIT_DIRECTORY/$1}"
  local active_state started_at_epoch module_list changed_file
  local manual_restart_hint="if its code changed, run: systemctl --user try-restart $unit"

  if ! active_state="$(unit_property "$unit" ActiveState)"; then
    warn "$unit" "cannot read its state (ActiveState), so it was not checked — run: systemctl --user status $unit"
    return 0
  fi
  # Inactive covers a unit skipped on an unmet condition: it is not running, so
  # it runs no old code, and only its own starter may start it.
  [[ "$active_state" == "$ACTIVE_STATE" ]] || return 0

  if ! started_at_epoch="$(unit_started_at_epoch "$unit")"; then
    warn "$unit" "cannot parse when it started (ActiveEnterTimestamp), so it was not restarted — $manual_restart_hint"
    return 0
  fi
  if ! module_list="$(service_module_list "$entry_module")"; then
    warn "$unit" "cannot work out which modules it runs ($entry_module and what it imports, under $EXTENSION_DIR), so it was not restarted — $manual_restart_hint"
    return 0
  fi
  if ! changed_file="$(first_change_since "$started_at_epoch" "$module_list" "$unit_file")"; then
    warn "$unit" "cannot search the modules it runs under $EXTENSION_DIR, or its unit file $unit_file, so it was not restarted — $manual_restart_hint"
    return 0
  fi
  [[ -n "$changed_file" ]] || return 0

  if ! systemctl --user try-restart "$unit"; then
    warn "$unit" "try-restart failed — journalctl --user -u $unit -e"
    return 0
  fi
  printf '  ✓ %s restarted: %s changed since it started%s\n' "$unit" "$changed_file" "${RESTART_NOTES[$unit]:-}"
}

main() {
  local unit_and_entry all_units=""

  # A server, a container and a CI runner legitimately have none.
  have_user_manager || return 0

  for unit_and_entry in "${SERVICE_UNITS[@]}"; do
    all_units+="${all_units:+, }${unit_and_entry%%:*}"
  done
  # One reload for every unit; when it fails, none can be decided. See the header.
  if ! systemctl --user daemon-reload >/dev/null 2>&1; then
    warn "$all_units" "daemon-reload failed, so they were not checked — run: systemctl --user daemon-reload"
    return 0
  fi

  for unit_and_entry in "${SERVICE_UNITS[@]}"; do
    refresh_unit "${unit_and_entry%%:*}" "${unit_and_entry#*:}"
  done
}

main "$@"
