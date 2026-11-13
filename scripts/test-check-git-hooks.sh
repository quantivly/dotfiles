#!/usr/bin/env bash
#
# scripts/test-check-git-hooks.sh
# ===============================
#
# State table for scripts/check-git-hooks.sh.
#
# The rows this file exists for are "the configured directory does not exist"
# (the live machine, 2026-01-28 to 2026-11-13) and "gitconfig names a path
# install.conf.yaml does not link" (the checkout, over the same months). Every
# other row is here to stop the checker resolving "I cannot tell" to "fine": an
# unreadable config, a hooks path set through an include, a hook that is present
# and not executable, a directory full of files git would never run.
#
# Hermetic: every row builds its own HOME, or its own checkout, under a temp
# dir. Nothing reads the real global git config or the real link table.
#
# MUTANTS. Each was applied to a copy of the checker and run through this table
# (CHECK=<copy>); the rows named are the ones that fail under it.
#   M1  drop `--includes`                      -> "set through an include"
#   M2  drop `--type=path`                     -> "healthy: reports one hook"
#   M3  treat every non-zero `git config` as   -> "unreadable global config: exit 2"
#       "key absent"
#   M4  count any executable file as a hook    -> "only a non-hook file: exit 1"
#   M5  skip the unrunnable-hook check         -> "one runnable, one not: exit 1",
#                                                 "pre-commit not executable: names it"
#   M6  skip the dangling-symlink branch       -> "dangling symlink: says dangling"
#   M7  (--tracked) accept an undeclared path  -> "undeclared: says no link is declared"
#   M8  (--tracked) skip the source-dir check  -> "declared source missing: says so"
#   M9  (--tracked) read the link table in a   -> "a manifest with no link block: exit 2"
#       $(...) subshell, so its exit 2 is lost    (this one was the first draft, not a
#                                                  hypothetical: the row caught it)
#   M10 (--tracked) treat every non-zero       -> "unreadable tracked gitconfig: exit 2"
#       `git config` as "key absent"              (survived the first sweep; the row was
#                                                  added for it)
#
# M5, M7 and M8 leave the exit status at 1 and change only the REASON, so it is the
# "names it" / "says so" rows that pin them. An exit-status row alone would not.
#
# Usage: scripts/test-check-git-hooks.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${CHECK:-$HERE/check-git-hooks.sh}"
BASH_BIN="$(command -v bash)"

