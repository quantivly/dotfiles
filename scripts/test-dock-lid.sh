#!/usr/bin/env bash
#
# scripts/test-dock-lid.sh
# ========================
#
# State table for scripts/setup-dock-lid.sh and the three files it installs:
# logind/lid-on-power.conf, udev/90-dock-lid-holdoff.rules and
# systemd/dock-lid-holdoff@.service.
#
# HERMETIC via `sudo`, `systemctl`, `busctl`, `udevadm` and `systemd-analyze`
# stubs at the front of PATH. The machine running this has a live logind: a row
# that reached a real `systemctl` with privilege could reload or restart it, and
# restarting logind ends every session. So `systemctl` is never executed.
#
# THE STUBS MODEL STATE, not just answers, because a stub that always says
# "ignore" passes an installer that reads the wrong property or reloads logind
# before copying the drop-in (both measured: the first review's mutants
# survived exactly that way). Per prefix, in <prefix>.state/:
#   - `sudo systemctl daemon-reload` snapshots the unit file on disk NOW; the
#     `systemctl show` stub answers LoadState / NeedDaemonReload from it.
#   - `sudo systemctl reload systemd-logind` snapshots the drop-in's value NOW;
#     the `busctl` stub answers from it, and only for
#     HandleLidSwitchExternalPower (HandleLidSwitchDocked defaults to "ignore"
#     too, so reading it would be a false green on a real machine).
# The `sudo` stub runs `install` for real, but only under an ABSOLUTE
# DOCK_LID_SETUP_PREFIX, and refuses any destination outside it.
#
# The checkout under test is COPIED OUT of git for every row that is not about
# the worktree guard, so the suite gives the same answer from a worktree, from
# the primary checkout and from CI. Every row runs from inside the suite's
# temporary directory.
#
# The last section runs the REAL `udevadm verify` and `systemd-analyze verify`
# against the shipped rule and unit, and asserts the rule lines and the unit's
# ExecStart exactly: udevadm verify accepts a rule that never fires.
#
# "Could not run" is exit 2, never a pass. The suite asserts its own row total.
#
# Requires: bash, git, cmp, sha256sum, stat, and systemd >= 254
# (`udevadm verify`). No sudo, no root, no network.
#
# Usage: scripts/test-dock-lid.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES="$(cd "$HERE/.." && pwd -P)"
SETUP="$HERE/setup-dock-lid.sh"
LOGIND_SRC="$DOTFILES/logind/lid-on-power.conf"
RULE_SRC="$DOTFILES/udev/90-dock-lid-holdoff.rules"
UNIT_SRC="$DOTFILES/systemd/dock-lid-holdoff@.service"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for f in "$SETUP" "$LOGIND_SRC" "$RULE_SRC" "$UNIT_SRC"; do
  [[ -r "$f" ]] || fatal "cannot read $f"
done
for t in git cmp sha256sum stat systemd-analyze; do
  command -v "$t" >/dev/null || fatal "$t is required"
done
udevadm verify --help >/dev/null 2>&1 || fatal "udevadm has no 'verify' (systemd < 254)"

T="$(mktemp -d)" || fatal "mktemp"
trap 'rm -rf "$T"' EXIT
# git must never find a repository above the fixtures, so a row's answer cannot
# depend on where the suite happens to be checked out.
export GIT_CEILING_DIRECTORIES="$T"
STUBBIN="$T/bin"
export STUBLOG="$T/stub.log"
mkdir -p "$STUBBIN" || fatal setup
: >"$STUBLOG"
ME="$(id -un):$(id -gn)"

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
cat >"$STUBBIN/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUBLOG"
pfx="${DOCK_LID_SETUP_PREFIX:-}"
state="${pfx}.state"
case "${1:-}" in
  install) ;;
  systemctl)
    # Modelled, never executed (see the header). Without a prefix: recorded only.
    [ -n "$pfx" ] || exit 0
    mkdir -p "$state" || exit 98
    case "${2:-}:${3:-}" in
      daemon-reload:)
        # The manager loads whatever unit file is on disk at this moment.
        f="$pfx/etc/systemd/system/dock-lid-holdoff@.service"
        if [ -f "$f" ]; then sha256sum <"$f" | cut -d' ' -f1 >"$state/unit-loaded"
        else echo absent >"$state/unit-loaded"; fi ;;
      reload:systemd-logind)
        [ "${STUB_LOGIND_RELOAD_FAIL:-0}" = 1 ] && exit 1
        # logind re-reads its drop-ins at this moment: what they say now is live.
        sed -n 's/^HandleLidSwitchExternalPower=//p' \
          "$pfx/etc/systemd/logind.conf.d/lid-on-power.conf" 2>/dev/null | head -1 >"$state/logind-live" ;;
    esac
    exit 0 ;;
  *) exit 0 ;;   # udevadm control --reload and anything else: recorded only
