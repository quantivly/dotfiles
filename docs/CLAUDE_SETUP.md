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

    claude plugin disable chrome-devtools-mcp@claude-plugins-official --scope user
    claude plugin disable desktop-commander@claude-plugins-official --scope user

Re-enable only in a project that really uses a browser or a REPL:

    cd <project> && claude plugin enable chrome-devtools-mcp@claude-plugins-official --scope project

Running sessions keep their servers until they exit, so `pgrep -fc chrome-devtools-mcp` falls as
sessions close, not when the setting changes. `claude mcp list` in a fresh shell shows what a new
session started there would load; the two names must be absent.
