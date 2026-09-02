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

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
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

# check <binary> <required|optional> <mise-tool-or--> <what breaks without it>
check() {
    local bin="$1" need="$2" tool="$3" breaks="$4" ver pin
    if command -v "$bin" >/dev/null 2>&1; then
        ver="$("$bin" --version 2>/dev/null | head -1 | tr -d '\n')"
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
# REQUIRED, not optional: herdr-lazy() resolves its own binary through a
# python3 one-liner, so without python3 \$root is empty and `herdr-lazy install`
# dies with env: '/target/release/herdr-lazy': No such file or directory -- an
# error that names neither python nor herdr-lazy. It also drives the sidebar
# status-line publisher, which merely stays blank.
check python3  required python \
      "herdr-lazy cannot resolve its binary, and the sidebar stays blank"
check cargo    optional - \
      "the herdmates plugin compiles from source; without Rust it will not install"
check node     optional node \
      "the Linear-to-worktree plugin"
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
