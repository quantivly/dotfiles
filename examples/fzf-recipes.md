# FZF Integration Recipes

This document demonstrates how to use FZF (fuzzy finder) with the integrations configured in this dotfiles repository.

## Quick Reference

| Keybinding | Action | Description |
|------------|--------|-------------|
| `Ctrl+T` | Fuzzy file search | Find and insert file path |
| `Ctrl+R` | Fuzzy history search | Search command history |
| `Alt+C` | Fuzzy directory nav | Change to directory |
| `**<TAB>` | FZF completion | Trigger FZF for paths, commands |

| Function | Command | Description |
|----------|---------|-------------|
| `fcd` | Fuzzy cd | Change to directory with preview |
| `fbr` | Fuzzy branch | Checkout git branch |
| `fco` | Fuzzy commit | Checkout git commit |
| `fshow` | Fuzzy git log | Browse commits with preview |

---

## Built-in FZF Keybindings

These keybindings are automatically configured when FZF is installed.

### Ctrl+T - Fuzzy File Search

Find files interactively and insert path at cursor.

```bash
# Usage: Type command, press Ctrl+T, select file
vim <Ctrl+T>
# FZF opens, search for file, Enter inserts path

code <Ctrl+T>
cat <Ctrl+T>
rm <Ctrl+T>
```

**Features:**
- Searches from current directory recursively
- Preview pane shows file contents (with bat if installed)
- Uses fd if available (respects .gitignore)
- Navigate with arrow keys or vim keys (j/k)

**FZF Search Syntax:**
```bash
# Exact match (quoted)
'myfile

# Prefix match
^myfile

# Suffix match
.py$

# OR operator
.py | .js

# AND operator (space)
test config

# Negation
!test
```

### Ctrl+R - Fuzzy History Search

Search through command history interactively.

```bash
# Press Ctrl+R anywhere
# Type to search history
# Enter to execute, or Tab to edit first
```

**Tips:**
- Recent commands appear first
- Search across all history (50,000 commands)
- Ctrl+R again to toggle sort order
- ESC to cancel

**Example Workflow:**
```bash
# You ran a complex command days ago
# Press Ctrl+R
# Type a few keywords: "docker exec"
# Select the right command
# Edit if needed, then execute
```

### Alt+C - Fuzzy Directory Navigation

Change to directory interactively.

```bash
# Press Alt+C anywhere
# FZF shows directories
# Select one and cd to it
```

**Use Cases:**
```bash
# Jump to project directory quickly
<Alt+C>
# Type "projec"
# Select "~/projects/myapp"
# Instantly cd there

# Navigate complex directory structures
<Alt+C>
# Search for "logs"
# Jump to /var/log/myapp
```

### Tab Completion Enhancement

FZF enhances tab completion for many commands.

```bash
# cd with FZF
cd **<TAB>
# FZF opens with directory list

# Kill process with FZF
kill -9 **<TAB>
# FZF shows process list

# SSH host completion
ssh **<TAB>
# FZF shows hosts from ~/.ssh/config

# Environment variables
export **<TAB>
unset **<TAB>

# Git checkout
git checkout **<TAB>
```

---

## Custom FZF Functions

These functions are defined in `~/.dotfiles/zsh/zshrc.conditionals`.

### fcd - Fuzzy Change Directory

Change directory with file tree preview.

```bash
# Basic usage
fcd
# FZF shows directories from current location
# Navigate and press Enter

# Start from specific directory
fcd /etc
# Search within /etc and subdirectories

# Start from home
fcd ~
```

**What It Does:**
- Uses fd (or find) to list directories
- Shows directory tree preview in right pane
- Respects .gitignore (when using fd)
- Faster than Alt+C for targeted searches

**Example:**
```bash
# Jump to deeply nested directory
fcd
# Type "comp" to filter to "components"
# Press Enter, now in components directory
```

### fbr - Fuzzy Branch Checkout

Checkout git branches interactively.

```bash
# In any git repository
fbr
# FZF shows all branches (local and remote)
# Select branch to checkout
```

**Features:**
- Lists both local and remote branches
- Shows branch names clearly
- Automatically handles remote branch checkout
- Strips remote prefixes (origin/feature → feature)

