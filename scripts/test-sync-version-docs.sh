#!/usr/bin/env bash
# State table for scripts/sync-version-docs.sh (DO-631).
#
# HERMETIC. Every row builds its own tree under a temp dir -- a copy of the
# script, a synthetic .mise.toml and a synthetic docs/TOOL_VERSION_UPDATES.md --
# and runs the copy there, so DOTFILES_ROOT resolves to the fixture. Nothing
# reads this repository except the two deliberate integration rows at the end,
# which assert that the tree we actually ship passes.
#
# Fixture versions are synthetic (1.0.<n>). Copying the real .mise.toml would
# make every row depend on what this repo happens to pin, and a version bump
# would then look like a regression in the checker.
#
# The tool list is READ OUT OF THE SUT rather than duplicated here, so adding a
# 15th tool to TOOL_ORDER does not silently invalidate every fixture. The
# extraction is asserted, not trusted: one that produced nothing would build an
# empty table, and rows expecting a clean run would fail for the wrong reason.
#
# WHAT THIS SUITE IS FOR. sync-version-docs.sh used to read the table as
# `sed -n '48,61p'` -- a window coupled both to every line above the table and
# to its own length. Measured before the fix, on copies of the real tree:
#
#   - one blank line inserted at the top => `fastfetch: missing from docs`,
#     exit 1. This is DO-627, hit for real in CI; the workaround then was to
#     keep the correction to one line.
#   - a 15th tool added consistently to .mise.toml, TOOL_ORDER and the table
#     => `ripgrep2: missing from docs`, exit 1. A false positive on a tree that
#     is correct. (The issue predicted this would be the SILENT case. It is
#     not -- it is loud. The silent case is the next one.)
#   - a row added to the table that TOOL_ORDER does not name => exit 0,
#     `All tool versions are in sync!`. Nothing compared it and nothing said
#     so. That is the "rows fail by looking green" shape, and the rows under
#     "the silent direction" below are the ones that exist for it.
#   - `--update` on an unchanged tree appended a blank line, every run. The
#     blank lines under the table in the tracked doc are that bug's residue.
#   - `--update` on a shifted tree deleted the |---| separator row, so the
#     table stopped rendering, and left a duplicate last row below it -- while
#     being the remedy the failing --check tells you to run.
#
# NEEDLES. A needle must be unique to the rule it names AND absent from the
# pass path. "missing from docs" is printed by the genuinely-missing-row rule
# as well as by the old window bug, so the position-independence rows assert
# exit status and the absence of that string, never its presence.
#
# MUTATION SWEEPS. Point SUT at a mutated copy:
#     SUT=/tmp/mutant/sync-version-docs.sh ./scripts/test-sync-version-docs.sh
# This suite is cheap (no interpreter per row), but run sweeps serially and
# `nice -n 19` anyway -- this box has been OOM-killed at loadavg 42.
set -uo pipefail

SUT=${SUT:-}
if [ -z "$SUT" ]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    SUT="$here/sync-version-docs.sh"
fi
[ -r "$SUT" ] || { printf 'test-sync-version-docs: cannot read %s\n' "$SUT" >&2; exit 2; }

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

pass=0; fail=0
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }

check() { # label expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi
}
contains() { # label haystack needle
    case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — output does not contain '$3'" ;; esac
}
lacks() { # label haystack needle
    case "$2" in *"$3"*) bad "$1 — output unexpectedly contains '$3'" ;; *) ok "$1" ;; esac
}

# --- the tool list the SUT actually carries ----------------------------------
mapfile -t TOOLS < <(
    sed -n 's/^TOOL_ORDER=(\(.*\))$/\1/p' "$SUT" | tr -d '"' | tr ' ' '\n' | grep -v '^$'
)
if [ "${#TOOLS[@]}" -lt 2 ]; then
    printf 'test-sync-version-docs: could not read TOOL_ORDER out of %s (got %d names)\n' \
        "$SUT" "${#TOOLS[@]}" >&2
    exit 2