PASS=0; FAIL=0
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1 — output lacked '$3'"; fi; }
hasnt(){ if grep -qF -- "$3" <<<"$2"; then bad "$1 — output contained '$3'"; else ok "$1"; fi; }
[[ -x "$CHECK" ]] || { printf 'FATAL: not executable: %s\n' "$CHECK" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
n=0

# The tick the checker prints for a pass. A "nothing to check" state must never carry it.
readonly PASS_TICK='✓'
# The literal text gitconfig and install.conf.yaml both carry; git and the link
# checker expand it, so the quoted tilde is deliberate.
# shellcheck disable=SC2088
readonly HOOKS_PATH_IN_HOME='~/.config/git/hooks'

# --- the live machine --------------------------------------------------------

# Build a home: $1 = the global gitconfig body. SETS the global H. (A global, not
# an echo read back through $(...): that runs in a subshell, where `n` increments
# and then dies with it, so every row would share one directory.)
home_with_gitconfig() {
  n=$((n+1))
  H="$TMP/h$n"
  mkdir -p "$H"
  printf '%s' "$1" > "$H/.gitconfig"
}

# Put a hook-shaped file in the hooks directory of $H. $1 = name, $2 = mode.
add_hook() {
  mkdir -p "$H/.config/git/hooks"
  printf '#!/bin/sh\nexit 0\n' > "$H/.config/git/hooks/$1"
  chmod "$2" "$H/.config/git/hooks/$1"
}

live()    { HOME="$1" XDG_CONFIG_HOME="$1/.config" GIT_CONFIG_NOSYSTEM=1 "$BASH_BIN" "$CHECK" 2>&1; }
live_rc() { HOME="$1" XDG_CONFIG_HOME="$1/.config" GIT_CONFIG_NOSYSTEM=1 "$BASH_BIN" "$CHECK" >/dev/null 2>&1; printf '%s' "$?"; }

GITCONFIG_WITH_HOOKS_PATH="[core]
	hooksPath = $HOOKS_PATH_IN_HOME
"

echo
echo "=== the live machine: nothing to check ==="

home_with_gitconfig '[core]
	editor = true
'
out="$(live "$H")"
check "hooksPath unset: exit 0" "$(live_rc "$H")" "0"
has   "hooksPath unset: says it is not set" "$out" "is not set in the global git config"
hasnt "hooksPath unset: is not reported as a pass" "$out" "$PASS_TICK"

home_with_gitconfig '[core]
	hooksPath = .githooks
'
out="$(live "$H")"
check "relative hooksPath: exit 0" "$(live_rc "$H")" "0"
has   "relative hooksPath: says it is resolved per repository" "$out" "is relative"
hasnt "relative hooksPath: is not reported as a pass" "$out" "$PASS_TICK"

echo
echo "=== the live machine: healthy ==="

home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
add_hook pre-commit 0755
out="$(live "$H")"
check "healthy: exit 0" "$(live_rc "$H")" "0"
has   "healthy: reports one hook" "$out" "1 hook(s) git will run (pre-commit)"

# The deployed shape: the hooks directory is a symlink into a checkout.
home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
mkdir -p "$H/checkout/config/git/hooks" "$H/.config/git"
printf '#!/bin/sh\nexit 0\n' > "$H/checkout/config/git/hooks/pre-commit"
chmod 0755 "$H/checkout/config/git/hooks/pre-commit"
ln -s "$H/checkout/config/git/hooks" "$H/.config/git/hooks"
check "hooks directory is a symlink into a checkout: exit 0" "$(live_rc "$H")" "0"

echo
echo "=== the live machine: the hooks cannot run ==="

home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
out="$(live "$H")"
check "directory does not exist: exit 1" "$(live_rc "$H")" "1"
has   "directory does not exist: says so" "$out" "does not exist"
has   "directory does not exist: states the consequence" "$out" "git runs no hooks in any repository"

home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
mkdir -p "$H/.config/git"
ln -s "$H/removed-worktree/config/git/hooks" "$H/.config/git/hooks"
out="$(live "$H")"
check "dangling symlink: exit 1" "$(live_rc "$H")" "1"
has   "dangling symlink: says dangling" "$out" "is a dangling symlink"

home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
mkdir -p "$H/.config/git"
printf 'not a directory\n' > "$H/.config/git/hooks"
out="$(live "$H")"
check "a regular file at the path: exit 1" "$(live_rc "$H")" "1"
has   "a regular file at the path: says so" "$out" "is not a directory"

home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
mkdir -p "$H/.config/git/hooks"
out="$(live "$H")"
check "empty directory: exit 1" "$(live_rc "$H")" "1"
has   "empty directory: says it holds no hook" "$out" "holds no hook git would run"

home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
add_hook README.md 0755
check "only a non-hook file: exit 1" "$(live_rc "$H")" "1"

home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
add_hook pre-commit 0644
out="$(live "$H")"
check "pre-commit not executable: exit 1" "$(live_rc "$H")" "1"
has   "pre-commit not executable: names it" "$out" "not executable: pre-commit"

home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
add_hook pre-commit 0755
add_hook commit-msg 0644
out="$(live "$H")"
check "one runnable, one not: exit 1" "$(live_rc "$H")" "1"
has   "one runnable, one not: names the one git would skip" "$out" "not executable: commit-msg"

# The path arrives through an include, as it would from ~/.gitconfig.local.
home_with_gitconfig '[include]
	path = .gitconfig.included
'
printf '%s' "$GITCONFIG_WITH_HOOKS_PATH" > "$H/.gitconfig.included"
check "set through an include: exit 1 on the missing directory" "$(live_rc "$H")" "1"

echo
echo "=== the live machine: could not tell ==="

home_with_gitconfig '[core
	hooksPath = oops
'
out="$(live "$H")"
check "unreadable global config: exit 2" "$(live_rc "$H")" "2"
has   "unreadable global config: says it could not read it" "$out" "could not read the global git config"

home_with_gitconfig "$GITCONFIG_WITH_HOOKS_PATH"
add_hook pre-commit 0755
check "git not on PATH: exit 2" "$(HOME="$H" PATH="$TMP/no-such-bin" "$BASH_BIN" "$CHECK" >/dev/null 2>&1; printf '%s' "$?")" "2"

check "unknown argument: exit 2" "$("$BASH_BIN" "$CHECK" --bogus >/dev/null 2>&1; printf '%s' "$?")" "2"

# --- the checkout ------------------------------------------------------------

# Build a checkout: $1 = tracked gitconfig body, $2 = install.conf.yaml body. SETS R.
checkout_with() {
  n=$((n+1))
  R="$TMP/r$n"
  mkdir -p "$R"
  printf '%s' "$1" > "$R/gitconfig"
  printf '%s' "$2" > "$R/install.conf.yaml"
}

# Put a hook-shaped file in the checkout's hooks source. $1 = name, $2 = mode.
add_tracked_hook() {
  mkdir -p "$R/config/git/hooks"
  printf '#!/bin/sh\nexit 0\n' > "$R/config/git/hooks/$1"
  chmod "$2" "$R/config/git/hooks/$1"
}

tracked()    { HOME="$TMP/unused-home" GIT_CONFIG_NOSYSTEM=1 "$BASH_BIN" "$CHECK" --tracked --root "$1" 2>&1; }
tracked_rc() { HOME="$TMP/unused-home" GIT_CONFIG_NOSYSTEM=1 "$BASH_BIN" "$CHECK" --tracked --root "$1" >/dev/null 2>&1; printf '%s' "$?"; }

MANIFEST_DECLARING_HOOKS="- link:
    ~/.config/git/ignore: config/git/ignore
    $HOOKS_PATH_IN_HOME: config/git/hooks
"
MANIFEST_WITHOUT_HOOKS='- link:
    ~/.config/git/ignore: config/git/ignore
'

echo
echo "=== the checkout ==="

checkout_with "$GITCONFIG_WITH_HOOKS_PATH" "$MANIFEST_DECLARING_HOOKS"
add_tracked_hook pre-commit 0755
out="$(tracked "$R")"
check "declared and runnable: exit 0" "$(tracked_rc "$R")" "0"
has   "declared and runnable: names the source" "$out" "is linked to config/git/hooks"

# The state the repository was in from edabe60 until this check was written.
checkout_with "$GITCONFIG_WITH_HOOKS_PATH" "$MANIFEST_WITHOUT_HOOKS"
add_tracked_hook pre-commit 0755
out="$(tracked "$R")"
check "undeclared: exit 1" "$(tracked_rc "$R")" "1"
has   "undeclared: says no link is declared" "$out" "declares no link there"

checkout_with "$GITCONFIG_WITH_HOOKS_PATH" "$MANIFEST_DECLARING_HOOKS"
out="$(tracked "$R")"
check "declared source missing: exit 1" "$(tracked_rc "$R")" "1"
has   "declared source missing: says so" "$out" "is not a directory in this checkout"

checkout_with "$GITCONFIG_WITH_HOOKS_PATH" "$MANIFEST_DECLARING_HOOKS"
add_tracked_hook pre-commit 0644
out="$(tracked "$R")"
check "tracked hook lost its executable bit: exit 1" "$(tracked_rc "$R")" "1"
has   "tracked hook lost its executable bit: names it" "$out" "not executable: pre-commit"

checkout_with '[core]
	editor = true
' "$MANIFEST_WITHOUT_HOOKS"
out="$(tracked "$R")"
check "tracked gitconfig sets no hooksPath: exit 0" "$(tracked_rc "$R")" "0"
hasnt "tracked gitconfig sets no hooksPath: is not reported as a pass" "$out" "$PASS_TICK"

checkout_with "$GITCONFIG_WITH_HOOKS_PATH" '- shell:
    - [true, nothing declared]
'
check "a manifest with no link block: exit 2, never a pass" "$(tracked_rc "$R")" "2"

check "no such checkout: exit 2" "$(tracked_rc "$TMP/no-such-checkout")" "2"

checkout_with '[core
	hooksPath = oops
' "$MANIFEST_DECLARING_HOOKS"
check "unreadable tracked gitconfig: exit 2" "$(tracked_rc "$R")" "2"

# --- this repository ---------------------------------------------------------

echo
echo "=== this repository ==="

check "the real checkout links the path its gitconfig names" "$(REPO_ROOT="$HERE/.." "$BASH_BIN" "$CHECK" --tracked >/dev/null 2>&1; printf '%s' "$?")" "0"

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
EXPECTED_ROWS=42
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mROW COUNT\033[0m: expected %d rows, %d ran — a check vanished or was added without updating EXPECTED_ROWS\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 1
fi
[[ "$FAIL" -eq 0 ]]
