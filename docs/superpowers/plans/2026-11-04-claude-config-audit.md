# Cross-Host Claude Config Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** record the shared-configuration design in the repo and build the read-only tool that collects every agent host's Claude Code configuration into one workspace and reports, artifact by artifact, where the hosts agree, differ or hold something the others lack — then run it once for real and write the merge record the next steps consume.

**Architecture:** one bash script, `scripts/claude-config-audit.sh`, with two verbs. `--collect` sends a fixed remote script over ssh (`bash -s`) that tars a declared include set out of a host's config dir and home, extracts it into `<workspace>/<host>/`, rewrites every text file through `scripts/redact-secrets.sh`, and records facts and symlink targets; the laptop is collected locally. `--matrix` reads only the workspace and writes TSV and Markdown reports: per artifact and host, per `settings.json` key, and per memory store and topic file. Nothing on any host is ever written. The merge itself (the design's D0 rules) is a human-reviewed deliverable produced from the workspace, not code.

**Tech Stack:** bash (shellcheck-clean, no GNU-only awk or grep extensions: `awk` here is mawk and `grep` a ugrep shim), `jq`, `tar`, `sha256sum`, OpenSSH; a hermetic state table in `scripts/test-claude-config-audit.sh` with stubbed `ssh`; CI job in `.github/workflows/ci.yml`.

**Spec:** [`docs/superpowers/specs/2026-11-04-shared-claude-config-design.md`](../specs/2026-11-04-shared-claude-config-design.md) — Task 1 creates it from the approved plan file; read sections D0, D1 and "Measured state" before Task 2. This plan implements the program's steps 1 and 2; steps 3–10 get their own plans once the audit's merged outputs exist.

## Global Constraints

