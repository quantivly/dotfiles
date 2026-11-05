# Claude Settings Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make `~/.claude/settings.json` a rendered file on every host that carries a host profile: a public base fragment (the repo's own hooks, statusLine, marketplace, plugin) merged with the private per-tenant overlays, keyed by hooks' script basenames, with host-specific keys left exactly as found, and a `--check` that the doctor and the sync can run.

**Architecture:** one bash+jq script in the public repo, `scripts/claude-settings-render.sh`, gated on a marker file that names the host's profile (`~/.config/claude-host-profile`), reading `claude/settings/base.json` from the checkout and `~/.dotfiles-local/claude/settings/{common,<tenant>…}.json` for the tenants the profile lists. It merges into the live file by rule (lists unioned, objects deep-merged, scalars from the highest fragment, hooks replaced by basename, only the "### Org-wide" block of `autoMode.environment` replaced, `$HOME` substituted in marketplace paths only, undeclared keys untouched), writes by temp file and rename with a backup, and refuses a symlink. `herdr-claude-wire.sh` delegates its statusLine/bell merge to the renderer where a profile exists; dotfiles-local's `claude-hooks-wire.sh` retires. The account-dir builder keeps copying the rendered file into each seat dir on launch.

**Tech Stack:** bash (shellcheck-clean, mawk-safe), jq, dotbot, the repo's state-table conventions; two repos, two PRs (public dotfiles first, then the private overlay), deploy on the laptop last.

**Spec:** `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md` D4, D2, D9, D12 — amended by this plan's Task 1 (four amendments below) — and the resolved merge record `~/Projects/handoffs/2026-11-claude-config-audit/audit.md` (§2 "settings.json keys", "Resolutions" S1–S6, "Not decided here"). The fragments to ship are `~/Projects/handoffs/2026-11-claude-config-audit/merged/settings/{base,common,quantivly,personal,toysim}.json`.

## Global Constraints

