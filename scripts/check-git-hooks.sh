#!/usr/bin/env bash
#
# check-git-hooks.sh — assert that the hooks directory git is told to use exists
# and holds hooks git can run.
#
# WHY THIS EXISTS. The tracked gitconfig sets `core.hooksPath = ~/.config/git/hooks`,
# and a global hooksPath REPLACES every repository's own .git/hooks. The link that
# puts config/git/hooks at that path was deleted from install.conf.yaml as
# collateral of the GPG removal (edabe60, 2026-01-28). The hook itself came back
# three weeks later (26cab05) with a header saying install.conf.yaml installs it.
# The link did not. From then until 2026-11-13 git ran NO hook in any repository
# that does not set its own hooksPath: no gitleaks, no shellcheck, no CLAUDE.md
# budget check. Nothing failed, because a hooks path that does not exist is not
# an error to git. It is "no hooks". `pre-commit install` could not cover for it
# either: it refuses outright while core.hooksPath is set.
#
# TWO QUESTIONS, because each can be false while the other looks fine:
#
#   (default)   THE LIVE MACHINE. Does the directory the global git config names
#               exist, and does it hold at least one hook git will run?
#   --tracked   THE CHECKOUT. Does install.conf.yaml declare a link at the path
#               the tracked gitconfig names, to a directory in this tree that
#               holds a runnable hook? This is the half CI can enforce, and the
#               one that fails on the commit that deletes the link.
#
# WHAT IT CANNOT SEE. A repository that sets its own core.hooksPath (husky does)
# never reads the global one; this says nothing about it. And a runnable hook is
# not a hook that does anything: the one shipped here exits 0 in a repository
# with no .pre-commit-config.yaml, by design.
#
# Usage:
#   scripts/check-git-hooks.sh                   # the live machine
#   scripts/check-git-hooks.sh --tracked         # this checkout
#   scripts/check-git-hooks.sh --tracked --root <checkout>
#
# Environment:
#   HOME       — the global git config and `~` resolve against it (tests set it)
#   REPO_ROOT  — the default for --root; else this script's repo
#
# Exit: 0 the hooks can run, or there is nothing to check (said so, never as a ✓);
#       1 the configured hooks cannot run;
#       2 the check could not run (no git, an unreadable config, a bad flag).

set -uo pipefail

readonly EXIT_HEALTHY=0
readonly EXIT_HOOKS_CANNOT_RUN=1
readonly EXIT_COULD_NOT_RUN=2

readonly HOOKS_PATH_KEY=core.hooksPath
# `git config --get` exits with this status when the key is absent. Any other
# non-zero status is a config git could not read, which is not the same answer.
readonly GIT_CONFIG_KEY_ABSENT_STATUS=1

# The client-side hooks git looks up BY NAME. A file with any other name in the
# hooks directory is never run, however executable it is.
readonly CLIENT_HOOK_NAMES=(
  applypatch-msg pre-applypatch post-applypatch
  pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit
  pre-rebase post-checkout post-merge pre-push post-rewrite
  pre-auto-gc reference-transaction post-index-change
  sendemail-validate fsmonitor-watchman
)

readonly TRACKED_GITCONFIG_NAME=gitconfig
readonly LINK_CHECKER_NAME=check-links.sh
# check-links.sh exits with this when it could not read the manifest at all.
readonly LINK_CHECKER_COULD_NOT_RUN_STATUS=2

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE

if [[ -t 1 ]]; then
  readonly RED=$'\033[1;31m' GREEN=$'\033[0;32m' DIM=$'\033[2m' OFF=$'\033[0m'
else
  readonly RED='' GREEN='' DIM='' OFF=''
fi

# --- reporting ---------------------------------------------------------------

