# `$TMPDIR` and its cleanup

`config/environment.d/tmpdir.conf` points `TMPDIR` at `~/.cache/tmp` for everything the systemd
user manager and the graphical session start. That moves temp files off the `/tmp` tmpfs, so they
no longer use RAM, and it also takes away the cleanup `/tmp` got from every reboot. This page is
about the half that gives the cleanup back: `systemd/tmpdir-clean.timer`, which runs
`scripts/tmpdir-clean.sh`, which applies `config/user-tmpfiles.d/tmpdir.conf` (DO-824).

**The rule this page backs:** nothing that must outlive 7 days goes under `$TMPDIR`. Registered git
worktrees there are guarded. Clones are not.

## Operating it

```bash
scripts/tmpdir-clean.sh --dry-run     # what a run would delete (systemd >= 256 only)
journalctl --user -u tmpdir-clean.service -e
cat ~/.local/state/tmpdir-clean/log   # one line per run
scripts/tmpdir-clean.sh --check       # what scripts/verify-tools.sh asserts
```

`./install` enables **and starts** the timer, and its first run is the next 05:15, not the moment
it starts ([why](#why-install-starts-the-timer-and-why-that-does-not-run-it)). Read the dry run
before then.

A log line reads `mode=apply guarded=3 rc=0 used=<bytes>-><bytes> inodes=<n>-><n> seconds=<s>`.
`used` and `inodes` are for the whole filesystem `~/.cache/tmp` is on, so other writers move them
too. Read them as a trend, not as what one run deleted.

### Turning it off

Export `TMPDIR_CLEAN_OFF=1` in `~/.zshrc.local` (the convention `GH_ACCOUNT_ROUTING_OFF` and
`CLAUDE_ISOLATION_OFF` follow), then run `./install`. It stops the timer and removes its `.wants`
link, and leaves the unit linked. It never runs `systemctl --user disable`: that deletes the dotbot
symlink that *is* the unit, and the next `./install` would re-link and re-enable it. From then on
`--check`, and so `verify-tools.sh`, reports the cleanup as deliberately off rather than FAILing,
and `check-timer-health.sh` skips a linked unit nobody enabled. Unset it and `./install` to turn
it back on.

The variable is read by `./install` and `verify-tools.sh`, never by the timer, so it has to be in
the environment they run in. With it set `~/.cache/tmp` grows without limit again.
`tmpdir.conf` stays linked, so a hand-run `systemd-tmpfiles --user --clean` still applies it,
guarded only by whatever the last run wrote to `$XDG_RUNTIME_DIR`.

## The ages

| path | age | why |
|---|---|---|
| `~/.cache/tmp` | 7 days | what the hand-written rule already said; upstream systemd ages `/tmp` at 10 days |
| `~/.cache/tmp/claude-<uid>/` | 14 days | Claude Code's per-session scratchpads and task output. A session can be resumed days later and still expect its scratchpad |

**An entry is deleted only when its atime, mtime, btime and (for files) ctime are all older than
the age** (`man tmpfiles.d`, "Age"). `/` is mounted `relatime` here, so a file read inside the
window survives. A file created inside the window survives too, whatever its mtime says, because
btime is counted. The tool also skips a path someone holds a BSD lock on, and live unix sockets.

**A path with its own line is skipped by its parent's cleanup.** That is what lets the `e` line
give `claude-<uid>/` a longer age than the `d` line above it. Measured on systemd 259 before relying
on it: a 10-day-old file under `claude-<uid>/` survived a clean that removed a 10-day-old file at
the top level.

## Why it had to be built, rather than switched on

Measured 2026-10-15, read-only:

- The cleanup rule existed, as a hand-written untracked `~/.config/user-tmpfiles.d/tmpdir.conf`
  (dated 2026-08-04). Its comment said "Applied by systemd-tmpfiles-clean.timer". That was false.
  Ubuntu does not apply user presets, so the vendor `systemd-tmpfiles-clean.timer` is disabled for
  the user manager, and it had **never run**.
- Nothing noticed. `scripts/check-timer-health.sh` and `scripts/reconcile-systemd-units.sh` only
  see units linked from this checkout, and the vendor timer is not one.
- By then `~/.cache/tmp` held about **188G in about 258k top-level entries**, mostly leaked
  nanoclaw vitest directories (that leak is tracked separately). `claude-1000/` alone was 51G and
  had never been cleaned.

**Do not enable the vendor timer instead.** It applies `tmpdir.conf` without the worktree guard
below. `scripts/verify-tools.sh` WARNs when it is enabled.

## The worktree guard

Registered git worktrees can live under `~/.cache/tmp`: Claude scratchpad worktrees and review
checkouts. A worktree's metadata lives in its host repository's `.git/worktrees/<name>`, outside the
root. Aging the checkout out loses its uncommitted files. After a later `git worktree prune`, it
also loses any commit that only the worktree could reach.

So before every clean, `scripts/tmpdir-clean.sh` writes an `x <path>` line for each such worktree to
`$XDG_RUNTIME_DIR/user-tmpfiles.d/tmpdir-worktrees.conf`. `x` makes systemd-tmpfiles skip that
subtree. The file is on the user search path, so a hand-run `systemd-tmpfiles --user --clean` sees
it too. It is a snapshot: a worktree created after the last run is unguarded until the next one.

- **A `.git` file is a worktree iff the gitdir it names points back at it**:
  `realpath("$gitdir/gitdir")` is the `.git` file. A submodule's `.git` file names a gitdir with no
  back-pointer. A copied worktree's back-pointer names the original. Neither is guarded. Relative
  paths (`worktree.useRelativePaths`, git 2.48+) are resolved.
- **Each pointer file is read as git reads it**: whole, with trailing CR and LF stripped. So a
  `.git` file with CRLF line endings, which git accepts, is a worktree. A back-pointer with a
  newline in its path is seen whole, and refused below. Read to its first line, it named a
  different path, and the worktree was classed "not a worktree" and deleted.
- **"No back-pointer" must mean it is not there.** `[[ -e ]]` is also false when a directory on the
  way cannot be searched (`EACCES`), so the nearest ancestor that resolves decides. If this user
  can search it, the file is absent. If not, the run refuses.
- **The host is `$gitdir/commondir`.** A host inside the root is temp too, and its worktrees age out
  with it. A registered worktree whose `commondir` cannot be read is guarded, since it cannot be
  shown to be temp.
- **The `x` line is the path as `find` spelled it**, through any symlink in `$HOME`. systemd-tmpfiles
  matches `x` lines against the path it walks, spelled from `%h`. Measured on 259 with `$HOME`
  reached through a symlink: the spelled-through line was honoured, and a `realpath`'d line was not,
  so the worktree was deleted with a guard naming it.
- **The root is the config's first `d` line**, with `%h` and `%U` expanded, so the guard cannot walk
  a different tree from the one being aged. Every line in the config must age a path inside it.
- **The walk** is `find -ignore_readdir_race`, with no depth limit. systemd-tmpfiles has none, and the
  old `-maxdepth 8` left a worktree four directories down a scratchpad unguarded. A scratchpad
  worktree's `.git` is at depth 6 (`claude-<uid>/<slug>/<session>/scratchpad/<wt>/.git`).
- **The walk skips a directory this user cannot read or cannot search.** systemd-tmpfiles cannot
  enter one either. It logs `Opening directory … failed, ignoring` and exits 0 (measured), so such a
  directory hides nothing that could be deleted. This laptop has one, a mode-000 `vol/data` under a
  `tmp.*` directory, and before this fix it made every run refuse.
- **Worktrees inside `node_modules` or a `.git` directory are not guarded.** The walk prunes both,
  because that is where its cost is and nothing puts a worktree checkout there. A row pins this as
  the limit it is.

### When it refuses

The script exits 2 and deletes nothing when the guard might be incomplete or wrong:

- **A worktree path an `x` line cannot express exactly.** That is whitespace or a control character
  (a newline included), `%` (a specifier), `*`, `?` or `[` (globs), a backslash, or a quote.
  tmpfiles.d unquotes, unescapes and expands each of these, so the line would protect a different
  path or none.
- **`find` exits non-zero.** `-ignore_readdir_race` makes an entry deleted mid-walk a non-error, and
  directories this user cannot enter are pruned, so what is left is a real error, such as `EIO`.
- **A `.git` file or back-pointer it cannot read**, or a git dir (or a directory above one) it
  cannot search.
- **The root is a symlink.** systemd-tmpfiles does not follow it: a clean deletes nothing and exits
  0 (measured), and the log would read as a clean run every night. A symlink *above* the root, such
  as `~/.cache`, is followed and is fine.
- **A config the root cannot be read from**: no `d` line, a quoted path, a specifier other than `%h`
  and `%U`, or a line aging a path outside the root.
- **No `XDG_RUNTIME_DIR`**, or no readable config.
- **`--dry-run` on systemd older than 256**, which has no `--dry-run`. Falling through would make a
  dry run real. The dev server runs 249.

A refusal fails the unit, and `check-timer-health.sh` reports a failed unit. That is deliberate:
a refusal that repeats every night has to be seen.

## Choices worth knowing about

- **Only this checkout's rules are applied.** The script passes the config and the guard to
  `systemd-tmpfiles --user --clean` by path. With no arguments it would also apply every other
  `user-tmpfiles.d` rule on the machine for the first time, unattended, as a side effect of this
  unit.
- **Exit 65 from systemd-tmpfiles is accepted** (logged, and echoed to the journal). It means a
  line could not be parsed. The guard's lines are checked for exactly that before they are written.
- **`./install` enables and starts the timer** (`scripts/tmpdir-clean.sh --install`, where the state
  table reaches it). For an unattended deleter this departs from the "linked, not enabled" pattern
  that `wt-gc-sweep` and `scrub-transcript-secrets` follow. This timer restores a cleanup the
  redirect took away rather than adding a new one, and the one thing under the root that is not
  disposable is guarded.
- **Priority.** `ionice` and `IOSchedulingClass=` do nothing on this laptop. Its NVMe scheduler is
  `none`, and the user manager delegates only `cpu memory pids`. What works is `Nice=19`,
  `CPUWeight=idle` and `MemoryHigh=512M`, which bounds the dentry and inode slab a large walk
  charges to the unit's memcg. `IOSchedulingClass=idle` stays for BFQ machines. `CPUWeight=idle`
  needs systemd 250+. Older managers log the line as unparseable and run the unit anyway.
- **05:15** is after the 04:00 `wt-gc-sweep` and its half-hour jitter.

## Why `./install` starts the timer, and why that does not run it

It first enabled the timer without `--now`, so the first and largest run would never be a side
effect of an install. The timer was then meant to start at the next boot or login. This laptop
lingers (`Linger=yes`), so its user manager outlives every logout, and "the next login" meant "the
next reboot". Until then `check-timer-health.sh` reported `enabled but ActiveState=inactive`, a
failure, every time it ran.

Starting a `Persistent=true` timer that has **no stamp file** does not fire it. That was checked
before relying on it, in the source and on this machine:

- **Source** (systemd v259, `src/core/timer.c`). `timer_start()` stats
  `~/.local/share/systemd/timers/stamp-<unit>`. On `ENOENT` it only creates one ("The timer has never
  run before, make sure a stamp file exists") and leaves `last_trigger` unset. `timer_enter_waiting()`
  then bases the calendar on `inactive_exit_timestamp`, the moment the timer started. So the next
  elapse is the next 05:15 after the start. Only a stamp file older than a missed elapse makes a
  start fire at once.
- **Probe** (2026-10-17 23:07, systemd 259.5, this laptop). Two throwaway transient timers ran
  `systemd-run --user --on-calendar='*-*-* 05:15:00' --timer-property=Persistent=true /bin/true`,
  18 hours after that day's 05:15. The one with no stamp file did not fire. `LastTriggerUSec` was
  empty, its service never got an `InvocationID`, `NextElapseUSecRealtime` was the next day's 05:15,
  and systemd wrote a stamp file dated the start. The control's stamp file was backdated two days,
  and it fired at start. Both were stopped and their stamp files removed.

So `enable --now` on a machine where the timer never ran waits for 05:15. On one where it ran
before and was stopped, a missed 05:15 runs at once, which is what `Persistent=true` is for.

## How it is tested

State table: `scripts/test-tmpdir-clean.sh` (66 checks, in CI as `tmpdir-clean-test`).

The aging rows run the **real** systemd-tmpfiles. What is pinned is the guard combined with the
semantics of the tool that reads it, and a stub would only restate what the script told it. HOME
and the XDG directories point into a mktemp tree, and the config and guard are passed by path. A
preflight proves `%h` resolves to the fake HOME, non-destructively, before any clean runs.

The config under test is derived from the shipped one by adding an `amAM:` age-by prefix (atime and
mtime only). btime and ctime cannot be backdated, so without it a fixture built now is never old.
The derivation is asserted to prefix every age field and change nothing else. Each age is pinned
from both sides: a day under it is kept, a day over it goes.

The rows that need an answer the real tools will not give on demand use stubs: a recording
systemd-tmpfiles for `--dry-run` on 255 and exit 65, a recording `systemctl` for `--check` and
`--install`, and a `find` that exits 1 for the one walk error left once `EACCES` is pruned.

**First mutation sweep: 36 mutants, 34 killed, the 2 expected survivors surviving.** Each mutant was
checked to apply exactly once before it ran. Each one was killed by a row naming the rule it
removed, including each encodability character class on its own. The first sweep found the
character-class row hollow. It ran on a tree still holding the previous row's `wt sp` worktree, so
every run refused for the wrong reason and every class mutant survived.

**Second sweep, after review: 37 mutants, 35 killed by the row named for them, 2 expected
survivors.** It covered each rule the review added: the depth limit (at 8 and at 2), each half of
the permission prune, `EACCES` at the git dir and at its parent, a first-line pointer read, no CR
strip, a `realpath`'d `x` line and a `realpath`'d walk, the symlinked root, a hard-coded root, each
config refusal, and each `--install` and opt-out branch. It also re-ran the first sweep's mutants on
code this round touched. The review had found two gaps the green suite hid. Every guard fixture
was a worktree at depth 1, so a `-maxdepth 2` mutant passed the whole suite. And `--check`'s two
skip rows shared the needle `skipped`. The survivors are `-ignore_readdir_race`, because a readdir race cannot
be produced on demand, and the `.git`-directory prune, which only saves cost: nothing inside a
`.git` directory is a file named `.git`.
