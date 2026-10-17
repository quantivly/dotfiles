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

A log line reads
`mode=apply guarded=3 chmod=12 rc=0 used=<bytes>-><bytes> inodes=<n>-><n> seconds=<s>`. `chmod` is
how many [non-writable directories](#non-writable-directories) were given `u+w` (in a dry run, how
many would be, each printed as `would restore u+w on <path>`). `used` and `inodes` are for the whole
filesystem `~/.cache/tmp` is on, so other writers move them too. Read them as a trend, not as what
one run deleted.

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

**A file is deleted only when its atime, btime, ctime and mtime are all older than the age**
(`man tmpfiles.d`, "Age"). `/` is mounted `relatime` here, so a file read inside the window
survives. A file created inside the window survives too, whatever its mtime says, because btime is
counted. **A directory is deleted when its btime and mtime are, once it is empty.** Each age carries
the age-by prefix `abcmBM:` that says so: lowercase letters are the timestamps counted for files,
uppercase for directories (systemd 248+; the dev server runs 249). The tool also skips a path someone
holds a BSD lock on, and live unix sockets.

**Directory atime is not counted, because the cleanup itself refreshes it.** The default age-by is
`abcmABM`. With it, no directory under the root ever aged out: the worktree guard's `find` reads
every directory before each clean, and on a `relatime` mount reading a directory whose atime is more
than a day old updates it. systemd-tmpfiles leaves ctime out for directories by default for the
same reason, since deleting an entry changes it. Atime protects nothing here. A directory holding a
file that survives cannot be removed anyway, and `stat()` does not update atime. Measured:

- **2026-10-18, after the first real run.** Of the top-level directories left in `~/.cache/tmp`,
  234,175 had an mtime older than 7 days and an atime of 2026-10-17 09:52, for example
  `clr-rule-scope-vIxbz0` (mtime 08-20). Their files had gone (`find` only stats files), and the
  empty directory trees stayed.
- **The cause, on systemd 259 in a fake HOME.** systemd-tmpfiles alone removed an old empty
  directory and an old directory holding an old file. When a `find` walk ran over them first, it
  removed neither, because the walk had made both atimes new. systemd-tmpfiles itself opens
  directories `O_NOATIME`, and after deleting in one it restores that directory's own atime and
  mtime (v259 `src/tmpfiles/tmpfiles.c`, `dir_cleanup()`).

