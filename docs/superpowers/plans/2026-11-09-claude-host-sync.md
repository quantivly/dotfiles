# Claude Host Sync (program step 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revision 2, 2026-11-09.** Revised after an independent review (2 Critical, 11 Important, 12 Minor; every Critical and Important is folded in, the Minors where they cost a line). The review's main corrections: the timer move is now lock-first and verify-before-touching-the-old; the overlay is cloned before the public `./install`; the plugin row's blast radius on marker-less hosts is stated rather than denied; `MUTATING` grows with the verbs the new rows add. Public content only.

**Goal:** Turn `scripts/dev-sync` into `scripts/host-sync`, one sync loop every agent host runs against git, parameterised by the host profile, with rows for everything the shared-configuration design declares: the private overlay, rendered settings, declared links, declared plugins, generated skills, linked and synced memory, and the absence of retired artifacts.

**Architecture:** The two-halves design stays: a controlling run on the laptop gathers facts and pipes the script to a host as `bash -s -- --here …`, and the host's own daily timer runs `--here --apply --no-mcp` with no laptop facts. The script reads the host profile marker (`~/.config/claude-host-profile` → `~/.dotfiles-local/hosts/<profile>.json`) and gates the overlay-dependent rows on it, so a host that has not opted in is never rendered, cloned into, linked or retired. The new rows do not reimplement the sibling scripts: they call `claude-settings-render.sh`, `claude-memory-link.sh`, `claude-memory-sync.sh --status`, `check-links.sh` and the herdr binaries, map their exit codes to ✓/✗/⚠, and run their `--apply` verbs when asked. The timer unit becomes `host-sync.timer`; the first `--apply` on a host whose `dev-sync.timer` is armed enables the new timer, verifies it, and only then moves the marker and stops the old one.

**Tech Stack:** bash, jq, git, systemd user units, the repo's hermetic state tables (stubs for `claude`, `herdr`, `systemctl` and the sibling scripts; real git against `file://` bare repos; the real link checker).

**Spec:** `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md`, D8 (this step), with D2 (profiles), D4 (render), D5 (plugins), D6 (skills), D7 (memory) and D9 (doctor) as the rows' definitions. The handoff that scoped it: `~/Projects/handoffs/2026-11-09-claude-config-step6-handoff.md` (private). The review: `~/Projects/handoffs/2026-11-claude-config-audit/step6/plan-review.md`.

## Global Constraints

