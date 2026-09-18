#!/usr/bin/env bash
# State table for scripts/check-claude-md.sh.
#
# Hermetic: every row builds its own git repository under a temp dir and runs
# the checker against it with an explicit root. The ratchet reads real history,
# so the fixtures make real commits rather than mocking git -- a mocked history
# would pin nothing about the one rule that cannot be checked any other way.
# Only the rows at the end read this repository, to assert the tree we ship
# passes.
#
# Two rules about needles, both learned in this repo before this suite existed:
#
#   - A `contains` needle must be UNIQUE TO THE RULE. This checker has eight
#     rules and several print a path in the same shape, so a bare filename is
#     ambiguous by construction. Anchor on the message prefix (SIZE:/AGGR:/
#     CAP-CARD:/CAP-SKILL:/FM:/LINK:/ORPH:/GLOB:).
#   - Check the needle against what the PASS path prints too. Every rule here
#     prints its prefix on both paths for the counters, so rc is asserted
#     alongside, and the fail-only wording is what the needle matches.
#
# Every "must not flag" row is DECORATION unless a "must flag" row on the same
# rule sits beside it -- a checker with the rule deleted passes every pass-side
# row. The pairs are noted inline; do not delete one half in a tidy-up.
#
# COST: ~60 fixture repositories, each with real commits. Run mutation sweeps
# serially under `nice -n 19`; this box has been OOM-killed at loadavg 42 during
# a 34-mutant sweep of a sibling suite.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECKER=${CHECKER:-$here/check-claude-md.sh}
CONF_SRC="$here/context-budget.conf"
[ -x "$CHECKER" ] || { printf 'test-claude-md: %s is not executable\n' "$CHECKER" >&2; exit 2; }
[ -r "$CONF_SRC" ] || { printf 'test-claude-md: %s is not readable\n' "$CONF_SRC" >&2; exit 2; }

pass=0; fail=0
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

check() { # check <desc> <expected-rc> <actual-rc>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"; fi
}
contains() { case "$2" in *"$3"*) pass=$((pass+1)); printf '  ok   %s\n' "$1";;
    *) fail=$((fail+1)); printf '  FAIL %s (missing: %s)\n' "$1" "$3";; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail+1)); printf '  FAIL %s (unexpectedly present: %s)\n' "$1" "$3";;
    *) pass=$((pass+1)); printf '  ok   %s\n' "$1";; esac; }

# --- fixtures ------------------------------------------------------------
seed() { # seed <file> <bytes>
    local f=$1 n=$2 cur pad
    printf '# CLAUDE.md\n\nSee [readme](README.md).\n' > "$f"
    cur=$(wc -c < "$f")
    pad=$(( n - cur ))
    if [ "$pad" -gt 0 ]; then head -c "$pad" /dev/zero | tr '\0' 'x' >> "$f"; fi
}
mkrepo() { # mkrepo <name> -> prints root
    local d="$ROOT/$1"
    rm -rf "$d"; mkdir -p "$d/scripts"
    git init -q -b main "$d" >/dev/null 2>&1
    git -C "$d" config user.email t@example.invalid
    git -C "$d" config user.name test
    cp "$CONF_SRC" "$d/scripts/context-budget.conf"
    printf '# readme\n' > "$d/README.md"
    printf '%s' "$d"
}
guard_in() { cp "$CHECKER" "$1/scripts/check-claude-md.sh"; }   # makes a commit "guard-bearing"
snap() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm "${2:-c}" >/dev/null 2>&1; }

printf '\n== A. exit semantics: could not run is never a pass ==\n'
d=$(mkrepo a1); seed "$d/CLAUDE.md" 500; snap "$d"; rm "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "A1 CLAUDE.md missing -> 2" 2 "$?"
contains "A1 says which file" "$out" "CLAUDE.md is missing"

d="$ROOT/a2"; rm -rf "$d"; mkdir -p "$d/scripts"; cp "$CONF_SRC" "$d/scripts/"; seed "$d/CLAUDE.md" 500
out=$("$CHECKER" "$d" 2>&1); check "A2 not a git repository -> 2" 2 "$?"

