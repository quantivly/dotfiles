#!/usr/bin/env bash
#
# scripts/test-vpn-failfast.sh
# ============================
#
# State table for scripts/vpn-failfast.sh, scripts/vpn-notify.sh,
# scripts/vpn-render.sh and scripts/vpn-log-report.py.
#
# HERMETIC via recording `ip` and `notify-send` STUBS at the front of PATH, never
# by relying on either being absent. The real `ip` on this box would need root to
# do anything — but `ip route show` does NOT, and a suite that let a real one
# through would read the live route table and report the machine's state as the
# subject's. More to the point, the subject INSTALLS ROUTES: a row that reached
# the real `ip` with privilege would blackhole a Quantivly server on the
# developer's own machine, which is the failure this file exists to prevent.
#
# The stub records its argv, so a row can assert what was NOT done — that a route
# with a foreign proto is never deleted, that nothing is added when the tunnel is
# up, and that a malformed config installs NOTHING rather than a partial set.
#
# THE NOTIFICATION BODY is asserted BYTE-FOR-BYTE and across differing config and
# tunnel state, because GNOME renders body-markup including <a href>: any text
# derived from anything is a phishing sink, and the only way to keep it constant
# is to check that it IS constant.
#
# THE REPORTER is exercised against tests/fixtures/vpn/aws_vpn_client_dst.log,
# which carries BOTH +03:00 and +02:00 in one file, dated across the NEXT
# Asia/Jerusalem transition (2026-10-25) deliberately: that is the one that will
# break it, about four weeks after this was written and exactly when the
# week-later comparison runs. Anything pinning the literal offset silently
# reports zero events, which reads as "the fix worked".
#
# "Could not run" is exit 2, never a pass. The suite asserts its own row total.
#
# Requires: bash, python3, sed, grep. No sudo, no root, no network, no systemd.
#
# Usage: scripts/test-vpn-failfast.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FAILFAST="$DOTFILES/scripts/vpn-failfast.sh"
NOTIFY="$DOTFILES/scripts/vpn-notify.sh"
RENDER="$DOTFILES/scripts/vpn-render.sh"
REPORT="$DOTFILES/scripts/vpn-log-report.py"
FIXTURES="$DOTFILES/tests/fixtures/vpn"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
grep_ok()   { if grep -q -- "$2" <<<"$1"; then ok "$3"; else bad "$3 — output did not contain '$2'"; fi; }
grep_none() { if grep -q -- "$2" <<<"$1"; then bad "$3 — output unexpectedly contained '$2'"; else ok "$3"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for f in "$FAILFAST" "$NOTIFY" "$RENDER" "$REPORT"; do
    [[ -x "$f" ]] || fatal "cannot execute $f"
done
[[ -r "$FIXTURES/aws_vpn_client_dst.log" ]] || fatal "missing DST fixture in $FIXTURES"
command -v python3 >/dev/null || fatal "python3 is required"

T="$(mktemp -d)" || fatal "no temp dir"
trap 'rm -rf "$T"' EXIT
STUBBIN="$T/bin"
mkdir -p "$STUBBIN" || fatal setup

PROTO=66
METRIC=4242
IFACE=tun0

# ---------------------------------------------------------------------------
# The `ip` stub
# ---------------------------------------------------------------------------
cat > "$STUBBIN/ip" <<'STUB'
#!/usr/bin/env bash
# Fake iproute2 for scripts/test-vpn-failfast.sh.
[ -n "${IPSTATE:-}" ] || { echo "ip stub: no IPSTATE" >&2; exit 99; }
printf '%s\n' "$*" >> "$IPSTATE/calls.log"

json=0
args=()
for a in "$@"; do
  case "$a" in
    -j|-json) json=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]}"

case "${1:-}" in
  link)
    # `ip -j link show <iface>`. A missing fixture is a missing interface, which
    # the real ip reports by exiting 1 with a message on stderr.
    f="$IPSTATE/link-${3:-}"
    if [ -r "$f" ]; then cat "$f"; exit 0; fi
    echo "Device \"${3:-}\" does not exist." >&2
    exit 1 ;;
  route)
    sub="${2:-}"
    case "$sub" in
      show)
        shift 2
        if [ "${1:-}" = "dev" ]; then
          f="$IPSTATE/route-dev-${2:-}"
          if [ -r "$f" ]; then cat "$f"; else echo '[]'; fi
          exit 0
        fi
        if [ "${1:-}" = "proto" ]; then
          # Only routes carrying the requested proto. Routes with any other
          # proto are never returned, which is what lets a row prove the subject
          # never deletes one it did not create.
          want="${2:-}"
          out="[]"
          if [ -r "$IPSTATE/routes" ]; then
            out="$(python3 - "$IPSTATE/routes" "$want" "${IPSTATE}/pretty-json" <<'PY'
