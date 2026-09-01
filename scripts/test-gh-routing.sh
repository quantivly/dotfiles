#!/usr/bin/env bash
#
# scripts/test-gh-routing.sh
# ==========================
#
# State table for the GitHub account routing and diagnosis in
# zsh/functions/github.sh (_gh_url_owner, _gh_repo_remotes, _gh_route_for,
# _gh_configured_dirs, _gh_active_config_dir, _gh_token_source, _gh_run_prefix,
# _gh_config_dir_user, _gh_probe_login, _gh_user_token, gh-doctor).
#
# Why this exists: `gh` stores its tokens in the system keyring keyed by HOST,
# not by config dir, so three config dirs declaring three different accounts can
# all resolve to one — and `gh auth status` keeps reporting the DECLARED one.
# The failure is silent, and on this machine it silently selected the WORK
# account in personal repositories. gh-doctor's whole job is to notice that, so
# a gh-doctor that reports agreement when there is none is worse than no
# gh-doctor at all. Every row below is therefore a state that produces a green
# tick somewhere if the code is wrong.
#
# The rows that already caught something, kept as named rows:
#   - `env VAR=x some_shell_function` cannot work (env execs a binary), and the
#     probe reported the resulting "No such file or directory" as an
#     unresolvable GitHub account.
#   - `env GH_TOKEN=x -u GITHUB_TOKEN gh ...` runs a program called `-u`: env
#     stops parsing options at the first operand. Same disguise — it surfaced as
#     a fact about GitHub rather than about the command line.
#   - zsh's `local NAME` on a name already local in that scope PRINTS it, so a
#     `local du` inside a loop emitted `du=zvi-quantivly` into the report.
#   - `${~pat}` enables tilde expansion as well as globbing, so a route pattern
#     starting with `~` aborted the lookup and took every later route with it.
#   - a route whose config dir does not exist can never fire; reporting it only
#     when it happens to match means the fault first appears on the day the
#     route was finally needed.
#
# gh itself is STUBBED (bin/gh below), deliberately: the stub reproduces the
# keyring collapse exactly, which no CI runner's real gh can be made to do, and
# it keeps the suite hermetic — no network, no credentials, no keyring, no
# GitHub account. The stub models gh's contract; the pure parsing functions are
# exercised against real strings and real git repositories.
#
# Requires: zsh, git. No sudo, no network, no gh, no real config dirs.
#
# Usage: scripts/test-gh-routing.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEM_SH="$DOTFILES/zsh/functions/system.sh"
GITHUB_SH="$DOTFILES/zsh/functions/github.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

