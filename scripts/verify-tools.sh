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

# NO `set -e` HERE — deliberately. This script's entire purpose is to report which
# tools are missing, and check_tool returns 1 for each one it doesn't find. Under
# errexit, a `check_tool x || check_tool x_fallback` pair where BOTH are absent kills
# the script outright. It had been dying at the first fully-missing tool (`bat`) after
# 12 lines and exit 1, silently reporting nothing about the other ~20 tools — which is
# why the missing `delta` that broke `git diff` was never surfaced despite this script
# existing to surface exactly that. A verifier must outlive the failures it reports.

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
echo -e "${BLUE}=== Modern CLI Tools (From mise) ===${NC}"

# Parse tools from .mise.toml [tools] section
DOTFILES_ROOT="${HOME}/.dotfiles"
if [[ -f "${DOTFILES_ROOT}/.mise.toml" ]]; then
    # Extract tool names from .mise.toml
    while IFS= read -r line; do
        tool_name=$(echo "$line" | awk -F= '{print $1}' | xargs)
        [[ -z "$tool_name" || "$tool_name" =~ ^# ]] && continue

        case "$tool_name" in
            bat) check_tool bat "--version" || check_tool batcat "--version" ;;
            fd) check_tool fd "--version" || check_tool fdfind "--version" ;;
            *) check_tool "$tool_name" "--version" ;;
        esac
    done < <(sed -n '/^\[tools\]/,/^\[/p' "${DOTFILES_ROOT}/.mise.toml" | grep -E '^\w+\s*=\s*"')
else
    echo -e "${YELLOW}⚠${NC} .mise.toml not found - using fallback"
    check_tool bat "--version" || check_tool batcat "--version"
    check_tool eza "--version"
    check_tool fd "--version" || check_tool fdfind "--version"
fi

echo ""
echo -e "${BLUE}=== Version Manager ===${NC}"
check_tool mise "--version"

echo ""
echo -e "${BLUE}=== Developer Tools ===${NC}"
check_tool lazygit "--version"
check_tool yazi "--version"
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
echo -e "${BLUE}=== mise config drift ===${NC}"
# Why this check exists: ~/.config/mise/config.toml is supposed to be a SYMLINK to
# ~/.dotfiles/.mise.toml, so the repo is the single source of truth. `./install`
# only creates that symlink when the target is absent or byte-identical; if a real
# file is already there and differs, it prints one warning and keeps the local copy
# — forever. That state is stable, self-perpetuating, and invisible.
#
# It happened, and it was not cosmetic: the live config declared 10 tools while the
# repo declared 23, so ~11 installed tools were simply never put on PATH. `delta` was
# one of them, and gitconfig routes pager.diff/log/show/reflog through it — so
# `git diff` failed outright in a terminal with "unable to execute pager 'delta'".
# Nothing anywhere reported it.
MISE_ACTIVE="$HOME/.config/mise/config.toml"
MISE_REPO="$HOME/.dotfiles/.mise.toml"
if [[ ! -e "$MISE_ACTIVE" ]]; then
    echo -e "${YELLOW}✗${NC} no active mise config at $MISE_ACTIVE"
elif [[ -L "$MISE_ACTIVE" ]] && [[ "$(readlink -f "$MISE_ACTIVE")" == "$(readlink -f "$MISE_REPO")" ]]; then
    echo -e "${GREEN}✓${NC} mise config symlinked to dotfiles (single source of truth)"
else
    echo -e "${YELLOW}✗${NC} mise config is NOT symlinked to $MISE_REPO"
    echo "    Declared tools will silently never reach PATH. Diff them, then:"
    echo "      ln -sfn $MISE_REPO $MISE_ACTIVE && mise install"
fi

# Every tool the repo declares must actually contribute a binary directory.
#
# `mise bin-paths` is the right probe, and the only one that isn't a heuristic: it
# lists the bin dir each active tool contributes, which is exactly what comes back
# EMPTY when a version pin no longer exists in its backend. glow 1.5.1 and fastfetch
# 2.8.10 both failed this way — mise created the install directory, reported "all
# tools are installed", and produced no binary at all.
#
# Rejected alternatives, each of which produced false positives here:
#   - `mise which <tool>` takes a BINARY name; several tools ship binaries named
#     differently (awscli->aws, ripgrep->rg, helix->hx, rust->rustc).
#   - `mise where <tool>` + find: the install dir may be a symlink (rust) and the
#     binary may sit at an arbitrary depth (fastfetch: <pkg>/usr/bin/fastfetch).
if command -v mise &>/dev/null && [[ -f "$MISE_REPO" ]]; then
    binpaths=$(mise bin-paths 2>/dev/null)
    no_binary=""
    while IFS= read -r tool; do
        grep -q "/installs/${tool}/" <<<"$binpaths" || no_binary+=" $tool"
    done < <(sed -n '/^\[tools\]/,/^\[/p' "$MISE_REPO" | grep -oE '^[a-z0-9_-]+' | sort -u)

    if [[ -z "$no_binary" ]]; then
        echo -e "${GREEN}✓${NC} every tool declared in .mise.toml contributes a binary"
    else
        echo -e "${YELLOW}✗${NC} declared but contributing NO binary:$no_binary"
        echo "    Usually a version pin that no longer exists in its backend — mise"
        echo "    still reports 'installed'. Check 'mise ls-remote <tool>' and re-pin,"
        echo "    or remove the tool from .mise.toml. A declaration that does not match"
        echo "    reality is what caused the drift above."
    fi
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