import json,os,sys
rows=[]
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    dst,proto,metric = line.split('\t')
    if proto != sys.argv[2]: continue
    rows.append({"type":"unreachable","dst":dst,"protocol":int(proto),
                 "metric":int(metric),"flags":[]})
# COMPACT by default, because that is what real `ip -j` emits -- verified on
# this box. The pretty form is what `ip -p -j` emits, and a row uses it.
if os.path.exists(sys.argv[3]):
    print(json.dumps(rows, indent=4))
else:
    print(json.dumps(rows, separators=(',', ':')))
PY
)"
          fi
          printf '%s\n' "$out"
          exit 0
        fi
        echo '[]'; exit 0 ;;
      add|del)
        # Grammar exactly as the real one: `route add|del unreachable <dst> proto
        # <n> metric <m>`.
        op="$sub"; shift 2
        [ "${1:-}" = "unreachable" ] || { echo "ip stub: expected 'unreachable', got '${1:-}'" >&2; exit 98; }
        dst="${2:-}"; proto=""; metric=""
        shift 2
        while [ $# -gt 0 ]; do
          case "$1" in
            proto) proto="${2:-}"; shift 2 ;;
            metric) metric="${2:-}"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -n "$proto" ] || { echo "ip stub: no proto given" >&2; exit 98; }
        touch "$IPSTATE/routes"
        if [ "$op" = "add" ]; then
          [ -e "$IPSTATE/fail-add" ] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
          # awk only: `grep` here is a ugrep shim, and -P is one of the GNU
          # extensions this repo's notes warn about resolving differently.
          if awk -F'\t' -v d="$dst" '$1==d{found=1} END{exit !found}' "$IPSTATE/routes"; then
            echo "RTNETLINK answers: File exists" >&2; exit 2
          fi
          printf '%s\t%s\t%s\n' "$dst" "$proto" "$metric" >> "$IPSTATE/routes"
          exit 0
        fi
        [ -e "$IPSTATE/fail-del" ] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
        if ! awk -F'\t' -v d="$dst" -v p="$proto" '$1==d && $2==p{found=1} END{exit !found}' "$IPSTATE/routes"; then
          echo "RTNETLINK answers: No such process" >&2; exit 2
        fi
        awk -F'\t' -v d="$dst" -v p="$proto" '!($1==d && $2==p)' "$IPSTATE/routes" > "$IPSTATE/.r" \
          && mv -f "$IPSTATE/.r" "$IPSTATE/routes"
        exit 0 ;;
    esac
    echo "ip stub: unhandled route subcommand: $sub" >&2; exit 99 ;;
  monitor)
    # --watch is not exercised here; a stub that streamed would hang the suite.
    exit 1 ;;
esac
echo "ip stub: unhandled: $*" >&2
exit 99
STUB
chmod +x "$STUBBIN/ip" || fatal setup

cat > "$STUBBIN/notify-send" <<'STUB'
#!/usr/bin/env bash
[ -n "${IPSTATE:-}" ] || exit 99
# One argv element per line, so a row can assert the body BYTE FOR BYTE and
# detect a body that was split, joined or interpolated.
: > "$IPSTATE/notify.argv"
for a in "$@"; do printf '%s\n' "$a" >> "$IPSTATE/notify.argv"; done
printf 'called\n' >> "$IPSTATE/notify.count"
exit 0
STUB
chmod +x "$STUBBIN/notify-send" || fatal setup

STUB_IP="$(PATH="$STUBBIN:$PATH" bash -c 'command -v ip')"
check "ip resolves to the stub" "$STUB_IP" "$STUBBIN/ip"
[[ "$STUB_IP" == "$STUBBIN/ip" ]] || \
  fatal "the stub is not first on PATH; a row could install a real route"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