- **Spec amendments, recorded in Task 1 before any code:** (A1) the quantivly marketplace is declared in `quantivly.json`, not base (Q2 amends D4 step 1); (A2) the renderer replaces only the "### Org-wide" block of `autoMode.environment` and leaves the "### User-specific" half as found (amends D4 step 3 / D12); (A3) hooks are keyed by the basename of the first script path in the command, or the executable when there is no path; a rendered entry replaces the live entry with the same key; events with no declared entry are left as found; (A4) host profiles are JSON, `~/.dotfiles-local/hosts/<profile>.json` with `{"tenants": [...]}`, selected by the marker `~/.config/claude-host-profile` (one line, the profile name); D2's `.toml` is amended, and the marker is what gates rendering (D4).
- **Render only where the marker exists.** No marker: exit 0, one note line, nothing written. Teammates and modular adopters never get their `settings.json` rewritten.
- **Merge rules, exact:** `permissions.allow` and every other JSON list: union, order = live then fragments, duplicates dropped; objects: deep merge, fragments win on conflicting scalars, later fragment over earlier (order: base, common, then each tenant in profile order); hooks: per event, key each entry by `basename` of the first `$HOME/...` or `/...` path in `command`, else the first word; a fragment entry replaces the live entry with the same key and is appended otherwise; `autoMode.environment`: if a fragment carries it, its lines replace the live array's lines from `### Org-wide` up to (not including) `### User-specific`, the rest untouched; `extraKnownMarketplaces.<name>.source.path`: literal `$HOME` replaced by the host's `$HOME` at render time (the only substitution; hook and statusLine commands keep `$HOME` literal, `sh -c` expands it at run time); keys no fragment declares (`env`, `feedbackSurveyState`, `skipWorkflowUsageWarning`, `tui`, anything else) copied as found.
- **Writer:** refuses when `settings.json` is a symlink or not a JSON object (exit 2); `--check` prints a unified diff of the would-be change and exits 1 on drift, 0 when identical; `--print` prints the rendered JSON; `--apply` (default when run by `./install` with the marker) writes `.settings.json.render.XXXXXX` beside the file, `chmod --reference`, keeps a copy of the previous file at `~/.local/state/claude-settings-render/settings.json.before-<UTC ts>` (last 10 kept), then renames. Exit codes: 0 · 1 drift (check) · 2 could not run · 64 usage.
- **Inputs validated:** the profile file must parse and list ≥1 tenant; every listed tenant must have `claude/settings/<tenant>.json` in the overlay (missing → exit 2 naming it); every fragment must be a JSON object; `jq` present (exit 2 otherwise).
- **Fragments are the audit's merged ones**, verbatim, except that this plan's Task 5 moves `extraKnownMarketplaces.quantivly` into `quantivly.json` if the merged files do not already have it there (they do, after the Task 7 fix round) and sets `statusLine.refreshInterval` 120 in base (S5).
- **State-table rules** (CLAUDE.md "CI/CD Testing"): hermetic under `mktemp -d` with a fixture `HOME`, exit 2 on could-not-run, `EXPECTED_ROWS` compared, every needle unique to its rule and checked against the pass path, mutation sweep before merge; no GNU-only awk/grep extensions.
- **Names explicit; literals with a role as named constants** (`PROFILE_MARKER_RELATIVE`, `BACKUPS_KEPT`, `ORG_WIDE_HEADING`, `USER_SPECIFIC_HEADING`, jq filters in named variables).
- **CLAUDE.md byte budget:** the public repo's CLAUDE.md has 154 B of headroom; the one pointer line already there covers the audit. Add nothing to it; the renderer is documented in `docs/CLAUDE_SETUP.md` and reachable from there.
- **Two repos, two PRs:** public `quantivly/dotfiles` (renderer, base fragment, tests, doctor section, wire delegation, spec amendments, docs) merges first under the standing authorization; private `ZviBaratz/dotfiles-local` (overlay fragments, profiles, marker, retire `claude-hooks-wire.sh`) is merged by Zvi. Deploy on the laptop last (Task 9).
- **Commit trailer:** `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Branch names from Linear (`gitBranchName`).

## Review Focus

1. A live `settings.json` whose `hooks.PreToolUse` carries the same script under two different absolute paths (dev's `/home/ubuntu/...` plus a `$HOME/...` one): the basename key must collapse them to one rendered entry, never two — pinned in Task 3 (`hooks: two spellings of one script become one entry`).
2. A fragment hook whose command has no path (`herdmates hook TeammateIdle` behind `command -v`): keyed by the executable, not the whole command, so a live entry `herdmates hook TeammateIdle` is replaced, not duplicated — Task 3.
3. `autoMode.environment` on a host with no `### User-specific` heading at all (sol-build today): the org-wide replace must not drop or duplicate lines; the result is the fragment's block plus whatever followed — Task 3 (`autoMode: no user-specific half`).
4. The live file's `env` object (clauth owns it) survives byte-for-byte, including when a fragment is empty `{}` (`personal.json`) — Task 3.
5. `--apply` on a `settings.json` that clauth rewrote a moment ago (different `env`, same declared keys): `--check` must report identical, not drift, because undeclared keys are not compared — Task 3 (`check: undeclared keys never count as drift`).

---

## File structure

| File | Task | Responsibility |
|---|---|---|
| `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md` | 1 | the four amendments, dated, in D2/D4/D12 |
| `claude/settings/base.json` (dotfiles) | 2 | the public base fragment (from `merged/settings/base.json`, refreshInterval 120) |
| `scripts/claude-settings-render.sh` (dotfiles) | 2–4 | the renderer: `load_profile`, `load_fragments`, `merge_settings` (jq program in `JQ_MERGE`), `substitute_home`, `write_settings`, `main` |
| `scripts/test-claude-settings-render.sh` (dotfiles) | 2–4 | hermetic state table |
| `scripts/herdr-claude-wire.sh` (dotfiles) | 6 | statusLine/bell merge delegates to the renderer when the marker exists; default refreshInterval 120 |
| `zsh/functions/claude.sh` (dotfiles) | 6 | `claude-doctor` "Rendered settings" section |
| `install.conf.yaml`, `docs/CLAUDE_SETUP.md`, `CHANGELOG.md`, `.github/workflows/ci.yml` (dotfiles) | 6 | render step in install (marker-gated), docs, changelog, CI job |
| `claude/settings/{common,quantivly,personal,toysim}.json`, `hosts/{cilantro,dev,sol-build}.json` (dotfiles-local) | 7 | the overlays and profiles |
| `scripts/claude-hooks-wire.sh`, `scripts/test-claude-hooks-wire.sh`, `install.conf.yaml`, `README.md`, `CLAUDE.md` (dotfiles-local) | 8 | retire the wire script; declare the marker; docs |

---

### Task 0: Issues and worktrees

