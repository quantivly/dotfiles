#!/usr/bin/env bash
#
# scripts/test-tmpdir-clean.sh
# ============================
#
# State table for scripts/tmpdir-clean.sh.
#
# The aging rows run the REAL systemd-tmpfiles, because what is being pinned is
# the combination of the guard this script writes and the semantics of the tool
# that reads it, and a stub would only restate what the script was told. Two
# things make that safe and hermetic:
#
#   * HOME, XDG_RUNTIME_DIR, XDG_CONFIG_HOME and XDG_STATE_HOME all point into a
#     mktemp tree, and the config and guard are passed BY PATH, so nothing on the
#     user search path is read. `%h` follows $HOME (measured on systemd 259), and
#     a preflight below proves it on this machine, non-destructively, before any
#     clean runs: a `%h` that resolved to the real home would age out the real
#     ~/.cache/tmp.
#   * The config is DERIVED from config/user-tmpfiles.d/tmpdir.conf by taking
#     b, B, c and C out of each age's age-by (or out of the default abcmABM where
#     a line has none): btime cannot be backdated and touch sets ctime to now, so
#     with them a fixture built now is never old. The shipped abcmBM becomes amM.
#     The derivation is asserted to change the age-by fields and nothing else,
#     so the paths, ages and every other letter under test are the shipped ones.
#
# The rows that need a version or an exit status systemd-tmpfiles will not give
# on demand (systemd < 249 and < 256, exits 65 and 73) use a recording stub
# through TMPDIR_CLEAN_TMPFILES, and the one find error the walk no longer meets
# by itself (EACCES is pruned) uses a find stub on PATH. So do the non-writable-
# directory pass's failures and races: a find that fails only its walk, a stat
# that fails, one that answers a btime that is not a number, one that swaps a
# path for a symlink (or removes it) after it answers, and an id that names
# another user. --check and --install run behind a recording systemctl stub at
# the front of PATH, never against a runner that happens to have no user
# manager.
#
# "Could not run" is exit 2, never a pass.
#
# Usage: scripts/test-tmpdir-clean.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SUT:-$HERE/tmpdir-clean.sh}"
SHIPPED="${SHIPPED:-$HERE/../config/user-tmpfiles.d/tmpdir.conf}"
# The caller's own settings must not reach a row: TMPDIR_CLEAN_OFF exported in a
# developer's ~/.zshrc.local would turn every --check and --install row around.
unset TMPDIR_CLEAN_OFF TMPDIR_CLEAN_CONFIG TMPDIR_CLEAN_GUARD_DIR TMPDIR_CLEAN_STATE \
      TMPDIR_CLEAN_TMPFILES TMPDIR_CLEAN_ENV_LINK SYSTEMD_USER_DIR

PASS=0; FAIL=0
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 2; }
[[ -x "$SUT" ]] || fatal "not executable: $SUT"
[[ -r "$SHIPPED" ]] || fatal "cannot read $SHIPPED"
for tool in systemd-tmpfiles git realpath; do
  command -v "$tool" >/dev/null 2>&1 || fatal "$tool is required"
done

T="$(mktemp -d)" || fatal "no temp dir"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
H="$T/home"; R="$H/.cache/tmp"; U="$(id -u)"
mkdir -p "$R" "$T/run" "$T/cfg" "$T/state" "$T/bin" "$T/hosts" || fatal "setup"

# --- the derived config -------------------------------------------------------
sed -E -e '/^[de] /s/[[:space:]]([0-9]+[a-z]*)$/ abcmABM:\1/' \
  -e ':a' -e 's/^([de] .*[[:space:]][aAmM]*)[bBcC]([aAbBcCmM]*:[0-9]+[a-z]*)$/\1\2/' -e 'ta' \
  "$SHIPPED" > "$T/tmpdir.conf" || fatal "derive"
[[ "$(grep -c -E '^[de] .*[[:space:]][aAmM]+:[0-9]+[a-z]*$' "$T/tmpdir.conf")" == "$(grep -c '^[de] ' "$SHIPPED")" ]] \
  || fatal "deriving the test config did not leave every age field with an age-by free of b, B, c and C"
noby() { sed -E 's/[[:space:]][aAbBcCmM]+:([0-9]+[a-z]*)$/ \1/' "$1"; }
[[ "$(noby "$T/tmpdir.conf")" == "$(noby "$SHIPPED")" ]] \
  || fatal "the derived test config differs from the shipped one by more than the age-by letters"

# --- preflight: %h is the fake home -------------------------------------------
probe=".tmpdir-clean-probe-$$"
printf 'd %%h/%s 0700 - - -\n' "$probe" > "$T/probe.conf"
HOME="$H" XDG_RUNTIME_DIR="$T/run" XDG_CONFIG_HOME="$T/cfg" \
  systemd-tmpfiles --user --create "$T/probe.conf" >/dev/null 2>&1
if [[ ! -d "$H/$probe" ]]; then
  [[ -d "$HOME/$probe" ]] && rmdir "$HOME/$probe"
  fatal "systemd-tmpfiles did not resolve %h to \$HOME; running the aging rows would clean the real home"
fi
rmdir "$H/$probe"

