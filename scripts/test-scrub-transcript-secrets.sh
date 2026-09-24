#!/usr/bin/env bash
#
# scripts/test-scrub-transcript-secrets.sh
# ========================================
#
# State table for scripts/scrub-transcript-secrets.py.
#
# HERMETIC, AND IT HAS TO BE. The subject rewrites Claude Code transcripts in
# place. Every row here runs against a throwaway tree under mktemp, reached only
# through SCRUB_TRANSCRIPT_ROOTS, and nothing in this file ever names
# ~/.claude/projects. A suite that could touch the real corpus is one nobody
# should run, and CI has no such corpus anyway.
#
# THE FIXTURE CREDENTIALS ARE ASSEMBLED AT RUNTIME, the same trick
# scripts/test-secret-guard.sh uses: this file must contain no literal that
# `gitleaks` or `detect-private-key` would flag over its own test data. That is
# not decoration -- a pre-commit hook that trips on the test data for the secret
# tooling is how the secret tooling stops being testable.
#
# WHAT EACH GROUP IS FOR
# ----------------------
#   catches      all fifteen shapes and the name rules, and the one row that is
#                the entire premise of the tool: a name-rule credential inside a
#                JSON string, which scripts/redact-secrets.sh provably misses.
#                That row asserts BOTH halves, so the premise cannot rot
#                silently. Shape rows are driven by SHAPE_FIXTURES, one entry
#                per rule, and a row in `parity` asserts that table covers every
#                rule the subject advertises.
#   leaves alone placeholders, the names `_PAT` must not reach, and
#                byte-for-byte idempotence on a second run. Most of a redactor's
#                value is in what it does not touch.
#   parity       the two files carry the same rule LABELS -- not the same
#                patterns, which differ by grammar and should. This is DO-700's
#                actual fix: nothing asserted it before, so seven shapes of
#                fifteen shipped and DO-692's two never propagated at all.
#   discretion   refuse, roll back, skip -- the paths where it declines. Rule 3
#                (the live-session skip) is reachable only through the
#                documented test seam; an untestable branch is an untested one.
#   hygiene      no .prescrub survives, and a leftover one from an interrupted
#                run is swept.
#   contract     exit codes, the audit line, and root discovery.
#   counts       the row total, and the two numbers docs/TRANSCRIPT_SCRUB.md
#                quotes back. Its row count was already stale (54 vs 58) when
#                this group was written, because nothing compared them.
#
# Every row is one `check`. The totals assertion at the end is the house norm
# (scripts/test-wt-gc-sweep.sh, scripts/test-claude-md.sh): a row that silently
# stops running is otherwise indistinguishable from a row that passes.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRUB="${SCRUB:-$DOTFILES/scripts/scrub-transcript-secrets.py}"
REDACT="${REDACT:-$DOTFILES/scripts/redact-secrets.sh}"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

# One name per `command -v` call: with two operands the shells disagree about
# both the output and the status, so a two-name check is a silent pass.
for tool in python3 shred; do
    command -v "$tool" >/dev/null 2>&1 || fatal "$tool is required to run this suite"
done
PY="$(command -v python3)"
[[ -r "$SCRUB" ]] || fatal "not readable: $SCRUB"
[[ -r "$REDACT" ]] || fatal "not readable: $REDACT"

# The two numbers this suite asserts about itself, and that its record quotes
# back. Both live here rather than beside the totals assertion because
# EXPECTED_RULES is read by the parity group, which runs long before it.
# `grep -c ✗` counts row NAMES, not outcomes; only the total at the end catches
# a check that silently stopped running.
EXPECTED_ROWS=112
EXPECTED_RULES=16

T="$(mktemp -d)" || fatal "cannot create a temp dir"
trap 'rm -rf "$T"' EXIT
ROOT="$T/projects"
STATE="$T/state"

# --- fixture credentials, none of them a literal in this file ---------------
GHO="gho_$(printf 'A%.0s' {1..36})"
PAT="github_pat_$(printf 'B%.0s' {1..30})"
ANT="sk-ant-$(printf 'C%.0s' {1..40})"
XOX="xoxb-$(printf '1%.0s' {1..20})"
GLP="glpat-$(printf 'D%.0s' {1..24})"
NTN="ntn_$(printf 'e%.0s' {1..43})"
LIN="lin_api_$(printf 'f%.0s' {1..40})"
# 32 hex-ish characters: no distinctive shape at all, which is the point. This
# is the class that only a NAME rule can reach.
SHAPELESS="$(printf 'ab%.0s' {1..16})"
# The eight DO-700 added. Assembled the same way and for the same reason -- the
# PEM header especially: `detect-private-key` blacklists the whole `BEGIN <type>
# PRIVATE KEY` string as a SUBSTRING, so it must not appear spelled out here.
# This comment used to spell it out while explaining not to, and the hook caught
# that -- the prose about a secret trips the same check the secret does.
AKID="AKIA$(printf 'Q%.0s' {1..16})"
ASID="ASIA$(printf 'Q%.0s' {1..16})"
AWSSEC="$(printf 'z%.0s' {1..40})"
SAMLV="fZ%2B$(printf 'a%.0s' {1..24})"
VPNCHAL="R:instance-abc,U:$(printf 'd%.0s' {1..24})"
BTOK="$(printf 't%.0s' {1..32})"
KEYTYPE="RSA"
PEMHDR="-----BEGIN $KEYTYPE PRIVATE KEY-----"
PEMFTR="-----END $KEYTYPE PRIVATE KEY-----"
PEMB64="$(printf 'M%.0s' {1..64})"
URLPW="$(printf 'p%.0s' {1..20})"

