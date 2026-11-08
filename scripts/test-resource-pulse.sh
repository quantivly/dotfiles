#!/usr/bin/env bash
#
# scripts/test-resource-pulse.sh
# ==============================
#
# State table for the Resource Pulse GNOME Shell extension
# (gnome-shell/extensions/resource-pulse@dotfiles). The rows live in plain-gjs
# test files under gnome-shell/tests/, imported by a static list in run.js;
# this wrapper runs them, echoes their output and folds the ONE anchored
# `JS-TALLY pass=<n> fail=<n>` line into its own PASS/FAIL.
#
# "Could not run" is exit 2, never a pass: a missing gjs or a missing tally
# line (an import error prints none) is fatal. The suite asserts its own row
# total.
#
# Requires: bash, gjs. No network, no root.
#
# Usage: scripts/test-resource-pulse.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES="$(cd "$HERE/.." && pwd -P)"
RUNNER="$DOTFILES/gnome-shell/tests/run.js"
TALLY_PATTERN='^JS-TALLY pass=([0-9]+) fail=([0-9]+)$'

PASS=0; FAIL=0
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

[[ -r "$RUNNER" ]] || fatal "cannot read $RUNNER"
command -v gjs >/dev/null || fatal "gjs is required"

JS_OUTPUT="$(gjs -m "$RUNNER" 2>&1)"
JS_EXIT=$?
printf '%s\n' "$JS_OUTPUT"

# The tally is read from ONE anchored line, never by counting marks: a row
# name may contain one.
TALLY_LINE=""
while IFS= read -r line; do
  if [[ "$line" =~ $TALLY_PATTERN ]]; then
    TALLY_LINE="$line"
    JS_PASS="${BASH_REMATCH[1]}"
    JS_FAIL="${BASH_REMATCH[2]}"
  fi
done <<<"$JS_OUTPUT"
[[ -n "$TALLY_LINE" ]] || fatal "no JS-TALLY line in the gjs output (exit $JS_EXIT): the tests did not run"

PASS=$((PASS + JS_PASS))
FAIL=$((FAIL + JS_FAIL))
# A non-zero gjs exit with a clean tally means the runner itself broke.
if (( JS_EXIT != 0 && JS_FAIL == 0 )); then
  printf '  \033[1;31m✗\033[0m gjs exited %d with no failing row\n' "$JS_EXIT"
  FAIL=$((FAIL + 1))
fi

EXPECTED_ROWS=36

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
