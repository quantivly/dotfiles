#!/usr/bin/env bash
#
# scripts/test-gh-routing.sh
# ==========================
#
# State table for the GitHub account routing and diagnosis in
# zsh/functions/github.sh (_gh_url_owner, _gh_repo_remotes, _gh_route_for,
# _gh_configured_dirs, _gh_active_config_dir, _gh_token_source, _gh_run,
# _gh_config_dir_user, _gh_probe_login, _gh_user_token, gh-doctor) AND the half
# of it that actually chooses every shell's account: _update_gh_config,
# _gh_route_report and the first-prompt hook in zsh/zshrc.company.
#
# That second half had no coverage at first, and two of the worst bugs found in
# review lived there — a shell left permanently unpinned after losing a startup
# race, and GITHUB_TOKEN never being cleared so a third account won silently.
# Both produce a wrong account with no error, which is this file's whole remit.
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
#   - a live credential passed as `env GH_TOKEN=… gh api user`, i.e. in ARGV,
#     which /proc/<pid>/cmdline publishes to every local account (mode 444)
#     while /proc/<pid>/environ does not (400). In the tool written because this
#     machine had a token in a tmux server's cmdline for 28 days.
#   - git's exit status discarded, so 128 ("cannot read the repository", which a
#     malformed ~/.gitconfig produces — and ~/.gitconfig is a managed symlink in
#     THIS repo) read as "not a git repository" and routed a work clone to the
#     personal account, on the one path that deliberately does not warn.
#   - the first-prompt hook replaying what startup recorded instead of re-running
#     the routing, leaving the shell that lost the cache race unpinned for life.
#   - GITHUB_TOKEN, which gh ranks second, never cleared alongside GH_TOKEN.
#   - the legacy-nickname purge running AFTER the write loop, deleting a token it
#     had just cached whenever a config dir was named `quantivly` or `personal`.
#   - `env VAR=x some_shell_function` cannot work (env execs a binary), and the
#     probe reported the resulting "No such file or directory" as an
#     unresolvable GitHub account.
#   - `env GH_TOKEN=x -u GITHUB_TOKEN gh ...` runs a program called `-u`: env
#     stops parsing options at the first operand. Same disguise — it surfaced as
#     a fact about GitHub rather than about the command line. (Both env traps
#     are retired with `env` itself; the row asserting so remains.)
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

# This suite drives zsh by handing it source text, so a single-quoted
# `${GH_TOKEN:+pinned}` is the POINT: it must reach the inner shell unexpanded
# and be evaluated there. SC2016 ("expressions don't expand in single quotes")
# is therefore correct and unwanted on every occurrence in this file.
# shellcheck disable=SC2016
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
          _gh_run _gh_config_dir_user _gh_probe_login _gh_user_token gh-doctor; do
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
  "__argv__ ")
    # Reports whether a credential reached ARGV (world-readable at
    # /proc/<pid>/cmdline) as opposed to the ENVIRONMENT (owner-only, 400).
    seen="$(tr '\0' ' ' < /proc/self/cmdline)$(tr '\0' ' ' < /proc/$PPID/cmdline 2>/dev/null)"
    if [ -n "${GH_TOKEN:-}" ]; then
      case "$seen" in *"$GH_TOKEN"*) echo "TOKEN-IN-ARGV" ;; *) echo "argv-clean" ;; esac
      echo "token-in-env"
    else
      echo "argv-clean"; echo "no-token-in-env"
    fi ;;
  "auth token")
    shift 2; u=""
    while [ $# -gt 0 ]; do
      case "$1" in --user) u="${2:-}"; shift 2 ;; *) shift ;; esac
    done
    [ -n "$u" ] || exit 1
    case " ${GH_STUB_NO_TOKEN_FOR:-} " in *" $u "*) exit 1 ;; esac
    # A per-user entry that is real but belongs to the wrong account — the one
    # isolation state that IS actionable (that config dir needs a re-login).
    if [ -n "${GH_STUB_WRONG_USER_TOKEN:-}" ]; then
      printf 'tok-someoneelse\n'; exit 0
    fi
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
# git exits 128 when it cannot read the repository at all — a malformed
# ~/.gitconfig does it, and ~/.gitconfig is a managed symlink in THIS repo, so a
# bad branch causes it. Discarding that status left _GH_REMOTE_STATE at its
# initialised "no-repo", which falls through to the personal default: a
# quantivly clone silently authenticating as the personal account, on the one
# path that deliberately does not warn.
BADHOME="$TMPROOT/badhome"; mkdir -p "$BADHOME"
printf 'this is not valid git config\n' > "$BADHOME/.gitconfig"
giterr() { PATH="$STUBBIN:$PATH" HOME="$BADHOME" zsh -c "
    source '$SYSTEM_SH'; source '$GITHUB_SH'
    GH_ACCOUNT_ROUTES=( 'acme=$CFG_WORK' ); GH_ACCOUNT_DEFAULT_DIR='$CFG_PERS'
    $1" 2>&1; }
check "unreadable git is its own state, not 'no repo'" \
      "$(giterr "_gh_repo_remotes '$R_WORK'; print -r -- \$_GH_REMOTE_STATE")" "git-error"
check "...and does NOT fall through to the default" \
      "$(giterr "_gh_route_for '$R_WORK'; print -r -- \"\$_GH_ROUTE_STATE:\${_GH_ROUTE_DIR:t}\"")" "git-error:"
