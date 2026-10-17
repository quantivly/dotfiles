#!/usr/bin/env bash
#
# scripts/tmpdir-clean.sh
# =======================
#
# The cleanup half of the TMPDIR redirect: ages out ~/.cache/tmp with
# systemd-tmpfiles, after guarding the registered git worktrees that live there.
# Run daily by systemd/tmpdir-clean.timer. Why it exists, and what was measured
# before it was written: docs/TMPDIR.md.
#
# THE AGES AND THE ROOT are not here. They are in config/user-tmpfiles.d/tmpdir.conf
# (7 days for the root, 14 for Claude Code's claude-<uid>/), and systemd-tmpfiles
# applies them, so a human running `systemd-tmpfiles --user --clean` by hand
# gets the same ages. The root this script walks is that file's first `d` line,
# so the guard cannot walk a different tree from the one being aged. A line
# there aging a path outside that root makes the run refuse.
#
# THE GUARD. A registered worktree under the root (a Claude scratchpad worktree, a
# review checkout) keeps its host metadata OUTSIDE the root, in the host
# repository's .git/worktrees/<name>. Aging the checkout out loses its
# uncommitted files and, after a later `git worktree prune`, any commit only it
# could reach. So every such worktree gets an `x <path>` line, which makes
# systemd-tmpfiles skip that subtree. Clones are not guarded: a clone under the
# root is temp by construction.
#
#   * A `.git` FILE is a worktree iff the gitdir it names points back at it
#     (realpath of "$gitdir/gitdir" == the .git file). A submodule's .git file
#     names a gitdir with no back-pointer, so it is not guarded. Each pointer
#     file is read as git reads it, whole, with trailing CR and LF stripped: a
#     CRLF .git file is a worktree, and a back-pointer with a newline in it is
#     seen whole (and refused, below), not cut at the newline.
#   * "No back-pointer" means the lookup found nothing there. A git dir this
#     user cannot search hides the answer, and makes the run refuse.
#   * The host is "$gitdir/commondir". A host INSIDE the root is temp too, and the
#     worktree ages out with it.
#   * An `x` line is a glob, and tmpfiles.d unquotes and expands specifiers, so a
#     path with whitespace, a control character, `%`, `*`, `?`, `[`, a backslash
#     or a quote cannot be written as an exact path. Such a worktree makes the
#     run REFUSE (exit 2), as does a failing `find` or an unreadable .git file:
#     never clean on a partial guard.
#   * The x line is the path as find spelled it under the root, through any
#     symlink in $HOME. That is the spelling systemd-tmpfiles matches; a
#     realpath'd line is not honoured (measured, systemd 259).
#   * The walk has no depth limit (systemd-tmpfiles has none worth the name).
#     It skips a directory this user cannot read or search, which
#     systemd-tmpfiles cannot enter either ("failed, ignoring", exit 0), so a
#     non-zero find is a real error. It does not look inside node_modules or
#     .git directories, so a worktree in one of those is NOT guarded.
#
# The guard is written atomically to $XDG_RUNTIME_DIR/user-tmpfiles.d/, which is
# on the user search path, so a hand-run `systemd-tmpfiles --user --clean` sees
# it too. It is a snapshot: a worktree created after the last run is unguarded
# until the next one.
#
# ONLY THIS CHECKOUT'S RULES ARE APPLIED. systemd-tmpfiles is given the config and
# the guard by path, so a run never applies some other user-tmpfiles.d rule for
# the first time, unattended, as a side effect.
#
# A ROOT THAT IS A SYMLINK is a refusal. systemd-tmpfiles does not follow it, so
# the clean deletes nothing and exits 0, and the log would read as a clean run.
#
# --dry-run passes --dry-run to systemd-tmpfiles, which has it only from systemd
# 256. On an older one this exits 2 rather than falling through to a real clean.
#
# --check is the verify-tools.sh assertion, kept here so it is testable on its
# own: FAIL when the TMPDIR redirect is linked but tmpdir-clean.timer is not
# enabled, unless TMPDIR_CLEAN_OFF says that is deliberate; WARN when the vendor
# systemd-tmpfiles-clean.timer is enabled too (it runs without the guard). No
# user manager, or no redirect, is a skip.
#
# --install is ./install's step, here for the same reason. It ENABLES AND STARTS
# tmpdir-clean.timer: a Persistent= timer started with no stamp file does not
# fire at start (docs/TMPDIR.md has the source and the probe), and enabling
# without starting left check-timer-health failing it until the next boot.
# With TMPDIR_CLEAN_OFF set it turns the timer off instead: stop, and remove the
# .wants link enable made. Never `systemctl disable`, which also deletes the
# dotbot symlink that IS the unit. Exits 0 when systemctl fails, so an install
# is not failed by it; --check is what reports.
#
# THE OPT-OUT: export TMPDIR_CLEAN_OFF=1 in ~/.zshrc.local, then ./install. It is
# read by --install and --check, so it must be in the environment of whatever
# runs them. The timer never sees it; ./install turns the timer off.
#
# Every run appends one line to $XDG_STATE_HOME/tmpdir-clean/log: mode, guarded
# worktrees, the systemd-tmpfiles exit status, used bytes and inodes on the
# root's filesystem before and after, and seconds.
#
# EXIT STATUS
#   0  cleaned (systemd-tmpfiles exited 0, or 65: a line it could not parse,
#      echoed to the journal), --check found nothing wrong, or --install ran
#   1  systemd-tmpfiles failed, or --check found the timer not enabled
#   2  COULD NOT RUN, and nothing was deleted: an unencodable worktree path, a
#      failing find, an unreadable .git file or back-pointer, a git dir that
#      cannot be searched, a root that is a symlink, a config the root cannot be
#      read from, no runtime dir, or --dry-run on systemd < 256
#
# Usage: scripts/tmpdir-clean.sh [--dry-run | --check | --install]
#
# Environment (the state table uses these):
#   TMPDIR_CLEAN_OFF        set: the cleanup is deliberately off (see above)
#   TMPDIR_CLEAN_CONFIG     tmpfiles.d file (default: ~/.config/user-tmpfiles.d/tmpdir.conf)
#   TMPDIR_CLEAN_GUARD_DIR  where the guard goes (default: $XDG_RUNTIME_DIR/user-tmpfiles.d)
#   TMPDIR_CLEAN_STATE      state dir (default: $XDG_STATE_HOME/tmpdir-clean)
#   TMPDIR_CLEAN_TMPFILES   systemd-tmpfiles to run (default: from PATH)
#   TMPDIR_CLEAN_ENV_LINK   --check: the redirect (default: ~/.config/environment.d/tmpdir.conf)
#   SYSTEMD_USER_DIR        --install: where the units are linked (default: ~/.config/systemd/user)