pass()        { printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$*"; }
not_checked() { printf '  %s·%s %s\n' "$DIM" "$OFF" "$*"; }
fault()       { printf '  %s✗%s %s\n' "$RED" "$OFF" "$*"; }

# Print why the check could not run, and stop. Never a pass.
could_not_run() {
  printf 'check-git-hooks: %s\n' "$*" >&2
  exit "$EXIT_COULD_NOT_RUN"
}

# Report a state in which the configured hooks cannot run, and stop.
#   $1 — what is wrong, in one line
#   $2 — how to fix it
hooks_cannot_run() {
  fault "$1"
  printf '      git runs no hooks in any repository that does not set its own %s.\n' "$HOOKS_PATH_KEY"
  printf '      Fix: %s\n' "$2"
  exit "$EXIT_HOOKS_CANNOT_RUN"
}

# --- shared ------------------------------------------------------------------

# Sort the hook-named files in a directory into two global arrays:
# RUNNABLE_HOOKS (regular and executable) and UNRUNNABLE_HOOKS (present, but not).
#   $1 — the hooks directory
classify_hooks_in() {
  local hooks_dir="$1" hook_name hook_file
  RUNNABLE_HOOKS=()
  UNRUNNABLE_HOOKS=()
  for hook_name in "${CLIENT_HOOK_NAMES[@]}"; do
    hook_file="$hooks_dir/$hook_name"
    [[ -e "$hook_file" || -L "$hook_file" ]] || continue
    if [[ -f "$hook_file" && -x "$hook_file" ]]; then
      RUNNABLE_HOOKS+=("$hook_name")
    else
      UNRUNNABLE_HOOKS+=("$hook_name")
    fi
  done
}

# Fail unless a directory holds at least one runnable hook and no unrunnable one.
#   $1 — the hooks directory
#   $2 — how to fix a fault in it
require_runnable_hooks_in() {
  local hooks_dir="$1" fix="$2"
  classify_hooks_in "$hooks_dir"
  if (( ${#UNRUNNABLE_HOOKS[@]} > 0 )); then
    local unrunnable_names="${UNRUNNABLE_HOOKS[*]}"
    hooks_cannot_run "$hooks_dir: not executable: $unrunnable_names — git skips a hook it cannot execute" "$fix"
  fi
  if (( ${#RUNNABLE_HOOKS[@]} == 0 )); then
    hooks_cannot_run "$hooks_dir holds no hook git would run" "$fix"
  fi
}

# --- the live machine --------------------------------------------------------

check_live_machine() {
  local configured_hooks_path git_config_status
  configured_hooks_path="$(git config --global --includes --type=path --get "$HOOKS_PATH_KEY" 2>/dev/null)"
  git_config_status=$?

  if (( git_config_status == GIT_CONFIG_KEY_ABSENT_STATUS )); then
    not_checked "$HOOKS_PATH_KEY is not set in the global git config — each repository's own .git/hooks applies"
    exit "$EXIT_HEALTHY"
  fi
  (( git_config_status == 0 )) ||
    could_not_run "could not read the global git config (git config exited $git_config_status)"

  if [[ "$configured_hooks_path" != /* ]]; then
    not_checked "$HOOKS_PATH_KEY = $configured_hooks_path is relative — git resolves it inside each repository, so there is no one directory to check"
    exit "$EXIT_HEALTHY"
  fi

  local install_fix="run ./install from the dotfiles checkout; if the path is still absent, its link is missing from install.conf.yaml"
  if [[ -L "$configured_hooks_path" && ! -e "$configured_hooks_path" ]]; then
    local dangling_target
    dangling_target="$(readlink "$configured_hooks_path" 2>/dev/null)"
    hooks_cannot_run "$HOOKS_PATH_KEY = $configured_hooks_path is a dangling symlink (to ${dangling_target:-an unreadable target})" "$install_fix"
  fi
  [[ -e "$configured_hooks_path" ]] ||
    hooks_cannot_run "$HOOKS_PATH_KEY = $configured_hooks_path does not exist" "$install_fix"
  [[ -d "$configured_hooks_path" ]] ||
    hooks_cannot_run "$HOOKS_PATH_KEY = $configured_hooks_path is not a directory" "$install_fix"

  require_runnable_hooks_in "$configured_hooks_path" "make the hook executable in the checkout (chmod +x), then ./install"
  local runnable_names="${RUNNABLE_HOOKS[*]}"
  pass "$HOOKS_PATH_KEY = $configured_hooks_path: ${#RUNNABLE_HOOKS[@]} hook(s) git will run ($runnable_names)"
}

# --- the checkout ------------------------------------------------------------

# Set the global DECLARED_LINK_SOURCE to the source install.conf.yaml declares for
# a link target, or to nothing.
#   $1 — the checkout
#   $2 — the declared target, as written in the manifest (e.g. ~/.config/git/hooks)
#
# It sets a global rather than printing, on purpose. Called as $(...) it would run
# in a subshell, where could_not_run's `exit 2` ends only the subshell: an
# unreadable manifest then reads as "declares no link there" and exits 1, which is
# the "I cannot tell" -> "here is the answer" slide this checker exists to stop.
find_declared_link_source() {
  local checkout="$1" declared_target="$2" link_table link_checker_status
  local link_checker="$HERE/$LINK_CHECKER_NAME"
  DECLARED_LINK_SOURCE=""
  [[ -x "$link_checker" ]] || could_not_run "$link_checker is missing — the link table is UNREAD"

  # Only the declared columns are read here, never the state column, so whether
  # the links exist on this machine does not matter and exit 1 is not an error.
  link_table="$("$link_checker" --tsv --root "$checkout" 2>/dev/null)"
  link_checker_status=$?
  (( link_checker_status != LINK_CHECKER_COULD_NOT_RUN_STATUS )) ||
    could_not_run "$LINK_CHECKER_NAME could not read the link table in $checkout/install.conf.yaml"

  DECLARED_LINK_SOURCE="$(awk -F'\t' -v wanted="${declared_target%/}" '
    { target = $2; sub(/\/$/, "", target) }
    target == wanted { print $3; exit }
  ' <<<"$link_table")"
}

check_checkout() {
  local checkout="$1"
  local tracked_gitconfig="$checkout/$TRACKED_GITCONFIG_NAME"
  [[ -r "$tracked_gitconfig" ]] || could_not_run "cannot read $tracked_gitconfig"

  local tracked_hooks_path git_config_status
  tracked_hooks_path="$(git config --file "$tracked_gitconfig" --get "$HOOKS_PATH_KEY" 2>/dev/null)"
  git_config_status=$?
  if (( git_config_status == GIT_CONFIG_KEY_ABSENT_STATUS )); then
    not_checked "the tracked $TRACKED_GITCONFIG_NAME sets no $HOOKS_PATH_KEY — nothing for install.conf.yaml to provide"
    exit "$EXIT_HEALTHY"
  fi
  (( git_config_status == 0 )) ||
    could_not_run "could not read $tracked_gitconfig (git config exited $git_config_status)"

  local declare_fix="add \"$tracked_hooks_path: <directory in this repo>\" under link: in install.conf.yaml, or drop $HOOKS_PATH_KEY from $TRACKED_GITCONFIG_NAME"
  find_declared_link_source "$checkout" "$tracked_hooks_path"
  local declared_source="$DECLARED_LINK_SOURCE"
  [[ -n "$declared_source" ]] ||
    hooks_cannot_run "$TRACKED_GITCONFIG_NAME sets $HOOKS_PATH_KEY = $tracked_hooks_path, and install.conf.yaml declares no link there" "$declare_fix"

  local source_dir="$checkout/$declared_source"
  [[ -d "$source_dir" ]] ||
    hooks_cannot_run "install.conf.yaml links $tracked_hooks_path to $declared_source, which is not a directory in this checkout" "$declare_fix"

  require_runnable_hooks_in "$source_dir" "chmod +x the hook and commit the mode change"
  local runnable_names="${RUNNABLE_HOOKS[*]}"
  pass "$tracked_hooks_path is linked to $declared_source: ${#RUNNABLE_HOOKS[@]} hook(s) git will run ($runnable_names)"
}

# --- main --------------------------------------------------------------------

IS_TRACKED_MODE=0
ROOT_ARG=""
while (( $# > 0 )); do
  case "$1" in
    --tracked) IS_TRACKED_MODE=1 ;;
    --root)
      [[ -n "${2:-}" ]] || could_not_run "--root needs a non-empty value"
      ROOT_ARG="$2"; shift ;;
    *) could_not_run "unknown argument '$1'" ;;
  esac
  shift
done

command -v git >/dev/null 2>&1 || could_not_run "git is not on PATH — hooks UNCHECKED"

if (( IS_TRACKED_MODE )); then
  CHECKOUT="${ROOT_ARG:-${REPO_ROOT:-$HERE/..}}"
  CHECKOUT="$(cd "$CHECKOUT" 2>/dev/null && pwd)" || could_not_run "no such checkout: ${ROOT_ARG:-${REPO_ROOT:-$HERE/..}}"
  check_checkout "$CHECKOUT"
else
  [[ -z "$ROOT_ARG" ]] || could_not_run "--root only applies with --tracked"
  check_live_machine
fi
exit "$EXIT_HEALTHY"
