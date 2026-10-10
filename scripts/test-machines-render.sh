#!/usr/bin/env bash
#
# scripts/test-machines-render
# ===============================
#
# State table for scripts/machines-render (DO-665, DO-811): the machine registry
# that `~/.config/claude-tenants.zsh` declares in CLAUDE_TENANT_MACHINE_ID and
# rabota consumes. Until DO-811 the registry was a PAIR of tables cross-checked
# against each other; the label half had no reader left after DO-810, so it went,
# and these rows pin the one table — including that a leftover label table is
# ignored rather than validated.
#
# Why this exists: the registry decides WHICH SEAT A REMOTE LANE BILLS, and a
# misread registry is silent — rabota just stops gating the seat. So every row
# below is really about one question — can a misconfiguration come back as "this
# machine owns nothing" instead of as an error? An empty registry and an
# unreadable one must never be the same answer. (The other reader of the same
# file, the launch check `claude-tenants-check`, refuses every launch on one it
# cannot read; until DO-810 it was the DO-632/DO-641 ownership guard, which read
# such a file as empty and stopped refusing.)
#
# HERMETIC: a fixture tenants file per case, no real ~/.config, no network.
# Requires: zsh, bash, jq.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REND="$DOTFILES/scripts/machines-render"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

for tool in zsh bash jq; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
[[ -x "$REND" ]] || fatal "$REND is not executable — every row below would assert nothing"

N=0
tf() {   # $@ = lines of a fixture tenants file -> its path
    N=$((N+1)); local f="$TMPROOT/t$N.zsh"
    printf '%s\n' "$@" > "$f"; printf '%s' "$f"
}
# OUT / ERR / RC as globals, never inside $( ): a command substitution is a
# subshell, so an exit code assigned there dies with it and a row about exit 2
# would silently measure the previous row's 0.
run() {  # $1 = tenants file (or '-' for none), $2... = args
    local t="$1"; shift
    OUT="$(CLAUDE_TENANTS_FILE="$t" "$REND" "$@" 2>"$TMPROOT/err")"; RC=$?
    ERR="$(cat "$TMPROOT/err")"
}

TENANTS_REAL_PROBE="$TMPROOT/plain-good.zsh"
printf '%s\n' 'CLAUDE_TENANT_MACHINE_ID=( a1 boxy )' > "$TENANTS_REAL_PROBE"

BOTH=( 'CLAUDE_TENANT_MACHINE_ID=( quantivly-0 dev  personal-1 nanoclaw )' )

echo "=== the happy path: one object, keyed by machine id ==="
f="$(tf "${BOTH[@]}")"
run "$f"
check "exit 0"                         "$RC" "0"
check "both machines are present"      "$(jq -r '. | keys | join(",")' <<<"$OUT")" "dev,nanoclaw"
check "dev's seat"                     "$(jq -r '.dev.profile' <<<"$OUT")" "quantivly-0"
check "...and nothing but the seat: no label since DO-811" "$(jq -c '.dev' <<<"$OUT")" '{"profile":"quantivly-0"}'
check "nanoclaw's seat"                "$(jq -r '.nanoclaw.profile' <<<"$OUT")" "personal-1"

echo
echo "=== an empty registry and an unreadable one are DIFFERENT answers ==="
# The whole suite is really this pair. A modular adopter genuinely owns no
# machine and must get {}; a file that exists and cannot be read is a fault, and
# answering {} for it would hand rabota "no machine has a seat" — the fail-open
# direction, which is what the tenants file's other reader already does silently.
run /nonexistent
check "no tenants file at all is an empty registry, exit 0" "$RC:$OUT" "0:{}"
f="$(tf "${BOTH[@]}")"; chmod 000 "$f"
run "$f"
check "a file that exists but cannot be READ is exit 2"     "$RC" "2"
check "...and prints no registry at all"                    "$OUT" ""
check "...naming the file"                                  "$(grep -c "$f" <<<"$ERR")" "1"
chmod 644 "$f"
f="$(tf 'CLAUDE_TENANT_MACHINE_ID=( )')"
run "$f"
check "a readable file declaring no machine is {} and exit 0" "$RC:$OUT" "0:{}"

