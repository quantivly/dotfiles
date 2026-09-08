#!/usr/bin/env bash
#
# scripts/test-claude-account-dirs.sh
# ===================================
#
# State table for scripts/claude-account-dirs.sh.
#
# HERMETIC VIA A FIXTURE $HOME, and that is not decoration. The script under test
# writes to ~/.local/state/claude-account-dirs/ and reads ~/.clauth/profiles/; on
# the box it was written for those hold four live Claude logins. A row that ran
# with the real $HOME would build real account dirs pointing at real credentials.
# Every run below therefore asserts the fixture is in place before invoking it.
#
# The rows are written against the states that produce a SUCCESSFUL-looking build,
# because that is how this script's predecessor failed: it seeded .claude.json
# from ~/.claude/.claude.json — a 1,156-byte husk with no projects, no
# hasCompletedOnboarding and a different machineID — which is still valid JSON, so
# the build "worked" and every session started with first-run onboarding and a
# trust dialog in every worktree.
#
# Requires: bash, and the coreutils the script itself uses. No network, no clauth,
# no Claude Code.
#
# Usage: scripts/test-claude-account-dirs.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so a fix can be reverted in a COPY of the script and the row that
# names it re-run against the mutant. A row that passes both ways pins nothing.
#     ACCOUNT_DIRS_SH=/tmp/mutant.sh scripts/test-claude-account-dirs.sh
SUT="${ACCOUNT_DIRS_SH:-$DOTFILES/scripts/claude-account-dirs.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()      { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()     { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
fatal()   { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

want_out() { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1 — expected output to contain '$2'"; fi; }
no_out()   { if [[ "$OUT" != *"$2"* ]]; then ok "$1"; else bad "$1 — output must NOT contain '$2'"; fi; }
want_rc()  { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1 — expected exit $2, got $RC"; fi; }
want_link(){ # $1 label, $2 path, $3 expected target
    if [[ -L "$2" && "$(readlink "$2")" == "$3" ]]; then ok "$1"
    else bad "$1 — $2 is not a symlink to $3 (readlink: '$(readlink "$2" 2>/dev/null)')"; fi; }
want_file(){ # $1 label, $2 path — a REAL file, explicitly not a symlink
    if [[ -f "$2" && ! -L "$2" ]]; then ok "$1"
    else bad "$1 — $2 is not a real (non-symlink) file"; fi; }

[[ -r "$SUT" ]] || fatal "cannot read $SUT"

# A fresh fixture HOME per row: a suite whose rows leak into each other reports
# the previous row's verdict for the current row's fixture.
new_home() {
    FHOME="$TMPROOT/home.$1"
    rm -rf "$FHOME"
    mkdir -p "$FHOME/.claude/hooks" "$FHOME/.claude/plugins" "$FHOME/.claude/skills"
    printf '{"statusLine":{"type":"command","command":"x"},"enabledPlugins":{"a":true}}\n' \
        > "$FHOME/.claude/settings.json"
    printf 'user-level memory\n'  > "$FHOME/.claude/CLAUDE.md"
    printf 'stamp\n'              > "$FHOME/.claude/.last-cleanup"
    # The real config file lives in $HOME, NOT in $HOME/.claude — the distinction
    # this whole script exists to get right. Padded past the husk threshold.
    { printf '{"hasCompletedOnboarding":true,"projects":{"/w":{}},"pad":"'
      head -c 12000 /dev/zero | tr '\0' 'x'
      printf '"}\n'; } > "$FHOME/.claude.json"
    # ...and the husk, present and valid JSON, exactly as on the real machine.
    printf '{"machineID":"different","migrationVersion":1}\n' > "$FHOME/.claude/.claude.json"
    ACCOUNT_ROOT="$FHOME/.local/state/claude-account-dirs"
}

mk_profile() {  # $1 = name; $2 = "nocred" to create the dir without a credential
    mkdir -p "$FHOME/.clauth/profiles/$1"
    [[ "${2:-}" == nocred ]] && return 0
    printf '{"claudeAiOauth":{"accessToken":"tok-%s"}}\n' "$1" \
        > "$FHOME/.clauth/profiles/$1/credentials.json"
}

# A credential with a chosen expiry. `stub` is the shape Claude Code writes after
# OAuth discovery but before authorisation -- an empty accessToken and NO
# expiresAt -- which is a real state on the machine this was written for and must
# never be mistaken for a live credential. `bad` is unparseable.
mk_cred() {  # $1 = path, $2 = expiresAt | stub | bad, $3 = optional marker
    local path="$1" kind="$2" mark="${3:-m}"
    case "$kind" in
        stub) printf '{"claudeAiOauth":{"accessToken":"","clientId":"c","serverName":"s"}}\n' > "$path" ;;
        bad)  printf 'not json at all: %s\n' "$mark" > "$path" ;;
        *)    printf '{"claudeAiOauth":{"accessToken":"CANARY-%s","expiresAt":%s},"mcpOAuth":{"n":{}}}\n' \
                  "$mark" "$kind" > "$path" ;;
    esac
    chmod 600 "$path"
}

