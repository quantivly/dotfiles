#!/usr/bin/env bash
#
# scripts/test-buildlimits.sh — state table for zsh/zshrc.buildlimits
#
# HERMETIC. `nproc` is a STUB on a from-scratch PATH, never the real one: the
# whole point of this module is what it computes from the core count, and a
# suite that read the host's would assert a different thing on every machine
# and on CI. zsh runs with -f so no rc file of the developer's can reach it.
#
# PATH is the stub directory ALONE, and zsh is invoked by absolute path. With
# /usr/bin on it the "nproc missing" rows found the REAL nproc and measured this
# host — a fixture that cannot reach the branch it names. nproc is the only
# external command this module runs (verified: two call sites, nothing else).
#
# HERDR_PANE_ID is cleared and set explicitly per row. It is normally SET when
# this suite is run (from a herdr pane), and inheriting it would put every row
# in the agent tier — the leak scripts/test-hspawn.sh already records for
# CLAUDE_CONFIG_DIR, in the one variable this module keys on.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SUT="$ROOT/zsh/zshrc.buildlimits"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

[[ -r "$SUT" ]] || fatal "cannot read $SUT"
command -v zsh >/dev/null 2>&1 || fatal "zsh is required"
ZSH=$(command -v zsh)

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
BIN="$TMPROOT/bin"; FHOME="$TMPROOT/home"
mkdir -p "$BIN" "$FHOME"

# A core count the rows choose, rather than the host's.
set_cores() {
    if [[ "$1" == "none" ]]; then
        rm -f "$BIN/nproc"
    else
        printf '#!/bin/sh\necho %s\n' "$1" > "$BIN/nproc"
        chmod +x "$BIN/nproc"
    fi
}

# $1 cores ("none" removes nproc), $2 HERDR_PANE_ID (empty = interactive),
# $3 variable to print, $4.. extra VAR=VALUE assignments for the child.
limits() {
    local cores="$1" pane="$2" var="$3"; shift 3
    set_cores "$cores"
    env -i HOME="$FHOME" PATH="$BIN" HERDR_PANE_ID="$pane" "$@" \
        "$ZSH" -f -c "source '$SUT' >/dev/null 2>&1; print -r -- \${$var-<unset>}" 2>/dev/null
}

# The `build-limits` report, for the rows that assert what it SAYS.
report() {
    local cores="$1" pane="$2"; shift 2
    set_cores "$cores"
    env -i HOME="$FHOME" PATH="$BIN" HERDR_PANE_ID="$pane" "$@" \
        "$ZSH" -f -c "source '$SUT' >/dev/null 2>&1; build-limits" 2>/dev/null
}

echo
echo "=== zsh/zshrc.buildlimits state table ==="
echo

# --- The agent tier is the point of this change ------------------------------
# It was a hardcoded 2 regardless of hardware — correct for the 8-thread laptop
# this repo was written on, and far too tight on a 16-core box carrying two or
# three sessions, which is exactly where work is being moved to. cores/4 keeps
# the laptop at 2 (8/4) so nothing about the machine it was tuned for changes.
echo "-- agent tier (inside a herdr pane) --"
check "8 cores: still exactly 2 (the laptop is UNCHANGED)" \
      "$(limits 8 w1:p1 MAKEFLAGS)" "-j2"
check "16 cores: 4"   "$(limits 16 w1:p1 MAKEFLAGS)" "-j4"
check "64 cores: 16"  "$(limits 64 w1:p1 MAKEFLAGS)" "-j16"
check "4 cores: floored at 2"  "$(limits 4 w1:p1 MAKEFLAGS)"  "-j2"
check "1 core: floored at 2"   "$(limits 1 w1:p1 MAKEFLAGS)"  "-j2"

# --- The interactive tier must not move --------------------------------------
echo "-- interactive tier (no pane) --"
check "16 cores: half, 8"      "$(limits 16 '' MAKEFLAGS)" "-j8"
check "8 cores: half, 4"       "$(limits 8 '' MAKEFLAGS)"  "-j4"
check "2 cores: floored at 2"  "$(limits 2 '' MAKEFLAGS)"  "-j2"

# --- Every tool gets the same number -----------------------------------------
# One row per exported name, because a typo in any single export is invisible:
# the tool simply keeps its own default and nothing reports it.
echo "-- every tool tracks the tier --"
for v in VITEST_MAX_WORKERS NPM_CONFIG_JOBS CARGO_BUILD_JOBS \
         PYTEST_XDIST_AUTO_NUM_WORKERS UV_CONCURRENT_BUILDS UV_CONCURRENT_INSTALLS; do
    check "$v at 16 cores in a pane" "$(limits 16 w1:p1 "$v")" "4"
