#!/usr/bin/env bash
#
# scripts/herdr-claude-wire.sh
# ============================
#
# Wire Claude Code to herdr: the two things `./install --herdr` links a file for
# but cannot finish, both of which fail silently when skipped (DO-563).
#
#   1. statusLine in ~/.claude/settings.json  -> publishes model / effort /
#      context into the herdr agent sidebar, and doubles as the in-pane status
#      line. Without it every $mdl / $eff_* / $ctx_* token resolves to nothing
#      and those sidebar rows render EMPTY, with no error anywhere.
#      `refreshInterval` is not optional: without it the idle band freezes when
#      a session goes quiet and every token then expires on the 4-minute TTL,
#      blanking the rows a second way.
#
#   2. ~/.claude/skills/herdr/SKILL.md        -> the CLI reference a lead agent
#      reads to drive other panes. `herdr --skill` only PRINTS it; nothing
#      generates the file, and the installer never even mentioned it.
#
# WHY A SCRIPT AND NOT A PARAGRAPH. Both were prose in the team write-up, step 4
# of seven, with the reader hand-substituting their own home directory into a
# JSON block. That is the most-skipped step in the install and the one whose
# failure is hardest to see. One idempotent command is followable; a JSON block
# with a placeholder in it is a transcription exercise.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not own ~/.claude/settings.json.
# That file is user-level, is not in this repo, and may hold a statusLine that
# belongs to something else -- Orca ships its own, and settings.json has exactly
# one statusLine key, so the collision is real. A foreign statusLine is REFUSED
# with an explanation, never overwritten.
#
# Idempotent. Safe to re-run after `herdr update` (and worth it -- SKILL.md is
# version-specific).
#
# Usage: scripts/herdr-claude-wire.sh [--print]
#   --print   show what would change, write nothing

set -uo pipefail

SETTINGS="${HOME}/.claude/settings.json"
HOOK="${HOME}/.claude/hooks/session-statusline.sh"
SKILL="${HOME}/.claude/skills/herdr/SKILL.md"
REFRESH=60

PRINT_ONLY=false
case "$#:${1:-}" in
    0:) ;;
    1:--print) PRINT_ONLY=true ;;
    1:-h | 1:--help)
        sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    *) printf 'usage: %s [--print]\n' "${0##*/}" >&2; exit 2 ;;
esac

GRN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
say()  { printf '%s\n' "$*"; }
good() { say "  ${GRN}✓${OFF} $*"; }
warn() { say "  ${YEL}○${OFF} $*"; }
bad()  { say "  ${RED}✗${OFF} $*"; RC=1; }
RC=0

# A signal mid-run left a temp file beside the destination (verified in review).
# $tmp is reused by both sections; clearing it after each successful mv keeps the
# trap from chasing a path that is already gone.
tmp=""
trap 'rm -f "${tmp:-}"' EXIT INT TERM

say ""
say "Wiring Claude Code to herdr"
say "${DIM}───────────────────────────${OFF}"

# ---------------------------------------------------------------------------
# 1. statusLine
# ---------------------------------------------------------------------------
# jq first, and REFUSING rather than falling back: the alternative to a real
# JSON parser here is a sed edit of the user's settings file, and getting that
# wrong costs them their Claude Code configuration. Absent jq we write nothing.
if ! command -v jq >/dev/null 2>&1; then
    bad "jq is not installed — refusing to edit ${SETTINGS/#$HOME/\~} without a JSON parser"
    say "      ${DIM}apt install jq   (then re-run)${OFF}"
elif [[ ! -e "$HOOK" ]]; then
    # A statusLine pointing at a file that is not there is a green settings.json
    # and a permanently blank sidebar. dotbot links this; if it is missing, the
    # install is incomplete and wiring around that would hide it.
    bad "no statusline hook at ${HOOK/#$HOME/\~} — run ./install --herdr first"
    say "      ${DIM}session-statusline.sh is linked by dotbot; nothing below can substitute for it.${OFF}"
