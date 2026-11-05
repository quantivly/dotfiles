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
# MERGE RULES. The fragments are folded, in order, into the live settings file (absent: {}).
#   - Lists are unioned: the live elements in their order, then each fragment's new ones; an
#     element appears once.
#   - Objects are deep-merged; on a scalar the fragment wins, and a later fragment over an earlier.
#   - Hooks, per event: an entry is keyed by the basename of the first script path in its command
#     (`$HOME/…`, `${HOME}/…`, `~/…` or `/…`, quoted or not, redirections ignored), or else by its
#     executable (the first word that is not `command`, `exec`, `[`, `]`, `&&`, `||` or an
#     option). A fragment entry replaces the live entry with its key, in place, and any second one
#     (the same script under another path); a new key is appended. An event no fragment declares
#     is left as found.
#   - autoMode.environment: the fragment's lines replace the live lines from `### Org-wide` up to,
#     not including, `### User-specific` (or to the end). With no live `### Org-wide`, they go
#     first, then `### User-specific` (moved up, or added), then the other live lines. A fragment
#     block must start with `### Org-wide` and hold no `### User-specific` (else exit 2).
#   - $HOME is substituted in marketplace source paths only.
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
# The autoMode.environment headings that bound the block the tenant overlay owns.
ORG_WIDE_HEADING='### Org-wide'
USER_SPECIFIC_HEADING='### User-specific'
# shellcheck disable=SC2016  # the literal the fragments carry, replaced in marketplace paths only
HOME_PLACEHOLDER='$HOME'
# The live file, slurped, when there is none: one empty object.
ABSENT_LIVE_DOCUMENTS='[{}]'
# A redirection in a hook command (`>/dev/null`, `2>&1`, `> /dev/null`), dropped before keying.
HOOK_REDIRECTION_RE='[0-9]*[<>]+&?[[:space:]]*[^[:space:];]*'
# A hook command's script path: starts the command or follows whitespace, `=` or a quote, and
# begins `$HOME/`, `${HOME}/`, `~/` or `/`; capture 2 is the path, without its quotes.
HOOK_SCRIPT_PATH_RE=$'(^|[[:space:]=\'"])((\\$HOME|\\$\\{HOME\\}|~)?/[^[:space:]\'";]*)'
# Words skipped when a hook command with no path is keyed by its executable.
HOOK_WRAPPER_WORDS_JSON='["command", "exec", "[", "]", "&&", "||"]'
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

# ---------------------------------------------------------------------------------------------
# The merge: one jq program, JQ_MERGE, built from the named filters below. It folds each fragment,
# in order, into the live settings with merge_at, which dispatches on the path it is merging at.
# ---------------------------------------------------------------------------------------------

# union_lists($fragment_list): the input list followed by $fragment_list, each element once, at its
# first position (JSON equality). The live order comes first because the live list is the input.
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_UNION_LISTS='
def union_lists($fragment_list):
  reduce (. + $fragment_list)[] as $element ([];
    if any(.[]; . == $element) then . else . + [$element] end);'

# hook_key: the identity of one hook command, so one script under two paths is one hook.
#   1. Redirections are dropped ($redirection_re), so `>/dev/null` and `2>&1` never name a script.
#   2. The basename of the first script path ($script_path_re: a word or an assignment's value,
#      quoted or not, that starts with `$HOME/`, `${HOME}/`, `~/` or `/`).
#   3. Otherwise the executable: the first word that is not a wrapper ($wrapper_words) or an
#      option, so `command -v herdmates … && exec herdmates hook X` is `herdmates`.
#   4. Otherwise the command itself.
# entry_key: an entry ({matcher?, hooks: [{type, command, …}]}) is keyed by its first command; an
# entry without one (a prompt hook, or a malformed entry) by the entry itself, so it matches only
# an equal entry. jq compares objects regardless of key order; a tojson key would not, and the
# render's sorted copy would then be appended again on every render.
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_HOOK_KEY='
def path_basename: sub("/+$"; "") | split("/") | last;
def is_wrapper_word: . as $word | any($wrapper_words[]; . == $word);
def executable_word:
  [splits("[[:space:];]+") | select(. != "" and (is_wrapper_word | not) and (startswith("-") | not))]
  | first;
