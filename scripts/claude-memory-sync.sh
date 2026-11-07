#!/usr/bin/env bash
#
# scripts/claude-memory-sync.sh
# =============================
#
# Commit each checked-out Claude Code memory store: stage every file in it, withhold each file that
# carries a credential shape, and commit the rest as one commit. --check reports what a run would
# commit and withhold; --scan looks for credential shapes in a committed tree. This is the LOCAL
# half: fetching, merging and pushing are the network half's (DO-892).
# Design: docs/superpowers/specs/2026-11-04-shared-claude-config-design.md (D7 and its amendments
# M1-M8).
#
# WHY. scripts/claude-memory-link.sh makes each project's `memory` entry a symlink into a store
# checkout, so every memory write lands in a git working tree. This script turns those writes into
# commits, which is what lets them travel between hosts.
#
# THE TABLE is the link script's, read here for `.stores.<name>.remote` alone. A host without it is
# not touched: the script says so and exits 0, before jq is looked for. A store is checked out when
# <stores root>/<name>/.git exists; one that is not is skipped without a word, since a host carries
# only the stores of the tenants it serves.
#
# A STORE PUSHES ONLY TO ITS OWN REMOTE. Before anything is staged, every fetch and push URL of the
# store's `origin` must be the table's `remote`: a difference is could-not-run for that store, with
# nothing staged. The URLs are git's own answer (`git remote get-url [--push] --all origin`, insteadOf
# applied), since those are the ones a push would use. A URL is never printed: it can carry a
# credential. A store with no `origin` at all is local-only.
#
# NO IGNORE RULE DECIDES WHAT IS MEMORY. `git add -A` skips ignored paths without a word, and a global
# ignore file, .git/info/exclude and a nested .gitignore all apply otherwise, so the stage is
# `git add -A -f` over the whole store. Its pathspec leaves out the link script's partial copies,
# .<name>.link-partial, at every depth, so a copy not yet verified whole is never committed; --check
# counts with the same pathspec, so a leftover partial never reads as pending. The stage, the gate and
# the commit run holding <state dir>/link.lock, the link script's own lock, so an index mid-write is
# never staged. The lock is released after the commit: the network half must not hold up a link run.
#
# THE GATE withholds files; it never refuses the commit (M6). Each staged path with content has its
# staged blob passed through `scripts/redact-secrets.sh --shapes-only`, and compared by digest. When
# the redactor changes it, the path is unstaged (`git reset`) and named with the labels of the shapes
# found, never a line of it, and the rest is committed. The file stays in the working tree, so every
# run stages it, finds it and names it again until someone edits it. Shapes only: the by-name rules
# would withhold ordinary prose such as `FOO_TOKEN=value` forever. The stage wrote the withheld
# blob to the object database; it is in no commit, so no push carries it, and git's gc prunes it.
#
# THE COMMIT is named `<host>: <n> files`, n counting every path it changes, deletions included, and
# is made with --no-gpg-sign: a timer has no one to unlock a signing key. Commit hooks run. The
# maintenance a commit may start runs in the foreground (autoDetach off), so that no child of the
# commit is left holding the lock's descriptor once this script lets go of it.
#
# THE STATUS of a store is <state dir>/<store>.status, one line: epoch<TAB>outcome<TAB>detail, with
# a backslash, tab or newline in the detail written \\, \t or \n. The outcomes, the network half's
# included:
#   ok, ok-local-only, withheld, kept-both, blocked, push-rejected, skipped-no-token, unreachable,
#   auth-failed, could-not-run
# This half writes three:
#   could-not-run   the store could not be committed; the detail says why
#   withheld        the gate held a file back; the detail names each one
#   ok-local-only   the store has no origin, and was committed or had nothing to commit
# A store WITH an origin that was committed with nothing withheld gets NO status from this half: its
# outcome is the push's, which the network half writes. Until then a missing status reads as "never
# synced", which is true, where ok-local-only would read as healthy while nothing leaves the host.
# <state dir>/<store>.last-ok holds the epoch of the last push or up-to-date check that succeeded. This
# half does neither, so it never writes that file.
#
# Usage:
#   claude-memory-sync --check [--store <name>]
#                    per checked-out store, one line
#                      <store>: <n> pending, <n> withheld, ahead <n> behind <n>
#                    then `<store>: withheld <path> (<labels>)` for each file the gate would hold
#                    back. Pending counts what a run would commit. Ahead and behind are counted against
#                    the last-fetched refs/remotes/origin/<branch>; `no fetched origin` stands in their
#                    place without one. Never writes, never fetches, takes no lock. Exit 1 when anything
#                    is pending or withheld (the default verb)
#   claude-memory-sync --scan [--store <name>] [--rev <rev>]
#                    `<store>: <path> (<labels>)` for each file in that revision's tree (default HEAD;
#                    a store with no commit has nothing to scan) that carries a credential shape: the
#                    gate, for commits this script did not make. Exit 1 when any is found
#   claude-memory-sync --apply [--store <name>]
#                    the origin check, the stage, the gate and the commit, store by store: a line
#                    `<store>: withheld <path> (<labels>)` for each file held back, then
#                    `<store>: committed <n> files`, or nothing when there was nothing to commit. A
#                    store that fails says why on stderr, and the later stores still run
#   claude-memory-sync --help    this text
#   --store limits any verb to that store; a name the table does not hold is exit 2.
#
# Exit: 0 ok, or no store table here (nothing to do)
#       1 attention on --check and --scan
#       2 could not run (HOME unset, no jq, git or sha256sum, a bad store table, an unknown --store, a
#         revision that does not resolve, an origin that is not the table's remote; on --apply also no
#         flock, an unusable host name, and a lock, stage, gate, commit or status write that failed,
#         reported once the other stores have run)
#       64 usage
#   --apply exits only 0 or 2: a withheld file is a status for the doctor, not a failed unit.
#
# Overrides: CLAUDE_MEMORY_STORES_ROOT (default ~/.local/share/claude-memory), CLAUDE_MEMORY_CONFIG
# (~/.dotfiles-local/claude/memory-stores.json), CLAUDE_MEMORY_STATE_DIR
# (~/.local/state/claude-memory-sync), CLAUDE_MEMORY_HOST (hostname -s, the host in a commit message).

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
DOTFILES="$(cd "$(dirname "$SELF")/.." && pwd)"

