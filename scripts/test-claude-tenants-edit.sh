#!/usr/bin/env bash
#
# scripts/test-claude-tenants-edit.sh
# ===================================
#
# State table for scripts/claude-tenants-edit (DO-795), the one sanctioned way to
# change the account pools in the tenants file.
#
# Why this exists: the tenants file decides which account every launch bills, and
# its two failure directions are both silent. A parse error above the pool lines
# EMPTIES the pool, and the ranked pick widens to every profile. A run-time error
# makes every launch refuse. So every row asks one of three questions:
#
#   - does the edit do exactly the requested change, and nothing else?
#   - when a request should be refused, is the file left byte-for-byte alone?
#   - can a file the editor cannot handle safely ever come back as "done"?
#
# HERMETIC: a fixture HOME per row. The tenants path is a SYMLINK into a fixture
# git repo, as it is on the real machine, so the rows that care can see that the
# link survives and the commit touches only that file. No real ~/.config, ~/.clauth
# or network. Synthetic tenant and profile names only: this repo is public.
#
# Requires: zsh, bash, git, diff.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="${CLAUDE_TENANTS_EDIT:-$DOTFILES/scripts/claude-tenants-edit}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
want_err() { if [[ "$ERR" == *"$2"* ]]; then ok "$1"; else bad "$1 — expected stderr to contain '$2'; got: ${ERR:0:300}"; fi; }
want_out() { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1 — expected stdout to contain '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

for tool in zsh bash git diff; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
[[ -r "$SUT" ]] || fatal "cannot read $SUT — every row below would assert nothing"

# The baseline tenants file. `work` is named by a route and `home` by the default,
# so both are REFERENCED; `w` is referenced by nothing, and its name is a prefix of
# `work`, which is what the row about editing the right line needs.
BASE='# fixture tenants file
typeset -ga CLAUDE_TENANT_ROUTES CLAUDE_TENANT_PATH_ROUTES CLAUDE_TENANT_BUCKETS
typeset -gA CLAUDE_TENANT_POOL CLAUDE_TENANT_OVERFLOW CLAUDE_TENANT_GH_DIR CLAUDE_TENANT_MACHINE_ID

CLAUDE_TENANT_ROUTES=(
  "orgw=work"
)
CLAUDE_TENANT_DEFAULT=home

CLAUDE_TENANT_POOL=(
  work "w1 w2"
  home "h1"
  w    "w1"
)

CLAUDE_TENANT_OVERFLOW=()

CLAUDE_TENANT_MACHINE_ID=(
  owned1 box
)
CLAUDE_TENANT_BUCKETS=()'

# A fresh fixture HOME. $1 = name, $2 = tenants file content (default BASE).
# The tenants file lives in $FHOME/repo (a git repo, one commit), and
# ~/.config/claude-tenants.zsh is a symlink to it.
new_home() {
    FHOME="$TMPROOT/home.$1"; rm -rf "$FHOME"
    mkdir -p "$FHOME/.config" "$FHOME/repo/claude" "$FHOME/.clauth/profiles" \
             "$FHOME/.local/state/claude-account-dirs"
    REAL="$FHOME/repo/claude/tenants.zsh"
    printf '%s\n' "${2-$BASE}" > "$REAL"
    ln -s "$REAL" "$FHOME/.config/claude-tenants.zsh"
    local p
    for p in w1 w2 w3 h1 h2 owned1 old9; do
        mkdir -p "$FHOME/.clauth/profiles/$p"
        printf '{}\n' > "$FHOME/.clauth/profiles/$p/credentials.json"
    done
    printf '[user]\n  name = fixture\n  email = fixture@example.invalid\n[commit]\n  gpgsign = false\n[init]\n  defaultBranch = main\n' \
        > "$FHOME/.gitconfig"
    gitf -C "$FHOME/repo" init -q
    printf 'other\n' > "$FHOME/repo/other.txt"
    gitf -C "$FHOME/repo" add -A && gitf -C "$FHOME/repo" commit -q -m init
    BEFORE="$(cat "$REAL")"
}
gitf() { GIT_CONFIG_GLOBAL="$FHOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 git "$@"; }

# OUT / ERR / RC as globals, never inside $( ): an exit code assigned in a
# command substitution dies with the subshell.
run() {
    OUT="$(umask "${RUN_UMASK:-022}"; env -u CLAUDE_TENANTS_FILE -u CLAUDE_ACCOUNT_DIRS_ROOT -u XDG_STATE_HOME \
               HOME="$FHOME" GIT_CONFIG_GLOBAL="$FHOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
               zsh "$SUT" "$@" 2>"$TMPROOT/err")"; RC=$?
    ERR="$(cat "$TMPROOT/err")"
}
run_at() {   # $1 = path of a SUT copy, rest = args
    local sut="$1"; shift
    OUT="$(env -u CLAUDE_TENANTS_FILE -u CLAUDE_ACCOUNT_DIRS_ROOT -u XDG_STATE_HOME \
               HOME="$FHOME" GIT_CONFIG_GLOBAL="$FHOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
               zsh "$sut" "$@" 2>"$TMPROOT/err")"; RC=$?
    ERR="$(cat "$TMPROOT/err")"
}
unchanged() { check "$1" "$(cat "$REAL" 2>/dev/null)" "$BEFORE"; }
# The pool value a launch would read, from a bare zsh with the table declared.
pool_of() {
    zsh -f -c 'typeset -gA CLAUDE_TENANT_POOL; source "$1" >/dev/null 2>&1; print -r -- "${CLAUDE_TENANT_POOL[$2]-<none>}"' _ "$REAL" "$1"
}
retired_of() {
    zsh -f -c 'typeset -gA CLAUDE_TENANT_RETIRED; source "$1" >/dev/null 2>&1; print -r -- "${CLAUDE_TENANT_RETIRED[$2]-<none>}"' _ "$REAL" "$1"
}
changed_lines() { diff <(printf '%s\n' "$BEFORE") "$REAL" | grep -c '^[<>]' || true; }
backups() { find "$FHOME/.local/state/claude-tenants-edit" -maxdepth 1 -name 'tenants.zsh.*' 2>/dev/null | wc -l | tr -d ' '; }

