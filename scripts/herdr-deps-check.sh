#!/usr/bin/env bash
#
# scripts/herdr-deps-check.sh
# ===========================
#
# Report which herdr runtime dependencies are present, and name what breaks
# without each one. Read-only: installs nothing, changes nothing, and never
# touches the caller's mise configuration.
#
# WHY THIS EXISTS (DO-555). The full `./install` symlinks ~/.config/mise/config.toml
# into this repo, which pins ~25 tools and overrides whatever node/python the
# machine already runs. That is right for a machine that has adopted the whole
# repo and wrong for one adopting herdr alone. So the modular path reports
# instead of imposing, and this script is the report.
#
# It handles both cases on purpose:
#   - mise present  -> offer the exact `mise use -g` line, with versions read
#                      from .mise.toml so this script cannot drift from the pins
#   - mise absent   -> name the versions we run and leave the method to you
#
# Exit status: 0 if every REQUIRED dependency is present, 1 otherwise. A missing
# OPTIONAL dependency degrades one named feature and is reported, not failed —
# an installer that refuses over a plugin you may not want is its own problem.
#
# Usage: scripts/herdr-deps-check.sh [--quiet]

set -uo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISE_TOML="${BASEDIR}/.mise.toml"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

# Colour only on a TTY, matching scripts/verify-tools.sh. This was unconditional,
# which put escape sequences into every redirect and pipe -- `./install --herdr
# > install.log` and the CI job both captured `\033[0;32m✓\033[0m curl`. It also
# made a grep for `✓ curl` impossible, so a state-table row asserting an old curl
# does NOT get a ✓ passed no matter what was printed: the literal never matched
# either way. A checker whose output cannot be grepped cannot be pinned.
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
    RED=''; GRN=''; YEL=''; DIM=''; OFF=''
fi
MISSING_REQUIRED=0
declare -a WANTED=()

say() { (( QUIET )) || printf '%s\n' "$*"; }

