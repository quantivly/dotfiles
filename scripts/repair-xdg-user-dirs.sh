#!/usr/bin/env bash
#
# scripts/repair-xdg-user-dirs.sh
# ===============================
#
# Keep the standard XDG user directories healthy and prevent the recurring
# "broken self-referential symlink" failure mode where ~/Desktop, ~/Documents,
# ~/Music, ~/Public, ~/Templates and ~/Videos turn into dangling links
# (~/Desktop -> /home/<user>/Desktop) that show a red ✗ in GNOME Files and make
# `cd ~/Documents` fail.
#
# The cycle this breaks:
#   1. A standard XDG dir does not exist as a real directory.
#   2. `xdg-user-dirs-update` (runs each login) honours its "don't recreate what
#      the user deleted" rule and collapses the entry in ~/.config/user-dirs.dirs
#      to XDG_<X>_DIR="$HOME/".
#   3. snapd-desktop-integration mirrors XDG dirs into snap sandboxes and, for the
#      collapsed/missing entries, creates a self-referential symlink back in the
#      real $HOME.
#   4. The broken link keeps the dir "missing", so step 2 repeats forever.
#
# A folder that exists as a *real directory* is left alone by both tools, so the
# durable fix is simply: remove the broken links, ensure the real dirs exist, and
# point user-dirs.dirs at them. This script does exactly that, idempotently.
#
# Idempotent — safe to re-run; a no-op when everything is already healthy.
# Desktop-only — exits cleanly with no changes when `xdg-user-dirs-update` is
# absent (e.g. minimal servers), so it is harmless in the ./install flow.
#
# Usage:
#   ./scripts/repair-xdg-user-dirs.sh      (or: xdg-repair)
#
# Requirements:
#   - xdg-user-dirs-update (Ubuntu: provided by the xdg-user-dirs package)
#
# Security:
#   - No secrets. Only removes *broken* symlinks (never real dirs or links that
#     resolve to existing data) and creates empty directories under $HOME.

set -euo pipefail

# Color codes (only if terminal supports it)
if [[ -t 1 ]]; then
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly RESET='\033[0m'
else
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly RESET=''
fi

log() {
    local level="$1"; shift
    case "$level" in
        INFO)    echo -e "${BLUE}▶${RESET} $*" ;;
        SUCCESS) echo -e "${GREEN}✓${RESET} $*" ;;
        WARNING) echo -e "${YELLOW}⚠${RESET} $*" >&2 ;;
    esac
}

# Standard XDG slots as "NAME:RelativeDir" pairs. Matches the system template at
# /etc/xdg/user-dirs.defaults. Keeping every slot as a real directory (even the
# unused ones) is what stops the collapse-then-symlink cycle described above.
readonly XDG_DIRS=(
    DESKTOP:Desktop
    DOWNLOAD:Downloads
    TEMPLATES:Templates
    PUBLICSHARE:Public
    DOCUMENTS:Documents
    MUSIC:Music
    PICTURES:Pictures
    VIDEOS:Videos
)

main() {
    if ! command -v xdg-user-dirs-update >/dev/null 2>&1; then
        log INFO "xdg-user-dirs-update not found — skipping (not a desktop system)."
        exit 0
    fi

    local changed=0 pair name key dir link

    # Step A — remove broken self-referential symlinks.
    # `-L` ensures it is a symlink; `! -e` is true only when the target does not
    # exist, so real directories and links pointing at real data are never touched.
    for pair in "${XDG_DIRS[@]}"; do
        name="${pair##*:}"
        link="${HOME}/${name}"
        if [[ -L "$link" && ! -e "$link" ]]; then
            rm "$link"
            log SUCCESS "Removed broken symlink ~/${name}"
            changed=1
        fi
    done

    # Step B — ensure the real directories exist (before Step C, so the config
    # always points at an existing path).
    for pair in "${XDG_DIRS[@]}"; do
        name="${pair##*:}"
        dir="${HOME}/${name}"
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log SUCCESS "Created ~/${name}"
            changed=1
        fi
    done

    # Step C — repoint user-dirs.dirs at the real subdirs, undoing any "$HOME/"
    # collapse. Uses the canonical tool rather than hand-editing the file. Cheap
    # and effectively a no-op when the entry is already correct.
    for pair in "${XDG_DIRS[@]}"; do
        key="${pair%%:*}"
        name="${pair##*:}"
        xdg-user-dirs-update --set "$key" "${HOME}/${name}"
    done

    if [[ "$changed" -eq 1 ]]; then
        log SUCCESS "XDG user dirs repaired."
        log INFO "Run 'nautilus -q' to clear any stale GNOME Files view."
    else
        log INFO "XDG user dirs already healthy — no changes."
    fi
}

main "$@"
