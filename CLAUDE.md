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
| `zsh/functions/system.sh` | Performance + Utilities + Dotfiles guard + GNOME + Backup + Audit (59 functions) | `startup_monitor`, `system_health`, `has_command`, `confirm`, `dotfiles-doctor`, `dotfiles-work`, `gnome-status`, `backup-now`, `backup-status`, `backup-doctor`, `backup-drill`, `backup-restore`, `backup-restore-system`, `audit-sweeps` |

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

### The checkout IS the deployment

Everything above is a **symlink into the git working tree**. Nothing is copied. So
`git checkout` in this repo is not a branch switch, it is a deploy: the instant HEAD
moves, `~/.zshrc`, `~/.gitconfig`, `~/.config/git/ignore`, the gh account configs and
the rest change under the running system — no install step, no restart, no log line,
and `git status` stays clean throughout. `~/.zshrc` also sources the whole of `zsh/`,
so a change to `zsh/functions/system.sh` is just as live as a linked file.

Both directions have caused real failures, both on 2026-08-31:

- **Behind the default branch.** The checkout predated PR #87, so `backup-doctor` was
  still printing `• external HDD not docked (normal — B2 covers offsite)` — the exact
  false reassurance that had already let a backup outage run unnoticed. Found, fixed,
  reviewed, merged, and still not running, because nothing re-pointed the symlink
  target at the fix.
- **Ahead of it.** ~830 lines of an open, unmerged, unreviewed PR's `zshrc.company`
  were being sourced by every new interactive shell.

Note the asymmetry that proves the mechanism: system-level files are **copied**
(`/etc/udev/rules.d/99-backup-external.rules`, `/etc/resticprofile/profiles.toml`), and
they kept working across the same branch switch that broke the symlinked half.

**The convention: the primary checkout stays on `main`; feature work happens in a
worktree.** No symlink points into a worktree, so you can edit, rebase, stash and
bisect there without changing the shell you are typing into.

```bash
dotfiles-work my/branch      # create/enter ~/dotfiles-worktrees/my-branch
dotfiles-work --list         # list worktrees
dotfiles-work --remove b     # remove one
dotfiles-doctor              # is the live config the reviewed config?
dotfiles-doctor --fetch      # ...compared against the actual remote, not a stale ref
```

`dotfiles-doctor` reports the pin state, how stale `origin/main` is, commits
ahead/behind it, **which managed files actually differ** (the blast radius, not just a
commit count), uncommitted changes to those files, and link integrity in four
directions — declared-but-not-installed, installed-but-dangling,
linked-but-pointing-outside-this-checkout, and linked-inside-the-checkout-but-at-the-
wrong-file (rename a source without re-running `./install` and the first three all pass
while the live file is the old source, permanently).

A one-line warning also fires on the first prompt of any shell whose live config is off
the pin branch, **or is on it at a different commit than `origin/main`**, **or is on it
and matching a ref older than `DOTFILES_STALE_WARN_HOURS` (168 = 7d)** — that second
case is the #87 outage, and nothing about a checkout sitting on `main` looks wrong. The
third exists because the first two shas are both read off local disk, so they agree the
moment the machine stops fetching: "identical to `origin/main`" on a checkout that has
not fetched in a month means identical to a month-old idea of `main`. The threshold is
far more forgiving than the doctor's 24h deliberately — the doctor is asked, this fires
unasked, and a line that appears every morning is a line nobody reads. Once per *shell*,
not once per source: re-sourcing `zshrc` (`zshreload`) does not reprint it. It
reads `.git/HEAD` and the two ref files directly rather than forking `git`: 0.07 ms for
HEAD, 0.3 ms including both refs, against 2–5 ms for a single `git symbolic-ref` on this
box, on every shell, forever. It cannot say *which* direction the divergence goes
(that needs a merge base, which needs a fork), so it does not claim one.

**Every layer of this feature fails by looking clean**, so each check is written against
the state that produces a green tick rather than an error. The ones that bit during
review, all of which reported success:

