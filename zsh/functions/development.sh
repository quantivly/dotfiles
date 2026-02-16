# shellcheck shell=bash
#==============================================================================
# Development Functions
#==============================================================================
# Consolidated development workflow functions for Git, Docker, and FZF operations.
# This module combines git-workflows.git, docker-management.docker, and fzf-integrations.fzf
# into a single, logically organized file for easier maintenance.
#
# Sections:
#   1. Git Functions - Enhanced git operations with fuzzy finding and safety
#   2. Docker Functions - Container and image management with interactive selection
#   3. FZF Functions - Fuzzy finding for navigation, files, and processes
#   4. Tmux Functions - Session management and layout automation
#
# See individual section headers below for detailed function listings.
#==============================================================================

# =============================================================================
# Git Functions
# =============================================================================
# Enhanced git operations with fuzzy finding, safety confirmations, and automation.
# All functions include inline "Usage: ..." documentation.
#
# Workflow Functions:
#   - gwtc: Git worktree create helper (creates worktree in ../worktrees/<branch>)
#   - git_cleanup: Automated branch cleanup with confirmations
#   - fgit: Menu-driven git operations with fzf
#   - fstash: Fuzzy git stash management
#   - fdiff: Fuzzy file selection for git diff
#   - frb: Fuzzy git interactive rebase
#   - ftag: Fuzzy git tag operations
#   - fmerge: Fuzzy merge with preview
#   - ffiles-changed: Show files changed in current branch
#
# Safety Functions:
#   - gpush-safe: Prevents accidental pushes to protected branches
#   - gpf-safe: Safe force push with explicit confirmation
#   - gco-safe: Warns before checkout if uncommitted changes exist
#
# Smart Display:
#   - gd: Smart git diff (adapts to terminal width)
#   - gdw: Force wide/side-by-side diff
#   - gdv: Force unified/vertical diff
#
# Requires: git, fzf (for fuzzy functions), delta (for gd)
# See also: examples/git-workflows.md
# =============================================================================

# Git worktree wrapper - creates worktree in ../worktrees/<branch>
# Note: 'gwt' is already defined by oh-my-zsh git plugin as 'git worktree'
# So we use 'gwtc' (git worktree create) for this helper function
gwtc() {
  # Usage: gwtc <branch_name>
  # Creates a git worktree in ../worktrees/<branch_name> and cd into it
  if [ $# -ne 1 ]; then
    echo "Usage: gwtc <branch_name>"
    echo "Creates a git worktree in ../worktrees/<branch_name>"
    return 1
  fi
  local worktree_dir="../worktrees/$1"
  git worktree add "$worktree_dir" "$1" && cd "$worktree_dir"
}

#==============================================================================
# Git Branch Management & Automation
#==============================================================================

# git_cleanup - Automated git branch cleanup
git_cleanup() {
  echo "=== Git Branch Cleanup ==="
  echo

  # Show current status
  echo "Current branch: $(git branch --show-current)"
  echo "All branches:"
  git branch -a
  echo

  # Find merged branches (excluding main/master/develop)
  local merged_branches=$(git branch --merged | grep -v -E '^\*|master|main|develop' | xargs)

  if [[ -n "$merged_branches" ]]; then
    echo "Merged branches that can be deleted:"
    echo "$merged_branches"
    echo

    printf "Delete these merged branches? [y/N] "
    read -r response
    case "$response" in
      [yY]|[yY][eE][sS])
        echo "$merged_branches" | xargs git branch -d
        echo "Merged branches deleted."
        ;;
      *)
        echo "Cleanup cancelled."
        ;;
    esac
  else
    echo "No merged branches found to clean up."
  fi

  echo
  echo "Remote tracking branch cleanup..."
  git remote prune origin

  # Optionally clean up remote references
  printf "Remove stale remote tracking branches? [y/N] "
  read -r response
  case "$response" in
    [yY]|[yY][eE][sS])
      git branch -r --merged | grep -v -E 'origin/(master|main|develop)' | sed 's/origin\///' | xargs -I {} git push origin --delete {} 2>/dev/null || true
      echo "Remote branch cleanup completed."
      ;;
    *)
      echo "Remote cleanup skipped."
      ;;
  esac
}

