# Troubleshooting

## Slow zsh startup

```bash
time zsh -i -c exit  # Profile performance (target: <250ms)
# Disable slow plugins in ~/.zshrc.local: plugins=(${plugins:#poetry})
# mise is fast (~5-10ms). If using nvm/pyenv, see docs/MIGRATION.md
```

**Startup caching:** Quanticli paths, GH tokens, and PR numbers are cached to disk and refreshed in background `&!` jobs. This avoids ~600ms+ of synchronous subprocess calls. Cache locations:
- `~/.cache/quanticli-paths/` — `data`, `test`, `workspace` files
- `~/.cache/gh-token-cache/` — token files (chmod 600)
- `~/.cache/p10k-pr-cache/` — PR numbers per repo/branch

Manual refresh: `qcache-refresh`, `gh-refresh-tokens`

**First shell after fresh install:** Env vars are empty until background jobs complete (~500ms). Subsequent shells read from cache instantly.

## Powerlevel10k warning about console output

If you see a warning about "console output during zsh initialization" caused by direnv:
- The dotfiles suppress direnv messages via `DIRENV_LOG_FORMAT=""`
- If you still see output, check for `echo` statements in project `.envrc` files
- Ensure `.envrc` files use redirects and `--quiet` flags (see examples/envrc-templates/)

## Powerlevel10k PR number not showing

```bash
# Verify gh CLI works
gh pr view

# Manually refresh cache
rm ~/.cache/p10k-pr-cache/$(basename $(git rev-parse --show-toplevel))/$(git branch --show-current)
source ~/.zshrc
```

**Stale PR number** (cache persists after PR closed):
```bash
rm ~/.cache/p10k-pr-cache/$(basename $(git rev-parse --show-toplevel))/$(git branch --show-current)
```

**Implementation:** `_p10k_get_pr_number()` function in `p10k.zsh`

## Function not found

```bash
ls -la ~/.zshrc      # Check symlink
./install            # Re-run installer
zsh -n ~/.zshrc      # Verify syntax
```

## Tool not loading

```bash
command -v toolname  # Check if installed
source ~/.zshrc      # Reload config
```

## mise config not trusted

Trust the config file: `mise trust ~/.dotfiles/.mise.toml`