# Both the remotes section and the route section have to say so: a reader who
# skims to "Route" must not find a confident answer built on a failed question.
check "...and both doctor sections call it UNKNOWN" \
      "$(giterr "gh-doctor --offline '$R_WORK'" | grep -c 'remote is UNKNOWN')" "2"
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
echo "=== _gh_run: a credential must never reach argv ==="
# CALIBRATION: `env VAR=val prog` does NOT put the assignment in prog's cmdline
# — env consumes it and execs (measured: `env FOO=x sleep 3` shows cmdline
# `sleep 3`). The old form exposed the token only in the short-lived `env`
# process's own argv, a fork-to-exec race, not the length of the call. So the
# four /proc rows below would ALSO have passed under the old implementation:
# they assert an invariant worth holding, but the row that actually pins the
# change is the source-text one, and it is labelled as such rather than left to
# look like the strong evidence.
argvprobe() { zrun "_gh_run 5 '' '$1' __argv__"; }
check "a pinned token stays out of argv"  "$(argvprobe tok-persony | grep -c 'TOKEN-IN-ARGV')" "0"
check "...and is confirmed argv-clean"    "$(argvprobe tok-persony | grep -c 'argv-clean')"    "1"
check "...while still reaching gh's env"  "$(argvprobe tok-persony | grep -c '^token-in-env')" "1"
check "the cleared form passes no token"  "$(argvprobe '' | grep -c 'no-token-in-env')"        "1"
# THIS is the row that pins the change: the `env` argv class — a shell function
# after `env`, `-u` after an assignment — is retired with `env` itself.
check "no env-assignment prefix remains" \
      "$(zrun "print -r -- \"\${functions[_gh_run]}\"" | grep -cE '\benv\b')" "0"
# zsh's `exec` resolves SHELL FUNCTIONS, which `env` could not — a hazard the
# subshell form introduced. It is reachable ONLY on the no-`timeout` fallback
# (on the normal path `timeout` execs the binary itself), so the probe has to
# run with a PATH that has gh but not timeout, or it tests nothing.
# A PATH holding exactly what the stub needs and NOT timeout. `PATH=$STUBBIN`
# alone would lose zsh itself, and the row would then pass for that reason.
NOTIMEOUT="$TMPROOT/notimeout"; mkdir -p "$NOTIMEOUT"
ln -sf "$STUBBIN/gh" "$NOTIMEOUT/gh"
for _b in zsh bash env tr awk; do
  _p="$(command -v "$_b")" || fatal "cannot locate $_b for the no-timeout fixture"
  ln -sf "$_p" "$NOTIMEOUT/$_b"
done
notimeout() { PATH="$NOTIMEOUT" HOME="$FAKEHOME" "$NOTIMEOUT/zsh" -c "$1" 2>&1; }
check "the fixture PATH really lacks timeout" \
      "$(notimeout 'print -r -- $+commands[timeout]')" "0"
check "...and still has gh" \
      "$(notimeout 'print -r -- $+commands[gh]')" "1"
check "a gh shell function cannot hijack the probe" \
      "$(notimeout "source '$GITHUB_SH'
                    gh() { print HIJACKED }
                    GH_STUB_KEYRING_LOGIN=worky _gh_run 5 '' '' api user --jq .login" \
        | grep -c HIJACKED)" "0"
