#!/usr/bin/env bash
# setup-dock-lid.sh — install the two lid-switch guards for the Thunderbolt dock.
#
# Closing the lid within ~2 s of plugging into the dock, before logind can see
# the dock or its power, starts a suspend while the dock is still enumerating —
# and on 2026-10-19 that suspend hung the laptop until a forced power-off. Two
# guards, each covering a different part of that window:
#
#   /etc/systemd/logind.conf.d/lid-on-power.conf   from logind/
#       lid closed on external power does nothing (from ~1.8 s after plug-in)
#   /etc/udev/rules.d/90-dock-lid-holdoff.rules    from udev/
#   /etc/systemd/system/dock-lid-holdoff.service   from systemd/
#       any USB-C plug-in blocks lid handling for 30 s (from ~0.1 s after)
#
# All COPIED root-owned 0644, never symlinked: root's logind, systemd and udevd
# read them, and a user-writable file consumed by root is the hole CLAUDE.md
# names for resticprofile/profiles.toml and vpn-failfast. Why, the measured
# timings and what neither guard covers: docs/DOCK_LID_SUSPEND.md.
#
# Run via `dock-lid-setup` (zsh/functions/system.sh). NEVER by ./install —
# ./install never uses sudo. Idempotent: re-run to resync after editing the repo
# copies. logind is RELOADED, not restarted: a restart ends every session.
#
# Usage: setup-dock-lid.sh [--check]
#   --check   read-only: does each installed copy match this checkout, and is
#             logind running with the setting? Exit 1 if not. Needs no sudo.
#
# DOCK_LID_SETUP_PREFIX is a TEST SEAM, not an operational knob: it prefixes
# every destination path so the state table can run the install for real. It is
# refused unless it is an absolute path to an existing directory, and it says so
# loudly on every run where it is set.
set -euo pipefail

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
      "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# A test seam, validated rather than trusted. Empty in every real run.
