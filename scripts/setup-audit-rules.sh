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
set -euo pipefail

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
if ! command -v auditctl >/dev/null 2>&1; then
  log INFO "auditd is not installed — it is required to load audit rules."
  log WARNING "Installing it moves AppArmor denials out of 'journalctl -k' into 'sudo ausearch -m AVC'."
  if command -v apt-get >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y auditd audispd-plugins
  else
    log ERROR "no apt-get here; install auditd manually, then re-run."
    exit 1
  fi
fi

# --- install + load ----------------------------------------------------------
sudo install -d -m 750 -o root -g root "$RULES_DIR"
sudo install -m 640 -o root -g root "$RULES_SRC" "$RULES_DST"
log SUCCESS "audit/99-logout-catch.rules → $RULES_DST (root-owned copy)"

sudo systemctl enable --now auditd.service >/dev/null 2>&1 || true

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
loaded=$(sudo auditctl -l 2>/dev/null | grep -c -- "-k ${KEY}\|key=${KEY}" || true)
if [[ "$loaded" -lt 1 ]]; then
  log ERROR "rules did NOT load — the tripwire is not armed."
  log ERROR "Check 'sudo auditctl -s' and 'sudo auditctl -l'. A rejected field"
  log ERROR "(e.g. an unsupported 'a1!=0' operator) leaves zero rules silently."
  exit 1
fi
log SUCCESS "tripwire armed (${loaded} rule(s), key=${KEY})"

echo
log INFO "Read hits with:  audit-sweeps [hours]      (default 24)"
log INFO "Check health with: audit-status"
