# Worktree sweep — the maintainer's record

**What this is for:** the evidence behind the one-line rule in `CLAUDE.md`, and why each
safety condition in `scripts/wt-gc-sweep.sh` and in `wt-gc`'s branch half is the shape it
is. If you are trying to *use* the sweep, the rule in `CLAUDE.md` and
`scripts/wt-gc-sweep.sh --help` are the whole interface.

DO-677. Design: `~/Projects/handoffs/2026-09-22-worktree-sweep-design.md`.

## The gap

A session spawned by `herdr-draft create --worktree` gets a worktree under
`~/.herdr/worktrees/<repo>/<slug>`, a local branch, and once it pushes a remote branch.
When its PR merges all three are left behind, and **the session cannot clean up after
itself** — removing its own worktree closes the herdr space it is running in. So the owner
was handed "remove this worktree" as a manual step every time, and it did not happen.

## What was measured, 2026-09-21

`wt-gc` with no flags, which is its documented read-only default:

| | |
|---|---|
| REAP machine-wide | 56 worktrees, ~3.3 GB |
| under `~/.herdr/worktrees` | 41 — 29 herdr-draft, 8 qspace-server, 2 nanoclaw, 2 .dotfiles |
| REVIEW (real work at risk) | 7 |
| Live sessions | every one correctly KEEP, as `in use by N process(es)` |

`wt-gc --apply` was run by hand on 2026-09-15 and removed 27 worktrees
(`~/Projects/handoffs/2026-09-15-wt-gc-reaped-branches.md`). **Six days later herdr-draft
alone was back to 29.** A manual sweep does not keep up.

Branch clutter is the larger half and had no tool at all:

| repo | local branches | on origin |
|---|---|---|
| herdr-draft | 70 | 27 |
| nanoclaw | 71 | 30 |
| .dotfiles | 22 | 10 |

Only ~24 of herdr-draft's 70 had a worktree. 14 of its 38 checkouts were on a detached
HEAD — the branch had already gone and the directory stayed.

## Two facts that forbid any path-based rule

- **7 of 38 worktree directories held a different branch than their name.**
  `zvi-fix-221-unset-session-upstream` was on `zvi/fix-230-popup-holds-warnings`. herdr
  names the directory from the branch slug *at create time* and never tracks a rename, so
  the path never identifies the work. Read the branch from git, never from the path.
- **`herdr worktree remove` is addressed only by `--workspace <ID>`.** 35 of 38
  herdr-draft worktrees had no open space, so herdr cannot remove them at all — it is
  `git worktree remove` or nothing. The "removing a worktree closes its space" constraint
  therefore binds only for the handful that are live, and those are exactly the ones
  `wt-gc`'s `/proc` cwd scan already refuses.

## Why a timer, and not any of the alternatives

Every other shape was tried or measured first:

- **pane-reaper** is enabled in the live herdr server
  (`local:/home/zvi/.dotfiles/config/herdr/plugins/local/pane-reaper`) and **has never
  fired** — no `~/.local/state/pane-reaper/log`, no slot files. Its precondition is the
  agent marking its own pane, and herdr-draft **#266** records that the precondition "is
  unknowable, so an agent will never pass it unprompted". Its own design doc
  (`~/Projects/handoffs/2026-09-17-pane-reaper-design.md`) puts worktrees explicitly out
  of scope: *"the worktree directory and branch stay on disk."*
- **herdr-draft keeps no registry.** `recents.json`, `last-used.json` and `projects.json`
  are preferences keyed by repo root — no branch, no path, no workspace id. Its
  `plan.CleanCheck`/`Clean` safety code needs `ExecResult.CreatedBranch` and `BaseCommit`,
  neither of which survives the process, so a later sweeper cannot reuse it.
- **The hspawn registry is empty.** hspawn is not in use; herdr-draft is the only spawner
  now. `wt-gc`'s HSPAWN carve-out is inert but stays, unchanged, and still defers to
  `hdespawn`.
- **A per-session convention** was measured not to work on 2026-09-17: the four `done`
  agents found that day belonged to four different parents, and the author of that note
  had twice failed to arm a watch they had promised to arm, in one session, an hour apart.
- **A machine-wide Claude `Stop` hook** was added and reverted the same day, because
  `~/.claude/settings.local.json` is symlinked from every account dir and the hook ran on
  every turn end in ~13 live sessions. The two rules that came out of it — *scope before
  durability*, *make the default path cheap* — are why the policy here is a systemd unit
  with a `ConditionPathExists` and no network call outside the run itself.

## Why the blast radius is what it is

- **`--scope ~/.herdr/worktrees`.** Of the 56 REAP worktrees, 41 were agent-made; the rest
  is other tools' territory, including 7 under `~/.local/state/rabota-impl` belonging to a
  live epic that a prior handoff names as do-not-touch. `wt-gc --apply` by hand still
  covers everything, with a human reading the list first. The report stays machine-wide
  and an out-of-scope REAP is reported `SKIPPED`, because a sweep that silently does less
  than its own report promised is the one nobody notices has stopped working.
- **`--scope` governs worktree paths only.** A branch has no path, so a scoped run still
  deletes every dangling branch its own predicate allows, in any repository. That is
  deliberate and the dry-run footer says so; if it ever needs narrowing, the narrowing
  belongs in the predicate, not in a path prefix that cannot express it.
- **`--min-age 2`, counted from the merge.** A PR that merged in the last two days keeps
  its checkout, so a merge nobody has looked at yet survives. The grace is read off
  `mergedAt`, not the last commit — `wt-gc`'s `age` column is days since HEAD's commit,
  which says nothing about when the PR merged. A branch name reused across two merged PRs
  is held back by the **newest** merge. A date that will not parse reads as *unknown* and
  falls back to the commit age; read as the epoch it would say 1970 and sweep at once.