PREFIX="${DOCK_LID_SETUP_PREFIX:-}"
if [[ -n "$PREFIX" ]]; then
  [[ "$PREFIX" == /* && -d "$PREFIX" ]] || {
    echo "DOCK_LID_SETUP_PREFIX must be an absolute path to an existing directory, got '$PREFIX'" >&2
    exit 2; }
fi

LOGIND_SRC="${DOTFILES}/logind/lid-on-power.conf"
RULE_SRC="${DOTFILES}/udev/90-dock-lid-holdoff.rules"
UNIT_SRC="${DOTFILES}/systemd/dock-lid-holdoff.service"
LOGIND_DST="${PREFIX}/etc/systemd/logind.conf.d/lid-on-power.conf"
RULE_DST="${PREFIX}/etc/udev/rules.d/90-dock-lid-holdoff.rules"
UNIT_DST="${PREFIX}/etc/systemd/system/dock-lid-holdoff.service"
SRCS=("$LOGIND_SRC" "$RULE_SRC" "$UNIT_SRC")
DSTS=("$LOGIND_DST" "$RULE_DST" "$UNIT_DST")

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

for f in "${SRCS[@]}"; do
  [[ -r "$f" ]] || { log ERROR "missing $f"; exit 1; }
done

if [[ -n "$PREFIX" ]]; then
  log WARNING "DOCK_LID_SETUP_PREFIX=$PREFIX — installing under a prefix, NOT to the real /etc"
fi

# The value logind must be running with, read from the file being installed so
# the check cannot drift from it.
WANT="$(sed -n 's/^HandleLidSwitchExternalPower=//p' "$LOGIND_SRC" | head -1)"
[[ -n "$WANT" ]] || { log ERROR "$LOGIND_SRC sets no HandleLidSwitchExternalPower="; exit 1; }

live_lid_power() {
  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager HandleLidSwitchExternalPower 2>/dev/null \
    | sed -n 's/^s "\(.*\)"$/\1/p'
}

# THE INSTALLED STATE, not the install's exit status. Every copy byte-identical
# to this checkout, and logind actually running with the value: a drop-in logind
# has not re-read looks installed and does nothing until the next boot.
check_installed() {
  local bad=0 i live
  for i in "${!SRCS[@]}"; do
    if [[ ! -e "${DSTS[$i]}" ]]; then
      log ERROR "${DSTS[$i]} is not installed — run: dock-lid-setup"; bad=1
    elif ! cmp -s "${SRCS[$i]}" "${DSTS[$i]}"; then
      log ERROR "${DSTS[$i]} DIFFERS from ${SRCS[$i]} — re-run: dock-lid-setup"; bad=1
    else
      log SUCCESS "${DSTS[$i]} matches this checkout"
    fi
  done
  # `|| true`: --check calls this as a plain command, where set -e and pipefail
  # would make a failing busctl end the script right here, silently, instead of
  # reporting logind as not running with it. (The install path calls it from an
  # `||` list, where bash suspends set -e for the whole function body.)
  live="$(live_lid_power || true)"
  if [[ "$live" == "$WANT" ]]; then
    log SUCCESS "logind is running with HandleLidSwitchExternalPower=$live"
  else
    log ERROR "logind is running with HandleLidSwitchExternalPower='${live}', not '${WANT}'"
    log ERROR "  sudo systemctl reload systemd-logind   (or reboot)"
    bad=1
  fi
  return "$bad"
}

if (( CHECK_ONLY )); then
  check_installed   # a plain call: under set -e a failed check exits 1 right here
  exit 0
fi

# REFUSE to install out of a worktree, as setup-vpn-failfast.sh does: root would
# read a copy taken from an unreviewed branch for months, and --check would then
# report the live checkout as drift. A worktree's .git is a FILE, and its
# resolved git-dir lives under <main>/.git/worktrees/<name>.
git_dir="$(git -C "$DOTFILES" rev-parse --git-dir 2>/dev/null || true)"
case "$git_dir" in
  *"/.git/worktrees/"*)
    log ERROR "refusing to install from a WORKTREE: $DOTFILES"
    log ERROR "  Run this from the live checkout:"
    log ERROR "    cd ~/.dotfiles && dock-lid-setup"
    log ERROR "  (set DOCK_LID_SETUP_ALLOW_WORKTREE=1 to override, e.g. to test a branch.)"
    [[ "${DOCK_LID_SETUP_ALLOW_WORKTREE:-0}" == "1" ]] || exit 1
    log WARNING "DOCK_LID_SETUP_ALLOW_WORKTREE=1 — continuing from a worktree anyway." ;;
esac

# VALIDATE BEFORE INSTALLING, with udev's and systemd's own parsers. A rule udevd
# cannot parse is skipped with one line in the journal, and a unit systemd cannot
# load answers Result=success to everything asked of it — either way the guard
# looks installed and never fires.
log INFO "Validating the rule and the unit"
if ! udevadm verify --resolve-names=never "$RULE_SRC" >/dev/null 2>&1; then
  log ERROR "udevadm verify rejects $RULE_SRC — nothing installed"
  exit 1
fi
if ! systemd-analyze verify --man=no "$UNIT_SRC" >/dev/null 2>&1; then
  log ERROR "systemd-analyze verify rejects $UNIT_SRC — nothing installed"
  exit 1
fi

log INFO "Installing root-owned files"
sudo install -d -m 755 -o root -g root "${PREFIX}/etc/systemd/logind.conf.d" \
  "${PREFIX}/etc/udev/rules.d" "${PREFIX}/etc/systemd/system"
sudo install -m 644 -o root -g root "$LOGIND_SRC" "$LOGIND_DST"
sudo install -m 644 -o root -g root "$RULE_SRC"   "$RULE_DST"
sudo install -m 644 -o root -g root "$UNIT_SRC"   "$UNIT_DST"
log SUCCESS "installed $LOGIND_DST, $RULE_DST, $UNIT_DST"

sudo systemctl daemon-reload
sudo udevadm control --reload
# RELOAD, never restart: restarting logind ends every session on the machine.
# Where logind cannot reload, the check below says so and names the reboot.
sudo systemctl reload systemd-logind \
  || log WARNING "could not reload systemd-logind; the logind setting applies at the next boot"

echo
check_installed || exit 1
echo
log SUCCESS "Done. The holdoff fires on the next USB-C plug-in; confirm with:"
log SUCCESS "  journalctl -u dock-lid-holdoff -b"
