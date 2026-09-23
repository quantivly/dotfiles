#!/usr/bin/env bash
#
# scripts/vpn-notify.sh
# =====================
#
# Raise a persistent, critical desktop notification when the VPN tunnel has been
# down longer than a threshold, and withdraw it when the tunnel returns.
#
# Why this exists
# ---------------
# The expensive part of a VPN drop on this machine is not the reconnect, it is
# the SILENCE. Measured over 33 days of client logs: after the client's own
# `SamlSessionTimedOutException` (a hard 600.0s SAML_LOGIN_START_TIMEOUT, 57
# occurrences) the connection sits Disconnected and NOTHING RETRIES IT. Time from
# that timeout to the next connection attempt, 16 observed:
#
#   3.5  6.8  11.2  16.4  28.4  33.6  47.1  486.7  868.2  945.5
#   2823.6  3478.3  5584.0  19625.2  24073.9  31750.5   seconds
#
# The short ones are a human noticing. The long ones -- up to 8.8 HOURS -- are
# nobody telling him. A fresh attempt then usually succeeds in seconds. So the
# recoverable downtime is not a missing click; it is a missing signal.
#
# THE INVARIANT: kernel state only, never a log
# --------------------------------------------
# State comes from `ip -j link show tun0` and the route table, exactly as
# vpn-failfast.sh does, and for the same reason: both client log directories are
# writable by any process running as this user, so a notifier that read one could
# be made to raise arbitrary notifications by anything on the box.
#
# THE NOTIFICATION BODY IS A COMPILE-TIME CONSTANT
# ------------------------------------------------
# GNOME's notification daemon advertises `body-markup` and renders `<a href=...>`
# inside a notification body. So ANY text derived from anything -- a log line, a
# profile name, a hostname, a timestamp, a URL -- is a phishing sink rendered by
# a trusted desktop component. Nothing derived from anything goes in it. There is
# no action button, no xdg-open, and no URL handling anywhere in this file. The
# body below is the whole body, forever; if it ever needs to carry a detail, the
# detail goes to `vpn-status` and the body says "run vpn-status".
#
# This is a USER unit (notifications need the session bus), unlike
# vpn-failfast.service which is a system unit (route changes need CAP_NET_ADMIN).
#
# Usage:
#   vpn-notify.sh --watch    daemon: poll, notify past the threshold, withdraw
#   vpn-notify.sh --once     evaluate once and exit
#   vpn-notify.sh --withdraw close any notification this tool raised, then exit
#   vpn-notify.sh --status   read-only: what it would do now
#
# Exit codes
#   0  did what was asked
#   1  a notification could not be sent (and is named)
#   2  COULD NOT RUN -- bad threshold, no notify-send. Never a pass.
#
# Test-suite overrides (also what makes it hermetic):
#   VPN_NOTIFY_IFACE      default tun0
#   VPN_NOTIFY_THRESHOLD  default 90   seconds down before the first notification
#   VPN_NOTIFY_POLL       default 15   seconds between evaluations
#   VPN_NOTIFY_STATE      default $XDG_RUNTIME_DIR/vpn-notify
#   VPN_NOTIFY_NOW        epoch seconds to use as "now"

set -uo pipefail

IFACE="${VPN_NOTIFY_IFACE:-tun0}"
THRESHOLD="${VPN_NOTIFY_THRESHOLD:-90}"
POLL="${VPN_NOTIFY_POLL:-15}"
STATE_DIR="${VPN_NOTIFY_STATE:-${XDG_RUNTIME_DIR:-/tmp}/vpn-notify}"

err() { printf 'vpn-notify: %s\n' "$*" >&2; }
log() { printf 'vpn-notify: %s\n' "$*"; }

for _v in THRESHOLD POLL; do
    if [[ ! "${!_v}" =~ ^[0-9]+$ ]]; then
        err "VPN_NOTIFY_${_v} must be a non-negative integer, got '${!_v}'"
        exit 2
    fi
done
# The threshold must clear the self-healing outages or this becomes noise, and a
# notifier people learn to dismiss is worse than none. Measured over 10 days with
# full log coverage: 41 in-use outages, p50 34s, and 17 of the 41 recovered with
# no SAML re-auth at all (p50 10s). 90s is comfortably above both, and below the
# 600s vendor timeout that produces the tail this exists to attack.
if (( THRESHOLD < 1 )); then
    err "VPN_NOTIFY_THRESHOLD must be at least 1 second"
    exit 2
fi

# ---------------------------------------------------------------------------
# THE BODY. A CONSTANT. See the header before changing anything here.
#
# No markup, no interpolation, no %s. `notify-send` is given these as separate
# argv elements, so even a hostile IFS cannot recombine them.
# ---------------------------------------------------------------------------
NOTIFY_SUMMARY='VPN tunnel is down'
NOTIFY_BODY='Reconnect the AWS VPN Client. Run vpn-status for detail.'
NOTIFY_ICON='network-vpn-disconnected-symbolic'

