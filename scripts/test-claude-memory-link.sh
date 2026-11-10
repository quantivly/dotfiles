#!/usr/bin/env bash
#
# scripts/test-claude-memory-link.sh
# ==================================
#
# State table for scripts/claude-memory-link.sh: mapping Claude Code project keys to memory-store
# directories, reporting the state of each key's `memory` entry, and (--apply) swapping a real
# directory for a link and merging it into the store, resumably.
#
# HERMETIC. Every row runs against fixtures under mktemp -d, under a fixture HOME, with the projects
# dir, the stores root, the store table, the state dir, the host name and tenant-route all named
# explicitly; git reads only the fixture's config files. Checkouts are real ones (`git init`, `git submodule add`, `git worktree
# add`), because a hand-written `.git` file would be a claim about git. tenant-route is a stub that
# answers per directory: fixture tenants are alpha and beta.
# Requires: bash, git, jq.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$DOTFILES/scripts/claude-memory-link.sh"
# Checked, because every fixture path hangs off it and reset_scene removes them: with an empty
# TMPROOT, HOME would be /home. Physical, because the script keys a directory by its physical path
# and every expected line below is built from this one.
TMPROOT="$(mktemp -d)" || { printf 'FATAL: mktemp failed\n' >&2; exit 2; }
trap 'rm -rf "$TMPROOT"' EXIT
TMPROOT="$(cd -P "$TMPROOT" && pwd -P)" || { printf 'FATAL: could not resolve the fixture root\n' >&2; exit 2; }

HOME="$TMPROOT/home"
mkdir -p "$HOME"
export HOME
# A row run from a git hook would otherwise point every fixture git at the hook's repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
# The caller's lock wait would otherwise reach every --apply; the row about it sets its own.
unset CLAUDE_MEMORY_LOCK_WAIT_SECONDS
# The caller's host name or profile marker would otherwise name the host; the host-name rows set their own.
unset CLAUDE_SETTINGS_RENDER_MARKER CLAUDE_MEMORY_HOST
GIT_CONFIG_GLOBAL="$TMPROOT/gitconfig-global"
GIT_CONFIG_SYSTEM="$TMPROOT/gitconfig-system"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
: > "$GIT_CONFIG_SYSTEM"
cat > "$GIT_CONFIG_GLOBAL" <<'GITCONFIG'
[user]
    name = Fixture
    email = fixture@example.invalid
[init]
    defaultBranch = main
[protocol "file"]
    allow = always
GITCONFIG

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for tool in bash git jq find sha256sum sort cmp flock mkfifo stat touch timeout; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
[[ -x "$SUT" ]] || fatal "$SUT is not executable — every row below would assert nothing"
# Mode 000 does not stop root, so the unreadable-directory rows would pass on nothing. Not a skip: a
# skipped row is neither a pass nor a fail, and it would leave a green total behind.
(( $(id -u) != 0 )) || fatal "the table cannot run as root: its unreadable-directory rows would assert nothing"

# ---------------------------------------------------------------------------------------------
# Fixtures. A scene is an empty fixture home, projects dir and stores root, plus the store table.
# ---------------------------------------------------------------------------------------------

TAB=$'\t'
PROJECTS_DIR="$TMPROOT/projects"
STORES_ROOT="$TMPROOT/stores"
CONFIG="$TMPROOT/memory-stores.json"
STATE_DIR="$TMPROOT/state"
FIXTURE_HOST='fixture-host'
ROUTE_STUB="$TMPROOT/stub-bin/tenant-route"
ROUTE_CALLS="$TMPROOT/route-calls"
ALPHA_STORE='alpha-store'
BETA_STORE='beta-store'
FIXTURE_OWNER='example-org'
SOURCE_REPOS="$TMPROOT/source-repos"
REPLACED_STAMP='memory.replaced-20261106T000000Z'
MERGED_MARKER='.merged-into-store'
NO_CHECKOUT_KEY='-no-such-checkout'

# The stub tenant-route: it records the call, then answers by a word in the directory's BASENAME.
# Never the whole path: the fixture root sits under whatever TMPDIR names, which can hold these words.
mkdir -p "$(dirname "$ROUTE_STUB")" "$SOURCE_REPOS"
cat > "$ROUTE_STUB" <<STUB
#!/usr/bin/env bash
printf '%s\0' "\$1" >> '$ROUTE_CALLS'
case "\${1##*/}" in
    *route-refuses-*) printf 'stub refusal\n' >&2; exit 3 ;;
    *route-garbled-*) printf '{"tenant":"alpha"} and then this is not json\n'; exit 0 ;;
    *route-blank-*)   printf '{"tenant":"","state":"none","why":"stub"}\n'; exit 0 ;;
    *gamma-*)         answer=gamma ;;
    *beta-*)          answer=beta ;;
    *)                answer=alpha ;;
esac
printf '{"tenant":"%s","state":"route","why":"stub"}\n' "\$answer"
STUB
chmod +x "$ROUTE_STUB"

# write_default_config — alpha and beta each in a store; checkouts under code/, plain dirs home and notes.
write_default_config() {
    cat > "$CONFIG" <<JSON
{"stores": {"$ALPHA_STORE": {"remote": "https://github.com/$FIXTURE_OWNER/alpha-memory.git", "tenants": ["alpha"]},
            "$BETA_STORE": {"remote": "https://github.com/$FIXTURE_OWNER/beta-memory.git", "tenants": ["beta"]}},
 "checkout_globs": ["code/*"],
 "plain_dirs": [],
 "stale_after_minutes": {"default": 60}}
JSON
}

# reset_scene — nothing under the fixture home, the projects dir, the stores root or the state dir;
# the alpha store checked out, the beta store not; the default table; no recorded route calls.
reset_scene() {
    rm -rf "$HOME" "$PROJECTS_DIR" "$STORES_ROOT" "$STATE_DIR" "$ROUTE_CALLS"
    mkdir -p "$HOME" "$PROJECTS_DIR" "$STORES_ROOT"
    git init -q "$STORES_ROOT/$ALPHA_STORE" || fatal "could not create the alpha store"
    write_default_config
}

# set_plain_dirs JSON_ARRAY — replace the table's plain_dirs.
set_plain_dirs() {
    jq --argjson plain_dirs "$1" '.plain_dirs = $plain_dirs' "$CONFIG" > "$CONFIG.new" \
        || fatal "could not set plain_dirs"
    mv "$CONFIG.new" "$CONFIG" || fatal "could not replace the table"
}

# make_checkout RELATIVE_PATH [ORIGIN_URL] — a real repo under the fixture home.
make_checkout() {
    git init -q "$HOME/$1" || fatal "git init failed for $1"
    if (( $# >= 2 )); then
        git -C "$HOME/$1" remote add origin "$2" || fatal "could not add an origin to $1"
    fi
}

# make_source_repo NAME — a repo with one commit, outside the home, for a submodule to clone.
make_source_repo() {
    git init -q "$SOURCE_REPOS/$1" || fatal "git init failed for source repo $1"
    git -C "$SOURCE_REPOS/$1" commit -q --allow-empty -m "$1" || fatal "could not commit in source repo $1"
    printf '%s\n' "$SOURCE_REPOS/$1"
}

# add_submodule SUPER_RELATIVE NAME PATH URL — a real submodule, committed in the superproject.
add_submodule() {
    git -C "$HOME/$1" submodule --quiet add --name "$2" "$4" "$3" || fatal "could not add submodule $2"
    git -C "$HOME/$1" commit -q -m "add $2" || fatal "could not commit submodule $2"
}

# key_of PATH — the project key, spelled independently of the script under test.
key_of() { printf '%s' "${1//[^A-Za-z0-9]/-}"; }

# real_memory KEY [FILE_NAME] — a real memory directory under KEY, holding FILE_NAME when given.
real_memory() {
    mkdir -p "$PROJECTS_DIR/$1/memory" || fatal "could not create the memory directory of $1"
    if (( $# >= 2 )); then
        printf 'fixture memory\n' > "$PROJECTS_DIR/$1/memory/$2"
    fi
}

# link_memory KEY TARGET — memory under KEY is a symlink to TARGET, which need not exist.
link_memory() {
    mkdir -p "$PROJECTS_DIR/$1" || fatal "could not create the key directory of $1"
    ln -s "$2" "$PROJECTS_DIR/$1/memory" || fatal "could not link the memory of $1"
}

# store_file STORE RELATIVE_DIR — a file in that store directory (memory another host wrote).
store_file() {
    mkdir -p "$STORES_ROOT/$1/$2" || fatal "could not create $2 in $1"
    printf 'fixture memory\n' > "$STORES_ROOT/$1/$2/MEMORY.md"
}

# run_sut ARGS… → combined output in $OUT, exit status in $RC. Every override is always set.
SUT_RUNNER_PREFIX=()
run_sut() {
    OUT=$(CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" CLAUDE_MEMORY_STORES_ROOT="$STORES_ROOT" \
        CLAUDE_MEMORY_CONFIG="$CONFIG" CLAUDE_MEMORY_STATE_DIR="$STATE_DIR" \
        CLAUDE_MEMORY_HOST="$FIXTURE_HOST" CLAUDE_MEMORY_TENANT_ROUTE="$ROUTE_STUB" \
        "${SUT_RUNNER_PREFIX[@]}" "$SUT" "$@" 2>&1); RC=$?
}

# run_sut_bounded ARGS… — run_sut for a row whose regression is a hang under the lock: the row then
# fails on exit 124, where the table would otherwise never end.
HANG_BOUND_SECONDS=30
run_sut_bounded() {
    SUT_RUNNER_PREFIX=(timeout --kill-after=5 "$HANG_BOUND_SECONDS")
    run_sut "$@"
    SUT_RUNNER_PREFIX=()
}

# row_of_key KEY — the --list line of KEY in $OUT, or nothing. A plain string match, so that the
# empty columns of a row cannot shift its fields.
row_of_key() {
    local line
    while IFS= read -r line; do
        if [[ "$line" == "$1$TAB"* ]]; then printf '%s' "$line"; fi
    done <<< "$OUT"
}

# row_line KEY STATE STORE RELATIVE_DIR SOURCE_DIR — the expected --list line.
row_line() { printf '%s\t%s\t%s\t%s\t%s' "$@"; }

# line_count TEXT — how many lines TEXT holds; 0 when it is empty.
line_count() {
    local line count=0
    [[ -n "$1" ]] || { printf '0'; return; }
    while IFS= read -r line; do count=$((count + 1)); done <<< "$1"
    printf '%d' "$count"
}

contains() { [[ "$1" == *"$2"* ]] && printf yes || printf no; }   # HAYSTACK NEEDLE → yes|no

# recorded_route_calls — every directory the stub was asked about since the scene began, sorted, on
# one line; nothing when it was not asked at all.
recorded_route_calls() {
    [[ -f "$ROUTE_CALLS" ]] || return 0
    tr '\0' '\n' < "$ROUTE_CALLS" | LC_ALL=C sort | tr '\n' ' '
}

# ---------------------------------------------------------------------------------------------
# One key in each state. add_state STATE builds that key and records its expected --list line.
# ---------------------------------------------------------------------------------------------

declare -A EXPECTED_ROW

add_state() {
    local state=$1 repo store relative source_dir key store_dir
    if [[ "$state" == UNMAPPED ]]; then
        real_memory "$NO_CHECKOUT_KEY" MEMORY.md
        EXPECTED_ROW[$state]=$(row_line "$NO_CHECKOUT_KEY" UNMAPPED '' '' '')
        return 0
    fi
    repo="${state,,}-repo"
    store=$ALPHA_STORE
    if [[ "$state" == NO-STORE ]]; then
        repo="beta-${state,,}-repo"
        store=$BETA_STORE
    fi
    relative="repos/$FIXTURE_OWNER/$repo"
    source_dir="$HOME/code/$repo"
    key=$(key_of "$source_dir")
    store_dir="$STORES_ROOT/$store/$relative"
    make_checkout "code/$repo" "git@github.com:$FIXTURE_OWNER/$repo.git"
    case "$state" in
        LINKED)
            store_file "$store" "$relative"
            link_memory "$key" "$store_dir" ;;
        REAL-DIR)
            real_memory "$key" MEMORY.md ;;
        MISSING)
            store_file "$store" "$relative" ;;
        DANGLING)
            link_memory "$key" "$store_dir" ;;
        PENDING-MERGE)
            store_file "$store" "$relative"
            link_memory "$key" "$store_dir"
            mkdir -p "$PROJECTS_DIR/$key/$REPLACED_STAMP" ;;
        WRONG-LINK)
            mkdir -p "$TMPROOT/elsewhere"
            link_memory "$key" "$TMPROOT/elsewhere" ;;
        NO-STORE)
            real_memory "$key" MEMORY.md ;;
        *)  fatal "add_state: no such state $state" ;;
    esac
    EXPECTED_ROW[$state]=$(row_line "$key" "$state" "$store" "$relative" "$source_dir")
}

# ---------------------------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------------------------

printf 'usage: the verbs\n'
reset_scene
run_sut --no-such-verb
check "usage: an unknown argument is exit 64" "$RC|$(contains "$OUT" 'unknown argument: --no-such-verb')" "64|yes"
run_sut --list --check
check "usage: two verbs are exit 64" "$RC|$(contains "$OUT" 'only one verb allowed')" "64|yes"
run_sut --help
check "usage: --help is exit 0 and names every verb and flag" \
    "$RC|$(contains "$OUT" '--list')$(contains "$OUT" '--check')$(contains "$OUT" '--apply')$(contains "$OUT" '--dry-run')$(contains "$OUT" '--only')" \
    "0|yesyesyesyesyes"
run_sut --dry-run
dry_run_alone="$RC|$(contains "$OUT" '--dry-run and --only go with --apply')"
run_sut --list --only some-key
check "usage: --dry-run or --only without --apply is exit 64" \
    "$dry_run_alone|$RC|$(contains "$OUT" '--dry-run and --only go with --apply')" "64|yes|64|yes"
run_sut --apply --only
only_with_nothing="$RC|$(contains "$OUT" '--only needs a key')"
run_sut --apply --only ''
check "usage: --only with no key is exit 64" \
    "$only_with_nothing|$RC|$(contains "$OUT" '--only needs a key')" "64|yes|64|yes"

# ---------------------------------------------------------------------------------------------
# The key rule. The literal is the example the spec gives; the function is called directly because
# no fixture path can be that literal.
# ---------------------------------------------------------------------------------------------

printf 'key: the project key of a path\n'
# shellcheck source=/dev/null  # the path is computed; shellcheck -x checks the script on its own
key_of_dotfiles=$(source "$SUT" && project_key_of_path /home/u/.dotfiles 2>&1)
# shellcheck source=/dev/null
key_kept_characters=$(source "$SUT" && project_key_of_path '/home/U1/My.Repo-2/a b+c' 2>&1)
check "key: dots and slashes become dashes" \
    "$key_of_dotfiles|$key_kept_characters" "-home-u--dotfiles|-home-U1-My-Repo-2-a-b-c"

# ---------------------------------------------------------------------------------------------
# The mapping. Each row gives the key a real memory directory so that it is listed (REAL-DIR).
# ---------------------------------------------------------------------------------------------

printf 'map: a directory to its store and store-relative directory\n'
reset_scene
make_checkout code/hub 'git@github.com:Example-Org/Hub.git'
make_checkout code/other 'https://github.com/Example-Org/Other-Repo'
hub_key=$(key_of "$HOME/code/hub")
other_key=$(key_of "$HOME/code/other")
real_memory "$hub_key"
real_memory "$other_key"
run_sut --list
check "map: origin owner and repo are lowercased" \
    "$RC|$(row_of_key "$hub_key")|$(row_of_key "$other_key")" \
    "0|$(row_line "$hub_key" REAL-DIR "$ALPHA_STORE" repos/example-org/hub "$HOME/code/hub")|$(row_line "$other_key" REAL-DIR "$ALPHA_STORE" repos/example-org/other-repo "$HOME/code/other")"

reset_scene
make_checkout code/slashed 'https://github.com/Example-Org/Slashed.git/'
key=$(key_of "$HOME/code/slashed")
real_memory "$key"
run_sut --list
check "map: an origin's trailing slash is dropped with its .git" \
    "$RC|$(row_of_key "$key" | cut -f2,4)" "0|REAL-DIR${TAB}repos/example-org/slashed"

reset_scene
make_checkout code/No-Origin
key=$(key_of "$HOME/code/No-Origin")
real_memory "$key"
run_sut --list
check "map: a repo with no origin is a dirs entry" \
    "$RC|$(row_of_key "$key")" "0|$(row_line "$key" REAL-DIR "$ALPHA_STORE" dirs/code-no-origin "$HOME/code/No-Origin")"

reset_scene
set_plain_dirs '["Notes/Daily"]'
mkdir -p "$HOME/Notes/Daily"
key=$(key_of "$HOME/Notes/Daily")
real_memory "$key"
run_sut --list
check "map: a plain directory is a dirs entry with a lowercased slug" \
    "$RC|$(row_of_key "$key")" "0|$(row_line "$key" REAL-DIR "$ALPHA_STORE" dirs/notes-daily "$HOME/Notes/Daily")"

reset_scene
set_plain_dirs '[""]'
key=$(key_of "$HOME")
real_memory "$key"
run_sut --list
check "map: home itself is dirs/home" \
    "$RC|$(row_of_key "$key")" "0|$(row_line "$key" REAL-DIR "$ALPHA_STORE" dirs/home "$HOME")"

reset_scene
make_checkout code/owner-less 'hub'
run_sut --list
check "map: an origin with no owner and repo is exit 2 naming the directory" \
    "$RC|$(contains "$OUT" "$HOME/code/owner-less: origin")" "2|yes"

reset_scene
make_checkout code/escaping 'https://example.com/../..'
run_sut --list
check "map: an origin that climbs out of the store is exit 2 naming the directory" \
    "$RC|$(contains "$OUT" "$HOME/code/escaping: origin")" "2|yes"

ORIGIN_CREDENTIAL_MARKER='fixture-credential-marker'
reset_scene
make_checkout code/carries-credential "https://fixture-user:$ORIGIN_CREDENTIAL_MARKER@hub"
run_sut --list
check "map: refusing an origin never prints its URL, which can carry a credential" \
    "$RC|$(contains "$OUT" "$HOME/code/carries-credential: origin")|$(contains "$OUT" "$ORIGIN_CREDENTIAL_MARKER")" "2|yes|no"