# --- stubs --------------------------------------------------------------------
cat > "$T/bin/tmpfiles-stub" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then printf 'systemd %s (%s-stub)\n' "$STUB_VER" "$STUB_VER"; exit 0; fi
printf '%s\n' "$*" >> "$STUB_LOG"
exit "${STUB_RC:-0}"
STUB
# Records every call, prefixed `systemctl `, in the same log the tmpfiles stub
# writes to: no mode calls both, so a row reading one reads only its own.
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$STUB_LOG"
[[ "$1" == --user ]] || exit 1
case "$2" in
  show-environment) [[ "${STUB_MANAGER:-1}" == 1 ]] ;;
  is-enabled)
    case "$3" in
      tmpdir-clean.timer)           printf '%s\n' "${STUB_TIMER:-enabled}"; [[ "${STUB_TIMER:-enabled}" == enabled ]] ;;
      systemd-tmpfiles-clean.timer) printf '%s\n' "${STUB_VENDOR:-disabled}"; [[ "${STUB_VENDOR:-disabled}" == enabled ]] ;;
      *) exit 1 ;;
    esac ;;
  is-active) printf '%s\n' "${STUB_ACTIVE:-active}"; [[ "${STUB_ACTIVE:-active}" == active ]] ;;
  daemon-reload|enable|stop) exit 0 ;;
  *) exit 1 ;;
esac
STUB
mkdir -p "$T/findbin" "$T/xdevbin" "$T/statbin" || fatal "setup"
printf '#!/bin/sh\necho "find: simulated I/O error" >&2\nexit 1\n' > "$T/findbin/find"
# Fails only the non-writable-directory walk (the one with -mindepth), so the
# guard's walk still succeeds and the run gets that far.
printf '#!/bin/sh\ncase " $* " in *" -mindepth "*) echo "find: simulated I/O error" >&2; exit 1 ;; esac\nexec %s "$@"\n' \
  "$(command -v find)" > "$T/xdevbin/find"
printf '#!/bin/sh\necho "stat: simulated failure" >&2\nexit 1\n' > "$T/statbin/stat"
REAL_STAT="$(command -v stat)" REAL_ID="$(command -v id)"
[[ -n "$REAL_STAT" && -n "$REAL_ID" ]] || fatal "stat and id are required"
# Answers every path with its real inode and a btime that is not a number.
mkdir -p "$T/nostatbin" "$T/swapbin" "$T/idbin" || fatal "setup"
# shellcheck disable=SC2016  # the $ belongs to the stub
printf '#!/bin/sh\nwhile [ "$1" != -- ]; do shift; done; shift\nfor f; do printf "%%s -\\n" "$(%s -c %%i -- "$f")"; done\n' \
  "$REAL_STAT" > "$T/nostatbin/stat"
# Answers as stat does, then swaps $SWAP_FROM for a symlink to $SWAP_TO, or
# with no $SWAP_TO removes it: a race between the walk and the chmod, on demand.
# shellcheck disable=SC2016  # the $ belongs to the stub
printf '#!/bin/sh\n%s "$@"; rc=$?\nif [ -n "$SWAP_TO" ]; then mv "$SWAP_FROM" "$SWAP_FROM.real" && ln -s "$SWAP_TO" "$SWAP_FROM"; else rmdir "$SWAP_FROM"; fi\nexit $rc\n' \
  "$REAL_STAT" > "$T/swapbin/stat"
# Says this user is uid 4242, so every fixture is owned by another user.
# shellcheck disable=SC2016  # the $ belongs to the stub
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 4242; exit 0; fi\nexec %s "$@"\n' "$REAL_ID" > "$T/idbin/id"
chmod +x "$T/bin/tmpfiles-stub" "$T/bin/systemctl" "$T/findbin/find" "$T/xdevbin/find" "$T/statbin/stat" \
  "$T/nostatbin/stat" "$T/swapbin/stat" "$T/idbin/id" || fatal "setup"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

# A host repository with one commit, and a worktree of it at $2.
host() { mkdir -p "$1" && g -C "$1" init -q && echo h > "$1/README" && g -C "$1" add README && g -C "$1" commit -qm i; }
worktree() { g -C "$1" worktree add -q --detach "$2" || fatal "git worktree add $2"; echo dirty > "$2/uncommitted"; }

# The baseline tree. Everything is made 10 days old, then the exceptions.
fresh() {
  chmod -R u+rwx "$R" "$T/hosts" 2>/dev/null
  rm -rf "$R" "$T/hosts" "$T/run" || fatal "fresh"
  mkdir -p "$R/claude-$U/s" "$T/hosts" "$T/run" || fatal "fresh"
  echo o > "$R/old"; echo y > "$R/young"; echo r > "$R/read"
  echo c > "$R/claude-$U/s/f13"; echo c > "$R/claude-$U/s/f15"
  host "$T/hosts/out" || fatal "host out"
  worktree "$T/hosts/out" "$R/wt-out"
  host "$R/hostin" || fatal "host in"
  worktree "$R/hostin" "$R/wt-in"
  find "$R" -exec touch -h -d '-10 days' {} + || fatal "age"
  # Each age is pinned from both sides: a day under it is kept, a day over goes.
  touch -d '-8 days' "$R/old"; touch -d '-6 days' "$R/young"
  touch -a -d '-1 day' "$R/read"
  touch -d '-13 days' "$R/claude-$U/s/f13"; touch -d '-15 days' "$R/claude-$U/s/f15"
}

run() {  # run [args...] — env overrides come from the caller; RUN_HOME, RUN_CONF too
  : > "$T/stub.log"
  HOME="${RUN_HOME:-$H}" XDG_RUNTIME_DIR="$T/run" XDG_CONFIG_HOME="$T/cfg" XDG_STATE_HOME="$T/state" \
  TMPDIR_CLEAN_CONFIG="${RUN_CONF:-$T/tmpdir.conf}" STUB_LOG="$T/stub.log" PATH="$T/bin:$PATH" \
    "$SUT" "$@" >"$T/out" 2>"$T/err"
  echo $?
}
guard() { cat "$T/run/user-tmpfiles.d/tmpdir-worktrees.conf" 2>/dev/null; }
here() { [[ -e "$1" ]] && echo kept || echo gone; }
lnk() { [[ -L "$1" ]] && echo kept || echo gone; }
mode() { stat -c %a -- "$1" 2>/dev/null || echo gone; }
# An empty directory, aged $2 (a touch -d date), then given mode $3.
mkro() { { mkdir -p "$1" && touch -d "$2" "$1" && chmod "$3" "$1"; } || fatal "mkro $1"; }
lastlog() { sed -n '$s/^[^ ]* //p' "$T/state/tmpdir-clean/log" | sed 's/ used=.*//'; }