- **Read-only on every host.** `--collect` runs only `find`, `tar`, `cat`, `--version` on a remote; the only writes are under the workspace on the laptop. A test row asserts the fixture host trees are byte-identical before and after.
- **Never collect a credential or a transcript.** Excluded by name, always: `.credentials.json*`, `.claude.json*`, `*.jsonl`, `sessions/`, `shell-snapshots/`, `file-history/`, `paste-cache/`, `debug/`, `cache/`, `backups/`, `downloads/`, `telemetry/`, `security/`, `*.signature*`, `plugins/{cache,marketplaces,repos,data,store,synced}/`, `skills/synced/`, and under `projects/` everything except `*/memory/`.
- **Every collected text file passes through `scripts/redact-secrets.sh`** before anything reads it; a file `grep -Iq .` calls binary is not copied and is named in `collect.log`.
- **Nothing user-supplied is interpolated into a remote command.** A host alias matches `^[A-Za-z0-9._-]+$`, a config dir `^\.[A-Za-z0-9._-]+$`; the remote script is a fixed heredoc and takes the config dir as `$1`.
- **Exit codes:** `--collect`: 0 every host collected · 2 a host failed (named, the others still collected) · 64 usage. `--matrix`: 0 hosts identical on every declared artifact · 1 drift reported · 2 a declared host has no `facts.tsv` (a missing row is a failed collect, never "nothing there") · 64 usage.
- **Workspace default** `$HOME/Projects/handoffs/2026-11-claude-config-audit`, overridable with `--workspace` / `CLAUDE_CONFIG_AUDIT_WORKSPACE`; it is a durable path, never `$TMPDIR`.
- **Default hosts** (constant in the script, overridable with repeated `--host NAME=ALIAS:CFGDIR`): `laptop=local:.claude`, `dev=dev:.claude`, `sol-build=sol-build:.claude`, `nanoclaw=nanoclaw:.claude-herdr`. `local` means collect without ssh.
- **The ssh command** is `${CLAUDE_CONFIG_AUDIT_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=30 -o ForwardAgent=no}` and is invoked as `$ssh_cmd "$alias" 'bash -s -- CFGDIR' <remote-script`, alias last before the command, so a stub can find it.
- **State table rules** (CLAUDE.md "CI/CD Testing"): hermetic under `mktemp -d`, "could not run" is exit 2, `EXPECTED_ROWS=<n>` compared against rows run, every needle unique to its rule and checked against the pass path, mutation sweep before merge.
- **Commit trailer:** `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Branch carries the DO issue id (Task 0).
- **CLAUDE.md stays under its ceiling** (`scripts/check-claude-md.sh`; 502 bytes of slack at 15635fa).

## Review Focus

1. A memory or hook file with a NUL byte or invalid UTF-8: the redactor cannot see into it, so it must be skipped and named, never copied unredacted — pinned in Task 3 (`binary file is skipped and logged`).
2. A host lacking one include path (no `agents/`, no `~/toysim`): the collect must still succeed and the matrix must show `missing`, not abort or silently drop the host — Task 3 (`absent paths do not fail the collect`), Task 5 (`missing is a status`).
3. Non-interactive ssh on dev has no `~/.local/bin` on PATH: `claude --version` must be read from `$HOME/.local/bin/claude` and degrade to `unknown`, with the collect still exit 0 — Task 3 (`claude version falls back to unknown`).
4. The same skill present as a symlink into dotfiles on one host and a real copy on another with identical bytes: the matrix must say `identical` and show the link/copy provenance, because a later "remove the duplicate" that forgets the link loses the skill — Task 5 (`identical content, link on one host, copy on the other`).
5. The laptop's per-seat `settings.json` copies diverging from `~/.claude/settings.json`: today byte-identical, but the account-dir builder refreshes them only on launch, so a divergence is a real drift source — Task 4 (`account-dir copies are collected and compared`).

---

## File structure

| File | Task | Responsibility |
|---|---|---|
| `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md` | 1 | the approved design, verbatim from the plan file with its header set to spec status |
| `CLAUDE.md` (Claude Code accounts & MCP section) | 1 | one pointer line to the spec and the audit verb |
| `scripts/claude-config-audit.sh` | 2–6 | the tool: constants, arg parsing, `collect_remote`, `collect_local`, `redact_tree`, `matrix_files`, `matrix_settings`, `matrix_memory`, `main` |
| `scripts/test-claude-config-audit.sh` | 2–6 | hermetic state table; fixture hosts under `$TMPROOT/hosts/<alias>`, stub `ssh` |
| `.github/workflows/ci.yml` | 6 | the `claude-config-audit-test` job |
| `CHANGELOG.md` | 6 | one entry |
| `docs/CLAUDE_SETUP.md` | 6 | a short "Auditing the hosts" section naming the verbs and the workspace layout |
| `~/Projects/handoffs/2026-11-claude-config-audit/` | 7 | the real collect, the matrices, `audit.md`, `merged/` |

Workspace layout written by the tool (Tasks 3–5 pin it; Task 7 fills it):

```
<ws>/hosts.tsv                      name  alias  cfgdir  collected_at  status
<ws>/<host>/facts.tsv               key<TAB>value: hostname user home cfgdir claude_version herdr_version collected_at
<ws>/<host>/links.tsv               path<TAB>target, every symlink in the include set
<ws>/<host>/collect.log             skipped binaries, absent paths
<ws>/<host>/cfg/…                   CLAUDE.md settings.json settings.local.json keybindings.json hooks/ skills/ agents/ commands/ rules/ plugins/{known_marketplaces,installed_plugins}.json
<ws>/<host>/memory/<projects-key>/  each projects/*/memory/ dir, named by its projects/ entry
<ws>/<host>/roots/<name>.CLAUDE.md  ~/quantivly ~/Projects ~/toysim root files, by basename of the root
<ws>/<host>/repos/<root>/<repo>/.claude/…   repo-local .claude dirs under those roots
<ws>/<host>/account-dirs/<seat>/settings.json   laptop only: each account dir's real settings copy
<ws>/matrix.tsv  matrix.md  settings-matrix.md  memory-matrix.tsv  memory-matrix.md
```

---

### Task 0: File the issue and name the branch

**Files:** none in the repo.

- [ ] **Step 1: File the DO issue** with the `quantivly-conventions:linear` skill. Title: `Audit and merge Claude Code configuration across the laptop, dev and sol-build`. Description: the one-paragraph goal above, the four hosts, "read-only on every host", and a link to the plan file path. Record the id as `DO-NNN`.
- [ ] **Step 2: Rename the branch** so the merge closes the issue: `git branch -m zvi/do-NNN-claude-config-audit` (the worktree path does not change; `herdr pane list` keeps working).
- [ ] **Step 3: Verify** `git rev-parse --abbrev-ref HEAD` prints the new name.
- [ ] **Step 4: File the sibling issue the spec names** (filing only, no fix in this plan): `server-bootstrap.sh never applies its server templates and Q_MODE=server is read by nothing` — Phase 3's `./install` creates `~/.zshrc.local` and `~/.gitconfig.local` from the workstation templates before Phase 5 checks for them (`scripts/server-bootstrap.sh:230,304,318`); `Q_MODE` is set at `zsh/zshrc.company:20` and never read. Record its id in the spec's "What exists and is reused" line.

### Task 1: Record the design

**Files:**
- Create: `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md`
- Modify: `CLAUDE.md` (the "Claude Code accounts & MCP (`claude-doctor`)" bullet list)

- [ ] **Step 1: Copy the approved plan file** `/home/zvi/.local/state/claude-account-dirs/quantivly-3/plans/working-remotely-on-dev-fuzzy-cake.md` to the spec path. Replace its first two lines with `# Shared Claude Code configuration across hosts — design` and `**Status:** approved by Zvi 2026-11-04 (brainstorm, builder check and his eight answers recorded below). Implementation plans: docs/superpowers/plans/2026-11-04-claude-config-audit.md (steps 1–2), later plans per step.` Rename the `## Plan` heading to `## Sequencing (one PR per step)`. Change nothing else.
- [ ] **Step 2: Add one line to CLAUDE.md** at the end of the Claude accounts bullet list: `- **One configuration across hosts.** Design: [docs/superpowers/specs/2026-11-04-shared-claude-config-design.md](docs/superpowers/specs/2026-11-04-shared-claude-config-design.md). Audit the hosts before changing any of them: \`scripts/claude-config-audit.sh --collect\` then \`--matrix\` (read-only everywhere; workspace under \`~/Projects/handoffs/\`).`
- [ ] **Step 3: Run the guards.** `./scripts/check-claude-md.sh` → `all 8 checks passed` (docs/superpowers/* is exempt from the reachability rule, so no `docs/README.md` row; its line 104 already names the directory as working material). `pre-commit run --files CLAUDE.md docs/superpowers/specs/2026-11-04-shared-claude-config-design.md` → passes.
- [ ] **Step 4: Commit** `docs: record the shared Claude Code configuration design (DO-NNN)`.

### Task 2: Script skeleton, argument parsing, usage

**Files:**
- Create: `scripts/claude-config-audit.sh` (mode 755)
- Create: `scripts/test-claude-config-audit.sh` (mode 755)

**Interfaces:**
- Produces: `usage()`; `parse_args "$@"` setting globals `MODE` (`collect`|`matrix`), `WORKSPACE`, `HOSTS` (array of `name=alias:cfgdir`), `SSH_CMD`; `die MSG` (exit 2), `usage_error MSG` (exit 64); the constants `DEFAULT_HOSTS`, `EXCLUDE_NAMES`, `ALIAS_RE='^[A-Za-z0-9._-]+$'`, `CFGDIR_RE='^\.[A-Za-z0-9._-]+$'`.

- [ ] **Step 1: Write the state table's frame** in `scripts/test-claude-config-audit.sh`: copy the header shape of `scripts/test-dev-sync.sh` (ok/bad/check/has/hasnt/fatal, `mktemp -d` + trap, tool preflight for `bash jq tar sha256sum`, `[[ -x "$SUT" ]] || fatal`, the "not inside a git repo" guard), `SUT="$DOTFILES/scripts/claude-config-audit.sh"`, and at the end `EXPECTED_ROWS=4` compared against `PASS+FAIL` with a FATAL on mismatch. Add the first four rows:
  - `usage: no verb → exit 64 and the usage text`: `out=$("$SUT" 2>&1); rc=$?` → `check "exit" "$rc" 64`, `has "names both verbs" "$out" "--collect"`.
  - `usage: --help → exit 0`.
  - `usage: a host alias with a space or semicolon → exit 64, nothing created`: `"$SUT" --collect --workspace "$W" --host 'x=bad host;rm:.claude'` → rc 64 and `[[ ! -e "$W" ]]`.
  - `usage: a config dir not starting with a dot → exit 64`.
- [ ] **Step 2: Run it to see it fail**: `./scripts/test-claude-config-audit.sh` → FATAL, SUT not executable (or every row ✗).
- [ ] **Step 3: Write the skeleton**: header comment in the repo's house style (what, why, the two verbs, exit codes, the read-only promise, test overrides `CLAUDE_CONFIG_AUDIT_SSH`, `CLAUDE_CONFIG_AUDIT_WORKSPACE`), `set -uo pipefail`, the constants, `usage()` printed from the header's Usage block (the `sed -n '/^# Usage/,/^# Exit:/p'` trick dev-sync uses), `parse_args`, and a `main` that dispatches `collect_main`/`matrix_main` (stubs that `die "not implemented"` for now).
- [ ] **Step 4: Run the table** → 4/4 ✓, `EXPECTED_ROWS` satisfied. `shellcheck -x scripts/claude-config-audit.sh scripts/test-claude-config-audit.sh` clean.
- [ ] **Step 5: Commit** `feat(audit): claude-config-audit skeleton with argument validation (DO-NNN)`.

### Task 3: `--collect` for a remote host

**Files:**
- Modify: `scripts/claude-config-audit.sh`
- Modify: `scripts/test-claude-config-audit.sh`

**Interfaces:**
- Produces: `collect_remote NAME ALIAS CFGDIR` → exit 0/1, writes `<ws>/NAME/{facts.tsv,links.tsv,collect.log,cfg/,memory/,roots/,repos/}`; `redact_tree DIR` rewrites every text file in place through `scripts/redact-secrets.sh` (resolved relative to the script's own directory, `$DOTFILES/scripts/redact-secrets.sh`) and appends `binary-skipped<TAB>path` lines to `collect.log` for files `grep -Iq .` rejects (which it then deletes from the workspace); `remote_script` is a fixed heredoc that, given `$1`=cfgdir, prints to stdout a tar stream (`tar -chf - --ignore-failed-read -T list`) containing `facts.tsv`, `links.tsv`, `absent.txt`, and the include set laid out as `cfg/…`, `memory/<key>/…`, `roots/…`, `repos/…`.
- Consumes: Task 2's globals.

- [ ] **Step 1: Build the fixture and stub ssh in the test.** `make_host ALIAS` creates `$TMPROOT/hosts/ALIAS` as a HOME with: `.claude/{CLAUDE.md,settings.json,settings.local.json,keybindings.json}`, `.claude/hooks/{a.sh,b.sh}` (`b.sh` a symlink to `$HOME/.dotfiles/claude/hooks/b.sh`), `.claude/skills/{rabota,synced}/SKILL.md`, `.claude/agents/x.md`, `.claude/plugins/{known_marketplaces,installed_plugins}.json` and `.claude/plugins/cache/junk`, `.claude/projects/-home-ALIAS-quantivly-hub/memory/{MEMORY.md,fact-one.md}` and a `.jsonl` beside it, `.claude/.credentials.json` and `.claude.json` (contents `FIXTURE-CRED`), `.claude/sessions/s`, `quantivly/CLAUDE.md`, `quantivly/hub/.claude/settings.json`, `.local/bin/claude` (a stub printing `2.1.300 (Claude Code)`), `.local/bin/herdr` (prints `herdr 0.9.5`). The stub `ssh` at `$TMPROOT/bin/ssh`: skips `-o X` pairs, takes the next arg as ALIAS and the rest as the command, runs `HOME=$TMPROOT/hosts/ALIAS PATH=/usr/bin:/bin bash -c "$cmd"` with stdin passed through; `ALIAS=down` exits 255 with "Connection refused". Export `CLAUDE_CONFIG_AUDIT_SSH="$TMPROOT/bin/ssh"`.
- [ ] **Step 2: Add the rows** (append to the frame; bump `EXPECTED_ROWS` by 9):
  - `collect: include set lands under cfg/ with the layout`: run `"$SUT" --collect --workspace "$W" --host h1=h1:.claude` → rc 0; `[[ -f $W/h1/cfg/CLAUDE.md && -f $W/h1/cfg/hooks/a.sh && -f $W/h1/cfg/skills/rabota/SKILL.md && -f $W/h1/cfg/agents/x.md && -f $W/h1/cfg/plugins/known_marketplaces.json && -f $W/h1/memory/-home-h1-quantivly-hub/fact-one.md && -f $W/h1/roots/quantivly.CLAUDE.md && -f $W/h1/repos/quantivly/hub/.claude/settings.json ]]`.
  - `collect: credentials, .claude.json, transcripts, sessions, plugin cache and synced skills are never copied`: `grep -rl FIXTURE-CRED "$W"` empty; no `*.jsonl`, no `sessions`, no `plugins/cache`, no `skills/synced` under `$W/h1`.
  - `collect: a credential-shaped string in a collected file is redacted`: write `tok="lin_api_""FIXTUREVALUE0123456789abcdefXYZ"` into the fixture's `CLAUDE.md` before the run → `grep -c REDACTED "$W/h1/cfg/CLAUDE.md"` is 1 and the literal is absent.
  - `collect: binary file is skipped and logged`: a `hooks/blob.bin` containing a NUL byte → absent from `$W/h1/cfg/hooks/`, and `collect.log` has `binary-skipped` + `hooks/blob.bin`.
  - `collect: symlinks are dereferenced and recorded`: `cfg/hooks/b.sh` is a regular file with the target's content; `links.tsv` has a line `hooks/b.sh<TAB>…/.dotfiles/claude/hooks/b.sh`.
  - `collect: facts.tsv carries hostname, user, home, cfgdir, claude_version 2.1.300, herdr_version 0.9.5`.
  - `collect: claude version falls back to unknown`: a fixture without `.local/bin/claude` → `claude_version<TAB>unknown`, rc 0.
  - `collect: absent paths do not fail the collect`: a fixture without `agents/` and without `~/toysim` → rc 0, `collect.log` has `absent<TAB>agents`.
  - `collect: an unreachable host exits 2, names it, and the reachable host is still collected`: `--host down=down:.claude --host h1=h1:.claude` → rc 2, stderr has `down`, `$W/h1/facts.tsv` exists, `hosts.tsv` has `down … failed` and `h1 … ok`.
  - `collect: the host tree is unchanged`: `find … -exec sha256sum` of `$TMPROOT/hosts/h1` before and after are equal.
- [ ] **Step 3: Run the table** → the new rows fail (`not implemented`).
- [ ] **Step 4: Implement `remote_script`, `collect_remote`, `redact_tree`, and the `hosts.tsv` writer** in `scripts/claude-config-audit.sh`. The remote script: `cd "$HOME"`; builds `list` with `find` over the include set (globs as literal paths, missing ones appended to `absent.txt` instead of erroring; `-not -path` for every `EXCLUDE_NAMES` entry; `projects/*/memory` only); writes `facts.tsv` (hostname, `id -un`, `$HOME`, cfgdir, `"$HOME/.local/bin/claude" --version` → first field or `unknown`, same for herdr, `date -u +%FT%TZ`), `links.tsv` from `find … -type l -printf '%P\t%l\n'`; then `tar -chf - --ignore-failed-read --transform` rules that map `CFGDIR/…`→`cfg/…`, `CFGDIR/projects/K/memory/…`→`memory/K/…`, `quantivly/CLAUDE.md`→`roots/quantivly.CLAUDE.md`, `ROOT/REPO/.claude/…`→`repos/ROOT/REPO/.claude/…`. If `--transform` proves awkward, stage into a `mktemp -d` on the remote with `cp --parents` and tar that; either is acceptable, the layout is what the rows pin. Locally: `mkdir -p "$ws/$name"`, `$SSH_CMD "$alias" 'bash -s -- CFG' <<<"$remote_script" | tar -xf - -C "$ws/$name"` with `PIPESTATUS` checked (ssh failure → `hosts.tsv` row `failed`, return 1), then `redact_tree "$ws/$name"`, then the `ok` row.
- [ ] **Step 5: Run the table** → all ✓; `shellcheck -x` clean; `EXPECTED_ROWS` satisfied.
- [ ] **Step 6: Commit** `feat(audit): --collect gathers a host's config read-only, redacted, with facts and links (DO-NNN)`.