fi
NTOOLS=${#TOOLS[@]}

# --- fixtures ----------------------------------------------------------------
DOC=docs/TOOL_VERSION_UPDATES.md

# mkfix <name> -> prints the fixture root. .mise.toml and the table agree, so
# the fixture passes untouched; each row then breaks exactly one thing.
mkfix() {
    local d="$ROOT/$1" i t
    mkdir -p "$d/scripts" "$d/docs"
    cp "$SUT" "$d/scripts/sync-version-docs.sh"
    chmod +x "$d/scripts/sync-version-docs.sh"

    { printf '[tools]\n'
      i=0; for t in "${TOOLS[@]}"; do printf '%s = "1.0.%d"\n' "$t" "$i"; i=$((i + 1)); done
    } > "$d/.mise.toml"

    { printf '# Tool Version Updates\n\n'
      printf 'A preamble paragraph, which is what DO-627 grew by one line.\n\n'
      printf '## Managed Tools\n\n'
      printf '### Core Tools (%d essential)\n' "$NTOOLS"
      printf '| Tool | Purpose | Current Version |\n'
      printf '|------|---------|----------------|\n'
      i=0; for t in "${TOOLS[@]}"; do printf '| %s | Purpose of %s | 1.0.%d |\n' "$t" "$t" "$i"; i=$((i + 1)); done
      printf '\n'
      printf '### Optional Tools\n'
      printf -- '- something not in a table\n\n'
      # A SECOND table, further down, whose first column repeats a Core tool
      # with a different version. This is what the old 48,61 window was really
      # guarding against, and it is why the anchored slice must stop at the
      # blank line rather than at "the next thing that is not a pipe".
      printf '### Known Compatibility Issues\n\n'
      printf '| Tool | Version | Issue | Workaround |\n'
      printf '|------|---------|-------|-----------|\n'
      printf '| %s | 7.7.7-COMPAT | Some issue | Upgrade |\n' "${TOOLS[0]}"
    } > "$d/$DOC"
    printf '%s' "$d"
}

# Insert <n> blank lines above the table, at the top of the file.
shift_down() { local d=$1 n=$2; awk -v n="$n" 'NR==3{for(i=0;i<n;i++) print ""} {print}' "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"; }
# Remove a line above the table.
shift_up()   { local d=$1; awk 'NR!=3' "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"; }

# The full text of the Nth Core row, as mkfix wrote it. Fixtures address rows by
# their whole line: `| bat |` alone also prefixes the compatibility table's row,
# and a fixture edit that hits two lines instead of one is a fixture that tests
# something other than what it says (caught here doing exactly that).
core_row() { printf '| %s | Purpose of %s | 1.0.%d |' "${TOOLS[$1]}" "${TOOLS[$1]}" "$1"; }

# Data rows in the Core table, counted WITHOUT reusing the SUT's own slicing
# logic -- a count that asked the script where the table ends could not detect
# the script getting that wrong. Everything piped up to "### Optional Tools",
# less the header and the |---| separator.
core_rows() {
    awk '/^### Optional Tools/ { exit } /^\|/ { n++ } END { print (n > 2 ? n - 2 : 0) }' "$1/$DOC"
}

OUT=""; RC=0
invoke() { local d=$1; shift; OUT=$("$d/scripts/sync-version-docs.sh" "$@" 2>&1) && RC=0 || RC=$?; }

printf '\n=== scripts/sync-version-docs.sh state table ===\n'

# --- the fixture itself ------------------------------------------------------
printf '\n== the baseline fixture is clean ==\n'
d=$(mkfix base); invoke "$d"
check "an untouched fixture passes" 0 "$RC"
contains "  and says so" "$OUT" "All tool versions are in sync!"
check "the fixture carries every TOOL_ORDER entry" "$NTOOLS" "$(core_rows "$d")"

# --- position independence: the loud direction (DO-627) ----------------------
# The needle is deliberately the ABSENCE of "missing from docs": that string is
# also what a genuinely absent row prints, so asserting its presence elsewhere
# would not distinguish the window bug from a real miss.
printf '\n== the table may sit anywhere in the file ==\n'
for n in 1 2 7 40; do
    d=$(mkfix "down$n"); shift_down "$d" "$n"; invoke "$d"
    check "table pushed down $n line(s): still passes" 0 "$RC"
done
d=$(mkfix down1b); shift_down "$d" 1; invoke "$d"
lacks "  and never reports a row as missing" "$OUT" "missing from docs"
contains "  it reports sync instead" "$OUT" "All tool versions are in sync!"

d=$(mkfix up1); shift_up "$d"; invoke "$d"
check "table pulled UP one line: still passes" 0 "$RC"
lacks "  and never reports a row as missing" "$OUT" "missing from docs"

# The table as the very last thing in the file: no blank line ends it, so the
# slice has to terminate at EOF rather than run off it.
d=$(mkfix eof)
sed -n "1,$(grep -n "^| ${TOOLS[$((NTOOLS - 1))]} |" "$d/$DOC" | head -1 | cut -d: -f1)p" "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"
invoke "$d"
check "table at EOF with nothing after it: passes" 0 "$RC"

# --- the table may GROW ------------------------------------------------------
# A 15th tool, added consistently everywhere. Before the fix this failed with
# "missing from docs" -- a false positive on a correct tree -- because the
# window was exactly as long as TOOL_ORDER.
printf '\n== the table may grow ==\n'
d=$(mkfix grow)
printf 'newtool = "4.5.6"\n' >> "$d/.mise.toml"
sed -i 's/^TOOL_ORDER=(\(.*\))$/TOOL_ORDER=(\1 "newtool")/' "$d/scripts/sync-version-docs.sh"
sed -i 's/^    \["'"${TOOLS[0]}"'"\]=\(.*\)$/&\n    ["newtool"]="A fifteenth tool"/' "$d/scripts/sync-version-docs.sh"
awk -v last="$(core_row $((NTOOLS - 1)))" '
    $0 == last { print; print "| newtool | A fifteenth tool | 4.5.6 |"; next } { print }
' "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"
# Assert the three fixture edits APPLIED. A fixture that failed to build still
# runs and still passes, which reads exactly like a survivor.
check "  fixture: TOOL_ORDER gained newtool" 1 "$(grep -c '"newtool")' "$d/scripts/sync-version-docs.sh")"
check "  fixture: a description was added"   1 "$(grep -c '\["newtool"\]=' "$d/scripts/sync-version-docs.sh")"
check "  fixture: the table gained a row"    1 "$(grep -c '^| newtool |' "$d/$DOC")"
invoke "$d"
check "a 15th tool, consistent everywhere: passes" 0 "$RC"
lacks "  and is not reported as missing" "$OUT" "missing from docs"

# --- the silent direction ----------------------------------------------------
# THE reason this issue exists. Before the fix each of these exited 0 printing
# "All tool versions are in sync!".
printf '\n== the silent direction: rows nothing compares ==\n'
d=$(mkfix docsonly)
awk -v last="$(core_row $((NTOOLS - 1)))" '
    $0 == last { print; print "| strayrow | Never checked | 0.0.1-STALE |"; next } { print }
' "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"
check "  fixture: the stray row is in the table" 1 "$(grep -c '^| strayrow |' "$d/$DOC")"
invoke "$d"
check "a docs row absent from TOOL_ORDER: FAILS" 1 "$RC"
contains "  and the row is named"  "$OUT" "strayrow"
contains "  as unverifiable"       "$OUT" "not in TOOL_ORDER"
lacks    "  and the run does NOT claim sync" "$OUT" "All tool versions are in sync!"

# A duplicated row leaves the NAME SETS equal and only the counts unequal, so
# the set check above cannot see it. It is why the count assertion is separate.
d=$(mkfix dupe)
awk -v first="$(core_row 0)" '
    $0 == first { print; print; next } { print }
' "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"
check "  fixture: the Core row appears twice" 2 "$(grep -cFx "$(core_row 0)" "$d/$DOC")"
check "  fixture: and the table grew by one"  "$((NTOOLS + 1))" "$(core_rows "$d")"
invoke "$d"
check "a duplicated docs row: FAILS" 1 "$RC"
contains "  and the count is named" "$OUT" "row count"
lacks    "  and the run does NOT claim sync" "$OUT" "All tool versions are in sync!"

# --- could not run ------------------------------------------------------------
# Exit 2, distinct from the 1 that means drift, and never 0. A checker that
# cannot find its input must not report a clean tree.
printf '\n== could not run is exit 2, never a pass ==\n'
d=$(mkfix noheader)
grep -v '^| Tool | Purpose | Current Version |$' "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"
check "  fixture: the header is gone" 0 "$(grep -c '^| Tool | Purpose | Current Version |$' "$d/$DOC")"
invoke "$d"
check "header row missing: exit 2" 2 "$RC"
contains "  and it says what it looked for" "$OUT" "could not find the Core Tools table"
lacks    "  and does NOT claim sync"        "$OUT" "All tool versions are in sync!"
lacks    "  and does NOT read as drift"     "$OUT" "OUT OF SYNC"

# A header that merely LOOKS right must not match: the whole point of anchoring
# on the full header is that a near-miss is reported rather than guessed at.
d=$(mkfix hdrtypo)
sed -i 's/^| Tool | Purpose | Current Version |$/| Tool | Purpose | Version |/' "$d/$DOC"
check "  fixture: the header was altered" 1 "$(grep -c '^| Tool | Purpose | Version |$' "$d/$DOC")"
invoke "$d"
check "a near-miss header: exit 2" 2 "$RC"

# Header present, every data row gone.
d=$(mkfix norows)
grep -v '^| .* | Purpose of ' "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"
check "  fixture: no data rows remain" 0 "$(grep -c '^| .* | Purpose of ' "$d/$DOC")"
invoke "$d"
check "header with no data rows: exit 2" 2 "$RC"
contains "  and says the table is empty" "$OUT" "no data rows"

# --- real drift is still detected --------------------------------------------
printf '\n== real drift still fails ==\n'
d=$(mkfix drift)
sed -i "s%^| ${TOOLS[0]} | Purpose of ${TOOLS[0]} | 1.0.0 |\$%| ${TOOLS[0]} | Purpose of ${TOOLS[0]} | 9.9.9 |%" "$d/$DOC"
check "  fixture: the version was changed" 1 "$(grep -c "^| ${TOOLS[0]} | Purpose of ${TOOLS[0]} | 9.9.9 |$" "$d/$DOC")"
invoke "$d"
check "a version disagreeing with .mise.toml: FAILS" 1 "$RC"
contains "  names the tool"        "$OUT" "${TOOLS[0]}"
contains "  and both versions"     "$OUT" "9.9.9 → 1.0.0"
lacks    "  and does NOT claim sync" "$OUT" "All tool versions are in sync!"

d=$(mkfix missingrow)
grep -v "^| ${TOOLS[1]} | Purpose of " "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"
check "  fixture: the row was removed" 0 "$(grep -c "^| ${TOOLS[1]} | Purpose of " "$d/$DOC")"
invoke "$d"
check "a tool with no docs row: FAILS" 1 "$RC"
contains "  and is named as missing" "$OUT" "${TOOLS[1]}: missing from docs"

# --- the other table in the same file ----------------------------------------
# The compatibility table repeats TOOLS[0] with version 7.7.7-COMPAT. If the
# slice ran past the blank line it would overwrite the real version with that
# one, and the run would fail naming it -- so a clean run here is evidence the
# slice stopped, not merely that nothing went wrong.
printf '\n== the second table in the same file is not read ==\n'
d=$(mkfix twotables); invoke "$d"
check "a later table does not leak into the slice" 0 "$RC"
lacks "  its version never appears" "$OUT" "7.7.7-COMPAT"
check "  fixture: that table really is there" 1 "$(grep -c '7.7.7-COMPAT' "$d/$DOC")"

# --- formatting tolerance ----------------------------------------------------
printf '\n== cell padding and trailing space ==\n'
d=$(mkfix padded)
sed -i "s%^| ${TOOLS[0]} | Purpose of ${TOOLS[0]} | 1.0.0 |\$%|   ${TOOLS[0]}   | Purpose of ${TOOLS[0]} |   1.0.0   |%" "$d/$DOC"
check "  fixture: the row was re-padded" 1 "$(grep -c "^|   ${TOOLS[0]}   |" "$d/$DOC")"
invoke "$d"
check "extra padding in cells: passes" 0 "$RC"

d=$(mkfix trailws)
sed -i "s%^\(| ${TOOLS[1]} | Purpose of ${TOOLS[1]} | 1.0.1 |\)\$%\1   %" "$d/$DOC"
check "  fixture: trailing spaces added" 1 "$(grep -c "| 1.0.1 |   $" "$d/$DOC")"
invoke "$d"
check "trailing whitespace on a row: passes" 0 "$RC"

# A separator row written with alignment colons is still a separator, not data.
d=$(mkfix aligned)
sed -i 's/^|------|---------|----------------|$/|:-----|:-------:|---------------:|/' "$d/$DOC"
check "  fixture: the separator uses colons" 1 "$(grep -c '^|:-----|' "$d/$DOC")"
invoke "$d"
check "an alignment-colon separator is not data" 0 "$RC"

# --- the write path ----------------------------------------------------------
# --update carried the SAME hardcoded 48,61. It is the remedy --check tells you
# to run, so a --check that now survives a shifted file while --update still
# corrupts one would be half a fix.
printf '\n== --update ==\n'
# --update carried the SAME hardcoded 48,61 as the read path. It is the remedy
# --check tells you to run, so a --check that survives a shifted file while
# --update still corrupts one would be half a fix.
#
# --update also NORMALISES the Purpose column out of TOOL_DESCRIPTIONS, so the
# fixture is legitimately not byte-stable across the FIRST run. Idempotency is
# asserted from the second run on -- which is where the bug lived: `echo -e` on
# a string that already ended in a newline appended one more blank line every
# single time. (Measured on a copy of the real tree before the fix: one --update
# on an otherwise unchanged repo produced a one-line diff, a new blank.)
d=$(mkfix upd_noop)
invoke "$d" --update
check "--update on a correct tree exits 0" 0 "$RC"
check "  and the table still has every row" "$NTOOLS" "$(core_rows "$d")"
cp "$d/$DOC" "$d/once.md"
invoke "$d" --update
if diff -q "$d/once.md" "$d/$DOC" >/dev/null; then ok "  a second --update changes nothing"; else bad "  a second --update changes nothing — file differs"; fi
invoke "$d" --update; invoke "$d" --update
if diff -q "$d/once.md" "$d/$DOC" >/dev/null; then ok "  and four runs still change nothing (no blank-line creep)"; else bad "  and four runs still change nothing (no blank-line creep) — file differs"; fi
invoke "$d"
check "  and --check passes on the result" 0 "$RC"

# On a shifted file the old rewrite ate the |---| separator row -- so the table
# stopped rendering as a table -- and left a duplicate last row below it.
d=$(mkfix upd_shift); shift_down "$d" 5
invoke "$d" --update
check "--update on a SHIFTED tree exits 0" 0 "$RC"
check "  keeps the |---| separator row" 1 "$(grep -c '^|------|---------|----------------|$' "$d/$DOC")"
check "  leaves the table exactly $NTOOLS rows" "$NTOOLS" "$(core_rows "$d")"
check "  with no duplicate last row" 1 "$(grep -c "^| ${TOOLS[$((NTOOLS - 1))]} |" "$d/$DOC")"
check "  and the shifted preamble intact" 1 "$(grep -c '^## Managed Tools$' "$d/$DOC")"
invoke "$d"
check "  and --check passes afterwards" 0 "$RC"

d=$(mkfix upd_fix)
sed -i "s%^| ${TOOLS[0]} | Purpose of ${TOOLS[0]} | 1.0.0 |\$%| ${TOOLS[0]} | Purpose of ${TOOLS[0]} | 9.9.9 |%" "$d/$DOC"
check "  fixture: the version was changed" 1 "$(grep -c '| 9.9.9 |$' "$d/$DOC")"
invoke "$d"; check "  fixture: --check sees the drift" 1 "$RC"
invoke "$d" --update
check "--update repairs a wrong version" 0 "$RC"
invoke "$d"
check "  and --check passes afterwards" 0 "$RC"
check "  content above the table survives" 1 "$(grep -c '^## Managed Tools$' "$d/$DOC")"
check "  content below the table survives" 1 "$(grep -c '^### Known Compatibility Issues$' "$d/$DOC")"
check "  and the second table is untouched" 1 "$(grep -c '7.7.7-COMPAT' "$d/$DOC")"

d=$(mkfix upd_noheader)
grep -v '^| Tool | Purpose | Current Version |$' "$d/$DOC" > "$d/.t" && mv "$d/.t" "$d/$DOC"
cp "$d/$DOC" "$d/before.md"
invoke "$d" --update
check "--update with no header: exit 2" 2 "$RC"
if diff -q "$d/before.md" "$d/$DOC" >/dev/null; then ok "  and does not touch the file"; else bad "  and does not touch the file — it was modified"; fi

# --- the tree we ship --------------------------------------------------------
printf '\n== the tree we ship ==\n'
OUT=$("$REPO/scripts/sync-version-docs.sh" 2>&1) && RC=0 || RC=$?
check "this repository passes its own check" 0 "$RC"
contains "  and says so" "$OUT" "All tool versions are in sync!"
check "the shipped doc still has the anchor header" 1 \
      "$(grep -c '^| Tool | Purpose | Current Version |$' "$REPO/docs/TOOL_VERSION_UPDATES.md")"

# The suite's own total, to catch a row that VANISHED rather than failed --
# several rows are emitted from `for` loops, and emptying one would remove them
# under a cheerful "all N checks passed". It does NOT catch a hollow row, which
# is what the fixture-applied assertions above are for.
EXPECTED_TOTAL=77

printf '\n'
if [ "$((pass + fail))" -ne "$EXPECTED_TOTAL" ]; then
    printf 'test-sync-version-docs: performed %d checks, expected %d — a row vanished\n' \
        "$((pass + fail))" "$EXPECTED_TOTAL"
    exit 1
fi
if [ "$fail" -gt 0 ]; then
    printf 'test-sync-version-docs: %d passed, %d FAILED\n' "$pass" "$fail"
    exit 1
fi
printf 'test-sync-version-docs: all %d checks passed\n' "$pass"
