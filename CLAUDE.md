# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal dotfiles repository that manages zsh, git, and development tool configurations using [dotbot](https://github.com/anishathalye/dotbot). The configuration is modular, portable across machines, and security-focused with secrets separated from version control.

## Installation & Testing

```bash
./install          # Install/update dotfiles (uses dotbot, creates symlinks, initializes submodules)
source ~/.zshrc    # Test changes
time zsh -i -c exit  # Profile startup performance
```

## Architecture

### Modular Configuration System

The zsh configuration is split into focused modules loaded by `zshrc`:

1. **zshrc.history** - History configuration (50k commands, timestamps, deduplication)
2. **zshrc.functions.\*** - Utility functions organized by category (see Function Modules below)
3. **zshrc.aliases** - Portable aliases for git, docker, python, system commands
4. **zshrc.conditionals** - Conditional loading of optional tools (colorls, mise, direnv)
5. **zshrc.company** - Work-specific configuration (Quantivly)
6. **~/.zshrc.local** - Machine-specific secrets and settings (NOT in git)

### Function Modules

| Module | Purpose | Key Functions |
|--------|---------|---------------|
| `zshrc.functions.core` | Core utilities | `pathadd`, `mkcd`, `backup`, `extract`, `osc52`, `killnamed` |
| `zshrc.functions.git` | Git workflows | `gd`, `git_cleanup`, `gco-safe`, `gpf-safe`, `gpush-safe` |
| `zshrc.functions.fzf` | FZF integrations | `fcd`, `fkill`, `fenv`, `fssh`, `fport`, `fstash`, `fdiff` |
| `zshrc.functions.docker` | Docker helpers | `dexec`, `dlogs`, `dkill`, `dimages`, `dnetwork`, `dvolume` |
| `zshrc.functions.performance` | Performance monitoring | `startup_monitor`, `startup_profile`, `system_health`, `zsh_bench` |
| `zshrc.functions.utilities` | Helper functions | `has_command`, `check_tool`, `tool_status` |

**Function Naming Convention:**
- User-facing: No separator or dashes (e.g., `fcd`, `dexec`, `gco-safe`)
- Internal helpers: Underscores (e.g., `has_command`, `tool_status`)

### Symlink Structure

Dotbot creates symlinks from `install.conf.yaml`:
- `~/.zshrc` → `~/.dotfiles/zshrc`
- `~/.p10k.zsh` → `~/.dotfiles/p10k.zsh`
- `~/.gitconfig` → `~/.dotfiles/gitconfig`
- `~/.config/gh/config.yml` → `~/.dotfiles/gh/config.yml`
- `~/.config/git/ignore` → `~/.dotfiles/config/git/ignore`
- `~/.config/Code/User/settings.json` → `~/.dotfiles/vscode/settings.json`

### Configuration Loading Order

```
1. Powerlevel10k instant prompt (performance)
2. oh-my-zsh core and plugins
3. p10k.zsh theme
4. zsh/zshrc.history
5. zsh/zshrc.functions.*
6. zsh/zshrc.aliases
7. zsh/zshrc.conditionals (overrides aliases if tools installed)
8. zsh/zshrc.company
9. ~/.zshrc.local (machine-specific secrets)
10. PATH additions
```

**Key Insight:** Conditionals load AFTER aliases, so tools that are installed get priority configuration.

## Security Rules

**CRITICAL:** Never commit sensitive information. All secrets belong in `~/.zshrc.local`:
- API keys, tokens, passwords
- SSH key paths
- Machine-specific environment variables
- Work-related credentials

The `.gitignore` protects: `*.local`, `*.secrets`, `.env*`, `secrets/`

## Development Guidelines

### Adding New Configuration

**New zsh module:**
1. Create `zsh/zshrc.newmodule`
2. Add source line in `zshrc` around line 120-136: `[ -f ~/.dotfiles/zsh/zshrc.newmodule ] && source ~/.dotfiles/zsh/zshrc.newmodule`
3. Test: `source ~/.zshrc`

**New symlink:**
1. Edit `install.conf.yaml` under `link:` section
2. Run `./install`

### Oh-My-Zsh Plugins

