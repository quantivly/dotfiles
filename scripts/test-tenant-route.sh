#!/usr/bin/env bash
#
# scripts/test-tenant-route.sh
# ============================
#
# State table for scripts/tenant-route (DO-773): which tenant owns a directory.
#
# Why this exists: the answer decides WHICH SEAT A LANE BILLS and which account's
# books its row lands in. Two layers used to answer it by different keys and
# disagreed for any repository checked out away from its tenant's root — a lane
# billing one account while the interactive session in the same directory billed
# another. So every row below is about one question: can this hand back a tenant
# it did not actually derive? A directory git cannot read, a tenants file that
# cannot be parsed, and a stray line of output in that file must each be an
# ERROR and never an answer — least of all the default, which is the one wrong
# answer that looks right.
#
# HERMETIC: a fixture tenants file and fixture git repositories per case, under
# mktemp -d. No real ~/.config, no network, no commits — `git init` plus a
# remote URL is the whole of what routing reads.
# Requires: zsh, bash, jq, git.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTE="$DOTFILES/scripts/tenant-route"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
has()   { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — '$3' not in '${2:0:120}'"; fi; }
hasnt() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 — '$3' unexpectedly in '${2:0:120}'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for tool in zsh bash jq git; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
[[ -x "$ROUTE" ]] || fatal "$ROUTE is not executable — every row below would assert nothing"

# THE FIXTURE ROOT MUST NOT BE INSIDE A GIT REPOSITORY. Every "not a git
# repository" row below is answered by `git` walking UP from the fixture
# directory; if TMPROOT sat inside a checkout, those rows would silently be
# testing that checkout's remote instead, and the whole no-remote half of this
# table would pass for the wrong reason. Asserted rather than assumed, because
# mktemp's location is an environment variable away from changing.
if git -C "$TMPROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    fatal "$TMPROOT is inside a git repository, so the no-remote rows would assert nothing"
fi

# mktemp, NOT a counter. Every caller below is `f="$(tf ...)"`, and a command
# substitution is a subshell: an `N=$((N+1))` in here never reaches the parent,
# so every fixture would be written to the SAME path and each would overwrite
# the last. Measured, and it is worse than it sounds — the rows still pass,
# because each `run` follows its own `tf` immediately, and only a fixture reused
# LATER (a --check row, a second happy-path row) silently asserts against
# whichever file was written most recently. Same subshell rule as `run` below,
# which already carries the warning for exit codes.
tf() {   # $@ = lines of a fixture tenants file -> its path
    local f; f="$(mktemp "$TMPROOT/tenants.XXXXXX")" || return 1
    printf '%s\n' "$@" > "$f"; printf '%s' "$f"
}
repo() { # $1 = name, $2... = remote URLs (origin, then upstream, ...) -> its path
    local name="$1"; shift
    local d="$TMPROOT/repos/$name"
    mkdir -p "$d"; git -C "$d" init -q 2>/dev/null
    local i=0 rname
    for url in "$@"; do
        case $i in 0) rname=origin ;; 1) rname=upstream ;; *) rname="r$i" ;; esac
        git -C "$d" remote add "$rname" "$url"; i=$((i+1))
    done
    printf '%s' "$d"
}
plain() { # $1 = name -> a directory that is NOT a git repository
    local d="$TMPROOT/plain/$1"; mkdir -p "$d"; printf '%s' "$d"
}

# OUT / ERR / RC as globals, never inside $( ): a command substitution is a
# subshell, so an exit code assigned there dies with it and a row about exit 2
# would silently measure the previous row's 0. machines-render's table pays for
# this one already.
run() {  # $1 = tenants file, $2... = args to tenant-route
    local t="$1"; shift
    OUT="$(CLAUDE_TENANTS_FILE="$t" "$ROUTE" "$@" 2>"$TMPROOT/err")"; RC=$?
    ERR="$(cat "$TMPROOT/err")"
}

# The table every happy-path row routes against: one owner route, one path
# route, a default, and a pool per named tenant (the resolver refuses a tenant
# with no pool, so a fixture without them tests the pool check instead of what
# it meant to).
GOOD=( 'CLAUDE_TENANT_ROUTES=( "acme=work" "Widget-LTD=side" )'
       "CLAUDE_TENANT_PATH_ROUTES=( \"$TMPROOT/plain/placed=work\" )"
       'CLAUDE_TENANT_DEFAULT=home'
       'CLAUDE_TENANT_POOL=( work "work-0" side "side-0" home "home-0" )' )
GOODF="$(tf "${GOOD[@]}")"

