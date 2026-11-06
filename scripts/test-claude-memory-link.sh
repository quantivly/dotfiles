#!/usr/bin/env bash
#
# scripts/test-claude-memory-link.sh
# ==================================
#
# State table for scripts/claude-memory-link.sh, the read-only half: mapping Claude Code project
# keys to memory-store directories, and reporting the state of each key's `memory` entry.
#
# HERMETIC. Every row runs against fixtures under mktemp -d, under a fixture HOME, with the projects
# dir, the stores root, the store table and tenant-route all named explicitly; git reads only the
# fixture's config files. Checkouts are real ones (`git init`, `git submodule add`, `git worktree
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

for tool in bash git jq find sha256sum sort; do command -v "$tool" >/dev/null || fatal "$tool is required"; done
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

# reset_scene — nothing under the fixture home, the projects dir or the stores root; the alpha store
# checked out, the beta store not; the default table; no recorded route calls.
reset_scene() {
    rm -rf "$HOME" "$PROJECTS_DIR" "$STORES_ROOT" "$ROUTE_CALLS"
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
run_sut() {
    OUT=$(CLAUDE_MEMORY_PROJECTS_DIR="$PROJECTS_DIR" CLAUDE_MEMORY_STORES_ROOT="$STORES_ROOT" \
        CLAUDE_MEMORY_CONFIG="$CONFIG" CLAUDE_MEMORY_TENANT_ROUTE="$ROUTE_STUB" "$SUT" "$@" 2>&1); RC=$?
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
check "usage: --help is exit 0 and names both verbs" \
    "$RC|$(contains "$OUT" '--list')$(contains "$OUT" '--check')" "0|yesyes"

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
    "$RC|$(contains "$OUT" 'claude-memory-link: 1 linked, 5 to fix, 1 unmapped')" "1|yes"
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
claude-memory-link: 0 linked, 1 to fix, 0 unmapped"
done

reset_scene
add_state UNMAPPED
run_sut --check
check "check: UNMAPPED alone is exit 0 and its row is printed" "$RC|$OUT" \
    "0|${EXPECTED_ROW[UNMAPPED]}
claude-memory-link: 0 linked, 0 to fix, 1 unmapped"

reset_scene
add_state LINKED
run_sut --check
check "check: all linked is exit 0 with only the summary line" "$RC|$OUT" \
    "0|claude-memory-link: 1 linked, 0 to fix, 0 unmapped"

reset_scene
add_state NO-STORE
run_sut --check
check "check: NO-STORE alone is exit 0 and is not printed" "$RC|$OUT" \
    "0|claude-memory-link: 0 linked, 0 to fix, 0 unmapped"

reset_scene
add_state REAL-DIR
run_sut
check "check: no verb means --check" "$RC|$OUT" \
    "1|${EXPECTED_ROW[REAL-DIR]}
claude-memory-link: 0 linked, 1 to fix, 0 unmapped"

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

printf '\n'
EXPECTED_ROWS=79
if (( PASS + FAIL != EXPECTED_ROWS )); then
    fatal "expected $EXPECTED_ROWS rows, $((PASS + FAIL)) ran — a check vanished or was added without updating EXPECTED_ROWS"
fi
if (( FAIL )); then printf '\033[1;31m%d of %d failed\033[0m\n' "$FAIL" "$((PASS + FAIL))"; exit 1; fi
printf '\033[0;32mall %d passed\033[0m\n' "$PASS"