Current plugins: autojump, colored-man-pages, command-not-found, direnv, extract, fzf, gh, git, poetry, safe-paste, sudo, web-search, zsh-autosuggestions, zsh-fzf-history-search, zsh-syntax-highlighting, quantivly

**Note:** `zsh-syntax-highlighting` must be last in the list.

### CI/CD Testing

GitHub Actions runs: ShellCheck, syntax validation, YAML validation, pre-commit hooks, installation tests (Ubuntu 22.04/24.04), security scans, and documentation checks.

**Run locally:**
```bash
pre-commit run --all-files    # All checks
bash -n install               # Syntax check
shellcheck -x install         # Lint
act -j shellcheck             # Run specific CI job locally (requires act)
```

See `.github/README.md` for details.

## Tool Dependencies

### Required Tools
- **zsh**, **oh-my-zsh**, **Powerlevel10k** (git submodule), **git**

### Strongly Recommended
- **fzf** - Fuzzy finder (many functions depend on it)
- **gh** - GitHub CLI (35+ custom aliases in `gh/config.yml`)

### Modern CLI Tools

All tools are optional with intelligent fallbacks. Managed by mise (see below).

**Core replacements:**
| Standard | Modern | Install |
|----------|--------|---------|
| cat | bat/batcat | `apt install bat` |
| ls | eza/exa/colorls | `mise use -g eza@latest` |
| find | fd/fdfind | `mise use -g fd@latest` |
| grep | ripgrep | `apt install ripgrep` (⚠️ Not POSIX compatible) |
| cd | zoxide | `mise use -g zoxide@latest` |
| top | btop | `apt install btop` |
| ps | procs | `cargo install procs` |
| df | duf | `mise use -g duf@latest` |
| du | dust | `mise use -g dust@latest` |
| diff | delta/difftastic | `mise use -g delta@latest` |

**Developer tools:** lazygit, just, glow, hyperfine, dive, forgit, ctop
**Security:** gitleaks, pre-commit, sops
**Productivity:** thefuck, tldr, cheat, neofetch/fastfetch

**Installation:**
```bash
./scripts/install-modern-tools.sh  # Interactive installer
tool_status                         # Check what's installed
```

### Version Manager: mise

**mise** - Modern polyglot version manager replacing nvm, pyenv, rbenv, asdf
- **Install**: `curl https://mise.run | sh` or via dev-setup
- **Config**: `~/.config/mise/config.toml` (global) or `.mise.toml` (per-project)
- **Performance**: ~5-10ms activation vs 200-400ms for nvm
- **Compatibility**: Reads `.nvmrc`, `.python-version`, `.tool-versions`

```bash
mise use -g node@lts python@3.12   # Install global versions
mise ls                             # List installed
mise outdated                       # Check for updates
```

For migration from nvm/pyenv, see [docs/MIGRATION.md](docs/MIGRATION.md).

## Managing CLI Tools with mise

Quick commands:
```bash
mise ls              # View installed tools
mise install         # Install from config
mise upgrade         # Upgrade to latest
mise use -g bat@latest  # Add a new tool
mise doctor          # Check status
```

### Configuration Architecture

**1. Single Source of Truth** - `~/.dotfiles/.mise.toml`
- Authoritative source for all CLI tool versions
- Defines 14 core CLI tools with pinned versions
- Copied to `~/.config/mise/config.toml` by `./install`
- **Trust**: Required when working in dotfiles directory: `mise trust ~/.dotfiles/.mise.toml`

**2. Active Configuration** - `~/.config/mise/config.toml`
- Created by `./install` from `.dotfiles/.mise.toml`
- What mise actually uses
- Auto-trusted (home directory)

**3. Project Overrides** - `.mise.toml` in project root
- Per-project version requirements
- Requires trust: `mise trust`

### Trust Configuration

Mise requires explicit trust for config files (security feature).

**When you'll see trust warnings:**
- Working in `~/.dotfiles/` directory
- Running mise commands in project directories
- Haven't trusted the `.mise.toml` file yet

**Solution:**
```bash
mise trust ~/.dotfiles/.mise.toml   # Trust dotfiles config (one-time)
mise config path                    # Verify active config
```