echo "=== claude-tenants-edit state table ==="

#-----------------------------------------------------------------------------
section "A. Usage"
#-----------------------------------------------------------------------------
new_home a
run;                               check "no arguments is a usage error"            "$RC" "64"
run frobnicate work w3;            check "an unknown operation is a usage error"    "$RC" "64"
run pool-add work;                 check "a missing argument is a usage error"      "$RC" "64"
run --force pool-add work w3;      check "an unknown option is a usage error"       "$RC" "64"
# A flag after the operation used to be read as an argument: `retire-name old9
# --dry-run` wrote "--dry-run" as the reason, for real (review, 2026-10-05).
run retire-name old9 --dry-run;    check "a flag after the operation is a usage error" "$RC" "64"
unchanged "...and nothing is written"
run pool-add work --dry-run;       check "...in any position"                       "$RC" "64"

#-----------------------------------------------------------------------------
section "B. Names and reasons the table cannot hold"
#-----------------------------------------------------------------------------
new_home b1
run pool-add work 'zvi+w'
check "a member with a character the picker rejects is refused" "$RC" "1"
want_err "...for its characters, not for some later reason" "may only contain letters"
unchanged "...and the file is untouched"
new_home b2
run retire-name old9 'renamed "badly"'
check "a reason with a double quote is refused"  "$RC" "1"
run retire-name old9 ''
check "an empty reason is refused"               "$RC" "1"
run retire-name old9 $'renamed\rX'
check "a reason with a carriage return is refused" "$RC" "1"
unchanged "...and the file is untouched"

