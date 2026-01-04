# Quantivly Dotfiles

![CI](https://github.com/quantivly/dotfiles/workflows/CI/badge.svg)

Shared configuration files for zsh, git, and various development tools used by the Quantivly team, managed with [dotbot](https://github.com/anishathalye/dotbot).

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
│   ├── zshrc.conditionals   # Optional tool configs (mise, colorls, etc.)
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
   git clone --recursive https://github.com/quantivly/dotfiles.git ~/.dotfiles
   cd ~/.dotfiles
   ```

3. **Run the installer:**

   ```bash
   ./install
   ```

4. **Configure your git identity:**

   The installer creates `~/.gitconfig.local` from the template. Edit it to set your personal information:

   ```bash
   vim ~/.gitconfig.local  # or your preferred editor

   # Set your name and email:
   [user]
       name = Your Name
       email = your.email@quantivly.com
   ```

   **Recommended:** Set up GPG signing to verify your commits (see [Personalization](#personalization) section for detailed instructions).

5. **Customize machine-specific settings:**

   The installer creates `~/.zshrc.local` from the template. Edit it to add:
   - API keys and tokens
   - Machine-specific PATH additions
   - SSH key configuration
   - Custom aliases for this machine

   ```bash
   vim ~/.zshrc.local  # or your preferred editor
   chmod 600 ~/.zshrc.local  # Ensure it's only readable by you
   ```

6. **Install optional dependencies** (see below)

### Updating Existing Installation

```bash
cd ~/.dotfiles
git pull
./install
```

## Installing Modern CLI Tools

Modern CLI tools (bat, fd, eza, ripgrep, lazygit, etc.) are managed through mise for unified version control and cross-platform consistency.

### Option 1: Via dev-setup (Recommended for Quantivly developers)

The dev-setup script installs everything automatically:
```bash
git clone https://github.com/quantivly/dev-setup.git
cd dev-setup
./setup.sh
```

This installs: zsh, dotfiles, mise, Python, Poetry, quanticli, and all CLI tools.

### Option 2: Manual Installation

1. **Install mise:**
   ```bash
   curl https://mise.run | sh
   ```

2. **Create tool config:**
   ```bash
   mkdir -p ~/.config/mise
   cp examples/mise-config.toml ~/.config/mise/config.toml
   ```

3. **Install tools (5-10 minutes):**
   ```bash
   ~/.local/bin/mise install
   ```

4. **Reload shell:**
   ```bash
   source ~/.zshrc
   ```

5. **Verify installation:**
   ```bash
   mise ls
   which bat fd eza delta
   ```

### Managing Tools

```bash
# View installed tools
mise ls

# Install/update all tools
mise install      # Install from config
mise upgrade      # Upgrade to latest

# Add a new tool
mise use -g bat@latest

# Check status
mise doctor
```

See `CLAUDE.md` for complete documentation on managing CLI tools with mise.

**Migrating from nvm/pyenv?** See [docs/MIGRATION.md](docs/MIGRATION.md) for step-by-step migration instructions.

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

- **mise** - Unified version manager for Node.js, Python, and 100+ languages
  ```bash
  # Automated installation (recommended)
  ./scripts/install-modern-tools.sh  # Select option 1 for essential tools

  # Or manual installation:
  # Ubuntu 24.04+
  sudo apt install mise

  # macOS
  brew install mise

  # Generic (curl installer)
  curl https://mise.run | sh
  ```

  **Quick start:**
  ```bash
  mise use -g node@lts python@3.12  # Install global versions
  mise ls                            # List installed versions
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
- mise (if installed)
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

### ~/.gitconfig.local (Not in Git)

Personal git configuration that should NEVER be committed:
- Your name and email address
- GPG signing keys
- Machine-specific git settings
- Personal git aliases

This file is included by the main `gitconfig` via the `[include]` directive.

## Personalization

These dotfiles are designed to be shared across the team while allowing personal customization.

### Git Configuration

Your personal git settings go in `~/.gitconfig.local`:

```bash
# Required: Your identity
[user]
    name = Your Name
    email = your.email@quantivly.com

# Recommended: GPG signing for commit verification
[user]
    signingkey = YOUR_GPG_KEY_ID
[commit]
    gpgsign = true
```

**GPG signing is strongly encouraged** to verify your identity and ensure commit authenticity. The dotfiles repository includes utilities to make GPG signing convenient:

- **gpg-prime** - Prime your GPG cache once per work session (8-24 hour cache)
- **Automatic prevention** - Pre-commit hook prevents hanging when cache expires
- **Shell reminder** - One-time reminder per session if cache not primed
- **Clear guidance** - Helpful error messages with actionable steps

**Quick setup:** See [examples/gpg-setup-guide.md](examples/gpg-setup-guide.md) for complete step-by-step instructions (5 minutes to verified commits).

**Already set up?** Just run `gpg-prime` once when you start working each day.

This file is automatically created from `gitconfig.local.example` during installation.

### Shell Configuration

Machine-specific shell settings go in `~/.zshrc.local`:

```bash
# API keys and secrets
export ANTHROPIC_API_KEY="sk-..."

# Machine-specific PATHs
export PATH="$HOME/my-tools/bin:$PATH"

# Custom aliases
alias myproject="cd ~/projects/myproject"
```

This file is automatically created from `zsh/zshrc.local.example` during installation.

### Forking for Personal Use

If you want to heavily customize these dotfiles:

1. Fork the repository: `https://github.com/quantivly/dotfiles`
2. Clone your fork: `git clone https://github.com/yourusername/dotfiles.git ~/.dotfiles`
3. Make your changes and commit them to your fork
4. Keep your fork in sync with upstream for team updates

## Security Best Practices

1. **Never commit personal information** - All sensitive and personal data goes in local files:
   - `~/.zshrc.local` for shell secrets and machine-specific config
   - `~/.gitconfig.local` for your git identity and GPG keys
2. **Protect your local config** - Both `~/.zshrc.local` and `~/.gitconfig.local` should have mode 600
3. **Review before committing** - Always check what you're committing to git
4. **Rotate exposed tokens** - If you accidentally commit secrets, rotate them immediately
5. **Use .gitignore** - The included `.gitignore` prevents common secret files from being committed
6. **Docker aliases security** - Docker cleanup functions (`dstop`, `drm`, `drmi`) use container/image IDs (not names) and safe iteration patterns to prevent command injection vulnerabilities

## Key Features

### Shell Enhancements

**Navigation:**
- `AUTO_CD` - Type directory name without cd command
- Smart directory stack with duplicate prevention
- Fuzzy directory search with `fcd`

**Completion:**
- Case-insensitive tab completion
- Colored completion matching your LS_COLORS
- Menu selection with arrow keys
- Complete from within a word/phrase

**History:**
- 50,000 commands stored with timestamps
- Smart duplicate removal
- Shared across all sessions
- Ignores common commands (ls, cd, pwd)

**Key Bindings:**
- Ctrl/Alt + Arrow keys for word movement
- Proper Home/End/Delete key support

### Utility Functions

**File & Directory:**
- `mkcd <dir>` - Create directory and cd into it
- `backup <file>` - Create timestamped backup
- `extract <file>` - Universal archive extractor
- `dirsize [dir]` - Show directory sizes sorted

**Network:**
- `myip` - Display public IP
- `localip` - Display local IP

**Development:**
- `note <msg>` - Quick timestamped notes
- `psgrep <pattern>` - Find processes
- `killnamed <name>` - Kill processes by name
- `gwt <branch>` - Git worktree wrapper

### Modern CLI Tool Integration

The configuration automatically detects and uses modern alternatives:

| Standard | Modern Alternative | Benefit |
|----------|-------------------|---------|
| `cat` | `bat` | Syntax highlighting, line numbers |
| `ls` | `eza`/`exa` | Colors, icons, better formatting |
| `find` | `fd` | Faster, respects .gitignore |
| `grep` | `ripgrep` | Much faster recursive search |
| `top` | `htop` | Better process viewer |
| git diff | `delta` | Syntax highlighting in diffs |

Tools are only used if installed. Use `\command` to bypass aliases (e.g., `\cat`, `\ls`).

### FZF Integration

Fuzzy finding for:
- Files and directories (`Ctrl+T`, `Alt+C`)
- Command history (`Ctrl+R`)
- Git branches: `fbr`
- Git commits: `fco`
- Git commit browser: `fshow`

### Enhanced Aliases

**Git shortcuts:**
```bash
gaa    # git add --all
gcam   # git commit -am
glogp  # Pretty git log with colors
gundo  # Undo last commit (soft)
gwip   # Quick WIP commit
```

**Docker shortcuts:**
```bash
dps    # docker ps
dex    # docker exec -it
dcup   # docker compose up -d
dclogs # docker compose logs -f
dclean # docker system prune
```

**System shortcuts:**
```bash
zshreload  # Reload zsh config
localrc    # Edit ~/.zshrc.local
c          # clear
..         # cd ..
...        # cd ../..
```

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

**And 25+ more!** See [gh/config.yml](gh/config.yml) for the complete list.

## Workflow Examples

Comprehensive workflow guides are available in the `examples/` directory:

### [Git Workflows](examples/git-workflows.md)
Step-by-step guides for:
- Feature branch development
- Pull request review workflow
- Merge conflict resolution
- Quick WIP commits (`gwip`/`gunwip`)
- Branch cleanup and maintenance
- Advanced operations (rebase, cherry-pick, stash)

### [Docker Workflows](examples/docker-workflows.md)
Practical Docker workflows for:
- Starting and monitoring services
- Container debugging and inspection
- Image management and cleanup
- Networking and volumes
- Troubleshooting common issues

### [FZF Integration Recipes](examples/fzf-recipes.md)
Power user tips for:
- Interactive fuzzy finding (`Ctrl+T`, `Ctrl+R`, `Alt+C`)
- Custom functions (`fcd`, `fbr`, `fco`, `fshow`)
- Process management
- Advanced file operations
- Git and Docker integration

See [examples/README.md](examples/README.md) for the complete index.

For tool installation and verification, see the [Utility Scripts](#utility-scripts) section.

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

## Security

This repository includes multiple layers of security to prevent accidental credential exposure:

### Incident Response
**Accidentally committed a secret?** Follow the step-by-step guide: [docs/SECURITY_INCIDENTS.md](docs/SECURITY_INCIDENTS.md)

- Immediate credential rotation procedures
- Git history cleanup instructions
- Team notification templates
- Post-incident review checklist

### Automated Prevention
- **Pre-commit hooks**: Automatic secret detection via gitleaks
- **Private key detection**: Blocks SSH/GPG keys from commits
- **Custom patterns**: HISTORY_IGNORE prevents secrets in shell history
- **File patterns**: `.gitignore` blocks sensitive file types

### Secret Storage
- **Never** commit secrets to git - use `~/.zshrc.local` (chmod 600)
- **Use sops** for encrypted secrets: `~/.secrets/env.enc.yaml`
- **Rotate immediately** if a secret is exposed
- **Enable GPG signing** to verify commit authenticity (see [Personalization](#personalization))

## Contributing

Contributions from the team are welcome! To contribute:
- Fork the repository and make your changes
- Test your changes on a fresh installation
- Run pre-commit checks locally: `pre-commit run --all-files`
- Ensure CI pipeline passes (automatic on PR)
- Submit a pull request with a clear description
- Ensure changes don't break existing configurations
- Keep personal information out of shared files (use `.local` files instead)

**Automated Testing:** All PRs automatically run:
- ShellCheck linting
- Syntax validation (bash/zsh)
- Pre-commit security hooks
- Installation tests on Ubuntu 22.04 and 24.04
- Secret detection via gitleaks
- Documentation validation

See `.github/README.md` for details on running tests locally.

## License

MIT License - Feel free to use and modify as needed.

## Resources

### Internal Documentation

- [Migration Guide](docs/MIGRATION.md) - Migrating from nvm/pyenv to mise
- [Security Incident Response](docs/SECURITY_INCIDENTS.md) - What to do if you accidentally commit secrets
- [GPG Signing Setup](docs/GPG_SIGNING_SETUP.md) - Technical reference for GPG commit signing
- [Workflow Examples](examples/README.md) - Git, Docker, and FZF workflow guides

### External Documentation

- [Dotbot Documentation](https://github.com/anishathalye/dotbot)
- [oh-my-zsh Documentation](https://github.com/ohmyzsh/ohmyzsh/wiki)
- [Powerlevel10k Documentation](https://github.com/romkatv/powerlevel10k)
- [GitHub CLI Documentation](https://cli.github.com/manual/)
- [mise Documentation](https://mise.jdx.dev/)
