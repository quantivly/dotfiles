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
#     systemd-tmpfiles cannot enter either (it logs "Opening directory ...
#     failed" and counts it in FAILED, below), so a non-zero find is a real
#     error. It does not look inside node_modules or .git directories, so a
#     worktree in one of those is NOT guarded.
#
# The guard is written atomically to $XDG_RUNTIME_DIR/user-tmpfiles.d/, which is
# on the user search path, so a hand-run `systemd-tmpfiles --user --clean` sees
# it too. It is a snapshot: a worktree created after the last run is unguarded
# until the next one.
#
# NON-WRITABLE DIRECTORIES. Removing an entry needs write on the directory it is
# in, so an old file in a directory with no write bit can never be aged out, and
# neither can an old directory inside one (a non-empty one too: rmdir checks
# permission before emptiness). Go makes its module cache mode 555, and tests put
# throwaway GOPATHs under $TMPDIR. So once the guard is written, this script runs
# `chmod u+w` on every directory under the root that
#   * this user owns and has no user write bit on,
#   * is old by the line that governs it (the deepest config line whose path is
#     above it), by that line's own age and age-by directory letters, read from
#     the config: with the shipped abcmBM, btime and mtime. An age-by with no
#     directory letter means ABM, as it does to systemd-tmpfiles. A btime the
#     filesystem does not record reads as 0, as it does for systemd-tmpfiles,
#     so both judge that directory by mtime alone. A timestamp that cannot be
#     read keeps the directory as it is, and so does a line that ages nothing,
#   * and is not inside a guarded worktree (each is pruned).
# The walk is find -P -xdev: it follows no symlink and stays on the root's
# device. That is not systemd-tmpfiles' mount check (it skips any mount root,
# so also a bind mount of the same filesystem, which -xdev enters). It prunes
# what this user cannot read or search, as the guard's walk does, and never
# gives those u+rx: the guard's walk did not look inside them either, so a
# worktree in one would reach systemd-tmpfiles unguarded. Unlike that walk it
# does look inside node_modules and .git. Paths, atime, mtime and
# ctime come from find, byte for byte. btime comes from stat, joined on the
# inode: GNU find reads no btime where it uses fstatat (findutils 4.10 prints
# -1.-000000010), and stat prints a non-UTF-8 name lossily (uutils 0.8), so no
# name is ever read back from it.
#   Just before each chmod, which follows symlinks, the path must still resolve
# to exactly itself under the root: a symlink swapped in anywhere below the
# root since the walk makes it a warning, not a chmod outside the root or in a
# guarded worktree. That narrows the race; a shell cannot close it.
#   This changes no one's age. chmod on a directory changes its ctime only, and
# ctime is not counted for directories (it is not in abcmBM, nor in the default
# abcmABM, because deleting an entry changes it too). A file's mode never
# matters to its deletion, so files are left alone. --dry-run chmods nothing; it
# prints each directory it would change. A failed chmod, or a failing walk, is
# a warning: what it leaves behind fails its removal, which FAILED counts,
# rather than stopping a clean that is safe to run.
#
# FAILED. systemd-tmpfiles logs each path it could not remove ("Failed to
# remove") or enter ("Opening directory ... failed") and goes on. Under the
# root's d line it then exits 0, and under claude-<uid>'s e line 73 (v259
# clean_item() drops the d line's result). Neither is a reason to fail a clean
# that did everything else, and a path that keeps failing would turn the unit
# red every night. So its stderr is copied to $STATE/tmpfiles.err on its way to
# the journal, those lines are counted into the log line's failed=, the first
# few are echoed, and a 73 with at least one counted is a warning. A 73 with
# none counted is unexplained, and a failure. --check warns when three real
# runs in a row each left some.
#
# ONLY THIS CHECKOUT'S RULES ARE APPLIED. systemd-tmpfiles is given the config and
# the guard by path, so a run never applies some other user-tmpfiles.d rule for
# the first time, unattended, as a side effect.
#
# A ROOT THAT IS A SYMLINK is a refusal. systemd-tmpfiles does not follow it, so
# the clean deletes nothing and exits 0, and the log would read as a clean run.
#
# SYSTEMD 249. The age-by field (abcmBM:) arrived in systemd 249. An older
# systemd-tmpfiles fails to parse every line that has one and exits 65, which
# would make every night a clean that does nothing, logged as a success. So a
# config with an age-by on systemd < 249 exits 2.
#
# --dry-run passes --dry-run to systemd-tmpfiles, which has it only from systemd
# 256. On an older one this exits 2 rather than falling through to a real clean.
#
# --check is the verify-tools.sh assertion, kept here so it is testable on its
# own: FAIL when the TMPDIR redirect is linked but tmpdir-clean.timer is not
# enabled, unless TMPDIR_CLEAN_OFF says that is deliberate; WARN when the vendor
# systemd-tmpfiles-clean.timer is enabled too (it runs without the guard), and
# when the last three real runs each logged failed= above 0. No user manager,
# or no redirect, is a skip.
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
# worktrees, directories given u+w (in a dry run, the ones it would), the
# systemd-tmpfiles exit status, the paths it could not remove or open (failed=,
# ? if they could not be counted), used bytes and inodes on the root's
# filesystem before and after, and seconds.
#
# EXIT STATUS
#   0  cleaned (systemd-tmpfiles exited 0; 65, a line it could not parse,
#      echoed to the journal; or 73 with failed= above 0, a warning),
#      --check found nothing wrong, or --install ran
#   1  systemd-tmpfiles failed (any other status, or a 73 with no failed path
#      counted), or --check found the timer not enabled
#   2  COULD NOT RUN, and nothing was deleted: an unencodable worktree path, a
#      failing find, an unreadable .git file or back-pointer, a git dir that
#      cannot be searched, a root that is a symlink, a config the root cannot be
#      read from (an age it cannot read included), no runtime dir, an age-by on
#      systemd < 249, or --dry-run on systemd < 256
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
  # A path systemd-tmpfiles cannot remove or open is a warning on each run
  # (FAILED, in the header). One still there three real runs later may never go
  # by itself, so it is said here too: a warning, never a failure.
  if [[ -z "${TMPDIR_CLEAN_OFF:-}" && -r "$STATE/log" ]]; then
    read -r streak lastfailed <<< "$(awk '
      / mode=apply / {
        f = -1
        for (i = 1; i <= NF; i++) if ($i ~ /^failed=[0-9]+$/) f = substr($i, 8) + 0
        if (f > 0) { n++; last = f } else n = 0
      }
      END { if (n >= 3) print n, last }' "$STATE/log")"
    if [[ -n "$streak" ]]; then
      printf '  ⚠ the last %s cleans each left paths systemd-tmpfiles could not remove or\n' "$streak"
      printf '      open (failed=%s in the latest). Some may need a hand (a mode-000\n' "$lastfailed"
      printf '      directory never goes by itself):\n'
      printf '      journalctl --user -u tmpdir-clean.service -e names them.\n'
    fi
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