- [ ] **Step 1:** file DO issue A, `Render Claude Code settings from the public base and the private tenant overlays` (team DO, assignee me, estimate 5, Todo, due 2026-11-07, label Developer Experience (DX)); description: problem (four hand writers, `/home/zvi` paths, dev's hand-kept copy), why now (step 4 of the program; the audit's fragments are ready), done when (renderer + doctor section merged; the laptop and dev render to the audit's merged settings; `claude-hooks-wire.sh` retired), Agent notes with the plan path and the four amendments. Record DO-A and its `gitBranchName`.
- [ ] **Step 2:** file DO issue B, `Ship the settings overlays and host profiles in dotfiles-local` (estimate 2, Todo, due 2026-11-07, `blockedBy` DO-A). Record DO-B.
- [ ] **Step 3:** worktrees: `git -C ~/.dotfiles worktree add -b <DO-A branch> ~/.herdr/worktrees/.dotfiles/zvi-do-A-settings-render origin/main` and `git -C ~/.dotfiles-local worktree add -b <DO-B branch> ~/.herdr/worktrees/.dotfiles-local/zvi-do-B-settings-overlays origin/main`. Commit this plan into the dotfiles worktree as `docs/superpowers/plans/2026-11-05-claude-settings-render.md` (`docs: plan for the Claude settings renderer (DO-A)`).

### Task 1: Spec amendments

**Files:** Modify `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md`.

- [ ] **Step 1:** add a dated `**Amended 2026-11-05 (DO-A):**` paragraph under D2 (A4: JSON profiles and the marker), D4 step 1 (A1), D4 step 3 (A2, A3) and D12 (the user-specific half stays per host). Each cites `audit.md` "Not decided here".
- [ ] **Step 2:** `./scripts/check-claude-md.sh` still passes (docs/superpowers is exempt; CLAUDE.md untouched).
- [ ] **Step 3: Commit** `docs: amend the design for the renderer (marketplace in the overlay, org-wide auto-mode block, hooks by basename, JSON host profiles) (DO-A)`.

### Task 2: Skeleton, profile and fragment loading

**Files:** Create `scripts/claude-settings-render.sh` (755), `scripts/test-claude-settings-render.sh` (755), `claude/settings/base.json`.

**Interfaces (Produces):** globals `MODE` (`check`|`print`|`apply`), `SETTINGS_PATH` (default `$HOME/.claude/settings.json`, `--settings PATH` override for tests), `PROFILE_MARKER` (`$HOME/.config/claude-host-profile`, `CLAUDE_SETTINGS_RENDER_MARKER` override), `OVERLAY_ROOT` (`$HOME/.dotfiles-local`, `CLAUDE_SETTINGS_RENDER_OVERLAY` override), `BASE_FRAGMENT` (`$DOTFILES/claude/settings/base.json`); `load_profile` → `PROFILE_NAME`, `TENANTS` array; `load_fragments` → `FRAGMENTS` array of paths in merge order; `die` (2), `usage_error` (64).

- [ ] **Step 1:** table frame (copy `scripts/test-claude-config-audit.sh`'s frame: ok/bad/check/has/hasnt/fatal, fixture `HOME` exported at the top, `mktemp -d`, preflight `bash jq`, `EXPECTED_ROWS` compared) with rows: `usage: no verb → 64`; `usage: --help → 0 with the usage text`; `no marker → exit 0, prints "no host profile", writes nothing` (a live settings fixture must be byte-identical after); `marker names a profile with no file → exit 2 naming the path`; `profile lists a tenant without a fragment → exit 2 naming the tenant`; `fragments load in order base, common, tenants` (`--print-order` debug verb or a `-v` line; pick one and name it). `EXPECTED_ROWS=6`.
- [ ] **Step 2:** run → FATAL/fails. **Step 3:** write the skeleton: header in the house style (what, why, the merge rules in one block, exit codes, overrides), constants, `parse_args`, `load_profile` (marker → `PROFILE_NAME` matched `^[A-Za-z0-9][A-Za-z0-9._-]*$`; `jq -r '.tenants[]'` from `$OVERLAY_ROOT/hosts/$PROFILE_NAME.json`), `load_fragments`, stubs for merge/write. Copy `merged/settings/base.json` to `claude/settings/base.json` and set `statusLine.refreshInterval` to 120 (`jq`), `jq -S` sorted keys.
- [ ] **Step 4:** run → 6/6; `pre-commit run shellcheck --files …` clean; `./scripts/check-state-table-totals.sh`. **Step 5: Commit** `feat(settings): renderer skeleton loads the host profile and the fragments (DO-A)`.

### Task 3: The merge

**Files:** Modify both scripts.

**Interfaces (Produces):** `merge_settings LIVE_JSON FRAGMENT_PATHS…` → rendered JSON on stdout, via one jq program held in `JQ_MERGE` with named sub-filters (`JQ_UNION_LISTS`, `JQ_HOOK_KEY`, `JQ_MERGE_HOOKS`, `JQ_AUTOMODE_ORG_WIDE`); `substitute_home JSON` → JSON with `$HOME` replaced in `extraKnownMarketplaces[].source.path` only.

- [ ] **Step 1:** rows (`EXPECTED_ROWS` += 12): `lists: permissions.allow is the union, live order first, no duplicates`; `objects: modelSettings deep-merges, a later fragment wins a scalar`; `scalars: theme from the highest fragment`; `hooks: a fragment entry replaces the live entry with the same basename` (live `bash '/home/h1/.claude/hooks/x.sh'` vs fragment `f="$HOME/.claude/hooks/x.sh"; …` → one entry, the fragment's); `hooks: two spellings of one script become one entry`; `hooks: a no-path command is keyed by its executable` (herdmates); `hooks: an event no fragment declares is left as found`; `autoMode: only the org-wide block is replaced` (live has both halves, fragment has org-wide → user-specific half byte-identical, org-wide = fragment); `autoMode: no user-specific half`; `home: $HOME substituted in the marketplace path only` (a hook command keeps the literal); `undeclared keys survive byte-for-byte` (`env`, `feedbackSurveyState`); `check: undeclared keys never count as drift`.
- [ ] **Step 2:** run → rows fail. **Step 3:** implement `JQ_MERGE` etc. **Step 4:** run → all ✓, shellcheck, totals. **Step 5: Commit** `feat(settings): merge base and overlays by rule — unions, deep merge, hooks by basename, org-wide auto-mode block (DO-A)`.

### Task 4: The writer and the verbs

- [ ] **Step 1:** rows (+8): `apply: writes by temp file and rename, mode preserved`; `apply: keeps a dated backup, at most 10`; `apply: refuses a symlinked settings.json (exit 2)`; `apply: refuses a non-object file (exit 2)`; `check: exit 1 with a unified diff on drift, 0 when rendered == live`; `print: rendered JSON on stdout, nothing written`; `apply twice: second run is a no-op (same bytes, no new backup)`; `jq missing → exit 2`.
- [ ] **Step 2–5:** RED, implement `write_settings` and `main`, GREEN, commit `feat(settings): --check, --print and --apply with a backed-up atomic write (DO-A)`.

### Task 5: Fragment fidelity

- [ ] **Step 1:** row (+1): `base.json equals the audit's merged base except refreshInterval 120` (the test carries a copy of the merged base as a fixture? No: the fixture is the repo's own `claude/settings/base.json`; the row asserts its keys are exactly `hooks statusLine extraKnownMarketplaces enabledPlugins` and that `extraKnownMarketplaces` holds only `dotfiles`). **Step 2–3:** adjust base if needed, commit `feat(settings): the public base fragment carries only what the repo owns (DO-A)`.

### Task 6: Wire delegation, doctor, install step, docs, CI, sweep, PR (dotfiles)

- [ ] **Step 1:** `herdr-claude-wire.sh`: when `$HOME/.config/claude-host-profile` exists, its statusLine/bell steps call `scripts/claude-settings-render.sh --apply` and skip their own jq merge (one row in `scripts/test-herdr-*`? the wire script's table is `scripts/test-herdr-claude-wire.sh` if present; otherwise add one row to the renderer's table that the wire script shells out — name what you did); default `REFRESH` 120.
- [ ] **Step 2:** `claude-doctor` "Rendered settings" section in `zsh/functions/claude.sh`: marker absent → `_doctor_note`; present → run `--check`, ✓ on 0, ✗ on 1 with "run scripts/claude-settings-render.sh --apply", ⚠ on 2 with the reason.
- [ ] **Step 3:** `install.conf.yaml`: a shell step after the hook links, `scripts/claude-settings-render.sh --apply` (it exits 0 with a note when no marker). `docs/CLAUDE_SETUP.md`: "Rendered settings" section (the marker, the fragments, the rules, the verbs, the backups, "settings.json is still not a symlink and clauth may rewrite `env`"). CHANGELOG. CI job `claude-settings-render-test` in the house shape.
- [ ] **Step 4:** mutation sweep (commit first): (a) lists concatenated instead of unioned; (b) hook key = whole command; (c) autoMode replaced wholesale; (d) `$HOME` substituted in every string; (e) undeclared keys dropped; (f) symlink refusal removed; (g) backup not written; each must die on its row; kill list in the commit message.
- [ ] **Step 5:** `pre-commit run --all-files`, the table at umask 002 and 077, `check-claude-md`, `check-state-table-totals`, `check-workflow-apt`; push; open the PR (`DO-A Render Claude Code settings from the base and the tenant overlays`, draft, body per the prs skill, deferred minors listed); CI green on HEAD; merge under the standing authorization (branch point current, no `--admin`, body rewritten to the final diff first); fast-forward `~/.dotfiles` (it is on `main` now; re-check first).

### Task 7: Overlays and profiles (dotfiles-local)

- [ ] **Step 1:** copy `merged/settings/{common,quantivly,personal,toysim}.json` to `claude/settings/` (`jq -S` sorted; `jq .` must parse each; confirm `quantivly.json` holds `extraKnownMarketplaces.quantivly` and `autoMode.environment` with only "### Org-wide" lines; `personal.json` may be `{}`). Create `hosts/cilantro.json` `{"tenants":["quantivly","personal","toysim"]}`, `hosts/dev.json` `{"tenants":["quantivly"]}`, `hosts/sol-build.json` `{"tenants":["personal"]}`. Add `link:` for nothing (the renderer reads the overlay in place) and a `shell:` step in `install.conf.yaml` that writes the marker **only if absent**: `[ -e ~/.config/claude-host-profile ] || printf '%s\n' "$(hostname -s)" > ~/.config/claude-host-profile` — with a comment that on dev (`ip-172-…` hostname) the marker is written by hand as `dev` during step 7 of the program. One row in a new `scripts/test-settings-overlays.sh`: every fragment parses, every profile's tenants have fragments.
- [ ] **Step 2:** commit `claude: ship the settings overlays and the host profiles (DO-B)`.

### Task 8: Retire the wire script (dotfiles-local)

- [ ] **Step 1:** delete `scripts/claude-hooks-wire.sh` and `scripts/test-claude-hooks-wire.sh`; drop its `shell:` step from `install.conf.yaml`; README (boundary table row for `claude/settings/`, `hosts/`; "Tests" list; the "register overlay hooks" sentence); CLAUDE.md rule 4 rewritten: the live-store guard is registered by the renderer through `toysim.json`, with the same `[ -r "$f" ] && exec …; exit 0` shape.
- [ ] **Step 2:** `scripts/test-check-links.sh`, `test-zshrc-local-shim.sh`, `test-wt-gc.sh`, `test-settings-overlays.sh` green; commit `claude: retire claude-hooks-wire.sh; the renderer registers the overlay's hooks (DO-B)`; push; open PR `DO-B Ship the settings overlays and host profiles`; hand Zvi the merge command.

### Task 9: Deploy and verify on the laptop (after both merges)

- [ ] **Step 1:** `git -C ~/.dotfiles-local fetch origin main && git -C ~/.dotfiles-local merge --ff-only origin/main && bash ~/.dotfiles-local/install` → marker `cilantro` written; then `scripts/claude-settings-render.sh --check` from `~/.dotfiles` → exit 1 with the diff (expected: `/home/zvi` paths become `$HOME` in hooks, dev's 13 permissions added, `explanatory-output-style` false, `security-guidance` true, refreshInterval 120, the laptop's wrong org-wide auto-mode block replaced by the quantivly one). Read the diff; it must contain nothing else.
- [ ] **Step 2:** `--apply`; `--check` → 0; `jq .env ~/.claude/settings.json` unchanged from before; `~/.dotfiles/scripts/claude-account-dirs.sh --check` 0; a new `claude` session: the comms hook still fires on `gh pr comment --help`; the statusLine still renders; `zsh -ic claude-doctor` shows the Rendered settings ✓.
- [ ] **Step 3:** record in `audit.md` under `## Step 4 deployed`.

Out of scope: dev and sol-build (steps 7 and 8 run the renderer there through host-sync); the memory stores (step 5); S6's auto-mode regeneration on dev.