### Task 4: `--collect` for the laptop (`local`), account dirs included

**Files:**
- Modify: `scripts/claude-config-audit.sh`
- Modify: `scripts/test-claude-config-audit.sh`

**Interfaces:**
- Produces: `collect_local NAME CFGDIR` — runs the same `remote_script` through `bash -s` locally (no ssh), then additionally copies `$HOME/.local/state/claude-account-dirs/*/settings.json` (regular files only, never symlinks) to `<ws>/NAME/account-dirs/<seat>/settings.json`, through `redact_tree`.

- [ ] **Step 1: Add the rows** (`EXPECTED_ROWS` += 3):
  - `collect: local host uses no ssh`: run with `--host laptop=local:.claude` under `HOME=$TMPROOT/hosts/lap` and a stub ssh that records calls → the ssh call log is empty, `$W/laptop/cfg/CLAUDE.md` exists.
  - `collect: account-dir copies are collected and compared`: fixture `~/.local/state/claude-account-dirs/{q1,q2}/settings.json` (q2 a symlink to `~/.claude/settings.json`) → `$W/laptop/account-dirs/q1/settings.json` exists, `q2` absent, `collect.log` has `account-dir-link<TAB>q2`.
  - `collect: local collect redacts too`: a fixture token in `account-dirs/q1/settings.json` → `REDACTED` present.