#-----------------------------------------------------------------------------
section "C. A file that cannot be edited safely is never 'done'"
#-----------------------------------------------------------------------------
new_home c1; rm -f "$FHOME/.config/claude-tenants.zsh"
run pool-add work w3
check "no tenants file is exit 2" "$RC" "2"

new_home c2; rm -f "$REAL"
run pool-add work w3
check "a dangling symlink is exit 2" "$RC" "2"
want_err "...and says so" "symlink whose target does not exist"

new_home c3; rm -f "$REAL"; mkdir "$REAL"
run pool-add work w3
check "a directory is exit 2" "$RC" "2"
want_err "...and says it is not a regular file" "not a regular file"

new_home c4 "$BASE
CLAUDE_TENANT_POOL=( broken \"x"
run pool-add work w3
check "a file that does not parse is exit 2" "$RC" "2"
want_err "...and says it does not parse" "does not parse"
unchanged "...and is left alone"

new_home c5; printf '%s\r\n' 'typeset -gA CLAUDE_TENANT_POOL' 'CLAUDE_TENANT_POOL=( work "w1" )' > "$REAL"; BEFORE="$(cat "$REAL")"
run pool-add work w3
check "a file that errors at RUN time (CRLF) is exit 2" "$RC" "2"
want_err "...named as not running cleanly" "did not run cleanly"
unchanged "...and is left alone"

# Every table a tenants file may assign is pre-declared, so a subscript
# assignment to one, ahead of the pools, is not a fault.
new_home c6 "$(printf '%s\n' "$BASE" | sed 's/^CLAUDE_TENANT_DEFAULT=home$/CLAUDE_TENANT_GH_DIR[work]="x"\nCLAUDE_TENANT_DEFAULT=home/')"
run pool-add work w3
check "a subscript assignment to a sibling table is not a fault" "$RC" "0"

#-----------------------------------------------------------------------------
section "D. pool-add"
#-----------------------------------------------------------------------------
# 604 under a 077 umask: `cp` without -p already copies the mode, minus what the
# umask removes, so under a permissive umask a copy that dropped -p kept the mode
# anyway and this row could not tell the two apart. Under 077 it comes out 600.
new_home d1; chmod 604 "$REAL"
RUN_UMASK=077 run pool-add work w3
check "adding a member succeeds"                  "$RC" "0"
check "...and the pool a launch reads gains it"   "$(pool_of work)" "w1 w2 w3"
check "...by changing exactly one line"           "$(changed_lines)" "2"
check "...the tenants path is still a symlink"    "$([[ -L "$FHOME/.config/claude-tenants.zsh" ]] && echo yes)" "yes"
check "...the file keeps its mode"                "$(stat -c %a "$REAL")" "604"
check "...and a backup of the old file is kept"   "$(backups)" "1"

# Two edits in one second shared a backup name, and the second's backup replaced
# the first's: the original file was in no backup at all (review, 2026-10-05).
# The same edit twice in a second is the case only the pid tells apart.
new_home d1b; run pool-add work w3; run pool-remove work w3; run pool-add work w3
check "three quick edits keep three backups" "$(backups)" "3"
check "...one of which is the original"  "$(for b in "$FHOME"/.local/state/claude-tenants-edit/tenants.zsh.*; do [[ "$(cat "$b")" == "$BEFORE" ]] && echo yes; done | head -1)" "yes"

new_home d2; run pool-add nosuch w3
check "an unknown tenant is refused" "$RC" "1"; unchanged "...and the file is untouched"
want_err "...as an unknown tenant, not by a later accident" "has no CLAUDE_TENANT_POOL entry"
new_home d3; run pool-add work w2
check "a member already in the pool is refused" "$RC" "1"
new_home d4; run pool-add work nostore
check "a name with no clauth profile store is refused" "$RC" "1"
# A seat another machine bills is no longer refused (DO-810): two logins to one
# seat are independent. Whether it SHOULD be a pool member is the tenants file's
# call — such a seat is meant to be a spill seat — not this tool's.
new_home d5; run pool-add work owned1
check "a name another machine bills is accepted (DO-810)" "$RC" "0"
check "...and the pool a launch reads gains it" "$(pool_of work)" "w1 w2 owned1"
new_home d6 "$BASE
typeset -gA CLAUDE_TENANT_RETIRED
CLAUDE_TENANT_RETIRED=(
  old9 \"renamed away\"
)"
run pool-add work old9
check "a retired name is refused" "$RC" "1"; unchanged "...and the file is untouched"
new_home d7; ln -s w1 "$FHOME/.local/state/claude-account-dirs/w3"
run pool-add work w3
check "a name whose account dir is a compat symlink is refused" "$RC" "1"

# `w` is a prefix of `work`: the edit must land on `w`'s line only.
new_home d8; run pool-add w w2
check "editing tenant 'w' changes 'w'"              "$(pool_of w)" "w1 w2"
check "...and leaves 'work' alone"                  "$(pool_of work)" "w1 w2"

new_home d9 "$(printf '%s\n' "$BASE" | sed 's/^  home "h1"$/  home "h1"\n  work "w1"/')"
run pool-add work w3
check "two lines for one tenant is a layout to edit by hand" "$RC" "2"
want_err "...and says so" "edit it by hand"
unchanged "...and the file is untouched"

new_home d10 "$(printf '%s\n' "$BASE" | sed "s/^  work \"w1 w2\"\$/  work 'w1 w2'/")"
run pool-add work w3
check "a single-quoted member list is a layout to edit by hand" "$RC" "2"

