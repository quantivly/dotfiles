#!/usr/bin/env bash
# State table for scripts/check-workflow-apt.sh (DO-608).
#
# Hermetic: every row builds its own fixture tree under a temp dir and runs the
# checker against it with an explicit root. Nothing reads this repository except
# the two deliberate integration rows at the end, which assert that the tree we
# actually ship passes.
#
# Most rows assert what the checker must NOT flag. A false positive costs the
# whole check — somebody deletes it — while a miss costs one CI outage, so the
# comment-mentioning-the-rule row matters as much as the violation rows.
set -uo pipefail

# shellcheck disable=SC2016
# The fixture builders below print literal `${{ inputs.packages }}` and
# `$PACKAGES` into YAML on purpose — they are the strings under test, not
# expansions this script wants performed.

CHECKER=${CHECKER:-}
if [ -z "$CHECKER" ]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    CHECKER="$here/check-workflow-apt.sh"
fi
[ -x "$CHECKER" ] || { printf 'test-workflow-apt: %s is not executable\n' "$CHECKER" >&2; exit 2; }

pass=0; fail=0
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

check() { # check <desc> <expected-rc> <actual-rc>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); printf '  ok   %s\n' "$1"
    else
        fail=$((fail + 1)); printf '  FAIL %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <desc> <haystack> <needle>
    case "$2" in
        *"$3"*) pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
        *)      fail=$((fail + 1)); printf '  FAIL %s (missing: %s)\n' "$1" "$3" ;;
    esac
}
lacks() { # lacks <desc> <haystack> <needle>
    case "$2" in
        *"$3"*) fail=$((fail + 1)); printf '  FAIL %s (unexpectedly present: %s)\n' "$1" "$3" ;;
        *)      pass=$((pass + 1)); printf '  ok   %s\n' "$1" ;;
    esac
}

# --- fixture builders ----------------------------------------------------
good_action() { # good_action <root>
    mkdir -p "$1/.github/actions/apt-install"
    cat > "$1/.github/actions/apt-install/action.yml" <<'A'
---
name: apt-install
inputs:
  packages:
    required: true
runs:
  using: composite
  steps:
    - shell: bash
      env:
        PACKAGES: ${{ inputs.packages }}
      run: |
        set -uo pipefail
        if ! sudo apt-get update; then
          printf '::warning::some sources failed\n'
        fi
        sudo apt-get install -y $PACKAGES
A
}
good_workflow() { # good_workflow <root>
    mkdir -p "$1/.github/workflows"
    cat > "$1/.github/workflows/ci.yml" <<'W'
---
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/apt-install
        with:
          packages: zsh jq
W
}
mkfix() { # mkfix <name> -> prints its root
    local d="$ROOT/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"
}

printf '\n== the shipped shape passes ==\n'
d=$(mkfix clean); good_action "$d"; good_workflow "$d"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a clean fixture exits 0" 0 "$rc"
contains "  and reports all six checks" "$out" "all 6 checks passed"

printf '\n== each violation is caught ==\n'
d=$(mkfix gate); good_action "$d"; good_workflow "$d"
cat >> "$d/.github/workflows/ci.yml" <<'W'
      - name: Install zsh
        run: sudo apt-get update && sudo apt-get install -y zsh
W
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a workflow gating with '&&' exits 1" 1 "$rc"
contains "  names the direct update" "$out" "runs 'apt-get update' directly"
contains "  names the gate" "$out" "gates a step"

# The gate must be caught inside the ACTION too — the one file the
# workflow-only rules never inspect.
#
# THE FIXTURE SIZE IS LOAD-BEARING, and this row was decoration until it grew.
# The bug being pinned is `strip_noise "$f" | grep -q PATTERN && gate=...`:
# grep -q exits on its first match, sed then dies of SIGPIPE, and under
# `set -o pipefail` the PIPELINE reports failure, so a matched gate reads as
# "no match". Whether sed has already flushed into the 64 KiB pipe buffer is a
# RACE, measured here: at ~27 KB the pipeline returned 0 in 30/30 runs, at
# ~289 KB it returned 141 in 30/30, and the real ci.yml at 29 KB sat on the
# boundary at 13/20 missed. A small fixture therefore passes with the bug
# reinstated. The padding is real (non-comment) shell lines on purpose —
# comment lines are stripped to empty ones and produce almost no volume, so
# they would not fill the pipe.
d=$(mkfix gate_in_action); good_workflow "$d"
mkdir -p "$d/.github/actions/apt-install"
{
    printf -- '---\nname: apt-install\ninputs:\n  packages:\n    required: true\n'
    printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      env:\n'
    # shellcheck disable=SC2016  # literal fixture text, not an expansion
    printf '        PACKAGES: ${{ inputs.packages }}\n      run: |\n'
    printf '        sudo apt-get update && true\n'
    # shellcheck disable=SC2016  # literal fixture text, not an expansion
    printf '        sudo apt-get install -y $PACKAGES\n'
    for i in $(seq 1 20000); do printf '        echo padding-%06d\n' "$i"; done
} > "$d/.github/actions/apt-install/action.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a gate inside the ACTION exits 1" 1 "$rc"
contains "  and names the action file" "$out" "apt-install/action.yml"