missing=()
for tool in zsh git; do command -v "$tool" >/dev/null || missing+=("$tool"); done
(( ${#missing[@]} == 0 )) || fatal "missing required tool(s): ${missing[*]}"
[[ -r "$GITHUB_SH" ]] || fatal "cannot read $GITHUB_SH"
[[ -r "$SYSTEM_SH" ]] || fatal "cannot read $SYSTEM_SH"

# Assert the code under test loads and defines what is about to be asserted
# about. Most rows below are "the report said X"; a module that failed to source
# produces no report at all, which greps to zero just as convincingly.
for fn in _gh_url_owner _gh_repo_remotes _gh_route_for _gh_configured_dirs \
          _gh_run_prefix _gh_config_dir_user _gh_probe_login _gh_user_token gh-doctor; do
  zsh -c "source '$SYSTEM_SH'; source '$GITHUB_SH'; (( \$+functions[$fn] ))" \
    || fatal "sourcing $GITHUB_SH did not define $fn"
done

# -----------------------------------------------------------------------------
# The gh stub
# -----------------------------------------------------------------------------
# Reproduces the three behaviours the doctor reasons about:
#   config get -h HOST user  -> reads $GH_CONFIG_DIR/hosts.yml (no credential)
#   api user --jq .login     -> a *token* decides the account; with no token the
#                               keyring answers by HOST and IGNORES the config
#                               dir. That last clause is the defect.
#   auth token --user LOGIN  -> the per-user keyring entry, which does isolate
# Knobs: GH_STUB_KEYRING_LOGIN (the shared default), GH_STUB_FAIL (API failure),
#        GH_STUB_NO_TOKEN_FOR (space-separated logins with no per-user entry).
STUBBIN="$TMPROOT/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
sub="${1:-} ${2:-}"
case "$sub" in
  "config get")
    shift 2; key=""
    while [ $# -gt 0 ]; do
      case "$1" in -h) shift 2 ;; *) key="$1"; shift ;; esac
    done
    [ "$key" = "user" ] || { echo "unsupported key" >&2; exit 1; }
    f="${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml"
    v=""
    [ -f "$f" ] && v="$(awk '/^[[:space:]]+user:[[:space:]]/ {print $2; exit}' "$f")"
    [ -n "$v" ] || { echo 'could not find key "user"' >&2; exit 1; }
    printf '%s\n' "$v" ;;
  "api user")
    [ -n "${GH_STUB_FAIL:-}" ] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    if [ -n "${GH_TOKEN:-}" ]; then
      case "$GH_TOKEN" in
        tok-*) printf '%s\n' "${GH_TOKEN#tok-}"; exit 0 ;;
      esac
    fi
    # No token (or an unrecognised one): the shared, host-keyed default.
    printf '%s\n' "${GH_STUB_KEYRING_LOGIN:-nobody}" ;;
  "auth token")
    shift 2; u=""
    while [ $# -gt 0 ]; do
      case "$1" in --user) u="${2:-}"; shift 2 ;; *) shift ;; esac
    done
    [ -n "$u" ] || exit 1
    case " ${GH_STUB_NO_TOKEN_FOR:-} " in *" $u "*) exit 1 ;; esac
    printf 'tok-%s\n' "$u" ;;
  *) echo "stub gh: unsupported: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUBBIN/gh"

mkcfg() {  # mkcfg <name> [declared-user]   -> prints the dir
  local d="$TMPROOT/cfg/$1"
  mkdir -p "$d"
  if [[ -n "${2:-}" ]]; then
    printf 'github.com:\n    git_protocol: ssh\n    users:\n        %s:\n    user: %s\n' "$2" "$2" > "$d/hosts.yml"
  fi
  printf '%s' "$d"
}
CFG_WORK="$(mkcfg work    worky)"
CFG_PERS="$(mkcfg personal persony)"
CFG_BARE="$(mkcfg bare)"          # exists, declares nobody

mkrepo() {  # mkrepo <name> [name=url ...]  -> prints the dir
  local d="$TMPROOT/repo/$1"; shift
  mkdir -p "$d"; git -C "$d" init -q
  local spec
  for spec in "$@"; do git -C "$d" remote add "${spec%%=*}" "${spec#*=}"; done
  printf '%s' "$d"
}
R_WORK="$(mkrepo work     "origin=git@github.com:acme/platform.git")"
R_PERS="$(mkrepo personal "origin=git@github.com:someone/blog.git")"
R_FORK="$(mkrepo fork     "origin=git@github.com:someone/platform.git" "upstream=https://github.com/acme/platform.git")"
R_NONE="$(mkrepo bare)"
NOTREPO="$TMPROOT/plain"; mkdir -p "$NOTREPO"

# Run a snippet with both modules sourced and the stub gh first on PATH.
#
# HOME and XDG_CONFIG_HOME are fixtures. Without that the doctor probes the
# developer's REAL ~/.config/gh, whose declared account and keyring state are
# whatever that machine happens to be in — which made two rows pass or fail by
# location. A suite about a machine-state bug must not read machine state.
FAKEHOME="$TMPROOT/home"; mkdir -p "$FAKEHOME/.config"
# The fixture HOME needs a git identity: the doctor reports a missing user.email
# as a ✗ (correctly — commits from there would be misattributed), which would
# otherwise make the "healthy machine" row impossible to reach.
printf '[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n' > "$FAKEHOME/.gitconfig"
zrun() {
  PATH="$STUBBIN:$PATH" HOME="$FAKEHOME" XDG_CONFIG_HOME="$FAKEHOME/.config" zsh -c "
    source '$SYSTEM_SH'; source '$GITHUB_SH'
    GH_ACCOUNT_ROUTES=( 'acme=$CFG_WORK' )
    GH_ACCOUNT_DEFAULT_DIR='$CFG_PERS'
    unset GH_TOKEN GITHUB_TOKEN GH_CONFIG_DIR
    $1" 2>&1
}

