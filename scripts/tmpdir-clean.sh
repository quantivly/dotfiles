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
# THE AGES are not here. They are in config/user-tmpfiles.d/tmpdir.conf (7 days
# for the root, 14 for Claude Code's claude-<uid>/), and systemd-tmpfiles applies
# them. This script is the guard and nothing else, so a human running
# `systemd-tmpfiles --user --clean` by hand gets the same ages.
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
#     names a gitdir with no back-pointer, so it is not guarded.
#   * The host is "$gitdir/commondir". A host INSIDE the root is temp too, and the
#     worktree ages out with it.
#   * An `x` line is a glob, and tmpfiles.d unquotes and expands specifiers, so a
#     path with whitespace, `%`, `*`, `?`, `[`, a backslash or a quote cannot be
#     written as an exact path. Such a worktree makes the run REFUSE (exit 2), as
#     does a failing `find` or an unreadable .git file: never clean on a partial
#     guard.
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
# --dry-run passes --dry-run to systemd-tmpfiles, which has it only from systemd
# 256. On an older one this exits 2 rather than falling through to a real clean.
#
# --check is the verify-tools.sh assertion, kept here so it is testable on its
# own: FAIL when the TMPDIR redirect is linked but tmpdir-clean.timer is not
# enabled, WARN when the vendor systemd-tmpfiles-clean.timer is enabled too (it
# runs without the guard). No user manager, or no redirect, is a skip.
#
# Every run appends one line to $XDG_STATE_HOME/tmpdir-clean/log: mode, guarded
# worktrees, the systemd-tmpfiles exit status, used bytes and inodes on the
# root's filesystem before and after, and seconds.
#
# EXIT STATUS
#   0  cleaned (systemd-tmpfiles exited 0, or 65: a line it could not parse,
#      echoed to the journal), or --check found nothing wrong
#   1  systemd-tmpfiles failed, or --check found the timer not enabled
#   2  COULD NOT RUN, and nothing was deleted: an unencodable worktree path, a
#      failing find, an unreadable .git file, no config, no runtime dir, or
#      --dry-run on systemd < 256
#
# Usage: scripts/tmpdir-clean.sh [--dry-run | --check]
#
# Environment (the state table uses these):
#   TMPDIR_CLEAN_ROOT       the root (default: ~/.cache/tmp, i.e. %h/.cache/tmp)
#   TMPDIR_CLEAN_CONFIG     tmpfiles.d file (default: ~/.config/user-tmpfiles.d/tmpdir.conf)
#   TMPDIR_CLEAN_GUARD_DIR  where the guard goes (default: $XDG_RUNTIME_DIR/user-tmpfiles.d)
#   TMPDIR_CLEAN_STATE      state dir (default: $XDG_STATE_HOME/tmpdir-clean)
#   TMPDIR_CLEAN_TMPFILES   systemd-tmpfiles to run (default: from PATH)
#   TMPDIR_CLEAN_ENV_LINK   --check: the redirect (default: ~/.config/environment.d/tmpdir.conf)

set -uo pipefail

MODE=apply
for arg in "$@"; do
  case "$arg" in
    --dry-run) MODE=dry ;;
    --check)   MODE=check ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'tmpdir-clean: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
ROOT="${TMPDIR_CLEAN_ROOT:-$HOME/.cache/tmp}"
ROOT="${ROOT%/}"
CONF="${TMPDIR_CLEAN_CONFIG:-$CONFIG_HOME/user-tmpfiles.d/tmpdir.conf}"
GUARD_DIR="${TMPDIR_CLEAN_GUARD_DIR:-${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/user-tmpfiles.d}}"
STATE="${TMPDIR_CLEAN_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/tmpdir-clean}"
TMPFILES="${TMPDIR_CLEAN_TMPFILES:-systemd-tmpfiles}"

