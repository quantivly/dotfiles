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

# $1 fixture, $2.. args to the script under test
run_sut() {
    local n="$1"; shift
    SYSTEMD_USER_DIR="$TMPROOT/$n/sysd" DOTFILES_DIR="$TMPROOT/$n/repo" \
        RECONCILE_NO_SYSTEMCTL=1 bash "$SUT" "$@" 2>&1
}
rc_sut() {
    local n="$1"; shift
    SYSTEMD_USER_DIR="$TMPROOT/$n/sysd" DOTFILES_DIR="$TMPROOT/$n/repo" \
        RECONCILE_NO_SYSTEMCTL=1 bash "$SUT" "$@" >/dev/null 2>&1
    echo $?
}

echo
echo "=== harness: a known-drifted fixture must actually fail ==="
# Asserted first, because most rows below are of the form "nothing was reported",
# which is also what a script that never looked at the fixture produces.
new_fixture harness >/dev/null
add_unit harness a.service "WantedBy=graphical-session.target"
enable_under harness a.service default.target
check "drifted fixture exits 1"  "$(rc_sut harness --check)"                            "1"
check "and names both targets"   "$(run_sut harness --check | grep -c 'default.target')" "1"
[[ "$(rc_sut harness --check)" == "1" ]] || fatal "the harness cannot produce a failing fixture; every row below is meaningless"

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
# Several targets, all enabled — the set matches, so this is not drift.
add_unit parse multi.service "WantedBy=default.target graphical-session.target"
enable_under parse multi.service default.target
enable_under parse multi.service graphical-session.target
check "multi-target, all enabled: ok" "$(run_sut parse --check | grep -c '✓ multi.service')" "1"

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
      "$(run_sut states --plan-stale | grep -cE '/sysd/[a-z]+\.service$')" "0"
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
echo "=== usage ==="
check "a bogus argument exits 2" "$(rc_sut empty --nonsense)" "2"
check "--help exits 0"           "$(rc_sut empty --help)"     "0"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
