#!/usr/bin/env bash
#
# scripts/test-mise-worktree.sh — state table for MISE_IGNORED_CONFIG_PATHS in
# zsh/zshrc.conditionals
#
# WHY. ~/.dotfiles/.mise.toml is the global config (~/.config/mise/config.toml
# links to it), so a dotfiles worktree carries a copy of the global config at
# its root, where mise reads it as an untrusted PROJECT config. Every new shell
# in a worktree printed mise's trust error and every mise lookup there failed.
# The copy adds nothing, since the global config already applies, so mise is
# told to ignore it. docs/TROUBLESHOOTING.md has the measurements.
#
# The rule pinned here: in a dotfiles worktree a shell raises no trust error,
# including the one from the hook `mise activate` runs at eval time, and mise
# reads the global config rather than the worktree's copy. Other repositories'
# project configs, worktrees of them included, keep loading.
#
# REAL MISE, NOT A STUB. What this pins is mise's own behaviour: on 2026.6.14 the
# [settings] key of the same name parses and then does nothing, so a stub would
# have passed the wrong fix. CI installs the latest mise, so a release that
# changes this fails here rather than on a laptop.
#
# env -i IS LOAD-BEARING. mise trusts every config when it detects CI, so under
# CI's environment the trust error cannot fire and the first row's fixture would
# be hollow. MISE_PARANOID=1 does not bring it back: under CI it auto-trusts too,
# and RECORDS a trust entry in mise's state dir, so never try it outside a sandbox
# (measured 2026-11-07, mise 2026.6.14). The first row is the proof the fault is
# reproduced where this runs.
#
# HERMETIC. zsh -f, env -i, a sandbox HOME, mise offline, and no config lookup
# above the sandbox. Rows read one of three outcomes rather than the absence of
# an error, because a shell that died for any other reason also prints no error.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CONDITIONALS="$ROOT/zsh/zshrc.conditionals"
REPO_MISE_CONFIG="$ROOT/.mise.toml"

TRUST_ERROR_TEXT='are not trusted'
SHELL_FINISHED_MARK='state-table-shell-finished'
HOME_AS_MISE_LISTS_IT='~'

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

[[ -r "$CONDITIONALS" && -r "$REPO_MISE_CONFIG" ]] \
    || fatal "cannot read $CONDITIONALS or $REPO_MISE_CONFIG"
command -v zsh >/dev/null 2>&1 || fatal "zsh is required"
MISE_BIN=$(command -v mise) || fatal "mise is required: this table pins mise's own behaviour"
ZSH_BIN=$(command -v zsh)
SANDBOX_PATH="$(dirname "$MISE_BIN"):/usr/bin:/bin"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

SANDBOX_HOME="$TMPROOT/home"
DOTFILES_WORKTREE="$SANDBOX_HOME/.herdr/worktrees/.dotfiles/branch"
OTHER_REPO_WORKTREE="$SANDBOX_HOME/.herdr/worktrees/hub/branch"
PLAIN_PROJECT="$SANDBOX_HOME/project"
mkdir -p "$SANDBOX_HOME/.dotfiles" "$SANDBOX_HOME/.config/mise" \
    "$DOTFILES_WORKTREE" "$OTHER_REPO_WORKTREE" "$PLAIN_PROJECT" \
    || fatal "cannot build the sandbox under $TMPROOT"

# The repo's real config, in the two places a real machine has it. It needs
# trust because of its [env], [settings] and tool options, and the first row
# fails if that ever stops being true.
cp "$REPO_MISE_CONFIG" "$SANDBOX_HOME/.dotfiles/.mise.toml" || fatal "cannot copy $REPO_MISE_CONFIG"
cp "$REPO_MISE_CONFIG" "$DOTFILES_WORKTREE/.mise.toml" || fatal "cannot copy $REPO_MISE_CONFIG"
ln -s "$SANDBOX_HOME/.dotfiles/.mise.toml" "$SANDBOX_HOME/.config/mise/config.toml" \
    || fatal "cannot link the global config"

