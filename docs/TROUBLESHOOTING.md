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

## GitHub CLI multi-account switching

The `zshrc.company` `chpwd` hook switches `GH_CONFIG_DIR`, `GH_TOKEN`, and `GITHUB_PERSONAL_ACCESS_TOKEN` based on directory context (`~/quantivly/**` → work, everything else → personal).

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

## Syntax errors

```bash
zsh -n ~/.zshrc                         # Check main config
zsh -n ~/.dotfiles/zsh/zshrc.aliases    # Check modules
# Temporarily disable modules by commenting source lines in zshrc
```
