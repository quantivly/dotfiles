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
# Overridable so a candidate can be tested WITHOUT copying it over the live
# hook. The hook is symlinked into ~/.claude/hooks, so installing an unproven
# guard to run the suite would weaken the running shell for the length of the
# edit — which is the window this suite exists to keep closed.
REDACT="${REDACT:-$DOTFILES/scripts/redact-secrets.sh}"
GUARD="${GUARD:-$DOTFILES/claude/hooks/secret-emission-guard.sh}"

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
# The VPN shapes (DO-692). The host is split and the blob assembled for the same
# reason as everything above: this file must contain no string that reads as a
# live SAML re-auth URL. Written with the Write tool rather than a heredoc --
# claude/hooks/secret-emission-guard.sh matches the SHELL STRING, so a heredoc
# carrying a SAML auth URL is refused before it ever reaches disk.
# The blob carries percent-encoding, because a real one does: the value is
# deflate+base64 then URL-encoded, so +, / and = arrive as %2B, %2F and %3D. A
# fixture of plain base64 let a mutant that dropped % from the character class
# survive a sweep -- the rule still matched, just not to the end of the value.
SAMLBLOB="$(printf 'fVNdb5swFP0r%%2Bx%%2Fy%%3D%.0s' {1..4})"
SAMLHOST="accounts.google"".""com"
SAMLURL="https://${SAMLHOST}/o/saml2/idp?idpid=C02zy1e8o&SAMLRequest=${SAMLBLOB}"

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
# The AWS Client VPN shapes, added 2026-09-23 (DO-692). Both were measured
# passing through this script COMPLETELY UNCHANGED before the rules existed.
# Both are shape rules: they appear bare in a log line and inside a URL, never as
# VAR=value, so no name rule can reach them -- the same two-rules-or-it-leaks
# argument the header makes, in its third instance.
check "saml request inside a re-auth URL" \
      "$(red "Attempting to open browser with URL: $SAMLURL")" \
      "Attempting to open browser with URL: https://${SAMLHOST}/o/saml2/idp?idpid=C02zy1e8o&SAMLRequest=<REDACTED:saml-request>"
check "vpn re-auth challenge" \
      "$(red "AUTH_FAILED,CRV1:R:instance-0a1b2c3d:${SAMLBLOB}")" \
      "AUTH_FAILED,CRV1:<REDACTED:vpn-auth-challenge>"
# The challenge value is dropped to the first whitespace, not to end of line: the
# client writes the user's name after it, and a rule eating the rest of the line
# would take the surrounding log context with it.
check "the challenge stops at whitespace" \
      "$(red "AUTH_FAILED,CRV1:R:instance-0a1b:${SAMLBLOB} connecting")" \
      "AUTH_FAILED,CRV1:<REDACTED:vpn-auth-challenge> connecting"
# Belt to the two rows above: no base64-shaped run of the blob survives anywhere,
# whatever the surrounding text. An equality row pins one spelling; this pins the
# property.
check "no 20+ char blob survives either shape" \
      "$(red "$SAMLURL AUTH_FAILED,CRV1:R:i:${SAMLBLOB}" \
         | grep -oE '[A-Za-z0-9%+/=_-]{20,}' | grep -vc 'REDACTED')" "0"

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
# The VPN rules must not mangle the two log lines vpn-sweeps counts. These are
# the ground truth for every number this feature reports -- redacting them would
# make the reporter read zero forever and look like a fix that worked. Note the
# vendor's spelling of "Succesfully"; it is matched exactly, so it is written
# exactly here too.
check "the ACS request line is untouched" \
      "$(red 'SAML ACS received a request: http://127.0.0.1:35001/ from Mozilla/5.0')" \
      'SAML ACS received a request: http://127.0.0.1:35001/ from Mozilla/5.0'
check "the assertion line is untouched" \
      "$(red 'Succesfully retrieved and validated assertion')" \
      'Succesfully retrieved and validated assertion'
