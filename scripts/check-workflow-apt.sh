#!/usr/bin/env bash
# Assert that no GitHub Actions workflow gates a job on `apt-get update`.
#
# WHY THIS EXISTS (DO-608). `apt-get update` exits non-zero when ANY configured
# source errors, and the GitHub runner images ship third-party lists (Google
# Chrome, Microsoft Edge) that no job in this repository reads. On 2026-09-09
# Google's repo served a Packages.gz that did not match its own Release file and
# `sudo apt-get update && sudo apt-get install -y ...` took 11 of 20 jobs red
# for ~40 minutes on every branch — and hid a real Pre-commit Hooks failure for
# a day underneath the noise.
#
# Measured against a fixture repository (no root needed; Dir::Etc, Dir::State
# and Dir::Cache redirected into a temp tree):
#
#   - a source whose Release advertises a Packages hash it does not serve gives
#     `E: ... Hash Sum mismatch` and exit 100;
#   - a healthy source configured alongside it STILL lands its index, and its
#     package stays a valid install candidate;
#   - an unreachable source is only `W:` and exits 0 — a different class.
#
# So the update's exit status is not evidence about whether a job can install
# what it needs. The install is, and it stays strict. All apt installs therefore
# go through .github/actions/apt-install, which holds that reasoning once.
#
# Exit 0 = clean, 1 = a violation, 2 = could not run the check at all. An
# unreadable tree is never reported as clean: "no files matched" is a failure
# here, because every way of getting the path wrong would otherwise narrow the
# check into silence.
set -uo pipefail

root=${1:-}
if [ -z "$root" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        printf 'check-workflow-apt: not a git repository and no root given\n' >&2
        exit 2
    }
fi
[ -d "$root/.github" ] || { printf 'check-workflow-apt: no %s/.github\n' "$root" >&2; exit 2; }

# GitHub resolves `uses: ./<dir>` to action.yml OR action.yaml, so hardcoding
# one made renaming the file a false "is missing" -- and took two later checks
# with it, silently (see EXPECTED_CHECKS).
ACTION_DIR='.github/actions/apt-install'
ACTION_REL="$ACTION_DIR/action.yml"
[ -f "$root/$ACTION_REL" ] || [ ! -f "$root/$ACTION_DIR/action.yaml" ] \
    || ACTION_REL="$ACTION_DIR/action.yaml"

# The number of checks this script performs on every run, whatever it finds.
# Asserted at the end: a run that quietly performed FEWER checks than this is
# itself a failure. Renaming the action file used to print "1 of 4 checks
# failed" -- a false failure whose denominator had silently dropped from 6,
# because two assertions never ran and nothing said so. That is this repo's
# "an unparseable link map yields no paths, and no paths reads as no drift"
# shape: the denominator moving is information the reader needs.
#
# WHAT IT CANNOT SEE, stated because the guard otherwise reads as more coverage
# than it is: `checks` counts CALLS to ok()/bad(), so it detects a check that
# was SKIPPED and never one that was HOLLOW. Every defect independent review
# found in this checker kept the count at exactly 6 while printing six ticks
# over a hidden violation -- a rule that stops being *reached* is invisible to
# this. The state table asserts the same number independently, which is where
# a deliberate change to it becomes visible in review; a literal here alone
# would be updated by the same hand that deletes a check.
EXPECTED_CHECKS=6
fail=0
checks=0

# Colour only on a tty. Unconditional escapes put control characters into every
# redirect and make a '✓' un-greppable, which has already let a state-table row
# in this repo pass whatever was printed.
if [ -t 1 ]; then GRN=$'\033[32m'; RED=$'\033[31m'; RST=$'\033[0m'
else GRN=''; RED=''; RST=''; fi

