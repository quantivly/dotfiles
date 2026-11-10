# Bring dev level with the shared configuration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make a host with one GitHub account and no clauth (dev today, sol-build next) behave correctly once the tenant table and the memory stores arrive there, so program step 7 can bring dev level with one `host-sync --host dev --apply`.

**Architecture:** four small mechanism fixes, each in the file that already owns the behaviour, then the bring-up itself, which is an operational procedure and not code. (1) `claude-tenants-apply-gh` derives no gh route on a machine where none of the tenants' gh config dirs exists; such a machine has one GitHub account, `scripts/gh-route` answers `none` there, and the memory sync then uses the host's own git credential. A machine that has at least one of the dirs behaves exactly as today. (2) `claude-doctor`'s pool checks say once that pools pick no account where clauth is not installed, instead of one ✗ per pool member. (3) The memory link and sync scripts name the host from the profile marker when there is one, so a conflict copy and a commit message say `dev`, not an EC2 hostname. (4) The memory link script skips a directory whose `.git` file names a git directory that does not exist, instead of refusing every verb for the whole host. The private overlay's change and the host-specific commands are in the controller's private runbook, outside this repository.

**Tech Stack:** bash 5 and zsh, jq, git ≥ 2.40, systemd user units, dotbot; state tables under `scripts/test-*.sh`.

**Spec:** `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md` — "Sequencing" item 7, D2, D3, D7 (M1–M8), D8 (H1–H10), D9, "Verification".

Revision 2, 2026-11-10, after an independent review that probed the code and dev (1 Critical, 7 Important, 13 Minor; all folded in).

## Why step 7 needs code at all (measured 2026-11-10, read-only, on dev)

- dev has no `clauth` binary and no `~/.clauth`; one GitHub account through `gh auth git-credential`; no `~/.config/gh-quantivly`, no `~/.cache/gh-token-cache`; `scripts/gh-route` answers `none` there today.
- The overlay installs the tenant table (`~/.config/claude-tenants.zsh`), and `claude-memory-link.sh` cannot map a checkout to a store without it (`scripts/tenant-route` exits 2). With it, `claude-tenants-apply-gh` adds `<owner>=<tenant gh dir>` without asking whether any such dir exists (`zsh/zshrc.herdr:460-472`), `gh-route` answers `matched` with a token file nothing on that host writes, and `claude-memory-sync.sh` records `skipped-no-token` on every tick: no fetch, no push, unit exit 0. Reproduced in a fixture `HOME` with the real table.
- With the table present and clauth absent, `claude()`, `hspawn` and `claude-pick` are unchanged apart from the table's validity check (`whence -p clauth` gates the picker), but `claude-doctor` prints five "pool … names …, which has no clauth profile store" lines and three "spill for … names …, which the picker cannot use (nostore)" lines, and the spec's check for a level host is a clean doctor.
- `hostname -s` on dev is an `ip-…` name; both memory scripts take the host's name from it (`claude-memory-link.sh:1161`, `claude-memory-sync.sh:1889`), and the first link on dev writes conflict copies that carry the name into the shared store.
- One directory under dev's work root holds a `.git` file whose `gitdir:` points at a path that no longer exists (a 2023 copy of a submodule's working tree). It matches a store glob, `tenant-route` gets git's exit 128 for it, and `claude-memory-link.sh` exits 2 on `--check`, `--list` and `--apply`: one stray directory, and no memory is linked on the host. Measured on dev and reproduced in a fixture; it is the only one of dev's 59 candidates that fails.
- Already true, no change needed: dev reads both private repositories over HTTPS, also from a unit's environment; git 2.52; a git identity is configured; lingering is on; `url.*.insteadOf` on dev rewrites only ssh forms; dotbot runs `if:` at the repo root and skips `create` when it fails (executed against a fixture); `scripts/check-links.sh` parses the extended `if:` entries and reports an absent conditional link as `conditional-absent`, exit 0.

## Global Constraints