reset_scene
mkdir -p "$HOME/code/not-a-repo"
key=$(key_of "$HOME/code/not-a-repo")
real_memory "$key"
run_sut --list
check "map: a glob match with no .git is not a candidate" "$RC|$(row_of_key "$key")" "0|"

reset_scene
set_plain_dirs '["absent-here"]'
key=$(key_of "$HOME/absent-here")
real_memory "$key"
run_sut --list
check "map: a plain_dirs entry absent on this host is not a candidate" "$RC|$(row_of_key "$key")" "0|"

reset_scene
mkdir -p "$HOME/code/garbled"
printf 'this is not a gitdir line\n' > "$HOME/code/garbled/.git"
run_sut --list
check "map: a .git file with no gitdir line is exit 2 naming it" \
    "$RC|$(contains "$OUT" "$HOME/code/garbled/.git has no gitdir: line")" "2|yes"

# code itself is a repo with an origin: a git that walks up from the hollow .git would answer for it.
reset_scene
make_checkout code "git@github.com:$FIXTURE_OWNER/parent-of-hollow.git"
mkdir -p "$HOME/code/hollow/.git"
run_sut --list
check "map: a .git directory git cannot read is exit 2 naming the directory" \
    "$RC|$(contains "$OUT" "git could not read the origin of $HOME/code/hollow")" "2|yes"

# Submodules. A plain one, at a path that is its name.
plain_source=$(make_source_repo plain-source)
reset_scene
make_checkout code/super "git@github.com:$FIXTURE_OWNER/super.git"
git -C "$HOME/code/super" commit -q --allow-empty -m first || fatal "could not commit in super"
add_submodule code/super plain-sub plain-sub "$plain_source"
git -C "$HOME/code/super/plain-sub" remote set-url origin "git@github.com:$FIXTURE_OWNER/Plain-Sub.git" \
    || fatal "could not set the submodule's origin"
sub_path="$HOME/code/super/plain-sub"
sub_git_dir="$HOME/code/super/.git/modules/plain-sub"
sub_key=$(key_of "$sub_path")
sub_git_dir_key=$(key_of "$sub_git_dir")
real_memory "$sub_key"
real_memory "$sub_git_dir_key"
rm -f "$ROUTE_CALLS"
run_sut --list
check "map: a submodule yields two keys, one directory" \
    "$RC|$(row_of_key "$sub_key")|$(row_of_key "$sub_git_dir_key")" \
    "0|$(row_line "$sub_key" REAL-DIR "$ALPHA_STORE" "repos/$FIXTURE_OWNER/plain-sub" "$sub_path")|$(row_line "$sub_git_dir_key" REAL-DIR "$ALPHA_STORE" "repos/$FIXTURE_OWNER/plain-sub" "$sub_git_dir")"
# The superproject and the submodule are two candidates, so two calls, though there are three keys.
check "tenant-route: asked once per candidate, not once per key" \
    "$(recorded_route_calls)" "$HOME/code/super $sub_path "

# A relative gitdir that is not a plain parent of the checkout: the checkout sits beside the
# superproject whose .git holds its git dir. Git accepts the relative form and writes it for real
# submodules; here it is rewritten by hand so the path crosses into a sibling directory.
reset_scene
make_checkout code/relative-super
relative_git_dir="$HOME/code/relative-super/.git/modules/relative-sub"
mkdir -p "$(dirname "$relative_git_dir")"
git init -q --separate-git-dir="$relative_git_dir" "$HOME/code/relative-sub" || fatal "could not make relative-sub"
printf 'gitdir: ../relative-super/.git/modules/relative-sub\n' > "$HOME/code/relative-sub/.git"
git --git-dir="$HOME/code/relative-sub/.git" remote add origin "git@github.com:$FIXTURE_OWNER/relative-sub.git" \
    || fatal "git does not accept the relative gitdir fixture"
key=$(key_of "$relative_git_dir")
real_memory "$key"
run_sut --list
check "map: a relative gitdir is resolved from the checkout" \
    "$RC|$(row_of_key "$key")" \
    "0|$(row_line "$key" REAL-DIR "$ALPHA_STORE" "repos/$FIXTURE_OWNER/relative-sub" "$relative_git_dir")"

# The same shape as git writes it, absolute: joined to the checkout, it would name nothing.
reset_scene
make_checkout code/absolute-super
absolute_git_dir="$HOME/code/absolute-super/.git/modules/absolute-sub"
mkdir -p "$(dirname "$absolute_git_dir")"
git init -q --separate-git-dir="$absolute_git_dir" "$HOME/code/absolute-sub" || fatal "could not make absolute-sub"
git --git-dir="$HOME/code/absolute-sub/.git" remote add origin "git@github.com:$FIXTURE_OWNER/absolute-sub.git" \
    || fatal "git does not accept the absolute gitdir fixture"
key=$(key_of "$absolute_git_dir")
real_memory "$key"
run_sut --list
check "map: an absolute gitdir is used as it is" \
    "$RC|$(row_of_key "$key")" \
    "0|$(row_line "$key" REAL-DIR "$ALPHA_STORE" "repos/$FIXTURE_OWNER/absolute-sub" "$absolute_git_dir")"

slash_source=$(make_source_repo slash-source)
reset_scene
make_checkout code/slash-super
git -C "$HOME/code/slash-super" commit -q --allow-empty -m first || fatal "could not commit in slash-super"
add_submodule code/slash-super vendor/tool vendor/tool "$slash_source"
slash_git_dir="$HOME/code/slash-super/.git/modules/vendor/tool"
key=$(key_of "$slash_git_dir")
real_memory "$key"
run_sut --list
check "map: a submodule name with a slash keeps it in the git-dir key" \
    "$RC|$(row_of_key "$key" | cut -f2,5)" "0|REAL-DIR$TAB$slash_git_dir"

worktree_source=$(make_source_repo worktree-source)
reset_scene
make_checkout code/wt-main "git@github.com:$FIXTURE_OWNER/wt-main.git"
git -C "$HOME/code/wt-main" commit -q --allow-empty -m first || fatal "could not commit in wt-main"
git -C "$HOME/code/wt-main" worktree add -q "$HOME/code/wt-linked" || fatal "could not add a worktree"
add_submodule code/wt-main wt-sub wt-sub "$worktree_source"
git -C "$HOME/code/wt-main/wt-sub" worktree add -q "$HOME/code/wt-of-sub" || fatal "could not add a submodule worktree"
main_key=$(key_of "$HOME/code/wt-main")
linked_key=$(key_of "$HOME/code/wt-linked")
sub_worktree_key=$(key_of "$HOME/code/wt-of-sub")
real_memory "$main_key"
real_memory "$linked_key"
real_memory "$sub_worktree_key"
run_sut --list
# The main checkout's row is part of each: a run that listed nothing would otherwise pass.
check "map: a worktree .git file is skipped" \
    "$RC|$(row_of_key "$main_key" | cut -f2)|$(row_of_key "$linked_key")" "0|REAL-DIR|"
check "map: a worktree of a submodule is skipped" \
    "$RC|$(row_of_key "$main_key" | cut -f2)|$(row_of_key "$sub_worktree_key")" "0|REAL-DIR|"

# A worktree has no key of its own, and neither has what it holds: the worktree is made after the
# submodule, and populated, so there is something for a wrong walk to find.
populated_source=$(make_source_repo populated-source)
reset_scene
make_checkout code/populated-main "git@github.com:$FIXTURE_OWNER/populated-main.git"
git -C "$HOME/code/populated-main" commit -q --allow-empty -m first || fatal "could not commit in populated-main"
add_submodule code/populated-main populated-sub populated-sub "$populated_source"
git -C "$HOME/code/populated-main" worktree add -q "$HOME/code/populated-linked" || fatal "could not add a worktree"
git -C "$HOME/code/populated-linked" submodule --quiet update --init || fatal "could not populate the worktree's submodule"
main_key=$(key_of "$HOME/code/populated-main")
worktree_submodule_key=$(key_of "$HOME/code/populated-linked/populated-sub")
real_memory "$main_key"
real_memory "$worktree_submodule_key"
run_sut --list
check "map: a worktree brings no submodules with it" \
    "$RC|$(row_of_key "$main_key" | cut -f2)|$(row_of_key "$worktree_submodule_key")" "0|REAL-DIR|"

nested_inner_source=$(make_source_repo nested-inner-source)
nested_outer_source=$(make_source_repo nested-outer-source)
git -C "$nested_outer_source" submodule --quiet add --name inner "$nested_inner_source" inner \
    || fatal "could not nest a submodule in the source repo"
git -C "$nested_outer_source" commit -q -m 'add inner' || fatal "could not commit the nested submodule"
reset_scene
make_checkout code/nest-super
git -C "$HOME/code/nest-super" commit -q --allow-empty -m first || fatal "could not commit in nest-super"
add_submodule code/nest-super outer outer "$nested_outer_source"
git -C "$HOME/code/nest-super" submodule --quiet update --init --recursive || fatal "could not init the nested submodule"
inner_path="$HOME/code/nest-super/outer/inner"
inner_git_dir="$HOME/code/nest-super/.git/modules/outer/modules/inner"
inner_key=$(key_of "$inner_path")
inner_git_dir_key=$(key_of "$inner_git_dir")
real_memory "$inner_key"
real_memory "$inner_git_dir_key"
run_sut --list
check "map: a nested submodule is a candidate" \
    "$RC|$(row_of_key "$inner_key" | cut -f2,5)|$(row_of_key "$inner_git_dir_key" | cut -f2,5)" \
    "0|REAL-DIR$TAB$inner_path|REAL-DIR$TAB$inner_git_dir"

reset_scene
set_plain_dirs '["code/both-ways"]'
make_checkout code/both-ways "git@github.com:$FIXTURE_OWNER/both-ways.git"
key=$(key_of "$HOME/code/both-ways")
real_memory "$key"
run_sut --list
check "map: a directory both a glob and plain_dirs name is one row, asked about once" \
    "$RC|$(line_count "$OUT")|$(row_of_key "$key" | cut -f2)|$(recorded_route_calls)" "0|1|REAL-DIR|$HOME/code/both-ways "

# Two directories can share a key: a-b/sub and a/b-sub both flatten the same way. Within one store
# the first candidate keeps the key, and the second still claims the key only it has.
reset_scene
jq '.checkout_globs = ["code/shared-sub", "code/shared"]' "$CONFIG" > "$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
shared_source=$(make_source_repo shared-source)
make_checkout code/shared-sub "git@github.com:$FIXTURE_OWNER/first-claim.git"
make_checkout code/shared
git -C "$HOME/code/shared" commit -q --allow-empty -m first || fatal "could not commit in shared"
add_submodule code/shared sub sub "$shared_source"
git -C "$HOME/code/shared/sub" remote set-url origin "git@github.com:$FIXTURE_OWNER/second-claim.git" \
    || fatal "could not set the second claim's origin"
shared_key=$(key_of "$HOME/code/shared/sub")
shared_git_dir="$HOME/code/shared/.git/modules/sub"
shared_git_dir_key=$(key_of "$shared_git_dir")
real_memory "$shared_key"
real_memory "$shared_git_dir_key"
run_sut --list
check "map: a key two directories share stays with the first" \
    "$RC|$(line_count "$OUT")|$(row_of_key "$shared_key")|$(row_of_key "$shared_git_dir_key")" \
    "0|2|$(row_line "$shared_key" REAL-DIR "$ALPHA_STORE" "repos/$FIXTURE_OWNER/first-claim" "$HOME/code/shared-sub")|$(row_line "$shared_git_dir_key" REAL-DIR "$ALPHA_STORE" "repos/$FIXTURE_OWNER/second-claim" "$shared_git_dir")"

# The same flattening across two stores: code/beta-twin and code-beta/twin. Claude Code would keep one
# memory directory for both, and the sync would commit one tenant's memory to the other's remote.
reset_scene
set_plain_dirs '["code-beta/twin"]'
make_checkout code/beta-twin "git@github.com:$FIXTURE_OWNER/beta-twin.git"
mkdir -p "$HOME/code-beta/twin"
key=$(key_of "$HOME/code/beta-twin")
run_sut --list
check "map: a key two directories share across stores is exit 2 naming both" \
    "$RC|$(contains "$OUT" "key $key is shared by $HOME/code/beta-twin (store $BETA_STORE) and $HOME/code-beta/twin (store $ALPHA_STORE)")" "2|yes"

# And with neither directory bringing a second key: the first keeps it, and the second is still asked.
reset_scene
set_plain_dirs '["code-plain/twin"]'
make_checkout code/plain-twin "git@github.com:$FIXTURE_OWNER/plain-twin.git"
mkdir -p "$HOME/code-plain/twin"
key=$(key_of "$HOME/code/plain-twin")
real_memory "$key"
run_sut --list
check "map: a key two directories share in one store goes to the first, silently" \
    "$RC|$OUT|$(recorded_route_calls)" \
    "0|$(row_line "$key" REAL-DIR "$ALPHA_STORE" "repos/$FIXTURE_OWNER/plain-twin" "$HOME/code/plain-twin")|$HOME/code-plain/twin $HOME/code/plain-twin "

# A glob is one pattern, whatever it holds.
reset_scene
jq '.checkout_globs = ["my code/*"]' "$CONFIG" > "$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
make_checkout 'my code/spaced' "git@github.com:$FIXTURE_OWNER/spaced.git"
key=$(key_of "$HOME/my code/spaced")
real_memory "$key"
run_sut --list
check "map: a checkout glob holding a space is one pattern" "$RC|$(row_of_key "$key" | cut -f2,4)" "0|REAL-DIR${TAB}repos/$FIXTURE_OWNER/spaced"

# git failing while it lists submodules must not read as "no submodules". The wrapper fails only
# for `submodule`; a process substitution's status is otherwise invisible.
FAILING_SUBMODULE_BIN="$TMPROOT/failing-submodule-bin"
mkdir -p "$FAILING_SUBMODULE_BIN"
printf '#!/bin/sh\ncase " $* " in *" submodule "*) exit 3 ;; esac\nexec "%s" "$@"\n' "$(command -v git)" \
    > "$FAILING_SUBMODULE_BIN/git"
chmod +x "$FAILING_SUBMODULE_BIN/git"
reset_scene
make_checkout code/lists-badly "git@github.com:$FIXTURE_OWNER/lists-badly.git"
PATH="$FAILING_SUBMODULE_BIN:$PATH" run_sut --list
check "map: git failing to list submodules is exit 2 naming the checkout" \
    "$RC|$(contains "$OUT" "git could not list the submodules of $HOME/code/lists-badly")" "2|yes"

# An exported repository variable would point the script's own git calls at another repository: a
# git hook's environment, say. Each one must leave the submodule's row as it is.
git_variable_source=$(make_source_repo git-variable-source)
reset_scene
make_checkout code/variable-super "git@github.com:$FIXTURE_OWNER/variable-super.git"
git -C "$HOME/code/variable-super" commit -q --allow-empty -m first || fatal "could not commit in variable-super"
add_submodule code/variable-super variable-sub variable-sub "$git_variable_source"
git -C "$HOME/code/variable-super/variable-sub" remote set-url origin "git@github.com:$FIXTURE_OWNER/variable-sub.git" \
    || fatal "could not set the submodule's origin"
key=$(key_of "$HOME/code/variable-super/variable-sub")
real_memory "$key"
git_variable_results=''
git_variable_expected=''
for git_variable in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE; do
    export "$git_variable=$TMPROOT/no-such-git-path"
    run_sut --list
    unset "$git_variable"
    git_variable_results+="$git_variable $RC $(row_of_key "$key" | cut -f2,4)|"
    git_variable_expected+="$git_variable 0 REAL-DIR${TAB}repos/$FIXTURE_OWNER/variable-sub|"
done
check "map: an exported git variable cannot change or hide a submodule's row" \
    "$git_variable_results" "$git_variable_expected"

# Claude Code's cwd is the physical path, so that is the key a session uses. Keyed by the link, this
# checkout would read MISSING under a key no session uses, and UNMAPPED under the one they do.
reset_scene
make_checkout elsewhere/real-repo "git@github.com:$FIXTURE_OWNER/real-repo.git"
mkdir -p "$HOME/code"
ln -s "$HOME/elsewhere/real-repo" "$HOME/code/link-repo"
physical_key=$(key_of "$HOME/elsewhere/real-repo")
real_memory "$physical_key" MEMORY.md
store_file "$ALPHA_STORE" "repos/$FIXTURE_OWNER/real-repo"
run_sut --list
check "map: a symlinked candidate is keyed by its physical path" "$RC|$OUT" \
    "0|$(row_line "$physical_key" REAL-DIR "$ALPHA_STORE" "repos/$FIXTURE_OWNER/real-repo" "$HOME/elsewhere/real-repo")"

reset_scene
set_plain_dirs '["link-notes"]'
mkdir -p "$HOME/real-notes"
ln -s "$HOME/real-notes" "$HOME/link-notes"
physical_key=$(key_of "$HOME/real-notes")
real_memory "$physical_key"
run_sut --list
check "map: a symlinked plain directory is keyed and slugged by its physical path" "$RC|$OUT" \
    "0|$(row_line "$physical_key" REAL-DIR "$ALPHA_STORE" dirs/real-notes "$HOME/real-notes")"

# A slug is relative to the physical home, or every directory would read as outside it.
reset_scene
set_plain_dirs '["Notes"]'
mkdir -p "$HOME/Notes"
key=$(key_of "$HOME/Notes")
real_memory "$key"
ln -s "$HOME" "$TMPROOT/home-link"
HOME="$TMPROOT/home-link" run_sut --list
rm -f "$TMPROOT/home-link"
check "map: a symlinked home keeps the slug relative to it" "$RC|$OUT" \
    "0|$(row_line "$key" REAL-DIR "$ALPHA_STORE" dirs/notes "$HOME/Notes")"

