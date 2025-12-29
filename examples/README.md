# Dotfiles Workflow Examples

This directory contains practical workflow examples and recipes for using the tools and aliases configured in this dotfiles repository.

## Available Guides

### [Git Workflows](git-workflows.md) 📚

Comprehensive Git workflow demonstrations using the configured aliases and GitHub CLI.

**Topics Covered:**
- Feature branch development (gcb → gaa → gcam → gp → gh pr create)
- Merge conflict resolution (git conflicts, editing, resolving)
- Pull request review workflow (gh review → gh co → gh approve → gh prmerge)
- Quick WIP commits (gwip/gunwip)
- Branch cleanup and maintenance
- Advanced operations (interactive rebase, cherry-pick, stash)
- GitHub CLI power tips (35+ custom aliases)

**Key Commands:**
- `gcb <branch>` - Create and checkout new branch
- `gwip` / `gunwip` - Temporary commit workflow
- `gh review` - PRs awaiting your review
- `gh prmerge` - Squash merge and delete branch
- `fbr` - Fuzzy branch checkout
- `fco` - Fuzzy commit checkout
- `fshow` - Interactive git log browser

**Best For:** Developers working with Git and GitHub daily

---

### [Docker Workflows](docker-workflows.md) 🐳

Practical Docker and Docker Compose workflows for local development and debugging.

**Topics Covered:**
- Starting and monitoring services (dcup, dps, dclogs)
- Container debugging (dex, dlog, docker inspect)
- Image management (building, pushing, cleanup)
- Cleanup workflows (dstop, drm, dclean, dprune)
- Networking and volumes
- Troubleshooting common issues
- Docker Compose advanced usage

**Key Commands:**
- `dcup` / `dcdown` - Start/stop compose services
- `dex <container> bash` - Access container shell
- `dlog <container>` - View container logs
- `dclean` - Clean up unused resources
- `dprune` - Aggressive cleanup (removes volumes!)

**Best For:** Developers working with containerized applications

---

### [FZF Integration Recipes](fzf-recipes.md) 🔍

Interactive fuzzy finding workflows and power user tips.

**Topics Covered:**
- Built-in keybindings (Ctrl+T, Ctrl+R, Alt+C)
- Custom functions (fcd, fbr, fco, fshow)
- Process management (kill interactively)
- File operations (open, copy, bulk operations)
- Git advanced (interactive staging, cherry-pick)
- Docker integration (select containers)
- Search and replace workflows
- Power user tips and tricks

**Key Keybindings:**
- `Ctrl+T` - Fuzzy file search with preview
- `Ctrl+R` - Fuzzy command history search
- `Alt+C` - Fuzzy directory navigation
- `**<TAB>` - FZF-enhanced completion

**Key Functions:**
- `fcd [dir]` - Fuzzy cd with preview
- `fbr` - Fuzzy git branch checkout
- `fco` - Fuzzy git commit checkout
- `fshow` - Git commit browser with preview

**Best For:** Users who want to work more efficiently with the terminal

---

## Tool Verification

### [verify-tools.sh](../scripts/verify-tools.sh) ✔️

**Purpose:** Check which tools are installed for this dotfiles configuration.

**Usage:**
```bash
./scripts/verify-tools.sh
```

**What It Checks:**
- Required tools (zsh, git)
- Recommended tools (fzf, gh)
- Modern CLI replacements (bat, eza, fd, rg, htop, delta)
- Version manager (mise)
- Optional tools (direnv, autojump, poetry, docker)
- Oh-My-Zsh plugins and theme

**Output:** Colored status report showing what's installed, what's missing, and how to install missing tools.

**Best For:** New installations, troubleshooting, verifying setup

---

## Quick Reference Tables

### Git Aliases

| Alias | Command | Description |
|-------|---------|-------------|
| `gst` | `git status` | View current status |
| `gco` | `git checkout` | Switch branches |
| `gcb` | `git checkout -b` | Create new branch |
| `gaa` | `git add --all` | Stage all changes |
| `gcam` | `git commit -am` | Add and commit |
| `gp` | `git push` | Push to remote |
| `gl` | `git pull` | Pull from remote |
| `gd` | `git diff` | Show changes |
| `glog` | Git log with graph | Pretty commit history |
| `gwip` | Quick WIP commit | Save work temporarily |
| `gunwip` | Undo WIP commit | Restore to uncommitted |

See [git-workflows.md](git-workflows.md) for complete list and detailed workflows.

### Docker Aliases

| Alias | Command | Description |
|-------|---------|-------------|
| `dcup` | `docker compose up -d` | Start services |
| `dcdown` | `docker compose down` | Stop services |
| `dps` | `docker ps` | List running containers |
| `dex` | `docker exec -it` | Execute in container |
| `dlog` | `docker logs` | View container logs |
| `dclogs` | `docker compose logs -f` | Follow compose logs |
| `dstop` | `docker stop $(docker ps -q)` | Stop all running |
| `dclean` | `docker system prune -f` | Basic cleanup |
| `dprune` | `docker system prune -af --volumes` | Full cleanup |

