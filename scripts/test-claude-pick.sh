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
new_home r3; rm -rf "$LED"; mkdir -p "$LED"
cat > "$TMPROOT/locktest.zsh" <<'EOS'
source "$HERDRRC_P" >/dev/null 2>&1
zmodload zsh/system
( zsystem flock -f hfd "$LED_P/.pick-ledger.lock"
  print ready > "$LED_P/held"
  sleep 8 ) &
for i in {1..100}; do [[ -f "$LED_P/held" ]] && break; sleep 0.1; done
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
          print -r -- \"\$REPLY|\$(_claude_pick_reset_text \$_CLAUDE_PICK_LEASTBAD_R5)\""
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

#-----------------------------------------------------------------------------
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