See the [Trust Configuration](../CLAUDE.md#mise-version-manager) section for full details.

## Command not found after adding tool

```bash
source ~/.zshrc              # Reload
command -v toolname          # Verify installation
echo $PATH | tr ":" "\n"     # Check PATH
```

## Unexpected command behavior

```bash
alias commandname            # Check for alias
type commandname             # See what runs
\commandname                 # Bypass alias
```

## Alias conflicts

```bash
alias                                        # List all aliases
grep -r "alias aliasname=" ~/.dotfiles/      # Find definition
# Override in ~/.zshrc.local with: unalias aliasname
```

## Git authentication issues

```bash
gh auth status   # Check status
gh auth login    # Re-authenticate
```

## Git identity & SSH key routing (work vs personal)

On a dual-identity machine, the work profile (`user.email`, `user.signingkey`, **and** the SSH key used for fetch/push) is selected by the repo's **remote org**, not by where it sits on disk. `~/.gitconfig.local` includes `~/.gitconfig-work` whenever any remote points at the quantivly org, via `includeIf "hasconfig:remote.*.url:…"` (requires **git ≥ 2.36**). This is path-independent, so it works in Atrium worktrees under `~/.atrium/worktrees/`, clones under `~/Projects/`, `/tmp`, etc. `~/.gitconfig-work` org-scopes the transport rewrite (`url."git@github-work:quantivly/".insteadOf`) so quantivly remotes use the work key while personal remotes stay on the personal key.

**Symptom:** a work repo authenticates/commits as personal — e.g. `git push` denied (`Permission to quantivly/<repo>.git denied to <personal-user>`), or commits show the personal email/signature.

**Verify which profile resolves (read-only, no network):**
```bash
git config --show-origin --get user.email   # work => …/.gitconfig-work  *@quantivly.com
git config --get user.signingkey            # work => …Quantivly ; personal => …Personal
git remote get-url --push origin            # work => git@github-work:quantivly/… (work key)
ssh -G github-work | grep -i '^identityfile'  # => ~/.ssh/id_work.pub
git ls-remote --heads origin                # read-only auth probe (no push)
```

**If a work repo resolves to personal:**
- Check git version: `git --version` (must be ≥ 2.36; older git silently ignores `hasconfig`).
- Confirm the rules exist: `git config --file ~/.gitconfig.local --get-regexp '^includeIf'` — expect three `hasconfig:remote.*.url:…quantivly/**` entries → `~/.gitconfig-work`.
- The personal `[user]` block in `~/.gitconfig.local` must come **before** the `includeIf` lines (last-wins). Don't reorder the file.
- Re-provision via dev-setup (`modules/accounts.sh`, dual profile) to (re)wire the rules idempotently.
- New repo with **no remote yet** commits as personal until the quantivly remote is added — add the remote before the first commit, or set a repo-local `git config user.email`.

## GitHub CLI multi-account switching

The `zshrc.company` `chpwd` hook switches `GH_CONFIG_DIR`, `GH_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`, and `CLAUDE_CONFIG_DIR` based on context: a dir is **work** if it lives under `~/quantivly/**` (fast path) **or** its `origin` remote belongs to the quantivly org (`_q_is_work_context`), everything else → personal. The remote check mirrors the git identity routing above, so the gh/Claude account follows the repo even when checked out outside `~/quantivly/`.

**Key gotcha — `gh auth token` keyring lookup:**
- `gh auth token` (no `--user`) returns a shared/default keyring entry, NOT the per-user entry matching the config's `user:` field
- Always use `gh auth token --user <username>` to get the correct per-user token from the keyring
- To get the configured username: `gh config get -h github.com user`

**Key gotcha — `GH_TOKEN` vs `GH_CONFIG_DIR`:**
- `GH_CONFIG_DIR` tells `gh` which config to read, but authentication still goes through the shared keyring
- `GH_TOKEN` env var is the highest-priority auth mechanism — it bypasses both config and keyring
- For reliable multi-account switching, always set `GH_TOKEN` explicitly (not just `GH_CONFIG_DIR`)

**Debugging multi-account issues:**
```bash
# Check which account a token authenticates as
GH_TOKEN="$(gh auth token --user USERNAME)" gh api user --jq '.login'

# Compare default vs per-user token (should match but may not!)
gh auth token                    # shared default — may be wrong
gh auth token --user USERNAME    # per-user keyring entry — correct

# Verify directory-based switching
cd ~ && echo "GH_TOKEN prefix: ${GH_TOKEN:0:15}" && gh api user --jq '.login'
cd ~/quantivly && echo "GH_TOKEN prefix: ${GH_TOKEN:0:15}" && gh api user --jq '.login'
```

**Auth flow (precedence):** `GH_TOKEN` env → `GH_ENTERPRISE_TOKEN` → keyring (via `GH_CONFIG_DIR` config)

## SSH agent forwarding issues (VSCode/remote servers)

**Symptom:** Git operations fail with "Repository not found" after reconnecting to remote server.

**Cause:** SSH_AUTH_SOCK points to a stale VSCode socket that no longer exists.

**Solution:** The dotfiles automatically detect and repair stale sockets on shell startup:
- Validates current SSH_AUTH_SOCK
- Auto-discovers current VSCode socket if stale
- Creates persistent symlink at `~/.ssh/ssh_auth_sock` for tmux/docker

**Verification:**
```bash
echo $SSH_AUTH_SOCK          # Should point to current socket
ssh-add -l                   # Should show your keys
ls -la ~/.ssh/ssh_auth_sock  # Should exist and point to valid socket
git fetch                    # Should work without errors
```

**Manual fix (if auto-repair fails):**
```bash
# Find current VSCode socket
ls -lt /run/user/1000/vscode-ssh-auth-sock-* | head -1

# Export it
export SSH_AUTH_SOCK=/run/user/1000/vscode-ssh-auth-sock-<ID>

# Test
ssh-add -l

# Reload config to create persistent symlink
source ~/.zshrc
```

**Note:** Fast path uses `[[ -S ]]` (zsh builtin, sub-ms) instead of `ssh-add -l` (~56ms). Full validation only runs on the repair path. VSCode socket discovery uses zsh glob qualifiers instead of `find | xargs ls -t`.

## fzf functions not working

```bash
command -v fzf   # Check installation
apt install fzf  # or: brew install fzf
```

## Python environment not activating

```bash
direnv allow           # Trust .envrc
mise trust             # Trust .mise.toml
mise install           # Install Python version
direnv reload          # Force reload
```

**Wrong Python version:**
```bash
cat .mise.toml         # Check configured version
mise ls python         # List installed versions
mise install python@X.Y  # Install missing version
```

**VSCode using wrong interpreter:**
- Cmd+Shift+P → "Python: Select Interpreter"
- Choose `.venv/bin/python` from project
- Global settings (managed by dotfiles) already set `python.terminal.activateEnvironment: false`
- Verify global settings: `cat ~/.config/Code/User/settings.json`

## Broken `~/Desktop`, `~/Documents`, ... symlinks (XDG user dirs)

**Symptom:** `cd ~/Documents` fails; GNOME Files shows red ✗ on Desktop/Documents/Music/Public/Templates/Videos with "The link is broken — target /home/zvi/X doesn't exist". The entries are **self-referential symlinks** (`~/Documents -> /home/zvi/Documents`).

**Cause:** a self-sustaining cycle between `xdg-user-dirs-update` and `snapd-desktop-integration`:

1. A standard XDG dir doesn't exist as a real directory.
2. At each login `xdg-user-dirs-update` runs (`enabled=True` in `/etc/xdg/user-dirs.conf`). Honouring its "don't recreate what the user deleted" rule, it **collapses** the entry in `~/.config/user-dirs.dirs` to `XDG_<X>_DIR="$HOME/"`.
3. The running `snapd-desktop-integration` service mirrors your XDG dirs into snap sandboxes; for the collapsed/missing entries it creates a self-referential symlink (`~/Documents -> /home/zvi/Documents`) back in the real `$HOME`.
4. That broken link keeps the dir "missing", so step 2 repeats every login — it never self-heals.

Only the missing dirs break; ones that exist as **real directories** (e.g. `Downloads`, `Pictures`) are left alone by both tools. Not caused by these dotfiles.

**Diagnose:**
```bash
find ~ -maxdepth 1 -xtype l          # list broken symlinks in home
cat ~/.config/user-dirs.dirs         # look for entries set to "$HOME/"
```

**Fix:** run the repair guard (idempotent — also runs automatically during `./install` on graphical workstations):
```bash
xdg-repair            # = bash ~/.dotfiles/scripts/repair-xdg-user-dirs.sh
nautilus -q           # relaunch Files to clear the stale view (if open)
```

The guard performs the underlying repair — (1) remove the broken self-referential symlinks (no data; the targets never existed), (2) `mkdir` the real directories, (3) `xdg-user-dirs-update --set` each XDG slot back to `$HOME/<Name>`. Once every standard XDG slot exists as a real directory and `user-dirs.dirs` points at them, the cycle is broken for good: `xdg-user-dirs-update` becomes a no-op and `snapd-desktop-integration` creates normal sandbox symlinks instead of broken ones. Keeping every slot — even unused ones — as a real (possibly empty) directory is what prevents recurrence; empty folders are harmless and desktop icons are hidden by the curated GNOME config.

## Syntax errors

```bash
zsh -n ~/.zshrc                         # Check main config
zsh -n ~/.dotfiles/zsh/zshrc.aliases    # Check modules
# Temporarily disable modules by commenting source lines in zshrc
```