# Exported once rather than repeated in every command prefix. `IPSTATE="$IPSTATE"`
# in a prefix expands the OUTER value, which happens to be right here and reads
# exactly like the bug where it is not (shellcheck SC2097/SC2098).
IPSTATE="$T/ipstate"
export IPSTATE
CONF="$T/vpn-failfast.conf"

reset() {
    rm -rf "$IPSTATE"; mkdir -p "$IPSTATE" || fatal setup
    : > "$IPSTATE/calls.log"
    : > "$IPSTATE/routes"
}

# The measured healthy shape: two forwarding routes with a gateway, plus the
# interface's own link-scope subnet route which has none.
tunnel_up_state() {
    printf '[{"ifindex":186,"ifname":"tun0","flags":["POINTOPOINT","MULTICAST","NOARP","UP","LOWER_UP"],"operstate":"UNKNOWN"}]\n' \
        > "$IPSTATE/link-$IFACE"
    printf '%s\n' '[{"dst":"0.0.0.0/1","gateway":"172.31.80.1","flags":[]},{"dst":"128.0.0.0/1","gateway":"172.31.80.1","flags":[]},{"dst":"172.31.80.0/27","protocol":"kernel","scope":"link","prefsrc":"172.31.80.10","flags":[]}]' \
        > "$IPSTATE/route-dev-$IFACE"
}

# The interface LINGERS, still flagged UP, with only its link-scope route left.
# This is what a drop actually looks like — the client deletes the two gateway
# routes — and it is why "does the interface exist" is not the test.
tunnel_down_lingering() {
    printf '[{"ifindex":186,"ifname":"tun0","flags":["POINTOPOINT","MULTICAST","NOARP","UP","LOWER_UP"],"operstate":"UNKNOWN"}]\n' \
        > "$IPSTATE/link-$IFACE"
    printf '%s\n' '[{"dst":"172.31.80.0/27","protocol":"kernel","scope":"link","prefsrc":"172.31.80.10","flags":[]}]' \
        > "$IPSTATE/route-dev-$IFACE"
}

tunnel_gone() {
    rm -f "$IPSTATE/link-$IFACE" "$IPSTATE/route-dev-$IFACE"
}

write_conf() { printf '%s\n' "$@" > "$CONF"; }

ff() {
    PATH="$STUBBIN:$PATH" \
    VPN_FAILFAST_CONF="$CONF" VPN_FAILFAST_PROTO="$PROTO" \
    VPN_FAILFAST_METRIC="$METRIC" VPN_FAILFAST_IFACE="$IFACE" \
    "$FAILFAST" "$@" 2>&1
}

installed() { awk -F'\t' '{print $1}' "$IPSTATE/routes" 2>/dev/null | sort | tr '\n' ' '; }
# awk, not `grep -c . || printf 0`: grep -c prints 0 AND exits 1 on an empty
# file, so the `||` fires too and the helper returns "0\n0" -- which compares
# unequal to "0" and fails a row that is actually correct. (On a MISSING file
# grep -c exits 2, the trap CLAUDE.md names.) awk answers once, always.
installed_count() { awk 'END{print NR+0}' "$IPSTATE/routes" 2>/dev/null || printf '0\n'; }
asked() { grep -c -- "$1" "$IPSTATE/calls.log" 2>/dev/null || true; }

GOOD_CONF=(54.166.22.221 44.221.89.155 "10.20.0.0/16")

# ---------------------------------------------------------------------------
printf '\nthe tunnel state machine\n'

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --status)"
grep_ok "$OUT" 'tunnel:  UP' "two gateway routes and UP: reported up"

# The case the naive test gets wrong. The interface is still there and still
# flagged UP; only the forwarding routes are gone. Counting routes on the
# interface would call this healthy.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --status)"
grep_ok "$OUT" 'tunnel:  DOWN' "UP but no gateway route: reported DOWN"

reset; tunnel_gone; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --status)"
grep_ok "$OUT" 'tunnel:  DOWN' "interface absent: reported DOWN"

printf '\ninstalling and withdrawing\n'

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --once)"; RC=$?
check "tunnel down: exit 0" "$RC" 0
check "tunnel down: all three destinations installed" "$(installed)" "10.20.0.0/16 44.221.89.155 54.166.22.221 "

