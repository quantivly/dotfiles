# Git Commit Signing Setup

This guide covers commit signing in Git. **SSH signing is recommended** for its simplicity and integration with SSH workflows.

## Recommended: SSH Signing

Git 2.34+ supports signing commits with SSH keys instead of GPG. This is simpler, more convenient, and integrates seamlessly with SSH agent workflows.

### Quick Start (5 minutes)

#### 1. Get Your SSH Public Key

```bash
# For file-based SSH keys
cat ~/.ssh/id_ed25519.pub

# For Bitwarden-managed keys (or other SSH agent)
ssh-add -L
```

#### 2. Configure Git

Edit `~/.gitconfig.local`:

```ini
[user]
    name = Your Name
    email = your.email@quantivly.com
    signingkey = ssh-ed25519 AAAAC3Nza... your.email@domain.com

[commit]
    gpgsign = true

[gpg]
    format = ssh

[gpg "ssh"]
    allowedSignersFile = ~/.ssh/allowedSigners
```

**Note**: Paste your complete SSH public key as the `signingkey` value.

#### 3. Create Allowed Signers File

```bash
# Create the file
mkdir -p ~/.ssh
cat << EOF > ~/.ssh/allowedSigners
your.email@domain.com ssh-ed25519 AAAAC3Nza... your.email@domain.com
EOF
```

**Format**: `email key-type public-key comment`

**Purpose**: Allows `git log --show-signature` to verify your signatures locally.

#### 4. Test Signing

```bash
# Make a test commit
git commit --allow-empty -m "Test SSH signing"

# Verify signature
git log -1 --show-signature
# Should show: "Good 'git' signature with ED25519 key SHA256:..."
```

### Bitwarden SSH Agent Integration

If you use Bitwarden SSH agent (recommended for secure key management):

**Advantages:**
- Keys never stored in filesystem
- Protected by Bitwarden vault encryption
- Works seamlessly with SSH agent forwarding
- One unlock per session (no repeated passphrase prompts)

**Setup:**
1. Enable Bitwarden SSH agent in Bitwarden settings
2. Add your SSH key to Bitwarden vault
3. Unlock Bitwarden vault
4. Get public key: `ssh-add -L`
5. Configure git with the public key (see Quick Start above)

**Daily Workflow:**
1. Unlock Bitwarden vault (once per session)
2. Commit as normal (signing automatic)
3. First signing operation may require Bitwarden confirmation
4. Subsequent commits sign automatically while vault unlocked

### SSH Agent Forwarding

SSH signing works seamlessly with SSH agent forwarding:

```
Laptop (SSH Agent)  →  EC2 Instance (forwarded agent)
                        ↓
                   Git commits signed with forwarded key
```

**Benefits:**
- No server-side SSH keys needed
- Signing happens via forwarded agent
- Unlock once on laptop, sign anywhere
- Works with Bitwarden, 1Password, system ssh-agent, etc.

**Enable Agent Forwarding:**

```bash
# SSH with agent forwarding
ssh -A your-server

# Or configure in ~/.ssh/config
Host your-server
    ForwardAgent yes
```

**Configure Git on Remote Server:**
- Same configuration as local (see Quick Start)
- Use same allowed signers file
- Commits will be signed using forwarded key

## GitHub Integration

Add your SSH public key to GitHub as a "Signing Key" to show verified badges on commits.

### Steps:

1. Copy your SSH public key:
   ```bash
   cat ~/.ssh/id_ed25519.pub
   # or: ssh-add -L
   ```

