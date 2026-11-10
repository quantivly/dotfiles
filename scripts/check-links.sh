#!/usr/bin/env bash
#
# check-links.sh — assert that every link this repo DECLARES is actually a
# symlink into this checkout.
#
# WHY THIS EXISTS. On 2026-09-15 `~/.config/claude-tenants.zsh` stopped being a
# symlink and became a regular file. Nothing failed. The tracked source
# `claude/tenants.zsh` went inert for a day: a pool edit made on 2026-09-15
# (dropping `quantivly-0`, which `dev` had just taken as its own Claude account)
# lived only in the installed copy, while the repo still shipped the old table.
# The next `bash ./install` — run on 2026-09-16 for an unrelated reason — backed
# the regular file up and relinked it, which would have RESTORED `quantivly-0`
# to the pool and put the laptop and dev back on one grant. Two machines sharing
# one grant log each other out, server-side, and the symptom appears nowhere
# near the cause.
#
# The same class is already documented for the team repo's mise config: a real
# copy where a symlink belongs, so `install` warns once and then keeps the copy
# forever. It declared 10 tools against the repo's 23 and ~11 binaries silently
# left PATH, for months.
#
# WHAT IT CANNOT DO. It does not prevent the edit. Nothing here can: the cause
# is a person or an agent writing the INSTALLED path instead of the source, and
# a write that replaces rather than follows the symlink. CLAUDE.md already says
# "Edit claude/tenants.zsh only, then bash ./install" and that instruction was
# simply not followed. What this turns into a loud failure is the STATE that
# edit leaves behind — which is the part that was silent, and the part that
# actually cost something.
#
# PROVENANCE. Ported from ~/.dotfiles-local/scripts/check-links.sh on 2026-11-09
# so the public repo and the private overlay are checked by one parser. Changed
# in the port: --tsv, --root and --config; and "could not run" (an unreadable
# config, or a link: block that declares nothing the parser recognises) is now
# exit 2 instead of exit 1, so it is never a pass and never mistaken for drift.
# The awk parser is unchanged.
#
# Usage:
#   scripts/check-links.sh                       # report; exit 1 on any fault
#   scripts/check-links.sh --quiet               # exit code only
#   scripts/check-links.sh --tsv                 # one "<state>\t<target>\t<source>"
#                                                #   line per declared entry, nothing else
#   scripts/check-links.sh --root <checkout>     # the checkout the sources live in
#   scripts/check-links.sh --config <file>       # the manifest (default <root>/install.conf.yaml)
#
# A relative --root is resolved against the current directory; a relative
# --config against the root.
#
# States (--tsv): ok, missing, wrong-target, regular-identical, regular-differs,
# source-missing, conditional-absent.
#
# Environment:
#   REPO_ROOT  — the default for --root (tests set it); else this script's repo
#   HOME       — target paths resolve against it, so tests are hermetic
#
# Exit: 0 every declared link is ok (or a conditional one that is absent);
#       1 any other state occurs;
#       2 the check could not run (config unreadable, nothing recognised, bad flag).

set -uo pipefail

EXIT_FAULTS=1
EXIT_COULD_NOT_RUN=2

STATE_OK="ok"
STATE_MISSING="missing"
STATE_WRONG_TARGET="wrong-target"
STATE_REGULAR_IDENTICAL="regular-identical"
STATE_REGULAR_DIFFERS="regular-differs"
STATE_SOURCE_MISSING="source-missing"
STATE_CONDITIONAL_ABSENT="conditional-absent"

QUIET=0
TSV=0
ROOT_ARG=""
CONFIG_ARG=""
while (( $# )); do
  case "$1" in
    --quiet) QUIET=1 ;;
    --tsv)   TSV=1 ;;
    --root)   [[ -n "${2:-}" ]] || { echo "check-links: --root needs a non-empty value" >&2; exit "$EXIT_COULD_NOT_RUN"; }
              ROOT_ARG="$2"; shift ;;
    --config) [[ -n "${2:-}" ]] || { echo "check-links: --config needs a non-empty value" >&2; exit "$EXIT_COULD_NOT_RUN"; }
              CONFIG_ARG="$2"; shift ;;
    *) echo "check-links: unknown argument '$1'" >&2; exit "$EXIT_COULD_NOT_RUN" ;;
  esac
  shift
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${ROOT_ARG:-${REPO_ROOT:-$(cd "$HERE/.." && pwd)}}"
REPO_ROOT="$(cd "$REPO_ROOT" 2>/dev/null && pwd)" || {
  echo "check-links: the root is not a directory" >&2; exit "$EXIT_COULD_NOT_RUN"; }
