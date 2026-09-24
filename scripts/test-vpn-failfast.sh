#!/usr/bin/env bash
#
# scripts/test-vpn-failfast.sh
# ============================
#
# State table for scripts/vpn-failfast.sh, scripts/vpn-notify.sh,
# scripts/setup-vpn-failfast.sh and scripts/vpn-log-report.py.
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
SETUP="$DOTFILES/scripts/setup-vpn-failfast.sh"
REPORT="$DOTFILES/scripts/vpn-log-report.py"
FIXTURES="$DOTFILES/tests/fixtures/vpn"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
grep_ok()   { if grep -q -- "$2" <<<"$1"; then ok "$3"; else bad "$3 — output did not contain '$2'"; fi; }
grep_none() { if grep -q -- "$2" <<<"$1"; then bad "$3 — output unexpectedly contained '$2'"; else ok "$3"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for f in "$FAILFAST" "$NOTIFY" "$SETUP" "$REPORT"; do
    [[ -x "$f" ]] || fatal "cannot execute $f"
done
[[ -r "$FIXTURES/aws_vpn_client_dst.log" ]] || fatal "missing DST fixture in $FIXTURES"
command -v python3 >/dev/null || fatal "python3 is required"
# Required, not optional. The unit rows below are the only thing standing between
# a misplaced directive and a unit that cannot start, and "systemd-analyze is
# missing so we skipped them" is the could-not-run-reads-as-a-pass shape this
# repo keeps finding. Present on ubuntu-latest and on every machine with systemd.
command -v systemd-analyze >/dev/null || fatal "systemd-analyze is required to verify the units"
# The drift rows below exercise _vpn_drift, which is zsh. Same requirement, and
# the same reason, as scripts/test-dotfiles-guard.sh: a skipped check is not a
# passing one.
command -v zsh >/dev/null || fatal "zsh is required to exercise the vpn-doctor helpers"

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

# FAMILY IS STATE, NOT NOISE. Stripping -6 alongside -j into one fixture file
# would make the "drop the -6" mutant unkillable by construction: the stub would
# answer identically with the flag and without it, so a sweep would burn a cycle
# against a written-down expected verdict. It is consumed into `fam` and selects
# a SEPARATE fixture file, so a v6 query that lost its flag reads the v4 table
# and a row sees it. Note $* is logged ABOVE, before this parse, which is what
# lets a row grep for `-6 route del`.
json=0
fam=4
args=()
for a in "$@"; do
  case "$a" in
    -j|-json) json=1 ;;
    -4) fam=4 ;;
    -6) fam=6 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]}"

# Two fixture files. The v4 one and its JSON are byte-identical to what this
# stub emitted before families existed, so every pre-existing row, installed()
# and has_route() are untouched.
if [ "$fam" = "6" ]; then RF="$IPSTATE/routes6"; else RF="$IPSTATE/routes"; fi

# Family/literal mismatch is an ERROR, exactly as the real tool -- and
# implementing this one behaviour is what makes "swap the family flag" and "drop
# the -4" killable without a single extra row, because the SUBJECT fails rather
# than the stub quietly recording the wrong thing. Measured against
# iproute2-6.19.0 on this box:
#   ip -6 route get 10.9.8.7 -> Error: inet6 prefix is expected rather than "10.9.8.7".  rc 1
#   ip -4 route get ::1      -> Error: inet prefix is expected rather than "::1".        rc 1
fam_check() {
  case "$fam:$1" in
    6:*:*) : ;;
    6:*)   echo "Error: inet6 prefix is expected rather than \"$1\"." >&2; exit 1 ;;
    4:*:*) echo "Error: inet prefix is expected rather than \"$1\"." >&2; exit 1 ;;
  esac
}

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
          if [ -r "$RF" ]; then
            out="$(python3 - "$RF" "$want" "${IPSTATE}/pretty-json" "$fam" <<'PY'
import json,os,sys
rows=[]
fam=sys.argv[4]
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    dst,proto,metric = line.split('\t')
    if proto != sys.argv[2]: continue
    if fam == "6":
        # MEASURED, not copied from the v4 row above: `ip -j -6 route show proto
        # N` emits NO "protocol" key at all -- iproute2 suppresses the attribute
        # it filtered on. A fixture carrying "protocol":66 here would describe
        # output `ip` never produces, and the parser under test would be proved
        # correct against fiction. A reject route's nexthop device is lo.
        rows.append({"type":"unreachable","dst":dst,"dev":"lo",
                     "metric":int(metric),"flags":[],"pref":"medium"})
    else:
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
      get)
        # `route get` is a FIXTURE, not a simulation. Its three outcomes are
        # recorded from the real tool and replayed verbatim, because the whole
        # point of the doctor's canary is that it must CLASSIFY rc and stderr
        # rather than grep stdout -- and a simulation would encode whatever the
        # author already believed. A missing fixture is exit 99, never a quiet
        # default that would let a doctor row pass on nothing at all.
        dst="${3:-}"
        fam_check "$dst"
        base="$IPSTATE/get-$dst"
        if [ -r "$base.rc" ]; then
          [ -r "$base.out" ] && cat "$base.out"
          [ -r "$base.err" ] && cat "$base.err" >&2
          exit "$(cat "$base.rc")"
        fi
        echo "ip stub: no route get fixture for '$dst'" >&2; exit 99 ;;
      add|del)
        # Grammar exactly as the real one: `route add|del unreachable <dst> proto
        # <n> [metric <m>]`.
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
        fam_check "$dst"
        touch "$RF"
        if [ "$op" = "add" ]; then
          [ -e "$IPSTATE/fail-add" ] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
          # awk only: `grep` here is a ugrep shim, and -P is one of the GNU
          # extensions this repo's notes warn about resolving differently.
          if awk -F'\t' -v d="$dst" '$1==d{found=1} END{exit !found}' "$RF"; then
            echo "RTNETLINK answers: File exists" >&2; exit 2
          fi
          printf '%s\t%s\t%s\n' "$dst" "$proto" "$metric" >> "$RF"
          exit 0
        fi
        [ -e "$IPSTATE/fail-del" ] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
        # Family-scoped failure, so a row can prove clear_owned reports a v6
        # failure even when the v4 half succeeded -- an rc that only tracked the
        # last family would report exactly that case as clean.
        if [ "$fam" = "6" ] && [ -e "$IPSTATE/fail-del6" ]; then
          echo "RTNETLINK answers: Operation not permitted" >&2; exit 2
        fi
        # Reports success and removes NOTHING. This is not a hypothetical: the
        # subject treats "No such process" as success, so a delete that
        # addressed the wrong route is indistinguishable from one that worked.
        # The re-read guard in clear_owned is the only thing that catches it,
        # and without this sentinel that guard has no way to be exercised.
        [ -e "$IPSTATE/del-noop" ] && exit 0
        # THE DELETE HONOURS `metric` WHEN IT IS GIVEN, and matches on dst+proto
        # when it is not -- which is the difference the v6 delete turns on.
        # Measured: `ip -6 route del <dst> proto 66 metric 1024` against a
        # metric-4242 route answers "No such process", which del_route treats as
        # SUCCESS. So one metric drift would make a v6 blackhole permanent while
        # clear_owned reported it cleared. A stub that ignored metric could not
        # tell those two commands apart and the mutant would be unkillable.
        if [ -n "$metric" ]; then
          if ! awk -F'\t' -v d="$dst" -v p="$proto" -v m="$metric" \
               '$1==d && $2==p && $3==m{found=1} END{exit !found}' "$RF"; then
            echo "RTNETLINK answers: No such process" >&2; exit 2
          fi
          awk -F'\t' -v d="$dst" -v p="$proto" -v m="$metric" \
              '!($1==d && $2==p && $3==m)' "$RF" > "$IPSTATE/.r" \
            && mv -f "$IPSTATE/.r" "$RF"
          exit 0
        fi
        if ! awk -F'\t' -v d="$dst" -v p="$proto" '$1==d && $2==p{found=1} END{exit !found}' "$RF"; then
          echo "RTNETLINK answers: No such process" >&2; exit 2
        fi
        awk -F'\t' -v d="$dst" -v p="$proto" '!($1==d && $2==p)' "$RF" > "$IPSTATE/.r" \
          && mv -f "$IPSTATE/.r" "$RF"
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

