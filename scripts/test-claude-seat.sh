#!/usr/bin/env bash
#
# scripts/test-claude-seat.sh
# ===========================
#
# State table for `scripts/claude-seat add` (DO-796): one command from a new login
# to a verified, pooled seat; and `claude-seat mcp` (DO-797), which signs a seat in
# to its pools' plugin MCP servers through `claude mcp login`; and `claude-seat
# retire` (DO-798), which takes a seat out of service without deleting anything a
# live session still holds.
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
no_out()   { if [[ "$OUT$ERR" != *"$2"* ]]; then ok "$1"; else bad "$1 — the output contains '$2'"; fi; }
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
# Never a config dir outside the fixture: this box's own is a LIVE account dir.
if [[ -z "${CLAUDE_CONFIG_DIR:-}" || "$CLAUDE_CONFIG_DIR" != "$HOME"/* ]]; then
  echo "stub claude: CLAUDE_CONFIG_DIR '${CLAUDE_CONFIG_DIR:-}' is not inside the fixture HOME" >&2
  exit 97
fi
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
# `claude mcp logout <server>`: drops that server's entries, atomically.
if [[ "${1:-}" == mcp && "${2:-}" == logout ]]; then
  srv="$3"
  if [[ " ${STUB_LOGOUT_FAIL:-} " == *" $srv "* ]]; then echo "logout failed: $srv" >&2; exit 1; fi
  f="$CLAUDE_CONFIG_DIR/.credentials.json"
  jq --arg s "$srv" '.mcpOAuth |= with_entries(select((.key | split("|")[0]) != $s))' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  exit 0
fi
# `claude mcp login [--no-browser] <server>`: the seat's own OAuth flow. It writes
# ITS OWN entry, atomically, as Claude Code does: a new file over the link.
if [[ "${1:-}" == mcp && "${2:-}" == login ]]; then
  shift 2
  [[ "${1:-}" == --no-browser ]] && shift
  srv="$1"
  if [[ " ${STUB_MCP_FAIL:-} " == *" $srv "* ]]; then echo "No MCP server found with name: $srv" >&2; exit 1; fi
  [[ " ${STUB_MCP_NOWRITE:-} " == *" $srv "* ]] && exit 0
  f="$CLAUDE_CONFIG_DIR/.credentials.json"
  jq --arg k "$srv|h-login" --arg s "$srv" \
     '.mcpOAuth[$k] = {serverName: $s, accessToken: "STUB-MCP-TOKEN", refreshToken: "r", expiresAt: 4102444800000, scope: "s"}' \
     "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
  exit 0
fi
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
# An mcpOAuth entry in a seat's store: good, discovery (never signed in) or fossil
# (a lost write blanked the token but kept its bookkeeping). Synthetic tokens.
mcp_entry() {   # $1 = seat, $2 = server, $3 = state, $4 = key suffix (another config hash)
    local f="$FHOME/.clauth/profiles/$1/credentials.json" e
    # The $s and $p in these are jq's, bound by --arg below, not the shell's.
    # shellcheck disable=SC2016
    case "$3" in
        good)      e='{serverName: $s, accessToken: ("tok-" + $p), refreshToken: "r", expiresAt: 4102444800000, scope: "s"}' ;;
        discovery) e='{serverName: $s, accessToken: ""}' ;;
        fossil)    e='{serverName: $s, accessToken: "", expiresAt: 4102444800000, scope: "s"}' ;;
        noexpiry)  e='{serverName: $s, accessToken: ("tok-" + $p), refreshToken: "r", expiresAt: "soon"}' ;;
    esac
    jq --arg k "$2|h-$1${4:-}" --arg s "$2" --arg p "$1" ".mcpOAuth[\$k] = $e" "$f" > "$f.tmp" && mv -f "$f.tmp" "$f"
}
settings_off() {   # the user settings, with the plugins named switched off
    local k body='"notion@claude-plugins-official":true'
    for k in "$@"; do body+=",\"$k\":false"; done
    mkdir -p "$FHOME/.claude"
    printf '{"enabledPlugins":{%s}}\n' "$body" > "$FHOME/.claude/settings.json"
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
    mkdir -p "$FHOME/procfix"
    printf 'WORK_TENANT = "quantivly"\nCONSOLE_SEATS = ("quantivly-3",)\n' > "$FHOME/budget.py"
}
# One fake Claude process for retire's holder scan. $1 = pid, $2 = the
# CLAUDE_CONFIG_DIR it holds ("" = none: the global file; "-" = an environment
# that cannot be read). NUL-separated, like the real thing.
mk_proc() {
    local d="$FHOME/procfix/$1"
    mkdir -p "$d"
    printf 'claude\n' > "$d/comm"
    ln -sfn "$FHOME/work/$1" "$d/cwd"
    case "${2-}" in
        -)  : ;;
        "") printf 'HOME=%s\0TERM=dumb\0' "$FHOME" > "$d/environ" ;;
        *)  printf 'HOME=%s\0CLAUDE_CONFIG_DIR=%s\0' "$FHOME" "$2" > "$d/environ" ;;
    esac
}
gitf() { GIT_CONFIG_GLOBAL="$FHOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 git "$@"; }

# OUT / ERR / RC as globals. stdin is /dev/null: never a terminal, so the
# first-launch question is never answered by accident.
run() {
    OUT="$(env -u CLAUDE_TENANTS_FILE -u CLAUDE_ACCOUNT_DIRS_ROOT -u XDG_STATE_HOME -u CLAUDE_CONFIG_DIR \
               HOME="$FHOME" STUB_LOG="$STUB_LOG" \
               CLAUDE_DOCTOR_PROC_ROOT="$FHOME/procfix" CLAUDE_SEAT_RABOTA_BUDGET="$FHOME/budget.py" \
               GIT_CONFIG_GLOBAL="$FHOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
               CLAUDE_SEAT_CLAUTH="$STUBS/clauth" CLAUDE_SEAT_CLAUDE="$STUBS/claude" \
               CLAUDE_SEAT_ACCOUNT_DIRS="$STUBS/account-dirs" CLAUDE_SEAT_PICK="$STUBS/pick" \
               zsh "$SUT" "$@" </dev/null 2>"$TMPROOT/err")"; RC=$?
    ERR="$(cat "$TMPROOT/err")"
}
# The same, under a pseudo-terminal: --no-browser needs one. script(1) joins the
# streams, so everything lands in OUT.
run_tty() {
    local cmd="zsh '$SUT'" a
    for a in "$@"; do cmd+=" '$a'"; done
    OUT="$(env -u CLAUDE_TENANTS_FILE -u CLAUDE_ACCOUNT_DIRS_ROOT -u XDG_STATE_HOME -u CLAUDE_CONFIG_DIR \
               HOME="$FHOME" STUB_LOG="$STUB_LOG" \
               CLAUDE_DOCTOR_PROC_ROOT="$FHOME/procfix" CLAUDE_SEAT_RABOTA_BUDGET="$FHOME/budget.py" \
               GIT_CONFIG_GLOBAL="$FHOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
               CLAUDE_SEAT_CLAUTH="$STUBS/clauth" CLAUDE_SEAT_CLAUDE="$STUBS/claude" \
               CLAUDE_SEAT_ACCOUNT_DIRS="$STUBS/account-dirs" CLAUDE_SEAT_PICK="$STUBS/pick" \
               script -qec "$cmd" /dev/null </dev/null 2>&1)"; RC=$?
    ERR=""
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
want_err "...by the prefix rule"                               "only a 'quantivly' seat may be named quantivly-*"
no_log   "...before any login"                                 "clauth login"

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
want_out "...starting with the mcp step"        "claude-seat mcp quantivly-5 signs it in"
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

#-----------------------------------------------------------------------------
section "H. mcp: sign a seat in to its pools' plugin MCP servers"
#-----------------------------------------------------------------------------
new_home h1
run mcp;                               check "mcp with no seat is a usage error"        "$RC" "64"
run mcp --yes quantivly-3;             check "--yes is not an mcp option"                "$RC" "64"
run add --no-browser quantivly;        check "--no-browser is not an add option"         "$RC" "64"
run mcp quantivly-3 quantivly-1;       check "mcp takes one seat"                        "$RC" "64"
run mcp ..;                            check "mcp refuses a name that is not a seat's"   "$RC" "1"

new_home h2; run mcp quantivly-4
check "a seat in no pool is refused" "$RC" "1"
want_err "...as having nothing to compare with" "is in no pool"
want_err "...without the add trailer"            "refused: 'quantivly-4'"
no_out   "...which would be false here"          "Nothing was added to the pool"

new_home h2b "${BASE/quantivly \"quantivly-1 quantivly-3\"/quantivly \"quantivly-1 quantivly-3 quantivly-2\"}"
run mcp quantivly-2
check "a compat symlink is refused as a seat" "$RC" "1"
want_err "...as another profile's dir"        "its dir is another profile's"
no_log   "...before any sign-in"              "mcp login"

new_home h3 "${BASE/quantivly \"quantivly-1 quantivly-3\"/quantivly \"quantivly-1 quantivly-3 quantivly-4\"}"
run mcp quantivly-4
check "a pooled seat with no account dir is refused" "$RC" "1"
want_err "...naming the builder, not add, which refuses a pooled name" "build it: scripts/claude-account-dirs.sh quantivly-4"

# quantivly-1 uses Slack, Notion and Linear; quantivly-3 has Notion already; the
# Linear plugin is switched off in the user settings (DO-801).
mcp_fixture() {
    mcp_entry quantivly-1 plugin:slack:slack good
    mcp_entry quantivly-1 plugin:Notion:notion good
    mcp_entry quantivly-1 plugin:linear:linear good
    mcp_entry quantivly-3 plugin:Notion:notion good
    settings_off linear@claude-plugins-official
}
new_home h4; mcp_fixture
run mcp --dry-run quantivly-3
check "a dry run passes"                           "$RC" "0"
want_out "...naming a server a sibling uses"       "plugin:slack:slack: 'quantivly-1' is signed in to it"
want_out "...and the command each would run"       "claude mcp login plugin:slack:slack"
no_out   "...not one it is signed in to already"   "plugin:Notion:notion:"
no_out   "...nor a disabled plugin's"              "plugin:linear:linear"
no_log   "...and signs in to nothing"              "mcp login"

new_home h4b; mcp_fixture; mcp_entry quantivly-3 plugin:linear:linear fossil
run mcp --dry-run quantivly-3
no_out "a damaged entry of a disabled plugin is not re-authorised" "plugin:linear:linear"

new_home h5; mcp_fixture
run mcp quantivly-3
check "a seat is signed in to what its pool uses" "$RC" "0"
want_log "...through claude mcp login"            "claude mcp login plugin:slack:slack"
no_log   "...and nothing else"                    "mcp login plugin:linear"
want_out "...checked afterwards"                  "✓ plugin:slack:slack"
check    "...with an entry of its own, not a copy of the sibling's" \
         "$(jq -r '.mcpOAuth["plugin:slack:slack|h-login"].accessToken // "none"' "$FHOME/.local/state/claude-account-dirs/quantivly-3/.credentials.json")" \
         "STUB-MCP-TOKEN"
no_out   "...and no token is printed"             "STUB-MCP-TOKEN"
no_out   "...not even the sibling's"              "tok-quantivly-1"

new_home h6; mcp_fixture; mcp_entry quantivly-3 plugin:github:github fossil
run mcp --dry-run quantivly-3
want_out "a damaged entry of its own is re-authorised, used by a sibling or not" "plugin:github:github: its own entry is damaged"
new_home h6c; mcp_fixture; mcp_entry quantivly-3 plugin:Notion:notion fossil -old
run mcp quantivly-3
check "a damaged entry beside a good one is not signed in again" "$RC" "0"
no_log   "...for that server"                                    "mcp login plugin:Notion"
want_out "...but reported"                                       "plugin:Notion:notion: signed in, beside an older entry that is damaged"

new_home h6d; mcp_fixture; mcp_entry quantivly-3 plugin:slack:slack noexpiry
run mcp --dry-run quantivly-3
want_out "an entry with no usable expiry, and nothing good, is signed in again" "plugin:slack:slack: its own entry has no usable expiry"

new_home h6b; mcp_fixture; mcp_entry quantivly-3 plugin:Notion:notion discovery -old
mcp_entry quantivly-1 plugin:figma:figma discovery; mcp_entry quantivly-3 plugin:figma:figma discovery
run mcp --dry-run quantivly-3
check    "a seat with discovery records still dry-runs"     "$RC" "0"
no_out   "a discovery record is not damage"                 "plugin:figma:figma"
no_out   "...nor does it hide a good entry beside it"       "plugin:Notion:notion:"

new_home h7; mcp_fixture; STUB_MCP_FAIL="plugin:slack:slack" run mcp quantivly-3
check "a sign-in that fails is exit 2"            "$RC" "2"
want_err "...naming the server"                   "still not signed in to plugin:slack:slack"
want_err "...with the /mcp steps instead"         "claude-as quantivly-3, then /mcp"

new_home h8; mcp_fixture; STUB_MCP_NOWRITE="plugin:slack:slack" run mcp quantivly-3
check "a sign-in that exits 0 but writes nothing is exit 2" "$RC" "2"
want_out "...as not signed in"                              "✗ plugin:slack:slack"

new_home h9; mcp_fixture; mcp_entry quantivly-1 plugin:asana:asana good
STUB_MCP_FAIL="plugin:asana:asana" run mcp quantivly-3
check "one failed sign-in does not stop the next" "$RC" "2"
want_log "...which is still made"                 "claude mcp login plugin:slack:slack"
want_out "...and succeeds"                        "✓ plugin:slack:slack"

new_home h10; mcp_fixture; mcp_entry quantivly-3 plugin:slack:slack good
run mcp quantivly-3
check "a seat already signed in to everything is exit 0" "$RC" "0"
want_out "...saying there is nothing to do"              "nothing to do"
no_log   "...and signing in to nothing"                  "mcp login"

new_home h11; mcp_fixture; printf 'not json\n' > "$FHOME/.clauth/profiles/quantivly-1/credentials.json"
run mcp quantivly-3
check "a sibling's unreadable sign-ins are exit 2" "$RC" "2"
want_err "...naming it"                            "cannot read the MCP sign-ins of 'quantivly-1'"
no_log   "...before any sign-in"                   "mcp login"

new_home h12; mcp_fixture; printf 'null\n' > "$FHOME/.clauth/profiles/quantivly-3/credentials.json"
run mcp quantivly-3
check "the seat's own unreadable sign-ins are exit 2" "$RC" "2"
want_err "...naming it"                               "of 'quantivly-3' itself"

new_home h13; mcp_fixture
run mcp --no-browser quantivly-3
check "--no-browser with no terminal is refused" "$RC" "1"
no_log   "...before any sign-in"                 "mcp login"
run mcp --dry-run --no-browser quantivly-3
check "...but a dry run needs none"              "$RC" "0"
want_out "...and its plan carries the flag"      "claude mcp login --no-browser plugin:slack:slack"
new_home h13b; mcp_fixture
run_tty mcp --no-browser quantivly-3
check "--no-browser in a terminal signs in"      "$RC" "0"
want_log "...passing the flag to claude"         "claude mcp login --no-browser plugin:slack:slack"

new_home h14 "$BASE
CLAUDE_TENANT_POOL+=( lab \"personal-0 quantivly-3\" )"
mcp_fixture; mcp_entry personal-0 plugin:asana:asana good
run mcp --dry-run quantivly-3
want_out "a seat in two pools needs what either pool uses" "plugin:asana:asana: 'personal-0' is signed in to it"
want_out "...and the other pool's too"                    "plugin:slack:slack: 'quantivly-1'"

new_home h16 "${BASE/quantivly \"quantivly-1 quantivly-3\"/quantivly \"quantivly-1 quantivly-3 quantivly-7\"}"
mcp_fixture
run mcp --dry-run quantivly-3
check "a pool member with no profile is skipped, not read" "$RC" "0"
want_out "...and the others still count"                   "plugin:slack:slack: 'quantivly-1'"
run mcp quantivly-7
check "a pooled seat with no profile store is refused"     "$RC" "1"
want_err "...with the doctor's remedy, not add's"          "'clauth login quantivly-7' if it should exist, otherwise take it out of the pool (claude-tenants-edit --commit pool-remove quantivly quantivly-7)"

new_home h17; mcp_fixture; printf '{"enabledPlugins": [' > "$FHOME/.claude/settings.json"
run mcp quantivly-3
check "an unreadable settings file is exit 2, not 'nothing disabled'" "$RC" "2"
want_err "...naming it"                                                "cannot read which plugins are enabled"
no_log   "...before any sign-in"                                       "mcp login"

new_home h18 "${BASE/quantivly \"quantivly-1 quantivly-3\"/quantivly \"quantivly-1 quantivly-3 quantivly-0.retired-20260917\"}"
mcp_fixture; seat quantivly-0.retired-20260917; mcp_entry quantivly-0.retired-20260917 plugin:asana:asana good
run mcp --dry-run quantivly-3
no_out "a retired member's sign-ins are not expected" "plugin:asana:asana"

new_home h15; mcp_fixture; settings_off linear@claude-plugins-official slack@claude-plugins-official
run mcp --dry-run quantivly-3
check "with Slack disabled too, nothing is left to do" "$RC" "0"
want_out "...and it says so"                           "nothing to do"

#-----------------------------------------------------------------------------
section "I. retire: out of service, nothing deleted while it is held"
#-----------------------------------------------------------------------------
# quantivly-5 is a seat that can be retired: pooled with two others, rabota and
# the ownership tables name it nowhere.
R5="${BASE/quantivly \"quantivly-1 quantivly-3\"/quantivly \"quantivly-1 quantivly-3 quantivly-5\"}"
retire_fixture() {
    seat quantivly-5 claude_team org-1
    mcp_entry quantivly-5 plugin:slack:slack good
    mcp_entry quantivly-5 plugin:Notion:notion discovery
}
TODAY="$(date +%Y%m%d)"
retired_of() {
    zsh -f -c 'typeset -gA CLAUDE_TENANT_RETIRED; source "$1" >/dev/null 2>&1; print -r -- "${CLAUDE_TENANT_RETIRED[$2]-<none>}"' _ "$REAL" "$1"
}

new_home i1
run retire;                            check "retire with no seat is a usage error"     "$RC" "64"
run retire --yes quantivly-5;          check "--yes is not a retire option"             "$RC" "64"
run add --plan quantivly;              check "--plan is not an add option"              "$RC" "64"
run retire --reason;                   check "--reason with no text is a usage error"   "$RC" "64"

new_home i2 "$R5"; retire_fixture
run retire --plan quantivly-5
check "a plan passes"                              "$RC" "0"
want_out "...listing its pools"                    "pools:          quantivly"
want_out "...and its account dir"                  "account dir:    "
check "...and changes no pool"                     "$(pool_of quantivly)" "quantivly-1 quantivly-3 quantivly-5"
check "...no account dir"                          "$([[ -d "$FHOME/.local/state/claude-account-dirs/quantivly-5" ]] && echo kept)" "kept"
check "...and no commit"                           "$(gitf -C "$FHOME/repo" log -1 --format=%s)" "init"
no_log "...and calls nothing"                      "mcp logout"

new_home i3; run retire quantivly-1
check "rabota's local seat is refused"             "$RC" "1"
want_err "...naming where"                         "rabota's seat in quantivly.toml"
check "...and its pool is untouched"               "$(pool_of quantivly)" "quantivly-1 quantivly-3"
new_home i4; run retire quantivly-3
check "rabota's console seat is refused"           "$RC" "1"
want_err "...naming CONSOLE_SEATS"                 "CONSOLE_SEATS in"
new_home i5; run retire quantivly-4
check "a seat another machine bills is refused"    "$RC" "1"
want_err "...naming the ownership table"           "CLAUDE_TENANT_MACHINE_OWNED"
new_home i6 "$R5
typeset -gA CLAUDE_TENANT_OVERFLOW
CLAUDE_TENANT_OVERFLOW=( personal \"quantivly-5\" )"; retire_fixture
run retire quantivly-5
check "a seat an overflow names is refused"        "$RC" "1"
want_err "...naming it"                            "CLAUDE_TENANT_OVERFLOW for 'personal'"
check "...before its pool is touched"              "$(pool_of quantivly)" "quantivly-1 quantivly-3 quantivly-5"

new_home i7 "$R5"; retire_fixture
run retire quantivly-5
check "a seat no session holds is retired"         "$RC" "0"
check "...out of its pool"                         "$(pool_of quantivly)" "quantivly-1 quantivly-3"
want_log "...its plugin sign-ins logged out"       "claude mcp logout plugin:slack:slack"
no_log   "...but not a discovery record"           "mcp logout plugin:Notion"
check "...its account dir a tombstone"             "$([[ -d "$FHOME/.local/state/claude-account-dirs/quantivly-5.retired-$TODAY" && ! -e "$FHOME/.local/state/claude-account-dirs/quantivly-5" ]] && echo yes)" "yes"
check "...its name recorded"                       "$(retired_of quantivly-5)" "retired $(date +%F) with claude-seat"
check "...in two commits of the tenants file"      "$(gitf -C "$FHOME/repo" log -2 --format=%s | tr '\n' '|')" "tenants: retire-name quantivly-5 (retired $(date +%F) with claude-seat)|tenants: pool-remove quantivly quantivly-5|"
want_out "...with clauth delete left for a person" "clauth delete quantivly-5 -y"
no_log   "...which it does not run"                "clauth delete"
want_out "...and the service grants to revoke"     "Revoke its app grants at each service (plugin:slack:slack)"
run retire quantivly-5
check "retiring it again is exit 0"                "$RC" "0"
want_out "...saying it is done"                    "already retired"

new_home i8 "$R5"; retire_fixture; mk_proc 201 "$FHOME/.local/state/claude-account-dirs/quantivly-5"
run retire quantivly-5
check "a seat a session holds is exit 3"           "$RC" "3"
check "...taken out of its pool"                   "$(pool_of quantivly)" "quantivly-1 quantivly-3"
check "...but its account dir is kept"             "$([[ -d "$FHOME/.local/state/claude-account-dirs/quantivly-5" ]] && echo kept)" "kept"
check "...and its name not yet recorded"           "$(retired_of quantivly-5)" "<none>"
no_log   "...nor logged out"                       "mcp logout"
want_out "...printing how to move the session"     "pid 201 (~/work/201): /exit in it, then claude-as quantivly-1 --resume"
rm -rf "$FHOME/procfix/201"
run retire quantivly-5
check "once it has moved, running again retires it" "$RC" "0"
check "...tombstoned"                              "$([[ -d "$FHOME/.local/state/claude-account-dirs/quantivly-5.retired-$TODAY" ]] && echo yes)" "yes"

new_home i9 "$R5"; retire_fixture
mkdir -p "$FHOME/.clauth/profiles/quantivly-5/runtime-202-0"
ln -s "$FHOME/.clauth/profiles/quantivly-5/credentials.json" "$FHOME/.clauth/profiles/quantivly-5/runtime-202-0/.credentials.json"
mk_proc 202 "$FHOME/.clauth/profiles/quantivly-5/runtime-202-0"
run retire quantivly-5
check "a clauth session on it is exit 3"           "$RC" "3"
want_out "...named by its sid, with the move"      "clauth switch 202-0 quantivly-1"

new_home i10 "$R5"; retire_fixture
mkdir -p "$FHOME/.clauth/profiles/quantivly-5/runtime-203-0"
ln -s "$FHOME/.clauth/profiles/quantivly-1/credentials.json" "$FHOME/.clauth/profiles/quantivly-5/runtime-203-0/.credentials.json"
mk_proc 203 "$FHOME/.clauth/profiles/quantivly-5/runtime-203-0"
run retire quantivly-5
check "a session started on it but moved to another seat does not hold it" "$RC" "0"

new_home i11 "$R5"; retire_fixture; mk_proc 204 -
run retire quantivly-5
check "an unreadable Claude process is exit 3"     "$RC" "3"
want_out "...as one it cannot tell about"          "cannot tell whether they hold it"
check "...and nothing is deleted"                  "$([[ -d "$FHOME/.local/state/claude-account-dirs/quantivly-5" ]] && echo kept)" "kept"

new_home i12 "$R5"; retire_fixture; mk_proc 205 ""
printf 'active_profile = "quantivly-5"\n' > "$FHOME/.clauth/profiles.toml"
run retire quantivly-5
check "a session on the global file, when that is the seat, is exit 3" "$RC" "3"
want_out "...saying so"                                                "on the global file, which is 'quantivly-5'"
new_home i12b "$R5"; retire_fixture; mk_proc 206 ""
printf 'active_profile = "quantivly-1"\n' > "$FHOME/.clauth/profiles.toml"
run retire quantivly-5
check "...but not when the global file is another seat"                "$RC" "0"

new_home i13; run retire quantivly-9
check "a name nothing knows is refused"            "$RC" "1"
want_err "...as no seat"                           "there is no seat called 'quantivly-9'"
new_home i14; run retire quantivly-2
check "a compat symlink is refused"                "$RC" "1"
want_err "...as not a seat"                        "a compat symlink in the account root"

new_home i15 "$R5"; retire_fixture; mkdir -p "$FHOME/.local/state/claude-account-dirs/quantivly-5.retired-$TODAY"
run retire quantivly-5
check "an existing tombstone of the same day is exit 2" "$RC" "2"
check "...and the account dir is kept"                  "$([[ -d "$FHOME/.local/state/claude-account-dirs/quantivly-5" ]] && echo kept)" "kept"

new_home i16; run retire personal-0
check "a seat whose pool it would empty is refused" "$RC" "1"
want_err "...by the editor"                         "would not take 'personal-0' out of 'personal'"
check "...and its account dir is kept"              "$([[ -d "$FHOME/.local/state/claude-account-dirs/personal-0" ]] && echo kept)" "kept"

new_home i17 "$R5"; retire_fixture; STUB_LOGOUT_FAIL="plugin:slack:slack" run retire quantivly-5
check "a failed logout still retires"               "$RC" "0"
want_out "...saying so"                             "✗ plugin:slack:slack: 'claude mcp logout' failed"

new_home i18 "$R5"; retire_fixture; rm -f "$FHOME/budget.py"
run retire quantivly-5
check "an unreadable budget.py is exit 2"           "$RC" "2"
want_err "...naming it"                             "whose CONSOLE_SEATS may name the seat"
new_home i18b "$R5"; retire_fixture; printf 'WORK_TENANT = "quantivly"\n' > "$FHOME/budget.py"
run retire quantivly-5
check "a budget.py without CONSOLE_SEATS is exit 2" "$RC" "2"

new_home i19 "$R5"; retire_fixture; printf '# a hand edit\n' >> "$REAL"
run retire quantivly-5
check "a dirty tenants file is exit 2"              "$RC" "2"
check "...before its pool is touched"               "$(grep -c 'quantivly-5' "$REAL")" "1"

new_home i20 "$R5"; retire_fixture
run retire --reason "handed over" quantivly-5
check "--reason is what the table records"          "$(retired_of quantivly-5)" "handed over"

new_home i21 "$R5"; retire_fixture; rm -f "$FHOME/.clauth/profiles/quantivly-5/credentials.json"
run retire quantivly-5
check "a seat whose profile is already deleted is still retired" "$RC" "0"
no_out "...without asking for clauth delete"                     "clauth delete quantivly-5"

# --- the row total -----------------------------------------------------------
EXPECTED_ROWS=278
if (( PASS + FAIL != EXPECTED_ROWS )); then
    printf '  \033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
        "$EXPECTED_ROWS" "$((PASS + FAIL))"
    FAIL=$((FAIL + 1))
fi

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
