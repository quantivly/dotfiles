# Timer health — the maintainer's record

*What `scripts/check-timer-health.sh` asserts, what was measured before it was written, and why
each rule is shaped the way it is. The operative rules live in [CLAUDE.md](../CLAUDE.md); the
evidence lives here.*

## The gap, measured 2026-09-22

Four repo-owned systemd **user** units run on timers on this machine. Nothing asserted that any of
them had ever run, or succeeded.

| what looked at failed units | scope |
|---|---|
| `scripts/verify-tools.sh` | unit **enablement** drift only, via `reconcile-systemd-units.sh --check` |
| `backup-doctor` (`zsh/functions/system.sh`) | `systemctl list-units --state=failed '*restic*'` — restic only, and the **system** manager |

```
$ grep -rln 'state=failed\|--failed\|is-failed' ~/.dotfiles/scripts/ ~/.dotfiles/zsh/
/home/zvi/.dotfiles/zsh/functions/system.sh
```

One file, one hit, and that hit is the restic-scoped line above. So a failed `claude-cred-reconcile`,
`rabota-precompute@` or `wt-gc-sweep` sat failed indefinitely, visible only to someone who happened
to type `systemctl --user --state=failed`.

That became urgent the same day. `wt-gc-sweep.timer` was armed (DO-677, `quantivly/dotfiles#201`);
it **deletes worktrees and local branches unattended**, nightly at 04:00. Its wrapper was built so
that only a real `FAILED` row exits non-zero, precisely so warnings do not cry wolf — a deliberately
loud failure, armed into a system with nothing listening.
[WORKTREE_SWEEP.md](WORKTREE_SWEEP.md) names *"a sweep that silently covers less every week"* as its
own failure mode.

The backup system had already solved this shape with healthchecks pings plus a doctor assertion. The
timers never got the same treatment.

## The three questions

Each can be false while the other two look fine, which is why all three are asked separately.

1. **Enabled.** Already answered by `reconcile-systemd-units.sh --check`. Not duplicated. A unit that
   is *linked but not enabled* is a **decision**, not drift — `wt-gc-sweep` ships that way on purpose
   — so it is reported as "not checked" and never as a pass.
2. **Succeeded.** `LoadState`, `ActiveState`, `Result`, `ExecMainStatus` of the last run.
3. **Still running.** The timer is firing at all, on its own schedule.

(3) is the one worth the most. An unmet `ConditionPathExists` makes systemd **skip** the unit, and a
skipped unit is not a failed one: no error, nothing in `--state=failed`, and `Result` stays
`success`. `wt-gc-sweep.service` carries exactly such a condition
(`ConditionPathExists=%h/.local/bin/wt-gc`, and `wt-gc` lives in the private `~/.dotfiles-local`),
so this is not hypothetical.

## What was measured first

All probed on this box on 2026-09-22, systemd 259 (259.5-0ubuntu3.4). Every one of these is a way for
the checker to report health it did not measure, and every one is a row in
`scripts/test-timer-health.sh`.

### A unit systemd cannot find answers `success` to everything

```
$ systemctl --user show nonexistent-xyz.service -p Result -p ConditionResult -p LoadState
LoadState=not-found
ConditionResult=no
Result=success
$ echo $?
0
```

Exit 0. `Result=success`. A unit renamed away in the checkout, or a typo in the checker's own unit
list, reads as **healthy** *and* — via `ConditionResult=no` — as **skipped**. So `LoadState` is
tested first and on its own, and `not-found` is a FAIL. Mutant **M1** (drop that gate) is killed by
two rows.

### `ConditionResult=no` is also the value on a unit that never started

The same `no` appears on a perfectly healthy, freshly enabled unit that systemd has not yet reached.
The discriminator is `ConditionTimestamp`: empty means "never evaluated". Skip-detection gated on
`ConditionResult` alone false-fails every timer on the day it is armed. Mutant **M2**.

### A bare template cannot be queried at all

```
$ systemctl --user show 'rabota-precompute@.timer' -p LoadState
Failed to get properties: Unit name rabota-precompute@.timer is neither a valid invocation ID
nor unit name.
```

dotbot links the bare template (`install.conf.yaml` links `rabota-precompute@.service` and
`rabota-precompute@.timer`), so `--list-managed` returns it. Only the **instance**,
`rabota-precompute@quantivly.timer`, is a real unit. Bare templates are dropped before anything is
asked. Mutant **M6**.

### Next-elapse is unparseable for half the timers

```
$ systemctl --user show claude-cred-reconcile.timer -p NextElapseUSecRealtime -p NextElapseUSecMonotonic
NextElapseUSecRealtime=
NextElapseUSecMonotonic=4h 48min 45.233680s
```

