#!/usr/bin/env bash
#
# scripts/test-dotfiles-guard.sh
# ==============================
#
# State table for the dotfiles live-config guard in zsh/functions/system.sh
# (_dotfiles_git_dir, _dotfiles_head_state, _dotfiles_ref_sha,
# _dotfiles_pin_divergence, _dotfiles_guard_verdict, _dotfiles_live_config_warn,
# _dotfiles_link_map, _dotfiles_static_live_paths, _dotfiles_extra_links,
# _dotfiles_fetch_age_hours, dotfiles-doctor, dotfiles-work), the _doctor_*
# reporting helpers those share with backup-doctor — including, over every doctor
# entry point rather than a fixed list, the "declare the counters local"
# convention they depend on — and the two files that consume them: `install`'s
# worktree refusal and the one-shot precmd hook in `zshrc`.
#
# Why this exists: the guard's whole job is to notice that the running config is
# not the reviewed config. A guard that reports "all clear" when it is actually
# broken is worse than no guard, because it turns an unnoticed problem into a
# confidently denied one. Every bug found in it so far produced a green tick
# rather than an error — a blanked PATH, a diff against a ref that did not
# exist, a stale remote-tracking ref, an unparseable link map, a symlink into
# somebody else's worktree — so each of those states is a row here. That class
# is invisible to shellcheck and to a single hand-run on a machine that happens
# to be in the passing state.
#
# Requires: zsh, git, awk. No sudo, no network, no real dotfiles checkout.
#
# Usage: scripts/test-dotfiles-guard.sh

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEM_SH="$DOTFILES/zsh/functions/system.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 1; }