check "a bare AUTH_FAILED is prose"   "$(red 'AUTH_FAILED')"    'AUTH_FAILED'
# The CRV1 rule takes one-or-more, not zero-or-more: with `*` the marker is
# appended to a prefix carrying no value at all, which mangles prose for no gain.
# Nothing else in this file exercises that distinction.
check "an empty CRV1 challenge is prose" \
      "$(red 'AUTH_FAILED,CRV1:')" 'AUTH_FAILED,CRV1:'
check "an empty SAMLRequest is prose" "$(red 'SAMLRequest=')"   'SAMLRequest='
check "the word SAMLRequest in prose" \
      "$(red 'the SAMLRequest parameter is described in the SAML 2.0 spec')" \
      'the SAMLRequest parameter is described in the SAML 2.0 spec'
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

# A heredoc body is data being written, not a file being read — but the guard
# does NOT strip heredoc bodies, and that is deliberate. A stripper has to guess
# where the body ends, and every wrong guess DELETES the rest of the command
# from the rule's view, which is a leak: `cat <<-X` with a tab-indented
# terminator, a mismatched terminator, or a `<<` inside a quoted string each
# swallowed a following real read. Over-stripping leaks; not stripping only
# costs this one false positive, on unquoted prose that names a credential file
# right next to a reading verb. Quoted prose — the usual shape when generating
# code or docs — is already allowed by the row above, because the verb test runs
# on the quote-stripped segment.
heredoc_prose="$(printf '%s\n' \
  "cat > doc.md <<'PY'" \
  'never cat ~/.zshrc.local in a transcript' \
  'PY')"
check "refuses: unquoted prose in a heredoc (known, accepted FP)" \
      "$(ask "$heredoc_prose")" "deny"

# The separators that split a command must be the ones the SHELL would treat as
# separators — not any `;` or `|` character. A `;` or `|` inside a quoted script
# argument is data, and splitting on it tears the verb away from the filename,
# which is a miss. Every row here dumps the file and every one was allowed by
# the first version of the segmenting rule.
check "refuses: grep -E with a quoted alternation" \
      "$(ask "grep -E 'a|b' ~/.zshrc.local")" "deny"
check "refuses: sed with a quoted multi-address script" \
      "$(ask "sed -n '1,5p;10p' ~/.zshrc.local")" "deny"
check "refuses: sed script whose whole body is 'p;'" \
      "$(ask "sed -n 'p;' ./.zshrc.local")" "deny"
check "refuses: awk with a quoted pipe as field separator" \
      "$(ask "awk -F'|' '{print \$2}' ~/.zshrc.local")" "deny"
check "refuses: grep pattern containing a semicolon" \
      "$(ask "grep 'a;b' ~/.zshrc.local")" "deny"

# A newline is the separator the segmenter is most likely to get wrong, because
# it is BOTH the commonest real separator and, in two places, not a separator at
# all. The first version protected `;` and `|` inside quotes but not `\n`, and
# the suite could not tell that build from a fixed one -- these five rows are
# what closes that blind spot.
#
#   backslash-newline is a line continuation: the shell deletes both characters
#   and joins the lines, so it must not end a segment.
bs_nl_cat="$(printf '%s\n' $'cat \\' '  ~/.zshrc.local')"
check "refuses: read split by a line continuation" \
      "$(ask "$bs_nl_cat")" "deny"
bs_nl_grep="$(printf '%s\n' $'grep -n TOKEN \\' '  ~/.zshrc.local')"
check "refuses: grep split by a line continuation" \
      "$(ask "$bs_nl_grep")" "deny"
# ...and a line continuation can rejoin a word mid-verb, so the backslash and
# the newline must both vanish rather than becoming whitespace.
bs_nl_word="$(printf '%s\n' $'ca\\' 't ~/.zshrc.local')"
check "refuses: a verb rejoined across a line continuation" \
      "$(ask "$bs_nl_word")" "deny"