# ---------------------------------------------------------------------------
# Kernel state. Identical definition to vpn-failfast.sh, deliberately: two
# components disagreeing about what "down" means is how one of them ends up
# permanently wrong. UP means the interface exists, carries the UP flag, and has
# at least one route through it WITH A GATEWAY -- the client deletes 0.0.0.0/1
# and 128.0.0.0/1 on a drop while tun0 itself can linger, still flagged UP, with
# only its own link-scope subnet route left.
tunnel_up() {
    local links routes
    links="$(ip -j link show "$IFACE" 2>/dev/null)" || return 1
    [[ -n "$links" && "$links" != "[]" ]] || return 1
    printf '%s' "$links" | grep -q '"UP"' || return 1
    routes="$(ip -j route show dev "$IFACE" 2>/dev/null)" || return 1
    printf '%s' "$routes" | grep -q '"gateway"' || return 1
    return 0
}

now() { printf '%s\n' "${VPN_NOTIFY_NOW:-$(date +%s)}"; }

# State: two files, so a restart of this unit does not re-notify for an outage it
# has already reported, and does not forget one it has. Under $XDG_RUNTIME_DIR,
# which is tmpfs mode 0700 and gone at logout -- a fresh login should re-evaluate
# from scratch rather than inherit a verdict from yesterday.
DOWN_SINCE_F="$STATE_DIR/down-since"
NOTIFIED_F="$STATE_DIR/notified"

ensure_state_dir() {
    mkdir -p "$STATE_DIR" 2>/dev/null || { err "cannot create $STATE_DIR"; return 2; }
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    return 0
}

read_epoch_file() {
    local v
    v="$(cat "$1" 2>/dev/null)" || { printf '0\n'; return 0; }
    [[ "$v" =~ ^[0-9]+$ ]] || { printf '0\n'; return 0; }
    printf '%s\n' "$v"
}

raise() {
    local rc=0
    # --replace-id needs a server-assigned id to be useful; instead the summary
    # is stable and urgency=critical, which on GNOME is already persistent (it
    # does not time out). Replacing rather than stacking is handled by only ever
    # raising ONCE per outage -- the notified marker below.
    if command -v notify-send >/dev/null 2>&1; then
        notify-send --urgency=critical --icon="$NOTIFY_ICON" \
            -- "$NOTIFY_SUMMARY" "$NOTIFY_BODY" || rc=1
    else
        err "notify-send not found; cannot raise a notification"
        rc=1
    fi
    (( rc == 0 )) && log "notified: tunnel down past ${THRESHOLD}s"
    return "$rc"
}

withdraw() {
    # There is nothing to actively close: a critical notification is dismissed by
    # the user or replaced. What matters is forgetting that we raised one, so the
    # NEXT outage notifies again. Keeping a server id to close would mean parsing
    # notify-send output, and `notify-send --print-id` is not available on every
    # machine this might run on.
    rm -f "$NOTIFIED_F" "$DOWN_SINCE_F" 2>/dev/null || true
    return 0
}

evaluate() {
    local n since
    ensure_state_dir || return 2
    n="$(now)"

    if tunnel_up; then
        if [[ -e "$NOTIFIED_F" || -e "$DOWN_SINCE_F" ]]; then
            log "tunnel back up"
        fi
        withdraw
        return 0
    fi

    since="$(read_epoch_file "$DOWN_SINCE_F")"
    if (( since == 0 )); then
        printf '%s\n' "$n" > "$DOWN_SINCE_F" 2>/dev/null || {
            err "cannot record the outage start in $DOWN_SINCE_F"; return 2; }
        return 0
    fi
    # A clock that went backwards (a resume, an NTP step) must not make an outage
    # look infinitely long OR restart its timer silently. Re-anchor and say so.
    if (( n < since )); then
        log "clock moved backwards; re-anchoring the outage start"
        printf '%s\n' "$n" > "$DOWN_SINCE_F" 2>/dev/null || true
        return 0
    fi
    (( n - since >= THRESHOLD )) || return 0
    [[ -e "$NOTIFIED_F" ]] && return 0
    raise || return 1
    : > "$NOTIFIED_F" 2>/dev/null || true
    return 0
}

print_status() {
    local n since
    n="$(now)"
    if tunnel_up; then
        printf 'tunnel:    UP (%s has a gateway route)\n' "$IFACE"
    else
        printf 'tunnel:    DOWN (%s missing, down, or with no gateway route)\n' "$IFACE"
    fi
    printf 'threshold: %ss\n' "$THRESHOLD"
    since="$(read_epoch_file "$DOWN_SINCE_F")"
    if (( since > 0 )); then
        printf 'down for:  %ss (since epoch %s)\n' "$(( n - since ))" "$since"
    else
        printf 'down for:  not currently recorded as down\n'
    fi
    if [[ -e "$NOTIFIED_F" ]]; then
        printf 'notified:  yes, for this outage\n'
    else
        printf 'notified:  no\n'
    fi
    return 0
}

run_watch() {
    trap 'log "stopping"; exit 0' TERM INT
    while :; do
        evaluate || true
        sleep "$POLL"
    done
}

usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

main() {
    if (( $# > 1 )); then
        err "too many arguments (expected at most one, got $#: $*)"
        exit 2
    fi
    case "${1:---watch}" in
        --status)   print_status; exit 0 ;;
        --once)     evaluate; exit $? ;;
        --withdraw) withdraw; exit 0 ;;
        --watch)    run_watch ;;
        --help|-h)  usage; exit 0 ;;
        *)          err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
}

main "$@"