echo
echo "=== the table against ITSELF, inside one file ==="
# Each of these is a way the canonical file can be wrong on its own. Without
# them the renderer would emit a seat under the machine key "", or let two seats
# claim one machine, and rabota would gate a lane on whichever won.
# Its OWN path, not tf's: tf runs inside `$( )`, so its counter never advances
# and every tf fixture is the same file, overwritten by the next. Reused below.
EMPTYID="$TMPROOT/emptyid.zsh"
printf '%s\n' 'CLAUDE_TENANT_MACHINE_ID=( quantivly-0 dev  personal-1 "" )' > "$EMPTYID"
run "$EMPTYID"
check "an entry naming NO machine is exit 1, not a key \"\""  "$RC" "1"
check "...naming the profile"                           "$(grep -c "personal-1" <<<"$ERR")" "1"
f="$(tf 'CLAUDE_TENANT_MACHINE_ID=( quantivly-0 dev  personal-1 dev )')"
run "$f"
check "two profiles claiming ONE machine is exit 1"     "$RC" "1"
check "...saying a machine bills one seat"              "$(grep -c 'bills one seat' <<<"$ERR")" "1"
# TWO EMPTY IDS are two faults of one kind, not ALSO a machine "" claimed twice:
# the empty-id branch skips the duplicate check, and without that a derived
# complaint is printed beside its own cause.
f="$(tf 'CLAUDE_TENANT_MACHINE_ID=( a1 ""  a2 "" )')"
run "$f"
check "...and two empty ids are not ALSO reported as a machine claimed twice" \
      "$(grep -c 'claimed by two profiles' <<<"$ERR")" "0"

echo
echo "=== the label table is gone, and a leftover one is IGNORED (DO-811) ==="
# Until DO-811 an id with no label was exit 1, and that is what made the label
# table impossible to delete: rabota failed at load, and every claude-tenants-edit
# write refused. A tenants file still carrying it by plain assignment is read
# past — it does not have to agree with anything.
f="$(tf 'CLAUDE_TENANT_MACHINE_OWNED=( other9 "somewhere else" )' \
        'CLAUDE_TENANT_MACHINE_ID=(    quantivly-0 dev  personal-1 nanoclaw )')"
run "$f"
check "an id the label table does not name renders, exit 0" "$RC" "0"
check "...with its seat"                                    "$(jq -r '.nanoclaw.profile' <<<"$OUT")" "personal-1"
# ...BUT BY SUBSCRIPT it is now an assignment to a table nobody declares, which
# aborts the source at that line — loud, as the undeclared-table row below
# requires. This is the mirror of the drift rows: the name left every list.
f="$(tf 'CLAUDE_TENANT_MACHINE_OWNED[quantivly-0]="dev (EC2)"' \
        'CLAUDE_TENANT_MACHINE_ID=( quantivly-0 dev )')"
run "$f"
check "a leftover label table assigned by SUBSCRIPT is exit 2" "$RC" "2"
check "...naming it, so the line to delete is obvious"         "$(grep -c 'CLAUDE_TENANT_MACHINE_OWNED' <<<"$ERR")" "1"

echo
echo "=== --check validates without rendering ==="
f="$(tf "${BOTH[@]}")"
run "$f" --check
check "--check on a good file is exit 0"            "$RC" "0"
check "...and prints NOTHING, so it is usable in a hook" "$OUT" ""
f="$EMPTYID"
run "$f" --check
check "--check on an inconsistent file is exit 1"   "$RC" "1"
run /nonexistent --check
check "--check with no tenants file is exit 0"      "$RC" "0"
run "$f" --nope
check "an unknown flag is exit 64, not a silent render" "$RC" "64"

