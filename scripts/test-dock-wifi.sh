#!/usr/bin/env bash
#
# scripts/test-dock-wifi.sh
# =========================
#
# State table for scripts/dock-wifi.sh (the behaviour), scripts/setup-dock-wifi.sh
# (the installer) and the two files it ships: networkmanager/50-dock-wifi and
# systemd/dock-wifi-sync.service.
#
# HERMETIC in one way that matters more than the others: `nmcli` is a STATEFUL
# stub (a device table and a radio state under a directory the row chooses).
# A row that reached the real nmcli would cut this laptop's Wi-Fi mid-suite.
# `sudo`, `systemctl` and `systemd-analyze` are the stubs of test-dock-lid.sh,
# adapted: the sudo stub runs `install` for real but only under an ABSOLUTE
# DOCK_WIFI_SETUP_PREFIX, refuses any destination outside it, and models what
# `systemctl enable/disable` leave behind so --check can read it back. The last
# section runs the REAL `systemd-analyze verify` against the shipped unit and
# asserts the shim and the unit's lines exactly.
#
# "Could not run" is exit 2, never a pass. The suite asserts its own row total.
#
# Requires: bash, git, cmp, stat, systemd-analyze. No sudo, no root, no network.
#
# Usage: scripts/test-dock-wifi.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DOTFILES="$(cd "$HERE/.." && pwd -P)"
SCRIPT="${DOCK_WIFI_SH:-$HERE/dock-wifi.sh}"
SETUP="$HERE/setup-dock-wifi.sh"
SHIM_SRC="$DOTFILES/networkmanager/50-dock-wifi"
UNIT_SRC="$DOTFILES/systemd/dock-wifi-sync.service"

PASS=0; FAIL=0
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — expected '$3', got '$2'"; fi; }
fatal() { printf '\033[1;31mFATAL\033[0m: %s\n' "$*" >&2; exit 2; }

for f in "$SCRIPT" "$SETUP" "$SHIM_SRC" "$UNIT_SRC"; do
  [[ -r "$f" ]] || fatal "cannot read $f"
done
for t in git cmp stat systemd-analyze; do
  command -v "$t" >/dev/null || fatal "$t is required"
done

T="$(mktemp -d)" || fatal "mktemp"
trap 'rm -rf "$T"' EXIT
export GIT_CEILING_DIRECTORIES="$T"
STUBBIN="$T/bin"
export STUBLOG="$T/stub.log"
mkdir -p "$STUBBIN" || fatal setup
: >"$STUBLOG"
ME="$(id -un):$(id -gn)"

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
# nmcli: a device table and a radio state under NMCLI_STATE; `radio wifi on|off`
# WRITES the state and is logged, so a row can count the writes and read the
# result. Anything not modelled is exit 99, never a guess.
cat >"$STUBBIN/nmcli" <<'STUB'
#!/usr/bin/env bash
printf 'nmcli %s\n' "$*" >>"${STUBLOG:?}"
st="${NMCLI_STATE:?}"
[ "${STUB_NMCLI_FAIL:-0}" = 1 ] && { echo "Error: NetworkManager is not running." >&2; exit 8; }
case "$*" in
  "-t -f DEVICE,TYPE,STATE device")
    [ "${STUB_NMCLI_FAIL:-0}" = device ] && { echo "Error: could not list devices." >&2; exit 8; }
    cat "$st/devices" ;;
  "radio wifi")     cat "$st/radio" ;;
  "radio wifi on")  echo enabled  >"$st/radio" ;;
  "radio wifi off") echo disabled >"$st/radio" ;;
  *) echo "nmcli stub: unmodelled call: $*" >&2; exit 99 ;;
esac
STUB

