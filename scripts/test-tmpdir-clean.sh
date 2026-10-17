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
#   * The config is DERIVED from config/user-tmpfiles.d/tmpdir.conf with an
#     `amAM:` age-by prefix on each age. By default systemd-tmpfiles also counts
#     btime and (for files) ctime, and neither can be backdated, so a fixture
#     built now is never old. The derivation is asserted to change exactly the
#     two age fields and nothing else, so the paths and ages under test are the
#     shipped ones.
#
# The rows that need a version or an exit status systemd-tmpfiles will not give
# on demand (--dry-run on systemd < 256, exit 65) use a recording stub through
# TMPDIR_CLEAN_TMPFILES. --check runs behind a systemctl stub at the front of
# PATH, never against a runner that happens to have no user manager.
#
# "Could not run" is exit 2, never a pass.
#
# Usage: scripts/test-tmpdir-clean.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${SUT:-$HERE/tmpdir-clean.sh}"
SHIPPED="${SHIPPED:-$HERE/../config/user-tmpfiles.d/tmpdir.conf}"

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
sed -E 's/^([de] .*[[:space:]])([0-9]+d)$/\1amAM:\2/' "$SHIPPED" > "$T/tmpdir.conf" || fatal "derive"
[[ "$(diff "$SHIPPED" "$T/tmpdir.conf" | grep -c '^>')" == "$(grep -c '^[de] ' "$SHIPPED")" ]] \
  || fatal "deriving the test config did not prefix every age field"
[[ "$(sed 's/amAM://' "$T/tmpdir.conf")" == "$(cat "$SHIPPED")" ]] \
  || fatal "the derived test config differs from the shipped one by more than the age-by prefix"

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
cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --user ]] || exit 1
case "$2" in
  show-environment) [[ "${STUB_MANAGER:-1}" == 1 ]] ;;
  is-enabled)
    case "$3" in
      tmpdir-clean.timer)           printf '%s\n' "${STUB_TIMER:-enabled}"; [[ "${STUB_TIMER:-enabled}" == enabled ]] ;;
      systemd-tmpfiles-clean.timer) printf '%s\n' "${STUB_VENDOR:-disabled}"; [[ "${STUB_VENDOR:-disabled}" == enabled ]] ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin/tmpfiles-stub" "$T/bin/systemctl" || fatal "setup"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

# A host repository with one commit, and a worktree of it at $2.
host() { mkdir -p "$1" && g -C "$1" init -q && echo h > "$1/README" && g -C "$1" add README && g -C "$1" commit -qm i; }
worktree() { g -C "$1" worktree add -q --detach "$2" || fatal "git worktree add $2"; echo dirty > "$2/uncommitted"; }

# The baseline tree. Everything is made 10 days old, then the exceptions.
fresh() {
  chmod -R u+rwx "$R" "$T/hosts" 2>/dev/null
  rm -rf "$R" "$T/hosts" "$T/run" && mkdir -p "$R/claude-$U/s" "$T/hosts" "$T/run" || fatal "fresh"
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

run() {  # run [args...] — env overrides come from the caller
  : > "$T/stub.log"
  HOME="$H" XDG_RUNTIME_DIR="$T/run" XDG_CONFIG_HOME="$T/cfg" XDG_STATE_HOME="$T/state" \
  TMPDIR_CLEAN_CONFIG="$T/tmpdir.conf" STUB_LOG="$T/stub.log" PATH="$T/bin:$PATH" \
    "$SUT" "$@" >"$T/out" 2>"$T/err"
  echo $?
}
guard() { cat "$T/run/user-tmpfiles.d/tmpdir-worktrees.conf" 2>/dev/null; }
here() { [[ -e "$1" ]] && echo kept || echo gone; }
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
check "the run is logged with its mode, guard count and status" "$(lastlog)" "mode=apply guarded=1 rc=0"

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

printf '\nrefusals delete nothing\n'
fresh
worktree "$T/hosts/out" "$R/wt sp"
rc="$(run)"
check "a worktree path with a space -> 2, naming the path" "$rc:$(grep -c -F 'sp has a path an x line' "$T/err")" "2:1"
check "... and nothing was deleted" "$(here "$R/old")" kept

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

fresh
mkdir "$R/locked" && chmod 000 "$R/locked"
rc="$(run)"
check "a find error -> 2, naming find" "$rc:$(grep -c 'find exited' "$T/err")" "2:1"
check "... and nothing was deleted" "$(here "$R/old")" kept
chmod 700 "$R/locked"

fresh
mkdir -p "$R/x" && echo 'gitdir: /nowhere' > "$R/x/.git" && chmod 000 "$R/x/.git"
rc="$(run)"
check "an unreadable .git file -> 2, naming it" "$rc:$(grep -c -F "cannot read $R/x/.git" "$T/err")" "2:1"
check "... and nothing was deleted" "$(here "$R/old")" kept
chmod 600 "$R/x/.git"

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
check "... and is logged as a dry run" "$(lastlog)" "mode=dry guarded=1 rc=0"
rc="$(STUB_VER=255 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run --dry-run)"
check "--dry-run on systemd 255 -> 2, naming the version" "$rc:$(grep -c 'needs systemd >= 256' "$T/err")" "2:1"
check "... and systemd-tmpfiles is never asked to clean" "$(grep -c -- --clean "$T/stub.log")" 0

printf '\nexit status\n'
rc="$(STUB_VER=259 STUB_RC=65 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run)"
check "systemd-tmpfiles 65 (an unparseable line) -> 0" "$rc" 0
check "... and says so on stderr" "$(grep -c 'exited 65' "$T/err")" 1
rc="$(STUB_VER=259 STUB_RC=1 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" run)"
check "systemd-tmpfiles 1 -> 1" "$rc" 1
rc="$(STUB_VER=259 TMPDIR_CLEAN_TMPFILES="$T/bin/tmpfiles-stub" TMPDIR_CLEAN_ROOT="$T/no-such-dir" run)"
check "a root that does not exist -> 0, and nothing runs" "$rc:$(grep -c '' "$T/stub.log")" "0:0"
rc="$(run --nope)"
check "an unknown argument -> 2" "$rc" 2

printf '\n--check (the verify-tools.sh assertion)\n'
mkdir -p "$T/cfg/environment.d"
rc="$(run --check)"
check "no TMPDIR redirect linked -> 0, skipped" "$rc:$(grep -c 'skipped' "$T/out")" "0:1"
ln -sf /dev/null "$T/cfg/environment.d/tmpdir.conf"
rc="$(STUB_MANAGER=0 run --check)"
check "linked, no user manager -> 0, skipped" "$rc:$(grep -c 'skipped' "$T/out")" "0:1"
rc="$(STUB_TIMER=disabled run --check)"
check "linked, timer not enabled -> 1" "$rc" 1
check "... and the line names the timer's state" "$(grep -c 'tmpdir-clean.timer is disabled' "$T/out")" 1
rc="$(run --check)"
check "linked, timer enabled -> 0" "$rc" 0
check "... with no warning" "$(grep -c '⚠' "$T/out")" 0
rc="$(STUB_VENDOR=enabled run --check)"
check "the vendor timer enabled too -> still 0, with a warning" "$rc:$(grep -c 'WITHOUT the worktree guard' "$T/out")" "0:1"

EXPECTED_ROWS=43

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