# ... and on the way back up they are ALL withdrawn.
tunnel_up_state
OUT="$(ff --once)"; RC=$?
check "tunnel back up: exit 0" "$RC" 0
check "tunnel back up: every route withdrawn" "$(installed_count)" "0"

# Converging twice must not re-add. `ip route add` on an existing route answers
# "File exists" and exits 2, which would otherwise be reported as a failure on
# every single poll.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
OUT="$(ff --once)"; RC=$?
check "converging twice: exit 0, not 'File exists'" "$RC" 0
check "converging twice: still exactly three routes" "$(installed_count)" "3"
grep_none "$OUT" 'could not add' "converging twice: no error reported"

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --once)"
check "tunnel up: nothing is installed" "$(installed_count)" "0"
check "tunnel up: no route was ever added" "$(asked 'route add')" "0"

printf '\norphans, and the routes that are not ours\n'

# An orphan from a previous run under a PREVIOUS config is invisible to a
# converge that only knows today's list. --watch and --once therefore clear
# everything owned BEFORE adding anything.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
printf '9.9.9.9\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes"
OUT="$(ff --once)"; RC=$?
check "an orphan at start: exit 0" "$RC" 0
grep_none "$(installed)" '9.9.9.9' "the orphan is gone"
check "...and only the configured set remains" "$(installed)" "10.20.0.0/16 44.221.89.155 54.166.22.221 "

# ORDER, not just outcome: the orphan must be removed BEFORE anything is added.
# Asserting only the end state would pass a version that added first.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
printf '9.9.9.9\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes"
ff --once >/dev/null
FIRST_DEL="$(grep -n 'route del' "$IPSTATE/calls.log" | head -1 | cut -d: -f1)"
FIRST_ADD="$(grep -n 'route add' "$IPSTATE/calls.log" | head -1 | cut -d: -f1)"
if [[ -n "$FIRST_DEL" && -n "$FIRST_ADD" && "$FIRST_DEL" -lt "$FIRST_ADD" ]]; then
    ok "the orphan is removed BEFORE the first add"
else
    bad "the orphan is removed BEFORE the first add — del at line '$FIRST_DEL', add at '$FIRST_ADD'"
fi

# A route somebody else installed is never touched, whatever its destination —
# even when it is one of ours by address. Proto IS the identity.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '54.166.22.221\t111\t100\n' > "$IPSTATE/routes"
OUT="$(ff --once)"
check "a foreign-proto route is never deleted" "$(installed)" "54.166.22.221 "
check "...and no delete was even attempted" "$(asked 'route del')" "0"

# A destination dropped from the config while the tunnel is DOWN must not be
# left installed: that is precisely the stale route that blackholes a host.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
write_conf 54.166.22.221
OUT="$(ff --once)"
check "a destination removed from config is withdrawn" "$(installed)" "54.166.22.221 "

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
OUT="$(ff --clear)"; RC=$?
check "--clear: exit 0" "$RC" 0
check "--clear: removes everything owned" "$(installed_count)" "0"

# `ip -p -j` pretty-prints. A parser that matched only the compact spelling
# would find no owned routes and therefore withdraw NOTHING -- silently, with no
# error, leaving every destination blackholed after the tunnel came back. There
# is no louder symptom than this row.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
touch "$IPSTATE/pretty-json"
OUT="$(ff --clear)"; RC=$?
check "pretty-printed ip -j output: exit 0" "$RC" 0
check "...and routes are STILL withdrawn" "$(installed_count)" "0"

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
touch "$IPSTATE/fail-add"
OUT="$(ff --once)"; RC=$?
check "a route that cannot be added: exit 1, not 0" "$RC" 1
grep_ok "$OUT" 'could not add' "failed add: named"

printf '\nconfig validation — nothing is installed until ALL of it parses\n'

reset; tunnel_down_lingering
rm -f "$CONF"
OUT="$(ff --once)"; RC=$?
check "a missing config: exit 2, never 'no destinations'" "$RC" 2
grep_ok "$OUT" 'does not exist' "missing config: named"