d=$(mkrepo a3src); seed "$d/CLAUDE.md" 500; guard_in "$d"; snap "$d"; snap "$d" second
git clone -q --depth 1 "file://$d" "$ROOT/a3" >/dev/null 2>&1
if [ -d "$ROOT/a3" ]; then
    out=$("$CHECKER" "$ROOT/a3" 2>&1); check "A3 shallow clone -> 2 (a depth-1 clone makes min==today)" 2 "$?"
    contains "A3 names the cause" "$out" "shallow"
else
    fail=$((fail+2)); printf '  FAIL A3 could not build a shallow clone fixture\n'
fi

d=$(mkrepo a4); seed "$d/CLAUDE.md" 500; snap "$d"
# A DIRECTORY named CLAUDE.md, not chmod 000: CI often runs as root, which reads
# mode-000 files, so a chmod fixture cannot reach the branch it names.
rm "$d/CLAUDE.md"; mkdir "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "A4 CLAUDE.md is a directory -> 2" 2 "$?"

d=$(mkrepo a5); seed "$d/CLAUDE.md" 500; mkdir -p "$d/.claude"; snap "$d"
out=$("$CHECKER" "$d" 2>&1); check "A5 empty .claude/ -> 0" 0 "$?"
contains "A5 an empty enumeration is stated, not implied" "$out" "rules=0 skills=0"

d=$(mkrepo a6); seed "$d/CLAUDE.md" 500; snap "$d"
out=$("$CHECKER" --nope 2>&1); check "A6 unrecognised argument -> 2" 2 "$?"

d=$(mkrepo a7); seed "$d/CLAUDE.md" 500; snap "$d"; rm "$d/scripts/context-budget.conf"
out=$("$CHECKER" "$d" 2>&1); check "A7 missing budget conf -> 2" 2 "$?"

d=$(mkrepo a8); seed "$d/CLAUDE.md" 500; snap "$d"
out=$("$CHECKER" "$d" 2>/dev/null)
lacks "A8 redirected output carries no colour escapes" "$out" $'\033'

d=$(mkrepo a9); seed "$d/CLAUDE.md" 500; snap "$d"
sed 's/^EXPECTED_CHECKS=8$/EXPECTED_CHECKS=9/' "$CHECKER" > "$ROOT/checker9.sh"; chmod +x "$ROOT/checker9.sh"
grep -q '^EXPECTED_CHECKS=9$' "$ROOT/checker9.sh" || { fail=$((fail+1)); printf '  FAIL A9 fixture edit did not apply\n'; }
out=$("$ROOT/checker9.sh" "$d" 2>&1); check "A9 a vanished check -> 3, not 1" 3 "$?"
contains "A9 says a check vanished" "$out" "a check vanished"

printf '\n== B. the ratchet ==\n'
d=$(mkrepo b1); seed "$d/CLAUDE.md" 30000; guard_in "$d"; snap "$d"
out=$("$CHECKER" "$d" 2>&1); check "B1 unchanged size passes" 0 "$?"
contains "B1 base names the ref actually used" "$out" "base=refs/heads/main"

d=$(mkrepo b2); seed "$d/CLAUDE.md" 30000; guard_in "$d"; snap "$d"
seed "$d/CLAUDE.md" 31500          # min 30000 + SLACK 1500, exactly at the ceiling
out=$("$CHECKER" "$d" 2>&1); check "B2 exactly at the ceiling passes (kills >= vs >)" 0 "$?"

d=$(mkrepo b3); seed "$d/CLAUDE.md" 30000; guard_in "$d"; snap "$d"
seed "$d/CLAUDE.md" 31501
out=$("$CHECKER" "$d" 2>&1); check "B3 one byte over the ceiling fails" 1 "$?"
contains "B3 is the SIZE rule" "$out" "SIZE: CLAUDE.md is 31501"

# THE RATCHET ROW. An earlier guard-bearing commit was smaller, so the minimum --
# not the parent -- sets the ceiling. A rate limit (parent+SLACK) passes this.
d=$(mkrepo b4); seed "$d/CLAUDE.md" 30000; guard_in "$d"; snap "$d"
seed "$d/CLAUDE.md" 40000; snap "$d" grew
seed "$d/CLAUDE.md" 40100
out=$("$CHECKER" "$d" 2>&1); check "B4 ratchet: the MINIMUM binds, not the parent" 1 "$?"
contains "B4 quotes the ratcheted ceiling" "$out" "ceiling=31500"