printf 'aging, with the shipped paths and ages\n'
fresh
rc="$(run)"
check "a clean run exits 0" "$rc" 0
check "an 8-day-old top-level file is removed" "$(here "$R/old")" gone
check "a 6-day-old top-level file is kept" "$(here "$R/young")" kept
check "an old file read yesterday is kept (atime counts)" "$(here "$R/read")" kept
check "a 13-day-old file under claude-<uid> is kept (its own 14-day line)" "$(here "$R/claude-$U/s/f13")" kept
check "a 15-day-old file under claude-<uid> is removed" "$(here "$R/claude-$U/s/f15")" gone

printf '\nthe worktree guard\n'
check "a worktree whose host is OUTSIDE the root keeps its uncommitted file" "$(here "$R/wt-out/uncommitted")" kept
check "... and its .git file" "$(here "$R/wt-out/.git")" kept
check "... and the guard names exactly that path" "$(guard | grep -c -x -F "x $R/wt-out")" 1
check "a worktree whose host is INSIDE the root ages out with it" "$(here "$R/wt-in/uncommitted")" gone
check "the guard has one x line in all" "$(guard | grep -c '^x ')" 1
check "the run is logged with its mode, guard count, status and failed count" "$(lastlog)" "mode=apply guarded=1 chmod=0 rc=0 failed=0"

fresh
cp -a "$R/wt-out" "$R/wt-copy"
mkdir -p "$R/sub" && printf 'gitdir: %s/hosts/out/.git/modules/m\n' "$T" > "$R/sub/.git"
mkdir -p "$T/hosts/out/.git/modules/m"
rc="$(run)"
check "a copy of a worktree (its gitdir points back elsewhere) is not guarded" \
  "$(guard | grep -c -F "$R/wt-copy")" 0
check "a submodule-style .git file (no back-pointer) is not guarded, and is no refusal" \
  "$rc:$(guard | grep -c -F "$R/sub")" "0:0"

fresh
g -C "$T/hosts/out" -c worktree.useRelativePaths=true worktree add -q --detach "$R/wt-rel"
rc="$(run)"
check "a worktree registered with relative paths is guarded" "$(guard | grep -c -x -F "x $R/wt-rel")" 1

# Where Claude Code really puts a worktree: claude-<uid>/<slug>/<session>/
# scratchpad/, so its .git is at depth 6, inside the 14-day e line. Aged past 14
# days, so an unguarded one is deleted; the loose file beside it shows the e
# line did run there. The deeper one has its .git at depth 9, past the
# -maxdepth 8 the walk once had.
fresh
SP="$R/claude-$U/-home-u-proj/0b5e-session/scratchpad"
mkdir -p "$SP/a/b/c" || fatal "scratchpad"
worktree "$T/hosts/out" "$SP/wt"
worktree "$T/hosts/out" "$SP/a/b/c/wt"
echo l > "$SP/loose"
find "$R/claude-$U" -exec touch -h -d '-20 days' {} + || fatal "age"
rc="$(run)"
check "a scratchpad worktree (claude-<uid>/<slug>/<session>/scratchpad/wt) is guarded" \
  "$(guard | grep -c -x -F "x $SP/wt")" 1
check "... and an x line inside the e line is honoured: kept at 20 days, a loose file beside it goes" \
  "$(here "$SP/wt/uncommitted"):$(here "$SP/loose")" "kept:gone"
check "a worktree three levels deeper (.git at depth 9) is guarded and kept" \
  "$(guard | grep -c -x -F "x $SP/a/b/c/wt"):$(here "$SP/a/b/c/wt/uncommitted")" "1:kept"

# git reads a .git file whole and strips trailing CR and LF, so a CRLF one is a
# worktree to git. Read as one line with its CR, it named a gitdir that does not
# exist, read as "no back-pointer", and the worktree went unguarded.
fresh
worktree "$T/hosts/out" "$R/wt-crlf"
printf '%s\r\n' "$(cat "$R/wt-crlf/.git")" > "$R/wt-crlf/.git.crlf" && mv "$R/wt-crlf/.git.crlf" "$R/wt-crlf/.git"
git -C "$R/wt-crlf" rev-parse --git-dir >/dev/null 2>&1 \
  || fatal "git does not accept a CRLF .git file, so the CRLF row has no premise"
find "$R/wt-crlf" -exec touch -h -d '-10 days' {} + || fatal "age"
rc="$(run)"
check "a worktree whose .git file has CRLF line endings is guarded and kept" \
  "$(guard | grep -c -x -F "x $R/wt-crlf"):$(here "$R/wt-crlf/uncommitted")" "1:kept"

# systemd-tmpfiles matches an x line against the path as it walks it, spelled
# from %h, so through a symlinked $HOME. A realpath'd x line is not honoured
# (measured, systemd 259): the worktree would be deleted under a guard naming it.
fresh
ln -s home "$T/homelink" || fatal "homelink"
rc="$(RUN_HOME="$T/homelink" run)"
check "with \$HOME through a symlink, the x line is spelled through it and the worktree kept" \
  "$(guard | grep -c -x -F "x $T/homelink/.cache/tmp/wt-out"):$(here "$R/wt-out/uncommitted")" "1:kept"

