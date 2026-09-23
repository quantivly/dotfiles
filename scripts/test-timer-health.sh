#!/usr/bin/env bash
#
# scripts/test-timer-health.sh
# ============================
#
# State table for scripts/check-timer-health.sh.
#
# HERMETIC via a recording `systemctl` STUB at the front of PATH — never by
# relying on systemctl being absent. This box has a real one wired to a live user
# manager that holds the herdr server every agent session on the machine depends
# on, plus an armed wt-gc-sweep.timer that DELETES worktrees. A suite that
# assumed absence would pass on a CI runner and tell you nothing here, which is
# exactly the shape scripts/test-systemd-reconcile.sh's header warns about after
# its own --apply rows turned out to have executed zero times.
#
# The stub answers the four things the checker asks — show-environment,
# `show --timestamp=unix`, `is-enabled`, and `list-timers --all -o json` — from
# per-unit fixture files, and records its argv so a row can assert what was NOT
# asked (a bare template must never be queried; an unenabled unit must not be
# inspected).
#
# The OWNERSHIP half is deliberately NOT stubbed: the fake checkout holds a real
# COPY of scripts/reconcile-systemd-units.sh, so every row also exercises
# --list-managed and the physical-path containment behind it. Faking that would
# have left the one piece of cross-script wiring in this feature unpinned. A copy
# and not a symlink — see reset().
#
# "Could not run" is exit 2, never a pass. The suite asserts its own row total.
#
# Requires: bash, awk, sed, jq. No sudo, no systemd, no network.
#
# Usage: scripts/test-timer-health.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SUT="$DOTFILES/scripts/check-timer-health.sh"
RECONCILER="$DOTFILES/scripts/reconcile-systemd-units.sh"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
grep_ok()   { if grep -q -- "$2" <<<"$1"; then ok "$3"; else bad "$3 — output did not contain '$2'"; fi; }
grep_none() { if grep -q -- "$2" <<<"$1"; then bad "$3 — output unexpectedly contained '$2'"; else ok "$3"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

[[ -x "$SUT" ]]         || fatal "cannot execute $SUT"
[[ -x "$RECONCILER" ]]  || fatal "cannot execute $RECONCILER"
command -v awk >/dev/null || fatal "awk is required"
command -v jq  >/dev/null || fatal "jq is required"

T="$(mktemp -d)" || fatal "no temp dir"
trap 'rm -rf "$T"' EXIT
STUBBIN="$T/bin"
mkdir -p "$STUBBIN" || fatal "setup"

# A frozen clock, so "stale" and "fresh" are properties of the fixture and not of
# when the suite happens to run.
NOW=1790000000
US=1000000

# ---------------------------------------------------------------------------
# The systemctl stub
# ---------------------------------------------------------------------------
cat > "$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
# Fake `systemctl --user` for scripts/test-timer-health.sh.
[ -n "${SCTL_STATE:-}" ] || { echo "systemctl stub: no SCTL_STATE" >&2; exit 99; }
printf '%s\n' "$*" >> "$SCTL_STATE/calls.log"

[ "${1:-}" = "--user" ] || { echo "systemctl stub: refusing a non---user call: $*" >&2; exit 99; }
shift

case "${1:-}" in
  show-environment)
    [ -e "$SCTL_STATE/no-manager" ] && exit 1
    echo "LANG=C"; exit 0 ;;
  is-enabled)
    f="$SCTL_STATE/enabled/${2}"
    if [ -r "$f" ]; then cat "$f"; exit 0; fi
    echo "linked"; exit 0 ;;
  list-timers)
    if [ -r "$SCTL_STATE/timers.json" ]; then cat "$SCTL_STATE/timers.json"; else echo '[]'; fi
    exit 0 ;;
  show)
    shift
    unit=""
    for a in "$@"; do
      case "$a" in
        --*|-p) continue ;;
        LoadState|ActiveState|UnitFileState|Result|ExecMainStatus|ConditionResult|ConditionTimestamp|ActiveEnterTimestamp|NRestarts) continue ;;
        *) [ -z "$unit" ] && unit="$a" ;;
      esac
    done
    case "$unit" in
      # The real systemctl ERRORS on a bare template. Reproduced, so a row can
      # prove the checker never asks.
      *@.*) echo "Unit name $unit is neither a valid invocation ID nor unit name." >&2; exit 1 ;;
    esac
    f="$SCTL_STATE/props/$unit"
    if [ -r "$f" ]; then cat "$f"; exit 0; fi
    # Measured on systemd 259: an unknown unit exits 0 and claims success.
    printf 'LoadState=not-found\nActiveState=inactive\nUnitFileState=\nResult=success\nExecMainStatus=0\nConditionResult=no\nConditionTimestamp=\nActiveEnterTimestamp=\nNRestarts=0\n'
    exit 0 ;;