# THE ANCHOR ROW. Commits predating the guard are not counted, so a repo that was
# small long ago is not held to that. min over ALL history passes this.
d=$(mkrepo b5); seed "$d/CLAUDE.md" 5000; snap "$d" "before the guard"
seed "$d/CLAUDE.md" 30000; guard_in "$d"; snap "$d" "guard lands"
out=$("$CHECKER" "$d" 2>&1); check "B5 anchor: pre-guard commits are not counted" 0 "$?"

# The scan stops at the first commit that LACKS the guard, rather than skipping
# it, so a delete-and-re-add is counted only from the re-add. That is the more
# permissive reading and it is deliberate -- deleting the guard fails the CI job
# loudly, and this repo squash-merges, so such a pair collapses into one
# guard-bearing commit. Without this row, `exit` and `next` are indistinguishable
# and the mutant swapping them survives.
d=$(mkrepo b10); seed "$d/CLAUDE.md" 8000; guard_in "$d"; snap "$d" "guard, small"
rm "$d/scripts/check-claude-md.sh"; seed "$d/CLAUDE.md" 40000; snap "$d" "guard removed"
guard_in "$d"; snap "$d" "guard re-added"
out=$("$CHECKER" "$d" 2>&1); check "B10 the scan stops at the first guardless commit" 0 "$?"
contains "B10 counts only the re-add, not the 8000 before the gap" "$out" "min=40000"

d=$(mkrepo b6); seed "$d/CLAUDE.md" 100; guard_in "$d"; snap "$d"
seed "$d/CLAUDE.md" 14000
out=$("$CHECKER" "$d" 2>&1); check "B6 the floor stops the ratchet becoming a wall" 0 "$?"
contains "B6 reports the floor as the ceiling" "$out" "ceiling=20000"

d=$(mkrepo b7); seed "$d/CLAUDE.md" 100; guard_in "$d"; snap "$d"
seed "$d/CLAUDE.md" 20001
out=$("$CHECKER" "$d" 2>&1); check "B7 the floor is a ceiling, not a free pass" 1 "$?"

d=$(mkrepo b8); seed "$d/CLAUDE.md" 30000; snap "$d"    # no guard in history
out=$("$CHECKER" "$d" 2>&1); check "B8 bootstrap (no guard-bearing commit) passes" 0 "$?"
contains "B8 says it bootstrapped rather than pretending it measured" "$out" "base=bootstrap"

# Bootstrap is not an escape hatch: every other rule still runs.
d=$(mkrepo b9); printf '# c\n\n[gone](docs/GONE.md)\n' > "$d/CLAUDE.md"; snap "$d"
out=$("$CHECKER" "$d" 2>&1); check "B9 bootstrap + a broken link still fails" 1 "$?"
contains "B9 fails on the link rule" "$out" "LINK:"

printf '\n== C. the aggregate: prose moved to another always-loaded surface ==\n'
d=$(mkrepo c1); seed "$d/CLAUDE.md" 10000; guard_in "$d"; snap "$d"
mkdir -p "$d/.claude/rules"
printf -- '---\npaths:\n  - CLAUDE.md\n---\n[c](../../CLAUDE.md)\n' > "$d/.claude/rules/a.md"
printf '\n[card](.claude/rules/a.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "C1 one small card is within the allowance" 0 "$?"

d=$(mkrepo c2); seed "$d/CLAUDE.md" 10000; guard_in "$d"; snap "$d"
mkdir -p "$d/.claude/rules"
for i in $(seq 1 15); do
    { printf -- '---\npaths:\n  - CLAUDE.md\n---\n[c](../../CLAUDE.md)\n'
      head -c 1800 /dev/zero | tr '\0' 'y'; printf '\n'; } > "$d/.claude/rules/c$i.md"
    printf '\n[card](.claude/rules/c%s.md)\n' "$i" >> "$d/CLAUDE.md"
done
out=$("$CHECKER" "$d" 2>&1); check "C2 15 cards under the per-card cap still bust the aggregate" 1 "$?"
contains "C2 is the AGGR rule" "$out" "AGGR: always-loaded total"