esac
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
[ "${1:-}" = show ] || exit 0
shift
prop=""; unit=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prop="${2:-}"; shift 2 ;;
    --value) shift ;;
    *) unit="$1"; shift ;;
  esac
done
pfx="${DOCK_LID_SETUP_PREFIX:-}"
f="$pfx/etc/systemd/system/dock-lid-holdoff@.service"
loaded="$(cat "${pfx}.state/unit-loaded" 2>/dev/null || echo absent)"
# Only an INSTANCE of the template loads it; the template name itself is refused
# by the real systemctl, and any other unit is not ours.
case "$unit" in dock-lid-holdoff@?*.service) ours=1 ;; *) ours=0 ;; esac
case "$prop" in
  LoadState)
    if [ -n "${STUB_LOADSTATE:-}" ]; then echo "$STUB_LOADSTATE"
    elif [ "$ours" = 1 ] && [ "$loaded" != absent ]; then echo loaded
    else echo not-found; fi ;;
  NeedDaemonReload)
    if [ "$ours" = 1 ] && [ "$loaded" != absent ] && [ -f "$f" ] \
       && [ "$(sha256sum <"$f" | cut -d' ' -f1)" != "$loaded" ]; then echo yes
    else echo no; fi ;;
  *) echo "systemctl stub: unmodelled property '$prop'" >&2; exit 99 ;;
esac
STUB

cat >"$STUBBIN/busctl" <<'STUB'
#!/usr/bin/env bash
printf 'busctl %s\n' "$*" >>"$STUBLOG"
[ "${STUB_BUSCTL_FAIL:-0}" = 1 ] && exit 1
if [ "${1:-}" != get-property ] || [ "${4:-}" != org.freedesktop.login1.Manager ] \
   || [ "${5:-}" != HandleLidSwitchExternalPower ]; then
  echo "busctl stub: unmodelled call: $*" >&2; exit 99
fi
# STUB_LID_POWER set (even to empty) overrides; otherwise what the last reload
# made live, and "" (logind's own default) if logind has never been reloaded.
if [ -n "${STUB_LID_POWER+set}" ]; then v="$STUB_LID_POWER"
else v="$(cat "${DOCK_LID_SETUP_PREFIX:-}.state/logind-live" 2>/dev/null)"; fi
printf 's "%s"\n' "$v"
STUB

cat >"$STUBBIN/udevadm" <<'STUB'
#!/usr/bin/env bash
printf 'udevadm %s\n' "$*" >>"$STUBLOG"
[ "${1:-}" = verify ] || exit 0
[ "${STUB_UDEV_NO_VERIFY:-0}" = 1 ] && { echo "Unknown command verb 'verify'." >&2; exit 1; }
[ "${2:-}" = --help ] && exit 0
if [ "${STUB_UDEV_VERIFY:-ok}" = fail ]; then
  echo "stub-udev: invalid key/value pair, line 30"; exit 1
fi
echo "1 udev rules files have been checked."
STUB

cat >"$STUBBIN/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
printf 'systemd-analyze %s\n' "$*" >>"$STUBLOG"
[ "${1:-}" = verify ] || exit 0
case "${STUB_ANALYZE:-ok}" in
  fail) echo "stub-analyze: Service has no ExecStart= setting. Refusing."; exit 1 ;;
  warn) echo "stub-analyze: Unknown key 'Typo' in section [Service], ignoring." ;;
