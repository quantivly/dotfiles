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

`scripts/test-timer-health.sh`, 77 checks, hermetic, run in CI
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
| M16 | a mid-run timer is treated as stopped | the four DO-686 rows below |

## The first unattended run found a defect in the checker (DO-686)

`wt-gc-sweep.timer`'s first real run, 2026-09-23. The machine slept through
04:00, `Persistent=true` caught the run up at **07:29:39**, and while the sweep
was still going this checker said:

```
✗ wt-gc-sweep.timer: active with NO next run scheduled — it has stopped firing.
```

It had not stopped firing. It was *running*.

**A timer whose triggered unit is running has no next elapse** — systemd
schedules one only once the run finishes:

```
$ systemctl --user list-timers --all -o json | jq -c '.[]|select(.unit=="wt-gc-sweep.timer")'
{"next":null,"left":null,"last":1790137779225147,"passed":45101411929,
 "unit":"wt-gc-sweep.timer","activates":"wt-gc-sweep.service"}
$ systemctl --user show wt-gc-sweep.service -p ActiveState -p SubState
ActiveState=activating
SubState=start
```

`null`, not a number. The checker reads `(.next // 0)`, so it became the same
`0` a genuinely stopped timer gives.

**Why the state table did not catch it.** There *was* a row for that branch —
"active with no next elapse: exit 1" — and it passed, because its fixture had
the service `inactive`. It described a state the real machine never produces
while pinning the branch that handles the state it does. A row that fails by
looking green, in the form this repo keeps finding: not a missing check, but a
check pinning the wrong rule. The lesson is narrower and sharper than "add a
row" — **ask of every fixture whether the machine can actually be in that
state, not only whether the branch is reached.**

The fix reads the activated service's `ActiveState` before treating `next <= 0`
as a fault; `active` or `activating` is mid-run and healthy. Nothing is asserted
about a run in progress, because `Result` and `ExecMainStatus` still describe
the **previous** run while a unit is activating — judging them there reports a
stale verdict as a fresh one. Both readings of `next=0` are now rows, and
reverting the fix fails exactly those four.

One thing this cost: by the time the fix was written the sweep had finished, so
the live machine no longer reproduced the fault. The suite is what proves the
fix, not the box — the same trap as a finding repaired under you mid-review.

For the record, that first run was otherwise clean:
`mode=apply removed=6 branches=16 pruned=0 skipped=120 failed=0 warnings=0`,
`Result=success`, 3m31s wall.

## The ambient half: a warning at the first prompt (DO-687)

Everything above fires only when someone runs `verify-tools.sh`. This is what closes that.

### Why not the obvious mechanisms

Measured before choosing, 2026-09-23:

- **`OnFailure=`** activates a unit "when this unit enters the **failed** state"
  (`man systemd.unit`). A condition-skipped unit never enters `failed`, so it is structurally
  blind to the case this whole feature exists for.
- **`notify-send` on a timer** would probably work — the user manager does hold `DISPLAY`,
  `WAYLAND_DISPLAY` and `DBUS_SESSION_BUS_ADDRESS` — but a notification fired at 04:00 is missed,
  and nothing notices if the notifier dies.
- **healthchecks.io**, the shape the backups use, needs URLs created by hand, a config key, and a
  pinger that is itself a timer needing to be watched.

### The mechanism, and the one part that is not a compromise

`check-timer-health.sh --write-state` records the verdict; `_dotfiles_live_config_warn` reads it
at the first prompt of each interactive shell. **There is no new systemd unit.** The prompt also
refreshes the file in the background, at most every 30 minutes, so the reader and the writer are
the same event — which is why there is no watcher here that itself needs watching.

The accepted cost is stated plainly: **it is not real-time.** A 04:00 failure reaches a human at
their next terminal.

### The prompt is a place with no timeout

Every line of the reader is shaped by that. Each of these was measured on this box (zsh 5.9), and
each is a row in `scripts/test-dotfiles-guard.sh`:

```
$ mkfifo f && zsh -fc '[[ -r f ]] && echo readable=yes'   → readable=yes
$ timeout 3 zsh -fc 'c=$(<f)'; echo $?                     → 124      # HUNG
```

A FIFO at the state path tests **readable** and then blocks a new terminal **forever** — no
output, no timeout, nothing to reason about. This is not exotic here:
`systemd/claude-cred-reconcile.service` carries a paragraph about a `cmp -s` on a FIFO left where
a credential should be, and got `TimeoutStartSec=60` for it. A prompt has no such escape. The
read therefore matches **regular files only**, via the glob qualifier `(N.)`.

```
$ zsh -fc 'foo=bar; bar=99; print $(( foo > 10 ))'         → 1
$ zsh -fc 'ts=1790000000; print $(( EPOCHSECONDS - ts > 10800 ))'  → 0
```

