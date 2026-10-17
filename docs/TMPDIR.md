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
systemctl --user start tmpdir-clean.timer   # ./install enables it but does not start it
journalctl --user -u tmpdir-clean.service -e
cat ~/.local/state/tmpdir-clean/log   # one line per run
scripts/tmpdir-clean.sh --check       # what scripts/verify-tools.sh asserts
```

A log line reads `mode=apply guarded=3 rc=0 used=<bytes>-><bytes> inodes=<n>-><n> seconds=<s>`.
`used` and `inodes` are for the whole filesystem `~/.cache/tmp` is on, so other writers move them
too. Read them as a trend, not as what one run deleted.

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
- **The host is `$gitdir/commondir`.** A host inside the root is temp too, and its worktrees age out
  with it. A registered worktree whose `commondir` cannot be read is guarded, since it cannot be
  shown to be temp.
- **The walk** is `find -maxdepth 8 -ignore_readdir_race`, pruning `node_modules` and `.git`
  directories. A scratchpad worktree sits at depth 5.

### When it refuses

The script exits 2 and deletes nothing when the guard might be incomplete or wrong:

- **A worktree path an `x` line cannot express exactly.** That is whitespace or a control character,
  `%` (a specifier), `*`, `?` or `[` (globs), a backslash, or a quote. tmpfiles.d unquotes,
  unescapes and expands each of these, so the line would protect a different path or none.
- **`find` exits non-zero.** `-ignore_readdir_race` makes an entry deleted mid-walk a non-error, so
  what is left is real, usually `EACCES` on a directory this user cannot read.
- **A `.git` file or back-pointer it cannot read.**
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
- **`./install` enables the timer, without `--now`.** For an unattended deleter this departs from
  the "linked, not enabled" pattern that `wt-gc-sweep` and `scrub-transcript-secrets` follow. This
  timer restores a cleanup the redirect took away rather than adding a new one, and the one thing
  under the root that is not disposable is guarded. Without `--now` the timer starts at the next
  boot or login, so the first and largest run is never a side effect of an install. Until then
  `check-timer-health.sh` reports it as enabled but not active, which is accurate: it will not fire.
- **Priority.** `ionice` and `IOSchedulingClass=` do nothing on this laptop. Its NVMe scheduler is
  `none`, and the user manager delegates only `cpu memory pids`. What works is `Nice=19`,
  `CPUWeight=idle` and `MemoryHigh=512M`, which bounds the dentry and inode slab a large walk
  charges to the unit's memcg. `IOSchedulingClass=idle` stays for BFQ machines. `CPUWeight=idle`
  needs systemd 250+. Older managers log the line as unparseable and run the unit anyway.
- **05:15** is after the 04:00 `wt-gc-sweep` and its half-hour jitter.

## How it is tested

State table: `scripts/test-tmpdir-clean.sh` (43 checks, in CI as `tmpdir-clean-test`).

The aging rows run the **real** systemd-tmpfiles. What is pinned is the guard combined with the
semantics of the tool that reads it, and a stub would only restate what the script told it. HOME
and the XDG directories point into a mktemp tree, and the config and guard are passed by path. A
preflight proves `%h` resolves to the fake HOME, non-destructively, before any clean runs.

The config under test is derived from the shipped one by adding an `amAM:` age-by prefix (atime and
mtime only). btime and ctime cannot be backdated, so without it a fixture built now is never old.
The derivation is asserted to prefix every age field and change nothing else. Each age is pinned
from both sides: a day under it is kept, a day over it goes.

**Mutation sweep: 36 mutants, 34 killed, the 2 expected survivors surviving.** Each mutant was
checked to apply exactly once before it ran. Each one was killed by a row naming the rule it
removed, including each encodability character class on its own. The two survivors are
`-ignore_readdir_race` and the `node_modules` prune: a readdir race cannot be produced on demand,
and the prune changes how fast the walk is, not what it finds. The first sweep found the
character-class row hollow. It ran on a tree still holding the previous row's `wt sp` worktree, so
every run refused for the wrong reason and every class mutant survived.
