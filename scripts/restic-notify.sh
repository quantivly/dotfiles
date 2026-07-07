#!/usr/bin/env bash
#
# scripts/restic-notify.sh
# ========================
#
# resticprofile run-after / run-after-fail hook (runs as ROOT). Does two things,
# both best-effort and non-fatal (a failed notification must never fail a backup):
#
#   1. Pings the healthchecks.io dead-man's-switch so you are ALERTED when a
#      backup is overdue (laptop asleep / undocked / offline for weeks).
#   2. Sends a desktop notify-send into the logged-in user's GUI session
#      (a root service has no DBus session of its own, so we bridge into it).
#      FAILURES notify on state change (when BACKUP_NOTIFY=1) with a daily
#      reminder while stuck, plus one "recovered" popup when a failing target
#      succeeds again (state in /var/lib/restic-notify). SUCCESS is otherwise
#      silent unless BACKUP_NOTIFY_SUCCESS=1 — "no news is good news", and the
#      healthcheck ping (which fires EVERY run, undeduped) already confirms
#      success externally.
#
# The target is taken from $PROFILE_NAME (set by resticprofile: "b2"/"external"),
# which selects the matching BACKUP_HC_URL_* from /etc/restic/backup.local.
#
# Usage (invoked by resticprofile):
#   restic-notify success
#   restic-notify fail

set -uo pipefail

STATUS="${1:-success}"
PROFILE="${PROFILE_NAME:-backup}"     # resticprofile exports PROFILE_NAME to hooks
COMMAND="${PROFILE_COMMAND:-backup}"  # …and PROFILE_COMMAND (backup/check/…); used in the message

# Load config if not already in the environment (manual runs / safety).
# shellcheck source=/dev/null
[[ -r /etc/restic/backup.local ]] && { set -a; . /etc/restic/backup.local; set +a; } 2>/dev/null

# --- 1. healthchecks.io ping ------------------------------------------------
hc_url=""
case "$PROFILE" in
  b2)       hc_url="${BACKUP_HC_URL_B2:-}" ;;
  external) hc_url="${BACKUP_HC_URL_EXTERNAL:-}" ;;
  verify)   hc_url="${BACKUP_HC_URL_VERIFY:-}" ;;   # backup-verify.sh dead-man's switch
esac
if [[ -n "$hc_url" ]] && command -v curl >/dev/null 2>&1; then
  [[ "$STATUS" == "fail" ]] && hc_url="${hc_url%/}/fail"
  curl -fsS -m 15 --retry 3 -o /dev/null "$hc_url" || true
fi

# --- 2. desktop notification (failures always; success only if opted in) ----
# Dedup: a STUCK failure (e.g. B2 storage cap) repeats every scheduled run —
# dozens of identical criticals train you to ignore the one that matters. Track
# state per profile+command and notify on state CHANGE: first failure, then a
# daily reminder while still failing, then one "recovered" popup on the next
# success. The healthchecks ping above is deliberately untouched — it must fire
# every run (healthchecks.io keeps its own state and dedups its own emails).
# All state I/O is best-effort (|| true): a notify bug must never fail a backup.
STATE_DIR="/var/lib/restic-notify"
STATE_FILE="${STATE_DIR}/${PROFILE}-${COMMAND}.state"
prev_status="" prev_notified=0
[[ -r "$STATE_FILE" ]] && { read -r prev_status prev_notified <"$STATE_FILE"; } 2>/dev/null
[[ "$prev_notified" =~ ^[0-9]+$ ]] || prev_notified=0
now="$(date +%s)"

notify_wanted=0
recovered=0
if [[ "$STATUS" == "fail" ]]; then
  if [[ "${BACKUP_NOTIFY:-1}" == "1" ]] \
     && { [[ "$prev_status" != "fail" ]] || (( now - prev_notified > 86400 )); }; then
    notify_wanted=1
  fi
else
  if [[ "$prev_status" == "fail" && "${BACKUP_NOTIFY:-1}" == "1" ]]; then
    # One-time recovery popup regardless of BACKUP_NOTIFY_SUCCESS — it closes the
    # loop on an alert you were shown, unlike a routine success notification.
    recovered=1; notify_wanted=1
  elif [[ "${BACKUP_NOTIFY_SUCCESS:-0}" == "1" ]]; then
    notify_wanted=1
  fi
fi

# Record the new state. When suppressing a repeat failure, keep the previous
# last-notified epoch so the daily reminder counts from the last popup shown.
{
  mkdir -p "$STATE_DIR"
  if [[ "$STATUS" == "fail" ]]; then
    if [[ "$notify_wanted" == "1" ]]; then
      printf 'fail %s\n' "$now" >"$STATE_FILE"
    else
      printf 'fail %s\n' "$prev_notified" >"$STATE_FILE"
    fi
  else
    printf 'success %s\n' "$now" >"$STATE_FILE"
  fi
} 2>/dev/null || true

if [[ "$notify_wanted" == "1" ]] && command -v notify-send >/dev/null 2>&1; then
  # No last-resort literal: an empty user makes `id -u ""` fail below, and the
  # -n guard then skips the notification (nobody to notify anyway).
  user="${NOTIFY_USER:-$(id -un 1000 2>/dev/null || true)}"
  uid="$(id -u "$user" 2>/dev/null || echo)"
  if [[ -n "$uid" && -S "/run/user/$uid/bus" ]]; then
    if [[ "$STATUS" == "fail" ]]; then
      urgency="critical"; icon="dialog-error"; title="restic $PROFILE $COMMAND FAILED"
      body="restic $PROFILE $COMMAND failed on $(hostname) — check the journal / resticprofile logs."
    elif [[ "$recovered" == "1" ]]; then
      urgency="normal"; icon="emblem-default"; title="restic $PROFILE $COMMAND recovered"
      body="restic $PROFILE $COMMAND is succeeding again on $(hostname)."
    else
      urgency="low"; icon="emblem-default"; title="restic $PROFILE $COMMAND complete"
      body="restic $PROFILE $COMMAND finished on $(hostname)."
    fi
    sudo -u "$user" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      notify-send -a "restic" -u "$urgency" -i "$icon" "$title" "$body" 2>/dev/null || true
  fi
fi

exit 0
