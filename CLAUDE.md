# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## How to extend this file

**This is an instruction file, not a journal.** It is loaded in full into every request of
every session, so every paragraph here is paid for on every turn — and past ~150k chars
Claude Code warns that length *reduces adherence*, i.e. the file stops producing the
behaviour it was written to produce. It held 14k–36k for eight months and then went
35,682 → 350,324 in nineteen days, because each PR appended its own review narrative. A
one-off cut was already tried (2026-01-07, −62%) and it regrew 25×, so the budget is now
enforced: `scripts/check-claude-md.sh`, run in CI and by pre-commit, against a ceiling
derived from history that can only tighten. **Remove as much as you add.**

Before adding anything, route it:

| what you have | where it goes |
|---|---|
| Changes what an agent **does**, everywhere in this repo | here, as **one imperative line** |
| Changes what it does in **one area** of the code | `.claude/rules/<area>.md` (a trigger card: imperative lines and links, ≤2,000 bytes) |
| A procedure for a recurring task | `.claude/skills/<task>/SKILL.md` (+ uncapped `references/`) |
| Evidence, a measurement, a date, a postmortem, a mutation tally | `docs/<AREA>.md` |
| What changed in this release | `CHANGELOG.md` |
| True of the **tools or harness** regardless of repo | the agent memory store |
| True of **every Quantivly repo**, not just this one | the `quantivly-conventions` plugin |
| A rule whose condition can no longer fire | **retire it — do not extract it** |

Two rules about *how* to move something, both measured rather than assumed:

- **Extract the elaboration; keep the operative rule here.** The threshold, the decision and
  the emitted line stay inline. nanoclaw measured a 22-file extracted reference corpus at
  **zero reads across 102 runs** — including a file cited with "You MUST read" — so moving a
  rule out and leaving a pointer improves every number and loses the rule.
- **One prose home per fact.** A one-line imperative here and a short memory hook are
  *pointers*; what is forbidden is the same *explanation* written twice. `CLAUDE.md` and
  `docs/HERDR_GUIDE.md` already drifted that way once (commit `69d815d`).

Anything you add under `docs/`, `.claude/rules/` or `.claude/skills/` **must be linked from
here or from `README.md`** — the guard enforces reachability, because an unrouted file is an
unread file. `docs/CLAUDE_SETUP.md` sat unlinked and therefore unread until this guard named
it; that is the failure mode, and it is silent from every other angle.

Budget knobs and their rationale: [scripts/context-budget.conf](scripts/context-budget.conf).
Run `./scripts/check-claude-md.sh` before you commit.

**`.claude/rules/` cards cannot be scoped, measured rather than assumed.** On Claude Code
2.1.277 a card carrying `paths:` **never loads** — not at session start, not after reading a
matching file, at project or user scope, in every spelling tried (block list, inline array,
literal path); an identical card *without* `paths:` loads every time. So a card is not a
cheap on-demand layer, it is more always-loaded text, and the guard forbids `paths:` rather
than requiring it. Until that changes, a rule that must reach an agent belongs **here**.

## Repository Overview

