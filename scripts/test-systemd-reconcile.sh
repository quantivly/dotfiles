#!/usr/bin/env bash
#
# scripts/test-systemd-reconcile.sh
# =================================
#
# State table for scripts/reconcile-systemd-units.sh.
#
# Why this exists: the defect it guards against is a `.wants/` symlink in the
# wrong directory, and that state is invisible — `systemctl status` is happy,
# `daemon-reload` reports nothing, the unit file under review says one thing and
# what actually starts is another. It cost a reboot's worth of every pane losing
# `gh --web`, `xdg-open` and the ssh agent, with every check on the machine
# green. So each way the comparison can be wrong is a row here.
#
# Deliberately needs NO systemd user manager: the whole comparison is filesystem
# state, so the suite drives it through SYSTEMD_USER_DIR / DOTFILES_DIR against
# throwaway directories with RECONCILE_NO_SYSTEMCTL=1. A CI runner usually has no
# user manager at all, and a suite that skips there is one that never runs.
#
# BUT that same variable used to be set on EVERY row, so have_user_manager() was
# false on every invocation and do_reconcile() returned at its first branch —
# its body executed ZERO times in a full 44/44 run (proved with a canary). The
# read-only decision layer was pinned completely; the layer that DELETES
# SYMLINKS was not pinned at all. Three mutations passed 44/44 because of it:
# making do_reconcile ALSO `rm -f` the unit symlink (the literal incident this
# file exists to pin), pruning the stale links BEFORE `enable` instead of after,
# and looping every managed unit instead of only the drifted ones.
#
# So the --apply rows run against a recording `systemctl` STUB at the front of
# PATH — the pattern scripts/test-hspawn.sh uses for `herdr`, and for the same
# reason: this box has a real systemctl wired to a live user manager holding the
# herdr server that every agent session on the machine depends on. Hermetic must
# mean "answered by a fake", never "the tool happens to be absent". The stub
# emulates the one behaviour the ordering argument rests on — `enable` ADDS
# .wants links and never touches the unit symlink — and records what it was
# asked, so the suite can assert on the ORDER of operations and not only on the
# end state (enable-then-prune and prune-then-enable reach the SAME end state;
# only the failure path and the call order tell them apart).
#
# Requires: bash, awk. No sudo, no systemd, no network.
#
# Usage: scripts/test-systemd-reconcile.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/reconcile-systemd-units.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

command -v awk >/dev/null || fatal "awk is required"
[[ -x "$SUT" ]] || fatal "cannot execute $SUT"

# A fixture is: a fake checkout holding unit FILES, and a fake systemd user dir
# holding symlinks to them plus <target>.wants/ directories.
#
# $1 fixture name. Echoes the systemd dir.
new_fixture() {
    local n="$1"
    mkdir -p "$TMPROOT/$n/repo/systemd" "$TMPROOT/$n/sysd"
    printf '%s\n' "$TMPROOT/$n/sysd"
}

# $1 fixture, $2 unit name, $3 the [Install] body (may be empty), $4.. extra text
add_unit() {
    local n="$1" unit="$2" install_body="$3"
    {
        printf '[Unit]\nDescription=fixture %s\n\n[Service]\nExecStart=/bin/true\n' "$unit"
        if [[ -n "$install_body" ]]; then
            printf '\n[Install]\n%s\n' "$install_body"
        fi
    } > "$TMPROOT/$n/repo/systemd/$unit"
    ln -sf "$TMPROOT/$n/repo/systemd/$unit" "$TMPROOT/$n/sysd/$unit"
}

# $1 fixture, $2 unit, $3 target  — pretend `systemctl enable` ran for <target>
enable_under() {
    local n="$1" unit="$2" target="$3"
    mkdir -p "$TMPROOT/$n/sysd/${target}.wants"
    ln -sf "$TMPROOT/$n/repo/systemd/$unit" "$TMPROOT/$n/sysd/${target}.wants/$unit"
}

# $1 systemd dir, $2 checkout dir, $3.. args. The general form; run_sut is the
# common case where both live under the same fixture. Split out because F-C is
# precisely about the two paths naming the same tree in different ways.
run_at() {
    local sysd="$1" dot="$2"; shift 2
    SYSTEMD_USER_DIR="$sysd" DOTFILES_DIR="$dot" \
        RECONCILE_NO_SYSTEMCTL=1 bash "$SUT" "$@" 2>&1
}
rc_at() {
    local sysd="$1" dot="$2"; shift 2
    SYSTEMD_USER_DIR="$sysd" DOTFILES_DIR="$dot" \
        RECONCILE_NO_SYSTEMCTL=1 bash "$SUT" "$@" >/dev/null 2>&1
    echo $?
}

# $1 fixture, $2.. args to the script under test
run_sut() { local n="$1"; shift; run_at "$TMPROOT/$n/sysd" "$TMPROOT/$n/repo" "$@"; }
rc_sut()  { local n="$1"; shift; rc_at  "$TMPROOT/$n/sysd" "$TMPROOT/$n/repo" "$@"; }

#-----------------------------------------------------------------------------
# The systemctl stub — see the header. Everything --apply does passes through
# here or through the script's own `rm`, so this is what makes the mutating half
# of the script observable at all.
#-----------------------------------------------------------------------------
STUBBIN="$TMPROOT/bin"; mkdir -p "$STUBBIN"
SCTL_LOG="$TMPROOT/systemctl.log"
FAKE_XDG="$TMPROOT/xdg"; mkdir -p "$FAKE_XDG"