# ...and a backslash-newline INSIDE quotes is two different things depending on
# WHICH quote, which is why the scan has a separate branch for it. Inside double
# quotes bash removes both characters and joins; inside single quotes it does
# neither, and both stay literal data.
#
# These two rows are a PAIR on purpose, and neither works alone. A "both must
# deny" pair -- the obvious spelling -- cannot fail: nothing inside quotes ever
# splits a segment, so every build denies both and the rows assert nothing.
# What discriminates is a filename straddling the continuation, where the two
# quotings name two different files: one that exists and one that does not.
# shellcheck disable=SC1003  # a literal backslash-newline is the whole point of the row
dq_bs_path="$(printf '%s\n' 'cat "~/.zshrc.loc\' 'al"')"
check "refuses: a path rejoined across a continuation in DOUBLE quotes" \
      "$(ask "$dq_bs_path")" "deny"
# shellcheck disable=SC1003  # a literal backslash-newline is the whole point of the row
sq_bs_path="$(printf '%s\n' 'cat '"'"'~/.zshrc.loc\' 'al'"'"'')"
check "allows: single quotes do NOT join, so that is a different filename" \
      "$(ask "$sq_bs_path")" "allow"
# shellcheck disable=SC1003  # a literal backslash-newline is the whole point of the row
dq_bs_pat="$(printf '%s\n' 'grep -e "foo\' 'bar" ~/.zshrc.local')"
check "refuses: a double-quoted pattern rejoined across a continuation" \
      "$(ask "$dq_bs_pat")" "deny"

#   a newline INSIDE quotes is data -- a multi-line awk or sed script is one
#   command, exactly as a quoted `;` is one command.
multiline_awk="$(printf '%s\n' "awk '" '/PATH/ {print}' "' ~/.zshrc.local")"
check "refuses: multi-line quoted awk script" \
      "$(ask "$multiline_awk")" "deny"
multiline_pat="$(printf '%s\n' 'grep -E "foo' 'bar" ~/.zshrc.local')"
check "refuses: quoted pattern spanning a newline" \
      "$(ask "$multiline_pat")" "deny"

# A pipeline is ONE unit of data flow, so it is never split: the file named in
# one stage is read by a verb in another.
check "refuses: the path is piped into the reader" \
      "$(ask 'echo ~/.zshrc.local | xargs cat')" "deny"

# A `;` or newline that merely introduces a compound-command KEYWORD is not a
# command boundary. `for f in <file>; do cat $f; done` names the file in the
# loop header and reads it in the body -- one command -- and splitting at the
# `;` tore the two apart, so the read was allowed.
#
# A loop written over several lines has TWO such separators, one either side of
# the keyword, and merging only the first still leaves the header and the body
# in different segments. That is the same shape in the spelling people actually
# write, so both are rows.
# shellcheck disable=SC2016  # the loop variable must reach the guard UNEXPANDED
loop_oneline='for f in ~/.zshrc.local; do cat $f; done'
check "refuses: the loop header names the file, the body reads it" \
      "$(ask "$loop_oneline")" "deny"
# shellcheck disable=SC2016  # the loop variable must reach the guard UNEXPANDED
loop_multiline="$(printf '%s\n' 'for f in ~/.zshrc.local' 'do' '  cat $f' 'done')"
check "refuses: ...the same loop written over four lines" \
      "$(ask "$loop_multiline")" "deny"
# shellcheck disable=SC2016  # the loop variable must reach the guard UNEXPANDED
loop_semi_nl="$(printf '%s\n' 'for f in ~/.zshrc.local;' 'do cat $f; done')"
check "refuses: ...with both a semicolon and a newline before the keyword" \
      "$(ask "$loop_semi_nl")" "deny"

# Group 2, and these are the rows that decide whether the keyword list stays
# narrow. Every one of them passes on a build that merges on EVERY
# compound-command keyword, or on one that matches keywords by prefix -- so
# each names the single change that would break it.
#
# `then` and `else` are deliberately NOT merge keywords. Merging them refuses
# an ordinary existence test whose body reads some other file, which is the
# `&&` spelling the suite already asserts is allowed a few rows above.
check "allows: an existence test whose THEN branch reads another file" \
      "$(ask 'if [ -f ~/.zshrc.local ]; then cat README.md; fi')" "allow"
