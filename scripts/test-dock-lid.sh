#!/usr/bin/env bash
#
# scripts/test-dock-lid.sh
# ========================
#
# State table for scripts/setup-dock-lid.sh and the three files it installs:
# logind/lid-on-power.conf, udev/90-dock-lid-holdoff.rules and
# systemd/dock-lid-holdoff.service.
#
# HERMETIC via recording `sudo`, `systemctl`, `busctl`, `udevadm` and
# `systemd-analyze` stubs at the front of PATH. The machine running this has a
# live logind: a row that reached a real `systemctl` with privilege could reload
# or restart it, and restarting logind ends every session. So `systemctl` is only
# ever recorded. The `sudo` stub runs `install` for real, because a row that only
# asserts argv cannot tell an installer that writes the file from one that does
# not, but only under DOCK_LID_SETUP_PREFIX, and it refuses any destination
# outside the prefix by construction.
#
# The checkout under test is COPIED OUT of git for every row that is not about
# the worktree guard, so the suite gives the same answer from a worktree, from
# the primary checkout and from CI.
#
# The last section runs the REAL `udevadm verify` and `systemd-analyze verify`
# against the repo's rule and unit: the stubs prove the installer refuses what
# the parsers reject, and only the real parsers prove the shipped files are not
# rejected.
#
# "Could not run" is exit 2, never a pass. The suite asserts its own row total.
#
# Requires: bash, git, cmp, and systemd >= 254 (`udevadm verify`). No sudo, no
# root, no network.
#
# Usage: scripts/test-dock-lid.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES="$(cd "$HERE/.." && pwd -P)"
SETUP="$HERE/setup-dock-lid.sh"
LOGIND_SRC="$DOTFILES/logind/lid-on-power.conf"
RULE_SRC="$DOTFILES/udev/90-dock-lid-holdoff.rules"
UNIT_SRC="$DOTFILES/systemd/dock-lid-holdoff.service"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for f in "$SETUP" "$LOGIND_SRC" "$RULE_SRC" "$UNIT_SRC"; do
  [[ -r "$f" ]] || fatal "cannot read $f"
done
command -v git >/dev/null || fatal "git is required"
command -v cmp >/dev/null || fatal "cmp is required"
udevadm verify --help >/dev/null 2>&1 || fatal "udevadm has no 'verify' (systemd < 254)"
command -v systemd-analyze >/dev/null || fatal "systemd-analyze is required"

T="$(mktemp -d)" || fatal "mktemp"
trap 'rm -rf "$T"' EXIT
# git must never find a repository above the fixtures, so a row's answer cannot
# depend on where the suite happens to be checked out.
export GIT_CEILING_DIRECTORIES="$T"
STUBBIN="$T/bin"
export STUBLOG="$T/stub.log"
mkdir -p "$STUBBIN" || fatal setup
: >"$STUBLOG"

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
cat >"$STUBBIN/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUBLOG"
# Everything but `install` is recorded and nothing else: systemctl and udevadm
# under sudo are exactly what must never reach the real machine.
[ "${1:-}" = install ] || exit 0
pfx="${DOCK_LID_SETUP_PREFIX:-}"
if [ -z "$pfx" ]; then
  echo "sudo stub: refused (no DOCK_LID_SETUP_PREFIX, so nothing may be written)" >&2
  exit 1
