# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The secret-guard state table now asserts its own row total, and the two prose copies of it
  (DO-698).** `scripts/test-secret-guard.sh` was the last state table here without an
  `EXPECTED_ROWS` guard, and a row count is what catches a check that silently stopped running:
  every row that still runs passes, and the suite still prints a green total. The drift it was
  missing was already visible in prose — `CLAUDE.md` claimed **182** checks and
  `docs/SECRET_EMISSION.md` claimed **79** against an actual **192**, each wrong since the first
  row added after it was written, and #215 had just corrected both *by hand*. So the guard also
  asserts the documented number, and deliberately does **not** parse it: a regex reading a count
  out of markdown has to guess the shape of an English sentence and fails by matching nothing,
  which reads exactly like a pass. It builds a fixed needle from `EXPECTED_ROWS` instead and
  greps for it, squashing whitespace because `CLAUDE.md` wraps the sentence between the script
  name and the count. A mutation sweep over nine mutants found the first draft reporting "could
  not run" as a **pass** for an unreadable file — an error branch no row had ever taken — which
  is now a row of its own. 192 → 195 checks.

- **rabota's pre-compute no longer fails at every resume (DO-691).** `Persistent=true` makes a
  missed run fire at the instant of thaw, and at that instant the network is not usable yet:
  measured here, all three failures in seven days were `precompute steps failed: sync`, two of
  them in the **same second** as `systemd-sleep` logging "System returned from sleep", the third
  at a boot. `After=network-online.target` does not help — it is a boot-ordering target and is not
  re-evaluated on resume. The cost was never mainly the failed unit: a resumed laptop got **no
  pre-compute at all** until the next 30-minute tick, so the ranked list, inbox plan and census
  were stale for up to half an hour after every resume. `Restart=on-failure` with
  `RestartSec=90s` and a bounded burst retries the transient case into success while leaving a
  real failure (a rejected token, an API refusing us) `failed` where `check-timer-health.sh` and
  the shell prompt report it.

### Added

- **Credentials left in Claude Code transcripts are now scrubbed on a schedule.** An audit on
  2026-09-23 found **154 of 2,344 transcripts carrying live credentials — 521 occurrences**, put
  there by a program logging its own environment. `claude/hooks/secret-emission-guard.sh` is a
  `PreToolUse` hook on `Bash` and cannot observe a program's own file write, so prevention cannot
  close this and periodic scrubbing is what is left. `scripts/scrub-transcript-secrets.py` is the
  file-at-rest half of the pair whose other half is `scripts/redact-secrets.sh`; a daily
  `scrub-transcript-secrets.timer` runs it. **Linked, not enabled** — it rewrites session
  transcripts unattended, which is the exact act the Claude Code permission classifier refuses an
  agent, so arming it is a typed command after one real dry run. Its roots are **derived**, not
  hardcoded: every session gets its own account dir here, and 58 transcripts under
  `~/.local/state/claude-account-dirs/*/projects` had never been scanned by anything. State table:
  `scripts/test-scrub-transcript-secrets.sh` (54 checks, hermetic, run in CI).
  [docs/TRANSCRIPT_SCRUB.md](docs/TRANSCRIPT_SCRUB.md).

- **A failed or skipped repo-owned timer now reaches you without being asked (DO-687).**
  `check-timer-health.sh` asserted that user timers ran and succeeded, but only when someone ran
  `verify-tools.sh` — so a `wt-gc-sweep` that started failing at 04:00, or fell silent under an
  unmet `ConditionPathExists`, was noticed only if a human went looking. A new `--write-state`
  mode records the verdict to `${XDG_STATE_HOME:-~/.local/state}/timer-health/status`, and
  `_dotfiles_live_config_warn` reads it at the first prompt of each interactive shell, printing
  one line to stderr when a timer is unhealthy. **No new systemd unit**: the prompt refreshes the
  file in the background at most every 30 minutes, so the reader and the writer are the same
  event and there is no watcher needing its own watcher. `TIMER_HEALTH_QUIET=1` silences it —
  deliberately *not* `DOTFILES_GUARD_QUIET`, whose documented meaning is "knowingly dogfooding a
  branch" and which would otherwise take timer health down for the length of a feature branch.
  The prompt path is built for a place with no timeout: a FIFO at the state path tests
  `-r`-readable and then blocks a new terminal forever, so the read matches regular files only;
  zsh arithmetic resolves a non-numeric operand *recursively* rather than as 0; and
  `EPOCHSECONDS` is empty without `zmodload zsh/datetime`, so the reader has no clock at all and
  no staleness rule — a threshold there would be a second copy of a schedule that lives
  elsewhere. `--write-state` exits 0 even when timers are unhealthy, because the file is the
  channel and a watcher that fails whenever the watched thing fails pollutes the very
  `--state=failed` signal this feature reads. Evidence, the two adversarial reviews and the
  mutants that survived the first sweep: [docs/TIMER_HEALTH.md](docs/TIMER_HEALTH.md).

### Fixed

- **Timer health no longer reports a mid-run timer as stopped (DO-686).** A timer whose
  triggered unit is running has **no next elapse** — systemd schedules one only once the run
  finishes — and `list-timers -o json` reports `"next": null`, which `jq`'s `// 0` made
  indistinguishable from a genuinely stopped timer's `0`. `wt-gc-sweep.timer`'s first
  unattended run hit it: `Persistent=true` caught up the missed 04:00 run at 07:29, and while
  the sweep was mid-flight the checker called it *"it has stopped firing"*. The state table had
  a row for that branch, but its fixture had the service `inactive`, so it described a state
  the machine never produces — a row pinning the wrong rule rather than a missing row. The
  checker now reads the activated service's `ActiveState` first and asserts nothing about a run
  in progress, since `Result` and `ExecMainStatus` still describe the previous run while a unit
  is activating. Both readings of `next=0` are rows now (77, up from 70).

### Added

- **`verify-tools.sh` now asserts that repo-owned systemd user timers actually RUN.** Unit
  *enablement* was already checked; nothing checked whether an enabled unit ever ran or what
  happened when it did. Measured 2026-09-22, a grep for `state=failed|--failed|is-failed` across
  `scripts/` and `zsh/` returned exactly one line — `backup-doctor`'s, scoped to `*restic*` and to
  the **system** manager. So a failed `claude-cred-reconcile`, `rabota-precompute@` or
  `wt-gc-sweep` sat failed indefinitely. `wt-gc-sweep.timer` had been armed that same day and
  deletes worktrees and branches unattended at 04:00.
  `scripts/check-timer-health.sh` asserts three things per unit, each of which can be false while
  the other two look fine: the last run **succeeded**, the timer is **still firing** on its own
  schedule, and it is not being silently **skipped** — an unmet `ConditionPathExists` makes
  systemd skip a unit with `Result=success` and nothing in `--state=failed`, which
  `wt-gc-sweep.service` is one missing `~/.local/bin/wt-gc` away from. Freshness is derived from
  systemd's own `list-timers -o json` (`now > next + (next - anchor)`) rather than from a
  per-unit table of expected periods that would drift from the unit files, plus a horizon check
  for a mis-specified `OnCalendar` that the staleness rule alone can never catch. Scope is
  repo-owned user units only, via a new `reconcile-systemd-units.sh --list-managed` so "ours" has
  one definition rather than two. Report-only: it fires when someone runs `verify-tools.sh`, and
  a healthchecks-style dead-man's switch is deliberately left as a follow-up.
  State table: `scripts/test-timer-health.sh` (70 checks, hermetic behind a recording `systemctl`
  stub, run in CI; 15/15 mutants killed). Evidence, including what `systemctl` reports wrongly
  about a unit that does not exist: [docs/TIMER_HEALTH.md](docs/TIMER_HEALTH.md).

- **Landed agent worktrees and their local branches are swept on a timer (DO-677).** A session
  spawned by `herdr-draft create --worktree` cannot tear itself down — removing its own worktree
  closes the herdr space it runs in — so its checkout, branch and remote branch were all left
  behind. Measured 2026-09-21: 56 worktrees machine-wide were reapable (~3.3 GB), 41 of them
  under `~/.herdr/worktrees`; a manual sweep on 2026-09-15 removed 27 and herdr-draft alone was
  back to 29 six days later. Branch clutter was the larger half and had no tool at all —
  herdr-draft carried 70 local branches against 27 on origin, only ~24 of which had a worktree.
  `scripts/wt-gc-sweep.sh` plus `systemd/wt-gc-sweep.{service,timer}` run `wt-gc --apply` daily,
  scoped to `~/.herdr/worktrees`, after a two-day grace counted from the **merge** rather than
  the last commit, deleting landed local branches in the repositories that host those
  worktrees and **never** a remote one. `--dry-run` prints exactly what an apply would do —
  `WOULD-REMOVE` / `WOULD-DELETE` / `WOULD-SKIP` with the reason — rather than only what has
  landed, so the list that is approved is the list that runs.
  **It is linked but not enabled**, deliberately: arm it with
  `systemctl --user enable --now wt-gc-sweep.timer` after reading one
  `scripts/wt-gc-sweep.sh --dry-run` in full. On a machine without the private
  `~/.dotfiles-local` the unit's `ConditionPathExists` makes systemd *skip* it, which is not a
  failure. The engine changes are in `~/.dotfiles-local` (`wt-gc` gains `--branches`, `--scope`
  and `--min-age`). Evidence, the branch predicate and the mutation sweep:
  `docs/WORKTREE_SWEEP.md`. State table: `scripts/test-wt-gc-sweep.sh` (21 checks, in CI as
  `wt-gc-sweep-test`).

### Changed

- **Which machine owns which clauth seat is declared once (DO-665).** It used to live in two
  files — `CLAUDE_TENANT_MACHINE_OWNED` in the tenants file (profile → label) and
  `[machines.<m>].profile` in rabota's tenant TOML (machine id → profile) — with nothing checking
  they agreed. They were inverse mappings in different vocabularies, so neither could be derived
  from the other; the tenants file gains `CLAUDE_TENANT_MACHINE_ID`, which is the missing link,
  and `scripts/machines-render` renders the registry on demand for rabota. **The direction is
  the decision:** a stale copy on the dotfiles side fails open and silently (the DO-632 / DO-641
  guards just stop refusing), while rabota fails loudly, so the hand-edited copy stays on the
  silent side and the loud side asks. Nothing is generated to disk — a rendered file is the same
  defect one level down. A fault never arrives as an empty registry, and a leftover `profile` key
  in a `[machines.<m>]` table is refused rather than ignored.
  **Migration, and the order matters.** Add `CLAUDE_TENANT_MACHINE_ID` to the tenants file (safe
  at any time — nothing reads it until this lands), then **delete `[machines.<m>].profile` BEFORE
  deploying**, not after. On the old code a missing key degrades only to "no seat configured" for
  that machine, and only if a remote lane is started; on the new code a *present* key raises at
  config load, so every rabota command — including `rabota doctor` — would exit 2 until the file
  is edited. Reasoning: `docs/CLAUDE_ACCOUNT_PICKER.md`.

### Fixed

- **`rabota census` parsed `wt-gc --tsv` in the wrong column order (DO-677).** The schema is
  `verdict path branch pr dirty unpushed age reason`, eight fields with no header; it was read as
  `path repo branch verdict reason`, so every row recorded the verdict as the path and the path
  as the repo. The fixture encoded the same wrong schema, which is why the tests passed the whole
  time. Rows are now selected by their leading token rather than by position, because the stream
  carries three row types (`STRAY` has two fields, `DANGLING` five). Only an on-demand
  `rabota census` reached it — `rabota precompute` passes `include_worktrees=False`.