2. Go to [GitHub Settings → SSH Keys](https://github.com/settings/keys)

3. Click **"New SSH key"**

4. **Key type**: Select **"Signing Key"** (not "Authentication Key")

5. **Title**: "Commit Signing Key" or descriptive name

6. **Key**: Paste your public key

7. Save

**Result**: Commits will show "Verified" badge with message:
> "Verified signature with SSH key fingerprint SHA256:..."

**Note**: You can use the same SSH key for both authentication and signing by adding it twice (once as "Authentication Key", once as "Signing Key").

## Migration from GPG

If migrating from GPG signing:

1. Follow Quick Start above to configure SSH signing
2. Remove or comment out GPG config from `~/.gitconfig.local`:
   ```ini
   # [user]
   #     signingkey = YOUR_GPG_KEY_ID
   # [gpg]
   #     program = gpg
   ```
3. Old GPG-signed commits remain valid and verified
4. New commits will be SSH-signed going forward

**No data loss**: Existing GPG-signed commits keep their signatures. Git supports mixed signature types in the same repository.

## Troubleshooting

### Problem: Commits not signed

**Check git config:**
```bash
git config --get gpg.format
# Should show: ssh

git config --get user.signingkey
# Should show your SSH public key
```

**Check ssh-agent:**
```bash
echo $SSH_AUTH_SOCK
# Should show agent socket path (e.g., /run/user/1000/ssh-agent.socket)

ssh-add -l
# Should list your SSH key
```

**Fix**: Ensure SSH agent is running and key is loaded.

### Problem: "agent refused operation"

**Cause**: SSH agent needs permission to use the key.

**For Bitwarden**: First signing operation requires confirmation in Bitwarden app.

**For passphrase-protected keys**: You'll be prompted for passphrase.

**Fix**: Approve the signature request or enter passphrase when prompted.

### Problem: Signature verification fails

**Check allowed signers file:**
```bash
cat ~/.ssh/allowedSigners
# Should contain: email + full SSH public key

git config --get gpg.ssh.allowedSignersFile
# Should show: ~/.ssh/allowedSigners (or your configured path)
```

**Fix**: Ensure allowed signers file:
1. Exists at configured path
2. Contains your email and complete public key
3. Format: `email key-type public-key comment` (space-separated)

### Problem: "ssh-keygen: command not found"

**Cause**: OpenSSH client not installed or not in PATH.

**Fix**:
```bash
# Ubuntu/Debian
sudo apt install openssh-client

# macOS (should be pre-installed)
which ssh-keygen  # Verify installation
```

### Problem: Works locally but not on remote server

**Check SSH agent forwarding:**
```bash
# On remote server
echo $SSH_AUTH_SOCK
# Should show forwarded socket path

ssh-add -l
# Should show your local keys
```

**Fix**: Enable agent forwarding (`ssh -A` or configure in `~/.ssh/config`).

## Advanced Topics

### Using Different Keys for Different Repositories

You can configure per-repository signing keys:

```bash
cd /path/to/repository
git config user.signingkey "ssh-ed25519 AAAAC3Nza... project-specific-key"
```

This overrides the global configuration in `~/.gitconfig.local`.

### Conditional Configuration

Use git's conditional includes for automatic key selection:

**File**: `~/.gitconfig`
```ini
[includeIf "gitdir:~/work/"]
    path = ~/.gitconfig.work

[includeIf "gitdir:~/personal/"]
    path = ~/.gitconfig.personal
```

**File**: `~/.gitconfig.work`
```ini
[user]
    signingkey = ssh-ed25519 AAAAC3Nza... work-key
```

### Multiple Allowed Signers

Your `~/.ssh/allowedSigners` file can contain multiple keys:

```
your.email@company.com ssh-ed25519 AAAAC3Nza... work-key
your.email@personal.com ssh-ed25519 AAAAC3Nza... personal-key
teammate@company.com ssh-rsa AAAAB3Nza... teammate-key
```

This allows verifying signatures from multiple people or your different identities.

---

## Alternative: GPG Signing (Not Recommended)

⚠️ **Warning**: GPG signing requires significantly more maintenance than SSH signing.

### Why SSH is Better

| Aspect | SSH Signing | GPG Signing |
|--------|-------------|-------------|
| **Setup** | 5 minutes | 15+ minutes |
| **Daily workflow** | Automatic (ssh-agent) | Manual (cache priming required) |
| **Cache management** | None needed | 8-24 hour TTL, requires daily priming |
| **Pre-commit hooks** | Not needed | Required (prevent hanging) |
| **Shell reminders** | Not needed | Required (cache expiration warnings) |
| **Agent integration** | Works with SSH agent forwarding | Separate GPG agent |
| **Passphrase prompts** | Once per session (if using agent) | Daily or per-session |
| **Complexity** | Simple (2 config values) | Complex (multiple scripts, hooks) |
| **Maintenance** | None | Ongoing (key renewal, cache management) |

### If You Still Want GPG

**When to Consider GPG:**
- Corporate policy mandates GPG
- Need GPG's web of trust model
- Already have extensive GPG infrastructure
- Team uses GPG signing exclusively
- Require email encryption integration

**Setup Requirements:**
1. Generate GPG key: `gpg --full-generate-key`
2. Get key ID: `gpg --list-secret-keys --keyid-format=long`
3. Configure git:
   ```ini
   [user]
       signingkey = YOUR_KEY_ID
   [commit]
       gpgsign = true
   [gpg]
       program = gpg
   ```
4. Configure gpg-agent with appropriate cache TTL
5. Set up pre-commit hooks to prevent hanging commits
6. Install passphrase caching utilities
7. Configure shell reminders for cache expiration

**Daily Workflow:**
1. Prime GPG cache (enter passphrase)
2. Cache lasts 8 hours idle / 24 hours max (typical)
3. Repeat when cache expires
4. Deal with blocked commits when cache expires mid-workflow

**Maintenance Overhead:**
- Daily or per-session passphrase entry
- Pre-commit hook installation and management
- Cache expiration monitoring
- Separate agent from SSH authentication
- Key expiration and renewal
- Backup and recovery procedures

**Why We Don't Recommend It:**
- Requires manual intervention (cache priming) at minimum once daily
- Pre-commit hooks can block workflow when cache expires
- Separate authentication method from SSH (two auth systems)
- More complex than SSH (multiple scripts vs simple config)
- Doesn't integrate with SSH agent forwarding workflows
- Interrupts flow with passphrase prompts and cache warnings

**Migration Path:**
If you're currently using GPG and want to switch to SSH, see the "Migration from GPG" section above. The process is straightforward and takes about 5 minutes.

---

## References

- [Git SSH Signing Documentation](https://git-scm.com/docs/git-config#Documentation/git-config.txt-gpgformat)
- [GitHub SSH Signing Support](https://github.blog/changelog/2022-08-23-ssh-commit-verification-now-supported/)
- [GitLab SSH Signing](https://docs.gitlab.com/ee/user/project/repository/signed_commits/ssh.html)
- [Bitwarden SSH Agent](https://bitwarden.com/help/ssh-agent/)
- [SSH Agent Forwarding Security](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/using-ssh-agent-forwarding)
