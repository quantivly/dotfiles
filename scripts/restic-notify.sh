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
#      FAILURES always notify (when BACKUP_NOTIFY=1); SUCCESS is silent unless
#      BACKUP_NOTIFY_SUCCESS=1 — "no news is good news", and the healthcheck
#      ping already confirms success externally.
#
# The target is taken from $PROFILE_NAME (set by resticprofile: "b2"/"external"),
# which selects the matching BACKUP_HC_URL_* from /etc/restic/backup.local.
#
# Usage (invoked by resticprofile):
#   restic-notify success
#   restic-notify fail

set -uo pipefail

STATUS="${1:-success}"
PROFILE="${PROFILE_NAME:-backup}"   # resticprofile exports PROFILE_NAME to hooks

# Load config if not already in the environment (manual runs / safety).
# shellcheck source=/dev/null
[[ -r /etc/restic/backup.local ]] && { set -a; . /etc/restic/backup.local; set +a; } 2>/dev/null

# --- 1. healthchecks.io ping ------------------------------------------------
hc_url=""
case "$PROFILE" in
  b2)       hc_url="${BACKUP_HC_URL_B2:-}" ;;
  external) hc_url="${BACKUP_HC_URL_EXTERNAL:-}" ;;
esac
if [[ -n "$hc_url" ]] && command -v curl >/dev/null 2>&1; then
  [[ "$STATUS" == "fail" ]] && hc_url="${hc_url%/}/fail"
  curl -fsS -m 15 --retry 3 -o /dev/null "$hc_url" || true
fi

# --- 2. desktop notification (failures always; success only if opted in) ----
notify_wanted=0
if [[ "$STATUS" == "fail" ]]; then
  [[ "${BACKUP_NOTIFY:-1}" == "1" ]] && notify_wanted=1
else
  [[ "${BACKUP_NOTIFY_SUCCESS:-0}" == "1" ]] && notify_wanted=1
fi
if [[ "$notify_wanted" == "1" ]] && command -v notify-send >/dev/null 2>&1; then
  user="${NOTIFY_USER:-$(id -un 1000 2>/dev/null || echo zvi)}"
  uid="$(id -u "$user" 2>/dev/null || echo)"
  if [[ -n "$uid" && -S "/run/user/$uid/bus" ]]; then
    if [[ "$STATUS" == "fail" ]]; then
      urgency="critical"; icon="dialog-error"; title="Backup FAILED ($PROFILE)"
      body="restic $PROFILE backup failed on $(hostname) — check the journal / resticprofile logs."
    else
      urgency="low"; icon="emblem-default"; title="Backup complete ($PROFILE)"
      body="restic $PROFILE snapshot finished on $(hostname)."
    fi
    sudo -u "$user" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      notify-send -a "restic" -u "$urgency" -i "$icon" "$title" "$body" 2>/dev/null || true
  fi
fi

exit 0