# fgit - Enhanced git operations with fzf
fgit() {
  local action

  echo "Git Operations:"
  echo "1. Fuzzy checkout branch"
  echo "2. Fuzzy checkout commit"
  echo "3. Fuzzy git log"
  echo "4. Fuzzy git stash"
  echo "5. Fuzzy git diff"
  echo "6. Fuzzy interactive rebase"
  echo
  read -p "Select action (1-6): " action

  case $action in
    1) fbr ;;
    2) fco ;;
    3) fshow ;;
    4) fstash ;;
    5) fdiff ;;
    6) frb ;;
    *) echo "Invalid selection" ;;
  esac
}

# fstash - Fuzzy git stash management
fstash() {
  local stash_list stash

  stash_list=$(git stash list)
  if [[ -z "$stash_list" ]]; then
    echo "No stashes found"
    return 1
  fi

  stash=$(echo "$stash_list" | fzf --header='Select stash to apply' --preview='git stash show -p {1}' | cut -d: -f1)

  if [[ -n "$stash" ]]; then
    echo "Applying stash: $stash"
    git stash apply "$stash"
  fi
}

# fdiff - Fuzzy git diff with file selection
fdiff() {
  local file

  file=$(git diff --name-only | fzf --header='Select file for diff' --preview='git diff --color=always {}')

  if [[ -n "$file" ]]; then
    git diff "$file"
  fi
}

# frb - Fuzzy git interactive rebase
frb() {
  local branches branch current_branch

  current_branch=$(git branch --show-current)

  # Get all branches (local and remote)
  branches=$(git branch --all --sort=-committerdate | grep -v HEAD) || return 1

  if [[ -z "$branches" ]]; then
    echo "No branches found"
    return 1
  fi

  branch=$(echo "$branches" | \
    fzf --ansi \
        --header="Select base branch for interactive rebase (current: $current_branch)" \
        --preview='git log --graph --color=always --format="%C(auto)%h%d %s %C(black)%C(bold)%cr" $(echo {} | sed "s/.* //" | sed "s#remotes/[^/]*/##")...HEAD' \
        --preview-window=right:60%:wrap | \
    sed "s/.* //" | sed "s#remotes/[^/]*/##")

  if [[ -n "$branch" ]]; then
    echo "Starting interactive rebase onto: $branch"
    git rebase -i "$branch"
  else
    echo "No branch selected"
  fi
}

#==============================================================================
# Git Safety Functions
#==============================================================================
# Enhanced git operations with safety confirmations to prevent common mistakes
#==============================================================================

# Safe git push - prevents accidental pushes to protected branches
gpush-safe() {
  # Usage: gpush-safe [git push options]
  # Prompts for confirmation when pushing to main, master, or develop branches
  local branch="$(git branch --show-current 2>/dev/null)"

  if [[ -z "$branch" ]]; then
    echo "❌ Not in a git repository"
    return 1
  fi

  # Check for protected branches
  if [[ "$branch" == "main" || "$branch" == "master" || "$branch" == "develop" ]]; then
    echo "⚠️  WARNING: You're about to push to '$branch'"
    echo ""
    printf "Type the branch name to confirm: "
    read -r confirm

    if [[ "$confirm" != "$branch" ]]; then
      echo "❌ Push aborted"
      return 1
    fi
  fi

  git push "$@"
}

# Safe force push with explicit confirmation
gpf-safe() {
  # Usage: gpf-safe [git push options]
  # Requires typing 'force' to confirm force push operation
  local branch="$(git branch --show-current 2>/dev/null)"

  if [[ -z "$branch" ]]; then
    echo "❌ Not in a git repository"
    return 1
  fi

  echo "⚠️  FORCE PUSH REQUESTED"
  echo "Branch: $branch"
  echo "Remote: $(git remote get-url origin 2>/dev/null || echo 'unknown')"
  echo ""
  echo "This will OVERWRITE remote history!"
  echo ""
  printf "Type 'force' to confirm: "
  read -r confirm

  if [[ "$confirm" != "force" ]]; then
    echo "❌ Force push aborted"
    return 1
  fi

  git push --force-with-lease "$@"
}