CONF="${CONFIG_ARG:-$REPO_ROOT/install.conf.yaml}"
[[ "$CONF" == /* ]] || CONF="$REPO_ROOT/$CONF"

# --tsv output is machine-read: the human lines are silenced and the state lines
# are the only thing on stdout.
(( TSV )) && QUIET=1

RED=$'\033[1;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; YELLOW=""; DIM=""; OFF=""; }

faults=0
say()  { (( QUIET )) || printf '%s\n' "$*"; }
good() { say "  ${GREEN}✓${OFF} $*"; }
bad()  { say "  ${RED}✗${OFF} $*"; faults=$((faults+1)); }
note() { say "  ${DIM}·${OFF} $*"; }
# One TSV line per declared entry: <state>\t<declared target>\t<declared source>.
# Each state is emitted from exactly one branch of the loop below.
emit() { if (( TSV )); then printf '%s\t%s\t%s\n' "$1" "$target" "$source"; fi; }

# ── Parse the `link:` block ──────────────────────────────────────────────────
#
# Emits "<target>\t<source>\t<conditional>" per entry. Handles both shapes this
# manifest uses — `target: source` and a `target:` whose nested block carries
# `path: source` — because a parser that silently skips the nested form would
# have left `live-store-write-guard.sh` unchecked while reporting all clear.
#
# `if:` is carried through rather than dropped. There is no conditional entry
# today; when one is added, an entry that vanished from the check would be a
# checker that quietly shrinks, which is the failure mode this whole file is
# about.
parse_links() {
  awk '
    function unq(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      sub(/[[:space:]]*#.*$/, "", s)
      sub(/^"/, "", s); sub(/"$/, "", s)
      sub(/^'\''/, "", s); sub(/'\''$/, "", s)
      return s
    }
    function flush() {
      if (tgt != "") printf "%s\t%s\t%s\n", tgt, src, cond
      tgt = ""; src = ""; cond = 0
    }
    # A new top-level "- key:" ends the link block.
    /^-[[:space:]]/ {
      if (inblock) { flush(); inblock = 0 }
      if ($0 ~ /^-[[:space:]]*link:[[:space:]]*$/) { inblock = 1 }
      next
    }
    !inblock { next }
    /^[[:space:]]*(#.*)?$/ { next }
    {
      line = $0
      # indentation depth of this line
      match(line, /^[[:space:]]*/); ind = RLENGTH
      body = substr(line, ind + 1)

      # Inside a nested entry block (deeper than the entry key we opened).
      #
      # The test is the INDENT alone. Keying it on "src is still empty" instead
      # ends the block the moment `path:` is read, so the sibling `relink:` and
      # `backup:` keys that follow are parsed as two more link entries — with
      # "true" and "false" as their sources. Measured: 7 entries out of a
      # 5-entry manifest, and two fabricated failures.
      if (tgt != "" && ind > keyind) {
        if (body ~ /^path:/)  { s = body; sub(/^path:[[:space:]]*/, "", s); src = unq(s); next }
        if (body ~ /^if:/)    { cond = 1; next }
        next
      }

      # A new entry key at entry depth.
      if (body ~ /^[^:]+:/) {
        flush()
        keyind = ind
        k = body; sub(/:.*$/, "", k); tgt = unq(k)
        v = body; sub(/^[^:]+:[[:space:]]*/, "", v); v = unq(v)
        if (v != "") { src = v; flush() }
        next
      }
    }
    END { flush() }
  ' "$CONF"
}

