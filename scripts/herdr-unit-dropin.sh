#!/usr/bin/env bash
#
# scripts/herdr-unit-dropin.sh
# ============================
#
# Make systemd/herdr-server.service's ExecStart correct for THIS checkout,
# wherever it is (DO-564), by rendering a drop-in:
#
#   ~/.config/systemd/user/herdr-server.service.d/10-execstart.conf
#
# The unit itself stays a SYMLINK into the checkout — see the template's header
# for why that is load-bearing and why a rendered copy of the unit is not an
# option. `./install` and `./install --herdr` both run this.
#
# Before this existed, the unit's absolute `%h/.dotfiles/scripts/...` ExecStart
# meant `--herdr` REFUSED to install from any other directory, and the only
# escape (HERDR_ALLOW_FOREIGN_CHECKOUT=1) produced a unit that failed at start
# with 203/EXEC. The cost landed on the adopter we most want to say yes: someone
# who already has their own ~/.dotfiles.
#
# Modes
# -----
#   (none) | --install   render and install the drop-in for this checkout
#   --print              render to stdout; write nothing
#   --check              is the EFFECTIVE ExecStart the launcher inside the
#                        checkout the unit symlink resolves to? exit 1 if not
#
# --check asks about the OUTCOME, not about this file. "The drop-in exists" is
# the wrong question: the base unit's own ExecStart is correct at ~/.dotfiles, so
# a machine there is healthy with or without a drop-in, and demanding one would
# be a permanently-red check on a correct machine — the failure CLAUDE.md warns
# about three times. "The launcher that will actually run lives in the checkout
# systemd is pointed at" is right everywhere, needs no severity branch, and
# catches the states that matter: a foreign checkout with no drop-in, and a
# drop-in left behind by a checkout that has since moved.
#
# Test overrides (also make it hermetic):
#   SYSTEMD_USER_DIR   default ~/.config/systemd/user
#   HERDR_ROOT         default the checkout this script lives in

set -uo pipefail

UNIT="herdr-server.service"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-${HOME}/.config/systemd/user}"
HERDR_ROOT="${HERDR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
# PHYSICAL, and canonicalised even when handed in by the caller — the same
# reasoning as scripts/reconcile-systemd-units.sh: bash's `pwd` is LOGICAL, so
# with the ordinary layout `~/.dotfiles -> ~/src/dotfiles` a rendered path would
# disagree with the `readlink -f` of the unit symlink that --check compares it
# against, and every run would report drift on a correct machine.
HERDR_ROOT="$(readlink -f "$HERDR_ROOT" 2>/dev/null || printf '%s' "$HERDR_ROOT")"

TEMPLATE="$HERDR_ROOT/systemd/${UNIT}.d/10-execstart.conf"
DROPIN_DIR="$SYSTEMD_USER_DIR/${UNIT}.d"
DROPIN="$DROPIN_DIR/10-execstart.conf"
LAUNCHER_REL="scripts/herdr-server-launch.sh"

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

# Parameter expansion, not sed, so a path containing | & or a backslash cannot
# corrupt the output (backup-render.sh, same reason). An unresolved placeholder
# is a HARD ERROR and never a blank: ExecStart=/scripts/herdr-server-launch.sh
# is not a degraded result, it is a unit that fails at start pointing at the
# filesystem root.
render() {
    local content
    [[ -r "$TEMPLATE" ]] || { printf 'herdr-unit-dropin: template not readable: %s\n' "$TEMPLATE" >&2; return 1; }
    content="$(cat "$TEMPLATE")" || return 1
    content="${content//__HERDR_ROOT__/$HERDR_ROOT}"
    if [[ "$content" == *__HERDR_*__* ]]; then
        printf 'herdr-unit-dropin: unresolved placeholder in %s — refusing to emit\n' "$TEMPLATE" >&2
        return 1
    fi
    printf '%s\n' "$content"
}

