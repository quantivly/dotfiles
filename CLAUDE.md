# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a personal dotfiles repository that manages zsh, git, and development tool configurations using [dotbot](https://github.com/anishathalye/dotbot). The configuration is modular, portable across machines, and security-focused with secrets separated from version control.

## Installation & Testing

For Quantivly developers: Use the `quantivly/dev-setup` repository which automatically installs prerequisites and dotfiles.

For standalone installation: `./scripts/install-prerequisites.sh && ./install`

### Testing Changes

```bash
./install          # Install/update dotfiles (uses dotbot, creates symlinks, initializes submodules)
source ~/.zshrc    # Test changes
time zsh -i -c exit  # Profile startup performance
```

## Server Setup

Bootstrap remote servers with `server-bootstrap.sh`. See [docs/SERVER_BOOTSTRAP_GUIDE.md](docs/SERVER_BOOTSTRAP_GUIDE.md) for full details including SSH config patterns, AL2 gotchas, and bootstrap ordering.

Key commands:
```bash
ssh server 'bash -s' < ~/.dotfiles/scripts/server-bootstrap.sh  # Bootstrap
ssh server '~/.dotfiles/scripts/server-bootstrap.sh --update'  # Update
```

## Architecture

### Modular Configuration System

The zsh configuration is split into focused modules loaded by `zshrc`:

1. **zshrc.history** - History configuration (50k commands, timestamps, deduplication)
2. **zsh/functions/\*.sh** - Utility functions organized into 3 modules (see Function Modules below)
3. **zshrc.aliases** - Portable aliases for git, docker, python, system commands
4. **zshrc.conditionals** - Module dispatcher that loads:
   - **zshrc.conditionals.tools** - Modern CLI tool configurations (bat, eza, ripgrep, zoxide, etc.)
   - **zshrc.conditionals.fzf** - FZF fuzzy finder setup and key bindings
   - **zshrc.conditionals.plugins** - Plugin integrations (mise, direnv, forgit, git workflows)
5. **zshrc.buildlimits** - Build/test worker caps so parallel agent sessions can't each claim every core
6. **zshrc.company** - Work-specific configuration (Quantivly)
7. **~/.zshrc.local** - Machine-specific secrets and settings (NOT in git)

### Function Modules

| Module | Purpose | Key Functions |
|--------|---------|---------------|
| `zsh/functions/core.sh` | Core utilities (22 functions) | `pathadd`, `mkcd`, `backup`, `extract`, `osc52`, `killnamed` |
| `zsh/functions/development.sh` | Git + Docker + FZF (39 functions) | `gd`, `git_cleanup`, `gco-safe`, `dexec`, `dlogs`, `fcd`, `fkill`, `qmux` |
| `zsh/functions/system.sh` | Performance + Utilities + GNOME + Backup + Audit (37 functions) | `startup_monitor`, `system_health`, `has_command`, `confirm`, `gnome-status`, `backup-now`, `backup-status`, `backup-doctor`, `backup-drill`, `backup-restore`, `backup-restore-system`, `audit-sweeps` |

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
- `~/.config/yazi/yazi.toml` → `~/.dotfiles/yazi/yazi.toml`