else
    # The command is stored as an ABSOLUTE path inside a bash -c wrapper: `~` is
    # not reliably expanded in this field, and a bare path is not executed by a
    # shell, so the wrapper is what makes it portable across Claude versions.
    # printf %q, not manual single quotes: "bash '$HOOK'" produced a command
    # that does not parse when $HOME contains a single quote, and the script
    # reported ✓ for it. A HOME with a space was already fine; this covers both.
    printf -v want_cmd 'bash %q' "$HOOK"

    existing=""
    st_type=""
    parse_ok=true
    if [[ -e "$SETTINGS" ]]; then
        # Three different states, three different remedies. `jq -e .` conflates
        # them: it fails for an unreadable file (a permissions problem), and it
        # exits 1 for a VALID `null` document (nothing wrong with the syntax).
        # Reporting either as "not valid JSON" sends the user to fix the wrong
        # thing, and the advice here is "fix it by hand".
        if [[ ! -r "$SETTINGS" ]]; then
            parse_ok=unreadable
        elif ! jq empty "$SETTINGS" >/dev/null 2>&1; then
            parse_ok=false
        elif [[ "$(jq -r 'type' "$SETTINGS" 2>/dev/null)" != object ]]; then
            parse_ok=nonobject
        else
            # Read the TYPE before the value. `.statusLine.command // ""` is a
            # jq ERROR when statusLine is not an object ("Cannot index string
            # with string"), and jq's exit status used to be discarded here --
            # so the empty capture read as "nothing is set" and this script
            # OVERWROTE another tool's statusLine and printed "Claude Code is
            # wired", exit 0. `//` substitutes for null; it is no defence
            # against a type error. Found in review, not in use.
            st_type="$(jq -r '.statusLine | type' "$SETTINGS" 2>/dev/null)" || st_type=""
            # An unreadable type is not a missing one: falling through on an
            # empty answer is how the original bug destroyed data.
            [[ -n "$st_type" ]] || st_type="unreadable"
            if [[ "$st_type" == object ]]; then
                existing="$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null)"
            fi
        fi
    fi

    if [[ "$parse_ok" == unreadable ]]; then
        bad "cannot read ${SETTINGS/#$HOME/\~} — check its permissions, then re-run"
    elif [[ "$parse_ok" == nonobject ]]; then
        bad "${SETTINGS/#$HOME/\~} is valid JSON but not an object — Claude Code cannot use it"
        say "      ${DIM}A bare null/array/string document has no place to put statusLine.${OFF}"
    elif [[ "$parse_ok" != true ]]; then
        # An unparseable settings.json is not an absent one, and treating it as
        # absent would replace a file we cannot read with one we wrote.
        bad "${SETTINGS/#$HOME/\~} is not valid JSON — fix it by hand, then re-run"
    elif [[ -n "$st_type" && "$st_type" != null && "$st_type" != object ]]; then
        # Any shape that is not an object is somebody else's key, whatever it
        # holds -- and "unreadable" lands here too, deliberately.
        bad "statusLine is a ${st_type}, not an object — that is not ours; not touching it"
        say "      ${DIM}Claude Code will not run it in that shape either. Inspect it,${OFF}"
        say "      ${DIM}remove it if it is stale, then re-run this script.${OFF}"
    elif [[ "$st_type" == object && "$existing" != *session-statusline.sh* ]]; then
        # An OBJECT whose command is not ours is still somebody else's key --
        # including {} and {"command":null}. Testing `-n "$existing"` instead
        # let those through, because an absent command reads identically to an
        # absent statusLine. "Ours" is a positive test, never the absence of
        # evidence that it is not.
        bad "a statusLine belonging to something else is already set — not touching it"
        say "      ${DIM}found: ${existing:-<an object with no command field>}${OFF}"
        say "      ${DIM}Remove it first if you want herdr's sidebar rows to populate;${OFF}"
        say "      ${DIM}settings.json has room for exactly one statusLine.${OFF}"
    else
        have_cmd="$existing"
        have_int="$(jq -r '.statusLine.refreshInterval // ""' "$SETTINGS" 2>/dev/null)"
        if [[ "$have_cmd" == "$want_cmd" && "$have_int" == "$REFRESH" ]]; then
            good "statusLine already correct"
        elif [[ "$PRINT_ONLY" == true ]]; then
            warn "would set statusLine -> ${want_cmd} (refreshInterval ${REFRESH})"
        else
            # Merge, never replace: settings.json holds permissions, model,
            # hooks and more, and this script is a guest in it.
            tmp="$(mktemp "${SETTINGS}.wire.XXXXXX")" || tmp=""
            if [[ -z "$tmp" ]]; then
                bad "could not create a temp file beside ${SETTINGS/#$HOME/\~}"
            elif { if [[ -e "$SETTINGS" ]]; then
                       # Merge into what is there. NOT `|| jq -n {...}` as a
                       # fallback: a jq failure on an existing, valid file would
                       # then be "repaired" by replacing the user's whole
                       # settings.json with a one-key object.
                       jq --arg c "$want_cmd" --argjson i "$REFRESH" \
                          '.statusLine = {type: "command", command: $c, refreshInterval: $i}' \
                          "$SETTINGS" >"$tmp" 2>/dev/null
                   else
                       jq -n --arg c "$want_cmd" --argjson i "$REFRESH" \
                          '{statusLine: {type: "command", command: $c, refreshInterval: $i}}' \
                          >"$tmp" 2>/dev/null
                   fi; }
            then
                # Written to a temp file and moved only after jq exited 0: a
                # redirect straight onto the destination truncates it before the
                # filter's status is known, which is how a failed render leaves
                # an empty file that "installed successfully".
                # if/else, NOT `mv && good || bad`: `good` is a printf, printf
                # returns non-zero on ENOSPC, and the || arm would then report a
                # failure for a write that succeeded. That exact inversion is
                # logged in CLAUDE.md against five checks in this repo.
                if mv "$tmp" "$SETTINGS"; then
                    tmp=""
                    good "statusLine set (refreshInterval ${REFRESH})"
                else
                    bad "could not replace ${SETTINGS/#$HOME/\~}"
                    rm -f "$tmp"
                fi
            else
                rm -f "$tmp"
                bad "jq could not write the statusLine into ${SETTINGS/#$HOME/\~}"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. The agent skill file
