#!/usr/bin/env bash
#
# scripts/test-dotfiles-guard.sh
# ==============================
#
# State table for the dotfiles live-config guard in zsh/functions/system.sh
# (_dotfiles_head_state, _dotfiles_guard_verdict, _dotfiles_live_config_warn,
# _dotfiles_link_map, dotfiles-doctor).
#
# Why this exists: the guard's whole job is to notice that the running config is
# not the reviewed config. A guard that reports "all clear" when it is actually
# broken is worse than no guard, because it turns an unnoticed problem into a
# confidently denied one. Two such bugs were found by hand while writing it —
# see the PATH and missing-ref cases below — and both produced a green tick, not
# an error. That class is invisible to shellcheck and to a single hand-run on a
# machine that happens to be in the passing state.
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
mkdir -p "$TMPROOT/br/.git" "$TMPROOT/det/.git" "$TMPROOT/empty/.git" "$TMPROOT/none" "$TMPROOT/wt"
printf 'ref: refs/heads/feature/x\n' > "$TMPROOT/br/.git/HEAD"
printf '9f1c0de5c0ffee0123456789abcdef0123456789\n' > "$TMPROOT/det/.git/HEAD"
: > "$TMPROOT/empty/.git/HEAD"
# A worktree has a .git FILE, not a directory. Nothing symlinks into a worktree,
# so "unknown" (and therefore silence) is correct there, not an error.
printf 'gitdir: /somewhere/.git/worktrees/wt\n' > "$TMPROOT/wt/.git"

head_state() { zrun "_dotfiles_head_state '$1'; print -r -- \$_DOTFILES_HEAD"; }

check "symbolic ref"          "$(head_state "$TMPROOT/br")"    "branch feature/x"
check "raw sha is detached"   "$(head_state "$TMPROOT/det")"   "detached 9f1c0de5c0ffee0123456789abcdef0123456789"
check "empty HEAD"            "$(head_state "$TMPROOT/empty")" "unknown"
check "no .git at all"        "$(head_state "$TMPROOT/none")"  "unknown"
check "worktree .git file"    "$(head_state "$TMPROOT/wt")"    "unknown"
check "empty root argument"   "$(head_state '')"               "unknown"

echo
echo "=== _dotfiles_live_config_warn: what the user sees at shell startup ==="
warn() { zrun "DOTFILES_ROOT='$1' DOTFILES_PIN_BRANCH='${2:-main}' ${3:-} _dotfiles_live_config_warn"; }

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
    ~/.config/thing.toml: config/thing.toml   # trailing comment
    ~/.p10k.zsh:
      path: p10k.zsh
      if: '[ -f p10k.zsh ]'
YAML
map() { zrun "_dotfiles_link_map '$TMPROOT/conf'"; }

check "inline form"            "$(map | grep -c '^~/.gitconfig gitconfig$')"                 "1"
check "trailing comment cut"   "$(map | grep -c '^~/.config/thing.toml config/thing.toml$')" "1"
check "expanded path: form"    "$(map | grep -c '^~/.p10k.zsh p10k.zsh$')"                   "1"
check "comment line ignored"   "$(map | grep -c 'decoy')"                                    "0"
check "no spurious entries"    "$(map | wc -l | tr -d ' ')"                                  "3"
check "live paths include zsh" "$(zrun "_dotfiles_live_paths '$TMPROOT/conf'" | grep -cx 'zsh')" "1"

echo
echo "=== dotfiles-doctor against a real fixture repo ==="
# A throwaway repo with an origin, so ahead/behind and the file-level diff get
# exercised for real rather than stubbed.
REMOTE="$TMPROOT/remote.git"; REPO="$TMPROOT/repo"
git init -q --bare "$REMOTE"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  Test
mkdir -p "$REPO/zsh" "$REPO/config"
cp "$TMPROOT/conf/install.conf.yaml" "$REPO/install.conf.yaml"
echo 'echo hi'   > "$REPO/zsh/zshrc.company"
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

doctor()    { zrun "HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' DOTFILES_PIN_BRANCH='${1:-main}' dotfiles-doctor"; }
doctor_rc() { zsh -c "source '$SYSTEM_SH'; HOME='$FAKEHOME' DOTFILES_ROOT='$REPO' DOTFILES_PIN_BRANCH='${1:-main}' dotfiles-doctor" >/dev/null 2>&1; echo $?; }

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
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