**Example Workflow:**
```bash
# See available branches
fbr
# Type "feat" to filter feature branches
# Select "feature/user-auth"
# Automatically checks out (creates local branch if remote)
```

**Equivalent Commands:**
```bash
# Instead of:
git branch -a
git checkout feature/user-auth

# Just do:
fbr  # and select
```

### fco - Fuzzy Commit Checkout

Checkout specific git commits interactively.

```bash
# In any git repository
fco
# FZF shows commit history
# Select commit to checkout (detached HEAD)
```

**Use Cases:**

**1. Test old version:**
```bash
fco
# Select old commit
# Test functionality
# Return to branch: git checkout main
```

**2. Find when bug was introduced:**
```bash
fco
# Checkout progressively older commits
# Test each one
# Identify the breaking commit
```

**3. Create branch from old commit:**
```bash
fco
# Select commit
# Create branch: git checkout -b fix-from-old-commit
```

**Features:**
- Shows commits in reverse chronological order
- Displays hash and commit message
- Easy navigation through history
- One-line per commit for clarity

### fshow - Git Commit Browser

Browse git history with rich preview.

```bash
# In any git repository
fshow
# Interactive commit browser with preview pane
```

**Features:**
- Left pane: Commit graph with colors
- Right pane: Live preview of selected commit (60% width)
- Preview updates automatically as you navigate
- Press Ctrl+M to view full commit in pager (less)
- Ctrl+S to toggle sort order

**Controls:**
- `Up/Down` or `j/k` - Navigate commits (preview updates automatically)
- `Ctrl+M` - Open full commit in pager (less) for detailed viewing
- `Ctrl+S` - Toggle sort order
- `Ctrl+C` or `ESC` - Exit
- Type to filter commits by message/hash

**Use Cases:**

**1. Find specific change:**
```bash
fshow
# Type keywords to filter commits
# Navigate to relevant commit
# Press Ctrl+M to see full diff
```

**2. Understand code history:**
```bash
fshow
# Browse through commits
# See who changed what and when
# Understand evolution of code
```

**3. Review before release:**
```bash
fshow
# Review all commits since last release
# Verify what's included
# Note breaking changes
```

---

## Advanced FZF Recipes

### Process Management

**Kill process interactively:**
```bash
kill -9 $(ps aux | fzf | awk '{print $2}')
# Shows process list in FZF
# Select process to kill
# Extracts PID and kills it
```

**More user-friendly version:**
```bash
ps aux | fzf --header="Select process to kill" | awk '{print $2}' | xargs kill -9
```

**Watch specific process:**
```bash
watch -n 1 "ps aux | grep $(ps aux | fzf | awk '{print $2}')"
```

### File Operations

**Open file in editor:**
```bash
code $(fzf)
# or
vim $(fzf)
# Select file from FZF, opens in editor
```

**Copy file path to clipboard:**
```bash
fzf | tr -d '\n' | pbcopy
# Select file, path copied to clipboard
```

**Delete files interactively (CAREFUL!):**
```bash
rm -i $(fzf -m)
# -m allows multi-select (Tab to select multiple)
# -i asks for confirmation before deleting
```

**Find and edit files matching pattern:**
```bash
vim $(rg -l "TODO" | fzf)
# Find files containing "TODO"
# Select file in FZF
# Open in vim
```

### Git Advanced

**Interactive git add:**
```bash
git ls-files -m -o --exclude-standard | fzf -m --preview 'git diff --color=always {}' | xargs git add
# Shows modified/new files
# Preview shows diff
# Multi-select files to stage
```

**Find commits by message:**
```bash
git log --oneline | fzf --preview 'git show --color=always {1}'
# Search commit messages
# Preview shows full commit
```

**Cherry-pick commits:**
```bash
git cherry-pick $(git log --oneline | fzf | awk '{print $1}')
# Select commit to cherry-pick
# Automatically applies it
```

**Interactive rebase:**
```bash
# Use the built-in frb function (recommended):
frb
# Shows branches sorted by recent activity
# Select base branch to rebase onto
# Preview shows commits that differ

# Or rebase onto a specific commit:
git rebase -i $(git log --oneline | fzf | awk '{print $1}')^
# Select commit to start rebase from
# Opens interactive rebase
```

### Docker Integration

**Exec into container:**
```bash
docker exec -it $(dps | fzf | awk '{print $1}') bash
# Select running container
# Access its shell
```

