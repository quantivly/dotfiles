#!/usr/bin/env bash
# setup-audit-rules.sh — install the broadcast-kill tripwire (audit/*.rules).
#
# Installs audit/99-logout-catch.rules into /etc/audit/rules.d/ and loads it.
# Idempotent: safe to re-run to resync after editing the repo copy.
#
# The rules file is COPIED root-owned rather than symlinked into ~/.dotfiles —
# same reasoning as resticprofile/profiles.toml: root's auditd reads it, and a
# user-writable file consumed by root is a privilege-escalation hole.
#
# Run via `audit-setup` (zsh/functions/system.sh). See docs/TROUBLESHOOTING.md.
#
# Usage: setup-audit-rules.sh [--yes]
#   --yes   don't prompt before installing the auditd package (for unattended runs)
set -euo pipefail

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y | --yes) ASSUME_YES=1 ;;
    # Print the header comment block, stopping at the first line of code.
    -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
      "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_SRC="${DOTFILES}/audit/99-logout-catch.rules"
RULES_DIR="/etc/audit/rules.d"
RULES_DST="${RULES_DIR}/99-logout-catch.rules"
KEY="logoutsweep"

# --- pretty logging (mirrors scripts/setup-backup.sh) ------------------------
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

[[ -f "$RULES_SRC" ]] || { log ERROR "missing $RULES_SRC"; exit 1; }

# --- auditd ------------------------------------------------------------------
# Note the trade-off before installing: auditd takes ownership of the kernel
# audit netlink socket, so AppArmor denials stop appearing in `journalctl -k`
# and move to `ausearch -m AVC`. That surprises anyone debugging snap
# confinement (see CLAUDE.md's AppArmor notes), so say it out loud.
#
# This side effect is system-wide and unrelated to what the user asked for, so
# confirm before causing it (matching setup-backup.sh's use of confirm for
# consequential steps). Non-interactive runs need --yes rather than a hang.
if ! command -v auditctl >/dev/null 2>&1; then
  log INFO "auditd is not installed — it is required to load audit rules."
  log WARNING "Installing it moves AppArmor denials out of 'journalctl -k' into 'sudo ausearch -m AVC'."
  if ! command -v apt-get >/dev/null 2>&1; then
    log ERROR "no apt-get here; install auditd manually, then re-run."
    exit 1
  fi
  if (( ! ASSUME_YES )); then
    if [[ ! -t 0 ]]; then
      log ERROR "auditd install needs confirmation; re-run with --yes for an unattended install."
      exit 1
    fi
    printf 'Install auditd + audispd-plugins now? [y/N] '
    read -r reply
    case "$reply" in
      [yY] | [yY][eE][sS]) ;;
      *) log INFO "Aborted — nothing installed."; exit 0 ;;
    esac
  fi
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y auditd audispd-plugins
fi

# --- install + load ----------------------------------------------------------
sudo install -d -m 750 -o root -g root "$RULES_DIR"
sudo install -m 640 -o root -g root "$RULES_SRC" "$RULES_DST"
log SUCCESS "audit/99-logout-catch.rules → $RULES_DST (root-owned copy)"

if ! sudo systemctl enable --now auditd.service >/dev/null 2>&1; then
  log WARNING "'systemctl enable --now auditd' failed — checked below, since kernel rules load without it."
fi

# augenrules rebuilds /etc/audit/audit.rules from every file in rules.d and
# reloads. Ubuntu's stock base file starts with `-D`, so there is a sub-second
# window with no rules loaded, and any dynamically-added rules are dropped.
if ! sudo augenrules --load >/dev/null 2>&1; then
  log WARNING "augenrules --load reported a problem; falling back to auditctl -R"
  sudo auditctl -R "$RULES_DST" >/dev/null 2>&1 || true
fi

# --- verify (the whole point) ------------------------------------------------
# A rule that fails to load leaves auditctl silent, which reads exactly like a
# machine where nothing bad ever happens. Assert it is actually armed, and fail
# loudly if not — an unverified tripwire is worse than none, because it is
# trusted.
#
# "Armed" needs all three of these, because each can be false while the other
# two look fine:
#   1. the rules are in the kernel      (auditctl -l)
#   2. auditing is switched on          (auditctl -s -> enabled != 0)
#   3. a daemon is holding the netlink socket to persist records to disk
#      (auditctl -s -> pid != 0). Rules live in the KERNEL, so `auditctl -l`
#      lists them happily with auditd stopped — but then records go to the
#      kernel ring buffer instead of /var/log/audit/audit.log, and ausearch
#      (so `audit-sweeps`) sees nothing, forever, with no error. That is the
#      exact silent failure this whole feature exists to prevent.
expected=$(grep -c '^-a ' "$RULES_SRC" || true)
loaded=$(sudo auditctl -l 2>/dev/null | grep -c -- "-k ${KEY}\|key=${KEY}" || true)
if [[ "$loaded" -lt 1 ]]; then
  log ERROR "rules did NOT load — the tripwire is not armed."
  log ERROR "Check 'sudo auditctl -s' and 'sudo auditctl -l'. A rejected field"
  log ERROR "(e.g. an unsupported 'a1!=0' operator) leaves zero rules silently."
  exit 1
fi
if [[ "$loaded" -lt "$expected" ]]; then
  # Most likely the arch=b32 rule on a kernel built without 32-bit compat. The
  # b64 rule still covers every 64-bit process, so this is a warning, not a
  # failure — but it must not pass silently as "armed".
  log WARNING "only ${loaded} of ${expected} rules loaded — one arch was rejected."
  log WARNING "Compare 'sudo auditctl -l' against ${RULES_DST} to see which."
fi

# `auditctl -s` prints one "key value" per line on audit 3.x, but a single
# "AUDIT_STATUS: key=value key=value ..." line on 2.x. Flatten both into one
# token per line and take the token after the key, so this reads either.
# NOTE: not named `status` — that is read-only in zsh, and these helpers are
# mirrored into zsh/functions/system.sh.
astat=$(sudo auditctl -s 2>/dev/null || true)
audit_stat() {
  printf '%s\n' "$astat" | tr '=' ' ' | tr -s '[:space:]' '\n' \
    | awk -v k="$1" 'found { print; exit } $0 == k { found = 1 }'
}
if [[ -z "$astat" ]]; then
  log ERROR "'auditctl -s' returned nothing — cannot confirm auditing is live."
  exit 1
fi
audit_enabled=$(audit_stat enabled)
audit_pid=$(audit_stat pid)

if [[ "${audit_enabled:-0}" == "0" ]]; then
  log ERROR "kernel auditing is DISABLED (enabled 0) — the rules will never match."
  log ERROR "Enable it with: sudo auditctl -e 1"
  exit 1
fi
if [[ "${audit_pid:-0}" == "0" ]]; then
  log ERROR "no audit daemon is registered (pid 0) — records would go to the kernel"
  log ERROR "ring buffer, not /var/log/audit/audit.log, so 'audit-sweeps' would"
  log ERROR "report nothing no matter what happens. The rules are loaded but USELESS."
  log ERROR "Fix with: sudo systemctl enable --now auditd && sudo systemctl status auditd"
  exit 1
fi
log SUCCESS "tripwire armed (${loaded} rule(s), key=${KEY})"
log SUCCESS "recording confirmed (auditing enabled, auditd pid ${audit_pid})"

echo
log INFO "Read hits with:  audit-sweeps [hours]      (default 24)"
log INFO "Check health with: audit-status"
