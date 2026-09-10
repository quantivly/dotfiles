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

ACTION_REL='.github/actions/apt-install/action.yml'
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
# Comments AND quoted strings are stripped before matching. A comment that
# EXPLAINS this rule must not trip it — this repo has already shipped a row that
# matched the comment describing the defect it was hunting. Quoted strings go
# for the same reason the secret-emission guard strips them: a step running
# `git commit -m "stop apt-get update failing CI"` merely NAMES the shape, and
# refusing it is the false positive that costs the whole check. A real apt-get
# invocation is never inside quotes, so nothing real is hidden by this.
strip_noise() {
    sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' \
        -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g' "$1"
}

# Callers use `[ -n "$(... | grep PATTERN || true)" ]` rather than `| grep -q`.
# `grep -q` exits on its first match; if sed still has output pending it dies of
# SIGPIPE, and under `set -o pipefail` the PIPELINE reports failure — so a
# matched pattern reads as "no match". This checker passed its own violating
# tree that way once.
#
# It is a RACE, not a certainty, which is what makes it dangerous: whether sed
# has already flushed into the 64 KiB pipe buffer decides the outcome. Measured
# on this repo — 27 KB returned 0 in 30/30 runs, 289 KB returned 141 in 30/30,
# and ci.yml at 29 KB sat on the boundary, missing the gate in 13 of 20 runs.
# So the bad form passes most of the time on a file this size, and the state
# table needs a deliberately oversized fixture to pin it at all.

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
        done < <(strip_noise "$wf" | grep -n "apt-get ${verb}" | cut -d: -f1)
    done
    if [ -n "$hits" ]; then
        bad "a workflow runs 'apt-get ${verb}' directly: ${hits% }"
        note "  Fix: use '- uses: ./${ACTION_REL%/action.yml}' with 'packages:'"
    else
        ok "no workflow runs 'apt-get ${verb}' directly"
    fi
done

# The gate itself, anywhere under .github — including the composite action.
gate=''
while IFS= read -r f; do
    # NB: never `| grep -q` under pipefail here — see the helper note below.
    if [ -n "$(strip_noise "$f" | grep 'apt-get update[[:space:]]*&&' || true)" ]; then
        gate="${gate}${f#"$root"/} "
    fi
done < <(find "$root/.github" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
if [ -n "$gate" ]; then
    bad "'apt-get update &&' gates a step in: ${gate% }"
    note "  Fix: run the update, warn on failure, then install strictly."
else
    ok "nothing gates a step on 'apt-get update' with &&"
fi

if [ ! -f "$root/$ACTION_REL" ]; then
    bad "$ACTION_REL is missing — nothing holds the reasoning or does the install"
else
    ok "$ACTION_REL exists"
    if [ -n "$(strip_noise "$root/$ACTION_REL" | grep 'apt-get install -y' || true)" ]; then
        ok "the action installs strictly with 'apt-get install -y'"
    else
        bad "the action does not run 'apt-get install -y' — the real gate is gone"
    fi
    # Packages must reach the script through env:, never by interpolating
    # ${{ }} into a shell line, which is a script-injection surface.
    run_script=$(awk '/^[[:space:]]*run:[[:space:]]*\|/{inrun=1;next} inrun && /^[[:space:]]*[a-z-]+:[[:space:]]*/ && !/^[[:space:]]{8}/{inrun=0} inrun' \
        "$root/$ACTION_REL")
    # shellcheck disable=SC2016  # literal ${{ }} is exactly what we hunt for
    if [ -n "$(printf '%s\n' "$run_script" | grep '\${{' || true)" ]; then
        bad "the action interpolates \${{ }} inside its run script — pass it via env:"
    else
        ok "the action's run script interpolates no \${{ }}"
    fi
fi

printf '\n'
if [ "$fail" -gt 0 ]; then
    printf 'check-workflow-apt: %s%d of %d checks failed%s\n' "$RED" "$fail" "$checks" "$RST"
    exit 1
fi
printf 'check-workflow-apt: %sall %d checks passed%s\n' "$GRN" "$checks" "$RST"
