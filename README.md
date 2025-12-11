# Dotfiles

Personal configuration files managed with [dotbot](https://github.com/anishathalye/dotbot).

## Contents

- `gh/config.yml` - GitHub CLI configuration and aliases
- `gitconfig` - Git configuration with aliases and settings
- `zshrc` - Zsh configuration with oh-my-zsh
- `p10k.zsh` - Powerlevel10k theme configuration
- `config/git/ignore` - Global git ignore patterns

## Setup on a New Machine

```bash
# Clone this repo with submodules
git clone --recursive <your-repo-url> ~/.dotfiles

# Run the install script
cd ~/.dotfiles
./install
```

If you forgot to use `--recursive` when cloning:
```bash
cd ~/.dotfiles
git submodule update --init --recursive
./install
```

## Adding More Config Files

1. Copy the file to this repo:
   ```bash
   cp ~/.zshrc ~/.dotfiles/zshrc
   ```

2. Add an entry to `install.conf.yaml`:
   ```yaml
   - link:
       ~/.config/gh/config.yml: gh/config.yml
       ~/.zshrc: zshrc  # Add this line
   ```

3. Test the configuration:
   ```bash
   ./install
   ```

4. Commit and push:
   ```bash
   git add .
   git commit -m "Add zshrc"
   git push
   ```

## Managing Changes

After updating any config file on your system, sync it back to the repo:

```bash
# The file is already symlinked, so changes are reflected in ~/.dotfiles
cd ~/.dotfiles
git diff  # Review changes
git add .
git commit -m "Update gh aliases"
git push
```

On other machines, just pull the latest:
```bash
cd ~/.dotfiles
git pull
./install  # Re-run to ensure everything is linked correctly
```

## How It Works

Dotbot reads `install.conf.yaml` and creates symlinks automatically. The configuration defines:
- What files to link and where
- Directories to create
- Commands to run during setup

This is much cleaner than maintaining shell scripts!