set -uo pipefail

MODE=apply
for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE=dry ;;
    --check)   MODE=check ;;
    --install) MODE=install ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'tmpdir-clean: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONF="${TMPDIR_CLEAN_CONFIG:-$CONFIG_HOME/user-tmpfiles.d/tmpdir.conf}"
GUARD_DIR="${TMPDIR_CLEAN_GUARD_DIR:-${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/user-tmpfiles.d}}"
STATE="${TMPDIR_CLEAN_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/tmpdir-clean}"
TMPFILES="${TMPDIR_CLEAN_TMPFILES:-systemd-tmpfiles}"
UNIT_DIR="${SYSTEMD_USER_DIR:-$CONFIG_HOME/systemd/user}"
TIMER=tmpdir-clean.timer

refuse() { printf 'tmpdir-clean: REFUSING, nothing deleted: %s\n' "$*" >&2; exit 2; }
have_manager() { command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# --install
# ---------------------------------------------------------------------------
if [[ "$MODE" == install ]]; then
  # Not linked (./install --herdr links none of this): nothing to enable.
  [[ -L "$UNIT_DIR/$TIMER" ]] || exit 0
  if ! have_manager; then
    printf '○ no systemd user manager reachable — %s not enabled\n' "$TIMER"
    exit 0
  fi
  enabled="$(systemctl --user is-enabled "$TIMER" 2>/dev/null)"
  active="$(systemctl --user is-active "$TIMER" 2>/dev/null)"
  if [[ -n "${TMPDIR_CLEAN_OFF:-}" ]]; then
    if [[ "$enabled" != enabled && "$active" != active ]]; then
      printf '○ TMPDIR_CLEAN_OFF is set: %s left off, so ~/.cache/tmp is not aged out\n' "$TIMER"
      exit 0
    fi
    off=1
    systemctl --user stop "$TIMER" || off=0
    for w in "$UNIT_DIR"/*.wants/"$TIMER"; do
      [[ -L "$w" ]] || continue
      rm -f "$w" 2>/dev/null
      [[ -L "$w" ]] && off=0
    done
    systemctl --user daemon-reload || off=0
    if (( off )); then
      printf '○ TMPDIR_CLEAN_OFF is set: %s stopped and its .wants link removed.\n' "$TIMER"
      printf '  The unit stays linked; unset TMPDIR_CLEAN_OFF and ./install to turn it back on.\n'
    else
      printf '⚠ TMPDIR_CLEAN_OFF is set, but %s could not be turned off. Stop it and\n' "$TIMER" >&2
      printf '  remove %s/*.wants/%s by hand — NOT systemctl disable.\n' "$UNIT_DIR" "$TIMER" >&2
    fi
    exit 0
  fi
  if [[ "$enabled" == enabled && "$active" == active ]]; then
    printf '✓ %s already enabled and running\n' "$TIMER"
  elif systemctl --user daemon-reload && systemctl --user enable --now "$TIMER"; then
    printf '✓ Enabled and started %s: it ages out ~/.cache/tmp daily at 05:15.\n' "$TIMER"
    printf '  The first run is the next 05:15, not now (unless it ran here before and has\n'
    printf '  missed one since). Read a dry run before then:\n'
    printf '    ~/.dotfiles/scripts/tmpdir-clean.sh --dry-run\n'
    printf '  Turning it off: TMPDIR_CLEAN_OFF=1 in ~/.zshrc.local, then ./install.\n'
  else
    printf '⚠ could not enable and start %s — scripts/verify-tools.sh will FAIL until it is\n' "$TIMER" >&2
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if [[ "$MODE" == check ]]; then
  link="${TMPDIR_CLEAN_ENV_LINK:-$CONFIG_HOME/environment.d/tmpdir.conf}"
  if [[ ! -L "$link" ]]; then
    printf '  ○ the TMPDIR redirect (%s) is not linked — skipped\n' "$link"
    exit 0
  fi
  if ! have_manager; then
    printf '  ○ no systemd user manager reachable — skipped\n'
    exit 0
  fi
  rc=0
  state="$(systemctl --user is-enabled "$TIMER" 2>/dev/null)"
  if [[ -n "${TMPDIR_CLEAN_OFF:-}" ]]; then
    printf '  ○ TMPDIR_CLEAN_OFF is set: the cleanup is deliberately off, and ~/.cache/tmp\n'
    printf '      is not aged out. Unset it and ./install to turn it back on.\n'
    if [[ "$state" == enabled ]]; then
      printf '  ⚠ ...but %s is still enabled. ./install turns it off.\n' "$TIMER"
    fi
  elif [[ "$state" == enabled ]]; then
    printf '  ✓ %s is enabled, so ~/.cache/tmp is aged out\n' "$TIMER"
  else
    printf '  ✗ TMPDIR is redirected to ~/.cache/tmp, but %s is %s —\n' "$TIMER" "${state:-not found}"
    printf '      nothing ages that directory out, and it grows without limit.\n'
    printf '      Fix: ./install (it enables and starts the timer). To turn the cleanup\n'
    printf '      off deliberately: TMPDIR_CLEAN_OFF=1 in ~/.zshrc.local, then ./install.\n'
    rc=1
  fi
  if [[ "$(systemctl --user is-enabled systemd-tmpfiles-clean.timer 2>/dev/null)" == enabled ]]; then
    printf '  ⚠ the vendor systemd-tmpfiles-clean.timer is enabled too. It applies\n'
    printf '      tmpdir.conf WITHOUT the worktree guard, so a registered worktree under\n'
    printf '      ~/.cache/tmp can be aged out. systemctl --user disable systemd-tmpfiles-clean.timer\n'
  fi
  exit "$rc"
fi

# ---------------------------------------------------------------------------
# Preconditions. Each one is checked before anything is written.
# ---------------------------------------------------------------------------
[[ -r "$CONF" ]] || refuse "cannot read the tmpfiles.d config $CONF"

# The root is the config's first `d` line, and every line must age a path inside
# it, because that root is the only tree the guard walks. %h and %U are the only
# specifiers expanded; any other, or a quoted path, is a refusal rather than a
# guess at what systemd-tmpfiles would read.
ROOT=""
CPATHS=()
while IFS= read -r cl || [[ -n "$cl" ]]; do
  ctype="" cpath=""
  read -r ctype cpath _ <<< "$cl"
  [[ -z "$ctype" || "$ctype" == \#* ]] && continue
  p="${cpath//%h/"$HOME"}"
  p="${p//%U/"$(id -u)"}"
  p="${p%/}"
  [[ "$p" == /* ]] || refuse "$CONF: '$cpath' is not an absolute path (a quoted one is not read here)"
  [[ "$p" != *%* ]] || refuse "$CONF: '$cpath' has a specifier this script does not expand (only %h and %U)"
  [[ "$ctype" == d && -z "$ROOT" ]] && ROOT="$p"
  CPATHS+=("$p")
done < "$CONF"
[[ -n "$ROOT" ]] || refuse "$CONF has no d line, so there is no root to guard"
for p in "${CPATHS[@]}"; do
  case "$p/" in
    "$ROOT"/*) ;;
    *) refuse "$CONF ages $p, outside $ROOT, the only tree the worktree guard walks" ;;
  esac
done

[[ -L "$ROOT" ]] && refuse "$ROOT is a symlink. systemd-tmpfiles does not follow it, so a clean would delete nothing and still exit 0"
if [[ ! -d "$ROOT" ]]; then
  printf 'tmpdir-clean: nothing to do — %s does not exist\n' "$ROOT"
  exit 0
fi
[[ -n "$GUARD_DIR" ]] || refuse "XDG_RUNTIME_DIR is not set, so there is nowhere to write the worktree guard"
command -v "$TMPFILES" >/dev/null 2>&1 || refuse "$TMPFILES is not available"

if [[ "$MODE" == dry ]]; then
  ver="$("$TMPFILES" --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
  [[ "$ver" =~ ^[0-9]+$ ]] || refuse "could not read the systemd version from '$TMPFILES --version'"
  (( ver >= 256 )) || refuse "--dry-run needs systemd >= 256, and this is $ver; a real clean is not a dry run"
fi

mkdir -p "$STATE" || refuse "could not create $STATE"
mkdir -p "$GUARD_DIR" || refuse "could not create $GUARD_DIR"

# A path systemd-tmpfiles would read back as exactly itself: no whitespace or
# control characters (word splitting), no specifier, no glob, no escape or quote.
encodable() {
  case "$1" in
    *[[:space:][:cntrl:]]* | *%* | *\** | *\?* | *\[* | *\\* | *\"* | *\'*) return 1 ;;
  esac
  return 0
}

# A git pointer file (.git, gitdir, commondir) as git reads it: the whole file,
# trailing CR and LF stripped. Fails, rather than returning empty, when
# unreadable; an empty file is readable and empty. git rejects a .git file over
# 4 x PATH_MAX as too large, so more than that is never needed.
read_ptr() {
  local c
  [[ -r "$1" ]] || return 1
  c="$(head -c 16384 -- "$1")" || return 1
  while [[ "$c" == *$'\r' || "$c" == *$'\n' ]]; do c="${c%?}"; done
  printf '%s' "$c"
}

# Is $1 absent, present, or hidden behind a directory this user cannot search?
# [[ -e ]] is false both for "not there" and for EACCES. The nearest ancestor
# that resolves decides: if it is a directory this user can search, the next
# component really is not there. 0 absent, 1 present, 2 cannot tell, with the
# directory that hides it in $BLOCKER.
lookup() {
  local p="$1"
  BLOCKER=""
  [[ -e "$p" || -L "$p" ]] && return 1
  while [[ "$p" == /?* ]]; do
    p="${p%/*}"
    p="${p:-/}"
    if [[ -e "$p" ]]; then
      if [[ -d "$p" && ! -x "$p" ]]; then BLOCKER="$p"; return 2; fi
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Find the worktrees to guard.
# ---------------------------------------------------------------------------
START=$SECONDS
LIST="$STATE/gitfiles.list"
FINDERR="$STATE/find.err"
# -ignore_readdir_race: the root is a live TMPDIR, and an entry deleted between
# readdir and stat is otherwise an error and a non-zero exit. A directory this
# user cannot read, or cannot search, is pruned: systemd-tmpfiles cannot enter it
# either (it logs "failed, ignoring" and exits 0), so it hides nothing that could
# be deleted. Each half is needed alone: d--x fails the walk at readdir, dr-- at
# the stat of each entry. What is left is a real error, and a real error means
# the guard may be partial.
find "$ROOT" -ignore_readdir_race \
  \( -type d \( ! -readable -o ! -executable \) -prune \) -o \
  \( -type d \( -name node_modules -o -name .git \) -prune \) -o \
  \( -type f -name .git -print0 \) > "$LIST" 2> "$FINDERR"
frc=$?
if (( frc != 0 )); then
  sed 's/^/  /' "$FINDERR" >&2
  refuse "find exited $frc while looking for worktrees under $ROOT"
fi

ROOT_REAL="$(realpath -m -- "$ROOT")"
GUARDS=()
while IFS= read -r -d '' gitfile; do
  wt="${gitfile%/.git}"
  line="$(read_ptr "$gitfile")" || refuse "cannot read $gitfile"
  [[ "$line" == "gitdir: "* ]] || continue
  gd="${line#gitdir: }"
  [[ "$gd" == /* ]] || gd="$wt/$gd"
  # No back-pointer: a submodule, or a worktree whose registration is gone.
  lookup "$gd/gitdir"
  case $? in
    0) continue ;;
    2) refuse "cannot search $(printf '%q' "$BLOCKER"), so cannot tell whether $(printf '%q' "$wt") is a registered worktree" ;;
  esac
  back="$(read_ptr "$gd/gitdir")" || refuse "cannot read $gd/gitdir"
  [[ "$back" == /* ]] || back="$gd/$back"
  [[ "$(realpath -m -- "$back")" == "$(realpath -m -- "$gitfile")" ]] || continue
  # A registered worktree whose host cannot be read is guarded: it cannot be
  # shown to be temp.
  if common="$(read_ptr "$gd/commondir" 2>/dev/null)"; then
    [[ "$common" == /* ]] || common="$gd/$common"
    case "$(realpath -m -- "$common")/" in
      "$ROOT_REAL"/*) continue ;;
    esac
  fi
  encodable "$wt" || refuse "registered worktree $(printf '%q' "$wt") has a path an x line cannot express exactly"
  GUARDS+=("$wt")
done < "$LIST"

GUARD="$GUARD_DIR/tmpdir-worktrees.conf"
gtmp="$(mktemp "$GUARD_DIR/.tmpdir-worktrees.XXXXXX")" || refuse "could not create a temp file in $GUARD_DIR"
if ! {
  printf '# Written by %s at %s. Registered git worktrees under %s\n' \
    "${0##*/}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROOT"
  printf '# whose host repository is outside it. Rewritten on every run.\n'
  for wt in "${GUARDS[@]}"; do printf 'x %s\n' "$wt"; done
} > "$gtmp" || ! mv -f "$gtmp" "$GUARD"; then
  rm -f "$gtmp"
  refuse "could not write $GUARD"
fi

# ---------------------------------------------------------------------------
# Clean.
# ---------------------------------------------------------------------------
usage() { df -B1 --output=used,iused "$ROOT" 2>/dev/null | awk 'NR == 2 { print $1, $2 }'; }
read -r used0 inodes0 <<< "$(usage)"

ARGS=(--user --clean)
[[ "$MODE" == dry ]] && ARGS+=(--dry-run)
"$TMPFILES" "${ARGS[@]}" "$CONF" "$GUARD"
rc=$?

read -r used1 inodes1 <<< "$(usage)"
printf '%s mode=%s guarded=%s rc=%s used=%s->%s inodes=%s->%s seconds=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "${#GUARDS[@]}" "$rc" \
  "${used0:-?}" "${used1:-?}" "${inodes0:-?}" "${inodes1:-?}" "$(( SECONDS - START ))" \
  | tee -a "$STATE/log"

case "$rc" in
  0) exit 0 ;;
  65) printf 'tmpdir-clean: systemd-tmpfiles exited 65: a line in %s or the guard could not be parsed\n' "$CONF" >&2
      exit 0 ;;
  *) printf 'tmpdir-clean: systemd-tmpfiles exited %s\n' "$rc" >&2; exit 1 ;;
esac