# The walk does not look inside node_modules, which is where its cost is, so a
# worktree there is NOT guarded. This row pins that documented limit, not a goal.
fresh
mkdir -p "$R/proj/node_modules" || fatal "node_modules"
worktree "$T/hosts/out" "$R/proj/node_modules/wt"
rc="$(run)"
check "a worktree inside node_modules is not looked for, so not guarded (the documented limit)" \
  "$rc:$(guard | grep -c -F "$R/proj/node_modules/wt")" "0:0"

printf '\nwhat the walk skips, as systemd-tmpfiles does\n'
# This laptop's ~/.cache/tmp holds a mode-000 directory, which made every run
# refuse while systemd-tmpfiles (same user) cannot enter it either: it logs
# "failed, ignoring" and exits 0. Each permission is pinned on its own.
fresh
mkdir -p "$R/searchonly/s" && chmod 100 "$R/searchonly"
rc="$(run)"
check "a directory this user can search but not read is skipped: 0, and the clean ran" "$rc:$(here "$R/old")" "0:gone"
chmod 700 "$R/searchonly"
fresh
mkdir -p "$R/readonly/s" && chmod 400 "$R/readonly"
rc="$(run)"
check "a directory this user can read but not search is skipped: 0, and the clean ran" "$rc:$(here "$R/old")" "0:gone"
chmod 700 "$R/readonly"

printf '\nnon-writable directories, and how directories age\n'
# The first real run (2026-10-18) logged 55,283 "Permission denied" removals, all
# of files in directories this user owns with no write bit: Go module caches (555)
# under throwaway GOPATHs. systemd-tmpfiles exits 73 for one under the e line and
# only logs one under the d line, so the first row has one of each. Each of the
# directories it changes has a fresh atime and an old mtime: the pre-pass, like
# the config, must not count directory atime, which the walks bump themselves.
# Not pinned here: a directory owned by another user (cannot be made without
# root), and -xdev (a second filesystem cannot be mounted without root).
fresh
G="$R/gopath/pkg/mod/x@v1" CG="$R/claude-$U/sess/scratchpad/go/pkg/mod/y@v1"
mkdir -p "$G/sub" "$CG/sub" "$R/emptyold" "$R/dirold" "$T/outside555/inner" || fatal "ro"
echo m > "$G/sub/f.go"; echo m > "$CG/sub/f.go"; echo o > "$R/dirold/f"
find "$R/gopath" "$R/emptyold" "$R/dirold" "$T/outside555" -exec touch -h -d '-10 days' {} + || fatal "age"
find "$R/claude-$U/sess" -exec touch -h -d '-20 days' {} + || fatal "age"
touch -a "$R/emptyold" "$R/dirold" "$G" "$CG"
chmod 555 "$G/sub" "$G" "$CG/sub" "$CG" "$T/outside555/inner" "$T/outside555" || fatal "ro"
{ ln -s "$T/outside555" "$R/link555" && touch -h -d '-10 days' "$R/link555"; } || fatal "link555"
mkro "$R/young555" '-6 days' 555
mkro "$R/wt-out/ro" '-10 days' 555
mkro "$R/claude-$U/s/ro10" '-10 days' 555
mkro "$R/m000" '-10 days' 000
rc="$(run)"
check "an old 555 dir holding an old 555 dir and an old file goes, under the root and under claude-<uid>, and the run exits 0" \
  "$rc:$(here "$R/gopath"):$(here "$R/claude-$U/sess")" "0:gone:gone"
check "... and the log counts the four directories given u+w, and the one it could not open (m000)" \
  "$(lastlog)" "mode=apply guarded=1 chmod=4 rc=0 failed=1"
check "... which is warned of, though under the d line systemd-tmpfiles exited 0" \
  "$(grep -c -F 'tmpdir-clean: WARNING: failed=1:' "$T/err")" 1
check "an old directory with a FRESH atime goes, empty or holding only an old file (directory atime is not counted)" \
  "$(here "$R/emptyold"):$(here "$R/dirold")" "gone:gone"
check "a 555 dir 6 days old keeps its mode" "$(mode "$R/young555")" 555
check "an old 555 dir inside a guarded worktree keeps its mode" "$(mode "$R/wt-out/ro")" 555
check "a 555 dir under claude-<uid>, 10 days old (its own line says 14), keeps its mode" "$(mode "$R/claude-$U/s/ro10")" 555
check "a symlink to an old 555 dir is not followed: neither that dir nor the one in it changes, or is even looked at" \
  "$(mode "$T/outside555"):$(mode "$T/outside555/inner"):$(grep -c -F "$R/link555" "$T/err")" "555:555:0"
check "an old dir this user cannot read (000) is pruned, as in the guard's walk, and keeps its mode" "$(mode "$R/m000")" 0
chmod -R u+rwx "$T/outside555"

# Under claude-<uid>'s e line, what systemd-tmpfiles cannot open or remove makes
# it exit 73, and that used to turn the unit red every night. The unreadable
# directory is never given u+rx: the guard's walk did not look inside it.
fresh
LK="$R/claude-$U/sess/scratchpad/fx/locked"
{ mkdir -p "$LK" && echo x > "$LK/f" && chmod 000 "$LK"; } || fatal "locked"
rc="$(run)"
check "an unreadable directory under claude-<uid> (systemd-tmpfiles exits 73) -> 0" "$rc" 0
check "... logged with that 73 and failed=1" "$(lastlog)" "mode=apply guarded=1 chmod=0 rc=73 failed=1"
check "... and the path is echoed in the warning" \
  "$(grep -c -F "  Opening directory \"$LK\" failed" "$T/err"):$(mode "$LK")" "1:0"
