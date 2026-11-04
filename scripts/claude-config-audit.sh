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
# Exit: --collect  0 every host collected · 2 a host failed · 130/143 interrupted (Ctrl-C/SIGTERM)
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

# Interpolated into ssh command lines, workspace paths and the remote's paths, so anything
# else is refused before it can reach a shell or a path. An alias or name may not start with
# `-` (ssh would read `-Fevil` as an option) or a dot (`.` and `..` name directories), and a
# config dir may not be `..` or `...` (the collect would read $HOME's parent).
ALIAS_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
CFGDIR_RE='^\.[A-Za-z0-9_-][A-Za-z0-9._-]*$'

SSH_CMD="${CLAUDE_CONFIG_AUDIT_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=30 -o ForwardAgent=no}"

# Never copied: credentials, transcripts and caches, plugin stores that a host re-downloads,
# and whole checkouts. Pruned at every depth of every collected tree (the config dir's paths,
# memory dirs, repo .claude dirs): a bare name matches that name anywhere, a/b matches a
# path ending in a/b.
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
    'worktrees'
)

EXIT_COLLECT_FAILED=2
EXIT_USAGE=64
EXIT_INTERRUPTED=130
EXIT_TERMINATED=143

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDACTOR="$DOTFILES/scripts/redact-secrets.sh"

# The include set: these paths under the config dir, each projects/*/memory/ dir, for each
# project root under $HOME its CLAUDE.md and its repos' .claude dirs, one level deep, and the
# HOME_REPO_CLAUDE_DIRS. A missing one is logged as absent, never a failure.
CFG_INCLUDE_PATHS=(
    CLAUDE.md settings.json settings.local.json keybindings.json
    hooks skills agents commands rules
    plugins/known_marketplaces.json plugins/installed_plugins.json
)
PROJECT_ROOTS=(quantivly Projects toysim)
# Repo .claude dirs directly under $HOME, which no ROOT/*/.claude glob reaches because the
# checkout is dot-named: the dotfiles repo's own .claude holds the claude-accounts project
# skill on the laptop and on dev. Laid out as repos/home/<path>.
HOME_REPO_CLAUDE_DIRS=(.dotfiles/.claude)
HOME_REPOS_LAYOUT_ROOT='repos/home'

# Read by absolute path: dev's non-interactive ssh has no ~/.local/bin on PATH. The field is
# the whitespace-separated word of `--version` holding the version: `2.1.300 (Claude Code)`
# and `herdr 0.9.5`.
CLAUDE_BIN_RELATIVE='.local/bin/claude'
CLAUDE_VERSION_FIELD=0
HERDR_BIN_RELATIVE='.local/bin/herdr'
HERDR_VERSION_FIELD=1

# The laptop's per-seat account dirs, each holding its own copy of settings.json (made by the
# account-dir builder at launch, so a copy can drift from ~/.claude/settings.json). Collected
# for `local` only, as account-dirs/<seat>/settings.json.
ACCOUNT_DIRS_RELATIVE='.local/state/claude-account-dirs'
ACCOUNT_DIR_SETTINGS_NAME='settings.json'
ACCOUNT_DIRS_LAYOUT_DIR='account-dirs'

# collect.log lines are TAG<TAB>path, or TAG<TAB>seat for an account dir.
ABSENT_TAG='absent'
BINARY_SKIPPED_TAG='binary-skipped'
ACCOUNT_DIR_LINK_TAG='account-dir-link'

LOCAL_ALIAS='local'
# How every host runs remote_script, given CFGDIR as $1: over ssh, or directly for `local`.
COLLECT_SCRIPT_SHELL=(bash -s --)
STAGING_PREFIX='.collecting-'
UNPACK_ERRORS_SUFFIX='.unpack-errors'
REDACTING_SUFFIX='.redacting'
# An earlier collect being replaced is renamed to $STAGING_PREFIX<name>$REPLACED_SUFFIX, a name
# the startup sweep removes if a run dies before it does.
REPLACED_SUFFIX='.replaced'