esac
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
stubs()    { PATH="$STUBBIN:$PATH" "$@"; }

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
printf '\nthe stubs (a stub that cannot fail is decoration; a stub is a claim about the real tool)\n'
check "sudo resolves to the stub" "$(stubs bash -c 'command -v sudo')" "$STUBBIN/sudo"
check "systemctl resolves to the stub" "$(stubs bash -c 'command -v systemctl')" "$STUBBIN/systemctl"
P="$(newprefix)"
rc="$(DOCK_LID_SETUP_PREFIX="$P" stubs sudo install -m 644 "$RULE_SRC" "$T/outside.rules" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a destination outside the prefix" "$rc:$([[ -e $T/outside.rules ]] && echo written || echo absent)" "97:absent"
rc="$(DOCK_LID_SETUP_PREFIX='' stubs sudo install -m 644 "$RULE_SRC" "$P/x.rules" >/dev/null 2>&1; echo $?)"
check "with no prefix the sudo stub writes nothing" "$rc:$(files_in "$P")" "1:0"
rc="$(cd "$T" && DOCK_LID_SETUP_PREFIX='rel' stubs sudo install -D -m 644 "$RULE_SRC" "rel/x.rules" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a relative prefix, which confines nothing" \
  "$rc:$([[ -e $T/rel ]] && echo written || echo absent)" "97:absent"
rc="$(DOCK_LID_SETUP_PREFIX="$P" stubs busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
       org.freedesktop.login1.Manager HandleLidSwitchDocked >/dev/null 2>&1; echo $?)"
check "the busctl stub refuses any property but HandleLidSwitchExternalPower" "$rc" 99
DOCK_LID_SETUP_PREFIX="$P" stubs sudo systemctl reload systemd-logind
check "a logind reload with no drop-in on disk makes nothing live" \
  "$(DOCK_LID_SETUP_PREFIX="$P" stubs busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
       org.freedesktop.login1.Manager HandleLidSwitchExternalPower)" 's ""'

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
            "systemd/dock-lid-holdoff@.service:etc/systemd/system/dock-lid-holdoff@.service"; do
  src="${pair%%:*}" dst="${pair#*:}"
  check "/$dst is a byte-identical copy of $src" \
    "$(cmp -s "$ROOT/$src" "$P/$dst" && echo same || echo differs)" same
done
check "each is installed root-owned 0644" "$(logged_re '^sudo install -m 644 -o root -g root [^ ]+ [^ ]+$')" 3
check "the system manager re-reads its units" "$(logged 'sudo systemctl daemon-reload')" 1
check "udevd re-reads its rules" "$(logged 'sudo udevadm control --reload')" 1
check "logind is RELOADED, and never restarted (a restart ends every session)" \
  "$(logged 'sudo systemctl reload systemd-logind'):$(logged_re 'restart')" "1:0"
check "the live logind value is read back and reported" \
  "$(out_has 'logind is running with HandleLidSwitchExternalPower=ignore')" 1
check "the check asks systemd whether it loaded the CURRENT unit" \
  "$(out_has 'systemd has loaded the current dock-lid-holdoff@.service')" 1
check "a prefixed run says it is not touching the real /etc" "$(out_has 'NOT to the real /etc')" 1

# ---------------------------------------------------------------------------
printf '\nparent directories\n'
P="$(newprefix)"
rc="$(umask 077; run_setup "$ROOT" "$P")"
check "a missing parent is created 0755 under a strict umask (0700 would make --check a false red)" \
  "$rc:$(stat -c %a "$P/etc/systemd/logind.conf.d")" "0:755"
P="$(newprefix)"
install -d -m 700 "$P/etc/systemd/system" || fatal "parent fixture"
rc="$(run_setup "$ROOT" "$P")"
check "an existing parent is left alone: not chmod-ed, not re-created" \
  "$rc:$(stat -c %a "$P/etc/systemd/system"):$(logged_re '^sudo install -d .*/etc/systemd/system$')" "0:700:0"

# ---------------------------------------------------------------------------
printf '\nvalidation refuses before anything is written, and says why\n'
P="$(newprefix)"
rc="$(STUB_UDEV_VERIFY=fail run_setup "$ROOT" "$P")"
check "a rule udevadm rejects: exit 1, nothing written, no install attempted" \
  "$rc:$(files_in "$P"):$(logged_re '^sudo install')" "1:0:0"
check "... and udevadm's own explanation is printed" "$(out_has 'stub-udev: invalid key/value pair, line 30')" 1
P="$(newprefix)"
rc="$(STUB_ANALYZE=fail run_setup "$ROOT" "$P")"
check "a unit systemd-analyze rejects: exit 1, nothing written, no install attempted" \
  "$rc:$(files_in "$P"):$(logged_re '^sudo install')" "1:0:0"
