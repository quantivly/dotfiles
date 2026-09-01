# shellcheck shell=bash
#==============================================================================
# GitHub Account Routing & Diagnosis
#==============================================================================
# Which GitHub account does `gh` act as, in this directory, right now?
#
# The answer is not what `gh auth status` says. gh stores its tokens in the
# system keyring keyed by HOST, not by config dir, so `GH_CONFIG_DIR` isolates
# `hosts.yml` and `config.yml` but NOT the credential: three config dirs
# declaring three different users can all resolve to one account. Observed on
# this machine, 2026-09-01:
#
#     config dir      hosts.yml declares    an API call resolves to
#     gh              zvi-quantivly      →  zvi-quantivly
#     gh-personal     ZviBaratz          →  zvi-quantivly   ← mismatch
#     gh-quantivly    zvi-quantivly      →  zvi-quantivly
#
# `gh auth status` reports the *declared* user throughout, so it says
# `ZviBaratz` while the API returns `zvi-quantivly`. That is the same shape as
# the `backup-doctor` bug and the live-config guard's false all-clear: a status
# command describing intent rather than effect. The failure is silent, and it
# silently falls back to the WORK account — which is the worse direction.
#
# `gh-doctor` makes it visible. It prints, for the current directory: the
# account the repo's remote routes to, the account gh declares, the account an
# actual API call returns, and which mechanism decided. Everything it reports
# about "effective" comes from a real request; nothing is inferred from config.
#
# Routing follows the REPO REMOTE, the way git identity already does (#67,
# `hasconfig:remote.*.url` in ~/.gitconfig.local) — not $PWD, so a work repo
# routes correctly wherever it is checked out, and a personal repo under
# ~/quantivly/ does not get the work account. Like hasconfig, ANY remote can
# match, not just origin.
#
# Functions:
#   _gh_url_owner        parse a remote URL -> GitHub owner (pure)
#   _gh_repo_remotes     every remote of a repo, with its owner (pure-ish)
#   _gh_route_for        apply GH_ACCOUNT_ROUTES to a directory (pure-ish)
#   _gh_active_config_dir / _gh_token_source   what gh will use right now
#   _gh_config_dir_user  the account a config dir DECLARES
#   _gh_probe_login      the account an API call actually RETURNS
#   gh-doctor            declared vs effective, and who decided
#
# State table: scripts/test-gh-routing.sh (run in CI, hermetic).
#==============================================================================

# -----------------------------------------------------------------------------
# Routing table
# -----------------------------------------------------------------------------
# GH_ACCOUNT_ROUTES: ordered 'owner-pattern=gh-config-dir' entries. The pattern
# is a zsh glob matched case-insensitively against a remote's GitHub owner
# (GitHub owners are case-insensitive). First entry with a matching remote wins,
# so order is precedence. A leading ~ in the dir is expanded; anything else is
# taken literally, so write "$HOME/..." in double quotes if you prefer.
#
#     GH_ACCOUNT_ROUTES=( "quantivly=$HOME/.config/gh-quantivly" )
#
# GH_ACCOUNT_DEFAULT_DIR: the config dir for a repo no route matches. Empty
# means "the remote does not determine an account" — which gh-doctor reports as
# a finding rather than letting the keyring pick one silently.
#
# Both are deliberately empty here and set by the machine's own config
# (zsh/zshrc.company, or ~/.zshrc.local): this file is the mechanism, the
# accounts are data.
typeset -ga GH_ACCOUNT_ROUTES
: "${GH_ACCOUNT_DEFAULT_DIR=}"

# -----------------------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------------------

