#!/usr/bin/env bash
#
# scripts/test-claude-memory-sync.sh
# ==================================
#
# State table for scripts/claude-memory-sync.sh, its local half: the origin check, staging every file
# but the link script's partial copies, the credential-shape gate, the commit, the status file,
# --check and --scan.
#
# HERMETIC. Every row runs against fixtures under mktemp -d, under a fixture HOME, with the projects
# dir, the stores root, the store table, the state dir, the host name and both route scripts named
# explicitly; git reads only the fixture's config files. A store is a real `git init -b main`
# checkout and a remote is a local bare repository, so nothing touches the network. The credential
# in the gate rows is fake, gho_ and 36 letters, built at run time so that no scanner reads this file
# as holding one.
# Requires: bash, git, jq, flock, sha256sum, find, sort, timeout, touch.

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

for tool in bash git jq flock sha256sum find sort timeout touch; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
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
# The route scripts are the network half's and the link script's; the local half asks neither.
ROUTE_STUB="$TMPROOT/stub-bin/refusing-route"
FAKE_TOKEN="gho_$(printf 'A%.0s' {1..36})"
LOCK_HOLD_SECONDS=2
HANG_BOUND_SECONDS=30
# touch -t: a moment after any fixture's own writes, so the file's stat data no longer matches its index entry.
FUTURE_MTIME_STAMP='203001010000'

mkdir -p "$(dirname "$ROUTE_STUB")"
printf '#!/usr/bin/env bash\nprintf "stub route: not for the local half\\n" >&2\nexit 3\n' > "$ROUTE_STUB"
printf '#!/usr/bin/env bash\nprintf called > %q\nexit 1\n' "$SIGNING_CALLS" > "$SIGNING_STUB"
chmod +x "$ROUTE_STUB" "$SIGNING_STUB"

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
    rm -rf "$HOME" "$STORES_ROOT" "$STATE_DIR" "$REMOTES_DIR" "$SEED_DIR" "$SIGNING_CALLS"
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

# make_tracked_store STORE — STORE becomes a clone of a fresh bare remote holding one commit, and the
# table's remote for STORE is that remote's path. The seed checkout stays at SEED_DIR, for pushes.
make_tracked_store() {
    local remote="$REMOTES_DIR/$1.git"
    git init -q --bare -b main "$remote" || fatal "could not create the remote of $1"
    git init -q -b main "$SEED_DIR" || fatal "could not create the seed checkout"
    write_file "$SEED_DIR/seed.md" 'seed body'
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

# run_sut ARGS… → combined output in $OUT, exit status in $RC. Every override is always set.
SUT_RUNNER_PREFIX=()
run_sut() {
    OUT=$(CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" CLAUDE_MEMORY_STORES_ROOT="$STORES_ROOT" \
        CLAUDE_MEMORY_CONFIG="$CONFIG" CLAUDE_MEMORY_STATE_DIR="$STATE_DIR" \
        CLAUDE_MEMORY_HOST="$FIXTURE_HOST" CLAUDE_MEMORY_TENANT_ROUTE="$ROUTE_STUB" \
        CLAUDE_MEMORY_GH_ROUTE="$ROUTE_STUB" \
        "${SUT_RUNNER_PREFIX[@]}" "$SUT" "$@" 2>&1); RC=$?
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
    "$RC|$(contains "$OUT" '--check')$(contains "$OUT" '--scan')$(contains "$OUT" '--apply')$(contains "$OUT" '--store')$(contains "$OUT" '--rev')" \
    "0|yesyesyesyesyes"

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
# lock: the link script's lock is held from stage to commit
# ---------------------------------------------------------------------------------------------

printf 'lock: the link script lock\n'
reset_scene
write_file "$ALPHA_DIR/early.md" 'early body'
mkdir -p "$STATE_DIR" || fatal "could not create the state dir"
lock_taken_file="$TMPROOT/lock-taken"
rm -f "$lock_taken_file"
# The holder writes late.md as the link script would, still under the lock: a sync that waited for the
# lock before staging commits it, and one that did not has already committed without it.
# shellcheck disable=SC2016  # expanded by the bash -c, not this one
flock "$STATE_DIR/link.lock" bash -c ': > "$1"; sleep "$3"; printf "late body\n" > "$2"' \
    _ "$lock_taken_file" "$ALPHA_DIR/late.md" "$LOCK_HOLD_SECONDS" &
lock_holder_pid=$!
for (( lock_wait_step = 0; lock_wait_step < 100; lock_wait_step++ )); do
    [[ -e "$lock_taken_file" ]] && break
    sleep 0.05
done
[[ -e "$lock_taken_file" ]] || fatal "the row's lock holder never took the lock"
run_sut_bounded --apply
check "lock: the sync waits for link.lock" \
    "$RC|$OUT|$(head_files "$ALPHA_DIR")" "0|$ALPHA_STORE: committed 2 files|early.md late.md "
wait "$lock_holder_pid"

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
    "$(status_field_of "$ALPHA_STORE" 1 | tr -d '0-9')|$(status_field_of "$ALPHA_STORE" 2)|$(status_field_of "$ALPHA_STORE" 3)|$(contains "$(status_line_of "$ALPHA_STORE")" "$FAKE_TOKEN")" \
    "|withheld|notes/leaky.md|no"
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

reset_scene
make_tracked_store "$ALPHA_STORE"
write_file "$ALPHA_DIR/a.md" 'a body'
remote_head_before=$(git -C "$REMOTES_DIR/$ALPHA_STORE.git" rev-parse main)
run_sut --apply
check "status: a store whose origin is the table's is committed and given no status" \
    "$RC|$OUT|$(commit_count "$ALPHA_DIR")|$([[ -e "$STATE_DIR/$ALPHA_STORE.status" ]] && printf 'has a status')|$(git -C "$REMOTES_DIR/$ALPHA_STORE.git" rev-parse main)" \
    "0|$ALPHA_STORE: committed 1 files|2||$remote_head_before"

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

printf '\n'
EXPECTED_ROWS=37
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
