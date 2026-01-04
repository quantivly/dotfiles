# Migration Guide: Transitioning to mise

This guide provides step-by-step instructions for migrating from legacy version managers (nvm, pyenv) and manual CLI tool installations to mise, the modern polyglot version manager used in this dotfiles configuration.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Why Migrate to mise?](#why-migrate-to-mise)
- [Migration Scenarios](#migration-scenarios)
  - [Scenario 1: From pyenv to mise](#scenario-1-from-pyenv-to-mise)
  - [Scenario 2: From nvm to mise](#scenario-2-from-nvm-to-mise)
  - [Scenario 3: From Manual CLI Tools to mise](#scenario-3-from-manual-cli-tools-to-mise)
  - [Scenario 4: Fresh Installation](#scenario-4-fresh-installation)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Rollback Procedures](#rollback-procedures)
- [FAQ](#faq)

---

## Prerequisites

Before migrating, ensure you have:

1. **Backup your shell configuration:**
   ```bash
   cp ~/.zshrc ~/.zshrc.backup
   cp ~/.zshrc.local ~/.zshrc.local.backup 2>/dev/null || true
   cp ~/.bashrc ~/.bashrc.backup 2>/dev/null || true
   ```

2. **Document your current tool versions:**
   ```bash
   # For pyenv users
   pyenv versions > ~/migration-backup-pyenv.txt 2>/dev/null || true

   # For nvm users
   nvm list > ~/migration-backup-nvm.txt 2>/dev/null || true

   # For all users - document installed CLI tools
   command -v bat && bat --version >> ~/migration-backup-tools.txt
   command -v fd && fd --version >> ~/migration-backup-tools.txt
   command -v eza && eza --version >> ~/migration-backup-tools.txt
   # ... etc
   ```

3. **Install mise** (if not already installed):
   ```bash
   curl https://mise.run | sh
   # or
   ./scripts/install-modern-tools.sh
   ```

4. **Have the dotfiles installed:**
   ```bash
   cd ~/.dotfiles && ./install
   ```

---

## Why Migrate to mise?

**Benefits over legacy version managers:**

- **Unified Management**: One tool for Python, Node, Ruby, Go, and 100+ languages
- **Fast**: ~5-10ms activation (vs 200-500ms for pyenv/nvm)
- **No Lazy Loading Needed**: Fast enough to load synchronously
- **CLI Tools Too**: Manages both runtimes and CLI tools (bat, fd, eza, etc.)
- **Legacy Compatible**: Reads `.nvmrc`, `.python-version`, `.tool-versions` files
- **Better UX**: Consistent commands across all languages

**Performance Comparison:**
```
nvm initialization:  ~200-500ms
pyenv initialization: ~150-300ms
mise initialization:  ~5-10ms    ✓
```

---

## Migration Scenarios

### Scenario 1: From pyenv to mise

**Current State Check:**
```bash
# Check what Python versions you have
pyenv versions

# Check your global Python version
pyenv global

# Check if pyenv is in your shell config
grep -n "pyenv" ~/.zshrc ~/.zshrc.local ~/.bashrc 2>/dev/null
```

**Step-by-Step Migration:**

1. **List your current Python versions:**
   ```bash
   pyenv versions
   # Example output:
   #   3.9.18
   #   3.10.13
   # * 3.12.0 (set by /home/user/.python-version)
   ```

2. **Install equivalent versions with mise:**
   ```bash
   # Install the versions you need
   mise use -g python@3.12.0
   mise use -g python@3.10.13
   mise use -g python@3.9.18

   # Verify installation
   mise ls python
   ```

3. **Set your global Python version:**
   ```bash
   # Set the version that was your pyenv global
   mise use -g python@3.12.0

   # Verify
   python --version  # Should show: Python 3.12.0
   ```

4. **Migrate project-specific Python versions:**
   ```bash
   # For each project with .python-version file
   cd ~/my-project

   # Option A: Let mise read .python-version (recommended)
   mise install  # Automatically reads .python-version

   # Option B: Create .mise.toml for explicit control
   cat > .mise.toml << 'EOF'
   [tools]
   python = "3.11.5"
   EOF
   mise install
   ```

5. **Clean up pyenv from shell configuration:**
   ```bash
   # Edit ~/.zshrc.local (or ~/.bashrc)
   vim ~/.zshrc.local

   # Remove or comment out these lines:
   # export PYENV_ROOT="$HOME/.pyenv"
   # export PATH="$PYENV_ROOT/bin:$PATH"
   # eval "$(pyenv init --path)"
   # eval "$(pyenv init -)"
   # eval "$(pyenv virtualenv-init -)"
   ```

6. **Remove pyenv (after verification - see below):**
   ```bash
   # WAIT! Verify everything works first (see Verification section)
   # Then when ready:
   rm -rf ~/.pyenv
   ```

7. **Reload your shell:**
   ```bash
   source ~/.zshrc
   # or
   exec zsh
   ```

**Migration Checklist:**
- [ ] Listed current pyenv versions
- [ ] Installed equivalent mise versions
- [ ] Set global Python version
- [ ] Migrated project-specific versions
- [ ] Cleaned up shell configuration
- [ ] Verified Python works (see Verification)
- [ ] Removed pyenv directory

---

### Scenario 2: From nvm to mise

**Current State Check:**
```bash
# Check what Node versions you have
nvm list

# Check your current/default version
nvm current

# Check if nvm is in your shell config
grep -n "NVM" ~/.zshrc ~/.zshrc.local ~/.bashrc 2>/dev/null
```

**Step-by-Step Migration:**

1. **List your current Node versions:**
   ```bash
   nvm list
   # Example output:
   #        v18.18.0
   #        v20.10.0
   # ->     v20.11.0
   # default -> 20 (-> v20.11.0)
   ```

2. **Install equivalent versions with mise:**
   ```bash
   # Install the versions you need
   mise use -g node@20.11.0
   mise use -g node@20.10.0
   mise use -g node@18.18.0

   # Or use shortcuts
   mise use -g node@20    # Latest 20.x
   mise use -g node@lts   # Latest LTS

   # Verify installation
   mise ls node
   ```

3. **Set your global Node version:**
   ```bash
   # Set the version that was your nvm default
   mise use -g node@20.11.0

   # Verify
   node --version  # Should show: v20.11.0
   npm --version   # Should work
   ```

4. **Migrate project-specific Node versions:**
   ```bash
   # For each project with .nvmrc file
   cd ~/my-project

   # Option A: Let mise read .nvmrc (recommended)
   mise install  # Automatically reads .nvmrc

   # Option B: Create .mise.toml for explicit control
   cat > .mise.toml << 'EOF'
   [tools]
   node = "20.10.0"
   EOF
   mise install
   ```

5. **Clean up nvm from shell configuration:**
   ```bash
   # Edit ~/.zshrc.local (or ~/.bashrc)
   vim ~/.zshrc.local

   # Remove or comment out these lines:
   # export NVM_DIR="$HOME/.nvm"
   # [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
   # [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
   ```

6. **Remove nvm (after verification - see below):**
   ```bash
   # WAIT! Verify everything works first (see Verification section)
   # Then when ready:
   rm -rf ~/.nvm
   ```

7. **Reload your shell:**
   ```bash
   source ~/.zshrc
   # or
   exec zsh
   ```

**Migration Checklist:**
- [ ] Listed current nvm versions
- [ ] Installed equivalent mise versions
- [ ] Set global Node version
- [ ] Migrated project-specific versions
- [ ] Cleaned up shell configuration
- [ ] Verified Node/npm works (see Verification)
- [ ] Removed nvm directory

---

### Scenario 3: From Manual CLI Tools to mise

If you've been installing modern CLI tools manually (via `apt`, `brew`, `cargo`, or downloading releases), you can migrate to mise for unified management.

**Current State Check:**
```bash
# Check what tools are installed and how
./scripts/verify-tools.sh

# Or manually check:
command -v bat && which bat
command -v fd && which fd
command -v eza && which eza
command -v lazygit && which lazygit
```

**Step-by-Step Migration:**

1. **Document current tool versions:**
   ```bash
   # Create a backup record
   echo "=== Current Tool Versions ===" > ~/migration-backup-tools.txt
   command -v bat && bat --version >> ~/migration-backup-tools.txt
   command -v fd && fd --version >> ~/migration-backup-tools.txt
   command -v eza && eza --version >> ~/migration-backup-tools.txt
   command -v delta && delta --version >> ~/migration-backup-tools.txt
   command -v lazygit && lazygit --version >> ~/migration-backup-tools.txt
   command -v just && just --version >> ~/migration-backup-tools.txt
   # ... etc
   ```

2. **Install tools via mise (from dotfiles configuration):**
   ```bash
   # The dotfiles .mise.toml already defines all tools
   cd ~/.dotfiles

   # This will be done automatically by ./install, but you can do it manually:
   cp .mise.toml ~/.config/mise/config.toml

   # Install all defined tools
   mise install

   # Verify
   mise ls
   ```

3. **Update your PATH (handled by dotfiles):**
   ```bash
   # The dotfiles zshrc.conditionals already handles mise activation
   # Just reload your shell
   source ~/.zshrc
   ```

4. **Verify tools are now provided by mise:**
   ```bash
   # Check that tools are coming from mise
   which bat    # Should show: ~/.local/share/mise/installs/bat/...
   which fd     # Should show: ~/.local/share/mise/installs/fd/...
   which eza    # Should show: ~/.local/share/mise/installs/eza/...

   # Verify versions match or are newer
   bat --version
   fd --version
   eza --version
   ```

5. **Remove manually installed versions (optional):**

   **⚠️ WARNING:** Only do this after verification!

   ```bash
   # For apt-installed tools (Ubuntu/Debian)
   sudo apt remove bat fd-find exa ripgrep  # etc

   # For brew-installed tools (macOS)
   brew uninstall bat fd eza ripgrep  # etc

   # For cargo-installed tools
   cargo uninstall bat fd-find eza  # etc

   # For manually downloaded binaries
   rm ~/.local/bin/bat ~/.local/bin/fd  # etc (if you installed them there)
   ```

6. **Clean up any tool-specific configuration in ~/.zshrc.local:**
   ```bash
   vim ~/.zshrc.local

   # Remove any manual PATH additions for these tools, like:
   # export PATH="$HOME/.cargo/bin:$PATH"  # (if only used for these tools)
   # export PATH="$HOME/bin:$PATH"  # (if only used for these tools)
   ```

**Migration Checklist:**
- [ ] Documented current tool versions
- [ ] Installed tools via mise
- [ ] Verified tools work from mise
- [ ] Removed manual installations (optional)
- [ ] Cleaned up shell configuration
- [ ] Verified all tools work (see Verification)

---

### Scenario 4: Fresh Installation

If you're setting up on a new machine or don't have nvm/pyenv installed:

**Quick Setup:**

```bash
# 1. Install mise
curl https://mise.run | sh

# 2. Install dotfiles
cd ~/.dotfiles
./install

# 3. Install runtimes (Python, Node, etc.)
mise use -g python@3.12
mise use -g node@lts

# 4. All CLI tools are automatically installed by the dotfiles
mise ls  # Verify everything is installed

# 5. Reload shell
source ~/.zshrc
```

**That's it!** The dotfiles handle all configuration automatically.

---

## Verification

After migration, verify everything works correctly:

### 1. Check mise is Active

```bash
# Verify mise is loaded
command -v mise
mise --version

# Should show mise path and version
```

### 2. Verify Runtimes (Python/Node)

```bash
# Python verification
python --version
pip --version
which python  # Should show mise path
python -c "import sys; print(sys.executable)"

# Node verification (if using)
node --version
npm --version
which node  # Should show mise path

# List all installed runtimes
mise ls
```

### 3. Verify CLI Tools

```bash
# Check tools are from mise
which bat     # Should show: ~/.local/share/mise/installs/bat/...
which fd      # Should show: ~/.local/share/mise/installs/fd/...
which eza     # Should show: ~/.local/share/mise/installs/eza/...

# Verify tools work
bat --version
fd --version
eza --version
delta --version
lazygit --version

# Run comprehensive check
./scripts/verify-tools.sh
```

### 4. Test Project-Specific Versions

```bash
# Navigate to a project with .nvmrc or .python-version
cd ~/my-project

# mise should automatically switch versions
mise current

# Verify the version matches
node --version  # (for Node projects)
python --version  # (for Python projects)
```

### 5. Test Development Workflow

```bash
# Create a test project
mkdir -p /tmp/test-mise-migration
cd /tmp/test-mise-migration

# Python test
echo "3.11" > .python-version
mise install
python --version  # Should show 3.11.x

# Node test
echo "18" > .nvmrc
mise install
node --version  # Should show v18.x.x

# Cleanup
cd ~ && rm -rf /tmp/test-mise-migration
```

### 6. Check Shell Performance

```bash
# Shell should start fast (<100ms)
time zsh -i -c exit

# Should be much faster than with nvm/pyenv
```

### Verification Checklist:
- [ ] mise command is available
- [ ] Python version is correct
- [ ] Node version is correct (if applicable)
- [ ] CLI tools work from mise paths
- [ ] Project-specific versions work (.nvmrc, .python-version)
- [ ] Shell startup is fast
- [ ] All workflows function normally

---

## Troubleshooting

### Issue: Command not found after migration

**Symptoms:**
```bash
$ python
command not found: python
```

**Solutions:**

1. **Verify mise is activated:**
   ```bash
   # Check if mise is in PATH
   echo $PATH | grep mise

   # Should show: .../.local/share/mise/shims:...
   ```

2. **Reload shell configuration:**
   ```bash
   source ~/.zshrc
   # or
   exec zsh
   ```

3. **Check mise installed the tool:**
   ```bash
   mise ls
   # If tool is missing:
   mise install python@3.12
   ```

4. **Verify mise activation in shell:**
   ```bash
   # Check zshrc.conditionals has mise activation
   grep "mise activate" ~/.dotfiles/zsh/zshrc.conditionals

   # Should show:
   # eval "$(mise activate zsh)"
   ```

---

### Issue: Wrong version being used

**Symptoms:**
```bash
$ python --version
Python 3.8.10  # But you installed 3.12!
```

**Solutions:**

1. **Check which Python is being used:**
   ```bash
   which python
   # If it's not from mise (should be ~/.local/share/mise/...):
   ```

2. **Check your PATH order:**
   ```bash
   echo $PATH | tr ':' '\n' | head -5
   # mise shims should be FIRST
   ```

3. **Check for conflicting installations:**
   ```bash
   # Find all Python installations
   which -a python
   which -a python3

   # If system Python is taking precedence, check PATH
   ```

4. **Set the global version explicitly:**
   ```bash
   mise use -g python@3.12
   mise current
   ```

5. **Check for project-specific version files:**
   ```bash
   # Look for .python-version or .tool-versions
   ls -la .python-version .tool-versions .mise.toml

   # mise respects these files and may override global
   ```

---

### Issue: Old version manager still loading

**Symptoms:**
```bash
$ echo $PATH
/home/user/.nvm/versions/node/v20.0.0/bin:...
```

**Solutions:**

1. **Check shell configuration for old exports:**
   ```bash
   grep -n "NVM\|PYENV" ~/.zshrc ~/.zshrc.local ~/.bashrc ~/.profile
   ```

2. **Remove old configuration:**
   ```bash
   vim ~/.zshrc.local
   # Remove nvm/pyenv lines
   ```

3. **Check for multiple shell config files:**
   ```bash
   ls -la ~/.zshrc* ~/.bashrc* ~/.profile*
   # Old configs might be sourced
   ```

4. **Reload shell after cleanup:**
   ```bash
   exec zsh
   ```

---

### Issue: Slow shell startup after migration

**Symptoms:**
```bash
$ time zsh -i -c exit
0.35s  # Should be <0.10s with mise
```

**Solutions:**

1. **Check if old version managers are still loading:**
   ```bash
   # Profile shell startup
   PS4='+ %D{%s.%.} %N:%i> ' zsh -i -x -c exit 2>&1 | grep -E "nvm|pyenv"
   ```

2. **Remove lazy-loading wrappers:**
   ```bash
   # mise doesn't need lazy loading - remove these patterns:
   vim ~/.zshrc.local
   # Remove:
   # [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
   # eval "$(pyenv init --path)"
   ```

3. **Verify mise activation is fast:**
   ```bash
   time mise activate zsh > /dev/null
   # Should be <10ms
   ```

---

### Issue: Project-specific version not switching

**Symptoms:**
```bash
$ cd my-project
$ cat .nvmrc
18
$ node --version
v20.11.0  # Wrong version!
```

**Solutions:**

1. **Verify mise can read the version file:**
   ```bash
   cd my-project
   mise ls
   mise current node
   ```

2. **Check legacy version file support is enabled:**
   ```bash
   # Should be enabled in .mise.toml
   grep "legacy_version_file" ~/.config/mise/config.toml

   # Should show:
   # legacy_version_file = true
   ```

3. **Install the specific version:**
   ```bash
   mise install  # Reads .nvmrc/.python-version
   mise current  # Verify version is now active
   ```

4. **Try explicit .mise.toml instead:**
   ```bash
   cat > .mise.toml << 'EOF'
   [tools]
   node = "18"
   EOF
   mise install
   ```

---

### Issue: Tools not found from mise

**Symptoms:**
```bash
$ bat
command not found: bat
```

**Solutions:**

1. **Verify tool is installed:**
   ```bash
   mise ls | grep bat
   # If missing:
   mise install bat
   ```

2. **Check mise shims are in PATH:**
   ```bash
   echo $PATH | grep mise
   # Should show mise shims directory
   ```

3. **Try running via mise directly:**
   ```bash
   mise exec bat -- --version
   # If this works, PATH issue
   ```

4. **Reinstall tool:**
   ```bash
   mise uninstall bat
   mise install bat
   ```

5. **Check for conflicts:**
   ```bash
   which -a bat
   # Multiple installations might conflict
   ```

---

### Issue: pip packages not found after migration

**Symptoms:**
```bash
$ poetry
command not found: poetry
```

**Solutions:**

1. **Check if package was installed in old Python:**
   ```bash
   # List packages in old Python (if not removed yet)
   ~/.pyenv/versions/3.12.0/bin/pip list | grep poetry
   ```

2. **Reinstall packages in mise Python:**
   ```bash
   pip install poetry
   # or install all common packages:
   pip install poetry black ruff mypy pytest
   ```

3. **Use mise default packages file:**
   ```bash
   # Create default packages file
   cat > ~/.default-python-packages << 'EOF'
   poetry
   black
   ruff
   mypy
   pytest
   ipython
   EOF

   # mise will auto-install these in future Python versions
   ```

4. **Verify pip is from mise:**
   ```bash
   which pip
   # Should show: ~/.local/share/mise/installs/python/...
   ```

---

## Rollback Procedures

If you need to rollback the migration:

### Rollback from mise to pyenv

1. **Restore shell configuration:**
   ```bash
   # Restore backup
   cp ~/.zshrc.local.backup ~/.zshrc.local

   # Or manually re-add pyenv:
   cat >> ~/.zshrc.local << 'EOF'
   export PYENV_ROOT="$HOME/.pyenv"
   export PATH="$PYENV_ROOT/bin:$PATH"
   eval "$(pyenv init --path)"
   eval "$(pyenv init -)"
   EOF
   ```

2. **Reinstall pyenv (if removed):**
   ```bash
   curl https://pyenv.run | bash
   ```

3. **Reinstall Python versions:**
   ```bash
   # From your backup notes
   cat ~/migration-backup-pyenv.txt

   # Reinstall versions
   pyenv install 3.12.0
   pyenv install 3.11.5
   pyenv global 3.12.0
   ```

4. **Reload shell:**
   ```bash
   source ~/.zshrc.local
   ```

### Rollback from mise to nvm

1. **Restore shell configuration:**
   ```bash
   # Restore backup
   cp ~/.zshrc.local.backup ~/.zshrc.local

   # Or manually re-add nvm:
   cat >> ~/.zshrc.local << 'EOF'
   export NVM_DIR="$HOME/.nvm"
   [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
   EOF
   ```

2. **Reinstall nvm (if removed):**
   ```bash
   curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
   ```

3. **Reinstall Node versions:**
   ```bash
   # From your backup notes
   cat ~/migration-backup-nvm.txt

   # Reinstall versions
   nvm install 20.11.0
   nvm install 18.18.0
   nvm alias default 20.11.0
   ```

4. **Reload shell:**
   ```bash
   source ~/.zshrc.local
   ```

### Disable mise temporarily

If you just want to test without mise:

```bash
# Edit ~/.zshrc.local
cat >> ~/.zshrc.local << 'EOF'
# Temporarily disable mise
unset MISE_SHELL
export PATH="${PATH//\/mise\/[^:]*:/}"  # Remove mise from PATH
EOF

# Reload
source ~/.zshrc.local
```

---

## FAQ

### Q: Can I use both mise and nvm/pyenv?

**A:** Not recommended. They conflict in PATH and can cause version confusion. Choose one. mise is preferred for its performance and unified management.

### Q: Will mise work with my existing .nvmrc files?

**A:** Yes! mise reads `.nvmrc`, `.python-version`, and `.tool-versions` files automatically when `legacy_version_file = true` in your config (enabled by default in dotfiles).

### Q: Do I need to migrate all tools at once?

**A:** No. You can migrate incrementally:
1. Start with runtimes (Python/Node)
2. Keep manual CLI tools temporarily
3. Migrate CLI tools when comfortable

### Q: What if I need a tool version not in the dotfiles .mise.toml?

**A:** Just install it:
```bash
mise use -g python@3.9  # Global
mise use python@3.9     # Project-local
```

### Q: Can I use different tool versions per project?

**A:** Yes! Create `.mise.toml` in your project:
```toml
[tools]
python = "3.11.5"
node = "18.18.0"
```

### Q: How do I update tool versions managed by mise?

**A:** See the dotfiles `.mise.toml` file for update procedures:
```bash
# Check for updates
mise outdated

# Upgrade specific tool
mise upgrade python

# Or edit ~/.config/mise/config.toml and run:
mise install
```

For detailed update procedures, see `docs/TOOL_VERSION_UPDATES.md` (coming in DO-152).

### Q: What if I encounter an issue not covered here?

**A:**
1. Check mise documentation: https://mise.jdx.dev/
2. Run diagnostics: `mise doctor`
3. Check issues: https://github.com/jdx/mise/issues
4. Ask in team chat or create a Linear issue

### Q: Can I keep using poetry/pipenv virtual environments?

**A:** Yes! mise manages the Python version, poetry/pipenv manage dependencies. They work together:
```bash
cd my-project
mise use python@3.11     # Sets Python version
poetry install           # Creates venv with that Python
```

### Q: Is there a performance difference between installation methods?

**A:** Yes:
- `mise install python` → Uses prebuilt binaries (fast, 1-2 minutes)
- `pyenv install python` → Compiles from source (slow, 5-20 minutes)

mise is significantly faster for both installation and activation.

### Q: What about Windows/WSL?

**A:** mise works great in WSL2. On Windows without WSL, consider using alternatives or waiting for native Windows support.

---

## Additional Resources

- **mise Documentation**: https://mise.jdx.dev/
- **mise GitHub**: https://github.com/jdx/mise
- **Dotfiles CLAUDE.md**: See "Version Manager" and "Managing CLI Tools" sections
- **Tool Verification**: Run `./scripts/verify-tools.sh` to check installation status
- **Tool Updates**: See `docs/TOOL_VERSION_UPDATES.md` (coming in DO-152)

---

**Migration Status Tracker:**

Use this checklist to track your migration progress:

- [ ] Created backups of shell configuration
- [ ] Documented current tool versions
- [ ] Installed mise
- [ ] Migrated Python versions (if applicable)
- [ ] Migrated Node versions (if applicable)
- [ ] Migrated CLI tools to mise
- [ ] Cleaned up old version manager configuration
- [ ] Removed old version manager directories (after verification)
- [ ] Verified all tools work correctly
- [ ] Tested project-specific version switching
- [ ] Confirmed shell startup performance
- [ ] Updated team/personal documentation

---

**Last Updated:** 2026-01-04
**Related Issues:** DO-151, DO-112, DO-147
**Maintained by:** DevOps Team