- [ ] **Step 2: Run** → the rows fail.
- [ ] **Step 3: Implement `collect_local`** and route `alias == local` to it in `collect_main`.
- [ ] **Step 4: Run** → all ✓; shellcheck clean.
- [ ] **Step 5: Commit** `feat(audit): collect the laptop locally, account-dir settings copies included (DO-NNN)`.

### Task 5: `--matrix`

**Files:**
- Modify: `scripts/claude-config-audit.sh`
- Modify: `scripts/test-claude-config-audit.sh`

**Interfaces:**
- Produces: `matrix_main` → writes `matrix.tsv` (`artifact<TAB>status<TAB>host:state…`), `matrix.md`, `settings-matrix.md`, `memory-matrix.tsv` (`store<TAB>file<TAB>status<TAB>host:state…`), `memory-matrix.md`; exit per Global Constraints. Helpers: `artifact_status` (given per-host sha256 or `-`): `identical` (all present, one hash) · `only-on:<host>` (present on exactly one) · `missing-on:<h,…>` (present on some, equal where present) · `differs` (more than one hash; the host with the newest mtime named as `newest:<host>`); `provenance` from `links.tsv`: `link→<target>` or `copy`; `store_key KEY USER` strips a leading `-home-USER-` so `-home-zvi-quantivly-hub` and `-home-ubuntu-quantivly-hub` meet as `quantivly-hub`; `fact_signature FILE` = the frontmatter `description:` value lowercased with whitespace collapsed; `settings_diff` using jq: `permissions.allow` as per-host set differences against the union, `hooks` compared by the basename of the first script path in each command, `enabledPlugins` by name with its boolean, `extraKnownMarketplaces` by name and `source.source`, every other top-level key `same`/`differs`.

