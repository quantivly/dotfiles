#!/usr/bin/env bash
#
# scripts/claude-memory-link.sh
# =============================
#
# Map each Claude Code project key to its directory in a git-backed memory store, report the state
# of the key's `memory` entry, and (--apply) make that entry a symlink into the store, merging a real
# directory's files in afterwards. --check and --list only read. Nothing here deletes or overwrites a
# memory file; the only things it removes are its own, a leftover partial copy and a stale marker.
# Design: docs/superpowers/specs/2026-11-04-shared-claude-config-design.md (D7 and its amendments
# M1-M8).
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
#   PENDING-MERGE a memory.replaced-* directory exists without the marker .merged-into-store, or
#                 holding a regular file newer than it
#   NO-STORE      mapped, but that store is not checked out on this host
#   LINKED        memory is a symlink to the mapped store directory, which exists and resolves inside
#                 its store checkout, not into the checkout's .git
#   DANGLING      the right symlink, but its target directory does not exist
#   WRONG-LINK    memory is a symlink to anywhere else, or the right one whose target now resolves
#                 outside the store checkout or into its .git (a link planted above it since)
#   REAL-DIR      memory is a real directory, the key is mapped, the store is checked out
#   MISSING       no memory entry, and the mapped store directory holds a file
#   UNMAPPED      a real memory directory holding a file, under a key no candidate claims
# A candidate with no memory entry and nothing in its store directory has no state and no row, and
# neither does an unclaimed key with nothing to report.
#
# THE SWAP, whose order is the safety argument:
#   1. mkdir -p the store directory
#   2. mv -T memory to memory.replaced-<UTC stamp>. mv -T is atomic only when it is a rename(2) within
#      one filesystem, which is why the replaced name is beside the original
#   3. ln -s -T the store directory to memory (-T: never INSIDE a directory a writer just recreated).
#      A recreated real directory is renamed to memory.replaced-<stamp>.NNN and the link retried, at
#      most 3 times; then exit 2
#   4. merge each replaced directory into the store directory, then write the marker in it
# The merge reads a directory only once it has its replaced name. A write by path before the rename
# is in the walk. A writer holding an open descriptor or a cwd inside the directory can land after
# the walk, and stays only in the replaced directory. The marker follows the last file, so a run
# stopped anywhere leaves PENDING-MERGE, which --check reports and the next --apply finishes before
# anything else on that key. A key whose store is not checked out, and a key no candidate claims,
# have nowhere their pending merge may go: --apply leaves them alone. A replaced directory is never
# pruned.
#
# A FILE WRITTEN AFTER THE MARKER is the one case the marker does not settle. A regular file newer than
# the marker makes the directory read as pending again, and the next --apply merges what is newer than
# the marker, and only that, since the store has been free to move on from the rest, then writes the
# marker anew. A file written in the marker's own clock tick reads as settled, and one whose mtime lies
# in the future reads as pending until the clock passes it.
#
# A REAL DIRECTORY ALREADY HOLDING THE MARKER is merged like any other, not refused. It is what
# undoing a link with `mv memory.replaced-X memory` leaves, and the marker spoke for what the
# directory held then, not for what was written since. A refusal would keep every later write off the
# store until someone removed the marker by hand. So the marker goes before the rename, and a run
# stopped right after the rename still reads as pending.
#
# THE MERGE of one file, at any depth. A symlink is copied and compared as a link: followed, it would
# bring what it points at into a store that is pushed to a remote.
#   absent from the store           copied to .<name>.link-partial beside the target, checked against
#                                   the source for size and content, then published by link(2), which
#                                   cannot overwrite. So a short copy never takes the name, and a
#                                   writer that gets there first keeps its file
#   byte-identical                  nothing
#   MEMORY.md or INDEX_*.md differ  the lines only the replaced copy has are appended. Appended and
#                                   never rewritten: the store's lines stay, as does a concurrent write
#   anything else differs           the store's copy keeps its name regardless of which body is newer;
#                                   the replaced copy becomes the conflict copy, published the same way:
#                                   x.md -> x.conflict-<host>.md, no extension: appended; a copy with
#                                   another body is kept and the next is .conflict-<host>.2, .3, ...
#                                   A copy with the same body is already that file, so a resumed merge
#                                   adds none.
# A leftover partial from a stopped run is no store file: nothing counts it, and only the next merge
# of the same file removes it. A file named like one in a memory directory stays in the replaced
# directory. A store directory that resolves outside its store checkout, or into the checkout's own
# .git, where git runs what it finds (a file named like a hook), is refused before anything is
# made, renamed or written for that key, and a target whose directory resolves outside the store
# directory is refused, so nothing is written through a symlink out of the store. A marker path holding
# anything but a regular file is refused as well: a symlink would be written through, a fifo would
# hang this run under the lock.
#
# A FAILURE STOPS ONLY WHAT FAILED. A file that cannot be merged leaves its directory unmarked, and the
# directory's other files still go. A key that fails prints its reasons and no line, and the later keys
# still run. The run then exits 2 naming those keys.
#
# Usage:
#   claude-memory-link --check   print each row that is not LINKED or NO-STORE, then a summary line:
#                                  <n> linked, <n> to fix, <n> unmapped, <n> without a store
#                                the last being the NO-STORE keys whose memory is a real directory
#                                holding a file, or a symlink into that store's checkout, which is
#                                gone (a store removed after linking); exit 1 if any key is REAL-DIR,
#                                MISSING, DANGLING, PENDING-MERGE or WRONG-LINK (the default verb)
#   claude-memory-link --list    print every key as TSV: key, state, store, store-relative directory,
#                                source directory (the path the key comes from; the last three are
#                                empty for a key no candidate claims). A backslash, tab or newline in
#                                a field is written \\, \t or \n, so that one key stays one line.
#   claude-memory-link --apply [--dry-run] [--only <key>]
#                                finish each pending merge and link each key that needs it. One line
#                                per key acted on:
#                                  linked <key> -> <store dir> (copied <n>, identical <n>, kept-both <n>)
#                                or `merged` for that line when the key finished a merge and keeps a
#                                link that points elsewhere. A key that fails prints its reasons on
#                                stderr instead. A second run prints nothing. Holds an flock on
#                                <state dir>/link.lock; another run waits for it 120 s at most
#                                (CLAUDE_MEMORY_LOCK_WAIT_SECONDS), then is exit 2 naming the lock.
#                                --dry-run prints the same lines and changes nothing, so it takes no
#                                lock: creating the lock file would be a change.
#                                --only limits the run to one key; one no candidate claims is exit 2.
#   claude-memory-link --help    this text
#
# Exit: 0 ok, or no store table here (nothing to do)
#       1 attention on --check
#       2 could not run (HOME unset, no jq or git, a bad store table, tenant-route or git could not
#         answer, a key two stores share, an unreadable projects or key directory, a memory entry that
#         is neither a directory nor a symlink; on --apply also no flock or cmp, an unusable host name
#         or lock wait, a lock still held when the wait ran out, and any step of a swap or a merge that
#         failed, reported once the other keys have run)
#       64 usage
#
# Needs bash 4.4: associative arrays (4.0), a nameref (4.3), and `wait` on a process substitution
# (4.4), which is how a failed listing is told from an empty one.
#
# Overrides: CLAUDE_MEMORY_PROJECTS_DIR (default ~/.claude/projects), CLAUDE_MEMORY_STORES_ROOT
# (~/.local/share/claude-memory), CLAUDE_MEMORY_CONFIG (~/.dotfiles-local/claude/memory-stores.json),
# CLAUDE_MEMORY_STATE_DIR (~/.local/state/claude-memory-sync), CLAUDE_MEMORY_HOST (hostname -s, the
# host in a conflict copy's name), CLAUDE_MEMORY_TENANT_ROUTE (the sibling scripts/tenant-route),
# CLAUDE_MEMORY_LOCK_WAIT_SECONDS (120, how long --apply waits for link.lock; a whole number above 0).

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
DOTFILES="$(cd "$(dirname "$SELF")/.." && pwd)"

