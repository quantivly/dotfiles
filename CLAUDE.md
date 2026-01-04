# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal dotfiles repository that manages zsh, git, and development tool configurations using [dotbot](https://github.com/anishathalye/dotbot). The configuration is modular, portable across machines, and security-focused with secrets separated from version control.

## Installation & Testing

**Install/update dotfiles:**
```bash
./install
```

This script:
- Uses dotbot to create symlinks to configuration files
- Initializes git submodules
- Creates `~/.zshrc.local` from template if it doesn't exist

**Test changes:**
```bash
source ~/.zshrc
# or
zsh -i -c exit  # Test for errors
```

**Profile startup performance:**
```bash
time zsh -i -c exit
```

## Architecture

### Modular Configuration System

The zsh configuration is split into focused modules loaded by `zshrc`:

1. **zshrc.history** - History configuration (50k commands, timestamps, deduplication)
2. **zshrc.functions** - Utility functions (`pathadd`, `mkcd`, `backup`, `gwt`, etc.)
3. **zshrc.aliases** - Portable aliases for git, docker, python, system commands
4. **zshrc.conditionals** - Conditional loading of optional tools (colorls, mise, direnv)
5. **zshrc.company** - Work-specific configuration (Quantivly)
6. **~/.zshrc.local** - Machine-specific secrets and settings (NOT in git)

### Symlink Structure

Dotbot creates these symlinks from `install.conf.yaml`:
- `~/.zshrc` → `~/.dotfiles/zshrc`
- `~/.p10k.zsh` → `~/.dotfiles/p10k.zsh`
- `~/.gitconfig` → `~/.dotfiles/gitconfig`
- `~/.config/gh/config.yml` → `~/.dotfiles/gh/config.yml`
- `~/.config/git/ignore` → `~/.dotfiles/config/git/ignore`

## Security Rules

**CRITICAL:** Never commit sensitive information. All secrets belong in `~/.zshrc.local`:
- API keys and tokens
- SSH key paths
- Machine-specific environment variables
- Work-related credentials

The `.gitignore` includes:
- `*.local`
- `*.secrets`
- `.env*`
- `secrets/`

When editing configuration files, always review changes before committing to ensure no secrets were accidentally included.

## Development Guidelines

### Adding New Configuration

**Add a new zsh module:**
1. Create `zsh/zshrc.newmodule`
2. Add source line in `zshrc` around line 120-136:
   ```bash
   [ -f ~/.dotfiles/zsh/zshrc.newmodule ] && source ~/.dotfiles/zsh/zshrc.newmodule
   ```
3. Test with `source ~/.zshrc`

**Add new symlink:**
1. Edit `install.conf.yaml`
2. Add entry under `link:` section
3. Run `./install` to create symlink

### Modifying Existing Files

**Key files and their purposes:**
- `zshrc` - Main entry point, loads oh-my-zsh and modules
- `zsh/zshrc.functions` - Add reusable shell functions here
- `zsh/zshrc.aliases` - Add portable aliases here
- `zsh/zshrc.conditionals` - Add tool-specific conditional setup here
- `gitconfig` - Git configuration (user info is specific to this user)
- `gh/config.yml` - GitHub CLI aliases (35+ workflow shortcuts)

### Oh-My-Zsh Plugins

Current plugins loaded (line 25-45 in `zshrc`):
- autojump, colored-man-pages, command-not-found, direnv, extract
- fzf, gh, git, poetry, safe-paste, sudo, web-search
- zsh-autosuggestions, zsh-fzf-history-search, zsh-syntax-highlighting
- quantivly (optional company plugin)

**Note:** `zsh-syntax-highlighting` must be last in the list.

### Configuration Loading Order

Understanding the order in which configuration files are loaded helps debug issues and understand precedence:

```
Loading Order (from zshrc):
1. Line 9-11:  Powerlevel10k instant prompt (performance optimization)
2. Line 47:    oh-my-zsh core and plugins
3. Line 50:    p10k.zsh theme configuration
4. Line 124:   zsh/zshrc.history (history settings)
5. Line 127:   zsh/zshrc.functions (utility functions like pathadd)
6. Line 130:   zsh/zshrc.aliases (common aliases)
7. Line 133:   zsh/zshrc.conditionals (tool-specific conditional config)
8. Line 136:   zsh/zshrc.company (Quantivly work config)
9. Line 150:   ~/.zshrc.local (machine-specific secrets)
10. Line 160:  PATH additions
```

