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
`mode=apply guarded=3 chmod=12 rc=0 failed=0 used=<bytes>-><bytes> inodes=<n>-><n> seconds=<s>`.
`chmod` is how many [non-writable directories](#non-writable-directories) were given `u+w` (in a dry
run, how many would be, each printed as `would restore u+w on <path>`). `failed` is how many paths
systemd-tmpfiles [could not remove or open](#what-systemd-tmpfiles-cannot-remove) (`?` if they could
not be counted). Each run with some prints a warning and the first five, and `--check` warns when
three real runs in a row left some. `used` and `inodes` are for the whole filesystem `~/.cache/tmp`
is on, so other writers move them too. Read them as a trend, not as what one run deleted.

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
uppercase for directories. An age-by with no uppercase letter leaves directories on the default
`ABM`. The field arrived in systemd 249 (`NEWS`; the dev server runs 249). An older systemd-tmpfiles
fails to parse every line that has one and exits 65, which would make every night a clean that does
nothing, logged as a success, so `tmpdir-clean.sh` refuses there instead. The tool also skips a path
someone holds a BSD lock on, and live unix sockets.

**Directory atime is not counted, because any walk over the root refreshes it.** The default
age-by is `abcmABM`. With it, no directory under the root ever aged out: the worktree guard's `find`
reads every directory before each clean, and on a `relatime` mount reading a directory whose atime
is more than a day old updates it. systemd-tmpfiles leaves ctime out for directories by default for
the same reason, since deleting an entry changes it. Leaving atime out costs little. A directory
holding a file that survives cannot be removed anyway, and `stat()` does not update atime. What does
lose protection is an empty directory that is read but never written, such as a spool a program
polls: atime kept it while it was polled, and now it goes once its btime and mtime are old. The
review of 2026-10-18 found none live. Measured:

- **2026-10-18, after the first real run.** Of the top-level directories left in `~/.cache/tmp`,
  234,175 had an mtime older than 7 days and an atime of 2026-10-17 09:52, for example
  `clr-rule-scope-vIxbz0` (mtime 08-20). Their files had gone (`find` only stats files), and the
  empty directory trees stayed. Those atimes were not set by that run's own guard walk. They came
  from an earlier walk over the root, about 15 hours before the first guarded run (01:18), and
  `relatime` does not refresh an atime less than a day old. The mechanism is the same either way.