A monotonic timer (`OnUnitActiveSec=2min`) has an **empty** realtime field, and the monotonic one is
a pretty-printed *duration* with no raw companion — unlike `LastTriggerUSecMonotonic`, which is raw
microseconds. `--timestamp=unix` normalises `LastTriggerUSec` and the `*Timestamp` fields to
`@<epoch>` but does nothing for this one.

### `list-timers -o json` answers all of it

```
$ systemctl --user list-timers --all -o json
[{"next":1790079620243244,"last":1790079500242354,"unit":"claude-cred-reconcile.timer",
  "activates":"claude-cred-reconcile.service"},
 {"next":1790125885373701,"last":0,"unit":"wt-gc-sweep.timer",
  "activates":"wt-gc-sweep.service"}, ...]
```

Epoch **microseconds** for both, `last: 0` meaning never fired, and `activates` naming the service
authoritatively so no `Unit=` parsing is needed. It lists only real template **instances**. This is
the source of truth in the checker. (`--json=short` is rejected by this systemctl; `-o json` is the
spelling that works.)

It lists only **loaded** timers, so a managed timer that is enabled and absent from the list is a
real fault rather than an absence. Mutant **M7**.

### "Never fired" is not "stale"

`wt-gc-sweep.timer` on the day it was armed:

```
ActiveState=active
ActiveEnterTimestamp=@1790076756      # 14:32 today
NextElapseUSecRealtime=@1790125885    # 04:11 tomorrow
LastTriggerUSec=                      # empty — has never fired
```

A freshness rule anchored on last-trigger alone reads this as 1970 and fails a timer that is
perfectly healthy and simply new. Mutant **M5**.

## Freshness is derived, never tabulated

```
anchor = last, or the timer's ActiveEnterTimestamp when it has never fired
stale  = now > next + (next - anchor)
```

One full projected cycle past the next scheduled run. For a 2-minute timer that fired at *T* that is
`now > T + 4min`; for `wt-gc-sweep`, armed 14:32 with its first run due 04:11 the next morning, it is
about 17:50 the day after. After the first fire the cycle re-derives to ~24 h and the limit becomes
two days.

The alternative considered and rejected was a per-unit table of expected periods, as `backup-doctor`
uses for snapshot age (26 h / 3 h). It is a second copy of every unit file's schedule, and the copy
drifts. Deriving it is the same argument `reconcile-systemd-units.sh` makes for deriving its unit
list instead of hardcoding one — and that file records what happened when it *was* hardcoded.

The comparison is `>`, not `>=`: exactly at the limit is not yet stale. Mutant **M4** flips it and is
killed by a boundary row.

### The horizon check is not redundant with staleness

A mis-specified `OnCalendar` resolves to a next elapse years out. The timer is `active`, nothing has
failed, and the derived cycle is then *as wide as the mistake* — so `now > next + cycle` can never
fire again. The staleness rule cannot catch its own worst input. A next run further away than
`TIMER_HEALTH_MAX_HORIZON_DAYS` (14; the longest repo-owned user timer is daily) is therefore its own
failure. Mutant **M3**, and the row for it also asserts that the same fixture produces **no** `STALE`
line — i.e. that the two checks really are independent.

## Scope: repo-owned user units only

Derived from `reconcile-systemd-units.sh --list-managed` — symlinks in the systemd user dir resolving
inside the checkout — rather than re-derived, because two definitions of "ours" drift and only that
one knows about the physical-path trap in its `DOTFILES_DIR` (`~/.dotfiles -> ~/src/dotfiles` makes a
logical `pwd` comparison fail forever).

