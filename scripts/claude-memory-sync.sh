#!/usr/bin/env bash
#
# scripts/claude-memory-sync.sh
# =============================
#
# Sync each checked-out Claude Code memory store with its remote: stage every file in it, withhold
# each file that carries a credential shape, commit the rest as one commit, fetch, merge the remote in
# (never rebase), keeping both copies on a conflict, and push. --check reports what a run would commit
# and withhold; --scan looks for credential shapes in a committed tree; --status reports how each store
# last synced, for the doctor.
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
# A STORE PUSHES ONLY TO ITS OWN REMOTE. Every verb first checks that every fetch and push URL of the
# store's `origin` is the table's `remote`: a difference is could-not-run for that store, with nothing
# staged, counted or scanned. The URLs are git's own answer (`git remote get-url [--push] --all
# origin`, insteadOf applied), since those are the ones a push would use. This script never prints a
# URL of its own accord, since one can carry a credential; git's own error text, which can name the
# URL, is printed and kept in a status detail only after the redactor. A store with no `origin` at all
# is local-only.
#
# NO IGNORE RULE DECIDES WHAT IS MEMORY. `git add -A` skips ignored paths without a word, and a global
# ignore file, .git/info/exclude and a nested .gitignore all apply otherwise, so the stage is
# `git add -A -f` over the whole store. Its pathspec leaves out the link script's partial copies,
# .<name>.link-partial, at every depth, so a copy not yet verified whole is never committed; --check
# counts with the same pathspec, so a leftover partial never reads as pending. The stage, the gate and
# the commit run holding <state dir>/link.lock, the link script's own lock, so an index mid-write is
# never staged. A run waits for it CLAUDE_MEMORY_LOCK_WAIT_SECONDS at most (120 by default), then
# gives up on that store as could-not-run. The merge runs under the same hold, since it writes into the
# tree the link script writes into; the fetch runs before the lock and the push after it, so no network
# wait ever holds up a link run. Every git call is made with the lock's descriptor closed in git's own
# process, so nothing git starts (a hook, a file-system monitor, a detached maintenance) can hold the
# lock past the end of this run and stop every later link run.
#
# TIME. Per store, at most: gh-route GH_ROUTE_TIMEOUT_SECONDS (20 s), the fetch and the push
# NETWORK_TIMEOUT_SECONDS each (60 s), each of those three killed NETWORK_KILL_AFTER_SECONDS (5 s)
# after that, and the lock wait LOCK_WAIT_SECONDS (120 s). Across the stores, RUN_DEADLINE_SECONDS
# (240 s from the start of the run), measured on the kernel's monotonic uptime (/proc/uptime: every
# host this runs on is Linux), so a step of the wall clock moves it neither way. Whether a store does
# network work at all is decided ONCE, before its first network step: a store that begins past the
# deadline asks gh-route nothing and fetches nothing, and records unreachable, `run deadline`, after
# its local commit. A store that began before it asks gh-route and fetches; its push is looked at
# again and does not start past the deadline either (unreachable, `run deadline`): a later look can
# only drop network work, never add it. No lock wait runs past the deadline (MIN_LOCK_WAIT_SECONDS,
# 1 s, at least). The deadline is looked at between steps and never cuts one short, so this script
# never interrupts a merge and its commit. A run therefore ends within the deadline, plus a gh-route
# call and a fetch that began just before it (90 s at most), plus the local git work of the stores
# after it: about 330 s and that local work at the defaults, which is what the unit's time limit has
# to allow.
#
# NO HOOK RUNS AND NO MONITOR STARTS. Every git call, a read as much as a write, is made with
# core.hooksPath=/dev/null and core.fsmonitor=false (GIT_SAFETY_OPTIONS, applied by git_in_store), and
# the commit, the merge and the push also with --no-verify. A host's hooks would otherwise run between
# the gate and the commit, and a hook can stage a file the gate held back; the global pre-commit this
# repository installs (config/git/hooks) runs `pre-commit run` in any repository holding a
# .pre-commit-config.yaml, which would make a memory file a program every host's timer runs. A
# file-system monitor the host names runs on any call that reads the index, the gate's own reads
# included, and can stage a file the same way. On git 2.53 core.hooksPath alone keeps every hook off;
# --no-verify is a second switch, should a later git define hooks where core.hooksPath does not reach.
# The maintenance a call may start runs in the foreground (autoDetach off), so the run ends when its
# git work has, and a unit that stops every process it started when the run ends never cuts one short.
#
# AUTH. Before any git call for a store, `scripts/gh-route <store dir>` says which GitHub account the
# directory routes to (M7: the keyring is keyed by host and cannot choose one):
#   could not answer (exit 2)        could-not-run, and the store is not touched
#   matched or default, with a       the token is read from the file gh-route names into this
#     token in the file it names     process, and given to the fetch and the push alone, in their
#                                    environment (CLAUDE_MEMORY_GIT_TOKEN, with GH_CONFIG_DIR), never
#                                    in an argument; each runs with every configured credential
#                                    helper cleared and one inline helper that answers only `get`,
#                                    from that variable, and fails when it is empty
#   matched or default, the file     skipped-no-token: the store is committed, and nothing is fetched
#     missing, empty or unreadable   or pushed
#   none, no-repo or no-remotes      git's own credential helpers, unpinned
# The token is in no argument, no output and no status. A network call has no prompt and no askpass
# program, runs in the C locale (its errors are read), redacts any trace git writes, and is cut off
# after NETWORK_TIMEOUT_SECONDS. git's trace variables (GIT_TRACE and every GIT_TRACE_*) and
# GIT_CURL_VERBOSE are unset when the run starts: with them, git writes curl's headers, the
# Authorization header among them, to the stderr this script keeps in a status detail, and the redactor
# has no rule for a Basic credential.
#
# ONE ATTEMPT PER RUN, for a store with an origin:
#   refuse   a merge, a cherry-pick, a revert or a rebase in progress, unmerged entries in the index
#            (a conflicted `git stash pop` leaves them with no MERGE_HEAD), or a detached HEAD, is
#            could-not-run before anything is staged, and is never reset: a stage would take the
#            conflict markers and a commit would conclude the operation. A person finishes or aborts it
#   fetch    failure: auth-failed when git's error names an auth or not-found failure, unreachable for
#            anything else. The store is still committed
#   merge    unless HEAD already holds origin/<branch>: one `git merge` (M8: a rebase empties the tree
#            of every unpushed file while it replays). Renames are off, so a rename is a deletion and
#            an addition; unrelated histories are allowed, so a store that committed before its first
#            fetch is not refused forever. When git will not start because a local file is in the way
#            (a withheld file, say), the outcome is blocked, naming it. On a conflict, by what each
#            side did:
#              both modified, both added    the remote's copy takes the name and ours becomes the
#                                           conflict copy (M4: x.md -> x.conflict-<host>.md, no
#                                           extension: appended; a name another body holds is passed
#                                           over for .conflict-<host>.2, .3, ...). An index (MEMORY.md,
#                                           INDEX_*.md) instead keeps the remote's lines and gains each
#                                           line only ours has
#              deleted here, changed there  the remote's copy
#              changed here, deleted there  ours: an edit beats a deletion
#              anything else                `git merge --abort`, could-not-run
#            Every resolution is staged from the blobs the merge produced, never from the working
#            tree, so nothing the gate has not seen is committed. The commit is named `<host>: merge,
#            kept both for <n> files`, and the outcome is kept-both. No run leaves MERGE_HEAD behind:
#            a merge that fails is aborted
#   push     once, HEAD to origin's branch, unless origin already holds HEAD. A rejection is
#            push-rejected; the next run fetches again
# Every outcome but could-not-run exits 0: a stale store is the doctor's to show, through --status.
#
# THE GATE withholds files; it never refuses the commit (M6). Each staged path has its name, then its
# staged blob (a submodule has a name alone), passed through `scripts/redact-secrets.sh
# --shapes-only` in one read, and the two compared by digest. When the redactor changes either, the
# path is unstaged (`git reset`) and named with the labels of the shapes found, never a line of it,
# and the rest is committed. A name is redacted wherever it is printed or written, the status
# included. The file stays in the working tree, so every run stages it, finds it and names it again
# until someone edits or renames it. Shapes only: the by-name rules would withhold ordinary prose such
# as `FOO_TOKEN=value` forever. The stage wrote the withheld blob to the object database; it is in no
# commit, so no push carries it, and git's gc prunes it. The gate reads the blob git stores: where the
# host configures a clean filter for a path (git-lfs, say), that is the filter's output, a pointer,
# and not the file's content.
#
# THE COMMIT is named `<host>: <n> files`, n counting every path it changes, deletions included, and
# is made with --no-gpg-sign: a timer has no one to unlock a signing key.
#
# THE STATUS of a store is <state dir>/<store>.status, one line: epoch<TAB>outcome<TAB>detail, with
# a backslash, tab or newline in the detail written \\, \t or \n. The outcomes:
#   ok                the store is committed, merged with origin and pushed, or origin already held it
#   kept-both         the same, after a conflict that left a conflict copy or a line union
#   ok-local-only     the store has no origin, and was committed or had nothing to commit
#   withheld          the gate held a file back; the detail names each one
#   blocked           the merge would not start, a local file in its way; the detail names it
#   push-rejected     origin refused the push
#   skipped-no-token  the route pins an account and its token file is missing, empty or unreadable
#   unreachable       the fetch or the push failed, or ran out of time, for no reason naming auth
#   auth-failed       git's error named an auth or a not-found failure
#   could-not-run     the store could not be synced; the detail says why
# A run that withheld a file and then pushed records withheld; one that withheld a file and then
# failed to fetch or push records that failure, with the withheld files added to its detail. Git's
# errors in a detail pass through scripts/redact-secrets.sh first.
# <state dir>/<store>.last-ok holds the epoch of the last push or up-to-date check that succeeded.
#
# --status prints `<store><TAB><level><TAB><message>` lines for each checked-out store, levels ok, warn
# and bad:
#   bad    the last outcome is withheld, blocked, auth-failed or could-not-run, naming the file or
#          reason; or the store has an origin and its last-ok is missing or older than the threshold,
#          with the last outcome and detail; or the store cannot be read at all (an origin that is not
#          the table's remote, an origin git cannot read, a status or last-ok file this script did not
#          write, a tree it cannot search), naming the reason through the redactor, and nothing else is
#          said about that store. A store the table names that is not checked out here is skipped,
#          never a bad line: a host carries only the stores of the tenants it serves
#   warn   the last outcome is ok-local-only (no remote yet); push-rejected, unreachable or
#          skipped-no-token while last-ok is still within the threshold; no run recorded for a store
#          with no origin; any conflict copy in the tree, counted; an index line (MEMORY.md, INDEX_*.md)
#          naming a file that is not there, or one file named by two index lines, counted per directory
#   ok     none of the above about the last run: `last synced <n> min ago`
# The threshold is the table's stale_after_minutes[<host>], else its .default, else
# STALE_AFTER_MINUTES_DEFAULT minutes.
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
#                    a store with no commit has nothing to scan) whose name or content carries a
#                    credential shape: the gate, for commits this script did not make. Exit 1 when any
#                    is found
#   claude-memory-sync --apply [--store <name>]
#                    the route, the origin check, the fetch, then the stage, the gate, the commit and the
#                    merge under the lock, then the push, store by store: a line
#                    `<store>: withheld <path> (<labels>)` for each file held back, then
#                    `<store>: committed <n> files` when there was something to commit,
#                    `<store>: merged origin/<branch>[, kept both for <n> files]`, `<store>: pushed`, and
#                    `<store>: <outcome>: <detail>` for blocked, push-rejected, skipped-no-token,
#                    unreachable and auth-failed. A store that cannot run says why on stderr, and the
#                    later stores still run
#   claude-memory-sync --status [--store <name>]
#                    `<store><TAB><level><TAB><message>` lines, one or more per checked-out store, levels
#                    ok, warn and bad (this script's header says when each is printed); a store it cannot
#                    read is a bad line, and the stores after it are still read. Never writes, never
#                    fetches, takes no lock
#   claude-memory-sync --help    this text
#   --store limits any verb to that store; a name the table does not hold is exit 2.
#
# Exit: 0 ok, or no store table here (nothing to do)
#       1 attention on --check and --scan
#       2 could not run (HOME unset, no jq, git or sha256sum, a bad store table, an unknown --store, a
#         revision that does not resolve, an origin that is not the table's remote (but on --status a
#         bad line), an unusable host name; on --apply also no flock or timeout, a gh-route that is not executable or could not
#         answer in time, an unusable lock wait, run deadline or gh-route limit, a lock still held when
#         the wait ran out, a merge, cherry-pick, revert or rebase in progress, unmerged index entries
#         or a detached HEAD, a conflict the sync does not resolve, and a lock, stage, gate, commit,
#         merge, status or last-ok write that failed, reported once the other stores have run)
#       64 usage
#   --apply exits only 0 or 2: a withheld file, a conflict copy, a blocked merge, a rejected push, a
#   missing token or an unreachable remote is a status for the doctor, not a failed unit. --status
#   exits 0 whatever levels it prints, a store it cannot read included (a bad line), and 2 only when it
#   could read nothing: HOME unset, no jq, git or sha256sum, a bad store table or threshold, an unknown
#   --store, an unusable host name, or a state dir that exists and cannot be read.
#
# Overrides: CLAUDE_MEMORY_STORES_ROOT (default ~/.local/share/claude-memory), CLAUDE_MEMORY_CONFIG
# (~/.dotfiles-local/claude/memory-stores.json), CLAUDE_MEMORY_STATE_DIR
# (~/.local/state/claude-memory-sync), CLAUDE_MEMORY_HOST (hostname -s, the host in a commit message, a
# conflict copy's name and the staleness threshold), CLAUDE_MEMORY_LOCK_WAIT_SECONDS (120, how long
# --apply waits for link.lock; a whole number above 0), CLAUDE_MEMORY_GH_ROUTE (the sibling
# scripts/gh-route), CLAUDE_MEMORY_RUN_DEADLINE_SECONDS (240) and CLAUDE_MEMORY_GH_ROUTE_TIMEOUT_SECONDS
# (20), whole numbers above 0 (see TIME above).

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
DOTFILES="$(cd "$(dirname "$SELF")/.." && pwd)"

