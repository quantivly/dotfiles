#!/usr/bin/env bash
#
# scripts/test-claude-memory-sync.sh
# ==================================
#
# State table for scripts/claude-memory-sync.sh. The local half: the origin check, staging every file
# but the link script's partial copies, the credential-shape gate, the commit with no hook, the lock,
# the status file, --check and --scan. The network half: the route and the token, fetch, the merge
# that keeps both copies on a conflict, the push, and --status.
#
# HERMETIC. Every row runs against fixtures under mktemp -d, under a fixture HOME, with the projects
# dir, the stores root, the store table, the state dir, the host name, the lock wait and both route
# scripts named explicitly; git reads only the fixture's config files. A store is a real
# `git init -b main` checkout and a remote is a local bare repository, so nothing touches the network.
# The credential in the gate rows is fake, gho_ and 36 letters, built at run time so that no scanner
# reads this file as holding one. A row that must see what git or cat is asked to do puts a fixture
# wrapper first on PATH for that one run; the wrapper runs the real tool. The other host is a second
# checkout of the same bare remote, and gh-route is a stub whose answer each row picks.
# Requires: bash, git, jq, flock, sha256sum, find, sort, timeout, touch, sleep, cat, stat, sh, a
# user other than root (the unreadable-file rows would assert nothing as root).

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/claude-memory-sync.sh"
REDACTOR="$DOTFILES/scripts/redact-secrets.sh"
# Checked, because every fixture path hangs off it and reset_scene removes them: with an empty
# TMPROOT, HOME would be /home.
TMPROOT="$(mktemp -d)" || { printf 'FATAL: mktemp failed\n' >&2; exit 2; }
trap 'rm -rf "$TMPROOT"' EXIT
TMPROOT="$(cd -P "$TMPROOT" && pwd -P)" || { printf 'FATAL: could not resolve the fixture root\n' >&2; exit 2; }

HOME="$TMPROOT/home"
mkdir -p "$HOME"
export HOME
# A row run from a git hook would otherwise point every fixture git at the hook's repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
# The account a shell routed to would otherwise reach every git call the rows log, and an unpinned run
# would show it as its own.
unset GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN CLAUDE_MEMORY_GIT_TOKEN
# The caller's host name or profile marker would otherwise name the host; the host-name rows set their own.
unset CLAUDE_SETTINGS_RENDER_MARKER CLAUDE_MEMORY_HOST
GIT_CONFIG_GLOBAL="$TMPROOT/gitconfig-global"
GIT_CONFIG_SYSTEM="$TMPROOT/gitconfig-system"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
# The global ignore file names one file, so that a row can show the stage takes it anyway.
GLOBAL_IGNORE_FILE="$TMPROOT/global-ignore"
GLOBALLY_IGNORED_NAME='global-ignored.md'
printf '%s\n' "$GLOBALLY_IGNORED_NAME" > "$GLOBAL_IGNORE_FILE"
: > "$GIT_CONFIG_SYSTEM"
cat > "$GIT_CONFIG_GLOBAL" <<GITCONFIG
[user]
    name = Fixture
    email = fixture@example.invalid
[init]
    defaultBranch = main
[core]
    excludesFile = $GLOBAL_IGNORE_FILE
GITCONFIG

# A second global config that turns signing on, with a signer that records the call and fails, so a
# commit that tried to sign would not exist.
SIGNING_STUB="$TMPROOT/stub-bin/failing-signer"
SIGNING_CALLS="$TMPROOT/signer-calls"
SIGNING_CONFIG="$TMPROOT/gitconfig-signing"
cat > "$SIGNING_CONFIG" <<GITCONFIG
[include]
    path = $GIT_CONFIG_GLOBAL
[commit]
    gpgsign = true
[gpg]
    program = $SIGNING_STUB
GITCONFIG

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for tool in bash git jq flock sha256sum find sort timeout touch sleep cat stat sh base64; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
(( $(id -u) != 0 )) || fatal "the table cannot run as root: its unreadable-file rows would assert nothing"
[[ -x "$SUT" ]] || fatal "$SUT is not executable — every row below would assert nothing"
[[ -x "$REDACTOR" ]] || fatal "$REDACTOR is not executable — the gate rows could not show their fixtures are right"

# ---------------------------------------------------------------------------------------------
# Fixtures. A scene is an empty fixture home, stores root and state dir, the alpha store checked out
# with no origin, and the default store table.
# ---------------------------------------------------------------------------------------------

NL=$'\n'
PROJECTS_DIR="$TMPROOT/projects"
STORES_ROOT="$TMPROOT/stores"
CONFIG="$TMPROOT/memory-stores.json"
STATE_DIR="$TMPROOT/state"
REMOTES_DIR="$TMPROOT/remotes"
SEED_DIR="$TMPROOT/seed"
FIXTURE_HOST='fixture-host'
FIXTURE_OWNER='example-org'
ALPHA_STORE='alpha-store'
BETA_STORE='beta-store'
ALPHA_DIR="$STORES_ROOT/$ALPHA_STORE"
BETA_DIR="$STORES_ROOT/$BETA_STORE"
ALPHA_REMOTE="https://github.com/$FIXTURE_OWNER/alpha-memory.git"
BETA_REMOTE="https://github.com/$FIXTURE_OWNER/beta-memory.git"
OTHER_REMOTE="https://github.com/$FIXTURE_OWNER/other-memory.git"
# The link script's tenant route: the sync never asks it.
ROUTE_STUB="$TMPROOT/stub-bin/refusing-route"
# The sync's gh-route: FIXTURE_GH_ROUTE_MODE picks its answer (none, the default: no route; matched: the
# fixture's config dir and token file; fail: exit 2), and every directory it is asked about is logged.
GH_ROUTE_STUB="$TMPROOT/stub-bin/gh-route"
FIXTURE_GH_ROUTE_CALLS="$TMPROOT/gh-route-calls"
FIXTURE_GH_CONFIG_DIR="$TMPROOT/gh-config/fixture-account"
FIXTURE_TOKEN_FILE="$TMPROOT/gh-token-cache/fixture-account"
FIXTURE_GH_ROUTE_MODE=none
FAKE_TOKEN="gho_$(printf 'A%.0s' {1..36})"
# What the redactor's shape rules make of FAKE_TOKEN.
REDACTED_FAKE_TOKEN='<REDACTED:github-token>'
LINK_LOCK="$STATE_DIR/link.lock"
LOCK_HOLD_SECONDS=2
HANG_BOUND_SECONDS=30
# Every run's run deadline and gh-route limit: far past anything a row does, so only the rows about
# them meet them.
RUN_DEADLINE_SECONDS_FOR_ROWS=600
GH_ROUTE_TIMEOUT_SECONDS_FOR_ROWS=20
# The run deadline is measured on the kernel's uptime. The clock row hands the script a fixture file
# instead, one the git wrapper moves: past the deadline on a fetch, back to the start on any call in
# FIXTURE_CLOCK_BACK_DIR.
REAL_UPTIME_FILE='/proc/uptime'
FIXTURE_UPTIME_FILE="$TMPROOT/fixture-uptime"
FIXTURE_UPTIME_START='1000.00 0.00'
FIXTURE_UPTIME_PAST_DEADLINE='1005.00 0.00'
# The deadline row: a deadline two seconds into the run, and a fetch that takes three, so the first
# store's fetch starts before it and everything after that fetch starts after it.
DEADLINE_ROW_DEADLINE_SECONDS=2
DEADLINE_ROW_FETCH_SECONDS=3
# The gh-route limit row: a limit of one second, and a gh-route that would answer only after the row's
# hang bound.
GH_ROUTE_LIMIT_ROW_SECONDS=1
FIXTURE_GH_ROUTE_HANG_SECONDS=$(( HANG_BOUND_SECONDS + 10 ))
# The lock wait every run is given: past LOCK_HOLD_SECONDS, so the waiting row waits it out, and short of
# HANG_BOUND_SECONDS, so a run that times out says so before the bound kills it.
LOCK_WAIT_SECONDS_FOR_ROWS=20
# The timeout row's wait, and how long at most its holder keeps the lock: well past that wait.
LOCK_WAIT_SECONDS_SHORT=1
TIMEOUT_ROW_HOLD_SECONDS=4
# How a row waits for its lock holder to have taken the lock: at most 100 looks, 0.05 s apart.
LOCK_TAKEN_POLL_ATTEMPTS=100
LOCK_TAKEN_POLL_INTERVAL_SECONDS=0.05
# How long the background child a commit leaves behind lives: long past the end of the run.
LEFTOVER_CHILD_SECONDS=5
# touch -t: a moment after any fixture's own writes, so the file's stat data no longer matches its index entry.
FUTURE_MTIME_STAMP='203001010000'
# touch -t: a moment long before the run, so a file the run rewrites shows it in its mtime.
PAST_MTIME_STAMP='200001010000'
# What a host that is not this one calls itself, in a conflict copy it made.
OTHER_HOST='other-host'
# The index lines the integrate rows write: the seed's, then one per side.
SEED_INDEX_LINE='- [Seed](seed.md) — the seed note'
REMOTE_INDEX_LINE='- [Topic](topic.md) — the remote host wrote this'
LOCAL_INDEX_LINE='- [Topic](topic.md) — this host wrote this'
# How old a last-ok the staleness rows write, and the thresholds they set around it.
STALE_ROW_AGE_MINUTES=45
SHORT_THRESHOLD_MINUTES=30
LONG_THRESHOLD_MINUTES=180
SECONDS_PER_MINUTE=60
TAB=$'\t'
# The attributes the real stores carry at their root: git's own union driver for every index.
STORE_UNION_ATTRIBUTES="MEMORY.md merge=union${NL}INDEX_*.md merge=union"
TOPIC_INDEX_NAME='INDEX_topics.md'
# What both hosts append to an index under those attributes, overlapping on the middle line: the other
# host the first two, this one the last two.
INDEX_LINE_ONLY_REMOTE='- [X](x.md) — only the remote host wrote this'
INDEX_LINE_BOTH_HOSTS='- [Y](y.md) — both hosts wrote this'
INDEX_LINE_ONLY_LOCAL='- [Z](z.md) — only this host wrote this'
# The branch a hand-made second checkout is on, where the remote's other host pushes main, and what the
# sync says of it.
OTHER_BRANCH='master'
BRANCH_MISMATCH_REASON="origin has no branch $OTHER_BRANCH, only main: the store's branch is not the remote's; rename it to the remote's (git branch -m <that branch>)"
# The redactor runs sed. This one waits first, so a run that does not wait for the redactor says its
# next line before the redacted one.
SLOW_SED_DIR="$TMPROOT/slow-sed-bin"
SLOW_SED_SECONDS=1
GH_ROUTE_FIXTURE_ERROR='gh-route: fixture: the tables are malformed'

mkdir -p "$(dirname "$ROUTE_STUB")"
printf '#!/usr/bin/env bash\nprintf "stub route: not for the sync\\n" >&2\nexit 3\n' > "$ROUTE_STUB"
printf '#!/usr/bin/env bash\nprintf called > %q\nexit 1\n' "$SIGNING_CALLS" > "$SIGNING_STUB"
cat > "$GH_ROUTE_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FIXTURE_GH_ROUTE_CALLS"
case "$FIXTURE_GH_ROUTE_MODE" in
    none)    jq -cn '{state: "none", dir: "", token_file: "", why: "fixture: no route"}' ;;
    matched) jq -cn --arg dir "$FIXTURE_GH_CONFIG_DIR" --arg token_file "$FIXTURE_TOKEN_FILE" \
                 '{state: "matched", dir: $dir, token_file: $token_file, why: "fixture: matched"}' ;;
    fail)    printf '%s\n' "$GH_ROUTE_FIXTURE_ERROR" >&2; exit 2 ;;
    hang)    exec sleep "$FIXTURE_GH_ROUTE_HANG_SECONDS" ;;
esac
STUB
chmod +x "$ROUTE_STUB" "$SIGNING_STUB" "$GH_ROUTE_STUB"
mkdir -p "$FIXTURE_GH_CONFIG_DIR" "$(dirname "$FIXTURE_TOKEN_FILE")"
export FIXTURE_GH_ROUTE_CALLS FIXTURE_GH_CONFIG_DIR FIXTURE_TOKEN_FILE FIXTURE_GH_ROUTE_MODE \
    FIXTURE_GH_ROUTE_HANG_SECONDS GH_ROUTE_FIXTURE_ERROR
mkdir -p "$SLOW_SED_DIR"
printf '#!/usr/bin/env bash\nsleep %q\nexec %q "$@"\n' "$SLOW_SED_SECONDS" "$(command -v sed)" > "$SLOW_SED_DIR/sed"
chmod +x "$SLOW_SED_DIR/sed"

# A third global config whose core.hooksPath holds hooks that stage the withheld file and leave a mark:
# pre-commit and post-index-change can each put a file into the commit the gate just kept it out of.
FIXTURE_HOOKS_DIR="$TMPROOT/fixture-hooks"
HOOKS_CONFIG="$TMPROOT/gitconfig-hooks"
FIXTURE_HOOK_MARKER="$TMPROOT/a-hook-ran"
FIXTURE_HOOK_STAGED_PATH='notes/leaky.md'
cat > "$HOOKS_CONFIG" <<GITCONFIG
[include]
    path = $GIT_CONFIG_GLOBAL
[core]
    hooksPath = $FIXTURE_HOOKS_DIR
GITCONFIG
mkdir -p "$FIXTURE_HOOKS_DIR"
# shellcheck disable=SC2016  # expanded when the hook runs
printf '%s\n' '#!/usr/bin/env bash' ': > "$FIXTURE_HOOK_MARKER"' \
    '[[ -z "${FIXTURE_HOOK_IS_STAGING:-}" ]] || exit 0' 'export FIXTURE_HOOK_IS_STAGING=1' \
    'git add -f -- "$FIXTURE_HOOK_STAGED_PATH"' 'exit 0' > "$FIXTURE_HOOKS_DIR/pre-commit"
