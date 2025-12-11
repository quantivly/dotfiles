# Git Workflow Examples

This document demonstrates common Git workflows using the aliases and tools configured in this dotfiles repository.

## Quick Reference

| Workflow | Key Commands | Description |
|----------|--------------|-------------|
| Feature Branch | `gcb` → `gaa` → `gcam` → `gp` | Create, commit, and push feature branch |
| PR Review | `gh review` → `gh co` → `gd` → `gh approve` | Review and approve pull requests |
| Conflict Resolution | `gl` → `git conflicts` → fix → `gaa` → `gcam` | Resolve merge conflicts |
| WIP Commits | `gwip` → work → `gunwip` → `gcam` | Temporary work-in-progress commits |
| Branch Cleanup | `gco main` → `gl` → cleanup branches | Sync and clean up old branches |

---

## Feature Branch Development Workflow

Standard workflow for developing a new feature in a separate branch.

### Step-by-Step

```bash
# 1. Ensure you're on main and it's up-to-date
gco main
gl  # git pull

# 2. Create new feature branch
gcb feature/user-authentication
# This creates and checks out a new branch

# 3. Make your changes to files
# ... edit files ...

# 4. Stage all changes
gaa  # git add --all

# 5. Commit with descriptive message
gcam "feat: Added user authentication with JWT tokens"
# or for more detailed commit:
gcm "feat: Added user authentication

Implemented JWT-based authentication system with:
- Login endpoint
- Token validation middleware
- Refresh token support"

# 6. Push to remote
gp  # git push

# 7. Create pull request using GitHub CLI
gh pr create -t "feat: Added user authentication" -b "Implements JWT-based auth system

Changes:
- New auth endpoints
- Token validation middleware
- Tests for auth flow"

# or create PR in browser
gh pr create --web
```

### Quick Version

```bash
gco main && gl && gcb feature/my-feature && gaa && gcam "feat: My feature" && gp && gh pr create --web
```

---

## Merge Conflict Resolution Workflow

When you encounter merge conflicts while pulling or merging.

### Step-by-Step

```bash
# 1. Pull latest changes (might cause conflicts)
gl  # git pull

# 2. If conflicts occur, see which files are conflicted
git conflicts
# Output: Lists only files with conflicts

# 3. Open conflicted files in editor
code $(git conflicts)
# or manually: code path/to/conflicted/file.js

# 4. Resolve conflicts in each file
# - Look for <<<<<<< HEAD markers
# - Choose which changes to keep
# - Remove conflict markers

# 5. After resolving, stage the resolved files
gaa  # git add --all

# 6. Complete the merge with a commit
gcam "Resolved merge conflicts with main"

# 7. Push the changes
gp
```

### Advanced: Preview Conflicts Before Merging

```bash
# Before pulling, check what conflicts might occur
gf  # git fetch (don't merge yet)

# View what changed on remote
gd main origin/main

# Now pull and resolve
gl
```

---

## Pull Request Review Workflow

Reviewing and approving PRs submitted by team members.

### Step-by-Step: Local Review

```bash
# 1. View PRs awaiting your review
gh review
# Shows list of PRs where you're requested as reviewer

# 2. Checkout PR locally for testing
gh co 123
# Checks out PR #123 to test locally

# 3. Review the changes
gd  # git diff (see all changes)
git lg  # Pretty log of commits
# or detailed log:
glogp

# 4. Run tests, check functionality
# ... test the changes ...

# 5. If approved, approve the PR
gh approve -b "LGTM! Great work on the authentication system."

# 6. If requesting changes
gh request-changes -b "Please add tests for the edge cases:
- Invalid tokens
- Expired refresh tokens"

# 7. After approval, merge the PR
gh prmerge
# Squashes commits, merges, and deletes the branch

# 8. Return to main and pull updates
gco main && gl
```

### Quick Review Workflow

