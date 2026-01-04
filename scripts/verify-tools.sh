#!/usr/bin/env bash
# Comprehensive tool installation status check
#
# This script verifies which development tools are installed and provides
# their versions. It's useful for:
# - Onboarding new developers
# - Troubleshooting environment issues
# - Verifying post-setup state
# - Checking which optional tools are available
#
# Usage:
#   ./scripts/verify-tools.sh
#   verify-tools  # If symlinked to ~/.local/bin

set -e

# Color codes (only if TTY)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Check if command exists and show version
check_tool() {
    local tool=$1
    local version_cmd=${2:-"--version"}
    local is_required=${3:-false}

    if command -v "$tool" &>/dev/null; then
        local version
        version=$(eval "$tool $version_cmd" 2>&1 | head -1)
        echo -e "${GREEN}✓${NC} $tool: $version"
        return 0
    else
        if [[ "$is_required" == true ]]; then
            echo -e "${YELLOW}✗${NC} $tool: NOT FOUND (required)"
        else
            echo -e "  ○ $tool: not installed (optional)"
        fi
        return 1
    fi
}

echo -e "${BLUE}=== Required Tools ===${NC}"
check_tool zsh "--version" true
check_tool git "--version" true
check_tool bash "--version" true

echo ""
echo -e "${BLUE}=== Strongly Recommended Tools ===${NC}"
check_tool fzf "--version"
check_tool gh "--version"

echo ""
echo -e "${BLUE}=== Modern CLI Tools (Replacements) ===${NC}"
check_tool bat "--version" || check_tool batcat "--version"
check_tool eza "--version" || check_tool exa "--version"
check_tool fd "--version" || check_tool fdfind "--version"
check_tool rg "--version"
check_tool delta "--version"
check_tool zoxide "--version"
check_tool btop "--version"
check_tool procs "--version"
check_tool duf "--version"
check_tool dust "--version"

echo ""
echo -e "${BLUE}=== Version Manager ===${NC}"
check_tool mise "--version"

echo ""
echo -e "${BLUE}=== Developer Tools ===${NC}"
check_tool lazygit "--version"
check_tool just "--version"
check_tool glow "--version"
check_tool hyperfine "--version"
check_tool dive "--version"
check_tool ctop "-v"  # ctop uses -v not --version
check_tool lazydocker "--version"

echo ""
echo -e "${BLUE}=== Security & Code Quality ===${NC}"
check_tool gitleaks "version"

# Check pre-commit (prefer user-installed version over virtualenv)
if [[ -x "$HOME/.local/bin/pre-commit" ]]; then
    # Use local version but display as "pre-commit" not full path
    precommit_version=$("$HOME/.local/bin/pre-commit" --version 2>&1 | head -1)
    echo -e "${GREEN}✓${NC} pre-commit: $precommit_version"
elif command -v pre-commit &>/dev/null; then
    check_tool pre-commit "--version"
else
    echo -e "  ○ pre-commit: not installed (optional)"
fi

check_tool sops "--version"
check_tool gpg "--version"

echo ""
echo -e "${BLUE}=== Productivity Tools ===${NC}"
check_tool thefuck "--version"
check_tool tldr "--version"
check_tool cheat "--version"
check_tool fastfetch "--version" || check_tool neofetch "--version"

echo ""
echo -e "${BLUE}=== Optional Development Tools ===${NC}"
check_tool direnv "version"
check_tool autojump "--version"
check_tool poetry "--version"
check_tool docker "--version"
check_tool docker-compose "--version"

echo ""
echo -e "${BLUE}=== Oh-My-Zsh Plugins ===${NC}"
if [[ -d ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions ]]; then
    echo -e "${GREEN}✓${NC} zsh-autosuggestions: installed"
else
    echo -e "  ○ zsh-autosuggestions: not installed"
fi

if [[ -d ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting ]]; then
    echo -e "${GREEN}✓${NC} zsh-syntax-highlighting: installed"
else
    echo -e "  ○ zsh-syntax-highlighting: not installed"
fi

if [[ -d ~/.oh-my-zsh/custom/plugins/zsh-fzf-history-search ]]; then
    echo -e "${GREEN}✓${NC} zsh-fzf-history-search: installed"
else
    echo -e "  ○ zsh-fzf-history-search: not installed"
fi

if [[ -d ~/.oh-my-zsh/custom/themes/powerlevel10k ]]; then
    echo -e "${GREEN}✓${NC} powerlevel10k theme: installed"
else
    echo -e "  ○ powerlevel10k theme: not installed"
fi

echo ""
echo -e "${BLUE}=== Forgit (Git + FZF Integration) ===${NC}"
if [[ -d ~/.forgit ]]; then
    echo -e "${GREEN}✓${NC} forgit: installed"
else
    echo -e "  ○ forgit: not installed (optional)"
fi

echo ""
echo -e "${BLUE}=== Summary ===${NC}"
echo "For installation instructions, see:"
echo "  - ~/.dotfiles/CLAUDE.md (comprehensive guide)"
echo "  - ~/.dotfiles/scripts/install-modern-tools.sh (automated installer)"
echo ""
echo "To install missing tools via mise:"
echo "  mise install"
echo ""
