---
name: claude-accounts
description: >
  Diagnose Claude Code account and credential trouble on this machine: (1) a session or
  several sessions reporting "Login expired · Please run /login"; (2) MCP servers or
  claude.ai connectors disconnecting or returning unauthorized; (3) a session billing the
  wrong account, or the sidebar naming an account that does not match; (4) clauth reporting
  auth_broken or quarantining a profile; (5) deciding whether it is safe to run
  `clauth <profile>`. Use when working in the dotfiles repo on any of these, or when editing
  zsh/functions/claude.sh, zsh/zshrc.herdr's claude() / picker code, or
  scripts/claude-account-dirs.sh. Do NOT use for GitHub account routing (that is
  gh-doctor), for herdr pane or workspace control (see the herdr skill), or for general
  questions about Claude Code features.
---

# Claude accounts: diagnose before you touch anything

One credential file per account, many sessions reading it, and three writers (Claude Code,
clauth, and this repo's reconciler). Most "fixes" that go wrong here go wrong by **writing a
credential** — relinking, switching a profile, restoring a copy — and the damage lands on every
session sharing that account, not just the one being fixed. So the procedure is read-only
until the last step.

## 1. Read the state — nothing here writes

```bash
claude-doctor                 # auth + MCP health, account dirs, clauth state; read-only
echo "$CLAUDE_CONFIG_DIR"     # the account THIS session bills (empty = the shared global file)
claude-pick --explain         # which account this directory would get, and why
journalctl --user -u clauth-daemon.service --since '2 hours ago' | grep -i auth_broken
```

`clauth which` is **not** "the active profile": it reports which profile *owns* the loaded
credential, answered from `$CLAUDE_CONFIG_DIR`. The daemon logs to the **journal**, not to
`~/.clauth/clauth.log` — silence in the log file is not evidence.

## 2. Classify

| what you see | most likely | read |
|---|---|---|
| Several sessions logged out in the **same minute** | a write to a shared credential (a `clauth <profile>` switch, or a session on the global file) | CLAUDE_ACCOUNTS.md → "A logout is not one session's problem" |
| Every account broken right after the laptop woke | tokens (8 h) expired during the suspend; clauth flagged `auth_broken` | CLAUDE_ACCOUNTS.md → "A long suspend expires every account at once" |
| `auth_broken` standing although sessions work | the reconciler adopted a live token; a successful fetch never clears the flag on 0.15.1 | CLAUDE_ACCOUNTS.md → "A standing `auth_broken` is reported" |
| One MCP server's entry has an empty token | no `expiresAt`/`scope`: never authorised in this config dir. With them: a lost interleaved write | CLAUDE_ACCOUNTS.md → the 2026-09-06 correction |
| Session on an account nobody chose | an empty tenant table widened the pool, or `CLAUDE_CONFIG_DIR` unset | CLAUDE_ACCOUNT_PICKER.md → "Tenants and pools" |
| `account 'home'` or no holder registered | a Bash-tool shell: `_helpers` are absent from the snapshot | CLAUDE_ACCOUNTS.md → "Holder attribution" |

## 3. Only then act, and prefer the narrowest action

- **Wrong account for your own work** → `claude-as <profile>`. It moves only your session.
- **An account needs re-auth** → `clauth login <profile>`. This is the only thing that clears
  `auth_broken`.
- **`clauth <profile>`** → only after `claude-doctor` says the stored copy **matches** the live
  credential. If it says DIFFERS, the store holds a superseded refresh token and switching logs
  out every session on that account.
- **Never** relink an account dir's `.credentials.json`, copy a credential between profiles, or
  edit `profiles.toml` by hand. Claude Code writes atomically and replaces the symlink; only
  `scripts/claude-account-dirs.sh --reconcile` decides which side is live, and it refuses when it
  cannot tell.
- **Never print a credential** while diagnosing. Pipe anything that might through
  `scripts/redact-secrets.sh`; the secret-emission hook refuses the usual shapes.

## References

| file | read it when |
|---|---|
| [docs/CLAUDE_ACCOUNTS.md](../../../docs/CLAUDE_ACCOUNTS.md) | you need the mechanism or the incident record behind any rule above |
| [docs/CLAUDE_ACCOUNT_PICKER.md](../../../docs/CLAUDE_ACCOUNT_PICKER.md) | the question is *which* account, not whether it works |
| [docs/CLAUDE_ACCOUNT_MCP.md](../../../docs/CLAUDE_ACCOUNT_MCP.md) | you are at the click-through step: connector cleanup, reviving a dead stdio server |
| [docs/CLAUDE_SETUP.md](../../../docs/CLAUDE_SETUP.md) | a plugin or MCP server is enabled in the wrong scope |