## The branch predicate, and the claim it supports

A local branch is deleted only when all of these hold:

- its repository has a GitHub remote, and `gh` **answered** (a `?` never deletes);
- no PR under that branch name is OPEN, and at least one is MERGED or CLOSED;
- every commit is on a remote ref, **or** its tip is (an ancestor of) a MERGED PR's head
  commit — the same `landed_in_merged_pr` predicate a worktree is judged by, which exists
  because a squash merge followed by deleting the remote branch leaves the commits on no
  remote at all while the work is on main;
- no worktree has it checked out, and it is neither a host's own HEAD nor the default
  branch `origin/HEAD` names;
- at delete time its tip is still where it was when it was judged.

**The claim that this loses nothing is exactly that predicate and nothing broader:** every
commit the branch holds is on a remote or inside a merged PR, so the commits outlive the
ref. The old framing — *"branches are never deleted, so the checkout comes back with
`git worktree add`"* — stops being true, and is replaced by this, not by a weaker version
of it. **Remote branches are never touched, by any flag.** `gh pr merge --delete-branch`
owns those, and only 7 of 37 worktree branches still had one.

The branch pass runs **only** under `--branches`, because it costs one `gh pr list` per
candidate. A row asserts the cost and not merely the output: the test's `gh` stub logs its
calls, and a plain run must ask about no branch that has no worktree.

## `wt-gc` exits 1 for a warning and for a failure alike

That is why `scripts/wt-gc-sweep.sh` derives its own status from what the run *reported*
rather than passing the engine's through:

| wt-gc | wrapper | why |
|---|---|---|
| 0 | 0 | |
| 1, a `FAILED` row | 1 | something could not be removed; that is real |
| 1, no `FAILED` row | 0 | warnings only — echoed to the journal, not an alarm |
| 2 | 1 | a usage error is the wrapper's bug, not a warning |
| other | 1 | |

Warnings here are routine — a repository whose `git worktree list` failed, an unreadable
hspawn registry entry — and mapping them to a failed unit would make the unit red most
nights, which is how a red unit stops being read. They are still echoed, because a
repository that could not be listed is one the run did not cover, and a sweep that
silently covers less every week is the failure mode this page exists to prevent.

Every run appends a line to `~/.local/state/wt-gc-sweep/log` and leaves the full TSV in
`last-run.tsv`. An unattended deleter nobody can audit afterwards is one nobody should run.

## Tests and the mutation sweep

- `~/.dotfiles-local/scripts/test-wt-gc.sh` — 51 → **100 rows**, real repositories
  throughout, and it asserts its own row total. Thirteen mutants, **thirteen killed**, each
  by a row that names the guard it removed.
- `scripts/test-wt-gc-sweep.sh` — **21 rows**, hermetic via a recording `wt-gc` stub at the
  front of `PATH`. Five mutants, five killed. CI job `wt-gc-sweep-test`.

One more refinement came out of reading the delete path again: a branch someone checked
out between the scan and the delete is a **race**, not a failure. git refuses, nothing is
lost, and there is nothing to fix — but `FAILED` is what makes the wrapper exit non-zero,
so a benign race would have put a red light on the nightly unit. It is `SKIPPED` now. Both
of git's spellings are matched (2.53 says *"used by worktree at"*, older versions *"checked
out at"*), which the new row caught because it was written against the wrong one first.

Three guards survived the first sweep, and the reason each survived is worth keeping:

- **the OPEN guard on a dangling branch** — the fixture's both-PR branch held a commit on
  no remote, so the MERGED-or-CLOSED clause below it refused the branch anyway. A row that
  fails for a second reason pins nothing.
- **the trunk guard** — every fixture host had its trunk checked out, so the checked-out
  exclusion already covered it. It needed a host sitting on a feature branch, with `main`
  carrying a merged PR: every condition for deletion except being the trunk.
- **the `PR_MERGED_AT` reset** — whether a detached row inherits a stale merge time
  depended on which worktree `git worktree list` returned first, which is in no defined
  order. Hosts *are* discovered by a sorted glob, so the detached worktree moved to a
  second host and what would leak became fixed rather than incidental.

## Adjacent defect fixed here

`rabota census`'s `worktrees()` parsed `wt-gc --tsv` as `path repo branch verdict reason`.
The real schema is `verdict path branch pr dirty unpushed age reason`, eight fields, with
**no header line** — so every row recorded the verdict as the path and the path as the
repo. Its fixture encoded the same wrong schema, which is why the tests passed the whole
time. Rows are now selected by their leading token, never by position or column count,
because the stream carries three row types (`STRAY` has two fields, `DANGLING` five) and a
positional reader mislabels everything the day a fourth appears.

Note that `rabota precompute` passes `include_worktrees=False`, so the every-30-minutes
timer never called `wt-gc` at all; the mis-parse was reached only by an on-demand
`rabota census`.

## Arming it

Linked by `./install`, **never enabled** — the same rule this repo already applies to
`herdr-server.service` and `rabota-precompute@`, and `reconcile-systemd-units.sh` treats
"declares targets, nobody enabled it" as a decision rather than drift.

```bash
scripts/wt-gc-sweep.sh --dry-run          # read this first, in full
systemctl --user daemon-reload
systemctl --user enable --now wt-gc-sweep.timer
```

Never `systemctl --user reenable` — its disable half deletes the dotbot symlink that *is*
the unit.