**View container logs:**
```bash
docker logs -f $(dps | fzf | awk '{print $1}')
# Select container
# Follow its logs
```

**Stop containers selectively:**
```bash
dps | fzf -m | awk '{print $1}' | xargs docker stop
# Multi-select containers
# Stop selected ones
```

### SSH and Remote

**SSH to host:**
```bash
# Add to ~/.bashrc or ~/.zshrc:
fssh() {
  ssh $(grep "Host " ~/.ssh/config | grep -v '*' | sed 's/Host //' | fzf)
}

# Usage:
fssh
# Select host from SSH config
# Connects automatically
```

**SCP file to host:**
```bash
scp $(fzf) $(grep "Host " ~/.ssh/config | sed 's/Host //' | fzf):~/
# Select file with FZF
# Select destination host with FZF
# Copies file
```

### Search and Replace

**Find and replace in files:**
```bash
rg "old_text" | fzf -m | cut -d: -f1 | sort -u | xargs sed -i 's/old_text/new_text/g'
# Find files containing "old_text"
# Select files in FZF (multi-select)
# Replace in selected files
```

**Search within selected files:**
```bash
rg --color=always "pattern" $(fzf -m) | less -R
# Select files with FZF
# Search within them
# View results with colors
```

---

## FZF Configuration

Your FZF configuration is in `~/.dotfiles/zsh/zshrc.conditionals`.

### Color Scheme (Dracula)

```bash
export FZF_DEFAULT_OPTS='
  --height 40%
  --layout=reverse
  --border
  --inline-info
  --color=fg:#f8f8f2,bg:#282a36,hl:#bd93f9
  --color=fg+:#f8f8f2,bg+:#44475a,hl+:#bd93f9
  --color=info:#ffb86c,prompt:#50fa7b,pointer:#ff79c6
  --color=marker:#ff79c6,spinner:#ffb86c,header:#6272a4
'
```

### Default Command (with fd)

```bash
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
```

**What it does:**
- Uses fd (faster than find)
- Searches for files (`--type f`)
- Includes hidden files (`--hidden`)
- Follows symlinks (`--follow`)
- Excludes .git directory

### Preview Configuration

```bash
export FZF_CTRL_T_OPTS="--preview 'bat --color=always --style=numbers --line-range=:500 {}'"
```

**Features:**
- Shows file contents with syntax highlighting (bat)
- Line numbers for reference
- First 500 lines (for performance)
- Colors preserved

---

## FZF Power User Tips

### 1. Multi-Select Mode

Use `-m` or `--multi` to enable multi-select:

```bash
# Select multiple files
fzf -m

# In multi-select mode:
# Tab - Select/deselect item
# Shift+Tab - Select/deselect and move up
# Enter - Confirm selection
```

### 2. Preview Window Customization

```bash
# Preview on right (default)
fzf --preview 'cat {}'

# Preview on top
fzf --preview 'cat {}' --preview-window up:30%

# Preview on left
fzf --preview 'cat {}' --preview-window left:50%

# Toggle preview with Ctrl+/
fzf --preview 'cat {}' --bind 'ctrl-/:toggle-preview'
```

### 3. Custom Key Bindings

```bash
# Enter to view, Ctrl+O to edit
fzf --bind 'enter:execute(cat {})' --bind 'ctrl-o:execute(vim {})'

# Ctrl+Y to copy path
fzf --bind 'ctrl-y:execute-silent(echo {} | pbcopy)'

# Ctrl+E to open in default editor
fzf --bind 'ctrl-e:execute($EDITOR {})'
```

### 4. Filter by File Type

```bash
# Only Python files
fzf --query '.py$'

# Only in specific directory
fd --type f . ~/projects | fzf

# Exclude patterns
fd --type f --exclude '*.log' | fzf
```

### 5. Search within Search

```bash
# Initial filter with ripgrep, then FZF
rg "import" --files-with-matches | fzf --preview 'bat --color=always {}'

# Search file contents, then select file
rg --color=always --line-number "pattern" | fzf --ansi --delimiter : --preview 'bat --color=always {1} --highlight-line {2}'
```

---

## Practical Workflows

### Workflow 1: Find and Edit Config File