**Not symlinked (but coupled):**
- `~/.config/alacritty/alacritty.toml` — Terminator-style tmux keybindings require CSI u key entries here. Template: `examples/alacritty.toml.template`, install with `alacritty-init`. **Gotcha:** Live config diverges from template — updating the template doesn't propagate. Also, Ctrl+Shift+letter combos that have Alacritty built-in defaults (e.g., F=SearchForward) must have explicit entries to override. **CORRECTED 2026-08-30 — `O` IS one of them.** This line previously listed (E, O, W, T, S) as "no defaults, work automatically"; `ctrl+shift+o` is in fact swallowed by an Alacritty default. **Where it is documented (corrected again after review):** it is a shipped `[[hints.enabled]]` default — `man 5 alacritty` shows `binding = { key = "O", mods = "Control|Shift" }`. It is a *hints* binding, not a `keyboard.bindings` one, which is why it does not appear in `man 5 alacritty-bindings` and why an earlier note here wrongly said "no man page". Look in the hints section. It left herdr's split-down silently dead. Verified at the keyboard with `scripts/herdr-keyprobe.sh`: the signature is a **release event with no matching key-press** (`ESC[111:79;6:3u` arriving alone), because Alacritty bindings fire on press and consume it while the kitty protocol still reports the release. E, W and T were re-probed and do deliver presses; S was not re-tested. **Do not infer from one working letter that the class works — probe each chord you bind.** Preferred override is `action = "ReceiveChar"` ("treat as unbound") rather than a hardcoded `chars` CSI u string, since it follows whatever encoding mode is active instead of forcing kitty sequences into a legacy-mode terminal.
- **GNOME settings** — not files, so not symlinked. Applied to the dconf database via `scripts/apply-gnome-settings.sh` (run by `./install` on GNOME, or `gnome-apply`). Machine-specific layer: `~/.gnome-settings.local` (template: `examples/gnome-settings.local.template`, install with `gnome-init`). See [GNOME Desktop Configuration](#gnome-desktop-configuration).
- **Backup config** — `~/.backup.local` (repo paths, B2 keys, healthcheck URLs) is created from `examples/backup.local.template` by `./install` on GNOME (or `backup-init`) and never overwritten. The backup *policy* lives in `resticprofile/profiles.toml`, **copied** (never symlinked — root runs its hooks) to `/etc/resticprofile/` by `backup-setup`. See [Backup & Restore](#backup--restore).

### Configuration Loading Order

```
1. Locale export (LANG/LC_ALL — must be before p10k for icon rendering)
2. Powerlevel10k instant prompt (performance)
3. oh-my-zsh core and plugins
4. p10k.zsh theme
5. zsh/zshrc.history
6. zsh/functions/*.sh (core, development, system)
7. zsh/zshrc.aliases
8. zsh/zshrc.conditionals → loads three focused modules:
   - zsh/zshrc.conditionals.tools (CLI tool overrides)
   - zsh/zshrc.conditionals.fzf (FZF integration)
   - zsh/zshrc.conditionals.plugins (mise, direnv, etc.)
9. zsh/zshrc.buildlimits (build/test worker caps)
10. zsh/zshrc.company
11. ~/.zshrc.local (machine-specific secrets)
12. PATH additions
```

**Key Insight:** Conditionals load AFTER aliases, so tools that are installed get priority configuration.

## Powerlevel10k Customizations

Prompt shows GitHub PR numbers (`#123`) for branches with open pull requests. Uses smart caching for <5ms latency with non-blocking background fetch on cache miss.

- **Implementation:** `_p10k_get_pr_number()` in `p10k.zsh`
- **Cache location:** `~/.cache/p10k-pr-cache/<repo>/<branch>`
- **Manual refresh:** `rm -rf ~/.cache/p10k-pr-cache` (or per-branch: `rm ~/.cache/p10k-pr-cache/<repo>/<branch>`)

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for PR display troubleshooting.

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

Current plugins: autojump, colored-man-pages, direnv, extract, gh, git, poetry, safe-paste, sudo, web-search, zsh-autosuggestions, zsh-fzf-history-search, zsh-syntax-highlighting, quantivly

**Note:** fzf is *not* an oh-my-zsh plugin here — its shell integration loads via `eval "$(fzf --zsh)"` in `zsh/zshrc.conditionals.fzf` (runs after mise activation; mise installs the fzf binary only, with no bundled shell scripts).

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

## Tool Dependencies & mise

### Required Tools
- **zsh**, **oh-my-zsh**, **Powerlevel10k** (git submodule), **git**

### Strongly Recommended
- **fzf** — Fuzzy finder (many functions depend on it)
- **gh** — GitHub CLI (35+ custom aliases in `gh/config.yml`)
- **tmux** — Terminal multiplexer (session persistence, splits, remote work)

### Modern CLI Replacements

All tools are optional with intelligent fallbacks. Managed by mise.

| Standard | Modern | Standard | Modern |
|----------|--------|----------|--------|
| cat | bat/batcat | ps | procs |
| ls | eza/exa/colorls | df | duf |
| find | fd/fdfind | du | dust |
| grep | ripgrep | diff | delta/difftastic |
| cd | zoxide | top | btop |

Additional: lazygit, just, glow, gitleaks, pre-commit, sops, age, fastfetch

### mise (Version Manager)

Modern polyglot version manager replacing nvm, pyenv, rbenv, asdf (~5-10ms activation).

```bash
mise ls              # View installed tools
mise install         # Install from config
mise trust ~/.dotfiles/.mise.toml  # Trust dotfiles config (one-time)
```

**Config architecture:**
1. **Source of truth:** `~/.dotfiles/.mise.toml` — ~25 CLI tools with pinned versions
2. **Active config:** `~/.config/mise/config.toml` — a **symlink** to the above (corrected
   2026-08-30; this file previously said "copied", which is what let the drift below go
   unnoticed). `mise use -g` writes *through* the symlink to the repo file, so the two cannot
   diverge — which is the whole point.
3. **Project overrides:** `.mise.toml` in project root — per-project versions, requires `mise trust`

**The failure mode this architecture has, and how it is detected.** `./install` only creates
that symlink when the target is absent or byte-identical; if a real file is already there and
differs, it prints one warning and **keeps the local copy forever**. That state is stable,
self-perpetuating, and invisible. It happened here: the live config declared 10 tools while the
repo declared 23, so ~11 installed tools were never put on PATH — including `delta`, which
`gitconfig` routes `pager.diff/log/show/reflog` through, so `git diff` failed outright in a
terminal with `unable to execute pager 'delta'`. Nothing reported it.

`scripts/verify-tools.sh` now asserts both halves: that the symlink is intact, and that every
declared tool actually contributes a binary (`mise bin-paths`). Run it after any mise change.
A version pin that no longer exists in its backend "installs" successfully and produces **no
binary at all** while `mise install` reports success — `glow 1.5.1` and `fastfetch 2.8.10` both
did exactly this.

See [docs/TOOL_VERSION_UPDATES.md](docs/TOOL_VERSION_UPDATES.md) for version update procedures and [docs/MIGRATION.md](docs/MIGRATION.md) for nvm/pyenv migration.

## Python Environment Management

Projects use **mise + direnv + Poetry**: mise for Python versions, direnv for automatic activation, Poetry for dependencies with in-project `.venv/`.

```
project-root/
├── .mise.toml       # Python version
├── .envrc           # Auto-activation (direnv)
└── .venv/           # Virtual environment
```

Setup: `cp ~/.dotfiles/examples/envrc-templates/minimal.envrc .envrc && direnv allow && mise trust && mise install`

See [examples/python-project-setup.md](examples/python-project-setup.md) for complete setup, envrc templates, and dependency checking with quanticli.

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

**Terminal gotchas:**
- **`$TERM` follows the terminfo, not the config.** Alacritty reports `alacritty` when that terminfo entry exists and falls back to `xterm-256color` when it doesn't — so the value depends on *how Alacritty was installed*, not on `alacritty.toml`. The snap ships no terminfo (→ `xterm-256color`); the apt package pulls `ncurses-term`, which has it (→ `alacritty`). `tmux.conf:94-95` deliberately sets `terminal-features` for **both** patterns, so either value works. Truecolor rides the catch-all `terminal-overrides ",*:RGB"` — note `*256col*` does *not* match `alacritty`.
- **Install Alacritty from apt, not snap** — the snap renders on the CPU. It bundles its own Mesa (23.2.1, from base `core22`) rather than the host's, so a GPU newer than that Mesa isn't recognized by `iris` and Mesa silently falls back to `swrast`/llvmpipe. On this hardware (Intel Lunar Lake, Arc 130V/140V Xe2 — silicon a year newer than the bundled driver) that cost 24.5% of a core sustained at idle and ~73% while rendering a busy TUI. The apt build bundles no driver, so it always uses host Mesa and can't go stale this way. Verify on the running process: no `swrast` in `/proc/<pid>/maps`, ≥1 `/dev/dri` fd, and no `llvmpipe-*` threads in `ps -o comm= -L -p <pid>` (`libgallium-<version>.so` and a `gdrv` thread are the healthy signs; `libLLVM` is *not* by itself a software-rendering signal — Mesa links it for shader compilation on the GPU path too).
- Ctrl+Shift+Arrow works natively in tmux (xterm modifier encoding). Ctrl+Shift+**letter** needs Alacritty key bindings sending CSI u sequences + tmux extended-keys
- tmux `extended-keys` and `terminal-features` are server-level — require `tmux kill-server`, not just config reload

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
- Commit signing: SSH signing recommended (see below to enable)

**Useful aliases:** `git lg` (pretty log), `git conflicts` (show merge conflicts)

## Commit Signing

SSH signing recommended (Git 2.34+). Configure in `~/.gitconfig.local` with `signingkey`, `gpgsign = true`, `format = ssh`.

See [docs/SSH_SIGNING_SETUP.md](docs/SSH_SIGNING_SETUP.md) for complete setup guide.

## SSH Configuration

Template at `examples/ssh-config.template`. Run `ssh-init` to install. See [docs/SSH_CONFIG_GUIDE.md](docs/SSH_CONFIG_GUIDE.md) for full guide (multiplexing, Bitwarden agent, forwarding patterns).

## GitHub CLI Aliases

35+ `gh` aliases in `gh/config.yml`:
- `gh mypr` - Your open PRs
- `gh prs` - All open non-draft PRs
- `gh review` - PRs where you're requested as reviewer
- `gh prmerge` - Squash merge and delete branch
- `gh runs` - Recent workflow runs for current branch

## Tmux Configuration

Prefix-free tmux setup with Terminator-style keybindings. Prefix: Ctrl+s.

**Essential bindings:** Ctrl+Shift+E/O (split), Ctrl+Shift+W (close), Ctrl+Shift+Arrow (navigate), Ctrl+Alt+Arrow (resize), Alt+z (zoom), Ctrl+Shift+T (new window)

**Popup windows:** Alt+o (file finder), Alt+s (live grep), Alt+w (session picker), Alt+g (lazygit), Alt+y (yazi popup), Ctrl+b (yazi side pane toggle), Ctrl+Shift+F (tmux-thumbs quick-copy)

**Nested tmux (remote servers):** F12 toggles outer tmux off, passing all keys to inner tmux. Outer status bar turns grey with `[INNER]` label. Inner tmux auto-detects nesting and uses gold bar at top. For manual SSH-into-remote-tmux usage (e.g., `ssh -t server 'tmux a'`).

**Key notes:**
- No auto-start — launch manually with `tmn <session>`
- Alacritty coupling — Ctrl+Shift+letter bindings require CSI u entries in `~/.config/alacritty/alacritty.toml` (template: `examples/alacritty.toml.template`, install with `alacritty-init`)
- `extended-keys` and `terminal-features` are server-level — require `tmux kill-server`, not just config reload
- Plugins: tmux-resurrect, tmux-continuum, tmux-thumbs, tmux-open, tmux-dispatch
- Claude Code runs in fullscreen rendering (alt-screen) to avoid scrollback corruption — its output isn't in tmux copy-mode; scroll/search inside Claude (`Ctrl+o`, then `[` to dump to scrollback). See [docs/CLAUDE_CODE_TMUX.md](docs/CLAUDE_CODE_TMUX.md)

See [docs/TMUX_LEARNING_GUIDE.md](docs/TMUX_LEARNING_GUIDE.md) and [examples/tmux-workflows.md](examples/tmux-workflows.md) for comprehensive guides.

## Herdr (agent workspace manager)

Terminal workspace manager for coding agents (workspaces → tabs → panes, with agent detection).
Config: `config/herdr/config.toml` → `~/.config/herdr/config.toml`. Full guide:
[docs/HERDR_GUIDE.md](docs/HERDR_GUIDE.md).

**The governing fact: every layer of this stack fails silently.** A 2026-08-30 walkthrough found
five separately configured features completely dead — a keybinding, a prefix fallback, two
popups, and `hspawn` — while `herdr config check` returned `ok` and `herdr server reload-config`
returned `applied` with zero diagnostics throughout. **`config check: ok` means the file parses;
it says nothing about whether anything works.** Verify effects, one binding at a time, and never
generalise from one working example to a class.

Gotchas, in the order they bite:

- **Never run bare `herdr`** from a script or an agent — it attaches a client and hijacks the
  user's UI. Subcommands only. (At a keyboard it is just how you re-attach after `ctrl+alt+q`.)
- **An error anywhere in `[ui]` silently reverts ALL of `[ui]`** and reports `partial` with no
  error text. After any config edit, `herdr server reload-config | jq '.result.status'` must say
  `applied`. If an edit "did nothing", this is the first thing to check.
- **Setting a key field REPLACES it wholesale.** An action relying on a stock prefix default must
  re-list that default explicitly or it is silently lost (this is how `f12 v` / `f12 -`
  disappeared — an audit found 15 of 25 rebound actions had lost theirs). A bare value is only
  safe for actions whose stock default is empty (`focus_agent`, `next_agent`, `previous_agent`,
  `move_tab_*`, `resize_pane_*`). Diff against `herdr --default-config` after any keymap edit.
- **The herdr server's PATH is a snapshot taken when the server starts.** It carries the mise
  `installs/<tool>/<version>` dirs for whatever was *globally* configured at that instant (not
  mise's `shims` dir). Two consequences: a tool declared only in a project `.mise.toml` is
  invisible to the server, and a tool added globally *after* launch stays invisible until the
  server restarts — in both cases the popup or plugin opens and closes instantly with no error.
  Symlinking into `~/.local/bin` (also on the server PATH) makes a tool available *without* a
  restart, which is why `bun`, `lazygit` and `yazi` are linked there. An earlier version of this
  note said the server PATH "has no mise shims", which is literally true but misleading — it
  implied mise tools never resolve there, and they do.
- **A plugin pane that flickers and vanishes means the command exited.** The error is real but
  renders too briefly to read; reproduce it in a shell.
- **Plugins cannot declare their own keybindings** — wire them in `config.toml` and verify IDs
  with `herdr plugin action list`. An action appearing there does not mean its plugin is enabled.
- **Claude's trust-folder dialog defaults to "No, exit"** and a fresh worktree triggers it every
  time. Answer it on the **agent** surface (`herdr agent send-keys <pane> down`, then `enter`)
  *after* detection — pane-level keys sent as the dialog renders are silently dropped, because
  the TUI is not accepting input yet. `herdr agent prompt` refuses to type into a blocked agent.
- **`herdr agent wait` requires an already-detected agent.** It resolves its target up front and
  fails `agent_not_found`; it cannot wait *for* detection. Poll separately.
- **herdmates leaks plugin env into lead sessions** (upstream). Prefix plugin CLIs with
  `env -u HERDR_PLUGIN_STATE_DIR -u HERDR_PLUGIN_CONFIG_DIR`.
- **`clauth start <profile>` bypasses the `claude()` shell function**, so the session gets the
  right account but no team-lead capability. Team leads need `clauth <profile>` then `claude`.
- **`herdr plugin link` state is herdr-local** and is not restored by herdr-lazy after a rebuild.
- **If you spawn agents or panes, CLOSE THEM when their work is collected.** This is not tidiness
  — memory is the binding constraint on this box (8 threads, swap runs hot, and `system_health`
  exists because memory-pressure kills here are *silent*). A session that spawned six panes and
  left them idling after they had delivered drove the machine to **load 27 and 96% swap with 33
  claude processes**, endangering ten unrelated in-flight sessions; tearing those six down
  recovered it to load 11.5 / 84% / 23. An idle agent still holds its memory. Close panes you
  created once you have their output; keep one only if you have a concrete next task for it.
  (Closing panes you did *not* create is a different matter — don't, unless asked.)
- **Teammates in a herdmates team are NOT detected as herdr agents.** They exist as panes but are
  absent from `herdr agent list`, the sidebar rows, the priority sort and toasts — only the lead
  is detected. A lead also reports `done` while its teammates are still working, so read the
  lead's own roster for progress, not its agent state. Same blind spot applies to any pane sitting
  on Claude's trust dialog.
- **The sidebar publisher needs TWO things wired, and `./install` only does one.**
  `claude/hooks/session-statusline.sh` is symlinked to `~/.claude/hooks/` by dotbot, but it must
  also be set as `statusLine` in `~/.claude/settings.json` (user-level, not in this repo). Without
  that it never runs, every `$mdl`/`$eff_*`/`$ctx_*` token resolves to nothing, and those sidebar
  rows render empty with no error. It doubles as the in-pane status line, so visible model/context
  text inside a pane means the publisher is alive.

## GNOME Desktop Configuration

Clean, modern GNOME (dark `Yaru-prussiangreen-dark`, floating autohiding **bottom** dock, empty desktop, tmux-friendly keys) applied reproducibly via **stock GNOME/Yaru only** — no third-party extensions or themes.

- **Mechanism:** curated `gsettings` script (schema-validated, idempotent, reviewable), **not** `dconf dump` (which drags in machine-specific cruft). GNOME has no first-party export/import.
- **Source of truth:** `scripts/apply-gnome-settings.sh` (portable core). Runs automatically during `./install` on GNOME only (no-op on servers / other desktops).
- **Machine-specific layer:** `~/.gnome-settings.local` (dock favorites, custom launch keys) — mirrors the `~/.zshrc.local` pattern, sourced by the apply script, never overwritten. Create with `gnome-init`.
- **Tmux integration:** the script moves GNOME workspace switching off `Ctrl+Alt+Arrow` onto `Super`-based shortcuts so tmux pane-resize works (the previously-manual fix is now baked in).
- **XDG user-dir guard:** `scripts/repair-xdg-user-dirs.sh` (alias `xdg-repair`) keeps `~/Desktop`, `~/Documents`, … as real directories so `snapd-desktop-integration` can't turn them into broken self-referential symlinks. Idempotent; `./install` runs it on graphical workstations (gated on `$XDG_CURRENT_DESKTOP` + `xdg-user-dirs-update`, skipped on servers). See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
- **Wayland gotcha:** changes apply live; dock relayout is guaranteed after one log out / log in. `Alt+F2 r` / `Meta.restart` are X11-only — never use them.

See [docs/GNOME_CONFIGURATION_GUIDE.md](docs/GNOME_CONFIGURATION_GUIDE.md) for the full guide.

## Backup & Restore

Encrypted **3-2-1 backups** via **restic** (engine) + **resticprofile** (declarative
orchestrator). Targets an **external HDD** (when docked) + **Backblaze B2** (offsite). Fills
the gap `dev-setup`/dotfiles can't: credentials, unpushed work, app/desktop state, network/VPN
secrets, personal files. `backup` in `core.sh` is a *separate* single-file utility — the system
commands are all `backup-*`.

- **Source of truth:** `resticprofile/profiles.toml` (policy: sources, excludes, retention, checks, schedule) and `udev/99-backup-external.rules` (hotplug remount). Both **copied** root-owned to `/etc/` by `backup-setup` — never symlinked (root runs them; a user-writable config would be privilege escalation) — and both drift-checked by `backup-doctor` against the repo copy.
- **Portability (DO-459):** the repo configs are user/host-generic. `examples/backup-{includes,excludes}.txt`, `examples/backup.local.template`, `systemd/restic-backup-external.service` and `udev/99-backup-external.rules` carry `__BACKUP_*__` placeholders rendered at install time by `scripts/backup-render.sh` (`__BACKUP_HOME__`/`__BACKUP_USER__`/`__BACKUP_HOSTNAME__` from the machine; `__BACKUP_EXTERNAL_UUID__`/`__BACKUP_EXTERNAL_MOUNT_UNIT__` supplied by the caller) — restic and systemd `EnvironmentFile` do **no** shell expansion, so `$HOME` can't appear in the installed files, and `/home/*` globs would change include semantics. **An unresolved placeholder is a hard error, never a blank:** an empty `ENV{ID_FS_UUID}==""` would match every device without a UUID. `profiles.toml` needs no install-time rendering — its tags use resticprofile's runtime `{{ .Hostname }}`; the `[groups]` name is the fixed `full` (= `backup-now`'s default target). `backup-doctor`'s drift check compares live `/etc` files against the *rendered* templates.
- **Machine-specific layer:** `~/.backup.local` (repo URLs, B2 keys, healthcheck URLs) rendered from `examples/backup.local.template`. Created by `./install` on GNOME / `backup-init`. Plain `KEY=value` (consumed by both shell `source` and systemd `EnvironmentFile`).
- **Runs as root** (to read `/etc/NetworkManager/system-connections` + the keyring). The B2 timer is generated by resticprofile (`Persistent=true`); the external HDD uses `systemd/restic-backup-external.{timer,service}` — a 6-hourly timer whose `ConditionPathExists` runs it **only when the drive is docked** (a `.path` unit was avoided: `PathExists` retriggers a oneshot in a loop). Immediate run: `backup-now external`.
- **Keeping the external drive mounted is the whole game, and every layer of it fails silently.** An unmet `ConditionPathExists` makes systemd *skip* the unit, and a skipped unit is not a failed one — no error, nothing in `--state=failed`, no notification, no healthchecks ping. So `backup-setup` writes an `/etc/fstab` entry from `BACKUP_EXTERNAL_UUID` (covers boot) **and** `udev/99-backup-external.rules` (covers dock cycles, which on a laptop outnumber boots), plus a `service.d/10-external-mount.conf` drop-in ordering the run `After=` the mount unit so the timer's `Persistent=true` catch-up can't win a race against USB enumeration. **`After=`, never `Requires=`/`RequiresMountsFor=`** — those turn an undocked disk into a *failed* unit every 6h, which is the false alarm the `ConditionPathExists` design exists to avoid.
- **Four traps specific to this area**, all found by review rather than by use:
  - `findmnt --verify` errors on "unreachable on boot" for a `nofail` entry whenever the disk is undocked *or* its mount point directory is absent, so it can only be used to compare **parse-error counts**, never as a pass/fail gate — gating on its exit code rejects every correct entry in exactly the states that need fixing. Parse both `findmnt` summary shapes (`N parse errors, …` *and* the bare `Success, no errors or warnings detected`), and always under **`LC_ALL=C`**: both strings are gettext-marked in util-linux and ship translated in Ubuntu's language packs, so a translated locale otherwise makes every clean table look unparseable and kills the feature permanently.
  - **`test -e "$repo/config"` is not a docked test**: a leftover directory on the root filesystem satisfies it while the disk is unmounted, so `backup-status`/`backup-doctor` use `findmnt --mountpoint`.
  - **`findmnt -S UUID=x` matches a `/dev/disk/by-uuid/x` fstab entry only while the disk is attached** — it resolves the tag through `/dev/disk/by-uuid`. That is the form Ubuntu's installer writes (and what `/boot` uses here), so undocked — the state the whole feature exists for — a correct fstab reads as having no entry. Always query the literal device path as a second step (`fstab_target_for_uuid`, `_backup_fstab_target_for_uuid`).
  - **Never `render … | sudo tee /etc/…`.** `tee` truncates the destination before the renderer's exit status is known, so a failed render leaves a zero-byte `/etc` file that installs "successfully": an empty `includes.txt` backs up nothing, an empty `.service` is a unit that does nothing. Use `render_install` (render to a temp file, check, then `install`).
- **The mount point is a `dirname` of a hand-edited path, so it is guarded before use.** `BACKUP_EXTERNAL_REPO` one level too shallow resolves to `/media/<user>`, and a typo resolves to `$HOME` — and everything downstream then passes, so the external disk gets mounted over the user's home at every boot (`nofail` does not help; the mount *succeeds*). `external_mount_point_sane` refuses a non-absolute, unnormalised (`/./` counts — it resolves *past* a deny-list of literal strings) or symlinked path, a deny-list of system directories including `$HOME`, `/media/$USER` and `/run/media/$USER` (the user from `id -un`, never `$USER`, which login/PAM sets and which is empty under `sudo -u`/`env -i`/a systemd unit), and any existing directory that is not already a mount point and is either non-empty or *unlistable* — "cannot read it" is not "it is empty". **Every** step that consumes the mount point is gated on it: the `/etc/fstab` write, the udev rule, `restic init`, and the `ConditionPathExists`/`After=` wiring. Missing the init gate is the expensive one: `BACKUP_EXTERNAL_REPO=/restic` derives the mount point `/`, which *is* mounted, so restic would initialise the "external" repository on the root filesystem and every 6-hourly run would then write there while `backup-status` reported `docked ✓`.
- **A udev step that declines because the *configuration* no longer supports a rule removes the rule a previous run installed**, and `backup-doctor` checks for a stale rule even when nothing is configured. A leftover rule names a UUID that may now belong to a different disk, keeps passing `udevadm verify`, and simply never fires — and a drift check gated on "is anything configured" is exactly how it stays invisible. The two bail-outs where only *this run* failed (render error, `udevadm` rejection) deliberately keep the installed rule, which is more likely correct than absent; they are covered by the doctor's drift compare instead. Don't restate this as "every skip path removes" — it isn't, and the difference is the point.
- **`scripts/test-backup-external.sh` pins all of the above** (68 checks, root-free, no real disk) and **runs in CI** (`backup-external-test`). It asserts its own harness first: sourcing `setup-backup.sh` also runs that script's `set -euo pipefail`, so the suite re-declares `set +e` — otherwise the first expected-to-fail assignment kills the run mid-table with no failure count — and it aborts unless every function under test is actually defined, because most of these assertions are "nothing was installed", which is also what a suite that loaded nothing produces.
- **Ransomware resistance:** B2 append-only key (no `deleteFiles`) + lifecycle rule (`daysFromHidingToDeleting=30`); **not** Object Lock (breaks restic prune). A full-access key lives only in the offline kit (`backup-prune`).
- **Cold-start break:** an age-encrypted **offline emergency kit** holds the restic password, B2 full key, Bitwarden recovery, LUKS passphrase + header, WiFi PSK, and a GitHub PAT — so restore doesn't deadlock on "secrets are inside the backup I can't open."
- **Restore correctness (LVM-on-LUKS):** regenerate — do not restore — `/etc/fstab`, `/etc/crypttab`, `/etc/machine-id`, `ssh_host_*`. Timeshift is file-level rollback only (known LVM-on-LUKS bare-metal restore bug). `backup-restore-system` bakes those four excludes in so the `/etc`-slice restore can't break boot.
- **Verification (DO-449):** a backup's deadliest failure is silent. `backup-doctor` asserts the whole chain is *correct* (perms, config drift vs. `~/.dotfiles`, the DO-448 env drop-in, snapshot age, B2 repo size vs `BACKUP_B2_SIZE_WARN_GB` + last-run churn vs `BACKUP_B2_CHURN_WARN_MB` + prune staleness vs `BACKUP_B2_PRUNE_REMIND_DAYS` (the B2 repo is append-only — it grows until a manual `backup-prune`, and a hit Backblaze storage cap fails ALL runs at the lock write), that healthcheck URLs are set, kit/LUKS-header freshness, disk space; non-zero exit on FAIL). A weekly `systemd/restic-verify.timer` runs `scripts/backup-verify.sh` — a content canary (critical paths present in the latest snapshot) + restore canary (one file restored) — decoupled from `[b2.check]`, skips cleanly when offline, alerts via `restic-notify` (`BACKUP_HC_URL_VERIFY`). `backup-drill` is the on-demand equivalent. `restic check` proves *intact*; this proves *complete + restorable*. Desktop failure notifications dedup on state change (daily reminder while stuck + one "recovered" popup); healthchecks pings fire every run.

Commands: `backup-init`, `backup-setup`, `backup-now`, `backup-status`, `backup-doctor`, `backup-drill`, `backup-snapshots`, `backup-check`, `backup-restore`, `backup-restore-system`, `backup-mount`, `backup-unlock`, `backup-prune`, `backup-luks-header`, `backup-kit`.

See [docs/BACKUP_AND_RESTORE_GUIDE.md](docs/BACKUP_AND_RESTORE_GUIDE.md) for setup, the disaster-recovery runbook, and the verification regimen.

## Audit Tripwire (broadcast kills)

A two-line **auditd** rule that records any real `kill(-1, sig)` — *"signal every
process I may signal"*, which on a desktop is the entire graphical session. This
machine runs many parallel agent sessions with shell access, and a broadcast kill
produces a perfectly orderly teardown: no crash, no OOM, no coredump, nothing in
the journal explaining it. Without the rule there is no evidence to find; with it
the record names the sending process, exe, cmdline and parent.

- **Source of truth:** `audit/99-logout-catch.rules`. **Copied** root-owned to
  `/etc/audit/rules.d/` by `audit-setup` — never symlinked, same reasoning as
  `resticprofile/profiles.toml` (root's auditd reads it).
- **`a0` must stay `0xFFFFFFFF`, never widened to 64 bits.** Audit's rule field is
  u32, and on x86-64 a C `int` of `-1` is passed via `mov edi,-1`, which
  zero-extends — the kernel sees `0x00000000FFFFFFFF`. A 64-bit constant matches
  nothing, and a rule that matches nothing is indistinguishable from a clean
  machine. `a1!=0` drops signal-0 probes (error-checking only, sends nothing).
- **auditd takes AppArmor denials out of the journal.** After install,
  `journalctl -k | grep apparmor` returns nothing — use `sudo ausearch -m AVC`.
  Relevant to the snap/`unprivileged_userns` notes above.
- **"Armed" is three independent things**, and each can be false while the other
  two look fine: the rules are in the kernel (`auditctl -l`), auditing is switched
  on (`enabled != 0`), and **a daemon is persisting records to disk** (`pid != 0`).
  Rules live in the *kernel*, so `auditctl -l` lists them happily with auditd
  stopped — but then records go to the kernel ring buffer instead of
  `/var/log/audit/audit.log`, and `ausearch` (so `audit-sweeps`) is blind forever
  with no error. `audit-setup` and `audit-status` both assert all three.
- **Silent-failure modes** (`audit-status` reports each as its own failure): a
  rejected rule field leaves *zero* rules loaded with no error; auditing switched
  off; no daemon registered; a climbing `lost` counter dropping records;
  `/etc` drifted from `~/.dotfiles` (the file is *copied*, so editing the repo
  copy alone changes nothing); and `disk_full_action`/`admin_space_left_action`
  are `SUSPEND`, so auditd stops logging quietly if `/var` runs low. Each
  otherwise looks exactly like "nothing bad happened".
- **Scope: `a0 == -1` only.** `kill(0, sig)` ("my whole process group") is a real
  hazard but shells issue it routinely, so a rule would be noise; `kill(-pgid,
  sig)` isn't expressible statically. `-1` is the one that can only ever be a
  session-wide broadcast. See the rules file for the full reasoning.
- Expect a benign burst from `systemd-shutdown` (pid 1) at every reboot.

Commands: `audit-setup` (add `--yes` to skip the auditd install prompt),
`audit-status`, `audit-sweeps`.

## Common Tasks & Workflows

```bash
source ~/.zshrc      # Reload config (or: zshreload)
localrc              # Edit ~/.zshrc.local
qcache-refresh       # Refresh startup caches
gh-refresh-tokens    # Refresh GH CLI token cache
tool_status          # Check installed tools
build-limits         # Show active build/test worker caps (see zshrc.buildlimits)
alacritty-init       # Set up Alacritty config (new machine)
qmux                 # Per-server tmux sessions for dev/staging/demo (Alt+w to switch)
gnome-apply          # Apply curated GNOME desktop config (idempotent)
xdg-repair           # Fix/guard ~/Desktop, ~/Documents, ... XDG dirs (idempotent)
gnome-init           # Create ~/.gnome-settings.local (dock favorites, launch keys)
gnome-status         # Summary of GNOME version, theme, dock, extensions
backup-init          # Create ~/.backup.local (repo paths, B2 keys)
backup-setup         # One-time guided backup install (restic, repos, timers, kit)
backup-now           # Run a backup now (external HDD + Backblaze B2)
backup-status        # Backup health: targets reachable, timers, latest snapshot
backup-doctor        # Full-chain health assertion (perms, drift, alerting, freshness)
backup-drill         # Prove the backup is complete + restorable (content + restore canary)
backup-restore       # Guided restore of a snapshot to ~/restore-<ts>/
backup-restore-system # Guarded /etc-slice restore (never clobbers fstab/crypttab/machine-id/ssh_host_*)
audit-setup          # Install/refresh the broadcast-kill audit tripwire (idempotent)
audit-status         # Armed, switched on, recording to disk, in sync? (non-zero on fail)
audit-sweeps         # Show broadcast kill(-1) events (default: last 24h)
```

Workflow guides: [git](examples/git-workflows.md) | [docker](examples/docker-workflows.md) | [fzf](examples/fzf-recipes.md) | [tmux](examples/tmux-workflows.md)

## Troubleshooting

Quick fixes for common issues. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for detailed troubleshooting.

- **Slow startup:** `time zsh -i -c exit` (target: <250ms). Caches at `~/.cache/{quanticli-paths,gh-token-cache,p10k-pr-cache}/`
- **Function not found:** Check symlink (`ls -la ~/.zshrc`), re-run `./install`
- **Tool not loading:** `command -v toolname`, then `source ~/.zshrc`
- **mise trust:** `mise trust ~/.dotfiles/.mise.toml`
- **Alias conflicts:** `type commandname` to inspect, `\commandname` to bypass
- **Git auth:** `gh auth status` / `gh auth login`
- **Backups:** `backup-doctor` (full-chain correctness — start here), `backup-status` (quick health), `systemctl list-timers | grep restic`, `resticprofile -c /etc/resticprofile/profiles.toml show` (validate config)
