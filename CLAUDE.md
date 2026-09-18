# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## How to extend this file

**This is an instruction file, not a journal.** It is loaded in full into every request of
every session, so every paragraph here is paid for on every turn — and past ~150k chars
Claude Code warns that length *reduces adherence*, i.e. the file stops producing the
behaviour it was written to produce. It held 14k–36k for eight months and then went
35,682 → 350,324 in nineteen days, because each PR appended its own review narrative. A
one-off cut was already tried (2026-01-07, −62%) and it regrew 25×, so the budget is now
enforced: `scripts/check-claude-md.sh`, run in CI and by pre-commit, against a ceiling
derived from history that can only tighten. **Remove as much as you add.**

Before adding anything, route it:

| what you have | where it goes |
|---|---|
| Changes what an agent **does**, everywhere in this repo | here, as **one imperative line** |
| Changes what it does in **one area** of the code | `.claude/rules/<area>.md` (a trigger card: imperative lines and links, ≤2,000 bytes) |
| A procedure for a recurring task | `.claude/skills/<task>/SKILL.md` (+ uncapped `references/`) |
| Evidence, a measurement, a date, a postmortem, a mutation tally | `docs/<AREA>.md` |
| What changed in this release | `CHANGELOG.md` |
| True of the **tools or harness** regardless of repo | the agent memory store |
| True of **every Quantivly repo**, not just this one | the `quantivly-conventions` plugin |
| A rule whose condition can no longer fire | **retire it — do not extract it** |

Two rules about *how* to move something, both measured rather than assumed:

- **Extract the elaboration; keep the operative rule here.** The threshold, the decision and
  the emitted line stay inline. nanoclaw measured a 22-file extracted reference corpus at
  **zero reads across 102 runs** — including a file cited with "You MUST read" — so moving a
  rule out and leaving a pointer improves every number and loses the rule.
- **One prose home per fact.** A one-line imperative here and a short memory hook are
  *pointers*; what is forbidden is the same *explanation* written twice. `CLAUDE.md` and
  `docs/HERDR_GUIDE.md` already drifted that way once (commit `69d815d`).

Anything you add under `docs/`, `.claude/rules/` or `.claude/skills/` **must be linked from
here or from `README.md`** — the guard enforces reachability, because an unrouted file is an
unread file. `docs/CLAUDE_SETUP.md` sat unlinked and therefore unread until this guard named
it; that is the failure mode, and it is silent from every other angle.

Budget knobs and their rationale: [scripts/context-budget.conf](scripts/context-budget.conf).
Run `./scripts/check-claude-md.sh` before you commit.

**`.claude/rules/` cards cannot be scoped, measured rather than assumed.** On Claude Code
2.1.277 a card carrying `paths:` **never loads** — not at session start, not after reading a
matching file, at project or user scope, in every spelling tried (block list, inline array,
literal path); an identical card *without* `paths:` loads every time. So a card is not a
cheap on-demand layer, it is more always-loaded text, and the guard forbids `paths:` rather
than requiring it. Until that changes, a rule that must reach an agent belongs **here**.

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
2. **zsh/functions/\*.sh** - Utility functions organized into 4 modules (see Function Modules below)
3. **zshrc.aliases** - Portable aliases for git, docker, python, system commands
4. **zshrc.conditionals** - Module dispatcher that loads:
   - **zshrc.conditionals.tools** - Modern CLI tool configurations (bat, eza, ripgrep, zoxide, etc.)
   - **zshrc.conditionals.fzf** - FZF fuzzy finder setup and key bindings
   - **zshrc.conditionals.plugins** - Plugin integrations (mise, direnv, forgit, git workflows)
5. **zshrc.buildlimits** - Build/test worker caps so parallel agent sessions can't each claim every core
6. **zshrc.herdr** - The herdr agent-workspace layer (portable; split out of
   zshrc.company by DO-555 so herdr can be adopted without the work half)
7. **zshrc.company** - Work-specific configuration (Quantivly)
8. **~/.zshrc.local** - Machine-specific secrets and settings (NOT in git)

### Function Modules

| Module | Purpose | Key Functions |
|--------|---------|---------------|
| `zsh/functions/core.sh` | Core utilities (22 functions) | `pathadd`, `mkcd`, `backup`, `extract`, `osc52`, `killnamed` |
| `zsh/functions/development.sh` | Git + Docker + FZF (39 functions) | `gd`, `git_cleanup`, `gco-safe`, `dexec`, `dlogs`, `fcd`, `fkill`, `qmux` |
| `zsh/functions/system.sh` | Performance + Utilities + Dotfiles guard + GNOME + Backup + Audit (59 functions) | `startup_monitor`, `system_health`, `has_command`, `confirm`, `dotfiles-doctor`, `dotfiles-work`, `gnome-status`, `backup-now`, `backup-status`, `backup-doctor`, `backup-drill`, `backup-restore`, `backup-restore-system`, `audit-sweeps` |
| `zsh/functions/github.sh` | gh account routing + diagnosis (10 functions) | `gh-doctor` |
| `zsh/functions/claude.sh` | Claude Code auth + MCP diagnosis (5 functions) | `claude-doctor` |
| `zsh/zshrc.herdr` | herdr agent workspaces (17 functions) — mostly **agent-facing**, a human at the keyboard uses the herdr UI and `clauth` instead | `hspawn`, `hdespawn`, `hreap`, `claude`, `herdr-lazy`, `herdr-help` |

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

Everything in the symlink table is a **symlink into this working tree**, `~/.zshrc` sources all of
`zsh/`, and `scripts/` runs from it by path — so moving HEAD *is* a deploy: no install step, no
restart, and `git status` stays clean. How that failed in both directions, and the live-config
guard, the umask guard and every trap in them: [docs/DOTFILES_DEPLOY.md](docs/DOTFILES_DEPLOY.md).