# ---------------------------------------------------------------------------
# The `sudo` stub — and it is a BUG FIX, not scaffolding
# ---------------------------------------------------------------------------
# The installer rows below set VPN_SETUP_ALLOW_WORKTREE=1, which is the whole
# point of one of them. With the REAL PATH the guard at setup-vpn-failfast.sh:93
# then does not exit: execution runs on through the readable-config check,
# `--check` and the placeholder grep, and reaches
#
#   sudo install -m 755 -o root -g root "$SCRIPT_SRC" /usr/local/bin/vpn-failfast.sh
#
# where $SCRIPT_SRC is the BRANCH's script. The row's needle is printed thirty
# lines earlier and the `|| true` swallows the status, so the row passes whether
# or not an install happened. Only the absence of a usable `sudo` stopped it on a
# developer's machine; on CI, which has passwordless sudo, the block actually
# ran — so the green history never once exercised the inert path, and
# `install(1)` writes IN PLACE, which means rewriting the running root daemon's
# file underneath it. The header of this file claims "No sudo, no root"; that
# claim was part of the defect.
#
# Recording and REFUSING (exit 1) is what a developer's machine already does, so
# it is the behaviour every green run to date was actually measured against.
cat > "$STUBBIN/sudo" <<'STUB'
#!/usr/bin/env bash
[ -n "${IPSTATE:-}" ] || { echo "sudo stub: no IPSTATE" >&2; exit 99; }
printf '%s\n' "$*" >> "$IPSTATE/sudo.log"

# systemctl and sysctl are NEVER executed, only recorded. The machine running
# this suite has a live system manager holding a root VPN daemon, and a stub
# that shelled out to `systemctl` would be one typo away from stopping it.
verb="${1:-}"
case "$verb" in
  install | rm | rmdir | mkdir) ;;
  *) exit 0 ;;
esac

# The file verbs DO run, because a row that only asserts argv cannot tell an
# installer that writes the drop-in from one that does not -- and the
# post-install check reads the file back. They run only under VPN_SETUP_PREFIX,
# and with no prefix set nothing is written at all.
pfx="${VPN_SETUP_PREFIX:-}"
if [ -z "$pfx" ]; then
  echo "sudo stub: refused (no VPN_SETUP_PREFIX, so nothing may be written)" >&2
  exit 1
fi

has_d=0
for a in "$@"; do [ "$a" = "-d" ] && has_d=1; done
shift

# -o root / -g root cannot work unprivileged, so they are stripped -- the
# RECORDED argv above still carries them, which is what a row asserts.
flags=(); ops=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o | -g) shift 2 ;;
    -m)      flags+=("$1" "${2:-}"); shift 2 ;;
    -*)      flags+=("$1"); shift ;;
    *)       ops+=("$1"); shift ;;
  esac
done

# EVERY DESTINATION MUST BE INSIDE THE PREFIX, checked here rather than trusted
# to the caller. This is what makes it impossible for a row to write to the real
# /etc by construction instead of by everyone remembering. Sources may of course
# live outside it, so for `install` without -d only the LAST operand is a target.
if [ "$verb" = "install" ] && [ "$has_d" -eq 0 ] && [ "${#ops[@]}" -gt 1 ]; then
  targets=("${ops[$((${#ops[@]} - 1))]}")
else
  targets=("${ops[@]}")