# Outside home a directory has no path relative to it, so a directory with no origin has no slug.
reset_scene
set_plain_dirs '["link-out"]'
mkdir -p "$TMPROOT/outside-home"
ln -s "$TMPROOT/outside-home" "$HOME/link-out"
run_sut --list
check "map: a directory outside home with no origin is exit 2 naming it" \
    "$RC|$(contains "$OUT" "$TMPROOT/outside-home is outside $HOME")" "2|yes"

# ---------------------------------------------------------------------------------------------
# --list: one key in each state, in one scene.
# ---------------------------------------------------------------------------------------------

printf 'list: one row per state\n'
ALL_STATES=(LINKED REAL-DIR MISSING DANGLING PENDING-MERGE WRONG-LINK NO-STORE UNMAPPED)
read_only_source=$(make_source_repo read-only-source)
reset_scene
for state in "${ALL_STATES[@]}"; do add_state "$state"; done
# A populated submodule with no memory and nothing in its store, so it adds no row: it is here for
# the read-only row below, which must cover `git submodule foreach` running on a real one.
make_checkout code/read-only-super "git@github.com:$FIXTURE_OWNER/read-only-super.git"
git -C "$HOME/code/read-only-super" commit -q --allow-empty -m first || fatal "could not commit in read-only-super"
add_submodule code/read-only-super read-only-sub read-only-sub "$read_only_source"
empty_unclaimed_key='-empty-unclaimed'
real_memory "$empty_unclaimed_key"
mkdir -p "$PROJECTS_DIR/$empty_unclaimed_key/memory/empty-subdir"
tree_before=$(find "$HOME" "$PROJECTS_DIR" "$STORES_ROOT" -printf '%p %y %l %s %T@\n' | LC_ALL=C sort | sha256sum)
run_sut --list
list_out=$OUT
list_rc=$RC
for state in "${ALL_STATES[@]}"; do
    state_key=${EXPECTED_ROW[$state]%%"$TAB"*}
    check "list: $state" "$list_rc|$(row_of_key "$state_key")" "0|${EXPECTED_ROW[$state]}"
done
check "list: an empty unclaimed directory is not listed" \
    "$(row_of_key "$empty_unclaimed_key")|$(line_count "$list_out")" "|${#ALL_STATES[@]}"
run_sut --check
check "check: the summary counts every state" \
    "$RC|$(contains "$OUT" 'claude-memory-link: 1 linked, 5 to fix, 1 unmapped, 1 without a store')" "1|yes"
tree_after=$(find "$HOME" "$PROJECTS_DIR" "$STORES_ROOT" -printf '%p %y %l %s %T@\n' | LC_ALL=C sort | sha256sum)
# The exit status is part of the row: a script that does nothing changes nothing, too.
check "read-only: --list and --check change nothing, mtimes included" "$list_rc|$tree_after" "0|$tree_before"

reset_scene
make_checkout code/no-memory-yet "git@github.com:$FIXTURE_OWNER/no-memory-yet.git"
run_sut --list
no_store_dir="$RC|$OUT"
mkdir -p "$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/no-memory-yet/empty-subdir"
run_sut --list
check "list: a candidate with no memory and nothing in its store directory is not listed" \
    "$no_store_dir|$RC|$OUT" "0||0|"

# A file at any depth counts as the store directory holding memory.
reset_scene
make_checkout code/nested-file "git@github.com:$FIXTURE_OWNER/nested-file.git"
key=$(key_of "$HOME/code/nested-file")
store_file "$ALPHA_STORE" "repos/$FIXTURE_OWNER/nested-file/deeper"
run_sut --list
check "list: a file at any depth in the store directory is MISSING" "$RC|$(row_of_key "$key" | cut -f2)" "0|MISSING"

# Only a REAL directory can be unmapped: a symlink under an unclaimed key already went somewhere. Two
# things give this answer: the script's `! -L`, and `find`, which does not descend into a symlink
# named as its starting point. So dropping `! -L` alone is an equivalent mutant; the row fails when
# find follows that link as well.
reset_scene
mkdir -p "$TMPROOT/elsewhere-with-file"
: > "$TMPROOT/elsewhere-with-file/MEMORY.md"
link_memory "$NO_CHECKOUT_KEY" "$TMPROOT/elsewhere-with-file"
run_sut --list
check "list: an unclaimed key whose memory is a symlink is not listed" "$RC|$OUT" "0|"

reset_scene
make_checkout code/beta-no-entry "git@github.com:$FIXTURE_OWNER/beta-no-entry.git"
key=$(key_of "$HOME/code/beta-no-entry")
run_sut --list
check "list: NO-STORE needs no memory entry" "$RC|$(row_of_key "$key" | cut -f2,3)" "0|NO-STORE$TAB$BETA_STORE"

reset_scene
make_checkout code/empty-memory "git@github.com:$FIXTURE_OWNER/empty-memory.git"
key=$(key_of "$HOME/code/empty-memory")
real_memory "$key"
run_sut --list
check "list: an empty real memory directory of a candidate is REAL-DIR" "$RC|$(row_of_key "$key" | cut -f2)" "0|REAL-DIR"

reset_scene
add_state LINKED
key=${EXPECTED_ROW[LINKED]%%"$TAB"*}
mkdir -p "$PROJECTS_DIR/$key/$REPLACED_STAMP"
: > "$PROJECTS_DIR/$key/$REPLACED_STAMP/$MERGED_MARKER"
run_sut --list
check "list: a replaced directory holding the marker stays LINKED" "$RC|$(row_of_key "$key")" "0|${EXPECTED_ROW[LINKED]}"

reset_scene
make_checkout code/relative-link "git@github.com:$FIXTURE_OWNER/relative-link.git"
key=$(key_of "$HOME/code/relative-link")
store_file "$ALPHA_STORE" "repos/$FIXTURE_OWNER/relative-link"
link_memory "$key" "../../stores/$ALPHA_STORE/repos/$FIXTURE_OWNER/relative-link"
run_sut --list
check "list: a relative link to the store directory is LINKED" "$RC|$(row_of_key "$key" | cut -f2)" "0|LINKED"

# A replaced directory the merge never finished must not hide behind any other answer: not a store
# that is gone, and not a key no candidate claims. Both still report it.
reset_scene
make_checkout code/beta-pending "git@github.com:$FIXTURE_OWNER/beta-pending.git"
key=$(key_of "$HOME/code/beta-pending")
mkdir -p "$PROJECTS_DIR/$key/$REPLACED_STAMP"
mkdir -p "$PROJECTS_DIR/$NO_CHECKOUT_KEY/$REPLACED_STAMP"
run_sut --list
check "list: PENDING-MERGE wins over NO-STORE, and needs no candidate" \
    "$RC|$(row_of_key "$key" | cut -f2)|$(row_of_key "$NO_CHECKOUT_KEY")" \
    "0|PENDING-MERGE|$(row_line "$NO_CHECKOUT_KEY" PENDING-MERGE '' '' '')"

reset_scene
make_checkout code/plain-file "git@github.com:$FIXTURE_OWNER/plain-file.git"
key=$(key_of "$HOME/code/plain-file")
mkdir -p "$PROJECTS_DIR/$key"
: > "$PROJECTS_DIR/$key/memory"
run_sut --list
check "list: a memory entry that is a plain file is exit 2 naming it" \
    "$RC|$(contains "$OUT" "$PROJECTS_DIR/$key/memory is neither a directory nor a symlink")" "2|yes"

reset_scene
awkward_repo=$'code/new\nline\ttab\\slash-repo'
make_checkout "$awkward_repo" "git@github.com:$FIXTURE_OWNER/awkward-repo.git"
key=$(key_of "$HOME/$awkward_repo")
real_memory "$key"
run_sut --list
check "list: a directory name with a newline, tab or backslash stays one row, escaped" \
    "$RC|$(line_count "$OUT")|$(row_of_key "$key")" \
    "0|1|$(row_line "$key" REAL-DIR "$ALPHA_STORE" "repos/$FIXTURE_OWNER/awkward-repo" "$HOME/code/new\\nline\\ttab\\\\slash-repo")"

# Mode 000: every test of what the directory holds would answer "nothing there", which is a clean
# report over real memory. The mode goes back before the row, or the fixture root cannot be removed.
reset_scene
make_checkout code/locked-key "git@github.com:$FIXTURE_OWNER/locked-key.git"
key=$(key_of "$HOME/code/locked-key")
real_memory "$key" MEMORY.md
chmod 000 "$PROJECTS_DIR/$key"
run_sut --check
chmod 755 "$PROJECTS_DIR/$key"
check "list: a candidate's unreadable key directory is exit 2 naming it" \
    "$RC|$(contains "$OUT" "$PROJECTS_DIR/$key is not a readable directory")" "2|yes"

reset_scene
real_memory "$NO_CHECKOUT_KEY" MEMORY.md
chmod 000 "$PROJECTS_DIR/$NO_CHECKOUT_KEY"
run_sut --check
chmod 755 "$PROJECTS_DIR/$NO_CHECKOUT_KEY"
check "list: an unclaimed unreadable key directory is exit 2 naming it" \
    "$RC|$(contains "$OUT" "$PROJECTS_DIR/$NO_CHECKOUT_KEY is not a readable directory")" "2|yes"

# A projects dir that cannot be listed would glob to nothing and report a clean host. Listing takes
# both bits, so each mode lacks a different one: neither, read only, search only.
reset_scene
add_state UNMAPPED
unreadable_results=''
for unreadable_mode in 000 644 311; do
    chmod "$unreadable_mode" "$PROJECTS_DIR"
    run_sut --check
    chmod 755 "$PROJECTS_DIR"
    unreadable_results+="$unreadable_mode $RC $(contains "$OUT" "$PROJECTS_DIR is not a readable directory")|"
done
check "list: an unreadable projects dir is exit 2 naming it" \
    "$unreadable_results" "000 2 yes|644 2 yes|311 2 yes|"

# find failing must not read as "the directory holds nothing". A wrapper, so that the row needs no
# unreadable directory and holds as root.
FAILING_FIND_BIN="$TMPROOT/failing-find-bin"
mkdir -p "$FAILING_FIND_BIN"
printf '#!/bin/sh\nexit 1\n' > "$FAILING_FIND_BIN/find"
chmod +x "$FAILING_FIND_BIN/find"
reset_scene
add_state MISSING
PATH="$FAILING_FIND_BIN:$PATH" run_sut --list
check "list: find failing is exit 2 naming the directory" \
    "$RC|$(contains "$OUT" "could not read $STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/missing-repo")" "2|yes"

rm -rf "$PROJECTS_DIR"
: > "$PROJECTS_DIR"
run_sut --list
check "list: a projects path that is not a directory is exit 2 naming it" \
    "$RC|$(contains "$OUT" "$PROJECTS_DIR is not a readable directory")" "2|yes"
rm -f "$PROJECTS_DIR"

reset_scene
rm -rf "$PROJECTS_DIR"
add_state MISSING
run_sut --list
check "list: no projects dir yet is no fault, and the key is MISSING" "$RC|$OUT" "0|${EXPECTED_ROW[MISSING]}"

# ---------------------------------------------------------------------------------------------
# --check: what is printed, what is counted, and the exit status.
# ---------------------------------------------------------------------------------------------

printf 'check: exit status and rows\n'
for state in REAL-DIR MISSING DANGLING PENDING-MERGE WRONG-LINK; do
    reset_scene
    add_state "$state"
    run_sut --check
    check "check: exit 1 on $state" "$RC|$OUT" \
        "1|${EXPECTED_ROW[$state]}
claude-memory-link: 0 linked, 1 to fix, 0 unmapped, 0 without a store"
done

reset_scene
add_state UNMAPPED
run_sut --check
check "check: UNMAPPED alone is exit 0 and its row is printed" "$RC|$OUT" \
    "0|${EXPECTED_ROW[UNMAPPED]}
claude-memory-link: 0 linked, 0 to fix, 1 unmapped, 0 without a store"

reset_scene
add_state LINKED
run_sut --check
check "check: all linked is exit 0 with only the summary line" "$RC|$OUT" \
    "0|claude-memory-link: 1 linked, 0 to fix, 0 unmapped, 0 without a store"

reset_scene
add_state NO-STORE
run_sut --check
check "check: NO-STORE alone is exit 0 and is not printed" "$RC|$OUT" \
    "0|claude-memory-link: 0 linked, 0 to fix, 0 unmapped, 1 without a store"

# Every mapped key NO-STORE, which is what the doctor must not read as the all-clear. Only a real
# directory holding a file waits for a store: the three other keys here have nothing that does.
reset_scene
for repo in beta-holds-memory beta-also-holds-memory beta-empty-memory beta-no-entry beta-link-entry; do
    make_checkout "code/$repo" "git@github.com:$FIXTURE_OWNER/$repo.git"
done
real_memory "$(key_of "$HOME/code/beta-holds-memory")" MEMORY.md
real_memory "$(key_of "$HOME/code/beta-also-holds-memory")" topic.md
real_memory "$(key_of "$HOME/code/beta-empty-memory")"
mkdir -p "$TMPROOT/link-target-with-a-file"
printf 'fixture memory\n' > "$TMPROOT/link-target-with-a-file/MEMORY.md"
link_memory "$(key_of "$HOME/code/beta-link-entry")" "$TMPROOT/link-target-with-a-file"
run_sut --check
check "check: the summary counts the NO-STORE keys holding memory, and no other" "$RC|$OUT" \
    "0|claude-memory-link: 0 linked, 0 to fix, 0 unmapped, 2 without a store"

# A store removed after its keys were linked leaves each memory a link into a checkout that is gone.
# The key is NO-STORE and holds no real directory, yet nothing Claude Code writes is kept: uncounted,
# it would be the doctor's ✓ over a host keeping no memory at all.
reset_scene
add_state LINKED
rm -rf "${STORES_ROOT:?}/$ALPHA_STORE"
run_sut --check
check "check: a key linked into a store that is gone counts as without a store" "$RC|$OUT" \
    "0|claude-memory-link: 0 linked, 0 to fix, 0 unmapped, 1 without a store"

# A count that cannot be taken is no smaller count.
reset_scene
add_state NO-STORE
unreadable_memory_dir="$PROJECTS_DIR/${EXPECTED_ROW[NO-STORE]%%"$TAB"*}/memory"
chmod 000 "$unreadable_memory_dir"
run_sut --check
unreadable_no_store_result="$RC|$(contains "$OUT" "could not read $unreadable_memory_dir")"
chmod 755 "$unreadable_memory_dir"
check "check: a NO-STORE key whose memory cannot be read is exit 2 naming it" \
    "$unreadable_no_store_result" "2|yes"

reset_scene
add_state REAL-DIR
run_sut
check "check: no verb means --check" "$RC|$OUT" \
    "1|${EXPECTED_ROW[REAL-DIR]}
claude-memory-link: 0 linked, 1 to fix, 0 unmapped, 0 without a store"

# ---------------------------------------------------------------------------------------------
# The store table.
# ---------------------------------------------------------------------------------------------

printf 'config: the store table\n'
reset_scene
add_state REAL-DIR
rm -f "$CONFIG"
tree_before=$(find "$HOME" "$PROJECTS_DIR" "$STORES_ROOT" -printf '%p %y %l %s %T@\n' | LC_ALL=C sort | sha256sum)
no_table_note="claude-memory-link: no store table at $CONFIG; nothing to do"
run_sut --list
absent_list="$RC|$OUT"
run_sut --check
absent_check="$RC|$OUT"
tree_after=$(find "$HOME" "$PROJECTS_DIR" "$STORES_ROOT" -printf '%p %y %l %s %T@\n' | LC_ALL=C sort | sha256sum)
check "config: absent is exit 0 with the note and no other output" \
    "$absent_list|$absent_check|$([[ "$tree_before" == "$tree_after" ]] && echo untouched)" \
    "0|$no_table_note|0|$no_table_note|untouched"

