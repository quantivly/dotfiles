#!/usr/bin/env bash
# setup-dock-lid.sh — install the lid policy and the dock holdoff.
#
#   /etc/systemd/logind.conf.d/lid-locks-never-suspends.conf   from logind/
#       closing the lid locks the screen, docked it does nothing, and it never
#       suspends: agents keep running until sleep is asked for
#   /etc/udev/rules.d/90-dock-lid-holdoff.rules    from udev/
#   /etc/systemd/system/dock-lid-holdoff@.service  from systemd/
#       every USB-C plug-in blocks lid handling for 30 s (from ~0.1 s after),
#       so closing the lid as you dock does not lock the screen you will use
#
# All COPIED root-owned 0644, never symlinked: root's logind, systemd and udevd
# read them, and a user-writable file consumed by root is the hole CLAUDE.md
# names for resticprofile/profiles.toml and vpn-failfast. It also REMOVES
# /etc/systemd/logind.conf.d/lid-on-power.conf, which the lid policy replaced:
# logind reads drop-ins in name order, so that file's
# HandleLidSwitchExternalPower=ignore would override the new one. Why, the
# measured timings and what is still not covered: docs/DOCK_LID_SUSPEND.md.
#
# Run via `dock-lid-setup` (zsh/functions/system.sh). NEVER by ./install —
# ./install never uses sudo. Idempotent: re-run to resync after editing the repo
# copies. logind is RELOADED, not restarted: a restart ends every session.
#
# Usage: setup-dock-lid.sh [--check]
#   --check   read-only: is each installed copy a root-owned 0644 regular file
#             matching this checkout, is the replaced drop-in gone, can systemd
#             load the unit, and is logind running with every setting the
#             drop-in makes? Exit 1 if not. Needs no sudo.
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

LOGIND_SRC="${DOTFILES}/logind/lid-locks-never-suspends.conf"
RULE_SRC="${DOTFILES}/udev/90-dock-lid-holdoff.rules"
UNIT_SRC="${DOTFILES}/systemd/dock-lid-holdoff@.service"
LOGIND_DST="${PREFIX}/etc/systemd/logind.conf.d/lid-locks-never-suspends.conf"
# The drop-in LOGIND_DST replaced on 2026-10-29. It sorts after it, so while it
# is installed its HandleLidSwitchExternalPower=ignore wins.
SUPERSEDED_LOGIND_DST="${PREFIX}/etc/systemd/logind.conf.d/lid-on-power.conf"
RULE_DST="${PREFIX}/etc/udev/rules.d/90-dock-lid-holdoff.rules"
UNIT_DST="${PREFIX}/etc/systemd/system/dock-lid-holdoff@.service"
SRCS=("$LOGIND_SRC" "$RULE_SRC" "$UNIT_SRC")
DSTS=("$LOGIND_DST" "$RULE_DST" "$UNIT_DST")
# A template cannot be asked about, only an instance of it; any instance name
# loads the template's fragment, so this one stands for all of them.
UNIT_PROBE="dock-lid-holdoff@check.service"
# Owner and mode of an installed copy. Under the test seam nothing can be
# chowned to root, so the copies belong to whoever runs the suite.
WANT_STAT="root:root 644"
[[ -n "$PREFIX" ]] && WANT_STAT="$(id -un):$(id -gn) 644"

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
# A parser's own explanation, indented under the line that names the file.
show_output() { [[ -n "$1" ]] && printf '%s\n' "$1" | sed 's/^/    /' >&2; return 0; }

for f in "${SRCS[@]}"; do
  [[ -r "$f" ]] || { log ERROR "missing $f"; exit 1; }
done

if [[ -n "$PREFIX" ]]; then
  log WARNING "DOCK_LID_SETUP_PREFIX=$PREFIX — installing under a prefix, NOT to the real /etc"
fi

