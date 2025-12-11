# Zvi's zsh configuration
# Modular structure for maintainability and portability

#==============================================================================
# Powerlevel10k instant prompt
#==============================================================================

# Enable Powerlevel10k instant prompt (MUST be near top of zshrc for performance)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

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
    colored-man-pages # Colorized man pages for better readability
    command-not-found # Suggest package installation for missing commands (Ubuntu/Debian)
    copyfile         # Copy file contents to clipboard
    copybuffer       # Copy command line to clipboard
    direnv           # Per-directory environment variables (requires: direnv)
    extract          # Universal archive extractor (extract <file>)
    fzf              # Fuzzy finder integration (requires: fzf)
    gh               # GitHub CLI completions
    git              # Git aliases and functions
    github           # GitHub utilities
    poetry           # Python poetry completions (requires: poetry)
    quantivly        # Company-specific plugin (optional)
    safe-paste       # Prevent accidental execution of pasted commands
    sudo             # Prefix command with sudo via ESC ESC
    web-search       # Search web from terminal
    zsh-autosuggestions      # Fish-like autosuggestions (requires manual install)
    zsh-fzf-history-search   # FZF history search (requires manual install)
    zsh-syntax-highlighting  # Fish-like syntax highlighting (requires manual install, must be last)
)

source "${ZSH}/oh-my-zsh.sh"

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

#==============================================================================
# ZSH options
#==============================================================================

# Navigation
setopt AUTO_CD              # cd by typing directory name if it's not a command
setopt AUTO_PUSHD           # Make cd push old directory onto stack
setopt PUSHD_IGNORE_DUPS    # Don't push duplicates onto the stack
setopt PUSHD_SILENT         # Don't print directory stack after pushd/popd

# Completion
setopt ALWAYS_TO_END        # Move cursor to end of word after completion
setopt AUTO_MENU            # Show completion menu on tab press
setopt COMPLETE_IN_WORD     # Allow completion from within a word/phrase
setopt LIST_PACKED          # Make completion lists more compact

# Globbing
setopt EXTENDED_GLOB        # Use extended globbing syntax (#, ~, ^)
setopt GLOB_DOTS            # Include dotfiles in glob patterns

# Input/Output
setopt INTERACTIVE_COMMENTS # Allow comments in interactive shell
setopt NO_FLOW_CONTROL      # Disable flow control (Ctrl+S/Ctrl+Q)

# Correction
setopt CORRECT              # Command spelling correction
setopt CORRECT_ALL          # Argument spelling correction (can be annoying, disable if needed)

#==============================================================================
# Completion configuration
#==============================================================================

# Case-insensitive completion
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'

# Colored completion (use same colors as ls)
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# Menu selection with arrow keys
zstyle ':completion:*' menu select

# Better SSH/SCP/RSYNC completion
zstyle ':completion:*:(ssh|scp|rsync):*' hosts off

# Cache completion
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.zsh/cache

#==============================================================================
# Key bindings
#==============================================================================

# Ctrl+Arrow keys for word movement
bindkey '^[[1;5C' forward-word      # Ctrl+Right
bindkey '^[[1;5D' backward-word     # Ctrl+Left

# Alt+Arrow keys for word movement (alternative)
bindkey '^[[1;3C' forward-word      # Alt+Right
bindkey '^[[1;3D' backward-word     # Alt+Left

# Home/End keys
bindkey '^[[H' beginning-of-line    # Home
bindkey '^[[F' end-of-line          # End

# Delete key
bindkey '^[[3~' delete-char         # Delete

#==============================================================================
# Load modular configuration files
#==============================================================================
# Loading order is important:
# 1. history - History settings (must load early)
# 2. functions - Provides utility functions (pathadd, mkcd, etc.)
# 3. aliases - Common portable aliases
# 4. conditionals - Tool-specific config (overrides aliases if tool installed)
# 5. company - Work-specific settings
# 6. ~/.zshrc.local - Machine-specific secrets (NOT in git)
#
# Note: Conditionals load AFTER aliases, so tool-specific aliases
# override the basic ones. Example: 'ls' becomes 'eza' if installed.
#==============================================================================

# History settings
[ -f ~/.dotfiles/zsh/zshrc.history ] && source ~/.dotfiles/zsh/zshrc.history

# Utility functions (pathadd, mkcd, backup, etc.)
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