**Important:** Active config at `~/.config/mise/config.toml` is always trusted. Template in dotfiles requires trust only when working in that directory.

### Available Tools

**Managed by mise** (14 essential): bat, fd, eza, delta, zoxide, duf, dust, lazygit, just, glow, gitleaks, pre-commit, sops, fastfetch

**Optional** (uncomment in `.mise.toml`): dive, lazydocker, ctop, hyperfine, difftastic, cheat, tlrc

**Not managed by mise**: forgit (manual install), procs (via cargo), btop (via apt)

### Per-Project Tool Versions

Create `.mise.toml` in project root:
```toml
[tools]
just = "1.16.0"
node = "20.10.0"
python = "3.11.5"
```

Then: `mise install && mise ls`

### Version Updates

```bash
cd ~/.dotfiles
vim .mise.toml              # Update versions
mise install <tool>@<ver>   # Test
./install                   # Update active config
git add .mise.toml && git commit -m "Updated <tool> to <version>"
```

See `docs/TOOL_VERSION_UPDATES.md` for details.

## Python Environment Management

### Architecture

Projects use a unified **mise + direnv + Poetry** strategy:
- **mise**: Fast Python version management (~5-10ms activation)
- **direnv**: Automatic per-directory environment activation
- **Poetry**: Dependency management with in-project `.venv/`

**Why not pyenv?** mise is faster (~5-10ms vs ~100-200ms) and already installed by dev-setup.

### Project Structure

```
project-root/
├── .mise.toml               # mise Python version specification
├── .python-version          # Python version (for documentation)
├── .envrc                   # Auto-activation script (direnv)
└── .venv/                   # Virtual environment (in-project)
```

**Note:** VSCode configuration is now managed globally via dotfiles (`~/.config/Code/User/settings.json`). Projects only need `.vscode/settings.json` for project-specific overrides.

### Setup New Project

```bash
cd project-root

# Create .mise.toml
cat > .mise.toml << 'EOF'
[tools]
python = "3.11"
EOF

# Create .python-version (optional, for documentation)
echo "3.11" > .python-version

# Copy .envrc template
cp ~/.dotfiles/examples/envrc-templates/minimal.envrc .envrc
# See examples/envrc-templates/README.md and examples/python-project-setup.md for details

# Trust direnv and mise
direnv allow
mise trust

# Install Python version
mise install
```

### Verification

```bash
mise current           # Shows active Python version
echo $VIRTUAL_ENV      # Shows .venv path
which python           # Shows .venv/bin/python
python --version       # Shows expected version
```

### Dependency Management

The `.envrc` automatically checks if your dependencies need updating when you `cd` into a project:
- **Poetry projects**: Checks if `poetry.lock` is newer than `.venv`
- **pip + requirements.txt**: Checks if requirements.txt is newer than `.venv`
- **pip + requirements/ directory**: Checks if any .txt file in requirements/ is newer than `.venv`
- Shows: `⚠️  Dependencies outdated. Run: <command>`

**Fully Automatic:** When you run `poetry install` or `pip install`, it modifies files in `.venv`, automatically updating its timestamp. The warning disappears on your next `cd` into the project - no manual marking needed!

### Dependency Checking with quanticli

**Simple, single-location approach** - no dotfiles coupling, graceful degradation:

**.envrc pattern:**
```bash
# Activate mise environment (reads .mise.toml)
eval "$(mise activate bash --shims)"

# Create virtualenv if it doesn't exist
if [ ! -d .venv ]; then
    echo "Creating virtual environment..."
    python -m venv .venv
fi

# Activate virtualenv
export VIRTUAL_ENV="$(pwd)/.venv"
PATH_add "$VIRTUAL_ENV/bin"

# Mark Poetry projects (optional)
[ -f poetry.lock ] && export POETRY_ACTIVE=1

# Check dependencies if quanticli is available
if command -v quanticli &>/dev/null; then
    quanticli doctor deps --quiet 2>/dev/null || true
fi
```

**How it works:**
- `.envrc` conditionally calls `quanticli doctor deps --quiet` if quanticli is installed
- No coupling to dotfiles - projects work independently
- Graceful degradation - if quanticli not available, environment still activates
- Automatic checking when you `cd` into a project
- Manual checking: `quanticli doctor deps` (shows detailed output)
- CI/CD integration: `quanticli doctor deps` (exit code 0 = success, 1 = outdated)

