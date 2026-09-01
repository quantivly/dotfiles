#!/usr/bin/env bash
#
# scripts/test-secret-guard.sh
# ============================
#
# State table for scripts/redact-secrets.sh and
# claude/hooks/secret-emission-guard.sh.
#
# Why this exists: on 2026-09-01 both of this machine's live GitHub tokens were
# found in plaintext in five Claude Code transcripts, two written days earlier.
# No dramatic mistake — ordinary diagnostics print secrets and everything
# printed is recorded. These two files attack the emission; this pins them.
#
# The rows fall into two groups, and the SECOND is the one that matters:
#
#   1. Does it block/redact what it should?  A miss costs a leaked credential.
#   2. Does it leave everything else alone?  A false positive costs the whole
#      guard, because a hook that refuses ordinary commands gets deleted within
#      a day and then protects nothing. Most rows here are group 2 on purpose.
#
# Requires: bash, jq, sed. No network, no secrets, no Claude Code.
#
# Usage: scripts/test-secret-guard.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDACT="$DOTFILES/scripts/redact-secrets.sh"
GUARD="$DOTFILES/claude/hooks/secret-emission-guard.sh"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

for t in jq sed; do command -v "$t" >/dev/null || fatal "missing required tool: $t"; done
[[ -x "$REDACT" ]] || fatal "not executable: $REDACT"
[[ -x "$GUARD"  ]] || fatal "not executable: $GUARD"

# Synthetic credentials, built at runtime so this file contains no string that
# looks like one — gitleaks and detect-private-key run over this repo in
# pre-commit, and a fixture that trips the repo's own scanners is a test nobody
# can commit. That is not hypothetical: the first version of this file pasted in
# a REAL session token as a fixture and spelled the private-key header out in
# full, and both were caught by those hooks. Every fixture below is assembled,
# never literal — including the low-entropy hex, which exists to prove that
# NAME-based redaction catches what shape-based redaction cannot see.
GHO="gho_$(printf 'A%.0s' {1..36})"
PAT="github_pat_$(printf 'B%.0s' {1..30})"
ANT="sk-ant-$(printf 'C%.0s' {1..40})"
AWS="AKIA$(printf 'D%.0s' {1..16})"

echo
echo "=== redact-secrets: the shapes it must catch ==="
red() { printf '%s' "$1" | "$REDACT"; }
check "github oauth token"  "$(red "tok=$GHO")"            "tok=<REDACTED:github-token>"
check "github fine-grained" "$(red "tok=$PAT")"            "tok=<REDACTED:github-pat>"
check "anthropic key"       "$(red "k=$ANT")"              "k=<REDACTED:anthropic-key>"
check "aws access key id"   "$(red "id=$AWS")"             "id=<REDACTED:aws-access-key-id>"
check "bearer header"       "$(red 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123')" \
                            "Authorization: Bearer <REDACTED:bearer>"
check "url password"        "$(red 'https://u:pw123456@h/x')" "https://u:<REDACTED:url-password>@h/x"
# Split so the literal header never appears in this file: it is exactly what
# pre-commit's detect-private-key greps for, and a fixture that trips the repo's
# own scanners is a test nobody can commit.
PKH="-----BEGIN RSA PRIV""ATE KEY-----"
check "private key header"  "$(red "${PKH}MIIEpAIBAAK")" "${PKH}<REDACTED:private-key>"
# Shape matching cannot know that 32 hex characters is a secret; name matching
# can, in the VAR=value shapes an env dump produces. Found by running the pair
# against a real printenv and seeing what survived.
HEX32="$(printf 'ab%.0s' {1..16})"   # 32 chars, deliberately low-entropy
check "secret by NAME, unguessable shape" \
      "$(red "CLAUDE_CODE_MESSAGING_TOKEN=$HEX32")" \
      "CLAUDE_CODE_MESSAGING_TOKEN=<REDACTED:by-name>"
check "…and other name suffixes" "$(red 'DB_PASSWORD=hunter2')" "DB_PASSWORD=<REDACTED:by-name>"

echo
echo "=== redact-secrets: what it must NOT touch ==="
# A redactor that mangles ordinary output gets removed from commands, and then
# it redacts nothing at all.
check "a 40-char git sha"    "$(red 'commit 9f3a2b1c4d5e6f708192a3b4c5d6e7f809a1b2c3')" \
                             "commit 9f3a2b1c4d5e6f708192a3b4c5d6e7f809a1b2c3"
check "a 32-hex md5"         "$(red 'md5 d41d8cd98f00b204e9800998ecf8427e')" \
                             "md5 d41d8cd98f00b204e9800998ecf8427e"
