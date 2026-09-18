#!/usr/bin/env bash
# State table for scripts/check-doc-tokens.sh (DO-622).
#
# Hermetic: every row builds its own git repository, commits a BASE CLAUDE.md,
# then edits the working tree the way a migration would, and runs the checker
# against the base commit. Only the final row reads this repository.
#
# Every "must not flag" row is decoration unless a "must flag" row on the same
# token class sits beside it -- a checker that extracts nothing passes every
# pass-side row. The pairs are noted inline; the LOST-row needles name the
# token class, which only the fail path prints.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECKER=${CHECKER:-$here/check-doc-tokens.sh}
[ -x "$CHECKER" ] || { printf 'test-doc-tokens: %s is not executable\n' "$CHECKER" >&2; exit 2; }

pass=0; fail=0
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
          else fail=$((fail+1)); printf '  FAIL %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  ok   %s\n' "$1";;
    *) fail=$((fail+1)); printf '  FAIL %s (missing: %s)\n' "$1" "$3";; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail+1)); printf '  FAIL %s (unexpectedly present: %s)\n' "$1" "$3";;
    *) pass=$((pass+1)); printf '  ok   %s\n' "$1";; esac; }

# A base CLAUDE.md carrying one token of every class, plus enough filler that a
# single deleted paragraph stays well inside the 10% volume bound.
BASE_MD='# CLAUDE.md

## Accounts section

