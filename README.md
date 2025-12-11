# Zvi's Dotfiles

Personal configuration files for zsh, git, and various development tools, managed with [dotbot](https://github.com/anishathalye/dotbot).

## Features

- **Modular zsh configuration** - Clean, organized structure that's easy to maintain
- **Portable across machines** - Machine-specific settings separated from shared config
- **Security-focused** - Secrets never committed to git
- **Well-documented** - Comments and examples throughout
- **Easy installation** - One command setup on new machines
- **Modern CLI tools** - Integration with bat, eza, fd, ripgrep, delta, and more
- **Enhanced productivity** - 40+ useful aliases and 15+ utility functions
- **FZF integration** - Fuzzy finding for files, directories, git branches, and commits
- **Smart completion** - Case-insensitive, colored, with menu selection
- **GitHub CLI power-user** - 35+ gh aliases for efficient PR and workflow management

## Structure

```
.dotfiles/
├── zsh/
│   ├── zshrc.history        # History configuration
│   ├── zshrc.functions      # Utility functions (pathadd, etc.)
│   ├── zshrc.aliases        # Common portable aliases
│   ├── zshrc.conditionals   # Optional tool configs (pyenv, nvm, colorls, etc.)
│   ├── zshrc.company        # Work-specific configuration
│   └── zshrc.local.example  # Template for machine-specific settings
├── gh/
│   └── config.yml           # GitHub CLI configuration with custom aliases
├── config/
│   └── git/
│       └── ignore           # Global git ignore patterns
├── gitconfig                # Git configuration
├── zshrc                    # Main zsh config (sources modular files)
├── p10k.zsh                 # Powerlevel10k theme configuration
├── install.conf.yaml        # Dotbot installation configuration
├── ENHANCEMENTS.md          # Detailed list of all enhancements and improvements
└── README.md                # This file
```

## Installation

### First-Time Setup (New Machine)

1. **Install prerequisites:**

   ```bash
   # macOS
   brew install zsh git

   # Ubuntu/Debian
   sudo apt update && sudo apt install zsh git
   ```

2. **Clone this repository:**

   ```bash
   git clone --recursive https://github.com/zvi-quantivly/dotfiles.git ~/.dotfiles
   cd ~/.dotfiles
   ```

3. **Run the installer:**

   ```bash
   ./install
   ```

4. **Customize machine-specific settings:**

   The installer creates `~/.zshrc.local` from the template. Edit it to add:
   - API keys and tokens
   - Machine-specific PATH additions
   - SSH key configuration
   - Custom aliases for this machine

   ```bash
   vim ~/.zshrc.local  # or your preferred editor
   chmod 600 ~/.zshrc.local  # Ensure it's only readable by you
   ```

5. **Install optional dependencies** (see below)

### Updating Existing Installation

```bash
cd ~/.dotfiles
git pull
./install
```

## Dependencies

### Required

- **zsh** - Shell
- **git** - Version control
- **oh-my-zsh** - Zsh framework
  ```bash
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  ```
- **Powerlevel10k** - Zsh theme
  ```bash
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
  ```

### Optional (Recommended)

Install these for the best experience:

- **colorls** - Colorized ls with icons
  ```bash
  # Requires Ruby
  gem install colorls
  ```

- **autojump** - Fast directory navigation
  ```bash
  # macOS
  brew install autojump

  # Ubuntu/Debian
  sudo apt install autojump
  ```

- **direnv** - Per-directory environment variables
  ```bash
  # macOS
  brew install direnv

  # Ubuntu/Debian
  sudo apt install direnv
  ```

- **pyenv** - Python version management
  ```bash
  curl https://pyenv.run | bash
  ```

- **nvm** - Node.js version management
  ```bash
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
  ```

- **zsh-autosuggestions** - Fish-like command suggestions
  ```bash
  git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
  ```

- **zsh-syntax-highlighting** - Fish-like syntax highlighting
  ```bash
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
  ```

- **zsh-fzf-history-search** - Fuzzy history search
  ```bash
  git clone https://github.com/joshskidmore/zsh-fzf-history-search ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-fzf-history-search
  ```

### Work-Specific (Quantivly)

- **quantivly plugin** - Custom oh-my-zsh plugin for Quantivly development
  - Located at `~/.oh-my-zsh/custom/plugins/quantivly/`
  - Provides `qn`, `qg`, `qh`, `qp` commands and other utilities
  - Not required for basic dotfiles functionality

## Configuration Modules

### zshrc.history

Comprehensive history settings including:
- 50,000 commands stored
- Timestamps recorded
- Duplicate removal
- Shared history across sessions

### zshrc.functions

Utility functions:
- `pathadd` - Safely add directories to PATH
- `clear-screen-and-scrollback` - Enhanced clear (Ctrl+L)

### zshrc.aliases

Common aliases that work across all systems:
- Navigation shortcuts (`..`, `...`, `....`)
- Safe file operations (`rm -i`, `cp -i`, `mv -i`)
- Git aliases (`gst`, `gco`, `gcb`, etc.)
- Docker shortcuts (`dps`, `dlog`, `dex`, etc.)
- Python utilities (`py`, `pip`, `venv`)

### zshrc.conditionals

Conditional loading of optional tools:
- colorls (if installed)
- pyenv (if installed)
- nvm (if installed)
- Editor configuration (prefers VS Code, falls back to vim)
- SSH agent setup
- Locale settings

### zshrc.company

Work-specific configuration:
- Quantivly environment variables (`Q_MODE`, `Q_DEV_CODE_ROOT`, etc.)
- Only loads if quantivly plugin is available
- Can be overridden in `~/.zshrc.local`

### ~/.zshrc.local (Not in Git)

Machine-specific settings that should NEVER be committed:
- API keys and tokens
- SSH key configuration
- Machine-specific PATH additions
- Local overrides of work variables
- Custom aliases for this machine only

## Security Best Practices

1. **Never commit secrets** - All sensitive data goes in `~/.zshrc.local`
2. **Protect your local config** - `~/.zshrc.local` should have mode 600
3. **Review before committing** - Always check what you're committing to git
4. **Rotate exposed tokens** - If you accidentally commit secrets, rotate them immediately
5. **Use .gitignore** - The included `.gitignore` prevents common secret files from being committed

## Recent Enhancements

This configuration has been significantly enhanced with modern best practices. See **[ENHANCEMENTS.md](ENHANCEMENTS.md)** for complete details.

**Highlights:**
- ⚡ **Performance**: Optimized P10k instant prompt loading
- 🔌 **Plugins**: Added extract, fzf, colored-man-pages, safe-paste, command-not-found
- 🛠️ **Functions**: 15+ new utility functions (mkcd, backup, note, psgrep, gwt, etc.)
- 🔗 **Aliases**: 40+ new aliases for git, docker, and system operations
- 🚀 **Modern Tools**: Automatic integration with bat, eza, fd, ripgrep, delta, htop
- 🔍 **FZF**: Comprehensive fuzzy finding for files, directories, git operations
- ⌨️ **Key Bindings**: Ctrl/Alt+Arrow word movement, proper Home/End/Delete
- 🎛️ **ZSH Options**: AUTO_CD, EXTENDED_GLOB, CORRECT, case-insensitive completion
- 🐙 **GitHub CLI**: 35+ gh aliases for PR management, reviews, CI/CD, and workflows

## GitHub CLI Aliases

This dotfiles includes extensive GitHub CLI aliases (see `gh/config.yml`):

**PR Management:**
- `gh mypr` - List your open PRs
- `gh prs` - List all open, non-draft PRs
- `gh prs!` - List PRs excluding dependency updates
- `gh prmerge` - Merge PR with squash and delete branch
- `gh prchecks` - View PR checks
- `gh prready` / `gh prdraft` - Toggle PR ready state

**Review Workflow:**
- `gh review` - List PRs where you're requested to review
- `gh reviewed` - PRs you've already reviewed
- `gh approve` - Approve PR
- `gh request-changes` - Request changes on PR

**CI/CD:**
- `gh runs` - List workflow runs for current branch
- `gh runwatch` - Watch workflow run in real-time
- `gh rerun` - Rerun failed workflow

**And 25+ more!** See [gh/config.yml](gh/config.yml) or [ENHANCEMENTS.md](ENHANCEMENTS.md) for the complete list.

## Customization

### Adding New Modules

To add a new configuration module:

1. Create the file in `~/.dotfiles/zsh/zshrc.newmodule`
2. Add it to the loading section in `~/.dotfiles/zshrc`:
   ```bash
   [ -f ~/.dotfiles/zsh/zshrc.newmodule ] && source ~/.dotfiles/zsh/zshrc.newmodule
   ```
3. Commit and push changes

### Disabling Modules

Comment out the source line in `~/.dotfiles/zshrc`:

```bash
# [ -f ~/.dotfiles/zsh/zshrc.company ] && source ~/.dotfiles/zsh/zshrc.company
```

Or disable specific plugins by removing them from the `plugins=()` array.

## Troubleshooting

### Slow Shell Startup

1. **Profile your startup time:**
   ```bash
   time zsh -i -c exit
   ```

2. **Disable unnecessary plugins** in `~/.zshrc.local`:
   ```bash
   plugins=(${plugins:#poetry})  # Remove poetry plugin
   ```

3. **Check for slow commands** - Add timing to your zshrc temporarily:
   ```bash
   PS4='+ %D{%s.%.} %N:%i> '
   set -x
   # ... your config ...
   set +x
   ```

### Missing Commands

If commands like `pathadd` are undefined:
- Ensure `~/.dotfiles/zsh/zshrc.functions` is being sourced
- Check that `~/.zshrc` is properly symlinked to `~/.dotfiles/zshrc`
- Run `./install` again

### SSH Agent Issues

If SSH keys aren't loading automatically:
1. Check that your key exists (default: `~/.ssh/id_ed25519`)
2. Add SSH configuration to `~/.zshrc.local` (see template)
3. Verify SSH_AUTH_SOCK is set: `echo $SSH_AUTH_SOCK`

## Contributing

This is a personal dotfiles repository, but feel free to:
- Fork it and adapt it for your own use
- Suggest improvements via issues
- Share your own dotfiles approach

## License

MIT License - Feel free to use and modify as needed.

## Resources

- [Dotbot Documentation](https://github.com/anishathalye/dotbot)
- [oh-my-zsh Documentation](https://github.com/ohmyzsh/ohmyzsh/wiki)
- [Powerlevel10k Documentation](https://github.com/romkatv/powerlevel10k)
- [GitHub CLI Documentation](https://cli.github.com/manual/)
