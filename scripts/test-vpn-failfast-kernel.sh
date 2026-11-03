#!/usr/bin/env bash
#
# scripts/test-vpn-failfast-kernel.sh
# ===================================
#
# The REAL-KERNEL half of the vpn-failfast state table. scripts/test-vpn-failfast.sh
# runs every row against a recording `ip` stub, which proves the daemon says what
# its author believed the kernel does -- and nothing about the kernel. This file
# runs the real daemon against a real routing table, in an EMPTY network
# namespace, and asks the kernel the questions that matter:
#
#   * while the tunnel is down, a configured destination FAILS at once
#     (ENETUNREACH), while everything else still leaves via the LAN;
#   * while it is up, the destination goes through the tunnel;
#   * across the transition the daemon emits NO route event for any configured
#     destination. That is the property that keeps AWS VPN Client 5.x alive: its
#     route listener crashed on the reject routes the old design toggled
#     (docs/VPN_INTERNALS.md §11).
#
# HOW, and why this shape. `unshare -rn` is blocked on this box, so the namespace
# comes from `docker run --network none --cap-add NET_ADMIN`. The container then
# CHROOTS INTO THE HOST'S READ-ONLY ROOT and runs this same file there, so the
# bash, awk and iproute2 under test are the host's -- never an image's: the local
# images ship BusyBox `ip`, whose error strings differ from iproute2's, and a
# measurement taken with it reads exactly like confirmation. --network none is an
# empty netns (only `lo`), so the host's routing table is never touched.
#
# "Could not run" is exit 2, never a pass. The file asserts its own row total.
#
# Usage: scripts/test-vpn-failfast-kernel.sh            (needs docker)
#        scripts/test-vpn-failfast-kernel.sh --inside   (what the container runs)

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FAILFAST="$DOTFILES/scripts/vpn-failfast.sh"
CONF="$DOTFILES/tests/fixtures/vpn/kernel-failfast.conf"
# Only for its `chroot` binary: everything that runs is the host's.
NAMESPACE_IMAGE="${VPN_KERNEL_TEST_IMAGE:-debian:12}"
EXPECTED_ROWS=16

readonly HOST_DESTINATION=203.0.113.10
readonly PREFIX_DESTINATION_PROBE=198.51.100.7     # inside 198.51.100.0/24
readonly UNRELATED_DESTINATION=1.1.1.1
readonly LAN_ADDRESS=10.0.0.53/24
readonly LAN_GATEWAY=10.0.0.138
readonly TUNNEL_ADDRESS=172.31.80.35/27
readonly TUNNEL_GATEWAY=172.31.80.33

fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 2; }

if [[ "${1:-}" != "--inside" ]]; then
    command -v docker >/dev/null 2>&1 || fatal "docker is required for the real-kernel rows"
    docker info >/dev/null 2>&1 || fatal "docker is installed but not usable by this user"
    exec docker run --rm --network none --cap-add NET_ADMIN -v /:/hostfs:ro \
        --entrypoint chroot "$NAMESPACE_IMAGE" /hostfs /usr/bin/env bash \
        "$DOTFILES/scripts/test-vpn-failfast-kernel.sh" --inside
fi

# --- inside the namespace, on the host's binaries --------------------------
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — '$2' does not contain '$3'"; fi; }

# A namespace that already has routes is not the empty one this file assumes,
# and every row below would then be measuring somebody else's table.
[[ "$(ip -4 route show | wc -l)" == "0" ]] || fatal "the namespace is not empty; refusing to run"

ff() { VPN_FAILFAST_CONF="$CONF" "$FAILFAST" "$@" >/dev/null 2>&1; }
route_get() { ip -4 route get "$1" 2>&1; }
tunnel_up()   { ip route add 0.0.0.0/1 via "$TUNNEL_GATEWAY" dev tun0
                ip route add 128.0.0.0/1 via "$TUNNEL_GATEWAY" dev tun0; }
tunnel_down() { ip route del 0.0.0.0/1 via "$TUNNEL_GATEWAY" dev tun0
                ip route del 128.0.0.0/1 via "$TUNNEL_GATEWAY" dev tun0; }
