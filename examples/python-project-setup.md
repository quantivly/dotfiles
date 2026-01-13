# Python Project Setup Examples

## Simple Dependency Checking with quanticli

All projects now use a **simple, single-location approach** with graceful degradation:

**.envrc pattern:**
- Conditionally calls `quanticli doctor deps --quiet` if quanticli is available
- No coupling to dotfiles - projects work independently
- Graceful degradation - environment activates even without quanticli
- Automatic dependency checking when you `cd` into a project

**What it checks:**
- Poetry projects: `poetry.lock` vs `.venv` modification time
- pip projects: `requirements.txt` vs `.venv`
- Django-style: All `requirements/*.txt` files
- PEP 621: `pyproject.toml` (non-Poetry)

**Templates:** Three ready-to-use templates available at `~/.dotfiles/examples/envrc-templates/`
- `minimal.envrc` - Poetry + requirements.txt
- `extended.envrc` - Plus requirements/ directory
- `hub-root.envrc` - No dependency checking

**See:** [envrc-templates/README.md](envrc-templates/README.md) for complete template guide

---

## Examples: All Project Types

The examples below show the standard pattern used by all projects.

### Poetry Project (e.g., quanticli, auto-conf)

### Files

**.mise.toml:**
```toml
[tools]
python = "3.10"
```

**.python-version:**
```
3.10
```

**.envrc:**
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

# Mark as Poetry project
[ -f poetry.lock ] && export POETRY_ACTIVE=1

# Check dependencies if quanticli is available
if command -v quanticli &>/dev/null; then
    quanticli doctor deps --quiet 2>/dev/null || true
fi
```

**pyproject.toml:**
```toml
[tool.poetry]
name = "my-project"
version = "0.1.0"

[tool.poetry.dependencies]
python = ">=3.9"

[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
```

**.vscode/settings.json:**
```bash
# Copy template from dotfiles
mkdir -p .vscode
cp ~/.dotfiles/examples/vscode/settings.json .vscode/
```

See [vscode/README.md](vscode/README.md) for details and customization options.

### Setup
```bash
direnv allow
mise trust
mise install
poetry install
```

### Verification
```bash
cd project-root
mise current           # Should show: python 3.10.x
echo $VIRTUAL_ENV      # Should show: /path/to/project/.venv
which python           # Should show: .venv/bin/python
python --version       # Should show: Python 3.10.x
```

## Project with scripts/ Directory (e.g., hub)

This pattern is for projects with a scripts/ directory that has its own dependencies.

### Files

**.mise.toml:**
```toml
[tools]
python = "3.13"
```

**.python-version:**
```
3.13
```

**.envrc:**
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

# Check dependencies if quanticli is available
if command -v quanticli &>/dev/null; then
    quanticli doctor deps --quiet 2>/dev/null || true
fi

# Also check scripts/requirements.txt (hub-specific)
if [ -f scripts/requirements.txt ] && [ -d .venv ]; then
    if [ scripts/requirements.txt -nt .venv ]; then
        echo "⚠️  Scripts dependencies outdated. Run: pip install -r scripts/requirements.txt"
    fi
fi
```

**scripts/requirements.txt:**
```
requests>=2.31.0
rich>=13.7.0
```

**.vscode/settings.json:**
```bash
# Copy template from dotfiles
mkdir -p .vscode
cp ~/.dotfiles/examples/vscode/settings.json .vscode/
```

See [vscode/README.md](vscode/README.md) for details and customization options.

### Setup
```bash
direnv allow
mise trust
mise install
pip install -r scripts/requirements.txt
```

### Usage
```bash
# Run scripts from project root
python scripts/my_script.py

# Scripts can import local modules
# e.g., from audit_logger import AuditLogger
```

### Verification
```bash
cd project-root
mise current           # Should show: python 3.13.x
echo $VIRTUAL_ENV      # Should show: /path/to/project/.venv
which python           # Should show: .venv/bin/python
python --version       # Should show: Python 3.13.x
```

## Plain Virtualenv Project (e.g., sre-core)

### Files

**.mise.toml:**
```toml
[tools]
python = "3.13"
```

**.python-version:**
```
3.13
```

**.envrc:**
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

# Check dependencies if quanticli is available
if command -v quanticli &>/dev/null; then
    quanticli doctor deps --quiet 2>/dev/null || true
fi
```

**.vscode/settings.json:**
```bash
# Copy template from dotfiles
mkdir -p .vscode
cp ~/.dotfiles/examples/vscode/settings.json .vscode/
```

See [vscode/README.md](vscode/README.md) for details and customization options.

### Setup
```bash
direnv allow
mise trust
mise install
pip install -r requirements.txt
```

### Verification
```bash
cd project-root
mise current           # Should show: python 3.13.x
echo $VIRTUAL_ENV      # Should show: /path/to/project/.venv
which python           # Should show: .venv/bin/python
python --version       # Should show: Python 3.13.x
```

## Monorepo with Multiple Python Projects

**Example: hub/ repo with root + sub-projects**

```
hub/
├── .mise.toml           # Root: Python 3.13
├── .envrc               # Root environment
├── .venv/               # Root virtualenv (serves scripts/)
├── scripts/
│   └── requirements.txt # Dependencies for scripts
├── sre-core/
│   ├── .mise.toml       # Sub-project: Python 3.10
│   ├── .envrc           # Sub-project environment
│   └── .venv/           # Sub-project virtualenv
└── other-project/       # Each sub-project has own environment
```

**Hub root (.mise.toml):**
```toml
[tools]
python = "3.13"
```

**sre-core sub-project (.mise.toml):**
```toml
[tools]
python = "3.10"
```

**Note on scripts/ directory:**
- The scripts/ directory uses the root environment (hub/.venv)
- Install scripts dependencies from root: `pip install -r scripts/requirements.txt`
- Run scripts from root: `python scripts/my_script.py`
- See "Project with scripts/ Directory" section above for details

### Behavior

When you `cd` into a sub-project, direnv automatically switches to that project's environment:

```bash
cd ~/hub
mise current              # python 3.13.x
echo $VIRTUAL_ENV         # /home/user/hub/.venv

cd ~/hub/sre-core
mise current              # python 3.10.x  (automatically switched!)
echo $VIRTUAL_ENV         # /home/user/hub/sre-core/.venv

cd ~/hub
mise current              # python 3.13.x  (back to root)
echo $VIRTUAL_ENV         # /home/user/hub/.venv
```

## Quick Setup Script

Use the dev-setup helper script for new projects:

```bash
~/quantivly/dev-setup/scripts/setup-python-project.sh <project-path> <python-version> [--poetry]
```

**Examples:**
```bash
# Plain virtualenv project with Python 3.11
~/quantivly/dev-setup/scripts/setup-python-project.sh ~/my-project 3.11

# Poetry project with Python 3.10
~/quantivly/dev-setup/scripts/setup-python-project.sh ~/my-poetry-project 3.10 --poetry
```
