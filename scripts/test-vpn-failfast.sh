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
numeric=0
args=()
for a in "$@"; do
  case "$a" in
    -j|-json) json=1 ;;
    # -N prints numbers for protocol, table and action, as the real tool does;
    # without it they are NAMES. A subject that drops -N then fails here exactly
    # as it would against a kernel, instead of being answered in its own terms.
    -N) numeric=1 ;;
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
  rule)
    # IPv4 ONLY. The subject never asks for a v6 rule, and a stub that quietly
    # answered one would hide a family flag that went wrong.
    [ "$fam" = "4" ] || { echo "ip stub: -6 rule is not modelled" >&2; exit 99; }
    # One rule per line: priority, dst (a /32 bare, as the kernel reports it),
    # shape (suppress-main | unreachable | lookup:<table>), proto ("" = none).
    RULES="$IPSTATE/rules"
    touch "$RULES"
    sub="${2:-}"
    case "$sub" in
      show)
        [ -e "$IPSTATE/fail-rule-show" ] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
        # Every rule, base ones included -- `ip rule show` has no protocol filter
        # that works (VPN_INTERNALS §10), so the subject must filter for itself,
        # and a stub that pre-filtered would prove that filter correct for free.
        python3 - "$RULES" "${IPSTATE}/pretty-json" "$numeric" <<'PY'
import json, os, sys
numeric = sys.argv[3] == "1"
# Measured in a netns: under -N, tables and the action are their kernel numbers.
TABLES = {"local": "255", "main": "254", "default": "253"}
def table(name):
    return TABLES.get(name, name) if numeric else name
rows = [(0, {"priority": 0, "src": "all", "table": table("local")})]
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if not line:
        continue
    priority, dst, shape, proto = line.split("\t")
    rule = {"priority": int(priority), "src": "all"}
    if dst:
        address, _, length = dst.partition("/")
        rule["dst"] = address
        if length:
            rule["dstlen"] = int(length)
    # Field order and types exactly as measured: "suppress_prefixlen" is an
    # integer, "protocol" is a STRING.
    if shape == "suppress-main":
        rule["table"] = table("main"); rule["suppress_prefixlen"] = 0
    elif shape == "unreachable":
        rule["action"] = "7" if numeric else "unreachable"
    elif shape.startswith("lookup:"):
        rule["table"] = table(shape.split(":", 1)[1])
    if proto:
        rule["protocol"] = proto
    rows.append((int(priority), rule))
rows.append((32766, {"priority": 32766, "src": "all", "table": table("main")}))
rows.append((32767, {"priority": 32767, "src": "all", "table": table("default")}))
rows.sort(key=lambda row: row[0])
rules = [rule for _, rule in rows]
if os.path.exists(sys.argv[2]):
    print(json.dumps(rules, indent=4))
else:
    print(json.dumps(rules, separators=(",", ":")))