echo
echo "=== a file that cannot be SOURCED must not read as an empty registry ==="
# THE HOLE A REVIEW FOUND, and the reason the section above is not enough. Every
# case here rendered `{}` with exit 0 before the fix, and --check passed all of
# them — so one unbalanced quote in the canonical file disabled rabota's seat
# gate while the OTHER reader of that same file (then the ownership guard,
# claude-profile-foreign) read it empty and stopped refusing, silently, which is
# the pair this change exists to prevent.
#
# The discriminator is `zsh -n`, NOT the fork's exit status and NOT a sentinel:
# a `source` that fails to parse returns to the forked shell, which then runs the
# loops over empty tables and prints any sentinel quite happily (measured). The
# status cannot serve either — it is the status of the file's LAST COMMAND, which
# is why a tenants file ending in a false command is legitimate.
f="$(tf 'CLAUDE_TENANT_MACHINE_ID=( a1 "oops')"
run "$f"
check "an unterminated quote is exit 2, not an empty registry" "$RC" "2"
check "...and prints no registry"                              "$OUT" ""
check "...naming the check that would show it"                 "$(grep -c 'zsh -n' <<<"$ERR")" "1"
run "$f" --check
check "...and --check refuses it too, since a hook is where this is caught" "$RC" "2"

# A DIRECTORY passes -e AND -r, and `source` fails on it. It rendered {} / exit 0.
run "$TMPROOT"
check "a path that is not a regular file is exit 2"  "$RC" "2"
check "...and prints no registry"                    "$OUT" ""
# The MESSAGE, not just the code: `zsh -n` fails on a directory too, so exit 2
# alone passes whichever guard caught it, and "does not parse" would send the
# reader looking for a syntax error in a directory.
check "...saying it is not a regular file, not that it fails to parse" \
      "$(grep -c 'is not a regular file' <<<"$ERR")" "1"

echo
echo "=== a file that RUNS but does not populate the tables is a fault too ==="
# THE CLASS, not three shapes. A second review found the first fix covered only
# PARSE errors: any command in the tenants file failing at RUN time left the
# tables empty, and `zsh -n` passes (it parses), the source's status is the
# file's last command (so it is ignored), and the sentinel still prints. The
# discriminator is the fork's STDERR, which the fork had been discarding — it
# does nothing but declare, source and print, so every byte on it came from the
# tenants file.
#
# Each row below rendered `{}` with exit 0 before that guard, and --check passed
# all of them.
printf 'CLAUDE_TENANT_POOL=( w "a1" )\r\nCLAUDE_TENANT_MACHINE_ID=( a1 boxy )\r\n' \
    > "$TMPROOT/crlf.zsh"
run "$TMPROOT/crlf.zsh"
check "CRLF line endings are exit 2, not an empty registry" "$RC" "2"
check "...and print no registry"                            "$OUT" ""
check "...naming CRLF, since no editor shows it"            "$(grep -c 'CRLF' <<<"$ERR")" "1"
# THE INDENT, which was not happening: `print -u2 -- "$x" | sed 's/^/    /'`
# pipes fd 1 — an empty stdin — so sed indented nothing and the tenants file's
# own complaint ran flush against the message, reading as a second message
# rather than as this one's evidence. Found writing the same line for
# the launch-time reader (DO-674). No other row here reads the shape of the
# output, only its words, so without this the fix is deletable. Counted as
# "no line escaped the indent" rather than "N lines got it": the fixture is
# two CRLF lines, so an exact count would be a row about its length.
check "...with the file's own complaint indented under it, not flush left" \
      "$(grep -cE '^[^ ].*command not found' <<<"$ERR")" "0"

printf '\xef\xbb\xbfCLAUDE_TENANT_MACHINE_ID=( a1 boxy )\n' > "$TMPROOT/bom.zsh"
run "$TMPROOT/bom.zsh"
check "a UTF-8 BOM is exit 2"                               "$RC" "2"

# THE ORIGINAL DEFECT, for any table added after today. The fork pre-declares a
# fixed list of CLAUDE_TENANT_* names; a subscript assignment to a name outside
# it aborts the source at that line. The list is a convenience that avoids
# refusing a file that is fine — this row pins that a missing name is LOUD.
f="$(tf 'CLAUDE_TENANT_FUTURE[work]="x"' \
        'CLAUDE_TENANT_MACHINE_ID=( a1 boxy )')"
