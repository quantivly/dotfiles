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
it; that is the failure mode, and it is silent from every other angle. Every page under `docs/`
is indexed, with what it is and who it is for, in [docs/README.md](docs/README.md) — a **guide**
(for someone adopting or operating a thing) or a **maintainer's record** (the evidence behind a
rule that stays here). New evidence goes to a record, never back into this file.

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

`zshrc` sources focused modules, each safe to read alone:

| module | purpose |
|---|---|
| `zshrc.history` | 50k commands, timestamps, deduplication |
| `zsh/functions/*.sh` | utility functions, 5 modules (see [Function Modules](#function-modules)) |
| `zshrc.aliases` | portable git, docker, python and system aliases |
| `zshrc.conditionals` | dispatcher → `.tools` (bat, eza, ripgrep, zoxide), `.fzf`, `.plugins` (mise, direnv, forgit) |
| `zshrc.buildlimits` | build/test worker caps, so parallel agent sessions can't each claim every core |
| `zshrc.herdr` | the herdr agent-workspace layer — portable, split out of `zshrc.company` by DO-555 so herdr can be adopted without the work half |
| `zshrc.company` | work-specific (Quantivly) |
| `~/.zshrc.local` | machine-specific secrets and settings, **NOT** in git |

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
- `~/.config/alacritty/alacritty.toml` — the CSI u key entries here are what make the Ctrl+Shift+letter tmux bindings work. Template: `examples/alacritty.toml.template`, install with `alacritty-init`; the live config does **not** track the template afterwards. **Probe every chord you bind** with `scripts/herdr-keyprobe.sh` and never infer from one working letter that the class works — some Ctrl+Shift+letter combos are swallowed by an Alacritty built-in default, and the symptom is a key-release event with no matching press. Override with `action = "ReceiveChar"` ("treat as unbound"), not a hardcoded `chars` CSI u string. Which chords, and the evidence: [docs/TERMINAL_AND_KEYS.md](docs/TERMINAL_AND_KEYS.md).
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

Locale → p10k instant prompt → oh-my-zsh → p10k theme → `zshrc.history` → `zsh/functions/*.sh` →
`zshrc.aliases` → `zshrc.conditionals` (→ `.tools`, `.fzf`, `.plugins`) → `zshrc.buildlimits` →
`zshrc.herdr` → `zshrc.company` → `~/.zshrc.local` → PATH → the live-config guard.

Four orderings are load-bearing: **conditionals load after aliases**, so an installed tool's
configuration wins; **`github.sh` and `claude.sh` load after `system.sh`**, which defines the shared
`_doctor_*` emitters they use; **`zshrc.herdr` loads before `zshrc.company` and independently of
it**, so a modular adopter can source that one file and nothing else; and **the live-config guard
runs on the FIRST prompt** via a one-shot `precmd` hook rather than at load time, because output
during initialization lands inside p10k's instant-prompt warning box.

The full annotated order: [docs/SHELL_LAYOUT.md](docs/SHELL_LAYOUT.md).

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

**`~/.config/mise/config.toml` is a SYMLINK to `~/.dotfiles/.mise.toml`, not a copy** — `mise use -g`
writes *through* it to the repo file, so the two cannot diverge, which is the whole point.
Per-project overrides go in a project-root `.mise.toml` and need `mise trust`.

**Run `scripts/verify-tools.sh` after any mise change.** Two failure modes here are stable, silent
and self-perpetuating: `./install` keeps a pre-existing *differing* `config.toml` forever after one
warning, and a version pin that no longer exists in its backend "installs" successfully while
producing no binary at all. The first one cost this machine a working `git diff` for as long as
nobody looked.

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
- **Install Alacritty from apt, not snap** — the snap bundles its own stale Mesa and silently falls back to software rendering, measured here at 24.5% of a core sustained at idle.
- **`$TERM` follows the terminfo, not the config**, so it depends on how Alacritty was *installed* (`alacritty` from apt, `xterm-256color` from the snap). `tmux.conf` sets `terminal-features` for both, so either works.
- Ctrl+Shift+Arrow works natively in tmux; Ctrl+Shift+**letter** needs the Alacritty CSI u entries above plus tmux `extended-keys`.
- tmux `extended-keys` and `terminal-features` are server-level — they need `tmux kill-server`, not a config reload.

How each was measured, and how to verify it on a running process: [docs/TERMINAL_AND_KEYS.md](docs/TERMINAL_AND_KEYS.md).

## Important Patterns

### pathadd Function

Always use `pathadd` for safe PATH additions:
```bash
pathadd "${HOME}/.local/bin"  # Checks existence, prevents duplicates
```

### Tool Availability Checks

Use `command -v tool` directly in `zshrc.conditionals` and standalone scripts, and the
`has_command()` wrapper inside functions for readability. Both cost ~1-2ms, so nothing is cached.

- **One name per call.** `command -v a b c` takes a single operand in POSIX sh, and the shells
  disagree about the rest: measured here, `command -v bash nosuchtool` prints only `/usr/bin/bash`
  and exits **0** in bash and dash, and **1** in zsh — so the same line is a silent pass with two
  tools missing in one shell, and an unexplained failure naming none of them in the other. Loop, or
  call it once per tool.

The two patterns with examples, the naming convention and the benchmark that removed the tool cache:
[docs/SHELL_LAYOUT.md](docs/SHELL_LAYOUT.md).

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

**`GH_CONFIG_DIR` does not isolate the credential, and `gh auth status` will not tell you.** gh keys
its tokens in the system keyring by **host**, not by config dir, so `gh auth status` reports the
account a config dir *declares* while an API call resolves to another one — and with `GH_TOKEN` unset
it falls back to the **work** account, in any directory. Never conclude which account is in play from
configuration; that inference *is* the bug. Run `gh-doctor`, which answers from a real `GET /user`.

- **Routing follows the repo REMOTE, not `$PWD`**, and **any** remote matches, not just `origin`.
  Precedence: remote-owner route → path route → `GH_ACCOUNT_DEFAULT_DIR`, with a git error stopping
  before all three rather than falling through to the personal default.
- **`GH_ACCOUNT_PATH_ROUTES` is consulted only for a directory with NO GitHub remote.** A GitHub
  remote whose owner matches no route means *personal, by remote*.
- **Every directory pins an account by exporting `GH_TOKEN`; the keyring never decides.** `GITHUB_TOKEN`
  is cleared wherever `GH_TOKEN` is set, on the success path too — gh outranks it, the GitHub MCP
  server and `act` do not. `GH_ACCOUNT_ROUTING_OFF=1` is the one escape hatch.
- **A Claude Code Bash-tool shell is unrouted** — `zsh -c`, no `.zshrc`, so it inherits the session
  environment verbatim and the GitHub MCP plugin fixes its `Authorization` header from it at startup.
  Run writes as `zsh -ic 'gh …'`; setting `GH_CONFIG_DIR` by hand does not route.

Configuration is data in `zsh/zshrc.company` — `GH_ACCOUNT_ROUTES` (owner-glob=config-dir),
`GH_ACCOUNT_PATH_ROUTES` (absolute-prefix=config-dir), `GH_ACCOUNT_DEFAULT_DIR`. **Double** quotes: a
single-quoted `$HOME` is a literal, and the route then silently never fires.

```bash
gh-doctor                 # this directory: declared vs EFFECTIVE account, and what decided
gh-doctor --offline       # config only — every network answer marked NOT CHECKED
gh-refresh-tokens         # refresh the per-account token cache
```

The keyring measurements and every trap found here, each of which produced a green tick or a confident
wrong answer: [docs/GH_ACCOUNT_ROUTING.md](docs/GH_ACCOUNT_ROUTING.md). State table:
`scripts/test-gh-routing.sh` (207 checks, hermetic, run in CI).

## Keeping secrets out of transcripts

**Everything a command prints is recorded, and that is where the credentials went.** An audit on
2026-09-01 found both of this machine's live GitHub tokens in plaintext in five Claude Code session
transcripts, put there by ordinary diagnostics — `ps` showing a `-e GH_TOKEN=…` launch, a `printf` of
`$GH_TOKEN`, a bare `gh auth token`. Rotation is the wrong loop to optimise: for GitHub it is
browser-only, `gh auth logout` leaves the leaked value valid, and none of it touches the next capture.

- **Pipe anything that might print a credential through `scripts/redact-secrets.sh`.** It needs **two**
  rule sets because either alone leaks: shapes find a credential anywhere, including bare in prose;
  names (`…TOKEN=`, `…SECRET=`, `_PAT=`) catch the ones no shape describes.
- **`claude/hooks/secret-emission-guard.sh` (`PreToolUse`, `Bash`) refuses** the shapes that print
  credentials unless piped through the redactor: `gh auth token`, `gh auth status --show-token`, `ps`
  with full command lines, `pgrep -a`, a bare `env`/`printenv`, reads of `/proc/*/cmdline|environ`, and
  reads of the files this file sends every secret to (`~/.zshrc.local`, `~/.gitconfig.local`,
  `~/.backup.local`, `~/.claude/.credentials.json`). It **denies** rather than asks, and **fails open**
  — a hook that breaks the shell when it breaks gets disabled wholesale.
- **A refusal is not proof the command would have leaked, and passing is not proof nothing did.** It
  knows a handful of shapes, and the remedy it names once printed a `NOTION_PAT` in full. Papercut
  guard, not a boundary.
- **`./install` only does half** — dotbot places the hook file; it does nothing until it is registered
  in `~/.claude/settings.json` (user-level, not in this repo), with its own `[ -r "$f" ]` guard, or a
  mid-deploy checkout puts `exit 127` on **every** Bash call on the box.
- **`.gitignore`'s `**/*token*`, `**/*secret*` and `**/*password*` rules exclude the very files whose
  job is secrets**, and `git add -A` skips ignored paths **silently** — commit, push and PR all report
  success with the content absent. Check new files with `git add --dry-run`, never `git check-ignore -v`
  (it exits 0 for a negated path too, reading as the opposite of the truth).

The audit, the reasoning behind each rule and every hole since found in them:
[docs/SECRET_EMISSION.md](docs/SECRET_EMISSION.md). A secret already committed:
[docs/SECURITY_INCIDENTS.md](docs/SECURITY_INCIDENTS.md). State table: `scripts/test-secret-guard.sh`
(182 checks, hermetic, run in CI).

## Tmux Configuration

Prefix-free tmux setup with Terminator-style keybindings. Prefix: Ctrl+s.

**Essential bindings:** Ctrl+Shift+E/O (split), Ctrl+Shift+W (close), Ctrl+Shift+Arrow (navigate), Ctrl+Alt+Arrow (resize), Alt+z (zoom), Ctrl+Shift+T (new window)

**Popup windows:** Alt+o (file finder), Alt+s (live grep), Alt+w (session picker), Alt+g (lazygit), Alt+y (yazi popup), Ctrl+b (yazi side pane toggle), Ctrl+Shift+F (tmux-thumbs quick-copy)

**Key notes:**
- No auto-start — launch manually with `tmn <session>`
- Alacritty coupling — Ctrl+Shift+letter bindings require CSI u entries in `~/.config/alacritty/alacritty.toml` (template: `examples/alacritty.toml.template`, install with `alacritty-init`)
- `extended-keys` and `terminal-features` are server-level — require `tmux kill-server`, not just config reload
- Plugins: tmux-resurrect, tmux-continuum, tmux-thumbs, tmux-open, tmux-dispatch
- Claude Code runs in fullscreen rendering (alt-screen) to avoid scrollback corruption — its output isn't in tmux copy-mode; scroll/search inside Claude (`Ctrl+o`, then `[` to dump to scrollback). See [docs/CLAUDE_CODE_TMUX.md](docs/CLAUDE_CODE_TMUX.md)

See [docs/TMUX_LEARNING_GUIDE.md](docs/TMUX_LEARNING_GUIDE.md) (nested tmux: F12) and [examples/tmux-workflows.md](examples/tmux-workflows.md) for comprehensive guides.

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
- **`clauth start <profile>` bypasses `claude()`**, so it is not a team lead (`clauth <profile>` then
  `claude`); it is refused for a profile another machine owns (`CLAUDE_TENANT_MACHINE_OWNED`).
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
  shows which one a directory would bill and why. A spent week demotes in the ranker; the gate
  refuses it unless spend headroom is left.
- **In a Claude Code Bash-tool shell, single-underscore functions do not exist** — the shell
  snapshot drops them, so `claude`/`hspawn` are defined and their `_helpers` are not. A guard whose
  failure mode is a *match* rather than an error is the one to audit.
- **Checkers here fail by looking clean.** Read a JSON value's type before indexing it; test exit
  status, never the emptiness of a pipeline's output (a hash of nothing matches every hash of
  nothing); `${VAR:-x}` substitutes for *empty* as well as unset; a test stub is a claim about the
  real tool; and no diagnostic ever prints a credential.

## GNOME Desktop Configuration

Clean, modern GNOME (dark `Yaru-prussiangreen-dark`, floating autohiding **bottom** dock, empty desktop, tmux-friendly keys) applied reproducibly via **stock GNOME/Yaru only** — no third-party extensions or themes.

- **Mechanism:** a curated, schema-validated, idempotent `gsettings` script — **not** `dconf dump` (GNOME has no first-party export/import). `scripts/apply-gnome-settings.sh` is the portable core; `~/.gnome-settings.local` (`gnome-init`) is the machine-specific layer. `./install` runs them on GNOME only; `gnome-apply` re-runs them.
- **The `.local` layer runs LAST and silently wins**, so a line there can undo one the portable layer just applied — that is how `grp:alt_shift_toggle` killed all four of herdr's `alt+shift+arrow` bindings while `gnome-apply` printed two ✓ lines. An overriding set now prints `(overrides <previous>, set above)`.
- **Tmux integration:** the script moves GNOME workspace switching off `Ctrl+Alt+Arrow` onto `Super`-based shortcuts, so tmux pane-resize works.
- **Wayland:** changes apply live, dock relayout is guaranteed after one log out / log in, and `Alt+F2 r` / `Meta.restart` are X11-only — never use them.
- **`xdg-repair`** (`scripts/repair-xdg-user-dirs.sh`) keeps `~/Desktop`, `~/Documents`, … real directories so `snapd-desktop-integration` cannot turn them into broken self-referential symlinks. Idempotent; `./install` runs it on graphical workstations. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

See [docs/GNOME_CONFIGURATION_GUIDE.md](docs/GNOME_CONFIGURATION_GUIDE.md) for the full guide.

## Backup & Restore

Encrypted **3-2-1 backups**: **restic** (engine) + **resticprofile** (orchestrator), to an external
HDD (when docked) and **Backblaze B2** (offsite). `backup` in `core.sh` is a *separate* single-file
utility — the system commands are all `backup-*`.

- **Start at `backup-doctor`, not `backup-status`.** It asserts the whole chain is *correct* — perms,
  config drift against `~/.dotfiles`, snapshot age, B2 size and prune staleness, kit freshness — and
  exits non-zero on FAIL. `restic check` proves *intact*; `backup-drill` proves *restorable*.
- **`resticprofile/profiles.toml` and `udev/99-backup-external.rules` are COPIED root-owned to `/etc/`
  by `backup-setup`, never symlinked** (root runs them). Editing the repo copy alone changes nothing.
- **Order the run `After=` the mount unit, never `Requires=`/`RequiresMountsFor=`** — those make an
  undocked disk a *failed* unit every 6h. An unmet `ConditionPathExists` makes systemd **skip** the
  unit, and a skipped unit is not a failed one: no error, no ping, nothing in `--state=failed`.
- **Never `render … | sudo tee /etc/…`** — `tee` truncates before the renderer's exit status is known,
  so a failed render installs a zero-byte unit that "succeeds". Use `render_install`. An unresolved
  `__BACKUP_*__` placeholder is a hard error, never a blank.
- **The external mount point is a `dirname` of a hand-edited path, so it is guarded before use**
  (`external_mount_point_sane`, tri-state — "could not determine" refuses, and every consumer is gated
  on it including `restic init`). One level too shallow gives `/media/<user>`; a typo gives `$HOME`,
  and the mount then *succeeds*, over the user's home, at every boot.
- **On restore, regenerate — do not restore — `/etc/fstab`, `/etc/crypttab`, `/etc/machine-id` and
  `ssh_host_*`.** `backup-restore-system` bakes those four excludes in so an `/etc` restore can't
  break boot.

Commands: `backup-init`, `backup-setup`, `backup-now`, `backup-status`, `backup-doctor`,
`backup-drill`, `backup-snapshots`, `backup-check`, `backup-restore`, `backup-restore-system`,
`backup-mount`, `backup-unlock`, `backup-prune`, `backup-luks-header`, `backup-kit`.

Setup, the DR runbook and the verification regimen:
[docs/BACKUP_AND_RESTORE_GUIDE.md](docs/BACKUP_AND_RESTORE_GUIDE.md). Why each guard exists and every
trap found in them: [docs/BACKUP_INTERNALS.md](docs/BACKUP_INTERNALS.md). State table:
`scripts/test-backup-external.sh` (99 checks, root-free, run in CI).

## Audit Tripwire (broadcast kills)

A two-line **auditd** rule — `audit/99-logout-catch.rules`, **copied** root-owned to
`/etc/audit/rules.d/` by `audit-setup` — recording any real `kill(-1, sig)`, which on a desktop is the
entire graphical session. A broadcast kill otherwise leaves a perfectly orderly teardown: no crash, no
OOM, nothing in the journal. With the rule the record names the sending process, exe, cmdline, parent.

- **`a0` must stay `0xFFFFFFFF`, never widened to 64 bits.** The rule field is u32 and x86-64
  zero-extends a C `int` of `-1`, so a 64-bit constant matches nothing — and a rule that matches
  nothing is indistinguishable from a clean machine.
- **"Armed" is three independent things**, each able to be false while the others look fine: rules in
  the kernel (`auditctl -l`), auditing on (`enabled != 0`), and a daemon persisting to disk
  (`pid != 0`). `auditctl -l` lists rules happily with auditd stopped — and `ausearch`, so
  `audit-sweeps`, is then blind forever with no error. `audit-setup` and `audit-status` assert all three.
- **auditd takes AppArmor denials out of the journal** — use `sudo ausearch -m AVC` afterwards.
- Expect a benign burst from `systemd-shutdown` (pid 1) at every reboot.

Commands: `audit-setup` (`--yes` skips the install prompt), `audit-status` (non-zero on fail),
`audit-sweeps` (default: last 24h). Why the scope is `a0 == -1` only, and each silent-failure mode
reported separately: [docs/AUDIT_TRIPWIRE.md](docs/AUDIT_TRIPWIRE.md).

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
