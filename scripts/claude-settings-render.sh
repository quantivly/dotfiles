#!/usr/bin/env bash
#
# scripts/claude-settings-render.sh
# =================================
#
# Render ~/.claude/settings.json from a public base fragment plus the private tenant overlays
# that this host's profile names, so every agent host carries the same settings.
#
# WHY. Four writers touch settings.json today (the dotfiles installer, clauth on every profile
# switch, dev-sync, and Claude Code itself), the file holds `/home/zvi` paths that are wrong
# on any other account, and dev's copy was made by hand and has drifted from the laptop's.
# One renderer, fed by fragments in version control, makes the file a function of the host's
# profile instead of its history. Design: docs/superpowers/specs/2026-11-04-shared-claude-config-design.md
# (D2, D4).
#
# PROFILE. A host opts in by carrying a marker file naming its profile. A host without the
# marker is not rendered: the script says so and exits 0, touching nothing. The profile is
# $OVERLAY_ROOT/hosts/<profile>.json, an object whose `tenants` array lists tenants in order.
#
# FRAGMENTS, in merge order (every one must exist and be a JSON object):
#   1. claude/settings/base.json in this checkout (public)
#   2. $OVERLAY_ROOT/claude/settings/common.json (private)
#   3. $OVERLAY_ROOT/claude/settings/<tenant>.json for each tenant, in profile order (private)
#
# MERGE RULES.
#   - Lists are unioned.
#   - Objects are deep-merged, and a later fragment wins where both set a key.
#   - Hooks are keyed by the basename of their command and replaced, never duplicated.
#   - Only the org-wide auto-mode block is replaced; the rest of auto mode is merged.
#   - $HOME is substituted in marketplace paths only.
#   - A key no fragment declares is left exactly as the live file has it.
#
# Usage:
#   claude-settings-render --check            exit 1 if the live file differs from the render
#   claude-settings-render --print            print the rendered settings to stdout
#   claude-settings-render --apply            write the render to the settings path
#   claude-settings-render --list-fragments   print the resolved fragment paths, one per line
#     --settings PATH                         the settings file (default: ~/.claude/settings.json)
#   claude-settings-render --help             this text
#
# Exit: 0 rendered, level, or no host profile here (nothing to render)
#       1 drift on --check
#       2 could not run (no jq, bad marker or profile, a fragment missing or not an object)
#       64 usage
#
# Overrides: CLAUDE_SETTINGS_RENDER_MARKER (default ~/.config/claude-host-profile),
# CLAUDE_SETTINGS_RENDER_OVERLAY (default ~/.dotfiles-local).

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
DOTFILES="$(cd "$(dirname "$SELF")/.." && pwd)"

SCRIPT_NAME='claude-settings-render'
PROFILE_MARKER_RELATIVE='.config/claude-host-profile'
OVERLAY_ROOT_RELATIVE='.dotfiles-local'
SETTINGS_RELATIVE='.claude/settings.json'
BASE_FRAGMENT_RELATIVE='claude/settings/base.json'
FRAGMENT_DIR_RELATIVE='claude/settings'
HOST_PROFILE_DIR_RELATIVE='hosts'
COMMON_FRAGMENT_NAME='common'
PROFILE_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
EXIT_COULD_NOT_RUN=2
EXIT_USAGE=64

PROFILE_MARKER="${CLAUDE_SETTINGS_RENDER_MARKER:-$HOME/$PROFILE_MARKER_RELATIVE}"
OVERLAY_ROOT="${CLAUDE_SETTINGS_RENDER_OVERLAY:-$HOME/$OVERLAY_ROOT_RELATIVE}"
BASE_FRAGMENT="$DOTFILES/$BASE_FRAGMENT_RELATIVE"
SETTINGS_PATH="$HOME/$SETTINGS_RELATIVE"
MODE=''                # check | print | apply | list-fragments
PROFILE_NAME=''
TENANTS=()
FRAGMENTS=()