check "allows: ...and whose ELSE branch does" \
      "$(ask 'if [ -f ~/.zshrc.local ]; then echo yes; else head -1 README.md; fi')" "allow"
# The keyword is compared WHOLE. A prefix test merges `do_thing` and `docker`.
# Each of these needs a reading VERB in the second half, or the row cannot
# tell a prefix match from a whole-word one: merging a segment that contains
# no verb changes no decision, so the obvious spelling (`; docker inspect x`)
# passes on a prefix-matching build and pins nothing.
check "allows: a later command merely STARTING with the keyword" \
      "$(ask 'echo ~/.zshrc.local; do_thing README.md | head -3')" "allow"
check "allows: ...including docker, which begins with do" \
      "$(ask 'echo ~/.zshrc.local; docker logs web | grep error')" "allow"
# The far-side merge is one-shot and fires only for a keyword this scan ALREADY
# merged into -- i.e. one a separator introduced. A plain look-behind, which is
# the obvious simplification, would merge the word `do` out of any command.
check "allows: a command ending in the bare word do" \
      "$(ask 'echo ~/.zshrc.local do; head -1 README.md')" "allow"
# An ordinary loop over ordinary files stays ordinary.
# shellcheck disable=SC2016  # the loop variable must reach the guard UNEXPANDED
check "allows: a loop over unrelated files" \
      "$(ask 'for f in *.md; do grep x $f; done')" "allow"
# shellcheck disable=SC2016  # the loop variable must reach the guard UNEXPANDED
check "allows: ...and one that mentions the file in a LATER segment" \
      "$(ask 'for f in *.md; do grep x $f; done; echo see ~/.zshrc.local')" "allow"

# Heredoc shapes that a body-stripper would have mis-terminated, each followed by
# a real read that must still be seen.
hd_dash="$(printf '%s\n' 'cat <<-X' '	body' '	X' 'cat ./.zshrc.local')"
check "refuses: read after a <<- with a tab-indented terminator" \
      "$(ask "$hd_dash")" "deny"
hd_quoted="$(printf '%s\n' 'echo "a <<EOF b"' 'cat ./.zshrc.local')"
check "refuses: read after a << inside a quoted string" \
      "$(ask "$hd_quoted")" "deny"
hd_mismatch="$(printf '%s\n' 'python3 - <<PY' 'print(1)' 'PY_END' 'cat ~/.zshrc.local')"
check "refuses: read after a heredoc that never terminates" \
      "$(ask "$hd_mismatch")" "deny"

# ...while a read in ANY segment is still a read. Segmenting the command must not
# become a way to smuggle one past the rule.
check "refuses: the read is in the second segment" \
      "$(ask 'cd /tmp && cat ~/.gitconfig.local')" "deny"
check "refuses: redirected into a reader" \
      "$(ask 'grep KEY < ~/.zshrc.local')" "deny"
check "refuses: piped onward to another command" \
      "$(ask 'cat ~/.zshrc.local | sort')" "deny"

echo
echo
echo "=== expanding a secret-bearing VARIABLE ==="
# Every rule above matches a command SHAPE. None was keyed on the variable
# being expanded, so `echo "$GH_TOKEN"` was allowed -- and on 2026-09-06 a line
# of that family printed a live OAuth token into a session transcript, the
# fourth such capture in six days.
#
# The names are assembled rather than written, for the same reason the fixture
# tokens above are: a literal would trip this repo's own secret scanners.
GHV="GH_""TOKEN"
LKV="LINEAR_""API_KEY"
for c in \
  "echo \"\$$GHV\"" \
  "echo \$$GHV" \
  "printf '%s' \"\$$LKV\"" \
  "echo \"\${$GHV}\"" \
  "printf '%s' \"\${$GHV:-unset}\"" \
  "printf '%s' \"\${$GHV:=fallback}\"" \
  "echo \"\${$GHV:0:4}\"" \
  "echo \"\${$GHV#gho_}\""
