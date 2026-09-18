# DO-621 Part A: weekly windows and the spend wall in the account ranker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The account ranker reads the aggregate weekly window only, treats a lapsed week as unmeasured, recognises the spend wall (spent week + no spend headroom = blocked), prefers the seat whose week resets soonest, dates caches from clauth 0.15.2's `fetched_at`, and warns when a pick will bill usage credits.

**Architecture:** All ranking logic lives in `zsh/zshrc.herdr` (`_claude_profile_metrics` → `_claude_pick_class` / `_claude_pick_score` → `_claude_pick_for_dir` → `_claude_pick_publish`). `scripts/claude-pick` is the CLI over the same functions and adds `--json`/`--explain`. `claude-doctor` in `zsh/functions/claude.sh` has its own cache-age line that must agree with the ranker. Every change is proven by a hermetic state-table row, and every fix is pinned by a mutant that must die.

**Tech Stack:** zsh (integer arithmetic only, no `zsh/mathfunc`), `jq`, bash test harnesses (`scripts/test-*.sh`).

**Spec:** `docs/superpowers/specs/2026-09-18-do-621-weekly-picker-design.md` (approved 2026-09-18). This plan covers **Part A only**. Part B (the gate: DO-623) gets its own plan once this lands.

## Global Constraints

- **jq output must be version-independent.** jq 1.7+ preserves number literals (`250.0` stays `250.0`); jq 1.6 prints `250`; CI runs both. Any number that reaches a message or an asserted string goes through arithmetic first (`. * 100 | round / 100`), and rows compare numbers numerically, never as literal JSON text.
- Integer arithmetic only in `zshrc.herdr`; no new external tools in any checker (jq is already a dependency; do **not** add `base64`, `python3`, `awk` to a code path the suites run).
- Positional records are **append-only**: the metrics TSV, `_claude_pick_explain`, `_claude_pick_exhausted`. Never insert a field; every reader indexes by position.
- Defaults, verbatim: `CLAUDE_PICK_W_WEEK_EXPIRE` = **200**; `CLAUDE_PICK_RR_BAND` = 800 (unchanged); `CLAUDE_PICK_WEEK_SPENT` = 100 (unchanged); `CLAUDE_PICK_WEEK_LOW` = 15 (unchanged, `weekf` stays); future-`fetched_at` tolerance = **60 s**; week length = **604800 s**.
- Missing data never escalates to a refusal in the ranker: spend `unknown` is never treated as `none`.
- Hermetic tests: fixture `$HOME` only; never read the real `~/.clauth`. Never print any `credentials.json`.
- Do not touch Part B: no gate per-model logic, no `rabota/` changes.
- The Bash tool's shell is zsh; run the suites with `bash scripts/test-….sh`.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- Line numbers below are from commit `18a8590`; they shift as tasks land. Locate code by the quoted text, not the number.

---

### Task 0: Branch

- [ ] **Step 1: Create the implementation branch from the commit that carries this plan and the spec**

```bash
git switch -c zvi/do-621-rank-claude-pick-on-weekly-reset-time-and-stop-a-lapsed
```