# ── Preconditions. An unanswerable question is a FAIL, never a pass. ─────────
if [[ ! -r "$CONF" ]]; then
  echo "${RED}✗ COULD NOT RUN:${OFF} $CONF is missing or unreadable — links UNCHECKED" >&2
  exit "$EXIT_COULD_NOT_RUN"
fi

mapfile -t ENTRIES < <(parse_links)
if (( ${#ENTRIES[@]} == 0 )); then
  echo "${RED}✗ COULD NOT RUN:${OFF} the 'link:' block in $CONF declares nothing this parser recognises" >&2
  echo "         Zero declared links is not a clean bill of health — it is a parser that stopped working." >&2
  exit "$EXIT_COULD_NOT_RUN"
fi

say "${DIM}checkout:${OFF} $REPO_ROOT"
say "${DIM}manifest:${OFF} ${#ENTRIES[@]} declared links"
say ""

for entry in "${ENTRIES[@]}"; do
  IFS=$'\t' read -r target source cond <<< "$entry"
  [[ -n "$target" && -n "$source" ]] || continue

  live="${target/#\~/$HOME}"
  want="$REPO_ROOT/$source"
  short="${live/#$HOME/\~}"

  # A declared source that is not in the tree cannot drift and cannot be
  # compared. Left unasserted it NARROWS the check instead of failing it — a
  # renamed source would take the most important file in the repo out of
  # coverage and still print a green tick.
  if [[ ! -e "$want" ]]; then
    bad "$short — declared source '$source' does not exist in this checkout"
    emit "$STATE_SOURCE_MISSING"
    continue
  fi

  if [[ -L "$live" ]]; then
    got="$(readlink -f -- "$live" 2>/dev/null || true)"
    if [[ "$got" == "$(readlink -f -- "$want" 2>/dev/null)" ]]; then
      good "$short → $source"
      emit "$STATE_OK"
    else
      bad "$short is a symlink, but to ${got:-<unresolvable>} — not to $source in this checkout"
      say "      Fix: cd $REPO_ROOT && ./install"
      emit "$STATE_WRONG_TARGET"
    fi
    continue
  fi

  if [[ ! -e "$live" ]]; then
    # A CONDITIONAL entry that is absent may be absent correctly — dotbot only
    # creates it when its `if:` succeeds, and this checker does not evaluate
    # that condition. Reporting a correct absence as a fault is how a checker
    # becomes one nobody reads, so it is a visible note instead. Note, not
    # silence: an entry that vanished from the output would be the quiet
    # shrinking this file exists to prevent. When such an entry IS present it
    # gets checked exactly like any other, above and below.
    if [[ "$cond" == "1" ]]; then
      note "$short is absent, and its entry is conditional — not judged (the 'if:' is not evaluated here)"
      emit "$STATE_CONDITIONAL_ABSENT"
      continue
    fi
    bad "$short is missing — declared but never installed"
    say "      Fix: cd $REPO_ROOT && ./install"
    emit "$STATE_MISSING"
    continue
  fi

  # The case that cost a day: present, but a real file. The source is inert.
  bad "$short is a REGULAR FILE, not a symlink — '$source' in this repo is INERT"
  if cmp -s -- "$live" "$want"; then
    note "content is identical, so nothing is lost yet; relink before they diverge"
    emit "$STATE_REGULAR_IDENTICAL"
  else
    note "${YELLOW}content DIFFERS from the repo${OFF} — './install' will BACK IT UP AND OVERWRITE IT"
    note "the live file is the one with the recent edits; copy them into '$source' FIRST:"
    note "  diff $short $REPO_ROOT/$source"
    emit "$STATE_REGULAR_DIFFERS"
  fi
  say "      Fix: copy any wanted edits into $source, then: cd $REPO_ROOT && ./install"
done

say ""
if (( faults == 0 )); then
  say "${GREEN}✓${OFF} all ${#ENTRIES[@]} declared links are symlinks into this checkout"
  exit 0
fi
say "${RED}✗${OFF} $faults of ${#ENTRIES[@]} declared links are not what this repo declares"
exit "$EXIT_FAULTS"