**What it checks:**
- Poetry projects: Compares `poetry.lock` vs `.venv` modification time
- pip projects: Compares `requirements.txt` vs `.venv`
- Django-style: Checks all `requirements/*.txt` files
- PEP 621: Checks `pyproject.toml` (non-Poetry)

**Benefits:**
- ✅ No dotfiles coupling - independent projects
- ✅ Graceful degradation - works without quanticli
- ✅ Single implementation - updates in one place
- ✅ Automatic checking - runs on `cd` via .envrc
- ✅ Manual checking - `quanticli doctor deps` for diagnostics
- ✅ CI/CD ready - proper exit codes

**quanticli doctor deps usage:**
```bash
quanticli doctor deps              # Check current project
quanticli doctor deps -p ~/project # Check specific project
quanticli doctor deps --quiet      # Suppress output (for .envrc)
```

**Migration from shared helper:**
All 11 existing projects have been migrated to use this pattern:
- quanticli
- Platform: auto-conf, quantivly-sdk, box, ptbi, healthcheck, auto-test, ris
- Hub: sre-sdk, sre-core, hub root

The old `~/.dotfiles/shell/python-env-helpers.sh` is deprecated.

### Troubleshooting

**Environment not activating:**
```bash
direnv allow           # Trust .envrc
mise trust             # Trust .mise.toml
mise install           # Install Python version
direnv reload          # Force reload
```

**Wrong Python version:**
```bash
cat .mise.toml         # Check configured version
mise ls python         # List installed versions
mise install python@X.Y  # Install missing version
```

**VSCode using wrong interpreter:**
- Cmd+Shift+P → "Python: Select Interpreter"
- Choose `.venv/bin/python` from project
- Global settings (managed by dotfiles) already set `python.terminal.activateEnvironment: false`
- Verify global settings: `cat ~/.config/Code/User/settings.json`

**See:** [examples/python-project-setup.md](examples/python-project-setup.md) for complete examples.

## Command Behavior Changes

When tools are installed, standard commands are replaced:

| Command | Replacement | Changed By | Workaround |
|---------|-------------|------------|------------|
| grep | ripgrep (rg) | `zshrc.conditionals:54` | `\grep` or `command grep` |
| find | fd/fdfind | `zshrc.conditionals:44-48` | `\find` |
| cat | bat | `zshrc.conditionals:10-18` | `\cat` or `catp` |
| top | htop | `zshrc.conditionals:64-66` | `\top` |
| ls | eza/exa/colorls | `zshrc.conditionals:24-39` | `\ls` |

**Alias renamed:** `fd` → `fdir` (to avoid conflict with fd-find tool)

## Important Patterns

### pathadd Function

Always use `pathadd` for safe PATH additions:
```bash
pathadd "${HOME}/.local/bin"  # Checks existence, prevents duplicates
```

### Tool Availability Checks

Use two patterns depending on context:

**1. Direct `command -v` check** - For conditionals and standalone scripts:
```bash
if command -v colorls &>/dev/null; then
    alias ls='colorls --sd --sf'
fi
```

**2. `has_command()` function** - For cleaner syntax in functions:
```bash
has_command() { command -v "$1" &>/dev/null; }

setup_fzf() {
    if has_command fzf; then
        # Configure fzf
    fi
}
```

**Guidelines:**
- Use `command -v` in `zshrc.conditionals` and standalone scripts
- Use `has_command()` inside functions for readability
- Both are fast (~1-2ms); no caching needed

**Historical note:** Tool cache was removed after benchmarks showed 81ms overhead.

### FZF Integration

Key fzf functions: `fcd`, `fbr`, `fco`, `fshow`, `fkill`, `fenv`, `fssh`, `fport`

## Git Configuration

**Key settings:**
- Editor: VS Code (`code --wait`)
- Default branch: `main`
- Credential helper: GitHub CLI (`gh auth git-credential`)
- GPG signing: Disabled by default (see below to enable)

**Useful aliases:** `git lg` (pretty log), `git conflicts` (show merge conflicts)