refuse() { printf 'tmpdir-clean: REFUSING, nothing deleted: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------
if [[ "$MODE" == check ]]; then
  link="${TMPDIR_CLEAN_ENV_LINK:-$CONFIG_HOME/environment.d/tmpdir.conf}"
  if [[ ! -L "$link" ]]; then
    printf '  ○ the TMPDIR redirect (%s) is not linked — skipped\n' "$link"
    exit 0
  fi
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    printf '  ○ no systemd user manager reachable — skipped\n'
    exit 0
  fi
  rc=0
  state="$(systemctl --user is-enabled tmpdir-clean.timer 2>/dev/null)"
  if [[ "$state" == enabled ]]; then
    printf '  ✓ tmpdir-clean.timer is enabled, so ~/.cache/tmp is aged out\n'
  else
    printf '  ✗ TMPDIR is redirected to ~/.cache/tmp, but tmpdir-clean.timer is %s —\n' "${state:-not found}"
    printf '      nothing ages that directory out, and it grows without limit.\n'
    printf '      Fix: ./install (it enables the timer), then\n'
    printf '      systemctl --user start tmpdir-clean.timer\n'
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
if [[ ! -d "$ROOT" ]]; then
  printf 'tmpdir-clean: nothing to do — %s does not exist\n' "$ROOT"
  exit 0
fi
[[ -r "$CONF" ]] || refuse "cannot read the tmpfiles.d config $CONF"
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

# First line of a file, failing (rather than returning empty) when unreadable.
# An empty file is readable and has an empty first line.
first_line() {
  local l=""
  [[ -r "$1" ]] || return 1
  IFS= read -r l < "$1"
  printf '%s' "$l"
}

# ---------------------------------------------------------------------------
# Find the worktrees to guard.
# ---------------------------------------------------------------------------
START=$SECONDS
LIST="$STATE/gitfiles.list"
FINDERR="$STATE/find.err"
# -ignore_readdir_race: the root is a live TMPDIR, and an entry deleted between
# readdir and stat is otherwise an error and a non-zero exit. What is left is
# real (EACCES), and a real error means the guard may be partial.
find "$ROOT" -maxdepth 8 -ignore_readdir_race \
  \( -name node_modules -o -name .git \) -type d -prune \
  -o -name .git -type f -print0 > "$LIST" 2> "$FINDERR"
frc=$?
if (( frc != 0 )); then
  sed 's/^/  /' "$FINDERR" >&2
  refuse "find exited $frc while looking for worktrees under $ROOT"
fi

ROOT_REAL="$(realpath -m -- "$ROOT")"
GUARDS=()
while IFS= read -r -d '' gitfile; do
  wt="${gitfile%/.git}"
  line="$(first_line "$gitfile")" || refuse "cannot read $gitfile"
  [[ "$line" == "gitdir: "* ]] || continue
  gd="${line#gitdir: }"
  [[ "$gd" == /* ]] || gd="$wt/$gd"
  # No back-pointer: a submodule, or a worktree whose registration is gone.
  [[ -e "$gd/gitdir" ]] || continue
  back="$(first_line "$gd/gitdir")" || refuse "cannot read $gd/gitdir"
  [[ "$back" == /* ]] || back="$gd/$back"
  [[ "$(realpath -m -- "$back")" == "$(realpath -m -- "$gitfile")" ]] || continue
  # A registered worktree whose host cannot be read is guarded: it cannot be
  # shown to be temp.
  if common="$(first_line "$gd/commondir" 2>/dev/null)"; then
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
{
  printf '# Written by %s at %s. Registered git worktrees under %s\n' \
    "${0##*/}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ROOT"
  printf '# whose host repository is outside it. Rewritten on every run.\n'
  for wt in "${GUARDS[@]}"; do printf 'x %s\n' "$wt"; done
} > "$gtmp" && mv -f "$gtmp" "$GUARD" || { rm -f "$gtmp"; refuse "could not write $GUARD"; }

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
