#!/usr/bin/env bash
#
# scripts/claude-memory-link.sh
# =============================
#
# Map each Claude Code project key to its directory in a git-backed memory store, and report the
# state of the key's `memory` entry. This half only reads: it never creates, moves or deletes
# anything. Design: docs/superpowers/specs/2026-11-04-shared-claude-config-design.md (D7 and its
# amendments M1-M8).
#
# WHY. Claude Code keeps auto-memory in <projects dir>/<key>/memory/, one directory per checkout
# path on one machine, so memory neither survives a new host nor follows a repo between hosts. A
# store is a git checkout keyed by repo identity; each `memory` entry is meant to be a symlink into
# it. This script answers, for every key, which store directory it belongs to and how far it is
# from being that symlink.
#
# THE TABLE. A host opts in by carrying the store table (shown below). A host without it is not
# touched: the script says so and exits 0. That check comes before any other, jq's included.
#   {"stores": {"<store>": {"remote": "<url>", "tenants": ["<tenant>"]}},
#    "checkout_globs": ["<path relative to $HOME, may hold *>"],
#    "plain_dirs": ["<path relative to $HOME; the empty string is $HOME>"]}
#
# THE KEY of a path is the path with every character outside [A-Za-z0-9] replaced by `-`. Checked
# against every live key on one machine that still resolves to a directory. No directory there
# holds `_`, so what `_` becomes is UNVERIFIED. A non-ASCII character is unverified too, and its key
# depends on the locale: `café` ends `caf--` under LC_ALL=C (one dash per byte) and `caf-` under
# C.UTF-8 (one per character), so a unit with no LANG and a shell can disagree.
#
# THE PATH a key comes from is the physical one, since that is Claude Code's cwd: a candidate reached
# through a symlink is keyed, routed and slugged by where it really is.
#
# CANDIDATES, deduplicated by key. A directory named twice is asked about once. Two directories can
# flatten to one key (a-b/c and a/b-c), and Claude Code then uses one memory directory for both. In
# one store the first keeps the key. Across stores that would commit one store's memory to the
# other's remote, which cannot be taken back, so it is exit 2 naming both.
#   1. every directory matching a checkout_globs entry that holds .git, and every populated
#      submodule of it, recursively. `git submodule status --recursive` lists the same submodules
#      but has no NUL form and prints paths that cannot be told from its trailing `(describe)`, so
#      this asks `git submodule foreach`. An unpopulated submodule has no .git, so it is no checkout.
#   2. every plain_dirs entry that exists on this host.
#
# A .git FILE is resolved through its gitdir: line, which may be relative to the checkout:
#   .../.git/worktrees/<n>                    a worktree of an ordinary repo: skipped, since Claude
#                                             Code keys it by the main checkout
#   <super>/.git/modules/<name>/worktrees/<n> a worktree of a submodule: skipped likewise
#   <super>/.git/modules/<name>               a submodule (<name> may hold /): a second key, from
#                                             that git dir, where sessions in a worktree of the
#                                             submodule key; both keys share one store directory
#   anything else                             one key, from the checkout's own path
# The shape decides: a submodule NAMED a/worktrees/b reads as a worktree of a. It then has no link,
# and shows up as UNMAPPED once it holds a memory file, not as a silent loss.
#
# THE MAPPING. A key's store is the one whose `tenants` holds the tenant `scripts/tenant-route <dir>`
# answers, asked once per candidate; a tenant no store lists is exit 2, never a default. The
# directory in the store is repos/<owner>/<repo> for a checkout with an origin (lowercased, by the
# rule of repo_of_url in scripts/dev-sync), or dirs/<slug> for a directory with no .git or a repo
# with no origin (the path relative to $HOME, / becoming -, lowercased; `home` for $HOME itself).
# Outside $HOME such a directory has no slug, which is exit 2. An origin's URL is never printed: it
# can carry a credential.
#
# STATES, first match wins. PENDING-MERGE comes first because a merge left unfinished must be
# reported whatever else is true of the key, a missing store and an unclaimed key included.
#   PENDING-MERGE a memory.replaced-* directory without the marker .merged-into-store exists
#   NO-STORE      mapped, but that store is not checked out on this host
#   LINKED        memory is a symlink to the mapped store directory, which exists
#   DANGLING      the right symlink, but its target directory does not exist
#   WRONG-LINK    memory is a symlink to anywhere else
#   REAL-DIR      memory is a real directory, the key is mapped, the store is checked out
#   MISSING       no memory entry, and the mapped store directory holds a file
#   UNMAPPED      a real memory directory holding a file, under a key no candidate claims
# A candidate with no memory entry and nothing in its store directory has no state and no row, and
# neither does an unclaimed key with nothing to report.
#
# Usage:
#   claude-memory-link --check   print each row that is not LINKED or NO-STORE, then a summary line;
#                                exit 1 if any key is REAL-DIR, MISSING, DANGLING, PENDING-MERGE or
#                                WRONG-LINK (the default verb)
#   claude-memory-link --list    print every key as TSV: key, state, store, store-relative directory,
#                                source directory (the path the key comes from; the last three are
#                                empty for a key no candidate claims). A backslash, tab or newline in
#                                a field is written \\, \t or \n, so that one key stays one line.
#   claude-memory-link --help    this text
#
# Exit: 0 ok, or no store table here (nothing to do)
#       1 attention on --check
#       2 could not run (HOME unset, no jq or git, a bad store table, tenant-route or git could not
#         answer, a key two stores share, an unreadable projects or key directory, a memory entry that
#         is neither a directory nor a symlink)
#       64 usage
#
# Needs bash 4.4: associative arrays (4.0), a nameref (4.3), and `wait` on a process substitution
# (4.4), which is how a failed listing is told from an empty one.
#
# Overrides: CLAUDE_MEMORY_PROJECTS_DIR (default ~/.claude/projects), CLAUDE_MEMORY_STORES_ROOT
# (~/.local/share/claude-memory), CLAUDE_MEMORY_CONFIG (~/.dotfiles-local/claude/memory-stores.json),
# CLAUDE_MEMORY_TENANT_ROUTE (the sibling scripts/tenant-route).

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
DOTFILES="$(cd "$(dirname "$SELF")/.." && pwd)"

