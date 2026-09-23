#!/usr/bin/env bash
# setup-vpn-failfast.sh — install the VPN fail-fast system unit and its config.
#
# Installs, all root-owned:
#   /usr/local/bin/vpn-failfast.sh            the daemon itself, 0755
#   /etc/vpn-failfast.conf                    from ~/.vpn-failfast.conf (vpn-init)
#   /etc/systemd/system/vpn-failfast.service  static, from systemd/
#   /etc/sysctl.d/99-vpn-acs-port.conf        from sysctl/
#
# Everything is COPIED, never symlinked into ~/.dotfiles — root reads or EXECUTES
# all four, and the same rule CLAUDE.md states for resticprofile/profiles.toml
# and the audit rules applies: a user-writable file consumed by root is a
# privilege-escalation hole, and a symlink into a working tree means a rebase or
# a half-finished checkout changes what root runs.
#
# The DAEMON is copied for that reason too, which the first version got wrong by
# pointing ExecStart into the checkout. backup-verify.sh, backup-manifest.sh and
# restic-notify already live in /usr/local/bin for exactly this reason.
#
# Run via `vpn-setup` (zsh/functions/system.sh). NEVER by ./install — ./install
# never uses sudo. Idempotent: re-run to resync after editing the repo copies.
#
# Usage: setup-vpn-failfast.sh [--yes] [--no-enable]
#   --yes         do not prompt before enabling the unit
#   --no-enable   install everything but leave the unit stopped and disabled
set -euo pipefail

ASSUME_YES=0
DO_ENABLE=1
for arg in "$@"; do
  case "$arg" in
    -y | --yes) ASSUME_YES=1 ;;
    --no-enable) DO_ENABLE=0 ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
      "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
UNIT_SRC="${DOTFILES}/systemd/vpn-failfast.service"
SYSCTL_SRC="${DOTFILES}/sysctl/99-vpn-acs-port.conf"
SCRIPT_SRC="${DOTFILES}/scripts/vpn-failfast.sh"
CONF_LOCAL="${VPN_LOCAL_CONF:-${HOME}/.vpn-failfast.conf}"
CONF_DST="/etc/vpn-failfast.conf"
UNIT_DST="/etc/systemd/system/vpn-failfast.service"
SYSCTL_DST="/etc/sysctl.d/99-vpn-acs-port.conf"
# The daemon is COPIED here and root runs it from here. Not a symlink and not a
# path in $HOME: the same rule resticprofile/profiles.toml and the audit rules
# follow, and the same place backup-verify.sh, backup-manifest.sh and
# restic-notify already live. See the unit's header for what went wrong without
# it -- the first install baked a WORKTREE path into a root unit, and
# wt-gc-sweep deletes worktrees daily.
SCRIPT_DST="/usr/local/bin/vpn-failfast.sh"
ACS_PORT=35001

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

for f in "$UNIT_SRC" "$SYSCTL_SRC" "$SCRIPT_SRC"; do
  [[ -r "$f" ]] || { log ERROR "missing $f"; exit 1; }
done

# REFUSE to install out of a worktree. `vpn-setup` resolves its checkout from
# $PWD when that looks like one, which is right for testing a branch and wrong
# for installing a file root will execute for months. The first real install
# copied from a worktree; wt-gc-sweep deletes landed worktrees daily, so the
# drift check would have started reporting against a directory that no longer
# exists. Same class as CLAUDE.md's "never run ./install from a worktree".
if git -C "$DOTFILES" rev-parse --git-dir >/dev/null 2>&1; then
  git_dir="$(git -C "$DOTFILES" rev-parse --git-dir 2>/dev/null || true)"
  # A worktree's .git is a FILE, and its resolved git-dir lives under
  # <main>/.git/worktrees/<name> rather than being <checkout>/.git.
  case "$git_dir" in
    *"/.git/worktrees/"*)
      log ERROR "refusing to install from a WORKTREE: $DOTFILES"
      log ERROR "  Root would run a copy taken from a branch checkout, and wt-gc-sweep"
      log ERROR "  deletes landed worktrees daily. Run this from the live checkout:"
      log ERROR "    cd ~/.dotfiles && vpn-setup"
      log ERROR "  (set VPN_SETUP_ALLOW_WORKTREE=1 to override, e.g. to test a branch.)"
      [[ "${VPN_SETUP_ALLOW_WORKTREE:-0}" == "1" ]] || exit 1
      log WARNING "VPN_SETUP_ALLOW_WORKTREE=1 — continuing from a worktree anyway." ;;
  esac
fi

if [[ ! -r "$CONF_LOCAL" ]]; then
  log ERROR "no destination list at $CONF_LOCAL"
  log ERROR "Create it first:  vpn-init   (then review it before re-running)"
  exit 1
fi

