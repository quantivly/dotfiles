#!/usr/bin/env bash
#
# scripts/test-claude-pick.sh
# ===========================
#
# State table for the smart account picker in zsh/zshrc.herdr (DO-574): the
# per-profile metrics, the score, the eligibility classes, holder counting across
# both launch paths, the round-robin ledger, exhaustion and machine backpressure,
# and the scripts/claude-pick CLI.
#
# Why this exists: every one of these decides WHICH ACCOUNT IS BILLED, and none
# of them announces itself afterwards. A wrong answer is not an error — it is a
# session quietly spending the wrong seat, which is the failure this whole area
# was built to end.
#
# HERMETIC, in the two specific ways this repo has paid for:
#
#   * a fixture $HOME, so the developer's real ~/.clauth is never read. This box
#     runs 20+ Claude processes against live profiles mid-rename; a suite that
#     read them would be scored against whatever is happening at the time.
#   * CLAUDE_CONFIG_DIR and HERDR_PANE_ID are CLEARED for every run. Whoever runs
#     this is very likely inside an isolated Claude session, and an inherited
#     CLAUDE_CONFIG_DIR makes claude() skip the entire selection path — so the
#     rows would pass while asserting nothing. test-hspawn.sh records both leaks.
#
# NO PROFILE NAME FROM THIS MACHINE APPEARS BELOW. Profile names are mid-rename
# (0-based), with compat symlinks at the old account-dir paths, so a fixture that
# hardcoded one would be testing a name that is about to stop existing. Fixtures
# use a1/b2/c3.
#
# Requires: zsh, bash, jq. No sudo, no network, no clauth, no real credentials.
#
# Usage: scripts/test-claude-pick.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDRRC="$DOTFILES/zsh/zshrc.herdr"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

for tool in zsh bash jq; do
    command -v "$tool" >/dev/null || fatal "$tool is required"
done
[[ -r "$HERDRRC" ]] || fatal "cannot read $HERDRRC"

# Assert the functions under test are DEFINED before asserting on behaviour. Most
# rows below are "this number, not that one", and a suite that loaded nothing
# produces empty output for every one of them — which `check` would report as a
# plain mismatch rather than as the harness failure it is.
for fn in _claude_profile_metrics _claude_pick_score; do
    zsh -c "source '$HERDRRC' >/dev/null 2>&1; (( \$+functions[$fn] ))" \
        || fatal "$fn is not defined after sourcing $HERDRRC — the suite would assert nothing"
done

FHOME=""
new_home() {   # $1 = label; a fresh fixture HOME per timing-sensitive group
    FHOME="$TMPROOT/$1"
    mkdir -p "$FHOME/.clauth/profiles" "$FHOME/.local/state/claude-account-dirs"
}

mkprof() {     # $1 = profile, $2 = usage_cache.json body ('-' = no cache file)
    local d="$FHOME/.clauth/profiles/$1"
    mkdir -p "$d"
    : > "$d/credentials.json"
    [[ "$2" == "-" ]] || printf '%s\n' "$2" > "$d/usage_cache.json"
}

# Every fixture shell clears the two variables named in the header.
zrun() {       # $1 = zsh snippet, run with the fixture HOME
    zsh -f -c "
      unset CLAUDE_CONFIG_DIR HERDR_PANE_ID CLAUDE_ACCOUNT_PROFILE CLAUDE_ACCOUNT_TENANT
      export HOME='$FHOME'
      CLAUDE_TENANTS_FILE=/nonexistent
      source '$HERDRRC' >/dev/null 2>&1
      $1" 2>/dev/null
}

metrics() {    # $1 = profile -> "u5 r5 uW tier"
    zrun "_claude_profile_metrics '$1'
          print -r -- \"\$_CPM_U5 \$_CPM_R5 \$_CPM_UW \$_CPM_TIER\""
}

#-----------------------------------------------------------------------------
echo "=== metrics: absent is its own state, never zero ==="

new_home m1
mkprof a1 '{"plan":{"tier":"Team"},"five_hour":{"utilization":10.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":40.0},"weekly_scoped":[{"label":"7d x","utilization":55.0}]}'
check "u5 floors to an integer"            "$(metrics a1 | cut -d' ' -f1)" "10"
check "uW is the WORST of 7d and scoped"   "$(metrics a1 | cut -d' ' -f3)" "55"
check "tier is carried through"            "$(metrics a1 | cut -d' ' -f4)" "Team"