run "$f"
check "a subscript assignment to an UNDECLARED table is exit 2" "$RC" "2"
check "...carrying zsh's own complaint, which names the table"  "$(grep -c 'CLAUDE_TENANT_FUTURE' <<<"$ERR")" "1"

# ...AND THE TWO FILES THAT MUST STILL RENDER. Without these the guard above
# passes just as well for a renderer that refuses everything.
# shellcheck disable=SC2016  # fixture text written INTO a zsh file, not an
# expression for this shell to expand.
f="$(tf 'CLAUDE_TENANT_MACHINE_ID=( a1 boxy )' \
        '[[ -n "${NOPE:-}" ]]')"
run "$f"
check "a file ending in a false command still renders"      "$(jq -r '.boxy.profile' <<<"$OUT")" "a1"
run "$TENANTS_REAL_PROBE"
check "...and a plain good file renders"                    "$RC" "0"

echo
echo "=== the sentinel: the read being CUT SHORT, which no other guard sees ==="
# Without a fixture this guard was four surviving mutants — it could be deleted,
# neutered or reworded with the suite green, because every other input the suite
# offers is intercepted by -f, -r, zsh -n or the stderr check first. A tenants
# file that kills its own shell produces no stderr and no __DONE__, which is
# precisely the state it exists for: measured, with the sentinel disabled this
# same fixture renders `{}` and exits 0.
printf 'kill -9 $$\nCLAUDE_TENANT_MACHINE_ID=( a1 boxy )\n' > "$TMPROOT/killed.zsh"
run "$TMPROOT/killed.zsh"
check "a fork that is killed mid-read is exit 2, not an empty registry" "$RC" "2"
check "...and prints no registry"                                      "$OUT" ""
check "...saying the read did not finish, not that the file is wrong"  "$(grep -c 'did not finish' <<<"$ERR")" "1"

echo
echo "=== a machine id is an identifier: 'a tab OR A NEWLINE' is refused ==="
# The comment and the message both promise newlines as well as tabs; when only a
# tab had a fixture, three mutants lived in the gap between promise and rows.
# A tab or a newline would re-split downstream and truncate the id, or
# synthesise a marker line and invent a machine.
printf 'CLAUDE_TENANT_MACHINE_ID=( a1 "line1\nline2" )\n' > "$TMPROOT/nl.zsh"
run "$TMPROOT/nl.zsh"
check "a NEWLINE in a machine id is refused, like a tab"   "$RC" "1"
check "...naming it as the cause"                     "$(grep -c 'contains a tab or a newline' <<<"$ERR")" "1"

printf 'CLAUDE_TENANT_MACHINE_ID=( a1 "boxy\tX" )\n' > "$TMPROOT/idtab.zsh"
run "$TMPROOT/idtab.zsh"
check "a TAB in a machine id is refused"              "$RC" "1"

echo
echo "=== the refusals name the file they are about ==="
# Three messages carried "$TENANTS" that no row read, so the path could be
# dropped from all of them — and a refusal that does not say WHICH tenants file
# is the one thing an operator with a worktree and a deployed checkout cannot act on.
f="$EMPTYID"
run "$f"
check "the consistency refusal names the tenants file"  "$(grep -c "$f" <<<"$ERR")" "1"
run "$TMPROOT/nl.zsh"
check "the unusable-value refusal names it too"         "$(grep -c "$TMPROOT/nl.zsh" <<<"$ERR")" "1"

echo
echo "=== argument handling ==="
run "$TENANTS_REAL_PROBE" --check extra
check "two arguments is exit 64, not a silent render"   "$RC" "64"
check "...and says how to call it"                      "$(grep -c '^usage: machines-render' <<<"$ERR")" "1"

echo
echo "=== a dangling symlink is not 'no tenants file' ==="
# `-e` FOLLOWS the link, so a broken one answered the modular adopter's question
# instead of its own — and a broken link is what a mid-deploy checkout or a
# removed worktree leaves behind: a state that arrives by accident and reads as
# a deliberate choice.
ln -sfn /nonexistent/nope "$TMPROOT/dangling.zsh"
run "$TMPROOT/dangling.zsh"
check "a dangling symlink is exit 2, not an empty registry"  "$RC" "2"
check "...saying the target is missing"                      "$(grep -c 'target does not exist' <<<"$ERR")" "1"