SCRIPT_NAME='claude-memory-sync'
STORES_ROOT_RELATIVE='.local/share/claude-memory'
CONFIG_RELATIVE='.dotfiles-local/claude/memory-stores.json'
STATE_DIR_RELATIVE='.local/state/claude-memory-sync'
REDACTOR_RELATIVE='scripts/redact-secrets.sh'
REDACTOR_SHAPES_ONLY_FLAG='--shapes-only'
LINK_LOCK_FILE_NAME='link.lock'
# The link script's copy on its way to <name> is .<name>.link-partial until it is known to be whole.
PARTIAL_COPY_SUFFIX='.link-partial'
PARTIAL_COPY_NAME_GLOB=".*$PARTIAL_COPY_SUFFIX"
# Every path in the store but a partial copy, at any depth: `**/` also matches no directory at all.
STAGE_PATHSPEC=(. ":(exclude,glob)**/$PARTIAL_COPY_NAME_GLOB")
STATUS_FILE_SUFFIX='.status'
STATUS_TEMP_SUFFIX='.new'
OUTCOME_OK='ok'
OUTCOME_OK_LOCAL_ONLY='ok-local-only'
OUTCOME_WITHHELD='withheld'
OUTCOME_KEPT_BOTH='kept-both'
OUTCOME_BLOCKED='blocked'
OUTCOME_PUSH_REJECTED='push-rejected'
OUTCOME_SKIPPED_NO_TOKEN='skipped-no-token'
OUTCOME_UNREACHABLE='unreachable'
OUTCOME_AUTH_FAILED='auth-failed'
OUTCOME_COULD_NOT_RUN='could-not-run'
KNOWN_OUTCOMES=("$OUTCOME_OK" "$OUTCOME_OK_LOCAL_ONLY" "$OUTCOME_WITHHELD" "$OUTCOME_KEPT_BOTH"
    "$OUTCOME_BLOCKED" "$OUTCOME_PUSH_REJECTED" "$OUTCOME_SKIPPED_NO_TOKEN" "$OUTCOME_UNREACHABLE"
    "$OUTCOME_AUTH_FAILED" "$OUTCOME_COULD_NOT_RUN")
