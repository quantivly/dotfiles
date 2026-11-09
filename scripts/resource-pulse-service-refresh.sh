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
# the data side alone. So the unit is try-restarted only when a file under the
# extension's service/ or lib/ (the only code the service runs) has an mtime
# newer than the unit's ActiveEnterTimestamp. A change to the drawing side
# (extension.js, card.js, the stylesheet) never restarts it; the shell picks
# that up at its next login.
#
# What it does, in order, and what it says:
#   - no systemctl, or no reachable user manager (a server, a container, CI):
#     nothing, silently, exit 0;
#   - systemctl --user daemon-reload, so the linked unit file is the loaded one;
#   - the unit not active (inactive, failed, activating, or not linked yet,
#     which systemd reports as inactive):
#     nothing more, silently, exit 0. A stopped service stays stopped: only the
#     extension starts it;
#   - active, nothing under service/ or lib/ newer than its start: silent, exit 0;
#   - active, something newer: `systemctl --user try-restart`, one ✓ line.
# A failure (the reload, a state or start time it cannot read, a directory it
# cannot search, the restart) prints a ⚠ line on stderr naming the step and what
# to run, restarts nothing it could not decide about (a partial answer never
# decides a restart), and still exits 0. It never fails the install: under
# `set -e` an exit 1 here would abort the rest of ./install for every desktop
# user, for a service that at worst keeps running its previous code, which is
# what reconcile-systemd-units.sh decides for its own failures too.
#
# Comparing times: the start time is read in whole seconds (@<epoch>), and
# `find -newermt @<epoch>` keeps files strictly newer than that second's start.
# So a change made after the service started is never missed; one made earlier
# in that same second restarts it once more than needed, which only costs the
# histories once.
#
# Test override: RESOURCE_PULSE_EXTENSION_DIR, the extension directory (default:
# this checkout's gnome-shell/extensions/resource-pulse@dotfiles). The state
# table is in scripts/test-resource-pulse.sh, against a systemctl stub.
#
# Usage: scripts/resource-pulse-service-refresh.sh

set -uo pipefail

SERVICE_UNIT="resource-pulse.service"
# Only the code the service runs: the drawing side is the shell's, read at login.
WATCHED_SUBDIRECTORIES=(service lib)
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

# first_file_changed_since <epoch>: prints the first file under the watched
# subdirectories modified after that second began, or nothing; fails when any
# of them cannot be searched, whatever it found in the others. find's stderr
# goes straight to this script's stderr, never into the list, so a warning
# from find can never pass for a changed file.
first_file_changed_since() {
  local started_at_epoch="$1" watched_paths=() subdirectory changed_files
  for subdirectory in "${WATCHED_SUBDIRECTORIES[@]}"; do
    watched_paths+=("$EXTENSION_DIR/$subdirectory")
  done
  changed_files="$(find "${watched_paths[@]}" -type f -newermt "@$started_at_epoch")" || return 1
  printf '%s\n' "${changed_files%%$'\n'*}"
}

main() {
  local active_state started_at_epoch changed_file
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
  if ! changed_file="$(first_file_changed_since "$started_at_epoch")"; then
    warn "cannot search $EXTENSION_DIR's ${WATCHED_SUBDIRECTORIES[*]}, so it was not restarted — $manual_restart_hint"
    return 0
  fi
  [[ -n "$changed_file" ]] || return 0

  if ! systemctl --user try-restart "$SERVICE_UNIT"; then
    warn "try-restart failed — journalctl --user -u $SERVICE_UNIT -e"
    return 0
  fi
  printf '  ✓ %s restarted: %s changed since it started (its histories start again)\n' \
    "$SERVICE_UNIT" "${changed_file#"$EXTENSION_DIR"/}"
}

main "$@"