```bash
# Review, approve, and merge in one flow
gh review | head -5  # See first 5 PRs
gh co 123 && gd && gh approve && gh prmerge && gco main && gl
```

### Advanced: Review Multiple PRs

```bash
# List all non-draft PRs
gh prs

# Filter PRs targeting current branch
gh prs@

# View PR in browser for detailed review
gh prv 123
```

---

## Quick WIP (Work in Progress) Commits

Save work quickly with temporary commits that you can undo later.

### Step-by-Step

```bash
# 1. You're in the middle of work and need to switch branches
# Create a quick WIP commit
gwip
# This runs: git add -A && git commit -m "WIP: Work in progress"

# 2. Switch to another branch to work on something else
gco hotfix/urgent-bug

# 3. Fix the urgent issue
gaa && gcam "fix: Urgent bug fix" && gp

# 4. Return to your feature branch
gco feature/my-feature

# 5. Undo the WIP commit (only if last commit was WIP)
gunwip
# This runs: git log -n 1 | grep -q -c "WIP:" && git reset HEAD~1

# 6. Continue working (files are still changed, just uncommitted)
# ... make more changes ...

# 7. Make proper commit
gaa && gcam "feat: Properly implemented feature"
```

### Use Cases for WIP Commits

**Scenario 1: Need to pull changes**
```bash
gwip  # Save current work
gl    # Pull latest
gunwip  # Restore work as uncommitted changes
# Fix any conflicts, then make proper commit
```

**Scenario 2: Test something quickly**
```bash
gwip  # Save current work
# ... test experimental changes ...
grhh  # git reset --hard HEAD (discard experimental changes)
# Your WIP commit is still there
gunwip  # Restore original work
```

**Scenario 3: Switch tasks urgently**
```bash
gwip  # Save work on Feature A
gco other-branch  # Switch to urgent task
# ... work on urgent task ...
gco feature-a  # Return
gunwip  # Continue Feature A
```

---

## Branch Cleanup Workflow

Keep your repository clean by removing old branches.

### Local Branch Cleanup

```bash
# 1. Switch to main
gco main

# 2. Update main
gl

# 3. View all branches
git branch -a
# or verbose with last commit:
git branch -vv

# 4. Delete merged local branch
git branch -d feature/old-feature

# 5. Force delete unmerged branch (use with caution)
git branch -D feature/abandoned-feature

# 6. Cleanup remote-tracking branches that are deleted on remote
git fetch --prune
# or shorthand:
gf --prune
```

### Bulk Cleanup

```bash
# List merged branches (excluding main/master)
git branch --merged | grep -v "main\|master"

# Delete all merged branches (interactive)
git branch --merged | grep -v "main\|master" | xargs -p git branch -d

# Prune remote branches
git remote prune origin
```

---

## Advanced Git Workflows

### Amend Last Commit

```bash
# Made a typo in commit message or forgot to add a file?
gaa  # Add any missing files
gca  # git commit --amend
# Edit commit message in editor

# Force push amended commit (if already pushed)
# CAUTION: Only do this on feature branches, never on main!
git push --force-with-lease
```

### Interactive Rebase (Clean Up Commit History)

```bash
# View commits on current branch
glog

# Interactive rebase last 3 commits
git rebase -i HEAD~3

# Common operations in interactive rebase:
# - pick: keep commit as-is
# - reword: change commit message
# - squash: combine with previous commit
# - fixup: like squash but discard commit message
# - drop: remove commit

# After rebase, force push (ONLY on feature branches!)
git push --force-with-lease
```

### Stash Workflow (Alternative to WIP)

```bash
# Save current work without committing
git stash push -m "Working on authentication"

# List stashes
git stash list

# Apply most recent stash (keep stash)
git stash apply

# Apply and remove stash
git stash pop

# Apply specific stash
git stash apply stash@{1}

# Clear all stashes
git stash clear
```

### Cherry-Pick Commits