echo
echo "=== _gh_url_owner: every remote form git accepts ==="
owner() { zrun "_gh_url_owner ${1:+\"$1\"}; print -r -- \$_GH_URL_STATE"; }
check "scp-like ssh"            "$(owner 'git@github.com:acme/p.git')"          "owner acme"
check "scp-like, no user"       "$(owner 'github.com:acme/p')"                  "owner acme"
check "host alias (github-work)" "$(owner 'git@github-work:acme/p.git')"        "owner acme"
check "ssh:// with user"        "$(owner 'ssh://git@github.com/acme/p.git')"    "owner acme"
check "ssh:// with port"        "$(owner 'ssh://git@github.com:22/acme/p')"     "owner acme"
check "ssh.github.com:443"      "$(owner 'ssh://git@ssh.github.com:443/acme/p')" "owner acme"
check "https"                   "$(owner 'https://github.com/acme/p.git')"      "owner acme"
check "https with userinfo"     "$(owner 'https://u:tok@github.com/acme/p')"    "owner acme"
check "git://"                  "$(owner 'git://github.com/acme/p.git')"        "owner acme"
check "owner case is preserved" "$(owner 'git@github.com:AcMe/p.git')"          "owner AcMe"
# Everything below must NOT come back as an owner. An over-eager parser hands a
# non-GitHub remote to a route and picks an account for it.
check "another forge"           "$(owner 'git@gitlab.com:acme/p.git')"          "not-github"
check "GitHub Enterprise host"  "$(owner 'git@github.example.com:acme/p.git')"  "not-github"
check "a local path"            "$(owner '/srv/git/p.git')"                     "not-github"
check "host but no owner/repo"  "$(owner 'https://github.com/acme')"            "unparsable"
check "empty url"               "$(owner '')"                                   "unparsable"

echo
echo "=== _gh_repo_remotes: ALL remotes, like hasconfig — not just origin ==="
rem() { zrun "_gh_repo_remotes '$1'; print -r -- \"\$_GH_REMOTE_STATE:\${(j:,:)_GH_REMOTE_OWNERS}\""; }
check "single origin"        "$(rem "$R_WORK")" "ok:acme"
check "fork: origin+upstream" "$(rem "$R_FORK")" "ok:someone,acme"
check "repo with no remotes"  "$(rem "$R_NONE")" "no-remotes:"
check "not a repository"      "$(rem "$NOTREPO")" "no-repo:"
# Its own fixture: adding a remote to R_NONE would silently retitle the
# "repo with no remotes" row above into something else.
R_GL="$(mkrepo gitlab "gl=git@gitlab.com:a/b.git")"
check "a non-GitHub remote keeps its slot" \
      "$(zrun "_gh_repo_remotes '$R_GL'; print -r -- \"\$_GH_REMOTE_STATE:[\${(j:,:)_GH_REMOTE_OWNERS}]\"")" \
      "ok:[]"