do
  check "refuses: $c" "$(ask "$c")" "deny"
done
# The line that actually leaked. `${NAME:+...}` is safe, `${NAME:-...}` is not,
# and the two sit side by side in it -- so a rule that stopped at the first
# expansion it recognised as safe would have allowed the whole thing.
check "refuses: the 2026-09-06 reporting line, whose :- half expands the value" \
      "$(ask "echo \"$GHV: \${$GHV:+set (\${#$GHV} chars)}\${$GHV:-unset}\"")" "deny"
# ...and the alternate text of a :+ is only safe while it does not itself
# expand the value.
check "refuses: a :+ whose alternate expands the variable" \
      "$(ask "echo \"\${$GHV:+\${$GHV}}\"")" "deny"
# `printenv NAME` prints one variable. The bare-dump rule requires env/printenv
# with NO operand, so naming a credential walked past every rule in the file.
check "refuses: printenv naming a credential variable" \
      "$(ask "printenv $GHV")" "deny"
# Two expansions with NOTHING between them. The scan consumes `$`, the brace and
# the NAME -- and deliberately not the character after it, which is itself the
# `$` that opens the next one. Eating one more character loses the second
# expansion entirely, and the first here is an ordinary variable, so the whole
# command reads as clean.
check "refuses: a credential expansion butted against an ordinary one" \
      "$(ask "echo \"\$USER\$$GHV\"")" "deny"
# The name list is patterns as well as literals, or it covers only the five
# variables someone happened to think of.
# shellcheck disable=SC2016  # the expansion must reach the guard UNEXPANDED
check "refuses: a name matched by the *_TOKEN pattern, not by literal" \
      "$(ask 'echo "$DEPLOY_TOKEN"')" "deny"

echo
echo "=== ...without refusing the forms that report set/unset ==="
# These are the only forms that report set/unset without expanding it. Denying them
# would leave no way to report whether a variable is set at all, and a guard
# with no permitted alternative is one people route around -- so they matter
# more than the rows above.
check "allows: the length only" \
      "$(ask "echo \"len=\${#$GHV}\"")" "allow"
check "allows: :+ with a literal alternate" \
      "$(ask "echo \"$GHV is \${$GHV:+set}\"")" "allow"
check "allows: :+ whose alternate reports only the length" \
      "$(ask "echo \"$GHV: \${$GHV:+set (\${#$GHV} chars)}\"")" "allow"

echo
echo "=== ...and an expansion is not an EMISSION ==="
# Group 2, and this is the group that decides the design. A rule keyed on the
# expansion alone -- the obvious shape -- refuses every one of these. Each
# expands a credential variable and prints nothing, and the first of them
# appears in this repo's own zsh/zshrc.herdr, so that rule would refuse
# ordinary work on the very tree the guard lives in.
for c in \
  "[[ -n \"\$$GHV\" ]] && echo pinned" \
  "[[ -n \$$GHV ]] && echo pinned" \
  "if [ -z \"\$$LKV\" ]; then echo unset; fi" \
  "export $GHV=\"\$(gh auth token --user x)\"" \
  "curl -H \"Authorization: Bearer \$$GHV\" https://api.github.com/user" \
  "env -u $GHV gh api user" \
  "git commit -m \"route \$$GHV properly\""
do
  check "allows: $c" "$(ask "$c")" "allow"
done
# SINGLE quotes suppress expansion, so these print the NAME, not the value.
# Matching on the raw command would refuse them; matching on $probe, which
# strips ALL quotes, would never have fired on the leak. Hence the third strip:
# single-quoted spans out, double-quoted spans kept.
check "allows: single quotes, which expand nothing" \
      "$(ask "echo 'the variable \$$GHV holds it'")" "allow"
check "allows: a backslash-escaped dollar inside double quotes" \
      "$(ask "echo \"the variable is \\\$$GHV\"")" "allow"