check "... and systemd-analyze's own explanation is printed" "$(out_has 'stub-analyze: Service has no ExecStart')" 1
P="$(newprefix)"
rc="$(STUB_ANALYZE=warn run_setup "$ROOT" "$P")"
check "a verify that exits 0 with a WARNING (an unknown key) is a rejection too" \
  "$rc:$(files_in "$P"):$(out_has "Unknown key 'Typo'")" "1:0:1"
P="$(newprefix)"
rc="$(STUB_UDEV_NO_VERIFY=1 run_setup "$ROOT" "$P")"
check "an udevadm with no 'verify' is named as that, not as a rejected rule" \
  "$rc:$(files_in "$P"):$(out_has "has no 'verify' (systemd < 254)"):$(out_has 'rejects')" "1:0:1:0"

# ---------------------------------------------------------------------------
printf '\nan install logind has not picked up is not a success\n'
P="$(newprefix)"
rc="$(STUB_LOGIND_RELOAD_FAIL=1 run_setup "$ROOT" "$P")"
check "logind cannot reload: files installed, but exit 1, and it names the reload" \
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
check "--check writes nothing and runs nothing under sudo" "$(logged_re '^sudo ')" 0
# --check calls the check as a PLAIN command, where set -e is live — the install
# path calls it from an `||` list, where bash suspends set -e, so only this row
# can see a failing busctl end the script with no message.
rc="$(STUB_BUSCTL_FAIL=1 run_setup "$ROOT" "$P" --check)"
check "--check with a bus that will not answer: exit 1 and reported, not a silent exit under set -e" \
  "$rc:$(out_has "logind is running with HandleLidSwitchExternalPower=''")" "1:1"
echo '# local edit' >>"$P/etc/udev/rules.d/90-dock-lid-holdoff.rules"
rc="$(run_setup "$ROOT" "$P" --check)"
check "an edited installed copy is drift: exit 1, and it names the file" \
  "$rc:$(grep -c 'rules.d/90-dock-lid-holdoff.rules DIFFERS' "$T/out")" "1:1"
rm -f "$P/etc/udev/rules.d/90-dock-lid-holdoff.rules"
ln -s "$ROOT/udev/90-dock-lid-holdoff.rules" "$P/etc/udev/rules.d/90-dock-lid-holdoff.rules" || fatal symlink
rc="$(run_setup "$ROOT" "$P" --check)"
check "a SYMLINK back into the checkout is refused, though its bytes match" \
  "$rc:$(grep -c 'rules.d/90-dock-lid-holdoff.rules is a SYMLINK' "$T/out")" "1:1"
rm -f "$P/etc/udev/rules.d/90-dock-lid-holdoff.rules"
install -m 644 "$ROOT/udev/90-dock-lid-holdoff.rules" "$P/etc/udev/rules.d/" || fatal restore
chmod 666 "$P/etc/systemd/logind.conf.d/lid-on-power.conf" || fatal chmod
rc="$(run_setup "$ROOT" "$P" --check)"
check "a world-writable copy is refused, though its bytes match" \
  "$rc:$(grep -c "lid-on-power.conf is $ME 666, not $ME 644" "$T/out")" "1:1"
chmod 644 "$P/etc/systemd/logind.conf.d/lid-on-power.conf" || fatal chmod
rm -f "$P/etc/systemd/system/dock-lid-holdoff@.service"
rc="$(run_setup "$ROOT" "$P" --check)"
check "a missing installed copy: exit 1, and it says not installed" \
  "$rc:$(grep -c 'dock-lid-holdoff@.service is not installed' "$T/out")" "1:1"
install -m 644 "$ROOT/systemd/dock-lid-holdoff@.service" "$P/etc/systemd/system/" || fatal restore
rc="$(run_setup "$ROOT" "$P" --check)"
check "(fixture) the restored prefix checks clean again" "$rc" 0
rc="$(STUB_LOADSTATE=not-found run_setup "$ROOT" "$P" --check)"
check "every file matching but systemd unable to load the unit: exit 1, names LoadState" \
  "$rc:$(out_has 'LoadState=not-found')" "1:1"
rc="$(STUB_LID_POWER='' run_setup "$ROOT" "$P" --check)"
check "every file matching but logind not running with the value: exit 1" "$rc" 1
R2="$T/root2"; mkroot "$R2"
P="$(newprefix)"
[[ "$(run_setup "$R2" "$P")" == 0 ]] || fatal "NeedDaemonReload fixture"
echo '# edited after the reload' | tee -a "$R2/systemd/dock-lid-holdoff@.service" \
  >>"$P/etc/systemd/system/dock-lid-holdoff@.service"