# Plain versions need no trust, so a listing of these reads the ignore rule
# alone, with no trust error in the way.
PROJECT_MISE_CONFIG=$'[tools]\nbat = "0.24.0"\n'
printf '%s' "$PROJECT_MISE_CONFIG" > "$OTHER_REPO_WORKTREE/.mise.toml"
printf '%s' "$PROJECT_MISE_CONFIG" > "$PLAIN_PROJECT/.mise.toml"

# $1 the directory the shell starts in, $2 the zsh code it runs. Stdout and
# stderr are merged: mise's error goes to stderr, and in the row that matters it
# comes from the hook inside `source`.
run_shell() {
    (cd "$1" && env -i HOME="$SANDBOX_HOME" PATH="$SANDBOX_PATH" TERM=dumb \
        MISE_OFFLINE=1 MISE_CEILING_PATHS="$TMPROOT" CONDITIONALS="$CONDITIONALS" \
        "$ZSH_BIN" -fc "$2" 2>&1)
}

# $1 a shell's output, read as one word.
shell_outcome() {
    local shell_output=$1
    if [[ "$shell_output" == *"$TRUST_ERROR_TEXT"* ]]; then
        echo trust-error
    elif [[ "$shell_output" == *"$SHELL_FINISHED_MARK"* ]]; then
        echo clean
    else
        echo did-not-finish
    fi
}

# The zsh a row runs: the module under test silently, then mise itself. The mark
# prints only when mise succeeded, or for ACTIVATE_THEN_MARK only when activation
# really defined the hook, which is what makes `clean` a positive claim.
# shellcheck disable=SC2016  # $CONDITIONALS is zsh's, from run_shell's environment
LOAD_CONDITIONALS='source "$CONDITIONALS" >/dev/null 2>&1;'
MISE_ENV_THEN_MARK="mise env && print -r -- $SHELL_FINISHED_MARK"
# shellcheck disable=SC2016  # as above, and ${+functions[...]} is zsh's own
ACTIVATE_THEN_MARK='source "$CONDITIONALS"; (( ${+functions[_mise_hook]} )) && print -r -- '"$SHELL_FINISHED_MARK"

# $1 a directory, $2 a config's path relative to the sandbox HOME. Prints yes or
# no: does `mise config ls` there, after the conditionals, name it?
config_is_listed() {
    local config_listing listing_row="$HOME_AS_MISE_LISTS_IT/$2 "
    config_listing=$(run_shell "$1" "$LOAD_CONDITIONALS mise config ls")
    if [[ $'\n'"$config_listing" == *$'\n'"$listing_row"* ]]; then echo yes; else echo no; fi
}

echo "a dotfiles worktree"
check "the fault reproduces here: bare mise refuses the worktree's copy" \
    "$(shell_outcome "$(run_shell "$DOTFILES_WORKTREE" "$MISE_ENV_THEN_MARK")")" "trust-error"
check "after the conditionals mise works in the worktree" \
    "$(shell_outcome "$(run_shell "$DOTFILES_WORKTREE" "$LOAD_CONDITIONALS $MISE_ENV_THEN_MARK")")" "clean"
check "activation itself raises no trust error" \
    "$(shell_outcome "$(run_shell "$DOTFILES_WORKTREE" "$ACTIVATE_THEN_MARK")")" "clean"
OWN_COPY_LISTED=$(config_is_listed "$DOTFILES_WORKTREE" '.herdr/worktrees/.dotfiles/branch/.mise.toml')
GLOBAL_LISTED=$(config_is_listed "$DOTFILES_WORKTREE" '.config/mise/config.toml')
check "it reads the global config and not its own copy" \
    "own=$OWN_COPY_LISTED global=$GLOBAL_LISTED" "own=no global=yes"

echo "everything else keeps its project config"
check "another repository's worktree" \
    "$(config_is_listed "$OTHER_REPO_WORKTREE" '.herdr/worktrees/hub/branch/.mise.toml')" "yes"
check "a plain project under HOME" \
    "$(config_is_listed "$PLAIN_PROJECT" 'project/.mise.toml')" "yes"

EXPECTED_ROWS=6
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mFATAL\033[0m: expected %d rows, ran %d\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 2
fi
echo
if (( FAIL )); then
    printf '\033[1;31m%d of %d checks failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"
    exit 1
fi
printf '\033[0;32mall %d checks passed\033[0m\n' "$PASS"
