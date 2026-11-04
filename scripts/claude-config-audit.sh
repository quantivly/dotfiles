#!/usr/bin/env bash
#
# scripts/claude-config-audit.sh
# ==============================
#
# Collect every agent host's Claude Code configuration into one workspace on the
# laptop, and report where the hosts agree or differ.
#
# WHY. The laptop, dev, sol-build and nanoclaw each grew their own ~/.claude (or
# ~/.claude-herdr) by hand, so no one can say which skills, hooks, memory and
# settings a host has, or which copy is the reference. The shared-configuration
# design (docs/superpowers/specs/2026-11-04-shared-claude-config-design.md) needs
# that answer BEFORE any host is rendered from, or synced to, a shared source:
# overwriting across hosts without it destroys whichever copy was newer.
#
# TWO VERBS.
#   --collect   for each host, copy its configuration tree into
#               <workspace>/<name>/ (over ssh, or locally for `local`) and write
#               facts.tsv beside it, replacing that host's earlier collect.
#   --matrix    read the workspace's facts.tsv files and print one row per fact,
#               one column per host, marking where the hosts differ.
#
# READ-ONLY. Nothing is changed on any host. Credentials, transcripts, caches and
# plugin stores are excluded from what is copied (EXCLUDE_NAMES), and the only
# thing written is the workspace.
#
# Usage:
#   claude-config-audit.sh --collect [--workspace DIR] [--host NAME=ALIAS:CFGDIR]...
#   claude-config-audit.sh --matrix  [--workspace DIR] [--host NAME=ALIAS:CFGDIR]...
#   claude-config-audit.sh --help
#     --workspace DIR              default: ~/Projects/handoffs/2026-11-claude-config-audit
#     --host NAME=ALIAS:CFGDIR     repeatable; replaces the default hosts. ALIAS is an
#                                  ssh alias, or `local` to collect without ssh;
#                                  CFGDIR is a dot-directory under that host's $HOME
#
# Exit: --collect  0 every host collected · 2 a host failed
#       --matrix   0 identical · 1 drift · 2 a declared host has no facts.tsv
#       64 usage
#
# Test overrides (scripts/test-claude-config-audit.sh): CLAUDE_CONFIG_AUDIT_SSH (the ssh
# command), CLAUDE_CONFIG_AUDIT_WORKSPACE (the default workspace).

set -uo pipefail

SELF="${BASH_SOURCE[0]}"

# --- constants ----------------------------------------------------------------------------------

DEFAULT_WORKSPACE="$HOME/Projects/handoffs/2026-11-claude-config-audit"

# name=alias:cfgdir. `local` as the alias means collect without ssh.
DEFAULT_HOSTS=(
    "laptop=local:.claude"
    "dev=dev:.claude"
    "sol-build=sol-build:.claude"
    "nanoclaw=nanoclaw:.claude-herdr"
)

# Interpolated into ssh command lines and tar arguments, so anything else is refused
# before it can reach a shell or a path.
ALIAS_RE='^[A-Za-z0-9._-]+$'
CFGDIR_RE='^\.[A-Za-z0-9._-]+$'

SSH_CMD="${CLAUDE_CONFIG_AUDIT_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=30 -o ForwardAgent=no}"

# Never copied: credentials, transcripts and caches, and plugin stores that a host
# re-downloads. Matched against names inside the configuration directory.
EXCLUDE_NAMES=(
    '.credentials.json*'
    '.claude.json*'
    '*.jsonl'
    'sessions'
    'shell-snapshots'
    'file-history'
    'paste-cache'
    'debug'
    'cache'
    'backups'
    'downloads'
    'telemetry'
    'security'
    '*.signature*'
    'plugins/cache'
    'plugins/marketplaces'
    'plugins/repos'
    'plugins/data'
    'plugins/store'
    'plugins/synced'
    'skills/synced'
)

EXIT_COLLECT_FAILED=2
EXIT_USAGE=64

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDACTOR="$DOTFILES/scripts/redact-secrets.sh"

# The include set: these paths under the config dir, each projects/*/memory/ dir, and for each
# project root under $HOME its CLAUDE.md and its repos' .claude dirs, one level deep. A missing
# one is logged as absent, never a failure.
CFG_INCLUDE_PATHS=(
    CLAUDE.md settings.json settings.local.json keybindings.json
    hooks skills agents commands rules
    plugins/known_marketplaces.json plugins/installed_plugins.json
)
PROJECT_ROOTS=(quantivly Projects toysim)

