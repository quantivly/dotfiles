#!/usr/bin/env bash
#
# scripts/install-prerequisites.sh
# ================================
#
# Automated installation of shell prerequisites for dotfiles:
#   - oh-my-zsh framework
#   - Powerlevel10k theme
#   - zsh plugins (autosuggestions, syntax-highlighting, fzf-history-search)
#   - fzf fuzzy finder
#
# This script is a simplified, standalone version extracted from quantivly/dev-setup.
# It provides a better experience for standalone dotfiles users.
#
# Usage:
#   ./scripts/install-prerequisites.sh
#
# Requirements:
#   - zsh, git, curl installed (sudo apt install zsh git curl build-essential)
#   - Internet connection
#
# Security:
#   - HTTPS downloads only
#   - Network timeouts and retries
#   - Idempotent (safe to re-run)
#   - No checksum verification (relies on HTTPS + official GitHub repos)
#
# Source: Adapted from quantivly/dev-setup modules/shell.sh (DO-260)
#

set -euo pipefail

# Configuration
readonly CURL_OPTS="--max-time 300 --connect-timeout 10 --retry 3"

# Color codes (only if terminal supports it)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly RESET='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly CYAN=''
    readonly BOLD=''
    readonly RESET=''
fi

#######################################
# Logging function with color support
# Arguments:
#   $1 - Level (INFO, SUCCESS, WARNING, ERROR, STEP)
#   $@ - Message
#######################################
log() {
    local level="$1"
    shift
    local message="$*"

    case "$level" in
        INFO)    echo -e "${BLUE}▶${RESET} $message" ;;
        SUCCESS) echo -e "${GREEN}✓${RESET} $message" ;;
        WARNING) echo -e "${YELLOW}⚠${RESET} $message" ;;
        ERROR)   echo -e "${RED}✗${RESET} $message" >&2 ;;
        STEP)    echo -e "\n${CYAN}${BOLD}➜ $message${RESET}" ;;
    esac
}

#######################################
# Log error and exit
# Arguments:
#   $1 - Error message
#######################################
error_exit() {
    log ERROR "$1"
    exit 1
}

#######################################
# Check if command exists in PATH
# Arguments:
#   $1 - Command name
# Returns:
#   0 if command exists, 1 otherwise
#######################################
command_exists() {
    command -v "$1" &> /dev/null
}

#######################################
# Install oh-my-zsh framework
# Globals:
#   HOME, USER
#######################################
install_oh_my_zsh() {
    log STEP "Installing oh-my-zsh"

    # Check if already installed
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        log INFO "oh-my-zsh already installed at $HOME/.oh-my-zsh"
        return 0
    fi

    log INFO "Installing oh-my-zsh (unattended mode)..."

    # Download installer
    local temp_dir
    temp_dir=$(mktemp -d)
    chmod 700 "$temp_dir"
    local installer="$temp_dir/install-ohmyzsh.sh"

    # shellcheck disable=SC2086  # CURL_OPTS intentionally unquoted
    if ! curl $CURL_OPTS -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$installer"; then
        rm -rf "$temp_dir"
        error_exit "Failed to download oh-my-zsh installer"
    fi

    # Verify installer file was downloaded
    if [[ ! -f "$installer" ]]; then
        rm -rf "$temp_dir"
        error_exit "oh-my-zsh installer download produced no file"
    fi

    # Run oh-my-zsh installer in unattended mode
    # RUNZSH=no prevents automatic shell switch
    # CHSH=no prevents changing default shell (we do that explicitly later)
    if RUNZSH=no CHSH=no sh "$installer" --unattended; then
        log SUCCESS "oh-my-zsh installed successfully"
    else
        rm -rf "$temp_dir"
        error_exit "oh-my-zsh installation failed"
    fi

    rm -rf "$temp_dir"

    # Change default shell to zsh if not already
    local username="${USER:-$(whoami)}"
    local current_shell
    current_shell=$(getent passwd "$username" | cut -d: -f7)
    if [[ "$current_shell" != *"zsh"* ]]; then
        log INFO "Changing default shell to zsh..."
        if command_exists chsh; then
            if sudo chsh -s "$(command -v zsh)" "$username"; then
                log SUCCESS "Default shell changed to zsh"
            else
                log WARNING "Failed to change default shell - run manually: chsh -s $(command -v zsh)"
            fi
        else
            log WARNING "chsh not available - cannot change default shell"
        fi
    else
        log INFO "Default shell is already zsh"
    fi
}

#######################################
# Install Powerlevel10k theme
# Globals:
#   HOME
#######################################
install_powerlevel10k() {
    log STEP "Installing Powerlevel10k Theme"

    local p10k_dir="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"

    # Check if already installed
    if [[ -d "$p10k_dir" ]]; then
        log INFO "Powerlevel10k already installed at $p10k_dir"
        return 0
    fi

    # Requires oh-my-zsh
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        log WARNING "oh-my-zsh not installed - skipping Powerlevel10k"
        return 0
    fi

    log INFO "Cloning Powerlevel10k theme (depth=1 for faster download)..."
    if timeout 60 git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir"; then
        log SUCCESS "Powerlevel10k installed successfully"
    else
        log WARNING "Failed to install Powerlevel10k - shell will use fallback theme"
    fi
}