# A PATH with what the script needs before its jq check, and no jq: a host with no table and no jq
# is a teammate's box, where the script must still say nothing is to be done.
NO_JQ_BIN="$TMPROOT/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for tool in bash dirname sed; do ln -s "$(command -v "$tool")" "$NO_JQ_BIN/$tool"; done
OUT=$(PATH="$NO_JQ_BIN" CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" CLAUDE_MEMORY_STORES_ROOT="$STORES_ROOT" \
    CLAUDE_MEMORY_CONFIG="$CONFIG" CLAUDE_MEMORY_TENANT_ROUTE="$ROUTE_STUB" "$SUT" --check 2>&1); RC=$?
check "config: absent with no jq is still exit 0 with the note" "$RC|$OUT" "0|$no_table_note"

ln -s "$TMPROOT/no-such-table.json" "$CONFIG"
run_sut --list
check "config: a dangling symlink is exit 2, not absent" \
    "$RC|$(contains "$OUT" "$CONFIG is a symlink whose target does not exist")" "2|yes"
rm -f "$CONFIG"

not_one_object_results=''
for not_an_object in '[]' '{' '' '{} {}'; do
    printf '%s\n' "$not_an_object" > "$CONFIG"
    run_sut --list
    not_one_object_results+="$RC$(contains "$OUT" "$CONFIG is not one JSON object") "
done
check "config: not a JSON object is exit 2" "$not_one_object_results" "2yes 2yes 2yes 2yes "

config_shape_results=''
for malformed_table in \
    '{"checkout_globs":[],"plain_dirs":[]}' \
    '{"stores":{"a":{"tenants":"alpha"}},"checkout_globs":[],"plain_dirs":[]}' \
    '{"stores":{"a":{"tenants":[""]}},"checkout_globs":[],"plain_dirs":[]}' \
    '{"stores":{"../up":{"tenants":["alpha"]}},"checkout_globs":[],"plain_dirs":[]}' \
    '{"stores":{},"plain_dirs":[]}' \
    '{"stores":{},"checkout_globs":["a"],"plain_dirs":"b"}'; do
    printf '%s\n' "$malformed_table" > "$CONFIG"
    run_sut --list
    config_shape_results+="$RC$(contains "$OUT" "$CONFIG: ") "
done
check "config: a wrong shape is exit 2 naming the table" "$config_shape_results" "2yes 2yes 2yes 2yes 2yes 2yes "

reset_scene
jq '.stores["beta-store"].tenants += ["alpha"]' "$CONFIG" > "$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
run_sut --list
check "config: a tenant two stores list is exit 2 naming it" \
    "$RC|$(contains "$OUT" "tenant 'alpha' is in two stores")" "2|yes"

reset_scene
make_checkout code/gamma-repo "git@github.com:$FIXTURE_OWNER/gamma-repo.git"
run_sut --list
check "config: a tenant no store lists is exit 2 naming the directory" \
    "$RC|$(contains "$OUT" "$HOME/code/gamma-repo: tenant 'gamma' is in no store of $CONFIG")" "2|yes"

# ---------------------------------------------------------------------------------------------
# tenant-route, and the tools the script needs.
# ---------------------------------------------------------------------------------------------

printf 'tenant-route: its failures are never a default\n'
reset_scene
make_checkout code/route-refuses-repo "git@github.com:$FIXTURE_OWNER/route-refuses-repo.git"
run_sut --list
check "tenant-route: a non-zero exit is exit 2 naming the directory" \
    "$RC|$(contains "$OUT" "tenant-route could not answer for $HOME/code/route-refuses-repo (exit 3)")" "2|yes"

reset_scene
make_checkout code/route-garbled-repo "git@github.com:$FIXTURE_OWNER/route-garbled-repo.git"
run_sut --list
garbled_answer="$RC|$(contains "$OUT" "tenant-route named no tenant for $HOME/code/route-garbled-repo")"
reset_scene
make_checkout code/route-blank-repo "git@github.com:$FIXTURE_OWNER/route-blank-repo.git"
run_sut --list
check "tenant-route: an answer with no tenant is exit 2 naming the directory" \
    "$garbled_answer|$RC|$(contains "$OUT" "tenant-route named no tenant for $HOME/code/route-blank-repo")" "2|yes|2|yes"

reset_scene
OUT=$(PATH="$NO_JQ_BIN" CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" CLAUDE_MEMORY_STORES_ROOT="$STORES_ROOT" \
    CLAUDE_MEMORY_CONFIG="$CONFIG" CLAUDE_MEMORY_TENANT_ROUTE="$ROUTE_STUB" "$SUT" --list 2>&1); RC=$?
check "tools: jq missing is exit 2 naming it" "$RC|$(contains "$OUT" 'claude-memory-link: jq is required')" "2|yes"

NO_GIT_BIN="$TMPROOT/no-git-bin"
mkdir -p "$NO_GIT_BIN"
for tool in bash dirname sed jq; do ln -s "$(command -v "$tool")" "$NO_GIT_BIN/$tool"; done
OUT=$(PATH="$NO_GIT_BIN" CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" CLAUDE_MEMORY_STORES_ROOT="$STORES_ROOT" \
    CLAUDE_MEMORY_CONFIG="$CONFIG" CLAUDE_MEMORY_TENANT_ROUTE="$ROUTE_STUB" "$SUT" --list 2>&1); RC=$?
check "tools: git missing is exit 2 naming it" "$RC|$(contains "$OUT" 'claude-memory-link: git is required')" "2|yes"

# Every default path hangs off HOME. A raw `unbound variable` would exit 1, which --check's callers
# read as "attention" rather than could-not-run. --help needs no home.
OUT=$(env -u HOME CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" CLAUDE_MEMORY_STORES_ROOT="$STORES_ROOT" \
    CLAUDE_MEMORY_CONFIG="$CONFIG" CLAUDE_MEMORY_TENANT_ROUTE="$ROUTE_STUB" "$SUT" --check 2>&1); RC=$?
home_unset_check="$RC|$(contains "$OUT" 'claude-memory-link: HOME is not set')"
OUT=$(env -u HOME "$SUT" --help 2>&1); RC=$?
check "tools: HOME unset is exit 2 naming it (--help still works)" \
    "$home_unset_check|$RC|$(contains "$OUT" '--check')" "2|yes|0|yes"

# ---------------------------------------------------------------------------------------------
# --apply: the swap, the merge and the resume. Each scene is one checkout with a real memory
# directory unless it says otherwise. A wrapper first on PATH is how a row gets between two steps of
# the script, as a session writing at that moment would.
# ---------------------------------------------------------------------------------------------

STUB_BIN="$TMPROOT/apply-stub-bin"
STUB_STATE_FILE="$TMPROOT/apply-stub-state"
export STUB_STATE_FILE
OLD_MTIME_STAMP='200101010000'
MARKER_PAST_MTIME_STAMP='200201010000'
PARTIAL_SUFFIX='.link-partial'
CONFLICT_MD_SUFFIX=".conflict-$FIXTURE_HOST.md"
UTC_STAMP_NAME_RE='/memory\.replaced-[0-9]{8}T[0-9]{6}Z$'

# apply_scene REPO — a new scene with one checkout and its real, empty memory directory. Sets $key,
# $key_dir, $memory_dir and $store_dir.
apply_scene() {
    reset_scene
    make_checkout "code/$1" "git@github.com:$FIXTURE_OWNER/$1.git"
    key=$(key_of "$HOME/code/$1")
    key_dir="$PROJECTS_DIR/$key"
    memory_dir="$key_dir/memory"
    store_dir="$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/$1"
    mkdir -p "$memory_dir" || fatal "could not create the memory directory of $1"
}

# pending_scene REPO — as a run stopped before its merge finished: memory is already the link, and
# $replaced_dir exists, empty and unmarked.
pending_scene() {
    apply_scene "$1"
    rmdir "$memory_dir" || fatal "could not clear the memory directory of $1"
    mkdir -p "$store_dir" || fatal "could not create the store directory of $1"
    ln -s "$store_dir" "$memory_dir" || fatal "could not link the memory of $1"
    replaced_dir="$key_dir/$REPLACED_STAMP"
    mkdir -p "$replaced_dir" || fatal "could not create the replaced directory of $1"
}

# write_file PATH BODY — PATH holding BODY and a newline, its parent created.
write_file() {
    mkdir -p "$(dirname "$1")" || fatal "could not create the parent of $1"
    printf '%s\n' "$2" > "$1" || fatal "could not write $1"
}

# body_of PATH — what PATH holds, or <absent>.
body_of() { if [[ -f "$1" ]]; then cat "$1"; else printf '<absent>'; fi; }

# linked_line COPIED IDENTICAL KEPT_BOTH — the expected line for the scene's key.
linked_line() { printf 'linked %s -> %s (copied %d, identical %d, kept-both %d)' "$key" "$store_dir" "$1" "$2" "$3"; }

# memory_kind PATH — what a memory entry is: `link to <target>`, `real` or `absent`.
memory_kind() {
    if [[ -L "$1" ]]; then
        printf 'link to %s' "$(readlink "$1")"
    elif [[ -d "$1" ]]; then
        printf 'real'
    else
        printf 'absent'
    fi
}

# replaced_dir_counts KEY_DIR — how many replaced directories hold the marker and how many do not.
replaced_dir_counts() {
    local candidate_dir marked_count=0 unmarked_count=0
    for candidate_dir in "$1"/memory.replaced-*; do
        [[ -d "$candidate_dir" ]] || continue
        if [[ -f "$candidate_dir/$MERGED_MARKER" ]]; then
            marked_count=$((marked_count + 1))
        else
            unmarked_count=$((unmarked_count + 1))
        fi
    done
    printf '%d marked, %d unmarked' "$marked_count" "$unmarked_count"
}

# tree_fingerprint — one hash of every path, type, link target, size and mtime in the scene.
tree_fingerprint() {
    find "$HOME" "$PROJECTS_DIR" "$STORES_ROOT" -printf '%p %y %l %s %T@\n' | LC_ALL=C sort | sha256sum
}

# file_manifest DIR — every file under DIR but the marker, by content hash.
file_manifest() {
    (cd "$1" && find . -type f ! -name "$MERGED_MARKER" -exec sha256sum {} + | LC_ALL=C sort)
}

# partial_of DIR NAME — the partial-copy path a merge uses for DIR/NAME.
partial_of() { printf '%s/.%s%s' "$1" "$2" "$PARTIAL_SUFFIX"; }

# partial_count DIR — how many partial copies lie under DIR.
partial_count() { find "$1" -name ".*$PARTIAL_SUFFIX" | wc -l | tr -d ' '; }

# write_stub TOOL — make $STUB_BIN hold one wrapper for TOOL, its sh body from stdin, with $real_tool
# naming the real one. $STUB_STATE_FILE starts absent, for a body that counts its calls.
write_stub() {
    local tool=$1 real_tool
    real_tool=$(command -v "$tool") || fatal "no $tool to wrap"
    rm -rf "$STUB_BIN" "$STUB_STATE_FILE"
    mkdir -p "$STUB_BIN" || fatal "could not create the stub directory"
    { printf '#!/bin/sh\nreal_tool=%q\n' "$real_tool"; cat; } > "$STUB_BIN/$tool" || fatal "could not write the $tool stub"
    chmod +x "$STUB_BIN/$tool" || fatal "could not make the $tool stub executable"
}

printf 'apply: a real directory becomes a link\n'
apply_scene real-to-link
write_file "$memory_dir/MEMORY.md" '- [topic](topic.md)'
write_file "$memory_dir/topic.md" 'topic body'
source_manifest=$(file_manifest "$memory_dir")
stamp_hour_before=$(date -u +%Y%m%dT%H)
TZ=Etc/GMT-12 run_sut --apply
stamp_hour_after=$(date -u +%Y%m%dT%H)
apply_result="$RC|$OUT"
replaced_dirs=("$key_dir"/memory.replaced-*)
run_sut --list
check "apply: a real directory becomes a link and every file is in the store" \
    "$apply_result|$(memory_kind "$memory_dir")|$(row_of_key "$key" | cut -f2)|$(body_of "$store_dir/MEMORY.md")|$(body_of "$store_dir/topic.md")" \
    "0|$(linked_line 2 0 0)|link to $store_dir|LINKED|- [topic](topic.md)|topic body"
check "apply: the replaced directory still holds every original file" \
    "$(file_manifest "${replaced_dirs[0]}")" "$source_manifest"
replaced_stamp_hour=${replaced_dirs[0]##*memory.replaced-}
replaced_stamp_hour=${replaced_stamp_hour:0:11}
check "apply: the replaced directory is named by a UTC stamp and holds the marker" \
    "${#replaced_dirs[@]}|$([[ "${replaced_dirs[0]}" =~ $UTC_STAMP_NAME_RE ]] && printf named)|$([[ "$replaced_stamp_hour" == "$stamp_hour_before" || "$replaced_stamp_hour" == "$stamp_hour_after" ]] && printf utc)|$(replaced_dir_counts "$key_dir")" \
    "1|named|utc|1 marked, 0 unmarked"

tree_before=$(tree_fingerprint)
run_sut --apply
check "apply: a second run prints nothing" "$RC|$OUT|$(tree_fingerprint)" "0||$tree_before"

apply_scene copy-metadata
write_file "$memory_dir/old.md" 'old body'
chmod 640 "$memory_dir/old.md"
touch -t "$OLD_MTIME_STAMP" "$memory_dir/old.md"
expected_metadata=$(stat -c '%a %Y' "$memory_dir/old.md")
run_sut --apply
check "apply: a copied file keeps its mtime and mode" "$RC|$(stat -c '%a %Y' "$store_dir/old.md" 2>&1)" "0|$expected_metadata"

apply_scene identical-file
write_file "$memory_dir/same.md" 'same body'
write_file "$store_dir/same.md" 'same body'
touch -t "$OLD_MTIME_STAMP" "$store_dir/same.md"
expected_metadata=$(stat -c '%Y' "$store_dir/same.md")
run_sut --apply
check "apply: identical files are not copied" \
    "$RC|$OUT|$(stat -c '%Y' "$store_dir/same.md")" "0|$(linked_line 0 1 0)|$expected_metadata"

printf 'apply: a file that differs\n'
apply_scene differing-topic
write_file "$memory_dir/topic.md" 'replaced body'
write_file "$store_dir/topic.md" 'store body'
run_sut --apply
check "apply: a differing topic file becomes a conflict copy and the store's copy is untouched" \
    "$RC|$OUT|$(body_of "$store_dir/topic.md")|$(body_of "$store_dir/topic$CONFLICT_MD_SUFFIX")" \
    "0|$(linked_line 0 0 1)|store body|replaced body"

apply_scene replaced-copy-newer
write_file "$memory_dir/topic.md" 'the newer body'
write_file "$store_dir/topic.md" 'the older body'
touch -t "$OLD_MTIME_STAMP" "$store_dir/topic.md"
run_sut --apply
check "apply: the store's copy keeps its name even when the replaced copy is newer" \
    "$RC|$(body_of "$store_dir/topic.md")|$(body_of "$store_dir/topic$CONFLICT_MD_SUFFIX")" \
    "0|the older body|the newer body"

apply_scene earlier-conflict
write_file "$memory_dir/topic.md" 'replaced body'
write_file "$store_dir/topic.md" 'store body'
write_file "$store_dir/topic$CONFLICT_MD_SUFFIX" 'an earlier conflict'
run_sut --apply
check "apply: an existing conflict copy with another body is kept, and the new one is numbered .2" \
    "$RC|$(body_of "$store_dir/topic$CONFLICT_MD_SUFFIX")|$(body_of "$store_dir/topic.conflict-$FIXTURE_HOST.2.md")" \
    "0|an earlier conflict|replaced body"

apply_scene same-conflict
write_file "$memory_dir/topic.md" 'replaced body'
write_file "$store_dir/topic.md" 'store body'
write_file "$store_dir/topic$CONFLICT_MD_SUFFIX" 'replaced body'
run_sut --apply
check "apply: a conflict copy with the same body is not written twice" \
    "$RC|$OUT|$(body_of "$store_dir/topic.conflict-$FIXTURE_HOST.2.md")" "0|$(linked_line 0 0 1)|<absent>"

apply_scene conflict-names-taken
write_file "$memory_dir/topic.md" 'replaced body'
write_file "$store_dir/topic.md" 'store body'
write_file "$store_dir/topic$CONFLICT_MD_SUFFIX" 'taken'
for (( conflict_ordinal = 2; conflict_ordinal <= 100; conflict_ordinal++ )); do
    write_file "$store_dir/topic.conflict-$FIXTURE_HOST.$conflict_ordinal.md" 'taken'
done
run_sut --apply
check "apply: with every conflict name taken the file is reported, exit 2 and no marker" \
    "$RC|$(contains "$OUT" "gave up on a conflict copy of $store_dir/topic.md")|$(body_of "$store_dir/topic.conflict-$FIXTURE_HOST.101.md")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|<absent>|0 marked, 1 unmarked"

apply_scene no-extension
write_file "$memory_dir/notes" 'replaced notes'
write_file "$store_dir/notes" 'store notes'
write_file "$memory_dir/.hidden" 'replaced hidden'
write_file "$store_dir/.hidden" 'store hidden'
run_sut --apply
check "apply: a file with no extension gets the infix appended" \
    "$RC|$(body_of "$store_dir/notes.conflict-$FIXTURE_HOST")|$(body_of "$store_dir/.hidden.conflict-$FIXTURE_HOST")" \
    "0|replaced notes|replaced hidden"

apply_scene final-extension
write_file "$memory_dir/backup.tar.gz" 'replaced archive'
write_file "$store_dir/backup.tar.gz" 'store archive'
run_sut --apply
check "apply: the infix goes before the final extension only" \
    "$RC|$(body_of "$store_dir/backup.tar.conflict-$FIXTURE_HOST.gz")" "0|replaced archive"

printf 'apply: an index file is a line union\n'
apply_scene index-union
injected_path="$TMPROOT/injected-by-the-union"
injection_line="\$(touch '$injected_path')"
write_file "$memory_dir/MEMORY.md" "- shared
- [new](new.md)
$injection_line
- shared
- [new](new.md)"
write_file "$store_dir/MEMORY.md" $'- [kept](kept.md)\n- shared'
run_sut --apply
check "apply: MEMORY.md is a line union, store order first" \
    "$RC|$OUT|$(body_of "$store_dir/MEMORY.md")|$(body_of "$store_dir/MEMORY$CONFLICT_MD_SUFFIX")" \
    "0|$(linked_line 0 0 1)|- [kept](kept.md)
- shared
- [new](new.md)
$injection_line|<absent>"
check "apply: a line of an index file is text, and nothing in it runs" \
    "$([[ -e "$injected_path" ]] && printf 'it ran')" ""

apply_scene topic-index
write_file "$memory_dir/INDEX_topics.md" '- replaced line'
write_file "$store_dir/INDEX_topics.md" '- store line'
write_file "$memory_dir/NOT_INDEX_topics.md" '- replaced line'
write_file "$store_dir/NOT_INDEX_topics.md" '- store line'
run_sut --apply
check "apply: INDEX_*.md is a line union too, and a name that only resembles it is not" \
    "$RC|$(body_of "$store_dir/INDEX_topics.md")|$(body_of "$store_dir/NOT_INDEX_topics.md")|$(body_of "$store_dir/NOT_INDEX_topics$CONFLICT_MD_SUFFIX")" \
    "0|- store line
- replaced line|- store line|- replaced line"

apply_scene index-subset
write_file "$memory_dir/MEMORY.md" '- shared'
write_file "$store_dir/MEMORY.md" $'- kept\n- shared'
touch -t "$OLD_MTIME_STAMP" "$store_dir/MEMORY.md"
expected_metadata=$(stat -c '%Y' "$store_dir/MEMORY.md")
run_sut --apply
check "apply: an index with no new line is not written" \
    "$RC|$OUT|$(stat -c '%Y' "$store_dir/MEMORY.md")" "0|$(linked_line 0 0 1)|$expected_metadata"

apply_scene index-no-newline
printf -- '- replaced last' > "$memory_dir/MEMORY.md"
mkdir -p "$store_dir"
printf -- '- store last' > "$store_dir/MEMORY.md"
run_sut --apply
check "apply: an index with no final newline keeps every line whole" \
    "$RC|$(body_of "$store_dir/MEMORY.md")|$(tail -c 1 "$store_dir/MEMORY.md" | od -An -c | tr -d ' ')" \
    "0|- store last
- replaced last|\\n"

apply_scene index-store-no-newline
write_file "$memory_dir/MEMORY.md" '- shared'
mkdir -p "$store_dir"
printf -- '- shared' > "$store_dir/MEMORY.md"
run_sut --apply
check "apply: a store index's last line counts as a line even with no final newline" \
    "$RC|$OUT|$(body_of "$store_dir/MEMORY.md")" "0|$(linked_line 0 0 1)|- shared"

apply_scene index-empty-store
write_file "$memory_dir/MEMORY.md" $'- first\n- second'
mkdir -p "$store_dir"
: > "$store_dir/MEMORY.md"
run_sut --apply
check "apply: an empty index in the store takes every line, with no blank line first" \
    "$RC|$(body_of "$store_dir/MEMORY.md")" "0|- first
- second"

printf 'apply: every file, whatever it is\n'
apply_scene archive-subdir
write_file "$memory_dir/.archive/old.md" 'old body'
write_file "$memory_dir/.archive/topic.md" 'replaced topic'
write_file "$store_dir/.archive/topic.md" 'store topic'
write_file "$memory_dir/.archive/deeper/MEMORY.md" '- replaced line'
write_file "$store_dir/.archive/deeper/MEMORY.md" '- store line'
run_sut --apply
check "apply: a subdirectory (.archive/) is merged by the same rule" \
    "$RC|$OUT|$(body_of "$store_dir/.archive/old.md")|$(body_of "$store_dir/.archive/topic.md")|$(body_of "$store_dir/.archive/topic$CONFLICT_MD_SUFFIX")|$(body_of "$store_dir/.archive/deeper/MEMORY.md")" \
    "0|$(linked_line 1 0 2)|old body|store topic|replaced topic|- store line
- replaced line"

apply_scene awkward-names
AWKWARD_NAMES=('a b.md' '-dash.md' $'new\nline.md' 'star*.md' '[x].md')
awkward_expected=''
for awkward_name in "${AWKWARD_NAMES[@]}"; do
    write_file "$memory_dir/$awkward_name" "body of $awkward_name"
    awkward_expected+="body of $awkward_name|"
done
write_file "$memory_dir/-differs.md" 'replaced body'
write_file "$store_dir/-differs.md" 'store body'
run_sut --apply
awkward_results=''
for awkward_name in "${AWKWARD_NAMES[@]}"; do
    awkward_results+="$(body_of "$store_dir/$awkward_name")|"
done
check "apply: awkward file names survive" \
    "$RC|$OUT|$awkward_results$(body_of "$store_dir/-differs$CONFLICT_MD_SUFFIX")" \
    "0|$(linked_line 5 0 1)|${awkward_expected}replaced body"

# Followed, the link would copy what it points at into a store that a sync pushes to a remote.
apply_scene symlink-copied
write_file "$TMPROOT/outside-store-target" 'outside body'
ln -s "$TMPROOT/outside-store-target" "$memory_dir/pointer.md"
ln -s "$TMPROOT/no-such-target" "$memory_dir/dangling.md"
run_sut --apply
check "apply: a symlink in a memory directory stays a link, and its target is not copied" \
    "$RC|$OUT|$(readlink "$store_dir/pointer.md")|$(readlink "$store_dir/dangling.md")" \
    "0|$(linked_line 2 0 0)|$TMPROOT/outside-store-target|$TMPROOT/no-such-target"

apply_scene symlink-compared
write_file "$TMPROOT/link-target-one" 'one body'
write_file "$TMPROOT/link-target-two" 'one body'
ln -s "$TMPROOT/link-target-one" "$memory_dir/same.md"
ln -s "$TMPROOT/link-target-one" "$memory_dir/other.md"
mkdir -p "$store_dir"
ln -s "$TMPROOT/link-target-one" "$store_dir/same.md"
ln -s "$TMPROOT/link-target-two" "$store_dir/other.md"
run_sut --apply
check "apply: a symlink is compared by where it points, not by what it holds" \
    "$RC|$OUT|$(readlink "$store_dir/other.md")|$(readlink "$store_dir/other$CONFLICT_MD_SUFFIX")" \
    "0|$(linked_line 0 1 1)|$TMPROOT/link-target-two|$TMPROOT/link-target-one"

# A directory where the memory has a file cannot be overwritten or compared; the file goes beside it.
apply_scene directory-in-store
write_file "$memory_dir/MEMORY.md" '- replaced line'
mkdir -p "$store_dir/MEMORY.md"
run_sut --apply
check "apply: a directory in the store where the memory has a file gets a conflict copy" \
    "$RC|$OUT|$(body_of "$store_dir/MEMORY$CONFLICT_MD_SUFFIX")" "0|$(linked_line 0 0 1)|- replaced line"

printf 'apply: a session writing during the swap\n'
apply_scene late-write
write_file "$memory_dir/MEMORY.md" '- index'
write_stub mv <<'STUB'
printf 'late body\n' > "$STUB_MEMORY_DIR/late.md"
exec "$real_tool" "$@"
STUB
PATH="$STUB_BIN:$PATH" STUB_MEMORY_DIR="$memory_dir" run_sut --apply
check "apply: a file written just before the rename is still merged" \
    "$RC|$OUT|$(body_of "$store_dir/late.md")" "0|$(linked_line 2 0 0)|late body"

apply_scene recreated-memory
write_file "$memory_dir/MEMORY.md" '- index'
write_stub ln <<'STUB'
if [ ! -e "$STUB_STATE_FILE" ]; then
    : > "$STUB_STATE_FILE"
    mkdir -p "$STUB_MEMORY_DIR"
    printf 'recreated body\n' > "$STUB_MEMORY_DIR/recreated.md"
fi
exec "$real_tool" "$@"
STUB
PATH="$STUB_BIN:$PATH" STUB_MEMORY_DIR="$memory_dir" run_sut --apply
apply_result="$RC|$OUT"
run_sut --list
check "apply: a memory directory recreated before the link is merged too" \
    "$apply_result|$(row_of_key "$key" | cut -f2)|$(body_of "$store_dir/recreated.md")|$(replaced_dir_counts "$key_dir")" \
    "0|$(linked_line 2 0 0)|LINKED|recreated body|2 marked, 0 unmarked"

apply_scene keeps-recreating
write_file "$memory_dir/MEMORY.md" '- index'
write_stub ln <<'STUB'
printf 'x' >> "$STUB_STATE_FILE"
mkdir -p "$STUB_MEMORY_DIR"
printf 'recreated body\n' > "$STUB_MEMORY_DIR/recreated.md"
exec "$real_tool" "$@"
STUB
PATH="$STUB_BIN:$PATH" STUB_MEMORY_DIR="$memory_dir" run_sut --apply
check "apply: a writer that keeps recreating the directory is given up on after 3 retries, exit 2" \
    "$RC|$(contains "$OUT" "gave up on $memory_dir")|$(wc -c < "$STUB_STATE_FILE" | tr -d ' ')|$(memory_kind "$memory_dir")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|4|real|0 marked, 4 unmarked"
run_sut --apply
check "resume: the next --apply finishes what giving up left" \
    "$RC|$(memory_kind "$memory_dir")|$(body_of "$store_dir/recreated.md")|$(body_of "$store_dir/MEMORY.md")|$(replaced_dir_counts "$key_dir")" \
    "0|link to $store_dir|recreated body|- index|5 marked, 0 unmarked"

# A writer that beats the publish: the check said absent, and the file is there by the time the copy
# is ready to take the name.
apply_scene writer-beats-copy
write_file "$memory_dir/topic.md" 'replaced body'
write_stub cp <<'STUB'
if [ ! -e "$STUB_STATE_FILE" ]; then
    : > "$STUB_STATE_FILE"
    printf "the writer's body\n" > "$STUB_TARGET_PATH"
fi
exec "$real_tool" "$@"
STUB
PATH="$STUB_BIN:$PATH" STUB_TARGET_PATH="$store_dir/topic.md" run_sut --apply
check "apply: a file that appears in the store just before the copy is not overwritten" \
    "$RC|$OUT|$(body_of "$store_dir/topic.md")|$(body_of "$store_dir/topic$CONFLICT_MD_SUFFIX")" \
    "0|$(linked_line 0 0 1)|the writer's body|replaced body"

printf 'resume: a run stopped before the merge finished\n'
# A real kill, as the second file's copy is checked: one file is in the store, the other only a
# partial, and the link is in place. cmp, because the script runs it directly, so its parent is the
# script and no subshell.
apply_scene killed-merge
write_file "$memory_dir/first.md" 'first body'
write_file "$memory_dir/second.md" 'second body'
write_stub cmp <<'STUB'
if [ -e "$STUB_STATE_FILE" ]; then
    kill -9 "$PPID"
    exit 1
fi
: > "$STUB_STATE_FILE"
exec "$real_tool" "$@"
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
killed_rc=$RC
killed_memory=$(memory_kind "$memory_dir")
killed_partials=$(partial_count "$store_dir")
run_sut --check
check "resume: an unmarked replaced directory makes --check exit 1" \
    "$killed_rc|$killed_memory|$killed_partials|$RC|$(contains "$OUT" "$key${TAB}PENDING-MERGE")|$(replaced_dir_counts "$key_dir")" \
    "137|link to $store_dir|1|1|yes|0 marked, 1 unmarked"
run_sut --apply
check "resume: the next --apply merges it and writes the marker" \
    "$RC|$OUT|$(body_of "$store_dir/first.md")|$(body_of "$store_dir/second.md")|$(replaced_dir_counts "$key_dir")|$(partial_count "$store_dir")" \
    "0|$(linked_line 1 1 0)|first body|second body|1 marked, 0 unmarked|0"
# Older than the marker, so the marker settles it. A newer file is the one case it does not: the rows
# under "apply: a file written after the marker".
late_replaced_dirs=("$key_dir"/memory.replaced-*)
write_file "${late_replaced_dirs[0]}/added-afterwards.md" 'added afterwards'
touch -t "$OLD_MTIME_STAMP" "${late_replaced_dirs[0]}/added-afterwards.md"
run_sut --apply
check "resume: a marked replaced directory is not merged again" \
    "$RC|$OUT|$(body_of "$store_dir/added-afterwards.md")" "0||<absent>"

# Stopped between the rename and the link, with a file to merge: the failed ln is the stop.
apply_scene ln-fails
write_file "$memory_dir/MEMORY.md" '- index'
write_stub ln <<'STUB'
exit 1
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
check "apply: a link that fails is exit 2 and the replaced directory stays unmarked" \
    "$RC|$(contains "$OUT" "could not link $memory_dir")|$(memory_kind "$memory_dir")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|absent|0 marked, 1 unmarked"
run_sut --apply
check "resume: a run stopped before the link gets its link and finishes the merge" \
    "$RC|$OUT|$(memory_kind "$memory_dir")|$(replaced_dir_counts "$key_dir")" \
    "0|$(linked_line 1 0 0)|link to $store_dir|1 marked, 0 unmarked"

# The same stop with an empty directory: no entry and nothing in the store is no state at all, and
# only the replaced directory says this key was on its way to a link.
apply_scene ln-fails-empty
rmdir "$memory_dir"
mkdir -p "$key_dir/$REPLACED_STAMP"
run_sut --apply
check "resume: a run stopped before the link gets its link when the directory was empty" \
    "$RC|$OUT|$(memory_kind "$memory_dir")|$([[ -d "$store_dir" ]] && printf present)|$(replaced_dir_counts "$key_dir")" \
    "0|$(linked_line 0 0 0)|link to $store_dir|present|1 marked, 0 unmarked"

# A stop while a session has recreated the directory: the pending merge, then the swap.
pending_scene pending-then-real
write_file "$replaced_dir/from-replaced.md" 'from replaced'
rm "$memory_dir"
write_file "$memory_dir/from-real.md" 'from real'
run_sut --apply
check "resume: a pending merge is finished before a real directory is swapped" \
    "$RC|$OUT|$(memory_kind "$memory_dir")|$(body_of "$store_dir/from-replaced.md")|$(body_of "$store_dir/from-real.md")|$(replaced_dir_counts "$key_dir")" \
    "0|$(linked_line 2 0 0)|link to $store_dir|from replaced|from real|2 marked, 0 unmarked"

printf 'apply: the other states\n'
reset_scene
add_state MISSING
key=${EXPECTED_ROW[MISSING]%%"$TAB"*}
store_dir="$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/missing-repo"
run_sut --apply
check "apply: MISSING gets a link" \
    "$RC|$OUT|$(memory_kind "$PROJECTS_DIR/$key/memory")" "0|$(linked_line 0 0 0)|link to $store_dir"

reset_scene
add_state DANGLING
key=${EXPECTED_ROW[DANGLING]%%"$TAB"*}
store_dir="$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/dangling-repo"
run_sut --apply
apply_result="$RC|$OUT"
run_sut --list
check "apply: DANGLING gets its target back" \
    "$apply_result|$(row_of_key "$key" | cut -f2)|$([[ -d "$store_dir" ]] && printf present)" \
    "0|$(linked_line 0 0 0)|LINKED|present"

for untouched_state in NO-STORE WRONG-LINK UNMAPPED; do
    reset_scene
    add_state "$untouched_state"
    tree_before=$(tree_fingerprint)
    run_sut --apply
    check "apply: $untouched_state is left alone" "$RC|$OUT|$(tree_fingerprint)" "0||$tree_before"
done

# A pending merge with no store checked out here has nowhere it may go; nor has one no candidate claims.
reset_scene
make_checkout code/beta-pending-apply "git@github.com:$FIXTURE_OWNER/beta-pending-apply.git"
key=$(key_of "$HOME/code/beta-pending-apply")
write_file "$PROJECTS_DIR/$key/$REPLACED_STAMP/topic.md" 'pending body'
tree_before=$(tree_fingerprint)
run_sut --apply
apply_result="$RC|$OUT|$(tree_fingerprint)"
run_sut --check
check "apply: a pending merge with no store checked out is left alone, and --check still reports it" \
    "$apply_result|$RC|$(contains "$OUT" "$key${TAB}PENDING-MERGE")" "0||$tree_before|1|yes"

reset_scene
write_file "$PROJECTS_DIR/$NO_CHECKOUT_KEY/$REPLACED_STAMP/topic.md" 'pending body'
tree_before=$(tree_fingerprint)
run_sut --apply
apply_result="$RC|$OUT|$(tree_fingerprint)"
run_sut --check
check "apply: a pending merge no candidate claims is left alone, and --check still reports it" \
    "$apply_result|$RC|$(contains "$OUT" "$NO_CHECKOUT_KEY${TAB}PENDING-MERGE")" "0||$tree_before|1|yes"

pending_scene pending-wrong-link
write_file "$replaced_dir/topic.md" 'pending body'
rm "$memory_dir"
mkdir -p "$TMPROOT/elsewhere"
ln -s "$TMPROOT/elsewhere" "$memory_dir"
run_sut --apply
check "apply: a WRONG-LINK key finishes its pending merge, says merged, and keeps its link" \
    "$RC|$OUT|$(memory_kind "$memory_dir")|$(body_of "$store_dir/topic.md")|$(replaced_dir_counts "$key_dir")" \
    "0|merged $key -> $store_dir (copied 1, identical 0, kept-both 0)|link to $TMPROOT/elsewhere|pending body|1 marked, 0 unmarked"

two_key_source=$(make_source_repo two-key-source)
reset_scene
make_checkout code/two-key-super "git@github.com:$FIXTURE_OWNER/two-key-super.git"
git -C "$HOME/code/two-key-super" commit -q --allow-empty -m first || fatal "could not commit in two-key-super"
add_submodule code/two-key-super two-key-sub two-key-sub "$two_key_source"
git -C "$HOME/code/two-key-super/two-key-sub" remote set-url origin "git@github.com:$FIXTURE_OWNER/two-key-sub.git" \
    || fatal "could not set the submodule's origin"
own_key=$(key_of "$HOME/code/two-key-super/two-key-sub")
git_dir_key=$(key_of "$HOME/code/two-key-super/.git/modules/two-key-sub")
store_dir="$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/two-key-sub"
real_memory "$own_key" own.md
real_memory "$git_dir_key" git-dir.md
run_sut --apply
check "apply: a submodule's two keys both link to one store directory" \
    "$RC|$(line_count "$OUT")|$(memory_kind "$PROJECTS_DIR/$own_key/memory")|$(memory_kind "$PROJECTS_DIR/$git_dir_key/memory")|$(body_of "$store_dir/own.md")|$(body_of "$store_dir/git-dir.md")" \
    "0|2|link to $store_dir|link to $store_dir|fixture memory|fixture memory"

# A slug keeps what the directory's name holds, so a newline there must not split the line.
reset_scene
set_plain_dirs '["new\nline"]'
mkdir -p "$HOME/new"$'\n'"line"
key=$(key_of "$HOME/new"$'\n'"line")
real_memory "$key" MEMORY.md
run_sut --apply
check "apply: a store directory with a newline in its name stays on one line, escaped" \
    "$RC|$(line_count "$OUT")|$OUT" \
    "0|1|linked $key -> $STORES_ROOT/$ALPHA_STORE/dirs/new\\nline (copied 1, identical 0, kept-both 0)"

printf 'apply: --only\n'
reset_scene
make_checkout code/only-this "git@github.com:$FIXTURE_OWNER/only-this.git"
make_checkout code/not-this "git@github.com:$FIXTURE_OWNER/not-this.git"
only_key=$(key_of "$HOME/code/only-this")
not_this_key=$(key_of "$HOME/code/not-this")
real_memory "$only_key" MEMORY.md
real_memory "$not_this_key" MEMORY.md
run_sut --apply --only "$only_key"
only_result="$RC|$(line_count "$OUT")"
run_sut --list
check "apply: --only limits the run to one key" \
    "$only_result|$(row_of_key "$only_key" | cut -f2)|$(row_of_key "$not_this_key" | cut -f2)" "0|1|LINKED|REAL-DIR"

run_sut --apply --only "$NO_CHECKOUT_KEY"
check "apply: --only naming a key no candidate claims is exit 2 naming it" \
    "$RC|$(contains "$OUT" "no candidate on this host claims key $NO_CHECKOUT_KEY")" "2|yes"

printf 'dry-run: the same lines, and nothing changed\n'
apply_scene dry-run-repo
write_file "$memory_dir/absent.md" 'absent body'
write_file "$memory_dir/same.md" 'same body'
write_file "$store_dir/same.md" 'same body'
write_file "$memory_dir/topic.md" 'replaced body'
write_file "$store_dir/topic.md" 'store body'
write_file "$memory_dir/MEMORY.md" '- replaced line'
write_file "$store_dir/MEMORY.md" '- store line'
tree_before=$(tree_fingerprint)
run_sut --apply --dry-run
check "dry-run: prints the counts and changes nothing" \
    "$RC|$OUT|$(tree_fingerprint)|$([[ -e "$STATE_DIR" ]] && printf 'made a state dir')" \
    "0|$(linked_line 1 1 2)|$tree_before|"
dry_run_out=$OUT
run_sut --apply
check "dry-run: the run itself then prints the same line" "$RC|$OUT" "0|$dry_run_out"

reset_scene
add_state MISSING
add_state DANGLING
add_state PENDING-MERGE
write_file "$PROJECTS_DIR/${EXPECTED_ROW[PENDING-MERGE]%%"$TAB"*}/$REPLACED_STAMP/topic.md" 'pending body'
tree_before=$(tree_fingerprint)
run_sut --apply --dry-run
dry_run_result="$RC|$(line_count "$OUT")|$(tree_fingerprint)"
dry_run_out=$OUT
run_sut --apply
check "dry-run: MISSING, DANGLING and PENDING-MERGE print what the run prints, and change nothing" \
    "$dry_run_result|$dry_run_out" "0|3|$tree_before|$OUT"

# One new file in two unmerged directories: the run copies it once and then finds it identical.
apply_scene dry-run-two-dirs
write_file "$memory_dir/shared.md" 'shared body'
write_file "$key_dir/$REPLACED_STAMP/shared.md" 'shared body'
run_sut --apply --dry-run
dry_run_result="$RC|$OUT"
run_sut --apply
check "dry-run: a file in two unmerged directories counts as the run counts it" \
    "$dry_run_result|$RC|$OUT" "0|$(linked_line 1 1 0)|0|$(linked_line 1 1 0)"

# Stopped before the link with an empty directory: only the replaced directory says a link is due.
apply_scene dry-run-empty-pending
rmdir "$memory_dir"
mkdir -p "$key_dir/$REPLACED_STAMP"
tree_before=$(tree_fingerprint)
run_sut --apply --dry-run
check "dry-run: a run stopped before the link prints the line it would print, and adds nothing" \
    "$RC|$OUT|$(tree_fingerprint)" "0|$(linked_line 0 0 0)|$tree_before"

printf 'apply: the lock\n'
apply_scene lock-held
write_file "$memory_dir/MEMORY.md" '- index'
mkdir -p "$STATE_DIR" || fatal "could not create the state dir"
lock_taken_file="$TMPROOT/lock-taken"
lock_released_file="$TMPROOT/lock-released"
rm -f "$lock_taken_file" "$lock_released_file"
# Still holding the lock when it writes the second file, so a run that waited always sees that file.
# shellcheck disable=SC2016  # expanded by the bash -c, not this one
flock "$STATE_DIR/link.lock" bash -c ': > "$1"; sleep 1; : > "$2"' _ "$lock_taken_file" "$lock_released_file" &
lock_holder_pid=$!
for (( lock_wait_step = 0; lock_wait_step < 100; lock_wait_step++ )); do
    [[ -e "$lock_taken_file" ]] && break
    sleep 0.05
done
[[ -e "$lock_taken_file" ]] || fatal "the row's lock holder never took the lock"
run_sut --apply
check "lock: a second run waits while the lock is held" \
    "$RC|$OUT|$([[ -e "$lock_released_file" ]] && printf 'finished after the release')" \
    "0|$(linked_line 1 0 0)|finished after the release"
wait "$lock_holder_pid"

apply_scene lock-default-dir
STATE_DIR='' run_sut --apply
check "lock: the state dir defaults to ~/.local/state/claude-memory-sync" \
    "$RC|$([[ -f "$HOME/.local/state/claude-memory-sync/link.lock" ]] && printf present)" "0|present"

apply_scene lock-no-state-dir
write_file "$memory_dir/MEMORY.md" '- index'
: > "$STATE_DIR"
tree_before=$(tree_fingerprint)
run_sut --apply
check "lock: a state dir that cannot be created is exit 2, with nothing touched" \
    "$RC|$(contains "$OUT" "could not create $STATE_DIR")|$(tree_fingerprint)" "2|yes|$tree_before"
rm -f "$STATE_DIR"

apply_scene lock-file-blocked
write_file "$memory_dir/MEMORY.md" '- index'
mkdir -p "$STATE_DIR/link.lock"
tree_before=$(tree_fingerprint)
run_sut --apply
check "lock: a lock file that cannot be opened is exit 2, with nothing touched" \
    "$RC|$(contains "$OUT" "could not open the lock $STATE_DIR/link.lock")|$(tree_fingerprint)" "2|yes|$tree_before"

apply_scene lock-fails
write_file "$memory_dir/MEMORY.md" '- index'
write_stub flock <<'STUB'
exit 1
STUB
tree_before=$(tree_fingerprint)
PATH="$STUB_BIN:$PATH" run_sut --apply
check "lock: a lock that cannot be taken is exit 2, with nothing touched" \
    "$RC|$(contains "$OUT" "could not take the lock $STATE_DIR/link.lock")|$(tree_fingerprint)" "2|yes|$tree_before"

# The wait is bounded, so a link step on the sync's timer cannot spend the sync's time on a lock a
# by-hand run holds. The holder keeps the lock past the row's wait of one second.
LOCK_WAIT_ROW_SECONDS=1
LOCK_HOLD_PAST_WAIT_SECONDS=3
apply_scene lock-wait-runs-out
write_file "$memory_dir/MEMORY.md" '- index'
mkdir -p "$STATE_DIR" || fatal "could not create the state dir"
lock_taken_file="$TMPROOT/lock-taken"
rm -f "$lock_taken_file"
# shellcheck disable=SC2016  # expanded by the bash -c, not this one
flock "$STATE_DIR/link.lock" bash -c ': > "$1"; sleep "$2"' _ "$lock_taken_file" "$LOCK_HOLD_PAST_WAIT_SECONDS" &
lock_holder_pid=$!
for (( lock_wait_step = 0; lock_wait_step < 100; lock_wait_step++ )); do
    [[ -e "$lock_taken_file" ]] && break
    sleep 0.05
done
[[ -e "$lock_taken_file" ]] || fatal "the row's lock holder never took the lock"
tree_before=$(tree_fingerprint)
CLAUDE_MEMORY_LOCK_WAIT_SECONDS=$LOCK_WAIT_ROW_SECONDS run_sut_bounded --apply
held_lock_result="$RC|$(contains "$OUT" "still held the lock $STATE_DIR/link.lock")|$(tree_fingerprint)"
CLAUDE_MEMORY_LOCK_WAIT_SECONDS=soon run_sut_bounded --apply
check "lock: a lock still held when the wait runs out is exit 2 naming it, with nothing renamed; a wait that is not whole seconds is exit 2" \
    "$held_lock_result|$RC|$(contains "$OUT" 'CLAUDE_MEMORY_LOCK_WAIT_SECONDS')|$(tree_fingerprint)" \
    "2|yes|$tree_before|2|yes|$tree_before"
wait "$lock_holder_pid"

printf 'apply: a failure stops only what failed\n'
apply_scene bad-file-keeps-going
write_file "$store_dir/aa" 'a file in the way'
write_file "$memory_dir/aa/x.md" 'x body'
write_file "$memory_dir/zz/y.md" 'y body'
write_file "$memory_dir/top.md" 'top body'
run_sut --apply
check "apply: a file that cannot be merged stops only itself: the rest reach the store, no marker, exit 2" \
    "$RC|$(contains "$OUT" "could not create $store_dir/aa")|$(body_of "$store_dir/aa")|$(body_of "$store_dir/zz/y.md")|$(body_of "$store_dir/top.md")|$(memory_kind "$memory_dir")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|a file in the way|y body|top body|link to $store_dir|0 marked, 1 unmarked"

# Three keys in discovery order. The stub spares b and c a real copy failure: only the fifo's name
# fails, so a regression fails these rows rather than hanging on the fifo.
reset_scene
for repo in a-stuck b-real c-pending; do
    make_checkout "code/$repo" "git@github.com:$FIXTURE_OWNER/$repo.git"
done
a_key=$(key_of "$HOME/code/a-stuck")
b_key=$(key_of "$HOME/code/b-real")
c_key=$(key_of "$HOME/code/c-pending")
b_store_dir="$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/b-real"
c_store_dir="$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/c-pending"
mkdir -p "$PROJECTS_DIR/$a_key/memory"
mkfifo "$PROJECTS_DIR/$a_key/memory/pipe"
real_memory "$b_key" MEMORY.md
write_file "$c_store_dir/.gitkeep-for-the-link" 'kept'
link_memory "$c_key" "$c_store_dir"
write_file "$PROJECTS_DIR/$c_key/$REPLACED_STAMP/pending.md" 'pending body'
write_stub cp <<'STUB'
case "$*" in *pipe*) exit 1 ;; esac
exec "$real_tool" "$@"
STUB
b_line="linked $b_key -> $b_store_dir (copied 1, identical 0, kept-both 0)"
c_line="linked $c_key -> $c_store_dir (copied 1, identical 0, kept-both 0)"
tree_before=$(tree_fingerprint)
PATH="$STUB_BIN:$PATH" run_sut --apply --dry-run
check "dry-run: a key that fails stops only itself too, and nothing changes" \
    "$RC|$(contains "$OUT" "$b_line")|$(contains "$OUT" "$c_line")|$(contains "$OUT" "could not finish 1 key(s): $a_key")|$(tree_fingerprint)" \
    "2|yes|yes|yes|$tree_before"
PATH="$STUB_BIN:$PATH" run_sut --apply
apply_result="$RC|$(contains "$OUT" "/pipe is neither a file nor a symlink")|$(contains "$OUT" "could not finish 1 key(s): $a_key")|$(contains "$OUT" "$b_line")|$(contains "$OUT" "$c_line")"
run_sut --list
check "apply: a key that fails stops only itself: later keys finish, exit 2 naming it" \
    "$apply_result|$(row_of_key "$a_key" | cut -f2)|$(row_of_key "$b_key" | cut -f2)|$(row_of_key "$c_key" | cut -f2)|$(body_of "$c_store_dir/pending.md")" \
    "2|yes|yes|yes|yes|PENDING-MERGE|LINKED|LINKED|pending body"

reset_scene
for repo in a-locked b-after-locked; do
    make_checkout "code/$repo" "git@github.com:$FIXTURE_OWNER/$repo.git"
done
a_key=$(key_of "$HOME/code/a-locked")
b_key=$(key_of "$HOME/code/b-after-locked")
real_memory "$a_key" MEMORY.md
real_memory "$b_key" MEMORY.md
chmod 000 "$PROJECTS_DIR/$a_key"
run_sut --apply
locked_key_result="$RC|$(contains "$OUT" "$PROJECTS_DIR/$a_key is not a readable directory")|$(contains "$OUT" "could not finish 1 key(s): $a_key")|$(memory_kind "$PROJECTS_DIR/$b_key/memory")"
chmod 755 "$PROJECTS_DIR/$a_key"
check "apply: a key directory that cannot be read stops only itself" \
    "$locked_key_result" \
    "2|yes|yes|link to $STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/b-after-locked"

# New writes belong in the store whatever an older directory holds, so the link is not held back.
pending_scene pending-fails-real-waits
mkfifo "$replaced_dir/pipe"
rm "$memory_dir"
write_file "$memory_dir/new.md" 'new body'
write_stub cp <<'STUB'
case "$*" in *pipe*) exit 1 ;; esac
exec "$real_tool" "$@"
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
check "apply: a pending merge that fails does not hold the link back" \
    "$RC|$(contains "$OUT" "/pipe is neither a file nor a symlink")|$(memory_kind "$memory_dir")|$(body_of "$store_dir/new.md")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|link to $store_dir|new body|1 marked, 1 unmarked"

# The dry run's plan spans keys: a subshell per key would count the shared file as copied twice.
pair_source=$(make_source_repo pair-source)
reset_scene
make_checkout code/pair-super "git@github.com:$FIXTURE_OWNER/pair-super.git"
git -C "$HOME/code/pair-super" commit -q --allow-empty -m first || fatal "could not commit in pair-super"
add_submodule code/pair-super pair-sub pair-sub "$pair_source"
git -C "$HOME/code/pair-super/pair-sub" remote set-url origin "git@github.com:$FIXTURE_OWNER/pair-sub.git" \
    || fatal "could not set the submodule's origin"
real_memory "$(key_of "$HOME/code/pair-super/pair-sub")" shared.md
real_memory "$(key_of "$HOME/code/pair-super/.git/modules/pair-sub")" shared.md
run_sut --apply --dry-run
pair_dry_run="$RC|$OUT"
run_sut --apply
check "dry-run: a file a submodule's two keys share counts across them, as the run counts it" \
    "$pair_dry_run|$(contains "$OUT" 'copied 1, identical 0')|$(contains "$OUT" 'copied 0, identical 1')" "0|$OUT|yes|yes"

printf 'apply: a copy takes the name only when it is whole\n'
BIG_BODY=$(printf 'a line of a body long enough to cut short %.0s\n' {1..200})
TRUNCATED_BODY='cut sho'
# write_truncating_cp_stub — the first cp writes a short file to its destination and exits with
# $STUB_CP_EXIT; every later one is the real cp.
write_truncating_cp_stub() {
    write_stub cp <<'STUB'
if [ ! -e "$STUB_STATE_FILE" ]; then
    : > "$STUB_STATE_FILE"
    for last_argument; do :; done
    printf '%s' "$STUB_SHORT_BODY" > "$last_argument"
    exit "$STUB_CP_EXIT"
fi
exec "$real_tool" "$@"
STUB
}

apply_scene short-copy-reports-failure
write_file "$memory_dir/big.md" "$BIG_BODY"
write_truncating_cp_stub
PATH="$STUB_BIN:$PATH" STUB_SHORT_BODY="$TRUNCATED_BODY" STUB_CP_EXIT=1 run_sut --apply
check "apply: a copy cut short that reports failure never takes the file's name" \
    "$RC|$(contains "$OUT" 'could not copy')|$(body_of "$store_dir/big.md")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|<absent>|0 marked, 1 unmarked"

apply_scene short-copy-reports-success
write_file "$memory_dir/big.md" "$BIG_BODY"
write_truncating_cp_stub
PATH="$STUB_BIN:$PATH" STUB_SHORT_BODY="$TRUNCATED_BODY" STUB_CP_EXIT=0 run_sut --apply
check "apply: a copy cut short that reports success never takes the file's name" \
    "$RC|$(contains "$OUT" 'did not arrive whole')|$(body_of "$store_dir/big.md")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|<absent>|0 marked, 1 unmarked"
run_sut --apply
check "resume: the next --apply brings the whole file and removes the short partial" \
    "$RC|$OUT|$(body_of "$store_dir/big.md")|$(partial_count "$store_dir")|$(replaced_dir_counts "$key_dir")" \
    "0|$(linked_line 1 0 0)|$BIG_BODY|0|1 marked, 0 unmarked"

# A real short write. The signal is ignored so that cp sees EFBIG and fails, as on a full disk,
# rather than dying with a core dump.
apply_scene short-copy-for-real
write_file "$memory_dir/big.md" "$BIG_BODY"
short_write_result=$(
    trap '' XFSZ
    ulimit -f 1
    run_sut --apply
    printf '%s|%s' "$RC" "$(contains "$OUT" 'could not copy')"
)
check "apply: a real short write (ulimit -f) never takes the file's name" \
    "$short_write_result|$(body_of "$store_dir/big.md")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|<absent>|0 marked, 1 unmarked"

# The reviewer's stale conflict copy: a short one must not stand in for the body at that name.
apply_scene short-conflict-copy
write_file "$memory_dir/big.md" "$BIG_BODY"
write_file "$store_dir/big.md" 'store body'
write_truncating_cp_stub
PATH="$STUB_BIN:$PATH" STUB_SHORT_BODY="$TRUNCATED_BODY" STUB_CP_EXIT=0 run_sut --apply
short_conflict_result="$RC|$(body_of "$store_dir/big$CONFLICT_MD_SUFFIX")"
run_sut --apply
check "apply: a conflict copy cut short never takes the conflict name, and the resume writes no .2" \
    "$short_conflict_result|$RC|$(body_of "$store_dir/big$CONFLICT_MD_SUFFIX")|$(body_of "$store_dir/big.conflict-$FIXTURE_HOST.2.md")|$(partial_count "$store_dir")" \
    "2|<absent>|0|$BIG_BODY|<absent>|0"

apply_scene leftover-partials
write_file "$memory_dir/topic.md" 'topic body'
write_file "$memory_dir/same.md" 'same body'
write_file "$store_dir/same.md" 'same body'
write_file "$(partial_of "$store_dir" topic.md)" 'a short leftover'
write_file "$(partial_of "$store_dir" same.md)" 'same body'
write_file "$(partial_of "$store_dir" other.md)" "another file's leftover"
run_sut --apply
check "apply: a leftover partial is removed by the next merge of its own file, and another file's stays" \
    "$RC|$OUT|$(body_of "$store_dir/topic.md")|$(body_of "$(partial_of "$store_dir" topic.md)")|$(body_of "$(partial_of "$store_dir" same.md)")|$(body_of "$(partial_of "$store_dir" other.md)")" \
    "0|$(linked_line 1 1 0)|topic body|<absent>|<absent>|another file's leftover"

apply_scene leftover-partial-symlink
write_file "$memory_dir/topic.md" 'topic body'
write_file "$TMPROOT/outside-partial-target" 'outside body'
mkdir -p "$store_dir"
ln -s "$TMPROOT/outside-partial-target" "$(partial_of "$store_dir" topic.md)"
run_sut --apply
check "apply: a leftover partial that is a symlink is not written through" \
    "$RC|$(body_of "$TMPROOT/outside-partial-target")|$(body_of "$store_dir/topic.md")|$(partial_count "$store_dir")" \
    "0|outside body|topic body|0"

reset_scene
make_checkout code/only-a-partial "git@github.com:$FIXTURE_OWNER/only-a-partial.git"
key=$(key_of "$HOME/code/only-a-partial")
store_dir="$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/only-a-partial"
write_file "$(partial_of "$store_dir" topic.md)" 'a short leftover'
run_sut --list
partial_list_result="$RC|$(row_of_key "$key")"
tree_before=$(tree_fingerprint)
run_sut --apply
check "list: a leftover partial is not a file the store holds" \
    "$partial_list_result|$RC|$OUT|$(tree_fingerprint)" "0||0||$tree_before"

apply_scene partial-named-source
write_file "$memory_dir/topic.md" 'topic body'
write_file "$(partial_of "$memory_dir" other.md)" 'named like a partial'
run_sut --apply
replaced_dirs=("$key_dir"/memory.replaced-*)
check "apply: a file named like a partial in a memory directory stays out of the store, and in the replaced directory" \
    "$RC|$OUT|$(partial_count "$store_dir")|$(body_of "$(partial_of "${replaced_dirs[0]}" other.md)")" \
    "0|$(linked_line 1 0 0)|0|named like a partial"

printf 'apply: a real directory holding the marker\n'
apply_scene restored-with-marker
write_file "$memory_dir/topic.md" 'written since the undo'
: > "$memory_dir/$MERGED_MARKER"
run_sut --apply --dry-run
restored_dry_run="$RC|$OUT"
run_sut --apply
apply_result="$RC|$OUT"
run_sut --check
check "apply: a real directory already holding the marker is merged, and ends marked" \
    "$restored_dry_run|$apply_result|$RC|$(body_of "$store_dir/topic.md")|$([[ -e "$store_dir/$MERGED_MARKER" ]] && printf 'marker in the store')|$(replaced_dir_counts "$key_dir")" \
    "0|$(linked_line 1 0 0)|0|$(linked_line 1 0 0)|0|written since the undo||1 marked, 0 unmarked"

# Stopped between the rename and the link, a stale marker would read as merged for good.
apply_scene restored-then-stopped
write_file "$memory_dir/topic.md" 'written since the undo'
: > "$memory_dir/$MERGED_MARKER"
write_stub ln <<'STUB'
exit 1
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
stopped_rc=$RC
run_sut --check
check "resume: a directory that held the marker reads as pending when stopped right after the rename" \
    "$stopped_rc|$RC|$(contains "$OUT" "$key${TAB}PENDING-MERGE")|$(replaced_dir_counts "$key_dir")" \
    "2|1|yes|0 marked, 1 unmarked"

apply_scene marker-is-a-directory
write_file "$memory_dir/topic.md" 'topic body'
mkdir -p "$memory_dir/$MERGED_MARKER"
run_sut --apply
check "apply: a stale marker that cannot be removed is exit 2, before the rename" \
    "$RC|$(contains "$OUT" "could not clear the stale marker in $memory_dir")|$(memory_kind "$memory_dir")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|real|0 marked, 0 unmarked"

printf 'apply: a file written after the marker\n'
# The marker is set in the past, rather than the row racing the clock: -newer compares timestamps, and
# a file written in the marker's own tick is not newer.
apply_scene_marked_in_the_past() {
    pending_scene "$1"
    shift
    local file_body_pair
    for file_body_pair in "$@"; do
        write_file "$replaced_dir/${file_body_pair%%=*}" "${file_body_pair#*=}"
    done
    run_sut --apply
    (( RC == 0 )) || fatal "could not mark the replaced directory of the scene: $OUT"
    find "$replaced_dir" -type f -exec touch -t "$OLD_MTIME_STAMP" {} +
    touch -t "$MARKER_PAST_MTIME_STAMP" "$replaced_dir/$MERGED_MARKER"
}

apply_scene_marked_in_the_past written-after-marker 'settled.md=settled body'
write_file "$replaced_dir/late.md" 'late body'
marker_mtime_before=$(stat -c '%Y' "$replaced_dir/$MERGED_MARKER")
tree_before=$(tree_fingerprint)
run_sut --apply --dry-run
late_dry_run="$RC|$OUT|$(tree_fingerprint)"
run_sut --check
late_check="$RC|$(contains "$OUT" "$key${TAB}PENDING-MERGE")"
run_sut --apply
late_apply="$RC|$OUT"
marker_mtime_after=$(stat -c '%Y' "$replaced_dir/$MERGED_MARKER")
run_sut --check
late_check_after="$RC"
run_sut --apply
check "apply: a file written into a marked directory is merged, and the marker moves" \
    "$late_dry_run|$late_check|$late_apply|$late_check_after|$RC|$OUT|$(body_of "$store_dir/late.md")|$(replaced_dir_counts "$key_dir")|$(( marker_mtime_after > marker_mtime_before ))" \
    "0|$(linked_line 1 0 0)|$tree_before|1|yes|0|$(linked_line 1 0 0)|0|0||late body|1 marked, 0 unmarked|1"

# The rest was merged when the marker was written, and the store has been free to move on since.
apply_scene_marked_in_the_past only-the-newcomer 'edited.md=body when merged' 'deleted.md=deleted body' 'MEMORY.md=- line of the replaced directory'
write_file "$store_dir/edited.md" 'edited since'
rm -f "$store_dir/deleted.md"
write_file "$store_dir/MEMORY.md" '- the store dropped that line'
write_file "$replaced_dir/late.md" 'late body'
run_sut --apply
check "apply: a file written after the marker brings only itself, and the store keeps what it moved on to" \
    "$RC|$OUT|$(body_of "$store_dir/late.md")|$(body_of "$store_dir/edited.md")|$(body_of "$store_dir/deleted.md")|$(body_of "$store_dir/MEMORY.md")|$(find "$store_dir" -name '*.conflict-*' | wc -l | tr -d ' ')" \
    "0|$(linked_line 1 0 0)|late body|edited since|<absent>|- the store dropped that line|0"

apply_scene_marked_in_the_past partial-after-marker
write_file "$(partial_of "$replaced_dir" other.md)" 'named like a partial'
run_sut --check
check "check: a file named like a partial, written after the marker, does not read as pending" \
    "$RC|$(contains "$OUT" PENDING-MERGE)" "0|no"

apply_scene_marked_in_the_past unreadable-after-marker 'locked/x.md=x body'
chmod 000 "$replaced_dir/locked"
run_sut --check
unreadable_check="$RC|$(contains "$OUT" "$key${TAB}PENDING-MERGE")"
run_sut --apply
unreadable_apply="$RC|$(contains "$OUT" "could not read $replaced_dir")"
chmod 755 "$replaced_dir/locked"
check "check: a marked directory that cannot be walked reads as pending, not as settled" \
    "$unreadable_check|$unreadable_apply" "1|yes|2|yes"

printf 'apply: never through a symlink\n'
apply_scene store-symlink-outside
outside_dir="$TMPROOT/outside-the-store"
rm -rf "$outside_dir"
write_file "$outside_dir/MEMORY.md" '- outside line'
mkdir -p "$store_dir"
ln -s "$outside_dir" "$store_dir/sub"
write_file "$memory_dir/sub/x.md" 'x body'
write_file "$memory_dir/sub/MEMORY.md" '- replaced line'
write_file "$memory_dir/sub/deeper/z.md" 'z body'
write_file "$memory_dir/ok.md" 'ok body'
outside_listing_before=$(file_manifest "$outside_dir")
run_sut --apply
check "apply: a store symlink pointing outside is refused and nothing lands outside" \
    "$RC|$(contains "$OUT" "refusing $store_dir/sub/x.md")|$(contains "$OUT" "refusing $store_dir/sub/MEMORY.md")|$(contains "$OUT" "refusing $store_dir/sub/deeper/z.md")|$(file_manifest "$outside_dir")|$([[ -e "$outside_dir/deeper" ]] && printf 'made a directory')|$(body_of "$store_dir/ok.md")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|yes|yes|$outside_listing_before||ok body|0 marked, 1 unmarked"

apply_scene store-symlink-dangling
mkdir -p "$store_dir"
ln -s "$TMPROOT/no-such-store-part" "$store_dir/dead"
write_file "$memory_dir/dead/x.md" 'x body'
run_sut --apply
check "apply: a dangling symlink in the store's path is refused" \
    "$RC|$(contains "$OUT" "refusing $store_dir/dead/x.md")|$([[ -e "$TMPROOT/no-such-store-part" ]] && printf 'made its target')|$(replaced_dir_counts "$key_dir")" \
    "2|yes||0 marked, 1 unmarked"

apply_scene store-symlink-inside
write_file "$store_dir/real-sub/kept.md" 'kept body'
ln -s "$store_dir/real-sub" "$store_dir/alias"
write_file "$memory_dir/alias/x.md" 'x body'
run_sut --apply
check "apply: a store symlink that stays inside the store directory is followed" \
    "$RC|$OUT|$(body_of "$store_dir/real-sub/x.md")" "0|$(linked_line 1 0 0)|x body"

apply_scene store-dir-is-symlink
write_file "$memory_dir/sub/x.md" 'x body'
real_store_dir="$STORES_ROOT/$ALPHA_STORE/store-dir-elsewhere"
mkdir -p "$real_store_dir" "$(dirname "$store_dir")"
ln -s "$real_store_dir" "$store_dir"
run_sut --apply
apply_result="$RC|$OUT"
run_sut --list
check "apply: a store directory that is itself a symlink inside the checkout still works" \
    "$apply_result|$(row_of_key "$key" | cut -f2)|$(body_of "$real_store_dir/sub/x.md")" \
    "0|$(linked_line 1 0 0)|LINKED|x body"

# Containment compares physical paths, so a checkout reached through a link of its own is no escape.
apply_scene store-checkout-is-symlink
write_file "$memory_dir/x.md" 'x body'
real_checkout_dir="$TMPROOT/store-checkout-elsewhere"
rm -rf "$real_checkout_dir"
mv "$STORES_ROOT/$ALPHA_STORE" "$real_checkout_dir" || fatal "could not move the store checkout"
ln -s "$real_checkout_dir" "$STORES_ROOT/$ALPHA_STORE" || fatal "could not link the store checkout"
run_sut --apply
check "apply: a store checkout that is itself a symlink still works" \
    "$RC|$OUT|$(body_of "$real_checkout_dir/repos/$FIXTURE_OWNER/store-checkout-is-symlink/x.md")" \
    "0|$(linked_line 1 0 0)|x body"

# plant_link_above_store_dir OUTSIDE_DIR — repos/<owner> in the alpha store is a symlink to OUTSIDE_DIR,
# which is empty: what a link committed on another host would leave here. $STORES_ROOT is physical.
plant_link_above_store_dir() {
    rm -rf "$1" "$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER"
    mkdir -p "$1" "$STORES_ROOT/$ALPHA_STORE/repos" || fatal "could not create the fixture directories"
    ln -s "$1" "$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER" || fatal "could not plant the link"
}

# outside_entry_count DIR — how many entries lie under DIR.
outside_entry_count() { find "$1" -mindepth 1 | wc -l | tr -d ' '; }

above_store_dir="$TMPROOT/outside-above-the-store"

apply_scene link-above-real-dir
make_checkout code/z-after-link-above 'git@github.com:other-org/z-after-link-above.git'
after_key=$(key_of "$HOME/code/z-after-link-above")
real_memory "$after_key" MEMORY.md
plant_link_above_store_dir "$above_store_dir"
write_file "$memory_dir/x.md" 'x body'
refusal_line="refusing $store_dir: it resolves outside the store checkout $STORES_ROOT/$ALPHA_STORE"
run_sut --apply --dry-run
link_above_dry_run="$RC|$(contains "$OUT" "$refusal_line")"
run_sut --apply
apply_result="$RC|$(contains "$OUT" "$refusal_line")|$(contains "$OUT" "could not finish 1 key(s): $key")"
run_sut --list
check "apply: a symlink above the store directory that leaves the checkout is refused: nothing lands outside, the key stays REAL-DIR, later keys link" \
    "$link_above_dry_run|$apply_result|$(outside_entry_count "$above_store_dir")|$(memory_kind "$memory_dir")|$(row_of_key "$key" | cut -f2)|$(replaced_dir_counts "$key_dir")|$(row_of_key "$after_key" | cut -f2)" \
    "2|yes|2|yes|yes|0|real|REAL-DIR|0 marked, 0 unmarked|LINKED"

# The same refusal from each other place that would make the directory, or write into it.
apply_scene link-above-missing
rmdir "$memory_dir"
plant_link_above_store_dir "$above_store_dir"
write_file "$above_store_dir/link-above-missing/MEMORY.md" 'memory reached through the link'
outside_listing_before=$(file_manifest "$above_store_dir")
run_sut --apply --dry-run
link_above_dry_run="$RC|$(contains "$OUT" "refusing $store_dir: it resolves outside")"
run_sut --apply
check "apply: a MISSING key behind a symlink above the store directory gets no link" \
    "$link_above_dry_run|$RC|$(contains "$OUT" "refusing $store_dir: it resolves outside")|$(memory_kind "$memory_dir")|$(file_manifest "$above_store_dir")" \
    "2|yes|2|yes|absent|$outside_listing_before"

apply_scene link-above-dangling
rmdir "$memory_dir"
plant_link_above_store_dir "$above_store_dir"
link_memory "$key" "$store_dir"
run_sut --apply
check "apply: a DANGLING key behind a symlink above the store directory makes nothing outside" \
    "$RC|$(contains "$OUT" "refusing $store_dir: it resolves outside")|$(outside_entry_count "$above_store_dir")" \
    "2|yes|0"

pending_scene link-above-pending
write_file "$replaced_dir/topic.md" 'pending body'
plant_link_above_store_dir "$above_store_dir"
run_sut --apply
check "apply: a pending merge behind a symlink above the store directory lands nothing outside, and stays pending" \
    "$RC|$(contains "$OUT" "refusing $store_dir: it resolves outside")|$(outside_entry_count "$above_store_dir")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|0|0 marked, 1 unmarked"

apply_scene store-dir-links-outside
write_file "$memory_dir/x.md" 'x body'
outside_store_dir="$TMPROOT/store-dir-outside-the-checkout"
rm -rf "$outside_store_dir"
mkdir -p "$outside_store_dir" "$(dirname "$store_dir")"
ln -s "$outside_store_dir" "$store_dir"
run_sut --apply
apply_result="$RC|$(contains "$OUT" "refusing $store_dir: it resolves outside")"
run_sut --list
check "apply: a store directory that is itself a symlink out of the checkout is refused, and the key stays REAL-DIR" \
    "$apply_result|$(outside_entry_count "$outside_store_dir")|$(row_of_key "$key" | cut -f2)" \
    "2|yes|0|REAL-DIR"

# Inside the checkout and still refused: git runs what lies under its .git, so a memory file named like
# a hook would land as one that the sync's `git merge` runs. The hooks directory is made, not assumed:
# what `git init` puts there depends on the host's template directory.
apply_scene hooks-trap
write_file "$memory_dir/post-merge" '#!/bin/sh'
chmod 755 "$memory_dir/post-merge"
store_git_dir="$STORES_ROOT/$ALPHA_STORE/.git"
mkdir -p "$store_git_dir/hooks" "$(dirname "$store_dir")"
ln -s ../../.git/hooks "$store_dir" || fatal "could not plant the link into the store's .git"
hooks_manifest_before=$(file_manifest "$store_git_dir/hooks")
run_sut --apply
apply_result="$RC|$(contains "$OUT" "refusing $store_dir: it resolves into the store checkout's git directory $store_git_dir")"
run_sut --list
check "apply: a store directory that resolves into the store checkout's .git is refused: no hook lands, the key stays REAL-DIR" \
    "$apply_result|$([[ -e "$store_git_dir/hooks/post-merge" ]] && printf 'hook landed')|$(file_manifest "$store_git_dir/hooks")|$(row_of_key "$key" | cut -f2)" \
    "2|yes||$hooks_manifest_before|REAL-DIR"

# linked_scene REPO — a key already linked into its store directory, which holds one file.
linked_scene() {
    apply_scene "$1"
    rmdir "$memory_dir" || fatal "could not clear the memory directory of $1"
    write_file "$store_dir/MEMORY.md" 'store memory'
    link_memory "$key" "$store_dir"
}

# --check holds a LINKED key to the same containment as --apply: a link planted above the store
# directory after the key was linked sends Claude Code's writes out of the store while the text of the
# key's own link stays right. --apply then leaves it, as it leaves any WRONG-LINK.
linked_scene relinked-outside
moved_owner_dir="$TMPROOT/owner-moved-outside"
rm -rf "$moved_owner_dir"
mv "$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER" "$moved_owner_dir" || fatal "could not move the owner directory"
ln -s "$moved_owner_dir" "$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER" || fatal "could not plant the link"
moved_owner_manifest_before=$(file_manifest "$moved_owner_dir")
run_sut --check
check_result="$RC|$OUT"
run_sut --apply
check "check: a LINKED key whose store directory now resolves outside the checkout is WRONG-LINK, and --apply leaves it" \
    "$check_result|$RC|$OUT|$(memory_kind "$memory_dir")|$(file_manifest "$moved_owner_dir")" \
    "1|$(row_line "$key" WRONG-LINK "$ALPHA_STORE" "repos/$FIXTURE_OWNER/relinked-outside" "$HOME/code/relinked-outside")
claude-memory-link: 0 linked, 1 to fix, 0 unmapped, 0 without a store|0||link to $store_dir|$moved_owner_manifest_before"

linked_scene relinked-into-git
store_git_dir="$STORES_ROOT/$ALPHA_STORE/.git"
mv "$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER" "$store_git_dir/planted-owner" || fatal "could not move the owner directory"
ln -s ../.git/planted-owner "$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER" || fatal "could not plant the link"
run_sut --check
check "check: a LINKED key whose store directory now resolves into the store checkout's .git is WRONG-LINK" \
    "$RC|$OUT" \
    "1|$(row_line "$key" WRONG-LINK "$ALPHA_STORE" "repos/$FIXTURE_OWNER/relinked-into-git" "$HOME/code/relinked-into-git")
claude-memory-link: 0 linked, 1 to fix, 0 unmapped, 0 without a store"

pending_scene marker-dangling
write_file "$replaced_dir/topic.md" 'pending body'
marker_target="$TMPROOT/no-such-marker-target"
rm -f "$marker_target"
ln -s "$marker_target" "$replaced_dir/$MERGED_MARKER"
run_sut --apply
check "apply: a dangling marker symlink is refused, and nothing is written through it" \
    "$RC|$(contains "$OUT" "refusing to write the marker through the symlink $replaced_dir/$MERGED_MARKER")|$([[ -e "$marker_target" ]] && printf 'wrote through it')|$(body_of "$store_dir/topic.md")|$([[ -L "$store_dir/$MERGED_MARKER" ]] && printf 'marker in the store')" \
    "2|yes||pending body|"

pending_scene marker-link-to-file
write_file "$replaced_dir/topic.md" 'pending body'
write_file "$TMPROOT/marker-link-target" 'a file of someone else'
ln -s "$TMPROOT/marker-link-target" "$replaced_dir/$MERGED_MARKER"
run_sut --check
marker_link_check="$RC|$(contains "$OUT" "$key${TAB}PENDING-MERGE")"
run_sut --apply
check "apply: a marker symlink to a file does not count as merged, and the file is left alone" \
    "$marker_link_check|$RC|$(body_of "$store_dir/topic.md")|$(body_of "$TMPROOT/marker-link-target")" \
    "1|yes|2|pending body|a file of someone else"

# The regression blocks in open(2) under the lock, so this runs bounded.
reset_scene
for repo in a-fifo-marker b-after-fifo-marker; do
    make_checkout "code/$repo" "git@github.com:$FIXTURE_OWNER/$repo.git"
done
a_key=$(key_of "$HOME/code/a-fifo-marker")
b_key=$(key_of "$HOME/code/b-after-fifo-marker")
a_store_dir="$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/a-fifo-marker"
b_store_dir="$STORES_ROOT/$ALPHA_STORE/repos/$FIXTURE_OWNER/b-after-fifo-marker"
mkdir -p "$a_store_dir"
link_memory "$a_key" "$a_store_dir"
a_replaced_dir="$PROJECTS_DIR/$a_key/$REPLACED_STAMP"
write_file "$a_replaced_dir/topic.md" 'pending body'
mkfifo "$a_replaced_dir/$MERGED_MARKER"
real_memory "$b_key" MEMORY.md
fifo_refusal="refusing to write the marker at $a_replaced_dir/$MERGED_MARKER: it is not a regular file"
run_sut_bounded --apply --dry-run
fifo_dry_run="$RC|$(contains "$OUT" "$fifo_refusal")"
run_sut_bounded --apply
check "apply: a fifo at the marker path is refused, exit 2 naming it, nothing hangs and the later key links" \
    "$fifo_dry_run|$RC|$(contains "$OUT" "$fifo_refusal")|$(contains "$OUT" "could not finish 1 key(s): $a_key")|$(replaced_dir_counts "$PROJECTS_DIR/$a_key")|$(body_of "$a_store_dir/topic.md")|$(memory_kind "$PROJECTS_DIR/$b_key/memory")" \
    "2|yes|2|yes|yes|0 marked, 1 unmarked|pending body|link to $b_store_dir"

apply_scene directory-at-partial-name
write_file "$memory_dir/topic.md" 'replaced body'
write_stub cp <<'STUB'
for last_argument; do :; done
mkdir -p "$last_argument"
exec "$real_tool" "$@"
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
check "apply: a directory appearing at the partial name is refused rather than entered" \
    "$RC|$(contains "$OUT" 'could not copy')|$(find "$(partial_of "$store_dir" topic.md)" -mindepth 1 | wc -l | tr -d ' ')|$(body_of "$store_dir/topic.md")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|0|<absent>|0 marked, 1 unmarked"

run_sut --apply
check "apply: a leftover that cannot be removed is exit 2 and writes no marker" \
    "$RC|$(contains "$OUT" 'could not remove the leftover')|$(body_of "$store_dir/topic.md")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|<absent>|0 marked, 1 unmarked"

apply_scene directory-at-target-name
write_file "$memory_dir/topic.md" 'replaced body'
write_stub cp <<'STUB'
if [ ! -e "$STUB_STATE_FILE" ]; then
    : > "$STUB_STATE_FILE"
    mkdir -p "$STUB_TARGET_PATH"
fi
exec "$real_tool" "$@"
STUB
PATH="$STUB_BIN:$PATH" STUB_TARGET_PATH="$store_dir/topic.md" run_sut --apply
check "apply: a directory appearing at the file's name is not entered, and the file goes beside it" \
    "$RC|$(find "$store_dir/topic.md" -mindepth 1 | wc -l | tr -d ' ')|$(body_of "$store_dir/topic$CONFLICT_MD_SUFFIX")|$(partial_count "$store_dir")" \
    "0|0|replaced body|0"

printf 'apply: every failure stops before the marker\n'
apply_scene memory-plain-file
rmdir "$memory_dir"
write_file "$memory_dir" 'a plain file'
tree_before=$(tree_fingerprint)
run_sut --apply
check "apply: a memory entry that is a plain file is exit 2 naming it, with nothing touched" \
    "$RC|$(contains "$OUT" "$memory_dir is neither a directory nor a symlink")|$(tree_fingerprint)" "2|yes|$tree_before"

apply_scene store-dir-blocked
write_file "$memory_dir/MEMORY.md" '- index'
: > "$STORES_ROOT/$ALPHA_STORE/repos"
run_sut --apply
check "apply: a store directory that cannot be created is exit 2 before the rename" \
    "$RC|$(contains "$OUT" "could not create $store_dir")|$(memory_kind "$memory_dir")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|real|0 marked, 0 unmarked"

apply_scene mv-fails
write_file "$memory_dir/MEMORY.md" '- index'
write_stub mv <<'STUB'
exit 1
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
check "apply: a rename that fails is exit 2 and the real directory stays" \
    "$RC|$(contains "$OUT" "could not rename $memory_dir")|$(memory_kind "$memory_dir")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|real|0 marked, 0 unmarked"

apply_scene cp-fails
write_file "$memory_dir/topic.md" 'replaced body'
write_stub cp <<'STUB'
printf 'stub copy failure\n' >&2
exit 1
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
check "apply: a copy that fails is exit 2 and writes no marker" \
    "$RC|$(contains "$OUT" 'stub copy failure')|$(contains "$OUT" 'could not copy')|$(memory_kind "$memory_dir")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|yes|link to $store_dir|0 marked, 1 unmarked"

# A copy that reports success and leaves nothing. Stepping to the next name would write forever.
# Only the publish fails: the swap's own ln has no partial in its arguments.
apply_scene publish-fails
write_file "$memory_dir/topic.md" 'topic body'
write_stub ln <<'STUB'
case "$*" in *"$STUB_FAILING_NAME"*) printf 'stub publish failure\n' >&2; exit 1 ;; esac
exec "$real_tool" "$@"
STUB
PATH="$STUB_BIN:$PATH" STUB_FAILING_NAME="$PARTIAL_SUFFIX" run_sut --apply
check "apply: a publish that fails is exit 2 and writes no marker" \
    "$RC|$(contains "$OUT" 'could not publish')|$(contains "$OUT" 'stub publish failure')|$(body_of "$store_dir/topic.md")|$(body_of "$store_dir/topic$CONFLICT_MD_SUFFIX")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|yes|<absent>|<absent>|0 marked, 1 unmarked"

apply_scene conflict-copy-lost
write_file "$memory_dir/topic.md" 'replaced body'
write_file "$store_dir/topic.md" 'store body'
write_stub cp <<'STUB'
exit 0
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
check "apply: a conflict copy that does not arrive is exit 2 and writes no marker" \
    "$RC|$(contains "$OUT" 'did not arrive whole')|$(body_of "$store_dir/topic$CONFLICT_MD_SUFFIX")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|<absent>|0 marked, 1 unmarked"

apply_scene cmp-fails
write_file "$memory_dir/topic.md" 'replaced body'
write_file "$store_dir/topic.md" 'store body'
write_stub cmp <<'STUB'
exit 2
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
check "apply: a comparison that fails is exit 2, no conflict copy and no marker" \
    "$RC|$(contains "$OUT" 'could not compare')|$(body_of "$store_dir/topic$CONFLICT_MD_SUFFIX")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|<absent>|0 marked, 1 unmarked"

apply_scene find-fails
write_file "$memory_dir/readable.md" 'readable body'
write_file "$memory_dir/locked/topic.md" 'locked body'
chmod 000 "$memory_dir/locked"
run_sut --apply
find_fails_result="$RC|$(contains "$OUT" "could not read $key_dir/memory.replaced-")|$(body_of "$store_dir/readable.md")|$(replaced_dir_counts "$key_dir")"
chmod -R u+rwx "$key_dir"
check "apply: a directory that cannot be walked merges what it could list, exit 2 and no marker" \
    "$find_fails_result" "2|yes|readable body|0 marked, 1 unmarked"

apply_scene file-where-directory
write_file "$memory_dir/sub/topic.md" 'replaced body'
write_file "$store_dir/sub" 'a file in the way'
run_sut --apply
check "apply: a file where the store needs a directory is exit 2 and writes no marker" \
    "$RC|$(contains "$OUT" "could not create $store_dir/sub")|$(body_of "$store_dir/sub")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|a file in the way|0 marked, 1 unmarked"

# The real cp would block on the fifo forever, under the lock. A failing stub turns that regression
# into a failed row rather than a table that hangs.
apply_scene fifo-in-memory
mkfifo "$memory_dir/pipe"
write_stub cp <<'STUB'
exit 1
STUB
PATH="$STUB_BIN:$PATH" run_sut --apply
check "apply: a fifo in a memory directory is exit 2 naming it, and writes no marker" \
    "$RC|$(contains "$OUT" "/pipe is neither a file nor a symlink")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|0 marked, 1 unmarked"

apply_scene index-read-only
write_file "$memory_dir/MEMORY.md" '- replaced line'
write_file "$store_dir/MEMORY.md" '- store line'
chmod 444 "$store_dir/MEMORY.md"
run_sut --apply
check "apply: an index that cannot be appended to is exit 2 and writes no marker" \
    "$RC|$(contains "$OUT" "could not add lines to $store_dir/MEMORY.md")|$(body_of "$store_dir/MEMORY.md")|$(replaced_dir_counts "$key_dir")" \
    "2|yes|- store line|0 marked, 1 unmarked"

pending_scene marker-fails
write_file "$replaced_dir/topic.md" 'pending body'
chmod 555 "$replaced_dir"
run_sut --apply
marker_fails_result="$RC|$(contains "$OUT" "could not write the marker in $replaced_dir")|$(body_of "$store_dir/topic.md")|$(replaced_dir_counts "$key_dir")"
chmod 755 "$replaced_dir"
check "apply: a marker that cannot be written is exit 2, and the key stays pending" \
    "$marker_fails_result" "2|yes|pending body|0 marked, 1 unmarked"

# ---------------------------------------------------------------------------------------------
# The host name in a conflict copy: CLAUDE_MEMORY_HOST, else the profile marker's first line, else
# hostname -s. Every row runs with the hostname stub first on PATH, and every row but the variable's
# with CLAUDE_MEMORY_HOST empty, so a fall-through to hostname -s shows as the stub's name. The marker
# sits in the fixture HOME, which the next scene's reset_scene removes, so the "defaults to
# hostname -s" row below runs with no marker.
# ---------------------------------------------------------------------------------------------

printf 'host name: the profile marker names the host\n'
# The marker's path, spelled independently of the script under test.
FIXTURE_PROFILE_MARKER="$HOME/.config/claude-host-profile"
OVERRIDE_PROFILE_MARKER="$TMPROOT/override-profile-marker"
MARKER_HOST='markerhost'
OVERRIDE_MARKER_HOST='overridehost'
STUB_SHORT_HOST='stub-short-host'
# Fails the host-name rule: it would climb out of the store directory.
UNUSABLE_MARKER_LINE='../climb'

write_stub hostname <<STUB
[ "\$1" = '-s' ] || exit 9
printf '%s\n' '$STUB_SHORT_HOST'
STUB

# host_name_scene REPO MARKER_LINE — an apply scene whose topic.md differs from the store's, so the run
# writes one conflict copy named for the host, and whose profile marker holds MARKER_LINE.
host_name_scene() {
    apply_scene "$1"
    write_file "$memory_dir/topic.md" 'replaced body'
    write_file "$store_dir/topic.md" 'store body'
    write_file "$FIXTURE_PROFILE_MARKER" "$2"
}

# conflict_copy_names — the name of every conflict copy in the scene's store directory, sorted, each
# followed by a space; so one name here also says no copy carries another host's name.
conflict_copy_names() { find "$store_dir" -name '*.conflict-*' -printf '%f\n' | LC_ALL=C sort | tr '\n' ' '; }

host_name_scene marker-names-host "$MARKER_HOST"
FIXTURE_HOST='' PATH="$STUB_BIN:$PATH" run_sut --apply
check "host name: the profile marker names the host" \
    "$RC|$(conflict_copy_names)|$(body_of "$store_dir/topic.conflict-$MARKER_HOST.md")" \
    "0|topic.conflict-$MARKER_HOST.md |replaced body"

# A pin: a marker that outranked the variable would name the copy markerhost.
host_name_scene variable-outranks-marker "$MARKER_HOST"
PATH="$STUB_BIN:$PATH" run_sut --apply
check "host name: CLAUDE_MEMORY_HOST outranks the marker" \
    "$RC|$(conflict_copy_names)" "0|topic.conflict-$FIXTURE_HOST.md "

# A pin: a marker line taken without the host-name rule reaches the last check, which stops the run, exit 2.
host_name_scene unusable-marker-line "$UNUSABLE_MARKER_LINE"
FIXTURE_HOST='' PATH="$STUB_BIN:$PATH" run_sut --apply
check "host name: an unusable marker line falls back to hostname -s" \
    "$RC|$OUT|$(conflict_copy_names)" "0|$(linked_line 0 0 1)|topic.conflict-$STUB_SHORT_HOST.md "

# A pin: a read with no readability test before it puts the shell's "Permission denied" on stderr.
# Mode 000 does not stop root, so under root (act runs so) the precondition below fails and the table
# is could-not-run, exit 2, as the root check at the top already makes it.
host_name_scene unreadable-marker "$MARKER_HOST"
chmod 000 "$FIXTURE_PROFILE_MARKER" || fatal "could not make the profile marker unreadable"
[[ ! -r "$FIXTURE_PROFILE_MARKER" ]] \
    || fatal "the profile marker is still readable at mode 000: the unreadable-marker row would assert nothing"
FIXTURE_HOST='' PATH="$STUB_BIN:$PATH" run_sut --apply
check "host name: an unreadable marker falls back to hostname -s, silently" \
    "$RC|$(contains "$OUT" 'Permission denied')|$(conflict_copy_names)" "0|no|topic.conflict-$STUB_SHORT_HOST.md "

host_name_scene marker-override-path "$MARKER_HOST"
write_file "$OVERRIDE_PROFILE_MARKER" "$OVERRIDE_MARKER_HOST"
CLAUDE_SETTINGS_RENDER_MARKER="$OVERRIDE_PROFILE_MARKER" FIXTURE_HOST='' PATH="$STUB_BIN:$PATH" run_sut --apply
check "host name: the marker override path is honoured" \
    "$RC|$(conflict_copy_names)" "0|topic.conflict-$OVERRIDE_MARKER_HOST.md "

printf 'apply: what it needs\n'
apply_scene default-host
write_file "$memory_dir/topic.md" 'replaced body'
write_file "$store_dir/topic.md" 'store body'
write_stub hostname <<'STUB'
[ "$1" = '-s' ] || exit 9
printf 'stub-short-host\n'
STUB
FIXTURE_HOST='' PATH="$STUB_BIN:$PATH" run_sut --apply
check "apply: the host in a conflict copy's name defaults to hostname -s" \
    "$RC|$(body_of "$store_dir/topic.conflict-stub-short-host.md")" "0|replaced body"

apply_scene unusable-host
write_file "$memory_dir/topic.md" 'replaced body'
write_file "$store_dir/topic.md" 'store body'
tree_before=$(tree_fingerprint)
FIXTURE_HOST='../up' run_sut --apply
check "apply: a host name that cannot be in a file name is exit 2, with nothing touched" \
    "$RC|$(contains "$OUT" "host name '../up' cannot go in a file name")|$(tree_fingerprint)" "2|yes|$tree_before"

apply_scene no-table
write_file "$memory_dir/MEMORY.md" '- index'
rm -f "$CONFIG"
tree_before=$(tree_fingerprint)
run_sut --apply
check "apply: no store table is exit 0 with the note, nothing touched and no state dir" \
    "$RC|$OUT|$(tree_fingerprint)|$([[ -e "$STATE_DIR" ]] && printf 'made a state dir')" \
    "0|claude-memory-link: no store table at $CONFIG; nothing to do|$tree_before|"

apply_tool_results=''
for needed_tool in flock cmp; do
    apply_scene "no-$needed_tool"
    MISSING_TOOL_BIN="$TMPROOT/no-$needed_tool-bin"
    mkdir -p "$MISSING_TOOL_BIN"
    for tool in bash dirname sed jq git flock cmp; do
        if [[ "$tool" != "$needed_tool" ]]; then ln -sf "$(command -v "$tool")" "$MISSING_TOOL_BIN/$tool"; fi
    done
    OUT=$(PATH="$MISSING_TOOL_BIN" CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" CLAUDE_MEMORY_STORES_ROOT="$STORES_ROOT" \
        CLAUDE_MEMORY_CONFIG="$CONFIG" CLAUDE_MEMORY_STATE_DIR="$STATE_DIR" CLAUDE_MEMORY_HOST="$FIXTURE_HOST" \
        CLAUDE_MEMORY_TENANT_ROUTE="$ROUTE_STUB" "$SUT" --apply 2>&1); RC=$?
    apply_tool_results+="$needed_tool $RC $(contains "$OUT" "claude-memory-link: $needed_tool is required")|"
done
check "tools: flock or cmp missing is exit 2 naming it" "$apply_tool_results" "flock 2 yes|cmp 2 yes|"

printf '\n'
EXPECTED_ROWS=211
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