- **A tenants file that cannot be read no longer means "nobody owns anything" (DO-674).**
  `claude-tenants-owner` forked a bare `zsh -f`, **ignored its exit status and discarded its
  stderr**, so any file that ran without populating the table read as "not foreign" and every
  DO-641 door stopped refusing, silently. Measured live after DO-665 deployed: CRLF line endings,
  an unterminated quote, a subscript assignment to an undeclared table, a UTF-8 BOM and a
  function-guarded assignment all failed open here while `scripts/machines-render` — the other
  reader of the same file — refused all five with exit 2. **The direction is refuse:** wrongly
  allowing is the DO-641 incident itself, a seat spent silently and invisibly to both machines,
  while wrongly refusing is a named error carrying zsh's own complaint, with
  `CLAUDE_FOREIGN_PROFILE_OK=1` (printed by the refusal, and honoured for the fault too) one
  command away. **No tenants file, and a file that owns nothing, are still real answers** — the
  same split DO-665 made between an unadopted registry and a broken one. Note the cost: on a
  machine whose tenants file is also the pool source, a broken file leaves `claude` with no last
  resort until it is fixed. Also corrects three places that recorded
  `has_command jq && TABLE=( … )` as undetectable — it writes to the fork's stderr, and
  `machines-render` had been refusing it all along — and a `print -u2 … | sed` in both readers
  that indented nothing, because the pipe reads fd 1. Reasoning:
  `docs/CLAUDE_ACCOUNT_PICKER.md`.

- **The account picker's last-resort fallback no longer takes a seat another machine owns
  (DO-632).** When no pool member was usable, `_claude_fallback_profile` handed out clauth's
  *active* profile and consulted nothing — and a profile is absent from every pool on this
  machine for exactly one reason: another machine owns it. It fired on 2026-09-19, putting a
  session in this repo on `personal-1`, nanoclaw's seat. The motivating correlation, stated as
  one: `quantivly-0`'s login was revoked 2026-09-18 22:16 and two laptop sessions were found on
  that seat on 09-19 through a door DO-641 has since closed — but that rejection class cannot
  distinguish a double-spend from a server-side revocation, so the cost is the live hypothesis
  and not a finding. The last resort now asks `claude-profile-foreign`, the same
  five explicit doors use — so `CLAUDE_FOREIGN_PROFILE_OK=1` still borrows on purpose, and the
  tenants file is re-read when the table is not in memory, which is the shell an agent gets.
  **The skip is never silent:** a declined last resort raises a `_claude_pick_warnings` entry
  naming the seat, its owner and what happened instead, and a `_claude_pick_skipped` entry so
  `claude()`'s refusal block prints a reason. Every *other* decline (quarantined, disabled) is
  now reported the same way, where all of them used to be silent. The one change a caller could
  notice: a pick that used to return clauth's active profile can now refuse, and the session
  lands on the shared credential loudly (`claude()`) or is refused (`hspawn`, `--strict`).
  `scripts/test-claude-pick.sh` 452 → 476; 19 mutants, 18 deaths, one equivalent. Reasoning, the
  pinned boundary and what the mutation sweep cost: `docs/CLAUDE_ACCOUNT_PICKER.md`.

### Added

