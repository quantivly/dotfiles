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
contains "  names the fatal refresh" "$out" "can fail its step"

# A `&&` gate inside the ACTION is caught -- the one file the workflow-only
# rules never inspect. (The four ways a refresh can be fatal have their own
# section below; this row is the plain one.)
d=$(mkfix gate_in_action); good_workflow "$d"
mkdir -p "$d/.github/actions/apt-install"
{
    printf -- '---\nname: apt-install\ninputs:\n  packages:\n    required: true\n'
    printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: |\n'
    printf '        sudo apt-get update && true\n'
    # shellcheck disable=SC2016  # literal fixture text, not an expansion
    printf '        sudo apt-get install -y $PACKAGES\n'
} > "$d/.github/actions/apt-install/action.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a gate inside the ACTION exits 1" 1 "$rc"
contains "  and names the action file" "$out" "apt-install/action.yml"

# This row used a deliberately OVERSIZED (289 KB) fixture, to make a SIGPIPE
# race deterministic: the rule was once `strip … | grep -q PAT && var=…`, where
# grep -q exits at its first match, sed dies of SIGPIPE, and under pipefail the
# PIPELINE fails -- so a matched gate read as "no match". Measured then: 0 in
# 30/30 runs at 27 KB, 141 in 30/30 at 289 KB, and ci.yml at 29 KB missing its
# own ten violations in 13 of 20 runs.
#
# The fixture is gone because the CODE is gone: no rule pipes into `grep -q` any
# more. It also cost 205 SECONDS per check before shell_code became one awk pass.
# What remains is the lesson, asserted at the source, which is deterministic and
# free -- a behavioural row could only reproduce the race probabilistically.
if grep -q '| *grep -q' "$CHECKER"; then
    fail=$((fail + 1))
    # shellcheck disable=SC2016,SC2018  # literal text / ASCII-only slug, both intended
    printf '  FAIL the checker pipes into grep -q: under pipefail that is a\n'
    printf '       SIGPIPE race in which a MATCH reads as no-match. Use\n'
    # shellcheck disable=SC2016,SC2018  # literal text / ASCII-only slug, both intended
    printf '       [ -n "$(... | grep PAT || true)" ] or a loop over grep output.\n'
else
    # shellcheck disable=SC2016,SC2018  # literal text / ASCII-only slug, both intended
    pass=$((pass + 1)); printf '  ok   the checker never pipes into grep -q (SIGPIPE race)\n'
fi

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

printf '\n== spellings that escaped the first version ==\n'
# Matching the literal "apt-get <verb>" missed two shapes people actually
# type, and each reintroduced DO-608 under a full green tick. Found in
# independent review, after this suite was already 29/29.
d=$(mkfix apt_short); good_action "$d"; good_workflow "$d"
printf '      - run: sudo apt update && sudo apt install -y zsh\n' >> "$d/.github/workflows/ci.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "'apt update' (not apt-get) is caught" 1 "$rc"

d=$(mkfix apt_opts); good_action "$d"; good_workflow "$d"
printf '      - run: sudo apt-get -qq update && sudo apt-get -y install zsh\n' >> "$d/.github/workflows/ci.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "options between the program and the verb do not hide it" 1 "$rc"

# The widened pattern must not start matching words that merely contain "apt".
d=$(mkfix apt_wordish); good_action "$d"; good_workflow "$d"
cat >> "$d/.github/workflows/ci.yml" <<'W'
      - run: echo aptitude update is a different program
      - run: echo we adapt update semantics here
W
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "'aptitude' and 'adapt' are not apt" 0 "$rc"

printf '\n== the quote/comment stripper must not hide a violation ==\n'
# Both of these passed the line-based sed version, which paired apostrophes
# across two separate double-quoted strings, and truncated at a '#' that was
# ordinary quoted text. Neither line is contrived.
d=$(mkfix strip_apostrophes); good_action "$d"; good_workflow "$d"
cat >> "$d/.github/workflows/ci.yml" <<'W'
      - run: echo "don't skip" && sudo apt-get update && sudo apt-get install -y zsh && echo "won't fail"