# Every Key=value logind must be running with, read from the file being
# installed so the check cannot drift from it. Each key is also the name of the
# logind Manager property that reports it.
mapfile -t LOGIND_SETTINGS < <(grep -E '^[A-Za-z]+=' "$LOGIND_SRC")
(( ${#LOGIND_SETTINGS[@]} > 0 )) || { log ERROR "$LOGIND_SRC sets nothing"; exit 1; }

live_logind_setting() {
  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager "$1" 2>/dev/null \
    | sed -n 's/^s "\(.*\)"$/\1/p'
}

# THE INSTALLED STATE, not the install's exit status:
#   - every copy a regular file (a symlink back into this checkout would hand
#     root a user-writable file), root-owned 0644, byte-identical to the checkout;
#   - systemd can load the unit: a copy it cannot load answers Result=success
#     to everything asked of it. (Not NeedDaemonReload: a never-started instance
#     is loaded fresh on every query, so it always says "no", and every new
#     instance reads the file on disk anyway.)
#   - the replaced drop-in gone: it would override the new one at the next
#     reload, while every live value still looked right;
#   - logind running with every setting: a drop-in logind has not re-read looks
#     installed and does nothing until the next boot.
check_installed() {
  local bad=0 i st load setting key want live is_logind_stale=0
  if [[ -e "$SUPERSEDED_LOGIND_DST" ]]; then
    log ERROR "$SUPERSEDED_LOGIND_DST is superseded and still installed — re-run: dock-lid-setup"; bad=1
  fi
  for i in "${!SRCS[@]}"; do
    if [[ -L "${DSTS[$i]}" ]]; then
      log ERROR "${DSTS[$i]} is a SYMLINK — root would read a file you can write; re-run: dock-lid-setup"; bad=1
    elif [[ ! -e "${DSTS[$i]}" ]]; then
      log ERROR "${DSTS[$i]} is not installed — run: dock-lid-setup"; bad=1
    elif ! cmp -s "${SRCS[$i]}" "${DSTS[$i]}"; then
      log ERROR "${DSTS[$i]} DIFFERS from ${SRCS[$i]} — re-run: dock-lid-setup"; bad=1
    elif st="$(stat -c '%U:%G %a' "${DSTS[$i]}")" && [[ "$st" != "$WANT_STAT" ]]; then
      log ERROR "${DSTS[$i]} is ${st}, not ${WANT_STAT} — re-run: dock-lid-setup"; bad=1
    else
      log SUCCESS "${DSTS[$i]} matches this checkout (${st})"
    fi
  done
  # `|| true` on both reads: --check calls this as a plain command, where
  # set -e and pipefail would make a failing systemctl or busctl end the script
  # right here, silently. (The install path calls it from an `||` list, where
  # bash suspends set -e for the whole function body.)
  load="$(systemctl show -p LoadState --value "$UNIT_PROBE" 2>/dev/null || true)"
  if [[ "$load" != "loaded" ]]; then
    log ERROR "systemd cannot load dock-lid-holdoff@.service (LoadState=${load:-unknown})"
    log ERROR "  re-run: dock-lid-setup"
    bad=1
  else
    log SUCCESS "systemd can load dock-lid-holdoff@.service"
  fi
  for setting in "${LOGIND_SETTINGS[@]}"; do
    key="${setting%%=*}" want="${setting#*=}"
    live="$(live_logind_setting "$key" || true)"
    if [[ "$live" == "$want" ]]; then
      log SUCCESS "logind is running with $key=$live"
    else
      log ERROR "logind is running with $key='${live}', not '${want}'"
      is_logind_stale=1
    fi
  done
  if (( is_logind_stale )); then
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
# report the live checkout as drift. A worktree is exactly a checkout whose
# git-dir is not the repository's common dir — true of a worktree of a bare or
# --separate-git-dir repository too, which a match on "/.git/worktrees/" misses.
# Not a git checkout at all (a copied tree) is not a worktree.
git_dir="$(git -C "$DOTFILES" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
common_dir="$(git -C "$DOTFILES" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -n "$git_dir" && -n "$common_dir" && "$git_dir" != "$common_dir" ]]; then
  log ERROR "refusing to install from a WORKTREE: $DOTFILES"
  log ERROR "  Run this from the live checkout:"
  log ERROR "    cd ~/.dotfiles && dock-lid-setup"
  log ERROR "  (set DOCK_LID_SETUP_ALLOW_WORKTREE=1 to override, e.g. to test a branch.)"
  [[ "${DOCK_LID_SETUP_ALLOW_WORKTREE:-0}" == "1" ]] || exit 1
  log WARNING "DOCK_LID_SETUP_ALLOW_WORKTREE=1 — continuing from a worktree anyway."
fi

# VALIDATE BEFORE INSTALLING, with udev's and systemd's own parsers. A rule udevd
# cannot parse is skipped with one line in the journal, and a unit systemd cannot
# load answers Result=success to everything asked of it — either way the guard
# looks installed and never fires. Each parser's own explanation is printed.
log INFO "Validating the rule and the unit"
if ! udevadm verify --help >/dev/null 2>&1; then
  log ERROR "this udevadm has no 'verify' (systemd < 254), so the rule cannot be validated — nothing installed"
  exit 1
fi
if ! out="$(udevadm verify --resolve-names=never "$RULE_SRC" 2>&1)"; then
  log ERROR "udevadm verify rejects $RULE_SRC — nothing installed:"
  show_output "$out"
  exit 1
fi
# systemd-analyze verify exits 0 on a WARNING — "<file>:18: Unknown key 'Typo' in
# section [Service], ignoring." — so a misspelled key would pass on the exit
# status alone: any line naming this unit is a rejection. But it also loads the
# unit's whole dependency closure (sysinit, basic, every enabled socket and
# timer) and reports on those too, so --recursive-errors=no and the filter keep
# an unrelated unit's warning from blocking the install.
if ! out="$(systemd-analyze verify --man=no --recursive-errors=no "$UNIT_SRC" 2>&1)" \
   || grep -q -F -e "$UNIT_SRC" -e 'dock-lid-holdoff@' <<<"$out"; then
  log ERROR "systemd-analyze verify rejects $UNIT_SRC — nothing installed:"
  show_output "$out"
  exit 1
fi

log INFO "Installing root-owned files"
# Create a MISSING parent 0755 (logind.conf.d does not exist on a fresh machine)
# and never touch an existing one: `install -d -m 755 -o root` on every parent
# would chmod and chown /etc/systemd/system itself, and `install -D` would make
# a new one with the caller's umask, which a non-root --check cannot then read.
for d in "${PREFIX}/etc/systemd/logind.conf.d" "${PREFIX}/etc/udev/rules.d" "${PREFIX}/etc/systemd/system"; do
  [[ -d "$d" ]] || sudo install -d -m 755 -o root -g root "$d"
done
sudo install -m 644 -o root -g root "$LOGIND_SRC" "$LOGIND_DST"
sudo install -m 644 -o root -g root "$RULE_SRC"   "$RULE_DST"
sudo install -m 644 -o root -g root "$UNIT_SRC"   "$UNIT_DST"
log SUCCESS "installed $LOGIND_DST, $RULE_DST, $UNIT_DST"
# Before the logind reload, which would otherwise read it once more.
if [[ -e "$SUPERSEDED_LOGIND_DST" ]]; then
  sudo rm -f "$SUPERSEDED_LOGIND_DST"
  log SUCCESS "removed the superseded $SUPERSEDED_LOGIND_DST"
fi

sudo systemctl daemon-reload
sudo udevadm control --reload
# RELOAD, never restart: restarting logind ends every session on the machine.
# Where logind cannot reload, the check below says so and names the reboot.
sudo systemctl reload systemd-logind \
  || log WARNING "could not reload systemd-logind; the logind setting applies at the next boot"

echo
check_installed || exit 1
echo
log SUCCESS "Done. Each USB-C plug-in starts one holdoff; confirm with:"
log SUCCESS "  journalctl -u 'dock-lid-holdoff@*' -b"