# Put the account dir into the state a token refresh leaves behind: a REAL file
# where the symlink used to be. This is not corruption -- Claude Code writes the
# credential atomically, and a rename replaces a symlink.
as_rotated_real_file() {  # $1 = profile, $2 = expiresAt | stub | bad, $3 = marker
    local a="$ACCOUNT_ROOT/$1/.credentials.json"
    rm -f "$a"
    mk_cred "$a" "$2" "${3:-live}"
}

store_of()  { printf '%s\n' "$FHOME/.clauth/profiles/$1/credentials.json"; }
backups_of(){ shopt -s nullglob; local g=("$1".superseded-*); shopt -u nullglob; printf '%d\n' "${#g[@]}"; }

run_sut() {
    [[ -n "${FHOME:-}" && -d "$FHOME" ]] || fatal "no fixture HOME — refusing to run against the real one"
    OUT="$(env -u CLAUDE_ACCOUNT_DIRS_ROOT HOME="$FHOME" bash "$SUT" "$@" 2>&1)"
    RC=$?
}

echo "=== claude-account-dirs state table ==="

#-----------------------------------------------------------------------------
section "A. Refusals — a wrong answer here builds a config dir that half works"
#-----------------------------------------------------------------------------
new_home a1; mk_profile p1
run_sut
want_rc  "no arguments is a usage error" 2

new_home a2; mk_profile p1
run_sut nosuch
want_rc  "an unregistered profile is refused"  1
want_out "and it is named"                     "no clauth profile 'nosuch'"

# A profile directory with no credential is the state right after `clauth`
# creates one. Building an account dir for it would produce a .credentials.json
# symlink pointing at nothing, which Claude Code reads as "not logged in" — a
# fresh /login into a file clauth does not own.
new_home a3; mk_profile p2 nocred
run_sut p2
want_rc  "a profile with no credential is refused"  1
want_out "and the fix is named"                     "clauth login p2"
if [[ ! -e "$ACCOUNT_ROOT/p2/.credentials.json" ]]; then
    ok "and no dangling credential link is left behind"
else
    bad "a refused build left $ACCOUNT_ROOT/p2/.credentials.json"
fi

new_home a4; mkdir -p "$FHOME/.clauth/profiles"
run_sut --all
want_rc  "--all with no usable profile is refused" 1
want_out "and says so"                             "no profiles with credentials.json"

#-----------------------------------------------------------------------------
section "B. Layout — clauth start's own, at a stable path"
#-----------------------------------------------------------------------------
new_home b1; mk_profile p1
run_sut p1
want_rc "a good build succeeds" 0
if [[ "$OUT" == "$ACCOUNT_ROOT/p1" ]]; then
    ok "stdout is exactly the account dir path, so a caller can capture it"
else
    bad "stdout was '$OUT', expected '$ACCOUNT_ROOT/p1'"
fi

