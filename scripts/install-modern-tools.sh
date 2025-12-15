#!/usr/bin/env bash

# Modern CLI Tools Installation Script for Dotfiles Enhancement
# This script installs all the tools configured in the dotfiles

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install via package manager
install_apt() {
    local package="$1"
    if command_exists apt-get; then
        print_status "Installing $package via apt..."
        if sudo apt-get update -qq && sudo apt-get install -y "$package" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    fi
    return 1
}

# Function to install via cargo
install_cargo() {
    local package="$1"
    if command_exists cargo; then
        print_status "Installing $package via cargo..."
        cargo install "$package"
        return 0
    else
        print_warning "Cargo not found. Install Rust first: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        return 1
    fi
}

# Function to install via pip
install_pip() {
    local package="$1"
    if command_exists pip3 || command_exists pip; then
        print_status "Installing $package via pip..."
        if command_exists pip3; then
            pip3 install --user "$package"
        else
            pip install --user "$package"
        fi
        return 0
    else
        print_warning "pip not found. Install Python3 and pip first"
        return 1
    fi
}

# Main installation function
install_tool() {
    local tool_name="$1"
    local alt_name="${2:-}"
    local description="$3"
    
    # Skip if already installed
    if command_exists "$tool_name" || [[ -n "$alt_name" && $(command_exists "$alt_name") ]]; then
        print_success "$tool_name already installed"
        return 0
    fi
    
    print_status "Installing $tool_name - $description"
    
    case "$tool_name" in
        "zoxide")
            curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash || \
            install_cargo zoxide || \
            install_apt zoxide
            ;;
        "btop")
            install_apt btop || {
                print_warning "btop not available via apt, installing from GitHub..."
                # Fall back to manual installation
                local version="1.2.13"
                wget -O btop.tbz "https://github.com/aristocratos/btop/releases/download/v${version}/btop-x86_64-linux-musl.tbz"
                tar -xf btop.tbz && sudo ./btop/install.sh && rm -rf btop.tbz btop/
            }
            ;;
        "procs")
            # procs is not available in Ubuntu 22.04 repos, needs cargo or GitHub release
            if ! install_cargo procs; then
                print_status "Installing procs from GitHub releases..."
                PROCS_VERSION=$(curl -s "https://api.github.com/repos/dalance/procs/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
                curl -Lo procs.zip "https://github.com/dalance/procs/releases/download/v${PROCS_VERSION}/procs-v${PROCS_VERSION}-x86_64-linux.zip"
                unzip -q procs.zip && sudo install procs /usr/local/bin && rm procs procs.zip
            fi
            ;;
        "duf")
            install_apt duf || {
                # Fall back to GitHub release
                local version="0.8.1"
                wget -O duf.deb "https://github.com/muesli/duf/releases/download/v${version}/duf_${version}_linux_amd64.deb"
                sudo dpkg -i duf.deb && rm duf.deb
            }
            ;;
        "dust")
            # du-dust is not available in Ubuntu 22.04 repos, needs cargo or GitHub release
            if ! install_cargo du-dust; then
                print_status "Installing dust from GitHub releases..."
                DUST_VERSION=$(curl -s "https://api.github.com/repos/bootandy/dust/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
                curl -Lo dust.tar.gz "https://github.com/bootandy/dust/releases/download/v${DUST_VERSION}/dust-v${DUST_VERSION}-x86_64-unknown-linux-musl.tar.gz"
                tar xf dust.tar.gz --strip-components=1 dust-v${DUST_VERSION}-x86_64-unknown-linux-musl/dust
                sudo install dust /usr/local/bin && rm dust dust.tar.gz
            fi
            ;;
        "lazygit")
            # Check if available via apt (newer Ubuntu versions)
            install_apt lazygit || {
                print_status "Installing lazygit from GitHub releases..."
                LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
                curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
                tar xf lazygit.tar.gz lazygit
                sudo install lazygit /usr/local/bin && rm lazygit lazygit.tar.gz
            }
            ;;
        "dive")
            # Install from GitHub releases
            print_status "Installing dive from GitHub releases..."
            DIVE_VERSION=$(curl -s "https://api.github.com/repos/wagoodman/dive/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
            curl -Lo dive.deb "https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_linux_amd64.deb"
            sudo dpkg -i dive.deb && rm dive.deb
            ;;
        "ctop")
            print_status "Installing ctop from GitHub releases..."
            sudo curl -Lo /usr/local/bin/ctop https://github.com/bcicen/ctop/releases/download/v0.7.7/ctop-0.7.7-linux-amd64
            sudo chmod +x /usr/local/bin/ctop
            ;;
        "just")
            install_cargo just || {
                print_status "Installing just from GitHub releases..."
                JUST_VERSION=$(curl -s "https://api.github.com/repos/casey/just/releases/latest" | grep -Po '"tag_name": "\K[^"]*')
                curl -Lo just.tar.gz "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz"
                tar xf just.tar.gz just
                sudo install just /usr/local/bin && rm just just.tar.gz
            }
            ;;
        "hyperfine")
            install_cargo hyperfine || install_apt hyperfine
            ;;
        "glow")
            install_apt glow || {
                print_status "Installing glow from GitHub releases..."
                # Get the download URL for amd64 .deb from latest release
                GLOW_URL=$(curl -s https://api.github.com/repos/charmbracelet/glow/releases/latest | grep "browser_download_url.*amd64\.deb" | cut -d '"' -f 4)
                if [ -z "$GLOW_URL" ]; then
                    print_error "Failed to get glow download URL"
                    return 1
                fi
                curl -sL "$GLOW_URL" -o glow.deb
                if [ -f glow.deb ] && [ -s glow.deb ]; then
                    sudo dpkg -i glow.deb && rm glow.deb
                else
                    print_error "Failed to download glow.deb"
                    rm -f glow.deb
                    return 1
                fi
            }
            ;;
        "difft"|"difftastic")
            install_cargo difftastic || {
                print_status "Installing difftastic from GitHub releases..."
                DIFFT_VERSION=$(curl -s "https://api.github.com/repos/Wilfred/difftastic/releases/latest" | grep -Po '"tag_name": "\K[^"]*')
                curl -Lo difftastic.tar.gz "https://github.com/Wilfred/difftastic/releases/download/${DIFFT_VERSION}/difft-x86_64-unknown-linux-gnu.tar.gz"
                tar xf difftastic.tar.gz difft
                sudo install difft /usr/local/bin && rm difft difftastic.tar.gz
            }
            ;;
        "thefuck")
            install_pip thefuck
            ;;
        "tldr")
            install_pip tldr || install_apt tldr
            ;;
        "neofetch")
            install_apt neofetch
            ;;
        "fastfetch")
            install_apt fastfetch || {
                print_status "Installing fastfetch from GitHub releases..."
                FASTFETCH_VERSION=$(curl -s "https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest" | grep -Po '"tag_name": "\K[^"]*')
                curl -Lo fastfetch.deb "https://github.com/fastfetch-cli/fastfetch/releases/download/${FASTFETCH_VERSION}/fastfetch-linux-amd64.deb"
                sudo dpkg -i fastfetch.deb && rm fastfetch.deb
            }
            ;;
        "gitleaks")
            print_status "Installing gitleaks from GitHub releases..."
            GITLEAKS_VERSION=$(curl -s "https://api.github.com/repos/gitleaks/gitleaks/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
            curl -Lo gitleaks.tar.gz "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
            tar xf gitleaks.tar.gz gitleaks
            sudo install gitleaks /usr/local/bin && rm gitleaks gitleaks.tar.gz
            ;;
        "pre-commit")
            install_pip pre-commit
            ;;
        "sops")
            print_status "Installing sops from GitHub releases..."
            SOPS_VERSION=$(curl -s "https://api.github.com/repos/getsops/sops/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
            curl -Lo sops "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64"
            sudo install sops /usr/local/bin && rm sops
            ;;
        "lazydocker")
            print_status "Installing lazydocker from GitHub releases..."
            curl https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash
            ;;
        "cheat")
            print_status "Installing cheat from GitHub releases..."
            CHEAT_VERSION=$(curl -s "https://api.github.com/repos/cheat/cheat/releases/latest" | grep -Po '"tag_name": "\K[^"]*')
            curl -Lo cheat.gz "https://github.com/cheat/cheat/releases/download/${CHEAT_VERSION}/cheat-linux-amd64.gz"
            gunzip cheat.gz && chmod +x cheat
            sudo mv cheat /usr/local/bin/
            ;;
        *)
            print_warning "Unknown tool: $tool_name"
            return 1
            ;;
    esac
    
    # Verify installation
    if command_exists "$tool_name" || [[ -n "$alt_name" && $(command_exists "$alt_name") ]]; then
        print_success "$tool_name installed successfully"
    else
        print_error "Failed to install $tool_name"
        return 1
    fi
}