This is a personal dotfiles repository that manages zsh, git, and development tool configurations using [dotbot](https://github.com/anishathalye/dotbot). The configuration is modular, portable across machines, and security-focused with secrets separated from version control.

## Installation & Testing

For Quantivly developers: Use the `quantivly/dev-setup` repository which automatically installs prerequisites and dotfiles.

For standalone installation: `./scripts/install-prerequisites.sh && ./install`

### Testing Changes

```bash
./install          # Install/update dotfiles (uses dotbot, creates symlinks, initializes submodules)
source ~/.zshrc    # Test changes
time zsh -i -c exit  # Profile startup performance
```

## Server Setup

Bootstrap remote servers with `server-bootstrap.sh`. See [docs/SERVER_BOOTSTRAP_GUIDE.md](docs/SERVER_BOOTSTRAP_GUIDE.md) for full details including SSH config patterns, AL2 gotchas, and bootstrap ordering.

Key commands:
```bash
ssh server 'bash -s' < ~/.dotfiles/scripts/server-bootstrap.sh  # Bootstrap
ssh server '~/.dotfiles/scripts/server-bootstrap.sh --update'  # Update
```

## Architecture

### Modular Configuration System

The zsh configuration is split into focused modules loaded by `zshrc`:

1. **zshrc.history** - History configuration (50k commands, timestamps, deduplication)
2. **zsh/functions/\*.sh** - Utility functions organized into 4 modules (see Function Modules below)
3. **zshrc.aliases** - Portable aliases for git, docker, python, system commands
4. **zshrc.conditionals** - Module dispatcher that loads:
   - **zshrc.conditionals.tools** - Modern CLI tool configurations (bat, eza, ripgrep, zoxide, etc.)
   - **zshrc.conditionals.fzf** - FZF fuzzy finder setup and key bindings
   - **zshrc.conditionals.plugins** - Plugin integrations (mise, direnv, forgit, git workflows)
5. **zshrc.buildlimits** - Build/test worker caps so parallel agent sessions can't each claim every core
6. **zshrc.herdr** - The herdr agent-workspace layer (portable; split out of
   zshrc.company by DO-555 so herdr can be adopted without the work half)
7. **zshrc.company** - Work-specific configuration (Quantivly)
8. **~/.zshrc.local** - Machine-specific secrets and settings (NOT in git)

### Function Modules

| Module | Purpose | Key Functions |
|--------|---------|---------------|
| `zsh/functions/core.sh` | Core utilities (22 functions) | `pathadd`, `mkcd`, `backup`, `extract`, `osc52`, `killnamed` |
| `zsh/functions/development.sh` | Git + Docker + FZF (39 functions) | `gd`, `git_cleanup`, `gco-safe`, `dexec`, `dlogs`, `fcd`, `fkill`, `qmux` |
| `zsh/functions/system.sh` | Performance + Utilities + Dotfiles guard + GNOME + Backup + Audit (59 functions) | `startup_monitor`, `system_health`, `has_command`, `confirm`, `dotfiles-doctor`, `dotfiles-work`, `gnome-status`, `backup-now`, `backup-status`, `backup-doctor`, `backup-drill`, `backup-restore`, `backup-restore-system`, `audit-sweeps` |
| `zsh/functions/github.sh` | gh account routing + diagnosis (10 functions) | `gh-doctor` |
| `zsh/functions/claude.sh` | Claude Code auth + MCP diagnosis (5 functions) | `claude-doctor` |
| `zsh/zshrc.herdr` | herdr agent workspaces (17 functions) — mostly **agent-facing**, a human at the keyboard uses the herdr UI and `clauth` instead | `hspawn`, `hdespawn`, `hreap`, `claude`, `herdr-lazy`, `herdr-help` |

**Function Naming Convention:**
- User-facing: No separator or dashes (e.g., `fcd`, `dexec`, `gco-safe`)
- Internal helpers: Underscores (e.g., `has_command`, `tool_status`)

### Symlink Structure

Dotbot creates symlinks from `install.conf.yaml`:
- `~/.zshrc` → `~/.dotfiles/zshrc`
- `~/.p10k.zsh` → `~/.dotfiles/p10k.zsh`
- `~/.gitconfig` → `~/.dotfiles/gitconfig`
- `~/.config/gh/config.yml` → `~/.dotfiles/gh/config.yml`
- `~/.config/git/ignore` → `~/.dotfiles/config/git/ignore`
- `~/.config/Code/User/settings.json` → `~/.dotfiles/vscode/settings.json`
- `~/.config/yazi/yazi.toml` → `~/.dotfiles/yazi/yazi.toml`

**Not symlinked (but coupled):**
- `~/.config/alacritty/alacritty.toml` — Terminator-style tmux keybindings require CSI u key entries here. Template: `examples/alacritty.toml.template`, install with `alacritty-init`. **Gotcha:** Live config diverges from template — updating the template doesn't propagate. Also, Ctrl+Shift+letter combos that have Alacritty built-in defaults (e.g., F=SearchForward) must have explicit entries to override. **CORRECTED 2026-08-30 — `O` IS one of them.** This line previously listed (E, O, W, T, S) as "no defaults, work automatically"; `ctrl+shift+o` is in fact swallowed by an Alacritty default. **Where it is documented (corrected again after review):** it is a shipped `[[hints.enabled]]` default — `man 5 alacritty` shows `binding = { key = "O", mods = "Control|Shift" }`. It is a *hints* binding, not a `keyboard.bindings` one, which is why it does not appear in `man 5 alacritty-bindings` and why an earlier note here wrongly said "no man page". Look in the hints section. It left herdr's split-down silently dead. Verified at the keyboard with `scripts/herdr-keyprobe.sh`: the signature is a **release event with no matching key-press** (`ESC[111:79;6:3u` arriving alone), because Alacritty bindings fire on press and consume it while the kitty protocol still reports the release. E, W and T were re-probed and do deliver presses; S was not re-tested. **Do not infer from one working letter that the class works — probe each chord you bind.** Preferred override is `action = "ReceiveChar"` ("treat as unbound") rather than a hardcoded `chars` CSI u string, since it follows whatever encoding mode is active instead of forcing kitty sequences into a legacy-mode terminal.
- **GNOME settings** — not files, so not symlinked. Applied to the dconf database via `scripts/apply-gnome-settings.sh` (run by `./install` on GNOME, or `gnome-apply`). Machine-specific layer: `~/.gnome-settings.local` (template: `examples/gnome-settings.local.template`, install with `gnome-init`). See [GNOME Desktop Configuration](#gnome-desktop-configuration).
- **Backup config** — `~/.backup.local` (repo paths, B2 keys, healthcheck URLs) is created from `examples/backup.local.template` by `./install` on GNOME (or `backup-init`) and never overwritten. The backup *policy* lives in `resticprofile/profiles.toml`, **copied** (never symlinked — root runs its hooks) to `/etc/resticprofile/` by `backup-setup`. See [Backup & Restore](#backup--restore).

### The checkout IS the deployment

Everything above is a **symlink into the git working tree**. Nothing is copied. So
`git checkout` in this repo is not a branch switch, it is a deploy: the instant HEAD
moves, `~/.zshrc`, `~/.gitconfig`, `~/.config/git/ignore`, the gh account configs and
the rest change under the running system — no install step, no restart, no log line,
and `git status` stays clean throughout. `~/.zshrc` also sources the whole of `zsh/`,
so a change to `zsh/functions/system.sh` is just as live as a linked file.

Both directions have caused real failures, both on 2026-08-31:

- **Behind the default branch.** The checkout predated PR #87, so `backup-doctor` was
  still printing `• external HDD not docked (normal — B2 covers offsite)` — the exact
  false reassurance that had already let a backup outage run unnoticed. Found, fixed,
  reviewed, merged, and still not running, because nothing re-pointed the symlink
  target at the fix.
- **Ahead of it.** ~830 lines of an open, unmerged, unreviewed PR's `zshrc.company`
  were being sourced by every new interactive shell.

Note the asymmetry that proves the mechanism: system-level files are **copied**
(`/etc/udev/rules.d/99-backup-external.rules`, `/etc/resticprofile/profiles.toml`), and
they kept working across the same branch switch that broke the symlinked half.

**The convention: the primary checkout stays on `main`; feature work happens in a
worktree.** No symlink points into a worktree, so you can edit, rebase, stash and
bisect there without changing the shell you are typing into.

```bash
dotfiles-work my/branch      # create/enter ~/dotfiles-worktrees/my-branch
dotfiles-work --list         # list worktrees
dotfiles-work --remove b     # remove one; deletes its branch only once its tree is on origin/main
dotfiles-doctor              # is the live config the reviewed config?
dotfiles-doctor --fetch      # ...compared against the actual remote, not a stale ref
```

**Performing the deploy — and `git pull` is NOT the command.** Advancing the primary
checkout is the whole deploy, and the obvious way to do it fails **in this repo's
ordinary resting state**, which is why it is written down here rather than left to be
rediscovered:

```bash
git -C ~/.dotfiles fetch origin main
git -C ~/.dotfiles merge --ff-only origin/main   # NOT `git pull`
bash ~/.dotfiles/install                          # renders/relinks what moved
dotfiles-doctor                                   # before and after
```

`pull.rebase = true` is set in `~/.gitconfig` — *itself a managed symlink into this
repo* — so `git pull` attempts a rebase and aborts with `cannot pull with rebase: You
have unstaged changes` the moment anything is dirty. **`--ff-only` does not override
it**; the rebase is chosen before the fast-forward is considered. And this repo
*expects* a dirty file: `DOTFILES_EXPECTED_DIRTY` defaults to
`config/herdr/plugins/plugins.lock`, a symlink `herdr-lazy` writes straight through by
design. So the failure is not an edge case — it is the normal state, and the deploy
command has to be one that tolerates it.

A fast-forward **merge** needs no clean tree, provided the dirty paths are not in the
incoming diff. Check that first, because a merge that *does* touch them will stop
halfway:

```bash
git -C ~/.dotfiles diff --name-only HEAD..origin/main   # dirty paths must not appear
```

**Do not reach for `git stash` to make `pull` work.** The stash stack is shared with
every worktree and every other agent session on the box, so a `pop` can take somebody
else's work — the hazard `dotfiles-work` exists to avoid in the first place. If the
dirty file genuinely blocks the merge, deal with that file; do not park it somewhere
global.

One asymmetry to expect afterwards: a squash-merged branch is **not** an ancestor of
`main`, so `git merge-base --is-ancestor` reports "not merged" for a branch that landed in
full — and `git branch -d` refuses it for the same reason, which is why the delete has to
be `-D`.

**Do not reach for a tree diff as the replacement.** An earlier version of this section
said `git diff <branch> origin/main` being empty is the test that answers whether a branch
landed. It is not, and it fails in the ORDINARY case: the moment any other commit lands on
`main`, that diff is non-empty for a branch whose own work is fully merged. Restricting it
to the files the branch touched does not rescue it either — nearly every change here
touches this file, so `CLAUDE.md` always differs.

**The merge record is the authority**, not the tree:

```bash
gh pr view <n> --json state,mergeCommit     # MERGED, and the commit it landed as
git -C ~/.dotfiles log --oneline --grep '(#<n>)' origin/main
```

A tree diff can only corroborate, and only while `main` has not moved since the merge —
`git rev-list --count <branch>..origin/main` must be `0` for it to mean anything.

`dotfiles-work --remove` inherits the weak test today (the `--quiet` diff against
`origin/<pin>`). It errs safe — it keeps the branch and prints the `-D` command rather
than deleting something unmerged — but the guard therefore almost never fires, and its
message asserts something false. Measured 2026-09-08 on DO-583's own branch, merged as
`e1a68d9`: "Kept branch …: it differs from origin/main … Once it has landed", about a
branch that had already landed.

`dotfiles-doctor` reports the pin state, how stale `origin/main` is, commits
ahead/behind it, **which managed files actually differ** (the blast radius, not just a
commit count), uncommitted changes to those files, `safe.directory` entries that a tool has
written through `~/.gitconfig` into the tracked `gitconfig` (see below), and link integrity
in four directions — declared-but-not-installed, installed-but-dangling,
linked-but-pointing-outside-this-checkout, and linked-inside-the-checkout-but-at-the-
wrong-file (rename a source without re-running `./install` and the first three all pass
while the live file is the old source, permanently).

A one-line warning also fires on the first prompt of any shell whose live config is off
the pin branch, **or is on it at a different commit than `origin/main`**, **or is on it
and matching a ref older than `DOTFILES_STALE_WARN_HOURS` (168 = 7d)** — that second
case is the #87 outage, and nothing about a checkout sitting on `main` looks wrong. The
third exists because the first two shas are both read off local disk, so they agree the
moment the machine stops fetching: "identical to `origin/main`" on a checkout that has
not fetched in a month means identical to a month-old idea of `main`. The threshold is
far more forgiving than the doctor's 24h deliberately — the doctor is asked, this fires
unasked, and a line that appears every morning is a line nobody reads. Once per *shell*,
not once per source: re-sourcing `zshrc` (`zshreload`) does not reprint it. It
reads `.git/HEAD` and the two ref files directly rather than forking `git`: 0.07 ms for
HEAD, 0.3 ms including both refs, against 2–5 ms for a single `git symbolic-ref` on this
box, on every shell, forever. It cannot say *which* direction the divergence goes
(that needs a merge base, which needs a fork), so it does not claim one.

**Every layer of this feature fails by looking clean**, so each check is written against
the state that produces a green tick rather than an error. The ones that bit during
review, all of which reported success:

- **`config check`-style existence is not currency.** Nothing on this machine fetches on
  a schedule, so `origin/main` is exactly as old as the last time a human typed
  `git fetch` — and against a week-old ref, "not behind" means "not behind whatever was
  true then", which is #87 reported as an all-clear. The doctor therefore states the
  fetch age every run and warns past `DOTFILES_FETCH_MAX_AGE_HOURS` (24), which
  suppresses the unqualified ✓. `--fetch` is the only form that answers about the real
  remote.
- **`./install` from a worktree re-points the whole live config at a feature branch**,
  silently: `git status` stays clean either side, and the doctor's branch and drift
  checks read the primary checkout. Three things now catch it: `install` refuses
  (`DOTFILES_ALLOW_WORKTREE_INSTALL=1` overrides), the doctor
  resolves every link to check it lands inside the checkout (testing only "is it a
  symlink" passed that state with "17/17 declared links present"), and the startup line
  resolves `~/.zshrc` — where the shell it is warning in was actually sourced from — with
  zsh's `:A`, so it stays forkless.
- **The live set is bigger than the link list.** `zsh/` is sourced by the linked
  `~/.zshrc`, and `scripts/` is executed *by path* out of the working tree — every
  `backup-*`/`audit-*`/`gnome-apply`/`verify-tools` command shells out to
  `~/.dotfiles/scripts/…`, and `systemd/herdr-server.service` has
  `ExecStart=%h/.dotfiles/scripts/herdr-server-launch.sh`. Omitting `scripts/` hid four
  drifting files, one of which writes root-owned files into `/etc`. `resticprofile/`,
  `audit/` and `udev/` are deliberately *not* in the set: they are **copied** to `/etc`,
  so moving HEAD does not change what runs — `backup-doctor`/`audit-status` drift-check
  those instead.
- **An unparseable `install.conf.yaml` yields no paths, and no paths reads as no drift.**
  The map is parsed once and a failure to read a single link is reported as
  `what is live is UNKNOWN` with a non-zero exit, never as "every live file matches".
  "Could not read the file" and "the `link:` block declares nothing" are named apart,
  because their fixes differ.
- **A pathspec that matches nothing exits 0 with empty output**, so every way of getting
  a source wrong *narrows* the drift check instead of failing it — and the narrowing is
  invisible. Four of them were live at once: a quoted scalar (`~/.zshrc: 'zshrc'` is
  ordinary YAML) kept its quotes; dotbot's null form (`~/.vimrc:`, source inferred from
  the destination's basename minus one dot — `link.py:_default_target`) was dropped
  whole; `target` was never cleared when the `link:` block ended, so the next `path:`
  anywhere below became the last link's source; and nothing checked that a declared
  source *exists*, so `~/.zshrc: zshrcc` would take the most live file in the repo out
  of every check and still print a green tick. Every declared source is now asserted
  present in the tree, once, before anything derived from the map runs.
- **`~/.config/mise/config.toml` is a live symlink that dotbot does not create** —
  `install` makes it itself, so it is in no `link:` block and was in nothing the doctor
  checked. It is emitted alongside the declared links now, under both halves of
  `install`'s own gate (the source exists, and mise is installed), so a machine without
  mise does not get a permanently-red check for a link that correctly does not exist.
  What its drifting costs is already recorded above: ~11 tools off `PATH` and a dead
  `git diff`, for months.
- **`git status --porcelain` is not a format you can compare paths against.** It
  C-quotes any path with a space and writes a rename as `old -> new`, so no
  `DOTFILES_EXPECTED_DIRTY` entry could ever match either and such a file was a
  permanent, inexcusable warning. `-z` records are unquoted; a rename's original path
  arrives as its own record; and the variable may now be a zsh array, since
  word-splitting a scalar makes a path with a space impossible to express.
- **`cond && ok || bad` reports both outcomes when the ✓ printf fails** (SC2015),
  counting a failure for a check that passed. Not academic: `zsh`'s printf returns 1 on
  ENOSPC, so a redirected run on a full filesystem inverted five checks. The lint that
  names this never sees the file — the ShellCheck job selects by `^#!` shebang and
  `zsh/functions/*.sh` has none, while pre-commit excludes the directory outright
  because the syntax is zsh. CI's `zsh -n` loop now covers it, which is the only static
  check that ever will.
- **`[[ -f .git ]]` is not the worktree test.** A `--separate-git-dir` clone and a
  submodule also have a `.git` FILE, and both are ordinary places to install from — they
  got `./install`'s refusal on every run and a `dotfiles-doctor` that returned 1 forever,
  with only an env var framed as "deploy this worktree" to escape. git's own definition
  is git-dir ≠ git-common-dir (`install`), or the `commondir` file git writes in a linked
  worktree's git dir (the forkless startup path).
- **A git that cannot read the repo answers every question with silence.** A malformed
  `~/.gitconfig` (itself a managed symlink, so a bad branch can cause this) made
  `rev-parse` fail and the doctor announce "no origin/main ref — Fix: git fetch origin"
  when the ref was there. One health probe runs first; if it fails, the doctor says so
  and reports nothing else.
- **Noise in normal states is a failure too.** The working-tree check is scoped to the
  live paths (unscoped it reported every scratch file and `node_modules/` in the tree),
  `DOTFILES_EXPECTED_DIRTY` covers files a tool is *meant* to write through its symlink
  (`plugins.lock`, per `install.conf.yaml`), and a conditional link (`if:` in
  `install.conf.yaml`, e.g. `~/.p10k.zsh`) that is correctly absent is a note, not a
  failure — reporting it as one made the doctor exit non-zero forever.
- **`dotfiles-work <branch>` needs `--no-track`.** Without it the new branch takes
  `origin/main` as upstream, and under this repo's own `push.default=simple` a plain
  `git push` fails and suggests `git push origin HEAD:main` — pushing unreviewed commits
  straight onto the protected branch. It also refuses a leftover directory that is not a
  worktree instead of `cd`-ing in and reporting success.
- **`dotfiles-work --remove` could not remove any worktree `./install` had run in
  (DO-583).** `install` populates the dotbot submodule in whichever checkout it runs from
  (in a worktree, only under `DOTFILES_ALLOW_WORKTREE_INSTALL=1`, or by a hand-run
  `git submodule update`), and `git worktree remove` refuses a worktree containing one —
  `working trees containing submodules cannot be moved or removed` — so the documented
  cleanup worked only on worktrees nobody had installed from (2026-09-08: one of each, the
  installed one refused). The fix is `--force`, which also skips git's dirty-tree check,
  so the function runs that check itself first — the same `status --porcelain
  --ignore-submodules=none` git runs, pinned with `GIT_DIR`/`GIT_WORK_TREE` the way git
  pins it (a plain `git -C` discovers UPWARD when the gitfile is gone and reads an
  ancestor repo as clean), plus `--untracked-files=normal`, because
  `status.showUntrackedFiles = no` makes an untracked file print NOTHING and git's own
  check has that hole — and refuses on any output **or on a status it cannot read**;
  `--remove --force` is the explicit override. Two refusals `--force` does not override:
  a directory git does not list as a worktree, and a worktree any live managed link
  resolves into — the worktrees this fix makes removable are exactly the ones an install
  has run in, and removing one would leave those links dangling; the remedy is
  `./install` from the primary, which is non-destructive. **Enumerated, not
  sentinelled:** the first version checked `~/.zshrc` alone, and `./install --herdr`
  never links `~/.zshrc` — it links five herdr destinations including the systemd unit
  that owns every agent session, and a herdr-shape worktree was removed with rc 0 and
  left the unit dangling. Every destination in BOTH confs is checked now, read from the
  primary and from the worktree, with the mise link and `~/.zshrc` as a floor. `git submodule deinit` first was the obvious alternative and does not
  work: git refuses on the mere existence of `.git/worktrees/<id>/modules`, which deinit
  keeps, and deinit run inside a worktree removes `submodule.<name>.*` from the **shared**
  config, unregistering the primary checkout's copy from a command whose whole purpose is
  to leave the primary alone. One `--force`, never two: a locked worktree still refuses.
  Afterwards the branch is deleted with `-D` only when `git diff <branch> origin/main` is
  empty (the squash-merge test above — `-d` and `merge-base` call a fully landed branch
  unmerged), kept with the `-D` command printed otherwise, kept when the comparison
  cannot run, and **never deleted when it is the pin branch** — `dotfiles-work main` is
  allowed while the primary is off-pin, and main's tree is origin/main's by definition,
  so without that arm `--remove main` deleted local `main` and called it landed. Every row for it runs against a fixture with a REAL populated submodule, and
  the fixture asserts git refuses the plain remove before any row runs — otherwise the
  rows pass with the fix reverted.

**The umask is part of "what is live in this shell", and it failed the same way.**
Ubuntu's `pam_umask` relaxes 022 to 002 whenever the login group is named after the user
— sound reasoning, because such a group is normally yours alone. `dev-setup` breaks that
assumption: `modules/system.sh` adds the `quantivly` service account to the user's group
(`getent group zvi` → `zvi:x:1000:quantivly`), so under 002 nearly every file the user
created was group-writable by an account that never logs in — `$HOME` dotfiles included,
and `.zshenv` that way is a code-execution path, not just a disclosure one. Nothing
reported it, because 002 on a user-private group is the correct, expected value.

The fix is removing the extra member (`sudo gpasswd -d quantivly zvi`);
`_dotfiles_umask_guard` is the belt to that braces, and it is **gated on the condition,
not on the order the fixes were applied in**. It reads the login group's member list and
tightens to 022 only while somebody else is in it — so it is right before *and* after the
`gpasswd`, stops firing by itself once the grant is gone, and leaves sharing alone on the
hosts where the reverse grant is genuinely load-bearing (which is why a blanket
`umask 022` in a repo installed on other people's machines would be wrong). Forkless
(`$(<file)` and `$GID`, never `getent`), because it runs in every shell: 0.5 ms.
"Cannot tell" — no `/etc/group` entry, as on SSSD or systemd-homed — leaves the umask
exactly as the system set it and says so, since guessing either way is worse than the
state the machine is already in. `dotfiles-doctor` reports the verdict — via `_dotfiles_umask_verdict`, which decides
without applying, because a read-only health check that resets the umask of the shell it
runs in would quietly undo a `umask 077` set before handling something sensitive.

Three traps in the guard itself, each of which reported success:

- **`umask 022` is an absolute assignment, not a tightening.** On a host already hardened
  to 077 a guard installed to harden it silently *loosened* the mask, and the doctor
  printed `✓ 022`. The numeric repair then produced two more of its own — `$(umask)` is a
  fork in a function documented as forkless, and `$(( 8#077 | 8#022 ))` is 63 **decimal**
  while `umask` parses a bare number as **octal**, so the union set `0o63` from 077 and
  errored `bad umask` from 002. The answer is the symbolic form: **`umask g-w,o-w`** denies
  exactly those bits relative to whatever is set (002→022, 022→022, 077→077, 007→027), with
  no read, no arithmetic and no base to confuse.
- **An invalid `DOTFILES_UMASK` was reported as applied**, and validity belongs to the
  *verdict*, not to applying it: while only the guard knew, `dotfiles-doctor` — which asks
  for the verdict alone — called a nonsense override ✓. The doctor also re-derived the
  comparison with `8#$WANT`, reproducing inside the checker the very defect the guard had
  just been fixed for. It runs the guard in a subshell and compares masks now; a fork in a
  doctor is free, a second implementation of the rule is not.

**Scope, since the above could be read as a guarantee:** `zshrc` is sourced only by
*interactive* shells, so `zsh -c …`, systemd --user units, GUI applications and cron keep
whatever pam_umask handed them. This is a belt and a partial one — removing the extra group
member is the braces and the actual fix. Override with `DOTFILES_UMASK` in `~/.zshenv`, or
just call `umask` in `~/.zshrc.local`.

Overrides: `DOTFILES_PIN_BRANCH`, `DOTFILES_ROOT`, `DOTFILES_WORKTREES`,
`DOTFILES_GUARD_QUIET=1` (silence the startup line while dogfooding a branch),
`DOTFILES_FETCH_MAX_AGE_HOURS`, `DOTFILES_STALE_WARN_HOURS`, `DOTFILES_EXPECTED_DIRTY`
(scalar or array), `DOTFILES_ALLOW_WORKTREE_INSTALL`, `DOTFILES_UMASK`,
`DOTFILES_GROUP_FILE`.

State table: `scripts/test-dotfiles-guard.sh` (371 checks, run in CI, hermetic — it
builds its own fixture repo, remote and `HOME`). Every bug found in the guard so far
printed a green tick rather than an error, so each one is a row: a `local path`
declaration that blanks `PATH` in zsh, a diff against a ref that did not exist, a stale
ref, an unparseable link map, a symlink into another worktree, an emptiness guard made
unreachable by a hardcoded fallback path, and every way of naming a link source that
makes its git pathspec match nothing. Each is pinned by mutation: the fix is reverted in
a copy of the tree and the row that names it has to fail. It also covers the `_doctor_*` reporting
helpers that `dotfiles-doctor` and `backup-doctor` share — including the "declare the
counters `local`" convention, asserted over every function that calls `_doctor_summary`
rather than a fixed list, because a doctor that forgets it silently restores the globals
and inherits the previous run's exit code.

### `safe.directory` in the tracked gitconfig (DO-589)

`~/.gitconfig` is a symlink into this checkout and `git config --global` writes **through**
the link, so a `safe.directory` entry added by anything lands in a tracked file in a public
repository. Seven did between 2026-09-03 and 09-07, each an absolute `/home/<user>/…` path
carrying an agent session UUID — and **no agent typed one**: both sessions' transcripts,
subagents included, contain no `git config` call. The writer was auto-conf's `configure.py`.
`ConfigModuleBuilder.ensure_config_is_initialized` runs
`git config --global --add safe.directory <output_dir>` for every workspace it builds (since
2022-08-08, for a "dubious ownership" error on servers where git runs as a different user
than the workspace owner), guarded only by a dedup that recognises the literal `*` or the
exact path. auto-conf's own test suite has known for a while — its `isolate_git_config`
fixture points `GIT_CONFIG_GLOBAL` at a throwaway file and its docstring names "a symlink
into tracked dotfiles" — but the production path has no such containment.

Three findings, each of which decided something:

- **Every entry protected against nothing.** The directories were owned by the user running
  git — measured with `-c safe.directory=`, which resets the list — and `~/.gitconfig.local`
  already carried `safe.directory = ~/*`, which git 2.46+ reads as "every repository below"
  (a bare `*` needs only 2.35.2; the comment in `gitconfig` had the two conflated, and so
  did `gitconfig.local.example`). auto-conf's dedup does not understand that glob.
- **A `PreToolUse` hook on `git config --global safe.directory` would have matched none of
  the seven.** The command text was `poetry run python ./configure.py …`; the write happened
  inside a subprocess. A third deny hook that misses the whole observed cause is cost without
  cover, so there is none.
- **The fix that removes the cause is upstream, in auto-conf**: add the entry only when a
  probe with the list reset actually fails with "dubious ownership", or contain the write
  with `GIT_CONFIG_GLOBAL` the way its tests already do. Until then, expect a dirty
  `gitconfig` after any configure.py run on a dev box.

What this repo does: `dotfiles-doctor` names the state (`_dotfiles_doctor_safedir`). It
reads the file the link map says `~/.gitconfig` points at — never a hardcoded name — from
the **worktree, the index and HEAD**, because a staged entry is one `git commit` from public
and an index-only one is invisible to a read of the file. Each entry is labelled by **git's
own reading of the value** (`--type=path` expands `~`, `~user/` and `%(prefix)`; only `*`
and a trailing `/*` are patterns; an empty value is the documented list reset; a relative
path is ignored) and then probed with the list reset, so `same owner` / `other owner` is
measured. Uncommitted entries are a ✗ with the fix
`git restore --staged --worktree -- gitconfig` — `--staged` because a bare `restore` copies
the *index* into the worktree and is a no-op the moment the entries have been `git add`ed;
committed ones are a ⚠, since they passed review and an adopter may have committed `*` on
purpose. The generic `⚠ M gitconfig` becomes a pointer only when worktree and index differ
from HEAD by nothing but those entries — decided by stripping them from copies with
`git config --unset-all` and comparing bytes, **not** by parsing a diff, which `color.ui` or
a `diff.external` driver in `~/.gitconfig.local` reshaped into something the first version's
parser read as "only pollution" for *any* edit. Anything git cannot read or parse — the file,
the index copy, the HEAD copy — is `UNKNOWN` or "fix HEAD first", never a tick and never a
restore that would install the broken copy. The commands, and the `GIT_CONFIG_GLOBAL`
include-shim for a tool that writes global config itself, are in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). Making that shim permanent in the shell
layer (option 3 in DO-589) is deliberately *not* done: it reaches only processes that inherit
the interactive shell, it also redirects the writes people make on purpose, and it is a
larger decision than this issue's.

Rows: `scripts/test-dotfiles-guard.sh`, "safe.directory in the tracked gitconfig" (63). The
fixture rationale is in that section's comments. Two things are worth knowing before reading
them: `GIT_TEST_ASSUME_DIFFERENT_OWNER=1` is how a foreign-owned repository is reached
without root, and the "remedy remedies" row runs the fix **as the doctor prints it** and
asserts the tree is clean — the row that would have caught the bare `restore` before a
review did.

### Configuration Loading Order

```
1. Locale export (LANG/LC_ALL — must be before p10k for icon rendering)
2. Powerlevel10k instant prompt (performance)
3. oh-my-zsh core and plugins
4. p10k.zsh theme
5. zsh/zshrc.history
6. zsh/functions/*.sh (core, development, system, github, claude — github and
   claude after system, which defines the shared _doctor_* emitters they use)
7. zsh/zshrc.aliases
8. zsh/zshrc.conditionals → loads three focused modules:
   - zsh/zshrc.conditionals.tools (CLI tool overrides)
   - zsh/zshrc.conditionals.fzf (FZF integration)
   - zsh/zshrc.conditionals.plugins (mise, direnv, etc.)
9. zsh/zshrc.buildlimits (build/test worker caps)
10. zsh/zshrc.herdr (herdr layer — before company, and independent of it:
    a modular adopter sources this one file and nothing else)
11. zsh/zshrc.company
12. ~/.zshrc.local (machine-specific secrets)
13. PATH additions
14. Dotfiles live-config guard — registers a one-shot `precmd` hook that runs
    `_dotfiles_live_config_warn` on the FIRST prompt, then removes itself.
    Deferred rather than run here because p10k's instant prompt turns any output
    during initialization into a warning box.
```

**Key Insight:** Conditionals load AFTER aliases, so tools that are installed get priority configuration.

## Powerlevel10k Customizations

Prompt shows GitHub PR numbers (`#123`) for branches with open pull requests. Uses smart caching for <5ms latency with non-blocking background fetch on cache miss.

- **Implementation:** `_p10k_get_pr_number()` in `p10k.zsh`
- **Cache location:** `~/.cache/p10k-pr-cache/<repo>/<branch>`
- **Manual refresh:** `rm -rf ~/.cache/p10k-pr-cache` (or per-branch: `rm ~/.cache/p10k-pr-cache/<repo>/<branch>`)

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for PR display troubleshooting.

## Security Rules

**CRITICAL:** Never commit sensitive information. All secrets belong in `~/.zshrc.local`:
- API keys, tokens, passwords
- SSH key paths
- Machine-specific environment variables
- Work-related credentials

The `.gitignore` protects: `*.local`, `*.secrets`, `.env*`, `secrets/`

## Development Guidelines

### Adding New Configuration

**New zsh module:**
1. Create `zsh/zshrc.newmodule`
2. Add source line in `zshrc` around line 120-136: `[ -f ~/.dotfiles/zsh/zshrc.newmodule ] && source ~/.dotfiles/zsh/zshrc.newmodule`
3. Test: `source ~/.zshrc`

**New symlink:**
1. Edit `install.conf.yaml` under `link:` section
2. Run `./install`

**Any change at all:** work in a worktree (`dotfiles-work <branch>`), not by moving the
primary checkout — see [The checkout IS the deployment](#the-checkout-is-the-deployment).
Check with `dotfiles-doctor` before and after.

### Oh-My-Zsh Plugins

Current plugins: autojump, colored-man-pages, direnv, extract, gh, git, poetry, safe-paste, sudo, web-search, zsh-autosuggestions, zsh-fzf-history-search, zsh-syntax-highlighting, quantivly

**Note:** fzf is *not* an oh-my-zsh plugin here — its shell integration loads via `eval "$(fzf --zsh)"` in `zsh/zshrc.conditionals.fzf` (runs after mise activation; mise installs the fzf binary only, with no bundled shell scripts).

**Note:** `zsh-syntax-highlighting` must be last in the list.

### CI/CD Testing

GitHub Actions runs: ShellCheck, syntax validation, YAML validation, pre-commit hooks, installation tests (Ubuntu 22.04/24.04), security scans, and documentation checks.

**Run locally:**
```bash
pre-commit run --all-files    # All checks
bash -n install               # Syntax check
shellcheck -x install         # Lint
act -j shellcheck             # Run specific CI job locally (requires act)
```

See `.github/README.md` for details.

**`apt-get update`'s exit status is not evidence about the job running it (DO-608).**
It exits non-zero when **any** configured source errors, and the runner images ship
third-party lists (Google Chrome, Microsoft Edge) that no job here reads. On 2026-09-09
Google's repo served a `Packages.gz` that did not match its own `Release` file, and ten
steps shaped `sudo apt-get update && sudo apt-get install -y …` took **11 of 20 jobs red
for ~40 minutes on every branch** — then hid a genuine `Pre-commit Hooks` failure for a
day underneath the noise. Measured against a fixture repository (root-free — `Dir::Etc`,
`Dir::State` and `Dir::Cache` redirected into a temp tree): a source whose `Release`
advertises a `Packages` hash it does not serve gives `E: … Hash Sum mismatch` and **exit
100**, while a healthy source configured alongside it **still lands its index and its
package stays a valid install candidate**. So the install was always possible; only the
gate failed. An *unreachable* source is merely `W:` and exits **0** — a different class,
and the reason "it exits non-zero on a broken repo" is too coarse a summary to reason
from. All apt installs now go through `.github/actions/apt-install`, which holds that
reasoning once, warns via `::warning::` when the refresh reports errors, and keeps the
**install** strict — so a genuinely broken Ubuntu archive still fails the job, loudly.
Two alternatives were rejected for reasons this file already records elsewhere: dropping
`google-chrome.list` names one vendor and leaves the next third-party repo fatal, and
`-o Dir::Etc::sourceparts=/dev/null` would silently drop the **main** archive on Ubuntu
24.04, where it lives in `sources.list.d/ubuntu.sources` — a pathspec that matches
nothing narrowing a check invisibly.

Traps in the guard written for it, every one of which reported success. They are
listed because the guard was **29/29 green over all of them at once** — an
independent review reproduced seven live defects against a fully passing suite,
which is the "rows that check the plumbing and not the answer" case this file
already records, met at scale:

- **The rule matched the literal string `apt-get <verb>`**, so `sudo apt update
  && sudo apt install -y zsh` — the spelling people actually type — and
  `sudo apt-get -qq update && …` were invisible to every rule. Program and verb
  are matched separately now, with word boundaries so `aptitude` and `adapt` stay
  out.
- **Asking whether `&&` is absent asked about the MECHANISM.** Four regressions
  *inside the composite action* — the one file that runs apt, and the one the
  workflow-scoped rules never inspect — all printed `all 6 checks passed`:
  `set -euo pipefail` plus a bare refresh (a complete restoration of the outage,
  and what "hardening" looks like to the next person), `update -qq &&`,
  `update || exit 1`, and `update; install`. Three contain no `&&` at all, so no
  tightening of that token could ever reach them. The rule is now the positive
  form — every refresh must sit in a construct that cannot fail its step (an
  `if` condition, or an explicit `|| true`) — because GitHub runs a composite
  `shell: bash` step as `bash --noprofile --norc -eo pipefail`, so a bare refresh
  is fatal whether or not the script says `set -e`, which is also why scanning
  for `set -e` would be the wrong test.
- **`… | grep -q PAT && var=…` under `set -o pipefail` is a RACE**, and it loses
  most often on the files you care about. `grep -q` exits at its first match; if
  `sed` still has output pending it dies of SIGPIPE and pipefail fails the
  *pipeline*, so a matched pattern reads as *no match*. Measured: 0 in 30/30 runs
  at 27 KB, 141 in 30/30 at 289 KB, and `ci.yml` at 29 KB missing its own ten
  violations in **13 of 20 runs**. This is the SC2015 family, one layer down.
- **Line-based quote stripping hid real violations two ways.** Two apostrophes
  inside *separate* double-quoted strings paired with each other and swallowed
  the command between them; a `#` inside a quoted string truncated the line.
  Both are ordinary shell. The stripper is character-by-character and
  quote-aware now, and after the fix it removes exactly what a shell would treat
  as quoted — so anything it hides was never going to run as a command.
- **YAML prose is not shell.** A step whose `name:` named the forbidden shape was
  reported as three violations *while correctly using the action*, with a remedy
  telling the reader to do what they had already done; the action's own
  `description:` failed the refresh rule the same way. Matching is scoped to
  `run:` scalars now. A checker that refuses a correct workflow gets deleted —
  the permanently-red failure this file records five times.
- **An empty answer was agreement, twice.** The `${{ }}` rule extracted the run
  block with `awk` and grepped it, so a one-line or folded `run:` yielded an
  *empty* extraction that read as "no interpolation" — a tick over the exact
  injection it forbids. It is a positive-form count now (every `${{` must be an
  `env:` assignment) with no empty case. Separately, `ACTION_REL` hardcoded
  `action.yml`, so renaming to the equally-valid `action.yaml` printed a false
  "is missing" **and silently dropped the check count from 6 to 4** — two
  assertions never ran and nothing said so. Both extensions resolve now, and a
  fixed `EXPECTED_CHECKS` makes a run that performed fewer checks than expected
  a failure in itself.
- **`apt-get install -y` with no operands exits 0**, so the "strict install"
  claim was hollow: `inputs.<id>.required` is advisory, the runner does not fail
  a step for a missing input, and `set -u` does not help because `PACKAGES` is
  set and merely empty. A job whose only package is preinstalled (`jq`) would
  have stayed green forever with the install switched off. The action refuses an
  empty or whitespace-only list now.
- **An unquoted expansion globs as well as splits.** The step's cwd is the
  checkout, so `packages: 'zsh*'` expanded against repository files — measured,
  it became `zsh-real` and apt failed naming a filename. A `*` is legal in apt's
  own patterns, so this needed no attacker. `read -ra` plus `-- "${pkgs[@]}"`
  splits without globbing and stops a package name beginning with `-`.
- **Two of the fixes were then unpinnable, and the fixture size was why.** The
  row for the SIGPIPE race used a ~20-line fixture, far too small to trigger it,
  so reinstating the bug passed the suite; and once the racing code was gone the
  oversized replacement fixture cost **205 seconds per check**, because the first
  version of the shell-scoping helper forked `awk` once per line. The helper is
  one `awk` pass now (2.4 s on the same 560 KB input) and the race is pinned at
  the source instead — the checker must never pipe into `grep -q`, which is
  deterministic and free, where a behavioural row could only be probabilistic.
- **A fixture built by a `python3` heredoc goes quiet when `python3` is absent.**
  The row then asserted its expected exit code against an *unmodified* fixture
  and passed for a reason unrelated to the rule — no error, no skip. Rebuilt
  with `sed`, plus an assertion that the edit applied. This is the class this
  file already records for `verify-tools.sh`: a new external tool in a checker is
  a new way for a check to go quiet.

State table: `scripts/test-workflow-apt.sh` (112 checks, in CI as
`workflow-apt-test`) over `scripts/check-workflow-apt.sh`. Hermetic — every row
builds its own fixture tree and is handed an explicit root; only the last rows
read this repository, to assert the shipped tree passes. Most rows assert what it
must **not** flag, because a false positive costs the whole check while a miss
costs one outage: a comment naming the forbidden line, a commit message
mentioning it, an unquoted YAML `name:` describing it, `aptitude`/`adapt`, a
quoted `env:` value, and a mid-word `#` all have to pass. "Could not run" is exit
2, never a pass, and the suite asserts its own total so a row that VANISHES —
an emptied `for` list, an early exit in a fixture builder — fails rather than
shrinking the denominator under a cheerful "all N passed".

Be precise about what those count guards do and do not see: they count reported
checks, so they detect a check that was **skipped** and never one that was
**hollow**. Every defect listed above kept the count at exactly six while
printing six ticks over a hidden violation. A rule that stops being *reached* is
invisible to them, which is why the rows above are what actually hold this
guard up.

- **A file-extension clause no fixture exercised was decoration, twice.** Every
  fixture wrote `ci.yml`, so `-o -name '*.yaml'` was unpinned in both finds —
  and with it removed, a violating `release.yaml` was invisible while the suite
  stayed green. GitHub accepts either extension; the only reason the repo was
  safe is that nobody had named a workflow `.yaml` yet. Worse, a hardcoded
  `action.yml` had been *accidentally* covering the same gap for the action
  (it reported "is missing"), so accepting both extensions removed a fail-safe
  nobody had chosen — which is exactly why the extension now has a row instead
  of an accident. The narrowing that IS deliberate — `-maxdepth 1`, because
  GitHub does not read nested workflow files — has its own row saying so, and
  the refresh rule was rescoped to agree with it rather than scanning every
  YAML under `.github` and disagreeing with the rules beside it.
- **Both halves of a two-state stripper need both directions.** The rows
  covered double quotes only, so deleting the single-quote branch survived
  while false-positiving on `git commit -m 'stop apt-get update failing CI'` —
  the more natural spelling of the two. Each state now has a must-pass row and
  a must-catch mirror.
- **The one path a human takes was executed by nothing.** Every row passed an
  explicit root, so the default `git rev-parse --show-toplevel` branch — what
  you get typing the script's name with no argument — had no coverage, and
  making its exit code 0 survived the suite.

**The guard now parses YAML with a YAML parser, and that is the finding.** Three
independent review rounds found **seventeen** defects in this one checker, every
one of them under a fully green state table. Rounds one and two were fixed by
patching. Round three found eight more, six of which were the same kind of thing:
`run: |  # refresh, then install` is valid YAML but a comment after the block
indicator meant the hand-written awk parser never opened the block, dropped the
whole script and silenced **three rules at once**; a step's sibling keys are
indented deeper than the `- ` of `- run: |`, so they were read as block body and
a `name:` describing the forbidden shape became a false violation; a multi-line
string's continuation lines were scanned as unquoted shell because quote state
reset per line; CRLF broke block detection the same way; and the install-strict
check read the whole file, so an unquoted `description:` mentioning
`apt-get install -y` satisfied it while the action installed nothing.

The pattern, not the bugs, is the lesson: **those are YAML questions, and each
round of patching produced a new way to answer one wrongly.** `scripts/gha-yaml-shell.py`
now hands the checker the shell of every `run:` scalar and the placement of every
`${{ }}`, using PyYAML. Six defects stopped being reachable rather than being
fixed. What remains is genuinely shell-level — operator position, apt's option
forms, heredoc bodies — and lives where it belongs.

The dependency is deliberate and it cannot go quiet: PyYAML missing, a file
unreadable, or YAML that does not parse all exit **2**, and the CI job installs
`python3-yaml` through this repo's own composite action. That matters because
this repo already records what a quiet dependency costs a checker, and the first
version of the very code enforcing it had the bug it was written against — the
helpers ran inside `$(...)`, so their `exit 2` exited the *subshell* and the
parent read zero records as "this file contains no shell", passing an
unparseable workflow clean. Status is tested in the parent now. `require_emitter`
was also **defined and never called** for a while, which no linter here catches.

Two smaller things worth keeping from the same round. **`grep` is not GNU grep
everywhere** — on this machine it resolves to a `ugrep` shim, which rejected a
`grep -P` pattern the CI runner's GNU grep would have accepted; the matching is
awk now, which this checker already depended on. And **a fixture can be wrong in
a way only a real parser reveals**: a row asserting that a `#` inside a quoted
string must not truncate the line used `- run: echo "tag #1" && sudo apt-get
update`, where ` #` opens a *YAML* comment — so the value is `echo "tag` and apt
never runs at all. The hand parser had been flagging a line GitHub would not
execute, and the row encoded that mistake. It needs a block scalar to mean what
it says.

**The mutation figures across three rounds, with the set beside the ratio,
because the ratio alone is what misled the first time.** An independent reviewer
grew the set each round specifically into rules that had no rows — the only way
the number means anything: **27/8 at `133cc91`, 31/12 at `e4bb8f3`, 36 mutants
with 27 killed and 9 survivors at `e381571`.** The set covered the file finds,
every branch of the shell scoping, all three copies of the quote stripper,
`apt_re`, the refresh-fatality rule and its excuse-path, the interpolation rule,
the count guards, and two mutations of `action.yml` itself.

**Every figure carries the commit it measured, deliberately.** Each of those
three trees is now several commits stale, and a ratio without its commit reads
as the suite's current coverage to anyone who finds it later. The round after
`e381571` was abandoned part-way — 16 of 34 measured, 10 killed, 6 survived, 18
never run, after the OOM watchdog killed the sweep three times on a box at
loadavg 66 and 21.6 GB of 23.7 GB swap. **That partial is deliberately not
recorded as a coverage figure**: a partial denominator quoted as a result is the
same shape as the "9 mutants, 9 deaths" claim this section exists to retract.
The reviewer said so about their own number before I could, which is the right
instinct to copy.

Two things about those numbers matter more than their size. **Every survivor of
the last round kept the check count at exactly six**, which is the evidence for
the honest label on the count guards above — a guard green over 9 of 9 of a
round's real defects is worth having and must not be described as coverage. And
**five of the nine clustered in the newest code**, the hand-written parser,
which is what decided the rewrite rather than a fourth round of patching. The
figures above are for the awk implementation; the parser rewrite came after
them, so no re-run has yet measured what shipped — recorded as unmeasured rather
than assumed to be better.

**The parser rewrite then produced a defect of its own, and the row written for
it was green BECAUSE of it.** `_heredoc_marker` read the delimiter from the
already-quote-stripped line, so `cat <<'EOF' > note.txt` — the *more* common CI
spelling — stripped to `cat << > note.txt`, whose "delimiter" was `>`. Nothing
later matched it, the heredoc never closed, and **every remaining line of that
run script was dropped**: `all 6 checks passed` over a complete restoration of
the outage. `mask=$(( 1 << 3 ))` did the same on `3`. The single heredoc row
asserted rc=0 and passed *in virtue of the defect* — it could not distinguish
"bodies are data" from "everything after is silently gone", which is why a
mutant making the end-marker never match survived it.

Three things fixed it and are worth stating as rules: read the introducer from
the **raw** line, inside the scan where quote state is known, so a quoted
delimiter works and a `<<` inside a string is not one; require a delimiter to
**look** like a delimiter (`[A-Za-z_]\w*`), which is what stops arithmetic
opening one; and treat an **unterminated** heredoc as exit 2 rather than
reporting the lines before it as the whole script. The discriminating row is a
real gate placed *after* the `EOF`, asserting that scanning **resumes** — the
row that existed asserted only that the body was ignored, which the defect also
satisfied.

**Two more from the round after that, both in the dependency handling and both
about caching or shadowing rather than logic.**

**`arr[k]=$(cmd)` creates the element even when `cmd` fails** — only the
statement's status is non-zero. So memoising the parser output cached a FAILED
run as a successful EMPTY result: the first call returned 2 and every later call
for that file returned empty with status 0, turning "could not read this file"
into "this file has no shell" — in the helper whose own comment warns about
exactly that. It was masked only because the first caller exits immediately, so
it was a loaded gun rather than a live outage, and it was found by a reviewer
reading the bash semantics rather than by any fixture. Assign to a local first
and populate the cache only on success; the behavioural row calls the helper
twice for a failing file and asserts 2 both times.

**Guards that shadow each other are individually unpinnable.** All four
`|| die_unreadable` call sites survived deletion, because every fixture that
reaches one reaches an earlier one first — and deleting two of them *together*
gave `all 6 checks passed` on an unparseable workflow. Each now has a fixture
whose broken file only that call site reads: a malformed non-workflow YAML under
`.github` for the refresh rule, and an unreadable action file (workflows intact)
for the install and interpolation rules. **The general rule: a row that deletes
one guard proves nothing while another guard upstream can answer for it — count
how many independent deletions it takes to reach a silent pass, not how many
guards exist.** An unreadable file is also a different emitter branch from
unparseable YAML (`OSError`, not `YAMLError`) and had no row at all.

**The cheap half of review outlives the expensive half.** Four gaps in that
round were found by *grepping the suite* rather than by mutation — no CRLF
fixture, no unreadable-file row, no row invoking the parser directly, no
multi-document fixture — and those findings survived four commits of churn,
because they are properties of the suite's text rather than of one tree's
behaviour. Re-checking them at a later commit is a grep; re-running the mutants
is an hour of load. Two were already closed by then and two were real: the
multi-document row is pinned (a single-document walk drops the second document
and the row dies), and **there is deliberately no CRLF row** — measured with the
emitter's `\r` strip removed, a CRLF workflow carrying a gate still exits 1 and
a CRLF action with a tolerant refresh still exits 0, because these patterns
accept a carriage return anyway. The property is protected twice, so no fixture
can distinguish the strip being present from absent. Knowing why a row is
impossible is worth more than having one that always passes.

Recorded and deliberately NOT acted on: the suite went from ~15s to ~62s idle as
it grew to 109 checks, one python start per uncached file per fixture. Combining
the emitter's two modes into one invocation would roughly halve it. It is left
alone because every round of this change has introduced a defect of its own, and
a performance edit is the one kind that cannot fix one — the measurement is here
so the next person can decide with the number in front of them.

Three lessons from that round that generalise past this guard:

- **A `contains` needle must be unique to the RULE, not merely absent from the
  pass path.** Three of this checker's rules print `<file>:<line>` in the same
  format, so a bare path needle is ambiguous by construction: one row passed
  with the verb rule's filename deleted, satisfied by the refresh rule's
  message instead. Anchor on the message prefix.
- **Check the needle against what the PASS path prints.** The interpolation
  rule's ok and bad messages both contain "env: assignment", so that needle
  asserted nothing at all.
- **A row whose fixture fails for more than one reason is decoration however
  carefully worded.** Two rows added for the parser exit 1 from the
  install-strict rule whether or not the property under test holds; only a
  rule-specific `contains` makes them able to fail, and one of them shipped
  without one.

**On the mutation numbers, which is the part worth carrying forward.** An earlier
version of this section claimed "9 mutants, 9 deaths" for this guard. That was
true and meaningless: the set only mutated rules that already had rows, so it
measured nothing about the rules that had none — and the suite it certified was
simultaneously green over seven reproduced defects. A mutation set assembled from
the code you happen to have tested is a mirror, not a check. **Ask of the
mutation set what you already ask of a row: what would it fail to notice?** The
current set is rebuilt against the rewritten matching core, and the honest figure
is whatever an independent re-run reports — recorded when it does, not asserted
here in advance.

## Tool Dependencies & mise

### Required Tools
- **zsh**, **oh-my-zsh**, **Powerlevel10k** (git submodule), **git**

### Strongly Recommended
- **fzf** — Fuzzy finder (many functions depend on it)
- **gh** — GitHub CLI (35+ custom aliases in `gh/config.yml`)
- **tmux** — Terminal multiplexer (session persistence, splits, remote work)

### Modern CLI Replacements

All tools are optional with intelligent fallbacks. Managed by mise.

| Standard | Modern | Standard | Modern |
|----------|--------|----------|--------|
| cat | bat/batcat | ps | procs |
| ls | eza/exa/colorls | df | duf |
| find | fd/fdfind | du | dust |
| grep | ripgrep | diff | delta/difftastic |
| cd | zoxide | top | btop |

Additional: lazygit, just, glow, gitleaks, pre-commit, sops, age, fastfetch

### mise (Version Manager)

Modern polyglot version manager replacing nvm, pyenv, rbenv, asdf (~5-10ms activation).

```bash
mise ls              # View installed tools
mise install         # Install from config
mise trust ~/.dotfiles/.mise.toml  # Trust dotfiles config (one-time)
```

**Config architecture:**
1. **Source of truth:** `~/.dotfiles/.mise.toml` — ~25 CLI tools with pinned versions
2. **Active config:** `~/.config/mise/config.toml` — a **symlink** to the above (corrected
   2026-08-30; this file previously said "copied", which is what let the drift below go
   unnoticed). `mise use -g` writes *through* the symlink to the repo file, so the two cannot
   diverge — which is the whole point.
3. **Project overrides:** `.mise.toml` in project root — per-project versions, requires `mise trust`

**The failure mode this architecture has, and how it is detected.** `./install` only creates
that symlink when the target is absent or byte-identical; if a real file is already there and
differs, it prints one warning and **keeps the local copy forever**. That state is stable,
self-perpetuating, and invisible. It happened here: the live config declared 10 tools while the
repo declared 23, so ~11 installed tools were never put on PATH — including `delta`, which
`gitconfig` routes `pager.diff/log/show/reflog` through, so `git diff` failed outright in a
terminal with `unable to execute pager 'delta'`. Nothing reported it.

`scripts/verify-tools.sh` now asserts both halves: that the symlink is intact, and that every
declared tool actually contributes a binary (`mise bin-paths`). Run it after any mise change.
A version pin that no longer exists in its backend "installs" successfully and produces **no
binary at all** while `mise install` reports success — `glow 1.5.1` and `fastfetch 2.8.10` both
did exactly this.

See [docs/TOOL_VERSION_UPDATES.md](docs/TOOL_VERSION_UPDATES.md) for version update procedures and [docs/MIGRATION.md](docs/MIGRATION.md) for nvm/pyenv migration.

## Python Environment Management

Projects use **mise + direnv + Poetry**: mise for Python versions, direnv for automatic activation, Poetry for dependencies with in-project `.venv/`.

```
project-root/
├── .mise.toml       # Python version
├── .envrc           # Auto-activation (direnv)
└── .venv/           # Virtual environment
```

Setup: `cp ~/.dotfiles/examples/envrc-templates/minimal.envrc .envrc && direnv allow && mise trust && mise install`

See [examples/python-project-setup.md](examples/python-project-setup.md) for complete setup, envrc templates, and dependency checking with quanticli.

## Command Behavior Changes

When tools are installed, standard commands are replaced:

| Command | Replacement | Changed By | Workaround |
|---------|-------------|------------|------------|
| grep | ripgrep (rg) | `zshrc.conditionals:54` | `\grep` or `command grep` |
| find | fd/fdfind | `zshrc.conditionals:44-48` | `\find` |
| cat | bat | `zshrc.conditionals:10-18` | `\cat` or `catp` |
| top | htop | `zshrc.conditionals:64-66` | `\top` |
| ls | eza/exa/colorls | `zshrc.conditionals:24-39` | `\ls` |

**Alias renamed:** `fd` → `fdir` (to avoid conflict with fd-find tool)

**Terminal gotchas:**
- **`$TERM` follows the terminfo, not the config.** Alacritty reports `alacritty` when that terminfo entry exists and falls back to `xterm-256color` when it doesn't — so the value depends on *how Alacritty was installed*, not on `alacritty.toml`. The snap ships no terminfo (→ `xterm-256color`); the apt package pulls `ncurses-term`, which has it (→ `alacritty`). `tmux.conf:94-95` deliberately sets `terminal-features` for **both** patterns, so either value works. Truecolor rides the catch-all `terminal-overrides ",*:RGB"` — note `*256col*` does *not* match `alacritty`.
- **Install Alacritty from apt, not snap** — the snap renders on the CPU. It bundles its own Mesa (23.2.1, from base `core22`) rather than the host's, so a GPU newer than that Mesa isn't recognized by `iris` and Mesa silently falls back to `swrast`/llvmpipe. On this hardware (Intel Lunar Lake, Arc 130V/140V Xe2 — silicon a year newer than the bundled driver) that cost 24.5% of a core sustained at idle and ~73% while rendering a busy TUI. The apt build bundles no driver, so it always uses host Mesa and can't go stale this way. Verify on the running process: no `swrast` in `/proc/<pid>/maps`, ≥1 `/dev/dri` fd, and no `llvmpipe-*` threads in `ps -o comm= -L -p <pid>` (`libgallium-<version>.so` and a `gdrv` thread are the healthy signs; `libLLVM` is *not* by itself a software-rendering signal — Mesa links it for shader compilation on the GPU path too).
- Ctrl+Shift+Arrow works natively in tmux (xterm modifier encoding). Ctrl+Shift+**letter** needs Alacritty key bindings sending CSI u sequences + tmux extended-keys
- tmux `extended-keys` and `terminal-features` are server-level — require `tmux kill-server`, not just config reload

## Important Patterns

### pathadd Function

Always use `pathadd` for safe PATH additions:
```bash
pathadd "${HOME}/.local/bin"  # Checks existence, prevents duplicates
```

### Tool Availability Checks

Use two patterns depending on context:

**1. Direct `command -v` check** - For conditionals and standalone scripts:
```bash
if command -v colorls &>/dev/null; then
    alias ls='colorls --sd --sf'
fi
```

**2. `has_command()` function** - For cleaner syntax in functions:
```bash
has_command() { command -v "$1" &>/dev/null; }

setup_fzf() {
    if has_command fzf; then
        # Configure fzf
    fi
}
```

**Guidelines:**
- Use `command -v` in `zshrc.conditionals` and standalone scripts
- Use `has_command()` inside functions for readability
- Both are fast (~1-2ms); no caching needed
- **One name per call.** `command -v a b c` takes a single operand in POSIX sh, and the
  shells disagree about the rest: measured here, `command -v bash nosuchtool` prints only
  `/usr/bin/bash` and exits **0** in bash and dash, and **1** in zsh — so the same line is a
  silent pass with two tools missing in one shell and an unexplained failure naming none of
  them in the other. It is not academic: `docs/HERDR_GUIDE.md` §2.3 carries this warning in a
  comment, and the team-facing write-up derived from it then used exactly that shape as a
  verification step. Loop, or call it once per tool.

**Historical note:** Tool cache was removed after benchmarks showed 81ms overhead.

### FZF Integration

Key fzf functions: `fcd`, `fbr`, `fco`, `fshow`, `fkill`, `fenv`, `fssh`, `fport`

## Git Configuration

**Key settings:**
- Editor: VS Code (`code --wait`)
- Default branch: `main`
- Credential helper: GitHub CLI (`gh auth git-credential`)
- Commit signing: SSH signing recommended (see below to enable)

**Useful aliases:** `git lg` (pretty log), `git conflicts` (show merge conflicts)

## Commit Signing

SSH signing recommended (Git 2.34+). Configure in `~/.gitconfig.local` with `signingkey`, `gpgsign = true`, `format = ssh`.

See [docs/SSH_SIGNING_SETUP.md](docs/SSH_SIGNING_SETUP.md) for complete setup guide.

## SSH Configuration

Template at `examples/ssh-config.template`. Run `ssh-init` to install. See [docs/SSH_CONFIG_GUIDE.md](docs/SSH_CONFIG_GUIDE.md) for full guide (multiplexing, Bitwarden agent, forwarding patterns).

## GitHub CLI Aliases

35+ `gh` aliases in `gh/config.yml`:
- `gh mypr` - Your open PRs
- `gh prs` - All open non-draft PRs
- `gh review` - PRs where you're requested as reviewer
- `gh prmerge` - Squash merge and delete branch
- `gh runs` - Recent workflow runs for current branch

## GitHub Account Routing (`gh-doctor`)

**`GH_CONFIG_DIR` does not isolate the credential, and `gh auth status` will not tell
you.** gh stores its tokens in the system keyring keyed by **host**, not by config dir,
so `GH_CONFIG_DIR` isolates `hosts.yml` and `config.yml` and nothing else. Observed here
on 2026-09-01:

```
config dir      hosts.yml declares    an API call resolves to
gh              zvi-quantivly      →  zvi-quantivly
gh-personal     ZviBaratz          →  zvi-quantivly   ← mismatch
gh-quantivly    zvi-quantivly      →  zvi-quantivly
```

`gh auth status` reports the *declared* user throughout — so it says `ZviBaratz` while
the API answers `zvi-quantivly`. **A status command describing intent rather than
effect**, the same shape as the `backup-doctor` bug and the live-config guard's false
all-clear. The direction matters: with `GH_TOKEN` unset it falls back to the **work**
account, in any directory, so a personal repo silently gets work credentials while git
correctly signs the commits as personal.

`zshrc.company` already works around it by caching per-account tokens
(`~/.cache/gh-token-cache/{personal,quantivly}`, 600, refreshed on shell start) and
exporting the right one as `GH_TOKEN`; its own comment notes that `gh auth token`
**without `--user`** "returns a shared default that may be wrong". So the mechanism was
known — **the defect is the failure mode**, which is invisible and biased toward work.

There is one deliberate escape hatch: `GH_ACCOUNT_ROUTING_OFF=1` makes the hook return
without touching anything, for a supervisor that provisions per-session credentials of its
own. It replaces the Atrium deferral, whose problem was the *detection* (`$ATRIUM`, or a
tmux socket named `*/atrium` — anything could set either), not the capability; being named
rather than sniffed also lets `gh-doctor` report such a shell as deliberate instead of
faulty.

`gh-doctor` (`zsh/functions/github.sh`) makes it visible. For a directory it prints the
account the **remote** routes to, the account gh **declares**, the account an actual
`GET /user` **returns**, and which mechanism decided (`GH_TOKEN` / `GITHUB_TOKEN` /
config-dir keyring). Everything it says about "effective" comes from a real request;
nothing is inferred from configuration, because that inference *is* the bug. It also
proves the workaround still works — for each config dir it probes twice, once with the
token env cleared (which reproduces the collapse) and once pinned with
`gh auth token --user <login>` (which does isolate) — so nobody is told to rely on a
mechanism that has itself broken.

**Routing follows the repo REMOTE, not `$PWD`** — the rule git identity already uses
(#67, `hasconfig:remote.*.url` in `~/.gitconfig.local`), so a work repo routes correctly
wherever it is checked out and a personal repo under `~/quantivly/` does not get the work
account. Like `hasconfig`, **any** remote can match, not just `origin`: in a fork workflow
origin is the personal fork and upstream is the work repo, and matching origin alone would
hand that repo the personal account while git signs its commits as work.

**A path route decides only what the remote cannot.** `GH_ACCOUNT_PATH_ROUTES` is
consulted for a directory with *no* GitHub remote — not a repository, a repository with no
remotes, or only non-GitHub remotes — and never for one that has a remote, matched or not: a
GitHub remote whose owner matches no route means *personal, by remote*, exactly what git
identity concludes. Precedence is remote owner route → path route → `GH_ACCOUNT_DEFAULT_DIR`,
with `git-error` stopping before any of them. It exists for the work tree's roots that are
not repositories (`~/quantivly/qspace` holds two repositories and is itself none; `drafts`,
`comms-style`, `handoffs`). On 2026-09-09 a Claude Code session started in
`~/quantivly/qspace` took the personal default; Claude's Bash-tool shells are `zsh -c` with
no `.zshrc`, so they inherit Claude's environment verbatim, and the GitHub MCP plugin's
`Authorization` header is expanded from that environment once at startup — so every `gh`
call and every MCP request in the session was the personal account, 404ing on private work
repositories until the session was restarted from a correctly routed shell. One deliberate
trade-off: a repository with *no* GitHub remote under `~/quantivly` (a fresh `git init`, a
GitLab checkout) is routed by place, while git identity stays personal until a quantivly
remote is added — the state `docs/TROUBLESHOOTING.md` already documents for git alone. A
GitHub URL the parser rejects is *not* that case: it counts as a GitHub remote, blocks the
path table, and `gh-doctor` flags it.

The `chpwd` hook (`_update_gh_config` in `zshrc.company`) uses the same
`_gh_route_for` the doctor does — one implementation, so the oracle cannot drift from the
thing it checks — then **pins** the account by exporting `GH_TOKEN` from
`~/.cache/gh-token-cache/<config-dir-basename>`. It routed on `$PWD` first until
2026-09-01, which let gh and git disagree about the same repository: a quantivly clone
outside `~/quantivly/` got the personal account from gh and the work identity from git.

**Every directory now pins an account explicitly; the keyring never decides.** Outside a
repo — `$HOME` is the normal resting state of a shell — the routing falls through to
`GH_ACCOUNT_DEFAULT_DIR` (personal), which is what git identity does there too. That is
deliberately *not* treated as a failure: warning on every `cd` into a non-repo directory is
how a warning stops being read. The loud path is reserved for the states where nothing can
be pinned — no default configured, an unusable table, or a routed account with no cached
token — and even then the message is printed **at most once per distinct message per
shell**, and never before the first prompt (output during initialization lands inside
p10k's instant-prompt warning box, the same reason the live-config guard defers).

The token cache is keyed by the config dir's **basename** (`gh-quantivly`, `gh-personal`),
not by a nickname, so the routing table is the single place an account is named — adding a
route needs no matching edit to the refresher, and a stale nickname cannot address the
wrong dir. `gh-refresh-tokens` and the shell-start background job are both driven by
`_gh_configured_dirs`, and both delete the pre-2026-09-01 nickname files, which would
otherwise sit there as a second, never-refreshed copy of a live credential.

```bash
gh-doctor                 # this directory
gh-doctor --offline       # config only — every network answer marked NOT CHECKED
gh-doctor ~/some/repo
```

Configuration is data, in `zsh/zshrc.company` (or `~/.zshrc.local`), read by the doctor:

```zsh
GH_ACCOUNT_ROUTES=( "quantivly=$HOME/.config/gh-quantivly" )             # owner-glob=config-dir
GH_ACCOUNT_PATH_ROUTES=( "$HOME/quantivly=$HOME/.config/gh-quantivly" )  # absolute-prefix=config-dir; only a dir with NO GitHub remote
GH_ACCOUNT_DEFAULT_DIR="$HOME/.config/gh-personal"                       # empty = indeterminate
```

Traps this area has, each of which produced a green tick or a confident wrong answer:

- **A route whose config dir does not exist can never fire**, and reporting that only when
  the route happens to match means the fault first surfaces on the day it was finally
  needed. The whole table is checked every run, matched or not. This is not hypothetical:
  writing the entry in **single** quotes (`'quantivly=$HOME/...'`) leaves a literal
  `$HOME` that never exists, and the route silently never matches.
- **`${~pat}` enables tilde expansion as well as globbing**, so a route pattern beginning
  with `~` aborted the lookup with "no such user or named directory" and took every later
  route with it. Owner patterns are restricted to `[A-Za-z0-9_.-]` plus `*` and `?`, and
  anything else is named as a bad table entry rather than left to misfire at match time.
- **An unparseable routing table selects nothing, and nothing reads as "this repo is
  personal"** — the unparseable-link-map failure from the live-config guard, in a new
  place. `bad-table` is its own state and is reported as UNUSABLE.
- **zsh's `local NAME` on a name already local in that scope is a DISPLAY command**, so a
  `local` inside a loop printed `du=zvi-quantivly` into the middle of the report.
- **An unfixable condition is a ⚠, not a ✗.** The keyring collapse is a property of `gh`;
  nothing here can repair it. Reporting it as a failure made `gh-doctor` exit 1 on *every*
  run — the permanently-red checker this file warns about two sections up, in the command
  written to avoid it, found only once it was deployed and run for real. The isolation
  section is the *rationale* for pinning (here is the collapse; here is proof the per-user
  token defeats it); ✗ is reserved for what someone can act on — the route disagreeing with
  the effective account, a missing route dir, an unreachable API, and a per-user token that
  resolves to the wrong login, which means that account needs `gh auth login`.
- **An empty answer is never agreement.** A failed or timed-out API call is a ✗ with the
  error, and every comparison that depended on it is reported as *skipped*, never passed.
  `--offline` marks its answers NOT CHECKED for the same reason.
- **The environment, not argv — and the severity of that was overstated once already.**
  `/proc/<pid>/cmdline` is world-readable (444) while `/proc/<pid>/environ` is owner-only
  (400), so `env GH_TOKEN=gho_… gh api user` looks like a leak. **It mostly is not**:
  measured, `env` *consumes* its assignments and then execs, so the token never reaches the
  exec'd program's cmdline — only the short-lived `env` process's own, between fork and
  exec. A microsecond race, not the length of the call, and **not** the same shape as the
  28-day tmux server this machine actually found. `_gh_run` uses a subshell anyway: it
  closes even the race, and — the real payoff — retires the whole `env`-argv class, which
  had already produced two bugs here (a shell function after `env`; `-u` after an
  assignment), both surfacing as *"could not resolve the account"*.
  The correction matters as much as the fix: a checker whose findings are inflated is a
  checker whose findings stop being believed.
- **`exec` resolves shell functions; `env` could not.** So the subshell form introduced a
  hazard the old one lacked — a user's `gh` wrapper in `~/.zshrc.local` being run instead
  of the binary, and its output taken as the effective login. `exec command gh`. Reachable
  only on the no-`timeout` fallback, which is why the test needs a PATH fixture that has
  `gh` but not `timeout`; without that it silently exercises the safe path.
- **git's exit status is load-bearing.** 0 = matched, 1 = no match, **128 = git could not
  read the repository at all** — which a malformed `~/.gitconfig` produces, and
  `~/.gitconfig` is itself a managed symlink in this repo, so a bad branch causes it.
  Discarding the status left the state at its initialised `no-repo`, which falls through to
  the personal default: a quantivly clone silently authenticating as the personal account,
  on the one path that deliberately does not warn. `git-error` is its own state, it stops
  rather than falling through, and it is loud.
- **The first prompt re-runs the routing; it does not replay what startup recorded.** The
  startup call routinely loses a race it is *meant* to lose — the token cache is
  repopulated by a background job that lands a second later — so the shell starts unpinned.
  Replaying that message printed something no longer true *and* left `GH_TOKEN` unset for
  the life of the shell, putting every `gh` call back on the keyring default inside a
  personal repo. The defect this mechanism exists to close, reintroduced in the one shell
  per boot nobody would re-check.
- **`GITHUB_TOKEN` is cleared everywhere `GH_TOKEN` is.** gh ranks it second, so leaving it
  set on an unpinned path means a third account nobody named wins — while the warning
  blames the keyring.
- **`gh-doctor <dir>` is not `gh-doctor`.** The effective-account probe reads *this
  shell's* environment, which the hook pinned for `$PWD`; comparing it against a different
  directory's route produced a confident ✗ for a state that cannot occur, since cd-ing
  there repins first. The comparison now runs only for `$PWD`.
- **The legacy-nickname purge subtracts the configured basenames.** `quantivly` and
  `personal` are also legal config-dir basenames, so purging *after* the writes deleted a
  token just cached, and purging *before* them discarded a still-valid one whenever that
  iteration's `gh auth token` failed transiently. Naming the exception removes the ordering
  question rather than answering it.
- **Helpers used outside the opt-in gate must be defined outside it.** `gh-refresh-tokens`
  sits outside `[[ -d ~/.config/gh-quantivly ]]` while its cache helpers sat inside, so on
  a personal-only box — the exact machine the gate exists for — it hit `command not found`,
  took an *empty* cache path, wrote a live token to `/<basename>` at the filesystem root,
  and printed `✓ … cached token` with exit 0.
- **A chpwd helper may not be a `$(...)` call.** Replacing a parameter with a function to
  deduplicate a path put a fork back in the hot path this file had just been cut down to
  one git fork. One assignment deduplicates just as well.
- **The first-prompt hook retires only once it has pinned something.** Unhooking after a
  single attempt meant a shell that lost the cache race twice — the refresher does two `gh`
  forks, and p10k's instant prompt can beat them — stayed on the keyring default for life.
  Later prompts are free: it short-circuits on `[[ -n $GH_TOKEN ]]` before any fork.
- **`GITHUB_TOKEN` is cleared on the SUCCESS path too, not just the failures.** gh outranks
  it, but the GitHub MCP server, `act`, `hub` and most Actions-shaped tooling do not — so
  an inherited one kept authenticating as a third account inside a correctly-routed
  directory, with `gh-doctor` reporting `credential: $GH_TOKEN` and showing nothing wrong.
- **Keep git's own error.** Collapsing every non-0/1 status into one sentence blaming
  `~/.gitconfig` was wrong for most of them: git missing is 127, `$PWD` may be deleted, and
  "detected dubious ownership" is ordinary on external media and wants `safe.directory`.
  stderr is folded into the capture (a temp file would need `rm`, and a broken PATH is one
  of the states being diagnosed), and the parser shape-checks `remote.<name>.url` so a
  warning cannot become a phantom remote.
- **`local` outside a function is an error in zsh**, and the shell-start refresher was an
  inline `{ … } &!` block — so the error went to a backgrounded subshell's stderr where
  nobody sees it, the cache stayed empty, and every directory reported "account NOT
  pinned". It is a function now. (Writing a credential out of dynamically-scoped globals
  would have been the other way to get that wrong.)
- **A `chpwd` hook cannot afford a `gh` fork.** The doctor may spend ~50 ms per config dir
  asking gh what it declares; the hook may not, so it reads the cache file directly and
  `_gh_repo_remotes` was reduced to a single `git` fork on the common path — `git config
  --get-regexp` exits non-zero for "not a repo" and "no such key" alike, so the `rev-parse`
  that tells them apart runs only when there was nothing to parse.
- **A workspace root is not a repository, and "not a repository" fell to the personal
  default.** `~/quantivly/qspace` holds two work repositories and has no remote of its own,
  so the remote rule had nothing to say and the default answered — inside the work tree. A
  Claude Code session started there inherited the personal `GH_TOKEN` and
  `GITHUB_PERSONAL_ACCESS_TOKEN`; its Bash-tool shells (`zsh -c`, no `.zshrc`) kept them,
  and the GitHub MCP plugin's bearer header was fixed to them at startup, so every private
  work repository 404'd for the life of the session (2026-09-09). `GH_ACCOUNT_PATH_ROUTES`
  answers exactly that case and only that case — a directory with a GitHub remote is still
  the remote's to decide, so a personal repository under the work tree stays personal, as
  git signs it.
- **`printf > file` truncates before it writes.** The refresher runs on every interactive
  shell start and rewrote both cache files in place, so a shell starting while another
  shell's refresher was mid-write read an *empty* token and started unpinned — and a Claude
  Code session launched from it carried no GitHub credential at all. herdr and Herdmates
  start several panes at once, which is that state. `_gh_cache_write` writes a temp and
  renames it into place: a reader sees the old token or the new one, never nothing. The
  chmod before the rename guarantees the live file's mode; the `umask 077` only closes the
  moment before it, inside a 700 directory, and is deliberately not what the rows measure.
  Independent review then found two more traps in the writer, both now pinned: the temp
  was named by `$$.$RANDOM`, and **both are inherited unchanged across a zsh fork**, so the
  disowned shell-start refresher and a foreground `gh-refresh-tokens` shared one name and
  the loser printed a false ✗ (`sysparams[pid]` is the real PID); and `mv -f` onto a
  *directory* moves into it and succeeds, so a directory at the cache path got a live token
  inside it and a ✓ (refused now, as `main`'s writer refused it). The state table tells a
  replace from a truncate by the live file's inode — which only holds with one fixture HOME
  per row, because a leftover refresher from an earlier row can free the recorded inode and
  hand it straight back to the new temp.
- **A deduplicated table hides a route.** `_gh_configured_dirs` deduplicates by config dir,
  and on the shipped configuration the path route names the *same* dir as the owner route —
  so the path table vanished from `gh-doctor` entirely, and a mistyped prefix was a silently
  inert route under a fully green report: the exact fault the table check exists to name,
  two lines above the code that hid it. A shared dir now carries every reason
  (`route 'quantivly' + path route '~/quantivly'`), and a prefix that does not exist on disk
  is a ⚠ that "can never fire" — a ⚠, not a ✗, because a machine with the work config dir
  and no work tree has nothing to route there and must not carry a permanently red doctor.
  Found by an independent review pass, not by the author.
- **"No GitHub remote" had a fourth case.** A GitHub URL the parser rejects left the owner
  slot empty exactly like a non-GitHub remote did, so it took the path route: a repository
  under the work tree whose only remote is `git@github.com:someone` was pinned to work while
  git signs it personal, with a reason that said "no route matched". `_gh_repo_remotes` now
  records the parse state per remote; `unparsable` counts as a GitHub remote, blocks the path
  table, and the doctor lists it as a ⚠.

State table: `scripts/test-gh-routing.sh` (199 checks, run in CI, hermetic — `gh` is
stubbed, so it needs no network, no keyring and no GitHub account; the stub reproduces the
keyring collapse, which a real `gh` cannot be made to do on demand). Each trap above is a
row, and each is pinned by mutation: reverting the fix in a copy of the tree has to make
the row that names it fail.

## Keeping secrets out of transcripts

**Everything a command prints is recorded, and that is where the credentials went.** An
audit on 2026-09-01 found *both* of this machine's live GitHub tokens in plaintext in five
Claude Code session transcripts — two written days earlier, matched by SHA-256 against the
live values, so not a historical artifact. Transcripts are conversation context, so those
values had also left the host.

No single dramatic mistake produced this. Ordinary diagnostics do it: `ps` showing a
process launched with `-e GH_TOKEN=…`, a `printf` of `$GH_TOKEN`, a bare `gh auth token`.

**Rotation is the wrong loop to optimise.** For GitHub it is browser-only — `gh auth` has
no `revoke`, `/authorizations` and `/applications/grants` are 404 (the API was removed in
2020), and the endpoints that can revoke need the OAuth *app's* client secret, i.e. you
would have to be GitHub. `gh auth logout` looks like rotation and is not: it drops the
local copy while the leaked value stays valid. So rotation is manual, and it does nothing
about the next capture.

Two pieces attack the emission instead:

- **`scripts/redact-secrets.sh`** — a stdin→stdout filter. **Two rules, because either
  alone leaks.** Shape matching (`gho_…`, `sk-ant-…`, `AKIA…`) finds a credential anywhere,
  including bare in prose, but cannot know that `CLAUDE_CODE_MESSAGING_TOKEN=b7dc…` is a
  secret — 32 hex characters is also every short git SHA. Name matching (`…TOKEN=`,
  `…SECRET=`) catches those in the `VAR=value` shapes an env dump produces, without
  false-positiving on arbitrary hex. That gap was found by running the pair against a real
  `printenv` and seeing what survived.
- **`claude/hooks/secret-emission-guard.sh`** — a `PreToolUse` hook (matcher `Bash`) that
  **refuses** the handful of command shapes that print credentials unless piped through the
  redactor: `gh auth token`, `gh auth status --show-token`, `ps` with full command lines,
  `pgrep -a`, a bare `env`/`printenv`, and reads of `/proc/*/cmdline|environ`.

Design decisions that are load-bearing, not preferences:

- **Deny, not ask.** The remedy is mechanical (append `| redact-secrets`), so a prompt
  would only train the human to click through — and an `ask` on commands an agent runs
  constantly makes the guard the most irritating thing on the machine.
- **Fail open, always.** Bad JSON, no `jq`, an unreadable payload, *or the hook file not
  being deployed yet* — all allow. A hook that breaks the shell when it breaks gets
  disabled wholesale, taking its protection with it. The registration in
  `~/.claude/settings.json` carries its own `[ -r "$f" ]` guard for exactly this: the file
  arrives via dotbot, so it is absent whenever the checkout is mid-deploy or on a branch
  without it, and registering it without that guard put `exit 127` on **every** Bash call
  in every session on the box until it was fixed.
- **Most of the state table asserts what it must NOT block.** `ps -o comm=`,
  `env -u GH_TOKEN … gh api user`, `printenv GH_CONFIG_DIR`, and
  `git commit -m "stop ps aux leaking"` all have to pass — quoted strings are stripped
  before matching so a command that merely *mentions* a shape is not refused. A false
  positive costs the entire guard; a miss costs one redaction.
- **It is a papercut guard, not a boundary.** Any command can print a secret and this knows
  about seven shapes. The real fixes are shorter-lived credentials (a fine-grained PAT with
  an expiry, so a leak decays on its own) and narrower scopes — both `gh` tokens here carry
  `admin:public_key`, the scope that lets a leak plant an SSH key surviving revocation.
- **Every original rule caught a command printing a secret it FETCHED; none caught one
  printing a FILE — and this file's own Security Rules send every secret to
  `~/.zshrc.local`.** So the guard covered every emission shape except the documented home
  of all of them. On 2026-09-07 an agent ran `tail -8 ~/.zshrc.local` to find where to
  append a `pathadd` line; the tail of that file held a live `LINEAR_API_KEY` and a
  `NOTION_PAT`, both reached the transcript, and both had to be rotated — the same class as
  the incident that created the hook, six days later. The rule added for it fires on
  `~/.zshrc.local`, `~/.gitconfig.local`, `~/.backup.local` and `~/.claude/.credentials.json`
  and **needs two conditions, whose split is the whole design**: the PATH matches on the raw
  command (`$probe` has quoted strings stripped, so `cat "$HOME/.zshrc.local"` — the most
  natural spelling — would escape a `$probe` match), while the VERB matches on `$probe`.
  Path-alone on the raw command refuses `git commit -m "move flyctl to ~/.zshrc.local"`, a
  message merely *naming* the file, which is the false positive that costs the whole guard.
  Metadata-only commands (`ls`, `stat`, `test -f`, `wc`, `readlink`) print no content and are
  deliberately not verbs. A `python3` heredoc that opens the file is not caught either: it
  prints nothing by default, and refusing it would block ordinary edits to the very file
  people are told to keep their secrets in.
- **The remedy the guard names did not remedy.** Immediately after the rule above shipped,
  running its own suggested `tail ~/.zshrc.local | redact-secrets` against the real file
  printed the `NOTION_PAT` in full. `NOTION_PAT` matched no name pattern (the alternation is
  `TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|CREDENTIAL`) and `ntn_` matched no shape pattern, so
  it fell through both rules — the exact case the redactor's header says two rules exist to
  prevent. **Worse than a plain miss:** the deny message points at the redactor, so the
  failure mode is guard blocks, human adds the pipe, token prints anyway, and it looks
  handled. Fixed by `ntn_` and `lin_api_` shape rules plus a `_PAT=` name rule. That last one
  is its OWN `-e`, never an entry in the alternation: the alternation is followed by
  `[A-Z0-9_]*=`, so any PAT inside it has the trailing class absorb what follows and redacts
  `SOME_PATH=`, `MY_PATHS=` and `COMPATIBLE=` (measured, both for `PAT` and `_PAT`). `PATH=`
  and `PATTERN=` are safe for a different reason — the `=` adjacency — and only a rule
  allowing PAT anywhere before the `=` reaches them. Six mutations, all pinned; the reasoning
  above was wrong on first writing (it blamed `PATH=` for what actually breaks `SOME_PATH=`)
  and the state table is what corrected it.
- **The quote-stripping has a hole of its own, found the same day and NOT fixed.** A heredoc
  body is not a quoted string, so a command whose heredoc merely *quotes this guard's own
  source* trips the `/proc/*cmdline*` rule — which happened while editing the guard, and the
  workaround is the documented one (pipe through the redactor). Worth knowing before assuming
  a refusal means the command really would have leaked.

**`.gitignore`'s `**/*secret*` rule excluded all three of these files**, whose entire job
is secrets — and `git add -A` skips ignored paths **silently**, so `git commit`, `git push`
and `gh pr create` all reported success with the content absent. Only CI caught it, via
`No such file or directory` on the test script and dotbot's `Nonexistent target` on the
hook. Three negations after the rule fix it (`!scripts/redact-secrets.sh` etc.), and the
check that matters is `git add --dry-run`, not `git check-ignore -v` — the latter exits 0
when a path matches *any* rule, negations included, so it reports "matched" for a file that
is not ignored at all and reads as the opposite of the truth.

**Like the sidebar publisher, `./install` only does half.** dotbot puts the hook file in
`~/.claude/hooks/`; it does nothing until it is also registered as a `PreToolUse` hook in
`~/.claude/settings.json`, which is user-level and not in this repo.

State table: `scripts/test-secret-guard.sh` (79 checks, run in CI, hermetic — the fixture
credentials are assembled at runtime so this file contains no string that would trip the
`gitleaks` pre-commit hook over its own test data).

## Tmux Configuration

Prefix-free tmux setup with Terminator-style keybindings. Prefix: Ctrl+s.

**Essential bindings:** Ctrl+Shift+E/O (split), Ctrl+Shift+W (close), Ctrl+Shift+Arrow (navigate), Ctrl+Alt+Arrow (resize), Alt+z (zoom), Ctrl+Shift+T (new window)

**Popup windows:** Alt+o (file finder), Alt+s (live grep), Alt+w (session picker), Alt+g (lazygit), Alt+y (yazi popup), Ctrl+b (yazi side pane toggle), Ctrl+Shift+F (tmux-thumbs quick-copy)

**Nested tmux (remote servers):** F12 toggles outer tmux off, passing all keys to inner tmux. Outer status bar turns grey with `[INNER]` label. Inner tmux auto-detects nesting and uses gold bar at top. For manual SSH-into-remote-tmux usage (e.g., `ssh -t server 'tmux a'`).

**Key notes:**
- No auto-start — launch manually with `tmn <session>`
- Alacritty coupling — Ctrl+Shift+letter bindings require CSI u entries in `~/.config/alacritty/alacritty.toml` (template: `examples/alacritty.toml.template`, install with `alacritty-init`)
- `extended-keys` and `terminal-features` are server-level — require `tmux kill-server`, not just config reload
- Plugins: tmux-resurrect, tmux-continuum, tmux-thumbs, tmux-open, tmux-dispatch
- Claude Code runs in fullscreen rendering (alt-screen) to avoid scrollback corruption — its output isn't in tmux copy-mode; scroll/search inside Claude (`Ctrl+o`, then `[` to dump to scrollback). See [docs/CLAUDE_CODE_TMUX.md](docs/CLAUDE_CODE_TMUX.md)

See [docs/TMUX_LEARNING_GUIDE.md](docs/TMUX_LEARNING_GUIDE.md) and [examples/tmux-workflows.md](examples/tmux-workflows.md) for comprehensive guides.

## Herdr (agent workspace manager)

Terminal workspace manager for coding agents (workspaces → tabs → panes, with agent detection).
Config: `config/herdr/config.toml` → `~/.config/herdr/config.toml`. Full guide:
[docs/HERDR_GUIDE.md](docs/HERDR_GUIDE.md).

**Two install paths, and the modular one is the default recommendation for anyone else
(DO-555).** `./install --herdr` links the FIVE destinations that are actually herdr —
`config.toml`, `plugins.list`, `plugins.lock`, the statusline hook and the systemd unit —
and stops. The full `./install` links 18, among them `~/.zshrc`, `~/.gitconfig`,
`~/.tmux.conf`, `~/.p10k.zsh` and VS Code's `settings.json`; requiring all of that to run
herdr is how an invitation becomes an ultimatum. The modular path deliberately does NOT
link `~/.config/mise/config.toml` (it would pin ~25 tools and override whatever
node/python the machine already runs) — `scripts/herdr-deps-check.sh` reports what is
present, names the one feature each missing tool costs, and offers the exact `mise use -g`
line with versions read out of `.mise.toml` so it cannot drift from the pins. It handles
mise-absent too, by naming the versions and leaving the method alone.

**The linked lockfile assumes push access, and an outside adopter does not have it (DO-566).**
`plugins.list` and `plugins.lock` are symlinks into the checkout in BOTH configs, deliberately,
so `herdr-lazy` writes a plugin change through as a reviewable diff. For anyone who cannot push
here that is permanent local modification of somebody else's repo plus a `git pull` that
conflicts on a file a tool wrote for them — no error, just an update path that stops working.
The answer is a fork with this repo as `upstream`, documented in HERDR_GUIDE §3 "Updating a
modular install you cannot push to" and printed by `./install --herdr`, where the reader is
standing when it matters. Copying the two files for the modular path instead was considered and
rejected: a copy is written once and never reconciled, which is the `~/.config/mise/config.toml`
failure above (one warning, keep the stale local copy, forever), and it costs the reviewable
diff that is most of why the lockfile is in git.

The shell layer is `zsh/zshrc.herdr`, sourced by `zshrc` and **safe to source alone** — a
modular adopter adds one line to their own rc. It needs zsh, and `hdespawn` prefers `confirm`
(`zsh/functions/system.sh`). `hspawn`/`hdespawn`/`hreap` in it are **agent-facing**: a lead
agent drives them to fan work into worktrees and reap it. A human uses the herdr UI and
`clauth`. It also carries `herdr-help`, the in-shell cheat sheet — moved here from
`zsh/zshrc.help` by DO-563, because that module is sourced by the FULL install only, so the one
command that lists `hspawn`/`hreap`/`clauth` was missing on exactly the machines whose owner had
not read the guide.

Two things the modular installer cannot do, both silent: Claude Code's `statusLine` +
agent skill file, and `herdr plugin link` for the local plugin. It prints both, and the first is
now one idempotent command — `scripts/herdr-claude-wire.sh` — rather than a JSON block with the
reader's own home directory to substitute in. `scripts/verify-tools.sh --herdr` is the single
check afterwards: the three herdr sections plus that wiring, and **none** of the eleven
full-install sections, whose mise check would otherwise print a ✗ and offer a paste that pins
~25 tools globally on a machine that deliberately linked no mise config. A checker that needs a
prose disclaimer telling you to ignore it is the permanently-red checker this file warns about
twice, and it had reached the one path written to avoid it.

**The checkout may live anywhere, and getting there needed a drop-in rather than a rendered
unit (DO-564).** The unit's own `ExecStart` is the absolute
`%h/.dotfiles/scripts/herdr-server-launch.sh`, so `--herdr` used to REFUSE any other
directory — the cost landing on the adopter we most want to say yes, someone who already has
their own `~/.dotfiles`, and the team page escalated it to "come and talk to us before you
move anything". `./install` now renders
`~/.config/systemd/user/herdr-server.service.d/10-execstart.conf`
(`scripts/herdr-unit-dropin.sh`, template under `systemd/herdr-server.service.d/`) pinning
ExecStart to the installing checkout. Six things about it are load-bearing:

- **A rendered COPY of the unit was the obvious move and is wrong.** Two checkers derive
  "which checkout is live" from the unit being a **symlink** —
  `reconcile-systemd-units.sh`'s `managed_units()` requires `-L`, and `verify-tools.sh`'s
  enablement assertion walks `~/.config/systemd/user/*` taking `readlink -f`. A copy makes
  both find nothing and **skip silently**, in the section whose own comment says a missing
  checker is not a pass. A copy would also be a copy of *reviewed content* (`OOMPolicy`,
  `KillMode`, `Restart`, `[Install]`) that stops tracking the repo the moment HEAD moves —
  the `~/.config/mise/config.toml` failure DO-566 refused to repeat.
- **What is rendered is machine IDENTITY, not content, which is why DO-566's objection does
  not transfer.** The drop-in holds one fact — where the checkout is — and HEAD cannot stale
  it. That is the `__BACKUP_*__` case (DO-459), not the mise case: the mise file is written
  by a *tool* and diverges from a reviewed source, a rendered path diverges from nothing.
- **The empty assignment before each value is required, not stylistic.** `ExecStart` is a
  list, so a drop-in that merely adds one gets you two, and systemd then refuses the unit:
  *"Service has more than one ExecStart= setting, which is only allowed for Type=oneshot
  services."* Verified both ways with `systemd-analyze verify --user` under
  `SYSTEMD_UNIT_PATH`, which needs **no manager and no running server** — the only way to
  test this at all, since a running server keeps its original `ExecStart` until a restart
  that would end every agent session.
- **The check asks the outcome, never the mechanism.** "A drop-in exists" is permanently red
  on a healthy machine at `~/.dotfiles`, where the unit's own value is already correct.
  `herdr-unit-dropin.sh --check` asks instead whether the **effective** `ExecStart` — base
  unit merged with its drop-ins, reset semantics applied — names an executable launcher
  inside the checkout the unit symlink resolves to. One rule, no severity branch, and it
  catches both real states: a foreign checkout nobody rendered for, and a drop-in left
  behind by a checkout that has since moved. Both sides are canonicalised before comparing,
  because `want` comes from a physical `readlink -f` and `bin` from `%h` expanded to `$HOME`
  — on the supported `~/.dotfiles -> ~/src/dotfiles` layout a naive compare reports drift on
  a correct machine forever.
- **The rendered value is QUOTED, and a local review pass is what caught why.** systemd splits
  an unquoted setting on whitespace, so a checkout at `~/my dotfiles` rendered
  `ExecStart=/home/me/my dotfiles/scripts/…` and systemd went hunting for a binary called
  `/home/me/my` — **203/EXEC, the exact failure this change removes, reintroduced for anyone
  with a space in their path.** Quoting unconditionally rather than only-when-needed is
  deliberate: a conditional puts the space case on a branch that never runs on our machines,
  and this repo has already shipped a row that could not reach the branch it named. The
  parser side had to learn quoting too, or `--check` could not read its own output back.
- **Only `%h` is expanded, and anything else is NOT CHECKED rather than guessed.** An earlier
  version also mapped `%%` → `%` and did it in the wrong order, so `%%h` — a literal `%h` —
  became `%$HOME`: dead code that was also wrong. A value carrying an unexpanded specifier is
  declined, because comparing it would report "wrong launcher" about a unit somebody
  legitimately extended, i.e. a permanently-red assertion. "No `ExecStart` at all" stays a
  hard FAIL, so the two empties are kept apart — an empty answer is never agreement.

**A mutation that no longer APPLIES reads exactly like a surviving mutant, and that cost two
full sweeps here.** `str.replace` on a pattern that stopped matching is a silent no-op, so
after the drop-in template was reworded the row-pinning mutant "survived" twice while
changing nothing. The mutation harness must diff the mutated tree against the original and
treat "nothing changed" as a harness error, never as a result — the same rule this file
already states for rows ("a row that cannot reach the branch it names is unfailable"), one
level up. Dry-run every mutation for applicability before paying for the suite runs.

**The governing fact: every layer of this stack fails silently.** A 2026-08-30 walkthrough found
five separately configured features completely dead — a keybinding, a prefix fallback, two
popups, and `hspawn` — while `herdr config check` returned `ok` and `herdr server reload-config`
returned `applied` with zero diagnostics throughout. **`config check: ok` means the file parses and
its keys, chords and `[ui]` schema are internally consistent; it says nothing about effects.** It
does catch bogus keys, bad inline fields, non-hex colours and chord collisions among *listed*
actions (probed 2026-08-30) — but not a collision with an unlisted stock default, a chord the
terminal swallows, a missing popup binary, or a token that is never published. Verify effects, one
binding at a time, and never generalise from one working example to a class.

Gotchas, in the order they bite:

- **Never run bare `herdr`** from a script or an agent — it attaches a client and hijacks the
  user's UI. Subcommands only. (At a keyboard it is just how you re-attach after `ctrl+alt+q`.)
- **Closing one terminal in the spaces sidebar can close the whole space, silently.** A close
  aimed at a single pane issues a **`tab.close`**, which kills every pane in that tab — and when
  the space holds only that one tab, the space goes with it. On 2026-09-07 at 09:57 an empty root
  terminal was closed in a space containing two nested Claude sessions; the server log shows one
  `method="tab.close"` followed by three `pane.exit` records (`code: 1`, and a `Hangup` for the
  third), and the space disappeared from the sidebar. Five sessions went that way across four such
  closes that morning. **There is no undo**: `herdr session` manages server *sessions*, not closed
  workspaces, and `~/.config/herdr/session-history.json` mirrors the LIVE set rather than retaining
  closed ones — verified, its entry count tracks `herdr workspace list` exactly. The layout is
  unrecoverable; the conversations are not, because Claude Code transcripts outlive the pane
  (`claude --resume <session-id>` from the original cwd). Two things make the post-mortem possible
  and are worth knowing before you need them: a killed pane's transcript stops at the instant of
  `pane.exit`, so matching transcript last-write times against exit timestamps identifies which
  session died where **to the second**; and the log records a workspace's *creation* and *closure*
  but **never its label**, so afterwards you can prove what was in a space and not what it was
  called.
- **`request_id="cli:…"` in the herdr log does NOT mean a program did it.** All 6,183 requests in
  this machine's server log carry that prefix — the TUI is a client speaking the same API — so the
  field cannot tell a human's click from an agent's CLI call. It was read as proof that "an agent
  closed these, not the user", and that was wrong. Nothing in the log attributes an action to a
  human.
- **Never start or restart the herdr server from inside a pane or a Claude session.** The server's
  environment is a snapshot of whoever launched it, and every pane inherits it. The live server was
  once relaunched from a team-lead pane (2026-08-29), so every pane got the teammux shim as `tmux`,
  a fake `TMUX`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and herdmates' plugin dirs — a dozen-plus
  team-of-one sessions, `tmn`/`tmux kill-server` dead, `$status` on every row, and the runbooks'
  `command -v tmux` pre-flight passing for everyone. Use the unit:
  `systemctl --user restart herdr-server.service` (`systemd/herdr-server.service`, launcher
  `scripts/herdr-server-launch.sh`; `--print-env` shows the environment it builds, and it refuses to
  start when `HERDR_ENV`, `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` is set). `scripts/verify-tools.sh`
  asserts the running server's env is clean. The unit is wanted by `graphical-session.target`, **not
  `default.target`**: `Linger=yes` on this account brings the user manager up at *boot*, so a
  `default.target` unit would start before GNOME imports `DISPLAY`/`WAYLAND_DISPLAY`/`XAUTHORITY`
  and get none of them. It still survives logout — `WantedBy` propagates start only, and the unit
  has no `PartOf` — so every agent session stays alive. Nothing is manual per boot. See
  HERDR_GUIDE §2.4.
- **An error anywhere in `[ui]` silently reverts ALL of `[ui]`** and reports `partial` with no
  error text. After any config edit, `herdr server reload-config | jq '.result.status'` must say
  `applied`. If an edit "did nothing", this is the first thing to check.
- **Setting a key field REPLACES it wholesale.** An action relying on a stock prefix default must
  re-list that default explicitly or it is silently lost (this is how `f12 v` / `f12 -`
  disappeared — an audit found 15 of 25 rebound actions had lost theirs). A bare value is only
  safe for actions whose stock default is empty (`focus_agent`, `next_agent`, `previous_agent`,
  `move_tab_*`, `resize_pane_*`). Diff against `herdr --default-config` after any keymap edit.
- **A LINKED systemd unit is not a RECONCILED one, and the difference is invisible.** systemd
  records `[Install]` at `enable` time, as a symlink under `<target>.target.wants/`. Editing
  `WantedBy=` afterwards changes nothing about what starts — **not even after `daemon-reload`**,
  which re-reads the unit but never revisits the symlink. **And the obvious fix is a trap:
  `systemctl reenable` (= `disable` + `enable`) DESTROYS a dotbot-installed unit.** `disable`
  removes every symlink in the unit search path pointing at the unit, and the entry in
  `~/.config/systemd/user` is exactly such a symlink, into the checkout — so the enable half then
  fails with "Unit does not exist" and the unit is left neither linked nor enabled. That happened
  here on 2026-09-01. What is safe is `enable` (it only ADDS `.wants` links) plus pruning the
  stale link by hand, in that order. A probe using a real FILE rather than a symlink showed
  `reenable` working perfectly, which is how the advice got written — **a fixture that differs
  from production in the one property that decides the outcome proves nothing.** Meanwhile
  `systemctl status` is happy, so the unit file under review says one thing and what boots is
  another. This repo *manufactures* that drift, because `git checkout` here is a deploy and
  `./install` is not in that path: HEAD moves, the linked unit file changes under systemd, nothing
  re-enables anything. It cost one reboot's worth of every pane losing `gh --web`, `xdg-open` and
  the ssh agent, with every check on the machine green. Now: `./install` reconciles
  (`scripts/reconcile-systemd-units.sh`, gated — no-op without a user manager, and it re-enables
  only a unit that is *already* enabled, so it reconciles a decision rather than making one), and
  `scripts/verify-tools.sh` **fails** when the enablement has drifted. `--check` reports,
  `--plan` lists what `--apply` would touch. State table: `scripts/test-systemd-reconcile.sh`
  (130 checks, in CI as `systemd-reconcile-test`) — hermetic via a recording **`systemctl` stub**
  at the front of `PATH`, never via systemctl's absence: this box has a real one wired to the live
  user manager that holds the herdr server. Reading "the comparison is filesystem state, so no
  manager is needed" as "set `RECONCILE_NO_SYSTEMCTL=1` on every row" left `do_reconcile`'s body
  executing **zero times** across a 44/44 pass — the read-only decision layer pinned completely,
  the layer that DELETES SYMLINKS not at all. Making `do_reconcile` also `rm -f` the unit symlink,
  i.e. reproducing the incident the file exists to prevent, passed 44/44.
- **The reconciler read the unit FILE and called systemd's own extension mechanism drift.**
  `declared_targets` parsed `WantedBy=` out of one file's `[Install]` and never looked at
  `<unit>.d/*.conf`. A drop-in is exactly how you add an `[Install]` target without editing a
  reviewed unit, and this repo already ships one for `ExecStart` (DO-564) — so the checker
  reported the correct fix as a fault. It bites on a headless box: `herdr-server.service` is
  `WantedBy=graphical-session.target`, which never activates without a graphical session, so an
  EC2 dev box needs a `default.target` drop-in to start the server at boot. Measured on that box,
  the drop-in gave `✗ enabled under default.target graphical-session.target, but its unit file
  declares graphical-session.target` and a permanently red `verify-tools.sh` — the failure this
  file names five times, produced by the checker rather than by the machine. **No drop-in
  spelling avoids it**: clearing and re-setting `WantedBy=` still leaves the unit file declaring
  something else, so the choice was a red checker or no boot autostart. It is now the merged
  value — unit file, then `<unit>.d/*.conf` in filename order, an empty assignment clearing the
  list, which is systemd's own rule for a list-valued `[Install]` key. Scope deliberately matches
  `herdr-unit-dropin.sh`: only the drop-in directory NEXT TO THE UNIT, because a hand-placed one
  in `/etc/systemd/user` cannot be told from an administrator's decision. **DO-564 wrote the
  lesson and the sibling checker did not inherit it** — ask the OUTCOME, never the mechanism.
  Three messages saying "its unit file declares" became "it declares", since the targets no
  longer come from one file. Rows: `scripts/test-systemd-reconcile.sh` (130 → 142). 5 mutants,
  5 deaths — and the fifth only after a row was added: **deleting the reset rule from the
  UNIT-FILE half survived the whole suite**, because every reset fixture put the empty
  assignment in a drop-in. The merge has two halves and only one of them was pinned.

- **Four more ways the reconciler answered "nothing to look at" over real drift**, all fixed and
  each pinned by a row that fails without the fix: `[[ -e ]]` follows symlinks, so a **dangling**
  unit symlink (rename a source, don't re-run `./install`) was skipped and reported
  character-for-character like an empty machine; a unit whose `[Install]` was **deleted** kept its
  `.wants` link forever and read as `static`, "nothing to reconcile"; `pwd` is **logical** while
  the containment test used `readlink -f`, so a checkout reached through a symlink
  (`~/.dotfiles -> ~/src/dotfiles`) yielded zero managed units and a green tick; and the unit glob
  was hardcoded to `*.service`/`*.timer` in the function whose own header argues against
  hardcoding, so a drifted `.socket`/`.path`/`.target` was invisible.
- **"Clean" is not "complete" for the server environment.** `verify-tools.sh` used to ask only
  whether anything FORBIDDEN was present, so a server started at boot — before any graphical
  session existed to import an environment from — carried no forbidden variable and passed as
  clean while every pane had lost `gh --web`, `xdg-open` and the ssh agent. It now also asserts
  that the session variables the *user manager* offers are actually present in the server, and
  warns when `DISPLAY`/`WAYLAND_DISPLAY` name a **previous** login (a server deliberately
  survives logout, so it keeps the dead session's values). `SSH_AUTH_SOCK` is excluded from that
  value comparison on purpose — the launcher substitutes a stable symlink for it by design.
- **The herdr server's PATH is a snapshot taken when the server starts.** It carries the mise
  `installs/<tool>/<version>` dirs for whatever was *globally* configured at that instant (not
  mise's `shims` dir). Two consequences: a tool declared only in a project `.mise.toml` is
  invisible to the server, and a tool added globally *after* launch stays invisible until the
  server restarts — in both cases the popup or plugin opens and closes instantly with no error.
  Symlinking into `~/.local/bin` (also on the server PATH) makes a tool available *without* a
  restart, which is why `bun`, `lazygit` and `yazi` are linked there. An earlier version of this
  note said the server PATH "has no mise shims", which is literally true but misleading — it
  implied mise tools never resolve there, and they do.
- **A plugin pane that flickers and vanishes means the command exited.** The error is real but
  renders too briefly to read; reproduce it in a shell.
- **Plugins cannot declare their own keybindings** — wire them in `config.toml` and verify IDs
  with `herdr plugin action list`. An action appearing there does not mean its plugin is enabled.
- **Claude's trust-folder dialog defaults to "No, exit"** and a fresh worktree triggers it every
  time. Answer it on the **agent** surface (`herdr agent send-keys <pane> down`, then `enter`)
  *after* detection — pane-level keys sent as the dialog renders are silently dropped, because
  the TUI is not accepting input yet. `herdr agent prompt` refuses to type into a blocked agent.
- **`herdr agent wait` requires an already-detected agent.** It resolves its target up front and
  fails `agent_not_found`; it cannot wait *for* detection. Poll separately.
- **herdmates leaks plugin env into lead sessions** (upstream). Prefix plugin CLIs with
  `env -u HERDR_PLUGIN_STATE_DIR -u HERDR_PLUGIN_CONFIG_DIR`.
  **Stripping is only half the rule, and the other half bites (2026-09-14).** A plugin CLI that
  reads its OWN config needs those variables SET, not absent — `herdr-draft create` refused with
  `--account auto needs an account picker: set [clauth] picker in config.toml` on a machine where
  that picker is configured and on PATH, because it had inherited herdmates' `HERDR_PLUGIN_CONFIG_DIR`
  and `HERDR_PLUGIN_STATE_DIR` with no `HERDR_PLUGIN_ID` to say whose they were, so it declined them
  and resolved from built-in defaults. It said so rather than guessing, which is the only reason this
  was five minutes and not an afternoon. Export all three for the plugin you are actually invoking:
  `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_CONFIG_DIR="$(herdr plugin config-dir <id>)"`, and
  `HERDR_PLUGIN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/<id>"` (herdr has a
  CLI for the config dir and none for the state dir). **`HERDR_PLUGIN_ID` is the load-bearing one**:
  it is what says whose the other two are, and a plugin that checks it is protected from this leak
  while one that does not silently uses another plugin's configuration.
- **`clauth start <profile>` bypasses the `claude()` shell function**, so it lacks what that function
  adds: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and a launch via `herdmates teammux-launch`, which
  passes `--settings '{"teammateMode":"tmux"}'` so teammates become herdr panes. Whether teams are
  enabled at all depends on the flag *reaching the process* — a contaminated server hands it to
  everyone, and such a session leads a team whose teammates run in-process, invisible to herdr
  (INFERRED from Claude Code's default `teammateMode`; not observed). Team leads need
  `clauth <profile>` then `claude`; prove it with `herdr pane process-info --pane <id>` showing
  `teammateMode`, not with `command -v tmux`.
- **`herdr plugin link` state is herdr-local** and is not restored by herdr-lazy after a rebuild.
- **If you spawn agents or panes, CLOSE THEM when their work is collected.** This is not tidiness
  — memory is the binding constraint on this box (8 threads, swap runs hot, and `system_health`
  exists because memory-pressure kills here are *silent*). A session that spawned six panes and
  left them idling after they had delivered drove the machine to **load 27 and 96% swap with 33
  claude processes**, endangering ten unrelated in-flight sessions; tearing those six down
  recovered it to load 11.5 / 84% / 23. An idle agent still holds its memory. Close panes you
  created once you have their output; keep one only if you have a concrete next task for it.
  (Closing panes you did *not* create is a different matter — don't, unless asked.) Enumerate with
  `hreap` — every Claude process **in a herdr pane**, detected or not, with idle age, memory and
  creator (default view is idle ≥ 30 min; `--older 0` shows all); `hreap --close --mine` closes
  only your registry-tagged idle spawns — **not** `herdr agent list`, which misses herdmates
  teammates and trust-dialog panes (it showed 14 while 33 claude processes ran — though note ~8 of
  those were Claude under Atrium's tmux, outside herdr panes and so outside `hreap` too; the tab
  bar's `agents <detected>/<procs>` gap is the full census). `hspawn` records each spawn in `~/.local/state/hspawn/`; `hdespawn <slug>` tears one down
  (pane, workspace, worktree, registry entry).
- **A pane id is not a permanent name, and the registry that keys on it is.** herdr allocates
  workspace ids from a short alphabet whose counter lives only in the running server
  (`~/.config/herdr/session.json` persists the workspaces but no next-id counter), so a restart
  reissues them from the start — the server log here shows `w4`, `w5`, `wN` and `wP` each created
  twice in five days — and every new workspace's first pane is `p1`. Meanwhile
  `~/.local/state/hspawn/` is a file tree that outlives every restart, and its entries are
  deliberately long-lived: each hspawn bail-out keeps its entry, and `hreap --close` annotates
  rather than deletes so `hdespawn` can finish later. So `wN:p1` names two different spawns, and
  hspawn's `>` used to destroy the older entry silently, orphaning its worktree and branch with
  nothing on disk pointing at them. It now renames it to `<pane>.stale-<ts>.json` and says so. Two
  habits follow: **`hdespawn <pane-id>` is the exact form** (a direct file lookup — `hdespawn
  <slug>` scans and REFUSES when two entries share a slug, which `--close` makes likely by
  design), and an entry whose workspace id now holds someone else's worktree is finished from the
  recorded path with herdr's live workspace left untouched, rather than refused forever. State
  table: `scripts/test-hspawn.sh` (235 checks, in CI as `hspawn-test`) — hermetic via a recording
  `herdr` **stub** at the front of `PATH`, never via herdr's absence: the box this was written on
  has a real one wired to a live server, and a suite that assumed absence would pass in CI and
  remove a real workspace here.
- **Teammates in a herdmates team are NOT detected as herdr agents.** They exist as panes but are
  absent from `herdr agent list`, the sidebar rows, the priority sort and toasts — only the lead
  is detected. A lead also reports `done` while its teammates are still working, so read the
  lead's own roster for progress, not its agent state. Same blind spot applies to any pane sitting
  on Claude's trust dialog. The cause is the process name: Claude Code execs teammates via its
  versioned binary, so `herdr pane process-info --pane <id>` shows a foreground process named
  `2.1.251` rather than `claude`, and herdr never consults the Claude manifest — although
  `herdr agent explain --file <screen> --agent claude` accepts the same pane's screen (`state: idle`,
  rule `live_prompt_box`). `herdr agent explain <pane>` is the first diagnostic; `agent_not_found`
  means nothing was detected at all. An upstream report is drafted, not yet filed.
  **The reaping consequence, learned the hard way on 2026-09-07:** in `hreap`, a row reading
  `DET no` / `unknown` and idle for many hours is a **teammate**, not an abandoned session. Six
  such rows — 17–20 h idle, named `general-purpose`, ~380 MB each — were about to be closed as
  "stale, pure upside" when `process-info` showed every one of them running `2.1.259`, the
  versioned-binary signature above. They belonged to leads that were still working. CLAUDE.md's
  own words apply to the status field too: `unknown` "does not prove completion". A clean `git
  status` in the pane's cwd is not evidence either — a teammate's work in progress lives in its
  conversation and in findings it has not yet reported to its lead. The reap path for a teammate
  is **`TaskStop` from its lead**, never closing its pane; left alone, those six were reaped
  correctly by their leads within the hour.
- **The build/test parallelism caps key on `$HERDR_PANE_ID`** (`zsh/zshrc.buildlimits`), and
  that gate was `$ATRIUM_SESSION` until 2026-09-01. An *unset* variable selects the LOOSE
  tier, so the day Atrium stopped running, every agent pane silently got the half-the-cores
  budget meant for a solo human — the exact over-subscription the file exists to prevent,
  arriving as a config file that still looked correct. Any migration that moves the marker
  variable has this shape: check what an unset gate falls back to before assuming the old
  name is merely dead. `build-limits` prints which tier is active.
- **The agent tier was a hardcoded 2 and so did not survive leaving the laptop (2026-09-16).**
  `zshrc.buildlimits` capped any pane with `$HERDR_PANE_ID` at 2 workers regardless of
  hardware — right for the 8-thread box it was tuned on, where a dozen agents compete, and
  wrong the moment work moves to a bigger machine. Measured on the 16-core EC2 dev box the
  day it was set up to absorb work: an agent pane got `-j2` while fourteen cores idled, so
  the constraint had travelled with the work instead of being left behind. The tier is
  `cores/4` now, which yields **exactly 2 on 8 threads** — the machine it was written for
  does not move at all — 4 on 16, 16 on 64, with one floor of 2 shared by both tiers.
  `BUILD_LIMITS_JOBS` overrides either tier for a box whose shape you actually know; set it
  in `~/.zshrc.local`, which is sourced after this module. An unusable value (0, negative,
  decimal, non-numeric) leaves the computed tier alone rather than being taken literally —
  `0` disables parallelism outright and the rest land in `MAKEFLAGS` as a malformed flag,
  both worse than the default they were meant to improve. It is not silent: `build-limits`
  gained a `source` line naming the tier, the override, or the override it ignored and why.
  State table: `scripts/test-buildlimits.sh` (35 checks, in CI as `buildlimits-test`) — the
  module's first, since `zsh -n` was all it ever had. Hermetic via an **`nproc` stub on a
  from-scratch PATH**: the whole subject is what the module derives from a core count, and
  the row that matters most ("8 cores is still exactly 2") cannot be written at all without
  choosing the hardware. Two harness defects worth keeping: leaving `/usr/bin` on PATH let
  the "nproc missing" rows find the REAL nproc and measure the host, and the first
  before/after comparison inherited `MAKEFLAGS` from the herdr pane the suite was run in,
  so both modules reported the pane's own `-j2` — the same env-leak this file records for
  `CLAUDE_CONFIG_DIR` in `test-hspawn.sh`, in the one variable being measured. 7 mutants,
  7 deaths.
- **The sidebar's account tag named the wrong account on every isolated pane, and that
  is the surface that hid the concentration (DO-590).** clauth's herdr plugin resolves
  the account from the **machine-wide active profile**, and it cannot see a foreign
  `CLAUDE_CONFIG_DIR` — so once `claude()` started isolating every session by default,
  the one column that says which account a pane is spending stopped tracking it.
  Measured 2026-09-09 on a pane billing `quantivly-2`: the published token was
  `clauth: "unknown"`, the same literal sentinel `clauth which` returns from inside an
  isolated shell. Not a wrong-but-plausible name — no name at all.
  The fix belongs here rather than upstream because our own
  `claude/hooks/session-statusline.sh` runs **inside** the session, so a token it
  derives from that process's own `CLAUDE_CONFIG_DIR` names the credential **file**
  the pane reads rather than a machine-wide setting. **It is not "correct by
  construction"** — that phrasing shipped in the first draft and is the
  declared-vs-effective overclaim this file records twice already. `$acct` is a
  directory name, not an API answer: a `/login` as a different account inside an
  isolated session leaves it unchanged and wrong. What it beats is the alternative,
  which reports an account belonging to a different pane entirely. It publishes `acct`, and the claude
  row in `config/herdr/config.toml` consumes `$acct` in place of `$clauth`. **Both were
  not kept**: two account fields disagreeing, one of them reading `unknown`, is the
  surface being removed, not one to double. `acct=shared` is a **finding, not a
  formatting fallback** — it means the session is on the shared global credential, the
  file a profile switch overwrites under every holder at once.
  Three things the change turned up that outlast the change itself:
  - **A publisher and a consumer that each fail silently can only be checked as a
    PAIR.** An unpublished token renders as nothing; an unconsumed one is never drawn.
    So a half-applied deploy — `./install` relinks `config.toml`, a checkout that moved
    without it does not — looks exactly like a healthy sidebar from either side alone.
    `verify-tools.sh --herdr` asserts the two together, against the **live**
    `~/.config/herdr/config.toml` and never the repo copy: the repo copy always carries
    `$acct` after this change, so reading it would print a green tick for precisely the
    half-applied state the check exists to catch. A mutation that swapped the path
    proved it.
  - **Presence is not correctness, and the state table said otherwise for a while.**
    Every row asserted that `acct` was published and consumed; none asserted its
    VALUE. A hook hardcoded to `acct=shared` therefore passed the entire table while
    showing every pane the same wrong account — the original bug, reintroduced, under
    a green suite. Only mutation testing found it (M6 survived; six derivation rows
    were added to kill it). The derivation *is* the feature: rows that check the
    plumbing and not the answer are decoration.
  - **The pair check itself shipped with two of this file's own recorded faults, and
    CI was 20/20 green over both.** It read the claude row by shelling out to python3
    and its stdlib TOML module. python3 had never been *invoked* in
    `scripts/verify-tools.sh` — it appeared only as a NAME inside
    `HERDR_SERVER_DEPS` — so that was a new dependency in a checker, "a new way for a
    check to go quiet"; and that module is 3.11+, while Ubuntu 20.04, the first
    outside adopter's box, ships 3.8. Worse, **every** non-zero exit (python3 absent,
    module absent, file unreadable) was collapsed into `acct_con=0`, which printed a
    confident `✗ the hook publishes $acct but no claude sidebar row consumes it` — a
    FAIL naming a fault that does not exist, taking the exit code with it. On the one
    machine class the herdr work exists to support, the new check would have been red
    on arrival: the permanently-red checker, **sixth** recurrence, inside the check
    written while citing the rule. Now a bounded `sed` range (the `fallback_chain`
    technique) and a **tri-state**, where "could not read the row" is `NOT CHECKED`
    and never a verdict.
  - **Three of the new rows asserted an exit code against a fixture that was already
    failing something else.** `new_home` does not write the agent-skill file, so
    `verify-tools.sh --herdr` returned 1 regardless of what the account check did, and
    "takes the exit code with it" passed without testing anything — green for no
    reason, which this file already rates as badly as red for no reason. Build the
    fixture with `wire`, which the suite's own end-to-end row proves exits 0, so the
    thing under test is the only thing that can move the code.
  - **A row that greps for a defect will match the comment explaining the defect.**
    The row asserting the checker no longer imports the TOML module matched the
    checker's own comment saying why it does not. Both were right; the pair was
    circular. The comment now says so explicitly, so the next person does not
    reintroduce the literal string.
  - **`tr -d` deletes BYTES, so a multi-byte strip corrupts its neighbours.** The
    guard against U+00B7 (herdr's own token separator) shipped as
    `tr -d '\302\267'`, which removes those two bytes *individually* rather than the
    character they spell — measured, it turns U+00B1 (`C2 B1`) into a lone `\xB1` and
    U+04B7 (`D2 B7`) into a lone `\xD2`, i.e. **invalid UTF-8 published straight into
    the sidebar**, which is worse than the separator it was guarding against. `sed
    's/·//g'` matches the pair as a unit in a UTF-8 *and* a C locale (both checked;
    `/bin/sh` here is dash and the locale is not guaranteed), and sed is already used
    throughout that file so it adds no dependency. **The row that covered this passed
    the entire time**, because it only ever fed in the exact character being stripped:
    a guard needs a row for what it must LEAVE ALONE, not only for what it removes.
    Found by asking what a reviewer would attack — after CI had gone 20/20 green over
    it.
  - **A fixture `$HOME` needs `.cache/`.** The hook redirects the publish call's stderr
    into `$HOME/.cache/`, so without that directory the redirection itself fails,
    `herdr` is never exec'd, and the stub records nothing — which reads identically to
    "the hook published no token". The first draft of those rows failed for exactly
    that reason, and had passed beforehand only because an ad-hoc run used the real
    `$HOME`.

- **The sidebar publisher needs THREE things wired, and `./install` only does one** —
  `scripts/herdr-claude-wire.sh` now does the other two, and `verify-tools.sh --herdr` fails when
  they are missing (before DO-563 nothing checked either, in either install path).
  `claude/hooks/session-statusline.sh` is symlinked to `~/.claude/hooks/` by dotbot, but it must
  also be set as `statusLine` in `~/.claude/settings.json` (user-level, not in this repo), and that
  entry needs `"refreshInterval": 60` — without the interval the idle band freezes when the session
  goes quiet and every token then expires on the 4-minute TTL, blanking the rows. Without the
  statusLine entry it never runs, every `$mdl`/`$eff_*`/`$ctx_*` token resolves to nothing, and those sidebar
  rows render empty with no error. It doubles as the in-pane status line, so visible model/context
  text inside a pane means the publisher is alive.
- **`//` substitutes for null, never for a type error.** `jq -r '.statusLine.command // ""'`
  *errors* on a `statusLine` that is not an object (`Cannot index string with string`), and the
  discarded exit status left an empty capture that read as **the key is absent** — so
  `herdr-claude-wire.sh` overwrote another tool's statusLine and printed "Claude Code is wired",
  exit 0, in exactly the state the script is written to refuse. Read the **type** first
  (`.statusLine | type`), and land "could not read the answer" in the same arm as "it belongs to
  somebody else": ours is a positive test — an object whose `.command` names our own hook — never
  the absence of evidence against. `verify-tools.sh` had the mirror-image bug, reporting the fault
  by leaking jq's parser error into its own message, which satisfied a row that merely looked for
  the word "string". An object is not enough either: `{"command":null}` and
  `{"type":"custom","script":"/opt/x"}` are objects whose `.command` comes back empty.
- **The permanently-red checker recurred inside the change written to remove one.** DO-563 exists
  because `verify-tools.sh` printed a ✗ that the write-up had to tell modular adopters in prose to
  ignore; the Claude-wiring section it added then asserted unconditionally, so any machine without
  herdr and Claude Code was red forever with nothing to act on, and a clean `./install` was red
  before anyone had the chance to wire anything. It reports `○ skipped` when there is nothing to
  wire and fails only when herdr and `~/.claude` are both present. This file already documents the
  class twice (gh-doctor, backup-doctor); a third recurrence means it is not something to remember
  but a question to ask of **every new check**: on a machine that legitimately lacks this subject,
  what does it print, and what can the reader do about it?
- **The first outside adopter's three install failures were one root cause: the modular path
  provides no mise, and step 1 of every write-up assumed it did (2026-09-04).** `./install
  --herdr` deliberately links no `~/.config/mise/config.toml`, so nothing puts mise's node on
  `PATH` — and the documented activation line was the bare `eval "$(mise activate zsh)"`, which
  cannot work at that point because mise is not on `PATH` yet. `zsh/zshrc.conditionals` has had
  the two-branch form (`command -v mise` **elif** `-x ~/.local/bin/mise`) all along; the
  instructions dropped it. Downstream, `node` resolved to `/usr/bin/node` at v10.19.0 and
  `herdr-lazy install` died building `tdi/herdr-worktree-setup` — whose build is `npm ci` — with
  `npm v9.2.0 is known not to run on Node.js v10.19.0`, so the error blamed **npm**, the newer of
  the two. `HERDR_GUIDE.md` §3 step 0 had also attributed node to the Linear plugin, which has no
  build step at all, and told the reader "step 1 provides them", true only of the FULL install.
  Separately `persiyanov/herdr-reviewr`'s build hook runs `curl --retry-all-errors`, added in
  **curl 7.71.0**; an older curl exits **2** on the unknown option and herdr reports `plugin
  build failed … status: exit status: 2`, naming neither curl nor the flag. `apt` only supplies
  what the release ships (Ubuntu 20.04: curl 7.68, node 10.19), so both are floors to state, not
  bugs to chase. **The lesson is about the checker, not the versions:** `herdr-deps-check.sh`
  asked only "is it on `PATH`", so it printed a green tick over both — a presence check cannot
  see a version problem, and two of the three failures were versions. It now carries floors for
  curl and node (18.0.0, npm's own supported floor, not a second opinion about `.mise.toml`'s
  20), checks `npm` at all (it was in no list), reports an unparseable version as its own ⚠
  state rather than as agreement, and compares fields by hand rather than with `sort -V`, which
  BSD sort lacks — a floor that fails open on a Mac is worse than no floor. It also honours
  `-t 1` now: its colour was unconditional, which put escapes into every redirect **and** made
  `✓ curl` un-greppable, so the state-table row asserting an old curl gets no ✓ had been passing
  whatever was printed. A checker whose output cannot be grepped cannot be pinned.
- **`verify-tools.sh` answered a question nobody had asked yet.** The same adopter ran
  `--herdr` four steps early and reasonably asked whether `✗ bun / lazygit / yazi / clauth:
  MISSING under the server PATH` was a problem. It was not — `clauth` is *installed by* the
  plugin step, so a check run before it necessarily shows it missing — and both the page and the
  installer's next-steps text say the plugin-dependency lines do not affect the exit code. But
  neither can control *when* somebody runs the checker, so the advisory now prints in the
  section itself, only when something is missing (unconditionally would make it a line nobody
  reads). His run also took a branch this machine never does — `no server running — resolving
  against the launcher's declared PATH` — which is correct and was phrased as though it were a
  live measurement; it now says it is a **prediction** about the server the enable step will
  start.
- **We shipped a config that depends on an install step none of our instructions mention.**
  `config/herdr/config.toml` sets `[session] resume_agents_on_restore = true`, whose own comment
  says it "Requires the official integration per agent (`herdr integration install claude`)" —
  and that command appeared in **no** install path and **no** checker: not `install`, not
  `install.conf.herdr.yaml`, not `herdr-claude-wire.sh`, not `HERDR_GUIDE.md`, not
  `verify-tools.sh`. It stayed invisible for the most ordinary reason there is: `herdr
  integration status` on this workstation says `claude: current (v8)`, installed here long
  before any of those files were written. Found by the first outside adopter, 2026-09-04.
  **What breaks without it is session resume, NOT agent-state detection** — read off the
  installed hook rather than assumed: it is one `SessionStart` hook calling
  `pane.report_agent_session` with the Claude session id and transcript path, so a server
  restart returns the panes without their conversations, silently. Detection is screen-scraping
  either way; the hook's own comment records that older versions mapped `SubagentStop` to state
  and that this was removed upstream, so do not restate the old behaviour from memory. It now
  lives in `scripts/herdr-claude-wire.sh` — the one script that already owns what dotbot cannot
  write into `~/.claude` — and `verify-tools.sh --herdr` asserts it. Probed in a throwaway
  `$HOME` rather than assumed before wiring it in: it does not prompt, exits 0 with stdin
  closed, is idempotent, and **merges** `settings.json`, so an existing `statusLine`, unrelated
  top-level keys and other `SessionStart` hooks all survive — which is load-bearing, because the
  wirer writes the statusLine into that same file a few lines earlier. The wirer re-reads the
  status afterwards rather than trusting exit 0, and an older herdr with no `integration`
  subcommand is a ⚠, not a ✗: upgrading herdr is not a fix a report can ask for.
- **State table: `scripts/test-herdr-modular.sh`** (170 checks, in CI as `herdr-modular-test`) —
  the two commands a modular adopter runs, hermetic via a recording `herdr` stub and fake `$HOME`.
  Two defects in the suite itself are worth more than most of its rows:
  - **A row that cannot reach the branch it names is unfailable.** The row asserting `--herdr`
    never prints the `ln -sfn` that pins ~25 tools globally passed with the full-install report
    un-gated *entirely* — that string is emitted only from the mise-drift FAIL branch, and the
    fake `$HOME` had no active mise config, so every run took the "nothing to compare" branch
    instead. The one row the whole change's rationale rests on was decorative. The fixture now
    writes a real, differing `~/.config/mise/config.toml` to make the branch reachable. Mutation
    testing is what found it: a row that passes both ways is worthless however carefully worded.
  - **A suite that shells out to the live machine is not hermetic, whatever its header says.** It
    `pgrep`'d for the real herdr server, so a contaminated server turned two exit-code rows red
    for a reason unrelated to the diff *and* made every row expecting `rc=1` pass for the wrong
    reason — red for no reason and green for no reason at once, under a header claiming "no
    server". Stub it, the way `test-systemd-reconcile.sh` stubs `systemctl`; never rely on the
    tool's absence, because this box has the real thing.

## Claude Code accounts & MCP (`claude-doctor`)

The mechanism and every incident behind these rules — the credential race, per-session account
dirs, clauth's writes, suspend storms, `auth_broken` — are in
[docs/CLAUDE_ACCOUNTS.md](docs/CLAUDE_ACCOUNTS.md); how an account is chosen is in
[docs/CLAUDE_ACCOUNT_PICKER.md](docs/CLAUDE_ACCOUNT_PICKER.md); what to run and click is
[docs/CLAUDE_ACCOUNT_MCP.md](docs/CLAUDE_ACCOUNT_MCP.md); which plugins run where is
[docs/CLAUDE_SETUP.md](docs/CLAUDE_SETUP.md). To diagnose a logout, a dropped MCP server or a
session on the wrong account, use the [claude-accounts](.claude/skills/claude-accounts/SKILL.md) skill.

- **Run `claude-doctor` first, and never `clauth <profile>` while it says the stored copy DIFFERS
  from the live credential.** Refresh tokens rotate server-side; clauth restores its stored copy,
  and a superseded token logs out every session on that account at once.
- **Prefer `claude-as <profile>` to `clauth <profile>`** — it changes nothing outside your session.
- **Every session gets its own account dir** (`claude()` does this by default). An account dir's
  `.credentials.json` is a **symlink** into `~/.clauth/profiles/<p>/`, never a copy — a copy is an
  independent holder of one grant. **Never relink one by hand**: Claude Code writes atomically and
  replaces the link, and only the reconciler (`scripts/claude-account-dirs.sh --reconcile`, a
  2-minute timer) may decide which side is live.
- **Name the account from `CLAUDE_CONFIG_DIR`** — not from the sidebar, not from `clauth which`
  (which reports credential ownership, answered from `$CLAUDE_CONFIG_DIR`, not the active profile).
- **Never put MCP or auth env vars in `~/.claude/settings.json`'s `env`**: clauth clears it on every
  profile switch. Put them in `zsh/zshrc.herdr`.
- **A standing `auth_broken` is reported, never cleared out of band.** The remedy is
  `clauth login <profile>`; a later successful *fetch* does not clear it on clauth 0.15.1.
- **Access tokens live 8 h.** A suspend that outlasts the validity a token had *left* expires every
  account at once; expect clauth to quarantine accounts on resume.
- **Accounts are chosen per directory** from `~/.config/claude-tenants.zsh`; `claude-pick --explain`
  shows which one a directory would bill and why. A spent weekly window demotes, never refuses.
- **In a Claude Code Bash-tool shell, single-underscore functions do not exist** — the shell
  snapshot drops them, so `claude`/`hspawn` are defined and their `_helpers` are not. A guard whose
  failure mode is a *match* rather than an error is the one to audit.
- **Checkers here fail by looking clean.** Read a JSON value's type before indexing it; test exit
  status, never the emptiness of a pipeline's output (a hash of nothing matches every hash of
  nothing); `${VAR:-x}` substitutes for *empty* as well as unset; a test stub is a claim about the
  real tool; and no diagnostic ever prints a credential.

## GNOME Desktop Configuration

Clean, modern GNOME (dark `Yaru-prussiangreen-dark`, floating autohiding **bottom** dock, empty desktop, tmux-friendly keys) applied reproducibly via **stock GNOME/Yaru only** — no third-party extensions or themes.

- **Mechanism:** curated `gsettings` script (schema-validated, idempotent, reviewable), **not** `dconf dump` (which drags in machine-specific cruft). GNOME has no first-party export/import.
- **Source of truth:** `scripts/apply-gnome-settings.sh` (portable core). Runs automatically during `./install` on GNOME only (no-op on servers / other desktops).
- **Machine-specific layer:** `~/.gnome-settings.local` (dock favorites, custom launch keys) — mirrors the `~/.zshrc.local` pattern, sourced by the apply script, never overwritten. Create with `gnome-init`. It runs LAST and silently wins, so a line here can undo one the portable layer just applied: `grp:alt_shift_toggle` was re-enabled that way on every run, killing all four of herdr's `alt+shift+arrow` bindings while `gnome-apply` printed two ✓ lines three apart and `gsettings get` showed the override as if it were the applied value. An overriding set now prints `(overrides <previous>, set above)` — a note, not a warning, since overriding is what the layer is for.
- **Tmux integration:** the script moves GNOME workspace switching off `Ctrl+Alt+Arrow` onto `Super`-based shortcuts so tmux pane-resize works (the previously-manual fix is now baked in).
- **XDG user-dir guard:** `scripts/repair-xdg-user-dirs.sh` (alias `xdg-repair`) keeps `~/Desktop`, `~/Documents`, … as real directories so `snapd-desktop-integration` can't turn them into broken self-referential symlinks. Idempotent; `./install` runs it on graphical workstations (gated on `$XDG_CURRENT_DESKTOP` + `xdg-user-dirs-update`, skipped on servers). See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
- **Wayland gotcha:** changes apply live; dock relayout is guaranteed after one log out / log in. `Alt+F2 r` / `Meta.restart` are X11-only — never use them.

See [docs/GNOME_CONFIGURATION_GUIDE.md](docs/GNOME_CONFIGURATION_GUIDE.md) for the full guide.

## Backup & Restore

Encrypted **3-2-1 backups** via **restic** (engine) + **resticprofile** (declarative
orchestrator). Targets an **external HDD** (when docked) + **Backblaze B2** (offsite). Fills
the gap `dev-setup`/dotfiles can't: credentials, unpushed work, app/desktop state, network/VPN
secrets, personal files. `backup` in `core.sh` is a *separate* single-file utility — the system
commands are all `backup-*`.

- **Source of truth:** `resticprofile/profiles.toml` (policy: sources, excludes, retention, checks, schedule) and `udev/99-backup-external.rules` (hotplug remount). Both **copied** root-owned to `/etc/` by `backup-setup` — never symlinked (root runs them; a user-writable config would be privilege escalation) — and both drift-checked by `backup-doctor` against the repo copy.
- **Portability (DO-459):** the repo configs are user/host-generic. `examples/backup-{includes,excludes}.txt`, `examples/backup.local.template`, `systemd/restic-backup-external.service` and `udev/99-backup-external.rules` carry `__BACKUP_*__` placeholders rendered at install time by `scripts/backup-render.sh` (`__BACKUP_HOME__`/`__BACKUP_USER__`/`__BACKUP_HOSTNAME__` from the machine; `__BACKUP_EXTERNAL_UUID__`/`__BACKUP_EXTERNAL_MOUNT_UNIT__` supplied by the caller) — restic and systemd `EnvironmentFile` do **no** shell expansion, so `$HOME` can't appear in the installed files, and `/home/*` globs would change include semantics. **An unresolved placeholder is a hard error, never a blank:** an empty `ENV{ID_FS_UUID}==""` would match every device without a UUID. `profiles.toml` needs no install-time rendering — its tags use resticprofile's runtime `{{ .Hostname }}`; the `[groups]` name is the fixed `full` (= `backup-now`'s default target). `backup-doctor`'s drift check compares live `/etc` files against the *rendered* templates.
- **Machine-specific layer:** `~/.backup.local` (repo URLs, B2 keys, healthcheck URLs) rendered from `examples/backup.local.template`. Created by `./install` on GNOME / `backup-init`. Plain `KEY=value` (consumed by both shell `source` and systemd `EnvironmentFile`).
- **Runs as root** (to read `/etc/NetworkManager/system-connections` + the keyring). The B2 timer is generated by resticprofile (`Persistent=true`); the external HDD uses `systemd/restic-backup-external.{timer,service}` — a 6-hourly timer whose `ConditionPathExists` runs it **only when the drive is docked** (a `.path` unit was avoided: `PathExists` retriggers a oneshot in a loop). Immediate run: `backup-now external`.
- **Keeping the external drive mounted is the whole game, and every layer of it fails silently.** An unmet `ConditionPathExists` makes systemd *skip* the unit, and a skipped unit is not a failed one — no error, nothing in `--state=failed`, no notification, no healthchecks ping. So `backup-setup` writes an `/etc/fstab` entry from `BACKUP_EXTERNAL_UUID` (covers boot) **and** `udev/99-backup-external.rules` (covers dock cycles, which on a laptop outnumber boots), plus a `service.d/10-external-mount.conf` drop-in ordering the run `After=` the mount unit so the timer's `Persistent=true` catch-up can't win a race against USB enumeration. **`After=`, never `Requires=`/`RequiresMountsFor=`** — those turn an undocked disk into a *failed* unit every 6h, which is the false alarm the `ConditionPathExists` design exists to avoid.
- **Four traps specific to this area**, all found by review rather than by use:
  - `findmnt --verify` errors on "unreachable on boot" for a `nofail` entry whenever the disk is undocked *or* its mount point directory is absent, so it can only be used to compare **parse-error counts**, never as a pass/fail gate — gating on its exit code rejects every correct entry in exactly the states that need fixing. Parse both `findmnt` summary shapes (`N parse errors, …` *and* the bare `Success, no errors or warnings detected`), and always under **`LC_ALL=C`**: both strings are gettext-marked in util-linux and ship translated in Ubuntu's language packs, so a translated locale otherwise makes every clean table look unparseable and kills the feature permanently.
  - **`test -e "$repo/config"` is not a docked test**: a leftover directory on the root filesystem satisfies it while the disk is unmounted, so `backup-status`/`backup-doctor` use `findmnt --mountpoint`.
  - **`findmnt -S UUID=x` matches a `/dev/disk/by-uuid/x` fstab entry only while the disk is attached** — it resolves the tag through `/dev/disk/by-uuid`. That is the form Ubuntu's installer writes (and what `/boot` uses here), so undocked — the state the whole feature exists for — a correct fstab reads as having no entry. Always query the literal device path as a second step (`fstab_target_for_uuid`, `_backup_fstab_target_for_uuid`).
  - **Never `render … | sudo tee /etc/…`.** `tee` truncates the destination before the renderer's exit status is known, so a failed render leaves a zero-byte `/etc` file that installs "successfully": an empty `includes.txt` backs up nothing, an empty `.service` is a unit that does nothing. Use `render_install` (render to a temp file, check, then `install`).
- **The mount point is a `dirname` of a hand-edited path, so it is guarded before use.** `BACKUP_EXTERNAL_REPO` one level too shallow resolves to `/media/<user>`, and a typo resolves to `$HOME` — and everything downstream then passes, so the external disk gets mounted over the user's home at every boot (`nofail` does not help; the mount *succeeds*). `external_mount_point_sane` refuses a non-absolute, unnormalised (`/./` counts — it resolves *past* a deny-list of literal strings) or symlinked path, a deny-list of system directories including `$HOME`, and any existing directory that is not already a mount point and is either non-empty or *unlistable* — "cannot read it" is not "it is empty". **The per-user parents are still on that list, but nothing rests on them any more.** For every other entry the list is belt-and-braces: `/etc` and `$HOME` are non-empty, so the content checks refuse them whether or not anyone listed them. `/media/<user>` is the one dangerous directory that is *legitimately empty* whenever no drive is docked, and also legitimately the parent of the right answer — so there the list was load-bearing and alone, and both holes ever found in it were there (an empty `$USER`; then `/media/./<user>`). The question is now put to the system: `path_is_account_directory` refuses `<parent>/<leaf>` for `/home`, `/media`, `/run/media` when `getent passwd` says `<leaf>` names a **regular login account** — uid within login.defs' `UID_MIN`..`UID_MAX`, **or** a home directory under `/home/`. That second test is not redundant: the login.defs window is right for local accounts and useless for exactly the ones the `getent` call was justified by, since SSSD's AD id-mapping starts at `ldap_idmap_range_min=200000` by default, real AD-mapped uids land in the millions, and systemd-homed allocates above `UID_MAX` — so a domain-joined workstation got no protection past the current user. Their home is `/home/<name>` (SSSD's `fallback_homedir` default), which is what catches them, and it still matches none of `backup` (`/var/backups`), `games` (`/usr/games`), `nobody` (`/nonexistent`) or `root` (`/root`). The literals stay as belt-and-braces (they cost nothing and still fire if `getent` is unavailable), but the structural rule is what does the work: it covers *every* account rather than the current one, and needs no identity resolution at all, so the `$USER` class of bug cannot recur in it. **The uid bound is the whole discriminator, not a detail.** udisks makes these directories only for accounts that log in to a desktop; matching *any* passwd entry would refuse `/media/backup` — a plausible hand-made mount point, with `backup` a stock uid-34 account — and that is not a harmless over-rejection: `install_external_udev` treats an unusable mount point as a reason to **remove** the hotplug rule, so a working install would silently lose its remount-on-dock. Two smaller traps: the passwd *name* field is compared back, so a numeric key (`getent passwd 1000`) doesn't make `/media/1000` look like a user directory; and the lookup runs under `timeout`, since NSS with an unreachable LDAP source would otherwise hang the installer with no output. A missing `timeout` binary falls back to a direct call rather than letting every lookup return empty, which would switch the rule off with no sign. **An unanswered lookup is not a clean "no", and the guard is tri-state because of it.** Only `getent`'s exit 2 means "no such key"; `timeout`'s 124 and a missing `getent` (127) mean the question never ran, and reading those as "not an account" switched the rule off silently on exactly the hosts the `timeout` exists for. `external_mount_point_sane` returns **2** for "could not determine" and refuses — **from the very end of the function, after every check that could settle the path with certainty has had its turn.** Returning it as soon as the lookup failed downgraded certain refusals to uncertain ones: `BACKUP_EXTERNAL_REPO=$HOME/restic`, the single most canonical error there is, became "could not check, keeping the rule" on any host whose name service was merely slow, and the `/media/$me` literals went unreachable in the one state where anything rests on them — accepting would be no safer, since the correct mount point is also one component under `/media` — and **every step that installs persistent state keys on that 2 to change nothing at all** — a name-service hiccup must not undo what an earlier successful run got right. There are exactly four consumers and each has to be checked individually: the `/etc/fstab` write skips (writes nothing, so a plain skip is correct), `install_external_udev` keeps the existing rule, `init_repos` skips *and says "could not be checked" rather than "unusable"*, and `install_external_schedule` returns before it writes. That last one is the expensive one and the ordering inside it is load-bearing: it re-renders the unit from the template first, which **resets `ConditionPathExists` to the template's own path**, so a bail-out placed after that has already destroyed the setting it meant to preserve — and it then `rm -f`s the `After=` drop-in. A unit whose `ConditionPathExists` names a nonexistent path is *skipped, not failed*, so nothing reports it, and `backup-doctor` checks the `10-backup-env.conf` drop-in but has **no check at all for `10-external-mount.conf`**. The lookup is bounded at 5s, not 2: since an unanswered lookup is now a refusal, too tight a bound turns a healthy-but-slow host (a cold SSSD cache resolving against a remote DC over a VPN) into a permanent installer failure telling the user to fix a working name service. `root` is accepted (`/media/root`) because uid 0 is outside the window *and* `/root` is not under `/home/` — a deliberate carve-out, *not* the claim that udisks never mounts there, which is false: on Ubuntu's layout it does, for a uid-0 session. Reaching uid 0 would mean reaching past every system account on the way, and the preflight already refuses to run the installer as root. It is also **not** a depth rule ("three components under `/media`"): that rejects `/media/backup-hdd`, `/media/external` and `/mnt/store`, which are ordinary hand-made mount points and not udisks parents at all. **Every** step that consumes the mount point is gated on it: the `/etc/fstab` write, the udev rule, `restic init`, and the `ConditionPathExists`/`After=` wiring. Missing the init gate is the expensive one: `BACKUP_EXTERNAL_REPO=/restic` derives the mount point `/`, which *is* mounted, so restic would initialise the "external" repository on the root filesystem and every 6-hourly run would then write there while `backup-status` reported `docked ✓`.
- **A udev step that declines because the *configuration* no longer supports a rule removes the rule a previous run installed**, and `backup-doctor` checks for a stale rule even when nothing is configured. A leftover rule names a UUID that may now belong to a different disk, keeps passing `udevadm verify`, and simply never fires — and a drift check gated on "is anything configured" is exactly how it stays invisible. The two bail-outs where only *this run* failed (render error, `udevadm` rejection) deliberately keep the installed rule, which is more likely correct than absent; they are covered by the doctor's drift compare instead. Don't restate this as "every skip path removes" — it isn't, and the difference is the point.
- **`scripts/test-backup-external.sh` pins all of the above** (99 checks, root-free, no real disk) and **runs in CI** (`backup-external-test`). It asserts its own harness first: sourcing `setup-backup.sh` also runs that script's `set -euo pipefail`, so the suite re-declares `set +e` — otherwise the first expected-to-fail assignment kills the run mid-table with no failure count — and it aborts unless every function under test is actually defined, because most of these assertions are "nothing was installed", which is also what a suite that loaded nothing produces.
- **Ransomware resistance:** B2 append-only key (no `deleteFiles`) + lifecycle rule (`daysFromHidingToDeleting=30`); **not** Object Lock (breaks restic prune). A full-access key lives only in the offline kit (`backup-prune`).
- **Cold-start break:** an age-encrypted **offline emergency kit** holds the restic password, B2 full key, Bitwarden recovery, LUKS passphrase + header, WiFi PSK, and a GitHub PAT — so restore doesn't deadlock on "secrets are inside the backup I can't open."
- **Restore correctness (LVM-on-LUKS):** regenerate — do not restore — `/etc/fstab`, `/etc/crypttab`, `/etc/machine-id`, `ssh_host_*`. Timeshift is file-level rollback only (known LVM-on-LUKS bare-metal restore bug). `backup-restore-system` bakes those four excludes in so the `/etc`-slice restore can't break boot.
- **Verification (DO-449):** a backup's deadliest failure is silent. `backup-doctor` asserts the whole chain is *correct* (perms, config drift vs. `~/.dotfiles`, the DO-448 env drop-in, snapshot age, B2 repo size vs `BACKUP_B2_SIZE_WARN_GB` + last-run churn vs `BACKUP_B2_CHURN_WARN_MB` + prune staleness vs `BACKUP_B2_PRUNE_REMIND_DAYS` (the B2 repo is append-only — it grows until a manual `backup-prune`, and a hit Backblaze storage cap fails ALL runs at the lock write), that healthcheck URLs are set, kit/LUKS-header freshness, disk space; non-zero exit on FAIL). A weekly `systemd/restic-verify.timer` runs `scripts/backup-verify.sh` — a content canary (critical paths present in the latest snapshot) + restore canary (one file restored) — decoupled from `[b2.check]`, skips cleanly when offline, alerts via `restic-notify` (`BACKUP_HC_URL_VERIFY`). `backup-drill` is the on-demand equivalent. `restic check` proves *intact*; this proves *complete + restorable*. Desktop failure notifications dedup on state change (daily reminder while stuck + one "recovered" popup); healthchecks pings fire every run.

Commands: `backup-init`, `backup-setup`, `backup-now`, `backup-status`, `backup-doctor`, `backup-drill`, `backup-snapshots`, `backup-check`, `backup-restore`, `backup-restore-system`, `backup-mount`, `backup-unlock`, `backup-prune`, `backup-luks-header`, `backup-kit`.

See [docs/BACKUP_AND_RESTORE_GUIDE.md](docs/BACKUP_AND_RESTORE_GUIDE.md) for setup, the disaster-recovery runbook, and the verification regimen.

## Audit Tripwire (broadcast kills)

A two-line **auditd** rule that records any real `kill(-1, sig)` — *"signal every
process I may signal"*, which on a desktop is the entire graphical session. This
machine runs many parallel agent sessions with shell access, and a broadcast kill
produces a perfectly orderly teardown: no crash, no OOM, no coredump, nothing in
the journal explaining it. Without the rule there is no evidence to find; with it
the record names the sending process, exe, cmdline and parent.

- **Source of truth:** `audit/99-logout-catch.rules`. **Copied** root-owned to
  `/etc/audit/rules.d/` by `audit-setup` — never symlinked, same reasoning as
  `resticprofile/profiles.toml` (root's auditd reads it).
- **`a0` must stay `0xFFFFFFFF`, never widened to 64 bits.** Audit's rule field is
  u32, and on x86-64 a C `int` of `-1` is passed via `mov edi,-1`, which
  zero-extends — the kernel sees `0x00000000FFFFFFFF`. A 64-bit constant matches
  nothing, and a rule that matches nothing is indistinguishable from a clean
  machine. `a1!=0` drops signal-0 probes (error-checking only, sends nothing).
- **auditd takes AppArmor denials out of the journal.** After install,
  `journalctl -k | grep apparmor` returns nothing — use `sudo ausearch -m AVC`.
  Relevant to the snap/`unprivileged_userns` notes above.
- **"Armed" is three independent things**, and each can be false while the other
  two look fine: the rules are in the kernel (`auditctl -l`), auditing is switched
  on (`enabled != 0`), and **a daemon is persisting records to disk** (`pid != 0`).
  Rules live in the *kernel*, so `auditctl -l` lists them happily with auditd
  stopped — but then records go to the kernel ring buffer instead of
  `/var/log/audit/audit.log`, and `ausearch` (so `audit-sweeps`) is blind forever
  with no error. `audit-setup` and `audit-status` both assert all three.
- **Silent-failure modes** (`audit-status` reports each as its own failure): a
  rejected rule field leaves *zero* rules loaded with no error; auditing switched
  off; no daemon registered; a climbing `lost` counter dropping records;
  `/etc` drifted from `~/.dotfiles` (the file is *copied*, so editing the repo
  copy alone changes nothing); and `disk_full_action`/`admin_space_left_action`
  are `SUSPEND`, so auditd stops logging quietly if `/var` runs low. Each
  otherwise looks exactly like "nothing bad happened".
- **Scope: `a0 == -1` only.** `kill(0, sig)` ("my whole process group") is a real
  hazard but shells issue it routinely, so a rule would be noise; `kill(-pgid,
  sig)` isn't expressible statically. `-1` is the one that can only ever be a
  session-wide broadcast. See the rules file for the full reasoning.
- Expect a benign burst from `systemd-shutdown` (pid 1) at every reboot.

Commands: `audit-setup` (add `--yes` to skip the auditd install prompt),
`audit-status`, `audit-sweeps`.

## Common Tasks & Workflows

```bash
source ~/.zshrc      # Reload config (or: zshreload)
localrc              # Edit ~/.zshrc.local
qcache-refresh       # Refresh startup caches
gh-refresh-tokens    # Refresh GH CLI token cache
gh-doctor            # Which GitHub account is gh ACTUALLY using here? (--offline)
claude-doctor        # Claude auth + MCP health; run BEFORE 'clauth <profile>'
claude-as <profile>  # claude on a named account: isolated AND still a team lead
claude-pick          # which account would this directory bill? (--explain --json --strict)
scripts/claude-account-dirs.sh --all   # (re)build every profile's persistent config dir
scripts/redact-secrets.sh  # Filter secrets out of anything before it is printed
tool_status          # Check installed tools
herdr-help           # In-shell herdr cheat sheet (hspawn/hreap/clauth)
build-limits         # Show active build/test worker caps (see zshrc.buildlimits)
alacritty-init       # Set up Alacritty config (new machine)
qmux                 # Per-server tmux sessions for dev/staging/demo (Alt+w to switch)
dotfiles-doctor      # Is the live config the reviewed config? (--fetch to check the real remote)
dotfiles-work <br>   # Create/enter a worktree so the primary checkout stays on main
git -C ~/.dotfiles merge --ff-only origin/main   # DEPLOY (after a fetch). NOT `git pull`
gnome-apply          # Apply curated GNOME desktop config (idempotent)
xdg-repair           # Fix/guard ~/Desktop, ~/Documents, ... XDG dirs (idempotent)
gnome-init           # Create ~/.gnome-settings.local (dock favorites, launch keys)
gnome-status         # Summary of GNOME version, theme, dock, extensions
scripts/herdr-claude-wire.sh    # Wire Claude Code to herdr (statusLine + agent skill file)
scripts/verify-tools.sh --herdr # The one check a modular herdr adopter runs
backup-init          # Create ~/.backup.local (repo paths, B2 keys)
backup-setup         # One-time guided backup install (restic, repos, timers, kit)
backup-now           # Run a backup now (external HDD + Backblaze B2)
backup-status        # Backup health: targets reachable, timers, latest snapshot
backup-doctor        # Full-chain health assertion (perms, drift, alerting, freshness)
backup-drill         # Prove the backup is complete + restorable (content + restore canary)
backup-restore       # Guided restore of a snapshot to ~/restore-<ts>/
backup-restore-system # Guarded /etc-slice restore (never clobbers fstab/crypttab/machine-id/ssh_host_*)
audit-setup          # Install/refresh the broadcast-kill audit tripwire (idempotent)
audit-status         # Armed, switched on, recording to disk, in sync? (non-zero on fail)
audit-sweeps         # Show broadcast kill(-1) events (default: last 24h)
```

Workflow guides: [git](examples/git-workflows.md) | [docker](examples/docker-workflows.md) | [fzf](examples/fzf-recipes.md) | [tmux](examples/tmux-workflows.md)

## Troubleshooting

Quick fixes for common issues. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for detailed troubleshooting.

- **Slow startup:** `time zsh -i -c exit` (target: <250ms). Caches at `~/.cache/{quanticli-paths,gh-token-cache,p10k-pr-cache}/`
- **Function not found:** Check symlink (`ls -la ~/.zshrc`), re-run `./install`
- **Tool not loading:** `command -v toolname`, then `source ~/.zshrc`
- **mise trust:** `mise trust ~/.dotfiles/.mise.toml`
- **Alias conflicts:** `type commandname` to inspect, `\commandname` to bypass
- **Git auth:** `gh-doctor` (declared vs *effective* account — `gh auth status` reports only the declared one), then `gh auth login`
- **Claude logged out / MCP servers dropping:** `claude-doctor`. These are usually the *same* fault — the claude.ai connectors ride on the login token. Never run `clauth <profile>` while the doctor reports the stored copy DIFFERS from the live credential — and prefer `claude-as <profile>`, which changes nothing outside your own session. If several sessions were logged out *at the same moment*, the cause is a write to the shared file, not your session: check the doctor's concurrency groups for how many are still on it.
- **Backups:** `backup-doctor` (full-chain correctness — start here), `backup-status` (quick health), `systemctl list-timers | grep restic`, `resticprofile -c /etc/resticprofile/profiles.toml show` (validate config)