- Every state table is hermetic under a fixture `HOME`, asserts its own row total (`EXPECTED_ROWS`), and treats "could not run" as exit 2. `scripts/check-state-table-totals.sh` must pass after every row added. Two tables also pin the count their doc quotes (`docs/GH_ACCOUNT_ROUTING.md:317` for `test-gh-routing.sh`, `docs/HERDR_INTERNALS.md:326` for `test-hspawn.sh`): the doc number changes in the same commit as `EXPECTED_ROWS`.
- Nothing in a test or a probe runs the renderer, the memory link or sync scripts, `./install` or `host-sync --apply` against the real machine.
- Every needle is unique to its rule and is checked against what the pass path prints. A row that passes before and after the change is a **pin**: the plan says so and names the change it would catch.
- The mutation sweep runs before the merge, on committed work, one mutant at a time under `setsid timeout --kill-after=5 <cap>`, with fixtures under `~/.cache/tmp/mutant-<id>`; `ps` (through `scripts/redact-secrets.sh`) and `du` after each; each mutant has an expected verdict and its diff is read, not only its applicability.
- No diagnostic prints a credential. A token file's path may be printed; its content never.
- `grep` is a `ugrep` shim and `awk` is mawk on the laptop; CI runs GNU. No GNU-only flag paired with `2>/dev/null || true`.
- A dashed zsh function may not call a single-underscore helper it adds: Claude Code's Bash-tool shells keep the first and drop the second (CLAUDE.md, "Claude Code accounts & MCP").
- Names say what the thing is; a literal with a role is a named constant; a new or changed function carries a comment that says what it returns.
- This PR does not touch `install.conf.yaml` or `CLAUDE.md`.
- Commits are scoped, imperative, and end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. PR title `DO-#### <summary>`.

## Review Focus

1. **A machine with some of the tenants' gh dirs and not others** (a laptop whose personal dir went missing): nothing changes from today. Every route is still derived, the missing dir included, so the store stays pinned to it and the miss stays loud. Pinned in Task 1 (row 2).
2. **A tenant gh dir given as a relative path, or one that is a regular file:** a relative path is not judged and is passed on, so `_gh_route_for` still refuses it as a bad table; a regular file is not a directory and does not make the machine a multi-account one. Pinned in Task 1 (rows 4, 5).
3. **A profile marker whose first line is unusable** (empty, a path, trailing carriage return) or that cannot be read: the memory scripts fall back to `hostname -s`, print no error about the marker, and never die on it. Pinned in Task 3 (rows 3, 4).
4. **A tenant table that parses and fails when run, on a machine without clauth:** still a ✗; the new note must come after every table-validity check, because `claude()` refuses each launch on those states with or without clauth. Pinned in Task 2 (rows 3, 4).
5. **A git failure that is not a dangling gitfile** (a corrupt checkout, an unreadable `.git`): the link script still refuses, exit 2. Only the one structural state is skipped. Pinned in Task 4 (row 4).

---

### Task 1: No tenant gh routes on a machine with none of the tenants' gh dirs

**Files:**
- Modify: `zsh/zshrc.herdr:452-472` (`claude-tenants-apply-gh` and its comment), `scripts/gh-route` (header, step 3), `docs/GH_ACCOUNT_ROUTING.md:317` (the documented count)
- Test: `scripts/test-gh-routing.sh` (the "tenant-derived gh routes" block and the "scripts/gh-route" block; `EXPECTED_ROWS` 231 → 239)

**Interfaces:**
- Produces: `claude-tenants-apply-gh`, same name and call sites. New first step, written inline (no helper function): if no value of `CLAUDE_TENANT_GH_DIR` is *present*, return 0 having added nothing. A value is present when it is not an absolute path (not judged) or is an existing directory (`[[ "$dir" != /* || -d "$dir" ]]`). When at least one is present, the function does exactly what it does today, entry for entry.
- Consumed by: `scripts/gh-route:108`, a machine's own overlay, Task 5's docs.

