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
for fn in _claude_profile_metrics _claude_pick_score \
          _claude_profile_excluded _claude_quarantine_scan; do
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

# THE FIXTURE TIMEZONE IS DELIBERATELY NOT UTC, and this is what makes the RFC
# 3339 rows mean anything. Every instant clauth writes is UTC, and the defect
# those rows pin is that `strftime -r` parses through mktime, which reads a
# broken-down time as LOCAL — so on a UTC machine a parser that ignores the zone
# is indistinguishable from one that honours it, and the mutant survives. CI
# runners are UTC. `XXX-3` is the POSIX form (the offset is what to ADD to local
# to reach UTC, so this is UTC+3) and needs no tzdata, which a minimal container
# may not have.
FIXTZ='XXX-3'

# Every fixture shell clears the two variables named in the header.
zrun() {       # $1 = zsh snippet, run with the fixture HOME
    zsh -f -c "
      unset CLAUDE_CONFIG_DIR HERDR_PANE_ID CLAUDE_ACCOUNT_PROFILE CLAUDE_ACCOUNT_TENANT
      export HOME='$FHOME'
      export TZ='$FIXTZ'
      CLAUDE_TENANTS_FILE=/nonexistent
      source '$HERDRRC' >/dev/null 2>&1
      $1" 2>/dev/null
}

metrics() {    # $1 = profile -> "u5 r5 uW tier"
    zrun "_claude_profile_metrics '$1'
          print -r -- \"\$_CPM_U5 \$_CPM_R5 \$_CPM_UW \$_CPM_TIER\""
}

# An RFC 3339 instant N seconds from now (negative = past), in clauth's own shape.
# GNU date, as the suite's `touch -d` already requires.
iso_in() { date -u -d "@$(( $(date +%s) + $1 ))" '+%Y-%m-%dT%H:%M:%S.000000+00:00'; }
# A 5h window that is fresh and whose reset is far away, so its bonus is 0 and it
# never decides a row that is about the WEEK.
FIVE='"five_hour":{"utilization":0.0,"resets_at":"2099-01-01T00:00:00Z"}'
spend_of() { zrun "_claude_profile_metrics '$1' >/dev/null; print -r -- \"\$_CPM_SPEND|\$_CPM_SPEND_TXT\""; }

#-----------------------------------------------------------------------------
echo "=== metrics: absent is its own state, never zero ==="

new_home m1
mkprof a1 '{"plan":{"tier":"Team"},"five_hour":{"utilization":10.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":40.0},"weekly_scoped":[{"label":"7d x","utilization":55.0}]}'
check "u5 floors to an integer"            "$(metrics a1 | cut -d' ' -f1)" "10"
# DO-621: uW is the AGGREGATE week alone. A per-model window (here 55) is the
# gate's business; folding it in with max() is what made two seats spent on
# OPPOSITE axes (2026-09-18: 83%/fable 100 vs 100%/fable 63) read identically.
check "uW is seven_day alone — a per-model window does not raise it" "$(metrics a1 | cut -d' ' -f3)" "40"
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

# uW and rW must describe ONE window. The live instants coincide to the second,
# so without a fixture whose per-model reset DIFFERS this split is unfalsifiable.
# (Fixture group renamed dw1 — the brief's own "m4" collides with the
# pre-existing "no usage cache" group of that name a few lines below, and
# new_home never clears a reused directory, so reusing it would leave this
# group's usage_cache.json behind for that unrelated row to read.)
new_home dw1
mkprof a1 "{\"five_hour\":{\"utilization\":5.0},\"seven_day\":{\"utilization\":40.0,\"resets_at\":\"$(iso_in 518400)\"},\"weekly_scoped\":[{\"label\":\"7d fable\",\"utilization\":100.0,\"resets_at\":\"$(iso_in 3600)\"}]}"
check "a spent per-model window does not reach uW"               "$(metrics a1 | cut -d' ' -f3)" "40"
check "...and rW is seven_day's reset, not the per-model one" \
      "$(zrun "_claude_profile_metrics a1 >/dev/null; (( _CPM_RW > 500000 )) && print yes || print no")" "yes"

# A LAPSED week is unmeasured: the figure describes a window that has ended.
new_home dw2
mkprof a1 '{"five_hour":{"utilization":5.0},"seven_day":{"utilization":100.0,"resets_at":"2000-01-01T00:00:00Z"}}'
check "a LAPSED week is unmeasured: uW is unknown"                "$(metrics a1 | cut -d' ' -f3)" "unknown"
# ...but ABSENT is not lapsed: clauth omits resets_at on an unstarted window, and
# un-demoting on missing data is optimism.
new_home dw3
mkprof a1 '{"five_hour":{"utilization":5.0},"seven_day":{"utilization":100.0}}'
check "an ABSENT weekly reset is not a lapse: uW still counts"    "$(metrics a1 | cut -d' ' -f3)" "100"

# Spend headroom: the signal that separates free, billed and blocked usage.
new_home dw4
mkprof a1 '{"five_hour":{"utilization":5.0},"spend":{"enabled":true,"used":190.77,"limit":250.0}}'
mkprof b2 '{"five_hour":{"utilization":5.0},"spend":{"enabled":true,"used":275.23,"limit":275.0}}'
mkprof c3 '{"five_hour":{"utilization":5.0},"spend":{"enabled":false,"used":0.0}}'
mkprof d4 '{"five_hour":{"utilization":5.0}}'
mkprof e5 '{"five_hour":{"utilization":5.0},"spend":{"enabled":true,"used":10.0}}'
# shellcheck disable=SC2016  # the literal $ amounts are the expected value, not an expansion
check "spend under its limit is headroom, with the amounts"       "$(spend_of a1)" 'headroom|$190.77 of $250'
check "spend at its limit is none"                                "$(spend_of b2 | cut -d'|' -f1)" "none"
check "spend disabled (a Max seat) is none"                       "$(spend_of c3 | cut -d'|' -f1)" "none"
check "no spend block is unknown, never none"                     "$(spend_of d4)" "unknown|"
check "a spend block with no limit is unknown"                    "$(spend_of e5 | cut -d'|' -f1)" "unknown"
# The reset at the top of the function is load-bearing: a profile with no spend
# block must not inherit the previous profile's value.
check "one profile's spend never leaks into the next one measured" \
      "$(zrun "_claude_profile_metrics b2 >/dev/null; _claude_profile_metrics d4 >/dev/null; print -r -- \$_CPM_SPEND")" "unknown"

# fetched_at and the per-model windows ride along for Task 2 and Part B.
new_home dw5
mkprof a1 '{"five_hour":{"utilization":5.0},"fetched_at":1789759993962,"weekly_scoped":[{"label":"7d sonnet 5","utilization":38.0,"resets_at":"2026-09-21T08:59:59.512214+00:00"}]}'
check "fetched_at is carried as an integer" \
      "$(zrun "_claude_profile_metrics a1 >/dev/null; print -r -- \$_CPM_FETCHED")" "1789759993962"
# Compared field by field, NOT as a JSON string: jq 1.7+ preserves the literal
# `38.0` and 1.6 prints `38`, and CI runs both (Ubuntu 22.04 and 24.04). A row
# that hardcodes either form is red on the other runner.
check "per-model windows round-trip: a spaced label and a colon-bearing reset survive" \
      "$(zrun "_claude_profile_metrics a1 >/dev/null; print -r -- \$_CPM_WINDOWS" \
         | jq -Rc '@base64d | fromjson | .[0] | [.label, .resets_at, (.utilization == 38)]')" \
      '["7d sonnet 5","2026-09-21T08:59:59.512214+00:00",true]'
new_home dw6
mkprof a1 '{"five_hour":{"utilization":5.0}}'
check "no per-model windows is the empty string, not base64 of []" \
      "$(zrun "_claude_profile_metrics a1 >/dev/null; print -r -- \"[\$_CPM_WINDOWS]\"")" "[]"

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

score() { zsh -f -c "source '$HERDRRC' >/dev/null 2>&1; _claude_pick_score $1 $2 $3 ${4:-0} ${5:-unknown}" 2>/dev/null; }
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

# DO-621 — the weekly axis. weekf STAYS (removing it switched weekly headroom
# off below 100%: an idle 99% seat tied an idle 20% one), but its penalty fades as
# the week's reset nears, and a consume-first bonus scaled by what is LEFT is
# added. W_WEEK_EXPIRE = 200 so a real preference clears the 800-point RR band.
check "no weekly reset known: exactly the old arithmetic"      "$(score 0 18000 95 0 unknown)" "3300"
check "a reset 1 h out lifts the near-spent penalty"           "$(score 0 18000 95 0 3600)"    "11000"
check "an empty week earns no consume-first bonus"             "$(score 0 18000 100 0 3600)"   "10000"
check "A: 40% of the week left, resetting in 6 d"              "$(score 0 18000 60 0 518400)"  "11200"
check "B: 20% of the week left, resetting in 12 h"             "$(score 0 18000 80 0 43200)"   "13720"

# THE CROSS-AXIS ORDERING — RECORDED, NOT ENDORSED. bonus_w tops out at 20000
# against base's maximum of 10000, so since DO-621 the weekly axis can outweigh
# the 5h axis outright. Both seats below have a week resetting in 3.5 d:
#
#   P  5h 0% used, week 90% used    6600 before DO-621, 9130 now
#   Q  5h 85% used, week 10% used   1500 before DO-621, 10500 now
#
# The ordering FLIPS, and by 1370 — outside CLAUDE_PICK_RR_BAND (800), so it is a
# preference the ledger cannot break rather than a coin flip: an interactive
# `claude` now prefers a seat with 15% of its 5h window left over one with all of
# it, because the loser's WEEK is nearly spent. This may well be the right
# long-horizon call and nothing here says it is wrong — the spec never compares
# the two axes against each other at all. What this row does is make the choice
# EXAMINED: every other score row passes u5 = 0 (FIVE is `utilization 0.0`), so
# without it there is no row anywhere in this suite where 5h headroom and weekly
# headroom point in opposite directions, and a future change to either weight
# would move the ordering in silence. The two scores are asserted as well as
# narrated, so the numbers in this comment cannot rot away from the code.
check "cross-axis: weekly headroom now outranks 5h headroom (recorded, not endorsed)" \
      "$(cmp2 '85 18000 10 0 302400' '>' '0 18000 90 0 302400')" "yes"
check "...P: 5h fresh, week 90% used, resetting in 3.5 d"  "$(score 0 18000 90 0 302400)"  "9130"
check "...Q: 5h 85% used, week 10% used, the same reset"   "$(score 85 18000 10 0 302400)" "10500"

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

# DO-621 — THE SPEND WALL, measured 2026-09-18: a spent window with spend
# headroom BILLS usage credits; with none it BLOCKS ("You've hit your individual
# spend limit"). Only the second is a wall, and missing data is never one.
new_home sw1
WEEK_SPENT_LIVE="\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 86400)\"}"
mkprof a1 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":true,\"used\":10.0,\"limit\":250.0}}"
mkprof b2 "{$FIVE,$WEEK_SPENT_LIVE}"
mkprof c3 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":true,\"used\":275.23,\"limit\":275.0}}"
mkprof d4 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":false,\"used\":0.0}}"
check "spent week + spend headroom: eligible (it bills; the tier demotes)" "$(cls a1)" "eligible"
check "spent week + spend unknown: eligible — missing data never refuses"   "$(cls b2)" "eligible"
check "spent week + spend at its limit: exhausted"                          "$(cls c3 | cut -d: -f1)" "exhausted"
check "spent week + spend disabled (a Max seat): exhausted"                 "$(cls d4 | cut -d: -f1)" "exhausted"
check "...and the reason names the spend wall"                              "$(cls c3 | grep -c 'no spend headroom')" "1"

# CLAUDE_PICK_WEEK_SPENT IS VALIDATED BEFORE ANY ARITHMETIC. zsh reads a
# non-numeric word in `(( ))` as 0, so an unusable value makes every measured
# week `>= 0` — and since DO-621 that is the spend wall, i.e. a HEADLESS
# REFUSAL, not only the demotion tier it used to be. Measured without the guard:
# a seat at 17% of its week came back `exhausted:weekly window 17% used and no
# spend headroom`, so one typo in ~/.zshrc.local refused every headless launch on
# the machine. THE BRANCH ESCALATED THE CONSEQUENCE, which is why the guard ships
# with it. The fallback is the default, never a refusal — the ranker's own rule
# is that broken data must not escalate.
new_home k8
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":17.0,\"resets_at\":\"$(iso_in 86400)\"},\"spend\":{\"enabled\":false}}"
check "an unusable CLAUDE_PICK_WEEK_SPENT falls back to 100, not to 0" \
      "$(zrun "CLAUDE_PICK_WEEK_SPENT=oops _claude_pick_class a1")" "eligible"
check "...and a negative one, which would wall every measured week as well" \
      "$(zrun "CLAUDE_PICK_WEEK_SPENT=-1 _claude_pick_class a1")" "eligible"
# An EMPTY value deliberately has no row of its own: `${VAR:-100}` substitutes for
# empty as well as unset, so the validator never sees one — and if that `:-` were
# ever weakened to `-`, the validator would catch the empty string instead. The
# two guards shadow each other, so no single deletion reaches a wrong answer and
# a row over it would pass either way. Written down rather than left out, because
# a missing row and an unfailable one look identical from the summary line.
#
# The block reset is the knob's second reader and runs the same arithmetic, so an
# unvalidated value there would wall a seat's reported WAIT independently of its
# class. A PLAIN assignment, not a `VAR=x cmd` prefix: a prefix lasts for that one
# command, so the first draft set the knob for _claude_profile_metrics — which
# never reads it — and left _claude_pick_block_reset on the default. The row
# passed under the mutant that deletes the guard, i.e. it asserted nothing.
# And an `if`, not `cond && print || print`: the bare form prints both when the
# first `print` fails, which is the SC2015 class this file exists to catch.
check "...and the block reset reads the same validated value" \
      "$(zrun "CLAUDE_PICK_WEEK_SPENT=oops
               _claude_profile_metrics a1 >/dev/null
               r=\$(_claude_pick_block_reset)
               if [[ \$r == \$_CPM_R5 ]]; then print same5h; else print -r -- \$r; fi")" "same5h"
# A USABLE value must still be honoured, or the guard is just a deletion.
check "a usable CLAUDE_PICK_WEEK_SPENT still arms the tier where it says" \
      "$(zrun "CLAUDE_PICK_WEEK_SPENT=10 _claude_pick_class a1 | cut -d: -f1")" "exhausted"
# ...and it is NOT SILENT. Only _claude_pick_for_dir can say so: the other two
# readers run inside `$(...)`, where anything they learn dies with the subshell.
# shellcheck disable=SC2016
check "...and an unusable value is warned about, once, by the one reader that can" \
      "$(zrun 'CLAUDE_PICK_WEEK_SPENT=oops _claude_pick_for_dir "$HOME" >/dev/null 2>&1
               print -rl -- "${_claude_pick_warnings[@]}"' | grep -c 'CLAUDE_PICK_WEEK_SPENT must be')" "1"
# shellcheck disable=SC2016
check "...and a usable one raises nothing" \
      "$(zrun 'CLAUDE_PICK_WEEK_SPENT=100 _claude_pick_for_dir "$HOME" >/dev/null 2>&1
               print -rl -- "${_claude_pick_warnings[@]}"' | grep -c 'CLAUDE_PICK_WEEK_SPENT must be')" "0"