# Warn before checkout if uncommitted changes exist
gco-safe() {
  # Usage: gco-safe <branch>
  # Prompts for confirmation if there are uncommitted changes
  if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
    echo "⚠️  Warning: Uncommitted changes detected"
    echo ""
    git status --short
    echo ""
    printf "Continue checkout? [y/N] "
    read -r response
    [[ "$response" =~ ^[Yy]$ ]] || return 1
  fi
  git checkout "$@"
}

#==============================================================================
# Git Delta Smart Display
#==============================================================================
# Smart git diff wrapper that adapts to terminal width
# Uses side-by-side mode for wide terminals, unified for narrow (e.g., VSCode split)
#==============================================================================

# Smart git diff - adapts layout based on terminal width
# Override oh-my-zsh's `gd` alias with a smart function
unalias gd 2>/dev/null  # Remove oh-my-zsh alias if it exists

gd() {
  # Usage: gd [git diff options]
  # Automatically uses side-by-side for wide terminals (>= 160 cols)
  # and unified diff for narrow terminals (< 160 cols)
  local width=$(tput cols 2>/dev/null || echo "80")
  local threshold="${GD_WIDTH_THRESHOLD:-160}"  # Configurable via env var

  if [ "$width" -ge "$threshold" ]; then
    git -c delta.side-by-side=true diff "$@"
  else
    git -c delta.side-by-side=false diff "$@"
  fi
}

# Variants for explicit control
alias gdw='git -c delta.side-by-side=true diff'   # Force wide/side-by-side
alias gdv='git -c delta.side-by-side=false diff'  # Force unified/vertical

#==============================================================================
# Additional FZF Git Functions
#==============================================================================
# Enhanced fuzzy finding functions for git operations
# Requires: fzf, bat/batcat (optional for preview)
#==============================================================================

# Fuzzy git tag operations
ftag() {
  # Usage: ftag
  # Browse git tags with fuzzy finder, then checkout, show, or delete selected tag
  local tag
  tag=$(git tag | sort -V | \
    fzf --preview 'git show --color=always {} --stat')

  [[ -z "$tag" ]] && return 0

  echo "Selected tag: $tag"
  echo "1) Checkout tag"
  echo "2) Show tag details"
  echo "3) Delete tag"
  printf "Choice [1]: "
  read -r choice

  case "${choice:-1}" in
    1) git checkout "$tag" ;;
    2) git show "$tag" ;;
    3) git tag -d "$tag" ;;
  esac
}

# Fuzzy merge with preview
fmerge() {
  # Usage: fmerge
  # Select branch to merge with fuzzy finder and preview of commits
  local branch
  branch=$(git branch --all | grep -v HEAD | \
    fzf --preview 'git log --color=always --oneline --graph {}' \
        --preview-window right:60%)

  [[ -z "$branch" ]] && return 0

  branch="${branch##*/}"  # Remove remotes/origin/ prefix
  branch="${branch#"${branch%%[![:space:]]*}"}"  # Trim leading whitespace

  echo "Merging: $branch"
  git merge "$branch"
}

# Show files changed in current branch with preview
ffiles-changed() {
  # Usage: ffiles-changed [base-branch]
  # Shows files changed in current branch compared to base (default: main)
  local base="${1:-main}"
  local file

  file=$(git diff --name-only "$base"...HEAD | \
    fzf --preview "git diff --color=always $base...HEAD -- {}" \
        --preview-window right:60%)

  [[ -n "$file" ]] && git diff "$base"...HEAD -- "$file"
}

# =============================================================================
# Docker Functions
# =============================================================================
# Enhanced Docker operations with intelligent defaults and FZF integration.
# All functions include inline "Usage: ..." documentation.
#
# Interactive Functions:
#   - dexec: Fuzzy Docker container exec
#   - dlogs: Fuzzy Docker container logs
#   - dkill: Fuzzy Docker container killer
#   - dimages: Fuzzy Docker image management
#   - dshell: Intelligent shell detection and execution
#   - dnetwork: Network management with fzf
#   - dvolume: Volume management with fzf
#   - dstats-live: Container resource monitoring
#
# Bulk Operations (with safety confirmations):
#   - dstop: Stop all running containers
#   - dstopa: Stop all containers (running and stopped)
#   - drm: Remove all containers
#   - drmi: Remove all images
#   - dprune: Complete Docker cleanup
#
# Requires: docker, fzf (for interactive functions), bat/batcat (optional for JSON preview)
# See also: examples/docker-workflows.md
# =============================================================================