- [ ] **Step 1: Add the rows** (`EXPECTED_ROWS` += 10). Build three fixture hosts `h1 h2 h3` with controlled differences, collect them, then run `--matrix --workspace "$W"`:
  - `matrix: identical / only-on / missing-on / differs are each classified`: `cfg/CLAUDE.md` same on all → `identical`; `cfg/agents/x.md` only on h2 → `only-on:h2`; `cfg/keybindings.json` on h1,h2 equal, absent on h3 → `missing-on:h3`; `cfg/hooks/a.sh` different on h3 → `differs` with `newest:h3`.
  - `matrix: identical content, link on one host, copy on the other, is identical with provenance`: `cfg/hooks/b.sh` → status `identical`, the row names `h1:link→…` and `h2:copy`.
  - `matrix: missing is a status, not an abort`: a host without `agents/` still has a row per artifact.
  - `matrix: a declared host without facts.tsv exits 2 and names it`.
  - `matrix: settings permissions.allow is reported as set differences`: h1 allow `[A,B]`, h2 `[B,C]` → `settings-matrix.md` lists `A` under `only h1`, `C` under `only h2`.
  - `matrix: settings hooks are compared by basename`: h1 `bash '/home/h1/.claude/hooks/x.sh'`, h2 `f="$HOME/.claude/hooks/x.sh"; …` → `x.sh` reported `same` for both; a `y.sh` only on h2 → `only h2`.
  - `matrix: memory stores meet across homes`: h1 `-home-h1-quantivly-hub`, h2 `-home-h2-quantivly-hub` → one store row `quantivly-hub` with both hosts.
  - `matrix: a memory topic file with one name and two bodies is differs; one description under two names is flagged`: `memory-matrix.tsv` rows `fact-one.md differs` and `same-fact?<TAB>fact-two.md~fact-2.md`.
  - `matrix: account-dir settings copies are compared against cfg/settings.json`: a `laptop/account-dirs/q1/settings.json` that differs from `laptop/cfg/settings.json` → row `account-dirs/q1/settings.json` with status `differs-from:cfg/settings.json`; an identical copy → `same-as:cfg/settings.json`.
  - `matrix: exit 0 when every artifact is identical, 1 when any row is not`.