# A non-writable directory younger than its line, holding an old one: the old
# one is given u+w and emptied, and cannot itself be removed until its parent ages.
fresh
PP="$R/claude-$U/sess/p"
{ mkdir -p "$PP/child" && echo x > "$PP/child/f"; } || fatal "e3"
find "$R/claude-$U/sess" -exec touch -h -d '-20 days' {} + || fatal "age"
{ touch -d '-3 days' "$PP" && chmod 555 "$PP/child" "$PP"; } || fatal "e3"
rc="$(run)"
check "under claude-<uid>, an old 555 dir in a 3-day-old 555 dir: its file goes, it stays, the parent keeps its mode, and the run exits 0" \
  "$rc:$(here "$PP/child/f"):$(here "$PP/child"):$(mode "$PP")" "0:gone:kept:555"
check "... logged as one chmod, rc=73 and failed=1" "$(lastlog)" "mode=apply guarded=1 chmod=1 rc=73 failed=1"

# stat prints a non-UTF-8 name lossily (uutils 0.8), so the pass reads every
# name from find. On GNU stat (CI) this row passes either way.
fresh
NU="$R/bad"$'\xff'"name"
{ mkdir -p "$NU" && echo f > "$NU/f" && touch -d '-10 days' "$NU/f" "$NU" && chmod 555 "$NU"; } || fatal "non-utf8"
rc="$(run)"
check "an old 555 dir whose name is not UTF-8 is given u+w, and goes with its old file" "$rc:$(here "$NU")" "0:gone"

# An age-by with no directory letter means the default ABM to systemd-tmpfiles.
fresh
mkro "$R/young1" '-1 day' 555
sed 's/ amM:7d$/ am:7d/' "$T/tmpdir.conf" > "$T/c-am.conf"
rc="$(RUN_CONF="$T/c-am.conf" run)"
check "with an age-by of am (no directory letter, so ABM), a 1-day-old 555 dir keeps its mode" "$(mode "$R/young1")" 555

# Owned by another user: an id stub says this user is uid 4242. It holds an old
# file, so that it cannot go and its mode can be read.
fresh
{ mkdir -p "$R/notmine" && echo o > "$R/notmine/f" && touch -d '-10 days' "$R/notmine/f"; } || fatal "notmine"
mkro "$R/notmine" '-10 days' 555
rc="$(PATH="$T/idbin:$PATH" run)"
check "an old 555 dir owned by another user (id says 4242) keeps its mode" "$rc:$(mode "$R/notmine")" "0:555"

# chmod follows symlinks, so a path swapped after the walk is checked again just
# before it: it must resolve to exactly itself under the root. The stat stub
# swaps it once it has answered.
outside555() { chmod -R u+rwx "$T/outside" 2>/dev/null; rm -rf "$T/outside"; mkro "$T/outside/b" '-10 days' 555; }
fresh
mkro "$R/a/b" '-10 days' 555
outside555
rc="$(SWAP_FROM="$R/a/b" SWAP_TO="$T/outside/b" PATH="$T/swapbin:$PATH" run)"
check "the directory itself swapped for a symlink out of the root after the walk -> left as it is, with a warning" \
  "$(mode "$T/outside/b"):$(grep -c -F "$R/a/b no longer resolves to the directory the walk found" "$T/err")" "555:1"
fresh
mkro "$R/a/b" '-10 days' 555
outside555
rc="$(SWAP_FROM="$R/a" SWAP_TO="$T/outside" PATH="$T/swapbin:$PATH" run)"
check "a directory ABOVE it swapped for a symlink out of the root -> no chmod outside the root" "$(mode "$T/outside/b")" 555
fresh
mkro "$R/a/b" '-10 days' 555
mkro "$R/wt-out/b" '-10 days' 555
rc="$(SWAP_FROM="$R/a" SWAP_TO="$R/wt-out" PATH="$T/swapbin:$PATH" run)"
check "... or for a symlink INSIDE the root, into a guarded worktree -> no chmod there either" "$(mode "$R/wt-out/b")" 555
fresh
mkro "$R/a/b" '-10 days' 555
rc="$(SWAP_FROM="$R/a/b" SWAP_TO="" PATH="$T/swapbin:$PATH" run)"
check "a directory removed between the walk and the chmod is passed over without a word" \
  "$rc:$(grep -c -F "$R/a/b" "$T/err")" "0:0"
chmod -R u+rwx "$T/outside" && rm -rf "$T/outside"

# The pre-pass takes its directory letters from the config, so each one the
# config adds keeps a directory the derived amM would have changed.
fresh
mkro "$R/byA" '-10 days' 555
sed 's/ amM:7d$/ amAM:7d/' "$T/tmpdir.conf" > "$T/c-A.conf"
rc="$(RUN_CONF="$T/c-A.conf" run)"
check "with A in the config's age-by, a 555 dir the walk itself just read is left alone" "$(mode "$R/byA")" 555
fresh
mkro "$R/byB" '-10 days' 555
sed 's/ amM:7d$/ amBM:7d/' "$T/tmpdir.conf" > "$T/c-B.conf"
rc="$(RUN_CONF="$T/c-B.conf" run)"
# systemd-tmpfiles reads a btime the filesystem does not record as 0, so ignores it.
if [[ "$(stat -c %W -- "$R")" == 0 ]]; then want=gone bt="changed and removed (this filesystem records no btime)"; else want=555 bt="left alone"; fi
check "with B in the config's age-by, an old-mtime 555 dir created today is $bt" "$(mode "$R/byB")" "$want"