fi
for t in "${targets[@]}"; do
  case "$t" in
    /*) case "$t" in
          "$pfx"/*) ;;
          *) echo "sudo stub: REFUSED a destination outside the prefix: $t" >&2; exit 97 ;;
        esac ;;
  esac
done
exec "$verb" "${flags[@]}" "${ops[@]}"
STUB
chmod +x "$STUBBIN/sudo" || fatal setup

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
    : > "$IPSTATE/routes6"
    : > "$IPSTATE/sudo.log"
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

# --watch, backgrounded. POLL=1 so a converge cycle is fast; `ip monitor` is
# stubbed to exit 1, so the loop falls to its poll -- which is the CORRECTNESS
# path and the one worth testing anyway.
watch_start() {
    PATH="$STUBBIN:$PATH" \
    VPN_FAILFAST_CONF="$CONF" VPN_FAILFAST_PROTO="$PROTO" \
    VPN_FAILFAST_METRIC="$METRIC" VPN_FAILFAST_IFACE="$IFACE" \
    VPN_FAILFAST_POLL=1 \
    "$FAILFAST" --watch >"$IPSTATE/watch.out" 2>&1 &
    WATCH_PID=$!
}
watch_stop() {
    [[ -n "${WATCH_PID:-}" ]] || return 0
    kill "$WATCH_PID" 2>/dev/null
    wait "$WATCH_PID" 2>/dev/null
    WATCH_PID=""
}
# Bounded wait on a predicate, never a fixed sleep: a row that sleeps long enough
# today is a row that flakes on a loaded CI runner, and this repo has already
# shipped one of those.
wait_for() {
    local budget="$1"; shift
    local deadline=$(( SECONDS + budget ))
    while (( SECONDS < deadline )); do
        if "$@"; then return 0; fi
        sleep 0.2
    done
    return 1
}
# Invoked INDIRECTLY, as `wait_for 15 has_route <dst>`, which shellcheck cannot
# see. BOTH codes: the pinned pre-commit shellcheck (v0.9) calls this SC2317,
# newer ones call it SC2329, and disabling only the one your local binary emits
# passes here and fails the hook.
# shellcheck disable=SC2317,SC2329
has_route()  { awk -F'\t' -v d="$1" '$1==d{f=1} END{exit !f}' "$IPSTATE/routes" 2>/dev/null; }
# shellcheck disable=SC2317,SC2329
lacks_route() { ! has_route "$1"; }

# LC_ALL=C on EVERY sort here, and it is not decoration. `::/1` and `8000::/1`
# order DIFFERENTLY under en_US.UTF-8 (which ignores punctuation when
# collating) than under C/POSIX (where ':' is 0x3A and '8' is 0x38). A
# developer machine is usually the former and a CI runner the latter, so an
# expectation written without this passes locally and fails on CI -- which is
# exactly what happened, on four rows, the first time this was pushed. Pinning
# the collation makes the expected string a property of the code rather than of
# whoever ran it.
installed() { awk -F'\t' '{print $1}' "$IPSTATE/routes" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }
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
check "tunnel up: no route was ever added" "$(asked '-4 route add')" "0"

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
FIRST_DEL="$(grep -n -- '-4 route del' "$IPSTATE/calls.log" | head -1 | cut -d: -f1)"
FIRST_ADD="$(grep -n -- '-4 route add' "$IPSTATE/calls.log" | head -1 | cut -d: -f1)"
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
check "...and no delete was even attempted" "$(asked '-4 route del')" "0"

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

printf '\nthe --watch path, which is what the unit actually runs\n'

# A link that EXISTS but is not UP, with its routes still listed. Real: the
# kernel keeps routes over a carrier-down interface and marks them `linkdown`
# (docker0 is in exactly that state on this box right now). Without this row the
# UP-flag test is unreachable, because every other fixture either has the flag or
# has no interface at all — measured: a mutant deleting the check SURVIVED.
reset; write_conf "${GOOD_CONF[@]}"
printf '[{"ifindex":186,"ifname":"tun0","flags":["POINTOPOINT","MULTICAST","NOARP"],"operstate":"DOWN"}]\n' \
    > "$IPSTATE/link-$IFACE"
printf '%s\n' '[{"dst":"0.0.0.0/1","gateway":"172.31.80.1","flags":["linkdown"]}]' \
    > "$IPSTATE/route-dev-$IFACE"
OUT="$(ff --status)"
grep_ok "$OUT" 'tunnel:  DOWN' "an interface that is present but NOT UP: reported DOWN"
OUT="$(ff --once)"
check "...and the fail-fast routes are installed" "$(installed)" "10.20.0.0/16 44.221.89.155 54.166.22.221 "

# Orphan-clear-at-start, through --watch rather than --once. The unit runs
# --watch; a mutant removing clear_owned from THAT branch alone survived every
# row above, because all of them go through --once.
reset; tunnel_down_lingering; write_conf 54.166.22.221
printf '9.9.9.9\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes"
watch_start
if wait_for 15 has_route 54.166.22.221; then ok "--watch converges"; else bad "--watch converges — timed out"; fi
FIRST_DEL="$(grep -n -- '-4 route del' "$IPSTATE/calls.log" | head -1 | cut -d: -f1)"
FIRST_ADD="$(grep -n -- '-4 route add' "$IPSTATE/calls.log" | head -1 | cut -d: -f1)"
if [[ -n "$FIRST_DEL" && -n "$FIRST_ADD" && "$FIRST_DEL" -lt "$FIRST_ADD" ]]; then
    ok "--watch removes an orphan BEFORE its first add"
else
    bad "--watch removes an orphan BEFORE its first add — del '$FIRST_DEL', add '$FIRST_ADD'"
fi
watch_stop

# A route carrying OUR proto that appears while the daemon is running -- another
# instance, or an operator's hand -- is reclaimed by the next converge. This is
# the only path on which converge's own removal loop can fire: --once clears
# everything up front, so that loop is dead code there, which is exactly why a
# mutant gutting it survived.
reset; tunnel_down_lingering; write_conf 54.166.22.221
watch_start
if wait_for 15 has_route 54.166.22.221; then ok "--watch installs the configured destination"; else bad "--watch installs the configured destination — timed out"; fi
printf '8.8.4.4\t%s\t%s\n' "$PROTO" "$METRIC" >> "$IPSTATE/routes"
if wait_for 15 lacks_route 8.8.4.4; then ok "a route appearing under our proto mid-run is reclaimed"; else bad "a route appearing under our proto mid-run is reclaimed — timed out"; fi
check "...and the configured destination is untouched" "$(installed)" "54.166.22.221 "
watch_stop

printf '\nthe IPv6 block (DO-704) — and its polarity is the OPPOSITE of the above\n'

# Armed. The block is a --watch-only capability, so anything that must actually
# INSTALL it goes through watch_start6 rather than --once.
ff6() {
    PATH="$STUBBIN:$PATH" \
    VPN_FAILFAST_CONF="$CONF" VPN_FAILFAST_PROTO="$PROTO" \
    VPN_FAILFAST_METRIC="$METRIC" VPN_FAILFAST_IFACE="$IFACE" \
    VPN_FAILFAST_IPV6=block \
    "$FAILFAST" "$@" 2>&1
}
watch_start6() {
    PATH="$STUBBIN:$PATH" \
    VPN_FAILFAST_CONF="$CONF" VPN_FAILFAST_PROTO="$PROTO" \
    VPN_FAILFAST_METRIC="$METRIC" VPN_FAILFAST_IFACE="$IFACE" \
    VPN_FAILFAST_POLL=1 VPN_FAILFAST_IPV6=block \
    "$FAILFAST" --watch >"$IPSTATE/watch.out" 2>&1 &
    WATCH_PID=$!
}
installed6()       { awk -F'\t' '{print $1}' "$IPSTATE/routes6" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }
installed6_count() { awk 'END{print NR+0}' "$IPSTATE/routes6" 2>/dev/null || printf '0\n'; }
# Invoked INDIRECTLY through wait_for, which shellcheck cannot see. BOTH codes:
# the pinned v0.9 says SC2317 and newer ones say SC2329.
# shellcheck disable=SC2317,SC2329
has_route6()   { awk -F'\t' -v d="$1" '$1==d{f=1} END{exit !f}' "$IPSTATE/routes6" 2>/dev/null; }
# shellcheck disable=SC2317,SC2329
lacks_route6() { ! has_route6 "$1"; }
# shellcheck disable=SC2317,SC2329
has_both_halves() { has_route6 '::/1' && has_route6 '8000::/1'; }
# awk, never `grep -c ... || echo 0`: grep -c prints 0 AND exits 1 on no match,
# so the `||` fires too and the helper answers "0\n0".
# shellcheck disable=SC2317,SC2329
converged_at_least() {
    local n; n="$(awk '/route show dev tun0/{c++} END{print c+0}' "$IPSTATE/calls.log" 2>/dev/null)"
    [[ "${n:-0}" -ge "$1" ]]
}
# shellcheck disable=SC2317,SC2329
watch_said() { grep -q -- "$1" "$IPSTATE/watch.out" 2>/dev/null; }
count_in() { awk -v pat="$1" 'index($0,pat){c++} END{print c+0}' "$2" 2>/dev/null; }

# --- the knob -------------------------------------------------------------
# An unknown value must be exit 2 in BOTH directions. Defaulting to `off` would
# silently disarm a machine that asked to be armed; defaulting to `block` would
# blackhole IPv6 off a typo. This validation is also what the installer uses as
# its post-install check, so it has to be fatal in every mode.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(PATH="$STUBBIN:$PATH" VPN_FAILFAST_CONF="$CONF" \
       VPN_FAILFAST_IPV6=blocked "$FAILFAST" --check 2>&1)"; RC=$?
check "an unknown VPN_FAILFAST_IPV6: exit 2" "$RC" 2
grep_ok "$OUT" 'VPN_FAILFAST_IPV6' "unknown knob value: names the knob"
check "an unknown knob value installs nothing" "$(installed6_count)" "0"

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --once)"
check "the default is off: tunnel up, no v6 block installed" "$(installed6_count)" "0"
check "...and no v6 route was even attempted" "$(asked '-6 route add')" "0"

# --- polarity -------------------------------------------------------------
# THE SINGLE STRONGEST ROW IN THIS SECTION. Asserting the argv byte for byte
# kills wrong family, wrong verb, wrong destination, missing proto and missing
# metric at once, and replaces five fuzzy ones. Same idiom the notification body
# uses, and for the same reason: the only way to keep something constant is to
# check that it IS constant.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
watch_start6
if wait_for 15 has_both_halves; then ok "armed + tunnel UP: the block is installed"; else bad "armed + tunnel UP: the block is installed — timed out"; fi
check "armed + UP: EXACTLY the two halves, nothing else" "$(installed6)" "8000::/1 ::/1 "
grep_ok "$(cat "$IPSTATE/calls.log")" '^-6 route add unreachable ::/1 proto 66 metric 4242$' \
        "the v6 install argv is exact, byte for byte"
watch_stop

# ... and the mirror. Tunnel DOWN means there is no tunnel to leak around, so
# the block comes OFF and the v4 fail-fast routes go ON.
reset; tunnel_down_lingering; write_conf 54.166.22.221
printf '::/1\t%s\t%s\n8000::/1\t%s\t%s\n' "$PROTO" "$METRIC" "$PROTO" "$METRIC" > "$IPSTATE/routes6"
watch_start6
if wait_for 15 has_route 54.166.22.221; then ok "armed + tunnel DOWN: the v4 half is installed"; else bad "armed + tunnel DOWN: the v4 half is installed — timed out"; fi
if wait_for 15 lacks_route6 '::/1'; then ok "armed + tunnel DOWN: the v6 block is withdrawn"; else bad "armed + tunnel DOWN: the v6 block is withdrawn — timed out"; fi
check "...and withdrawn completely, not half of it" "$(installed6_count)" "0"
watch_stop

# Both ways round, under one daemon: this is the transition that actually
# happens on this machine several times a day.
reset; tunnel_up_state; write_conf 54.166.22.221
watch_start6
if wait_for 15 has_both_halves; then ok "UP: block on"; else bad "UP: block on — timed out"; fi
tunnel_down_lingering
if wait_for 15 lacks_route6 '::/1'; then ok "UP->DOWN: block off, without a restart"; else bad "UP->DOWN: block off — timed out"; fi
if wait_for 15 has_route 54.166.22.221; then ok "UP->DOWN: v4 fail-fast on"; else bad "UP->DOWN: v4 fail-fast on — timed out"; fi
tunnel_up_state
if wait_for 15 has_both_halves; then ok "DOWN->UP: block back on"; else bad "DOWN->UP: block back on — timed out"; fi
if wait_for 15 lacks_route 54.166.22.221; then ok "DOWN->UP: v4 fail-fast back off"; else bad "DOWN->UP: v4 fail-fast back off — timed out"; fi
watch_stop

# IDEMPOTENCE, and it is not cosmetic. If the up-branch cleared and re-added the
# block each pass there would be a real unblocked window 17,280 times a day —
# which is the leak this exists to close. One transition, one log line, however
# many polls run.
reset; tunnel_up_state; write_conf 54.166.22.221
watch_start6
if wait_for 15 has_both_halves; then ok "armed + UP: converged"; else bad "armed + UP: converged — timed out"; fi
# A predicate, never a fixed sleep: a row that sleeps long enough today is a row
# that flakes on a loaded CI runner, and this repo has already shipped one.
if wait_for 20 converged_at_least 4; then ok "the daemon kept converging"; else bad "the daemon kept converging — timed out"; fi
check "four converges later: still exactly the two halves" "$(installed6)" "8000::/1 ::/1 "
check "...and ::/1 was announced ONCE, not once per poll" \
      "$(count_in 'fail-fast ON  ::/1' "$IPSTATE/watch.out")" "1"
check "...and it was never deleted and re-added" "$(asked '-6 route del')" "0"
watch_stop

# --- --once refuses the block --------------------------------------------
# --once leaves no daemon and no ExecStopPost, so `--once` with the tunnel up
# would blackhole global IPv6 until somebody found the route.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(ff6 --once)"; RC=$?
check "--once with the block armed: exit 0" "$RC" 0
check "--once refuses to install the block" "$(installed6_count)" "0"
grep_ok "$OUT" 'watch-only capability' "--once says WHY it refused"

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
OUT="$(ff6 --once)"
check "--once still installs the IPv4 half" "$(installed)" "10.20.0.0/16 44.221.89.155 54.166.22.221 "

# --- withdrawal is UNCONDITIONAL -----------------------------------------
# Not gated on the arming switch, anywhere. "we were not armed" is never a
# reason to leave a blackhole installed, and disarming then restarting has to
# actually withdraw.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '::/1\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes6"
OUT="$(ff --clear)"; RC=$?
check "a DISARMED daemon still clears a v6 owned route: exit 0" "$RC" 0
check "...and the route is gone" "$(installed6_count)" "0"

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
printf '::/1\t%s\t%s\n8000::/1\t%s\t%s\n' "$PROTO" "$METRIC" "$PROTO" "$METRIC" > "$IPSTATE/routes6"
OUT="$(ff --clear)"; RC=$?
check "--clear clears BOTH families in one call: exit 0" "$RC" 0
check "--clear: v4 empty" "$(installed_count)" "0"
check "--clear: v6 empty" "$(installed6_count)" "0"

# A v6 route this tool owns that is NOT one of today's halves is an older
# release's constant, or an operator's hand. Same rule as a destination dropped
# from the config: it does not get to stay.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '2000::/3\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes6"
watch_start6
if wait_for 15 has_both_halves; then ok "armed + UP: the block converged over a stale constant"; else bad "armed + UP: the block converged over a stale constant — timed out"; fi
if wait_for 15 lacks_route6 '2000::/3'; then ok "armed + UP: an owned v6 route that is not a half is dropped"; else bad "armed + UP: an owned v6 route that is not a half is dropped — timed out"; fi
check "...and only the two halves remain" "$(installed6)" "8000::/1 ::/1 "
watch_stop

# Proto IS the identity in v6 exactly as in v4.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '2001:db8::/32\t111\t100\n' > "$IPSTATE/routes6"
OUT="$(ff --clear)"
check "a foreign-proto v6 route is never deleted" "$(installed6)" "2001:db8::/32 "
check "...and no v6 delete was even attempted" "$(asked '-6 route del')" "0"

# Orphan-clear-at-start through --watch, in v6. The unit runs --watch, and the
# case that strands routes is the one where the stop path did not run.
reset; tunnel_up_state; write_conf 54.166.22.221
printf '2001:db8::/32\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes6"
watch_start6
if wait_for 15 lacks_route6 '2001:db8::/32'; then ok "--watch clears a v6 orphan"; else bad "--watch clears a v6 orphan — timed out"; fi
if wait_for 15 has_both_halves; then ok "...and then installs the block"; else bad "...and then installs the block — timed out"; fi
FIRST_DEL6="$(grep -n -- '-6 route del' "$IPSTATE/calls.log" | head -1 | cut -d: -f1)"
FIRST_ADD6="$(grep -n -- '-6 route add' "$IPSTATE/calls.log" | head -1 | cut -d: -f1)"
if [[ -n "$FIRST_DEL6" && -n "$FIRST_ADD6" && "$FIRST_DEL6" -lt "$FIRST_ADD6" ]]; then
    ok "--watch removes a v6 orphan BEFORE its first v6 add"
else
    bad "--watch removes a v6 orphan BEFORE its first v6 add — del '$FIRST_DEL6', add '$FIRST_ADD6'"
fi
watch_stop

# A v6 route appearing under our proto mid-run — another instance, or a hand —
# is reclaimed by the next converge, not left until a restart.
reset; tunnel_up_state; write_conf 54.166.22.221
watch_start6
if wait_for 15 has_both_halves; then ok "--watch installs the block"; else bad "--watch installs the block — timed out"; fi
printf '2001:db8::/32\t%s\t%s\n' "$PROTO" "$METRIC" >> "$IPSTATE/routes6"
if wait_for 15 lacks_route6 '2001:db8::/32'; then ok "a v6 route appearing under our proto mid-run is reclaimed"; else bad "a v6 route appearing under our proto mid-run is reclaimed — timed out"; fi
check "...and the block itself is untouched" "$(installed6)" "8000::/1 ::/1 "
watch_stop

# A DISARMED daemon, tunnel DOWN, and a v6 route this tool owns appearing
# mid-run. The start-clear cannot answer this one: the route arrives after it.
# It is the only path on which converge's own tunnel-down v6 clear fires, and
# therefore the only row that can see that clear being gated on the arming
# switch.
reset; tunnel_down_lingering; write_conf 54.166.22.221
watch_start
if wait_for 15 has_route 54.166.22.221; then ok "disarmed + DOWN: the v4 half converged"; else bad "disarmed + DOWN: the v4 half converged — timed out"; fi
printf '::/1\t%s\t%s\n' "$PROTO" "$METRIC" >> "$IPSTATE/routes6"
if wait_for 15 lacks_route6 '::/1'; then ok "a DISARMED daemon still withdraws a v6 route it owns"; else bad "a DISARMED daemon still withdraws a v6 route it owns — timed out"; fi
watch_stop

# --- THE METRIC. Measured: `ip -6 route del <dst> proto 66 metric 1024`
# against a metric-4242 route answers "No such process", which del_route treats
# as SUCCESS. So one metric drift would make a v6 blackhole PERMANENT while
# clear_owned reported it cleared.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '::/1\t%s\t1024\n' "$PROTO" > "$IPSTATE/routes6"
OUT="$(ff --clear)"; RC=$?
check "a v6 route at a DIFFERENT metric is still withdrawn: exit 0" "$RC" 0
check "...and it is really gone" "$(installed6_count)" "0"

# --- failures are not silences -------------------------------------------
# A v6 add that FAILS. --once refuses the block and --watch swallows converge's
# rc by design, so the only honest place this is observable is the daemon's own
# output -- and it must name the destination rather than go quiet.
reset; tunnel_up_state; write_conf 54.166.22.221
touch "$IPSTATE/fail-add"
watch_start6
if wait_for 15 watch_said 'could not add unreachable ::/1'; then
    ok "a failing v6 add is named, not swallowed"
else
    bad "a failing v6 add is named, not swallowed — nothing said so within the budget"
fi
check "...and nothing was installed" "$(installed6_count)" "0"
watch_stop

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '::/1\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes6"
touch "$IPSTATE/fail-del"
OUT="$(ff --clear)"; RC=$?
check "a v6 delete that fails for a REAL reason: exit 1, not 0" "$RC" 1
grep_ok "$OUT" 'could not remove unreachable ::/1' "failed v6 delete: names the destination"

# clear_owned must report a v6 failure even when the v4 half succeeded — an rc
# that only tracked the last family would report this as clean.
reset; tunnel_down_lingering; write_conf 54.166.22.221
ff --once >/dev/null
printf '::/1\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes6"
touch "$IPSTATE/fail-del6"
OUT="$(ff --clear)"; RC=$?
check "--clear fails when the v6 half fails and the v4 half SUCCEEDED: exit 1" "$RC" 1
check "...and the v4 half really was cleared" "$(installed_count)" "0"

# THE RE-READ GUARD. del_route treats "No such process" as success, so a delete
# that addressed the wrong route is indistinguishable from one that worked. The
# re-read is what makes "every delete succeeded and the route is still there"
# loud instead of silent.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '::/1\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes6"
touch "$IPSTATE/del-noop"
OUT="$(ff --clear)"; RC=$?
rm -f "$IPSTATE/del-noop"
check "a delete that reports success and removes nothing: exit 1" "$RC" 1
grep_ok "$OUT" 'still owned after clearing' "the surviving route is named, not swallowed"

# The pretty-printed trap applies identically in v6 — and here it would mean the
# BLOCK is never withdrawn, which blackholes all global IPv6.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '::/1\t%s\t%s\n8000::/1\t%s\t%s\n' "$PROTO" "$METRIC" "$PROTO" "$METRIC" > "$IPSTATE/routes6"
touch "$IPSTATE/pretty-json"
OUT="$(ff --clear)"; RC=$?
check "pretty-printed ip -6 -j output: exit 0" "$RC" 0
check "...and the v6 routes are STILL withdrawn" "$(installed6_count)" "0"

# --- --status and --help -------------------------------------------------
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --status)"
grep_ok "$OUT" 'ipv6:    off' "--status: reports the knob as off by default"
grep_ok "$OUT" 'ipv6 installed (proto 66)' "--status: has a v6 installed section"
OUT="$(ff6 --status)"
grep_ok "$OUT" 'ipv6:    block' "--status: reports the knob as block when set"
check "--status adds no route in either family" "$(asked 'route add')" "0"

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '::/1\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes6"
OUT="$(ff --status)"
grep_ok "$OUT" '^  - ::/1$' "--status lists an installed v6 route"

# EVERY knob appears in --help, extracted from the script rather than listed
# here — so renaming one cannot make the daemon's own help lie while a
# hand-written list stays green.
OUT="$(ff --help)"
MISSING=""
while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    grep -q -- "$k" <<<"$OUT" || MISSING="$MISSING $k"
done < <(grep -oE 'VPN_FAILFAST_[A-Z_]+' "$FAILFAST" | LC_ALL=C sort -u)
check "every VPN_FAILFAST_* identifier is documented in --help" "$MISSING" ""

# --- the stub's own fidelity ---------------------------------------------
# A fixture that cannot fail is decoration, so the stub's two load-bearing
# behaviours get rows of their own.
reset; tunnel_up_state
OUT="$(PATH="$STUBBIN:$PATH" ip -6 route get 10.9.8.7 2>&1)"; RC=$?
check "the stub rejects a v4 literal under -6, as the real tool does: exit 1" "$RC" 1
grep_ok "$OUT" 'inet6 prefix is expected' "...with the measured message"
OUT="$(PATH="$STUBBIN:$PATH" ip -4 route get ::1 2>&1)"; RC=$?
check "the stub rejects a v6 literal under -4: exit 1" "$RC" 1
grep_ok "$OUT" 'inet prefix is expected' "...with the measured message"
OUT="$(PATH="$STUBBIN:$PATH" ip -9 route show proto 66 2>&1)"; RC=$?
check "an unknown family flag still falls to the stub's exit 99" "$RC" 99

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

printf '\nthe installer refuses to point root at a worktree\n'

# THE BUG THIS EXISTS FOR, and it reached a real install. `vpn-setup` resolves its
# checkout from $PWD when that looks like one -- right for testing a branch,
# wrong for a file root executes for months. The first install baked
#   ExecStart=".../.herdr/worktrees/.dotfiles/zvi-do-692-.../vpn-failfast.sh"
# into a root unit, and wt-gc-sweep DELETES landed worktrees daily. Same class as
# CLAUDE.md's "never run ./install from a worktree".
# A REAL git worktree, not a simulated one. An earlier version hand-built a
# `.git` file and the guard did not fire -- the fixture described a state git
# would never produce, so the row was green about nothing. `git worktree add` is
# two commands and is the thing itself.
MAINREPO="$T/mainrepo"
FAKE_WT="$T/fakewt"
git init -q "$MAINREPO" 2>/dev/null || fatal "git init failed"
git -C "$MAINREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null \
    || fatal "git commit failed"
git -C "$MAINREPO" worktree add -q --detach "$FAKE_WT" 2>/dev/null || fatal "git worktree add failed"
mkdir -p "$FAKE_WT/scripts" "$FAKE_WT/systemd/vpn-failfast.service.d" "$FAKE_WT/sysctl" || fatal setup
cp -f "$SETUP" "$FAILFAST" "$FAKE_WT/scripts/" || fatal setup
cp -f "$DOTFILES/systemd/vpn-failfast.service" "$FAKE_WT/systemd/" || fatal setup
cp -f "$DOTFILES/systemd/vpn-failfast.service.d/ipv6-block.conf" \
      "$FAKE_WT/systemd/vpn-failfast.service.d/" || fatal setup
cp -f "$DOTFILES/sysctl/99-vpn-acs-port.conf" "$FAKE_WT/sysctl/" || fatal setup
# Proof the fixture is what it claims to be, before any row leans on it.
WT_GITDIR="$(git -C "$FAKE_WT" rev-parse --git-dir 2>/dev/null || true)"
case "$WT_GITDIR" in
    *"/.git/worktrees/"*) ok "the fixture really is a git worktree" ;;
    *) bad "the fixture is NOT a worktree (git-dir=$WT_GITDIR) — the rows below prove nothing" ;;
esac

OUT="$(PATH="$STUBBIN:$PATH" VPN_LOCAL_CONF="$CONF" "$FAKE_WT/scripts/setup-vpn-failfast.sh" --no-enable 2>&1)"; RC=$?
check "installing from a worktree: refused, exit 1" "$RC" 1
grep_ok "$OUT" 'refusing to install from a WORKTREE' "worktree install: refused by name"
grep_ok "$OUT" 'wt-gc-sweep' "worktree install: says WHY (the sweep deletes it)"
grep_none "$OUT" 'Installing root-owned files' "worktree install: nothing was installed"

# ... and the override exists, because testing a branch is a real need.
OUT="$(PATH="$STUBBIN:$PATH" VPN_SETUP_ALLOW_WORKTREE=1 VPN_LOCAL_CONF="$CONF" "$FAKE_WT/scripts/setup-vpn-failfast.sh" --no-enable 2>&1 || true)"
grep_ok "$OUT" 'continuing from a worktree anyway' "the override is honoured and says so"

printf '\nthe units systemd will actually load\n'

# BOTH of the defects these rows exist for shipped in DO-692 and were caught by
# hand, one command before the first `vpn-setup`. Neither is visible in a diff.
#
# 1. StartLimitIntervalSec in [Service] is IGNORED -- systemd moved it to [Unit]
#    in v229 and only the legacy StartLimitBurst spelling still parses there. The
#    burst then applied against the default 10s interval, and with RestartSec=5
#    five restarts span 20s, so the limiter could never trip: a broken unit would
#    restart forever without ever reaching `failed`. That is precisely the
#    crash-loop check-timer-health.sh's NRestarts guard was written for, shipped
#    inside the unit that guard was written for.
# 2. ProtectHome=yes with an ExecStart under /home -- 203/EXEC on every start.
#
# systemd-analyze catches (1) and NOT (2), which is why there are two kinds of
# row here rather than one.
UNITDIR="$T/units"
mkdir -p "$UNITDIR" || fatal setup
cp -f "$DOTFILES/systemd/vpn-failfast.service" "$UNITDIR/" || fatal setup
cp -f "$DOTFILES/systemd/vpn-notify.service" "$UNITDIR/" || fatal setup

# The system unit is STATIC now. A placeholder here would mean someone
# reintroduced rendering without reintroducing the renderer, which installs a
# unit with a literal __VPN_...__ in its ExecStart.
check "vpn-failfast.service carries no placeholder" \
      "$(grep -c '__VPN_[A-Z_]*__' "$UNITDIR/vpn-failfast.service" || true)" "0"

# systemd-analyze checks that ExecStart EXISTS, and /usr/local/bin/vpn-failfast.sh
# is only there after vpn-setup has run -- which must not be a precondition of
# this suite. Verify a copy whose ExecStart points at a real temp file instead,
# so any remaining complaint is about the unit's KEYS rather than the machine.
STANDIN="$T/standin.sh"
printf '#!/bin/sh\nexit 0\n' > "$STANDIN"; chmod +x "$STANDIN"
sed "s#^ExecStart=.*#ExecStart=$STANDIN --watch#; s#^ExecStopPost=.*#ExecStopPost=$STANDIN --clear#" \
    "$UNITDIR/vpn-failfast.service" > "$UNITDIR/probe.service"

# Any output at all is a finding: systemd-analyze is silent on a clean unit.
SA_SYS="$(systemd-analyze verify "$UNITDIR/probe.service" 2>&1 | grep -v 'probe.service: Command' || true)"
check "vpn-failfast.service: systemd-analyze is silent" "$SA_SYS" ""

# ROOT MUST NOT EXECUTE OUT OF \$HOME. This is the row the worktree incident
# earned: /usr/local/bin is where backup-verify.sh and restic-notify already
# live, and it is what lets ProtectHome go back to `yes`.
FF_EXEC_SHIPPED="$(sed -n 's/^ExecStart=//p' "$UNITDIR/vpn-failfast.service" | head -1 | tr -d '"' | awk '{print $1}')"
check "the shipped ExecStart is the installed copy, not a checkout path" \
      "$FF_EXEC_SHIPPED" "/usr/local/bin/vpn-failfast.sh"
# The user unit needs a fake HOME, because `%h` expands from $HOME and
# systemd-analyze ALSO checks that ExecStart exists. Without this the row passed
# on a machine that happens to have ~/.dotfiles and failed on a CI runner that
# does not -- green for an environmental reason, which is not green.
#
# --user also pulls in the whole user unit path, so unrelated system-shipped
# units (spice-vdagent here) report their own pre-existing faults. Scope to ours.
FAKEHOME="$T/fakehome"
mkdir -p "$FAKEHOME/.dotfiles/scripts" || fatal setup
cp -f "$DOTFILES/scripts/vpn-notify.sh" "$FAKEHOME/.dotfiles/scripts/" || fatal setup
SA_USR="$(HOME="$FAKEHOME" systemd-analyze --user verify "$UNITDIR/vpn-notify.service" 2>&1 | grep 'vpn-notify' || true)"
check "vpn-notify.service: systemd-analyze is silent about it" "$SA_USR" ""

# ... and the row above is only worth having if the verifier would have spoken.
# Remove the script from that fake HOME and it must complain about ExecStart --
# otherwise "silent" proves nothing about the unit and everything about the tool
# having given up.
rm -f "$FAKEHOME/.dotfiles/scripts/vpn-notify.sh"
SA_GONE="$(HOME="$FAKEHOME" systemd-analyze --user verify "$UNITDIR/vpn-notify.service" 2>&1 | grep -c 'is not executable' || true)"
if [[ "${SA_GONE:-0}" -ge 1 ]]; then
    ok "systemd-analyze really is checking ExecStart (it objects when it is absent)"
else
    bad "systemd-analyze did NOT object to a missing ExecStart — the silence above proves nothing"
fi

# The specific directive, named, because a silent `systemd-analyze` is not the
# same as the key being in the right place -- it is only the same as systemd
# having heard of the key in that section.
for u in vpn-failfast vpn-notify; do
    unit_src="$DOTFILES/systemd/$u.service"
    before_service="$(awk '/^\[Service\]/{exit} /^StartLimitIntervalSec=/{found=1} END{print found+0}' "$unit_src")"
    check "$u.service: StartLimitIntervalSec is in [Unit], above [Service]" "$before_service" "1"
done

# ProtectHome=yes makes /home "inaccessible and empty" (systemd.exec), and the
# checkout IS the deployment here, so ExecStart lives under /home. systemd-analyze
# does NOT flag the combination -- verified, it stayed silent about it while
# complaining about the StartLimit key on the same file.
FF_PH="$(sed -n 's/^ProtectHome=//p' "$UNITDIR/vpn-failfast.service" | head -1)"
case "$FF_EXEC_SHIPPED" in
    /home/*) if [[ "$FF_PH" == "yes" || "$FF_PH" == "true" ]]; then
                 bad "ProtectHome=$FF_PH hides the ExecStart under /home — the unit cannot start"
             else
                 ok "ExecStart is under /home, and ProtectHome=${FF_PH:-unset} does not hide it"
             fi ;;
    *)       check "ExecStart is outside /home, so ProtectHome can be strict" "$FF_PH" "yes" ;;
esac

printf '\ndrift is judged on DIRECTIVES, not bytes\n'

# THE ROW THIS EXISTS FOR. The unit file here is mostly prose, and a docs commit
# that touched only its header made vpn-doctor demand a sudo re-install that
# would have changed nothing -- on a machine where the unit was running
# perfectly. This repo had already worked that out once, in
# systemd/herdr-server.service.d/10-execstart.conf: "a checker that cries wolf
# over a comment is one people stop reading". It was written down and I did it
# anyway, so now it has rows.
SYSTEM_SH="$DOTFILES/zsh/functions/system.sh"
[[ -r "$SYSTEM_SH" ]] || fatal "missing $SYSTEM_SH"
zdrift() {
    # $1 checkout file, $2 installed file. _DOCTOR_* are declared so the emitters
    # do not trip `set -u` inside the function under test.
    zsh -c "source '$SYSTEM_SH'; typeset -i _DOCTOR_FAIL=0 _DOCTOR_WARN=0; \
            _vpn_drift 'thing' '$1' '$2' 'do the fix'" 2>&1
}
DA="$T/drift-a"; DB="$T/drift-b"

printf '[Service]\n# a comment\nExecStart=/usr/local/bin/x --watch\n' > "$DA"
cp -f "$DA" "$DB"
OUT="$(zdrift "$DA" "$DB")"
grep_ok "$OUT" '✓ thing matches this checkout' "identical files: a tick"

# Comment-only: the case that cried wolf.
printf '[Service]\n# a DIFFERENT comment, rewritten by a docs commit\nExecStart=/usr/local/bin/x --watch\n' > "$DB"
OUT="$(zdrift "$DA" "$DB")"
grep_ok "$OUT" 'COMMENTS ONLY' "comment-only drift: reported as a note"
grep_none "$OUT" '⚠' "comment-only drift: NOT a warning"
grep_none "$OUT" '✗' "comment-only drift: NOT a failure"

# ... but a real directive change must still warn, or the fix above has quietly
# turned the whole check off.
printf '[Service]\n# a comment\nExecStart=/usr/local/bin/x --oops\n' > "$DB"
OUT="$(zdrift "$DA" "$DB")"
grep_ok "$OUT" '⚠ thing DIFFERS' "a directive change: still a warning"
grep_ok "$OUT" 'do the fix' "a directive change: names the remedy"

# Blank-line-only churn is comments' twin and must not warn either.
printf '[Service]\n# a comment\n\n\nExecStart=/usr/local/bin/x --watch\n' > "$DB"
OUT="$(zdrift "$DA" "$DB")"
grep_none "$OUT" '⚠' "blank-line churn: not a warning"

# A missing installed file is a FAILURE, not drift: nothing is installed at all.
rm -f "$DB"
OUT="$(zdrift "$DA" "$DB")"
grep_ok "$OUT" '✗ thing not installed' "an absent installed file: a failure, not drift"

printf '\nvpn-doctor and the IPv6 block — the canary that was specified backwards\n'

# EVERY zsh row below puts PATH and IPSTATE INSIDE the `zsh -c` string. The
# existing zdrift() has no stub on PATH and is safe only because _vpn_drift
# shells out to nothing but diff and grep; a v6 doctor row written "like the
# existing ones" would read the LIVE routing table and go green or red on
# whether the tunnel happens to be up on the machine running the suite.
zv6() {
    zsh -c "export IPSTATE='$IPSTATE'; export PATH=\"$STUBBIN:\$PATH\"; \
            source '$SYSTEM_SH'; typeset -i _DOCTOR_FAIL=0 _DOCTOR_WARN=0; $1" 2>&1
}

# --- the six-cell verdict table ------------------------------------------
# _vpn_v6_verdict is PURE -- armed, tunnel-up, both-halves, any-owned, all as
# arguments -- which is the only reason every cell is reachable from a row
# without putting the machine into the state the cell describes. Three of the
# six are FAILures for three different reasons.
check "verdict: armed, UP, block installed"          "$(zv6 '_vpn_v6_verdict 1 1 1 1')" "ok"
check "verdict: armed, UP, block MISSING -> leaking" "$(zv6 '_vpn_v6_verdict 1 1 0 0')" "leaking"
check "verdict: armed, DOWN, block present -> orphan" "$(zv6 '_vpn_v6_verdict 1 0 1 1')" "orphan-down"
check "verdict: armed, DOWN, nothing owned"          "$(zv6 '_vpn_v6_verdict 1 0 0 0')" "ok-down"
check "verdict: NOT armed but routes owned -> orphan" "$(zv6 '_vpn_v6_verdict 0 1 1 1')" "orphan-disarmed"
check "verdict: not armed, nothing owned -> a note"  "$(zv6 '_vpn_v6_verdict 0 1 0 0')" "not-armed"
# Half the block installed is NOT installed. A single half leaves the other half
# of the address space leaking, and reporting that as ok would be the quietest
# possible failure.
check "verdict: armed, UP, only ONE half -> leaking" "$(zv6 '_vpn_v6_verdict 1 1 0 1')" "leaking"

# --- what the doctor DOES with a probe result ----------------------------
# Pure, for the same reason _vpn_v6_verdict is: the halves-guard is the thing
# standing between a green tick and crediting our block for somebody ELSE's
# reject route, and inside vpn-doctor's own case statement it would be reachable
# only with a whole machine in the state it describes.
check "canary: blocked AND we own both halves -> a pass" \
      "$(zv6 '_vpn_v6_canary_verdict blocked 1')" "ok"
check "canary: blocked but we own NEITHER half -> not ours, not a pass" \
      "$(zv6 '_vpn_v6_canary_verdict blocked 0')" "not-ours"
check "canary: open -> leaking" "$(zv6 '_vpn_v6_canary_verdict open 1')" "leaking"
check "canary: no-v6 is NEVER a pass" \
      "$(zv6 '_vpn_v6_canary_verdict no-v6 1')" "not-exercised"
check "canary: anything unrecognised -> odd" \
      "$(zv6 '_vpn_v6_canary_verdict weird 1')" "odd"

# --- the route-get canary ------------------------------------------------
# THE ROW THE FIRST DESIGN NEEDED AND DID NOT HAVE. `ip -6 route get` prints the
# winning route on STDOUT with rc 0 when open, and on failure prints NOTHING on
# stdout with the message on STDERR and rc 2. So `grep -q unreachable` is never
# true for the blocked case and ALWAYS true for the no-IPv6 case -- a green tick
# for a block that is not installed.
mkget() {   # mkget <addr> <rc> <stdout> <stderr>
    printf '%s\n' "$2" > "$IPSTATE/get-$1.rc"
    if [[ -n "$3" ]]; then printf '%s\n' "$3" > "$IPSTATE/get-$1.out"; else rm -f "$IPSTATE/get-$1.out"; fi
    if [[ -n "$4" ]]; then printf '%s\n' "$4" > "$IPSTATE/get-$1.err"; else rm -f "$IPSTATE/get-$1.err"; fi
}

reset
mkget 2606:4700:4700::1111 2 "" "RTNETLINK answers: No route to host"
check "_vpn_v6_probe: EHOSTUNREACH is 'blocked'" \
      "$(zv6 '_vpn_v6_probe 2606:4700:4700::1111')" "blocked"

reset
mkget 2606:4700:4700::1111 0 "2606:4700:4700::1111 from :: via fe80::1 dev wlp0s20f3 proto ra src 2a06:c701::1 metric 600 pref medium" ""
check "_vpn_v6_probe: rc 0 with a route on stdout is 'open'" \
      "$(zv6 '_vpn_v6_probe 2606:4700:4700::1111')" "open"

# THE ROW THAT WOULD HAVE CAUGHT THE INVERTED CANARY. A machine with no IPv6 at
# all answers ENETUNREACH, and the naive `grep -q unreachable` matches that
# string -- so the original design reported "blocked" loudest on the machine
# where nothing was blocked at all.
reset
mkget 2606:4700:4700::1111 2 "" "RTNETLINK answers: Network is unreachable"
check "_vpn_v6_probe: ENETUNREACH is 'no-v6', NOT 'blocked'" \
      "$(zv6 '_vpn_v6_probe 2606:4700:4700::1111')" "no-v6"

reset
mkget 2606:4700:4700::1111 2 "" "RTNETLINK answers: Some new message nobody has seen"
check "_vpn_v6_probe: anything else is 'odd', never a pass" \
      "$(zv6 '_vpn_v6_probe 2606:4700:4700::1111')" "odd"

# ... and the probe is answering from the STUB, not from this machine's kernel.
# Without this the four rows above would pass on a host whose real routing table
# happened to agree with the fixtures.
reset
mkget 2606:4700:4700::1111 2 "" "RTNETLINK answers: No route to host"
zv6 '_vpn_v6_probe 2606:4700:4700::1111' >/dev/null
grep_ok "$(cat "$IPSTATE/calls.log")" '^-6 route get 2606:4700:4700::1111$' \
        "the probe went through the stub, not the live routing table"

# THE FIXTURE PINNED TO THE MEASUREMENT. These three strings are the whole
# design; a fixture that drifted into fiction would prove the classifier correct
# against strings iproute2 never emits.
reset
OUT="$(PATH="$STUBBIN:$PATH" ip -6 route get 2606:4700:4700::1111 2>&1)"; RC=$?
check "a missing route-get fixture is exit 99, never a quiet default" "$RC" 99

printf '\nthe IPv6 block drop-in, and arming it without breaking IPv4 fail-fast\n'

DROPIN_SRC="$DOTFILES/systemd/vpn-failfast.service.d/ipv6-block.conf"
[[ -r "$DROPIN_SRC" ]] || fatal "missing $DROPIN_SRC"

# THE DROP-IN'S VALUE MUST BE ONE THE SCRIPT ACCEPTS. This is worth more than a
# `systemd-analyze verify` row, which is decoration here: a drop-in containing
# only Environment= cannot make the verifier speak, and the suite verifies a
# sed'd copy at a path where the .d directory would not even be read.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
DROPIN_VAL="$(sed -n 's/^Environment=VPN_FAILFAST_IPV6=//p' "$DROPIN_SRC" | head -1)"
check "the shipped drop-in sets exactly one value" \
      "$(grep -c '^Environment=VPN_FAILFAST_IPV6=' "$DROPIN_SRC")" "1"
OUT="$(PATH="$STUBBIN:$PATH" VPN_FAILFAST_CONF="$CONF" \
       VPN_FAILFAST_IPV6="$DROPIN_VAL" "$FAILFAST" --check 2>&1)"; RC=$?
check "the shipped drop-in's value is one the daemon accepts: exit 0" "$RC" 0
check "...and it is the value that actually arms the block" "$DROPIN_VAL" "block"

# --- the installer -------------------------------------------------------
# A NON-worktree fixture, so the worktree guard is not in play and no row needs
# VPN_SETUP_ALLOW_WORKTREE=1 on a path that reaches the install block.
# $MAINREPO is a real repository whose git-dir is <root>/.git, which does not
# match */.git/worktrees/*.
INSTROOT="$MAINREPO"
mkdir -p "$INSTROOT/scripts" "$INSTROOT/systemd/vpn-failfast.service.d" "$INSTROOT/sysctl" || fatal setup
cp -f "$SETUP" "$FAILFAST" "$INSTROOT/scripts/" || fatal setup
cp -f "$DOTFILES/systemd/vpn-failfast.service" "$INSTROOT/systemd/" || fatal setup
cp -f "$DROPIN_SRC" "$INSTROOT/systemd/vpn-failfast.service.d/" || fatal setup
cp -f "$DOTFILES/sysctl/99-vpn-acs-port.conf" "$INSTROOT/sysctl/" || fatal setup
# Proof the fixture is what it claims to be, before any row leans on it.
INST_GITDIR="$(git -C "$INSTROOT" rev-parse --git-dir 2>/dev/null || true)"
case "$INST_GITDIR" in
    *"/.git/worktrees/"*) bad "the installer fixture IS a worktree — the rows below would exit at the guard" ;;
    *) ok "the installer fixture is a plain checkout, so the install block is reachable" ;;
esac

FAKEROOT="$T/fakeroot"
DROPIN_ETC="etc/systemd/system/vpn-failfast.service.d/ipv6-block.conf"
setup_run() {   # setup_run <prefix> <args...>
    local pfx="$1"; shift
    PATH="$STUBBIN:$PATH" VPN_SETUP_PREFIX="$pfx" VPN_LOCAL_CONF="$CONF" \
      "$INSTROOT/scripts/setup-vpn-failfast.sh" --no-enable "$@" 2>&1
}
fresh_root() {
    rm -rf "$FAKEROOT"
    mkdir -p "$FAKEROOT/usr/local/bin" "$FAKEROOT/etc/systemd/system" "$FAKEROOT/etc/sysctl.d"
}

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"; fresh_root
OUT="$(setup_run "$FAKEROOT" --block-ipv6)"; RC=$?
check "--block-ipv6: exit 0" "$RC" 0
if [[ -r "$FAKEROOT/$DROPIN_ETC" ]]; then ok "--block-ipv6 installs the drop-in"; else bad "--block-ipv6 installs the drop-in — not there"; fi
grep_ok "$(cat "$IPSTATE/sudo.log")" "install -m 644 -o root -g root" \
        "the drop-in is installed ROOT-OWNED, mode 644"

# NEITHER FLAG LEAVES ARMING EXACTLY AS IT IS. A re-run after `git pull` is the
# normal path -- it is what vpn-doctor tells you to do -- and a boolean
# defaulting to off would silently disarm the machine every single time.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(setup_run "$FAKEROOT")"; RC=$?
check "a plain re-run: exit 0" "$RC" 0
if [[ -r "$FAKEROOT/$DROPIN_ETC" ]]; then ok "a plain re-run does NOT disarm"; else bad "a plain re-run silently disarmed the machine"; fi

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(setup_run "$FAKEROOT" --no-block-ipv6)"; RC=$?
check "--no-block-ipv6: exit 0" "$RC" 0
if [[ -r "$FAKEROOT/$DROPIN_ETC" ]]; then bad "--no-block-ipv6 left the drop-in behind"; else ok "--no-block-ipv6 removes the drop-in"; fi
if [[ -d "$FAKEROOT/etc/systemd/system/vpn-failfast.service.d" ]]; then
    bad "--no-block-ipv6 left the now-empty .d directory behind"
else
    ok "--no-block-ipv6 drops the now-empty .d directory too"
fi

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(setup_run "$FAKEROOT" --block-ipv6 --no-block-ipv6)"; RC=$?
check "both flags at once: exit 2, never a guess" "$RC" 2
grep_ok "$OUT" 'contradictory' "both flags: says why"

# THE ONE THAT MATTERS. The drop-in is the only producer of VPN_FAILFAST_IPV6
# and the knob is fatal on an unknown value, so `blocked` (or `Block`, or a
# trailing space) makes --watch exit 2 on EVERY start -> Restart=on-failure ->
# StartLimitBurst -> the unit sits failed, and IPv4 fail-fast, which works today
# with NRestarts=0, is dead because of a typo in an OPTIONAL feature. The
# pre-install validation runs the CHECKOUT script with the CHECKOUT environment
# and cannot see the drop-in at all.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"; fresh_root
printf '[Service]\nEnvironment=VPN_FAILFAST_IPV6=blocked\n' \
    > "$INSTROOT/systemd/vpn-failfast.service.d/ipv6-block.conf"
OUT="$(setup_run "$FAKEROOT" --block-ipv6)"; RC=$?
cp -f "$DROPIN_SRC" "$INSTROOT/systemd/vpn-failfast.service.d/" || fatal setup
check "a drop-in the daemon would REFUSE: exit 1, before any restart" "$RC" 1
grep_ok "$OUT" 'REFUSES' "the bad value is named"
if [[ -r "$FAKEROOT/$DROPIN_ETC" ]]; then
    bad "the refused drop-in was left installed — the next boot would fail the unit"
else
    ok "the refused drop-in is REMOVED, not left for the next boot to find"
fi
if [[ -x "$FAKEROOT/usr/local/bin/vpn-failfast.sh" ]]; then
    ok "the refusal leaves IPv4 fail-fast installed — it does not take the working half down"
else
    bad "the refusal removed the daemon itself"
fi

# A DROP-IN THE RUNNING UNIT HAS NOT RE-READ IS NOT ARMED. `enable --now` runs
# `start`, and `start` on an already-active unit is a no-op -- so without this
# the installer would arm the file, reload, report success, and change nothing
# until the next reboot, while vpn-doctor correctly reported IPv6 as leaking.
# `try-restart` cannot start a unit that --no-enable left stopped, which is why
# it is safe to run before the DO_ENABLE gate.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"; fresh_root
OUT="$(setup_run "$FAKEROOT" --block-ipv6)"
grep_ok "$(cat "$IPSTATE/sudo.log")" 'systemctl try-restart vpn-failfast.service' \
        "arming re-reads the running unit, so the block takes effect now"

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(setup_run "$FAKEROOT" --no-block-ipv6)"
grep_ok "$(cat "$IPSTATE/sudo.log")" 'systemctl try-restart vpn-failfast.service' \
        "disarming re-reads it too, so the block is really withdrawn"

# ... and a routine re-run restarts NOTHING. This is the other half of the
# tri-state: `vpn-setup` after a `git pull` must not bounce a root daemon that
# is holding fail-fast routes for a tunnel that is currently down.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(setup_run "$FAKEROOT")"
grep_none "$(cat "$IPSTATE/sudo.log")" 'try-restart' \
          "a plain re-run does NOT bounce the running daemon"

# The seam itself is validated rather than trusted: a relative or absent prefix
# would silently install to the real /etc.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(PATH="$STUBBIN:$PATH" VPN_SETUP_PREFIX="relative/path" VPN_LOCAL_CONF="$CONF" \
       "$INSTROOT/scripts/setup-vpn-failfast.sh" --no-enable 2>&1)"; RC=$?
check "a relative VPN_SETUP_PREFIX: exit 2, never the real /etc" "$RC" 2
OUT="$(setup_run "$FAKEROOT")"
grep_ok "$OUT" 'NOT to the real /etc' "a prefixed run says loudly that it is not a real install"

# A REMEDY THAT CANNOT BE RUN IS WORSE THAN NO REMEDY. `vpn-setup`, `vpn-init`,
# `vpn-doctor` and `vpn-status` are zsh FUNCTIONS; `sudo` can only exec a binary,
# so `sudo vpn-setup` fails with "command not found" before it does anything. The
# script escalates per-command internally, which is the whole reason it does not
# need a leading sudo. DO-704's approved plan said `sudo vpn-setup` throughout and
# it reached vpn-doctor's own remedy lines — the first thing a user would type.
# IN THE DOCS, ONLY A FENCED CODE BLOCK COUNTS. Prose that NAMES the broken
# form in order to document it is legitimate -- this very suite caught the
# heading "`sudo vpn-setup` cannot work" in VPN_INTERNALS, which is the sentence
# explaining the bug. A row that cannot tell a remedy from a description of one
# would be paid for by deleting the explanation, which is the wrong direction.
# `awk`, not `grep -P`: this box's grep is a ugrep shim and its awk is mawk, so
# no GNU extensions.
doc_sudo() {
    awk '/^```/ { inf = !inf; next }
         inf && /sudo +(vpn-setup|vpn-init|vpn-doctor|vpn-status)/ { print FILENAME ":" FNR ": " $0 }' "$@"
}
BAD_SUDO="$( { grep -nE 'sudo +(vpn-setup|vpn-init|vpn-doctor|vpn-status)' "$SYSTEM_SH" || true
               doc_sudo "$DOTFILES/docs/VPN_RESILIENCE.md" "$DOTFILES/docs/VPN_INTERNALS.md" || true
             } | grep -v '^[[:space:]]*$' || true )"
check "no remedy anywhere tells you to sudo a zsh function" "$BAD_SUDO" ""

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
EXPECTED_ROWS=239
if (( TOTAL != EXPECTED_ROWS )); then
    printf '\033[1;31mFATAL\033[0m: ran %d checks, expected %d — a row was added or lost.\n' \
        "$TOTAL" "$EXPECTED_ROWS" >&2
    printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
    exit 2
fi
printf 'vpn fail-fast state table: %d/%d checks passed\n' "$PASS" "$TOTAL"
(( FAIL == 0 )) || exit 1
exit 0