- [ ] **Step 1: Re-fixture and add rows.** In the `apply` block the fixture's dirs become real ones under the table's temp dir (`GH_WORK_DIR`, `GH_PERSONAL_DIR`, both created) plus `GH_ABSENT_DIR` (absolute, never created); the seven existing rows keep their names and shapes with the real paths. In the "scripts/gh-route" block, three existing rows whose tenants file names only `/gh-client` get that dir created under their fixture `HOME` and the path substituted: `a route the tenants file derives is applied`, `--tables lists the derived route after the shipped one`, `a malformed table is exit 2, not no-route`. The row `a route naming a relative config dir is exit 2, never that dir` must pass unchanged. New rows:
  1. `a machine with none of the tenants' gh dirs gets no route, no path route and no default` — all three tenants → `GH_ABSENT_DIR` → the answer is `||`.
  2. `one tenant's gh dir present: every entry is still derived, the missing ones included` — `work → GH_WORK_DIR`, `client` and `home → GH_ABSENT_DIR` → field 1 is `quantivly=<GH_WORK_DIR>,Acme-LTD=<GH_ABSENT_DIR>` and field 3 is `<GH_ABSENT_DIR>`.
  3. `a gh dir that is a symlink to a directory counts as present` — the only non-absent value is a symlink to `GH_WORK_DIR` → field 1 starts `quantivly=`. (Pin: catches a test that does not follow links.)
  4. `a gh dir path that is a regular file does not count as present` — every value absent except one that is a regular file → `||`.
  5. `a relative gh dir is not judged: its entry is passed on` — the only value is `relative/gh` → field 1 is `quantivly=relative/gh`.
  6. `a team default survives on a machine with none of the dirs` — `GH_ACCOUNT_DEFAULT_DIR=/team-default`, all absent → field 3 is `/team-default`. (Pin: catches a guard that clears the tables.)
  In the "scripts/gh-route" block, under the block's gate-off `HOME` (`GR_NOGATE`) with a tenants file that routes an owner: 7. `a tenants file on a machine with none of the tenants' gh dirs: a routed owner answers none` — `state` is `none`, `dir` and `token_file` are `""`. 8. `...and with that tenant's dir created, the same owner answers matched` — same `HOME`, same tenants file, the dir created → `state` is `matched` (the control that proves row 7's fixture routes at all).
- [ ] **Step 2: Run** `bash scripts/test-gh-routing.sh` → rows 1, 4 and 7 fail (routes to dirs that do not exist are printed; `state` is `matched`); 2, 3, 5, 6, 8 pass already.
- [ ] **Step 3: Implement** the guard. The comment above the function gains the reason: a machine with none of the dirs has one GitHub account; a route derived there pins nothing, makes `scripts/gh-route` answer `matched` with a token file nobody writes, and the memory sync then skips every push (dev, 2026-11-10); with at least one dir present a missing one is a fault that must stay visible, so nothing is skipped entry by entry.
- [ ] **Step 4: Run** the table → 239 ✓; `zsh -n zsh/zshrc.herdr`; `bash scripts/test-hspawn.sh`, `bash scripts/test-tenant-route.sh` and `bash scripts/test-claude-doctor.sh` still pass (all source the file); `bash scripts/check-state-table-totals.sh`.
- [ ] **Step 5: Commit** `fix(gh-routing): derive no tenant gh route on a machine with none of the tenants' gh dirs`.

### Task 2: Pool checks on a machine without clauth

**Files:**
- Modify: `zsh/functions/claude.sh` (`_claude_doctor_pools`: between the last table-validity check, line 904, and the pool-shape checks, line 906), `docs/HERDR_INTERNALS.md:326` (the documented count), `docs/CLAUDE_ACCOUNT_MCP.md:185` (one clause: the row appears where clauth is installed)
- Test: `scripts/test-claude-doctor.sh` (`EXPECTED_ROWS` 603 → 608), `scripts/test-hspawn.sh` (`EXPECTED_ROWS` 454 → 456)

**Interfaces:**
- Produces: in `_claude_doctor_pools`, when `whence -p clauth` fails and the table was read, parsed and run cleanly, exactly one `_doctor_note` line, `clauth is not installed — the pools pick no account on this machine; member checks skipped`, then return 0. Every check above it keeps running without clauth.

- [ ] **Step 1: Doctor rows**, with the table's pool-section driver and a fixture `PATH` without `clauth`:
  1. `no clauth, a tenant table with pools and spill seats: one note` — output has `clauth is not installed — the pools pick no account on this machine`.
  2. `...and the Pools section prints no ✗` — the section's output has no line starting with the ✗ glyph (this covers the member lines and the `spill for … (nostore)` lines).
  3. `no clauth, a tenant table that does not parse is still a ✗` — output has `cannot be read or does not parse — pool checks NOT RUN`.
  4. `no clauth, a tenant table that parses and fails when run is still a ✗` — output has `did not run cleanly — pool checks NOT RUN`.
  5. `clauth installed, a member with no profile store is still a ✗, and there is no note` — same table as row 1, `clauth` on the fixture `PATH` → output has `which has no clauth profile store` and lacks `clauth is not installed`.
- [ ] **Step 2: hspawn rows**, beside the existing `NOCLAUTH=1` rows. Write a valid tenants file to `$FHOME/.config/claude-tenants.zsh` before them and remove it after, so no later row loads it:
  6. `with no clauth and a tenant table, the launch is unchanged` — `CFG <unset>`. (Pin: dev depends on it from step 7 on; catches a picker that runs on the table alone.)
  7. `...and hspawn shares the credential, unpicked` — `account:   SHARED global credential`. (Pin, same change.)
