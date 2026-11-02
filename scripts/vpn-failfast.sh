#!/usr/bin/env bash
#
# scripts/vpn-failfast.sh
# =======================
#
# Make VPN-only destinations FAIL instead of HANG while the tunnel is down, with
# two static policy rules per destination that the kernel evaluates on every
# lookup -- so nothing is installed or withdrawn when the tunnel comes and goes.
#
# Why this exists
# ---------------
# The AWS Client VPN here is a full tunnel (`redirect-gateway def1`): the client
# installs 0.0.0.0/1 and 128.0.0.0/1 via tun0. When it drops it DELETES both, and
# the LAN default silently takes over -- so packets aimed at a Quantivly server
# still leave the machine, from an unauthorised source address, and the security
# groups drop them with no RST and no ICMP. Measured on this box, tunnel up,
# using SO_BINDTODEVICE to reproduce the tunnel-down path without touching the
# tunnel:
#
#   dev    54.166.22.221:22   via tunnel           CONNECTED in 0.16s
#   dev    54.166.22.221:22   forced out wlp0s20f3 NO RESPONSE (timeout at 6.0s)
#   github 140.82.121.3:443   forced out wlp0s20f3 CONNECTED in 0.06s
#
# tcp_syn_retries=6 means retransmits at 1/2/4/8/16/32/64s and ETIMEDOUT at
# ~127s; an established socket uses tcp_retries2=15, about 15 minutes. That is
# the 2-3 minute hang, exactly, and it is also why a dead tunnel went unnoticed
# for up to 8.8 hours: nothing FAILS, it hangs. Making it fail fast IS the
# notification.
#
# HOW: TWO RULES PER DESTINATION, INSTALLED ONCE
# ----------------------------------------------
#   priority 6600  to D  lookup main suppress_prefixlength 0  protocol 66
#   priority 6601  to D  unreachable                          protocol 66
#
# While the tunnel is up, 0.0.0.0/1 via tun0 matches D in main; it is a /1, not
# a /0, so the first rule accepts it and D goes through the tunnel. While it is
# down, the only match left is the LAN default -- a /0, which the first rule
# suppresses -- so the lookup falls to the second rule and connect() gets
# ENETUNREACH at once. The kernel makes that decision per lookup, so there is no
# poll window, and the rules never change when the tunnel does. Measured in a
# private netns with the host's iproute2-6.19.0 (docs/VPN_INTERNALS.md §11).
#
# WHY NOT THE ROUTE TOGGLE THIS REPLACED. Until 2026-11 this installed
# `unreachable` ROUTES while the tunnel was down and withdrew them seconds after
# it came back. AWS VPN Client 5.x listens to every IPv4 route event, and for a
# route with no output interface -- which every IPv4 reject route is -- its
# parser reads an UNINITIALIZED interface name and throws an unhandled
# ArgumentException. The client crashed on about one reconnect in four, took
# the tunnel with it, and nothing restarted it: 15 of 17 crashes with logs
# followed one of our withdrawals. That listener subscribes to route events and
# NOT to rule events (nl_groups 0x51, no RTMGRP_IPV4_RULE), and a rule that
# never changes emits nothing anyway. A fail-fast that crashes the VPN it
# guards is worse than none, so this must never go back to toggling routes.
#
# THE INVARIANT: this reads KERNEL STATE ONLY, never a log
# --------------------------------------------------------
# Both ~/.config/AWSVPNClient/logs (drwxrwxr-x zvi:zvi) and
# /var/log/aws-vpn-client/zvi (drwx------ zvi:root) are writable by any process
# running as the desktop user, and this runs as ROOT. A root daemon that acted on
# a line any unprivileged process can append is a privilege-escalation primitive
# handed out for free. `ip -j link` and `ip -j route` cannot be forged by an
# unprivileged process, so there is nothing to poison -- and that single decision
# deletes the whole attack surface two adversarial reviews mapped for the
# log-reading designs that preceded this one. Logs are read OFFLINE, by
# scripts/vpn-log-report.py, for reporting. Never here.
#
# IDENTITY, and what may be removed
# ---------------------------------
# Everything this installs carries a dedicated PROTOCOL (default 66), and that is
# the only thing consulted when deciding what may be removed:
#
#   * IPv4 RULES are ours when they carry protocol 66 AND sit at priority 6600 or
#     6601 AND have one of the two shapes above. They are found by reading the
#     WHOLE of `ip -j -4 rule show` and filtering here -- never with `ip rule show
#     protocol 66`, which ignores its filter and prints every rule on the box
#     (VPN_INTERNALS §10): a cleanup loop built on it would delete Tailscale's.
#     They are deleted by their full spec, protocol included, and the kernel will
#     not match a delete naming protocol 66 against a rule that lacks it.
#   * ROUTES (the IPv6 block, and any IPv4 `unreachable` route left by the old
#     toggle) are ours when `ip -j route show proto 66` lists them. A LEGACY IPv4
#     route is always an orphan now: a /32 beats the tunnel's /1, so one left
#     behind blackholes its host while the tunnel is UP.
#   * Both listings work UNPRIVILEGED, so vpn-doctor can check them without root.
#   * Route orphans are removed at START, before anything is added, as well as at
#     stop (ExecStopPost=) -- because the case that leaves them is the one where
#     the stop path did not run. Rules are reconciled as a delta instead: a rule
#     that is already right is never deleted and re-added.
#
# CONFIG VALIDATION IS NOT DECORATION. Measured with the real `ip`:
#
#   ip route add unreachable 0.0.0.0/0   -> ACCEPTED (reaches netlink)
#   ip route add unreachable 10.9.8.1/24 -> ACCEPTED (host bits ignored, /24 installed)
#   ip route add unreachable ::1/128     -> ACCEPTED (silently into the v6 table)
#   ip route add unreachable 300.1.2.3   -> rejected at parse
#
# So `ip` will happily blackhole the entire internet from a one-character typo.
# The rules need exactly the same care: `to 0.0.0.0/0 unreachable` would reject
# everything whenever the tunnel is down. Every destination is validated HERE,
# all of them BEFORE any is installed, so a bad entry can never leave a partial
# set behind.
#
# THE IPv6 BLOCK (DO-704), and why its polarity is the OPPOSITE of the above
# ---------------------------------------------------------------------------
# The endpoint is SplitTunnel=False but only IPv4 is tunnelled: the client
# installs the 0.0.0.0/1 + 128.0.0.0/1 pair and NOTHING for IPv6, so while the
# tunnel is up every v6 packet still leaves via the ISP -- and with no family
# flag glibc PREFERS v6, so the leak is the default path, not an edge case.
# Measured: `curl -4 ifconfig.me` returns the VPN's NAT gateway and `curl -6`
# returns the ISP address, on the same connected client.
#
# So while the tunnel is UP this installs `unreachable ::/1` + `unreachable
# 8000::/1`, and withdraws them while it is DOWN. That is the mirror image of
# the IPv4 half above, and deliberately so: there is no leak to close while the
# tunnel is down, and you keep a working dual-stack internet when disconnected.
#
# OFF BY DEFAULT. Arming is a typed command (`vpn-setup --block-ipv6`), which
# installs a drop-in setting VPN_FAILFAST_IPV6=block. WITHDRAWAL IS NOT GATED ON
# IT: --clear, the stop path and the tunnel-down branch remove the block however
# the knob is set, so disarming and restarting actually withdraws.
#
# THERE IS NO AUTOMATIC EXPIRY AND THERE CANNOT BE ONE. `expires` is ACCEPTED on
# an `unreachable` IPv6 route -- rc 0, netlink takes it -- and the attribute is
# then NEVER ATTACHED: no `expires` in `show`, no "expires" key in `-j`, not
# immediately and not later. The control is what makes that conclusive: a
# NEXTHOP route given the IDENTICAL flag, in the same netns, by the same binary,
# in the same second, shows `expires 4sec` at once and `expires -7sec` twelve
# seconds on. So the flag is honoured there and simply does not apply here. A
# dead-man switch built on it would be a safety claim that silently is not
# true. Withdrawal is guaranteed
# instead by four named things, none automatic: ExecStopPost=--clear (systemd
# runs it on EVERY stop, including a killed main process), the clear-at-start on
# --watch, the boot-time start via WantedBy=multi-user.target, and vpn-doctor's
# orphan check.
#
# --once REFUSES to install the block. It converges and exits, leaving no daemon
# and no ExecStopPost -- so `--once` with the tunnel up would blackhole global
# IPv6 until somebody found the route. The block is a --watch-only capability
# because only --watch can withdraw it.
#
# Usage:
#   vpn-failfast.sh --watch     daemon: converge on every link event, and poll
#   vpn-failfast.sh --once      converge once and exit (the IPv4 rules stay)
#   vpn-failfast.sh --clear     remove every rule and route this tool owns, then exit
#   vpn-failfast.sh --status    read-only: what is true now (no root needed)
#   vpn-failfast.sh --check     validate the config only; exit 2 if it is bad
#
# Exit codes
#   0  did what was asked
#   1  a route operation failed (and is named)
#   2  COULD NOT RUN -- bad config, missing `ip`, unreadable config. Never a pass.
#
# Test-suite overrides (also what makes it hermetic):
#   VPN_FAILFAST_CONF      default /etc/vpn-failfast.conf
#   VPN_FAILFAST_PROTO     default 66      route protocol = this tool's identity
#   VPN_FAILFAST_METRIC    default 4242
#   VPN_FAILFAST_IFACE     default tun0
#   VPN_FAILFAST_POLL      default 5       seconds
#   VPN_FAILFAST_MIN_PREFIX default 8      refuse anything broader than this
#   VPN_FAILFAST_IPV6      default off     off | block -- the DO-704 v6 block