D="$ACCOUNT_ROOT/p1"
want_link "directories are shared with ~/.claude"        "$D/hooks"    "$FHOME/.claude/hooks"
want_link "plugins are shared, so MCP servers survive"   "$D/plugins"  "$FHOME/.claude/plugins"
want_link "skills are shared"                            "$D/skills"   "$FHOME/.claude/skills"
want_link "user-level CLAUDE.md is shared"               "$D/CLAUDE.md" "$FHOME/.claude/CLAUDE.md"
want_link "dotfiles are shared too, not just visible ones" "$D/.last-cleanup" "$FHOME/.claude/.last-cleanup"

# THE ROW THE WHOLE DESIGN RESTS ON. A copy would be an independent holder of one
# OAuth grant, and refresh-token rotation is server-side — the first rotation
# would orphan the other holder for real, which is the failure this mechanism
# exists to remove rather than to manufacture.
want_link "the credential is a SYMLINK to the profile store, never a copy" \
          "$D/.credentials.json" "$FHOME/.clauth/profiles/p1/credentials.json"

# Not a symlink: clauth rewrites the global settings.json's env/[models] on a
# profile switch, and a symlink would import that churn into every account dir.
want_file "settings.json is a real file, not a link to the global one" "$D/settings.json"
if cmp -s "$D/settings.json" "$FHOME/.claude/settings.json"; then
    ok "and its content is the global one, so hooks and statusLine survive"
else
    bad "settings.json content does not match ~/.claude/settings.json"
fi

want_file ".claude.json is a real file — it carries per-account oauthAccount/userID" "$D/.claude.json"

#-----------------------------------------------------------------------------
section "C. Seeding .claude.json — the husk is the trap"
#-----------------------------------------------------------------------------
new_home c1; mk_profile p1
run_sut p1
if cmp -s "$ACCOUNT_ROOT/p1/.claude.json" "$FHOME/.claude.json"; then
    ok ".claude.json is seeded from ~/.claude.json"
else
    bad ".claude.json was not seeded from ~/.claude.json"
fi
if cmp -s "$ACCOUNT_ROOT/p1/.claude.json" "$FHOME/.claude/.claude.json"; then
    bad ".claude.json was seeded from the ~/.claude/ husk — onboarding in every worktree"
else
    ok "and NOT from the ~/.claude/.claude.json husk"
fi

# The husk is valid JSON, so nothing downstream would have complained.
new_home c2; mk_profile p1
printf '{"machineID":"x","migrationVersion":1}\n' > "$FHOME/.claude.json"
run_sut p1
want_rc  "an implausibly small ~/.claude.json is a hard error" 1
want_out "and says what it would have cost"                    "husk"
if [[ ! -e "$ACCOUNT_ROOT/p1/.claude.json" ]]; then
    ok "and no half-built .claude.json is left behind"
else
    bad "the refused build still wrote $ACCOUNT_ROOT/p1/.claude.json"
fi

new_home c3; mk_profile p1; rm -f "$FHOME/.claude.json"
run_sut p1
want_rc  "an absent ~/.claude.json is refused, not defaulted" 1
want_out "and says which file it wanted"                      ".claude.json"

# Re-running must not throw away the account's accumulated project trust.
new_home c4; mk_profile p1
run_sut p1
printf '{"projects":{"/w":{}},"mine":"do-not-clobber"}\n' > "$ACCOUNT_ROOT/p1/.claude.json"
run_sut p1
want_rc "a re-run succeeds" 0
if grep -q 'do-not-clobber' "$ACCOUNT_ROOT/p1/.claude.json"; then
    ok "a re-run does NOT overwrite an existing .claude.json"
else
    bad "the re-run clobbered .claude.json"
fi

#-----------------------------------------------------------------------------
section "D. Refresh and prune — a persistent dir has no fresh-launch moment"
#-----------------------------------------------------------------------------
# clauth's runtime dirs get a new settings.json snapshot every launch because the
# whole directory is rebuilt. A persistent one has no such moment, so the builder
# is that moment; without this the dir silently keeps whatever settings.json was
# current the day it was created.
new_home d1; mk_profile p1
run_sut p1
printf '{"statusLine":{"type":"command","command":"CHANGED"}}\n' > "$FHOME/.claude/settings.json"
run_sut p1
if grep -q CHANGED "$ACCOUNT_ROOT/p1/settings.json"; then
    ok "settings.json is refreshed from the global one on a re-run"