SCRIPT_NAME='claude-memory-link'
PROJECTS_DIR_RELATIVE='.claude/projects'
STORES_ROOT_RELATIVE='.local/share/claude-memory'
CONFIG_RELATIVE='.dotfiles-local/claude/memory-stores.json'
STATE_DIR_RELATIVE='.local/state/claude-memory-sync'
TENANT_ROUTE_RELATIVE='scripts/tenant-route'
MEMORY_ENTRY_NAME='memory'
# A replaced real directory is memory.replaced-<stamp>; it counts as merged once it holds the marker.
REPLACED_DIR_INFIX='.replaced-'
MERGED_MARKER_NAME='.merged-into-store'
REPLACED_STAMP_FORMAT='+%Y%m%dT%H%M%SZ'
LINK_LOCK_FILE_NAME='link.lock'
# How long --apply waits for link.lock, so a run on the sync's timer cannot spend the sync's time on a
# lock a by-hand run holds. The sync waits for the same lock as long, under the same override.
LOCK_WAIT_SECONDS_DEFAULT=120
LOCK_WAIT_SECONDS_RE='^[1-9][0-9]*$'
# What flock -w is told to exit with (-E) when the wait runs out, apart from its own failures.
FLOCK_WAIT_RAN_OUT_STATUS=75
MAX_LINK_RETRIES=3
INDEX_FILE_NAME='MEMORY.md'
TOPIC_INDEX_FILE_GLOB='INDEX_*.md'
CONFLICT_INFIX='.conflict-'
# A run holds the lock while it looks for a free name, so that search has an end.
MAX_CONFLICT_COPIES=100
# A copy on its way to <name> is .<name>.link-partial until it is known to be whole.
PARTIAL_COPY_SUFFIX='.link-partial'
PARTIAL_COPY_NAME_GLOB=".*$PARTIAL_COPY_SUFFIX"
# entries_are_identical: cmp could not tell. publish_copy: something is at the target by then.
COMPARISON_FAILED=2
PUBLISH_TARGET_TAKEN=3
# The host goes into a file name in the store, so it may not climb out of the directory.
HOST_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
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
STATE_DIR="${CLAUDE_MEMORY_STATE_DIR:-${HOME:-}/$STATE_DIR_RELATIVE}"
TENANT_ROUTE="${CLAUDE_MEMORY_TENANT_ROUTE:-$DOTFILES/$TENANT_ROUTE_RELATIVE}"

MODE=''                       # check | list | apply
IS_DRY_RUN=0                  # --apply --dry-run
ONLY_KEY=''                   # --apply --only
HOST_NAME=''                  # the host in a conflict copy's name, set by prepare_apply
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
# The report, as parallel arrays: each row's key, its state, its store, and its line as printed.
ROW_KEYS=()
ROW_STATES=()
ROW_STORES=()
ROW_LINES=()
UNMARKED_REPLACED_DIRS=()     # what load_unmarked_replaced_dirs found
# What apply_key reports for one key.
COPIED_COUNT=0
IDENTICAL_COUNT=0
KEPT_BOTH_COUNT=0
# A dry run copies nothing, so a later file with the same target compares against this: store path →
# the source a run would have copied there. It spans keys, since a submodule's two keys share a store.
declare -A PLANNED_SOURCE_OF_TARGET=()
PHYSICAL_STORE_CHECKOUT=''    # the physical path of the checkout of the store apply_key is on
PHYSICAL_STORE_DIR=''         # what resolve_store_directory found; empty when it does not exist yet

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