check "an ordinary VAR"      "$(red 'MY_VAR=hello')"        "MY_VAR=hello"
check "a lowercase token flag" "$(red 'curl --token=abc')"  "curl --token=abc"
check "prose"                "$(red 'the token is stored in the keyring')" \
                             "the token is stored in the keyring"
check "empty input"          "$(printf '' | "$REDACT")"     ""
# Streaming filter: it must not swallow the command's status.
check "exit status survives the pipe" \
      "$(bash -c "set -o pipefail; (echo x; exit 3) | '$REDACT' >/dev/null; echo \$?")" "3"
check "multi-line input is preserved line-for-line" \
      "$(printf 'a\nb\nc\n' | "$REDACT" | wc -l | tr -d ' ')" "3"

echo
echo "=== the guard: commands that must be REFUSED ==="
ask() {  # ask <command> -> "deny" | "allow"
  local d
  d="$(python3 -c "
import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]}}))" "$1" \
      | "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)"
  printf '%s' "${d:-allow}"
}
for c in \
  'gh auth token' \
  'gh auth token --user someone' \
  'gh auth status --show-token' \
  'ps aux' \
  'ps -ef | grep node' \
  'ps -o pid,args -p 1' \
  'pgrep -af claude' \
  'pgrep --list-full claude' \
  'env' \
  'printenv' \
  'cat /proc/123/cmdline' \
  'grep -a . /proc/self/environ'
do
  check "refuses: $c" "$(ask "$c")" "deny"
done

echo
echo "=== the guard: near misses that must be ALLOWED ==="
# Every one of these is a command someone runs constantly. A guard that refuses
# them is a guard that gets switched off, so these rows matter more than the
# ones above.
for c in \
  'ps -p 1234 -o comm=' \
  'ps -o pid,rss -p 1' \
  'ps --version' \
  'pgrep claude' \
  'env -u GH_TOKEN GH_CONFIG_DIR=/x gh api user' \
  'env VAR=1 make test' \
  'printenv GH_CONFIG_DIR' \
  'gh auth status' \
  'gh auth login' \
  'ls /proc' \
  'git commit -m "stop ps aux from dumping env"' \
  'echo "run printenv to debug"' \
  'grep -r "gh auth token" docs/'
do
  check "allows: $c" "$(ask "$c")" "allow"
done
# The escape hatch has to work, or the deny message is a dead end.
check "allows the redirected form" \
      "$(ask 'ps aux 2>&1 | ~/.dotfiles/scripts/redact-secrets.sh')" "allow"

echo
echo "=== the guard fails OPEN, always ==="
# A hook that blocks the shell when it breaks gets disabled wholesale, taking
# its protection with it. Every malformed input must allow.
#
# `jq // "allow"` is NOT enough to read the answer here: on EMPTY input jq emits
# nothing at all, so the default never fires and the row compares against "".
# Silence is precisely how this hook says allow, so the reader has to treat no
# output as allow — three rows failed for that reason before this wrapper.
decide() {  # decide < payload -> "deny" | "allow"
  local out
  out="$("$GUARD" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
  printf '%s' "${out:-allow}"
}
BASH_BIN="$(command -v bash)"
check "empty stdin"            "$(printf '' | decide)"                                  "allow"
check "not JSON"               "$(printf 'garbage' | decide)"                            "allow"
check "JSON without a command" "$(printf '{"tool_name":"Bash","tool_input":{}}' | decide)" "allow"
# PATH=/nonexistent has to keep bash itself reachable, or the row proves only
# that bash was missing.
check "no jq on PATH" \
      "$(printf '{"tool_input":{"command":"env"}}' \
         | PATH=/nonexistent "$BASH_BIN" "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; \
         printf 'allow')" "allow"
check "always exits 0"     "$(printf '{"tool_input":{"command":"env"}}' | "$GUARD" >/dev/null; echo $?)" "0"
# And the guard must still DENY through the same reader, or the rows above pass
# for the wrong reason (everything reading as allow).
check "the reader can still see a deny" \
      "$(printf '{"tool_input":{"command":"env"}}' | decide)" "deny"

echo
echo "=== the deny message has to be actionable ==="
msg="$(python3 -c "
import json; print(json.dumps({'tool_input':{'command':'env'}}))" | "$GUARD" \
      | jq -r '.hookSpecificOutput.permissionDecisionReason')"
check "names the redactor"   "$(printf '%s' "$msg" | grep -c 'redact-secrets')" "1"
check "says why it is a deny" "$(printf '%s' "$msg" | grep -c 'transcript')"    "1"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
