# Zvi's zsh configuration
# Modular structure for maintainability and portability

#==============================================================================
# oh-my-zsh setup
#==============================================================================

export ZSH="${HOME}/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# Auto-update without prompting
zstyle ':omz:update' mode auto

# Plugins to load
# Note: zsh-syntax-highlighting must be last in the list
plugins=(
    autojump         # Fast directory navigation (requires: autojump)
    copyfile         # Copy file contents to clipboard
    copybuffer       # Copy command line to clipboard
    direnv           # Per-directory environment variables (requires: direnv)
    gh               # GitHub CLI completions
    git              # Git aliases and functions
    github           # GitHub utilities
    poetry           # Python poetry completions (requires: poetry)
    quantivly        # Company-specific plugin (optional)
    sudo             # Prefix command with sudo via ESC ESC
    web-search       # Search web from terminal
    zsh-autosuggestions      # Fish-like autosuggestions (requires manual install)
    zsh-fzf-history-search   # FZF history search (requires manual install)
    zsh-syntax-highlighting  # Fish-like syntax highlighting (requires manual install, must be last)
)

source "${ZSH}/oh-my-zsh.sh"

#==============================================================================
# Powerlevel10k instant prompt
#==============================================================================

# Enable Powerlevel10k instant prompt (should stay close to top of zshrc)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

#==============================================================================
# Load modular configuration files
#==============================================================================

# History settings
[ -f ~/.dotfiles/zsh/zshrc.history ] && source ~/.dotfiles/zsh/zshrc.history

# Utility functions (pathadd, clear-screen-and-scrollback, etc.)
[ -f ~/.dotfiles/zsh/zshrc.functions ] && source ~/.dotfiles/zsh/zshrc.functions

# Common aliases
[ -f ~/.dotfiles/zsh/zshrc.aliases ] && source ~/.dotfiles/zsh/zshrc.aliases

# Optional tool configurations (colorls, pyenv, nvm, etc.)
[ -f ~/.dotfiles/zsh/zshrc.conditionals ] && source ~/.dotfiles/zsh/zshrc.conditionals

# Company/work-specific configuration
[ -f ~/.dotfiles/zsh/zshrc.company ] && source ~/.dotfiles/zsh/zshrc.company

#==============================================================================
# Machine-specific configuration
#==============================================================================

# Load machine-specific settings and secrets
# This file is NOT tracked in git
# Examples of what to put here:
#   - API keys and tokens
#   - Machine-specific PATH additions
#   - SSH key configuration
#   - Custom aliases for this machine only
#   - Override Q_MODE or other work variables
if [ -f ~/.zshrc.local ]; then
    source ~/.zshrc.local
fi

#==============================================================================
# PATH additions
#==============================================================================

# Add common directories to PATH (if they exist)
# Machine-specific paths should go in ~/.zshrc.local
pathadd "${HOME}/.local/bin"
pathadd "${HOME}/.docker/cli-plugins"

# Note: Add machine-specific paths in ~/.zshrc.local, such as:
#   pathadd "${HOME}/dcm4che-5.29.2/bin/"
#   pathadd "${HOME}/go/bin"
