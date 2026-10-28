#!/usr/bin/env bash
# setup-dock-wifi.sh — install the dock Wi-Fi guard: a docked laptop keeps ONE uplink.
#
# Docked, this laptop had two uplinks at once, and a VPN session that came up
# over Wi-Fi kept riding Wi-Fi after docking; every Wi-Fi flap then became a
# 20-second gap and a tunnel restart. Three files make "docked" mean "wired only":
#
#   /usr/local/bin/dock-wifi.sh                       from scripts/
#       the logic: Wi-Fi radio off while a managed ethernet device is connected,
#       on again when none is; a pure function of NetworkManager's current state
#   /etc/NetworkManager/dispatcher.d/50-dock-wifi     from networkmanager/
#       every link event re-evaluates it
#   /etc/systemd/system/dock-wifi-sync.service        from systemd/
#       so does boot and resume, the two moments no link event fires (NetworkManager
#       persists `radio wifi off` across reboots)
#
# All COPIED root-owned, never symlinked: root executes the first two and PID 1
# reads the third, and a user-writable file consumed by root is the hole
# CLAUDE.md names for resticprofile/profiles.toml and vpn-failfast. Why, and
# the measurements: docs/DOCK_WIFI.md.
#
# Run via `dock-wifi-setup` (zsh/functions/system.sh). NEVER by ./install —
# ./install never uses sudo. Idempotent: re-run to resync after editing the repo
# copies. The install converges the radio immediately through the installed copy.
#
# Usage: setup-dock-wifi.sh [--check | --remove]
#   --check   read-only: is each installed copy a root-owned regular file of the
#             right mode matching this checkout, can systemd load the unit, is it
#             enabled, and is the radio in the state a connected wired device
#             wants? Exit 1 if not. Needs no sudo.
#   --remove  uninstall all three, disable the oneshot, and turn the radio back
#             ON, so uninstalling never leaves the laptop offline.
#
# DOCK_WIFI_SETUP_PREFIX is a TEST SEAM, not an operational knob: it prefixes
# every destination path so the state table can run the install for real. It is
# refused unless it is an absolute path to an existing directory, and it says so
# loudly on every run where it is set.
set -euo pipefail

MODE=install
for arg in "$@"; do
  case "$arg" in
    --check)  MODE=check ;;
    --remove) MODE=remove ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
      "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PREFIX="${DOCK_WIFI_SETUP_PREFIX:-}"
