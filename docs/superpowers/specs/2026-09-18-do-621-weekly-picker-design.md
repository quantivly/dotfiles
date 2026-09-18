# Weekly windows in the account picker: rank on the aggregate, gate on the model

**Date:** 2026-09-18
**Status:** Approved (pending spec review)
**Issues:** DO-621 (Part A — ranker), DO-623 (Part B — gate, blocked by DO-621).
Follow-ups out of scope: DO-624 (`hspawn -m` through the gate),
ZviBaratz/herdr-draft#185 (herdr-draft passing the model to its picker).

## Problem

`claude-pick` folds every weekly window into one number and then ignores when it
resets.

`_claude_profile_metrics` sets `_CPM_UW = max(seven_day, weekly_scoped[].utilization)`
while `_CPM_RW` is `seven_day.resets_at` only, so `uW` and `rW` can describe
different windows. `_claude_pick_for_dir` demotes to the `weekly-spent` tier on
`uW >= CLAUDE_PICK_WEEK_SPENT` alone, never consulting a reset. `_claude_pick_score`
takes `(u5, r5, uw, holders)`, with no weekly reset at all. `weekf` is flat at 100
until weekly headroom drops below `CLAUDE_PICK_WEEK_LOW` (15), so between 0% and 85%
weekly use the weekly axis contributes nothing to ranking.

Measured on `cilantro`, 2026-09-18 17:51Z:

```
quantivly-1   seven_day  83% (resets 09-21T09:00Z) · 7d fable 100%
quantivly-3   seven_day 100% (resets 09-21T03:00Z) · 7d fable  63%

PROFILE        CLASS           5H    7D   ...  WHY
quantivly-1    weekly-spent     2   100        7d window spent (100%)
quantivly-3    weekly-spent     9   100        7d window spent (100%)
```