check "...and the real binary is still reached" \
      "$(notimeout "source '$GITHUB_SH'
                    gh() { print HIJACKED }
                    GH_STUB_KEYRING_LOGIN=worky _gh_run 5 '' '' api user --jq .login")" "worky"
check "the run is still time-bounded" \
      "$(zrun "print -r -- \"\${functions[_gh_run]}\"" | grep -c 'timeout')" "2"

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
# cd in first: that is how the hook and the doctor are actually used together,
# and the route-vs-effective comparison is only meaningful for $PWD (see the
# foreign-directory rows below).
doctor() {  # doctor <dir> <env-assignments> [gh-doctor flags]
  zrun "builtin cd $1 2>/dev/null; $2 gh-doctor ${3:-}; print -r -- \"rc=\$?\""
}
COLLAPSE="GH_STUB_KEYRING_LOGIN=worky"

out="$(doctor "'$R_PERS'" "$COLLAPSE")"
check "personal repo: the wrong account is named" \
      "$(printf '%s\n' "$out" | grep -c "routes to 'persony', but gh is 'worky'")" "1"
check "personal repo: and it fails"      "$(printf '%s\n' "$out" | grep -c 'rc=1')" "1"
check "personal repo: the collapse is named" \
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

echo
echo "=== the collapse is a ⚠, not a ✗: gh-doctor must not be permanently red ==="
# gh keys tokens by host, so no configuration on this machine can make a config
# dir isolate. Reporting that as a failure made gh-doctor exit 1 on EVERY run —
# the "permanently red checker" this repo warns about, in the command written to
# avoid it. It must still be REPORTED (it is why $GH_TOKEN is pinned at all),
# and ✗ must still fire for anything actually actionable.
out="$(doctor "'$R_WORK'" "$COLLAPSE GH_TOKEN=tok-worky GH_CONFIG_DIR=$CFG_WORK")"
check "the collapse is reported as a warning" \
      "$(printf '%s\n' "$out" | grep -c '⚠ .*does NOT isolate the credential')" "1"
check "...and not as a failure" \
      "$(printf '%s\n' "$out" | grep -c '✗ .*does NOT isolate the credential')" "0"
check "a correctly routed machine exits 0 despite the collapse" \
      "$(printf '%s\n' "$out" | grep -c 'rc=0')" "1"
check "...and says so in the summary" \
      "$(printf '%s\n' "$out" | grep -c 'warning(s), no failures')" "1"
# The actionable neighbour keeps its ✗: if even the per-user token resolves to
# the wrong login, pinning cannot work for that account and it needs a re-login.
out="$(doctor "'$R_WORK'" "GH_STUB_KEYRING_LOGIN=worky GH_STUB_WRONG_USER_TOKEN=1 \
                           GH_TOKEN=tok-worky GH_CONFIG_DIR=$CFG_WORK")"
# Both configured dirs are probed, and the knob breaks both, so two ✗ lines.
check "a broken per-user token is still ✗" \
      "$(printf '%s\n' "$out" | grep -c '✗ .*even the per-user token')" "2"
check "...and still exits non-zero" \
      "$(printf '%s\n' "$out" | grep -c 'rc=1')" "1"
check "...and points at the fix" \
      "$(printf '%s\n' "$out" | grep -c 'gh auth login')" "2"

# With no collapse to find, the doctor must go quiet. A checker that fails in the
# healthy state is one people stop running.
out="$(zrun "GH_ACCOUNT_DEFAULT_DIR=''
             GH_STUB_KEYRING_LOGIN=worky GH_TOKEN=tok-worky GH_CONFIG_DIR=$CFG_WORK \
               gh-doctor '$R_WORK'; print -r -- \"rc=\$?\"")"
check "a healthy machine: no failures" "$(printf '%s\n' "$out" | grep -c 'rc=0')" "1"
check "a healthy machine: says so"     "$(printf '%s\n' "$out" | grep -c '✓ gh acts as the account')" "1"