echo
echo "=== _gh_route_for: which config dir the remote selects ==="
route() {  # route <dir> [table-entry ...]   (default: the one work route)
  local dir="$1"; shift
  local tbl="'acme=$CFG_WORK'"
  (( $# )) && tbl="$(printf "'%s' " "$@")"
  zrun "GH_ACCOUNT_ROUTES=( $tbl ); _gh_route_for '$dir'
        print -r -- \"\$_GH_ROUTE_STATE:\${_GH_ROUTE_DIR:t}\""
}
check "work remote matches"      "$(route "$R_WORK")" "matched:work"
check "personal falls to default" "$(route "$R_PERS")" "default:personal"
# `$HOME` is the normal resting state of a shell, not a fault: with a default
# configured, no repo and no remotes take it, so the account is still PINNED
# explicitly and the keyring never decides. Warning on every `cd` into a
# non-repo directory is how a warning stops being read.
check "no repo takes the default"    "$(route "$NOTREPO")" "default:personal"
check "no remotes takes the default" "$(route "$R_NONE")"  "default:personal"
# The fork case is the reason ALL remotes are consulted: origin is the personal
# fork, upstream is the work repo, and git identity (hasconfig:remote.*.url)
# already routes it to work. Matching origin only would split the two.
check "fork routes on upstream"  "$(route "$R_FORK")" "matched:work"
# ...and with NO default there is genuinely nothing to go on. Each flavour keeps
# its own state, because "add a route" and "you are not in a repository" are
# different fixes.
nodef() { zrun "GH_ACCOUNT_DEFAULT_DIR=''; _gh_route_for '$1'
                print -r -- \"\$_GH_ROUTE_STATE:\${_GH_ROUTE_DIR:t}\""; }
check "no remotes, no default"   "$(nodef "$R_NONE")"  "no-remotes:"
check "not a repo, no default"   "$(nodef "$NOTREPO")" "no-repo:"
check "unmatched, no default"    "$(nodef "$R_PERS")"  "none:"
# Remotes exist but none is GitHub: nothing to route on, so the default — not a
# guess drawn from the one non-GitHub remote.
check "only a non-GitHub remote"  "$(route "$R_GL")" "default:personal"
check "and with no default, 'none'" "$(nodef "$R_GL")" "none:"
check "owner match is case-insensitive" \
      "$(zrun "cd '$TMPROOT'; d=\$(mktemp -d); git -C \$d init -q
               git -C \$d remote add origin git@github.com:AcMe/p.git
               _gh_route_for \$d; print -r -- \$_GH_ROUTE_STATE")" "matched"
check "glob pattern"             "$(route "$R_WORK" "ac*=$CFG_WORK")" "matched:work"
check "first matching route wins" \
      "$(route "$R_WORK" "acme=$CFG_PERS" "acme=$CFG_WORK")" "matched:personal"
# An unusable table must not select nothing and let that read as "personal".
check "entry without ="          "$(route "$R_WORK" "acme")"          "bad-table:"
check "entry with empty pattern" "$(route "$R_WORK" "=$CFG_WORK")"    "bad-table:"
check "entry with empty dir"     "$(route "$R_WORK" "acme=")"         "bad-table:"
# ${~pat} does tilde expansion too, so this used to abort the whole lookup.
check "pattern starting with ~"  "$(route "$R_WORK" "~acme=$CFG_WORK")" "bad-table:"
check "pattern with a slash"     "$(route "$R_WORK" "ac/me=$CFG_WORK")" "bad-table:"
check "a later bad entry is not masked by an earlier match" \
      "$(route "$R_WORK" "acme=$CFG_WORK" "oops")" "bad-table:"
check "~ in the config dir expands" \
      "$(zrun "GH_ACCOUNT_ROUTES=( 'acme=~/somecfg' ); _gh_route_for '$R_WORK'
               print -r -- \"\${_GH_ROUTE_DIR#\$HOME/}\"")" "somecfg"
check "empty table and no default is 'none', not a guess" \
      "$(zrun "GH_ACCOUNT_ROUTES=(); GH_ACCOUNT_DEFAULT_DIR=''
               _gh_route_for '$R_PERS'; print -r -- \$_GH_ROUTE_STATE")" "none"
check "~ in GH_ACCOUNT_DEFAULT_DIR expands" \
      "$(zrun "GH_ACCOUNT_ROUTES=(); GH_ACCOUNT_DEFAULT_DIR='~/defcfg'
               _gh_route_for '$R_PERS'; print -r -- \"\${_GH_ROUTE_DIR#\$HOME/}\"")" "defcfg"