new_home d11 'typeset -gA CLAUDE_TENANT_POOL
CLAUDE_TENANT_POOL[work]="w1 w2"'
run pool-add work w3
check "the subscript form, with no pool block, is a layout to edit by hand" "$RC" "2"
want_err "...because there is no pool block" "found no 'CLAUDE_TENANT_POOL=('"

new_home d12; printf '\n\n' >> "$REAL"; BEFORE="$(cat "$REAL"; printf x)"; BEFORE="${BEFORE%x}"
run pool-add work w3
AFTER="$(cat "$REAL"; printf x)"; AFTER="${AFTER%x}"
check "trailing blank lines survive the edit" "${AFTER: -4}" $')\n\n\n'
check "...and the edit still landed"          "$(pool_of work)" "w1 w2 w3"

#-----------------------------------------------------------------------------
section "E. pool-remove"
#-----------------------------------------------------------------------------
new_home e1; run pool-remove work w2
check "removing a member succeeds"                "$RC" "0"
check "...and the pool a launch reads loses it"   "$(pool_of work)" "w1"
new_home e2; run pool-remove work w3
check "removing a member that is not there is refused" "$RC" "1"
new_home e3; run pool-remove home h1
check "emptying a pool the default names is refused" "$RC" "1"
want_err "...because every launch would refuse"      "every launch would refuse"
unchanged "...and the file is untouched"
new_home e3b "$(printf '%s\n' "$BASE" | sed 's/^  work "w1 w2"$/  work "w1"/')"
run pool-remove work w1
check "emptying a pool a route names is refused" "$RC" "1"
want_err "...as one every launch depends on"     "every launch would refuse"
# An unreferenced pool emptied is refused too: a launch PINNED to that tenant had
# no pool to use. It widened to every profile until DO-804, and is refused since
# (review, 2026-10-05). This row used to assert the edit.
new_home e4; run pool-remove w w1
check "emptying a pool nothing names is refused too" "$RC" "1"
want_err "...because a pinned launch would be refused" "a launch pinned to 'w' would be refused"
unchanged "...and the file is untouched"

#-----------------------------------------------------------------------------
section "F. retire-name"
#-----------------------------------------------------------------------------
new_home f1; run retire-name old9 'renamed to w1'
check "retiring a name with no table yet succeeds"  "$RC" "0"
check "...and a launch's reader sees it"            "$(retired_of old9)" "renamed to w1"
check "...the file still parses"                    "$(zsh -n "$REAL" && echo ok)" "ok"
check "...and machines-render still accepts it"     "$(CLAUDE_TENANTS_FILE="$REAL" zsh "$DOTFILES/scripts/machines-render" --check >/dev/null 2>&1 && echo ok)" "ok"
check "...and the pools are untouched"              "$(pool_of work)" "w1 w2"

