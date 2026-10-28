#!/usr/bin/env bash
#
# scripts/dock-wifi.sh
# ====================
#
# Keep a docked laptop single-homed: the Wi-Fi radio is OFF while a wired,
# NetworkManager-managed ethernet device is connected, and ON again when none is.
#
# Why this exists
# ---------------
# Docked, this laptop had two uplinks at once: the dock's USB ethernet and the
# home Wi-Fi. A VPN session opened over Wi-Fi before docking kept riding Wi-Fi
# after docking, and every Wi-Fi disassociation or beacon loss (the home SSID
# band-hops between 5 GHz and 2.4 GHz) then became a 20-second gap and a tunnel
# restart through a browser login. Measured over a fortnight: four tunnel drops
# came exactly 20 s after a Wi-Fi disconnect while the wired link was up. With
# one uplink at a time there is nothing to flap. Record: docs/DOCK_WIFI.md.
#
# A PURE FUNCTION OF CURRENT STATE
# --------------------------------
# No markers, no memory. Every call asks NetworkManager what is connected and
# what the radio is, and changes the radio only when the two disagree. That is
# what makes it safe to run from three triggers at once -- every dispatcher
# event, a system oneshot after NetworkManager starts, and the same oneshot
# after resume -- and it is what closes the trap a marker-based design walks
# into: NetworkManager PERSISTS `radio wifi off` across reboots, so a laptop
# shut down docked and booted undocked would come up with Wi-Fi off and no
# "down" event to turn it on. Re-evaluating at boot and at resume turns it on.
#
# Root executes this (the dispatcher runs as root, the oneshot is a system
# unit), so it is COPIED to /usr/local/bin by setup-dock-wifi.sh, never
# symlinked into a user-writable checkout.
#
# Usage:
#   dock-wifi.sh --sync                     converge the radio to the wired state
#   dock-wifi.sh --status                   read-only: the deciding device, the radio, the wanted state
#   dock-wifi.sh --dispatch IFACE ACTION    the NetworkManager dispatcher entry: --sync on the
#                                           actions that can change the answer, a no-op otherwise
#   dock-wifi.sh --help
#
# Exit codes
#   0  converged (or nothing to do), or printed
#   2  COULD NOT RUN -- nmcli missing or failing; the radio is left alone
#
# Seams: DOCK_WIFI_NMCLI (the nmcli to use; the state table points it at a stub)

set -uo pipefail

NMCLI="${DOCK_WIFI_NMCLI:-nmcli}"
# The dispatcher actions after which the answer can have changed. `hostname`,
# `dhcp6-change`, `vpn-up` and the rest cannot connect or disconnect a wired
# device, and a dispatcher that reconverges on every event is noise in the
# journal for nothing.
DISPATCH_ACTIONS=" up down connectivity-change dhcp4-change "

err() { printf 'dock-wifi: %s\n' "$*" >&2; }
log() { printf 'dock-wifi: %s\n' "$*"; }

need_nmcli() {
    command -v "$NMCLI" >/dev/null 2>&1 || { err "nmcli not found ($NMCLI); cannot run"; exit 2; }
}

# The first NetworkManager-managed ethernet device in state `connected`, or
# nothing. `unmanaged` rows (docker's veths, a tethered container bridge) do not
# count: NM is not routing through them. A USB-tethered phone IS an ethernet
# device in state connected, and counts; it is a wired uplink.
wired_connected() {
    local rows
    rows="$("$NMCLI" -t -f DEVICE,TYPE,STATE device 2>/dev/null)" || return 2
    awk -F: '$2 == "ethernet" && $3 == "connected" { print $1; exit }' <<<"$rows"
    return 0
}

radio_wifi() {   # prints on|off
    local state
    state="$("$NMCLI" radio wifi 2>/dev/null)" || return 2
    case "$state" in
        enabled)  printf 'on\n' ;;
        disabled) printf 'off\n' ;;
        *) err "unexpected radio state '$state'"; return 2 ;;
    esac
}

mode_sync() {
    local dev wanted have
    need_nmcli
    dev="$(wired_connected)" || { err "nmcli device failed; touching nothing"; exit 2; }
    if [[ -n "$dev" ]]; then wanted="off"; else wanted="on"; fi
    have="$(radio_wifi)" || { err "nmcli radio failed; touching nothing"; exit 2; }
    if [[ "$have" == "$wanted" ]]; then
        log "wifi already ${wanted} (wired: ${dev:-none})"
        return 0
    fi
    "$NMCLI" radio wifi "$wanted" >/dev/null 2>&1 || { err "nmcli radio wifi ${wanted} failed"; exit 2; }
    log "wifi ${wanted} (wired: ${dev:-none})"
    return 0
}

mode_status() {
    local dev have
    need_nmcli
    dev="$(wired_connected)" || { err "nmcli device failed"; exit 2; }
    have="$(radio_wifi)" || { err "nmcli radio failed"; exit 2; }
    printf 'wired:  %s\n' "${dev:-none}"
    printf 'wifi:   %s\n' "$have"
    if [[ -n "$dev" ]]; then printf 'wanted: off\n'; else printf 'wanted: on\n'; fi
    return 0
}

mode_dispatch() {   # <iface> <action>: the interface is NetworkManager's first argument, unused here
    local action="${2:-}"
    [[ "$DISPATCH_ACTIONS" == *" ${action} "* ]] || return 0
    mode_sync
}

usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

main() {
    case "${1:-}" in
        --sync)     mode_sync; exit $? ;;
        --status)   mode_status; exit $? ;;
        --dispatch) mode_dispatch "${2:-}" "${3:-}"; exit $? ;;
        --help|-h)  usage; exit 0 ;;
        *)          err "unknown mode: ${1:-<none>}"; usage >&2; exit 2 ;;
    esac
}

main "$@"
