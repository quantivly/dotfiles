#!/usr/bin/env bash
#
# scripts/resource-pulse-service-refresh.sh
# =========================================
#
# ./install's step for the Resource Pulse sampler service
# (systemd/resource-pulse.service, linked by install.conf.yaml, never enabled:
# the GNOME Shell extension starts it on demand). It reloads systemd, then
# restarts the service only when its code changed after it started.
#
# Why only then: a restart resets the service's histories (the top-bar graph
# and the card's), and deploys happen several times a day, most of them leaving
# the data side alone. So the unit is try-restarted only when a module the
# service runs has an mtime newer than the unit's ActiveEnterTimestamp: its
# entry, service/main.js, and every module that imports, directly or not, as
# scripts/resource-pulse-module-closure.sh lists them (ruling R23). A change to
# the drawing side (extension.js, card.js, a lib/ module only the shell
# imports, the stylesheet) never restarts it; the shell picks that up at its
# next login. A lib/ module both sides import counts for both. So does the unit
# file itself (systemd/resource-pulse.service) when it is newer than the start:
# the daemon-reload loads it, but its [Service] settings (a cap, the ExecStart)
# apply only from the next start.
#
# What it does, in order, and what it says:
#   - no systemctl, or no reachable user manager (a server, a container, CI):
#     nothing, silently, exit 0;
#   - systemctl --user daemon-reload, so the linked unit file is the loaded one;
#   - the unit not active (inactive, failed, activating, or not linked yet,
#     which systemd reports as inactive):
#     nothing more, silently, exit 0. A stopped service stays stopped: only the
#     extension starts it;
#   - active, no module it runs and not its unit file newer than its start:
#     silent, exit 0;
#   - active, one newer: `systemctl --user try-restart`, one ✓ line.
# A failure (the reload, a state or start time it cannot read, modules it
# cannot work out, modules or a unit file it cannot search, the restart) prints
# a ⚠ line on stderr naming the step and what to run, restarts nothing it could
# not decide about (a partial answer never decides a restart), and still exits
# 0. It never fails the install: under `set -e` an exit 1 here would abort the
# rest of ./install for every desktop user, for a service that at worst keeps
# running its previous code, which is what reconcile-systemd-units.sh decides
# for its own failures too.
#
# Comparing times: the start time is read in whole seconds (@<epoch>), and
# `find -newermt @<epoch>` keeps files strictly newer than that second's start.
# So a change made after the service started is never missed; one made earlier
# in that same second restarts it once more than needed, which only costs the
# histories once.
#
# Test overrides: RESOURCE_PULSE_EXTENSION_DIR, the extension directory
# (default: this checkout's gnome-shell/extensions/resource-pulse@dotfiles), and
# RESOURCE_PULSE_UNIT_FILE, the unit file (default: this checkout's
# systemd/resource-pulse.service). The state table is in
# scripts/test-resource-pulse.sh, against a systemctl stub.
#
# Usage: scripts/resource-pulse-service-refresh.sh

set -uo pipefail

SERVICE_UNIT="resource-pulse.service"
# Only the code the service runs, this module and what it imports (the closure
# helper below): the drawing side is the shell's, read at login.
SERVICE_ENTRY_MODULE="service/main.js"
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
DEFAULT_UNIT_FILE="$SCRIPT_DIRECTORY/../systemd/$SERVICE_UNIT"
UNIT_FILE="${RESOURCE_PULSE_UNIT_FILE:-$DEFAULT_UNIT_FILE}"
# How the ✓ line names a changed unit file.
UNIT_FILE_LABEL="its unit file"

# warn <message>: one ⚠ line on stderr.
warn() { printf '  ⚠ %s: %s\n' "$SERVICE_UNIT" "$*" >&2; }

# have_user_manager: systemctl exists and a systemd user manager answers it.
have_user_manager() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

# unit_property <property>: one property of the unit, its value only.
unit_property() {
  systemctl --user show "$SERVICE_UNIT" -p "$1" --value
}