# dexec - Fuzzy Docker container exec
dexec() {
  local container cmd

  # Select container interactively
  container=$(docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | tail -n +2 | fzf --header='Select container for exec' | awk '{print $1}')

  if [[ -z "$container" ]]; then
    echo "No container selected"
    return 1
  fi

  # Default command or use provided command
  cmd="${1:-bash}"

  echo "Executing '$cmd' in container: $container"
  docker exec -it "$container" "$cmd"
}

# dlogs - Fuzzy Docker container logs
dlogs() {
  local container

  container=$(docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | tail -n +2 | fzf --header='Select container for logs' | awk '{print $1}')

  if [[ -n "$container" ]]; then
    echo "Showing logs for container: $container"
    docker logs -f "$container"
  else
    echo "No container selected"
  fi
}

# dkill - Fuzzy Docker container killer
dkill() {
  local containers

  containers=$(docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" | tail -n +2 | fzf --multi --header='Select container(s) to stop' | awk '{print $1}')

  if [[ -n "$containers" ]]; then
    echo "Stopping containers: $containers"
    echo "$containers" | xargs docker stop
  else
    echo "No containers selected"
  fi
}

# dimages - Fuzzy Docker image management
dimages() {
  local action image

  echo "Docker Image Management:"
  echo "1. Remove image(s)"
  echo "2. Inspect image"
  echo "3. History of image"
  echo
  read -p "Select action (1-3): " action

  case $action in
    1)
      image=$(docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.ID}}" | tail -n +2 | fzf --multi --header='Select image(s) to remove' | awk '{print $4}')
      if [[ -n "$image" ]]; then
        echo "Removing images: $image"
        echo "$image" | xargs docker rmi
      fi
      ;;
    2)
      image=$(docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.ID}}" | tail -n +2 | fzf --header='Select image to inspect' | awk '{print $4}')
      if [[ -n "$image" ]]; then
        docker inspect "$image"
      fi
      ;;
    3)
      image=$(docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.ID}}" | tail -n +2 | fzf --header='Select image for history' | awk '{print $4}')
      if [[ -n "$image" ]]; then
        docker history "$image"
      fi
      ;;
    *)
      echo "Invalid selection"
      ;;
  esac
}

# Intelligent shell detection and execution
dshell() {
  # Usage: dshell
  # Opens fuzzy container selector, then tries shells in order: zsh, bash, sh, ash
  if ! command -v docker &>/dev/null; then
    echo "❌ Docker not installed"
    return 1
  fi

  local container
  container=$(docker ps --format '{{.Names}}' | fzf --height 40% --header 'Select container')
  [[ -z "$container" ]] && return 0

  # Try shells in order of preference
  for shell in zsh bash sh ash; do
    if docker exec "$container" which "$shell" &>/dev/null; then
      echo "🐚 Opening $shell in $container..."
      docker exec -it "$container" "$shell"
      return 0
    fi
  done

  echo "❌ No shell found in container"
  return 1
}

# Network management with fzf
dnetwork() {
  # Usage: dnetwork
  # Interactive Docker network management menu
  if ! command -v docker &>/dev/null; then
    echo "❌ Docker not installed"
    return 1
  fi

  echo "Docker Network Operations:"
  echo "1) List networks"
  echo "2) Inspect network"
  echo "3) Remove network"
  echo "4) Prune unused networks"
  printf "Select [1]: "
  read -r choice

  case "${choice:-1}" in
    1) docker network ls ;;
    2)
      local net
      net=$(docker network ls --format '{{.Name}}' | fzf --header 'Select network to inspect')
      [[ -n "$net" ]] && docker network inspect "$net" | bat -l json 2>/dev/null || docker network inspect "$net"
      ;;
    3)
      local net
      net=$(docker network ls --format '{{.Name}}' | fzf --header 'Select network to remove')
      [[ -n "$net" ]] && docker network rm "$net"
      ;;
    4)
      echo "⚠️  This will remove all unused networks"
      printf "Proceed? [y/N] "
      read -r confirm
      [[ "$confirm" =~ ^[Yy]$ ]] && docker network prune -f
      ;;
  esac
}