- [ ] **Step 3: Run** both tables → rows 1 and 2 fail; 3–7 pass already.
- [ ] **Step 4: Implement** the note and the early return. **Step 5: Run** both tables → 608 and 456 ✓; `zsh -n zsh/functions/claude.sh`; totals check.
- [ ] **Step 6: Commit** `fix(claude-doctor): say once that pools pick no account without clauth`.

### Task 3: The memory scripts name the host from the profile marker

**Files:**
- Modify: `scripts/claude-memory-link.sh` (`prepare_apply`, line 1161; header line 174), `scripts/claude-memory-sync.sh` (`settle_host_name`, line 1889; header line 247)
- Test: `scripts/test-claude-memory-link.sh` (`EXPECTED_ROWS` 206 → 211), `scripts/test-claude-memory-sync.sh` (`EXPECTED_ROWS` 111 → 116)

**Interfaces:**
- Produces, in each script (they stay standalone; no shared library): `resolve_host_name` prints the host's name, the first of: `CLAUDE_MEMORY_HOST` when set and non-empty; the first line of the profile marker (`${CLAUDE_SETTINGS_RENDER_MARKER:-$HOME/.config/claude-host-profile}`, the renderer's and host-sync's path) when the file is readable and that line matches `HOST_NAME_RE`; `hostname -s`. It tests readability before it reads, so an unreadable marker prints nothing on stderr. The existing `HOST_NAME_RE` test and `die` stay as the last check on whichever name was chosen. Named constant `PROFILE_MARKER_RELATIVE='.config/claude-host-profile'`.
- Unchanged for a machine whose marker equals its hostname (the laptop), or that has no marker.

- [ ] **Step 1: Rows**, five in each table, after an `unset CLAUDE_SETTINGS_RENDER_MARKER CLAUDE_MEMORY_HOST` at the top of the table. The link table has a `hostname` stub (`stub-short-host`); the sync table has none and always passes `CLAUDE_MEMORY_HOST`, so build the same stub there. In the link table the marker the new rows write into the shared fixture `HOME` is removed before the existing "defaults to hostname -s" row.
  1. `host name: the profile marker names the host` — marker `markerhost`. Link table: a differing file's conflict copy is `<stem>.conflict-markerhost.md` and no `*.conflict-stub-short-host*` exists. Sync table: the commit a changed store gets names `markerhost`, and with `stale_after_minutes` `{"default": 60, "markerhost": 5}` and a last-ok 10 minutes old, `--status` reports that store stale.
  2. `host name: CLAUDE_MEMORY_HOST outranks the marker` — both set → the name is the variable's.
  3. `host name: an unusable marker line falls back to hostname -s` — marker `../climb` → the name is the stub's, exit status as for a normal run.
  4. `host name: an unreadable marker falls back to hostname -s, silently` — marker mode 000 → the name is the stub's and the run's stderr has no `Permission denied`. The row first asserts the fixture file really is unreadable to this user; under root (`act` runs so) that assertion fails and the table is could-not-run, exit 2, which the row's comment says.
  5. `host name: the marker override path is honoured` — `CLAUDE_SETTINGS_RENDER_MARKER=<other file>` naming `overridehost`, and another name in the fixture `HOME`'s default marker → the name is `overridehost`.
- [ ] **Step 2: Run** both tables → rows 1 and 5 fail; 2, 3 and 4 pass already and are pins (mutants h3, h4 and h6 below).
- [ ] **Step 3: Implement** `resolve_host_name` in both scripts and call it where `HOST_NAME` is set today; update the two header lines. **Step 4: Run** both tables → 211 and 116 ✓; `bash scripts/test-host-sync.sh` still 649 ✓; `shellcheck -x` on both scripts; totals check.
- [ ] **Step 5: Commit** `feat(memory): name the host from the profile marker when there is one`.

### Task 4: One directory with a dangling gitfile does not stop memory linking