- **The cause, on systemd 259 in a fake HOME.** systemd-tmpfiles alone removed an old empty
  directory and an old directory holding an old file. When a `find` walk ran over them first, it
  removed neither, because the walk had made both atimes new. systemd-tmpfiles itself opens
  directories `O_NOATIME`. After it unlinks a file in one (removing a subdirectory does not count),
  it restores that directory's own atime and mtime (v259 `src/tmpfiles/tmpfiles.c`,
  `dir_cleanup()`).

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
  enter one either, so such a directory hides nothing that could be deleted. It logs
  `Opening directory … failed, ignoring` and goes on. Under the root's `d` line it then exits 0;
  under `claude-<uid>/`'s `e` line it exits 73, which this script reports as a
  [warning](#what-systemd-tmpfiles-cannot-remove). This laptop has one, a mode-000 `vol/data` under
  a `tmp.*` directory, and until the walk pruned it, it made every run refuse.
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
- **An age-by on systemd older than 249**, where every line with one fails to parse and the clean
  does nothing.
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
What [still fails](#what-systemd-tmpfiles-cannot-remove) after the pass below is now a warning.

**So once the guard is written, `tmpdir-clean.sh` runs `chmod u+w` on every directory under the
root that:**

- this user owns and has no user write bit on,
- is old by the line that governs it, the deepest config line whose path is above it. That line's
  age and directory letters are read from the config, so btime and mtime with the shipped
  `abcmBM`, at 7 days under the root and 14 under `claude-<uid>/`,
- and is not inside a guarded worktree.

A timestamp that is not a number keeps the directory as it is, and so does a line with no age. The
walk is `find -P -xdev`, so it never follows a symlink and never leaves the root's device. That is
not systemd-tmpfiles' own mount check. It skips any mount root (`STATX_ATTR_MOUNT_ROOT`), so also a
bind mount of the same filesystem, which shares `st_dev` and which `-xdev` enters. Making one needs
root, and none is mounted under the root here. Like the guard's walk, it prunes directories this
user cannot read or search, since systemd-tmpfiles cannot enter them. It never gives them `u+rx`,
because the guard's walk did not look inside them, and a worktree there would reach systemd-tmpfiles
unguarded. Unlike that walk, it does look inside `node_modules` and `.git`.

**Names and atime, mtime and ctime come from `find -printf`, byte for byte. btime comes from
`stat`, joined on the inode.** Two measurements on this laptop decide that split. `/usr/bin/stat` is
uutils 0.8.0, which prints a non-UTF-8 name lossily (`\xff` becomes U+FFFD), so the old
`stat --printf '… %n'` pass sent `chmod` to a path that does not exist. And GNU find 4.10 reads no
btime at all: it uses `fstatat`, not `statx`, and prints `%B@` as `-1.-000000010` on a filesystem
that records one. Read as 0, that would ignore `B` everywhere. So `stat` is asked for `%i %W` only,
and no name is read back from it. A directory gone since the walk is passed over without a word.

- **It resets no one's age.** `chmod` on a directory changes only its ctime, and ctime is not
  counted for directories, neither in `abcmBM` nor in the default. Files are not touched.
- **After the guard, never before.** A refusal therefore leaves every mode as it was.
- **`--dry-run` changes nothing.** It prints each directory it would change.
- **Just before each `chmod`, the path must still resolve to exactly itself under the root.**
  `chmod` follows symlinks. A directory swapped since the walk for a symlink, at the last component
  or at any one above it, would otherwise send `chmod u+w` outside the root (measured: an
  intermediate swap did, with only the last component rechecked) or into a guarded worktree. So
  `realpath -e` of the path must equal the real root plus the path below it, or the directory is
  left as it is, with a warning. This narrows the race. A shell cannot close it.
- **A failure is a warning, not a refusal.** That covers a failing walk, a failing `stat` (a
  directory whose line counts `B` and has no btime is left as it is), or a `chmod` that fails. All
  it can leave behind is a directory that is still not writable, and the removal that then fails is
  counted in `failed=`.
- **A read-only tree in use loses its protection.** Take a Go module cache under `$TMPDIR` that is
  still in use and whose directories have not changed in 7 days. It is made owner-writable, and from
  then on it ages out file by file like everything else under the root. Go verifies a module's hash
  when it downloads it, and on `go mod verify`, not on every build. A module directory that has
  partly aged out fails at compile time, and the remedy is `go clean -modcache`. The rule this page
  backs already says such a tree does not belong here.
- **A non-writable directory younger than its line**, holding something old, still fails that
  removal until the directory ages too. With btime counted this needs a directory that was writable
  inside the window. It is counted in `failed=`.

### What systemd-tmpfiles cannot remove

systemd-tmpfiles logs each path it could not remove (`Failed to remove …`) or enter
(`Opening directory … failed`), and goes on. Under the root's `d` line it then exits 0. Under
`claude-<uid>/`'s `e` line it exits 73, so the unit could still go red every night after the pass
above. Measured on systemd 259 in a fake HOME (exit 73 on two runs each): a fresh mode-000
directory under `claude-<uid>/…/scratchpad/`; the same, 20 days old and non-empty, which the pass
prunes; and a 3-day-old 555 directory holding an old 555 one, whose child is emptied but cannot
itself be removed until the parent ages.

So `tmpdir-clean.sh` copies systemd-tmpfiles' stderr to `~/.local/state/tmpdir-clean/tmpfiles.err`
on its way to the journal, and counts those two kinds of line into the log's `failed=`. A run with
any prints a warning and the first five. Exit 73 with at least one counted is that warning, and the
run exits 0. Exit 73 with none counted is unexplained, and a failure, as is every status but 0, 65
and that 73.

`tmpdir-clean.sh --check`, and so `verify-tools.sh`, warns, and never fails, when the last three
real runs each logged `failed=` above 0. A dry run does not count. Some such paths go by
themselves (an old directory in a young non-writable one goes once its parent ages), but a mode-000
directory never does: it is never given `u+rx` (above), so it stays until removed by hand.
`check-timer-health.sh` reads only the unit's state, which is now a success, so it does not say
so.

## Choices worth knowing about

- **Only this checkout's rules are applied.** The script passes the config and the guard to
  `systemd-tmpfiles --user --clean` by path. With no arguments it would also apply every other
  `user-tmpfiles.d` rule on the machine for the first time, unattended, as a side effect of this
  unit.
- **Exit 65 from systemd-tmpfiles is accepted** (logged, and echoed to the journal). It means a
  line could not be parsed. The guard's lines are checked for exactly that before they are written,
  and an age-by on systemd < 249, which would make every line fail, is a refusal.
- **Exit 73 is accepted when it is explained**, by at least one path counted in `failed=`
  ([above](#what-systemd-tmpfiles-cannot-remove)).
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

State table: `scripts/test-tmpdir-clean.sh` (101 checks, in CI as `tmpdir-clean-test`).

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
systemd-tmpfiles for systemd 248 and 255 and for exits 65 and 73, a recording `systemctl` for
`--check` and `--install`, and a `find` that exits 1 for the one walk error left once `EACCES` is
pruned. The non-writable pass adds a `find` that fails only that walk, a `stat` that fails, one
that answers a btime that is not a number, one that swaps a path for a symlink (or removes it) once
it has answered, and an `id` that names another user. The non-UTF-8 row only bites where `stat`
prints names lossily (uutils, this laptop); on GNU `stat`, as in CI, it passes either way.

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
`chmod`). That last claim was wrong, and so was the recheck: a `stat` stub that swaps the path once
it has answered kills the no-recheck mutant, and swapping a component above it sent `chmod u+w`
outside the root on that code.

**Fourth sweep, after review (DO-826): 33 mutants, 33 killed by the row named for them.** Each was
checked to apply exactly once, in a temp copy, and the new suite fails 20 rows against the code
before this round. Killed: exit 73 treated as a failure; a 73 accepted with nothing counted;
`failed=` not logged; the warning only on a non-zero exit; no echo of the paths; only
`Failed to remove` counted; `--check` not warning, counting a dry run, reading only the last run,
or counting runs that were not in a row; no `ABM` default for an age-by with no directory letter;
no recheck, the old last-component recheck, and a recheck that only asks "under the root"; no skip
for a directory gone since the walk; no `-uid` (an `id` stub); no 249 check, 248 for 249, the
check made regardless of the config, and the 256 check gone; names read back from `stat`; btime
from `find` (it reads none here); a missing btime read as 0; a btime that is not a number read as
old. That is 24. The third sweep's mutants on the rewritten pass were re-expressed and re-run, 9
more: atime counted, no age check, no worktree prune, `find -L`, no unreadable prune, writable
directories included, a dry run that chmods, and `A` or `M` ignored. `find -L` survived at first,
because the new recheck refuses what it reaches, so its row now also asserts that the symlinked
tree is never looked at. The survivors that remain cannot be produced without root or on demand:
`-xdev` (a second filesystem) and the guard walk's `-ignore_readdir_race`.