- [ ] **Step 2: Run** → rows fail.
- [ ] **Step 3: Implement** `matrix_main` and the helpers. Hashes via `sha256sum`; mtimes via `stat -c %Y`; tables with `printf`; Markdown tables from the TSVs. Keep the per-key settings logic in jq filters held in named variables (`JQ_ALLOW_SETS`, `JQ_HOOK_BASENAMES`, …), one line each.
- [ ] **Step 4: Run** → all ✓; shellcheck clean; `EXPECTED_ROWS` satisfied.
- [ ] **Step 5: Commit** `feat(audit): --matrix classifies every artifact, settings key and memory file across hosts (DO-NNN)`.

### Task 6: CI, docs, changelog, mutation sweep

**Files:**
- Modify: `.github/workflows/ci.yml` (add job `claude-config-audit-test`, shape of the transcript-scrub job; needs only stock tools)
- Modify: `docs/CLAUDE_SETUP.md` (new section "Auditing the hosts": the two verbs, the workspace layout block above, "read-only everywhere", the exclusion list, the exit codes)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the CI job** and run `./scripts/check-workflow-apt.sh` and `./scripts/check-state-table-totals.sh` → both pass.
- [ ] **Step 2: Write the docs section and the CHANGELOG entry.** `./scripts/check-claude-md.sh` still passes.
- [ ] **Step 3: Mutation sweep** (commit first — `git checkout --` restores delete uncommitted work): for each of these one-line mutations, apply, run the table, confirm at least one row dies, revert: (a) drop `.credentials.json*` from `EXCLUDE_NAMES`; (b) skip `redact_tree`; (c) `tar -cf` instead of `-chf` (no dereference); (d) `store_key` returns its input unchanged; (e) `artifact_status` returns `identical` for any one-host artifact; (f) `--matrix` exits 0 on drift; (g) the `grep -Iq .` binary test inverted. Record the kill list in the commit message. A mutant that survives is a hollow row: fix the row, not the tally.
- [ ] **Step 4: Run everything** `pre-commit run --all-files`, the table, `shellcheck -x` on both scripts → clean.
- [ ] **Step 5: Commit** `test(audit): CI job, docs and a seven-mutant sweep for claude-config-audit (DO-NNN)`, then open the PR with the `quantivly-conventions:prs` skill (title `DO-NNN Audit Claude Code configuration across hosts read-only`), CI green on the branch's own HEAD sha (`gh pr checks` can show the previous run).

