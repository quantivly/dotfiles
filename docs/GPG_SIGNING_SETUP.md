# GPG Commit Signing with Claude Code

This guide explains how to use GPG signing with Claude Code for automated commits.

## Overview

GPG signing has been configured with secure passphrase caching so that:
- Your passphrase is stored securely by gpg-agent
- Credentials are cached for 8 hours (default) or 24 hours (maximum)
- Claude Code can sign commits automatically without hanging

## Configuration Summary

### Files Modified

1. **~/.dotfiles/gitconfig** - Enabled commit signing
   ```ini
   [commit]
       gpgsign = true
   ```

2. **~/.gnupg/gpg-agent.conf** - Configured passphrase caching
   ```ini
   # Cache GPG passphrase for 8 hours of inactivity
   default-cache-ttl 28800

   # Maximum cache time of 24 hours
   max-cache-ttl 86400

   # Use terminal-friendly pinentry
   pinentry-program /usr/bin/pinentry-curses

   # Allow loopback pinentry for automated tools
   allow-loopback-pinentry
   ```

3. **~/.gnupg/gpg.conf** - Enabled loopback mode for automated signing
   ```ini
   use-agent
   batch
   pinentry-mode loopback
   ```

4. **~/.dotfiles/zsh/zshrc.conditionals** - Exports GPG_TTY (already configured)
   ```bash
   export GPG_TTY=$(tty)
   ```

## Usage Instructions

### Daily Workflow

**Before starting work with Claude Code:**

1. Prime the GPG cache by running:
   ```bash
   gpg-prime-cache
   # or use the alias:
   gpg-prime
   ```

2. Enter your GPG passphrase when prompted

3. Your passphrase is now cached securely for 8-24 hours

4. Use Claude Code normally - commits will be signed automatically

### Manual Testing

Test GPG signing with a manual commit:
```bash
# In any git repository
git commit --allow-empty -m "Test GPG signing"

# Verify the commit is signed
git log --show-signature -1
```

### Cache Status

Check if your GPG key is cached:
```bash
# List cached keys
gpg-connect-agent 'keyinfo --list' /bye | grep "KEYINFO"

# Or test signing directly
echo "test" | gpg --clearsign
```

## Security Notes

- **Passphrase is stored securely**: The cache is managed by gpg-agent in encrypted memory
- **Automatic timeout**: Cache expires after 8 hours of inactivity
- **Maximum lifetime**: Cache is cleared after 24 hours regardless of activity
- **Per-session**: Cache is cleared when gpg-agent restarts or system reboots

## Troubleshooting

### "gpg failed to sign the data" error

1. Verify your signing key is configured:
   ```bash
   git config --global user.signingkey
   ```

2. List your GPG keys:
   ```bash
   gpg --list-secret-keys --keyid-format=long
   ```

3. Prime the cache:
   ```bash
   gpg-prime-cache
   ```

4. If you see "not a tty" errors:
   ```bash
   # This is normal for Claude Code context
   # The loopback configuration handles this
   ```

### Cache expired during work session

Simply run `gpg-prime-cache` again to re-cache your passphrase.

### Want longer cache times?

Edit `~/.gnupg/gpg-agent.conf`:
```ini
# Cache for 24 hours of inactivity
default-cache-ttl 86400

# Maximum cache time of 48 hours
max-cache-ttl 172800
```

Then restart gpg-agent:
```bash
gpgconf --kill gpg-agent
```

### Disable signing temporarily

```bash
# For a single commit
git commit --no-gpg-sign -m "Message"

# Disable globally
git config --global commit.gpgsign false

# Re-enable when ready
git config --global commit.gpgsign true
```

## Alternative: SSH Signing (No Passphrase Prompts)

If GPG passphrase prompts become inconvenient, consider using SSH signing instead:

1. Generate an SSH key for signing:
   ```bash
   ssh-keygen -t ed25519 -C "your_email@example.com" -f ~/.ssh/git_signing
   ```

2. Configure git to use SSH signing:
   ```bash
   git config --global gpg.format ssh
   git config --global user.signingkey ~/.ssh/git_signing.pub
   ```

3. Add the public key to GitHub/GitLab

4. SSH keys don't require passphrase entry if using ssh-agent

## Resources

- [Git GPG Signing Documentation](https://git-scm.com/book/en/v2/Git-Tools-Signing-Your-Work)
- [GitHub GPG Setup Guide](https://docs.github.com/en/authentication/managing-commit-signature-verification)
- [GPG Agent Documentation](https://www.gnupg.org/documentation/manuals/gnupg/Invoking-GPG_002dAGENT.html)