# VALIDATE BEFORE INSTALLING. The script's own --check is the single source of
# truth for what a valid destination is, so this cannot drift from it -- and
# installing a config the daemon will refuse would leave a unit that restart-
# loops to its StartLimitBurst and then sits failed.
log INFO "Validating $CONF_LOCAL"
if ! VPN_FAILFAST_CONF="$CONF_LOCAL" "${DOTFILES}/scripts/vpn-failfast.sh" --check; then
  log ERROR "refusing to install an invalid destination list"
  exit 1
fi

# The unit is STATIC now -- no placeholder, nothing rendered, so there is no
# `render | sudo tee` to get wrong (tee truncates before the renderer's exit
# status is known, which installs a zero-byte unit that "succeeds"). Refusing a
# unit that still carries a placeholder is kept as a belt: it would mean someone
# reintroduced rendering without reintroducing the renderer.
if grep -q '__VPN_[A-Z_]*__' "$UNIT_SRC"; then
  log ERROR "$UNIT_SRC contains an unresolved placeholder — nothing installed"
  exit 1
fi

log INFO "Installing root-owned files"
sudo install -m 755 -o root -g root "$SCRIPT_SRC" "$SCRIPT_DST"
sudo install -m 644 -o root -g root "$CONF_LOCAL" "$CONF_DST"
sudo install -m 644 -o root -g root "$UNIT_SRC"   "$UNIT_DST"
sudo install -d -m 755 -o root -g root /etc/sysctl.d
sudo install -m 644 -o root -g root "$SYSCTL_SRC" "$SYSCTL_DST"
log SUCCESS "installed $SCRIPT_DST, $CONF_DST, $UNIT_DST, $SYSCTL_DST"

# Apply the sysctl now as well as at boot. A file in /etc/sysctl.d that has
# never been applied is the silent-failure shape this repo keeps finding: it
# looks installed and does nothing until the next reboot.
log INFO "Applying $SYSCTL_DST"
if sudo sysctl -p "$SYSCTL_DST" >/dev/null 2>&1; then
  live="$(cat /proc/sys/net/ipv4/ip_local_reserved_ports 2>/dev/null || true)"
  if [[ ",${live}," == *",${ACS_PORT},"* || "$live" == "$ACS_PORT" ]]; then
    log SUCCESS "ip_local_reserved_ports now contains ${ACS_PORT} (live: ${live:-empty})"
  else
    log WARNING "sysctl applied but ${ACS_PORT} is not in the live value (${live:-empty})"
    log WARNING "vpn-doctor will keep reporting this until it is."
  fi
else
  log WARNING "could not apply $SYSCTL_DST now; it will apply at the next boot"
fi

sudo systemctl daemon-reload

if (( ! DO_ENABLE )); then
  log INFO "--no-enable: unit installed but not started."
  log INFO "Start it with: sudo systemctl enable --now vpn-failfast.service"
  exit 0
fi

if (( ! ASSUME_YES )); then
  echo
  echo "About to enable and start vpn-failfast.service. While the tunnel is DOWN it"
  echo "installs 'unreachable' routes for every destination in $CONF_DST,"
  echo "so traffic to them fails instantly instead of hanging. They are withdrawn"
  echo "when the tunnel returns, at stop, and at the next start."
  echo
  printf 'Enable and start it now? [y/N] '
  read -r reply
  case "$reply" in
    [yY] | [yY][eE][sS]) ;;
    *) log INFO "Left installed but not enabled. Enable with:"
       log INFO "  sudo systemctl enable --now vpn-failfast.service"
       exit 0 ;;
  esac
fi

# Clear a previous failure BEFORE starting. Re-running this script after a
# failed install is the normal recovery path -- it is what you do when
# vpn-doctor tells you something is wrong -- and inside StartLimitIntervalSec a
# unit that has exhausted its burst refuses to start with "Start request
# repeated too quickly", which reads as a brand-new fault rather than as the
# previous one still being counted. Harmless when the unit is healthy.
sudo systemctl reset-failed vpn-failfast.service 2>/dev/null || true

sudo systemctl enable --now vpn-failfast.service

# VERIFY, rather than trusting that `enable --now` meant it worked. LoadState
# first: a unit systemd cannot load answers Result=success to every other
# question asked of it.
load="$(systemctl show -p LoadState --value vpn-failfast.service 2>/dev/null || true)"
if [[ "$load" != "loaded" ]]; then
  log ERROR "LoadState=$load — systemd cannot load the unit."
  log ERROR "  systemctl status vpn-failfast.service"
  exit 1
fi
active="$(systemctl show -p ActiveState --value vpn-failfast.service 2>/dev/null || true)"
case "$active" in
  active|activating) log SUCCESS "vpn-failfast.service is $active" ;;
  *) log ERROR "vpn-failfast.service is $active — it did not start."
     log ERROR "  journalctl -u vpn-failfast.service -e"
     exit 1 ;;
esac

echo
log SUCCESS "Done. Check the whole chain with: vpn-doctor"
