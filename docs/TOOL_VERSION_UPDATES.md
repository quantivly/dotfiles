# Tool Version Update Procedures

## Overview

CLI tools are managed via mise (https://mise.jdx.dev/) with versions pinned for reproducibility. This document describes procedures for updating tool versions across the dotfiles and dev-setup repositories.

## Source of Truth Architecture

**Single Source of Truth**: `~/.dotfiles/.mise.toml`
- Authoritative source for all CLI tool versions
- Defines 14 core CLI tools with pinned versions
- Copied to `~/.config/mise/config.toml` by `dotfiles/install`
- All team members use these versions for consistency
- Can enable optional tools (dive, lazydocker, ctop)

**Active Configuration**: `~/.config/mise/config.toml`
- Created by dotfiles installation (`./install`)
- Used by mise for actual tool management
- Can be edited for machine-specific needs

**Dev-Setup Role**:
- Installs the mise **binary** only (`install_mise()` function)
- Does NOT configure or install CLI tools
- Calls `dotfiles/install` which handles all tool configuration
- Clean separation: dev-setup = system setup, dotfiles = personal config

## Tool Version Philosophy

**Pinned Versions (Recommended)**:
- Reproducible environments across team
- Predictable behavior during development
- Coordinated updates with changelog
- Example: `bat = "0.24.0"`

**Latest Versions (Alternative)**:
- Always newest features
- May introduce breaking changes
- Personal responsibility to track upstream
- Example: `bat = "latest"`

The team uses **pinned versions** by default for consistency.

## Managed Tools

### Core Tools (14 essential)
| Tool | Purpose | Current Version |
|------|---------|----------------|
| bat | Better cat with syntax highlighting | 0.24.0 |
| fd | Better find with .gitignore support | 10.2.0 |
| eza | Better ls with icons and colors | 0.23.4 |
| delta | Git diff with syntax highlighting | 0.18.2 |
| zoxide | Smart cd that learns patterns | 0.9.6 |
| duf | Beautiful disk usage | 0.8.1 |
| dust | Intuitive directory sizes | 1.1.1 |
| lazygit | Interactive git TUI | 0.45.1 |
| just | Modern command runner | 1.38.0 |
| glow | Terminal markdown renderer | 2.0.0 |
| gitleaks | Secret detection | 8.21.2 |
| pre-commit | Git hook framework | 4.0.1 |
| sops | Encrypted secrets management | 3.9.2 |
| fastfetch | System info display | 2.32.0 |

### Optional Tools (uncomment in config)
- dive, lazydocker, ctop - Docker tools
- hyperfine - Benchmarking
- difftastic - Structural diffs
- cheat - Interactive cheatsheets
- tlrc - Rust-based tldr client

### Not Managed by Mise
- btop - Install via `apt install btop` (aqua registry issue)
- forgit - Manual git clone to `~/.forgit`
- procs - Install via `cargo install procs`

## Update Procedures

### Check for Available Updates

```bash
# Check all tools for newer versions
mise outdated

# Check specific tool
mise ls-remote bat          # List all versions
mise ls-remote bat --limit 5  # Latest 5 versions

# Check currently installed versions
mise ls
mise current
```

### Test New Version Locally

```bash
# Install new version without changing config
mise use bat@0.25.0

# Test functionality
bat --version
bat ~/.zshrc

# Test with real workflows
# ... verify no breaking changes ...

# If good, proceed with config update
# If bad, revert: mise use bat@0.24.0
```

### Update Team Configuration (Coordinated)

**Important**: Tool updates should be coordinated with the team to ensure everyone stays in sync.

#### Step 1: Update Single Source of Truth

```bash
cd ~/.dotfiles

# Edit .mise.toml (single source of truth)
vim .mise.toml

# Change:
# bat = "0.24.0"
# To:
# bat = "0.25.0"

# Install updated configuration
./install  # Copies to ~/.config/mise/config.toml

# Install new version
mise install bat@0.25.0

# Test thoroughly
bat --version
# ... test workflows ...
```

#### Step 2: Update Documentation

```bash
# Update this file with new version
vim docs/TOOL_VERSION_UPDATES.md

# Update CHANGELOG.md
echo "## [Date]
- Updated bat from 0.24.0 to 0.25.0
- Reason: [new features / bug fixes / security]
" | cat - CHANGELOG.md > temp && mv temp CHANGELOG.md
```

#### Step 3: Commit and PR

```bash
cd ~/.dotfiles
git checkout -b zvi/update-bat-0.25.0
git add .mise.toml CHANGELOG.md docs/TOOL_VERSION_UPDATES.md
git commit -m "Updated bat to 0.25.0

- Reason for update: [features/fixes/security]
- Tested on: [your system]
- Breaking changes: [none/describe]
"
git push -u origin zvi/update-bat-0.25.0
gh pr create --title "Updated bat to 0.25.0" --body "..."
```

### Update Personal Configuration (Independent)

If you want to test a tool version independently without affecting team config:

```bash
# Option 1: Temporary use (doesn't persist)
mise use bat@0.25.0

# Option 2: Edit personal active config
vim ~/.config/mise/config.toml
# Change bat version
mise install

# Note: This creates drift from team config (.dotfiles/.mise.toml)
# Remember to sync back when ready to share with team
```

## Validation Procedures

### Validate Configuration Syntax

```bash
# Check TOML syntax
cd ~/.dotfiles
python3 -c "import tomllib; tomllib.load(open('.mise.toml', 'rb'))"

# Validate with mise
mise doctor
mise config validate
```

### CI Validation

The dotfiles repository includes CI jobs that:
- Validate mise configuration syntax (TOML parsing)
- Test installation on Ubuntu 22.04 & 24.04
- Verify tool functionality post-install
- Run pre-commit hooks (shellcheck, yaml validation)

### Installation Testing

```bash
# Test full installation flow
# 1. In clean VM or container
docker run -it ubuntu:22.04 bash

# 2. Clone and run dev-setup (installs mise binary, calls dotfiles)
git clone https://github.com/quantivly/dev-setup
cd dev-setup
./setup.sh
# Note: This automatically clones dotfiles and runs ./install

# 3. Verify tools installed and active
mise ls
mise current
bat --version
fd --version
eza --version
# ... test all tools ...

# 4. Verify configuration source
cat ~/.config/mise/config.toml  # Should match ~/.dotfiles/.mise.toml
```

## Version Compatibility Matrix

### Known Compatibility Issues

| Tool | Version | Issue | Workaround |
|------|---------|-------|-----------|
| bat | < 0.23.0 | Lacks --map-syntax | Upgrade to 0.23.0+ |
| fd | < 8.0.0 | No --base-directory | Upgrade to 8.0.0+ |
| delta | < 0.16.0 | Side-by-side requires newer | Upgrade to 0.16.0+ |

### Operating System Compatibility

| OS | Minimum Versions | Notes |
|----|------------------|-------|
| Ubuntu 22.04 | All current versions | Fully supported |
| Ubuntu 24.04 | All current versions | Fully supported |
| Debian 11+ | Most tools work | Some may need manual install |
| macOS | All current versions | Install via Homebrew or mise |

### Tool Interdependencies

- **gitleaks** requires pre-commit for hook integration
- **delta** requires git 2.25+ for diff integration
- **zoxide** requires fzf for interactive mode
- **lazygit** requires git 2.25+

## Troubleshooting Updates

### Tool Won't Install

```bash
# Check mise backend
mise doctor

# Try manual backend installation
mise use --backend aqua bat@0.25.0

# Check tool availability
mise ls-remote bat

# Verify no conflicting versions
which bat
mise where bat
```

### Tool Installed But Not in PATH

```bash
# Check mise activation
mise doctor

# Re-activate mise
eval "$(mise activate bash)"
# or for zsh:
eval "$(mise activate zsh)"

# Reload shell
source ~/.zshrc
```

### Version Mismatch After Update

```bash
# Clear mise cache
rm -rf ~/.local/share/mise/installs/bat

# Reinstall
mise install bat@0.25.0

# Verify
mise current bat
bat --version
```

### CI Validation Failing

```bash
# Run same checks locally
cd ~/.dotfiles
pre-commit run --all-files

# Check syntax
mise config validate

# Test installation
./install
```

## Quarterly Update Schedule

**Recommended cadence**: Review tool versions quarterly

### Q1 (January)
- Review all tool versions
- Check for security updates
- Plan coordinated upgrade sprint

### Q2 (April)
- Minor version bumps
- Test new features
- Update documentation

### Q3 (July)
- Security patches
- Compatibility testing with new OS versions

### Q4 (October)
- Major version updates (if needed)
- End-of-year cleanup
- Plan next year's strategy

## Security Considerations

### Security Updates (Immediate)

If a tool has a critical security vulnerability:

1. **Verify CVE**: Check official security advisories
2. **Test hotfix**: Install patched version immediately
3. **Emergency update**: Skip normal coordination process
4. **Notify team**: Alert in Slack/Linear about required update
5. **Update docs**: Document security patch in CHANGELOG

### Integrity Verification

```bash
# Mise uses aqua backend which verifies checksums
# Check tool integrity
mise doctor

# Verify installation
mise ls --json | jq '.[] | {tool, version, path}'
```

## References

- [mise Documentation](https://mise.jdx.dev/)
- [mise Configuration](https://mise.jdx.dev/configuration)
- [aqua Backend](https://mise.jdx.dev/dev-tools/backends/aqua)
- [Tool Registry](https://github.com/aquaproj/aqua-registry)
- [Dotfiles Repository](https://github.com/quantivly/dotfiles)

## Questions?

- **Tool update coordination**: Ask in #dev-tools Slack channel
- **Tool not working**: Check TROUBLESHOOTING.md in dotfiles
- **New tool request**: Create Linear issue with DO- prefix
- **Version pinning philosophy**: See [docs/MIGRATION.md](MIGRATION.md)