# Render to a temp file, CHECK, then install. Never `render > "$DROPIN"` and
# never a pipe into tee: the redirect truncates the destination before the
# renderer's status is known, so a failed render leaves a zero-byte drop-in —
# which, being a valid empty drop-in, installs "successfully" and reads as
# present forever while changing nothing.
do_install() {
    local tmp rc=0
    if [[ ! -x "$HERDR_ROOT/$LAUNCHER_REL" ]]; then
        printf '  ⚠ %s/%s is not executable — drop-in not written.\n' "$HERDR_ROOT" "$LAUNCHER_REL" >&2
        return 1
    fi
    mkdir -p "$DROPIN_DIR" || {
        printf '  ⚠ could not create %s\n' "$DROPIN_DIR" >&2
        return 1
    }
    # The temp file lives IN the destination directory, for two reasons.
    # Atomicity: the final step is then a same-filesystem rename, so no reader
    # ever sees a half-written drop-in ($TMPDIR is often a different filesystem,
    # where mv degrades to copy-then-unlink). And the name deliberately does NOT
    # end in .conf — systemd loads every *.conf in this directory, and so does
    # effective_execstart below, so a leftover temp file must be invisible to
    # both rather than becoming a second, stale drop-in.
    tmp="$(mktemp "$DROPIN_DIR/.10-execstart.XXXXXX")" || return 1
    if ! render >"$tmp"; then
        rm -f "$tmp"
        printf '  ⚠ could not render the herdr unit drop-in — %s left unchanged.\n' "$DROPIN" >&2
        return 1
    fi
    # `mv`, NOT `install`. This repo's own installer is a script called `install`
    # in the checkout root, and dotbot runs shell steps with cwd set to the
    # checkout — so on a machine with `.` anywhere in PATH, `install -m 0644 …`
    # resolves to ./install and re-enters the installer. Unlikely, unrecoverable
    # if it happens, and free to avoid.
    chmod 0644 "$tmp" 2>/dev/null
    if ! mv -f "$tmp" "$DROPIN"; then
        rc=1
        rm -f "$tmp"
        printf '  ⚠ could not write %s\n' "$DROPIN" >&2
    fi
    (( rc == 0 )) && printf '  ✓ herdr unit ExecStart pinned to %s\n' "$HERDR_ROOT"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Effective ExecStart
# ---------------------------------------------------------------------------

# Every ExecStart= in the [Service] section of $1, one per line. A bare
# `ExecStart=` prints as an empty line, which is what makes the reset visible to
# the caller. Only [Service] is read, and the pattern is anchored, so a commented
# or otherwise-sectioned ExecStart is not an instruction.
execstart_lines() {
    local file="$1"
    [[ -r "$file" ]] || return 0
    awk '
        /^[[:space:]]*\[/ { in_service = ($0 ~ /^[[:space:]]*\[Service\][[:space:]]*$/); next }
        !in_service { next }
        /^[[:space:]]*ExecStart[[:space:]]*=/ {
            sub(/^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*/, "")
            print
        }
    ' "$file"
}

# systemd's own merge order: the unit file, then its drop-ins by filename. An
# empty value clears everything accumulated so far. Only the drop-in directory
# NEXT TO THE UNIT is read — that is the one this repo writes; a drop-in placed
# by hand in /etc/systemd/user would also apply and is deliberately out of
# scope, since a check cannot distinguish that from an administrator's decision.
effective_execstart() {
    local unit_path="$1" dir="$2" f line result=""
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then result=""; else result="$line"; fi
    done < <(execstart_lines "$unit_path")
    if [[ -d "$dir" ]]; then
        for f in "$dir"/*.conf; do
            [[ -f "$f" ]] || continue
            while IFS= read -r line; do
                if [[ -z "$line" ]]; then result=""; else result="$line"; fi
            done < <(execstart_lines "$f")
        done
    fi
    printf '%s\n' "$result"
}

# The executable an ExecStart line names: specifiers expanded, systemd's exec
# prefixes stripped, first word taken. Only %h and %% are handled, because they
# are the only specifiers this unit uses — a general expander would be more code
# and more ways to be wrong about a value nothing produces.
# The executable an ExecStart line names: systemd's exec prefixes stripped, the
# %h specifier expanded, quoting honoured, first word taken.
#
# Prints nothing when the answer cannot be known, and the caller reports that as
# NOT CHECKED rather than comparing. Only %h is expanded, because it is the only
# specifier this unit uses — but a line carrying ANOTHER specifier must not be
# silently mis-expanded into a confident "wrong launcher", which would make this
# assertion permanently red on a unit somebody legitimately extended. (An earlier
# version also substituted %% -> % and did it in the wrong order, so `%%h` — a
# literal %h — became `%$HOME`. Dead code that was also wrong; the honest answer
# is to decline.)
execstart_binary() {
    local line="$1"
    while [[ "$line" == [-@:+!]* ]]; do line="${line#?}"; done
    # Quoted first token: take it whole, so a checkout path containing a space
    # resolves instead of being split at the space.
    if [[ "$line" == '"'* ]]; then
        line="${line#\"}"
        line="${line%%\"*}"
    else
        line="${line%% *}"
    fi
    line="${line//%h/$HOME}"
    [[ "$line" == *%* ]] && return 0
    printf '%s\n' "$line"
}

do_check() {
    local link target checkout eff bin want
    link="$SYSTEMD_USER_DIR/$UNIT"

    if [[ ! -L "$link" ]]; then
        if [[ -e "$link" ]]; then
            # Not ours to reason about: every install path in this repo links it.
            printf '  · %s is a regular file, not a link into a checkout — ExecStart NOT CHECKED\n' "$UNIT"
            return 0
        fi
        printf '  ○ %s not linked into %s — skipped\n' "$UNIT" "$SYSTEMD_USER_DIR"
        return 0
    fi

    target="$(readlink -f "$link" 2>/dev/null)"
    if [[ -z "$target" || ! -e "$target" ]]; then
        # reconcile-systemd-units.sh --check reports this as `broken` and names
        # the fix; saying it twice with different words would only be two things
        # to keep in step.
        printf '  ○ %s resolves to nothing — ExecStart NOT CHECKED (see the enablement report)\n' "$UNIT"
        return 0
    fi
    [[ "$target" == */systemd/* ]] || {
        printf '  · %s does not resolve into a checkout'"'"'s systemd/ dir — ExecStart NOT CHECKED\n' "$UNIT"
        return 0
    }
    checkout="${target%/systemd/*}"
    want="$checkout/$LAUNCHER_REL"

    eff="$(effective_execstart "$target" "$DROPIN_DIR")"
    bin="$(execstart_binary "$eff")"

    # Canonicalise BOTH sides before comparing. `want` is derived from a
    # `readlink -f` (physical), while `bin` comes out of the unit text with %h
    # expanded to $HOME (logical) — so on the layout this repo explicitly
    # supports, ~/.dotfiles -> ~/src/dotfiles, the two spellings name the same
    # file and a naive string compare reports drift on a CORRECT machine, in
    # every shell, forever. Exactly the trap reconcile-systemd-units.sh carries a
    # paragraph about, and DOTFILES_ROOT exists because the checkout does move.
    # Fall back to the literal when canonicalisation fails (readlink -f exits 1
    # on a missing intermediate component), so a genuinely wrong path is still
    # compared and still reported in the words the unit actually uses.
    canon() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }

    # Two different empties, and collapsing them was the whole point of teaching
    # execstart_binary to decline. No ExecStart AT ALL is a real fault — systemd
    # refuses to load such a unit. An ExecStart that is present but carries a
    # specifier this script does not expand is a question it cannot answer, and
    # answering it anyway would report "wrong launcher" about a unit somebody
    # legitimately extended.
    if [[ -z "$eff" ]]; then
        printf '  ✗ FAIL: %s has no effective ExecStart — systemd will refuse to load it.\n' "$UNIT"
        printf '      Fix: ./install (or ./install --herdr) — it renders the drop-in.\n'
        return 1
    fi
    if [[ -z "$bin" ]]; then
        printf '  · %s ExecStart carries a specifier this check does not expand — NOT CHECKED\n' "$UNIT"
        printf '      value: %s\n' "$eff"
        printf '      Only %%h is expanded. Extend execstart_binary in %s if that is now wrong.\n' \
               "${BASH_SOURCE[0]##*/}"
        return 0
    fi
    if [[ "$(canon "$bin")" != "$(canon "$want")" ]]; then
        printf '  ✗ FAIL: %s would run the WRONG launcher.\n' "$UNIT"
        printf '      effective ExecStart: %s\n' "$bin"
        printf '      the live unit link points into: %s\n' "$checkout"
        printf '      so it should run: %s\n' "$want"
        printf '      Left alone it fails at start with 203/EXEC, reported nowhere you will look.\n'
        printf '      Fix: ./install (or ./install --herdr) from %s\n' "$checkout"
        return 1
    fi
    if [[ ! -x "$bin" ]]; then
        printf '  ✗ FAIL: %s ExecStart names %s, which is not executable.\n' "$UNIT" "$bin"
        printf '      Fix: chmod +x %s\n' "$bin"
        return 1
    fi
    printf '  ✓ %s ExecStart runs %s\n' "$UNIT" "$bin"
    return 0
}

case "${1:-}" in
    ""|--install) do_install ;;
    --print)      render ;;
    --check)      do_check ;;
    --help|-h)    awk 'NR < 3 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' \
                      "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            printf 'usage: %s [--install|--print|--check]\n' "${0##*/}" >&2; exit 2 ;;
esac