# --- the remote collect -------------------------------------------------------------------------
#
# Sent on stdin to `bash -s -- CFGDIR` (COLLECT_SCRIPT_SHELL) on the host — over ssh, or run
# directly for `local` — with the include-set constants above prepended by declare -p, so the
# host and this script share one definition of them. It prints one tar stream: facts.tsv,
# links.tsv, collect.log, and the include set renamed into the workspace layout (cfg/,
# memory/<key>/, roots/<root>.CLAUDE.md, repos/<root>/<repo>/.claude/, repos/home/<repo>/.claude/)
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

    local include_path memory_dir root repo_claude_dir home_repo_claude_dir memory_found=no
    local -a include_starts=()
    for include_path in "${CFG_INCLUDE_PATHS[@]}"; do
        if is_present "$cfgdir/$include_path"; then include_starts+=("$cfgdir/$include_path")
        else note_absent "$include_path"; fi
    done
    for home_repo_claude_dir in "${HOME_REPO_CLAUDE_DIRS[@]}"; do
        if is_present "$home_repo_claude_dir"; then include_starts+=("$home_repo_claude_dir")
        else note_absent "$home_repo_claude_dir"; fi
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
    # sed to every links.tsv path. The home-repo and memory rules must precede the cfg/ rule,
    # which would also match their paths: the memory dirs' always, a home repo's when the config
    # dir is its parent (.dotfiles). No rule matches another's output.
    local cfgdir_pattern="${cfgdir//./\\.}"
    local -a layout_rules=()
    for home_repo_claude_dir in "${HOME_REPO_CLAUDE_DIRS[@]}"; do
        layout_rules+=("s,^${home_repo_claude_dir//./\\.},$HOME_REPOS_LAYOUT_ROOT/$home_repo_claude_dir,")
    done
    layout_rules+=(
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
    tar -c -f - -h --hard-dereference --ignore-failed-read --null --no-recursion --mode=u+rwX \
        "${tar_layout_args[@]}" -T "$META_DIR/include.list" \
        -C "$META_DIR" facts.tsv links.tsv collect.log
    tar_status=$?
    (( tar_status <= TAR_EXIT_FILE_CHANGED )) || exit "$tar_status"
    exit 0
}