# Read by absolute path: dev's non-interactive ssh has no ~/.local/bin on PATH. The field is
# the whitespace-separated word of `--version` holding the version: `2.1.300 (Claude Code)`
# and `herdr 0.9.5`.
CLAUDE_BIN_RELATIVE='.local/bin/claude'
CLAUDE_VERSION_FIELD=0
HERDR_BIN_RELATIVE='.local/bin/herdr'
HERDR_VERSION_FIELD=1

# collect.log lines are TAG<TAB>path.
ABSENT_TAG='absent'
BINARY_SKIPPED_TAG='binary-skipped'

LOCAL_ALIAS='local'
REMOTE_SHELL_COMMAND='bash -s --'
STAGING_PREFIX='.collecting-'
UNPACK_ERRORS_SUFFIX='.unpack-errors'
REDACTING_SUFFIX='.redacting'

# --- the remote collect -------------------------------------------------------------------------
#
# Sent on stdin to `bash -s -- CFGDIR` on the host, with the include-set constants above
# prepended by declare -p, so the host and this script share one definition of them. It
# prints one tar stream: facts.tsv, links.tsv, collect.log, and the include set renamed into
# the workspace layout (cfg/, memory/<key>/, roots/<root>.CLAUDE.md, repos/<root>/<repo>/.claude/)
# with every symlink dereferenced. It reads only: the one write is its own mktemp -d holding
# those three metadata files and the file list, removed on exit. Everything runs inside a
# function so bash has read the whole script before any command can consume stdin.
IFS= read -r -d '' REMOTE_SCRIPT_BODY <<'REMOTE' || true
set -u

# tar's "file changed as we read it": the archive is still whole.
TAR_EXIT_FILE_CHANGED=1

is_present() { [[ -e "$1" || -L "$1" ]]; }

note_absent() { printf '%s\t%s\n' "$ABSENT_TAG" "$1" >> "$META_DIR/collect.log"; }

version_field() {   # BINARY FIELD_INDEX → that word of `BINARY --version`, or unknown
    local binary="$1" field_index="$2" version_line
    local -a version_words=()
    if [[ -x "$binary" ]] && version_line=$("$binary" --version 2>/dev/null </dev/null); then
        read -r -a version_words <<<"$version_line"
    fi
    printf '%s\n' "${version_words[field_index]:-unknown}"
}