else
    bad "settings.json went stale — the account dir kept the old copy"
fi
want_out "and the refresh is reported, not silent" "settings.json refreshed"

# [[ -e ]] follows symlinks, so a dangling link is invisible to any check that
# only asks whether something is there — the trap that hid a dangling systemd
# unit link for a whole reboot (CLAUDE.md).
new_home d2; mk_profile p1
mkdir -p "$FHOME/.claude/goingaway"
run_sut p1
rmdir "$FHOME/.claude/goingaway"
run_sut p1
if [[ ! -L "$ACCOUNT_ROOT/p1/goingaway" ]]; then
    ok "a link whose source disappeared is pruned"
else
    bad "a dangling link to a removed ~/.claude entry survived"
fi
want_out "and the prune is reported" "pruned dangling link"
if [[ -L "$ACCOUNT_ROOT/p1/hooks" ]]; then
    ok "and links whose source still exists are kept"
else
    bad "the prune removed a live link"
fi

#-----------------------------------------------------------------------------
section "E. --all"
#-----------------------------------------------------------------------------
new_home e1; mk_profile p1; mk_profile p2; mk_profile p3 nocred
run_sut --all
want_rc "--all succeeds" 0
if [[ -L "$ACCOUNT_ROOT/p1/.credentials.json" && -L "$ACCOUNT_ROOT/p2/.credentials.json" ]]; then
    ok "--all builds every profile that has a credential"
else
    bad "--all missed a profile"
fi
if [[ ! -d "$ACCOUNT_ROOT/p3" ]]; then
    ok "--all skips a profile directory with no credential"
else
    bad "--all built an account dir for a profile with no credential"
fi

#-----------------------------------------------------------------------------
section "F. Credential reconciliation — the account dir vs the clauth store"
#-----------------------------------------------------------------------------
# THE BUG THIS SECTION EXISTS FOR. Claude Code writes .credentials.json
# atomically, so a rename REPLACES the symlink this script creates with a real
# file holding a freshly ROTATED token. The old code then ran an unconditional
# `ln -sfn` on the next launch, restoring the store's SUPERSEDED token -- and
# because rotation is server-side, that logged out every live session on the
# account. Three of four account dirs were in this state when it was found, and
# clauth had already quarantined one profile as auth_broken.

new_home f1; mk_profile p1
run_sut p1
want_link "a first build links the credential to the store" \
          "$ACCOUNT_ROOT/p1/.credentials.json" "$(store_of p1)"
run_sut p1
want_link "a rebuild leaves a healthy link alone" \
          "$ACCOUNT_ROOT/p1/.credentials.json" "$(store_of p1)"
if [[ "$(backups_of "$(store_of p1)")" == 0 ]]; then
    ok "and the healthy path makes no backups"
else
    bad "a healthy rebuild made a backup"
fi

# The row the whole fix rests on: revert reconcile_credential to `ln -sfn` and
# this must fail.
new_home f2; mk_profile p1
run_sut p1
mk_cred "$(store_of p1)" 1000 old
as_rotated_real_file p1 9999 rotated
cp "$ACCOUNT_ROOT/p1/.credentials.json" "$TMPROOT/f2.rotated"
run_sut p1
want_rc  "a rebuild over a rotated credential succeeds" 0
want_out "and says it adopted it"                       "adopted the live session"
want_link "the account dir is a symlink again" \
          "$ACCOUNT_ROOT/p1/.credentials.json" "$(store_of p1)"
if cmp -s "$TMPROOT/f2.rotated" "$(store_of p1)"; then
    ok "THE ROTATED TOKEN SURVIVED: the store now holds it, not the superseded one"
else
    bad "the rotated credential was CLOBBERED — this is the logout bug"
fi
if [[ "$(backups_of "$(store_of p1)")" == 1 ]]; then
    ok "and the superseded store copy was kept, not destroyed"
else
    bad "the superseded store copy was not kept"
fi