reset; tunnel_down_lingering; write_conf "# only a comment" ""
OUT="$(ff --once)"; RC=$?
check "a config with no destinations: exit 2" "$RC" 2
grep_ok "$OUT" 'lists no destinations' "empty config: refuses rather than no-opping"
check "empty config: nothing installed" "$(installed_count)" "0"

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
chmod 000 "$CONF"
OUT="$(ff --once)"; RC=$?
chmod 644 "$CONF"
check "a config that exists and cannot be read: exit 2" "$RC" 2
grep_ok "$OUT" 'cannot be read' "unreadable config: named, not treated as empty"

# THE ONE THAT MATTERS. Measured against the real ip: `ip route add unreachable
# 0.0.0.0/0` is ACCEPTED and reaches netlink. One typo would blackhole the
# entire internet until somebody found the route.
reset; tunnel_down_lingering; write_conf 54.166.22.221 "0.0.0.0/0"
OUT="$(ff --once)"; RC=$?
check "0.0.0.0/0 in the config: exit 2" "$RC" 2
grep_ok "$OUT" 'blackholes the entire internet' "0.0.0.0/0: refused with the reason"
check "0.0.0.0/0: NOTHING installed, not even the valid line above it" "$(installed_count)" "0"

reset; tunnel_down_lingering; write_conf 54.166.22.221 "10.0.0.0/4"
OUT="$(ff --once)"; RC=$?
check "a prefix broader than the floor: exit 2" "$RC" 2
check "...and a partial set is never installed" "$(installed_count)" "0"

# `ip` accepts 10.9.8.1/24 and installs the whole /24 — a typo meant as a host
# route silently takes 256 addresses with it.
reset; tunnel_down_lingering; write_conf "10.9.8.1/24"
OUT="$(ff --once)"; RC=$?
check "host bits below the prefix: exit 2" "$RC" 2
grep_ok "$OUT" 'host bits set' "host bits: named"
grep_ok "$OUT" '10.9.8.0/24' "host bits: names the prefix that WOULD have been installed"

# `ip` accepts an IPv6 prefix and files it silently in the v6 table.
reset; tunnel_down_lingering; write_conf "2001:db8::/32"
OUT="$(ff --once)"; RC=$?
check "an IPv6 prefix: exit 2" "$RC" 2
grep_ok "$OUT" 'not an IPv4' "IPv6: refused explicitly rather than ignored"

reset; tunnel_down_lingering; write_conf "127.0.0.1"
OUT="$(ff --once)"; RC=$?
check "loopback: exit 2" "$RC" 2

reset; tunnel_down_lingering; write_conf "300.1.2.3"
OUT="$(ff --once)"; RC=$?
check "an out-of-range octet: exit 2" "$RC" 2

reset; tunnel_down_lingering; write_conf "10.0.0.010"
OUT="$(ff --once)"; RC=$?
check "a leading-zero octet: exit 2" "$RC" 2

reset; tunnel_down_lingering; write_conf "54.166.22.221 extra"
OUT="$(ff --once)"; RC=$?
check "two tokens on one line: exit 2" "$RC" 2

reset; tunnel_down_lingering; write_conf "54.166.22.221/33"
OUT="$(ff --once)"; RC=$?
check "a prefix length above /32: exit 2" "$RC" 2

# A /32 is reported by `ip route show` WITHOUT its prefix length, so the config
# spelling and the kernel spelling must compare equal or every converge re-adds
# a route that is already there.
reset; tunnel_down_lingering; write_conf "54.166.22.221/32"
ff --once >/dev/null
check "a /32 is normalised to the kernel's spelling" "$(installed)" "54.166.22.221 "
ff --once >/dev/null
check "...so a second converge adds nothing" "$(installed_count)" "1"

reset; tunnel_down_lingering; write_conf "  54.166.22.221   # dev" "" "# a comment"
OUT="$(ff --once)"; RC=$?
check "comments and whitespace are stripped: exit 0" "$RC" 0
check "...and the destination is installed" "$(installed)" "54.166.22.221 "

# THE SHIPPED TEMPLATE must itself be a valid config. It is the seed vpn-init
# copies and vpn-setup installs, so a typo in it is a unit that restart-loops to
# its StartLimitBurst and then sits failed -- and every row above uses a fixture,
# so not one of them would notice.
reset; tunnel_down_lingering
OUT="$(VPN_FAILFAST_CONF="$DOTFILES/examples/vpn-failfast.conf.template" \
       PATH="$STUBBIN:$PATH" "$FAILFAST" --check 2>&1)"; RC=$?