collect_this_host() {   # CFGDIR
    local cfgdir="$1"
    cd "$HOME" || exit 1
    if [[ ! -d "$cfgdir" ]]; then
        printf '%s has no %s\n' "$HOME" "$cfgdir" >&2
        exit 1
    fi
    META_DIR=$(mktemp -d) || exit 1
    trap 'rm -rf "$META_DIR"' EXIT
    : > "$META_DIR/collect.log"; : > "$META_DIR/include.list"; : > "$META_DIR/links.tsv"

    local include_path memory_dir root repo_claude_dir memory_found=no
    local -a include_starts=()
    for include_path in "${CFG_INCLUDE_PATHS[@]}"; do
        if is_present "$cfgdir/$include_path"; then include_starts+=("$cfgdir/$include_path")
        else note_absent "$include_path"; fi
    done
    for memory_dir in "$cfgdir"/projects/*/memory; do
        is_present "$memory_dir" || continue
        include_starts+=("$memory_dir"); memory_found=yes
    done
    [[ "$memory_found" == yes ]] || note_absent 'projects/*/memory'
    for root in "${PROJECT_ROOTS[@]}"; do
        if [[ ! -d "$root" ]]; then note_absent "$root"; continue; fi
        if is_present "$root/CLAUDE.md"; then include_starts+=("$root/CLAUDE.md")
        else note_absent "$root/CLAUDE.md"; fi
        for repo_claude_dir in "$root"/*/.claude; do
            if is_present "$repo_claude_dir"; then include_starts+=("$repo_claude_dir"); fi
        done
    done

    # EXCLUDE_NAMES: a bare name matches at any depth, a/b matches that path's tail.
    local excluded_name
    local -a prune_tests=()
    for excluded_name in "${EXCLUDE_NAMES[@]}"; do
        if (( ${#prune_tests[@]} )); then prune_tests+=(-o); fi
        if [[ "$excluded_name" == */* ]]; then prune_tests+=(-path "*/$excluded_name")
        else prune_tests+=(-name "$excluded_name"); fi
    done

    # The workspace layout as sed s-expressions, applied in order by tar to every member and by
    # sed to every links.tsv path. The memory rule must come first: the cfg/ rule matches the
    # memory dirs too. No rule matches another's output.
    local cfgdir_pattern="${cfgdir//./\\.}"
    local -a layout_rules=(
        "s,^$cfgdir_pattern/projects/\([^/]*\)/memory,memory/\1,"
        "s,^$cfgdir_pattern/,cfg/,"
    )
    for root in "${PROJECT_ROOTS[@]}"; do
        layout_rules+=(
            "s,^$root/CLAUDE\.md,roots/$root.CLAUDE.md,"
            "s,^$root/\([^/]*\)/\.claude,repos/$root/\1/.claude,"
        )
    done
    local layout_rule
    local -a tar_layout_args=() sed_layout_args=()
    for layout_rule in "${layout_rules[@]}"; do
        tar_layout_args+=("--transform=$layout_rule")
        sed_layout_args+=(-e "$layout_rule")
    done

    # find with no start path would walk all of $HOME, so an empty include set lists nothing.
    if (( ${#include_starts[@]} )); then
        find -L "${include_starts[@]}" \( "${prune_tests[@]}" \) -prune -o -type f -print0 \
            > "$META_DIR/include.list"
        # -L reports a followed link's target as empty, so each link found is read again
        # without following it.
        local link_path
        local -a link_paths=()
        while IFS= read -r -d '' link_path; do link_paths+=("$link_path"); done \
            < <(find -L "${include_starts[@]}" \( "${prune_tests[@]}" \) -prune -o -xtype l -print0)
        if (( ${#link_paths[@]} )); then
            find "${link_paths[@]}" -maxdepth 0 -printf '%p\t%l\n' | sed "${sed_layout_args[@]}" \
                > "$META_DIR/links.tsv"
        fi
    fi

    local host_name user_name claude_version herdr_version collected_at
    host_name=$(hostname 2>/dev/null) || host_name=$(uname -n)
    user_name=$(id -un)
    claude_version=$(version_field "$HOME/$CLAUDE_BIN_RELATIVE" "$CLAUDE_VERSION_FIELD")
    herdr_version=$(version_field "$HOME/$HERDR_BIN_RELATIVE" "$HERDR_VERSION_FIELD")
    collected_at=$(date -u +%FT%TZ)
    printf '%s\t%s\n' hostname "$host_name" user "$user_name" home "$HOME" cfgdir "$cfgdir" \
        claude_version "$claude_version" herdr_version "$herdr_version" \
        collected_at "$collected_at" > "$META_DIR/facts.tsv"

    local tar_status
    tar -c -f - -h --hard-dereference --ignore-failed-read --null --no-recursion \
        "${tar_layout_args[@]}" -T "$META_DIR/include.list" \
        -C "$META_DIR" facts.tsv links.tsv collect.log
    tar_status=$?
    (( tar_status <= TAR_EXIT_FILE_CHANGED )) || exit "$tar_status"
    exit 0
}

collect_this_host "$1"
REMOTE
REMOTE_CONSTANTS=$(declare -p EXCLUDE_NAMES CFG_INCLUDE_PATHS PROJECT_ROOTS \
    CLAUDE_BIN_RELATIVE CLAUDE_VERSION_FIELD HERDR_BIN_RELATIVE HERDR_VERSION_FIELD ABSENT_TAG)
readonly remote_script="$REMOTE_CONSTANTS"$'\n'"$REMOTE_SCRIPT_BODY"

# --- failure ------------------------------------------------------------------------------------

usage() { sed -n '/^# Usage:/,/^# Exit:/p' "$SELF" | sed '$d; s/^# \{0,1\}//'; }

warn() { printf 'claude-config-audit: %s\n' "$*" >&2; }

die() { warn "$@"; exit "$EXIT_COLLECT_FAILED"; }

usage_error() { printf 'claude-config-audit: %s\n\n' "$*" >&2; usage >&2; exit "$EXIT_USAGE"; }

# --- arguments ----------------------------------------------------------------------------------

MODE=""
WORKSPACE="${CLAUDE_CONFIG_AUDIT_WORKSPACE:-$DEFAULT_WORKSPACE}"
HOSTS=()

split_host_spec() {   # NAME=ALIAS:CFGDIR → sets SPEC_NAME, SPEC_ALIAS, SPEC_CFGDIR
    SPEC_NAME="${1%%=*}"
    SPEC_ALIAS="${1#*=}"; SPEC_ALIAS="${SPEC_ALIAS%%:*}"
    SPEC_CFGDIR="${1#*:}"
}

validate_host_spec() {   # $1 = name=alias:cfgdir
    local spec="$1"
    [[ "$spec" == *=*:* ]] || usage_error "--host wants NAME=ALIAS:CFGDIR, got '$spec'"
    split_host_spec "$spec"
    [[ "$SPEC_NAME" =~ $ALIAS_RE ]]   || usage_error "host name '$SPEC_NAME' must match $ALIAS_RE"
    [[ "$SPEC_ALIAS" =~ $ALIAS_RE ]]  || usage_error "host alias '$SPEC_ALIAS' must match $ALIAS_RE"
    [[ "$SPEC_CFGDIR" =~ $CFGDIR_RE ]] || usage_error "config dir '$SPEC_CFGDIR' must match $CFGDIR_RE"
}

parse_args() {
    local custom_hosts=()
    local -A seen_host_names=()
    while (( $# )); do
        case "$1" in
            --collect) MODE=collect ;;
            --matrix)  MODE=matrix ;;
            --help|-h) usage; exit 0 ;;
            --workspace)
                (( $# >= 2 )) || usage_error "--workspace needs a directory"
                WORKSPACE="$2"; shift ;;
            --host)
                (( $# >= 2 )) || usage_error "--host needs NAME=ALIAS:CFGDIR"
                validate_host_spec "$2"
                # The name is the host's workspace directory, so two hosts may not share one.
                [[ -z "${seen_host_names[$SPEC_NAME]:-}" ]] \
                    || usage_error "host name '$SPEC_NAME' is given twice"
                seen_host_names[$SPEC_NAME]=1
                custom_hosts+=("$2"); shift ;;
            *) usage_error "unknown argument '$1'" ;;
        esac
        shift
    done
    [[ -n "$MODE" ]] || usage_error "say what to do: --collect or --matrix"
    if (( ${#custom_hosts[@]} )); then HOSTS=("${custom_hosts[@]}"); else HOSTS=("${DEFAULT_HOSTS[@]}"); fi
}

# --- --collect ----------------------------------------------------------------------------------

# Every text file under DIR is rewritten in place through the redactor; a file grep calls
# binary (it holds a NUL) is deleted and logged, since the redactor cannot be trusted to see
# into it. `^` rather than `.`, and the -s guard, keep empty and blank-line-only files as text.
# The redactor runs under LC_ALL=C because in a UTF-8 locale its by-name rules stop at an
# invalid byte and leave the value whole (measured: MY_TOKEN=\xe9… survives under C.UTF-8).
redact_tree() {   # DIR → 0 when every file was redacted or skipped, 1 when the redactor failed
    local tree_dir="$1" file_path relative_path redacting_path
    local -a tree_files=() binary_skipped_lines=()
    mapfile -d '' tree_files < <(find "$tree_dir" -type f -print0)
    for file_path in "${tree_files[@]}"; do
        relative_path="${file_path#"$tree_dir"/}"
        if [[ -s "$file_path" ]] && ! LC_ALL=C grep -Iq '^' "$file_path"; then
            rm -f "$file_path"
            binary_skipped_lines+=("$BINARY_SKIPPED_TAG"$'\t'"$relative_path")
            continue
        fi
        redacting_path="$file_path$REDACTING_SUFFIX"
        if ! LC_ALL=C "$REDACTOR" < "$file_path" > "$redacting_path"; then
            rm -f "$redacting_path"
            return 1
        fi
        mv -f "$redacting_path" "$file_path" || return 1
    done
    if (( ${#binary_skipped_lines[@]} )); then
        printf '%s\n' "${binary_skipped_lines[@]}" >> "$tree_dir/collect.log"
    fi
}

# A re-collect replaces the earlier one before it starts, so neither a stale file nor, after
# a failure, a stale facts.tsv survives it. Anything else at that path is not ours to remove.
remove_earlier_collect() {   # NAME → 0 when $WORKSPACE/NAME is now absent, 1 when it is not ours
    local name="$1"
    local host_dir="$WORKSPACE/$name"
    [[ -e "$host_dir" || -L "$host_dir" ]] || return 0
    if [[ -L "$host_dir" || ! -f "$host_dir/facts.tsv" ]]; then
        warn "collect of $name failed: $host_dir is not an earlier collect (no facts.tsv), so it is left alone"
        return 1
    fi
    rm -rf "$host_dir"
}

collect_remote() {   # NAME ALIAS CFGDIR → 0 collected into $WORKSPACE/NAME, 1 failed (why, on stderr)
    local name="$1" alias_name="$2" cfgdir="$3"
    local host_dir="$WORKSPACE/$name"
    local remote_command="$REMOTE_SHELL_COMMAND $cfgdir"
    local staging_dir unpack_errors_path unpack_errors failure=""
    local -a pipe_status=()

    remove_earlier_collect "$name" || return 1
    if ! staging_dir=$(mktemp -d "$WORKSPACE/$STAGING_PREFIX$name.XXXXXX"); then
        warn "collect of $name failed: cannot create a staging directory in $WORKSPACE"
        return 1
    fi
    unpack_errors_path="$staging_dir$UNPACK_ERRORS_SUFFIX"

    # SSH_CMD is a command with its options, word-split on purpose. CFGDIR matched CFGDIR_RE,
    # so remote_command holds nothing a remote shell would expand.
    # shellcheck disable=SC2086
    $SSH_CMD "$alias_name" "$remote_command" <<<"$remote_script" \
        | tar -x -f - -C "$staging_dir" 2>"$unpack_errors_path"
    pipe_status=("${PIPESTATUS[@]}")

    if (( pipe_status[0] != 0 )); then
        failure="the ssh session exited ${pipe_status[0]}"
    elif (( pipe_status[1] != 0 )); then
        unpack_errors=$(<"$unpack_errors_path")
        failure="the stream did not unpack: $unpack_errors"
    elif [[ ! -f "$staging_dir/facts.tsv" ]]; then
        failure="the stream carried no facts.tsv"
    elif ! redact_tree "$staging_dir"; then
        failure="the redactor failed, so nothing from this host is kept"
    elif ! mv "$staging_dir" "$host_dir"; then
        failure="cannot move the collect into $host_dir"
    fi
    rm -f "$unpack_errors_path"
    if [[ -n "$failure" ]]; then
        rm -rf "$staging_dir"
        warn "collect of $name failed: $failure"
        return 1
    fi
}

collect_host() {   # NAME ALIAS CFGDIR → 0 collected, 1 failed
    if [[ "$2" == "$LOCAL_ALIAS" ]]; then
        warn "collect of $1 failed: collecting this machine (alias $LOCAL_ALIAS) is not implemented yet"
        return 1
    fi
    collect_remote "$@"
}

# hosts.tsv (name, alias, cfgdir, collected_at, status) is written once, after every host,
# so a re-run replaces it instead of adding to it.
collect_main() {
    [[ -x "$REDACTOR" ]] || die "the redactor $REDACTOR is missing; nothing is collected without it"
    mkdir -p "$WORKSPACE" || die "cannot create the workspace $WORKSPACE"
    local spec attempted_at host_status host_row
    local -a host_rows=() failed_names=()
    for spec in "${HOSTS[@]}"; do
        split_host_spec "$spec"
        attempted_at=$(date -u +%FT%TZ)
        if collect_host "$SPEC_NAME" "$SPEC_ALIAS" "$SPEC_CFGDIR"; then
            host_status=ok
        else
            host_status=failed
            failed_names+=("$SPEC_NAME")
        fi
        printf -v host_row '%s\t%s\t%s\t%s\t%s' \
            "$SPEC_NAME" "$SPEC_ALIAS" "$SPEC_CFGDIR" "$attempted_at" "$host_status"
        host_rows+=("$host_row")
    done
    printf '%s\n' "${host_rows[@]}" > "$WORKSPACE/hosts.tsv"
    (( ${#failed_names[@]} == 0 )) || die "not every host was collected; failed: ${failed_names[*]}"
}

# --- --matrix (Task 5) --------------------------------------------------------------------------

matrix_main()  { die "--matrix is not implemented"; }

main() {
    parse_args "$@"
    case "$MODE" in
        collect) collect_main ;;
        matrix)  matrix_main ;;
    esac
}

main "$@"