# parse_args ARGS… — set MODE and the flags of --apply from the command line; --check when no verb is
# given. A key starts with a dash, so --only takes the next argument whatever it looks like.
parse_args() {
    while (( $# )); do
        case "$1" in
            --check)   set_mode check ;;
            --list)    set_mode list ;;
            --apply)   set_mode apply ;;
            --dry-run) IS_DRY_RUN=1 ;;
            --only)
                [[ -n "${2:-}" ]] || usage_error "--only needs a key"
                ONLY_KEY=$2
                shift ;;
            -h|--help) usage; exit 0 ;;
            *)         usage_error "unknown argument: $1" ;;
        esac
        shift
    done
    [[ -n "$MODE" ]] || MODE=check
    if [[ "$MODE" != apply ]] && { (( IS_DRY_RUN )) || [[ -n "$ONLY_KEY" ]]; }; then
        usage_error "--dry-run and --only go with --apply"
    fi
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

# path_is_at_or_under PATH ANCESTOR — true when PATH is ANCESTOR or lies under it, by the text alone.
path_is_at_or_under() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

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

# path_is_free PATH — true when nothing is at PATH, not even a dangling symlink.
path_is_free() { [[ ! -e "$1" && ! -L "$1" ]]; }

# is_regular_file PATH — true for a regular file itself, not a symlink to one.
is_regular_file() { [[ -f "$1" && ! -L "$1" ]]; }

# holds_file_newer_than_marker REPLACED_DIR — true when a regular file there is newer than the marker,
# leaving out what the merge leaves out. A walk that fails proves nothing, so it answers yes too, and
# the merge's own walk reports why. The marker is written after the last file, so a merge never trips
# this by itself.
holds_file_newer_than_marker() {
    local replaced_dir=$1 first_newer_file
    first_newer_file=$(find "$replaced_dir" -type f -newer "$replaced_dir/$MERGED_MARKER_NAME" \
        ! -name "$PARTIAL_COPY_NAME_GLOB" -print -quit 2>/dev/null) || return 0
    [[ -n "$first_newer_file" ]]
}

# load_unmarked_replaced_dirs KEY_DIR — set UNMARKED_REPLACED_DIRS to the replaced directories there
# that lack the marker or hold a file newer than it, oldest first, since the stamp sorts by time. A
# marker is a regular file: this script writes no other kind, and a symlink there must not read as
# merged.
load_unmarked_replaced_dirs() {
    local key_dir=$1 replaced_dirs=() replaced_dir
    UNMARKED_REPLACED_DIRS=()
    shopt -s nullglob
    replaced_dirs=("$key_dir/$MEMORY_ENTRY_NAME$REPLACED_DIR_INFIX"*)
    shopt -u nullglob
    for replaced_dir in "${replaced_dirs[@]}"; do
        [[ -d "$replaced_dir" && ! -L "$replaced_dir" ]] || continue
        if ! is_regular_file "$replaced_dir/$MERGED_MARKER_NAME" || holds_file_newer_than_marker "$replaced_dir"; then
            UNMARKED_REPLACED_DIRS+=("$replaced_dir")
        fi
    done
}