cat > "$STUBBIN/systemctl" <<'STUB'
#!/bin/sh
# Fake `systemctl --user` for scripts/test-systemd-reconcile.sh.
#
# Refuses to run at all without SYSTEMCTL_STUB_LOG and SYSTEMD_USER_DIR: if the
# stub is ever reached from an environment the suite did not build, the right
# outcome is a loud failure, not a quiet touch of the real user manager.
[ -n "${SYSTEMCTL_STUB_LOG:-}" ] || { echo "systemctl stub: no SYSTEMCTL_STUB_LOG" >&2; exit 99; }
[ -n "${SYSTEMD_USER_DIR:-}" ]   || { echo "systemctl stub: no SYSTEMD_USER_DIR" >&2; exit 99; }
printf 'CMD %s
' "$*" >> "$SYSTEMCTL_STUB_LOG"

[ "$1" = "--user" ] && shift
verb="${1:-}"; unit="${2:-}"

case "$verb" in
    show-environment) exit 0 ;;
    daemon-reload)    exit "${SYSTEMCTL_STUB_RELOAD_RC:-0}" ;;
    is-active)        echo "${SYSTEMCTL_STUB_ACTIVE:-inactive}"; exit 0 ;;
    show)             echo "${SYSTEMCTL_STUB_NEEDRELOAD:-no}"; exit 0 ;;
    enable) ;;
    *) exit 0 ;;
esac

# `enable`. Two behaviours are emulated because the script's correctness rests
# on them: (1) systemd REFUSES a unit with no [Install] WantedBy=, and (2) a
# successful enable only ADDS <target>.wants/ links — it never touches the unit
# symlink in the search path. (2) is the whole reason `enable` is safe here and
# `reenable` is not.
if [ "${SYSTEMCTL_STUB_FAIL_ENABLE:-}" = "$unit" ]; then
    echo "stub: enable refused" >&2
    exit 1