See [docker-workflows.md](docker-workflows.md) for complete list and detailed workflows.

### FZF Functions

| Function | Description | Usage |
|----------|-------------|-------|
| `fcd` | Fuzzy cd with preview | `fcd` or `fcd /path` |
| `fbr` | Fuzzy git branch checkout | `fbr` |
| `fco` | Fuzzy git commit checkout | `fco` |
| `fshow` | Git commit browser | `fshow` |

| Keybinding | Description | Usage |
|------------|-------------|-------|
| `Ctrl+T` | Fuzzy file search | Press in terminal |
| `Ctrl+R` | Fuzzy history search | Press in terminal |
| `Alt+C` | Fuzzy directory nav | Press in terminal |

See [fzf-recipes.md](fzf-recipes.md) for complete list and advanced recipes.

---

## Common Workflow Patterns

### Daily Development Flow

```bash
# Morning: Start work
gco main && gl          # Update main branch
gcb feature/my-task    # Create feature branch

# Development
# ... make changes ...
gaa && gcam "feat: Description"  # Stage and commit
gp                      # Push to remote

# Create PR
gh pr create --web      # Open browser to create PR

# Throughout day
gwip                    # Quick save before switching tasks
gco other-branch        # Switch to urgent task
# ... work on urgent task ...
gco feature/my-task     # Return to feature
gunwip                  # Restore work
```

### Code Review Flow

```bash
# Check PRs needing review
gh review

# Review a PR locally
gh co 123               # Checkout PR
gd                      # See changes
git lg                  # View commits

# Test locally
dcup && dps && dclogs   # If Docker-based

# Approve and merge
gh approve -b "LGTM!"
gh prmerge              # Squash merge and cleanup
gco main && gl          # Return to updated main
```

### Debugging Flow

```bash
# Docker debugging
dps                     # Check running containers
dlog myapp --tail 100   # View recent logs
dex myapp bash          # Access container shell

# Inside container:
ps aux | grep python    # Check processes
curl localhost:8000/health  # Test endpoints

# Host debugging with FZF
kill -9 $(ps aux | fzf | awk '{print $2}')  # Kill problematic process
vim $(rg "ERROR" | fzf)  # Open file with errors
```

---

## Learning Path

### Beginner (Day 1-7)

Start with these essentials:

1. **Basic Git Workflow** - `gcb`, `gaa`, `gcam`, `gp`
2. **FZF Keybindings** - `Ctrl+T`, `Ctrl+R`, `Alt+C`
3. **Docker Basics** - `dcup`, `dps`, `dlog`, `dcdown`
4. **Tool Verification** - `./scripts/verify-tools.sh`

Read: First half of [git-workflows.md](git-workflows.md)

### Intermediate (Week 2-4)

Add these to your toolkit:

1. **Git PR Workflow** - `gh review`, `gh co`, `gh approve`, `gh prmerge`
2. **FZF Functions** - `fbr`, `fcd`, `fshow`
3. **Docker Debugging** - `dex`, `docker inspect`, cleanup workflows
4. **WIP Commits** - `gwip` / `gunwip`

Read: Complete [git-workflows.md](git-workflows.md) and [docker-workflows.md](docker-workflows.md)

### Advanced (Month 2+)

Master these power features:

1. **FZF Power User** - Process management, custom pipes, multi-select
2. **Interactive Git** - Cherry-pick, interactive rebase, advanced logs
3. **Docker Advanced** - Networking, volumes, multi-stage builds
4. **Custom Workflows** - Create your own functions in `~/.zshrc.local`

Read: [fzf-recipes.md](fzf-recipes.md) advanced sections

---

## Related Documentation

- [CLAUDE.md](../CLAUDE.md) - Complete repository documentation
- [README.md](../README.md) - Installation and setup guide
- [zshrc.aliases](../zsh/zshrc.aliases) - All alias definitions
- [zshrc.conditionals](../zsh/zshrc.conditionals) - Tool configurations
- [zshrc.functions](../zsh/zshrc.functions) - Utility functions
- [gh/config.yml](../gh/config.yml) - GitHub CLI aliases (35+)

---

## Contributing

Found a workflow that's missing or could be improved? This is a personal dotfiles repository, but suggestions are welcome:

1. Document the workflow in your own setup
2. Test it thoroughly
3. Consider if it's generally useful
4. Submit as an issue or PR with examples

---

## Tips for Using These Examples

1. **Don't memorize everything** - Bookmark this README and refer back
2. **Practice workflows** - Try each workflow a few times to build muscle memory
3. **Customize** - Add your own functions to `~/.zshrc.local`
4. **Mix and match** - Combine workflows to fit your needs
5. **Share** - Teach teammates useful workflows you discover

---

**Last Updated:** December 2025
**Repository:** [Zvi's Dotfiles](https://github.com/zvi-quantivly/dotfiles)