# Volume management with fzf
dvolume() {
  # Usage: dvolume
  # Interactive Docker volume management menu
  if ! command -v docker &>/dev/null; then
    echo "❌ Docker not installed"
    return 1
  fi

  echo "Docker Volume Operations:"
  echo "1) List volumes"
  echo "2) Inspect volume"
  echo "3) Remove volumes (multi-select)"
  echo "4) Prune unused volumes"
  printf "Select [1]: "
  read -r choice

  case "${choice:-1}" in
    1) docker volume ls ;;
    2)
      local vol
      vol=$(docker volume ls --format '{{.Name}}' | fzf --header 'Select volume to inspect')
      [[ -n "$vol" ]] && docker volume inspect "$vol" | bat -l json 2>/dev/null || docker volume inspect "$vol"
      ;;
    3)
      local vols
      vols=$(docker volume ls --format '{{.Name}}' | fzf --multi --header 'Select volumes to remove (Tab for multi-select)')
      [[ -n "$vols" ]] && echo "$vols" | xargs docker volume rm
      ;;
    4)
      echo "⚠️  This will remove all unused volumes"
      printf "Proceed? [y/N] "
      read -r confirm
      [[ "$confirm" =~ ^[Yy]$ ]] && docker volume prune -f
      ;;
  esac
}

# Container resource monitoring (enhanced dps)
dstats-live() {
  # Usage: dstats-live
  # Shows real-time resource usage for all running containers
  if ! command -v docker &>/dev/null; then
    echo "❌ Docker not installed"
    return 1
  fi

  docker stats --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
}

# ==============================================================================
# Bulk Container/Image Operations with Safety Confirmations
# ==============================================================================
# All functions use confirm() helper and iterate safely with while loops

dstop() {
  # Security: Uses container IDs (-q) not names to avoid injection vulnerabilities
  local containers=$(docker ps -q)
  if [ -z "$containers" ]; then
    echo "No running containers to stop."
    return 0
  fi
  echo "This will stop all running containers:"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
  echo
  if confirm "Proceed?"; then
    # Use while loop for safe iteration (handles any edge cases)
    while IFS= read -r container; do
      docker stop "$container" || echo "Failed to stop $container"
    done <<< "$containers"
  else
    echo "Operation cancelled."
  fi
}

dstopa() {
  # Security: Uses container IDs (-aq) not names to avoid injection vulnerabilities
  local containers=$(docker ps -aq)
  if [ -z "$containers" ]; then
    echo "No containers to stop."
    return 0
  fi
  echo "This will stop ALL containers (running and stopped):"
  docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
  echo
  if confirm "Proceed?"; then
    # Use while loop for safe iteration (handles any edge cases)
    while IFS= read -r container; do
      docker stop "$container" || echo "Failed to stop $container"
    done <<< "$containers"
  else
    echo "Operation cancelled."
  fi
}

drm() {
  # Security: Uses container IDs (-aq) not names to avoid injection vulnerabilities
  local containers=$(docker ps -aq)
  if [ -z "$containers" ]; then
    echo "No containers to remove."
    return 0
  fi
  echo "This will REMOVE all containers:"
  docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
  echo
  if confirm "Proceed?"; then
    # Use while loop for safe iteration (handles any edge cases)
    while IFS= read -r container; do
      docker rm "$container" || echo "Failed to remove $container"
    done <<< "$containers"
  else
    echo "Operation cancelled."
  fi
}

drmi() {
  # Security: Uses image IDs (-q) not names to avoid injection vulnerabilities
  local images=$(docker images -q)
  if [ -z "$images" ]; then
    echo "No images to remove."
    return 0
  fi
  echo "This will REMOVE all Docker images:"
  docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
  echo
  if confirm "Proceed?"; then
    # Use while loop for safe iteration (handles any edge cases)
    while IFS= read -r image; do
      docker rmi "$image" || echo "Failed to remove $image"
    done <<< "$images"
  else
    echo "Operation cancelled."
  fi
}

dprune() {
  echo "⚠️  WARNING: This will DELETE:"
  echo "   - All stopped containers"
  echo "   - All unused networks"
  echo "   - All unused images (not just dangling ones)"
  echo "   - All unused volumes"
  echo "   - All build cache"
  echo
  if confirm "This action cannot be undone. Proceed?"; then
    docker system prune -af --volumes
  else
    echo "Operation cancelled."
  fi
}