SCRIPT_NAME='claude-memory-link'
PROJECTS_DIR_RELATIVE='.claude/projects'
STORES_ROOT_RELATIVE='.local/share/claude-memory'
CONFIG_RELATIVE='.dotfiles-local/claude/memory-stores.json'
TENANT_ROUTE_RELATIVE='scripts/tenant-route'
MEMORY_ENTRY_NAME='memory'
# A replaced real directory is memory.replaced-<stamp>; it counts as merged once it holds the marker.
REPLACED_DIR_INFIX='.replaced-'
MERGED_MARKER_NAME='.merged-into-store'
REPOS_DIR_NAME='repos'
DIRS_DIR_NAME='dirs'
HOME_SLUG='home'
GITDIR_LINE_PREFIX='gitdir: '
SUBMODULE_GIT_DIR_INFIX='/.git/modules/'
WORKTREE_GIT_DIR_RE='/\.git/(modules/.+/)?worktrees/[^/]+$'
# shellcheck disable=SC2016  # expanded by the shell `git submodule foreach` starts, not this one
PRINT_SUBMODULE_PATH='printf "%s\0" "$displaypath"'
# git's documented status for "that remote does not exist", against 128 for "git could not run".
GIT_EXIT_NO_SUCH_REMOTE=2
# Each becomes a path component in a store, so neither may be `.` or `..`. A repo may start with a
# dot (.github); an owner may not.
OWNER_AND_REPO_RE='^[a-z0-9_-][a-z0-9._-]*/\.?[a-z0-9_-][a-z0-9._-]*$'
STORE_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
EXIT_ATTENTION=1
EXIT_COULD_NOT_RUN=2
EXIT_USAGE=64

