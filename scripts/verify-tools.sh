#!/usr/bin/env bash
#
# Tool Installation Verification Script
# Checks which tools are installed for this dotfiles repository
#

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Symbols
CHECK="${GREEN}✓${NC}"
CROSS="${RED}✗${NC}"
CIRCLE="${YELLOW}○${NC}"

echo "=== Dotfiles Tool Installation Status ==="
echo

#==============================================================================
# Required Tools
#==============================================================================

echo "Required Tools:"
for tool in zsh git; do
    if command -v $tool &>/dev/null; then
        version=$(command $tool --version 2>&1 | head -1)
        echo -e "  ${CHECK} $tool: $version"
    else
        echo -e "  ${CROSS} $tool: NOT INSTALLED (required)"
    fi
done
echo

#==============================================================================
# Strongly Recommended Tools
#==============================================================================

echo "Strongly Recommended:"
for tool in fzf gh; do
    if command -v $tool &>/dev/null; then
        version=$($tool --version 2>&1 | head -1)
        echo -e "  ${CHECK} $tool: $version"
    else
        echo -e "  ${CROSS} $tool: not installed"
        if [ "$tool" = "fzf" ]; then
            echo "      Install: sudo apt install fzf  OR  brew install fzf"
        elif [ "$tool" = "gh" ]; then
            echo "      Install: https://cli.github.com/"
        fi
    fi
done
echo

#==============================================================================
# Modern CLI Replacements
#==============================================================================

echo "Modern CLI Replacements:"

# bat/batcat (cat replacement)
if command -v bat &>/dev/null; then
    version=$(bat --version 2>&1 | head -1)
    echo -e "  ${CHECK} bat (replaces cat): $version"
elif command -v batcat &>/dev/null; then
    version=$(batcat --version 2>&1 | head -1)
    echo -e "  ${CHECK} batcat (replaces cat): $version"
    echo "      Note: On Ubuntu, 'bat' is installed as 'batcat'"
else
    echo -e "  ${CIRCLE} bat (cat fallback active)"
    echo "      Install: sudo apt install bat  OR  brew install bat"
fi

# eza (ls replacement - maintained fork)
if command -v eza &>/dev/null; then
    version=$(eza --version 2>&1 | head -1)
    echo -e "  ${CHECK} eza (replaces ls): $version"
elif command -v exa &>/dev/null; then
    version=$(exa --version 2>&1 | head -1)
    echo -e "  ${CHECK} exa (replaces ls): $version"
    echo "      Note: exa is unmaintained, consider upgrading to eza"
elif command -v colorls &>/dev/null; then
    echo -e "  ${CHECK} colorls (replaces ls)"
else
    echo -e "  ${CIRCLE} eza/exa/colorls (ls fallback active)"
    echo "      Install: cargo install eza  OR  brew install eza"
fi

# fd/fdfind (find replacement)
if command -v fd &>/dev/null; then
    version=$(fd --version 2>&1 | head -1)
    echo -e "  ${CHECK} fd (replaces find): $version"
elif command -v fdfind &>/dev/null; then
    version=$(fdfind --version 2>&1 | head -1)
    echo -e "  ${CHECK} fdfind (replaces find): $version"
    echo "      Note: On Ubuntu, 'fd' is installed as 'fdfind'"
else
    echo -e "  ${CIRCLE} fd (find fallback active)"
    echo "      Install: sudo apt install fd-find  OR  brew install fd"
fi

# ripgrep (grep replacement)
if command -v rg &>/dev/null; then
    version=$(rg --version 2>&1 | head -1)
    echo -e "  ${CHECK} rg/ripgrep (replaces grep): $version"
else
    echo -e "  ${CIRCLE} ripgrep (grep fallback active)"
    echo "      Install: sudo apt install ripgrep  OR  brew install ripgrep"
fi

# htop (top replacement)
if command -v htop &>/dev/null; then
    version=$(htop --version 2>&1 | head -1)
    echo -e "  ${CHECK} htop (replaces top): $version"
else
    echo -e "  ${CIRCLE} htop (top fallback active)"
    echo "      Install: sudo apt install htop  OR  brew install htop"
fi

# delta (git diff replacement)
if command -v delta &>/dev/null; then
    version=$(delta --version 2>&1 | head -1)
    echo -e "  ${CHECK} delta (git diff enhancer): $version"
else
    echo -e "  ${CIRCLE} delta (standard git diff active)"
    echo "      Install: https://github.com/dandavison/delta"
fi

echo