NOTHING_TO_COMMIT_DETAIL='nothing to commit'
NO_FETCHED_ORIGIN_TEXT='no fetched origin'
ORIGIN_REMOTE_NAME='origin'
# What the redactor puts where it found a shape: <REDACTED:label>.
REDACTION_MARKER_PREFIX='<REDACTED:'
REDACTION_MARKER_SUFFIX='>'
REDACTION_MARKER_ERE='<REDACTED:[a-z0-9-]+>'
# The redactor changed the content but left no marker this script could read.
UNLABELLED_SHAPE='unlabelled shape'
# A submodule's entry in a tree or an index: a commit id, with no blob to read.
GITLINK_MODE='160000'
# git's documented status for "that remote does not exist", against 128 for "git could not run".
GIT_EXIT_NO_SUCH_REMOTE=2
# content_has_credential_shape: the content could not be read or filtered.
SHAPE_CHECK_FAILED=2
# The host goes into the commit message, on its one line.
HOST_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
STORE_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
EXIT_ATTENTION=1
EXIT_COULD_NOT_RUN=2
EXIT_USAGE=64

# HOME may be unset here: main refuses that, and --help needs no home.
STORES_ROOT="${CLAUDE_MEMORY_STORES_ROOT:-${HOME:-}/$STORES_ROOT_RELATIVE}"
CONFIG_PATH="${CLAUDE_MEMORY_CONFIG:-${HOME:-}/$CONFIG_RELATIVE}"
STATE_DIR="${CLAUDE_MEMORY_STATE_DIR:-${HOME:-}/$STATE_DIR_RELATIVE}"
REDACTOR="$DOTFILES/$REDACTOR_RELATIVE"

MODE=''                         # check | scan | apply
ONLY_STORE=''                   # --store
SCAN_REVISION=''                # --scan --rev
HOST_NAME=''                    # the host in a commit message, set by prepare_apply
STORE_NAMES=()                  # every store the table names, sorted
declare -A REMOTE_OF_STORE=()   # store → the table's remote
FAILED_STORES=()                # stores that could not run, reported at the end
NEEDS_ATTENTION=0               # --check or --scan found something
LINK_LOCK_FD=''                 # the open descriptor of link.lock while it is held
STORE_HAS_ORIGIN=0              # what check_origin found
WITHHELD_PATHS=()               # what gate_staged_paths held back
COMMITTED_COUNT=0               # how many paths commit_staged_paths committed

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

# parse_args ARGS… — set MODE, ONLY_STORE and SCAN_REVISION from the command line; --check when no
# verb is given.
parse_args() {
    while (( $# )); do
        case "$1" in
            --check) set_mode check ;;
            --scan)  set_mode scan ;;
            --apply) set_mode apply ;;
            --store)
                [[ -n "${2:-}" ]] || usage_error "--store needs a store name"
                ONLY_STORE=$2
                shift ;;
            --rev)
                [[ -n "${2:-}" ]] || usage_error "--rev needs a revision"
                SCAN_REVISION=$2
                shift ;;
            -h|--help) usage; exit 0 ;;
            *)         usage_error "unknown argument: $1" ;;
        esac
        shift
    done
    [[ -n "$MODE" ]] || MODE=check
    if [[ -n "$SCAN_REVISION" && "$MODE" != scan ]]; then usage_error "--rev goes with --scan"; fi
    # A revision is never an option, and rev-parse would read one that looks like it as one.
    if [[ "$SCAN_REVISION" == -* ]]; then usage_error "--rev takes a revision, not an option"; fi
}

# read_nul_items ARRAY_NAME COMMAND… — run COMMAND and set the array to its NUL-terminated items.
# Returns COMMAND's own status: a process substitution's failure is otherwise invisible, and would
# read as an empty list.
read_nul_items() {
    local -n nul_items_target="$1"
    shift
    local item
    nul_items_target=()
    while IFS= read -r -d '' item; do
        nul_items_target+=("$item")
    done < <("$@")
    wait "$!"
}