# Fail loudly on a missing dependency rather than letting every check that needs
# it quietly report the "nothing happened" answer several of them expect.
missing=()
for tool in zsh git awk; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
(( ${#missing[@]} == 0 )) || fatal "missing required tool(s): ${missing[*]}"
# One row writes to /dev/full to make printf fail for real. Without it that row
# would pass for the wrong reason, which is the failure mode of every other row
# in this file.
[[ -c /dev/full ]] || fatal "/dev/full is required (the failing-printf row needs a write that returns ENOSPC)"
[[ -r "$SYSTEM_SH" ]] || fatal "cannot read $SYSTEM_SH"

# Assert the code under test actually loads before asserting anything about what
# it does. Many checks below are of the form "nothing was printed", and a file
# that failed to source produces exactly that.
if ! zsh -c "source '$SYSTEM_SH'; (( \$+functions[dotfiles-doctor] ))"; then
  fatal "sourcing $SYSTEM_SH did not define dotfiles-doctor"
fi

# Run a snippet with the module sourced.
zrun() { zsh -c "source '$SYSTEM_SH'; $1" 2>&1; }

echo
echo "=== _dotfiles_guard_verdict: the decision, every state ==="
verdict() { zrun "_dotfiles_guard_verdict '$1' '$2'; print -r -- \$_DOTFILES_VERDICT"; }

check "on the pin branch"           "$(verdict 'branch main' main)"     "ok"
check "another branch"              "$(verdict 'branch zvi/x' main)"    "off-pin zvi/x"
check "name merely containing pin"  "$(verdict 'branch mainline' main)" "off-pin mainline"
check "detached passes through"     "$(verdict 'detached abc123' main)" "detached abc123"
check "unreadable head"             "$(verdict 'unknown' main)"         "unknown"
check "empty pin is not ok"         "$(verdict 'branch main' '')"       "unknown"
check "non-default pin honoured"    "$(verdict 'branch trunk' trunk)"   "ok"

echo
echo "=== _dotfiles_head_state: reading .git/HEAD ==="
# Two arbitrary object ids, used from here on to stand for "the same commit" and
# "a different commit" without needing a real repo per case.
SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222
mkdir -p "$TMPROOT/br/.git" "$TMPROOT/det/.git" "$TMPROOT/empty/.git" "$TMPROOT/none" "$TMPROOT/wt"
printf 'ref: refs/heads/feature/x\n' > "$TMPROOT/br/.git/HEAD"
printf '9f1c0de5c0ffee0123456789abcdef0123456789\n' > "$TMPROOT/det/.git/HEAD"
: > "$TMPROOT/empty/.git/HEAD"
# A worktree has a .git FILE, not a directory. Nothing symlinks into a worktree,
# so "unknown" (and therefore silence) is correct there, not an error.
printf 'gitdir: /somewhere/.git/worktrees/wt\n' > "$TMPROOT/wt/.git"
# A HEAD holding only a newline: `read` succeeds with an empty line, where an
# empty file makes it fail. Both must land on "unknown" — the branch that
# handles them was previously unreachable, and therefore untested while the
# empty-file row appeared to cover it.
mkdir -p "$TMPROOT/blank/.git"
printf '\n' > "$TMPROOT/blank/.git/HEAD"

head_state() { zrun "_dotfiles_head_state '$1'; print -r -- \$_DOTFILES_HEAD"; }

check "symbolic ref"          "$(head_state "$TMPROOT/br")"    "branch feature/x"
check "raw sha is detached"   "$(head_state "$TMPROOT/det")"   "detached 9f1c0de5c0ffee0123456789abcdef0123456789"
check "empty HEAD"            "$(head_state "$TMPROOT/empty")" "unknown"
check "newline-only HEAD"     "$(head_state "$TMPROOT/blank")" "unknown"
check "no .git at all"        "$(head_state "$TMPROOT/none")"  "unknown"
check "worktree .git file"    "$(head_state "$TMPROOT/wt")"    "unknown"
check "empty root argument"   "$(head_state '')"               "unknown"

echo
echo "=== _dotfiles_git_dir: which .git layouts hold a live checkout ==="
# `.git` is a directory in an ordinary clone and a FILE in two layouts that must
# not be treated alike. The old `[[ -f .git ]]` test filed a --separate-git-dir
# clone under "worktree", so ./install refused and dotfiles-doctor returned 1 on
# every single run of one — a permanently-red checker, i.e. an ignored one. git's
# own marker for a linked worktree is the `commondir` file in the dir it points
# at, so that is what is read, rather than pattern-matching the path.
SEP="$TMPROOT/sepgitdir"
git init -q -b main --separate-git-dir="$TMPROOT/sepgit" "$SEP"
PRIMARY="$TMPROOT/wtmain"
git init -q -b main "$PRIMARY"
git -C "$PRIMARY" config user.email t@example.com
git -C "$PRIMARY" config user.name  Test
git -C "$PRIMARY" commit -q --allow-empty -m init
git -C "$PRIMARY" worktree add -q -b wtbranch "$TMPROOT/realwt" >/dev/null 2>&1
[[ -f "$TMPROOT/realwt/.git" && -f "$SEP/.git" ]] \
  || fatal "fixture: both a linked worktree and a --separate-git-dir clone must have a .git FILE"

gitkind() { zrun "_dotfiles_git_dir '$1'; print -r -- \$_DOTFILES_GIT_KIND"; }

check "ordinary clone"           "$(gitkind "$PRIMARY")"         "primary"
check "separate-git-dir clone"   "$(gitkind "$SEP")"             "separate"
check "linked worktree"          "$(gitkind "$TMPROOT/realwt")"  "worktree"
check "not a repo at all"        "$(gitkind "$TMPROOT/none")"    "none"
check "empty root argument"      "$(gitkind '')"                 "none"
# Why the distinction is worth drawing: a --separate-git-dir clone is an ordinary
# place to work and its HEAD must be readable. A linked worktree's must not be —
# nothing there is live, so "unknown", and therefore silence, is the answer.
check "separate-git-dir HEAD read"    "$(head_state "$SEP")"            "branch main"
check "linked worktree stays unknown" "$(head_state "$TMPROOT/realwt")" "unknown"

echo
echo "=== _dotfiles_live_config_warn: what the user sees at shell startup ==="
# Its own HOME, containing no ~/.zshrc: the warning also checks where the
# running shell was sourced FROM (see the foreign-source rows at the end of this
# section), and with the tester's real HOME that check would read whatever is
# installed on the machine running the suite — passing here and failing in CI, or
# the reverse.
WARNHOME="$TMPROOT/warnhome"; mkdir -p "$WARNHOME"
warn() { zrun "HOME='$WARNHOME' DOTFILES_ROOT='$1' DOTFILES_PIN_BRANCH='${2:-main}' ${3:-} _dotfiles_live_config_warn"; }

check "off-pin warns"         "$(warn "$TMPROOT/br"  main | grep -c 'not main')"      "1"
check "off-pin names branch"  "$(warn "$TMPROOT/br"  main | grep -c 'feature/x')"     "1"
check "on-pin is silent"      "$(warn "$TMPROOT/br"  feature/x)"                      ""
check "detached warns"        "$(warn "$TMPROOT/det" main | grep -c 'detached HEAD')" "1"
# Silence in normal states is deliberate: a machine without this repo, a fresh
# clone mid-install and a shell inside a worktree are all fine. A guard that
# fires in ordinary states is one people learn to ignore.
check "unknown is silent"     "$(warn "$TMPROOT/none" main)"                          ""
check "worktree is silent"    "$(warn "$TMPROOT/wt"   main)"                          ""
check "QUIET silences it"     "$(warn "$TMPROOT/br" main 'DOTFILES_GUARD_QUIET=1')"   ""

# On the pin branch but not at the same commit as origin/<pin>. This is the
# state that caused the #87 outage — a merged, reviewed fix that simply was not
# running — and nothing about a checkout sitting on main looks wrong, so the
# startup line is its only automatic detection. It deliberately does not claim a
# direction: telling behind from ahead needs a merge base, which needs a fork.
mkdir -p "$TMPROOT/pinned/.git/refs/heads" "$TMPROOT/pinned/.git/refs/remotes/origin"
printf 'ref: refs/heads/main\n' > "$TMPROOT/pinned/.git/HEAD"
printf '%s\n' "$SHA_A" > "$TMPROOT/pinned/.git/refs/heads/main"
printf '%s\n' "$SHA_A" > "$TMPROOT/pinned/.git/refs/remotes/origin/main"
check "on pin and current is silent" "$(warn "$TMPROOT/pinned" main)"                    ""
printf '%s\n' "$SHA_B" > "$TMPROOT/pinned/.git/refs/remotes/origin/main"
check "on pin but diverged warns"    "$(warn "$TMPROOT/pinned" main | grep -c 'not the same commit as origin/main')" "1"
check "diverged names no direction"  "$(warn "$TMPROOT/pinned" main | grep -c 'Merged fixes may not be running')"    "1"
check "QUIET silences diverged too"  "$(warn "$TMPROOT/pinned" main 'DOTFILES_GUARD_QUIET=1')" ""
# No remote-tracking ref at all (a fresh clone, or a repo with no origin) is a
# normal state, and a guard that fires in normal states is one people learn to
# ignore.
rm "$TMPROOT/pinned/.git/refs/remotes/origin/main"
check "no origin ref is silent"      "$(warn "$TMPROOT/pinned" main)"                    ""

# Where was this shell sourced FROM? `./install` run from a worktree re-points
# every managed symlink at a feature branch, and every branch check above reads
# $DOTFILES_ROOT — none of them can see it. That state was silent: the doctor
# said "N/N declared links present" and the startup line said nothing at all.
mkdir -p "$TMPROOT/elsewhere"
: > "$TMPROOT/br/zshrc"
: > "$TMPROOT/elsewhere/zshrc"
ln -sf "$TMPROOT/br/zshrc" "$WARNHOME/.zshrc"
check "own checkout: no source warning" "$(warn "$TMPROOT/br" feature/x | grep -c 'sourced from')"       "0"
ln -sf "$TMPROOT/elsewhere/zshrc" "$WARNHOME/.zshrc"
check "foreign source warns"            "$(warn "$TMPROOT/br" feature/x | grep -c 'sourced from')"       "1"
check "foreign source names the path"   "$(warn "$TMPROOT/br" feature/x | grep -c 'elsewhere/zshrc')"    "1"
# It supersedes the branch line rather than adding to it: the branch of a tree
# that is not live is not the thing to report.
check "foreign source supersedes branch" "$(warn "$TMPROOT/br" main | grep -c 'live config is branch')"  "0"
check "QUIET silences foreign source"   "$(warn "$TMPROOT/br" main 'DOTFILES_GUARD_QUIET=1')"            ""
# A ~/.zshrc that is not a symlink is somebody else's arrangement, not a
# misinstalled one, and gets no opinion.
rm "$WARNHOME/.zshrc"; : > "$WARNHOME/.zshrc"
check "regular ~/.zshrc: no opinion"    "$(warn "$TMPROOT/br" feature/x | grep -c 'sourced from')"       "0"
rm "$WARNHOME/.zshrc"

echo
echo "=== _dotfiles_link_map: both dotbot link forms ==="
# dotbot accepts an inline mapping and an expanded one with `path:` beneath. A
# parser that knows only the inline form silently omits the rest — and silent
# omission is the failure this whole feature exists to prevent.
mkdir -p "$TMPROOT/conf"
cat > "$TMPROOT/conf/install.conf.yaml" <<'YAML'
- defaults:
    link:
      relink: true
- link:
    ~/.gitconfig: gitconfig
    # a comment mentioning ~/.decoy: decoy
    #   path: commented-out.txt
    ~/.config/thing.toml: config/thing.toml   # trailing comment
    ~/.flow.toml: {path: flow.toml, if: '[ -f flow.toml ]'}
    ~/.p10k.zsh:
      path: p10k.zsh
      if: '[ -f p10k.zsh ]'
YAML
map() { zrun "_dotfiles_link_map '$TMPROOT/conf'"; }

# Third field is the `if:` flag. It has to be captured, not ignored: a
# conditional link that is correctly not installed is not a fault, and treating
# it as one makes dotfiles-doctor exit non-zero forever on any machine where the
# condition is false — install.conf.yaml already ships one such entry.
check "inline form"            "$(map | grep -c '^~/.gitconfig gitconfig 0$')"                 "1"
check "trailing comment cut"   "$(map | grep -c '^~/.config/thing.toml config/thing.toml 0$')" "1"
check "expanded path: form"    "$(map | grep -c '^~/.p10k.zsh p10k.zsh 1$')"                   "1"
# Flow mapping. Read as an inline source it yields the literal string
# "{path: flow.toml, if: ...}", which then enters a git pathspec and makes the
# whole drift check fail — so the form is parsed rather than half-understood.
check "flow mapping form"      "$(map | grep -c '^~/.flow.toml flow.toml 1$')"                 "1"
check "comment line ignored"   "$(map | grep -c 'decoy')"                                      "0"
check "commented path ignored" "$(map | grep -c 'commented-out')"                              "0"
check "no spurious entries"    "$(map | wc -l | tr -d ' ')"                                    "4"
check "unreadable conf fails"  "$(zsh -c "source '$SYSTEM_SH'; _dotfiles_link_map '$TMPROOT/none'" >/dev/null 2>&1; echo $?)" "1"

# Quoting, dotbot's null form, and where an entry ENDS. All three were silent:
# a quoted source kept its quotes and became a git pathspec matching nothing
# (git exits 0 for that, so the file left the drift check while still counting as
# an installed link); the null form — `~/.vimrc:`, source inferred from the
# destination, which dotbot installs for real — was dropped entirely; and
# `target` was never cleared when the link: block ended, so the next `path:`
# anywhere below became the last link's source.
mkdir -p "$TMPROOT/conf2"
cat > "$TMPROOT/conf2/install.conf.yaml" <<'YAML'
- link:
    ~/.gitconfig: 'gitconfig'
    ~/.tmux.conf: "tmux.conf"
    ~/.vimrc:
    ~/.config/git/ignore:
    '~/.quoted': quoted-src
    ~/.last.zsh:
      path: last.zsh
- shell:
    - command: echo hi
      path: NOT-A-LINK-SOURCE
YAML
map2() { zrun "_dotfiles_link_map '$TMPROOT/conf2'"; }

check "single-quoted source"    "$(map2 | grep -c '^~/.gitconfig gitconfig 0$')"      "1"
check "double-quoted source"    "$(map2 | grep -c '^~/.tmux.conf tmux.conf 0$')"      "1"
# dotbot's _default_target(): the destination's basename, minus one leading dot.
check "null source inferred"    "$(map2 | grep -c '^~/.vimrc vimrc 0$')"              "1"
check "null source, nested"     "$(map2 | grep -c '^~/.config/git/ignore ignore 0$')" "1"
check "quoted destination"      "$(map2 | grep -c '^~/.quoted quoted-src 0$')"        "1"
check "last entry still parsed" "$(map2 | grep -c '^~/.last.zsh last.zsh 0$')"        "1"
check "entry ends with its block" "$(map2 | grep -c 'NOT-A-LINK-SOURCE')"             "0"
check "no spurious entries (2)" "$(map2 | wc -l | tr -d ' ')"                         "6"

# Live-but-unlinked paths. `zsh` because ~/.zshrc sources all of it; `scripts`
# because backup-*/audit-*/gnome-apply shell out to ~/.dotfiles/scripts/... and
# systemd/herdr-server.service ExecStarts from there — a running unit whose next
# exec comes from whatever HEAD points at. Omitting scripts/ understated the
# blast radius by four files on the branch that introduced this table.
check "static live paths: zsh"     "$(zrun '_dotfiles_static_live_paths' | grep -cx 'zsh')"     "1"
check "static live paths: scripts" "$(zrun '_dotfiles_static_live_paths' | grep -cx 'scripts')" "1"

echo
echo "=== _dotfiles_ref_sha / _dotfiles_pin_divergence: on the pin != up to date ==="
# Being ON main is not being UP TO DATE with main, and "behind" is the direction
# that caused the #87 outage. The startup path must detect it without forking,
# from either ref storage form — loose file, or a line in packed-refs after a gc.
REFREPO="$TMPROOT/refs"
mkdir -p "$REFREPO/.git/refs/heads" "$REFREPO/.git/refs/remotes/origin"
printf '%s\n' "$SHA_A" > "$REFREPO/.git/refs/heads/main"
printf '%s\n' "$SHA_A" > "$REFREPO/.git/refs/remotes/origin/main"
printf 'ref: refs/heads/main\n' > "$REFREPO/.git/HEAD"

ref_sha()   { zrun "_dotfiles_ref_sha '$1' '$2'; print -r -- \$_DOTFILES_REF_SHA"; }
diverged()  { zrun "_dotfiles_pin_divergence '$1' '${2:-main}'; print -r -- \$_DOTFILES_DIVERGED"; }

check "loose ref read"        "$(ref_sha "$REFREPO" refs/heads/main)"        "$SHA_A"
check "absent ref is empty"   "$(ref_sha "$REFREPO" refs/heads/nope)"        ""
check "same sha => same"      "$(diverged "$REFREPO")"                       "same"
printf '%s\n' "$SHA_B" > "$REFREPO/.git/refs/remotes/origin/main"
check "differing sha"         "$(diverged "$REFREPO")"                       "differs"
# Packed refs: git packs refs on gc, and a reader that only knows the loose form
# would silently stop checking from then on — passing forever, for a reason
# nobody would think to look for.
rm "$REFREPO/.git/refs/remotes/origin/main"
cat > "$REFREPO/.git/packed-refs" <<PACKED
# pack-refs with: peeled fully-peeled sorted
$SHA_B refs/remotes/origin/main
^3333333333333333333333333333333333333333
PACKED
check "packed ref read"       "$(ref_sha "$REFREPO" refs/remotes/origin/main)" "$SHA_B"
check "packed ref diverges"   "$(diverged "$REFREPO")"                         "differs"
rm "$REFREPO/.git/packed-refs"
check "no remote ref: unknown" "$(diverged "$REFREPO")"                        "unknown"
check "worktree: unknown"      "$(diverged "$TMPROOT/wt")"                     "unknown"

# Equal shas are not by themselves an all-clear. Both are read off local disk, so
# they agree the instant the machine stops fetching — permanently, and most of
# all on the machine that has not fetched since the fix it is missing was merged.
# That is #87 exactly, and the age of the ref is therefore part of the answer.
# Epoch arithmetic, not `touch -d '8 days ago'`: that is a WALL-CLOCK offset, so
# it lands 7d23h or 8d1h back across a DST change and the row fails twice a year
# on a developer's laptop for no reason connected to the code.
staleref() { touch -d "@$(( $(date +%s) - $1 * 86400 ))" "$2"; }
printf '%s\n' "$SHA_A" > "$REFREPO/.git/refs/remotes/origin/main"
check "fresh and same => same"      "$(diverged "$REFREPO")" "same"
staleref 8 "$REFREPO/.git/refs/remotes/origin/main"
check "stale and same => stale"     "$(diverged "$REFREPO")" "stale"
check "threshold is overridable" \
      "$(zrun "DOTFILES_STALE_WARN_HOURS=1000 _dotfiles_pin_divergence '$REFREPO' main; print -r -- \$_DOTFILES_DIVERGED")" "same"
# An unreadable age must not fall back to the answer it would have had if
# everything were fine: refs in packed-refs alone have no mtime to read.
rm "$REFREPO/.git/refs/remotes/origin/main"
cat > "$REFREPO/.git/packed-refs" <<PACKED
# pack-refs with: peeled fully-peeled sorted
$SHA_A refs/remotes/origin/main
PACKED
check "unknown age is not 'same'"   "$(diverged "$REFREPO")" "unknown"
rm "$REFREPO/.git/packed-refs"
# A difference is knowable whatever the ref's age, and outranks staleness.
printf '%s\n' "$SHA_B" > "$REFREPO/.git/refs/remotes/origin/main"
staleref 8 "$REFREPO/.git/refs/remotes/origin/main"
check "stale but differing => differs" "$(diverged "$REFREPO")" "differs"

# The startup line for it. Silence in this state is what let a merged fix sit
# unrun for a day while every check on the machine reported an all-clear.
mkdir -p "$TMPROOT/stalepin/.git/refs/heads" "$TMPROOT/stalepin/.git/refs/remotes/origin"
printf 'ref: refs/heads/main\n' > "$TMPROOT/stalepin/.git/HEAD"
printf '%s\n' "$SHA_A" > "$TMPROOT/stalepin/.git/refs/heads/main"
printf '%s\n' "$SHA_A" > "$TMPROOT/stalepin/.git/refs/remotes/origin/main"
staleref 10 "$TMPROOT/stalepin/.git/refs/remotes/origin/main"
check "stale pin warns at startup"  "$(warn "$TMPROOT/stalepin" main | grep -c 'has not been fetched in 10d')" "1"
check "stale pin names the fix"     "$(warn "$TMPROOT/stalepin" main | grep -c 'dotfiles-doctor --fetch')"     "1"
check "QUIET silences stale too"    "$(warn "$TMPROOT/stalepin" main 'DOTFILES_GUARD_QUIET=1')"               ""
touch "$TMPROOT/stalepin/.git/refs/remotes/origin/main"
check "fresh pin is silent again"   "$(warn "$TMPROOT/stalepin" main)"                                        ""

echo
echo "=== dotfiles-doctor against a real fixture repo ==="
# A throwaway repo with an origin, so ahead/behind and the file-level diff get
# exercised for real rather than stubbed.
REMOTE="$TMPROOT/remote.git"; REPO="$TMPROOT/repo"
# -b main is load-bearing: without it the bare repo's HEAD points at an unborn
# `master` on any machine that has not set init.defaultBranch (every CI runner),
# a clone of it checks out nothing, and the push-from-elsewhere fixture below
# then pushes no commit — making the --fetch rows fail for a reason that has
# nothing to do with the code under test.
git init -q --bare -b main "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  Test
mkdir -p "$REPO/zsh" "$REPO/config" "$REPO/scripts" "$REPO/docs"
# Its own link map rather than the parser fixture's: this one is the shape of the
# real install.conf.yaml (one conditional entry, no flow mapping), so the
# link-integrity counts below stay meaningful.
cat > "$REPO/install.conf.yaml" <<'YAML'
- defaults:
    link:
      relink: true
- link:
    ~/.gitconfig: gitconfig
    ~/.config/thing.toml: config/thing.toml
    ~/.p10k.zsh:
      path: p10k.zsh
      if: '[ -f p10k.zsh ]'
YAML
echo 'echo hi'   > "$REPO/zsh/zshrc.company"
# Live without being linked, and for two different reasons — see
# _dotfiles_static_live_paths. docs/ is neither, and is here to prove the
# working-tree status check is scoped rather than repo-wide.
echo 'echo scripted' > "$REPO/scripts/thing.sh"
echo 'notes'         > "$REPO/docs/NOTES.md"
# Symlinked to the fake HOME's ~/.gitconfig, so it must parse. The include
# mirrors the real file: it is what the safe.directory rows below rely on to
# prove the doctor reads the tracked file WITHOUT following it.
printf '[user]\n\tname = Fixture\n[include]\n\tpath = ~/.gitconfig.local\n' > "$REPO/gitconfig"
echo 'p10k'      > "$REPO/p10k.zsh"
echo 'thing'     > "$REPO/config/thing.toml"
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm init
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin

# Link integrity resolves ~/... against $HOME, which is correct in real use but
# would make these checks depend on whatever is in the tester's actual home
# directory — passing on this laptop and failing on a fresh CI runner, or the
# reverse. Give the fixture its own HOME so the whole table is hermetic.
FAKEHOME="$TMPROOT/home"
mkdir -p "$FAKEHOME/.config"
ln -s "$REPO/gitconfig"         "$FAKEHOME/.gitconfig"
ln -s "$REPO/config/thing.toml" "$FAKEHOME/.config/thing.toml"
ln -s "$REPO/p10k.zsh"          "$FAKEHOME/.p10k.zsh"

# $1 pin branch, $2 extra env assignments, $3 arguments to dotfiles-doctor.
doctor()    { zrun "HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' DOTFILES_PIN_BRANCH='${1:-main}' ${2:-} dotfiles-doctor ${3:-}"; }
doctor_rc() { zsh -c "source '$SYSTEM_SH'; HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' DOTFILES_PIN_BRANCH='${1:-main}' ${2:-} dotfiles-doctor ${3:-}" >/dev/null 2>&1; echo $?; }

check "clean and on pin exits 0"  "$(doctor_rc main)" "0"
check "clean and on pin all-clear" "$(doctor main | grep -c 'Live config is the reviewed config')" "1"
check "no drift reported"          "$(doctor main | grep -c 'none — every live file matches')"     "1"

# Ahead: unmerged code is live.
git -C "$REPO" checkout -q -b feature/live
echo 'echo unreviewed' >> "$REPO/zsh/zshrc.company"
git -C "$REPO" commit -qam "unreviewed change"

check "off-pin exits 1"          "$(doctor_rc main)"                                       "1"
check "off-pin branch named"     "$(doctor main | grep -c "on 'feature/live', not 'main'")" "1"
check "ahead is reported"        "$(doctor main | grep -c '1 commit(s) AHEAD')"             "1"
check "drifting file is named"   "$(doctor main | grep -c 'zsh/zshrc.company')"             "1"

# Behind: merged, reviewed fixes are not running. This is the state that let a
# fixed backup-doctor keep printing its false reassurance for a day.
git -C "$REPO" checkout -q main
echo 'echo merged-fix' >> "$REPO/zsh/zshrc.company"
git -C "$REPO" commit -qam "merged fix"
git -C "$REPO" push -q origin main
git -C "$REPO" fetch -q origin
git -C "$REPO" reset -q --hard HEAD~1

check "behind is reported" "$(doctor main | grep -c '1 commit(s) BEHIND')" "1"
check "behind exits 1"     "$(doctor_rc main)"                             "1"

echo
echo "=== silent-failure regressions (both once printed a green tick) ==="

# 1. `local path` in zsh blanks PATH for the rest of the function, because that
#    identifier is tied to the PATH array. Every external command after it then
#    fails; with stderr discarded, git's empty output read as "no drift" and the
#    doctor printed "none — every live file matches". Assert PATH survives.
check "PATH survives dotfiles-doctor" \
      "$(zsh -c "source '$SYSTEM_SH'; HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' dotfiles-doctor >/dev/null 2>&1; command -v git >/dev/null && echo ok || echo BROKEN")" \
      "ok"

# 2. Without an origin/<pin> ref there is nothing to compare against. Every diff
#    returns empty, indistinguishable from "no drift" unless the missing ref is
#    checked for first. It must report UNKNOWN, never an all-clear.
NOREMOTE="$TMPROOT/noremote"
git init -q -b main "$NOREMOTE"
git -C "$NOREMOTE" config user.email t@example.com
git -C "$NOREMOTE" config user.name Test
cp "$TMPROOT/conf/install.conf.yaml" "$NOREMOTE/install.conf.yaml"
git -C "$NOREMOTE" add -A >/dev/null && git -C "$NOREMOTE" commit -qm init

noref() { zrun "DOTFILES_ROOT='$NOREMOTE' DOTFILES_PIN_BRANCH=main dotfiles-doctor"; }
check "missing origin ref flagged"     "$(noref | grep -c 'no origin/main ref')"             "1"
check "no false all-clear without ref" "$(noref | grep -c 'none — every live file matches')" "0"
check "missing ref exits 1" \
      "$(zsh -c "source '$SYSTEM_SH'; DOTFILES_ROOT='$NOREMOTE' DOTFILES_PIN_BRANCH=main dotfiles-doctor" >/dev/null 2>&1; echo $?)" "1"

echo
echo "=== link integrity ==="
git -C "$REPO" checkout -q main
git -C "$REPO" reset -q --hard origin/main
check "all links installed"      "$(doctor main | grep -c '3/3 declared links present')" "1"
check "no dangling reported"     "$(doctor main | grep -c 'no dangling links')"          "1"
check "fully clean exits 0"      "$(doctor_rc main)"                                     "0"
check "clean run says all-clear" "$(doctor main | grep -c 'Live config is the reviewed config')" "1"

# Declared but never installed: ./install has not run since it was added, so the
# file is NOT live and edits to it do nothing. Silent in exactly the same way as
# everything else this feature exists to catch.
rm "$FAKEHOME/.config/thing.toml"
check "uninstalled link reported" "$(doctor main | grep -c 'not linked: ~/.config/thing.toml')" "1"
check "uninstalled link exits 1"  "$(doctor_rc main)"                                           "1"
ln -s "$REPO/config/thing.toml" "$FAKEHOME/.config/thing.toml"

# Installed but dangling: linked while on a branch that declares the target,
# left behind after switching away. A systemd user unit is in exactly this state
# on any machine that ran ./install on a branch that added one.
rm "$FAKEHOME/.p10k.zsh"
ln -s "$REPO/gone-with-that-branch" "$FAKEHOME/.p10k.zsh"
check "dangling link reported" "$(doctor main | grep -c 'dangling (target absent on this branch): ~/.p10k.zsh')" "1"
check "dangling link exits 1"  "$(doctor_rc main)"                                                                "1"

echo
echo "=== blast radius: scripts/ is live too ==="
# Every backup-*, audit-*, gnome-apply and verify-tools command shells out to
# ~/.dotfiles/scripts/..., and systemd/herdr-server.service ExecStarts from
# there. Omitting scripts/ from the live set understated the blast radius by four
# files on the very branch that added this table — including a script that
# writes root-owned files into /etc.
ln -sf "$REPO/p10k.zsh" "$FAKEHOME/.p10k.zsh"
git -C "$REPO" checkout -q -b feature/scripts
echo 'echo changed' >> "$REPO/scripts/thing.sh"
git -C "$REPO" commit -qam "change a script"
check "scripts/ drift is reported" "$(doctor main | grep -c 'scripts/thing.sh')" "1"
git -C "$REPO" checkout -q main

echo
echo "=== an unparseable link map is not an empty one ==="
# With no links resolved, the pathspec is empty, the diff returns nothing, and
# the section used to print "none — every live file matches". The emptiness guard
# it was supposed to hit could never fire, because the live-path list always had
# a hardcoded entry appended. Not knowing what is live must read as UNKNOWN.
NOMAP="$TMPROOT/nomap"
git init -q -b main "$NOMAP"
git -C "$NOMAP" config user.email t@example.com
git -C "$NOMAP" config user.name Test
mkdir -p "$NOMAP/zsh"
printf -- '- link:\n' > "$NOMAP/install.conf.yaml"   # parses as YAML, declares nothing
echo 'echo hi' > "$NOMAP/zsh/zshrc.company"
git -C "$NOMAP" add -A >/dev/null && git -C "$NOMAP" commit -qm init
git -C "$NOMAP" remote add origin "$REMOTE" && git -C "$NOMAP" fetch -q origin
# One commit of real, live drift against origin/main, which must NOT be reported
# as "everything matches" just because the link map yielded nothing.
nomap() { zrun "DOTFILES_ROOT='$NOMAP' DOTFILES_PIN_BRANCH=main dotfiles-doctor"; }
check "empty map says UNKNOWN"    "$(nomap | grep -c 'what is live is UNKNOWN')"        "1"
check "empty map: no all-clear"   "$(nomap | grep -c 'none — every live file matches')" "0"
check "empty map: no green tick"  "$(nomap | grep -c 'Live config is the reviewed config')" "0"
check "empty map exits 1" \
      "$(zsh -c "source '$SYSTEM_SH'; DOTFILES_ROOT='$NOMAP' DOTFILES_PIN_BRANCH=main dotfiles-doctor" >/dev/null 2>&1; echo $?)" "1"
# And the two ways of not knowing are named apart, because their fixes differ.
# _dotfiles_link_map has always returned non-zero for "could not read the file",
# but its only caller took its output through a process substitution and threw
# the status away, so both landed on one message that named only the other one.
check "empty map says which"      "$(nomap | grep -c 'declares nothing this parser recognises')" "1"
mv "$NOMAP/install.conf.yaml" "$NOMAP/install.conf.yaml.gone"
check "unreadable map says which" "$(nomap | grep -c 'missing or unreadable')"                   "1"
check "unreadable map: no tick"   "$(nomap | grep -c 'Live config is the reviewed config')"      "0"
mv "$NOMAP/install.conf.yaml.gone" "$NOMAP/install.conf.yaml"

echo
echo "=== uncommitted changes are scoped to live files ==="
# Unscoped, `git status --porcelain` reported every scratch file and
# node_modules/ in the tree, with untracked directories collapsed so the
# offending file was not even named. Noise in normal states is how a checker
# becomes one nobody reads.
: > "$REPO/docs/NOTES-scratch.md"
: > "$REPO/zsh/scratch.txt"
check "untracked live file named"    "$(doctor main | grep -c 'zsh/scratch.txt')"       "1"
check "untracked non-live ignored"   "$(doctor main | grep -c 'NOTES-scratch')"         "0"
check "no collapsed directory entry" "$(doctor main | grep -cE '\?\? docs/$')"           "0"
rm "$REPO/docs/NOTES-scratch.md" "$REPO/zsh/scratch.txt"

# A file a tool is *meant* to write through its symlink (plugins.lock, per
# install.conf.yaml) is a note, not a warning — and must not change the exit code.
echo 'local edit' >> "$REPO/config/thing.toml"
check "expected-dirty is a note"  "$(doctor main "DOTFILES_EXPECTED_DIRTY='config/thing.toml'" | grep -c '· M config/thing.toml (expected')" "1"
check "expected-dirty exits 0"    "$(doctor_rc main "DOTFILES_EXPECTED_DIRTY='config/thing.toml'")" "0"
check "unexpected-dirty warns"    "$(doctor main | grep -c '⚠ M config/thing.toml')" "1"
git -C "$REPO" checkout -q -- config/thing.toml

# Plain --porcelain is not a format you can compare paths against: it C-quotes
# any path holding a space and writes a rename as "old -> new". Both reached
# DOTFILES_EXPECTED_DIRTY as a string no entry could ever equal, so such a file
# was a permanent warning with no way to excuse it — and word-splitting the
# variable made a spaced path impossible to express in the first place.
doctor_arr() { zrun "HOME='$FAKEHOME'; DOTFILES_ROOT='$REPO'; DOTFILES_PIN_BRANCH=main; DOTFILES_EXPECTED_DIRTY=($1); dotfiles-doctor"; }
: > "$REPO/zsh/a file with spaces.sh"
check "spaced path is unquoted"  "$(doctor main | grep -c '?? zsh/a file with spaces.sh')"                  "1"
check "spaced path excusable"    "$(doctor_arr "'zsh/a file with spaces.sh'" | grep -c 'spaces.sh (expected')" "1"
rm "$REPO/zsh/a file with spaces.sh"
git -C "$REPO" mv zsh/zshrc.company zsh/zshrc.renamed
check "rename shows both paths"  "$(doctor main | grep -c 'zsh/zshrc.company → zsh/zshrc.renamed')"         "1"
check "rename excusable by old"  "$(doctor main "DOTFILES_EXPECTED_DIRTY='zsh/zshrc.company'" | grep -c '(expected')" "1"
check "rename excusable by new"  "$(doctor main "DOTFILES_EXPECTED_DIRTY='zsh/zshrc.renamed'" | grep -c '(expected')" "1"
git -C "$REPO" mv zsh/zshrc.renamed zsh/zshrc.company

echo
echo "=== safe.directory in the tracked gitconfig ==="
# ~/.gitconfig is a symlink into the checkout and `git config --global` writes
# through it, so a safe.directory entry added by ANY git-using tool lands in a
# tracked file in a public repo — auto-conf's configure.py adds one for every
# workspace it builds. The generic uncommitted-changes warning cannot say what
# the edit is or whether git ever needed it; the doctor's section does both, and
# every state it names is a row here. Several of these rows exist because a
# review reached a state the first version never tested: a STAGED entry, for
# which the advertised `git restore` was a no-op; an index-only entry behind a
# green tick; colour and diff.external settings that blinded a diff parser; an
# unreadable file that exited 1 like "no entries"; and git's own reading of
# `~`, `~user/`, `?`, an empty value and a relative path.
SCRATCH="$TMPROOT/scratch"
GONE="$SCRATCH/gone-workspace"                                     # deleted with its scratchpad
OWN="$SCRATCH/own-workspace";  mkdir -p "$OWN";  git init -q "$OWN"  # exists, owned by the tester
PLAIN="$SCRATCH/plain-dir";    mkdir -p "$PLAIN"                   # exists, not a repository
sdadd() { git config --file "$REPO/gitconfig" --add safe.directory "$1"; }
sdclean() { git -C "$REPO" restore --staged --worktree -- gitconfig; }
check "clean gitconfig: its own tick"  "$(doctor main | grep -c 'none — machine-specific entries belong in ~/.gitconfig.local')" "1"
sdadd "$GONE"; sdadd "$OWN"; sdadd "$PLAIN"
# The tilde is git's to expand, not the shell's: `~/*` is exactly how the real
# ~/.gitconfig.local spells "every repository under HOME".
# shellcheck disable=SC2088
sdadd '~/*'
check "polluted gitconfig is a ✗"        "$(doctor main | grep -c '✗ 4 safe.directory entry(s) in gitconfig')" "1"
check "polluted gitconfig exits 1"       "$(doctor_rc main)"                                               "1"
check "deleted workspace is 'gone'"      "$(doctor main | grep -cE "^ +gone +$GONE\$")"                   "1"
check "same-owner workspace is measured" "$(doctor main | grep -cE "^ +same owner +$OWN\$")"              "1"
# Classified by exit status, so the label holds under a localized git; git's
# own first line follows in parentheses, in whatever language it speaks.
check "non-repo is 'not a repo'"         "$(doctor main | grep -cE "^ +not a repo +$PLAIN  \\(")"        "1"
check "trailing /* is 'pattern'"         "$(doctor main | grep -cE "^ +pattern +~/\\*\$")"                "1"
# --staged --worktree, not a bare restore: the bare form copies the INDEX into
# the worktree and is a no-op the moment the entries have been `git add`ed.
check "the fix restores index and worktree" "$(doctor main | grep -c "Fix (4 not in HEAD): git -C $REPO restore --staged --worktree -- gitconfig")" "1"
check "no PR advice while uncommitted"   "$(doctor main | grep -c 'Committed in HEAD')"                    "0"
check "no other-edits caveat"            "$(doctor main | grep -c 'also differs from HEAD in other ways')" "0"
# The reader is told a TOOL does this, or the next question is "which of my
# sessions typed that" — the question the investigation spent a day on.
check "the writer is named"              "$(doctor main | grep -c "auto-conf's configure.py does")"        "1"
# The generic line becomes a pointer, not a second vaguer report of the same fact…
check "generic line points up"           "$(doctor main | grep -c '· M gitconfig — only the safe.directory entries reported above')" "1"
check "generic ⚠ is not duplicated"      "$(doctor main | grep -c '⚠ M gitconfig')"                       "0"
# …but only while the entries are the WHOLE difference from HEAD. Another edit
# keeps its warning, and the printed fix says the restore would discard it.
printf '[alias]\n\tst = status\n' >> "$REPO/gitconfig"
check "other edits keep the generic ⚠"   "$(doctor main | grep -c '⚠ M gitconfig')"                       "1"
check "…and the fix carries a caveat"    "$(doctor main | grep -c 'also differs from HEAD in other ways')" "1"
# color.ui=always and a diff.external driver (difftastic's documented setup) in
# the INCLUDED ~/.gitconfig.local reshape `git diff` output. The first version
# parsed that output and downgraded the warning for ANY edit in this state.
printf '[color]\n\tui = always\n[diff]\n\texternal = /bin/echo\n' > "$FAKEHOME/.gitconfig.local"
check "colour + external diff do not hide the edit" "$(doctor main | grep -c '⚠ M gitconfig')"            "1"
rm "$FAKEHOME/.gitconfig.local"
sdclean
# Staged — `git add -A` has run, the commit has not. The state the headline
# warns is next, and the one a bare `git restore` cannot reach.
sdadd "$GONE"; git -C "$REPO" add gitconfig
check "staged entry is reported"         "$(doctor main | grep -c '✗ 1 safe.directory entry(s) in gitconfig')" "1"
check "staged entry is marked"           "$(doctor main | grep -c "$GONE  (staged)\$")"                    "1"
check "staged: generic line still a pointer" "$(doctor main | grep -c '· M gitconfig — only the safe.directory')" "1"
# The remedy must remedy: run the fix exactly as the doctor prints it.
fix="$(doctor main | sed -n 's/^    Fix ([^)]*): //p')"
eval "$fix"
check "running the printed fix clears the index too" "$(git -C "$REPO" status --porcelain -- gitconfig)" ""
check "…and the tick returns"            "$(doctor main | grep -c 'none — machine-specific')"             "1"
# Index-only: staged, then the worktree copy reverted by hand. A read of the
# file sees nothing; a plain `git commit` would still carry the entry.
sdadd "$GONE"; git -C "$REPO" add gitconfig; git -C "$REPO" show HEAD:gitconfig > "$REPO/gitconfig"
check "index-only entry is not a green tick" "$(doctor main | grep -c 'none — machine-specific')"         "0"
check "index-only entry is reported"     "$(doctor main | grep -c '✗ 1 safe.directory entry(s) in gitconfig')" "1"
check "…marked staged only"              "$(doctor main | grep -c "$GONE  (staged only)\$")"               "1"
sdclean
# Entries in the INCLUDED ~/.gitconfig.local are the correct state and must not
# be reported — and the HEAD read must not follow the include either: --blob
# follows includes BY DEFAULT (--file does not), so without --no-includes a
# value present in both files reads as "(committed)" and the reader is sent to
# a PR for something the restore would clear.
printf '[safe]\n\tdirectory = *\n' > "$FAKEHOME/.gitconfig.local"
check "entries in ~/.gitconfig.local are not pollution" "$(doctor main | grep -c 'none — machine-specific entries belong')" "1"
printf '[safe]\n\tdirectory = %s\n' "$GONE" > "$FAKEHOME/.gitconfig.local"; sdadd "$GONE"
check "an include-only value is not '(committed)'" "$(doctor main | grep -c "$GONE  (committed)")"        "0"
check "…it is uncommitted"               "$(doctor main | grep -c 'Fix (1 not in HEAD)')"                  "1"
sdclean
# A workspace git genuinely refuses. GIT_TEST_ASSUME_DIFFERENT_OWNER makes git
# treat every repository as somebody else's — the only way to reach the state
# without root. The `*` in the fake ~/.gitconfig.local keeps the doctor's own
# git calls working; the per-entry probe resets the list, so it still sees the
# refusal. Same fixture without the variable must read "same owner", or the row
# proves only that the variable works.
printf '[safe]\n\tdirectory = *\n' > "$FAKEHOME/.gitconfig.local"
sdadd "$OWN"
check "foreign-owned workspace is 'other owner'" "$(doctor main GIT_TEST_ASSUME_DIFFERENT_OWNER=1 | grep -cE "^ +other owner +$OWN\$")" "1"
check "…and is sent to ~/.gitconfig.local"       "$(doctor main GIT_TEST_ASSUME_DIFFERENT_OWNER=1 | grep -c 'git config --file ~/.gitconfig.local --add safe.directory')" "1"
# An entry naming a SUBDIRECTORY of that repository is one git never honours
# (measured: with the list reset, `repo/sub` and `repo?` are refused while
# `repo`, `repo/`, a symlink to it and `*` are accepted). The probe that says
# so must reset the list first: a lone `-c safe.directory=<entry>` only
# appends, and the `*` in this fixture's include would answer for it.
mkdir -p "$OWN/sub"; sdadd "$OWN/sub"
check "subdirectory of a foreign repo is 'not matched'" "$(doctor main GIT_TEST_ASSUME_DIFFERENT_OWNER=1 | grep -cE "^ +not matched +$OWN/sub  \\(")" "1"
check "same fixture, same owner without it"      "$(doctor main | grep -cE "^ +same owner +$OWN\$")"       "1"
check "no ~/.gitconfig.local advice then"        "$(doctor main | grep -c 'git config --file ~/.gitconfig.local --add')" "0"
sdclean
rm "$FAKEHOME/.gitconfig.local"
# git's reading of the value, not this function's. `--type=path` expands a bare
# `~` and `~/x` (and `~user/x`, which needs a passwd entry and is not staged
# here); only `*` and a trailing `/*` are patterns — a `?` or a `*` elsewhere is
# compared literally; an empty value is the documented "reset the list"; a
# relative path is warned about and ignored. The first version dropped the
# empty value on the floor and printed "✗ 0 entries" with no fix line.
git init -q "$FAKEHOME/own"
# The tildes are git's to expand, deliberately not the shell's.
# shellcheck disable=SC2088
sdadd '~'
# shellcheck disable=SC2088
sdadd '~/own'
sdadd ''; sdadd "scratch/own-workspace"; sdadd "$SCRATCH/*/own-workspace"; sdadd "${PLAIN}?"
check "all six are counted, the empty one included" "$(doctor main | grep -c '✗ 6 safe.directory entry(s)')" "1"
check "bare ~ is expanded, not 'gone'"   "$(doctor main | grep -cE "^ +not a repo +~  \\(")"             "1"
# shellcheck disable=SC2088
check "~/x is expanded and probed"       "$(doctor main | grep -cE "^ +same owner +~/own\$")"             "1"
check "empty value is git's list reset"  "$(doctor main | grep -cE "^ +empty +<empty>\$")"                "1"
check "relative path is 'relative'"      "$(doctor main | grep -cE "^ +relative +scratch/own-workspace\$")" "1"
check "mid-path * is literal: 'gone'"    "$(doctor main | grep -cE "^ +gone +$SCRATCH/\\*/own-workspace\$")" "1"
check "? is literal: 'gone'"             "$(doctor main | grep -cE "^ +gone +$PLAIN\\?\$")"               "1"
check "none of them is 'pattern'"        "$(doctor main | grep -cE '^ +pattern ')"                        "0"
sdclean
rm -rf "$FAKEHOME/own"
# Committed: it passed review, so it is a ⚠ and not the permanently-red ✗ an
# adopter who committed `*` on purpose would learn to ignore. Pushed to the
# fixture remote so nothing else in the report is red.
# shellcheck disable=SC2088
sdadd '~/committed-ws'
git -C "$REPO" commit -qam "commit a safe.directory entry"
git -C "$REPO" push -q origin main && git -C "$REPO" fetch -q origin
check "committed entry is a ⚠"            "$(doctor main | grep -c '⚠ 1 safe.directory entry(s) committed in gitconfig')" "1"
check "committed entry alone exits 0"     "$(doctor_rc main)"                                              "0"
# shellcheck disable=SC2088
check "committed entry is marked"         "$(doctor main | grep -c '~/committed-ws  (committed)$')"        "1"
check "committed entry wants a PR"        "$(doctor main | grep -c 'Committed in HEAD (1)')"               "1"
check "committed entry: no restore advice" "$(doctor main | grep -c 'Fix (')"                              "0"
# …and a fresh uncommitted one beside it is still a ✗ with a restore. It is a
# glob on purpose: the HEAD lookup must compare values, not use the new value
# as a PATTERN over the committed ones — `(I)` instead of `(Ie)` would match
# `~/*` against `~/committed-ws`, call the glob committed, and lose its fix.
# shellcheck disable=SC2088
sdadd '~/*'
check "mixed: the uncommitted one makes it a ✗" "$(doctor main | grep -c '✗ 2 safe.directory entry(s) in gitconfig')" "1"
check "mixed: restore counts only the new one"  "$(doctor main | grep -c 'Fix (1 not in HEAD)')"           "1"
# shellcheck disable=SC2088
check "an uncommitted glob is not matched against committed paths" "$(doctor main | grep -c '~/\*  (committed)')" "0"
sdclean
git -C "$REPO" reset -q --hard HEAD~1
git -C "$REPO" push -q -f origin main && git -C "$REPO" fetch -q origin
# Unparseable: UNKNOWN, never a tick. Reachable only while ~/.gitconfig points
# elsewhere — linked, a malformed tracked gitconfig kills every git call and the
# doctor stops at its health probe, which is the right answer there.
printf '[user]\n\tname = Elsewhere\n' > "$SCRATCH/other-gitconfig"
ln -sf "$SCRATCH/other-gitconfig" "$FAKEHOME/.gitconfig"
printf '[[[not a git config\n' > "$REPO/gitconfig"
check "unparseable gitconfig is UNKNOWN" "$(doctor main | grep -c 'safe.directory state UNKNOWN')"  "1"
check "unparseable gitconfig: no tick"   "$(doctor main | grep -c 'none — machine-specific')"       "0"
git -C "$REPO" checkout -q -- gitconfig
ln -sf "$REPO/gitconfig" "$FAKEHOME/.gitconfig"
# Unreadable: `git config --get-all` exits 1 for EACCES, the same status as "no
# such key", and the first version printed ✓ over a file it could not open.
# git merely warns about an unreadable ~/.gitconfig, so the link can stay.
if (( EUID != 0 )); then
  sdadd "$GONE"; chmod 000 "$REPO/gitconfig"
  check "unreadable gitconfig is UNKNOWN"  "$(doctor main | grep -c 'safe.directory state UNKNOWN')" "1"
  check "unreadable gitconfig: no tick"    "$(doctor main | grep -c 'none — machine-specific')"      "0"
  chmod 644 "$REPO/gitconfig"; sdclean
else
  echo "  · unreadable-file rows skipped: root reads mode-000 files"
fi
# A HEAD copy git cannot parse: committed cannot be told from uncommitted, and a
# restore would put that copy under the live ~/.gitconfig symlink. `config
# --blob` exits 1 for it — the "no such key" status — so the first version read
# it as "no entries" and advised exactly that restore.
git -C "$REPO" checkout -q -b feature/badhead
printf '[[[not a git config\n' > "$REPO/gitconfig"
git -C "$REPO" commit -qam "a broken gitconfig in HEAD"
printf '[user]\n\tname = Fixture\n[safe]\n\tdirectory = %s\n' "$GONE" > "$REPO/gitconfig"
check "unparseable HEAD copy is named"   "$(doctor main | grep -c "HEAD's gitconfig cannot be parsed")" "1"
check "unparseable HEAD: no restore advice" "$(doctor main | grep -c 'Fix (')"                         "0"
check "unparseable HEAD is still a ✗"    "$(doctor main | grep -c '✗ 1 safe.directory entry(s)')"      "1"
git -C "$REPO" checkout -q -- gitconfig
git -C "$REPO" checkout -q main
git -C "$REPO" branch -qD feature/badhead
# No gitconfig in the tree is a note, not a finding: the other fixture repos
# have none, and neither does an adopter who does not manage git through here.
check "no gitconfig is a note"           "$(noref | grep -c '· no gitconfig in')"                  "1"
# One that exists but is in neither HEAD nor the index: reported, and honest
# that there is nothing to restore from rather than advising a restore that
# would fail.
git config --file "$NOREMOTE/gitconfig" --add safe.directory "$GONE"
check "untracked gitconfig still reported" "$(noref | grep -c '✗ 1 safe.directory entry(s) in gitconfig')" "1"
check "…and HEAD's silence is named"       "$(noref | grep -c 'not in HEAD, so there is nothing to restore from')" "1"
check "…with no restore advice"            "$(noref | grep -c 'Fix (')"                             "0"
rm "$NOREMOTE/gitconfig"
# The file is whatever the link map says ~/.gitconfig points at, not a hardcoded
# `gitconfig`: rename the source and a hardcoded name reads "nothing to check"
# over a polluted live file — the fourth link direction's failure, in a new place.
SRCMAP="$TMPROOT/srcmap"
git init -q -b main "$SRCMAP"
git -C "$SRCMAP" config user.email t@example.com
git -C "$SRCMAP" config user.name Test
mkdir -p "$SRCMAP/git"
printf -- '- link:\n    ~/.gitconfig: git/config\n' > "$SRCMAP/install.conf.yaml"
printf '[user]\n\tname = Renamed\n' > "$SRCMAP/git/config"
git -C "$SRCMAP" add -A >/dev/null && git -C "$SRCMAP" commit -qm init
git config --file "$SRCMAP/git/config" --add safe.directory "$GONE"
srcmap() { zrun "DOTFILES_ROOT='$SRCMAP' DOTFILES_PIN_BRANCH=main dotfiles-doctor"; }
check "source path comes from the link map" "$(srcmap | grep -c '✗ 1 safe.directory entry(s) in git/config')" "1"
check "…and the fix names it"            "$(srcmap | grep -c 'restore --staged --worktree -- git/config')" "1"
check "…and the generic line follows it" "$(srcmap | grep -c '· M git/config — only the safe.directory')" "1"
# A map that declares no ~/.gitconfig at all: nothing writes through, so a note.
NOLINK="$TMPROOT/nolink"
git init -q -b main "$NOLINK"
git -C "$NOLINK" config user.email t@example.com
git -C "$NOLINK" config user.name Test
printf -- '- link:\n    ~/.thing: thing\n' > "$NOLINK/install.conf.yaml"
echo thing > "$NOLINK/thing"
git -C "$NOLINK" add -A >/dev/null && git -C "$NOLINK" commit -qm init
check "undeclared ~/.gitconfig is a note" "$(zrun "DOTFILES_ROOT='$NOLINK' DOTFILES_PIN_BRANCH=main dotfiles-doctor" | grep -c '· ~/.gitconfig is not a declared link')" "1"

echo
echo "=== links must resolve INSIDE this checkout ==="
# `./install` run from a worktree re-points the whole live config at a feature
# branch. Checking only "is it a symlink" passed that state with "N/N declared
# links present" while every other check in the function inspected the primary
# checkout, and the startup warning stayed silent — the feature defeated by one
# command, invisibly.
OTHERTREE="$TMPROOT/otherworktree"
mkdir -p "$OTHERTREE"
printf '[user]\n\tname = Unreviewed\n' > "$OTHERTREE/gitconfig"
ln -sf "$OTHERTREE/gitconfig" "$FAKEHOME/.gitconfig"
check "foreign link reported"  "$(doctor main | grep -c 'points OUTSIDE the checkout')" "1"
check "foreign link named"     "$(doctor main | grep -c 'otherworktree/gitconfig')"     "1"
check "foreign link exits 1"   "$(doctor_rc main)"                                      "1"
ln -sf "$REPO/gitconfig" "$FAKEHOME/.gitconfig"
check "own links pass"         "$(doctor main | grep -c 'every link resolves inside')"  "1"

echo
echo "=== a link into the RIGHT tree but at the WRONG file ==="
# Rename a source in install.conf.yaml and forget to re-run ./install: the old
# link still resolves to a real file inside the checkout, so it is not missing,
# not dangling and not foreign. Three green ticks and a full all-clear, while the
# live file is the old source — permanently, since nothing else ever looks.
ln -sf "$REPO/p10k.zsh" "$FAKEHOME/.config/thing.toml"
check "wrong-file link reported" "$(doctor main | grep -c 'points at the WRONG file')"          "1"
check "wrong-file link named"    "$(doctor main | grep -c '[~]/.config/thing.toml→p10k.zsh')"  "1"
check "wrong-file exits 1"       "$(doctor_rc main)"                                            "1"
# It is none of the other three, so it must not be miscounted as one of them —
# each has a different fix, and "not linked (run ./install)" is wrong advice here.
check "wrong file is not foreign"  "$(doctor main | grep -c 'points OUTSIDE')"                  "0"
check "wrong file is not missing"  "$(doctor main | grep -c 'not linked: ~/.config/thing.toml')" "0"
check "wrong file is not dangling" "$(doctor main | grep -c 'dangling (target absent')"          "0"
ln -sf "$REPO/config/thing.toml" "$FAKEHOME/.config/thing.toml"
check "correct link passes"      "$(doctor main | grep -c 'points at the source install.conf.yaml declares')" "1"

echo
echo "=== a conditional link (\`if:\`) that is absent is not a failure ==="
# install.conf.yaml ships ~/.p10k.zsh with `if: [ -f p10k.zsh ]`. On a machine
# where such a condition is false the link is correctly absent; reporting it as
# "not linked" made the doctor exit 1 permanently, and a permanently-red checker
# is a permanently-ignored one.
rm "$FAKEHOME/.p10k.zsh"
check "conditional absence noted"  "$(doctor main | grep -c '· conditional in install.conf.yaml')" "1"
check "conditional not a failure"  "$(doctor main | grep -c 'not linked: ~/.p10k.zsh')"            "0"
check "conditional exits 0"        "$(doctor_rc main)"                                             "0"
ln -sf "$REPO/p10k.zsh" "$FAKEHOME/.p10k.zsh"

echo
echo "=== git itself unusable: no confident wrong answers ==="
# A malformed ~/.gitconfig makes every git call exit 128 — and ~/.gitconfig is
# itself one of the managed symlinks whose content changes on the branch switch
# this function is about, so a bad branch could blind the guard to that branch.
# Two checks used to convert that into definite claims: "no origin/main ref —
# Fix: git fetch origin" (the ref existed) and "(none)" worktrees (three did).
BADGIT="$TMPROOT/badgit"
git init -q -b main "$BADGIT"
printf 'this is not [[[ a git config\n' > "$BADGIT/.git/config"
badgit() { zrun "DOTFILES_ROOT='$BADGIT' DOTFILES_PIN_BRANCH=main dotfiles-doctor"; }
check "broken git is reported"     "$(badgit | grep -c 'git cannot read')"        "1"
check "no false missing-ref claim" "$(badgit | grep -c 'no origin/main ref')"     "0"
check "no false worktree claim"    "$(badgit | grep -c '(none) — dotfiles-work')" "0"
check "broken git exits 1" \
      "$(zsh -c "source '$SYSTEM_SH'; DOTFILES_ROOT='$BADGIT' DOTFILES_PIN_BRANCH=main dotfiles-doctor" >/dev/null 2>&1; echo $?)" "1"

echo
echo "=== a stale origin ref is not a current one ==="
# The whole feature turns on this. Nothing on this machine fetches on a
# schedule, so origin/main is exactly as old as the last `git fetch` — and
# against a week-old ref, "not behind" means "not behind what was true a week
# ago". That is the #87 scenario reported as a green tick.
check "fresh fetch is stated"  "$(doctor main | grep -c 'last fetched 0h ago')" "1"

# Epoch arithmetic, not `touch -d '3 days ago'`: that is a wall-clock offset, so
# across a DST transition it lands 71 or 73 hours back and this row fails twice a
# year on a developer's machine for a reason unconnected to the code. CI runs UTC
# and would never have shown it.
staleref 3 "$REPO/.git/FETCH_HEAD"
[[ -e "$REPO/.git/refs/remotes/origin/main" ]] && staleref 3 "$REPO/.git/refs/remotes/origin/main"
check "stale ref warns"        "$(doctor main | grep -c 'last fetched 72h ago')"            "1"
check "stale ref: no green tick" "$(doctor main | grep -c 'Live config is the reviewed config')" "0"
check "stale ref still exits 0"  "$(doctor_rc main)"                                        "0"

# And the merged-fix-not-running case end to end: someone else pushes to main,
# this checkout never fetches, and the read-only run therefore cannot see it.
# --fetch is the only thing that can, so it must actually change the verdict.
PUSHER="$TMPROOT/pusher"
git clone -q -b main "$REMOTE" "$PUSHER"
git -C "$PUSHER" config user.email t@example.com
git -C "$PUSHER" config user.name Test
# Assert the fixture before asserting the behaviour. Both rows below are of the
# form "the doctor now sees a commit it could not see before", and a clone that
# checked out nothing produces the same output as a doctor that ignored the
# fetch — which is how this failed in CI while passing locally.
git -C "$PUSHER" rev-parse --verify -q HEAD >/dev/null \
  || fatal "pusher clone has no HEAD — the bare remote's default branch is wrong"
echo 'echo merged-elsewhere' >> "$PUSHER/zsh/zshrc.company"
git -C "$PUSHER" commit -qam "a fix merged by someone else"
git -C "$PUSHER" push -q origin main
[[ "$(git -C "$REMOTE" rev-parse refs/heads/main)" != "$(git -C "$REPO" rev-parse HEAD)" ]] \
  || fatal "the pushed commit did not land on the remote — nothing for --fetch to find"
check "stale run cannot see it"  "$(doctor main | grep -c 'commit(s) BEHIND')" "0"
check "--fetch sees it"          "$(doctor main '' '--fetch' | grep -c '1 commit(s) BEHIND')" "1"
check "--fetch exits 1"          "$(doctor_rc main '' '--fetch')" "1"

echo
echo "=== install's own symlinks are live too (~/.config/mise/config.toml) ==="
# .mise.toml is symlinked by `install` itself, not by dotbot, so it appears in no
# link: block — and was therefore in nothing the doctor checked. CLAUDE.md
# records the bill for that going unnoticed: the live config declared 10 tools
# against the repo's 23, ~11 binaries never reached PATH, and `git diff` died
# with "unable to execute pager 'delta'", for months, with nothing reporting it.
MISEREPO="$TMPROOT/miserepo"; MISEHOME="$TMPROOT/misehome"
git init -q -b main "$MISEREPO"
git -C "$MISEREPO" config user.email t@example.com
git -C "$MISEREPO" config user.name  Test
mkdir -p "$MISEREPO/zsh"
printf -- '- link:\n    ~/.gitconfig: gitconfig\n' > "$MISEREPO/install.conf.yaml"
printf '[user]\n\tname = Fixture\n' > "$MISEREPO/gitconfig"
printf '[tools]\n' > "$MISEREPO/.mise.toml"
git -C "$MISEREPO" add -A >/dev/null && git -C "$MISEREPO" commit -qm init
mkdir -p "$MISEHOME/.local/bin" "$MISEHOME/.config/mise"
printf '#!/bin/sh\n' > "$MISEHOME/.local/bin/mise"; chmod +x "$MISEHOME/.local/bin/mise"
ln -s "$MISEREPO/gitconfig" "$MISEHOME/.gitconfig"

# PATH is emptied for the unit rows so the answer depends on the fixture and not
# on whether the machine running the suite happens to have mise installed.
extra() { zrun "PATH=/nonexistent; HOME='$1'; _dotfiles_extra_links '$2'"; }
check "emitted when install would" "$(extra "$MISEHOME" "$MISEREPO" | grep -c '^~/.config/mise/config.toml .mise.toml 0$')" "1"
# Both halves of install's own gate, because a link install never made is not a
# fault — and a checker that is red for a correct state is one nobody reads.
check "no .mise.toml: not emitted"  "$(extra "$MISEHOME"   "$REPO"     | wc -l | tr -d ' ')" "0"
check "no mise at all: not emitted" "$(extra "$TMPROOT/none" "$MISEREPO" | wc -l | tr -d ' ')" "0"
check "mise on PATH also counts" \
      "$(zrun "PATH='$MISEHOME/.local/bin'; HOME='$TMPROOT/none'; _dotfiles_extra_links '$MISEREPO'" | wc -l | tr -d ' ')" "1"

misedoc() { zrun "HOME='$MISEHOME' DOTFILES_ROOT='$MISEREPO' DOTFILES_PIN_BRANCH=main dotfiles-doctor"; }
check "counted with the declared links" "$(misedoc | grep -c '1/2 present')"                                 "1"
check "absent mise link is named"       "$(misedoc | grep -c 'not linked: ~/.config/mise/config.toml')"      "1"
ln -s "$MISEREPO/.mise.toml" "$MISEHOME/.config/mise/config.toml"
check "installed mise link passes"      "$(misedoc | grep -c '2/2 declared links present')"                  "1"
# ...and being in the link list is what puts .mise.toml in the live set at all.
echo 'changed = true' >> "$MISEREPO/.mise.toml"
check "its drift is visible"            "$(misedoc | grep -c 'M .mise.toml')"                                "1"
git -C "$MISEREPO" checkout -q -- .mise.toml

echo
echo "=== a declared source that is not in the tree is checked by NOTHING ==="
# git exits 0 with empty output for a pathspec matching nothing, so a typo or a
# rename left un-propagated into install.conf.yaml silently NARROWS every check
# instead of failing one: `~/.zshrc: zshrcc` takes the most live file in the repo
# out of the drift check and still prints a green tick.
printf -- '- link:\n    ~/.gitconfig: gitconfigg\n' > "$MISEREPO/install.conf.yaml"
misedoc_rc() { zsh -c "source '$SYSTEM_SH'; HOME='$MISEHOME' DOTFILES_ROOT='$MISEREPO' DOTFILES_PIN_BRANCH=main dotfiles-doctor" >/dev/null 2>&1; echo $?; }
check "absent source reported" "$(misedoc | grep -c 'declared source(s) absent from this tree')" "1"
check "absent source named"    "$(misedoc | grep -c '[~]/.gitconfig → gitconfigg')"             "1"
check "absent source exits 1"  "$(misedoc_rc)"                                                   "1"
check "absent source: no tick" "$(misedoc | grep -c 'Live config is the reviewed config')"       "0"

echo
echo "=== a failing ✓ printf must not be counted as a ✗ ==="
# `cond && _doctor_ok … || _doctor_bad …` runs BOTH branches when the ✓ printf
# returns non-zero, so a check that PASSED increments the failure count and the
# doctor exits 1. ShellCheck names the idiom (SC2015) but never sees this file.
#
# The write must actually fail, and closing stdout is not enough: zsh's printf
# prints "write error: bad file descriptor" and still returns 0 there, so a
# `>&-` run reproduces nothing. /dev/full returns ENOSPC and a status of 1,
# which is the real-world case — a redirected run on a filesystem that filled
# up. Verified both ways against a copy with the old idiom restored.
# Its own pristine repo: $REPO is a commit behind by this point in the table
# (the --fetch rows put it there), and a doctor that legitimately exits 1 would
# make this row measure the fixture instead of the idiom.
CLEANREPO="$TMPROOT/cleanrepo"; CLEANHOME="$TMPROOT/cleanhome"
git init -q --bare -b main "$TMPROOT/cleanremote.git"
git init -q -b main "$CLEANREPO"
git -C "$CLEANREPO" config user.email t@example.com
git -C "$CLEANREPO" config user.name  Test
mkdir -p "$CLEANREPO/zsh" "$CLEANREPO/scripts"
printf -- '- link:\n    ~/.gitconfig: gitconfig\n' > "$CLEANREPO/install.conf.yaml"
printf '[user]\n\tname = Fixture\n' > "$CLEANREPO/gitconfig"
echo 'echo hi' > "$CLEANREPO/zsh/zshrc.company"
echo 'echo hi' > "$CLEANREPO/scripts/thing.sh"
git -C "$CLEANREPO" add -A >/dev/null && git -C "$CLEANREPO" commit -qm init
git -C "$CLEANREPO" remote add origin "$TMPROOT/cleanremote.git"
git -C "$CLEANREPO" push -q origin main && git -C "$CLEANREPO" fetch -q origin
mkdir -p "$CLEANHOME"; ln -s "$CLEANREPO/gitconfig" "$CLEANHOME/.gitconfig"
clean_rc() { zsh -c "source '$SYSTEM_SH'; HOME='$CLEANHOME' DOTFILES_ROOT='$CLEANREPO' DOTFILES_PIN_BRANCH=main dotfiles-doctor $1"; echo $?; }
# Assert the fixture before the behaviour: "exits 0 when writes fail" is also
# what a doctor that never ran at all would produce.
check "fixture is clean to begin with"     "$(clean_rc '>/dev/null 2>&1')" "0"
check "unwritable stdout is not a failure" "$(clean_rc '>/dev/full 2>/dev/null')" "0"

echo
echo "=== the doctor leaves nothing behind in the shell ==="
# The counters and the internals' result variables used to be globals, so four
# _D* variables persisted in every shell that ran the doctor (or merely started,
# for two of them), and a nested call clobbered the outer count.
leak() { zsh -c "source '$SYSTEM_SH'; HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' dotfiles-doctor >/dev/null 2>&1; print -r -- \"\${$1-unset}\""; }
for v in _DOCTOR_FAIL _DOCTOR_WARN _DOTFILES_HEAD _DOTFILES_VERDICT \
         _DOTFILES_UMASK_WANT _DOTFILES_UMASK_MODE; do
  check "no \$$v left behind" "$(leak "$v")" "unset"
done
check "no _D* left after the startup warning" \
      "$(zsh -c "source '$SYSTEM_SH'; DOTFILES_ROOT='$TMPROOT/br' _dotfiles_live_config_warn >/dev/null 2>&1; print -r -- \"\${_DOTFILES_VERDICT-unset}\"")" \
      "unset"

echo
echo "=== shared doctor reporting (dotfiles-doctor AND backup-doctor) ==="
# _doctor_ok/bad/warn/note/summary are shared by both doctors, and backup-doctor
# reaches them through its _backup_doctor_* names. Two things here had no
# coverage anywhere: the summary's wording and exit status (backup-doctor's own
# suite asserts printed findings, never the verdict), and the convention that
# each doctor declares the counters as locals. The counters are the CALLER's
# locals — zsh scopes locals dynamically — which is what keeps them out of every
# interactive shell, and it is exactly the kind of convention a comment cannot
# enforce: a doctor that forgets the declaration silently recreates the globals
# and its exit code becomes whatever the previous run left behind.
summary() { zsh -c "source '$SYSTEM_SH'; f() { local _DOCTOR_FAIL=$1 _DOCTOR_WARN=$2; _doctor_summary 'all good' 'the fix hint'; print -r -- \"rc=\$?\"; }; f" 2>&1; }

check "failures: both counts"   "$(summary 2 1 | grep -c '✗ 2 failure(s), 1 warning(s)')"   "1"
check "failures: fix hint"      "$(summary 2 1 | grep -c 'the fix hint')"                    "1"
check "failures: exit 1"        "$(summary 2 1 | grep -c 'rc=1')"                            "1"
check "warnings: no failures"   "$(summary 0 3 | grep -c '⚠ 3 warning(s), no failures')"     "1"
# A warning is not a failure: backup-doctor is wired into alerting, and a
# warning-only run turning non-zero would make every run look broken.
check "warnings: exit 0"        "$(summary 0 3 | grep -c 'rc=0')"                            "1"
check "clean: all-clear text"   "$(summary 0 0 | grep -c '✓ all good')"                      "1"
check "clean: no fix hint"      "$(summary 0 0 | grep -c 'the fix hint')"                    "0"
check "clean: exit 0"           "$(summary 0 0 | grep -c 'rc=0')"                            "1"

# The mechanism the whole design rests on: a callee's increment reaches the
# caller's declaration, and does not outlive it.
mech() { zsh -c "source '$SYSTEM_SH'; f() { local _DOCTOR_FAIL=0 _DOCTOR_WARN=0; _doctor_bad b >/dev/null; _doctor_warn w >/dev/null; _doctor_ok o >/dev/null; _doctor_note n >/dev/null; print -r -- \"in=\$_DOCTOR_FAIL/\$_DOCTOR_WARN\"; }; f; print -r -- \"out=\${_DOCTOR_FAIL-unset}\"" 2>&1; }
check "callee writes caller local" "$(mech | grep -c 'in=1/1')"    "1"
check "✓ and · count as neither"   "$(mech | grep -c 'in=1/1')"    "1"
check "counters do not outlive it" "$(mech | grep -c 'out=unset')" "1"

# backup-doctor's emitters are now thin wrappers; if the delegation breaks, its
# findings still print and its verdict silently becomes "all checks passed".
wrap() { zsh -c "source '$SYSTEM_SH'; f() { local _DOCTOR_FAIL=0 _DOCTOR_WARN=0; _backup_doctor_bad b >/dev/null; _backup_doctor_warn w >/dev/null; _backup_doctor_ok o >/dev/null; print -r -- \"\$_DOCTOR_FAIL/\$_DOCTOR_WARN\"; }; f" 2>&1; }
check "backup wrappers still count" "$(wrap)" "1/1"

# Over EVERY doctor entry point, found by asking which functions call
# _doctor_summary rather than from a hardcoded list — so a third doctor is
# covered the moment it is written, which is the only way this convention stays
# true.
# Every functions module, not just system.sh: the emitters live here but
# doctors do not have to, and gh-doctor (zsh/functions/github.sh) is the first
# that does not — the sweep has to find it or the convention holds only for the
# doctors that happen to share a file with it.
ALLFUNCS="$(printf "source '%s'; " "$DOTFILES"/zsh/functions/*.sh)"
doctors="$(zsh -c "$ALLFUNCS for f in \${(k)functions}; do [[ \"\${functions[\$f]}\" == *_doctor_summary* ]] && print -r -- \$f; done" | sort)"
[[ -n "$doctors" ]] || fatal "no functions call _doctor_summary — were the emitters renamed?"
check "dotfiles-doctor is a doctor" "$(printf '%s\n' "$doctors" | grep -cx 'dotfiles-doctor')" "1"
check "backup-doctor is a doctor"   "$(printf '%s\n' "$doctors" | grep -cx 'backup-doctor')"   "1"
check "gh-doctor is a doctor"       "$(printf '%s\n' "$doctors" | grep -cx 'gh-doctor')"       "1"
while IFS= read -r d; do
  [[ -n "$d" ]] || continue
  body="$(zsh -c "$ALLFUNCS print -r -- \"\${functions[$d]}\"")"
  case "$body" in
    *"local _DOCTOR_FAIL=0 _DOCTOR_WARN=0"*|*"local _DOCTOR_FAIL"*"local _DOCTOR_WARN"*)
      ok "$d declares its own counters" ;;
    *)
      bad "$d calls _doctor_summary without declaring _DOCTOR_FAIL/_DOCTOR_WARN local — the globals are back" ;;
  esac
done <<< "$doctors"

echo
echo "=== dotfiles-work ==="
WTBASE="$TMPROOT/worktrees"
git -C "$REPO" checkout -q main
work()    { zrun "HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' DOTFILES_PIN_BRANCH=main DOTFILES_WORKTREES='$WTBASE' dotfiles-work $1"; }
work_rc() { zsh -c "source '$SYSTEM_SH'; HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' DOTFILES_PIN_BRANCH=main DOTFILES_WORKTREES='$WTBASE' dotfiles-work $1" >/dev/null 2>&1; echo $?; }

# A leftover directory is not a worktree — `rm -rf` without `git worktree
# prune`, a half-failed `worktree remove`, or a name collision all leave one.
# The previous version cd'd in, printed "Entered existing worktree" with an
# empty branch and returned 0, so the next hour of edits went into a directory
# git knew nothing about.
mkdir -p "$WTBASE/stale-thing"
echo 'work in progress' > "$WTBASE/stale-thing/notes.txt"
check "stale dir refused"       "$(work stale-thing | grep -c 'is not a git worktree')" "1"
check "stale dir exits 1"       "$(work_rc stale-thing)"                                "1"
check "stale dir not claimed"   "$(work stale-thing | grep -c 'Entered existing')"      "0"

check "new worktree created"    "$(work feat/new | grep -c 'Worktree:')"                "1"
check "worktree dir exists"     "$([[ -d "$WTBASE/feat-new" ]] && echo yes)"            "yes"
check "worktree on the branch"  "$(git -C "$WTBASE/feat-new" rev-parse --abbrev-ref HEAD)" "feat/new"
check "primary checkout unmoved" "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"        "main"
# --no-track is load-bearing: with origin/main as upstream, this repo's own
# push.default=simple makes `git push` fail and suggest `git push origin
# HEAD:main` — pushing unreviewed commits straight onto the protected branch.
check "new branch has no upstream" "$(git -C "$WTBASE/feat-new" config --get branch.feat/new.remote)" ""
check "no upstream merge ref"      "$(git -C "$WTBASE/feat-new" config --get branch.feat/new.merge)"  ""
check "re-entry is recognised"     "$(work feat/new | grep -c 'Entered existing worktree')"           "1"
check "re-entry exits 0"           "$(work_rc feat/new)"                                              "0"

echo
echo "=== dotfiles-work --remove: a worktree ./install has run in ==="
# install:76 runs `git submodule update --init --recursive dotbot` in whichever
# checkout it is run from — in a worktree that takes the
# DOTFILES_ALLOW_WORKTREE_INSTALL=1 override install:56-72 otherwise refuses, or
# a hand-run `git submodule update`, which is what installed_wt() below does —
# so a worktree anyone has installed from carries a populated dotbot submodule,
# and `git worktree remove` refuses those outright:
#   fatal: working trees containing submodules cannot be moved or removed
# The documented cleanup command therefore worked only on worktrees nobody had
# installed from (2026-09-08: of two removed that day, the one ./install had run
# in refused). `--force` is the fix, and it discards git's own dirty-tree check,
# so the function performs that check itself — with the command git runs for it,
# `status --porcelain --ignore-submodules=none` — and refuses when it is
# non-empty OR when it cannot be read: a state that cannot be inspected is not a
# clean one.
#
# `git submodule deinit` first, then a plain remove, was the alternative and does
# not work: git refuses on the mere existence of .git/worktrees/<id>/modules,
# which deinit keeps — and deinit run inside a worktree removes
# submodule.<name>.* from the SHARED config, unregistering the primary
# checkout's copy too. A row below asserts the primary's registration survives.
#
# A separate fixture repo with a REAL submodule: every row here is unfailable
# unless the worktree actually carries a populated one, so the fixture proves
# that git refuses the plain remove before any row runs.
SUBSRC="$TMPROOT/subsrc"; SUBREMOTE="$TMPROOT/subremote.git"; SUBREPO="$TMPROOT/subrepo"
SUBWT="$TMPROOT/subworktrees"
git init -q -b main "$SUBSRC"
git -C "$SUBSRC" -c user.email=t@example.com -c user.name=Test commit -q --allow-empty -m subinit
git init -q --bare -b main "$SUBREMOTE"
git init -q -b main "$SUBREPO"
git -C "$SUBREPO" config user.email t@example.com
git -C "$SUBREPO" config user.name  Test
echo 'tracked' > "$SUBREPO/file.txt"
git -C "$SUBREPO" add -A >/dev/null
git -C "$SUBREPO" commit -qm init
# file:// submodule clones are refused by default since git 2.38.1
# (CVE-2022-39253), so every place the fixture clones one has to allow them.
git -C "$SUBREPO" -c protocol.file.allow=always submodule add -q "$SUBSRC" dotbot >/dev/null 2>&1 \
  || fatal "fixture: could not add the dotbot submodule"
git -C "$SUBREPO" commit -qm addsub
git -C "$SUBREPO" remote add origin "$SUBREMOTE"
git -C "$SUBREPO" push -q origin main
git -C "$SUBREPO" fetch -q origin

# One run, both answers kept: a second run for the exit code would see a
# worktree that the first one already removed.
subwork_run() {
  OUT="$(zsh -c "source '$SYSTEM_SH'; HOME='$FAKEHOME' DOTFILES_ROOT='$SUBREPO' DOTFILES_PIN_BRANCH='${2:-main}' DOTFILES_WORKTREES='$SUBWT' dotfiles-work $1" 2>&1)"
  RC=$?
}
# A worktree made through the function, with its submodule populated the way
# install:76 populates it. Asserted, not assumed: a fixture that silently fails
# to populate it makes every row below pass with the fix reverted.
installed_wt() {
  subwork_run "$1"
  (( RC == 0 )) || fatal "fixture: dotfiles-work $1 failed: $OUT"
  git -C "$SUBWT/${1//\//-}" -c protocol.file.allow=always submodule update --init --recursive dotbot >/dev/null 2>&1
  [[ -f "$SUBWT/${1//\//-}/dotbot/.git" ]] || fatal "fixture: submodule not populated in $SUBWT/${1//\//-}"
}
branch_state() { git -C "$SUBREPO" show-ref --verify --quiet "refs/heads/$1" && echo kept || echo deleted; }
dir_state()    { [[ -e "$SUBWT/$1" ]] && echo present || echo gone; }

# The precondition every row rests on: git itself refuses this fixture. If it did
# not, the rows would pass whether or not --force is passed.
installed_wt probe/plain
plain_out="$(git -C "$SUBREPO" worktree remove "$SUBWT/probe-plain" 2>&1)"; plain_rc=$?
if (( plain_rc == 0 )) || [[ "$plain_out" != *"containing submodules"* ]]; then
  fatal "fixture: git did not refuse a plain 'worktree remove' on the populated submodule (rc=$plain_rc: $plain_out) — the rows below cannot fail"
fi

subwork_run '--remove probe/plain'
check "populated submodule: removed (rc 0)" "$RC"                                                     "0"
check "populated submodule: dir gone"       "$(dir_state probe-plain)"                                 "gone"
check "populated submodule: unlisted"       "$(git -C "$SUBREPO" worktree list | grep -c 'probe-plain')" "0"
check "populated submodule: primary unmoved" "$(git -C "$SUBREPO" rev-parse --abbrev-ref HEAD)"        "main"
check "primary submodule still registered"  "$(git -C "$SUBREPO" config --get submodule.dotbot.url >/dev/null && echo yes || echo no)" "yes"
# Its tree is origin/main's, so nothing on the branch is unlanded: deleted, and
# the reason stated.
check "landed branch deleted"               "$(branch_state probe/plain)"                              "deleted"
check "landed branch: says why"             "$(printf '%s\n' "$OUT" | grep -c 'identical to origin/main')" "1"

# The protection --force discards, performed by the function instead. Both kinds
# of change git's own check refuses on: a modified tracked file and an untracked one.
installed_wt probe/dirty
echo 'unsaved work' >  "$SUBWT/probe-dirty/notes.txt"
echo 'edited'       >> "$SUBWT/probe-dirty/file.txt"
subwork_run '--remove probe/dirty'
check "dirty worktree refused (rc 1)"       "$RC"                                                     "1"
check "dirty worktree: dir kept"            "$(dir_state probe-dirty)"                                 "present"
check "dirty worktree: untracked file kept" "$(cat "$SUBWT/probe-dirty/notes.txt" 2>/dev/null)"        "unsaved work"
check "dirty worktree: names the untracked" "$(printf '%s\n' "$OUT" | grep -c 'notes.txt')"            "1"
check "dirty worktree: names the modified"  "$(printf '%s\n' "$OUT" | grep -c 'file.txt')"             "1"
check "dirty worktree: names the override"  "$(printf '%s\n' "$OUT" | grep -c -- '--remove --force probe/dirty')" "1"
check "dirty worktree: branch kept"         "$(branch_state probe/dirty)"                              "kept"
# The override the refusal names has to work — a remedy that does not remedy is
# the redactor lesson in "Keeping secrets out of transcripts".
subwork_run '--remove --force probe/dirty'
check "--force override removes it"         "$RC"                                                     "0"
check "--force override: dir gone"          "$(dir_state probe-dirty)"                                 "gone"

# A directory at the path that git knows nothing about. Its state cannot be read,
# and an unreadable state must not be forced through: the answer is a refusal
# that says so, never `worktree remove --force` on whatever is there.
mkdir -p "$SUBWT/probe-stale"; echo 'keep me' > "$SUBWT/probe-stale/keep.txt"
subwork_run '--remove probe/stale'
check "unreadable state refused (rc 1)"     "$RC"                                                     "1"
check "unreadable state: dir kept"          "$(cat "$SUBWT/probe-stale/keep.txt" 2>/dev/null)"         "keep me"
check "unreadable state: says so"           "$(printf '%s\n' "$OUT" | grep -c 'refusing to force')"    "1"
check "unreadable state: says untracked"    "$(printf '%s\n' "$OUT" | grep -c 'is not a worktree of')"  "1"
check "unreadable state: names the cleanup" "$(printf '%s\n' "$OUT" | grep -c 'worktree prune')"       "1"

# A REGISTERED worktree whose state cannot be read — a half-failed removal, or a
# .git file something overwrote. Same refusal, for the same reason, and this is
# the row that reaches the status-failure branch: the unregistered directory
# above never runs `git status` at all.
installed_wt probe/broken
echo 'garbage' > "$SUBWT/probe-broken/.git"
subwork_run '--remove probe/broken'
check "unreadable registered: refused (rc 1)" "$RC"                                                   "1"
check "unreadable registered: dir kept"     "$(dir_state probe-broken)"                                "present"
check "unreadable registered: says so"      "$(printf '%s\n' "$OUT" | grep -c 'cannot read the state of')" "1"
check "unreadable registered: not blamed on the dir" "$(printf '%s\n' "$OUT" | grep -c 'is not a worktree of')" "0"

# A registered worktree whose directory has been rm -rf'd — the leftover the
# create path warns about. Nothing is left to protect, and git runs neither its
# submodule nor its cleanliness check on a directory that is not there, so this
# passed BEFORE the fix. It is here because the state check the fix adds must not
# refuse a directory it cannot find: the entry is pruned, and the branch handled.
installed_wt probe/gone
rm -rf "$SUBWT/probe-gone"
subwork_run '--remove probe/gone'
check "vanished dir: entry pruned (rc 0)"   "$RC"                                                     "0"
check "vanished dir: unlisted"              "$(git -C "$SUBREPO" worktree list | grep -c 'probe-gone')" "0"

# One --force, never two: a LOCKED worktree needs `-f -f`, and the lock is the
# one protection --force leaves in place. The branch is untouched when the
# removal did not happen.
installed_wt probe/locked
git -C "$SUBREPO" worktree lock "$SUBWT/probe-locked"
subwork_run '--remove probe/locked'
check "locked worktree still refused"       "$([[ $RC -ne 0 ]] && echo refused || echo removed)"       "refused"
check "locked worktree: dir kept"           "$(dir_state probe-locked)"                                 "present"
check "locked worktree: branch kept"        "$(branch_state probe/locked)"                              "kept"
git -C "$SUBREPO" worktree unlock "$SUBWT/probe-locked"

# A branch with unlanded commits is kept, and the hint says -D — a squash-merged
# branch is not an ancestor of main, so -d calls a fully landed branch unmerged.
installed_wt probe/ahead
echo 'new' > "$SUBWT/probe-ahead/new.txt"
git -C "$SUBWT/probe-ahead" add new.txt
git -C "$SUBWT/probe-ahead" commit -qm ahead
subwork_run '--remove probe/ahead'
check "unlanded branch: worktree removed"   "$RC"                                                     "0"
check "unlanded branch kept"                "$(branch_state probe/ahead)"                              "kept"
check "unlanded branch: -D hint"            "$(printf '%s\n' "$OUT" | grep -c 'branch -D probe/ahead')" "1"
check "unlanded branch: never -d"           "$(printf '%s\n' "$OUT" | grep -c 'branch -d ')"           "0"

# The squash shape itself: main carries the branch's content in a commit that is
# NOT the branch's, so `merge-base --is-ancestor` says unmerged and `branch -d`
# refuses — while `git diff <branch> origin/main` is empty. Only -D deletes it.
installed_wt probe/squashed
echo 'squashed content' > "$SUBWT/probe-squashed/sq.txt"
git -C "$SUBWT/probe-squashed" add sq.txt
git -C "$SUBWT/probe-squashed" commit -qm 'feature commit'
echo 'squashed content' > "$SUBREPO/sq.txt"
git -C "$SUBREPO" add sq.txt
git -C "$SUBREPO" commit -qm 'Squash merge of probe/squashed'
git -C "$SUBREPO" push -q origin main
git -C "$SUBREPO" fetch -q origin
git -C "$SUBREPO" merge-base --is-ancestor probe/squashed origin/main \
  && fatal "fixture: probe/squashed is an ancestor of origin/main — this is not the squash shape"
git -C "$SUBREPO" diff --quiet probe/squashed origin/main \
  || fatal "fixture: probe/squashed's tree differs from origin/main — this is not the squash shape"
subwork_run '--remove probe/squashed'
check "squash-merged: worktree removed"     "$RC"                                                     "0"
check "squash-merged branch deleted"        "$(branch_state probe/squashed)"                           "deleted"

# No origin/<pin> to compare with: a comparison that cannot run is not "landed".
installed_wt probe/nopin
subwork_run '--remove probe/nopin' nosuch
check "no origin/<pin>: worktree removed"   "$RC"                                                     "0"
check "no origin/<pin>: branch kept"        "$(branch_state probe/nopin)"                              "kept"
check "no origin/<pin>: says could not compare" "$(printf '%s\n' "$OUT" | grep -c 'could not compare')" "1"

# A detached worktree has no branch to delete, and must not be reported as if it had.
git -C "$SUBREPO" worktree add -q --detach "$SUBWT/probe-detached" origin/main 2>/dev/null
git -C "$SUBWT/probe-detached" -c protocol.file.allow=always submodule update --init --recursive dotbot >/dev/null 2>&1
[[ -f "$SUBWT/probe-detached/dotbot/.git" ]] || fatal "fixture: submodule not populated in $SUBWT/probe-detached"
subwork_run '--remove probe/detached'
check "detached worktree: removed"          "$RC"                                                     "0"
check "detached worktree: no branch action" "$(printf '%s\n' "$OUT" | grep -c 'branch -D')"            "0"
check "detached worktree: says detached"    "$(printf '%s\n' "$OUT" | grep -c 'detached HEAD')"         "1"

# The create path cd's INTO the worktree, so the shell that removes one is often
# standing in it — and a shell left in a deleted directory fails every relative
# path from then on. Removing from inside moves the shell to the primary checkout.
installed_wt probe/inside
check "removed from inside: shell moved out" \
      "$(zsh -c "cd '$SUBWT/probe-inside' && source '$SYSTEM_SH' && HOME='$FAKEHOME' DOTFILES_ROOT='$SUBREPO' DOTFILES_PIN_BRANCH=main DOTFILES_WORKTREES='$SUBWT' dotfiles-work --remove probe/inside >/dev/null 2>&1; print -r -- \"\${PWD:A}\"")" \
      "$(cd "$SUBREPO" && pwd -P)"
check "removed from inside: dir gone"       "$(dir_state probe-inside)"                                "gone"

# A git that cannot read the repo answers every question with silence, and the
# registry lookup's silence must not be taken for "not a worktree" — that message
# blames the directory for a fault in the repo, and sends the reader to rm -rf it.
# The directory EXISTS here on purpose: that is the only state in which the
# swallowed failure produces the wrong message, so without it the third row
# passes with the fix reverted (found by mutation).
mkdir -p "$SUBWT/probe-whatever"
OUT="$(zsh -c "source '$SYSTEM_SH'; HOME='$FAKEHOME' DOTFILES_ROOT='$TMPROOT/none' DOTFILES_PIN_BRANCH=main DOTFILES_WORKTREES='$SUBWT' dotfiles-work --remove probe/whatever" 2>&1)"; RC=$?
check "unreadable repo: refused (rc 1)"     "$RC"                                                     "1"
check "unreadable repo: names git"          "$(printf '%s\n' "$OUT" | grep -c 'could not list the worktrees')" "1"
check "unreadable repo: not blamed on the dir" "$(printf '%s\n' "$OUT" | grep -c 'is not a worktree of')" "0"

# stderr is not a dirty file. `git status` can warn with exit 0, and a capture
# that folds stderr into the listing would refuse a clean worktree over a
# warning — so the check reads stdout only. Injected through a PATH stub that
# wraps the real git, the way the systemctl and herdr suites stub theirs.
REALGIT="$(command -v git)"
STUBGIT="$TMPROOT/stubgit"; mkdir -p "$STUBGIT"
cat > "$STUBGIT/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" status "*) echo 'warning: injected stderr noise' >&2 ;; esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$STUBGIT/git"
installed_wt probe/noisy
OUT="$(zsh -c "PATH='$STUBGIT:$PATH'; source '$SYSTEM_SH'; HOME='$FAKEHOME' DOTFILES_ROOT='$SUBREPO' DOTFILES_PIN_BRANCH=main DOTFILES_WORKTREES='$SUBWT' dotfiles-work --remove probe/noisy" 2>&1)"; RC=$?
check "stderr warning is not dirt: removed" "$RC"                                                     "0"
check "stderr warning is not dirt: dir gone" "$(dir_state probe-noisy)"                               "gone"
check "stderr warning is not dirt: not listed" "$(printf '%s\n' "$OUT" | grep -c 'uncommitted changes')" "0"
check "stderr warning is not dirt: surfaced" "$(printf '%s\n' "$OUT" | grep -c 'injected stderr noise')" "1"

# `status.showUntrackedFiles = no` — a standard large-repo tweak, and settable
# from this repo's own ~/.gitconfig.local — makes `status --porcelain` print
# NOTHING for an untracked file. git's own check has that hole; this one must
# not, so the flag is passed explicitly. Set on the fixture's shared config,
# which is where a worktree reads it, and unset before the rows are judged.
git -C "$SUBREPO" config status.showUntrackedFiles no
installed_wt probe/hidden
echo 'invisible work' > "$SUBWT/probe-hidden/hidden.txt"
subwork_run '--remove probe/hidden'
git -C "$SUBREPO" config --unset status.showUntrackedFiles
check "hidden untracked: refused (rc 1)"    "$RC"                                                     "1"
check "hidden untracked: file kept"         "$(cat "$SUBWT/probe-hidden/hidden.txt" 2>/dev/null)"     "invisible work"
check "hidden untracked: named"             "$(printf '%s\n' "$OUT" | grep -c 'hidden.txt')"          "1"

# `dotfiles-work main` is allowed when the primary is off-pin (the create path
# takes any existing branch), and its tree is origin/main's by definition — so
# `--remove main` deleted local main. The pin branch is never deleted, whatever
# the diff says.
git -C "$SUBREPO" checkout -q -b side
installed_wt main
subwork_run '--remove main'
# Read the branch's state BEFORE moving the primary back: `git checkout main`
# with no local main DWIMs one back into existence from origin/main, and a row
# that read the state afterwards passed with the guard absent (found by mutation).
main_after="$(branch_state main)"
git -C "$SUBREPO" checkout -q main
check "pin branch: worktree removed"        "$RC"                                                     "0"
check "pin branch never deleted"            "$main_after"                                             "kept"
check "pin branch: says why"                "$(printf '%s\n' "$OUT" | grep -c 'pin branch')"          "1"

# The worktrees this fix makes removable are exactly the ones an install has run
# in — and an install run there re-pointed every managed symlink INTO it.
# Removing it would leave the live rc file dangling, and the next shell would
# source nothing, with none of the doctors present to say so. The sentinel is
# the rc symlink in HOME, resolved the forkless way the startup guard resolves
# it. --force does NOT override this one: the remedy is a non-destructive re-run
# of ./install, and there is no state in which a dangling live config is what
# anyone wants. A separate HOME keeps the link away from every other row.
LIVEHOME="$TMPROOT/livehome"; mkdir -p "$LIVEHOME"
installed_wt probe/live
ln -s "$SUBWT/probe-live/file.txt" "$LIVEHOME/.zshrc"
live_run() { OUT="$(zsh -c "source '$SYSTEM_SH'; HOME='$LIVEHOME' DOTFILES_ROOT='$SUBREPO' DOTFILES_PIN_BRANCH=main DOTFILES_WORKTREES='$SUBWT' dotfiles-work $1" 2>&1)"; RC=$?; }
live_run '--remove probe/live'
check "live config inside: refused (rc 1)"  "$RC"                                                     "1"
check "live config inside: dir kept"        "$(dir_state probe-live)"                                  "present"
check "live config inside: names ./install" "$(printf '%s\n' "$OUT" | grep -c './install')"           "1"
live_run '--remove --force probe/live'
check "live config inside: --force does not override" "$RC"                                           "1"
check "live config inside: still present"   "$(dir_state probe-live)"                                  "present"
rm "$LIVEHOME/.zshrc"
live_run '--remove probe/live'
check "live config elsewhere: removed"      "$RC"                                                     "0"

# Directory names flatten / to -, so `feat/y` and `feat-y` share one. The remove
# path acts on the branch the registry records, and — like the create path — has
# to say so when that is not the name it was given.
installed_wt feat/y
subwork_run '--remove feat-y'
check "flattened name: removed"             "$RC"                                                     "0"
check "flattened name: notes the branch"    "$(printf '%s\n' "$OUT" | grep -c "is on 'feat/y', not 'feat-y'")" "1"

# When git refuses the -D, its reason is the actionable part. A
# reference-transaction hook that aborts every ref update is the hermetic way to
# make it refuse — installed AFTER the worktree exists, because `worktree add -b`
# is a ref update too, and with core.hooksPath set on the fixture because a
# global hooksPath (this machine has one) would otherwise hide the hook. The
# hook prints its own marker: git relays a hook's stderr whatever version it is,
# while git's own wording for the abort changed between 2.53 and 2.55 and made
# this row red on CI when it matched that instead.
installed_wt probe/hookfail
HOOKS="$TMPROOT/hooks"; mkdir -p "$HOOKS"
cat > "$HOOKS/reference-transaction" <<'HOOK'
#!/bin/sh
if [ "$1" = prepared ]; then
  echo 'reference-transaction hook: deletion refused for this test' >&2
  exit 1
fi
exit 0
HOOK
chmod +x "$HOOKS/reference-transaction"
git -C "$SUBREPO" config core.hooksPath "$HOOKS"
subwork_run '--remove probe/hookfail'
git -C "$SUBREPO" config --unset core.hooksPath
check "-D refused by git: worktree removed" "$RC"                                                     "0"
check "-D refused by git: branch kept"      "$(branch_state probe/hookfail)"                           "kept"
check "-D refused by git: said so"          "$(printf '%s\n' "$OUT" | grep -c 'would not delete it')"  "1"
check "-D refused by git: reason shown"     "$(printf '%s\n' "$OUT" | grep -c 'deletion refused for this test')" "1"

# Argument parsing, and the listing cap.
subwork_run '--remove --bogus probe/x'
check "--remove: unknown option refused"    "$RC"                                                     "1"
check "--remove: unknown option named"      "$(printf '%s\n' "$OUT" | grep -c "unknown option '--bogus'")" "1"
subwork_run '--remove a b'
check "--remove: two targets refused"       "$RC"                                                     "1"
installed_wt probe/many
for i in $(seq 1 12); do echo x > "$SUBWT/probe-many/u$i.txt"; done
subwork_run '--remove probe/many'
check "many dirty files: refused"           "$RC"                                                     "1"
check "many dirty files: listing capped"    "$(printf '%s\n' "$OUT" | grep -c 'and 2 more')"          "1"

# The sentinel was ~/.zshrc alone, and `./install --herdr` never links ~/.zshrc:
# it links five herdr destinations, among them the systemd unit that owns every
# agent session — so a herdr-shape install from a worktree was removed with rc 0
# and left the unit dangling (found by the local reviewer, reproduced). The check
# enumerates the declared links of BOTH confs instead, read from the primary and
# from the worktree, with the mise link and ~/.zshrc as a floor. The fixture repo
# gains a conf declaring two herdr-shape links; ~/.zshrc stays on the primary.
mkdir -p "$SUBREPO/config/herdr" "$SUBREPO/systemd"
echo 'herdr'  > "$SUBREPO/config/herdr/config.toml"
echo '[Unit]' > "$SUBREPO/systemd/herdr-server.service"
cat > "$SUBREPO/install.conf.yaml" <<'YAML'
- link:
    ~/.config/herdr/config.toml: config/herdr/config.toml
    ~/.config/systemd/user/herdr-server.service: systemd/herdr-server.service
YAML
git -C "$SUBREPO" add -A >/dev/null
git -C "$SUBREPO" commit -qm 'declare herdr links'
git -C "$SUBREPO" push -q origin main
git -C "$SUBREPO" fetch -q origin
HERDRHOME="$TMPROOT/herdrhome"; mkdir -p "$HERDRHOME/.config/herdr" "$HERDRHOME/.config/systemd/user"
installed_wt probe/herdr
ln -s "$SUBREPO/file.txt" "$HERDRHOME/.zshrc"
ln -s "$SUBWT/probe-herdr/config/herdr/config.toml"          "$HERDRHOME/.config/herdr/config.toml"
ln -s "$SUBWT/probe-herdr/systemd/herdr-server.service"      "$HERDRHOME/.config/systemd/user/herdr-server.service"
herdr_run() { OUT="$(zsh -c "source '$SYSTEM_SH'; HOME='$HERDRHOME' DOTFILES_ROOT='$SUBREPO' DOTFILES_PIN_BRANCH=main DOTFILES_WORKTREES='$SUBWT' dotfiles-work $1" 2>&1)"; RC=$?; }
herdr_run '--remove probe/herdr'
check "herdr-shape links inside: refused (rc 1)" "$RC"                                                "1"
check "herdr-shape links inside: dir kept"  "$(dir_state probe-herdr)"                                 "present"
check "herdr-shape links inside: names the unit" "$(printf '%s\n' "$OUT" | grep -c 'herdr-server.service')" "1"
check "herdr-shape links inside: unit not dangling" "$([[ -e "$HERDRHOME/.config/systemd/user/herdr-server.service" ]] && echo resolves || echo dangling)" "resolves"
rm "$HERDRHOME/.config/herdr/config.toml" "$HERDRHOME/.config/systemd/user/herdr-server.service"
herdr_run '--remove probe/herdr'
check "herdr-shape links elsewhere: removed" "$RC"                                                    "0"

# git's own check_clean_worktree pins GIT_DIR=<wt>/.git and GIT_WORK_TREE=<wt>. A
# plain `git -C <wt>` discovers UPWARD when the gitfile is gone, and under an
# ancestor repo that ignores everything it reads THAT repo as clean — so --force
# reached git for a directory whose state was never read. The ancestor repo is
# created here, LAST, so that no other row's worktree sits under one.
installed_wt probe/orphan
echo 'orphaned work' > "$SUBWT/probe-orphan/orphan.txt"
rm "$SUBWT/probe-orphan/.git"
git init -q "$SUBWT"
echo '*' > "$SUBWT/.gitignore"
subwork_run '--remove probe/orphan'
check "gitfile gone under a repo: refused (rc 1)" "$RC"                                               "1"
check "gitfile gone under a repo: file kept" "$(cat "$SUBWT/probe-orphan/orphan.txt" 2>/dev/null)"    "orphaned work"
check "gitfile gone under a repo: says unreadable" "$(printf '%s\n' "$OUT" | grep -c 'cannot read the state of')" "1"

echo
echo "=== ./install refuses a worktree — and ONLY a worktree ==="
# The refusal is the first thing the script does, so a fixture with no dotbot
# submodule fails right after it either way: these rows read the MESSAGE, not the
# exit code. `[[ -f .git ]]` was the old test, and a --separate-git-dir clone and
# a submodule both have a .git FILE — they got this refusal on every run, with
# only an env var framed as "deploy this worktree" to escape it.
try_install() { ( cd "$1" && cp "$DOTFILES/install" . && bash ./install 2>&1 ); }
check "refuses a linked worktree"   "$(try_install "$TMPROOT/realwt" | grep -c 'Refusing to install from a git worktree')" "1"
check "allows --separate-git-dir"   "$(try_install "$SEP"            | grep -c 'Refusing to install from a git worktree')" "0"
check "allows an ordinary checkout" "$(try_install "$PRIMARY"        | grep -c 'Refusing to install from a git worktree')" "0"
check "override still escapes it" \
      "$( ( cd "$TMPROOT/realwt" && DOTFILES_ALLOW_WORKTREE_INSTALL=1 bash ./install 2>&1 ) | grep -c 'Refusing to install' )" "0"

echo
echo "=== the startup warning fires once per SHELL, not once per source ==="
# The hook unhooks itself, but re-sourcing zshrc re-defined and re-armed it, so
# `zshreload` / `source ~/.zshrc` — the edit loop CLAUDE.md documents for testing
# config changes — reprinted the three-line warning every single time. A guard
# that repeats itself on every reload is one people learn to silence, which is
# the same failure the deferral to the first prompt exists to avoid.
GUARDSNIP="$TMPROOT/guardsnip.zsh"
sed -n '/^# Once per SHELL/,/^fi$/p' "$DOTFILES/zshrc" > "$GUARDSNIP"
grep -q '_dotfiles_guard_precmd' "$GUARDSNIP" || fatal "could not extract the guard hook from $DOTFILES/zshrc"
# $1 is whatever happens AFTER the first prompt has already been drawn.
hookruns() {
  zsh -c "
    source '$SYSTEM_SH'
    HOME='$WARNHOME'; DOTFILES_ROOT='$TMPROOT/br'; DOTFILES_PIN_BRANCH=main
    autoload -Uz add-zsh-hook
    prompt() { local f; for f in \$precmd_functions; do \$f; done }
    source '$GUARDSNIP'; prompt
    $1
  " 2>&1 | grep -c 'live config is branch'
}
check "first prompt warns once"     "$(hookruns '')"                             "1"
check "later prompts stay quiet"    "$(hookruns 'prompt; prompt')"               "1"
check "a reload does not re-arm it" "$(hookruns "source '$GUARDSNIP'; prompt")"  "1"
check "no dead hook left in the table" \
      "$(zsh -c "
          source '$SYSTEM_SH'
          HOME='$WARNHOME'; DOTFILES_ROOT='$TMPROOT/br'; DOTFILES_PIN_BRANCH=main
          autoload -Uz add-zsh-hook
          source '$GUARDSNIP'
          { for f in \$precmd_functions; do \$f; done } >/dev/null 2>&1
          print -r -- \$+functions[_dotfiles_guard_precmd]")" "0"

echo
echo "=== _dotfiles_umask_guard: tighten only while the group is really shared ==="
# Ubuntu's pam_umask gives 002 whenever the login group is named after the user,
# on the reasoning that its permissions are then yours alone — and dev-setup
# breaks that by adding a service account to the group. Every row is a state
# where getting it wrong is invisible: too loose leaves $HOME group-writable by
# another account, too tight silently breaks workspace sharing on the hosts
# where the grant is real.
GRPDIR="$TMPROOT/groups"; mkdir -p "$GRPDIR"
printf 'root:x:0:\ntester:x:%s:\nsvc:x:242:tester\n'  "$(id -g)" > "$GRPDIR/private"
printf 'root:x:0:\ntester:x:%s:%s\n'  "$(id -g)" "$(id -un)"      > "$GRPDIR/selfonly"
printf 'root:x:0:\ntester:x:%s:svc,other\n' "$(id -g)"            > "$GRPDIR/shared"
printf 'root:x:0:\nsomethingelse:x:64999:\n'                      > "$GRPDIR/nogroup"
umaskrun() {  # umaskrun <env-assignments>  -> "<rc> <umask> <why>"
  zsh -c "umask 002; source '$SYSTEM_SH'
          $1 _dotfiles_umask_guard; rc=\$?
          print -r -- \"\$rc \$(umask) \$_DOTFILES_UMASK_WHY\"" 2>&1
}
check "shared group tightens to 022" \
      "$(umaskrun "DOTFILES_GROUP_FILE=$GRPDIR/shared" | cut -d' ' -f1,2)" "0 022"
check "...and names who else is in it" \
      "$(umaskrun "DOTFILES_GROUP_FILE=$GRPDIR/shared" | grep -c 'svc, other')" "1"
# The whole point of gating on the condition: once `gpasswd -d` has run, the
# guard must stop firing on its own rather than needing a second edit.
check "private group is left alone" \
      "$(umaskrun "DOTFILES_GROUP_FILE=$GRPDIR/private" | cut -d' ' -f1,2)" "0 002"
# Being listed in your own group is not sharing.
check "self-membership is not sharing" \
      "$(umaskrun "DOTFILES_GROUP_FILE=$GRPDIR/selfonly" | cut -d' ' -f1,2)" "0 002"
# "Could not determine" must not pick a side: tightening breaks sharing that may
# be load-bearing, relaxing recreates the exposure. Both report non-zero.
check "no entry for our gid: unchanged" \
      "$(umaskrun "DOTFILES_GROUP_FILE=$GRPDIR/nogroup" | cut -d' ' -f1,2)" "1 002"
check "...and says why"  "$(umaskrun "DOTFILES_GROUP_FILE=$GRPDIR/nogroup" | grep -c 'no .* entry for gid')" "1"
check "unreadable group file: unchanged" \
      "$(umaskrun "DOTFILES_GROUP_FILE=$TMPROOT/no-such-group" | cut -d' ' -f1,2)" "1 002"
check "DOTFILES_UMASK wins outright" \
      "$(umaskrun "DOTFILES_GROUP_FILE=$GRPDIR/shared DOTFILES_UMASK=077" | cut -d' ' -f1,2)" "0 077"
# It may only RESTRICT. `umask 022` is an absolute assignment, so a guard
# installed to harden silently LOOSENED an already-hardened host — and the
# doctor printed that as ✓ 022. Two arithmetic traps live here too: $(( ))
# yields DECIMAL while umask parses OCTAL, so passing the union straight
# through set 0o63 from 077 and errored "bad umask" from 002.
stricter() {  # stricter <starting-mask> -> resulting mask
  zsh -c "umask $1; source '$SYSTEM_SH'
          DOTFILES_GROUP_FILE='$GRPDIR/shared' _dotfiles_umask_guard 2>/dev/null
          print -r -- \$(umask)"
}
check "002 tightens to 022"            "$(stricter 002)" "022"
check "022 is already there"           "$(stricter 022)" "022"
check "077 is NOT loosened"            "$(stricter 077)" "077"
check "007 unions rather than replaces" "$(stricter 007)" "027"
# An override that is not a valid mask must be reported, not reported as applied
# — and its error must not escape to stderr during shell initialisation, where
# it lands inside p10k's instant-prompt warning box.
check "invalid DOTFILES_UMASK is a failure" \
      "$(umaskrun "DOTFILES_UMASK=nonsense" | cut -d' ' -f1,2)" "1 002"
check "...named as invalid, not as applied" \
      "$(umaskrun "DOTFILES_UMASK=nonsense" | grep -c 'is not a valid mask')" "1"
# Validity belongs to the VERDICT, not to applying it: while only the guard
# knew, dotfiles-doctor (which asks for the verdict alone) called a nonsense
# override ✓ — reproducing, inside the checker, the very "reported as applied"
# defect the guard had just been fixed for.
check "the verdict itself rejects an invalid override" \
      "$(zsh -c "source '$SYSTEM_SH'
                 local _DOTFILES_UMASK_MODE _DOTFILES_UMASK_WANT _DOTFILES_UMASK_WHY
                 DOTFILES_UMASK=nonsense _dotfiles_umask_verdict
                 print -r -- \"\$?/\${_DOTFILES_UMASK_MODE:-none}\"")" "1/none"
check "the doctor calls it a warning, not ✓" \
      "$(zsh -c "source '$SYSTEM_SH'
                 DOTFILES_UMASK=nonsense HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' \
                   dotfiles-doctor 2>&1" | grep -c '⚠ umask .* not a valid mask')" "1"
check "...and emits no math error" \
      "$(zsh -c "source '$SYSTEM_SH'
                 DOTFILES_UMASK=nonsense HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' \
                   dotfiles-doctor 2>&1" | grep -ci 'bad math')" "0"
# The restriction is applied symbolically, so there is no current-mask read and
# no base conversion — the two traps the numeric form kept producing.
check "the guard performs no umask read" \
      "$(zsh -c "source '$SYSTEM_SH'; print -r -- \"\${functions[_dotfiles_umask_guard]}\"" \
         | grep -cE '\$\(umask\)|8#')" "0"