**Files:**
- Modify: `scripts/claude-memory-link.sh` (candidate discovery: `add_checkout_and_submodules`, line 541, and the gitfile reader above `classify_directory`'s kind test, lines 488–493)
- Test: `scripts/test-claude-memory-link.sh` (`EXPECTED_ROWS` 211 → 215)

**Interfaces:**
- Produces: a directory matched by a checkout glob whose `.git` is a regular file with a `gitdir:` line naming a path that does not exist (resolved against the directory, as the script already resolves it) is **not a checkout**: it is not registered as a candidate, and one line goes to stderr on every verb, `claude-memory-link: <dir> is not a checkout: its .git names a git directory that does not exist; skipped`. Exit status, the summary line and every other candidate are unaffected. Any other failure to read a candidate (no `gitdir:` line, an unreadable `.git`, `tenant-route` exit 2 for a real checkout) still dies, exit 2.
- `host-sync` reads a sibling's stderr only when the sibling exits 2 (`run_memory_sibling`), so its rows do not change.

- [ ] **Step 1: Rows.**
  1. `a directory whose .git names a missing git directory is skipped: --check still answers` — fixture with one real checkout and one such directory under a glob → exit is 0 or 1 as for the real checkout alone, the summary line prints, stderr has `is not a checkout: its .git names a git directory that does not exist`.
  2. `...and --apply still links the real checkout beside it` — the real checkout's `memory` is a link into the store afterwards.
  3. `a submodule whose git directory exists is still a candidate` — a gitfile naming an existing `…/modules/<name>` → its key is listed. (Pin: catches a skip of every gitfile.)
  4. `a checkout git cannot answer for is still exit 2` — an ordinary `.git` directory made unusable (its `HEAD` removed) → exit 2 with `tenant-route could not answer`. If an existing row asserts exactly this, name it in the commit message and do not add a twin; the total is then 214.
- [ ] **Step 2: Run** → rows 1 and 2 fail (exit 2); 3 and 4 pass already.
- [ ] **Step 3: Implement** the skip where the gitfile's target is resolved. **Step 4: Run** → 215 ✓ (or 214); `bash scripts/test-host-sync.sh` 649 ✓; `shellcheck -x`; totals check.
- [ ] **Step 5: Commit** `fix(memory): skip a directory whose gitfile names a missing git directory`.

### Task 5: Spec amendments, docs, and the sweep

**Files:**
- Modify: `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md` (dated amendment paragraphs under D7, D8 and D9)
- Modify: `docs/CLAUDE_SETUP.md` ("Keeping a host level (DO-895)": a subsection for a host's first run; the memory section's host-name and `stale_after_minutes` sentences; the two documented row counts at lines 624–625), `docs/GH_ACCOUNT_ROUTING.md` and `docs/CLAUDE_ACCOUNT_PICKER.md:648-663` (the `claude-tenants-apply-gh` paragraphs: one clause each), `CHANGELOG.md`

- [ ] **Step 1: Spec amendments**, each dated 2026-11-10 and citing this plan:
  - **(M9, under D7) A host with one GitHub account syncs with its own git credential.** Where none of the tenants' gh config dirs exists, the tenant table derives no gh route, `gh-route` answers `none` and the sync runs unpinned. Where at least one exists nothing changes: M7's routed token cache applies, and a store whose tenant's dir is missing is still pinned to it and reported.
  - **(M10, under D7) The host's name** in a conflict copy, a commit message and `stale_after_minutes` is `CLAUDE_MEMORY_HOST`, else the profile marker's name, else `hostname -s`.
  - **(M11, under D7) A directory whose `.git` names a missing git directory is not a checkout** for the link script: skipped and named, never a refusal for the host.
  - **(H11, under D8) A first run needs the marker first.** It is written by hand before the first `--apply` (a hostname that is not a profile name cannot name one). The overlay's per-tenant links carry `if:` conditions on the host profile, and the link rows count an absent conditional link as in place.
  - **(under D9)** the doctor's pool checks apply where clauth is installed; elsewhere one note.
- [ ] **Step 2: `docs/CLAUDE_SETUP.md`**, "A host's first run": write the marker; run `host-sync --host <alias> --apply` outside the host's 05:00–05:30 window; what the run changes (overlay cloned, both `./install`s, settings rendered by the public `./install` with the previous file kept under `~/.local/state/claude-settings-render/`, missing plugins installed, memory stores cloned and linked with every replaced directory kept beside its link, the memory timer armed, stale skills and agents moved under `~/.local/state/host-sync/retired/`); the three reads that prove it (`--check`, `gh-route <store>` answering `none` on a single-account host, `claude-memory-sync.sh --status`); and the standing preflight for a new host (every glob match answers `git config --get-regexp '^remote\..*\.url$'` with exit 0 or 1). Correct the host-name sentences and the two row counts. Run `scripts/check-doc-tokens.sh` and `scripts/check-claude-md.sh`.
- [ ] **Step 3: Mutation sweep** (commit first; expected verdict KILLED for each, by the row named):

  | id | mutation | killed by |
  |---|---|---|
  | g1 | remove the guard | Task 1 rows 1, 7 |
  | g2 | `-d` → `-e` in the guard | Task 1 row 4 |
  | g3 | guard returns unless **every** dir is present | Task 1 row 2 |
  | g4 | judge a relative path too (drop the `/*` half) | Task 1 row 5 |
  | g5 | invert the guard (return when a dir is present) | the existing "it adds every entry the tenant table implies" row |
  | d1 | remove the no-clauth return | Task 2 row 2 |
  | d2 | move the return above the parse check | Task 2 row 3 |
  | d3 | move the return between the parse check and the run-cleanly check | Task 2 row 4 |
  | d4 | return whenever a table exists, clauth or not | Task 2 row 5 |
  | h1 | ignore the marker (link) | Task 3 row 1, link table |
  | h2 | ignore the marker (sync) | Task 3 row 1, sync table |
  | h3a / h3b | the marker outranks `CLAUDE_MEMORY_HOST` (link / sync) | Task 3 row 2, each table |
  | h4a / h4b | accept any marker line (link / sync) | Task 3 row 3, each table |
  | h5a / h5b | read the default marker path only (link / sync) | Task 3 row 5, each table |
  | h6a / h6b | drop the readability test before the read (link / sync) | Task 3 row 4, each table |
  | l1 | remove the dangling-gitfile skip | Task 4 rows 1, 2 |
  | l2 | skip every directory whose `.git` is a file | Task 4 row 3 |
  | control | no change | every table passes |

  A survivor gets a row or a recorded reason it is equivalent; the kill table goes in the PR body.
- [ ] **Step 4:** `pre-commit run --all-files`; every table this plan touched, once more, from a clean tree. **Step 5: Commit** `docs: record the single-account host rules and a host's first run`.

---

## The bring-up (controller-run; host-specific commands are in the private runbook)

Order, each step verified before the next:

1. This PR merged and deployed on the laptop; laptop reads unchanged (`gh-route --tables` and the answer for each memory store identical before and after, the next memory tick `ok`, `claude-doctor` as before).
2. The overlay's PR merged and deployed on the laptop: per-tenant links gated on the host profile, its link checker replaced by `scripts/check-links.sh --root`, the store table's globs reaching every checkout dev has memory for.
3. Preflight on dev, read-only: every glob match answers git; a fresh collect of dev's configuration; `claude-doctor`'s output as a baseline; dev's first settings render simulated on the laptop from a copy of its `settings.json` and read against the audit's table.
4. The marker written on dev by hand, then `scripts/host-sync --host dev --apply`, outside dev's 05:00–05:30 window.
5. Verified per the spec: `host-sync --host dev --check` with no ✗ and no ⚠ on a memory row; `claude-doctor` no worse than its baseline, Pools a note; the five skills and the rendered permissions present; `gh-route` for the work store `none` and the store's first sync `ok`; dev's memory in the laptop's store and the laptop's on dev after one tick each way; a deliberate two-sided edit kept as a pair; the units' health read with `LoadState` first; `claude-config-audit.sh --matrix` with no difference on a declared artifact.

## Calls made here (check these while reading)

- **"None of the dirs exists" is what makes a machine single-account**, not "this dir is missing". Skipping entry by entry was the first draft; it would let a multi-account machine with one dir gone sync that tenant's store with whatever the keyring answers, which M7 exists to prevent. The rule here changes nothing on a machine that has any of the dirs.
- **The profile marker names the host for memory**, since the marker is already the host's identity for settings and host-sync. Two hosts on one profile would share a name in conflict copies; none exist.
- **The doctor's note is a note (○), not a ✓ or ⚠:** nothing is wrong and nothing was checked.
- **A dangling gitfile is skipped; every other git failure still refuses.** The alternative, moving the directory aside by hand, is a write under the team's work tree on a shared box, repeated on every new host.
- **Deferred to step 10, named so they are not lost:** the link rows' wording ("N declared links in place" counts an absent conditional link, and no `test-host-sync.sh` row pins that state); `check-links.sh` cannot say whether an absent conditional link *should* be present (it does not evaluate `if:`); the render's list union keeps two spellings of one `soft_deny` rule on dev; dev's `herdr-agent-state.sh` is one integration version behind the laptop's although both run herdr 0.9.1; if a per-tenant gh dir is ever created on a single-account host, `zshrc.gh-routes`' gate opens and the tenant default could then name a dir that does not exist.