# A line that ages nothing (age -) governs what is under it: nothing there goes,
# so nothing there is changed.
fresh
mkro "$R/keep/ro" '-10 days' 555
{ cat "$T/tmpdir.conf"; printf 'd %%h/.cache/tmp/keep 0700 - - -\n'; } > "$T/c-keep.conf"
rc="$(RUN_CONF="$T/c-keep.conf" run)"
check "an old 555 dir under a line with no age keeps its mode" "$rc:$(mode "$R/keep/ro")" "0:555"

# A failure in the pre-pass can only leave a directory unwritable, so it warns
# and the clean still runs.
fresh
rc="$(PATH="$T/xdevbin:$PATH" run)"
check "a failing non-writable-directory walk -> a warning naming it, and the clean runs: 0" \
  "$rc:$(grep -c -F 'while looking for non-writable directories' "$T/err"):$(here "$R/old")" "0:1:gone"
# The directory holds an old file, so that it cannot go and its mode can be read.
# Only btime comes from stat, so these rows count B (amBM): without it, stat's
# answer decides nothing.
fresh
{ mkdir -p "$R/st555" && echo o > "$R/st555/f" && touch -d '-10 days' "$R/st555/f"; } || fatal "st555"
mkro "$R/st555" '-10 days' 555
rc="$(RUN_CONF="$T/c-B.conf" PATH="$T/statbin:$PATH" run)"
check "a failing stat, with B counted -> a warning naming the directory, the clean runs, and it keeps its mode" \
  "$rc:$(grep -c -F "stat did not answer for $R/st555 " "$T/err"):$(here "$R/old"):$(mode "$R/st555")" \
  "0:1:gone:555"
rc="$(RUN_CONF="$T/c-B.conf" PATH="$T/nostatbin:$PATH" run)"
check "a btime stat answers with something other than a number keeps the directory as it is" \
  "$rc:$(mode "$R/st555")" "0:555"

printf '\nrefusals delete nothing\n'
fresh
worktree "$T/hosts/out" "$R/wt sp"
mkro "$R/ro555" '-10 days' 555
rc="$(run)"
check "a worktree path with a space -> 2, naming the path" "$rc:$(grep -c -F 'sp has a path an x line' "$T/err")" "2:1"
check "... and nothing was deleted" "$(here "$R/old")" kept
check "... and no directory was given u+w: that happens only once the guard is written" "$(mode "$R/ro555")" 555

# Every character class encodable() rejects, one worktree at a time. Each one
# that slipped through would write an x line that tmpfiles reads back as a
# different path, a glob or a parse error, and the worktree would go unguarded.
# On a fresh tree: the one above still holds `wt sp`, which refuses every run.
fresh
rcs=""
for name in 'wt%h' 'wt*' 'wt?' 'wt[a]' 'wt\b' 'wt"q' "wt'q" $'wt\tt'; do
  worktree "$T/hosts/out" "$R/$name"
  rcs+="$(run) "
  g -C "$T/hosts/out" worktree remove --force "$R/$name"
done
check "%, *, ?, [, backslash, both quotes and a tab each -> 2" "$rcs" "2 2 2 2 2 2 2 2 "

# A newline is a control character, so this is a refusal. It used to be "not a
# worktree": the back-pointer was read to its first line, which named a
# different path, and the worktree was deleted unguarded with exit 0.
fresh
worktree "$T/hosts/out" "$R/wt"$'\n'"nl"
rc="$(run)"
check "a worktree path with a newline -> 2, not misread as 'not a worktree'" \
  "$rc:$(grep -c 'has a path an x line cannot express' "$T/err")" "2:1"

fresh
rc="$(PATH="$T/findbin:$PATH" run)"
check "a find error -> 2, naming find" "$rc:$(grep -c 'find exited 1' "$T/err")" "2:1"
check "... and nothing was deleted" "$(here "$R/old")" kept

fresh
mkdir -p "$R/x" && echo 'gitdir: /nowhere' > "$R/x/.git" && chmod 000 "$R/x/.git"
rc="$(run)"
check "an unreadable .git file -> 2, naming it" "$rc:$(grep -c -F "cannot read $R/x/.git" "$T/err")" "2:1"
check "... and nothing was deleted" "$(here "$R/old")" kept
chmod 600 "$R/x/.git"

# [[ -e ]] is false for EACCES as well as ENOENT. Read as "no back-pointer", a git
# dir this user cannot search left its worktree unguarded, deleted with exit 0.
fresh
chmod 000 "$T/hosts/out/.git/worktrees/wt-out"
rc="$(run)"
check "a worktree whose git dir cannot be searched -> 2, naming that dir" \
  "$rc:$(grep -c -F "cannot search $T/hosts/out/.git/worktrees/wt-out," "$T/err")" "2:1"
check "... and nothing was deleted" "$(here "$R/wt-out/uncommitted"):$(here "$R/old")" "kept:kept"
chmod 700 "$T/hosts/out/.git/worktrees/wt-out"
fresh
chmod 000 "$T/hosts/out/.git/worktrees"
rc="$(run)"
check "... and one whose git dir's PARENT cannot be searched -> 2, naming the parent" \
  "$rc:$(grep -c -F "cannot search $T/hosts/out/.git/worktrees," "$T/err")" "2:1"
chmod 700 "$T/hosts/out/.git/worktrees"