# HOME may be unset here: main refuses that, and --help needs no home.
PROJECTS_DIR="${CLAUDE_MEMORY_PROJECTS_DIR:-${HOME:-}/$PROJECTS_DIR_RELATIVE}"
STORES_ROOT="${CLAUDE_MEMORY_STORES_ROOT:-${HOME:-}/$STORES_ROOT_RELATIVE}"
CONFIG_PATH="${CLAUDE_MEMORY_CONFIG:-${HOME:-}/$CONFIG_RELATIVE}"
TENANT_ROUTE="${CLAUDE_MEMORY_TENANT_ROUTE:-$DOTFILES/$TENANT_ROUTE_RELATIVE}"

MODE=''                       # check | list
declare -A STORE_OF_TENANT=() # tenant → store, from the table
CHECKOUT_GLOBS=()
PLAIN_DIRS=()
# The candidates, as parallel arrays in discovery order, and who claimed each key.
declare -A SOURCE_DIR_OF_KEY=()
declare -A STORE_OF_KEY=()
CANDIDATE_KEYS=()
CANDIDATE_STORES=()
CANDIDATE_RELATIVE_DIRS=()
CANDIDATE_SOURCE_DIRS=()
CHECKOUT_KIND=''              # what classify_directory found: plain | ordinary | submodule | worktree
SUBMODULE_GIT_DIR=''          # and, for a submodule, its git dir
GLOB_MATCHES=()               # what expand_home_glob found
# The report, as parallel arrays: each row's state, and its line as printed.
ROW_STATES=()
ROW_LINES=()

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

# parse_args ARGS… — set MODE from the command line; --check when no verb is given.
parse_args() {
    while (( $# )); do
        case "$1" in
            --check)   set_mode check ;;
            --list)    set_mode list ;;
            -h|--help) usage; exit 0 ;;
            *)         usage_error "unknown argument: $1" ;;
        esac
        shift
    done
    [[ -n "$MODE" ]] || MODE=check
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