esac
echo "systemctl stub: unhandled: $*" >&2
exit 99
STUB
chmod +x "$STUBBIN/systemctl" || fatal "setup"

STUB_RESOLVED="$(PATH="$STUBBIN:$PATH" bash -c 'command -v systemctl')"
check "systemctl resolves to the stub" "$STUB_RESOLVED" "$STUBBIN/systemctl"
[[ "$STUB_RESOLVED" == "$STUBBIN/systemctl" ]] || \
  fatal "the stub is not first on PATH; rows would query the REAL user manager"

# A PATH with every tool the checker and the reconciler need EXCEPT jq, for the
# "could not run" row. Built by symlink, so jq is genuinely absent rather than
# mocked into absence.
NOJQ="$T/nojq"
mkdir -p "$NOJQ" || fatal "setup"
for t in bash sh awk sed grep tr sort head cat date readlink rm ls mkdir dirname basename; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$t"
done
[[ ! -e "$NOJQ/jq" ]] || fatal "setup: jq leaked into the no-jq PATH"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
CHECKOUT="$T/checkout"      # a fake dotfiles checkout
SUDIR="$T/systemd-user"     # a fake ~/.config/systemd/user
STATE="$T/state"            # what the stub answers from

reset() {
    rm -rf "$CHECKOUT" "$SUDIR" "$STATE"
    mkdir -p "$CHECKOUT/systemd" "$CHECKOUT/scripts" "$SUDIR" \
             "$STATE/props" "$STATE/enabled" || fatal "setup"
    # A REAL reconciler, so --list-managed and its containment logic run for real
    # — but a COPY, never a symlink. A row below replaces this file with a stub
    # that cannot answer --list-managed, and `>` follows a symlink: the first
    # draft of this suite truncated scripts/reconcile-systemd-units.sh in the
    # working tree, from inside a test whose subject is a script that must never
    # delete the wrong file. A copy also keeps the fixture honest, because
    # readlink -f containment then resolves inside the fake checkout.
    cp -f "$RECONCILER" "$CHECKOUT/scripts/reconcile-systemd-units.sh" || fatal "setup"
    chmod +x "$CHECKOUT/scripts/reconcile-systemd-units.sh" || fatal "setup"
    : > "$STATE/calls.log"
}

# link_unit <unit> [extra unit-file line ...]
link_unit() {
    local unit="$1" l; shift
    { printf '[Unit]\nDescription=%s\n' "$unit"
      for l in "$@"; do printf '%s\n' "$l"; done
      printf '[Install]\nWantedBy=default.target\n'; } > "$CHECKOUT/systemd/$unit"
    ln -sf "$CHECKOUT/systemd/$unit" "$SUDIR/$unit"
}

set_enabled() { printf '%s\n' "$2" > "$STATE/enabled/$1"; }

# props <unit> <LoadState> <ActiveState> <Result> <ExecMainStatus> <ConditionResult> <ConditionTimestamp> <ActiveEnterTimestamp> [NRestarts]
# NRestarts is optional and defaults to 0, so every row written before it existed
# still describes exactly the machine it described then.
props() {
    printf 'LoadState=%s\nActiveState=%s\nUnitFileState=enabled\nResult=%s\nExecMainStatus=%s\nConditionResult=%s\nConditionTimestamp=%s\nActiveEnterTimestamp=%s\nNRestarts=%s\n' \
        "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:-0}" > "$STATE/props/$1"
}

timers_json() { printf '%s\n' "$1" > "$STATE/timers.json"; }

# A timer JSON row helper: row <unit> <svc> <next_sec> <last_sec>
row() { printf '{"next":%d,"last":%d,"unit":"%s","activates":"%s"}' \
        $(( $3 * US )) $(( $4 * US )) "$1" "$2"; }

run() {
    # XDG_STATE_HOME is pinned here too, not only in ws(): before the arity check
    # existed, the row `run --write-state --extra` fell through to a real
    # --write-state and wrote to the TESTER'S OWN ~/.local/state/timer-health,
    # which is the file the live shell prompt reads. Found by noticing a state
    # file this session never meant to create. A fixture that can reach live
    # state is not hermetic, whatever it asserts.
    PATH="$STUBBIN:$PATH" SCTL_STATE="$STATE" \
    SYSTEMD_USER_DIR="$SUDIR" TIMER_HEALTH_NOW="$NOW" \
    XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$T/xdg-run" \
    "$SUT" "$@" 2>&1
}
asked() { grep -c -- "$1" "$STATE/calls.log" 2>/dev/null || true; }

# The steady state every fault row is a single change away from: a 30-minute
# timer that fired 10 minutes ago, and a healthy service.
healthy() {
    reset
    link_unit precompute.timer
    link_unit precompute.service 'ConditionPathExists=/nonexistent/wt-gc'
    set_enabled precompute.timer enabled
    props precompute.timer loaded active success 0 yes "@$((NOW-600))" "@$((NOW-6000))"
    props precompute.service loaded inactive success 0 yes "@$((NOW-600))" ""
    timers_json "[$(row precompute.timer precompute.service $((NOW+1200)) $((NOW-600)))]"
}