connect_errno() {
    python3 -I -c '
import errno, socket, sys
probe = socket.socket()
probe.settimeout(3)
try:
    probe.connect((sys.argv[1], 22))
    print("connected")
except OSError as failure:
    print(errno.errorcode.get(failure.errno, failure.errno))' "$1"
}

build_fixture() {
    ip link add lan type dummy && ip addr add "$LAN_ADDRESS" dev lan && ip link set lan up \
        && ip route add default via "$LAN_GATEWAY" dev lan \
        && ip link add tun0 type dummy && ip addr add "$TUNNEL_ADDRESS" dev tun0 \
        && ip link set tun0 up
}
build_fixture || fatal "could not build the LAN and tunnel interfaces"
# Two rules that are NOT ours, each a near miss: Tailscale's own reject, and a
# reject at OUR priority with no protocol. --clear must leave both.
ip rule add priority 5250 fwmark 0x80000/0xff0000 unreachable || fatal "foreign rule"
ip rule add priority 6601 to 9.9.9.9 unreachable || fatal "foreign rule"

printf '\nthe tunnel is DOWN\n'
ff --once; check "--once installs the rules: exit 0" "$?" 0
check "four rules, two per destination, are installed" \
      "$(ip -4 rule show | grep -c 'proto 66')" "4"
contains "a configured host fails at once" "$(route_get "$HOST_DESTINATION")" "Network is unreachable"
contains "an address inside a configured prefix fails at once" \
         "$(route_get "$PREFIX_DESTINATION_PROBE")" "Network is unreachable"
check "a real connect() gets ENETUNREACH, not a hang" "$(connect_errno "$HOST_DESTINATION")" "ENETUNREACH"
contains "everything else still leaves via the LAN" "$(route_get "$UNRELATED_DESTINATION")" "dev lan"

printf '\nthe tunnel comes UP, and goes DOWN again\n'
RULES_BEFORE="$(ip -4 rule show)"
# Held in a PIPE, not a file: the chrooted root is read-only, so there is nowhere
# to write one. The read end is duplicated at once, because bash closes a
# coproc's own descriptors the moment it exits -- and it exits when killed below.
coproc EVENT_MONITOR { exec ip monitor route; }
exec {EVENTS_FD}<&"${EVENT_MONITOR[0]}"
MONITOR_PID=$EVENT_MONITOR_PID
sleep 0.3
tunnel_up
ff --once; check "--once with the tunnel up: exit 0" "$?" 0
contains "a configured host goes through the tunnel" "$(route_get "$HOST_DESTINATION")" "dev tun0"
contains "...and so does the prefix" "$(route_get "$PREFIX_DESTINATION_PROBE")" "dev tun0"
check "the rules did not change when the tunnel came up" "$(ip -4 rule show)" "$RULES_BEFORE"
tunnel_down
ff --once
contains "back down: the host fails at once again" "$(route_get "$HOST_DESTINATION")" "Network is unreachable"
sleep 0.3
kill "$MONITOR_PID" 2>/dev/null; wait "$MONITOR_PID" 2>/dev/null
EVENTS="$(cat <&"$EVENTS_FD")"
exec {EVENTS_FD}<&-
# THE CRASH GUARANTEE. The only route events in the window are the tunnel's own
# four; nothing names a configured destination, and nothing is a reject route.
check "the transition emitted exactly the tunnel's own four route events" \
      "$(grep -c . <<<"$EVENTS")" "4"
check "...and not one of them names a configured destination or a reject route" \
      "$(grep -cE '203\.0\.113\.|198\.51\.100\.|unreachable' <<<"$EVENTS")" "0"

printf '\n--clear\n'
ff --clear; check "--clear: exit 0" "$?" 0
check "--clear removes every rule of ours" "$(ip -4 rule show | grep -c 'proto 66')" "0"
check "...and leaves the two that are not ours" "$(ip -4 rule show | grep -cE '^(5250|6601):')" "2"

TOTAL=$(( PASS + FAIL ))
printf '\n'
if (( TOTAL != EXPECTED_ROWS )); then
    printf 'FATAL: ran %d checks, expected %d — a row was added or lost.\n' "$TOTAL" "$EXPECTED_ROWS" >&2
    exit 2
fi
printf 'vpn fail-fast kernel table: %d/%d checks passed\n' "$PASS" "$TOTAL"
(( FAIL == 0 )) || exit 1
exit 0