# A line's age as systemd-tmpfiles reads it, for the non-writable-directory
# pass: AGE_S, its length in seconds (empty: the line ages nothing), and AGE_BY,
# the timestamps it counts for directories (the age-by's uppercase letters; with
# no age-by, or one with no uppercase letter, the default abcmABM's ABM, as v259
# parse_age_by_from_arg() reads it). One number and one unit are read, and
# anything else refuses rather than guessing. AGEBY says some line has an age-by.
AGEBY=0
age_of() {
  local a="$1" by=ABM n
  AGE_S="" AGE_BY=""
  [[ -z "$a" || "$a" == - ]] && return 0
  if [[ "$a" == *:* ]]; then
    by="${a%%:*}" a="${a#*:}"
    [[ "$by" =~ ^[aAbBcCmM]+$ ]] || return 1
    by="${by//[abcm]/}"
    [[ -n "$by" ]] || by=ABM
    AGEBY=1
  fi
  [[ "$a" =~ ^([0-9]+)([a-z]*)$ ]] || return 1
  n=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in
    "" | s | sec | second | seconds) ;;
    m | min | minute | minutes) n=$((n * 60)) ;;
    h | hr | hour | hours) n=$((n * 3600)) ;;
    d | day | days) n=$((n * 86400)) ;;
    w | week | weeks) n=$((n * 604800)) ;;
    *) return 1 ;;
  esac
  AGE_S="$n" AGE_BY="$by"
}