echo "=== a repository is routed by its REMOTE OWNER, wherever it sits ==="
r="$(repo owned git@github.com:acme/thing.git)"
run "$GOODF" "$r"
check "exit 0"                        "$RC" "0"
check "the owner route decided"       "$(jq -r .tenant <<<"$OUT")" "work"
check "state is matched"              "$(jq -r .state <<<"$OUT")" "matched"
has   "why names the remote's owner"  "$(jq -r .why <<<"$OUT")" "acme"
check "three keys, no more"           "$(jq -r '. | keys | join(",")' <<<"$OUT")" "state,tenant,why"

r="$(repo second-remote git@github.com:nobody/x.git https://github.com/Widget-LTD/y.git)"
run "$GOODF" "$r"
check "ANY remote matches, not just origin" "$(jq -r .tenant <<<"$OUT")" "side"

echo
echo "=== THE RULE: a GitHub remote blocks the path table, even when it matches nothing ==="
# This is the whole reason rabota adopted this resolver rather than the other
# way round. A work repository checked out under a personal path must not be
# decided by the path — identity travels with the repository. A row that let the
# path win here would reinstate DO-773.
mkdir -p "$TMPROOT/plain/placed"
r="$(repo placed/inside git@github.com:nobody-we-know/z.git)"
run "$GOODF" "$r"
check "the path route did NOT decide"  "$(jq -r .tenant <<<"$OUT")" "home"
check "it fell through to the default" "$(jq -r .state <<<"$OUT")" "default"
has   "why says no route matched"      "$(jq -r .why <<<"$OUT")" "no route matched"

echo
echo "=== only a directory with NO GitHub remote is decided by its place ==="
d="$(plain placed)"
run "$GOODF" "$d"
check "the path route decided"        "$(jq -r .tenant <<<"$OUT")" "work"
check "state is matched"              "$(jq -r .state <<<"$OUT")" "matched"

d="$(plain elsewhere)"
run "$GOODF" "$d"
check "no route, so the default"      "$(jq -r .tenant <<<"$OUT")" "home"
check "state is default"              "$(jq -r .state <<<"$OUT")" "default"

r="$(repo no-remotes-at-all)"
run "$GOODF" "$r"
check "a repo with NO remotes is placed by path too" "$(jq -r .state <<<"$OUT")" "default"

echo
echo "=== a directory git cannot read REFUSES; it never becomes the default ==="
# The fail-open shape this script exists to close: "git could not be asked" is
# not "there is nothing here", and answering 'home' would hand a work repository
# the personal pool in silence.
run "$GOODF" "$TMPROOT/no/such/dir"
check "exit 2"                        "$RC" "2"
has   "the state is named"            "$ERR" "git-error"
hasnt "no tenant is printed"          "$OUT" "home"
check "nothing at all on stdout"      "$OUT" ""

echo
echo "=== a tenants file that cannot be used is an ERROR, never an answer ==="
run "$TMPROOT/absent.zsh" "$(plain elsewhere)"
check "missing file: exit 2"          "$RC" "2"
has   "missing file: says so"         "$ERR" "does not exist"
check "missing file: no stdout"       "$OUT" ""

mkdir -p "$TMPROOT/adir.zsh"
run "$TMPROOT/adir.zsh" "$(plain elsewhere)"
check "a directory: exit 2"           "$RC" "2"
has   "a directory: says so"          "$ERR" "not a regular file"

ln -sfn "$TMPROOT/gone-forever" "$TMPROOT/broken.zsh"
run "$TMPROOT/broken.zsh" "$(plain elsewhere)"
check "broken symlink: exit 2"        "$RC" "2"
has   "broken symlink: says so"       "$ERR" "symlink"

unreadable="$(tf 'CLAUDE_TENANT_DEFAULT=home' 'CLAUDE_TENANT_POOL=( home "home-0" )')"
chmod 000 "$unreadable"
run "$unreadable" "$(plain elsewhere)"
if [[ -r "$unreadable" ]]; then
    # Running as root reads anything, so the row cannot be reached. Loud, and
    # counted as a FAIL rather than skipped: a skipped row is neither a pass nor
    # a failure and makes a green suite mean less than it looks.
    bad "unreadable file: exit 2 — NOT REACHABLE as this user (the file stayed readable)"
else
    check "unreadable file: exit 2"   "$RC" "2"
    has   "unreadable file: says so"  "$ERR" "cannot read"
fi
chmod 644 "$unreadable"

noparse="$(tf 'CLAUDE_TENANT_ROUTES=( "unclosed')"
run "$noparse" "$(plain elsewhere)"
check "will not parse: exit 2"        "$RC" "2"
has   "will not parse: says so"       "$ERR" "does not parse"
has   "and hands over the check"      "$ERR" "zsh -n"

