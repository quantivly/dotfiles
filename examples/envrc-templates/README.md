# Self-Contained .envrc Templates

Self-contained Python environment templates with **graceful dependency checking** via quanticli.

## Why Use These Templates?

**Benefits:**
- ✅ **No dotfiles coupling** - Works independently
- ✅ **Graceful degradation** - Functions without quanticli installed
- ✅ **Simple and maintainable** - Clean, minimal .envrc files
- ✅ **Portable** - Copy .envrc to new machine, it just works
- ✅ **Single source of truth** - Dependency logic in quanticli

**When to use:**
- All new Python projects
- External/open-source projects
- Critical infrastructure projects
- Any project needing automatic dependency checking

## Available Templates

### 1. `minimal.envrc` - General-Purpose Template

**Supports all Python project types:**
- Poetry projects (with `poetry.lock`)
- pip projects (with `requirements.txt`)
- Django-style projects (with `requirements/` directory)
- PEP 621 projects (with `pyproject.toml`)
- Automatic dependency checking via quanticli

**Use for:** All Python projects (quanticli, auto-conf, quantivly-sdk, box, ptbi, healthcheck, auto-test, ris, sre-core, sre-sdk, hub subdirectories)

**How it works:**
- `quanticli doctor deps` automatically detects your project's dependency pattern
- No configuration needed - just copy and use
- Graceful degradation if quanticli not installed

### 2. `hub-root.envrc` - Root Directory Template

**Differences from minimal:**
- Omits `POETRY_ACTIVE` environment variable (root directories don't use Poetry)
- Same dependency checking via quanticli (optional for ad-hoc scripts)

**Use for:** Root-level directories with ad-hoc scripts (hub root)

## Usage

### Quick Start

```bash
# 1. Choose a template
cp ~/.dotfiles/examples/envrc-templates/minimal.envrc /path/to/project/.envrc

# 2. Create .mise.toml with Python version
echo '[tools]
python = "3.11"' > /path/to/project/.mise.toml

# 3. Trust direnv and install Python
cd /path/to/project
direnv allow
mise install

# 4. Install dependencies
poetry install  # or: pip install -r requirements.txt
```

### Complete Setup

```bash
cd /path/to/project

# 1. Copy template
cp ~/.dotfiles/examples/envrc-templates/minimal.envrc .envrc

# 2. Create .mise.toml
cat > .mise.toml << 'EOF'
[tools]
python = "3.11"
EOF

# 3. Create VSCode settings (optional)
mkdir -p .vscode
cp ~/.dotfiles/examples/vscode/settings.json .vscode/
# See ~/.dotfiles/examples/vscode/README.md for details

# 4. Trust and activate
direnv allow
mise install

# 5. Install dependencies
poetry install  # or: pip install -r requirements.txt
```

## Dependency Checking

Templates use `quanticli doctor deps --quiet` for dependency checking:

```bash
cd project
# If quanticli installed and dependencies outdated:
⚠️  Dependencies outdated. Run: poetry install

# If quanticli not installed:
# (silent - environment still works)
```

**How it works:**
- `.envrc` conditionally calls `quanticli doctor deps --quiet` if quanticli is available
- quanticli compares modification times of dependency files vs `.venv`
- Warnings appear automatically when you `cd` into the project
- Warnings disappear after you run the install command

**Manual checking:**
```bash
quanticli doctor deps              # Show detailed status
quanticli doctor deps -p ~/project # Check specific project
quanticli doctor deps --quiet      # Suppress output (for .envrc)
```

**What it checks:**
- Poetry: `poetry.lock` vs `.venv`
- pip: `requirements.txt` vs `.venv`
- Django-style: All `requirements/*.txt` vs `.venv`
- PEP 621: `pyproject.toml` vs `.venv` (non-Poetry)

## Benefits Over Previous Approaches

**Compared to shared helper:**
- ✅ No dotfiles coupling - projects are independent
- ✅ No cascading failures - bug in one check doesn't affect others
- ✅ Single implementation - update quanticli, all projects benefit
- ✅ Graceful degradation - works without quanticli

**Compared to inline checking:**
- ✅ DRY - logic in one place (quanticli)
- ✅ Cross-platform - no shell quirks
- ✅ Comprehensive - handles all dependency patterns
- ✅ Testable - quanticli has test suite

## Customization

Templates are designed to be copied and modified:

```bash
# Copy template
cp ~/.dotfiles/examples/envrc-templates/minimal.envrc project/.envrc

# Customize for your needs
vim project/.envrc

# Examples:
# - Add custom environment variables
# - Add project-specific setup steps
# - Change Python version in .mise.toml
# - Add additional checks
```

## Migration from Shared Helper

All 9 existing projects have been migrated from the old shared helper pattern to use quanticli:

**Before:**
```bash
source ~/.dotfiles/shell/python-env-helpers.sh
check_python_dependencies
```

**After:**
```bash
if command -v quanticli &>/dev/null; then
    quanticli doctor deps --quiet 2>/dev/null || true
fi
```

The old `~/.dotfiles/shell/python-env-helpers.sh` is deprecated and will be removed.

## Troubleshooting

### Environment not activating
```bash
direnv allow           # Trust .envrc
mise install           # Install Python version
direnv reload          # Force reload
```

### Wrong Python version
```bash
cat .mise.toml         # Check configured version
mise ls python         # List installed versions
mise install python@X.Y  # Install missing version
```

### VSCode using wrong interpreter
- Cmd+Shift+P → "Python: Select Interpreter"
- Choose `.venv/bin/python` from project
- Ensure `"python.terminal.activateEnvironment": false` in settings

### Dependency checking not working
```bash
# Check if quanticli is installed
command -v quanticli

# Test dependency check manually
quanticli doctor deps

# If not installed, install quanticli
# (environment still works without it)
```

## Further Reading

- **Implementation plan:** `~/.claude/plans/curried-herding-deer.md`
- **Python setup examples:** `~/.dotfiles/examples/python-project-setup.md`
- **CLAUDE.md documentation:** `~/.dotfiles/CLAUDE.md` (Python Environment Management section)
- **quanticli documentation:** Check quanticli README for `doctor deps` command

## Sources

Research and community patterns:
- [direnv Python Wiki](https://github.com/direnv/direnv/wiki/Python) - Community custom layouts
- [Mise + Direnv + Python](https://www.gbb.is/posts/2024-07-24-mise-direnv-and-python/) - Real-world integration
- [direnv Python Handbook](https://pydevtools.com/handbook/reference/direnv/) - Best practices

---

**Created:** 2026-01-13
**Updated:** 2026-01-13
**Purpose:** Provide independent Python environment templates with graceful dependency checking
**Implementation:** Uses quanticli doctor deps for centralized dependency validation