SCRIPT_NAME='claude-memory-sync'
STORES_ROOT_RELATIVE='.local/share/claude-memory'
CONFIG_RELATIVE='.dotfiles-local/claude/memory-stores.json'
STATE_DIR_RELATIVE='.local/state/claude-memory-sync'
REDACTOR_RELATIVE='scripts/redact-secrets.sh'
REDACTOR_SHAPES_ONLY_FLAG='--shapes-only'
GH_ROUTE_RELATIVE='scripts/gh-route'
LINK_LOCK_FILE_NAME='link.lock'
LOCK_WAIT_SECONDS_DEFAULT=120
LOCK_WAIT_SECONDS_RE='^[1-9][0-9]*$'
# flock's status when -w runs out with the lock still held (its default conflict exit code).
FLOCK_TIMED_OUT_STATUS=1
# take_link_lock: the wait ran out.
LOCK_WAIT_RAN_OUT=2
# Every git call, through git_in_store: no hook runs, no file-system monitor starts, and the maintenance
# a call may start stays in the foreground.
GIT_SAFETY_OPTIONS=(-c core.hooksPath=/dev/null -c core.fsmonitor=false -c maintenance.autoDetach=false
    -c gc.autoDetach=false)
# A fetch or a push is cut off after this long, and killed this long after that (gh-route as well).
NETWORK_TIMEOUT_SECONDS=60
NETWORK_KILL_AFTER_SECONDS=5
# gh-route is a zsh script that sources tables and runs git: it answers in well under a second.
GH_ROUTE_TIMEOUT_SECONDS_DEFAULT=20
# No gh-route call, fetch or push starts this long after the run started, and no lock wait runs past it.
RUN_DEADLINE_SECONDS_DEFAULT=240
MIN_LOCK_WAIT_SECONDS=1
RUN_DEADLINE_DETAIL='run deadline'
WHOLE_SECONDS_RE='^[1-9][0-9]*$'
# What git leaves in its directory while each operation that a commit would conclude is unfinished.
# The pseudorefs are asked of git, since a reftable repository keeps CHERRY_PICK_HEAD and REVERT_HEAD
# in its table and not as files; the rebase states are directories in either.
UNFINISHED_OPERATION_PSEUDOREFS=(MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD)
UNFINISHED_OPERATION_DIRECTORIES=(rebase-merge rebase-apply)
declare -A OPERATION_OF_MARKER=([MERGE_HEAD]=merge [CHERRY_PICK_HEAD]=cherry-pick [REVERT_HEAD]=revert
    [rebase-merge]=rebase [rebase-apply]=rebase)
# The run deadline's clock: seconds since boot, with two decimals, as the first field.
UPTIME_FILE_DEFAULT='/proc/uptime'
UPTIME_RE='^([0-9]+)\.([0-9]{2})( |$)'
CENTISECONDS_PER_SECOND=100
# network_git_in_store's status when it refused a call with no settled route mode: none of git's or
# timeout's.
UNROUTED_NETWORK_CALL_STATUS=200
# fetch_origin and push_to_origin: the store could not run (reported), apart from a network failure.
NETWORK_STEP_COULD_NOT_RUN=2
# How a run authenticates, by gh-route's answer.
ROUTE_MODE_PINNED='pinned'
ROUTE_MODE_UNPINNED='unpinned'
ROUTE_MODE_NO_TOKEN='no-token'
# timeout's status when the time ran out, and when it then had to kill.
TIMEOUT_EXPIRED_STATUS=124
TIMEOUT_KILLED_STATUS=137
# The merge: renames off, so a rename meets an edit as a deletion and keeps both; no recorded
# resolution replayed, and nothing the host configures that would stash, sign, verify or refuse a merge
# commit. Unrelated histories are merged: a store that committed before its first fetch (two hosts that
# cloned an empty remote) would otherwise be refused on every run, and both sides' files are kept.
MERGE_CONFIG_OPTIONS=(-c merge.renames=false -c rerere.enabled=false)
MERGE_FLAGS=(--no-edit --no-gpg-sign --no-verify --no-autostash --ff --no-verify-signatures
    --allow-unrelated-histories)
# gh-route's states: an account is pinned, or no route applies and git's own helpers answer.
PINNED_ROUTE_STATES=(matched default)
UNPINNED_ROUTE_STATES=(none no-repo no-remotes)
# A pinned run gives the fetch and the push this helper alone, after clearing every configured one. It
# answers `get` only, from the token in its own environment, and fails when there is none. The variable
# name is written out here and set by network_git_in_store; single quotes, since git's shell expands it.
# shellcheck disable=SC2016
PINNED_CREDENTIAL_HELPER='!f() { [ "$1" = get ] || exit 0; [ -n "${CLAUDE_MEMORY_GIT_TOKEN:-}" ] || exit 1; echo username=x-access-token; echo "password=$CLAUDE_MEMORY_GIT_TOKEN"; }; f'
# An empty helper entry clears every helper configured before it.
CLEARED_CREDENTIAL_HELPERS='credential.helper='
# What git says when the remote turned the credential down or will not show the repository to it.
AUTH_FAILURE_ERE='Authentication failed|could not read Username|Repository not found|error: 40[13]|Permission denied \(publickey'
# What git says when the remote refused a pushed ref.
PUSH_REJECTED_ERE='\[(remote )?rejected\]'
# What git says when the merge would not start because a local file is in its way: either a list, one
# path per tab-indented line, or a single path in quotes.
MERGE_BLOCKED_ERE='would be overwritten by merge|not uptodate\. Cannot merge'
MERGE_BLOCKED_SINGLE_PATH_RE="^error: (Untracked working tree file|Entry) '(.*)' (would be overwritten by merge|not uptodate)"
# An unmerged path's stages, as a mask (stage 1 the base, 2 ours, 3 theirs): what each side did.
STAGE_MASK_DELETED_BY_THEM=3    # base and ours: git status UD
STAGE_MASK_DELETED_BY_US=5      # base and theirs: git status DU
STAGE_MASK_BOTH_ADDED=6         # ours and theirs: git status AA
STAGE_MASK_BOTH_MODIFIED=7      # all three: git status UU
STAGE_MASK_UNRESOLVABLE='unresolvable'   # anything else, or a submodule on either side
OURS_STAGE=2
THEIRS_STAGE=3
# The modes of a regular file: an index unions only these, and anything else in its place is kept
# both ways as a conflict copy.
REGULAR_FILE_MODE_RE='^100(644|755)$'
# The link script's names for an index, whose difference is a line union, and for a conflict copy.
INDEX_FILE_NAME='MEMORY.md'
TOPIC_INDEX_FILE_GLOB='INDEX_*.md'
CONFLICT_INFIX='.conflict-'
CONFLICT_COPY_NAME_GLOB="*$CONFLICT_INFIX*"
# A run holds the lock while it looks for a free conflict-copy name, so that search has an end.
MAX_CONFLICT_COPIES=100
# A markdown link's target in an index line, and a target that names no file in the store: a URL (any
# scheme), an anchor or an absolute path.
INDEX_LINK_RE='\]\(([^)]*)\)'
NOT_A_STORE_FILE_RE='^([A-Za-z][A-Za-z0-9+.-]*:|#|/)'
LAST_OK_FILE_SUFFIX='.last-ok'
STALE_AFTER_MINUTES_DEFAULT=60
STALE_AFTER_MINUTES_RE='^[1-9][0-9]*$'
SECONDS_PER_MINUTE=60
EPOCH_RE='^[0-9]+$'
STATUS_LEVEL_OK='ok'
STATUS_LEVEL_WARN='warn'
STATUS_LEVEL_BAD='bad'
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
# What stands for a path, or for git's error, that the redactor could not read: never the text itself.
UNREDACTABLE_PATH_TEXT='<a path the redactor could not read>'
UNREDACTABLE_TEXT='<an error the redactor could not read>'
# Ends a command substitution's output, so the substitution cannot strip a newline that ends a path.
OUTPUT_END_SENTINEL='.'
# One line of sha256sum's output for stdin.
STDIN_DIGEST_LINE_RE='^[0-9a-f]{64}  -$'
# `git status --porcelain=v1` puts "XY " before each path.
PORCELAIN_STATUS_PREFIX_LENGTH=3
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
LINK_LOCK_PATH="$STATE_DIR/$LINK_LOCK_FILE_NAME"
LOCK_WAIT_SECONDS="${CLAUDE_MEMORY_LOCK_WAIT_SECONDS:-$LOCK_WAIT_SECONDS_DEFAULT}"
REDACTOR="$DOTFILES/$REDACTOR_RELATIVE"
GH_ROUTE="${CLAUDE_MEMORY_GH_ROUTE:-$DOTFILES/$GH_ROUTE_RELATIVE}"
GH_ROUTE_TIMEOUT_SECONDS="${CLAUDE_MEMORY_GH_ROUTE_TIMEOUT_SECONDS:-$GH_ROUTE_TIMEOUT_SECONDS_DEFAULT}"
RUN_DEADLINE_SECONDS="${CLAUDE_MEMORY_RUN_DEADLINE_SECONDS:-$RUN_DEADLINE_SECONDS_DEFAULT}"
UPTIME_FILE="${CLAUDE_MEMORY_UPTIME_FILE:-$UPTIME_FILE_DEFAULT}"