set -uo pipefail

CONF="${VPN_FAILFAST_CONF:-/etc/vpn-failfast.conf}"
PROTO="${VPN_FAILFAST_PROTO:-66}"
METRIC="${VPN_FAILFAST_METRIC:-4242}"
IFACE="${VPN_FAILFAST_IFACE:-tun0}"
POLL="${VPN_FAILFAST_POLL:-5}"
MIN_PREFIX="${VPN_FAILFAST_MIN_PREFIX:-8}"
IPV6="${VPN_FAILFAST_IPV6:-off}"

# THE DESTINATIONS ARE A CONSTANT, NOT CONFIG, and NOT `2000::/3`. The
# well-known NAT64 prefix 64:ff9b::/96 lives in ::/3, so on an IPv6-only hotspot
# with PREF64+DNS64 -- where every AAAA answer is a 64:ff9b:: address --
# 2000::/3 would block nothing at all. Measured here: `ip -6 route get
# 64:ff9b::1` resolves via the ISP default route.
#
# This pair is the exact mirror of the 0.0.0.0/1 + 128.0.0.0/1 the VPN client
# installs for IPv4, which makes it self-explanatory in a routing table. Nothing
# that should keep working is caught by it, measured rather than assumed:
# multicast is in `table local` (consulted by rule 0 before anything else),
# link-local fe80::/64 and the on-link LAN /64 win on prefix length, and
# Tailscale's fd7a:115c:a1e0::/48 resolves via table 52 at rule 5270, which is
# evaluated BEFORE the main table.
IPV6_BLOCK_DSTS=( "::/1" "8000::/1" )

