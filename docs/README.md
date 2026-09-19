# `docs/` — what each page is, and who it is for

Every page under `docs/` is listed here. This index exists because an unrouted file is an unread
file: `scripts/check-claude-md.sh` refuses any page that is not reachable from
[CLAUDE.md](../CLAUDE.md) or [README.md](../README.md), and `docs/CLAUDE_SETUP.md` sat unlinked —
and therefore unread — until that guard named it.

Two audiences run through the whole tree, and mixing them is what made `CLAUDE.md` unreadable:

- **Guides** are for someone *adopting or operating* a thing — set it up, run it, recover from it.
- **Maintainer's records** are the evidence behind the rules in [CLAUDE.md](../CLAUDE.md): the
  measurements, the incidents and the traps. The operative rule stays in CLAUDE.md; the story of
  how it was learned lives here. **Add new evidence to these pages, not to CLAUDE.md.**

## Setting the machine up

| page | what it is | for |
|---|---|---|
| [SERVER_BOOTSTRAP_GUIDE.md](SERVER_BOOTSTRAP_GUIDE.md) | bootstrapping a remote server, SSH config patterns, AL2 gotchas, bootstrap ordering | guide |
| [SSH_CONFIG_GUIDE.md](SSH_CONFIG_GUIDE.md) | SSH config: multiplexing, Bitwarden agent, forwarding patterns | guide |
| [SSH_SIGNING_SETUP.md](SSH_SIGNING_SETUP.md) | turning on SSH commit signing (GPG alternative included) | guide |
| [MIGRATION.md](MIGRATION.md) | migrating off nvm/pyenv/rbenv/asdf onto mise | guide |
| [TOOL_VERSION_UPDATES.md](TOOL_VERSION_UPDATES.md) | how tool versions are pinned and updated — **plus** the maintainer's record of the mise symlink and the silent drift it prevents | guide + record |
| [GNOME_CONFIGURATION_GUIDE.md](GNOME_CONFIGURATION_GUIDE.md) | the curated GNOME desktop: what is set, how to customise it, Wayland notes — **plus** the maintainer's record of the apply mechanism and its one silent override trap | guide + record |
| [SHELL_LAYOUT.md](SHELL_LAYOUT.md) | the zsh layer: the two tool-availability patterns with examples, and the full annotated load order | record |

## Terminal and multiplexer

| page | what it is | for |
|---|---|---|
| [TMUX_LEARNING_GUIDE.md](TMUX_LEARNING_GUIDE.md) | learning this tmux setup: prefix-free bindings, popups, nested sessions | guide |
| [CLAUDE_CODE_TMUX.md](CLAUDE_CODE_TMUX.md) | why Claude Code runs in fullscreen (alt-screen) here, and how scrollback and search change | guide |
| [TERMINAL_AND_KEYS.md](TERMINAL_AND_KEYS.md) | why the Alacritty config is not symlinked, which Ctrl+Shift chords Alacritty silently swallows and how that was probed, why `$TERM` follows the *terminfo*, and the measured cost of the snap build rendering on the CPU | record |

## Claude Code: accounts, credentials, MCP

| page | what it is | for |
|---|---|---|
| [CLAUDE_ACCOUNT_MCP.md](CLAUDE_ACCOUNT_MCP.md) | what to run and what to click to fix a logout or a dropped MCP server | guide |
| [CLAUDE_SETUP.md](CLAUDE_SETUP.md) | which plugins are enabled at user scope vs per project (neither file is in this repo, so this page is the record) | record |
| [CLAUDE_ACCOUNTS.md](CLAUDE_ACCOUNTS.md) | the account-dir mechanism and every credential incident behind it: the race, clauth's writes, suspend storms, `auth_broken` | record |
| [CLAUDE_ACCOUNT_PICKER.md](CLAUDE_ACCOUNT_PICKER.md) | how a directory's account is chosen, and how the ranking has been wrong | record |

To *diagnose* one of these, use the [`claude-accounts`](../.claude/skills/claude-accounts/SKILL.md)
skill rather than reading the records end to end.

## Agent workspaces (herdr)

| page | what it is | for |
|---|---|---|
| [HERDR_GUIDE.md](HERDR_GUIDE.md) | adopting herdr: workspaces, tabs, panes, agent detection | guide |
| [HERDR_INTERNALS.md](HERDR_INTERNALS.md) | this repo's herdr integration: both install paths, the systemd unit and drop-in, the sidebar publisher, every trap and its state table | record |

## Security

| page | what it is | for |
|---|---|---|
| [SECURITY_INCIDENTS.md](SECURITY_INCIDENTS.md) | step-by-step response when a secret **has already been committed** | guide |
| [SECRET_EMISSION.md](SECRET_EMISSION.md) | **preventing** an emission: the 2026-09-01 transcript audit, the redactor, the `PreToolUse` guard, and every hole since found in them | record |
| [AUDIT_TRIPWIRE.md](AUDIT_TRIPWIRE.md) | the `kill(-1, sig)` auditd rule: why the `a0` constant must stay 32 bits, and each way "armed" can be silently false | record |
| [GH_ACCOUNT_ROUTING.md](GH_ACCOUNT_ROUTING.md) | how `gh` picks a GitHub account and how it gets it wrong: the measured keyring collapse, the routing table, and every trap in `gh-doctor` and the `chpwd` hook | record |

## Backups

| page | what it is | for |
|---|---|---|
| [BACKUP_AND_RESTORE_GUIDE.md](BACKUP_AND_RESTORE_GUIDE.md) | setup, daily operation, the disaster-recovery runbook, drills | guide |
| [BACKUP_INTERNALS.md](BACKUP_INTERNALS.md) | why each guard exists: what is copied rather than symlinked, placeholder rendering, and the traps in the mount-point guard, the udev rule and the systemd wiring | record |

## This repository

| page | what it is | for |
|---|---|---|
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | quick fixes: slow startup, missing functions, alias conflicts, git identity and account routing | guide |
| [DOTFILES_DEPLOY.md](DOTFILES_DEPLOY.md) | why `git checkout` here *is* a deploy, how that failed in both directions, and the live-config, worktree and umask guards | record |
| [REPO_CHECKS.md](REPO_CHECKS.md) | the CI guards and what reviewing them taught: the apt outage, seventeen defects in one checker under a green suite, the version-sync line window, the mutation rounds | record |

## Skills

- **Project scope**, in this repo and reviewed with it:
  [`.claude/skills/claude-accounts/SKILL.md`](../.claude/skills/claude-accounts/SKILL.md) —
  diagnosing a logout, a dropped MCP server, or a session billing the wrong account.
- **User scope**, *not* in this repo: `~/.claude/skills/herdr/` is **generated** by
  [`scripts/herdr-claude-wire.sh`](../scripts/herdr-claude-wire.sh). Edit the generator, never the
  generated file.

## Not indexed

`docs/plans/` and `docs/superpowers/` hold working material rather than reference pages, and the
reachability guard skips them deliberately.