# ---------------------------------------------------------------------------
printf '\nownership and discovery\n'

reset
OUT="$(run)"; RC=$?
check "nothing linked: exit 0" "$RC" 0
grep_ok "$OUT" 'no managed systemd user units linked' "nothing linked: says skipped, not clean"

healthy
rm -f "$CHECKOUT/scripts/reconcile-systemd-units.sh"
printf '#!/bin/sh\nexit 2\n' > "$CHECKOUT/scripts/reconcile-systemd-units.sh"
chmod +x "$CHECKOUT/scripts/reconcile-systemd-units.sh"
OUT="$(run)"; RC=$?
check "reconciler cannot answer --list-managed: exit 2" "$RC" 2

# Links exist, and the checkout they point into cannot be asked about them. This
# must NOT collapse into "nothing is linked" — that was a real hole, found by
# this row: it exited 0 with a ○ while ownership was unknown.
healthy
rm -f "$CHECKOUT/scripts/reconcile-systemd-units.sh"
OUT="$(run)"; RC=$?
check "linked, but the owning checkout has no reconciler: exit 2" "$RC" 2
grep_ok "$OUT" 'OWNERSHIP is unknown' "no reconciler in the owning checkout: says ownership is unknown"
grep_none "$OUT" 'no managed systemd user units linked' "no reconciler: not reported as an empty machine"