MODE=''                         # check | scan | apply | status
ONLY_STORE=''                   # --store
SCAN_REVISION=''                # --scan --rev
HOST_NAME=''                    # the host in a commit message and a conflict copy, set by settle_host_name
STALE_AFTER_MINUTES=''          # --status: this host's threshold, set by settle_stale_after_minutes
STORE_NAMES=()                  # every store the table names, sorted
declare -A REMOTE_OF_STORE=()   # store → the table's remote
FAILED_STORES=()                # stores that could not run, reported at the end
NEEDS_ATTENTION=0               # --check or --scan found something
LINK_LOCK_FD=''                 # the open descriptor of link.lock while it is held
LOCK_WAIT_THIS_STORE=''         # the lock wait, cut to the run deadline, set by settle_lock_wait
RUN_STARTED_CENTISECONDS=''     # the uptime when main began, in hundredths: the run deadline counts from it
STORE_IS_PAST_DEADLINE=0        # decided once per store, before its first network step
LAST_OK_FAILURE_DETAIL=''       # why last-ok could not be written, for the status detail
GIT_RUNNER_PREFIX=()            # what runs git: empty, or timeout for a network call
STORE_HAS_ORIGIN=0              # what check_origin found
CURRENT_BRANCH=''               # the branch HEAD names, set by refuse_unfinished_operation
WITHHELD_REDACTED_PATHS=()      # what gate_staged_paths held back, each with its shapes redacted
COMMITTED_COUNT=0               # how many paths commit_staged_paths committed
ROUTE_MODE=''                   # a ROUTE_MODE_* set by resolve_route; empty past the run deadline
ROUTED_TOKEN=''                 # the pinned account's token: never printed, written or put in an argument
ROUTED_GH_CONFIG_DIR=''         # the pinned account's gh config dir
NO_TOKEN_DETAIL=''              # why a pinned route has no token
NETWORK_OUTCOME=''              # a fetch or push that failed: its outcome
NETWORK_DETAIL=''               # and why, redacted
MERGED_FROM_ORIGIN=0            # integrate_origin merged origin in
INTEGRATION_OUTCOME=''          # integrate_origin: blocked, kept-both, or nothing
INTEGRATION_DETAIL=''           # and the detail of blocked
KEPT_BOTH_COUNT=0               # how many conflicted paths the merge resolved
PUSHED=0                        # push_to_origin sent something
STATUS_OUTCOME=''               # --status: the outcome in the store's status file, set by read_status_file
STATUS_DETAIL=''                # and its detail

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
            --check)  set_mode check ;;
            --scan)   set_mode scan ;;
            --apply)  set_mode apply ;;
            --status) set_mode status ;;
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

# git_in_store STORE_DIR ARGS… — git, in the store, with GIT_SAFETY_OPTIONS on every call, run by
# GIT_RUNNER_PREFIX when a caller sets one. While this run holds link.lock, the lock's descriptor is
# closed in git's own process and this shell keeps it: nothing git starts can then hold the lock past the
# end of the run.
git_in_store() {
    local store_dir=$1
    shift
    if [[ -n "$LINK_LOCK_FD" ]]; then
        "${GIT_RUNNER_PREFIX[@]}" git -C "$store_dir" "${GIT_SAFETY_OPTIONS[@]}" "$@" {LINK_LOCK_FD}>&-
    else
        "${GIT_RUNNER_PREFIX[@]}" git -C "$store_dir" "${GIT_SAFETY_OPTIONS[@]}" "$@"
    fi
}

# network_git_in_store STORE_DIR ARGS… — git_in_store for a call that reaches the remote: cut off after
# NETWORK_TIMEOUT_SECONDS, in the C locale (its errors are read), with no prompt and no askpass program,
# and with any trace git writes redacted (main has unset the trace variables already; this is a second
# switch, for one a later git reads).
# When the route pinned an account, the token and the account's config dir are in this one git
# process's environment, and every configured credential helper is cleared for the one that reads it.
# The token is never in an argument. Only a route that said unpinned runs with git's own helpers: any
# other mode, an empty one included, is refused (UNROUTED_NETWORK_CALL_STATUS, having said so), since
# falling back to the host's helpers for a store gh-route would have pinned is a push as the wrong account.
network_git_in_store() {
    local store_dir=$1 shown_route_mode
    shift
    # Read by git_in_store, which this call reaches: bash scopes a local to the calls it makes.
    # shellcheck disable=SC2034
    local GIT_RUNNER_PREFIX=(timeout --kill-after="$NETWORK_KILL_AFTER_SECONDS" "$NETWORK_TIMEOUT_SECONDS")
    case "$ROUTE_MODE" in
        "$ROUTE_MODE_PINNED")
            CLAUDE_MEMORY_GIT_TOKEN=$ROUTED_TOKEN GH_CONFIG_DIR=$ROUTED_GH_CONFIG_DIR \
                LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' GIT_TRACE_REDACT=1 \
                git_in_store "$store_dir" -c "$CLEARED_CREDENTIAL_HELPERS" \
                    -c "credential.helper=$PINNED_CREDENTIAL_HELPER" "$@" ;;
        "$ROUTE_MODE_UNPINNED")
            LC_ALL=C GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' GIT_TRACE_REDACT=1 git_in_store "$store_dir" "$@" ;;
        *)
            shown_route_mode=$(escaped_for_one_line "$ROUTE_MODE")
            printf "%s: refusing a network call: the route mode is '%s'\n" "$SCRIPT_NAME" "$shown_route_mode" >&2
            return "$UNROUTED_NETWORK_CALL_STATUS" ;;
    esac
}

# stderr_redacted COMMAND… — COMMAND, with what it says on stderr passed through the redactor's shape
# rules: a warning that names a path can carry a credential as well as a body can.
stderr_redacted() {
    "$@" 2> >("$REDACTOR" "$REDACTOR_SHAPES_ONLY_FLAG" >&2)
}

# redacted_text TEXT — TEXT through the full redactor, its final newline dropped; UNREDACTABLE_TEXT when
# the redactor fails, never TEXT itself.
redacted_text() {
    local redacted_output
    if ! redacted_output=$(printf '%s\n' "$1" | "$REDACTOR"); then
        printf '%s' "$UNREDACTABLE_TEXT"
        return 0
    fi
    printf '%s' "$redacted_output"
}

# redact_path_into VARIABLE PATH — set VARIABLE to PATH with each credential shape the redactor finds
# replaced by its marker: a name can carry a credential as well as a body can. A path the redactor
# cannot read becomes UNREDACTABLE_PATH_TEXT, never itself.
# shellcheck disable=SC2034  # redacted_path_target is a nameref: assigning it sets the caller's variable
redact_path_into() {
    local -n redacted_path_target="$1"
    local path=$2 redacted_output
    # The newline printf adds lets sed read the last line whole, and is taken off again; the sentinel
    # keeps the command substitution from stripping a newline the path itself ends with.
    if ! redacted_output=$(printf '%s\n' "$path" | "$REDACTOR" "$REDACTOR_SHAPES_ONLY_FLAG" \
        && printf '%s' "$OUTPUT_END_SENTINEL"); then
        redacted_path_target=$UNREDACTABLE_PATH_TEXT
        return 0
    fi
    redacted_output=${redacted_output%"$OUTPUT_END_SENTINEL"}
    redacted_path_target=${redacted_output%$'\n'}
}

# printable_path PATH — PATH as a line of output shows it: redacted, then kept on one line.
printable_path() {
    local redacted_path
    redact_path_into redacted_path "$1"
    escaped_for_one_line "$redacted_path"
}

# What is wrong with the shape of the table, or nothing. Only what this script reads is checked.
# shellcheck disable=SC2016  # jq's own $variables, not the shell's
JQ_TABLE_PROBLEM='
def is_usable_remote: type == "string" and . != "" and (test("[[:cntrl:]]") | not);
def is_whole_minutes: type == "number" and . > 0 and . == floor;
if (.stores | type) != "object" then ".stores is not an object"
elif any(.stores | keys[]; test($store_name_re) | not) then "a name in .stores is not a plain name"
elif any(.stores[]; if type == "object" then .remote | is_usable_remote | not else true end)
    then "a store has no remote"
elif has("stale_after_minutes") and ((.stale_after_minutes | type) != "object"
    or any(.stale_after_minutes[]; is_whole_minutes | not))
    then "stale_after_minutes is not an object of whole minutes above 0"
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
# record could-not-run as its status. --check and --scan write nothing. --status instead prints a bad
# line naming the reason and does not count the store: a store it cannot read is a finding about that
# store, and its exit 2 is kept for a run that could read nothing.
report_store_failure() {
    local store=$1 reason=$2
    if [[ "$MODE" == status ]]; then
        print_status_line "$store" "$STATUS_LEVEL_BAD" "$(redacted_text "$reason")"
        return 0
    fi
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
    git_errors=$(git_in_store "$store_dir" "$@" 2>&1 >/dev/null)
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
    fetch_urls=$(git_in_store "$store_dir" remote get-url --all "$ORIGIN_REMOTE_NAME" 2>/dev/null)
    get_url_status=$?
    if (( get_url_status == GIT_EXIT_NO_SUCH_REMOTE )); then return 0; fi
    if (( get_url_status != 0 )); then
        report_store_failure "$store" "git could not read the origin (exit $get_url_status)"
        return 1
    fi
    if ! push_urls=$(git_in_store "$store_dir" remote get-url --push --all "$ORIGIN_REMOTE_NAME" 2>/dev/null); then
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
    git_in_store "$1" symbolic-ref -q HEAD >/dev/null && ! git_in_store "$1" rev-parse -q --verify HEAD >/dev/null
}

# base_tree_of STORE_DIR — print the tree a commit would change: HEAD's, or the empty tree when HEAD
# has no commit yet.
base_tree_of() {
    if head_is_unborn "$1"; then
        git_in_store "$1" hash-object -t tree --stdin < /dev/null
    else
        git_in_store "$1" rev-parse -q --verify 'HEAD^{tree}'
    fi
}