cat >"$STUBBIN/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$STUBLOG"
pfx="${DOCK_WIFI_SETUP_PREFIX:-}"
state="${pfx}.state"
case "${1:-}" in
  install) ;;
  systemctl)
    [ -n "$pfx" ] || exit 0
    mkdir -p "$state" || exit 98
    case "${2:-}:${3:-}" in
      enable:dock-wifi-sync.service)  : >"$state/enabled" ;;
      disable:dock-wifi-sync.service) rm -f "$state/enabled" ;;
    esac
    exit 0 ;;
  nmcli) shift; exec nmcli "$@" ;;              # the converge/remove step: the stateful stub answers
  rm)
    [ -n "$pfx" ] || { echo "sudo stub: refused rm with no prefix" >&2; exit 1; }
    shift; for a in "$@"; do case "$a" in -*) ;; "$pfx"/*) ;; *) echo "sudo stub: REFUSED rm outside the prefix: $a" >&2; exit 97 ;; esac; done
    exec rm "$@" ;;
  "$pfx"/usr/local/bin/dock-wifi.sh)
    [ -n "$pfx" ] || exit 0
    exec bash "$@" ;;                           # the installed copy, run under the stub nmcli
  *) exit 0 ;;
esac
if [ -z "$pfx" ]; then
  echo "sudo stub: refused (no DOCK_WIFI_SETUP_PREFIX, so nothing may be written)" >&2
  exit 1
fi
case "$pfx" in
  /*) ;;
  *) echo "sudo stub: REFUSED a relative prefix: $pfx" >&2; exit 97 ;;
esac
shift
has_d=0; flags=(); ops=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o | -g) shift 2 ;;
    -m) flags+=("$1" "${2:-}"); shift 2 ;;
    -d) has_d=1; flags+=("$1"); shift ;;
    -*) flags+=("$1"); shift ;;
    *)  ops+=("$1"); shift ;;
  esac
done
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
pfx="${DOCK_WIFI_SETUP_PREFIX:-}"
state="${pfx}.state"
case "${1:-}" in
  show)
    shift; prop=""; unit=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -p) prop="${2:-}"; shift 2 ;;
        --value) shift ;;
        *) unit="$1"; shift ;;
      esac
    done
    case "$prop" in
      LoadState)
        if [ -n "${STUB_LOADSTATE:-}" ]; then echo "$STUB_LOADSTATE"
        elif [ "$unit" = dock-wifi-sync.service ] && [ -f "$pfx/etc/systemd/system/dock-wifi-sync.service" ]; then echo loaded
        else echo not-found; fi ;;
      *) echo "systemctl stub: unmodelled property '$prop'" >&2; exit 99 ;;
    esac ;;
  is-enabled)
    if [ -n "${STUB_ENABLED:-}" ]; then v="$STUB_ENABLED"
    elif [ -f "$state/enabled" ]; then v=enabled; else v=disabled; fi
    echo "$v"; [ "$v" = enabled ] ;;
  *) exit 0 ;;
esac
STUB

cat >"$STUBBIN/systemd-analyze" <<'STUB'
#!/usr/bin/env bash
printf 'systemd-analyze %s\n' "$*" >>"$STUBLOG"
[ "${1:-}" = verify ] || exit 0
unit="${*: -1}" recursive=1
case " $* " in *" --recursive-errors=no "*) recursive=0 ;; esac
case "${STUB_ANALYZE:-ok}" in
  fail) echo "$unit: Service has no ExecStart= setting. Refusing."; exit 1 ;;
  warn) echo "$unit:9: Unknown key 'Typo' in section [Service], ignoring." ;;
  warn-other) echo "/etc/systemd/system/other.timer:3: Unknown key 'Foo' in section [Timer], ignoring." ;;
  fail-other) echo "/etc/systemd/system/other.service: Unit has no ExecStart= setting."
              [ "$recursive" = 1 ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$STUBBIN"/* || fatal setup

# A world for the nmcli stub: <devices as DEVICE:TYPE:STATE lines, '|'-separated> <enabled|disabled>
world() {
  local d; d="$(mktemp -d "$T/world.XXXXXX")" || fatal "mktemp world"
  tr '|' '\n' <<<"$1" >"$d/devices"
  printf '%s\n' "$2" >"$d/radio"
  printf '%s\n' "$d"
}
WIRED_UP='lo:loopback:unmanaged|enx8c3b4a256b7a:ethernet:connected|wlp0s20f3:wifi:connected|docker0:bridge:connected'
WIRED_DOWN='lo:loopback:unmanaged|enx8c3b4a256b7a:ethernet:disconnected|wlp0s20f3:wifi:connected'
NO_WIRED='lo:loopback:unmanaged|wlp0s20f3:wifi:connected|tun0:tun:connected'
VETH_ONLY='lo:loopback:unmanaged|veth1a2b:ethernet:unmanaged|veth3c4d:ethernet:unmanaged|wlp0s20f3:wifi:connected'
radio_of()  { cat "$1/radio"; }
writes()    { grep -c -E '^nmcli radio wifi (on|off)$' "$STUBLOG"; }
nmcli_calls() { grep -c '^nmcli' "$STUBLOG"; }
# run_script <world> [args...] -> OUT, RC; the stub nmcli is the only one on PATH
run_script() {
  local w="$1"; shift
  : >"$STUBLOG"
  OUT="$(cd "$T" && NMCLI_STATE="$w" PATH="$STUBBIN:$PATH" bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
want_rc()  { if [[ "$RC" == "$2" ]]; then ok "$1"; else bad "$1 — expected exit $2, got $RC"; fi; }
want_out() { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1 — expected output to contain '$2', got: $OUT"; fi; }

# ---------------------------------------------------------------------------
printf '\nthe stubs (a stub that cannot fail is decoration)\n'
check "nmcli resolves to the stub" "$(PATH="$STUBBIN:$PATH" bash -c 'command -v nmcli')" "$STUBBIN/nmcli"
W="$(world "$WIRED_UP" enabled)"
rc="$(NMCLI_STATE="$W" PATH="$STUBBIN:$PATH" nmcli device wifi list >/dev/null 2>&1; echo $?)"
check "the nmcli stub refuses an unmodelled call (exit 99)" "$rc" 99
NMCLI_STATE="$W" PATH="$STUBBIN:$PATH" nmcli radio wifi off >/dev/null
check "the nmcli stub's radio writes are real state" "$(radio_of "$W")" disabled

# ---------------------------------------------------------------------------
printf '\ndock-wifi.sh --sync: a pure function of what NetworkManager reports\n'
W="$(world "$WIRED_UP" enabled)"; run_script "$W" --sync
want_rc  "wired connected, wifi on: exit 0" 0
check "wired connected, wifi on: ONE write, radio wifi off" "$(writes):$(grep -c '^nmcli radio wifi off$' "$STUBLOG")" "1:1"
check "...and the radio is now disabled" "$(radio_of "$W")" disabled
want_out "...and the deciding device is named" "wifi off (wired: enx8c3b4a256b7a)"
W="$(world "$NO_WIRED" disabled)"; run_script "$W" --sync
check "no wired, wifi off: ONE write, radio wifi on" "$(writes):$(grep -c '^nmcli radio wifi on$' "$STUBLOG")" "1:1"
check "...and the radio is now enabled" "$(radio_of "$W")" enabled
W="$(world "$WIRED_UP" disabled)"; run_script "$W" --sync
want_rc  "wired connected, wifi already off: exit 0" 0
check "...ZERO writes (idempotent: the down event the toggle causes re-enters harmlessly)" "$(writes)" 0
want_out "...and says so" "wifi already off"
W="$(world "$NO_WIRED" enabled)"; run_script "$W" --sync
check "no wired, wifi already on: zero writes" "$(writes)" 0
W="$(world "$VETH_ONLY" enabled)"; run_script "$W" --sync
check "docker's veths are ethernet but UNMANAGED: not a wired uplink, wifi stays on" "$(writes):$(radio_of "$W")" "0:enabled"
W="$(world "$WIRED_DOWN" disabled)"; run_script "$W" --sync
check "a wired device present but DISCONNECTED (cable out) is no uplink: wifi on" "$(radio_of "$W")" enabled
W="$(world 'enx8c3b4a256b7a:ethernet:connected|wlp0s20f3:wifi:unavailable' disabled)"; run_script "$W" --sync
check "the wifi device's own state is irrelevant (it is unavailable while the radio is off)" "$(writes)" 0
W="$(world "$WIRED_UP" enabled)"; STUB_NMCLI_FAIL=1 run_script "$W" --sync
want_rc  "nmcli failing: COULD NOT RUN (exit 2)" 2
check "...and the radio is left alone" "$(writes):$(radio_of "$W")" "0:enabled"
# The device listing failing ALONE, with the radio still answering: a failed read must never
# read as "no wired device" and turn the radio on under a docked laptop (mutant E11 survived
# the row above because the stub failed every call, so the radio read failed too).
W="$(world "$WIRED_UP" disabled)"; STUB_NMCLI_FAIL=device run_script "$W" --sync
want_rc  "only the device listing failing: still COULD NOT RUN (exit 2)" 2
check "...and the radio stays off (a failed read is not 'no wired device')" "$(writes):$(radio_of "$W")" "0:disabled"
NONMCLI="$T/nonmcli"; mkdir -p "$NONMCLI"; ln -sf "$(command -v awk)" "$NONMCLI/awk"
W="$(world "$WIRED_UP" enabled)"
BASH_BIN="$(command -v bash)"
OUT="$(cd "$T" && NMCLI_STATE="$W" PATH="$NONMCLI" "$BASH_BIN" "$SCRIPT" --sync 2>&1)"; RC=$?
want_rc "nmcli missing from PATH: COULD NOT RUN (exit 2)" 2
check "...and the radio is untouched" "$(radio_of "$W")" enabled
W="$(world 'wlp0s20f3:wifi:connected|enx8c3b4a256b7a:ethernet:connected' enabled)"; run_script "$W" --sync
check "the first connected ethernet device decides, whatever row order NetworkManager prints" "$(radio_of "$W")" disabled

printf '\ndock-wifi.sh --status and --dispatch\n'
W="$(world "$WIRED_UP" enabled)"; run_script "$W" --status
want_rc  "status: exit 0" 0
want_out "status: names the wired device" "wired:  enx8c3b4a256b7a"
want_out "status: the radio as it is" "wifi:   on"
want_out "status: the state it should be in" "wanted: off"
check "status writes nothing" "$(writes)" 0
W="$(world "$WIRED_UP" enabled)"; run_script "$W" --dispatch enx8c3b4a256b7a up
check "dispatch up: converges (one write)" "$(writes)" 1
W="$(world "$WIRED_DOWN" disabled)"; run_script "$W" --dispatch enx8c3b4a256b7a down
check "dispatch down after unplugging: wifi back on" "$(radio_of "$W")" enabled
W="$(world "$WIRED_UP" enabled)"; run_script "$W" --dispatch wlp0s20f3 connectivity-change
check "dispatch connectivity-change: converges" "$(writes)" 1
W="$(world "$WIRED_UP" enabled)"; run_script "$W" --dispatch enx8c3b4a256b7a dhcp4-change
check "dispatch dhcp4-change: converges" "$(writes)" 1
W="$(world "$WIRED_UP" enabled)"; run_script "$W" --dispatch wlp0s20f3 hostname
want_rc  "dispatch hostname: exit 0" 0
check "...and asks nmcli NOTHING (no uplink can change on that event)" "$(nmcli_calls)" 0
W="$(world "$WIRED_UP" enabled)"; run_script "$W" --dispatch tun0 vpn-up
check "dispatch vpn-up: nothing asked" "$(nmcli_calls)" 0
W="$(world "$WIRED_UP" enabled)"; run_script "$W" --dispatch enx8c3b4a256b7a dhcp6-change
check "dispatch dhcp6-change: nothing asked" "$(nmcli_calls)" 0
run_script "$W" --bogus
want_rc  "an unknown mode is exit 2" 2
run_script "$W" --help
want_rc  "--help exits 0" 0
want_out "--help prints the usage" "Usage"

# ---------------------------------------------------------------------------
# A checkout laid out like the repo, holding only what the installer reads.
mkroot() {
  mkdir -p "$1/scripts" "$1/networkmanager" "$1/systemd" || fatal "mkroot $1"
  if ! { cp "$SETUP" "$1/scripts/" && cp "$SCRIPT" "$1/scripts/dock-wifi.sh" \
         && cp "$SHIM_SRC" "$1/networkmanager/" && cp "$UNIT_SRC" "$1/systemd/"; }; then
    fatal "mkroot $1"
  fi
}
ROOT="$T/root"; mkroot "$ROOT"
newprefix() { mktemp -d "$T/prefix.XXXXXX" || fatal "mktemp prefix"; }
files_in() { find "$1" -type f | wc -l | tr -d ' '; }
logged()   { grep -c -x -F -- "$1" "$STUBLOG"; }
logged_re() { grep -c -E -- "$1" "$STUBLOG"; }
out_has()  { grep -c -F -- "$1" "$T/out"; }
# run_setup <checkout> <prefix> <world> [args...] — prints the exit status; output in $T/out.
run_setup() {
  local root="$1" pfx="$2" w="$3"; shift 3
  : >"$STUBLOG"
  ( cd "$T" && PATH="$STUBBIN:$PATH" DOCK_WIFI_SETUP_PREFIX="$pfx" NMCLI_STATE="$w" \
      bash "$root/scripts/setup-dock-wifi.sh" "$@" ) >"$T/out" 2>&1
  echo $?
}
SCRIPT_DST="usr/local/bin/dock-wifi.sh"
SHIM_DST="etc/NetworkManager/dispatcher.d/50-dock-wifi"
UNIT_DST="etc/systemd/system/dock-wifi-sync.service"

printf '\nthe sudo stub\n'
P="$(newprefix)"
rc="$(DOCK_WIFI_SETUP_PREFIX="$P" PATH="$STUBBIN:$PATH" sudo install -m 644 "$UNIT_SRC" "$T/outside.service" >/dev/null 2>&1; echo $?)"
check "the sudo stub refuses a destination outside the prefix" "$rc:$([[ -e $T/outside.service ]] && echo written || echo absent)" "97:absent"
rc="$(DOCK_WIFI_SETUP_PREFIX='' PATH="$STUBBIN:$PATH" sudo install -m 644 "$UNIT_SRC" "$P/x.service" >/dev/null 2>&1; echo $?)"
check "with no prefix the sudo stub writes nothing" "$rc:$(files_in "$P")" "1:0"

printf '\nsetup-dock-wifi.sh: arguments\n'
W="$(world "$NO_WIRED" enabled)"
check "an unknown argument is exit 2" "$(run_setup "$ROOT" "" "$W" --bogus)" 2
rc="$(run_setup "$ROOT" "" "$W" --help)"
check "--help is exit 0 and prints the usage" "$rc:$(out_has 'Usage: setup-dock-wifi.sh')" "0:1"
check "a relative prefix is refused, exit 2" "$(run_setup "$ROOT" "relative/dir" "$W")" 2
check "a prefix that does not exist is refused, exit 2" "$(run_setup "$ROOT" "$T/no/such/dir" "$W")" 2

printf '\ninstall\n'
P="$(newprefix)"; W="$(world "$WIRED_UP" enabled)"
rc="$(run_setup "$ROOT" "$P" "$W")"
check "installs, exit 0" "$rc" 0
check "/$SCRIPT_DST is a byte-identical copy" "$(cmp -s "$ROOT/scripts/dock-wifi.sh" "$P/$SCRIPT_DST" && echo same || echo differs)" same
check "/$SHIM_DST is a byte-identical copy" "$(cmp -s "$ROOT/networkmanager/50-dock-wifi" "$P/$SHIM_DST" && echo same || echo differs)" same
check "/$UNIT_DST is a byte-identical copy" "$(cmp -s "$ROOT/systemd/dock-wifi-sync.service" "$P/$UNIT_DST" && echo same || echo differs)" same
check "the two executables are installed root-owned 0755, the unit 0644" \
  "$(logged_re '^sudo install -m 755 -o root -g root [^ ]+ [^ ]+$'):$(logged_re '^sudo install -m 644 -o root -g root [^ ]+ [^ ]+$')" "2:1"
check "the system manager re-reads its units" "$(logged 'sudo systemctl daemon-reload')" 1
check "the oneshot is enabled (boot and resume), never started as a daemon" "$(logged 'sudo systemctl enable dock-wifi-sync.service'):$(logged_re 'systemctl (start|restart)')" "1:0"
check "the install converges NOW through the installed copy (docked with wifi on: radio off)" "$(radio_of "$W")" disabled
check "a prefixed run says it is not touching the real /etc" "$(out_has 'NOT to the real /etc')" 1

printf '\nparent directories\n'
P="$(newprefix)"
rc="$(umask 077; run_setup "$ROOT" "$P" "$W")"
check "a missing parent is created 0755 under a strict umask" "$rc:$(stat -c %a "$P/etc/NetworkManager/dispatcher.d")" "0:755"
P="$(newprefix)"
install -d -m 700 "$P/etc/systemd/system" || fatal "parent fixture"
rc="$(run_setup "$ROOT" "$P" "$W")"
check "an existing parent is left alone" "$rc:$(stat -c %a "$P/etc/systemd/system"):$(logged_re '^sudo install -d .*/etc/systemd/system$')" "0:700:0"