(The name is Linear's `branchName` for DO-621. If executing in a fresh worktree instead, base it on the commit that added this plan file.)

- [ ] **Step 2: Baseline — all three suites green before any change**

Run: `bash scripts/test-claude-pick.sh 2>&1 | tail -1; bash scripts/test-hspawn.sh 2>&1 | tail -1; bash scripts/test-claude-doctor.sh 2>&1 | tail -1`
Expected: three `=== N passed, 0 failed ===` lines. Record the three N values; later tasks report deltas against them.

---

### Task 1: Metrics — aggregate `uW`, lapse, spend, `fetched_at`, per-model windows

**Files:**
- Modify: `zsh/zshrc.herdr` — `_claude_profile_metrics` (~660–762) and every `_CPM_*` localisation site (~879, ~1161, ~1312, ~1584)
- Modify: `scripts/claude-pick` — the pinned-path `typeset _CPM_…` line (~370)
- Test: `scripts/test-claude-pick.sh` — helpers near `metrics()` (~97), rows in "metrics: absent is its own state" (~103–125)

**Interfaces:**
- Produces (globals set by `_claude_profile_metrics <profile>`):
  - `_CPM_UW` — `seven_day.utilization` floored, or `unknown` (absent, or **lapsed**: `seven_day.resets_at` parses to the past)
  - `_CPM_SPEND` — `headroom` | `none` | `unknown`
  - `_CPM_SPEND_TXT` — e.g. `$190.77 of $250`, or empty
  - `_CPM_FETCHED` — `fetched_at` epoch **ms** as an integer string, or `unknown`
  - `_CPM_WINDOWS` — base64 of a JSON array `[{label, utilization, resets_at}]` (empty string when absent). Base64 because `@tsv` escapes backslashes and the payload must round-trip byte-exact; it is still the spec's "one `@json` array", just transported safely. Part B decodes it with `jq '@base64d | fromjson'`.
- Unchanged: `_CPM_U5 _CPM_R5 _CPM_R5_AT _CPM_RW _CPM_RW_AT _CPM_AGE _CPM_TIER`.

- [ ] **Step 1: Add fixture helpers to `scripts/test-claude-pick.sh`, directly after the `metrics()` helper**

```bash
# An RFC 3339 instant N seconds from now (negative = past), in clauth's own shape.
# GNU date, as the suite's `touch -d` already requires.
iso_in() { date -u -d "@$(( $(date +%s) + $1 ))" '+%Y-%m-%dT%H:%M:%S.000000+00:00'; }
# A 5h window that is fresh and whose reset is far away, so its bonus is 0 and it
# never decides a row that is about the WEEK.
FIVE='"five_hour":{"utilization":0.0,"resets_at":"2099-01-01T00:00:00Z"}'
spend_of() { zrun "_claude_profile_metrics '$1' >/dev/null; print -r -- \"\$_CPM_SPEND|\$_CPM_SPEND_TXT\""; }
```

- [ ] **Step 2: Invert the `max()` row and add the metrics rows**

In "metrics: absent is its own state", replace:

```bash
check "uW is the WORST of 7d and scoped"   "$(metrics a1 | cut -d' ' -f3)" "55"
```

with:

```bash
# DO-621: uW is the AGGREGATE week alone. A per-model window (here 55) is the
# gate's business; folding it in with max() is what made two seats spent on
# OPPOSITE axes (2026-09-18: 83%/fable 100 vs 100%/fable 63) read identically.
check "uW is seven_day alone — a per-model window does not raise it" "$(metrics a1 | cut -d' ' -f3)" "40"
```

Then, after the `m3` rows, add:

```bash
# uW and rW must describe ONE window. The live instants coincide to the second,
# so without a fixture whose per-model reset DIFFERS this split is unfalsifiable.
new_home m4
mkprof a1 "{\"five_hour\":{\"utilization\":5.0},\"seven_day\":{\"utilization\":40.0,\"resets_at\":\"$(iso_in 518400)\"},\"weekly_scoped\":[{\"label\":\"7d fable\",\"utilization\":100.0,\"resets_at\":\"$(iso_in 3600)\"}]}"
check "a spent per-model window does not reach uW"               "$(metrics a1 | cut -d' ' -f3)" "40"
check "...and rW is seven_day's reset, not the per-model one" \
      "$(zrun "_claude_profile_metrics a1 >/dev/null; (( _CPM_RW > 500000 )) && print yes || print no")" "yes"

# A LAPSED week is unmeasured: the figure describes a window that has ended.
new_home m5
mkprof a1 '{"five_hour":{"utilization":5.0},"seven_day":{"utilization":100.0,"resets_at":"2000-01-01T00:00:00Z"}}'
check "a LAPSED week is unmeasured: uW is unknown"                "$(metrics a1 | cut -d' ' -f3)" "unknown"
# ...but ABSENT is not lapsed: clauth omits resets_at on an unstarted window, and
# un-demoting on missing data is optimism.
new_home m5b
mkprof a1 '{"five_hour":{"utilization":5.0},"seven_day":{"utilization":100.0}}'
check "an ABSENT weekly reset is not a lapse: uW still counts"    "$(metrics a1 | cut -d' ' -f3)" "100"

# Spend headroom: the signal that separates free, billed and blocked usage.
new_home m6
mkprof a1 '{"five_hour":{"utilization":5.0},"spend":{"enabled":true,"used":190.77,"limit":250.0}}'
mkprof b2 '{"five_hour":{"utilization":5.0},"spend":{"enabled":true,"used":275.23,"limit":275.0}}'
mkprof c3 '{"five_hour":{"utilization":5.0},"spend":{"enabled":false,"used":0.0}}'
mkprof d4 '{"five_hour":{"utilization":5.0}}'
mkprof e5 '{"five_hour":{"utilization":5.0},"spend":{"enabled":true,"used":10.0}}'
check "spend under its limit is headroom, with the amounts"       "$(spend_of a1)" 'headroom|$190.77 of $250'
check "spend at its limit is none"                                "$(spend_of b2 | cut -d'|' -f1)" "none"
check "spend disabled (a Max seat) is none"                       "$(spend_of c3 | cut -d'|' -f1)" "none"
check "no spend block is unknown, never none"                     "$(spend_of d4)" "unknown|"
check "a spend block with no limit is unknown"                    "$(spend_of e5 | cut -d'|' -f1)" "unknown"
# The reset at the top of the function is load-bearing: a profile with no spend
# block must not inherit the previous profile's value.
check "one profile's spend never leaks into the next one measured" \
      "$(zrun "_claude_profile_metrics b2 >/dev/null; _claude_profile_metrics d4 >/dev/null; print -r -- \$_CPM_SPEND")" "unknown"

# fetched_at and the per-model windows ride along for Task 2 and Part B.
new_home m7
mkprof a1 '{"five_hour":{"utilization":5.0},"fetched_at":1789759993962,"weekly_scoped":[{"label":"7d sonnet 5","utilization":38.0,"resets_at":"2026-09-21T08:59:59.512214+00:00"}]}'
check "fetched_at is carried as an integer" \
      "$(zrun "_claude_profile_metrics a1 >/dev/null; print -r -- \$_CPM_FETCHED")" "1789759993962"
# Compared field by field, NOT as a JSON string: jq 1.7+ preserves the literal
# `38.0` and 1.6 prints `38`, and CI runs both (Ubuntu 22.04 and 24.04). A row
# that hardcodes either form is red on the other runner.
check "per-model windows round-trip: a spaced label and a colon-bearing reset survive" \
      "$(zrun "_claude_profile_metrics a1 >/dev/null; print -r -- \$_CPM_WINDOWS" \
         | jq -Rc '@base64d | fromjson | .[0] | [.label, .resets_at, (.utilization == 38)]')" \
      '["7d sonnet 5","2026-09-21T08:59:59.512214+00:00",true]'
new_home m7b
mkprof a1 '{"five_hour":{"utilization":5.0}}'
check "no per-model windows is the empty string, not base64 of []" \
      "$(zrun "_claude_profile_metrics a1 >/dev/null; print -r -- \"[\$_CPM_WINDOWS]\"")" "[]"
```

- [ ] **Step 3: Run the suite to verify the new rows fail**

Run: `bash scripts/test-claude-pick.sh 2>&1 | grep -E '✗|passed'`
Expected FAIL: the inverted row (gets 55), `a spent per-model window does not reach uW` (gets 100), the lapse row (gets 100), all five spend rows and the leak row (empty), and both fetched_at/windows rows. Expected PASS already: `…rW is seven_day's reset` and `an ABSENT weekly reset is not a lapse`. Those two pin the behaviour against mutants rather than drive it.

- [ ] **Step 4: Rewrite the `jq` program and the field parse in `_claude_profile_metrics`**

At the top of the function, replace:

```zsh
  _CPM_U5=unknown; _CPM_R5=unknown; _CPM_UW=unknown; _CPM_RW=unknown
  _CPM_AGE=unknown; _CPM_TIER=unknown
```

with:

```zsh
  _CPM_U5=unknown; _CPM_R5=unknown; _CPM_UW=unknown; _CPM_RW=unknown
  _CPM_AGE=unknown; _CPM_TIER=unknown
  # DO-621. Reset HERE, because each field below is assigned only when jq
  # emitted it — a profile with no spend block must not inherit the previous
  # profile's value, which is exactly what a missing reset does.
  _CPM_SPEND=unknown; _CPM_SPEND_TXT=""; _CPM_FETCHED=unknown; _CPM_WINDOWS=""
```

Change the `local` line from `local f=… line u5 rs uw rws tier` to:

```zsh
  local f="$HOME/.clauth/profiles/$1/usage_cache.json" line u5 rs uw rws tier sp spt fa wins
```

Replace the whole `line="$(jq -r '…' "$f" 2>/dev/null)" || return 1` program with:

```zsh
  line="$(jq -r '
      [ (.five_hour.utilization // null | if . == null then null else floor end),
        (.five_hour.resets_at   // null),
        (.seven_day.utilization // null | if type == "number" then floor else null end),
        (.seven_day.resets_at // null),
        (.plan.tier // null
           | if type == "object" then (keys | .[0])
             elif . == null then null
             else tostring end),
        (.spend | if type != "object" then null
                  elif .enabled == false then "none"
                  elif .enabled == true and (.used | type) == "number" and (.limit | type) == "number"
                    then (if .used < .limit then "headroom" else "none" end)
                  else null end),
        (.spend | if type == "object" and (.used | type) == "number" and (.limit | type) == "number"
                  then "$\(.used * 100 | round / 100) of $\(.limit * 100 | round / 100)" else null end),
        (.fetched_at | if type == "number" then floor else null end),
        ((.weekly_scoped // []) | if type == "array" then map(select(type == "object")
             | {label, utilization, resets_at}) else [] end
           | if length == 0 then null else (tojson | @base64) end)
      ] | @tsv' "$f" 2>/dev/null)" || return 1
```

Replace the field-assignment block:

```zsh
  u5="${_cpm[1]}"; rs="${_cpm[2]}"; uw="${_cpm[3]}"; rws="${_cpm[4]}"; tier="${_cpm[5]}"
  [[ -n "$u5"   ]] && _CPM_U5="$u5"
  [[ -n "$uw"   ]] && _CPM_UW="$uw"
  [[ -n "$tier" ]] && _CPM_TIER="$tier"
```

with:

```zsh
  u5="${_cpm[1]}"; rs="${_cpm[2]}"; uw="${_cpm[3]}"; rws="${_cpm[4]}"; tier="${_cpm[5]}"
  sp="${_cpm[6]:-}"; spt="${_cpm[7]:-}"; fa="${_cpm[8]:-}"; wins="${_cpm[9]:-}"
  [[ -n "$u5"   ]] && _CPM_U5="$u5"
  [[ -n "$uw"   ]] && _CPM_UW="$uw"
  [[ -n "$tier" ]] && _CPM_TIER="$tier"
  [[ -n "$sp"   ]] && _CPM_SPEND="$sp"
  [[ -n "$spt"  ]] && _CPM_SPEND_TXT="$spt"
  [[ "$fa" == <-> ]] && _CPM_FETCHED="$fa"
  [[ -n "$wins" ]] && _CPM_WINDOWS="$wins"
```

After the two `_claude_ts_delta … && { … }` lines, and **before** `_CPM_AGE=…`, add:

```zsh
  # A LAPSED WEEK IS AN UNMEASURED ONE (DO-621). The figure describes a window
  # that has ended, so it can neither demote nor bill. `unknown` here is the
  # VALUE, not the class: the seat stays rankable. An ABSENT reset is not a
  # lapse — clauth omits resets_at only on an unstarted window, and un-demoting
  # a seat on missing data would be optimism.
  if [[ "$_CPM_UW" != unknown && "$_CPM_RW" == (-|)<-> ]] && (( _CPM_RW < 0 )); then
    _CPM_UW=unknown
  fi
```

- [ ] **Step 5: Update every `_CPM_*` localisation site**

Replace each of these four lines in `zsh/zshrc.herdr` (in `_claude_pick_class`, `_claude_pick_least_bad`, `_claude_pick_for_dir`, `_claude_pick_publish`):

```zsh
  local _CPM_U5 _CPM_R5 _CPM_UW _CPM_AGE _CPM_TIER _CPM_R5_AT _CPM_RW_AT
```
```zsh
  local _CPM_U5 _CPM_R5 _CPM_UW _CPM_RW _CPM_AGE _CPM_TIER _CPM_R5_AT _CPM_RW_AT
```

with the one line:

```zsh
  local _CPM_U5 _CPM_R5 _CPM_UW _CPM_RW _CPM_AGE _CPM_TIER _CPM_R5_AT _CPM_RW_AT _CPM_SPEND _CPM_SPEND_TXT _CPM_FETCHED _CPM_WINDOWS
```

and in `scripts/claude-pick` replace:

```zsh
  typeset _CPM_U5 _CPM_R5 _CPM_UW _CPM_RW _CPM_AGE _CPM_TIER _CPM_R5_AT _CPM_RW_AT
```

with:

```zsh
  typeset _CPM_U5 _CPM_R5 _CPM_UW _CPM_RW _CPM_AGE _CPM_TIER _CPM_R5_AT _CPM_RW_AT _CPM_SPEND _CPM_SPEND_TXT _CPM_FETCHED _CPM_WINDOWS
```

Verify none were missed: `grep -n 'local _CPM_\|typeset _CPM_' zsh/zshrc.herdr scripts/claude-pick` — every hit ends in `_CPM_WINDOWS`.

- [ ] **Step 6: Update the header comment of `_claude_profile_metrics`**

Replace the line `#        _CPM_UW   worst of seven_day and every weekly_scoped window` with:

```zsh
#        _CPM_UW   seven_day utilization ALONE (DO-621), or `unknown` when absent
#                  or LAPSED. Per-model windows are the gate's, never the ranker's.
#        _CPM_SPEND     headroom | none | unknown  (spend.enabled/used/limit)
#        _CPM_SPEND_TXT "$used of $limit" for messages, or empty
#        _CPM_FETCHED   clauth 0.15.2's fetched_at (epoch ms), or `unknown`
#        _CPM_WINDOWS   base64 JSON [{label,utilization,resets_at}] for Part B
```

Replace the paragraph beginning `# _CPM_RW is the SEVEN_DAY window's own reset, and it is labelled that way rather` (through the end of that paragraph) with:

```zsh
# _CPM_RW is the SEVEN_DAY window's own reset, and since DO-621 _CPM_UW is that
# same window's utilization, so the two finally describe one window. Until then
# uW was max(seven_day, every weekly_scoped window) while rW was seven_day's
# reset — and on 2026-09-18 two seats spent on OPPOSITE axes (83% with fable 100,
# 100% with fable 63) both read "100, weekly-spent".
```

- [ ] **Step 7: Run the suite — the new rows pass, nothing else moved**

Run: `bash scripts/test-claude-pick.sh 2>&1 | grep -E '✗|passed'`
Expected: `=== N passed, 0 failed ===` where N = baseline + 13 (thirteen new rows; the inverted `:108` row is an edit, not an addition). Nothing else moved.

- [ ] **Step 8: Syntax check and commit**

```bash
zsh -n zsh/zshrc.herdr && zsh -n scripts/claude-pick
git add zsh/zshrc.herdr scripts/claude-pick scripts/test-claude-pick.sh
git commit -m "feat(picker): measure the aggregate week alone, spend headroom and fetched_at (DO-621)

uW is seven_day alone; a lapsed week is unmeasured. The metrics record
gains spend state, fetched_at and the per-model windows (base64 JSON).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Cache age from `fetched_at` (ranker, and the gate that inherits it)

**Files:**
- Modify: `zsh/zshrc.herdr` — `_claude_profile_cache_age` (~575) and its call in `_claude_profile_metrics` (`_CPM_AGE="$(_claude_profile_cache_age "$1")"`)
- Modify: `scripts/claude-pick` — the "A STALE READING IS AN UNMEASURED ONE" comment (~60–75)
- Test: `scripts/test-claude-pick.sh` — new "cache age" rows after the classes section; one gate row at the end of the gate section

**Interfaces:**
- Consumes: `_CPM_FETCHED` (Task 1).
- Produces: `_claude_profile_cache_age <profile> [fetched_at_ms]` → prints age in seconds, or returns 1.

- [ ] **Step 1: Write the failing rows** — after the classes section (after the `k4` rows), add:

```bash
#-----------------------------------------------------------------------------
echo
echo "=== cache age: fetched_at first, mtime as the fallback (DO-621) ==="

age_of()  { zrun "_claude_profile_metrics '$1' >/dev/null; print -r -- \$_CPM_AGE"; }
between() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= $2 && $1 <= $3 )) && echo yes || echo "no ($1)"; }