zsh arithmetic is **not** bash's silent 0: a non-numeric operand is resolved *recursively as a
parameter name*, and a malformed one prints `bad math expression` at the prompt. And
`EPOCHSECONDS` is **empty** without `zmodload zsh/datetime`, so any freshness comparison silently
never fires — invisible on this box, where p10k loads the module, and broken for a modular
`--herdr` adopter.

So the reader has **no clock at all** and **no staleness rule**. A threshold there would have been
a second copy of a schedule that lives in a unit file — the very thing the freshness section above
rejects by name, reintroduced one layer up. The refresh gate is a glob qualifier (`Nmm+30`),
which needs neither a module nor arithmetic.

### Two exit-code decisions

**`--write-state` exits 0 even when timers are unhealthy.** The state file is the channel; the
exit status reports only whether the verdict could be recorded. Carrying `--check`'s semantics
over would make whatever runs it fail for as long as any watched unit is unhealthy — polluting the
`--state=failed` signal this feature reads, and foreclosing any future `OnFailure=` on the writer.
`systemd/claude-cred-reconcile.service` already argues the same point about itself: *"an alarm
that is always on is an alarm nobody reads."*

**`rc=2` is silent at the prompt.** "The checker could not run" is most often a worktree ahead of
the deployed checkout, which `dotfiles-work` makes normal. `verify-tools.sh` reports it with the
ff-merge that fixes it; warning about it at every prompt is the permanently-red checker.

### `TIMER_HEALTH_QUIET`, and why it is not `DOTFILES_GUARD_QUIET`

The existing switch is documented narrowly — *"a deliberate opt-out for knowingly dogfooding a
branch"*. Inheriting it would mean a week on a feature branch silently takes timer health with it.
So timer health has its own switch, and its call sits **before** the `DOTFILES_GUARD_QUIET` return
inside `_dotfiles_live_config_warn`. That ordering *is* the decision, which is why the row for it
drives the real entry point rather than the helper.

### What two adversarial reviews changed

The design was reviewed twice before implementation — once for silent-failure paths, once from a
YAGNI position — and both changed it materially. It went from **five components to three**: the
new `timer-health.{service,timer}` pair, the staleness rule, a standalone `_timer_health_warn`
arm in `zshrc`, and a sixth `verify-tools.sh` assertion were all cut. Dropping the unit dissolved
four further findings outright (`TimeoutStartSec`, `PATH` pinning, `StateDirectory`, and a blind
spot where a oneshot writer can never judge itself, because DO-686's mid-run branch matches on
every one of its own runs).

One recommendation was **rejected**: deleting `ConditionPathExists` from `wt-gc-sweep.service` so
the skip case "ceases to exist". The observation behind it is correct — `scripts/wt-gc-sweep.sh`
checks for `wt-gc` itself — but the script exits **1**, so dropping the condition gives every
machine without `~/.dotfiles-local` a failed unit nightly; and making that path exit 0 instead
means a machine that *loses* `wt-gc` reports success. Today it is a skip, which this checker
detects and names. The trade deletes observability to simplify the observer.

Also rejected: distinguishing `rc=2` at the prompt (correct that the remedy differs; wrong that
it is worth a warning on every terminal in a worktree-heavy workflow).

### The claim that was dropped

The first draft said the design "watches itself", because the state file's age would reveal a
writer that had stopped. That is **false for the case it was invented for**: the file's *absence*
is what every real inertness produces, and absence is silent. It is not claimed any more.
`verify-tools.sh` reports when no verdict has ever been written, or when one is over a day old —
which is hand-run, the same tier as everything else here, and is stated as a limit rather than
sold as a property.

### Mutation sweep, 2026-09-23 — and the five that survived the first pass

15 mutants over both halves; final tally **15 killed, 0 survived**. That number is the least
interesting part of it. The first pass killed 8 and **five survived**, and the survivors are what
made the suite worth anything:

| survivor | why | verdict |
|---|---|---|
| drop the summary sanitiser | the fixture put the escape in an `X-Evil=` line, which `condition_lines()` never greps | **fixture described a state the machine cannot produce** — the DO-686 defect again, one week old |
| temp file in `$TMPDIR` | "no temp files left behind" passes either way; it pinned nothing | row rewritten to make `$TMPDIR` unwritable |
| unwritable state dir | `mkdir` failing is caught downstream by `mktemp` failing | **equivalent mutant**; replaced with one that changes behaviour |
| non-numeric count | `faults` never reaches `(( ))`, only string interpolation | row now pins the contract (the *displayed* count is a number) |
| quiet-var ordering | the row called the helper directly, so the ordering inside the guard was never exercised | row now drives `_dotfiles_live_config_warn` |

The replacement rows found two real defects in passing.

**With `$TMPDIR` unusable the whole write failed**, because the captured-output temp file still
used it. Every temp file now lives in the state directory, so the mode depends on exactly one
writable location.