```bash
# Copy a specific commit from another branch
git cherry-pick abc123

# Cherry-pick multiple commits
git cherry-pick abc123 def456

# Cherry-pick with custom message
git cherry-pick abc123 -e
```

---

## GitHub CLI Power Tips

### PR Management

```bash
# Create PR with pre-filled template
gh pr create --template .github/pull_request_template.md

# View PR checks/CI status
gh prchecks 123

# Mark draft as ready
gh prready 123

# Convert back to draft
gh prdraft 123

# Reopen closed PR
gh prreopen 123

# Get PR base branch
gh prbase 123
```

### Workflow Runs

```bash
# View recent workflow runs for current branch
gh runs

# Watch workflow run in real-time
gh runwatch <run-id>

# Rerun failed workflow
gh rerun <run-id>

# View workflow run in browser
gh runview <run-id>
```

### Issue Management

```bash
# View your assigned issues
gh myissues

# Create new issue
gh issue create -t "Bug: Login fails" -b "Description here"

# Close issue
gh issue close 456
```

---

## Troubleshooting

### Undo Last Commit (Keep Changes)

```bash
gundo  # git reset --soft HEAD^
# Commit is undone, files still staged
```

### Undo Last Commit (Discard Changes)

```bash
grhh  # git reset --hard HEAD
# WARNING: This discards all uncommitted changes!
```

### View Beautiful Git Log

```bash
# Basic graph
glog

# All branches
gloga

# Pretty format with author and date
glogp
```

### Find Which Commit Changed a File

```bash
git log --follow --oneline path/to/file.js

# With diff
git log -p path/to/file.js
```

### See Who Changed Each Line (Git Blame)

```bash
git blame path/to/file.js

# Ignore whitespace changes
git blame -w path/to/file.js
```

---

## Best Practices

1. **Commit Messages**
   - Use conventional commit format: `type: description`
   - Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`
   - Example: `feat: Added user authentication`

2. **Branch Names**
   - Use descriptive names: `feature/user-auth`, `fix/login-bug`, `hotfix/security-patch`
   - Avoid generic names like `temp`, `test`, `wip`

3. **Pull Requests**
   - Keep PRs focused and small (< 400 lines when possible)
   - Write clear descriptions explaining WHY, not just WHAT
   - Reference related issues: "Closes #123"

4. **Before Pushing**
   - Run tests: `pytest` or `npm test`
   - Check diff: `gds` (staged changes)
   - Lint code if applicable

5. **Don't Force Push to Main**
   - Never use `git push --force` on main/master branches
   - Use `--force-with-lease` on feature branches only

6. **Sync Frequently**
   - Pull main often: `gco main && gl`
   - Rebase feature branches: `git rebase main`
   - Avoid long-lived feature branches

---

## Keyboard Shortcuts Summary

These are defined in your aliases (`~/.dotfiles/zsh/zshrc.aliases`):

| Alias | Command | Description |
|-------|---------|-------------|
| `gst` | `git status` | View current status |
| `gco` | `git checkout` | Switch branches |
| `gcb` | `git checkout -b` | Create new branch |
| `gaa` | `git add --all` | Stage all changes |
| `gcam` | `git commit -am` | Add and commit |
| `gcm` | `git commit -m` | Commit with message |
| `gca` | `git commit --amend` | Amend last commit |
| `gp` | `git push` | Push to remote |
| `gl` | `git pull` | Pull from remote |
| `gf` | `git fetch` | Fetch without merging |
| `gd` | `git diff` | Show changes |
| `gds` | `git diff --staged` | Show staged changes |
| `glog` | Git log with graph | Pretty commit history |
| `glogp` | Detailed git log | With author and dates |
| `gundo` | `git reset --soft HEAD^` | Undo last commit |
| `gwip` | Quick WIP commit | Save work temporarily |
| `gunwip` | Undo WIP commit | Restore to uncommitted |

See `~/.dotfiles/gh/config.yml` for 35+ GitHub CLI aliases.