PY
        exit 0 ;;
      add|del)
        # Grammar exactly as the subject spells it, and nothing looser: a token
        # the stub does not know is exit 98, so a spec that drifted fails loudly.
        op="$sub"; shift 2
        priority=""; dst=""; shape=""; proto=""
        while [ $# -gt 0 ]; do
          case "$1" in
            priority) priority="${2:-}"; shift 2 ;;
            to) dst="${2:-}"; shift 2 ;;
            lookup)
              if [ "${2:-}" = "main" ] && [ "${3:-}" = "suppress_prefixlength" ] && [ "${4:-}" = "0" ]; then
                shape="suppress-main"; shift 4
              else
                echo "ip stub: unmodelled lookup: $*" >&2; exit 98
              fi ;;
            unreachable) shape="unreachable"; shift ;;
            protocol) proto="${2:-}"; shift 2 ;;
            *) echo "ip stub: unexpected rule token '$1'" >&2; exit 98 ;;
          esac
        done
        [ -n "$priority" ] && [ -n "$dst" ] && [ -n "$shape" ] || {
          echo "ip stub: incomplete rule spec" >&2; exit 98; }
        dst="${dst%/32}"
        if [ "$op" = "add" ]; then
          [ -e "$IPSTATE/fail-rule-add" ] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
          # One KIND failing alone: the partial failures the ordering has to survive.
          [ -e "$IPSTATE/fail-rule-add-tunnel" ] && [ "$priority" = "6600" ] && {
            echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
          if awk -F'\t' -v p="$priority" -v d="$dst" -v s="$shape" -v r="$proto" \
               '$1==p && $2==d && $3==s && $4==r{found=1} END{exit !found}' "$RULES"; then
            echo "RTNETLINK answers: File exists" >&2; exit 2
          fi
          printf '%s\t%s\t%s\t%s\n' "$priority" "$dst" "$shape" "$proto" >> "$RULES"
          exit 0
        fi
        [ -e "$IPSTATE/fail-rule-del" ] && { echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
        [ -e "$IPSTATE/fail-rule-del-reject" ] && [ "$priority" = "6601" ] && {
          echo "RTNETLINK answers: Operation not permitted" >&2; exit 2; }
        # Success that removes nothing, for the re-read guard in clear_rules.
        [ -e "$IPSTATE/rule-del-noop" ] && exit 0
        # The kernel matches EVERY selector the delete names, protocol included:
        # measured, `del ... unreachable protocol 66` against a rule with no
        # protocol answers "No such file or directory". That is what makes a
        # foreign rule at our priority untouchable, so the stub honours it.
        if ! awk -F'\t' -v p="$priority" -v d="$dst" -v s="$shape" -v r="$proto" \
             '$1==p && $2==d && $3==s && $4==r{found=1} END{exit !found}' "$RULES"; then
          echo "RTNETLINK answers: No such file or directory" >&2; exit 2
        fi
        awk -F'\t' -v p="$priority" -v d="$dst" -v s="$shape" -v r="$proto" \
            'done || !($1==p && $2==d && $3==s && $4==r) {print; next} {done=1}' "$RULES" > "$IPSTATE/.rules" \
          && mv -f "$IPSTATE/.rules" "$RULES"
        exit 0 ;;
    esac
    echo "ip stub: unhandled rule subcommand: $sub" >&2; exit 99 ;;
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
# ran — so the green history never once exercised the inert path, and the
# branch's script replaced the root daemon's installed copy on the runner. The
# header of this file claims "No sudo, no root"; that claim was part of the
# defect.
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
    : > "$IPSTATE/rules"
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

# The IPv4 RULES, read straight from the stub's table rather than through the
# subject's parser, so a row cannot pass by agreeing with a parser that is wrong.
# our_rules: "<tunnel|reject> <dst>" for every rule carrying OUR protocol at OUR
# priority in OUR shape -- exactly what the subject is allowed to own.
our_rules() {
    awk -F'\t' -v p="$PROTO" '
        $4==p && $1=="6600" && $3=="suppress-main" {print "tunnel " $2}
        $4==p && $1=="6601" && $3=="unreachable"   {print "reject " $2}' \
        "$IPSTATE/rules" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '
}
# The destinations that have BOTH rules -- the only state in which a host both
# fails fast while the tunnel is down and is reachable while it is up.
paired() {
    awk -F'\t' -v p="$PROTO" '
        $4==p && $1=="6600" && $3=="suppress-main" {t[$2]=1}
        $4==p && $1=="6601" && $3=="unreachable"   {r[$2]=1}
        END {for (d in t) if (d in r) print d}' \
        "$IPSTATE/rules" 2>/dev/null | LC_ALL=C sort | tr '\n' ' '
}
rule_count() { awk 'END{print NR+0}' "$IPSTATE/rules" 2>/dev/null || printf '0\n'; }
# One converge = one tunnel check. awk, never `grep -c ... || echo 0`: grep -c prints 0 AND exits 1 on no match,
# so the `||` fires too and the helper answers "0\n0".
# shellcheck disable=SC2317,SC2329
converged_at_least() {
    local n; n="$(awk '/route show dev tun0/{c++} END{print c+0}' "$IPSTATE/calls.log" 2>/dev/null)"
    [[ "${n:-0}" -ge "$1" ]]
}
# Invoked INDIRECTLY through wait_for. BOTH codes: v0.9 says SC2317, newer SC2329.
# shellcheck disable=SC2317,SC2329
has_pair() { [[ " $(paired)" == *" $1 "* ]]; }
# shellcheck disable=SC2317,SC2329
lacks_rules() { ! awk -F'\t' -v d="$1" '$2==d{f=1} END{exit !f}' "$IPSTATE/rules" 2>/dev/null; }
# shellcheck disable=SC2317,SC2329
line_of() { grep -n -- "$1" "$IPSTATE/calls.log" | head -1 | cut -d: -f1; }

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

printf '\nthe IPv4 rules — installed once, never toggled\n'

# THE GUARANTEE THIS WHOLE SECTION EXISTS FOR. AWS VPN Client 5.x crashed on
# about one reconnect in four because this daemon deleted reject routes it could
# not parse (docs/VPN_INTERNALS.md §11). So across a full down -> up -> down
# cycle the subject must not add or delete a single IPv4 route, and must not
# touch its rules either once they are right.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --once)"; RC=$?
check "tunnel down: exit 0" "$RC" 0
check "tunnel down: every destination has BOTH rules" "$(paired)" "10.20.0.0/16 44.221.89.155 54.166.22.221 "
check "...and nothing else: exactly two rules per destination" "$(rule_count)" "6"
tunnel_up_state
OUT="$(ff --once)"; RC=$?
check "tunnel back up: exit 0" "$RC" 0
check "tunnel back up: the rules are all still there" "$(paired)" "10.20.0.0/16 44.221.89.155 54.166.22.221 "
check "tunnel back up: no rule was deleted" "$(asked 'rule del')" "0"
tunnel_down_lingering
ff --once >/dev/null
check "a whole down->up->down cycle added no IPv4 route" "$(asked '-4 route add')" "0"
check "...and deleted none" "$(asked '-4 route del')" "0"
check "...and added each rule exactly once" "$(asked 'rule add')" "6"

# The rules do not wait for the tunnel to drop: a machine that boots connected
# must be protected from the first drop onward.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(ff --once)"
check "tunnel up from the start: the rules are installed anyway" "$(paired)" "10.20.0.0/16 44.221.89.155 54.166.22.221 "

# Converging twice must not re-add. `ip rule add` on an existing rule answers
# "File exists" and exits 2, which would otherwise be a failure on every poll.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
OUT="$(ff --once)"; RC=$?
check "converging twice: exit 0, not 'File exists'" "$RC" 0
check "converging twice: still exactly six rules" "$(rule_count)" "6"
grep_none "$OUT" 'could not add' "converging twice: no error reported"

# BYTE FOR BYTE, both shapes. This one pair of rows kills a wrong priority, a
# wrong table, a missing suppress_prefixlength, a dropped protocol and a wrong
# family at once -- and the delete spells the same spec, so it kills a drift
# between the two as well (see the clear rows below).
reset; tunnel_down_lingering; write_conf 54.166.22.221
ff --once >/dev/null
grep_ok "$(cat "$IPSTATE/calls.log")" \
        '^-4 rule add priority 6600 to 54.166.22.221 lookup main suppress_prefixlength 0 protocol 66$' \
        "the tunnel rule's argv is exact, byte for byte"
grep_ok "$(cat "$IPSTATE/calls.log")" \
        '^-4 rule add priority 6601 to 54.166.22.221 unreachable protocol 66$' \
        "the reject rule's argv is exact, byte for byte"
# ORDER: the tunnel rule first. A reject rule added first rejects a host whose
# tunnel is UP for as long as its tunnel rule is missing.
TUNNEL_ADD="$(line_of 'rule add priority 6600 to 54.166.22.221')"
REJECT_ADD="$(line_of 'rule add priority 6601 to 54.166.22.221')"
if [[ -n "$TUNNEL_ADD" && -n "$REJECT_ADD" && "$TUNNEL_ADD" -lt "$REJECT_ADD" ]]; then
    ok "the tunnel rule is added BEFORE the reject rule"
else
    bad "the tunnel rule is added BEFORE the reject rule — tunnel at '$TUNNEL_ADD', reject at '$REJECT_ADD'"
fi

# Half a pair is completed, not torn down and rebuilt.
reset; tunnel_up_state; write_conf 54.166.22.221
printf '6601\t54.166.22.221\tunreachable\t%s\n' "$PROTO" > "$IPSTATE/rules"
ff --once >/dev/null
check "a lone reject rule gets its tunnel rule" "$(paired)" "54.166.22.221 "
check "...and the reject rule was never deleted" "$(asked 'rule del')" "0"

printf '\norphans, and the rules and routes that are not ours\n'

# A LEGACY IPv4 route under our proto -- what the old toggle left behind -- is
# reclaimed whatever the tunnel state. With the tunnel UP it is the dangerous
# one: a /32 beats the tunnel's /1, so it blackholes its host.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '9.9.9.9\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes"
OUT="$(ff --once)"; RC=$?
check "a legacy route at start: exit 0" "$RC" 0
check "the legacy route is gone" "$(installed_count)" "0"
check "...and the rules are in place" "$(paired)" "10.20.0.0/16 44.221.89.155 54.166.22.221 "

# ORDER, not just outcome: the orphan goes BEFORE anything is added.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
printf '9.9.9.9\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes"
ff --once >/dev/null
FIRST_DEL="$(line_of '-4 route del')"
FIRST_ADD="$(line_of 'rule add')"
if [[ -n "$FIRST_DEL" && -n "$FIRST_ADD" && "$FIRST_DEL" -lt "$FIRST_ADD" ]]; then
    ok "the legacy route is removed BEFORE the first rule is added"
else
    bad "the legacy route is removed BEFORE the first rule is added — del at line '$FIRST_DEL', add at '$FIRST_ADD'"
fi

# A route somebody else installed is never touched, whatever its destination —
# even when it is one of ours by address. Proto IS the identity.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '54.166.22.221\t111\t100\n' > "$IPSTATE/routes"
OUT="$(ff --once)"
check "a foreign-proto route is never deleted" "$(installed)" "54.166.22.221 "
check "...and no route delete was even attempted" "$(asked '-4 route del')" "0"

# RULES THAT ARE NOT OURS, each a near miss on a different part of the
# identity: Tailscale's two (no dst), a reject at OUR priority with NO protocol,
# a reject with ANOTHER protocol, and our protocol at ANOTHER priority. --clear
# must remove our pair and leave all five exactly as they were.
reset; tunnel_up_state; write_conf 54.166.22.221
{
    printf '5250\t\tunreachable\t\n'
    printf '5270\t\tlookup:52\t\n'
    printf '6601\t9.9.9.9\tunreachable\t\n'
    printf '6601\t54.166.22.221\tunreachable\t111\n'
    printf '6602\t8.8.8.8\tunreachable\t%s\n' "$PROTO"
} > "$IPSTATE/rules"
ff --once >/dev/null
check "beside five foreign rules, ours are installed" "$(paired)" "54.166.22.221 "
OUT="$(ff --clear)"; RC=$?
check "--clear beside foreign rules: exit 0" "$RC" 0
check "--clear removes our pair" "$(our_rules)" ""
check "...and leaves all five foreign rules" "$(rule_count)" "5"
check "...and never tried to delete the protocol-less reject" "$(asked 'rule del priority 6601 to 9.9.9.9')" "0"

# A destination dropped from the config loses its rules, REJECT FIRST, and the
# destination that stays is not touched at all.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
write_conf 54.166.22.221
: > "$IPSTATE/calls.log"
OUT="$(ff --once)"
check "a destination removed from config loses its rules" "$(paired)" "54.166.22.221 "
check "...and only the remaining destination's two rules are left" "$(our_rules)" "reject 54.166.22.221 tunnel 54.166.22.221 "
check "...and the destination that stays was not touched" "$(asked 'rule del priority 6601 to 54.166.22.221')" "0"
REJECT_DEL="$(line_of 'rule del priority 6601 to 44.221.89.155')"
TUNNEL_DEL="$(line_of 'rule del priority 6600 to 44.221.89.155')"
if [[ -n "$REJECT_DEL" && -n "$TUNNEL_DEL" && "$REJECT_DEL" -lt "$TUNNEL_DEL" ]]; then
    ok "a stale pair is withdrawn REJECT FIRST"
else
    bad "a stale pair is withdrawn REJECT FIRST — reject at '$REJECT_DEL', tunnel at '$TUNNEL_DEL'"
fi

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
printf '9.9.9.9\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes"
OUT="$(ff --clear)"; RC=$?
check "--clear: exit 0" "$RC" 0
check "--clear: removes every rule owned" "$(rule_count)" "0"
check "--clear: and every legacy route" "$(installed_count)" "0"
# --clear runs at EVERY stop, with the tunnel most likely up -- so its order is
# the one that matters most: reject first, or a reachable host is rejected for
# the length of the gap.
REJECT_DEL="$(line_of 'rule del priority 6601 to 54.166.22.221')"
TUNNEL_DEL="$(line_of 'rule del priority 6600 to 54.166.22.221')"
if [[ -n "$REJECT_DEL" && -n "$TUNNEL_DEL" && "$REJECT_DEL" -lt "$TUNNEL_DEL" ]]; then
    ok "--clear withdraws REJECT FIRST"
else
    bad "--clear withdraws REJECT FIRST — reject at '$REJECT_DEL', tunnel at '$TUNNEL_DEL'"
fi

# `ip -p -j` pretty-prints. A parser that matched only the compact spelling
# would find no owned rules and therefore withdraw NOTHING.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
touch "$IPSTATE/pretty-json"
OUT="$(ff --clear)"; RC=$?
check "pretty-printed ip -j rule output: exit 0" "$RC" 0
check "...and the rules are STILL withdrawn" "$(rule_count)" "0"

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
touch "$IPSTATE/fail-rule-add"
OUT="$(ff --once)"; RC=$?
check "a rule that cannot be added: exit 1, not 0" "$RC" 1
grep_ok "$OUT" 'could not add tunnel rule' "failed rule add: named"

reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
touch "$IPSTATE/fail-rule-del"
OUT="$(ff --clear)"; RC=$?
check "a rule delete that fails for a REAL reason: exit 1" "$RC" 1
grep_ok "$OUT" 'could not remove reject rule' "failed rule delete: named"

# THE RE-READ GUARD. "No such file or directory" is success, so a delete that
# matched nothing looks exactly like one that worked; only the re-read tells.
reset; tunnel_down_lingering; write_conf "${GOOD_CONF[@]}"
ff --once >/dev/null
touch "$IPSTATE/rule-del-noop"
OUT="$(ff --clear)"; RC=$?
rm -f "$IPSTATE/rule-del-noop"
check "a rule delete that reports success and removes nothing: exit 1" "$RC" 1
grep_ok "$OUT" 'rules still owned after clearing' "the surviving rules are named"

# --- partial failures: the invariant ordering alone does not keep ---------
# Found by the independent review of the first version: a tunnel add that FAILED
# was still followed by its reject add, and a reject delete that FAILED was still
# followed by its tunnel delete. Each leaves a host REJECTED while the tunnel is
# up -- and on the stop path nothing re-converges to repair it.
reset; tunnel_up_state; write_conf 54.166.22.221
touch "$IPSTATE/fail-rule-add-tunnel"
OUT="$(ff --once)"; RC=$?
check "a failing tunnel add: exit 1" "$RC" 1
check "...and its reject rule is NOT added" "$(our_rules)" ""
check "...not even attempted" "$(asked 'rule add priority 6601')" "0"

reset; tunnel_up_state; write_conf 54.166.22.221
ff --once >/dev/null
touch "$IPSTATE/fail-rule-del-reject"
OUT="$(ff --clear)"; RC=$?
check "--clear with a failing reject delete: exit 1" "$RC" 1
check "...and the tunnel rule STAYS, so the host is never reject-only" \
      "$(our_rules)" "reject 54.166.22.221 tunnel 54.166.22.221 "
grep_ok "$OUT" 'keeping its tunnel rule' "...and it says why"

reset; tunnel_up_state; write_conf 54.166.22.221 44.221.89.155
ff --once >/dev/null
write_conf 54.166.22.221
touch "$IPSTATE/fail-rule-del-reject"
OUT="$(ff --once)"; RC=$?
check "a stale pair whose reject cannot be removed: exit 1" "$RC" 1
check "...keeps its tunnel rule too" "$(paired)" "44.221.89.155 54.166.22.221 "

# --- a listing that cannot be read is an error, never "no rules" ----------
reset; tunnel_down_lingering; write_conf 54.166.22.221
ff --once >/dev/null
touch "$IPSTATE/fail-rule-show"
OUT="$(ff --clear)"; RC=$?
check "--clear when the rules cannot be listed: exit 1, not a clean 0" "$RC" 1
grep_ok "$OUT" 'could not list the IPv4 rules' "...and it says it could not list them"
OUT="$(ff --status)"
grep_ok "$OUT" 'COULD NOT LIST the rules' "--status says so too, instead of '(none)'"
rm -f "$IPSTATE/fail-rule-show"

# NUMERIC, because names come from rt_protos and can change under the tool.
reset; tunnel_down_lingering; write_conf 54.166.22.221
ff --once >/dev/null
grep_ok "$(cat "$IPSTATE/calls.log")" '^-N -j -4 rule show$' "the rule listing asks for numbers (-N)"

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

# Legacy-route-clear-at-start, through --watch rather than --once. The unit runs
# --watch; a mutant removing the clear from THAT branch alone would survive every
# row above, because all of them go through --once.
reset; tunnel_down_lingering; write_conf 54.166.22.221
printf '9.9.9.9\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes"
watch_start
if wait_for 15 has_pair 54.166.22.221; then ok "--watch converges"; else bad "--watch converges — timed out"; fi
FIRST_DEL="$(line_of '-4 route del')"
FIRST_ADD="$(line_of 'rule add')"
if [[ -n "$FIRST_DEL" && -n "$FIRST_ADD" && "$FIRST_DEL" -lt "$FIRST_ADD" ]]; then
    ok "--watch removes a legacy route BEFORE its first rule add"
else
    bad "--watch removes a legacy route BEFORE its first rule add — del '$FIRST_DEL', add '$FIRST_ADD'"
fi
watch_stop

# A RESTART MUST NOT CHURN. Rules that are already right are reconciled as a
# delta, so a daemon starting over a correct table neither deletes nor re-adds:
# a clear-then-add start would leave every host hanging instead of failing for
# the length of the gap, on every `vpn-setup` and every boot-time restart.
reset; tunnel_up_state; write_conf 54.166.22.221
printf '6600\t54.166.22.221\tsuppress-main\t%s\n6601\t54.166.22.221\tunreachable\t%s\n' \
    "$PROTO" "$PROTO" > "$IPSTATE/rules"
watch_start
if wait_for 20 converged_at_least 3; then ok "--watch over correct rules keeps converging"; else bad "--watch over correct rules keeps converging — timed out"; fi
check "...and never deleted a rule" "$(asked 'rule del')" "0"
check "...and never re-added one" "$(asked 'rule add')" "0"
watch_stop

# A rule carrying OUR identity that appears while the daemon is running, for a
# destination that is not configured, is reclaimed by the next converge.
reset; tunnel_down_lingering; write_conf 54.166.22.221
watch_start
if wait_for 15 has_pair 54.166.22.221; then ok "--watch installs the configured pair"; else bad "--watch installs the configured pair — timed out"; fi
printf '6601\t8.8.4.4\tunreachable\t%s\n' "$PROTO" >> "$IPSTATE/rules"
if wait_for 15 lacks_rules 8.8.4.4; then ok "a rule appearing under our identity mid-run is reclaimed"; else bad "a rule appearing under our identity mid-run is reclaimed — timed out"; fi
check "...and the configured pair is untouched" "$(paired)" "54.166.22.221 "
watch_stop

# A LEGACY route appearing mid-run -- the old daemon still running during an
# upgrade, or a hand -- is reclaimed by the next converge, not left until a
# restart. With the tunnel UP it blackholes its host, so it cannot wait.
reset; tunnel_up_state; write_conf 54.166.22.221
watch_start
if wait_for 15 has_pair 54.166.22.221; then ok "--watch installs the pair, tunnel up"; else bad "--watch installs the pair, tunnel up — timed out"; fi
printf '54.166.22.221\t%s\t%s\n' "$PROTO" "$METRIC" >> "$IPSTATE/routes"
# shellcheck disable=SC2317,SC2329
no_legacy_routes() { [[ "$(installed_count)" == "0" ]]; }
if wait_for 15 no_legacy_routes; then ok "a legacy route appearing mid-run is reclaimed"; else bad "a legacy route appearing mid-run is reclaimed — timed out"; fi
watch_stop

# ... and the mirror: a rule of ours that VANISHES mid-run -- an `ip rule flush`,
# another tool -- is put back without a restart.
reset; tunnel_down_lingering; write_conf 54.166.22.221
watch_start
if wait_for 15 has_pair 54.166.22.221; then ok "--watch installs the pair before it is removed"; else bad "--watch installs the pair before it is removed — timed out"; fi
: > "$IPSTATE/rules"
if wait_for 15 has_pair 54.166.22.221; then ok "rules removed mid-run are re-installed"; else bad "rules removed mid-run are re-installed — timed out"; fi
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
# the block comes OFF, while the v4 rules are in place either way.
reset; tunnel_down_lingering; write_conf 54.166.22.221
printf '::/1\t%s\t%s\n8000::/1\t%s\t%s\n' "$PROTO" "$METRIC" "$PROTO" "$METRIC" > "$IPSTATE/routes6"
watch_start6
if wait_for 15 has_pair 54.166.22.221; then ok "armed + tunnel DOWN: the v4 rules are installed"; else bad "armed + tunnel DOWN: the v4 rules are installed — timed out"; fi
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
tunnel_up_state
if wait_for 15 has_both_halves; then ok "DOWN->UP: block back on"; else bad "DOWN->UP: block back on — timed out"; fi
# Both transitions under one daemon, and the v4 side did not move at all: one
# add per rule from the first converge, and nothing since.
check "UP->DOWN->UP: each v4 rule added once and never since" "$(asked 'rule add')" "2"
check "...and no v4 rule or route was ever deleted" "$(( $(asked 'rule del') + $(asked '-4 route del') ))" "0"
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
check "--once still installs the IPv4 rules" "$(paired)" "10.20.0.0/16 44.221.89.155 54.166.22.221 "

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
check "--clear: v4 rules empty" "$(rule_count)" "0"
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
if wait_for 15 has_pair 54.166.22.221; then ok "disarmed + DOWN: the v4 rules converged"; else bad "disarmed + DOWN: the v4 rules converged — timed out"; fi
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
check "...and the v4 rules really were cleared" "$(rule_count)" "0"

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
check "--status adds no rule" "$(asked 'rule add')" "0"

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
check "empty config: nothing installed" "$(rule_count)" "0"

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
check "0.0.0.0/0: NOTHING installed, not even the valid line above it" "$(rule_count)" "0"

reset; tunnel_down_lingering; write_conf 54.166.22.221 "10.0.0.0/4"
OUT="$(ff --once)"; RC=$?
check "a prefix broader than the floor: exit 2" "$RC" 2
check "...and a partial set is never installed" "$(rule_count)" "0"

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

# A /32 is reported by `ip -j rule show` WITHOUT its prefix length, so the
# config spelling and the kernel spelling must compare equal or every converge
# re-adds a rule that is already there.
reset; tunnel_down_lingering; write_conf "54.166.22.221/32"
ff --once >/dev/null
check "a /32 is normalised to the kernel's spelling" "$(paired)" "54.166.22.221 "
ff --once >/dev/null
check "...so a second converge adds nothing" "$(rule_count)" "2"

reset; tunnel_down_lingering; write_conf "  54.166.22.221   # dev" "" "# a comment"
OUT="$(ff --once)"; RC=$?
check "comments and whitespace are stripped: exit 0" "$RC" 0
check "...and the destination is installed" "$(paired)" "54.166.22.221 "

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
check "--check installs nothing" "$(rule_count)" "0"

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

# THE REMEDY MUST BE RUNNABLE VERBATIM. Dropping the flags prints a command
# that succeeds and does something else: `vpn-setup` with no flags leaves arming
# untouched by design, so a user who typed --block-ipv6, pasted the remedy, and
# saw it succeed would still be leaking IPv6. Second time this class has bitten
# here -- the first was `sudo vpn-setup`, which could not run at all.
OUT="$(PATH="$STUBBIN:$PATH" VPN_LOCAL_CONF="$CONF" \
       "$FAKE_WT/scripts/setup-vpn-failfast.sh" --no-enable --block-ipv6 2>&1)"
grep_ok "$OUT" 'cd ~/.dotfiles && vpn-setup --no-enable --block-ipv6' \
        "the worktree refusal echoes the flags you typed, so the remedy is runnable"

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

printf '\nvpn-doctor and the IPv4 rules\n'

# --- the --status contract ------------------------------------------------
# The daemon's REAL --status, through the doctor's REAL parser. The two live in
# different files and different languages; these rows notice when one of them
# renames a header and the other does not. Rules list in priority order, as the
# kernel lists them. The targets row also proves a list ENDS at the next header:
# otherwise it would run on into the rules.
reset; tunnel_up_state; write_conf 54.166.22.221 "10.20.0.0/16"
ff --once >/dev/null
printf '9.9.9.9\t%s\t%s\n' "$PROTO" "$METRIC" > "$IPSTATE/routes"
STATUS_OUT="$(ff --status)"
zsection() { zv6 "_vpn_status_section '$1' \"\$(cat '$T/status.out')\"" | tr '\n' ' '; }
printf '%s\n' "$STATUS_OUT" > "$T/status.out"
check "contract: the doctor reads the targets from --status" "$(zsection 'targets: ')" "54.166.22.221 10.20.0.0/16 "
check "contract: ...and the rules, as '<kind> <dst>'" "$(zsection 'ipv4 rules (proto ')" \
      "tunnel 54.166.22.221 tunnel 10.20.0.0/16 reject 54.166.22.221 reject 10.20.0.0/16 "
check "contract: ...and the legacy routes" "$(zsection 'ipv4 legacy routes (proto ')" "9.9.9.9 "
check "contract: an empty section, '(none)', reads as empty" "$(zsection 'ipv6 installed (proto ')" ""

# --- _vpn_v4_rule_findings is PURE ---------------------------------------
zfind() { zv6 "_vpn_v4_rule_findings \$'$1' \$'$2'" | tr '\n' ' '; }
check "findings: every target paired -> nothing at all" \
      "$(zfind '54.166.22.221\n10.20.0.0/16' 'tunnel 54.166.22.221\nreject 54.166.22.221\ntunnel 10.20.0.0/16\nreject 10.20.0.0/16')" ""
check "findings: no rule at all -> missing" "$(zfind '54.166.22.221' '')" "missing 54.166.22.221 "
# The dangerous half: a reject with no tunnel rule rejects a host that is UP.
check "findings: reject without tunnel -> reject-only" \
      "$(zfind '54.166.22.221' 'reject 54.166.22.221')" "reject-only 54.166.22.221 "
check "findings: tunnel without reject -> tunnel-only" \
      "$(zfind '54.166.22.221' 'tunnel 54.166.22.221')" "tunnel-only 54.166.22.221 "
check "findings: a pair for an unlisted destination -> ONE extra, not two" \
      "$(zfind '54.166.22.221' 'tunnel 54.166.22.221\nreject 54.166.22.221\ntunnel 8.8.8.8\nreject 8.8.8.8')" "extra 8.8.8.8 "
# An unlisted reject with no tunnel rule is a live blackhole, not a tidy-up.
check "findings: an unlisted reject without its tunnel rule -> extra-reject-only" \
      "$(zfind '54.166.22.221' 'tunnel 54.166.22.221\nreject 54.166.22.221\nreject 8.8.8.8')" "extra-reject-only 8.8.8.8 "

# --- _vpn_v4_probe: classify rc AND the message, as measured ---------------
reset
zprobe() { zv6 "_vpn_v4_probe $1; print -r -- \"\$_VPN_V4_PROBE_STATE \$_VPN_V4_PROBE_DEV\""; }
mkget 54.166.22.221 2 "" "RTNETLINK answers: Network is unreachable"
check "_vpn_v4_probe: ENETUNREACH (our rule) is 'rejected'" "$(zprobe 54.166.22.221)" "rejected "
mkget 54.166.22.221 2 "" "RTNETLINK answers: No route to host"
check "_vpn_v4_probe: EHOSTUNREACH (a reject ROUTE) is told apart" "$(zprobe 54.166.22.221)" "rejected-by-route "
mkget 54.166.22.221 0 "54.166.22.221 via 172.31.80.33 dev tun0 src 172.31.80.35 uid 1000" ""
check "_vpn_v4_probe: rc 0 reports the winning device" "$(zprobe 54.166.22.221)" "routed tun0"
mkget 54.166.22.221 1 "" "Error: something else entirely"
check "_vpn_v4_probe: anything else is 'odd', never a pass" "$(zprobe 54.166.22.221)" "odd "
grep_ok "$(cat "$IPSTATE/calls.log")" '^-4 route get 54.166.22.221$' "_vpn_v4_probe asks exactly '-4 route get <addr>'"

# --- _vpn_v4_canary_verdict is PURE --------------------------------------
zcanary() { zv6 "_vpn_v4_canary_verdict $*"; }
check "canary: up, via the tunnel -> ok-up"                 "$(zcanary 1 tun0 1 routed tun0)" "ok-up"
check "canary: up, via the LAN -> not-via-tunnel"           "$(zcanary 1 tun0 1 routed wlp0s20f3)" "not-via-tunnel"
check "canary: up, rejected -> rejected-while-up"           "$(zcanary 1 tun0 1 rejected)" "rejected-while-up"
check "canary: up, rejected by a ROUTE -> rejected-while-up" "$(zcanary 1 tun0 1 rejected-by-route)" "rejected-while-up"
check "canary: down, rejected, pair present -> ok-down"     "$(zcanary 0 tun0 1 rejected)" "ok-down"
# THE GUARD. No network at all rejects everything the same way; that must not be
# credited to rules that are not even installed.
check "canary: down, rejected, NO pair -> not-ours"         "$(zcanary 0 tun0 0 rejected)" "not-ours"
check "canary: down, routed -> would-hang"                  "$(zcanary 0 tun0 1 routed wlp0s20f3)" "would-hang"
check "canary: down, rejected by a ROUTE -> route-not-rules" "$(zcanary 0 tun0 1 rejected-by-route)" "route-not-rules"

# --- the AWS apt signing key ---------------------------------------------
check "key: no expiry -> never"       "$(zv6 '_vpn_key_expiry_verdict "" 1793648983')" "never"
check "key: expires later -> valid"   "$(zv6 '_vpn_key_expiry_verdict 1814448776 1793648983')" "valid"
# The measured case: the key the vendor's instructions installed, expired
# 2026-09-05, read on 2026-11-02.
check "key: expired -> expired"       "$(zv6 '_vpn_key_expiry_verdict 1788563976 1793648983')" "expired"
check "key: expiring this second -> expired, not valid" "$(zv6 '_vpn_key_expiry_verdict 1793648983 1793648983')" "expired"

printf 'Types: deb\nURIs: https://example.invalid/\nSigned-By: /etc/apt/keyrings/awsvpnclient.asc\n' > "$T/aws.sources"
check "key file: deb822 Signed-By is read" \
      "$(zv6 "_vpn_apt_key_file '$T/aws.sources'")" "/etc/apt/keyrings/awsvpnclient.asc"
printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/aws.gpg] https://example.invalid/ ubuntu main\n' > "$T/aws.list"
check "key file: one-line signed-by= is read" \
      "$(zv6 "_vpn_apt_key_file '$T/no-such.sources' '$T/aws.list'")" "/usr/share/keyrings/aws.gpg"
# The live machine's shape on 2026-11-02: a deb822 file with an EMPTY Signed-By,
# so apt trusts the legacy trusted.gpg.d key -- which is the one that expired.
printf 'Types: deb\nSigned-By: \n' > "$T/empty.sources"
: > "$T/legacy.asc"
check "key file: an empty Signed-By falls back to the legacy key" \
      "$(zv6 "_VPN_APT_LEGACY_KEY='$T/legacy.asc'; _vpn_apt_key_file '$T/empty.sources'")" "$T/legacy.asc"
check "key file: ...and to nothing when there is no legacy key either" \
      "$(zv6 "_VPN_APT_LEGACY_KEY='$T/no-such.asc'; _vpn_apt_key_file '$T/empty.sources'")" ""
# A key that cannot be read is NOT a key that never expires: gpg prints nothing,
# and an empty expiry reads as "never". The first version called that "current".
zkeystate() { zv6 "_vpn_apt_key_state '$1'; print -r -- \$_VPN_APT_KEY_STATE"; }
check "key state: a keyring that cannot be read is 'unreadable', never 'never'" \
      "$(zkeystate "$T/no-such-key.asc")" "unreadable"
printf 'not a key\n' > "$T/not-a-key.asc"
check "key state: a file gpg cannot parse is 'unparsed'" "$(zkeystate "$T/not-a-key.asc")" "unparsed"

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

# ... and a re-run that CHANGES NOTHING restarts nothing. This is the other
# half of the tri-state: a restart clears every owned rule and route before the
# new start puts them back, so bouncing a daemon for no reason opens a window in
# which a configured host hangs instead of failing.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
OUT="$(setup_run "$FAKEROOT")"
grep_none "$(cat "$IPSTATE/sudo.log")" 'try-restart' \
          "a plain re-run does NOT bounce the running daemon"

# A RE-RUN THAT CHANGES WHAT THE DAEMON READS DOES RESTART IT. It reads its
# script, config and unit only at start, and `enable --now` is a no-op on a
# running unit, so without the restart the new files sit on disk while the old
# daemon runs on: PR #341's deploy needed a hand restart for exactly this. Each
# row makes ONE installed file stale, so each names the cmp that caught it.
reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '# an older daemon\n' >> "$FAKEROOT/usr/local/bin/vpn-failfast.sh"
OUT="$(setup_run "$FAKEROOT")"
grep_ok "$(cat "$IPSTATE/sudo.log")" 'systemctl try-restart vpn-failfast.service' \
        "a re-run that changes the DAEMON restarts the running unit"
grep_ok "$OUT" "so it runs what was just installed: $FAKEROOT/usr/local/bin/vpn-failfast.sh" \
        "...and names the daemon as what changed"

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '# an older config\n' >> "$FAKEROOT/etc/vpn-failfast.conf"
OUT="$(setup_run "$FAKEROOT")"
grep_ok "$OUT" "so it runs what was just installed: $FAKEROOT/etc/vpn-failfast.conf" \
        "a re-run that changes the CONFIG restarts it too: the daemon reads it only at start"

reset; tunnel_up_state; write_conf "${GOOD_CONF[@]}"
printf '# an older unit\n' >> "$FAKEROOT/etc/systemd/system/vpn-failfast.service"
OUT="$(setup_run "$FAKEROOT")"
grep_ok "$OUT" "so it runs what was just installed: $FAKEROOT/etc/systemd/system/vpn-failfast.service" \
        "a re-run that changes the UNIT restarts it too"

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

# The end of the window is PINNED, to the day after the fixture. Measured from
# the wall clock, a 7-day window stopped containing this fixture on 2026-11-01
# and every row below failed on an unchanged tree -- the suite had a fuse.
FIXTURE_WINDOW_END=1792972800   # 2026-10-26T00:00:00Z
rep() { VPN_REPORT_NOW="$FIXTURE_WINDOW_END" "$REPORT" --app-dir "$FIXTURES" --ovpn-dir "$T/no-ovpn" --daemon-dir "$T/no-daemon" "$@" 2>&1; }
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

OUT="$("$REPORT" --app-dir "$T/no-such-a" --ovpn-dir "$T/no-such-b" --daemon-dir "$T/no-such-c" 2>&1)"; RC=$?
check "no log directory at all: exit 2, never a clean report" "$RC" 2
grep_ok "$OUT" 'no log directory exists' "missing dirs: named"

mkdir -p "$T/empty-logs"
OUT="$("$REPORT" --app-dir "$T/empty-logs" --ovpn-dir "$T/no-such-b" --daemon-dir "$T/no-such-c" 2>&1)"; RC=$?
check "a log dir with no logs in the window: exit 2" "$RC" 2
grep_ok "$OUT" 'NOT "no outages"' "empty window: refuses to read as a clean week"

OUT="$(rep --days 0)"; RC=$?
check "--days 0: exit 2" "$RC" 2

# The pin is HONOURED, not merely accepted. This window starts at 1792880000,
# BETWEEN the fixture's two browser opens (1792869001 and 1792888201), so it must
# count exactly one. A reporter that ignored the pin would count both or none,
# depending on the day -- and the window cannot go stale itself, because the file
# filter is on mtime and every checkout postdates the window's start.
CUT_WINDOW_END=1792966400   # since = 1792880000 with --days 1
OUT="$(VPN_REPORT_NOW="$CUT_WINDOW_END" "$REPORT" --app-dir "$FIXTURES" --ovpn-dir "$T/no-ovpn" --daemon-dir "$T/no-daemon" --days 1 --json 2>&1)"
check "a pinned window that cuts the fixture counts only its own half" \
      "$(printf '%s' "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin)['browser_opens'])" 2>&1)" "1"
