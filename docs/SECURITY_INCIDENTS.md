# Security Incident Response Guide

This document provides step-by-step procedures for handling security incidents involving accidentally committed secrets in the dotfiles repository.

## 🚨 If You Accidentally Commit a Secret

**DO NOT PANIC.** Follow these steps carefully and in order.

### Step 1: IMMEDIATELY Rotate the Credential ⚡

**This is the MOST IMPORTANT step** - do this BEFORE anything else!

The moment a secret enters git history, assume it's compromised. Even if you haven't pushed yet, treat it as public.

**Common credential types and how to rotate:**

- **API Keys**: Revoke in provider dashboard, generate new key
- **SSH Keys**: Remove from authorized_keys, generate new keypair
- **Passwords**: Change immediately in the service
- **Access Tokens**: Revoke and generate new token
- **Database Credentials**: Change password in database
- **AWS Keys**: Deactivate in IAM console, create new access key

**Why rotate first?**
- Git history rewriting takes time
- If you pushed, the secret is already public
- Rotation prevents unauthorized access immediately

### Step 2: Remove from Git History

Now that the credential is rotated and safe, clean up git history.

#### Option A: Interactive Rebase (if not pushed yet)

```bash
# View recent commits
git log --oneline -10

# Interactive rebase to edit history
git rebase -i HEAD~5  # Adjust number as needed

# In the editor:
# - Change 'pick' to 'edit' for commits with secrets
# - Save and close

# For each commit marked 'edit':
# 1. Remove the secret from files
git add .
git commit --amend --no-edit

# 2. Continue rebase
git rebase --continue
```

#### Option B: git-filter-repo (if already pushed)

**Warning**: This rewrites history and requires force-push. Coordinate with your team first!

```bash
# Install git-filter-repo (if not installed)
pip install git-filter-repo

# Remove specific file patterns
git filter-repo --path-glob '*secret*' --invert-paths
git filter-repo --path '**.local' --invert-paths

# Remove specific content (e.g., hardcoded password)
git filter-repo --replace-text <(echo 'hardcoded_password==>REDACTED')

# Force push (DANGER: coordinate with team!)
git push --force-with-lease origin main
```

#### Option C: BFG Repo-Cleaner (fastest for large repos)

```bash
# Install BFG (faster than git-filter-repo)
# Download from: https://rtyley.github.io/bfg-repo-cleaner/

# Remove passwords
bfg --replace-text passwords.txt

# Remove files
bfg --delete-files '*.env'
bfg --delete-folders '.secrets'

# Clean up
git reflog expire --expire=now --all
git gc --prune=now --aggressive

# Force push
git push --force-with-lease origin main
```

### Step 3: Notify Your Team

If the secret was pushed to a shared repository:

**Immediate notification (within 15 minutes):**
```
Subject: [SECURITY] Secret exposed in dotfiles - [SECRET_TYPE]

Hi team,

I accidentally committed and pushed [SECRET_TYPE] to the dotfiles repository.

Actions taken:
- ✓ Credential rotated at [TIME]
- ✓ Git history cleaned
- ✓ Force push completed at [TIME]

Action required from you:
- Pull latest changes: git pull --force origin main
- If you have local branches, rebase them: git rebase origin/main

Timeline:
- Exposed: [TIME_COMMITTED]
- Detected: [TIME_DETECTED]
- Rotated: [TIME_ROTATED]
- Cleaned: [TIME_CLEANED]

Let me know if you have any issues!
```

### Step 4: Post-Incident Review

Once the immediate crisis is over, conduct a blameless post-mortem:

1. **Root Cause Analysis**
   - How did the secret enter the codebase?
   - Why didn't pre-commit hooks catch it?
   - What process failed?

2. **Prevention Measures**
   - Add pattern to `.gitignore` if missing
   - Enhance `HISTORY_IGNORE` patterns
   - Add gitleaks rule for this secret type
   - Update pre-commit hooks configuration

3. **Documentation Updates**
   - Document the pattern that was missed
   - Update this guide if process was unclear
   - Share learnings with team

### Step 5: Verify Complete Removal

```bash
# Search entire git history for the secret
git log -S"secret_value_here" --all --pretty=format:"%h %an %ad %s"

# Search file contents across all commits
git rev-list --all | xargs git grep "secret_value"

# Use gitleaks to scan history
gitleaks detect --source . --verbose --redact

# If found in any commit, repeat Step 2
```

