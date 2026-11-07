# Claude Memory Stores (program step 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revision 2, 2026-11-06.** Revised after an independent review (3 Critical, 12 Important) and a hand-run pilot. This file holds the public code, Tasks 1–7. The controller's runbook (the private store table, the laptop migration, remotes and arming) is a separate, private file and is not committed to this repo.

**Goal:** Give Claude Code's auto-memory a git-backed home keyed by repo identity: a script that makes each live `memory/` directory a symlink into a store checkout, and a script that syncs a store with its remote in both directions on a timer, without ever losing a write or pushing a credential.

**Architecture:** `scripts/claude-memory-link.sh` maps a Claude project key to a store directory and swaps a real `memory/` directory for a symlink, merging its content in afterwards and resumably. `scripts/claude-memory-sync.sh` commits a store, withholds files that carry a credential shape, merges the remote (never rebases: live sessions use the working tree) and pushes, keeping both copies on a conflict. Which stores exist, their remotes, and which directories count is data read from `~/.dotfiles-local/claude/memory-stores.json`; with no such file both scripts do nothing.

**Tech Stack:** bash, jq, git, the existing zsh helpers `scripts/tenant-route` and `scripts/gh-route`, `scripts/redact-secrets.sh`, systemd user units, the repo's hermetic state tables.

**Spec:** `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md`, sections D7 (memory), D9 (doctor), D12 (what stays per host).

## Global Constraints

- **Spec amendments, recorded in the spec by Task 1 before any code** (this plan amends D7):
  - **(M1) Stores are a table, not one per tenant.** `memory-stores.json` names each store, its `remote` and the `tenants` it holds. A store is checked out at `~/.local/share/claude-memory/<store>`. A key maps to the store whose `tenants` holds the tenant `scripts/tenant-route <dir>` answers.
  - **(M2) Store-relative directory.** A checkout with an `origin`: `repos/<owner>/<repo>`, lowercased, by the rule of `repo_of_url` in `scripts/dev-sync`. A directory with no `.git`, or a repo with no `origin`: `dirs/<slug>`, where slug is the path relative to `$HOME` with `/` → `-`, lowercased, and `home` for `$HOME` itself.
  - **(M3) Keys.** The project key of a path is the path with every character outside `[A-Za-z0-9]` replaced by `-` (`/home/u/.dotfiles` → `-home-u--dotfiles`). This reproduces every live key on the laptop that still resolves to a directory; no directory there shows what `_` becomes, so that case is unverified. A worktree of an ordinary repo has no key of its own: Claude Code keys it by the main checkout. A submodule has **two** keys: its own path (sessions started in it), and its git dir `<super>/.git/modules/<name>` (sessions started in a worktree *of* the submodule, whose common dir is that git dir). Both link to one store directory.
  - **(M4) Conflict copies** are named by inserting `.conflict-<host>` before the final extension (`x.md` → `x.conflict-<host>.md`; no extension: appended), not D7's `<name>.<host>.md`, so a glob finds them without a host list. An existing copy with a different body is never overwritten: the next free `.conflict-<host>.2`, `.3`, … is used.
  - **(M5) What gets a link.** A candidate is linked when it has a real `memory/` directory, **or** when its mapped store directory already holds a file (memory another host wrote). Nothing is created for a checkout with neither.
  - **(M6) The secret gate withholds files, it does not refuse the commit.** A file whose content changes under the redactor's shape rules is left uncommitted and named; the other files sync.
  - **(M7) Auth on a host with more than one GitHub account reads the routed token file.** D7 and the answer recorded as Q4 say "keyring via gh, no token on disk". The keyring is keyed by host and cannot choose an account (`docs/GH_ACCOUNT_ROUTING.md`), so the sync asks `scripts/gh-route` and reads the shell's existing token cache file, as the `rabota schedule` tick does. No new token file is created. **This reverses a recorded answer and needs Zvi's confirmation before Task 6.**
  - **(M8) Merge, never rebase.** D7 says `pull --rebase`. A rebase removes every unpushed file from the working tree while it replays, and a session writing in that window stops it in a state `--abort` cannot leave (probed). The sync integrates with one `git merge`.