# clauth 0.15.2 stamps fetched_at only on a LIVE fetch, so a plan-only rewrite
# advances the mtime while the reading stays old — the case upstream fixed
# alongside #74, and the one an mtime clock reads as fresh.
new_home ag1
mkprof a1 "{\"five_hour\":{\"utilization\":5.0},\"fetched_at\":$(( ($(date +%s) - 7200) * 1000 ))}"
check "age comes from fetched_at, not the fresh mtime"       "$(between "$(age_of a1)" 7190 7400)" "yes"
check "...so a plan-only rewrite is stale to the picker"      "$(cls a1 | cut -d: -f1)" "unknown"

new_home ag2
mkprof a1 '{"five_hour":{"utilization":5.0}}'
touch -d "@$(( $(date +%s) - 100 ))" "$FHOME/.clauth/profiles/a1/usage_cache.json"
check "with no fetched_at the mtime still decides (0.15.1)"   "$(between "$(age_of a1)" 95 200)" "yes"

new_home ag3
mkprof a1 "{\"five_hour\":{\"utilization\":5.0},\"fetched_at\":$(( ($(date +%s) + 30) * 1000 ))}"
check "a stamp up to 60 s ahead clamps to 0"                  "$(age_of a1)" "0"

# Far ahead is corruption. clauth's own scheduler (oauth_seed_clock) filters
# `at <= now` and falls back to the mtime; mapping it to `unknown` instead would
# read as FRESH, because the ranker never calls an unknown age stale.
new_home ag4
mkprof a1 "{\"five_hour\":{\"utilization\":5.0},\"fetched_at\":$(( ($(date +%s) + 3600) * 1000 ))}"
touch -d "@$(( $(date +%s) - 2000 ))" "$FHOME/.clauth/profiles/a1/usage_cache.json"
check "a stamp far in the future falls back to the mtime"     "$(between "$(age_of a1)" 1995 2100)" "yes"
```

At the very end of the gate section (just before the final `printf '\n=== %d passed…`), add:

```bash
# DO-621: the gate reads the same age, so its 600 s threshold is now measured
# against fetched_at. A fresh mtime over a 700 s-old fetch used to pass.
mkdir -p "$H/.clauth/profiles/gf"; : > "$H/.clauth/profiles/gf/credentials.json"
printf '{"five_hour":{"utilization":10,"resets_at":"%s"},"seven_day":{"utilization":10,"resets_at":"2099-01-06T00:00:00Z"},"fetched_at":%s,"plan":{"tier":"Team"}}\n' \
    "$GATE_FUTURE" "$(( ($(date +%s) - 700) * 1000 ))" > "$H/.clauth/profiles/gf/usage_cache.json"
gate_run gf
check "gate: a fresh mtime over a 700 s-old fetch refuses"     "$rc" "2"
check "gate: ...as gate-unmeasured"                             "$(jq -r .state <<<"$out")" "gate-unmeasured"
```

- [ ] **Step 2: Run to verify they fail**

Run: `bash scripts/test-claude-pick.sh 2>&1 | grep -E '✗|passed'`
Expected FAIL: both `ag1` rows (age ≈ 0, class eligible) and both gate rows (rc 0). `ag2` and `ag4` may already PASS under the mtime clock, and `ag3` may pass by accident when the mtime age happens to be 0. That is fine: these rows pin the fallback and the clamp against Task 7's mutants. After Step 3, `ag3` is deterministic, because the clamp returns exactly 0.

- [ ] **Step 3: Implement** — replace the whole `_claude_profile_cache_age` function with:

```zsh
# Seconds since this profile's usage reading was TAKEN, or nothing.
#
# DO-621: clauth 0.15.2 writes `fetched_at` (epoch ms) on every live fetch and
# never on a plan-only rewrite, so it is the honest clock and the file mtime is
# not — a rewrite that produced no new reading advances the mtime and read as
# fresh. The caller passes the value it already extracted, so this adds no fork.
#   * a stamp at most 60 s ahead clamps to 0 (one clock; that is jitter);
#   * a stamp further ahead is corruption, and falls back to the mtime, which is
#     what clauth's own scheduler does (oauth_seed_clock filters at <= now).
#     `unknown` would be the wrong answer: the ranker never calls it stale;
#   * no stamp at all (clauth 0.15.1) is the mtime, as before.
#
# Loads its own modules. A helper that depends on a module its CALLER happened to
# load returns nothing when called any other way — and "no age" reads as "fresh",
# so a stale reading would have been believed.
_claude_profile_cache_age() {
  local f="$HOME/.clauth/profiles/$1/usage_cache.json" fa="${2:-}" mtime s
  zmodload zsh/datetime 2>/dev/null || return 1
  if [[ "$fa" == <-> ]]; then
    s=$(( fa / 1000 ))
    if (( s <= EPOCHSECONDS + 60 )); then
      (( s > EPOCHSECONDS )) && s=$EPOCHSECONDS
      print -r -- $(( EPOCHSECONDS - s ))
      return 0
    fi
  fi
  [[ -r "$f" ]] || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  mtime=$(zstat +mtime "$f" 2>/dev/null) || return 1
  print -r -- $(( EPOCHSECONDS - mtime ))
}
```

In `_claude_profile_metrics` replace:

```zsh
  _CPM_AGE="$(_claude_profile_cache_age "$1")" || _CPM_AGE=unknown
```

with:

```zsh
  _CPM_AGE="$(_claude_profile_cache_age "$1" "$fa")" || _CPM_AGE=unknown
```

- [ ] **Step 4: Update the stale comment in `scripts/claude-pick`** — replace the sentences from `What the gate CANNOT see is` through `… refused here only by its file's mtime.` with:

```zsh
# clauth's own freshness verdict (`clauth status` reports `stale` and
# `fetch_status`) does not reach usage_cache.json, but since clauth 0.15.2 its
# clock does: `fetched_at` (epoch ms) is stamped on every live fetch and never on
# a plan-only rewrite. The age this gate compares against CLAUDE_PICK_CACHE_MAX_AGE
# is measured from it (DO-621), falling back to the file mtime only when the
# stamp is absent (clauth 0.15.1) or implausibly far in the future.
```

- [ ] **Step 5: Run and verify pass**

Run: `bash scripts/test-claude-pick.sh 2>&1 | grep -E '✗|passed'`
Expected: `=== N passed, 0 failed ===`, N = Task 1's N + 7.

- [ ] **Step 6: Commit**

```bash
zsh -n zsh/zshrc.herdr && zsh -n scripts/claude-pick
git add zsh/zshrc.herdr scripts/claude-pick scripts/test-claude-pick.sh
git commit -m "feat(picker): date usage caches from fetched_at, not the file mtime (DO-621)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Score — `weekf` damped by the weekly reset, plus a consume-first bonus

**Files:**
- Modify: `zsh/zshrc.herdr` — `_claude_pick_score` (~764–837) and its two call sites in `_claude_pick_for_dir` (`score="$(_claude_pick_score "$_CPM_U5" "$_CPM_R5" "$_CPM_UW" "$holders")"`, twice)
- Test: `scripts/test-claude-pick.sh` — `score()` helper (~145) and the scoring section; pick rows after the `fd*` rows

**Interfaces:**
- Consumes: `_CPM_RW` (seconds until the aggregate week resets, or `unknown`).
- Produces: `_claude_pick_score <u5> <r5> <uW> <holders> [rw]` → integer centipoints. A missing 5th argument is `unknown`, which reduces exactly to the pre-DO-621 arithmetic.

- [ ] **Step 1: Pass a 5th argument through the test helper** — replace:

```bash
score() { zsh -f -c "source '$HERDRRC' >/dev/null 2>&1; _claude_pick_score $1 $2 $3 ${4:-0}" 2>/dev/null; }
```

with:

```bash
score() { zsh -f -c "source '$HERDRRC' >/dev/null 2>&1; _claude_pick_score $1 $2 $3 ${4:-0} ${5:-unknown}" 2>/dev/null; }
```

- [ ] **Step 2: Write the failing score rows** — after the `a fresh week outranks a spent one at equal 5h` row, add:

```bash
# DO-621 — the weekly axis. weekf STAYS (removing it switched weekly headroom
# off below 100%: an idle 99% seat tied an idle 20% one), but its penalty fades as
# the week's reset nears, and a consume-first bonus scaled by what is LEFT is
# added. W_WEEK_EXPIRE = 200 so a real preference clears the 800-point RR band.
check "no weekly reset known: exactly the old arithmetic"      "$(score 0 18000 95 0 unknown)" "3300"
check "a reset 1 h out lifts the near-spent penalty"           "$(score 0 18000 95 0 3600)"    "11000"
check "an empty week earns no consume-first bonus"             "$(score 0 18000 100 0 3600)"   "10000"
check "A: 40% of the week left, resetting in 6 d"              "$(score 0 18000 60 0 518400)"  "11200"
check "B: 20% of the week left, resetting in 12 h"             "$(score 0 18000 80 0 43200)"   "13720"
```

After the `fd2` rows (the "with only unreadable accounts…" row), add:

```bash
# Consume-first must hold for the PICK, not just the scores: inside RR_BAND the
# least-recently-picked seat wins, so a gap under 800 is a coin flip.
new_home wk1
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":60.0,\"resets_at\":\"$(iso_in 518400)\"}}"
mkprof b2 "{$FIVE,\"seven_day\":{\"utilization\":80.0,\"resets_at\":\"$(iso_in 43200)\"}}"
check "consume-first: B is picked with an empty ledger"        "$(pfd '' '' '' 0 | cut -d: -f2)" "b2"
printf 'a1\t1\nb2\t%s\n' "$(date +%s)" > "$FHOME/.local/state/claude-account-dirs/.pick-ledger"
check "...and still B when the ledger just picked B"           "$(pfd '' '' '' 0 | cut -d: -f2)" "b2"

# weekf kept: at equal reset distance, a nearly-spent week loses to a fresh one.
new_home wk2
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":99.0,\"resets_at\":\"$(iso_in 432000)\"}}"
mkprof b2 "{$FIVE,\"seven_day\":{\"utilization\":20.0,\"resets_at\":\"$(iso_in 432000)\"}}"
check "an idle seat at 99% of its week loses to one at 20%"   "$(pfd '' '' '' 0 | cut -d: -f2)" "b2"
```

- [ ] **Step 3: Run to verify they fail**

Run: `bash scripts/test-claude-pick.sh 2>&1 | grep -E '✗|passed'`
Expected, computed from today's code, which ignores the 5th argument:

| Row | Today | Expect |
|---|---|---|
| `3300` | 3300 | PASS |
| `11000` | 3300 | FAIL |
| `10000` | 0 | FAIL |
| `11200` | 10000 | FAIL |
| `13720` | 10000 | FAIL |
| `wk1` empty ledger | a1 (both score 10000; the tie breaks by name) | FAIL |
| `wk1` hostile ledger | a1 | FAIL |
| `wk2` | b2 (600 vs 10000) | PASS — it pins "weekf kept" against Task 7's mutants |

- [ ] **Step 4: Implement** — in `_claude_pick_score`, replace the signature/`local` lines:

```zsh
  local u5="$1" r5="$2" uw="$3" h="${4:-0}"
  local w_expire=${CLAUDE_PICK_W_EXPIRE:-50} w_holder=${CLAUDE_PICK_W_HOLDER:-3}
  local w_crowd=${CLAUDE_PICK_W_CROWD:-15} week_low=${CLAUDE_PICK_WEEK_LOW:-15}
  local h5 hw exp weekf base bonus crowd
```

with:

```zsh
  local u5="$1" r5="$2" uw="$3" h="${4:-0}" rw="${5:-unknown}"
  local w_expire=${CLAUDE_PICK_W_EXPIRE:-50} w_holder=${CLAUDE_PICK_W_HOLDER:-3}
  local w_crowd=${CLAUDE_PICK_W_CROWD:-15} week_low=${CLAUDE_PICK_WEEK_LOW:-15}
  local w_wexp=${CLAUDE_PICK_W_WEEK_EXPIRE:-200}
  local h5 hw exp exp_w weekf weekf_eff base bonus bonus_w crowd
```

Replace the weekly block:

```zsh
  if [[ "$uw" == unknown ]]; then
    # Unknown must not outrank a measured value, but neither may it INVENT a
    # penalty: an unread weekly window is not a spent one. Class handles rank.
    weekf=100
  else
```

with:

```zsh
  if [[ "$uw" == unknown ]]; then
    # Unknown must not outrank a measured value, but neither may it INVENT a
    # penalty: an unread weekly window is not a spent one. Class handles rank.
    # hw=0: nothing is known to be left, so nothing earns a consume-first bonus.
    weekf=100; hw=0
  else
```

Replace the tail:

```zsh
  base=$(( h5 * 100 ))
  bonus=$(( h5 * exp * w_expire / 100 ))
  crowd=$(( h * (w_holder * 100 + u5 * w_crowd) ))
  print -r -- $(( (base + bonus) * weekf / 100 - crowd ))
```

with:

```zsh
  # DO-621 — CONSUME-FIRST ON THE WEEK. exp_w is how close the aggregate week is
  # to resetting (0 unknown/rolled/a week away, 100 imminent). Two uses:
  #   weekf_eff — weekf's near-spent penalty FADES as the reset nears: 5% left
  #               that resets in an hour is exactly what should be spent. With
  #               rw unknown, exp_w = 0 and this is the old arithmetic exactly.
  #   bonus_w   — scaled by weekly headroom, so an EMPTY week earns nothing for
  #               resetting soon. 200 so that a real preference clears RR_BAND
  #               (800): at 50, 40%/6 d vs 20%/12 h was a 630-point coin flip.
  if [[ "$rw" != (-|)<-> ]] || (( rw <= 0 || rw >= 604800 )); then
    exp_w=0
  else
    exp_w=$(( 100 - rw * 100 / 604800 ))
  fi
  weekf_eff=$(( weekf + (100 - weekf) * exp_w / 100 ))

  base=$(( h5 * 100 ))
  bonus=$(( h5 * exp * w_expire / 100 ))
  bonus_w=$(( hw * exp_w * w_wexp / 100 ))
  crowd=$(( h * (w_holder * 100 + u5 * w_crowd) ))
  print -r -- $(( (base + bonus + bonus_w) * weekf_eff / 100 - crowd ))
