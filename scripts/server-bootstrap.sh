#!/usr/bin/env bash
#
# scripts/server-bootstrap.sh
# ============================
#
# Bootstrap a remote server (AL2, Ubuntu, etc.) with the team's standard
# shell DX environment: zsh, oh-my-zsh, Powerlevel10k, tmux, modern CLI tools.
#
# Usage:
#   # From workstation (pipe over SSH):
#   ssh server 'bash -s' < ~/.dotfiles/scripts/server-bootstrap.sh
#
#   # On the server directly:
#   curl -fsSL https://raw.githubusercontent.com/quantivly/dotfiles/main/scripts/server-bootstrap.sh | bash
#
#   # Update mode (skip system packages, just pull + reinstall):
#   ~/.dotfiles/scripts/server-bootstrap.sh --update
#
# Features:
#   - Idempotent (safe to re-run)
#   - OS-aware (AL2/yum, Ubuntu/apt, Fedora/dnf)
#   - Server-optimized mise config (lightweight tool subset)
#   - Never overwrites .zshrc.local or .gitconfig.local
#
# Requirements:
#   - sudo access
#   - Internet connectivity
#

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

readonly DOTFILES_REPO="https://github.com/quantivly/dotfiles.git"
readonly DOTFILES_DIR="$HOME/.dotfiles"
readonly MISE_INSTALLER="https://mise.run"

UPDATE_MODE=false
[[ "${1:-}" == "--update" ]] && UPDATE_MODE=true

# Global state (set by detect_and_validate, used by install_system_packages)
PKG_MGR=""
PKG_INSTALL=""

# ─────────────────────────────────────────────────────────────────────────────
# Color output
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