fi
# A RELATIVE prefix confines nothing: `relative/dir/etc/x` is "inside" it and
# lands in whatever directory the caller is sitting in. The first mutation sweep
# wrote a whole /etc tree into the worktree it was run from exactly this way.
case "$pfx" in
  /*) ;;
  *) echo "sudo stub: REFUSED a relative prefix: $pfx" >&2; exit 97 ;;
esac
shift
has_d=0; flags=(); ops=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o | -g) shift 2 ;;   # cannot work unprivileged; the RECORDED argv keeps them
    -m) flags+=("$1" "${2:-}"); shift 2 ;;
    -d) has_d=1; flags+=("$1"); shift ;;
    -*) flags+=("$1"); shift ;;
    *)  ops+=("$1"); shift ;;
  esac
done
# For `install SRC DST` only the last operand is a target; with -d all are.
if [ "$has_d" -eq 0 ] && [ "${#ops[@]}" -gt 1 ]; then
  targets=("${ops[$((${#ops[@]} - 1))]}")
else
  targets=("${ops[@]}")
fi
for t in "${targets[@]}"; do
  case "$t" in
    "$pfx"/*) ;;
    *) echo "sudo stub: REFUSED a destination outside the prefix: $t" >&2; exit 97 ;;
  esac
done
exec install "${flags[@]}" "${ops[@]}"
STUB

cat >"$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STUBLOG"
STUB

# The live HandleLidSwitchExternalPower. STUB_LID_POWER set-but-empty is what an
# un-reloaded logind answers; STUB_BUSCTL_FAIL=1 is a bus that will not answer.
cat >"$STUBBIN/busctl" <<'STUB'
#!/usr/bin/env bash
printf 'busctl %s\n' "$*" >>"$STUBLOG"
[ "${STUB_BUSCTL_FAIL:-0}" = 1 ] && exit 1
printf 's "%s"\n' "${STUB_LID_POWER-ignore}"
STUB

cat >"$STUBBIN/udevadm" <<'STUB'
#!/usr/bin/env bash
printf 'udevadm %s\n' "$*" >>"$STUBLOG"
[ "${1:-}" = verify ] && [ "${STUB_UDEV_VERIFY:-ok}" = fail ] && exit 1
exit 0
STUB

cat >"$STUBBIN/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
printf 'systemd-analyze %s\n' "$*" >>"$STUBLOG"
[ "${1:-}" = verify ] && [ "${STUB_ANALYZE_VERIFY:-ok}" = fail ] && exit 1
exit 0
STUB
chmod +x "$STUBBIN"/* || fatal setup

# A checkout laid out like the repo, holding only what the installer reads.
mkroot() {
  mkdir -p "$1/scripts" "$1/logind" "$1/udev" "$1/systemd" || fatal "mkroot $1"
  if ! { cp "$SETUP" "$1/scripts/" && cp "$LOGIND_SRC" "$1/logind/" \
         && cp "$RULE_SRC" "$1/udev/" && cp "$UNIT_SRC" "$1/systemd/"; }; then
    fatal "mkroot $1"
  fi
}
ROOT="$T/root"; mkroot "$ROOT"

newprefix() { mktemp -d "$T/prefix.XXXXXX" || fatal "mktemp prefix"; }
files_in() { find "$1" -type f | wc -l | tr -d ' '; }
logged()   { grep -c -x -F -- "$1" "$STUBLOG"; }
logged_re() { grep -c -E -- "$1" "$STUBLOG"; }
out_has()  { grep -c -F -- "$1" "$T/out"; }

# run_setup <checkout> <prefix> [args...] — prints the exit status; the output
# lands in $T/out and the stubs' argv in $STUBLOG (cleared first). Variables the
# caller puts in front of it reach the stubs. Runs from inside $T, so nothing a
# row does can land in the directory the suite was started from.
run_setup() {
  local root="$1" pfx="$2"; shift 2
  : >"$STUBLOG"
  ( cd "$T" && PATH="$STUBBIN:$PATH" DOCK_LID_SETUP_PREFIX="$pfx" \
      bash "$root/scripts/setup-dock-lid.sh" "$@" ) >"$T/out" 2>&1
  echo $?
}

# ---------------------------------------------------------------------------
printf '\nthe stubs (a stub that cannot fail is decoration)\n'
check "sudo resolves to the stub" "$(PATH="$STUBBIN:$PATH" bash -c 'command -v sudo')" "$STUBBIN/sudo"
check "systemctl resolves to the stub" "$(PATH="$STUBBIN:$PATH" bash -c 'command -v systemctl')" "$STUBBIN/systemctl"
P="$(newprefix)"
rc="$(PATH="$STUBBIN:$PATH" DOCK_LID_SETUP_PREFIX="$P" sudo install -m 644 "$RULE_SRC" "$T/outside.rules" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a destination outside the prefix" "$rc:$([[ -e $T/outside.rules ]] && echo written || echo absent)" "97:absent"
rc="$(PATH="$STUBBIN:$PATH" DOCK_LID_SETUP_PREFIX='' sudo install -m 644 "$RULE_SRC" "$P/x.rules" >/dev/null 2>&1; echo $?)"
check "with no prefix the sudo stub writes nothing" "$rc:$(files_in "$P")" "1:0"
rc="$(cd "$T" && PATH="$STUBBIN:$PATH" DOCK_LID_SETUP_PREFIX='rel' sudo install -D -m 644 "$RULE_SRC" "rel/x.rules" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a relative prefix, which confines nothing" \
  "$rc:$([[ -e $T/rel ]] && echo written || echo absent)" "97:absent"

# ---------------------------------------------------------------------------
printf '\narguments\n'
check "an unknown argument is exit 2" "$(run_setup "$ROOT" "" --bogus)" 2
rc="$(run_setup "$ROOT" "" --help)"
check "--help is exit 0 and prints the usage" "$rc:$(out_has 'Usage: setup-dock-lid.sh')" "0:1"
check "a relative prefix is refused, exit 2" "$(run_setup "$ROOT" "relative/dir")" 2
check "a prefix that does not exist is refused, exit 2" "$(run_setup "$ROOT" "$T/no/such/dir")" 2

# ---------------------------------------------------------------------------
printf '\ninstall\n'
P="$(newprefix)"
rc="$(run_setup "$ROOT" "$P")"
check "installs, exit 0" "$rc" 0
for pair in "logind/lid-on-power.conf:etc/systemd/logind.conf.d/lid-on-power.conf" \
            "udev/90-dock-lid-holdoff.rules:etc/udev/rules.d/90-dock-lid-holdoff.rules" \
            "systemd/dock-lid-holdoff.service:etc/systemd/system/dock-lid-holdoff.service"; do
  src="${pair%%:*}" dst="${pair#*:}"
  check "/$dst is a byte-identical copy of $src" \
    "$(cmp -s "$ROOT/$src" "$P/$dst" && echo same || echo differs)" same
done
check "each is installed root-owned 0644" "$(logged_re '^sudo install -D -m 644 -o root -g root [^ ]+ [^ ]+$')" 3
check "the system manager re-reads its units" "$(logged 'sudo systemctl daemon-reload')" 1
check "udevd re-reads its rules" "$(logged 'sudo udevadm control --reload')" 1
check "logind is RELOADED, and never restarted (a restart ends every session)" \
  "$(logged 'sudo systemctl reload systemd-logind'):$(logged_re 'restart')" "1:0"
check "the live value is read back and reported" \
  "$(out_has 'logind is running with HandleLidSwitchExternalPower=ignore')" 1
check "a prefixed run says it is not touching the real /etc" "$(out_has 'NOT to the real /etc')" 1

# ---------------------------------------------------------------------------
printf '\nvalidation refuses before anything is written\n'
P="$(newprefix)"
rc="$(STUB_UDEV_VERIFY=fail run_setup "$ROOT" "$P")"
check "a rule udevadm rejects: exit 1, nothing written, no install attempted" \
  "$rc:$(files_in "$P"):$(logged_re '^sudo install')" "1:0:0"
P="$(newprefix)"
rc="$(STUB_ANALYZE_VERIFY=fail run_setup "$ROOT" "$P")"
check "a unit systemd-analyze rejects: exit 1, nothing written, no install attempted" \
  "$rc:$(files_in "$P"):$(logged_re '^sudo install')" "1:0:0"

# ---------------------------------------------------------------------------
printf '\nan install logind has not picked up is not a success\n'
P="$(newprefix)"
rc="$(STUB_LID_POWER='' run_setup "$ROOT" "$P")"
check "files installed but logind not running with the value: exit 1, names the reload" \
  "$rc:$(files_in "$P"):$(out_has 'sudo systemctl reload systemd-logind')" "1:3:1"
P="$(newprefix)"
rc="$(STUB_BUSCTL_FAIL=1 run_setup "$ROOT" "$P")"
check "a bus that will not answer is reported after an install" \
  "$rc:$(out_has "logind is running with HandleLidSwitchExternalPower=''")" "1:1"

# ---------------------------------------------------------------------------
printf '\n--check\n'
P="$(newprefix)"
[[ "$(run_setup "$ROOT" "$P")" == 0 ]] || fatal "--check fixture: the install it checks did not succeed"
rc="$(run_setup "$ROOT" "$P" --check)"
check "a clean install checks clean, exit 0" "$rc" 0
# --check calls the check as a PLAIN command, where set -e is live — the install
# path calls it from an `||` list, where bash suspends set -e, so only this row
# can see a failing busctl end the script with no message.
rc="$(STUB_BUSCTL_FAIL=1 run_setup "$ROOT" "$P" --check)"
check "--check with a bus that will not answer: exit 1 and reported, not a silent exit under set -e" \
  "$rc:$(out_has "logind is running with HandleLidSwitchExternalPower=''")" "1:1"
check "--check writes nothing and runs nothing under sudo" "$(logged_re '^sudo ')" 0
echo '# local edit' >>"$P/etc/udev/rules.d/90-dock-lid-holdoff.rules"
rc="$(run_setup "$ROOT" "$P" --check)"
check "an edited installed copy is drift: exit 1, and it names the file" \
  "$rc:$(grep -c 'rules.d/90-dock-lid-holdoff.rules DIFFERS' "$T/out")" "1:1"
cp "$ROOT/udev/90-dock-lid-holdoff.rules" "$P/etc/udev/rules.d/" || fatal restore
rm -f "$P/etc/systemd/system/dock-lid-holdoff.service"
rc="$(run_setup "$ROOT" "$P" --check)"
check "a missing installed copy: exit 1, and it says not installed" \
  "$rc:$(grep -c 'dock-lid-holdoff.service is not installed' "$T/out")" "1:1"
cp "$ROOT/systemd/dock-lid-holdoff.service" "$P/etc/systemd/system/" || fatal restore
rc="$(STUB_LID_POWER='' run_setup "$ROOT" "$P" --check)"
check "every file matching is not enough: logind not running with it is exit 1" "$rc" 1

# ---------------------------------------------------------------------------
printf '\nthe worktree guard\n'
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
mkroot "$T/repo"
{ "${G[@]}" -C "$T/repo" init -q -b main && "${G[@]}" -C "$T/repo" add -A \
    && "${G[@]}" -C "$T/repo" commit -q -m fixture \
    && "${G[@]}" -C "$T/repo" worktree add -q -b feature "$T/wt"; } >/dev/null 2>&1 \
  || fatal "could not build the worktree fixture"
P="$(newprefix)"
rc="$(run_setup "$T/wt" "$P")"
check "from a worktree: exit 1, nothing written" "$rc:$(files_in "$P")" "1:0"
check "... and the refusal names the remedy" "$(out_has 'cd ~/.dotfiles && dock-lid-setup')" 1
P="$(newprefix)"
rc="$(DOCK_LID_SETUP_ALLOW_WORKTREE=1 run_setup "$T/wt" "$P")"
check "DOCK_LID_SETUP_ALLOW_WORKTREE=1 overrides it" "$rc:$(files_in "$P")" "0:3"
P="$(newprefix)"
rc="$(run_setup "$T/repo" "$P")"
check "the primary checkout of the same repo is not a worktree: installs" "$rc:$(files_in "$P")" "0:3"

# ---------------------------------------------------------------------------
printf '\nthe shipped files, against the real parsers\n'
rc="$(udevadm verify --resolve-names=never "$RULE_SRC" >"$T/out" 2>&1; echo $?)"
check "the real udevadm verify accepts the rule" "$rc" 0
rc="$(systemd-analyze verify --man=no "$UNIT_SRC" >"$T/out" 2>&1; echo $?)"
check "the real systemd-analyze verify accepts the unit" "$rc" 0
check "the rule pulls in the unit by its real file name (a wrong name verifies and never fires)" \
  "$(grep -c -F "ENV{SYSTEMD_WANTS}+=\"$(basename "$UNIT_SRC")\"" "$RULE_SRC")" 1
check "the rule fires on a USB-C partner being added, and on nothing else" \
  "$(grep -v '^#' "$RULE_SRC" | grep -c -F 'ACTION=="add", SUBSYSTEM=="typec", ENV{DEVTYPE}=="typec_partner"')" 1
check "the unit BLOCKS handle-lid-switch (a delay lock would let the suspend through)" \
  "$(grep -c -E '^ExecStart=/usr/bin/systemd-inhibit .*--what=handle-lid-switch .*--mode=block ' "$UNIT_SRC")" 1
check "the logind drop-in is a [Login] section setting HandleLidSwitchExternalPower=ignore" \
  "$(grep -v '^#' "$LOGIND_SRC" | tr '\n' ' ')" "[Login] HandleLidSwitchExternalPower=ignore "

EXPECTED_ROWS=41

# --- the count this suite is documented as running ---------------------------
# Same needle as the other suites: docs/REPO_CHECKS.md, "Where a check count lives".
docs_claim() {
  local f="$HERE/../$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-dock-lid.sh\` ($EXPECTED_ROWS checks"
}

printf '\nthe count this suite is documented as running\n'
check "docs/DOCK_LID_SUSPEND.md says $EXPECTED_ROWS checks" "$(docs_claim docs/DOCK_LID_SUSPEND.md)" 1
check "a documented file that cannot be read is not a pass" \
      "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