cp "$FIXTURE_HOOKS_DIR/pre-commit" "$FIXTURE_HOOKS_DIR/post-index-change"
cp "$FIXTURE_HOOKS_DIR/pre-commit" "$FIXTURE_HOOKS_DIR/post-commit"
# The hooks a merge and a push run. None of these names is a hook the receiving side runs, so the bare
# remote, which reads the same global config, runs none of them.
cp "$FIXTURE_HOOKS_DIR/pre-commit" "$FIXTURE_HOOKS_DIR/post-merge"
cp "$FIXTURE_HOOKS_DIR/pre-commit" "$FIXTURE_HOOKS_DIR/pre-merge-commit"
cp "$FIXTURE_HOOKS_DIR/pre-commit" "$FIXTURE_HOOKS_DIR/pre-push"
chmod +x "$FIXTURE_HOOKS_DIR"/*

# A fourth global config naming a file-system monitor that leaves a mark and stages the withheld file:
# git runs it on any call that reads the index, between the gate and the commit as much as anywhere.
FSMONITOR_CONFIG="$TMPROOT/gitconfig-fsmonitor"
FIXTURE_FSMONITOR="$TMPROOT/fixture-fsmonitor"
FIXTURE_FSMONITOR_MARKER="$TMPROOT/a-monitor-ran"
cat > "$FSMONITOR_CONFIG" <<GITCONFIG
[include]
    path = $GIT_CONFIG_GLOBAL
[core]
    fsmonitor = $FIXTURE_FSMONITOR
GITCONFIG
# shellcheck disable=SC2016  # expanded when the monitor runs
printf '%s\n' '#!/usr/bin/env bash' ': > "$FIXTURE_FSMONITOR_MARKER"' \
    '[[ -z "${FIXTURE_HOOK_IS_STAGING:-}" ]] || exit 1' 'export FIXTURE_HOOK_IS_STAGING=1' \
    'git add -f -- "$FIXTURE_HOOK_STAGED_PATH"' 'exit 1' > "$FIXTURE_FSMONITOR"
chmod +x "$FIXTURE_FSMONITOR"

# The fixture's git, for a row that puts it first on PATH: it logs each call's arguments; logs its
# subcommand with what its environment holds (the token: expected, other or unset; GH_CONFIG_DIR);
# keeps the inline credential helper it was given; on a fetch, fails as GitHub does for a repository it
# cannot see when FIXTURE_GIT_ON_FETCH=not-found; on a commit, does what FIXTURE_GIT_ON_COMMIT asks
# (probe-lock: record whether link.lock is free; leave-child: start a background child keeping every
# descriptor the commit was given but its output); then runs the real git.
FIXTURE_REAL_GIT=$(command -v git)
GIT_WRAPPER_DIR="$TMPROOT/git-wrapper-bin"
FIXTURE_GIT_CALL_LOG="$TMPROOT/git-calls"
FIXTURE_GIT_ENV_LOG="$TMPROOT/git-call-environments"
FIXTURE_GIT_SETTINGS_LOG="$TMPROOT/git-call-settings"
FIXTURE_CREDENTIAL_HELPER_FILE="$TMPROOT/credential-helper"
FIXTURE_LOCK_PROBE_RESULT="$TMPROOT/lock-probe-result"
FIXTURE_LEFTOVER_CHILD_PID="$TMPROOT/leftover-child-pid"
mkdir -p "$GIT_WRAPPER_DIR"
cat > "$GIT_WRAPPER_DIR/git" <<'WRAPPER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_GIT_CALL_LOG"
subcommand='' takes_value=0
for argument in "$@"; do
    if (( takes_value )); then takes_value=0; continue; fi
    case "$argument" in
        -C|-c) takes_value=1 ;;
        -*)    ;;
        *)     subcommand=$argument; break ;;
    esac
done
token_state=unset
if [[ -n "${CLAUDE_MEMORY_GIT_TOKEN:-}" ]]; then
    token_state=other
    if [[ "$CLAUDE_MEMORY_GIT_TOKEN" == "${FIXTURE_EXPECTED_TOKEN:-}" ]]; then token_state=expected; fi
fi
printf '%s token:%s gh-config:%s\n' "$subcommand" "$token_state" "${GH_CONFIG_DIR:-unset}" >> "$FIXTURE_GIT_ENV_LOG"
# What else the call's environment says about prompts, the locale and tracing: unset, or the value
# (an empty one shows as nothing after the colon).
trace_variable_names=$(compgen -v GIT_TRACE | grep -vx GIT_TRACE_REDACT | tr '\n' ',')
printf '%s askpass:%s prompt:%s locale:%s trace-variables:%s curl-verbose:%s trace-redact:%s\n' "$subcommand" \
    "${GIT_ASKPASS-unset}" "${GIT_TERMINAL_PROMPT-unset}" "${LC_ALL-unset}" "$trace_variable_names" \
    "${GIT_CURL_VERBOSE-unset}" "${GIT_TRACE_REDACT-unset}" >> "$FIXTURE_GIT_SETTINGS_LOG"
for argument in "$@"; do
    if [[ "$argument" == 'credential.helper=!'* ]]; then
        printf '%s' "${argument#credential.helper=!}" > "$FIXTURE_CREDENTIAL_HELPER_FILE"
    fi
done
if [[ -n "${FIXTURE_CLOCK_STEPS:-}" ]]; then
    if [[ "$subcommand" == fetch ]]; then printf '%s\n' "$FIXTURE_UPTIME_PAST_DEADLINE" > "$FIXTURE_UPTIME_FILE"; fi
    if [[ " $* " == *" -C $FIXTURE_CLOCK_BACK_DIR "* ]]; then printf '%s\n' "$FIXTURE_UPTIME_START" > "$FIXTURE_UPTIME_FILE"; fi
fi
if [[ "$subcommand" == fetch && "${FIXTURE_GIT_ON_FETCH:-}" == slow ]]; then
    sleep "$FIXTURE_FETCH_SECONDS"
fi
if [[ "$subcommand" == fetch && "${FIXTURE_GIT_ON_FETCH:-}" == not-found ]]; then
    printf "remote: Repository not found.\nfatal: repository 'https://github.com/%s/alpha-memory.git/' not found\n" \
        "$FIXTURE_OWNER" >&2
    exit 128
fi
if [[ " $* " == *" commit "* ]]; then
    case "${FIXTURE_GIT_ON_COMMIT:-}" in
        probe-lock)
            if flock -n "$FIXTURE_LINK_LOCK" true; then lock_state=free; else lock_state=held; fi
            printf '%s' "$lock_state" > "$FIXTURE_LOCK_PROBE_RESULT" ;;
        leave-child)
            sleep "$FIXTURE_LEFTOVER_CHILD_SECONDS" < /dev/null > /dev/null 2>&1 &
            printf '%s' "$!" > "$FIXTURE_LEFTOVER_CHILD_PID" ;;
    esac
fi
exec "$FIXTURE_REAL_GIT" "$@"
WRAPPER

# The fixture's cat, for a row that puts it first on PATH: FIXTURE_CAT_TARGET reads differently each
# time, as a file a session is writing would, and each read is counted; anything else is the real cat.
FIXTURE_REAL_CAT=$(command -v cat)
CAT_STUB_DIR="$TMPROOT/cat-stub-bin"
FIXTURE_CAT_READ_COUNT="$TMPROOT/cat-read-count"
mkdir -p "$CAT_STUB_DIR"
cat > "$CAT_STUB_DIR/cat" <<'STUB'
#!/usr/bin/env bash
if [[ $# -eq 2 && "$1" == -- && "$2" == "${FIXTURE_CAT_TARGET:-}" ]]; then
    read_count=0
    if [[ -e "$FIXTURE_CAT_READ_COUNT" ]]; then read_count=$(< "$FIXTURE_CAT_READ_COUNT"); fi
    read_count=$(( read_count + 1 ))
    printf '%s' "$read_count" > "$FIXTURE_CAT_READ_COUNT"
    printf 'body as of read %s\n' "$read_count"
    exit 0
fi
exec "$FIXTURE_REAL_CAT" "$@"
STUB
chmod +x "$GIT_WRAPPER_DIR/git" "$CAT_STUB_DIR/cat"
FIXTURE_LINK_LOCK=$LINK_LOCK
FIXTURE_LEFTOVER_CHILD_SECONDS=$LEFTOVER_CHILD_SECONDS
export FIXTURE_HOOK_MARKER FIXTURE_HOOK_STAGED_PATH FIXTURE_REAL_GIT FIXTURE_GIT_CALL_LOG \
    FIXTURE_LOCK_PROBE_RESULT FIXTURE_LEFTOVER_CHILD_PID FIXTURE_LINK_LOCK FIXTURE_LEFTOVER_CHILD_SECONDS \
    FIXTURE_REAL_CAT FIXTURE_CAT_READ_COUNT FIXTURE_GIT_ENV_LOG FIXTURE_CREDENTIAL_HELPER_FILE \
    FIXTURE_FSMONITOR_MARKER FIXTURE_OWNER FIXTURE_GIT_SETTINGS_LOG FIXTURE_UPTIME_FILE FIXTURE_UPTIME_START \
    FIXTURE_UPTIME_PAST_DEADLINE

# write_default_config — alpha and beta each in a store with its own remote.
write_default_config() {
    cat > "$CONFIG" <<JSON
{"stores": {"$ALPHA_STORE": {"remote": "$ALPHA_REMOTE", "tenants": ["alpha"]},
            "$BETA_STORE": {"remote": "$BETA_REMOTE", "tenants": ["beta"]}},
 "checkout_globs": ["code/*"],
 "plain_dirs": []}
JSON
}

# set_store_remote STORE URL — replace the table's remote for STORE.
set_store_remote() {
    jq --arg store "$1" --arg remote "$2" '.stores[$store].remote = $remote' "$CONFIG" > "$CONFIG.new" \
        || fatal "could not set the remote of $1"
    mv "$CONFIG.new" "$CONFIG" || fatal "could not replace the table"
}

# reset_scene — nothing under the fixture home, the stores root, the state dir or the remotes; the
# alpha store checked out with no origin and no commit, the beta store not checked out.
reset_scene() {
    rm -rf "$HOME" "$STORES_ROOT" "$STATE_DIR" "$REMOTES_DIR" "$SEED_DIR" "$SIGNING_CALLS" \
        "$FIXTURE_GH_ROUTE_CALLS" "$FIXTURE_CREDENTIAL_HELPER_FILE"
    : > "$FIXTURE_GIT_CALL_LOG"
    : > "$FIXTURE_GIT_ENV_LOG"
    : > "$FIXTURE_GIT_SETTINGS_LOG"
    rm -f "$FIXTURE_TOKEN_FILE"
    mkdir -p "$HOME" "$STORES_ROOT"
    git init -q -b main "$ALPHA_DIR" || fatal "could not create the alpha store"
    write_default_config
}

# write_file PATH BODY — PATH holds BODY and a newline, its directories made.
write_file() {
    mkdir -p "$(dirname "$1")" || fatal "could not create the directory of $1"
    printf '%s\n' "$2" > "$1" || fatal "could not write $1"
}

# fixture_commit DIR MESSAGE — commit everything in DIR, as the fixture, not as the script under test.
fixture_commit() {
    git -C "$1" add -A -f || fatal "could not stage in $1"
    git -C "$1" commit -q --no-gpg-sign -m "$2" || fatal "could not commit in $1"
}

# make_tracked_store STORE — STORE becomes a clone of a fresh bare remote holding one commit (seed.md
# and an index naming it), and the table's remote for STORE is that remote's path. The seed checkout
# stays at SEED_DIR: it is the other host, for pushes.
make_tracked_store() {
    local remote="$REMOTES_DIR/$1.git"
    git init -q --bare -b main "$remote" || fatal "could not create the remote of $1"
    git init -q -b main "$SEED_DIR" || fatal "could not create the seed checkout"
    write_file "$SEED_DIR/seed.md" 'seed body'
    write_file "$SEED_DIR/MEMORY.md" "$SEED_INDEX_LINE"
    fixture_commit "$SEED_DIR" 'seed'
    git -C "$SEED_DIR" push -q "$remote" main || fatal "could not seed the remote of $1"
    rm -rf "${STORES_ROOT:?}/$1"
    git clone -q "$remote" "$STORES_ROOT/$1" || fatal "could not clone the remote of $1"
    set_store_remote "$1" "$remote"
}

# seed_push FILE_NAME — the seed checkout commits FILE_NAME and pushes it: another host's sync.
seed_push() {
    write_file "$SEED_DIR/$1" "$1 body"
    fixture_commit "$SEED_DIR" "$1"
    git -C "$SEED_DIR" push -q "$REMOTES_DIR/$ALPHA_STORE.git" main || fatal "could not push $1"
}

# seed_write_push PATH BODY — the other host writes PATH, commits and pushes it.
seed_write_push() {
    write_file "$SEED_DIR/$1" "$2"
    fixture_commit "$SEED_DIR" "write $1"
    git -C "$SEED_DIR" push -q "$REMOTES_DIR/$ALPHA_STORE.git" main || fatal "could not push $1"
}

# seed_remove_push PATH — the other host deletes PATH, commits and pushes the deletion.
seed_remove_push() {
    git -C "$SEED_DIR" rm -q -- "$1" || fatal "could not remove $1 in the seed checkout"
    git -C "$SEED_DIR" commit -q --no-gpg-sign -m "remove $1" || fatal "could not commit the removal of $1"
    git -C "$SEED_DIR" push -q "$REMOTES_DIR/$ALPHA_STORE.git" main || fatal "could not push the removal of $1"
}

# pull_into_alpha — the alpha store takes what the remote has, as an earlier sync would have.
pull_into_alpha() {
    git -C "$ALPHA_DIR" fetch -q origin || fatal "could not fetch into the alpha store"
    git -C "$ALPHA_DIR" merge -q --ff-only origin/main || fatal "could not fast-forward the alpha store"
}

remote_head() { git -C "$REMOTES_DIR/$ALPHA_STORE.git" rev-parse main 2>/dev/null; }   # → the remote's main
local_head() { git -C "$ALPHA_DIR" rev-parse HEAD 2>/dev/null; }                      # → the alpha store's HEAD
parent_count() { git -C "$1" rev-list --parents -n 1 HEAD 2>/dev/null | wc -w | tr -d ' '; }  # DIR → 1 + parents
body_of() { cat "$1" 2>/dev/null || printf '(absent)'; }                                # FILE → its body
mtime_of() { stat -c %Y -- "$1" 2>/dev/null; }                                          # FILE → its mtime
last_ok_of() { cat "$STATE_DIR/$1.last-ok" 2>/dev/null || printf '(absent)'; }          # STORE → its last-ok
# committed_body_of PATH — PATH's body in the alpha store's HEAD, so a row pins the commit as well as the tree.
committed_body_of() { git -C "$ALPHA_DIR" show "HEAD:$1" 2>/dev/null || printf '(absent)'; }
# tree_state — "tree is HEAD" when the alpha store's tree holds exactly what HEAD does, untracked files included.
tree_state() { [[ -z "$(git -C "$ALPHA_DIR" status --porcelain --untracked-files=all 2>&1)" ]] && printf 'tree is HEAD'; }
merge_head_state() { [[ -e "$ALPHA_DIR/.git/MERGE_HEAD" ]] && printf 'a merge in progress'; }

# conflict_copies DIR — every conflict copy under DIR outside .git, sorted, each followed by a space.
conflict_copies() {
    (cd "$1" && find . -path ./.git -prune -o -name '*.conflict-*' -print) | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' '
}

# calls_of SUBCOMMAND — how many logged git calls ran SUBCOMMAND.
calls_of() {
    local logged_call calls=0
    while IFS= read -r logged_call; do
        if [[ "$logged_call" == "$1 "* ]]; then calls=$(( calls + 1 )); fi
    done < "$FIXTURE_GIT_ENV_LOG"
    printf '%s' "$calls"
}

# stamp_now_minus MINUTES — the epoch MINUTES ago.
stamp_now_minus() {
    local now
    printf -v now '%(%s)T' -1
    printf '%s' $(( now - $1 * SECONDS_PER_MINUTE ))
}

# write_status_fixture STORE OUTCOME DETAIL [LAST_OK_EPOCH] — a status the sync could have written, and
# a last-ok when one is given.
write_status_fixture() {
    local now
    mkdir -p "$STATE_DIR" || fatal "could not create the state dir"
    printf -v now '%(%s)T' -1
    printf '%s\t%s\t%s\n' "$now" "$2" "$3" > "$STATE_DIR/$1.status" || fatal "could not write a status"
    rm -f "$STATE_DIR/$1.last-ok"
    if [[ -n "${4:-}" ]]; then printf '%s\n' "$4" > "$STATE_DIR/$1.last-ok" || fatal "could not write a last-ok"; fi
}

# set_stale_after HOST_MINUTES DEFAULT_MINUTES — the table's stale_after_minutes, either one left out
# when empty, and the key left out when both are.
set_stale_after() {
    jq --arg host "$FIXTURE_HOST" --arg host_minutes "$1" --arg default_minutes "$2" '
        del(.stale_after_minutes)
        | if $host_minutes != "" then .stale_after_minutes[$host] = ($host_minutes | tonumber) else . end
        | if $default_minutes != "" then .stale_after_minutes.default = ($default_minutes | tonumber) else . end' \
        "$CONFIG" > "$CONFIG.new" || fatal "could not set stale_after_minutes"
    mv "$CONFIG.new" "$CONFIG" || fatal "could not replace the table"
}

commit_count() { git -C "$1" rev-list --count HEAD 2>/dev/null || printf '0'; }   # DIR → commits on HEAD
head_subject() { git -C "$1" log -1 --format=%s 2>/dev/null; }                     # DIR → HEAD's subject

# head_files DIR — every path in HEAD's tree, sorted, each followed by a space.
head_files() { git -C "$1" ls-tree -r --name-only HEAD 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }

# index_files DIR — every path in DIR's index, sorted, each followed by a space.
index_files() { git -C "$1" ls-files 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }

# commit_header_names DIR — the names of HEAD's header lines (tree, parent, author, …, gpgsig).
commit_header_names() {
    git -C "$1" cat-file commit HEAD 2>/dev/null | sed '/^$/,$d' | cut -d' ' -f1 | tr '\n' ' '
}

status_line_of() { cat "$STATE_DIR/$1.status" 2>/dev/null; }          # STORE → its status line
status_field_of() { status_line_of "$1" | cut -f"$2"; }                # STORE FIELD → one field of it

# tree_fingerprint DIR — one hash of every path under DIR, its kind and its content, .git included,
# so that any write the script makes there, an index refresh among them, changes it.
tree_fingerprint() {
    (
        cd "$1" || exit 2
        find . -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' path; do
            if [[ -L "$path" ]]; then printf 'L %s %s\n' "$path" "$(readlink "$path")"
            elif [[ -f "$path" ]]; then printf 'F %s %s\n' "$path" "$(sha256sum < "$path")"
            else printf 'D %s\n' "$path"
            fi
        done
    ) | sha256sum
}

# run_sut ARGS… → combined output in $OUT, exit status in $RC. Every override is always set; a row
# shortens the lock wait, the run deadline or the gh-route limit by calling it as
# SUT_LOCK_WAIT_SECONDS=<n> run_sut …, and likewise SUT_RUN_DEADLINE_SECONDS or SUT_GH_ROUTE_TIMEOUT_SECONDS;
# SUT_UPTIME_FILE hands it the fixture clock.
SUT_RUNNER_PREFIX=()
SUT_LOCK_WAIT_SECONDS=$LOCK_WAIT_SECONDS_FOR_ROWS
SUT_RUN_DEADLINE_SECONDS=$RUN_DEADLINE_SECONDS_FOR_ROWS
SUT_GH_ROUTE_TIMEOUT_SECONDS=$GH_ROUTE_TIMEOUT_SECONDS_FOR_ROWS
SUT_UPTIME_FILE=$REAL_UPTIME_FILE
run_sut() {
    OUT=$(CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" CLAUDE_MEMORY_STORES_ROOT="$STORES_ROOT" \
        CLAUDE_MEMORY_CONFIG="$CONFIG" CLAUDE_MEMORY_STATE_DIR="$STATE_DIR" \
        CLAUDE_MEMORY_HOST="$FIXTURE_HOST" CLAUDE_MEMORY_TENANT_ROUTE="$ROUTE_STUB" \
        CLAUDE_MEMORY_GH_ROUTE="$GH_ROUTE_STUB" CLAUDE_MEMORY_LOCK_WAIT_SECONDS="$SUT_LOCK_WAIT_SECONDS" \
        CLAUDE_MEMORY_RUN_DEADLINE_SECONDS="$SUT_RUN_DEADLINE_SECONDS" \
        CLAUDE_MEMORY_GH_ROUTE_TIMEOUT_SECONDS="$SUT_GH_ROUTE_TIMEOUT_SECONDS" CLAUDE_MEMORY_UPTIME_FILE="$SUT_UPTIME_FILE" \
        "${SUT_RUNNER_PREFIX[@]}" "$SUT" "$@" 2>&1); RC=$?
}

# make_beta_tracked_store — the beta store becomes a clone of its own bare remote, a copy of the alpha
# store's remote as it stands, and the table's remote for beta is that remote's path.
make_beta_tracked_store() {
    git clone -q --bare "$REMOTES_DIR/$ALPHA_STORE.git" "$REMOTES_DIR/$BETA_STORE.git" \
        || fatal "could not create the remote of the beta store"
    git clone -q "$REMOTES_DIR/$BETA_STORE.git" "$BETA_DIR" || fatal "could not clone the beta store"
    set_store_remote "$BETA_STORE" "$REMOTES_DIR/$BETA_STORE.git"
}

# network_call_settings FIELDS — for each logged fetch and push, its subcommand and what FIELDS
# (prompt: askpass, prompt and locale; trace: trace variables, curl-verbose, trace-redact) say, each
# call followed by a space.
network_call_settings() {
    local logged_call summary=''
    while IFS= read -r logged_call; do
        [[ "$logged_call" == 'fetch '* || "$logged_call" == 'push '* ]] || continue
        case "$1" in
            prompt) summary+="${logged_call%% trace-variables:*} " ;;
            trace)  summary+="${logged_call%% *} trace-variables:${logged_call#* trace-variables:} " ;;
        esac
    done < "$FIXTURE_GIT_SETTINGS_LOG"
    printf '%s' "$summary"
}

# calls_with_trace_variables — how many logged git calls had a GIT_TRACE variable (GIT_TRACE_REDACT
# aside) or GIT_CURL_VERBOSE in their environment.
calls_with_trace_variables() {
    local logged_call calls=0
    while IFS= read -r logged_call; do
        if [[ "$logged_call" != *' trace-variables: curl-verbose:unset '* ]]; then calls=$(( calls + 1 )); fi
    done < "$FIXTURE_GIT_SETTINGS_LOG"
    printf '%s' "$calls"
}

# wait_for_file PATH — status 0 once PATH exists, 1 when it has not appeared after every look.
wait_for_file() {
    local poll_attempt
    for (( poll_attempt = 0; poll_attempt < LOCK_TAKEN_POLL_ATTEMPTS; poll_attempt++ )); do
        [[ -e "$1" ]] && return 0
        sleep "$LOCK_TAKEN_POLL_INTERVAL_SECONDS"
    done
    [[ -e "$1" ]]
}

# git_write_calls_summary — from the fixture git's call log: for add, reset and commit, how many calls
# ran it, how many of those turned hooks off and how many turned the file-system monitor off; then how
# many commits passed --no-verify.
git_write_calls_summary() {
    local subcommand logged_call calls hooks_off monitor_off no_verify=0 summary=''
    for subcommand in add reset commit; do
        calls=0 hooks_off=0 monitor_off=0
        while IFS= read -r logged_call; do
            [[ " $logged_call " == *" $subcommand "* ]] || continue
            calls=$(( calls + 1 ))
            if [[ " $logged_call " == *" -c core.hooksPath=/dev/null "* ]]; then hooks_off=$(( hooks_off + 1 )); fi
            if [[ " $logged_call " == *" -c core.fsmonitor=false "* ]]; then monitor_off=$(( monitor_off + 1 )); fi
            if [[ "$subcommand" == commit && " $logged_call " == *" --no-verify "* ]]; then no_verify=$(( no_verify + 1 )); fi
        done < "$FIXTURE_GIT_CALL_LOG"
        summary+="$subcommand $calls $hooks_off $monitor_off "
    done
    printf '%sno-verify %s' "$summary" "$no_verify"
}

# run_sut_bounded ARGS… — run_sut for a row whose regression is a hang: the row then fails on exit
# 124, where the table would otherwise never end.
run_sut_bounded() {
    SUT_RUNNER_PREFIX=(timeout --kill-after=5 "$HANG_BOUND_SECONDS")
    run_sut "$@"
    SUT_RUNNER_PREFIX=()
}

contains() { [[ "$1" == *"$2"* ]] && printf yes || printf no; }   # HAYSTACK NEEDLE → yes|no

# ---------------------------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------------------------

printf 'usage: the verbs\n'
reset_scene
run_sut --no-such-verb
check "usage: an unknown argument is exit 64" "$RC|$(contains "$OUT" 'unknown argument: --no-such-verb')" "64|yes"
run_sut --check --apply
check "usage: two verbs are exit 64" "$RC|$(contains "$OUT" 'only one verb allowed')" "64|yes"
run_sut --apply --rev HEAD
check "usage: --rev without --scan is exit 64" "$RC|$(contains "$OUT" '--rev goes with --scan')" "64|yes"
run_sut --apply --store
store_with_nothing="$RC|$(contains "$OUT" '--store needs a store name')"
run_sut --scan --rev
check "usage: --store or --rev with no value is exit 64" \
    "$store_with_nothing|$RC|$(contains "$OUT" '--rev needs a revision')" "64|yes|64|yes"
run_sut --help
check "usage: --help is exit 0 and names every verb and flag" \
    "$RC|$(contains "$OUT" '--check')$(contains "$OUT" '--scan')$(contains "$OUT" '--apply')$(contains "$OUT" '--status')$(contains "$OUT" '--store')$(contains "$OUT" '--rev')" \
    "0|yesyesyesyesyesyes"

# ---------------------------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------------------------

printf 'config: the store table\n'
reset_scene
write_file "$ALPHA_DIR/pending.md" 'pending body'
rm -f "$CONFIG"
store_before=$(tree_fingerprint "$ALPHA_DIR")
run_sut --apply
check "config: absent is exit 0 with the note" \
    "$RC|$OUT|$(tree_fingerprint "$ALPHA_DIR")|$([[ -e "$STATE_DIR" ]] && printf 'made a state dir')" \
    "0|claude-memory-sync: no store table at $CONFIG; nothing to do|$store_before|"

config_shape_results=''
for table in 'not json' '[]' '{"stores": []}' \
    '{"stores": {"alpha-store": {"tenants": ["alpha"]}}}' \
    '{"stores": {"alpha-store": {"remote": "", "tenants": ["alpha"]}}}' \
    '{"stores": {"../up": {"remote": "https://example.invalid/x.git", "tenants": ["alpha"]}}}'; do
    printf '%s\n' "$table" > "$CONFIG"
    run_sut --check
    config_shape_results+="$RC$(contains "$OUT" "$CONFIG") "
done
check "config: a wrong shape is exit 2 naming the table" "$config_shape_results" "2yes 2yes 2yes 2yes 2yes 2yes "

# ---------------------------------------------------------------------------------------------
# commit: stage everything but a partial copy, ignore rules included, and commit it as one
# ---------------------------------------------------------------------------------------------

printf 'commit: stage and commit\n'
reset_scene
write_file "$ALPHA_DIR/old.md" 'old body'
fixture_commit "$ALPHA_DIR" 'seed'
write_file "$ALPHA_DIR/old.md" 'changed body'
write_file "$ALPHA_DIR/topic/new.md" 'new body'
run_sut --apply
check "commit: new and changed files become one commit named <host>: <n> files" \
    "$RC|$OUT|$(commit_count "$ALPHA_DIR")|$(head_subject "$ALPHA_DIR")|$(head_files "$ALPHA_DIR")|$(git -C "$ALPHA_DIR" show HEAD:old.md)" \
    "0|$ALPHA_STORE: committed 2 files|2|$FIXTURE_HOST: 2 files|old.md topic/new.md |changed body"

head_before=$(git -C "$ALPHA_DIR" rev-parse HEAD)
run_sut --apply
# The status detail is the positive half: the row must not pass on a script that does nothing at all.
check "commit: nothing to do writes no commit" \
    "$RC|$OUT|$(git -C "$ALPHA_DIR" rev-parse HEAD)|$(status_field_of "$ALPHA_STORE" 3)" \
    "0||$head_before|nothing to commit"

rm "$ALPHA_DIR/old.md"
run_sut --apply
check "commit: a deletion is committed" \
    "$RC|$OUT|$(head_subject "$ALPHA_DIR")|$(head_files "$ALPHA_DIR")" \
    "0|$ALPHA_STORE: committed 1 files|$FIXTURE_HOST: 1 files|topic/new.md "

reset_scene
write_file "$ALPHA_DIR/signed.md" 'body'
GIT_CONFIG_GLOBAL="$SIGNING_CONFIG" run_sut --apply
check "commit: signing is off even when commit.gpgsign is true in the fixture config" \
    "$RC|$(commit_count "$ALPHA_DIR")|$(commit_header_names "$ALPHA_DIR")|$([[ -e "$SIGNING_CALLS" ]] && printf 'the signer was called')|$(GIT_CONFIG_GLOBAL="$SIGNING_CONFIG" git -C "$ALPHA_DIR" config --get commit.gpgsign)" \
    "0|1|tree author committer ||true"

reset_scene
write_file "$ALPHA_DIR/$GLOBALLY_IGNORED_NAME" 'body'
run_sut --apply
check "commit: a file the global ignore file names is still committed" \
    "$RC|$(head_files "$ALPHA_DIR")|$(git -C "$ALPHA_DIR" check-ignore -q --no-index "$GLOBALLY_IGNORED_NAME" && printf ignored)" \
    "0|$GLOBALLY_IGNORED_NAME |ignored"

reset_scene
printf 'info-excluded.md\n' >> "$ALPHA_DIR/.git/info/exclude"
write_file "$ALPHA_DIR/info-excluded.md" 'body'
run_sut --apply
check "commit: a file .git/info/exclude names is still committed" \
    "$RC|$(head_files "$ALPHA_DIR")|$(git -C "$ALPHA_DIR" check-ignore -q --no-index info-excluded.md && printf ignored)" \
    "0|info-excluded.md |ignored"

reset_scene
write_file "$ALPHA_DIR/sub/.gitignore" 'nested-ignored.md'
write_file "$ALPHA_DIR/sub/nested-ignored.md" 'body'
run_sut --apply
check "commit: a file a nested .gitignore names is still committed" \
    "$RC|$(head_files "$ALPHA_DIR")|$(git -C "$ALPHA_DIR" check-ignore -q --no-index sub/nested-ignored.md && printf ignored)" \
    "0|sub/.gitignore sub/nested-ignored.md |ignored"

reset_scene
write_file "$ALPHA_DIR/kept.md" 'kept body'
write_file "$ALPHA_DIR/.kept.md.link-partial" 'partial body'
write_file "$ALPHA_DIR/deep/er/.x.md.link-partial" 'partial body'
run_sut --apply
check "commit: a .<name>.link-partial is never staged" \
    "$RC|$OUT|$(head_files "$ALPHA_DIR")|$(index_files "$ALPHA_DIR")|$([[ -f "$ALPHA_DIR/.kept.md.link-partial" && -f "$ALPHA_DIR/deep/er/.x.md.link-partial" ]] && printf 'both partials left in place')" \
    "0|$ALPHA_STORE: committed 1 files|kept.md |kept.md |both partials left in place"

# ---------------------------------------------------------------------------------------------
# hooks: nothing runs between the gate and the commit
# ---------------------------------------------------------------------------------------------

printf 'hooks: none run\n'
reset_scene
write_file "$ALPHA_DIR/clean.md" 'clean body'
write_file "$ALPHA_DIR/$FIXTURE_HOOK_STAGED_PATH" "a line carrying $FAKE_TOKEN in prose"
rm -f "$FIXTURE_HOOK_MARKER"
GIT_CONFIG_GLOBAL="$HOOKS_CONFIG" run_sut --apply
fixture_log=$(git -C "$ALPHA_DIR" log -p --all)
hook_mark_after_sync=$([[ -e "$FIXTURE_HOOK_MARKER" ]] && printf 'a hook ran')
# The fixture is only meaningful if its hooks run for a commit that does not turn them off.
GIT_CONFIG_GLOBAL="$HOOKS_CONFIG" git -C "$ALPHA_DIR" commit -q --allow-empty --no-gpg-sign -m 'hook probe' \
    || fatal "could not make the hook probe's commit"
check "hooks: a hook that stages a withheld file never runs, and the token is in no commit" \
    "$RC|$(contains "$fixture_log" "$FAKE_TOKEN")|$(contains "$fixture_log" 'clean body')|$hook_mark_after_sync|$([[ -e "$FIXTURE_HOOK_MARKER" ]] && printf 'the hook runs for plain git')" \
    "0|no|yes||the hook runs for plain git"

reset_scene
write_file "$ALPHA_DIR/clean.md" 'clean body'
write_file "$ALPHA_DIR/notes/leaky.md" "a line carrying $FAKE_TOKEN in prose"
: > "$FIXTURE_GIT_CALL_LOG"
PATH="$GIT_WRAPPER_DIR:$PATH" run_sut --apply
check "hooks: every git call that writes turns hooks and the file-system monitor off, and the commit passes --no-verify" \
    "$RC|$(git_write_calls_summary)" "0|add 1 1 1 reset 1 1 1 commit 1 1 1 no-verify 1"

# A monitor runs on reads as well as writes: the gate's own diff-index under the lock ran it, and the
# file it staged then went into the commit.
reset_scene
write_file "$ALPHA_DIR/clean.md" 'clean body'
write_file "$ALPHA_DIR/$FIXTURE_HOOK_STAGED_PATH" "a line carrying $FAKE_TOKEN in prose"
rm -f "$FIXTURE_FSMONITOR_MARKER"
GIT_CONFIG_GLOBAL="$FSMONITOR_CONFIG" run_sut --apply
fixture_log=$(git -C "$ALPHA_DIR" log -p --all)
monitor_mark_after_sync=$([[ -e "$FIXTURE_FSMONITOR_MARKER" ]] && printf 'the monitor ran')
# The fixture is only meaningful if git runs the monitor for a read that does not turn it off.
GIT_CONFIG_GLOBAL="$FSMONITOR_CONFIG" git -C "$ALPHA_DIR" diff-index --cached --quiet HEAD -- >/dev/null 2>&1
check "hooks: a file-system monitor the host configures never runs, and the token is in no commit" \
    "$RC|$(contains "$fixture_log" "$FAKE_TOKEN")|$(contains "$fixture_log" 'clean body')|$monitor_mark_after_sync|$([[ -e "$FIXTURE_FSMONITOR_MARKER" ]] && printf 'the monitor runs for plain git')" \
    "0|no|yes||the monitor runs for plain git"

# ---------------------------------------------------------------------------------------------
# lock: the link script's lock is held from stage to commit, and only so long
# ---------------------------------------------------------------------------------------------

printf 'lock: the link script lock\n'
reset_scene
write_file "$ALPHA_DIR/early.md" 'early body'
mkdir -p "$STATE_DIR" || fatal "could not create the state dir"
lock_taken_file="$TMPROOT/lock-taken"
lock_release_file="$TMPROOT/lock-release"
rm -f "$lock_taken_file"
# The holder writes late.md as the link script would, still under the lock: a sync that waited for the
# lock before staging commits it, and one that did not has already committed without it.
# shellcheck disable=SC2016  # expanded by the bash -c, not this one
flock "$LINK_LOCK" bash -c ': > "$1"; sleep "$3"; printf "late body\n" > "$2"' \
    _ "$lock_taken_file" "$ALPHA_DIR/late.md" "$LOCK_HOLD_SECONDS" &
lock_holder_pid=$!
wait_for_file "$lock_taken_file" || fatal "the row's lock holder never took the lock"
run_sut_bounded --apply
check "lock: the sync waits for link.lock" \
    "$RC|$OUT|$(head_files "$ALPHA_DIR")" "0|$ALPHA_STORE: committed 2 files|early.md late.md "
wait "$lock_holder_pid"

reset_scene
write_file "$ALPHA_DIR/a.md" 'a body'
rm -f "$FIXTURE_LOCK_PROBE_RESULT"
PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GIT_ON_COMMIT=probe-lock run_sut --apply
check "lock: link.lock is still held while the commit runs" \
    "$RC|$OUT|$(cat "$FIXTURE_LOCK_PROBE_RESULT" 2>/dev/null)" "0|$ALPHA_STORE: committed 1 files|held"

reset_scene
write_file "$ALPHA_DIR/a.md" 'a body'
rm -f "$FIXTURE_LEFTOVER_CHILD_PID"
PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GIT_ON_COMMIT=leave-child run_sut --apply
lock_after_run=$(flock -n "$LINK_LOCK" true && printf free || printf held)
leftover_child_pid=$(cat "$FIXTURE_LEFTOVER_CHILD_PID" 2>/dev/null)
# The row can only see the fault while the child the commit left behind is still alive.
leftover_child_state=$([[ -n "$leftover_child_pid" ]] && kill -0 "$leftover_child_pid" 2>/dev/null && printf 'still running')
if [[ -n "$leftover_child_pid" ]]; then kill "$leftover_child_pid" 2>/dev/null; fi
check "lock: a child git leaves behind does not hold link.lock once the sync has exited" \
    "$RC|$OUT|$leftover_child_state|$lock_after_run" "0|$ALPHA_STORE: committed 1 files|still running|free"

reset_scene
write_file "$ALPHA_DIR/pending.md" 'pending body'
mkdir -p "$STATE_DIR" || fatal "could not create the state dir"
rm -f "$lock_taken_file" "$lock_release_file"
# This holder keeps the lock until the row lets it go, or TIMEOUT_ROW_HOLD_SECONDS at most.
# shellcheck disable=SC2016  # expanded by the bash -c, not this one
flock "$LINK_LOCK" timeout "$TIMEOUT_ROW_HOLD_SECONDS" \
    bash -c ': > "$1"; while [[ ! -e "$2" ]]; do sleep "$3"; done' \
    _ "$lock_taken_file" "$lock_release_file" "$LOCK_TAKEN_POLL_INTERVAL_SECONDS" &
lock_holder_pid=$!
wait_for_file "$lock_taken_file" || fatal "the row's lock holder never took the lock"
store_before=$(tree_fingerprint "$ALPHA_DIR")
SUT_LOCK_WAIT_SECONDS=$LOCK_WAIT_SECONDS_SHORT run_sut_bounded --apply
: > "$lock_release_file"
wait "$lock_holder_pid"
check "lock: a lock still held when the wait runs out is could-not-run naming it, and nothing is staged" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: the lock $LINK_LOCK was still held after $LOCK_WAIT_SECONDS_SHORT s")|$(tree_fingerprint "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)" \
    "2|yes|$store_before|could-not-run"

# ---------------------------------------------------------------------------------------------
# gate: a file with a credential shape is withheld, the rest sync, and the value goes nowhere
# ---------------------------------------------------------------------------------------------

printf 'gate: credential shapes\n'
reset_scene
write_file "$ALPHA_DIR/clean.md" 'clean body'
write_file "$ALPHA_DIR/notes/leaky.md" "a line carrying $FAKE_TOKEN in prose"
run_sut --apply
check "gate: a file with a token shape is withheld and the others are committed" \
    "$RC|$(head_files "$ALPHA_DIR")|$(head_subject "$ALPHA_DIR")|$(index_files "$ALPHA_DIR")|$([[ -f "$ALPHA_DIR/notes/leaky.md" ]] && printf 'still on disk')" \
    "0|clean.md |$FIXTURE_HOST: 1 files|clean.md |still on disk"
check "gate: the token value is in neither stdout nor stderr" \
    "$(contains "$OUT" "$FAKE_TOKEN")|$OUT" \
    "no|$ALPHA_STORE: withheld notes/leaky.md (github-token)${NL}$ALPHA_STORE: committed 1 files"
fixture_log=$(git -C "$ALPHA_DIR" log -p --all)
check "gate: the token value is in no commit" \
    "$(contains "$fixture_log" "$FAKE_TOKEN")|$(contains "$fixture_log" 'clean body')|$(commit_count "$ALPHA_DIR")" "no|yes|1"
check "status: outcome withheld names the file" \
    "$([[ "$(status_field_of "$ALPHA_STORE" 1)" =~ ^[0-9]+$ ]] && printf 'an epoch')|$(status_field_of "$ALPHA_STORE" 2)|$(status_field_of "$ALPHA_STORE" 3)|$(contains "$(status_line_of "$ALPHA_STORE")" "$FAKE_TOKEN")" \
    "an epoch|withheld|notes/leaky.md|no"
run_sut --apply
check "gate: the next run names the withheld file again" \
    "$RC|$OUT|$(commit_count "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)|$(index_files "$ALPHA_DIR")" \
    "0|$ALPHA_STORE: withheld notes/leaky.md (github-token)|1|withheld|clean.md "

reset_scene
write_file "$ALPHA_DIR/prose.md" 'set FOO_TOKEN=plainvalue in the shell first'
# The fixture is only meaningful if the full redactor, by-name rules included, would change it.
prose_fully_redacted=$("$REDACTOR" < "$ALPHA_DIR/prose.md")
prose_as_written=$(< "$ALPHA_DIR/prose.md")
run_sut --apply
check "gate: FOO_TOKEN=plainvalue in prose is committed" \
    "$RC|$OUT|$(head_files "$ALPHA_DIR")|$([[ "$prose_fully_redacted" != "$prose_as_written" ]] && printf 'the by-name rule changes it')" \
    "0|$ALPHA_STORE: committed 1 files|prose.md |the by-name rule changes it"

# A name is gated as a body is: a token in a file's name would reach the remote in the tree.
TOKEN_NAMED_FILE="notes-$FAKE_TOKEN.md"
REDACTED_TOKEN_NAMED_FILE="notes-$REDACTED_FAKE_TOKEN.md"
reset_scene
write_file "$ALPHA_DIR/clean.md" 'clean body'
write_file "$ALPHA_DIR/$TOKEN_NAMED_FILE" 'a clean body under a leaky name'
run_sut --apply
fixture_log=$(git -C "$ALPHA_DIR" log -p --all)
check "gate: a file whose name carries a token shape is withheld" \
    "$RC|$(head_files "$ALPHA_DIR")|$(index_files "$ALPHA_DIR")|$(contains "$fixture_log" "$FAKE_TOKEN")|$([[ -f "$ALPHA_DIR/$TOKEN_NAMED_FILE" ]] && printf 'still on disk')" \
    "0|clean.md |clean.md |no|still on disk"
check "gate: a withheld name is redacted in the output and in the status file" \
    "$OUT|$(contains "$OUT" "$FAKE_TOKEN")|$(status_field_of "$ALPHA_STORE" 2)|$(status_field_of "$ALPHA_STORE" 3)|$(contains "$(status_line_of "$ALPHA_STORE")" "$FAKE_TOKEN")" \
    "$ALPHA_STORE: withheld $REDACTED_TOKEN_NAMED_FILE (github-token)${NL}$ALPHA_STORE: committed 1 files|no|withheld|$REDACTED_TOKEN_NAMED_FILE|no"

# ---------------------------------------------------------------------------------------------
# status: one line per store, epoch<TAB>outcome<TAB>detail
# ---------------------------------------------------------------------------------------------

printf 'status: the outcome of a run\n'
reset_scene
write_file "$ALPHA_DIR/a.md" 'a body'
printf -v epoch_before '%(%s)T' -1
run_sut --apply
printf -v epoch_after '%(%s)T' -1
status_epoch=$(status_field_of "$ALPHA_STORE" 1)
check "status: ok-local-only when there is no origin" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|$(status_field_of "$ALPHA_STORE" 3)|$([[ "$status_epoch" =~ ^[0-9]+$ ]] && (( status_epoch >= epoch_before && status_epoch <= epoch_after )) && printf 'stamped now')" \
    "0|ok-local-only|committed 1 files|stamped now"

# ---------------------------------------------------------------------------------------------
# scan: the gate, for commits the sync did not make
# ---------------------------------------------------------------------------------------------

printf 'scan: committed trees\n'
reset_scene
write_file "$ALPHA_DIR/clean.md" 'clean body'
fixture_commit "$ALPHA_DIR" 'clean'
run_sut --scan
check "scan: a clean tree is exit 0 with no output" "$RC|$OUT" "0|"

write_file "$ALPHA_DIR/notes/leaky.md" "carries $FAKE_TOKEN"
fixture_commit "$ALPHA_DIR" 'leaky'
run_sut --scan
check "scan: a committed file with a token shape is named with its rule label, exit 1, value absent from the output" \
    "$RC|$OUT|$(contains "$OUT" "$FAKE_TOKEN")" "1|$ALPHA_STORE: notes/leaky.md (github-token)|no"

git -C "$ALPHA_DIR" rm -q notes/leaky.md || fatal "could not remove the leaky file"
git -C "$ALPHA_DIR" commit -q --no-gpg-sign -m 'drop leaky' || fatal "could not commit the removal"
run_sut --scan
scan_of_head="$RC|$OUT"
run_sut --scan --rev HEAD~1
check "scan: --rev scans that revision, not HEAD" \
    "$scan_of_head|$RC|$OUT" "0||1|$ALPHA_STORE: notes/leaky.md (github-token)"

reset_scene
write_file "$ALPHA_DIR/$TOKEN_NAMED_FILE" 'a clean body under a leaky name'
fixture_commit "$ALPHA_DIR" 'leaky name'
run_sut --scan
check "scan: a committed file whose name carries a token shape is named redacted, exit 1" \
    "$RC|$OUT|$(contains "$OUT" "$FAKE_TOKEN")" "1|$ALPHA_STORE: $REDACTED_TOKEN_NAMED_FILE (github-token)|no"

# ---------------------------------------------------------------------------------------------
# origin: a store pushes only to its own remote
# ---------------------------------------------------------------------------------------------

printf 'origin: the table names the remote\n'
reset_scene
git -C "$ALPHA_DIR" remote add origin "$OTHER_REMOTE" || fatal "could not add an origin"
write_file "$ALPHA_DIR/pending.md" 'pending body'
store_before=$(tree_fingerprint "$ALPHA_DIR")
run_sut --apply
check "origin: a remote other than the table's is could-not-run, exit 2, and nothing is staged" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: origin is not the table's remote")|$(contains "$OUT" 'other-memory')|$(tree_fingerprint "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)" \
    "2|yes|no|$store_before|could-not-run"
run_sut --check
check "origin: --check names a remote other than the table's, exit 2" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: origin is not the table's remote")|$(tree_fingerprint "$ALPHA_DIR")" \
    "2|yes|$store_before"

reset_scene
git -C "$ALPHA_DIR" remote add origin "$ALPHA_REMOTE" || fatal "could not add an origin"
git -C "$ALPHA_DIR" remote set-url --push origin "$OTHER_REMOTE" || fatal "could not set a push URL"
write_file "$ALPHA_DIR/pending.md" 'pending body'
store_before=$(tree_fingerprint "$ALPHA_DIR")
run_sut --apply
check "origin: a push URL other than the table's is could-not-run, and nothing is staged" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: origin is not the table's remote")|$(tree_fingerprint "$ALPHA_DIR")" \
    "2|yes|$store_before"

reset_scene
write_file "$ALPHA_DIR/notes/leaky.md" "carries $FAKE_TOKEN"
fixture_commit "$ALPHA_DIR" 'leaky'
git -C "$ALPHA_DIR" remote add origin "$OTHER_REMOTE" || fatal "could not add an origin"
run_sut --scan
check "origin: --scan names a remote other than the table's, exit 2, and scans nothing" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: origin is not the table's remote")|$(contains "$OUT" 'leaky.md')" \
    "2|yes|no"

# ---------------------------------------------------------------------------------------------
# check: what --apply would do, read-only
# ---------------------------------------------------------------------------------------------

printf 'check: read-only\n'
reset_scene
write_file "$ALPHA_DIR/seeded.md" 'seed body'
write_file "$ALPHA_DIR/stat-only.md" 'unchanged body'
fixture_commit "$ALPHA_DIR" 'seed'
write_file "$ALPHA_DIR/seeded.md" 'changed body'
write_file "$ALPHA_DIR/new.md" 'new body'
write_file "$ALPHA_DIR/$GLOBALLY_IGNORED_NAME" 'ignored, and memory all the same'
# A tracked file whose mtime moved and whose content did not: git refreshes its index entry, and left
# to itself writes the index back, which is the write --check must not make. Not pending: same content.
touch -m -t "$FUTURE_MTIME_STAMP" "$ALPHA_DIR/stat-only.md" || fatal "could not move the mtime of stat-only.md"
store_before=$(tree_fingerprint "$ALPHA_DIR")
git_status_before=$(GIT_OPTIONAL_LOCKS=0 git -C "$ALPHA_DIR" status --porcelain --ignored)
run_sut --check
check "check: pending is exit 1 and writes nothing" \
    "$RC|$OUT|$(tree_fingerprint "$ALPHA_DIR")|$([[ -e "$STATE_DIR" ]] && printf 'made a state dir')|$(GIT_OPTIONAL_LOCKS=0 git -C "$ALPHA_DIR" status --porcelain --ignored)" \
    "1|$ALPHA_STORE: 3 pending, 0 withheld, no fetched origin|$store_before||$git_status_before"

reset_scene
write_file "$ALPHA_DIR/kept.md" 'kept body'
fixture_commit "$ALPHA_DIR" 'seed'
write_file "$ALPHA_DIR/.kept.md.link-partial" 'partial body'
write_file "$ALPHA_DIR/deep/er/.x.md.link-partial" 'partial body'
run_sut --check
check "check: a leftover .<name>.link-partial is not pending" \
    "$RC|$OUT" "0|$ALPHA_STORE: 0 pending, 0 withheld, no fetched origin"

reset_scene
write_file "$ALPHA_DIR/clean.md" 'clean body'
write_file "$ALPHA_DIR/notes/leaky.md" "a line carrying $FAKE_TOKEN in prose"
run_sut --check
check "check: a file with a token shape is named as withheld, never its value" \
    "$RC|$OUT|$(contains "$OUT" "$FAKE_TOKEN")" \
    "1|$ALPHA_STORE: 1 pending, 1 withheld, no fetched origin${NL}$ALPHA_STORE: withheld notes/leaky.md (github-token)|no"

reset_scene
write_file "$ALPHA_DIR/clean.md" 'clean body'
write_file "$ALPHA_DIR/$TOKEN_NAMED_FILE" 'a clean body under a leaky name'
run_sut --check
check "check: a file whose name carries a token shape is counted withheld, its name redacted" \
    "$RC|$OUT|$(contains "$OUT" "$FAKE_TOKEN")" \
    "1|$ALPHA_STORE: 1 pending, 1 withheld, no fetched origin${NL}$ALPHA_STORE: withheld $REDACTED_TOKEN_NAMED_FILE (github-token)|no"

# The fixture cat gives being-written.md a different body at every read: two reads disagree as they
# would across a session's write, and a verdict from two reads would withhold a file with no shape.
reset_scene
write_file "$ALPHA_DIR/being-written.md" 'first body'
rm -f "$FIXTURE_CAT_READ_COUNT"
PATH="$CAT_STUB_DIR:$PATH" FIXTURE_CAT_TARGET="$ALPHA_DIR/being-written.md" run_sut --check
check "check: a file is read once for its verdict, so a write between two reads withholds nothing" \
    "$RC|$OUT|$(cat "$FIXTURE_CAT_READ_COUNT" 2>/dev/null)" \
    "1|$ALPHA_STORE: 1 pending, 0 withheld, no fetched origin|1"

# What cat says about a file it cannot read names the file: here a name that carries a token shape.
reset_scene
write_file "$ALPHA_DIR/$TOKEN_NAMED_FILE" 'a clean body under a leaky name'
chmod 000 "$ALPHA_DIR/$TOKEN_NAMED_FILE"
token_named_file_state=$([[ -r "$ALPHA_DIR/$TOKEN_NAMED_FILE" ]] || printf unreadable)
run_sut --check
chmod 644 "$ALPHA_DIR/$TOKEN_NAMED_FILE"
check "check: an unreadable file whose name carries a token shape is named redacted, and the shape is in no line" \
    "$RC|$(contains "$OUT" "$FAKE_TOKEN")|$(contains "$OUT" "$ALPHA_STORE: could not read $REDACTED_TOKEN_NAMED_FILE")|$token_named_file_state" \
    "2|no|yes|unreadable"

# git status warns about a directory it cannot open, by name. The mode goes back before the row, or
# the fixture root cannot be removed.
TOKEN_NAMED_DIR="dir-$FAKE_TOKEN"
reset_scene
write_file "$ALPHA_DIR/$TOKEN_NAMED_DIR/inner.md" 'inner body'
chmod 000 "$ALPHA_DIR/$TOKEN_NAMED_DIR"
run_sut --check
chmod 755 "$ALPHA_DIR/$TOKEN_NAMED_DIR"
check "check: git's warning about an unreadable directory whose name carries a token shape is redacted" \
    "$(contains "$OUT" "$FAKE_TOKEN")|$(contains "$OUT" "could not open directory 'dir-$REDACTED_FAKE_TOKEN/'")" \
    "no|yes"

reset_scene
make_tracked_store "$ALPHA_STORE"
seed_push second.md
git -C "$ALPHA_DIR" fetch -q || fatal "could not fetch into the alpha store"
write_file "$ALPHA_DIR/local.md" 'local body'
fixture_commit "$ALPHA_DIR" 'local'
seed_push third.md
fetched_ref_before=$(git -C "$ALPHA_DIR" rev-parse refs/remotes/origin/main)
run_sut --check
check "check: ahead and behind count against the last-fetched origin ref, and nothing is fetched" \
    "$RC|$OUT|$(git -C "$ALPHA_DIR" rev-parse refs/remotes/origin/main)" \
    "0|$ALPHA_STORE: 0 pending, 0 withheld, ahead 1 behind 1|$fetched_ref_before"

# ---------------------------------------------------------------------------------------------
# store: which stores a run touches
# ---------------------------------------------------------------------------------------------

printf 'store: which stores a run touches\n'
reset_scene
git init -q -b main "$BETA_DIR" || fatal "could not create the beta store"
write_file "$ALPHA_DIR/a.md" 'a body'
write_file "$BETA_DIR/b.md" 'b body'
run_sut --apply --store "$BETA_STORE"
check "store: --store limits the run" \
    "$RC|$OUT|$(commit_count "$ALPHA_DIR")|$(commit_count "$BETA_DIR")|$([[ -e "$STATE_DIR/$ALPHA_STORE.status" ]] && printf 'alpha has a status')" \
    "0|$BETA_STORE: committed 1 files|0|1|"

reset_scene
write_file "$ALPHA_DIR/a.md" 'a body'
run_sut --apply
apply_without_beta="$RC|$OUT"
run_sut --check
check "store: a configured store with no checkout is skipped silently" \
    "$apply_without_beta|$RC|$OUT|$([[ -e "$STATE_DIR/$BETA_STORE.status" ]] && printf 'beta has a status')" \
    "0|$ALPHA_STORE: committed 1 files|0|$ALPHA_STORE: 0 pending, 0 withheld, no fetched origin|"

run_sut --check --store no-such-store
check "store: --store naming no store in the table is exit 2" \
    "$RC|$(contains "$OUT" 'no store named no-such-store in')" "2|yes"

# ---------------------------------------------------------------------------------------------
# network: fetch, merge, push, and what each outcome leaves
# ---------------------------------------------------------------------------------------------

printf 'network: push and pull\n'
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
printf -v epoch_before '%(%s)T' -1
run_sut --apply
printf -v epoch_after '%(%s)T' -1
last_ok_epoch=$(last_ok_of "$ALPHA_STORE")
check "push: a local commit reaches origin and last-ok is written" \
    "$RC|$OUT|$(remote_head)|$(status_field_of "$ALPHA_STORE" 2)|$([[ "$last_ok_epoch" =~ ^[0-9]+$ ]] && (( last_ok_epoch >= epoch_before && last_ok_epoch <= epoch_after )) && printf 'stamped now')" \
    "0|$ALPHA_STORE: committed 1 files${NL}$ALPHA_STORE: pushed|$(local_head)|ok|stamped now"

# The local commit is the fixture's, so the run has a commit to integrate past: a rebase would write
# local.md again, and the merge leaves it alone.
reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push remote-only.md 'remote-only body'
write_file "$ALPHA_DIR/local.md" 'local body'
fixture_commit "$ALPHA_DIR" 'local'
touch -m -t "$PAST_MTIME_STAMP" "$ALPHA_DIR/local.md" "$ALPHA_DIR/seed.md" || fatal "could not move the mtimes back"
mtimes_before="$(mtime_of "$ALPHA_DIR/local.md") $(mtime_of "$ALPHA_DIR/seed.md")"
run_sut --apply
check "pull: a remote-only file arrives and local files keep their mtime" \
    "$RC|$(body_of "$ALPHA_DIR/remote-only.md")|$(mtime_of "$ALPHA_DIR/local.md") $(mtime_of "$ALPHA_DIR/seed.md")|$(status_field_of "$ALPHA_STORE" 2)|$(remote_head)" \
    "0|remote-only body|$mtimes_before|ok|$(local_head)"

printf 'integrate: both sides changed\n'
reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push theirs.md 'their body'
write_file "$ALPHA_DIR/ours.md" 'our body'
run_sut --apply
check "integrate: different files on both sides merge with no conflict copy" \
    "$RC|$(head_files "$ALPHA_DIR")|$(conflict_copies "$ALPHA_DIR")|$(parent_count "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)|$(remote_head)" \
    "0|MEMORY.md ours.md seed.md theirs.md ||3|ok|$(local_head)"

reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push seed.md 'remote body'
write_file "$ALPHA_DIR/seed.md" 'local body'
run_sut --apply
check "integrate: both edited one file keeps both bodies, and the conflict copy is the local one" \
    "$RC|$(committed_body_of "seed.md")|$(committed_body_of "seed.conflict-$FIXTURE_HOST.md")|$(conflict_copies "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)|$(head_subject "$ALPHA_DIR")|$(merge_head_state)|$(remote_head)|$(tree_state)" \
    "0|remote body|local body|seed.conflict-$FIXTURE_HOST.md |kept-both|$FIXTURE_HOST: merge, kept both for 1 files||$(local_head)|tree is HEAD"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$SEED_DIR/topic.md" 'remote topic'
printf '%s\n' "$REMOTE_INDEX_LINE" >> "$SEED_DIR/MEMORY.md"
fixture_commit "$SEED_DIR" 'remote topic'
git -C "$SEED_DIR" push -q "$REMOTES_DIR/$ALPHA_STORE.git" main || fatal "could not push the remote topic"
write_file "$ALPHA_DIR/topic.md" 'local topic'
printf '%s\n' "$LOCAL_INDEX_LINE" >> "$ALPHA_DIR/MEMORY.md"
run_sut --apply
check "integrate: both added one name keeps both bodies, the conflict copy is the local one, and the index holds both lines" \
    "$RC|$(committed_body_of "topic.md")|$(committed_body_of "topic.conflict-$FIXTURE_HOST.md")|$(committed_body_of "MEMORY.md")|$(status_field_of "$ALPHA_STORE" 2)|$(merge_head_state)|$(remote_head)|$(tree_state)" \
    "0|remote topic|local topic|$SEED_INDEX_LINE${NL}$REMOTE_INDEX_LINE${NL}$LOCAL_INDEX_LINE|kept-both||$(local_head)|tree is HEAD"

reset_scene
make_tracked_store "$ALPHA_STORE"
printf '%s\n' "$REMOTE_INDEX_LINE" >> "$SEED_DIR/MEMORY.md"
fixture_commit "$SEED_DIR" 'remote index line'
git -C "$SEED_DIR" push -q "$REMOTES_DIR/$ALPHA_STORE.git" main || fatal "could not push the remote index line"
printf '%s\n' "$LOCAL_INDEX_LINE" >> "$ALPHA_DIR/MEMORY.md"
run_sut --apply
check "integrate: index lines added on both sides are unioned with no conflict copy" \
    "$RC|$(committed_body_of "MEMORY.md")|$(conflict_copies "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)|$(remote_head)|$(tree_state)" \
    "0|$SEED_INDEX_LINE${NL}$REMOTE_INDEX_LINE${NL}$LOCAL_INDEX_LINE||kept-both|$(local_head)|tree is HEAD"

# The layout the real stores have: a .gitattributes naming git's union driver for every index. Read, it
# resolves each index inside the merge, ours first and the line both hosts wrote twice, and the sync's
# own union never runs.
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$SEED_DIR/.gitattributes" "$STORE_UNION_ATTRIBUTES"
write_file "$SEED_DIR/$TOPIC_INDEX_NAME" "$SEED_INDEX_LINE"
fixture_commit "$SEED_DIR" 'union attributes and a topic index'
git -C "$SEED_DIR" push -q "$REMOTES_DIR/$ALPHA_STORE.git" main || fatal "could not push the attributes"
pull_into_alpha
for index_name in MEMORY.md "$TOPIC_INDEX_NAME"; do
    printf '%s\n%s\n' "$INDEX_LINE_ONLY_REMOTE" "$INDEX_LINE_BOTH_HOSTS" >> "$SEED_DIR/$index_name"
    printf '%s\n%s\n' "$INDEX_LINE_BOTH_HOSTS" "$INDEX_LINE_ONLY_LOCAL" >> "$ALPHA_DIR/$index_name"
done
fixture_commit "$SEED_DIR" 'remote index lines'
git -C "$SEED_DIR" push -q "$REMOTES_DIR/$ALPHA_STORE.git" main || fatal "could not push the remote index lines"
run_sut --apply
union_index_body="$SEED_INDEX_LINE${NL}$INDEX_LINE_ONLY_REMOTE${NL}$INDEX_LINE_BOTH_HOSTS${NL}$INDEX_LINE_ONLY_LOCAL"
check "integrate: under the stores' own merge=union attributes, MEMORY.md takes the sync's union, origin's lines first and each once" \
    "$RC|$(committed_body_of MEMORY.md)|$(conflict_copies "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)|$(status_field_of "$ALPHA_STORE" 3)|$(remote_head)|$(tree_state)" \
    "0|$union_index_body||kept-both|kept both for 2 files|$(local_head)|tree is HEAD"
check "integrate: ...and an INDEX_*.md takes it likewise" "$(committed_body_of "$TOPIC_INDEX_NAME")" "$union_index_body"

reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push seed.md 'remote edit'
rm "$ALPHA_DIR/seed.md"
run_sut --apply
check "integrate: deleted here, edited there is present with their body" \
    "$RC|$(committed_body_of "seed.md")|$(conflict_copies "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)|$(merge_head_state)|$(remote_head)|$(tree_state)" \
    "0|remote edit||kept-both||$(local_head)|tree is HEAD"

reset_scene
make_tracked_store "$ALPHA_STORE"
seed_remove_push seed.md
write_file "$ALPHA_DIR/seed.md" 'local edit'
run_sut --apply
check "integrate: edited here, deleted there is present with our body" \
    "$RC|$(committed_body_of "seed.md")|$(conflict_copies "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)|$(merge_head_state)|$(remote_head)|$(tree_state)" \
    "0|local edit||kept-both||$(local_head)|tree is HEAD"

reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push "seed.conflict-$FIXTURE_HOST.md" 'an older copy'
pull_into_alpha
seed_write_push seed.md 'remote body'
write_file "$ALPHA_DIR/seed.md" 'local body'
run_sut --apply
check "integrate: an existing conflict copy is never overwritten, and the next is numbered .2" \
    "$RC|$(committed_body_of "seed.md")|$(committed_body_of "seed.conflict-$FIXTURE_HOST.md")|$(committed_body_of "seed.conflict-$FIXTURE_HOST.2.md")|$(status_field_of "$ALPHA_STORE" 2)|$(tree_state)" \
    "0|remote body|an older copy|local body|kept-both|tree is HEAD"

# With renames off a rename is a deletion and an addition, so the edit meets a deletion.
reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push seed.md 'remote edit'
mv "$ALPHA_DIR/seed.md" "$ALPHA_DIR/renamed.md" || fatal "could not rename seed.md"
run_sut --apply
check "integrate: a rename on one side and an edit on the other loses neither body" \
    "$RC|$(committed_body_of "seed.md")|$(committed_body_of "renamed.md")|$(status_field_of "$ALPHA_STORE" 2)|$(merge_head_state)|$(remote_head)|$(tree_state)" \
    "0|remote edit|seed body|kept-both||$(local_head)|tree is HEAD"

reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push "$FIXTURE_HOOK_STAGED_PATH" 'a clean body from the other host'
write_file "$ALPHA_DIR/$FIXTURE_HOOK_STAGED_PATH" "a line carrying $FAKE_TOKEN in prose"
head_before=$(local_head)
remote_before=$(remote_head)
run_sut --apply
fixture_log=$(git -C "$ALPHA_DIR" log -p --all)
check "integrate: a withheld local file in the merge's way is outcome blocked, exit 0, nothing committed" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|$(contains "$(status_field_of "$ALPHA_STORE" 3)" "$FIXTURE_HOOK_STAGED_PATH")|$(local_head)|$(remote_head)|$(contains "$(body_of "$ALPHA_DIR/$FIXTURE_HOOK_STAGED_PATH")" "$FAKE_TOKEN")|$(merge_head_state)|$(contains "$fixture_log" "$FAKE_TOKEN")|$(contains "$OUT" "$FAKE_TOKEN")" \
    "0|blocked|yes|$head_before|$remote_before|yes||no|no"

reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push theirs.md 'their body'
write_file "$ALPHA_DIR/ours.md" 'our body'
rm -f "$FIXTURE_HOOK_MARKER"
GIT_CONFIG_GLOBAL="$HOOKS_CONFIG" run_sut --apply
check "hooks: no hook runs during the merge or the push" \
    "$RC|$([[ -e "$FIXTURE_HOOK_MARKER" ]] && printf 'a hook ran')|$(parent_count "$ALPHA_DIR")|$(remote_head)" \
    "0||3|$(local_head)"

# The store's first commit is its own, made before it ever fetched: its history and origin's share no
# commit, and a merge that refuses unrelated histories would refuse on every run.
reset_scene
make_tracked_store "$ALPHA_STORE"
rm -rf "$ALPHA_DIR"
git init -q -b main "$ALPHA_DIR" || fatal "could not create the alpha store"
git -C "$ALPHA_DIR" remote add origin "$REMOTES_DIR/$ALPHA_STORE.git" || fatal "could not add the origin"
write_file "$ALPHA_DIR/seed.md" 'local seed body'
write_file "$ALPHA_DIR/own.md" 'own body'
run_sut --apply
check "integrate: an origin that shares no history with the store is merged, keeping both" \
    "$RC|$(committed_body_of "seed.md")|$(committed_body_of "seed.conflict-$FIXTURE_HOST.md")|$(head_files "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)|$(remote_head)|$(tree_state)" \
    "0|seed body|local seed body|MEMORY.md own.md seed.conflict-$FIXTURE_HOST.md seed.md |kept-both|$(local_head)|tree is HEAD"

printf 'branch: the store and its remote on one branch\n'
# A second host that ran `git init` against the remote on another branch name: its merge and its push
# would both aim at origin/<its branch>, which no other host pushes, and every run would say ok.
reset_scene
make_tracked_store "$ALPHA_STORE"
rm -rf "$ALPHA_DIR"
git init -q -b "$OTHER_BRANCH" "$ALPHA_DIR" || fatal "could not create the alpha store"
git -C "$ALPHA_DIR" remote add origin "$REMOTES_DIR/$ALPHA_STORE.git" || fatal "could not add the origin"
write_file "$ALPHA_DIR/own.md" 'own body'
run_sut --apply
check "branch: a store on a branch origin lacks, while origin has another, is could-not-run naming both, with nothing committed or pushed" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: $BRANCH_MISMATCH_REASON")|$(commit_count "$ALPHA_DIR")|$(git -C "$REMOTES_DIR/$ALPHA_STORE.git" for-each-ref --format='%(refname)' refs/heads/)|$(status_field_of "$ALPHA_STORE" 2)|$(status_field_of "$ALPHA_STORE" 3)" \
    "2|yes|0|refs/heads/main|could-not-run|$BRANCH_MISMATCH_REASON"

# The first host to push to an empty remote: origin has no branch at all, and the push makes the store's.
reset_scene
git init -q --bare -b main "$REMOTES_DIR/$ALPHA_STORE.git" || fatal "could not create an empty remote"
git -C "$ALPHA_DIR" remote add origin "$REMOTES_DIR/$ALPHA_STORE.git" || fatal "could not add the origin"
set_store_remote "$ALPHA_STORE" "$REMOTES_DIR/$ALPHA_STORE.git"
write_file "$ALPHA_DIR/own.md" 'own body'
run_sut --apply
check "branch: an origin with no branch at all is no mismatch: the push makes the store's branch" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|$(remote_head)" "0|ok|$(local_head)"

printf 'apply: an operation left unfinished\n'
reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push seed.md 'remote body'
write_file "$ALPHA_DIR/seed.md" 'local body'
fixture_commit "$ALPHA_DIR" 'local'
git -C "$ALPHA_DIR" fetch -q origin || fatal "could not fetch into the alpha store"
git -C "$ALPHA_DIR" merge -q --no-edit origin/main >/dev/null 2>&1
[[ -e "$ALPHA_DIR/.git/MERGE_HEAD" ]] || fatal "the fixture merge did not stop on its conflict"
store_before=$(tree_fingerprint "$ALPHA_DIR")
run_sut --apply
check "apply: a merge in progress is could-not-run, naming it, and nothing is reset" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: a merge is in progress")|$(merge_head_state)|$(tree_fingerprint "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)" \
    "2|yes|a merge in progress|$store_before|could-not-run"

reset_scene
make_tracked_store "$ALPHA_STORE"
git -C "$ALPHA_DIR" checkout -q --detach || fatal "could not detach HEAD"
write_file "$ALPHA_DIR/pending.md" 'pending body'
store_before=$(tree_fingerprint "$ALPHA_DIR")
run_sut --apply
check "apply: a detached HEAD is could-not-run, and nothing is staged" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: HEAD is detached")|$(tree_fingerprint "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)" \
    "2|yes|$store_before|could-not-run"

# A file here where the remote has a directory: git moves the file aside to d~HEAD, an entry added by
# us alone, which is none of the statuses the sync resolves.
reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push d/x.md 'remote body under d'
write_file "$ALPHA_DIR/d" 'local file d'
run_sut --apply
check "apply: no run leaves MERGE_HEAD behind, even on a conflict it cannot resolve" \
    "$RC|$(merge_head_state)|$([[ -e "$ALPHA_DIR/d~HEAD" ]] && printf 'd~HEAD left')|$(body_of "$ALPHA_DIR/d")|$(git -C "$ALPHA_DIR" status --porcelain)|$(status_field_of "$ALPHA_STORE" 2)|$(contains "$OUT" "$ALPHA_STORE: a conflict the sync does not resolve")" \
    "2|||local file d||could-not-run|yes"

# A conflict left in the index with no MERGE_HEAD, as a conflicted `git stash pop` leaves one: a stage
# would take the file with its markers, and a commit would conclude it.
reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push seed.md 'remote body'
write_file "$ALPHA_DIR/seed.md" 'local body'
fixture_commit "$ALPHA_DIR" 'local'
git -C "$ALPHA_DIR" fetch -q origin || fatal "could not fetch into the alpha store"
git -C "$ALPHA_DIR" merge -q --no-edit origin/main >/dev/null 2>&1
rm -f "$ALPHA_DIR/.git/MERGE_HEAD" "$ALPHA_DIR/.git/MERGE_MSG" "$ALPHA_DIR/.git/MERGE_MODE"
[[ -n "$(git -C "$ALPHA_DIR" ls-files -u)" ]] || fatal "the fixture left no unmerged entry"
store_before=$(tree_fingerprint "$ALPHA_DIR")
head_before=$(local_head)
run_sut --apply
check "apply: unmerged index entries with no merge in progress are could-not-run, and no conflict marker is committed" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: the index holds unmerged entries")|$(tree_fingerprint "$ALPHA_DIR")|$(local_head)|$(status_field_of "$ALPHA_STORE" 2)" \
    "2|yes|$store_before|$head_before|could-not-run"

# Each stopped on a conflict that was then staged, so no unmerged entry is left: the marker file alone
# says the operation is unfinished, and a commit would conclude it.
# make_diverged_alpha — a tracked alpha store whose main and a side branch each changed seed.md; sets
# side_commit.
make_diverged_alpha() {
    reset_scene
    make_tracked_store "$ALPHA_STORE"
    git -C "$ALPHA_DIR" checkout -q -b side || fatal "could not branch the alpha store"
    write_file "$ALPHA_DIR/seed.md" 'side body'
    fixture_commit "$ALPHA_DIR" 'side'
    side_commit=$(local_head)
    git -C "$ALPHA_DIR" checkout -q main || fatal "could not go back to main"
    write_file "$ALPHA_DIR/seed.md" 'main body'
    fixture_commit "$ALPHA_DIR" 'main'
}

make_diverged_alpha
git -C "$ALPHA_DIR" cherry-pick "$side_commit" >/dev/null 2>&1
write_file "$ALPHA_DIR/seed.md" 'resolved body'
git -C "$ALPHA_DIR" add seed.md || fatal "could not stage the resolution"
[[ -e "$ALPHA_DIR/.git/CHERRY_PICK_HEAD" && -z "$(git -C "$ALPHA_DIR" ls-files -u)" ]] \
    || fatal "the fixture cherry-pick did not stop resolved"
head_before=$(local_head)
run_sut --apply
cherry_pick_result="$RC|$(contains "$OUT" "$ALPHA_STORE: a cherry-pick is in progress")|$(local_head)|$(status_field_of "$ALPHA_STORE" 2)"
make_diverged_alpha
git -C "$ALPHA_DIR" revert --no-edit "$side_commit" >/dev/null 2>&1
write_file "$ALPHA_DIR/seed.md" 'resolved body'
git -C "$ALPHA_DIR" add seed.md || fatal "could not stage the resolution"
[[ -e "$ALPHA_DIR/.git/REVERT_HEAD" && -z "$(git -C "$ALPHA_DIR" ls-files -u)" ]] \
    || fatal "the fixture revert did not stop resolved"
head_before_revert=$(local_head)
run_sut --apply
check "apply: a cherry-pick or a revert in progress is could-not-run, and nothing is committed" \
    "$cherry_pick_result|$RC|$(contains "$OUT" "$ALPHA_STORE: a revert is in progress")|$(local_head)|$(status_field_of "$ALPHA_STORE" 2)" \
    "2|yes|$head_before|could-not-run|2|yes|$head_before_revert|could-not-run"

# On a reftable store CHERRY_PICK_HEAD is a ref in the table, not a file in the git directory.
reset_scene
rm -rf "$ALPHA_DIR"
git init -q -b main --ref-format=reftable "$ALPHA_DIR" || fatal "could not create a reftable store"
write_file "$ALPHA_DIR/seed.md" 'seed body'
fixture_commit "$ALPHA_DIR" 'seed'
git -C "$ALPHA_DIR" checkout -q -b side || fatal "could not branch the reftable store"
write_file "$ALPHA_DIR/seed.md" 'side body'
fixture_commit "$ALPHA_DIR" 'side'
side_commit=$(local_head)
git -C "$ALPHA_DIR" checkout -q main || fatal "could not go back to main"
write_file "$ALPHA_DIR/seed.md" 'main body'
fixture_commit "$ALPHA_DIR" 'main'
git -C "$ALPHA_DIR" cherry-pick "$side_commit" >/dev/null 2>&1
write_file "$ALPHA_DIR/seed.md" 'resolved body'
git -C "$ALPHA_DIR" add seed.md || fatal "could not stage the resolution"
if ! git -C "$ALPHA_DIR" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null \
    || [[ -n "$(git -C "$ALPHA_DIR" ls-files -u)" ]]; then
    fatal "the reftable cherry-pick did not stop resolved"
fi
reftable_marker_state=$([[ -e "$(git -C "$ALPHA_DIR" rev-parse --path-format=absolute --git-path CHERRY_PICK_HEAD)" ]] \
    || printf 'no file')
head_before=$(local_head)
run_sut --apply
check "apply: a cherry-pick in progress on a reftable store is could-not-run" \
    "$reftable_marker_state|$RC|$(contains "$OUT" "$ALPHA_STORE: a cherry-pick is in progress")|$(local_head)|$(status_field_of "$ALPHA_STORE" 2)" \
    "no file|2|yes|$head_before|could-not-run"

printf 'auth: the route and the token\n'
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GH_ROUTE_MODE=fail run_sut --apply
check "auth: gh-route exit 2 is could-not-run and git is never called" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|$(cat "$FIXTURE_GIT_CALL_LOG")|$(contains "$OUT" "$ALPHA_STORE: gh-route could not answer")|$(commit_count "$ALPHA_DIR")" \
    "2|could-not-run||yes|1"

# gh-route's own stderr reaches the output through the redactor. Made slow, it shows whether the run
# waits for it or says its next line first.
reset_scene
make_tracked_store "$ALPHA_STORE"
PATH="$SLOW_SED_DIR:$PATH" FIXTURE_GH_ROUTE_MODE=fail run_sut --apply
route_error_line=0 could_not_answer_line=0 output_line_number=0
while IFS= read -r output_line; do
    output_line_number=$(( output_line_number + 1 ))
    if [[ "$output_line" == "$GH_ROUTE_FIXTURE_ERROR" ]]; then route_error_line=$output_line_number; fi
    if [[ "$output_line" == *"$ALPHA_STORE: gh-route could not answer"* ]]; then could_not_answer_line=$output_line_number; fi
done <<< "$OUT"
check "auth: gh-route's own error, redacted, is printed before the line saying it could not answer" \
    "$RC|$(( route_error_line > 0 && route_error_line < could_not_answer_line ))" "2|1"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
: > "$FIXTURE_TOKEN_FILE"
remote_before=$(remote_head)
PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GH_ROUTE_MODE=matched run_sut --apply
check "auth: an empty token file is skipped-no-token, exit 0, no fetch, and the local commit is still made" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|fetch $(calls_of fetch) push $(calls_of push)|$(remote_head)|$(commit_count "$ALPHA_DIR")|$(last_ok_of "$ALPHA_STORE")" \
    "0|skipped-no-token|fetch 0 push 0|$remote_before|2|(absent)"

# A remote commit as well, so the run fetches, merges and pushes: every git call it makes is logged.
reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push theirs.md 'their body'
write_file "$ALPHA_DIR/a.md" 'a body'
printf '%s\n' "$FAKE_TOKEN" > "$FIXTURE_TOKEN_FILE"
PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GH_ROUTE_MODE=matched FIXTURE_EXPECTED_TOKEN="$FAKE_TOKEN" run_sut --apply
calls_with_token=''
while IFS= read -r logged_call; do
    if [[ "$logged_call" != *" token:unset "* ]]; then calls_with_token+="${logged_call%% *}:${logged_call#* token:} "; fi
done < "$FIXTURE_GIT_ENV_LOG"
fetch_call=$(grep -F ' fetch ' "$FIXTURE_GIT_CALL_LOG")
# GH_CONFIG_DIR is not among what they are given: git reads none of gh's config, and the helper that
# would (gh auth git-credential) is cleared. The routed config dir decides only which token file is read.
check "auth: the token is in no argv, no output and no status, and only the fetch and the push are given it" \
    "$RC|$(contains "$(cat "$FIXTURE_GIT_CALL_LOG")" "$FAKE_TOKEN")|$(contains "$OUT" "$FAKE_TOKEN")|$(contains "$(status_line_of "$ALPHA_STORE")" "$FAKE_TOKEN")|$calls_with_token|$(contains "$fetch_call" ' -c credential.helper= -c credential.helper=!')|$(remote_head)" \
    "0|no|no|no|fetch:expected gh-config:unset push:expected gh-config:unset |yes|$(local_head)"

# The helper the run gave git, run as git runs one: `sh -c '<helper> <operation>'`, its request on stdin.
helper_snippet=$(cat "$FIXTURE_CREDENTIAL_HELPER_FILE" 2>/dev/null)
credential_request="protocol=https${NL}host=github.com${NL}"
helper_get_output=$(printf '%s\n' "$credential_request" | CLAUDE_MEMORY_GIT_TOKEN="$FAKE_TOKEN" sh -c "$helper_snippet get" 2>&1)
helper_get_status=$?
helper_store_output=$(printf '%s\n' "$credential_request" | CLAUDE_MEMORY_GIT_TOKEN="$FAKE_TOKEN" sh -c "$helper_snippet store" 2>&1)
helper_store_status=$?
helper_erase_output=$(printf '%s\n' "$credential_request" | CLAUDE_MEMORY_GIT_TOKEN="$FAKE_TOKEN" sh -c "$helper_snippet erase" 2>&1)
helper_erase_status=$?
helper_empty_output=$(printf '%s\n' "$credential_request" | CLAUDE_MEMORY_GIT_TOKEN='' sh -c "$helper_snippet get" 2>&1)
helper_empty_status=$?
# And as git itself asks it, behind a cleared helper list.
git_fill_output=$(printf '%s\n' "$credential_request" | CLAUDE_MEMORY_GIT_TOKEN="$FAKE_TOKEN" GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= -c "credential.helper=!$helper_snippet" credential fill 2>&1)
check "auth: the helper answers only get, and fails on an empty variable" \
    "$([[ -n "$helper_snippet" ]] && printf 'a helper was given')|$helper_get_status|$([[ "$helper_get_output" == "username=x-access-token${NL}password=$FAKE_TOKEN" ]] && printf 'answers the token')|$helper_store_status|$helper_store_output|$helper_erase_status|$helper_erase_output|$helper_empty_status|$helper_empty_output|$(contains "$git_fill_output" "password=$FAKE_TOKEN")" \
    "a helper was given|0|answers the token|0||0||1||yes"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GH_ROUTE_MODE=none run_sut --apply
calls_with_route_environment=''
while IFS= read -r logged_call; do
    if [[ "$logged_call" != *" token:unset gh-config:unset" ]]; then calls_with_route_environment+="$logged_call "; fi
done < "$FIXTURE_GIT_ENV_LOG"
check "auth: state none runs unpinned, with the host's own credential helper" \
    "$RC|$(cat "$FIXTURE_GH_ROUTE_CALLS" 2>/dev/null)|$(contains "$(cat "$FIXTURE_GIT_CALL_LOG")" 'credential.helper')|$calls_with_route_environment|fetch $(calls_of fetch)|$(status_field_of "$ALPHA_STORE" 2)|$(remote_head)" \
    "0|$ALPHA_DIR|no||fetch 1|ok|$(local_head)"

printf 'fetch: a remote that does not answer\n'
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
mv "$REMOTES_DIR/$ALPHA_STORE.git" "$REMOTES_DIR/$ALPHA_STORE.git.gone" || fatal "could not move the remote away"
run_sut --apply
check "fetch: an unreachable origin is outcome unreachable, exit 0, and the local commit is still made" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|$(contains "$OUT" "$ALPHA_STORE: unreachable")|$(commit_count "$ALPHA_DIR")|$(last_ok_of "$ALPHA_STORE")" \
    "0|unreachable|yes|2|(absent)"

# A withheld file is bad on every run until it is renamed or edited; an unreachable remote may answer
# the next run. So withheld is the outcome, and the network failure goes into its detail.
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/clean.md" 'clean body'
write_file "$ALPHA_DIR/$FIXTURE_HOOK_STAGED_PATH" "a line carrying $FAKE_TOKEN in prose"
mv "$REMOTES_DIR/$ALPHA_STORE.git" "$REMOTES_DIR/$ALPHA_STORE.git.gone" || fatal "could not move the remote away"
run_sut --apply
check "fetch: a withheld file outranks an unreachable origin, which goes into its detail" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|$(contains "$(status_field_of "$ALPHA_STORE" 3)" "$FIXTURE_HOOK_STAGED_PATH; unreachable: ")|$(contains "$OUT" "$ALPHA_STORE: unreachable")|$(contains "$(status_line_of "$ALPHA_STORE")" "$FAKE_TOKEN")" \
    "0|withheld|yes|yes|no"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
remote_before=$(remote_head)
PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GIT_ON_FETCH=not-found run_sut --apply
check "fetch: a not-found error is outcome auth-failed, exit 0, and nothing is pushed" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|$(contains "$(status_field_of "$ALPHA_STORE" 3)" 'Repository not found')|push $(calls_of push)|$(remote_head)|$(last_ok_of "$ALPHA_STORE")" \
    "0|auth-failed|yes|push 0|$remote_before|(absent)"

# The fetch prunes, so the branches the branch check reads are origin's as they are now, not as
# they once were.
reset_scene
make_tracked_store "$ALPHA_STORE"
PATH="$GIT_WRAPPER_DIR:$PATH" run_sut --apply
fetch_call=$(grep -F ' fetch ' "$FIXTURE_GIT_CALL_LOG")
check "fetch: carries --prune" "$RC|$(contains "$fetch_call" ' --prune ')" "0|yes"

reset_scene
make_tracked_store "$ALPHA_STORE"
git -C "$SEED_DIR" push -q "$REMOTES_DIR/$ALPHA_STORE.git" main:other || fatal "could not push other to the alpha remote"
git -C "$ALPHA_DIR" fetch -q origin || fatal "could not fetch into the alpha store"
git -C "$ALPHA_DIR" rev-parse -q --verify refs/remotes/origin/other >/dev/null \
    || fatal "the alpha store has no origin/other for the run to prune"
git -C "$REMOTES_DIR/$ALPHA_STORE.git" branch -q -D other || fatal "could not delete other on the alpha remote"
run_sut --apply
check "fetch: a remote branch deleted upstream disappears from refs/remotes after a run" \
    "$RC|$(git -C "$ALPHA_DIR" rev-parse -q --verify refs/remotes/origin/other || printf 'gone')" "0|gone"

PUSH_ATTEMPTS_LOG="$TMPROOT/push-attempts"
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
rm -f "$PUSH_ATTEMPTS_LOG"
printf '#!/usr/bin/env bash\nprintf "attempt\\n" >> %q\nprintf "fixture: this remote takes no pushes\\n" >&2\nexit 1\n' \
    "$PUSH_ATTEMPTS_LOG" > "$REMOTES_DIR/$ALPHA_STORE.git/hooks/pre-receive"
chmod +x "$REMOTES_DIR/$ALPHA_STORE.git/hooks/pre-receive"
remote_before=$(remote_head)
run_sut --apply
check "push: a rejected push is outcome push-rejected, exit 0, one attempt" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|$(wc -l < "$PUSH_ATTEMPTS_LOG" 2>/dev/null | tr -d ' ')|$(remote_head)|$(last_ok_of "$ALPHA_STORE")" \
    "0|push-rejected|1|$remote_before|(absent)"

# ---------------------------------------------------------------------------------------------
# network: last-ok, the run deadline, what a network call's environment holds
# ---------------------------------------------------------------------------------------------

printf 'network: last-ok, the run deadline, the child environment\n'
# Nothing to commit and nothing to push: the fetch is the check, and a quiet host is still in sync.
reset_scene
make_tracked_store "$ALPHA_STORE"
printf -v epoch_before '%(%s)T' -1
PATH="$GIT_WRAPPER_DIR:$PATH" run_sut --apply
printf -v epoch_after '%(%s)T' -1
last_ok_epoch=$(last_ok_of "$ALPHA_STORE")
check "push: an up-to-date run is ok, pushes nothing, and still stamps last-ok" \
    "$RC|$OUT|$(status_field_of "$ALPHA_STORE" 2)|$(status_field_of "$ALPHA_STORE" 3)|fetch $(calls_of fetch) push $(calls_of push)|$([[ "$last_ok_epoch" =~ ^[0-9]+$ ]] && (( last_ok_epoch >= epoch_before && last_ok_epoch <= epoch_after )) && printf 'stamped now')" \
    "0||ok|up to date|fetch 1 push 0|stamped now"

# The deadline is two seconds into the run and the alpha store's fetch takes three: that fetch starts
# before it, and its merge is committed whole after it; the alpha push, and the beta store's gh-route
# and fetch, would all start after it.
reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push theirs.md 'their body'
write_file "$ALPHA_DIR/ours.md" 'our body'
make_beta_tracked_store
write_file "$BETA_DIR/b.md" 'b body'
beta_remote_before=$(git -C "$REMOTES_DIR/$BETA_STORE.git" rev-parse main)
beta_commits_after_its_local_commit=$(( $(commit_count "$BETA_DIR") + 1 ))
SUT_RUN_DEADLINE_SECONDS=$DEADLINE_ROW_DEADLINE_SECONDS PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GIT_ON_FETCH=slow \
    FIXTURE_FETCH_SECONDS=$DEADLINE_ROW_FETCH_SECONDS run_sut_bounded --apply
check "deadline: no gh-route, fetch or push starts after the run deadline; a store past it is committed and reads unreachable, run deadline" \
    "$RC|$(status_field_of "$BETA_STORE" 2)|$(status_field_of "$BETA_STORE" 3)|$(status_field_of "$ALPHA_STORE" 2)|$(status_field_of "$ALPHA_STORE" 3)|fetch $(calls_of fetch) push $(calls_of push)|$(wc -l < "$FIXTURE_GH_ROUTE_CALLS" | tr -d ' ')|$(parent_count "$ALPHA_DIR")|$(merge_head_state)|$([[ -e "$BETA_DIR/.git/MERGE_HEAD" ]] && printf 'a merge in progress')|$(commit_count "$BETA_DIR")|$(git -C "$REMOTES_DIR/$BETA_STORE.git" rev-parse main)" \
    "0|unreachable|run deadline|unreachable|run deadline|fetch 1 push 0|1|3|||$beta_commits_after_its_local_commit|$beta_remote_before"

# A network call with a route mode that is neither pinned nor unpinned is called here directly, from
# the script's own functions: no run reaches one, and the call must still not fall back to the host's
# own credential helpers.
unrouted_call_results=''
for unsettled_route_mode in '' 'not-a-mode'; do
    reset_scene
    make_tracked_store "$ALPHA_STORE"
    # shellcheck disable=SC2016  # expanded by the bash -c, not this one
    unrouted_call_output=$(PATH="$GIT_WRAPPER_DIR:$PATH" bash -c 'source "$1" && ROUTE_MODE=$2 && network_git_in_store "$3" fetch --quiet origin' \
        _ "$SUT" "$unsettled_route_mode" "$ALPHA_DIR" 2>&1)
    unrouted_call_status=$?
    unrouted_call_results+="$([[ "$unrouted_call_status" != 0 ]] && printf refused)|$(contains "$unrouted_call_output" "refusing a network call: the route mode is '$unsettled_route_mode'")|$(cat "$FIXTURE_GIT_CALL_LOG") "
done
check "auth: a network call with no settled route mode is refused, and git is never called" \
    "$unrouted_call_results" "refused|yes| refused|yes| "

# The clock is the fixture's: the alpha fetch moves it past the deadline, and the beta store's first git
# call moves it back. The beta store, past the deadline when it began, makes no network call: the
# decision is made once, before its first network step, and nothing later in the store re-opens it.
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
make_beta_tracked_store
write_file "$BETA_DIR/b.md" 'b body'
printf '%s\n' "$FIXTURE_UPTIME_START" > "$FIXTURE_UPTIME_FILE" || fatal "could not set the fixture clock"
SUT_UPTIME_FILE=$FIXTURE_UPTIME_FILE SUT_RUN_DEADLINE_SECONDS=$DEADLINE_ROW_DEADLINE_SECONDS \
    PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_CLOCK_STEPS=1 FIXTURE_CLOCK_BACK_DIR="$BETA_DIR" run_sut --apply
check "deadline: a store past the deadline makes no network call, decided once, even when the clock then steps back" \
    "$RC|$(status_field_of "$BETA_STORE" 2)|$(status_field_of "$BETA_STORE" 3)|fetch $(calls_of fetch) push $(calls_of push)|$(wc -l < "$FIXTURE_GH_ROUTE_CALLS" | tr -d ' ')|$(cat "$FIXTURE_UPTIME_FILE")" \
    "0|unreachable|run deadline|fetch 1 push 0|1|$FIXTURE_UPTIME_START"

# A deadline of two seconds and a lock wait of twenty: the wait is cut to the time left, so the run
# gives up on a lock the holder keeps for four seconds rather than waiting it out.
reset_scene
write_file "$ALPHA_DIR/pending.md" 'pending body'
mkdir -p "$STATE_DIR" || fatal "could not create the state dir"
rm -f "$lock_taken_file" "$lock_release_file"
# shellcheck disable=SC2016  # expanded by the bash -c, not this one
flock "$LINK_LOCK" timeout "$TIMEOUT_ROW_HOLD_SECONDS" \
    bash -c ': > "$1"; while [[ ! -e "$2" ]]; do sleep "$3"; done' \
    _ "$lock_taken_file" "$lock_release_file" "$LOCK_TAKEN_POLL_INTERVAL_SECONDS" &
lock_holder_pid=$!
wait_for_file "$lock_taken_file" || fatal "the row's lock holder never took the lock"
SUT_RUN_DEADLINE_SECONDS=$DEADLINE_ROW_DEADLINE_SECONDS run_sut_bounded --apply
: > "$lock_release_file"
wait "$lock_holder_pid"
check "deadline: no lock wait runs past the run deadline" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: the lock $LINK_LOCK was still held after")|$(commit_count "$ALPHA_DIR")|$(status_field_of "$ALPHA_STORE" 2)" \
    "2|yes|0|could-not-run"

# A caller can set these; git then writes its trace, curl's headers among them, to stderr, which a
# status detail and the output keep.
reset_scene
make_tracked_store "$ALPHA_STORE"
seed_write_push theirs.md 'their body'
write_file "$ALPHA_DIR/a.md" 'a body'
printf '%s\n' "$FAKE_TOKEN" > "$FIXTURE_TOKEN_FILE"
encoded_credential=$(printf 'x-access-token:%s' "$FAKE_TOKEN" | base64 | tr -d '\n')
PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GH_ROUTE_MODE=matched GIT_TRACE=1 GIT_TRACE_CURL=1 GIT_TRACE_PACKET=1 \
    GIT_CURL_VERBOSE=1 GIT_TRACE_REDACT=0 run_sut --apply
check "network: git's trace and curl-verbose variables reach no git call, a network call redacts its trace, and no credential is in the output or the status" \
    "$RC|$(calls_with_trace_variables)|$(network_call_settings trace)|$(contains "$OUT" 'Authorization')|$(contains "$OUT" "$encoded_credential")|$(contains "$(status_line_of "$ALPHA_STORE")" "$encoded_credential")|$(remote_head)" \
    "0|0|fetch trace-variables: curl-verbose:unset trace-redact:1 push trace-variables: curl-verbose:unset trace-redact:1 |no|no|no|$(local_head)"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
PATH="$GIT_WRAPPER_DIR:$PATH" GIT_ASKPASS="$TMPROOT/fixture-askpass" GIT_TERMINAL_PROMPT=1 run_sut --apply
unpinned_prompt_settings="$RC|$(network_call_settings prompt)|$([[ "$(remote_head)" == "$(local_head)" ]] && printf pushed)"
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
printf '%s\n' "$FAKE_TOKEN" > "$FIXTURE_TOKEN_FILE"
PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GH_ROUTE_MODE=matched GIT_ASKPASS="$TMPROOT/fixture-askpass" \
    GIT_TERMINAL_PROMPT=1 run_sut --apply
check "network: a fetch and a push run with no prompt, no askpass program and the C locale, whatever the caller set, pinned or not" \
    "$unpinned_prompt_settings|$RC|$(network_call_settings prompt)|$([[ "$(remote_head)" == "$(local_head)" ]] && printf pushed)" \
    "0|fetch askpass: prompt:0 locale:C push askpass: prompt:0 locale:C |pushed|0|fetch askpass: prompt:0 locale:C push askpass: prompt:0 locale:C |pushed"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
SUT_GH_ROUTE_TIMEOUT_SECONDS=$GH_ROUTE_LIMIT_ROW_SECONDS PATH="$GIT_WRAPPER_DIR:$PATH" FIXTURE_GH_ROUTE_MODE=hang \
    run_sut_bounded --apply
check "auth: a gh-route that does not answer within its limit is could-not-run, naming gh-route, and git is never called" \
    "$RC|$(contains "$OUT" "$ALPHA_STORE: gh-route did not answer within $GH_ROUTE_LIMIT_ROW_SECONDS s")|$(cat "$FIXTURE_GIT_CALL_LOG")|$(status_field_of "$ALPHA_STORE" 2)" \
    "2|yes||could-not-run"

# The push succeeds and last-ok cannot be written: a directory stands where its temporary file goes.
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
mkdir -p "$STATE_DIR/$ALPHA_STORE.last-ok.new" || fatal "could not put a directory in last-ok's way"
run_sut --apply
check "push: a last-ok that cannot be written still records the outcome, naming the failure, and is exit 2" \
    "$RC|$(status_field_of "$ALPHA_STORE" 2)|$(contains "$(status_field_of "$ALPHA_STORE" 3)" "could not write $STATE_DIR/$ALPHA_STORE.last-ok")|$(remote_head)" \
    "2|ok|yes|$(local_head)"

# ---------------------------------------------------------------------------------------------
# --status: one or more lines per checked-out store, store<TAB>level<TAB>message
# ---------------------------------------------------------------------------------------------

printf 'status: --status, read-only\n'
reset_scene
make_tracked_store "$ALPHA_STORE"
write_status_fixture "$ALPHA_STORE" ok '' "$(stamp_now_minus 0)"
run_sut --status
status_after_ok="$RC|$OUT"
write_status_fixture "$ALPHA_STORE" kept-both 'kept both for 1 files' "$(stamp_now_minus 0)"
run_sut --status
check "status: ok or kept-both with last-ok within the threshold is level ok" \
    "$status_after_ok|$RC|$OUT" \
    "0|$ALPHA_STORE${TAB}ok${TAB}last synced 0 min ago|0|$ALPHA_STORE${TAB}ok${TAB}last synced 0 min ago"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_status_fixture "$ALPHA_STORE" skipped-no-token 'no token' ''
run_sut --status
status_never_synced="$RC|$OUT"
write_status_fixture "$ALPHA_STORE" ok '' "$(stamp_now_minus "$STALE_ROW_AGE_MINUTES")"
set_stale_after '' "$SHORT_THRESHOLD_MINUTES"
run_sut --status
check "status: a store with an origin whose last-ok is missing or past the threshold is bad, with the last outcome and detail" \
    "$status_never_synced|$RC|$OUT" \
    "0|$ALPHA_STORE${TAB}bad${TAB}never synced; last outcome skipped-no-token: no token|0|$ALPHA_STORE${TAB}bad${TAB}last synced $STALE_ROW_AGE_MINUTES min ago, past the $SHORT_THRESHOLD_MINUTES min threshold; last outcome ok"

# Fetched by hand and never synced, so no status file can carry the reason: the line is --status's own.
reset_scene
make_tracked_store "$ALPHA_STORE"
rm -rf "$ALPHA_DIR"
git init -q -b "$OTHER_BRANCH" "$ALPHA_DIR" || fatal "could not create the alpha store"
git -C "$ALPHA_DIR" remote add origin "$REMOTES_DIR/$ALPHA_STORE.git" || fatal "could not add the origin"
git -C "$ALPHA_DIR" fetch -q origin || fatal "could not fetch into the alpha store"
run_sut --status
check "status: a store on a branch the last-fetched origin lacks, while it has another, is one bad line naming both" \
    "$RC|$OUT" "0|$ALPHA_STORE${TAB}bad${TAB}$BRANCH_MISMATCH_REASON"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_status_fixture "$ALPHA_STORE" ok '' "$(stamp_now_minus "$STALE_ROW_AGE_MINUTES")"
threshold_levels=''
for stale_after in "$LONG_THRESHOLD_MINUTES $SHORT_THRESHOLD_MINUTES" " $SHORT_THRESHOLD_MINUTES" " "; do
    set_stale_after "${stale_after% *}" "${stale_after#* }"
    run_sut --status
    threshold_levels+="$(cut -f2 <<< "$OUT") "
done
check "status: the threshold is stale_after_minutes[<host>], else .default, else 60" \
    "$threshold_levels" "ok bad ok "

reset_scene
make_tracked_store "$ALPHA_STORE"
bad_outcome_lines=''
for bad_outcome in withheld blocked auth-failed could-not-run; do
    write_status_fixture "$ALPHA_STORE" "$bad_outcome" "notes/$bad_outcome.md" "$(stamp_now_minus 0)"
    run_sut --status
    bad_outcome_lines+="$RC $OUT${NL}"
done
check "status: withheld, blocked, auth-failed and could-not-run are bad, naming the file or reason" \
    "$bad_outcome_lines" \
    "0 $ALPHA_STORE${TAB}bad${TAB}withheld: notes/withheld.md${NL}0 $ALPHA_STORE${TAB}bad${TAB}blocked: notes/blocked.md${NL}0 $ALPHA_STORE${TAB}bad${TAB}auth-failed: notes/auth-failed.md${NL}0 $ALPHA_STORE${TAB}bad${TAB}could-not-run: notes/could-not-run.md${NL}"

reset_scene
write_status_fixture "$ALPHA_STORE" ok-local-only 'committed 1 files'
run_sut --status
check "status: ok-local-only is warn, no remote yet" \
    "$RC|$OUT" "0|$ALPHA_STORE${TAB}warn${TAB}no remote yet"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/x.conflict-$FIXTURE_HOST.md" 'one copy'
write_file "$ALPHA_DIR/sub/y.conflict-$OTHER_HOST.2.md" 'another copy'
write_status_fixture "$ALPHA_STORE" ok '' "$(stamp_now_minus 0)"
run_sut --status
check "status: a conflict copy in the tree is warn, with the count" \
    "$RC|$OUT" \
    "0|$ALPHA_STORE${TAB}ok${TAB}last synced 0 min ago${NL}$ALPHA_STORE${TAB}warn${TAB}2 conflict copies in the tree"

reset_scene
make_tracked_store "$ALPHA_STORE"
printf '%s\n' '- [Gone](gone.md) — names a file that is not there' >> "$ALPHA_DIR/MEMORY.md"
write_file "$ALPHA_DIR/repos/$FIXTURE_OWNER/demo/a.md" 'a body'
printf '%s\n' '- [A](a.md) — first' '- [A again](a.md) — second' '- [B](b.md) — missing' \
    > "$ALPHA_DIR/repos/$FIXTURE_OWNER/demo/MEMORY.md"
write_status_fixture "$ALPHA_STORE" ok '' "$(stamp_now_minus 0)"
run_sut --status
check "status: an index line naming a missing file, or one file named by two index lines, is warn with the directory and counts" \
    "$RC|$OUT" \
    "0|$ALPHA_STORE${TAB}ok${TAB}last synced 0 min ago${NL}$ALPHA_STORE${TAB}warn${TAB}.: 1 index lines name a missing file, 0 files are named by more than one index line${NL}$ALPHA_STORE${TAB}warn${TAB}repos/$FIXTURE_OWNER/demo: 1 index lines name a missing file, 1 files are named by more than one index line"

# A store --status cannot read is one of its own lines, so the doctor names it with the reason; exit 2
# is kept for a run that could read nothing at all.
reset_scene
make_tracked_store "$ALPHA_STORE"
make_beta_tracked_store
git -C "$BETA_DIR" remote set-url origin "$OTHER_REMOTE" || fatal "could not repoint the beta store's origin"
write_status_fixture "$ALPHA_STORE" ok '' "$(stamp_now_minus 0)"
run_sut --status
check "status: a store it cannot read is a bad line naming the reason, the other stores are still read, exit 0" \
    "$RC|$OUT" \
    "0|$ALPHA_STORE${TAB}ok${TAB}last synced 0 min ago${NL}$BETA_STORE${TAB}bad${TAB}origin is not the table's remote"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_status_fixture "$ALPHA_STORE" ok '' "$(stamp_now_minus 0)"
# A PATH holding only what the script runs before it looks for jq.
NO_JQ_BIN_DIR="$TMPROOT/no-jq-bin"
mkdir -p "$NO_JQ_BIN_DIR" || fatal "could not create the no-jq bin directory"
for tool in bash dirname; do ln -sf "$(command -v "$tool")" "$NO_JQ_BIN_DIR/$tool" || fatal "could not link $tool"; done
PATH="$NO_JQ_BIN_DIR" run_sut --status
check "status: no jq is still exit 2, naming it" "$RC|$(contains "$OUT" 'jq is required')" "2|yes"

reset_scene
make_tracked_store "$ALPHA_STORE"
write_status_fixture "$ALPHA_STORE" ok '' "$(stamp_now_minus 0)"
chmod 000 "$STATE_DIR" || fatal "could not make the state dir unreadable"
run_sut --status
unreadable_state_result="$RC|$(contains "$OUT" "the state dir $STATE_DIR cannot be read")|$(contains "$OUT" "${TAB}bad${TAB}")"
chmod 755 "$STATE_DIR" || fatal "could not make the state dir readable again"
check "status: a state dir it cannot read is exit 2 naming it, never a store reading as never synced" \
    "$unreadable_state_result" "2|yes|no"

# ---------------------------------------------------------------------------------------------
# The host name in a commit message and the staleness threshold: CLAUDE_MEMORY_HOST, else the profile
# marker's first line, else hostname -s. Every row runs with the hostname stub first on PATH, and every
# row but the variable's with CLAUDE_MEMORY_HOST empty, so a fall-through to hostname -s shows as the
# stub's name.
# ---------------------------------------------------------------------------------------------

printf 'host name: the profile marker names the host\n'
# The marker's path, spelled independently of the script under test.
FIXTURE_PROFILE_MARKER="$HOME/.config/claude-host-profile"
OVERRIDE_PROFILE_MARKER="$TMPROOT/override-profile-marker"
MARKER_HOST='markerhost'
OVERRIDE_MARKER_HOST='overridehost'
STUB_SHORT_HOST='stub-short-host'
# Fails the host-name rule: it would climb out of a directory.
UNUSABLE_MARKER_LINE='../climb'
# The marker host's threshold, short of the last-ok's age, and the default, past it: the store reads
# stale only when the threshold is the marker host's.
MARKER_HOST_THRESHOLD_MINUTES=5
MARKER_ROW_DEFAULT_THRESHOLD_MINUTES=60
MARKER_ROW_AGE_MINUTES=10
# The fixture's hostname: `hostname -s` answers STUB_SHORT_HOST, any other call fails.
HOSTNAME_STUB_DIR="$TMPROOT/hostname-stub-bin"
mkdir -p "$HOSTNAME_STUB_DIR" || fatal "could not create the hostname stub directory"
cat > "$HOSTNAME_STUB_DIR/hostname" <<STUB
#!/bin/sh
[ "\$1" = '-s' ] || exit 9
printf '%s\n' '$STUB_SHORT_HOST'
STUB
chmod +x "$HOSTNAME_STUB_DIR/hostname" || fatal "could not make the hostname stub executable"

# host_name_scene MARKER_LINE — a scene with one new file in the alpha store, so --apply commits it
# under the host's name, and a profile marker holding MARKER_LINE.
host_name_scene() {
    reset_scene
    write_file "$ALPHA_DIR/topic.md" 'topic body'
    write_file "$FIXTURE_PROFILE_MARKER" "$1"
}

host_name_scene "$MARKER_HOST"
FIXTURE_HOST='' PATH="$HOSTNAME_STUB_DIR:$PATH" run_sut --apply
marker_commit_result="$RC|$OUT|$(head_subject "$ALPHA_DIR")"
reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$FIXTURE_PROFILE_MARKER" "$MARKER_HOST"
write_status_fixture "$ALPHA_STORE" ok '' "$(stamp_now_minus "$MARKER_ROW_AGE_MINUTES")"
FIXTURE_HOST="$MARKER_HOST" set_stale_after "$MARKER_HOST_THRESHOLD_MINUTES" "$MARKER_ROW_DEFAULT_THRESHOLD_MINUTES"
FIXTURE_HOST='' PATH="$HOSTNAME_STUB_DIR:$PATH" run_sut --status
check "host name: the profile marker names the host" \
    "$marker_commit_result|$RC|$OUT" \
    "0|$ALPHA_STORE: committed 1 files|$MARKER_HOST: 1 files|0|$ALPHA_STORE${TAB}bad${TAB}last synced $MARKER_ROW_AGE_MINUTES min ago, past the $MARKER_HOST_THRESHOLD_MINUTES min threshold; last outcome ok"

# A pin: a marker that outranked the variable would name the commit markerhost.
host_name_scene "$MARKER_HOST"
PATH="$HOSTNAME_STUB_DIR:$PATH" run_sut --apply
check "host name: CLAUDE_MEMORY_HOST outranks the marker" \
    "$RC|$(head_subject "$ALPHA_DIR")" "0|$FIXTURE_HOST: 1 files"

# A pin: a marker line taken without the host-name rule reaches the last check, which stops the run, exit 2.
host_name_scene "$UNUSABLE_MARKER_LINE"
FIXTURE_HOST='' PATH="$HOSTNAME_STUB_DIR:$PATH" run_sut --apply
check "host name: an unusable marker line falls back to hostname -s" \
    "$RC|$OUT|$(head_subject "$ALPHA_DIR")" "0|$ALPHA_STORE: committed 1 files|$STUB_SHORT_HOST: 1 files"

# A pin: a read with no readability test before it puts the shell's "Permission denied" on stderr.
# Mode 000 does not stop root, so under root (act runs so) the precondition below fails and the table
# is could-not-run, exit 2, as the root check at the top already makes it.
host_name_scene "$MARKER_HOST"
chmod 000 "$FIXTURE_PROFILE_MARKER" || fatal "could not make the profile marker unreadable"
[[ ! -r "$FIXTURE_PROFILE_MARKER" ]] \
    || fatal "the profile marker is still readable at mode 000: the unreadable-marker row would assert nothing"
FIXTURE_HOST='' PATH="$HOSTNAME_STUB_DIR:$PATH" run_sut --apply
check "host name: an unreadable marker falls back to hostname -s, silently" \
    "$RC|$(contains "$OUT" 'Permission denied')|$(head_subject "$ALPHA_DIR")" "0|no|$STUB_SHORT_HOST: 1 files"

# A pin: it catches the marker test losing its -f half. A directory passes -r, and the read on it puts
# the shell's "Is a directory" on stderr before the fall-back, which names the commit the same either way.
host_name_scene "$MARKER_HOST"
rm -f "$FIXTURE_PROFILE_MARKER" || fatal "could not remove the profile marker file"
mkdir "$FIXTURE_PROFILE_MARKER" || fatal "could not put a directory at the profile marker's path"
FIXTURE_HOST='' PATH="$HOSTNAME_STUB_DIR:$PATH" run_sut --apply
check "host name: a marker that is a directory falls back to hostname -s, silently" \
    "$RC|$(contains "$OUT" 'Is a directory')|$(head_subject "$ALPHA_DIR")" "0|no|$STUB_SHORT_HOST: 1 files"

host_name_scene "$MARKER_HOST"
write_file "$OVERRIDE_PROFILE_MARKER" "$OVERRIDE_MARKER_HOST"
CLAUDE_SETTINGS_RENDER_MARKER="$OVERRIDE_PROFILE_MARKER" FIXTURE_HOST='' PATH="$HOSTNAME_STUB_DIR:$PATH" run_sut --apply
check "host name: the marker override path is honoured" \
    "$RC|$(head_subject "$ALPHA_DIR")" "0|$OVERRIDE_MARKER_HOST: 1 files"

# ---------------------------------------------------------------------------------------------
# units: the tick, and the two links ./install makes for it
# ---------------------------------------------------------------------------------------------

printf 'units: the service, the timer and their links\n'
SYNC_SERVICE_UNIT="$DOTFILES/systemd/claude-memory-sync.service"
SYNC_TIMER_UNIT="$DOTFILES/systemd/claude-memory-sync.timer"
UNIT_COPIES_DIR="$TMPROOT/units"
# The directives that carry a decision, as the service must hold them: the dash on ExecStartPre lets a
# failed link step leave the sync to run, the timeout keeps a link step that hangs from spending the
# sync's time, and 8 min outlasts both worst cases together, about 125 s and 330 s.
EXPECTED_SERVICE_DIRECTIVES="ConditionPathExists=%h/.local/share/claude-memory
Type=oneshot
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStartPre=-/usr/bin/timeout --kill-after=5 120 %h/.dotfiles/scripts/claude-memory-link.sh --apply
ExecStart=%h/.dotfiles/scripts/claude-memory-sync.sh --apply
TimeoutStartSec=8min"
SERVICE_DIRECTIVE_ERE='^(Condition[A-Za-z]*|Type|Environment|ExecStartPre|ExecStart|TimeoutStartSec)='
EXPECTED_TIMER_DIRECTIVES="OnCalendar=*:0/10
RandomizedDelaySec=60
Persistent=true
WantedBy=default.target"
TIMER_DIRECTIVE_ERE='^(On[A-Za-z]*|RandomizedDelaySec|Persistent|WantedBy)='
check "units: the service runs the bounded link step, which cannot stop it, then the sync's --apply, within 8 min" \
    "$(grep -E "$SERVICE_DIRECTIVE_ERE" "$SYNC_SERVICE_UNIT")" "$EXPECTED_SERVICE_DIRECTIVES"
check "units: the timer fires every 10 min, catching up a missed tick, wanted by default.target" \
    "$(grep -E "$TIMER_DIRECTIVE_ERE" "$SYNC_TIMER_UNIT")" "$EXPECTED_TIMER_DIRECTIVES"
if command -v systemd-analyze >/dev/null 2>&1; then
    # verify checks that each command it runs EXISTS, and %h/.dotfiles is not there on a CI runner, so
    # the service is verified through a copy whose two commands point at this checkout's scripts: the
    # same unit text, commands that exist. The row above pins the real paths. The timer is verified
    # next to it, by name.
    mkdir -p "$UNIT_COPIES_DIR"
    sed -e "/^ExecStart/s#%h/.dotfiles/scripts/#$DOTFILES/scripts/#" "$SYNC_SERVICE_UNIT" \
        > "$UNIT_COPIES_DIR/claude-memory-sync.service"
    cp "$SYNC_TIMER_UNIT" "$UNIT_COPIES_DIR/claude-memory-sync.timer"
    check "units: systemd-analyze verify accepts both (both commands pointed at this checkout)" \
        "$(systemd-analyze verify --man=no --recursive-errors=no "$UNIT_COPIES_DIR/claude-memory-sync.service" \
            "$UNIT_COPIES_DIR/claude-memory-sync.timer" >/dev/null 2>&1 && echo ok || echo bad)" ok
elif [[ -n "${CI:-}" ]]; then
    # CI is where this row is meant to run, so a runner without the tool is a failure, never a skip.
    bad "units: systemd-analyze verify accepts both — systemd-analyze is missing on CI"
else
    ok "units: systemd-analyze absent here; CI runs it"
fi
# Linked and nothing more: a host arms the timer by hand, so no line of ./install or of its config
# (comments aside) may enable it.
if [[ -r "$DOTFILES/install" && -r "$DOTFILES/install.conf.yaml" ]]; then
    enabling_lines=$(cat "$DOTFILES/install" "$DOTFILES/install.conf.yaml" | grep -v '^[[:space:]]*#' \
        | grep -c 'enable.*claude-memory-sync')
else
    enabling_lines='install or install.conf.yaml is unreadable'
fi
check "units: neither ./install nor install.conf.yaml enables claude-memory-sync" "$enabling_lines" 0
# shellcheck disable=SC2088  # the tilde is the literal text of the yaml line, not a path
check "install.conf.yaml links the service (linked, not enabled)" \
    "$(grep -c '^    ~/.config/systemd/user/claude-memory-sync.service: systemd/claude-memory-sync.service$' "$DOTFILES/install.conf.yaml")" 1
# shellcheck disable=SC2088  # same: literal yaml text
check "install.conf.yaml links the timer" \
    "$(grep -c '^    ~/.config/systemd/user/claude-memory-sync.timer: systemd/claude-memory-sync.timer$' "$DOTFILES/install.conf.yaml")" 1

printf '\n'
EXPECTED_ROWS=117
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