# @-imports are inlined into context, so they are counted.
d=$(mkrepo c3); seed "$d/CLAUDE.md" 10000; guard_in "$d"; snap "$d"
head -c 30000 /dev/zero | tr '\0' 'z' > "$d/big-import.md"
printf '\n@big-import.md\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "C3 an @-import counts against the aggregate" 1 "$?"

# Skills are excluded because their bodies load on demand. This row ENCODES that
# decision -- if skills turn out to be eagerly loaded, this is the row to flip.
d=$(mkrepo c4); seed "$d/CLAUDE.md" 10000; guard_in "$d"; snap "$d"
mkdir -p "$d/.claude/skills/s/references"
printf -- '---\nname: s\ndescription: d\n---\n[c](../../../CLAUDE.md)\n' > "$d/.claude/skills/s/SKILL.md"
head -c 200000 /dev/zero | tr '\0' 'q' > "$d/.claude/skills/s/references/big.md"
printf '\n[skill](.claude/skills/s/SKILL.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "C4 a skill's references/ are uncapped and uncounted" 0 "$?"

printf '\n== D. per-file caps ==\n'
mkcard() { # mkcard <root> <name> <bytes>
    mkdir -p "$1/.claude/rules"
    { printf -- '---\npaths:\n  - CLAUDE.md\n---\n[c](../../CLAUDE.md)\n'
      head -c "$3" /dev/zero | tr '\0' 'y'; printf '\n'; } > "$1/.claude/rules/$2.md"
    printf '\n[card](.claude/rules/%s.md)\n' "$2" >> "$1/CLAUDE.md"
}
d=$(mkrepo d1); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkcard "$d" ok 1900
out=$("$CHECKER" "$d" 2>&1); check "D1 a card under the cap passes" 0 "$?"

d=$(mkrepo d2); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkcard "$d" big 2100
out=$("$CHECKER" "$d" 2>&1); check "D2 a card over the cap fails" 1 "$?"
contains "D2 is the card cap, not the skill cap" "$out" "CAP-CARD:"

d=$(mkrepo d3); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/.claude/skills/s"
{ printf -- '---\nname: s\ndescription: d\n---\n[c](../../../CLAUDE.md)\n'
  head -c 40000 /dev/zero | tr '\0' 'y'; } > "$d/.claude/skills/s/SKILL.md"
printf '\n[skill](.claude/skills/s/SKILL.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "D3 a SKILL.md over the cap fails" 1 "$?"
contains "D3 is the skill cap, not the card cap" "$out" "CAP-SKILL:"

printf '\n== E. frontmatter ==\n'
d=$(mkrepo e1); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkcard "$d" good 100
out=$("$CHECKER" "$d" 2>&1); check "E1 a valid card passes" 0 "$?"

d=$(mkrepo e2); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkdir -p "$d/.claude/rules"
printf 'no frontmatter here\n[c](../../CLAUDE.md)\n' > "$d/.claude/rules/x.md"
printf '\n[card](.claude/rules/x.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "E2 a card with no frontmatter fails" 1 "$?"
contains "E2 is the FM rule" "$out" "FM:"

d=$(mkrepo e3); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkdir -p "$d/.claude/rules"
printf -- '---\ndescription: x\n---\n[c](../../CLAUDE.md)\n' > "$d/.claude/rules/x.md"
printf '\n[card](.claude/rules/x.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "E3 a card with no paths: fails" 1 "$?"

# An empty answer is never agreement: a card scoped to nothing never fires.
d=$(mkrepo e4); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkdir -p "$d/.claude/rules"
printf -- '---\npaths: []\n---\n[c](../../CLAUDE.md)\n' > "$d/.claude/rules/x.md"
printf '\n[card](.claude/rules/x.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "E4 paths: [] fails -- it would never fire" 1 "$?"

d=$(mkrepo e5); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkdir -p "$d/.claude/skills/s"
printf -- '---\ndescription: d\n---\n[c](../../../CLAUDE.md)\n' > "$d/.claude/skills/s/SKILL.md"
printf '\n[skill](.claude/skills/s/SKILL.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "E5 a SKILL.md with no name: fails" 1 "$?"