# Owner (user or org) of a GitHub remote URL.
# Usage: _gh_url_owner <url>
# Sets:  _GH_URL_STATE = "owner <name>" | not-github | unparsable
# Returns non-zero for everything but a parsed owner.
#
# Handles the four forms git accepts — scp-like (git@host:owner/repo), ssh://,
# https:// (with or without userinfo) and git:// — because a routing rule that
# silently fails to parse one of them reads as "personal repo", which is the
# direction that hands a work repo the wrong account with no error.
_gh_url_owner() {
  local url="${1:-}" rest host path owner
  _GH_URL_STATE=unparsable
  [[ -n "$url" ]] || return 1

  if [[ "$url" == *://* ]]; then
    rest="${url#*://}"
    rest="${rest#*@}"                 # strip userinfo; no-op when absent
    [[ "$rest" == */* ]] || return 1
    host="${rest%%/*}"
    host="${host%%:*}"                # strip :port
    path="${rest#*/}"
  elif [[ "$url" == *:* ]]; then
    rest="${url#*@}"                  # scp-like: [user@]host:path
    host="${rest%%:*}"
    path="${rest#*:}"
  else
    # A local path or a plain name. Not a remote we can route on, and not a
    # parse failure either — say so, so the two are not fixed the same way.
    _GH_URL_STATE=not-github
    return 1
  fi

  # github.com, GitHub's port-443 SSH endpoint, and the `github-work`-style host
  # aliases this repo's SSH config uses to bind one account's key to github.com
  # (see gitconfig-work.example). A GitHub Enterprise host is deliberately NOT
  # matched: it has its own accounts and would route to the wrong ones.
  case "${host:l}" in
    github.com|ssh.github.com|github-*) ;;
    *) _GH_URL_STATE=not-github; return 1 ;;
  esac

  path="${path#/}"
  [[ "$path" == */* ]] || return 1
  owner="${path%%/*}"
  [[ -n "$owner" ]] || return 1
  _GH_URL_STATE="owner $owner"
  return 0
}

# Every remote of a repository, with the owner each one parses to.
# Usage: _gh_repo_remotes [dir]
# Sets:  _GH_REMOTE_STATE = ok | no-repo | no-remotes | git-error
#        _GH_REMOTE_ERR = git's own message, when the state is git-error
#        _GH_REMOTE_NAMES / _GH_REMOTE_URLS / _GH_REMOTE_OWNERS  (parallel;
#        owner is "" for a remote that is not a parsable GitHub URL)
# Returns non-zero unless the state is ok.
#
# ALL remotes, not just origin, because that is what git identity routes on
# (`hasconfig:remote.*.url`). In a fork workflow origin is the personal fork and
# upstream is the work repo; matching only origin would give that repo the
# personal account while git signs the commits with the work identity.
_gh_repo_remotes() {
  local dir="${1:-$PWD}" line key name url
  local _GH_URL_STATE
  local -a lines
  _GH_REMOTE_NAMES=(); _GH_REMOTE_URLS=(); _GH_REMOTE_OWNERS=(); _GH_REMOTE_ERR=""
  _GH_REMOTE_STATE=no-repo

  # One git fork on the common path. This runs from the chpwd hook, so the
  # obvious `rev-parse --git-dir` guard first would double the cost of every
  # `cd` for an answer only the empty case needs.
  #
  # THE EXIT STATUS IS LOAD-BEARING, and discarding it was a silent
  # wrong-account bug. git uses 0 = matched, 1 = no match (whether that is "no
  # remotes" or "not a repository"), and 128 = it could not read the repository
  # at all. A malformed ~/.gitconfig produces 128 — and ~/.gitconfig is itself a
  # managed symlink in THIS repo, so a bad branch can cause it. Treating 128 as
  # "not a git repository" sends a quantivly clone down the no-repo path, which
  # falls through to the personal account and, by design, does not warn. Exactly
  # the failure CLAUDE.md already records for dotfiles-doctor: "A git that
  # cannot read the repo answers every question with silence."
  # stderr is folded into the capture rather than parked in a temp file: the
  # cleanup would need `rm`, and one of the states being diagnosed is a broken
  # PATH, where `command rm` is itself not found. The fold is safe because the
  # capture is only PARSED when rc is 0, and the parser below accepts a line
  # only if it really is `remote.<name>.url <value>`, so a warning on stderr
  # cannot become a phantom remote.
  local out rc
  out="$(command git -C "$dir" config --get-regexp '^remote\..*\.url$' 2>&1)"; rc=$?
  if (( rc != 0 && rc != 1 )); then
    # KEEP git's own message. Collapsing every non-0/1 status into one sentence
    # that blamed ~/.gitconfig was wrong for most of them: `command git` exits
    # 127 when git is not installed, $PWD may have been deleted, and "detected
    # dubious ownership" (whose fix is safe.directory, not the gitconfig) is
    # ordinary for a repo on external media. Discarding stderr left neither the
    # hook nor the doctor able to say what actually happened.
    _GH_REMOTE_ERR="${${out%%$'\n'*}:-git exited $rc with no message}"
    _GH_REMOTE_STATE=git-error
    return 1
  fi
  lines=( ${(f)out} )
  for line in "${lines[@]}"; do
    [[ -n "$line" ]] || continue      # ${(f)} on empty output yields one blank
    key="${line%% *}"
    url="${line#* }"
    [[ "$key" != "$line" ]] || continue
    # Shape-check the key rather than trusting anything with a space in it: with
    # stderr folded into the capture, a git warning would otherwise be parsed as
    # a remote named "warning:" and shown as one in the doctor.
    [[ "$key" == remote.*.url ]] || continue
    name="${key#remote.}"; name="${name%.url}"
    _GH_REMOTE_NAMES+=("$name")
    _GH_REMOTE_URLS+=("$url")
    if _gh_url_owner "$url"; then
      _GH_REMOTE_OWNERS+=("${_GH_URL_STATE#owner }")
    else
      _GH_REMOTE_OWNERS+=("")
    fi
  done

  if (( ${#_GH_REMOTE_NAMES[@]} == 0 )); then
    # git's config is provably readable by now (rc was 0 or 1, never 128), so a
    # failing rev-parse here really does mean "not a repository" rather than
    # "git could not be asked".
    command git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 && _GH_REMOTE_STATE=no-remotes
    return 1
  fi
  _GH_REMOTE_STATE=ok
  return 0
}

# Which gh config dir GH_ACCOUNT_ROUTES selects for a directory.
# Usage: _gh_route_for [dir]
# Sets:  _GH_ROUTE_STATE = matched | default | none | no-repo | no-remotes
#                        | bad-table | git-error
#        _GH_ROUTE_DIR   = the selected gh config dir ("" when there is none)
#        _GH_ROUTE_WHY   = one line saying which rule decided, for the report
# Returns 0 only for matched/default.
#
# `bad-table` exists because an unparseable routing table otherwise selects
# nothing, and "nothing" is indistinguishable from "this repo is personal" —
# the unparseable-link-map failure from the live-config guard, in a new place.
_gh_route_for() {
  local dir="${1:-$PWD}" entry pat rdir i
  local -a _GH_REMOTE_NAMES _GH_REMOTE_URLS _GH_REMOTE_OWNERS
  local _GH_REMOTE_STATE
  _GH_ROUTE_STATE=none; _GH_ROUTE_DIR=""; _GH_ROUTE_WHY=""

  # Validate the whole table before consulting any of it: a typo in entry three
  # must not be masked by entry one happening to match.
  for entry in "${GH_ACCOUNT_ROUTES[@]}"; do
    if [[ "$entry" != *=* || -z "${entry%%=*}" || -z "${entry#*=}" ]]; then
      _GH_ROUTE_STATE=bad-table
      _GH_ROUTE_WHY="GH_ACCOUNT_ROUTES entry is not 'owner-pattern=config-dir': '$entry'"
      return 1
    fi
    # The pattern is matched with ${~pat}, which enables filename generation AND
    # tilde expansion — so a pattern beginning with ~ aborts the whole function
    # with "no such user or named directory", taking every later route with it.
    # A GitHub owner is [A-Za-z0-9-]; the only extras a route needs are the * ?
    # wildcards. Everything else (~ / ( ) # ^ whitespace) is a typo, and is
    # named as one here rather than left to misfire at match time.
    if [[ -n "${${entry%%=*}//[A-Za-z0-9_.?*-]/}" ]]; then
      _GH_ROUTE_STATE=bad-table
      _GH_ROUTE_WHY="GH_ACCOUNT_ROUTES owner pattern may only contain letters, digits, - _ . and the * ? wildcards: '${entry%%=*}'"
      return 1
    fi
  done

  # No repo and no remotes are NOT failures — `$HOME` is the normal resting
  # state of a shell — but they are also not licence to let the keyring answer.
  # They fall through to GH_ACCOUNT_DEFAULT_DIR below, which is what git
  # identity does outside a work repo (the personal `[user]` block). Only with
  # no default configured does the account become genuinely undetermined, and
  # only then is it worth saying so. Warning on every `cd` into a non-repo
  # directory is how the whole mechanism gets tuned out.
  local why_no_route
  _gh_repo_remotes "$dir"
  # "git could not be asked" is NOT "there is nothing here". Falling through to
  # the default would hand a work repository the personal account on the one
  # path that deliberately stays quiet, so this one stops here and is loud.
  if [[ "$_GH_REMOTE_STATE" == "git-error" ]]; then
    _GH_ROUTE_STATE=git-error
    _GH_ROUTE_WHY="git could not read '$dir' — the remote is UNKNOWN, so no account was selected: ${_GH_REMOTE_ERR:-(no message)}"
    return 1
  fi
  case "$_GH_REMOTE_STATE" in
    no-repo)    why_no_route="not a git repository — no remote to route on" ;;
    no-remotes) why_no_route="git repository with no remotes — nothing to route on" ;;
    *)          why_no_route="no route matched any remote" ;;
  esac

  for entry in "${GH_ACCOUNT_ROUTES[@]}"; do
    pat="${entry%%=*}"
    rdir="${entry#*=}"
    [[ "$rdir" == '~'* ]] && rdir="${HOME}${rdir#\~}"
    for (( i = 1; i <= ${#_GH_REMOTE_OWNERS[@]}; i++ )); do
      [[ -n "${_GH_REMOTE_OWNERS[i]}" ]] || continue
      if [[ "${_GH_REMOTE_OWNERS[i]:l}" == ${~pat:l} ]]; then
        _GH_ROUTE_STATE=matched
        _GH_ROUTE_DIR="$rdir"
        _GH_ROUTE_WHY="remote '${_GH_REMOTE_NAMES[i]}' owner '${_GH_REMOTE_OWNERS[i]}' matches route '$pat'"
        return 0
      fi
    done
  done

  if [[ -n "$GH_ACCOUNT_DEFAULT_DIR" ]]; then
    _GH_ROUTE_STATE=default
    _GH_ROUTE_DIR="$GH_ACCOUNT_DEFAULT_DIR"
    [[ "$_GH_ROUTE_DIR" == '~'* ]] && _GH_ROUTE_DIR="${HOME}${_GH_ROUTE_DIR#\~}"
    _GH_ROUTE_WHY="$why_no_route — GH_ACCOUNT_DEFAULT_DIR"
    return 0
  fi
  # Report which flavour of "nothing to go on" this is: a missing route and a
  # missing repository have different fixes.
  case "$_GH_REMOTE_STATE" in
    no-repo)    _GH_ROUTE_STATE=no-repo ;;
    no-remotes) _GH_ROUTE_STATE=no-remotes ;;
    *)          _GH_ROUTE_STATE=none ;;
  esac
  _GH_ROUTE_WHY="$why_no_route, and GH_ACCOUNT_DEFAULT_DIR is unset"
  return 1
}

# Every gh config dir the routing table names, in table order, deduplicated,
# with ~ expanded. Shared by the table check and the isolation probe so the two
# can never disagree about what is configured.
# Usage: _gh_configured_dirs
# Sets:  _GH_CONFIGURED_DIRS (parallel with _GH_CONFIGURED_WHY)
_gh_configured_dirs() {
  local entry d
  _GH_CONFIGURED_DIRS=(); _GH_CONFIGURED_WHY=()
  for entry in "${GH_ACCOUNT_ROUTES[@]}"; do
    [[ "$entry" == *=* ]] || continue
    d="${entry#*=}"; [[ "$d" == '~'* ]] && d="${HOME}${d#\~}"
    (( ${_GH_CONFIGURED_DIRS[(Ie)$d]} )) && continue
    _GH_CONFIGURED_DIRS+=("$d"); _GH_CONFIGURED_WHY+=("route '${entry%%=*}'")
  done
  if [[ -n "$GH_ACCOUNT_DEFAULT_DIR" ]]; then
    d="$GH_ACCOUNT_DEFAULT_DIR"; [[ "$d" == '~'* ]] && d="${HOME}${d#\~}"
    if ! (( ${_GH_CONFIGURED_DIRS[(Ie)$d]} )); then
      _GH_CONFIGURED_DIRS+=("$d"); _GH_CONFIGURED_WHY+=("GH_ACCOUNT_DEFAULT_DIR")
    fi
  fi
}

# -----------------------------------------------------------------------------
# What gh will actually do
# -----------------------------------------------------------------------------

# The config dir gh will read, applying gh's own precedence.
_gh_active_config_dir() {
  if [[ -n "${GH_CONFIG_DIR:-}" ]]; then
    print -r -- "$GH_CONFIG_DIR"
  else
    print -r -- "${XDG_CONFIG_HOME:-$HOME/.config}/gh"
  fi
}

# Which mechanism supplies the credential for github.com right now.
# Sets: _GH_TOKEN_SOURCE = GH_TOKEN | GITHUB_TOKEN | config-dir
# `config-dir` is the dangerous one: that is the path through the shared
# keyring, where the config dir does not decide the account.
_gh_token_source() {
  if [[ -n "${GH_TOKEN:-}" ]];       then _GH_TOKEN_SOURCE=GH_TOKEN
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then _GH_TOKEN_SOURCE=GITHUB_TOKEN
  else                                    _GH_TOKEN_SOURCE=config-dir
  fi
}

# Run gh with an explicitly-controlled environment, under a wall-clock bound.
# Usage: _gh_run <seconds> <config-dir|""> <token|""|-> <gh args...>
#   config-dir  ""  -> leave GH_CONFIG_DIR as it is
#   token       "-" -> leave the ambient token env exactly as it is
#               ""  -> unset GH_TOKEN and GITHUB_TOKEN, forcing the config-dir path
#               *   -> pin this token
# Prints gh's stdout; stderr is the caller's to redirect. Returns gh's status,
# or 124 when `timeout` killed it.
#
# The environment is set inside a subshell rather than as `env VAR=val` argv.
#
# CALIBRATION, because the first version of this comment overstated it: `env`
# CONSUMES its assignments and then execs, so the token never reaches the
# exec'd program's `/proc/<pid>/cmdline` — measured, not assumed. It is in argv
# only of the short-lived `env` process itself, between fork and exec. That is a
# microsecond race, not the length of the call, and it is NOT the same shape as
# the 28-day-old tmux server this machine found on 2026-09-01, whose credential
# sat in a long-lived process's own cmdline.
#
# It is still worth not doing: /proc/<pid>/cmdline is world-readable (444) and
# /proc/<pid>/environ is owner-only (400), so the subshell form closes even the
# race — and, the actual payoff, it retires the whole `env` argv class. Two bugs
# in this file came from it (a shell function after `env`, and `-u` after an
# assignment), and both surfaced as "could not resolve the account", i.e. as
# facts about GitHub.
#
# `exec command gh`, not `exec gh`: zsh's `exec` resolves SHELL FUNCTIONS, so a
# user-defined `gh` wrapper in ~/.zshrc.local would be run instead of the binary
# and its output taken as the effective login. `env` could not do that, so this
# hazard is new with the subshell — it is the one thing the old form was better
# at, and it only bites on the no-`timeout` fallback (on the normal path
# `timeout` execs the binary itself).
#
# A missing `timeout` degrades to an unbounded call rather than to failure —
# the same reasoning as setup-backup.sh's account lookup, where "the question
# never ran" must not read as an answer.
_gh_run() {
  local secs="$1" dir="$2" token="$3"
  shift 3
  (
    case "$token" in
      -)  ;;
      "") unset GH_TOKEN GITHUB_TOKEN ;;
      *)  export GH_TOKEN="$token"; unset GITHUB_TOKEN ;;
    esac
    [[ -n "$dir" ]] && export GH_CONFIG_DIR="$dir"
    if (( $+commands[timeout] )); then
      exec timeout "$secs" gh "$@"
    else
      exec command gh "$@"
    fi
  )
}

# The account a config dir DECLARES (hosts.yml), read through gh itself rather
# than by parsing YAML here. No network and no credential needed.
# Usage: _gh_config_dir_user <config-dir> [host]
# Prints the login, or nothing; returns non-zero when there is none.
_gh_config_dir_user() {
  local dir="${1:-}" host="${2:-github.com}" out
  [[ -n "$dir" && -d "$dir" ]] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  out="$(_gh_run 5 "$dir" - config get -h "$host" user 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  print -r -- "${out%%$'\n'*}"
}

# The account an actual API call RETURNS. This is the only authoritative answer
# and the reason this file exists.
# Usage: _gh_probe_login [config-dir] [token]
#   config-dir  ""  -> whatever the ambient GH_CONFIG_DIR says
#   token       ""  -> unset GH_TOKEN/GITHUB_TOKEN, forcing the config-dir path
#               "-" -> leave the ambient token env exactly as it is
# Sets:  _GH_PROBE_LOGIN, _GH_PROBE_ERR
# Returns 0 on a login, 1 on any failure — an empty answer is NEVER agreement.
_gh_probe_login() {
  local dir="${1:-}" token="${2:--}" out rc
  _GH_PROBE_LOGIN=""; _GH_PROBE_ERR=""
  if ! command -v gh >/dev/null 2>&1; then
    _GH_PROBE_ERR="gh is not installed"; return 1
  fi
  out="$(_gh_run 15 "$dir" "$token" api user --jq .login 2>&1)"; rc=$?
  if (( rc != 0 )) || [[ -z "$out" ]]; then
    _GH_PROBE_ERR="${out:-gh exited $rc with no output}"
    _GH_PROBE_ERR="${_GH_PROBE_ERR%%$'\n'*}"
    (( rc == 124 )) && _GH_PROBE_ERR="timed out after 15s"
    return 1
  fi
  _GH_PROBE_LOGIN="${out%%$'\n'*}"
  return 0
}

# The per-user token gh holds for an account, fetched with --user so it comes
# from that account's keyring entry rather than the shared default. This is the
# mechanism that DOES isolate, and the doctor proves it works before advising
# anyone to rely on it.
_gh_user_token() {
  local dir="${1:-}" user="${2:-}" out
  [[ -n "$user" ]] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  out="$(_gh_run 5 "$dir" "" auth token --user "$user" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  print -r -- "${out%%$'\n'*}"
}

# -----------------------------------------------------------------------------
# gh-doctor
# -----------------------------------------------------------------------------

gh-doctor() {
  # Usage: gh-doctor [--offline] [dir]
  #
  # Declared vs effective GitHub account for a directory, and which mechanism
  # decided. Read-only: no config is written, no account is switched.
  #
  # Makes real API calls by default, because "effective" cannot be inferred from
  # configuration — that inference is the bug. `--offline` skips every call and
  # reports the config-only half, clearly marked as unverified rather than as a
  # clean bill of health.
  #
  # Uses the shared _doctor_* emitters; their counters are locals by dynamic
  # scope, so this function must declare them — see _doctor_ok in system.sh.
  local _DOCTOR_FAIL=0 _DOCTOR_WARN=0
  local offline=0 dir="$PWD"
  local _GH_ROUTE_STATE _GH_ROUTE_DIR _GH_ROUTE_WHY
  local _GH_REMOTE_STATE _GH_TOKEN_SOURCE _GH_PROBE_LOGIN _GH_PROBE_ERR
  local -a _GH_REMOTE_NAMES _GH_REMOTE_URLS _GH_REMOTE_OWNERS
  local -a _GH_CONFIGURED_DIRS _GH_CONFIGURED_WHY
  # zsh's `local` on an existing name in the same scope PRINTS it, so every
  # loop-body variable is declared once, here.
  local cd_ why_ cu_ dir_is_pwd rt

  while (( $# )); do
    case "$1" in
      --offline)  offline=1 ;;
      --help|-h)  echo "Usage: gh-doctor [--offline] [dir]"; return 0 ;;
      -*)         echo "usage: gh-doctor [--offline] [dir]" >&2; return 2 ;;
      *)          dir="$1" ;;
    esac
    shift
  done

  echo "=== GitHub Account Doctor ==="

  # Prove the one tool every answer depends on is present, before printing any
  # answer that would look the same whether it ran or not.
  if ! command -v gh >/dev/null 2>&1; then
    echo "  ✗ gh is not installed — nothing below could be checked"
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    echo "  ✗ not a directory: $dir"
    return 1
  fi

  echo "Directory: $dir"

  # ---- 1. What the remote says --------------------------------------------
  echo
  echo "Remotes (routing follows these, not \$PWD — #67):"
  local i
  _gh_repo_remotes "$dir"
  case "$_GH_REMOTE_STATE" in
    git-error)  _doctor_bad "git cannot read this directory — the remote is UNKNOWN, so nothing below infers a route from it"
                echo "    A malformed ~/.gitconfig does this, and ~/.gitconfig is a managed symlink in this repo." ;;
    no-repo)    _doctor_note "not a git repository" ;;
    no-remotes) _doctor_note "git repository with no remotes" ;;
    ok)
      for (( i = 1; i <= ${#_GH_REMOTE_NAMES[@]}; i++ )); do
        if [[ -n "${_GH_REMOTE_OWNERS[i]}" ]]; then
          _doctor_note "${_GH_REMOTE_NAMES[i]} -> ${_GH_REMOTE_URLS[i]}  (owner: ${_GH_REMOTE_OWNERS[i]})"
        else
          _doctor_note "${_GH_REMOTE_NAMES[i]} -> ${_GH_REMOTE_URLS[i]}  (not a GitHub remote)"
        fi
      done ;;
  esac

  # The WHOLE table, before the lookup. A route whose config dir is missing or
  # unauthenticated is only reported by the lookup when that route happens to
  # match — so on the day it does match, the fault is new and unexplained. It is
  # also how a `$HOME/...` entry written in single quotes disappears: the literal
  # path never exists, the route silently never fires, and the repo it was meant
  # to route quietly gets whatever the keyring hands out.
  echo "Routing table:"
  local j
  if (( ${#GH_ACCOUNT_ROUTES[@]} == 0 )) && [[ -z "$GH_ACCOUNT_DEFAULT_DIR" ]]; then
    _doctor_warn "empty — set GH_ACCOUNT_ROUTES / GH_ACCOUNT_DEFAULT_DIR (see zsh/functions/github.sh)"
  else
    _gh_configured_dirs
    for (( j = 1; j <= ${#_GH_CONFIGURED_DIRS[@]}; j++ )); do
      local cd_="${_GH_CONFIGURED_DIRS[j]}" why_="${_GH_CONFIGURED_WHY[j]}" cu_=""
      if [[ ! -d "$cd_" ]]; then
        _doctor_bad "$why_ -> $cd_ — no such directory, so that route can never fire"
      elif cu_="$(_gh_config_dir_user "$cd_")" && [[ -n "$cu_" ]]; then
        _doctor_ok "$why_ -> ${cd_/#$HOME/~} (declares: $cu_)"
      else
        _doctor_bad "$why_ -> ${cd_/#$HOME/~} declares no github.com user (gh auth login there?)"
      fi
    done
  fi

  echo "Route for this directory:"
  local want_dir="" want_user=""
  if (( ${#GH_ACCOUNT_ROUTES[@]} == 0 )) && [[ -z "$GH_ACCOUNT_DEFAULT_DIR" ]]; then
    _doctor_note "skipped — no routing table"
  else
    _gh_route_for "$dir"
    case "$_GH_ROUTE_STATE" in
      matched|default)
        want_dir="$_GH_ROUTE_DIR"
        if [[ ! -d "$want_dir" ]]; then
          _doctor_bad "$_GH_ROUTE_WHY -> $want_dir, which does not exist"
        else
          want_user="$(_gh_config_dir_user "$want_dir")" || want_user=""
          if [[ -n "$want_user" ]]; then
            _doctor_ok "$_GH_ROUTE_WHY -> $want_dir (declares: $want_user)"
          else
            _doctor_bad "$_GH_ROUTE_WHY -> $want_dir, which declares no user (gh auth login there?)"
          fi
        fi ;;
      bad-table)
        _doctor_bad "routing table UNUSABLE — $_GH_ROUTE_WHY"
        echo "    Nothing below that compares against the route is a clean bill of health." ;;
      git-error)
        _doctor_bad "$_GH_ROUTE_WHY" ;;
      none)
        _doctor_warn "$_GH_ROUTE_WHY — the remote does not determine an account here" ;;
      no-repo|no-remotes)
        _doctor_note "$_GH_ROUTE_WHY" ;;
    esac
  fi

  # ---- 2. What gh will actually do ----------------------------------------
  echo
  echo "In effect (what gh does from this shell):"
  # Removing the Atrium deferral took a capability with it: there is no longer
  # any way for a supervisor that provisions per-session credentials to say
  # "leave this shell alone". One explicit switch restores it with no guessing —
  # and, unlike sniffing $ATRIUM or a tmux socket name, it lets the doctor
  # report a deliberately-unrouted shell as such instead of as a fault.
  if [[ -n "${GH_ACCOUNT_ROUTING_OFF:-}" ]]; then
    _doctor_note "\$GH_ACCOUNT_ROUTING_OFF is set — this shell is deliberately not routed; whatever set GH_CONFIG_DIR/GH_TOKEN owns them"
  fi
  local active_dir; active_dir="$(_gh_active_config_dir)"
  _gh_token_source
  case "$_GH_TOKEN_SOURCE" in
    GH_TOKEN)     _doctor_note "credential: \$GH_TOKEN (pins the account; overrides the config dir)" ;;
    GITHUB_TOKEN) _doctor_note "credential: \$GITHUB_TOKEN (pins the account; overrides the config dir)" ;;
    config-dir)   _doctor_note "credential: the config dir's keyring entry — which is keyed by HOST, not by dir" ;;
  esac
  _doctor_note "config dir: $active_dir${GH_CONFIG_DIR:+ (\$GH_CONFIG_DIR)}"

  local decl_user=""
  decl_user="$(_gh_config_dir_user "$active_dir")" || decl_user=""
  if [[ -n "$decl_user" ]]; then
    _doctor_note "declared account: $decl_user   (this is what \`gh auth status\` reports)"
  else
    _doctor_warn "declared account: none — $active_dir has no user for github.com"
  fi

  # The probe below reads THIS shell's environment, which the chpwd hook pinned
  # for $PWD. When a different directory was asked about, that answer describes
  # the shell, not the argument — comparing it against the argument's route
  # produced a confident ✗ ("Commits, PRs and API writes from here land under
  # the wrong account") for a state that cannot occur, because cd-ing there
  # would repin first. Say which question is being answered, and do not run the
  # comparison that only makes sense for $PWD.
  dir_is_pwd=1
  [[ "${dir:A}" == "${PWD:A}" ]] || dir_is_pwd=0
  (( dir_is_pwd )) || _doctor_note "this section describes the CURRENT shell (\$PWD), not $dir — cd there to pin its own account"

  local eff_user=""
  if (( offline )); then
    _doctor_warn "effective account: NOT CHECKED (--offline) — declared is not effective, that is the whole bug"
  elif _gh_probe_login "" -; then
    eff_user="$_GH_PROBE_LOGIN"
    _doctor_note "effective account: $eff_user   (GET /user)"
  else
    _doctor_bad "effective account: UNKNOWN — $_GH_PROBE_ERR"
    echo "    Everything below that compares against it is skipped, not passed."
  fi

  echo "Agreement:"
  if (( offline )); then
    _doctor_note "skipped — --offline cannot answer the only question that matters"
  elif [[ -n "$decl_user" && -n "$eff_user" ]]; then
    if [[ "${decl_user:l}" == "${eff_user:l}" ]]; then
      _doctor_ok "declared == effective ($eff_user)"
    else
      _doctor_bad "declared '$decl_user' but the API answers as '$eff_user'"
      echo "    gh auth status is describing intent, not effect."
    fi
  elif (( ! offline )) && [[ -z "$eff_user" ]]; then
    _doctor_warn "declared vs effective: skipped — the effective account is unknown"
  fi

  if [[ -n "$want_user" && -n "$eff_user" ]] && [[ -n "${GH_ACCOUNT_ROUTING_OFF:-}" ]]; then
    # The opt-out previously suppressed only the "no route determined" warning,
    # so a deliberately-unrouted shell inside a repo that DOES match a route
    # still got "✗ … land under the wrong account" and a non-zero exit — the
    # exact false alarm the switch exists to prevent.
    _doctor_note "route vs effective: not compared — \$GH_ACCOUNT_ROUTING_OFF is set, so '$eff_user' is whatever provisioned this shell"
  elif [[ -n "$want_user" && -n "$eff_user" ]] && (( ! dir_is_pwd )); then
    _doctor_note "route vs effective: this shell is '$eff_user'; for $dir see the routed-account probe below"
  elif [[ -n "$want_user" && -n "$eff_user" ]]; then
    if [[ "${want_user:l}" == "${eff_user:l}" ]]; then
      _doctor_ok "the remote routes to '$want_user', and that is who gh is"
    else
      _doctor_bad "the remote routes to '$want_user', but gh is '$eff_user'"
      echo "    Commits, PRs and API writes from here land under the wrong account."
    fi
  elif [[ -n "$want_user" ]] && (( ! offline )); then
    _doctor_warn "route vs effective: skipped — the effective account is unknown"
  elif [[ -z "$want_dir" && -n "$eff_user" ]] && (( dir_is_pwd )) && [[ -z "${GH_ACCOUNT_ROUTING_OFF:-}" ]]; then
    _doctor_warn "no route determined an account, yet gh is authenticated as '$eff_user' — that account was chosen by something other than the remote"
  fi

  # For an argument directory, the question "which account would I be there?"
  # is answerable — it is the routed dir's own per-user token, which is exactly
  # what the chpwd hook would pin. Skipping it turned the advertised
  # `gh-doctor ~/some/repo` form into a note, which is a suppression rather than
  # a fix: the one question a user asks about another repo could then only be
  # answered by cd-ing into it.
  if (( ! dir_is_pwd )) && [[ -n "$want_dir" && -n "$want_user" ]] && (( ! offline )); then
    echo "Routed account for $dir (what a shell there would be pinned to):"
    local rt
    rt="$(_gh_user_token "$want_dir" "$want_user")" || rt=""
    if [[ -z "$rt" ]]; then
      _doctor_warn "no per-user token for $want_user — a shell there could not be pinned either"
    elif _gh_probe_login "$want_dir" "$rt"; then
      if [[ "${_GH_PROBE_LOGIN:l}" == "${want_user:l}" ]]; then
        _doctor_ok "resolves to $_GH_PROBE_LOGIN, which is what the remote routes to"
      else
        _doctor_bad "routes to '$want_user' but its own token resolves to '$_GH_PROBE_LOGIN'"
      fi
    else
      _doctor_warn "could not resolve — $_GH_PROBE_ERR"
    fi
  fi

  # ---- 3. Does GH_CONFIG_DIR isolate the credential? ----------------------
  # Probed per config dir with the token env cleared, which is the state every
  # `env -u GH_TOKEN gh ...` invocation runs in.
  #
  # A MISMATCH HERE IS A WARNING, NOT A FAILURE, and that distinction is the
  # reason the section is worth reading. The collapse is a property of gh —
  # tokens keyed by host, not by config dir — and no configuration on this
  # machine can repair it. Reporting an unfixable condition as a failure made
  # gh-doctor exit 1 on EVERY run, which is the state CLAUDE.md already warns
  # about in this repo ("reporting it as one made the doctor exit non-zero
  # forever") and which this command exists to avoid: a checker that always
  # fails cannot be wired into anything, and people stop reading it.
  #
  # So this section reads as the RATIONALE for pinning — here is the collapse,
  # and here is proof the per-user token still defeats it — while ✗ is kept for
  # states someone can act on: the route disagreeing with the effective
  # account, a route dir that does not exist, an unreachable API, and the one
  # below where even the per-user token resolves to the wrong login.
  echo
  echo "Credential isolation (GH_CONFIG_DIR with no \$GH_TOKEN):"
  if (( offline )); then
    _doctor_warn "NOT CHECKED (--offline)"
  else
    local -a probe_dirs seen
    # Declared here, not in the loop: zsh's `local` on a name that already exists
    # in this scope is a DISPLAY command, so `local du` inside the loop printed
    # `du=zvi-quantivly` into the report on every iteration after the first.
    local d du ut
    _gh_configured_dirs
    probe_dirs=("${XDG_CONFIG_HOME:-$HOME/.config}/gh" "${_GH_CONFIGURED_DIRS[@]}")
    seen=()
    for d in "${probe_dirs[@]}"; do
      # The default dir is commonly also a route dir; probe each one once.
      (( ${seen[(Ie)$d]} )) && continue
      seen+=("$d")
      # A missing dir is already a ✗ in the table check above; do not count it
      # twice, and do not silently pass over it either.
      [[ -d "$d" ]] || continue
      du="$(_gh_config_dir_user "$d")" || du=""
      if [[ -z "$du" ]]; then
        _doctor_note "${d/#$HOME/~}: declares no user — skipped"
        continue
      fi
      if _gh_probe_login "$d" ""; then
        if [[ "${_GH_PROBE_LOGIN:l}" == "${du:l}" ]]; then
          _doctor_ok "${d/#$HOME/~}: declares $du, resolves to $_GH_PROBE_LOGIN"
        else
          _doctor_warn "${d/#$HOME/~}: declares $du, resolves to $_GH_PROBE_LOGIN — the dir does NOT isolate the credential (gh keys tokens by host; this is why \$GH_TOKEN is pinned)"
        fi
      else
        _doctor_warn "${d/#$HOME/~}: declares $du, could not resolve — $_GH_PROBE_ERR"
      fi

      # The fix, verified rather than asserted: does the per-user keyring entry
      # give a token that really is this account? If this fails, pinning
      # GH_TOKEN is not a workaround either and the account needs re-login.
      ut="$(_gh_user_token "$d" "$du")" || ut=""
      if [[ -z "$ut" ]]; then
        _doctor_warn "${d/#$HOME/~}: no per-user token for $du (gh auth token --user) — GH_TOKEN cannot pin it"
      elif _gh_probe_login "$d" "$ut"; then
        if [[ "${_GH_PROBE_LOGIN:l}" == "${du:l}" ]]; then
          _doctor_ok "${d/#$HOME/~}: pinned with its per-user token, resolves to $_GH_PROBE_LOGIN"
        else
          # Unlike the line above this one is fixable, and it breaks pinning:
          # the workaround the whole design rests on fails for that account.
          _doctor_bad "${d/#$HOME/~}: even the per-user token for $du resolves to $_GH_PROBE_LOGIN — re-run \`gh auth login\` in that config dir"
        fi
      else
        _doctor_warn "${d/#$HOME/~}: per-user token for $du could not resolve — $_GH_PROBE_ERR"
      fi
    done
  fi

  # ---- 4. Git identity, which routes on the same signal -------------------
  # gh opening a PR as one account while git authored the commits as another is
  # a real and confusing state, and both are supposed to key off the remote.
  echo
  echo "Git identity here (same signal — #67):"
  if [[ "$_GH_REMOTE_STATE" == "git-error" ]]; then
    # Two of the three _GH_REMOTE_STATE consumers were taught about git-error
    # and this one was missed, so it announced "user.email is unset" — a
    # confident, wrong diagnosis — when git simply could not be read.
    _doctor_note "git could not be read here, so the identity is unknown too"
  elif [[ "$_GH_REMOTE_STATE" == "no-repo" ]]; then
    _doctor_note "not a git repository"
  else
    local gname gmail
    gname="$(command git -C "$dir" config --get user.name 2>/dev/null)"
    gmail="$(command git -C "$dir" config --get user.email 2>/dev/null)"
    if [[ -z "$gmail" ]]; then
      _doctor_bad "user.email is unset — commits here would be rejected or misattributed"
    else
      _doctor_note "${gname:-(no name)} <$gmail>"
    fi
  fi

  echo
  _doctor_summary "gh acts as the account this repo's remote routes to." \
    "Start with the route: a missing config dir, an account with no per-user token, or a remote no route matches."
}