W
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "apostrophes inside double quotes do not swallow the command" 1 "$rc"

d=$(mkfix strip_hash); good_action "$d"; good_workflow "$d"
cat >> "$d/.github/workflows/ci.yml" <<'W'
      - run: echo "tag #1" && sudo apt-get update && sudo apt-get install -y zsh
W
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a '#' inside a quoted string does not truncate the line" 1 "$rc"

printf '\n== the interpolation rule has no empty case ==\n'
# The awk extractor only understood `run: |`, so a one-line or folded run
# yielded an EMPTY extraction that read as "no interpolation" -- a tick over
# the exact injection surface the rule forbids.
# shellcheck disable=SC2016,SC2018  # literal ${{ }} / ASCII-only slug, both intended
for form in 'run: sudo apt-get install -y ${{ inputs.packages }}' 'run: >\n        sudo apt-get install -y ${{ inputs.packages }}'; do
    # shellcheck disable=SC2016,SC2018  # literal ${{ }} / ASCII-only slug, both intended
    d=$(mkfix "interp_$(printf '%s' "$form" | tr -cd 'a-z' | cut -c1-12)")
    good_workflow "$d"; mkdir -p "$d/.github/actions/apt-install"
    {
        printf -- '---\nname: apt-install\ninputs:\n  packages:\n    required: true\n'
        printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      '
        printf '%b\n' "$form"
    } > "$d/.github/actions/apt-install/action.yml"
    out=$("$CHECKER" "$d" 2>&1); rc=$?
    check "interpolation in a non-block run: is caught (${form%% *} ${form#* })" 1 "$rc"
done

# A ${{ }} inside a QUOTED string in a run line is still an injection, so the
# interpolation rule must strip comments only -- never quoted text. This row is
# what stops someone "simplifying" it to reuse strip_noise.
d=$(mkfix interp_quoted); good_workflow "$d"; mkdir -p "$d/.github/actions/apt-install"
cat > "$d/.github/actions/apt-install/action.yml" <<'A'
---
name: apt-install
inputs:
  packages:
    required: true
runs:
  using: composite
  steps:
    - shell: bash
      run: |
        sudo apt-get install -y "${{ inputs.packages }}"
A
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "interpolation inside quotes is still caught" 1 "$rc"

# ...and a COMMENT naming ${{ }} must not count as one, or the shipped action
# fails its own check (it did, on the first version of this rule).
d=$(mkfix interp_comment); good_action "$d"; good_workflow "$d"
# sed, not a python3 heredoc: with python3 absent the heredoc failed silently,
# the fixture was never modified, and this row then asserted rc=0 against an
# unmodified GOOD fixture -- green for a reason unrelated to the rule. The
# assertion below that the edit applied is what makes that impossible now.
af="$d/.github/actions/apt-install/action.yml"
sed -i 's|^\( *\)run: |\1# never interpolate ${{ inputs.x }} into a run line\n\1run: |' "$af"
if ! grep -q 'never interpolate' "$af"; then
    fail=$((fail + 1)); printf '  FAIL fixture edit did not apply (interp_comment)\n'
fi
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a comment naming \${{ }} is not counted as interpolation" 0 "$rc"

# A quoted env value is ordinary YAML and arguably better style. The first
# version of the interpolation rule required a bare value and flagged this,
# which is the false positive that gets a checker deleted.
d=$(mkfix interp_quoted_env); good_workflow "$d"; mkdir -p "$d/.github/actions/apt-install"
cat > "$d/.github/actions/apt-install/action.yml" <<'A'
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
        PACKAGES: "${{ inputs.packages }}"
      run: |
        sudo apt-get install -y $PACKAGES
A
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a QUOTED env value is not flagged" 0 "$rc"