echo
echo "=== what gh will use right now ==="
check "GH_CONFIG_DIR wins"   "$(zrun "GH_CONFIG_DIR=/x _gh_active_config_dir")"                "/x"
check "else XDG_CONFIG_HOME" "$(zrun "XDG_CONFIG_HOME=/xdg _gh_active_config_dir")"            "/xdg/gh"
check "else \$HOME/.config/gh" "$(zrun "unset XDG_CONFIG_HOME; _gh_active_config_dir")" "$FAKEHOME/.config/gh"
src() { zrun "$1 _gh_token_source; print -r -- \$_GH_TOKEN_SOURCE"; }
check "GH_TOKEN first"       "$(src 'GH_TOKEN=a GITHUB_TOKEN=b')" "GH_TOKEN"
check "then GITHUB_TOKEN"    "$(src 'GITHUB_TOKEN=b')"            "GITHUB_TOKEN"
check "else the config dir"  "$(src '')"                          "config-dir"
# An empty GH_TOKEN is not a pinned account — gh ignores it and falls through.
check "empty GH_TOKEN is not a pin" "$(src 'GH_TOKEN=')"          "config-dir"

echo
echo "=== _gh_run_prefix: env's argv, which twice looked like a GitHub fault ==="
# `env` execs a binary, so a shell function can never follow it, and it stops
# parsing options at the first operand, so every -u must precede every VAR=val.
pre() { zrun "local -a _GH_RUN; _gh_run_prefix 7 $1; print -r -- \"\${_GH_RUN[*]}\""; }
check "unsets are hoisted above assignments" \
      "$(pre '"GH_TOKEN=x" -u GITHUB_TOKEN "GH_CONFIG_DIR=/d"' | sed 's/ timeout 7//')" \
      "command env -u GITHUB_TOKEN GH_TOKEN=x GH_CONFIG_DIR=/d"
check "no shell word after env" \
      "$(pre '-u GH_TOKEN' | tr ' ' '\n' | grep -c '^command$')" "1"
check "the run is time-bounded" \
      "$(pre '-u GH_TOKEN' | grep -c 'timeout 7')" "1"

echo
echo "=== _gh_config_dir_user: what a config dir DECLARES (no credential) ==="
decl() { zrun "_gh_config_dir_user '$1' || print -r -- '(none)'"; }
check "reads hosts.yml"        "$(decl "$CFG_WORK")" "worky"
check "the other dir"          "$(decl "$CFG_PERS")" "persony"
check "dir with no user"       "$(decl "$CFG_BARE")" "(none)"
check "dir that does not exist" "$(decl "$TMPROOT/nope")" "(none)"

echo
echo "=== _gh_probe_login: an unanswered question is NEVER agreement ==="
probe() { zrun "$2 _gh_probe_login '${1:-}' '${3:--}' && print -r -- \"login=\$_GH_PROBE_LOGIN\" || print -r -- \"fail=\$_GH_PROBE_ERR\""; }
check "a token pins the account" \
      "$(probe "$CFG_PERS" 'GH_STUB_KEYRING_LOGIN=worky' 'tok-persony')" "login=persony"
check "no token: the keyring answers, ignoring the dir" \
      "$(probe "$CFG_PERS" 'GH_STUB_KEYRING_LOGIN=worky' '')" "login=worky"
check "an API failure is a failure, not a login" \
      "$(probe "$CFG_PERS" 'GH_STUB_FAIL=1' '')" "fail=HTTP 401: Bad credentials"
check "a missing gh is a failure, not a login" \
      "$(zsh -c "source '$SYSTEM_SH'; source '$GITHUB_SH'; PATH=/nonexistent
                 _gh_probe_login '' '' || print -r -- \"fail=\$_GH_PROBE_ERR\"" 2>&1)" \
      "fail=gh is not installed"