# Set only on the --watch path. See the --once note in the header.
ALLOW_V6_BLOCK=0

# The IPv4 rule pair, at fixed priorities: after Tailscale's 5210-5270 (so the
# tailnet is never affected) and before the main table at 32766. Constants, not
# knobs -- a priority is part of the identity, and an identity that a stray
# environment variable can move is one a cleanup can lose track of.
readonly TUNNEL_RULE_PRIORITY=6600
readonly REJECT_RULE_PRIORITY=6601

log() { printf 'vpn-failfast: %s\n' "$*"; }
err() { printf 'vpn-failfast: %s\n' "$*" >&2; }

# Every numeric knob is validated, never trusted. Each is used inside (( )) or
# handed to `ip`, and a non-numeric value is a silent 0 in bash -- a PROTO of 0
# is the kernel's "unspec", which would make the delete filter match routes this
# tool never created. That is the one failure here that damages the machine
# rather than this script.
for _v in PROTO METRIC POLL MIN_PREFIX; do
    if [[ ! "${!_v}" =~ ^[0-9]+$ ]]; then
        err "VPN_FAILFAST_${_v} must be a non-negative integer, got '${!_v}'"
        exit 2
    fi
done
if (( PROTO < 1 || PROTO > 255 )); then
    err "VPN_FAILFAST_PROTO must be 1-255 (got $PROTO): 0 is the kernel's 'unspec'," \
        "and deleting by it would match routes this tool never created"
    exit 2
fi
if (( MIN_PREFIX < 1 || MIN_PREFIX > 32 )); then
    err "VPN_FAILFAST_MIN_PREFIX must be 1-32, got $MIN_PREFIX"
    exit 2
fi
# An unknown value is exit 2, NEVER a silent default in either direction.
# Defaulting to `off` would disarm a machine that asked to be armed and say
# nothing; defaulting to `block` would blackhole IPv6 off a typo. This is the
# only producer of the value's meaning, and the installer uses this very
# validation as its post-install check -- so `VPN_FAILFAST_IPV6=blocked` in the
# drop-in is caught before `systemctl restart`, rather than making --watch exit
# 2 on every start until the unit sits `failed` and IPv4 fail-fast dies with it.
case "$IPV6" in
    off|block) ;;
    *) err "VPN_FAILFAST_IPV6 must be 'off' or 'block', got '$IPV6'"
       exit 2 ;;
esac

