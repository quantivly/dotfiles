# Deploying this repo: the live-config guard and its traps

Why `git checkout` in this repository *is* a deploy, how that failed in both directions, and the
guard, `dotfiles-doctor`, the `dotfiles-work` worktree convention and the umask guard built in
response — with every trap found in them and the state table that pins it. The deploy procedure
and the rules are in [CLAUDE.md](../CLAUDE.md); this page is the evidence behind them.

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-626), from the tree at `95568ae`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 95568ae:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

## The checkout IS the deployment

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

## `safe.directory` in the tracked gitconfig (DO-589)

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
[docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md). Making that shim permanent in the shell
layer (option 3 in DO-589) is deliberately *not* done: it reaches only processes that inherit
the interactive shell, it also redirects the writes people make on purpose, and it is a
larger decision than this issue's.

Rows: `scripts/test-dotfiles-guard.sh`, "safe.directory in the tracked gitconfig" (63). The
fixture rationale is in that section's comments. Two things are worth knowing before reading
them: `GIT_TEST_ASSUME_DIFFERENT_OWNER=1` is how a foreign-owned repository is reached
without root, and the "remedy remedies" row runs the fix **as the doctor prints it** and
asserts the tree is clean — the row that would have caught the bare `restore` before a
review did.