# A symlinked root is a silent no-op in systemd-tmpfiles (it does not follow
# it, and exits 0), so without this the log would read as a clean run forever.
fresh
if ! mv "$R" "$H/.cache/tmp-real" || ! ln -s tmp-real "$R"; then fatal "symlink root"; fi
rc="$(run)"
check "a root that is a symlink -> 2, naming it" "$rc:$(grep -c 'is a symlink' "$T/err")" "2:1"
check "... and nothing was deleted" "$(here "$H/.cache/tmp-real/old")" kept
if ! rm "$R" || ! mv "$H/.cache/tmp-real" "$R"; then fatal "restore root"; fi

# The root is read from the config, and the config must stay inside it. One
# config per rule, each refusing for its own reason, named by its own needle.
fresh
grep -v '^d ' "$T/tmpdir.conf" > "$T/c-nod.conf"
sed 's#^d %h/.cache/tmp #d "%h/.cache/tmp" #' "$T/tmpdir.conf" > "$T/c-quoted.conf"
{ cat "$T/tmpdir.conf"; printf 'e %%h/.cache/tmp/%%t - - - amAM:1d\n'; } > "$T/c-spec.conf"
{ cat "$T/tmpdir.conf"; printf 'e %%h/elsewhere - - - amAM:1d\n'; } > "$T/c-out.conf"
# 1d12h is an age systemd-tmpfiles reads; the non-writable-directory pass does not.
{ cat "$T/tmpdir.conf"; printf 'e %%h/.cache/tmp/x - - - amM:1d12h\n'; } > "$T/c-age.conf"
got=""
for c in "nod:has no d line" "quoted:is not an absolute path" "spec:has a specifier" \
         "out:the only tree the worktree guard walks" "age:is not an age this script reads"; do
  got+="$(RUN_CONF="$T/c-${c%%:*}.conf" run):$(grep -c -F "${c#*:}" "$T/err") "
done
check "a config with no d line, a quoted root, a %t, a line outside the root, or an age it cannot read -> 2 each" \
  "$got" "2:1 2:1 2:1 2:1 2:1 "
check "... and nothing was deleted" "$(here "$R/old")" kept

fresh
rc="$(HOME="$H" XDG_CONFIG_HOME="$T/cfg" XDG_STATE_HOME="$T/state" TMPDIR_CLEAN_CONFIG="$T/tmpdir.conf" \
      env -u XDG_RUNTIME_DIR "$SUT" >/dev/null 2>"$T/err"; echo $?)"
check "no XDG_RUNTIME_DIR -> 2, naming it" "$rc:$(grep -c 'XDG_RUNTIME_DIR is not set' "$T/err")" "2:1"
check "... and nothing was deleted" "$(here "$R/old")" kept

printf '\n--dry-run\n'
fresh
rc="$(run --dry-run)"
check "--dry-run with the real systemd-tmpfiles deletes nothing" "$(here "$R/old")" kept
rc="$(STUB_VER=259 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run --dry-run)"
check "--dry-run on systemd 259 passes --dry-run, and only the two files" "$(cat "$T/stub.log")" \
  "--user --clean --dry-run $T/tmpdir.conf $T/run/user-tmpfiles.d/tmpdir-worktrees.conf"
check "... and is logged as a dry run" "$(lastlog)" "mode=dry guarded=1 chmod=0 rc=0 failed=0"
fresh
mkro "$R/dry555" '-10 days' 555
rc="$(STUB_VER=259 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run --dry-run)"
check "--dry-run changes no mode, and prints each directory it would give u+w" \
  "$(mode "$R/dry555"):$(grep -c -x -F "tmpdir-clean: would restore u+w on $R/dry555" "$T/out")" "555:1"
check "... and logs how many it would" "$(lastlog)" "mode=dry guarded=1 chmod=1 rc=0 failed=0"
rc="$(STUB_VER=255 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run --dry-run)"
check "--dry-run on systemd 255 -> 2, naming the version" "$rc:$(grep -c 'needs systemd >= 256' "$T/err")" "2:1"
check "... and systemd-tmpfiles is never asked to clean" "$(grep -c -- --clean "$T/stub.log")" 0
# The age-by field arrived in systemd 249. Older, every line with one fails to
# parse (65, which is otherwise accepted), and each night would clean nothing.
rc="$(STUB_VER=248 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run)"
check "an age-by in the config on systemd 248 -> 2, naming 249, and systemd-tmpfiles is never asked to clean" \
  "$rc:$(grep -c -F 'reads only from systemd 249' "$T/err"):$(grep -c -- --clean "$T/stub.log")" "2:1:0"
noby "$T/tmpdir.conf" > "$T/c-noby.conf"
rc="$(STUB_VER=248 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" RUN_CONF="$T/c-noby.conf" run)"
check "... but a config with no age-by on 248 runs" "$rc:$(grep -c -- --clean "$T/stub.log")" "0:1"

printf '\nexit status\n'
rc="$(STUB_VER=259 STUB_RC=65 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run)"
check "systemd-tmpfiles 65 (an unparseable line) -> 0" "$rc" 0
check "... and says so on stderr" "$(grep -c 'exited 65' "$T/err")" 1
rc="$(STUB_VER=259 STUB_RC=1 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run)"
check "systemd-tmpfiles 1 -> 1" "$rc" 1
# 73 is a warning only for the paths it names (the rows above, with the real
# systemd-tmpfiles). One that names none is not explained by them.
rc="$(STUB_VER=259 STUB_RC=73 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run)"
check "systemd-tmpfiles 73 naming no path it could not remove or open -> 1, saying so" \
  "$rc:$(grep -c -F 'named no path it could not remove or open' "$T/err")" "1:1"