# content_has_credential_shape COMMAND… — status 0 when the redactor's shape rules change what COMMAND
# prints, 1 when they do not, 2 when it could not be read or filtered. COMMAND runs once, so a file a
# session writes to cannot read one way for the digest of the content and another for the digest of
# its redaction. Compared by digest, so the content is never held in a variable.
content_has_credential_shape() {
    local digests_text digest_lines=()
    # tee hands the one read to a digest of its own, written to fd 3, while the redactor's output is
    # digested on stdout; both land in the substitution. The two lines arrive in either order, which an
    # equality test does not mind; anything but two digest lines is a failure.
    digests_text=$( { "$@" | tee >(sha256sum >&3) | "$REDACTOR" "$REDACTOR_SHAPES_ONLY_FLAG" | sha256sum; } 3>&1 ) \
        || return "$SHAPE_CHECK_FAILED"
    mapfile -t digest_lines <<< "$digests_text"
    if (( ${#digest_lines[@]} != 2 )) || [[ ! "${digest_lines[0]}" =~ $STDIN_DIGEST_LINE_RE ]] \
        || [[ ! "${digest_lines[1]}" =~ $STDIN_DIGEST_LINE_RE ]]; then
        return "$SHAPE_CHECK_FAILED"
    fi
    [[ "${digest_lines[0]}" != "${digest_lines[1]}" ]]
}

# print_name_then_content PATH [COMMAND…] — PATH on a line of its own, then what COMMAND prints (no
# COMMAND: the name alone), so one shape check and one set of labels cover a file's name and body. The
# redactor reads line by line, so no shape spans the two.
print_name_then_content() {
    printf '%s\n' "$1"
    shift
    if (( $# )); then "$@"; fi
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
# memory file that quotes a marker does not name a shape it lacks. Labels only, never a line. COMMAND
# runs again here, after the verdict: a write in between can change a label, never the verdict.
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

# print_withheld_line STORE PATH LABELS — the line that names a withheld file, its name redacted.
print_withheld_line() {
    local shown_path
    shown_path=$(printable_path "$2")
    printf '%s: withheld %s (%s)\n' "$1" "$shown_path" "$3"
}

# print_link_target PATH — what git stores for a symlink: its target, with no newline. What readlink
# says on a failure names the path, which can carry a credential, so it is dropped: the caller names
# the path, redacted.
print_link_target() {
    local link_target
    link_target=$(readlink -- "$1" 2>/dev/null) || return 1
    printf '%s' "$link_target"
}

# print_file_content PATH — the file's bytes. What cat says on a failure names the path, so it is
# dropped, as in print_link_target.
print_file_content() {
    cat -- "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------------------------
# --apply: stage, gate and commit, holding the link script's lock.
# ---------------------------------------------------------------------------------------------

# read_uptime_centiseconds VARIABLE — set VARIABLE to the seconds since boot, in hundredths, from
# UPTIME_FILE: a clock that only moves forward, whatever the wall clock does. Returns 1 when it cannot be
# read.
# shellcheck disable=SC2034  # uptime_target is a nameref: assigning it sets the caller's variable
read_uptime_centiseconds() {
    local -n uptime_target="$1"
    local uptime_line=''
    # A file with no final newline still yields its line; the pattern decides.
    { IFS= read -r uptime_line < "$UPTIME_FILE"; } 2>/dev/null
    [[ "$uptime_line" =~ $UPTIME_RE ]] || return 1
    uptime_target=$(( 10#${BASH_REMATCH[1]} * CENTISECONDS_PER_SECOND + 10#${BASH_REMATCH[2]} ))
}

# centiseconds_until_run_deadline — how many hundredths of a second are left before the run deadline:
# 0 or less once it has passed, and 0 when the clock cannot be read, since no time is then left that
# this script can vouch for.
centiseconds_until_run_deadline() {
    local now_centiseconds
    if ! read_uptime_centiseconds now_centiseconds; then
        printf '0'
        return 0
    fi
    printf '%s' $(( RUN_STARTED_CENTISECONDS + RUN_DEADLINE_SECONDS * CENTISECONDS_PER_SECOND - now_centiseconds ))
}

# run_deadline_has_passed — status 0 once RUN_DEADLINE_SECONDS have passed since the run started.
run_deadline_has_passed() {
    (( $(centiseconds_until_run_deadline) <= 0 ))
}

# settle_lock_wait — LOCK_WAIT_THIS_STORE: LOCK_WAIT_SECONDS, cut to the whole seconds left before the
# run deadline, and never under MIN_LOCK_WAIT_SECONDS.
settle_lock_wait() {
    local seconds_left
    seconds_left=$(( $(centiseconds_until_run_deadline) / CENTISECONDS_PER_SECOND ))
    LOCK_WAIT_THIS_STORE=$LOCK_WAIT_SECONDS
    if (( seconds_left < LOCK_WAIT_THIS_STORE )); then LOCK_WAIT_THIS_STORE=$seconds_left; fi
    if (( LOCK_WAIT_THIS_STORE < MIN_LOCK_WAIT_SECONDS )); then LOCK_WAIT_THIS_STORE=$MIN_LOCK_WAIT_SECONDS; fi
}

# take_link_lock — wait LOCK_WAIT_THIS_STORE at most for <state dir>/link.lock, the link script's lock,
# and hold it in LINK_LOCK_FD. Returns LOCK_WAIT_RAN_OUT when another run still held it at the end of
# the wait, 1 when it could not be opened or locked.
take_link_lock() {
    local flock_status
    settle_lock_wait
    mkdir -p -- "$STATE_DIR" || return 1
    exec {LINK_LOCK_FD}>> "$LINK_LOCK_PATH" || return 1
    flock -w "$LOCK_WAIT_THIS_STORE" "$LINK_LOCK_FD"
    flock_status=$?
    (( flock_status != 0 )) || return 0
    release_link_lock
    if (( flock_status == FLOCK_TIMED_OUT_STATUS )); then return "$LOCK_WAIT_RAN_OUT"; fi
    return 1
}

# release_link_lock — close the lock's descriptor, which lets go of the lock.
release_link_lock() {
    exec {LINK_LOCK_FD}>&-
    LINK_LOCK_FD=''
}

# gate_staged_paths STORE STORE_DIR BASE_TREE — unstage each staged path whose name or blob carries a
# credential shape, naming it and recording it, redacted, in WITHHELD_REDACTED_PATHS. Returns 1,
# having reported the store, when a blob could not be read or a path could not be unstaged.
gate_staged_paths() {
    local store=$1 store_dir=$2 base_tree=$3 raw_items=() index metadata path blob_mode blob_id labels
    local shape_status redacted_path name_and_content_command=()
    WITHHELD_REDACTED_PATHS=()
    if ! read_nul_items raw_items git_in_store "$store_dir" diff-index --cached --raw -z --no-abbrev \
        --no-renames --diff-filter=d "$base_tree" --; then
        report_store_failure "$store" "git could not list the staged files"
        return 1
    fi
    # Raw items come in pairs: ":<old mode> <new mode> <old id> <new id> <status>", then the path.
    for (( index = 0; index + 1 < ${#raw_items[@]}; index += 2 )); do
        metadata=${raw_items[index]}
        path=${raw_items[index + 1]}
        read -r _ blob_mode _ blob_id _ <<< "$metadata"
        # A submodule's entry is a commit id with no blob to read: its name is all there is to gate.
        name_and_content_command=(print_name_then_content "$path")
        if [[ "$blob_mode" != "$GITLINK_MODE" ]]; then
            name_and_content_command+=(git_in_store "$store_dir" cat-file blob "$blob_id")
        fi
        content_has_credential_shape "${name_and_content_command[@]}"
        shape_status=$?
        (( shape_status != 1 )) || continue
        if (( shape_status != 0 )); then
            report_store_failure "$store" "could not read the staged $(printable_path "$path")"
            return 1
        fi
        labels=$(shape_labels_of "${name_and_content_command[@]}")
        if ! run_git_reporting_errors "$store_dir" --literal-pathspecs reset -q -- "$path"; then
            report_store_failure "$store" "could not unstage the withheld $(printable_path "$path")"
            return 1
        fi
        redact_path_into redacted_path "$path"
        WITHHELD_REDACTED_PATHS+=("$redacted_path")
        print_withheld_line "$store" "$path" "$labels"
    done
}

# commit_staged_paths STORE STORE_DIR BASE_TREE — commit what is staged as `<host>: <n> files`, and set
# COMMITTED_COUNT; nothing staged is no commit. Returns 1, having reported the store, on a failure.
commit_staged_paths() {
    local store=$1 store_dir=$2 base_tree=$3 staged_paths=() commit_message
    COMMITTED_COUNT=0
    if ! read_nul_items staged_paths git_in_store "$store_dir" diff-index --cached --name-only -z \
        --no-renames "$base_tree" --; then
        report_store_failure "$store" "git could not count the staged files"
        return 1
    fi
    (( ${#staged_paths[@]} )) || return 0
    commit_message="$HOST_NAME: ${#staged_paths[@]} files"
    if ! run_git_reporting_errors "$store_dir" commit -q --no-verify --no-gpg-sign -m "$commit_message"; then
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

# ---------------------------------------------------------------------------------------------
# --apply: the route, the unfinished-operation refusal, fetch, merge and push.
# ---------------------------------------------------------------------------------------------

# is_one_of WORD CANDIDATE… — status 0 when WORD is one of the candidates.
is_one_of() {
    local word=$1 candidate
    shift
    for candidate in "$@"; do
        if [[ "$word" == "$candidate" ]]; then return 0; fi
    done
    return 1
}

# route_fields_of ROUTE_JSON — gh-route's state, dir and token_file, each ended by a NUL; fails on any
# other shape.
route_fields_of() {
    printf '%s' "$1" | jq -j 'if type == "object" and (.state | type) == "string"
        and (.dir | type) == "string" and (.token_file | type) == "string"
        then .state, "\u0000", .dir, "\u0000", .token_file, "\u0000" else error("not a route") end' 2>/dev/null
}

# resolve_route STORE STORE_DIR — ask gh-route which account the store's directory routes to, before any
# git call, and set ROUTE_MODE: pinned (the token read into ROUTED_TOKEN, the config dir into
# ROUTED_GH_CONFIG_DIR), unpinned, or no-token (NO_TOKEN_DETAIL says why). gh-route's own errors pass
# through the redactor. gh-route gets GH_ROUTE_TIMEOUT_SECONDS. Returns 1, having reported the store,
# when gh-route could not answer, did not answer in time, or gave an answer this script does not know.
resolve_route() {
    local store=$1 store_dir=$2 route_json route_status route_fields=() state config_dir token_file
    local shown_token_file
    ROUTE_MODE='' ROUTED_TOKEN='' ROUTED_GH_CONFIG_DIR='' NO_TOKEN_DETAIL=''
    route_json=$(stderr_redacted timeout --kill-after="$NETWORK_KILL_AFTER_SECONDS" "$GH_ROUTE_TIMEOUT_SECONDS" \
        "$GH_ROUTE" "$store_dir")
    route_status=$?
    if (( route_status == TIMEOUT_EXPIRED_STATUS || route_status == TIMEOUT_KILLED_STATUS )); then
        report_store_failure "$store" "gh-route did not answer within $GH_ROUTE_TIMEOUT_SECONDS s"
        return 1
    elif (( route_status != 0 )); then
        report_store_failure "$store" "gh-route could not answer for the store"
        return 1
    fi
    if ! read_nul_items route_fields route_fields_of "$route_json" || (( ${#route_fields[@]} != 3 )); then
        report_store_failure "$store" "gh-route gave an answer that is not a route"
        return 1
    fi
    state=${route_fields[0]} config_dir=${route_fields[1]} token_file=${route_fields[2]}
    if is_one_of "$state" "${UNPINNED_ROUTE_STATES[@]}"; then
        ROUTE_MODE=$ROUTE_MODE_UNPINNED
        return 0
    fi
    if ! is_one_of "$state" "${PINNED_ROUTE_STATES[@]}" || [[ -z "$config_dir" ]]; then
        report_store_failure "$store" "gh-route answered a state this script does not know: $(escaped_for_one_line "$state")"
        return 1
    fi
    ROUTED_GH_CONFIG_DIR=$config_dir
    # The shell reads the same file the same way: its whole body, less the final newlines.
    if [[ -n "$token_file" && -f "$token_file" && -r "$token_file" ]]; then
        ROUTED_TOKEN=$(< "$token_file")
    fi
    if [[ -n "$ROUTED_TOKEN" ]]; then
        ROUTE_MODE=$ROUTE_MODE_PINNED
        return 0
    fi
    ROUTE_MODE=$ROUTE_MODE_NO_TOKEN
    shown_token_file=$(printable_path "${token_file:-<none>}")
    NO_TOKEN_DETAIL="the token file $shown_token_file is missing, empty or unreadable"
}

# refuse_unfinished_operation STORE STORE_DIR — set CURRENT_BRANCH. Returns 1, having reported the store,
# when a merge, a cherry-pick, a revert or a rebase is in progress, the index holds unmerged entries, or
# HEAD is detached: a stage would then take conflict markers, a commit would conclude the operation with
# whatever the tree holds, or land on no branch. It never resets anything; a person finishes or aborts it.
refuse_unfinished_operation() {
    local store=$1 store_dir=$2 marker marker_path unmerged_entries branch_status
    CURRENT_BRANCH=''
    for marker in "${UNFINISHED_OPERATION_PSEUDOREFS[@]}"; do
        git_in_store "$store_dir" rev-parse -q --verify "$marker" >/dev/null || continue
        report_store_failure "$store" "a ${OPERATION_OF_MARKER[$marker]} is in progress: conclude or abort it by hand"
        return 1
    done
    for marker in "${UNFINISHED_OPERATION_DIRECTORIES[@]}"; do
        if ! marker_path=$(git_in_store "$store_dir" rev-parse --path-format=absolute --git-path "$marker"); then
            report_store_failure "$store" "git could not find its own directory"
            return 1
        fi
        [[ -e "$marker_path" ]] || continue
        report_store_failure "$store" "a ${OPERATION_OF_MARKER[$marker]} is in progress: conclude or abort it by hand"
        return 1
    done
    if ! unmerged_entries=$(git_in_store "$store_dir" ls-files -u); then
        report_store_failure "$store" "git could not list the index's unmerged entries"
        return 1
    fi
    if [[ -n "$unmerged_entries" ]]; then
        report_store_failure "$store" "the index holds unmerged entries: resolve them by hand"
        return 1
    fi
    CURRENT_BRANCH=$(git_in_store "$store_dir" symbolic-ref -q --short HEAD)
    branch_status=$?
    (( branch_status != 0 )) || return 0
    if (( branch_status == 1 )); then
        report_store_failure "$store" "HEAD is detached: check out the store's branch by hand"
    else
        report_store_failure "$store" "git could not read HEAD"
    fi
    return 1
}

# record_network_failure GIT_STATUS GIT_ERRORS OTHERWISE — set NETWORK_OUTCOME and NETWORK_DETAIL for a
# fetch or push that failed: unreachable when it ran out of time, auth-failed when its error names an
# auth or a not-found failure, OTHERWISE for anything else. The detail is git's error, redacted.
record_network_failure() {
    local git_status=$1 git_errors=$2 otherwise=$3
    if (( git_status == TIMEOUT_EXPIRED_STATUS || git_status == TIMEOUT_KILLED_STATUS )); then
        NETWORK_OUTCOME=$OUTCOME_UNREACHABLE
        NETWORK_DETAIL="no answer within $NETWORK_TIMEOUT_SECONDS s"
        return 0
    fi
    NETWORK_OUTCOME=$otherwise
    if [[ "$git_errors" =~ $AUTH_FAILURE_ERE ]]; then NETWORK_OUTCOME=$OUTCOME_AUTH_FAILED; fi
    NETWORK_DETAIL=$(redacted_text "$git_errors")
}

# report_unrouted_network_call STORE STEP — the store could not run: network_git_in_store refused its
# STEP for want of a settled route mode.
report_unrouted_network_call() {
    local shown_route_mode
    shown_route_mode=$(escaped_for_one_line "$ROUTE_MODE")
    report_store_failure "$1" "refused the $2: no route was settled for it (route mode '$shown_route_mode')"
}

# fetch_origin STORE STORE_DIR — fetch the store's origin. Returns 1 with NETWORK_OUTCOME and
# NETWORK_DETAIL set when it failed, and NETWORK_STEP_COULD_NOT_RUN, having reported the store, when the
# call was refused for want of a route.
fetch_origin() {
    local store=$1 store_dir=$2 fetch_errors fetch_status
    fetch_errors=$(network_git_in_store "$store_dir" fetch --quiet --no-recurse-submodules \
        "$ORIGIN_REMOTE_NAME" 2>&1 >/dev/null)
    fetch_status=$?
    (( fetch_status != 0 )) || return 0
    if (( fetch_status == UNROUTED_NETWORK_CALL_STATUS )); then
        report_unrouted_network_call "$store" fetch
        return "$NETWORK_STEP_COULD_NOT_RUN"
    fi
    record_network_failure "$fetch_status" "$fetch_errors" "$OUTCOME_UNREACHABLE"
    return 1
}

# merge_is_in_progress STORE_DIR — status 0 while MERGE_HEAD exists.
merge_is_in_progress() {
    git_in_store "$1" rev-parse -q --verify MERGE_HEAD >/dev/null
}

# blocking_paths_of MERGE_OUTPUT — the paths git named as in the merge's way, redacted, joined by ", ".
blocking_paths_of() {
    local line blocking_path joined_paths=''
    while IFS= read -r line; do
        blocking_path=''
        if [[ "$line" == $'\t'* ]]; then
            blocking_path=${line#$'\t'}
        elif [[ "$line" =~ $MERGE_BLOCKED_SINGLE_PATH_RE ]]; then
            blocking_path=${BASH_REMATCH[2]}
        fi
        [[ -n "$blocking_path" ]] || continue
        joined_paths+="${joined_paths:+, }$(printable_path "$blocking_path")"
    done <<< "$1"
    printf '%s' "$joined_paths"
}

# index_entry_of STORE_DIR PATH — PATH's stage-0 entry in the index, `<mode> <id>`, or nothing.
index_entry_of() {
    local index_line index_mode index_id index_stage
    index_line=$(git_in_store "$1" --literal-pathspecs ls-files -s -- "$2") || return 1
    [[ -n "$index_line" ]] || return 0
    read -r index_mode index_id index_stage _ <<< "$index_line"
    if [[ "$index_stage" == 0 ]]; then printf '%s %s' "$index_mode" "$index_id"; fi
}

# set_index_entry STORE_DIR MODE ID PATH — PATH in the index, at stage 0, as the blob ID: the merge's
# higher stages for it go. Staged from the blob and never from the tree, which a session may be writing.
set_index_entry() {
    run_git_reporting_errors "$1" update-index --add --cacheinfo "$2,$3,$4"
}

# write_conflict_copy STORE_DIR PATH MODE ID — put the blob ID beside PATH under the first conflict-copy
# name that is free (M4), in the index and in the tree: x.md -> x.conflict-<host>.md, no extension:
# appended, then .conflict-<host>.2, .3, … A name whose index entry already is that blob is that copy,
# and nothing is written. A name anything else holds, in the tree or the index, is passed over: git's
# checkout-index will not write over a file. Returns 1, having said why, when it could not.
write_conflict_copy() {
    local store_dir=$1 path=$2 mode=$3 object_id=$4 parent='' name=$2 name_stem final_extension=''
    local ordinal=1 infix copy_path existing_entry
    if [[ "$path" == */* ]]; then parent="${path%/*}/" name=${path##*/}; fi
    name_stem=$name
    # .hidden and trailing. have no extension: the infix goes after the whole name.
    if [[ "$name" == ?*.?* ]]; then
        name_stem=${name%.*}
        final_extension=".${name##*.}"
    fi
    while (( ordinal <= MAX_CONFLICT_COPIES )); do
        infix="$CONFLICT_INFIX$HOST_NAME"
        (( ordinal == 1 )) || infix+=".$ordinal"
        copy_path="$parent$name_stem$infix$final_extension"
        ordinal=$(( ordinal + 1 ))
        existing_entry=$(index_entry_of "$store_dir" "$copy_path") || return 1
        if [[ "$existing_entry" == "$mode $object_id" ]]; then return 0; fi
        if [[ -n "$existing_entry" || -e "$store_dir/$copy_path" || -L "$store_dir/$copy_path" ]]; then continue; fi
        if [[ -n "$(git_in_store "$store_dir" --literal-pathspecs ls-files -u -- "$copy_path")" ]]; then continue; fi
        set_index_entry "$store_dir" "$mode" "$object_id" "$copy_path" || return 1
        if git_in_store "$store_dir" checkout-index -- "$copy_path" 2>/dev/null; then return 0; fi
        # Something took the name between the look and the write: it stays, and the entry goes.
        run_git_reporting_errors "$store_dir" update-index --force-remove -- "$copy_path" || return 1
        if [[ ! -e "$store_dir/$copy_path" && ! -L "$store_dir/$copy_path" ]]; then
            printf '%s: could not write the conflict copy %s\n' "$SCRIPT_NAME" "$(printable_path "$copy_path")" >&2
            return 1
        fi
    done
    printf '%s: gave up on a conflict copy of %s: %d names are taken\n' "$SCRIPT_NAME" \
        "$(printable_path "$path")" "$MAX_CONFLICT_COPIES" >&2
    return 1
}

# union_index_blob STORE_DIR THEIRS_ID OURS_ID — write to the object database the remote's index, then
# each line only ours has, in our order and once each, and print the new blob's id. The link script's
# union: the remote's copy keeps its lines and their order.
union_index_blob() {
    local store_dir=$1 theirs_id=$2 ours_id=$3 line union_text=''
    local -A seen_lines=()
    # The keys are prefixed because an associative array can refuse an empty subscript, depending on the
    # bash, and a blank line is one.
    while IFS= read -r line || [[ -n "$line" ]]; do
        seen_lines["line:$line"]=1
        union_text+="$line"$'\n'
    done < <(git_in_store "$store_dir" cat-file blob "$theirs_id")
    wait "$!" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${seen_lines["line:$line"]:-}" ]] || continue
        seen_lines["line:$line"]=1
        union_text+="$line"$'\n'
    done < <(git_in_store "$store_dir" cat-file blob "$ours_id")
    wait "$!" || return 1
    printf '%s' "$union_text" | git_in_store "$store_dir" hash-object -w --no-filters --stdin
}

# is_index_file_name NAME — true for a file whose difference is a line union, not a conflict copy.
is_index_file_name() {
    # shellcheck disable=SC2053  # the glob on the right is the point
    [[ "$1" == "$INDEX_FILE_NAME" || "$1" == $TOPIC_INDEX_FILE_GLOB ]]
}

# take_theirs_at STORE_DIR MODE ID PATH — the remote's blob takes PATH, in the index and in the tree,
# where the merge left its conflict markers.
take_theirs_at() {
    set_index_entry "$1" "$2" "$3" "$4" || return 1
    run_git_reporting_errors "$1" checkout-index -f -- "$4"
}

# resolve_conflicts STORE STORE_DIR — resolve every unmerged path the merge left, by what each side did
# (see the header), counting them in KEPT_BOTH_COUNT. Every path is checked before any is touched, so a
# status the sync does not resolve leaves the merge as git left it. Returns 1, having reported the
# store, when it could not; the caller aborts the merge.
resolve_conflicts() {
    local store=$1 store_dir=$2 unmerged_items=() item metadata path mode object_id stage index position
    local unmerged_paths=() stage_masks=() ours_modes=() ours_ids=() theirs_modes=() theirs_ids=()
    local -A position_of_path=()
    local stage_mask union_id
    KEPT_BOTH_COUNT=0
    if ! read_nul_items unmerged_items git_in_store "$store_dir" ls-files -u -z; then
        report_store_failure "$store" "git could not list the conflicts of the merge"
        return 1
    fi
    # Each item: "<mode> <id> <stage>", a tab, then the path; a path has one item per stage it holds.
    for item in "${unmerged_items[@]}"; do
        metadata=${item%%$'\t'*}
        path=${item#*$'\t'}
        read -r mode object_id stage <<< "$metadata"
        position=${position_of_path["$path"]-}
        if [[ -z "$position" ]]; then
            position=${#unmerged_paths[@]}
            position_of_path["$path"]=$position
            unmerged_paths+=("$path")
            stage_masks+=(0)
        fi
        stage_masks[position]=$(( stage_masks[position] | (1 << (stage - 1)) ))
        if [[ "$stage" == "$OURS_STAGE" ]]; then ours_modes[position]=$mode ours_ids[position]=$object_id; fi
        if [[ "$stage" == "$THEIRS_STAGE" ]]; then theirs_modes[position]=$mode theirs_ids[position]=$object_id; fi
    done
    for (( index = 0; index < ${#unmerged_paths[@]}; index++ )); do
        stage_mask=${stage_masks[index]}
        case "$stage_mask" in
            "$STAGE_MASK_BOTH_MODIFIED"|"$STAGE_MASK_BOTH_ADDED")
                if [[ "${ours_modes[index]}" == "$GITLINK_MODE" || "${theirs_modes[index]}" == "$GITLINK_MODE" ]]; then
                    stage_mask=$STAGE_MASK_UNRESOLVABLE
                fi ;;
            "$STAGE_MASK_DELETED_BY_US"|"$STAGE_MASK_DELETED_BY_THEM") ;;
            *) stage_mask=$STAGE_MASK_UNRESOLVABLE ;;
        esac
        if [[ "$stage_mask" == "$STAGE_MASK_UNRESOLVABLE" ]]; then
            report_store_failure "$store" "a conflict the sync does not resolve, at $(printable_path "${unmerged_paths[index]}")"
            return 1
        fi
    done
    for (( index = 0; index < ${#unmerged_paths[@]}; index++ )); do
        path=${unmerged_paths[index]}
        case "${stage_masks[index]}" in
            "$STAGE_MASK_DELETED_BY_US")
                # Deleted here, changed there: theirs is what the merge left in the tree.
                set_index_entry "$store_dir" "${theirs_modes[index]}" "${theirs_ids[index]}" "$path" || break ;;
            "$STAGE_MASK_DELETED_BY_THEM")
                # Changed here, deleted there: ours is what the merge left in the tree.
                set_index_entry "$store_dir" "${ours_modes[index]}" "${ours_ids[index]}" "$path" || break ;;
            *)
                if is_index_file_name "${path##*/}" && [[ "${ours_modes[index]}" =~ $REGULAR_FILE_MODE_RE \
                    && "${theirs_modes[index]}" =~ $REGULAR_FILE_MODE_RE ]]; then
                    union_id=$(union_index_blob "$store_dir" "${theirs_ids[index]}" "${ours_ids[index]}") || break
                    take_theirs_at "$store_dir" "${theirs_modes[index]}" "$union_id" "$path" || break
                else
                    write_conflict_copy "$store_dir" "$path" "${ours_modes[index]}" "${ours_ids[index]}" || break
                    take_theirs_at "$store_dir" "${theirs_modes[index]}" "${theirs_ids[index]}" "$path" || break
                fi ;;
        esac
        KEPT_BOTH_COUNT=$(( KEPT_BOTH_COUNT + 1 ))
    done
    if (( KEPT_BOTH_COUNT != ${#unmerged_paths[@]} )); then
        report_store_failure "$store" "could not resolve the conflict at $(printable_path "$path")"
        return 1
    fi
}

# abort_merge STORE STORE_DIR — `git merge --abort`, so that no run leaves MERGE_HEAD behind. The store
# has already been reported; this says only when the abort itself failed.
abort_merge() {
    run_git_reporting_errors "$2" merge --abort && return 0
    printf '%s: %s: git merge --abort failed: a merge is left in progress\n' "$SCRIPT_NAME" "$1" >&2
}

# integrate_origin STORE STORE_DIR — merge the fetched origin branch into HEAD, unless HEAD already holds
# it. Sets MERGED_FROM_ORIGIN, INTEGRATION_OUTCOME (blocked or kept-both, or nothing for a clean merge)
# and INTEGRATION_DETAIL. Returns 1, having reported the store and aborted any merge it started, when it
# could not.
integrate_origin() {
    local store=$1 store_dir=$2 tracking_ref merge_output ancestor_status commit_message
    MERGED_FROM_ORIGIN=0 INTEGRATION_OUTCOME='' INTEGRATION_DETAIL='' KEPT_BOTH_COUNT=0
    tracking_ref="refs/remotes/$ORIGIN_REMOTE_NAME/$CURRENT_BRANCH"
    # An origin with no such branch yet has nothing to merge: the push makes it.
    git_in_store "$store_dir" rev-parse -q --verify "$tracking_ref^{commit}" >/dev/null || return 0
    if ! head_is_unborn "$store_dir"; then
        git_in_store "$store_dir" merge-base --is-ancestor "$tracking_ref" HEAD
        ancestor_status=$?
        (( ancestor_status != 0 )) || return 0
        if (( ancestor_status != 1 )); then
            report_store_failure "$store" "git could not compare HEAD with $tracking_ref"
            return 1
        fi
    fi
    merge_output=$(LC_ALL=C git_in_store "$store_dir" "${MERGE_CONFIG_OPTIONS[@]}" merge "${MERGE_FLAGS[@]}" \
        "$tracking_ref" 2>&1) && { MERGED_FROM_ORIGIN=1; return 0; }
    if ! merge_is_in_progress "$store_dir"; then
        if [[ "$merge_output" =~ $MERGE_BLOCKED_ERE ]]; then
            INTEGRATION_OUTCOME=$OUTCOME_BLOCKED
            INTEGRATION_DETAIL="a local file is in the way of the merge: $(blocking_paths_of "$merge_output")"
            return 0
        fi
        redacted_text "$merge_output" >&2
        printf '\n' >&2
        report_store_failure "$store" "git merge failed"
        return 1
    fi
    if ! resolve_conflicts "$store" "$store_dir"; then
        abort_merge "$store" "$store_dir"
        return 1
    fi
    commit_message="$HOST_NAME: merge, kept both for $KEPT_BOTH_COUNT files"
    if ! run_git_reporting_errors "$store_dir" commit -q --no-verify --no-gpg-sign -m "$commit_message"; then
        report_store_failure "$store" "git could not commit the merge"
        abort_merge "$store" "$store_dir"
        return 1
    fi
    MERGED_FROM_ORIGIN=1
    INTEGRATION_OUTCOME=$OUTCOME_KEPT_BOTH
}

# push_to_origin STORE STORE_DIR — push HEAD to its branch on origin, once, unless origin already holds
# HEAD or there is nothing to push. Sets PUSHED. Returns 1 with NETWORK_OUTCOME and NETWORK_DETAIL set
# when the push failed: auth-failed, push-rejected when origin refused the ref, unreachable otherwise,
# and unreachable `run deadline` when the run deadline passed before it could start (a store reaches
# this only after a fetch, so this look can only drop the push, never add one); and
# NETWORK_STEP_COULD_NOT_RUN, having reported the store, when the call was refused for want of a route.
push_to_origin() {
    local store=$1 store_dir=$2 tracking_ref head_id tracking_id push_errors push_status otherwise
    PUSHED=0
    if head_is_unborn "$store_dir"; then return 0; fi
    tracking_ref="refs/remotes/$ORIGIN_REMOTE_NAME/$CURRENT_BRANCH"
    head_id=$(git_in_store "$store_dir" rev-parse -q --verify HEAD)
    tracking_id=$(git_in_store "$store_dir" rev-parse -q --verify "$tracking_ref^{commit}")
    if [[ -n "$head_id" && "$head_id" == "$tracking_id" ]]; then return 0; fi
    if run_deadline_has_passed; then
        NETWORK_OUTCOME=$OUTCOME_UNREACHABLE NETWORK_DETAIL=$RUN_DEADLINE_DETAIL
        return 1
    fi
    push_errors=$(network_git_in_store "$store_dir" push --quiet --no-verify --recurse-submodules=no \
        "$ORIGIN_REMOTE_NAME" "HEAD:refs/heads/$CURRENT_BRANCH" 2>&1 >/dev/null)
    push_status=$?
    if (( push_status == 0 )); then
        PUSHED=1
        return 0
    fi
    if (( push_status == UNROUTED_NETWORK_CALL_STATUS )); then
        report_unrouted_network_call "$store" push
        return "$NETWORK_STEP_COULD_NOT_RUN"
    fi
    otherwise=$OUTCOME_UNREACHABLE
    if [[ "$push_errors" =~ $PUSH_REJECTED_ERE ]]; then otherwise=$OUTCOME_PUSH_REJECTED; fi
    record_network_failure "$push_status" "$push_errors" "$otherwise"
    return 1
}

# write_last_ok STORE — record now as the last push or up-to-date check that succeeded, by a rename.
write_last_ok() {
    local store=$1 epoch last_ok_path="$STATE_DIR/$1$LAST_OK_FILE_SUFFIX"
    printf -v epoch '%(%s)T' -1
    # The shell's own complaint about the redirection is dropped: the line below names the file.
    if ! { printf '%s\n' "$epoch" > "$last_ok_path$STATUS_TEMP_SUFFIX"; } 2>/dev/null \
        || ! mv -f -- "$last_ok_path$STATUS_TEMP_SUFFIX" "$last_ok_path"; then
        printf '%s: %s: could not write %s\n' "$SCRIPT_NAME" "$store" "$last_ok_path" >&2
        return 1
    fi
}

# take_link_lock_reporting STORE — take_link_lock, reporting the store when it could not.
take_link_lock_reporting() {
    local lock_status
    take_link_lock
    lock_status=$?
    (( lock_status != 0 )) || return 0
    if (( lock_status == LOCK_WAIT_RAN_OUT )); then
        report_store_failure "$1" "the lock $LINK_LOCK_PATH was still held after $LOCK_WAIT_THIS_STORE s"
    else
        report_store_failure "$1" "could not take the lock $LINK_LOCK_PATH"
    fi
    return 1
}

# print_outcome_line STORE OUTCOME DETAIL — `<store>: <outcome>: <detail>`, on one line.
print_outcome_line() {
    printf '%s: %s: %s\n' "$1" "$2" "$(escaped_for_one_line "$3")"
}

# record_store_outcome STORE — write the store's status from what the run found, and print the line of
# a network outcome that is not ok. A withheld file is a bad level of its own, so it outranks a sync that
# worked and a failure the next run may not repeat (push-rejected, unreachable, skipped-no-token), which
# goes into its detail; it is added to the detail of one that is bad as well (blocked, auth-failed).
record_store_outcome() {
    local store=$1 outcome detail joined_paths='' withheld_path
    for withheld_path in "${WITHHELD_REDACTED_PATHS[@]}"; do
        joined_paths+="${joined_paths:+, }$withheld_path"
    done
    if (( ! STORE_HAS_ORIGIN )); then
        outcome=$OUTCOME_OK_LOCAL_ONLY detail=$NOTHING_TO_COMMIT_DETAIL
        if (( COMMITTED_COUNT )); then detail="committed $COMMITTED_COUNT files"; fi
    elif [[ -n "$NETWORK_OUTCOME" ]]; then
        outcome=$NETWORK_OUTCOME detail=$NETWORK_DETAIL
    elif [[ "$INTEGRATION_OUTCOME" == "$OUTCOME_BLOCKED" ]]; then
        outcome=$OUTCOME_BLOCKED detail=$INTEGRATION_DETAIL
    elif [[ "$INTEGRATION_OUTCOME" == "$OUTCOME_KEPT_BOTH" ]]; then
        outcome=$OUTCOME_KEPT_BOTH detail="kept both for $KEPT_BOTH_COUNT files"
    else
        outcome=$OUTCOME_OK detail='up to date'
        if (( PUSHED )); then detail='pushed'; fi
    fi
    if is_one_of "$outcome" "$OUTCOME_BLOCKED" "$OUTCOME_PUSH_REJECTED" "$OUTCOME_SKIPPED_NO_TOKEN" \
        "$OUTCOME_UNREACHABLE" "$OUTCOME_AUTH_FAILED"; then
        print_outcome_line "$store" "$outcome" "$detail"
    fi
    if [[ -n "$joined_paths" ]]; then
        if is_one_of "$outcome" "$OUTCOME_OK" "$OUTCOME_KEPT_BOTH" "$OUTCOME_OK_LOCAL_ONLY"; then
            outcome=$OUTCOME_WITHHELD detail=$joined_paths
        elif is_one_of "$outcome" "$OUTCOME_PUSH_REJECTED" "$OUTCOME_UNREACHABLE" "$OUTCOME_SKIPPED_NO_TOKEN"; then
            detail="$joined_paths; $outcome: $detail" outcome=$OUTCOME_WITHHELD
        else
            detail+="; withheld: $joined_paths"
        fi
    fi
    if [[ -n "$LAST_OK_FAILURE_DETAIL" ]]; then detail+="; $LAST_OK_FAILURE_DETAIL"; fi
    write_status "$store" "$outcome" "$detail"
}

# commit_and_integrate STORE STORE_DIR HAS_FETCHED — the part of a run that holds the lock: stage, gate
# and commit, then the merge of a fetched origin.
commit_and_integrate() {
    stage_gate_and_commit "$1" "$2" || return 1
    (( $3 )) || return 0
    integrate_origin "$1" "$2"
}

# sync_store STORE STORE_DIR — the route, the origin check and the refusal of an unfinished operation;
# the fetch; stage, gate, commit and merge under the lock; the push; then the status. Whether the store
# does network work at all is decided once, before its first network step: past the run deadline the
# route is not asked and nothing is fetched or pushed. Returns 1 when the store could not run.
sync_store() {
    local store=$1 store_dir=$2 has_fetched=0 locked_status fetch_status push_status
    NETWORK_OUTCOME='' NETWORK_DETAIL='' INTEGRATION_OUTCOME='' INTEGRATION_DETAIL='' MERGED_FROM_ORIGIN=0
    KEPT_BOTH_COUNT=0 PUSHED=0 COMMITTED_COUNT=0 WITHHELD_REDACTED_PATHS=() LAST_OK_FAILURE_DETAIL=''
    ROUTE_MODE='' STORE_IS_PAST_DEADLINE=0
    if run_deadline_has_passed; then STORE_IS_PAST_DEADLINE=1; fi
    # Past the deadline nothing reaches the network, so the route that serves it is not asked either.
    if (( ! STORE_IS_PAST_DEADLINE )); then resolve_route "$store" "$store_dir" || return 1; fi
    check_origin "$store" "$store_dir" || return 1
    refuse_unfinished_operation "$store" "$store_dir" || return 1
    if (( STORE_HAS_ORIGIN )); then
        if [[ "$ROUTE_MODE" == "$ROUTE_MODE_NO_TOKEN" ]]; then
            NETWORK_OUTCOME=$OUTCOME_SKIPPED_NO_TOKEN NETWORK_DETAIL=$NO_TOKEN_DETAIL
        elif (( STORE_IS_PAST_DEADLINE )); then
            NETWORK_OUTCOME=$OUTCOME_UNREACHABLE NETWORK_DETAIL=$RUN_DEADLINE_DETAIL
        else
            fetch_origin "$store" "$store_dir"
            fetch_status=$?
            if (( fetch_status == NETWORK_STEP_COULD_NOT_RUN )); then return 1; fi
            if (( fetch_status == 0 )); then has_fetched=1; fi
        fi
    fi
    take_link_lock_reporting "$store" || return 1
    commit_and_integrate "$store" "$store_dir" "$has_fetched"
    locked_status=$?
    release_link_lock
    (( locked_status == 0 )) || return 1

    if (( COMMITTED_COUNT )); then printf '%s: committed %d files\n' "$store" "$COMMITTED_COUNT"; fi
    if (( MERGED_FROM_ORIGIN )); then
        if [[ "$INTEGRATION_OUTCOME" == "$OUTCOME_KEPT_BOTH" ]]; then
            printf '%s: merged %s/%s, kept both for %d files\n' "$store" "$ORIGIN_REMOTE_NAME" "$CURRENT_BRANCH" "$KEPT_BOTH_COUNT"
        else
            printf '%s: merged %s/%s\n' "$store" "$ORIGIN_REMOTE_NAME" "$CURRENT_BRANCH"
        fi
    fi
    if (( has_fetched )) && [[ "$INTEGRATION_OUTCOME" != "$OUTCOME_BLOCKED" ]]; then
        push_to_origin "$store" "$store_dir"
        push_status=$?
        if (( push_status == NETWORK_STEP_COULD_NOT_RUN )); then return 1; fi
        if (( push_status == 0 )); then
            if (( PUSHED )); then printf '%s: pushed\n' "$store"; fi
            if ! write_last_ok "$store"; then
                LAST_OK_FAILURE_DETAIL="could not write $STATE_DIR/$store$LAST_OK_FILE_SUFFIX"
            fi
        fi
    fi
    # The outcome is recorded even when last-ok could not be: its detail then says so, and the run
    # still ends as could not run.
    record_store_outcome "$store" || { FAILED_STORES+=("$store"); return 1; }
    if [[ -n "$LAST_OK_FAILURE_DETAIL" ]]; then
        FAILED_STORES+=("$store")
        return 1
    fi
}

# apply_store STORE STORE_DIR — sync_store, then the token goes, whichever way the store's run ended:
# it never stays in this process past its own store.
apply_store() {
    local store_status
    sync_store "$@"
    store_status=$?
    ROUTED_TOKEN=''
    return "$store_status"
}

# ---------------------------------------------------------------------------------------------
# --status: read-only.
# ---------------------------------------------------------------------------------------------

# print_status_line STORE LEVEL MESSAGE — one line of --status.
print_status_line() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

# find_in_store STORE_DIR FIND_EXPRESSION… — find, from inside the store, over everything but .git: each
# path is ./<path in the store>, ended by a NUL. From inside, so a pattern never meets the store's own
# path.
find_in_store() {
    local store_dir=$1
    shift
    (cd -- "$store_dir" && find . -path ./.git -prune -o "$@" -print0)
}

# count_conflict_copies STORE_DIR — how many conflict copies the tree holds, outside .git.
count_conflict_copies() {
    local conflict_copies=()
    read_nul_items conflict_copies find_in_store "$1" ! -type d -name "$CONFLICT_COPY_NAME_GLOB" || return 1
    printf '%s' "${#conflict_copies[@]}"
}

# index_problem_counts INDEX_FILE — `<lines> <files>` for one index: how many of its lines name a file
# that is not there, and how many files more than one of its lines names. A target is a markdown link's;
# a URL, an anchor or an absolute path names no file in the store.
index_problem_counts() {
    local index_file=$1 index_dir=${1%/*} line rest target line_targets line_names_missing
    local missing_lines=0 repeated_files=0 target_key
    local -A lines_naming=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        rest=$line line_targets=$'\n' line_names_missing=0
        while [[ "$rest" =~ $INDEX_LINK_RE ]]; do
            target=${BASH_REMATCH[1]}
            rest=${rest#*"${BASH_REMATCH[0]}"}
            target=${target%%#*}
            target=${target#./}
            if [[ -z "$target" || "$target" =~ $NOT_A_STORE_FILE_RE ]]; then continue; fi
            # One line naming a file twice is still one line.
            [[ "$line_targets" != *$'\n'"$target"$'\n'* ]] || continue
            line_targets+="$target"$'\n'
            target_key="target:$target"
            lines_naming["$target_key"]=$(( ${lines_naming["$target_key"]:-0} + 1 ))
            if [[ ! -e "$index_dir/$target" && ! -L "$index_dir/$target" ]]; then line_names_missing=1; fi
        done
        missing_lines=$(( missing_lines + line_names_missing ))
    done < "$index_file" || return 1
    for target_key in "${!lines_naming[@]}"; do
        if (( ${lines_naming["$target_key"]} > 1 )); then repeated_files=$(( repeated_files + 1 )); fi
    done
    printf '%s %s' "$missing_lines" "$repeated_files"
}

# print_index_warnings STORE STORE_DIR — a warn line for each directory whose index names a file that
# is not there, or names one file on two lines, in the order of the directories' names.
print_index_warnings() {
    local store=$1 store_dir=$2 index_files=() index_file counts missing_lines repeated_files index_dir
    if ! read_nul_items index_files find_in_store "$store_dir" -type f \
        \( -name "$INDEX_FILE_NAME" -o -name "$TOPIC_INDEX_FILE_GLOB" \); then
        return 1
    fi
    if (( ${#index_files[@]} == 0 )); then return 0; fi
    read_nul_items index_files sort_nul_items "${index_files[@]}" || return 1
    # Each is ./<path in the store>; its directory is shown as find gives it, less the ./ (the store's
    # own top is .).
    for index_file in "${index_files[@]}"; do
        counts=$(index_problem_counts "$store_dir/${index_file#./}") || return 1
        read -r missing_lines repeated_files <<< "$counts"
        (( missing_lines || repeated_files )) || continue
        index_dir=${index_file%/*}
        index_dir=${index_dir#./}
        print_status_line "$store" "$STATUS_LEVEL_WARN" \
            "$(printable_path "$index_dir"): $missing_lines index lines name a missing file, $repeated_files files are named by more than one index line"
    done
}

# sort_nul_items ITEM… — the items, sorted bytewise, each ended by a NUL.
sort_nul_items() {
    printf '%s\0' "$@" | LC_ALL=C sort -z
}

# read_status_file STORE — set STATUS_OUTCOME and STATUS_DETAIL from the store's status line, both
# empty when there is none. Returns 1 when the line is not one this script writes.
read_status_file() {
    local status_path="$STATE_DIR/$1$STATUS_FILE_SUFFIX" status_line rest
    STATUS_OUTCOME='' STATUS_DETAIL=''
    [[ -e "$status_path" ]] || return 0
    status_line=$(< "$status_path") || return 1
    [[ "$status_line" == *$'\t'*$'\t'* ]] || return 1
    rest=${status_line#*$'\t'}
    [[ "${status_line%%$'\t'*}" =~ $EPOCH_RE ]] || return 1
    STATUS_OUTCOME=${rest%%$'\t'*}
    STATUS_DETAIL=${rest#*$'\t'}
    is_one_of "$STATUS_OUTCOME" "${KNOWN_OUTCOMES[@]}"
}

# status_store STORE STORE_DIR — print the store's --status lines. Returns 1, having reported the
# store, when it could not be read.
status_store() {
    local store=$1 store_dir=$2 last_ok_path="$STATE_DIR/$1$LAST_OK_FILE_SUFFIX" last_ok='' now
    local age_minutes=0 is_fresh=0 last_outcome_text printed_lines=0 conflict_copy_count
    check_origin "$store" "$store_dir" || return 1
    if ! read_status_file "$store"; then
        report_store_failure "$store" "the status file is not one this script writes"
        return 1
    fi
    if [[ -e "$last_ok_path" ]]; then
        last_ok=$(< "$last_ok_path")
        if [[ ! "$last_ok" =~ $EPOCH_RE ]]; then
            report_store_failure "$store" "the last-ok file does not hold an epoch"
            return 1
        fi
        printf -v now '%(%s)T' -1
        if (( now > last_ok )); then age_minutes=$(( (now - last_ok) / SECONDS_PER_MINUTE )); fi
        if (( now - last_ok <= STALE_AFTER_MINUTES * SECONDS_PER_MINUTE )); then is_fresh=1; fi
    fi
    last_outcome_text='no run recorded'
    if [[ -n "$STATUS_OUTCOME" ]]; then
        last_outcome_text="last outcome $STATUS_OUTCOME${STATUS_DETAIL:+: $STATUS_DETAIL}"
    fi

    case "$STATUS_OUTCOME" in
        "$OUTCOME_WITHHELD"|"$OUTCOME_BLOCKED"|"$OUTCOME_AUTH_FAILED"|"$OUTCOME_COULD_NOT_RUN")
            print_status_line "$store" "$STATUS_LEVEL_BAD" "$STATUS_OUTCOME: $STATUS_DETAIL"
            printed_lines=$(( printed_lines + 1 )) ;;
        "$OUTCOME_OK_LOCAL_ONLY")
            print_status_line "$store" "$STATUS_LEVEL_WARN" 'no remote yet'
            printed_lines=$(( printed_lines + 1 )) ;;
        "$OUTCOME_PUSH_REJECTED"|"$OUTCOME_UNREACHABLE"|"$OUTCOME_SKIPPED_NO_TOKEN")
            # Past the threshold, the staleness line below names this outcome.
            if (( STORE_HAS_ORIGIN && is_fresh )); then
                print_status_line "$store" "$STATUS_LEVEL_WARN" "$STATUS_OUTCOME: $STATUS_DETAIL"
                printed_lines=$(( printed_lines + 1 ))
            fi ;;
    esac
    if (( STORE_HAS_ORIGIN )) && [[ -z "$last_ok" ]]; then
        print_status_line "$store" "$STATUS_LEVEL_BAD" "never synced; $last_outcome_text"
        printed_lines=$(( printed_lines + 1 ))
    elif (( STORE_HAS_ORIGIN && ! is_fresh )); then
        print_status_line "$store" "$STATUS_LEVEL_BAD" \
            "last synced $age_minutes min ago, past the $STALE_AFTER_MINUTES min threshold; $last_outcome_text"
        printed_lines=$(( printed_lines + 1 ))
    elif (( ! STORE_HAS_ORIGIN )) && [[ -z "$STATUS_OUTCOME" ]]; then
        print_status_line "$store" "$STATUS_LEVEL_WARN" 'no run recorded yet'
        printed_lines=$(( printed_lines + 1 ))
    fi
    if (( printed_lines == 0 )); then
        if (( STORE_HAS_ORIGIN )); then
            print_status_line "$store" "$STATUS_LEVEL_OK" "last synced $age_minutes min ago"
        else
            print_status_line "$store" "$STATUS_LEVEL_OK" "$last_outcome_text"
        fi
    fi

    if ! conflict_copy_count=$(count_conflict_copies "$store_dir"); then
        report_store_failure "$store" "could not look for conflict copies in the tree"
        return 1
    fi
    if (( conflict_copy_count )); then
        print_status_line "$store" "$STATUS_LEVEL_WARN" "$conflict_copy_count conflict copies in the tree"
    fi
    if ! print_index_warnings "$store" "$store_dir"; then
        report_store_failure "$store" "could not read the indexes in the tree"
        return 1
    fi
}

# ---------------------------------------------------------------------------------------------
# --check and --scan: read-only.
# ---------------------------------------------------------------------------------------------

# ahead_behind_text STORE_DIR — `ahead <n> behind <n>` against the last-fetched origin ref of the
# current branch, or NO_FETCHED_ORIGIN_TEXT when there is none. Never fetches.
ahead_behind_text() {
    local store_dir=$1 branch tracking_ref counts ahead behind
    if ! branch=$(git_in_store "$store_dir" symbolic-ref -q --short HEAD); then
        printf '%s' "$NO_FETCHED_ORIGIN_TEXT"
        return 0
    fi
    tracking_ref="refs/remotes/$ORIGIN_REMOTE_NAME/$branch"
    if ! git_in_store "$store_dir" rev-parse -q --verify "$tracking_ref^{commit}" >/dev/null; then
        printf '%s' "$NO_FETCHED_ORIGIN_TEXT"
        return 0
    fi
    if head_is_unborn "$store_dir"; then
        behind=$(git_in_store "$store_dir" rev-list --count "$tracking_ref") || return 1
        printf 'ahead 0 behind %s' "$behind"
        return 0
    fi
    counts=$(git_in_store "$store_dir" rev-list --left-right --count "HEAD...$tracking_ref") || return 1
    read -r ahead behind <<< "$counts"
    printf 'ahead %s behind %s' "$ahead" "$behind"
}

# check_store STORE STORE_DIR — print what --apply would commit and withhold, and how far the store
# is from its fetched origin. Returns 1 when the store could not be read.
check_store() {
    local store=$1 store_dir=$2 status_entries=() status_entry path full_path
    local name_and_content_command=() shape_status labels withheld_lines=() pending_count position
    check_origin "$store" "$store_dir" || return 1
    # The stage's pathspec, so that what is counted is what would be staged: every changed tracked path
    # and every untracked one, ignored ones included, one entry each ("XY <path>"). `git status` and not
    # `git diff <tree>`: under GIT_OPTIONAL_LOCKS=0 status leaves the index alone, and diff still writes
    # back the entries it refreshes (probed, git 2.53).
    # A warning git prints names a path, so it passes through the redactor.
    if ! read_nul_items status_entries stderr_redacted git_in_store "$store_dir" status --porcelain=v1 -z \
        --no-renames --untracked-files=all --ignored=traditional -- "${STAGE_PATHSPEC[@]}"; then
        report_store_failure "$store" "git could not list the changed files"
        return 1
    fi
    for status_entry in "${status_entries[@]}"; do
        path=${status_entry:PORCELAIN_STATUS_PREFIX_LENGTH}
        full_path="$store_dir/$path"
        name_and_content_command=(print_name_then_content "$path")
        if [[ -L "$full_path" ]]; then name_and_content_command+=(print_link_target "$full_path")
        elif [[ -f "$full_path" ]]; then name_and_content_command+=(print_file_content "$full_path")
        elif [[ ! -e "$full_path" ]]; then continue   # a deletion: its name leaves the tree
        fi   # else a nested repository: its name is all a commit would carry
        content_has_credential_shape "${name_and_content_command[@]}"
        shape_status=$?
        (( shape_status != 1 )) || continue
        if (( shape_status != 0 )); then
            report_store_failure "$store" "could not read $(printable_path "$path")"
            return 1
        fi
        labels=$(shape_labels_of "${name_and_content_command[@]}")
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

# scan_store STORE STORE_DIR — name each file in the scanned revision's tree whose name or content
# carries a credential shape. Returns 1 when the origin is not the table's remote, or the revision or a
# blob could not be read.
scan_store() {
    local store=$1 store_dir=$2 tree_id tree_items=() item metadata path object_type object_id
    local shape_status labels shown_path name_and_content_command=()
    check_origin "$store" "$store_dir" || return 1
    if [[ -n "$SCAN_REVISION" ]]; then
        if ! tree_id=$(git_in_store "$store_dir" rev-parse -q --verify "$SCAN_REVISION^{tree}"); then
            report_store_failure "$store" "revision $SCAN_REVISION does not resolve to a tree"
            return 1
        fi
    elif head_is_unborn "$store_dir"; then
        return 0
    elif ! tree_id=$(git_in_store "$store_dir" rev-parse -q --verify 'HEAD^{tree}'); then
        report_store_failure "$store" "git could not read HEAD"
        return 1
    fi
    if ! read_nul_items tree_items git_in_store "$store_dir" ls-tree -r -z "$tree_id"; then
        report_store_failure "$store" "git could not list the tree of ${SCAN_REVISION:-HEAD}"
        return 1
    fi
    # Each item: "<mode> <type> <id>", a tab, then the path. A submodule (type commit) has a name alone.
    for item in "${tree_items[@]}"; do
        metadata=${item%%$'\t'*}
        path=${item#*$'\t'}
        read -r _ object_type object_id <<< "$metadata"
        name_and_content_command=(print_name_then_content "$path")
        if [[ "$object_type" == blob ]]; then
            name_and_content_command+=(git_in_store "$store_dir" cat-file blob "$object_id")
        fi
        content_has_credential_shape "${name_and_content_command[@]}"
        shape_status=$?
        (( shape_status != 1 )) || continue
        shown_path=$(printable_path "$path")
        if (( shape_status != 0 )); then
            report_store_failure "$store" "could not read $shown_path"
            return 1
        fi
        labels=$(shape_labels_of "${name_and_content_command[@]}")
        printf '%s: %s (%s)\n' "$store" "$shown_path" "$labels"
        NEEDS_ATTENTION=1
    done
}

# settle_host_name — the host a commit message, a conflict copy's name and the threshold name.
settle_host_name() {
    HOST_NAME=${CLAUDE_MEMORY_HOST:-$(hostname -s)}
    [[ "$HOST_NAME" =~ $HOST_NAME_RE ]] || die "host name '$HOST_NAME' cannot go in a commit message or a file name"
}

# prepare_apply — settle the host name, the lock wait and the tools only --apply runs.
prepare_apply() {
    settle_host_name
    [[ "$LOCK_WAIT_SECONDS" =~ $LOCK_WAIT_SECONDS_RE ]] \
        || die "CLAUDE_MEMORY_LOCK_WAIT_SECONDS '$LOCK_WAIT_SECONDS' is not a whole number of seconds above 0"
    [[ "$RUN_DEADLINE_SECONDS" =~ $WHOLE_SECONDS_RE ]] \
        || die "CLAUDE_MEMORY_RUN_DEADLINE_SECONDS '$RUN_DEADLINE_SECONDS' is not a whole number of seconds above 0"
    [[ "$GH_ROUTE_TIMEOUT_SECONDS" =~ $WHOLE_SECONDS_RE ]] \
        || die "CLAUDE_MEMORY_GH_ROUTE_TIMEOUT_SECONDS '$GH_ROUTE_TIMEOUT_SECONDS' is not a whole number of seconds above 0"
    [[ -n "$RUN_STARTED_CENTISECONDS" ]] \
        || die "could not read the uptime from $UPTIME_FILE, which the run deadline is measured on (Linux only)"
    command -v flock >/dev/null || die "flock is required"
    command -v timeout >/dev/null || die "timeout is required"
    [[ -x "$GH_ROUTE" ]] || die "$GH_ROUTE is not executable"
}

# settle_stale_after_minutes — this host's threshold: the table's stale_after_minutes[<host>], else its
# .default, else STALE_AFTER_MINUTES_DEFAULT. load_store_table has checked the shape.
settle_stale_after_minutes() {
    settle_host_name
    STALE_AFTER_MINUTES=$(jq -r --arg host "$HOST_NAME" --argjson fallback "$STALE_AFTER_MINUTES_DEFAULT" \
        '(.stale_after_minutes // {}) | (.[$host] // .default // $fallback)' "$CONFIG_PATH") \
        || die "could not read stale_after_minutes from $CONFIG_PATH"
    [[ "$STALE_AFTER_MINUTES" =~ $STALE_AFTER_MINUTES_RE ]] \
        || die "$CONFIG_PATH: stale_after_minutes for $HOST_NAME is not a whole number of minutes above 0"
}

main() {
    local store store_dir
    # The run deadline counts from here; prepare_apply refuses a run whose clock could not be read.
    read_uptime_centiseconds RUN_STARTED_CENTISECONDS || RUN_STARTED_CENTISECONDS=''
    parse_args "$@"
    # Every default path hangs off HOME.
    [[ -n "${HOME:-}" ]] || die "HOME is not set"
    # These would point this script's git calls at another repository: a git hook exports them.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    # With these, git writes its trace, curl's headers and an Authorization header among them, to the
    # stderr this script keeps in a status detail.
    unset GIT_CURL_VERBOSE "${!GIT_TRACE@}"
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
    load_store_table
    if [[ -n "$ONLY_STORE" && -z "${REMOTE_OF_STORE[$ONLY_STORE]+set}" ]]; then
        die "no store named $ONLY_STORE in $CONFIG_PATH"
    fi
    if [[ "$MODE" == apply ]]; then
        prepare_apply
    else
        # --check, --scan and --status never write, and an index refresh is a write git otherwise makes
        # on its own.
        export GIT_OPTIONAL_LOCKS=0
    fi
    if [[ "$MODE" == status ]]; then
        settle_stale_after_minutes
        # A state dir that is not there yet means no run yet; one that is there and cannot be read would
        # make every store read as never synced.
        if [[ -e "$STATE_DIR" ]] && ! [[ -d "$STATE_DIR" && -r "$STATE_DIR" && -x "$STATE_DIR" ]]; then
            die "the state dir $STATE_DIR cannot be read"
        fi
    fi
    for store in "${STORE_NAMES[@]}"; do
        if [[ -n "$ONLY_STORE" && "$store" != "$ONLY_STORE" ]]; then continue; fi
        store_dir="$STORES_ROOT/$store"
        [[ -e "$store_dir/.git" ]] || continue
        case "$MODE" in
            apply)  apply_store "$store" "$store_dir" ;;
            check)  check_store "$store" "$store_dir" ;;
            scan)   scan_store "$store" "$store_dir" ;;
            status) status_store "$store" "$store_dir" ;;
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