# escaped_for_one_line TEXT — TEXT with a backslash, tab or newline written \\, \t or \n, so that it
# stays on one line of output.
escaped_for_one_line() {
    local text=$1
    text=${text//\\/\\\\}
    text=${text//$'\t'/\\t}
    text=${text//$'\n'/\\n}
    printf '%s' "$text"
}

# What is wrong with the shape of the table, or nothing. Only what this script reads is checked.
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_TABLE_PROBLEM='
def is_usable_remote: type == "string" and . != "" and (test("[[:cntrl:]]") | not);
if (.stores | type) != "object" then ".stores is not an object"
elif any(.stores | keys[]; test($store_name_re) | not) then "a name in .stores is not a plain name"
elif any(.stores[]; if type == "object" then .remote | is_usable_remote | not else true end)
    then "a store has no remote"
else empty end'

# load_store_table — set STORE_NAMES and REMOTE_OF_STORE from the table. Dies unless the table is
# one JSON object whose every store has a remote.
load_store_table() {
    local table_problem store
    jq -se 'length == 1 and (.[0] | type) == "object"' "$CONFIG_PATH" >/dev/null 2>&1 \
        || die "$CONFIG_PATH is not one JSON object"
    table_problem=$(jq -r --arg store_name_re "$STORE_NAME_RE" "$JQ_TABLE_PROBLEM" "$CONFIG_PATH") \
        || die "could not read the shape of $CONFIG_PATH"
    [[ -z "$table_problem" ]] || die "$CONFIG_PATH: $table_problem"
    read_nul_items STORE_NAMES jq -j '.stores | keys[] | ., "\u0000"' "$CONFIG_PATH" \
        || die "could not read the stores of $CONFIG_PATH"
    for store in "${STORE_NAMES[@]}"; do
        REMOTE_OF_STORE[$store]=$(jq -r --arg store "$store" '.stores[$store].remote' "$CONFIG_PATH") \
            || die "could not read the remote of $store in $CONFIG_PATH"
    done
}

# ---------------------------------------------------------------------------------------------
# One store: its origin, its HEAD, the gate.
# ---------------------------------------------------------------------------------------------

# write_status STORE OUTCOME DETAIL — replace the store's status line, by a rename, so that a reader
# never sees half of one. Returns 1, having said why, when it cannot.
write_status() {
    local store=$1 outcome=$2 known_outcome is_known=0 epoch escaped_detail
    local status_path="$STATE_DIR/$store$STATUS_FILE_SUFFIX"
    for known_outcome in "${KNOWN_OUTCOMES[@]}"; do
        if [[ "$outcome" == "$known_outcome" ]]; then is_known=1; fi
    done
    (( is_known )) || die "write_status: no such outcome $outcome"
    printf -v epoch '%(%s)T' -1
    escaped_detail=$(escaped_for_one_line "$3")
    if ! mkdir -p -- "$STATE_DIR" \
        || ! printf '%s\t%s\t%s\n' "$epoch" "$outcome" "$escaped_detail" > "$status_path$STATUS_TEMP_SUFFIX" \
        || ! mv -f -- "$status_path$STATUS_TEMP_SUFFIX" "$status_path"; then
        printf '%s: %s: could not write the status %s\n' "$SCRIPT_NAME" "$store" "$status_path" >&2
        return 1
    fi
}

# report_store_failure STORE REASON — the store could not run: say why, count it, and on --apply
# record could-not-run as its status. --check and --scan write nothing.
report_store_failure() {
    local store=$1 reason=$2
    printf '%s: %s: %s\n' "$SCRIPT_NAME" "$store" "$reason" >&2
    FAILED_STORES+=("$store")
    if [[ "$MODE" == apply ]]; then write_status "$store" "$OUTCOME_COULD_NOT_RUN" "$reason"; fi
}

# run_git_reporting_errors STORE_DIR ARGS… — run git in the store with its output discarded; when it
# fails, print what it said on stderr through the redactor (a URL in an error can carry a credential)
# and return its status.
run_git_reporting_errors() {
    local store_dir=$1 git_errors git_status
    shift
    git_errors=$(git -C "$store_dir" "$@" 2>&1 >/dev/null)
    git_status=$?
    if (( git_status != 0 )) && [[ -n "$git_errors" ]]; then
        printf '%s\n' "$git_errors" | "$REDACTOR" >&2
    fi
    return "$git_status"
}

# check_origin STORE STORE_DIR — set STORE_HAS_ORIGIN. Returns 0 when the store has no origin, or one
# whose every fetch and push URL is the table's remote; otherwise reports the store and returns 1.
check_origin() {
    local store=$1 store_dir=$2 fetch_urls push_urls get_url_status
    local table_remote=${REMOTE_OF_STORE[$store]}
    STORE_HAS_ORIGIN=0
    fetch_urls=$(git -C "$store_dir" remote get-url --all "$ORIGIN_REMOTE_NAME" 2>/dev/null)
    get_url_status=$?
    if (( get_url_status == GIT_EXIT_NO_SUCH_REMOTE )); then return 0; fi
    if (( get_url_status != 0 )); then
        report_store_failure "$store" "git could not read the origin (exit $get_url_status)"
        return 1
    fi
    if ! push_urls=$(git -C "$store_dir" remote get-url --push --all "$ORIGIN_REMOTE_NAME" 2>/dev/null); then
        report_store_failure "$store" "git could not read the origin's push URL"
        return 1
    fi
    if [[ "$fetch_urls" != "$table_remote" || "$push_urls" != "$table_remote" ]]; then
        report_store_failure "$store" "origin is not the table's remote"
        return 1
    fi
    STORE_HAS_ORIGIN=1
}

# head_is_unborn STORE_DIR — status 0 when HEAD names a branch with no commit yet.
head_is_unborn() {
    git -C "$1" symbolic-ref -q HEAD >/dev/null && ! git -C "$1" rev-parse -q --verify HEAD >/dev/null
}

# base_tree_of STORE_DIR — print the tree a commit would change: HEAD's, or the empty tree when HEAD
# has no commit yet.
base_tree_of() {
    if head_is_unborn "$1"; then
        git -C "$1" hash-object -t tree --stdin < /dev/null
    else
        git -C "$1" rev-parse -q --verify 'HEAD^{tree}'
    fi
}

# content_has_credential_shape COMMAND… — status 0 when the redactor's shape rules change what COMMAND
# prints, 1 when they do not, 2 when it could not be read or filtered. Compared by digest, so the
# content is never held in a variable.
content_has_credential_shape() {
    local original_digest redacted_digest
    original_digest=$("$@" | sha256sum) || return "$SHAPE_CHECK_FAILED"
    redacted_digest=$("$@" | "$REDACTOR" "$REDACTOR_SHAPES_ONLY_FLAG" | sha256sum) || return "$SHAPE_CHECK_FAILED"
    [[ "$original_digest" != "$redacted_digest" ]]
}

# redaction_marker_labels — the label of every redaction marker on stdin, one per line.
redaction_marker_labels() {
    awk -v marker_re="$REDACTION_MARKER_ERE" -v prefix_length="${#REDACTION_MARKER_PREFIX}" \
        -v suffix_length="${#REDACTION_MARKER_SUFFIX}" '{
        line = $0
        while (match(line, marker_re)) {
            print substr(line, RSTART + prefix_length, RLENGTH - prefix_length - suffix_length)
            line = substr(line, RSTART + RLENGTH)
        }
    }'
}

# shape_labels_of COMMAND… — the labels of the shapes the redactor finds in what COMMAND prints,
# sorted and joined by ", ": the markers in its output less those the content already held, so a
# memory file that quotes a marker does not name a shape it lacks. Labels only, never a line.
shape_labels_of() {
    local -A marker_balance=()
    local label found_labels=() sorted_labels
    while IFS= read -r label; do
        marker_balance[$label]=$(( ${marker_balance[$label]:-0} + 1 ))
    done < <("$@" | "$REDACTOR" "$REDACTOR_SHAPES_ONLY_FLAG" | redaction_marker_labels)
    while IFS= read -r label; do
        marker_balance[$label]=$(( ${marker_balance[$label]:-0} - 1 ))
    done < <("$@" | redaction_marker_labels)
    for label in "${!marker_balance[@]}"; do
        if (( ${marker_balance[$label]} > 0 )); then found_labels+=("$label"); fi
    done
    if (( ${#found_labels[@]} == 0 )); then printf '%s' "$UNLABELLED_SHAPE"; return 0; fi
    sorted_labels=$(printf '%s\n' "${found_labels[@]}" | LC_ALL=C sort)
    printf '%s' "${sorted_labels//$'\n'/, }"
}

# print_withheld_line STORE PATH LABELS — the line that names a withheld file.
print_withheld_line() {
    local escaped_path
    escaped_path=$(escaped_for_one_line "$2")
    printf '%s: withheld %s (%s)\n' "$1" "$escaped_path" "$3"
}

# print_link_target PATH — what git stores for a symlink: its target, with no newline.
print_link_target() {
    local link_target
    link_target=$(readlink -- "$1") || return 1
    printf '%s' "$link_target"
}

# ---------------------------------------------------------------------------------------------
# --apply: stage, gate and commit, holding the link script's lock.
# ---------------------------------------------------------------------------------------------

# take_link_lock — wait for <state dir>/link.lock, the link script's lock, and hold it in
# LINK_LOCK_FD. Returns 1 when it cannot.
take_link_lock() {
    mkdir -p -- "$STATE_DIR" || return 1
    exec {LINK_LOCK_FD}>> "$STATE_DIR/$LINK_LOCK_FILE_NAME" || return 1
    if ! flock "$LINK_LOCK_FD"; then
        release_link_lock
        return 1
    fi
}

# release_link_lock — close the lock's descriptor, which lets go of the lock.
release_link_lock() {
    exec {LINK_LOCK_FD}>&-
    LINK_LOCK_FD=''
}

# gate_staged_paths STORE STORE_DIR BASE_TREE — unstage each staged path whose blob carries a
# credential shape, naming it and recording it in WITHHELD_PATHS. Returns 1, having reported the
# store, when a blob could not be read or a path could not be unstaged.
gate_staged_paths() {
    local store=$1 store_dir=$2 base_tree=$3 raw_items=() index metadata path blob_mode blob_id labels
    local shape_status
    WITHHELD_PATHS=()
    if ! read_nul_items raw_items git -C "$store_dir" diff-index --cached --raw -z --no-abbrev \
        --no-renames --diff-filter=d "$base_tree" --; then
        report_store_failure "$store" "git could not list the staged files"
        return 1
    fi
    # Raw items come in pairs: ":<old mode> <new mode> <old id> <new id> <status>", then the path.
    for (( index = 0; index + 1 < ${#raw_items[@]}; index += 2 )); do
        metadata=${raw_items[index]}
        path=${raw_items[index + 1]}
        read -r _ blob_mode _ blob_id _ <<< "$metadata"
        [[ "$blob_mode" != "$GITLINK_MODE" ]] || continue
        content_has_credential_shape git -C "$store_dir" cat-file blob "$blob_id"
        shape_status=$?
        (( shape_status != 1 )) || continue
        if (( shape_status != 0 )); then
            report_store_failure "$store" "could not read the staged $(escaped_for_one_line "$path")"
            return 1
        fi
        labels=$(shape_labels_of git -C "$store_dir" cat-file blob "$blob_id")
        if ! run_git_reporting_errors "$store_dir" --literal-pathspecs reset -q -- "$path"; then
            report_store_failure "$store" "could not unstage the withheld $(escaped_for_one_line "$path")"
            return 1
        fi
        WITHHELD_PATHS+=("$path")
        print_withheld_line "$store" "$path" "$labels"
    done
}

# commit_staged_paths STORE STORE_DIR BASE_TREE — commit what is staged as `<host>: <n> files`, and set
# COMMITTED_COUNT; nothing staged is no commit. Returns 1, having reported the store, on a failure.
commit_staged_paths() {
    local store=$1 store_dir=$2 base_tree=$3 staged_paths=() commit_message
    COMMITTED_COUNT=0
    if ! read_nul_items staged_paths git -C "$store_dir" diff-index --cached --name-only -z \
        --no-renames "$base_tree" --; then
        report_store_failure "$store" "git could not count the staged files"
        return 1
    fi
    (( ${#staged_paths[@]} )) || return 0
    commit_message="$HOST_NAME: ${#staged_paths[@]} files"
    if ! run_git_reporting_errors "$store_dir" -c maintenance.autoDetach=false -c gc.autoDetach=false \
        commit -q --no-gpg-sign -m "$commit_message"; then
        report_store_failure "$store" "git commit failed"
        return 1
    fi
    COMMITTED_COUNT=${#staged_paths[@]}
}

# stage_gate_and_commit STORE STORE_DIR — the part of a run that holds the lock.
stage_gate_and_commit() {
    local store=$1 store_dir=$2 base_tree
    if ! run_git_reporting_errors "$store_dir" add -A -f -- "${STAGE_PATHSPEC[@]}"; then
        report_store_failure "$store" "git add failed"
        return 1
    fi
    if ! base_tree=$(base_tree_of "$store_dir"); then
        report_store_failure "$store" "git could not read HEAD"
        return 1
    fi
    gate_staged_paths "$store" "$store_dir" "$base_tree" || return 1
    commit_staged_paths "$store" "$store_dir" "$base_tree"
}

# apply_store STORE STORE_DIR — the origin check, then stage, gate and commit under the lock, then the
# status. Returns 1 when the store could not run.
apply_store() {
    local store=$1 store_dir=$2 locked_status joined_paths withheld_path local_only_detail
    check_origin "$store" "$store_dir" || return 1
    if ! take_link_lock; then
        report_store_failure "$store" "could not take the lock $STATE_DIR/$LINK_LOCK_FILE_NAME"
        return 1
    fi
    stage_gate_and_commit "$store" "$store_dir"
    locked_status=$?
    release_link_lock
    (( locked_status == 0 )) || return 1

    if (( COMMITTED_COUNT )); then printf '%s: committed %d files\n' "$store" "$COMMITTED_COUNT"; fi
    if (( ${#WITHHELD_PATHS[@]} )); then
        joined_paths=''
        for withheld_path in "${WITHHELD_PATHS[@]}"; do
            joined_paths+="${joined_paths:+, }$withheld_path"
        done
        write_status "$store" "$OUTCOME_WITHHELD" "$joined_paths" || { FAILED_STORES+=("$store"); return 1; }
    elif (( ! STORE_HAS_ORIGIN )); then
        local_only_detail=$NOTHING_TO_COMMIT_DETAIL
        if (( COMMITTED_COUNT )); then local_only_detail="committed $COMMITTED_COUNT files"; fi
        write_status "$store" "$OUTCOME_OK_LOCAL_ONLY" "$local_only_detail" || { FAILED_STORES+=("$store"); return 1; }
    fi
}

# ---------------------------------------------------------------------------------------------
# --check and --scan: read-only.
# ---------------------------------------------------------------------------------------------

# ahead_behind_text STORE_DIR — `ahead <n> behind <n>` against the last-fetched origin ref of the
# current branch, or NO_FETCHED_ORIGIN_TEXT when there is none. Never fetches.
ahead_behind_text() {
    local store_dir=$1 branch tracking_ref counts ahead behind
    if ! branch=$(git -C "$store_dir" symbolic-ref -q --short HEAD); then
        printf '%s' "$NO_FETCHED_ORIGIN_TEXT"
        return 0
    fi
    tracking_ref="refs/remotes/$ORIGIN_REMOTE_NAME/$branch"
    if ! git -C "$store_dir" rev-parse -q --verify "$tracking_ref^{commit}" >/dev/null; then
        printf '%s' "$NO_FETCHED_ORIGIN_TEXT"
        return 0
    fi
    if head_is_unborn "$store_dir"; then
        behind=$(git -C "$store_dir" rev-list --count "$tracking_ref") || return 1
        printf 'ahead 0 behind %s' "$behind"
        return 0
    fi
    counts=$(git -C "$store_dir" rev-list --left-right --count "HEAD...$tracking_ref") || return 1
    read -r ahead behind <<< "$counts"
    printf 'ahead %s behind %s' "$ahead" "$behind"
}

# check_store STORE STORE_DIR — print what --apply would commit and withhold, and how far the store
# is from its fetched origin. Returns 1 when the store could not be read.
check_store() {
    local store=$1 store_dir=$2 status_entries=() status_entry path full_path
    local content_command=() shape_status labels withheld_lines=() pending_count position
    check_origin "$store" "$store_dir" || return 1
    # The stage's pathspec, so that what is counted is what would be staged: every changed tracked path
    # and every untracked one, ignored ones included, one entry each ("XY <path>"). `git status` and not
    # `git diff <tree>`: under GIT_OPTIONAL_LOCKS=0 status leaves the index alone, and diff still writes
    # back the entries it refreshes (probed, git 2.53).
    if ! read_nul_items status_entries git -C "$store_dir" status --porcelain=v1 -z --no-renames \
        --untracked-files=all --ignored=traditional -- "${STAGE_PATHSPEC[@]}"; then
        report_store_failure "$store" "git could not list the changed files"
        return 1
    fi
    for status_entry in "${status_entries[@]}"; do
        path=${status_entry:3}
        full_path="$store_dir/$path"
        if [[ -L "$full_path" ]]; then content_command=(print_link_target "$full_path")
        elif [[ -f "$full_path" ]]; then content_command=(cat -- "$full_path")
        else continue   # a deletion, or a nested repository: nothing to read
        fi
        content_has_credential_shape "${content_command[@]}"
        shape_status=$?
        (( shape_status != 1 )) || continue
        if (( shape_status != 0 )); then
            report_store_failure "$store" "could not read $(escaped_for_one_line "$path")"
            return 1
        fi
        labels=$(shape_labels_of "${content_command[@]}")
        withheld_lines+=("$(print_withheld_line "$store" "$path" "$labels")")
    done
    pending_count=$(( ${#status_entries[@]} - ${#withheld_lines[@]} ))
    if ! position=$(ahead_behind_text "$store_dir"); then
        report_store_failure "$store" "git could not count the commits against the fetched origin"
        return 1
    fi
    printf '%s: %d pending, %d withheld, %s\n' "$store" "$pending_count" "${#withheld_lines[@]}" "$position"
    if (( ${#withheld_lines[@]} )); then printf '%s\n' "${withheld_lines[@]}"; fi
    if (( pending_count || ${#withheld_lines[@]} )); then NEEDS_ATTENTION=1; fi
}

# scan_store STORE STORE_DIR — name each file in the scanned revision's tree that carries a credential
# shape. Returns 1 when the revision or a blob could not be read.
scan_store() {
    local store=$1 store_dir=$2 tree_id tree_items=() item metadata path object_type object_id
    local shape_status labels escaped_path
    if [[ -n "$SCAN_REVISION" ]]; then
        if ! tree_id=$(git -C "$store_dir" rev-parse -q --verify "$SCAN_REVISION^{tree}"); then
            report_store_failure "$store" "revision $SCAN_REVISION does not resolve to a tree"
            return 1
        fi
    elif head_is_unborn "$store_dir"; then
        return 0
    elif ! tree_id=$(git -C "$store_dir" rev-parse -q --verify 'HEAD^{tree}'); then
        report_store_failure "$store" "git could not read HEAD"
        return 1
    fi
    if ! read_nul_items tree_items git -C "$store_dir" ls-tree -r -z "$tree_id"; then
        report_store_failure "$store" "git could not list the tree of ${SCAN_REVISION:-HEAD}"
        return 1
    fi
    # Each item: "<mode> <type> <id>", a tab, then the path.
    for item in "${tree_items[@]}"; do
        metadata=${item%%$'\t'*}
        path=${item#*$'\t'}
        read -r _ object_type object_id <<< "$metadata"
        [[ "$object_type" == blob ]] || continue
        content_has_credential_shape git -C "$store_dir" cat-file blob "$object_id"
        shape_status=$?
        (( shape_status != 1 )) || continue
        escaped_path=$(escaped_for_one_line "$path")
        if (( shape_status != 0 )); then
            report_store_failure "$store" "could not read $escaped_path"
            return 1
        fi
        labels=$(shape_labels_of git -C "$store_dir" cat-file blob "$object_id")
        printf '%s: %s (%s)\n' "$store" "$escaped_path" "$labels"
        NEEDS_ATTENTION=1
    done
}

# prepare_apply — settle the host name the commit message carries.
prepare_apply() {
    HOST_NAME=${CLAUDE_MEMORY_HOST:-$(hostname -s)}
    [[ "$HOST_NAME" =~ $HOST_NAME_RE ]] || die "host name '$HOST_NAME' cannot go in a commit message"
}

main() {
    local store store_dir
    parse_args "$@"
    # Every default path hangs off HOME.
    [[ -n "${HOME:-}" ]] || die "HOME is not set"
    # These would point this script's git calls at another repository: a git hook exports them.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    # A symlink whose target is gone is what a mid-deploy overlay leaves behind: a fault, not a
    # choice not to configure this host.
    if [[ -L "$CONFIG_PATH" && ! -e "$CONFIG_PATH" ]]; then
        die "$CONFIG_PATH is a symlink whose target does not exist"
    fi
    # The table first: a host with neither a table nor jq (a teammate's box) gets the note and exit 0.
    if [[ ! -e "$CONFIG_PATH" ]]; then
        printf '%s: no store table at %s; nothing to do\n' "$SCRIPT_NAME" "$CONFIG_PATH"
        exit 0
    fi
    command -v jq >/dev/null || die "jq is required"
    command -v git >/dev/null || die "git is required"
    command -v sha256sum >/dev/null || die "sha256sum is required"
    [[ -x "$REDACTOR" ]] || die "$REDACTOR is not executable"
    if [[ "$MODE" == apply ]]; then command -v flock >/dev/null || die "flock is required"; fi
    load_store_table
    if [[ -n "$ONLY_STORE" && -z "${REMOTE_OF_STORE[$ONLY_STORE]+set}" ]]; then
        die "no store named $ONLY_STORE in $CONFIG_PATH"
    fi
    if [[ "$MODE" == apply ]]; then
        prepare_apply
    else
        # --check and --scan never write, and an index refresh is a write git otherwise makes on its own.
        export GIT_OPTIONAL_LOCKS=0
    fi
    for store in "${STORE_NAMES[@]}"; do
        if [[ -n "$ONLY_STORE" && "$store" != "$ONLY_STORE" ]]; then continue; fi
        store_dir="$STORES_ROOT/$store"
        [[ -e "$store_dir/.git" ]] || continue
        case "$MODE" in
            apply) apply_store "$store" "$store_dir" ;;
            check) check_store "$store" "$store_dir" ;;
            scan)  scan_store "$store" "$store_dir" ;;
        esac
    done
    if (( ${#FAILED_STORES[@]} )); then
        die "could not finish ${#FAILED_STORES[@]} store(s): ${FAILED_STORES[*]}"
    fi
    (( NEEDS_ATTENTION == 0 )) || exit "$EXIT_ATTENTION"
}

# Sourced, only the functions are defined.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
