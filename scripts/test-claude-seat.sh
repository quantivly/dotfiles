#!/usr/bin/env bash
#
# scripts/test-claude-seat.sh
# ===========================
#
# State table for `scripts/claude-seat add` (DO-796): one command from a new login
# to a verified, pooled seat.
#
# Why this exists: adding a seat by hand hit three silent failures on 2026-09-30,
# and each one looked like success. So most rows below assert the one property the
# command exists for: when any check fails, the seat is NOT in the pool. The pool
# is the last thing touched, and a pool naming a seat that failed a check is the
# failure this command removes.
#
# HERMETIC: a fixture HOME per row. `clauth`, `claude`, the account-dir builder and
# the picker are STUBS that record every call and touch only the fixture. This box
# has a real clauth wired to live accounts, and `clauth login` would start a real
# OAuth flow. The real claude-tenants-edit and the real claude.sh reader run
# against the fixture's tenants file. Synthetic accounts and addresses only: this
# repo is public.
#
# Requires: zsh, bash, git, jq.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="${CLAUDE_SEAT:-$DOTFILES/scripts/claude-seat}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
want_err() { if [[ "$ERR" == *"$2"* ]]; then ok "$1"; else bad "$1 — expected stderr to contain '$2'; got: ${ERR:0:300}"; fi; }
want_out() { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1 — expected stdout to contain '$2'; got: ${OUT:0:300}"; fi; }
no_log()   { if ! grep -q -- "$2" "$STUB_LOG" 2>/dev/null; then ok "$1"; else bad "$1 — the stubs were called with '$2'"; fi; }
want_log() { if grep -q -- "$2" "$STUB_LOG" 2>/dev/null; then ok "$1"; else bad "$1 — no stub call with '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

for tool in zsh bash git jq; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
[[ -r "$SUT" ]] || fatal "cannot read $SUT — every row below would assert nothing"

#-----------------------------------------------------------------------------
# The stubs
#-----------------------------------------------------------------------------
STUBS="$TMPROOT/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/clauth" <<'STUB'
#!/usr/bin/env bash
# `clauth login <name>`: what a real login leaves behind, in the fixture only.
printf 'clauth %s\n' "$*" >> "$STUB_LOG"
[[ "${1:-}" == login ]] || exit 0
[[ "${STUB_LOGIN_RC:-0}" == 0 ]] || exit "$STUB_LOGIN_RC"
[[ "${STUB_LOGIN_NOSTORE:-0}" == 1 ]] && exit 0
# A hand edit of the tenants file while the human is logging in.
[[ "${STUB_LOGIN_TOUCH_TENANTS:-0}" == 1 ]] && printf '# edited during the login\n' >> "$HOME/.config/claude-tenants.zsh"
d="$HOME/.clauth/profiles/$2"; mkdir -p "$d"
printf '{"claudeAiOauth":{"accessToken":"fake"}}\n' > "$d/credentials.json"
printf '"%s"\n' "${STUB_ACCOUNT_ID-uuid-$2}" > "$d/account_id.json"
printf '# clauth template: every line commented\n# auto_start = false\n# [models]\n# default = "x"\n' > "$d/config.toml"
[[ "${STUB_LOGIN_PARTIAL:-0}" == 1 ]] && exit 1
exit 0
STUB
cat > "$STUBS/claude" <<'STUB'
#!/usr/bin/env bash
# `claude auth status` and a first `claude -p` launch: either may write the
# seat's oauthAccount, as configured by the row. By default it is the account the
# login recorded, as Claude Code derives it from the credential.
printf 'claude %s\n' "$*" >> "$STUB_LOG"
write() {
  local cj="$CLAUDE_CONFIG_DIR/.claude.json" own
  own="$(jq -r . "$HOME/.clauth/profiles/${CLAUDE_CONFIG_DIR##*/}/account_id.json" 2>/dev/null)"
  [[ -s "$cj" ]] || printf '{}\n' > "$cj"
  jq --arg u "${STUB_UUID:-$own}" --arg t "${STUB_OTYPE:-claude_team}" \
     --arg o "${STUB_ORG:-org-1}" --arg e "${STUB_EMAIL:-seat@example.invalid}" \
     '.oauthAccount = {accountUuid: $u, organizationType: $t, organizationUuid: $o, emailAddress: $e, organizationName: "Fixture Org"}' \
     "$cj" > "$cj.tmp" && mv -f "$cj.tmp" "$cj"
}
if [[ "${1:-}" == auth ]]; then
  [[ "${STUB_AUTH_WRITES:-1}" == 1 ]] && write
  [[ -n "${STUB_AUTH_ERR:-}" ]] && { printf '%s\n' "$STUB_AUTH_ERR" >&2; exit 1; }
  exit 0
fi
if [[ "${1:-}" == -p ]]; then [[ "${STUB_LAUNCH_WRITES:-1}" == 1 ]] && write; exit 0; fi
exit 0
STUB
cat > "$STUBS/account-dirs" <<'STUB'
#!/usr/bin/env bash
# claude-account-dirs.sh <name>: the dir, its credential a LINK into the store.
printf 'account-dirs %s\n' "$*" >> "$STUB_LOG"
[[ "${STUB_AD_RC:-0}" == 0 ]] || exit "$STUB_AD_RC"
ad="$HOME/.local/state/claude-account-dirs/$1"; mkdir -p "$ad"
if [[ "${STUB_AD_COPY:-0}" == 1 ]]; then
  rm -f "$ad/.credentials.json"; cp "$HOME/.clauth/profiles/$1/credentials.json" "$ad/.credentials.json"
else
  ln -sfn "$HOME/.clauth/profiles/$1/credentials.json" "$ad/.credentials.json"
fi
# A first build seeds .claude.json from the global file, identity and all:
# STUB_AD_SEED="<uuid> <type> <org>" stands for a global file that names an account.
if [[ ! -e "$ad/.claude.json" ]]; then
  if [[ "${STUB_AD_CJ_BAD:-0}" == 1 ]]; then printf 'not json\n' > "$ad/.claude.json"
  elif [[ -n "${STUB_AD_SEED:-}" ]]; then
    read -r u t o <<< "$STUB_AD_SEED"
    jq -n --arg u "$u" --arg t "$t" --arg o "$o" \
      '{oauthAccount: {accountUuid: $u, organizationType: $t, organizationUuid: $o, emailAddress: "main@example.invalid"}}' > "$ad/.claude.json"
  else printf '{}\n' > "$ad/.claude.json"; fi
fi
STUB
cat > "$STUBS/pick" <<'STUB'
#!/usr/bin/env zsh
# claude-pick --tenant <t> --dry-run --explain: the pool line, on stderr.
print -r -- "pick $*" >> "$STUB_LOG"
typeset -gA CLAUDE_TENANT_POOL
source "$HOME/.config/claude-tenants.zsh" >/dev/null 2>&1
print -u2 -- "  pool:   ${STUB_PICK_LINE-${CLAUDE_TENANT_POOL[$2]-}}"
STUB
# The editor, when its commit fails AND its roll-back fails: the edit stands, and
# it exits 2. Everything else is passed to the real one.
cat > "$STUBS/edit-written-then-failed" <<'STUB'
#!/usr/bin/env zsh
if [[ " $* " == *" pool-add "* ]]; then
  zsh "$REAL_EDIT" "${@:#--commit}" >/dev/null 2>&1
  print -u2 -- "claude-tenants-edit: the commit failed AND the roll-back failed"
  exit 2
fi
exec zsh "$REAL_EDIT" "$@"
STUB
chmod +x "$STUBS"/*

BASE='typeset -ga CLAUDE_TENANT_ROUTES CLAUDE_TENANT_PATH_ROUTES CLAUDE_TENANT_BUCKETS
typeset -gA CLAUDE_TENANT_POOL CLAUDE_TENANT_OVERFLOW CLAUDE_TENANT_GH_DIR CLAUDE_TENANT_MACHINE_OWNED

CLAUDE_TENANT_ROUTES=(
  "orgq=quantivly"
)
CLAUDE_TENANT_DEFAULT=personal

CLAUDE_TENANT_POOL=(
  quantivly "quantivly-1 quantivly-3"
  personal  "personal-0"
)

CLAUDE_TENANT_MACHINE_OWNED=(
  quantivly-4 "box (server)"
)
CLAUDE_TENANT_MACHINE_ID=(
  quantivly-4 box
)'
M1='[models]
default = "opus[1m]"'

seat() {   # $1 = profile, $2 = org type, $3 = org id ('' = no account dir)
    local p="$1" pd="$FHOME/.clauth/profiles/$1" ad="$FHOME/.local/state/claude-account-dirs/$1"
    mkdir -p "$pd"
    printf '{"claudeAiOauth":{"accessToken":"fake"}}\n' > "$pd/credentials.json"
    printf '"uuid-%s"\n' "$p" > "$pd/account_id.json"
    printf '%s\n' "$M1" > "$pd/config.toml"
    if [[ -n "${2:-}" ]]; then
        mkdir -p "$ad"; ln -sfn "$pd/credentials.json" "$ad/.credentials.json"
        jq -n --arg u "uuid-$p" --arg t "$2" --arg o "$3" \
            '{oauthAccount: {accountUuid: $u, organizationType: $t, organizationUuid: $o}}' > "$ad/.claude.json"
    fi
}
new_home() {   # $1 = name, $2 = tenants content (default BASE)
    FHOME="$TMPROOT/home.$1"; rm -rf "$FHOME"
    mkdir -p "$FHOME/.config" "$FHOME/repo/claude" "$FHOME/.clauth/profiles" \
             "$FHOME/.local/state/claude-account-dirs" "$FHOME/.dotfiles-local/rabota/tenants"
    REAL="$FHOME/repo/claude/tenants.zsh"
    printf '%s\n' "${2-$BASE}" > "$REAL"
    ln -s "$REAL" "$FHOME/.config/claude-tenants.zsh"
    seat quantivly-1 claude_team org-1
    seat quantivly-3 claude_team org-1
    seat quantivly-4
    seat personal-0 claude_max org-p
    ln -s quantivly-1 "$FHOME/.local/state/claude-account-dirs/quantivly-2"
    mkdir -p "$FHOME/.local/state/claude-account-dirs/quantivly-0.retired-20260917"
    printf '[seats]\nlocal = "quantivly-1"\n' > "$FHOME/.dotfiles-local/rabota/tenants/quantivly.toml"
    printf 'quantivly-1\t123\n' > "$FHOME/.local/state/claude-account-dirs/.pick-ledger"
    printf '[user]\n  name = fixture\n  email = fixture@example.invalid\n[commit]\n  gpgsign = false\n[init]\n  defaultBranch = main\n' > "$FHOME/.gitconfig"
    gitf -C "$FHOME/repo" init -q && gitf -C "$FHOME/repo" add -A && gitf -C "$FHOME/repo" commit -q -m init
    STUB_LOG="$FHOME/stub.log"; : > "$STUB_LOG"
}
gitf() { GIT_CONFIG_GLOBAL="$FHOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 git "$@"; }

# OUT / ERR / RC as globals. stdin is /dev/null: never a terminal, so the
# first-launch question is never answered by accident.
run() {
    OUT="$(env -u CLAUDE_TENANTS_FILE -u CLAUDE_ACCOUNT_DIRS_ROOT -u XDG_STATE_HOME \
               HOME="$FHOME" STUB_LOG="$STUB_LOG" \
               GIT_CONFIG_GLOBAL="$FHOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
               CLAUDE_SEAT_CLAUTH="$STUBS/clauth" CLAUDE_SEAT_CLAUDE="$STUBS/claude" \
               CLAUDE_SEAT_ACCOUNT_DIRS="$STUBS/account-dirs" CLAUDE_SEAT_PICK="$STUBS/pick" \
               zsh "$SUT" "$@" </dev/null 2>"$TMPROOT/err")"; RC=$?
    ERR="$(cat "$TMPROOT/err")"
}
pool_of() {
    zsh -f -c 'typeset -gA CLAUDE_TENANT_POOL; source "$1" >/dev/null 2>&1; print -r -- "${CLAUDE_TENANT_POOL[$2]-<none>}"' _ "$REAL" "$1"
}
not_pooled() { check "$1" "$(pool_of quantivly)" "quantivly-1 quantivly-3"; }

echo "=== claude-seat state table ==="

#-----------------------------------------------------------------------------
section "A. Usage"
#-----------------------------------------------------------------------------
new_home a
run;                                  check "no arguments is a usage error"         "$RC" "64"
run add;                              check "add with no tenant is a usage error"   "$RC" "64"
run add --force quantivly;            check "an unknown option is a usage error"    "$RC" "64"
run add quantivly a b;                check "too many arguments is a usage error"   "$RC" "64"
run add --email;                      check "--email with no address is a usage error" "$RC" "64"

#-----------------------------------------------------------------------------
section "B. Preflight refusals: nothing is touched"
#-----------------------------------------------------------------------------
new_home b1; run add nosuch
check "an unknown tenant is refused" "$RC" "1"
want_err "...as having no pool, not by a later accident" "has no pool in the tenants file"
new_home b2; printf '[models]\ndefault = "sonnet"\n' > "$FHOME/.clauth/profiles/quantivly-3/config.toml"
run add quantivly
check "a pool whose members disagree is refused"   "$RC" "1"
want_err "...naming the two members"               "'quantivly-1' and 'quantivly-3' disagree"
no_log   "...before any login"                     "clauth login"
new_home b3; run add quantivly 'quantivly-5+x'
check "a name with a character the picker rejects is refused" "$RC" "1"
want_err "...for its characters, not the prefix rule"  "may only contain letters, digits"
no_log   "...before any login"                         "clauth login"
new_home b4; chmod 000 "$FHOME/.clauth/profiles/quantivly-3/config.toml"
run add quantivly
check "a member's unreadable config.toml is exit 2, not read as agreeing" "$RC" "2"
want_err "...naming it"                                "cannot read $FHOME/.clauth/profiles/quantivly-3/config.toml"
no_log   "...before any login"                         "clauth login"
new_home b5; : > "$FHOME/.clauth/profiles/quantivly-4/account_id.json"
run add quantivly
check "another profile's empty account id is exit 2" "$RC" "2"
want_err "...as a second login it could not tell apart" "cannot read the account id of 'quantivly-4'"
no_log   "...found before any login"                   "clauth login"

#-----------------------------------------------------------------------------
section "C. A name that has never existed"
#-----------------------------------------------------------------------------
new_home c1; run add --dry-run quantivly
check "a dry run passes" "$RC" "0"
want_out "the next free number skips retired, compat and owned names" "proposed name: quantivly-5"
no_log   "...and a dry run logs in to nothing"                         "clauth"
check    "...and creates no profile" "$([[ -e "$FHOME/.clauth/profiles/quantivly-5" ]] && echo yes || echo no)" "no"
new_home c2; run add --dry-run personal
want_out "another tenant's prefix is its own name" "proposed name: personal-1"

new_home c3; run add quantivly quantivly-2
check "a compat symlink's name is refused" "$RC" "1"; want_err "...named as one" "a compat symlink"
new_home c4; run add quantivly quantivly-0
check "a retired dir's name is refused" "$RC" "1"; want_err "...named as one" "a retired account dir"
new_home c5; run add quantivly quantivly-4
check "a machine-owned name is refused" "$RC" "1"
new_home c6; printf '[seats]\nlocal = "quantivly-9"\n' > "$FHOME/.dotfiles-local/rabota/tenants/other.toml"
run add quantivly quantivly-9
check "a name rabota uses is refused" "$RC" "1"; want_err "...naming rabota" "rabota's seat"
new_home c10; printf 'quantivly-8\t99\n' >> "$FHOME/.local/state/claude-account-dirs/.pick-ledger"
run add quantivly quantivly-8
check "a name only the picker's ledger remembers is refused" "$RC" "1"
want_err "...naming the ledger"                              "the picker's ledger"

new_home c11; run add personal ..
check "'..' is refused as a name" "$RC" "1"
want_err "...for how it starts"   "must start with a letter or digit"
no_log   "...before any login"    "clauth login"

new_home c12; printf "[seats]\nlocal = 'quantivly-5'\n" > "$FHOME/.dotfiles-local/rabota/tenants/other.toml"
run add --dry-run quantivly
want_out "a rabota seat in single quotes counts" "proposed name: quantivly-6"
new_home c13; printf '[general]\nseats = { local = "quantivly-5" }\n' > "$FHOME/.dotfiles-local/rabota/tenants/other.toml"
run add --dry-run quantivly
want_out "a rabota seat in an inline table counts" "proposed name: quantivly-6"
new_home c14; : > "$FHOME/.local/state/claude-account-dirs/.pick-ledger"; : > "$FHOME/.dotfiles-local/rabota/tenants/empty.toml"
run add --dry-run quantivly
check "an empty ledger and an empty rabota file are read as empty" "$RC" "0"
want_out "...and the name is still proposed"                         "proposed name: quantivly-5"
new_home c15; chmod 000 "$FHOME/.dotfiles-local/rabota/tenants/quantivly.toml"
run add --dry-run quantivly
check "an unreadable rabota file is exit 2: it may name a seat" "$RC" "2"
want_err "...naming it"                                         "quantivly.toml, which may name a seat"
new_home c15b; chmod 000 "$FHOME/.local/state/claude-account-dirs/.pick-ledger"
run add --dry-run quantivly
check "an unreadable picker ledger is exit 2: it remembers names" "$RC" "2"
want_err "...naming it"                                           ".pick-ledger, which remembers names"

new_home c16; seat quantivly-5
run add quantivly
check "a seat a run started and did not finish is not proposed past" "$RC" "1"
want_err "...and the refusal says how to resume it"                  "Resume it: claude-seat add quantivly quantivly-5"
no_log   "...before any second login"                                "clauth login"

new_home c7; run add quantivly quantivly-3
check "a name already in a pool is refused" "$RC" "1"; want_err "...as used" "already been used"
new_home c8; run add quantivly personal-5
check "a work seat outside the work prefix is refused" "$RC" "1"
new_home c9; run add personal quantivly-7
check "another tenant's seat inside the work prefix is refused" "$RC" "1"

#-----------------------------------------------------------------------------
section "D. The whole way through"
#-----------------------------------------------------------------------------
new_home d1; run add quantivly
check "a seat is added"                         "$RC" "0"
want_log "...through clauth login"              "clauth login quantivly-5"
check "...with its pool's settings"             "$(cat "$FHOME/.clauth/profiles/quantivly-5/config.toml")" "$M1"
want_log "...an account dir built"              "account-dirs quantivly-5"
want_log "...its identity read"                 "claude auth status"
check "...and the pool names it"                "$(pool_of quantivly)" "quantivly-1 quantivly-3 quantivly-5"
check "...in a commit of the tenants file"      "$(gitf -C "$FHOME/repo" log -1 --format=%s)" "tenants: pool-add quantivly quantivly-5"
want_out "...the picker sees it"                "the picker sees 'quantivly-5'"
want_out "...and what is left is listed"        "claude-as quantivly-5, then /mcp"
no_log   "...with no first launch needed"       "claude -p"

new_home d2; STUB_OTYPE=claude_max run add personal
check "a seat in a pool of individual accounts is added" "$RC" "0"
check "...and its pool names it" "$(pool_of personal)" "personal-0 personal-1"

new_home d3; run add personal
check "a team account in a pool of individual accounts is refused" "$RC" "1"
want_err "...naming both types"     "is a claude_team account, and 'personal-0' is claude_max"
check "...and the pool is unchanged" "$(pool_of personal)" "personal-0"

# The account dir is seeded from ~/.claude.json, identity and all.
new_home d4; STUB_AD_SEED="uuid-main claude_team org-1" STUB_OTYPE=claude_max run add quantivly
check "an identity copied into the dir is not judged: the login's own is" "$RC" "1"
want_log "...auth status is asked for it"                                  "claude auth status"
want_err "...and the login's own type is refused"                          "is a claude_max account"
not_pooled "...and the seat is not pooled"
new_home d5; STUB_AD_SEED="uuid-quantivly-1 claude_team org-1" run add quantivly
check "a copied identity naming another seat does not refuse a good login" "$RC" "0"
check "...which is pooled" "$(pool_of quantivly)" "quantivly-1 quantivly-3 quantivly-5"

# Members whose account dir names ANOTHER account (a stale copy) are not compared.
new_home d6
jq -n '{oauthAccount: {accountUuid: "uuid-stale", organizationType: "claude_max", organizationUuid: "org-x"}}' \
    > "$FHOME/.local/state/claude-account-dirs/quantivly-1/.claude.json"
run add quantivly
check "a member with a stale identity is not compared" "$RC" "0"
new_home d7
for m in quantivly-1 quantivly-3; do printf '{}\n' > "$FHOME/.local/state/claude-account-dirs/$m/.claude.json"; done
run add quantivly
check "a pool with no member identity to compare against is exit 2" "$RC" "2"
want_err "...saying so"                                              "nothing to be compared with"
not_pooled "...and the seat is not pooled"

#-----------------------------------------------------------------------------
section "E. Every failed check leaves the seat OUT of the pool"
#-----------------------------------------------------------------------------
new_home e1; STUB_LOGIN_RC=1 run add quantivly
check "a failed login is exit 2"   "$RC" "2"; not_pooled "...and the seat is not pooled"

new_home e1b; STUB_LOGIN_PARTIAL=1 run add quantivly
check "a login that fails after writing its files is exit 2" "$RC" "2"
want_err "...as a failed login"                              "'clauth login quantivly-5' failed"
not_pooled "...and the seat is not pooled"

new_home e1c; STUB_LOGIN_NOSTORE=1 run add quantivly
check "a login that succeeds without a store is exit 2" "$RC" "2"
want_err "...naming the missing store"                  "does not exist"
not_pooled "...and the seat is not pooled"

new_home e2; STUB_ACCOUNT_ID=uuid-quantivly-1 run add quantivly
check "a second login to an existing account is refused" "$RC" "1"
want_err "...naming the account it repeats"             "same account as 'quantivly-1'"
not_pooled "...and the seat is not pooled"

new_home e3; STUB_AUTH_WRITES=0 STUB_LAUNCH_WRITES=1 run add quantivly
check "an identity auth status cannot give, with no --yes, is exit 2" "$RC" "2"
no_log  "...and no first launch is made unasked"                       "claude -p"
want_err "...naming the exact re-run, so the next number is not taken" "claude-seat add --yes quantivly quantivly-5"
not_pooled "...and the seat is not pooled"

new_home e4; STUB_AUTH_WRITES=0 STUB_LAUNCH_WRITES=1 run add --yes quantivly
check "with --yes, one first launch fetches it" "$RC" "0"
want_log "...through claude -p"                 "claude -p"

new_home e5; STUB_ORG=org-2 run add quantivly
check "a team seat in another organisation is refused" "$RC" "1"
want_err "...as the browser's account"                 "different organisation"
not_pooled "...and the seat is not pooled"

new_home e6; STUB_OTYPE=claude_max run add quantivly
check "an individual account in a pool of team seats is refused" "$RC" "1"
not_pooled "...and the seat is not pooled"

new_home e7; STUB_UUID=uuid-someone-else run add --yes quantivly
check "an identity naming another account than the login's is exit 2" "$RC" "2"
want_err "...saying so"                                               "names another account than the one"
not_pooled "...and the seat is not pooled"

new_home e7b; STUB_ACCOUNT_ID="" run add quantivly
check "a login that records no account id is exit 2" "$RC" "2"
want_err "...as nothing to anchor the identity to"   "recorded no account id"
not_pooled "...and the seat is not pooled"

new_home e7c; STUB_AD_CJ_BAD=1 run add --yes quantivly
check "a dir whose .claude.json is not JSON is exit 2" "$RC" "2"
no_log  "...and no launch is made into it"            "claude -p"
not_pooled "...and the seat is not pooled"

new_home e7d; STUB_AUTH_WRITES=0 STUB_AUTH_ERR="fixture: token revoked" run add quantivly
check "a failed auth status is exit 2" "$RC" "2"
want_err "...and what it said is kept"  "token revoked"

new_home e8; STUB_EMAIL=seat@example.invalid run add --email other@example.invalid quantivly
check "an address other than --email is refused" "$RC" "1"
not_pooled "...and the seat is not pooled"

new_home e9; STUB_AD_RC=1 run add quantivly
check "a failed account-dir build is exit 2" "$RC" "2"; not_pooled "...and the seat is not pooled"

new_home e9b; STUB_AD_COPY=1 run add quantivly
check "an account dir whose credential is a COPY is exit 2" "$RC" "2"
want_err "...as not a link into the store"                  "is not a link into"
not_pooled "...and the seat is not pooled"

new_home e10; printf '# a hand edit\n' >> "$REAL"
run add quantivly
check "a tenants file the editor will not commit is exit 2" "$RC" "2"
no_log  "...found before the login"                         "clauth login"
not_pooled "...and the seat is not pooled"

new_home e11; STUB_LOGIN_TOUCH_TENANTS=1 run add quantivly
check "a tenants file edited during the login is exit 2" "$RC" "2"
want_err "...as the editor's refusal"                    "did not add it"
not_pooled "...and the seat is not pooled"

new_home e12; CLAUDE_SEAT_TENANTS_EDIT="$STUBS/edit-written-then-failed" REAL_EDIT="$DOTFILES/scripts/claude-tenants-edit" \
    run add quantivly
check "an editor failure that left the edit standing is exit 3" "$RC" "3"
want_err "...saying the seat IS in the pool"                    "IS in the pool of 'quantivly'"
check "...which it is" "$(pool_of quantivly)" "quantivly-1 quantivly-3 quantivly-5"

new_home e13; STUB_PICK_LINE="quantivly-1 quantivly-3 quantivly-51" run add quantivly
check "a picker that does not list the seat is exit 3" "$RC" "3"
want_err "...not fooled by a longer name"              "the picker's dry run does not list it"

#-----------------------------------------------------------------------------
section "F. A run that stopped can be run again"
#-----------------------------------------------------------------------------
new_home f1; seat quantivly-5
run add quantivly quantivly-5
check "a seat logged in by an earlier run is resumed" "$RC" "0"
no_log "...without logging in again"                  "clauth login"
check "...and pooled"                                 "$(pool_of quantivly)" "quantivly-1 quantivly-3 quantivly-5"

new_home f2; seat quantivly-5; printf '[models]\ndefault = "sonnet"\n' > "$FHOME/.clauth/profiles/quantivly-5/config.toml"
run add quantivly quantivly-5
check "a resumed seat with settings of its own is refused" "$RC" "1"
not_pooled "...and is not pooled"

#-----------------------------------------------------------------------------
section "G. What is left for a person"
#-----------------------------------------------------------------------------
new_home g1 "$BASE
typeset -gA CLAUDE_TENANT_CONNECTORS CLAUDE_TENANT_CONNECTOR_ACCOUNT
CLAUDE_TENANT_CONNECTORS=( quantivly \"Gmail Calendar Drive\" )
CLAUDE_TENANT_CONNECTOR_ACCOUNT=( quantivly \"work@example.invalid\" )"
run add quantivly
want_out "the tenant's connectors are named"            "claude.ai connectors: Gmail Calendar Drive"
want_out "...with the Google account to choose"         "choosing work@example.invalid when Google asks"
new_home g2; run add quantivly
want_out "with none recorded, it says how to record them" "set
     CLAUDE_TENANT_CONNECTORS"
want_out "the DO-792 warning is printed"                 "DO-792"

# --- the row total -----------------------------------------------------------
EXPECTED_ROWS=136
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '  \033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))"
    FAIL=$((FAIL + 1))
fi

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
