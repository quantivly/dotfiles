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

# YAML comments are stripped before matching. A comment that EXPLAINS this rule
# must not trip it — this repo has already shipped a row that matched the
# comment describing the defect it was hunting.
# strip_noise removes shell comments and the CONTENTS of quoted strings before
# matching, so that a line which merely NAMES a forbidden command is not
# refused: a comment explaining this rule, and a step running
# `git commit -m "stop apt-get update failing CI"`, both have to pass. A false
# positive costs the whole check -- somebody deletes it -- while a miss costs
# one CI outage.
#
# It scans CHARACTER BY CHARACTER, tracking quote state, because the obvious
# line-based `sed` version had two holes that each hid a real violation while
# printing a green tick (found in review, both reproduced):
#
#   echo "don't skip" && sudo apt-get update && sudo apt-get install -y zsh
#     -- the single-quote rule ran first, so the two apostrophes INSIDE
#        separate double-quoted strings paired with each other and swallowed
#        the command between them.
#   echo "tag #1" && sudo apt-get update && sudo apt-get install -y zsh
#     -- the comment rule ran first and did not know about quoting, so it
#        truncated the line at a `#` that was ordinary quoted text.
#
# Neither is contrived; both are shapes people write. A `#` only opens a
# comment at a word boundary (`foo#bar` is not one) and only outside quotes.
strip_noise() {
    awk '{
        out = ""; n = length($0); i = 1; sq = 0; dq = 0
        while (i <= n) {
            c = substr($0, i, 1)
            if (!sq && !dq && c == "#" && (i == 1 || substr($0, i-1, 1) ~ /[ \t]/)) break
            if (!dq && c == "'"'"'") { sq = !sq; i++; continue }
            if (!sq && c == "\"")   { dq = !dq; i++; continue }
            if (sq || dq)          { i++; continue }
            out = out c; i++
        }
        print out
    }' "$1"
}

# strip_comments drops shell/YAML comments the same quote-aware way, but KEEPS
# quoted content. The interpolation rule below needs this and not strip_noise:
# `run: echo "${{ inputs.packages }}"` is still an injection surface, so
# dropping quoted text would hide a real violation -- while a COMMENT that
# merely names `${{ }}` must not count. That comment case is not theoretical:
# this action's own doc comment explains why not to interpolate, and the first
# version of the rule counted it and failed the shipped tree.
strip_comments() {
    awk '{
        out = ""; n = length($0); i = 1; sq = 0; dq = 0
        while (i <= n) {
            c = substr($0, i, 1)
            if (!sq && !dq && c == "#" && (i == 1 || substr($0, i-1, 1) ~ /[ \t]/)) break
            if (!dq && c == "'"'"'") sq = !sq
            else if (!sq && c == "\"") dq = !dq
            out = out c; i++
        }
        print out
    }' "$1"
}

