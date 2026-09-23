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
#   catches      the shapes and the names, and the one row that is the entire
#                premise of the tool: a name-rule credential inside a JSON
#                string, which scripts/redact-secrets.sh provably misses. That
#                row asserts BOTH halves, so the premise cannot rot silently.
#   leaves alone placeholders, and byte-for-byte idempotence on a second run.
#                Most of a redactor's value is in what it does not touch.
#   discretion   refuse, roll back, skip -- the paths where it declines. Rule 3
#                (the live-session skip) is reachable only through the
#                documented test seam; an untestable branch is an untested one.
#   hygiene      no .prescrub survives, and a leftover one from an interrupted
#                run is swept.
#   contract     exit codes, the audit line, and root discovery.
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

echo "=== catches: the shapes, unchanged from redact-secrets.sh ==="

for pair in "$GHO:github-token" "$PAT:github-pat" "$ANT:anthropic-key" \
            "$XOX:slack-token" "$GLP:gitlab-pat" "$NTN:notion-token" \
            "$LIN:linear-key"; do
    cred="${pair%:*}"; kind="${pair##*:}"
    fresh
    line "a token $cred here" > "$ROOT/proj/s.jsonl"
    run --apply >/dev/null
    check "shape $kind is replaced" \
          "$(grep -c "REDACTED:$kind" "$ROOT/proj/s.jsonl")" "1"
done

fresh
line "a token $GHO here" > "$ROOT/proj/s.jsonl"
run --apply >/dev/null
check "...and the credential itself is gone" \
      "$(grep -cF "$GHO" "$ROOT/proj/s.jsonl")" "0"

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

# A row total, the house norm. `grep -c ✗` counts row NAMES, not outcomes; only
# this catches a check that silently stopped running.
EXPECTED_ROWS=60

# --- the count this suite is documented as running ---------------------------
# docs_claim pins the number the prose quotes to EXPECTED_ROWS: it greps for a
# FIXED needle built from that number rather than parsing a count out of
# markdown, because a regex has to guess the shape of an English sentence and
# fails by matching nothing, which reads exactly like a pass. Whitespace is
# squashed because the sentence wraps. Which page owns this count and why:
# docs/REPO_CHECKS.md, "Where a check count lives".
docs_claim() {
  local f="$DOTFILES/$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-scrub-transcript-secrets.sh\` ($EXPECTED_ROWS checks"
}

printf '\nthe count this suite is documented as running\n'
check "docs/TRANSCRIPT_SCRUB.md says $EXPECTED_ROWS checks" \
      "$(docs_claim docs/TRANSCRIPT_SCRUB.md)" 1
# The unreadable branch needs a row of its own or nothing ever takes it, and an
# untaken branch is free to be wrong: in DO-698 a sweep caught this branch
# reporting "could not run" as a PASS, with every other row still green.
check "a documented file that cannot be read is not a pass" \
      "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))"
    FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