- **`claude-pick --gate` refuses a lane whose weekly window is spent with no spend headroom
  (DO-623).** After every 5h arm, the gate checks the aggregate `seven_day` and each per-model
  window whose label governs `--model`. At or past `CLAUDE_PICK_WEEK_SPENT` (100) a live window
  refuses as the new state **`gate-spend-wall`** when spend is `none`, allows when it is
  `headroom` (the lane bills credits), and refuses as `gate-unmeasured` when spend is
  `unknown` or `disabled` (a Max seat: nobody has watched one run past a spent window, so the
  gate does not assume it will — the user's decision of 2026-09-19, reversing the DO-623
  plan's proposal to allow it; the ranker still only demotes such a seat). An undated or
  unreadable governing window refuses as `gate-unmeasured` too. The `gate` JSON object gains
  three keys: `model_window` (`{label, utilization, resets_at, state}` or `null`),
  `bills_credits` (`true`/`false`/`null` — `null` when no governing weekly figure was read)
  and `spend`. rabota maps `gate-spend-wall` to `credential:window`.
  **The one change a consumer could notice:** `usage.spend` has a new value, `disabled`, for
  `spend.enabled == false`, which read `unknown` before. The reasoning and the open edges are
  in `docs/CLAUDE_ACCOUNT_PICKER.md`.

- **The last six evidence sections left CLAUDE.md, verbatim, and a `docs/` index was added
  (DO-627).** 55,033 chars moved in ten slices: GitHub account routing to
  `docs/GH_ACCOUNT_ROUTING.md`, the backup guards to `docs/BACKUP_INTERNALS.md`, the transcript
  secret-emission guard to `docs/SECRET_EMISSION.md`, the broadcast-kill tripwire to
  `docs/AUDIT_TRIPWIRE.md`, the Alacritty and `$TERM` gotchas (two fragments, one subject) to
  `docs/TERMINAL_AND_KEYS.md`, and the shell-layer elaboration to `docs/SHELL_LAYOUT.md`; the GNOME
  and mise records were appended to the guides that already own their subject. CLAUDE.md is now
  **44,165 characters**, from 85,140 at DO-626 and 353,845 at the start — a 48% cut here and 87.5%
  overall. Every slice is proven identical to `main`'s by reconstruction (10 of 10, modulo two link
  rewrites and the six end-of-file blank lines `pre-commit`'s `end-of-file-fixer` normalises);
  `check-doc-tokens.sh`: 70 tokens, 0 lost.

  **Measured before merging, as DO-625 required.** Backup, GNOME, mise, the secrets guard, the
  tripwire and the terminal gotchas each share 0–2.4% of their 8-word runs with the existing guide
  nearest them — so nothing was already duplicated, and the split is by *audience*: a guide is for
  someone adopting or operating a thing, a maintainer's record is the evidence behind a rule that
  stays in CLAUDE.md. `docs/README.md` now indexes all 25 pages under that distinction, names which
  skills are project- versus user-scope, and is linked from CLAUDE.md so the reachability guard can
  see it.

  **It did not reach the ~20k target, deliberately.** What is left is 44k of operative rules and
  routing, not evidence: no section over 3.3k remains, and the four largest are residues from this
  and the previous three PRs. Cutting further would have meant deleting rules to hit a number, which
  the budget's own `FLOOR` of 20,000 exists to make unnecessary.

  **Non-verbatim, and therefore the part a human must read:** the "Modular Configuration System"
  numbered list became a table (and its stale "4 modules" is now the correct 5), and each residue is
  newly written rather than excerpted. Three stale facts were corrected in passing:
  `scripts/test-gh-routing.sh` reports 207 checks and `scripts/test-secret-guard.sh` 182, not the
  199 and 79 CLAUDE.md claimed, and `docs/TOOL_VERSION_UPDATES.md` still said the mise config is
  *copied* to `~/.config/mise/config.toml` — the very claim the record appended beneath it exists to
  correct.

- **The deploy, `safe.directory` and CI/CD evidence left CLAUDE.md, verbatim (DO-626).** 48,031
  chars moved: "The checkout IS the deployment" and the DO-589 `safe.directory` write-up to
  `docs/DOTFILES_DEPLOY.md`, and "CI/CD Testing" — the DO-608 apt outage, the seventeen defects
  three review rounds found in one checker under a green suite, the YAML-parser rewrite and the
  mutation rounds — to `docs/REPO_CHECKS.md`. CLAUDE.md is now 85,140 characters. Both sections are
  proven identical to `main`'s once the one link rewrite and the heading promotions are undone;
  `check-doc-tokens.sh`: 85 tokens, 0 lost. What stayed inline is what an agent *runs*: the deploy
  procedure as a command block (fetch, check the incoming diff against dirty paths,
  `merge --ff-only`, `./install` — never `git pull`, never `git stash`), the worktree convention,
  "the merge record decides whether a branch landed", the run-locally block, the apt-install rule,
  and the row-quality rules that recur across every guard. The heading "The checkout IS the
  deployment" stays in CLAUDE.md because the only inbound anchor in the repo points at it.

- **CLAUDE.md is under Claude Code's 150k warning: the herdr section moved to its own maintainer
  doc, verbatim (DO-625).** 47,594 chars went to `docs/HERDR_INTERNALS.md` — install paths, the unit
  and its drop-in, the sidebar publisher, every trap with its evidence — and CLAUDE.md is now
  129,299 characters (from 353,845 two PRs ago). The plan said to *merge* this into
  `docs/HERDR_GUIDE.md` to avoid a third copy; **measured first, that premise was false**: only
  1.6% of the section's 8-word runs (119 of 7,358) and 4 of its 100 bold claims appear in the
  guide. They are two documents for two readers — the guide for a teammate adopting herdr, the
  section a maintainer's record of traps — and merging would have buried 48k of forensics in the
  adopter guide. So it moved to its own page, linked from CLAUDE.md and from the guide, and the copy
  count is unchanged. Proven identical to `main`'s section once the one link rewrite is undone;
  `check-doc-tokens.sh`: 100 tokens, 0 lost. Thirteen operative rules stay inline (never run bare
  `herdr`, never restart the server from a pane, never `reenable` a dotbot unit, close what you
  spawn but never a teammate's pane, and so on).

- **The Claude Code accounts section left CLAUDE.md for `docs/`, verbatim, and its rules stayed
  (DO-622).** 180,896 of CLAUDE.md's 353,845 chars moved to `docs/CLAUDE_ACCOUNTS.md` (the
  credential mechanism and its incidents) and `docs/CLAUDE_ACCOUNT_PICKER.md` (the picker and the
  tenant table); CLAUDE.md is now 174,761. **Verbatim was the decision that mattered**: a rewrite
  quietly shortens arguments, and no mechanical check can see that loss — so the moved text was
  proven identical to `main`'s, modulo two link rewrites, two heading promotions and two boundary
  blank lines, by rebuilding the section from the docs and diffing. What stayed inline is the ten
  operative rules an agent needs *before* acting (run `claude-doctor` first, never
  `clauth <profile>` while the stored copy differs, never relink a credential, name the account
  from `CLAUDE_CONFIG_DIR`, …), because nanoclaw's IMP-2778 measured an extracted reference corpus
  at zero reads over 102 runs. A `claude-accounts` project skill carries the diagnostic procedure —
  read-only until the last step — and routes into the docs by section name; skill bodies load on
  demand, which the DO-620 probe measured (87 skills, 9.1k tokens, descriptions only).
  `scripts/check-doc-tokens.sh` (CI) asserts every ticket, date, script path, PR reference and
  heading in the base CLAUDE.md still resolves in `CLAUDE.md`/`docs/`/`.claude/` — **not**
  `CHANGELOG.md`, where a token survives only by being cited — plus a 10% bound on total doc
  volume; deliberate retirement is a line in `docs/RETIRED.md`, not a bypass flag. It says what it
  cannot see: ~one anchor per 36 lines, and nothing at all about a paraphrase. State table:
  `scripts/test-doc-tokens.sh`, 33 checks; 9 mutants, 9 deaths — one only after a row was added,
  because a *demoted* heading still contains the original as a substring, so only a *promoted*
  one can tell "level ignored" from "level must match". The ~50 code comments citing "CLAUDE.md
  records X" are left for one pass once every section has moved, rather than repointed twice.

- **CLAUDE.md now has a context budget that can only tighten, and a written rule for what
  may go in it.** The file is loaded in full into every request of every session. It held
  14k–36k chars for eight months and then went **35,682 → 350,324 in the nineteen days from
  2026-08-30 to 2026-09-18** — every PR appending its own review narrative (+26,499 for #160,
  +21,404 for #134, +20,758 for #135) — which is ~87k tokens per request, and the documented
  reason for Claude Code's 150k warning is that longer files *reduce adherence*, i.e. the file
  stops producing the behaviour it was written to produce. The one-off cut has already been
  tried here (2026-01-07, `Streamlined CLAUDE.md to reduce size by 62%`, 32.6k → 14.2k) and it
  **regrew 25×**, so the ratchet is the deliverable and the cut is secondary — this change
  deliberately clears nothing. `scripts/check-claude-md.sh` (CI job `CLAUDE.md Guard State
  Table`, plus a pre-commit hook) enforces eight rules: the CLAUDE.md ceiling, the aggregate
  over every always-loaded surface, per-file caps on rule cards and `SKILL.md`, frontmatter
  validity, relative-link resolution, reachability, and that no rule card carries `paths:`.
  **The ceiling is derived, not written down** — `max(FLOOR, min(size over
  base-branch commits that also carry the guard) + SLACK)` — because every design where a human
  types the ceiling into a file has the same hole: the PR that breaks the rule edits the number
  in the same diff. There is no value to raise; the only way to raise the ceiling is to lower
  CLAUDE.md and merge. It is a ratchet rather than a rate limit because a minimum cannot be
  lowered by a larger commit, so SLACK is a one-time buffer (parent-size + slack at ~1 PR/day is
  ~550k/year, i.e. the pathology slightly slowed). The anchor is self-referential — only commits
  carrying the guard count — so it needs no date, tag or SHA, none of which the introducing PR
  could name. `FLOOR` exists because a ratchet with no floor eventually forbids all edits and one
  accidental truncation would pin the minimum near zero, and a permanently-red checker gets
  deleted, which this repo has now recorded seven times.

  Three findings from building it, each of which reported success first. **`awk` is mawk here
  and on Ubuntu**, where gawk's three-argument `match()` is a syntax error — paired with the
  `2>/dev/null || true` the first draft had, the link extractor produced **zero links** and the
  link and reachability rules reported a clean tree they had never read. It is POSIX
  `index()`/`substr()` now, errors are not suppressed, and `links_selftest` asserts the extractor
  against known answers before any rule trusts it, because a checker that silently extracts
  nothing reports a perfect tree. **The aggregate cannot share the CLAUDE.md ceiling**: doing so
  leaves the whole rule-card layer `SLACK` (1,500 bytes) — one card, ever — so the first card
  spends the budget and every later area has nowhere to put its trigger rules except back in
  CLAUDE.md; `AGGREGATE_EXTRA_BYTES` (18,000, nine cards at the cap) is its own allowance, and
  counting cards is not pessimism but accuracy, as the measurement below shows. And **a
  5,000-byte `SKILL.md` cap, which an earlier
  draft proposed, would have failed every skill on this machine** (measured: herdr 10,553,
  rabota 17,539, zvi-voice 11,883, `quantivly-conventions:linear` 29,335, `:prs` 26,696) — it is
  30,000, with `references/`, `scripts/` and `assets/` under a skill deliberately uncapped,
  because capping them punishes the progressive disclosure the house style already uses.

  **A `paths:`-scoped `.claude/rules/` card never loads, measured rather than assumed, and the
  first version of this guard REQUIRED one.** The plan leaned on path-scoped cards as a cheap
  on-demand layer — documented, and present in the installed 2.1.277 binary (`.claude/rules` ×10,
  a `rulesDir` symbol, `"paths"` ×19). So it was measured in a throwaway herdr pane before anything
  depended on it, with unique probe phrases and a fresh session per round: a card **without**
  `paths:` loaded at project and at user scope; a card **with** it did not load at session start,
  did not load after the session read a matching file, and did not load in any spelling tried —
  block list, inline array, or a literal file path instead of a glob. `/context` agreed: "Memory
  files: 3" before and after the matching read. A guard that requires `paths:` therefore
  guarantees every card is inert, which is a rule silently switching off the thing it polices.
  The rule is inverted: a card may not carry `paths:`, cards are unconditional, and the aggregate
  rule counts them because they are always loaded. The one card this PR shipped is gone — scoped,
  it was dead; unscoped, it was always-loaded text restating CLAUDE.md, which the single-home rule
  forbids. The same probe put CLAUDE.md at **130.4k tokens**, not the ~87k a chars/4 estimate gave;
  at ~2.7 chars/token this file is costlier than it looked. Every probe card was removed and the
  pane closed; an unconditional user-level card loads into every session on the machine.

  The governing rule for what moves, taken from nanoclaw's IMP-2778 rather than invented: **this
  discipline governs where elaboration lives, not where the rule lives.** nanoclaw measured a
  22-file extracted reference corpus at **zero production reads over 30 days and 102 runs**,
  including a file cited with "You MUST read", and measured that relocating 181 lines behind a
  pointer improved every budget number while leaving the session's loaded context unchanged and
  137 tests green. So the threshold, the decision and the emitted line stay in CLAUDE.md and only
  the evidence moves; a rule whose condition can no longer fire is **retired, not extracted**;
  and the reachability rule exists because an unrouted file is an unread file — it immediately
  found `docs/CLAUDE_SETUP.md`, which had zero inbound links and is now routed. The pre-commit
  hook **warns and passes** when it cannot evaluate the budget rather than failing, because
  nanoclaw measured that a gate failing in an unevaluable state teaches `--no-verify`, which
  disables every other hook.

  State table: `scripts/test-claude-md.sh` (**77 checks**, CI job `claude-md-test`), hermetic —
  every row builds its own git repository with real commits, because the ratchet reads real
  history and a mocked one would pin nothing about the only rule that cannot be checked another
  way. **18 mutants, 18 deaths, 0 survivors, 0 harness errors** (plus one retired: its target was
  removed as a duplicate guard, since two guards for one property are individually unkillable),
  every mutation dry-run for
  applicability first since a mutation that no longer applies reads exactly like a surviving
  mutant. Three survived the first sweep: two were badly-constructed mutants that changed no
  behaviour (`m=$2` unconditionally still yields the minimum, because `rev-list` is newest-first),
  and the third was real — `exit` and `next` on the history scan are indistinguishable unless the
  guard is deleted and re-added, a shape no fixture had, so row B10 now pins it. The `CLAUDE.md
  unreadable` row uses a **directory** named `CLAUDE.md` rather than `chmod 000`, because CI
  often runs as root and reads mode-000 files, so a chmod fixture cannot reach the branch it
  names. The suite's own total catches a row that vanished; it does **not** catch a hollow rule —
  one still called, still counted, always returning ok — and only review does.

- **The Claude account picker scores headroom instead of sorting on utilization, and
  `claude-pick` exposes it as a command (DO-574).** The old ranking was the worse of the 5h
  and 7d utilization, then live holders, then name — so an account at 3% of a 5h window that
  resets in four minutes outranked one at 20% with the whole window ahead of it, and every
  session starting in the same quiet minute landed on the same seat, because a deterministic
  sort has no memory. `_claude_pick_for_dir` is now one code path — resolve → candidates →
  classify → score → exhaustion → backpressure → ledger — shared by `claude()`, `hspawn` and
  the new `scripts/claude-pick` (symlinked to `~/.local/bin/claude-pick`, so the herdr
  server's frozen `PATH` finds it). The score is 5h headroom, plus a use-it-or-lose-it bonus
  scaled by *both* headroom and closeness to the reset, times weekly headroom as a
  multiplier, minus crowding that costs more on an account already busy; ties inside
  `CLAUDE_PICK_RR_BAND` break by least-recently-picked under a lock, which is what stops the
  pile-up. Classes are tiers rather than scores: `excluded` is never chosen, `unknown` (no
  usage cache, or one past `CLAUDE_PICK_CACHE_MAX_AGE`) ranks after every measured candidate
  but is still chosen when nothing else remains, and `exhausted` is where the callers
  deliberately differ — an interactive `claude` proceeds on the least-bad member with a loud
  block, while `hspawn`, `claude-pick --strict` and herdr-draft refuse and name each
  member's reset time. `claude-pick`'s exit codes are the contract: 0 picked, 2 exhausted,
  3 a machine ceiling, 4 an unusable tenant table, 5 no credential, 64 usage.
  Machine backpressure is measured and warned about but **never refuses** unless
  `CLAUDE_PICK_LOAD_MAX`/`_SWAP_MAX` is explicitly set. Three approved-spec items were
  changed on measurement and the reasons are in CLAUDE.md: the weekly window demotes rather
  than refusing (zero weekly-reset refusals in 750 transcripts, against 34 individual
  spend-limit messages in 24 h, whose remedy is an admin and not a rollover);
  `CLAUDE_PICK_CACHE_MAX_AGE` stays 3600 and the planned `claude-usage-refresh.timer` is
  dropped, because clauth has no refresh entry point for it to call; and an already-reset
  window earns no expiry bonus. `claude-doctor` gains a usage-cache freshness line, since a
  stale cache silently removes a profile from the ranking and nothing else reported it.
  Two bugs found on the way out are worth their own mention: `zsystem flock` opens without
  `O_CREAT`, so the pick lock had never once been acquired while the row covering it
  asserted the warning that broken state produces; and `strftime -r` parses through
  `mktime`, which reads a broken-down time as local and discards the offset, so every reset
  instant was wrong by the machine's UTC offset — up to 60% of a 5h window, and it shifted
  every reset time the messages print. `CLAUDE_ACCOUNT_CACHE_MAX_AGE` is gone; the knob is
  `CLAUDE_PICK_CACHE_MAX_AGE`. New `scripts/test-claude-pick.sh` (CI job
  `claude-pick-test`), with rows added to `scripts/test-hspawn.sh` and
  `scripts/test-claude-doctor.sh`.
- **gh routes a work-tree directory with no GitHub remote to the work account
  (`GH_ACCOUNT_PATH_ROUTES`, DO-596).** `~/quantivly/qspace` holds two work repositories
  and is itself none, so the remote rule had nothing to say and the personal default
  answered — inside the work tree. On 2026-09-09 a Claude Code session started there
  inherited the personal `GH_TOKEN` and `GITHUB_PERSONAL_ACCESS_TOKEN`; its Bash-tool
  shells (`zsh -c`, no `.zshrc`) kept them and the GitHub MCP plugin's bearer header was
  fixed to them at startup, so every private work repository 404'd for the life of the
  session. A path route is consulted only for a directory with *no* GitHub remote — not a
  repository, no remotes, or only non-GitHub ones — and never for one that has a remote,
  matched or not: precedence is remote owner route → path route → default, so a
  personal-remote repository under `~/quantivly` stays personal exactly as git identity
  signs it, and work repositories outside the tree (`~/.dotfiles`) still route by remote.
  `git-error` still stops before any of them. The table is validated whole (a relative
  prefix is `bad-table`, not `$PWD` routing by typo), the match is by resolved path
  component (`~/quantivly-other` is not under `~/quantivly`), `_gh_configured_dirs` lists
  the route's dir so the refresher caches its token, and `gh-doctor` names the route.
  A GitHub URL the parser rejects is a GitHub remote nobody can read, not "no GitHub
  remote": it blocks the path table and the default answers, as before, and `gh-doctor`
  lists it as a ⚠. A dir named by both tables keeps both reasons in the doctor's table
  (`route 'quantivly' + path route '~/quantivly'`), and a prefix that does not exist on
  disk is a ⚠ that can never fire — an independent review found the path table entirely
  invisible to the doctor on the shipped configuration, since it shares the owner route's
  dir. `~user` prefixes are `bad-table`. Forty-seven new checks in
  `scripts/test-gh-routing.sh` (152 → 199), including the guard rows that pin the
  precedence.
- **`dotfiles-doctor` names a `safe.directory`-polluted gitconfig, and says which entries are
  dead (DO-589).** `~/.gitconfig` is a symlink into the checkout and `git config --global`
  writes through it, so a `safe.directory` entry added by anything lands in a tracked file in
  a public repo — seven did in five days, each an absolute path carrying an agent session
  UUID, and no agent typed one: auto-conf's `configure.py` adds one for every workspace it
  builds, and its dedup does not understand the `~/*` glob that already covered them. The
  doctor reads the file the link map says `~/.gitconfig` points at from the worktree, the
  index and HEAD (a staged entry is one commit from public; an index-only one is invisible to
  a read of the file), with `--no-includes` on every read because the entries *belong* in the
  included `~/.gitconfig.local`. Each entry is labelled by git's own reading of the value
  (`--type=path` for `~`, `~user/` and `%(prefix)`; only `*` and a trailing `/*` are patterns;
  an empty value is the list reset; a relative path is ignored) and probed with the list reset
  and by exit status, never by matching git's translatable messages: `same owner`,
  `other owner`, `not matched`, `not a repo`. Uncommitted entries are a ✗ with
  `git restore --staged --worktree -- gitconfig` — a bare `restore` copies the index and is a
  no-op once the entries are staged — and committed ones a ⚠. The generic `⚠ M gitconfig`
  becomes a pointer only when worktree and index differ from HEAD by nothing else, decided by
  stripping the entries with `git config --unset-all` and comparing bytes rather than parsing
  a diff that `color.ui` or `diff.external` can reshape. An unreadable file, index copy or HEAD
  copy is `UNKNOWN` or "fix HEAD first", never a tick and never a restore that would install
  the broken copy. A `PreToolUse` hook on the `git config` text was considered and dropped: it
  would have matched none of the seven, because the write happened inside a subprocess.
  63 rows in `scripts/test-dotfiles-guard.sh`, one of which runs the printed fix and asserts
  the tree is clean; 33 mutants, all killed. `other owner` is reached without root via
  `GIT_TEST_ASSUME_DIFFERENT_OWNER=1`. The `gitconfig` and `gitconfig.local.example` comments
  now state the git versions correctly (`*` needs 2.35.2, a trailing `/*` needs 2.46) and
  point at docs/TROUBLESHOOTING.md for the calls. The cause itself is upstream, in auto-conf.

- **`gh-doctor`: which GitHub account is `gh` *actually* using here?**
  `gh` keys its tokens in the system keyring by **host**, not by config dir, so
  `GH_CONFIG_DIR` isolates `hosts.yml` and nothing else: three config dirs declaring
  three different accounts all resolved to one, and `gh auth status` kept reporting the
  declared one throughout (`gh-personal` said `ZviBaratz` while the API answered
  `zvi-quantivly`). The fallback direction is the bad one — with `GH_TOKEN` unset, a
  personal repository silently gets **work** credentials while git correctly signs its
  commits as personal. A status command describing intent rather than effect, the same
  shape as the `backup-doctor` bug and the live-config guard's false all-clear.

  `gh-doctor` (`zsh/functions/github.sh`) reports, for a directory: the account the
  repo's **remote** routes to, the account gh **declares**, the account a real
  `GET /user` **returns**, and which mechanism decided. It then probes each config dir
  twice — once with the token env cleared, which reproduces the collapse, and once
  pinned with `gh auth token --user <login>`, which does isolate — so the workaround is
  demonstrated rather than asserted. `--offline` marks every network answer NOT CHECKED
  instead of omitting it.

  Routing keys on the repo **remote**, matching git identity (#67,
  `hasconfig:remote.*.url`), and consults **every** remote rather than just `origin`, so
  a fork whose upstream is the work repo routes the same way git already signs it.
  Configuration is data: `GH_ACCOUNT_ROUTES` / `GH_ACCOUNT_DEFAULT_DIR`, set in
  `zsh/zshrc.company` and consumed by both `gh-doctor` and the `chpwd` hook — see the
  routing entry under **Changed**, which is where the account selection actually moves.

  State table: `scripts/test-gh-routing.sh` (145 checks, new CI job
  `gh-routing-test`, hermetic — `gh` is stubbed, so no network, no keyring, no account).
  The rows that already caught something: `env VAR=x some_shell_function` (env execs a
  binary) and `env GH_TOKEN=x -u GITHUB_TOKEN gh …` (env stops parsing options at the
  first operand, so it ran a program called `-u`), both of which surfaced as *"could not
  resolve the account"*; `${~pat}` doing tilde expansion as well as globbing, so a route
  pattern starting with `~` aborted the whole lookup; zsh's `local NAME` on an
  already-local name being a DISPLAY command, which printed `du=zvi-quantivly` into the
  middle of the report; and a route whose config dir does not exist being reported only
  when it happened to match.

  `scripts/test-dotfiles-guard.sh`'s "every doctor declares its counters local" sweep now
  sources every `zsh/functions/*.sh` rather than only `system.sh` — `gh-doctor` is the
  first doctor that does not live in that file, and the sweep exists precisely so a new
  one is covered the moment it is written.

### Added

- **Keeping secrets out of transcripts** (`scripts/redact-secrets.sh`,
  `claude/hooks/secret-emission-guard.sh`). An audit found *both* of this machine's live
  GitHub tokens in plaintext in five Claude Code session transcripts — two written days
  earlier, SHA-256-matched against the live values. Transcripts are conversation context,
  so those values had left the host as well. Nothing dramatic caused it: ordinary
  diagnostics print secrets (`ps` on a process launched with `-e GH_TOKEN=…`, a `printf` of
  `$GH_TOKEN`, a bare `gh auth token`) and everything printed is recorded.

  Rotation cannot be the answer: for GitHub it is browser-only (`gh auth` has no `revoke`,
  `/authorizations` and `/applications/grants` are 404 since the API was removed in 2020,
  and the endpoints that can revoke need the OAuth app's own client secret), and it does
  nothing about the next capture. `gh auth logout` looks like rotation and is not — it
  drops the local copy while the leaked value stays valid.

  So: a redaction filter and a `PreToolUse` hook that refuses the shapes that print
  credentials unless piped through it. **Two redaction rules, because either alone leaks** —
  shape matching cannot know `CLAUDE_CODE_MESSAGING_TOKEN=b7dc…` is a secret (32 hex is also
  every short git SHA), and name matching only sees `VAR=value`. Deny rather than ask, since
  the remedy is mechanical and a prompt just trains people to click through. **Fail open
  everywhere**, including when the hook file is not deployed yet: registering it without a
  `[ -r "$f" ]` guard put `exit 127` on every Bash call in every session on the box until
  that was fixed, which is the deployment coupling this repo keeps relearning.

  Most of the 51 state-table rows assert what it must **not** block — `ps -o comm=`,
  `env -u GH_TOKEN … gh api user`, `git commit -m "stop ps aux leaking"`. A false positive
  costs the whole guard, because a hook that refuses ordinary commands is deleted within a
  day; a miss costs one redaction. New CI job `secret-guard-test`. Fixture credentials are
  assembled at runtime so the test file cannot trip the repo's own scanners over its own
  data — the first version pasted in a real session token and spelled a private-key header
  out in full, and `gitleaks` and `detect-private-key` caught both.

  `.gitignore`'s `**/*secret*` rule excluded all three files on the first attempt, and
  `git add -A` skips ignored paths silently — commit, push and PR creation all succeeded
  with the content missing, and only CI noticed. Negations added; verify such a fix with
  `git add --dry-run`, since `git check-ignore -v` exits 0 for a negation match too and so
  reports the opposite of the truth.

  It is a papercut guard, not a boundary — any command can print a secret and this knows six
  shapes. The durable fixes are a shorter-lived credential and narrower scopes.

### Fixed

- **The gh token cache is replaced, never truncated (`_gh_cache_write`, DO-596).** Both
  writers — the refresher every interactive shell start spawns, and `gh-refresh-tokens` —
  rewrote the live cache files with `printf > file`, which truncates before it writes, and
  set mode 600 only afterwards. The hook reads those files at shell start, at the first
  prompt and on every `cd`, so a shell starting while another shell's refresher was
  mid-write read an *empty* token and started unpinned — and a Claude Code session
  launched from it carried no GitHub credential at all, for its whole life. herdr's
  `pane run` and Herdmates teammates start several panes at once, which is that state;
  the files were rewritten twice in twenty minutes while this was being diagnosed. The
  writer now creates a temp in the same directory and renames it into place: a reader
  sees the old token or the new one, never nothing. The chmod before the rename guarantees
  the live file's mode; `umask 077` only closes the moment before it, inside a 700
  directory. The temp is named by the real PID (`sysparams[pid]`): `$$` and `$RANDOM` are
  both inherited unchanged across a zsh fork, so the disowned shell-start refresher and a
  foreground `gh-refresh-tokens` would otherwise share one temp name and the loser would
  print a false ✗. A directory at the cache path is refused rather than having the token
  `mv`'d *into* it with a ✓. It lives outside the opt-in gate, where `gh-refresh-tokens`
  already is. Two state-table rows tell a replace from a truncate by the live file's inode,
  a third refuses any truncating redirect onto a live cache file at the source, and three
  more pin the PID source and the directory refusal — the inode rows needed one fixture HOME
  each, since a leftover refresher from an earlier row can free the recorded inode and hand
  it straight back to the new temp.
- **A flaky row in `scripts/test-gh-routing.sh`** — "a config dir named like a legacy key
  survives the purge" failed roughly one run in five under load, which by that suite's own
  standard ("a flaky row in a suite about silent failures is worse than no row") makes the
  whole table less believable.

  Every `hookrun` row sources `zshrc.company`, whose token refresher starts with `&!` —
  **disowned, so it outlives the shell that spawned it** — and all those rows share one
  fixture `HOME`. This row is the only one that changes the routing table mid-flight, so a
  leftover refresher from an *earlier* row, still holding the old table, does not know
  `personal` has become a configured basename and purges the entry this row just wrote.
  A private `HOME` removes the shared state the race needs: 8 runs under 8-way CPU load,
  0 failures, against a harness that produced 2 failures in 9 before.

  Two earlier fixes were wrong because they were guesses rather than measurements — raising
  the `gh config get` timeout (forcing it to 1 ms did not reproduce the failure at all) and
  a barrier against this row's *own* refresher (it synchronises against the wrong process).
  Both are recorded in the comment so the next reader does not retry them. No production
  bug: overlapping refreshers on a real machine always share a table, so a purge can only
  remove what that table does not name.

### Changed

- **gh account routing keys on the repo remote, and pins the account instead of hoping.**
  `_update_gh_config` asked `$PWD` first (`~/quantivly/**`, then the `origin` remote), which
  is exactly the signal #67 moved git identity *off* — so gh and git could disagree about
  the same repository: a quantivly clone outside `~/quantivly/` got the personal account
  from gh and the work identity from git. It now uses the same `_gh_route_for` `gh-doctor`
  uses (one implementation, so the oracle cannot drift from the thing it checks), consults
  **every** remote like git's `hasconfig:remote.*.url`, and exports `GH_TOKEN` — because
  `GH_CONFIG_DIR` alone leaves the host-keyed keyring to choose, and it chooses work.

  Every directory now pins an account explicitly. Outside a repo the routing falls through
  to `GH_ACCOUNT_DEFAULT_DIR` (personal), which is what git identity does there too, and is
  deliberately silent: `$HOME` is a shell's normal resting state, and warning on every `cd`
  into a non-repo directory is how a warning stops being read. The loud path is reserved
  for states where nothing *can* be pinned — no default configured, an unusable routing
  table, or a routed account with no cached token — printed at most once per distinct
  message per shell, and never before the first prompt (output during initialisation lands
  inside p10k's instant-prompt warning box).

  The token cache is keyed by config-dir basename (`gh-quantivly`, `gh-personal`) rather
  than by nickname, so the routing table is the single place an account is named.
  `gh-refresh-tokens` and the shell-start background job are both driven by
  `_gh_configured_dirs` and both delete the old nickname-keyed files, which would otherwise
  remain as a second, never-refreshed copy of a live credential. The first shell after this
  lands may report "account NOT pinned" once, before its background refresh completes.

- **Build/test parallelism caps now key on `$HERDR_PANE_ID`, not `$ATRIUM_SESSION`.** An
  unset gate selects the LOOSE tier, so once Atrium stopped running every agent pane
  silently got the half-the-cores budget meant for a solo human — the exact
  over-subscription `zsh/zshrc.buildlimits` exists to prevent, presented as a config file
  that still looked correct.
- **`apply-gnome-settings.sh` now says when the machine-specific layer overrides the portable
  one** (`scripts/apply-gnome-settings.sh`). Both layers log a plain `✓`, so a `~/.gnome-settings.local`
  line that undoes a setting three lines after the portable layer applied it was invisible: two
  successes that cancel, reported as two successes. That is exactly how `grp:alt_shift_toggle`
  stayed enabled — `apply_input_sources` cleared it, the local file re-enabled it every run, and
  all four of herdr's `alt+shift+arrow` bindings were dead for as long as they had existed while
  `gnome-apply` reported success and `gsettings get` showed the override as though it were the
  applied value. An overriding set now reads `✓ key → value  (overrides <previous>, set above)`.
  A NOTE rather than a warning, deliberately: overriding is what that layer is *for* — the
  workspace-switch keys are legitimate overrides — and a warning on each would be noise in the
  normal case, which is how a diagnostic becomes one nobody reads. `GNOME_LOCAL_OVERRIDES` makes
  the path injectable so the behaviour can be exercised against a fixture.

- **`umask`: 022 while the login group is actually shared.** Ubuntu's `pam_umask` relaxes
  022 to 002 whenever the login group is named after the user, because such a group is
  normally yours alone — and `dev-setup` breaks that by adding the `quantivly` service
  account to it (`zvi:x:1000:quantivly`). Under 002, nearly every file the user created was
  group-writable by an account that never logs in, `$HOME` dotfiles included; `.zshenv`
  that way is a code-execution path. Nothing reported it, because 002 on a user-private
  group is the correct, expected value.

  `_dotfiles_umask_guard` reads the login group's member list and tightens only while
  someone else is in it — gated on the condition rather than on the order the fixes were
  applied in, so it is right before *and* after `gpasswd -d`, stops firing by itself once
  the grant is removed, and leaves sharing alone on hosts where the reverse grant is
  load-bearing (a blanket `umask 022` in a repo that installs on other people's machines
  would break exactly those). Forkless (`$(<file)` and `$GID`, never `getent`) at 0.5 ms
  per shell. "Cannot tell" leaves the umask as the system set it and says so.
  `dotfiles-doctor` reports the verdict; `DOTFILES_UMASK` overrides.

- **Review follow-up: eight defects in the above, found before merge.** Each reported
  success, which is the criterion the state tables are written against; each is now a row
  that fails when the fix is reverted.
  - **The gh invocation moved from `env VAR=val` argv to a subshell environment.**
    *Corrected below* — the first version of this entry called it a live credential leak
    "for the length of the call", which is wrong: `env` consumes its assignments and then
    execs, so the token never reaches the exec'd program's `/proc/<pid>/cmdline`. The real
    payoff is retiring the whole `env`-argv class, which had already produced two bugs
    here.
  - **git's exit status was discarded**, so 128 ("cannot read the repository" — a malformed
    `~/.gitconfig` does it, and `~/.gitconfig` is a managed symlink in this repo) read as
    "not a git repository" and routed a quantivly clone to the *personal* account, on the
    one path that deliberately does not warn. `git-error` is now its own state and stops.
  - **The first-prompt hook replayed a stale message instead of re-running the routing.**
    The startup call routinely loses the cache race it is meant to lose; replaying left
    `GH_TOKEN` unset for the life of that shell, putting every `gh` call back on the
    keyring default inside a personal repo.
  - **`GITHUB_TOKEN` was never cleared** alongside `GH_TOKEN`; gh ranks it second, so an
    inherited one authenticated as a third account while the warning blamed the keyring.
  - **`gh-doctor <dir>` compared that directory's route against the current shell's
    account**, producing a confident ✗ ("land under the wrong account") for a state that
    cannot occur — on the documented `gh-doctor ~/some/repo` form.
  - **The legacy-nickname purge ran after the write loop**, deleting a token it had just
    cached whenever a config dir was named `quantivly` or `personal`.
  - **`umask 022` is an assignment, not a tightening**, so on a host hardened to 077 the
    guard *loosened* it and the doctor printed `✓ 022`; and `$(( ))` yields decimal where
    `umask` parses octal, so the union set `0o63` from 077 and errored `bad umask` from
    002. An invalid `DOTFILES_UMASK` was reported as applied, with its error emitted during
    initialisation — inside p10k's instant-prompt box.
  - **`dotfiles-doctor` reset the umask of the shell it ran in.** The decision is now
    `_dotfiles_umask_verdict`, which decides without applying.

  Also: `_q_is_work_context` was dead (its only caller was the branch this PR deleted) and
  the comment added here claimed otherwise — both removed; an explicit
  `GH_ACCOUNT_ROUTING_OFF=1` replaces the capability the Atrium deferral provided, without
  the sniffing that made it dangerous; the `TROUBLESHOOTING.md` reproduction used
  `GH_CONFIG_DIR=~/...`, which **zsh does not tilde-expand in a command word**, so every
  row printed the same keyring default for entirely the wrong reason.

- **Second review round: fifteen more defects, including three vacuous tests.** The first
  round's fixes were themselves unreviewed, and the second round found that three of the
  new state-table rows could not fail — the criterion this repo cares about most.
  - **CORRECTION to the entry above.** `env VAR=val prog` does **not** put the assignment
    in `prog`'s `/proc/<pid>/cmdline` — measured. `env` consumes it and execs; the token
    was in argv only of the short-lived `env` process, between fork and exec. That is a
    microsecond race, not the lifetime of the call, and not the same shape as the 28-day
    tmux server. The subshell fix stands (it closes the race and retires the `env` class),
    but the severity claimed for it did not. The `/proc` test rows would also have passed
    under the old implementation; the row that actually pins the change is the source-text
    one, now labelled as such.
  - **`exec` resolves shell functions, which `env` could not** — so the subshell form let a
    user's `gh` wrapper be run instead of the binary and its output taken as the effective
    login. `exec command gh`. Only reachable on the no-`timeout` fallback, so the test
    needs a PATH fixture with `gh` and without `timeout`.
  - **`gh-refresh-tokens` is outside the `~/.config/gh-quantivly` gate while its cache
    helpers were inside it.** On a personal-only box it hit `command not found`, took an
    *empty* cache path, wrote a live token to `/<basename>` at the filesystem root, and
    printed `✓ … cached token` with exit 0.
  - **`GITHUB_TOKEN` survived the success path.** gh outranks it; the GitHub MCP server,
    `act` and `hub` do not — so an inherited one authenticated as a third account in a
    correctly-routed directory.
  - **The `git-error` state reached only two of its three consumers**, so `gh-doctor`
    announced `✗ user.email is unset` when git simply could not be read; and the one
    message blamed `~/.gitconfig` for every cause, including git being absent (127) and
    "dubious ownership" (which wants `safe.directory`). git's own text is kept now.
  - **`GH_ACCOUNT_ROUTING_OFF` suppressed only the no-route warning**, so a deliberately
    unrouted shell inside a *matching* repo still got the confident ✗ the switch exists to
    prevent.
  - **`gh-doctor <dir>` skipped the route-vs-effective question instead of answering it.**
    It now probes the routed dir's own per-user token — what a shell there would be pinned
    to — restoring the value of the advertised form.
  - **The first-prompt hook unhooked after one attempt**, so a shell that lost the cache
    race twice stayed on the keyring default for life.
  - **`gh-refresh-tokens` printed ✓ without checking the write or the chmod.**
  - **The umask numeric repair introduced two more traps** — a `$(umask)` fork in a
    function documented as forkless, and decimal-vs-octal (`$(( 8#077 | 8#022 ))` is 63
    decimal; `umask` reads octal, so it set `0o63` from 077 and errored `bad umask` from
    002). Replaced by the symbolic `umask g-w,o-w`, which needs no read and no arithmetic.
    Override validity moved into the verdict, because `dotfiles-doctor` asks only for the
    verdict and was calling a nonsense override ✓ — and the doctor's re-derived comparison
    reproduced, inside the checker, the defect the guard had just been fixed for.
  - **Three test rows were vacuous**: the git-error hook row never defined
    `_update_gh_config`, and the argv rows could not fail. Rewritten; each fix is now
    pinned by mutation.

  Also: a `$(...)` helper introduced to deduplicate the cache path put a fork back in the
  `chpwd` hot path (a parameter does the same job); the legacy-nickname purge now subtracts
  the configured basenames rather than depending on ordering; and CLAUDE.md still
  documented the deleted `_gh_run_prefix`.

- **`gh-doctor` no longer exits non-zero on every run.** Deploying #94 immediately showed
  it: the "Credential isolation" section reported the keyring collapse as ✗, and that
  collapse is a property of `gh` — tokens keyed by host, not by config dir — which no
  configuration on this machine can repair. So a correctly-routed, fully-pinned machine
  still failed, every time. That is exactly the state CLAUDE.md warns about
  ("reporting it as one made the doctor exit non-zero forever"), reintroduced in the
  command written to avoid it, and it matters beyond tidiness: a checker that always fails
  cannot be wired into a hook, a healthcheck or a cron, and people stop reading it.

  The mismatch is a ⚠ now — still printed, still counted, exit 0 — and the section reads as
  the rationale for pinning rather than as a fault list. ✗ is kept for the states someone
  can act on: the route disagreeing with the effective account, a route dir that does not
  exist, an unreachable API, and a per-user token that resolves to the wrong login (which
  means that config dir needs `gh auth login`, and the message now says so). Seven new
  state-table rows, including one asserting a machine whose only problem is the collapse
  exits 0 — the old behaviour was never pinned, because the rows grepped the message text
  and never the glyph or the exit status.

### Removed
- **Atrium coupling in the live shell config.** Atrium is retired (2026-09-01), so
  `_in_atrium_session()` and the interactive account switchers' early-return that deferred
  to Atrium's injected `GH_CONFIG_DIR` / `GH_TOKEN` / `GITHUB_PERSONAL_ACCESS_TOKEN` are
  gone, along with the `atrium()` wind-down guard that stripped `HERDR_*` before exec'ing
  the binary. The early-return was the risky half: it keyed on `$ATRIUM` or a tmux socket
  named `*/atrium`, so anything that set either would have left whatever account was
  inherited, silently, in a shell that now believes it routes by remote.

### Fixed

- **Backups: the mount-point guard's last enumerated case is now a structural rule.**
  `external_mount_point_sane` refused `/media/$USER` and `/run/media/$USER` as literal
  strings, and both holes ever found in that guard were in exactly those two entries — an
  empty `$USER` collapsed them to `/media/`, and `/media/./<user>` resolved past them. That
  is not a coincidence: for every other entry on the deny-list the list is belt-and-braces,
  because `/etc`, `/usr` and `$HOME` are non-empty and the content checks refuse them
  unlisted. The udisks parents are the one dangerous directory that is *legitimately empty*
  whenever no drive is docked — and legitimately the parent of the correct answer — so
  there the string list was load-bearing and alone. `path_is_account_directory` replaces
  them: `<parent>/<leaf>` under `/home`, `/media` or `/run/media` is refused when
  `getent passwd` says `<leaf>` names a **regular login account** — uid within login.defs'
  `UID_MIN`..`UID_MAX`, **or** a home directory under `/home/`. The window alone is right
  for local accounts and useless for the ones the `getent` call was justified by: SSSD's
  AD id-mapping starts at 200000 by default, real AD-mapped uids land in the millions, and
  systemd-homed allocates above `UID_MAX`, so a domain-joined workstation had no protection
  past the current user. Their home is `/home/<name>`, which catches them while still
  matching none of `backup` (`/var/backups`), `games`, `nobody` or `root` (`/root`). It covers every account rather than just the current one, and it
  asks nothing about who is running the installer, so the `$USER` class of bug cannot recur
  in it. The literals stay as belt-and-braces but no longer carry the guard.
  The uid bound is the discriminator, not a detail: matching *any* passwd entry would
  refuse `/media/backup` — a plausible hand-made mount point, `backup` being a stock uid-34
  account — and that is not a harmless over-rejection, because `install_external_udev`
  treats an unusable mount point as a reason to **remove** the hotplug rule, so a working
  install would silently lose its remount-on-dock. It is also not a depth rule ("three
  components under `/media`"), which would reject `/media/backup-hdd`, `/media/external`
  and `/mnt/store`. The passwd *name* field is compared back so a numeric key
  (`getent passwd 1000`) does not make `/media/1000` look like a user directory, and the
  lookup runs under `timeout` so an unreachable NSS source cannot hang the installer.
  An **unanswered** lookup is not read as a clean "no": only `getent`'s exit 2 means "no
  such key", while `timeout`'s 124 and a missing `getent` (127) mean the question never
  ran, and folding those into "not an account" switched the whole rule off in silence on
  precisely the LDAP/SSSD hosts the timeout was added for. The guard now reports a third
  status for "could not determine" and refuses — a correct mount point is one component
  under `/media` too, so guessing would wave through `/media/<another-login-user>` just as
  readily — with a message that names the lookup rather than blaming the path, since the
  fix is name-service resolution and not `BACKUP_EXTERNAL_REPO`. That refusal is issued from the **end** of
  the function, after every check that could settle the path with certainty: returning it
  as soon as the lookup failed downgraded certain refusals to uncertain ones, turning
  `BACKUP_EXTERNAL_REPO=$HOME/restic` — the most canonical error there is — into "could not
  check, keeping the rule" on any host whose name service was merely slow, and leaving the
  `/media/$USER` literals unreachable in the one state where anything rests on them.
  **Every** step that installs
  persistent state keys on that status to change nothing at all, so a transient NSS failure
  cannot undo what an earlier successful run got right; only a genuinely unusable mount
  point still tears state down. All four consumers were checked individually: the fstab
  write skips, `install_external_udev` keeps the existing rule, `init_repos` skips and says
  "could not be checked" rather than "unusable", and `install_external_schedule` returns
  **before it writes** — that ordering matters, because it re-renders the unit from the
  template first and that resets `ConditionPathExists` to the template's own path, so a
  later bail-out has already destroyed what it meant to preserve, and it then removes the
  `After=` ordering drop-in. A unit whose `ConditionPathExists` names a nonexistent path is
  *skipped, not failed*, and `backup-doctor` has no check for `10-external-mount.conf`, so
  the whole loss would have been invisible. The lookup bound is 5s rather than 2, since an
  unanswered lookup is now a refusal and a cold SSSD cache over a VPN routinely takes
  several seconds — too tight a bound makes a healthy host permanently unconfigurable.
  68 checks → 99, driven by a fake `getent` on PATH
  (a shell function is invisible to a lookup made through `timeout`, so a stub would have
  passed vacuously), and the two sub-shell probes now print a positive token so a broken
  probe fails loudly instead of asserting an absence it would produce anyway.

### Added
- **Dotfiles live-config guard** (`dotfiles-doctor`, `dotfiles-work`, a one-line warning on
  the first prompt of an off-pin shell; `zsh/functions/system.sh`, `zshrc`). This repo is
  installed with dotbot `link:`, so every managed file is a symlink into the working tree
  and `git checkout` is a **deploy**: HEAD moves and `~/.zshrc`, `~/.gitconfig`,
  `~/.config/git/ignore` and the gh account configs change under the running system, with
  no install step and a clean `git status` throughout. Both directions bit us on
  2026-08-31 — a checkout predating #87 kept `backup-doctor` printing its false
  "external HDD not docked (normal — B2 covers offsite)" reassurance long after the fix
  merged, and ~830 lines of an open PR's `zshrc.company` were live in every new shell.
  The convention is now: primary checkout pinned to `main`, feature work in worktrees
  (nothing symlinks into one). `dotfiles-doctor` reports pin state, **how stale the
  `origin/main` ref it compares against is** (nothing here fetches on a schedule, so
  "not behind" is only as current as the last `git fetch`; `--fetch` refreshes it),
  ahead/behind, the file-level blast radius — the link list *plus* `zsh/` and `scripts/`,
  both of which are live without being linked — uncommitted changes to those files, and
  link integrity in four directions (declared-but-not-installed, installed-but-dangling,
  linked-but-pointing-outside-the-checkout, and linked-inside-it-but-at-the-wrong-file:
  rename a source without re-running `./install` and the other three all pass while the
  live file stays the old source). The startup check reads `.git/HEAD` and
  the two ref files directly rather than forking git — 0.07 ms / 0.3 ms against 2–5 ms for
  one `git symbolic-ref` — and fires both when the checkout is off `main` and when it is
  on `main` at a different commit than `origin/main`, which is the #87 case and the one
  with no other detection path — and, since both of those shas come off local disk and so
  agree the moment the machine stops fetching, when the ref they came from is older than
  `DOTFILES_STALE_WARN_HOURS` (168 = 7d, far more forgiving than the doctor's 24h because
  this one fires unasked). Deferred to the first prompt so p10k's instant prompt does not
  turn it into a warning box, and shown once per *shell* rather than once per source, so
  `zshreload` does not reprint it. `DOTFILES_GUARD_QUIET=1` opts out;
  `DOTFILES_PIN_BRANCH`, `DOTFILES_ROOT`, `DOTFILES_WORKTREES`,
  `DOTFILES_FETCH_MAX_AGE_HOURS`, `DOTFILES_STALE_WARN_HOURS` and
  `DOTFILES_EXPECTED_DIRTY` (scalar or zsh array) override the rest.
- **`./install` refuses to run from a git worktree** — git-dir ≠ git-common-dir, which is
  git's own definition, and unlike `[[ -f .git ]]` does not also catch a
  `--separate-git-dir` clone or a submodule (`DOTFILES_ALLOW_WORKTREE_INSTALL=1`
  overrides). Installing from a worktree re-points every managed symlink — `~/.zshrc`,
  `~/.gitconfig`, the gh configs — at a feature branch, with a clean `git status` either
  side and nothing but `readlink` to reveal it; one `./install` in the wrong directory
  defeated the whole feature. `dotfiles-doctor` now also resolves each link and fails when
  one lands outside the checkout, and the startup line resolves `~/.zshrc` (forklessly,
  with zsh's `:A`) to report a shell sourced from somewhere else entirely — between them
  they catch the machines already installed that way.
- **[scripts/test-dotfiles-guard.sh](scripts/test-dotfiles-guard.sh)** — 195-check state
  table for the guard, run in CI. Every bug found in the guard so far printed a green tick
  rather than an error, so each is a row: `local path` in zsh is tied to the `PATH` array,
  so declaring it blanked PATH and every later external command vanished — git's empty
  output then read as "no drift" and the doctor announced "none — every live file
  matches"; folding git's stderr into the parsed value with `2>&1` produced a section that
  printed nothing at all; a stale remote-tracking ref made a merged-but-not-running fix
  report "not behind"; an unparseable `install.conf.yaml` resolved no live paths, which
  read as no drift; a symlink into another worktree passed as "17/17 links present"; and a
  malformed `~/.gitconfig` turned every git failure into a confident wrong claim. The
  fixture builds its own repo, remote and `HOME`, so the table is hermetic. A second
  review pass added rows for every way a link source can be got wrong without anything
  saying so — a quoted YAML scalar, dotbot's null form, an entry left open past the end of
  the `link:` block, and a declared source absent from the tree — because a git pathspec
  that matches nothing exits 0 with empty output, so each of those *narrowed* the drift
  check rather than failing it. Plus: `--separate-git-dir` and linked-worktree layouts,
  the mise symlink `install` creates itself, spaced and renamed paths in the working-tree
  check, a stale-but-identical ref, `./install`'s refusal end to end, the startup line
  surviving a reload, and a run whose ✓ printf fails for real (`/dev/full` — a closed fd
  does not do it: zsh's printf warns and returns 0 there).

- **`bun` pinned in `.mise.toml`** (1.4.0) — runtime for the herdr `gh-pr` plugin. herdr's
  server PATH carries no mise shims, so it must also be reachable as `~/.local/bin/bun`
  (`ln -s "$(mise which bun)" ~/.local/bin/bun`).
- **[docs/HERDR_GUIDE.md](docs/HERDR_GUIDE.md)** — the team-facing guide to the recommended
  agentic dev setup: prerequisites and how to verify them, keymap with rationale, sidebar
  semantics, plugins, `hspawn`, troubleshooting, and criteria for who should use herdr at all
  (non-developers are pointed at Orca, with the evaluation's limits stated). Leads with the
  lesson that cost the most time: **every layer of this stack fails silently** — `config
  check: ok` means the file parses, nothing more.
- **`yazi` pinned in `.mise.toml`** (26.8.15) and added to `scripts/verify-tools.sh`. It was
  bound to `alt+y` with its config symlinked into `~/.config/yazi`, but the binary had never
  been installed, so the popup opened and closed instantly.
- **herdr chord-first keymap and coloured agent sidebar** (`config/herdr/config.toml`,
  `scripts/herdr-keyprobe.sh`, `hspawn` in `zsh/zshrc.company`, local `sidebar-icons`
  plugin). Root cause of the earlier "3-modifier chords don't work": GNOME's
  `grp:alt_shift_toggle` xkb option made Alt+Shift the layout switch and swallowed one
  modifier of every Alt+Shift chord — now cleared by `apply-gnome-settings.sh`
  (Super+space remains the switch).
- **`system_health` now reports memory-pressure kills** (earlyoom / systemd-oomd /
  kernel OOM killer) over the last 7 days, with the most recent victim. These are
  worth surfacing because the damage is *silent*: a process killed mid-pipeline
  still lets the pipeline exit 0 with empty output, so the result is a confident
  wrong answer rather than an error. Observed on 2026-08-03, when a 16 GB search
  was shed this way and its empty output was read as "no matches". The match
  pattern requires `sending SIG… to process` — earlyoom's startup banner
  (`sending SIGTERM when mem avail <= 10.00%`) otherwise counts as a kill on every
  boot. When the system journal can't be read at all (no `journalctl`; a user
  outside `adm`/`systemd-journal`, who sees only their own journal while these
  kills are logged by root units) the check reports `skipped` rather than a clean
  ✓ — a false all-clear would reproduce the exact failure mode it exists to catch.
  The journal read is narrowed to the `earlyoom`/`systemd-oomd`/`kernel`
  identifiers, which is the same answer in 0.3s instead of 3.3s.
- **Broadcast-kill audit tripwire** — a two-line auditd rule
  (`audit/99-logout-catch.rules`, installed root-owned by `audit-setup` /
  `scripts/setup-audit-rules.sh`) that records any real `kill(-1, sig)`: *"signal
  every process I may signal"*, which on a desktop is the whole graphical
  session. Motivated by three unexplained GNOME logouts (2026-08-02/03) in which
  a broadcast kill from a project test suite produced a completely orderly
  teardown — no crash, no OOM, no coredump, nothing in the journal — leaving the
  audit log as the only place the sender's identity could exist.
  - `audit-status` reports every way this instrumentation can go quiet as its own
    distinct failure, so that "nothing found" can only mean "nothing happened":
    a rejected rule field leaves zero rules loaded with no error; auditing
    switched off (`enabled 0`); **no daemon registered (`pid 0`)** — rules live in
    the kernel, so `auditctl -l` lists them happily while records go to the ring
    buffer instead of `/var/log/audit/audit.log`, leaving `ausearch` blind
    forever; a climbing `lost` counter dropping records; `/etc` drifted from
    `~/.dotfiles` (the file is *copied*, so editing the repo alone changes
    nothing); and auditd's `SUSPEND` disk actions, which stop logging quietly
    when `/var` runs low. Exits non-zero on the fatal ones.
  - `audit-sweeps [hours]` reads hits, encoding the fact that `ausearch -ts`
    takes the date and time as **two** arguments — quoting them as one string
    matches nothing and prints no error. It validates `hours`, and distinguishes
    ausearch's benign "no matches" from a real read failure rather than
    reporting both as an all-clear.
  - `audit-setup` asserts all three arms (rules loaded, auditing on, daemon
    recording) and fails loudly otherwise; it prompts before installing the
    auditd package, since that has a system-wide side effect (`--yes` to skip).
  - Scope is `kill(-1, …)` only; `audit/99-logout-catch.rules` documents why
    `kill(0, …)` and `kill(-pgid, …)` are deliberately excluded.
  - Note: installing auditd moves AppArmor denials out of `journalctl -k` into
    `sudo ausearch -m AVC`. See CLAUDE.md → Audit Tripwire and
    docs/TROUBLESHOOTING.md → "Desktop session suddenly logged out".
- **DO-449 — Backup hardening (verification, health checks, safe-restore guardrails)**:
  closes the *silent-failure* class for the backup system.
  - `backup-doctor` — full-chain correctness assertion (file perms, config drift vs.
    `~/.dotfiles`, the DO-448 EnvironmentFile drop-in, snapshot age, that healthcheck URLs are
    actually set, emergency-kit/LUKS-header freshness, disk space); non-zero exit on any failure.
  - Weekly verification — `scripts/backup-verify.sh` + `systemd/restic-verify.{service,timer}`
    run a **content canary** (critical paths still present in the latest snapshot, catching a
    regressed exclude) and a **restore canary** (one file actually restored), decoupled from the
    `[b2.check]` integrity check and skipping cleanly when offline. `backup-drill` is the
    on-demand equivalent. `restic check` proves *intact*; this proves *complete + restorable*.
  - `backup-restore-system` — guarded `/etc`-slice restore that always excludes
    `fstab`/`crypttab`/`machine-id`/`ssh_host_*`, so the bare-metal restore can't break boot.
  - `setup-backup.sh` now warns when `BACKUP_HC_URL_*` are blank (alerting would be inert),
    re-takes the LUKS header when stale, and points to `backup-doctor`. New
    `BACKUP_HC_URL_VERIFY` / `BACKUP_CANARY_PATHS` knobs; optional `timeshift-autosnap` apt hook.
  See [docs/BACKUP_AND_RESTORE_GUIDE.md](docs/BACKUP_AND_RESTORE_GUIDE.md).
- **Backup & restore workflow** — encrypted 3-2-1 backups via restic + resticprofile to an
  external HDD (dock-triggered) and Backblaze B2 (offsite, append-only key + lifecycle for
  ransomware resistance). Declarative policy in `resticprofile/profiles.toml`; machine config
  in `~/.backup.local` (template + `backup-init`); one-time installer `scripts/setup-backup.sh`
  (`backup-setup`) wires repos, systemd timers, the dock trigger, Timeshift, a LUKS header
  backup, and an age-encrypted offline emergency kit. New `backup-*` functions in
  `zsh/functions/system.sh`. See
  [docs/BACKUP_AND_RESTORE_GUIDE.md](docs/BACKUP_AND_RESTORE_GUIDE.md).

### Changed
- **Three more findings from the independent review of #89.** (1) The launcher preferred the
  CALLER's `SSH_AUTH_SOCK` over the stable `~/.ssh/ssh_auth_sock` symlink, which made the symlink
  branch dead on the one restart path the runbooks sanction — `systemctl --user restart` carries
  the manager's environment, so the live snap path always won and the server got the snapshot the
  indirection exists to avoid. The header already described the intended order; the code did the
  opposite. (2) `hdespawn`'s worktree-path recovery was gated on a live workspace, so it was
  unreachable in the post-`hreap --close` state it exists for: hdespawn then said "no worktree dir
  on disk", removed the registry entry anyway, and orphaned the worktree and its branch. It now
  runs ungated and falls back to `git worktree list`, which knows even when herdr does not.
  (3) `plugins.lock` still pinned `herdr-auto-pilot` after `plugins.list` dropped it, so
  `herdr-lazy restore` would have reinstated the plugin the change exists to keep out.
- **`./install` reconciles systemd user unit enablement, and `verify-tools.sh` fails when it has
  drifted** (`scripts/reconcile-systemd-units.sh`, `install.conf.yaml`, `scripts/verify-tools.sh`,
  `systemd/herdr-server.service`). A linked unit is not a reconciled one: systemd records
  `[Install]` at `enable` time as a `<target>.target.wants/` symlink, and editing `WantedBy=`
  afterwards moves nothing — not even after `daemon-reload`, which re-reads the unit but never
  revisits the symlink. The obvious primitive is a trap: `systemctl reenable` (= `disable` +
  `enable`) DESTROYS a dotbot-installed unit, because `disable` removes every symlink in the unit
  search path pointing at it — and the entry in `~/.config/systemd/user` is such a symlink, into
  the checkout. The enable half then fails with "Unit does not exist" and the unit is left neither
  linked nor enabled; this happened on a real machine on 2026-09-01, following advice added in the
  same series of commits. The reconciler therefore `enable`s (which only ADDS `.wants` links) and
  prunes the stale link itself, enable first so a failure leaves the unit enabled under the old
  target rather than off. This repo manufactures that drift, because
  `git checkout` here is a deploy and install is not in that path — so reconciliation at install
  time is necessary but not sufficient, and the load-bearing half is the check, which runs
  whenever anyone asks about the machine. The reconciler is gated twice: it no-ops without a user
  manager (servers, containers, CI), and it acts only on a unit already enabled, so it reconciles
  a decision and never makes one. It also
  says plainly that a RUNNING server keeps the old unit until a restart, which ends every agent
  session, rather than printing a success nobody can act on. `--check` reports, `--plan` lists
  what `--apply` would touch (which is how the gate became testable without systemd).
- **`verify-tools.sh` now asserts the server environment is COMPLETE, not just uncontaminated.**
  It only ever asked whether anything forbidden was present, so a server started at boot — before
  any graphical session existed to import an environment from — carried no forbidden variable and
  printed "environment is clean" while every pane had lost `gh --web`, `xdg-open` and the ssh
  agent. It now compares against the user manager's own environment (so a headless box correctly
  reports nothing), FAILs on a variable the session offers and the server lacks, and WARNs when
  `DISPLAY`/`WAYLAND_DISPLAY` name a previous login. `SSH_AUTH_SOCK` is excluded from the value
  comparison because the launcher substitutes a stable symlink for it by design.
- **[scripts/test-systemd-reconcile.sh](scripts/test-systemd-reconcile.sh)** — 130-check state
  table for the reconciler, in CI as `systemd-reconcile-test`, needing no systemd user manager
  because the read-only comparison is filesystem state and the mutating half runs against a
  recording `systemctl` **stub** at the front of `PATH` (a runner has no manager, and a suite that
  skips in CI is one that never runs; but "hermetic" has to mean answered-by-a-fake, not
  tool-happens-to-be-absent — this box has a real systemctl wired to the user manager holding the
  herdr server). Each fix is pinned by mutation, which is how four hollow assertions
  were caught before this landed: a note-prefix check that passed when two different notes
  collapsed into one, a "plain file ignored" row that was really testing containment, a dead
  comment-skip rule in the awk that could not fire because the pattern is anchored, and — worst —
  the reconcile gate, which was unpinnable while it sat inside a manager-gated loop. A later,
  costlier lesson from the same change is pinned too: the suite now asserts the script never
  reaches for `reenable`/`disable`, because the first version did and it cost a machine its unit.
- **One doctor-reporting implementation** (`_doctor_ok`/`_doctor_bad`/`_doctor_warn`/
  `_doctor_note`/`_doctor_summary` in `zsh/functions/system.sh`). `backup-doctor` had a
  byte-for-byte duplicate of the ✓/✗/⚠ emitters and its own hand-rolled summary; both now
  delegate, so a change to how results are emitted is made once. Their counters are also
  no longer globals — zsh scopes locals dynamically, so each doctor declares them and a
  run leaves nothing behind in the shell (four `_D*` variables used to persist in every
  shell, and a nested call clobbered the outer count). The summary's wording and exit
  status had no coverage in either suite before this — `backup-doctor`'s own table asserts
  printed findings, never the verdict — so the state table now pins all three paths, the
  dynamic-scoping mechanism, the `_backup_doctor_*` delegation, and the local-counter
  convention across every doctor entry point. `backup-doctor`'s three remaining
  hand-rolled `• …` note lines now go through `_doctor_note` too, so the neutral marker
  is not a fourth glyph in the one function the consolidation was about.
- **CI runs `zsh -n` over `zsh/functions/*.sh`** (`.github/workflows/ci.yml`). It is the
  largest zsh in the repo and no static check read it: the ShellCheck job selects files by
  a `^#!` shebang and these have none (they are sourced, not run), and pre-commit excludes
  the directory because the syntax is zsh, not bash. A syntax error there was caught only
  when some test happened to source the file.
- **`~/.config/mise/config.toml` is checked like any other managed link.** `install`
  creates it itself rather than via dotbot, so it appeared in no `link:` block and in
  nothing `dotfiles-doctor` looked at — while CLAUDE.md already records what its drifting
  cost once: ~11 tools missing from `PATH` and `git diff` dead with "unable to execute
  pager 'delta'". Emitted under both halves of `install`'s own gate, so a machine without
  mise is not permanently red for a link that correctly does not exist.

### Fixed
- **External-HDD auto-mount: the review follow-up to #87.** An independent xhigh review of
  the merged change found fifteen defects, all confirmed. The dangerous one: the `/etc/fstab`
  mount point was a blind `dirname` of the hand-edited `BACKUP_EXTERNAL_REPO`, with no floor
  at all — a repo path one level too shallow resolves to `/media/<user>` and a typo resolves
  to `$HOME`, and every check downstream passed, so the external disk would have been mounted
  over the user's home at every boot. `nofail` is no help there; the mount *succeeds*.
  `external_mount_point_sane` now refuses non-absolute, unnormalised (`/./` included) and
  symlinked paths, a deny-list of system directories (`$HOME`, `/media/$USER`,
  `/run/media/$USER`, … — the user resolved with `id -un`, never the login-set `$USER`,
  which is empty under `sudo -u`/`env -i`), and any existing directory that is not already a
  mount point and is either non-empty or unlistable. It gates the `/etc/fstab` write, the
  udev rule, `restic init` **and** the `ConditionPathExists`/`After=` wiring — the repo
  init is the step that would otherwise create the "external" repository on the internal
  disk for a `BACKUP_EXTERNAL_REPO` of `/restic`, since `/` is a mount point.
  - **`render … | sudo tee /etc/…` truncates on failure.** `backup-render.sh` became fallible
    when unresolved placeholders were made a hard error, but three call sites still piped it
    into `tee`, which empties the destination before the renderer's status is known — leaving
    a zero-byte `includes.txt` (restic backs up nothing) or `.service` (a unit that does
    nothing), both installed and reading as present. Replaced with `render_install`
    (render → temp → check → `install`), the pattern the udev step already used.
  - **`findmnt -S UUID=x` misses `/dev/disk/by-uuid/x` entries while the disk is undocked**,
    because it resolves the tag through `/dev/disk/by-uuid`. That is the form Ubuntu's
    installer writes (and what `/boot` uses here), so a correct `/etc/fstab` read as empty in
    exactly the state the feature exists for — producing a duplicate entry, a refused udev
    rule, and a false "will not mount after a reboot" warning. Both the installer and
    `backup-doctor` now query the literal device path as a second step.
  - **`findmnt`'s summary is translated.** Both `N parse errors, …` and `Success, no errors or
    warnings detected` are gettext-marked in util-linux; under a translated locale the parse
    returned the 999 "unusable" sentinel for every clean table and the step refused to install
    anything, permanently. Now read under `LC_ALL=C`.
  - **A failed mount no longer leaves a root-owned mount point behind** — udisks owns
    `/run/media/<user>` and creates it user-owned, and the leftover is precisely the
    directory that makes `test -e "$repo/config"` report a drive that is not there.
  - **Stale udev rules are removed and reported.** Every path on which the step declines to
    install now removes a rule an earlier run left, and `backup-doctor` checks for one even
    when nothing is configured — the check used to be gated on "is anything configured",
    which is how a rule naming a since-reassigned UUID stayed invisible.
  - `fstab_escape` covers the full fstab(5) set (`\011`, `\012`, `\134`, not just `\040`);
    `backup-status` reports "not configured" instead of asserting "not attached" for a disk
    it cannot know about; `backup-doctor` no longer warns twice about a single
    non-configuration; `_backup_external_attached` no longer treats *any* volume whose label
    matches the mount point's basename as the backup drive (a name coincidence was enough to
    raise a hard, non-zero-exit failure); the dead `_backup_external_mnt` helper and the
    unused `out_of` test helper are gone; and the udev template's own documentation header no
    longer names the placeholder tokens inline, which had the renderer replacing the
    explanation with the values in the only copy an administrator ever opens.
- **`scripts/test-backup-external.sh` now runs in CI** (`backup-external-test`) and checks its
  own harness first. Sourcing `setup-backup.sh` also runs that script's `set -euo pipefail`,
  so the suite re-declares `set +e` — without it the first expected-to-fail assignment killed
  the run mid-table with no failure count printed. It also aborts unless every function under
  test is defined and every required tool present: most of these assertions are "nothing was
  installed", which is exactly what a suite that loaded nothing produces. 27 checks → 68.

- **Backups: the external HDD stopped mounting, and every layer said it was fine.**
  `BACKUP_EXTERNAL_UUID` had been declared in `backup.local.template` since the backup
  system was written and nothing ever read it. Without an `/etc/fstab` entry the drive
  stays unmounted, `restic-backup-external.service` fails its `ConditionPathExists`, and
  systemd **skips** it — which is not a failure: no error, nothing in `--state=failed`, no
  notification, and no healthchecks ping, because a skipped unit pings nothing. On a laptop
  it compounds, since the drive leaves and returns with every dock cycle (twelve times in
  seven days on the machine this came from) and fstab alone only covers boot. `backup-doctor`
  reported all of it as a neutral note claiming `B2 covers offsite`, a reassurance it never
  checked — while B2 was simultaneously failing on a storage cap.

  `backup-setup` now installs three things from that key, covering three different windows:
  an `/etc/fstab` entry for **boot** (`nofail` + `x-systemd.device-timeout=10s`, so an absent
  disk can never break or stall it, and the filesystem type is read off the disk rather than
  assumed), [`udev/99-backup-external.rules`](udev/99-backup-external.rules) for **dock
  cycles**, and a `service.d` drop-in ordering the run `After=` the mount unit so the timer's
  `Persistent=true` catch-up cannot lose a race against USB enumeration at boot. The ordering
  is `After=` only — `Requires=`/`RequiresMountsFor=` would turn an undocked disk into a
  *failed* unit every six hours, which is the false alarm the `ConditionPathExists` design
  exists to avoid.

  `backup-status` and `backup-doctor` now distinguish **attached-but-unmounted** (a hard
  failure: it is the one external fault that looks exactly like "nothing was due") from
  genuinely absent, without depending on `BACKUP_EXTERNAL_UUID` being set — the population
  that has this bug is precisely the one that never set it. Both now test whether the mount
  point *is a mount point*, rather than whether a path under it exists: a leftover directory
  on the internal disk satisfied the old check, so "docked ✓" could be reported while writes
  landed on the root filesystem. `backup-doctor` also checks `BACKUP_HC_URL_EXTERNAL` (the
  external target's only possible dead-man's switch), that the unit's `ConditionPathExists`
  and the configured repo agree, and compares the live udev rule against the rendered repo
  template — its load-bearing half is the `systemd-escape`'d mount unit name, which goes
  stale on a repo-path change and leaves a rule that still contains the UUID, still passes
  `udevadm verify`, and never fires.

  [`scripts/test-backup-external.sh`](scripts/test-backup-external.sh) pins the install and
  doctor decisions against a fake fstab, with no root and no real disk. Two traps it exists
  to hold down: `findmnt --verify` reports "unreachable on boot" as an **error** for a
  `nofail` entry whenever the disk is undocked or its mount point directory is absent, so
  gating on its exit code rejects every correct entry in exactly the two states this fix
  targets; and a hardcoded `ext4` passes `findmnt --verify` (a type mismatch is only a
  warning) and then fails to mount, which `nofail` converts straight back into a silent
  non-mount.
- **herdr: the 2026-08-30 independent-evaluation batch** (`~/herdr-eval-findings.md`, F1–F11).
  The live herdr server had been restarted from inside a herdmates team-lead pane, so every pane
  inherited a fake `TMUX`, the teammux shim as `tmux`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
  and herdmates' plugin dirs: every Claude session became a team of one, `tmn` / `tmux
  kill-server` hit the shim, `$status` appeared on nearly every sidebar row, and the runbooks'
  own pre-flight (`command -v tmux` → the shim) passed for everyone. Nothing detected it.
  - The server now runs from a declared, clean environment: `systemd/herdr-server.service` +
    `scripts/herdr-server-launch.sh` (`--print-env`; refuses to start from inside a pane or a
    Claude session; PATH from `~/.local/bin` + `mise bin-paths`, never a plugin shim;
    `LINEAR_API_KEY` from `~/.zshrc.local`; the session-bus variables toasts need). The unit is
    wanted by `graphical-session.target`, not `default.target`: `Linger=yes` here means the user
    manager comes up at boot, so a `default.target` unit would start before GNOME imports
    `DISPLAY`/`WAYLAND_DISPLAY`/`XAUTHORITY` and get none of them. `WantedBy` propagates start
    only and the unit has no `PartOf`, so it still survives logout with every session alive.
    `SSH_AUTH_SOCK` resolves to the stable `~/.ssh/ssh_auth_sock` symlink rather than the live
    snap path, because the Bitwarden agent that owns it autostarts *after* that target.
    `scripts/verify-tools.sh` gained "herdr server environment hygiene" (the running server's env
    carries none of the pane/team/plugin variables) and "Plugin dependencies under the herdr
    SERVER PATH" (each dependency resolved one at a time under the *server's* PATH).
  - Cleanup is executable instead of prose: `hspawn` gained `-p/-m/-e/--mode/-b/-n` and a
    registry (`~/.local/state/hspawn/`), plus `hdespawn <slug>` and `hreap [--close] [--mine]
    [--older MIN]` — every Claude process herdr hosts, detected or not, with idle age, memory and
    creator. `herdr agent list` had been the documented "what is alive", and it misses herdmates
    teammates and trust-dialog panes (14 agents shown while 33 claude processes ran, 15 of them
    finished teammates holding 4.5 GB).
  - Sidebar: an idle band `$idle_ok|$idle_warn|$idle_crit` (5/10 min, matching herdmates'
    quiet/stalled tiers) published by `session-statusline.sh` — the sidebar had no time
    dimension; the tab bar shows `agents <detected>/<claude procs>`; `remove_worktree` and
    `previous_workspace`/`next_workspace` bound; the `$task $status` comment corrected (`$status`
    is not team-only in practice, and `stale` = no transcript write for 10 min);
    `0xGosu/herdr-auto-pilot` dropped from `plugins.list`.
  - Guide + CLAUDE.md corrected: the from-zero sequence no longer strands a new hire at step 4
    (rustup, jq, `herdr plugin install natori-hrj/herdr-lazy` *before* `herdr-lazy check`,
    `LINEAR_API_KEY` before the server first starts, the unit, then `verify-tools.sh`);
    `clauth start` lacks `teammateMode: tmux`, not "team capability"; five sidebar rows, not
    six; the hspawn branch is `${HSPAWN_BRANCH_PREFIX:-$USER}/<slug>`, not `zvi/<slug>`; the
    keymap table's "swap panes / copy mode" row (no such actions exist) replaced with the real
    prefix actions; macOS labels on rotation, `/proc` and `notify-send`; `herdr agent explain`
    and named test sessions in troubleshooting. `config check` turned out stricter than §0 had
    said — probing showed it catches bogus keys, bad inline fields, non-hex colours and chord
    collisions among listed actions — but it still misses collisions with unlisted stock
    defaults, terminal-swallowed chords, missing popup binaries and unpublished tokens; §0 and
    the CLAUDE.md intro now say exactly that.
  - Upstream: teammates go undetected because Claude Code execs them via its versioned binary
    (process name `2.1.251`, not `claude`) while `herdr agent explain --file` accepts the same
    screen. Issue drafts for herdr (same class as herdrdev/herdr#803) and herdmates
    (`HERDR_AGENT=claude` on the respawned command, or `pane report-agent` from its hooks) are
    under `~/herdr-eval-upstream/`.
- **herdr: `hspawn` never worked.** Both code paths failed on every invocation. It creates a
  fresh worktree each run, so Claude's trust-folder dialog is guaranteed, and neither path
  answered it: the profile path called `herdr agent wait` before herdr had detected any agent
  (`agent wait` resolves its target up front and cannot wait *for* detection, so it died with
  `agent_not_found`), and the no-profile path died with `agent_not_ready`. Now polls for
  detection first, then answers the dialog on the agent surface — sending the keys at the pane
  level as the dialog renders does not work, because Claude's TUI is not yet accepting input
  and the keys vanish without error. Both paths verified end to end.
- **herdr: `f12 v` and `f12 -` had been silently deleted.** `split_vertical` /
  `split_horizontal` were arrays that omitted the stock prefix defaults, and setting a key
  field replaces it wholesale — leaving the two splits as the only actions with no prefix
  escape hatch.
- **herdr: `ctrl+shift+o` (split down) was dead**, because *Alacritty* has a compiled-in
  default binding that consumes the key press; the keyprobe signature is a release event with
  no matching press. Fixed in `~/.config/alacritty/alacritty.toml` (not symlinked from this
  repo) with an explicit `{ key = "O", mods = "Control|Shift", action = "ReceiveChar" }`.
  A sweep of the other 15 bound chords found `o` the only casualty — "one letter works, so the
  class works" is an unsound inference, and `CLAUDE.md` has been corrected accordingly.
- **DO-452**: the verification canary (`backup-verify.sh`) now runs its read-only `restic ls`
  / `restore` with `--no-lock`, so it no longer takes a repo lock that blocked the structural
  `restic check` in `backup-drill` (the check was being skipped rather than run). Added a
  `backup-unlock [b2|external] [--force]` command to clear stale restic locks after an
  interrupted run.
- **DO-451**: `backup-drill` no longer reports a false "DRILL FAILED" when a backup is running
  concurrently. `restic check` needs an exclusive lock, which collides with the every-2h
  backup; the drill now passes `--retry-lock 2m` and treats a still-held lock as "repo busy /
  skipped" rather than an integrity failure (the content + restore canary already proves
  restorability).
- **DO-450**: `backup-doctor` fixes found in live verification — its disk-space check used
  `df` (aliased to `duf`) so it silently printed nothing; now uses `command df -P` to bypass
  the alias. Also stops false-warning when `emergency-kit.age` isn't in `$HOME` (it's meant to
  live offline on the USB / in the repo) — now a neutral note instead of a warning.
- **DO-155**: Fixed CI ShellCheck error suppression - Shell script errors now fail CI builds instead of being silently ignored
- **DO-160**: Fixed mise activation error suppression in install script
  - Replaced `|| true` with explicit error checking
  - Shows warning message when activation fails
  - Provides remediation instructions
  - Users now informed when mise tools unavailable