# shell_code emits `<lineno>:<shell>` for the lines of a YAML file that are
# SHELL -- the inline value of a `run:` key, and the body of a `run:` block
# scalar -- with comments and the contents of quoted strings removed.
#
# ONE awk pass, deliberately. The first version composed a line-selector with a
# per-line stripper through a shell `while read` loop, which forks awk once per
# line: on a 560 KB fixture that was 20,000 forks and a single check took 205
# SECONDS. A checker too slow to run is a checker that gets skipped.
#
# Scoping to shell is what stops YAML PROSE being read as a command. Two false
# positives proved it necessary, both reproduced: a step whose `name:` names the
# forbidden shape ("Install deps (replaces apt-get update && apt-get install
# -y)") was reported as three violations while correctly USING the composite
# action, with a remedy telling the reader to do what they had already done; and
# this action's own `description:` ("Runs apt-get update tolerantly") failed the
# refresh-fatality rule.
#
# Block detection is by indentation, which is what YAML itself uses: a `run:`
# whose value is `|`/`>` (with any chomping/indent modifier) opens a block whose
# body is every following line indented deeper than the key. The `- run:`
# list-item form works because the key's own indent is measured, and a body is
# always deeper than that.
#
# Stripping is character-by-character and quote-aware. The obvious line-based
# sed version had two holes that each hid a real violation under a green tick:
# two apostrophes inside SEPARATE double-quoted strings paired with each other
# and swallowed the command between them, and a `#` inside a quoted string
# truncated the line. A `#` opens a comment only at a word boundary (`foo#bar`
# is not one) and only outside quotes. After the fix the strip matches what a
# shell would treat as quoted, so anything it hides was never going to run as a
# command anyway.
shell_code() {
    awk '
    function strip(line,   out, n, i, c, sq, dq) {
        out = ""; n = length(line); i = 1; sq = 0; dq = 0
        while (i <= n) {
            c = substr(line, i, 1)
            if (!sq && !dq && c == "#" && (i == 1 || substr(line, i-1, 1) ~ /[ \t]/)) break
            if (!dq && c == "'"'"'") { sq = !sq; i++; continue }
            if (!sq && c == "\"")   { dq = !dq; i++; continue }
            if (sq || dq)          { i++; continue }
            out = out c; i++
        }
        return out
    }
    {
        match($0, /^[ \t]*/); ind = RLENGTH
        if (inrun) {
            if ($0 ~ /^[ \t]*$/) next
            if (ind > runind) { print NR ":" strip($0); next }
            inrun = 0
        }
        if (match($0, /^[ \t]*-?[ \t]*run:[ \t]*/)) {
            rest = substr($0, RSTART + RLENGTH)
            match($0, /^[ \t]*/); runind = RLENGTH
            if (rest ~ /^[|>][0-9+-]*[ \t]*$/) { inrun = 1; next }
            print NR ":" strip(rest)
        }
    }' "$1"
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
    printf '(^|[^A-Za-z0-9_-])apt(-get)?([[:space:]]+-[^[:space:]]+)*[[:space:]]+%s([^A-Za-z0-9_-]|$)' "$1"
}

mapfile -t workflows < <(find "$root/.github/workflows" -maxdepth 1 -type f \
    \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
if [ ${#workflows[@]} -eq 0 ]; then
    printf 'check-workflow-apt: no workflow files found under %s/.github/workflows\n' "$root" >&2
    exit 2
fi
note "scanning ${#workflows[@]} workflow file(s)"

for verb in update install; do
    hits=''
    for wf in "${workflows[@]}"; do
        while IFS= read -r n; do
            hits="${hits}${wf#"$root"/}:${n} "
        done < <(shell_code "$wf" | grep -E ":.*$(apt_re "$verb")" | cut -d: -f1)
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
    while IFS= read -r rec; do
        n="${rec%%:*}"; line="${rec#*:}"
        case "$line" in
            *'||'*true*|*'||'*':'*) continue ;;
        esac
        # An `if`/`elif` condition, or `&&`-chained inside one, is non-fatal.
        case "$line" in
            *if[[:space:]]*|*elif[[:space:]]*) continue ;;
        esac
        fatal="${fatal}${rel}:${n} "
    done < <(shell_code "$f" | grep -E ":.*$(apt_re update)")
done < <(find "$root/.github" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
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
    if [ -n "$(strip_noise "$root/$ACTION_REL" | grep 'apt-get install -y' || true)" ]; then
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
    # The value may be quoted -- `PACKAGES: "${{ inputs.packages }}"` is ordinary
    # YAML and arguably the better style -- so the quotes are optional here. The
    # first version required a bare value and flagged that shape, which is the
    # false positive that gets a checker deleted.
    #
    # `run` is itself a valid NAME, so `run: ${{ inputs.packages }}` would
    # otherwise count as an env assignment -- the injection, laundered through
    # the rule meant to catch it. Env-style lines whose key is `run` are
    # subtracted back out.
    # shellcheck disable=SC2016  # the ${{ }} patterns are literal, not expansions
    all_interp=$(strip_comments "$root/$ACTION_REL" | grep -c '\${{' || true)
    # shellcheck disable=SC2016  # ditto
    env_style=$(strip_comments "$root/$ACTION_REL" \
        | grep -cE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*["'"'"']?\${{[^}]*}}["'"'"']?[[:space:]]*$' || true)
    # shellcheck disable=SC2016  # ditto
    run_style=$(strip_comments "$root/$ACTION_REL" \
        | grep -cE '^[[:space:]]*run:[[:space:]]*["'"'"']?\${{' || true)
    env_interp=$((env_style - run_style))
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