done
check "GOFLAGS carries -p"  "$(limits 16 w1:p1 GOFLAGS)"  "-p=4"
check "MAKEFLAGS carries -j" "$(limits 16 w1:p1 MAKEFLAGS)" "-j4"

# --- The override ------------------------------------------------------------
# A box whose shape you actually know (dev: 16 cores, two or three sessions)
# should be able to say so without editing a tracked file.
echo "-- BUILD_LIMITS_JOBS override --"
check "override wins in a pane"        "$(limits 16 w1:p1 MAKEFLAGS BUILD_LIMITS_JOBS=6)" "-j6"
check "override wins interactively"    "$(limits 16 ''    MAKEFLAGS BUILD_LIMITS_JOBS=6)" "-j6"
check "override reaches every tool"    "$(limits 16 w1:p1 VITEST_MAX_WORKERS BUILD_LIMITS_JOBS=6)" "6"

# An unusable override must leave the computed tier alone. Taking it literally
# would be worse than ignoring it: 0 disables parallelism entirely and a
# negative or non-numeric value lands as a malformed flag the tool rejects.
check "non-numeric override ignored"   "$(limits 16 w1:p1 MAKEFLAGS BUILD_LIMITS_JOBS=abc)" "-j4"
check "zero override ignored"          "$(limits 16 w1:p1 MAKEFLAGS BUILD_LIMITS_JOBS=0)"   "-j4"
check "negative override ignored"      "$(limits 16 w1:p1 MAKEFLAGS BUILD_LIMITS_JOBS=-3)"  "-j4"
check "empty override ignored"         "$(limits 16 w1:p1 MAKEFLAGS BUILD_LIMITS_JOBS=)"    "-j4"
check "decimal override ignored"       "$(limits 16 w1:p1 MAKEFLAGS BUILD_LIMITS_JOBS=2.5)" "-j4"

# --- The module's own promise ------------------------------------------------
# "Every value is a default, not an override: an explicitly-set variable always
# wins." That sentence has been in the header since the module was written and
# nothing asserted it.
echo "-- an explicitly set variable still wins --"
check "VITEST_MAX_WORKERS set by the caller" \
      "$(limits 16 w1:p1 VITEST_MAX_WORKERS VITEST_MAX_WORKERS=9)" "9"
check "MAKEFLAGS set by the caller" \
      "$(limits 16 w1:p1 MAKEFLAGS MAKEFLAGS=-j12)" "-j12"
check "...and it beats the override too" \
      "$(limits 16 w1:p1 MAKEFLAGS MAKEFLAGS=-j12 BUILD_LIMITS_JOBS=6)" "-j12"

# --- nproc absent ------------------------------------------------------------
# A missing nproc must not yield an empty or zero budget. The module falls back
# to 4, so the tiers are 2 and 2 — conservative, which is the right direction
# when the hardware is unknown.
echo "-- nproc missing --"
check "no nproc, pane: 2"        "$(limits none w1:p1 MAKEFLAGS)" "-j2"
check "no nproc, interactive: 2" "$(limits none ''    MAKEFLAGS)" "-j2"

# --- The report --------------------------------------------------------------
# build-limits is how you find out which tier is active, so it has to name the
# tier AND where the number came from. An override that is silently ignored is
# the case this matters most for.
echo "-- build-limits reports its reasoning --"
check "names the pane context"      "$(report 16 w1:p1 | grep -c 'herdr pane')"   "1"
check "names the interactive context" "$(report 16 '' | grep -c 'interactive')"   "1"
check "shows the core count"        "$(report 16 w1:p1 | grep -c '16')"           "1"
check "names the tier as the source" \
      "$(report 16 w1:p1 | grep -ci 'source.*tier')" "1"
check "names the override as the source" \
      "$(report 16 w1:p1 BUILD_LIMITS_JOBS=6 | grep -ci 'source.*BUILD_LIMITS_JOBS')" "1"
check "says an unusable override was ignored" \
      "$(report 16 w1:p1 BUILD_LIMITS_JOBS=abc | grep -ci 'ignored')" "1"

echo
if (( FAIL )); then
    printf '\033[1;31m=== %d passed, %d failed ===\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
printf '\033[0;32m=== %d passed, %d failed ===\033[0m\n' "$PASS" "$FAIL"
