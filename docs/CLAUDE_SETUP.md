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

## Auditing the hosts (DO-880)

The laptop, dev, sol-build and nanoclaw each grew their own config dir by hand, so no one can say
which skills, hooks, memory and settings a host has, or which copy is the reference.
`scripts/claude-config-audit.sh` copies each host's configuration into one workspace on the laptop
and reports, one column per host, where they agree. It is step 1 of the
[shared-configuration design](superpowers/specs/2026-11-04-shared-claude-config-design.md): no host
is rendered from, or synced to, a shared source before this answer exists.

    scripts/claude-config-audit.sh --collect   # every default host into the workspace
    scripts/claude-config-audit.sh --matrix    # reads the workspace only; writes the five reports

| verb | exit |
|---|---|
| `--collect` | 0 every host collected · 2 a host failed (the others are still collected), or `hosts.tsv` cannot be parsed, or another `--collect` holds the workspace lock (for those two, nothing is collected) · 130/143 interrupted |
| `--matrix` | 0 every row identical · 1 drift · 2 a host in `hosts.tsv` failed or has no `facts.tsv`, or a collect is not named in `hosts.tsv` (no report is written), or a report cannot be written |

Both exit 64 on a usage error.

**Read-only on every host.** Each host runs one `bash -s` over ssh (`BatchMode`, no agent
forwarding), and that script runs only `find`, `sed`, `tar`, `date`, `hostname` (or `uname -n`),
`id -un`, and `--version` of `~/.local/bin/claude` and `~/.local/bin/herdr`. Its one write is its
own `mktemp -d` for the file list and the facts, removed on exit. The laptop (`local`) runs the
same script without ssh. The state table asserts a fixture host's tree is byte-identical before
and after.

