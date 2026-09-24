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
# Usage: setup-vpn-failfast.sh [--yes] [--no-enable] [--block-ipv6|--no-block-ipv6]
#   --yes             do not prompt before enabling the unit
#   --no-enable       install everything but leave the unit stopped and disabled
#   --block-ipv6      arm the DO-704 IPv6 block (installs the drop-in)
#   --no-block-ipv6   disarm it (removes the drop-in)
#
# NEITHER IPv6 FLAG LEAVES ARMING EXACTLY AS IT IS. A routine re-run -- which is
# what you do after a `git pull`, and what vpn-doctor tells you to do -- must
# never silently disarm a machine, so the drop-in is only touched when you ask.
#
# VPN_SETUP_PREFIX is a TEST SEAM, not an operational knob: it prefixes every
# destination path so the state table can exercise the install and the
# post-install check for real instead of asserting argv. It is refused unless it
# is an absolute path to an existing directory, and it says so loudly on every
# run where it is set.
set -euo pipefail

ASSUME_YES=0
DO_ENABLE=1
BLOCK_IPV6=''   # '' = leave arming alone; 1 = arm; 0 = disarm
for arg in "$@"; do
  case "$arg" in
    -y | --yes) ASSUME_YES=1 ;;
    --no-enable) DO_ENABLE=0 ;;
    --block-ipv6)
      [[ "$BLOCK_IPV6" == "0" ]] && { echo "--block-ipv6 and --no-block-ipv6 are contradictory" >&2; exit 2; }
      BLOCK_IPV6=1 ;;
    --no-block-ipv6)
      [[ "$BLOCK_IPV6" == "1" ]] && { echo "--block-ipv6 and --no-block-ipv6 are contradictory" >&2; exit 2; }
      BLOCK_IPV6=0 ;;
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
      "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