if [[ -n "$PREFIX" ]]; then
  [[ "$PREFIX" == /* && -d "$PREFIX" ]] || {
    echo "DOCK_WIFI_SETUP_PREFIX must be an absolute path to an existing directory, got '$PREFIX'" >&2
    exit 2; }
fi

SCRIPT_SRC="${DOTFILES}/scripts/dock-wifi.sh"
SHIM_SRC="${DOTFILES}/networkmanager/50-dock-wifi"
UNIT_SRC="${DOTFILES}/systemd/dock-wifi-sync.service"
SCRIPT_DST="${PREFIX}/usr/local/bin/dock-wifi.sh"
SHIM_DST="${PREFIX}/etc/NetworkManager/dispatcher.d/50-dock-wifi"
UNIT_DST="${PREFIX}/etc/systemd/system/dock-wifi-sync.service"
SRCS=("$SCRIPT_SRC" "$SHIM_SRC" "$UNIT_SRC")
DSTS=("$SCRIPT_DST" "$SHIM_DST" "$UNIT_DST")
MODES=(755 755 644)
UNIT_NAME="dock-wifi-sync.service"
# Under the test seam nothing can be chowned to root; the copies belong to whoever runs the suite.
OWNER="root:root"
[[ -n "$PREFIX" ]] && OWNER="$(id -un):$(id -gn)"

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; BLUE=''; RED=''; RESET=''
fi
log() {
  local level="$1"; shift; local msg="$*"
  case "$level" in
    INFO)    echo -e "${BLUE}▶${RESET} $msg" ;;
    SUCCESS) echo -e "${GREEN}✓${RESET} $msg" ;;
    WARNING) echo -e "${YELLOW}⚠${RESET} $msg" >&2 ;;
    ERROR)   echo -e "${RED}✗${RESET} $msg" >&2 ;;
  esac
}
show_output() { [[ -n "$1" ]] && printf '%s\n' "$1" | sed 's/^/    /' >&2; return 0; }

for f in "${SRCS[@]}"; do
  [[ -r "$f" ]] || { log ERROR "missing $f"; exit 1; }
done
if [[ -n "$PREFIX" ]]; then
  log WARNING "DOCK_WIFI_SETUP_PREFIX=$PREFIX — installing under a prefix, NOT to the real /etc"
fi

# The live radio against what a connected wired device wants, read through the
# checkout's own script (--status writes nothing), so the check cannot drift from
# the logic it checks. Prints "ok <msg>" or "bad <msg>".
live_radio_vs_wanted() {
  local st wifi wanted
  if ! st="$(bash "$SCRIPT_SRC" --status 2>/dev/null)"; then
    printf 'bad could not read the radio state (dock-wifi.sh --status failed)\n'; return 0
  fi
  wifi="$(sed -n 's/^wifi:   //p' <<<"$st")"
  wanted="$(sed -n 's/^wanted: //p' <<<"$st")"
  if [[ "$wifi" == "$wanted" ]]; then
    if [[ "$wanted" == "off" ]]; then printf 'ok radio is off, as a connected wired device wants\n'
    else printf 'ok radio is on, no wired device connected\n'; fi
  else
    if [[ "$wanted" == "off" ]]; then printf 'bad radio is on, but a connected wired device wants it off\n'
    else printf 'bad radio is off, but no wired device is connected\n'; fi
  fi
}

# THE INSTALLED STATE, not the install's exit status (the dock-lid rule).
check_installed() {
  local bad=0 i st load en verdict want
  for i in "${!SRCS[@]}"; do
    want="${OWNER} ${MODES[$i]}"
    if [[ -L "${DSTS[$i]}" ]]; then
      log ERROR "${DSTS[$i]} is a SYMLINK — root would execute a file you can write; re-run: dock-wifi-setup"; bad=1
    elif [[ ! -e "${DSTS[$i]}" ]]; then
      log ERROR "${DSTS[$i]} is not installed — run: dock-wifi-setup"; bad=1
    elif ! cmp -s "${SRCS[$i]}" "${DSTS[$i]}"; then
      log ERROR "${DSTS[$i]} DIFFERS from ${SRCS[$i]} — re-run: dock-wifi-setup"; bad=1
    elif st="$(stat -c '%U:%G %a' "${DSTS[$i]}")" && [[ "$st" != "$want" ]]; then
      log ERROR "${DSTS[$i]} is ${st}, not ${want} — re-run: dock-wifi-setup"; bad=1
    else
      log SUCCESS "${DSTS[$i]} matches this checkout (${st})"
    fi
  done
  # `|| true`: --check calls this as a plain command under set -e.
  load="$(systemctl show -p LoadState --value "$UNIT_NAME" 2>/dev/null || true)"
  if [[ "$load" != "loaded" ]]; then
    log ERROR "systemd cannot load ${UNIT_NAME} (LoadState=${load:-unknown}) — re-run: dock-wifi-setup"; bad=1
  else
    log SUCCESS "systemd can load ${UNIT_NAME}"
  fi
  en="$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true)"
  if [[ "$en" != "enabled" ]]; then
    log ERROR "${UNIT_NAME} is not enabled (${en:-unknown}) — no re-sync at boot or resume; re-run: dock-wifi-setup"; bad=1
  else
    log SUCCESS "${UNIT_NAME} is enabled (re-syncs at boot and after resume)"
  fi
  verdict="$(live_radio_vs_wanted)"
  case "$verdict" in
    ok\ *) log SUCCESS "${verdict#ok }" ;;
    *)     log ERROR "${verdict#bad }"
           log ERROR "  sudo /usr/local/bin/dock-wifi.sh --sync"
           bad=1 ;;
  esac
  return "$bad"
}

if [[ "$MODE" == "check" ]]; then
  check_installed
  exit 0
fi

if [[ "$MODE" == "remove" ]]; then
  log INFO "Removing the dock Wi-Fi guard"
  sudo rm -f "$SHIM_DST" "$UNIT_DST" "$SCRIPT_DST"
  sudo systemctl disable "$UNIT_NAME" >/dev/null 2>&1 \
    || log WARNING "could not disable ${UNIT_NAME} (not installed?)"
  sudo systemctl daemon-reload
  # Never leave the laptop offline: whatever the guard decided, it is gone now.
  sudo nmcli radio wifi on || log WARNING "could not turn the radio on — run: nmcli radio wifi on"
  log SUCCESS "removed ${SCRIPT_DST}, ${SHIM_DST}, ${UNIT_DST}; Wi-Fi radio on"
  exit 0
fi

# REFUSE to install out of a worktree (the setup-dock-lid.sh rule): root would
# execute a copy taken from an unreviewed branch for months.
git_dir="$(git -C "$DOTFILES" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
common_dir="$(git -C "$DOTFILES" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -n "$git_dir" && -n "$common_dir" && "$git_dir" != "$common_dir" ]]; then
  log ERROR "refusing to install from a WORKTREE: $DOTFILES"
  log ERROR "  Run this from the live checkout:"
  log ERROR "    cd ~/.dotfiles && dock-wifi-setup"
  log ERROR "  (set DOCK_WIFI_SETUP_ALLOW_WORKTREE=1 to override, e.g. to test a branch.)"
  [[ "${DOCK_WIFI_SETUP_ALLOW_WORKTREE:-0}" == "1" ]] || exit 1
  log WARNING "DOCK_WIFI_SETUP_ALLOW_WORKTREE=1 — continuing from a worktree anyway."
fi

# VALIDATE BEFORE INSTALLING: the script with bash's own parser, the unit with
# systemd's. A unit systemd cannot load answers Result=success to everything.
log INFO "Validating the script and the unit"
if ! out="$(bash -n "$SCRIPT_SRC" 2>&1)"; then
  log ERROR "bash -n rejects $SCRIPT_SRC — nothing installed:"
  show_output "$out"
  exit 1
fi
# systemd-analyze verify exits 0 on a WARNING about our unit, so any line naming
# it is a rejection; --recursive-errors=no and the filter keep an unrelated
# unit's trouble from blocking the install. It also checks that ExecStart's
# command EXISTS, and /usr/local/bin/dock-wifi.sh exists only after the install
# below writes it, so the unit is verified through a copy whose ExecStart points
# at this checkout's script: the same unit text, a command that exists. The
# installed unit keeps the real path; its existence is what the install step
# guarantees.
verify_dir="$(mktemp -d)"
trap 'rm -rf "$verify_dir"' EXIT
sed "s#^ExecStart=/usr/local/bin/dock-wifi.sh #ExecStart=${SCRIPT_SRC} #" "$UNIT_SRC" >"$verify_dir/dock-wifi-sync.service"
if ! out="$(systemd-analyze verify --man=no --recursive-errors=no "$verify_dir/dock-wifi-sync.service" 2>&1)" \
   || grep -q -F 'dock-wifi-sync' <<<"$out"; then
  log ERROR "systemd-analyze verify rejects $UNIT_SRC — nothing installed:"
  show_output "$out"
  exit 1
fi

log INFO "Installing root-owned files"
for d in "${PREFIX}/usr/local/bin" "${PREFIX}/etc/NetworkManager/dispatcher.d" "${PREFIX}/etc/systemd/system"; do
  [[ -d "$d" ]] || sudo install -d -m 755 -o root -g root "$d"
done
sudo install -m 755 -o root -g root "$SCRIPT_SRC" "$SCRIPT_DST"
sudo install -m 755 -o root -g root "$SHIM_SRC"   "$SHIM_DST"
sudo install -m 644 -o root -g root "$UNIT_SRC"   "$UNIT_DST"
log SUCCESS "installed $SCRIPT_DST, $SHIM_DST, $UNIT_DST"

sudo systemctl daemon-reload
# Enabled, never started: it is a oneshot that boot and resume start.
sudo systemctl enable "$UNIT_NAME" >/dev/null 2>&1 \
  || log WARNING "could not enable ${UNIT_NAME}; the boot/resume re-sync is off until it is"

log INFO "Converging the radio now, through the installed copy"
sudo "$SCRIPT_DST" --sync || log WARNING "could not converge: ${SCRIPT_DST} --sync failed"

echo
check_installed || exit 1
echo
log SUCCESS "Done. Dock or undock and confirm with: nmcli radio wifi; journalctl -u NetworkManager-dispatcher -e"