# The mirror image: a stale real file must not be adopted over a newer store.
new_home f3; mk_profile p1
run_sut p1
mk_cred "$(store_of p1)" 9999 fresh
cp "$(store_of p1)" "$TMPROOT/f3.store"
as_rotated_real_file p1 1000 stale
run_sut p1
want_out "a superseded account-dir credential is relinked, not adopted" "superseded credential"
if cmp -s "$TMPROOT/f3.store" "$(store_of p1)"; then
    ok "and the store's newer credential is untouched"
else
    bad "a stale account-dir credential overwrote a newer store credential"
fi
if [[ "$(backups_of "$ACCOUNT_ROOT/p1/.credentials.json")" == 1 ]]; then
    ok "and the discarded copy was kept anyway"
else
    bad "the discarded account-dir credential was destroyed"
fi

# A discovery stub is not a live credential, however recently it was written.
new_home f4; mk_profile p1
run_sut p1
mk_cred "$(store_of p1)" 5000 real
cp "$(store_of p1)" "$TMPROOT/f4.store"
as_rotated_real_file p1 stub
run_sut p1
if cmp -s "$TMPROOT/f4.store" "$(store_of p1)"; then
    ok "a discovery stub never displaces a real credential"
else
    bad "a discovery stub was adopted over a live credential"
fi

new_home f5; mk_profile p1
run_sut p1
mk_cred "$(store_of p1)" bad storeside
as_rotated_real_file p1 bad liveside
cp "$(store_of p1)" "$TMPROOT/f5.store"
run_sut p1
want_out "two unreadable credentials are refused, not guessed at" "neither could be read"
want_file "and the account dir file is left exactly as it was" "$ACCOUNT_ROOT/p1/.credentials.json"
if cmp -s "$TMPROOT/f5.store" "$(store_of p1)"; then
    ok "and so is the store"
else
    bad "an unreadable pair was written to anyway"
fi

# A build refuses earlier, on its own guard, and never reaches the reconciler.
new_home f6; mk_profile p1
run_sut p1
rm -f "$(store_of p1)"
as_rotated_real_file p1 9999 live
run_sut p1
want_out "a build with no store credential is refused before reconciling" "has no credentials.json yet"
want_file "and the live account-dir credential is not touched" "$ACCOUNT_ROOT/p1/.credentials.json"

# --reconcile has no such guard -- it is the timer's path, and it must refuse to
# invent a credential rather than leave a dangling link where a live one was.
new_home f6b; mk_profile p1
run_sut p1
rm -f "$(store_of p1)"
as_rotated_real_file p1 9999 live
cp "$ACCOUNT_ROOT/p1/.credentials.json" "$TMPROOT/f6b.live"
run_sut --reconcile
want_out "--reconcile refuses a missing store credential, never invents one" "refusing to"
want_out "and names the fix"                                                 "clauth login p1"
want_file "and leaves the live credential exactly where it is" "$ACCOUNT_ROOT/p1/.credentials.json"
if cmp -s "$TMPROOT/f6b.live" "$ACCOUNT_ROOT/p1/.credentials.json"; then
    ok "and unmodified — a refusal that destroys the only copy is worse than none"
else
    bad "the only surviving credential was altered by a refusal path"
fi

new_home f7; mk_profile p1; mk_profile p2
run_sut p1
ln -sfn "$(store_of p2)" "$ACCOUNT_ROOT/p1/.credentials.json"
run_sut p1
want_out "a link to the WRONG profile's store is caught" "pointed somewhere other than"
want_link "and repointed at this profile's own store" \
          "$ACCOUNT_ROOT/p1/.credentials.json" "$(store_of p1)"

# The mtime fallback, exercised on a PATH with no jq. Without this row the
# fallback is unreachable code that only runs on someone else's machine.
new_home f8; mk_profile p1
run_sut p1
mk_cred "$(store_of p1)" 9999 old
touch -d '2020-01-01' "$(store_of p1)"
as_rotated_real_file p1 1000 rotated
cp "$ACCOUNT_ROOT/p1/.credentials.json" "$TMPROOT/f8.rotated"
NOJQ="$TMPROOT/nojq"; mkdir -p "$NOJQ"
for b in bash cp mv rm ln stat date cmp chmod mkdir basename ls awk readlink flock; do
    src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$NOJQ/$b"