echo
echo "=== gh-doctor <dir>: an argument is not this shell ==="
# The effective-account probe reads THIS shell's environment, which the chpwd
# hook pinned for $PWD. Comparing that against a DIFFERENT directory's route
# produced a confident ✗ — "Commits, PRs and API writes from here land under the
# wrong account" — for a state that cannot occur, because cd-ing there repins
# first. `gh-doctor ~/some/repo` is an advertised form, so this was a false
# alarm on the documented usage.
out="$(zrun "builtin cd '$R_WORK' 2>/dev/null
             GH_STUB_KEYRING_LOGIN=worky GH_TOKEN=tok-worky GH_CONFIG_DIR=$CFG_WORK \
               gh-doctor '$R_PERS'; print -r -- \"rc=\$?\"")"
check "says which shell it is describing" \
      "$(printf '%s\n' "$out" | grep -c 'describes the CURRENT shell')" "1"
check "route vs effective is not a failure" \
      "$(printf '%s\n' "$out" | grep -c "this shell is 'worky'")" "1"
# ...and the question about the argument IS answered, from that dir's own
# per-user token, rather than merely skipped.
check "the argument directory's own account is reported" \
      "$(printf '%s\n' "$out" | grep -c 'Routed account for')" "1"
check "...and resolves to the account its remote routes to" \
      "$(printf '%s\n' "$out" | grep -c 'resolves to persony, which is what the remote routes to')" "1"
check "and it does NOT claim the wrong account" \
      "$(printf '%s\n' "$out" | grep -c 'land under the wrong account')" "0"
# Same directory, no argument: the comparison is meaningful and must still run.
check "for \$PWD the comparison still runs" \
      "$(doctor "'$R_PERS'" "$COLLAPSE" | grep -c "routes to 'persony', but gh is 'worky'")" "1"

echo
echo "=== gh-doctor: a deliberately unrouted shell is not a fault ==="
# Removing the Atrium deferral removed the only way for a supervisor that
# provisions per-session credentials to say "leave this shell alone". The
# replacement is explicit rather than sniffed, so the doctor can report it.
out="$(zrun "builtin cd '$R_NONE' 2>/dev/null
             GH_ACCOUNT_ROUTES=(); GH_ACCOUNT_DEFAULT_DIR=''
             GH_STUB_KEYRING_LOGIN=worky GH_ACCOUNT_ROUTING_OFF=1 gh-doctor; print -r -- \"rc=\$?\"")"
check "the opt-out is reported"          "$(printf '%s\n' "$out" | grep -c 'deliberately not routed')" "1"
check "and suppresses the 'who chose this?' warning" \
      "$(printf '%s\n' "$out" | grep -c 'chosen by something other than the remote')" "0"
# The harder case: a route DOES match, and the provisioned account is not it.
# The opt-out originally covered only the no-route branch, so this produced
# "✗ … land under the wrong account" and a non-zero exit for a deliberate state.
out="$(zrun "builtin cd '$R_WORK' 2>/dev/null
             GH_STUB_KEYRING_LOGIN=worky GH_ACCOUNT_ROUTING_OFF=1 \
             GH_TOKEN=tok-thirdparty gh-doctor; print -r -- \"rc=\$?\"")"
check "a matched route is not a ✗ when routing is off" \
      "$(printf '%s\n' "$out" | grep -c 'land under the wrong account')" "0"
# Twice: once as the note in "In effect", once where the comparison would have
# been. Both are wanted — a reader who skims to the verdict must still see why.
check "...it says why it did not compare" \
      "$(printf '%s\n' "$out" | grep -c 'GH_ACCOUNT_ROUTING_OFF is set')" "2"

# git-error must not make the git-identity section invent a diagnosis.
check "git-error does not claim user.email is unset" \
      "$(giterr "gh-doctor --offline '$R_WORK'" | grep -c 'user.email is unset')" "0"
check "...it says the identity is unknown too" \
      "$(giterr "gh-doctor --offline '$R_WORK'" | grep -c 'identity is unknown too')" "1"
# And git's own message has to reach the report, since ~/.gitconfig is only one
# of several causes (missing git, a deleted $PWD, dubious ownership).
check "git's own error text is surfaced" \
      "$(giterr "gh-doctor --offline '$R_WORK'" | grep -c 'bad config line')" "1"