def hook_key:
  gsub($redirection_re; " ") as $command
  | ([$command | match($script_path_re) | .captures[1].string | path_basename | select(. != "")] | first)
    // ($command | executable_word)
    // .;
def entry_key:
  (try .hooks[0].command catch null) as $command
  | if ($command | type) == "string" then ($command | hook_key) else {uncommanded_entry: .} end;'

# merge_hook_entries($fragment_entries): fold each fragment entry into the input (one event's
# entries). It replaces the first entry with the same key, in that entry's place, and drops any
# later one (the same script under another path); an entry with a new key is appended.
# merge_hooks($fragment_hooks): do that for each event the fragment declares; an event it does not
# declare is left exactly as found.
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_MERGE_HOOKS='
def merge_hook_entries($fragment_entries):
  reduce $fragment_entries[] as $entry (.;
    ($entry | entry_key) as $key
    | . as $entries
    | ([range(length) as $index | select(($entries[$index] | entry_key) == $key) | $index] | first)
      as $first_match
    | if $first_match == null then . + [$entry]
      else [range(length) as $index
            | if $index == $first_match then $entry
              elif ($entries[$index] | entry_key) == $key then empty
              else $entries[$index] end]
      end);
def merge_hooks($fragment_hooks):
  reduce ($fragment_hooks | keys_unsorted[]) as $event (.;
    .[$event] |= ((. // []) | merge_hook_entries($fragment_hooks[$event])));'

# replace_org_wide_block($fragment_lines): in the input (the live autoMode.environment lines),
# replace the lines from the $org_wide_heading line up to, not including, the next
# $user_specific_heading line (or to the end) with $fragment_lines. Everything before the block
# and from the user-specific heading on is kept. With no org-wide heading, the fragment's lines go
# first, then the user-specific heading (the live one, moved up, or a new one), then every other
# live line in order, so the next render finds both headings and changes nothing. Every fragment
# block starts with the org-wide heading and holds no user-specific one (JQ_ORG_WIDE_BLOCK_PROBLEM).
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_AUTOMODE_ORG_WIDE='
def first_index_of($line; $from): [range($from; length) as $index | select(.[$index] == $line) | $index] | first;
def without_line_at($index): if $index == null then . else .[:$index] + .[$index + 1:] end;
def replace_org_wide_block($fragment_lines):
  first_index_of($org_wide_heading; 0) as $block_start
  | if $block_start == null then
      $fragment_lines + [$user_specific_heading]
        + without_line_at(first_index_of($user_specific_heading; 0))
    else (first_index_of($user_specific_heading; $block_start + 1) // length) as $block_end
      | .[:$block_start] + $fragment_lines + .[$block_end:]
    end;'

# What is wrong with one fragment autoMode.environment, or nothing. A block must start with the
# org-wide heading and hold no user-specific one; otherwise the next render could not find the
# block it wrote, and the file would grow on every render.
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_ORG_WIDE_BLOCK_PROBLEM='
if (.autoMode | type) != "object" or (.autoMode | has("environment") | not) then empty
else .autoMode.environment as $lines
  | if ($lines | type) != "array" then "is not a list of lines"
    elif $lines[0] != $org_wide_heading then "does not start with the line \($org_wide_heading)"
    elif any($lines[]; . == $user_specific_heading) then "holds the line \($user_specific_heading)"
    else empty end
end'

# merge_at($path; $fragment): merge $fragment into the input, the live value at $path (null when
# the live file lacks it). Hooks and the auto-mode environment have their own rules; otherwise
# objects deep-merge, lists union, and any other value is the fragment's. Only keys the fragment
# declares are visited, so a key no fragment declares keeps the live value untouched.
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_DEEP_MERGE='
def merge_at($path; $fragment):
  ($fragment | type) as $fragment_type
  | if $path == ["hooks"] and $fragment_type == "object" then
      (. // {}) | merge_hooks($fragment)
    elif $path == ["autoMode", "environment"] and $fragment_type == "array" then
      (. // []) | replace_org_wide_block($fragment)
    elif $fragment_type == "object" and (type == "object" or . == null) then
      reduce ($fragment | keys_unsorted[]) as $key (. // {};
        .[$key] |= merge_at($path + [$key]; $fragment[$key]))
    elif $fragment_type == "array" and (type == "array" or . == null) then
      (. // []) | union_lists($fragment)
    else $fragment
    end;'

# The program: $live_documents is the live file slurped (exactly one object), and the fragments
# arrive as inputs, in merge order.
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_MERGE="$JQ_UNION_LISTS $JQ_HOOK_KEY $JQ_MERGE_HOOKS $JQ_AUTOMODE_ORG_WIDE $JQ_DEEP_MERGE"'
def live_settings:
  if ($live_documents | length) == 1 and ($live_documents[0] | type) == "object" then $live_documents[0]
  else error("the live settings file is not one JSON object") end;
reduce inputs as $fragment (live_settings; merge_at([]; $fragment))'

# substitute_home: replace the literal $placeholder with $home in every marketplace source path; no
# other string is touched (hook and statusLine commands keep $HOME for `sh -c` to expand).
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_SUBSTITUTE_HOME='
def has_source_path: type == "object" and (.source | type) == "object" and (.source.path | type) == "string";
if (.extraKnownMarketplaces | type) == "object" then
  .extraKnownMarketplaces |= map_values(
    if has_source_path then .source.path |= (split($placeholder) | join($home)) else . end)
else . end'

# require_org_wide_blocks FRAGMENT_PATHS… — die, naming the fragment, when one carries an
# autoMode.environment that is not an org-wide block (see JQ_ORG_WIDE_BLOCK_PROBLEM).
require_org_wide_blocks() {
    local fragment problem
    for fragment in "$@"; do
        problem=$(jq -r --arg org_wide_heading "$ORG_WIDE_HEADING" \
            --arg user_specific_heading "$USER_SPECIFIC_HEADING" \
            "$JQ_ORG_WIDE_BLOCK_PROBLEM" "$fragment") \
            || die "could not read the auto-mode block of $fragment"
        [[ -z "$problem" ]] || die "$fragment: autoMode.environment $problem"
    done
}

# merge_settings LIVE_JSON_PATH FRAGMENT_PATHS… — print the live settings file merged with the
# fragments, in the order given. An absent live file is the empty object. A live file that is not
# a single JSON object, a fragment whose auto-mode block is malformed, or a merge that fails, dies.
merge_settings() {
    local live_path="$1"
    shift
    require_org_wide_blocks "$@"
    local live_arguments=(--slurpfile live_documents "$live_path")
    [[ -e "$live_path" ]] || live_arguments=(--argjson live_documents "$ABSENT_LIVE_DOCUMENTS")
    jq -n -S --indent 2 "${live_arguments[@]}" \
        --arg org_wide_heading "$ORG_WIDE_HEADING" \
        --arg user_specific_heading "$USER_SPECIFIC_HEADING" \
        --arg redirection_re "$HOOK_REDIRECTION_RE" \
        --arg script_path_re "$HOOK_SCRIPT_PATH_RE" \
        --argjson wrapper_words "$HOOK_WRAPPER_WORDS_JSON" \
        "$JQ_MERGE" "$@" \
        || die "could not merge $live_path with the fragments"
}

# substitute_home — stdin JSON to stdout, with $HOME replaced in the marketplace paths only.
substitute_home() {
    jq -S --indent 2 --arg placeholder "$HOME_PLACEHOLDER" --arg home "$HOME" "$JQ_SUBSTITUTE_HOME" \
        || die "could not substitute \$HOME in the marketplace paths"
}

# render_settings — print the render of SETTINGS_PATH: merged with FRAGMENTS, $HOME substituted.
render_settings() {
    local merged
    # merge_settings dies inside the command substitution, having said why; pass its exit on.
    merged=$(merge_settings "$SETTINGS_PATH" "${FRAGMENTS[@]}") || exit "$EXIT_COULD_NOT_RUN"
    substitute_home <<< "$merged"
}

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
    # write_settings is a stub that dies until the writer lands, so --check and --apply reach it
    # and nothing else.
    case "$MODE" in
        list-fragments) printf '%s\n' "${FRAGMENTS[@]}" ;;
        print)          render_settings ;;
        check|apply)    write_settings ;;
    esac
}

main "$@"
