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

## Memory stores (DO-891)

Claude Code keeps auto-memory in `~/.claude/projects/<key>/memory/`, one directory per checkout
path on one machine, so memory neither survives a new host nor follows a repo between hosts.
`scripts/claude-memory-link.sh` maps each project key to a directory in a git-backed store and makes
its `memory` entry a symlink there. It is the link half of D7 in the
[shared-configuration design](superpowers/specs/2026-11-04-shared-claude-config-design.md), as
amended (M1-M8). The link itself commits and pushes nothing: `scripts/claude-memory-sync.sh` does
that, on a timer once a host arms it ([Syncing a store](#syncing-a-store-do-892), below).

**The layout.** A store is a git checkout at `~/.local/share/claude-memory/<store>`, keyed by repo
identity rather than by path:

```
~/.local/share/claude-memory/<store>/
  repos/<owner>/<repo>/   a checkout with an origin (lowercased, by the rule of repo_of_url in scripts/dev-sync)
  dirs/<slug>/            a directory with no .git, or a repo with no origin
```

The slug is the path relative to `$HOME`, `/` becoming `-`, lowercased, and `home` for `$HOME` itself.

**The table.** `~/.dotfiles-local/claude/memory-stores.json`, private, is what opts a host in:

```json
{
  "stores": {"<store>": {"remote": "https://github.com/<owner>/<repo>.git", "tenants": ["<tenant>"]}},
  "checkout_globs": ["<path relative to $HOME, may hold *>"],
  "plain_dirs": ["<path relative to $HOME; the empty string is $HOME>"],
  "stale_after_minutes": {"default": 60, "<host>": 120}
}
```

`stale_after_minutes` is optional and read by the sync alone: how long a store may go without a
successful sync before the doctor calls it stale, per host (`hostname -s`), else `default`, else 60.

**A host without the table is not touched**: one line and exit 0, before the script even looks for
jq. A store in the table that is not checked out on this host is left alone too. `./install` runs
neither script: it links the `claude-memory-sync` timer and does not enable it. Until a host arms
that timer, a by-hand `--apply` is the only way a link appears; once armed, every tick runs
`--apply` before it syncs ([The tick](#the-tick), below).

**Which directory a key names.** The key of a path is the physical path with every character outside
`[A-Za-z0-9]` replaced by `-`, and the candidates are every directory matching a `checkout_globs`
entry that holds `.git`, each populated submodule of one, and every `plain_dirs` entry that exists.
A candidate's store is the one whose `tenants` holds the tenant `scripts/tenant-route <dir>` answers;
a tenant no store lists is exit 2, never a default. A worktree has no key of its own, since Claude
Code keys it by the main checkout. A submodule has two, its own path and its git dir, both linked to
one store directory. The script's header has the full rules.

**The eight states**, first match wins. A candidate with no `memory` entry and nothing in its store
directory has no state and no row.

| state | what it means | `--check` | `--apply` |
|---|---|---|---|
| `PENDING-MERGE` | a `memory.replaced-*` directory exists without the marker, or holding a file newer than it | to fix | finishes the merge, unless the store is not checked out or no candidate claims the key: then it has nowhere to go and is left |
| `NO-STORE` | mapped, but that store is not checked out on this host | not shown, but counted as `without a store` when its `memory` is a real directory holding a file, or a symlink into that store's checkout (a store removed after linking) | left alone |
| `LINKED` | a symlink to the mapped store directory, which exists and resolves inside its store checkout, outside the checkout's `.git` | counted | nothing |
| `DANGLING` | the right symlink, but its target directory does not exist | to fix | creates the directory |
| `WRONG-LINK` | a symlink to anywhere else, or the right one whose target now resolves outside the store checkout or into its `.git` (a link planted above it since) | to fix | left alone, to fix by hand (a pending merge still finishes, reported as `merged`) |
| `REAL-DIR` | a real directory, the key is mapped, the store is checked out | to fix | swaps it for the link and merges it in |
| `MISSING` | no `memory` entry, and the mapped store directory holds a file, such as memory another host wrote | to fix | creates the link |
| `UNMAPPED` | a real `memory` directory holding a file, under a key no candidate claims | shown, exit 0 | not walked: it has no store directory (see **Adding a directory**) |

**The verbs.** `--check` and `--list` only read.

    scripts/claude-memory-link.sh --check                 # each row not LINKED or NO-STORE, then the summary line
    scripts/claude-memory-link.sh --list                  # every key as TSV: key, state, store, store-relative directory, source directory
    scripts/claude-memory-link.sh --apply --dry-run       # the lines --apply would print; changes nothing, takes no lock
    scripts/claude-memory-link.sh --apply                 # finish pending merges, then link
    scripts/claude-memory-link.sh --apply --only <key>    # the same for one key

`--check` ends with its summary line:

    claude-memory-link: <n> linked, <n> to fix, <n> unmapped, <n> without a store

The last count is the `NO-STORE` keys whose `memory` is a real directory holding a file, or a symlink
into that store's checkout, which is what a store removed after linking leaves: memory waiting for its
store to be checked out here. No row of `--check` names them; `--list` does.

`--apply` prints one line per key it acted on, and nothing on a second run:
`linked <key> -> <store dir> (copied <n>, identical <n>, kept-both <n>)`. A real run holds an flock on
`~/.local/state/claude-memory-sync/link.lock`, so another run waits for it, 120 s at most
(`CLAUDE_MEMORY_LOCK_WAIT_SECONDS`), and then is exit 2 naming the lock with nothing touched.

| exit | meaning |
|---|---|
| 0 | nothing to fix, or no table here. `UNMAPPED` rows alone are exit 0, with their rows printed |
| 1 | `--check` found a key to fix |
| 2 | could not run: `HOME` unset, no jq or git, a bad table (a symlink to nothing included), `tenant-route` or git could not answer, a key two stores share, an unreadable projects or key directory, a `memory` entry that is neither a directory nor a symlink; on `--apply` also no flock or cmp, an unusable host name, and any step of a swap or a merge that failed, reported once the other keys have run |
| 64 | usage |

**What `--apply` does to a real directory**, in this order, which is the safety argument:

1. `mkdir -p` the store directory.
2. Rename `memory` to `memory.replaced-<UTC yyyymmddThhmmssZ>` beside it, atomic within one
   filesystem. A write by path before this point is in the merge.
3. Symlink `memory` to the store directory. A directory a writer recreated meanwhile is renamed
   aside too and the link retried, at most 3 times, then exit 2.
4. Merge each replaced directory into the store directory, file by file.
5. Write the marker `.merged-into-store` in the replaced directory, after its last file.

**What it never does: delete or overwrite a memory file.** The replaced directory stays beside the
link and is never pruned, and the only changes to a store's existing content are the appended index
lines below. A writer holding an open descriptor or a cwd inside the directory can land after the
walk; that write stays in the replaced directory, not lost and not merged. Nothing leaves the store
through a symlink either: a store directory that resolves outside its store checkout (a link planted
at `repos/<owner>`, say), or into the checkout's own `.git`, where git would run a memory file named
like a hook, is exit 2 before anything is made, renamed or written for that key, and a target whose
directory resolves outside the store directory is refused file by file. `--check` holds a `LINKED`
key to the same rule, so a link planted above the store directory after the key was linked reads as
`WRONG-LINK`.

**The marker means "merged".** A replaced directory without `.merged-into-store` reads as
`PENDING-MERGE`, so a run stopped anywhere fails `--check`, and the next `--apply` finishes the merge
before anything else on that key. A file that cannot be merged leaves its directory unmarked while
its other files still go, and a key that fails stops only itself. A real directory that already holds
the marker, which is what undoing a link with `mv memory.replaced-<stamp> memory` leaves, is merged
like any other: the marker spoke for what it held then, so it is removed before the rename. The one
case the marker does not settle is a file written into a replaced directory after it: a regular file
newer than the marker reads as `PENDING-MERGE` again, and the next `--apply` merges what is newer than
the marker, and only that, since the store has been free to move on from the rest, then writes the
marker anew. A marker path holding anything but a regular file is refused, exit 2, and the directory
stays unmarked.

**One file in the merge**, at any depth. A symlink is copied and compared as a link, never followed,
or it would bring what it points at into a store that is pushed to a remote.

| the store holds | what happens |
|---|---|
| nothing at that name | copied to a `.<name>.link-partial` beside it, checked against the source, and published by `link(2)`, which cannot overwrite |
| the same bytes | nothing |
| a different `MEMORY.md` or `INDEX_*.md` | the lines only the replaced copy has are appended |
| any other different file | the store's copy keeps its name, whichever is newer, and the replaced copy becomes a conflict copy beside it |

A conflict copy inserts `.conflict-<host>` before the final extension: `x.md` becomes
`x.conflict-<host>.md`, and a name with no extension gets it appended. A copy that already holds
another body is kept and the next is `x.conflict-<host>.2.md`, `.3.md`, and so on; one with the same
body is that file already, so a resumed merge adds none.

**Adding a directory.** An `UNMAPPED` row is usually the prompt: it names a key holding memory that
the table does not claim. A key whose directory still exists is claimed by adding it to
`checkout_globs` or `plain_dirs`: a pattern in `checkout_globs` for a checkout (with its populated
submodules), or the path in `plain_dirs` for a directory that is not one, with a store's `tenants`
listing the tenant `scripts/tenant-route <dir>` answers for it. `--check` then shows the key as
`REAL-DIR`; look with `--apply --dry-run --only <key>`, then run `--apply --only <key>`.

A key whose directory no longer exists cannot be claimed: a `plain_dirs` entry absent on this host is
skipped and no glob matches what is gone. Read its memory, move what is worth keeping into the store
by hand, then move the key directory out of the projects directory, or the row is permanent: under a
new name inside it, the key directory is walked again.

**Permission mode, from the pilot** (Claude Code 2.1.319, 2026-11-06). With `memory` a symlink to a
directory outside `~/.claude`, the index loads at session start, and Write, Read and Edit work. A
`default`-mode session is asked on a memory write, as it was before the link; an `auto`-mode one is
not.

**Who runs it.** A person, and every tick of an armed timer, which runs `--apply` before each sync.
`claude-doctor`'s "Memory stores" section runs `--check`, and nothing else: a note
with no table, ✓ with the counts, ✗ with each row on exit 1 (`--apply --dry-run` shows what `--apply`
would do), ⚠ with each row and both remedies when an exit 0 carries `UNMAPPED` rows, ⚠
`no store that these keys map to is checked out here (<n> keys wait for one)` when nothing is linked
and keys hold memory waiting for a store, and ⚠ with the last stderr line when it could not run.
`CLAUDE_MEMORY_PROJECTS_DIR`, `CLAUDE_MEMORY_STORES_ROOT`,
`CLAUDE_MEMORY_CONFIG`, `CLAUDE_MEMORY_STATE_DIR`, `CLAUDE_MEMORY_HOST` and
`CLAUDE_MEMORY_TENANT_ROUTE` override the paths, the host in a conflict copy's name and the tenant
lookup.

### Syncing a store (DO-892)

`scripts/claude-memory-sync.sh` turns the writes the link lands in a store checkout into commits,
and carries them between hosts through the store's remote. For each checked-out store, in this
order (the script's header has the full rules):

1. **Refuse what it must not touch.** Every fetch and push URL of `origin` must be the table's
   `remote`, so a store pushes only to its own. A merge, cherry-pick, revert or rebase in progress,
   unmerged index entries or a detached HEAD is `could-not-run`, and is never reset.
2. **Route.** `scripts/gh-route <store dir>` names the GitHub account that directory routes to, and
   the shell's existing token cache file for it (M7: the keyring is keyed by host and cannot choose
   an account). The token is read from that file and handed to the fetch and the push alone, in
   their environment, through an inline credential helper that answers only `get`. **No token is
   written anywhere**: no new file, no argument, no output, no status. A route that pins an account
   whose token file is missing, empty or unreadable is `skipped-no-token`; a directory with no
   route uses git's own credential helpers.
3. **Fetch**, with no prompt, cut off after 60 s.
4. **Under the link script's lock** (`~/.local/state/claude-memory-sync/link.lock`, so an index
   mid-write is never staged): stage every file but the link script's `.<name>.link-partial`
   copies, with `git add -A -f`, since no ignore rule decides what is memory; **withhold** each
   file whose name or content carries a credential shape (`scripts/redact-secrets.sh
   --shapes-only`), naming it with the shape's label and never a line of it; commit the rest as
   `<host>: <n> files`, with no hook and no signature; then **merge** origin's branch. Never a
   rebase: one empties the tree of every unpushed file while it replays, and sessions write there.
5. **Push** once, unless origin already holds HEAD.

**The merge rules**, for a file both sides changed. Renames are off, so a rename is a deletion and an
addition.

| this host | origin | result |
|---|---|---|
| modified | modified | origin's copy keeps the name, and ours becomes a conflict copy |
| added | added | the same |
| a `MEMORY.md` or `INDEX_*.md`, changed | changed | origin's lines, plus each line only ours has |
| deleted | modified | origin's copy |
| modified | deleted | ours: an edit beats a deletion |
| anything else (a submodule, a file against a directory) | | `git merge --abort`, and `could-not-run` |

A conflict copy is named as the link step names one (`x.md` → `x.conflict-<host>.md`), and the merge
commit says `<host>: merge, kept both for <n> files`. Each resolution is staged from the blobs the
merge produced, never from the working tree, so nothing the gate has not seen is committed.

**The run deadline.** All the stores together get 240 s (`RUN_DEADLINE_SECONDS`, measured on the
kernel's monotonic uptime). A store that begins past it does no network work: it commits and records
`unreachable`, `run deadline`. The deadline never cuts a step short, so a gh-route call and a fetch
that began just before it can add 90 s: about 330 s at worst. With the link step's 125 s at most
before it, that is why the unit allows 8 min.

**The ten outcomes.** A store's last one is in `~/.local/state/claude-memory-sync/<store>.status`,
and `<store>.last-ok` holds the time of the last push, or up-to-date check, that succeeded. `--apply`
exits 0 for every one but `could-not-run`: the rest are the doctor's to show.

| outcome | what it means | what to do |
|---|---|---|
| `ok` | committed, merged with origin and pushed, or origin already held it | nothing |
| `kept-both` | the same, after a conflict that left a conflict copy or an index line union | resolve the conflict copy (below) |
| `ok-local-only` | the store has no `origin`; whatever was pending is committed | give it the table's `remote` as `origin` |
| `withheld` | the gate held a file back; the detail names it and its shape | release it (below) |
| `blocked` | the merge would not start, a local file in its way: usually a withheld one that origin also has | release that file; the next tick merges, keeping both copies if they differ |
| `push-rejected` | origin refused the push, usually because another host pushed first | nothing: the next tick fetches, merges and pushes again. One that outlasts the threshold is the remote refusing this account or this branch |
| `skipped-no-token` | the route pins an account and its token file is missing, empty or unreadable; the store was committed and nothing went over the network | refresh the shell's token cache (`gh-refresh-tokens`) |
| `unreachable` | the fetch or the push failed, or ran out of time (the run deadline included), for a reason not naming auth | nothing while it is brief; past the threshold, look at the network and GitHub |
| `auth-failed` | git's error named an auth or a not-found failure | `gh-doctor` in the store checkout: the account it routes to must be able to push to the store's repo |
| `could-not-run` | the store could not be synced; the detail says why | what the detail names: finish or abort an operation by hand in the store, point `origin` back at the table's `remote`, merge a conflict the sync does not resolve by hand, or set a git identity |

**What `claude-doctor` shows.** After the link rows, the section asks `scripts/claude-memory-sync.sh
--status`, which only reads, and shows each line it prints as a row, `memory store <store>:
<message>`:

- ✗ when the last outcome is `withheld`, `blocked`, `auth-failed` or `could-not-run`; when a store
  with an origin has not synced within the threshold (`never synced; …`, or `last synced <n> min
  ago, past the <t> min threshold; …`, naming the last outcome); or when `--status` cannot read the
  store at all, naming the reason (an origin that is not the table's `remote`, an origin git cannot
  read, a status or last-ok file the sync did not write, a tree it cannot search), and nothing else
  about that store;
- ⚠ for `no remote yet` (`ok-local-only`); `push-rejected`, `unreachable` or `skipped-no-token`
  while the last success is still within the threshold; `no run recorded yet` for a store with no
  origin; `<n> conflict copies in the tree`; and, per directory, an index line naming a missing file
  or one file named by two index lines;
- ✓ `last synced <n> min ago` otherwise, or, for a store with no origin, `last outcome <outcome>`
  with its detail.

The threshold is the table's `stale_after_minutes`. A store the table names that is not checked out
on this host is skipped, never a row: a host carries only the stores of the tenants it serves. When
no store is checked out `--status` prints nothing and the doctor adds no row, the link rows' ⚠ having
said so. `--status` exits 2 only when it could read nothing (no jq, a bad table or threshold, a state
dir that exists and cannot be read); the row is then ⚠ `memory sync status could not be read: <last
stderr line>`, with every stderr line before it printed indented under it. A line the doctor cannot
read is shown whole as a ⚠.

**Resolving a conflict copy.** `x.conflict-<host>.md` beside `x.md` holds this host's body, where
origin's took the name. Merge the two bodies into `x.md` by hand, delete the copy, and let the next
tick commit and push: the ⚠ clears when no copy is left. An index file gets no copy, since it took
the union of the lines; the doctor's index ⚠ names a directory whose index now lists a missing file,
or one file twice.

**Releasing a withheld file.** The gate leaves the file in the working tree, so every tick names it
again until it changes. Edit the credential out of it (`--check` names the file and the shape's
label), or, when it is the NAME that carries the shape, rename the file: a kebab-case name beginning
`xoxb-` matches the Slack shape, for one. The next tick commits it. `--scan` runs the same gate over a
committed tree, for history this script did not write.

**A git identity.** The sync commits as the host's own `user.name` and `user.email` (on these
dotfiles, from `~/.gitconfig.local`, or the store's own config). With neither, every commit fails and
the store reads `could-not-run: git commit failed`.

### The tick

`systemd/claude-memory-sync.service` and `.timer`, linked by `./install` and **not enabled**. Every
10 minutes (`OnCalendar=*:0/10`, up to 60 s later at random, and a tick missed asleep runs once on
resume) it runs `scripts/claude-memory-link.sh --apply`, then `scripts/claude-memory-sync.sh
--apply`, within 8 min. The link step is `ExecStartPre=-/usr/bin/timeout --kill-after=5 120 …`: its
failure never stops the sync and never fails the unit, and neither does its running out of time,
which the `-` alone would not cover (the unit's time limit counts both steps, and a link step can wait
on a lock a by-hand run holds). Either shows only in the doctor's link row. The service runs only where
`~/.local/share/claude-memory` exists. Both units' headers say why each value is what it is.

**Arming**, by hand on each host, once the table and a store are there:

```bash
~/.dotfiles/scripts/claude-memory-link.sh --apply --dry-run   # what the first tick's link step will do
~/.dotfiles/scripts/claude-memory-sync.sh --check             # exit 2 if an origin is not the table's remote; names each file it would withhold
systemctl --user daemon-reload
systemctl --user enable --now claude-memory-sync.timer
```

Before the first tick `--check` exits 1 whenever something is pending, which is normal: read its
lines, not its exit status.

**Disarming.** Never `systemctl --user disable` or `reenable`: either one deletes the dotbot link
that is the unit (the note at the top of `scripts/reconcile-systemd-units.sh`). Stop the timer and
remove its `.wants` link by hand:

```bash
systemctl --user stop claude-memory-sync.timer
rm ~/.config/systemd/user/default.target.wants/claude-memory-sync.timer && systemctl --user daemon-reload
```

An armed timer on a host whose `~/.local/share/claude-memory` has gone is skipped, and
`scripts/check-timer-health.sh` reports that as the fault it is: memory stopped travelling.

`CLAUDE_MEMORY_STORES_ROOT`, `CLAUDE_MEMORY_CONFIG`, `CLAUDE_MEMORY_STATE_DIR`, `CLAUDE_MEMORY_HOST`,
`CLAUDE_MEMORY_GH_ROUTE`, `CLAUDE_MEMORY_LOCK_WAIT_SECONDS`, `CLAUDE_MEMORY_RUN_DEADLINE_SECONDS` and
`CLAUDE_MEMORY_GH_ROUTE_TIMEOUT_SECONDS` override the sync's paths, host, route and limits.

State tables: `scripts/test-claude-memory-link.sh` (206 rows) and `scripts/test-claude-memory-sync.sh`
(103 rows), both hermetic: a fixture `HOME`, every path named, real `git init` checkouts, and for the
sync local bare repositories as remotes and a stub `gh-route` (CI `claude-memory-link-test` and
`claude-memory-sync-test`). The doctor's rows are section AA of `scripts/test-claude-doctor.sh`, and
`scripts/test-claude-config-audit.sh` pins that `claude-config-audit.sh` collects a linked `memory`
by content.