# ...and a variable whose name merely resembles a secret must be left alone.
# shellcheck disable=SC2016  # the expansion must reach the guard UNEXPANDED
for c in \
  'echo "PATH is $PATH"' \
  'echo "${PATTERN:-none}"' \
  'echo "${COMPAT:-no}"' \
  'echo "user=$USER"' \
  'printenv GH_CONFIG_DIR' \
  'echo "$TOKEN_COUNT tokens used"'
do
  check "allows: $c" "$(ask "$c")" "allow"
done

echo
echo "=== other ways of printing the same file (DO-597) ==="
# The rule matched a fixed list of reading verbs, and several ordinary ways of
# printing a file were not on it. Two of these are not verb-list entries at all:
# an input REDIRECTION feeds the file to whatever command is there, and command
# substitution differs from a plain read only in the character before the verb.
for c in \
  'cut -d= -f2 ~/.zshrc.local' \
  'base64 ~/.zshrc.local' \
  'paste ~/.zshrc.local' \
  'sort ~/.gitconfig.local' \
  'rev ~/.backup.local' \
  'jq . ~/.claude/.credentials.json' \
  'diff ~/.zshrc.local ~/.zshrc'
do
  check "refuses: $c" "$(ask "$c")" "deny"
done
# `< <file>` needs no verb list: it is what tr, tee, mapfile and a `while read`
# loop all have in common, and enumerating a verb for each would be four
# entries that all mean "this file is being read".
for c in \
  'tr -d x < ~/.zshrc.local' \
  'tee < ~/.zshrc.local' \
  'mapfile -t a < ~/.zshrc.local' \
  'readarray -t a < ~/.zshrc.local' \
  'grep KEY < ~/.zshrc.local'
do
  check "refuses: $c" "$(ask "$c")" "deny"
done
# shellcheck disable=SC2016  # the fixture must reach the guard UNEXPANDED
wr_loop='while read -r l; do echo "$l"; done < ~/.zshrc.local'
check "refuses: a while-read loop fed by the file" "$(ask "$wr_loop")" "deny"
# Command substitution. The verb is there in plain sight; only the `(` or the
# backtick before it kept the old pattern from seeing it.
# shellcheck disable=SC2016  # the fixture must reach the guard UNEXPANDED
check "refuses: the read inside a command substitution" \
      "$(ask 'echo $(cat ~/.zshrc.local)')" "deny"
# shellcheck disable=SC2016  # the fixture must reach the guard UNEXPANDED
check "refuses: ...and the backtick spelling" \
      "$(ask 'echo `cat ~/.zshrc.local`')" "deny"

echo
echo "=== ...without letting the wider verb list catch metadata ==="
# Group 2. A longer verb list is the easiest way to start refusing commands
# that print nothing, and `wc`/`du`/`file`/`cp` are the ones nearest the line.
for c in \
  'du -h ~/.zshrc.local' \
  'file ~/.zshrc.local' \
  'cp ~/.zshrc.local ~/.zshrc.local.bak' \
  'mv ~/.zshrc.local ~/.zshrc.local.old' \
  'touch ~/.zshrc.local' \
  'chmod 600 ~/.zshrc.local'
do
  check "allows: $c" "$(ask "$c")" "allow"
done
# The verb must still be reading THE FILE. Each of these runs a NEW verb over
# some other file while naming the credential file in a different segment.
check "allows: a new verb reading a different file" \
      "$(ask 'echo see ~/.zshrc.local > n.txt; cut -d: -f1 /etc/passwd')" "allow"
check "allows: ...and sort over an unrelated file" \
      "$(ask 'echo see ~/.zshrc.local > n.txt; sort README.md | uniq')" "allow"
# `(` became a word boundary so command substitution is seen. It must not fire
# on ordinary array syntax, where there is no command at all.
# shellcheck disable=SC2016  # the fixture must reach the guard UNEXPANDED
check "allows: an array literal that happens to start with a verb name" \
      "$(ask 'FILES=(~/.zshrc.local ~/.zshrc); echo ${#FILES[@]}')" "allow"
