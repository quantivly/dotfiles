# VSCode Python Configuration

VSCode settings for Python projects using mise + direnv + Poetry are managed globally via dotfiles.

## Global Configuration (Automatic)

The dotfiles installer (`./install`) symlinks `~/.dotfiles/vscode/settings.json` to `~/.config/Code/User/settings.json`, providing these settings for **all** Python projects:

- **`python.terminal.activateEnvironment: false`** - Critical for direnv compatibility
- **`python.defaultInterpreterPath`** - Uses project-local `.venv/bin/python`
- **`[python]` formatting** - Format on save with Ruff as default formatter
- **pytest enabled** - Pytest testing framework enabled by default
- **File associations** - `.envrc`, `.python-version`, `.mise.toml` syntax highlighting

## Why Global Configuration?

Since you use direnv consistently across all Python projects, these settings should be global rather than duplicated in each project's `.vscode/settings.json`.

**Benefits:**
- ✅ No need to configure VSCode per-project
- ✅ Consistent behavior across all projects
- ✅ Works for both standalone projects and multi-folder workspaces
- ✅ Single source of truth in dotfiles

## Critical Setting: `python.terminal.activateEnvironment: false`

When you use direnv (via `.envrc`), the virtualenv is automatically activated when you `cd` into the project. If VSCode also tries to activate it, you get conflicts.

**With global setting to `false`:**
- Open integrated terminal → direnv activates `.venv` automatically
- No double-activation
- Consistent behavior between terminal and VSCode

## Project-Specific Overrides (Optional)

Most projects don't need a `.vscode/settings.json` file. Only create one if you need project-specific settings like:

- Custom pytest arguments
- Project-specific formatters or linters
- Special code actions
- Non-standard interpreter paths

**Template for overrides:**

```bash
mkdir -p .vscode
cp ~/.dotfiles/examples/vscode/settings.json .vscode/
# Edit .vscode/settings.json to uncomment and customize settings
```

See `settings.json` in this directory for commented examples.

## Verification

Check your global settings:

```bash
cat ~/.config/Code/User/settings.json  # Should be symlinked to ~/.dotfiles/vscode/settings.json
ls -la ~/.config/Code/User/settings.json  # Verify it's a symlink
```

## Multi-Folder Workspaces

Global settings also work with multi-folder workspaces (like `quantivly.code-workspace`). Workspace settings can override global settings if needed.

---

**Updated:** 2026-01-13
**Purpose:** Global VSCode configuration for Python projects with direnv managed via dotfiles