# Pinned version for a tool, straight out of .mise.toml. Returns empty when the
# file is unreadable or the tool is not pinned -- callers must treat empty as
# "no opinion", never as "any version will do".
pinned() {
    [[ -r "$MISE_TOML" ]] || return 0
    sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*[\"']([^\"']+)[\"'].*/\1/p" \
        "$MISE_TOML" | head -1
}

# First dotted-numeric token in a --version line. `grep -oE ... | head -1`
# deliberately, NOT a greedy sed capture: `curl 8.18.0 (x86_64-pc-linux-gnu)
# libcurl/8.18.0` ends in a second version, and `.*[^0-9]([0-9.]+)` captures the
# LAST one -- which on a mismatched build reports libcurl's version as curl's.
first_version() {
    printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# 0 if $1 >= $2, comparing dotted numerics field by field.
#
# NOT `sort -V`: BSD sort has no -V, so on a Mac the comparison would fail open
# and every version floor would silently pass -- and HERDR_GUIDE already tracks
# macOS portability as an open gap, so this file cannot assume GNU coreutils.
# A floor that passes everything is worse than no floor, because it reports a
# green tick over the exact state it exists to catch.
version_ge() {
    local h w i
    local -a hp wp
    IFS=. read -r -a hp <<<"$1"
    IFS=. read -r -a wp <<<"$2"
    for ((i = 0; i < 3; i++)); do
        h="${hp[i]:-0}"; w="${wp[i]:-0}"
        h="${h//[^0-9]/}"; w="${w//[^0-9]/}"    # "7.68.0-DEV" -> 0
        (( ${h:-0} > ${w:-0} )) && return 0
        (( ${h:-0} < ${w:-0} )) && return 1
    done
    return 0
}

# check <binary> <required|optional> <mise-tool-or--> <what breaks without it> [min-version]
#
# A version floor is checked only when the binary is PRESENT. Too old counts as
# missing for exit-status purposes when the dependency is required: the whole
# point of the floor is that the tool resolving on PATH is not the question.
check() {
    local bin="$1" need="$2" tool="$3" breaks="$4" floor="${5:-}" ver pin have
    if command -v "$bin" >/dev/null 2>&1; then
        ver="$("$bin" --version 2>/dev/null | head -1 | tr -d '\n')"
        if [[ -n "$floor" ]]; then
            have="$(first_version "$ver")"
            if [[ -z "$have" ]]; then
                # "Could not read the version" is not "the version is fine" --
                # the empty-answer-is-never-agreement rule. Reported, and it
                # does NOT count as a failure, because the tool is there and a
                # parse we cannot do is our problem, not the machine's.
                say "  ${YEL}⚠${OFF} ${bin}  present, but its version could not be read (need ${floor}+) — ${DIM}${ver}${OFF}"
                return 0
            fi
            if ! version_ge "$have" "$floor"; then
                say "  ${RED}✗${OFF} ${bin}  ${RED}${have}, need ${floor}+${OFF} — ${breaks}"
                [[ "$need" == required ]] && MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
                return 1
            fi
        fi
        say "  ${GRN}✓${OFF} ${bin}  ${DIM}${ver:-present}${OFF}"
        return 0
    fi
    pin="$(pinned "$tool")"
    if [[ "$need" == required ]]; then
        say "  ${RED}✗${OFF} ${bin}  ${RED}REQUIRED${OFF} — ${breaks}"
        MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    else
        say "  ${YEL}○${OFF} ${bin}  optional — ${breaks}"
    fi
    [[ "$tool" != "-" && -n "$pin" ]] && WANTED+=("${tool}@${pin}")
    return 1
}

say ""
say "herdr runtime dependencies"
say "${DIM}──────────────────────────${OFF}"

# Not managed by mise, and no version opinion: any jq parses herdr's replies.
# herdr itself. Nothing in this repo installs it, and every next-step the
# installer prints invokes it -- so omitting it let this script report "all
# required dependencies present" on a machine with no herdr at all.
check herdr    required - \
      "everything. Install it: curl -fsSL https://herdr.dev/install.sh | sh"
check jq       required - \
      "hspawn / hdespawn / hreap read herdr's JSON replies and refuse to run"
check git      required - "worktrees"
# The shell layer is hard zsh -- `bash -n zsh/zshrc.herdr` dies on the glob
# qualifier at line 741 -- and next-step 1 of the installer tells the adopter to
# source it. Without zsh the report was otherwise happy to say everything was fine.
check zsh      required - \
      "the shell layer: hspawn / hdespawn / hreap / claude cannot be sourced"
# REQUIRED, not optional: herdr-lazy() resolves its own binary through a
# python3 one-liner, so without python3 \$root is empty and `herdr-lazy install`
# dies with env: '/target/release/herdr-lazy': No such file or directory -- an
# error that names neither python nor herdr-lazy. It also drives the sidebar
# status-line publisher, which merely stays blank.
check python3  required python \
      "herdr-lazy cannot resolve its binary, and the sidebar stays blank"
check cargo    optional - \
      "the herdmates plugin compiles from source; without Rust it will not install"
# curl's PRESENCE is never the question by the time anyone runs this -- installing
# herdr, mise and rustup all go through it. Its VERSION is: reviewr's build hook
# runs `curl --retry-all-errors`, added in curl 7.71.0, and an unknown option makes
# curl exit 2 under that hook's `set -euo pipefail`. herdr surfaces it as
# `plugin build failed ... status: exit status: 2`, naming neither curl nor the flag.
# Reported by the first outside adopter, 2026-09-04, on a distro shipping 7.68.
check curl     optional - \
      "herdr-lazy install fails building persiyanov/herdr-reviewr; its build hook needs --retry-all-errors" \
      7.71.0
# node is BUILD-time here, and the floor matters more than the presence.
# tdi/herdr-worktree-setup declares `[[build]] command = ["npm", "ci"]`, so a node
# too old for npm fails `herdr-lazy install` outright rather than degrading one
# feature. An earlier version of this line called node optional "for the
# Linear-to-worktree plugin": wrong plugin (worktree-from-linear has no build step)
# and wrong severity. 18.0.0 is npm's own supported floor, not a guess -- npm says
# `^14.17.0 || ^16.13.0 || >=18.0.0` -- and .mise.toml pins 20, so this is below
# what we run rather than a second opinion about it.
#
# It is what catches the state the adopter above was actually in: mise never
# activated, `node` resolved to /usr/bin/node at v10.19.0, and the failure arrived
# as `npm v9.2.0 is known not to run on Node.js v10.19.0` -- so the report blamed
# npm, which was the newer of the two.
check node     optional node \
      "herdr-lazy install fails building tdi/herdr-worktree-setup, whose build is npm ci" \
      18.0.0
# No floor: npm 9 was fine on the machine above, node was not. Presence only --
# and no mise tool, since npm arrives with node.
check npm      optional - \
      "the same build: tdi/herdr-worktree-setup runs npm ci"
check bun      optional bun \
      "the gh-pr sidebar plugin"

say ""
if (( ${#WANTED[@]} )); then
    if command -v mise >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/mise" ]]; then
        say "  mise is installed. To get the missing ones at the versions we run:"
        say "    ${DIM}mise use -g ${WANTED[*]}${OFF}"
        say ""
        # On a machine that ran the FULL install, ~/.config/mise/config.toml is a
        # symlink to this repo's .mise.toml -- so `mise use -g` writes THROUGH it
        # and edits the repo. Telling such a user their pins are untouched is a
        # confident wrong answer, so check rather than assert.
        local_mise="${HOME}/.config/mise/config.toml"
        if [[ -L "$local_mise" && "$(readlink -f "$local_mise")" == "$(readlink -f "$MISE_TOML")" ]]; then
            say "  ${YEL}⚠${OFF} Your global mise config is a SYMLINK to ${MISE_TOML/#$HOME/\~}."
            say "  ${DIM}   'mise use -g' would write through it and edit this repo. Install the${OFF}"
            say "  ${DIM}   tools some other way, or expect a modified .mise.toml.${OFF}"
        else
            say "  ${DIM}That writes to YOUR global mise config. This repo's own pins stay${OFF}"
            say "  ${DIM}in ${MISE_TOML/#$HOME/\~} and are not linked into your setup by --herdr.${OFF}"
        fi
    else
        say "  mise is not installed. Versions we run, however you prefer to get them:"
        for w in "${WANTED[@]}"; do say "    ${DIM}${w/@/ }${OFF}"; done
    fi
    say ""
fi

if (( MISSING_REQUIRED )); then
    say "  ${RED}${MISSING_REQUIRED} required dependency missing.${OFF}"
    exit 1
fi
say "  ${GRN}All required dependencies present.${OFF}"
exit 0
