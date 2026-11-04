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
#   --matrix    read only the workspace and write five reports at its root, one
#               column per host: matrix.tsv/.md (every collected file by layout
#               path), settings-matrix.md (settings.json key by key) and
#               memory-matrix.tsv/.md (memory files per store, across homes).
#
# READ-ONLY. Nothing is changed on any host. Credentials, transcripts, caches and
# plugin stores are excluded from what is copied (EXCLUDE_NAMES), and the only
# thing written is the workspace.
#
# Usage:
#   claude-config-audit.sh --collect [--workspace DIR] [--host NAME=ALIAS:CFGDIR]...
#   claude-config-audit.sh --matrix  [--workspace DIR]
#   claude-config-audit.sh --help
#     --workspace DIR              default: ~/Projects/handoffs/2026-11-claude-config-audit
#     --host NAME=ALIAS:CFGDIR     --collect only, repeatable; replaces the default hosts.
#                                  ALIAS is an ssh alias, or `local` to collect without
#                                  ssh; CFGDIR is a dot-directory under that host's $HOME.
#                                  --matrix reports on every host in hosts.tsv
#
# Exit: --collect  0 every host collected · 2 a host failed, or hosts.tsv cannot be parsed (nothing
#                  is collected) · 130/143 interrupted (Ctrl-C/SIGTERM). Its rows are merged into
#                  hosts.tsv: a host it did not collect keeps its row
#       --matrix   0 every row identical · 1 drift · 2 a host in hosts.tsv has no facts.tsv or a
#                  failed collect, a collect is not named in hosts.tsv (no report is written), or
#                  a report cannot be written
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