done
OUT="$(env -u CLAUDE_ACCOUNT_DIRS_ROOT HOME="$FHOME" PATH="$NOJQ" bash "$SUT" p1 2>&1)"; RC=$?
if ! command -v jq >/dev/null 2>&1 || [[ -x "$NOJQ/jq" ]]; then
    ok "(jq fallback row skipped: could not build a jq-free PATH)"
elif cmp -s "$TMPROOT/f8.rotated" "$(store_of p1)"; then
    ok "with no jq, mtime still adopts the file written last"
else
    bad "with no jq, the newer account-dir credential was clobbered"
fi

# `claude()` runs this on every launch, so two sessions starting together race
# the adopt: both read the diverged state, both back up, both write. Testing that
# by racing real processes is flaky in both directions, so this holds the lock
# from OUTSIDE and asserts the script WAITS for it -- deterministic, and it fails
# the moment the locking is removed.
new_home f9; mk_profile p1
run_sut p1
if command -v flock >/dev/null 2>&1; then
    LOCKF="$FHOME/.clauth/profiles/p1/.reconcile.lock"
    flock -x "$LOCKF" -c 'sleep 3' &
    HOLDER=$!
    sleep 0.4                       # let the holder actually take it
    T0=$(date +%s%N)
    run_sut p1
    T1=$(date +%s%N)
    wait "$HOLDER" 2>/dev/null
    WAITED_MS=$(( (T1 - T0) / 1000000 ))
    if (( WAITED_MS >= 1500 )); then
        ok "a second launch WAITS for the credential lock (${WAITED_MS}ms)"
    else
        bad "a second launch did not wait for the lock (${WAITED_MS}ms) — two launches can race the adopt"
    fi
    want_rc "and still succeeds once it has the lock" 0
else
    ok "(lock row skipped: no flock on this machine)"
fi

#-----------------------------------------------------------------------------
section "G. --reconcile — the path the timer takes"
#-----------------------------------------------------------------------------
new_home g1; mk_profile p1; mk_profile p2
run_sut --all
mk_cred "$(store_of p1)" 1000 old
as_rotated_real_file p1 9999 rotated
cp "$ACCOUNT_ROOT/p1/.credentials.json" "$TMPROOT/g1.rotated"
run_sut --reconcile
want_rc  "--reconcile succeeds" 0
want_link "and restores the invariant" \
          "$ACCOUNT_ROOT/p1/.credentials.json" "$(store_of p1)"
if cmp -s "$TMPROOT/g1.rotated" "$(store_of p1)"; then
    ok "and adopts the rotation without a rebuild"
else
    bad "--reconcile lost the rotated credential"
fi

new_home g2; mk_profile p1
run_sut --all
rm -f "$ACCOUNT_ROOT/p1/settings.json"
run_sut --reconcile
if [[ ! -e "$ACCOUNT_ROOT/p1/settings.json" ]]; then
    ok "--reconcile builds nothing: it only touches credentials"
else
    bad "--reconcile rebuilt settings.json — it is not a build"
fi

new_home g3; mk_profile p1
run_sut --all
mkdir -p "$ACCOUNT_ROOT/orphan"
run_sut --reconcile
want_out "an account dir with no clauth profile is named, not acted on" "no clauth profile"

new_home g4
mkdir -p "$FHOME/.clauth/profiles"
run_sut --reconcile
want_rc "--reconcile with nothing to do is not an error" 0

#-----------------------------------------------------------------------------
section "H. A diagnostic that prints a credential is worse than no diagnostic"
#-----------------------------------------------------------------------------
# Every message above names files and states. None may carry a token. The
# fixtures stamp CANARY- into every accessToken for exactly this row.
new_home h1; mk_profile p1
run_sut p1
mk_cred "$(store_of p1)" 1000 storeside
as_rotated_real_file p1 9999 livesid
run_sut p1
no_out "the adopt path never prints a token"  "CANARY-"
as_rotated_real_file p1 bad liveside
mk_cred "$(store_of p1)" bad storeside
run_sut p1
no_out "and neither does the refusal path"    "CANARY-"

#-----------------------------------------------------------------------------
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
