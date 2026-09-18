# Weekly windows in the account picker: rank on the aggregate, respect the spend wall, gate on the model

**Date:** 2026-09-18
**Status:** Revised after adversarial review (pending spec review)
**Issues:** DO-621 (Part A: ranker), DO-623 (Part B: gate, blocked by DO-621).
Follow-ups out of scope: DO-624 (`hspawn -m` through the gate) and
ZviBaratz/herdr-draft#185 (herdr-draft passing the model to its picker).

## Problem

`claude-pick` collapses every weekly window into one number, ignores when that
window resets, and never reads spend headroom. Spend headroom is the one signal that
separates free usage from billed usage from blocked usage.

Today, `_claude_profile_metrics` sets `_CPM_UW = max(seven_day, weekly_scoped[].utilization)`,
but `_CPM_RW` holds `seven_day.resets_at` only, so `uW` and `rW` can describe different
windows. `_claude_pick_for_dir` demotes a seat to the `weekly-spent` tier on
`uW >= CLAUDE_PICK_WEEK_SPENT` alone, without checking whether the window has already
reset. `_claude_pick_score` takes `(u5, r5, uw, holders)` and has no weekly-reset input.

Snapshot on `cilantro`, 2026-09-18 17:51Z:

```
quantivly-1   seven_day  83% (resets 09-21T09:00Z) · 7d fable 100% · spend $190.77 / $250
quantivly-3   seven_day 100% (resets 09-21T03:00Z) · 7d fable  63% · spend $275.23 / $275

PROFILE        CLASS           5H    7D   ...  WHY
quantivly-1    weekly-spent     2   100        7d window spent (100%)
quantivly-3    weekly-spent     9   100        7d window spent (100%)
```