OUT="$(VPN_REPORT_NOW=yesterday "$REPORT" --app-dir "$FIXTURES" --ovpn-dir "$T/no-ovpn" --daemon-dir "$T/no-daemon" 2>&1)"; RC=$?
check "a malformed VPN_REPORT_NOW: exit 2, never the wall clock" "$RC" 2

# --- client crashes: the number the 2026-11 fix targets --------------------
# Against a `journalctl` STUB, never the real journal: this machine's own crash
# history would make every one of these rows a statement about the developer's
# laptop. The stub records its argv and answers from a fixture per mode:
#   journal-user.out present -> print it, exit 0
#   journal-user-none        -> `-- No entries --`, exit 1  (measured: what -g prints for no match)
#   journal-user-fail        -> nothing, exit 2              (could not ask)
# Every non-user query (the kernel resumes, --list-boots) gets the no-match answer.
cat > "$STUBBIN/journalctl" <<'STUB'
#!/usr/bin/env bash
[ -n "${IPSTATE:-}" ] || exit 99
printf '%s\n' "$*" >> "$IPSTATE/journal.calls"
case " $* " in
  *" --user "*)
    [ -e "$IPSTATE/journal-user-fail" ] && exit 2
    if [ -r "$IPSTATE/journal-user.out" ]; then cat "$IPSTATE/journal-user.out"; exit 0; fi
    echo '-- No entries --'; exit 1 ;;
  *" -u aws-client-vpn-daemon.service "*)
    if [ -e "$IPSTATE/journal-system-hint" ]; then
      echo 'Hint: You are currently not seeing messages from other users and the system.' >&2
      echo '-- No entries --'; exit 1
    fi
    [ -e "$IPSTATE/journal-daemon-fail" ] && exit 2
    if [ -r "$IPSTATE/journal-daemon.out" ]; then cat "$IPSTATE/journal-daemon.out"; exit 0; fi
    echo '-- No entries --'; exit 1 ;;