# `run` is itself a valid NAME, so allowing quotes opened a hole: a whole-value
# `run: ${{ inputs.packages }}` would have counted as an env assignment -- the
# injection laundered through the rule meant to catch it.
d=$(mkfix interp_run_key); good_workflow "$d"; mkdir -p "$d/.github/actions/apt-install"
cat > "$d/.github/actions/apt-install/action.yml" <<'A'
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
        PACKAGES: "${{ inputs.packages }}"
      run: ${{ inputs.packages }}
A
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a 'run:' key whose whole value interpolates is caught" 1 "$rc"
contains "  and names the interpolation" "$out" "env: assignment"

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
contains "  and still names it" "$out" "can fail its step"

d=$(mkfix unrelated); good_action "$d"; good_workflow "$d"
printf '      - run: git commit -m "stop apt-get update failing CI"\n' \
    >> "$d/.github/workflows/ci.yml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a commit message mentioning the shape exits 0" 0 "$rc"

printf '\n== the refresh must be non-fatal, asserted positively ==\n'
# The rule was "no `apt-get update &&`", and review defeated it with four
# regressions INSIDE the action -- the one file that actually runs apt, and the
# one the workflow rules never inspect. All four printed `all 6 checks passed`.
# Three contain no `&&` at all, so tightening that token could never reach them.
#
# Each fixture keeps a VALID install line, so the fatal refresh is the only
# thing wrong: the row asserts the specific message, not just rc=1, or it could
# pass for an unrelated reason.
act_with() { # act_with <root> <run-body>
    mkdir -p "$1/.github/actions/apt-install"
    {
        printf -- '---\nname: apt-install\ninputs:\n  packages:\n    required: true\n'
        printf 'runs:\n  using: composite\n  steps:\n    - shell: bash\n      env:\n'
        # shellcheck disable=SC2016  # literal fixture text, not an expansion
        printf '        PACKAGES: ${{ inputs.packages }}\n      run: |\n'
        printf '%b\n' "$2"
    } > "$1/.github/actions/apt-install/action.yml"
}
# shellcheck disable=SC2016  # $PACKAGES is literal fixture text
inst='        sudo apt-get install -y $PACKAGES'
for c in \
    "set -e and a bare refresh@@        set -euo pipefail\n        sudo apt-get update\n$inst" \
    "a refresh with an option before &&@@        sudo apt-get update -qq && sudo apt-get install -y \$PACKAGES" \
    "a refresh with || exit 1@@        sudo apt-get update || exit 1\n$inst" \
    "a refresh separated by ;@@        sudo apt-get update\n$inst"; do
    # shellcheck disable=SC2016,SC2018  # literal text / ASCII-only slug, both intended
    d=$(mkfix "fatal_$(printf '%s' "${c%%@@*}" | tr -cd 'a-z')"); good_workflow "$d"
    act_with "$d" "${c#*@@}"
    out=$("$CHECKER" "$d" 2>&1); rc=$?
    check "in the action, ${c%%@@*} is caught" 1 "$rc"
    contains "  and names it as fatal" "$out" "can fail its step"
done

# The two spellings that are legal, so the rule is not simply "no refresh".
for c in \
    "an if ! condition@@        if ! sudo apt-get update; then printf warn; fi\n$inst" \
    "an explicit || true@@        sudo apt-get update || true\n$inst"; do
    # shellcheck disable=SC2016,SC2018  # literal text / ASCII-only slug, both intended
    d=$(mkfix "ok_$(printf '%s' "${c%%@@*}" | tr -cd 'a-z')"); good_workflow "$d"
    act_with "$d" "${c#*@@}"
    out=$("$CHECKER" "$d" 2>&1); rc=$?
    check "in the action, ${c%%@@*} is accepted" 0 "$rc"
done