- **The symlink bet is tested** (pilot, Claude Code 2.1.319, 2026-11-06): with `memory` a symlink to a directory outside `~/.claude`, the index loads at session start, and Write, Read and Edit succeed headlessly in `auto` mode with no `Refusing to write into symlinked directory`. In `default` mode a memory write asks, as it does today.
- **Never lose a write.** Neither script deletes or overwrites a memory file. The only content changes are the line union of an index file and a conflict copy written beside the original. A replaced real directory is renamed to `memory.replaced-<UTC yyyymmddThhmmssZ>` beside the link and never pruned.
- **The link step is resumable.** A replaced directory counts as merged only once it holds the marker file `.merged-into-store`, written after its last file is handled, and while it holds no regular file newer than that marker. Any run finishes every unmarked replaced directory first, and `--check` reports one as a failure.
- **Act only where configured.** No `memory-stores.json`: exit 0, one note line, nothing touched. A key whose store is not checked out on this host is left alone.
- **A store pushes only to its own remote.** Every sync run compares `git remote get-url origin` with the table's `remote` for that store and refuses (could-not-run) on a difference.
- **No ignore rule decides what is memory.** The sync stages with `git add -A -f`, with a pathspec that excludes the link script's temporaries at every depth (`:(exclude,glob)**/.*.link-partial`), and holding `<state dir>/link.lock` — the link script's lock — from stage to commit, so a copy not yet verified whole is never committed and an index mid-write never staged. `git add -A` skips ignored paths silently, and a global ignore file, `.git/info/exclude` and a nested `.gitignore` all apply otherwise (probed).
- **Exit codes, both scripts:** `0` ok · `1` attention on `--check` and `--scan` only · `2` could not run · `64` usage. `--apply` exits `0` or `2`: a withheld file, a conflict copy, a rejected push, a missing token or an unreachable remote is a status the doctor shows, not a failed unit.
- **No credential is printed, written or put in argv.** The sync reads a token only from the file `scripts/gh-route` names, exports it to the one git child that needs it, and uses an inline credential helper that answers only the `get` operation, from that variable, and fails when the variable is empty. A withheld file is named; its lines are never printed. Any git stderr kept in a status file passes through `scripts/redact-secrets.sh` first.
- **Overrides for tests and other hosts:** `CLAUDE_MEMORY_PROJECTS_DIR` (default `~/.claude/projects`), `CLAUDE_MEMORY_STORES_ROOT` (`~/.local/share/claude-memory`), `CLAUDE_MEMORY_CONFIG` (`~/.dotfiles-local/claude/memory-stores.json`), `CLAUDE_MEMORY_STATE_DIR` (`~/.local/state/claude-memory-sync`), `CLAUDE_MEMORY_HOST` (`hostname -s`), `CLAUDE_MEMORY_TENANT_ROUTE` and `CLAUDE_MEMORY_GH_ROUTE` (the sibling `scripts/tenant-route` and `scripts/gh-route`).
- **State-table rules** (CLAUDE.md "CI/CD Testing"): hermetic under `mktemp -d` with a fixture `HOME`; remotes are local bare repos, no network; `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_SYSTEM` pointed at fixture files; exit 2 on could-not-run; `EXPECTED_ROWS` compared; every needle unique to its rule and checked against the pass path; a mutation sweep before merge, each mutant with its expected killing row named before it is run, the kill list in the commit message; no GNU-only awk or grep extensions (`grep` is a ugrep shim, `awk` is mawk).
- **Tests never touch the real stores:** every row sets all the overrides. No row runs against `~/.claude/projects` or `~/.local/share/claude-memory`.
- **Fixtures use invented names.** Tenants `alpha` and `beta`, owners such as `example-org`. No real tenant, repo or host name beyond what this file already shows goes into a fixture, a doc or a commit message.
- **Names explicit; literals with a role as named constants** (`REPLACED_DIR_INFIX`, `MERGED_MARKER_NAME`, `CONFLICT_INFIX`, `INDEX_FILE_NAME`, `NETWORK_TIMEOUT_SECONDS`, `STALE_AFTER_MINUTES_DEFAULT`).
- **CLAUDE.md byte budget:** 154 B of headroom. Add nothing to it. Document in `docs/CLAUDE_SETUP.md` (new section "Memory stores") with one cross-reference line in `docs/CLAUDE_ACCOUNTS.md`.
- **Never read** `~/.zshrc.local`, `~/.gitconfig.local`, any `.credentials.json` or `.claude.json`; never run `env` or `printenv`.
- **Two PRs.** PR 1 is Tasks 1–4 (link, the redactor flag, the readers). PR 2 is Tasks 5–7 (sync, units). PR 2 changes `install.conf.yaml`: that diff is shown to Zvi **before** the merge, as the standing authorization requires.
- **Commit trailer:** `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Branch names from Linear (`gitBranchName`).

## Review Focus

1. A session writes a memory file while its directory is being linked. Expected: the write survives. The swap is a rename then a symlink, and the merge reads the renamed directory afterwards (Task 2, rows `apply: a file written just before the rename is still merged` and `apply: a memory directory recreated before the link is merged too`).
2. A link run killed between the symlink and the end of the merge. Expected: `--check` exits 1 naming the key, and the next `--apply` finishes the merge (Task 2, rows `resume:*`).
3. A store left with `MERGE_HEAD` by a killed run. Expected: exit 2 naming the state, never a reset (Task 6, row `apply: a merge in progress is could-not-run`).
4. A file that carries a credential shape. Expected: it stays uncommitted, the rest sync, the value appears in no output and in no commit, and the next run names it again (Task 5, rows `gate:*`).
5. Two hosts add a file of the same name with different bodies in one interval. Expected: the remote's keeps the name, the local one becomes the conflict copy, and the index holds both lines (Task 6, row `integrate: both added`).

---

## File structure

| File | Responsibility |
|---|---|
| `scripts/claude-memory-link.sh` | key → store directory; `--list`, `--check`, `--apply [--dry-run] [--only <key>]` |
| `scripts/test-claude-memory-link.sh` | its state table |
| `scripts/redact-secrets.sh` | gains `--shapes-only` |
| `scripts/claude-memory-sync.sh` | per store: gate, commit, merge, push; `--check`, `--apply`, `--scan`, `--status` |
| `scripts/test-claude-memory-sync.sh` | its state table |
| `systemd/claude-memory-sync.{service,timer}` | the tick; linked by `./install`, armed by hand |
| `zsh/functions/claude.sh`, `scripts/test-claude-doctor.sh` | "Memory stores" doctor section |
| `scripts/test-claude-config-audit.sh` | one row pinning that a symlinked `memory` is collected by content |

The store table the scripts read (`memory-stores.json`), by shape:

```json
{
  "stores": {"<store>": {"remote": "https://github.com/<owner>/<repo>.git", "tenants": ["<tenant>"]}},
  "checkout_globs": ["<path relative to $HOME, may hold *>"],
  "plain_dirs": ["<path relative to $HOME; the empty string is $HOME>"],
  "stale_after_minutes": {"default": 60, "<host>": 120}
}
```

---

### Task 1: Link script, read-only half

**Files:** Create `scripts/claude-memory-link.sh`, `scripts/test-claude-memory-link.sh`. Modify the spec (amendments M1–M8 under D7).

**Interfaces — Produces:**
- `claude-memory-link.sh --list` prints TSV, one row per listed key: `key<TAB>state<TAB>store<TAB>store-relative dir<TAB>source dir`.
- `claude-memory-link.sh --check` (the default) prints every row that is not `LINKED` or `NO-STORE`, then `claude-memory-link: <n> linked, <n> to fix, <n> unmapped, <n> without a store` (the last: `NO-STORE` keys whose `memory` is a real directory holding a file). Exit 1 when any `REAL-DIR`, `MISSING`, `DANGLING`, `PENDING-MERGE` or `WRONG-LINK` exists. `UNMAPPED` alone is exit 0, and its rows are still printed.
- Functions later tasks use: `project_key_of_path PATH`, `store_dir_of_candidate DIR` (prints `<store>/<relative dir>`), `load_store_table`.

States:

| state | meaning |
|---|---|
| `LINKED` | `memory` is a symlink to the mapped store directory, which exists, and no unmarked replaced directory remains |
| `REAL-DIR` | `memory` is a real directory, the key is mapped, the store is checked out |
| `MISSING` | no `memory` entry, and the mapped store directory holds a file (M5) |
| `DANGLING` | the right symlink, but its target directory does not exist |
| `PENDING-MERGE` | a `memory.replaced-*` directory exists without the marker, or holding a regular file newer than it |
| `WRONG-LINK` | `memory` is a symlink to anywhere else |
| `NO-STORE` | mapped, but that store is not checked out on this host |
| `UNMAPPED` | a real `memory` directory holding a file, under a key no candidate claims |

Candidates, deduplicated by key:
1. every directory matching a `checkout_globs` entry that holds `.git`, and every submodule of it, recursively (`git submodule status --recursive`);
2. every `plain_dirs` entry.

A `.git` **file** is resolved through its `gitdir:` line, which may be relative to the checkout: a path ending `/.git/worktrees/<n>` is a worktree of an ordinary repo and is skipped; `<super>/.git/modules/<name>` (the name may hold `/`) is a submodule and yields its second key; `<super>/.git/modules/<name>/worktrees/<n>` is a worktree of a submodule and is skipped.

- [ ] **Step 1: Record the amendments** M1–M8 in the spec under D7, as the step-4 amendments were recorded under D4. M7 is recorded as awaiting confirmation.
- [ ] **Step 2: Write the failing rows** (fixture `HOME`; checkouts made by `git init` and `git remote add origin`; a stub `tenant-route` named by `CLAUDE_MEMORY_TENANT_ROUTE`):
  - `key: dots and slashes become dashes`
  - `map: origin owner and repo are lowercased` (`git@github.com:Example-Org/Hub.git`) → `<store>/repos/example-org/hub`
  - `map: a repo with no origin is a dirs entry`, `map: home itself is dirs/home`
  - `map: a submodule yields two keys, one directory`
  - `map: a relative gitdir is resolved from the checkout`
  - `map: a submodule name with a slash keeps it in the git-dir key`
  - `map: a worktree .git file is skipped`, `map: a worktree of a submodule is skipped`
  - `map: a nested submodule is a candidate`
  - `list:` one row per state, eight rows
  - `list: an empty unclaimed directory is not listed`
  - `check: exit 1` for each of the five failing states, one row each
  - `check: UNMAPPED alone is exit 0 and its row is printed`
  - `check: all linked is exit 0 with only the summary line`
  - `config: absent is exit 0 with the note and no other output`
  - `config: not a JSON object is exit 2`, `config: a tenant no store lists is exit 2 naming the directory`
  - `tenant-route: a non-zero exit is exit 2 naming the directory`
- [ ] **Step 3: Run** `bash scripts/test-claude-memory-link.sh`. Expected: every row FAILS on the missing script or verb, not on a fixture error.
- [ ] **Step 4: Implement** the read-only half. Paths are handled NUL-terminated throughout.
- [ ] **Step 5: Run the table.** Expected: all rows pass, `EXPECTED_ROWS` matches.
- [ ] **Step 6: Commit** (`feat(memory): map Claude project keys to store directories (DO-…)`).

### Task 2: Link script, `--apply`

**Files:** Modify `scripts/claude-memory-link.sh`, `scripts/test-claude-memory-link.sh`.

**Interfaces — Consumes:** Task 1's functions. **Produces:** `claude-memory-link.sh --apply [--dry-run] [--only <key>]`. One line per key acted on: `linked <key> -> <store dir> (copied <n>, identical <n>, kept-both <n>)`. `--dry-run` prints the same lines and changes nothing. Exit 0, or 2 on could-not-run. Holds an `flock` on `<state dir>/link.lock`; a second run waits for it.

The algorithm (the tests do not determine the order, and the order is the safety argument):

```
for every key:   finish first — merge each memory.replaced-* that lacks .merged-into-store   (step 4)
REAL-DIR:
  1. mkdir -p the store directory.
  2. rename  <projects>/<key>/memory  ->  <projects>/<key>/memory.replaced-<UTC ts>     (same parent: atomic)
  3. ln -s -T <store directory> <projects>/<key>/memory     (-T: never create the link INSIDE a directory)
     if a real `memory` exists again (a writer recreated it): rename it to memory.replaced-<ts>.NNN
     and retry step 3, at most 3 times; on giving up exit 2 (the replaced directories stay unmarked)
  4. merge each unmarked replaced directory into the store directory, recursively, every file:
       absent in the store            -> copy with cp -p
       byte-identical                 -> nothing
       MEMORY.md or INDEX_*.md differ -> the store's lines, then the lines only the replaced copy has
       any other file differs         -> the replaced file becomes the conflict copy (M4)
     then write .merged-into-store into that replaced directory