d=$(mkfix bare_update); good_action "$d"; good_workflow "$d"
printf '      - run: sudo apt-get update\n' >> "$d/.github/workflows/ci.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a workflow running a bare 'apt-get update' exits 1" 1 "$rc"

d=$(mkfix bare_install); good_action "$d"; good_workflow "$d"
printf '      - run: sudo apt-get install -y zsh\n' >> "$d/.github/workflows/ci.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a workflow running a bare 'apt-get install' exits 1" 1 "$rc"
contains "  names the direct install" "$out" "runs 'apt-get install' directly"

d=$(mkfix no_action); good_workflow "$d"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a missing composite action exits 1" 1 "$rc"
contains "  and says so" "$out" "is missing"

d=$(mkfix action_no_install); good_action "$d"; good_workflow "$d"
# shellcheck disable=SC2016  # literal fixture text, not an expansion
sed -i 's|sudo apt-get install -y \$PACKAGES|echo "nothing installed"|' \
    "$d/.github/actions/apt-install/action.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "an action that installs nothing exits 1" 1 "$rc"
contains "  and calls the gate gone" "$out" "the real gate is gone"

d=$(mkfix action_interp); good_action "$d"; good_workflow "$d"
sed -i 's|sudo apt-get install -y \$PACKAGES|sudo apt-get install -y ${{ inputs.packages }}|' \
    "$d/.github/actions/apt-install/action.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "an action interpolating into its run script exits 1" 1 "$rc"
contains "  and points at env:" "$out" "pass it via env:"

printf '\n== what it must NOT flag ==\n'
# A comment explaining the rule is the classic false positive: this repo has
# already shipped a row that matched the comment describing its own defect.
d=$(mkfix comment_only); good_action "$d"; good_workflow "$d"
cat >> "$d/.github/workflows/ci.yml" <<'W'
      # Never write `sudo apt-get update && sudo apt-get install -y zsh` here:
      # apt-get install and apt-get update belong in the composite action.
      - run: echo fine
W
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a comment naming the forbidden line exits 0" 0 "$rc"
contains "  still reports six passes" "$out" "all 6 checks passed"

# The quote-stripping must not become a hiding place: a REAL violation on a
# line that also carries a quoted string still has to be caught. Without this
# row, widening the strip to swallow a whole line would pass the suite.
d=$(mkfix gate_beside_quote); good_action "$d"; good_workflow "$d"
cat >> "$d/.github/workflows/ci.yml" <<'W'
      - run: echo "installing deps" && sudo apt-get update && sudo apt-get install -y zsh
W
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a real gate beside a quoted string is still caught" 1 "$rc"
contains "  and still names the gate" "$out" "gates a step"

d=$(mkfix unrelated); good_action "$d"; good_workflow "$d"
printf '      - run: git commit -m "stop apt-get update failing CI"\n' \
    >> "$d/.github/workflows/ci.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a commit message mentioning the shape exits 0" 0 "$rc"

printf '\n== cannot-run is not clean ==\n'
d=$(mkfix no_github)
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "no .github at all exits 2, not 0" 2 "$rc"
contains "  and says which path" "$out" ".github"

d=$(mkfix empty_workflows); good_action "$d"; mkdir -p "$d/.github/workflows"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a .github with no workflow files exits 2, not 0" 2 "$rc"
contains "  and does not claim a pass" "$out" "no workflow files found"

printf '\n== output is machine-readable ==\n'
d=$(mkfix clean2); good_action "$d"; good_workflow "$d"
out=$("$CHECKER" "$d" 2>&1 | cat)
lacks "piped output carries no ANSI escape" "$out" $'\033'
contains "a piped tick is greppable" "$out" "  ✓ "

printf '\n== the tree we ship ==\n'
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$("$CHECKER" "$repo" 2>&1); rc=$?
check "this repository passes its own check" 0 "$rc"
contains "  over its real workflow set" "$out" "scanning"

printf '\n'
if [ "$fail" -gt 0 ]; then
    printf 'test-workflow-apt: %d passed, %d FAILED\n' "$pass" "$fail"
    exit 1
fi
printf 'test-workflow-apt: all %d checks passed\n' "$pass"