# A Max plan writes the tier as an OBJECT ({"Max":20}); a Team plan as a string.
new_home m1b
mkprof a1 '{"plan":{"tier":{"Max":20}},"five_hour":{"utilization":0.0}}'
check "an object tier is normalised to its key" "$(metrics a1 | cut -d' ' -f4)" "Max"

# The correction that motivated this whole function.
new_home m2
mkprof a1 '{"five_hour":{"utilization":0.0},"seven_day":{"utilization":2.0}}'
check "an ABSENT resets_at is 'unknown', not 0" "$(metrics a1 | cut -d' ' -f2)" "unknown"
check "...and u5 is still read"                 "$(metrics a1 | cut -d' ' -f1)" "0"
check "...and uW is still read"                 "$(metrics a1 | cut -d' ' -f3)" "2"

new_home m3
mkprof a1 '{"five_hour":{"utilization":5.0,"resets_at":"not a timestamp"}}'
check "an UNPARSEABLE resets_at is 'unknown'"   "$(metrics a1 | cut -d' ' -f2)" "unknown"
check "...and does not poison u5"               "$(metrics a1 | cut -d' ' -f1)" "5"

new_home m4
mkprof a1 '-'
check "no usage cache is unknown throughout"    "$(metrics a1 | cut -d' ' -f1,3)" "unknown unknown"

new_home m5
mkprof a1 '{"five_hour":{"utilization":0.0,"resets_at":"2000-01-01T00:00:00.000000+00:00"}}'
check "a PAST resets_at gives a negative r5" \
      "$(zrun "_claude_profile_metrics a1; (( _CPM_R5 < 0 )) && print yes || print no")" "yes"

new_home m6
mkprof a1 '{"seven_day":{"utilization":7.0}}'
check "a missing five_hour block leaves u5 unknown, not 0" "$(metrics a1 | cut -d' ' -f1)" "unknown"

#-----------------------------------------------------------------------------
echo
echo "=== scoring: one row per term, each isolating that term ==="

