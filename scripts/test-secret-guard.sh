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
# Notion and Linear, added 2026-09-07 after a NOTION_PAT went through this
# script untouched. It mattered more than an ordinary miss: DO-576 had just made
# the emission guard refuse `tail ~/.zshrc.local` and name THIS script as the
# remedy, so the token printed in full through the very pipe the deny message
# recommends. `NOTION_PAT` matched no name pattern ("PAT" was absent from the
# alternation) and `ntn_` matched no shape pattern — both rules missed, which is
# the exact case the header says two rules exist to prevent.
NTN="ntn_$(printf 'f%.0s' {1..43})"
LIN="lin_api_$(printf 'g%.0s' {1..40})"
check "notion token by name"  "$(red "NOTION_PAT=$NTN")"  "NOTION_PAT=<REDACTED:by-name>"
check "notion token by shape, bare in prose" \
      "$(red "see $NTN here")" "see <REDACTED:notion-token> here"
check "linear key by shape, bare in prose" \
      "$(red "see $LIN here")" "see <REDACTED:linear-key> here"
check "linear key by name too" "$(red "LINEAR_API_KEY=$LIN")" \
                               "LINEAR_API_KEY=<REDACTED:by-name>"

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
# The `_PAT` rule's anchoring, and these rows are why it is its own -e rule
# rather than another entry in the alternation. That alternation is followed by
# `[A-Z0-9_]*=`, so any form of PAT inside it has the trailing class absorb
# whatever follows: measured, both `PAT` and `_PAT` there redact SOME_PATH=,
# MY_PATHS= and COMPATIBLE=. Those three rows pin that mutation.
#
# PATH= and PATTERN= are safe for a simpler reason -- the `=` adjacency, since
# both have a character between PAT and the `=`. They are pinned by a different
# mutation: a rule allowing PAT anywhere before the `=`. Stated because an
# earlier version of this comment had it wrong, claiming naked `PAT` in the
# alternation swallowed PATH= (it does not; the leading `[A-Z]` eats the `P`),
# and a justification nobody can reproduce is worse than none.
check "PATH is not a PAT"     "$(red 'PATH=/usr/bin:/bin')"  "PATH=/usr/bin:/bin"
check "nor is SOME_PATH"      "$(red 'SOME_PATH=/x/y')"      "SOME_PATH=/x/y"
check "nor MY_PATHS"          "$(red 'MY_PATHS=/a:/b')"      "MY_PATHS=/a:/b"
check "nor COMPATIBLE"        "$(red 'COMPATIBLE=yes')"      "COMPATIBLE=yes"
check "nor PATTERN"           "$(red 'PATTERN=foo')"         "PATTERN=foo"
check "a short ntn_ word is not a token" "$(red 'ntn_short')" "ntn_short"
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
echo "=== reading a file that HOLDS credentials ==="
# Every rule above catches a command that prints a secret it FETCHED. None
# caught a command that prints a FILE -- and CLAUDE.md's Security Rules send
# every secret on the machine to ~/.zshrc.local, so the guard covered every
# emission shape except the documented home of all of them.
#
# On 2026-09-07 an agent ran `tail -8 ~/.zshrc.local` to find where to append a
# pathadd line. The tail of that file held a live LINEAR_API_KEY and a
# NOTION_PAT; both reached the transcript and had to be rotated. Same class as
# the 2026-09-01 incident that created this hook.
for c in \
  'tail -8 ~/.zshrc.local' \
  'cat ~/.zshrc.local' \
  'grep TOKEN ~/.zshrc.local' \
  'source ~/.zshrc.local' \
  'head -20 /home/zvi/.backup.local' \
  'less ~/.gitconfig.local' \
  'cat ~/.claude/.credentials.json'
do
  check "refuses: $c" "$(ask "$c")" "deny"
done
# The QUOTED path is the row that decides whether this rule works at all.
# $probe has quoted strings stripped, so a rule matching the path on $probe
# would miss the most natural spelling. Hence path-on-$cmd, verb-on-$probe.
# shellcheck disable=SC2016  # the $HOME must reach the guard UNEXPANDED -- an
# expanded /home/zvi/... would test a different string than the one this row is
# about, which is a command whose path only exists inside double quotes.
check "refuses the quoted path, which \$probe cannot see" \
      "$(ask 'cat "$HOME/.zshrc.local"')" "deny"

echo
echo "=== ...without refusing the commands people actually run on it ==="
# Group 2, and it matters more than the group above. Naming the file is not
# reading it, and metadata is not content. A guard that refuses `ls` on a path,
# or a commit message that mentions it, gets switched off within a day.
for c in \
  'git commit -m "move flyctl to ~/.zshrc.local"' \
  'echo "secrets live in ~/.zshrc.local"' \
  'ls -l ~/.zshrc.local' \
  'stat -c %y ~/.zshrc.local' \
  'test -f ~/.zshrc.local && echo yes' \
  'wc -l ~/.zshrc.local' \
  'readlink -f ~/.zshrc.local' \
  'cat ~/.zshrc' \
  'grep -n pathadd ~/.dotfiles/zshrc'
do
  check "allows: $c" "$(ask "$c")" "allow"
done
check "allows the redacted read — the remedy the deny message names" \
      "$(ask 'tail -8 ~/.zshrc.local | ~/.dotfiles/scripts/redact-secrets.sh')" "allow"

echo
echo "=== ...and the verb must be reading THE FILE, not merely present ==="
# The rule's two conditions were independent existence tests over the WHOLE
# command string, so nothing tied the verb to the file: any compound command
# that named a credential file anywhere and read some OTHER file anywhere was
# refused. Hit on 2026-09-09 while authoring documentation about
# ~/.gitconfig.local and then grepping the draft to check the result. Group 2,
# and the kind of row that decides whether the hook survives the week.
check "allows: the verb reads a different file" \
      "$(ask 'head -5 README.md && echo mentions ~/.zshrc.local')" "allow"
check "allows: the verb is in an unrelated later segment" \
      "$(ask 'echo ~/.zshrc.local > notes.txt; sed -n 1p README.md')" "allow"

# A heredoc BODY is content being WRITTEN, not a file being read — even when the
# prose inside it names a credential file next to a reading verb.
authoring_prose="$(printf '%s\n' \
  'python3 - <<PY' \
  "s = 'the ~/.gitconfig.local file carries the work identity'" \
  'PY' \
  'grep -n hasconfig NOTES.md')"
check "allows: authoring prose about the file, then grepping the draft" \
      "$(ask "$authoring_prose")" "allow"

heredoc_prose="$(printf '%s\n' \
  "cat > doc.md <<'PY'" \
  'never cat ~/.zshrc.local in a transcript' \
  'PY')"
check "allows: a reading verb inside heredoc prose" \
      "$(ask "$heredoc_prose")" "allow"

# ...while a read in ANY segment is still a read. Segmenting the command must not
# become a way to smuggle one past the rule.
check "refuses: the read is in the second segment" \
      "$(ask 'cd /tmp && cat ~/.gitconfig.local')" "deny"
check "refuses: redirected into a reader" \
      "$(ask 'grep KEY < ~/.zshrc.local')" "deny"
check "refuses: piped onward to another command" \
      "$(ask 'cat ~/.zshrc.local | sort')" "deny"

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