**Key Insight:** Conditionals load AFTER aliases, so conditional aliases override unconditional ones. This is intentional - tools that are installed get priority configuration.

### CI/CD Testing

The repository includes automated GitHub Actions workflows to ensure quality and prevent regressions.

**Workflow Jobs** (see `.github/workflows/ci.yml`):

1. **ShellCheck** - Lints all shell scripts for common issues
2. **Syntax Check** - Validates bash and zsh syntax for all configuration modules
3. **YAML Validation** - Ensures install.conf.yaml and other YAML files are valid
4. **Pre-commit Hooks** - Runs security checks (gitleaks, secret detection, etc.)
5. **Installation Tests** - Tests `./install` on Ubuntu 22.04 and 24.04
6. **Security Scan** - Full repository scan for secrets via gitleaks
7. **Documentation Check** - Validates markdown links and verifies required docs exist

**Running Tests Locally:**

```bash
# Install pre-commit (via mise or pip)
mise use -g pre-commit@latest
# or
pip install pre-commit

# Run all checks
pre-commit run --all-files

# Test specific checks
bash -n install                    # Syntax check install script
zsh -n zsh/zshrc.aliases           # Syntax check zsh module
shellcheck -x install              # Lint install script
```

**Local CI Simulation:**

```bash
# Install act (https://github.com/nektos/act)
brew install act  # or download from releases

# Run specific CI jobs locally
act -j shellcheck
act -j syntax-check
act -j pre-commit

# Run all CI jobs
act pull_request
```

**When to Run Tests:**

- **Before committing**: Run `pre-commit run --all-files`
- **Before PR**: Ensure local tests pass
- **After refactoring**: Test syntax and installation
- **Adding new scripts**: Add to ShellCheck patterns

**CI Badge:**

The README includes a CI status badge showing build health:
```
![CI](https://github.com/quantivly/dotfiles/workflows/CI/badge.svg)
```

**Troubleshooting CI Failures:**

- **ShellCheck errors**: Review warnings, fix or add `# shellcheck disable=SC####` with justification
- **Syntax errors**: Test locally with `bash -n` or `zsh -n`
- **Pre-commit failures**: Run locally to see full error context
- **Installation test failures**: Test `./install` in clean container
- **Secret detection**: Remove secrets, use `.local` files or sops

For more details, see `.github/README.md`.

## Tool Dependencies

### Required Tools (Must Install)

These tools are required for the configuration to work properly:
- **zsh** - The shell itself
- **oh-my-zsh** - Plugin framework
- **Powerlevel10k** - Prompt theme (git submodule)
- **git** - Version control (used extensively)

### Strongly Recommended Tools

These tools significantly enhance the development experience:
- **fzf** - Fuzzy finder (many functions depend on it: `fcd`, `fbr`, `fco`, `fshow`)
- **gh** - GitHub CLI (35+ custom aliases configured in `gh/config.yml`)

### Modern CLI Tools (Enhanced in 2024)

The dotfiles configuration now supports 25+ modern CLI tool replacements with intelligent fallback chains. All tools are optional and configured conditionally - your setup won't break if tools aren't installed.

#### Core Replacement Tools
| Standard Tool | Modern Replacement | Priority | Install Command | Notes |
|--------------|-------------------|----------|-----------------|-------|
| cat | bat/batcat | Optional | `apt install bat` | Ubuntu uses `batcat` name |
| ls | eza | First | `cargo install eza` | Maintained fork of exa |
| ls | exa | Second | `apt install exa` | Original, unmaintained |
| ls | colorls | Third | `gem install colorls` | Ruby-based fallback |
| find | fd/fdfind | Optional | `apt install fd-find` | Ubuntu uses `fdfind` name |
| grep | ripgrep | Optional | `apt install ripgrep` | **Warning:** Not fully POSIX compatible |
| cd | zoxide | **NEW** | `./scripts/install-modern-tools.sh` | Learns from usage patterns |
| top | btop | **NEW** | `apt install btop` | Modern resource monitor |
| ps | procs | **NEW** | `cargo install procs` | Tree view, search, sorting |
| df | duf | **NEW** | `apt install duf` | Beautiful disk usage visualization |
| du | dust | **NEW** | `cargo install du-dust` | Intuitive directory sizes |
| diff | delta | Optional | GitHub releases | Syntax-highlighted diffs |
| diff | difftastic | **NEW** | `cargo install difftastic` | Structural diffs |