# ---------------------------------------------------------------------------
# Regenerated unconditionally, not created-if-absent: it is generated content,
# it is version-specific, and a stale copy teaches a lead agent flags that no
# longer exist -- which is worse than none, because it looks fine.
if ! command -v herdr >/dev/null 2>&1; then
    bad "herdr is not on PATH — cannot generate ${SKILL/#$HOME/\~}"
    say "      ${DIM}Install it (https://herdr.dev), then re-run this script.${OFF}"
elif [[ "$PRINT_ONLY" == true ]]; then
    warn "would regenerate ${SKILL/#$HOME/\~} from 'herdr --skill'"
else
    mkdir -p "${SKILL%/*}" 2>/dev/null
    tmp="$(mktemp "${SKILL}.XXXXXX" 2>/dev/null)" || tmp=""
    if [[ -z "$tmp" ]]; then
        bad "could not create a temp file beside ${SKILL/#$HOME/\~}"
    elif herdr --skill >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        # -s matters: `herdr --skill` on a broken install exits 0 and prints
        # nothing, and an empty SKILL.md is indistinguishable from a wired one
        # until an agent reads it.
        if mv "$tmp" "$SKILL"; then
            tmp=""
            good "skill file regenerated from 'herdr --skill'"
        else
            bad "could not replace ${SKILL/#$HOME/\~}"
            rm -f "$tmp"
        fi
    else
        rm -f "$tmp"
        bad "'herdr --skill' produced nothing — ${SKILL/#$HOME/\~} left as it was"
    fi
fi

say ""
if (( RC == 0 )); then
    if [[ "$PRINT_ONLY" == true ]]; then
        say "  ${DIM}--print: nothing was written.${OFF}"
    else
        say "  ${GRN}Claude Code is wired.${OFF} Verify the way the server sees it:"
        say "      ${DIM}scripts/verify-tools.sh --herdr${OFF}"
    fi
else
    say "  ${RED}Not fully wired${OFF} — each ✗ above says what to do."
fi
say ""
exit "$RC"
