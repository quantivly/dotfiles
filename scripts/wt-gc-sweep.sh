#!/usr/bin/env bash
#
# scripts/wt-gc-sweep.sh
# ======================
#
# The unattended half of worktree teardown: runs `wt-gc --apply` on a schedule so
# landed agent worktrees and their local branches stop piling up.
#
# The engine is `wt-gc` (in ~/.dotfiles-local, on PATH as ~/.local/bin/wt-gc).
# This script is policy and nothing else: which paths an unattended run may
# remove, how long a merge is left alone, and what counts as a failure. Keeping
# the two apart is deliberate — wt-gc is a tool a human points at a question, and
# a timer must not quietly widen what that tool does when a human runs it.
#
# POLICY, and why each part is what it is:
#
#   --scope ~/.herdr/worktrees   Only agent-made checkouts. Measured 2026-09-21:
#       of 56 REAP worktrees machine-wide, 41 were under that path, and the rest
#       are other tools' territory — 7 belong to a live rabota epic under
#       ~/.local/state/rabota-impl. `wt-gc --apply` by hand still covers those,
#       with a human reading the list first.
#   --min-age 2                  A PR that merged in the last two days keeps its
#       checkout, so a merge nobody has looked at yet survives the sweep. The
#       grace is counted from the MERGE, not the last commit.
#   --branches                   Deletes each reaped worktree's branch and every
#       dangling local branch that passes wt-gc's landed test. Never a remote
#       branch: `gh pr merge --delete-branch` owns those.
#
# EXIT STATUS is the part with a trap in it. `wt-gc` exits 1 for a removal
# failure AND for a warning — and a warning here is routine (a repository whose
# `git worktree list` failed, an unreadable registry entry). Mapping that
# straight through would fail the unit most nights, which is how a red unit stops
# being read. So the exit status is derived from what the run REPORTED:
#
#   wt-gc 0            -> 0
#   wt-gc 1, FAILED    -> 1   something could not be removed; that is real
#   wt-gc 1, no FAILED -> 0   warnings only, echoed to the journal
#   wt-gc 2            -> 1   a usage error is this script's bug, not a warning
#   anything else      -> 1
#
# Every run appends one line to $XDG_STATE_HOME/wt-gc-sweep/log and leaves the
# full TSV in last-run.tsv, because an unattended deleter nobody can audit
# afterwards is one nobody should run.
#
# Usage: scripts/wt-gc-sweep.sh [--dry-run]
#
# Environment (the state table uses these):
#   WT_GC_SWEEP_BIN       wt-gc to run (default: wt-gc from PATH)
#   WT_GC_SWEEP_SCOPE     removal scope (default: ~/.herdr/worktrees)
#   WT_GC_SWEEP_MIN_AGE   grace in days (default: 2)
#   WT_GC_SWEEP_STATE     state dir (default: $XDG_STATE_HOME/wt-gc-sweep)

set -uo pipefail

DRY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed -e '/^set -uo/d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'wt-gc-sweep: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

BIN="${WT_GC_SWEEP_BIN:-wt-gc}"
SCOPE="${WT_GC_SWEEP_SCOPE:-$HOME/.herdr/worktrees}"
MIN_AGE="${WT_GC_SWEEP_MIN_AGE:-2}"
STATE="${WT_GC_SWEEP_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/wt-gc-sweep}"

# `command -v` one name at a time: with two operands the shells disagree about
# both the output and the status, so a two-name check is a silent pass.
if ! command -v "$BIN" >/dev/null 2>&1 && [[ ! -x "$BIN" ]]; then
  printf 'wt-gc-sweep: %s is not available — it lives in ~/.dotfiles-local, which this machine may not have\n' \
    "$BIN" >&2
  exit 1
fi

# An unattended run whose scope does not exist would fall back to nothing at all
# in wt-gc, which is safe, but it means the machine has no agent worktrees and
# there is nothing to do. Say so rather than reporting a successful sweep of
# nothing, which reads identically to a sweep that silently stopped working.
if [[ ! -d "$SCOPE" ]]; then
  printf 'wt-gc-sweep: nothing to do — %s does not exist\n' "$SCOPE"
  exit 0
fi

if ! mkdir -p "$STATE"; then
  printf 'wt-gc-sweep: could not create %s\n' "$STATE" >&2
  exit 1
fi

ARGS=(--tsv --branches --scope "$SCOPE" --min-age "$MIN_AGE")
(( DRY )) || ARGS+=(--apply)

ERRFILE="$STATE/last-run.err"
OUT="$("$BIN" "${ARGS[@]}" 2>"$ERRFILE")"
RC=$?
printf '%s\n' "$OUT" > "$STATE/last-run.tsv"

count() { awk -F'\t' -v k="$1" '$1 == k' <<< "$OUT" | grep -c '' ; }
REMOVED="$(count REMOVED)"
DELETED="$(count DELETED)"
PRUNED="$(count PRUNED)"
SKIPPED="$(count SKIPPED)"
FAILED="$(count FAILED)"
WARNINGS="$(grep -c '' < "$ERRFILE")"

# Warnings are echoed rather than swallowed: they are not a failure, but a
# repository whose worktrees could not be listed is one this run did not cover,
# and a sweep that silently covers less every week is the failure mode here.
if (( WARNINGS )); then
  printf 'wt-gc-sweep: %s warning(s) from wt-gc:\n' "$WARNINGS" >&2
  sed 's/^/  /' "$ERRFILE" >&2
fi

printf '%s removed=%s branches=%s pruned=%s skipped=%s failed=%s warnings=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$REMOVED" "$DELETED" "$PRUNED" "$SKIPPED" "$FAILED" "$WARNINGS" \
  | tee -a "$STATE/log"

case "$RC" in
  0) exit 0 ;;
  1) (( FAILED )) && exit 1; exit 0 ;;
  *) printf 'wt-gc-sweep: wt-gc exited %s, which is not a warning\n' "$RC" >&2; exit 1 ;;
esac