check "_gh_user_token: per-user entry" \
      "$(zrun "_gh_user_token '$CFG_PERS' persony")" "tok-persony"
check "_gh_user_token: no entry is a failure" \
      "$(zrun "GH_STUB_NO_TOKEN_FOR=persony _gh_user_token '$CFG_PERS' persony || print -r -- '(none)'")" "(none)"

echo
echo "=== gh-doctor: the defect it exists to catch ==="
# The live state on the machine this was written for: the keyring hands out the
# WORK account no matter which config dir is selected, and `gh auth status`
# keeps reporting the declared one.
doctor() { zrun "$2 gh-doctor $1; print -r -- \"rc=\$?\""; }
COLLAPSE="GH_STUB_KEYRING_LOGIN=worky"

out="$(doctor "'$R_PERS'" "$COLLAPSE")"
check "personal repo: the wrong account is named" \
      "$(printf '%s\n' "$out" | grep -c "routes to 'persony', but gh is 'worky'")" "1"
check "personal repo: and it fails"      "$(printf '%s\n' "$out" | grep -c 'rc=1')" "1"
check "personal repo: isolation ✗ names the dir" \
      "$(printf '%s\n' "$out" | grep -c 'does NOT isolate the credential')" "1"
check "personal repo: and says the per-user token does work" \
      "$(printf '%s\n' "$out" | grep -c 'pinned with its per-user token, resolves to persony')" "1"

out="$(doctor "'$R_WORK'" "$COLLAPSE GH_TOKEN=tok-worky GH_CONFIG_DIR=$CFG_WORK")"
check "work repo, pinned: route agrees" \
      "$(printf '%s\n' "$out" | grep -c "routes to 'worky', and that is who gh is")" "1"
check "work repo, pinned: declared == effective" \
      "$(printf '%s\n' "$out" | grep -c 'declared == effective')" "1"
# It still fails, because gh-personal genuinely does not isolate — the doctor
# reports the machine's state, not this directory's luck.
check "work repo, pinned: the isolation defect is still reported" \
      "$(printf '%s\n' "$out" | grep -c 'does NOT isolate the credential')" "1"

# With no collapse to find, the doctor must go quiet. A checker that fails in the
# healthy state is one people stop running.
out="$(zrun "GH_ACCOUNT_DEFAULT_DIR=''
             GH_STUB_KEYRING_LOGIN=worky GH_TOKEN=tok-worky GH_CONFIG_DIR=$CFG_WORK \
               gh-doctor '$R_WORK'; print -r -- \"rc=\$?\"")"
check "a healthy machine: no failures" "$(printf '%s\n' "$out" | grep -c 'rc=0')" "1"
check "a healthy machine: says so"     "$(printf '%s\n' "$out" | grep -c '✓ gh acts as the account')" "1"

echo
echo "=== gh-doctor: states that must not read as a clean bill of health ==="
out="$(doctor "--offline '$R_PERS'" "$COLLAPSE")"
check "--offline never claims an effective account" \
      "$(printf '%s\n' "$out" | grep -c '✓.*effective account')" "0"
check "--offline says the check did not run" \
      "$(printf '%s\n' "$out" | grep -c 'NOT CHECKED')" "2"
check "--offline is a warning, not a pass" \
      "$(printf '%s\n' "$out" | grep -c 'warning(s), no failures')" "1"

out="$(doctor "'$R_PERS'" "GH_STUB_FAIL=1")"
check "an unreachable API is a ✗, not agreement" \
      "$(printf '%s\n' "$out" | grep -c 'effective account: UNKNOWN')" "1"
check "and the comparisons are skipped, not passed" \
      "$(printf '%s\n' "$out" | grep -c 'skipped — the effective account is unknown')" "2"
check "and it exits non-zero"  "$(printf '%s\n' "$out" | grep -c 'rc=1')" "1"