esac
if [ -e "$IPSTATE/journal-system-hint" ]; then
  echo 'Hint: You are currently not seeing messages from other users and the system.' >&2
fi
echo '-- No entries --'; exit 1
STUB
chmod +x "$STUBBIN/journalctl" || fatal setup
rep_journal() { PATH="$STUBBIN:$PATH" VPN_REPORT_NOW="$FIXTURE_WINDOW_END" \
    "$REPORT" --app-dir "$FIXTURES" --ovpn-dir "$T/no-ovpn" --daemon-dir "$T/no-daemon" --days 7 --json 2>&1; }
jfield() { printf '%s' "$1" | python3 -c "import json,sys;v=json.load(sys.stdin)['$2'];print(v.get('resumes_seen') if isinstance(v,dict) else v)" 2>&1; }

# One crash, five minutes after the fixture's first CONNECTED (1792868400), so
# the next CONNECTED is the fixture's 1792869020: 320 seconds later.
reset
printf '%s\n' '2026-10-24T22:05:00+03:00 cilantro awsvpnclient.desktop[111]: Unhandled exception. System.ArgumentException: Invalid network interface ID: input contains invalid characters.' \
    > "$IPSTATE/journal-user.out"
J_CRASH="$(rep_journal)"
check "one crash in the window is counted" "$(jfield "$J_CRASH" client_crashes)" "1"
check "...and paired with the NEXT CONNECTED, 320s later" "$(jfield "$J_CRASH" crash_to_reconnect_p50)" "320.0"
grep_ok "$(cat "$IPSTATE/journal.calls")" '--user -t awsvpnclient.desktop --since .* -g Unhandled exception' \
        "the crash query is the user journal, the GUI's identifier and the marker"