# The root is the config's first `d` line, and every line must age a path inside
# it, because that root is the only tree the guard walks. %h and %U are the only
# specifiers expanded; any other, or a quoted path, is a refusal rather than a
# guess at what systemd-tmpfiles would read.
ROOT=""
CPATHS=() CAGES=() CBYS=()
while IFS= read -r cl || [[ -n "$cl" ]]; do
  ctype="" cpath="" cage=""
  read -r ctype cpath _ _ _ cage _ <<< "$cl"
  [[ -z "$ctype" || "$ctype" == \#* ]] && continue
  p="${cpath//%h/"$HOME"}"
  p="${p//%U/"$(id -u)"}"
  p="${p%/}"
  [[ "$p" == /* ]] || refuse "$CONF: '$cpath' is not an absolute path (a quoted one is not read here)"
  [[ "$p" != *%* ]] || refuse "$CONF: '$cpath' has a specifier this script does not expand (only %h and %U)"
  age_of "$cage" || refuse "$CONF: '$cage' on $cpath is not an age this script reads (one number and one unit, up to weeks, after an optional age-by)"
  [[ "$ctype" == d && -z "$ROOT" ]] && ROOT="$p"
  CPATHS+=("$p") CAGES+=("$AGE_S") CBYS+=("$AGE_BY")
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

if (( AGEBY )) || [[ "$MODE" == dry ]]; then
  ver="$("$TMPFILES" --version 2>/dev/null | awk 'NR == 1 { print $2 }')"
  [[ "$ver" =~ ^[0-9]+$ ]] || refuse "could not read the systemd version from '$TMPFILES --version'"
  [[ "$MODE" != dry ]] || (( ver >= 256 )) || refuse "--dry-run needs systemd >= 256, and this is $ver; a real clean is not a dry run"
  (( ver >= 249 )) || refuse "$CONF uses the age-by field, which systemd-tmpfiles reads only from systemd 249, and this is $ver: every line with one would fail to parse, and the clean would do nothing"
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
# either (it logs "Opening directory ... failed, ignoring", which FAILED counts),
# so it hides nothing that could be deleted. Each half is needed alone: d--x
# fails the walk at readdir, dr-- at the stat of each entry. What is left is a
# real error, and a real error means the guard may be partial.
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
# Give u+w back to old directories this user owns and cannot write. Only now,
# so a refusal above has changed nothing. The rule, and why it resets no
# one's age: NON-WRITABLE DIRECTORIES in the header.
# ---------------------------------------------------------------------------
NOW="$(date +%s)"
PRE="$STATE/nonwritable.list"
PREPATHS="$STATE/nonwritable.paths"
PREBT="$STATE/nonwritable.btime"
PREERR="$STATE/nonwritable.err"
pf=(find -P "$ROOT" -xdev -mindepth 1 -ignore_readdir_race)
for wt in "${GUARDS[@]}"; do pf+=(-path "$wt" -prune -o); done
pf+=(-type d \( ! -readable -o ! -executable \) -prune -o
     -type d -uid "$(id -u)" ! -perm -u=w -printf '%i %A@ %T@ %C@ %p\0')
"${pf[@]}" > "$PRE" 2> "$PREERR"
prc=$?
if (( prc != 0 )); then
  sed 's/^/  /' "$PREERR" >&2
  printf 'tmpdir-clean: find exited %s while looking for non-writable directories under %s; a removal in one it missed will fail\n' "$prc" "$ROOT" >&2
fi
# btime, by inode (why not from find, and why no name: the header). %W is 0
# where the filesystem records no btime, which reads as old below:
# systemd-tmpfiles also takes an absent btime as 0, so both judge by the rest.
while IFS= read -r -d '' rec; do printf '%s\0' "${rec#* * * * }"; done < "$PRE" > "$PREPATHS"
xargs -0 -r stat --printf '%i %W\n' -- < "$PREPATHS" > "$PREBT" 2> "$PREERR"
src=$?
declare -A BTIME=()
while read -r ino bt _; do [[ -n "$ino" ]] && BTIME[$ino]="$bt"; done < "$PREBT"

# Does $1, a directory the walk found under the root, still resolve to exactly
# itself, with no symlink anywhere below the root?
is_itself() {
  local r
  [[ -d "$1" ]] || return 1
  r="$(realpath -e -- "$1" && echo x)" || return 1
  [[ "${r%$'\n'x}" == "$ROOT_REAL${1#"$ROOT"}" ]]
}

CHMOD=0 stat_said=0
while IFS= read -r -d '' rec; do
  ino="${rec%% *}" rest="${rec#* }"
  at="${rest%% *}" rest="${rest#* }"
  mt="${rest%% *}" rest="${rest#* }"
  ct="${rest%% *}" d="${rest#* }"
  # The line that governs d: the deepest config path above it.
  gi=-1 glen=-1
  for i in "${!CPATHS[@]}"; do
    [[ "$d" == "${CPATHS[i]}"/* ]] && (( ${#CPATHS[i]} > glen )) && gi=$i glen=${#CPATHS[i]}
  done
  { (( gi >= 0 )) && [[ -n "${CAGES[gi]}" ]]; } || continue
  # Gone since the walk: nothing to change, and nothing to say.
  [[ -e "$d" || -L "$d" ]] || continue
  cutoff=$((NOW - CAGES[gi]))
  old=1
  by="${CBYS[gi]}"
  for (( k = 0; k < ${#by}; k++ )); do
    case "${by:k:1}" in
      A) t="${at%%.*}" ;;
      B) t="${BTIME[$ino]-}"
         if [[ -z "$t" ]]; then
           (( stat_said++ )) || sed 's/^/  /' "$PREERR" >&2
           printf 'tmpdir-clean: stat did not answer for %s (xargs exited %s), so it is left as it is\n' "$d" "$src" >&2
         fi ;;
      C) t="${ct%%.*}" ;;
      M) t="${mt%%.*}" ;;
    esac
    # A timestamp that is not a number keeps the directory as it is.
    if ! [[ "$t" =~ ^[0-9]+$ ]] || (( t >= cutoff )); then old=0; break; fi
  done
  (( old )) || continue
  if [[ "$MODE" == dry ]]; then
    printf 'tmpdir-clean: would restore u+w on %s\n' "$d"
    CHMOD=$((CHMOD + 1))
  elif ! is_itself "$d"; then
    printf 'tmpdir-clean: %s no longer resolves to the directory the walk found (a symlink on its path?), so it is left as it is\n' "$d" >&2
  elif chmod u+w -- "$d"; then
    CHMOD=$((CHMOD + 1))
  else
    printf 'tmpdir-clean: could not restore u+w on %s\n' "$d" >&2
  fi
done < "$PRE"

# ---------------------------------------------------------------------------
# Clean.
# ---------------------------------------------------------------------------
usage() { df -B1 --output=used,iused "$ROOT" 2>/dev/null | awk 'NR == 2 { print $1, $2 }'; }
read -r used0 inodes0 <<< "$(usage)"

ARGS=(--user --clean)
[[ "$MODE" == dry ]] && ARGS+=(--dry-run)
# Its stderr still goes to the journal, through a copy kept to count (FAILED).
TFERR="$STATE/tmpfiles.err"
FAILRE='Failed to remove|Opening directory .* failed'
{ "$TMPFILES" "${ARGS[@]}" "$CONF" "$GUARD" 2>&1 >&3 3>&- | tee "$TFERR" >&2 3>&-; rcs=("${PIPESTATUS[@]}"); } 3>&1
rc="${rcs[0]}"
failed="?"
if (( rcs[1] == 0 )) && n="$(awk -v re="$FAILRE" '$0 ~ re { n++ } END { print n + 0 }' "$TFERR")"; then
  failed="$n"
fi

read -r used1 inodes1 <<< "$(usage)"
printf '%s mode=%s guarded=%s chmod=%s rc=%s failed=%s used=%s->%s inodes=%s->%s seconds=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "${#GUARDS[@]}" "$CHMOD" "$rc" "$failed" \
  "${used0:-?}" "${used1:-?}" "${inodes0:-?}" "${inodes1:-?}" "$(( SECONDS - START ))" \
  | tee -a "$STATE/log"

if [[ "$failed" =~ ^[1-9][0-9]*$ ]]; then
  printf 'tmpdir-clean: WARNING: failed=%s: systemd-tmpfiles could not remove or open that many paths, so they are still there. The first:\n' "$failed" >&2
  awk -v re="$FAILRE" '$0 ~ re { print "  " $0; if (++n == 5) exit }' "$TFERR" >&2
fi
case "$rc" in
  0) exit 0 ;;
  65) printf 'tmpdir-clean: systemd-tmpfiles exited 65: a line in %s or the guard could not be parsed\n' "$CONF" >&2
      exit 0 ;;
  73) if [[ "$failed" =~ ^[1-9][0-9]*$ ]]; then
        printf 'tmpdir-clean: systemd-tmpfiles exited 73 for those, and cleaned the rest: a warning, not a failure\n' >&2
        exit 0
      fi
      printf 'tmpdir-clean: systemd-tmpfiles exited 73, and named no path it could not remove or open\n' >&2
      exit 1 ;;
  *) printf 'tmpdir-clean: systemd-tmpfiles exited %s\n' "$rc" >&2; exit 1 ;;
esac