echo
echo "=== gh-doctor: states that must not read as a clean bill of health ==="
out="$(doctor "'$R_PERS'" "$COLLAPSE" --offline)"
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
echo "=== _update_gh_config: the hook that pins every shell's account ==="
COMPANY_SH="$DOTFILES/zsh/zshrc.company"
[[ -r "$COMPANY_SH" ]] || fatal "cannot read $COMPANY_SH"
# A fixture HOME with the two config dirs the routing table names, so sourcing
# zshrc.company takes its opt-in gate and the stub gh reads fixture hosts.yml.
HOOKHOME="$TMPROOT/hookhome"
mkdir -p "$HOOKHOME/.config/gh-quantivly" "$HOOKHOME/.config/gh-personal" "$HOOKHOME/.cache"
printf 'github.com:\n    users:\n        worky:\n    user: worky\n'     > "$HOOKHOME/.config/gh-quantivly/hosts.yml"
printf 'github.com:\n    users:\n        persony:\n    user: persony\n' > "$HOOKHOME/.config/gh-personal/hosts.yml"
printf '[user]\n\temail = fixture@example.invalid\n' > "$HOOKHOME/.gitconfig"
# Repos whose owners match the table zshrc.company actually ships.
R_QUANT="$(mkrepo quantivly "origin=git@github.com:quantivly/platform.git")"
R_MINE="$(mkrepo mine       "origin=git@github.com:someone/blog.git")"

# Source the real zshrc.company, wait for its background refresh, then drive the
# hook. `env -i` so the ambient GH_* of the developer's own shell cannot leak in
# and make a row pass for the wrong reason.
hookrun() {  # hookrun <dir> <setup-statements> <report-expression>
  # $2 holds STATEMENTS, not a command prefix: a prefix assignment
  # (`FOO=1 _update_gh_config`) lasts only for the call, so a row asserting what
  # the hook LEFT in the environment read the previous call's values instead.
  # The hook's own warnings go to stderr and are dropped here; the rows that
  # assert on a message capture it explicitly.
  env -i PATH="$STUBBIN:/usr/bin:/bin" HOME="$HOOKHOME" TERM=dumb \
    zsh -c "
      source '$SYSTEM_SH'; source '$GITHUB_SH'
      source '$COMPANY_SH' >/dev/null 2>&1
      # The background refresher is the point of several rows; wait for it.
      for _i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -e \$HOME/.cache/gh-token-cache/gh-personal ]] && break
        sleep 0.2
      done
      _GH_ROUTE_INTERACTIVE=1
      builtin cd '$1' 2>/dev/null
      $2
      _update_gh_config 2>/dev/null
      $3" 2>/dev/null
}
pin() { hookrun "$1" "${2:-}" 'print -r -- "${${GH_CONFIG_DIR:t}:-none}/${${GH_TOKEN:+pinned}:-UNPINNED}"'; }

check "work repo pins the work dir"      "$(pin "$R_QUANT")" "gh-quantivly/pinned"
check "personal repo pins the personal dir" "$(pin "$R_MINE")"  "gh-personal/pinned"
check "outside a repo takes the default" "$(pin "$TMPROOT")"  "gh-personal/pinned"
# The cache key is the config dir's BASENAME; a nickname-keyed file must not be
# what the hook reads, or the routing table stops being the only place an
# account is named.
check "the cache is keyed by basename" \
      "$(hookrun "$R_QUANT" "" 'print -r -- ${(j:,:)${(f)"$(ls $HOME/.cache/gh-token-cache)"}}')" \
      "gh-personal,gh-quantivly"
check "legacy nickname files are purged" \
      "$(hookrun "$R_QUANT" "" 'print -r -- $(ls $HOME/.cache/gh-token-cache | grep -cx "quantivly\|personal")')" "0"
# ...and the purge must not delete a token it just wrote. The legacy names are
# `quantivly` and `personal`, which are also perfectly legal config-dir
# basenames — so with the purge running AFTER the write loop, a route named
# `~/.config/personal` had its freshly-cached token deleted on every shell
# start, leaving that account permanently unpinned with no error anywhere.
mkdir -p "$HOOKHOME/.config/personal"
printf 'github.com:\n    users:\n        namesake:\n    user: namesake\n' \
  > "$HOOKHOME/.config/personal/hosts.yml"