command -v ip >/dev/null 2>&1 || { err "iproute2 'ip' not found"; exit 2; }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
# PARSED, never sourced. The file is root-owned and this runs as root, so
# sourcing it would be executing a config file as root on every start for no
# benefit whatsoever.
#
# `dst` is normalised to the spelling `ip route show` uses, because that is the
# string the delta below compares against: a /32 is reported WITHOUT its prefix
# length, so a config line of `1.2.3.4/32` and a route of `1.2.3.4` are the same
# route and must compare equal, or every converge re-adds a route that is
# already there.
normalise_dst() {
    local d="$1"
    [[ "$d" == */32 ]] && d="${d%/32}"
    printf '%s\n' "$d"
}

# One destination. Prints nothing; the message is the caller's.
# Rejects, in order: not IPv4-literal (which catches IPv6, hostnames and every
# typo), an out-of-range octet, an out-of-range or too-broad prefix, host bits
# set, and loopback.
validate_dst() {
    local d="$1" addr len o
    addr="${d%%/*}"
    if [[ "$d" == */* ]]; then len="${d#*/}"; else len=32; fi

    [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        REASON="not an IPv4 address or CIDR (IPv6 and hostnames are not supported here; 'ip'"
        REASON+=" would accept an IPv6 prefix and silently install it into the v6 table)"
        return 1; }
    for o in ${addr//./ }; do
        # A leading zero is octal to some parsers and decimal to others; refusing
        # it costs nothing and removes the ambiguity entirely.
        [[ "$o" =~ ^0[0-9] ]] && { REASON="octet '$o' has a leading zero"; return 1; }
        (( o >= 0 && o <= 255 )) || { REASON="octet '$o' is out of range"; return 1; }
    done
    [[ "$len" =~ ^[0-9]+$ ]] || { REASON="prefix length '/$len' is not a number"; return 1; }
    (( len <= 32 )) || { REASON="prefix length /$len is out of range"; return 1; }
    (( len >= MIN_PREFIX )) || {
        REASON="/$len is broader than the /$MIN_PREFIX floor. 'ip' ACCEPTS unreachable"
        REASON+=" 0.0.0.0/0 -- one typo there blackholes the entire internet until someone"
        REASON+=" finds this route"
        return 1; }

    # Host bits. `ip` takes 10.9.8.1/24 and installs the whole /24, so a typo
    # meant as a host route silently blackholes 256 addresses. Refuse it and say
    # which prefix was meant.
    local -i ip32=0 mask
    for o in ${addr//./ }; do ip32=$(( (ip32 << 8) | o )); done
    if (( len == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF )); fi
    if (( (ip32 & ~mask & 0xFFFFFFFF) != 0 )); then
        local -i net=$(( ip32 & mask ))
        REASON="has host bits set below /$len -- 'ip' would install"
        REASON+=" $(( (net >> 24) & 255 )).$(( (net >> 16) & 255 ))"
        REASON+=".$(( (net >> 8) & 255 )).$(( net & 255 ))/$len instead"
        return 1
    fi
    if (( (ip32 >> 24) == 127 )); then REASON="is loopback"; return 1; fi
    return 0
}

# Reads CONF into DESTS. Exit 2 on anything wrong -- an unreadable or malformed
# config must NEVER degrade to "no destinations", which is a silent no-op that
# looks exactly like a healthy machine with the tunnel up.
DESTS=()
read_config() {
    local line dst n=0
    DESTS=()
    if [[ ! -e "$CONF" ]]; then
        err "$CONF does not exist. Run vpn-setup, or create it from examples/vpn-failfast.conf.template."
        return 2
    fi
    if [[ ! -r "$CONF" ]]; then
        err "$CONF exists and cannot be read. That is not 'no destinations' -- refusing."
        return 2
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$(( n + 1 ))
        line="${line%%#*}"
        # Trim. No `xargs`, no subshell: this runs on every start.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" == *[[:space:]]* ]]; then
            err "$CONF:$n: '$line' -- one destination per line, no spaces"
            return 2
        fi
        REASON=""
        if ! validate_dst "$line"; then
            err "$CONF:$n: '$line' $REASON"
            return 2
        fi
        dst="$(normalise_dst "$line")"
        DESTS+=("$dst")
    done < "$CONF"
    if (( ${#DESTS[@]} == 0 )); then
        err "$CONF lists no destinations. Nothing would ever fail fast; refusing rather than" \
            "running as a no-op that is indistinguishable from a healthy tunnel."
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Kernel state
# ---------------------------------------------------------------------------
# UP means: the interface exists and carries the UP flag, AND at least one route
# through it has a GATEWAY.
#
# The gateway clause is the load-bearing half and it is what the measurements
# support. On a drop the client deletes 0.0.0.0/1 and 128.0.0.0/1 -- both of
# which carry `"gateway": "172.31.80.1"` -- while tun0 itself can linger, still
# flagged UP, with only its own link-scope subnet route left. Measured with the
# tunnel healthy:
#
#   {"dst":"0.0.0.0/1",     "gateway":"172.31.80.1"}      <- forwarding
#   {"dst":"128.0.0.0/1",   "gateway":"172.31.80.1"}      <- forwarding
#   {"dst":"172.31.80.0/27","protocol":"kernel","scope":"link"}  <- not
#
# So counting routes on the interface would call a dead tunnel healthy; counting
# routes WITH A GATEWAY does not.
tunnel_up() {
    local links routes
    links="$(ip -j link show "$IFACE" 2>/dev/null)" || return 1
    [[ -n "$links" && "$links" != "[]" ]] || return 1
    printf '%s' "$links" | grep -q '"UP"' || return 1
    routes="$(ip -j route show dev "$IFACE" 2>/dev/null)" || return 1
    printf '%s' "$routes" | grep -q '"gateway"' || return 1
    return 0
}

# ADDRESS FAMILY IS AN EXPLICIT FIRST ARGUMENT, at every call site, with no
# default anywhere. `ip route show proto N` answers about IPv4 ONLY -- it is not
# a family-neutral query that happens to return v4 today. A defaulted family is
# therefore a route this tool owns that nothing enumerates and nothing
# withdraws: invisible to clear_owned(), to --status and to vpn-doctor, and
# surviving a SIGKILLed daemon as a permanent blackhole with no symptom but the
# outage. Making the caller say which family costs one token and removes the
# entire class.

# The destinations this tool currently owns in ONE family, one per line.
# Filtered by PROTO and by nothing else: proto IS the identity, and a route with
# another proto is somebody else's whatever it points at.
#
# owned_routes <-4|-6>
owned_routes() {
    local fam="$1"
    # Whitespace-tolerant on purpose. Real iproute2 emits compact JSON here
    # (verified), but `ip -p -j` pretty-prints, and a parser that silently
    # matches nothing means NOTHING IS EVER WITHDRAWN -- the stale route that
    # blackholes a host, arrived at through a formatting change nobody would
    # connect to it. There is no error to notice: the delete loop simply has
    # nothing to iterate.
    ip -j "$fam" route show proto "$PROTO" 2>/dev/null \
        | grep -oE '"dst"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/^"dst"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

# add_route <-4|-6> <dst>
add_route() {
    local fam="$1" d="$2" out
    if out="$(ip "$fam" route add unreachable "$d" proto "$PROTO" metric "$METRIC" 2>&1)"; then
        log "fail-fast ON  $d"
        return 0
    fi
    # Already there is success: converge is idempotent by design, and a race
    # with our own previous pass must not be an error.
    [[ "$out" == *"File exists"* ]] && return 0
    err "could not add unreachable $d: $out"
    return 1
}

# del_route <-4|-6> <dst>
#
# THE v6 DELETE CARRIES NO `metric`, DELIBERATELY. Measured: `ip -6 route del
# <dst> proto 66 metric 1024` against a metric-4242 route answers "No such
# process" -- which the swallow below treats as SUCCESS. So a single metric
# drift (a re-add, an RA, a kernel default) would make a v6 blackhole PERMANENT
# while clear_owned cheerfully reported it cleared. Proto is the identity;
# metric never was. The v4 delete keeps it because that half has shipped and its
# metric is written by this same script on the way in.
del_route() {
    local fam="$1" d="$2" out
    local -a cmd=(ip "$fam" route del unreachable "$d" proto "$PROTO")
    [[ "$fam" == "-6" ]] || cmd+=(metric "$METRIC")
    if out="$("${cmd[@]}" 2>&1)"; then
        log "fail-fast OFF $d"
        return 0
    fi
    [[ "$out" == *"No such process"* || "$out" == *"not found"* ]] && return 0
    err "could not remove unreachable $d: $out"
    return 1
}

# Remove everything this tool owns IN ONE FAMILY, whatever the config says now.
# Used at start (an orphan from a previous config is still an orphan), at stop,
# and by --clear.
#
# clear_owned <-4|-6>
clear_owned() {
    local fam="$1" d rc=0 left
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        del_route "$fam" "$d" || rc=1
    done < <(owned_routes "$fam")
    # RE-READ, and it is worth the one extra `ip` call. "every delete reported
    # success and the route is still there" is otherwise completely silent --
    # and it is reachable, because del_route treats "No such process" as
    # success, so a delete that addressed the wrong route looks identical to a
    # delete that worked. This turns that whole class from silent into loud.
    left="$(owned_routes "$fam")"
    if [[ -n "$left" ]]; then
        err "routes still owned after clearing ($fam): $(tr '\n' ' ' <<<"$left")"
        rc=1
    fi
    return "$rc"
}

# Both families of ROUTE, unconditionally and regardless of the arming switch:
# the legacy IPv4 routes the old toggle left, and the IPv6 block. This is what
# the --watch and --once start use: a stale v6 blackhole is exactly as dangerous
# as a stale v4 one, and "we were not armed" is never a reason to leave one
# installed.
clear_routes() {
    local rc=0
    clear_owned -4 || rc=1
    clear_owned -6 || rc=1
    return "$rc"
}

# ---------------------------------------------------------------------------
# The IPv4 rules
# ---------------------------------------------------------------------------
# The two shapes, spelled ONCE, because add and delete must agree byte for byte:
# a delete is matched by the kernel on every selector it names, so a delete
# spelled differently from its add is a delete of nothing.
#
# rule_spec <tunnel|reject> <dst>   (sets RULE_SPEC)
RULE_SPEC=()
rule_spec() {
    case "$1" in
        tunnel) RULE_SPEC=(priority "$TUNNEL_RULE_PRIORITY" to "$2"
                           lookup main suppress_prefixlength 0 protocol "$PROTO") ;;
        reject) RULE_SPEC=(priority "$REJECT_RULE_PRIORITY" to "$2"
                           unreachable protocol "$PROTO") ;;
        *) err "rule_spec: unknown kind '$1'"; return 1 ;;
    esac
}

# The rules this tool owns, one `<tunnel|reject> <dst>` per line, with dst in
# the same spelling read_config produces (a /32 bare, anything else with its
# length). Measured shapes, compact and `-p` pretty alike:
#
#   {"priority":6600,"src":"all","dst":"3.216.24.205","table":"main","suppress_prefixlen":0,"protocol":"66"}
#   {"priority":6601,"src":"all","dst":"10.20.0.0","dstlen":16,"action":"unreachable","protocol":"66"}
#
# A record is one object, split on `}` (rule objects are flat). Fields are read
# with match(), whitespace-tolerant, because `ip -p -j` puts newlines and spaces
# where the compact form has none, and a parser that matched only one spelling
# would find NOTHING -- so nothing would ever be withdrawn. mawk-safe: no
# character classes, no gawk extensions.
owned_rules() {
    ip -j -4 rule show 2>/dev/null | awk \
        -v proto="$PROTO" \
        -v tunnel_priority="$TUNNEL_RULE_PRIORITY" \
        -v reject_priority="$REJECT_RULE_PRIORITY" '
        function field(name,    pattern, value) {
            pattern = "\"" name "\"[ \t\r\n]*:[ \t\r\n]*(\"[^\"]*\"|[0-9]+)"
            if (!match($0, pattern)) return ""
            value = substr($0, RSTART, RLENGTH)
            sub(/^"[^"]*"[ \t\r\n]*:[ \t\r\n]*/, "", value)
            gsub(/"/, "", value)
            return value
        }
        BEGIN { RS = "}" }
        {
            if (field("protocol") != proto) next
            destination = field("dst")
            if (destination == "") next
            prefix_length = field("dstlen")
            if (prefix_length != "" && prefix_length != "32") destination = destination "/" prefix_length
            priority = field("priority")
            if (priority == tunnel_priority && field("table") == "main" && field("suppress_prefixlen") == "0")
                print "tunnel " destination
            else if (priority == reject_priority && field("action") == "unreachable")
                print "reject " destination
        }'
}

# add_rule <tunnel|reject> <dst>
add_rule() {
    local kind="$1" d="$2" out
    rule_spec "$kind" "$d" || return 1
    if out="$(ip -4 rule add "${RULE_SPEC[@]}" 2>&1)"; then
        log "fail-fast rule ON  $kind $d"
        return 0
    fi
    # Already there is success, as for routes: converge is idempotent by design.
    [[ "$out" == *"File exists"* ]] && return 0
    err "could not add $kind rule for $d: $out"
    return 1
}

# del_rule <tunnel|reject> <dst>
del_rule() {
    local kind="$1" d="$2" out
    rule_spec "$kind" "$d" || return 1
    if out="$(ip -4 rule del "${RULE_SPEC[@]}" 2>&1)"; then
        log "fail-fast rule OFF $kind $d"
        return 0
    fi
    # Measured: deleting a rule that is not there answers "No such file or
    # directory". Already gone is success; the re-read in clear_rules is what
    # makes a delete that matched nothing loud instead of silent.
    [[ "$out" == *"No such file or directory"* ]] && return 0
    err "could not remove $kind rule for $d: $out"
    return 1
}

is_configured() {
    local want="$1" d
    for d in "${DESTS[@]}"; do [[ "$d" == "$want" ]] && return 0; done
    return 1
}

# Remove every rule this tool owns, REJECT RULES FIRST. The order is the safety
# property: with the tunnel up, a reject rule whose tunnel rule has already gone
# rejects a host that is perfectly reachable. Removing rejects first means no
# moment exists where that is true.
clear_rules() {
    local rc=0 kind k d left
    for kind in reject tunnel; do
        while IFS=' ' read -r k d; do
            [[ "$k" == "$kind" ]] || continue
            del_rule "$kind" "$d" || rc=1
        done < <(owned_rules)
    done
    left="$(owned_rules)"
    if [[ -n "$left" ]]; then
        err "rules still owned after clearing: $(tr '\n' ' ' <<<"$left")"
        rc=1
    fi
    return "$rc"
}

# Reconcile the rules with DESTS as a DELTA. Never clear-then-add: a rule that is
# already right is left alone, so a running daemon never opens a window.
#
# Stale rules come off first, rejects before tunnels (see clear_rules). Missing
# rules go on per destination, TUNNEL BEFORE REJECT, for the mirror reason: a
# reject rule added first would reject a host whose tunnel is up for as long as
# its tunnel rule is missing.
converge_rules() {
    local rc=0 have kind k d
    have="$(owned_rules)"
    for kind in reject tunnel; do
        while IFS=' ' read -r k d; do
            [[ "$k" == "$kind" ]] || continue
            is_configured "$d" && continue
            del_rule "$kind" "$d" || rc=1
        done <<<"$have"
    done
    for d in "${DESTS[@]}"; do
        grep -qxF -- "tunnel $d" <<<"$have" || add_rule tunnel "$d" || rc=1
        grep -qxF -- "reject $d" <<<"$have" || add_rule reject "$d" || rc=1
    done
    return "$rc"
}

# Everything this tool owns, in both families, unconditionally and regardless of
# the arming switch. This is what --clear and the stop path use.
clear_all() {
    local rc=0
    clear_rules || rc=1
    clear_routes || rc=1
    return "$rc"
}

# The IPv6 half of the tunnel-UP branch. Split out because it is the ONE place
# in this file where "tunnel up" does not mean "withdraw everything", and
# burying that inversion inside converge() is how it would get lost.
#
# It is a DELTA, never a clear-then-add. If the up-branch simply cleared and
# re-added the block every pass, there would be a genuinely unblocked window
# 17,280 times a day -- which is the leak this exists to close.
converge_v6_up() {
    local rc=0 d have keep k
    if [[ "$IPV6" != "block" ]]; then
        # Not armed: nothing should be blocked, so withdraw anything we own.
        clear_owned -6 || rc=1
        return "$rc"
    fi
    if (( ! ALLOW_V6_BLOCK )); then
        log "the IPv6 block is a --watch-only capability (only --watch can withdraw it)" \
            "-- installing the IPv4 half only"
        clear_owned -6 || rc=1
        return "$rc"
    fi
    have="$(owned_routes -6)"
    for d in "${IPV6_BLOCK_DSTS[@]}"; do
        grep -qxF -- "$d" <<<"$have" && continue
        add_route -6 "$d" || rc=1
    done
    # A v6 route we own that is not one of today's halves is the same stale
    # route the v4 branch drops when a destination leaves the config -- an older
    # release's constant, or an operator's hand. Same rule, same reason.
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        keep=0
        for k in "${IPV6_BLOCK_DSTS[@]}"; do [[ "$k" == "$d" ]] && { keep=1; break; }; done
        (( keep )) || del_route -6 "$d" || rc=1
    done <<<"$have"
    return "$rc"
}

# One convergence. The config must already be in DESTS.
#
# IPv4 DOES NOT DEPEND ON THE TUNNEL STATE AT ALL. The rules are the same either
# way -- the kernel decides per lookup -- so this reconciles them on every pass
# and never adds or withdraws anything because the tunnel moved. Only the IPv6
# block still follows the tunnel, with the opposite polarity:
#
#   tunnel UP   -> v6 block goes ON   (the tunnel does NOT carry v6)
#   tunnel DOWN -> v6 block comes OFF (there is no tunnel to leak around)
converge() {
    local rc=0
    converge_rules || rc=1
    # A legacy IPv4 route under our proto is an orphan in EVERY state now (see
    # the header), so it is reclaimed on every pass, not only at start.
    clear_owned -4 || rc=1
    if tunnel_up; then
        converge_v6_up || rc=1
        return "$rc"
    fi
    # UNCONDITIONAL, and not gated on the arming switch: while the tunnel is
    # down there is nothing to block, so a block left installed is an orphan
    # that blackholes all global IPv6 on a machine with no VPN at all.
    clear_owned -6 || rc=1
    return "$rc"
}

# ---------------------------------------------------------------------------
print_status() {
    local d n=0
    if tunnel_up; then
        printf 'tunnel:  UP (%s has a gateway route)\n' "$IFACE"
    else
        printf 'tunnel:  DOWN (%s missing, down, or with no gateway route)\n' "$IFACE"
    fi
    printf 'config:  %s\n' "$CONF"
    if read_config; then
        printf 'targets: %d\n' "${#DESTS[@]}"
        for d in "${DESTS[@]}"; do printf '  - %s\n' "$d"; done
    else
        printf 'targets: CONFIG UNUSABLE (see above)\n'
    fi
    # The rules, as `<tunnel|reject> <dst>`. vpn-doctor parses this section to
    # judge each destination's pair, so its header and line shape are an
    # interface: change them in both places or not at all.
    printf 'ipv4 rules (proto %s, priorities %s/%s):\n' \
        "$PROTO" "$TUNNEL_RULE_PRIORITY" "$REJECT_RULE_PRIORITY"
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        printf '  - %s\n' "$d"; n=$(( n + 1 ))
    done < <(owned_rules)
    (( n == 0 )) && printf '  (none)\n'
    # Any entry here is an orphan of the old route toggle -- see the header.
    printf 'ipv4 legacy routes (proto %s):\n' "$PROTO"
    n=0
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        printf '  - %s\n' "$d"; n=$(( n + 1 ))
    done < <(owned_routes -4)
    (( n == 0 )) && printf '  (none)\n'
    # The v6 block, armed state and installed halves. Cheap -- one more `ip`
    # call -- and it is what makes vpn-doctor able to answer the orphan question
    # for BOTH families from a single --status rather than growing a second
    # route parser of its own.
    #
    # The `route get` canaries deliberately do NOT live here. vpn-doctor is the
    # one consumer that needs them, it would otherwise run them two or three
    # times per invocation, and their interpretation would end up written down
    # twice -- once in bash and once in zsh.
    # "as seen by THIS process" is not pedantry. The unit gets its value from a
    # drop-in; a shell running --status by hand does not, so a bare "not armed"
    # here would report every armed machine as disarmed. vpn-doctor reads the
    # arming state from the drop-in for exactly this reason.
    printf 'ipv6:    %s (VPN_FAILFAST_IPV6, as seen by this process)\n' "$IPV6"
    printf 'ipv6 installed (proto %s):\n' "$PROTO"
    n=0
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        printf '  - %s\n' "$d"; n=$(( n + 1 ))
    done < <(owned_routes -6)
    (( n == 0 )) && printf '  (none)\n'
    return 0
}

run_watch() {
    local line
    # ip monitor is the LATENCY optimisation. The poll is the CORRECTNESS
    # guarantee: a netlink socket can overrun and drop events silently, `ip
    # monitor` can die, and neither is visible from here -- so the loop converges
    # every POLL seconds regardless and never depends on an event arriving.
    local have_mon=0
    if coproc MON { exec ip monitor link; } 2>/dev/null; then
        have_mon=1
    else
        log "ip monitor unavailable -- polling every ${POLL}s"
    fi
    # Withdraw on the way out as well as in ExecStopPost=, because the stop path
    # that fails to run is exactly the one that strands routes.
    trap 'log "stopping"; clear_all; exit 0' TERM INT
    while :; do
        converge || true
        if (( have_mon )) && [[ -n "${MON_PID:-}" ]] && kill -0 "$MON_PID" 2>/dev/null; then
            IFS= read -r -t "$POLL" line <&"${MON[0]}" || true
        else
            sleep "$POLL"
        fi
    done
}

usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

main() {
    # Arity before the flag: `case "${1:-}"` reads only the first word, so
    # `--clear --oops` would silently run a normal --clear.
    if (( $# > 1 )); then
        err "too many arguments (expected at most one, got $#: $*)"
        exit 2
    fi
    case "${1:---watch}" in
        --status)      print_status; exit 0 ;;
        --check)       read_config || exit 2
                       log "$CONF: ${#DESTS[@]} destination(s), all valid"; exit 0 ;;
        --clear)       clear_all || exit 1; exit 0 ;;
        --once)        read_config || exit 2
                       clear_routes || exit 1
                       converge || exit 1
                       exit 0 ;;
        --watch)       read_config || exit 2
                       # Route orphans first, ALWAYS, and before anything is
                       # added: a route left by a previous run is invisible to
                       # converge_v6_up, which only knows today's halves. Rules
                       # are NOT cleared here -- converge_rules reconciles them as
                       # a delta, so a restart never opens a window in which a
                       # configured host hangs instead of failing.
                       clear_routes || exit 1
                       ALLOW_V6_BLOCK=1
                       run_watch ;;
        --help|-h)     usage; exit 0 ;;
        *)             err "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
}

main "$@"