# Function to install forgit
install_forgit() {
    if [[ ! -d "${HOME}/.forgit" ]]; then
        print_status "Installing forgit..."
        git clone https://github.com/wfxr/forgit.git "${HOME}/.forgit"
        print_success "forgit installed to ~/.forgit"
    else
        print_success "forgit already installed"
    fi
}

# Main installation menu
main() {
    echo "=========================================="
    echo "  Modern CLI Tools Installation Script"
    echo "=========================================="
    echo
    echo "This script will install modern CLI tools to enhance your dotfiles workflow."
    echo "Tools will be installed via apt, cargo, pip, or GitHub releases as appropriate."
    echo
    
    # Check prerequisites
    print_status "Checking prerequisites..."
    if ! command_exists curl; then
        print_error "curl is required but not installed. Please install curl first."
        exit 1
    fi
    
    if ! command_exists git; then
        print_error "git is required but not installed. Please install git first."
        exit 1
    fi
    
    print_success "Prerequisites check passed"
    echo
    
    # Installation options
    echo "Installation Options:"
    echo "1. Install essential tools (recommended for all users)"
    echo "2. Install development tools (for developers)"
    echo "3. Install all tools (complete setup)"
    echo "4. Install specific tool"
    echo "5. Show tool status"
    echo
    read -p "Choose option [1-5]: " choice
    
    case $choice in
        1)
            echo
            print_status "Installing essential tools..."
            install_tool "zoxide" "" "Smart cd replacement"
            install_tool "btop" "htop" "Modern resource monitor"
            install_tool "duf" "" "Better df visualization"
            install_tool "thefuck" "" "Command correction"
            install_tool "tldr" "" "Simplified man pages"
            install_tool "fastfetch" "neofetch" "System info display"
            ;;
        2)
            echo
            print_status "Installing development tools..."
            install_tool "lazygit" "" "Git TUI"
            install_tool "dive" "" "Docker image analyzer"
            install_tool "just" "" "Command runner"
            install_tool "hyperfine" "" "Command benchmarking"
            install_tool "glow" "" "Markdown renderer"
            install_tool "difft" "difftastic" "Structural diff tool"
            install_tool "gitleaks" "" "Git secrets scanner"
            install_tool "pre-commit" "" "Code quality automation"
            install_forgit
            ;;
        3)
            echo
            print_status "Installing all tools..."
            # Essential tools
            install_tool "zoxide" "" "Smart cd replacement"
            install_tool "btop" "htop" "Modern resource monitor"
            install_tool "procs" "" "Modern ps replacement"
            install_tool "duf" "" "Better df visualization"
            install_tool "dust" "" "Intuitive du replacement"
            install_tool "ctop" "" "Container monitoring"
            
            # Developer tools
            install_tool "lazygit" "" "Git TUI"
            install_tool "dive" "" "Docker image analyzer"
            install_tool "just" "" "Command runner"
            install_tool "hyperfine" "" "Command benchmarking"
            install_tool "glow" "" "Markdown renderer"
            install_tool "difft" "difftastic" "Structural diff tool"
            install_tool "lazydocker" "" "Docker TUI"
            
            # Productivity tools
            install_tool "thefuck" "" "Command correction"
            install_tool "tldr" "" "Simplified man pages"
            install_tool "cheat" "" "Interactive cheatsheets"
            install_tool "fastfetch" "neofetch" "System info display"
            
            # Security tools
            install_tool "gitleaks" "" "Git secrets scanner"
            install_tool "pre-commit" "" "Code quality automation"
            install_tool "sops" "" "Encrypted secrets management"
            
            # Git enhancement
            install_forgit
            ;;
        4)
            echo
            echo "Available tools:"
            echo "  zoxide, btop, procs, duf, dust, ctop"
            echo "  lazygit, dive, just, hyperfine, glow, difft, lazydocker"
            echo "  thefuck, tldr, cheat, neofetch, fastfetch"
            echo "  gitleaks, pre-commit, sops, forgit"
            echo
            read -p "Enter tool name: " tool_name
            install_tool "$tool_name" "" "Selected tool"
            ;;
        5)
            echo
            # Load the tool_status function if available
            if declare -f tool_status >/dev/null; then
                tool_status
            else
                print_status "Checking basic tool availability..."
                for tool in zoxide btop procs duf dust lazygit dive just hyperfine glow difft thefuck tldr cheat neofetch fastfetch gitleaks pre-commit sops; do
                    if command_exists "$tool"; then
                        print_success "$tool is installed"
                    else
                        echo "  ✗ $tool is not installed"
                    fi
                done
            fi
            ;;
        *)
            print_error "Invalid option"
            exit 1
            ;;
    esac
    
    echo
    print_success "Installation complete!"
    print_status "Restart your shell or run 'source ~/.zshrc' to use the new tools"
    
    # Optional: Run tool status check
    echo
    read -p "Run tool status check? [y/N]: " check_status
    if [[ "$check_status" =~ ^[Yy]$ ]]; then
        echo
        # Try to load and run tool_status if available
        if [[ -f ~/.dotfiles/zsh/zshrc.functions ]]; then
            source ~/.dotfiles/zsh/zshrc.functions
            tool_status
        fi
    fi
}

# Run main function
main "$@"