# Server Bootstrap Guide

Bootstrap remote servers (AL2, Ubuntu, etc.) with the team's standard shell DX.

## Bootstrap a New Server

```bash
# From your workstation (pipe over SSH):
ssh server 'bash -s' < ~/.dotfiles/scripts/server-bootstrap.sh

# Or on the server directly:
curl -fsSL https://raw.githubusercontent.com/quantivly/dotfiles/main/scripts/server-bootstrap.sh | bash
```

The bootstrap script runs 6 phases: OS detection, system packages (zsh, git, tmux, etc.), dotfiles clone + install, mise tools (server-optimized subset), server identity templates, and verification.

## Update Servers

After dotfiles changes, update a server without reinstalling system packages:

```bash
ssh server-shell '~/.dotfiles/scripts/server-bootstrap.sh --update'
```

This pulls the latest dotfiles, re-runs `./install`, and updates mise tools.

## SSH Config (Workstation-Side)

Each server gets **two entries** in your `~/.ssh/config`:

```ssh-config
# Auto-tmux for terminal SSH
Host staging
    HostName <actual-hostname>
    User ec2-user
    ForwardAgent yes
    RequestTTY yes
    RemoteCommand tmux new-session -A -s admin

# Clean access for VSCode Remote SSH, scp, one-off commands
Host staging-shell
    HostName <actual-hostname>
    User ec2-user
    ForwardAgent yes
```

**Why two entries**: VSCode Remote SSH breaks with `RemoteCommand`. The `-shell` variant gives clean access for VSCode, `scp`, and scripted commands (including `--update`). The base entry auto-attaches to a persistent tmux session.

## Shared ec2-user Considerations

- Servers use a shared `ec2-user` account (team standard)
- Personal preferences go in `~/.zshrc.local` (never overwritten by bootstrap or updates)
- `.gitconfig.local` uses a team email by default — update if needed
- SSH agent forwarding carries your identity from your workstation — no keys stored on servers
- `Q_MODE=server` in `.zshrc.local` tells `zshrc.company` to skip workstation-only features

## Server mise Config

Servers use a lightweight tool subset (`examples/server-mise.toml`) instead of the full workstation config. Includes: bat, fd, eza, delta, zoxide, duf, dust, lazygit, glow, fastfetch. Excludes dev-only tools (node, python, pre-commit, etc.).

## AL2 2023 Gotchas

| Issue | Solution |
|-------|----------|
| Missing `en_US.UTF-8` locale | Bootstrap runs `localedef` automatically |
| `chsh` not available | Bootstrap installs `util-linux-user` package |
| `gpg-agent` not installed | Node.js GPG verification fails; server config excludes node |
| `gh auth git-credential` won't work | `.gitconfig.local` uses SSH URLs via `insteadOf` |
| tmux 3.2 (not 3.3+) | Most features work; may need `tmux kill-server` after first config |
| Package manager is `dnf` (not `yum`) | Bootstrap auto-detects; both work |

## Bootstrap Ordering Note

The `./install` script skips the mise config section if mise isn't installed yet. The bootstrap handles this by installing mise in Phase 4 (after `./install` runs in Phase 3), then separately configuring the server mise config. On `--update` runs, mise is already installed, so `./install` handles it normally.

## Piping Bootstrap via SSH

Always use `ssh server 'bash -s' < script.sh` (not `ssh server 'script.sh'`) for bootstrap. This ensures the script runs in bash regardless of the remote user's default shell — critical if the login shell is broken or hanging.

## SSH Debugging (Remote Server Work)

- **Empty SSH output?** Test with `-o ControlPath=none` to bypass ControlMaster muxing
- **SSH command hangs?** Remote shell startup may be broken — use `ssh host 'bash -s'` piped via stdin
- **`exec zsh` in `.bashrc`**: Anti-pattern that breaks non-interactive SSH. Fix: remove it, use `chsh` instead
- **Push before bootstrap**: `server-bootstrap.sh` clones from GitHub — new files must be pushed first

## Shell Script CI Requirements

- **SC2088**: Use `$HOME` not `~` in quoted strings (tilde doesn't expand in quotes)
- **SC2015**: Don't use `A && B || C` as if-then-else — rewrite as `if/then/else`
- **SC2086**: Add `# shellcheck disable=SC2086` comment when word-splitting is intentional (e.g., `$PKG_INSTALL`)
- **end-of-file-fixer**: All files must end with exactly one newline

## Server mise Config Strategy

Servers use a **copy** of `examples/server-mise.toml` (not a symlink). The `./install` script detects the differing file and preserves it ("Keeping your version"). This means server tool configs survive `./install` re-runs without special-casing.

## Bootstrapped Servers

| Server | Status | Date | Notes |
|--------|--------|------|-------|
| staging | Complete | 2026-02-10 | AL2 2023, had pre-existing partial zsh setup |