# =============================================================================
# FZF Interactive Functions
# =============================================================================
# Enhanced fuzzy finding functions for navigation, files, processes, and code.
# All functions include inline "Usage: ..." documentation.
#
# Functions:
#   - fcd: Fuzzy directory search and cd with enhanced preview
#   - fkill: Fuzzy process killer with preview
#   - fenv: Browse environment variables with fzf
#   - fssh: SSH host selection from config/known_hosts
#   - fport: Find what's using a specific port
#   - fls: Fuzzy file browser with content preview
#   - fzgrep: Fuzzy grep with file preview and jump-to-line
#
# Requires: fzf, fd/fdfind (optional for fcd), bat/batcat (optional for preview),
#           ripgrep (optional for fzgrep)
# See also: examples/fzf-recipes.md
# =============================================================================

# Find and cd to a directory using fzf
fcd() {
  # Usage: fcd [starting_directory]
  # Fuzzy find directories and cd into selection with enhanced preview
  local dir
  local start_dir="${1:-.}"

  # Enhanced preview showing directory contents and git status if applicable
  local preview_cmd='ls -la {} 2>/dev/null; echo ""; if [ -d {}/.git ]; then echo "Git repo:"; git -C {} status --short 2>/dev/null || echo "Git status unavailable"; fi'

  # Use fd if available (much faster), otherwise fall back to find
  if command -v fd &> /dev/null; then
    dir=$(fd --type d --hidden --follow \
      --exclude .git --exclude node_modules --exclude .cache \
      --exclude .venv --exclude venv \
      --exclude build --exclude dist --exclude target \
      --exclude .npm --exclude .cargo --exclude .gradle \
      . "$start_dir" | fzf +m \
      --header "Navigate to directory (showing from: $start_dir)" \
      --preview "$preview_cmd" \
      --preview-window=right:50%:wrap)
  elif command -v fdfind &> /dev/null; then
    # Ubuntu installs it as fdfind
    dir=$(fdfind --type d --hidden --follow \
      --exclude .git --exclude node_modules --exclude .cache \
      --exclude .venv --exclude venv \
      --exclude build --exclude dist --exclude target \
      --exclude .npm --exclude .cargo --exclude .gradle \
      . "$start_dir" | fzf +m \
      --header "Navigate to directory (showing from: $start_dir)" \
      --preview "$preview_cmd" \
      --preview-window=right:50%:wrap)
  else
    # Fallback to find with exclusions
    dir=$(find "$start_dir" -type d \( \
      -name .git -o -name node_modules -o -name .cache \
      -o -name .venv -o -name venv \
      -o -name build -o -name dist -o -name target \
      -o -name .npm -o -name .cargo -o -name .gradle \
      \) -prune -o -type d -print 2>/dev/null | fzf +m \
      --header "Navigate to directory (showing from: $start_dir)" \
      --preview "$preview_cmd" \
      --preview-window=right:50%:wrap)
  fi

  if [ -n "$dir" ]; then
    cd "$dir" && echo "Changed to: $(pwd)"
  fi
}

