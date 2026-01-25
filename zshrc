# Zvi's zsh configuration
# Modular structure for maintainability and portability

#==============================================================================
# Powerlevel10k instant prompt
#==============================================================================

# Enable Powerlevel10k instant prompt (MUST be near top of zshrc for performance)
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Uncomment for gitstatus debugging if needed
# export GITSTATUS_LOG_LEVEL=DEBUG

#==============================================================================
# oh-my-zsh setup
#==============================================================================

export ZSH="${HOME}/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# Auto-update without prompting
zstyle ':omz:update' mode auto

# Suppress direnv informational messages to avoid Powerlevel10k instant prompt warnings
# This keeps error messages but silences "loading" and "export" notifications
export DIRENV_LOG_FORMAT=""

# Plugins to load (optimized for performance)
# Note: zsh-syntax-highlighting must be last in the list
# Removed slow plugins: poetry (300ms), command-not-found (100ms)
plugins=(
    colored-man-pages # Colorized man pages for better readability
    extract          # Universal archive extractor (extract <file>)
    fzf              # Fuzzy finder integration (requires: fzf)
    git              # Git aliases and functions
    safe-paste       # Prevent accidental execution of pasted commands
    sudo             # Prefix command with sudo via ESC ESC
    zsh-autosuggestions      # Fish-like autosuggestions (requires manual install)
    zsh-fzf-history-search   # FZF history search (requires manual install)
    zsh-syntax-highlighting  # Fish-like syntax highlighting (requires manual install, must be last)
)

# Conditionally load slow plugins only if their tools are available
# This prevents slowdown when tools aren't installed (saves ~400ms total)
[[ -n "$(command -v direnv)" ]] && plugins+=(direnv)
[[ -n "$(command -v gh)" ]] && plugins+=(gh)

# Smart poetry loading: only load if poetry is available AND we're likely in a Python project
# This saves ~300ms when not in Python projects
if command -v poetry >/dev/null 2>&1; then
  # Check if we're in a poetry project or if poetry is currently active
  if [[ -f "pyproject.toml" ]] || [[ -f "poetry.lock" ]] || [[ -n "$POETRY_ACTIVE" ]] || [[ -n "$VIRTUAL_ENV" ]]; then
    plugins+=(poetry)
  else
    # Lazy load poetry completions when first used (saves startup time)
    poetry() {
      # Remove this function and load the real plugin
      unfunction poetry
      plugins+=(poetry)
      # Source the poetry plugin directly instead of calling compinit
      if [ -f "${ZSH}/plugins/poetry/poetry.plugin.zsh" ]; then
        source "${ZSH}/plugins/poetry/poetry.plugin.zsh"
      fi
      # Call the real poetry command
      command poetry "$@"
    }
  fi
fi

# Ubuntu/Debian specific plugins
[[ -n "$(command -v apt-get)" ]] && plugins+=(command-not-found)

# Company-specific plugin (only if available)
[[ -f "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/quantivly/quantivly.plugin.zsh" ]] && plugins+=(quantivly)

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

# Cache completion (create directory if it doesn't exist)
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.zsh/cache
[[ ! -d ~/.zsh/cache ]] && mkdir -p ~/.zsh/cache

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

# Ctrl+Backspace to delete word backward
bindkey '^H' backward-kill-word     # Ctrl+Backspace
bindkey '^?' backward-delete-char   # Backspace

# Additional useful key bindings
bindkey '^U' backward-kill-line     # Ctrl+U - delete from cursor to beginning of line
bindkey '^K' kill-line              # Ctrl+K - delete from cursor to end of line
bindkey '^W' backward-kill-word     # Ctrl+W - delete word backward (alternative)

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

# Utility functions (modular: core, development, system)
for func_module in \
  ~/.dotfiles/zsh/functions/core.sh \
  ~/.dotfiles/zsh/functions/development.sh \
  ~/.dotfiles/zsh/functions/system.sh; do
  [ -f "$func_module" ] && source "$func_module"
done
unset func_module

# Common aliases
[ -f ~/.dotfiles/zsh/zshrc.aliases ] && source ~/.dotfiles/zsh/zshrc.aliases

# Optional tool configurations (colorls, pyenv, nvm, etc.)
[ -f ~/.dotfiles/zsh/zshrc.conditionals ] && source ~/.dotfiles/zsh/zshrc.conditionals

# GPG cache reminder (one-time per session)
[ -f ~/.dotfiles/zsh/zshrc.gpg-reminder ] && source ~/.dotfiles/zsh/zshrc.gpg-reminder

# Company/work-specific configuration
[ -f ~/.dotfiles/zsh/zshrc.company ] && source ~/.dotfiles/zsh/zshrc.company

# Help system with semantic categorization
[ -f ~/.dotfiles/zsh/zshrc.help ] && source ~/.dotfiles/zsh/zshrc.help

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

#==============================================================================
# Final overrides (after all other configs load)
#==============================================================================

# Note: Smart width-aware gd() function is defined in zshrc.functions.git
# It will automatically override forgit's gd alias during module loading

# Ensure quanticli aliases are set correctly (in case they were overridden)
if [ -d "${HOME}/.oh-my-zsh/custom/plugins/quantivly" ]; then
  unalias q 2>/dev/null
  alias q='quanticli'
fi

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