new_home f2 "$BASE
typeset -gA CLAUDE_TENANT_RETIRED
CLAUDE_TENANT_RETIRED=(
  old8 \"earlier\"
)"
run retire-name old9 'later'
check "retiring into an existing table succeeds" "$RC" "0"
check "...adding the new name"                    "$(retired_of old9)" "later"
check "...and keeping the old one"                "$(retired_of old8)" "earlier"
run retire-name old9 'again'
check "retiring a name twice is refused" "$RC" "1"

new_home f3; run retire-name w2 'gone'
check "retiring a name still in a pool is refused" "$RC" "1"
want_err "...naming where it still is"             "pool work"
new_home f4 "$(printf '%s\n' "$BASE" | sed 's/^CLAUDE_TENANT_OVERFLOW=()$/CLAUDE_TENANT_OVERFLOW=( work "h2" )/')"
run retire-name h2 'gone'
check "retiring a name still in an overflow is refused" "$RC" "1"

#-----------------------------------------------------------------------------
section "G. --dry-run"
#-----------------------------------------------------------------------------
new_home g1; run --dry-run pool-add work w3
check "a dry run passes"                 "$RC" "0"
want_out "...prints the change"          '+  work "w1 w2 w3"'
unchanged "...writes nothing"
check "...and keeps no backup"           "$(backups)" "0"

#-----------------------------------------------------------------------------
section "H. --commit"
#-----------------------------------------------------------------------------
new_home h1; printf 'hand edit\n' >> "$FHOME/repo/other.txt"
run --commit pool-add work w3
check "a committed edit succeeds"                   "$RC" "0"
check "...the commit names the change"              "$(gitf -C "$FHOME/repo" log -1 --format=%s)" "tenants: pool-add work w3"
check "...the tenants file is clean afterwards"     "$(gitf -C "$FHOME/repo" status --porcelain -- claude/tenants.zsh)" ""
check "...and an unrelated dirty file is NOT swept in" "$(gitf -C "$FHOME/repo" status --porcelain -- other.txt)" " M other.txt"

new_home h2; printf '# a hand edit\n' >> "$REAL"; BEFORE="$(cat "$REAL")"
run --commit pool-add work w3
check "--commit over an already-dirty tenants file is refused" "$RC" "2"
unchanged "...the hand edit is left as it was"
check "...and nothing was committed"  "$(gitf -C "$FHOME/repo" rev-list --count HEAD)" "1"

new_home h3; rm -rf "$FHOME/repo/.git"
run --commit pool-add work w3
check "--commit outside a git work tree is refused" "$RC" "2"
want_err "...for that reason, not a later check" "inside a git work tree"
unchanged "...and the file is untouched"

new_home h5; mkdir -p "$FHOME/repo/.git/hooks"
printf '#!/bin/sh\nexit 1\n' > "$FHOME/repo/.git/hooks/pre-commit"; chmod +x "$FHOME/repo/.git/hooks/pre-commit"
run --commit pool-add work w3
check "a commit a hook rejects is exit 2"            "$RC" "2"
unchanged "...and the edit is rolled back"
check "...and nothing is left staged"                "$(gitf -C "$FHOME/repo" status --porcelain -- claude/tenants.zsh)" ""
want_err "...and it says so"                         "rolled back"

new_home h6; gitf -C "$FHOME/repo" rm -q --cached claude/tenants.zsh; gitf -C "$FHOME/repo" commit -q -m untrack
run --commit pool-add work w3
check "--commit on an untracked file is refused" "$RC" "2"
want_err "...as untracked, before anything is written" "untracked or ignored"
unchanged "...and the file is untouched"
run pool-add work w3
want_out "without --commit it says the file is not tracked" "not tracked"