fi
targets=$(awk '
    /^[[:space:]]*\[/ { ins = ($0 ~ /^[[:space:]]*\[Install\][[:space:]]*$/); next }
    !ins { next }
    /^[[:space:]]*WantedBy[[:space:]]*=/ {
        sub(/^[[:space:]]*WantedBy[[:space:]]*=[[:space:]]*/, ""); gsub(/,/, " "); print
    }' "$SYSTEMD_USER_DIR/$unit" 2>/dev/null)
if [ -z "$targets" ]; then
    echo "stub: unit $unit has no installation config" >&2
    exit 1
fi
# Record the .wants links that exist at the MOMENT of enable. This is what makes
# enable-before-prune distinguishable from prune-before-enable: both reach the
# same end state, and only this line sees the stale link still present.
for d in "$SYSTEMD_USER_DIR"/*.wants; do
    [ -e "$d/$unit" ] || [ -L "$d/$unit" ] || continue
    printf 'PRE-ENABLE %s %s
' "$unit" "$(basename "$d")" >> "$SYSTEMCTL_STUB_LOG"
done
for t in $targets; do
    mkdir -p "$SYSTEMD_USER_DIR/${t}.wants"
    ln -sf "$(readlink "$SYSTEMD_USER_DIR/$unit" 2>/dev/null || echo "$SYSTEMD_USER_DIR/$unit")" \
           "$SYSTEMD_USER_DIR/${t}.wants/$unit"
done
exit 0
STUB
chmod +x "$STUBBIN/systemctl"

# $1 fixture, $2.. args. Runs the REAL mutating path, against the stub.
# Deliberately does NOT set RECONCILE_NO_SYSTEMCTL — that variable is what made
# every one of these rows unreachable before.
apply_at() {
    local sysd="$1" dot="$2"; shift 2
    case "$sysd" in
        "$TMPROOT"/*) ;;
        *) fatal "apply outside the fixture root: $sysd" ;;
    esac
    SYSTEMD_USER_DIR="$sysd" DOTFILES_DIR="$dot" PATH="$STUBBIN:$PATH" \
        XDG_RUNTIME_DIR="$FAKE_XDG" SYSTEMCTL_STUB_LOG="$SCTL_LOG" \
        SYSTEMCTL_STUB_FAIL_ENABLE="${STUB_FAIL_ENABLE:-}" \
        SYSTEMCTL_STUB_RELOAD_RC="${STUB_RELOAD_RC:-0}" \
        SYSTEMCTL_STUB_ACTIVE="${STUB_ACTIVE:-inactive}" \
        SYSTEMCTL_STUB_NEEDRELOAD="${STUB_NEEDRELOAD:-no}" \
        bash "$SUT" "$@" 2>&1
}
apply_sut() { local n="$1"; shift; : > "$SCTL_LOG"; apply_at "$TMPROOT/$n/sysd" "$TMPROOT/$n/repo" "$@"; }
rc_apply()  { local n="$1"; shift; : > "$SCTL_LOG"; apply_at "$TMPROOT/$n/sysd" "$TMPROOT/$n/repo" "$@" >/dev/null 2>&1; echo $?; }
# grep -c over the stub log, always a number.
inlog()  { grep -cF -- "$1" "$SCTL_LOG" 2>/dev/null || true; }
exists() { if [[ -e "$1" || -L "$1" ]]; then echo yes; else echo no; fi; }

echo
echo "=== harness: a known-drifted fixture must actually fail ==="
# Asserted first, because most rows below are of the form "nothing was reported",
# which is also what a script that never looked at the fixture produces.
new_fixture harness >/dev/null
add_unit harness a.service "WantedBy=graphical-session.target"
enable_under harness a.service default.target
check "drifted fixture exits 1"  "$(rc_sut harness --check)"                            "1"
# BOTH targets, on ONE line. Counting 'default.target' alone passed a message
# that had dropped the DECLARED target — the half that says what should happen —
# and 'graphical-session.target' contains 'default.target' nowhere, so an
# unanchored count of either one proves nothing about the other.
check "and names both targets"   \
      "$(run_sut harness --check | grep -c '✗ a.service: enabled under default.target, but its unit file declares graphical-session.target')" "1"
[[ "$(rc_sut harness --check)" == "1" ]] || fatal "the harness cannot produce a failing fixture; every row below is meaningless"

# The stub must be the systemctl any --apply row reaches. Asserted with a hard
# fatal, first, because the alternative is the REAL user manager on this box —
# which holds the herdr server every agent session depends on.
STUB_RESOLVED="$(PATH="$STUBBIN:$PATH" bash -c 'command -v systemctl')"
check "systemctl resolves to the stub" "$STUB_RESOLVED" "$STUBBIN/systemctl"
[[ "$STUB_RESOLVED" == "$STUBBIN/systemctl" ]] || fatal "the stub is not first on PATH; --apply rows would touch the real user manager"

# And do_reconcile's body must actually EXECUTE. Every --apply row below is of
# the form "the unit symlink survived" / "this unit was never enabled", which is
# also exactly what a run that returned at the have_user_manager gate produces —
# and that is precisely how the mutating half of the script went unpinned
# through a 44/44 run.
new_fixture canary >/dev/null
add_unit canary c.service "WantedBy=graphical-session.target"
enable_under canary c.service default.target
apply_sut canary --apply >/dev/null
check "apply actually reaches systemd" "$(inlog 'daemon-reload')" "1"
[[ "$(inlog 'daemon-reload')" == "1" ]] || fatal "do_reconcile returned before doing anything; every --apply row below is meaningless"

echo
echo "=== the four enablement states ==="
new_fixture states >/dev/null
add_unit states ok.service          "WantedBy=graphical-session.target"
enable_under states ok.service      graphical-session.target
add_unit states drifted.service     "WantedBy=graphical-session.target"
enable_under states drifted.service default.target
add_unit states notenabled.service  "WantedBy=default.target"
add_unit states static.service      ""

check "ok: reported as matching"     "$(run_sut states --check | grep -c '✓ ok.service')"          "1"
check "drifted: reported"            "$(run_sut states --check | grep -c '✗ drifted.service')"     "1"
# A unit nobody enabled is not drift. Calling it drift makes this permanently red
# on any machine that chose not to enable it — a permanently-red check is an
# ignored one, which is the failure mode the whole file is about.
check "not-enabled: says not enabled" "$(run_sut states --check | grep -c 'notenabled.service: not enabled')" "1"
check "not-enabled: not a ✗"          "$(run_sut states --check | grep -c '✗ notenabled')"                     "0"
# Likewise a unit with no WantedBy at all: started by hand, or pulled in by
# another unit's Wants=. There is nothing to reconcile. The message has to be
# asserted, not just the '·' prefix — the two notes are different answers, and a
# prefix-only check passed when 'static' silently collapsed into 'not-enabled'.
check "static: says no WantedBy"      "$(run_sut states --check | grep -c 'static.service: no WantedBy')"      "1"
check "static: not a ✗"               "$(run_sut states --check | grep -c '✗ static')"                         "0"
check "one ✗ overall exits 1"        "$(rc_sut states --check)"                                   "1"

echo
echo "=== which units count as ours ==="
new_fixture scope >/dev/null
add_unit scope mine.service "WantedBy=default.target"
enable_under scope mine.service default.target
# A real file in ~/.config/systemd/user is somebody else's unit, not one this
# repo links, and reconciling it would be this script overreaching.
printf '[Unit]\n[Install]\nWantedBy=graphical-session.target\n' > "$TMPROOT/scope/sysd/theirs.service"
mkdir -p "$TMPROOT/scope/sysd/default.target.wants"
ln -sf "$TMPROOT/scope/sysd/theirs.service" "$TMPROOT/scope/sysd/default.target.wants/theirs.service"
# A symlink pointing OUTSIDE the checkout is equally not ours.
mkdir -p "$TMPROOT/scope/elsewhere"
printf '[Unit]\n[Install]\nWantedBy=graphical-session.target\n' > "$TMPROOT/scope/elsewhere/foreign.service"
ln -sf "$TMPROOT/scope/elsewhere/foreign.service" "$TMPROOT/scope/sysd/foreign.service"

check "our symlinked unit is seen"   "$(run_sut scope --check | grep -c 'mine.service')"    "1"
# A plain file sits at the systemd dir's own path, so it can never resolve into
# the checkout — containment is what rejects it, not the symlink test.
check "a plain file cannot be ours"  "$(run_sut scope --check | grep -c 'theirs.service')"  "0"
check "a link outside is ignored"    "$(run_sut scope --check | grep -c 'foreign.service')" "0"
check "ours matching: exits 0"       "$(rc_sut scope --check)"                              "0"

# Timers are units too, and a timer is exactly the kind of thing added later and
# then never noticed by a hardcoded list.
new_fixture timers >/dev/null
add_unit timers t.timer "WantedBy=timers.target"
enable_under timers t.timer default.target
check "a .timer drifts too"          "$(run_sut timers --check | grep -c '✗ t.timer')"      "1"

echo
echo "=== parsing WantedBy: only real declarations count ==="
new_fixture parse >/dev/null
# Several targets, all enabled — the SET matches, so this is not drift. Declared
# in REVERSE alphabetical order on purpose: the comparison is a string compare
# of two space-joined lists and actual_targets() sorts, so both sides must sort
# or a correct machine reads as drifted. Written the other way round, the
# fixture declared its targets already sorted and dropping `sort` from
# declared_targets() changed nothing — the mutant was demonstrably broken and
# the suite still passed 44/44.
add_unit parse multi.service "WantedBy=graphical-session.target default.target"
enable_under parse multi.service default.target
enable_under parse multi.service graphical-session.target
check "multi-target, all enabled: ok" "$(run_sut parse --check | grep -c '✓ multi.service')" "1"
# ...and the -u half. systemd tolerates a target named twice (several WantedBy=
# lines are legal and are flattened); the comparison must not report that as
# drift against a single .wants link.
new_fixture dedup >/dev/null
{
    printf '[Unit]\nDescription=x\n\n[Service]\nExecStart=/bin/true\n'
    printf '\n[Install]\nWantedBy=default.target\nWantedBy=default.target\n'
} > "$TMPROOT/dedup/repo/systemd/d.service"
ln -sf "$TMPROOT/dedup/repo/systemd/d.service" "$TMPROOT/dedup/sysd/d.service"
enable_under dedup d.service default.target
check "a target declared twice: ok"   "$(run_sut dedup --check | grep -c '✓ d.service')" "1"
check "a target declared twice: rc 0" "$(rc_sut dedup --check)"                          "0"

new_fixture partial >/dev/null
add_unit partial half.service "WantedBy=default.target graphical-session.target"
enable_under partial half.service default.target
check "multi-target, half enabled: ✗" "$(run_sut partial --check | grep -c '✗ half.service')" "1"

new_fixture comment >/dev/null
# A comment never declares anything, and neither does a WantedBy in [Unit] —
# that key belongs to [Install], and honouring it elsewhere invents a target.
{
    printf '[Unit]\nDescription=x\nWantedBy=wrong.target\n\n[Service]\nExecStart=/bin/true\n'
    printf '\n[Install]\n# WantedBy=commented-out.target\nWantedBy=default.target\n'
} > "$TMPROOT/comment/repo/systemd/c.service"
ln -sf "$TMPROOT/comment/repo/systemd/c.service" "$TMPROOT/comment/sysd/c.service"
enable_under comment c.service default.target
check "commented WantedBy ignored"   "$(run_sut comment --check | grep -c 'commented-out')" "0"
check "WantedBy in [Unit] ignored"   "$(run_sut comment --check | grep -c 'wrong.target')"  "0"
check "the real one is honoured"     "$(run_sut comment --check | grep -c '✓ c.service')"   "1"
check "so it exits 0"                "$(rc_sut comment --check)"                            "0"

echo
echo "=== nothing to look at is not a failure ==="
new_fixture empty >/dev/null
check "no units: says so"    "$(run_sut empty --check | grep -c 'no systemd user units linked')" "1"
check "no units: exits 0"    "$(rc_sut empty --check)"                                          "0"

echo
echo "=== reconcile without a user manager ==="
# A server, a container and a CI runner all legitimately have none, and failing
# there would make ./install noisy on every machine that is not this laptop.
new_fixture noman >/dev/null
add_unit noman n.service "WantedBy=graphical-session.target"
enable_under noman n.service default.target
check "apply: says it skipped"  "$(run_sut noman --apply | grep -c 'no systemd user manager reachable')" "1"
check "apply: exits 0"          "$(rc_sut noman --apply)"                                                "0"
# And it must not have moved anything by hand while pretending systemd did.
check "apply: nothing moved"    "$([[ -e "$TMPROOT/noman/sysd/default.target.wants/n.service" ]] && echo kept)" "kept"
check "apply: nothing created"  "$([[ -d "$TMPROOT/noman/sysd/graphical-session.target.wants" ]] && echo yes || echo no)" "no"
echo
echo "=== --plan: which units reconcile would touch ==="
# The safety-critical line in the script. `reenable` on a DISABLED unit enables
# it, so acting on anything but 'drifted' would make ./install take a decision
# instead of reconciling one. --plan exists so that decision is observable
# without a systemd manager; while it lived inside the manager-gated loop this
# assertion could not fail, whatever the gate said (found by mutation).
check "plan: the drifted unit"        "$(run_sut states --plan | grep -cx 'drifted.service')"    "1"
check "plan: NOT the not-enabled one" "$(run_sut states --plan | grep -cx 'notenabled.service')" "0"
check "plan: NOT the static one"      "$(run_sut states --plan | grep -cx 'static.service')"     "0"
check "plan: NOT the matching one"    "$(run_sut states --plan | grep -cx 'ok.service')"         "0"
check "plan: only that one unit"      "$(run_sut states --plan | wc -l | tr -d ' ')"             "1"
check "plan: exits 0"                 "$(rc_sut states --plan)"                                  "0"
# "Changed nothing" has to name the unit: that directory already exists in this
# fixture, created for ok.service, so asserting on the directory passed for the
# wrong reason.
check "plan: moved no symlink"         "$([[ -e "$TMPROOT/states/sysd/graphical-session.target.wants/drifted.service" ]] && echo yes || echo no)" "no"
check "plan: left the old one alone"   "$([[ -e "$TMPROOT/states/sysd/default.target.wants/drifted.service" ]] && echo kept || echo gone)"       "kept"

echo
echo "=== --plan-stale: what --apply removes, and what it must never remove ==="
# The bug this pins cost a real machine its unit. `systemctl disable` (and so
# `reenable`) removes EVERY symlink in the unit search path pointing at the unit
# — and for a dotbot-installed unit, the entry in ~/.config/systemd/user IS such
# a symlink, into the checkout. So reenable deleted the unit and the enable half
# then failed with "Unit does not exist". --apply therefore enables (which only
# ADDS links) and prunes the stale .wants links itself.
check "stale: the old target's link"  "$(run_sut states --plan-stale | grep -c 'default.target.wants/drifted.service')" "1"
check "stale: not the new target's"   "$(run_sut states --plan-stale | grep -c 'graphical-session.target.wants/drifted')" "0"
# The regression test for the incident: the unit symlink itself must never be in
# the removal list, however the targets are arranged.
check "stale: NEVER the unit symlink" \
      "$(run_sut states --plan-stale | grep -cE '/sysd/[^/]+\.service$')" "0"
# The same guard on a REALISTICALLY NAMED unit. It was written `[a-z]+\.service`
# and every fixture unit was named ok/drifted/static — pure lowercase letters —
# so it matched. The one real unit this repo manages is herdr-server.service,
# and `echo /x/sysd/herdr-server.service | grep -cE '/sysd/[a-z]+\.service$'` is
# 0: the guard for the incident that cost the user their unit would have gone
# quietly dead the moment a fixture was named after production.
new_fixture realname >/dev/null
add_unit realname herdr-server.service "WantedBy=graphical-session.target"
enable_under realname herdr-server.service default.target
check "stale: the hyphenated unit's old link" \
      "$(run_sut realname --plan-stale | grep -c 'default.target.wants/herdr-server.service')" "1"
check "stale: NEVER a hyphenated unit symlink" \
      "$(run_sut realname --plan-stale | grep -cE '/sysd/[^/]+\.service$')" "0"
check "stale: nothing for a matching unit" "$(run_sut states --plan-stale | grep -c 'ok.service')"         "0"
check "stale: nothing for not-enabled"     "$(run_sut states --plan-stale | grep -c 'notenabled.service')" "0"
check "stale: exits 0"                     "$(rc_sut states --plan-stale)"                                 "0"
check "stale: removes nothing itself"      "$([[ -e "$TMPROOT/states/sysd/default.target.wants/drifted.service" ]] && echo kept)" "kept"

# Crude on purpose, and worth it: the whole incident was one wrong verb. A future
# edit that reaches for `reenable` or `disable` because it reads as the obvious
# primitive should fail here and be sent to the header comment explaining why.
# Comment and printf/echo lines are stripped first: the script deliberately NAMES
# those verbs, at length, in the header and in its advice — and a real invocation
# never shares a line with a comment marker, printf or echo.
check "the script never calls reenable/disable" \
      "$(grep -vE 'printf|echo|^[[:space:]]*#' "$SUT" | grep -cE 'systemctl[^#]*(reenable|disable)')" "0"

echo
echo "=== --apply: what the mutating half actually does ==="
# Everything in this section was unreachable until the systemctl stub existed —
# see the header. Each row names the mutation it exists to fail.

new_fixture apply >/dev/null
add_unit apply moved.service "WantedBy=graphical-session.target"
enable_under apply moved.service default.target
add_unit apply steady.service "WantedBy=default.target"
enable_under apply steady.service default.target
add_unit apply idle.service   "WantedBy=default.target"      # declared, never enabled
add_unit apply nowanted.service ""                            # static, no links
APPLY_OUT="$(apply_sut apply --apply)"

check "apply: reloads first"          "$(inlog 'daemon-reload')"                    "1"
check "apply: enables the drifted"    "$(inlog 'enable moved.service')"             "1"
check "apply: reports the move"       "$(grep -c '✓ moved.service: enablement moved to graphical-session.target' <<<"$APPLY_OUT")" "1"
check "apply: new link created"       "$(exists "$TMPROOT/apply/sysd/graphical-session.target.wants/moved.service")" "yes"
check "apply: stale link pruned"      "$(exists "$TMPROOT/apply/sysd/default.target.wants/moved.service")"           "no"

# THE incident. `systemctl disable` (so `reenable`) removes every symlink in the
# search path pointing at the unit, and for a dotbot-installed unit the entry in
# ~/.config/systemd/user IS such a symlink, into the checkout. Making
# do_reconcile also `rm -f "$SYSTEMD_USER_DIR/$unit"` — the literal incident —
# passed 44/44, because do_reconcile never ran and because the existing grep
# guard only looks for the words reenable/disable, not for `rm`.
check "apply: the unit symlink SURVIVES" "$(exists "$TMPROOT/apply/sysd/moved.service")" "yes"
check "apply: and still points into the checkout" \
      "$(readlink "$TMPROOT/apply/sysd/moved.service")" "$TMPROOT/apply/repo/systemd/moved.service"
check "apply: every managed unit still linked" \
      "$(for u in moved steady idle nowanted; do exists "$TMPROOT/apply/sysd/$u.service"; done | grep -c yes)" "4"

# The safety gate. `enable` on a unit nobody enabled ENABLES it, so acting on
# anything but 'drifted' turns ./install from reconciling a decision into taking
# one. Looping managed_units instead of units_to_reenable passed 44/44 — --plan
# calls units_to_reenable directly, so no plan row can see it.
check "apply: NEVER enables the not-enabled one" "$(inlog 'enable idle.service')"     "0"
check "apply: NEVER enables the matching one"    "$(inlog 'enable steady.service')"   "0"
check "apply: NEVER enables the static one"      "$(inlog 'enable nowanted.service')" "0"
check "apply: the not-enabled one stays off"     "$(exists "$TMPROOT/apply/sysd/default.target.wants/idle.service")" "no"
check "apply: the matching one is untouched"     "$(exists "$TMPROOT/apply/sysd/default.target.wants/steady.service")" "yes"
check "apply: exits 0"                           "$(rc_apply apply --apply)"          "0"

echo
echo "=== --apply: enable BEFORE prune, which is the whole ordering argument ==="
# Both orders reach the same end state, so an end-state assertion cannot tell
# them apart — and swapping them passed 44/44. Two rows that can: the stub
# records which .wants links existed at the moment of `enable`, and the failure
# path leaves the unit enabled under the OLD target rather than not at all.
new_fixture order >/dev/null
add_unit order o.service "WantedBy=graphical-session.target"
enable_under order o.service default.target
apply_sut order --apply >/dev/null
check "the stale link is still there when enable runs" \
      "$(inlog 'PRE-ENABLE o.service default.target.wants')" "1"

new_fixture failenable >/dev/null
add_unit failenable f.service "WantedBy=graphical-session.target"
enable_under failenable f.service default.target
STUB_FAIL_ENABLE=f.service
FAIL_OUT="$(apply_sut failenable --apply)"
check "enable failed: says so"            "$(grep -c '⚠ f.service: enable failed' <<<"$FAIL_OUT")"    "1"
check "enable failed: warns off reenable" "$(grep -c 'Do NOT use systemctl --user reenable' <<<"$FAIL_OUT")" "1"
# The reason the order is what it is, stated as a test: a failed enable must
# leave the unit enabled under the old target rather than not enabled at all.
check "enable failed: the OLD link is kept" \
      "$(exists "$TMPROOT/failenable/sysd/default.target.wants/f.service")" "yes"
check "enable failed: no ✓ printed"       "$(grep -c '✓ f.service' <<<"$FAIL_OUT")"                  "0"
# Still inside the failure window on purpose: resetting the stub before this row
# measured a SUCCESSFUL apply under a row named "enable failed".
check "enable failed: still exits 0"      "$(rc_apply failenable --apply)"                           "0"
STUB_FAIL_ENABLE=

# A daemon-reload that fails must stop the run before anything is moved.
new_fixture noreload >/dev/null
add_unit noreload r.service "WantedBy=graphical-session.target"
enable_under noreload r.service default.target
STUB_RELOAD_RC=1
RELOAD_OUT="$(apply_sut noreload --apply)"
STUB_RELOAD_RC=
check "reload failed: says so"         "$(grep -c 'daemon-reload failed' <<<"$RELOAD_OUT")"                    "1"
check "reload failed: enables nothing" "$(inlog 'enable r.service')"                                           "0"
check "reload failed: prunes nothing"  "$(exists "$TMPROOT/noreload/sysd/default.target.wants/r.service")"     "yes"

echo
echo "=== --apply: a running unit is told the restart is not free ==="
# The one message nothing else on the machine prints. It was also unreachable.
new_fixture active >/dev/null
add_unit active act.service "WantedBy=graphical-session.target"
enable_under active act.service default.target
STUB_ACTIVE=active
ACT_OUT="$(apply_sut active --apply)"
STUB_ACTIVE=
check "active: names the running instance" "$(grep -c 'the RUNNING instance still has the old unit' <<<"$ACT_OUT")" "1"
check "active: names the cost"             "$(grep -c 'ENDS EVERY AGENT SESSION' <<<"$ACT_OUT")"                    "1"
check "inactive: says nothing of the sort"  "$(grep -c 'RUNNING instance' <<<"$APPLY_OUT")"                         "0"

echo
echo "=== F-E: a prune that fails must not print a ✓ ==="
# `rm -f` succeeds loudly and fails quietly. The stale link was left in place and
# "✓ enablement moved to …" printed anyway — the silent-success class this whole
# file is about.
#
# The fixture makes `rm -f` fail by making the .wants ENTRY a non-empty
# directory rather than by chmod-ing its parent: `rm -f` on a directory fails
# for root too, and this suite runs both as an ordinary user here and as root in
# some containers. The property that decides the outcome is "rm returns
# non-zero", and that is what the fixture reproduces.
new_fixture unremovable >/dev/null
add_unit unremovable u.service "WantedBy=graphical-session.target"
mkdir -p "$TMPROOT/unremovable/sysd/default.target.wants/u.service/inner"
RM_OUT="$(apply_sut unremovable --apply)"
check "prune failed: says which link"  "$(grep -c 'could not remove the stale link' <<<"$RM_OUT")"                 "1"
check "prune failed: no ✓"             "$(grep -c '✓ u.service' <<<"$RM_OUT")"                                     "0"
check "prune failed: link still there" "$(exists "$TMPROOT/unremovable/sysd/default.target.wants/u.service")"      "yes"
check "prune failed: the new link was still created" \
      "$(exists "$TMPROOT/unremovable/sysd/graphical-session.target.wants/u.service")"                             "yes"
check "prune failed: unit symlink survives" "$(exists "$TMPROOT/unremovable/sysd/u.service")"                      "yes"
check "prune failed: still exits 0"    "$(rc_apply unremovable --apply)"                                           "0"

echo
echo "=== F-A: a dangling unit symlink is not an empty machine ==="
# Rename systemd/herdr-server.service in the repo, commit, don't re-run
# ./install: the ~/.config/systemd/user symlink dangles and the .wants link
# still points at a file that is gone. `-e` follows symlinks, so the unit was
# skipped and --check printed "no systemd user units linked … — skipped",
# exit 0 — character for character what an EMPTY machine prints, which the
# suite has its own row asserting is correct.
new_fixture dangling >/dev/null
add_unit dangling gone.service "WantedBy=graphical-session.target"
enable_under dangling gone.service default.target
rm -f "$TMPROOT/dangling/repo/systemd/gone.service"      # the rename nobody re-installed
check "dangling: NOT reported as empty" "$(run_sut dangling --check | grep -c 'no systemd user units linked')" "0"
check "dangling: reported as ✗"         "$(run_sut dangling --check | grep -c '✗ gone.service')"               "1"
check "dangling: names the cause"       "$(run_sut dangling --check | grep -c 'unit symlink resolves to nothing')" "1"
check "dangling: exits 1"               "$(rc_sut dangling --check)"                                           "1"
# It cannot be enabled and its declared targets cannot be read, so --apply must
# leave it entirely alone: the fix is ./install, not deleting anything.
check "dangling: not in --plan"         "$(run_sut dangling --plan | grep -c 'gone.service')"                   "0"
check "dangling: not in --plan-stale"   "$(run_sut dangling --plan-stale | grep -c 'gone.service')"             "0"
apply_sut dangling --apply >/dev/null
check "dangling: --apply enables nothing" "$(inlog 'enable gone.service')"                                      "0"
check "dangling: --apply removes nothing" "$(exists "$TMPROOT/dangling/sysd/default.target.wants/gone.service")" "yes"
check "dangling: unit symlink survives"   "$(exists "$TMPROOT/dangling/sysd/gone.service")"                      "yes"

# The other half of the same `-e`: a .wants entry whose target was renamed away
# is still a link systemd walks at boot, so the unit IS enabled under it.
new_fixture danglingwants >/dev/null
add_unit danglingwants w.service "WantedBy=graphical-session.target"
mkdir -p "$TMPROOT/danglingwants/sysd/default.target.wants"
ln -sf "$TMPROOT/danglingwants/repo/systemd/renamed-away.service" \
       "$TMPROOT/danglingwants/sysd/default.target.wants/w.service"
check "a dangling .wants link still counts as enabled" \
      "$(run_sut danglingwants --check | grep -c '✗ w.service: enabled under default.target')" "1"
check "and is listed for removal" \
      "$(run_sut danglingwants --plan-stale | grep -c 'default.target.wants/w.service')" "1"

echo
echo "=== F-B: deleting [Install] must not leave the unit enabled forever ==="
# Make herdr-server.service manual-start-only by deleting its [Install]. The
# reviewed unit file says it starts on demand; the machine still starts it at
# every graphical login from the leftover .wants symlink. That was classified
# 'static' and printed as "· no WantedBy= — nothing to reconcile", exit 0.
# 'static' is the right call for a unit that was NEVER enabled — it is 'static'
# WITH a live .wants link that is drift.
new_fixture orphan >/dev/null
add_unit orphan orph.service ""
enable_under orphan orph.service default.target
add_unit orphan quiet.service ""                    # genuinely static: no link
check "orphan .wants: reported as ✗"   "$(run_sut orphan --check | grep -c '✗ orph.service')"                 "1"
check "orphan .wants: names the target" "$(run_sut orphan --check | grep -c 'enabled under default.target')"   "1"
check "orphan .wants: not 'nothing to reconcile'" \
      "$(run_sut orphan --check | grep -c 'orph.service: no WantedBy= — nothing to reconcile')" "0"
check "orphan .wants: exits 1"         "$(rc_sut orphan --check)"                                              "1"
# A unit with no [Install] AND no link is still just static.
check "a truly static unit stays a ·"  "$(run_sut orphan --check | grep -c '· quiet.service: no WantedBy')"    "1"
# It cannot be `enable`d (systemd refuses a unit with no installation config),
# so it is pruned and never enabled — the two lists are kept apart for that.
check "orphan .wants: NOT in --plan"   "$(run_sut orphan --plan | grep -c 'orph.service')"                     "0"
check "orphan .wants: IS in --plan-stale" \
      "$(run_sut orphan --plan-stale | grep -c 'default.target.wants/orph.service')" "1"
ORPH_OUT="$(apply_sut orphan --apply)"
check "orphan .wants: --apply never calls enable" "$(inlog 'enable orph.service')"                             "0"
check "orphan .wants: --apply removed the link" \
      "$(exists "$TMPROOT/orphan/sysd/default.target.wants/orph.service")" "no"
check "orphan .wants: unit symlink survives"      "$(exists "$TMPROOT/orphan/sysd/orph.service")"              "yes"
check "orphan .wants: says it no longer starts itself" \
      "$(grep -c 'no longer starts on its own' <<<"$ORPH_OUT")" "1"
check "orphan .wants: the static one was not touched" \
      "$(inlog 'enable quiet.service')" "0"

echo
echo "=== F-C: the checkout reached through a symlink is the same checkout ==="
# ~/.dotfiles -> ~/src/dotfiles is an ordinary layout, and DOTFILES_ROOT exists
# as an override precisely because the checkout moves. bash's cd/pwd are
# LOGICAL and the containment test compares against readlink -f, which is
# PHYSICAL, so containment could never hold: same fixture, same drift, opposite
# verdicts depending on which spelling of the path you invoked it with.
new_fixture symlinked >/dev/null
add_unit symlinked s.service "WantedBy=graphical-session.target"
enable_under symlinked s.service default.target
ln -s "$TMPROOT/symlinked/repo" "$TMPROOT/symlinked/via-link"
check "via the real path: drift found" \
      "$(run_at "$TMPROOT/symlinked/sysd" "$TMPROOT/symlinked/repo" --check | grep -c '✗ s.service')" "1"
check "via a symlinked path: same verdict" \
      "$(run_at "$TMPROOT/symlinked/sysd" "$TMPROOT/symlinked/via-link" --check | grep -c '✗ s.service')" "1"
check "via a symlinked path: same exit code" \
      "$(rc_at "$TMPROOT/symlinked/sysd" "$TMPROOT/symlinked/via-link" --check)" "1"
check "via a symlinked path: not reported as empty" \
      "$(run_at "$TMPROOT/symlinked/sysd" "$TMPROOT/symlinked/via-link" --check | grep -c 'no systemd user units linked')" "0"
# ...and containment must still REJECT a genuinely foreign tree, or the fix
# would be "resolve everything and compare nothing".
mkdir -p "$TMPROOT/symlinked/other"
printf '[Unit]\n[Install]\nWantedBy=default.target\n' > "$TMPROOT/symlinked/other/alien.service"
ln -sf "$TMPROOT/symlinked/other/alien.service" "$TMPROOT/symlinked/sysd/alien.service"
check "a foreign tree is still rejected" \
      "$(run_at "$TMPROOT/symlinked/sysd" "$TMPROOT/symlinked/via-link" --check | grep -c 'alien.service')" "0"

# Nothing above ever lets the script DERIVE its own DOTFILES_DIR — every row
# hands one in — so both halves of the F-C fix could be reverted together and
# the rows above would still pass. Here the script is copied into a fixture
# checkout and invoked THROUGH a symlink to it, with DOTFILES_DIR unset: this is
# the shape of ~/.dotfiles -> ~/src/dotfiles, which is what F-C was about.
mkdir -p "$TMPROOT/symlinked/repo/scripts"
cp "$SUT" "$TMPROOT/symlinked/repo/scripts/"
check "invoked through a symlinked checkout path" \
      "$(env -u DOTFILES_DIR SYSTEMD_USER_DIR="$TMPROOT/symlinked/sysd" RECONCILE_NO_SYSTEMCTL=1 \
             bash "$TMPROOT/symlinked/via-link/scripts/${SUT##*/}" --check 2>&1 | grep -c '✗ s.service')" "1"
check "invoked through the real checkout path" \
      "$(env -u DOTFILES_DIR SYSTEMD_USER_DIR="$TMPROOT/symlinked/sysd" RECONCILE_NO_SYSTEMCTL=1 \
             bash "$TMPROOT/symlinked/repo/scripts/${SUT##*/}" --check 2>&1 | grep -c '✗ s.service')" "1"

echo
echo "=== F-D: the unit-type list is derived, not two hardcoded suffixes ==="
# The header argues that deriving the list means a unit added later is covered
# the moment dotbot links it, "hardcoding is how the next one gets missed" — and
# then the glob was *.service and *.timer only. .socket, .path and .target are
# ordinary user units; a drifted one read as "no systemd user units linked …",
# exit 0.
new_fixture suffixes >/dev/null
for u in a.socket b.path c.target d.mount e.slice; do
    add_unit suffixes "$u" "WantedBy=graphical-session.target"
    enable_under suffixes "$u" default.target
done
check "a .socket drifts"  "$(run_sut suffixes --check | grep -c '✗ a.socket')"  "1"
check "a .path drifts"    "$(run_sut suffixes --check | grep -c '✗ b.path')"    "1"
check "a .target drifts"  "$(run_sut suffixes --check | grep -c '✗ c.target')"  "1"
check "a .mount drifts"   "$(run_sut suffixes --check | grep -c '✗ d.mount')"   "1"
check "a .slice drifts"   "$(run_sut suffixes --check | grep -c '✗ e.slice')"   "1"
check "all five, no more" "$(run_sut suffixes --plan | wc -l | tr -d ' ')"      "5"
# ...and the widened glob must not swallow the directories that live alongside:
# <target>.wants/ and a unit's drop-in .d/ are not units.
mkdir -p "$TMPROOT/suffixes/sysd/a.socket.d"
printf '[Service]\n' > "$TMPROOT/suffixes/sysd/a.socket.d/10-x.conf"
ln -sf "$TMPROOT/suffixes/repo/systemd/a.socket" "$TMPROOT/suffixes/sysd/notaunit.conf"
check "a .wants directory is not a unit" "$(run_sut suffixes --check | grep -c 'default.target.wants:')" "0"
check "a drop-in directory is not a unit" "$(run_sut suffixes --check | grep -c 'a.socket.d')"           "0"
check "a linked non-unit file is ignored" "$(run_sut suffixes --check | grep -c 'notaunit.conf')"        "0"

echo
echo "=== --check: NeedDaemonReload is drift of the same kind ==="
# Also unreachable before the stub: the branch runs only when a user manager is
# present. The file on disk is what is under review; the loaded unit is what
# actually runs.
new_fixture reload >/dev/null
add_unit reload rl.service "WantedBy=default.target"
enable_under reload rl.service default.target
STUB_NEEDRELOAD=yes
RELOADED="$(apply_sut reload --check)"
RELOAD_RC="$(rc_apply reload --check)"
STUB_NEEDRELOAD=
check "not re-read: reported"  "$(grep -c 'systemd has not re-read this unit' <<<"$RELOADED")" "1"
check "not re-read: exits 1"   "$RELOAD_RC"                                                    "1"
check "re-read: silent"        "$(apply_sut reload --check | grep -c 'has not re-read')"       "0"
check "re-read: exits 0"       "$(rc_apply reload --check)"                                    "0"
# A unit systemd cannot even load must not be asked about its load timestamp.
check "a dangling unit is not probed for a reload" \
      "$(apply_sut dangling --check >/dev/null; inlog 'show gone.service')" "0"

echo
echo "=== F-F: --help prints the whole header, not a hardcoded line range ==="
# `sed -n '3,50p'` truncated mid-sentence inside the --plan description as the
# header grew, so --plan-stale and the exit-code paragraph — the two things a
# reader opens --help for — were never printed by it.
HELP_OUT="$(run_sut empty --help)"
check "--help reaches --plan-stale"      "$(grep -c -- '--plan-stale' <<<"$HELP_OUT")"          "1"
check "--help reaches the exit codes"    "$(grep -c 'Exit code:' <<<"$HELP_OUT")"               "1"
check "--help reaches the last line"     "$(grep -c 'RECONCILE_NO_SYSTEMCTL' <<<"$HELP_OUT")"   "1"
check "--help stops at the code"         "$(grep -c 'set -uo pipefail' <<<"$HELP_OUT")"         "0"

echo
echo "=== usage ==="
check "a bogus argument exits 2" "$(rc_sut empty --nonsense)" "2"
check "--help exits 0"           "$(rc_sut empty --help)"     "0"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