echo
echo "=== a malformed table is bad-table, and names the entry ==="
badroute="$(tf 'CLAUDE_TENANT_ROUTES=( "no-equals-sign" )' 'CLAUDE_TENANT_DEFAULT=home' \
               'CLAUDE_TENANT_POOL=( home "home-0" )')"
run "$badroute" "$(plain elsewhere)"
check "exit 2"                        "$RC" "2"
has   "the state is named"            "$ERR" "bad-table"
has   "the offending entry is quoted" "$ERR" "no-equals-sign"

nodefault="$(tf 'CLAUDE_TENANT_ROUTES=( "acme=work" )' 'CLAUDE_TENANT_DEFAULT=' \
                'CLAUDE_TENANT_POOL=( work "work-0" )')"
run "$nodefault" "$(plain elsewhere)"
check "no match and no default: exit 2" "$RC" "2"
check "no match and no default: no stdout" "$OUT" ""

echo
echo "=== a stray line in the tenants file cannot BECOME the answer ==="
# The marker protocol machines-render pays for: a `print` in a sourced file
# lands on the fork's stdout beside the real fields, and an unmarked reader
# would take it as data.
noisy="$(tf 'print "__TENANT__attacker"' 'CLAUDE_TENANT_ROUTES=( "acme=work" )' \
            'CLAUDE_TENANT_DEFAULT=home' 'CLAUDE_TENANT_POOL=( work "work-0" home "home-0" )')"
run "$noisy" "$(plain elsewhere)"
check "the stray line did not decide" "$(jq -r .tenant <<<"$OUT")" "home"
check "and the call still succeeded"  "$RC" "0"

echo
echo "=== the answer is a DOCUMENT, whatever punctuation why carries ==="
# `why` is prose quoting remote names and route patterns — "remote 'origin'
# owner 'acme' matches route 'acme'". Built by jq from typed pieces for exactly
# this reason; concatenation would make one apostrophe the difference between a
# document and a syntax error.
r="$(repo quoted "git@github.com:acme/it's-fine.git")"
run "$GOODF" "$r"
check "still valid JSON"              "$(jq -r .tenant <<<"$OUT" 2>/dev/null)" "work"
check "exit 0"                        "$RC" "0"
run "$GOODF" "$(plain elsewhere)"
check "why is a single JSON string"   "$(jq -r '.why | type' <<<"$OUT")" "string"

echo
echo "=== --check validates the file and answers nothing ==="
run "$GOODF" --check
check "good file: exit 0"             "$RC" "0"
check "good file: prints nothing"     "$OUT" ""
run "$noparse" --check
check "bad file: exit 2"              "$RC" "2"

echo
echo "=== usage is 64, and distinct from a fault ==="
run "$GOODF" --nope
check "unknown flag: exit 64"         "$RC" "64"
has   "unknown flag: prints usage"    "$ERR" "usage:"
run "$GOODF" one two
check "two arguments: exit 64"        "$RC" "64"

echo
echo "=== the resolver is REUSED, never reimplemented ==="
# The point of the script is that it calls the picker's own _claude_tenant_for.
# A rewrite in this file would pass every row above while reintroducing the
# second answer DO-773 exists to remove, so the coupling itself is asserted.
if grep -q '_claude_tenant_for' "$ROUTE"; then ok "tenant-route calls _claude_tenant_for"
else bad "tenant-route no longer calls _claude_tenant_for — it is parsing remotes itself"; fi
if grep -q 'zsh/zshrc.herdr' "$ROUTE"; then ok "and sources the file that defines it"
else bad "tenant-route no longer sources zsh/zshrc.herdr"; fi
# COMMENTS STRIPPED FIRST. This file's own prose explains why copying
# `_gh_url_owner` here would be the defect, and an unstripped grep matched that
# explanation — a row that failed because the reasoning for it was written down.
if sed 's/#.*//' "$ROUTE" | grep -qE '_gh_url_owner|github\.com'; then
    bad "tenant-route looks like it parses remote URLs itself"
else ok "tenant-route parses no remote URL of its own"; fi

echo
printf 'tenant-route state table: %d passed, %d failed\n' "$PASS" "$FAIL"

# The row total: a check that VANISHES — an early exit, an unset variable under
# set -u, a deleted block — leaves every surviving row green and the summary
# cheerful. This is what catches that; it says nothing about whether any row is
# HOLLOW, which is what the mutation sweep in the PR is for.
EXPECTED_ROWS=49
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '\033[1;31mFATAL\033[0m: expected %d rows, ran %d — a check was skipped or added\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))" >&2
    exit 2
fi
(( FAIL == 0 )) || exit 1