# THE rc-1 ROW. journalctl -g exits 1 when nothing matches; reading that as
# "could not ask" made every quiet window read NOT CHECKED, and it would have
# made the week the fix works look like the week the probe broke.
reset
J_QUIET="$(rep_journal)"
check "no crash at all reads 0, not NOT CHECKED" "$(jfield "$J_QUIET" client_crashes)" "0"
check "...and the same answer is a count of resumes, not NOT CHECKED" "$(jfield "$J_QUIET" resume_split)" "0"

reset; touch "$IPSTATE/journal-user-fail"
check "a journal that cannot be read: NOT CHECKED, never 0" "$(jfield "$(rep_journal)" client_crashes)" "NOT CHECKED"

# A 6.x DAEMON failure, as systemd records it: Restart=always brings it back, so
# the record systemd writes is the only trace of the death.
reset
printf '%s\n' '2026-10-24T22:05:00+03:00 cilantro systemd[1]: aws-client-vpn-daemon.service: Failed with result '"'"'exit-code'"'"'.' \
    > "$IPSTATE/journal-daemon.out"
J_DAEMON="$(rep_journal)"
check "a 6.x daemon failure is counted" "$(jfield "$J_DAEMON" daemon_failures_6x)" "1"
check "...and is a client crash in the total" "$(jfield "$J_DAEMON" client_crashes)" "1"
reset; touch "$IPSTATE/journal-daemon-fail"
check "a daemon journal that cannot be read: the TOTAL is NOT CHECKED" \
      "$(jfield "$(rep_journal)" client_crashes)" "NOT CHECKED"