# fkill - Fuzzy process killer
fkill() {
  local pid
  if [[ $# -gt 0 ]]; then
    # If arguments provided, kill those processes
    kill -9 "$@"
  else
    # Interactive selection with fzf
    pid=$(ps -ef | sed 1d | fzf --multi --header='Select process(es) to kill' --preview='echo {}' | awk '{print $2}')

    if [[ -n "$pid" ]]; then
      echo "Killing process(es): $pid"
      echo "$pid" | xargs kill -9
    else
      echo "No process selected"
    fi
  fi
}

# fenv - Fuzzy environment variable browser
fenv() {
  env | fzf --preview='echo "Variable: {1}" && echo "Value: {2}"' --delimiter='=' --header='Environment Variables'
}

# fssh - Fuzzy SSH host selection
fssh() {
  local host
  # Extract hosts from SSH config and known_hosts
  host=$(cat ~/.ssh/config ~/.ssh/known_hosts 2>/dev/null | grep -E '^Host |^[a-zA-Z0-9]' | awk '{print $1}' | grep -v '\*' | sort -u | fzf --header='Select SSH host')

  if [[ -n "$host" ]]; then
    ssh "$host"
  fi
}

# fport - Find process using a specific port
fport() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: fport <port_number>"
    return 1
  fi

  local port=$1
  local process

  if command -v lsof &> /dev/null; then
    process=$(lsof -ti:$port)
    if [[ -n "$process" ]]; then
      echo "Port $port is being used by process ID: $process"
      ps -p $process -o pid,ppid,cmd
    else
      echo "Port $port is not in use"
    fi
  else
    echo "lsof command not available"
    netstat -tulanp 2>/dev/null | grep ":$port "
  fi
}

# Fuzzy file browser with content preview
fls() {
  # Usage: fls
  # Opens fuzzy file finder with preview, then opens selected file in $EDITOR
  local selected
  local cmd="${_FD_CMD:-find}"
  local bat="${_BAT_CMD:-cat}"

  local preview_cmd
  if [[ "$bat" != "cat" ]]; then
    preview_cmd="$bat --style=numbers --color=always --line-range :500 {} 2>/dev/null || cat {}"
  else
    preview_cmd="cat {}"
  fi

  if [[ "$cmd" == "fd" || "$cmd" == "fdfind" ]]; then
    selected=$($cmd --type f --hidden --exclude .git | \
      fzf --preview "$preview_cmd")
  else
    selected=$(find . -type f | \
      fzf --preview "$preview_cmd")
  fi

  [[ -n "$selected" ]] && ${EDITOR:-vim} "$selected"
}

# Fuzzy grep with file preview and jump-to-line
fzgrep() {
  # Usage: fzgrep <pattern>
  # Searches for pattern with ripgrep, allows fuzzy selection, opens in editor at line
  local pattern="$1"
  [[ -z "$pattern" ]] && { echo "Usage: fzgrep <pattern>"; return 1; }

  if command -v rg &>/dev/null; then
    local result
    result=$(rg --line-number --no-heading --color=always "$pattern" | \
      fzf --ansi \
          --delimiter ':' \
          --preview 'bat --style=numbers --color=always --highlight-line {2} {1}' \
          --preview-window '+{2}/2')

    if [[ -n "$result" ]]; then
      local file="${result%%:*}"
      local line="${result#*:}"
      line="${line%%:*}"
      ${EDITOR:-vim} "+${line}" "$file"
    fi
  else
    echo "⚠️  ripgrep not installed. Using basic grep (install with: apt install ripgrep)"
    command grep -rn "$pattern" . | \
      fzf --delimiter ':' \
          --preview 'bat --style=numbers --color=always {1} 2>/dev/null || cat {1}'
  fi
}

# =============================================================================
# Tmux Functions
# =============================================================================
# Enhanced tmux session management with FZF integration.
#
# Functions:
#   - ftmux: Fuzzy tmux session picker (attach/switch/kill)
#   - tdev:  Create standard development layout
# =============================================================================

# ftmux - Fuzzy tmux session picker
ftmux() {
  if ! command -v fzf &>/dev/null; then
    echo "fzf required for ftmux"
    return 1
  fi

  local sessions
  sessions=$(tmux list-sessions -F "#{session_name}: #{session_windows} windows (created #{session_created_string})#{?session_attached, [attached],}" 2>/dev/null)

  if [[ -z "$sessions" ]]; then
    printf "No sessions. Create one? Name: "
    read -r name
    [[ -n "$name" ]] && tmux new-session -s "$name"
    return
  fi

  local selected
  selected=$(echo "$sessions" | fzf \
    --header="Enter=attach  Ctrl-K=kill  Ctrl-N=new" \
    --expect=ctrl-k,ctrl-n \
    --preview='tmux capture-pane -t $(echo {} | cut -d: -f1) -p 2>/dev/null | tail -30' \
    --preview-window=right:50%:wrap)

  [[ -z "$selected" ]] && return

  local key session
  key=$(echo "$selected" | head -1)
  session=$(echo "$selected" | tail -1 | cut -d: -f1)

  case "$key" in
    ctrl-k)
      tmux kill-session -t "$session" && echo "Killed: $session"
      ;;
    ctrl-n)
      printf "Session name: "
      read -r name
      [[ -n "$name" ]] && tmux new-session -s "$name"
      ;;
    *)
      if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$session"
      else
        tmux attach -t "$session"
      fi
      ;;
  esac
}