- **The primary checkout stays on `main`; feature work happens in a worktree.** No symlink points
  into a worktree, so you can edit, rebase and bisect there without changing the live shell.
  ```bash
  dotfiles-work my/branch      # create/enter a worktree
  dotfiles-work --list
  dotfiles-work --remove b     # deletes its branch only once it has landed
  dotfiles-doctor --fetch      # is the live config the reviewed config, against the real remote?
  ```
- **Deploy with a fast-forward merge, never `git pull`.** `pull.rebase = true` makes `pull` refuse in
  this repo's normal state, where `plugins.lock` is dirty by design:
  ```bash
  git -C ~/.dotfiles fetch origin main
  git -C ~/.dotfiles diff --name-only HEAD..origin/main   # dirty paths must not appear here
  git -C ~/.dotfiles merge --ff-only origin/main
  bash ~/.dotfiles/install
  ```
- **Never `git stash`** to make a merge work: the stash stack is shared with every worktree and
  every agent session on the box.
- **Never run `./install` from a worktree** — it re-points the whole live config at a feature
  branch, silently. It refuses unless `DOTFILES_ALLOW_WORKTREE_INSTALL=1`.
- **Whether a branch landed is answered by the merge record, not by a tree diff:**
  `gh pr view <n> --json state,mergeCommit`. A squash-merged branch is not an ancestor of `main`,
  so delete it with `git branch -D`.
- **`dotfiles-doctor` without `--fetch` answers about the last fetch**, which nothing on this
  machine schedules — "not behind" can mean "not behind a month-old idea of `main`".