printf '\nvalidation refuses before anything is written, and says why\n'
P="$(newprefix)"
rc="$(STUB_ANALYZE=fail run_setup "$ROOT" "$P" "$W")"
check "a unit systemd-analyze rejects: exit 1, nothing written, no install attempted" "$rc:$(files_in "$P"):$(logged_re '^sudo install')" "1:0:0"
check "... and its own explanation is printed" "$(out_has 'Service has no ExecStart= setting. Refusing.')" 1
P="$(newprefix)"
rc="$(STUB_ANALYZE=warn run_setup "$ROOT" "$P" "$W")"
check "a verify that exits 0 with a WARNING about OUR unit is a rejection" "$rc:$(files_in "$P")" "1:0"
P="$(newprefix)"
rc="$(STUB_ANALYZE=warn-other run_setup "$ROOT" "$P" "$W")"
check "a WARNING about an unrelated unit does not block the install" "$rc:$(files_in "$P")" "0:3"
P="$(newprefix)"
rc="$(STUB_ANALYZE=fail-other run_setup "$ROOT" "$P" "$W")"
check "an ERROR in an unrelated unit does not block it either (--recursive-errors=no)" "$rc:$(files_in "$P")" "0:3"

printf '\n--check\n'
P="$(newprefix)"; W="$(world "$WIRED_UP" enabled)"
[[ "$(run_setup "$ROOT" "$P" "$W")" == 0 ]] || fatal "--check fixture: the install it checks did not succeed"
rc="$(run_setup "$ROOT" "$P" "$W" --check)"
check "a clean install checks clean, exit 0" "$rc" 0
check "--check writes nothing and runs nothing under sudo" "$(logged_re '^sudo ')" 0
check "--check reports the live radio against the wanted state" "$(out_has 'radio is off, as a connected wired device wants')" 1
echo '# local edit' >>"$P/$SHIM_DST"
rc="$(run_setup "$ROOT" "$P" "$W" --check)"
check "an edited installed copy is drift: exit 1, named" "$rc:$(grep -c '50-dock-wifi DIFFERS' "$T/out")" "1:1"
rm -f "$P/$SHIM_DST"; ln -s "$ROOT/networkmanager/50-dock-wifi" "$P/$SHIM_DST" || fatal symlink
rc="$(run_setup "$ROOT" "$P" "$W" --check)"
check "a SYMLINK back into the checkout is refused, though its bytes match" "$rc:$(grep -c '50-dock-wifi is a SYMLINK' "$T/out")" "1:1"
rm -f "$P/$SHIM_DST"; install -m 755 "$ROOT/networkmanager/50-dock-wifi" "$P/$SHIM_DST" || fatal restore
chmod 777 "$P/$SCRIPT_DST" || fatal chmod
rc="$(run_setup "$ROOT" "$P" "$W" --check)"
check "a world-writable copy is refused, though its bytes match" "$rc:$(grep -c "dock-wifi.sh is $ME 777, not $ME 755" "$T/out")" "1:1"
chmod 755 "$P/$SCRIPT_DST" || fatal chmod
rm -f "$P/$UNIT_DST"
rc="$(run_setup "$ROOT" "$P" "$W" --check)"
check "a missing installed copy: exit 1, says not installed" "$rc:$(grep -c 'dock-wifi-sync.service is not installed' "$T/out")" "1:1"
install -m 644 "$ROOT/systemd/dock-wifi-sync.service" "$P/$UNIT_DST" || fatal restore
rc="$(run_setup "$ROOT" "$P" "$W" --check)"
check "(fixture) the restored prefix checks clean again" "$rc" 0
rc="$(STUB_LOADSTATE=not-found run_setup "$ROOT" "$P" "$W" --check)"
check "every file matching but systemd unable to load the unit: exit 1, names LoadState" "$rc:$(out_has 'LoadState=not-found')" "1:1"
rc="$(STUB_ENABLED=disabled run_setup "$ROOT" "$P" "$W" --check)"
check "every file matching but the oneshot not enabled: exit 1 (no boot/resume re-sync)" "$rc:$(out_has 'is not enabled')" "1:1"
W2="$(world "$WIRED_UP" enabled)"
rc="$(run_setup "$ROOT" "$P" "$W2" --check)"
check "every file matching but the radio on while docked: exit 1, names the live state" "$rc:$(out_has 'radio is on, but a connected wired device wants it off')" "1:1"