d=$(mkrepo e6); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkdir -p "$d/.claude/skills/s"
printf -- '---\nname: s\ndescription:\n---\n[c](../../../CLAUDE.md)\n' > "$d/.claude/skills/s/SKILL.md"
printf '\n[skill](.claude/skills/s/SKILL.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "E6 an empty description: fails" 1 "$?"

# CRLF frontmatter must still parse: this repo has already shipped a CRLF disagreement.
d=$(mkrepo e7); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkdir -p "$d/.claude/rules"
printf -- '---\r\npaths:\r\n  - CLAUDE.md\r\n---\r\n[c](../../CLAUDE.md)\r\n' > "$d/.claude/rules/x.md"
printf '\n[card](.claude/rules/x.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "E7 CRLF frontmatter still parses" 0 "$?"

printf '\n== F. links ==\n'
d=$(mkrepo f1); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs"; printf '# real\n' > "$d/docs/REAL.md"
printf '\n[r](docs/REAL.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "F1 a resolving link passes" 0 "$?"

d=$(mkrepo f2); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
printf '\n[g](docs/GONE.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "F2 a broken link fails" 1 "$?"
contains "F2 names the missing target" "$out" "docs/GONE.md does not exist"

# A small CLAUDE.md must not short-circuit the other rules.
d=$(mkrepo f3); printf '# c\n\n[g](docs/GONE.md)\n' > "$d/CLAUDE.md"; guard_in "$d"; snap "$d"
out=$("$CHECKER" "$d" 2>&1); check "F3 a 900-byte CLAUDE.md is still link-checked" 1 "$?"

# Resolution is relative to the CONTAINING file, not the repo root.
d=$(mkrepo f4); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs" "$d/.claude/rules"; printf '# real\n' > "$d/docs/REAL.md"
printf -- '---\npaths:\n  - CLAUDE.md\n---\n[up](../../docs/REAL.md)\n' > "$d/.claude/rules/x.md"
printf '\n[card](.claude/rules/x.md)\n[r](docs/REAL.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "F4 a card link resolves relative to the card" 0 "$?"

# CLAUDE.md carries ~50 fences full of example paths; checking them is permanent red.
d=$(mkrepo f5); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
# shellcheck disable=SC2016  # the fence and link are literal input under test
printf '\n```\n[x](docs/NOT_REAL.md)\n```\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "F5 a link inside a fence is not checked" 0 "$?"

d=$(mkrepo f6); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
printf '\n[e](https://example.invalid/x)\n[m](mailto:a@b.invalid)\n[a](#anchor)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "F6 external, mailto and bare anchors are skipped" 0 "$?"

d=$(mkrepo f7); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs"; printf '# real\n' > "$d/docs/REAL.md"
printf '\n[r](docs/REAL.md#a-section)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "F7 an anchor on a real file checks the file only" 0 "$?"

printf '\n== G. reachability ==\n'
d=$(mkrepo g1); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs"; printf '# orphan\n' > "$d/docs/ORPHAN.md"
out=$("$CHECKER" "$d" 2>&1); check "G1 an unlinked docs page fails" 1 "$?"
contains "G1 is the ORPH rule" "$out" "ORPH:"

d=$(mkrepo g2); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs"; printf '# a\n' > "$d/docs/A.md"
printf '\n[a](docs/A.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "G2 a page linked from CLAUDE.md passes" 0 "$?"

# Transitive: CLAUDE.md -> A -> B.
d=$(mkrepo g3); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs"; printf '# a\n\n[b](B.md)\n' > "$d/docs/A.md"; printf '# b\n' > "$d/docs/B.md"
printf '\n[a](docs/A.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "G3 reachability is transitive" 0 "$?"

# THE ISLAND ROW. Two pages linking only to each other pass an inbound-link
# count and must fail a reachability walk.
d=$(mkrepo g4); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs"; printf '# c\n\n[d](D.md)\n' > "$d/docs/C.md"; printf '# d\n\n[c](C.md)\n' > "$d/docs/D.md"
out=$("$CHECKER" "$d" 2>&1); check "G4 an island of two mutually-linked pages fails" 1 "$?"