```bash
# One-liner:
vim $(fzf --query '.conf$' --select-1)

# If only one .conf file matches, opens immediately
# If multiple, shows FZF to select
```

### Workflow 2: Clean Up Old Branches

```bash
# Find merged branches
git branch --merged | grep -v main | fzf -m

# Delete selected branches
git branch --merged | grep -v main | fzf -m | xargs git branch -d
```

### Workflow 3: Quick Note Taking with Fuzzy Search

```bash
# Add to ~/.zshrc:
notes() {
  local notes_dir=~/notes
  local note=$(fd . $notes_dir --type f | fzf --preview 'bat --color=always {}')
  if [ -n "$note" ]; then
    $EDITOR "$note"
  else
    read "filename?New note name: "
    $EDITOR "$notes_dir/$filename.md"
  fi
}

# Usage:
notes
# Select existing note or create new
```

### Workflow 4: Docker Container Debugging

```bash
# Quick access to container shell
dex_fzf() {
  local container=$(docker ps --format '{{.Names}}' | fzf)
  [[ -n "$container" ]] && docker exec -it "$container" bash
}

# Usage:
dex_fzf
```

### Workflow 5: Log File Investigation

```bash
# Find and tail log files
tail -f $(fd . /var/log --type f | fzf --preview 'tail -20 {}')

# Search within logs
rg "ERROR" /var/log --files-with-matches | fzf --preview 'rg --color=always "ERROR" {}'
```

---

## Troubleshooting

### FZF Not Found

```bash
# Check if installed
command -v fzf

# Install (Ubuntu)
sudo apt install fzf

# Install (macOS)
brew install fzf

# Install via git
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install
```

### Preview Not Working

```bash
# Install bat for syntax highlighting
sudo apt install bat  # Ubuntu
brew install bat  # macOS

# Or disable preview
fzf --no-preview
```

### fd Not Found

```bash
# FZF will fall back to find
# But for better performance, install fd:
sudo apt install fd-find  # Ubuntu (binary is 'fdfind')
brew install fd  # macOS
```

### Ctrl+T Not Working

```bash
# Re-source FZF key bindings
source /usr/share/doc/fzf/examples/key-bindings.zsh  # Ubuntu
source ~/.fzf.zsh  # If installed via git

# Or reinstall FZF
~/.fzf/install
```

---

## Best Practices

1. **Use Multi-Select for Batch Operations**
   - Always use `-m` when operating on multiple items
   - Tab to select, Shift+Tab to deselect

2. **Leverage Previews**
   - Previews help you verify before selecting
   - Customize preview window size for your workflow
   - Use bat for syntax-highlighted previews

3. **Combine with ripgrep**
   - FZF for navigation, ripgrep for content search
   - Powerful combination for code exploration

4. **Create Custom Functions**
   - Wrap common FZF patterns in functions
   - Add to ~/.zshrc.local for personal workflows

5. **Learn the Query Syntax**
   - `'` for exact match
   - `^` for prefix, `$` for suffix
   - `!` for exclusion
   - `|` for OR, space for AND

---

## FZF Functions Quick Reference

Defined in `~/.dotfiles/zsh/zshrc.conditionals`:

| Function | Description | Usage |
|----------|-------------|-------|
| `fcd` | Fuzzy cd with preview | `fcd` or `fcd /path` |
| `fbr` | Fuzzy git branch checkout | `fbr` |
| `fco` | Fuzzy git commit checkout | `fco` |
| `fshow` | Git commit browser | `fshow` |

Keybindings (automatic):

| Key | Action | Description |
|-----|--------|-------------|
| `Ctrl+T` | File search | Insert file path |
| `Ctrl+R` | History search | Search commands |
| `Alt+C` | Directory jump | Change directory |
| `**<TAB>` | FZF completion | Enhanced completion |

---

## Additional Resources

- [FZF GitHub](https://github.com/junegunn/fzf)
- [FZF Wiki](https://github.com/junegunn/fzf/wiki)
- [FZF Examples](https://github.com/junegunn/fzf/wiki/examples)
- [Advanced FZF Examples](https://github.com/junegunn/fzf/blob/master/ADVANCED.md)

Your dotfiles include carefully tuned FZF integration - explore and customize further in:
- `~/.dotfiles/zsh/zshrc.conditionals` (lines 74-133)