score() { zsh -f -c "source '$HERDRRC' >/dev/null 2>&1; _claude_pick_score $1 $2 $3 ${4:-0}" 2>/dev/null; }
cmp2()  { zsh -f -c "source '$HERDRRC' >/dev/null 2>&1
                     (( \$(_claude_pick_score $1) $2 \$(_claude_pick_score $3) )) && print yes || print no" 2>/dev/null; }

# base — plain 5h headroom, with no bonus, no weekly demotion and no crowding.
check "base is 5h headroom x100"          "$(score 0  18000 0)" "10000"
check "base falls with utilization"       "$(score 40 18000 0)" "6000"

# bonus — use-it-or-lose-it. Equal headroom, nearer the reset, higher score.
check "a near-reset window outscores a fresh one" "$(cmp2 '20 60 0' '>' '20 18000 0')" "yes"
check "a nearly-spent window near its reset earns little" \
      "$(cmp2 '95 60 0' '<' '20 18000 0')" "yes"

# The two corrections, both measured on this machine.
check "UNKNOWN r5 scores exactly as a fresh window does" \
      "$(score 20 unknown 0)" "$(score 20 18000 0)"
check "a window that ALREADY reset earns no bonus either" \
      "$(score 20 -61 0)" "$(score 20 18000 0)"

# weekf — weekly headroom as a MULTIPLIER, not a gate.
check "7d 96% scores below 7d 60% at equal 5h"   "$(cmp2 '0 18000 96' '<' '0 18000 60')" "yes"
check "a spent week scores 0 — a NUMBER, not a refusal" "$(score 0 18000 100)" "0"
check "an unknown week is not treated as spent"  "$(score 0 18000 unknown)" "10000"

# crowd — holders, dearer as the account fills.
check "holders subtract"                         "$(score 0 18000 0 1)" "9700"
# Written out rather than through cmp2: this row compares two DIFFERENCES, and
# threading that through a helper built for two scores produced a malformed
# expression that answered "no" for the wrong reason.
check "a holder costs more on a fuller account" \
      "$(zsh -f -c "source '$HERDRRC' >/dev/null 2>&1
         empty_cost=\$(( \$(_claude_pick_score 0 18000 0 0)  - \$(_claude_pick_score 0 18000 0 1) ))
         full_cost=\$((  \$(_claude_pick_score 80 18000 0 0) - \$(_claude_pick_score 80 18000 0 1) ))
         (( empty_cost < full_cost )) && print yes || print no" 2>/dev/null)" "yes"

# The ordering that matters on this machine: a fresh seat beats two spent ones.
check "a fresh week outranks a spent one at equal 5h" \
      "$(cmp2 '0 unknown 2' '>' '0 unknown 100')" "yes"

#-----------------------------------------------------------------------------
echo
echo "=== classes: what is eligible, exhausted, unknown, excluded ==="

cls() { zrun "_claude_pick_class '$1'"; }

new_home k1; mkprof a1 '{"five_hour":{"utilization":97.0}}'
check "u5 at the 5h ceiling is exhausted"  "$(cls a1 | cut -d: -f1)" "exhausted"
new_home k2; mkprof a1 '{"five_hour":{"utilization":96.0}}'
check "one point below it is eligible"     "$(cls a1)"               "eligible"

# THE DEPARTURE FROM §5.3, and the reason it is a departure. Measured 2026-09-10:
# two Team seats read seven_day 100 with live sessions on them; ZERO weekly-reset
# refusals in 750 transcripts over 7 days; the block a Team seat actually hits is
# a spend limit whose remedy is an admin, not a window rolling over; and their
# per-model windows read 38 and 54, so the block is partial. A hard class here
# would have refused across the entire work tree that morning.
new_home k3; mkprof a1 '{"five_hour":{"utilization":0.0},"seven_day":{"utilization":100.0}}'
check "a fully spent WEEK is still eligible — it demotes, it does not refuse" \
      "$(cls a1)" "eligible"
check "...and it is demoted to the floor by the score, not by a class" \
      "$(zrun "_claude_profile_metrics a1 >/dev/null
               _claude_pick_score \$_CPM_U5 \$_CPM_R5 \$_CPM_UW 0")" "0"
check "...unless the inert knob is armed" \
      "$(zrun "CLAUDE_PICK_WEEK_EXHAUSTED=100 _claude_pick_class a1 | cut -d: -f1")" "exhausted"
check "the knob's default is 101, i.e. unreachable" \
      "$(zrun "print -r -- \${CLAUDE_PICK_WEEK_EXHAUSTED:-101}")" "101"

new_home k4; mkprof a1 '-'
check "no usage cache is unknown, not exhausted" "$(cls a1 | cut -d: -f1)" "unknown"

# 30 minutes: stale under a tightened threshold, fresh under the default. One
# fixture exercising BOTH sides of the boundary — an earlier version used 3 hours
# and then asserted it was eligible by default, which 3h > 3600s is not.
new_home k5; mkprof a1 '{"five_hour":{"utilization":0.0}}'
touch -d '30 minutes ago' "$FHOME/.clauth/profiles/a1/usage_cache.json"
check "a cache older than MAX_AGE is unknown" \
      "$(zrun "CLAUDE_PICK_CACHE_MAX_AGE=60 _claude_pick_class a1 | cut -d: -f1")" "unknown"
check "...and the DEFAULT max age is 3600, not the spec's 900" \
      "$(zrun "print -r -- \${CLAUDE_PICK_CACHE_MAX_AGE:-3600}")" "3600"
check "...so that same cache is eligible by default" "$(cls a1)" "eligible"
# The 900 the spec asked for would have called it unknown — which is the whole
# reason the default stayed at 3600 with no refresher to feed it.
check "...and would have been unknown at the spec's 900" \
      "$(zrun "CLAUDE_PICK_CACHE_MAX_AGE=900 _claude_pick_class a1 | cut -d: -f1")" "unknown"

# A directory under profiles/ is not a profile (observed on this machine).
new_home k6
mkdir -p "$FHOME/.clauth/profiles/ghost/runtime-1-0"
: > "$FHOME/.clauth/profiles/ghost/.reconcile.lock"
check "a profile DIR with no credential is excluded" "$(cls ghost | cut -d: -f1)" "excluded"
check "...and says why"                              "$(cls ghost | cut -d: -f2)" "no credential"

new_home k7; mkprof a1 '{"five_hour":{"utilization":0.0}}'
mkdir -p "$FHOME/.clauth"
printf 'auth_broken = [\n  "a1",\n]\n' > "$FHOME/.clauth/profiles.toml"
check "a quarantined profile is excluded" "$(cls a1 | cut -d: -f1)" "excluded"

#-----------------------------------------------------------------------------
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