# The refresher must run AFTER the new default is in place — it is started at
# source time, so setting the route afterwards would test nothing.
check "a config dir named like a legacy key survives the purge" \
      "$(hookrun "$R_MINE" "GH_ACCOUNT_DEFAULT_DIR=\$HOME/.config/personal
                            _gh_refresh_token_cache_bg" \
         'print -r -- "${${GH_CONFIG_DIR:t}:-none}/${${GH_TOKEN:+pinned}:-UNPINNED}"')" \
      "personal/pinned"
rm -rf "$HOOKHOME/.config/personal"

# gh ranks GITHUB_TOKEN second, so leaving it set on a path that clears GH_TOKEN
# means a third account nobody named wins — while the message blames the keyring.
check "GITHUB_TOKEN is cleared with GH_TOKEN" \
      "$(hookrun "$TMPROOT" "GH_ACCOUNT_DEFAULT_DIR=''; export GITHUB_TOKEN=tok-someoneelse" \
         'print -r -- "${GITHUB_TOKEN:-cleared}"')" "cleared"
check "...and the account really is unpinned then" \
      "$(hookrun "$TMPROOT" "GH_ACCOUNT_DEFAULT_DIR=''; export GITHUB_TOKEN=tok-someoneelse" \
         'print -r -- "$(GH_STUB_KEYRING_LOGIN=keyring gh api user --jq .login)"')" "keyring"

# git-error must not fall through to the personal default.
#
# This row was VACUOUS as first written: it sourced only github.sh, so
# `_update_gh_config` was `command not found` and `env -i` supplied the expected
# `none/UNPINNED` no matter what the hook did — reverting the fix left it green.
# It loads zshrc.company against the fixture HOME now, with a broken
# ~/.gitconfig placed inside that HOME so git really cannot read the repo.
cp "$BADHOME/.gitconfig" "$HOOKHOME/.gitconfig.broken"
check "unreadable git pins nothing" \
      "$(env -i PATH="$STUBBIN:/usr/bin:/bin" HOME="$HOOKHOME" TERM=dumb zsh -c "
           source '$SYSTEM_SH'; source '$GITHUB_SH'
           source '$COMPANY_SH' >/dev/null 2>&1
           (( \$+functions[_update_gh_config] )) || { print MISSING-HOOK; exit }
           builtin cd '$R_QUANT' 2>/dev/null
           cp \$HOME/.gitconfig.broken \$HOME/.gitconfig
           _update_gh_config 2>/dev/null
           print -r -- \"\${GH_CONFIG_DIR:-none}/\${\${GH_TOKEN:+pinned}:-UNPINNED}\"" 2>&1)" \
      "none/UNPINNED"
printf '[user]\n\temail = fixture@example.invalid\n' > "$HOOKHOME/.gitconfig"

# The explicit opt-out must leave an injected credential entirely alone.
check "GH_ACCOUNT_ROUTING_OFF leaves the env untouched" \
      "$(hookrun "$R_QUANT" "export GH_ACCOUNT_ROUTING_OFF=1 GH_CONFIG_DIR=/injected GH_TOKEN=tok-injected" \
         'print -r -- "${GH_CONFIG_DIR}/${GH_TOKEN}"')" "/injected/tok-injected"

# gh outranks GITHUB_TOKEN, but nothing else does: the MCP server, act, hub and
# most Actions-shaped tooling read it, so an inherited one must not survive a
# SUCCESSFULLY routed directory either.
check "GITHUB_TOKEN is cleared on the success path too" \
      "$(hookrun "$R_QUANT" "export GITHUB_TOKEN=tok-thirdparty" \
         'print -r -- "${${GH_CONFIG_DIR:t}:-none}/${GITHUB_TOKEN:-cleared}"')" "gh-quantivly/cleared"

# gh-refresh-tokens is defined OUTSIDE the ~/.config/gh-quantivly gate while its
# helpers were defined inside it, so on a personal-only box it hit `command not
# found`, took an EMPTY cache path, wrote a live token to `/<basename>` at the
# filesystem root, and still printed ✓ and returned 0.
NOGATE="$TMPROOT/nogate"; mkdir -p "$NOGATE/.config/gh-personal" "$NOGATE/.cache"
printf 'github.com:\n    users:\n        persony:\n    user: persony\n' \
  > "$NOGATE/.config/gh-personal/hosts.yml"