check "...and prints nothing to stderr" \
      "$(zsh -c "source '$SYSTEM_SH'; DOTFILES_UMASK=nonsense _dotfiles_umask_guard 2>&1 >/dev/null" | wc -c | tr -d ' ')" "0"
# The doctor is a read-only assertion; it must not reset the umask of the shell
# it runs in (a `umask 077` set before handling something sensitive would go).
check "dotfiles-doctor does not touch the umask" \
      "$(zsh -c "umask 077; source '$SYSTEM_SH'
                 DOTFILES_GROUP_FILE='$GRPDIR/shared' HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' \
                   dotfiles-doctor >/dev/null 2>&1
                 print -r -- \$(umask)")" "077"
check "...and the verdict function applies nothing" \
      "$(zsh -c "umask 002; source '$SYSTEM_SH'
                 local _DOTFILES_UMASK_MODE _DOTFILES_UMASK_WANT _DOTFILES_UMASK_WHY
                 DOTFILES_GROUP_FILE='$GRPDIR/shared' _dotfiles_umask_verdict
                 print -r -- \"\$(umask) mode=\$_DOTFILES_UMASK_MODE\"")" "002 mode=restrict"
# It runs in every shell, so it must not fork: $(<file) and $GID, never getent.
check "no getent/awk fork in the guard" \
      "$(zsh -c "source '$SYSTEM_SH'; print -r -- \"\${functions[_dotfiles_umask_guard]}\"" \
         | grep -cE 'getent|\bawk\b|\bid -')" "0"
