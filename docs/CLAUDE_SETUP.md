# Claude Code setup: which plugins run where

Plugin state lives in `~/.claude/settings.json` (`enabledPlugins`, user scope) and in each
project's `.claude/settings.json`; neither is in this repo, so this page is the record.

## Global (user scope): every plugin except two stdio MCP servers

Everything else stays enabled at user scope: remote (HTTP) MCP servers and skill-only plugins cost no process per session.

## Off globally, on per project: `chrome-devtools-mcp`, `desktop-commander`

Both are stdio MCP servers, so every Claude Code session forks its own copy whether or not it
ever drives a browser or a REPL. Measured on this laptop on 2026-09-16 (`research/resources-audit.md`
and `research/herdr-audit.md` in the rabota-v2 handoff): 152 MCP server processes for 22 agents
(6.9 per agent), 0 of 22 `chrome-devtools-mcp` instances had a browser attached, and the MCP servers
held 4.4 GB of swap. Dropping the two saves about 7 processes and ~230 MB per session.

Disabled at user scope on 2026-09-16. Pass `--scope user` explicitly: without it, `claude plugin
disable` wrote the *project* scope of the directory it ran in first.

    ( unset CLAUDE_CONFIG_DIR &&
      command claude plugin disable chrome-devtools-mcp@claude-plugins-official --scope user &&
      command claude plugin disable desktop-commander@claude-plugins-official --scope user )

Run bare from an interactive shell, `claude plugin …` goes through the `claude()` wrapper into an
account dir. Run from a session, it uses that session's dir. Either way, `--scope user` writes that
dir's `settings.json` copy, and the next launch overwrites it from the global file.

Re-enable only in a project that really uses a browser or a REPL:

    cd <project> && ( unset CLAUDE_CONFIG_DIR && command claude plugin enable chrome-devtools-mcp@claude-plugins-official --scope project )

Running sessions keep their servers until they exit, so `pgrep -fc chrome-devtools-mcp` falls as
sessions close, not when the setting changes. `claude mcp list` in a fresh shell shows what a new
session started there would load; the two names must be absent.

## Linear: one API key, no sign-in (DO-801)

Linear's MCP server comes from `claude/plugins/linear-key` in this repo, not from the official
`linear` plugin. It sends `Authorization: Bearer ${LINEAR_API_KEY}`, and that variable is already
in every session's environment for rabota's GraphQL path. A new seat therefore needs no Linear
sign-in, and there is no Linear entry in any seat's `mcpOAuth` for a lost write to blank
(runbook §2.4). The official plugin ships only the MCP server, so disabling it loses nothing else.

**One-time setup**, by a person, from a plain shell after the PR is deployed to `~/.dotfiles`.
The subshell keeps a session's `CLAUDE_CONFIG_DIR` out of it, and `command` skips the `claude()`
wrapper. The `&&` matters: the official plugin is disabled only once its replacement installed.
Otherwise a failed install leaves no session with Linear at all:

    ( unset CLAUDE_CONFIG_DIR &&
      command claude plugin marketplace add ~/.dotfiles/claude/plugins --scope user &&
      command claude plugin install linear-key@dotfiles --scope user &&
      command claude plugin disable linear@claude-plugins-official --scope user )

This writes four things, measured in a scratch config dir: `known_marketplaces.json` and
`installed_plugins.json` under `~/.claude/plugins/`, a copy of the plugin under
`~/.claude/plugins/cache/dotfiles/`, and `extraKnownMarketplaces` plus two `enabledPlugins` keys
in `~/.claude/settings.json`. Every account dir links the plugins dir and refreshes its
`settings.json` from the global one at launch, so each seat gets it at its next launch, with no
per-seat step. Sessions already running keep the official server until they exit.

**Check:** `claude-doctor` prints `✓ linear-key plugin installed, enabled and current` under
`--- Linear ---`, and a `✗` if a setup or rollback stopped half way and left neither plugin on, and `--- Pools ---` stops asking seats to sign in to `plugin:linear:linear`. In
a new session, `/mcp` lists `plugin:linear-key:linear` as connected.

**Rollback**, in the reverse order and for the same reason: nothing is removed until the
official plugin is back:

    ( unset CLAUDE_CONFIG_DIR &&
      command claude plugin enable linear@claude-plugins-official --scope user &&
      command claude plugin uninstall linear-key@dotfiles --scope user &&
      command claude plugin marketplace remove dotfiles --scope user )

**Changing the plugin.** Installing *copies* it into the cache, and `claude plugin update`
compares versions only: an edit without a version bump is answered with "already at the latest
version" and never reaches a session. So bump `version` in `plugin.json` with every edit,
deploy, then run, in the same subshell as the setup:

    ( unset CLAUDE_CONFIG_DIR &&
      command claude plugin marketplace update dotfiles &&
      command claude plugin update linear-key@dotfiles --scope user )

The doctor flags an installed copy that differs from the checkout. Run from a session, or
through `claude()`, any of these commands writes an account dir's `settings.json` copy, which
the next launch overwrites. It also records the plugin's `installPath` inside that dir.

What was measured on Claude Code 2.1.289, and why the setup is shaped this way:

- **`${LINEAR_API_KEY}` is expanded in a plugin's `headers`.** With the key set, `claude mcp
  list` reports the server connected. With it empty or wrong, the server answers 401, and Claude
  Code says so: "OAuth fallback is disabled when headers.Authorization is set". A seat without
  the key therefore fails loudly and never falls back to a sign-in.
- **The official plugin has to be disabled, not just outranked.** Two plugins at one URL are
  deduplicated, and the one listed *first* in `enabledPlugins` wins. With the official plugin
  installed first, it shadowed `linear-key` completely. A user-scope `mcpServers` entry at the
  same URL beats both, but `.claude.json` is seeded once per account dir, so it would never
  reach existing seats.
- **Not `--mcp-config` from `claude()`.** A session started with `clauth start` never passes
  through the wrapper, and this one setting would then differ by launcher.
- **Against a claude.ai connector at the same URL, the plugin wins in an interactive session**
  (`Suppressing claude.ai connector "claude.ai Linear": duplicates manually-configured
  "plugin:linear-key:linear"`). In a headless `claude -p`, Claude Code's lazy dedup suppresses
  the plugin as well, so neither side's tools load. Slack and Notion behave the same way, with or
  without this change.
- **End to end on a real seat:** a headless session with only this plugin serving Linear (the
  official one turned off for that run with `--settings`, and connectors off) called
  `mcp__plugin_linear-key_linear__get_issue` and got the issue back, with no sign-in.

**The key itself** can be narrowed: Linear lets a personal API key be limited to Read, Write,
Admin, Create issues or Create comments, and to specific teams (Settings → Account → Security &
Access). It is the same key rabota writes with, so it needs Read and Write, and never Admin.