UNIT_SRC="${DOTFILES}/systemd/vpn-failfast.service"
SYSCTL_SRC="${DOTFILES}/sysctl/99-vpn-acs-port.conf"
SCRIPT_SRC="${DOTFILES}/scripts/vpn-failfast.sh"
DROPIN_SRC="${DOTFILES}/systemd/vpn-failfast.service.d/ipv6-block.conf"
CONF_LOCAL="${VPN_LOCAL_CONF:-${HOME}/.vpn-failfast.conf}"
# A test seam, validated rather than trusted. Empty in every real run.
PREFIX="${VPN_SETUP_PREFIX:-}"
if [[ -n "$PREFIX" ]]; then
  [[ "$PREFIX" == /* && -d "$PREFIX" ]] || {
    echo "VPN_SETUP_PREFIX must be an absolute path to an existing directory, got '$PREFIX'" >&2
    exit 2; }
fi
CONF_DST="${PREFIX}/etc/vpn-failfast.conf"
UNIT_DST="${PREFIX}/etc/systemd/system/vpn-failfast.service"
SYSCTL_DST="${PREFIX}/etc/sysctl.d/99-vpn-acs-port.conf"
DROPIN_DIR="${PREFIX}/etc/systemd/system/vpn-failfast.service.d"
DROPIN_DST="${DROPIN_DIR}/ipv6-block.conf"
# The daemon is COPIED here and root runs it from here. Not a symlink and not a
# path in $HOME: the same rule resticprofile/profiles.toml and the audit rules
# follow, and the same place backup-verify.sh, backup-manifest.sh and
# restic-notify already live. See the unit's header for what went wrong without
# it -- the first install baked a WORKTREE path into a root unit, and
# wt-gc-sweep deletes worktrees daily.
SCRIPT_DST="${PREFIX}/usr/local/bin/vpn-failfast.sh"
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

for f in "$UNIT_SRC" "$SYSCTL_SRC" "$SCRIPT_SRC" "$DROPIN_SRC"; do
  [[ -r "$f" ]] || { log ERROR "missing $f"; exit 1; }
done

if [[ -n "$PREFIX" ]]; then
  log WARNING "VPN_SETUP_PREFIX=$PREFIX — installing under a prefix, NOT to the real /etc"
fi

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
sudo install -d -m 755 -o root -g root "${PREFIX}/etc/sysctl.d"
sudo install -m 644 -o root -g root "$SYSCTL_SRC" "$SYSCTL_DST"
log SUCCESS "installed $SCRIPT_DST, $CONF_DST, $UNIT_DST, $SYSCTL_DST"

# ---------------------------------------------------------------------------
# The IPv6 block (DO-704): arm, disarm, or leave exactly as it is
# ---------------------------------------------------------------------------
# An UNSET $BLOCK_IPV6 touches nothing. That is the whole reason it is tri-state
# rather than a boolean: a re-run after `git pull` is the normal path, and a
# boolean defaulting to off would silently disarm the machine every time.
if [[ "$BLOCK_IPV6" == "1" ]]; then
  log INFO "Arming the IPv6 block"
  sudo install -d -m 755 -o root -g root "$DROPIN_DIR"
  sudo install -m 644 -o root -g root "$DROPIN_SRC" "$DROPIN_DST"
  log SUCCESS "installed $DROPIN_DST"
elif [[ "$BLOCK_IPV6" == "0" ]]; then
  log INFO "Disarming the IPv6 block"
  # HARDCODED LITERALS, never "$DROPIN_DST"/"$DROPIN_DIR". Under `set -u` an
  # unset variable aborts, but a variable that is set and EMPTY does not -- and
  # `sudo rm -f /` -style removal is not a class of accident worth being one
  # refactor away from. The prefix form is spelled out separately.
  if [[ -n "$PREFIX" ]]; then
    sudo rm -f "${PREFIX}/etc/systemd/system/vpn-failfast.service.d/ipv6-block.conf"
    sudo rmdir --ignore-fail-on-non-empty "${PREFIX}/etc/systemd/system/vpn-failfast.service.d" 2>/dev/null || true
  else
    sudo rm -f /etc/systemd/system/vpn-failfast.service.d/ipv6-block.conf
    sudo rmdir --ignore-fail-on-non-empty /etc/systemd/system/vpn-failfast.service.d 2>/dev/null || true
  fi
  log SUCCESS "removed the IPv6 block drop-in"
fi

# THE CHECK THAT MATTERS IS "WILL THE DAEMON STILL START", NOT "DID THE ROUTES
# APPEAR". The drop-in is the only producer of VPN_FAILFAST_IPV6 and the script
# treats an unknown value as fatal in every mode, so `blocked`, `Block` or a
# trailing space makes --watch exit 2 on every start -> Restart=on-failure ->
# StartLimitBurst -> the unit sits `failed`, and IPv4 fail-fast, which works
# today with NRestarts=0, is dead because of a typo in an OPTIONAL feature.
#
# The validation above this runs the CHECKOUT script with the CHECKOUT
# environment and cannot see the drop-in at all. So read the value back out of
# the file that is actually installed, hand it to the script that is actually
# installed, and refuse BEFORE systemctl ever restarts anything.
if [[ -r "$DROPIN_DST" ]]; then
  dropin_val="$(sed -n 's/^Environment=VPN_FAILFAST_IPV6=//p' "$DROPIN_DST" | head -1)"
  log INFO "Checking the installed daemon accepts VPN_FAILFAST_IPV6='${dropin_val}'"
  if VPN_FAILFAST_IPV6="$dropin_val" VPN_FAILFAST_CONF="$CONF_DST" \
     "$SCRIPT_DST" --check >/dev/null 2>&1; then
    log SUCCESS "the installed daemon accepts the drop-in's value"
  else
    log ERROR "the installed daemon REFUSES VPN_FAILFAST_IPV6='${dropin_val}'"
    log ERROR "  Restarting now would leave the unit in a restart loop and then failed,"
    log ERROR "  taking IPv4 fail-fast down with it. Removing the drop-in and refusing."
    if [[ -n "$PREFIX" ]]; then
      sudo rm -f "${PREFIX}/etc/systemd/system/vpn-failfast.service.d/ipv6-block.conf"
    else
      sudo rm -f /etc/systemd/system/vpn-failfast.service.d/ipv6-block.conf
    fi
    sudo systemctl daemon-reload
    exit 1
  fi
fi

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

# A DROP-IN THE RUNNING UNIT HAS NOT RE-READ IS NOT ARMED. `systemctl enable
# --now` below runs `start`, and `start` on an ALREADY-ACTIVE unit is a no-op --
# it does not re-read the environment. So on the normal machine, where
# vpn-failfast is already running, arming would install the file, reload, report
# success, and change nothing at all until the next reboot. vpn-doctor would
# then correctly report IPv6 as LEAKING while the installer had just said it was
# armed, which is the worst possible pairing: a green install and a red doctor.
#
# `try-restart`, not `restart`: it restarts the unit only if it is ALREADY
# running, and is a no-op otherwise -- so it cannot start a unit that --no-enable
# deliberately left stopped. Guarded on the arming state having actually changed,
# so a plain re-run still restarts nothing.
if [[ -n "$BLOCK_IPV6" ]]; then
  log INFO "Re-reading the unit so the drop-in takes effect now, not at the next boot"
  sudo systemctl try-restart vpn-failfast.service
fi

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