# lexically_normal_path ABSOLUTE_PATH — print the path with `.`, `..` and empty components resolved
# by the text alone. A gitdir may name a directory that is gone, so nothing here may touch the disk.
lexically_normal_path() {
    local remaining="$1/" component
    local kept_components=()
    while [[ -n "$remaining" ]]; do
        component=${remaining%%/*}
        remaining=${remaining#*/}
        case "$component" in
            ''|.) ;;
            ..)   if (( ${#kept_components[@]} )); then unset 'kept_components[-1]'; fi ;;
            *)    kept_components+=("$component") ;;
        esac
    done
    local IFS=/
    printf '/%s' "${kept_components[*]}"
}

# physical_path_of DIR — print DIR with every symlink resolved. Dies when DIR cannot be entered.
physical_path_of() { (cd -P -- "$1" 2>/dev/null && pwd -P) || die "could not enter $1"; }

# ---------------------------------------------------------------------------------------------
# The mapping: a path to its key, a directory to its store directory, the table behind them.
# ---------------------------------------------------------------------------------------------

# project_key_of_path PATH — print Claude Code's project key for PATH.
project_key_of_path() { printf '%s' "${1//[^A-Za-z0-9]/-}"; }

# What is wrong with the shape of the table, or nothing. Only what this script reads is checked; a
# list that is absent is a fault, because a typo there would otherwise narrow the run into silence.
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_TABLE_PROBLEM='
def is_string_list: type == "array" and all(.[]; type == "string");
def tenants_of_store: if type == "object" then .tenants else null end;
def is_tenant_list: type == "array" and all(.[]; type == "string" and . != "");
if (.stores | type) != "object" then ".stores is not an object"
elif any(.stores | keys[]; test($store_name_re) | not) then "a name in .stores is not a plain name"
elif any(.stores[]; tenants_of_store | is_tenant_list | not) then "a store has no list of tenant names"
elif (.checkout_globs | is_string_list | not) then ".checkout_globs is not a list of strings"
elif (.plain_dirs | is_string_list | not) then ".plain_dirs is not a list of strings"
else empty end'

# Every store and tenant, NUL-terminated in turn: store, tenant, store, tenant, …
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_STORE_TENANT_PAIRS='.stores | to_entries[] | .key as $store | .value.tenants[] | $store, "\u0000", ., "\u0000"'

# load_store_table — set STORE_OF_TENANT, CHECKOUT_GLOBS and PLAIN_DIRS from the table. Dies unless
# the table is one JSON object of the right shape, naming each tenant in at most one store.
load_store_table() {
    local table_problem store_tenant_pairs=() index store tenant
    jq -se 'length == 1 and (.[0] | type) == "object"' "$CONFIG_PATH" >/dev/null 2>&1 \
        || die "$CONFIG_PATH is not one JSON object"
    table_problem=$(jq -r --arg store_name_re "$STORE_NAME_RE" "$JQ_TABLE_PROBLEM" "$CONFIG_PATH") \
        || die "could not read the shape of $CONFIG_PATH"
    [[ -z "$table_problem" ]] || die "$CONFIG_PATH: $table_problem"

    read_nul_items store_tenant_pairs jq -j "$JQ_STORE_TENANT_PAIRS" "$CONFIG_PATH" \
        || die "could not read the stores of $CONFIG_PATH"
    for (( index = 0; index < ${#store_tenant_pairs[@]}; index += 2 )); do
        store=${store_tenant_pairs[index]}
        tenant=${store_tenant_pairs[index + 1]}
        if [[ -n "${STORE_OF_TENANT[$tenant]:-}" && "${STORE_OF_TENANT[$tenant]}" != "$store" ]]; then
            die "$CONFIG_PATH: tenant '$tenant' is in two stores"
        fi
        STORE_OF_TENANT[$tenant]=$store
    done
    read_nul_items CHECKOUT_GLOBS jq -j '.checkout_globs[] | ., "\u0000"' "$CONFIG_PATH" \
        || die "could not read .checkout_globs of $CONFIG_PATH"
    read_nul_items PLAIN_DIRS jq -j '.plain_dirs[] | ., "\u0000"' "$CONFIG_PATH" \
        || die "could not read .plain_dirs of $CONFIG_PATH"
}

# tenant_of_directory DIR — print the tenant tenant-route answers for DIR. A refusal or an answer
# with no tenant dies: "could not be asked" must never read as a default.
tenant_of_directory() {
    local dir=$1 route_answer route_status tenant
    route_answer=$("$TENANT_ROUTE" "$dir")
    route_status=$?
    (( route_status == 0 )) || die "tenant-route could not answer for $dir (exit $route_status)"
    tenant=$(jq -r '.tenant | select(type == "string")' <<< "$route_answer" 2>/dev/null) \
        || die "tenant-route named no tenant for $dir"
    [[ -n "$tenant" ]] || die "tenant-route named no tenant for $dir"
    printf '%s' "$tenant"
}

# repo_of_url URL — owner/repo from a remote URL, lowercased. The rule of repo_of_url in
# scripts/dev-sync, reproduced because that script cannot be sourced.
repo_of_url() {
    printf '%s\n' "$1" | sed -E 's#/+$##; s#\.git$##; s#^.*[:/]([^/:]+)/([^/:]+)$#\1/\2#' | tr '[:upper:]' '[:lower:]'
}

# dirs_slug_of_path PHYSICAL_DIR — the slug of a directory with no repo identity: the path relative
# to the physical $HOME, with / as -, lowercased; `home` for $HOME itself. Dies outside $HOME, where
# there is no such path.
dirs_slug_of_path() {
    local dir=$1 home_dir relative_path slug
    # It dies inside the command substitution, having said why; pass the exit on.
    home_dir=$(physical_path_of "$HOME") || exit "$EXIT_COULD_NOT_RUN"
    if [[ "$dir" == "$home_dir" ]]; then
        printf '%s' "$HOME_SLUG"
        return 0
    fi
    [[ "$dir" == "$home_dir"/* ]] || die "$dir is outside $home_dir and has no origin, so it has no store directory"
    relative_path=${dir#"$home_dir"/}
    slug=${relative_path//\//-}
    printf '%s' "${slug,,}"
}

# store_relative_dir DIR — print repos/<owner>/<repo> for a checkout with an origin, else dirs/<slug>.
# --git-dir, not -C: with an unreadable .git, -C walks up and answers for whichever repo holds DIR.
store_relative_dir() {
    local dir=$1 origin_url origin_status owner_and_repo slug
    if [[ -e "$dir/.git" ]]; then
        origin_url=$(git --git-dir="$dir/.git" remote get-url origin 2>/dev/null)
        origin_status=$?
        if (( origin_status == 0 )); then
            owner_and_repo=$(repo_of_url "$origin_url")
            [[ "$owner_and_repo" =~ $OWNER_AND_REPO_RE ]] \
                || die "$dir: origin does not name an owner and a repo"
            printf '%s/%s' "$REPOS_DIR_NAME" "$owner_and_repo"
            return 0
        fi
        (( origin_status == GIT_EXIT_NO_SUCH_REMOTE )) \
            || die "git could not read the origin of $dir (exit $origin_status)"
    fi
    # It dies inside the command substitution, having said why; pass the exit on.
    slug=$(dirs_slug_of_path "$dir") || exit "$EXIT_COULD_NOT_RUN"
    printf '%s/%s' "$DIRS_DIR_NAME" "$slug"
}

# store_dir_of_candidate DIR — print <store>/<relative dir> for a candidate directory. Dies when
# tenant-route cannot answer, no store lists its tenant, or git cannot read DIR's origin.
store_dir_of_candidate() {
    local dir=$1 tenant store relative_dir
    # Each dies inside the command substitution, having said why; pass the exit on.
    tenant=$(tenant_of_directory "$dir") || exit "$EXIT_COULD_NOT_RUN"
    store=${STORE_OF_TENANT[$tenant]:-}
    [[ -n "$store" ]] || die "$dir: tenant '$tenant' is in no store of $CONFIG_PATH"
    relative_dir=$(store_relative_dir "$dir") || exit "$EXIT_COULD_NOT_RUN"
    printf '%s/%s' "$store" "$relative_dir"
}

# classify_directory DIR — set CHECKOUT_KIND and SUBMODULE_GIT_DIR from DIR's .git entry.
classify_directory() {
    local dir=$1 dot_git="$1/.git" gitfile_text git_dir
    CHECKOUT_KIND=plain
    SUBMODULE_GIT_DIR=''
    if [[ ! -e "$dot_git" && ! -L "$dot_git" ]]; then return 0; fi
    if [[ -d "$dot_git" ]]; then
        CHECKOUT_KIND=ordinary
        return 0
    fi
    # The whole file, not its first line: git reads it whole, and a path may hold a newline.
    gitfile_text=$(< "$dot_git") || die "could not read $dot_git"
    [[ "$gitfile_text" == "$GITDIR_LINE_PREFIX"* ]] || die "$dot_git has no gitdir: line"
    git_dir=${gitfile_text#"$GITDIR_LINE_PREFIX"}
    [[ "$git_dir" == /* ]] || git_dir="$dir/$git_dir"
    git_dir=$(lexically_normal_path "$git_dir")
    if [[ "$git_dir" =~ $WORKTREE_GIT_DIR_RE ]]; then
        CHECKOUT_KIND=worktree
    elif [[ "$git_dir" == *"$SUBMODULE_GIT_DIR_INFIX"?* ]]; then
        CHECKOUT_KIND=submodule
        SUBMODULE_GIT_DIR=$git_dir
    else
        CHECKOUT_KIND=ordinary
    fi
}

# register_candidate KEY MAPPED_DIR SOURCE_DIR — record KEY's candidate. A claimed key stays with its
# first candidate, unless this one maps to another store: that dies, naming both.
register_candidate() {
    local key=$1 mapped_dir=$2 source_dir=$3 store=${2%%/*}
    if [[ -n "${SOURCE_DIR_OF_KEY[$key]:-}" ]]; then
        [[ "${STORE_OF_KEY[$key]}" == "$store" ]] \
            || die "key $key is shared by ${SOURCE_DIR_OF_KEY[$key]} (store ${STORE_OF_KEY[$key]}) and $source_dir (store $store)"
        return 0
    fi
    SOURCE_DIR_OF_KEY[$key]=$source_dir
    STORE_OF_KEY[$key]=$store
    CANDIDATE_KEYS+=("$key")
    CANDIDATE_STORES+=("$store")
    CANDIDATE_RELATIVE_DIRS+=("${mapped_dir#*/}")
    CANDIDATE_SOURCE_DIRS+=("$source_dir")
}

# add_candidate DIR — register DIR's key, and for a submodule its git-dir key, on one store
# directory. A worktree adds nothing (CHECKOUT_KIND says so afterwards). A directory that already
# holds all its keys is not asked about again; any other is routed, even if its keys are claimed,
# since only its store can say whether it may share them.
add_candidate() {
    local dir=$1 own_key git_dir_key='' mapped_dir
    classify_directory "$dir"
    [[ "$CHECKOUT_KIND" != worktree ]] || return 0
    own_key=$(project_key_of_path "$dir")
    [[ -z "$SUBMODULE_GIT_DIR" ]] || git_dir_key=$(project_key_of_path "$SUBMODULE_GIT_DIR")
    if [[ "${SOURCE_DIR_OF_KEY[$own_key]:-}" == "$dir" ]]; then
        if [[ -z "$git_dir_key" || "${SOURCE_DIR_OF_KEY[$git_dir_key]:-}" == "$SUBMODULE_GIT_DIR" ]]; then return 0; fi
    fi
    # It dies inside the command substitution, having said why; pass the exit on.
    mapped_dir=$(store_dir_of_candidate "$dir") || exit "$EXIT_COULD_NOT_RUN"
    register_candidate "$own_key" "$mapped_dir" "$dir"
    [[ -z "$git_dir_key" ]] || register_candidate "$git_dir_key" "$mapped_dir" "$SUBMODULE_GIT_DIR"
}

# add_checkout_and_submodules DIR — a checkout_globs match: when it holds .git, DIR and each of its
# populated submodules, recursively. A worktree brings no submodules with it.
add_checkout_and_submodules() {
    local dir submodule_paths=() submodule_path
    [[ -d "$1" ]] || return 0
    if [[ ! -e "$1/.git" && ! -L "$1/.git" ]]; then return 0; fi
    # It dies inside the command substitution, having said why; pass the exit on.
    dir=$(physical_path_of "$1") || exit "$EXIT_COULD_NOT_RUN"
    add_candidate "$dir"
    [[ "$CHECKOUT_KIND" != worktree ]] || return 0
    read_nul_items submodule_paths git -C "$dir" submodule --quiet foreach --recursive "$PRINT_SUBMODULE_PATH" \
        || die "git could not list the submodules of $dir"
    for submodule_path in "${submodule_paths[@]}"; do
        add_candidate "$dir/$submodule_path"
    done
}

# expand_home_glob PATTERN — set GLOB_MATCHES to what PATTERN, relative to $HOME, matches. The empty
# IFS stops word splitting on the one unquoted expansion, leaving only its pathname expansion.
expand_home_glob() {
    local pattern=$1 IFS=''
    shopt -s nullglob
    # shellcheck disable=SC2206  # the pathname expansion is the point; IFS rules out word splitting
    GLOB_MATCHES=("$HOME"/$pattern)
    shopt -u nullglob
}

# load_candidates — every candidate on this host: the checkouts first, then the plain directories.
load_candidates() {
    local glob_pattern glob_match plain_dir physical_dir
    for glob_pattern in "${CHECKOUT_GLOBS[@]}"; do
        expand_home_glob "$glob_pattern"
        for glob_match in "${GLOB_MATCHES[@]}"; do
            add_checkout_and_submodules "$glob_match"
        done
    done
    for plain_dir in "${PLAIN_DIRS[@]}"; do
        [[ -d "$HOME/$plain_dir" ]] || continue
        # It dies inside the command substitution, having said why; pass the exit on.
        physical_dir=$(physical_path_of "$HOME/$plain_dir") || exit "$EXIT_COULD_NOT_RUN"
        add_candidate "$physical_dir"
    done
}

# ---------------------------------------------------------------------------------------------
# The state of a key.
# ---------------------------------------------------------------------------------------------

# require_readable_if_present PATH — die when PATH exists and cannot be listed. Every test of what a
# directory holds would otherwise answer "nothing there": a glob, -e, -d and -L all do, and that
# reports a clean host over real memory. An absent path is no fault: no session has run there yet.
require_readable_if_present() {
    if [[ -e "$1" && ! ( -d "$1" && -r "$1" && -x "$1" ) ]]; then
        die "$1 is not a readable directory"
    fi
}

# has_unmerged_replaced_dir KEY_DIR — true when a replaced directory there lacks the marker.
has_unmerged_replaced_dir() {
    local key_dir=$1 replaced_dirs=() replaced_dir
    shopt -s nullglob
    replaced_dirs=("$key_dir/$MEMORY_ENTRY_NAME$REPLACED_DIR_INFIX"*)
    shopt -u nullglob
    for replaced_dir in "${replaced_dirs[@]}"; do
        if [[ -d "$replaced_dir" && ! -L "$replaced_dir" && ! -f "$replaced_dir/$MERGED_MARKER_NAME" ]]; then
            return 0
        fi
    done
    return 1
}

# directory_holds_a_file DIR — true when anything but a directory lies under DIR, at any depth. find
# does not descend into a symlink named as its starting point, so a DIR that is itself a symlink
# holds nothing by this test, whatever its target holds.
directory_holds_a_file() {
    local first_found
    first_found=$(find "$1" -mindepth 1 ! -type d -print -quit) || die "could not read $1"
    [[ -n "$first_found" ]]
}

# state_of_memory_link KEY_DIR STORE_DIR — print the state of KEY_DIR's memory symlink. The target
# is compared by its text, so a relative link to the right place is the right link.
state_of_memory_link() {
    local key_dir=$1 store_dir=$2 link_target
    link_target=$(readlink -- "$key_dir/$MEMORY_ENTRY_NAME") || die "could not read the link in $key_dir"
    [[ "$link_target" == /* ]] || link_target="$key_dir/$link_target"
    if [[ "$(lexically_normal_path "$link_target")" != "$(lexically_normal_path "$store_dir")" ]]; then
        printf 'WRONG-LINK'
    elif [[ -d "$store_dir" ]]; then
        printf 'LINKED'
    else
        printf 'DANGLING'
    fi
}

# state_of_mapped_key KEY STORE RELATIVE_DIR — print the state of a candidate's key, or nothing when
# it has neither a memory entry nor a file in its store directory.
state_of_mapped_key() {
    local key_dir="$PROJECTS_DIR/$1" store=$2 relative_dir=$3
    local memory_path="$key_dir/$MEMORY_ENTRY_NAME" store_dir="$STORES_ROOT/$2/$3"
    require_readable_if_present "$key_dir"
    if has_unmerged_replaced_dir "$key_dir"; then
        printf 'PENDING-MERGE'
    elif [[ ! -e "$STORES_ROOT/$store/.git" ]]; then
        printf 'NO-STORE'
    elif [[ -L "$memory_path" ]]; then
        state_of_memory_link "$key_dir" "$store_dir"
    elif [[ -d "$memory_path" ]]; then
        printf 'REAL-DIR'
    elif [[ -e "$memory_path" ]]; then
        die "$memory_path is neither a directory nor a symlink"
    elif [[ -d "$store_dir" ]] && directory_holds_a_file "$store_dir"; then
        printf 'MISSING'
    fi
}

# state_of_unclaimed_key KEY — print the state of a key no candidate claims, or nothing. The `! -L`
# states the rule, that only a real directory can be unmapped. directory_holds_a_file also answers no
# for a symlink, so a mutant dropping `! -L` alone is equivalent.
state_of_unclaimed_key() {
    local key_dir="$PROJECTS_DIR/$1" memory_path="$PROJECTS_DIR/$1/$MEMORY_ENTRY_NAME"
    require_readable_if_present "$key_dir"
    if has_unmerged_replaced_dir "$key_dir"; then
        printf 'PENDING-MERGE'
    elif [[ -d "$memory_path" && ! -L "$memory_path" ]] && directory_holds_a_file "$memory_path"; then
        printf 'UNMAPPED'
    fi
}

# ---------------------------------------------------------------------------------------------
# The report and the verbs.
# ---------------------------------------------------------------------------------------------

# add_row STATE KEY STORE RELATIVE_DIR SOURCE_DIR — record a row: its state, and its TSV line.
add_row() {
    local field escaped_fields=()
    ROW_STATES+=("$1")
    for field in "$2" "$1" "$3" "$4" "$5"; do
        field=${field//\\/\\\\}
        field=${field//$'\t'/\\t}
        field=${field//$'\n'/\\n}
        escaped_fields+=("$field")
    done
    local IFS=$'\t'
    ROW_LINES+=("${escaped_fields[*]}")
}

# load_rows — the state of every key: the candidates in discovery order, then the keys on disk that
# no candidate claims. Each state function can die inside its command substitution, having said why.
load_rows() {
    local index state key_dirs=() key_dir key
    for (( index = 0; index < ${#CANDIDATE_KEYS[@]}; index++ )); do
        state=$(state_of_mapped_key "${CANDIDATE_KEYS[index]}" "${CANDIDATE_STORES[index]}" "${CANDIDATE_RELATIVE_DIRS[index]}") \
            || exit "$EXIT_COULD_NOT_RUN"
        if [[ -n "$state" ]]; then
            add_row "$state" "${CANDIDATE_KEYS[index]}" "${CANDIDATE_STORES[index]}" \
                "${CANDIDATE_RELATIVE_DIRS[index]}" "${CANDIDATE_SOURCE_DIRS[index]}"
        fi
    done
    shopt -s nullglob
    key_dirs=("$PROJECTS_DIR"/*/)
    shopt -u nullglob
    for key_dir in "${key_dirs[@]}"; do
        key=${key_dir%/}
        key=${key##*/}
        [[ -z "${SOURCE_DIR_OF_KEY[$key]:-}" ]] || continue
        state=$(state_of_unclaimed_key "$key") || exit "$EXIT_COULD_NOT_RUN"
        if [[ -n "$state" ]]; then add_row "$state" "$key" '' '' ''; fi
    done
}

# print_list — every row.
print_list() {
    if (( ${#ROW_LINES[@]} )); then printf '%s\n' "${ROW_LINES[@]}"; fi
}

# print_check — each row that is not LINKED or NO-STORE, then the summary; exit 1 if any is to fix.
print_check() {
    local index linked_count=0 to_fix_count=0 unmapped_count=0
    for (( index = 0; index < ${#ROW_STATES[@]}; index++ )); do
        case "${ROW_STATES[index]}" in
            LINKED)   linked_count=$(( linked_count + 1 )); continue ;;
            NO-STORE) continue ;;
            UNMAPPED) unmapped_count=$(( unmapped_count + 1 )) ;;
            *)        to_fix_count=$(( to_fix_count + 1 )) ;;
        esac
        printf '%s\n' "${ROW_LINES[index]}"
    done
    printf '%s: %d linked, %d to fix, %d unmapped\n' "$SCRIPT_NAME" "$linked_count" "$to_fix_count" "$unmapped_count"
    (( to_fix_count == 0 )) || exit "$EXIT_ATTENTION"
}

main() {
    parse_args "$@"
    # Every default path, the globs and the slugs hang off HOME.
    [[ -n "${HOME:-}" ]] || die "HOME is not set"
    # These would point this script's git calls, and tenant-route's, at another repository: a git hook
    # exports them, and a bogus GIT_DIR makes a submodule vanish from the listing without an error.
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
    require_readable_if_present "$PROJECTS_DIR"
    load_store_table
    load_candidates
    load_rows
    case "$MODE" in
        list)  print_list ;;
        check) print_check ;;
    esac
}

# Sourced, only the functions are defined: the table calls project_key_of_path directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