**What is copied.** From the config dir: `CLAUDE.md`, `settings.json`, `settings.local.json`,
`keybindings.json`, `hooks/`, `skills/`, `agents/`, `commands/`, `rules/` and the two plugin
registries; under `projects/`, only `*/memory/`. Then each root `CLAUDE.md` and each repo's
`.claude/`, one level deep, in `~/quantivly`, `~/Projects` and `~/toysim`, and `~/.dotfiles/.claude`
(as `repos/home/.dotfiles/.claude/`). Symlinks are dereferenced and recorded in `links.tsv`, so a
link is never read as a second copy. Pruned by name at every depth (`EXCLUDE_NAMES`):
`.credentials.json*`, `.claude.json*`, `*.jsonl`, `*.signature*`,
`plugins/{cache,marketplaces,repos,data,store,synced}`, `skills/synced` and `worktrees`. Claude
Code's own directories (`EXCLUDE_TOP_LEVEL_NAMES`: `sessions`, `shell-snapshots`, `file-history`,
`paste-cache`, `debug`, `cache`, `backups`, `downloads`, `telemetry`, `security`) are pruned only
directly under the config dir, so a skill or repo directory that shares one of those names is
still collected; the include set never walks that level, so today those rules guard rather than
prune. Every pruned path is logged as `excluded` in `collect.log`. Every file then goes through
`scripts/redact-secrets.sh`, a `*.json` file first through a jq pass: a string under an `env`
object, or under a key named like a credential (the redactor's name rules, case-insensitive),
becomes `<REDACTED:json-name>`, since the line redactor cannot see a name inside JSON; a file jq
cannot parse gets the line redactor alone. A binary file is dropped and named in `collect.log`, a
stream member that is neither a file nor a directory fails the host, and a missing path is logged
as absent, never a failure.

```
<ws>/hosts.tsv                      name  alias  cfgdir  collected_at  status
<ws>/.collect.lock                  held by the running --collect, its pid inside
<ws>/<host>/facts.tsv               key<TAB>value: hostname user home cfgdir claude_version herdr_version collected_at
<ws>/<host>/links.tsv               path<TAB>target, every symlink in the include set
<ws>/<host>/collect.log             excluded paths, skipped binaries, absent paths
<ws>/<host>/cfg/…                   CLAUDE.md settings.json settings.local.json keybindings.json hooks/ skills/ agents/ commands/ rules/ plugins/{known_marketplaces,installed_plugins}.json
<ws>/<host>/memory/<projects-key>/  each projects/*/memory/ dir, named by its projects/ entry
<ws>/<host>/roots/<name>.CLAUDE.md  ~/quantivly ~/Projects ~/toysim root files, by basename of the root
<ws>/<host>/repos/<root>/<repo>/.claude/…   repo-local .claude dirs under those roots
<ws>/<host>/account-dirs/<seat>/settings.json   laptop only: each account dir's real settings copy
<ws>/matrix.tsv  matrix.md  settings-matrix.md  memory-matrix.tsv  memory-matrix.md
```

`matrix.*` has every collected file by layout path: `identical`, `only-on:H`, `missing-on:H,…` or
`differs newest:H`. `settings-matrix.md` compares `settings.json` key by key: `permissions.allow`
as set differences, hooks by script basename, plugins and marketplaces by name. `memory-matrix.*`
compares memory files per store, the key stripped of `-home-USER-` so stores meet across homes.

**`hosts.tsv` is the authority on which collects are valid.** Each `--collect` merges its rows in:
a host it did not collect keeps its row, so re-collecting one host never drops the others, and a
host's earlier collect is replaced only once the new one is whole. `--matrix` reports on every
host the file names and refuses a collect directory it does not name. A host is retired by
deleting its row and its directory.

Default hosts: `laptop=local:.claude`, `dev=dev:.claude`, `sol-build=sol-build:.claude`,
`nanoclaw=nanoclaw:.claude-herdr`. `--host NAME=ALIAS:CFGDIR` (repeatable, `--collect` only)
replaces them: `ALIAS` is an ssh alias or `local`, `CFGDIR` a dot-directory under that host's
`$HOME`. The default workspace is `~/Projects/handoffs/2026-11-claude-config-audit`
(`--workspace DIR`). `CLAUDE_CONFIG_AUDIT_WORKSPACE` overrides that default and
`CLAUDE_CONFIG_AUDIT_SSH` the ssh command; the state table,
`scripts/test-claude-config-audit.sh`, points the latter at its stub.

**Known limits.**

- **One `--collect` per workspace at a time.** A second one exits 2 at once, naming the pid that
  holds `.collect.lock`; each would otherwise sweep the other's staging directories. `--matrix`
  takes no lock, so do not run it while a `--collect` is replacing hosts.
- **A workspace path containing a backslash breaks `--collect`.** The default has none.
- **`--matrix` takes tens of seconds** on a laptop-sized workspace; it hashes every collected file
  on every run.
- **A host whose shell startup prints to stdout fails its collect**: the stream does not unpack,
  so nothing partial lands.
- **Untested against AL2-era hosts** (bash 4.2, tar 1.26); every default host runs Ubuntu.

## Rendered settings (DO-884)

On a host that carries a profile marker, `~/.claude/settings.json` is a render:
`scripts/claude-settings-render.sh` folds a public base fragment and the private overlays the
host's profile names into the live file. It is step 2 of the
[shared-configuration design](superpowers/specs/2026-11-04-shared-claude-config-design.md), D4
as amended on 2026-11-05.

**The marker and the profile.** `~/.config/claude-host-profile` holds one line, the profile name
(`[A-Za-z0-9][A-Za-z0-9._-]*`), written by `~/.dotfiles-local`'s install (DO-885). The profile is
`~/.dotfiles-local/hosts/<name>.json`, `{"tenants": ["quantivly", …]}`, its tenants in merge
order. **A host without the marker is not rendered**: a teammate's box, a modular `--herdr`
adopter and CI get one line and exit 0, before the script even looks for jq, and there
`herdr-claude-wire.sh` keeps merging its statusLine and Stop bell as it always has.

**The fragments**, in merge order. Each must exist and be a JSON object, or nothing renders.

| fragment | lives in | holds |
|---|---|---|
| `claude/settings/base.json` | this repo, public | the repo's own hooks (secret guard, herdr `SessionStart`, the Stop bell, herdmates), the statusLine (`refreshInterval` 120), the `dotfiles` marketplace and `linear-key`; a row pins it to exactly those keys |
| `claude/settings/common.json` | `~/.dotfiles-local`, private | what every tenant shares |
| `claude/settings/<tenant>.json` | `~/.dotfiles-local`, private | one per tenant in the profile, in profile order: permissions, plugins, marketplaces, the org-wide auto-mode block |

**The merge rules**, from the script's header:

```
The fragments are folded, in order, into the live settings file (absent: {}).
  - Lists are unioned: the live elements in their order, then each fragment's new ones; an
    element appears once.
  - Objects are deep-merged; on a scalar the fragment wins, and a later fragment over an earlier.
  - Hooks, per event: an entry is keyed by the basename of the first script path in its command
    (`$HOME/…`, `${HOME}/…`, `~/…` or `/…`, quoted or not, redirections ignored), or else by its
    executable (the first word that is not `command`, `exec`, `[`, `]`, `&&`, `||` or an
    option). A fragment entry replaces the live entry with its key, in place, and drops any other
    (the same script under another path or matcher); a new key is appended. The key is the
    script basename or executable alone, matcher excluded, so a fragment that declares one key
    twice under one event is refused (exit 2). An event no fragment declares is left as found.
  - autoMode.environment: the fragment's lines replace the live lines from `### Org-wide` up to,
    not including, `### User-specific` (or to the end). With no live `### Org-wide`, they go
    first, then `### User-specific` (moved up, or added), then the other live lines. A fragment
    block must start with `### Org-wide` and hold no `### User-specific` (else exit 2).
  - $HOME is substituted in marketplace source paths only.
  - A key no fragment declares is left exactly as the live file has it.
```

**The verbs.** The render and the live file are compared in one canonical form
(`jq -S --indent 2`), so formatting and key order are never drift. `--check` diffs and prints only
the top-level keys some fragment declares, so an undeclared value (clauth's `env`) is never shown;
`--print` emits the whole render, what `--apply` would write.

    scripts/claude-settings-render.sh --check            # the diff, live → rendered; writes nothing
    scripts/claude-settings-render.sh --print            # the render on stdout; writes nothing
    scripts/claude-settings-render.sh --apply            # write it, with a backup, only if it differs
    scripts/claude-settings-render.sh --list-fragments   # the fragment paths, in merge order

| exit | meaning |
|---|---|
| 0 | rendered, already level, or no host profile here (nothing to render) |
| 1 | `--check` found drift |
| 2 | could not run: no jq, a bad marker or profile, a fragment missing or not an object, a fragment auto-mode block that is not an org-wide block, a fragment declaring one hook key twice under one event, a settings file that is a symlink or not one JSON object, a failed write or backup |
| 64 | usage |

`--settings PATH` renders another file; `CLAUDE_SETTINGS_RENDER_MARKER` and
`CLAUDE_SETTINGS_RENDER_OVERLAY` override the marker and `~/.dotfiles-local`.

**Who runs it.** `./install` runs `--apply` on every host (the no-marker note is its whole
effect on most of them). `scripts/herdr-claude-wire.sh`, on a host with the marker, runs it once
for its statusLine and Stop-bell steps (`--check` under `--print`) and merges nothing itself.
`claude-doctor`'s "Rendered settings" section runs `--check`: ✓ rendered, ✗ drifted (run
`--apply`), ⚠ could not run (its last stderr line), and a note on a host with no profile.

**The backups.** `--apply` copies the file it replaces to
`~/.local/state/claude-settings-render/settings.json.before-<UTC stamp>` (the directory is created mode 700),
always mode 600 whatever the live file's mode. A second backup within one UTC second gets a
`.NNN` counter (`…Z.001`), so the names sort in the order they were made. The newest ten are kept;
a file in that directory whose name the script would not make is never pruned. A level file is
not rewritten and makes no backup.

**`settings.json` is still not a symlink.** It is a real file, written by a temp file beside it and
one rename, keeping its mode (600 for a new one). A symlinked `settings.json`, even a dangling
one, is refused by every verb that reads it. clauth rewrites `env` on every profile switch and
Claude Code writes its own keys (`feedbackSurveyState` and the like); no fragment declares them,
so they are kept as found and never count as drift. The account-dir builder still copies the
rendered file into each seat's dir at launch.

State table: `scripts/test-claude-settings-render.sh` (hermetic: fixture `HOME`, marker and
overlay; CI `claude-settings-render-test`).