collect_this_host "$1"
REMOTE
REMOTE_CONSTANTS=$(declare -p EXCLUDE_NAMES CFG_INCLUDE_PATHS PROJECT_ROOTS \
    HOME_REPO_CLAUDE_DIRS HOME_REPOS_LAYOUT_ROOT \
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

# A staging directory holds a host's content BEFORE it is redacted, so it must never outlive
# the run that made it: the traps in collect_main remove the current one on exit, Ctrl-C or
# SIGTERM, and collect_main sweeps any a SIGKILLed run left behind. bash runs the EXIT trap on
# a fatal SIGTERM too (measured); INT and TERM are trapped anyway for an explicit exit status.
CURRENT_STAGING_DIR=""

# Owner rwx on every directory and rw on every file, so a read-only directory in a stream
# (GNU tar unpacks a 555 directory member as 555) can stop neither a redaction nor a removal.
# find, not chmod -R: -type d/-type f never follow a symlink out of the tree, and -exec \;
# opens each directory before find descends into it.
make_tree_owner_writable() {   # DIR
    find "$1" -type d -exec chmod u+rwx {} \;
    find "$1" -type f -exec chmod u+rw {} +
}

remove_tree() {   # PATH → 0 when PATH no longer exists, 1 when it survived the removal
    local tree_path="$1"
    [[ -e "$tree_path" || -L "$tree_path" ]] || return 0
    if [[ -d "$tree_path" && ! -L "$tree_path" ]]; then make_tree_owner_writable "$tree_path"; fi
    rm -rf "$tree_path"
    [[ ! -e "$tree_path" && ! -L "$tree_path" ]]
}

remove_current_staging() {
    [[ -n "$CURRENT_STAGING_DIR" ]] || return 0
    rm -f "$CURRENT_STAGING_DIR$UNPACK_ERRORS_SUFFIX"
    if ! remove_tree "$CURRENT_STAGING_DIR"; then
        warn "could not remove $CURRENT_STAGING_DIR, which may hold UNREDACTED host content; remove it by hand"
    fi
    CURRENT_STAGING_DIR=""
}

# Every text file under DIR is rewritten in place through the redactor; a file grep calls
# binary (it holds a NUL) is deleted and logged, since the redactor cannot be trusted to see
# into it. `^` rather than `.`, and the -s guard, keep empty and blank-line-only files as text.
# The redactor runs under LC_ALL=C because in a UTF-8 locale its by-name rules stop at an
# invalid byte and leave the value whole (measured: MY_TOKEN=\xe9… survives under C.UTF-8).
redact_tree() {   # DIR → 0 when every file was redacted or skipped, 1 when one could be neither
    local tree_dir="$1" file_path relative_path redacting_path
    local -a tree_files=() binary_skipped_lines=()
    mapfile -d '' tree_files < <(find "$tree_dir" -type f -print0)
    for file_path in "${tree_files[@]}"; do
        relative_path="${file_path#"$tree_dir"/}"
        if [[ -s "$file_path" ]] && ! LC_ALL=C grep -Iq '^' "$file_path"; then
            rm -f "$file_path"
            [[ ! -e "$file_path" ]] || return 1
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

# Only an earlier collect (a real directory holding facts.tsv) is ever replaced; anything else
# at a host's workspace path is not ours to remove.
is_earlier_collect() { [[ -d "$1" && ! -L "$1" && -f "$1/facts.tsv" ]]; }

# The new collect replaces the earlier one only once it is complete and redacted, so a failed
# re-collect (an ssh drop) leaves the earlier tree whole; hosts.tsv says which is current. The
# swap is two renames, never a removal in place: an interrupt inside an rm of HOST_DIR would
# leave a partial tree there that still holds facts.tsv and so passes for a collect. The
# earlier tree waits at ASIDE_DIR, under the staging prefix, until the new one is in place.
install_collect() {   # STAGING_DIR HOST_DIR ASIDE_DIR → 0 when STAGING_DIR is now HOST_DIR
    local staging_dir="$1" host_dir="$2" aside_dir="$3" earlier_set_aside=no
    if [[ -e "$host_dir" || -L "$host_dir" ]]; then
        is_earlier_collect "$host_dir" || return 1
        # mv onto an existing directory would move HOST_DIR inside it.
        remove_tree "$aside_dir" || return 1
        mv "$host_dir" "$aside_dir" || return 1
        earlier_set_aside=yes
    fi
    if ! mv "$staging_dir" "$host_dir"; then
        if [[ "$earlier_set_aside" == yes ]] && ! mv "$aside_dir" "$host_dir"; then
            warn "the earlier collect is at $aside_dir; the next --collect removes it"
        fi
        return 1
    fi
    if [[ "$earlier_set_aside" == yes ]] && ! remove_tree "$aside_dir"; then
        warn "could not remove $aside_dir, the replaced collect; the next --collect removes it"
    fi
    return 0
}

# The one path every host's content takes: SCRIPT_RUNNER is the command that runs remote_script
# from stdin (ssh to the host, or bash here) and prints its tar stream, which is unpacked into a
# staging dir, given ADD_TO_STAGING's extra files, redacted, and only then installed at
# $WORKSPACE/NAME. STREAM_SOURCE names the runner in a failure message. The runner is a plain
# command, never a function: a function in a pipeline runs in a forked subshell, so a signal
# meant for this collect would reach ssh's parent subshell instead.
collect_from_stream() {   # NAME STREAM_SOURCE ADD_TO_STAGING SCRIPT_RUNNER [ARG]... → 0 collected, 1 failed
    local name="$1" stream_source="$2" add_to_staging="$3"
    shift 3
    local host_dir="$WORKSPACE/$name"
    local aside_dir="$WORKSPACE/$STAGING_PREFIX$name$REPLACED_SUFFIX"
    local staging_dir unpack_errors_path unpack_errors failure=""
    local -a pipe_status=()

    if [[ -e "$host_dir" || -L "$host_dir" ]] && ! is_earlier_collect "$host_dir"; then
        warn "collect of $name failed: $host_dir is not an earlier collect (no facts.tsv), so it is left alone"
        return 1
    fi
    if ! staging_dir=$(mktemp -d "$WORKSPACE/$STAGING_PREFIX$name.XXXXXX"); then
        warn "collect of $name failed: cannot create a staging directory in $WORKSPACE"
        return 1
    fi
    CURRENT_STAGING_DIR="$staging_dir"
    unpack_errors_path="$staging_dir$UNPACK_ERRORS_SUFFIX"

    "$@" <<<"$remote_script" | tar -x -f - -C "$staging_dir" 2>"$unpack_errors_path"
    pipe_status=("${PIPESTATUS[@]}")
    # A `./` member in the stream gives the staging dir the host's mode for it, which may let
    # others read what is not yet redacted; mktemp's 700 is put back before anything else.
    chmod 700 "$staging_dir"
    make_tree_owner_writable "$staging_dir"

    if (( pipe_status[0] != 0 )); then
        failure="$stream_source exited ${pipe_status[0]}"
    elif (( pipe_status[1] != 0 )); then
        unpack_errors=$(<"$unpack_errors_path")
        failure="the stream did not unpack: $unpack_errors"
    elif [[ ! -f "$staging_dir/facts.tsv" ]]; then
        failure="the stream carried no facts.tsv"
    elif ! "$add_to_staging" "$staging_dir"; then
        failure="a file beside the stream could not be copied"
    elif ! redact_tree "$staging_dir"; then
        failure="a collected file could be neither redacted nor removed, so nothing from this host is kept"
    elif ! install_collect "$staging_dir" "$host_dir" "$aside_dir"; then
        failure="cannot replace $host_dir with the new collect"
    fi
    rm -f "$unpack_errors_path"
    if [[ -n "$failure" ]]; then
        warn "collect of $name failed: $failure"
        remove_current_staging
        return 1
    fi
    CURRENT_STAGING_DIR=""
}

add_nothing_to_staging() { :; }   # STAGING_DIR: a remote host's stream is its whole collect

# Each account dir's settings.json, copied into STAGING_DIR/account-dirs/<seat>/ so it is
# redacted and installed with the rest. Only a regular file reached through no symlink is a copy
# that can drift: a settings.json that is a link, or one in a seat dir that is a link
# (personal -> personal-0), is the linked file itself, so it is logged instead of copied.
add_account_dir_settings() {   # STAGING_DIR → 0, or 1 when a copy failed
    local staging_dir="$1" settings_path seat_dir seat seat_layout_dir found_any=no
    local collect_log="$staging_dir/collect.log"
    for settings_path in "$HOME/$ACCOUNT_DIRS_RELATIVE"/*/"$ACCOUNT_DIR_SETTINGS_NAME"; do
        [[ -e "$settings_path" || -L "$settings_path" ]] || continue
        found_any=yes
        seat_dir="${settings_path%/*}"
        seat="${seat_dir##*/}"
        if [[ -L "$seat_dir" || -L "$settings_path" ]]; then
            printf '%s\t%s\n' "$ACCOUNT_DIR_LINK_TAG" "$seat" >> "$collect_log" || return 1
            continue
        fi
        # A directory or a FIFO by that name is no settings copy, and cp would fail or block on it.
        [[ -f "$settings_path" ]] || continue
        seat_layout_dir="$staging_dir/$ACCOUNT_DIRS_LAYOUT_DIR/$seat"
        mkdir -p "$seat_layout_dir" || return 1
        cp -- "$settings_path" "$seat_layout_dir/$ACCOUNT_DIR_SETTINGS_NAME" || return 1
    done
    if [[ "$found_any" == no ]]; then
        printf '%s\t%s\n' "$ABSENT_TAG" "$ACCOUNT_DIRS_RELATIVE/*/$ACCOUNT_DIR_SETTINGS_NAME" >> "$collect_log" \
            || return 1
    fi
    return 0
}

collect_remote() {   # NAME ALIAS CFGDIR → 0 collected into $WORKSPACE/NAME, 1 failed (why, on stderr)
    local name="$1" alias_name="$2" cfgdir="$3"
    # One string, as ssh hands the remote shell one. CFGDIR matched CFGDIR_RE, so it holds
    # nothing a remote shell would expand.
    local remote_command="${COLLECT_SCRIPT_SHELL[*]} $cfgdir"
    # SSH_CMD is a command with its options, word-split on purpose.
    # shellcheck disable=SC2086
    collect_from_stream "$name" 'the ssh session' add_nothing_to_staging \
        $SSH_CMD "$alias_name" "$remote_command"
}

# The laptop: the same remote_script, run here under $HOME with no ssh, plus the account dirs'
# settings copies.
collect_local() {   # NAME CFGDIR → 0 collected into $WORKSPACE/NAME, 1 failed (why, on stderr)
    local name="$1" cfgdir="$2"
    collect_from_stream "$name" 'the local collect script' add_account_dir_settings \
        "${COLLECT_SCRIPT_SHELL[@]}" "$cfgdir"
}

collect_host() {   # NAME ALIAS CFGDIR → 0 collected, 1 failed
    if [[ "$2" == "$LOCAL_ALIAS" ]]; then
        collect_local "$1" "$3"
    else
        collect_remote "$@"
    fi
}

# hosts.tsv (name, alias, cfgdir, collected_at, status) is written once, after every host,
# so a re-run replaces it instead of adding to it.
collect_main() {
    [[ -x "$REDACTOR" ]] || die "the redactor $REDACTOR is missing; nothing is collected without it"
    mkdir -p "$WORKSPACE" || die "cannot create the workspace $WORKSPACE"
    trap remove_current_staging EXIT
    trap 'remove_current_staging; exit "$EXIT_INTERRUPTED"' INT
    trap 'remove_current_staging; exit "$EXIT_TERMINATED"' TERM
    local stale_staging
    for stale_staging in "$WORKSPACE/$STAGING_PREFIX"*; do
        remove_tree "$stale_staging" \
            || die "cannot remove $stale_staging, left by an earlier run; it may hold UNREDACTED host content"
    done
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
