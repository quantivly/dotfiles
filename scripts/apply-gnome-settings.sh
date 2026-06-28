#!/usr/bin/env bash
#
# scripts/apply-gnome-settings.sh
# ===============================
#
# Apply a clean, modern GNOME desktop configuration:
#   - Appearance:  dark mode, Yaru-prussiangreen-dark, teal accent, crisp fonts
#   - Dock:        floating, autohiding, centered at the bottom, decluttered
#   - Desktop:     all icons hidden (ding kept enabled, just invisible)
#   - Keybindings: free Ctrl+Alt+Arrow for tmux pane-resize (GNOME -> Super-based)
#
# The committed settings here are the *portable core* (the source of truth).
# Machine-specific bits (dock favorites, custom launch keys) live in
# ~/.gnome-settings.local, which is sourced at the end and never overwritten.
#
# Idempotent — safe to re-run (each key is only set when it differs).
# Workstation-only — exits cleanly with no changes when not running under GNOME,
# so it is harmless in the ./install flow on servers.
#
# Usage:
#   ./scripts/apply-gnome-settings.sh      (or: gnome-apply)
#
# Requirements:
#   - gsettings (Ubuntu: provided by libglib2.0-bin)
#   - A running GNOME session (Wayland or X11)
#
# Notes (Wayland):
#   - Appearance, dock, desktop and keybinding changes apply immediately.
#   - Extension/dock relayout is fully guaranteed after one log out / log in.
#   - Do NOT use `Alt+F2 r` / Meta.restart — that is X11-only.
#
# Security:
#   - No secrets. Settings only affect the current user's dconf database.
#

set -euo pipefail

# Snap-confined terminals (e.g. the Alacritty snap) export GIO_MODULE_DIR pointing
# at a private cache that lacks the dconf GSettings backend. Without it, `gsettings`
# silently falls back to an in-memory backend and every `set` becomes a no-op that
# never reaches the real dconf database. Drop it (and any forced memory backend) so
# GLib loads the system dconf backend and our writes actually persist.
unset GIO_MODULE_DIR
[[ "${GSETTINGS_BACKEND:-}" == "memory" ]] && unset GSETTINGS_BACKEND

# Color codes (only if terminal supports it)
if [[ -t 1 ]]; then
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
else
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly CYAN=''
    readonly BOLD=''
    readonly RESET=''
fi

readonly LOCAL_OVERRIDES="${HOME}/.gnome-settings.local"

#######################################
# Logging function with color support
# Arguments:
#   $1 - Level (INFO, SUCCESS, WARNING, STEP)
#   $@ - Message
#######################################
log() {
    local level="$1"
    shift
    local message="$*"

    case "$level" in
        INFO)    echo -e "${BLUE}▶${RESET} $message" ;;
        SUCCESS) echo -e "${GREEN}✓${RESET} $message" ;;
        WARNING) echo -e "${YELLOW}⚠${RESET} $message" >&2 ;;
        STEP)    echo -e "\n${CYAN}${BOLD}➜ $message${RESET}" ;;
    esac
}

# Cache the list of installed schemas once (cheaper than querying per key, and
# lets us skip cleanly on machines/versions where a schema is absent).
SCHEMAS="$(gsettings list-schemas 2>/dev/null || true)"

#######################################
# Idempotently set a gsettings key.
# Skips when the schema is absent (e.g. extension not installed) or the value is
# already correct, so re-runs are quiet and missing schemas never abort.
# Arguments:
#   $1 - schema (e.g. org.gnome.desktop.interface)
#   $2 - key
#   $3 - value in `gsettings get` form (strings keep their single quotes)
#######################################
gset() {
    local schema="$1" key="$2" value="$3"

    if ! grep -qx "$schema" <<<"$SCHEMAS"; then
        log WARNING "Schema '$schema' not found — skipping $key"
        return 0
    fi

    local current
    current="$(gsettings get "$schema" "$key" 2>/dev/null || true)"
    if [[ "$current" == "$value" ]]; then
        return 0
    fi

    # Numbers (notably doubles like 0.8 -> 0.80000000000000004) round-trip with a
    # different textual form; treat them as unchanged when numerically equal.
    local num_re='^-?[0-9]+(\.[0-9]+)?$'
    if [[ "$current" =~ $num_re && "$value" =~ $num_re ]] \
       && awk -v a="$current" -v b="$value" 'BEGIN{exit !(a==b)}'; then
        return 0
    fi

    if gsettings set "$schema" "$key" "$value" 2>/dev/null; then
        log SUCCESS "$key → $value"
    else
        log WARNING "Could not set $schema $key (key may not exist on this version)"
    fi
}