# A checkout that is reachable and answers, but owns no UNITS: everything it has
# linked here has a suffix systemd does not treat as a unit.
healthy
rm -f "$SUDIR"/*.timer "$SUDIR"/*.service
mkdir -p "$T/other/systemd" "$T/other/scripts"
cp -f "$RECONCILER" "$T/other/scripts/reconcile-systemd-units.sh"
chmod +x "$T/other/scripts/reconcile-systemd-units.sh"
printf 'x\n' > "$T/other/systemd/notes.conf"
ln -sf "$T/other/systemd/notes.conf" "$SUDIR/notes.conf"
OUT="$(run)"; RC=$?
check "a checkout that owns no units here: exit 0" "$RC" 0
grep_ok "$OUT" 'owns no systemd user units' "owns nothing: says so"

# A bare template is linked by dotbot and MUST NOT be queried — the real
# systemctl errors on one.
healthy
link_unit 'rabota-precompute@.timer'
link_unit 'rabota-precompute@.service'
OUT="$(run)"; RC=$?
check "a bare template does not break the run" "$RC" 0
check "the bare template is never passed to systemctl" "$(asked 'rabota-precompute@\.')" 0

printf '\nthe manager, and the tools needed to ask it\n'

healthy
OUT="$( unset XDG_RUNTIME_DIR
        PATH="$STUBBIN:$PATH" SCTL_STATE="$STATE" SYSTEMD_USER_DIR="$SUDIR" \
        TIMER_HEALTH_NOW="$NOW" "$SUT" 2>&1 )"; RC=$?
check "no user manager reachable: exit 0" "$RC" 0
grep_ok "$OUT" 'no systemd user manager reachable' "no manager: says skipped"

healthy
touch "$STATE/no-manager"
OUT="$(run)"; RC=$?
check "show-environment fails: exit 0, skipped" "$RC" 0
grep_ok "$OUT" 'skipped' "manager unreachable: says skipped"
rm -f "$STATE/no-manager"

healthy
OUT="$(PATH="$STUBBIN:$NOJQ" SCTL_STATE="$STATE" SYSTEMD_USER_DIR="$SUDIR" \
        TIMER_HEALTH_NOW="$NOW" XDG_RUNTIME_DIR="$T/run" "$SUT" 2>&1)"; RC=$?
check "jq missing: exit 2, not 0" "$RC" 2
grep_ok "$OUT" 'UNCHECKED' "jq missing: names it UNCHECKED"

printf '\nthe healthy steady state\n'

healthy
OUT="$(run)"; RC=$?
check "healthy timer + service: exit 0" "$RC" 0
grep_ok "$OUT" '✓ precompute.timer' "healthy: a tick for the timer"
grep_ok "$OUT" '(precompute.service ok)' "healthy: the service is named as CHECKED, not silent"

healthy
set_enabled precompute.timer linked
OUT="$(run)"; RC=$?
check "linked but not enabled is a DECISION: exit 0" "$RC" 0
grep_ok "$OUT" 'linked, not enabled' "not enabled: says so rather than passing silently"
check "not enabled: its properties are never read" "$(asked 'show .*precompute.timer')" 0

printf '\ntimer faults\n'

healthy
timers_json '[]'
OUT="$(run)"; RC=$?
check "enabled but absent from list-timers: exit 1" "$RC" 1
grep_ok "$OUT" 'does not list it as a timer' "absent from list-timers: named"

healthy
props precompute.timer loaded inactive success 0 yes "@$((NOW-600))" "@$((NOW-6000))"
OUT="$(run)"; RC=$?
check "timer not active: exit 1" "$RC" 1
grep_ok "$OUT" 'will not fire' "inactive timer: named"

healthy
timers_json "[$(row precompute.timer precompute.service 0 $((NOW-600)))]"
OUT="$(run)"; RC=$?
check "active with no next elapse: exit 1" "$RC" 1
grep_ok "$OUT" 'NO next run scheduled' "no next elapse: named"

# THE REGRESSION, 2026-09-23. A timer whose triggered unit is RUNNING has no
# next elapse -- systemd schedules one only when the run finishes -- and
# list-timers reports "next": null, which jq's `// 0` makes indistinguishable
# from a stopped timer's 0. Shipped calling wt-gc-sweep.timer "it has stopped
# firing" on its own first unattended run, while the sweep was mid-flight.
#
# The row above this one pinned the branch but asserted the WRONG rule: its
# fixture had the service inactive, so it never described the state the real
# machine produced. Both readings of next=0 are now rows.
healthy
props precompute.service loaded activating success 0 yes "@$((NOW-600))" "@$((NOW-60))"
timers_json "[$(row precompute.timer precompute.service 0 $((NOW-60)))]"
OUT="$(run)"; RC=$?
check "a timer whose service is RUNNING is not 'stopped': exit 0" "$RC" 0
grep_ok "$OUT" 'is running now' "mid-run: says the service is running"
grep_none "$OUT" 'stopped firing' "mid-run: not reported as stopped"
grep_none "$OUT" 'STALE' "mid-run: freshness is not judged on a run in progress"

healthy
props precompute.service loaded active success 0 yes "@$((NOW-600))" "@$((NOW-60))"
timers_json "[$(row precompute.timer precompute.service 0 $((NOW-60)))]"
check "the same for ActiveState=active, not just activating: exit 0" "$(run >/dev/null 2>&1; echo $?)" 0

# ... and the fault is still a fault when nothing is running.
healthy
props precompute.service loaded inactive success 0 yes "@$((NOW-600))" ""
timers_json "[$(row precompute.timer precompute.service 0 $((NOW-600)))]"
OUT="$(run)"; RC=$?
check "next=0 with the service NOT running is still a fault: exit 1" "$RC" 1
grep_ok "$OUT" 'stopped firing' "not running + no next: named as stopped"

healthy
timers_json "[$(row precompute.timer precompute.service $((NOW+20*86400)) $((NOW-600)))]"
OUT="$(run)"; RC=$?
check "next run beyond the horizon: exit 1" "$RC" 1
grep_ok "$OUT" 'OnCalendar' "beyond horizon: points at the calendar spec"
# The horizon is NOT redundant with staleness: this same fixture is not stale,
# because the derived cycle is as wide as the mistake.
grep_none "$OUT" 'STALE' "beyond horizon: staleness alone could never catch it"

healthy
timers_json "[$(row precompute.timer precompute.service $((NOW+13*86400)) $((NOW-600)))]"
OUT="$(run)"; RC=$?
check "13 days away is inside the 14-day horizon" "$RC" 0

printf '\nfreshness, derived from the timer schedule\n'

# Never fired, armed recently — wt-gc-sweep.timer was in exactly this state on
# the day this was written, and must not read as infinitely stale.
healthy
props precompute.timer loaded active success 0 yes "@$((NOW-600))" "@$((NOW-3600))"
timers_json "[$(row precompute.timer precompute.service $((NOW+40000)) 0)]"
OUT="$(run)"; RC=$?
check "never fired, armed an hour ago: exit 0" "$RC" 0
grep_ok "$OUT" 'last run never' "never fired: reported as never, not as 1970"

# Never fired, and its first run is long overdue.
healthy
props precompute.timer loaded active success 0 yes "@$((NOW-600))" "@$((NOW-100000))"
timers_json "[$(row precompute.timer precompute.service $((NOW-60000)) 0)]"
OUT="$(run)"; RC=$?
check "never fired and a full cycle overdue: exit 1" "$RC" 1
grep_ok "$OUT" 'STALE' "never fired + overdue: STALE"

healthy
timers_json "[$(row precompute.timer precompute.service $((NOW+1200)) $((NOW-1800)))]"
OUT="$(run)"; RC=$?
check "fired within its cycle: exit 0" "$RC" 0

# cycle = next - last = 1800; the limit is next + cycle.
healthy
timers_json "[$(row precompute.timer precompute.service $((NOW-1801)) $((NOW-3601)))]"
OUT="$(run)"; RC=$?
check "one second past next + cycle: exit 1" "$RC" 1
grep_ok "$OUT" 'STALE' "past the limit: STALE"

healthy
timers_json "[$(row precompute.timer precompute.service $((NOW-1800)) $((NOW-3600)))]"
OUT="$(run)"; RC=$?
check "exactly AT next + cycle is not yet stale (> not >=)" "$RC" 0

printf '\nservice faults\n'

# The measured trap: an unknown unit exits 0 and answers Result=success to
# everything. LoadState is the only question that tells the truth.
healthy
rm -f "$STATE/props/precompute.service"
OUT="$(run)"; RC=$?
check "the service systemd cannot load: exit 1" "$RC" 1
grep_ok "$OUT" 'LoadState=not-found' "not-found service: named by LoadState"
grep_none "$OUT" 'SKIPPED' "not-found service: not misreported as skipped"

healthy
props precompute.service loaded failed exit-code 1 yes "@$((NOW-600))" ""
OUT="$(run)"; RC=$?
check "last run failed: exit 1" "$RC" 1
grep_ok "$OUT" 'last run FAILED' "failed run: named"
grep_ok "$OUT" 'journalctl --user -u precompute.service' "failed run: gives the journal command"

healthy
props precompute.service loaded inactive success 1 yes "@$((NOW-600))" ""
OUT="$(run)"; RC=$?
check "Result=success but ExecMainStatus=1: exit 1" "$RC" 1

healthy
props precompute.service loaded failed success 0 yes "@$((NOW-600))" ""
OUT="$(run)"; RC=$?
check "ActiveState=failed alone: exit 1" "$RC" 1

# The silent one this whole file exists for.
healthy
props precompute.service loaded inactive success 0 no "@$((NOW-600))" ""
OUT="$(run)"; RC=$?
check "armed but SKIPPED by a condition: exit 1" "$RC" 1
grep_ok "$OUT" 'armed but SKIPPED' "skipped unit: named"
grep_ok "$OUT" 'ConditionPathExists=/nonexistent/wt-gc' "skipped unit: names the condition from the unit file"

# ... but the same value on a unit that has simply never started is not a fault.
healthy
props precompute.service loaded inactive success 0 no "" ""
OUT="$(run)"; RC=$?
check "ConditionResult=no with no ConditionTimestamp: exit 0" "$RC" 0
grep_none "$OUT" 'SKIPPED' "never-started service: not reported as skipped"

printf '\nstandalone (non-timer) managed services\n'

healthy
link_unit server.service
set_enabled server.service enabled
props server.service loaded active success 0 yes "@$((NOW-9000))" "@$((NOW-9000))"
OUT="$(run)"; RC=$?
check "a long-running managed service that is up: exit 0" "$RC" 0
grep_ok "$OUT" '✓ server.service: active' "standalone service: reported"

healthy
link_unit server.service
set_enabled server.service enabled
props server.service loaded inactive success 0 yes "@$((NOW-9000))" ""
OUT="$(run)"; RC=$?
check "an enabled long-running service that is down: exit 1" "$RC" 1

healthy
link_unit server.service
set_enabled server.service enabled
rm -f "$STATE/props/server.service"
OUT="$(run)"; RC=$?
check "a standalone service systemd cannot load: exit 1" "$RC" 1
grep_ok "$OUT" 'LoadState=not-found' "standalone not-found: named by LoadState"

# SKIPPED, not down. A standalone unit held back by an unmet Condition* is
# inactive with Result=success — which this function reported as a FAIL until
# DO-692, making any unit gated on hardware or a vendor client permanently red on
# every machine that lacks it. The needle is the word SKIPPED on the unit's own
# line; asserting exit 0 alone would also pass if the branch vanished and the
# unit happened to be up.
healthy
link_unit server.service 'ConditionPathExists=/nonexistent/vpn-client'
set_enabled server.service enabled
props server.service loaded inactive success 0 no "@$((NOW-9000))" ""
OUT="$(run)"; RC=$?
check "a standalone service skipped by a condition: exit 0" "$RC" 0
grep_ok "$OUT" '· server.service: SKIPPED by a condition' "standalone skipped: reported as a decision"
grep_ok "$OUT" 'ConditionPathExists=/nonexistent/vpn-client' "standalone skipped: names the condition holding it back"
grep_none "$OUT" '✗ server.service' "standalone skipped: NOT reported as a fault"

# The same ConditionResult=no on a unit that has never been reached is not a
# skip — it is the default systemd reports for a unit it has not looked at. The
# timestamp is what separates them, exactly as in check_service().
healthy
link_unit server.service 'ConditionPathExists=/nonexistent/vpn-client'
set_enabled server.service enabled
props server.service loaded inactive success 0 no "" ""
OUT="$(run)"; RC=$?
check "standalone, ConditionResult=no with no timestamp: exit 1" "$RC" 1
grep_none "$OUT" 'SKIPPED' "standalone never reached: not reported as skipped"

# ... and a unit that is UP is judged on that, whatever an earlier start attempt
# declined to do. Without the ActiveState gate this row reports a running daemon
# as skipped.
healthy
link_unit server.service 'ConditionPathExists=/nonexistent/vpn-client'
set_enabled server.service enabled
props server.service loaded active success 0 no "@$((NOW-9000))" "@$((NOW-9000))"
OUT="$(run)"; RC=$?
check "standalone up, stale ConditionResult=no: exit 0" "$RC" 0
grep_ok "$OUT" '✓ server.service: active' "standalone up: judged on ActiveState, not on a stale condition"
grep_none "$OUT" 'SKIPPED' "standalone up: not reported as skipped"

# CRASH-LOOPING. `activating` was accepted as a tick, so a daemon restarting
# forever read green — and because each run outlives StartLimitIntervalSec the
# rate limiter never trips, so nothing else reports it either.
healthy
link_unit server.service
set_enabled server.service enabled
props server.service loaded activating success 0 yes "@$((NOW-9000))" "@$((NOW-30))" 9
OUT="$(run)"; RC=$?
check "a standalone daemon in a restart loop: exit 1" "$RC" 1
grep_ok "$OUT" 'CRASH-LOOPING' "restart loop: named"
grep_ok "$OUT" 'NRestarts=9' "restart loop: reports the count it judged on"
grep_none "$OUT" '✓ server.service' "restart loop: no tick"

# Sampled in the UP half of the same cycle. This is the row that makes the guard
# worth having: ActiveState=active is what a healthy daemon reports too, so a
# check that only looked at `activating` would pass here every other poll.
healthy
link_unit server.service
set_enabled server.service enabled
props server.service loaded active success 0 yes "@$((NOW-9000))" "@$((NOW-30))" 9
OUT="$(run)"; RC=$?
check "a restart loop sampled while active: exit 1" "$RC" 1
grep_ok "$OUT" 'CRASH-LOOPING' "restart loop while active: still named"

# Below the limit is a blip, not a loop: a resume or a network hiccup restarts a
# daemon once or twice and it must not turn the checker red.
healthy
link_unit server.service
set_enabled server.service enabled
props server.service loaded active success 0 yes "@$((NOW-9000))" "@$((NOW-9000))" 3
OUT="$(run)"; RC=$?
check "restarts at the limit are not a loop: exit 0" "$RC" 0
grep_ok "$OUT" '✓ server.service: active' "at the limit: still a tick"

# The limit is a threshold, not a constant this suite happens to agree with.
healthy
link_unit server.service
set_enabled server.service enabled
props server.service loaded active success 0 yes "@$((NOW-9000))" "@$((NOW-9000))" 3
OUT="$(TIMER_HEALTH_RESTART_LIMIT=2 run)"; RC=$?
check "a lowered restart limit is honoured: exit 1" "$RC" 1
grep_ok "$OUT" '(limit 2)' "lowered limit: reported"

# A non-numeric limit must not silently become 0 inside (( )), which would fail
# every healthy daemon on the machine.
healthy
OUT="$(TIMER_HEALTH_RESTART_LIMIT=soon run)"; RC=$?
check "a non-numeric restart limit: exit 2, not a pass" "$RC" 2
grep_ok "$OUT" 'TIMER_HEALTH_RESTART_LIMIT' "bad restart limit: names the variable"

# NRestarts is read into an arithmetic context, and bash EXECUTES command
# substitution there: `(( r > 3 ))` with r='x[$(touch /tmp/f)]' creates the file
# and evaluates to false, silently. Measured, not recalled. systemctl is a
# trusted source, so this pins a property rather than a live attack path — the
# same defensive shape as epoch_of() and the HORIZON_DAYS validation in this
# file, both of which exist because a non-numeric value inside (( )) is a silent
# 0 rather than an error.
healthy
link_unit server.service
set_enabled server.service enabled
CANARY="$T/nrestarts-canary"
printf 'LoadState=loaded\nActiveState=active\nUnitFileState=enabled\nResult=success\nExecMainStatus=0\nConditionResult=yes\nConditionTimestamp=@%s\nActiveEnterTimestamp=@%s\nNRestarts=x[$(touch %s)]\n' \
    "$((NOW-9000))" "$((NOW-9000))" "$CANARY" > "$STATE/props/server.service"
OUT="$(run)"; RC=$?
check "a non-numeric NRestarts: exit 0, treated as no restarts" "$RC" 0
[[ -e "$CANARY" ]] && bad "NRestarts is evaluated as an arithmetic expression — command substitution RAN" \
                   || ok "NRestarts is never evaluated as an arithmetic expression"
grep_ok "$OUT" '✓ server.service: active' "non-numeric NRestarts: still a tick"

# A service a managed timer activates must not ALSO be judged as a standalone
# daemon — a oneshot is inactive between runs, which would read as "down".
healthy
set_enabled precompute.service linked
OUT="$(run)"; RC=$?
check "the activated oneshot is not judged as a daemon: exit 0" "$RC" 0
grep_none "$OUT" 'precompute.service: linked, not enabled' "activated service: not re-reported standalone"

printf '\nforeign units are not this repos business\n'

healthy
timers_json "[$(row precompute.timer precompute.service $((NOW+1200)) $((NOW-600))),$(row snap.firmware.timer snap.firmware.service $((NOW-99999)) $((NOW-99999)))]"
OUT="$(run)"; RC=$?
check "a failing foreign timer does not fail this check" "$RC" 0
grep_none "$OUT" 'snap.firmware' "foreign timer: not reported at all"

printf '\ninputs and CLI\n'

healthy
OUT="$(PATH="$STUBBIN:$PATH" SCTL_STATE="$STATE" SYSTEMD_USER_DIR="$SUDIR" \
        TIMER_HEALTH_NOW="$NOW" XDG_RUNTIME_DIR="$T/run" \
        TIMER_HEALTH_MAX_HORIZON_DAYS=abc "$SUT" 2>&1)"; RC=$?
check "a non-numeric horizon: exit 2, not a silent 0" "$RC" 2

healthy
OUT="$(PATH="$STUBBIN:$PATH" SCTL_STATE="$STATE" SYSTEMD_USER_DIR="$SUDIR" \
        XDG_RUNTIME_DIR="$T/run" TIMER_HEALTH_NOW=abc "$SUT" 2>&1)"; RC=$?
check "a non-numeric clock: exit 2" "$RC" 2

healthy
OUT="$(run --nope)"; RC=$?
check "an unknown flag: exit 2" "$RC" 2

healthy
OUT="$(run --help)"; RC=$?
check "--help: exit 0" "$RC" 0
grep_ok "$OUT" 'check-timer-health.sh' "--help prints the header"
grep_ok "$OUT" 'EXIT CODE' "--help reaches the exit-code paragraph"

healthy
OUT="$(run --check)"; RC=$?
check "--check is the same as no argument" "$RC" 0

printf '\n--write-state: the state file is the channel (DO-687)\n'

# A fixture XDG_STATE_HOME, so no row can touch the real one the prompt reads.
WS="$T/xdgstate"
ws() {   # ws -- run --write-state, echo its exit status
  rm -rf "$WS"; mkdir -p "$WS"
  PATH="$STUBBIN:$PATH" SCTL_STATE="$STATE" SYSTEMD_USER_DIR="$SUDIR" \
  TIMER_HEALTH_NOW="$NOW" XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$WS" \
    "$SUT" --write-state >"$T/wsout" 2>&1
  echo $?
}
wskey() { sed -n "s/^$1=//p" "$WS/timer-health/status"; }

healthy
check "healthy: exit 0"                "$(ws)"        0
check "healthy: rc recorded as 0"      "$(wskey rc)"  0
check "healthy: no faults"             "$(wskey faults)" 0
check "healthy: detail file written"   "$([[ -s "$WS/timer-health/detail" ]] && echo yes)" yes

# The exit code DIVERGES from --check here, deliberately: an unhealthy timer must
# not make the writer itself a failed unit, or the instrument pollutes the very
# --state=failed signal this feature is built on.
healthy
props precompute.service loaded failed exit-code 1 yes "@$((NOW-600))" ""
check "a failing timer still exits 0"  "$(ws)"           0
check "... but rc=1 is recorded"       "$(wskey rc)"     1
check "... and the fault is counted"   "$(wskey faults)" 1
check "... and summarised"             "$(wskey summary | grep -c 'precompute.service')" 1

# rc=2 ("could not run") must survive into the file, because the prompt
# deliberately stays silent for it while verify-tools.sh does not.
healthy
rm -f "$CHECKOUT/scripts/reconcile-systemd-units.sh"
check "could-not-run still exits 0"    "$(ws)"        0
check "... and records rc=2"           "$(wskey rc)"  2

# summary carries text grepped out of unit FILES, so it is whatever is in
# ~/.config/systemd/user/*. A newline would forge a later key; an ESC would let a
# unit file paint the reader's terminal. Sanitised at WRITE time -- atomicity
# does nothing about content.
# The producible vector is a UNIT FILENAME: anything in ~/.config/systemd/user is
# a name this script will print. An earlier version of this row put the escape in
# an `X-Evil=` line, which condition_lines() never greps -- a fixture describing a
# state the machine cannot produce, which is the DO-686 defect exactly, and it let
# the "drop the sanitiser" mutant survive.
healthy
EVIL="$(printf 'ev\033[31mil.timer')"
link_unit "$EVIL"
set_enabled "$EVIL" enabled
ws >/dev/null
check "summary is a single line"       "$(wskey summary | wc -l | tr -d ' ')" 1
check "an ESC in a unit NAME is stripped" "$(wskey summary | grep -c $'\033')" 0
check "status file has exactly 4 keys" "$(grep -c '^[a-z]*=' "$WS/timer-health/status")" 4

# A newline in the same place would forge a later key=value record and could set
# rc=0, silencing the prompt from inside a unit filename.
healthy
NL="$(printf 'nl\nrc=0\nx.timer')"
link_unit "$NL" 2>/dev/null || true
set_enabled "$NL" enabled 2>/dev/null || true
ws >/dev/null
check "rc is never forged by injected content" "$(grep -c '^rc=' "$WS/timer-health/status")" 1

# The temp file must be created INSIDE the target dir: this box sets TMPDIR via
# config/environment.d/tmpdir.conf, and a cross-filesystem mv is copy-then-rename,
# which a reader can catch half-written.
healthy
ws >/dev/null
check "no temp files left behind"      "$(find "$WS/timer-health" -name '.status.*' | wc -l | tr -d ' ')" 0

# ... and the temp file is created INSIDE the target dir. Asserted by making
# $TMPDIR unusable: a writer that reaches for $TMPDIR fails, one that uses
# `mktemp -p "$dir"` does not. The previous row passed for either implementation.
healthy
RO="$T/readonly-tmp"; rm -rf "$RO"; mkdir -p "$RO"; chmod 500 "$RO"
rm -rf "$WS"; mkdir -p "$WS"
rc="$(PATH="$STUBBIN:$PATH" SCTL_STATE="$STATE" SYSTEMD_USER_DIR="$SUDIR" \
      TIMER_HEALTH_NOW="$NOW" XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$WS" \
      TMPDIR="$RO" "$SUT" --write-state >/dev/null 2>&1; echo $?)"
chmod 700 "$RO"
check "an unusable TMPDIR does not stop the write" "$rc" 0
check "... and the state file is there anyway" "$([[ -s "$WS/timer-health/status" ]] && echo yes)" yes

# An unwritable state dir must be the ONE thing that makes this exit non-zero.
healthy
rm -rf "$WS"; mkdir -p "$WS"; chmod 500 "$WS"
rc="$(PATH="$STUBBIN:$PATH" SCTL_STATE="$STATE" SYSTEMD_USER_DIR="$SUDIR" \
      TIMER_HEALTH_NOW="$NOW" XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$WS" \
      "$SUT" --write-state >/dev/null 2>&1; echo $?)"
chmod 700 "$WS"
check "an unwritable state dir exits non-zero" "$rc" 1

# ... and the case where the DIRECTORY is fine but the WRITE is not, which is
# the only one that reaches write_state's own return value. The row above makes
# `mkdir -p` fail first, so a mutant that swallows write_state's status survived
# it: the two failures need separate rows to be told apart.
healthy
rm -rf "$WS"; mkdir -p "$WS/timer-health"; chmod 500 "$WS/timer-health"
rc="$(PATH="$STUBBIN:$PATH" SCTL_STATE="$STATE" SYSTEMD_USER_DIR="$SUDIR" \
      TIMER_HEALTH_NOW="$NOW" XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$WS" \
      "$SUT" --write-state >/dev/null 2>&1; echo $?)"
chmod 700 "$WS/timer-health"
check "an unwritable state dir (mktemp path) exits non-zero" "$rc" 1

# ... and the case that reaches write_state's OWN return value. Both rows above
# fail earlier -- at mkdir, then at the mktemp for the capture file -- so a
# mutant that swallowed write_state's status survived them BOTH. A non-empty
# directory where `status` should be makes the final `mv` fail with everything
# else working, which is the only way to exercise that return.
healthy
rm -rf "$WS"; mkdir -p "$WS/timer-health/status"
: > "$WS/timer-health/status/occupied"
rc="$(PATH="$STUBBIN:$PATH" SCTL_STATE="$STATE" SYSTEMD_USER_DIR="$SUDIR" \
      TIMER_HEALTH_NOW="$NOW" XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$WS" \
      "$SUT" --write-state >/dev/null 2>&1; echo $?)"
check "a failed state write is reported, not swallowed" "$rc" 1

healthy
OUT="$(run --write-state --extra 2>&1)"; RC=$?
check "--write-state takes no second argument" "$RC" 2

# ---------------------------------------------------------------------------
TOTAL=$(( PASS + FAIL ))
printf '\n'
# The suite asserts its own size: a row silently deleted (or a fixture helper
# that stopped emitting one) is otherwise indistinguishable from a clean run.
EXPECTED_ROWS=122
if (( TOTAL != EXPECTED_ROWS )); then
    printf '\033[1;31mFATAL\033[0m: ran %d checks, expected %d — a row was added or lost.\n' \
        "$TOTAL" "$EXPECTED_ROWS" >&2
    printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
    exit 2
fi
printf 'timer-health state table: %d/%d checks passed\n' "$PASS" "$TOTAL"
(( FAIL == 0 )) || exit 1
exit 0