printf '\n--remove\n'
P="$(newprefix)"; W="$(world "$WIRED_UP" enabled)"
[[ "$(run_setup "$ROOT" "$P" "$W")" == 0 ]] || fatal "--remove fixture: the install did not succeed"
check "(fixture) the install turned the radio off" "$(radio_of "$W")" disabled
rc="$(run_setup "$ROOT" "$P" "$W" --remove)"
check "remove: exit 0, all three files gone" "$rc:$(files_in "$P")" "0:0"
check "remove: the oneshot is disabled" "$(logged 'sudo systemctl disable dock-wifi-sync.service')" 1
check "remove: the radio is turned back ON (uninstalling never strands the laptop offline)" "$(radio_of "$W")" enabled

printf '\nthe worktree guard\n'
G=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
mkroot "$T/repo"
{ "${G[@]}" -C "$T/repo" init -q -b main && "${G[@]}" -C "$T/repo" add -A \
    && "${G[@]}" -C "$T/repo" commit -q -m fixture \
    && "${G[@]}" -C "$T/repo" worktree add -q -b feature "$T/wt"; } >/dev/null 2>&1 \
  || fatal "could not build the worktree fixtures"
P="$(newprefix)"
rc="$(run_setup "$T/wt" "$P" "$W")"
check "from a worktree: exit 1, nothing written" "$rc:$(files_in "$P")" "1:0"
check "... and the refusal names the remedy" "$(out_has 'cd ~/.dotfiles && dock-wifi-setup')" 1
P="$(newprefix)"
rc="$(DOCK_WIFI_SETUP_ALLOW_WORKTREE=1 run_setup "$T/wt" "$P" "$W")"
check "DOCK_WIFI_SETUP_ALLOW_WORKTREE=1 overrides it" "$rc:$(files_in "$P")" "0:3"
P="$(newprefix)"
rc="$(run_setup "$T/repo" "$P" "$W")"
check "the primary checkout of the same repo is not a worktree: installs" "$rc:$(files_in "$P")" "0:3"