MISSING:   mkdir -p <projects>/<key>;  ln -s -T <store directory> <projects>/<key>/memory
DANGLING:  mkdir -p the store directory
WRONG-LINK, NO-STORE, UNMAPPED: never touched
```

- [ ] **Step 1: Write the failing rows:**
  - `apply: a real directory becomes a link and every file is in the store`
  - `apply: a copied file keeps its mtime and mode`
  - `apply: identical files are not copied` (the store file's mtime is unchanged)
  - `apply: a differing topic file becomes a conflict copy and the store's copy is untouched`
  - `apply: an existing conflict copy with another body is kept, and the new one is numbered .2`
  - `apply: a file with no extension gets the infix appended`
  - `apply: MEMORY.md is a line union, store order first`
  - `apply: a subdirectory (.archive/) is merged by the same rule`
  - `apply: awkward file names survive` (`a b.md`, `-dash.md`)
  - `apply: a file written just before the rename is still merged` (Review Focus 1): an `mv` stub first on `PATH` adds `late.md` to the source directory, then runs the real `mv`; `late.md` must be in the store. This row fails if the merge runs before the rename.
  - `apply: a memory directory recreated before the link is merged too`: an `ln` stub creates a real `memory/` holding `recreated.md` once, then runs the real `ln`; the key ends `LINKED` and `recreated.md` is in the store.
  - `resume: an unmarked replaced directory makes --check exit 1` (Review Focus 2)
  - `resume: the next --apply merges it and writes the marker`
  - `resume: a marked replaced directory is not merged again` (a file older than the marker stays out of the store; a newer one is the one case the marker does not settle, and only it is merged)
  - `apply: MISSING gets a link`, `apply: DANGLING gets its target back`
  - `apply: NO-STORE, WRONG-LINK and UNMAPPED are left alone`, one row each
  - `apply: a second run prints nothing`
  - `apply: the replaced directory still holds every original file`
  - `dry-run: prints the counts and changes nothing` (the tree's listing and mtimes are unchanged)
  - `apply: --only limits the run to one key`
  - `lock: a second run waits while the lock is held` (hold the lock in the row for one second; the run finishes after it)
- [ ] **Step 2: Run the table.** Expected: the new rows FAIL on the missing verb.
- [ ] **Step 3: Implement `--apply`** as specified.
- [ ] **Step 4: Run the table**, at umask 022 and 077. Expected: all pass.
- [ ] **Step 5: Mutation sweep:** merge before the rename; plain `ln -s` without `-T`; `cp` without `-p`; overwrite on difference; overwrite an existing conflict copy; drop the index union; skip the marker; merge marked directories too; act on `WRONG-LINK`; drop the `flock`.
- [ ] **Step 6: Commit** (`feat(memory): link a memory directory into its store, merging it in resumably (DO-…)`).

### Task 3: `redact-secrets.sh --shapes-only`

**Files:** Modify `scripts/redact-secrets.sh`, `scripts/test-secret-guard.sh` (the redactor's rows live there), `docs/SECRET_EMISSION.md` (its pinned check count).

**Interfaces — Produces:** `redact-secrets.sh --shapes-only` is the same filter without the two by-name rules. No argument: behaviour unchanged, byte for byte. Any other argument: exit 64.

Why a flag and not a marker count: the by-name rule runs last and overwrites a shape marker on a line such as `GH_TOKEN=gho_…` (probed), so counting shape markers in the full redactor's output misses exactly that line.

- [ ] **Step 1: Failing rows:** `shapes-only: a github token is redacted`; `shapes-only: FOO_TOKEN=plainvalue passes unchanged`; `shapes-only: GH_TOKEN=<token shape> is redacted, labelled by the shape`; `no argument: FOO_TOKEN=plainvalue is still redacted`; `unknown flag: exit 64`.
- [ ] **Step 2: Run.** Expected: the `shapes-only` rows FAIL.
- [ ] **Step 3: Implement.** Every rule line must still begin `-e '` at the start of its line: `scripts/test-scrub-transcript-secrets.sh` extracts the rule labels by that anchor for the parity check.
- [ ] **Step 4: Run** `scripts/test-secret-guard.sh` and `scripts/test-scrub-transcript-secrets.sh`. Expected: all pass; update `EXPECTED_ROWS` and the count in `docs/SECRET_EMISSION.md`.
- [ ] **Step 5: Commit** (`feat(redact): a --shapes-only mode for at-rest gates (DO-…)`).

### Task 4: Readers of the linked layout (doctor, audit row, docs, CI) and PR 1

**Files:** Modify `zsh/functions/claude.sh`, `scripts/test-claude-doctor.sh`, `scripts/test-claude-config-audit.sh`, `docs/CLAUDE_SETUP.md`, `docs/CLAUDE_ACCOUNTS.md`, `CHANGELOG.md`, `.github/workflows/ci.yml`.

**Interfaces — Consumes:** `claude-memory-link.sh --check`, its stdout rows and its exit codes.

- [ ] **Step 1: Failing doctor rows** (a stub link script, as the rendered-settings rows stub the renderer):
  - `ms1` no config → a note, `no memory stores configured`
  - `ms2` exit 0, summary only → ✓ `every memory directory is linked`
  - `ms3` exit 1 → ✗, each reported row shown whole
  - `ms4` exit 0 with `UNMAPPED` rows → ⚠, each row shown (never the ✓ of `ms2`)
  - `ms5` exit 2 → ⚠ with the last stderr line, whole
  - `ms6` the doctor passes only `--check`
  - `ms11` exit 0, nothing linked, keys holding memory without a store → ⚠ `no memory store is checked out on this host (<n> keys wait for one)`, never the ✓
- [ ] **Step 2: Implement** the "Memory stores" section after "Rendered settings". Unlike that section it must keep stdout: the rows are the report. stderr goes into a `local -a` array as there.
- [ ] **Step 3: One audit row,** `collect: a memory directory that is a symlink is collected by content`. The collector already does this (read and confirmed); the row pins it. If it fails, stop and report: do not change the collector in this task.
- [ ] **Step 4: Docs.** "Memory stores" in `docs/CLAUDE_SETUP.md`: the layout, the eight states, what `--apply` does and never does, where a replaced directory goes and what its marker means, how to add a directory to the table, and the pilot's finding that a `default`-mode session is asked on a memory write. One cross-reference line in `docs/CLAUDE_ACCOUNTS.md`. CHANGELOG entry.
- [ ] **Step 5: CI job** `claude-memory-link-test`, shaped like `claude-settings-render-test` (jq through `.github/actions/apt-install`).
- [ ] **Step 6: Run** the tables touched, `scripts/check-state-table-totals.sh`, `scripts/check-claude-md.sh`, `shellcheck -x` on the new scripts, `zsh -n zsh/functions/claude.sh`, `pre-commit run --all-files`. Expected: all green.
- [ ] **Step 7: Commit, push, open PR 1 as draft** with the repo's template.

### Task 5: Sync script, local half (stage, gate, commit, scan)

**Files:** Create `scripts/claude-memory-sync.sh`, `scripts/test-claude-memory-sync.sh`.

**Interfaces — Produces:**
- `claude-memory-sync.sh --check [--store <name>]`: per checked-out store, the count of files that would be committed (built with the same pathspec exclusion as the stage, so a leftover `.<name>.link-partial` never reads as pending), the names of files that would be withheld, and `ahead <n> behind <n>` against the last-fetched `origin` ref. Never writes, never fetches. Exit 1 when anything is pending or withheld.
- `claude-memory-sync.sh --scan [--store <name>] [--rev <rev>]`: the names of files in that revision's tree (default `HEAD`) whose content changes under `redact-secrets.sh --shapes-only`, each with the rule labels, never the lines. Exit 1 when any is found. This is the gate for commits the sync did not make itself.
- `claude-memory-sync.sh --apply [--store <name>]`: this task implements the origin check, stage, gate, commit and the status file; Task 6 adds the network half.
- Staging is `git add -A -f` with a pathspec that excludes the link script's temporaries at every depth (`:(exclude,glob)**/.*.link-partial`), holding `<state dir>/link.lock` — the link script's lock — from stage to commit, so a copy not yet verified whole is never committed and an index mid-write never staged.
- Status: `<state dir>/<store>.status`, one line `epoch<TAB>outcome<TAB>detail`. Outcomes: `ok`, `ok-local-only`, `withheld`, `kept-both`, `blocked`, `push-rejected`, `skipped-no-token`, `unreachable`, `auth-failed`, `could-not-run`. `<state dir>/<store>.last-ok` holds the epoch of the last run whose push or up-to-date check succeeded.
- Commit message `<host>: <n> files`, made with `--no-gpg-sign`.

- [ ] **Step 1: Failing rows** (each store is a `git init -b main` fixture):
  - `commit: new and changed files become one commit named <host>: <n> files`
  - `commit: nothing to do writes no commit`, `commit: a deletion is committed`
  - `commit: signing is off even when commit.gpgsign is true in the fixture config`
  - `commit: a file the global ignore file names is still committed`
  - `commit: a file .git/info/exclude names is still committed`
  - `commit: a file a nested .gitignore names is still committed`
  - `commit: a .<name>.link-partial is never staged`
  - `lock: the sync waits for link.lock`
  - `gate: a file with a token shape is withheld and the others are committed`
  - `gate: the token value is in neither stdout nor stderr`
  - `gate: the token value is in no commit` (`git log -p` of the fixture)
  - `gate: FOO_TOKEN=plainvalue in prose is committed` (shapes only)
  - `gate: the next run names the withheld file again`
  - `scan: a clean tree is exit 0 with no output`
  - `scan: a committed file with a token shape is named with its rule label, exit 1, value absent from the output`
  - `scan: --rev scans that revision, not HEAD`
  - `origin: a remote other than the table's is could-not-run, exit 2, and nothing is staged`
  - `status: outcome withheld names the file`, `status: ok-local-only when there is no origin`
  - `check: pending is exit 1 and writes nothing` (the fixture's `git status` is unchanged)
  - `store: --store limits the run`, `store: a configured store with no checkout is skipped silently`
  - `config: absent is exit 0 with the note`
- [ ] **Step 2: Run.** Expected: all FAIL on the missing script.
- [ ] **Step 3: Implement.** Stage with `git add -A -f -- . ':(exclude,glob)**/.*.link-partial'` (probed on git 2.53: a partial at every depth stays out, an ignored file goes in), holding `<state dir>/link.lock` from stage to commit, so a copy not yet verified whole is never committed and an index mid-write never staged. The gate: for each staged path with content, compare the staged blob with its `--shapes-only` output; a difference unstages the path (`git reset -q -- <path>`).
- [ ] **Step 4: Run.** Expected: all pass.
- [ ] **Step 5: Commit** (`feat(memory): commit a memory store, withholding files with credential shapes (DO-…)`).

### Task 6: Sync script, network half (auth, merge, push, status)

**Files:** Modify `scripts/claude-memory-sync.sh`, `scripts/test-claude-memory-sync.sh`.

**Interfaces — Consumes:** Task 5's status and commit. `scripts/gh-route <dir>` prints JSON `{"state","dir","token_file","why"}`; exit 2 means it could not answer. **Blocked on M7's confirmation.**

Auth, per store:

| `gh-route` answer | action |
|---|---|
| exit 2 | outcome `could-not-run`, exit 2 |
| `matched` or `default`, token file readable and non-empty | export `GH_CONFIG_DIR` and the token to the git child only; git gets `-c credential.helper=` (clearing every configured helper) then the inline helper |
| `matched` or `default`, token file missing, empty or unreadable | outcome `skipped-no-token`, exit 0, no network call |
| `none`, `no-repo`, `no-remotes` | run git with the host's own credential helper, unpinned |

One attempt per tick (specified because the tests alone do not fix it):

```
refuse (could-not-run, exit 2) if .git/MERGE_HEAD, .git/rebase-merge or .git/rebase-apply exists, or HEAD is detached.
git fetch origin                     under timeout NETWORK_TIMEOUT_SECONDS=60
    failure: stderr names an auth or not-found error -> outcome auth-failed, exit 0
             anything else                           -> outcome unreachable, exit 0
if origin/<branch> is not an ancestor of HEAD:
    git -c merge.renames=false merge --no-edit --no-gpg-sign origin/<branch>
    git refused to start because a local file is in the way -> outcome blocked, naming the file, exit 0
    conflicts, per unmerged path, by its status:
        UU (both modified), AA (both added) -> ours becomes the conflict copy (M4), theirs takes the path, add both
        UD (we deleted, they modified)      -> take theirs
        DU (they deleted, we modified)      -> keep ours at the path          (an edit beats a deletion)
        any other status                    -> git merge --abort; outcome could-not-run, exit 2
    commit --no-gpg-sign "<host>: merge, kept both for <k> files"; outcome kept-both
git push origin HEAD:<branch>        under timeout NETWORK_TIMEOUT_SECONDS
    rejected -> outcome push-rejected, exit 0   (the next tick fetches again; the staleness row catches a lasting one)
    success  -> write last-ok
```

`--status` prints `store<TAB>level<TAB>message`, one or more lines per checked-out store, exit 0:

| condition | level |
|---|---|
| last outcome `ok` or `kept-both`, `last-ok` within the threshold | ok |
| the store has an `origin` and `last-ok` is missing or older than the threshold | bad, with the last outcome and detail |
| last outcome `withheld`, `blocked`, `auth-failed` or `could-not-run` | bad, naming the file or reason |
| last outcome `ok-local-only` | warn (`no remote yet`) |
| any conflict copy in the tree | warn, with the count |
| an index line naming a missing file, or one file named by two index lines | warn, with the directory and counts |

The threshold is `stale_after_minutes[<host>]`, else `.default`, else `STALE_AFTER_MINUTES_DEFAULT=60`.

- [ ] **Step 1: Failing rows** (a bare repo as `origin`, a second clone as the other host, a stub `gh-route`):
  - `push: a local commit reaches origin and last-ok is written`
  - `pull: a remote-only file arrives and local files keep their mtime`
  - `integrate: different files on both sides merge with no conflict copy`
  - `integrate: both edited one file` → both bodies present; the conflict copy is the local one
  - `integrate: both added` (Review Focus 5) → the same, and the index holds both lines
  - `integrate: index lines added on both sides are unioned with no conflict copy`
  - `integrate: deleted here, edited there` → present with their body
  - `integrate: edited here, deleted there` → present with our body
  - `integrate: an existing conflict copy is never overwritten` (numbered `.2`)
  - `integrate: a rename on one side and an edit on the other loses neither body` (with renames off this is a delete plus an add)
  - `integrate: a withheld local file in the merge's way is outcome blocked, exit 0, nothing committed`
  - `apply: a merge in progress is could-not-run` (Review Focus 3), `apply: a detached HEAD is could-not-run`
  - `apply: no run leaves MERGE_HEAD behind` (after the `any other status` path, forced by a fixture)
  - `auth: gh-route exit 2 is could-not-run and git is never called` (a recording git stub)
  - `auth: an empty token file is skipped-no-token, exit 0, no fetch`
  - `auth: the token is in no argv` (the recording stub logs every argv; the fixture value must be absent)
  - `auth: the helper answers only get, and fails on an empty variable`
  - `auth: state none runs unpinned`
  - `fetch: an unreachable origin is outcome unreachable, exit 0`
  - `fetch: a not-found error is outcome auth-failed, exit 0`
  - `push: a rejected push is outcome push-rejected, exit 0, one attempt` (a pre-receive hook on the bare repo)
  - `status:` one row per line of the table above, six rows
- [ ] **Step 2: Run.** Expected: the new rows FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: all pass.
- [ ] **Step 5: Mutation sweep:** drop the gate; stage partials too; rebase in place of merge (killed by the mtime row); overwrite in place of a conflict copy; push without fetch; treat `skipped-no-token` as `ok`; token into argv; reset on a merge in progress; leave `MERGE_HEAD` on the unknown-status path; a missing `last-ok` read as healthy.
- [ ] **Step 6: Commit** (`feat(memory): sync a memory store both ways, keeping both copies on a conflict (DO-…)`).

### Task 7: Units, doctor rows, docs, CI and PR 2

**Files:** Create `systemd/claude-memory-sync.service`, `systemd/claude-memory-sync.timer`. Modify `install.conf.yaml` (two links), `zsh/functions/claude.sh`, `scripts/test-claude-doctor.sh`, `scripts/test-claude-memory-sync.sh`, `docs/CLAUDE_SETUP.md`, `CHANGELOG.md`, `.github/workflows/ci.yml`.

Unit values:
- service: `Type=oneshot`; `ConditionPathExists=%h/.local/share/claude-memory`; `ExecStartPre=-%h/.dotfiles/scripts/claude-memory-link.sh --apply`; `ExecStart=%h/.dotfiles/scripts/claude-memory-sync.sh --apply`; `TimeoutStartSec=5min`; `Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin`. The link step's failure does not stop the sync and is visible only in the doctor's link row; say so in the unit's header.
- timer: `OnCalendar=*:0/10`; `RandomizedDelaySec=60`; `Persistent=true`; `[Install] WantedBy=default.target` with the repo's standard "never reenable" comment. Linked by `./install`, **not enabled**: armed by hand.

- [ ] **Step 1: Failing rows.** Doctor (PR 1 took `ms1`–`ms11`): `ms12` each `--status` level maps to its emitter (ok ✓, warn ⚠, bad ✗) with the message whole; `ms13` `--status` exit 2 → ⚠ with the last stderr line; `ms14` no store checked out → ⚠ `no memory store is checked out here`, never silence.
- [ ] **Step 1b: Link-script carries from PR 1's whole-branch review**, each with a row in `scripts/test-claude-memory-link.sh`: (a) `resolve_store_directory` also refuses a store directory whose physical path is at or under `<store checkout>/.git` (a planted `repos/<owner>/<repo> -> ../../.git/hooks` plus a memory file named like a hook would otherwise install an executable hook that the sync's `git merge` runs); (b) `--check` re-tests containment for a `LINKED` key and reports a link whose target resolves outside the physical store checkout as `WRONG-LINK`; (c) a key whose `memory` link dangles into a store that is gone counts under `without a store`, so a removed store is never a ✓; (d) the doctor's UNMAPPED remedy says to move the key directory *out of the projects directory* (a sibling name is walked again), its ⚠ reads `no store that these keys map to is checked out here`, and the stale docstring at `load_unmarked_replaced_dirs` is corrected. Sync table: `units: systemd-analyze verify accepts both` on a sed-pointed copy; `install.conf.yaml links the service`; `install.conf.yaml links the timer` (the pattern at the end of `scripts/test-dev-link.sh`).
- [ ] **Step 2: Implement** the doctor rows and the units.
- [ ] **Step 3: Docs.** Extend "Memory stores": the tick, each outcome and what to do about it, how to resolve a conflict copy (merge the bodies, delete the copy, let the next tick push), how to release a withheld file, how to arm and disarm. CHANGELOG. CI job `claude-memory-sync-test` (jq and git).
- [ ] **Step 4: Run** every table touched, `scripts/test-timer-health.sh`, the reconciler's table, the guards of Task 4 Step 6, and `scripts/verify-tools.sh` in a shell (`zsh -ic`). Expected: green; the new timer reads "linked, not enabled — not checked".
- [ ] **Step 5: Commit, push, open PR 2 as draft**, based on `main` after PR 1 has merged. The controller shows Zvi the `install.conf.yaml` diff before merging.

---

## Calls made here (check these while reading)

- The work store's memory and the personal store's are separated by tenant, by the table. Which tenants share a store is the table's business, not this code's.
- A directory gets a link when it holds memory, or when its store directory already does (M5).
- A file with a credential shape is withheld, and the rest sync (M6). The spec said the commit is refused.
- The sync merges and never rebases (M8). History has merge commits.
- A deletion on one side loses to an edit on the other.
- The sync never fails its unit for a withheld file, a conflict copy, a rejected push, a missing token or an unreachable remote. Those are doctor rows. Only a repo it cannot operate on is a failed unit.
- A multi-account host reads the shell's existing token cache through `scripts/gh-route` (M7, awaiting confirmation).
- Store checkouts on other hosts are cloned by `host-sync` in step 6, not by these scripts.