## GPG Commit Signing

**Quick setup:**
```bash
gpg --full-generate-key
# In ~/.gitconfig.local:
# [user]
#     signingkey = YOUR_KEY_ID
# [commit]
#     gpgsign = true
gpg-prime  # Prime cache once per session
```

**Utilities:**
- `gpg-prime` - Prime cache for automatic signing
- `git-check-gpg-cache` - Check cache status
- `install-gpg-hooks` - Install pre-commit hooks

**Documentation:**
- Quick-start: [examples/gpg-setup-guide.md](examples/gpg-setup-guide.md)
- Technical: [docs/GPG_SIGNING_SETUP.md](docs/GPG_SIGNING_SETUP.md)
- Workflows: [examples/git-workflows.md](examples/git-workflows.md)

## GitHub CLI Aliases

35+ `gh` aliases in `gh/config.yml`:
- `gh mypr` - Your open PRs
- `gh prs` - All open non-draft PRs
- `gh review` - PRs where you're requested as reviewer
- `gh prmerge` - Squash merge and delete branch
- `gh runs` - Recent workflow runs for current branch

## Common Tasks

```bash
# Reload zsh config
source ~/.zshrc  # or: zshreload

# Edit machine-specific config
vim ~/.zshrc.local  # or: localrc
chmod 600 ~/.zshrc.local

# View PATH
path  # alias for: echo $PATH | tr ":" "\n"

# Copy to clipboard (works over SSH with OSC 52!)
copyfile filename    # Smart clipboard with auto-detection
catcopy filename     # View with bat + copy
osc52 "text"         # Direct OSC 52 copy

# Verify tool status
./scripts/verify-tools.sh
```

## Workflow Examples

Comprehensive guides in `examples/` directory:

- **[examples/git-workflows.md](examples/git-workflows.md)** - Feature branches, conflict resolution, PR reviews, WIP commits, cleanup
- **[examples/docker-workflows.md](examples/docker-workflows.md)** - Service management, debugging, cleanup, networking
- **[examples/fzf-recipes.md](examples/fzf-recipes.md)** - Interactive fuzzy finding, keybindings, integrations

Quick reference:
```bash
# Git workflow
gcb feature/my-feature && gaa && gcam "feat: My feature" && gp && gh pr create --web

# Docker workflow
dcup && dps && dclogs

# FZF usage
Ctrl+T    # Fuzzy file search
fbr       # Fuzzy branch checkout
fshow     # Browse git history
```

## Troubleshooting

### Slow zsh startup
```bash
time zsh -i -c exit  # Profile performance
# Disable slow plugins in ~/.zshrc.local: plugins=(${plugins:#poetry})
# mise is fast (~5-10ms). If using nvm/pyenv, see docs/MIGRATION.md
```

### Function not found
```bash
ls -la ~/.zshrc      # Check symlink
./install            # Re-run installer
zsh -n ~/.zshrc      # Verify syntax
```

### Tool not loading
```bash
command -v toolname  # Check if installed
source ~/.zshrc      # Reload config
```

### mise config not trusted
Trust the config file: `mise trust ~/.dotfiles/.mise.toml`

See [Trust Configuration](#trust-configuration) section for full details.

### Command not found after adding tool
```bash
source ~/.zshrc              # Reload
command -v toolname          # Verify installation
echo $PATH | tr ":" "\n"     # Check PATH
```

### Unexpected command behavior
```bash
alias commandname            # Check for alias
type commandname             # See what runs
\commandname                 # Bypass alias
```

### Alias conflicts
```bash
alias                                        # List all aliases
grep -r "alias aliasname=" ~/.dotfiles/      # Find definition
# Override in ~/.zshrc.local with: unalias aliasname
```

### Git authentication issues
```bash
gh auth status   # Check status
gh auth login    # Re-authenticate
```

### fzf functions not working
```bash
command -v fzf   # Check installation
apt install fzf  # or: brew install fzf
```

### Syntax errors
```bash
zsh -n ~/.zshrc                         # Check main config
zsh -n ~/.dotfiles/zsh/zshrc.aliases    # Check modules
# Temporarily disable modules by commenting source lines in zshrc
```