printf '\nthe shipped files, against the real parser and exactly\n'
# verify checks that ExecStart's command exists, and /usr/local/bin/dock-wifi.sh is not
# installed on a runner, so the unit is verified exactly as the installer verifies it: through
# a copy whose ExecStart points at the checkout's script.
sed "s#^ExecStart=/usr/local/bin/dock-wifi.sh #ExecStart=${SCRIPT} #" "$UNIT_SRC" >"$T/dock-wifi-sync.service"
out="$(systemd-analyze verify --man=no --recursive-errors=no "$T/dock-wifi-sync.service" 2>&1)"; rc=$?
check "the real systemd-analyze verify accepts the unit (ExecStart pointed at an existing copy) and prints nothing" "$rc:[$out]" "0:[]"
out="$(systemd-analyze verify --man=no --recursive-errors=no "$UNIT_SRC" 2>&1)"; rc=$?
check "...and the shipped unit itself is rejected ONLY for the not-yet-installed command, nothing else" \
  "$rc:$(grep -c 'is not executable' <<<"$out"):$(grep -vc 'is not executable' <<<"$out")" "1:1:0"
check "the unit runs the installed copy's --sync" "$(grep '^ExecStart=' "$UNIT_SRC")" 'ExecStart=/usr/local/bin/dock-wifi.sh --sync'
check "the unit is a oneshot" "$(grep -c '^Type=oneshot$' "$UNIT_SRC")" 1
check "the unit runs after NetworkManager and after resume (suspend.target, hibernate.target)" \
  "$(grep '^After=' "$UNIT_SRC")" 'After=NetworkManager.service suspend.target hibernate.target'