# pfd() is documented in full at its house-convention spot below (the
# `_claude_pick_for_dir` section, next to `hold`/`unhold`) — defined here first
# because these DO-621 rows need a PICK, not just a class, and bash functions
# are not hoisted: calling it before this point is "command not found". Defined
# once; the later spot is unchanged and simply stops re-defining it.
pfd() {   # $1 = prelude, $2 = dir, $3 = tenant, $4 = strict
          #   -> "<rc>:<profile>:<state>:<class>"
    zsh -f -c "
      unset CLAUDE_CONFIG_DIR HERDR_PANE_ID CLAUDE_ACCOUNT_PROFILE CLAUDE_ACCOUNT_TENANT
      export HOME='$FHOME'
      export TZ='$FIXTZ'
      CLAUDE_ACCOUNT_DIRS_ROOT='$FHOME/.local/state/claude-account-dirs'
      CLAUDE_TENANTS_FILE=/nonexistent
      source '$HERDRRC' >/dev/null 2>&1
      ${1:-}
      _claude_pick_for_dir '${2:-}' '${3:-}' '${4:-0}' 0
      print -r -- \"\$?:\$REPLY:\$_claude_pick_state:\$_claude_pick_class\"" 2>/dev/null
}

new_home sw2
mkprof a1 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":true,\"used\":10.0,\"limit\":250.0}}"
check "a billing seat is picked in the weekly-spent tier"   "$(pfd '' '' '' 0 | cut -d: -f1,4)" "0:weekly-spent"

new_home sw3
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"2000-01-01T00:00:00Z\"},\"spend\":{\"enabled\":true,\"used\":275.23,\"limit\":275.0}}"
check "a LAPSED spent week behind a spend wall is not exhausted" "$(cls a1)" "eligible"
check "...and is picked as eligible, not weekly-spent"            "$(pfd '' '' '' 0 | cut -d: -f4)" "eligible"

# The pair that motivated DO-621, as measured on 2026-09-18.
new_home sw4
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":86.0,\"resets_at\":\"$(iso_in 216000)\"},\"weekly_scoped\":[{\"label\":\"7d fable\",\"utilization\":100.0,\"resets_at\":\"$(iso_in 216000)\"}],\"spend\":{\"enabled\":true,\"used\":190.77,\"limit\":250.0}}"
mkprof b2 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 194400)\"},\"weekly_scoped\":[{\"label\":\"7d fable\",\"utilization\":63.0,\"resets_at\":\"$(iso_in 194400)\"}],\"spend\":{\"enabled\":true,\"used\":275.23,\"limit\":275.0}}"
check "the 2026-09-18 pair: the Fable-spent seat is eligible"        "$(cls a1)" "eligible"
check "...the aggregate-spent seat at its spend limit is exhausted"   "$(cls b2 | cut -d: -f1)" "exhausted"
check "...and the pick is the eligible one"                          "$(pfd '' '' '' 0 | cut -d: -f2,4)" "a1:eligible"

new_home sw5
mkprof a1 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":true,\"used\":275.23,\"limit\":275.0}}"
check "a headless caller refuses a pool behind the spend wall"       "$(pfd '' '' '' 1 | cut -d: -f1,3)" "2:exhausted"

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

# THE RUNAWAY SPAN, AND THE POOL IT USED TO COLLAPSE. `auth_broken = [` with no
# members followed by `profiles = [...]` closes on the OTHER array's bracket, so
# the unvalidated span held every registered name and EVERY profile came back
# `excluded: auth broken`. Measured 2026-09-17 before the fix: claude-pick
# refused with "no usable account", exit 2, in plain and --strict form, naming
# two healthy accounts — so every headless caller started nothing at all. The
# two error directions are not symmetric, which is why an unreadable list now
# excludes nobody: missing a quarantine costs one session that says why, while
# excluding everybody costs all work on the machine.
new_home k7b; mkprof a1 '{"five_hour":{"utilization":0.0}}'
mkprof a2 '{"five_hour":{"utilization":0.0}}'
printf 'auth_broken = [\nprofiles = [\n  "a1",\n  "a2",\n]\n' > "$FHOME/.clauth/profiles.toml"
check "a runaway span excludes NOBODY (1/2)" "$(cls a1 | cut -d: -f1)" "eligible"
check "a runaway span excludes NOBODY (2/2)" "$(cls a2 | cut -d: -f1)" "eligible"

# ...and it is not silent. The classifier runs inside $(...), so the scan that
# can see the failure has to happen in _claude_pick_for_dir itself.
new_home k7c; mkprof a1 '{"five_hour":{"utilization":0.0}}'
printf 'auth_broken = [\nprofiles = [\n  "a1",\n]\n' > "$FHOME/.clauth/profiles.toml"
# SC2016 is the point, not an oversight: the snippet is evaluated by the inner
# zsh with the fixture HOME, so $HOME and the array must NOT expand in bash here.
# shellcheck disable=SC2016
check "...and an unreadable quarantine list is warned about" \
      "$(zrun '_claude_pick_for_dir "$HOME" >/dev/null 2>&1; print -rl -- "${_claude_pick_warnings[@]}"' | grep -c 'auth_broken list')" "1"

# A well-formed list must still exclude, or the fix above is just a deletion.
new_home k7d; mkprof a1 '{"five_hour":{"utilization":0.0}}'
mkprof a2 '{"five_hour":{"utilization":0.0}}'
printf 'profiles = [\n  "a1",\n  "a2",\n]\nauth_broken = [\n  "a1",\n]\n' \
    > "$FHOME/.clauth/profiles.toml"
check "a well-formed list still excludes its member"  "$(cls a1 | cut -d: -f1)" "excluded"
check "...and leaves the others alone"                "$(cls a2 | cut -d: -f1)" "eligible"

# The scan's own contract: rc=1 means the question could not be ASKED. Without
# testing sed's status an absent sed yields an empty span, which reads as
# "nothing is quarantined" — and a quarantined account then reads as maximum
# headroom, the bug this exclusion exists to prevent, arriving through the tool
# meant to detect it.
new_home k7e; mkprof a1 '{"five_hour":{"utilization":0.0}}'
printf 'auth_broken = [\n  "a1",\n]\n' > "$FHOME/.clauth/profiles.toml"
check "the scan reports a readable list"  "$(zrun '_claude_quarantine_scan; echo $?')" "0"
# shellcheck disable=SC2016  # expanded by the inner zsh, not by bash
check "...and finds its member"           "$(zrun '_claude_quarantine_scan && print -r -- "${_CQ_NAMES[*]}"')" "a1"
printf 'auth_broken = [\nprofiles = [\n  "a1",\n]\n' > "$FHOME/.clauth/profiles.toml"
check "a runaway span is rc=1, not an empty answer" "$(zrun '_claude_quarantine_scan; echo $?')" "1"
# CRLF. This reader was copied from the doctor's BEFORE the carriage return was
# added to that character class, so it inherited the divergence — two of the
# three readers accepted CRLF and this one did not.
new_home k7f; mkprof a1 '{"five_hour":{"utilization":0.0}}'
printf 'profiles = [\r\n  "a1",\r\n]\r\nauth_broken = [\r\n  "a1",\r\n]\r\n' \
    > "$FHOME/.clauth/profiles.toml"
check "a CRLF list still excludes its member" "$(cls a1 | cut -d: -f1)" "excluded"

# THE SCAN'S ONE EXTERNAL TOOL, REMOVED. Without this row the `|| return 1` on
# the sed call is unpinned — mutation proved it: deleting that test passed the
# whole suite, because every other fixture has a working sed. `echo` and `[[`
# are builtins, so an empty PATH reaches the scan and nothing else.
printf 'auth_broken = [\n  "a1",\n]\n' > "$FHOME/.clauth/profiles.toml"
check "sed missing is rc=1, never an empty all-clear" \
      "$(zrun 'PATH=/nonexistent; _claude_quarantine_scan; echo $?')" "1"
rm -f "$FHOME/.clauth/profiles.toml"
check "an absent profiles.toml is rc=1 too"         "$(zrun '_claude_quarantine_scan; echo $?')" "1"

#-----------------------------------------------------------------------------
echo
echo "=== cache age: fetched_at first, mtime as the fallback (DO-621) ==="

age_of()  { zrun "_claude_profile_metrics '$1' >/dev/null; print -r -- \$_CPM_AGE"; }
# An `if`, not `cond && echo yes || echo no`: that shape prints BOTH when the
# `echo yes` itself fails (SC2015), which in this file would report a failure for
# a row that passed — the exact class this suite exists to catch.
between() {
  if [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= $2 && $1 <= $3 )); then
    echo yes
  else
    echo "no ($1)"
  fi
}

# clauth 0.15.2 stamps fetched_at only on a LIVE fetch, so a plan-only rewrite
# advances the mtime while the reading stays old — the case upstream fixed
# alongside #74, and the one an mtime clock reads as fresh.
new_home ag1
mkprof a1 "{\"five_hour\":{\"utilization\":5.0},\"fetched_at\":$(( ($(date +%s) - 7200) * 1000 ))}"
check "age comes from fetched_at, not the fresh mtime"       "$(between "$(age_of a1)" 7190 7400)" "yes"
check "...so a plan-only rewrite is stale to the picker"      "$(cls a1 | cut -d: -f1)" "unknown"

new_home ag2
mkprof a1 '{"five_hour":{"utilization":5.0}}'
touch -d "@$(( $(date +%s) - 100 ))" "$FHOME/.clauth/profiles/a1/usage_cache.json"
check "with no fetched_at the mtime still decides (0.15.1)"   "$(between "$(age_of a1)" 95 200)" "yes"

new_home ag3
mkprof a1 "{\"five_hour\":{\"utilization\":5.0},\"fetched_at\":$(( ($(date +%s) + 30) * 1000 ))}"
check "a stamp up to 60 s ahead clamps to 0"                  "$(age_of a1)" "0"

# Far ahead is corruption. clauth's own scheduler (oauth_seed_clock) filters
# `at <= now` and falls back to the mtime; mapping it to `unknown` instead would
# read as FRESH, because the ranker never calls an unknown age stale.
new_home ag4
mkprof a1 "{\"five_hour\":{\"utilization\":5.0},\"fetched_at\":$(( ($(date +%s) + 3600) * 1000 ))}"
touch -d "@$(( $(date +%s) - 2000 ))" "$FHOME/.clauth/profiles/a1/usage_cache.json"
check "a stamp far in the future falls back to the mtime"     "$(between "$(age_of a1)" 1995 2100)" "yes"

#-----------------------------------------------------------------------------
echo
echo "=== holders: both launch paths, and buckets ==="
#
# holders/ pidfiles see only claude()/hspawn launches; a `clauth start` session
# appears only in clauth's live_sessions. Neither side alone counts both, and a
# picker that under-counts hands the next session the busiest account.

holders() { zrun "_claude_holder_count '$1'"; }

new_home o1
mkdir -p "$FHOME/.local/state/claude-account-dirs/a1/holders" "$FHOME/.clauth/live_sessions"
: > "$FHOME/.local/state/claude-account-dirs/a1/holders/$$"
check "a pidfile alone counts"                  "$(holders a1)" "1"
printf '{"pid":%d,"start_profile":"a1"}\n' "$$" > "$FHOME/.clauth/live_sessions/s1.json"
check "pidfile and live_sessions are SUMMED"    "$(holders a1)" "2"

printf '{"pid":999999,"start_profile":"a1"}\n' > "$FHOME/.clauth/live_sessions/dead.json"
check "a dead live_sessions pid is not counted" "$(holders a1)" "2"
# clauth owns those files. Pruning from here would race its writer.
check "...and its file is NOT deleted" \
      "$([[ -f "$FHOME/.clauth/live_sessions/dead.json" ]] && echo kept || echo REMOVED)" "kept"

# A --with-fallback session moves accounts; start_profile is where it BEGAN.
new_home o2
mkdir -p "$FHOME/.clauth/live_sessions"
printf '{"pid":%d,"start_profile":"a1","current_member":"b2"}\n' "$$" > "$FHOME/.clauth/live_sessions/s.json"
check "current_member wins over start_profile"  "$(holders b2)" "1"
check "...and the start profile is not counted" "$(holders a1)" "0"

# A dead pidfile IS ours, so it is pruned as it is counted.
new_home o3
mkdir -p "$FHOME/.local/state/claude-account-dirs/a1/holders"
: > "$FHOME/.local/state/claude-account-dirs/a1/holders/999999"
check "a dead pidfile is not counted"           "$(holders a1)" "0"
check "...and IS removed, because this layer owns it" \
      "$([[ -f "$FHOME/.local/state/claude-account-dirs/a1/holders/999999" ]] && echo kept || echo removed)" "removed"

# Buckets. CLAUDE_TENANT_BUCKETS is empty on this machine (the shared-bucket
# verdict was withdrawn 2026-09-10 — two profiles read 7d 2% against 100% with no
# reset due for days, and they resolve to different seats), so this is a fixture
# row and deliberately does not depend on the machine's own grouping.
new_home o4
mkdir -p "$FHOME/.local/state/claude-account-dirs/a1/holders" \
         "$FHOME/.local/state/claude-account-dirs/b2/holders" "$FHOME/.clauth/live_sessions"
: > "$FHOME/.local/state/claude-account-dirs/a1/holders/$$"
: > "$FHOME/.local/state/claude-account-dirs/b2/holders/$$"
check "without a bucket each account counts only its own" "$(holders a1)" "1"
check "bucket members are SUMMED when configured" \
      "$(zrun "CLAUDE_TENANT_BUCKETS=( 'a1 b2' ); _claude_holder_count a1")" "2"
check "...for every member of the bucket" \
      "$(zrun "CLAUDE_TENANT_BUCKETS=( 'a1 b2' ); _claude_holder_count b2")" "2"
check "...and an unrelated account is untouched by it" \
      "$(zrun "CLAUDE_TENANT_BUCKETS=( 'a1 b2' ); _claude_holder_count c3")" "0"

# CLAUDE_TENANT_BUCKETS is a LIST, not a map. #129 declared it -gA (copying
# §5.1, which declares it associative and then shows a list as its example
# value); assigning a one-element list to an associative array fails outright
# with "bad set of key/value pairs". A tenant file that just assigns — exactly
# what §5.1 shows — got an error and an unusable table.
check "a bucket list assigns cleanly with NO re-declaration" \
      "$(zrun "CLAUDE_TENANT_BUCKETS=( 'a1 b2' ) 2>&1
               print -r -- \"\${(t)CLAUDE_TENANT_BUCKETS}:\${#CLAUDE_TENANT_BUCKETS}\"")" \
      "array:1"

# An EMPTY live_sessions directory is an ordinary resting state — clauth creates
# the directory — and it must not hang. An empty file glob leaves jq with no file
# operands, and jq then reads STDIN and blocks forever; `(N)` suppresses the
# no-match error but produces exactly that empty expansion. This ran on every
# `claude` launch. `timeout` is the assertion: without the guard the row never
# returns rather than returning something wrong.
new_home o6
mkdir -p "$FHOME/.clauth/live_sessions"
check "an EMPTY live_sessions dir returns 0 and does not hang" \
      "$(timeout 10 zsh -f -c "
           export HOME='$FHOME'
           source '$HERDRRC' >/dev/null 2>&1
           _claude_holder_count a1" < /dev/zero 2>/dev/null)" "0"

new_home o5
check "no holders anywhere is 0, not an error"  "$(holders a1)" "0"

#-----------------------------------------------------------------------------
echo
echo "=== round-robin: within the band, least recently picked wins ==="
#
# Scores separate accounts that differ MEANINGFULLY. Inside RR_BAND the
# difference is noise, and always taking the top would pile every session onto
# one account — the concentration this layer exists to undo.