usage() { sed -n '/^# Usage:/,/^# Exit:/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; }

# die MESSAGE — could not run: message to stderr, exit 2.
die() {
    printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
    exit "$EXIT_COULD_NOT_RUN"
}

# usage_error MESSAGE — the command line is wrong: message and usage to stderr, exit 64.
usage_error() {
    printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
    usage >&2
    exit "$EXIT_USAGE"
}

# set_mode VERB — record the one verb; a second verb is a usage error.
set_mode() {
    [[ -z "$MODE" ]] || usage_error "only one verb allowed ($MODE and $1)"
    MODE="$1"
}

# parse_args ARGS… — set MODE and SETTINGS_PATH from the command line.
parse_args() {
    while (( $# )); do
        case "$1" in
            --check)          set_mode check ;;
            --print)          set_mode print ;;
            --apply)          set_mode apply ;;
            --list-fragments) set_mode list-fragments ;;
            --settings)
                (( $# >= 2 )) || usage_error "--settings needs a path"
                SETTINGS_PATH="$2"; shift ;;
            -h|--help)        usage; exit 0 ;;
            *)                usage_error "unknown argument: $1" ;;
        esac
        shift
    done
    [[ -n "$MODE" ]] || usage_error "a verb is required"
}

# load_profile — set PROFILE_NAME from the marker's first line and TENANTS from the profile
# file. Dies if the name is malformed, the profile file is missing or unreadable as JSON, or
# it lists no tenant.
load_profile() {
    local profile_file tenants_output tenant
    IFS= read -r PROFILE_NAME < "$PROFILE_MARKER" || [[ -n "$PROFILE_NAME" ]] \
        || die "profile marker $PROFILE_MARKER is empty"
    [[ "$PROFILE_NAME" =~ $PROFILE_NAME_RE ]] \
        || die "profile marker $PROFILE_MARKER: '$PROFILE_NAME' is not a profile name ($PROFILE_NAME_RE)"
    profile_file="$OVERLAY_ROOT/$HOST_PROFILE_DIR_RELATIVE/$PROFILE_NAME.json"
    [[ -f "$profile_file" ]] || die "profile '$PROFILE_NAME' has no file: $profile_file"
    tenants_output=$(jq -r '.tenants[]' "$profile_file") \
        || die "$profile_file has no readable .tenants array"
    [[ -n "$tenants_output" ]] || die "$profile_file lists no tenant"
    mapfile -t TENANTS <<< "$tenants_output"
    for tenant in "${TENANTS[@]}"; do
        # A tenant becomes a file name; refuse anything that is not a plain name.
        [[ "$tenant" =~ $PROFILE_NAME_RE ]] || die "$profile_file: '$tenant' is not a tenant name ($PROFILE_NAME_RE)"
    done
}

# require_fragment PATH LABEL — die unless PATH exists and parses as a JSON object.
require_fragment() {
    [[ -f "$1" ]] || die "$2 has no fragment: $1"
    jq -e 'type == "object"' "$1" >/dev/null 2>&1 || die "$2 fragment is not a JSON object: $1"
}

# load_fragments — set FRAGMENTS in merge order: base, common, then each tenant in profile order.
load_fragments() {
    local overlay_dir="$OVERLAY_ROOT/$FRAGMENT_DIR_RELATIVE" tenant
    FRAGMENTS=("$BASE_FRAGMENT" "$overlay_dir/$COMMON_FRAGMENT_NAME.json")
    for tenant in "${TENANTS[@]}"; do
        FRAGMENTS+=("$overlay_dir/$tenant.json")
    done
    require_fragment "${FRAGMENTS[0]}" "base"
    require_fragment "${FRAGMENTS[1]}" "$COMMON_FRAGMENT_NAME"
    local index
    for (( index = 0; index < ${#TENANTS[@]}; index++ )); do
        require_fragment "${FRAGMENTS[index + 2]}" "tenant ${TENANTS[index]}"
    done
}

merge_settings() { die "not implemented"; }
write_settings() { die "not implemented"; }

main() {
    parse_args "$@"
    command -v jq >/dev/null || die "jq is required"
    if [[ ! -f "$PROFILE_MARKER" ]]; then
        printf '%s: no host profile at %s; nothing to render\n' "$SCRIPT_NAME" "$PROFILE_MARKER"
        exit 0
    fi
    load_profile
    load_fragments
    # merge_settings and write_settings are stubs that die until the merge and the writer land, so
    # write_settings reads as unreachable to shellcheck for now.
    # shellcheck disable=SC2317
    case "$MODE" in
        list-fragments) printf '%s\n' "${FRAGMENTS[@]}" ;;
        print|check)    merge_settings ;;
        apply)          merge_settings; write_settings ;;
    esac
}

main "$@"