**`mv` without `-T` turned a directory at the state path into a silent success.** A non-empty
directory where `status` should be makes plain `mv -f` move the temp file *inside* it and exit 0:
the writer believes it wrote, the reader sees a directory and correctly stays silent, and the
channel is dead with **both halves reporting health**. That is this feature's own failure mode,
reproduced inside the thing built to prevent it. `mv -fT` makes it an error.

It also took three attempts to write a row that could kill "a failed state write is swallowed",
and the two failures are worth recording: the first made `mkdir` fail, the second made the capture
file's `mktemp` fail, and both exited non-zero *before* `write_state` was ever called. A row can
reach the right exit status by a path that never executes the code it claims to pin.

One more thing the rows caught: before the arity check existed, `--write-state --extra` fell
through to a real write with the tester's own `$HOME` and wrote to the **live** state file the
prompt reads. `run()` in the suite now pins `XDG_STATE_HOME` as well. A fixture that can reach
live state is not hermetic, whatever it asserts.

## A standalone service is judged differently from a timer-activated one (DO-692)

Added when DO-692 went to register a second standalone unit (`vpn-notify.service`) and had to
look at `check_standalone_service()` properly. It got **two** things backwards, both in code
written for DO-685, and both only reachable once a second standalone unit existed.

### A SKIPPED standalone unit was reported as a fault

A unit held back by an unmet `Condition*` is `ActiveState=inactive`, `Result=success`,
`ConditionResult=no` — and the standalone path reported
`✗ enabled but ActiveState=inactive`. That is the exact inverse of this repo's own rule that a
skipped unit is not a failed one, which `check_service()` had implemented correctly all along.
Any unit gated on hardware, a dock or a vendor client would have been permanently red on every
machine lacking it.

**The two questions genuinely differ, and that is why the same branch gets opposite verdicts:**

| | a **timer-activated** unit stops matching its condition | a **standalone** unit never matches |
|---|---|---|
| means | scheduled work silently stopped | this machine is not one it runs on |
| verdict | **fault** | **decision**, same class as "linked, not enabled" |

The skip branch is gated on the unit **not** being up, because `ConditionResult` describes the
most recent start attempt: a unit that failed a condition once and is running now is judged on
what it is doing now.

### A crash-looping daemon read as a tick

`ActiveState` reads `activating` between automatic restarts, and `activating` was accepted as
✓ — a consequence of DO-686's mid-run fix carried into a path where its reasoning does not
hold. The failure mode is specific and nasty: **a daemon whose every run outlives
`StartLimitIntervalSec` never exhausts `StartLimitBurst`, so the rate limiter never trips.**
The unit never enters `failed`, never appears in `--state=failed`, and DO-687's prompt warning
never fires. It restarts forever, silently, and every check on the machine is green.

Sampling `ActiveState` cannot tell "starting" from "starting again for the ninth time".
`NRestarts` is the only property that can, and it counts **automatic** restarts only. It is
checked while `active` too, so a sample landing in the up half of the cycle does not read as
health.

`TIMER_HEALTH_RESTART_LIMIT` defaults to **3**: above a one-off blip (a network hiccup, a
resume) and below systemd's default `StartLimitBurst` of 5, so it speaks *before* the rate
limiter would — which matters precisely because in the loop this catches, the limiter never
speaks at all.

### Mutation sweep, 2026-09-23 (the standalone branches)

**8 mutants, 8 killed, 0 survived, 0 not applicable.** Run after the fact, because the change
shipped without one recorded — the rows were there and strong, but nothing on record said so,
and a reader cannot tell a swept guard from an unswept one.

| # | mutation | killed by |
|---|---|---|
| S1 | a skipped standalone unit is a fault again (the inverted rule) | reported as a decision, not `✗` |
| S2 | drop the `ConditionTimestamp` gate | a never-started unit reads as skipped |
| S3 | a unit that is UP but once failed a condition reads as skipped | judged on `ActiveState`, not a stale condition |
| S4 | drop the `NRestarts` crash-loop check | a restart loop reads as a tick |
| S5 | crash-loop checked only while `activating` | a loop sampled while `active` still named |
| S6 | a non-numeric `NRestarts` reaches arithmetic | still a tick, treated as no restarts |
| S7 | the limit is off by one (`>=` for `>`) | restarts *at* the limit are not a loop |
| S8 | a non-numeric `TIMER_HEALTH_RESTART_LIMIT` accepted | exit 2, not a silent default |

The suite is 125 rows (up from 98). Both defects were invisible while `herdr-server.service`
was the only standalone unit — neither is gated on a condition and it does not crash-loop. **A
branch with one instance is a branch with one shape**, which is the same lesson as the fixture
that described a state the machine could not produce: the rows existed, and the machine had
never been in the state they were written for.

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