```

Update the `# Usage:` line to `# Usage: _claude_pick_score <u5> <r5> <uW> <holders> [rw]` and `#   r5, uW and rw accept the literal `unknown`.`; add to the term list after the `weekf` bullet:

```zsh
#   weekf_eff / bonus_w = DO-621: the week's reset. weekf's penalty fades as it
#           nears, and a consume-first bonus scaled by weekly headroom is added.
```

In `_claude_pick_for_dir`, change **both** call sites from:

```zsh
          score="$(_claude_pick_score "$_CPM_U5" "$_CPM_R5" "$_CPM_UW" "$holders")"
```

to:

```zsh
          score="$(_claude_pick_score "$_CPM_U5" "$_CPM_R5" "$_CPM_UW" "$holders" "$_CPM_RW")"
```

- [ ] **Step 5: Run and verify** — `bash scripts/test-claude-pick.sh 2>&1 | grep -E '✗|passed'`
Expected: `0 failed`. **Confirm the four pre-existing weekly rows are still green unchanged**: `7d 96% scores below 7d 60% at equal 5h`, `a spent week scores 0`, `a fresh week outranks a spent one at equal 5h`, and `k3`'s `…demoted to the floor by the score`. If any failed, stop: the spec's claim that rw=unknown reduces to today's arithmetic is wrong, and that is a design finding, not a row to edit.

- [ ] **Step 6: Commit**

```bash
zsh -n zsh/zshrc.herdr
git add zsh/zshrc.herdr scripts/test-claude-pick.sh
git commit -m "feat(picker): consume-first on the weekly window, weekf damped by its reset (DO-621)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The spend wall — class, least-bad reset, exhaustion report

**Files:**
- Modify: `zsh/zshrc.herdr` — `_claude_pick_class` (~841–925), new `_claude_pick_block_reset` (place directly above `_claude_pick_least_bad`), `_claude_pick_least_bad` (~1159–1178), the `exhausted)` branch and the two `_claude_pick_reason=` strings in `_claude_pick_for_dir`, `_claude_pick_report_exhausted` (~1628)
- Test: `scripts/test-claude-pick.sh` — classes section, least-bad section (`x*` rows)

**Interfaces:**
- Consumes: `_CPM_UW`, `_CPM_RW`, `_CPM_SPEND`, `_CPM_U5`, `_CPM_R5` (Task 1).
- Produces:
  - `_claude_pick_class` may print `exhausted:weekly window N% used and no spend headroom`.
  - `_claude_pick_block_reset` — reads the current `_CPM_*` globals, prints the seconds until THIS seat stops being blocked (the later of the walls that apply), or `unknown`.
  - `_claude_pick_exhausted` records gain a 5th field: the block reset.

- [ ] **Step 1: Write the failing rows** — after the `k4` classes rows, add:

```bash
# DO-621 — THE SPEND WALL, measured 2026-09-18: a spent window with spend
# headroom BILLS usage credits; with none it BLOCKS ("You've hit your individual
# spend limit"). Only the second is a wall, and missing data is never one.
new_home sw1
WEEK_SPENT_LIVE="\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 86400)\"}"
mkprof a1 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":true,\"used\":10.0,\"limit\":250.0}}"
mkprof b2 "{$FIVE,$WEEK_SPENT_LIVE}"
mkprof c3 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":true,\"used\":275.23,\"limit\":275.0}}"
mkprof d4 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":false,\"used\":0.0}}"
check "spent week + spend headroom: eligible (it bills; the tier demotes)" "$(cls a1)" "eligible"
check "spent week + spend unknown: eligible — missing data never refuses"   "$(cls b2)" "eligible"
check "spent week + spend at its limit: exhausted"                          "$(cls c3 | cut -d: -f1)" "exhausted"
check "spent week + spend disabled (a Max seat): exhausted"                 "$(cls d4 | cut -d: -f1)" "exhausted"
check "...and the reason names the spend wall"                              "$(cls c3 | grep -c 'no spend headroom')" "1"

new_home sw2
mkprof a1 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":true,\"used\":10.0,\"limit\":250.0}}"
check "a billing seat is picked in the weekly-spent tier"   "$(pfd '' '' '' 0 | cut -d: -f1,4)" "0:weekly-spent"

new_home sw3
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"2000-01-01T00:00:00Z\"},\"spend\":{\"enabled\":true,\"used\":275.23,\"limit\":275.0}}"
check "a LAPSED spent week behind a spend wall is not exhausted" "$(cls a1)" "eligible"
check "...and is picked as eligible, not weekly-spent"            "$(pfd '' '' '' 0 | cut -d: -f4)" "eligible"

# The pair that motivated DO-621, as measured on 2026-09-18.
new_home sw4
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":86.0,\"resets_at\":\"$(iso_in 216000)\"},\"weekly_scoped\":[{\"label\":\"7d fable\",\"utilization\":100.0,\"resets_at\":\"$(iso_in 216000)\"}],\"spend\":{\"enabled\":true,\"used\":190.77,\"limit\":250.0}}"
mkprof b2 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 194400)\"},\"weekly_scoped\":[{\"label\":\"7d fable\",\"utilization\":63.0,\"resets_at\":\"$(iso_in 194400)\"}],\"spend\":{\"enabled\":true,\"used\":275.23,\"limit\":275.0}}"
check "the 2026-09-18 pair: the Fable-spent seat is eligible"        "$(cls a1)" "eligible"
check "...the aggregate-spent seat at its spend limit is exhausted"   "$(cls b2 | cut -d: -f1)" "exhausted"
check "...and the pick is the eligible one"                          "$(pfd '' '' '' 0 | cut -d: -f2,4)" "a1:eligible"

new_home sw5
mkprof a1 "{$FIVE,$WEEK_SPENT_LIVE,\"spend\":{\"enabled\":true,\"used\":275.23,\"limit\":275.0}}"
check "a headless caller refuses a pool behind the spend wall"       "$(pfd '' '' '' 1 | cut -d: -f1,3)" "2:exhausted"
```

After the existing least-bad rows (`x1`, `x2`, …), add:

```bash
# Behind the spend wall it is the WEEK that has to reset, so that is the wait to
# quote. Both 5h windows below reset at the same far instant, so the old
# r5-only choice ties and keeps the first name — the row dies on it.
new_home x5
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 172800)\"},\"spend\":{\"enabled\":false}}"
mkprof b2 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 86400)\"},\"spend\":{\"enabled\":false}}"
check "behind the spend wall, the soonest WEEKLY reset is least bad" "$(lb a1 b2 | cut -d\| -f1)" "b2"
```

- [ ] **Step 2: Run to verify they fail** — `bash scripts/test-claude-pick.sh 2>&1 | grep -E '✗|passed'`
Expected: FAIL on c3/d4 exhausted rows, the reason row, `sw4` b2 row, `sw5` (rc 0), and `x5` (a1). The eligible/lapse rows may already pass.

- [ ] **Step 3: Add the spend wall to `_claude_pick_class`** — add `local spent=${CLAUDE_PICK_WEEK_SPENT:-100}` to its `local` lines, and directly after the existing `exw` check:

```zsh
  if [[ "$_CPM_UW" != unknown ]] && (( _CPM_UW >= exw )); then
    print -r -- "exhausted:weekly window ${_CPM_UW}% used"
    return 0
  fi
```

add:

```zsh
  # THE SPEND WALL (DO-621). A spent week is not a wall WHILE SPEND HEADROOM
  # LASTS — it bills usage credits, which is DO-574's 2026-09-10 measurement
  # (live sessions on 100% seats). Once headroom is gone it blocks: 2026-09-18,
  # six "You've hit your individual spend limit" errors on a seat at 100% with
  # $275.23 of $275 spent, each quoting that seat's own weekly reset. `none`
  # only: spend `unknown` never escalates to a refusal (missing data is not a
  # wall), and a LAPSED week has uW `unknown` so it never reaches this line.
  if [[ "$_CPM_UW" != unknown && "$_CPM_SPEND" == none ]] && (( _CPM_UW >= spent )); then
    print -r -- "exhausted:weekly window ${_CPM_UW}% used and no spend headroom"
    return 0
  fi
```

Update the header: `#          exhausted — the 5h window is spent. A real, self-clearing wall.` becomes:

```zsh
#          exhausted — the 5h window is spent, OR (DO-621) a live spent week
#                      with no spend headroom. Real, self-clearing walls.
```

and append to the end of the "THE WEEKLY WINDOW IS NOT AN EXHAUSTION CLASS" paragraph:

```zsh
#
# DO-621 REFINES THIS, it does not reverse it. The 2026-09-10 seats were
# billing: a spent week with spend headroom bills usage credits and keeps
# working, so it still only demotes. A spent week with NO spend headroom blocks
# (measured 2026-09-18), and that one state is `exhausted` above.
```

- [ ] **Step 4: Add `_claude_pick_block_reset` and use it in `_claude_pick_least_bad`** — directly above `_claude_pick_least_bad() {`, add:

```zsh
# Seconds until THIS seat stops being blocked, from the current _CPM_* values, or
# `unknown`. The 5h reset for a 5h wall; the WEEKLY reset for the spend wall
# (DO-621), because that is the window that has to roll; the later of the two
# when both apply. Prints; callers that need no fork read _CPM_* themselves.
_claude_pick_block_reset() {
  local ex5=${CLAUDE_PICK_5H_EXHAUSTED:-97} spent=${CLAUDE_PICK_WEEK_SPENT:-100}
  local r="$_CPM_R5"
  if [[ "$_CPM_UW" != unknown && "$_CPM_SPEND" == none && "$_CPM_RW" == (-|)<-> ]] \
     && (( _CPM_UW >= spent )); then
    if [[ "$r" != (-|)<-> || "$_CPM_U5" != <-> ]] || (( _CPM_U5 < ex5 || _CPM_RW > r )); then
      r="$_CPM_RW"
    fi
  fi
  print -r -- "$r"
}
```

In `_claude_pick_least_bad`, replace `    r="$_CPM_R5"` with:

```zsh
    r="$(_claude_pick_block_reset)"
```

- [ ] **Step 5: Carry the block reset into the exhaustion record and report** — in `_claude_pick_for_dir`'s `exhausted)` branch replace:

```zsh
          _claude_pick_exhausted+=( "$name"$'\t'"$_CPM_U5"$'\t'"$_CPM_UW"$'\t'"$_CPM_R5" )
```

with:

```zsh
          # Field 5 (appended, never inserted): the reset that ends THIS wall.
          _claude_pick_exhausted+=( "$name"$'\t'"$_CPM_U5"$'\t'"$_CPM_UW"$'\t'"$_CPM_R5"$'\t'"$(_claude_pick_block_reset)" )
```

In `_claude_pick_report_exhausted` replace:

```zsh
    n="${f[1]}"; u5="${f[2]}"; uw="${f[3]}"; r5="${f[4]}"
```

with:

```zsh
    n="${f[1]}"; u5="${f[2]}"; uw="${f[3]}"; r5="${f[4]}"
    # DO-621: quote the reset that ends THIS seat's wall (field 5) — for the
    # spend wall that is the week, not the 5h window.
    [[ -n "${f[5]:-}" ]] && r5="${f[5]}"
```

Replace the two reason strings in `_claude_pick_for_dir`:

```zsh
      _claude_pick_reason="every member of ${_claude_pick_tenant:+pool $_claude_pick_tenant }${_claude_pick_tenant:+has}${_claude_pick_tenant:-the account pool has} a spent 5h window"
```
→
```zsh
      _claude_pick_reason="every member of ${_claude_pick_tenant:+pool $_claude_pick_tenant}${_claude_pick_tenant:-the account pool} is exhausted — a spent 5h window, or a spent week with no spend headroom"
```

```zsh
    _claude_pick_reason="every pool member's 5h window is spent — proceeding on the least-bad one"
```
→
```zsh
    _claude_pick_reason="every pool member is exhausted — proceeding on the least-bad one"
```

- [ ] **Step 6: Run and verify** — `bash scripts/test-claude-pick.sh 2>&1 | grep -E '✗|passed'` and `bash scripts/test-hspawn.sh 2>&1 | grep -E '✗|passed'`
Expected: both `0 failed`. If a pre-existing row asserted the old reason wording, it will show here; update its expected string to the new wording (the only known one, `report 0 | head -1 … 'has NO usable account — proceeding on the least-bad one'`, prints the report header, which is unchanged).

- [ ] **Step 7: Commit**

```bash
zsh -n zsh/zshrc.herdr
git add zsh/zshrc.herdr scripts/test-claude-pick.sh scripts/test-hspawn.sh
git commit -m "feat(picker): a spent week with no spend headroom is exhausted (DO-621)

Measured 2026-09-18: a spent window bills usage credits while spend
headroom lasts and blocks with 'individual spend limit' once it is gone.
The least-bad choice and the exhaustion report quote the weekly reset
for a seat behind that wall.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Say when a pick will bill — warning, `--json usage.spend`

**Files:**
- Modify: `zsh/zshrc.herdr` — `_claude_pick_publish` (~1570), the per-call reset block in `_claude_pick_for_dir` (`_claude_pick_leastbad=""; _claude_pick_leastbad_r5=unknown`), the two `local … _claude_pick_leastbad_r5=unknown` lines in `claude()` (~1696) and `hspawn` (~2309)
- Modify: `scripts/claude-pick` — the pinned path (after `_claude_pick_rw_at=…`), the `jq -n` call and its `usage:` object
- Test: `scripts/test-claude-pick.sh` (CLI section, after `cli()` is defined); `scripts/test-hspawn.sh` (after the `claude()` isolation rows)

**Interfaces:**
- Consumes: `_CPM_SPEND`, `_CPM_SPEND_TXT`, `_claude_pick_class`.
- Produces: global `_claude_pick_spend` (`headroom|none|unknown`); a `_claude_pick_warnings` entry on a `weekly-spent` pick; `--json` `.usage.spend`.

- [ ] **Step 1: Write the failing rows** — in `scripts/test-claude-pick.sh`, in the CLI section after the existing `cli --dry-run --json` rows, add:

```bash
# DO-621: a pick that will bill usage credits says so. claude() prints every
# _claude_pick_warnings entry on an interactive launch (zshrc.herdr), so this is
# the channel an interactive user actually sees.
new_home bill1
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":100.0,\"resets_at\":\"$(iso_in 86400)\"},\"spend\":{\"enabled\":true,\"used\":10.0,\"limit\":250.0}}"
cli --dry-run --json
check "--json reports the chosen seat's spend state"          "$(jq -r .usage.spend <<<"$CLI_OUT")" "headroom"
check "a billing pick carries the billing warning" \
      "$(jq -r '[.warnings[] | select(contains("usage bills credits"))] | length' <<<"$CLI_OUT")" "1"
check "...naming the amounts" \
      "$(jq -r '.warnings[] | select(contains("usage bills credits"))' <<<"$CLI_OUT" | grep -c '\$10 of \$250')" "1"

new_home bill2
mkprof a1 "{$FIVE,\"seven_day\":{\"utilization\":20.0,\"resets_at\":\"$(iso_in 86400)\"},\"spend\":{\"enabled\":true,\"used\":10.0,\"limit\":250.0}}"
cli --dry-run --json
check "an eligible pick carries no billing warning" \
      "$(jq -r '[.warnings[] | select(contains("bills credits"))] | length' <<<"$CLI_OUT")" "0"