- **`config check`-style existence is not currency.** Nothing on this machine fetches on
  a schedule, so `origin/main` is exactly as old as the last time a human typed
  `git fetch` — and against a week-old ref, "not behind" means "not behind whatever was
  true then", which is #87 reported as an all-clear. The doctor therefore states the
  fetch age every run and warns past `DOTFILES_FETCH_MAX_AGE_HOURS` (24), which
  suppresses the unqualified ✓. `--fetch` is the only form that answers about the real
  remote.
- **`./install` from a worktree re-points the whole live config at a feature branch**,
  silently: `git status` stays clean either side, and the doctor's branch and drift
  checks read the primary checkout. Three things now catch it: `install` refuses
  (`DOTFILES_ALLOW_WORKTREE_INSTALL=1` overrides), the doctor
  resolves every link to check it lands inside the checkout (testing only "is it a
  symlink" passed that state with "17/17 declared links present"), and the startup line
  resolves `~/.zshrc` — where the shell it is warning in was actually sourced from — with
  zsh's `:A`, so it stays forkless.
- **The live set is bigger than the link list.** `zsh/` is sourced by the linked
  `~/.zshrc`, and `scripts/` is executed *by path* out of the working tree — every
  `backup-*`/`audit-*`/`gnome-apply`/`verify-tools` command shells out to
  `~/.dotfiles/scripts/…`, and `systemd/herdr-server.service` has
  `ExecStart=%h/.dotfiles/scripts/herdr-server-launch.sh`. Omitting `scripts/` hid four
  drifting files, one of which writes root-owned files into `/etc`. `resticprofile/`,
  `audit/` and `udev/` are deliberately *not* in the set: they are **copied** to `/etc`,
  so moving HEAD does not change what runs — `backup-doctor`/`audit-status` drift-check
  those instead.
- **An unparseable `install.conf.yaml` yields no paths, and no paths reads as no drift.**
  The map is parsed once and a failure to read a single link is reported as
  `what is live is UNKNOWN` with a non-zero exit, never as "every live file matches".
  "Could not read the file" and "the `link:` block declares nothing" are named apart,
  because their fixes differ.
- **A pathspec that matches nothing exits 0 with empty output**, so every way of getting
  a source wrong *narrows* the drift check instead of failing it — and the narrowing is
  invisible. Four of them were live at once: a quoted scalar (`~/.zshrc: 'zshrc'` is
  ordinary YAML) kept its quotes; dotbot's null form (`~/.vimrc:`, source inferred from
  the destination's basename minus one dot — `link.py:_default_target`) was dropped
  whole; `target` was never cleared when the `link:` block ended, so the next `path:`
  anywhere below became the last link's source; and nothing checked that a declared
  source *exists*, so `~/.zshrc: zshrcc` would take the most live file in the repo out
  of every check and still print a green tick. Every declared source is now asserted
  present in the tree, once, before anything derived from the map runs.
- **`~/.config/mise/config.toml` is a live symlink that dotbot does not create** —
  `install` makes it itself, so it is in no `link:` block and was in nothing the doctor
  checked. It is emitted alongside the declared links now, under both halves of
  `install`'s own gate (the source exists, and mise is installed), so a machine without
  mise does not get a permanently-red check for a link that correctly does not exist.
  What its drifting costs is already recorded above: ~11 tools off `PATH` and a dead
  `git diff`, for months.
- **`git status --porcelain` is not a format you can compare paths against.** It
  C-quotes any path with a space and writes a rename as `old -> new`, so no
  `DOTFILES_EXPECTED_DIRTY` entry could ever match either and such a file was a
  permanent, inexcusable warning. `-z` records are unquoted; a rename's original path
  arrives as its own record; and the variable may now be a zsh array, since
  word-splitting a scalar makes a path with a space impossible to express.
- **`cond && ok || bad` reports both outcomes when the ✓ printf fails** (SC2015),
  counting a failure for a check that passed. Not academic: `zsh`'s printf returns 1 on
  ENOSPC, so a redirected run on a full filesystem inverted five checks. The lint that
  names this never sees the file — the ShellCheck job selects by `^#!` shebang and
  `zsh/functions/*.sh` has none, while pre-commit excludes the directory outright
  because the syntax is zsh. CI's `zsh -n` loop now covers it, which is the only static
  check that ever will.
- **`[[ -f .git ]]` is not the worktree test.** A `--separate-git-dir` clone and a
  submodule also have a `.git` FILE, and both are ordinary places to install from — they
  got `./install`'s refusal on every run and a `dotfiles-doctor` that returned 1 forever,
  with only an env var framed as "deploy this worktree" to escape. git's own definition
  is git-dir ≠ git-common-dir (`install`), or the `commondir` file git writes in a linked
  worktree's git dir (the forkless startup path).
- **A git that cannot read the repo answers every question with silence.** A malformed
  `~/.gitconfig` (itself a managed symlink, so a bad branch can cause this) made
  `rev-parse` fail and the doctor announce "no origin/main ref — Fix: git fetch origin"
  when the ref was there. One health probe runs first; if it fails, the doctor says so
  and reports nothing else.
- **Noise in normal states is a failure too.** The working-tree check is scoped to the
  live paths (unscoped it reported every scratch file and `node_modules/` in the tree),
  `DOTFILES_EXPECTED_DIRTY` covers files a tool is *meant* to write through its symlink
  (`plugins.lock`, per `install.conf.yaml`), and a conditional link (`if:` in
  `install.conf.yaml`, e.g. `~/.p10k.zsh`) that is correctly absent is a note, not a
  failure — reporting it as one made the doctor exit non-zero forever.
- **`dotfiles-work <branch>` needs `--no-track`.** Without it the new branch takes
  `origin/main` as upstream, and under this repo's own `push.default=simple` a plain
  `git push` fails and suggests `git push origin HEAD:main` — pushing unreviewed commits
  straight onto the protected branch. It also refuses a leftover directory that is not a
  worktree instead of `cd`-ing in and reporting success.

Overrides: `DOTFILES_PIN_BRANCH`, `DOTFILES_ROOT`, `DOTFILES_WORKTREES`,
`DOTFILES_GUARD_QUIET=1` (silence the startup line while dogfooding a branch),
`DOTFILES_FETCH_MAX_AGE_HOURS`, `DOTFILES_STALE_WARN_HOURS`, `DOTFILES_EXPECTED_DIRTY`
(scalar or array), `DOTFILES_ALLOW_WORKTREE_INSTALL`.

State table: `scripts/test-dotfiles-guard.sh` (195 checks, run in CI, hermetic — it
builds its own fixture repo, remote and `HOME`). Every bug found in the guard so far
printed a green tick rather than an error, so each one is a row: a `local path`
declaration that blanks `PATH` in zsh, a diff against a ref that did not exist, a stale
ref, an unparseable link map, a symlink into another worktree, an emptiness guard made
unreachable by a hardcoded fallback path, and every way of naming a link source that
makes its git pathspec match nothing. Each is pinned by mutation: the fix is reverted in
a copy of the tree and the row that names it has to fail. It also covers the `_doctor_*` reporting
helpers that `dotfiles-doctor` and `backup-doctor` share — including the "declare the
counters `local`" convention, asserted over every function that calls `_doctor_summary`
rather than a fixed list, because a doctor that forgets it silently restores the globals
and inherits the previous run's exit code.

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
13. Dotfiles live-config guard — registers a one-shot `precmd` hook that runs
    `_dotfiles_live_config_warn` on the FIRST prompt, then removes itself.
    Deferred rather than run here because p10k's instant prompt turns any output
    during initialization into a warning box.
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

**Any change at all:** work in a worktree (`dotfiles-work <branch>`), not by moving the
primary checkout — see [The checkout IS the deployment](#the-checkout-is-the-deployment).
Check with `dotfiles-doctor` before and after.

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
returned `applied` with zero diagnostics throughout. **`config check: ok` means the file parses and
its keys, chords and `[ui]` schema are internally consistent; it says nothing about effects.** It
does catch bogus keys, bad inline fields, non-hex colours and chord collisions among *listed*
actions (probed 2026-08-30) — but not a collision with an unlisted stock default, a chord the
terminal swallows, a missing popup binary, or a token that is never published. Verify effects, one
binding at a time, and never generalise from one working example to a class.

Gotchas, in the order they bite:

- **Never run bare `herdr`** from a script or an agent — it attaches a client and hijacks the
  user's UI. Subcommands only. (At a keyboard it is just how you re-attach after `ctrl+alt+q`.)
- **Never start or restart the herdr server from inside a pane or a Claude session.** The server's
  environment is a snapshot of whoever launched it, and every pane inherits it. The live server was
  once relaunched from a team-lead pane (2026-08-29), so every pane got the teammux shim as `tmux`,
  a fake `TMUX`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and herdmates' plugin dirs — a dozen-plus
  team-of-one sessions, `tmn`/`tmux kill-server` dead, `$status` on every row, and the runbooks'
  `command -v tmux` pre-flight passing for everyone. Use the unit:
  `systemctl --user restart herdr-server.service` (`systemd/herdr-server.service`, launcher
  `scripts/herdr-server-launch.sh`; `--print-env` shows the environment it builds, and it refuses to
  start when `HERDR_ENV`, `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` is set). `scripts/verify-tools.sh`
  asserts the running server's env is clean. The unit is wanted by `graphical-session.target`, **not
  `default.target`**: `Linger=yes` on this account brings the user manager up at *boot*, so a
  `default.target` unit would start before GNOME imports `DISPLAY`/`WAYLAND_DISPLAY`/`XAUTHORITY`
  and get none of them. It still survives logout — `WantedBy` propagates start only, and the unit
  has no `PartOf` — so every agent session stays alive. Nothing is manual per boot. See
  HERDR_GUIDE §2.4.
- **An error anywhere in `[ui]` silently reverts ALL of `[ui]`** and reports `partial` with no
  error text. After any config edit, `herdr server reload-config | jq '.result.status'` must say
  `applied`. If an edit "did nothing", this is the first thing to check.
- **Setting a key field REPLACES it wholesale.** An action relying on a stock prefix default must
  re-list that default explicitly or it is silently lost (this is how `f12 v` / `f12 -`
  disappeared — an audit found 15 of 25 rebound actions had lost theirs). A bare value is only
  safe for actions whose stock default is empty (`focus_agent`, `next_agent`, `previous_agent`,
  `move_tab_*`, `resize_pane_*`). Diff against `herdr --default-config` after any keymap edit.
- **A LINKED systemd unit is not a RECONCILED one, and the difference is invisible.** systemd
  records `[Install]` at `enable` time, as a symlink under `<target>.target.wants/`. Editing
  `WantedBy=` afterwards changes nothing about what starts — **not even after `daemon-reload`**,
  which re-reads the unit but never revisits the symlink. **And the obvious fix is a trap:
  `systemctl reenable` (= `disable` + `enable`) DESTROYS a dotbot-installed unit.** `disable`
  removes every symlink in the unit search path pointing at the unit, and the entry in
  `~/.config/systemd/user` is exactly such a symlink, into the checkout — so the enable half then
  fails with "Unit does not exist" and the unit is left neither linked nor enabled. That happened
  here on 2026-09-01. What is safe is `enable` (it only ADDS `.wants` links) plus pruning the
  stale link by hand, in that order. A probe using a real FILE rather than a symlink showed
  `reenable` working perfectly, which is how the advice got written — **a fixture that differs
  from production in the one property that decides the outcome proves nothing.** Meanwhile
  `systemctl status` is happy, so the unit file under review says one thing and what boots is
  another. This repo *manufactures* that drift, because `git checkout` here is a deploy and
  `./install` is not in that path: HEAD moves, the linked unit file changes under systemd, nothing
  re-enables anything. It cost one reboot's worth of every pane losing `gh --web`, `xdg-open` and
  the ssh agent, with every check on the machine green. Now: `./install` reconciles
  (`scripts/reconcile-systemd-units.sh`, gated — no-op without a user manager, and it re-enables
  only a unit that is *already* enabled, so it reconciles a decision rather than making one), and
  `scripts/verify-tools.sh` **fails** when the enablement has drifted. `--check` reports,
  `--plan` lists what `--apply` would touch. State table: `scripts/test-systemd-reconcile.sh`
  (36 checks, in CI as `systemd-reconcile-test`) — hermetic and needing no systemd at all, since
  the whole comparison is filesystem state.
- **"Clean" is not "complete" for the server environment.** `verify-tools.sh` used to ask only
  whether anything FORBIDDEN was present, so a server started at boot — before any graphical
  session existed to import an environment from — carried no forbidden variable and passed as
  clean while every pane had lost `gh --web`, `xdg-open` and the ssh agent. It now also asserts
  that the session variables the *user manager* offers are actually present in the server, and
  warns when `DISPLAY`/`WAYLAND_DISPLAY` name a **previous** login (a server deliberately
  survives logout, so it keeps the dead session's values). `SSH_AUTH_SOCK` is excluded from that
  value comparison on purpose — the launcher substitutes a stable symlink for it by design.
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
- **`clauth start <profile>` bypasses the `claude()` shell function**, so it lacks what that function
  adds: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and a launch via `herdmates teammux-launch`, which
  passes `--settings '{"teammateMode":"tmux"}'` so teammates become herdr panes. Whether teams are
  enabled at all depends on the flag *reaching the process* — a contaminated server hands it to
  everyone, and such a session leads a team whose teammates run in-process, invisible to herdr
  (INFERRED from Claude Code's default `teammateMode`; not observed). Team leads need
  `clauth <profile>` then `claude`; prove it with `herdr pane process-info --pane <id>` showing
  `teammateMode`, not with `command -v tmux`.
- **`herdr plugin link` state is herdr-local** and is not restored by herdr-lazy after a rebuild.
- **If you spawn agents or panes, CLOSE THEM when their work is collected.** This is not tidiness
  — memory is the binding constraint on this box (8 threads, swap runs hot, and `system_health`
  exists because memory-pressure kills here are *silent*). A session that spawned six panes and
  left them idling after they had delivered drove the machine to **load 27 and 96% swap with 33
  claude processes**, endangering ten unrelated in-flight sessions; tearing those six down
  recovered it to load 11.5 / 84% / 23. An idle agent still holds its memory. Close panes you
  created once you have their output; keep one only if you have a concrete next task for it.
  (Closing panes you did *not* create is a different matter — don't, unless asked.) Enumerate with
  `hreap` — every Claude process **in a herdr pane**, detected or not, with idle age, memory and
  creator (default view is idle ≥ 30 min; `--older 0` shows all); `hreap --close --mine` closes
  only your registry-tagged idle spawns — **not** `herdr agent list`, which misses herdmates
  teammates and trust-dialog panes (it showed 14 while 33 claude processes ran — though note ~8 of
  those were Claude under Atrium's tmux, outside herdr panes and so outside `hreap` too; the tab
  bar's `agents <detected>/<procs>` gap is the full census). `hspawn` records each spawn in `~/.local/state/hspawn/`; `hdespawn <slug>` tears one down
  (pane, workspace, worktree, registry entry).
- **A pane id is not a permanent name, and the registry that keys on it is.** herdr allocates
  workspace ids from a short alphabet whose counter lives only in the running server
  (`~/.config/herdr/session.json` persists the workspaces but no next-id counter), so a restart
  reissues them from the start — the server log here shows `w4`, `w5`, `wN` and `wP` each created
  twice in five days — and every new workspace's first pane is `p1`. Meanwhile
  `~/.local/state/hspawn/` is a file tree that outlives every restart, and its entries are
  deliberately long-lived: each hspawn bail-out keeps its entry, and `hreap --close` annotates
  rather than deletes so `hdespawn` can finish later. So `wN:p1` names two different spawns, and
  hspawn's `>` used to destroy the older entry silently, orphaning its worktree and branch with
  nothing on disk pointing at them. It now renames it to `<pane>.stale-<ts>.json` and says so. Two
  habits follow: **`hdespawn <pane-id>` is the exact form** (a direct file lookup — `hdespawn
  <slug>` scans and REFUSES when two entries share a slug, which `--close` makes likely by
  design), and an entry whose workspace id now holds someone else's worktree is finished from the
  recorded path with herdr's live workspace left untouched, rather than refused forever. State
  table: `scripts/test-hspawn.sh` (126 checks, in CI as `hspawn-test`) — hermetic via a recording
  `herdr` **stub** at the front of `PATH`, never via herdr's absence: the box this was written on
  has a real one wired to a live server, and a suite that assumed absence would pass in CI and
  remove a real workspace here.
- **Teammates in a herdmates team are NOT detected as herdr agents.** They exist as panes but are
  absent from `herdr agent list`, the sidebar rows, the priority sort and toasts — only the lead
  is detected. A lead also reports `done` while its teammates are still working, so read the
  lead's own roster for progress, not its agent state. Same blind spot applies to any pane sitting
  on Claude's trust dialog. The cause is the process name: Claude Code execs teammates via its
  versioned binary, so `herdr pane process-info --pane <id>` shows a foreground process named
  `2.1.251` rather than `claude`, and herdr never consults the Claude manifest — although
  `herdr agent explain --file <screen> --agent claude` accepts the same pane's screen (`state: idle`,
  rule `live_prompt_box`). `herdr agent explain <pane>` is the first diagnostic; `agent_not_found`
  means nothing was detected at all. Reported upstream (drafts: `~/herdr-eval-upstream/`).
- **The sidebar publisher needs THREE things wired, and `./install` only does one.**
  `claude/hooks/session-statusline.sh` is symlinked to `~/.claude/hooks/` by dotbot, but it must
  also be set as `statusLine` in `~/.claude/settings.json` (user-level, not in this repo), and that
  entry needs `"refreshInterval": 60` — without the interval the idle band freezes when the session
  goes quiet and every token then expires on the 4-minute TTL, blanking the rows. Without the
  statusLine entry it never runs, every `$mdl`/`$eff_*`/`$ctx_*` token resolves to nothing, and those sidebar
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
- **The mount point is a `dirname` of a hand-edited path, so it is guarded before use.** `BACKUP_EXTERNAL_REPO` one level too shallow resolves to `/media/<user>`, and a typo resolves to `$HOME` — and everything downstream then passes, so the external disk gets mounted over the user's home at every boot (`nofail` does not help; the mount *succeeds*). `external_mount_point_sane` refuses a non-absolute, unnormalised (`/./` counts — it resolves *past* a deny-list of literal strings) or symlinked path, a deny-list of system directories including `$HOME`, and any existing directory that is not already a mount point and is either non-empty or *unlistable* — "cannot read it" is not "it is empty". **The per-user parents are still on that list, but nothing rests on them any more.** For every other entry the list is belt-and-braces: `/etc` and `$HOME` are non-empty, so the content checks refuse them whether or not anyone listed them. `/media/<user>` is the one dangerous directory that is *legitimately empty* whenever no drive is docked, and also legitimately the parent of the right answer — so there the list was load-bearing and alone, and both holes ever found in it were there (an empty `$USER`; then `/media/./<user>`). The question is now put to the system: `path_is_account_directory` refuses `<parent>/<leaf>` for `/home`, `/media`, `/run/media` when `getent passwd` says `<leaf>` names a **regular login account** — uid within login.defs' `UID_MIN`..`UID_MAX`, **or** a home directory under `/home/`. That second test is not redundant: the login.defs window is right for local accounts and useless for exactly the ones the `getent` call was justified by, since SSSD's AD id-mapping starts at `ldap_idmap_range_min=200000` by default, real AD-mapped uids land in the millions, and systemd-homed allocates above `UID_MAX` — so a domain-joined workstation got no protection past the current user. Their home is `/home/<name>` (SSSD's `fallback_homedir` default), which is what catches them, and it still matches none of `backup` (`/var/backups`), `games` (`/usr/games`), `nobody` (`/nonexistent`) or `root` (`/root`). The literals stay as belt-and-braces (they cost nothing and still fire if `getent` is unavailable), but the structural rule is what does the work: it covers *every* account rather than the current one, and needs no identity resolution at all, so the `$USER` class of bug cannot recur in it. **The uid bound is the whole discriminator, not a detail.** udisks makes these directories only for accounts that log in to a desktop; matching *any* passwd entry would refuse `/media/backup` — a plausible hand-made mount point, with `backup` a stock uid-34 account — and that is not a harmless over-rejection: `install_external_udev` treats an unusable mount point as a reason to **remove** the hotplug rule, so a working install would silently lose its remount-on-dock. Two smaller traps: the passwd *name* field is compared back, so a numeric key (`getent passwd 1000`) doesn't make `/media/1000` look like a user directory; and the lookup runs under `timeout`, since NSS with an unreachable LDAP source would otherwise hang the installer with no output. A missing `timeout` binary falls back to a direct call rather than letting every lookup return empty, which would switch the rule off with no sign. **An unanswered lookup is not a clean "no", and the guard is tri-state because of it.** Only `getent`'s exit 2 means "no such key"; `timeout`'s 124 and a missing `getent` (127) mean the question never ran, and reading those as "not an account" switched the rule off silently on exactly the hosts the `timeout` exists for. `external_mount_point_sane` returns **2** for "could not determine" and refuses — **from the very end of the function, after every check that could settle the path with certainty has had its turn.** Returning it as soon as the lookup failed downgraded certain refusals to uncertain ones: `BACKUP_EXTERNAL_REPO=$HOME/restic`, the single most canonical error there is, became "could not check, keeping the rule" on any host whose name service was merely slow, and the `/media/$me` literals went unreachable in the one state where anything rests on them — accepting would be no safer, since the correct mount point is also one component under `/media` — and **every step that installs persistent state keys on that 2 to change nothing at all** — a name-service hiccup must not undo what an earlier successful run got right. There are exactly four consumers and each has to be checked individually: the `/etc/fstab` write skips (writes nothing, so a plain skip is correct), `install_external_udev` keeps the existing rule, `init_repos` skips *and says "could not be checked" rather than "unusable"*, and `install_external_schedule` returns before it writes. That last one is the expensive one and the ordering inside it is load-bearing: it re-renders the unit from the template first, which **resets `ConditionPathExists` to the template's own path**, so a bail-out placed after that has already destroyed the setting it meant to preserve — and it then `rm -f`s the `After=` drop-in. A unit whose `ConditionPathExists` names a nonexistent path is *skipped, not failed*, so nothing reports it, and `backup-doctor` checks the `10-backup-env.conf` drop-in but has **no check at all for `10-external-mount.conf`**. The lookup is bounded at 5s, not 2: since an unanswered lookup is now a refusal, too tight a bound turns a healthy-but-slow host (a cold SSSD cache resolving against a remote DC over a VPN) into a permanent installer failure telling the user to fix a working name service. `root` is accepted (`/media/root`) because uid 0 is outside the window *and* `/root` is not under `/home/` — a deliberate carve-out, *not* the claim that udisks never mounts there, which is false: on Ubuntu's layout it does, for a uid-0 session. Reaching uid 0 would mean reaching past every system account on the way, and the preflight already refuses to run the installer as root. It is also **not** a depth rule ("three components under `/media`"): that rejects `/media/backup-hdd`, `/media/external` and `/mnt/store`, which are ordinary hand-made mount points and not udisks parents at all. **Every** step that consumes the mount point is gated on it: the `/etc/fstab` write, the udev rule, `restic init`, and the `ConditionPathExists`/`After=` wiring. Missing the init gate is the expensive one: `BACKUP_EXTERNAL_REPO=/restic` derives the mount point `/`, which *is* mounted, so restic would initialise the "external" repository on the root filesystem and every 6-hourly run would then write there while `backup-status` reported `docked ✓`.
- **A udev step that declines because the *configuration* no longer supports a rule removes the rule a previous run installed**, and `backup-doctor` checks for a stale rule even when nothing is configured. A leftover rule names a UUID that may now belong to a different disk, keeps passing `udevadm verify`, and simply never fires — and a drift check gated on "is anything configured" is exactly how it stays invisible. The two bail-outs where only *this run* failed (render error, `udevadm` rejection) deliberately keep the installed rule, which is more likely correct than absent; they are covered by the doctor's drift compare instead. Don't restate this as "every skip path removes" — it isn't, and the difference is the point.
- **`scripts/test-backup-external.sh` pins all of the above** (99 checks, root-free, no real disk) and **runs in CI** (`backup-external-test`). It asserts its own harness first: sourcing `setup-backup.sh` also runs that script's `set -euo pipefail`, so the suite re-declares `set +e` — otherwise the first expected-to-fail assignment kills the run mid-table with no failure count — and it aborts unless every function under test is actually defined, because most of these assertions are "nothing was installed", which is also what a suite that loaded nothing produces.
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
dotfiles-doctor      # Is the live config the reviewed config? (--fetch to check the real remote)
dotfiles-work <br>   # Create/enter a worktree so the primary checkout stays on main
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