echo
echo "=== a tab or newline in a profile NAME, not only in a machine id ==="
# The value check was there and the key check was not, so a tab in a profile
# name did the exact thing the value check exists to prevent — split the record
# and invent a machine — with exit 0.
printf 'CLAUDE_TENANT_MACHINE_ID=( "a1\tX" boxy )\n' > "$TMPROOT/tabkey.zsh"
run "$TMPROOT/tabkey.zsh"
check "a TAB in a profile name is refused"                   "$RC" "1"
check "...naming the profile name as the fault, not the machine id" \
      "$(grep -c 'a profile name in' <<<"$ERR")" "1"
check "...and not reporting it as a machine-id fault as well" \
      "$(grep -c 'the machine id for' <<<"$ERR")" "0"

echo
echo "=== the pre-declaration list must not drift from zshrc.herdr's ==="
# THE THIRD COPY. This change's own thesis is that a fact written down twice with
# no cross-check is the defect, and the fork's table list is a third literal copy
# of zsh/zshrc.herdr's two. Drift fails OPEN: the day a ninth CLAUDE_TENANT_*
# table exists and a tenants file assigns it by subscript, the row above is what
# catches it — but only because this row keeps the lists identical.
# Names are taken from the `typeset -g[aA]` DECLARATION LINES of each file, not
# from every CLAUDE_TENANT_* token in them: the loose form sweeps up flags like
# _CLAUDE_TENANT_WARNED_UNSUPPORTED and the row then fails for a reason that has
# nothing to do with drift.
decl_names() {  # $1 = file -> the declared CLAUDE_TENANT_* names, one per line, sorted
    # Backslash continuations are JOINED first: the renderer's -gA declaration
    # wraps, so a line-based match saw three of its five names and the row failed
    # for a formatting difference rather than for drift.
    sed -e :a -e '/\\$/N; s/\\\n//; ta' "$1" \
      | grep -hE '^[[:space:]]*typeset -g[aA] ' \
      | grep -oE 'CLAUDE_TENANT_[A-Z_]+' | sort -u
}
missing="$(comm -23 <(decl_names "$DOTFILES/zsh/zshrc.herdr") <(decl_names "$REND") | tr '\n' ',')"
check "every table zshrc.herdr declares is pre-declared by the fork" "$missing" ""
# ...and the fork declares nothing zshrc.herdr does not, or the "same list" claim
# is only half true and the next reader trusts it in the wrong direction.
extra="$(comm -13 <(decl_names "$DOTFILES/zsh/zshrc.herdr") <(decl_names "$REND") | tr '\n' ',')"
check "...and the fork declares no table zshrc.herdr does not" "$extra" ""
# THE OTHER THREE COPIES (DO-811). The list is written out six times — twice in
# zshrc.herdr, once here, and in the doctor, tenant-route and claude-tenants-edit
# — and until DO-811 only these first two were compared. Removing
# CLAUDE_TENANT_MACHINE_OWNED meant editing all six by hand; one missed copy
# accepts a subscript assignment the others refuse, and the readers disagree.
for copy in zsh/functions/claude.sh scripts/tenant-route scripts/claude-tenants-edit; do
    drift="$(comm -3 <(decl_names "$DOTFILES/zsh/zshrc.herdr") <(decl_names "$DOTFILES/$copy") | tr -d '\t' | tr '\n' ',')"
    check "$copy declares exactly zshrc.herdr's tables" "$drift" ""
done

echo
echo "=== the fork must tolerate every OTHER table a tenants file declares ==="
# A real tenants file assigns CLAUDE_TENANT_POOL and friends. The subscript form
# is valid everywhere else because zsh/zshrc.herdr declares those names -gA before
# sourcing; a fork that declared only the machine tables raised "assignment to
# invalid subscript range", aborted the source at THAT LINE, and returned an empty
# registry from a file that is correct.
f="$(tf 'CLAUDE_TENANT_POOL[work]="quantivly-1 quantivly-2"' \
        'CLAUDE_TENANT_MACHINE_ID=( quantivly-0 dev )')"