## 🛡️ Prevention (Better Than Cure)

### Pre-Commit Hooks (Automated Defense)

This repository uses pre-commit hooks that run automatically before each commit:

```bash
# Install hooks (run once after cloning)
pre-commit install

# Manually run all hooks
pre-commit run --all-files

# Update hook versions
pre-commit autoupdate
```

**What the hooks check:**
- ✓ Private key detection (`detect-private-key`)
- ✓ Secret patterns (`gitleaks`)
- ✓ Large files that might contain secrets
- ✓ YAML syntax (prevents malformed secret files)
- ✓ Custom patterns for HISTORY_IGNORE compliance

### .gitignore Patterns

Never commit these file types:

```gitignore
# Secrets and credentials
*.local
*.secret*
*.password*
*token*
.env
.env.*

# SSH and GPG keys
*.pem
*.key
*.ppk
id_rsa*
id_ed25519*

# Cloud provider credentials
.aws/credentials
.azure/credentials
gcloud-credentials.json

# Database dumps
*.sql
*.dump
```

### Environment Variables

**NEVER hardcode secrets in files:**

```bash
# ❌ BAD - Hardcoded
export API_KEY="abc123secret"

# ✓ GOOD - Sourced from encrypted file
export API_KEY=$(sops -d ~/.secrets/env.enc.yaml | yq -r '.API_KEY')

# ✓ GOOD - Prompt at runtime
read -sp "API Key: " API_KEY && export API_KEY
```

### Secret Storage Best Practices

1. **Use `sops` for encrypted secrets:**
   ```bash
   # Create encrypted file
   sops ~/.secrets/env.enc.yaml

   # Decrypt and source
   eval "$(sops -d ~/.secrets/env.enc.yaml | yq -r 'to_entries | .[] | "export \(.key)=\(.value)"')"
   ```

2. **Use password managers:**
   - 1Password CLI
   - Bitwarden CLI
   - AWS Secrets Manager
   - HashiCorp Vault

3. **Never commit `.local` files:**
   - `~/.zshrc.local` is in `.gitignore`
   - Put machine-specific secrets there
   - Ensure `chmod 600 ~/.zshrc.local`

## 📞 When to Escalate

Contact your security team immediately if:

- ✗ Production database credentials exposed
- ✗ AWS root account keys exposed
- ✗ Certificate private keys exposed
- ✗ Secret exposed in public repository (not just internal)
- ✗ Evidence of unauthorized access detected
- ✗ Unable to rotate credential (e.g., hard-coded in legacy system)

## 🔗 Related Resources

- **Pre-commit hooks**: `.pre-commit-config.yaml`
- **Gitleaks config**: Uses default rules + custom patterns
- **gitignore patterns**: `.gitignore`
- **HISTORY_IGNORE**: `zsh/zshrc.history`
- **Encrypted secrets**: `docs/SOPS_SETUP.md` (if exists)

## 📚 External Tools

- [git-filter-repo](https://github.com/newren/git-filter-repo) - Rewrite git history
- [BFG Repo-Cleaner](https://rtyley.github.io/bfg-repo-cleaner/) - Fast history cleaning
- [gitleaks](https://github.com/gitleaks/gitleaks) - Secret scanner
- [sops](https://github.com/mozilla/sops) - Encrypted secrets
- [git-secrets](https://github.com/awslabs/git-secrets) - AWS secret prevention

## 🧪 Test Your Knowledge

**Scenario 1**: You committed a file containing an AWS access key but haven't pushed yet. What's the order of operations?

<details>
<summary>Click to reveal answer</summary>

1. Rotate AWS key in IAM console (FIRST!)
2. Interactive rebase to remove the commit
3. Verify with `git log -S"ACCESS_KEY"`
4. Add pattern to .gitignore if needed
5. Document in post-mortem
</details>

**Scenario 2**: You pushed a commit containing an API key 5 commits ago. The key is still active. What do you do?

<details>
<summary>Click to reveal answer</summary>

1. IMMEDIATELY revoke API key (don't wait!)
2. Notify team via Slack/email
3. Use git-filter-repo to clean history
4. Force push with `--force-with-lease`
5. Team must `git pull --force`
6. Monitor API logs for unauthorized usage
7. Conduct post-mortem to prevent recurrence
</details>

---

**Remember**: It's better to act quickly and imperfectly than to delay and expose systems to risk. When in doubt, ROTATE FIRST, then clean up.