#### Developer & Git Tools
| Tool | Purpose | Key Features |
|------|---------|-------------|
| **lazygit** | Git TUI | Interactive staging, branching, merging |
| **dive** | Docker analyzer | Analyze image layers for optimization |
| **forgit** | Git + FZF | Interactive git operations with fuzzy finding |
| **just** | Command runner | Modern make alternative with better syntax |
| **hyperfine** | Benchmarking | Command performance testing and comparison |
| **glow** | Markdown viewer | Beautiful terminal markdown rendering |
| **ctop** | Container monitor | htop-style interface for Docker containers |

#### Security & Code Quality Tools
| Tool | Purpose | Key Features |
|------|---------|-------------|
| **gitleaks** | Secret scanner | Prevent secrets from entering git history |
| **pre-commit** | Code quality | Automated checks before commits |
| **sops** | Secrets management | Encrypted secrets with git integration |

#### Productivity & Navigation
| Tool | Purpose | Key Features |
|------|---------|-------------|
| **thefuck** | Command correction | Auto-fix previous commands with `fuck` |
| **tldr** | Simplified docs | Concise command examples vs full man pages |
| **cheat** | Interactive cheatsheets | Personal command cheatsheets |
| **neofetch/fastfetch** | System info | Beautiful system information display |

#### Easy Installation

**Automated Installation Script:**
```bash
# Run the comprehensive installation script
./scripts/install-modern-tools.sh

# Interactive options:
# 1. Essential tools (recommended for all users)
# 2. Development tools (for developers)
# 3. All tools (complete setup)
# 4. Install specific tool
# 5. Show tool status
```

**Manual Installation Examples:**
```bash
# Core productivity tools
curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
apt install btop duf
cargo install procs du-dust eza

# Developer tools
apt install lazygit  # or GitHub releases for latest
cargo install just hyperfine difftastic
pip install thefuck pre-commit gitleaks

# Check what's installed
tool_status  # runs comprehensive status check
```

#### New Functions Added

**Enhanced FZF Functions:**
- `fkill` - Fuzzy process killer with preview
- `fenv` - Browse environment variables with fzf
- `fssh` - SSH host selection from config/known_hosts
- `fport` - Find what's using a specific port

**Enhanced Docker Functions:**
- `dexec` - Fuzzy container selection for exec
- `dlogs` - Fuzzy container logs viewing
- `dkill` - Fuzzy container stopping
- `dimages` - Interactive image management

**Git Workflow Functions:**
- `git_cleanup` - Automated branch cleanup with confirmations
- `fgit` - Menu-driven git operations
- `fstash` - Fuzzy git stash management
- `fdiff` - Fuzzy file selection for git diff
- `fworktree` - Git worktree management with fzf

**Performance Monitoring:**
- `startup_monitor` - Monitor shell startup with alerts
- `startup_profile` - Detailed startup profiling with recommendations
- `system_health` - Comprehensive system health check

### Version Manager