check "the shipped config template is valid: exit 0" "$RC" 0
grep_ok "$OUT" 'destination(s), all valid' "the template's destinations all parse"

printf '\nthe numeric knobs are validated, never trusted\n'

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
OUT="$(PATH="$STUBBIN:$PATH" VPN_FAILFAST_CONF="$CONF" \
       VPN_FAILFAST_PROTO=0 "$FAILFAST" --once 2>&1)"; RC=$?
check "proto 0 is refused: exit 2" "$RC" 2
grep_ok "$OUT" "unspec" "proto 0: says why it is dangerous, not just that it is wrong"

OUT="$(PATH="$STUBBIN:$PATH" VPN_FAILFAST_CONF="$CONF" \
       VPN_FAILFAST_PROTO=soon "$FAILFAST" --once 2>&1)"; RC=$?
check "a non-numeric proto: exit 2, not a silent 0" "$RC" 2

OUT="$(PATH="$STUBBIN:$PATH" VPN_FAILFAST_CONF="$CONF" \
       VPN_FAILFAST_PROTO=256 "$FAILFAST" --once 2>&1)"; RC=$?
check "a proto above 255: exit 2" "$RC" 2

OUT="$(PATH="$STUBBIN:$PATH" VPN_FAILFAST_CONF="$CONF" \
       VPN_FAILFAST_MIN_PREFIX=0 "$FAILFAST" --once 2>&1)"; RC=$?
check "a min-prefix of 0 is refused: exit 2" "$RC" 2

printf '\nCLI\n'

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --clear --oops)"; RC=$?
check "a second argument is refused: exit 2" "$RC" 2
OUT="$(ff --nonsense)"; RC=$?
check "an unknown argument: exit 2" "$RC" 2
OUT="$(ff --help)"; RC=$?
check "--help: exit 0" "$RC" 0
grep_ok "$OUT" 'KERNEL STATE ONLY' "--help prints the header's invariant"

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --check)"; RC=$?
check "--check on a good config: exit 0" "$RC" 0
check "--check installs nothing" "$(installed_count)" "0"

printf '\nthe notifier — and its body is a CONSTANT\n'

nf() {
    PATH="$STUBBIN:$PATH" \
    VPN_NOTIFY_IFACE="$IFACE" VPN_NOTIFY_THRESHOLD=90 \
    VPN_NOTIFY_STATE="$IPSTATE/notify" VPN_NOTIFY_NOW="$1" \
    "$NOTIFY" "${@:2}" 2>&1
}
NOW=1790000000

reset; tunnel_up_state
OUT="$(nf "$NOW" --once)"; RC=$?
check "tunnel up: exit 0" "$RC" 0
check "tunnel up: nothing is notified" "$(grep -c . "$IPSTATE/notify.count" 2>/dev/null || echo 0)" "0"

# First observation of an outage records the start and says nothing: the whole
# point of the threshold is that the 17-of-41 self-healing outages never notify.
reset; tunnel_down_lingering
OUT="$(nf "$NOW" --once)"
check "first sight of a down tunnel: no notification yet" "$(grep -c . "$IPSTATE/notify.count" 2>/dev/null || echo 0)" "0"
OUT="$(nf "$((NOW + 89))" --once)"
check "one second under the threshold: still silent" "$(grep -c . "$IPSTATE/notify.count" 2>/dev/null || echo 0)" "0"
OUT="$(nf "$((NOW + 90))" --once)"
check "at the threshold: notified" "$(grep -c . "$IPSTATE/notify.count" 2>/dev/null || echo 0)" "1"
# ... and exactly once, however long it stays down.
OUT="$(nf "$((NOW + 900))" --once)"
check "still down much later: NOT notified again" "$(grep -c . "$IPSTATE/notify.count" 2>/dev/null || echo 0)" "1"

BODY_A="$(cat "$IPSTATE/notify.argv")"