new_home h7; : > "$FHOME/repo/.git/index.lock"
run --commit pool-add work w3
check "--commit while git holds index.lock is refused" "$RC" "2"
want_err "...naming the lock, before git does"         "has an index.lock; another git command is running there"
unchanged "...and the file is untouched"

new_home h4; run pool-add work w3
check "without --commit, nothing is committed" "$(gitf -C "$FHOME/repo" rev-list --count HEAD)" "1"
want_out "...and it says how to commit"         "not committed"

#-----------------------------------------------------------------------------
section "I. The checks on the edited copy"
#-----------------------------------------------------------------------------
# machines-render rejects one machine claimed by two profiles. The edit itself
# is fine; the copy fails the check, so nothing is written.
new_home i1 "$(printf '%s\n' "$BASE" | sed 's/^  owned1 box$/  owned1 box\n  w2 box/')"
run pool-add work w3
check "a copy machines-render rejects is not written" "$RC" "2"
want_err "...naming machines-render"                  "machines-render"
unchanged "...and the file is untouched"

# A later subscript assignment overrides the pool line, so the text edit cannot
# reach the value a launch reads. The semantic comparison must catch it.
new_home i2 "$BASE
CLAUDE_TENANT_POOL[work]=\"w1 w2\""
run pool-add work w3
check "an edit that does not change what a launch reads is not written" "$RC" "2"
want_err "...and says the table differs"                                "differs from the table"
unchanged "...and the file is untouched"

new_home i3; mkdir -p "$TMPROOT/lone"; cp "$SUT" "$TMPROOT/lone/claude-tenants-edit"
run_at "$TMPROOT/lone/claude-tenants-edit" pool-add work w3
check "with no machines-render beside it, nothing is written" "$RC" "2"
want_err "...and it says machines-render is missing"          "machines-render is not beside"
unchanged "...and the file is untouched"

# `$(< f; cmd)` is not zsh's file shortcut: it runs $READNULLCMD. With a pager
# missing it read nothing (review, 2026-10-05); with `rev` it reads the file
# backwards, which this row would catch.
new_home i4; READNULLCMD=rev run pool-add work w3
check "the file is read directly, not through READNULLCMD" "$RC" "0"
check "...and the edit lands"                               "$(pool_of work)" "w1 w2 w3"

new_home k1 "$(cat <<'EOF'
typeset -gA CLAUDE_TENANT_POOL CLAUDE_TENANT_SPILL
CLAUDE_TENANT_POOL=(
  quantivly "w2 w3"
  w "w1"
)
CLAUDE_TENANT_SPILL=( w "w2" )
EOF
)"
run retire-name w2 "test"
check "a name a spill entry holds is not retired" "$RC" "1"
want_err "...naming the spill"                    "spill w"
run pool-remove w w1
check "emptying a pool a spill entry needs is refused as referenced" "$RC" "1"
want_err "...as every launch would refuse"        "every launch would refuse"

#-----------------------------------------------------------------------------
section "J. dump: the one reader claude-seat uses"
#-----------------------------------------------------------------------------
new_home j1; chmod 444 "$REAL"
run dump
check "dump reads a file it may not write"   "$RC" "0"
check "...one line per value, in the launch's table" "$(printf '%s\n' "$OUT" | tr '\037' '|' | grep -c '^POOL|work|w1 w2$')" "1"
run dump extra
check "dump takes no arguments"              "$RC" "64"
new_home j2; printf '%s\r\n' 'typeset -gA CLAUDE_TENANT_POOL' 'CLAUDE_TENANT_POOL=( work "w1" )' > "$REAL"
run dump
check "dump of a file that errors at run time is exit 2" "$RC" "2"

# --- the row total -----------------------------------------------------------
# Catches a row that vanished: an early exit, a deleted block, an emptied loop.
EXPECTED_ROWS=123
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '  \033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))"
    FAIL=$((FAIL + 1))
fi

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