#==============================================================================
# Version Managers
#==============================================================================

echo "Version Managers:"

# nvm (Node Version Manager)
if [[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
    # Source nvm to get version
    source "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    version=$(nvm --version 2>&1)
    echo -e "  ${CHECK} nvm: v$version"
    current_node=$(nvm current 2>&1)
    if [[ "$current_node" != "none" ]]; then
        echo "      Current Node.js: $current_node"
    fi
else
    echo -e "  ${CIRCLE} nvm: not installed (optional)"
    echo "      Install: https://github.com/nvm-sh/nvm#installing-and-updating"
fi

# pyenv (Python Version Manager)
if command -v pyenv &>/dev/null; then
    version=$(pyenv --version 2>&1 | awk '{print $2}')
    echo -e "  ${CHECK} pyenv: $version"
    current_python=$(pyenv version 2>&1 | awk '{print $1}')
    echo "      Current Python: $current_python"
else
    echo -e "  ${CIRCLE} pyenv: not installed (optional)"
    echo "      Install: https://github.com/pyenv/pyenv#installation"
fi

echo

#==============================================================================
# Other Optional Tools
#==============================================================================

echo "Other Optional Tools:"

tools=("direnv" "autojump" "poetry" "xclip" "docker" "docker-compose")
descriptions=(
    "direnv: per-directory environment manager"
    "autojump: smart directory navigation"
    "poetry: Python dependency management"
    "xclip: clipboard support (Linux)"
    "docker: container platform"
    "docker-compose: multi-container orchestration"
)

for i in "${!tools[@]}"; do
    tool="${tools[$i]}"
    desc="${descriptions[$i]}"

    if command -v "$tool" &>/dev/null; then
        # Get version for some tools
        case "$tool" in
            docker)
                version=$(docker --version 2>&1 | awk '{print $3}' | tr -d ',')
                echo -e "  ${CHECK} $tool: $version"
                ;;
            docker-compose)
                version=$(docker-compose --version 2>&1 | awk '{print $3}' | tr -d ',')
                echo -e "  ${CHECK} $tool: $version"
                ;;
            poetry)
                version=$(poetry --version 2>&1 | awk '{print $3}')
                echo -e "  ${CHECK} $tool: $version"
                ;;
            *)
                echo -e "  ${CHECK} $tool"
                ;;
        esac
    else
        echo -e "  ${CIRCLE} $tool"
    fi
done

echo

#==============================================================================
# Oh-My-Zsh Plugins
#==============================================================================

echo "Oh-My-Zsh Custom Plugins:"

ZSH_CUSTOM="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"

plugins=(
    "zsh-autosuggestions"
    "zsh-syntax-highlighting"
    "zsh-fzf-history-search"
)

for plugin in "${plugins[@]}"; do
    if [ -d "${ZSH_CUSTOM}/plugins/$plugin" ]; then
        echo -e "  ${CHECK} $plugin"
    else
        echo -e "  ${CROSS} $plugin: not installed"
        case "$plugin" in
            zsh-autosuggestions)
                echo "      Install: git clone https://github.com/zsh-users/zsh-autosuggestions \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
                ;;
            zsh-syntax-highlighting)
                echo "      Install: git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
                ;;
            zsh-fzf-history-search)
                echo "      Install: git clone https://github.com/joshskidmore/zsh-fzf-history-search \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-fzf-history-search"
                ;;
        esac
    fi
done

echo

#==============================================================================
# Powerlevel10k Theme
#==============================================================================

echo "Oh-My-Zsh Theme:"

P10K_DIR="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}/themes/powerlevel10k"

if [ -d "$P10K_DIR" ]; then
    echo -e "  ${CHECK} powerlevel10k theme installed"
    if [ -f "${HOME}/.p10k.zsh" ]; then
        echo "      Configuration: ~/.p10k.zsh exists"
    else
        echo "      Note: Run 'p10k configure' to set up"
    fi
else
    echo -e "  ${CROSS} powerlevel10k: not installed"
    echo "      This is configured as the theme in zshrc"
    echo "      Install: git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/themes/powerlevel10k"
fi

echo

#==============================================================================
# Summary
#==============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Legend:"
echo -e "  ${CHECK} installed"
echo -e "  ${CROSS} missing (required or configured)"
echo -e "  ${CIRCLE} not installed (optional, fallback active)"
echo
echo "For more information, see:"
echo "  - ~/.dotfiles/CLAUDE.md (tool documentation)"
echo "  - ~/.dotfiles/README.md (installation guide)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