# A route whose dir does not exist can never fire. Reported always, not only on
# the day it matches — that is how a single-quoted "$HOME/..." entry hides.
out="$(zrun "GH_ACCOUNT_ROUTES=( 'acme=\$HOME/.config/gh-work' ) gh-doctor --offline '$R_PERS'
             print -r -- \"rc=\$?\"")"
check "an unreachable route dir is a ✗ even when it did not match" \
      "$(printf '%s\n' "$out" | grep -c 'no such directory, so that route can never fire')" "1"
check "and it exits non-zero" "$(printf '%s\n' "$out" | grep -c 'rc=1')" "1"

out="$(zrun "GH_ACCOUNT_ROUTES=( 'acme=$CFG_BARE' ) gh-doctor --offline '$R_WORK'; print -r -- \"rc=\$?\"")"
check "a route dir with no login is a ✗" \
      "$(printf '%s\n' "$out" | grep -c 'declares no github.com user')" "1"

out="$(zrun "GH_ACCOUNT_ROUTES=( 'oops' ) gh-doctor --offline '$R_WORK'; print -r -- \"rc=\$?\"")"
check "an unusable table is UNUSABLE, not 'no route'" \
      "$(printf '%s\n' "$out" | grep -c 'routing table UNUSABLE')" "1"

out="$(zrun "GH_ACCOUNT_ROUTES=(); GH_ACCOUNT_DEFAULT_DIR=''; gh-doctor --offline '$R_WORK'
             print -r -- \"rc=\$?\"")"
check "no table at all is a warning, not silence" \
      "$(printf '%s\n' "$out" | grep -c 'empty — set GH_ACCOUNT_ROUTES')" "1"

check "a missing gh stops the doctor rather than passing it" \
      "$(zsh -c "source '$SYSTEM_SH'; source '$GITHUB_SH'; PATH=/nonexistent
                 gh-doctor >/dev/null 2>&1; print -r -- \$?")" "1"
check "a directory that is not one" \
      "$(zrun "gh-doctor '$TMPROOT/no-such-dir' 2>&1 | grep -c 'not a directory'")" "1"

echo
echo "=== the report never leaks a variable into the shell ==="
# The doctor runs in the user's interactive shell. Every internal is a local by
# dynamic scope; one missing declaration and the value persists (and a nested
# call corrupts the outer one).
for v in _DOCTOR_FAIL _DOCTOR_WARN _GH_URL_STATE _GH_REMOTE_STATE _GH_ROUTE_STATE \
         _GH_ROUTE_DIR _GH_ROUTE_WHY _GH_TOKEN_SOURCE _GH_PROBE_LOGIN _GH_PROBE_ERR \
         _GH_CONFIGURED_DIRS _GH_RUN du ut cd_ cu_ why_; do
  check "no \$$v left behind" \
        "$(zrun "gh-doctor '$R_WORK' >/dev/null 2>&1; print -r -- \"\${$v-unset}\"")" "unset"
done
# The symptom that made this a row: zsh's `local NAME` on a name already local in
# the same scope is a DISPLAY command, so a `local` inside a loop printed
# `name=value` into the middle of the report.
check "no 'name=value' typeset output in the report" \
      "$(doctor "'$R_PERS'" "$COLLAPSE" | grep -vx 'rc=[0-9]*' | grep -cE '^[a-z_]+=')" "0"

echo
echo "=== the module itself ==="
check "github.sh parses"  "$(zsh -n "$GITHUB_SH" 2>&1 | wc -l | tr -d ' ')" "0"
# gh-doctor uses the shared emitters, so it must declare their counters local —
# the convention asserted over every doctor in scripts/test-dotfiles-guard.sh.
check "gh-doctor declares its own counters" \
      "$(zrun "print -r -- \"\${functions[gh-doctor]}\"" | grep -c 'local _DOCTOR_FAIL=0 _DOCTOR_WARN=0')" "1"
# The emitters live in system.sh; github.sh must not grow a fourth glyph.
check "no hand-rolled report glyphs" \
      "$(grep -cE "printf '  [•*-] " "$GITHUB_SH")" "0"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