- **Tools write `safe.directory` entries through the `~/.gitconfig` symlink into the tracked,
  public `gitconfig`** (auto-conf's `configure.py` did, seven times). `dotfiles-doctor` names them;
  the fix is `git restore --staged --worktree -- gitconfig`.

### Configuration Loading Order

```
1. Locale export (LANG/LC_ALL — must be before p10k for icon rendering)
2. Powerlevel10k instant prompt (performance)
3. oh-my-zsh core and plugins
4. p10k.zsh theme
5. zsh/zshrc.history
6. zsh/functions/*.sh (core, development, system, github, claude — github and
   claude after system, which defines the shared _doctor_* emitters they use)
7. zsh/zshrc.aliases
8. zsh/zshrc.conditionals → loads three focused modules:
   - zsh/zshrc.conditionals.tools (CLI tool overrides)
   - zsh/zshrc.conditionals.fzf (FZF integration)
   - zsh/zshrc.conditionals.plugins (mise, direnv, etc.)
9. zsh/zshrc.buildlimits (build/test worker caps)
10. zsh/zshrc.herdr (herdr layer — before company, and independent of it:
    a modular adopter sources this one file and nothing else)
11. zsh/zshrc.company
12. ~/.zshrc.local (machine-specific secrets)
13. PATH additions
14. Dotfiles live-config guard — registers a one-shot `precmd` hook that runs
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

GitHub Actions runs ShellCheck, syntax and YAML validation, pre-commit hooks, installation tests
(Ubuntu 22.04/24.04), and a hermetic state table per guard. See `.github/README.md`.

**Run locally:**
```bash
pre-commit run --all-files    # All checks
bash -n install               # Syntax check
shellcheck -x install         # Lint
act -j shellcheck             # Run specific CI job locally (requires act)
```

- **Every apt install in CI goes through `.github/actions/apt-install`** — `apt-get update` exits
  non-zero when *any* configured source errors, including third-party lists no job reads.
  `scripts/check-workflow-apt.sh` enforces it.
- **A new guard ships with a hermetic state table and a mutation sweep.** "Could not run" is
  exit 2, never a pass, and the suite asserts its own row total.
- **Rows fail by looking green.** A needle must be unique to the rule, and checked against what
  the pass path prints; a row whose fixture fails for more than one reason is decoration; ask of
  every row what single change to the code would make it fail. Dry-run every mutation for
  applicability — one that no longer applies reads exactly like a survivor. A row count detects a
  *skipped* check, never a *hollow* one.
- **A new external tool in a checker is a new way for it to go quiet.** Here `grep` is a `ugrep`
  shim and `awk` is mawk, so GNU extensions fail — and paired with `2>/dev/null || true`, fail
  silently.

The evidence — the apt outage, seventeen defects found in one checker under a green suite, the
YAML-parser rewrite, and the mutation rounds: [docs/REPO_CHECKS.md](docs/REPO_CHECKS.md).

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
- **One name per call.** `command -v a b c` takes a single operand in POSIX sh, and the
  shells disagree about the rest: measured here, `command -v bash nosuchtool` prints only
  `/usr/bin/bash` and exits **0** in bash and dash, and **1** in zsh — so the same line is a
  silent pass with two tools missing in one shell and an unexplained failure naming none of
  them in the other. It is not academic: `docs/HERDR_GUIDE.md` §2.3 carries this warning in a
  comment, and the team-facing write-up derived from it then used exactly that shape as a
  verification step. Loop, or call it once per tool.

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

## GitHub Account Routing (`gh-doctor`)

**`GH_CONFIG_DIR` does not isolate the credential, and `gh auth status` will not tell
you.** gh stores its tokens in the system keyring keyed by **host**, not by config dir,
so `GH_CONFIG_DIR` isolates `hosts.yml` and `config.yml` and nothing else. Observed here
on 2026-09-01:

```
config dir      hosts.yml declares    an API call resolves to
gh              zvi-quantivly      →  zvi-quantivly
gh-personal     ZviBaratz          →  zvi-quantivly   ← mismatch
gh-quantivly    zvi-quantivly      →  zvi-quantivly
```

`gh auth status` reports the *declared* user throughout — so it says `ZviBaratz` while
the API answers `zvi-quantivly`. **A status command describing intent rather than
effect**, the same shape as the `backup-doctor` bug and the live-config guard's false
all-clear. The direction matters: with `GH_TOKEN` unset it falls back to the **work**
account, in any directory, so a personal repo silently gets work credentials while git
correctly signs the commits as personal.

`zshrc.company` already works around it by caching per-account tokens
(`~/.cache/gh-token-cache/{personal,quantivly}`, 600, refreshed on shell start) and
exporting the right one as `GH_TOKEN`; its own comment notes that `gh auth token`
**without `--user`** "returns a shared default that may be wrong". So the mechanism was
known — **the defect is the failure mode**, which is invisible and biased toward work.

There is one deliberate escape hatch: `GH_ACCOUNT_ROUTING_OFF=1` makes the hook return
without touching anything, for a supervisor that provisions per-session credentials of its
own. It replaces the Atrium deferral, whose problem was the *detection* (`$ATRIUM`, or a
tmux socket named `*/atrium` — anything could set either), not the capability; being named
rather than sniffed also lets `gh-doctor` report such a shell as deliberate instead of
faulty.

`gh-doctor` (`zsh/functions/github.sh`) makes it visible. For a directory it prints the
account the **remote** routes to, the account gh **declares**, the account an actual
`GET /user` **returns**, and which mechanism decided (`GH_TOKEN` / `GITHUB_TOKEN` /
config-dir keyring). Everything it says about "effective" comes from a real request;
nothing is inferred from configuration, because that inference *is* the bug. It also
proves the workaround still works — for each config dir it probes twice, once with the
token env cleared (which reproduces the collapse) and once pinned with
`gh auth token --user <login>` (which does isolate) — so nobody is told to rely on a
mechanism that has itself broken.

**Routing follows the repo REMOTE, not `$PWD`** — the rule git identity already uses
(#67, `hasconfig:remote.*.url` in `~/.gitconfig.local`), so a work repo routes correctly
wherever it is checked out and a personal repo under `~/quantivly/` does not get the work
account. Like `hasconfig`, **any** remote can match, not just `origin`: in a fork workflow
origin is the personal fork and upstream is the work repo, and matching origin alone would
hand that repo the personal account while git signs its commits as work.

**A path route decides only what the remote cannot.** `GH_ACCOUNT_PATH_ROUTES` is
consulted for a directory with *no* GitHub remote — not a repository, a repository with no
remotes, or only non-GitHub remotes — and never for one that has a remote, matched or not: a
GitHub remote whose owner matches no route means *personal, by remote*, exactly what git
identity concludes. Precedence is remote owner route → path route → `GH_ACCOUNT_DEFAULT_DIR`,
with `git-error` stopping before any of them. It exists for the work tree's roots that are
not repositories (`~/quantivly/qspace` holds two repositories and is itself none; `drafts`,
`comms-style`, `handoffs`). On 2026-09-09 a Claude Code session started in
`~/quantivly/qspace` took the personal default; Claude's Bash-tool shells are `zsh -c` with
no `.zshrc`, so they inherit Claude's environment verbatim, and the GitHub MCP plugin's
`Authorization` header is expanded from that environment once at startup — so every `gh`
call and every MCP request in the session was the personal account, 404ing on private work
repositories until the session was restarted from a correctly routed shell. One deliberate
trade-off: a repository with *no* GitHub remote under `~/quantivly` (a fresh `git init`, a
GitLab checkout) is routed by place, while git identity stays personal until a quantivly
remote is added — the state `docs/TROUBLESHOOTING.md` already documents for git alone. A
GitHub URL the parser rejects is *not* that case: it counts as a GitHub remote, blocks the
path table, and `gh-doctor` flags it.

The `chpwd` hook (`_update_gh_config` in `zshrc.company`) uses the same
`_gh_route_for` the doctor does — one implementation, so the oracle cannot drift from the
thing it checks — then **pins** the account by exporting `GH_TOKEN` from
`~/.cache/gh-token-cache/<config-dir-basename>`. It routed on `$PWD` first until
2026-09-01, which let gh and git disagree about the same repository: a quantivly clone
outside `~/quantivly/` got the personal account from gh and the work identity from git.

**Every directory now pins an account explicitly; the keyring never decides.** Outside a
repo — `$HOME` is the normal resting state of a shell — the routing falls through to
`GH_ACCOUNT_DEFAULT_DIR` (personal), which is what git identity does there too. That is
deliberately *not* treated as a failure: warning on every `cd` into a non-repo directory is
how a warning stops being read. The loud path is reserved for the states where nothing can
be pinned — no default configured, an unusable table, or a routed account with no cached
token — and even then the message is printed **at most once per distinct message per
shell**, and never before the first prompt (output during initialization lands inside
p10k's instant-prompt warning box, the same reason the live-config guard defers).

The token cache is keyed by the config dir's **basename** (`gh-quantivly`, `gh-personal`),
not by a nickname, so the routing table is the single place an account is named — adding a
route needs no matching edit to the refresher, and a stale nickname cannot address the
wrong dir. `gh-refresh-tokens` and the shell-start background job are both driven by
`_gh_configured_dirs`, and both delete the pre-2026-09-01 nickname files, which would
otherwise sit there as a second, never-refreshed copy of a live credential.

```bash
gh-doctor                 # this directory
gh-doctor --offline       # config only — every network answer marked NOT CHECKED
gh-doctor ~/some/repo
```

Configuration is data, in `zsh/zshrc.company` (or `~/.zshrc.local`), read by the doctor:

```zsh
GH_ACCOUNT_ROUTES=( "quantivly=$HOME/.config/gh-quantivly" )             # owner-glob=config-dir
GH_ACCOUNT_PATH_ROUTES=( "$HOME/quantivly=$HOME/.config/gh-quantivly" )  # absolute-prefix=config-dir; only a dir with NO GitHub remote
GH_ACCOUNT_DEFAULT_DIR="$HOME/.config/gh-personal"                       # empty = indeterminate
```

Traps this area has, each of which produced a green tick or a confident wrong answer:

- **A route whose config dir does not exist can never fire**, and reporting that only when
  the route happens to match means the fault first surfaces on the day it was finally
  needed. The whole table is checked every run, matched or not. This is not hypothetical:
  writing the entry in **single** quotes (`'quantivly=$HOME/...'`) leaves a literal
  `$HOME` that never exists, and the route silently never matches.
- **`${~pat}` enables tilde expansion as well as globbing**, so a route pattern beginning
  with `~` aborted the lookup with "no such user or named directory" and took every later
  route with it. Owner patterns are restricted to `[A-Za-z0-9_.-]` plus `*` and `?`, and
  anything else is named as a bad table entry rather than left to misfire at match time.
- **An unparseable routing table selects nothing, and nothing reads as "this repo is
  personal"** — the unparseable-link-map failure from the live-config guard, in a new
  place. `bad-table` is its own state and is reported as UNUSABLE.
- **zsh's `local NAME` on a name already local in that scope is a DISPLAY command**, so a
  `local` inside a loop printed `du=zvi-quantivly` into the middle of the report.
- **An unfixable condition is a ⚠, not a ✗.** The keyring collapse is a property of `gh`;
  nothing here can repair it. Reporting it as a failure made `gh-doctor` exit 1 on *every*
  run — the permanently-red checker this file warns about two sections up, in the command
  written to avoid it, found only once it was deployed and run for real. The isolation
  section is the *rationale* for pinning (here is the collapse; here is proof the per-user
  token defeats it); ✗ is reserved for what someone can act on — the route disagreeing with
  the effective account, a missing route dir, an unreachable API, and a per-user token that
  resolves to the wrong login, which means that account needs `gh auth login`.
- **An empty answer is never agreement.** A failed or timed-out API call is a ✗ with the
  error, and every comparison that depended on it is reported as *skipped*, never passed.
  `--offline` marks its answers NOT CHECKED for the same reason.
- **The environment, not argv — and the severity of that was overstated once already.**
  `/proc/<pid>/cmdline` is world-readable (444) while `/proc/<pid>/environ` is owner-only
  (400), so `env GH_TOKEN=gho_… gh api user` looks like a leak. **It mostly is not**:
  measured, `env` *consumes* its assignments and then execs, so the token never reaches the
  exec'd program's cmdline — only the short-lived `env` process's own, between fork and
  exec. A microsecond race, not the length of the call, and **not** the same shape as the
  28-day tmux server this machine actually found. `_gh_run` uses a subshell anyway: it
  closes even the race, and — the real payoff — retires the whole `env`-argv class, which
  had already produced two bugs here (a shell function after `env`; `-u` after an
  assignment), both surfacing as *"could not resolve the account"*.
  The correction matters as much as the fix: a checker whose findings are inflated is a
  checker whose findings stop being believed.
- **`exec` resolves shell functions; `env` could not.** So the subshell form introduced a
  hazard the old one lacked — a user's `gh` wrapper in `~/.zshrc.local` being run instead
  of the binary, and its output taken as the effective login. `exec command gh`. Reachable
  only on the no-`timeout` fallback, which is why the test needs a PATH fixture that has
  `gh` but not `timeout`; without that it silently exercises the safe path.
- **git's exit status is load-bearing.** 0 = matched, 1 = no match, **128 = git could not
  read the repository at all** — which a malformed `~/.gitconfig` produces, and
  `~/.gitconfig` is itself a managed symlink in this repo, so a bad branch causes it.
  Discarding the status left the state at its initialised `no-repo`, which falls through to
  the personal default: a quantivly clone silently authenticating as the personal account,
  on the one path that deliberately does not warn. `git-error` is its own state, it stops
  rather than falling through, and it is loud.
- **The first prompt re-runs the routing; it does not replay what startup recorded.** The
  startup call routinely loses a race it is *meant* to lose — the token cache is
  repopulated by a background job that lands a second later — so the shell starts unpinned.
  Replaying that message printed something no longer true *and* left `GH_TOKEN` unset for
  the life of the shell, putting every `gh` call back on the keyring default inside a
  personal repo. The defect this mechanism exists to close, reintroduced in the one shell
  per boot nobody would re-check.
- **`GITHUB_TOKEN` is cleared everywhere `GH_TOKEN` is.** gh ranks it second, so leaving it
  set on an unpinned path means a third account nobody named wins — while the warning
  blames the keyring.
- **`gh-doctor <dir>` is not `gh-doctor`.** The effective-account probe reads *this
  shell's* environment, which the hook pinned for `$PWD`; comparing it against a different
  directory's route produced a confident ✗ for a state that cannot occur, since cd-ing
  there repins first. The comparison now runs only for `$PWD`.
- **The legacy-nickname purge subtracts the configured basenames.** `quantivly` and
  `personal` are also legal config-dir basenames, so purging *after* the writes deleted a
  token just cached, and purging *before* them discarded a still-valid one whenever that
  iteration's `gh auth token` failed transiently. Naming the exception removes the ordering
  question rather than answering it.
- **Helpers used outside the opt-in gate must be defined outside it.** `gh-refresh-tokens`
  sits outside `[[ -d ~/.config/gh-quantivly ]]` while its cache helpers sat inside, so on
  a personal-only box — the exact machine the gate exists for — it hit `command not found`,
  took an *empty* cache path, wrote a live token to `/<basename>` at the filesystem root,
  and printed `✓ … cached token` with exit 0.
- **A chpwd helper may not be a `$(...)` call.** Replacing a parameter with a function to
  deduplicate a path put a fork back in the hot path this file had just been cut down to
  one git fork. One assignment deduplicates just as well.
- **The first-prompt hook retires only once it has pinned something.** Unhooking after a
  single attempt meant a shell that lost the cache race twice — the refresher does two `gh`
  forks, and p10k's instant prompt can beat them — stayed on the keyring default for life.
  Later prompts are free: it short-circuits on `[[ -n $GH_TOKEN ]]` before any fork.
- **`GITHUB_TOKEN` is cleared on the SUCCESS path too, not just the failures.** gh outranks
  it, but the GitHub MCP server, `act`, `hub` and most Actions-shaped tooling do not — so
  an inherited one kept authenticating as a third account inside a correctly-routed
  directory, with `gh-doctor` reporting `credential: $GH_TOKEN` and showing nothing wrong.
- **Keep git's own error.** Collapsing every non-0/1 status into one sentence blaming
  `~/.gitconfig` was wrong for most of them: git missing is 127, `$PWD` may be deleted, and
  "detected dubious ownership" is ordinary on external media and wants `safe.directory`.
  stderr is folded into the capture (a temp file would need `rm`, and a broken PATH is one
  of the states being diagnosed), and the parser shape-checks `remote.<name>.url` so a
  warning cannot become a phantom remote.
- **`local` outside a function is an error in zsh**, and the shell-start refresher was an
  inline `{ … } &!` block — so the error went to a backgrounded subshell's stderr where
  nobody sees it, the cache stayed empty, and every directory reported "account NOT
  pinned". It is a function now. (Writing a credential out of dynamically-scoped globals
  would have been the other way to get that wrong.)
- **A `chpwd` hook cannot afford a `gh` fork.** The doctor may spend ~50 ms per config dir
  asking gh what it declares; the hook may not, so it reads the cache file directly and
  `_gh_repo_remotes` was reduced to a single `git` fork on the common path — `git config
  --get-regexp` exits non-zero for "not a repo" and "no such key" alike, so the `rev-parse`
  that tells them apart runs only when there was nothing to parse.
- **A workspace root is not a repository, and "not a repository" fell to the personal
  default.** `~/quantivly/qspace` holds two work repositories and has no remote of its own,
  so the remote rule had nothing to say and the default answered — inside the work tree. A
  Claude Code session started there inherited the personal `GH_TOKEN` and
  `GITHUB_PERSONAL_ACCESS_TOKEN`; its Bash-tool shells (`zsh -c`, no `.zshrc`) kept them,
  and the GitHub MCP plugin's bearer header was fixed to them at startup, so every private
  work repository 404'd for the life of the session (2026-09-09). `GH_ACCOUNT_PATH_ROUTES`
  answers exactly that case and only that case — a directory with a GitHub remote is still
  the remote's to decide, so a personal repository under the work tree stays personal, as
  git signs it.
- **`printf > file` truncates before it writes.** The refresher runs on every interactive
  shell start and rewrote both cache files in place, so a shell starting while another
  shell's refresher was mid-write read an *empty* token and started unpinned — and a Claude
  Code session launched from it carried no GitHub credential at all. herdr and Herdmates
  start several panes at once, which is that state. `_gh_cache_write` writes a temp and
  renames it into place: a reader sees the old token or the new one, never nothing. The
  chmod before the rename guarantees the live file's mode; the `umask 077` only closes the
  moment before it, inside a 700 directory, and is deliberately not what the rows measure.
  Independent review then found two more traps in the writer, both now pinned: the temp
  was named by `$$.$RANDOM`, and **both are inherited unchanged across a zsh fork**, so the
  disowned shell-start refresher and a foreground `gh-refresh-tokens` shared one name and
  the loser printed a false ✗ (`sysparams[pid]` is the real PID); and `mv -f` onto a
  *directory* moves into it and succeeds, so a directory at the cache path got a live token
  inside it and a ✓ (refused now, as `main`'s writer refused it). The state table tells a
  replace from a truncate by the live file's inode — which only holds with one fixture HOME
  per row, because a leftover refresher from an earlier row can free the recorded inode and
  hand it straight back to the new temp.
- **A deduplicated table hides a route.** `_gh_configured_dirs` deduplicates by config dir,
  and on the shipped configuration the path route names the *same* dir as the owner route —
  so the path table vanished from `gh-doctor` entirely, and a mistyped prefix was a silently
  inert route under a fully green report: the exact fault the table check exists to name,
  two lines above the code that hid it. A shared dir now carries every reason
  (`route 'quantivly' + path route '~/quantivly'`), and a prefix that does not exist on disk
  is a ⚠ that "can never fire" — a ⚠, not a ✗, because a machine with the work config dir
  and no work tree has nothing to route there and must not carry a permanently red doctor.
  Found by an independent review pass, not by the author.
- **"No GitHub remote" had a fourth case.** A GitHub URL the parser rejects left the owner
  slot empty exactly like a non-GitHub remote did, so it took the path route: a repository
  under the work tree whose only remote is `git@github.com:someone` was pinned to work while
  git signs it personal, with a reason that said "no route matched". `_gh_repo_remotes` now
  records the parse state per remote; `unparsable` counts as a GitHub remote, blocks the path
  table, and the doctor lists it as a ⚠.

State table: `scripts/test-gh-routing.sh` (199 checks, run in CI, hermetic — `gh` is
stubbed, so it needs no network, no keyring and no GitHub account; the stub reproduces the
keyring collapse, which a real `gh` cannot be made to do on demand). Each trap above is a
row, and each is pinned by mutation: reverting the fix in a copy of the tree has to make
the row that names it fail.

## Keeping secrets out of transcripts

**Everything a command prints is recorded, and that is where the credentials went.** An
audit on 2026-09-01 found *both* of this machine's live GitHub tokens in plaintext in five
Claude Code session transcripts — two written days earlier, matched by SHA-256 against the
live values, so not a historical artifact. Transcripts are conversation context, so those
values had also left the host.

No single dramatic mistake produced this. Ordinary diagnostics do it: `ps` showing a
process launched with `-e GH_TOKEN=…`, a `printf` of `$GH_TOKEN`, a bare `gh auth token`.

**Rotation is the wrong loop to optimise.** For GitHub it is browser-only — `gh auth` has
no `revoke`, `/authorizations` and `/applications/grants` are 404 (the API was removed in
2020), and the endpoints that can revoke need the OAuth *app's* client secret, i.e. you
would have to be GitHub. `gh auth logout` looks like rotation and is not: it drops the
local copy while the leaked value stays valid. So rotation is manual, and it does nothing
about the next capture.

Two pieces attack the emission instead:

- **`scripts/redact-secrets.sh`** — a stdin→stdout filter. **Two rules, because either
  alone leaks.** Shape matching (`gho_…`, `sk-ant-…`, `AKIA…`) finds a credential anywhere,
  including bare in prose, but cannot know that `CLAUDE_CODE_MESSAGING_TOKEN=b7dc…` is a
  secret — 32 hex characters is also every short git SHA. Name matching (`…TOKEN=`,
  `…SECRET=`) catches those in the `VAR=value` shapes an env dump produces, without
  false-positiving on arbitrary hex. That gap was found by running the pair against a real
  `printenv` and seeing what survived.
- **`claude/hooks/secret-emission-guard.sh`** — a `PreToolUse` hook (matcher `Bash`) that
  **refuses** the handful of command shapes that print credentials unless piped through the
  redactor: `gh auth token`, `gh auth status --show-token`, `ps` with full command lines,
  `pgrep -a`, a bare `env`/`printenv`, and reads of `/proc/*/cmdline|environ`.

Design decisions that are load-bearing, not preferences:

- **Deny, not ask.** The remedy is mechanical (append `| redact-secrets`), so a prompt
  would only train the human to click through — and an `ask` on commands an agent runs
  constantly makes the guard the most irritating thing on the machine.
- **Fail open, always.** Bad JSON, no `jq`, an unreadable payload, *or the hook file not
  being deployed yet* — all allow. A hook that breaks the shell when it breaks gets
  disabled wholesale, taking its protection with it. The registration in
  `~/.claude/settings.json` carries its own `[ -r "$f" ]` guard for exactly this: the file
  arrives via dotbot, so it is absent whenever the checkout is mid-deploy or on a branch
  without it, and registering it without that guard put `exit 127` on **every** Bash call
  in every session on the box until it was fixed.
- **Most of the state table asserts what it must NOT block.** `ps -o comm=`,
  `env -u GH_TOKEN … gh api user`, `printenv GH_CONFIG_DIR`, and
  `git commit -m "stop ps aux leaking"` all have to pass — quoted strings are stripped
  before matching so a command that merely *mentions* a shape is not refused. A false
  positive costs the entire guard; a miss costs one redaction.
- **It is a papercut guard, not a boundary.** Any command can print a secret and this knows
  about seven shapes. The real fixes are shorter-lived credentials (a fine-grained PAT with
  an expiry, so a leak decays on its own) and narrower scopes — both `gh` tokens here carry
  `admin:public_key`, the scope that lets a leak plant an SSH key surviving revocation.
- **Every original rule caught a command printing a secret it FETCHED; none caught one
  printing a FILE — and this file's own Security Rules send every secret to
  `~/.zshrc.local`.** So the guard covered every emission shape except the documented home
  of all of them. On 2026-09-07 an agent ran `tail -8 ~/.zshrc.local` to find where to
  append a `pathadd` line; the tail of that file held a live `LINEAR_API_KEY` and a
  `NOTION_PAT`, both reached the transcript, and both had to be rotated — the same class as
  the incident that created the hook, six days later. The rule added for it fires on
  `~/.zshrc.local`, `~/.gitconfig.local`, `~/.backup.local` and `~/.claude/.credentials.json`
  and **needs two conditions, whose split is the whole design**: the PATH matches on the raw
  command (`$probe` has quoted strings stripped, so `cat "$HOME/.zshrc.local"` — the most
  natural spelling — would escape a `$probe` match), while the VERB matches on `$probe`.
  Path-alone on the raw command refuses `git commit -m "move flyctl to ~/.zshrc.local"`, a
  message merely *naming* the file, which is the false positive that costs the whole guard.
  Metadata-only commands (`ls`, `stat`, `test -f`, `wc`, `readlink`) print no content and are
  deliberately not verbs. A `python3` heredoc that opens the file is not caught either: it
  prints nothing by default, and refusing it would block ordinary edits to the very file
  people are told to keep their secrets in.
- **The remedy the guard names did not remedy.** Immediately after the rule above shipped,
  running its own suggested `tail ~/.zshrc.local | redact-secrets` against the real file
  printed the `NOTION_PAT` in full. `NOTION_PAT` matched no name pattern (the alternation is
  `TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|CREDENTIAL`) and `ntn_` matched no shape pattern, so
  it fell through both rules — the exact case the redactor's header says two rules exist to
  prevent. **Worse than a plain miss:** the deny message points at the redactor, so the
  failure mode is guard blocks, human adds the pipe, token prints anyway, and it looks
  handled. Fixed by `ntn_` and `lin_api_` shape rules plus a `_PAT=` name rule. That last one
  is its OWN `-e`, never an entry in the alternation: the alternation is followed by
  `[A-Z0-9_]*=`, so any PAT inside it has the trailing class absorb what follows and redacts
  `SOME_PATH=`, `MY_PATHS=` and `COMPATIBLE=` (measured, both for `PAT` and `_PAT`). `PATH=`
  and `PATTERN=` are safe for a different reason — the `=` adjacency — and only a rule
  allowing PAT anywhere before the `=` reaches them. Six mutations, all pinned; the reasoning
  above was wrong on first writing (it blamed `PATH=` for what actually breaks `SOME_PATH=`)
  and the state table is what corrected it.
- **The quote-stripping has a hole of its own, found the same day and NOT fixed.** A heredoc
  body is not a quoted string, so a command whose heredoc merely *quotes this guard's own
  source* trips the `/proc/*cmdline*` rule — which happened while editing the guard, and the
  workaround is the documented one (pipe through the redactor). Worth knowing before assuming
  a refusal means the command really would have leaked.

**`.gitignore`'s `**/*secret*` rule excluded all three of these files**, whose entire job
is secrets — and `git add -A` skips ignored paths **silently**, so `git commit`, `git push`
and `gh pr create` all reported success with the content absent. Only CI caught it, via
`No such file or directory` on the test script and dotbot's `Nonexistent target` on the
hook. Three negations after the rule fix it (`!scripts/redact-secrets.sh` etc.), and the
check that matters is `git add --dry-run`, not `git check-ignore -v` — the latter exits 0
when a path matches *any* rule, negations included, so it reports "matched" for a file that
is not ignored at all and reads as the opposite of the truth.

**Like the sidebar publisher, `./install` only does half.** dotbot puts the hook file in
`~/.claude/hooks/`; it does nothing until it is also registered as a `PreToolUse` hook in
`~/.claude/settings.json`, which is user-level and not in this repo.

State table: `scripts/test-secret-guard.sh` (79 checks, run in CI, hermetic — the fixture
credentials are assembled at runtime so this file contains no string that would trip the
`gitleaks` pre-commit hook over its own test data).

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
Config: `config/herdr/config.toml` → `~/.config/herdr/config.toml`. Adopting it:
[docs/HERDR_GUIDE.md](docs/HERDR_GUIDE.md). How this repo's integration works, fails and is tested —
both install paths, the systemd unit and its drop-in, the sidebar publisher, and the evidence behind
every rule below: [docs/HERDR_INTERNALS.md](docs/HERDR_INTERNALS.md). The shell layer is
`zsh/zshrc.herdr`, safe to source alone.

- **Every layer fails silently.** `herdr config check: ok` means the file parses, not that anything
  works. After a config edit, `herdr server reload-config | jq '.result.status'` must say `applied` —
  an error anywhere in `[ui]` reverts all of `[ui]` and reports `partial`. Verify each binding at the
  keyboard; never generalise from one working chord to a class.
- **Setting a key field REPLACES it wholesale.** Re-list any stock default you still want, and diff
  against `herdr --default-config` after any keymap edit.
- **Never run bare `herdr`** from a script or an agent — it attaches a client and hijacks the UI.
- **Never start or restart the herdr server from a pane or a Claude session** — every pane inherits
  the environment of whoever launched it. Use `systemctl --user restart herdr-server.service`.
- **Never `systemctl reenable` a dotbot-installed unit**: its disable half deletes the unit's symlink
  into this checkout. `enable` plus pruning the stale `.wants` link is safe; `./install` reconciles.
- **Close the panes you spawn once you have their output** — memory is the binding constraint on this
  box. `hdespawn <pane-id>` (the exact form), `hreap --close --mine`. Never close panes you did not
  create unless asked.
- **An `hreap` row reading `DET no` / `unknown`, idle for hours, may be a herdmates teammate** still
  working for a live lead — `herdr pane process-info` shows a versioned binary name. Reap a teammate
  with `TaskStop` from its lead, never by closing its pane.
- **Closing one terminal in the spaces sidebar can close the whole space** (a `tab.close`), with no
  undo. Transcripts survive: `claude --resume <session-id>` from the original cwd.
- **Claude's trust dialog defaults to "No, exit".** Answer it on the agent surface after detection
  (`herdr agent send-keys <pane> down`, then `enter`). `herdr agent wait` cannot wait *for*
  detection — poll.
- **For a plugin CLI, export all three of `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_CONFIG_DIR` and
  `HERDR_PLUGIN_STATE_DIR`** for the plugin you are invoking — herdmates leaks its own into lead
  sessions, and `HERDR_PLUGIN_ID` is what says whose the other two are.
- **The server's `PATH` is a snapshot taken when it started.** Link a tool into `~/.local/bin` to make
  it visible without a restart.
- **`clauth start <profile>` bypasses `claude()`**, so it is not a team lead: `clauth <profile>` then
  `claude`.
- **A modular adopter** runs `./install --herdr` (five links, nothing else),
  `scripts/herdr-claude-wire.sh`, and `scripts/verify-tools.sh --herdr` as the one check.

## Claude Code accounts & MCP (`claude-doctor`)

The mechanism and every incident behind these rules — the credential race, per-session account
dirs, clauth's writes, suspend storms, `auth_broken` — are in
[docs/CLAUDE_ACCOUNTS.md](docs/CLAUDE_ACCOUNTS.md); how an account is chosen is in
[docs/CLAUDE_ACCOUNT_PICKER.md](docs/CLAUDE_ACCOUNT_PICKER.md); what to run and click is
[docs/CLAUDE_ACCOUNT_MCP.md](docs/CLAUDE_ACCOUNT_MCP.md); which plugins run where is
[docs/CLAUDE_SETUP.md](docs/CLAUDE_SETUP.md). To diagnose a logout, a dropped MCP server or a
session on the wrong account, use the [claude-accounts](.claude/skills/claude-accounts/SKILL.md) skill.

- **Run `claude-doctor` first, and never `clauth <profile>` while it says the stored copy DIFFERS
  from the live credential.** Refresh tokens rotate server-side; clauth restores its stored copy,
  and a superseded token logs out every session on that account at once.
- **Prefer `claude-as <profile>` to `clauth <profile>`** — it changes nothing outside your session.
- **Every session gets its own account dir** (`claude()` does this by default). An account dir's
  `.credentials.json` is a **symlink** into `~/.clauth/profiles/<p>/`, never a copy — a copy is an
  independent holder of one grant. **Never relink one by hand**: Claude Code writes atomically and
  replaces the link, and only the reconciler (`scripts/claude-account-dirs.sh --reconcile`, a
  2-minute timer) may decide which side is live.
- **Name the account from `CLAUDE_CONFIG_DIR`** — not from the sidebar, not from `clauth which`
  (which reports credential ownership, answered from `$CLAUDE_CONFIG_DIR`, not the active profile).
- **Never put MCP or auth env vars in `~/.claude/settings.json`'s `env`**: clauth clears it on every
  profile switch. Put them in `zsh/zshrc.herdr`.
- **A standing `auth_broken` is reported, never cleared out of band.** The remedy is
  `clauth login <profile>`; a later successful *fetch* does not clear it on clauth 0.15.1.
- **Access tokens live 8 h.** A suspend that outlasts the validity a token had *left* expires every
  account at once; expect clauth to quarantine accounts on resume.
- **Accounts are chosen per directory** from `~/.config/claude-tenants.zsh`; `claude-pick --explain`
  shows which one a directory would bill and why. A spent weekly window demotes, never refuses.
- **In a Claude Code Bash-tool shell, single-underscore functions do not exist** — the shell
  snapshot drops them, so `claude`/`hspawn` are defined and their `_helpers` are not. A guard whose
  failure mode is a *match* rather than an error is the one to audit.
- **Checkers here fail by looking clean.** Read a JSON value's type before indexing it; test exit
  status, never the emptiness of a pipeline's output (a hash of nothing matches every hash of
  nothing); `${VAR:-x}` substitutes for *empty* as well as unset; a test stub is a claim about the
  real tool; and no diagnostic ever prints a credential.

## GNOME Desktop Configuration

Clean, modern GNOME (dark `Yaru-prussiangreen-dark`, floating autohiding **bottom** dock, empty desktop, tmux-friendly keys) applied reproducibly via **stock GNOME/Yaru only** — no third-party extensions or themes.

- **Mechanism:** curated `gsettings` script (schema-validated, idempotent, reviewable), **not** `dconf dump` (which drags in machine-specific cruft). GNOME has no first-party export/import.
- **Source of truth:** `scripts/apply-gnome-settings.sh` (portable core). Runs automatically during `./install` on GNOME only (no-op on servers / other desktops).
- **Machine-specific layer:** `~/.gnome-settings.local` (dock favorites, custom launch keys) — mirrors the `~/.zshrc.local` pattern, sourced by the apply script, never overwritten. Create with `gnome-init`. It runs LAST and silently wins, so a line here can undo one the portable layer just applied: `grp:alt_shift_toggle` was re-enabled that way on every run, killing all four of herdr's `alt+shift+arrow` bindings while `gnome-apply` printed two ✓ lines three apart and `gsettings get` showed the override as if it were the applied value. An overriding set now prints `(overrides <previous>, set above)` — a note, not a warning, since overriding is what the layer is for.
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
gh-doctor            # Which GitHub account is gh ACTUALLY using here? (--offline)
claude-doctor        # Claude auth + MCP health; run BEFORE 'clauth <profile>'
claude-as <profile>  # claude on a named account: isolated AND still a team lead
claude-pick          # which account would this directory bill? (--explain --json --strict)
scripts/claude-account-dirs.sh --all   # (re)build every profile's persistent config dir
scripts/redact-secrets.sh  # Filter secrets out of anything before it is printed
tool_status          # Check installed tools
herdr-help           # In-shell herdr cheat sheet (hspawn/hreap/clauth)
build-limits         # Show active build/test worker caps (see zshrc.buildlimits)
alacritty-init       # Set up Alacritty config (new machine)
qmux                 # Per-server tmux sessions for dev/staging/demo (Alt+w to switch)
dotfiles-doctor      # Is the live config the reviewed config? (--fetch to check the real remote)
dotfiles-work <br>   # Create/enter a worktree so the primary checkout stays on main
git -C ~/.dotfiles merge --ff-only origin/main   # DEPLOY (after a fetch). NOT `git pull`
gnome-apply          # Apply curated GNOME desktop config (idempotent)
xdg-repair           # Fix/guard ~/Desktop, ~/Documents, ... XDG dirs (idempotent)
gnome-init           # Create ~/.gnome-settings.local (dock favorites, launch keys)
gnome-status         # Summary of GNOME version, theme, dock, extensions
scripts/herdr-claude-wire.sh    # Wire Claude Code to herdr (statusLine + agent skill file)
scripts/verify-tools.sh --herdr # The one check a modular herdr adopter runs
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
- **Git auth:** `gh-doctor` (declared vs *effective* account — `gh auth status` reports only the declared one), then `gh auth login`
- **Claude logged out / MCP servers dropping:** `claude-doctor`. These are usually the *same* fault — the claude.ai connectors ride on the login token. Never run `clauth <profile>` while the doctor reports the stored copy DIFFERS from the live credential — and prefer `claude-as <profile>`, which changes nothing outside your own session. If several sessions were logged out *at the same moment*, the cause is a write to the shared file, not your session: check the doctor's concurrency groups for how many are still on it.
- **Backups:** `backup-doctor` (full-chain correctness — start here), `backup-status` (quick health), `systemctl list-timers | grep restic`, `resticprofile -c /etc/resticprofile/profiles.toml show` (validate config)