# tdev - Create standard development layout
tdev() {
  # Usage: tdev [session_name] [directory]
  # Layout: Main (top 60%) / Tests (bottom-left) / Git (bottom-right)
  local session="${1:-dev}"
  local dir="${2:-$(pwd)}"

  if tmux has-session -t "$session" 2>/dev/null; then
    if [[ -n "$TMUX" ]]; then
      tmux switch-client -t "$session"
    else
      tmux attach -t "$session"
    fi
    return
  fi

  tmux new-session -d -s "$session" -c "$dir"
  tmux split-window -v -p 40 -t "$session" -c "$dir"
  tmux split-window -h -t "$session" -c "$dir"
  tmux select-pane -t "$session:.1"

  if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach -t "$session"
  fi
}

# =============================================================================
# SSH + Tmux Integration Functions
# =============================================================================
# Smart SSH + tmux integration for seamless remote server administration.
# All functions include inline "Usage: ..." documentation.
#
# Functions:
#   - ssht: SSH to host and attach/create named tmux session
#   - sshls: List tmux sessions on remote server
#   - sshkill: Kill specific tmux session on remote server
#   - qmux: Quantivly server admin — per-server tmux sessions (Alt+w to switch)
#
# See also: docs/SSH_CONFIG_GUIDE.md, examples/tmux-workflows.md
# =============================================================================

# ssht - Smart SSH + tmux: Connect to server and attach/create named tmux session
ssht() {
  # Usage: ssht <host> [session_name]
  # Connects to SSH host and automatically attaches to or creates a named tmux session
  if [ $# -lt 1 ]; then
    echo "Usage: ssht <host> [session_name]"
    echo "  host         - SSH host from ~/.ssh/config"
    echo "  session_name - Tmux session name (default: 'admin')"
    echo ""
    echo "Examples:"
    echo "  ssht dev               # Connect to dev, attach/create 'admin' session"
    echo "  ssht staging deploy    # Connect to staging, 'deploy' session"
    echo "  ssht qspace monitor    # Connect to qspace, 'monitor' session"
    return 1
  fi

  local host="$1"
  local session="${2:-admin}"  # Default to 'admin' if not specified

  # Connect and attach/create session
  ssh -t "$host" "tmux new-session -A -s '$session'"
}

# sshls - SSH to server and list available tmux sessions
sshls() {
  # Usage: sshls <host>
  # Lists all tmux sessions running on remote server
  if [ $# -ne 1 ]; then
    echo "Usage: sshls <host>"
    echo "  Lists all tmux sessions on remote server"
    return 1
  fi

  ssh -t "$1" "tmux list-sessions"
}

# sshkill - SSH to server and kill specific tmux session
sshkill() {
  # Usage: sshkill <host> <session_name>
  # Kills specified tmux session on remote server
  if [ $# -ne 2 ]; then
    echo "Usage: sshkill <host> <session_name>"
    echo "  Kills specified tmux session on remote server"
    return 1
  fi

  ssh -t "$1" "tmux kill-session -t '$2'"
}

# qmux - Quantivly server admin via per-server tmux sessions
# Creates "Quantivly [<server>]" sessions with SSH to each server.
# Uses session switching (Alt+w) instead of tmux nesting.
qmux() {
  # Usage: qmux [server...]
  # Default servers: dev staging demo
  local -a servers
  if (( $# > 0 )); then
    servers=("$@")
  else
    servers=(dev staging demo)
  fi

  # Create sessions for each server (skip existing)
  local server session
  for server in "${servers[@]}"; do
    session="Quantivly [${server}]"
    if tmux has-session -t "=$session" 2>/dev/null; then
      continue
    fi
    # Uses send-keys so the pane survives SSH failures
    tmux new-session -d -s "$session" -n "$server"
    tmux setw -t "$session" automatic-rename off
    tmux send-keys -t "$session" "ssh ${server}" Enter
  done

  # Switch/attach to the first server's session
  local target="Quantivly [${servers[1]}]"
  if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "=$target"
  else
    tmux attach -t "=$target"
  fi
}