note() { printf '  %s\n' "$1"; }
ok()   { checks=$((checks + 1)); printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
bad()  { checks=$((checks + 1)); fail=$((fail + 1)); printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; }

# shell_code emits `<lineno>\t<shell>` via scripts/gha-yaml-shell.py, which
# uses a real YAML parser.
#
# It used to do this by hand in awk, and three rounds of independent review
# found SIX ways that went quiet -- each printing a full row of green ticks over
# a complete restoration of the outage. A comment after a block indicator
# (`run: |  # refresh, then install`, valid YAML) dropped the whole script and
# silenced three rules at once; a step's sibling keys were read as block body,
# making a `name:` that described the forbidden shape a false violation; a
# multi-line string's continuation lines were scanned as unquoted shell; CRLF
# broke block detection the same way. Every one of those is a YAML question,
# and the answer to a YAML question is a YAML parser. What is left below --
# operator position and apt's option forms -- is genuinely shell-level.
#
# The dependency is deliberate and cannot go quiet: the helper exits 2 when
# PyYAML is missing, the file is unreadable or the YAML does not parse, and
# `require_emitter` below turns any of those into this script's own exit 2.
# "Could not read the shell" is never "there is no shell here".
EMITTER="$(dirname "${BASH_SOURCE[0]}")/gha-yaml-shell.py"

require_emitter() {
    [ -x "$EMITTER" ] || {
        printf 'check-workflow-apt: %s is missing or not executable\n' "$EMITTER" >&2
        exit 2
    }
    python3 -c 'import yaml' 2>/dev/null || {
        printf 'check-workflow-apt: PyYAML is required (Ubuntu: python3-yaml).\n' >&2
        printf '  Refusing to fall back to hand-parsing YAML: that is where six\n' >&2
        printf '  separate silent-pass defects came from.\n' >&2
        exit 2
    }
}

# These PRINT and return the emitter's status. They must never be used inside
# `< <(...)` or `$(...)` with an `exit` of their own: that exits the SUBSHELL,
# the parent reads zero records, and zero records read as "this file contains no
# shell" -- so an unparseable workflow passed clean. That is the
# empty-answer-is-agreement shape, inside the dependency handling written to
# prevent it. Every call site captures into a variable and tests the status in
# the parent.
# Memoised per file: the rules ask for the same file's shell up to three times
# (two verbs plus the refresh rule), and each miss is a python start. Without
# this the state table took 76s instead of 20s -- and a checker slow enough to
# be annoying is a checker people stop running.
declare -A _SHELL_CACHE=()
shell_code() {
    if [ -z "${_SHELL_CACHE[$1]+set}" ]; then
        _SHELL_CACHE[$1]=$("$EMITTER" --shell "$1") || return 2
    fi
    printf '%s\n' "${_SHELL_CACHE[$1]}"
}
interp_lines() { "$EMITTER" --interp "$1"; }

die_unreadable() {
    printf 'check-workflow-apt: could not read the %s of %s\n' "$2" "$1" >&2
    printf '  Refusing to treat an unreadable file as one containing no shell.\n' >&2
    exit 2
}

# fatal_refreshes reads `<lineno>\t<shell>` and prints the line numbers whose
# apt refresh can FAIL ITS STEP.
#
# Position, not presence -- review broke the previous glob three ways, all
# reproduced. `if [ "$RUNNER_OS" = Linux ]; then sudo apt-get update; fi` passed
# because the substring `if` appeared on the line, yet `set -e` does kill a
# then-branch (verified). `sudo apt-get update ; if false; then :; fi` passed
# for the same reason. And `sudo apt-get update || { echo ERR: x; exit 1; }`
# passed because the `||`-then-colon glob matched the colon in `ERR:` -- a
# refresh that is emphatically fatal.
#
# Non-fatal means exactly two things:
#   - the refresh sits in a CONDITION: the line opens with if/elif/while/until
#     and no `then`/`do` appears before the refresh. `while !`/`until` matter:
#     a retry loop is the canonical answer to a flaky index, so refusing it
#     would refuse the improvement this guard exists to encourage.
#   - the tail after the LAST `||` is exactly `true` or `:`.
fatal_refreshes() {
    awk -F'\t' -v re="$1" '
    {
        n = $1; code = $2
        where = match(code, re)
        if (where == 0) next

        # Condition position?
        if (code ~ /^[[:space:]]*(if|elif|while|until)[[:space:]]/) {
            t = match(code, /[[:space:]](then|do)([[:space:]]|;|$)/)
            if (t == 0 || t > where) next
        }

        # Explicit tolerance after the last ||?
        rest = code; tail = ""
        while ((k = index(rest, "||")) > 0) {
            tail = substr(rest, k + 2)
            rest = tail
        }
        if (tail != "" && tail ~ /^[[:space:]]*(true|:)[[:space:]]*(;|$)/) next

        print n
    }'
}

# apt_re builds the pattern for one verb. Matching the literal string
# "apt-get <verb>" was not enough, and review proved it with two spellings
# people actually type -- `sudo apt update && sudo apt install -y zsh` and
# `sudo apt-get -qq update && sudo apt-get -y install zsh` -- both of which
# reintroduced the exact DO-608 bug while every check printed a tick. So the
# PROGRAM and the VERB are matched separately, with any number of options
# between them. The leading/trailing character classes are word boundaries
# that `grep -E` lacks portably; they keep `aptitude` and `adapt` out.
apt_re() {
    # An option's value may be a SEPARATE word -- `-o Acquire::Retries=3`,
    # `-t focal`, `-c file`, `--option K=V`. The previous class only consumed
    # attached values, so `sudo apt-get -o Acquire::Retries=3 update` (the
    # standard flaky-apt incantation, i.e. the likeliest future edit to this
    # action) stopped the pattern before the verb and switched the guard off.
    printf '(^|[^A-Za-z0-9_-])apt(-get)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+%s([^A-Za-z0-9_-]|$)' "$1"
}

mapfile -t workflows < <(find "$root/.github/workflows" -maxdepth 1 -type f \
    \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
if [ ${#workflows[@]} -eq 0 ]; then
    printf 'check-workflow-apt: no workflow files found under %s/.github/workflows\n' "$root" >&2
    exit 2
fi
# Called before any rule runs. It was DEFINED and never CALLED for a while --
# a guard that exists and is not invoked, which no linter here catches.
require_emitter
note "scanning ${#workflows[@]} workflow file(s)"

for verb in update install; do
    hits=''
    for wf in "${workflows[@]}"; do
        code=$(shell_code "$wf") || die_unreadable "${wf#"$root"/}" "shell"
        while IFS= read -r n; do
            hits="${hits}${wf#"$root"/}:${n} "
        done < <(printf '%s\n' "$code" | awk -F'\t' -v re="$(apt_re "$verb")" '$2 ~ re {print $1}')
    done
    if [ -n "$hits" ]; then
        bad "a workflow runs 'apt-get ${verb}' directly: ${hits% }"
        note "  Fix: use '- uses: ./${ACTION_REL%/action.yml}' with 'packages:'"
    else
        ok "no workflow runs 'apt-get ${verb}' directly"
    fi
done

# The refresh must be NON-FATAL, asserted positively.
#
# This was "no `apt-get update &&` anywhere", and review defeated it with four
# regressions inside the action -- the one file in the repo that actually runs
# apt, and the one the two workflow rules above never look at. All four printed
# `all 6 checks passed`:
#
#   set -euo pipefail            <- a COMPLETE restoration of DO-608, and what
#   sudo apt-get update             "hardening" looks like to the next person
#   sudo apt-get install ...
#
#   sudo apt-get update -qq && sudo apt-get install ...
#   sudo apt-get update || exit 1
#   sudo apt-get update; sudo apt-get install ...
#
# Three of them contain no `&&` at all, so no amount of tightening that token
# reaches them. Asking about the absence of one spelling is asking about the
# MECHANISM; this repo records that a check which does that goes green on the
# outcome it exists to prevent.
#
# So: every apt refresh anywhere under .github must be in a construct that
# cannot fail its step. A bare refresh is always fatal here -- GitHub runs a
# composite `shell: bash` step as `bash --noprofile --norc -eo pipefail`, so
# `set -e` is in force whether or not the script says so, which is also why
# scanning for `set -e` would be the wrong test. The legal spellings are an
# `if` condition (which suspends -e for that command) or an explicit
# `|| true` / `||:`.
fatal=''
while IFS= read -r f; do
    rel="${f#"$root"/}"
    code=$(shell_code "$f") || die_unreadable "$rel" "shell"
    while IFS= read -r n; do
        [ -n "$n" ] && fatal="${fatal}${rel}:${n} "
    done < <(printf '%s\n' "$code" | fatal_refreshes "$(apt_re update)")
    # The file set is what GITHUB actually executes, which is not every YAML
    # under .github:
    #
    #   - workflows: the TOP LEVEL of .github/workflows only. GitHub does not
    #     read nested files there, so `workflows/archive/old.yml` is a fragment
    #     or a backup and flagging it would be a false positive on dead code.
    #     The workflow rules use -maxdepth 1 and this rule must agree with
    #     them, or the two disagree about one repository.
    #   - everything else under .github at ANY depth, which is how composite
    #     actions are reached: `uses: ./path/to/action` accepts any path, so
    #     action files cannot be bounded by depth.
done < <({
    find "$root/.github/workflows" -maxdepth 1 -type f \
        \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
    find "$root/.github" -type f \( -name '*.yml' -o -name '*.yaml' \) \
        -not -path "$root/.github/workflows/*" 2>/dev/null
} | sort -u)

if [ -n "$fatal" ]; then
    bad "an apt refresh can fail its step at: ${fatal% }"
    note "  Fix: wrap it -- 'if ! sudo apt-get update; then <warn>; fi' -- or append '|| true'."
else
    ok "every apt refresh is in a construct that cannot fail its step"
fi

if [ ! -f "$root/$ACTION_REL" ]; then
    bad "$ACTION_DIR/action.yml (or .yaml) is missing — nothing holds the reasoning or does the install"
    # Emitted as failures rather than skipped: they are genuinely not
    # satisfied, and skipping them is what let the denominator move.
    bad "no action, so nothing installs strictly"
    bad "no action, so its \${{ }} placement cannot be checked"
else
    ok "$ACTION_REL exists"
    act_code=$(shell_code "$root/$ACTION_REL") || die_unreadable "$ACTION_REL" "shell"
    if [ -n "$(printf '%s\n' "$act_code" \
        | awk -F'\t' -v re="$(apt_re install)" '$2 ~ re {print $1}')" ]; then
        ok "the action installs strictly with 'apt-get install -y'"
    else
        bad "the action does not run 'apt-get install -y' — the real gate is gone"
    fi
    # Packages must reach the shell through `env:`, never by interpolating
    # ${{ }} into a run line -- that is a script-injection surface.
    #
    # This was an awk extractor that pulled out the `run: |` block and grepped
    # it, and review broke it in one line: the extractor only recognised the
    # BLOCK form, so a one-line `run: sudo apt-get install -y ${{ inputs.packages }}`
    # (and the folded `run: >` form) yielded an EMPTY extraction, which the
    # `[ -n ... ]` test read as "no interpolation found" and ticked -- over the
    # exact injection the check forbids. An empty answer is never agreement.
    #
    # The rule is positive-form instead, and has no empty case: COUNT every
    # `${{` in the file, count the ones in an `env:` assignment
    # (`NAME: ${{ ... }}`), and require the two to be equal. Any other
    # placement -- a run line, a `with:`, anywhere -- makes them differ. No
    # YAML parsing, nothing to fail to find, and no new dependency in a
    # checker.
    # false positive that gets a checker deleted.
    #
    # shellcheck disable=SC2016  # the ${{ }} patterns are literal, not expansions
    interp=$(interp_lines "$root/$ACTION_REL") || die_unreadable "$ACTION_REL" "interpolations"
    all_interp=$(printf '%s\n' "$interp" | grep -c . || true)
    env_interp=$(printf '%s\n' "$interp" | grep -c 'env$' || true)
    if [ "$all_interp" -ne "$env_interp" ]; then
        bad "the action has $all_interp \${{ }} but only $env_interp in an env: assignment — pass it via env:"
        note "  Fix: set 'env: {NAME: \${{ inputs.x }}}' and use \$NAME in the script."
    else
        ok "every \${{ }} in the action is an env: assignment ($env_interp)"
    fi
fi

printf '\n'
if [ "$checks" -ne "$EXPECTED_CHECKS" ]; then
    printf 'check-workflow-apt: %sperformed %d checks, expected %d%s — a check was skipped\n' \
        "$RED" "$checks" "$EXPECTED_CHECKS" "$RST"
    exit 1
fi
if [ "$fail" -gt 0 ]; then
    printf 'check-workflow-apt: %s%d of %d checks failed%s\n' "$RED" "$fail" "$checks" "$RST"
    exit 1
fi
printf 'check-workflow-apt: %sall %d checks passed%s\n' "$GRN" "$checks" "$RST"