d=$(mkrepo g5); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs/plans" "$d/docs/superpowers"
printf '# p\n' > "$d/docs/plans/P.md"; printf '# s\n' > "$d/docs/superpowers/S.md"
out=$("$CHECKER" "$d" 2>&1); check "G5 docs/plans and docs/superpowers are excluded" 0 "$?"

d=$(mkrepo g6); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs"; printf '# a\n' > "$d/docs/A.md"
printf '\n[a](docs/A.md)\n' >> "$d/README.md"
out=$("$CHECKER" "$d" 2>&1); check "G6 README.md is a root too" 0 "$?"

# CHANGELOG is deliberately NOT a root: cited by a changelog entry is mentioned, not routed.
d=$(mkrepo g7); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"
mkdir -p "$d/docs"; printf '# a\n' > "$d/docs/A.md"
printf '# changelog\n\n[a](docs/A.md)\n' > "$d/CHANGELOG.md"
out=$("$CHECKER" "$d" 2>&1); check "G7 CHANGELOG.md is not a reachability root" 1 "$?"

printf '\n== H. paths: globs ==\n'
d=$(mkrepo h1); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkdir -p "$d/.claude/rules"
printf -- '---\npaths:\n  - CLAUDE.md\n---\n[c](../../CLAUDE.md)\n' > "$d/.claude/rules/x.md"
printf '\n[card](.claude/rules/x.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "H1 a glob that matches passes" 0 "$?"

d=$(mkrepo h2); seed "$d/CLAUDE.md" 5000; guard_in "$d"; snap "$d"; mkdir -p "$d/.claude/rules"
printf -- '---\npaths:\n  - src/**/*.rs\n---\n[c](../../CLAUDE.md)\n' > "$d/.claude/rules/x.md"
printf '\n[card](.claude/rules/x.md)\n' >> "$d/CLAUDE.md"
out=$("$CHECKER" "$d" 2>&1); check "H2 a glob matching nothing fails -- that card can never fire" 1 "$?"
contains "H2 is the GLOB rule" "$out" "GLOB:"

printf '\n== I. the tree we ship ==\n'
repo=$(cd "$here/.." && pwd)
out=$("$CHECKER" "$repo" 2>&1); rc=$?
check "I1 this repository passes" 0 "$rc"
contains "I1 prints a summary line" "$out" "SUMMARY: size="
# Not decoration: recomputed here by a differently-written loop, so a checker
# that printed a ceiling it did not use fails this even while I1 passes.
want_min=$(git -C "$repo" rev-list --first-parent HEAD | while read -r c; do
        if git -C "$repo" cat-file -e "$c:scripts/check-claude-md.sh" 2>/dev/null; then
            git -C "$repo" cat-file -s "$c:CLAUDE.md" 2>/dev/null
        else break; fi
    done | sort -n | head -1)
if [ -z "$want_min" ]; then want_min=$(wc -c < "$repo/CLAUDE.md" | tr -d ' '); fi
want_ceiling=$(( want_min + 1500 )); [ "$want_ceiling" -ge 20000 ] || want_ceiling=20000
contains "I2 the printed ceiling matches an independent recomputation" "$out" "ceiling=$want_ceiling "
contains "I3 CI invokes the state table" \
    "$(cat "$repo/.github/workflows/ci.yml")" "./scripts/test-claude-md.sh"
contains "I4 CI invokes the checker against the shipped tree" \
    "$(cat "$repo/.github/workflows/ci.yml")" "./scripts/check-claude-md.sh"

# The suite's own total: this catches a row that VANISHED (an emptied loop, an
# early exit in a fixture builder) rather than one that failed. It does NOT
# catch a hollow rule -- one still called, still counted, always returning ok.
# Only review catches that; do not claim otherwise.
EXPECTED_TOTAL=72

printf '\n'
if [ "$((pass + fail))" -ne "$EXPECTED_TOTAL" ]; then
    printf 'test-claude-md: performed %d checks, expected %d — a row vanished\n' \
        "$((pass + fail))" "$EXPECTED_TOTAL"
    exit 1
fi
if [ "$fail" -gt 0 ]; then
    printf 'test-claude-md: %d passed, %d FAILED\n' "$pass" "$fail"
    exit 1
fi
printf 'test-claude-md: all %d checks passed\n' "$pass"
