# GPG Commit Signing Setup Guide

## Quick Start (5 Minutes)

**For the impatient - minimal steps to get signing working:**

```bash
# 1. Generate GPG key (follow prompts)
gpg --full-generate-key

# 2. Get your key ID
gpg --list-secret-keys --keyid-format=long
# Look for: sec   rsa4096/YOUR_KEY_ID_HERE

# 3. Configure git (edit ~/.gitconfig.local)
# Add these lines:
#   [user]
#       signingkey = YOUR_KEY_ID
#   [commit]
#       gpgsign = true

# 4. Add public key to GitHub
gpg --armor --export YOUR_KEY_ID | gh auth git-credential
# Then paste at: https://github.com/settings/keys

# 5. Prime cache and test
gpg-prime
git commit --allow-empty -m "Test GPG signing"
git log --show-signature -1
```

Done! You should see "Good signature" in the log output.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Step-by-Step Setup](#step-by-step-setup)
  - [1. Generate GPG Key](#1-generate-gpg-key)
  - [2. Configure Git](#2-configure-git)
  - [3. Add Public Key to GitHub](#3-add-public-key-to-github)
  - [4. Prime GPG Cache](#4-prime-gpg-cache)
  - [5. Test Setup](#5-test-setup)
- [Daily Workflow](#daily-workflow)
- [Available Utilities](#available-utilities)
- [Troubleshooting](#troubleshooting)
- [Advanced Topics](#advanced-topics)
- [Team Information](#team-information)
- [Quick Reference](#quick-reference)

---

## Overview

### What is GPG Commit Signing?

GPG (GNU Privacy Guard) signing allows you to cryptographically sign your git commits, proving they were actually created by you. When you sign commits:

- GitHub shows a "Verified" badge next to your commits
- Others can verify commits haven't been tampered with
- Your identity as the author is cryptographically guaranteed
- It protects against commit spoofing and impersonation

### Why Use It?

**Security**: Anyone can set `git config user.name "Your Name"` and make commits that appear to be from you. GPG signing prevents this.

**Trust**: Verified commits provide confidence in code review and audit trails.

**Compliance**: Some organizations require signed commits for compliance reasons.

**Best Practice**: It's becoming standard in the industry, especially for security-sensitive projects.

### Team Policy

**Quantivly's policy**: GPG commit signing is **required** for all team members. While not technically enforced (unsigned commits won't be rejected), it is expected that all commits to team repositories are signed.

This guide provides the tools and documentation to make signing convenient and seamless.

---

## Prerequisites

Before you begin, ensure you have:

- **GPG installed**:
  - **macOS**: `brew install gpg`
  - **Ubuntu/Debian**: `sudo apt install gpg`
  - **Verify**: `gpg --version`

- **Git configured**: Your `~/.gitconfig.local` should have your name and email
  ```bash
  git config user.name
  git config user.email
  ```

- **GitHub CLI** (optional but helpful):
  ```bash
  gh auth status  # Check if authenticated
  ```

- **Time estimate**: 5-10 minutes for initial setup, then 2 seconds per day

---

## Step-by-Step Setup

### 1. Generate GPG Key

**Generate a new GPG key pair:**

```bash
gpg --full-generate-key
```

**Interactive prompts** (recommended answers):

1. **Key type**: `(1) RSA and RSA` (default)
2. **Key size**: `4096` (maximum security)
3. **Expiration**: `0 = key does not expire` (or set expiration if preferred)
4. **Confirm**: `y`
5. **Real name**: Your full name (matches GitHub profile)
6. **Email**: Your work email (must match git config)
7. **Comment**: Optional (can leave blank or add "Work" or "Quantivly")
8. **Passphrase**: **Choose a strong passphrase you'll remember!**
   - You'll enter this once per day with `gpg-prime`
   - Use a password manager if needed

**Example output:**

```
gpg: key ABC123DEF456 marked as ultimately trusted
gpg: revocation certificate stored as '/home/user/.gnupg/openpgp-revocs.d/...'
public and secret key created and signed.
```

**Verify key created:**

```bash
gpg --list-secret-keys --keyid-format=long
```

Output:
```
sec   rsa4096/ABC123DEF456 2024-12-31 [SC]
      ABCD1234EFGH5678IJKL9012MNOP3456QRST7890
uid                 [ultimate] Your Name <your.email@company.com>
ssb   rsa4096/XYZ987WVU654 2024-12-31 [E]
```

**Your key ID** is the part after `rsa4096/` on the `sec` line: `ABC123DEF456`

**Save this key ID** - you'll need it for the next steps!

### 2. Configure Git

Git needs to know which GPG key to use for signing. Edit `~/.gitconfig.local`:

```bash
vim ~/.gitconfig.local
# or: code ~/.gitconfig.local
# or: nano ~/.gitconfig.local
```

**Add these lines** (replace `ABC123DEF456` with YOUR key ID):

```gitconfig
[user]
    name = Your Name
    email = your.email@company.com
    signingkey = ABC123DEF456

[commit]
    gpgsign = true
```

**Notes:**
- `signingkey` - Your GPG key ID from step 1
- `gpgsign = true` - Sign ALL commits automatically
- **Don't edit** `~/.gitconfig` directly (it's symlinked from dotfiles)
- **Only edit** `~/.gitconfig.local` (not in version control)

**Verify configuration:**

```bash
git config user.signingkey
# Should output: ABC123DEF456

git config commit.gpgsign
# Should output: true
```

### 3. Add Public Key to GitHub

GitHub needs your **public key** to verify signatures. Your **private key** stays secret on your machine.

**Export your public key:**

```bash
# Option 1: Copy to clipboard directly (macOS)
gpg --armor --export ABC123DEF456 | pbcopy

# Option 2: Copy to clipboard (Linux with xclip)
gpg --armor --export ABC123DEF456 | xclip -selection clipboard

# Option 3: Print to terminal and copy manually
gpg --armor --export ABC123DEF456
```

This outputs a block like:
```
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGVw...
[many lines of base64 text]
...
-----END PGP PUBLIC KEY BLOCK-----
```

**Add to GitHub:**

1. Go to: https://github.com/settings/keys
2. Click **"New GPG key"**
3. **Title**: "Work Laptop" or "Ubuntu Workstation" (something descriptive)
4. **Key**: Paste the entire key block (including BEGIN and END lines)
5. Click **"Add GPG key"**

**Verify on GitHub:**

Go to: https://github.com/settings/keys

You should see your new GPG key listed with:
- Your key ID
- Your email address
- Creation date

### 4. Prime GPG Cache

The `gpg-prime` utility caches your GPG passphrase so you don't have to enter it for every commit.

**Prime the cache:**

```bash
gpg-prime
```

**You'll see:**
```
Priming GPG cache for key: ABC123DEF456
You will be prompted for your GPG passphrase.

[Passphrase prompt will appear]

✓ GPG cache primed successfully!

Your passphrase is cached for:
  - 8 hours of inactivity (default-cache-ttl)
  - 24 hours maximum (max-cache-ttl)
```

**Enter your GPG passphrase** when prompted.

**Important:**
- Run `gpg-prime` **once per work session** (typically once per day)
- Your passphrase is cached securely by gpg-agent
- After 8 hours of inactivity OR 24 hours maximum, you'll need to run it again
- You'll get a friendly reminder if you forget!

### 5. Test Setup

**Verify everything works:**

```bash
# Create a test commit
cd /tmp
git init test-gpg
cd test-gpg
echo "test" > test.txt
git add test.txt
git commit -m "Test GPG signing"

# Verify signature
git log --show-signature -1
```

**Expected output:**

```
commit abc123...
gpg: Signature made Tue Dec 31 10:30:00 2024
gpg:                using RSA key ABC123DEF456
gpg: Good signature from "Your Name <your.email@company.com>" [ultimate]
Author: Your Name <your.email@company.com>
Date:   Tue Dec 31 10:30:00 2024

    Test GPG signing
```

**Look for**: `Good signature` - this means it worked!

**If you see an error**, check the [Troubleshooting](#troubleshooting) section below.

**Clean up:**

```bash
cd ~
rm -rf /tmp/test-gpg
```

---

## Daily Workflow

### Morning Routine

When you start working for the day:

```bash
gpg-prime
```

**That's it!** Enter your passphrase once, and you're set for the day.

**Shell Reminder**: If you forget to run `gpg-prime`, you'll see a friendly one-time reminder when you start a new shell session:

```
⚠️  GPG Cache Reminder
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GPG commit signing is enabled, but your cache may not be primed.

Run once to cache your passphrase for the day:
  gpg-prime

This reminder will not show again this session.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Making Commits

**Nothing changes!** Your normal git workflow works exactly the same:

```bash
git add .
git commit -m "Your commit message"
git push
```

Commits are signed **automatically** because we set `commit.gpgsign = true`.

**No extra commands needed!**

### When Cache Expires

If you haven't run git commands for 8+ hours, or it's been 24 hours since you ran `gpg-prime`, the cache expires.

**You'll see this error:**

```
error: gpg failed to sign the data
fatal: failed to write commit object
```

**Fix:**

```bash
gpg-prime
# Then retry your commit
git commit -m "Your message"
```

**Pre-commit Hook Protection**: Our dotfiles include a pre-commit hook that **prevents** this hanging scenario. If your cache has expired, you'll see:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  GPG Cache Not Primed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

GPG commit signing is enabled, but your passphrase cache has expired.
This would cause the commit to hang waiting for credentials.

To fix this:
  gpg-prime              # Prime cache (recommended)

To commit without signing this once:
  git commit --no-gpg-sign

Need help? See: ~/.dotfiles/examples/gpg-setup-guide.md
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Just run `gpg-prime` and try again!

---

## Available Utilities

The dotfiles repository includes three GPG utilities, automatically installed to `~/.local/bin/`:

### gpg-prime-cache

**Alias:** `gpg-prime` (shorter and easier to type)

**Purpose**: Prime your GPG passphrase cache for automatic commit signing.

**When to run**: Once per work session (typically daily).

**Usage:**

```bash
gpg-prime
```

**What it does:**
1. Checks if GPG is installed
2. Checks if you have a secret key
3. Checks if git is configured with a signing key
4. Prompts for your GPG passphrase
5. Caches passphrase for 8-24 hours

**Cache lifetime:**
- **8 hours** of inactivity (default-cache-ttl)
- **24 hours** maximum (max-cache-ttl)

**Error handling**: Provides clear error messages with fix instructions if:
- GPG not installed
- No GPG keys found
- No signing key configured in git

### git-check-gpg-cache

**Purpose**: Check if GPG cache is primed (used internally by hooks).

**When to run**: Usually automatic, but can run manually to check status.

**Usage:**

```bash
git-check-gpg-cache
echo $?  # 0 = cached, 1 = not cached
```

**Exit codes:**
- `0` - Cache is primed and ready
- `1` - Cache is not primed OR signing not enabled

**What it does:**
1. Checks if commit signing is enabled
2. Gets your signing key from git config
3. Attempts a test signature
4. Returns exit code based on success

**Note**: This script is **silent** - it doesn't print output (used by pre-commit hook).

### install-gpg-hooks

**Purpose**: Install GPG pre-commit hooks in existing repositories.

**When to run**: Almost never! (Only if you've disabled global hooks)

**Usage:**

```bash
# Install in specific repositories
install-gpg-hooks ~/project1 ~/project2

# Or search and install in all repos
install-gpg-hooks
```

**Important note**: If you're using the Quantivly dotfiles, you **don't need this script**! Global hooks are configured via `core.hooksPath`, so all repositories automatically get the GPG cache check hook.

This script is only useful if:
- You've disabled global hooks for some reason
- You want hooks in specific repos only
- You're debugging hook issues

**What it does:**
1. Shows a warning that it's probably not needed
2. Searches for git repositories
3. Copies the pre-commit hook from templates
4. Sets executable permissions

---

## Troubleshooting

### "GPG failed to sign the data"

**Cause**: GPG cache has expired or passphrase not entered.

**Fix**:

```bash
gpg-prime
```

Then retry your commit.

### "No signing key configured"

**Cause**: Git doesn't know which GPG key to use.

**Fix**:

1. Get your key ID:
   ```bash
   gpg --list-secret-keys --keyid-format=long
   ```

2. Add to `~/.gitconfig.local`:
   ```gitconfig
   [user]
       signingkey = YOUR_KEY_ID
   ```

### "Error: GPG is not installed"

**Fix**:

```bash
# macOS
brew install gpg

# Ubuntu/Debian
sudo apt install gpg
```

### "Error: No GPG secret keys found"

**Cause**: You haven't generated a GPG key yet.

**Fix**: Follow [Step 1: Generate GPG Key](#1-generate-gpg-key)

### "Inappropriate ioctl for device"

**Cause**: GPG can't access the pinentry program for passphrase entry.

**Fix**:

Add to `~/.gnupg/gpg-agent.conf`:

```
pinentry-program /usr/bin/pinentry-curses
```

Then restart gpg-agent:

```bash
gpgconf --kill gpg-agent
gpg-prime
```

### Commits not showing "Verified" on GitHub

**Possible causes and fixes:**

1. **Email mismatch**: Git email must match GitHub account and GPG key email
   ```bash
   git config user.email
   gpg --list-keys
   # These must match your GitHub email
   ```

2. **Public key not added to GitHub**: Follow [Step 3](#3-add-public-key-to-github)

3. **Key expired**: Check key expiration:
   ```bash
   gpg --list-keys
   # Look for expiration date
   ```

4. **Signature made with wrong key**: Verify signing key:
   ```bash
   git log --show-signature -1
   # Check if key ID matches your configured key
   ```

### "gpg: signing failed: No secret key"

**Cause**: The key ID configured doesn't exist or is wrong.

**Fix**:

1. List available keys:
   ```bash
   gpg --list-secret-keys --keyid-format=long
   ```

2. Update `~/.gitconfig.local` with correct key ID

### GPG prompts for passphrase despite running gpg-prime

**Cause**: Multiple gpg-agent instances or cache not working.

**Fix**:

```bash
# Kill all gpg-agent processes
gpgconf --kill gpg-agent

# Restart gpg-agent
gpg-agent --daemon

# Prime cache again
gpg-prime
```

### Pre-commit hook not running

**Verify hooks path:**

```bash
git config core.hooksPath
# Should output: ~/.config/git/hooks
```

**Verify hook exists:**

```bash
ls -la ~/.config/git/hooks/pre-commit
# Should be executable
```

**If missing**, run:

```bash
cd ~/.dotfiles
./install
```

---

## Advanced Topics

### Customizing Cache Duration

The default cache settings are:
- 8 hours of inactivity (28800 seconds)
- 24 hours maximum (86400 seconds)

**To customize**, edit `~/.gnupg/gpg-agent.conf`:

```
# Cache passphrase for 12 hours of inactivity
default-cache-ttl 43200

# Cache passphrase for 48 hours maximum
max-cache-ttl 172800
```

**Restart gpg-agent** for changes to take effect:

```bash
gpgconf --kill gpg-agent
gpg-prime
```

### Multiple GPG Keys

If you have multiple GPG keys (e.g., personal and work), specify which to use:

```gitconfig
# In ~/.gitconfig.local
[user]
    signingkey = WORK_KEY_ID

# In personal projects, override locally
# cd ~/personal-project
# git config user.signingkey PERSONAL_KEY_ID
```

### SSH Signing Alternative

Git also supports SSH key signing (simpler but less widely supported):

```bash
# Generate SSH key for signing
ssh-keygen -t ed25519 -C "signing@company.com"

# Configure git
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub

# Add to GitHub at: https://github.com/settings/keys
# Select "Signing Key" type
```

**Note**: SSH signing is newer and not all tools support verification.

### Signing Tags

Sign git tags for releases:

```bash
# Create signed tag
git tag -s v1.0.0 -m "Version 1.0.0"

# Push signed tag
git push origin v1.0.0

# Verify tag
git tag -v v1.0.0
```

### GPG Best Practices

1. **Backup your key**:
   ```bash
   gpg --export-secret-keys --armor YOUR_KEY_ID > gpg-private-key-backup.asc
   # Store securely (encrypted USB, password manager, etc.)
   ```

2. **Generate revocation certificate** (done automatically, but verify):
   ```bash
   ls ~/.gnupg/openpgp-revocs.d/
   # Backup this file too
   ```

3. **Use a strong passphrase**: Long and memorable, or use a password manager

4. **Set expiration dates**: Consider 2-5 year expiration, can extend later

5. **Don't share private keys**: Only share public keys

6. **Regular key rotation**: Rotate keys every few years for best security

---

## Team Information

### Quantivly Policy

**Requirement**: GPG commit signing is required for all team members.

**Enforcement**: While not technically enforced (unsigned commits won't be rejected by git), all team members are expected to sign commits.

**Support**: This guide and the included utilities are provided to make signing seamless and convenient.

### Getting Help

**For GPG setup issues:**
- This guide: `~/.dotfiles/examples/gpg-setup-guide.md`
- Technical reference: `~/.dotfiles/docs/GPG_SIGNING_SETUP.md`
- Ask in team chat or #engineering channel

**For dotfiles issues:**
- GitHub issues: https://github.com/quantivly/dotfiles/issues
- Internal documentation: Confluence or team wiki
- Team lead or DevOps engineer

**For GitHub verification issues:**
- GitHub docs: https://docs.github.com/en/authentication/managing-commit-signature-verification
- Ensure email matches between git, GPG, and GitHub

---

## Quick Reference

### Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `gpg-prime` | Prime cache (run once daily) |
| `gpg --list-secret-keys --keyid-format=long` | List your GPG keys |
| `gpg --armor --export KEY_ID` | Export public key |
| `git log --show-signature -1` | Verify last commit signature |
| `git commit --no-gpg-sign` | Skip signing for one commit |
| `git config user.signingkey` | Show configured signing key |
| `git-check-gpg-cache; echo $?` | Check cache status (0=ready) |
| `gpgconf --kill gpg-agent` | Restart GPG agent |

### File Locations

| File | Purpose |
|------|---------|
| `~/.gnupg/` | GPG configuration and keys |
| `~/.gnupg/gpg-agent.conf` | GPG agent configuration |
| `~/.gitconfig.local` | Machine-specific git config (add signing key here) |
| `~/.config/git/hooks/pre-commit` | Pre-commit hook (checks GPG cache) |
| `~/.local/bin/gpg-prime-cache` | GPG cache priming utility |
| `~/.local/bin/git-check-gpg-cache` | GPG cache check utility |
| `~/.dotfiles/scripts/` | Source scripts directory |

### Configuration Examples

**~/.gitconfig.local**:
```gitconfig
[user]
    name = Your Name
    email = your.email@company.com
    signingkey = ABC123DEF456

[commit]
    gpgsign = true
```

**~/.gnupg/gpg-agent.conf** (optional customization):
```
default-cache-ttl 43200    # 12 hours
max-cache-ttl 172800       # 48 hours
pinentry-program /usr/bin/pinentry-curses
```

### Common Error Messages

| Error | Quick Fix |
|-------|-----------|
| "gpg failed to sign the data" | Run `gpg-prime` |
| "No signing key configured" | Add `signingkey` to `~/.gitconfig.local` |
| "GPG is not installed" | Install GPG: `brew install gpg` or `apt install gpg` |
| "No GPG secret keys found" | Generate key: `gpg --full-generate-key` |
| Pre-commit hook message | Run `gpg-prime` then retry commit |

---

## Related Documentation

- **Technical deep-dive**: [~/docs/GPG_SIGNING_SETUP.md](../docs/GPG_SIGNING_SETUP.md)
- **Git workflows**: [git-workflows.md](git-workflows.md)
- **Main dotfiles README**: [../README.md](../README.md)
- **GitHub GPG docs**: https://docs.github.com/en/authentication/managing-commit-signature-verification
- **GPG manual**: `man gpg`

---

**Last updated**: 2024-12-31

**Questions or improvements?** Open an issue or PR at the dotfiles repository.