check "the unit is wanted at boot AND by suspend.target (the resume trigger; a wrong target verifies and never fires)" \
  "$(grep '^WantedBy=' "$UNIT_SRC")" 'WantedBy=multi-user.target suspend.target hibernate.target'
check "the shim runs under sh" "$(head -1 "$SHIM_SRC")" '#!/bin/sh'
# shellcheck disable=SC2016  # "$1" "$2" are the shim's literal text, NetworkManager's arguments
check "the shim is exactly one command: exec the installed copy's --dispatch with NetworkManager's two arguments" \
  "$(grep -v '^#' "$SHIM_SRC" | tr '\n' ' ')" 'exec /usr/local/bin/dock-wifi.sh --dispatch "$1" "$2" '

EXPECTED_ROWS=90

# --- the count this suite is documented as running ---------------------------
docs_claim() {
  local f="$HERE/../$1"
  [[ -r "$f" ]] || { printf 'cannot read %s' "$1"; return; }
  tr -s '[:space:]' ' ' <"$f" \
    | grep -c -F "\`scripts/test-dock-wifi.sh\` ($EXPECTED_ROWS checks"
}
printf '\nthe count this suite is documented as running\n'
check "docs/DOCK_WIFI.md says $EXPECTED_ROWS checks" "$(docs_claim docs/DOCK_WIFI.md)" 1
check "a documented file that cannot be read is not a pass" "$(docs_claim no/such/file.md)" "cannot read no/such/file.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( PASS + FAIL != EXPECTED_ROWS )); then
  printf '\033[1;31m✗\033[0m row total: expected %d, ran %d — a check did not run\n' \
    "$EXPECTED_ROWS" "$((PASS + FAIL))"
  FAIL=$((FAIL + 1))
fi
(( FAIL == 0 ))