EXIT_DRIFT=1
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
TAB=$'\t'
# How every host runs remote_script, given CFGDIR as $1: over ssh, or directly for `local`.
COLLECT_SCRIPT_SHELL=(bash -s --)
STAGING_PREFIX='.collecting-'
UNPACK_ERRORS_SUFFIX='.unpack-errors'
REDACTING_SUFFIX='.redacting'
# An earlier collect being replaced is renamed aside to $STAGING_PREFIX<name>$REPLACED_SUFFIX
# until the new one is in place, and is the only copy of it meanwhile. If the run dies between
# the two renames, the traps put it back; after a SIGKILL, the next run's startup sweep puts
# back any aside whose host dir is missing, and removes it only when the host dir is there.
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
    if [[ "$MODE" == matrix ]] && (( ${#custom_hosts[@]} )); then
        usage_error "--host applies to --collect only; --matrix reports on every host in hosts.tsv"
    fi
    if (( ${#custom_hosts[@]} )); then HOSTS=("${custom_hosts[@]}"); else HOSTS=("${DEFAULT_HOSTS[@]}"); fi
}

# --- hosts.tsv ----------------------------------------------------------------------------------
#
# One row per host collected into the workspace, by any run: name, alias, cfgdir, collected_at,
# status. --collect merges its own hosts' rows in and keeps every other row as it was;
# --matrix reports on every row.

HOSTS_TSV_NAME='hosts.tsv'
HOSTS_TSV_FIELD_COUNT=5
HOST_OK_STATUS='ok'
HOST_FAILED_STATUS='failed'
# A row is split on this, never on a tab through IFS: a tab is IFS whitespace, so an empty field
# would fold away and every field after it shift one place left.
HOSTS_TSV_SPLIT_SEPARATOR=$'\x1f'

# Filled by read_hosts_tsv, in the file's order.
HOSTS_TSV_NAMES=()
declare -A HOSTS_TSV_ROWS=()           # name → the row as written
declare -A HOSTS_TSV_STATUSES=()       # name → status
declare -A HOSTS_TSV_COLLECTED_AT=()   # name → collected_at

# FILE → 0 with HOSTS_TSV_* filled (left empty when FILE does not exist), 1 when a row cannot be
# parsed (why, on stderr): not five fields, a name ALIAS_RE refuses, or a name given twice.
read_hosts_tsv() {
    local hosts_tsv="$1" hosts_row host_name line_number=0
    local -a row_fields=()
    HOSTS_TSV_NAMES=()
    HOSTS_TSV_ROWS=()
    HOSTS_TSV_STATUSES=()
    HOSTS_TSV_COLLECTED_AT=()
    [[ -e "$hosts_tsv" ]] || return 0
    if [[ ! -f "$hosts_tsv" || ! -r "$hosts_tsv" ]]; then
        warn "$hosts_tsv is not a readable file"
        return 1
    fi
    while IFS= read -r hosts_row || [[ -n "$hosts_row" ]]; do
        line_number=$(( line_number + 1 ))
        [[ -n "$hosts_row" ]] || continue
        row_fields=()
        if [[ "$hosts_row" != *"$HOSTS_TSV_SPLIT_SEPARATOR"* ]]; then
            IFS="$HOSTS_TSV_SPLIT_SEPARATOR" read -r -a row_fields <<<"${hosts_row//"$TAB"/"$HOSTS_TSV_SPLIT_SEPARATOR"}"
        fi
        if (( ${#row_fields[@]} != HOSTS_TSV_FIELD_COUNT )); then
            warn "$hosts_tsv line $line_number is not $HOSTS_TSV_FIELD_COUNT tab-separated fields (name, alias, cfgdir, collected_at, status)"
            return 1
        fi
        host_name="${row_fields[0]}"
        if [[ ! "$host_name" =~ $ALIAS_RE ]]; then
            warn "$hosts_tsv line $line_number names '$host_name', which is not a valid host name"
            return 1
        fi
        if [[ -n "${HOSTS_TSV_ROWS[$host_name]+named}" ]]; then
            warn "$hosts_tsv names $host_name twice"
            return 1
        fi
        HOSTS_TSV_NAMES+=("$host_name")
        HOSTS_TSV_ROWS[$host_name]=$hosts_row
        HOSTS_TSV_COLLECTED_AT[$host_name]="${row_fields[3]}"
        HOSTS_TSV_STATUSES[$host_name]="${row_fields[4]}"
    done < "$hosts_tsv"
}

# --- --collect ----------------------------------------------------------------------------------

# A staging directory holds a host's content BEFORE it is redacted, so it must never outlive
# the run that made it: the traps in collect_main remove the current one on exit, Ctrl-C or
# SIGTERM, and collect_main sweeps any a SIGKILLed run left behind. bash runs the EXIT trap on
# a fatal SIGTERM too (measured); INT and TERM are trapped anyway for an explicit exit status.
CURRENT_STAGING_DIR=""
# Set while install_collect swaps an earlier collect out: where it was set aside, and the host
# dir it came from, so the traps can put it back (see REPLACED_SUFFIX).
CURRENT_ASIDE_DIR=""
CURRENT_HOST_DIR=""
# The new hosts.tsv while it is written, before it is renamed into place.
CURRENT_HOSTS_TSV_TEMP=""
# This run's hosts.tsv rows, by host name, for write_merged_hosts_tsv.
declare -A THIS_RUN_HOST_ROWS=()

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

path_exists() { [[ -e "$1" || -L "$1" ]]; }

# An earlier collect set aside at ASIDE_DIR is put back at HOST_DIR when nothing is there (the
# swap never completed), and removed when something is (normally the new collect). A partial
# aside, whose removal was cut short and so lacks facts.tsv, is removed and never put back.
settle_set_aside_collect() {   # ASIDE_DIR HOST_DIR
    local aside_dir="$1" host_dir="$2"
    path_exists "$aside_dir" || return 0
    if path_exists "$host_dir" || ! is_earlier_collect "$aside_dir"; then
        remove_tree "$aside_dir" \
            || warn "could not remove $aside_dir, a replaced collect; the next --collect removes it"
    elif ! mv "$aside_dir" "$host_dir"; then
        warn "the earlier collect of $host_dir is at $aside_dir; the next --collect puts it back"
    fi
}

finish_current_swap() {
    [[ -n "$CURRENT_ASIDE_DIR" ]] || return 0
    settle_set_aside_collect "$CURRENT_ASIDE_DIR" "$CURRENT_HOST_DIR"
    CURRENT_ASIDE_DIR=""
    CURRENT_HOST_DIR=""
}

# What the traps run: an earlier collect a swap had set aside is settled first, since it may be
# the only copy, then the staging dir is removed.
clean_up_current_collect() {
    finish_current_swap
    remove_current_staging
    if [[ -n "$CURRENT_HOSTS_TSV_TEMP" ]]; then rm -f "$CURRENT_HOSTS_TSV_TEMP"; fi
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
        # The host's mtime, which tar restored, is kept: --matrix names the newest copy by it.
        touch -r "$file_path" "$redacting_path" || return 1
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
# earlier tree waits at ASIDE_DIR, under the staging prefix, until the new one is in place,
# and the swap is recorded first so the traps can put it back if the run dies in between.
install_collect() {   # STAGING_DIR HOST_DIR ASIDE_DIR → 0 when STAGING_DIR is now HOST_DIR
    local staging_dir="$1" host_dir="$2" aside_dir="$3" install_status=0
    if path_exists "$host_dir"; then
        is_earlier_collect "$host_dir" || return 1
        # mv onto an existing directory would move HOST_DIR inside it.
        remove_tree "$aside_dir" || return 1
        CURRENT_ASIDE_DIR="$aside_dir"
        CURRENT_HOST_DIR="$host_dir"
        if ! mv "$host_dir" "$aside_dir"; then
            finish_current_swap
            return 1
        fi
    fi
    mv "$staging_dir" "$host_dir" || install_status=1
    # Removes the earlier tree once the new one is in place, or puts it back if it is not.
    finish_current_swap
    return "$install_status"
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

# HOSTS_TSV THIS_RUN_NAME... → HOSTS_TSV rewritten from the rows read_hosts_tsv found and
# THIS_RUN_HOST_ROWS: every earlier row in its place (this run's row where it collected that host
# again), then the hosts new to the file in run order. Written to a temp file and renamed over
# the old one, so a failed write leaves the old one whole.
write_merged_hosts_tsv() {
    local hosts_tsv="$1" host_name
    shift
    local -a merged_rows=()
    for host_name in "${HOSTS_TSV_NAMES[@]}"; do
        if [[ -n "${THIS_RUN_HOST_ROWS[$host_name]+collected}" ]]; then
            merged_rows+=("${THIS_RUN_HOST_ROWS[$host_name]}")
        else
            merged_rows+=("${HOSTS_TSV_ROWS[$host_name]}")
        fi
    done
    for host_name in "$@"; do
        if [[ -z "${HOSTS_TSV_ROWS[$host_name]+named}" ]]; then merged_rows+=("${THIS_RUN_HOST_ROWS[$host_name]}"); fi
    done
    CURRENT_HOSTS_TSV_TEMP=$(mktemp "$WORKSPACE/$STAGING_PREFIX$HOSTS_TSV_NAME.XXXXXX") || return 1
    printf '%s\n' "${merged_rows[@]}" > "$CURRENT_HOSTS_TSV_TEMP" || return 1
    mv -f "$CURRENT_HOSTS_TSV_TEMP" "$hosts_tsv" || return 1
    CURRENT_HOSTS_TSV_TEMP=""
}

# Each host's row goes into hosts.tsv once every host is done: merged with the rows of hosts
# this run did not collect, so re-collecting one host never drops the others from --matrix.
collect_main() {
    [[ -x "$REDACTOR" ]] || die "the redactor $REDACTOR is missing; nothing is collected without it"
    mkdir -p "$WORKSPACE" || die "cannot create the workspace $WORKSPACE"
    local hosts_tsv="$WORKSPACE/$HOSTS_TSV_NAME"
    read_hosts_tsv "$hosts_tsv" || die "cannot parse $hosts_tsv, which this collect would merge into; fix or remove it (nothing was collected)"
    trap clean_up_current_collect EXIT
    trap 'clean_up_current_collect; exit "$EXIT_INTERRUPTED"' INT
    trap 'clean_up_current_collect; exit "$EXIT_TERMINATED"' TERM
    # What a SIGKILLed run left: a staging dir is removed; an earlier collect it had set aside
    # is put back if its host dir is missing (settle_set_aside_collect).
    local stale_entry stale_host_name
    for stale_entry in "$WORKSPACE/$STAGING_PREFIX"*; do
        if [[ "$stale_entry" == *"$REPLACED_SUFFIX" ]]; then
            stale_host_name="${stale_entry#"$WORKSPACE/$STAGING_PREFIX"}"
            stale_host_name="${stale_host_name%"$REPLACED_SUFFIX"}"
            settle_set_aside_collect "$stale_entry" "$WORKSPACE/$stale_host_name"
            continue
        fi
        remove_tree "$stale_entry" \
            || die "cannot remove $stale_entry, left by an earlier run; it may hold UNREDACTED host content"
    done
    local spec attempted_at host_status host_row
    local -a collected_names=() failed_names=()
    for spec in "${HOSTS[@]}"; do
        split_host_spec "$spec"
        attempted_at=$(date -u +%FT%TZ)
        if collect_host "$SPEC_NAME" "$SPEC_ALIAS" "$SPEC_CFGDIR"; then
            host_status=$HOST_OK_STATUS
        else
            host_status=$HOST_FAILED_STATUS
            failed_names+=("$SPEC_NAME")
        fi
        printf -v host_row '%s\t%s\t%s\t%s\t%s' \
            "$SPEC_NAME" "$SPEC_ALIAS" "$SPEC_CFGDIR" "$attempted_at" "$host_status"
        THIS_RUN_HOST_ROWS[$SPEC_NAME]=$host_row
        collected_names+=("$SPEC_NAME")
    done
    write_merged_hosts_tsv "$hosts_tsv" "${collected_names[@]}" || die "cannot write $hosts_tsv"
    (( ${#failed_names[@]} == 0 )) || die "not every host was collected; failed: ${failed_names[*]}"
}

# --- --matrix -----------------------------------------------------------------------------------
#
# Reads the workspace only: hosts.tsv, and each host's facts.tsv, links.tsv and collected tree.
# Writes the five reports at the workspace root and nothing else; no host is reached.

FACTS_NAME='facts.tsv'
LINKS_NAME='links.tsv'
MATRIX_TSV_NAME='matrix.tsv'
MATRIX_MD_NAME='matrix.md'
SETTINGS_MATRIX_MD_NAME='settings-matrix.md'
MEMORY_MATRIX_TSV_NAME='memory-matrix.tsv'
MEMORY_MATRIX_MD_NAME='memory-matrix.md'

# Every file under these layout roots is an artifact, keyed by its layout path; memory/ is
# compared per store instead, since a store's key differs from home to home.
ARTIFACT_LAYOUT_ROOTS=(cfg roots repos "$ACCOUNT_DIRS_LAYOUT_DIR")
MEMORY_LAYOUT_ROOT='memory'
CFG_SETTINGS_LAYOUT_PATH='cfg/settings.json'

# artifact_status's classes. ABSENT_HASH stands for a host without the file.
ABSENT_HASH='-'
STATUS_IDENTICAL='identical'
STATUS_DIFFERS='differs'
ONLY_ON_PREFIX='only-on:'
MISSING_ON_PREFIX='missing-on:'
NEWEST_PREFIX='newest:'
SAME_AS_CFG_SETTINGS="same-as:$CFG_SETTINGS_LAYOUT_PATH"
DIFFERS_FROM_CFG_SETTINGS="differs-from:$CFG_SETTINGS_LAYOUT_PATH"
SHA256_HEX_LENGTH=64

# A host's state in a row: present or absent, or, when any host holds the artifact through a
# symlink, every holder's provenance, so a link is never mistaken for a duplicate copy.
PRESENT_STATE='present'
ABSENT_STATE='absent'
COPY_STATE='copy'
LINK_STATE_PREFIX='link→'

# A projects key is the project's absolute path with every character but a letter or digit
# turned into a dash: /home/zvi/quantivly/hub is -home-zvi-quantivly-hub.
PROJECTS_HOME_PREFIX='-home-'
FRONTMATTER_FENCE='---'
FRONTMATTER_DESCRIPTION_KEY='description:'
SAME_FACT_LABEL='same-fact?'
SAME_FACT_NAME_SEPARATOR='~'

# settings-matrix.md. Each JQ_ filter reads one host's settings.json and prints key<TAB>value
# lines for one section; the values are then compared host by host.
SETTINGS_PARSED_STATE='parsed'
SETTINGS_INVALID_STATE='invalid'
SETTINGS_KEY_ABSENT_CELL='—'
PRESENT_MARK='✓'
NO_MARKETPLACE_SOURCE='none'
# A value this long or longer prints as a label, v1, v2… (hosts sharing a label share the value),
# with the first characters of the value's sha256 so it can be found again.
LONG_VALUE_MIN_CHARS=40
VARIANT_LABEL_PREFIX='v'
VALUE_DIGEST_PREFIX_LENGTH=8
# settings_status reuses artifact_status, which wants an mtime; a settings value has none.
SETTINGS_VALUE_MTIME=0
# A hook command's script: the first word holding a slash, without its quotes or an assignment.
HOOK_SCRIPT_PATH_RE=$'[^[:space:]\'"=;|&<>()]*/[^[:space:]\'"/;|&<>()]+'
# The top-level keys that have a section of their own; permissions' other keys join the rest.
KEYS_COMPARED_APART_JSON='["permissions","hooks","enabledPlugins","extraKnownMarketplaces"]'
JQ_IS_OBJECT='type == "object"'
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_ALLOW_SETS='.permissions.allow? // [] | .[]? | strings | [., $present] | @tsv'
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_HOOK_BASENAMES='.hooks? // {} | to_entries[]? | .key as $event | .value | arrays | .[] | .hooks? // [] | .[]? | .command? | strings | (first(match($script_path_re).string) // (split(" ") | map(select(length > 0)) | first) // "") as $script_path | [$event + " " + ($script_path | split("/") | last // ""), $present] | @tsv'
JQ_PLUGIN_NAMES='.enabledPlugins? // {} | to_entries[]? | [.key, (.value | tostring)] | @tsv'
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_MARKETPLACE_SOURCES='.extraKnownMarketplaces? // {} | to_entries[]? | [.key, ((.value | objects | .source | objects | .source) // $no_source | tostring)] | @tsv'
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_OTHER_KEYS='def key_sorted: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end); ((to_entries[] | select(.key | IN($compared_apart[]) | not)), (.permissions | objects | to_entries[] | select(.key != "allow") | .key |= "permissions." + .)) | [.key, (.value | key_sorted | tojson)] | @tsv'
JQ_SETTINGS_ARGUMENTS=(--arg present "$PRESENT_MARK" --arg script_path_re "$HOOK_SCRIPT_PATH_RE"
    --arg no_source "$NO_MARKETPLACE_SOURCE" --argjson compared_apart "$KEYS_COMPARED_APART_JSON")

# The Markdown tables: column 1 is the artifact, store file or key, column 2 the status, and
# the hosts' columns follow.
STATUS_COLUMN=2
FIRST_HOST_COLUMN=3
AWK_IS_IDENTICAL_FUNCTION='function is_identical(row_status) { return row_status == identical || row_status == same_as_cfg }'
DECIMAL_COUNT_RE='^[0-9]+$'
MATRIX_LEGEND="Status: identical (one hash on every host) · only-on:HOST · missing-on:HOSTS (equal where present) · differs newest:HOST (by mtime). An account-dir copy is compared with its own host's cfg/settings.json instead: same-as or differs-from. Cell: present · absent, or for an artifact any host holds through a symlink, link→TARGET · copy."
MEMORY_LEGEND='One section per store, its key stripped of -home-USER- so stores meet across homes. Status as in matrix.md. A same-fact? row names files whose frontmatter descriptions match (lowercased, whitespace collapsed) under different names.'
SETTINGS_LEGEND="Each host's cfg/settings.json, key by key. Status: same · only HOST · missing on HOSTS · differs. A host without the file reads absent; a key a host does not set reads —. Under every other key, a value (as JSON, object keys sorted) of $LONG_VALUE_MIN_CHARS characters or more prints as v1, v2… with its sha256 prefix."

# Filled by load_matrix_hosts and load_host_index; HOST<TAB>... keys are per host.
MATRIX_HOSTS=()
declare -A FILE_HASHES=()       # HOST<TAB>layout path → sha256
declare -A FILE_MTIMES=()       # HOST<TAB>layout path → mtime, in seconds
declare -A LINK_TARGETS=()      # HOST<TAB>layout path → target, from links.tsv
declare -A ARTIFACT_PATHS=()    # layout path under ARTIFACT_LAYOUT_ROOTS → 1
declare -A MEMORY_FILES=()      # HOST<TAB>store<TAB>file → its layout path on HOST
declare -A MEMORY_ENTRIES=()    # store<TAB>file → 1
declare -A SETTINGS_FILE_STATES=()   # HOST → parsed, absent or invalid

facts_value() { awk -F'\t' -v fact_key="$2" '$1 == fact_key { print $2; exit }' "$1"; }   # FACTS_TSV KEY

# hosts.tsv is the authority on which collects are valid: every host it names must be `ok` and
# hold facts.tsv, and every collect in the workspace (a directory holding facts.tsv) must be named
# in it, or no report is written (exit 2, each such host named).
load_matrix_hosts() {
    local hosts_tsv="$WORKSPACE/$HOSTS_TSV_NAME" host_name host_status facts_path collect_dir_name
    local -a invalid_hosts=()
    [[ -f "$hosts_tsv" ]] || die "$WORKSPACE has no $HOSTS_TSV_NAME; run --collect first"
    read_hosts_tsv "$hosts_tsv" || die "cannot parse $hosts_tsv; no report written"
    (( ${#HOSTS_TSV_NAMES[@]} )) || die "$hosts_tsv names no host"
    for host_name in "${HOSTS_TSV_NAMES[@]}"; do
        host_status="${HOSTS_TSV_STATUSES[$host_name]}"
        if [[ "$host_status" != "$HOST_OK_STATUS" ]]; then
            warn "$host_name: $HOSTS_TSV_NAME says its collect failed (status '$host_status', not '$HOST_OK_STATUS'); re-run --collect"
            invalid_hosts+=("$host_name")
        elif [[ ! -f "$WORKSPACE/$host_name/$FACTS_NAME" ]]; then
            warn "$host_name has no $FACTS_NAME in $WORKSPACE; re-run --collect"
            invalid_hosts+=("$host_name")
        fi
    done
    # A collect hosts.tsv does not name would be left out of every report without a word.
    for facts_path in "$WORKSPACE"/*/"$FACTS_NAME"; do
        [[ -f "$facts_path" ]] || continue
        collect_dir_name="${facts_path%/"$FACTS_NAME"}"
        collect_dir_name="${collect_dir_name##*/}"
        if [[ -z "${HOSTS_TSV_ROWS[$collect_dir_name]+named}" ]]; then
            warn "$WORKSPACE/$collect_dir_name holds a collect that $HOSTS_TSV_NAME does not name; re-run --collect for it, or move it out"
            invalid_hosts+=("$collect_dir_name")
        fi
    done
    (( ${#invalid_hosts[@]} == 0 )) || die "no report written; not every collect in $WORKSPACE is valid and named in $HOSTS_TSV_NAME: ${invalid_hosts[*]}"
    MATRIX_HOSTS=("${HOSTS_TSV_NAMES[@]}")
}

# Every file under ROOT... of HOST_DIR, one line each: layout path<TAB>sha256<TAB>mtime. The
# hashes and mtimes are read in batches in the order of the path list and matched to it by
# position, so no file name is ever parsed back out of sha256sum's or stat's output.
index_host_files() {   # HOST_DIR ROOT... → 0, or 1 when a file cannot be indexed (why, on stderr)
    local host_dir="$1" layout_root layout_path hash_line path_index
    shift
    local -a existing_roots=() layout_paths=() hash_lines=() mtimes=()
    for layout_root in "$@"; do
        if [[ -d "$host_dir/$layout_root" ]]; then existing_roots+=("$layout_root"); fi
    done
    (( ${#existing_roots[@]} )) || return 0
    mapfile -d '' layout_paths < <(cd "$host_dir" && find "${existing_roots[@]}" -type f -print0 | LC_ALL=C sort -z)
    (( ${#layout_paths[@]} )) || return 0
    for layout_path in "${layout_paths[@]}"; do
        if [[ "$layout_path" == *[$'\t\n']* ]]; then
            warn "$host_dir/$layout_path has a tab or newline in its name, which no matrix row can hold"
            return 1
        fi
    done
    mapfile -t hash_lines < <(cd "$host_dir" && printf '%s\0' "${layout_paths[@]}" | xargs -0 sha256sum --)
    mapfile -t mtimes < <(cd "$host_dir" && printf '%s\0' "${layout_paths[@]}" | xargs -0 stat -c %Y --)
    if (( ${#hash_lines[@]} != ${#layout_paths[@]} || ${#mtimes[@]} != ${#layout_paths[@]} )); then
        warn "could not hash and date every file under $host_dir"
        return 1
    fi
    for path_index in "${!layout_paths[@]}"; do
        # sha256sum marks a line whose name it had to escape with a leading backslash.
        hash_line="${hash_lines[path_index]#\\}"
        printf '%s\t%s\t%s\n' "${layout_paths[path_index]}" "${hash_line:0:SHA256_HEX_LENGTH}" "${mtimes[path_index]}"
    done
}

# KEY USER → the store's name across hosts: KEY without a leading -home-USER-, USER spelled as a
# projects key spells it (every character but a letter or digit a dash); KEY itself otherwise.
store_key() {
    local projects_key="$1" user_as_projects_key="${2//[^A-Za-z0-9]/-}"
    local home_prefix="$PROJECTS_HOME_PREFIX$user_as_projects_key-"
    if [[ "$projects_key" == "$home_prefix"?* ]]; then
        printf '%s\n' "${projects_key#"$home_prefix"}"
    else
        printf '%s\n' "$projects_key"
    fi
}

# FILE → its frontmatter description: lowercased, whitespace collapsed, one pair of enclosing
# quotes dropped; empty when the file has no frontmatter or no description in it.
fact_signature() {
    local file_path="$1" line description="" in_frontmatter=no
    local -a description_words=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$in_frontmatter" == no ]]; then
            [[ "$line" == "$FRONTMATTER_FENCE" ]] || return 0
            in_frontmatter=yes
            continue
        fi
        [[ "$line" != "$FRONTMATTER_FENCE" ]] || return 0
        if [[ "$line" == "$FRONTMATTER_DESCRIPTION_KEY"* ]]; then
            description="${line#"$FRONTMATTER_DESCRIPTION_KEY"}"
            break
        fi
    done < "$file_path"
    read -r -a description_words <<<"$description"
    description="${description_words[*]}"
    if [[ "$description" == \"*\" || "$description" == \'*\' ]] && (( ${#description} >= 2 )); then
        description="${description:1:${#description}-2}"
        read -r -a description_words <<<"$description"
        description="${description_words[*]}"
    fi
    printf '%s\n' "${description,,}"
}

load_host_index() {   # HOST → the indexes filled from $WORKSPACE/HOST; 1 when it cannot be indexed
    local host="$1" host_dir="$WORKSPACE/$1" host_files user_name layout_path file_hash file_mtime
    local path_in_memory projects_key file_in_store store_name link_line
    local -A store_names_by_key=()
    host_files=$(index_host_files "$host_dir" "${ARTIFACT_LAYOUT_ROOTS[@]}" "$MEMORY_LAYOUT_ROOT") || return 1
    user_name=$(facts_value "$host_dir/$FACTS_NAME" user)
    while IFS="$TAB" read -r layout_path file_hash file_mtime; do
        [[ -n "$layout_path" ]] || continue
        FILE_HASHES[$host$TAB$layout_path]=$file_hash
        FILE_MTIMES[$host$TAB$layout_path]=$file_mtime
        if [[ "$layout_path" != "$MEMORY_LAYOUT_ROOT"/* ]]; then
            ARTIFACT_PATHS[$layout_path]=1
            continue
        fi
        path_in_memory="${layout_path#"$MEMORY_LAYOUT_ROOT"/}"
        projects_key="${path_in_memory%%/*}"
        file_in_store="${path_in_memory#*/}"
        if [[ -z "${store_names_by_key[$projects_key]+named}" ]]; then
            store_names_by_key[$projects_key]=$(store_key "$projects_key" "$user_name")
        fi
        store_name="${store_names_by_key[$projects_key]}"
        MEMORY_FILES[$host$TAB$store_name$TAB$file_in_store]=$layout_path
        MEMORY_ENTRIES[$store_name$TAB$file_in_store]=1
    done <<<"$host_files"
    [[ -f "$host_dir/$LINKS_NAME" ]] || return 0
    while IFS= read -r link_line; do
        [[ "$link_line" == *"$TAB"* ]] || continue
        LINK_TARGETS[$host$TAB${link_line%%"$TAB"*}]="${link_line#*"$TAB"}"
    done < "$host_dir/$LINKS_NAME"
}

# HOST HASH MTIME [HOST HASH MTIME]... → how the copies compare, HASH being the file's sha256 on
# HOST or $ABSENT_HASH where HOST lacks it:
#   identical          present on every host, one hash
#   only-on:H          present on exactly one host (with one host in hosts.tsv, every artifact)
#   missing-on:H,…     present on some hosts, equal wherever present
#   differs newest:H   more than one hash; H holds the newest mtime (every host tied for it)
artifact_status() {
    local host file_hash file_mtime newest_mtime=-1
    local -a present_hosts=() missing_hosts=() newest_hosts=()
    local -A distinct_hashes=()
    while (( $# >= 3 )); do
        host="$1" file_hash="$2" file_mtime="$3"
        shift 3
        if [[ "$file_hash" == "$ABSENT_HASH" ]]; then
            missing_hosts+=("$host")
            continue
        fi
        present_hosts+=("$host")
        distinct_hashes[$file_hash]=1
        if (( file_mtime > newest_mtime )); then
            newest_mtime=$file_mtime
            newest_hosts=("$host")
        elif (( file_mtime == newest_mtime )); then
            newest_hosts+=("$host")
        fi
    done
    local IFS=,
    if (( ${#distinct_hashes[@]} > 1 )); then
        printf '%s %s%s\n' "$STATUS_DIFFERS" "$NEWEST_PREFIX" "${newest_hosts[*]}"
    elif (( ${#present_hosts[@]} == 1 )); then
        printf '%s%s\n' "$ONLY_ON_PREFIX" "${present_hosts[0]}"
    elif (( ${#missing_hosts[@]} )); then
        printf '%s%s\n' "$MISSING_ON_PREFIX" "${missing_hosts[*]}"
    else
        printf '%s\n' "$STATUS_IDENTICAL"
    fi
}

# HOST LAYOUT_PATH → link→TARGET when LAYOUT_PATH, or failing that its nearest ancestor, was a
# symlink on HOST (links.tsv records a linked directory once, so its files resolve to
# TARGET/<the rest of the path>); copy otherwise.
provenance() {
    local host="$1" linked_path="$2" path_below_link=""
    while :; do
        if [[ -n "${LINK_TARGETS[$host$TAB$linked_path]+recorded}" ]]; then
            printf '%s%s%s\n' "$LINK_STATE_PREFIX" "${LINK_TARGETS[$host$TAB$linked_path]}" "$path_below_link"
            return 0
        fi
        [[ "$linked_path" == */* ]] || break
        path_below_link="/${linked_path##*/}$path_below_link"
        linked_path="${linked_path%/*}"
    done
    printf '%s\n' "$COPY_STATE"
}

# LAYOUT_PATH... (one per host, in MATRIX_HOSTS order; empty where the host lacks the file) →
# the row's host:state cells, each after a tab.
print_host_state_cells() {
    local -a layout_paths=("$@") host_provenances=()
    local host_index any_link=no host_state
    for host_index in "${!MATRIX_HOSTS[@]}"; do
        host_provenances[host_index]=""
        [[ -n "${layout_paths[host_index]}" ]] || continue
        host_provenances[host_index]=$(provenance "${MATRIX_HOSTS[host_index]}" "${layout_paths[host_index]}")
        if [[ "${host_provenances[host_index]}" == "$LINK_STATE_PREFIX"* ]]; then any_link=yes; fi
    done
    for host_index in "${!MATRIX_HOSTS[@]}"; do
        if [[ -z "${layout_paths[host_index]}" ]]; then host_state=$ABSENT_STATE
        elif [[ "$any_link" == yes ]]; then host_state=${host_provenances[host_index]}
        else host_state=$PRESENT_STATE
        fi
        printf '\t%s:%s' "${MATRIX_HOSTS[host_index]}" "$host_state"
    done
}

print_tsv_header() {   # LEADING_COLUMN... → the header line: those columns, then one per host
    local IFS="$TAB"
    printf '%s\t%s\n' "$*" "${MATRIX_HOSTS[*]}"
}

sorted_lines() { (( $# )) || return 0; printf '%s\n' "$@" | LC_ALL=C sort; }   # WORD...

# account-dirs/<seat>/settings.json, the laptop's per-seat copies of cfg/settings.json.
is_account_dir_settings() {   # LAYOUT_PATH
    local seat_path="${1#"$ACCOUNT_DIRS_LAYOUT_DIR"/}"
    [[ "$1" == "$ACCOUNT_DIRS_LAYOUT_DIR"/* && "$seat_path" == */"$ACCOUNT_DIR_SETTINGS_NAME" ]] || return 1
    seat_path="${seat_path%/"$ACCOUNT_DIR_SETTINGS_NAME"}"
    [[ -n "$seat_path" && "$seat_path" != */* ]]
}

# ARTIFACT (an account-dir copy) → same-as:cfg/settings.json when every host holding it holds an
# identical cfg/settings.json, else differs-from:cfg/settings.json. The copies exist only on the
# laptop, so this, not a cross-host status, is how one drifts.
account_copy_status() {
    local artifact="$1" host
    for host in "${MATRIX_HOSTS[@]}"; do
        [[ -n "${FILE_HASHES[$host$TAB$artifact]+indexed}" ]] || continue
        if [[ "${FILE_HASHES[$host$TAB$artifact]}" != "${FILE_HASHES[$host$TAB$CFG_SETTINGS_LAYOUT_PATH]:-$ABSENT_HASH}" ]]; then
            printf '%s\n' "$DIFFERS_FROM_CFG_SETTINGS"
            return 0
        fi
    done
    printf '%s\n' "$SAME_AS_CFG_SETTINGS"
}

# matrix.tsv, on stdout: artifact<TAB>status<TAB>host:state…, one row per layout path of any host.
print_artifact_matrix() {
    local artifact host artifact_row_status
    local -a status_arguments=() host_layout_paths=()
    print_tsv_header artifact status
    while IFS= read -r artifact; do
        [[ -n "$artifact" ]] || continue
        status_arguments=()
        host_layout_paths=()
        for host in "${MATRIX_HOSTS[@]}"; do
            if [[ -n "${FILE_HASHES[$host$TAB$artifact]+indexed}" ]]; then
                status_arguments+=("$host" "${FILE_HASHES[$host$TAB$artifact]}" "${FILE_MTIMES[$host$TAB$artifact]}")
                host_layout_paths+=("$artifact")
            else
                status_arguments+=("$host" "$ABSENT_HASH" "$ABSENT_HASH")
                host_layout_paths+=("")
            fi
        done
        if is_account_dir_settings "$artifact"; then
            artifact_row_status=$(account_copy_status "$artifact")
        else
            artifact_row_status=$(artifact_status "${status_arguments[@]}")
        fi
        printf '%s\t%s' "$artifact" "$artifact_row_status"
        print_host_state_cells "${host_layout_paths[@]}"
        printf '\n'
    done < <(sorted_lines "${!ARTIFACT_PATHS[@]}")
}

# STORE FILE... → one same-fact? row for each description that two or more of the store's file
# names share: store<TAB>same-fact?<TAB>name~name…, names in the order first seen (hosts in
# hosts.tsv order, files sorted), each host's cell naming those it holds.
print_same_fact_rows() {
    local store_name="$1" host file_in_store layout_path signature names held_names delimited_names
    shift
    local -a signatures_in_order=() group_names=() held=()
    local -A names_by_signature=()
    for host in "${MATRIX_HOSTS[@]}"; do
        for file_in_store in "$@"; do
            [[ "$file_in_store" == *.md ]] || continue
            layout_path=${MEMORY_FILES[$host$TAB$store_name$TAB$file_in_store]:-}
            [[ -n "$layout_path" ]] || continue
            signature=$(fact_signature "$WORKSPACE/$host/$layout_path")
            [[ -n "$signature" ]] || continue
            if [[ -z "${names_by_signature[$signature]+seen}" ]]; then
                signatures_in_order+=("$signature")
                names_by_signature[$signature]=$file_in_store
                continue
            fi
            # Fenced by the separator on both sides, so a name matches only as a whole name.
            delimited_names="$SAME_FACT_NAME_SEPARATOR${names_by_signature[$signature]}$SAME_FACT_NAME_SEPARATOR"
            if [[ "$delimited_names" != *"$SAME_FACT_NAME_SEPARATOR$file_in_store$SAME_FACT_NAME_SEPARATOR"* ]]; then
                names_by_signature[$signature]+="$SAME_FACT_NAME_SEPARATOR$file_in_store"
            fi
        done
    done
    for signature in "${signatures_in_order[@]}"; do
        names=${names_by_signature[$signature]}
        [[ "$names" == *"$SAME_FACT_NAME_SEPARATOR"* ]] || continue
        IFS="$SAME_FACT_NAME_SEPARATOR" read -r -a group_names <<<"$names"
        printf '%s\t%s\t%s' "$store_name" "$SAME_FACT_LABEL" "$names"
        for host in "${MATRIX_HOSTS[@]}"; do
            held=()
            for file_in_store in "${group_names[@]}"; do
                if [[ -n "${MEMORY_FILES[$host$TAB$store_name$TAB$file_in_store]+held}" ]]; then held+=("$file_in_store"); fi
            done
            held_names=$(IFS=,; printf '%s' "${held[*]}")
            printf '\t%s:%s' "$host" "${held_names:-$ABSENT_STATE}"
        done
        printf '\n'
    done
}

# memory-matrix.tsv, on stdout: store<TAB>file<TAB>status<TAB>host:state…, each store's files
# sorted, then its same-fact? rows.
print_memory_matrix() {
    local entry store_name file_in_store host layout_path memory_row_status current_store=""
    local -a status_arguments=() host_layout_paths=() current_store_files=()
    print_tsv_header store file status
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        store_name="${entry%%"$TAB"*}"
        file_in_store="${entry#*"$TAB"}"
        if [[ "$store_name" != "$current_store" ]]; then
            if [[ -n "$current_store" ]]; then print_same_fact_rows "$current_store" "${current_store_files[@]}"; fi
            current_store=$store_name
            current_store_files=()
        fi
        current_store_files+=("$file_in_store")
        status_arguments=()
        host_layout_paths=()
        for host in "${MATRIX_HOSTS[@]}"; do
            layout_path=${MEMORY_FILES[$host$TAB$entry]:-}
            if [[ -n "$layout_path" ]]; then
                status_arguments+=("$host" "${FILE_HASHES[$host$TAB$layout_path]}" "${FILE_MTIMES[$host$TAB$layout_path]}")
            else
                status_arguments+=("$host" "$ABSENT_HASH" "$ABSENT_HASH")
            fi
            host_layout_paths+=("$layout_path")
        done
        memory_row_status=$(artifact_status "${status_arguments[@]}")
        printf '%s\t%s\t%s' "$store_name" "$file_in_store" "$memory_row_status"
        print_host_state_cells "${host_layout_paths[@]}"
        printf '\n'
    done < <(sorted_lines "${!MEMORY_ENTRIES[@]}")
    if [[ -n "$current_store" ]]; then print_same_fact_rows "$current_store" "${current_store_files[@]}"; fi
}

# PROGRAM [FILE]... → awk over TSV with is_identical(status) defined: identical, or an
# account-dir copy the same as its cfg/settings.json. Every count and ordering of the rows that
# are not identical goes through it, so they all share one meaning of "identical".
awk_over_statuses() {
    awk -F'\t' -v identical="$STATUS_IDENTICAL" -v same_as_cfg="$SAME_AS_CFG_SETTINGS" \
        -v status_column="$STATUS_COLUMN" "$AWK_IS_IDENTICAL_FUNCTION $1" "${@:2}"
}

# TSV on stdin, header line first → a Markdown table. Column 1 prints as code, every `|` is
# escaped, and a cell in a host column (FIRST_HOST_COLUMN on) drops its `<host>:` prefix, since
# the column's header names the host.
markdown_table() {
    awk -F'\t' -v first_host_column="$FIRST_HOST_COLUMN" '
        function escaped(text) { gsub(/\|/, "\\|", text); return text }
        function as_code(text) { if (index(text, "`")) return "`` " text " ``"; return "`" text "`" }
        NR == 1 {
            header_line = "|"; rule_line = "|"
            for (column = 1; column <= NF; column++) {
                column_name[column] = $column
                header_line = header_line " " escaped($column) " |"
                rule_line = rule_line "---|"
            }
            print header_line; print rule_line
            next
        }
        {
            row_line = "|"
            for (column = 1; column <= NF; column++) {
                cell = $column
                if (column >= first_host_column && index(cell, column_name[column] ":") == 1)
                    cell = substr(cell, length(column_name[column]) + 2)
                if (column == 1) cell = as_code(cell)
                row_line = row_line " " escaped(cell) " |"
            }
            print row_line
        }'
}

report_heading() {   # TITLE → a report's first line: TITLE, the workspace and each host's collect time
    local host collect_time_list
    local -a collect_times=()
    for host in "${MATRIX_HOSTS[@]}"; do
        collect_times+=("$host ${HOSTS_TSV_COLLECTED_AT[$host]}")
    done
    printf -v collect_time_list '%s, ' "${collect_times[@]}"
    printf '# %s: %s (collected %s)\n' "$1" "$WORKSPACE" "${collect_time_list%, }"
}

# HEADING TABLE_HEADER SECTION_ROWS → one Markdown section: HEADING with how many of the rows
# are not identical, then the table, those rows first (each group keeps its TSV order).
print_markdown_section() {
    local heading="$1" table_header="$2" section_rows="$3" section_counts ordered_rows
    # shellcheck disable=SC2016  # awk's own $fields, not the shell's
    section_counts=$(awk_over_statuses '!is_identical($status_column) { drift_count++ }
        END { print drift_count + 0 " of " NR }' <<<"$section_rows") || return 1
    # shellcheck disable=SC2016  # awk's own $fields, not the shell's
    ordered_rows=$(awk_over_statuses '{ if (is_identical($status_column)) identical_rows[++identical_count] = $0; else print }
        END { for (row = 1; row <= identical_count; row++) print identical_rows[row] }' <<<"$section_rows") || return 1
    printf '\n## %s (%s not identical)\n\n' "$heading" "$section_counts"
    printf '%s\n%s\n' "$table_header" "$ordered_rows" | markdown_table
}

# matrix.md, on stdout: matrix.tsv as one section per layout root.
print_matrix_markdown() {
    local matrix_tsv="$WORKSPACE/$MATRIX_TSV_NAME" layout_root table_header section_rows
    table_header=$(head -n 1 "$matrix_tsv") || return 1
    report_heading 'Claude config matrix'
    printf '\n%s\n' "$MATRIX_LEGEND"
    for layout_root in "${ARTIFACT_LAYOUT_ROOTS[@]}"; do
        section_rows=$(awk -F'\t' -v layout_prefix="$layout_root/" 'NR > 1 && index($1, layout_prefix) == 1' "$matrix_tsv") \
            || return 1
        [[ -n "$section_rows" ]] || continue
        print_markdown_section "$layout_root/" "$table_header" "$section_rows" || return 1
    done
}

# memory-matrix.md, on stdout: memory-matrix.tsv as one section per store, the store column dropped.
print_memory_markdown() {
    local memory_tsv="$WORKSPACE/$MEMORY_MATRIX_TSV_NAME" store_name table_header store_rows
    table_header=$(head -n 1 "$memory_tsv" | cut -f2-) || return 1
    report_heading 'Claude memory matrix'
    printf '\n%s\n' "$MEMORY_LEGEND"
    while IFS= read -r store_name; do
        store_rows=$(awk -F'\t' -v store_name="$store_name" 'NR > 1 && $1 == store_name' "$memory_tsv" | cut -f2-) \
            || return 1
        print_markdown_section "$store_name" "$table_header" "$store_rows" || return 1
    done < <(awk -F'\t' 'NR > 1 && !seen[$1]++ { print $1 }' "$memory_tsv")
}

# HOST VALUE [HOST VALUE]... → same · only HOST · missing on H,… · differs: artifact_status's
# classes over one settings key's values ($ABSENT_HASH where a host does not set it), in words.
settings_status() {
    local value_status
    local -a status_arguments=()
    while (( $# >= 2 )); do
        status_arguments+=("$1" "$2" "$SETTINGS_VALUE_MTIME")
        shift 2
    done
    value_status=$(artifact_status "${status_arguments[@]}")
    case "$value_status" in
        "$STATUS_IDENTICAL")     printf 'same\n' ;;
        "$ONLY_ON_PREFIX"*)      printf 'only %s\n' "${value_status#"$ONLY_ON_PREFIX"}" ;;
        "$MISSING_ON_PREFIX"*)   printf 'missing on %s\n' "${value_status#"$MISSING_ON_PREFIX"}" ;;
        *)                       printf '%s\n' "$STATUS_DIFFERS" ;;
    esac
}

# TITLE KEY_HEADER JQ_FILTER CELL_KIND → one settings-matrix.md section: a heading and a table
# with one row per key any host sets. CELL_KIND `value` prints each host's value as it is;
# `value_or_label` does so for a value shorter than LONG_VALUE_MIN_CHARS and prints a longer one
# as its label (v1, v2…, hosts sharing a label share the value) and sha256 prefix.
print_settings_section() {
    local section_title="$1" key_header="$2" jq_filter="$3" cell_kind="$4"
    local host settings_path section_lines section_line key value key_status host_cell host_cells section_tsv
    local variant_number value_digest value_digest_prefix
    local -a section_keys=() status_arguments=()
    local -A section_values=() key_seen=() variant_labels=() unreadable_hosts=()
    for host in "${MATRIX_HOSTS[@]}"; do
        [[ "${SETTINGS_FILE_STATES[$host]}" == "$SETTINGS_PARSED_STATE" ]] || continue
        settings_path="$WORKSPACE/$host/$CFG_SETTINGS_LAYOUT_PATH"
        if ! section_lines=$(jq -r "${JQ_SETTINGS_ARGUMENTS[@]}" "$jq_filter" "$settings_path" 2>/dev/null); then
            warn "$host: cannot read $section_title from $CFG_SETTINGS_LAYOUT_PATH; its column reads $SETTINGS_INVALID_STATE"
            unreadable_hosts[$host]=1
            continue
        fi
        while IFS= read -r section_line; do
            key="${section_line%%"$TAB"*}"
            value="${section_line#*"$TAB"}"
            [[ -n "$key" ]] || continue
            section_values[$host$TAB$key]=$value
            if [[ -z "${key_seen[$key]+seen}" ]]; then
                key_seen[$key]=1
                section_keys+=("$key")
            fi
        done <<<"$section_lines"
    done
    printf '\n## %s\n\n' "$section_title"
    if (( ${#section_keys[@]} == 0 )); then
        printf 'No host sets any.\n'
        return 0
    fi
    section_tsv=$(print_tsv_header "$key_header" status)
    while IFS= read -r key; do
        status_arguments=()
        for host in "${MATRIX_HOSTS[@]}"; do
            status_arguments+=("$host" "${section_values[$host$TAB$key]-$ABSENT_HASH}")
        done
        key_status=$(settings_status "${status_arguments[@]}")
        host_cells=""
        variant_labels=()
        for host in "${MATRIX_HOSTS[@]}"; do
            if [[ "${SETTINGS_FILE_STATES[$host]}" != "$SETTINGS_PARSED_STATE" ]]; then
                host_cell=${SETTINGS_FILE_STATES[$host]}
            elif [[ -n "${unreadable_hosts[$host]+unreadable}" ]]; then
                host_cell=$SETTINGS_INVALID_STATE
            elif [[ -z "${section_values[$host$TAB$key]+set}" ]]; then
                host_cell=$SETTINGS_KEY_ABSENT_CELL
            elif [[ "$cell_kind" == value_or_label ]] && (( ${#section_values[$host$TAB$key]} >= LONG_VALUE_MIN_CHARS )); then
                value=${section_values[$host$TAB$key]}
                if [[ -z "${variant_labels[$value]+labelled}" ]]; then
                    variant_number=$(( ${#variant_labels[@]} + 1 ))
                    value_digest=$(printf '%s' "$value" | sha256sum)
                    value_digest_prefix="${value_digest:0:VALUE_DIGEST_PREFIX_LENGTH}"
                    variant_labels[$value]="$VARIANT_LABEL_PREFIX$variant_number ($value_digest_prefix)"
                fi
                host_cell=${variant_labels[$value]}
            else
                host_cell=${section_values[$host$TAB$key]}
            fi
            host_cells+="$TAB$host:$host_cell"
        done
        section_tsv+=$'\n'"$key$TAB$key_status$host_cells"
    done < <(sorted_lines "${section_keys[@]}")
    printf '%s\n' "$section_tsv" | markdown_table
}

# settings-matrix.md, on stdout: every host's cfg/settings.json compared key by key.
settings_diff() {
    local host settings_path
    for host in "${MATRIX_HOSTS[@]}"; do
        settings_path="$WORKSPACE/$host/$CFG_SETTINGS_LAYOUT_PATH"
        if [[ ! -f "$settings_path" ]]; then
            SETTINGS_FILE_STATES[$host]=$ABSENT_STATE
        elif jq -e "$JQ_IS_OBJECT" "$settings_path" >/dev/null 2>&1; then
            SETTINGS_FILE_STATES[$host]=$SETTINGS_PARSED_STATE
        else
            warn "$host: $CFG_SETTINGS_LAYOUT_PATH is not a JSON object; its column reads $SETTINGS_INVALID_STATE"
            SETTINGS_FILE_STATES[$host]=$SETTINGS_INVALID_STATE
        fi
    done
    report_heading 'Claude settings matrix'
    printf '\n%s\n' "$SETTINGS_LEGEND"
    print_settings_section 'permissions.allow' rule "$JQ_ALLOW_SETS" value
    print_settings_section "hooks, by each command's script basename" 'event and script' "$JQ_HOOK_BASENAMES" value
    print_settings_section 'enabledPlugins' plugin "$JQ_PLUGIN_NAMES" value
    print_settings_section 'extraKnownMarketplaces, by source.source' marketplace "$JQ_MARKETPLACE_SOURCES" value
    print_settings_section 'every other key, by value' key "$JQ_OTHER_KEYS" value_or_label
}

# The rows that are not identical, in matrix.tsv (status in field 2) and then memory-matrix.tsv
# (field 3). FNR == NR marks the first file: comparing FILENAME with an awk -v value would not
# hold for a workspace path with a backslash, which -v turns into an escape.
count_drift_rows() {
    # shellcheck disable=SC2016  # awk's own $fields, not the shell's
    awk_over_statuses 'FNR == 1 { next }
        FNR == NR { if (!is_identical($2)) drift_count++; next }
        !is_identical($3) { drift_count++ }
        END { print drift_count + 0 }' "$WORKSPACE/$MATRIX_TSV_NAME" "$WORKSPACE/$MEMORY_MATRIX_TSV_NAME"
}

write_report() {   # REPORT_NAME PRINTER → PRINTER's output at $WORKSPACE/REPORT_NAME, or exit 2
    local report_path="$WORKSPACE/$1"
    "$2" > "$report_path" || die "cannot write $report_path; the reports in $WORKSPACE are incomplete"
}

matrix_main() {
    local host drift_rows
    load_matrix_hosts
    for host in "${MATRIX_HOSTS[@]}"; do
        load_host_index "$host" || die "cannot index $WORKSPACE/$host; no report written"
    done
    write_report "$MATRIX_TSV_NAME" print_artifact_matrix
    write_report "$MEMORY_MATRIX_TSV_NAME" print_memory_matrix
    write_report "$MATRIX_MD_NAME" print_matrix_markdown
    write_report "$MEMORY_MATRIX_MD_NAME" print_memory_markdown
    write_report "$SETTINGS_MATRIX_MD_NAME" settings_diff
    drift_rows=$(count_drift_rows) || die "cannot count the rows that are not identical in $WORKSPACE"
    [[ "$drift_rows" =~ $DECIMAL_COUNT_RE ]] \
        || die "counting the rows that are not identical in $WORKSPACE gave '$drift_rows', not a number"
    printf 'claude-config-audit: %s rows not identical across %s; reports in %s\n' \
        "$drift_rows" "${MATRIX_HOSTS[*]}" "$WORKSPACE"
    (( drift_rows == 0 )) || exit "$EXIT_DRIFT"
}

main() {
    parse_args "$@"
    case "$MODE" in
        collect) collect_main ;;
        matrix)  matrix_main ;;
    esac
}

main "$@"