# has_unmerged_replaced_dir KEY_DIR — true when a replaced directory there is unmarked, or holds a
# regular file newer than its marker.
has_unmerged_replaced_dir() {
    load_unmarked_replaced_dirs "$1"
    (( ${#UNMARKED_REPLACED_DIRS[@]} ))
}

# directory_holds_a_file DIR — true when anything but a directory or a leftover partial copy lies
# under DIR, at any depth. find does not descend into a symlink named as its starting point, so a DIR
# that is itself a symlink holds nothing by this test, whatever its target holds.
directory_holds_a_file() {
    local first_found
    first_found=$(find "$1" -mindepth 1 ! -type d ! -name "$PARTIAL_COPY_NAME_GLOB" -print -quit) || die "could not read $1"
    [[ -n "$first_found" ]]
}

# normal_memory_link_target KEY_DIR — print the target of KEY_DIR's memory symlink as an absolute,
# lexically normal path: a relative target is taken from KEY_DIR, as the kernel takes it.
normal_memory_link_target() {
    local key_dir=$1 link_target
    link_target=$(readlink -- "$key_dir/$MEMORY_ENTRY_NAME") || die "could not read the link in $key_dir"
    [[ "$link_target" == /* ]] || link_target="$key_dir/$link_target"
    lexically_normal_path "$link_target"
}

# state_of_memory_link KEY_DIR STORE_DIR STORE_CHECKOUT — print the state of KEY_DIR's memory symlink.
# The target is compared by its text, so a relative link to the right place is the right link. The
# right link is LINKED only while the store directory also resolves inside its checkout and outside the
# checkout's .git, the rule resolve_store_directory holds --apply to: a link planted above the store
# directory after the key was linked sends every write elsewhere, and the key's own link reads the same.
state_of_memory_link() {
    local key_dir=$1 store_dir=$2 store_checkout=$3 link_target physical_store_checkout
    # Each dies inside its command substitution, having said why.
    link_target=$(normal_memory_link_target "$key_dir") || exit "$EXIT_COULD_NOT_RUN"
    if [[ "$link_target" != "$(lexically_normal_path "$store_dir")" ]]; then
        printf 'WRONG-LINK'
        return 0
    fi
    if [[ ! -d "$store_dir" ]]; then
        printf 'DANGLING'
        return 0
    fi
    physical_store_checkout=$(physical_path_of "$store_checkout") || exit "$EXIT_COULD_NOT_RUN"
    if path_resolves_inside "$store_dir" "$physical_store_checkout" "$physical_store_checkout/.git"; then
        printf 'LINKED'
    else
        printf 'WRONG-LINK'
    fi
}

# state_of_memory_entry KEY STORE RELATIVE_DIR — print the state of a key whose store is checked out
# and whose merges are done with, or nothing when it has neither a memory entry nor a file in its
# store directory.
state_of_memory_entry() {
    local key_dir="$PROJECTS_DIR/$1"
    local memory_path="$key_dir/$MEMORY_ENTRY_NAME" store_dir="$STORES_ROOT/$2/$3"
    if [[ -L "$memory_path" ]]; then
        state_of_memory_link "$key_dir" "$store_dir" "$STORES_ROOT/$2"
    elif [[ -d "$memory_path" ]]; then
        printf 'REAL-DIR'
    elif [[ -e "$memory_path" ]]; then
        die "$memory_path is neither a directory nor a symlink"
    elif [[ -d "$store_dir" ]] && directory_holds_a_file "$store_dir"; then
        printf 'MISSING'
    fi
}

# state_of_mapped_key KEY STORE RELATIVE_DIR — print the state of a candidate's key, or nothing when
# it has no state.
state_of_mapped_key() {
    local key_dir="$PROJECTS_DIR/$1" store=$2
    require_readable_if_present "$key_dir"
    if has_unmerged_replaced_dir "$key_dir"; then
        printf 'PENDING-MERGE'
    elif [[ ! -e "$STORES_ROOT/$store/.git" ]]; then
        printf 'NO-STORE'
    else
        state_of_memory_entry "$1" "$2" "$3"
    fi
}

# key_holds_real_memory KEY — true when KEY's memory entry is a real directory holding a file. The
# `! -L` states the rule, that only a real directory counts. directory_holds_a_file also answers no for
# a symlink, so a mutant dropping `! -L` alone is equivalent.
key_holds_real_memory() {
    local memory_path="$PROJECTS_DIR/$1/$MEMORY_ENTRY_NAME"
    [[ -d "$memory_path" && ! -L "$memory_path" ]] && directory_holds_a_file "$memory_path"
}

# memory_links_into_store_checkout KEY STORE — true when KEY's memory entry is a symlink whose target
# lies in STORE's checkout, by its text, dangling or not. Asked of a NO-STORE key, whose store is not
# checked out here: it is the link a store removed after linking leaves, and nothing written through it
# is kept.
memory_links_into_store_checkout() {
    local key_dir="$PROJECTS_DIR/$1" link_target
    [[ -L "$key_dir/$MEMORY_ENTRY_NAME" ]] || return 1
    # It dies inside the command substitution, having said why.
    link_target=$(normal_memory_link_target "$key_dir") || exit "$EXIT_COULD_NOT_RUN"
    path_is_at_or_under "$link_target" "$(lexically_normal_path "$STORES_ROOT/$2")"
}

# state_of_unclaimed_key KEY — print the state of a key no candidate claims, or nothing.
state_of_unclaimed_key() {
    require_readable_if_present "$PROJECTS_DIR/$1"
    if has_unmerged_replaced_dir "$PROJECTS_DIR/$1"; then
        printf 'PENDING-MERGE'
    elif key_holds_real_memory "$1"; then
        printf 'UNMAPPED'
    fi
}

# ---------------------------------------------------------------------------------------------
# The merge: one replaced directory's files into a store directory. Nothing from here to prepare_apply
# ends the run: a failure is reported and returned, so that the other files and keys still go.
# ---------------------------------------------------------------------------------------------

# report_failure MESSAGE — say what could not be done, on stderr, and return 1.
report_failure() {
    printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2
    return 1
}

# entries_are_identical FIRST SECOND — 0 when both are links to one target, or regular files with one
# body; 1 when not; COMPARISON_FAILED when cmp cannot tell, having said so, since that must not read
# as "they differ".
entries_are_identical() {
    local first=$1 second=$2 comparison_status
    if [[ -L "$first" || -L "$second" ]]; then
        [[ -L "$first" && -L "$second" && "$(readlink -- "$first")" == "$(readlink -- "$second")" ]]
        return
    fi
    if ! is_regular_file "$first" || ! is_regular_file "$second"; then return 1; fi
    cmp -s -- "$first" "$second"
    comparison_status=$?
    if (( comparison_status > 1 )); then
        report_failure "could not compare $first and $second"
        return "$COMPARISON_FAILED"
    fi
    return "$comparison_status"
}

# partial_copy_path_of TARGET — where a copy waits beside TARGET until it is known to be whole.
partial_copy_path_of() { printf '%s/.%s%s' "${1%/*}" "${1##*/}" "$PARTIAL_COPY_SUFFIX"; }

# remove_leftover_partial_copy TARGET — remove what a stopped run left on its way to TARGET. The one
# place a leftover goes: the name is derived from this file, so no other merge can reach it.
remove_leftover_partial_copy() {
    local partial_path
    partial_path=$(partial_copy_path_of "$1")
    if path_is_free "$partial_path"; then return 0; fi
    rm -f -- "$partial_path" || report_failure "could not remove the leftover $partial_path"
}

# publish_copy SOURCE TARGET — bring SOURCE to TARGET whole or not at all, keeping mode and mtime and
# copying a link as a link. cmp tells a short copy by its size as well as its bytes. link(2) cannot
# overwrite, and -T keeps both tools out of a directory at the name. Returns 0 when published,
# PUBLISH_TARGET_TAKEN when something is at TARGET by then, which stays as it is, and 1 when it
# failed, having said so; the partial then stays for the next merge of this file.
publish_copy() {
    local source_file=$1 target_file=$2 partial_path copy_output link_output comparison_status publish_status=0
    partial_path=$(partial_copy_path_of "$target_file")
    if ! copy_output=$(cp -T -P -p -- "$source_file" "$partial_path" 2>&1); then
        report_failure "could not copy $source_file to $partial_path: $copy_output"
        return 1
    fi
    entries_are_identical "$source_file" "$partial_path"
    comparison_status=$?
    if (( comparison_status == 1 )); then
        report_failure "the copy of $source_file did not arrive whole at $partial_path"
    fi
    (( comparison_status == 0 )) || return 1
    if ! link_output=$(ln -P -T -- "$partial_path" "$target_file" 2>&1); then
        if path_is_free "$target_file"; then
            report_failure "could not publish $partial_path as $target_file: $link_output"
            return 1
        fi
        publish_status=$PUBLISH_TARGET_TAKEN
    fi
    rm -f -- "$partial_path" || { report_failure "could not remove $partial_path"; return 1; }
    return "$publish_status"
}

# append_lines_only_in_source SOURCE TARGET — append to the index TARGET each line only SOURCE has, in
# SOURCE's order and once each. With no such line TARGET is not touched. The keys are prefixed because
# an associative array can refuse an empty subscript, depending on the bash, and a blank line is one.
append_lines_only_in_source() {
    local source_file=$1 target_file=$2 line lines_to_append=''
    local -A seen_lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        seen_lines["line:$line"]=1
    done < "$target_file" || { report_failure "could not read $target_file"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${seen_lines["line:$line"]:-}" ]] || continue
        seen_lines["line:$line"]=1
        lines_to_append+="$line"$'\n'
    done < "$source_file" || { report_failure "could not read $source_file"; return 1; }
    [[ -n "$lines_to_append" ]] || return 0
    # The store's last line stays whole. $(...) drops a final newline, so a last byte shows only if
    # it is something else; an empty file shows none.
    if [[ -n "$(tail -c 1 -- "$target_file")" ]]; then
        lines_to_append=$'\n'"$lines_to_append"
    fi
    printf '%s' "$lines_to_append" >> "$target_file" || report_failure "could not add lines to $target_file"
}

# write_conflict_copy SOURCE TARGET — copy SOURCE beside TARGET under the first conflict-copy name
# that is free. A name already holding SOURCE's body means that copy exists, and nothing is written.
# The loop only steps over names that are taken, and over MAX_CONFLICT_COPIES of them it stops.
write_conflict_copy() {
    local source_file=$1 target_parent=${2%/*} target_name=${2##*/}
    local name_stem=$target_name final_extension='' ordinal=1 infix copy_path copy_status
    # .hidden and trailing. have no extension: the infix goes after the whole name.
    if [[ "$target_name" == ?*.?* ]]; then
        name_stem=${target_name%.*}
        final_extension=".${target_name##*.}"
    fi
    while (( ordinal <= MAX_CONFLICT_COPIES )); do
        infix="$CONFLICT_INFIX$HOST_NAME"
        (( ordinal == 1 )) || infix+=".$ordinal"
        copy_path="$target_parent/$name_stem$infix$final_extension"
        remove_leftover_partial_copy "$copy_path" || return 1
        if path_is_free "$copy_path"; then
            publish_copy "$source_file" "$copy_path"
            copy_status=$?
            (( copy_status == PUBLISH_TARGET_TAKEN )) || return "$copy_status"
        fi
        entries_are_identical "$source_file" "$copy_path"
        copy_status=$?
        (( copy_status != 0 )) || return 0
        (( copy_status == 1 )) || return 1
        ordinal=$(( ordinal + 1 ))
    done
    report_failure "gave up on a conflict copy of $2: $MAX_CONFLICT_COPIES names are taken"
}

# is_index_file_name NAME — true for a file whose difference is a line union, not a conflict copy.
is_index_file_name() {
    # shellcheck disable=SC2053  # the glob on the right is the point
    [[ "$1" == "$INDEX_FILE_NAME" || "$1" == $TOPIC_INDEX_FILE_GLOB ]]
}

# keep_both SOURCE TARGET EXISTING — SOURCE differs from what the store holds at TARGET. EXISTING is
# that entry, or on a dry run perhaps the source that would be there.
keep_both() {
    local source_file=$1 target_file=$2 existing_file=$3 target_name=${2##*/}
    KEPT_BOTH_COUNT=$(( KEPT_BOTH_COUNT + 1 ))
    (( ! IS_DRY_RUN )) || return 0
    if is_index_file_name "$target_name" && is_regular_file "$source_file" && is_regular_file "$existing_file"; then
        append_lines_only_in_source "$source_file" "$target_file"
    else
        write_conflict_copy "$source_file" "$target_file"
    fi
}

# path_resolves_inside PATH PHYSICAL_ANCHOR [PHYSICAL_EXCLUDED] — false when the deepest part of PATH
# that exists resolves outside PHYSICAL_ANCHOR, or at or under PHYSICAL_EXCLUDED when one is given, or
# does not resolve at all. Asked before anything reads or writes there, since mkdir -p, >> and cp all
# follow a symlink. A plain file in the way leads nowhere, and mkdir -p reports it.
path_resolves_inside() {
    local existing_ancestor=$1 physical_anchor=$2 physical_excluded=${3:-} physical_ancestor
    while [[ -n "$existing_ancestor" ]] && path_is_free "$existing_ancestor"; do
        existing_ancestor=${existing_ancestor%/*}
    done
    if is_regular_file "$existing_ancestor"; then return 0; fi
    physical_ancestor=$(cd -P -- "$existing_ancestor" 2>/dev/null && pwd -P) || return 1
    path_is_at_or_under "$physical_ancestor" "$physical_anchor" || return 1
    [[ -z "$physical_excluded" ]] || ! path_is_at_or_under "$physical_ancestor" "$physical_excluded"
}

# resolve_store_directory STORE_DIR — set PHYSICAL_STORE_DIR, making the directory first on a real
# run. On a dry run one that does not exist yet stays empty: nothing in it can lead anywhere. A store
# directory that leads out of its checkout, or into the checkout's .git, is refused here, before the
# mkdir that would follow it. So every path to the directory comes through here first, and a refusal
# leaves the key as it was.
resolve_store_directory() {
    local store_dir=$1 physical_git_dir="$PHYSICAL_STORE_CHECKOUT/.git"
    PHYSICAL_STORE_DIR=''
    if ! path_resolves_inside "$store_dir" "$PHYSICAL_STORE_CHECKOUT"; then
        report_failure "refusing $store_dir: it resolves outside the store checkout $PHYSICAL_STORE_CHECKOUT"
        return 1
    fi
    # Inside the checkout and still no place for memory: git runs what lies under .git, so a memory file
    # named like a hook would become one that the sync's own `git merge` runs.
    if ! path_resolves_inside "$store_dir" "$PHYSICAL_STORE_CHECKOUT" "$physical_git_dir"; then
        report_failure "refusing $store_dir: it resolves into the store checkout's git directory $physical_git_dir"
        return 1
    fi
    if (( ! IS_DRY_RUN )) && ! mkdir -p -- "$store_dir"; then
        report_failure "could not create $store_dir"
        return 1
    fi
    [[ -d "$store_dir" ]] || return 0
    # It dies inside the command substitution, having said why.
    PHYSICAL_STORE_DIR=$(physical_path_of "$store_dir") || return 1
}

# target_parent_is_inside_store PARENT — path_resolves_inside for a file's directory, against the store
# directory, which resolve_store_directory has already held inside its checkout.
target_parent_is_inside_store() {
    [[ -n "$PHYSICAL_STORE_DIR" ]] || return 0
    path_resolves_inside "$1" "$PHYSICAL_STORE_DIR"
}

# merge_file_into_store SOURCE TARGET — bring one file of a replaced directory into the store, or
# return 1 having said why. A FIFO would hang cp while this run holds the lock, and a device has no
# body to keep, so anything but a file or a symlink is such a failure.
merge_file_into_store() {
    local source_file=$1 target_file=$2 target_parent=${2%/*} existing_file merge_status
    if [[ ! -L "$source_file" && ! -f "$source_file" ]]; then
        report_failure "$source_file is neither a file nor a symlink"
        return 1
    fi
    if ! target_parent_is_inside_store "$target_parent"; then
        report_failure "refusing $target_file: its directory resolves outside $PHYSICAL_STORE_DIR"
        return 1
    fi
    if (( ! IS_DRY_RUN )); then remove_leftover_partial_copy "$target_file" || return 1; fi
    existing_file=${PLANNED_SOURCE_OF_TARGET[$target_file]:-$target_file}
    if path_is_free "$existing_file"; then
        if (( IS_DRY_RUN )); then
            PLANNED_SOURCE_OF_TARGET[$target_file]=$source_file
            COPIED_COUNT=$(( COPIED_COUNT + 1 ))
            return 0
        fi
        mkdir -p -- "$target_parent" || { report_failure "could not create $target_parent"; return 1; }
        publish_copy "$source_file" "$target_file"
        merge_status=$?
        if (( merge_status == 0 )); then
            COPIED_COUNT=$(( COPIED_COUNT + 1 ))
            return 0
        fi
        (( merge_status == PUBLISH_TARGET_TAKEN )) || return 1
        # A writer got there first. Its file stays, and is compared like any other.
    fi
    entries_are_identical "$source_file" "$existing_file"
    merge_status=$?
    if (( merge_status == 0 )); then
        IDENTICAL_COUNT=$(( IDENTICAL_COUNT + 1 ))
        return 0
    fi
    (( merge_status == 1 )) || return 1
    keep_both "$source_file" "$target_file" "$existing_file"
}

# merge_directory_into_store SOURCE_DIR STORE_DIR [FIND_TEST…] — every file under SOURCE_DIR, NUL-safe,
# that passes FIND_TEST, but a leftover partial and the directory's own marker. A file that fails stops
# only itself, and a walk that fails partway still merges what it listed; either returns 1, so the
# marker stays as it was.
merge_directory_into_store() {
    local source_dir=$1 store_dir=$2 source_files=() source_file has_failed=0
    shift 2
    resolve_store_directory "$store_dir" || return 1
    if ! read_nul_items source_files find "$source_dir" -mindepth 1 ! -type d ! -name "$PARTIAL_COPY_NAME_GLOB" "$@" -print0; then
        report_failure "could not read $source_dir"
        has_failed=1
    fi
    for source_file in "${source_files[@]}"; do
        [[ "$source_file" != "$source_dir/$MERGED_MARKER_NAME" ]] || continue
        merge_file_into_store "$source_file" "$store_dir/${source_file#"$source_dir"/}" || has_failed=1
    done
    return "$has_failed"
}

# write_merged_marker REPLACED_DIR — the marker, never through a symlink at its path and never into
# anything else that is not a regular file: opening a fifo blocks this run, under the lock, until a
# reader comes. A dry run asks the same questions and writes nothing.
write_merged_marker() {
    local marker_path="$1/$MERGED_MARKER_NAME"
    if [[ -L "$marker_path" ]]; then
        report_failure "refusing to write the marker through the symlink $marker_path"
        return 1
    fi
    if ! path_is_free "$marker_path" && ! is_regular_file "$marker_path"; then
        report_failure "refusing to write the marker at $marker_path: it is not a regular file"
        return 1
    fi
    (( ! IS_DRY_RUN )) || return 0
    : > "$marker_path" || report_failure "could not write the marker in $1"
}

# merge_unmarked_replaced_dirs KEY_DIR STORE_DIR — merge each replaced directory lacking the marker,
# and write the marker only in one that merged whole. Where a marker stands, what load_unmarked_replaced_dirs
# found is a file newer than it, and only those go: the rest merged when the marker was written, and the
# store has been free to move on from it since.
merge_unmarked_replaced_dirs() {
    local key_dir=$1 store_dir=$2 replaced_dir has_failed=0 newer_than_marker
    load_unmarked_replaced_dirs "$key_dir"
    for replaced_dir in "${UNMARKED_REPLACED_DIRS[@]}"; do
        newer_than_marker=()
        if is_regular_file "$replaced_dir/$MERGED_MARKER_NAME"; then
            newer_than_marker=(-newer "$replaced_dir/$MERGED_MARKER_NAME")
        fi
        if merge_directory_into_store "$replaced_dir" "$store_dir" "${newer_than_marker[@]}"; then
            write_merged_marker "$replaced_dir" || has_failed=1
        else
            has_failed=1
        fi
    done
    return "$has_failed"
}

# ---------------------------------------------------------------------------------------------
# The swap: a key's memory entry to a link.
# ---------------------------------------------------------------------------------------------

# rename_memory_aside KEY_DIR STAMP — rename the real memory directory to the first free replaced
# name: memory.replaced-<stamp>, then .001, .002, … mv -T would replace an empty directory there. A
# marker inside is stale (see the header) and goes first, so that the new name never reads as merged.
rename_memory_aside() {
    local key_dir=$1 stamp=$2 memory_path="$1/$MEMORY_ENTRY_NAME" ordinal=0 replaced_path base_path
    base_path="$memory_path$REPLACED_DIR_INFIX$stamp"
    replaced_path=$base_path
    while ! path_is_free "$replaced_path"; do
        ordinal=$(( ordinal + 1 ))
        printf -v replaced_path '%s.%03d' "$base_path" "$ordinal"
    done
    rm -f -- "$memory_path/$MERGED_MARKER_NAME" || { report_failure "could not clear the stale marker in $memory_path"; return 1; }
    mv -T -- "$memory_path" "$replaced_path" || report_failure "could not rename $memory_path to $replaced_path"
}

# link_memory_entry KEY_DIR STORE_DIR STAMP — make memory the link. Without -T, ln would put the link
# inside a directory a writer just recreated, and report success. That directory goes aside and the
# link is retried; a writer that outlasts the retries stops this key with every directory unmarked.
link_memory_entry() {
    local key_dir=$1 store_dir=$2 stamp=$3 memory_path="$1/$MEMORY_ENTRY_NAME" retries=0 link_error
    while ! link_error=$(ln -s -T -- "$store_dir" "$memory_path" 2>&1); do
        if [[ ! -d "$memory_path" || -L "$memory_path" ]]; then
            report_failure "could not link $memory_path to $store_dir: $link_error"
            return 1
        fi
        if (( retries >= MAX_LINK_RETRIES )); then
            report_failure "gave up on $memory_path: recreated again after $MAX_LINK_RETRIES retries; its replaced directories stay unmarked"
            return 1
        fi
        retries=$(( retries + 1 ))
        rename_memory_aside "$key_dir" "$stamp" || return 1
    done
}

# swap_real_directory_for_link KEY_DIR STORE_DIR — steps 1 to 4 of THE SWAP. A dry run counts what the
# merge would find in the directory as it stands.
swap_real_directory_for_link() {
    local key_dir=$1 store_dir=$2 stamp
    if (( IS_DRY_RUN )); then
        merge_directory_into_store "$key_dir/$MEMORY_ENTRY_NAME" "$store_dir"
        return
    fi
    resolve_store_directory "$store_dir" || return 1
    stamp=$(date -u "$REPLACED_STAMP_FORMAT") || { report_failure "could not read the clock"; return 1; }
    rename_memory_aside "$key_dir" "$stamp" || return 1
    link_memory_entry "$key_dir" "$store_dir" "$stamp" || return 1
    merge_unmarked_replaced_dirs "$key_dir" "$store_dir"
}

# link_missing_entry KEY_DIR STORE_DIR — make the link where no entry exists. A session can create a
# real directory here too, so this ends with the same merge.
link_missing_entry() {
    local key_dir=$1 store_dir=$2 stamp
    resolve_store_directory "$store_dir" || return 1
    (( ! IS_DRY_RUN )) || return 0
    mkdir -p -- "$key_dir" || { report_failure "could not create $key_dir"; return 1; }
    stamp=$(date -u "$REPLACED_STAMP_FORMAT") || { report_failure "could not read the clock"; return 1; }
    link_memory_entry "$key_dir" "$store_dir" "$stamp" || return 1
    merge_unmarked_replaced_dirs "$key_dir" "$store_dir"
}

# apply_key KEY STORE RELATIVE_DIR — finish the key's pending merges, bring its entry to a link, and
# print its line if anything was to do. Returns 1 if any of that failed, having said why, and prints
# no line then. A pending merge that fails does not hold the entry back: the files that could not go
# stay where they are either way, and new writes belong in the store. WRONG-LINK, NO-STORE and a key
# with no state keep what they have.
apply_key() {
    local key=$1 store=$2 relative_dir=$3
    local key_dir="$PROJECTS_DIR/$1" store_dir="$STORES_ROOT/$2/$3" had_unmerged=0 has_failed=0 state report_verb=linked
    # A subshell, because this check dies and a key that cannot be read stops only itself.
    ( require_readable_if_present "$key_dir" ) || return 1
    # Pending or not: with no store here, a merge has nowhere it may go.
    [[ -e "$STORES_ROOT/$store/.git" ]] || return 0
    # It dies inside the command substitution, having said why.
    PHYSICAL_STORE_CHECKOUT=$(physical_path_of "$STORES_ROOT/$store") || return 1
    COPIED_COUNT=0
    IDENTICAL_COUNT=0
    KEPT_BOTH_COUNT=0
    if has_unmerged_replaced_dir "$key_dir"; then
        had_unmerged=1
        merge_unmarked_replaced_dirs "$key_dir" "$store_dir" || has_failed=1
    fi
    # It dies inside the command substitution, having said why.
    state=$(state_of_memory_entry "$key" "$store" "$relative_dir") || return 1
    # A run stopped between the rename and the link left no entry, and if its directory was empty
    # nothing in the store either. The replaced directory is what says a link is due.
    if [[ -z "$state" ]] && (( had_unmerged )); then state=MISSING; fi
    case "$state" in
        REAL-DIR) swap_real_directory_for_link "$key_dir" "$store_dir" || has_failed=1 ;;
        MISSING)  link_missing_entry "$key_dir" "$store_dir" || has_failed=1 ;;
        DANGLING) resolve_store_directory "$store_dir" || has_failed=1 ;;
        WRONG-LINK)
            (( had_unmerged )) || return 0
            report_verb=merged ;;
        *)  (( had_unmerged )) || return 0 ;;
    esac
    (( ! has_failed )) || return 1
    printf '%s %s -> %s (copied %d, identical %d, kept-both %d)\n' "$report_verb" "$key" \
        "$(escaped_for_one_line "$store_dir")" "$COPIED_COUNT" "$IDENTICAL_COUNT" "$KEPT_BOTH_COUNT"
}

# apply_all_keys — apply_key for every candidate, or for the one --only names. Keys no candidate
# claims are not walked: an unmapped one has no store directory to go to. A key that fails stops only
# itself; the run exits 2 at the end, naming each. Each key runs in this shell, not a subshell: the
# dry run's plan and each key's counts live here.
apply_all_keys() {
    local index failed_keys=()
    if [[ -n "$ONLY_KEY" && -z "${SOURCE_DIR_OF_KEY[$ONLY_KEY]:-}" ]]; then
        die "no candidate on this host claims key $ONLY_KEY"
    fi
    for (( index = 0; index < ${#CANDIDATE_KEYS[@]}; index++ )); do
        if [[ -n "$ONLY_KEY" && "${CANDIDATE_KEYS[index]}" != "$ONLY_KEY" ]]; then continue; fi
        apply_key "${CANDIDATE_KEYS[index]}" "${CANDIDATE_STORES[index]}" "${CANDIDATE_RELATIVE_DIRS[index]}" \
            || failed_keys+=("${CANDIDATE_KEYS[index]}")
    done
    if (( ${#failed_keys[@]} )); then
        die "could not finish ${#failed_keys[@]} key(s): ${failed_keys[*]}"
    fi
}

# prepare_apply — settle the host name and, on a real run, wait for the lock. Everything that reads a
# key's state happens after this, so a run that waited sees what the previous run left.
prepare_apply() {
    local lock_path="$STATE_DIR/$LINK_LOCK_FILE_NAME" link_lock_fd flock_status
    local lock_wait_seconds="${CLAUDE_MEMORY_LOCK_WAIT_SECONDS:-$LOCK_WAIT_SECONDS_DEFAULT}"
    HOST_NAME=${CLAUDE_MEMORY_HOST:-$(hostname -s)}
    [[ "$HOST_NAME" =~ $HOST_NAME_RE ]] || die "host name '$HOST_NAME' cannot go in a file name"
    [[ "$lock_wait_seconds" =~ $LOCK_WAIT_SECONDS_RE ]] \
        || die "CLAUDE_MEMORY_LOCK_WAIT_SECONDS '$lock_wait_seconds' is not a whole number of seconds above 0"
    (( ! IS_DRY_RUN )) || return 0
    mkdir -p -- "$STATE_DIR" || die "could not create $STATE_DIR"
    # The descriptor stays open after this function returns, and with it the lock, until the run ends.
    exec {link_lock_fd}>> "$lock_path" || die "could not open the lock $lock_path"
    flock -E "$FLOCK_WAIT_RAN_OUT_STATUS" -w "$lock_wait_seconds" "$link_lock_fd"
    flock_status=$?
    if (( flock_status == FLOCK_WAIT_RAN_OUT_STATUS )); then
        die "another run still held the lock $lock_path after $lock_wait_seconds s"
    fi
    (( flock_status == 0 )) || die "could not take the lock $lock_path"
}

# ---------------------------------------------------------------------------------------------
# The report and the verbs.
# ---------------------------------------------------------------------------------------------

# escaped_for_one_line TEXT — TEXT with a backslash, tab or newline written \\, \t or \n, so that it
# stays on one line of output.
escaped_for_one_line() {
    local text=$1
    text=${text//\\/\\\\}
    text=${text//$'\t'/\\t}
    text=${text//$'\n'/\\n}
    printf '%s' "$text"
}

# add_row STATE KEY STORE RELATIVE_DIR SOURCE_DIR — record a row: its state, and its TSV line.
add_row() {
    local field escaped_fields=()
    ROW_KEYS+=("$2")
    ROW_STATES+=("$1")
    ROW_STORES+=("$3")
    for field in "$2" "$1" "$3" "$4" "$5"; do
        escaped_fields+=("$(escaped_for_one_line "$field")")
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

# print_check — each row that is not LINKED or NO-STORE, then the summary; exit 1 if any is to fix. A
# NO-STORE key is no row, but one holding memory counts: with no store here it is what "0 linked" hides.
# So does one whose link points into its store's checkout: a store removed after linking leaves every
# key NO-STORE with no real directory, and uncounted that would read as nothing to report.
print_check() {
    local index linked_count=0 to_fix_count=0 unmapped_count=0 without_store_count=0
    for (( index = 0; index < ${#ROW_STATES[@]}; index++ )); do
        case "${ROW_STATES[index]}" in
            LINKED)   linked_count=$(( linked_count + 1 )); continue ;;
            NO-STORE)
                if key_holds_real_memory "${ROW_KEYS[index]}" \
                    || memory_links_into_store_checkout "${ROW_KEYS[index]}" "${ROW_STORES[index]}"; then
                    without_store_count=$(( without_store_count + 1 ))
                fi
                continue ;;
            UNMAPPED) unmapped_count=$(( unmapped_count + 1 )) ;;
            *)        to_fix_count=$(( to_fix_count + 1 )) ;;
        esac
        printf '%s\n' "${ROW_LINES[index]}"
    done
    printf '%s: %d linked, %d to fix, %d unmapped, %d without a store\n' \
        "$SCRIPT_NAME" "$linked_count" "$to_fix_count" "$unmapped_count" "$without_store_count"
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
    if [[ "$MODE" == apply ]]; then
        command -v flock >/dev/null || die "flock is required"
        command -v cmp >/dev/null || die "cmp is required"
    fi
    require_readable_if_present "$PROJECTS_DIR"
    load_store_table
    if [[ "$MODE" == apply ]]; then prepare_apply; fi
    load_candidates
    case "$MODE" in
        apply) apply_all_keys ;;
        list)  load_rows; print_list ;;
        check) load_rows; print_check ;;
    esac
}

# Sourced, only the functions are defined: the table calls project_key_of_path directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