#######################################
# Verify we are on a GNOME desktop with gsettings available.
# Returns: 0 if GNOME, 1 otherwise
#######################################
is_gnome() {
    command -v gsettings >/dev/null 2>&1 || return 1
    printf '%s' "${XDG_CURRENT_DESKTOP:-}" | grep -qi gnome
}

apply_appearance() {
    log STEP "Appearance — dark, green-tinted"
    gset org.gnome.desktop.interface color-scheme          "'prefer-dark'"
    gset org.gnome.desktop.interface gtk-theme             "'Yaru-prussiangreen-dark'"
    gset org.gnome.desktop.interface icon-theme            "'Yaru-prussiangreen-dark'"
    gset org.gnome.desktop.interface accent-color          "'teal'"
    gset org.gnome.desktop.interface font-antialiasing     "'rgba'"
    gset org.gnome.desktop.interface font-hinting          "'slight'"
    gset org.gnome.desktop.interface clock-show-weekday    "true"
    gset org.gnome.desktop.interface show-battery-percentage "true"
}

apply_dock() {
    log STEP "Dock — floating, autohide, bottom"
    local schema="org.gnome.shell.extensions.dash-to-dock"
    gset "$schema" dock-position       "'BOTTOM'"
    gset "$schema" extend-height       "false"
    gset "$schema" dock-fixed          "false"
    gset "$schema" autohide            "true"
    gset "$schema" intellihide         "true"
    gset "$schema" dash-max-icon-size  "40"
    gset "$schema" transparency-mode   "'DYNAMIC'"
    gset "$schema" background-opacity  "0.8"
    gset "$schema" show-mounts         "false"
    gset "$schema" show-mounts-network "false"
    gset "$schema" show-trash          "false"
}

apply_desktop() {
    log STEP "Desktop — hide all icons (ding stays enabled, just invisible)"
    local schema="org.gnome.shell.extensions.ding"
    gset "$schema" show-home            "false"
    gset "$schema" show-trash           "false"
    gset "$schema" show-volumes         "false"
    gset "$schema" show-network-volumes "false"
    gset "$schema" show-link-emblem     "false"
    gset "$schema" show-drop-place      "false"
}

apply_keybindings() {
    # Free Ctrl+Alt+Arrow (GNOME workspace switching) so tmux pane-resize works.
    # See docs/TMUX_LEARNING_GUIDE.md and CLAUDE.md (Terminal gotchas).
    log STEP "Keybindings — free Ctrl+Alt+Arrow for tmux"
    local schema="org.gnome.desktop.wm.keybindings"
    gset "$schema" switch-to-workspace-up    "['<Super>Page_Up']"
    gset "$schema" switch-to-workspace-down  "['<Super>Page_Down']"
    gset "$schema" switch-to-workspace-left  "['<Super><Alt>Left']"
    gset "$schema" switch-to-workspace-right "['<Super><Alt>Right']"
}

apply_local_overrides() {
    [[ -f "$LOCAL_OVERRIDES" ]] || return 0
    log STEP "Machine-specific overrides (~/.gnome-settings.local)"
    # Sourced so it can reuse gset()/log(). User overrides must never abort the
    # run, so relax errexit around the include.
    set +e
    # shellcheck source=/dev/null
    source "$LOCAL_OVERRIDES"
    set -e
}

main() {
    if ! is_gnome; then
        log INFO "GNOME not detected (XDG_CURRENT_DESKTOP='${XDG_CURRENT_DESKTOP:-}') — skipping desktop config."
        exit 0
    fi

    log INFO "Applying GNOME desktop configuration ($(gnome-shell --version 2>/dev/null || echo 'GNOME'))"

    apply_appearance
    apply_dock
    apply_desktop
    apply_keybindings
    apply_local_overrides

    log STEP "Done"
    log SUCCESS "GNOME settings applied."
    log INFO "Most changes are live. Log out / log in once to guarantee the dock relayout."
    log INFO "Customize pinned apps & launch keys in: $LOCAL_OVERRIDES (run 'gnome-init' to create it)."
}

main "$@"