nogate() {
  env -i PATH="$STUBBIN:/usr/bin:/bin" HOME="$NOGATE" TERM=dumb zsh -c "
      source '$SYSTEM_SH'; source '$GITHUB_SH'
      source '$COMPANY_SH' >/dev/null 2>&1
      GH_ACCOUNT_DEFAULT_DIR=\$HOME/.config/gh-personal
      gh-refresh-tokens >/dev/null 2>&1
      $1" 2>&1
}
check "the cache path survives a machine without the work dir" \
      "$(nogate 'print -r -- "${_GH_TOKEN_CACHE#$HOME/}"')" ".cache/gh-token-cache"
check "...and the token lands there, not at the filesystem root" \
      "$(nogate 'print -r -- "$(ls $HOME/.cache/gh-token-cache)"')" "gh-personal"

echo
echo "=== the first prompt must RE-RUN routing, not replay a stale line ==="
# The startup call routinely loses a race it is meant to lose: the cache is
# repopulated by a background job that lands ~1s later, so the shell starts
# unpinned and records "account NOT pinned". Replaying that at the first prompt
# printed a message that was no longer true AND left GH_TOKEN unset for the life
# of the shell — every gh call then falling to the host-keyed keyring default
# (work) inside a personal repo, which is the defect this all exists to close.
cat > "$TMPROOT/firstprompt.zsh" <<'FP'
source "$T_SYSTEM_SH"; source "$T_GITHUB_SH"
source "$T_COMPANY_SH" >/dev/null 2>&1
builtin cd "$T_DIR" 2>/dev/null
# Force the miss deterministically rather than trying to out-race the
# background refresher — against a stub gh that race is a coin flip, and a
# flaky row in a suite about silent failures is worse than no row.
rm -rf "$HOME/.cache/gh-token-cache"
_update_gh_config 2>/dev/null               # the startup call: silent, unpinned
startup="${${GH_TOKEN:+pinned}:-UNPINNED}"
_gh_refresh_token_cache_bg                  # what the background job does, ~1s later
# The hook runs in THIS shell, with stderr diverted to a file. Capturing it in
# a command substitution instead put _update_gh_config's exports in a subshell,
# so the row read the parent's unchanged environment and failed for a reason
# that had nothing to do with the code under test.
exec 3>&2 2>"$T_MSG"
for f in $precmd_functions; do $f; done
exec 2>&3 3>&-
msg="$(<$T_MSG)"
print -r -- "$startup|${${GH_TOKEN:+pinned}:-UNPINNED}|${msg:+said}"
FP
firstprompt() {  # <dir> -> "<pinned at startup>|<pinned after first prompt>|<said?>"
  env -i PATH="$STUBBIN:/usr/bin:/bin" HOME="$HOOKHOME" TERM=dumb \
      T_SYSTEM_SH="$SYSTEM_SH" T_GITHUB_SH="$GITHUB_SH" T_COMPANY_SH="$COMPANY_SH" \
      T_DIR="$1" T_MSG="$TMPROOT/firstprompt.err" zsh "$TMPROOT/firstprompt.zsh" 2>/dev/null
}
check "startup loses the race, the first prompt repairs it" \
      "$(firstprompt "$R_MINE")" "UNPINNED|pinned|"
check "the hook removes itself once it has pinned" \
      "$(hookrun "$R_MINE" "" 'for f in $precmd_functions; do $f; done >/dev/null 2>&1
                               print -r -- ${+functions[_gh_route_first_prompt]}')" "0"
# ...but NOT before. It used to unhook after one attempt, so a shell that lost
# the cache race twice — the refresher does two gh forks, and p10k's instant
# prompt can beat them on a loaded box — stayed on the keyring default for life.
check "the hook stays while nothing is pinned" \
      "$(hookrun "$R_MINE" "rm -rf \$HOME/.cache/gh-token-cache" \
         'for f in $precmd_functions; do $f; done >/dev/null 2>&1
          print -r -- ${+functions[_gh_route_first_prompt]}')" "1"
check "...and a later prompt still repairs it" \
      "$(hookrun "$R_MINE" "rm -rf \$HOME/.cache/gh-token-cache" \
         'for f in $precmd_functions; do $f; done >/dev/null 2>&1
          _gh_refresh_token_cache_bg
          for f in $precmd_functions; do $f; done >/dev/null 2>&1
          print -r -- "${${GH_TOKEN:+pinned}:-UNPINNED}"')" "pinned"

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