Fixed in DO-574 on 2026-09-10 by scripts/claude-pick-helper.sh, merged as (#135).
A second paragraph cites DO-613 and (#16).

### A subsection heading

Body text.
'
filler() { head -c 8000 /dev/zero | tr '\0' 'f'; printf '\n'; }

mkbase() { # mkbase <name> -> prints root; base commit is tagged `base`
    local d="$ROOT/$1"
    rm -rf "$d"; mkdir -p "$d/docs"
    git init -q -b main "$d" >/dev/null 2>&1
    git -C "$d" config user.email t@example.invalid; git -C "$d" config user.name test
    { printf '%s' "$BASE_MD"; filler; } > "$d/CLAUDE.md"
    git -C "$d" add -A >/dev/null; git -C "$d" commit -qm base >/dev/null
    git -C "$d" tag base
    printf '%s' "$d"
}
run() { "$CHECKER" "$1" base 2>&1; }
# Remove one line containing a string from CLAUDE.md, asserting the edit applied.
drop() { # drop <root> <literal>
    grep -vF -- "$2" "$1/CLAUDE.md" > "$1/CLAUDE.md.new" && mv "$1/CLAUDE.md.new" "$1/CLAUDE.md"
    if grep -qF -- "$2" "$1/CLAUDE.md"; then fail=$((fail+1)); printf '  FAIL fixture: drop %s did not apply\n' "$2"; fi
}

printf '\n== could not run is never a pass ==\n'
d="$ROOT/norepo"; mkdir -p "$d"; printf 'x\n' > "$d/CLAUDE.md"
out=$("$CHECKER" "$d" base 2>&1); check "not a git repository -> 2" 2 "$?"
d=$(mkbase badref); out=$("$CHECKER" "$d" no-such-ref 2>&1); check "an unresolvable base ref -> 2" 2 "$?"
contains "  and it names the ref" "$out" "no-such-ref"
d="$ROOT/nobasemd"; rm -rf "$d"; mkdir -p "$d"; git init -q -b main "$d"
git -C "$d" config user.email t@example.invalid; git -C "$d" config user.name test
printf 'x\n' > "$d/README.md"; git -C "$d" add -A; git -C "$d" commit -qm base; git -C "$d" tag base
printf 'x\n' > "$d/CLAUDE.md"
out=$(run "$d"); check "no CLAUDE.md at the base -> 2" 2 "$?"
# A base CLAUDE.md with no tokens at all: zero extracted must not read as clean.
d="$ROOT/notokens"; rm -rf "$d"; mkdir -p "$d"; git init -q -b main "$d"
git -C "$d" config user.email t@example.invalid; git -C "$d" config user.name test
printf 'plain prose only\n' > "$d/CLAUDE.md"; git -C "$d" add -A; git -C "$d" commit -qm base; git -C "$d" tag base
out=$(run "$d"); check "zero tokens extracted -> 2, not clean" 2 "$?"

printf '\n== an unchanged tree and an honest move both pass ==\n'
d=$(mkbase same); out=$(run "$d"); check "the unchanged tree passes" 0 "$?"
# 2 tickets + 1 date + 1 script + 2 PR refs + 2 headings, counted by hand from BASE_MD.
contains "  and says how many tokens it checked" "$out" "tokens=8 "
lacks "  with no colour escapes when redirected" "$out" $'\033'

# The shape of every migration PR: the section leaves CLAUDE.md for docs/,
# its heading demoted one level on the way.
d=$(mkbase move)
sed -n '/^## Accounts section/,$p' "$d/CLAUDE.md" | sed 's/^### /#### /' > "$d/docs/ACCOUNTS.md"
{ printf '# CLAUDE.md\n\nSee [accounts](docs/ACCOUNTS.md).\n'; } > "$d/CLAUDE.md"
out=$(run "$d"); check "a section moved to docs/, heading level changed, passes" 0 "$?"

# PROMOTION too, and it is the row that matters: a demoted `#### X` still
# CONTAINS `### X` as a substring, so the demote row above passes whether or
# not the level is ignored. Only a promoted heading can tell the two apart,
# and promotion is the common case -- a moved section becomes the top of its doc.
d=$(mkbase promote)
sed -n '/^## Accounts section/,$p' "$d/CLAUDE.md" | sed 's/^### /## /; s/^## Accounts/# Accounts/' > "$d/docs/ACCOUNTS.md"
{ printf '# CLAUDE.md\n\nSee [accounts](docs/ACCOUNTS.md).\n'; } > "$d/CLAUDE.md"
out=$(run "$d"); check "a section moved to docs/ with headings PROMOTED passes" 0 "$?"

printf '\n== each token class, lost ==\n'
for spec in "TICKET|DO-574|Fixed in DO-574" "DATE|2026-09-10|Fixed in DO-574" \
            "SCRIPT|scripts/claude-pick-helper.sh|Fixed in DO-574" "HEADING|A subsection heading|### A subsection"; do
    cls=${spec%%|*}; rest=${spec#*|}; tok=${rest%%|*}; line=${rest#*|}
    d=$(mkbase "lost-$cls"); drop "$d" "$line"
    out=$(run "$d"); check "$cls lost -> 1" 1 "$?"
    contains "  and the $cls class names it" "$out" "$cls"
    contains "  and the token is printed" "$out" "$tok"
done

printf '\n== PR references need a boundary ==\n'
# (#16) survives only as part of #160 -- that is not survival.
d=$(mkbase prb); drop "$d" "A second paragraph"; printf 'Cites DO-613 and #160 only.\n' >> "$d/CLAUDE.md"
out=$(run "$d"); check "#16 is not satisfied by #160" 1 "$?"
contains "  and the lost ref is #16" "$out" "#16"
d=$(mkbase prok); drop "$d" "A second paragraph"; printf 'Cites DO-613 and #16, then more.\n' >> "$d/CLAUDE.md"
out=$(run "$d"); check "#16 followed by a comma survives" 0 "$?"

printf '\n== where a token may survive ==\n'
# CHANGELOG is not searched: cited in the migration's own entry is not preserved.
d=$(mkbase changelog); drop "$d" "Fixed in DO-574"
printf 'Fixed in DO-574 on 2026-09-10 by scripts/claude-pick-helper.sh, merged as (#135).\n' > "$d/CHANGELOG.md"
out=$(run "$d"); check "surviving only in CHANGELOG.md does not count" 1 "$?"
# ...and the same line in .claude/ does count (paired with the row above).
d=$(mkbase dotclaude); drop "$d" "Fixed in DO-574"; mkdir -p "$d/.claude/skills/s"
printf 'Fixed in DO-574 on 2026-09-10 by scripts/claude-pick-helper.sh, merged as (#135).\n' > "$d/.claude/skills/s/SKILL.md"
out=$(run "$d"); check "surviving in .claude/ counts" 0 "$?"
# Retirement: the ledger resolves the token deliberately.
d=$(mkbase retired); drop "$d" "Fixed in DO-574"
printf '# Retired\n\n- DO-574 / 2026-09-10 / scripts/claude-pick-helper.sh / (#135): rule could no longer fire.\n' > "$d/docs/RETIRED.md"
out=$(run "$d"); check "a token recorded in docs/RETIRED.md passes" 0 "$?"

printf '\n== volume: moved, not deleted ==\n'
d=$(mkbase volbig); head -c 400 "$d/CLAUDE.md" > "$d/CLAUDE.md.new"
{ cat "$d/CLAUDE.md.new"; printf '%s' "$BASE_MD"; } > "$d/CLAUDE.md"; rm "$d/CLAUDE.md.new"
out=$(run "$d"); check "every token kept but the prose deleted -> 1" 1 "$?"
contains "  and it is the VOLUME finding" "$out" "VOLUME"
d=$(mkbase volsmall)
# sed, not a python3 heredoc: a fixture edit that needs a tool the runner might
# lack goes quiet, and the row then asserts rc=0 against an UNMODIFIED tree.
sed -i 's/f\{500\}//' "$d/CLAUDE.md"
[ "$(wc -c < "$d/CLAUDE.md")" -lt 8200 ] || { fail=$((fail+1)); printf '  FAIL fixture: volsmall trim did not apply\n'; }
out=$(run "$d"); check "a 6% trim stays inside the bound" 0 "$?"

printf '\n== the tree we ship ==\n'
repo=$(cd "$here/.." && pwd)
out=$("$CHECKER" "$repo" 2>&1); check "this repository passes against its own base" 0 "$?"
contains "  and reports a real base" "$out" "base=refs/"

# The suite's own total catches a row that VANISHED (an emptied loop), never a
# hollow one; only review catches that.
EXPECTED_TOTAL=33
printf '\n'
if [ "$((pass + fail))" -ne "$EXPECTED_TOTAL" ]; then
    printf 'test-doc-tokens: performed %d checks, expected %d — a row vanished\n' "$((pass + fail))" "$EXPECTED_TOTAL"
    exit 1
fi
if [ "$fail" -gt 0 ]; then printf 'test-doc-tokens: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; fi
printf 'test-doc-tokens: all %d checks passed\n' "$pass"