# `<<` is a heredoc, which reads nothing from the named file.
hd_named="$(printf '%s\n' 'cat <<EOF' 'see ~/.zshrc.local for the key' 'EOF')"
check "allows: a heredoc whose body names the file" "$(ask "$hd_named")" "allow"
# `<<<` is a HERESTRING: it feeds the literal path text to the command, and the
# shell never opens the file. The command here is deliberately one the verb list
# does not know, because every verb it DOES know denies the segment on its own
# and so cannot tell the two rules apart -- which is what left the `<<`
# exclusion unpinned until this row existed.
check "allows: a herestring carrying the path, which opens nothing" \
      "$(ask 'tr a b <<< ~/.zshrc.local')" "allow"
# ...and the redirection rule has to check WHICH file is being redirected, not
# merely that the segment has a `<` somewhere in it.
check "allows: a redirection from something else, in a segment that names the file" \
      "$(ask 'echo ~/.zshrc.local < /dev/null')" "allow"

echo
echo "=== ...and the shapes that stay uncovered, pinned so the scope is explicit ==="
# DO-597 chose to add the reachable shapes and NAME the rest rather than grow
# the pattern list until the guard merely LOOKS comprehensive. These rows are
# the scope written down: each is a real read that this hook does not catch,
# and a change that starts catching one should fail here and be a decision.
# shellcheck disable=SC2016  # the fixture must reach the guard UNEXPANDED
for c in \
  "perl -ne 'print' ~/.zshrc.local" \
  'eval "cat ~/.zshrc.local"' \
  'cat ~/.zshrc.loca*' \
  'cp ~/.zshrc.local /tmp/x && cat /tmp/x' \
  'f=~/.zshrc.local && cat "$f"'
do
  check "uncovered (by decision): $c" "$(ask "$c")" "allow"
done
py_read='python3 -c "print(open(\"/home/zvi/.zshrc.local\").read())"'
check "uncovered (by decision): an interpreter handed the path" \
      "$(ask "$py_read")" "allow"
# A known FALSE POSITIVE, pre-existing and pinned rather than fixed here: the
# file is the TARGET of a redirection, so nothing is read from it, but the
# segment carries both a reading verb and the path. Same treatment as the
# heredoc-prose row above -- visible and tracked beats quietly wrong.
check "refuses: writing TO the file (known, pre-existing FP)" \
      "$(ask 'cat README.md > ~/.zshrc.local')" "deny"

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

# The variable rule's message has to name the SAFE form, because the generic
# remedy above -- the redactor -- is the wrong tool for it: there is nothing to
# redact when all you wanted was to say whether the variable is set, and the
# redactor matches token shapes, so a variable caught here by its NAME alone
# passes through it untouched. CLAUDE.md records a case where this guard's own
# suggested remedy still printed the token; this row is against that.
vmsg="$(python3 -c "
import json; print(json.dumps({'tool_input':{'command':'echo \"\$$GHV\"'}}))" | "$GUARD" \
      | jq -r '.hookSpecificOutput.permissionDecisionReason')"
# shellcheck disable=SC2016  # the expansion must reach the guard UNEXPANDED
check "the variable rule names the length form as the remedy" \
      "$(printf '%s' "$vmsg" | grep -c '\${#')" "1"
check "...and says the redactor is not the remedy here" \
      "$(printf '%s' "$vmsg" | grep -c 'not a reliable remedy')" "1"
# ...and it must never print the VALUE. The guard runs with the real
# environment, so the only thing stopping it is that it never expands the
# command it was handed -- which is worth a canary rather than an assurance.
# A diagnostic that prints a credential is worse than no diagnostic.
CANARY="canary$(printf '9%.0s' {1..12})zz"
vleak="$(GH_TOKEN="$CANARY" python3 -c "
import json; print(json.dumps({'tool_input':{'command':'echo \"\$$GHV\"'}}))" \
        | GH_TOKEN="$CANARY" "$GUARD")"
check "the variable rule never expands the command it refuses" \
      "$(printf '%s' "$vleak" | grep -c "$CANARY")" "0"
check "...while still denying it" \
      "$(printf '%s' "$vleak" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