### Task 7: Run the audit for real and write the merge record

**Files:**
- Create (outside the repo): `~/Projects/handoffs/2026-11-claude-config-audit/{hosts.tsv,<host>/…,matrix.*,settings-matrix.md,memory-matrix.*,audit.md,merged/}`

This task needs the merged PR's script on the laptop (deploy with `git -C ~/.dotfiles fetch origin main && git -C ~/.dotfiles merge --ff-only origin/main`, never `git pull`). nanoclaw is a production box: the collect is read-only and brief, but run it outside Sol's busy hours and never from a pane an agent reads.

- [ ] **Step 1: Collect.** `scripts/claude-config-audit.sh --collect` (defaults: laptop local, dev, sol-build, nanoclaw with `.claude-herdr`). Expected: rc 0 and four `ok` rows in `hosts.tsv`. If dev is unreachable, `dev-link-doctor` first; the SSM link, not dev, is the usual fault.
- [ ] **Step 2: Matrix.** `scripts/claude-config-audit.sh --matrix` → rc 1 (drift is expected); every artifact class in the spec's D0 list has a row for every host (grep `matrix.tsv` for each class; a missing class is a collect defect, go back to Step 1).
- [ ] **Step 3: Write `audit.md`** with these sections, in this order, each a table with `artifact | hosts | decision | goes to | provenance (host, mtime) | why`: user-level CLAUDE.md (three-way merge → `merged/CLAUDE.md`); `settings.json` keys (permissions union, hooks by basename, enabledPlugins per tenant, the quantivly `autoMode.environment` text taken from dev → `merged/settings/{common,quantivly,personal,toysim}.json`); hooks; skills; agents (dev's 15: keep / retire, one row each); keybindings; plugins and marketplaces; tenant-root and host `CLAUDE.md` files (→ `merged/roots/`); repo-local `.claude/` dirs; memory per store (→ `merged/memory/<tenant>/repos/<owner>/<repo>/`, built from the D0 rules: union by file name, index regenerated from frontmatter, conflicts kept as `<name>.<host>.md` and listed under a "Conflicts for review" heading). A retire decision cites where the content now lives or why it is dropped.
- [ ] **Step 4: Verify the memory merge** with a count: for each store, topic files in `merged/` = union of the hosts' files minus confirmed duplicates (listed), and each regenerated `MEMORY.md` has exactly one line per topic file (`ls | wc -l` vs `grep -c '^- '`).
- [ ] **Step 5: Hand over for review.** Tell Zvi the workspace path and that `audit.md` and `merged/` are the inputs of the next plan (step 3, tracking the canon in dotfiles-local); nothing on any host has changed. The next plan is written only after his review of `audit.md`.