check "no \$_DOTFILES_UMASK_WHY left behind by the doctor" \
      "$(leak _DOTFILES_UMASK_WHY)" "unset"
# zshrc must actually call it, and must not leak the reason into every shell.
check "zshrc calls the guard" \
      "$(grep -cE '^[[:space:]]*_dotfiles_umask_guard[[:space:]]*$' "$DOTFILES/zshrc")" "1"
check "zshrc unsets the reason"  \
      "$(grep -c 'unset _DOTFILES_UMASK_WHY' "$DOTFILES/zshrc")" "1"

echo
echo "=== the module itself: one note glyph, and it parses ==="
# The two doctors share ✓/✗/⚠ through _doctor_*; a hand-rolled fourth glyph in
# one of them is the deduplication half-done, and puts the next change to how
# notes render back in four places.
check "no hand-rolled note lines" "$(grep -c "printf '  • " "$SYSTEM_SH")" "0"
# `local path` blanks PATH for the function's lifetime (zsh ties that array to
# PATH). The doctor row above pins it behaviourally for one function; this pins
# the class for the whole module, because it recurred in DO-583 — the link
# enumerator lost `awk`, read every conf as unparseable, and refused every
# removal with the wrong reason. Static, so it fires before any behaviour does.
check "no local named path in the module" "$(grep -cE '^[[:space:]]*local\b.*\bpath\b' "$SYSTEM_SH")" "0"
# zsh/functions/*.sh is read by no other static check: the shellcheck job selects
# files by a `^#!` shebang and these have none, and pre-commit excludes the
# directory because the syntax is zsh. CI now runs `zsh -n` over it; so does this,
# so a local run catches it before the push.
check "every functions module parses" \
      "$(for f in "$DOTFILES"/zsh/functions/*.sh; do zsh -n "$f" 2>&1 || echo BAD; done | grep -c BAD)" "0"

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