LED="$TMPROOT/led"
led_run() { mkdir -p "$LED"; zsh -f -c "
      unset CLAUDE_CONFIG_DIR HERDR_PANE_ID
      export HOME='$FHOME'
      CLAUDE_ACCOUNT_DIRS_ROOT='$LED'
      CLAUDE_TENANTS_FILE=/nonexistent
      source '$HERDRRC' >/dev/null 2>&1
      local -a _claude_pick_warnings=()
      $1" 2>/dev/null; }

# The zsh snippets below are written with QUOTED heredocs. They contain zsh
# literals like $'9000\ta1', and inside a single-quoted bash string shellcheck
# reads those as an expansion that will not expand (SC2016) — which `shellcheck
# -x` exits non-zero on, failing both the ShellCheck job and the pre-commit hook.
# A quoted heredoc says "this is data" and needs no disable comment.
snip() { SNIP="$(cat)"; }

new_home r1; rm -rf "$LED"
snip <<'EOS'
_claude_pick_cands=( $'9000\ta1' $'5000\tb2' ); _claude_pick_choose && print -r -- $REPLY
EOS
check "with an empty ledger the top score wins" "$(led_run "$SNIP")" "a1"

# Inside the band the two are tied, so the ledger decides.
snip <<'EOS'
_claude_pick_ledger_write a1
_claude_pick_cands=( $'9000\ta1' $'8500\tb2' )
_claude_pick_choose && print -r -- $REPLY
EOS
check "inside RR_BAND the least recently picked wins" "$(led_run "$SNIP")" "b2"

# The row above cannot tell "consulted the ledger" from "took whatever sorted
# first": entries sort as "<score>\t<name>" strings, so the lower-scored b2 leads
# either way, and a mutant that ignored the ledger entirely survived it. With
# EQUAL scores the sort falls back to the name, so the two answers diverge — sort
# order says a1, the ledger says b2.
rm -rf "$LED"
snip <<'EOS'
_claude_pick_ledger_write a1
_claude_pick_cands=( $'9000\ta1' $'9000\tb2' )
_claude_pick_choose && print -r -- $REPLY
EOS
check "...and that is the ledger deciding, not the sort order" "$(led_run "$SNIP")" "b2"

rm -rf "$LED"
snip <<'EOS'
_claude_pick_ledger_write a1
_claude_pick_cands=( $'9000\ta1' $'5000\tb2' )
_claude_pick_choose && print -r -- $REPLY
EOS
check "outside RR_BAND the score wins regardless of the ledger" "$(led_run "$SNIP")" "a1"

# The ledger PERSISTS across led_run calls, and rows above wrote `a1` into it —
# so this one must start from an empty ledger or it is really testing "least
# recently picked" again.
rm -rf "$LED"
snip <<'EOS'
_claude_pick_cands=( $'9000\tb2' $'9000\ta1' ); _claude_pick_choose && print -r -- $REPLY
EOS
check "with no ledger entries a tie breaks by name, deterministically" "$(led_run "$SNIP")" "a1"

# The ledger is a file, and a concurrent reader must never see it half-written.
new_home r2; rm -rf "$LED"
snip <<'EOS'
_claude_pick_ledger_write a1; _claude_pick_ledger_read; print -r -- ${+_CLAUDE_LEDGER[a1]}
EOS
check "the ledger records the pick" "$(led_run "$SNIP")" "1"

snip <<'EOS'
_claude_pick_ledger_write a1; _claude_pick_ledger_write b2
_claude_pick_ledger_read; print -r -- ${#_CLAUDE_LEDGER}
EOS
check "a second pick does not lose the first" "$(led_run "$SNIP")" "2"

snip <<'EOS'
_claude_pick_ledger_write a1
i1=$(zmodload -F zsh/stat b:zstat; zstat +inode $(_claude_pick_ledger_file))
_claude_pick_ledger_write b2
i2=$(zmodload -F zsh/stat b:zstat; zstat +inode $(_claude_pick_ledger_file))
[[ $i1 != $i2 ]] && print changed || print same
EOS
check "the replace is atomic — the inode changes, it is not truncated in place" \
      "$(led_run "$SNIP")" "changed"

# A stuck lock must never block a launch: the worst case of proceeding unlocked
# is the ordinary pre-ledger behaviour, while the worst case of blocking is that
# `claude` hangs. The row bounds itself, because the failure mode is a hang.
#
# The background holder SIGNALS once it holds the lock. A sleep-based holder is a
# race, and it passes with the locking removed exactly when the machine is
# loaded — which is when a mutation sweep runs.
#
# It also has to CREATE the lock file and check that its own flock succeeded, and
# both were missing until 2026-09-10. `zsystem flock` opens without O_CREAT, so
# on a path nothing has created the holder's flock failed, the foreground call's
# flock failed for the same reason, and the row read `warned` — the answer it
# expects — while nothing was ever locked. A row that asserts a WARNING passes in
# every state that warns, including "the mechanism has never once worked"; the
# missing row is the one that asserts the uncontended case is SILENT.
new_home r3; rm -rf "$LED"; mkdir -p "$LED"
cat > "$TMPROOT/locktest.zsh" <<'EOS'
source "$HERDRRC_P" >/dev/null 2>&1
zmodload zsh/system
: >> "$LED_P/.pick-ledger.lock"
( zsystem flock -f hfd "$LED_P/.pick-ledger.lock" || exit 1
  print ready > "$LED_P/held"
  sleep 8 ) &
for i in {1..100}; do [[ -f "$LED_P/held" ]] && break; sleep 0.1; done
[[ -f "$LED_P/held" ]] || { print -r -- holder-never-acquired; exit 0 }
local -a _claude_pick_warnings=()
CLAUDE_PICK_LOCK_WAIT=1 _claude_pick_with_ledger_lock _claude_pick_ledger_write a1
(( ${#_claude_pick_warnings} )) && print -r -- warned || print -r -- silent
EOS
check "a held lock does not block the pick past the timeout, and warns" \
      "$(HOME="$FHOME" HERDRRC_P="$HERDRRC" LED_P="$LED" CLAUDE_ACCOUNT_DIRS_ROOT="$LED" \
         CLAUDE_TENANTS_FILE=/nonexistent \
         timeout 20 zsh -f "$TMPROOT/locktest.zsh" </dev/zero 2>/dev/null)" "warned"

#-----------------------------------------------------------------------------
echo
echo "=== backpressure: measured, warned about, and NOT refused by default ==="
#
# D6 as amended: this laptop is deliberately oversubscribed and must keep
# working, so the picker chooses an account rather than policing the box. A
# refusal happens only when a *_MAX knob is explicitly set.

mkproc() {   # $1 = loadavg first field, $2 = cpu online spec, $3 = SwapTotal kB, $4 = SwapFree kB
    PROCR="$TMPROOT/proc.$RANDOM"
    mkdir -p "$PROCR/proc" "$PROCR/sys/devices/system/cpu"
    printf '%s 1.00 1.00 1/1 1\n' "$1" > "$PROCR/proc/loadavg"
    printf '%s\n' "$2" > "$PROCR/sys/devices/system/cpu/online"
    { printf 'MemTotal:       1 kB\n'
      printf 'SwapTotal: %s kB\n' "$3"
      printf 'SwapFree:  %s kB\n' "$4"; } > "$PROCR/proc/meminfo"
}
bp() {   # $1 = extra prelude -> "<rc>:<warning count>"
    zsh -f -c "
      unset CLAUDE_CONFIG_DIR HERDR_PANE_ID
      export HOME='$FHOME'
      CLAUDE_PICK_PROC_ROOT='$PROCR'
      CLAUDE_TENANTS_FILE=/nonexistent
      source '$HERDRRC' >/dev/null 2>&1
      typeset -ga _claude_pick_warnings=()
      ${1:-}
      _claude_pick_backpressure; rc=\$?
      print -r -- \"\$rc:\${#_claude_pick_warnings}\"" 2>/dev/null
}

new_home bp1
mkproc 1.00 0-7 8000000 8000000     # load 1.0 on 8 cpus = 12%, no swap used
check "a quiet machine warns about nothing"              "$(bp)" "0:0"

mkproc 24.00 0-7 8000000 4000000    # load 24 on 8 = 300%, swap 50%
check "a loaded machine warns"                           "$(bp)" "0:1"
# THE WARNING'S NUMBERS, not just its existence. Every row here counted warnings
# and none read one, so the text went unpinned — and it printed the ratio alone
# ("load 3.0 x 8 threads"), a number that appears nowhere else, while
# `claude-pick --explain` reported the load itself for the same machine. Found by
# running it beside that line on the real box, not by a row.
bpmsg() {
    zsh -f -c "
      unset CLAUDE_CONFIG_DIR HERDR_PANE_ID
      export HOME='$FHOME'
      CLAUDE_PICK_PROC_ROOT='$PROCR'
      CLAUDE_TENANTS_FILE=/nonexistent
      source '$HERDRRC' >/dev/null 2>&1
      typeset -ga _claude_pick_warnings=()
      _claude_pick_backpressure >/dev/null 2>&1
      print -r -- \"\${_claude_pick_warnings[1]}\"" 2>/dev/null
}
check "...naming the load itself, then the ratio" \
      "$(bpmsg)" "machine: load 24.00 on 8 threads (3.0x) — a new session will thrash"
check "...and does NOT refuse, because no MAX is set"    "$(bp | cut -d: -f1)" "0"
check "...but refuses once LOAD_MAX is set and exceeded" \
      "$(bp 'CLAUDE_PICK_LOAD_MAX=200' | cut -d: -f1)"   "3"
check "...and not when LOAD_MAX is set above the load" \
      "$(bp 'CLAUDE_PICK_LOAD_MAX=400' | cut -d: -f1)"   "0"

mkproc 1.00 0-7 8000000 2000000     # swap 75%
check "swap alone warns"                                 "$(bp)" "0:1"
check "...and refuses only with SWAP_MAX set"            "$(bp 'CLAUDE_PICK_SWAP_MAX=70' | cut -d: -f1)" "3"

# SwapTotal 0 is a machine with no swap, not a machine at 100% swap. Dividing by
# it is a division by zero; reporting 100 would warn forever.
mkproc 1.00 0-7 0 0
check "SwapTotal 0 is skipped, not read as 100%"         "$(bp)" "0:0"

# Counting ONLINE cpus, not the highest index: with cpus offline the load
# threshold would otherwise be wrong in whichever direction the gap falls.
mkproc 6.00 0-1,4-5 8000000 8000000  # 4 cpus, load 6 = 150% -> warns
check "offline cpus are excluded from the thread count"  "$(bp)" "0:1"
mkproc 6.00 0-7 8000000 8000000      # 8 cpus, load 6 = 75% -> quiet
check "...and the same load on 8 threads is quiet"       "$(bp)" "0:0"

# An unreadable /proc must not invent a number.
PROCR="$TMPROOT/proc-empty"; mkdir -p "$PROCR"
check "an unreadable /proc warns about nothing and does not refuse" "$(bp)" "0:0"

#-----------------------------------------------------------------------------
echo
echo "=== exhaustion: name the soonest reset, and name NO time when none is known ==="
#
# resets_at is absent whenever the 5h window has not started — measured on three
# of five profiles here — so "no reset instant" is the COMMON case, not an edge.

# `|` as the separator, NOT `:`. The reset text is "%H:%M", so a colon separator
# is split by the TIME's own colon — `cut -d: -f2` returned "Thu 01 Jan 00" and
# the row failed against perfectly correct output.
lb() {   # profiles... -> "<pick>|<reset text>"
    zrun "_claude_pick_least_bad $* >/dev/null
          print -r -- \"\$REPLY|\$(_claude_pick_reset_text \$_CLAUDE_PICK_LEASTBAD_RESET)\""
}

new_home x1
mkprof a1 '{"five_hour":{"utilization":99.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"}}'
mkprof b2 '{"five_hour":{"utilization":99.0,"resets_at":"2098-01-01T00:00:00.000000+00:00"}}'
check "the soonest reset wins"                  "$(lb a1 b2 | cut -d\| -f1)" "b2"
check "...and its reset instant is named"       "$(lb a1 b2 | cut -d\| -f2 | grep -c '[0-9][0-9]:[0-9][0-9]')" "1"

# A known reset beats an unknown one: an account that might free up in four
# minutes is a better bet than one nobody can time.
new_home x2
mkprof a1 '{"five_hour":{"utilization":99.0}}'
mkprof b2 '{"five_hour":{"utilization":99.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"}}'
check "a KNOWN reset is preferred over an unknown one" "$(lb a1 b2 | cut -d\| -f1)" "b2"
# ORDER MATTERS, and the row above cannot see it: with the unknown listed first
# it is only ever a candidate for an empty slot, so a mutant that lets an unknown
# overwrite a known one survives. Listing the known one FIRST is what exercises
# the overwrite.
check "...whatever the order they are considered in" "$(lb b2 a1 | cut -d\| -f1)" "b2"

# The case the spec's message could not express.
new_home x3
mkprof a1 '{"five_hour":{"utilization":99.0}}'
mkprof b2 '{"five_hour":{"utilization":98.0}}'
check "with NO known reset an account is still named" \
      "$(lb a1 b2 | cut -d\| -f1 | grep -cE '^(a1|b2)$')" "1"
check "...and no time is invented"               "$(lb a1 b2 | cut -d\| -f2)" ""
check "the reset formatter returns empty for unknown, not an epoch date" \
      "$(zrun '_claude_pick_reset_text unknown')" ""

# Behind the spend wall it is the WEEK that has to reset, so that is the wait to
# quote. Both 5h windows below reset at the same far instant, so the old
# r5-only choice ties and keeps the first name — the row dies on it.
new_home x5
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 172800)\"},\"spend\":{\"enabled\":false}}"
mkprof b2 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 86400)\"},\"spend\":{\"enabled\":false}}"
check "behind the spend wall, the soonest WEEKLY reset is least bad" "$(lb a1 b2 | cut -d\| -f1)" "b2"

#-----------------------------------------------------------------------------
echo
echo "=== the lock is actually TAKEN, not merely warned about ==="
#
# The row above asserts the contended case warns. Nothing asserted the
# UNCONTENDED case is silent, and that is the whole difference between a lock
# that works and one that has never once been acquired: `zsystem flock` opens
# without O_CREAT, so on a lock path nothing created, every call failed to open,
# fell into the proceed-unlocked fallback and warned — forever, since nothing
# else ever creates that file.

new_home lk1; rm -rf "$LED"
snip <<'EOS'
local -a _claude_pick_warnings=()
_claude_pick_with_ledger_lock _claude_pick_ledger_write a1
(( ${#_claude_pick_warnings} )) && print -r -- warned || print -r -- silent
EOS
check "an uncontended pick TAKES the lock and says nothing" "$(led_run "$SNIP")" "silent"

snip <<'EOS'
_claude_pick_with_ledger_lock _claude_pick_ledger_write a1
[[ -e "$(_claude_pick_ledger_lock)" ]] && print exists || print absent
EOS
check "...having created the lock file it needs" "$(led_run "$SNIP")" "exists"

# `: >>`, never `: >`. A truncating create would clear a lock file another
# process is holding at the moment a third arrives.
new_home lk2; rm -rf "$LED"; mkdir -p "$LED"
printf 'sentinel\n' > "$LED/.pick-ledger.lock"
snip <<'EOS'
_claude_pick_with_ledger_lock _claude_pick_ledger_write a1
print -r -- "$(< "$(_claude_pick_ledger_lock)")"
EOS
check "an existing lock file is not truncated" "$(led_run "$SNIP")" "sentinel"

#-----------------------------------------------------------------------------
echo
echo "=== RFC 3339: the zone is part of the instant, not decoration ==="
#
# `strftime -r` is strptime followed by mktime, and mktime reads a broken-down
# time as LOCAL and discards any offset strptime parsed. So cutting the string at
# its first `.` and parsing the rest yields an instant wrong by this machine's
# own UTC offset — measured 2026-09-10 at UTC+2, two hours early, and three in
# summer. r5 drives the expiry bonus over an 18000 s window, so that is up to 60%
# of the window, and it shifts every reset time the §5.4 messages print.
#
# These rows assert the VALUE, which is what the task-1 rows did not: they
# checked that an absent reset is `unknown` and an unparseable one is `unknown`,
# and a WRONG NUMBER satisfies neither.

tsd() {   # $1 = instant -> the absolute epoch it names, or "rc1"
    zrun "if _claude_ts_delta '$1'; then print -r -- \$(( EPOCHSECONDS + _CLAUDE_TS_DELTA )); else print -r -- rc1; fi"
}
# 2099-01-01T00:00:00Z is 4070908800; the same wall time at -03:00 is 4070919600.
check "a +00:00 offset is read as UTC"      "$(tsd '2099-01-01T00:00:00.000000+00:00')" "4070908800"
check "a Z designator is read as UTC"       "$(tsd '2099-01-01T00:00:00Z')"             "4070908800"
check "a +hhmm offset is read as UTC"       "$(tsd '2099-01-01T00:00:00+0000')"         "4070908800"
check "a NON-zero offset is applied"        "$(tsd '2099-01-01T00:00:00-03:00')"        "4070919600"
check "no zone at all is read as UTC, not as local time" \
      "$(tsd '2099-01-01T00:00:00')"        "4070908800"
check "an unparseable instant is still rc1" "$(tsd 'not a timestamp')"                  "rc1"

# ...and through the metrics function, which is where it matters.
new_home tz1
mkprof a1 '{"five_hour":{"utilization":5.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":9.0,"resets_at":"2099-02-01T00:00:00.000000+00:00"}}'
snip <<'EOS'
_claude_profile_metrics a1; print -r -- $(( EPOCHSECONDS + _CPM_R5 ))
EOS
check "_CPM_R5 names the instant the cache does"  "$(zrun "$SNIP")" "4070908800"

# --- the absolute instant, which is what a RENDERER must use (DO-612) --------
#
# Every row above reconstructs the instant as `EPOCHSECONDS + <delta>`, and that
# is precisely the arithmetic this section now exists to keep out of the
# rendering path: it reads the clock a SECOND time, so a second boundary falling
# between the two reads makes the answer one second late. Those rows survive it
# only because their two reads are microseconds apart; `--json` had real work in
# between and failed 1 run in 6, always by exactly +1s, never early.
#
# So these rows read the published epoch DIRECTLY and no row below adds
# EPOCHSECONDS to anything. The delta rows above stay as they are — the delta is
# still what scoring wants, and its zone arithmetic needs pinning too.
tsa() {   # $1 = instant -> the absolute epoch published for rendering
    zrun "_claude_ts_delta '$1' >/dev/null 2>&1; print -r -- \$_CLAUDE_TS_ABS"
}
check "_CLAUDE_TS_ABS is the instant itself, no clock read" \
      "$(tsa '2099-01-01T00:00:00.000000+00:00')" "4070908800"
check "...with a non-zero offset applied, exactly as the delta has it" \
      "$(tsa '2099-01-01T00:00:00-03:00')"        "4070919600"
# A PARSE FAILURE MUST NOT LEAVE A NUMBER, and this is the arm that decides it:
# the pair is assigned only on the parser's success, so an earlier profile's
# instant cannot survive into a later profile that has none. Without the reset at
# the top of the function, the second call below reports the FIRST call's epoch.
snip <<'EOS'
_claude_ts_delta '2099-01-01T00:00:00.000000+00:00' >/dev/null 2>&1
_claude_ts_delta 'not a timestamp' >/dev/null 2>&1
print -r -- $_CLAUDE_TS_ABS
EOS
check "...and an unparseable instant leaves no STALE epoch behind" \
      "$(zrun "$SNIP")" "unknown"

snip <<'EOS'
_claude_profile_metrics a1; print -r -- "$_CPM_R5_AT $_CPM_RW_AT"
EOS
check "_CPM_R5_AT and _CPM_RW_AT name both instants absolutely" \
      "$(zrun "$SNIP")" "4070908800 4073587200"

snip <<'EOS'
_claude_profile_metrics a1; print -r -- $(( EPOCHSECONDS + _CPM_RW ))
EOS
check "_CPM_RW is the aggregate weekly reset"     "$(zrun "$SNIP")" "4073587200"

new_home tz2
mkprof a1 '{"five_hour":{"utilization":5.0},"seven_day":{"utilization":9.0}}'
snip <<'EOS'
_claude_profile_metrics a1; print -r -- $_CPM_RW
EOS
check "an absent weekly reset is unknown, not zero" "$(zrun "$SNIP")" "unknown"
snip <<'EOS'
_claude_profile_metrics a1; print -r -- "$_CPM_U5 $_CPM_UW"
EOS
check "...and the extra column does not shift the ones beside it" \
      "$(zrun "$SNIP")" "5 9"

# Absent and unparseable are the two states the whole metrics layer exists to
# keep apart from a measured zero, and the _AT pair has to honour it too: an
# epoch of 0 renders as 1970, which is a date, and a date reads as an answer.
#
# These are last in the section ON PURPOSE: new_home REPLACES the fixture, and
# an earlier placement silently re-pointed the rows below at a profile with no
# weekly reset — which is how the `_CPM_RW is the aggregate weekly reset` row
# came to be asserting against the wrong cache while looking untouched.
new_home tzat1
mkprof a1 '{"five_hour":{"utilization":0.0},"seven_day":{"utilization":2.0}}'
check "an ABSENT resets_at leaves _CPM_R5_AT unknown, never an epoch" \
      "$(zrun "_claude_profile_metrics a1; print -r -- \$_CPM_R5_AT")" "unknown"
new_home tzat2
mkprof a1 '{"five_hour":{"utilization":5.0,"resets_at":"not a timestamp"}}'
check "an UNPARSEABLE resets_at leaves _CPM_R5_AT unknown"  \
      "$(zrun "_claude_profile_metrics a1; print -r -- \$_CPM_R5_AT")" "unknown"


#-----------------------------------------------------------------------------
echo
echo "=== the tie inside RR_BAND breaks by NAME, not by the score's text ==="
#
# Entries are "<score>\t<name>" strings, so iterating `${(o)}` over them sorted
# by the SCORE TEXT. With an empty ledger every candidate's time is 0, `<` is
# never true, and the first in iteration order wins — which inside the band
# handed it to the LOWEST-scoring member, and put any negative score ahead of
# every positive one. The rule was documented as "then name" throughout.

new_home nb1; rm -rf "$LED"
snip <<'EOS'
_claude_pick_cands=( $'9000\ta1' $'8500\tb2' ); _claude_pick_choose && print -r -- $REPLY
EOS
check "inside the band with no ledger, the tie breaks by name" "$(led_run "$SNIP")" "a1"

rm -rf "$LED"
snip <<'EOS'
_claude_pick_cands=( $'-500\tz9' $'-400\ta1' ); _claude_pick_choose && print -r -- $REPLY
EOS
check "...and a negative score does not sort ahead of a better one" "$(led_run "$SNIP")" "a1"

#-----------------------------------------------------------------------------
echo
echo "=== the machine numbers survive the call that decided on them ==="
#
# --explain and the JSON report the load a refusal was decided on. Reading /proc
# a second time could legitimately give a different answer, and then the report
# would not be about the decision — so the measurement is published, by one
# writer, rather than localised and re-taken.

new_home mp1
mkproc 24.00 0-7 8000000 4000000
check "_CML_* are set after _claude_pick_backpressure returns" \
      "$(zsh -f -c "
          export HOME='$FHOME'
          CLAUDE_PICK_PROC_ROOT='$PROCR'
          CLAUDE_TENANTS_FILE=/nonexistent
          source '$HERDRRC' >/dev/null 2>&1
          typeset -ga _claude_pick_warnings=()
          _claude_pick_backpressure >/dev/null 2>&1
          print -r -- \"\$_CML_LOAD1 \$_CML_NCPU \$_CML_SWAPPCT\"" 2>/dev/null)" \
      "2400 8 50"

#-----------------------------------------------------------------------------
echo
echo "=== sourcing under CLAUDE_PICK_SOURCING has no side effect ==="
#
# scripts/claude-pick sources this file to reach the picker and wants nothing
# else from it. The marker exists so that a future top-level side effect trips
# THIS row rather than the CLI — which is the only way the guard means anything,
# since a side effect that is merely absent today needs no guard at all.

check "sourcing under the marker prints nothing on either stream" \
      "$(CLAUDE_PICK_SOURCING=1 CLAUDE_TENANTS_FILE=/nonexistent \
         zsh -f -c "source '$HERDRRC'" 2>&1 | wc -c | tr -d ' ')" "0"
check "...and does not pull in the build-limits module" \
      "$(CLAUDE_PICK_SOURCING=1 CLAUDE_TENANTS_FILE=/nonexistent \
         zsh -f -c "source '$HERDRRC' >/dev/null 2>&1; print -r -- \$+functions[build-limits]" 2>/dev/null)" "0"
check "...while an ordinary source still provides it" \
      "$(CLAUDE_TENANTS_FILE=/nonexistent \
         zsh -f -c "source '$HERDRRC' >/dev/null 2>&1; print -r -- \$+functions[build-limits]" 2>/dev/null)" "1"

#-----------------------------------------------------------------------------
echo
echo "=== _claude_pick_for_dir: the one code path, and its five exits ==="
#
# Every caller — claude(), hspawn, claude-pick — goes through this. The classes
# are TIERS rather than scores: "unknown never outranks a measurement" is a rule
# about rank, and as arithmetic it would be at the mercy of the weights, because
# an eligible account at 96% with a spent week also scores near zero.

# The account-dir root is pointed at the fixture so the ledger and the holder
# pidfiles land there and not in the developer's own state directory.
# REAL pidfiles with LIVE pids, because _claude_holder_count prunes with `kill -0`
# as it counts -- a fixture of invented pids counts zero and the crowding term
# then contributes nothing, which is the difference between a row that pins the
# tier and a row that passes either way.
#
# The COUNT is load-bearing too. With a1 at 5h=61%/7d=33% and b2 idle at 7d=100%,
# the arithmetic alone gives a1 3900 - 1215h against b2's 0, so a1 wins on score
# until h reaches 4. A fixture with fewer holders would pass with the tier
# deleted; 11 mirrors what was measured on the real machine.
HOLD_PIDS=()
hold() {  # $1 = profile, $2 = how many live holders
    local d="$FHOME/.local/state/claude-account-dirs/$1/holders" i
    mkdir -p "$d"
    for (( i=0; i<$2; i++ )); do
        sleep 30 & : > "$d/$!"; HOLD_PIDS+=("$!")
    done
}
unhold() { (( ${#HOLD_PIDS[@]} )) && kill "${HOLD_PIDS[@]}" 2>/dev/null; HOLD_PIDS=(); return 0; }

# pfd() itself is defined earlier (DO-621's spend-wall rows need it first); this
# is its house-convention spot, documented above, right before its main section.

new_home fd1
mkprof a1 '{"five_hour":{"utilization":10.0}}'
mkprof b2 '-'
check "an eligible account beats an unreadable one outright" \
      "$(pfd '' '' '' 0)" "0:a1:picked:eligible"

new_home fd2
mkprof a1 '-'
mkprof b2 '-'
check "with only unreadable accounts one is still chosen, as class unknown" \
      "$(pfd '' '' '' 0 | cut -d: -f1,3,4)" "0:picked:unknown"

# Consume-first must hold for the PICK, not just the scores: inside RR_BAND the
# least-recently-picked seat wins, so a gap under 800 is a coin flip.
new_home wk1
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":60.0,\"resets_at\":\"$(iso_in 518400)\"}}"
mkprof b2 "{$FIVE,\"seven_day\":{\"utilization\":80.0,\"resets_at\":\"$(iso_in 43200)\"}}"
check "consume-first: B is picked with an empty ledger"        "$(pfd '' '' '' 0 | cut -d: -f2)" "b2"
printf 'a1\t1\nb2\t%s\n' "$(date +%s)" > "$FHOME/.local/state/claude-account-dirs/.pick-ledger"
check "...and still B when the ledger just picked B"           "$(pfd '' '' '' 0 | cut -d: -f2)" "b2"

# At equal reset distance, a nearly-spent week loses to a fresh one — the PICK,
# which is what this row asserts. It does NOT pin `weekf`: with weekf removed the
# two score 10058 and 14640 and b2 still wins, so the row survives that mutation.
# What pins weekf is the score row above asserting 3300 for an unknown reset,
# where weekf is the only term that can move the number.
new_home wk2
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":99.0,\"resets_at\":\"$(iso_in 432000)\"}}"
mkprof b2 "{$FIVE,\"seven_day\":{\"utilization\":20.0,\"resets_at\":\"$(iso_in 432000)\"}}"
check "an idle seat at 99% of its week loses to one at 20%"   "$(pfd '' '' '' 0 | cut -d: -f2)" "b2"

# THE TIER IS ONLY OBSERVABLE WHERE THE SCORE WOULD NOT HAVE SEPARATED THEM, and
# the row above cannot see it: a1 at 10% scores 9000 against an unknown's 0, and
# 9000 is far outside RR_BAND, so a mutant that scored the unknowns alongside the
# eligible ones changed nothing and survived. This is the case the rule exists
# for, and it is the one the code comment names: an eligible account at 96% of
# its 5h window with a fully spent week scores 0 as well — h5 is 4, and weekf
# collapses it — so as arithmetic "unknown never outranks a measurement" reduces
# to whichever name happens to sort first, and `a1` sorts before `b2`.
new_home fd2b
mkprof a1 '-'
mkprof b2 '{"five_hour":{"utilization":96.0},"seven_day":{"utilization":100.0}}'
# DO-609: b2's week is fully spent, so it is now class `weekly-spent` rather than
# `eligible` -- a TIER above `unknown`, since a measurement outranks the absence
# of one. The claim this row makes is unchanged (b2 still wins) and the assertion
# is strictly stronger: it pins the winner AND the demotion.
check "a measured near-spent account still beats an unreadable one" \
      "$(pfd '' '' '' 0 | cut -d: -f2,4)" "b2:weekly-spent"

# DO-609. THE BUG, REPRODUCED: an account at 100% of its weekly cap was picked
# over one with two thirds of its week left, because the exhausted one was idle.
#
# weekf multiplies (base + bonus), but crowd is subtracted UNSCALED, so at
# weekf=0 the score collapses to -crowd -- and crowd is near zero precisely
# because an exhausted account has no holders. Measured on the real machine
# 2026-09-10: quantivly-0/-3 at 7d=100% with 1 holder scored -300 and were
# picked; quantivly-1 at 7d=33% with 11 holders scored -8334.
#
# THE HOLDERS ARE THE WHOLE FIXTURE. Without them b2 outscores a1 on the
# arithmetic alone and the row passes with the tier deleted -- it would be
# decoration. hold() puts real pidfiles under the busy account, so the ONLY
# thing that can make a1 win is the tier.
new_home fd2c
mkprof a1 '{"five_hour":{"utilization":61.0},"seven_day":{"utilization":33.0}}'
mkprof b2 '{"five_hour":{"utilization":0.0},"seven_day":{"utilization":100.0}}'
hold a1 11
check "an account with weekly headroom beats an idle, weekly-spent one" \
      "$(pfd '' '' '' 0 | cut -d: -f2,4)" "a1:eligible"
unhold

# ...and the demotion must not become a refusal. DO-574 decided the weekly window
# DEMOTES rather than refuses, on measurements that still hold: two Team seats
# read 7d=100 with live sessions on them, and there were ZERO weekly-reset
# refusals in 750 transcripts over 7 days. A tier is chosen when nothing above it
# exists, so a pool that is entirely spent still yields an account.
new_home fd2d
mkprof a1 '{"five_hour":{"utilization":0.0},"seven_day":{"utilization":100.0}}'
mkprof b2 '{"five_hour":{"utilization":20.0},"seven_day":{"utilization":100.0}}'
check "a pool that is ENTIRELY weekly-spent still picks, and does not refuse" \
      "$(pfd '' '' '' 0 | cut -d: -f1,3,4)" "0:picked:weekly-spent"
check "...and refuses no harder for a headless caller either" \
      "$(pfd '' '' '' 1 | cut -d: -f1,3)" "0:picked"

# A spent week is MEASURED, so it outranks an unreadable account -- the same rule
# that puts `unknown` after every measured candidate.
new_home fd2e
mkprof a1 '-'
mkprof b2 '{"five_hour":{"utilization":5.0},"seven_day":{"utilization":100.0}}'
check "weekly-spent outranks unknown, because a measurement outranks its absence" \
      "$(pfd '' '' '' 0 | cut -d: -f2,4)" "b2:weekly-spent"

# OVERFLOW MUST NOT BE REACHED BY A MERELY-CAPPED POOL. Overflow borrows another
# tenant's account and bills work to the wrong place, so it is paid only when the
# pool named nothing usable at all. A weekly-spent member IS usable -- that is the
# whole point of demoting rather than refusing -- so the pass-found-something
# guard has to count the weekly tier too.
#
# This row exists because the mutation survived without it: dropping
# ${#_claude_pick_weekly} from that guard left all 197 other rows green while a
# capped-but-usable pool silently borrowed someone else's seat.
new_home fd2g
mkprof a1 '{"five_hour":{"utilization":5.0},"seven_day":{"utilization":10.0}}'
mkprof b2 '{"five_hour":{"utilization":5.0},"seven_day":{"utilization":100.0}}'
check "a weekly-spent POOL member is used rather than borrowing from overflow" \
      "$(pfd 'CLAUDE_TENANT_POOL=( t1 "b2" ); CLAUDE_TENANT_OVERFLOW=( t1 "a1" )' '' t1 0 | cut -d: -f2,4)" \
      "b2:weekly-spent"

# A 5h wall is still a 5h wall. The weekly tier must not rescue an account the
# exhaustion class already caught, or DO-574's refusal path stops working.
new_home fd2f
mkprof a1 '{"five_hour":{"utilization":99.0},"seven_day":{"utilization":100.0}}'
check "a 5h-exhausted account stays exhausted even with the weekly tier" \
      "$(pfd '' '' '' 1 | cut -d: -f1,3)" "2:exhausted"

# An exhausted pool: a real, self-clearing wall.
new_home fd3
mkprof a1 '{"five_hour":{"utilization":99.0,"resets_at":"2099-02-01T00:00:00.000000+00:00"},"seven_day":{"utilization":40.0}}'
mkprof b2 '{"five_hour":{"utilization":98.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":40.0}}'
check "STRICT refuses an exhausted pool with exit 2 and names nothing chosen" \
      "$(pfd '' '' '' 1)" "2::exhausted:"
check "INTERACTIVE proceeds on the least-bad member, exit 0" \
      "$(pfd '' '' '' 0)" "0:b2:picked:least-bad"

# The §5.4 blocks. stderr only, because that is where a caller reads a reason.
report() {   # $1 = strict -> the block, from stderr
    { zsh -f -c "
      unset CLAUDE_CONFIG_DIR HERDR_PANE_ID
      export HOME='$FHOME'
      export TZ='$FIXTZ'
      CLAUDE_ACCOUNT_DIRS_ROOT='$FHOME/.local/state/claude-account-dirs'
      CLAUDE_TENANTS_FILE=/nonexistent
      source '$HERDRRC' >/dev/null 2>&1
      _claude_pick_prog=claude-pick
      _claude_pick_for_dir '' '' '${1:-0}' 0 >/dev/null" >/dev/null; } 2>&1
}
check "the strict header names the earliest reset and the account it is on" \
      "$(report 1 | head -1 | grep -c 'refused — the account pool exhausted (earliest reset .*, on b2)')" "1"
check "...it lists EVERY member with its window" \
      "$(report 1 | grep -cE '^        (a1|b2)  5h [0-9]+% ')" "2"
check "...and closes with the override and a retry time" \
      "$(report 1 | tail -1 | grep -c -- '--profile <p> to override, or retry after ')" "1"
check "the interactive header says it is proceeding anyway" \
      "$(report 0 | head -1 | grep -c 'has NO usable account — proceeding on the least-bad one')" "1"
check "...naming only the member it is proceeding on" \
      "$(report 0 | grep -cE '^        (a1|b2)  5h ')" "1"
check "...and pointing at the two overrides" \
      "$(report 0 | tail -1 | grep -c 'claude-as <profile>')" "1"

# NO TIME IS INVENTED. resets_at is absent exactly when the window has not
# started, which is the common case, so this is the shape most refusals take.
new_home fd4
mkprof a1 '{"five_hour":{"utilization":99.0}}'
mkprof b2 '{"five_hour":{"utilization":98.0}}'
check "with no reset known the strict header says so instead of naming a time" \
      "$(report 1 | head -1 | grep -c 'exhausted (no reset time is known for any member)')" "1"
check "...the member line says the reset time is unknown" \
      "$(report 1 | grep -c 'reset time unknown')" "2"
check "...an unknown weekly figure carries no percent sign" \
      "$(report 1 | grep -c '7d unknown%')" "0"
check "...and the last line offers no retry time" \
      "$(report 1 | tail -1)" "        --profile <p> to override."

# A reset already in the PAST is not a time to quote back, and it is not rare:
# nothing on this machine refreshes the usage caches on a schedule, so a spent
# figure beside a rolled window is the ordinary stale reading. Formatting the
# delta unconditionally told the reader to wait for a moment long gone.
new_home fd5
mkprof a1 '{"five_hour":{"utilization":99.0,"resets_at":"2000-01-01T00:00:00.000000+00:00"}}'
check "a rolled window is reported as a stale reading, not as a past reset" \
      "$(report 1 | grep -c 'already rolled — this reading is stale')" "1"
check "...and the header says the same rather than quoting the date" \
      "$(report 1 | head -1 | grep -c 'exhausted on stale readings')" "1"
check "...so no reset time from the past is offered as a retry" \
      "$(report 1 | tail -1)" "        --profile <p> to override."

# DO-621 — THE REPORT QUOTES THE WALL THAT ACTUALLY BLOCKS THIS SEAT. Behind the
# spend wall it is the WEEK that has to roll, so the exhausted record carries
# that reset in field 5 (appended, never inserted) and the member line reads it.
# NOT ONE fixture above can reach the weekly substitution: fd3's week reads 40%,
# fd4's and fd5's have no weekly reading at all, and none of the three carries a
# spend block, so _CPM_SPEND is `unknown` where the substitution needs `none`.
# Field 5 therefore EQUALS field 4 throughout and the substitution is a no-op —
# so none of them can tell the two apart, and either half of the mechanism (the
# append in _claude_pick_for_dir, the ${f[5]:-} read in
# _claude_pick_report_exhausted) could be deleted with all three suites green. What that costs is not a missing
# detail: the header goes on reading _claude_pick_leastbad_reset, which stays
# right, so the refusal becomes INTERNALLY CONTRADICTORY — "retry in a day" on
# one line and a 2099 date on the next. Both lines are therefore asserted, since
# "they name the same instant" is the property, and each is pinned by a
# different mutant (field 5 for the member line, "least-bad ignores the block
# reset" for the header).
#
# TWO FIXED INSTANTS, far apart and NEITHER on a minute boundary. An instant
# makes a round trip through "seconds from now" and is re-rendered against a
# second read of the clock, so one whose seconds component is 00 can print a
# minute early when a second ticks in between; at :30 a one-second drift can
# never move the minute it renders. That is what makes these rows exact rather
# than probabilistic, and it is why the expected text is computed here — with
# the same GNU date `iso_in` already requires — instead of matched by pattern.
ISO_LATE='2099-01-01T00:00:30.000000+00:00'
ISO_EARLY='2098-06-15T12:34:30.000000+00:00'
TXT_LATE="$(TZ="$FIXTZ" date -d "$ISO_LATE" '+%a %d %b %H:%M %Z')"
TXT_EARLY="$(TZ="$FIXTZ" date -d "$ISO_EARLY" '+%a %d %b %H:%M %Z')"

# Which wall's reset does _claude_pick_block_reset quote? Compared against the
# seat's OWN two instants inside one process, so there is no tolerance to choose
# and no clock to race. `both-equal` is the degenerate fixture that would make
# the answer mean nothing, and it is reported rather than passing as either.
blockwall() {   # $1 = profile -> 5h | weekly | both-equal | neither:<value>
    zrun "_claude_profile_metrics '$1' >/dev/null
          r=\$(_claude_pick_block_reset)
          if   [[ \$r == \$_CPM_R5 && \$r == \$_CPM_RW ]]; then print -r -- both-equal
          elif [[ \$r == \$_CPM_RW ]]; then print -r -- weekly
          elif [[ \$r == \$_CPM_R5 ]]; then print -r -- 5h
          else print -r -- \"neither:\$r\"; fi"
}

# The spend wall alone: the 5h window is FRESH (0% used), so only the week blocks
# and the 5h reset below is there purely as the wrong answer to catch.
new_home fd5b
mkprof e1 "{\"five_hour\":{\"utilization\":0.0,\"resets_at\":\"$ISO_LATE\"},\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$ISO_EARLY\"},\"spend\":{\"enabled\":false}}"
blk="$(report 1)"
mem="$(printf '%s\n' "$blk" | sed -n 's/^ *e1  .*(resets \(.*\))$/\1/p')"
hdr="$(printf '%s\n' "$blk" | sed -n 's/.*earliest reset \(.*\), on e1)$/\1/p')"
check "behind the spend wall the member line quotes the WEEKLY reset, not the 5h one" \
      "$mem" "$TXT_EARLY"
check "...and the header names that same instant, so the refusal cannot contradict itself" \
      "$hdr" "$TXT_EARLY"

# BOTH WALLS AT ONCE, the week clearing last. _claude_pick_block_reset takes the
# later of the two, because both have to clear before the seat is usable again.
new_home fd5c
mkprof e1 "{\"five_hour\":{\"utilization\":99.0,\"resets_at\":\"$ISO_EARLY\"},\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$ISO_LATE\"},\"spend\":{\"enabled\":false}}"
check "both walls up and the WEEK later: that is the reset the seat reports" \
      "$(blockwall e1)" "weekly"
blk="$(report 1)"
mem="$(printf '%s\n' "$blk" | sed -n 's/^ *e1  .*(resets \(.*\))$/\1/p')"
check "...and the report quotes it, not the 5h reset that clears first" \
      "$mem" "$TXT_LATE"

# The other direction, which the REPORT cannot see: with the 5h wall clearing
# last, field 5 equals field 4 and the member line reads the same either way. So
# it is pinned on the function instead — a row that cannot distinguish the two
# answers is decoration however carefully it is worded.
new_home fd5d
mkprof e1 "{\"five_hour\":{\"utilization\":99.0,\"resets_at\":\"$ISO_LATE\"},\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$ISO_EARLY\"},\"spend\":{\"enabled\":false}}"
check "both walls up and the 5H later: that is the reset the seat reports" \
      "$(blockwall e1)" "5h"

# AN UNDATEABLE WEEK IS `unknown`, NOT THE 5H RESET. Whether the spend wall
# APPLIES and whether its reset can be DATED are two questions, and they used to
# share one `&&` chain, so the second answered the first: the substitution was
# skipped and `r` fell back to _CPM_R5, putting the FIVE-HOUR reset on a refusal
# the WEEK has to clear. Restore that chain and this fixture's refusal quotes
# $TXT_LATE — the 2099 five-hour instant, rendered without a year, offered as the
# moment to retry — on the header AND on the member line, which is what made it
# invisible: uniformly wrong reads as right.
#
# `blockwall` cannot see this: _CPM_RW is the literal `unknown` here, so a
# returned `unknown` compares equal to it and the helper answers `weekly` either
# way. The value itself is what these rows assert.
blockraw() { zrun "_claude_profile_metrics '$1' >/dev/null; _claude_pick_block_reset"; }

new_home fd5e
mkprof e1 "{\"five_hour\":{\"utilization\":0.0,\"resets_at\":\"$ISO_LATE\"},\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"garbage\"},\"spend\":{\"enabled\":false}}"
check "an UNPARSEABLE weekly reset behind the spend wall is unknown, not the 5h one" \
      "$(blockraw e1)" "unknown"
blk="$(report 1)"
check "...so the member line says the time is unknown" \
      "$(printf '%s\n' "$blk" | grep -c 'reset time unknown')" "1"
check "...and the header offers no retry instant at all" \
      "$(printf '%s\n' "$blk" | head -1 | grep -c 'no reset time is known for any member')" "1"
check "...and no 5h instant reaches the report" \
      "$(printf '%s\n' "$blk" | grep -c "$TXT_LATE")" "0"

# REACHABLE AT THE DEFAULT CONFIGURATION, which is why this is a fix and not a
# noted gap: `dw3` above exists precisely to keep a 100% week with no resets_at
# rankable (clauth omits the key on an unstarted window), and such a seat with
# spend `none` lands here. No knob is armed in this fixture.
new_home fd5f
mkprof e1 "{\"five_hour\":{\"utilization\":0.0,\"resets_at\":\"$ISO_LATE\"},\"seven_day\":{\"utilization\":100.0},\"spend\":{\"enabled\":false}}"
check "an ABSENT weekly reset behind the spend wall is unknown too" \
      "$(blockraw e1)" "unknown"

# BOTH WALLS, ONE INSTANT UNREADABLE. The wait is the LATER of the two, so half
# an answer is no answer: quoting the readable half would present a lower bound
# as the moment to retry.
new_home fd5g
mkprof e1 "{\"five_hour\":{\"utilization\":99.0,\"resets_at\":\"garbage\"},\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$ISO_EARLY\"},\"spend\":{\"enabled\":false}}"
check "both walls up with the 5h instant unreadable: the combined wait is unknown" \
      "$(blockraw e1)" "unknown"

# ...and a seat the spend wall does NOT reach still reports its 5h reset, with a
# readable weekly one sitting there as the wrong answer to catch. Every fixture
# above is behind the wall — fd5d declines the substitution because the weekly
# reset is EARLIER, which is the arithmetic, not the gate — so on their own they
# cannot tell "the gate is right" from "the gate was widened".
new_home fd5h
mkprof e1 "{\"five_hour\":{\"utilization\":99.0,\"resets_at\":\"$ISO_EARLY\"},\"seven_day\":{\"utilization\":40.0,\"resets_at\":\"$ISO_LATE\"},\"spend\":{\"enabled\":false}}"
check "a seat blocked by the 5h window alone still quotes the 5h reset" \
      "$(blockwall e1)" "5h"

# Machine backpressure: warn-only unless a ceiling is set, and only a headless
# caller refuses on it.
new_home fd6
mkprof a1 '{"five_hour":{"utilization":10.0}}'
mkproc 24.00 0-7 8000000 4000000
check "a loaded machine does not refuse a strict caller by default" \
      "$(pfd "CLAUDE_PICK_PROC_ROOT='$PROCR'" '' '' 1 | cut -d: -f1,2)" "0:a1"
check "...it refuses once LOAD_MAX is set and exceeded" \
      "$(pfd "CLAUDE_PICK_PROC_ROOT='$PROCR' CLAUDE_PICK_LOAD_MAX=200" '' '' 1 | cut -d: -f1,3)" "3:backpressure"
check "...but never refuses an interactive one" \
      "$(pfd "CLAUDE_PICK_PROC_ROOT='$PROCR' CLAUDE_PICK_LOAD_MAX=200" '' '' 0 | cut -d: -f1,2)" "0:a1"
check "--force overrides the ceiling and records that it did" \
      "$(zsh -f -c "
          unset CLAUDE_CONFIG_DIR HERDR_PANE_ID
          export HOME='$FHOME'
          CLAUDE_ACCOUNT_DIRS_ROOT='$FHOME/.local/state/claude-account-dirs'
          CLAUDE_PICK_PROC_ROOT='$PROCR' CLAUDE_PICK_LOAD_MAX=200
          CLAUDE_TENANTS_FILE=/nonexistent
          source '$HERDRRC' >/dev/null 2>&1
          _claude_pick_for_dir '' '' 1 1; rc=\$?
          print -r -- \"\$rc:\$(print -l \"\$_claude_pick_warnings[@]\" | grep -c -- '--force')\"" 2>/dev/null)" \
      "0:1"
PROCR=""

# No profiles at all, and an unusable table: different exits because they are
# different fixes — one is `clauth login`, the other is an edit to a data file.
new_home fd7
check "no registered profile with a credential is exit 5" \
      "$(pfd '' '' '' 0 | cut -d: -f1,3)" "5:no-profiles"

new_home fd8
mkprof a1 '{"five_hour":{"utilization":10.0}}'
check "a tenant with no pool entry is exit 4, never a widened pool" \
      "$(pfd '' '' 'nosuchtenant' 0 | cut -d: -f1,3)" "4:bad-table"

# --dry-run leaves the ledger alone, and the second half of the pair is what
# makes the first mean anything: "no file" is also what a broken write produces.
new_home fd9
mkprof a1 '{"five_hour":{"utilization":10.0}}'
pfd 'typeset -g _claude_pick_dry_run=1' '' '' 0 >/dev/null
if [[ -e "$FHOME/.local/state/claude-account-dirs/.pick-ledger" ]]; then r=written; else r=absent; fi
check "a dry-run pick writes no ledger" "$r" "absent"
pfd '' '' '' 0 >/dev/null
if [[ -e "$FHOME/.local/state/claude-account-dirs/.pick-ledger" ]]; then r=written; else r=absent; fi
check "...and a real one does" "$r" "written"

#-----------------------------------------------------------------------------
echo
echo "=== scripts/claude-pick: the exit codes ARE the contract ==="
#
# The CLI decides nothing of its own — it serialises _claude_pick_for_dir — so
# these rows are about the mapping and the output shape. A caller acts on the
# code: 2 means wait, 3 means the box is full, 4 means fix a file, 5 means log
# in, 64 means the call was wrong. Collapsing any two of those into one costs the
# caller its only way to tell them apart.
#
# `cli` sets CLI_OUT / CLI_ERR / CLI_RC as GLOBALS and is called directly, never
# inside `$( )`: a command substitution is a subshell, so an exit code assigned
# in there dies with it — and reading a stale CLI_RC would make a row about exit
# 64 pass while measuring the previous row's exit 0.

PICK="$DOTFILES/scripts/claude-pick"
JQBIN="$(command -v jq)"
CLIPATH="$(dirname "$JQBIN"):/usr/bin:/bin"
[[ -x "$PICK" ]] || fatal "$PICK is not executable"

# AN ACCOUNT-DIR BUILDER STUB, and it is what makes the --dry-run row mean
# anything. Without DOTFILES_ROOT the CLI resolves the builder to
# $HOME/.dotfiles/scripts/claude-account-dirs.sh, which does not exist in a
# fixture HOME — so config_dir came back null on the non-dry-run path too, and a
# mutant that built the dir regardless of --dry-run survived. The real builder
# reconciles a live credential; a stub is the only correct thing to point at.
CLIDOT="$TMPROOT/clidot"; mkdir -p "$CLIDOT/scripts"
cat > "$CLIDOT/scripts/claude-account-dirs.sh" <<'STUB'
#!/bin/sh
printf '%s' "/fixture/account-dirs/$1"
STUB
chmod +x "$CLIDOT/scripts/claude-account-dirs.sh"

CLI_OUT=""; CLI_ERR=""; CLI_RC=0; CLI_ENV=""; PROCR=""
cli() {   # $@ = claude-pick args; sets CLI_OUT, CLI_ERR, CLI_RC
    # TZ is passed explicitly through `env -i`: the RFC 3339 rows below are
    # unfailable on a UTC machine, and CI runners are UTC. See FIXTZ above.
    env -i HOME="$FHOME" PATH="$CLIPATH" TZ="$FIXTZ" DOTFILES_ROOT="$CLIDOT" \
        CLAUDE_ACCOUNT_DIRS_ROOT="$FHOME/.local/state/claude-account-dirs" \
        CLAUDE_TENANTS_FILE=/nonexistent \
        ${PROCR:+CLAUDE_PICK_PROC_ROOT="$PROCR"} \
        ${CLI_ENV:+"$CLI_ENV"} \
        zsh "$PICK" "$@" >"$TMPROOT/cli.out" 2>"$TMPROOT/cli.err"
    CLI_RC=$?
    CLI_OUT="$(cat "$TMPROOT/cli.out")"
    CLI_ERR="$(cat "$TMPROOT/cli.err")"
}

new_home cli1
mkprof a1 '{"plan":{"tier":"Team"},"five_hour":{"utilization":10.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":40.0}}'
mkprof b2 '{"plan":{"tier":"Team"},"five_hour":{"utilization":60.0},"seven_day":{"utilization":40.0}}'

cli --dry-run
check "a plain run prints the profile and nothing else"  "$CLI_OUT"  "a1"
check "...with exit 0"                                   "$CLI_RC"   "0"
check "...and stderr stays empty"                        "$CLI_ERR"  ""

cli --nope
check "an unknown option is exit 64, not a refusal"      "$CLI_RC"   "64"
check "...and the usage error names the option"          "$(printf '%s' "$CLI_ERR" | head -1)" \
      "claude-pick: unknown option: --nope"
check "...printing nothing on stdout"                    "$CLI_OUT"  ""
cli --tenant ''
check "--tenant with an empty value is exit 64"          "$CLI_RC"   "64"
cli --help
check "--help is exit 0 and touches no account"          "$CLI_RC"   "0"

# --json: the shape herdr-draft consumes (§5.6).
cli --dry-run --json
check "--json is one valid object"                       "$(printf '%s' "$CLI_OUT" | jq -e 'type' 2>/dev/null)" '"object"'
check "...naming the profile"                            "$(printf '%s' "$CLI_OUT" | jq -r .profile)" "a1"
check "...with config_dir null under --dry-run"          "$(printf '%s' "$CLI_OUT" | jq -r '.config_dir // "null"')" "null"
# The other half of the pair, and without it the row above is satisfied by a CLI
# that can never build a dir at all: `null` is also what a broken builder gives.
cli --json
check "...and a REAL run reports the dir it built"      "$(printf '%s' "$CLI_OUT" | jq -r '.config_dir // "null"')" "/fixture/account-dirs/a1"
cli --dry-run --json
check "...the usage figures as numbers"                  "$(printf '%s' "$CLI_OUT" | jq -r '"\(.usage.five_hour)/\(.usage.weekly)"')" "10/40"
check "...resets_at.five_hour in RFC 3339 UTC"           "$(printf '%s' "$CLI_OUT" | jq -r .resets_at.five_hour)" "2099-01-01T00:00:00Z"
check "...an absent weekly reset as null, never an epoch date" \
      "$(printf '%s' "$CLI_OUT" | jq -r '.resets_at.weekly // "null"')" "null"
check "...every non-chosen candidate in skipped, structured" \
      "$(printf '%s' "$CLI_OUT" | jq -r '.skipped | map(.profile) | join(",")')" "b2"
check "...and the machine reading it decided on"         "$(printf '%s' "$CLI_OUT" | jq -r '.machine | has("load1")')" "true"

# An UNKNOWN figure must be null, never 0: that distinction is the whole point of
# the metrics layer, and this is the last place it can be thrown away.
new_home cli2
mkprof a1 '-'
cli --dry-run --json
check "an unreadable usage figure serialises as null, not 0" \
      "$(printf '%s' "$CLI_OUT" | jq -r '.usage.five_hour // "null"')" "null"
check "...and the class says why it was chosen anyway"    "$(printf '%s' "$CLI_OUT" | jq -r .class)" "unknown"

# The refusals.
new_home cli3
mkprof a1 '{"five_hour":{"utilization":99.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"}}'
cli --strict --dry-run
check "--strict on an exhausted pool is exit 2"          "$CLI_RC"   "2"
check "...and stderr carries the reason, for --on-failure" \
      "$(printf '%s' "$CLI_ERR" | grep -c 'refused')" "1"
check "...with nothing on stdout to mistake for a name"  "$CLI_OUT"  ""
cli --dry-run
check "...while without --strict it proceeds, exit 0"    "$CLI_RC"   "0"
cli --strict --dry-run --json
check "--strict --json still emits an object on the refusal" \
      "$(printf '%s' "$CLI_OUT" | jq -r '.state')" "exhausted"
check "...whose profile is null, not a name it did not choose" \
      "$(printf '%s' "$CLI_OUT" | jq -r '.profile // "null"')" "null"
check "...and whose exit_code matches the process's"     "$(printf '%s' "$CLI_OUT" | jq -r .exit_code)" "$CLI_RC"

new_home cli4
cli --dry-run
check "no registered profile is exit 5"                  "$CLI_RC"   "5"

new_home cli5
mkprof a1 '{"five_hour":{"utilization":10.0}}'
cli --dry-run --tenant nosuchtenant
check "an unusable tenant is exit 4"                     "$CLI_RC"   "4"
cli --dry-run --profile nope
check "--profile naming an unregistered account is exit 5" "$CLI_RC" "5"
cli --dry-run --profile a1 --json
check "--profile naming a registered one pins it, class pinned" \
      "$(printf '%s' "$CLI_OUT" | jq -r '"\(.profile)/\(.class)"')" "a1/pinned"

# A PIN NEVER REFUSES ON THE ACCOUNT — overriding the ranking is what --profile is
# for — but it must say when the seat it was handed is spent, because "it started
# and died twenty minutes in" is the outcome that warning prevents.
new_home cli5b
mkprof a1 '{"five_hour":{"utilization":99.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"}}'
cli --dry-run --profile a1
check "pinning a spent account still succeeds"           "$CLI_RC"   "0"
check "...and names it on stdout regardless"             "$CLI_OUT"  "a1"
check "...but says on stderr that it is exhausted"       "$(printf '%s' "$CLI_ERR" | grep -c "'a1' is exhausted")" "1"
cli --dry-run --profile a1 --json
check "...and records it in warnings, for a JSON caller" \
      "$(printf '%s' "$CLI_OUT" | jq -r '[.warnings[] | select(test("exhausted"))] | length')" "1"
# THE PINNED PATH BUILDS ITS OWN EXPLAIN ROW and never goes through
# _claude_pick_publish, so it is a second place the reset can be dropped — and
# dropping it there is invisible to every row above, which all take the ranked
# path. A pin is exactly when a caller most wants this field: it has been handed
# a spent seat and is deciding whether to wait.
check "...and a PINNED account still reports its reset instant" \
      "$(printf '%s' "$CLI_OUT" | jq -r .resets_at.five_hour)" "2099-01-01T00:00:00Z"

# A quarantined account is the sharper case: clauth has said the credential does
# not work, and a pin overrides that too — so the line has to be there.
new_home cli5c
mkprof a1 '{"five_hour":{"utilization":10.0}}'
printf 'active_profile = "a1"\nauth_broken = [\n  "a1",\n]\n' > "$FHOME/.clauth/profiles.toml"
cli --dry-run --profile a1
check "pinning a QUARANTINED account warns rather than refusing" \
      "$(printf '%s' "$CLI_ERR" | grep -c "'a1' is excluded")" "1"
check "...and still exits 0, because the pin is the override" "$CLI_RC" "0"

# A FRESH FIXTURE, because the rows above leave a1 quarantined — and then a
# machine-ceiling row measures exit 2 (nothing usable) instead of exit 3, or
# passes for the wrong reason. A fixture that carries state forward from the
# previous row is the same class of fault as a ledger that does.
new_home cli5d
mkprof a1 '{"five_hour":{"utilization":10.0}}'
mkproc 24.00 0-7 8000000 4000000
CLI_ENV='CLAUDE_PICK_LOAD_MAX=200'
cli --strict --dry-run
check "a machine ceiling refuses a strict CLI with exit 3" "$CLI_RC" "3"
# EVERY refusal reports a null profile, not only the ones _claude_pick_for_dir
# handles: a JSON object naming an account beside a non-zero exit is one a caller
# can act on by mistake. The pinned path had to be taught this separately, since
# it sets REPLY before the machine is ever measured.
cli --strict --dry-run --profile a1 --json
check "...and a PINNED refusal reports no profile either" \
      "$(printf '%s' "$CLI_OUT" | jq -r '"\(.state)/\(.profile // "null")"')" "backpressure/null"
cli --strict --force --dry-run
check "...and --force gets past it"                      "$CLI_RC"   "0"
CLI_ENV=""; PROCR=""

# --explain is stderr, so it can never corrupt the one line a caller reads.
new_home cli6
mkprof a1 '{"five_hour":{"utilization":10.0}}'
mkprof b2 '{"five_hour":{"utilization":99.0}}'
cli --dry-run --explain
check "--explain leaves stdout as the bare profile name" "$CLI_OUT"  "a1"
check "...and puts a row per candidate on stderr"        "$(printf '%s' "$CLI_ERR" | grep -cE '^  (a1|b2) ')" "2"
# ANCHORED TO THE TABLE ROW, because the bare word was not unique to the rule:
# --explain echoes the directory it was asked about, so any checkout whose path
# contains "exhausted" counted twice. Measured -- this row failed in a worktree
# named for DO-609's own Linear branch,
# `zvi/do-609-stop-the-account-picker-preferring-an-exhausted-account`, and would
# have passed in CI, which is the least useful way round.
check "...naming each one's class"                       "$(printf '%s' "$CLI_ERR" | grep -cE '^  b2 +exhausted ')" "1"
check "...and what it picked"                            "$(printf '%s' "$CLI_ERR" | grep -c 'picked:  a1')" "1"

# THE TWO RENDERINGS OF AN UNMEASURED VALUE MUST DIFFER, and no row saw that
# until a mutant swapped one for the other and survived: every fixture above
# reads the real /proc, where both renderings agree. JSON says `null` so a
# consumer can tell "not measured" from a number; the report says `unknown`,
# which is the word every other unmeasured field in this repo uses. One renderer
# gives one of them the other's answer, and `load null on unknown threads` reads
# as a bug in the picker rather than as a machine it could not measure.
new_home cli7
mkprof a1 '{"five_hour":{"utilization":10.0}}'
PROCR="$TMPROOT/proc-none"; mkdir -p "$PROCR"
cli --dry-run --explain
check "an unmeasured machine reads 'unknown' in the report" \
      "$(printf '%s' "$CLI_ERR" | grep -c 'machine: load unknown on unknown threads, swap unknown$')" "1"
cli --dry-run --json
check "...and null in the JSON, never the word" \
      "$(printf '%s' "$CLI_OUT" | jq -r '.machine.load1 // "null"')" "null"
check "...for every machine field"       "$(printf '%s' "$CLI_OUT" | jq -r '[.machine[] | . == null] | all')" "true"
PROCR=""

# EVERY exit path reports the machine, including the two that give up before the
# accounts are even looked at. herdr-draft's failure row shows these numbers, and
# a refusal that cannot say what the machine was doing is the empty answer this
# repo keeps paying for. The measurement is taken first and the VERDICT deferred,
# so an unusable table still reports exit 4 rather than 3 — the fixable fault
# outranks the transient one.
# The fixture /proc is over the ceiling AND the tenant is unusable, both at once
# — which is what makes the precedence assertion mean anything. With a quiet
# machine, "exit 4, not 3" holds however the two are ordered, and a mutant that
# refuses on the machine first survives.
new_home cli8
mkprof a1 '{"five_hour":{"utilization":10.0}}'
mkproc 24.00 0-7 8000000 4000000
CLI_ENV='CLAUDE_PICK_LOAD_MAX=200'
cli --strict --dry-run --tenant nosuchtenant --json
check "an exit-4 refusal still reports the machine it measured" \
      "$(printf '%s' "$CLI_OUT" | jq -r '.machine.ncpu != null')" "true"
check "...and an unusable table outranks a machine ceiling: exit 4, not 3" \
      "$CLI_RC"   "4"
new_home cli9
cli --strict --dry-run --json
check "an exit-5 refusal reports the machine too" \
      "$(printf '%s' "$CLI_OUT" | jq -r '.machine.ncpu != null')" "true"
check "...and no credential outranks the ceiling too: exit 5, not 3" \
      "$CLI_RC"   "5"
CLI_ENV=""; PROCR=""

check "the CLI does not source system.sh" \
      "$(grep -c 'functions/system.sh' "$PICK")" "0"

# DO-621: a pick that will bill usage credits says so. claude() prints every
# _claude_pick_warnings entry on an interactive launch (zshrc.herdr), so this is
# the channel an interactive user actually sees.
new_home bill1
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 86400)\"},\"spend\":{\"enabled\":true,\"used\":10.0,\"limit\":250.0}}"
cli --dry-run --json
check "--json reports the chosen seat's spend state"          "$(jq -r .usage.spend <<<"$CLI_OUT")" "headroom"
check "a billing pick carries the billing warning" \
      "$(jq -r '[.warnings[] | select(contains("usage bills credits"))] | length' <<<"$CLI_OUT")" "1"
# shellcheck disable=SC2016  # the literal $ amounts are the expected value, not an expansion
check "...naming the amounts" \
      "$(jq -r '.warnings[] | select(contains("usage bills credits"))' <<<"$CLI_OUT" | grep -c '\$10 of \$250')" "1"

new_home bill2
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":20.0,\"resets_at\":\"$(iso_in 86400)\"},\"spend\":{\"enabled\":true,\"used\":10.0,\"limit\":250.0}}"
cli --dry-run --json
check "an eligible pick carries no billing warning" \
      "$(jq -r '[.warnings[] | select(contains("bills credits"))] | length' <<<"$CLI_OUT")" "0"

# DO-621 review finding: no row covered the `_CPM_SPEND == unknown` wording
# branch. `spend.enabled:false` would give `_CPM_SPEND=none`, which the
# exhausted check (_claude_pick_class) claims first, so it never reaches the
# weekly-spent tier at all -- omitting the spend block entirely is what lands
# on `unknown` AND weekly-spent together. The needle is "spend headroom
# unknown", which the headroom branch's "usage bills credits (...)" text never
# contains.
new_home bill3
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 86400)\"}}"
cli --dry-run --json
check "an unknown-spend weekly-spent pick warns with the UNKNOWN wording, never the headroom one" \
      "$(jq -r '[.warnings[] | select(contains("spend headroom unknown"))] | length' <<<"$CLI_OUT")" "1"

#-----------------------------------------------------------------------------
echo
echo "=== canary: nothing the picker READS reaches either stream ==="
#
# A diagnostic that prints a credential is worse than no diagnostic. The picker
# reads four clauth files plus status.json and its own ledger; a token-shaped
# string and an `api_key = "..."` line are planted in every one of them, and no
# exit path may echo either.
#
# The one field deliberately derived from a cache is the plan TIER, so the canary
# is planted under keys the picker does not read rather than in that field —
# asserting the tier is not printed would be asserting against the spec. A row
# below checks the tier DID come out, so "clean" cannot be satisfied by a run
# that read nothing at all.
#
# The tenant file is deliberately NOT canaried, and that is a decision rather
# than an omission. Its entries are QUOTED BY DESIGN in the bad-table message
# (_CLAUDE_TENANT_WHY names the offending entry, which is the entire job of that
# diagnostic), so a canary there would be a row against a feature. It is also the
# one file in the set that holds no credential: it is routing data, and this
# repo's Security Rules send every secret to ~/.zshrc.local instead.

# Assembled at runtime, so this file contains no string that would trip the
# gitleaks pre-commit hook over its own test data.
CANARY="gho_$(printf '%s' 'AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIII')"
CANARY_VAL="$(printf '%s' 'deadbeefcafef00dfeedfacedecafbad0badc0de')"
CANARY2="api_key = \"$CANARY_VAL\""

plant() {
    local d="$FHOME/.clauth" prof
    mkdir -p "$d/live_sessions"
    # Valid JSON throughout: an invalid cache takes a path that reads nothing,
    # and the rows would then pass because nothing was read.
    for prof in "$d"/profiles/*/; do
        [[ -d "$prof" ]] || continue
        if [[ -r "$prof/usage_cache.json" ]]; then
            jq --arg c "$CANARY" '. + {canary: $c}' "$prof/usage_cache.json" \
               > "$prof/usage_cache.json.new" \
               && mv "$prof/usage_cache.json.new" "$prof/usage_cache.json"
        fi
        printf 'disabled = false\n%s\n' "$CANARY2" > "$prof/config.toml"
    done
    printf 'active_profile = "a1"\nauth_broken = []\n%s\n' "$CANARY2" > "$d/profiles.toml"
    printf '{"active_profile":"a1","canary":"%s"}\n' "$CANARY" > "$d/status.json"
    printf '{"current_member":"a1","pid":1,"canary":"%s"}\n' "$CANARY" > "$d/live_sessions/s.json"
    mkdir -p "$FHOME/.local/state/claude-account-dirs"
    printf 'a1\t1\n%s\n' "$CANARY" > "$FHOME/.local/state/claude-account-dirs/.pick-ledger"
}

canary_run() {   # $@ = claude-pick args -> "clean" or "LEAKED"
    local both
    both="$(env -i HOME="$FHOME" PATH="$CLIPATH" TZ="$FIXTZ" \
              CLAUDE_ACCOUNT_DIRS_ROOT="$FHOME/.local/state/claude-account-dirs" \
              CLAUDE_TENANTS_FILE=/nonexistent \
              ${PROCR:+CLAUDE_PICK_PROC_ROOT="$PROCR"} \
              ${CLI_ENV:+"$CLI_ENV"} \
              zsh "$PICK" "$@" 2>&1)"
    if printf '%s' "$both" | grep -qF -e "$CANARY" -e "$CANARY_VAL"; then
        printf 'LEAKED'
    else
        printf 'clean'
    fi
}

# Exit 0 — an ordinary pick, plain, JSON, explained and pinned.
new_home can1
mkprof a1 '{"plan":{"tier":"Team"},"five_hour":{"utilization":10.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"},"seven_day":{"utilization":40.0}}'
mkprof b2 '{"plan":{"tier":"Team"},"five_hour":{"utilization":60.0},"seven_day":{"utilization":40.0}}'
plant
check "exit 0, plain"                 "$(canary_run --dry-run)"                     "clean"
check "exit 0, --json"                "$(canary_run --dry-run --json)"              "clean"
check "exit 0, --explain"             "$(canary_run --dry-run --explain)"           "clean"
check "exit 0, --profile pinned"      "$(canary_run --dry-run --profile a1 --json)" "clean"
# ...and the run really did read the planted files, or every row above is
# satisfied by a picker that read nothing at all.
cli --dry-run --json
check "...and the planted cache WAS read (the tier came out of it)" \
      "$(printf '%s' "$CLI_OUT" | jq -r .tier)" "Team"

# Exit 2 — refused, exhausted. The loudest path: a line per member, built out of
# the same files.
new_home can2
mkprof a1 '{"plan":{"tier":"Team"},"five_hour":{"utilization":99.0,"resets_at":"2099-01-01T00:00:00.000000+00:00"}}'
mkprof b2 '{"plan":{"tier":"Team"},"five_hour":{"utilization":98.0}}'
plant
check "exit 2, refused strict"        "$(canary_run --strict --dry-run)"            "clean"
check "exit 2, refused with --json"   "$(canary_run --strict --dry-run --json)"     "clean"
check "exit 0, least-bad interactive" "$(canary_run --dry-run --explain)"           "clean"

# Exit 3 — a machine ceiling.
mkproc 24.00 0-7 8000000 4000000
CLI_ENV='CLAUDE_PICK_LOAD_MAX=200'
check "exit 3, machine ceiling"       "$(canary_run --strict --dry-run)"            "clean"
CLI_ENV=""; PROCR=""

# Exit 4 — an unusable tenant. That message quotes the TENANT, which is caller
# input, not file content.
check "exit 4, unusable tenant"       "$(canary_run --dry-run --tenant nosuchtenant)" "clean"
check "exit 4, with --explain"        "$(canary_run --dry-run --tenant nosuchtenant --explain)" "clean"

# Exit 5 — nothing registered, with the other files still there to be read.
new_home can3
plant
check "exit 5, no profiles"           "$(canary_run --dry-run)"                     "clean"

# Exit 64 — a usage error, which prints the usage text.
check "exit 64, usage error"          "$(canary_run --nope)"                        "clean"

# A quarantined account is the one case where a profiles.toml SPAN is matched and
# a reason is printed out of it, so it gets its own row.
new_home can4
mkprof a1 '{"plan":{"tier":"Team"},"five_hour":{"utilization":10.0}}'
mkprof b2 '{"plan":{"tier":"Team"},"five_hour":{"utilization":10.0}}'
plant
printf 'active_profile = "b2"\nauth_broken = [\n  "a1",\n]\n%s\n' "$CANARY2" \
    > "$FHOME/.clauth/profiles.toml"
check "a quarantine reason printed out of profiles.toml carries nothing else" \
      "$(canary_run --dry-run --explain)" "clean"
cli --dry-run
check "...and the quarantined account really was excluded" "$CLI_OUT" "b2"

# --- gate rows (WS4' Task 0) --------------------------------------------------
# `claude-pick --gate --model M --effort E [--est-minutes N]` refuses (exit 2)
# when the picked seat's PROJECTED end-utilisation — u5 now + rate(model,
# effort) × minutes / 60 — exceeds CLAUDE_PICK_GATE_MAX (95). The rate is
# CLAUDE_PICK_RATES["<model>:<effort>"] from ~/.config/claude-tenants.zsh, else
# CLAUDE_PICK_RATE_DEFAULT (115, the worst rate measured 2026-09-16). An
# unmeasured window refuses too: "unknown" must never read as room. Every
# refusal has a state a caller can switch on and a null profile.
new_home gate
H="$FHOME"
# The fixture's 5h reset is the same far-future literal every other section
# uses (2099), NOT a date near the day the rows were written: the first version
# said 2026-09-16T20:00:00Z, which was already in the past by the time the gate
# learned to read it — a fixture describing a rolled window while every row
# treated it as live. Past is the matching far-past literal (2000). A fourth
# argument overrides the instant; `-` omits the key altogether, which is how
# clauth writes a window that has not started.
GATE_FUTURE='2099-01-01T00:00:00Z'
GATE_PAST='2000-01-01T00:00:00Z'
gate_profile() {   # gate_profile NAME U5 [AGE_S] [RESETS_AT|-]  → a registered fixture profile at U5 % of its
                   # 5h window, whose usage_cache.json was written AGE_S seconds ago (default: just now)
                   # and whose five_hour.resets_at is RESETS_AT (default GATE_FUTURE; `-` = no key)
  local r="${4:-$GATE_FUTURE}" fh
  if [[ "$r" == - ]]; then fh="{\"utilization\":$2}"; else fh="{\"utilization\":$2,\"resets_at\":\"$r\"}"; fi
  mkdir -p "$H/.clauth/profiles/$1"
  : > "$H/.clauth/profiles/$1/credentials.json"
  printf '{"five_hour":%s,"seven_day":{"utilization":10,"resets_at":"2099-01-06T00:00:00Z"},"plan":{"tier":"Team"}}\n' "$fh" \
    > "$H/.clauth/profiles/$1/usage_cache.json"
  if [[ -n "${3:-}" ]]; then
    touch -d "$3 seconds ago" "$H/.clauth/profiles/$1/usage_cache.json"
  fi
}
gate_run() {       # gate_run PROFILE [extra args]  → $out (JSON) and $rc, Fable-high, 30 min, dry-run
  local p="$1"; shift
  out="$(unset CLAUDE_CONFIG_DIR HERDR_PANE_ID; HOME="$H" CLAUDE_TENANTS_FILE=/nonexistent \
          zsh "$DOTFILES/scripts/claude-pick" --profile "$p" --dry-run --json \
          --gate --model claude-fable-5-1 --effort high --est-minutes 30 "$@" 2>/dev/null)"; rc=$?
}
has_words() {      # has_words TEXT WORD...  → yes when TEXT contains every WORD
  local t="$1" w; shift
  for w in "$@"; do [[ "$t" == *"$w"* ]] || { echo no; return 0; }; done
  echo yes
}
gate_profile g1 40
out="$(unset CLAUDE_CONFIG_DIR HERDR_PANE_ID; HOME="$H" zsh "$DOTFILES/scripts/claude-pick" --profile g1 --dry-run --json \
        --gate --model claude-fable-5-1 --effort high --est-minutes 30 2>/dev/null)"; rc=$?
check "gate: 40% + 115×0.5h = 97 refuses" "$rc" "2"
check "gate: state names the projection"  "$(jq -r .state <<<"$out")" "gate-projected"
check "gate: projected is 97"             "$(jq -r .gate.projected <<<"$out")" "97"
check "gate: profile is null on refusal"  "$(jq -r .profile <<<"$out")" "null"
gate_profile g2 30
out="$(unset CLAUDE_CONFIG_DIR HERDR_PANE_ID; HOME="$H" zsh "$DOTFILES/scripts/claude-pick" --profile g2 --dry-run --json \
        --gate --model claude-fable-5-1 --effort high --est-minutes 30 2>/dev/null)"; rc=$?
check "gate: 30% projects to 87 and allows" "$rc" "0"
check "gate: verdict allow"                  "$(jq -r .gate.verdict <<<"$out")" "allow"
gate_profile g3 50
# CLAUDE_PICK_RATES_OVERRIDE is deliberately IGNORED by the implementation — the
# rate table is the zsh associative array from claude-tenants.zsh, not an env
# string — so this row proves an unlisted model:effort pair falls back to 115.
out="$(unset CLAUDE_CONFIG_DIR HERDR_PANE_ID; HOME="$H" CLAUDE_PICK_RATES_OVERRIDE='claude-sonnet-5:medium=20' \
        zsh "$DOTFILES/scripts/claude-pick" --profile g3 --dry-run --json --gate --model claude-sonnet-5 --effort medium 2>/dev/null)"; rc=$?
check "gate: an unlisted model/effort uses the default rate 115 (50+57=107 refuses)" "$rc" "2"
mkdir -p "$H/.clauth/profiles/g4"; : > "$H/.clauth/profiles/g4/credentials.json"   # registered, no usage cache
out="$(unset CLAUDE_CONFIG_DIR HERDR_PANE_ID; HOME="$H" zsh "$DOTFILES/scripts/claude-pick" --profile g4 --dry-run --json --gate --model x --effort y 2>/dev/null)"; rc=$?
check "gate: unmeasured window refuses"  "$rc" "2"
check "gate: state names unmeasured"     "$(jq -r .state <<<"$out")" "gate-unmeasured"
out="$(unset CLAUDE_CONFIG_DIR HERDR_PANE_ID; HOME="$H" zsh "$DOTFILES/scripts/claude-pick" --profile g2 --dry-run --json 2>/dev/null)"
check "no --gate: gate field is null"    "$(jq -r .gate <<<"$out")" "null"
check "...and the key is present, not absent" "$(jq -r 'has("gate")' <<<"$out")" "true"
HOME="$H" zsh "$DOTFILES/scripts/claude-pick" --gate --model a 2>/dev/null; check "gate without --effort is usage (64)" "$?" "64"
# The positive half of the rate table: a pair listed in claude-tenants.zsh is
# used instead of the default. Without this row a gate that ignored the array
# entirely would pass every row above.
mkdir -p "$H/.config"
printf 'typeset -gA CLAUDE_PICK_RATES\nCLAUDE_PICK_RATES[claude-sonnet-5:medium]=20\n' > "$H/.config/claude-tenants.zsh"
out="$(unset CLAUDE_CONFIG_DIR HERDR_PANE_ID; HOME="$H" zsh "$DOTFILES/scripts/claude-pick" --profile g3 --dry-run --json --gate --model claude-sonnet-5 --effort medium 2>/dev/null)"; rc=$?
check "gate: a rate listed in claude-tenants.zsh is used (50+20×0.5h=60 allows)" "$rc" "0"
check "gate: ...and the JSON reports that rate" "$(jq -r .gate.rate <<<"$out")" "20"
rm -f "$H/.config/claude-tenants.zsh"

# --- gate: a STALE reading is unmeasured (fix brief ws4p-fix, defect 1) -----
# The gate trusted whatever number usage_cache.json held, however old. A seat
# at 30% three hours ago can be at 100% now (F13: two profiles went 7% -> 100%
# in forty minutes), so a reading older than CLAUDE_PICK_CACHE_MAX_AGE (600 s
# for the gate) is UNMEASURED and refuses — design §4.2, an unmeasured dimension
# is a refusal, never a zero. Reproduced by the orchestrator: rc 0, allow,
# projected 87, from a 3-hour-old file.
gate_profile s30 30 10800
gate_run s30
check "gate: a 3h-old usage cache refuses"          "$rc" "2"
check "gate: ...as gate-unmeasured"                 "$(jq -r .state <<<"$out")" "gate-unmeasured"
# The age is asserted as a RANGE, and the reason is checked against the age the
# JSON itself reports: the fixture's mtime and the run are two clock reads, and a
# second boundary between them makes 10800 read 10801. A row that fails one run
# in N on main is worse than no row (CLAUDE.md, DO-612).
check "gate: ...naming the age and the threshold"   "$(has_words "$(jq -r .reason <<<"$out")" "$(jq -r .gate.cache_age_s <<<"$out")s" 600 CLAUDE_PICK_CACHE_MAX_AGE)" "yes"
check "gate: ...with a null profile"                "$(jq -r .profile <<<"$out")" "null"
check "gate: ...and the gate object carries the age it decided on" "$(jq -r '.gate.cache_age_s | . >= 10800 and . <= 10810' <<<"$out")" "true"
check "gate: ...and the threshold it applied"       "$(jq -r .gate.cache_max_age_s <<<"$out")" "600"
check "gate: ...and no verdict allow anywhere"      "$(jq -r .gate.verdict <<<"$out")" "refuse"
gate_profile s30f 30
gate_run s30f
check "gate: the same seat with a fresh cache allows"        "$rc" "0"
check "gate: ...and cache_age_s is a NUMBER on an allow too" "$(jq -r '.gate.cache_age_s | type' <<<"$out")" "number"
check "gate: ...usage.cache_age_s agrees"                    "$(jq -r '.usage.cache_age_s | type' <<<"$out")" "number"
# The knob is read, in both directions: a wider one admits the 3h-old reading, a
# narrower one refuses a 5-minute-old one that the default would have allowed.
CLAUDE_PICK_CACHE_MAX_AGE=20000 gate_run s30
check "gate: CLAUDE_PICK_CACHE_MAX_AGE=20000 admits the 3h-old reading" "$rc" "0"
check "gate: ...and the JSON reports the threshold used"              "$(jq -r .gate.cache_max_age_s <<<"$out")" "20000"
gate_profile s30m 30 300
CLAUDE_PICK_CACHE_MAX_AGE=100 gate_run s30m
check "gate: CLAUDE_PICK_CACHE_MAX_AGE=100 refuses a 300s-old reading" "$rc" "2"
check "gate: ...as gate-unmeasured"                                    "$(jq -r .state <<<"$out")" "gate-unmeasured"
gate_run s30m
check "gate: ...which the default 600 admits" "$rc" "0"
# THE RANKED PATH FAILS THE SAME WAY and must be covered by the same check: a
# 1000s-old reading is `eligible` to the ranker (its threshold is 3600, and
# stays there — see zshrc.herdr) but stale to the gate.
SAVED_H="$H"; new_home gate-ranked; H="$FHOME"
gate_profile r1 30 1000
out="$(unset CLAUDE_CONFIG_DIR HERDR_PANE_ID; HOME="$H" CLAUDE_TENANTS_FILE=/nonexistent zsh "$DOTFILES/scripts/claude-pick" --dir "$H" --dry-run --json \
        --gate --model claude-fable-5-1 --effort high 2>/dev/null)"; rc=$?
# On a refusal the picked row is reported under `skipped` (REPLY is cleared), so
# the ranker's own classification of it is readable there: `eligible`, not
# `unknown` — the ranker admitted what the gate refused.
check "gate (ranked path): a 1000s-old reading is ELIGIBLE to the ranker..." "$(jq -r '.skipped[0].class' <<<"$out")" "eligible"
check "gate (ranked path): ...and refused by the gate"                    "$rc" "2"
check "gate (ranked path): ...as gate-unmeasured"                         "$(jq -r .state <<<"$out")" "gate-unmeasured"
check "gate (ranked path): ...with the age in the gate object"            "$(jq -r '.gate.cache_age_s | . >= 1000 and . <= 1010' <<<"$out")" "true"
H="$SAVED_H"

# --- gate: a tuning value that does not parse REFUSES (defect 2) ------------
# Reproduced by the review gate at a 90% seat: RATE_DEFAULT=abc allowed with
# projected 90 (the rate parsed as 0), RATE_DEFAULT=-100 allowed with projected
# 40 (a negative rate SUBTRACTS), GATE_MAX=1x printed an unparseable object and
# no refusal. Every one is an operator's typo hiding behind an allow. Now: exit
# 2, state gate-misconfigured, a reason naming the variable and the value it
# got — never a silent 0, and never a fallback to the default, which would hide
# the typo. THE FIXTURES ARE CHOSEN SO THAT A FALLBACK WOULD ALLOW: v10 with the
# default rate projects to 67, v30 with the default cap is 87 < 95. A row at
# 90% would refuse as gate-projected under a fallback and pin nothing.
gate_profile v10 10
gate_profile v30 30
CLAUDE_PICK_RATE_DEFAULT=abc gate_run v10
check "gate: CLAUDE_PICK_RATE_DEFAULT=abc refuses"        "$rc" "2"
check "gate: ...as gate-misconfigured, not a projection"  "$(jq -r .state <<<"$out")" "gate-misconfigured"
check "gate: ...naming the variable and the value"        "$(has_words "$(jq -r .reason <<<"$out")" CLAUDE_PICK_RATE_DEFAULT abc)" "yes"
check "gate: ...with a null profile"                      "$(jq -r .profile <<<"$out")" "null"
check "gate: ...verdict refuse"                           "$(jq -r .gate.verdict <<<"$out")" "refuse"
check "gate: ...and no rate is reported as measured"      "$(jq -r .gate.rate <<<"$out")" "null"
CLAUDE_PICK_RATE_DEFAULT=-100 gate_run v10
check "gate: a NEGATIVE default rate refuses"             "$rc" "2"
check "gate: ...as gate-misconfigured"                    "$(jq -r .state <<<"$out")" "gate-misconfigured"
check "gate: ...naming -100"                              "$(has_words "$(jq -r .reason <<<"$out")" CLAUDE_PICK_RATE_DEFAULT -100)" "yes"
CLAUDE_PICK_RATE_DEFAULT=0 gate_run v10
check "gate: a ZERO default rate refuses (must be > 0)"   "$rc" "2"
check "gate: ...as gate-misconfigured"                    "$(jq -r .state <<<"$out")" "gate-misconfigured"
CLAUDE_PICK_GATE_MAX=1x gate_run v30
check "gate: CLAUDE_PICK_GATE_MAX=1x refuses"             "$rc" "2"
check "gate: ...as gate-misconfigured"                    "$(jq -r .state <<<"$out")" "gate-misconfigured"
check "gate: ...and the output is still ONE valid JSON object" "$(jq -e . <<<"$out" >/dev/null 2>&1; echo $?)" "0"
check "gate: ...naming the variable and the value"        "$(has_words "$(jq -r .reason <<<"$out")" CLAUDE_PICK_GATE_MAX 1x)" "yes"
check "gate: ...and max is null, not a guess"             "$(jq -r .gate.max <<<"$out")" "null"
CLAUDE_PICK_GATE_MAX=0 gate_run v30
check "gate: CLAUDE_PICK_GATE_MAX=0 refuses (must be > 0)" "$rc" "2"
check "gate: ...as gate-misconfigured"                    "$(jq -r .state <<<"$out")" "gate-misconfigured"
CLAUDE_PICK_GATE_MAX=150 gate_run v30
check "gate: a VALID CLAUDE_PICK_GATE_MAX is honoured"    "$rc" "0"
check "gate: ...and reported"                             "$(jq -r .gate.max <<<"$out")" "150"
CLAUDE_PICK_CACHE_MAX_AGE=abc gate_run v30
check "gate: CLAUDE_PICK_CACHE_MAX_AGE=abc refuses"       "$rc" "2"
check "gate: ...as gate-misconfigured"                    "$(jq -r .state <<<"$out")" "gate-misconfigured"
check "gate: ...naming the variable and the value"        "$(has_words "$(jq -r .reason <<<"$out")" CLAUDE_PICK_CACHE_MAX_AGE abc)" "yes"
# A rate table entry is validated the same way, and named by its KEY.
mkdir -p "$H/.config"
printf 'typeset -gA CLAUDE_PICK_RATES\nCLAUDE_PICK_RATES[claude-sonnet-5:medium]=fast\n' > "$H/.config/claude-tenants.zsh"
out="$(unset CLAUDE_CONFIG_DIR HERDR_PANE_ID; HOME="$H" zsh "$DOTFILES/scripts/claude-pick" --profile v10 --dry-run --json --gate --model claude-sonnet-5 --effort medium 2>/dev/null)"; rc=$?
check "gate: CLAUDE_PICK_RATES[claude-sonnet-5:medium]=fast refuses" "$rc" "2"
check "gate: ...as gate-misconfigured"                    "$(jq -r .state <<<"$out")" "gate-misconfigured"
check "gate: ...naming the entry and the value"           "$(has_words "$(jq -r .reason <<<"$out")" 'CLAUDE_PICK_RATES[claude-sonnet-5:medium]' fast)" "yes"
rm -f "$H/.config/claude-tenants.zsh"
# A zero-length lane is not a request: the same usage error a non-integer gets.
HOME="$H" zsh "$DOTFILES/scripts/claude-pick" --profile v10 --dry-run --gate --model a --effort b --est-minutes 0 2>/dev/null
check "gate: --est-minutes 0 is a usage error (64)"       "$?" "64"
HOME="$H" zsh "$DOTFILES/scripts/claude-pick" --profile v10 --dry-run --gate --model a --effort b --est-minutes=0 2>/dev/null
check "gate: ...in the --est-minutes=0 spelling too"      "$?" "64"

# --- gate: a window that has ROLLED is unmeasured (cleanup brief ws4p-cleanup, defect 2)
# The staleness test above reads only the file's mtime, so `touch` on a
# three-hour-old cache made a stale reading pass, and a five_hour.resets_at
# already in the past — the window has rolled, so the number describes a window
# that no longer exists — was ignored while the file was new. A real clauth
# write rewrites content and mtime together, which makes this low-risk, not
# absent, and this is a safety gate. A reset in the past is the same refusal
# the mtime one already makes — exit 2, gate-unmeasured — and an ABSENT or
# UNPARSEABLE reset refuses too: unmeasured, never optimistic. The parsed
# instant is reported in the gate object beside cache_age_s so the refusal can
# be read without guessing.
gate_profile rp 30 "" "$GATE_PAST"                       # fresh mtime, rolled window
gate_run rp
check "gate: a FRESH file whose 5h reset is in the past refuses" "$rc" "2"
check "gate: ...as gate-unmeasured"                              "$(jq -r .state <<<"$out")" "gate-unmeasured"
check "gate: ...naming the reset instant and that it has rolled" "$(has_words "$(jq -r .reason <<<"$out")" "$GATE_PAST" rolled)" "yes"
check "gate: ...profile is null on the refusal"                  "$(jq -r .profile <<<"$out")" "null"
check "gate: ...and the gate object reports the parsed resets_at" "$(jq -r .gate.resets_at <<<"$out")" "$GATE_PAST"
check "gate: ...beside cache_age_s"  "$(jq -r '.gate | has("resets_at") and has("cache_age_s") and (.cache_age_s|type == "number")' <<<"$out")" "true"
gate_profile rf 30 "" "$GATE_FUTURE"                     # the same fixture, window still open
gate_run rf
check "gate: the same fixture with a FUTURE reset allows"        "$rc" "0"
check "gate: ...verdict allow"                                   "$(jq -r .gate.verdict <<<"$out")" "allow"
check "gate: ...and reports the reset it allowed on"             "$(jq -r .gate.resets_at <<<"$out")" "$GATE_FUTURE"
gate_profile rn 30 "" -                                  # no resets_at key at all
gate_run rn
check "gate: a MISSING resets_at refuses rather than allows"     "$rc" "2"
check "gate: ...as gate-unmeasured"                              "$(jq -r .state <<<"$out")" "gate-unmeasured"
check "gate: ...and resets_at is null in the gate object"        "$(jq -r .gate.resets_at <<<"$out")" "null"
gate_profile ru 30 "" "not a timestamp"                  # unparseable
gate_run ru
check "gate: an UNPARSEABLE resets_at refuses rather than allows" "$rc" "2"
check "gate: ...as gate-unmeasured"                              "$(jq -r .state <<<"$out")" "gate-unmeasured"
check "gate: ...and resets_at is null, never an epoch"           "$(jq -r .gate.resets_at <<<"$out")" "null"
# The mtime test runs FIRST, so a file that is both stale and rolled is
# reported as stale — the message the rows above this section already pin.
gate_profile rb 30 10800 "$GATE_PAST"
gate_run rb
check "gate: stale AND rolled is reported as stale"              "$(has_words "$(jq -r .reason <<<"$out")" CLAUDE_PICK_CACHE_MAX_AGE)" "yes"
# A rolled window is not a projection: nothing is computed on a number the gate
# refused to trust, so `projected` is null.
gate_run rp
check "gate: a rolled window has no projection"                  "$(jq -r .gate.projected <<<"$out")" "null"

# DO-621: the gate reads the same age, so its 600 s threshold is now measured
# against fetched_at. A fresh mtime over a 700 s-old fetch used to pass.
mkdir -p "$H/.clauth/profiles/gf"; : > "$H/.clauth/profiles/gf/credentials.json"
printf '{"five_hour":{"utilization":10,"resets_at":"%s"},"seven_day":{"utilization":10,"resets_at":"2099-01-06T00:00:00Z"},"fetched_at":%s,"plan":{"tier":"Team"}}\n' \
    "$GATE_FUTURE" "$(( ($(date +%s) - 700) * 1000 ))" > "$H/.clauth/profiles/gf/usage_cache.json"
gate_run gf
check "gate: a fresh mtime over a 700 s-old fetch refuses"     "$rc" "2"
check "gate: ...as gate-unmeasured"                             "$(jq -r .state <<<"$out")" "gate-unmeasured"

#-----------------------------------------------------------------------------
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