rc="$(run_setup "$R2" "$P" --check)"
check "copy matches the checkout but systemd still runs the old one: exit 1, names NeedDaemonReload" \
  "$rc:$(out_has 'NeedDaemonReload=yes')" "1:1"

# ---------------------------------------------------------------------------
printf '\nthe worktree guard\n'
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
mkroot "$T/repo"
{ "${G[@]}" -C "$T/repo" init -q -b main && "${G[@]}" -C "$T/repo" add -A \
    && "${G[@]}" -C "$T/repo" commit -q -m fixture \
    && "${G[@]}" -C "$T/repo" worktree add -q -b feature "$T/wt" \
    && "${G[@]}" clone -q --bare "$T/repo" "$T/bare.git" \
    && "${G[@]}" -C "$T/bare.git" worktree add -q -b other "$T/barewt"; } >/dev/null 2>&1 \
  || fatal "could not build the worktree fixtures"
P="$(newprefix)"
rc="$(run_setup "$T/wt" "$P")"
check "from a worktree: exit 1, nothing written" "$rc:$(files_in "$P")" "1:0"
check "... and the refusal names the remedy" "$(out_has 'cd ~/.dotfiles && dock-lid-setup')" 1
P="$(newprefix)"
rc="$(run_setup "$T/barewt" "$P")"
check "a worktree of a BARE repository is refused too (its git-dir has no /.git/worktrees/)" \
  "$rc:$(files_in "$P")" "1:0"
P="$(newprefix)"
rc="$(DOCK_LID_SETUP_ALLOW_WORKTREE=1 run_setup "$T/wt" "$P")"
check "DOCK_LID_SETUP_ALLOW_WORKTREE=1 overrides it" "$rc:$(files_in "$P")" "0:3"
P="$(newprefix)"
rc="$(run_setup "$T/repo" "$P")"
check "the primary checkout of the same repo is not a worktree: installs" "$rc:$(files_in "$P")" "0:3"

# ---------------------------------------------------------------------------
printf '\nthe shipped files, against the real parsers and exactly\n'
rc="$(udevadm verify --resolve-names=never "$RULE_SRC" >"$T/out" 2>&1; echo $?)"
check "the real udevadm verify accepts the rule" "$rc" 0
out="$(systemd-analyze verify --man=no "$UNIT_SRC" 2>&1)"; rc=$?
check "the real systemd-analyze verify accepts the unit and prints nothing" "$rc:[$out]" "0:[]"
# Both rule lines exactly. udevadm verify accepts all of: no TAG+="systemd" (PID 1
# never sees the device), a wrong unit name, an extra match that never holds.
# shellcheck disable=SC2016  # $env{SEQNUM} is udev's substitution, not the shell's
want_rules='ACTION=="add", SUBSYSTEM=="typec", ENV{DEVTYPE}=="typec_partner", TAG+="systemd", ENV{SYSTEMD_WANTS}+="dock-lid-holdoff@%k-$env{SEQNUM}.service"
ACTION=="change", SUBSYSTEM=="power_supply", ENV{POWER_SUPPLY_TYPE}=="Mains|USB", ENV{POWER_SUPPLY_ONLINE}=="0", RUN+="/usr/bin/busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.DBus.Peer Ping"'
check "the rule file is exactly the two rules: holdoff per USB-C plug-in, and a logind re-check on power loss" \
  "$(grep -v '^#' "$RULE_SRC")" "$want_rules"
check "the rule pulls in the template that ships (a wrong name verifies and never fires)" \
  "$(basename "$UNIT_SRC")" "dock-lid-holdoff@.service"
check "the unit BLOCKS handle-lid-switch for 30 s, the whole ExecStart line" \
  "$(grep '^ExecStart=' "$UNIT_SRC")" \
  'ExecStart=/usr/bin/systemd-inhibit --what=handle-lid-switch --mode=block --who=dock-lid-holdoff --why="USB-C device connecting (%i)" /usr/bin/sleep 30'
check "the logind drop-in is a [Login] section setting HandleLidSwitchExternalPower=ignore" \
  "$(grep -v '^#' "$LOGIND_SRC" | tr '\n' ' ')" "[Login] HandleLidSwitchExternalPower=ignore "

EXPECTED_ROWS=56

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
