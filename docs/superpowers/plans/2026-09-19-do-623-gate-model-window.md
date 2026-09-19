# DO-623 — the gate refuses a lane its model cannot run

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`
> (recommended) or `superpowers:executing-plans` to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `claude-pick --gate` refuse a lane whose *model's* weekly window is spent
with no spend headroom, instead of only checking the 5h window.

**Architecture:** Part A already publishes everything the gate needs (`_CPM_WINDOWS`,
`_CPM_SPEND`, `fetched_at`-based age). This part plumbs `_CPM_WINDOWS` into `claude-pick`,
adds a weekly arm after the existing 5h arms (so every current refusal keeps its
precedence), and teaches `rabota/budget.py` the new state. One Part A field is widened —
`_CPM_SPEND` gains a fourth value — to resolve spec drift honestly rather than paper over it.

**Tech Stack:** zsh (integer arithmetic only, no `zsh/mathfunc`), `jq` (1.6-compatible
forms), Python 3 for rabota, hermetic shell state tables.

**Spec:** `docs/superpowers/specs/2026-09-18-do-621-weekly-picker-design.md`, "Part B: the
gate". **The spec's Part B spend table is stale and Task 5 rewrites it** — see *Context*.

---

## Context

`claude-pick --gate` is the one implementation of "may a headless lane start on this seat".
Today it only asks about the **5h** window: projection, staleness, a rolled reset. A lane
can therefore pass the gate and die immediately because the seat's *weekly* window for that
lane's model is spent and the seat has no usage-credit headroom left. That was measured on
2026-09-18: six "You've hit your individual spend limit" errors on a seat at `seven_day` 100
with $275.23 of a $275 limit.

Part A (DO-621, merged `cfdd419`) landed the measurements and the data: `_CPM_WINDOWS`
carries the per-model windows, `_CPM_SPEND` carries headroom state, and the gate already
dates caches from `fetched_at`. Nothing reads `_CPM_WINDOWS` yet. This part is the reader.

### The drift, and how it is resolved

The spec's Part B table says a spent window with spend **`unknown`** refuses as
`gate-unmeasured` — "the gate is never optimistic". That was written when `unknown` meant
"no spend block on disk". It no longer does: Part A's final revision made
`spend.enabled == false` — **every Max seat** — also map to `unknown`, because refusing Max
seats on an inference was taken back (`zsh/zshrc.herdr:1078-1097`,
`docs/CLAUDE_ACCOUNT_PICKER.md:400-406`).

Implemented verbatim, the table would refuse every Max-seat lane whose model window is spent.
**Decision (2026-09-19): split `disabled` out of `unknown`, and allow it.**

> **Superseded 2026-09-19, before merge.** An independent review of PR #177 challenged
> this, and the user decided to keep the approved spec's rule: on a live spent window the
> gate **refuses** `disabled` as `gate-unmeasured`. The `disabled` state stays. Everything
> below that argues for *allowing* it is the plan's original position, kept as history.
> The as-built rule and its evidence: `docs/CLAUDE_ACCOUNT_PICKER.md`, "The gate and the
> model's own window (DO-623)".

| `_CPM_SPEND` | means | gate, on a live spent window |
|---|---|---|
| `none` | `enabled:true`, `used >= limit` | **refuse** `gate-spend-wall` |
| `headroom` | `enabled:true`, `used < limit` | allow, `bills_credits: true` |
| `disabled` | `enabled:false` — a Max seat | allow, `bills_credits: null` |
| `unknown` | no spend block, or a non-numeric `used`/`limit` | **refuse** `gate-unmeasured` |

Why `disabled` allows, written down because it is the arm that reads as inconsistent:

- **The number is fine; only its consequence is unknown.** Every existing `gate-unmeasured`
  refusal is about a figure that describes *nothing*: stale, rolled, or undated. Here the
  utilization is freshly fetched with a live reset. "Never optimistic" was written about
  measurements, not about a good measurement of unknown effect.
- **Nobody has watched a Max seat block on a spent window.** `personal-0` reads
  `used 134.43` against `limit 125.0` with `enabled:false`, which is not the shape "no
  credits" predicts. Refusing on the field name is the #123 failure — a plausible mechanism
  standing in for an observation — recurring one document over from the repo's own record of it.
- **The asymmetry is the same one Part A already resolved.** `~/.config/claude-tenants.zsh`
  composes `personal` and `toysim` entirely out of Max seats with no overflow. Once DO-624
  routes `hspawn` through the gate, refusing empties both tenants for up to a week with
  nothing to borrow. Part A chose to demote rather than refuse for exactly this seat class;
  refusing *here* is strictly worse, because the gate refuses outright where the ranker only
  demotes.
- **A truly-blocked Max seat fails at the first request**, not twenty minutes in. The
  mid-lane death is the failure the gate exists to prevent.

`unknown` keeps the spec's rule, now applying only to the data the rule was written about.

### A second gap the spec does not cover

Part A maps a lapsed week to `_CPM_UW = unknown`, so from `uW` alone the gate cannot tell
"lapsed" from "no `seven_day` block at all". **Decision: when `uW` is `unknown` there is no
aggregate check.** The spec's table already says a lapsed window allows; an absent aggregate
has no row, and refusing on it would invent a refusal class that fires on seats the gate
passes today. The per-model arm is unaffected, and the 5h arms still demand a live, fresh,
dated window, so a cache this broken fails there anyway. Stated as a limitation, with a row.

### What is *not* drift

The rest of Part B stands and is implemented as written: token-based label attribution, the
`7d claude` exclusion, worst-of-matches, and "a lapsed per-model window counts as undated
when `fetched_at` is absent".

---

## Global Constraints

- **Integer arithmetic only.** No `zsh/mathfunc` — the state table's from-scratch PATH
  cannot vouch for a module (`scripts/claude-pick:840-843`).
- **`unknown` is never `0`, and never a silent default.** A tuning value that does not parse
  refuses as `gate-misconfigured`, naming the variable and the value
  (`scripts/claude-pick:96-107`).
- **Never a credential.** The canary row asserts nothing from `usage_cache.json`,
  `profiles.toml`, `config.toml` or `live_sessions/*.json` reaches stdout or stderr on any
  exit path. New reason strings carry labels, percentages, reset instants and the operator's
  own spend figures — never a token.
- **Positional and append-only.** The metrics TSV and the publish records are positional
  (DO-612). Nothing is inserted between existing fields.
- **Suites stay hermetic:** fixture `$HOME`, no reads of the real `~/.clauth`,
  `CLAUDE_CONFIG_DIR` and `HERDR_PANE_ID` cleared.
- **Every fix is pinned by a mutant that dies**, and every mutation is **dry-run for
  applicability first** — a mutation that no longer applies reads exactly like a survivor.
- Green under `LC_ALL=C`; `pre-commit run --all-files` clean; `./scripts/check-claude-md.sh`
  before committing.

**Verified on this machine, 2026-09-19 (do not re-derive):**

- `jq` here is **1.8.1**. Decoding `_CPM_WINDOWS` **requires `jq -R`** — without raw input,
  `jq -r '@base64d | fromjson'` tries to parse the base64 text as JSON and dies with
  `parse error: Invalid numeric literal`. An empty input pipes to no rows and exit 0.
- `weekly_scoped[].utilization` is a **float** and `resets_at` a **string** in the live
  cache; `_CPM_WINDOWS` carries them **unfloored and unparsed**, so the gate must `floor`
  and must call `_claude_ts_delta`.
- `jq`: `null == false` is `false`, so an **absent** `.enabled` does not reach the
  `disabled` arm.
- Label attribution behaves as the spec describes: `7d fable` governs `claude-fable-5-1` and
  `fable` but not `fablex` or `claude-opus-5`; `7d sonnet 5` governs `claude-sonnet-5`;
  `7d opus` governs `opus[1m]`; `7d claude` governs nothing; a label that is not `7d <word>`
  governs nothing.

---

## File Structure

| File | Responsibility in this change |
|---|---|
| `zsh/zshrc.herdr` | `_claude_profile_metrics` jq — add the `disabled` arm. `_claude_pick_publish` — publish `_CPM_WINDOWS` and refine the billing warning. Comments at `~1078-1097`. |
| `scripts/claude-pick` | Declare `_claude_pick_windows` and the `_CLAUDE_TS_*` outputs; set them on the pin path; add the weekly arm after the 5h arms; extend the `gate` JSON object; header comment. |
| `rabota/rabota/budget.py` | Map `gate-spend-wall` to `credential:window` with a detail that names the right wall. |
| `scripts/test-claude-pick.sh` | The metrics rows for `disabled`, the class rows, and all Part B gate rows. |
| `scripts/test-hspawn.sh` | The `disabled` billing-warning wording reaches `claude()`. |
| `rabota/tests/` | `gate-spend-wall` → `credential:window`. |
| `docs/superpowers/specs/2026-09-18-do-621-weekly-picker-design.md` | Rewrite the stale Part B spend table; record the drift resolution. |
| `docs/CLAUDE_ACCOUNT_PICKER.md` | The `disabled` state; the Part B gate section. |
| `CHANGELOG.md` | The release entry. |

`CLAUDE.md` is **not** touched — this is evidence, and evidence goes to `docs/`.

---

## Task 1: `_CPM_SPEND` gains `disabled`

**Files:**
- Modify: `zsh/zshrc.herdr` — the metrics `jq` (~764-767), the field doc (~699), the
  `_claude_pick_class` comment block (~1078-1097), `_claude_pick_publish` (~1893-1898)
- Test: `scripts/test-claude-pick.sh`, `scripts/test-hspawn.sh`

**Interfaces:**
- Produces: `_CPM_SPEND` ∈ `{headroom, none, disabled, unknown}`. `_claude_pick_spend` and
  `--json` `usage.spend` inherit the new value. `_claude_pick_class`'s `== none` test is
  **deliberately unchanged**, so a Max seat still demotes to `weekly-spent`.

- [ ] **Step 1: Write the failing rows** in `scripts/test-claude-pick.sh`, beside the
      existing spend rows. `metrics` prints the `_CPM_*` fields space-separated; add a
      `cut -d' ' -f<n>` for the spend field matching the helper already in the file.

```sh
new_home sp_disabled
# A Max seat: enabled:false, and a `used` that has PASSED its `limit` — the real
# shape (personal-0 reads 134.43 against 125.0), which is why "no credits" is not
# what enabled:false means.
mkprof a1 "{\"plan\":{\"tier\":{\"Max\":20}},\"five_hour\":{\"utilization\":5.0,\"resets_at\":\"$(iso_in 3600)\"},\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 216000)\"},\"spend\":{\"enabled\":false,\"used\":134.43,\"limit\":125.0}}"
check "spend: enabled:false is 'disabled', not 'unknown'" "$(metrics a1 | cut -d' ' -f9)" "disabled"
check "...and a disabled Max seat still only DEMOTES"     "$(_claude_pick_class a1)"      "weekly-spent"

new_home sp_absent_enabled
mkprof a1 "{\"five_hour\":{\"utilization\":5.0,\"resets_at\":\"$(iso_in 3600)\"},\"spend\":{\"used\":1.0,\"limit\":2.0}}"
check "spend: an ABSENT enabled is still 'unknown'" "$(metrics a1 | cut -d' ' -f9)" "unknown"

new_home sp_nonnumeric
mkprof a1 "{\"five_hour\":{\"utilization\":5.0,\"resets_at\":\"$(iso_in 3600)\"},\"spend\":{\"enabled\":true,\"used\":\"x\",\"limit\":2.0}}"
check "spend: a non-numeric used is 'unknown', not 'disabled'" "$(metrics a1 | cut -d' ' -f9)" "unknown"
```

- [ ] **Step 2: Run them and confirm they fail**

```bash
zsh scripts/test-claude-pick.sh 2>&1 | grep -E "spend: (enabled|an ABSENT|a non-numeric)|disabled Max seat"
```

Expected: the `disabled` row FAILS reporting `unknown`; the two `unknown` rows PASS already
(they pin behaviour the change must not break).

- [ ] **Step 3: Add the `disabled` arm.** In `_claude_profile_metrics`'s jq, replace the
      spend-state expression (`zsh/zshrc.herdr:764-767`):

```jq
        (.spend | if type != "object" then null
                  elif .enabled == false then "disabled"
                  elif .enabled == true and (.used | type) == "number" and (.limit | type) == "number"
                    then (if .used < .limit then "headroom" else "none" end)
                  else null end),
```

The `disabled` arm goes **before** the `enabled == true` arm and tests `== false`
explicitly: an absent `.enabled` is `null`, and `null == false` is `false` in jq, so it
still falls through to `null` → `unknown`. Verified 2026-09-19.

Update the field doc at `zsh/zshrc.herdr:699`:

```
#        _CPM_SPEND     headroom | none | disabled | unknown  (spend.enabled/used/limit)
```

- [ ] **Step 4: Retarget the `_claude_pick_class` comment.** The block at
      `zsh/zshrc.herdr:1078-1097` currently says `spend.enabled == false` maps to `unknown`.
      Replace that sentence — the reasoning is unchanged, only the name is:

```
  # A MAX SEAT DEMOTES, IT DOES NOT REFUSE, and that is the whole reason
  # `spend.enabled == false` maps to its OWN state `disabled` (DO-623 split it
  # out of `unknown`; before that split, refusing on `unknown` in the gate would
  # have refused every Max seat). This line tests `none` alone, so `disabled`
  # reaches it and does not fire. The blocking arm above is MEASURED for a Team
  # seat: six "individual spend limit" errors on 2026-09-18. For a Max seat there
  # is no measurement at all — only the field name, and the reasoning "no
  # usage-credit overflow, therefore blocked". Plausible, and not enough:
  # personal-0 reads used 134.43 against a limit of 125.0 with enabled:false, so a
  # Max seat does carry a spend counter that has passed a limit, which is not the
  # shape "no credits" predicts.
```

Keep the two paragraphs that follow (the tenant asymmetry, and "this line fires only where
it was measured") verbatim — they are still exactly right.

- [ ] **Step 5: Refine the billing warning.** `_claude_pick_publish`
      (`zsh/zshrc.herdr:1893-1898`) currently has two arms, so a Max seat is told its
      "spend headroom" is unknown, which is not what `disabled` means. Three arms:

```zsh
  if [[ "$_claude_pick_class" == weekly-spent ]]; then
    case "$_CPM_SPEND" in
      headroom) _claude_pick_warnings+=("$1: weekly window spent — usage bills credits${_CPM_SPEND_TXT:+ ($_CPM_SPEND_TXT)}") ;;
      # A Max seat has no spend limit configured, which is not the same as a
      # spend limit nobody could read. Nobody has watched such a seat block, so
      # the warning says what is known and claims nothing more.
      disabled) _claude_pick_warnings+=("$1: weekly window spent — this seat has no spend limit configured, so what it bills is unmeasured") ;;
      *)        _claude_pick_warnings+=("$1: weekly window spent — usage may bill credits (spend headroom unknown)") ;;
    esac
  fi
```

- [ ] **Step 6: Add the warning-wording rows.** In `scripts/test-claude-pick.sh`, beside the
      existing billing-warning rows; and in `scripts/test-hspawn.sh`, beside the row that
      already asserts `claude()` prints the `headroom` warning, add the `disabled` wording.

```sh
# Pinned so the class is `weekly-spent` deterministically, with the same fixture as sp_disabled.
out="$("$PICK" --dir "$HOME/w" --json 2>/dev/null)"
check "a disabled Max seat's warning does not claim headroom is unknown" \
      "$(jq -r '.warnings[] | select(test("no spend limit configured"))' <<<"$out" | wc -l)" "1"
check "...and does not use the headroom wording" \
      "$(jq -r '[.warnings[] | select(test("spend headroom unknown"))] | length' <<<"$out")" "0"
```

- [ ] **Step 7: Run the suites**

```bash
zsh scripts/test-claude-pick.sh && zsh scripts/test-hspawn.sh
LC_ALL=C zsh scripts/test-claude-pick.sh
```

Expected: all rows PASS, and the asserted row total in each suite is updated to match.

- [ ] **Step 8: Kill the mutants.** Dry-run each for applicability first (`git apply
      --check`, or confirm the target text is present), then apply, run, revert.

| Mutant | Must kill |
|---|---|
| delete the `elif .enabled == false then "disabled"` arm | `spend: enabled:false is 'disabled'` |
| change it to `.enabled != true then "disabled"` | `spend: an ABSENT enabled is still 'unknown'` |
| change `_claude_pick_class`'s test to `== disabled` | `a disabled Max seat still only DEMOTES` |
| change `_claude_pick_class`'s test to `!= headroom` | same row |
| collapse the warning `case` back to two arms | both warning-wording rows |

- [ ] **Step 9: Commit**

```bash
git add zsh/zshrc.herdr scripts/test-claude-pick.sh scripts/test-hspawn.sh
git commit -m "DO-623 Split spend 'disabled' out of 'unknown' so the gate can tell a Max seat from missing data

Part A folded spend.enabled == false into 'unknown' when it took back
refusing Max seats on an inference. Part B's gate refuses on 'unknown',
so implemented as specced it would have refused every Max-seat lane whose
model window is spent. The two cases are different facts and now have
different names; the ranker's behaviour is unchanged (it tests 'none').

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: plumb the per-model windows into `claude-pick`

**Files:**
- Modify: `zsh/zshrc.herdr` — `_claude_pick_publish` (~1885-1887)
- Modify: `scripts/claude-pick` — the globals block (~247-261), the pin path (~373-381)
- Test: `scripts/test-claude-pick.sh`

**Interfaces:**
- Consumes: `_CPM_WINDOWS` (Task 0 / Part A) — base64 of a JSON array of
  `{label, utilization, resets_at}`, or the empty string when there are none.
- Produces: the global `_claude_pick_windows`, set on **both** the ranked path (via
  `_claude_pick_publish`) and the pinned path. Empty string when there are none.

- [ ] **Step 1: Write the failing rows.** A pinned seat and a ranked seat must both
      surface the windows. There is no JSON key yet, so assert through `--explain`'s
      warning channel is wrong; instead assert via a temporary debug print is wrong too.
      Assert the *observable* consequence in Task 3 and, here, assert the plumbing
      directly by sourcing the layer the way the metrics rows already do:

```sh
new_home win_plumb
mkprof a1 "{\"five_hour\":{\"utilization\":5.0,\"resets_at\":\"$(iso_in 3600)\"},\"seven_day\":{\"utilization\":40.0,\"resets_at\":\"$(iso_in 216000)\"},\"weekly_scoped\":[{\"label\":\"7d sonnet 5\",\"utilization\":63.7,\"resets_at\":\"$(iso_in 216000)\"}]}"
# The encoding must survive a label containing SPACES and a resets_at containing
# COLONS — the reason Part A chose one @json array over colon-separated triples.
check "windows: a spaced label and a colon-bearing reset round-trip" \
      "$(metrics a1 | cut -d' ' -f12 | jq -Rr '@base64d | fromjson | .[] | [.label, (.utilization|floor)] | @tsv')" \
      "$(printf '7d sonnet 5\t63')"
check "windows: no weekly_scoped is the empty string, not '[]'" \
      "$(new_home win_none >/dev/null; mkprof a1 '{"five_hour":{"utilization":5.0}}'; metrics a1 | cut -d' ' -f12)" ""
```

`jq -R` is **required** — verified 2026-09-19: without it, jq parses the base64 text as
JSON and dies with `parse error: Invalid numeric literal`. Any row or implementation that
omits `-R` fails in a way that looks like bad data.

- [ ] **Step 2: Run them and confirm the round-trip row fails** (field 12 does not exist
      until the `metrics` helper is extended to print `_CPM_WINDOWS`).

```bash
zsh scripts/test-claude-pick.sh 2>&1 | grep "windows:"
```

- [ ] **Step 3: Extend the `metrics` test helper** in `scripts/test-claude-pick.sh` to
      print `_CPM_WINDOWS` as its last field, appended so no existing `cut -d' ' -f<n>`
      moves. (Positional and append-only, the same rule the TSV follows.)

- [ ] **Step 4: Publish it on the ranked path.** In `_claude_pick_publish`
      (`zsh/zshrc.herdr`, beside `_claude_pick_spend="$_CPM_SPEND"`):

```zsh
  # DO-623: the gate's per-model windows. Published here rather than read from
  # the explain row, which is a RANKING record and deliberately model-blind.
  _claude_pick_windows="$_CPM_WINDOWS"
  _claude_pick_fetched="$_CPM_FETCHED"
```

`_CPM_FETCHED` travels too: Part B's rule "a lapsed per-model window counts as undated when
`fetched_at` is absent" needs it, and the cache *age* has already collapsed the distinction
away.

- [ ] **Step 5: Declare and set them in `scripts/claude-pick`.** Add to the globals block
      (~247-261), beside `_claude_pick_spend`:

```zsh
typeset _claude_pick_windows="" _claude_pick_fetched=unknown _claude_pick_spend_txt=""
# _claude_ts_delta's two outputs, declared for the same reason every other name
# here is: a stray global must not leak in from the environment and be reported
# as a measurement.
typeset _CLAUDE_TS_DELTA=unknown _CLAUDE_TS_ABS=unknown
```

and to the pin path (~373-381), beside `_claude_pick_spend="$_CPM_SPEND"`:

```zsh
  _claude_pick_windows="$_CPM_WINDOWS"; _claude_pick_fetched="$_CPM_FETCHED"
  _claude_pick_spend_txt="$_CPM_SPEND_TXT"
```

`_claude_pick_spend_txt` is new here and mirrors `_CPM_SPEND_TXT` (`"$used of $limit"`,
empty when there is none). Task 3's refusal reason quotes the amounts, and they are the
operator's own settings rather than anything credential-shaped. Set it in **both** sites —
here on the pin path, and in `_claude_pick_publish` beside `_claude_pick_windows` — and
declare it in the globals block:

```zsh
typeset _claude_pick_windows="" _claude_pick_fetched=unknown _claude_pick_spend_txt=""
```

The pin path builds its own explain row and never goes through `_claude_pick_publish`, so
it must set these itself — the same trap the `_r5_at`/`_rw_at` comment there already records.
**This is the path rabota uses**, so missing it means the whole feature is dead for its only
caller while every ranked row stays green.

- [ ] **Step 6: Run the suites** — `zsh scripts/test-claude-pick.sh`. Expected: PASS.

- [ ] **Step 7: Kill the mutants**

| Mutant | Must kill |
|---|---|
| drop `-R` from the row's decode | the round-trip row (parse error) |
| publish `_CPM_WINDOWS` as `[]` when empty | `no weekly_scoped is the empty string` |

The two plumbing sites cannot be mutated into a visible failure yet — Task 3 adds the rows
that kill them, and Task 3's mutant list names both.

- [ ] **Step 8: Commit**

```bash
git add zsh/zshrc.herdr scripts/claude-pick scripts/test-claude-pick.sh
git commit -m "DO-623 Plumb the per-model windows and fetched_at through to claude-pick

Part A published _CPM_WINDOWS for this and nothing read it. Set on BOTH
the ranked path (_claude_pick_publish) and the pinned one, which builds
its own explain row and is the path rabota uses.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: the weekly spend wall in the gate

**Files:**
- Modify: `scripts/claude-pick` — the gate block (~431-502), the `gate` JSON object
  (~604-634), the header comment (~18-38 and ~40-117)
- Test: `scripts/test-claude-pick.sh`

**Interfaces:**
- Consumes: `_claude_pick_windows`, `_claude_pick_fetched`, `_claude_pick_spend`,
  `_claude_pick_uw`, `_claude_pick_rw`, `_claude_pick_rw_at` (Task 2 and Part A);
  `_claude_ts_delta` and `_claude_pick_week_spent` from `zsh/zshrc.herdr`.
- Produces: the new state `gate-spend-wall` (exit 2); `gate.model_window`
  (`{label, utilization, resets_at, state}` or `null`), `gate.bills_credits`
  (`true|false|null`) and `gate.spend` (the four-state string) in `--json`.

### Placement

The whole block goes in the **final `else`** of the existing gate chain, **after** the
`gate_projected > gate_max` test — so a 5h refusal keeps its precedence, exactly as the spec
requires. The current `else gate_verdict=allow` becomes the entry point.

- [ ] **Step 1: Write the failing rows.** All of Part B's table, plus the drift rows. Every
      row here differs from its neighbours in **one** field, so define one fixture builder
      first and parameterise it — a hand-written JSON blob per row is how a row comes to fail
      for a second reason and stop pinning what it names.

```sh
fetched_now_ms() { print -r -- $(( EPOCHSECONDS * 1000 )) }

# One gate fixture. $1 profile, $2 the weekly_scoped array, $3 the spend block,
# $4 seven_day, $5 fetched_at ("" to OMIT the key — the undated case).
# The 5h window is deliberately constant and healthy across every row: this suite
# section is about the WEEKLY arms, and a 5h difference would give a row a second
# way to fail.
mk_gate_prof() {
  local ws="${2:-[]}" sp="${3:-null}" sd="${4:-{\"utilization\":40.0,\"resets_at\":\"$(iso_in 216000)\"}}"
  local fa="${5-$(fetched_now_ms)}"
  mkprof "$1" "{\"five_hour\":{\"utilization\":5.0,\"resets_at\":\"$(iso_in 3600)\"}\
${fa:+,\"fetched_at\":$fa},\"seven_day\":$sd,\"weekly_scoped\":$ws,\"spend\":$sp}"
}

SP_NONE='{"enabled":true,"used":275.23,"limit":275.0}'
SP_ROOM='{"enabled":true,"used":190.77,"limit":250.0}'
SP_OFF='{"enabled":false,"used":134.43,"limit":125.0}'
SP_NADA='null'
WS_FABLE_SPENT="[{\"label\":\"7d fable\",\"utilization\":100.0,\"resets_at\":\"$(iso_in 216000)\"}]"

# Every row below runs the gate the way rabota does — pinned, dry-run, JSON.
gate_json() {   # <profile> <model>
  "$PICK" --profile "$1" --dry-run --json --gate --model "$2" --effort high 2>/dev/null
}
```

```sh
# ---- the model wall: the measured blocking case ------------------------------
new_home gw_model_none
mk_gate_prof a1 "$WS_FABLE_SPENT" "$SP_NONE"
out="$(gate_json a1 claude-fable-5-1)"; rc=$?
check "gate/model: a spent model window with no headroom refuses" "$(jq -r .state <<<"$out")" "gate-spend-wall"
check "...with exit 2"                                "$rc" "2"
check "...naming the window that is spent"            "$(jq -r '.reason | test("7d fable") and test("100%")' <<<"$out")" "true"
check "...and quoting the spend that walled it"       "$(jq -r '.reason | test("275.23")' <<<"$out")" "true"
check "...and no profile is named beside the refusal" "$(jq -r .profile <<<"$out")" "null"
check "...reporting the model window"                 "$(jq -r '.gate.model_window | [.label,(.utilization|tostring),.state] | join("/")' <<<"$out")" "7d fable/100/live"

# ---- billing is allowed, not refused ----------------------------------------
new_home gw_model_headroom
mk_gate_prof a1 "$WS_FABLE_SPENT" "$SP_ROOM"
out="$(gate_json a1 claude-fable-5-1)"; rc=$?
check "gate/model: headroom left ALLOWS"       "$(jq -r .gate.verdict <<<"$out")"        "allow"
check "...with exit 0"                         "$rc"                                    "0"
check "...and says the lane will bill credits" "$(jq -r .gate.bills_credits <<<"$out")" "true"

# ---- the drift: a Max seat ---------------------------------------------------
new_home gw_model_disabled
mk_gate_prof a1 "$WS_FABLE_SPENT" "$SP_OFF"
out="$(gate_json a1 claude-fable-5-1)"; rc=$?
check "gate/model: a Max seat (spend disabled) ALLOWS"  "$(jq -r .gate.verdict <<<"$out")"        "allow"
check "...with exit 0"                                  "$rc"                                    "0"
check "...and does not claim to know whether it bills"  "$(jq -r .gate.bills_credits <<<"$out")" "null"
check "...reporting the spend state that decided it"    "$(jq -r .gate.spend <<<"$out")"         "disabled"

# ---- the drift: genuinely missing data still refuses -------------------------
new_home gw_model_unknown
mk_gate_prof a1 "$WS_FABLE_SPENT" "$SP_NADA"
out="$(gate_json a1 claude-fable-5-1)"
check "gate/model: a spent window with NO spend block refuses" "$(jq -r .state <<<"$out")" "gate-unmeasured"
check "...for the spend reason, not a 5h one"                  "$(jq -r '.reason | test("spend headroom cannot be read")' <<<"$out")" "true"

# ---- the aggregate wall, and the pin -----------------------------------------
new_home gw_agg_none
mk_gate_prof a1 '[]' "$SP_NONE" "{\"utilization\":100.0,\"resets_at\":\"$(iso_in 194400)\"}"
out="$(gate_json a1 claude-opus-5)"
check "gate/aggregate: a pinned seat does not bypass the wall" "$(jq -r .state <<<"$out")" "gate-spend-wall"
check "...naming the aggregate, not a label"                   "$(jq -r '.reason | test("aggregate")' <<<"$out")" "true"
check "...and model_window is null"                            "$(jq -r .gate.model_window <<<"$out")" "null"

# ---- model scoping: the same seat, a different lane --------------------------
new_home gw_scoping
mk_gate_prof a1 "$WS_FABLE_SPENT" "$SP_NONE"
check "gate: an Opus lane on a Fable-spent seat is allowed" \
      "$(jq -r .gate.verdict <<<"$(gate_json a1 claude-opus-5)")" "allow"

# ---- attribution: one fixture, one label, one lane, one expectation ----------
# Each label sits at 100 with spend `none`, so GOVERNS is observable as a refusal
# and "does not govern" as an allow. `verdict` for the allows and `state` for the
# refusals, so neither reads as the other.
for row in \
  '7d fable:claude-fable-5-1:refuse' \
  '7d fable:fable:refuse'            \
  '7d fable:fablex:allow'            \
  '7d sonnet 5:claude-sonnet-5:refuse' \
  '7d opus:opus[1m]:refuse'          \
  '7d claude:claude-fable-5-1:allow' \
  '7d fable:claude-opus-5:allow'     ; do
  lbl="${row%%:*}"; rest="${row#*:}"; mdl="${rest%:*}"; want="${rest##*:}"
  new_home "gw_attr_${lbl// /_}_${mdl//[^a-z0-9]/_}"
  mk_gate_prof a1 "[{\"label\":\"$lbl\",\"utilization\":100.0,\"resets_at\":\"$(iso_in 216000)\"}]" "$SP_NONE"
  got="$(gate_json a1 "$mdl")"
  if [[ "$want" == refuse ]]; then
    check "attribution: '$lbl' governs '$mdl'"        "$(jq -r .state <<<"$got")"        "gate-spend-wall"
  else
    check "attribution: '$lbl' does NOT govern '$mdl'" "$(jq -r .gate.verdict <<<"$got")" "allow"
  fi
done

# ---- worst-of-matches --------------------------------------------------------
# Both labels govern `claude-fable-5`: `7d fable` on the token `fable`, `7d 5` on
# the token `5`. Only the second is spent, so best-of-matches would allow.
new_home gw_worst
mk_gate_prof a1 "[{\"label\":\"7d fable\",\"utilization\":10.0,\"resets_at\":\"$(iso_in 216000)\"},\
{\"label\":\"7d 5\",\"utilization\":100.0,\"resets_at\":\"$(iso_in 216000)\"}]" "$SP_NONE"
out="$(gate_json a1 claude-fable-5)"
check "gate: when two labels govern, the WORST decides" "$(jq -r .state <<<"$out")" "gate-spend-wall"
check "...and the worst one is the one reported"        "$(jq -r .gate.model_window.label <<<"$out")" "7d 5"

# ---- a lapse needs a real clock ---------------------------------------------
WS_FABLE_LAPSED="[{\"label\":\"7d fable\",\"utilization\":100.0,\"resets_at\":\"$(iso_in -3600)\"}]"
new_home gw_lapsed_dated
mk_gate_prof a1 "$WS_FABLE_LAPSED" "$SP_NONE"
out="$(gate_json a1 claude-fable-5-1)"
check "gate: a lapsed model window WITH fetched_at is allowed" "$(jq -r .gate.verdict <<<"$out")" "allow"
check "...and is reported as lapsed"   "$(jq -r .gate.model_window.state <<<"$out")" "lapsed"

new_home gw_lapsed_undated
mk_gate_prof a1 "$WS_FABLE_LAPSED" "$SP_NONE" "" ""     # fifth arg "" OMITS fetched_at
out="$(gate_json a1 claude-fable-5-1)"
check "gate: a lapsed model window WITHOUT fetched_at is undated" "$(jq -r .state <<<"$out")" "gate-unmeasured"
check "...and says so in model_window.state" "$(jq -r .gate.model_window.state <<<"$out")" "undated"

# ---- precedence: a 5h refusal keeps its own state ----------------------------
# u5 at 90 projects to 90 + 115/2 = 147 > 95, so the 5h arm fires; the Fable
# window is ALSO spent with spend `none`, so without the ordering this reports
# gate-spend-wall instead.
new_home gw_precedence
mkprof a1 "{\"five_hour\":{\"utilization\":90.0,\"resets_at\":\"$(iso_in 3600)\"},\"fetched_at\":$(fetched_now_ms),\
\"seven_day\":{\"utilization\":40.0,\"resets_at\":\"$(iso_in 216000)\"},\"weekly_scoped\":$WS_FABLE_SPENT,\"spend\":$SP_NONE}"
check "gate: a 5h refusal keeps its state when a window is also spent" \
      "$(jq -r .state <<<"$(gate_json a1 claude-fable-5-1)")" "gate-projected"

# ---- the aggregate we cannot read -------------------------------------------
new_home gw_agg_unknown
mkprof a1 "{\"five_hour\":{\"utilization\":5.0,\"resets_at\":\"$(iso_in 3600)\"},\"fetched_at\":$(fetched_now_ms),\"spend\":$SP_NONE}"
check "gate: an unreadable aggregate does not refuse (the 5h arms still apply)" \
      "$(jq -r .gate.verdict <<<"$(gate_json a1 claude-opus-5)")" "allow"

# ---- a lapsed aggregate, which reaches the gate as `unknown` too ------------
new_home gw_agg_lapsed
mk_gate_prof a1 '[]' "$SP_NONE" "{\"utilization\":100.0,\"resets_at\":\"$(iso_in -3600)\"}"
check "gate: a lapsed aggregate does not refuse" \
      "$(jq -r .gate.verdict <<<"$(gate_json a1 claude-opus-5)")" "allow"

# ---- the threshold is a tuning value, and a bad one refuses -----------------
new_home gw_badthreshold
mk_gate_prof a1 "$WS_FABLE_SPENT" "$SP_ROOM"
check "gate: CLAUDE_PICK_WEEK_SPENT=oops refuses rather than defaulting to 100" \
      "$(CLAUDE_PICK_WEEK_SPENT=oops jq -r .state <<<"$(CLAUDE_PICK_WEEK_SPENT=oops gate_json a1 claude-fable-5-1)")" \
      "gate-misconfigured"

# ---- no --gate is still no gate object --------------------------------------
new_home gw_off
mk_gate_prof a1 "$WS_FABLE_SPENT" "$SP_NONE"
check "gate: without --gate the spent window changes nothing" \
      "$("$PICK" --profile a1 --dry-run --json 2>/dev/null | jq -r '.gate // "null"')" "null"
```

`iso_in` must accept a **negative** offset for the two lapsed fixtures; check the existing
helper and extend it if it does not. `mk_gate_prof`'s fifth argument uses `${5-...}`
(unset-only default), so passing `""` omits `fetched_at` while omitting the argument stamps
it — the distinction the undated rows turn on.

- [ ] **Step 2: Run them and confirm every new row fails**

```bash
zsh scripts/test-claude-pick.sh 2>&1 | grep -E "^(FAIL|not ok).*gate/" | wc -l
```

Expected: every `gate/` row fails; no existing row does.

- [ ] **Step 3: Add the helpers** to `scripts/claude-pick`, above the gate block.

```zsh
# WHICH PER-MODEL LABEL GOVERNS A LANE (DO-623). clauth v0.15.2 builds a label as
# `format!("7d {}", name.to_lowercase())`, taking `name` from the scope's model
# display_name or, failing that, the surface name — so the word after "7d " is the
# model name and everything after it is decoration ("7d sonnet 5").
#
# The lane's model id is normalised by dropping a trailing "[...]" (opus[1m] ->
# opus) and split on "-" into tokens; a label governs when its first word equals
# one of those tokens. WHOLE TOKENS, NEVER SUBSTRINGS: a substring test makes
# `fablex` match `7d fable` and refuse a lane on a window that is not its own.
#
# A label whose first word is `claude` is IGNORED — every model id here begins
# `claude-`, so it would govern every lane and turn one spent surface window into
# a refusal for the whole seat. Any other surface-scoped label is unknown today;
# the worst it can cause is a refusal on a seat that is also out of spend headroom.
_gate_label_governs() {   # <label> <model-id>
  local label="$1" model="$2" first base tok
  [[ "$label" == '7d '* ]] || return 1
  first="${${label#7d }%% *}"
  [[ -n "$first" && "$first" != claude ]] || return 1
  base="${model%%\[*}"
  for tok in "${(@s:-:)base}"; do
    [[ "$tok" == "$first" ]] && return 0
  done
  return 1
}
```

- [ ] **Step 4: Add the weekly arm.** Replace the final `else gate_verdict=allow` of the
      existing chain with the block below. It runs once, after every 5h arm has passed.

```zsh
      else
        # --- DO-623: THE WEEKLY SPEND WALL, FOR THE AGGREGATE AND FOR THE LANE'S
        # MODEL. A spent window is not a wall while spend headroom lasts — it
        # BILLS, measured 2026-09-18 (+$0.31 and +$0.28 within four minutes of a
        # window reaching 100). Once headroom is gone it BLOCKS: six "You've hit
        # your individual spend limit" errors on a seat at 100% with $275.23 of
        # $275. The gate refuses only what would be BLOCKED; a lane that would
        # bill is allowed and says so. Spending policy beyond that is not the
        # gate's job (design decision 5).
        #
        # SPEND `disabled` ALLOWS, AND THAT IS DELIBERATE. It means enabled:false
        # — a Max seat — which is a MEASURED absence of a spend mechanism, not
        # missing data. Nobody has ever watched such a seat block on a spent
        # window; refusing on the field name is the #123 failure. Both non-work
        # tenants are composed entirely of Max seats with no overflow, so a
        # refusal empties them for up to a week, which is the same trade Part A
        # declined to make in the ranker. `unknown` — no spend block at all, or a
        # non-numeric used/limit — still refuses: THAT is the missing data the
        # "never optimistic" rule was written about.
        #
        # AN UNREADABLE AGGREGATE DOES NOT REFUSE. _CPM_UW is `unknown` both for a
        # LAPSED week (the metrics layer maps it so) and for an absent seven_day
        # block, and the spec allows a lapse. Refusing on the pair would invent a
        # refusal that fires on seats the gate passes today; the 5h arms above
        # still demand a live, fresh, dated window, so a cache this broken has
        # already been refused.
        _claude_pick_week_spent || {
          gate_verdict=refuse; _claude_pick_state=gate-misconfigured
          _claude_pick_reason="CLAUDE_PICK_WEEK_SPENT must be a non-negative integer (percent of the weekly window), got '$CLAUDE_PICK_WEEK_SPENT'; refusing rather than guessing a threshold"
          REPLY=""; rc=2
        }
        if (( rc == 0 )); then
          gate_week_spent=$_CLAUDE_PICK_WEEK_SPENT
          gate_bills=false
          # Each candidate is one TAB-separated row: label, utilization, resets_at.
          # The aggregate goes in under the reserved label `aggregate`, which is not
          # a `7d ` label and so can never be confused with a per-model one.
          gate_rows=()
          [[ "$_claude_pick_uw" == <-> ]] && \
            gate_rows+=( "aggregate"$'\t'"$_claude_pick_uw"$'\t'"$_claude_pick_rw"$'\t'"$_claude_pick_rw_at" )
          if [[ -n "$_claude_pick_windows" ]]; then
            # `jq -R`: the value is base64 TEXT. Without raw input jq parses it as
            # JSON and dies — measured 2026-09-19, "Invalid numeric literal".
            # `floor` here because weekly_scoped carries a float and every figure
            # this file compares is an integer.
            while IFS= read -r gate_line; do
              [[ -n "$gate_line" ]] || continue
              gate_f=( "${(@ps:\t:)gate_line}" )
              _gate_label_governs "${gate_f[1]}" "$gate_model" || continue
              _claude_ts_delta "${gate_f[3]}"
              gate_rows+=( "${gate_f[1]}"$'\t'"${gate_f[2]}"$'\t'"$_CLAUDE_TS_DELTA"$'\t'"$_CLAUDE_TS_ABS" )
            done < <(print -r -- "$_claude_pick_windows" | jq -Rr '
                       @base64d | fromjson | .[]
                       | [ .label,
                           (.utilization | if type == "number" then floor else "" end),
                           (.resets_at // "") ] | @tsv' 2>/dev/null)
          fi
          # Evaluate every candidate and let the WORST govern: a refusal beats an
          # allow, and among equals the higher utilization is reported. Taking only
          # the highest-utilization window would let a lapsed 100 mask a live 99
          # that is out of headroom.
          for gate_line in "${gate_rows[@]}"; do
            gate_f=( "${(@ps:\t:)gate_line}" )
            gate_w_label="${gate_f[1]}"; gate_w_util="${gate_f[2]}"
            gate_w_delta="${gate_f[3]}"; gate_w_at="${gate_f[4]}"
            [[ "$gate_w_util" == <-> ]] || continue
            (( gate_w_util >= gate_week_spent )) || continue
            if [[ "$gate_w_delta" != (-|)<-> ]]; then
              gate_w_state=undated
            elif (( gate_w_delta < 0 )); then
              # A LAPSED WINDOW COUNTS AS UNDATED WITHOUT A REAL CLOCK. With only
              # the file mtime to go on, a plan-only rewrite keeps a cache "fresh"
              # while the window lapsed days ago and has since refilled — two
              # profiles here went 7% to 100% in forty minutes.
              [[ "$_claude_pick_fetched" == <-> ]] && gate_w_state=lapsed || gate_w_state=undated
            else
              gate_w_state=live
            fi
            case "$gate_w_state" in
              lapsed) gate_w_verdict=allow ;;
              undated) gate_w_verdict=refuse; gate_w_state_reason="its reset cannot be dated" ;;
              live)
                case "$_claude_pick_spend" in
                  headroom) gate_w_verdict=allow; gate_bills=true ;;
                  disabled) gate_w_verdict=allow; [[ "$gate_bills" == false ]] && gate_bills=null ;;
                  none)     gate_w_verdict=refuse; gate_w_state_reason="and the seat has no spend headroom left" ;;
                  *)        gate_w_verdict=refuse; gate_w_state_reason="and the seat's spend headroom cannot be read" ;;
                esac ;;
            esac
            _gate_keep_worst || continue     # sets gate_mw_* when this row is the worst so far
          done
          if [[ "$gate_mw_verdict" == refuse ]]; then
            gate_verdict=refuse
            if [[ "$gate_mw_state" == undated ]]; then
              _claude_pick_state=gate-unmeasured
            elif [[ "$_claude_pick_spend" == none ]]; then
              _claude_pick_state=gate-spend-wall
            else
              _claude_pick_state=gate-unmeasured
            fi
            _claude_pick_reason="$REPLY's ${gate_mw_label} window is ${gate_mw_util}% used (resets $(text_instant "$gate_mw_at")) ${gate_mw_reason}${_claude_pick_spend_txt:+ ($_claude_pick_spend_txt)}"
            REPLY=""; rc=2
          else
            gate_verdict=allow
          fi
        fi
      fi
```

`_gate_keep_worst` goes beside `_gate_label_governs`. It promotes the current row into the
`gate_mw_*` set when `(verdict-rank, utilization)` beats what is held, `refuse` ranking above
`allow`. It reads and writes these names directly — `claude-pick` is a script, and every one
of them is declared in the globals block for exactly that reason, so no `local` anywhere.

```zsh
# THE WORST CANDIDATE GOVERNS, and "worst" is a refusal first, then the higher
# utilization. Highest-utilization-alone would let a lapsed 100 (which allows)
# mask a live 99 that is out of headroom (which refuses).
_gate_keep_worst() {
  local rank held
  [[ "$gate_w_verdict" == refuse ]] && rank=2 || rank=1
  [[ "$gate_mw_verdict" == refuse ]] && held=2 || held=${gate_mw_label:+1}
  held="${held:-0}"
  (( rank > held || ( rank == held && gate_w_util > gate_mw_util ) )) || return 1
  gate_mw_label="$gate_w_label"; gate_mw_util="$gate_w_util"; gate_mw_at="$gate_w_at"
  gate_mw_state="$gate_w_state"; gate_mw_verdict="$gate_w_verdict"
  gate_mw_reason="$gate_w_state_reason"
  return 0
}
```

Note the field mapping: the loop writes `gate_w_state_reason`, and this is the one place it
becomes `gate_mw_reason` — the name the refusal string interpolates. A mismatch here is
silent, producing a refusal whose sentence trails off.

Declare in the globals block, all defaulting empty:

```zsh
typeset gate_week_spent="" gate_bills=false gate_line=""
typeset gate_w_label="" gate_w_util="" gate_w_delta="" gate_w_at=""
typeset gate_w_state="" gate_w_verdict="" gate_w_state_reason=""
typeset gate_mw_label="" gate_mw_util=0 gate_mw_at="" gate_mw_state="" \
        gate_mw_verdict="" gate_mw_reason=""
typeset -a gate_rows=() gate_f=()
```

`gate_mw_util` starts at `0`, not empty: `_gate_keep_worst` compares it arithmetically on
the first call, and an empty word there is a comparison against an unset parameter.

- [ ] **Step 5: Extend the `gate` JSON object** (`scripts/claude-pick:604-634`). Three new
      keys; existing ones untouched.

```zsh
    --argjson gate_bills  "$(json_tristate "$gate_bills")" \
    --arg    gate_spend   "${_claude_pick_spend:-}" \
    --argjson gate_mw     "$(json_model_window)" \
```

```jq
       gate: (if $gate_on == 1 then { ...existing keys...,
                                      model_window:  $gate_mw,
                                      bills_credits: $gate_bills,
                                      spend:         (if $gate_spend == "" then null else $gate_spend end),
                                      verdict: (...) }
              else null end),
```

with two helpers beside `json_num`:

```zsh
# true | false | null, and NEVER a bare word. `null` is the Max-seat answer —
# "this seat has no spend limit configured, so what the lane bills is unmeasured"
# — and it must be distinguishable from `false` ("the lane is free").
json_tristate() {
  case "${1:-}" in (true) print -r -- true ;; (false) print -r -- false ;; (*) print -r -- null ;; esac
}

# The window the decision was made on, or null when no per-model window governed
# the lane. utilization is a JSON number so a consumer need not parse a percent
# sign; resets_at is RFC 3339 UTC, the same rendering as every other instant here.
json_model_window() {
  [[ -n "$gate_mw_label" && "$gate_mw_label" != aggregate ]] || { print -r -- null; return 0 }
  jq -n --arg label "$gate_mw_label" --arg state "$gate_mw_state" \
        --argjson util "$(json_num "$gate_mw_util")" \
        --argjson at "$(json_instant "$gate_mw_at")" \
        '{label: $label, utilization: $util, resets_at: $at, state: $state}'
}
```

- [ ] **Step 6: Update the header comment.** Three edits in `scripts/claude-pick`:
      the exit-code 2 paragraph (~24-27) gains `gate-spend-wall`; a new **THE WEEKLY SPEND
      WALL** section after **A ROLLED WINDOW IS AN UNMEASURED ONE TOO** (~79-94) carrying
      the four-state table and the `disabled` reasoning; and the `usage.spend` rough-edges
      comment (~562-574), which currently says *"nothing in this repo reads the key yet and
      Part B's per-model gate (DO-623) will"* — it does now, so say which arm reads it and
      that the lapse edge it warns about is the reason the gate skips an `unknown` aggregate.
      Also extend `usage()`'s `--gate` description (~159-165).

- [ ] **Step 7: Run everything**

```bash
zsh scripts/test-claude-pick.sh && zsh scripts/test-hspawn.sh && zsh scripts/test-claude-doctor.sh
LC_ALL=C zsh scripts/test-claude-pick.sh
zsh -n scripts/claude-pick && shellcheck -x scripts/test-claude-pick.sh
```

Expected: all PASS, each suite's asserted row total updated, and the **canary** row still
green — the new reason strings quote a label, a percentage, an instant and the operator's own
spend figures, none of which is a credential, but the row is what proves it.

- [ ] **Step 8: Kill the mutants.** Dry-run each for applicability first.

| Mutant | Must kill |
|---|---|
| `_gate_label_governs` matches by substring (`[[ "$first" == *"$tok"* ]]`) | `7d fable` x `fablex` |
| drop the `!= claude` exclusion | `7d claude` x `claude-fable-5-1` |
| drop the `${model%%\[*}` strip | `7d opus` x `opus[1m]` |
| `_gate_keep_worst` ranks `allow` above `refuse` (best-of-matches) | `when two labels govern, the WORST decides` |
| treat `disabled` as `none` | `a Max seat (spend disabled) ALLOWS` |
| treat `unknown` as `disabled` | `a spent window with NO spend block refuses` |
| refuse on `headroom` | `headroom left ALLOWS` |
| drop the `fetched_at` test in the lapse arm | `a lapsed model window WITHOUT fetched_at is undated` |
| move the block **above** the `gate_projected` test | `a 5h refusal keeps its state` |
| refuse when `_claude_pick_uw` is `unknown` | `an unreadable aggregate does not refuse` |
| let `_claude_pick_week_spent`'s fallback stand (drop the `\|\|` arm) | `CLAUDE_PICK_WEEK_SPENT=oops refuses` |
| delete `_claude_pick_windows="$_CPM_WINDOWS"` from the **pin** path (Task 2) | every `--profile` model row |
| delete it from `_claude_pick_publish` (Task 2) | the ranked-path model row |
| `jq` decode without `-R` | every model row (no windows parsed) |

- [ ] **Step 9: Commit**

```bash
git add scripts/claude-pick scripts/test-claude-pick.sh
git commit -m "DO-623 Refuse a gated lane whose model's weekly window is spent and walled

The gate only ever asked about the 5h window, so a lane could pass it and
die at once on a spent weekly window with no usage-credit headroom left
(measured 2026-09-18: six 'individual spend limit' errors at seven_day 100
with \$275.23 of \$275). It now checks the aggregate and the lane's own
model window, after every 5h arm so their precedence is unchanged.

Refuses only what would be BLOCKED: a lane that would bill is allowed and
reports bills_credits. A Max seat (spend 'disabled') is allowed too — that
absence is measured, nobody has watched such a seat block, and both
non-work tenants are all-Max with no overflow.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: rabota reports a measured refusal as measured

**Files:**
- Modify: `rabota/rabota/budget.py:44-79`
- Test: rabota's test for `credential_gate`

**Interfaces:**
- Consumes: `claude-pick --json` `state == "gate-spend-wall"` and `gate.spend` (Task 3).
- Produces: `{"code": "credential:window"}` for that state.

Without this, a spend-wall refusal falls to the `else` and is reported as
`credential:unmeasured` — "could not measure" for the one refusal that is entirely measured.

- [ ] **Step 1: Write the failing test** beside rabota's existing `credential_gate` tests,
      with a stub runner returning exit 2 and the Task 3 JSON shape.

```python
def test_gate_spend_wall_is_a_measured_window_refusal(stub_runner):
    stub_runner.queue(code=2, out=json.dumps({
        "profile": None, "state": "gate-spend-wall",
        "reason": "q1's 7d fable window is 100% used (resets 2026-09-21T09:00:00Z) "
                  "and the seat has no spend headroom left ($275.23 of $275)",
        "usage": {"five_hour": 12, "weekly": 100, "cache_age_s": 4, "spend": "none"},
        "resets_at": {"five_hour": "2026-09-19T20:00:00Z", "weekly": "2026-09-21T09:00:00Z"},
        "gate": {"verdict": "refuse", "spend": "none", "bills_credits": None,
                 "model_window": {"label": "7d fable", "utilization": 100,
                                  "resets_at": "2026-09-21T09:00:00Z", "state": "live"}},
    }))
    out = credential_gate(stub_runner, "q1", "claude-fable-5-1", "high", 30)
    assert out["ok"] is False
    assert out["code"] == "credential:window"      # not "credential:unmeasured"
    assert "7d fable" in out["detail"]


def test_gate_spend_wall_detail_does_not_fall_back_to_the_5h_sentence(stub_runner):
    # The gate always sets a reason; if a future one does not, the fallback must
    # still name the wall that fired rather than a projection that never ran.
    stub_runner.queue(code=2, out=json.dumps({
        "state": "gate-spend-wall", "reason": "",
        "usage": {"five_hour": 12}, "gate": {"verdict": "refuse", "spend": "none"},
    }))
    out = credential_gate(stub_runner, "q1", "claude-fable-5-1", "high", 30)
    assert "projected" not in out["detail"]
    assert "spend" in out["detail"]
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `cd rabota && python -m pytest tests -k spend_wall -v`
Expected: FAIL — `credential:unmeasured` != `credential:window`.

- [ ] **Step 3: Implement.** Replace the state branch at `rabota/rabota/budget.py:73-78`:

```python
    if state in ("gate-projected", "exhausted", "gate-spend-wall"):
        out["code"] = "credential:window"
        if not out["detail"]:
            out["detail"] = (
                f"{seat} weekly window spent, spend {gate.get('spend')}"
                if state == "gate-spend-wall"
                else f"{seat} 5h window: {usage.get('five_hour')}% now, projected {gate.get('projected')}%"
            )
    else:  # gate-unmeasured, gate-misconfigured, no-profiles, bad-table, backpressure,
           # or exit 0 without a verdict
        out["code"] = "credential:unmeasured"
        out["detail"] = out["detail"] or f"claude-pick state {state!r} with no gate verdict"
```

and update the docstring at `:47-50` so `credential:window` names the spend wall — an
unlisted state silently reporting a measured refusal as unmeasured is the defect this fixes,
and the docstring is where the next reader checks the list.

- [ ] **Step 4: Run the tests** — `cd rabota && python -m pytest tests -v`. Expected: PASS.

- [ ] **Step 5: Kill the mutants**

| Mutant | Must kill |
|---|---|
| remove `"gate-spend-wall"` from the tuple | the first test |
| keep the single 5h fallback string | the second test |

- [ ] **Step 6: Commit**

```bash
git add rabota/rabota/budget.py rabota/tests
git commit -m "DO-623 Map gate-spend-wall to credential:window in rabota's budget

An unlisted state falls to credential:unmeasured, which reports the one
entirely measured refusal as 'could not measure'.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: resolve the spec, and record the evidence

The spec section is stale as written and must not be left to be read as current. Docs are
one task because a reviewer accepts or rejects the *resolution*, not each file.

**Files:**
- Modify: `docs/superpowers/specs/2026-09-18-do-621-weekly-picker-design.md` — Part B
- Modify: `docs/CLAUDE_ACCOUNT_PICKER.md`
- Modify: `CHANGELOG.md`
- Create: `docs/superpowers/plans/2026-09-19-do-623-gate-model-window.md` (this plan)

- [ ] **Step 1: Rewrite the spec's Part B spend table** (`:206-218`) to the four-state form,
      and add a dated note directly under it:

```markdown
**Drift resolved 2026-09-19 (DO-623).** The `unknown` row above was written when
`unknown` meant "no spend block on disk". Part A's final revision also mapped
`spend.enabled == false` — every Max seat — to `unknown`, so the table as first
written would have refused every Max-seat lane whose model window is spent.
`_CPM_SPEND` therefore gains a fourth state, `disabled`, and the gate allows it:
the utilization is measured and only its consequence is not, nobody has watched a
Max seat block on a spent window, and `personal` and `toysim` are composed
entirely of Max seats with no overflow — the same asymmetry Part A resolved by
demoting rather than refusing. `unknown` keeps the original rule, now applying
only to the missing data it was written about.

**A second gap, decided here rather than left open.** Part A maps a lapsed week to
`_CPM_UW = unknown`, so the gate cannot tell a lapsed aggregate from an absent one.
The aggregate arm therefore does not run at all when `uW` is `unknown`: the table's
`lapsed -> allow` row already covers half of it, and refusing on the other half
would invent a refusal that fires on seats the gate passes today. The per-model arm
is unaffected, and the 5h arms still require a live, fresh, dated window.
```

Also update the spec's Part B test table (`:303-325`): the `spend unknown -> gate-unmeasured`
row splits into `disabled -> allow` and `unknown -> refuse`, and the mutant list gains
"treat `disabled` as `none`" and "treat `unknown` as `disabled`".

- [ ] **Step 2: Update `docs/CLAUDE_ACCOUNT_PICKER.md`.** In the DO-621 section, the
      sentence at `:400-406` says `enabled == false` maps to **`unknown`** — it now maps to
      **`disabled`**; the *reasoning* around it is unchanged and stays verbatim. Then add a
      **The gate and the model's own window (DO-623)** section: the four-state table, the
      `disabled` decision with its four reasons, label attribution and the `7d claude`
      exclusion, the "lapsed needs `fetched_at`" rule, the unreadable-aggregate limitation,
      and the row pointers (`scripts/test-claude-pick.sh`, `scripts/test-hspawn.sh`,
      rabota's tests).

      **One prose home per fact:** the reasoning lives here; `scripts/claude-pick`'s header
      keeps the operative rule and the table only, and `CLAUDE.md` gains nothing.

- [ ] **Step 3: `CHANGELOG.md`** — one entry naming the new `gate-spend-wall` state, the
      three new `gate` JSON keys, and `usage.spend`'s new `disabled` value as the one
      interface change a consumer could notice.

- [ ] **Step 4: Verify the guards**

```bash
./scripts/check-claude-md.sh
pre-commit run --all-files
```

Expected: both clean. `check-claude-md.sh` also enforces reachability — this plan and the
spec are already linked from `docs/README.md`'s index; confirm, and add the row if not.

- [ ] **Step 5: Commit**

```bash
git add docs CHANGELOG.md
git commit -m "docs: resolve the DO-621 spec's stale Part B spend table (DO-623)

The table's \`unknown -> refuse\` row was written when unknown meant 'no
spend block'. It now also means a Max seat, so the row as written refused
every Max-seat lane. Records the four-state split and the two decisions.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Verification

Run from the worktree, never `~/.dotfiles`.

```bash
# 1. The suites, twice — the second run is the locale the state tables compare under.
zsh scripts/test-claude-pick.sh
zsh scripts/test-hspawn.sh
zsh scripts/test-claude-doctor.sh
LC_ALL=C zsh scripts/test-claude-pick.sh
LC_ALL=C zsh scripts/test-hspawn.sh
cd rabota && python -m pytest tests -v && cd ..

# 2. Each suite asserts its own row total. Confirm each one was RAISED by the
#    number of rows added — a row count detects a skipped check, never a hollow one,
#    which is what the mutation sweep is for.

# 3. Syntax and lint.
zsh -n scripts/claude-pick && bash -n install
pre-commit run --all-files
./scripts/check-claude-md.sh

# 4. End to end against the REAL cache, read-only. quantivly-1 is a Team seat with
#    7d fable at 100 and spend headroom, so a Fable lane must be ALLOWED and must
#    say it will bill; an Opus lane must be allowed with bills_credits false.
zsh -ic 'scripts/claude-pick --profile quantivly-1 --dry-run --json --gate \
           --model claude-fable-5-1 --effort high | jq "{state, verdict:.gate.verdict, \
           bills:.gate.bills_credits, spend:.gate.spend, mw:.gate.model_window}"'
zsh -ic 'scripts/claude-pick --profile quantivly-1 --dry-run --json --gate \
           --model claude-opus-5 --effort high | jq "{verdict:.gate.verdict, bills:.gate.bills_credits}"'

# 5. The old contract still holds: no --gate means gate: null, and a 5h refusal
#    still reports its own state.
zsh -ic 'scripts/claude-pick --profile quantivly-1 --dry-run --json | jq .gate'   # null
```

`--dry-run` throughout: it skips the account-dir builder, which reconciles a profile's
credential store as a side effect. **Nothing in this plan writes to `~/.clauth/`, and
`clauth <profile>` is never run.**

## Not in scope

- **DO-624** (`hspawn` through the gate) and **ZviBaratz/herdr-draft#185** (herdr-draft
  passing the model). Filed separately. Part B protects rabota lanes as soon as it lands;
  `hspawn` does not use the CLI, and herdr-draft passes no model, so neither reaches the new
  arm today.
- **A model-aware ranker.** The ranker stays model-blind (design decision 2).
- **rabota surfacing `bills_credits`.** The key exists for it; consuming it is a spending
  policy, and decision 5 keeps policy out of the gate.
- **`CLAUDE.md`.** Evidence goes to `docs/`; the operative rules already reachable there.

## Seat budget

quantivly-1 is past its weekly cap and billing usage credits. Check before any expensive
step and again after a long stretch:

```bash
jq -c '{d7:.seven_day.utilization, spend:"\(.spend.used)/\(.spend.limit)"}' \
   ~/.clauth/profiles/quantivly-1/usage_cache.json
```

**Past $235, stop and report.** The window resets 2026-09-21T09:00Z.

Readings taken while writing this plan, 2026-09-19:

| moment | spend |
|---|---|
| start of the planning session | $212.01 / $250 |
| plan complete | $226.77 / $250 |

**$8 of headroom against the stop line, not $23.** How much of that $14.76 is this session
and how much is the other sessions drawing on the same seat cannot be separated from the
counter. Either way the implementation does not fit before the stop line: **Task 1 is the
most that should be attempted on this seat**, and even that should re-check the counter
before it starts. The realistic plan is to wait for the 2026-09-21T09:00Z reset, or move the
implementation to a seat with a live window.

### Step 0, before Task 1

This plan is written to the plan-mode scratch file, which is session-scoped. Commit it to
the repo first — it is the deliverable DO-623 asks for:

```bash
cp <plan-mode path> docs/superpowers/plans/2026-09-19-do-623-gate-model-window.md
git add docs/superpowers/plans/2026-09-19-do-623-gate-model-window.md
git commit -m "DO-623 Plan: the gate refuses a lane whose model's weekly window is spent

Resolves the DO-621 spec's Part B drift: 'unknown' spend now also means a
Max seat, so the table as approved would have refused every Max-seat lane.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