printf '\n== YAML prose is not shell ==\n'
# A step whose name NAMES the forbidden shape, while correctly using the
# action, was reported as three violations with a remedy telling the reader to
# do what they had already done. The action's own `description:` failed the
# refresh rule the same way. A checker that refuses a correct workflow gets
# deleted.
d=$(mkfix prose_name); good_action "$d"; good_workflow "$d"
cat >> "$d/.github/workflows/ci.yml" <<'W'
      - name: Install deps (replaces apt-get update && apt-get install -y)
        uses: ./.github/actions/apt-install
        with:
          packages: zsh
W
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "an unquoted YAML name: naming the shape is not a violation" 0 "$rc"

printf '\n== the check count is invariant ==\n'
# Renaming the action file printed "1 of 4 checks failed": a false failure whose
# denominator had silently dropped from 6, because two assertions never ran.
d=$(mkfix ext_yaml); good_workflow "$d"
mkdir -p "$d/.github/actions/apt-install"
good_action "$d"
mv "$d/.github/actions/apt-install/action.yml" "$d/.github/actions/apt-install/action.yaml"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "action.yaml is found as readily as action.yml" 0 "$rc"
contains "  and still runs all six checks" "$out" "all 6 checks passed"

d=$(mkfix no_action_count); good_workflow "$d"
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a missing action still fails" 1 "$rc"
contains "  over the full six checks, not a shrunken denominator" "$out" "of 6 checks failed"

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

printf '\n== the action REFUSES an empty package list ==\n'
# Measured before this guard existed: `apt-get install -y` with no operands
# prints "0 newly installed" and exits 0, so the install silently did nothing
# and the step stayed green. `inputs.<id>.required` is advisory -- the runner
# does not fail a step for a missing input -- so an omitted `with:`,
# `packages: ""`, or a mistyped key (`package:`, only an "Unexpected input"
# warning) all arrive as an empty string, and `set -u` does not help because
# PACKAGES is set. The worst case is a job whose only package is preinstalled
# (jq): green forever with the install switched off.
#
# This asserts the run script's EXIT CODE, not the presence of the guard's
# text -- a row that greps for the guard would pass over a guard that does not
# fire. The script is extracted with awk (already a dependency) rather than
# python3, and `sudo` is stubbed so nothing is installed.
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runscript=$(awk '
    /^ *run: \|/ { inrun = 1; match($0, /^ */); keyind = RLENGTH; bodyind = 0; next }
    inrun {
        if ($0 ~ /^ *$/) { print ""; next }
        match($0, /^ */)
        if (RLENGTH > keyind) {
            # The body indent is whatever the FIRST body line uses; taking it
            # from the key plus a guessed offset chopped 12 characters off
            # every line and produced a script that could not run.
            if (bodyind == 0) bodyind = RLENGTH
            print substr($0, bodyind + 1)
            next
        }
        inrun = 0
    }' "$repo_root/.github/actions/apt-install/action.yml")
if [ -z "$runscript" ]; then
    fail=$((fail + 1)); printf '  FAIL could not extract the action run script\n'
else
    for pk in '' '   '; do
        rc=0
        PACKAGES="$pk" bash -c 'sudo() { :; }; '"$runscript" >/dev/null 2>&1 || rc=$?
        check "the action refuses PACKAGES=$(printf '%q' "$pk")" 1 "$rc"
    done
    rc=0
    PACKAGES='zsh jq' bash -c 'sudo() { :; }; '"$runscript" >/dev/null 2>&1 || rc=$?
    check "the action accepts a real package list" 0 "$rc"
fi

printf '\n== a # only opens a comment at a word boundary ==\n'
# strip_noise's rule is that `foo#bar` is not a comment. Nothing pinned it, and
# losing it would truncate any line containing a `#` mid-word -- hiding the
# gate that follows.
d=$(mkfix hash_wordish); good_action "$d"; good_workflow "$d"
cat >> "$d/.github/workflows/ci.yml" <<'W'
      - run: echo ref#123 && sudo apt-get update && sudo apt-get install -y zsh
W
out=$("$CHECKER" "$d" 2>&1); rc=$?
check "a mid-word '#' does not truncate the line" 1 "$rc"

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