log_step()    { echo -e "\n${CYAN}${BOLD}[$1/6] $2${RESET}"; }
log_info()    { echo -e "${CYAN}▶${RESET} $*"; }
log_success() { echo -e "${GREEN}✓${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
log_error()   { echo -e "${RED}✗${RESET} $*" >&2; }

error_exit() {
    log_error "$1"
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Detect & Validate
# ─────────────────────────────────────────────────────────────────────────────

detect_and_validate() {
    log_step 1 "Detect & Validate"

    # Detect OS
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        log_info "OS: $PRETTY_NAME"
    else
        log_warn "Cannot detect OS (/etc/os-release not found)"
    fi

    # Detect package manager
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="sudo dnf install -y"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        PKG_INSTALL="sudo yum install -y"
    elif command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
        PKG_INSTALL="sudo apt-get install -y"
    else
        error_exit "No supported package manager found (dnf/yum/apt)"
    fi
    log_info "Package manager: $PKG_MGR"

    # Check sudo
    if ! sudo -n true 2>/dev/null; then
        # Try with password prompt
        if ! sudo true; then
            error_exit "sudo access required"
        fi
    fi
    log_success "sudo access verified"

    # Check internet connectivity
    if ! curl -fsS --max-time 5 https://github.com >/dev/null 2>&1; then
        error_exit "No internet connectivity (cannot reach github.com)"
    fi
    log_success "Internet connectivity verified"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: System Packages
# ─────────────────────────────────────────────────────────────────────────────

install_system_packages() {
    log_step 2 "System Packages"

    if $UPDATE_MODE; then
        log_info "Update mode — skipping system packages"
        return 0
    fi

    # Core packages needed for dotfiles
    local packages=(zsh git curl tmux jq htop make)

    # Add OS-specific packages
    if [[ "$PKG_MGR" == "apt" ]]; then
        packages+=(build-essential locales)
    else
        # gcc for native extensions, util-linux-user for chsh (missing on AL2 2023)
        packages+=(gcc gcc-c++ util-linux-user)
    fi

    log_info "Installing: ${packages[*]}"
    # shellcheck disable=SC2086  # PKG_INSTALL intentionally word-split
    $PKG_INSTALL "${packages[@]}" || log_warn "Some packages may have failed to install"

    # Ensure en_US.UTF-8 locale exists (AL2 often missing it)
    if ! locale -a 2>/dev/null | grep -qi "en_US.utf8\|en_US.UTF-8"; then
        log_info "Creating en_US.UTF-8 locale..."
        if command -v localedef &>/dev/null; then
            sudo localedef -i en_US -f UTF-8 en_US.UTF-8 2>/dev/null || true
            log_success "en_US.UTF-8 locale created"
        elif [[ "$PKG_MGR" == "apt" ]]; then
            sudo locale-gen en_US.UTF-8 2>/dev/null || true
        fi
    else
        log_success "en_US.UTF-8 locale already exists"
    fi

    # Set zsh as default shell for current user
    local current_shell
    current_shell=$(getent passwd "$(whoami)" | cut -d: -f7)
    if [[ "$current_shell" != *"zsh"* ]]; then
        local zsh_path
        zsh_path=$(command -v zsh)
        if [[ -n "$zsh_path" ]]; then
            # Ensure zsh is in /etc/shells
            if ! grep -q "$zsh_path" /etc/shells 2>/dev/null; then
                echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
            fi
            if sudo chsh -s "$zsh_path" "$(whoami)"; then
                log_success "Default shell set to zsh"
            else
                log_warn "Failed to set default shell — run: chsh -s $zsh_path"
            fi
        fi
    else
        log_success "Default shell is already zsh"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Dotfiles
# ─────────────────────────────────────────────────────────────────────────────

install_dotfiles() {
    log_step 3 "Dotfiles"

    # Clone or update dotfiles repo
    if [[ -d "$DOTFILES_DIR" ]]; then
        log_info "Dotfiles already cloned — pulling latest..."
        git -C "$DOTFILES_DIR" pull --ff-only || log_warn "git pull failed — continuing with existing version"
    else
        log_info "Cloning dotfiles..."
        if git clone --recursive "$DOTFILES_REPO" "$DOTFILES_DIR"; then
            log_success "Dotfiles cloned to $DOTFILES_DIR"
        else
            error_exit "Failed to clone dotfiles from $DOTFILES_REPO"
        fi
    fi

    # Run prerequisites installer (oh-my-zsh, p10k, plugins, fzf)
    if [[ -x "$DOTFILES_DIR/scripts/install-prerequisites.sh" ]]; then
        log_info "Running prerequisites installer..."
        bash "$DOTFILES_DIR/scripts/install-prerequisites.sh"
    else
        log_warn "Prerequisites script not found — skipping"
    fi

    # Run dotbot installer (symlinks, TPM, forgit, templates)
    log_info "Running dotfiles installer..."
    cd "$DOTFILES_DIR" && ./install
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: Server-specific mise
# ─────────────────────────────────────────────────────────────────────────────

install_mise_tools() {
    log_step 4 "Server mise Tools"

    # Ensure ~/.local/bin is in PATH for current session
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi

    # Install mise if not present (prefer local install over system-wide)
    local mise_bin=""
    if [[ -x "$HOME/.local/bin/mise" ]]; then
        mise_bin="$HOME/.local/bin/mise"
        log_success "mise found at $mise_bin"
    elif command -v mise &>/dev/null; then
        mise_bin="mise"
        log_success "mise already installed: $(mise --version 2>/dev/null | head -1)"
    else
        log_info "Installing mise..."
        if curl -fsSL "$MISE_INSTALLER" | sh; then
            mise_bin="$HOME/.local/bin/mise"
            log_success "mise installed"
        else
            log_warn "mise installation failed — skipping tool installation"
            return 0
        fi
    fi

    # Replace mise config with server-optimized subset
    local server_mise="$DOTFILES_DIR/examples/server-mise.toml"
    local mise_config="$HOME/.config/mise/config.toml"

    if [[ -f "$server_mise" ]]; then
        mkdir -p "$HOME/.config/mise"

        # Remove symlink if install script created one (server needs a copy, not a symlink)
        if [[ -L "$mise_config" ]]; then
            rm "$mise_config"
            log_info "Removed mise config symlink (servers use a copy)"
        fi

        cp "$server_mise" "$mise_config"
        log_success "Installed server mise config (lightweight tool subset)"
    else
        log_warn "Server mise config not found at $server_mise"
    fi

    # Trust and install tools
    $mise_bin trust "$DOTFILES_DIR/.mise.toml" 2>/dev/null || true
    $mise_bin trust "$HOME/.config/mise/config.toml" 2>/dev/null || true

    log_info "Installing mise tools (this may take a few minutes)..."
    if $mise_bin install 2>&1; then
        log_success "mise tools installed"
    else
        log_warn "Some mise tools may have failed to install — run: mise install"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: Server Identity
# ─────────────────────────────────────────────────────────────────────────────

setup_server_identity() {
    log_step 5 "Server Identity"

    # Copy server .zshrc.local template if not exists (NEVER overwrite)
    local server_template="$DOTFILES_DIR/examples/server-zshrc-local.template"
    if [[ ! -f "$HOME/.zshrc.local" ]]; then
        if [[ -f "$server_template" ]]; then
            cp "$server_template" "$HOME/.zshrc.local"
            chmod 600 "$HOME/.zshrc.local"
            log_success "Created ~/.zshrc.local from server template"
            log_info "Edit SERVER_NAME and SERVER_ENV: vim ~/.zshrc.local"
        else
            log_warn "Server template not found — .zshrc.local not created"
        fi
    else
        log_success "$HOME/.zshrc.local already exists (preserved)"
    fi

    # Create server-appropriate .gitconfig.local if not exists
    if [[ ! -f "$HOME/.gitconfig.local" ]]; then
        cat > "$HOME/.gitconfig.local" << 'GITCONFIG'
# Server Git Configuration
# ========================
# Minimal git config for server admin work.

[user]
	name = Quantivly Admin
	email = admin@quantivly.com

[core]
	editor = vim

# Use SSH URLs for Quantivly repos (no gh auth on servers)
[url "git@github.com:quantivly/"]
	insteadOf = https://github.com/quantivly/

[safe]
	directory = *
GITCONFIG
        chmod 600 "$HOME/.gitconfig.local"
        log_success "Created ~/.gitconfig.local (server defaults)"
        log_info "Update name/email if needed: vim ~/.gitconfig.local"
    else
        log_success "$HOME/.gitconfig.local already exists (preserved)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6: Verify & Summary
# ─────────────────────────────────────────────────────────────────────────────

verify_and_summarize() {
    log_step 6 "Verify & Summary"

    echo ""
    echo -e "${BOLD}Tool Status:${RESET}"

    local tools=(zsh tmux git mise bat eza fd lazygit zoxide)
    local missing=0
    for tool in "${tools[@]}"; do
        if command -v "$tool" &>/dev/null || [[ -x "$HOME/.local/bin/$tool" ]]; then
            local ver
            ver=$("$tool" --version 2>/dev/null | head -1 || echo "installed")
            echo -e "  ${GREEN}✓${RESET} $tool: $ver"
        else
            echo -e "  ${RED}✗${RESET} $tool: not found"
            ((missing++)) || true
        fi
    done

    echo ""
    if [[ $missing -gt 0 ]]; then
        log_warn "$missing tools not found — they may work after shell restart"
    fi

    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║   Server Bootstrap Complete!                         ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "${BOLD}Next steps:${RESET}"
    echo "  1. Set server identity:  vim ~/.zshrc.local"
    echo "     → Set SERVER_NAME and SERVER_ENV"
    echo "  2. Start a new shell:    exec zsh"
    echo "  3. Start tmux:           tmux new -s admin"
    echo ""
    echo -e "${BOLD}SSH config (on your workstation):${RESET}"
    echo "  # Auto-tmux for terminal SSH"
    echo "  Host myserver"
    echo "      HostName <hostname>"
    echo "      User ec2-user"
    echo "      ForwardAgent yes"
    echo "      RequestTTY yes"
    echo "      RemoteCommand tmux new-session -A -s admin"
    echo ""
    echo "  # Clean access for VSCode/scp"
    echo "  Host myserver-shell"
    echo "      HostName <hostname>"
    echo "      User ec2-user"
    echo "      ForwardAgent yes"
    echo ""
    echo -e "${BOLD}Update later:${RESET}"
    echo "  ~/.dotfiles/scripts/server-bootstrap.sh --update"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Server Shell DX Bootstrap                         ║"
    echo "║   zsh + oh-my-zsh + Powerlevel10k + tmux + tools    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    if $UPDATE_MODE; then
        echo -e "${YELLOW}Running in update mode (skipping system packages)${RESET}"
        echo ""
    fi

    detect_and_validate
    install_system_packages
    install_dotfiles
    install_mise_tools
    setup_server_identity
    verify_and_summarize
}

main "$@"