# --- helpers ---------------------------------------------------------------
# A transcript line. The body is embedded in a JSON string, so a `\n` written
# here is the two characters backslash-n, exactly as Claude Code records a
# multi-line command -- which is the condition redact-secrets.sh cannot see past.
line() { printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$1"; }

fresh() {
    rm -rf "$ROOT" "$STATE"
    mkdir -p "$ROOT/proj" "$STATE"
}

# Prints combined output and returns the subject's exit status. It must NOT
# stash the status in a variable: every capturing caller runs it in a command
# substitution, where an assignment cannot reach this shell, and the row would
# then read whatever the PREVIOUS run left behind -- green for the wrong reason.
run() {
    SCRUB_TRANSCRIPT_ROOTS="$ROOT" SCRUB_TRANSCRIPT_STATE="$STATE" \
        "$PY" "$SCRUB" "$@" 2>&1
}

manifest() { find "$ROOT" -type f -exec sha256sum {} + 2>/dev/null | sort; }
logline()  { tail -n 1 "$STATE/log" 2>/dev/null; }

# "ok" only if EVERY non-blank line parses. Anything else -- a mangled record,
# an unreadable file -- is not a pass, so the row names what it got.
json_ok() {
    "$PY" -c 'import json,sys
[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print("ok")' "$1" 2>/dev/null || echo "NOT JSON"
}

# The redaction labels redact-secrets.sh advertises, read out of its sed
# program. Anchored on `-e '` at the start of a line, which only a rule line
# is: its header, its trailing commentary and this suite's own prose all
# mention `<REDACTED:` too, and a looser extractor would quietly harvest those
# and agree with anything.
redactor_labels() {
    local f="$1"
    [[ -r "$f" ]] || { printf 'cannot read %s\n' "${f##*/}"; return; }
    grep -E "^[[:space:]]*-e '" "$f" \
        | grep -oE '<REDACTED:[a-z0-9-]+>' \
        | sed -e 's/^<REDACTED://' -e 's/>$//' | sort -u
}

echo "=== catches: all fifteen shapes, the same set redact-secrets.sh carries ==="

# One entry per shape rule: label|payload|the value that must disappear.
# KEYED rules (aws-secret, saml-request, vpn-auth-challenge, bearer,
# private-key, url-password) keep their key and replace only the value, so the
# needle is the value alone -- a rule that redacted the key instead would still
# print its marker, and only this column would notice.
#
# Payloads embed `\n` as the two characters backslash-n, exactly as Claude Code
# records a multi-line command: that is the condition every rule here has to
# survive, and the condition redact-secrets.sh's name rules cannot see past.
SHAPE_FIXTURES=(
    "github-token|a token $GHO here|$GHO"
    "github-pat|a token $PAT here|$PAT"
    "anthropic-key|a token $ANT here|$ANT"
    "slack-token|a token $XOX here|$XOX"
    "aws-access-key-id|aws sts\\nkey id $AKID\\nend|$AKID"
    "aws-temp-key-id|assumed a role, $ASID, expiring|$ASID"
    "aws-secret|credentials\\naws_secret_access_key=$AWSSEC\\nregion=x|$AWSSEC"
    "gitlab-pat|a token $GLP here|$GLP"
    "notion-token|a token $NTN here|$NTN"
    "linear-key|a token $LIN here|$LIN"
    "saml-request|GET /sso?SAMLRequest=$SAMLV&RelayState=x|$SAMLV"
    "vpn-auth-challenge|log AUTH_FAILED,CRV1:$VPNCHAL please re-auth|$VPNCHAL"
    "bearer|curl -H 'Authorization: Bearer $BTOK' https://x|$BTOK"
    "private-key|key follows:\\n$PEMHDR\\n$PEMB64\\n$PEMFTR\\ndone|$PEMB64"
    "url-password|clone https://svc:$URLPW@git.example.com/r.git|$URLPW"
)

for fx in "${SHAPE_FIXTURES[@]}"; do
    label="${fx%%|*}"; rest="${fx#*|}"
    payload="${rest%|*}"; needle="${rest##*|}"
    fresh
    line "$payload" > "$ROOT/proj/s.jsonl"
    run --apply >/dev/null
    check "shape $label is replaced" \
          "$(grep -c "REDACTED:$label" "$ROOT/proj/s.jsonl")" "1"
    check "...and the $label value itself is gone" \
          "$(grep -cF -- "$needle" "$ROOT/proj/s.jsonl")" "0"
done

# All fifteen in one file, which is the only place their INTERACTION is tested:
# the rules run in sequence over the whole byte blob, so one rule's replacement
# is the next rule's input. This is also where idempotence is proved for the
# eight added by DO-700 -- every one of their value classes excludes `<` for
# exactly this row, because a rule that re-matches its own output reports
# replacements it did not make on every nightly run forever.
fresh
: > "$ROOT/proj/s.jsonl"
for fx in "${SHAPE_FIXTURES[@]}"; do
    rest="${fx#*|}"
    line "${rest%|*}" >> "$ROOT/proj/s.jsonl"
done
run --apply >/dev/null
seen=0
for fx in "${SHAPE_FIXTURES[@]}"; do
    label="${fx%%|*}"
    grep -q "REDACTED:$label" "$ROOT/proj/s.jsonl" && seen=$((seen+1))
done
check "all ${#SHAPE_FIXTURES[@]} shapes fire in one file, side by side" \
      "$seen" "${#SHAPE_FIXTURES[@]}"
survived=0
for fx in "${SHAPE_FIXTURES[@]}"; do
    rest="${fx#*|}"
    grep -qF -- "${rest##*|}" "$ROOT/proj/s.jsonl" && survived=$((survived+1))
done
check "...and not one of their values survives" "$survived" "0"
check "...and every line still parses as JSON" "$(json_ok "$ROOT/proj/s.jsonl")" "ok"
cp "$ROOT/proj/s.jsonl" "$T/allshapes.jsonl"
run --apply >/dev/null
check "...a second run over all of them is a byte-for-byte no-op" \
      "$(cmp -s "$ROOT/proj/s.jsonl" "$T/allshapes.jsonl" && echo same || echo changed)" "same"
check "...and counts nothing, so no rule re-matched its own replacement" \
      "$(logline | grep -o 'replacements=[0-9]*')" "replacements=0"

# private-key is the one translation that needed real thought, and these two
# rows are what stop it regressing to the sed spelling. `.*` to end of line is
# right in a pipe and wrong here: inside a JSON string the end of the line is
# the end of the RECORD, so it swallows the closing `"}`, unparseable() refuses
# the whole file, and the key stays on disk while the run reports a refusal.
fresh
line "key follows:\\n$PEMHDR\\n$PEMB64\\n$PEMFTR\\nand prose after it" \
    > "$ROOT/proj/s.jsonl"
run --apply >/dev/null
check "a PEM body is replaced without eating the rest of the JSON record" \
      "$(grep -c 'and prose after it' "$ROOT/proj/s.jsonl")" "1"
# `--` because the END marker begins with five dashes: without it grep reads
# the needle as an option bundle and the row fails with an empty result, which
# is not the same thing as the marker being absent.
check "...keeping the END marker, so the line still reads as what it was" \
      "$(grep -cF -- "$PEMFTR" "$ROOT/proj/s.jsonl")" "1"

# A PEM cut off by the end of the record has no END marker at all. It must
# still be redacted, and must still stop at the JSON string boundary.
fresh
line "truncated key:\\n$PEMHDR\\n$PEMB64" > "$ROOT/proj/s.jsonl"
run --apply >/dev/null
check "a truncated PEM is redacted and the record still parses" \
      "$(json_ok "$ROOT/proj/s.jsonl")" "ok"
check "...with its body gone" "$(grep -cF -- "$PEMB64" "$ROOT/proj/s.jsonl")" "0"

echo
echo "=== catches: the names, which is why this tool exists at all ==="

# THE row. Same bytes through both tools: the pipe filter cannot see it, this
# one can. If either half ever changes, the premise of the whole change is dead
# and this is where it is caught.
fresh
line "ran env\\nSONIOX_API_KEY=$SHAPELESS\\nthen carried on" > "$ROOT/proj/s.jsonl"
cp "$ROOT/proj/s.jsonl" "$T/before.jsonl"
check "redact-secrets.sh MISSES a name inside a JSON string (the premise)" \
      "$("$REDACT" < "$T/before.jsonl" | grep -cF "$SHAPELESS")" "1"
run --apply >/dev/null
check "...and this tool catches it" \
      "$(grep -cF "$SHAPELESS" "$ROOT/proj/s.jsonl")" "0"
check "...replacing it by name" \
      "$(grep -c 'SONIOX_API_KEY=<REDACTED:by-name>' "$ROOT/proj/s.jsonl")" "1"
check "...and the line still parses as JSON" \
      "$("$PY" -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.strip()]; print("ok")' \
         "$ROOT/proj/s.jsonl")" "ok"

for name in LINEAR_API_KEY GH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_MESSAGING_TOKEN \
            GITHUB_PERSONAL_ACCESS_TOKEN ANTHROPIC_AUTH_TOKEN; do
    fresh
    line "env dump\\n$name=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
    run --apply >/dev/null
    check "name $name is replaced" \
          "$(grep -c "$name=<REDACTED:by-name>" "$ROOT/proj/s.jsonl")" "1"
done

fresh
line "a value ending at a quote: GH_TOKEN=$SHAPELESS\" and then prose" > "$ROOT/proj/s.jsonl"
run --apply >/dev/null
check "the value stops at the closing quote, not at the next real space" \
      "$(grep -c 'and then prose' "$ROOT/proj/s.jsonl")" "1"

# The DO-700 widening: the name rule is the redactor's generic SUFFIX pattern,
# not the seven-name allowlist this shipped with. None of these four is in that
# allowlist, and each measured in the double digits across the real corpus --
# DB_PASSWORD in 75 transcripts, OPENAI_API_KEY 55, GITHUB_TOKEN 51,
# OIDC_CLIENT_SECRET 22. One row per suffix the alternation carries, so a
# suffix dropped from it fails here rather than silently under-scrubbing.
for name in DB_PASSWORD OPENAI_API_KEY GITHUB_TOKEN OIDC_CLIENT_SECRET; do
    fresh
    line "env dump\\n$name=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
    run --apply >/dev/null
    check "no allowlist could name it: $name is replaced by pattern" \
          "$(grep -c "$name=<REDACTED:by-name>" "$ROOT/proj/s.jsonl")" "1"
done

# `_PAT` is a rule of its own here for redact-secrets.sh's measured reason, and
# a NOTION_PAT is what got past that file in the first place (DO-576).
fresh
line "env dump\\nNOTION_PAT=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
run --apply >/dev/null
check "the _PAT rule reaches a name no suffix in the alternation does" \
      "$(grep -c 'NOTION_PAT=<REDACTED:by-name>' "$ROOT/proj/s.jsonl")" "1"

# The counter is keyed by the VARIABLE NAME, not by `by-name`. (`tail -n 1`
# because --json prints its object after the per-root lines, not instead of
# them.) With the rule a
# pattern rather than a list, `--dry-run --json` is the only review surface
# there is for what an unattended, backup-shredding job would rewrite -- and it
# is useless if every hit collapses into one bucket.
fresh
line "env\\nDB_PASSWORD=$SHAPELESS\\nOPENAI_API_KEY=$SHAPELESS\\nend" \
    > "$ROOT/proj/s.jsonl"
check "a dry run names each variable it would rewrite, not just a total" \
      "$(run --dry-run --json | tail -n 1 | "$PY" -c \
         'import json,sys; d=json.load(sys.stdin); print(",".join(sorted(d["by_kind"])))')" \
      "DB_PASSWORD,OPENAI_API_KEY"

echo
echo "=== leaves alone: most of the value is in what it does not touch ==="

fresh
{
  # shellcheck disable=SC2016  # the literal $GH_TOKEN is the fixture: an
  # unexpanded shell variable is one of the placeholders that must survive.
  line 'a shell variable: GH_TOKEN=$GH_TOKEN stays readable'
  line 'already done: LINEAR_API_KEY=<REDACTED:by-name>'
  line 'documentation filler: ANTHROPIC_API_KEY=your-token-here'
  line 'masked already: GH_TOKEN=xxxxxxxxxxxx'
  line 'an ellipsis: ANTHROPIC_API_KEY=...redacted'
  line 'a short value is not a credential: GH_TOKEN=abc'
  line 'a bare prefix in prose: ntn_ and lin_api_ and gho_'
} > "$ROOT/proj/s.jsonl"
cp "$ROOT/proj/s.jsonl" "$T/untouched.jsonl"
run --apply >/dev/null
check "placeholders, filler and short values are all left alone" \
      "$(cmp -s "$ROOT/proj/s.jsonl" "$T/untouched.jsonl" && echo same || echo changed)" "same"

# The five names redact-secrets.sh's trailing comment pins, and the reason
# `_PAT` is a separate rule rather than another branch of the alternation:
# inside it, the trailing `[A-Z0-9_]*=` absorbs whatever follows and every one
# of these redacts. A scrubber that mangles ordinary variables is one somebody
# stops running, and this one runs unattended.
fresh
{
  line 'a path: SOME_PATH=/usr/local/bin/thing'
  line 'a path list: MY_PATHS=/a/bb:/c/dd'
  line 'an ordinary word: COMPATIBLE=yesyesyesyes'
  line 'a regex: PATTERN=abcdefghijk'
  line 'the big one: PATH=/usr/bin:/bin:/sbin'
} > "$ROOT/proj/s.jsonl"
cp "$ROOT/proj/s.jsonl" "$T/patsafe.jsonl"
run --apply >/dev/null
check "PATH, SOME_PATH, MY_PATHS, COMPATIBLE and PATTERN are all untouched" \
      "$(cmp -s "$ROOT/proj/s.jsonl" "$T/patsafe.jsonl" && echo same || echo changed)" "same"

# The 8-character floor, which is what keeps the widened rule off the ordinary
# uses of these words. Neither of these is a credential and neither is long.
fresh
{
  line 'a setting: TOKENIZERS_PARALLELISM=false'
  line 'a limit: MAX_TOKENS=4096'
} > "$ROOT/proj/s.jsonl"
cp "$ROOT/proj/s.jsonl" "$T/shortval.jsonl"
run --apply >/dev/null
check "...and a short value is not a credential whatever the name suggests" \
      "$(cmp -s "$ROOT/proj/s.jsonl" "$T/shortval.jsonl" && echo same || echo changed)" "same"

# A bare PEM header in prose has no body, and the `+` in the private-key rule
# is what stops it matching. With `*` it would match, append a marker, and
# append another on every run after that.
fresh
line "the header is written $PEMHDR in docs" > "$ROOT/proj/s.jsonl"
cp "$ROOT/proj/s.jsonl" "$T/hdr.jsonl"
run --apply >/dev/null
check "a PEM header with no body after it is left alone" \
      "$(cmp -s "$ROOT/proj/s.jsonl" "$T/hdr.jsonl" && echo same || echo changed)" "same"
check "...and a file with nothing to do is not counted as scrubbed" \
      "$(logline | grep -o 'scrubbed=[0-9]*')" "scrubbed=0"

fresh
line "env dump\\nGH_TOKEN=$SHAPELESS\\nand a token $ANT" > "$ROOT/proj/s.jsonl"
run --apply >/dev/null
cp "$ROOT/proj/s.jsonl" "$T/once.jsonl"
run --apply >/dev/null
check "a second run is a byte-for-byte no-op (idempotence)" \
      "$(cmp -s "$ROOT/proj/s.jsonl" "$T/once.jsonl" && echo same || echo changed)" "same"
check "...and reports nothing left to scrub" \
      "$(logline | grep -o 'replacements=[0-9]*')" "replacements=0"

echo
echo "=== it never prints a matched value ==="

fresh
line "env\\nGH_TOKEN=$SHAPELESS\\ntoken $GHO and $ANT and $NTN" > "$ROOT/proj/s.jsonl"
OUT="$(run --apply)"
leaked=0
for cred in "$GHO" "$ANT" "$NTN" "$SHAPELESS"; do
    grep -qF "$cred" <<< "$OUT" && leaked=$((leaked+1))
done
check "no fixture credential appears in stdout or stderr" "$leaked" "0"
check "...while the run really did replace them" \
      "$(logline | grep -o 'replacements=[0-9]*')" "replacements=4"

fresh
line "env\\nGH_TOKEN=$SHAPELESS\\ntoken $GHO and $ANT" > "$ROOT/proj/s.jsonl"
OUT="$(run --dry-run)"
leaked=0
for cred in "$GHO" "$ANT" "$SHAPELESS"; do
    grep -qF "$cred" <<< "$OUT" && leaked=$((leaked+1))
done
check "...nor in the DRY RUN, which prints a line per file" "$leaked" "0"

echo
echo "=== discretion: refuse, roll back, skip ==="

# A line that is not JSON to begin with cannot be made worse by scrubbing, but
# the file must still be refused rather than rewritten: the tool's promise is
# that what it writes parses, and it cannot keep that promise here.
fresh
printf 'this is not json at all GH_TOKEN=%s\n' "$SHAPELESS" > "$ROOT/proj/s.jsonl"
cp "$ROOT/proj/s.jsonl" "$T/bad.jsonl"
OUT="$(run --apply)"; RC_REFUSE=$?
check "a file whose result would not parse is REFUSED" \
      "$(grep -c 'REFUSED' <<< "$OUT")" "1"
check "...and is left exactly as it was" \
      "$(cmp -s "$ROOT/proj/s.jsonl" "$T/bad.jsonl" && echo same || echo changed)" "same"
check "...and the run exits 1" "$RC_REFUSE" "1"

# Rule 3, through the one documented seam. The hook appends to the file between
# the read and the re-stat, which is precisely the live-session race.
fresh
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
cp "$ROOT/proj/s.jsonl" "$T/live.jsonl"
# shellcheck disable=SC2016  # the hook body is expanded by the subject, not here:
# $SCRUB_TRANSCRIPT_FILE is set per file in the environment it runs the hook with.
OUT="$(SCRUB_TRANSCRIPT_PRE_WRITE_HOOK='printf "\n" >> "$SCRUB_TRANSCRIPT_FILE"' \
       SCRUB_TRANSCRIPT_ROOTS="$ROOT" SCRUB_TRANSCRIPT_STATE="$STATE" \
       "$PY" "$SCRUB" --apply 2>&1)"; RC_SKIP=$?
check "a file that changed under us is SKIPPED, not rewritten from a stale read" \
      "$(grep -c 'SKIP (changed while reading' <<< "$OUT")" "1"
check "...and the credential is still there for the next run to catch" \
      "$(grep -cF "$SHAPELESS" "$ROOT/proj/s.jsonl")" "1"
check "...and a skip is NOT a failure" "$RC_SKIP" "0"
check "...and it is counted as a skip" \
      "$(logline | grep -o 'skipped=[0-9]*')" "skipped=1"

fresh
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
run --apply >/dev/null
check "the next run does catch it (idempotence is what makes a skip cheap)" \
      "$(grep -cF "$SHAPELESS" "$ROOT/proj/s.jsonl")" "0"

fresh
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
OUT="$(SCRUB_SELF_TRANSCRIPT="proj" SCRUB_TRANSCRIPT_ROOTS="$ROOT" \
       SCRUB_TRANSCRIPT_STATE="$STATE" "$PY" "$SCRUB" --apply 2>&1)"
check "SCRUB_SELF_TRANSCRIPT excludes a matching path outright" \
      "$(grep -cF "$SHAPELESS" "$ROOT/proj/s.jsonl")" "1"

echo
echo "=== hygiene: a backup is a second copy of the same secrets ==="

fresh
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
run --apply >/dev/null
check "no .prescrub survives a successful run" \
      "$(find "$ROOT" -name '*.prescrub' | wc -l | tr -d ' ')" "0"

fresh
line "nothing to do here" > "$ROOT/proj/s.jsonl"
line "an interrupted run left this\\nGH_TOKEN=$SHAPELESS" > "$ROOT/proj/s.jsonl.prescrub"
OUT="$(run --apply)"
check "a leftover backup from an interrupted run is swept by --apply" \
      "$(find "$ROOT" -name '*.prescrub' | wc -l | tr -d ' ')" "0"
check "...and the sweep says so" "$(grep -c 'shredded leftover backup' <<< "$OUT")" "1"

fresh
line "nothing to do here" > "$ROOT/proj/s.jsonl"
line "left behind\\nGH_TOKEN=$SHAPELESS" > "$ROOT/proj/s.jsonl.prescrub"
OUT="$(run --dry-run)"
check "a dry run REPORTS a leftover backup" \
      "$(grep -c 'LEFTOVER BACKUP' <<< "$OUT")" "1"
check "...and does not remove it, because a dry run writes nothing" \
      "$(find "$ROOT" -name '*.prescrub' | wc -l | tr -d ' ')" "1"

echo
echo "=== contract: exit codes, the audit line, root discovery ==="

fresh
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
BEFORE="$(manifest)"
OUT="$(run --dry-run)"; RC_DRY=$?
check "a dry run changes nothing under the roots" \
      "$([[ "$BEFORE" == "$(manifest)" ]] && echo same || echo changed)" "same"
check "...exits 0" "$RC_DRY" "0"
check "...and says what it would do" "$(grep -c 'would scrub' <<< "$OUT")" "1"
check "...and logs mode=dry, not mode=apply" \
      "$(logline | grep -o 'mode=[a-z]*')" "mode=dry"

fresh
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
run --apply >/dev/null
check "an apply logs mode=apply" "$(logline | grep -o 'mode=[a-z]*')" "mode=apply"
check "...and the audit line carries every counter" \
      "$(logline | grep -oE '(roots|scanned|scrubbed|replacements|skipped|refused|shred_failed)=' | wc -l | tr -d ' ')" "7"

fresh
line "nothing here" > "$ROOT/proj/s.jsonl"
run --apply >/dev/null; RC_CLEAN=$?
check "a clean sweep exits 0" "$RC_CLEAN" "0"

SCRUB_TRANSCRIPT_STATE="$STATE" "$PY" "$SCRUB" --root "$T/does-not-exist" >/dev/null 2>&1
check "no usable root is COULD NOT RUN (2), never a clean sweep of nothing" "$?" "2"

SCRUB_TRANSCRIPT_ROOTS="$ROOT" SCRUB_TRANSCRIPT_STATE="$STATE" \
    "$PY" "$SCRUB" --apply --dry-run >/dev/null 2>&1
check "--apply with --dry-run is a usage error (2)" "$?" "2"

mkdir -p "$T/emptybin"
fresh
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
PATH="$T/emptybin" SCRUB_TRANSCRIPT_ROOTS="$ROOT" SCRUB_TRANSCRIPT_STATE="$STATE" \
    "$PY" "$SCRUB" --apply >/dev/null 2>&1
check "a missing shred refuses to write at all (2)" "$?" "2"
check "...having touched nothing" "$(grep -cF "$SHAPELESS" "$ROOT/proj/s.jsonl")" "1"

# Two roots, one of them nested inside the other. The nested one must be
# dropped: scanning a file twice in one run makes the second pass see the mtime
# the first pass just set, and report a live-session skip that never happened.
fresh
mkdir -p "$T/other/proj"
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
line "env\\nLINEAR_API_KEY=$SHAPELESS\\nend" > "$T/other/proj/s.jsonl"
SCRUB_TRANSCRIPT_ROOTS="$ROOT:$T/other" SCRUB_TRANSCRIPT_STATE="$STATE" \
    "$PY" "$SCRUB" --apply >/dev/null 2>&1
check "two roots are both swept" \
      "$(( $(grep -c 'REDACTED:by-name' "$ROOT/proj/s.jsonl") + \
           $(grep -c 'REDACTED:by-name' "$T/other/proj/s.jsonl") ))" "2"
check "...and the audit line counts them" "$(logline | grep -o 'roots=[0-9]*')" "roots=2"

fresh
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$ROOT/proj/s.jsonl"
SCRUB_TRANSCRIPT_ROOTS="$ROOT:$ROOT/proj" SCRUB_TRANSCRIPT_STATE="$STATE" \
    "$PY" "$SCRUB" --apply >/dev/null 2>&1
check "a root nested in another is dropped, not scanned twice" \
      "$(logline | grep -o 'roots=[0-9]*')" "roots=1"
check "...and nothing is reported as a phantom skip" \
      "$(logline | grep -o 'skipped=[0-9]*')" "skipped=0"

echo
echo "=== discovery: the roots nobody had been looking at ==="

# The only rows that exercise discover_roots(). Everything above overrides the
# roots outright, so without these the function that motivated this whole change
# is never executed. HOME is redirected because that is exactly what it reads.
FAKE="$T/home"
fresh
rm -rf "$FAKE"
mkdir -p "$FAKE/.claude/projects/p" "$FAKE/.local/state/claude-account-dirs/acct-0/projects/q"
line "env\\nGH_TOKEN=$SHAPELESS\\nend" > "$FAKE/.claude/projects/p/a.jsonl"
line "env\\nLINEAR_API_KEY=$SHAPELESS\\nend" \
    > "$FAKE/.local/state/claude-account-dirs/acct-0/projects/q/b.jsonl"
HOME="$FAKE" SCRUB_TRANSCRIPT_STATE="$STATE" "$PY" "$SCRUB" --apply >/dev/null 2>&1
check "discovery finds ~/.claude/projects with no override" \
      "$(grep -c 'REDACTED:by-name' "$FAKE/.claude/projects/p/a.jsonl")" "1"
check "...and every account dir's projects/ too (the 58 nobody had scanned)" \
      "$(grep -c 'REDACTED:by-name' "$FAKE/.local/state/claude-account-dirs/acct-0/projects/q/b.jsonl")" "1"
check "...counting both as roots" "$(logline | grep -o 'roots=[0-9]*')" "roots=2"

echo
echo "=== parity: the two files' rule sets, which is what DO-700 is about ==="

# THE MECHANISM, and the reason this group exists rather than eight more shape
# rows. Nothing asserted that scrub-transcript-secrets.py and redact-secrets.sh
# carried the same rules, so they drifted: seven shapes of fifteen shipped
# here, and DO-692's two arrived in one file and never in the other. Any fix
# that is only a fix rots the same way; this is the part that does not.
#
# The comparison is over rule LABELS, not patterns, and that is deliberate. The
# two files are in different languages against different value grammars -- sed
# ERE on a line, Python `re` on the bytes of a JSON string -- so their patterns
# SHOULD differ and an assertion that they match textually would be wrong as
# well as fragile. What must never differ is the set of credentials either one
# claims to cover, and a label is exactly that claim.
#
# One side is asked (`--rules`, derived from the compiled rules), the other is
# read (the `-e` lines of the sed program). Both counts are asserted against a
# literal (EXPECTED_RULES, at the top) so that two empty extractors cannot
# agree with each other -- an extractor that harvests nothing is the failure
# mode here, and it looks identical to perfect agreement.

check "the scrubber advertises $EXPECTED_RULES rules" \
      "$("$PY" "$SCRUB" --rules | wc -l | tr -d ' ')" "$EXPECTED_RULES"
check "redact-secrets.sh advertises $EXPECTED_RULES rules" \
      "$(redactor_labels "$REDACT" | wc -l | tr -d ' ')" "$EXPECTED_RULES"
check "every rule redact-secrets.sh has, the scrubber has" \
      "$(comm -23 <(redactor_labels "$REDACT") <("$PY" "$SCRUB" --rules) | tr '\n' ' ')" ""
check "every rule the scrubber has, redact-secrets.sh has" \
      "$(comm -13 <(redactor_labels "$REDACT") <("$PY" "$SCRUB" --rules) | tr '\n' ' ')" ""

# The extractor has to actually READ the file, and a row proving it agrees with
# the scrubber proves nothing on its own -- a function returning the scrubber's
# own list would pass every row above. So: delete one rule from a COPY and the
# extractor must notice exactly that one. This is the row that fails if someone
# re-anchors the grep onto something the rule lines do not have.
sed '/REDACTED:aws-access-key-id>/d' "$REDACT" > "$T/redact-minus-one.sh"
check "a rule deleted from redact-secrets.sh is detected, and named" \
      "$(comm -13 <(redactor_labels "$T/redact-minus-one.sh") \
                  <("$PY" "$SCRUB" --rules) | tr '\n' ' ')" "aws-access-key-id "
check "...and it is one rule fewer, not a broken extractor" \
      "$(redactor_labels "$T/redact-minus-one.sh" | wc -l | tr -d ' ')" \
      "$((EXPECTED_RULES - 1))"
# An unreadable file must not read as "no labels", which compares equal to an
# empty list and passes every row above. test-secret-guard.sh grew this row
# after a mutation sweep found its docs check reporting "could not run" as a
# pass, with every other row still green because none reached that branch.
check "a redactor that cannot be read is not a pass" \
      "$(redactor_labels "$T/no/such/file.sh")" "cannot read file.sh"

# --rules is introspection: it must answer on a machine with no transcript root
# at all, which is every CI runner, and it must not write.
BEFORE_RULES="$(manifest)"
"$PY" "$SCRUB" --rules >/dev/null 2>&1
check "--rules needs no transcript root and exits 0" "$?" "0"
check "...and writes nothing" \
      "$([[ "$BEFORE_RULES" == "$(manifest)" ]] && echo same || echo changed)" "same"

# And the loop closes here: a rule can reach both files, pass every row above,
# and still never be exercised. Every label but `by-name` (which has its own
# group) must have a fixture in SHAPE_FIXTURES.
fixture_labels="$(printf '%s\n' "${SHAPE_FIXTURES[@]}" | sed 's/|.*//' | sort -u)"
check "every advertised rule has a fixture in this suite" \
      "$(comm -23 <("$PY" "$SCRUB" --rules | grep -v '^by-name$') \
                  <(printf '%s\n' "$fixture_labels") | tr '\n' ' ')" ""

# --- the counts this suite is documented as running --------------------------
# docs_claim pins the number the prose quotes to EXPECTED_ROWS: it greps for a
# FIXED needle built from that number rather than parsing a count out of
# markdown, because a regex has to guess the shape of an English sentence and
# fails by matching nothing, which reads exactly like a pass. Whitespace is
# squashed because the sentence wraps. Which page owns this count and why:
# docs/REPO_CHECKS.md, "Where a check count lives".
docs_claim() {
  local f="$DOTFILES/$1" needle="${2-}"
  # The needle is MANDATORY, and this guard is not defensive programming. `tr`
  # squashes the whole page onto ONE line, so `grep -c -F ""` returns exactly
  # 1 -- the same value a real match returns, from a file it never looked at.
  # A mutation sweep found that: this function first took the needle as an
  # OPTIONAL argument defaulting to the check-count string, and emptying the
  # default left every row green. A hollow pass here is indistinguishable from
  # a true one, so the degenerate input is refused rather than guarded against.
  [[ -n "$needle" ]] || { printf 'no needle given'; return; }
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" | grep -c -F "$needle"
}

printf '\nthe count this suite is documented as running\n'
check "docs/TRANSCRIPT_SCRUB.md says $EXPECTED_ROWS checks" \
      "$(docs_claim docs/TRANSCRIPT_SCRUB.md \
         "\`scripts/test-scrub-transcript-secrets.sh\` ($EXPECTED_ROWS checks")" 1
# The unreadable branch needs a row of its own or nothing ever takes it, and an
# untaken branch is free to be wrong: in DO-698 a sweep caught this branch
# reporting "could not run" as a PASS, with every other row still green.
# The other number this page quotes, and the one DO-700 exists to keep true.
# Same mechanism and the same reason: a fixed needle, never a parse.
check "docs/TRANSCRIPT_SCRUB.md says $EXPECTED_RULES shared rule labels" \
      "$(docs_claim docs/TRANSCRIPT_SCRUB.md \
         "the same $EXPECTED_RULES rule labels")" 1
check "a documented file that cannot be read is not a pass" \
      "$(docs_claim no/such/file.md "anything")" "cannot read no/such/file.md"
# The other degenerate input, and the one a sweep actually caught: an empty
# needle matches the squashed page once and reads as a correct claim.
check "an empty needle is not a pass either" \
      "$(docs_claim docs/TRANSCRIPT_SCRUB.md "")" "no needle given"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))"
    FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