# A user outside adm/systemd-journal: journalctl exits 1 with `-- No entries --`
# exactly as for a real zero, and only its stderr hint tells the two apart.
reset; touch "$IPSTATE/journal-system-hint"
J_HINT="$(rep_journal)"
check "a system journal this user cannot read: daemon failures NOT CHECKED, not 0" \
      "$(jfield "$J_HINT" daemon_failures_6x)" "NOT CHECKED"
check "...and so are the kernel resumes" "$(jfield "$J_HINT" resume_split)" "NOT CHECKED"

# --- the 6.x daemon log ----------------------------------------------------
# 6.x moved the tunnel into a root daemon with its own, root-owned log. The
# fixture is in its measured line shapes: a 5 s first connect, then one drop that
# needs a SAML re-auth, closed 300 s later.
reset
J6="$(PATH="$STUBBIN:$PATH" VPN_REPORT_NOW="$FIXTURE_WINDOW_END" "$REPORT" --app-dir "$T/no-app" \
      --ovpn-dir "$T/no-ovpn" --daemon-dir "$FIXTURES/daemon" --days 7 --json 2>&1)"
check "6.x: a first connect and one drop are two outages" "$(jfield "$J6" outages)" "2"
# Durations come from the daemon's own UTC stamps: 5 s + 300 s.
check "6.x: the spans are measured from the daemon's UTC stamps, 5 s + 300 s" "$(jfield "$J6" downtime_seconds)" "305"
check "6.x: the drop's DYNAMIC_CHALLENGE marks it as needing SAML" "$(jfield "$J6" needed_saml)" "1"
check "6.x: the assertion reaching the local callback is counted" "$(jfield "$J6" acs_requests)" "1"

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
EXPECTED_ROWS=336
if (( TOTAL != EXPECTED_ROWS )); then
    printf '\033[1;31mFATAL\033[0m: ran %d checks, expected %d — a row was added or lost.\n' \
        "$TOTAL" "$EXPECTED_ROWS" >&2
    printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
    exit 2
fi
printf 'vpn fail-fast state table: %d/%d checks passed\n' "$PASS" "$TOTAL"
(( FAIL == 0 )) || exit 1
exit 0