# unit_started_at_epoch: the unit's ActiveEnterTimestamp in whole seconds since
# the epoch; fails (printing nothing) when it cannot be read as one.
unit_started_at_epoch() {
  local started_at
  started_at="$(systemctl --user show "$SERVICE_UNIT" -p ActiveEnterTimestamp --value --timestamp=unix)" || return 1
  [[ "$started_at" =~ $START_TIME_PATTERN ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# service_module_list: the modules the service runs, one per line, relative to
# EXTENSION_DIR: service/main.js and what it imports, from the closure helper
# (run by this same bash). Fails, with nothing on stdout, when the helper cannot
# say; its reason goes straight to this script's stderr.
service_module_list() {
  "$BASH" "$MODULE_CLOSURE_SCRIPT" "$EXTENSION_DIR" "$SERVICE_ENTRY_MODULE"
}

# first_change_since <epoch> <module list>: prints the first of those modules,
# then the unit file, modified after that second began: a module relative to
# EXTENSION_DIR, the unit file as UNIT_FILE_LABEL; or nothing. Fails when any of
# them cannot be searched, whatever it found in the others. find's stderr goes
# straight to this script's stderr, never into the list, so a warning from find
# can never pass for a changed file.
first_change_since() {
  local started_at_epoch="$1" module_list="$2" module_path changed_files first_changed_path
  local -a watched_paths=()
  while IFS= read -r module_path; do
    watched_paths+=("$EXTENSION_DIR/$module_path")
  done <<<"$module_list"
  watched_paths+=("$UNIT_FILE")
  changed_files="$(find "${watched_paths[@]}" -maxdepth 0 -type f -newermt "@$started_at_epoch")" || return 1
  first_changed_path="${changed_files%%$'\n'*}"
  if [[ "$first_changed_path" == "$UNIT_FILE" ]]; then
    printf '%s\n' "$UNIT_FILE_LABEL"
  else
    printf '%s\n' "${first_changed_path#"$EXTENSION_DIR"/}"
  fi
}

main() {
  local active_state started_at_epoch module_list changed_file
  local manual_restart_hint="if its code changed, run: systemctl --user try-restart $SERVICE_UNIT"

  # A server, a container and a CI runner legitimately have none.
  have_user_manager || return 0

  # Every failure below warns and returns 0: see the header.
  if ! systemctl --user daemon-reload >/dev/null 2>&1; then
    warn "daemon-reload failed, so the service was not checked — run: systemctl --user daemon-reload"
    return 0
  fi

  if ! active_state="$(unit_property ActiveState)"; then
    warn "cannot read its state (ActiveState), so it was not checked — run: systemctl --user status $SERVICE_UNIT"
    return 0
  fi
  [[ "$active_state" == "$ACTIVE_STATE" ]] || return 0

  if ! started_at_epoch="$(unit_started_at_epoch)"; then
    warn "cannot parse when it started (ActiveEnterTimestamp), so it was not restarted — $manual_restart_hint"
    return 0
  fi
  if ! module_list="$(service_module_list)"; then
    warn "cannot work out which modules it runs ($SERVICE_ENTRY_MODULE and what it imports, under $EXTENSION_DIR), so it was not restarted — $manual_restart_hint"
    return 0
  fi
  if ! changed_file="$(first_change_since "$started_at_epoch" "$module_list")"; then
    warn "cannot search the modules it runs under $EXTENSION_DIR, or its unit file $UNIT_FILE, so it was not restarted — $manual_restart_hint"
    return 0
  fi
  [[ -n "$changed_file" ]] || return 0

  if ! systemctl --user try-restart "$SERVICE_UNIT"; then
    warn "try-restart failed — journalctl --user -u $SERVICE_UNIT -e"
    return 0
  fi
  printf '  ✓ %s restarted: %s changed since it started (its histories start again)\n' \
    "$SERVICE_UNIT" "$changed_file"
}

main "$@"