- **mise** - Modern polyglot version manager (https://mise.jdx.dev/)
  - **Replaces**: nvm, pyenv, rbenv, asdf
  - **Install**: `./scripts/install-modern-tools.sh` or `curl https://mise.run | sh`
  - **Config**: `~/.config/mise/config.toml` (global) or `.mise.toml` (per-project)
  - **Legacy support**: Reads `.nvmrc`, `.python-version`, `.tool-versions` files
  - **Performance**: ~5-10ms activation (no lazy loading needed)
  - **Languages**: Node, Python, Ruby, Go, Rust, Java, PHP, and 100+ more

#### Quick Start

```bash
# Install global versions
mise use -g node@lts python@3.12

# Install project-specific versions
cd my-project/
mise use node@20.10.0 python@3.11

# List installed versions
mise ls

# List available versions
mise ls-remote node
mise ls-remote python
```

#### Migration from nvm/pyenv

If you previously used nvm or pyenv, see [docs/MIGRATION.md](docs/MIGRATION.md) for comprehensive step-by-step migration instructions including verification, troubleshooting, and rollback procedures.

**Quick migration (4 steps):**

1. Install your versions with mise:
   ```bash
   mise use -g node@20 python@3.12
   ```

2. Remove old version managers:
   ```bash
   rm -rf ~/.nvm ~/.pyenv
   ```

3. Clean up `~/.zshrc.local` if you have nvm/pyenv exports

4. Reload shell: `source ~/.zshrc`

For detailed instructions, see [docs/MIGRATION.md](docs/MIGRATION.md).

## Managing CLI Tools with mise

All modern CLI tools (bat, fd, eza, ripgrep, etc.) are managed through mise for unified version control.

### Quick Commands

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

### Configuration

The dotfiles repository provides a unified mise configuration:

**Dotfiles (committed)**: `.mise.toml` - Pinned versions for reproducibility
  - Automatically installed by `./install` script to `~/.config/mise/config.toml`
  - Synchronized with dev-setup repository tool versions
  - Recommended for team consistency

**Global**: `~/.config/mise/config.toml` - Active configuration
  - Created from `.mise.toml` during installation
  - Can be customized per machine if needed

**Project**: `.mise.toml` - Override versions per project (optional)
  - Committed to git for project-specific requirements

**Example**: `examples/mise-config.toml` - Template with "latest" versions
  - Use for custom configurations
  - Alternative to pinned versions

### Version Management

**Pinned Versions** (recommended):
- Copy from dotfiles: `cp ~/.dotfiles/.mise.toml ~/.config/mise/config.toml`
- Reproducible, tested versions
- Synchronized across team

**Latest Versions** (alternative):
- Copy from examples: `cp ~/.dotfiles/examples/mise-config.toml ~/.config/mise/config.toml`
- Always newest features
- May have compatibility issues

See `docs/TOOL_VERSION_UPDATES.md` (coming in DO-152) for update procedures.

### Available Tools

**Managed by mise** (14 essential):
- Core CLI: bat, fd, eza, delta
- Navigation: zoxide
- Monitoring: duf, dust
- Developer: lazygit, just, glow
- Security: gitleaks, pre-commit, sops
- Productivity: fastfetch

**Note:** btop should be installed via apt (`apt install btop`) due to aqua registry asset name issue.

**Optional tools** (uncomment in `.mise.toml`):
- dive, lazydocker, ctop - Docker tools
- hyperfine - Benchmarking
- difftastic - Structural diffs
- cheat - Interactive cheatsheets
- tlrc - Rust-based tldr client

**Not managed by mise**:
- forgit - Manual git clone to ~/.forgit
- procs - Install via `cargo install procs` (optional)

### Per-Project Tool Versions

Create `.mise.toml` in project root to pin specific versions:

```toml
[tools]
just = "1.16.0"
hyperfine = "1.18.0"
```

Commit this file to git for team consistency.

### Per-Project Tool Versions Example

For a project that needs specific tool versions:

```bash
cd ~/my-project

# Create project config
cat > .mise.toml << 'EOF'
[tools]
just = "1.16.0"
node = "20.10.0"
python = "3.11.5"
EOF

# Install project tools
mise install

# Verify
mise ls
```

### Other Optional Tools

- **direnv** - Per-directory environment variables (`apt install direnv`)
- **autojump** - Fast directory navigation (`apt install autojump`)
- **poetry** - Python dependency management (`pip install poetry`)
- **xclip** - Clipboard support on Linux (`apt install xclip`)

### Plugin Requirements

Some oh-my-zsh plugins require external tools:
- `autojump` plugin → requires `autojump` binary
- `direnv` plugin → requires `direnv` binary
- `fzf` plugin → requires `fzf` binary
- `poetry` plugin → requires `poetry` binary
- `gh` plugin → requires `gh` CLI tool
- `quantivly` plugin → requires custom plugin installation (work-specific)

**Note:** oh-my-zsh handles missing plugin dependencies gracefully - plugins simply won't activate if their tools aren't installed.

## Command Behavior Changes

When optional tools are installed, these standard commands behave differently:

### grep → ripgrep (rg)
**Changed by:** `zshrc.conditionals:54`
**Behavior:** Completely replaces `grep` with `rg` if ripgrep is installed
**Warning:** ripgrep is NOT fully POSIX compatible - it has different options and behavior
**Workaround:** Use `\grep` to access original grep, or `command grep` to bypass alias

### find → fd
**Changed by:** `zshrc.conditionals:44-48`
**Behavior:** Replaces `find` with `fd` (or `fdfind` on Ubuntu)
**Key Difference:** fd respects `.gitignore` by default, has different syntax
**Workaround:** Use `\find` to access original find command

### cat → bat
**Changed by:** `zshrc.conditionals:10-18`
**Behavior:** Adds syntax highlighting and line numbers
**Impact:** May alter output in scripts expecting plain text
**Workaround:** Use `\cat` for original behavior, or `catp` alias for bat without line numbers

### top → htop
**Changed by:** `zshrc.conditionals:64-66`
**Behavior:** Replaces with interactive htop interface
**Note:** Only active if htop is installed (conditional check)
**Workaround:** Use `\top` to access original top command

### ls → eza/exa/colorls
**Changed by:** `zshrc.conditionals:24-39`
**Behavior:** Priority chain: eza → exa → colorls → standard ls
**Features:** Icons, colors, git integration, better formatting
**Workaround:** Use `\ls` or `command ls` for original ls

### Alias Renamed: fd → fdir
**Location:** `zshrc.aliases:80`
**Previous:** `alias fd='find . -type d -name'` (find directories)
**Current:** `alias fdir='find . -type d -name'`
**Reason:** Avoid conflict with fd-find tool
**Impact:** If you used `fd` for finding directories, use `fdir` instead

## Important Patterns

### pathadd Function

Always use `pathadd` to add directories to PATH safely:
```bash
pathadd "${HOME}/.local/bin"
pathadd "${HOME}/custom/bin"
```

This ensures:
- Directory exists before adding
- No duplicates in PATH
- Works across different machines

### Conditional Tool Loading

The `zshrc.conditionals` module checks for tool availability before configuration:
```bash
if command -v colorls &> /dev/null; then
    alias ls='colorls --sd --sf'
fi
```

Follow this pattern when adding tool-specific configuration.

### FZF Integration

Several functions use fzf for fuzzy finding:
- `fcd` - Fuzzy directory navigation
- `fbr` - Fuzzy git branch selection (defined in conditionals)
- `fco` - Fuzzy git commit selection
- `fshow` - Git commit browser

## Git Configuration

**Key git settings:**
- Default editor: VS Code (`code --wait`)
- Default branch: `main`
- Credential helper: GitHub CLI (`gh auth git-credential`)
- GPG signing: Disabled by default
- Difftool: VS Code

**Useful git aliases:**
- `git lg` - Pretty log with graph
- `git conflicts` - Show files with merge conflicts

## GPG Commit Signing

**Team Policy:** GPG signing is strongly encouraged for commit verification.

### Quick Setup

```bash
# 1. Generate key
gpg --full-generate-key

# 2. Configure git (in ~/.gitconfig.local)
[user]
    signingkey = YOUR_KEY_ID
[commit]
    gpgsign = true

# 3. Prime cache once per session
gpg-prime
```

### Available Utilities

- **gpg-prime** (alias for gpg-prime-cache) - Prime GPG cache for automatic signing
- **git-check-gpg-cache** - Check if cache is primed (used by pre-commit hook)
- **install-gpg-hooks** - Install hooks in existing repos (usually not needed)

All scripts located in `/scripts/` and symlinked to `~/.local/bin/`.

### How It Works

1. **Shell reminder** - Shows once per session if cache not primed
2. **Pre-commit hook** - Blocks commits if cache not primed (prevents hanging)
3. **gpg-prime** - Cache passphrase for 8-24 hours
4. **Automatic signing** - Commits signed without prompts

### Graceful Degradation

- If GPG not configured, commits work normally
- To bypass signing: `git commit --no-gpg-sign`
- Scripts fail gracefully with helpful messages
- Pre-commit hook allows commit if check script missing

### Documentation

- **Team quick-start**: [examples/gpg-setup-guide.md](examples/gpg-setup-guide.md)
- **Technical reference**: [docs/GPG_SIGNING_SETUP.md](docs/GPG_SIGNING_SETUP.md)
- **Git workflows**: [examples/git-workflows.md](examples/git-workflows.md)

### Troubleshooting

**"GPG failed to sign the data":**
```bash
gpg-prime  # Re-prime cache
```

**Cache expired during work:**
```bash
gpg-prime  # Run again
```

**Want to disable temporarily:**
```bash
git commit --no-gpg-sign -m "Message"
```

See full troubleshooting guide in [examples/gpg-setup-guide.md](examples/gpg-setup-guide.md).

## GitHub CLI Aliases

The repository includes 35+ `gh` aliases in `gh/config.yml` for PR and workflow management:

**Most used:**
- `gh mypr` - Your open PRs
- `gh prs` - All open non-draft PRs
- `gh review` - PRs where you're requested as reviewer
- `gh prmerge` - Squash merge and delete branch
- `gh runs` - Recent workflow runs for current branch

## Common Tasks

**Update oh-my-zsh plugins:**
```bash
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
```

**Reload zsh config:**
```bash
source ~/.zshrc
# or use alias
zshreload
```

**Edit machine-specific config:**
```bash
vim ~/.zshrc.local  # or: localrc
chmod 600 ~/.zshrc.local
```

**View PATH entries:**
```bash
path  # alias for: echo $PATH | tr ":" "\n"
```

**Copy file contents to clipboard:**
```bash
# Smart clipboard - auto-detects SSH and uses appropriate method
copyfile filename           # Uses OSC 52 over SSH, xclip/pbcopy locally
catcopy filename            # View with bat + copy to clipboard

# Direct OSC 52 usage (works over SSH!)
osc52 "some text"           # Copy text directly
echo "text" | osc52         # Copy from pipe
cat file.txt | osc52        # Copy file via pipe

# Alternative methods
\cat filename               # Use original cat to view/copy manually
bat --plain filename        # Plain view without formatting
catp filename               # Bat with plain style (no line numbers)
```

**Note:** OSC 52 copies to your **local** clipboard even when SSH'd into a remote machine. Requires a modern terminal (iTerm2, tmux, Windows Terminal, WezTerm, etc.).

**Verify tool installation status:**
```bash
./scripts/verify-tools.sh
# Shows which tools are installed and which are missing
```

## Workflow Examples

Comprehensive workflow guides are available in the `examples/` directory:

### Git Workflows (`examples/git-workflows.md`)

Step-by-step guides for common Git operations:
- **Feature Branch Development** - Complete workflow from branch creation to PR
- **Merge Conflict Resolution** - Handling conflicts when pulling or merging
- **Pull Request Review** - Reviewing and approving team PRs locally
- **Quick WIP Commits** - Temporary commits with `gwip`/`gunwip`
- **Branch Cleanup** - Removing old and merged branches
- **Advanced Operations** - Interactive rebase, cherry-pick, stash

Quick examples:
```bash
# Create feature branch and PR
gcb feature/my-feature && gaa && gcam "feat: My feature" && gp && gh pr create --web

# Review PR locally
gh review | head -5  # See PRs needing review
gh co 123 && gd && gh approve && gh prmerge

# WIP workflow
gwip  # Save work temporarily
# ... switch branches ...
gunwip  # Restore work as uncommitted changes
```

### Docker Workflows (`examples/docker-workflows.md`)

Practical Docker and Docker Compose workflows:
- **Start and Monitor Services** - Using docker-compose for local development
- **Container Debugging** - Accessing shells, viewing logs, inspecting state
- **Image Management** - Building, pushing, and cleaning up images
- **Cleanup Workflows** - Safe and aggressive cleanup strategies
- **Networking and Volumes** - Managing networks and persistent data
- **Troubleshooting** - Common issues and solutions

Quick examples:
```bash
# Start services and check logs
dcup && dps && dclogs

# Debug container
dex myapp bash

# Cleanup workflow
dstop && drm && dclean
```

### FZF Integration Recipes (`examples/fzf-recipes.md`)

Interactive fuzzy finding workflows:
- **Built-in Keybindings** - Ctrl+T (files), Ctrl+R (history), Alt+C (directories)
- **Custom Functions** - `fcd`, `fbr`, `fco`, `fshow`
- **Process Management** - Kill processes interactively
- **File Operations** - Open files, copy paths, bulk operations
- **Git Integration** - Interactive staging, commit selection, cherry-picking
- **Docker Integration** - Select containers for exec, logs, stop

Quick examples:
```bash
# Fuzzy file search with preview
Ctrl+T  # then select file

# Fuzzy git branch checkout
fbr

# Browse git history with preview
fshow

# Kill process interactively
kill -9 $(ps aux | fzf | awk '{print $2}')
```

### Tool Verification Script

Check which tools are installed:
```bash
./scripts/verify-tools.sh
```

This script shows:
- Required tools (zsh, git) with versions
- Recommended tools (fzf, gh) installation status
- Modern CLI replacements (bat, eza, fd, rg, htop, delta)
- Version manager (mise)
- Optional tools (direnv, autojump, poetry, docker)
- Oh-My-Zsh plugins (zsh-autosuggestions, zsh-syntax-highlighting)

## Troubleshooting

### Slow zsh startup
- Profile with: `PS4='+ %D{%s.%.} %N:%i> ' && set -x && source ~/.zshrc && set +x`
- Profile performance: `time zsh -i -c exit`
- Disable slow plugins in `~/.zshrc.local`: `plugins=(${plugins:#poetry})`
- Common culprits: mise activation issues, poetry completions
- Note: mise is very fast (~5-10ms), much faster than the old nvm/pyenv setup
- If still using nvm/pyenv, see [docs/MIGRATION.md](docs/MIGRATION.md) for migration instructions

### Function not found
- Ensure `zsh/zshrc.functions` is being sourced
- Check symlink: `ls -la ~/.zshrc`
- Re-run: `./install`
- Verify no syntax errors: `zsh -n ~/.zshrc`

### Tool not loading
- Check if tool is installed: `command -v toolname`
- Review `zsh/zshrc.conditionals` for conditional logic
- Reload config: `source ~/.zshrc` or `zshreload`

### Command not found after adding tool
- Reload zsh configuration: `source ~/.zshrc` or `zshreload`
- Verify tool is actually installed: `command -v toolname`
- Check which configuration file should load it (see Configuration Loading Order above)
- Ensure the tool's binary is in PATH: `echo $PATH | tr ":" "\n"`

### Unexpected command behavior
- Check if command has been aliased: `alias commandname`
- See what actually runs: `type commandname` or `which commandname`
- Use backslash to bypass alias: `\grep` instead of `grep`
- Use `command` prefix to skip aliases: `command grep` instead of `grep`
- Check zshrc.conditionals for tool replacement overrides

### Alias conflicts
- List all current aliases: `alias`
- List specific alias: `alias aliasname`
- Find where alias is defined: `grep -r "alias aliasname=" ~/.dotfiles/`
- Override in `~/.zshrc.local` if needed: `unalias aliasname` then define your own
- Temporarily disable: `\commandname` or `command commandname`

### htop not found when running 'top'
- This was a bug fixed in recent updates
- Manually check if htop is installed: `command -v htop`
- Install htop: `apt install htop` or `brew install htop`
- Verify fix: The htop alias should only exist in `zshrc.conditionals:64-66` (conditional)
- If still broken: Check that line 119 in `zshrc.aliases` does NOT have `alias top='htop'`

### Git authentication issues
- GitHub CLI handles credentials: `gh auth status`
- Re-authenticate if needed: `gh auth login`
- Credential helper configured in `gitconfig:11-16`

### fzf functions not working (fbr, fco, fshow)
- Check if fzf is installed: `command -v fzf`
- Install fzf: `apt install fzf` or `brew install fzf`
- Verify functions are defined: `type fbr`
- These functions are defined in `zshrc.conditionals:107-132`

### PATH not including custom directories
- Use `pathadd` function for safety: `pathadd "${HOME}/mybin"`
- Add to `~/.zshrc.local` for machine-specific paths
- View current PATH: `path` alias or `echo $PATH | tr ":" "\n"`
- Check order: Earlier entries take precedence

### Oh-My-Zsh plugin not loading
- Verify plugin exists: `ls ~/.oh-my-zsh/custom/plugins/`
- For third-party plugins, ensure they're installed (e.g., zsh-autosuggestions)
- Check plugin name matches directory name exactly
- Reload after adding: `source ~/.zshrc`

### Syntax errors or zsh won't start
- Check syntax without running: `zsh -n ~/.zshrc`
- Look for common issues: unmatched quotes, unclosed blocks
- Test individual modules:
  ```bash
  zsh -n ~/.dotfiles/zsh/zshrc.aliases
  zsh -n ~/.dotfiles/zsh/zshrc.functions
  zsh -n ~/.dotfiles/zsh/zshrc.conditionals
  ```
- Temporarily disable modules by commenting out source lines in main `zshrc`