On a filesystem that does not record btime, statx reports none. v259 then reads btime as 0, which
is older than any cutoff, so a directory there is judged by mtime alone. The non-writable pass
below reads it the same way.

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
  and `%U`, a line aging a path outside the root, or an age the
  [non-writable pass](#non-writable-directories) cannot read. That pass reads one number and one unit
  up to weeks, after an optional age-by. `1d12h` is valid to systemd-tmpfiles and refused here.
- **No `XDG_RUNTIME_DIR`**, or no readable config.
- **`--dry-run` on systemd older than 256**, which has no `--dry-run`. Falling through would make a
  dry run real. The dev server runs 249.

A refusal fails the unit, and `check-timer-health.sh` reports a failed unit. That is deliberate:
a refusal that repeats every night has to be seen.

## Non-writable directories

Removing an entry needs write permission on the directory it is in. A file's own mode does not
matter. So an old file in a directory with no write bit can never be aged out. Neither can an old
directory inside one, even a non-empty one, because `rmdir` checks permission before emptiness. Go
makes its module cache mode 555, and tests and builds put throwaway GOPATHs under `$TMPDIR`.

**Measured on the first real run** (2026-10-18 01:18, systemd 259). It freed about 159G (used
452,366,831,616 → 293,514,301,440 bytes, inodes 15,316,902 → 8,679,488, 325 s). It then exited
`rc=73` and the unit FAILED. All 55,283 `Failed to remove … Permission denied` lines were files in
directories this user owns with no write bit. Most were Go module caches
(`go/pkg/mod/golang.org/x/term@v0.43.0/…`) under GOPATHs at the top level and under
`claude-<uid>/…/scratchpad/{fh2.*,fakehome.*,tui/home}/go`. A few were 500 and 555 test fixtures
(`state/ro`, `orch-lock-*`, `imp2628-*/home/…/sub`). Nothing would ever have changed that, so the
timer would have been red every night.

**Exit 73 comes only from the `e` line.** For a `d` line, v259's `clean_item()` drops the result of
the clean, so a removal that fails there is logged and the run still exits 0. Measured here: a 555
directory holding an old file exits 0 under the root's `d` line, and 73 under `claude-<uid>/`'s `e`
line. The top-level failures were silent leftovers, and the scratchpad ones turned the unit red.

**So once the guard is written, `tmpdir-clean.sh` runs `chmod u+w` on every directory under the
root that:**

- this user owns and has no user write bit on,
- is old by the line that governs it, the deepest config line whose path is above it. That line's
  age and directory letters are read from the config, so btime and mtime with the shipped
  `abcmBM`, at 7 days under the root and 14 under `claude-<uid>/`,
- and is not inside a guarded worktree.

A timestamp that is not a number keeps the directory as it is, and so does a line with no age. The
walk is `find -P -xdev`. It never follows a symlink, and it never leaves the root's filesystem,
which systemd-tmpfiles does not do either. Like the guard's walk, it prunes directories this user
cannot read or search, since systemd-tmpfiles cannot enter them. Unlike that walk, it does look
inside `node_modules` and `.git`.

- **It resets no one's age.** `chmod` on a directory changes only its ctime, and ctime is not
  counted for directories, neither in `abcmBM` nor in the default. Files are not touched.
- **After the guard, never before.** A refusal therefore leaves every mode as it was.
- **`--dry-run` changes nothing.** It prints each directory it would change.
- **A failure is a warning, not a refusal.** That covers a failing walk, a failing `stat`, or a
  `chmod` that fails. All it can leave behind is a directory that is still not writable, and
  systemd-tmpfiles reports the removal that then fails.
- **A read-only tree in use loses its protection.** Take a Go module cache under `$TMPDIR` that is
  still in use and whose directories have not changed in 7 days. It is made owner-writable, and from
  then on it ages out file by file like everything else under the root. Go checks module content by
  hash, not by mode. The rule this page backs already says such a tree does not belong here.
- **A non-writable directory younger than its line**, holding something old, still fails that
  removal until the directory ages too. With btime counted this needs a directory that was writable
  inside the window.

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

State table: `scripts/test-tmpdir-clean.sh` (83 checks, in CI as `tmpdir-clean-test`).

The aging rows run the **real** systemd-tmpfiles. What is pinned is the guard combined with the
semantics of the tool that reads it, and a stub would only restate what the script told it. HOME
and the XDG directories point into a mktemp tree, and the config and guard are passed by path. A
preflight proves `%h` resolves to the fake HOME, non-destructively, before any clean runs.

The config under test is derived from the shipped one by taking `b`, `B`, `c` and `C` out of each
age-by, so the shipped `abcmBM` becomes `amM`. btime cannot be backdated, and `touch` sets ctime to
now, so with them a fixture built now is never old. The derivation is asserted to change the age-by
letters and nothing else. Each age is pinned from both sides: a day under it is kept, a day over it
goes.

The rows that need an answer the real tools will not give on demand use stubs: a recording
systemd-tmpfiles for `--dry-run` on 255 and exit 65, a recording `systemctl` for `--check` and
`--install`, and a `find` that exits 1 for the one walk error left once `EACCES` is pruned. The
non-writable pass adds a `find` that fails only that walk, a `stat` that fails, and a `stat` that
answers with timestamps that are not numbers.

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

**Third sweep, for the non-writable pass and the directory age-by (DO-826): 23 mutants, 20 killed
by the row named for them, 3 expected survivors.** Each mutant was checked to apply exactly once,
in a temp copy. Killed: no pre-pass; the pre-pass counting directory atime; the `chmod` not counted
in the log; no age check; guarded worktrees not pruned; the shallowest line governing instead of the
deepest; a dry run that chmods; `find -L`; the pre-pass moved ahead of the guard; the config putting
`A` back in the directory letters; `A` or `B` ignored when the config names them; a failing walk
refusing; unreadable directories not pruned; a failing `stat` ignored; writable directories
included; an unreadable age accepted; a line with no age read as age 0; days counted as hours; and a
timestamp that is not a number read as old. The survivors cannot be produced without root or on
demand: `-uid` (a directory owned by another user), `-xdev` (a second filesystem), and the recheck
for a symlink just before `chmod` (a directory swapped for a symlink between the walk and the
`chmod`).