#######################################
# Install zsh plugins
# Installs: autosuggestions, syntax-highlighting, fzf-history-search
# Globals:
#   HOME
#######################################
install_zsh_plugins() {
    log STEP "Installing zsh Plugins"

    local plugins_dir="$HOME/.oh-my-zsh/custom/plugins"

    # Requires oh-my-zsh
    if [[ ! -d "$plugins_dir" ]]; then
        log WARNING "oh-my-zsh custom plugins directory not found - skipping zsh plugins"
        return 0
    fi

    # zsh-autosuggestions - Fish-like command suggestions
    if [[ ! -d "$plugins_dir/zsh-autosuggestions" ]]; then
        if timeout 60 git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$plugins_dir/zsh-autosuggestions"; then
            log SUCCESS "zsh-autosuggestions installed"
        else
            log WARNING "Failed to install zsh-autosuggestions"
        fi
    else
        log INFO "zsh-autosuggestions already installed"
    fi

    # zsh-syntax-highlighting - Fish-like syntax highlighting
    if [[ ! -d "$plugins_dir/zsh-syntax-highlighting" ]]; then
        if timeout 60 git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$plugins_dir/zsh-syntax-highlighting"; then
            log SUCCESS "zsh-syntax-highlighting installed"
        else
            log WARNING "Failed to install zsh-syntax-highlighting"
        fi
    else
        log INFO "zsh-syntax-highlighting already installed"
    fi

    # zsh-fzf-history-search - FZF-based history search
    if [[ ! -d "$plugins_dir/zsh-fzf-history-search" ]]; then
        if timeout 60 git clone --depth=1 https://github.com/joshskidmore/zsh-fzf-history-search "$plugins_dir/zsh-fzf-history-search"; then
            log SUCCESS "zsh-fzf-history-search installed"
        else
            log WARNING "Failed to install zsh-fzf-history-search"
        fi
    else
        log INFO "zsh-fzf-history-search already installed"
    fi

    log SUCCESS "zsh plugins installation complete"
}

#######################################
# Install fzf fuzzy finder
# Globals:
#   HOME
#######################################
install_fzf() {
    log STEP "Installing fzf (Fuzzy Finder)"

    # Check if already installed
    if command_exists fzf; then
        log INFO "fzf already installed: $(fzf --version 2>/dev/null | head -1)"
        return 0
    fi

    # Install from git
    local fzf_dir="$HOME/.fzf"
    if [[ ! -d "$fzf_dir" ]]; then
        log INFO "Installing fzf from git..."
        if timeout 60 git clone --depth 1 https://github.com/junegunn/fzf.git "$fzf_dir"; then
            # Run fzf installer (key-bindings, completion, no rc modifications)
            if "$fzf_dir/install" --key-bindings --completion --no-update-rc --no-bash --no-fish &>/dev/null; then
                log SUCCESS "fzf installed from git"
            else
                log WARNING "fzf installation script failed"
            fi
        else
            log WARNING "Failed to clone fzf repository"
        fi
    else
        log INFO "fzf directory already exists at $fzf_dir"
    fi
}

#######################################
# Check for tmux installation
#######################################
check_tmux() {
    log STEP "Checking for tmux"

    if command_exists tmux; then
        log SUCCESS "tmux is already installed: $(tmux -V)"
    else
        log WARNING "tmux is not installed"
        log INFO "Install with: sudo apt install tmux"
    fi
}

#######################################
# Main installation flow
#######################################
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Dotfiles Prerequisites Installer                  ║"
    echo "║   Installing: oh-my-zsh, Powerlevel10k, plugins, fzf║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    # Check prerequisites
    if ! command_exists git; then
        error_exit "git is not installed. Please install: sudo apt install git"
    fi

    if ! command_exists curl; then
        error_exit "curl is not installed. Please install: sudo apt install curl"
    fi

    if ! command_exists zsh; then
        error_exit "zsh is not installed. Please install: sudo apt install zsh"
    fi

    # Run installations
    install_oh_my_zsh
    install_powerlevel10k
    install_zsh_plugins
    install_fzf
    check_tmux

    # Summary
    echo ""
    log SUCCESS "Prerequisites installation complete!"
    echo ""
    echo -e "${CYAN}Next steps:${RESET}"
    echo "  1. Run the dotfiles installer: ${BOLD}./install${RESET}"
    echo "  2. Configure git identity: ${BOLD}vim ~/.gitconfig.local${RESET}"
    echo "  3. Restart your terminal or run: ${BOLD}exec zsh${RESET}"
    echo ""
}

# Run main function
main "$@"