- **Spec amendments, recorded under D8 by Task 4 (H1–H4, H9, H10) and Task 11 (H5–H8) before each PR merges:**
  - **(H1) The profile marker gates the overlay-dependent rows:** `dotfiles-local`, `settings`, the memory store clones and the memory timer, and the `retire` move. With no `~/.config/claude-host-profile` none of those runs. The `plugin` and `marketplace` rows read the live `settings.json` on every host (H4), so a marker-less host's declaration is whatever that file already says; what that changes on dev between PR 2 and step 7 is recorded in PR 2's body (its 19 `true` entries become ✓ rows instead of today's 4; nothing is installed, enabled or disabled by it).
  - **(H2) Marker and state move, in that order of safety.** `~/.local/state/dev-sync/` becomes `~/.local/state/host-sync/`, moved under the lock on the first `--apply`. `~/.config/dev-sync/{armed,disarmed}` become `~/.config/host-sync/{armed,disarmed}`, moved file by file **only after** `host-sync.timer` reads back enabled and active, so every intermediate state has at least one timer whose `ConditionPathExists` holds. `systemd/dev-sync.{service,timer}` stay linked one release; `dev-sync.timer` is stopped and its `.wants` link pruned by hand (never `disable`, never `reenable`) only after that read-back; when the new timer cannot be armed, the old one is left armed and the run says so.
  - **(H3) "Not armed" is information, not drift.** Arming is a per-host decision, like the memory timer's. Drift is an `armed` marker without an enabled, active `host-sync.timer`, or a `dev-sync.timer` still carrying the arming. `--apply` re-arms on a marker without `--arm`.
  - **(H4) The plugin declaration is the live `settings.json`** (rendered on a host with a profile): the `enabledPlugins` entries that are `true`, and `extraKnownMarketplaces`, with `claude-plugins-official` implicit. The sync adds and refreshes marketplaces and installs missing plugins; it updates only the directory-marketplace plugin whose version the checkout carries (`linear-key`); it never enables or disables a plugin (the render owns enablement; the superseded list and the official-Linear rule leave the script). D5's weekly update of marketplace plugins stays unimplemented and is carried to step 10. Every `claude plugin` call the sync makes runs with `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`.
  - **(H5) Stale is structural.** An entry under `~/.claude/skills`, `~/.claude/hooks` or `~/.claude/agents` is declared when it is a symlink that resolves to an existing path under the resolved `~/.dotfiles/` or `~/.dotfiles-local/`; generated when it is `skills/herdr`, `skills/spawn` or `hooks/herdr-agent-state.sh`; Claude Code's own when it is `skills/synced` or any dot-entry under `skills/`; anything else (a regular file or directory, a dangling link, a link elsewhere) is stale. `--apply` moves stale entries to `~/.local/state/host-sync/retired/<UTC stamp>/<kind>/<name>` and never deletes; it does so only on a host with a profile marker. On dev this rule yields exactly the audit's dispositions (`audit.md` §3–§5, A1): the 15 agents and `review-pr`.
  - **(H6) Store checkouts are clones made by `host-sync --apply`:** `git clone <the table's remote, verbatim> ~/.local/share/claude-memory/<store>` for each store whose `tenants` meets the profile's, with the host's own git credentials (a host that `--apply` runs on has one GitHub account; the laptop is never applied). A checked-out store that serves none of the host's tenants is reported, never removed. On an armed host with at least one served store checked out, `--apply` enables `claude-memory-sync.timer`; the host-sync arming is that decision.
  - **(H7) git ≥ 2.40 is a host requirement of the memory sync** (`--attr-source`); `host-sync` reports an older git as a person's step.
  - **(H8) One link checker for both repos.** `scripts/check-links.sh` is ported from dotfiles-local into the public repo with `--root`, `--config` and `--tsv`; `host-sync` runs it against both checkouts. Dotbot's `backup: true` is the safety net: a declared link that is a regular file is drift the repo's `./install` fixes, and when its content differs from the repo the row names the backup dotbot leaves beside it. A source missing from the checkout is a person's step. The private copy is replaced by the public one in step 7's dotfiles-local PR.
  - **(H9) The auth rows do not apply where clauth manages accounts** (`~/.clauth` exists): one information row, no `claude auth status` call.
  - **(H10) `host-sync` requires `--host <alias>` or `--here`;** `scripts/dev-sync` stays one release as a wrapper that supplies `--host dev`.
- **The existing checks keep their meaning.** Every needle that names `dev-sync`, `~/.config/dev-sync` or `~/.local/state/dev-sync` is rewritten to the new name in the same commit as the rename; a row is removed only when the behaviour it pins leaves the script (Task 7 names all twelve), and the commit message lists them. `EXPECTED_ROWS` is asserted after every task.
- **State-table rules** (CLAUDE.md "CI/CD Testing"): hermetic under `mktemp -d` with a fixture `HOME`; remotes are local bare repos; **no network and no agent**: every laptop-half row sets `HOST_SYNC_DOTFILES_REMOTE=file://…` and `HOST_SYNC_GITHUB_BASE=file://…` as the existing ones do; stubs record every call; "could not run" is exit 2; every needle unique to its rule and checked against the pass path; a mutation sweep before each merge with the killing row named before each mutant runs, each mutant under `setsid timeout --kill-after=5 120`, one at a time, fixtures inside the work directory, `ps` for `mutant-` through the redactor and `du` afterwards; no GNU-only awk or grep extensions (`grep` is a ugrep shim, `awk` is mawk).
- **`MUTATING` names every verb that changes a host,** and the "nothing mutating" rows also diff a filesystem snapshot (the table's `snapshot()`, minus `$STATE` and the stub log). Task 2 adds `systemctl --user stop`; Task 6 adds `claude-settings-render.sh --apply`; Task 8 adds `herdr-draft skill$`; Task 9 adds `claude-memory-link.sh --apply` and `git clone` (logged by the sibling stubs and by a `git` wrapper that records `clone` and execs the real git); Task 10's retire `mv` is caught by the snapshot. One mutant per PR removes the new alternatives from `MUTATING` and must turn the second-apply rows red.
- **Tests never touch the real machine:** no row runs against `~/.claude`, `~/.dotfiles`, `~/.dotfiles-local` or `~/.local/share/claude-memory`; the renderer, the link and sync scripts are stubs committed into the fixture's seed repo (never untracked files in the fixture clone); the laptop smoke tests are `--here --check --no-mcp` and `--host dev --check`, which write nothing.
- **Nothing here reads a credential.** The token rows keep their by-name, by-mode, by-date reads; the memory rows read `--status` lines; git stderr that reaches a row passes through `scripts/redact-secrets.sh`.
- **Never read** `~/.zshrc.local`, `~/.gitconfig.local`, any `.credentials.json` or `.claude.json` in a probe; never run `env` or `printenv`.
- **Every sibling call maps its exit code the same way:** 0 and 1 as the row defines; 2 → ⚠ "could not run" with the first stderr line; **anything else (127 when the sibling does not exist on a host behind this release, a timeout) → ⚠ "could not run (exit N)"**, never ✓ and never ✗.
- **Every `./install` the script runs is `bash ./install </dev/null`** (the public install prompts on a tty).
- **Exit codes unchanged:** 0 level (⚠ rows allowed) · 1 drift remains · 2 could not run · 64 usage.
- **Env overrides** are renamed wholesale: every `DEV_SYNC_*` becomes `HOST_SYNC_*`. New: `CLAUDE_SETTINGS_RENDER_MARKER` (the renderer's own name for the marker, so one variable moves all three scripts), `CLAUDE_MEMORY_STORES_ROOT` (the sync's), `HOST_SYNC_DOTFILES_LOCAL_REPO` (default `ZviBaratz/dotfiles-local`, the public spec's name for it).
- **Names explicit; literals with a role as named constants.** Existing globals keep their names (`DOTFILES`, `STATE`, `SETTINGS`, `INSTALLED`, `KNOWN`); new ones: `DOTFILES_LOCAL`, `MARKER_DIR`, `LEGACY_MARKER_DIR`, `LEGACY_STATE_DIR`, `TIMER_UNIT=host-sync.timer`, `LEGACY_TIMER_UNIT=dev-sync.timer`, `MEMORY_TIMER_UNIT=claude-memory-sync.timer`, `WANTS_DIR` (`~/.config/systemd/user/default.target.wants`), `PROFILE_MARKER`, `PROFILE_NAME_RE` (the renderer's: `^[A-Za-z0-9][A-Za-z0-9._-]*$`), `DOTFILES_LOCAL_REPO`, `OFFICIAL_MARKETPLACE`, `GENERATED_CLAUDE_ENTRIES`, `CLAUDE_OWN_ENTRIES`, `RETIRED_DIR_NAME=retired`, `MIN_GIT_VERSION_FOR_MEMORY_SYNC=2.40`, `LINK_APPLY_TIMEOUT_SECONDS=300`, `CLONE_TIMEOUT_SECONDS=300`.
- **CLAUDE.md byte budget:** 139 B of headroom. Add nothing to it in this step; document in `docs/CLAUDE_SETUP.md` and `docs/HERDR_GUIDE.md` (both already reachable).
- **Two PRs.** PR 1 is DO-894, Tasks 1–4 (rename, migration, profile, dotfiles-local row, units), branch `zvi/do-894-rename-dev-sync-to-host-sync-and-read-the-host`. PR 2 is DO-895, Tasks 5–11 (link checker, the declared-configuration rows, the sync's `--prune`), branch `zvi/do-895-add-the-declared-configuration-rows-to-host-sync`, in its own worktree. PR 1 changes `install.conf.yaml` (two unit links): that diff is shown to Zvi **before** the merge. Each PR: CI green on the HEAD sha, `rev-list --count merge-base..origin/main` = 0, title and body rewritten to the final diff, squash merge, fast-forward deploy, `./install`.
- **Commit trailer:** `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Branch names from Linear (`gitBranchName`); PR titles `DO-#### …`.

## Review Focus

1. The day dev's old `dev-sync` fast-forwards itself onto PR 1's commit and keeps running the rest of its rows from the already-parsed old program; then the next day's run through the wrapper; then a laptop `--apply` that lands inside dev's own 05:00–05:30 tick and cannot take the lock. Expected: day N ends as today; day N+1 migrates; the colliding run exits 2 having moved nothing, and dev's timer keeps firing. Task 2, rows `legacy: --apply moves the marker …`, `legacy: a run that cannot take the lock moves nothing`, `legacy: when the new timer cannot be armed the old one is left armed`.
2. A marker written by hand on a host with no dotfiles-local yet (step 7's first minute). Expected: the overlay is cloned **before** the public `./install` (which the renderer would otherwise fail, exit 2, with a marker and no overlay), the profile is read after the clone in the same run, and the host's work clones keep being fetched while the tenants are unknown. Task 3, rows `marker before the overlay: the overlay is cloned before the public ./install` and `profile named but overlay missing: the work clones row still runs`.
3. A plugin the overlay sets to `false` that is still installed. Expected: never enabled, never uninstalled, never `disable`d by the sync; not a ✗. Task 7, rows `a declared-false plugin is left alone` and `host-sync never calls plugin enable or disable`.
4. A declared link that is a regular file whose content differs from the repo (someone edited the installed copy). Expected: drift; `--apply` runs that repo's `./install`, dotbot backs the file up and relinks, and the row names the backup. Task 6, row `links: a regular file with other content is relinked and its backup named`.
5. A store directory for a tenant the host does not serve (a personal store on dev). Expected: ⚠ naming the store and its tenants, nothing removed, nothing synced by this script. Task 9, row `memory: a store for an unserved tenant is reported, not touched`.

---

## File structure

| File | Responsibility |
|---|---|
| `scripts/host-sync` | the script (`git mv` of `scripts/dev-sync`); both halves, every row |
| `scripts/dev-sync` | 12-line wrapper: `exec host-sync --host dev "$@"` unless `--here`, `--host` or `--host=` is given |
| `scripts/test-host-sync.sh` | its state table (`git mv` of `scripts/test-dev-sync.sh`) |
| `systemd/host-sync.{service,timer}` | the host's daily run; `ConditionPathExists=%h/.config/host-sync/armed` |
| `systemd/dev-sync.{service,timer}` | kept one release, unchanged (their `ExecStart` runs the wrapper) |
| `install.conf.yaml` | links the two new units beside the two old ones |
| `scripts/check-links.sh`, `scripts/test-check-links.sh` | the link checker ported from dotfiles-local, with `--root`, `--config`, `--tsv` |
| `scripts/claude-memory-sync.sh`, `scripts/test-claude-memory-sync.sh` | `fetch --prune` (step-5 follow-up O1) |
| `zsh/zshrc.conditionals.plugins` | `_ssh_shared_host` accepts either marker directory |
| `scripts/claude-oauth-store`, `scripts/claude-memory-link.sh`, `scripts/claude-settings-render.sh`, `.github/workflows/ci.yml:1281` | the sentences and comments that name `dev-sync` |
| `.github/workflows/ci.yml` | job `host-sync-test` (renamed), job `check-links-test` (new) |
| `docs/CLAUDE_SETUP.md`, `docs/HERDR_GUIDE.md`, `docs/README.md`, `CHANGELOG.md`, the spec | names, the new section, the amendments |

The host profile the script reads (private, dotfiles-local; shape only):

```json
{"tenants": ["<tenant>", "..."]}
```

Row areas, in print order, with what gates each (— means always):

| area | gate | `--check` | `--apply` adds |
|---|---|---|---|
| `dotfiles-local` (clone only) | marker | absent → ✗ | `git clone` |
| `dotfiles` | — | as today | as today (`./install` now sees the overlay) |
| `dotfiles-local` | marker | branch, fast-forward, local-edit and install-stamp rules as `dotfiles` | fast-forward, `bash ./install` |
| `profile` | — | the profile and its tenants, or why there is none | — |
| `timer` | — | H2/H3 | arm, move the marker, retire the old timer |
| `claude`, `auth`, `agent`, `herdr`, `herdr-draft` | — (`auth` skipped on a clauth host) | as today | as today |
| `settings` | marker | `claude-settings-render.sh --check` | `--apply` |
| `links` | — for `~/.dotfiles`; `~/.dotfiles-local` when present | `check-links.sh --tsv` | that repo's `./install` |
| `marketplace`, `plugin` | — | declared = the live `settings.json` | add, update, install |
| `skill` | — | `herdr --skill` vs the file; `herdr-draft skill --check` | regenerate |
| `mcp` | — (`--no-mcp`) | as today | — |
| `clone`, `clones` | skipped only when the tenants are known and exclude `quantivly` | as today | as today |
| `memory` | store table present; clones and the memory timer need known tenants | git floor; stores for served tenants present; link `--check`; sync `--status`; memory timer | clone, link `--apply`, enable the memory timer |
| `retire` | — (moves only with a marker) | stale entries counted and named | move to `retired/<stamp>/` |
| `slice`, `sessions` | — | as today | — |

---

### Task 1: Rename, wrapper, `--host`

**Files:** `git mv scripts/dev-sync scripts/host-sync`; create `scripts/dev-sync`; `git mv scripts/test-dev-sync.sh scripts/test-host-sync.sh`; modify `.github/workflows/ci.yml` (job `dev-sync-test` → `host-sync-test`, name "host-sync State Table", step runs `./scripts/test-host-sync.sh`; the comment at line 1281), `zsh/zshrc.conditionals.plugins:36-38`.

**Interfaces — Produces:** `scripts/host-sync` with the usage below; every later task adds rows to it. `scripts/test-host-sync.sh` with `SUT="$DOTFILES/scripts/host-sync"` and the fixture dirs `$H/.config/host-sync`, `$H/.local/state/host-sync`.

```
Usage (the controlling host, usually the laptop):
  host-sync --host <ssh alias> [--check]     report drift on <host>; changes nothing (default)
  host-sync --host <ssh alias> --apply       bring <host> level, then report; arms its timer
  host-sync --host <ssh alias> --print-facts print what would be sent to <host>, and exit
Usage (on the host itself; the timer's form; --here must come first):
  host-sync --here [--check|--apply] [--no-mcp]
```

- [ ] **Step 1: Rename the files and the names inside them.** In `scripts/host-sync`: the header, `usage()`, every `dev-sync:` message prefix, every `~/.local/state/dev-sync` path in a row, `STATE="$HOME/.local/state/host-sync"`, the marker paths (`MARKER_DIR="$HOME/.config/host-sync"`), `HERDR_TMP` suffix, the `settings.json.before-dev-sync` backup name, the summary line (`host-sync --apply (from the laptop: --host <alias>) fixes the ✗ rows`), and every `DEV_SYNC_*` override → `HOST_SYNC_*`. Row texts that say "on dev" become "on this host" or `$(hostname)`; "dev-sync" in a row becomes "host-sync". Do not touch what the rows check.
- [ ] **Step 2: `--host` is required.** In `laptop_main`: `host=""`; after parsing, `[[ -n "$host" ]] || { echo "host-sync: --host <ssh alias> is required (or --here on the host itself)" >&2; usage >&2; return 64; }`; validate `[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]` else 64.
- [ ] **Step 3: Write the wrapper** `scripts/dev-sync`:

```bash
#!/usr/bin/env bash
# scripts/dev-sync — kept one release as a wrapper (shared-configuration design, D8 / H10).
# `dev-sync …` is `host-sync --host dev …`; `--here` (first, as host-sync requires), `--host X`
# or `--host=X` pass through unchanged.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
case " $* " in
    *" --here "*|*" --host "*|*" --host="*) exec "$here/host-sync" "$@" ;;
    *) exec "$here/host-sync" --host dev "$@" ;;
esac
```

- [ ] **Step 4: Update the table.** `SUT`, the fixture directories, the stub `systemctl`'s `dev-sync.timer:*` show case → `host-sync.timer:*`, every needle (53 lines name `dev-sync`; after this step `grep -c 'dev-sync' scripts/test-host-sync.sh` counts only the wrapper and legacy rows). Add rows, each run with the fixture `HOME`, `HOST_SYNC_DOTFILES_REMOTE="file://$GH/quantivly/dotfiles.git"` and `HOST_SYNC_GITHUB_BASE="file://$GH"` exactly as the existing laptop-half rows (test line 761) do, so no row reaches the network or an ssh agent:
  - `host-sync with neither --host nor --here: usage (64)` — run `bash "$SUT" --check`, `RC` 64.
  - `the dev-sync wrapper runs host-sync against dev` — with `HOST_SYNC_SSH` pointing at a stub that records its first argument and exits 255, run `bash "$DOTFILES/scripts/dev-sync" --check`; the stub's log holds `dev`.
  - `the wrapper passes --here through unchanged` — `bash "$DOTFILES/scripts/dev-sync" --here --check` under the fixture env prints the header `host-sync check on`.
  - `the wrapper honours an explicit --host` and `… --host=` — the stub's log holds `other` after `dev-sync --host other --check` and after `dev-sync --host=other --check` (host-sync's parser accepts `--host=X` too; add that case to `laptop_main`).
- [ ] **Step 5: `_ssh_shared_host`** → `[[ -d "$HOME/.config/host-sync" || -d "$HOME/.config/dev-sync" ]]`, comment updated; find any existing row that pins the old directory (`grep -rn 'config/dev-sync' scripts/test-*.sh zsh/`) and add its twin for the new one.
- [ ] **Step 6: Run** `./scripts/test-host-sync.sh` — all rows pass, `EXPECTED_ROWS` = 325 + 5 (+ the Step 5 twin if one was added). Run `shellcheck -x scripts/host-sync scripts/dev-sync scripts/test-host-sync.sh`, `scripts/check-state-table-totals.sh`, `./scripts/check-claude-md.sh`.
- [ ] **Step 7: Commit** `refactor: rename dev-sync to host-sync; dev-sync stays as a wrapper`.

### Task 2: State-dir migration under the lock; the timer transition

**Files:** `scripts/host-sync` (`here_main`, `here_timer`, `move_marker_files`), `scripts/test-host-sync.sh` (stub `systemctl` keyed by unit; migration rows; `MUTATING` gains `systemctl --user stop`).

**Interfaces — Produces:** `is_armed` (an `armed` file in either marker dir), `is_disarmed` (a `disarmed` file in either), `move_marker_files` (file by file into `MARKER_DIR`, then `rmdir` of the legacy dir when empty), `here_timer` with the states below.

- [ ] **Step 1: Stub per-unit state.** In `write_stubs`, `systemctl`: `is-enabled <unit>` reads `$S/enabled-<unit>` (else `disabled`, exit 1); `is-active <unit>` reads `$S/active-<unit>` (else `inactive`, exit 3); `enable --now <unit>` writes both for `<unit>` unless `$S/enable-fails` exists; `stop <unit>` writes `inactive` for `<unit>`; `show <unit> -p NextElapseUSecRealtime` answers for `host-sync.timer` only. `new_case` seeds `enabled-host-sync.timer`/`active-host-sync.timer`, touches both unit links `$H/.config/systemd/user/{host-sync,dev-sync}.timer` and creates `$H/.config/systemd/user/default.target.wants/` (empty). Rows that previously wrote `timer-enabled`/`timer-active` (lines 237, 710, 721) are rewritten to the per-unit files. Run the table: every existing row still passes.
- [ ] **Step 2: Migration rows (failing first).** A "legacy host" fixture: `$H/.config/dev-sync/armed` instead of `host-sync/armed`, `enabled-dev-sync.timer`=enabled, `active-dev-sync.timer`=active, `$WANTS_DIR/dev-sync.timer` link present, no `host-sync` state dir, the install stamp under `$H/.local/state/dev-sync/`.
  - `legacy: --check names the move and changes nothing` — `run_level --check`: `RC` 1, `OUT` has `✗ timer          dev-sync.timer is armed; --apply moves the arming to host-sync.timer`, snapshot unchanged (both marker and state dirs still legacy).
  - `legacy: --apply without --arm is not refused` — `run_level --apply`: `RC` 0.
  - `legacy: the state dir is moved under the lock and the install stamp carried` — `$H/.local/state/host-sync/installed-head` holds the HEAD; `$H/.local/state/dev-sync` absent; `install-ran` not written.
  - `legacy: host-sync.timer is enabled with enable --now, never reenable` — calls hold `systemctl --user enable --now host-sync.timer`, no `reenable`/`disable`.
  - `legacy: the marker moves only after the new timer reads back armed` — in the calls log, `enable --now host-sync.timer` precedes the first `is-enabled host-sync.timer` that precedes `stop dev-sync.timer`; `$H/.config/host-sync/armed` exists; `$H/.config/dev-sync` absent (files moved, dir removed).
  - `legacy: dev-sync.timer is stopped and its .wants link removed` — calls hold `systemctl --user stop dev-sync.timer`; `$WANTS_DIR/dev-sync.timer` gone; `daemon-reload` called after the removal.
  - `legacy: the unit link of dev-sync.timer is left` — `$H/.config/systemd/user/dev-sync.timer` still exists.
  - `legacy: ✓ says the arming moved` — `OUT` has `✓ timer          arming moved from dev-sync.timer to host-sync.timer`.
  - `legacy: a second --apply calls nothing mutating and changes no file` — `mutations` 0 and the snapshot diff empty.
  - `legacy: a run that cannot take the lock moves nothing` — a background `flock` holds `$H/.local/state/dev-sync/lock` (the inode a rename keeps): `run_level --apply` is `RC` 2; `$H/.config/dev-sync/armed` and `$H/.local/state/dev-sync` still exist; no `enable` call.
  - `legacy: when the new timer cannot be armed the old one is left armed` — fixture without `$H/.config/systemd/user/host-sync.timer`: `OUT` has `✗ timer          host-sync.timer is not linked (./install has not run for a commit that has it); dev-sync.timer left armed`; no `stop dev-sync.timer` call; `$WANTS_DIR/dev-sync.timer` and `$H/.config/dev-sync/armed` present.
  - `legacy: an enable that fails leaves the old timer and the marker in place` — `$S/enable-fails`: same assertions, text `✗ timer          host-sync.timer could not be armed (is-enabled=…, is-active=…); dev-sync.timer left armed`.
  - `legacy: both timers enabled (half migrated): --apply finishes the move` — both enabled; after apply, `stop dev-sync.timer` called, `.wants` link gone, marker moved.
  - `legacy: a disarmed legacy host reads disarmed in --check` — `dev-sync/disarmed`, no `armed`, `dev-sync.timer` not enabled: `OUT` has `· timer          disarmed by hand`, not the "not armed … arms it" text; `RC` 0.
  - `legacy: --apply --arm on a disarmed legacy host writes no marker and moves the disarmed file` — `$H/.config/host-sync/disarmed` exists, no `armed` anywhere, no `enable`.
  - `legacy: an existing host-sync dir does not strand the legacy marker` — both dirs exist (`host-sync/` empty): after apply, `dev-sync/` is gone and `host-sync/armed` exists.
  - `unarmed host: --check is information, exit 0` — replaces `unarmed dev: --check shows the ✗`: `OUT` has `· timer          not armed on this host (no ~/.config/host-sync/armed); host-sync --host <alias> --apply from the laptop arms it`, `RC` 0.
  - `unarmed host with an enabled timer: the information row names it` — `enabled-host-sync.timer`=enabled, no marker: the `·` text ends `(is-enabled=enabled, is-active=active: a timer that fires into a skipped unit)`.
  - `armed marker, timer inactive: ✗ in --check` — `OUT` has `✗ timer          armed (marker present) but host-sync.timer is-enabled=enabled, is-active=inactive`.
  - `armed marker, timer inactive: --apply without --arm re-arms` — calls hold `enable --now host-sync.timer`; `RC` 0.
- [ ] **Step 3: Implement.** In `here_main`, apply mode: `STATE` is the new dir when it exists, else the legacy dir when that exists (lock its `lock` file), else the new dir created; take `flock -n` **first**; then, still under the lock, `[[ -d $LEGACY_STATE_DIR && ! -e $NEW_STATE ]] && mv` and point `STATE` at the new path. The arming gate reads `is_armed()`. `here_timer` states, tested in this order so a half-migrated host is finished rather than passed:
  1. `is_disarmed` (either dir) → `· disarmed by hand (…/disarmed); --apply does not re-arm it`; in apply, `move_marker_files` (so `disarmed` lands in the new dir); return.
  2. `is-enabled $LEGACY_TIMER_UNIT` = enabled → check: `✗ dev-sync.timer is armed; --apply moves the arming to host-sync.timer`; apply: `arm_timer` (below) unless `TIMER_UNIT` already reads enabled+active; **read back** `is-enabled`/`is-active` of `TIMER_UNIT`; only when both hold: `move_marker_files`, `stop $LEGACY_TIMER_UNIT`, `rm -f $WANTS_DIR/$LEGACY_TIMER_UNIT`, `daemon-reload` → `✓ arming moved from dev-sync.timer to host-sync.timer`; otherwise one of the two `✗ … dev-sync.timer left armed` rows and nothing touched.
  3. `TIMER_UNIT` enabled+active and `is_armed` → `✓ host-sync.timer armed, next run …`; in apply also `move_marker_files` when a legacy file remains.
  4. apply and (`is_armed` or `ARM=1`) → `arm_timer`: unit link present else the `✗ … is not linked` row; write `$MARKER_DIR/armed`; `daemon-reload`; `enable --now $TIMER_UNIT`; read back → `✓ host-sync.timer armed (daily)` or `✗ arming failed: is-enabled=…, is-active=…`.
  5. check and `is_armed` → `✗ armed (marker present) but host-sync.timer is-enabled=…, is-active=…`.
  6. else → the `·` information row, with `(is-enabled=…, is-active=…: a timer that fires into a skipped unit)` appended when either is not `disabled`/`linked`/`inactive`.
  `move_marker_files`: for `f in armed disarmed`: `[[ -e $LEGACY_MARKER_DIR/$f ]] && mkdir -p "$MARKER_DIR" && mv "$LEGACY_MARKER_DIR/$f" "$MARKER_DIR/$f"`; then `rmdir "$LEGACY_MARKER_DIR" 2>/dev/null || true`.
- [ ] **Step 4: Run** the table; all pass; `EXPECTED_ROWS` updated; `MUTATING` holds `systemctl --user stop`. Commit `feat(host-sync): move the state under the lock, and the arming from dev-sync only once host-sync.timer is live`.

### Task 3: The host profile, the overlay rows, the clauth skip

**Files:** `scripts/host-sync` (`read_profile`, `here_profile`, `clone_overlay`, `sync_checkout`, `here_dotfiles_local`, `laptop_facts`, `laptop_main`, `here_auth`, `here_clones`), `scripts/test-host-sync.sh`.

**Interfaces — Produces:** globals `DOTFILES_LOCAL` (`$HOME/.dotfiles-local`, set in `here_main`), `PROFILE` (name or empty), `PROFILE_FILE`, `TENANTS` (array), `TENANTS_KNOWN` (1 once the profile file was read), `PROFILE_FAULT` (text, when the marker or file is unusable); `has_tenant <name>`; `tenants_exclude <name>` (true only when `TENANTS_KNOWN` and the name is absent); `clone_overlay` (the clone branch alone, run before `here_dotfiles`); `sync_checkout LABEL DIR STAMP_NAME` (fetch, fast-forward, local-edit rule, install stamp, `bash ./install </dev/null`); facts `--dotfiles-local-sha`, `--dotfiles-local-behind` validated like their dotfiles twins.

- [ ] **Step 1: Rows (failing first).** Fixture additions in `new_case`: a bare `$GH/ZviBaratz/dotfiles-local.git` seeded with `install` (the same stub shape as dotfiles': appends `local` to a combined `$H/stub/install-order` log and records `local-install-ran`; the public stub appends `public`), `install.conf.yaml` (two declared links, used from Task 6), `hosts/p.json` = `{"tenants":["quantivly"]}`; cloned to `$H/.dotfiles-local` with its stamp `$H/.local/state/host-sync/installed-head-dotfiles-local`; marker `$H/.config/claude-host-profile` = `p`; `CLAUDE_SETTINGS_RENDER_MARKER` exported in `run` to that path.
  - `level: the profile row names the profile and its tenants` — `OUT` has `· profile        p (tenants: quantivly)`.
  - `no marker: the overlay rows are skipped` — marker removed: `OUT` has `· profile        no host profile marker (~/.config/claude-host-profile); dotfiles-local, settings, memory stores and retire are not managed here`, no `dotfiles-local` row; `RC` 0.
  - `a marker with an unusable name is a person's step` — marker `../x`: `⚠ profile        the marker holds an unusable profile name (the renderer's rule: letters, digits, dots, dashes)`; no clone attempted in `--apply`.
  - `marker names a profile dotfiles-local lacks` — `rm $H/.dotfiles-local/hosts/p.json`: `⚠ profile        no hosts/p.json in ~/.dotfiles-local`.
  - `dotfiles-local absent: --check ✗, nothing cloned` — `rm -rf $H/.dotfiles-local`: `✗ dotfiles-local not cloned (origin would be ZviBaratz/dotfiles-local)`; dir still absent; the profile row reads `· profile        p: ~/.dotfiles-local is not cloned yet, so its tenants are unknown until --apply clones it`.
  - `marker before the overlay: the overlay is cloned before the public ./install` — stale public stamp plus no overlay: after `run_level --apply`, `$H/.dotfiles-local` is a clone on `main`, and `$H/stub/install-order` reads `public` then `local` **after** a `✓ dotfiles-local cloned from ZviBaratz/dotfiles-local` row that precedes the `dotfiles` row in `OUT`.
  - `marker before the overlay: the profile is read after the clone` — same run: `OUT` has `· profile        p (tenants: quantivly)`.
  - `profile named but overlay missing: the work clones row still runs` — `--check` with no overlay: a `clone`/`clones` row is printed.
  - `profile without quantivly: the work clones row is skipped` — `hosts/p.json` = `{"tenants":["personal"]}`: no `clone`/`clones` row; `$H/quantivly` not created by `--apply`.
  - `no profile: the work clones row still runs`.
  - `dotfiles-local behind: --apply fast-forwards and reinstalls` — push a commit to its origin; `--check` ✗ `1 commits behind`; `--apply` HEAD = origin's, `local-install-ran` grows, stamp updated.
  - `dotfiles-local off main: not touched` — `⚠ dotfiles-local on 'feature', not main`.
  - `dotfiles-local with an overlapping local edit: not merged`.
  - `facts: the laptop sends dotfiles-local's main sha when it has the checkout` — `--print-facts` under a fixture `HOME` with `.dotfiles-local` on a `file://` origin and `HOST_SYNC_DOTFILES_LOCAL_REMOTE=file://…`: output holds `--dotfiles-local-sha <40 hex>`; without the checkout, it does not.
  - `a bad --dotfiles-local-sha over the wire is refused (64)`.
  - `clauth host: the auth rows do not apply` — `mkdir $H/.clauth`: `· auth           accounts are managed by clauth on this host; the long-lived-token rows do not apply`; no `claude auth` call; no other `auth` row.
- [ ] **Step 2: Implement.** `read_profile()`: marker readable → first line → `PROFILE_NAME_RE` else fault; `PROFILE_FILE="$DOTFILES_LOCAL/hosts/$PROFILE.json"`; when `$DOTFILES_LOCAL` is absent → `TENANTS_KNOWN=0` and the "not cloned yet" text; readable and `jq -e '.tenants | type == "array"'` → `mapfile TENANTS; TENANTS_KNOWN=1`; else fault. Called once before the rows and again after `clone_overlay`. Row order at the top of `here_rows`: `clone_overlay` (marker and `PROFILE` set, `$DOTFILES_LOCAL` absent: check ✗ / apply `git_net clone --quiet "$GITHUB_BASE/$DOTFILES_LOCAL_REPO.git" "$DOTFILES_LOCAL"` under `timeout $CLONE_TIMEOUT_SECONDS`, then `read_profile` again), then `here_dotfiles` = `sync_checkout dotfiles "$DOTFILES" installed-head`, then `here_dotfiles_local` = `[[ -n "$PROFILE" || -n "$PROFILE_FAULT" ]] && [[ -d "$DOTFILES_LOCAL" ]] && sync_checkout dotfiles-local "$DOTFILES_LOCAL" installed-head-dotfiles-local`, then `here_profile`. `here_clones`: `tenants_exclude quantivly && return 0`. `here_auth`: `[[ -d "$HOME/.clauth" ]] && { row info auth "…"; return; }` first. `laptop_facts`: when `$HOME/.dotfiles-local` is a checkout, `ls-remote "${HOST_SYNC_DOTFILES_LOCAL_REMOTE:-origin}" refs/heads/main` → `--dotfiles-local-sha`; `laptop_main` reads both heads in one ssh call and counts both `behind` values.
- [ ] **Step 3: Run** the table; all pass. Commit `feat(host-sync): read the host profile; clone and keep dotfiles-local level; skip the token rows where clauth rules`.

### Task 4: Units, install, docs, amendments, PR 1

**Files:** create `systemd/host-sync.service`, `systemd/host-sync.timer`; modify `install.conf.yaml:189-194`, `docs/HERDR_GUIDE.md` (19 lines), `docs/CLAUDE_SETUP.md:307`, `scripts/claude-oauth-store:139-141`, `scripts/claude-memory-link.sh:58,421`, `scripts/claude-settings-render.sh:10`, `CHANGELOG.md`, the spec (D8).

- [ ] **Step 1: Units.** `host-sync.service` = `dev-sync.service` with: Description `Keep this host's tooling and Claude Code configuration level with git (host-sync)`, `Documentation=file://%h/.dotfiles/scripts/host-sync`, `ConditionPathExists=%h/.config/host-sync/armed`, `ExecStart=%h/.dotfiles/scripts/host-sync --here --apply --no-mcp`, the header comments rewritten for "the host" (the arming paragraph names H2: the first `--apply` moves a `dev-sync` arming over, new timer first). `Slice=agents.slice` stays: a slice with no unit file is synthesised by systemd (probed 2026-11-09). `host-sync.timer` = `dev-sync.timer` renamed, same schedule. `dev-sync.{service,timer}` untouched.
- [ ] **Step 2: `install.conf.yaml`.** Add the two links after line 194 with the comment: linked everywhere, enabled only by `host-sync --apply`; `dev-sync.{service,timer}` keep their entries with a one-line note that they go in the next release. Run `./scripts/check-state-table-totals.sh`, and verify the unit the way the repo's other unit checks do: `systemd-analyze --user verify` on a copy whose `ExecStart` is sed-pointed at this worktree's `scripts/host-sync` (the real path exists only after deploy).
- [ ] **Step 3: Docs.** `HERDR_GUIDE.md`: every `dev-sync` mention → `host-sync` (`--check` and `--apply` examples carry `--host dev`; the disarming recipe uses `~/.config/host-sync/` and `host-sync.timer`; "a host with `~/.config/dev-sync`" → "`~/.config/host-sync`"). `CLAUDE_SETUP.md:307`, the link script's two comments and the renderer's one: `repo_of_url in scripts/host-sync` / `host-sync`. `claude-oauth-store`: `scripts/host-sync --host dev --check`. `CHANGELOG.md` Unreleased → Changed: the rename, the wrapper, the moved directories, the timer transition, H3. Spec D8: append amendments H1–H4, H9, H10 in the "**Amended 2026-11-09 (DO-894):**" form the spec uses (PR 2 records its four as DO-895); H1 and H4 are recorded now so PR 2 implements against them.
- [ ] **Step 4: Mutation sweep** on `scripts/host-sync` over the rows this PR added, each mutant named with its killing row first: (a) the lock taken after the state move → `legacy: a run that cannot take the lock moves nothing`; (b) `mv` of the state dir dropped → `…install stamp carried`; (c) the read-back gate before `stop`/`rm` dropped → `legacy: an enable that fails leaves…`; (d) `move_marker_files` called before the read-back → `legacy: the marker moves only after…`; (e) `rm` of the `.wants` link dropped → `dev-sync.timer is stopped…`; (f) the unarmed `·` row turned back into drift → `unarmed host: --check is information`; (g) `is_disarmed` reading the new dir only → `legacy: a disarmed legacy host reads disarmed`; (h) `tenants_exclude` treating unknown tenants as excluding → `profile named but overlay missing…`; (i) `clone_overlay` moved after `here_dotfiles` → `…cloned before the public ./install`; (j) `read_profile` not re-run after the clone → `…the profile is read after the clone`; (k) the clauth early return dropped → `clauth host…`; (l) the wrapper's `--here` passthrough dropped → `the wrapper passes --here through unchanged`; (m) `PROFILE_NAME_RE` widened to `.*` → `a marker with an unusable name…`; (n) on the test: `systemctl --user stop` removed from `MUTATING` → `legacy: a second --apply calls nothing mutating…` must go red. Record the table in the PR body.
- [ ] **Step 5: PR 1.** Push; CI green on the HEAD sha; whole-branch review (fable) with one fix pass; show the `install.conf.yaml` diff to Zvi; merge (squash, `--delete-branch`, never `--admin`); deploy (`fetch`, `merge --ff-only`, `bash ./install`); on the laptop `systemctl --user list-unit-files 'host-sync*'` shows both linked, disabled. Smoke test `scripts/host-sync --here --check --no-mcp` on the laptop: **exit 1 is expected**, the laptop being check-only; the expected rows are `· profile cilantro (tenants: quantivly, personal, toysim)`, `· timer not armed on this host…`, `· auth accounts are managed by clauth…`, `⚠ herdr-draft linked from a local checkout`, and ✗ rows that are the laptop's own state, each with the command that clears it if wanted: `dotfiles`/`dotfiles-local` `… ./install has not run for it` (no stamp on a never-applied host; leave), `marketplace quantivly: last updated N d ago` (`claude plugin marketplace update quantivly`), `clones N of M not fetched in 36h` (`git -C ~/quantivly/<x> fetch` or leave). Any ✗ outside that list is a defect. Record "Step 6, PR 1 deployed" in `audit.md` with the rows seen.

### Task 5: The public link checker

**Files:** create `scripts/check-links.sh` (ported from `~/.dotfiles-local/scripts/check-links.sh`, provenance line in the header), `scripts/test-check-links.sh` (ported from its test, plus the rows below); modify `.github/workflows/ci.yml` (job `check-links-test`; bash only, no apt step).

**Interfaces — Produces:** `scripts/check-links.sh [--quiet] [--tsv] [--root <checkout>] [--config <install.conf.yaml>]`; `REPO_ROOT` env still honoured. `--tsv` prints one line per declared entry, `<state>\t<target>\t<source>`, states `ok`, `missing`, `wrong-target`, `regular-identical`, `regular-differs`, `source-missing`, `conditional-absent`; exit 0 when no state other than `ok` and `conditional-absent` occurs, 1 otherwise, 2 when the config is unreadable or declares nothing the parser recognises (today's two FAIL exits become 2: "could not run" is never a pass and never drift). The parser is kept as is: it already recognises every one of the public manifest's 49 entries and the private one's nested `path:` shape (review probe).

- [ ] **Step 1: Port** both files; the ported table asserts its own `EXPECTED_ROWS` as `scripts/check-state-table-totals.sh` requires; add a fixture entry with `if:` (present → checked; absent → `conditional-absent`). Rows added: `--tsv prints one state per declared entry`, `--tsv: a regular file with identical content is regular-identical`, `--tsv: a regular file with other content is regular-differs`, `--config points the parser at another manifest`, `--root resolves sources against that checkout`, `an unreadable config is exit 2, not 1`, `a parser that recognises nothing is exit 2`, `the public manifest shape (a key with a nested path and if) parses`.
- [ ] **Step 2: CI job** in the memory-sync job's style.
- [ ] **Step 3: Commit** `feat: port check-links.sh to the public repo, with --tsv, --root and --config`.

### Task 6: Rows `settings` and `links`

**Files:** `scripts/host-sync` (`here_settings`, `here_links`), `scripts/test-host-sync.sh` (fixture: a stub `scripts/claude-settings-render.sh` and the REAL `scripts/check-links.sh`, both **committed into the fixture's seed repos** by `new_case` so they are tracked in the clone; two declared links per fixture repo; the fixture `install` stubs create those links, and when the target is a regular file first move it to `<target>.<stamp>.bak` as dotbot's backup does; `MUTATING` gains `claude-settings-render.sh --apply`).

- [ ] **Step 1: Rows (failing first).** Render stub: logs calls; `--check` exits `$(cat $S/render-rc)` (default 0); `--apply` exits 0 and writes `0` to `render-rc`; `--check` with `render-rc` 2 prints `claude-settings-render: settings.json is a symlink` to stderr.
  - `settings: level → ✓` — `✓ settings       settings.json renders to itself (profile p)`.
  - `settings: no marker → · and the renderer is not called`.
  - `settings: drift → ✗ in --check, --apply renders then re-checks` — `render-rc`=1: ✗ `settings.json differs from its render`; after `--apply` calls hold `claude-settings-render.sh --apply` then `--check`; ✓ `rendered (profile p)`.
  - `settings: a renderer that cannot run → ⚠ with its first line, no --apply` — `render-rc`=2.
  - `settings: a renderer that is not there → ⚠ could not run (exit 127)` — remove the stub for one case.
  - `links: level → one ✓ per repo` — `✓ links          dotfiles: 2 declared links in place` and the same for `dotfiles-local`.
  - `links: dotfiles-local absent → no dotfiles-local links row`.
  - `links: a missing link is drift; --apply runs that repo's ./install and re-checks` — `rm` one link: ✗ `dotfiles: 1 link(s) to fix: ~/.x`; after `--apply`, `install-ran` +1, ✓.
  - `links: a regular file with identical content is drift ./install fixes`.
  - `links: a regular file with other content is relinked and its backup named` — ✗ `dotfiles: ~/.x is a regular file whose content differs from the repo; ./install backs it up beside it and relinks`; after `--apply` the link is in place, a `~/.x.*.bak` exists with the old content, and the ✓ row names it.
  - `links: a source missing from the checkout is a person's step` — ⚠ naming the source; `./install` not run for it alone.
  - `links: a checker that cannot run → ⚠` — remove the fixture's `install.conf.yaml`: ⚠ `dotfiles: check-links could not run (exit 2)`; and with the checker file absent, `(exit 127)`.
  - `links: ./install runs once per repo per run even with several faults`.
- [ ] **Step 2: Implement** `here_settings` (gate `PROFILE`; `$DOTFILES/scripts/claude-settings-render.sh --check` with stderr captured through the redactor; rc map per the Global Constraint; apply = `--apply` then `--check`) and `here_links` (`for repo in dotfiles[:$DOTFILES] dotfiles-local[:$DOTFILES_LOCAL if -d]`: `$DOTFILES/scripts/check-links.sh --tsv --root "$dir" --config "$dir/install.conf.yaml"`; `fix` = missing|wrong-target|regular-identical|regular-differs, `hand` = source-missing; rows as above; apply = `(cd "$dir" && bash ./install </dev/null) >"$STATE/install-links-<repo>.log" 2>&1` then re-run; the backup name is found as the newest `<target>.*.bak` after the install).
- [ ] **Step 3: Run**; commit `feat(host-sync): settings and links rows`.

### Task 7: Row `plugin`, generalised from the live settings

**Files:** `scripts/host-sync` (`declared_plugins`, `declared_marketplaces`, `here_marketplaces`, `here_plugins`), `scripts/test-host-sync.sh` (fixture `settings.json` gains `extraKnownMarketplaces`; the `claude` stub records whether `CLAUDE_CODE_PLUGIN_PREFER_HTTPS` was `1` for each `plugin` call, by name only).

- [ ] **Step 1: Remove the twelve rows whose behaviour leaves the script** (name every one in the commit): the seven `superseded plugin:` rows (lines 604–611), the two `official linear:` rows (637–638), the two `linear-key install failing:` rows (646–647; the needle `must not end up with neither` leaves with `LINEAR_OFFICIAL`), and `disabled plugin: enabled, not reinstalled` (632; it pins `claude plugin enable`, which H4 forbids). **Re-fixture, keeping the rows:** `missing plugin: ✗ not installed` and `missing plugin: installed at USER scope` (613–618) must keep `slack@claude-plugins-official: true` in `enabledPlugins` and delete only the install. Note in the commit that the "fully drifted" fixture (384) now also prints `✗ marketplace quantivly: does not list quantivly-pr-conventions` (a declared-true plugin its marketplace lacks); its row asserts only `RC` 1 and no file change, so it stays green. Add, failing first:
  - `plugins: the declaration is settings.json` — `extra@quantivly: true`, not installed: ✗ `plugin         extra@quantivly not installed`; `--apply` calls `claude plugin install extra@quantivly --scope user`; ✓.
  - `a declared-false plugin is left alone` — `old@quantivly: false`, installed: no row for it; `installed_plugins.json` unchanged.
  - `host-sync never calls plugin enable or disable` — over the drifted fixture after `--apply`, no `claude plugin enable` or `claude plugin disable` call is logged.
  - `a plugin whose marketplace no fragment declares is a person's step` — `x@unknown: true`: ⚠ `plugin         x@unknown: marketplace unknown is declared by no settings fragment; not installed`.
  - `marketplaces come from extraKnownMarketplaces` — drop `quantivly` from `known_marketplaces.json`: ✗ `marketplace    quantivly: not added`; `--apply` calls `claude plugin marketplace add quantivly/claude-plugins --scope user`.
  - `a hand-written directory marketplace path with $HOME is expanded before it is compared` — (the renderer already expands it; this guards a hand-edited file) ✓ against the known location.
  - `every claude plugin call carries CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1`.
  - The marketplace-stale and linear-key-version rows keep passing unchanged.
- [ ] **Step 2: Implement.** `declared_plugins()` = `jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$SETTINGS"`; `declared_marketplaces()` = `OFFICIAL_MARKETPLACE` plus `jq -r '.extraKnownMarketplaces // {} | to_entries[] | "\(.key)=\(if .value.source.source == "directory" then .value.source.path else .value.source.repo end)"'`, with `$HOME`, `${HOME}` and a leading `~` in a path expanded. `here_marketplaces` iterates that list with `market_why` unchanged except that "lists the plugin" is asked for the declared plugins of that marketplace. `here_plugins`: no `$SETTINGS` → ⚠ as today; for each declared plugin: marketplace undeclared → ⚠; installed (user scope) → ✓ (linear-key's version rule stays); else check ✗ / apply `install`. `claude_plugin()` exports `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` for its child. Delete `PLUGINS_ON`, `PLUGINS_SUPERSEDED`, `LINEAR_OFFICIAL`, `MARKETPLACES`, the `settings.json.before-*` backup.
- [ ] **Step 3: Run**; `EXPECTED_ROWS` −12 + 7; commit `feat(host-sync): plugins and marketplaces are whatever the live settings declare` with the PR body paragraph on dev's change (H1).

### Task 8: Row `skill` (generated skills)

**Files:** `scripts/host-sync` (`here_skills`; the regeneration leaves `here_herdr`), `scripts/test-host-sync.sh` (stub `herdr plugin list … --json` gains `plugin_root`; a stub `$H/stub/draft-root/bin/herdr-draft` with `skill` and `skill --check <path>`: 0 when the file equals what it prints, 1 otherwise (a missing file included), 2 when `$S/draft-skill-cannot-answer` exists; `MUTATING` gains `herdr-draft skill$`).

- [ ] **Step 1: Rows (failing first):** `skill: herdr skill current → ✓` (`✓ skill          herdr skill current (herdr 0.9.1)`); `skill: a herdr skill that differs is drift; --apply regenerates it`; `skill: an empty herdr --skill never replaces the file` (existing needle, now in this row's case); `skill: a SKILL.md that is a directory is a person's step`; `skill: spawn current → ✓`; `skill: a stale spawn skill is drift; --apply regenerates it with herdr-draft skill`; `skill: spawn is created where none exists` (no `skills/spawn` dir: after apply it holds the stub's output); `skill: herdr-draft that cannot answer → ⚠`; `skill: no herdr-draft plugin → · and no spawn row`; the existing `older herdr: the agent skill is regenerated` keeps passing (now by this row, later in the same run).
- [ ] **Step 2: Implement.** herdr: `want="$("$HERDR" --skill 2>/dev/null)"`; empty → ⚠; `cmp -s <(printf '%s\n' "$want") "$file"` → ✓; else check ✗ / apply `mkdir -p`, write tmp, `mv` into place, ✓. spawn: `root="$("$HERDR" plugin list --plugin "$DRAFT_ID" --json | jq -r '.result.plugins[0].plugin_root // empty')"`; `bin="$root/bin/herdr-draft"`; not executable → `·`; `"$bin" skill --check "$file"` rc 0 ✓ / 1 ✗ (apply: `mkdir -p "$(dirname "$file")"`, `"$bin" skill >tmp`, non-empty, `mv`, re-check) / 2 ⚠ with its first line / other → ⚠ could not run. Remove the SKILL.md write from `here_herdr`.
- [ ] **Step 3: Run**; commit `feat(host-sync): generated skills (herdr, spawn) are regenerated from this host's binaries`.

### Task 9: Row `memory`, and the sync's `fetch --prune`

**Files:** `scripts/host-sync` (`here_memory`), `scripts/test-host-sync.sh` (fixture store table under `$H/.dotfiles-local/claude/memory-stores.json`, stubs `claude-memory-link.sh` and `claude-memory-sync.sh` committed into the fixture's seed repo, bare store remotes under `$GH`, a served store `alpha` cloned in `new_case` with `enabled-claude-memory-sync.timer`/`active-…` seeded so the level fixture stays level; a `git` wrapper first on the fixture PATH that logs `clone` to the calls file and execs the real git; `MUTATING` gains `claude-memory-link.sh --apply` and `git clone`); `scripts/claude-memory-sync.sh:1158` (`fetch --prune`), `scripts/test-claude-memory-sync.sh`.

- [ ] **Step 1: Rows (failing first).** Fixture: stores `alpha` (tenants `["quantivly"]`, remote `file://$GH/example-org/mem-alpha.git`) and `beta` (`["personal"]`); profile tenants `["quantivly"]`; `CLAUDE_MEMORY_STORES_ROOT=$H/.local/share/claude-memory` exported in `run`; link stub: `--check` exits `$S/link-rc` (default 0) printing `claude-memory-link: 3 linked, 0 to fix, 0 unmapped, 0 without a store` (or the counts `$S/link-summary` holds), `--apply` writes `0`; sync stub: `--status` prints `$S/status-lines` (default `alpha\tok\tlast synced 4 min ago`).
  - `memory: git older than 2.40 is a person's step` — the `git` wrapper printing `git version 2.39.2` for `--version` in this case: `⚠ memory         git 2.39.2 is older than 2.40; the memory sync needs --attr-source: upgrade git`.
  - `memory: no store table → · and nothing else`.
  - `memory: tenants unknown → · store checkouts not judged, nothing cloned`.
  - `memory: a served store that is not checked out is drift; --apply clones it` — `rm -rf $STORES_ROOT/alpha`: ✗ `store alpha not checked out (example-org/mem-alpha)`; after apply, the dir is a clone on the remote's default branch with `origin` equal to the table's `remote` string byte for byte; ✓ `store alpha cloned`.
  - `memory: a remote that is not under the GitHub base is not cloned` — table remote `ssh://x/y.git`: ⚠ naming the store, no clone.
  - `memory: a store for an unserved tenant is reported, not touched` — create `$STORES_ROOT/beta` as a clone: ⚠ `store beta is checked out here but serves no tenant of profile p (its tenants: personal); remove it by hand`; still present after `--apply`.
  - `memory: linked → ✓ with the link script's summary`; `memory: unmapped or store-less keys in the summary → ⚠ even at exit 0`; `memory: links to fix → ✗; --apply runs claude-memory-link.sh --apply and re-checks`; `memory: a link script that cannot run → ⚠`.
  - `memory: status ok → ✓`, `status warn → ⚠ carrying the word warn`, `status bad → ⚠ carrying the word bad` (`⚠ memory         store alpha: bad: never synced; …`); `status that cannot run → ⚠`.
  - `memory: the memory timer is armed by --apply once a served store is checked out` — `enabled-claude-memory-sync.timer` removed: ✗ `claude-memory-sync.timer not armed`; after apply calls hold `enable --now claude-memory-sync.timer`, no `reenable`; ✓.
  - `memory: no served store checked out → no memory timer row`.
  - `memory: --check clones nothing and arms nothing` — `mutations` 0 and no `git clone` logged.
  - In `test-claude-memory-sync.sh`: `fetch carries --prune` (the logged fetch call's arguments) and `a remote branch deleted upstream disappears from refs/remotes after a run` (seed `origin/other` in a bare remote, fetch once, delete it upstream, `--apply`, `rev-parse -q --verify refs/remotes/origin/other` fails).
- [ ] **Step 2: Implement** `here_memory` in that order: git floor (`ver_ge "$(git --version | awk '{print $3}')" "$MIN_GIT_VERSION_FOR_MEMORY_SYNC"`); table `$DOTFILES_LOCAL/claude/memory-stores.json` readable else `·`; stores via `jq -r '.stores | to_entries[] | [.key, .value.remote, (.value.tenants | join(","))] | @tsv'`; `serves` needs `TENANTS_KNOWN` (else the `·` row); clone with `git_net clone --quiet "$remote" "$dir"` (the table's string verbatim) under `timeout $CLONE_TIMEOUT_SECONDS`, accepted only when it is `$GITHUB_BASE/<owner>/<repo>[.git]` with both parts matching `SAFE_REPO_RE`'s halves; link script rc map with apply under `timeout $LINK_APPLY_TIMEOUT_SECONDS`, the summary line's four counts parsed and the two non-exit counts turned into ⚠; status lines parsed with `IFS=$'\t'`, level word carried into the text; memory timer: when at least one served store is checked out and `is-enabled`≠enabled or `is-active`≠active → ✗ / apply `daemon-reload; enable --now`, read back. In `claude-memory-sync.sh`'s `fetch_origin`, add `--prune` after `--quiet`.
- [ ] **Step 3: Run** both tables; commit `feat(host-sync): memory rows — git floor, store checkouts, links, sync status, the memory timer; the sync prunes on fetch`.

### Task 10: Row `retire`

**Files:** `scripts/host-sync` (`here_retire`, `classify_claude_entry`), `scripts/test-host-sync.sh`.

- [ ] **Step 1: Rows (failing first).** Fixture under `$H/.claude`: `skills/rabota → $H/.dotfiles/claude/skills/rabota` (declared; create the source), `skills/zvi-voice → $H/.dotfiles-local/claude/skills/zvi-voice` (declared), `skills/herdr/` (generated), `skills/spawn/` (generated), `skills/synced/`, `skills/.trash/`, `skills/.cache/` (own), `skills/review-pr/` (stale dir), `hooks/herdr-agent-state.sh` (generated), `hooks/a.sh → $H/.dotfiles/claude/hooks/a.sh` (declared), `hooks/__pycache__/` (stale), `hooks/gone.sh → $H/.dotfiles/claude/hooks/missing.sh` (dangling: stale), `agents/x.md` (stale).
  - `retire: nothing stale → ✓` (fixture without the four): `✓ retire         no stale skill, hook or agent under ~/.claude`.
  - `retire: stale entries are counted and named in --check` — `✗ retire         4 stale entries under ~/.claude: agents/x.md, hooks/__pycache__, hooks/gone.sh, skills/review-pr; --apply moves them to ~/.local/state/host-sync/retired/<stamp>/`; nothing moved.
  - `retire: --apply moves exactly the stale ones, keeping their paths` — the four exist under `$STATE/retired/<stamp>/<kind>/<name>`; the declared, generated and own entries are untouched (snapshot minus the four is unchanged); ✓ `4 entries moved to …`.
  - `retire: nothing is deleted` — the moved regular file's content is intact.
  - `retire: a checkout reached through a symlink still counts as declared` — `$H/.dotfiles` replaced by a symlink to the real clone dir for one case: the `rabota` link stays.
  - `retire: without a profile marker, --apply moves nothing and ⚠ says why` — `⚠ retire         4 stale entries under ~/.claude (…); no host profile here, so --apply leaves them`.
  - `retire: a second --apply is clean` — `mutations` 0, snapshot unchanged.
- [ ] **Step 2: Implement.** `classify_claude_entry KIND NAME` → `declared|generated|own|stale`: `GENERATED_CLAUDE_ENTRIES=(skills/herdr skills/spawn hooks/herdr-agent-state.sh)`, `CLAUDE_OWN_ENTRIES=(skills/synced)` plus any `skills/.*`; a symlink is declared when `readlink -f` resolves to an existing path with prefix `$(readlink -f "$DOTFILES")/` or `$(readlink -f "$DOTFILES_LOCAL")/`. `here_retire` walks `skills hooks agents` (dot-entries included, `agents` may be absent); apply with `PROFILE` set: `stamp=$(date -u +%Y%m%dT%H%M%SZ)`, `mkdir -p "$STATE/$RETIRED_DIR_NAME/$stamp/$kind"`, `mv` each.
- [ ] **Step 3: Run**; commit `feat(host-sync): stale skills, hooks and agents are moved aside on a host with a profile`.

### Task 11: Docs, amendments, sweep, PR 2

**Files:** `docs/CLAUDE_SETUP.md` (new section "Keeping a host level (DO-895)" after "Memory stores": what the script is, the two forms, the row table above with gates, the arming and the transition, the git ≥ 2.40 floor (N2), the retire rule and where moved entries go, dotbot's backup as the link safety net, what a run never does), `docs/README.md:42` (add `host-sync`), `CHANGELOG.md`, the spec (H5–H8 under D8; the D7 sentence "the memory repo synced within the last hour" now points at `--status` and the table's threshold).

- [ ] **Step 1: Write** the section and the index line; `./scripts/check-claude-md.sh` passes (docs reachability; no CLAUDE.md change).
- [ ] **Step 2: Mutation sweep** over PR 2's rows, killing row named first: (a) `here_settings` apply branch calls `--check` only → `settings: drift…re-checks`; (b) `regular-differs` dropped from `fix` → `links: a regular file with other content…`; (c) `select(.value == true)` → `select(.value != null)` → `a declared-false plugin is left alone`; (d) `PREFER_HTTPS` export dropped → its row; (e) `cmp` inverted in the herdr skill → `skill: herdr skill current → ✓`; (f) `mkdir -p` dropped before the spawn `mv` → `skill: spawn is created where none exists`; (g) `serves` check dropped → `memory: a store for an unserved tenant…`; (h) remote shape check dropped → `…is not cloned`; (i) `ver_ge` arguments swapped → `memory: git older than 2.40…`; (j) the summary's non-exit counts ignored → `memory: unmapped or store-less keys…`; (k) `classify` treating a dangling link as declared → `retire: stale entries are counted…`; (l) the marker gate on `mv` dropped → `retire: without a profile marker…`; (m) `--prune` dropped → both sync rows; (n) on the test: the new `MUTATING` alternatives removed → the second-apply rows go red. Record in the PR body.
- [ ] **Step 3: PR 2.** Same gates as PR 1 (no `install.conf.yaml` change expected; if the diff touches it, show it). After deploy, the laptop smoke test again expects exit 1 with the Task 4 list plus: ✓ `settings`, both `links` rows, every `plugin`, `memory` (four rows) and `retire`; one new real ✗, the laptop's herdr skill differing from `herdr --skill` (53 lines on 2026-11-09; the laptop is not armed, so clear it by hand with `scripts/herdr-claude-wire.sh` and re-run to see the row go ✓). Then `scripts/host-sync --host dev --check` from the laptop (read-only on dev; `dev-link-doctor` first): the legacy rows plus `· profile no host profile marker…` and `⚠ links … check-links could not run (exit 127)` until dev has fast-forwarded; no ✗ it did not print before PR 1 except the timer move if dev's own tick has not run yet. Record "Step 6 deployed" in `audit.md`; copy the SDD workspace to `sdd-step6/`.

---

## Calls made here (check these while reading)

- Two PRs, not one: the rename plus transition is reviewable as a behaviour-preserving change with its migration rows; the eight new rows of configuration are a second review.
- The profile marker gates the overlay-dependent rows (H1); the plugin row reads the live settings everywhere, and the plan says what that changes on dev rather than claiming nothing changes.
- The timer move is ordered for failure: lock, state, new timer, read-back, and only then the marker and the old timer. Every abort leaves a host with a firing timer.
- The overlay is cloned before the public `./install`, because that install renders settings and the renderer needs the overlay once a marker exists.
- The clones made by `--apply` (dotfiles-local, the stores) use the host's own git credentials, not `gh-route`: every host `--apply` runs on has one GitHub account, and the laptop (the multi-account host) is check-only.
- `--apply` arms `claude-memory-sync.timer` on an armed host with a served store (H6): one arming decision per host, not two.
- Stale is a structural rule (H5), not the audit's name list, and `--apply` moves rather than deletes.
- Dotbot's backup is the safety net for a hand-replaced link (H8); the row names the backup instead of refusing, because the checkout rows run `./install` earlier in the same run anyway.
- The auth rows keep dev's semantics everywhere except a clauth host (H9); sol-build's method is step 8's decision and may change their text then.
- D5's weekly plugin update is not built here; H4 says so and step 10 carries it.
- The link checker is ported rather than called from dotfiles-local, so a host without the private repo still checks the public one; the private copy is retired in step 7's dotfiles-local PR.

## Carried forward (not this step)

- **Step 7 (dev), in this order:** grant `zvi-quantivly` read access to dotfiles-local **before** writing the marker (with a marker and no overlay every tick's public `./install` fails on the renderer until the clone succeeds); gate dotfiles-local's tenant-root links (`~/toysim/CLAUDE.md`, `~/Projects/CLAUDE.md`) with `if:` on the profile's tenants before dev installs it (dotbot's `create: true` would otherwise create `~/toysim` on dev); in that same dotfiles-local PR, replace its `scripts/check-links.sh` with a call to the public one and drop its test (H8); write the marker `dev` by hand; record that dotbot replacing dev's hand-made `~/.claude/CLAUDE.md` with the overlay's link (audit §1) is deliberate; confirm `scripts/gh-route ~/.local/share/claude-memory/work` on dev answers a route whose token file exists (or `default`) before the memory timer's first push; the first `--apply` installs ~19 plugins (the unit's 30-minute cap); regenerate dev's user-specific auto-mode half (audit S6).
- **Step 8 (sol-build):** the token rows' advice on a `/login` host; `agents.slice` caps there; a settings file with no `extraKnownMarketplaces` declares no marketplaces until rendered.
- **Step 10:** remove `scripts/dev-sync`, `systemd/dev-sync.*`, their `install.conf.yaml` lines and `_ssh_shared_host`'s legacy directory; prune the then-dangling unit links by hand (dotbot's `clean:` does not enter `~/.config/systemd/user`); D5's weekly update of marketplace plugins; D9's remaining doctor rows (links, skills, plugins) or a doctor line that points at `host-sync --here --check`; the spec's D2 `.toml`, D4 "prints the diff" and hook-key wording; the N1 `symbolic-ref` text.