# The root comes from the config's d line, so this one names a directory that
# does not exist while ~/.cache/tmp does: a hardcoded root would run the clean.
sed 's#%h/.cache/tmp#%h/no-such-dir#' "$T/tmpdir.conf" > "$T/c-nodir.conf"
rc="$(STUB_VER=259 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" RUN_CONF="$T/c-nodir.conf" run)"
check "a root (the config's d line) that does not exist -> 0, and nothing runs" "$rc:$(grep -c '' "$T/stub.log")" "0:0"
rc="$(run --nope)"
check "an unknown argument -> 2" "$rc" 2

printf '\n--check (the verify-tools.sh assertion)\n'
mkdir -p "$T/cfg/environment.d"
LOG="$T/state/tmpdir-clean/log"
: > "$LOG"
rc="$(run --check)"
check "no TMPDIR redirect linked -> 0, skipped" "$rc:$(grep -c 'is not linked — skipped' "$T/out")" "0:1"
ln -sf /dev/null "$T/cfg/environment.d/tmpdir.conf"
rc="$(STUB_MANAGER=0 run --check)"
check "linked, no user manager -> 0, skipped" "$rc:$(grep -c 'no systemd user manager reachable' "$T/out")" "0:1"
rc="$(STUB_TIMER=disabled run --check)"
check "linked, timer not enabled -> 1" "$rc" 1
check "... and the line names the timer's state" "$(grep -c 'tmpdir-clean.timer is disabled' "$T/out")" 1
rc="$(STUB_TIMER=disabled TMPDIR_CLEAN_OFF=1 run --check)"
check "linked, timer not enabled, TMPDIR_CLEAN_OFF=1 -> 0, reported as deliberately off" \
  "$rc:$(grep -c 'deliberately off' "$T/out")" "0:1"
rc="$(run --check)"
check "linked, timer enabled -> 0" "$rc" 0
check "... with no warning" "$(grep -c '⚠' "$T/out")" 0
rc="$(STUB_VENDOR=enabled run --check)"
check "the vendor timer enabled too -> still 0, with a warning" "$rc:$(grep -c 'WITHOUT the worktree guard' "$T/out")" "0:1"
# What systemd-tmpfiles could not remove or open stays, so three real cleans in
# a row that each left some are said here too. A dry run is not a clean.
logrun() { printf '2026-10-18T05:15:00Z mode=%s guarded=0 chmod=0 rc=0 failed=%s used=1->1 inodes=1->1 seconds=1\n' "$1" "$2"; }
{ logrun apply 2; logrun dry 0; logrun apply 2; logrun apply 5; } > "$LOG"
rc="$(run --check)"
check "three real cleans in a row each left paths (a dry run between does not count) -> 0, with a warning naming the latest" \
  "$rc:$(grep -c -F '(failed=5 in the latest)' "$T/out")" "0:1"
{ logrun apply 3; logrun apply 0; logrun apply 2; logrun apply 2; } > "$LOG"
rc="$(run --check)"
check "... but not when a clean that left none came between" "$rc:$(grep -c -F 'in the latest' "$T/out")" "0:0"

printf '\n--install (the ./install step)\n'
UD="$T/cfg/systemd/user"
mkdir -p "$UD/default.target.wants" || fatal "unit dir"
enables() { grep -c -E '^systemctl --user enable' "$T/stub.log"; }
rc="$(STUB_TIMER=disabled STUB_ACTIVE=inactive run --install)"
check "no timer linked -> 0, and nothing is enabled" "$rc:$(enables)" "0:0"
ln -s "$HERE/../systemd/tmpdir-clean.timer" "$UD/tmpdir-clean.timer" || fatal "link timer"
rc="$(STUB_TIMER=disabled STUB_ACTIVE=inactive run --install)"
check "linked, not enabled -> enable --now, so it is not left inactive until a reboot" \
  "$rc:$(grep -c -x 'systemctl --user enable --now tmpdir-clean.timer' "$T/stub.log")" "0:1"
rc="$(STUB_TIMER=enabled STUB_ACTIVE=inactive run --install)"
check "enabled but never started (what enable alone left) -> started" \
  "$(grep -c -x 'systemctl --user enable --now tmpdir-clean.timer' "$T/stub.log")" 1
rc="$(STUB_TIMER=disabled STUB_ACTIVE=inactive TMPDIR_CLEAN_OFF=1 run --install)"
check "TMPDIR_CLEAN_OFF=1, not enabled -> left off, and says why" \
  "$rc:$(enables):$(grep -c 'TMPDIR_CLEAN_OFF is set' "$T/out")" "0:0:1"
ln -s ../tmpdir-clean.timer "$UD/default.target.wants/tmpdir-clean.timer" || fatal "link wants"
rc="$(STUB_TIMER=enabled STUB_ACTIVE=active TMPDIR_CLEAN_OFF=1 run --install)"
check "TMPDIR_CLEAN_OFF=1, enabled -> stopped and its .wants link removed, nothing enabled" \
  "$(grep -c -x 'systemctl --user stop tmpdir-clean.timer' "$T/stub.log"):$(lnk "$UD/default.target.wants/tmpdir-clean.timer"):$(enables)" \
  "1:gone:0"
check "... and the unit itself stays linked (systemctl disable would delete it)" "$(lnk "$UD/tmpdir-clean.timer")" kept

EXPECTED_ROWS=101

# --- the count this suite is documented as running ---------------------------
# Same needle as the other suites: docs/REPO_CHECKS.md, "Where a check count lives".
docs_claim() {
  local f="$HERE/../$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-tmpdir-clean.sh\` ($EXPECTED_ROWS checks"
}

printf '\nthe count this suite is documented as running\n'
check "docs/TMPDIR.md says $EXPECTED_ROWS checks" "$(docs_claim docs/TMPDIR.md)" 1
check "a documented file that cannot be read is not a pass" \
      "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