# The same outage, with a completely different config and a different interface
# name, must produce a BYTE-IDENTICAL notification. GNOME renders body-markup
# including <a href>, so anything derived from anything is a phishing sink, and
# the only way to keep the body constant is to assert that it is.
reset; tunnel_gone
write_conf "10.20.0.0/16"
OUT="$(nf "$NOW" --once)"; OUT="$(nf "$((NOW + 90))" --once)"
BODY_B="$(cat "$IPSTATE/notify.argv")"
check "the notification is byte-identical across tunnel state and config" "$BODY_B" "$BODY_A"
grep_none "$BODY_A" 'tun0' "the body names no interface"
grep_none "$BODY_A" '10.20' "the body carries nothing from the config"
grep_none "$BODY_A" 'http' "the body carries no URL"
grep_none "$BODY_A" '<a ' "the body carries no markup"
grep_ok "$BODY_A" 'urgency=critical' "the notification is critical, so GNOME keeps it up"

# Back up: the state is withdrawn, so the NEXT outage notifies again.
reset; tunnel_down_lingering
nf "$NOW" --once >/dev/null; nf "$((NOW + 90))" --once >/dev/null
tunnel_up_state
OUT="$(nf "$((NOW + 100))" --once)"
grep_ok "$OUT" 'tunnel back up' "recovery is logged"
tunnel_down_lingering
nf "$((NOW + 200))" --once >/dev/null
nf "$((NOW + 290))" --once >/dev/null
check "a SECOND outage notifies again" "$(grep -c . "$IPSTATE/notify.count" 2>/dev/null || echo 0)" "2"

# A clock that jumps backwards (a resume, an NTP step) must re-anchor rather than
# make the outage look enormous or silently restart its timer.
reset; tunnel_down_lingering
nf "$NOW" --once >/dev/null
OUT="$(nf "$((NOW - 5000))" --once)"
grep_ok "$OUT" 'clock moved backwards' "a backwards clock is named, not silently absorbed"
check "...and no notification was raised on it" "$(grep -c . "$IPSTATE/notify.count" 2>/dev/null || echo 0)" "0"

reset; tunnel_down_lingering
OUT="$(PATH="$STUBBIN:$PATH" VPN_NOTIFY_STATE="$IPSTATE/notify" \
       VPN_NOTIFY_THRESHOLD=soon "$NOTIFY" --once 2>&1)"; RC=$?
check "a non-numeric threshold: exit 2, not a silent 0" "$RC" 2

reset; tunnel_up_state
OUT="$(nf "$NOW" --status)"; RC=$?
check "--status: exit 0" "$RC" 0
grep_ok "$OUT" 'tunnel:    UP' "--status reports the tunnel"
OUT="$(nf "$NOW" --once --oops)"; RC=$?
check "the notifier refuses a second argument: exit 2" "$RC" 2

printf '\nvpn-render — an unresolved placeholder is a hard error\n'

TPL="$T/tpl"
printf 'ExecStart="__VPN_DOTFILES__/scripts/vpn-failfast.sh" --watch\n' > "$TPL"
OUT="$(VPN_RENDER_DOTFILES=/opt/x "$RENDER" "$TPL" 2>&1)"; RC=$?
check "a template renders: exit 0" "$RC" 0
check "...with the checkout path substituted" "$OUT" 'ExecStart="/opt/x/scripts/vpn-failfast.sh" --watch'

printf 'ExecStart=__VPN_MISSING__/x\n' > "$TPL"
OUT="$(VPN_RENDER_DOTFILES=/opt/x "$RENDER" "$TPL" 2>&1)"; RC=$?
check "an unresolved placeholder: exit 1, never a blank" "$RC" 1
grep_ok "$OUT" 'unresolved placeholder' "unresolved placeholder: named"

printf 'ExecStart="__VPN_DOTFILES__/x"\n' > "$TPL"
OUT="$(VPN_RENDER_DOTFILES='/opt/we"ird' "$RENDER" "$TPL" 2>&1)"; RC=$?
check "a checkout path containing a double quote: exit 1" "$RC" 1

OUT="$("$RENDER" "$T/no-such-template" 2>&1)"; RC=$?
check "a missing template: exit 1" "$RC" 1

# The real unit must actually render — a template that no row renders is a
# template whose placeholder spelling nothing checks.
OUT="$(VPN_RENDER_DOTFILES=/opt/x "$RENDER" "$DOTFILES/systemd/vpn-failfast.service" 2>&1)"; RC=$?
check "the shipped unit renders: exit 0" "$RC" 0
grep_ok "$OUT" '/opt/x/scripts/vpn-failfast.sh' "the shipped unit's ExecStart is substituted"
grep_none "$OUT" '__VPN_' "the rendered unit carries no placeholder"
grep_ok "$OUT" 'ExecStopPost' "the rendered unit keeps its withdraw-on-stop hook"