```

In `scripts/test-hspawn.sh`, directly after the `check "and it says which account it took" …` row, add:

```bash
# DO-621: a pick that will bill usage credits is SAID on the interactive path.
cat > "$FHOME/.clauth/profiles/personal/usage_cache.json" <<EOF
{"five_hour":{"utilization":10.0,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":100.0,"resets_at":"$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')"},"spend":{"enabled":true,"used":10.0,"limit":250.0}}
EOF
run "claude"
check "a billing pick is announced as billing"   "$(outgrep "usage bills credits")" "1"
rm -f "$FHOME/.clauth/profiles/personal/usage_cache.json"
```

- [ ] **Step 2: Run to verify they fail** — both suites; expect the four pick rows except "no billing warning" and the hspawn row to FAIL (`.usage.spend` is null; no warning).

- [ ] **Step 3: Implement** — in `_claude_pick_publish`, after `_claude_pick_rw_at="$_CPM_RW_AT"`, add:

```zsh
  _claude_pick_spend="$_CPM_SPEND"
  # DO-621 — SAY WHEN A PICK WILL COST MONEY. weekly-spent means the aggregate
  # week is spent and the seat is not blocked, i.e. usage bills credits
  # (measured 2026-09-18). claude() prints every warning on an interactive
  # launch, and --json/--explain carry the same entry.
  if [[ "$_claude_pick_class" == weekly-spent ]]; then
    if [[ "$_CPM_SPEND" == headroom ]]; then
      _claude_pick_warnings+=("$1: weekly window spent — usage bills credits${_CPM_SPEND_TXT:+ ($_CPM_SPEND_TXT)}")
    else
      _claude_pick_warnings+=("$1: weekly window spent — usage may bill credits (spend headroom unknown)")
    fi
  fi
```

In `_claude_pick_for_dir`'s per-call reset block, change `_claude_pick_leastbad=""; _claude_pick_leastbad_r5=unknown` to:

```zsh
  _claude_pick_leastbad=""; _claude_pick_leastbad_r5=unknown; _claude_pick_spend=unknown
```

In `claude()` and in `hspawn`, change `local _claude_pick_holders=0 _claude_pick_leastbad="" _claude_pick_leastbad_r5=unknown` to:

```zsh
  local _claude_pick_holders=0 _claude_pick_leastbad="" _claude_pick_leastbad_r5=unknown _claude_pick_spend=unknown
```

In `scripts/claude-pick`'s pinned path, after `_claude_pick_r5_at="$_CPM_R5_AT"; _claude_pick_rw_at="$_CPM_RW_AT"`, add:

```zsh
  _claude_pick_spend="$_CPM_SPEND"
```

In the `jq -n` call add the argument (next to `--argjson cache_age …`):

```zsh
    --arg    spend        "${_claude_pick_spend:-}" \
```

and change the `usage:` line to:

```zsh
       usage:        { five_hour: $five_hour, weekly: $weekly, cache_age_s: $cache_age,
                       spend: (if $spend == "" then null else $spend end) },
```

- [ ] **Step 4: Run and verify** — `bash scripts/test-claude-pick.sh 2>&1 | grep -E '✗|passed'; bash scripts/test-hspawn.sh 2>&1 | grep -E '✗|passed'`
Expected: both `0 failed`.

- [ ] **Step 5: Commit**

```bash
zsh -n zsh/zshrc.herdr && zsh -n scripts/claude-pick
git add zsh/zshrc.herdr scripts/claude-pick scripts/test-claude-pick.sh scripts/test-hspawn.sh
git commit -m "feat(picker): warn when a pick will bill usage credits (DO-621)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `claude-doctor` dates caches the same way

**Files:**
- Modify: `zsh/functions/claude.sh` — new `_claude_usage_cache_age_s` after `_claude_file_age_s` (~469–477); the freshness loop's `uc_age="$(_claude_file_age_s "$ucf")"` (~1237)
- Test: `scripts/test-claude-doctor.sh` — after the `s1` usage-cache rows (~1543)

**Interfaces:**
- Produces: `_claude_usage_cache_age_s <usage_cache.json path>` → seconds, or returns 1. Same rule as Task 2's `_claude_profile_cache_age`.

- [ ] **Step 1: Write the failing row** — after the `s1` rows, add:

```bash
# DO-621: the doctor must agree with the picker about a cache's age. A plan-only
# rewrite leaves the mtime fresh while clauth 0.15.2's fetched_at says the
# reading is two hours old; the picker (test-claude-pick.sh, "cache age" ag1)
# calls that stale, so the doctor must too.
new_home ufa1; write_cred
mk_usage_profile p1 60
printf '{"five_hour":{"utilization":10.0},"fetched_at":%s}\n' "$(( ($(date +%s) - 7200) * 1000 ))" \
    > "$FHOME/.clauth/profiles/p1/usage_cache.json"
run_doctor
want_out "the doctor dates a cache from fetched_at, not its fresh mtime" "oldest 2h ago"
```

- [ ] **Step 2: Run to verify it fails** — `bash scripts/test-claude-doctor.sh 2>&1 | grep -E '✗|passed'`
Expected: FAIL (the doctor reports `oldest 0s ago` / a ✓).

- [ ] **Step 3: Implement** — after `_claude_file_age_s`, add:

```zsh
# Age of a usage cache's READING, in seconds: clauth 0.15.2's fetched_at when it
# has one, else the file mtime. THE SAME RULE AS _claude_profile_cache_age in
# zsh/zshrc.herdr, deliberately duplicated rather than shared: this file must
# work without zshrc.herdr (a modular adopter has only one of them), and two
# readers of one file must agree on its age — the same fixture shape is pinned
# in both suites (DO-621).
_claude_usage_cache_age_s() {
  local f="$1" fa s
  zmodload zsh/datetime 2>/dev/null || return 1
  fa="$(jq -r '.fetched_at // empty | floor' "$f" 2>/dev/null)"
  if [[ "$fa" == <-> ]]; then
    s=$(( fa / 1000 ))
    if (( s <= EPOCHSECONDS + 60 )); then
      (( s > EPOCHSECONDS )) && s=$EPOCHSECONDS
      print -r -- $(( EPOCHSECONDS - s ))
      return 0
    fi
  fi
  _claude_file_age_s "$f"
}
```

In the freshness loop replace:

```zsh
    uc_age="$(_claude_file_age_s "$ucf")" || uc_age=""
```

with:

```zsh
    uc_age="$(_claude_usage_cache_age_s "$ucf")" || uc_age=""
```

- [ ] **Step 4: Run and verify** — `bash scripts/test-claude-doctor.sh 2>&1 | grep -E '✗|passed'`
Expected: `0 failed` (the existing `s1`/age rows use caches without `fetched_at`, so they exercise the fallback unchanged).

- [ ] **Step 5: Commit**

```bash
zsh -n zsh/functions/claude.sh
git add zsh/functions/claude.sh scripts/test-claude-doctor.sh
git commit -m "fix(doctor): date usage caches from fetched_at, as the picker does (DO-621)

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Stale comments, CLAUDE.md, full verification, mutation sweep

**Files:**
- Modify: `zsh/zshrc.herdr` — the tier comment in `_claude_pick_for_dir` above `if [[ "$cls" == eligible && "$_CPM_UW" != unknown ]] && (( _CPM_UW >= week_spent )); then`
- Modify: `CLAUDE.md` — a new subsection in "Claude Code accounts & MCP"
- Create (outside the repo, never committed): the mutation driver at `$MUT`. Set it once, to a file in your session's scratchpad directory, e.g. `MUT="$SCRATCHPAD/mutate-do-621.py"`; every step below refers to `$MUT`.

**Deviation from the spec's mutant list, stated rather than silent.** The spec lists "drop one localisation site". Three of the five `local _CPM_…` sites run inside `$(…)` (`_claude_pick_class`) or after the loop has finished (`_claude_pick_publish`). A mutant that removes one of those cannot leak anything observable, so it can never die, and a mutant that can never die reads as coverage. The leak that CAN happen is a new global not being reset at the top of `_claude_profile_metrics`. So this plan's mutant is "drop the `_CPM_SPEND` reset", killed by the Task 1 row `one profile's spend never leaks into the next one measured`. Likewise the spec's "map a future `fetched_at` to `unknown`" becomes "trust a far-future `fetched_at`". Both mutate the same branch, and both die on `ag4`.

- [ ] **Step 1: Update the tier comment** — directly above the `if [[ "$cls" == eligible && "$_CPM_UW" != unknown ]] && (( _CPM_UW >= week_spent )); then` line, add:

```zsh
      # DO-621: the week that decides this tier is the AGGREGATE seven_day alone
      # (a per-model window is the gate's), a LAPSED week never enters it (uW is
      # unknown), and a spent week with NO spend headroom never reaches it —
      # _claude_pick_class already made that seat `exhausted`. What is left here
      # is the seat that will BILL usage credits, and _claude_pick_publish says so.
```

- [ ] **Step 2: Add the CLAUDE.md subsection** — insert immediately before the line `### Tenants and pools (DO-599)`:

```markdown
### Weekly windows and the spend wall (DO-621)

**`max()` over heterogeneous windows reported two seats spent on opposite axes as the
same state.** On 2026-09-18 quantivly-1 read `seven_day` 83 with `7d fable` 100, and
quantivly-3 read `seven_day` 100 with `7d fable` 63; both came out `weekly-spent (100%)`.
The ranker now reads the aggregate `seven_day` alone (per-model windows belong to the
gate, which knows the model — DO-623), a lapsed week is unmeasured, and clauth 0.15.2's
`fetched_at` dates the cache instead of the file mtime.

**Spend headroom is the signal that separates free, billed and blocked**, measured the
same day from `usage_history.jsonl` and transcripts:

| Seat state | What happens |
|---|---|
| window not spent | free |
| window spent, spend headroom left | usage **bills usage credits** (+$0.59 within 4 min of a window hitting 100 — the only spend increases in two days across all work seats) |
| window spent, spend at its limit | **blocked**: "You've hit your individual spend limit" (6 errors, each quoting that seat's weekly reset) |

This refines DO-574 rather than reversing it: its 2026-09-10 seats were billing. So the
tiers are `eligible` (free) > `weekly-spent` (bills — and the pick says so in a warning
`claude()` prints) > `exhausted` (a live spent week with spend `none`). Spend `unknown`
never escalates to `exhausted`: missing data is not a wall. Max seats have
`spend.enabled = false`; that a spent window blocks them is inferred from the field,
not observed.

**Consume-first on the week, without switching the week off.** `weekf` stays, its
penalty fading as the weekly reset nears (`weekf_eff`), plus a consume-first bonus
scaled by weekly headroom (`CLAUDE_PICK_W_WEEK_EXPIRE`, 200). The weight is set against
`CLAUDE_PICK_RR_BAND` (800), not in isolation: inside the band the least-recently-picked
seat wins, so at 50 the spec's own 40%/6 d vs 20%/12 h example was a 630-point coin
flip. An adversarial review caught that, and caught that removing `weekf` outright made
an idle 99% seat tie an idle 20% one. **A weight is only meaningful relative to the
band that decides ties** — check it against the band, and assert the PICK, not the score.

**The "Fable · Requires usage credits" banner is not evidence about windows** (a
server-side flag on every Team profile; a notice, not a block). The first draft of this
design built a refusal on it. That was the #123 failure — a correlation plus a plausible
mechanism — recurring, and caught by a reviewer checking the claim against this repo's
own memory.

Rows: `scripts/test-claude-pick.sh` (metrics, cache age, scoring, spend wall, billing
warning), `scripts/test-hspawn.sh` (the warning reaches `claude()`),
`scripts/test-claude-doctor.sh` (the doctor dates caches the same way). Spec:
`docs/superpowers/specs/2026-09-18-do-621-weekly-picker-design.md`.
```

- [ ] **Step 3: Full verification**

```bash
zsh -n zsh/zshrc.herdr && zsh -n scripts/claude-pick && zsh -n zsh/functions/claude.sh
bash scripts/test-claude-pick.sh  2>&1 | tail -1
bash scripts/test-hspawn.sh       2>&1 | tail -1
bash scripts/test-claude-doctor.sh 2>&1 | tail -1
pre-commit run --files zsh/zshrc.herdr scripts/claude-pick zsh/functions/claude.sh \
  scripts/test-claude-pick.sh scripts/test-hspawn.sh scripts/test-claude-doctor.sh CLAUDE.md
```

Expected: three `0 failed` lines; pre-commit all Passed. Run once more under `LC_ALL=C` (CI's collation) for the pick suite: `LC_ALL=C bash scripts/test-claude-pick.sh 2>&1 | tail -1` → `0 failed`.

- [ ] **Step 4: Write the mutation driver to `$MUT`** (not the repo). Run it from the repo root, because its paths are repo-relative:

```python
#!/usr/bin/env python3
"""DO-621 mutation sweep. One mutant per invocation: `mutate-do-621.py <index>`.

A mutation whose find-string does not occur EXACTLY once, whose replacement is a
no-op, or that does not parse is a HARNESS ERROR, never a result: a mutation that
no longer applies reads exactly like a survivor (CLAUDE.md). The source is always
restored, including on Ctrl-C.
"""
import pathlib, subprocess, sys

HERDR, PICKCLI, DOCTOR = "zsh/zshrc.herdr", "scripts/claude-pick", "zsh/functions/claude.sh"
PICK, HSPAWN, DOC = "scripts/test-claude-pick.sh", "scripts/test-hspawn.sh", "scripts/test-claude-doctor.sh"

MUTANTS = [
  ("restore max() for uW", HERDR,
   '(.seven_day.utilization // null | if type == "number" then floor else null end),',
   '([ (.seven_day.utilization // empty), ((.weekly_scoped // []) | .[]? | .utilization // empty) ] | map(select(type == "number")) | if length > 0 then (max | floor) else null end),',
   [PICK]),
  ("drop the lapse arm", HERDR,
   '&& (( _CPM_RW < 0 )); then\n    _CPM_UW=unknown',
   '&& (( _CPM_RW < -999999999 )); then\n    _CPM_UW=unknown',
   [PICK]),
  ("drop the _CPM_SPEND reset", HERDR,
   '_CPM_SPEND=unknown; _CPM_SPEND_TXT=""; _CPM_FETCHED=unknown; _CPM_WINDOWS=""',
   '_CPM_SPEND_TXT=""; _CPM_FETCHED=unknown; _CPM_WINDOWS=""',
   [PICK]),
  ("prefer mtime over fetched_at (ranker)", HERDR,
   'local f="$HOME/.clauth/profiles/$1/usage_cache.json" fa="${2:-}" mtime s',
   'local f="$HOME/.clauth/profiles/$1/usage_cache.json" fa="" mtime s',
   [PICK]),
  ("trust a far-future fetched_at", HERDR,
   '    if (( s <= EPOCHSECONDS + 60 )); then\n      (( s > EPOCHSECONDS )) && s=$EPOCHSECONDS\n      print -r -- $(( EPOCHSECONDS - s ))\n      return 0\n    fi\n  fi\n  [[ -r "$f" ]] || return 1',
   '    if (( 1 )); then\n      (( s > EPOCHSECONDS )) && s=$EPOCHSECONDS\n      print -r -- $(( EPOCHSECONDS - s ))\n      return 0\n    fi\n  fi\n  [[ -r "$f" ]] || return 1',
   [PICK]),
  ("remove the weekf damping", HERDR,
   'weekf_eff=$(( weekf + (100 - weekf) * exp_w / 100 ))',
   'weekf_eff=$weekf',
   [PICK]),
  ("drop the headroom factor from bonus_w", HERDR,
   'bonus_w=$(( hw * exp_w * w_wexp / 100 ))',
   'bonus_w=$(( exp_w * w_wexp / 100 ))',
   [PICK]),
  ("W_WEEK_EXPIRE back to 50", HERDR,
   'local w_wexp=${CLAUDE_PICK_W_WEEK_EXPIRE:-200}',
   'local w_wexp=${CLAUDE_PICK_W_WEEK_EXPIRE:-50}',
   [PICK]),
  ("treat spend unknown as none", HERDR,
   'if [[ "$_CPM_UW" != unknown && "$_CPM_SPEND" == none ]] && (( _CPM_UW >= spent )); then',
   'if [[ "$_CPM_UW" != unknown && "$_CPM_SPEND" != headroom ]] && (( _CPM_UW >= spent )); then',
   [PICK]),
  ("least-bad ignores the block reset", HERDR,
   '    r="$(_claude_pick_block_reset)"',
   '    r="$_CPM_R5"',
   [PICK]),
  ("drop the billing warning", HERDR,
   '      _claude_pick_warnings+=("$1: weekly window spent — usage bills credits${_CPM_SPEND_TXT:+ ($_CPM_SPEND_TXT)}")',
   '      :',
   [PICK, HSPAWN]),
  ("doctor prefers mtime over fetched_at", DOCTOR,
   "fa=\"$(jq -r '.fetched_at // empty | floor' \"$f\" 2>/dev/null)\"",
   'fa=""',
   [DOC]),
]

def main():
    i = int(sys.argv[1]); name, path, find, repl, suites = MUTANTS[i]
    p = pathlib.Path(path); src = p.read_text()
    n = src.count(find)
    if n != 1:
        print(f"[{i}] HARNESS ERROR {name}: find-string occurs {n} times"); sys.exit(3)
    mut = src.replace(find, repl)
    if mut == src:
        print(f"[{i}] HARNESS ERROR {name}: replacement is a no-op"); sys.exit(3)
    try:
        p.write_text(mut)
        if subprocess.run(["zsh", "-n", path]).returncode != 0:
            print(f"[{i}] HARNESS ERROR {name}: mutant does not parse"); sys.exit(3)
        died = []
        for s in suites:
            r = subprocess.run(["bash", s], capture_output=True, text=True)
            tail = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
            if r.returncode != 0:
                died.append(f"{s}: {tail}")
        print(f"[{i}] {'DIED' if died else 'SURVIVED'} {name}" + ("" if not died else f" — {'; '.join(died)}"))
    finally:
        p.write_text(src)

if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Dry-run every mutation for applicability first** — for each index `i` in 0–11, check that the find-string occurs exactly once without running the suites:

```bash
for i in $(seq 0 11); do MUT="$MUT" python3 - "$i" <<'PY'
import os, sys, pathlib, importlib.util
spec = importlib.util.spec_from_file_location("m", os.environ["MUT"]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
name, path, find, repl, _ = m.MUTANTS[int(sys.argv[1])]
print(sys.argv[1], pathlib.Path(path).read_text().count(find), name)
PY
done
```

Expected: every line shows count `1`. Fix any find-string that shows 0 or >1 to match the code as actually written before running the sweep.

- [ ] **Step 6: Run the sweep one mutant at a time** (this box kills long jobs under memory pressure; one invocation per mutant, `nohup`-detached if run in the background):

```bash
for i in $(seq 0 11); do python3 "$MUT" "$i"; done 2>&1 | tee "${MUT%.py}.log"
git status --short   # must be clean of zshrc.herdr / claude.sh changes — the driver restores
```

Expected: 12 lines, every one `DIED`, zero `SURVIVED`, zero `HARNESS ERROR`. A survivor means a row cannot fail: add or fix the row it names, re-run that one mutant, and record the fix in the commit message. Do not delete a mutant to make the count clean; if one is genuinely unkillable, say why in a comment beside the code it defends.

- [ ] **Step 7: Commit**

```bash
git add zsh/zshrc.herdr CLAUDE.md
git commit -m "docs(picker): record DO-621's weekly windows and spend wall

12 mutants, 12 deaths (sweep log in the PR description).

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

The branch is then ready for a PR; opening it follows the `quantivly-conventions:prs` skill and is not part of this plan.
