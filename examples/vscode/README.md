# VSCode Python Project Settings

This directory contains VSCode settings templates for Python projects using mise + direnv + Poetry.

## Quick Setup

Copy the template to your project:

```bash
mkdir -p .vscode
cp ~/.dotfiles/examples/vscode/settings.json .vscode/
```

## What It Does

The template configures VSCode to work seamlessly with direnv-managed Python environments:

- **`python.defaultInterpreterPath`**: Points to project-local `.venv/bin/python`
- **`python.terminal.activateEnvironment: false`**: Critical - lets direnv handle activation instead of VSCode
- **Format on save**: Enabled for Python files

## Why `python.terminal.activateEnvironment: false`?

When you use direnv (via `.envrc`), the virtualenv is automatically activated when you `cd` into the project. If VSCode also tries to activate it, you get conflicts and confusion.

**With this setting:**
- Open integrated terminal → direnv activates `.venv` automatically
- No double-activation
- Consistent behavior between terminal and VSCode

## Customization

You can extend the template with additional settings:

```json
{
  "python.defaultInterpreterPath": "${workspaceFolder}/.venv/bin/python",
  "python.terminal.activateEnvironment": false,

  "[python]": {
    "editor.formatOnSave": true,
    "editor.defaultFormatter": "charliermarsh.ruff",  // If using Ruff
    "editor.codeActionsOnSave": {
      "source.organizeImports": "explicit"
    }
  },

  // Testing
  "python.testing.pytestEnabled": true,
  "python.testing.unittestEnabled": false,

  // Type checking
  "python.analysis.typeCheckingMode": "basic"
}
```

## Integration with Project Setup

This template is referenced in:
- `~/.dotfiles/examples/python-project-setup.md`
- `~/.dotfiles/examples/envrc-templates/README.md`

## Multi-Folder Workspaces

For multi-folder workspaces (like `quantivly.code-workspace`), you need workspace-level settings. See DO-209 for workspace configuration.

---

**Created:** 2026-01-13
**Purpose:** Provide reusable VSCode settings for Python projects with direnv