printf '\nthe reporter — DST, the join, and refusing to invent a clean week\n'

rep() { "$REPORT" --app-dir "$FIXTURES" --ovpn-dir "$T/no-ovpn" "$@" 2>&1; }
J="$(rep --days 7 --json)"
jget() { printf '%s' "$J" | python3 -c "import json,sys;print(json.load(sys.stdin)['$1'])"; }

# THE DST ROW. The fixture carries both +03:00 and +02:00 in one file. Anything
# that pins the literal offset drops half of it and reports a quieter week.
check "events on BOTH sides of the DST change are counted" "$(jget browser_opens)" "2"
check "...and so are the state transitions" "$(jget outages)" "2"
check "the +02:00 SAML timeout is seen" "$(jget saml_timeouts)" "1"

# THE JOIN ROW. The fixture writes each AUTH_FAILED three times, exactly as the
# client does: CM received, CM processsing, and the openvpn line. One event.
check "three log lines for one AUTH_FAILED collapse to one" "$(jget auth_failed)" "2"
check "...which is then 1:1 with the browser opens, as measured live" \
      "$(jget auth_failed)" "$(jget browser_opens)"

# Durations come from the openvpn epoch, so a DST change inside a span cannot
# lengthen or shorten it: 20s + 930s.
check "outage durations are computed from the openvpn epoch" "$(jget downtime_seconds)" "950"
check "open -> ACS latency" "$(jget open_to_acs_p50)" "10.0"
check "SAML timeout -> next attempt" "$(jget timeout_to_next_attempt_p50)" "299.0"
check "the vendor's 'Succesfully' spelling is matched" "$(jget assertions)" "1"

# Untimestamped continuation lines (stack traces) must not be attributed to the
# previous line's time; the fixture has two.
check "untimestamped continuation lines are skipped" "$(jget acs_unclean_stops)" "1"

OUT="$("$REPORT" --app-dir "$T/no-such-a" --ovpn-dir "$T/no-such-b" 2>&1)"; RC=$?
check "no log directory at all: exit 2, never a clean report" "$RC" 2
grep_ok "$OUT" 'neither log directory exists' "missing dirs: named"

mkdir -p "$T/empty-logs"
OUT="$("$REPORT" --app-dir "$T/empty-logs" --ovpn-dir "$T/no-such-b" 2>&1)"; RC=$?
check "a log dir with no logs in the window: exit 2" "$RC" 2
grep_ok "$OUT" 'NOT "no outages"' "empty window: refuses to read as a clean week"

OUT="$(rep --days 0)"; RC=$?
check "--days 0: exit 2" "$RC" 2

printf '\nthe redactor covers what the reporter reads\n'

RED="$DOTFILES/scripts/redact-secrets.sh"
LINE="$(grep -m1 'Attempting to open browser' "$FIXTURES/aws_vpn_client_dst.log")"
check "a fixture re-auth URL is left alone (it carries no SAMLRequest)" \
      "$(printf '%s' "$LINE" | "$RED")" "$LINE"
CHAL="$(grep -m1 -o 'AUTH_FAILED,CRV1:[^ ]*' "$FIXTURES/aws_vpn_client_dst.log")"
grep_ok "$(printf '%s' "$CHAL" | "$RED")" 'REDACTED:vpn-auth-challenge' \
      "the fixture's real CRV1 challenge IS redacted"

# ---------------------------------------------------------------------------
TOTAL=$(( PASS + FAIL ))
printf '\n'
# The suite asserts its own size: a row silently deleted, or a fixture helper
# that stopped emitting one, is otherwise indistinguishable from a clean run.
EXPECTED_ROWS=112
if (( TOTAL != EXPECTED_ROWS )); then
    printf '\033[1;31mFATAL\033[0m: ran %d checks, expected %d — a row was added or lost.\n' \
        "$TOTAL" "$EXPECTED_ROWS" >&2
    printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
    exit 2
fi
printf 'vpn fail-fast state table: %d/%d checks passed\n' "$PASS" "$TOTAL"
(( FAIL == 0 )) || exit 1
exit 0
