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

#-----------------------------------------------------------------------------
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