run "$f"
check "a subscript assignment to ANOTHER table does not abort the read" \
      "$(jq -r '.dev.profile' <<<"$OUT")" "quantivly-0"
f="$(tf 'CLAUDE_TENANT_SPILL[work]="personal-0"' \
        'CLAUDE_TENANT_MACHINE_ID=( quantivly-0 dev )')"
run "$f"
check "...nor does one to the spill table (DO-800)" \
      "$(jq -r '.dev.profile' <<<"$OUT")" "quantivly-0"

echo
echo "=== declaring no machine ids is 'not adopted', not drift ==="
# A tenants file with pools and no machine ids is every pre-DO-665 file, and a
# modular adopter's. Refusing it would make EVERY rabota command exit 2 —
# including `rabota doctor`, the tool you would reach for to find out why — so
# the honest answer is an empty registry, and rabota then refuses a remote lane
# by name.
f="$(tf 'CLAUDE_TENANT_POOL=( w "a1" )')"
run "$f"
check "a file with pools and no machine ids is an empty registry, exit 0" "$RC:$OUT" "0:{}"
run "$f" --check
check "...and --check is content with it"                      "$RC" "0"

echo
echo "=== what the FORK can and cannot see, which constrains the tenants file ==="
# Every row here is a spelling a real tenants file uses, or a shape that made
# the launch-time reader answer wrongly in 2026-09-20. The fork exists so all of
# them behave alike; a renderer that sourced the file in-process would differ on each.
f="$(tf 'typeset -A CLAUDE_TENANT_MACHINE_ID' \
        'CLAUDE_TENANT_MACHINE_ID=( quantivly-0 dev )')"
run "$f"
check "a 'typeset -A' spelling renders (a function-local would read empty)" \
      "$(jq -r '.dev.profile' <<<"$OUT")" "quantivly-0"
f="$(tf "${BOTH[@]}" 'print -r -- "a stray line"')"
run "$f"
check "a stray print in the tenants file does not become data" \
      "$(jq -r '. | keys | join(",")' <<<"$OUT")" "dev,nanoclaw"
# shellcheck disable=SC2016  # the single quotes are the point: this is fixture
# text written INTO a zsh file, not an expression for this shell to expand.
f="$(tf "${BOTH[@]}" '[[ -n "${NOPE:-}" ]]')"
run "$f"
check "a file ending in a FALSE command still renders" "$RC" "0"
check "...with both machines"                          "$(jq -r '. | keys | length' <<<"$OUT")" "2"

echo
echo "=== a name is DATA, not JSON source ==="
# jq builds from typed pieces precisely so this cannot be a syntax error. One
# quote in a name is the difference between a document and a crash, and a
# renderer built with printf passes every row above and fails this one.
f="$(tf 'CLAUDE_TENANT_MACHINE_ID=( "a\"1" "box'"'"'y" )')"
run "$f"
check "a profile and a machine id with quotes in them survive intact" \
      "$(jq -r '.["box'"'"'y"].profile' <<<"$OUT")" 'a"1'
check "...and the document is still valid JSON" "$(jq -e . <<<"$OUT" >/dev/null && echo valid)" "valid"

# --- the row total -----------------------------------------------------------
# Catches a row that VANISHED -- an early exit, a deleted block, an emptied
# loop, an unset variable under `set -u`. Every row that still ran would pass
# and this suite would print a green summary over half its coverage. The full
# argument is at the tail of scripts/test-secret-guard.sh; which page owns a
# count is docs/REPO_CHECKS.md, "Where a check count lives".
#
# There is deliberately NO docs_claim row here. Both numbers written about this
# suite are deltas inside dated entries in docs/CLAUDE_ACCOUNT_PICKER.md --
# "(65, new CI job `machines-render-test`)" and "(65 -> 66)" -- which is to say
# they are RECORDS of what a change did, true where they stand, not claims about
# today. Asserting one would force a historical entry to be rewritten every time
# a row lands. scripts/test-claude-pick.sh is the same case, argued there first.
EXPECTED_ROWS=70

if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '  \033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