The two seats are spent on **opposite axes**, and `max()` reports them identically.
`clauth list` shows quantivly-1 at 83%. Separately, a lapsed weekly reading at 100%
demotes a seat whose week has already rolled over. clauth fixed that class on its
own surfaces in 0.15.2 (#74), but the picker reads `usage_cache.json` raw and does
not inherit the fix.

### A constraint this design must keep

A spent **aggregate** week is not a hard wall on Team seats. Measured 2026-09-10 and
recorded on `_claude_pick_class`: two seats read `seven_day` 100 with live sessions
on them, zero weekly-reset refusals across 750 transcripts, and what Team seats hit
instead is the individual spend limit, whose remedy is a person. That is why DO-574
made the week **demote, never refuse**. Nothing here changes that.

A spent **per-model** window is different. A spent `7d fable` window is when Team
seats show "Fable · Requires usage credits". That window, and only that window, is
worth a refusal, and only for a lane that runs that model.

## Decisions

1. **Consume-first dominates on the weekly axis.** Given A (40% of its week left,
   resetting in 6 days) and B (20% left, resetting in 12 hours), prefer B. This is
   the rule DO-574 already applies to the 5h window, and the rule clauth#86 asks
   upstream for.
2. **The ranker is aggregate-only; per-model windows belong to the gate.** The ranker
   is model-blind by construction. The gate already takes `--model`.
3. **`weekf` is removed.** Under consume-first, penalising a seat with little weekly
   headroom is backwards when its reset is near. The weekly axis becomes tier + bonus.
   Keeping a long headless lane off a nearly-dry seat is the gate's job.
4. **An undated per-model window at or above threshold refuses** in the gate, as
   `gate-unmeasured`, matching the gate's existing rule that an undated number is
   never optimistic.

## Part A — the ranker (DO-621)

### Metrics — `_claude_profile_metrics`

- `_CPM_UW` = `seven_day.utilization` alone, so `uW` and `rW` now describe one window.
- **Lapse.** When `seven_day.resets_at` parses and is in the past, `_CPM_UW = unknown`.
  This is not the `unknown` *class*: a lapsed week must not rank after every measured
  seat, because that is the same demotion by another route. It only removes the tier
  and the bonus. An **absent** or unparseable reset is not a lapse: the reading keeps
  counting, as today. clauth omits `resets_at` only on an unstarted window (at 0%),
  and un-demoting a seat on missing data would be optimism the gate forbids.
- **New fields, appended.** Per-model windows as `label:utilization:resets_at` triples,
  consumed by Part B, and `fetched_at`. The TSV and publish records are positional and
  documented append-only (DO-612): nothing is inserted, every reader keeps its index.

### Tier — `_claude_pick_for_dir`

Unchanged in meaning: `weekly-spent` when a *live* `seven_day` is at or above
`CLAUDE_PICK_WEEK_SPENT` (default 100). It remains a demotion tier (below `eligible`,
above `unknown`) and never a refusal. On the data above, quantivly-1 becomes
`eligible` and quantivly-3 stays `weekly-spent`.

### Score — `_claude_pick_score(u5, r5, uw, holders, rw)`

`rw` is appended as the fifth argument, so existing four-argument calls read it as
`unknown`.

```
hw      = 100 - uw                                   (0 when uw unknown)
exp_w   = 100 - rw*100/604800   when 0 < rw < 604800, else 0
bonus_w = hw * exp_w * W_WEEK_EXPIRE / 100
score   = base + bonus + bonus_w - crowd             # weekf removed
```

- `bonus_w` is scaled by weekly headroom, so an empty seat earns nothing just for
  resetting soon. This is what makes B outrank A.
- `CLAUDE_PICK_W_WEEK_EXPIRE` defaults to 50, the same as `CLAUDE_PICK_W_EXPIRE`, so
  neither expiry term dominates the other by default. The rows pin the ordering, not
  the weight.
- `CLAUDE_PICK_WEEK_LOW` is retired. If it is set, it is ignored and says so, so it
  cannot silently do nothing.
- Unknown, negative or ≥ 7 d `rw` earns no weekly bonus. That matches the 5h
  reasoning already in the function: a rolled or undated window has nothing left to
  use or lose.

### Cache age — `fetched_at`

`_claude_profile_cache_age` gains an optional second argument, the `fetched_at` value
the metrics `jq` call already extracted, so the ranker adds no fork.

- A numeric `fetched_at` (epoch **ms**) → `now - fetched_at/1000`.
- More than 60 s in the future → `unknown` (same clock, so it can only be corruption).
  Anything less clamps to 0.
- Absent → file mtime, today's behaviour. This keeps a 0.15.1 clauth, or an adopter
  still on it, working.

This closes the case upstream fixed alongside #74: a cache rewrite that produced no
new reading advances the mtime and reads as fresh.

**The gate inherits this in Part A.** Its staleness check reads the same
`_claude_pick_age`, so after DO-621 the 600 s gate threshold is measured against
`fetched_at`, not mtime. That makes the gate stricter: it refuses a plan-only
rewrite it used to pass. The change is intended, and needs one gate row to pin it.

**`claude-doctor`** moves in the same PR. Its usage-cache freshness line uses
`_claude_file_age_s` (mtime) and would otherwise disagree with the picker about the
same file. A `jq` per profile is acceptable in the doctor.

## Part B — the gate (DO-623)

### Which window governs a lane

A `weekly_scoped` label of the form `7d <family>` governs a lane when `<family>` is a
**hyphen-delimited token** of the lane's `--model`. Token, not substring:
`claude-fable-5-1` and `fable` match `7d fable`, a hypothetical `fablex` does not, and
`claude-opus-5[1m]` matches nothing today. If no window matches, or a label is not in
`7d <word>` form, there is no per-model check and the gate behaves exactly as now.
It never refuses on a window it cannot attribute.

### Refusal

This runs after every existing 5h check has passed, so current refusal states keep
their precedence.

| Governing window | Utilization | Result |
|---|---|---|
| live | ≥ `CLAUDE_PICK_WEEK_SPENT` | refuse — state `gate-model-window`, exit 2; reason names label, %, reset |
| lapsed | any | allow |
| no readable reset | ≥ threshold | refuse — `gate-unmeasured` |
| any | < threshold | allow |

A lapsed window is allowed because the gate already requires a cache no older than
`CLAUDE_PICK_CACHE_MAX_AGE` (600 s here), so a lapsed window inside it reset within
that span, and the fresh 5h check still guards the lane. A spent aggregate alone
never refuses.

### Interfaces

- **JSON:** the `gate` object gains
  `model_window: {label, utilization, resets_at, state: "live"|"lapsed"|"undated"}`,
  or `null`. It is a new key; existing readers are unaffected.
- **rabota:** `rabota/budget.py` maps `gate-model-window` → `credential:window`.
  Today every unlisted state falls to `credential:unmeasured`, which would report a
  measured refusal as "could not measure".
- **`--explain`:** one info line per spent, live per-model window
  (`quantivly-1: 7d fable 100% (resets …)`). It never changes the pick. It is the only
  signal an interactive `claude`, which has no gate, gets before Claude Code itself.

### Callers

The only in-repo caller of `--gate` today is `rabota/budget.py`. herdr-draft calls
`claude-pick --dir D --json [--strict]` without a model (ZviBaratz/herdr-draft#185),
and `hspawn` picks through `_claude_pick_for_dir` directly (DO-624). Part B protects
rabota lanes on landing, and the others as they opt in.

## Testing

All rows are hermetic, in the existing suites. Every fix is pinned by a mutant that
dies, and each mutation is dry-run for applicability first: a mutation that no longer
applies reads exactly like a survivor.

### Part A — `scripts/test-claude-pick.sh`, `scripts/test-claude-doctor.sh`

Existing rows that change, deliberately:

- `uW is the WORST of 7d and scoped` (`:108`, expects 55) → "`uW` is `seven_day`
  alone" (expects 40).
- `a spent week scores 0` (`:166`) → removed. Its replacement asserts that a spent
  week leaves the score intact and the **tier** demotes.
- Every other score literal was taken with no weekly reset. At `rw` unknown,
  `bonus_w = 0`, so they stay valid unchanged. The 21 age rows use `touch -d` on
  fixtures with no `fetched_at`, so they exercise the fallback and stay valid.

New rows:

| Row | Pins |
|---|---|
| lapsed `seven_day` at 100 → not demoted, no bonus | the lapse |
| `weekly_scoped` reset ≠ `seven_day` reset | that `uW`/`rW` are one window; without it the split is unfalsifiable, since the live instants coincide |
| complementary pair (quantivly-1/-3 shapes) → 1 `eligible`, 3 `weekly-spent` | the aggregate-only tier |
| A/B → B ranks above A | consume-first |
| empty seat resetting soon earns no `bonus_w` | headroom scaling |
| `fetched_at` old + mtime new → stale; absent → mtime; future → unknown | `fetched_at` |
| doctor freshness agrees with the picker on a `fetched_at` fixture | two readers, one answer |
| gate refuses a fresh-mtime cache whose `fetched_at` is past 600 s | the gate inherits `fetched_at` |
| `CLAUDE_PICK_WEEK_LOW` set → ignored, and says so | retirement |

Mutants: restore `max()`; drop the lapse arm; drop the headroom factor from
`bonus_w`; prefer mtime over `fetched_at`; restore `weekf`.

### Part B — `scripts/test-claude-pick.sh`, rabota's tests

| Row | Pins |
|---|---|
| fable lane, live `7d fable` 100 → `gate-model-window`, exit 2 | the refusal |
| opus lane, same seat → allow | model scoping |
| lapsed → allow · undated ≥ 100 → `gate-unmeasured` · < threshold → allow | the table |
| unrecognised label, near-miss token (`fablex`) → no check | attribution |
| aggregate 100 alone → allow | DO-574 kept |
| a 5h refusal keeps its state when the model window is also spent | precedence |
| `model_window` shape, and `null` with no match | JSON |
| rabota maps `gate-model-window` → `credential:window` | consumer |
| `--explain` info line present; pick unchanged | interactive signal |

Mutants: substring instead of token matching; drop the lapse row; rabota falling back
to `unmeasured`; `--explain` line changing the pick.

## Not in scope

- A weekly burn projection in the gate. The rate table is in points of the **5h**
  window per lane-hour; a weekly rate would be a second unmeasured table.
- Upstream clauth changes. This does not wait on clauth#86.
- herdr-draft and `hspawn` opting in to the gate (#185, DO-624).
