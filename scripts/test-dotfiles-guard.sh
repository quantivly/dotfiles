#!/usr/bin/env bash
#
# scripts/test-dotfiles-guard.sh
# ==============================
#
# State table for the dotfiles live-config guard in zsh/functions/system.sh
# (_dotfiles_head_state, _dotfiles_ref_sha, _dotfiles_pin_divergence,
# _dotfiles_guard_verdict, _dotfiles_live_config_warn, _dotfiles_link_map,
# _dotfiles_static_live_paths, _dotfiles_fetch_age_hours, dotfiles-doctor,
# dotfiles-work).
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

echo
echo "=== dotfiles-doctor against a real fixture repo ==="
# A throwaway repo with an origin, so ahead/behind and the file-level diff get
# exercised for real rather than stubbed.
REMOTE="$TMPROOT/remote.git"; REPO="$TMPROOT/repo"
git init -q --bare "$REMOTE"
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
printf '[user]\n\tname = Fixture\n' > "$REPO/gitconfig"   # symlinked to the fake HOME's ~/.gitconfig: must parse
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

touch -d '3 days ago' "$REPO/.git/FETCH_HEAD"
[[ -e "$REPO/.git/refs/remotes/origin/main" ]] && touch -d '3 days ago' "$REPO/.git/refs/remotes/origin/main"
check "stale ref warns"        "$(doctor main | grep -c 'last fetched 72h ago')"            "1"
check "stale ref: no green tick" "$(doctor main | grep -c 'Live config is the reviewed config')" "0"
check "stale ref still exits 0"  "$(doctor_rc main)"                                        "0"

# And the merged-fix-not-running case end to end: someone else pushes to main,
# this checkout never fetches, and the read-only run therefore cannot see it.
# --fetch is the only thing that can, so it must actually change the verdict.
PUSHER="$TMPROOT/pusher"
git clone -q "$REMOTE" "$PUSHER"
git -C "$PUSHER" config user.email t@example.com
git -C "$PUSHER" config user.name Test
echo 'echo merged-elsewhere' >> "$PUSHER/zsh/zshrc.company"
git -C "$PUSHER" commit -qam "a fix merged by someone else"
git -C "$PUSHER" push -q origin main
check "stale run cannot see it"  "$(doctor main | grep -c 'commit(s) BEHIND')" "0"
check "--fetch sees it"          "$(doctor main '' '--fetch' | grep -c '1 commit(s) BEHIND')" "1"
check "--fetch exits 1"          "$(doctor_rc main '' '--fetch')" "1"

echo
echo "=== the doctor leaves nothing behind in the shell ==="
# The counters and the internals' result variables used to be globals, so four
# _D* variables persisted in every shell that ran the doctor (or merely started,
# for two of them), and a nested call clobbered the outer count.
leak() { zsh -c "source '$SYSTEM_SH'; HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' dotfiles-doctor >/dev/null 2>&1; print -r -- \"\${$1-unset}\""; }
for v in _DOCTOR_FAIL _DOCTOR_WARN _DOTFILES_HEAD _DOTFILES_VERDICT; do
  check "no \$$v left behind" "$(leak "$v")" "unset"
done
check "no _D* left after the startup warning" \
      "$(zsh -c "source '$SYSTEM_SH'; DOTFILES_ROOT='$TMPROOT/br' _dotfiles_live_config_warn >/dev/null 2>&1; print -r -- \"\${_DOTFILES_VERDICT-unset}\"")" \
      "unset"

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
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