The two seats are spent on opposite axes, yet `max()` reports them identically. A
lapsed weekly reading also still demotes a seat whose week has already rolled over.
clauth fixed that class on its own surfaces in 0.15.2 (#74), but the picker reads
`usage_cache.json` raw, so it does not inherit the fix.

### What a spent window actually does (measured 2026-09-18)

Sources: clauth's `usage_history.jsonl` for each profile (about two days retained) and
Claude Code transcripts.

| Seat state | What happens | Evidence |
|---|---|---|
| window not spent | free | quantivly-1's aggregate rose 77 → 86 over 27 h while spend stayed flat at $190.77 |
| window spent, spend headroom left | usage **bills to usage credits** | quantivly-1 on 09-17: +$0.31 at 19:07 and +$0.28 at 19:09, within 4 min of `7d fable` reaching 100 while the aggregate sat at 77. These are the only spend increases in the retained history across all three work seats |
| window spent, spend at its limit | **hard block**: "You've hit your individual spend limit" | 6 errors between 18:03 and 19:15Z today. Each quotes a weekly reset of Sep 21 06:00 IDT (03:00Z), which is quantivly-3's `seven_day` reset. quantivly-3 hit 100 at 17:40Z with spend at $275.23 of $275 |

The sample is small: one billing episode and one blocking episode. Both are direct
readings of clauth's spend counter and of the error text. Max seats have
`spend.enabled = false`; that a spent window therefore blocks them is **inferred from
the field**, not observed.

These readings refine DO-574 rather than contradict it. DO-574's 2026-09-10
measurement, live sessions on 100% seats, is the billing row: a spent week is not a
wall while spend headroom lasts. It becomes a wall once headroom is gone.

The "Fable · Requires usage credits" banner is **not** evidence either way. It comes
from a server-side flag that is enabled on every Team profile, and it is a notice,
not a block. An earlier draft of this spec claimed otherwise; that claim is retracted.

## Decisions

1. **Consume-first dominates on the weekly axis.** Given seat A with 40% of its week
   left and a reset in 6 d, and seat B with 20% left and a reset in 12 h, prefer B.
   The pick must hold at the default weights, not just the scores.
2. **The ranker reads the aggregate `seven_day` only; per-model windows belong to the
   gate.** The ranker is model-blind; the gate already takes `--model`.
3. **`weekf` stays, and its penalty fades as the reset approaches.** Removing it, as an
   earlier draft proposed, switches weekly headroom off below 100%. The adversarial
   review showed an idle seat at 99% tying with an idle seat at 20% under that design.
4. **Three tiers, matching what the seat will actually do:** `eligible` (free) >
   `weekly-spent` (bills credits) > `exhausted` (blocked until the weekly reset).
5. **The gate refuses only a lane that would be blocked**: its model window or the
   aggregate is spent *and* there is no spend headroom. A lane that would bill is
   allowed, and the verdict reports `bills_credits: true`. Spending policy beyond that
   is not the gate's job.
6. **Missing data never escalates to a refusal in the ranker.** An absent or
   unreadable spend block leaves a spent seat at `weekly-spent`, never `exhausted`.
   DO-574 recorded what a false hard block costs: every headless caller refusing
   across the whole work tree. The gate's own rule is the opposite, and it stands: an
   undated number is never optimistic there.

## Part A: the ranker (DO-621)

### Metrics (`_claude_profile_metrics`)

- `_CPM_UW` = `seven_day.utilization` alone. `uW` and `rW` now describe one window.
- **Lapse.** If `seven_day.resets_at` parses to a time in the past, `_CPM_UW` becomes
  `unknown`: no tier, no bonus, no penalty. This does **not** move the seat into the
  `unknown` *class*, which would demote it by another route. An **absent** or
  unparseable reset is not a lapse; the reading still counts, as today.
- **Spend headroom** becomes `_CPM_SPEND`, one of:
  - `headroom`: `spend.enabled == true`, and `used` and `limit` are both numeric with `used < limit`
  - `none`: `enabled == false`, or `used >= limit`
  - `unknown`: anything else, including no spend block, a missing `limit`, or a non-numeric value
- **Appended fields.** Add `_CPM_SPEND`, `fetched_at`, and the per-model windows for
  Part B. The per-model windows travel as one `@json` array of
  `{label, utilization, resets_at}`, not colon-separated triples: `resets_at` itself
  contains colons, and labels contain spaces. The TSV and publish records are
  positional and append-only (DO-612), so nothing is inserted between existing fields.
- **Localisation.** Every site that declares `_CPM_*` locals must declare the new
  ones, or one profile's values leak into the next profile's measurement. Those
  sites are `zshrc.herdr` (~879, ~1161, ~1312, ~1584) and `scripts/claude-pick`
  (~370). Grep for `local _CPM_` rather than trusting these line numbers.

### Class and tier

- `_claude_pick_class` returns `exhausted:weekly window spent and no spend headroom`
  when a live `seven_day` is at or above `CLAUDE_PICK_WEEK_SPENT` **and**
  `_CPM_SPEND == none`. Everything that already follows from `exhausted` applies
  unchanged:
  - headless callers refuse
  - interactive callers proceed on the least-bad seat and print the existing warning
  - an exhausted pool does not reach overflow
- The least-bad choice and the exhaustion report use **`rW`** for a seat exhausted by
  the spend wall, because the weekly window is what blocks it. `_claude_pick_exhausted`
  gains `rW` as an appended field. The 5h reset would name the wrong wait.
- `weekly-spent` (demote, never refuse) covers a live, spent `seven_day` with
  `_CPM_SPEND` of `headroom` or `unknown`.
- `CLAUDE_PICK_WEEK_EXHAUSTED` stays inert at 101. It now tests the aggregate only,
  which is stated and not silent.

On today's data: quantivly-1 is `eligible` (86%) and quantivly-3 is `exhausted`.

### Score (`_claude_pick_score(u5, r5, uw, holders, rw)`)

`rw` is appended, so existing four-argument calls read it as `unknown`.

```
hw        = max(0, 100 - uw)                         (as today; unknown uw -> weekf = 100)
weekf     = as today: 100 when hw >= WEEK_LOW, else hw*100/WEEK_LOW
exp_w     = 100 - rw*100/604800   when 0 < rw < 604800, else 0
weekf_eff = weekf + (100 - weekf) * exp_w / 100      # the penalty fades near the reset
bonus_w   = hw * exp_w * W_WEEK_EXPIRE / 100          # consume-first, scaled by headroom
score     = (base + bonus + bonus_w) * weekf_eff / 100 - crowd
```

`CLAUDE_PICK_W_WEEK_EXPIRE` defaults to **200**. The ranker picks by round-robin among
seats within `CLAUDE_PICK_RR_BAND` (800) of the best score, so a consume-first gap
smaller than the band is a coin flip rather than a preference. Worked at the defaults:

| Case | Today | Revised |
|---|---|---|
| A (40%, 6 d) vs B (20%, 12 h) | no weekly signal | 1200 vs 3720, a gap of 2520 > band, so **B is picked regardless of the ledger** |
| idle 99% vs idle 20%, reset in 5 d | 600 vs 10000 | 3319 vs 14640 |
| 5% left, resets in 1 h | penalised (weekf 33) | exp_w = 100 in integer arithmetic, so weekf_eff = 100: no penalty, and a small bonus |
| rw unknown | n/a | exp_w = 0, reducing exactly to today's arithmetic |

### Cache age (`fetched_at`)

`_claude_profile_cache_age` gains an optional second argument: the `fetched_at` value
the metrics `jq` call has already extracted. This adds no fork.

- If `fetched_at` is a number (epoch **ms**), the age is `now - fetched_at/1000`.
- If it is up to 60 s in the future, the age clamps to 0. If it is more than 60 s in
  the future, it **falls back to the file mtime**, which is what clauth's own
  scheduler does (`oauth_seed_clock` filters `at <= now`). The previous draft mapped
  this case to `unknown`, and the ranker treats an unknown age as fresh.
- If it is absent, use the file mtime, as today. This keeps a 0.15.1 clauth working.

This closes the case upstream fixed alongside #74: a plan-only cache rewrite advances
the mtime, so under mtime-based age it reads as fresh when it is not.

**The gate inherits this.** Its staleness check reads the same age, so its 600 s
threshold is measured against `fetched_at`. It therefore refuses plan-only rewrites
it used to pass. That is intended.

**`claude-doctor`** changes in the same PR: its usage-cache freshness line (the
`_claude_file_age_s` call, mtime-based) reads `fetched_at` first. Two readers of one
file must agree on its age, and a `jq` call per profile is fine in the doctor.

### Interfaces that change in Part A

- `--json` `usage.weekly` and `skipped[].weekly` now mean `seven_day` instead of the
  maximum, and are `null` on a lapsed week. herdr-draft renders this value as its 7d
  gauge (`internal/app/async.go`, `internal/form/field_account.go`), so the gauge now
  matches `clauth list`'s "7D USED".
- `usage.cache_age_s` is computed from `fetched_at` where present.
- `--json` gains `usage.spend` (`headroom|none|unknown`) as a new key.
- `--explain` shows `7D unknown` for a lapsed week, and gives the spend-wall reason
  for an exhausted seat.
- **A billing warning.** When the pick is `weekly-spent`, `_claude_pick_for_dir`
  appends to `_claude_pick_warnings`, e.g.
  `quantivly-1: weekly window spent — usage bills credits ($190.77 of $250)`.
  `claude()` already prints every warning on an interactive ranked launch
  (`zshrc.herdr:1757`). `_claude_pick_for_dir` runs in the calling shell, not a
  subshell, so the warning reaches that print. The same entry lands in `--json`
  `warnings[]` and in `--explain`. No new output channel is needed. (The adversarial
  review said `claude()` never prints these warnings; the code shows it does.)
- Comments that become stale and must be updated in the same PR: the DO-574/DO-609
  blocks on `_claude_pick_class` and at the tier (~855–869, ~1422–1434), and the "no
  freshness field" paragraph near the top of `scripts/claude-pick` (~69–75).

## Part B: the gate (DO-623)

This part runs after every existing 5h check has passed, so current refusal states
keep their precedence.

### The spend wall, for both windows

A pinned seat (`--profile`, which is how rabota calls) bypasses the ranker's tiers,
but a pin does not override the gate. The gate therefore applies the spend wall
itself.

| Window | Spend | Result |
|---|---|---|
| aggregate `seven_day` live and spent | `none` | refuse: `gate-spend-wall` |
| lane's model window live and spent | `none` | refuse: `gate-spend-wall` |
| either live and spent | `headroom` | allow; `gate.bills_credits = true` |
| either live and spent | `unknown` | refuse: `gate-unmeasured` (decision 6's gate half) |
| lapsed | any | allow |
| no readable reset at or above threshold | any | refuse: `gate-unmeasured` |
| below threshold | any | allow |

The refusal reason names which window is spent (`aggregate` or the label), its
percentage, its reset time, and the seat's spend.

### Which per-model window governs a lane

clauth v0.15.2 builds labels as `format!("7d {}", name.to_lowercase())`, taking `name`
from the scope's model `display_name` or, failing that, the surface name.

- Normalise the lane's model id by stripping a trailing `[…]` (so `opus[1m]` becomes
  `opus`) and splitting it on `-` into tokens.
- A label governs the lane when its **first word** after `7d ` equals one of those
  tokens. `claude-fable-5-1` and `fable` both match `7d fable`, and `7d sonnet 5`
  matches `claude-sonnet-5`. Matching is on whole tokens, not substrings, so `fablex`
  does not match `7d fable`.
- A label whose first word is `claude` is **ignored**, because it would match every
  model id. Any other surface-scoped label is unknown today. The worst it can cause is
  a refusal on a seat that is also out of spend headroom.
- When several labels match, the **worst** of them governs.
- With no match, there is no per-model check and the gate behaves exactly as it does
  now.
- **A lapsed per-model window counts as undated when `fetched_at` is absent.** With
  only the file mtime to go on, a plan-only rewrite can keep a cache "fresh" while the
  window lapsed days ago and has since refilled. CLAUDE.md records a seat going from
  7% to 100% in forty minutes.

### Interfaces

- **JSON:** the `gate` object gains
  `model_window: {label, utilization, resets_at, state: "live"|"lapsed"|"undated"}`
  (or `null`), `bills_credits`, and `spend`. All three are new keys.
- **rabota:** `rabota/budget.py` maps `gate-spend-wall` to `credential:window`.
  Unlisted states currently fall to `credential:unmeasured`, which would report a
  measured refusal as "could not measure".

### Callers

The only in-repo caller of `--gate` is `rabota/budget.py`, and it always pins
`--profile`. herdr-draft does not pass a model (#185), and `hspawn` does not use the
CLI (DO-624). Part B protects rabota lanes as soon as it lands.

## Testing

All rows are hermetic. Each fix is pinned by a mutant that dies, and each mutation is
dry-run for applicability first, because a mutation that no longer applies reads
exactly like a survivor.

### Existing rows in `scripts/test-claude-pick.sh`

| Row | Effect of the change |
|---|---|
| `:108` "uW is the WORST of 7d and scoped", expects 55 | **Inverts** to "`uW` is `seven_day` alone", expects 40 |
| `:165` 96% below 60% · `:166` spent week scores 0 · `:181` fresh outranks spent · `k3` (~`:202`) floor | **Pass unchanged.** With `rw` unknown, `exp_w = 0`, `weekf_eff = weekf` and `bonus_w = 0`, so the arithmetic is exactly today's. Verify each one, don't assume. |
| other score literals | Pass unchanged, for the same reason |
| the 21 age rows (`touch -d`, no `fetched_at`) | Exercise the mtime fallback and pass unchanged |
| `k3`'s class assertion (no spend block) | `_CPM_SPEND = unknown`, so the class stays `eligible` |

### New rows, Part A

| Row | Pins |
|---|---|
| A/B: B **picked** under an empty ledger **and** under a ledger that last picked B | consume-first, clearing the band |
| idle 99% vs idle 20%, reset in 5 d: the 20% seat picked | `weekf` kept |
| 5% left, reset in 1 h: no `weekf` penalty | damping |
| lapsed `seven_day` at 100: not demoted, no bonus | the lapse |
| `weekly_scoped` reset differs from `seven_day` reset | `uW` and `rW` are one window. The live instants coincide, so without this the split is unfalsifiable |
| the complementary pair: 1 `eligible`, 3 `exhausted` | aggregate-only tier plus the spend wall |
| aggregate spent with spend `headroom` / `unknown` / `none` / `enabled:false` | `weekly-spent` / `weekly-spent` / `exhausted` / `exhausted` |
| an exhausted spend-wall seat reports `rW` as its reset | the exhaustion report names the right wait |
| `fetched_at` old with a new mtime: stale; absent: mtime; 30 s ahead: clamps to 0; 1 h ahead: mtime | `fetched_at` |
| the doctor's freshness agrees with the picker on a `fetched_at` fixture | two readers, one answer |
| the gate refuses a fresh-mtime cache whose `fetched_at` is older than 600 s | the gate inherits the age |
| a `weekly-spent` pick adds the billing warning, and `claude()` prints it (`test-hspawn.sh`, which covers `claude()`) | interactive signal |
| an `eligible` pick adds no billing warning | the warning is not noise |
| per-model windows as `@json`: a label with spaces and a colon-bearing `resets_at` round-trip | encoding |
| two profiles measured in sequence: no `_CPM_*` value leaks from the first into the second | localisation |

Part A mutants:
- restore `max()`
- drop the lapse arm
- remove the `weekf_eff` damping
- drop the headroom factor from `bonus_w`
- set `W_WEEK_EXPIRE` to 50 (the A/B pick row must die)
- treat spend `unknown` as `none` (the missing-data row must die)
- prefer mtime over `fetched_at`
- map a future `fetched_at` to `unknown`
- drop one localisation site

### New rows, Part B (in `scripts/test-claude-pick.sh` and rabota's tests)

| Row | Pins |
|---|---|
| Fable lane, live `7d fable` at 100, spend `none`: `gate-spend-wall` | model wall |
| same, spend `headroom`: allow, `bills_credits: true` | billing is not refused |
| same, spend `unknown`: `gate-unmeasured` | gate never optimistic |
| pinned seat, aggregate spent, spend `none`: `gate-spend-wall` | the pin does not bypass the wall |
| Opus lane on the Fable-spent seat: allow | model scoping |
| `opus[1m]` normalises; `7d sonnet 5` matches `claude-sonnet-5`; `fablex` does not match; `7d claude` ignored | attribution |
| two matching labels: the worst governs | worst-of-matches |
| lapsed per-model window without `fetched_at`: undated | lapse needs a real age |
| a 5h refusal keeps its state when a window is also spent | precedence |
| `model_window`, `bills_credits` and `spend` in the JSON | interface |
| rabota maps `gate-spend-wall` to `credential:window` | consumer |

Part B mutants:
- substring instead of token matching
- skip the `claude` exclusion
- best-of-matches instead of worst
- refuse on `headroom`
- allow on `unknown`
- rabota falling back to `unmeasured`

## Not in scope

- **A model-aware ranker.** The ranker stays model-blind. On today's work pool it
  makes no difference, because no pool seat has a free Fable window. In general a
  Fable session can land on a Fable-spent seat and bill credits. The gate is what
  catches the case where that seat would be blocked, and the model hint reaches the
  gate only through DO-624 and herdr-draft#185.
- **A weekly burn projection in the gate.** The rate table is denominated in points of
  the 5h window per lane-hour.
- **A spending policy** beyond "refuse what would be blocked".
- **Upstream clauth changes.** This does not wait on clauth#86.
