#!/usr/bin/env bash
#
# scripts/test-claude-config-audit.sh
# ===================================
#
# State table for scripts/claude-config-audit.sh: collecting every agent host's
# Claude Code configuration into one workspace, and reporting where hosts agree.
#
# HERMETIC. Every row runs against a workspace under mktemp -d. Nothing here
# reaches a real host: ssh is replaced through CLAUDE_CONFIG_AUDIT_SSH where a row
# needs it, and the argument-validation rows below stop before any ssh happens.
# Requires: bash, jq, tar, sha256sum.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/claude-config-audit.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()   { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — '$3' not in: ${2:0:600}"; fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 — '$3' unexpectedly in: ${2:0:600}"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for tool in bash jq tar sha256sum; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
[[ -x "$SUT" ]] || fatal "$SUT is not executable — every row below would assert nothing"
if git -C "$TMPROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    fatal "$TMPROOT is inside a git repository; the fixtures would resolve against it"
fi

# ---------------------------------------------------------------------------------------------
# Usage and argument validation
# ---------------------------------------------------------------------------------------------

printf 'usage: no verb → exit 64 and the usage text\n'
out=$("$SUT" 2>&1); rc=$?
# This line appears only in the usage block; usage_error's own message never contains it.
USAGE_ONLY_NEEDLE='--host NAME=ALIAS:CFGDIR'
prints_usage=no; [[ "$out" == *"$USAGE_ONLY_NEEDLE"* ]] && prints_usage=yes
check "no verb: exit 64, usage text printed" "$rc $prints_usage" "64 yes"

printf 'usage: --help → exit 0\n'
help_stdout=$("$SUT" --help 2>/dev/null); rc=$?
help_prints_usage=no; [[ "$help_stdout" == *"$USAGE_ONLY_NEEDLE"* ]] && help_prints_usage=yes
check "--help: exit 0, usage text on stdout" "$rc $help_prints_usage" "0 yes"

printf 'usage: a host alias with a space or semicolon → exit 64, nothing created\n'
WS_NEVER="$TMPROOT/ws-never"
"$SUT" --collect --workspace "$WS_NEVER" --host 'x=bad host;rm:.claude' >/dev/null 2>&1; rc=$?
workspace_state=absent; [[ -e "$WS_NEVER" ]] && workspace_state=exists
check "bad alias: exit 64 and no workspace created" "$rc $workspace_state" "64 absent"

printf 'usage: a config dir not starting with a dot → exit 64\n'
"$SUT" --collect --workspace "$WS_NEVER" --host 'x=x:claude' >/dev/null 2>&1; rc=$?
check "config dir without a leading dot: exit 64" "$rc" 64

printf '\n'
EXPECTED_ROWS=4
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