This machine also runs `nanoclaw-*`, `ubuntu-insights-*` and `snap.firmware-updater.*` user timers.
This repo has no standing to call those broken, and a checker that is red about a unit it cannot fix
is the permanently-red checker this repo's records warn about three times
([CLAUDE_ACCOUNTS.md](CLAUDE_ACCOUNTS.md), [GH_ACCOUNT_ROUTING.md](GH_ACCOUNT_ROUTING.md), and
`verify-tools.sh`'s own `--herdr` rationale). The restic units are **system**-manager units and
belong to `backup-doctor`.

`herdr-server.service` is managed but has no timer. There is no freshness question for a
`Type=simple` daemon, so it is asked only whether it is up; its environment and `ExecStart` already
have their own two sections in `verify-tools.sh`.

## Which checkout gets asked

The **live** one, resolved from the links systemd actually holds — not the checkout the script was
run from. `dotfiles-work` makes a worktree the normal place to run repo scripts, and no symlink
points into a worktree, so deriving the root from `BASH_SOURCE` makes the whole check vacuous exactly
where it is most likely to be run: "nothing linked — skipped", exit 0, while the live deployment has
a failing unit. `verify-tools.sh` hit that same bug in review and resolves the same way.

A consequence worth knowing: run from a branch whose `--list-managed` has not been deployed yet, the
checker exits 2 and says so, naming the ff-merge that fixes it. That is correct — "could not run" is
not a pass — and it clears the moment the branch lands, because the two scripts ship together.

## Failure modes of the checker itself

Two states that used to collapse into one, both found by rows:

- **Links exist, but the checkout they point into has no reconciler.** This printed the same sentence
  as "nothing is linked at all" and exited 0 — an unanswerable question resolving to the answer it
  would have had if everything were fine. `verify-tools.sh` separates exactly these two
  (`enable_found_link` vs `enable_root`) after the same bug. Mutant **M13**.
- **A `$(...)` caller is a subshell.** The flag distinguishing them was set inside
  `live_checkout_root` and read by its caller through command substitution, so it never came back.
  The resolver now assigns to globals.

`TIMER_HEALTH_MAX_HORIZON_DAYS` and `TIMER_HEALTH_NOW` are validated rather than trusted: every use
is inside `(( ))`, where a non-numeric value is a silent **0** — a horizon of zero days fails every
unit and a "now" of zero passes every one of them. Both are exit 2. Mutant **M14**.

## The state table

`scripts/test-timer-health.sh`, 70 checks, hermetic, run in CI
("Repo-Owned Timer Health State Table").

**Hermetic means a recording `systemctl` stub at the front of `PATH`**, never "systemctl happens to
be absent". This box has a real one wired to a live user manager holding the herdr server every agent
session depends on, plus an armed `wt-gc-sweep.timer`. A suite built on absence passes on a CI runner
and tells you nothing here — the same lesson `scripts/test-systemd-reconcile.sh`'s header records
after its `--apply` rows turned out to have executed zero times in a full green run.

The **ownership** half is deliberately not stubbed: each fixture holds a real copy of
`reconcile-systemd-units.sh`, so every row also exercises `--list-managed` and the containment logic
behind it.

> A copy, **not a symlink**. The first draft of the suite symlinked it, and the row that replaces the
> reconciler with a stub that cannot answer `--list-managed` wrote through that symlink with `>` —
> truncating `scripts/reconcile-systemd-units.sh` in the working tree, from inside a test whose
> subject is a checker that must never touch the wrong file. The live checkout was untouched; the
> worktree copy was restored from git and the patch re-applied.

### Mutation sweep, 2026-09-22

15 mutants, **15 killed, 0 survived, 0 not applicable**. Each was applied by exact string replace
with the occurrence count asserted, **diffed** before the suite ran — a mutation that applies and
parses can still be a different mutation than its name — and restored from git afterwards.

| # | mutation | killed by |
|---|---|---|
| M1 | drop the `LoadState` gate | not-found service reads as clean |
| M2 | drop the `ConditionTimestamp` gate | a never-started service reads as SKIPPED |
| M3 | drop the horizon check | a next run 20 days out reads as clean |
| M4 | staleness uses `>=` | exactly at the limit reads as stale |
| M5 | anchor on `last` unconditionally | a never-fired overdue timer reads as clean |
| M6 | stop dropping bare templates | the template is passed to systemctl |
| M7 | enabled timer absent from `list-timers` reads as clean | — |
| M8 | exit 2 collapses to a pass | three "could not run" rows |
| M9 | do not check `ExecMainStatus` | `Result=success` with status 1 reads as clean |
| M10 | do not check the timer `ActiveState` | an inactive timer reads as clean |
| M11 | skip the not-enabled decision | an unenabled unit is inspected |
| M12 | a standalone service that is down reads as clean | — |
| M13 | links-with-no-reconciler collapses to "empty machine" | — |
| M14 | a non-numeric horizon is accepted | exit 1 instead of 2 |
| M15 | `next <= 0` reads as clean | — |

## What this does not do

**It only fires when someone runs it.** That is the honest limitation of the report-only decision
taken on 2026-09-22. `verify-tools.sh` is what people already run and what the switch-over runbooks
treat as an assertion, and the check is now inside its exit code — but nothing pings anything at
04:05 when the sweep fails.

The follow-up, if that turns out to matter, is a healthchecks.io dead-man's-switch per unit, reusing
`scripts/restic-notify.sh`'s pattern and `BACKUP_HC_URL_*`'s config shape. It is deliberately not in
the first round: it needs URLs created by hand, a new config key and a timer to do the pinging, and a
pinger that silently dies is a new instance of the very failure being fixed — which is why the
healthchecks side has to be configured as a dead-man's switch rather than an on-failure alert.

Also rejected: `~/.local/state/wt-gc-sweep/log` as a freshness source. It is a real audit trail
(`mode=apply removed=27 branches=175 … failed=0 warnings=0`) but it is per-unit special-casing, and
`list-timers` answers the same question for every unit including the ones added next.
