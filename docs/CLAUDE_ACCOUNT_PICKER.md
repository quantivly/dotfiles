# Claude account picker, tenants and pools

The evidence behind how `claude()`, `hspawn` and `claude-pick` choose which account a session bills:
the score, the eligibility tiers, the round-robin ledger, and the per-directory tenant table. Rules
are in [CLAUDE.md](../CLAUDE.md); the credential side is in
[CLAUDE_ACCOUNTS.md](CLAUDE_ACCOUNTS.md).

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-622), from the tree at `dab17b3`.**
> Nothing was rewritten — paraphrase is the one loss no check can see. So in the text below
> "this file" means CLAUDE.md, and "above", "below" and "N sections up" refer to its layout at
> that commit; `git show dab17b3:CLAUDE.md` restores the context. **Add new evidence here, not to
> CLAUDE.md** — the rules stay there, the evidence lives here.

---

## The smart account picker (DO-574)

**The old ranking answered "which account is least used"; it could not answer "which account will
still be usable in twenty minutes".** It sorted on the worse of the 5h and 7d utilization, then live
holders, then name — so an account at 3% of a 5h window that resets in four minutes outranked one at
20% with the whole window ahead of it, and every session in a quiet minute landed on the same seat
because a deterministic sort has no memory. `_claude_pick_for_dir` replaces it with a score plus
eligibility classes plus a round-robin ledger, and `scripts/claude-pick` exposes the same code path
as a command so herdr-draft and a human can ask before launching.

**One function, because the parts drift.** `claude()`, `hspawn` and `claude-pick` each used to
resolve their own tenant and report their own reasons. Which account a session bills is exactly the
thing nothing announces afterwards, so resolve → candidates → classify → score → exhaustion →
backpressure → ledger is one function that also produces the explanation. `_claude_pick_profile`
remains as a thin tenant-less alias for one release; the compatibility rows in
`scripts/test-hspawn.sh` are written against it and pass unchanged, which is what proves the pool,
overflow and refusal semantics of #129/#131 survived.

The score, in centipoints, integer arithmetic only (no `zsh/mathfunc`, which the state table's
from-scratch `PATH` cannot vouch for): `base` is 5h headroom; `bonus` is use-it-or-lose-it, scaled by
**both** headroom and closeness to the reset, so a nearly-spent window resetting soon earns almost
nothing and a fresh window earns nothing extra; `weekf` is weekly headroom as a **multiplier**;
`weekf_eff` and `bonus_w` are DO-621's two weekly-reset terms — `weekf`'s penalty fades as the week's
own reset nears, and a consume-first bonus scaled by weekly headroom is added (see that section); and
`crowd` charges each live holder more on an account that is already busy. Knobs:
`CLAUDE_PICK_W_EXPIRE`, `_W_WEEK_EXPIRE` (200 — DO-621), `_W_HOLDER`, `_W_CROWD`, `_WEEK_LOW`,
`_RR_BAND`, `_5H_EXHAUSTED`, `_WEEK_EXHAUSTED` (inert, 101 — see below), `_WEEK_SPENT` (100 — the
demotion tier, DO-609), `_CACHE_MAX_AGE`, `_LOAD_WARN`, `_SWAP_WARN`, `_LOAD_MAX`, `_SWAP_MAX`,
`_LOCK_WAIT`, `_PROC_ROOT` (a test hook).

**Three departures from the approved spec, each measured rather than argued.**

**The demotion is a TIER, not a weight — DO-609, and the first version got this wrong.**
`weekf` multiplies `(base + bonus)` while `crowd` is subtracted **unscaled**, so at `weekf=0`
the score collapses to `-crowd` — and `crowd` is near zero precisely because an exhausted
account is idle. Measured 2026-09-10 on the live machine: `quantivly-0` and `quantivly-3` at
`7d=100%` with one holder scored **-300** and were picked, while `quantivly-1` at `7d=33%` with
real headroom and 11 holders scored **-8334**. The emptiness that exhaustion causes read as
headroom — the same shape this file already records for the ranking DO-574 replaced, where the
emptiness came from a quarantine. `crowd = h*(300 + u5*15)` is also unbounded in holders, so it
can sink a perfectly fresh account: 11 holders at `u5=61` costs 13,365 against a maximum `base`
of 10,000.

The fix is the one the `unknown` branch's own comment had already argued for, three lines from
the defect: *"expressing it as a score would put it at the mercy of the weights"* — and it even
names this case, *"an eligible account at 96% with a spent week scores near zero too"*. A spent
week is now its own class, `weekly-spent`, ranked **below `eligible` and above `unknown`** (a
measurement outranks the absence of one) and still scored internally so the tier is ordered
rather than falling to whichever name sorts first. It **demotes and never refuses**: a tier is
chosen when nothing above it exists, so an entirely-spent pool still yields an account and still
starts a session — DO-574's measured decision kept intact, but no longer able to lose to a
crowding term. `CLAUDE_PICK_WEEK_SPENT` (100) is the threshold.

The tier also had to be added to the **overflow** guard, and that was the one unpinned edit:
overflow borrows another tenant's account, so it is paid only when the pool named nothing usable
at all, and a weekly-spent member *is* usable. Dropping it from that guard left all 197 other
rows green while a capped-but-usable pool silently borrowed someone else's seat — a row now names
it. **An unpinned fix is an unverified fix, and a surviving mutant is the only thing that says so.**

- **The weekly window DEMOTES; it never refuses.** §5.3 made `uW >= 100` an exhaustion class that
  every headless caller refuses on. Measured 2026-09-10: two Team seats read `seven_day = 100` **with
  live sessions on them**, their per-model `weekly_scoped` windows read 38 and 54 (so the block is
  partial), and there were **zero** weekly-reset refusals across 750 transcripts in 7 days — the
  refusal that class was modelled on has never fired. What a Team seat actually hits is *"You've hit
  your individual spend limit · run /usage-credits to ask your admin for a higher limit"*, 34 times in
  24 h, whose remedy is **a person raising a limit**, not a window rolling over; refusing locally
  never makes such an account usable sooner. With all three work accounts at 100 that morning, a hard
  block would have refused across the entire work tree while work was demonstrably possible.
  `CLAUDE_PICK_WEEK_EXHAUSTED` stays as an **inert** knob defaulting to 101, and a mutant proves that
  lowering it to 100 makes the "a spent week is still eligible" row fail.
- **`CLAUDE_PICK_CACHE_MAX_AGE` stays 3600, not the spec's 900, and `claude-usage-refresh.timer` is
  dropped.** There is no refresh entry point to build it on: clauth's only writer of
  `usage_cache.json` is its scheduler, every fetch is gated on a lease acquired in exactly two places
  — its TUI and its daemon — and no CLI subcommand takes it. Probed against caches already 207–282 s
  old, `clauth which`, `status --json`, `list`, `sessions` and `jobs` left every mtime unchanged to
  the second, and `clauth --help` has no `refresh`; a 15-minute sample at 10 s resolution recorded
  **zero** writes while ~29 panes were open, the caches aging monotonically to 20m45s. At 900 s every
  profile would read `unknown` for most of the day and the picker would rank on nothing. The honest
  follow-up is an upstream request for a first-class `clauth refresh [profile]`.
- **A negative `r5` earns no bonus.** `.five_hour.resets_at` **can be absent** — measured on three of
  five profiles, absent exactly where utilization is `0.0`, i.e. an unstarted window — and §5.3's
  `100 - min(100, max(0,r5)·100/18000)` yields **100**, the *maximum* urgency, for a window that has
  already reset. The spec only reached that value because it routed `r5 < 0` through a post-reset
  class that re-fetched the cache first, and no such refresh exists. Without it the cached `u5`
  belongs to the previous window and is an **upper bound** on the true one — pessimistic, therefore
  safe — so the reading is kept and only the bonus is dropped.

**Classes are TIERS, not scores.** "Unknown never outranks a measurement" is a rule about rank, and
expressing it as arithmetic puts it at the mercy of the weights: an eligible account at 96% of its 5h
window with a spent week also scores 0, so as a score the rule reduces to whichever name sorts first.
`excluded` is never chosen; `unknown` ranks after every measured candidate but is still chosen when
nothing else remains; `exhausted` is the refusal class.

**The callers deliberately disagree about an exhausted pool, and that asymmetry is the decision.**
Interactive (`claude`, `claude-as`, `claude-pick`) proceeds on the least-bad member — the one whose
blocking window resets soonest — and prints the loud §5.4 block. Headless (`hspawn`,
`claude-pick --strict`, herdr-draft) **refuses**, naming every member's window and the earliest reset.
A human blocked by a window that clears itself in minutes is the worse outcome; a worker started on a
spent window burns the seat and dies mid-task unwatched. Both messages come from one reporter, because
they are the same facts read two ways and a second copy is a second place to forget that **no time may
be invented** — `resets_at` is absent whenever the window has not started, so "no reset instant" is the
common case, not an edge.

**An exhausted pool does NOT reach overflow, and that is not the same rule as an empty one.**
Overflow is consulted only when the pool named nothing that exists at all — borrowing another
tenant's account bills work to the wrong place, so it is paid only when the alternative is no
isolation. An exhausted pool is a real wall that clears itself, with a reset time to quote; borrowing
a seat to get past it would bill the wrong tenant permanently for a wait of minutes.

**A pin overrides the ranking, so it never refuses on the account — but it says what it was handed.**
`--profile <p>` / `CLAUDE_ACCOUNT_PROFILE` skips scoring entirely, and when the named account is
`exhausted` or `excluded` (clauth's own quarantine) that is one stderr line and a `warnings[]` entry,
never an exit code: "it started and died twenty minutes in" is the outcome the line prevents, and
overriding the ranking is exactly what the flag is for. The credential is still checked — reporting a
name nobody can authenticate as hands the caller a config dir that Claude Code answers by writing a
fresh independent login, manufacturing the very independent holder the account-dir design forbids.
Every refusal reports a **null** profile, including the pinned path, which had to be taught it
separately because it sets `REPLY` before the machine is ever measured: a JSON object naming an
account beside a non-zero exit is one a caller can act on by mistake.

`scripts/claude-pick` is `#!/usr/bin/env zsh`, symlinked to `~/.local/bin/claude-pick` (on the herdr
server's frozen `PATH`, so a plugin finds it without a server restart). It sources `github.sh` and
`zshrc.herdr` under `CLAUDE_PICK_SOURCING=1` and **not** `system.sh` — `--explain` prints plain lines
of its own, because `system.sh` is the full install's and a CLI that dies on a missing module fails at
the one moment its answer is wanted. Exit codes are the contract: **0** picked · **2** refused,
exhausted or nothing usable · **3** refused, a machine ceiling · **4** the tenant table is unusable ·
**5** no profile has a credential · **64** usage. `--strict` is the only thing that switches semantics
and there is **no TTY sniffing**: a command whose refusal behaviour depends on whether its output is a
pipe makes both its rows and its callers conditional, and herdr-draft passes `--strict` itself.

**Backpressure is warn-only by default (D6 as amended).** `load1` from `/proc/loadavg` (×100 integer),
online cpus from `/sys/devices/system/cpu/online`, swap from `/proc/meminfo` — forkless, and skipped
rather than divided by zero when `SwapTotal` is 0. Every caller warns past `CLAUDE_PICK_LOAD_WARN`
(150% of threads) or `CLAUDE_PICK_SWAP_WARN` (60%); only a `*_MAX` knob, explicitly set, refuses, and
only for a headless caller. This laptop is deliberately oversubscribed and must keep working: the
picker's job is to choose an account, not to police the box. The measurement is **published** rather
than localised so `--explain` and the JSON report the numbers the refusal was decided on — reading
`/proc` a second time could legitimately differ, and then the report would not be about the decision.
**Measured first, acted on last:** the read happens before the tenant table and the profile census,
so *every* exit path reports the machine (herdr-draft's failure row shows these numbers), while the
verdict is deferred so that an unusable table (4) and no credential at all (5) — faults a person must
fix — outrank a transient ceiling (3). An earlier version read it after the census and its own comment
claimed "every exit path", which was false for exactly those two.

Defects found by writing the rows, every one of which had a **passing test** first:

- **jq's `empty` inside `[ … ]` produces no element**, so every absent field shifted the remaining
  ones left: a profile with no `resets_at` read its weekly figure as the reset instant, and one with
  no `five_hour` block reported `seven_day` as the 5h utilization. `// null` keeps the column.
- **Fixing that left it fully intact**, because `IFS=$'\t' read` collapses runs of tabs — tab is an
  IFS *whitespace* character. The same defect in two layers. `${(@ps:\t:)line}` preserves empties.
- **An empty file glob made `jq` read STDIN and hang.** `(N)` suppresses the no-match error but yields
  an empty expansion, leaving jq with no file operands. clauth creates `~/.clauth/live_sessions` as a
  directory, so an empty one is an ordinary resting state — and this runs on **every** `claude` launch,
  which would then never return. It passed earlier runs only because their stdin happened to be at EOF.
- **The ledger was written with a literal backslash-t.** `print -r` is precisely the flag that disables
  escape expansion, so `"$p\t$v"` wrote `a1\t175…`; the reader found no tab and discarded every entry.
  The file was the right size and got a new inode on every write, so the atomicity row passed
  throughout while round-robin silently degraded to "always the top score".
- **`zsystem flock` opens without `O_CREAT`, so the pick lock had NEVER been acquired.** A lock file
  that does not exist is not an unlocked lock — it is an open failure, which lands in the
  proceed-unlocked fallback, and since nothing else creates that path it lands there forever. The row
  covering it asserted the **warning**, which the broken state produces too, so it passed from the
  start; its own background holder failed to open the same missing file, so nothing was ever held. The
  missing row was the one that asserts the *uncontended* case is silent. `: >>`, never `: >`, so a
  create cannot truncate a lock somebody is holding.
- **`strftime -r` parses through `mktime`, which reads a broken-down time as LOCAL and discards any
  offset `strptime` parsed** — so cutting `…T00:00:00.000000+00:00` at its first `.` and parsing the
  rest yields an instant wrong by the machine's own UTC offset. Measured here at UTC+2: two hours
  early — and this zone is UTC+3 in summer, which is 60% of an 18000 s window. Not cosmetic: `r5`
  drives the bonus over exactly that window, and it shifts every reset time the messages print —
  the number a reader uses to decide
  how long to wait. `local TZ=UTC` (function-scoped) plus the string's own zone applied arithmetically,
  because `%z` would be discarded by the same `mktime`. **The rows that existed could not catch it:**
  they asserted an absent reset is `unknown` and an unparseable one is `unknown`, and a wrong number
  satisfies neither. **And a UTC machine cannot fail the fixed rows at all**, so the fixture timezone is
  now explicitly non-UTC (`XXX-3`, the POSIX form, which needs no tzdata) — CI runners are UTC.
- **The band's tie-break sorted by the score's TEXT, not by name.** Entries are `"<score>\t<name>"`
  strings, so `${(o)}` over them ordered by score text; with an empty ledger every candidate's time is
  0, `<` is never true, and the first in iteration order won — which inside the band handed it to the
  **lowest-scoring** member and put any negative score ahead of every positive one. The rule was
  documented as "then name" throughout.
- **`CLAUDE_TENANT_BUCKETS` was declared `typeset -gA` in #129**, copying §5.1, which declares it
  associative and then shows a one-element **list** as its example. `typeset -gA B; B=( "a b" )` fails
  with *"bad set of key/value pairs"* and the assignment does not happen. Masked here only because the
  tenant data file re-declares it `-ga` first.

**Four rows were decoration, and no two failed for the same reason** — which is the useful part,
because none of the four reasons is visible by reading the row:

- *The fixture's answer was the same either way.* "An eligible account beats an unreadable one" used
  a candidate at 10% against an unknown, and 9000 against 0 is far outside `RR_BAND` — so scoring the
  unknowns alongside the eligible ones changed nothing. The tier is only observable where the score
  would *not* have separated them, which is the case the rule exists for: an eligible account at 96%
  with a spent week also scores 0.
- *The fixture could not reach the branch.* "config_dir is null under `--dry-run`" ran with no
  executable account-dir builder, so `null` was the answer on both paths. `null` is also what a
  broken builder gives, which is why the row needed its pair — a real run reporting the dir it built.
- *Both renderings agreed on that machine.* The JSON says `null` for an unmeasured load and the report
  says `unknown`, and every fixture read the real `/proc`, where the two are identical. A mutant
  swapping one for the other survived until a fixture with an unreadable `/proc` existed.
- *The row asserted the wrong artefact.* The ledger lock's row asserted the **warning**, which the
  never-once-acquired state produces too. Only "the uncontended case is silent" could fail.

Two mutants are **retired rather than pinned**, each with its reason written beside the code it
defends. Stripping a trailing `Z` before `strptime` is defence in depth: measured here, glibc's
`strptime` ignores trailing input, so removing that arm is behaviourally identical and the mutant can
never die — it stays because the function's contract is "split the instant from its zone, then apply
the zone", and an implementation that works only because `strptime` is lax is one strict `strptime`
away from returning `unknown` for every UTC instant. And quoting the `auth_broken` span was never a
leak vector: the `sed` range is anchored at the assignment and quits at the first `]`, so the span is
a list of profile names, and `profiles.toml` carries no credential at all. The class it was meant to
pin — "a diagnostic gains a file dump" — is pinned instead by a mutant that makes `--explain` dump the
pick ledger, which does die. **A mutant that can never die is worse than no mutant, because it reads
as coverage.**

Two things went away with the old ranking, and both were dead the moment nothing called them:
`_claude_profile_load` (which answered "the worse of the 5h and 7d utilization" — the whole of the
old ranking) and `CLAUDE_ACCOUNT_CACHE_MAX_AGE`. The threshold is `CLAUDE_PICK_CACHE_MAX_AGE`. A dead
function beside a live one that reads the same file is an invitation to reintroduce the old ranking by
accident, so it is removed rather than left.

**`scripts/claude-pick` is checked by exactly one thing, and it took finding out to keep it that
way.** It is extensionless on purpose — it is a command on `~/.local/bin`, so `claude-pick.zsh` would
put the implementation language into the name a user types and into herdr-draft's config. CI's
ShellCheck job globs `*.sh`/`*.bash`/`*.zsh`, so it never selects it; pre-commit's ShellCheck matches
by `identify`, which types a `#!/usr/bin/env zsh` shebang as `shell` and WOULD have picked it up and
failed, since ShellCheck cannot parse zsh; and `script-must-have-extension` would have rejected the
name. Both hooks now exclude it by path, and CI's `zsh -n` loop names it explicitly — otherwise the
repo's newest executable would have had no syntax check at all.

State tables: `scripts/test-claude-pick.sh` (192 at DO-574; **283 at `0b0f8c0`, 294 after the
runaway-span rows** (this read 293 until 2026-09-18; measured twice, deterministic — a
one-digit error in the very sentence whose point is that a count carries its commit) — the "205" this line carried was stale by 78, which is what a count without
its commit decays into; CI job `claude-pick-test`),
`scripts/test-hspawn.sh` (319 → 328, the caller-wiring rows and the compatibility contract) and
`scripts/test-claude-doctor.sh` (156 → 172, the usage-cache freshness line). **40 mutants, 40
deaths**, every mutation dry-run for applicability first — and the two retirements above are comments
in the harness rather than entries, so the count is of mutants that can actually die.

**An instant rebuilt from a delta reads the clock twice, and the second read is a
bug (DO-612).** `json_instant` rendered `resets_at` for `--json` as
`EPOCHSECONDS + d`, where `d` was the remaining-seconds figure the metrics layer
had computed earlier — so any second boundary falling between the two reads made
the rendered instant **one second late**, drifting later on every re-render and
never earlier. Measured on the state table before the fix: the row asserting that
field failed **1 run in 6**, always by exactly +1s. It arrived with DO-574 in
`#135` and was deliberately left out of `#139` to keep that diff reviewable.

Three things about it outlast the one-line fix:

- **A freshness figure and a renderable instant are different values, even when
  one is derived from the other.** `_claude_ts_delta` already computed the
  absolute epoch as `secs - off` and then threw it away to return a delta. The
  fix publishes what the function had rather than computing anything new, and
  the delta stays the delta — **scoring genuinely wants "seconds from now"**, so
  replacing it would have broken the use-it-or-lose-it bonus to fix a renderer.
- **A flaky row cannot pin a fix, and it is worse than no row.** The existing row
  was probabilistic, so reverting the fix passed it three runs in four — and a
  row that fails one run in four on `main` trains everyone to re-run a red row,
  which is how a real failure gets re-run away. The pin is deterministic instead:
  `json_instant` now takes an absolute epoch, so a mutant restoring
  `EPOCHSECONDS + at` renders **2155** where the fixture says 2099. Same rule as
  the SIGPIPE race two sections up — pin at the source, where the answer is
  deterministic and free, not at the behaviour, where it can only be statistical.
- **The pinned path builds its own explain row**, so it is a second place the
  field can be dropped, invisible to every row that takes the ranked path — and a
  `--profile` caller is exactly who most wants the reset, having been handed a
  spent seat and deciding whether to wait. It has its own row.

The record is **10 fields wide now, appended and never inserted**: every reader
indexes it positionally (`_claude_pick_publish` takes `f[4]`..`f[10]`), so a
field added anywhere but the end shifts the ones after it and each reader
silently returns its neighbour — the shape that already produced a false
`CREDENTIAL STATE CHANGED` here.

**8 mutants, 7 deaths and one retirement**, the retirement documented beside the
code it defends: the `&&` on the metrics assignment is unpinnable **alone**,
because the parser resets both outputs to `unknown` before any of its return
paths, so assigning unconditionally is behaviourally identical. Deleting **both**
that reset and the guard does die, on three rows. That is this file's own rule
applied rather than restated — *count how many independent deletions it takes to
reach a silent pass, not how many guards exist* — and the guard stays, because
code that is correct only because a function it calls happens to pre-clear its
outputs is one refactor away from carrying a stale epoch into a profile that has
none.

**The eighth mutant was missing until the sweep was audited row by row, and that
is the cheap half of review working.** Dropping `- off` cannot kill the `+00:00`
rows, because the offset is zero in them — so after seven mutants, nothing yet
proved those rows could fail at all. Publishing the *delta* under the absolute's
name kills twelve. Ask of a mutation SET what this file already asks of a row:
which of these rows would still pass if the value were simply wrong?

Two things found while writing the rows, both the familiar shapes. **A new row
that calls `new_home` steals the fixture of every row below it** — three rows
placed mid-section silently re-pointed `_CPM_RW is the aggregate weekly reset` at
a profile with no weekly reset, and it failed for a reason that had nothing to do
with it; the fixture-replacing rows go last, and say so. And **the rows that
reconstruct an instant to check the zone arithmetic have the same defect they are
now testing for** — they survive it only because their two clock reads are
microseconds apart. They are left as they are, deliberately: the delta's zone
handling still needs pinning, and the new rows read the published epoch directly,
so no row added for this reads a clock at all.

**Deliberately NOT fixed, and named so it is not mistaken for done:**
`_claude_pick_reset_text` — the §5.4 human line — rebuilds its instant the same
way. It renders at **minute** resolution, so the drift is visible only when the
true instant's seconds component is 59, and closing it means widening two more
positional records (`_claude_pick_exhausted`, `_claude_pick_leastbad_reset`). The
measurement is here so the next person can decide with the number in front of
them.

**A mutation sweep on this box has to be CHUNKED, and the harness has to refuse to start.** A single
40-mutant run takes over an hour at the load this machine normally carries, and it was killed for
memory three times partway through — the same pressure that kills background jobs here. Each mutant
is independent and the harness restores the source between them, so a chunked sweep measures exactly
what one long run measures: `MUT_FROM=<file>` / `MUT_TAKE=<n>` select a chunk, and the driver
recomputes what is left from its own log every pass, so a kill costs at most the chunk in flight. The
run this section reports was finished one mutant per pass, launched `nohup`-detached — a
harness-tracked background job is what the memory reaper takes first, and every watcher waiting on
this one was reaped while the detached driver kept going. Three properties are load-bearing rather
than tidy:

- **The signal handler must `os._exit`, not `sys.exit`.** `sys.exit` raises `SystemExit`, so the
  `finally` block runs too — and it restores from a backup the handler has just removed, which fails
  with `FileNotFoundError` and buries the reason the run stopped. The handler has already done the
  cleanup; nothing else should.
- **A leftover `.mb7` backup is a REFUSAL, not a warning.** If one is on disk, a previous run died
  mid-mutation and the source *is* a mutant — so every mutation measured after it is measured against
  a mutant, and the sweep is meaningless while looking perfectly normal. Self-healing (restore, then
  continue) is right for the harness; refusing outright is right for a driver that would otherwise
  chunk straight across the damage.
- **Do not edit the source between chunks.** That is the one thing a chunked sweep does not survive,
  and it happened here: an edit landed mid-sweep, was overwritten by the next mutant's write, and then
  by the final restore. The file looked hand-edited, and then did not.

Verify the composition afterwards, too, rather than trusting the tally: this run's log was checked
for 40 **distinct** names each appearing **once**, because a resumable driver that recomputed its
to-do list wrongly would happily run one mutant twice and report 40.

## Weekly windows and the spend wall (DO-621)

**`max()` over heterogeneous windows reported two seats spent on opposite axes as the
same state.** On 2026-09-18 quantivly-1 read `seven_day` 83 with `7d fable` 100, and
quantivly-3 read `seven_day` 100 with `7d fable` 63; both came out `weekly-spent (100%)`.
The ranker now reads the aggregate `seven_day` alone (per-model windows belong to the
gate, which knows the model — DO-623), a lapsed week is unmeasured rather than spent, and
a cache is dated from clauth 0.15.2's `fetched_at` where it has one — the file mtime
otherwise, so a 0.15.1 clauth still works and a plan-only rewrite stops reading as fresh.
That last mechanism is **upstream's, not a local measurement**: clauth #74 is where
`fetched_at` is stamped on a live fetch alone, so a rewrite that only touches the plan
advances the mtime and leaves the reading's own timestamp where it was.

**Spend headroom is the signal that separates free, billed and blocked**, measured the
same day from clauth's `usage_history.jsonl` (about two days retained) and transcripts:

| Seat state | What happens |
|---|---|
| window not spent | free — quantivly-1's aggregate rose 77 → 86 over the 27 h from 09-17 19:09, with spend flat at $190.77 throughout |
| window spent, spend headroom left | usage **bills usage credits** — +$0.31 at 09-17 19:07 and +$0.28 at 19:09, within 4 min of a window reaching 100, the only spend increases in the retained history across all three work seats |
| window spent, spend at its limit | **blocked** — "You've hit your individual spend limit", 6 errors, each quoting that seat's own weekly reset |

Rows 1 and 2 are the same seat and the same $190.77 and they do not contradict each other,
which the first version of this table left the reader to work out: the two increments are
what took the figure to $190.77 at 19:09, and the flat run is everything after that
instant. Without the timestamps it reads as one seat whose spend is both rising and flat.

**One episode each way, and they are not on the same axis.** The blocking row is
aggregate (quantivly-3 at `seven_day` 100 with $275.23 of $275). The billing row is not:
what reached 100 was `7d fable` while the aggregate sat at 77, so *a spent window bills*
is measured and *a spent AGGREGATE bills* is an inference from it. Max seats have
`spend.enabled = false`; that a spent window blocks them is inferred from the field, not
observed.

This refines DO-574 rather than reversing it: its 2026-09-10 seats were **not blocked** —
live sessions ran on them — and nobody measured their spend that day, so "they were billing"
is the inference drawn from the table above, not something anyone observed then. The ranking
tiers are therefore `eligible` (free) > `weekly-spent` (bills — and
the pick says so in a warning `claude()` prints) > `unknown`, with `exhausted` outside the
ranking as the refusal class that a live spent week with spend `none` now joins. Spend
`unknown` never escalates to `exhausted` — missing data is not a wall — and its warning
says "may bill" rather than "bills".

**What the Max-seat inference costs, since it is an arm nobody has watched fire.**
`_claude_profile_metrics` maps `spend.enabled == false` to **`disabled`** (DO-623 split it out of
`unknown`, which it shared until then), not to `none`, so a
Max seat at 100% of its week is DEMOTED to `weekly-spent` and stays choosable. The blocking
arm fires only where it was measured: a Team seat whose spend has reached its limit. Both
non-work tenants are composed entirely of Max seats with no overflow, so refusing on the
inference would empty them for up to a week; demoting costs one session that fails at auth
and names the reason.

**Consume-first on the week, without switching the week off.** `weekf` stays, its penalty
fading as the weekly reset nears (`weekf_eff`), plus a consume-first bonus scaled by
weekly headroom (`CLAUDE_PICK_W_WEEK_EXPIRE`, 200). The weight is set against
`CLAUDE_PICK_RR_BAND` (800), not in isolation: inside the band the least-recently-picked
seat wins, so at 50 the spec's own example — 40% of the week **left** resetting in 6 d,
against 20% **left** resetting in 12 h — was a 630-point coin flip. (Every other
percentage in this section is a utilization; these two are headroom, which is what makes
the arithmetic come out at 300 against 930.) An adversarial review caught that, and caught
that removing `weekf` outright switches weekly headroom off entirely below 100% — with no
weekly reset to read, an idle 99% seat then scores exactly as an idle 20% one. **A weight is
only meaningful relative to the band that decides ties** — check it against the band, and
assert the PICK, not the score.

**The "Fable · Requires usage credits" banner is not evidence about windows** (a
server-side flag on every Team profile; a notice, not a block). The first draft of this
design called a spent `7d fable` window "worth a refusal" on the strength of it. That is
the #123 failure — a correlation plus a plausible mechanism — recurring one document over
from the repo's own record of #123 ([CLAUDE_ACCOUNTS.md](CLAUDE_ACCOUNTS.md)), and it was
caught in review rather than by any measurement.

Rows: `scripts/test-claude-pick.sh` (metrics, cache age, scoring, the spend wall, the
billing warning, which wall a refusal quotes, and the `CLAUDE_PICK_WEEK_SPENT` guard),
`scripts/test-hspawn.sh` (the warning reaches `claude()`),
`scripts/test-claude-doctor.sh` (the doctor dates caches the same way, and one row runs
both age readers over one fixture). Spec:
`docs/superpowers/specs/2026-09-18-do-621-weekly-picker-design.md`.

## The gate and the model's own window (DO-623)

**The gate asked only about the 5h window, so a lane could pass it and die at its first
weekly check.** The 2026-09-18 blocking episode above is exactly that: six "You've hit your
individual spend limit" errors on a seat the gate would have passed. `claude-pick --gate`
now runs a weekly arm **after** every 5h arm — so a 5h refusal keeps its own state — over
the aggregate `seven_day` and every per-model window whose label governs the lane's
`--model`. A window is a candidate only at or past `CLAUDE_PICK_WEEK_SPENT` (100), and a
spent window is a wall only where the seat cannot bill past it:

| `_CPM_SPEND` | means | gate, on a live spent window |
|---|---|---|
| `none` | `enabled:true`, `used >= limit` | **refuse** `gate-spend-wall` |
| `headroom` | `enabled:true`, `used < limit` | allow, `bills_credits: true` |
| `disabled` | `enabled:false` — a Max seat | allow, `bills_credits: null` |
| `unknown` | no spend block, or a non-numeric `used`/`limit` | **refuse** `gate-unmeasured` |

A lapsed window (dated by `fetched_at`) allows whatever the spend; an undated one refuses
as `gate-unmeasured`. rabota maps `gate-spend-wall` to `credential:window`, because
unlisted states fall to `credential:unmeasured` and a measured refusal would then read as
"could not measure".

**Why `disabled` allows, since it is the arm that reads as inconsistent.** The DO-621 spec
said a spent window with spend `unknown` refuses — "the gate is never optimistic". That was
written when `unknown` meant "no spend block on disk"; Part A's final revision then mapped
every Max seat there too, so the table as written would have refused every Max-seat lane
with a spent model window. The split, decided 2026-09-19:

- **The number is fine; only its consequence is unknown.** Every other `gate-unmeasured`
  refusal is about a figure that describes nothing — stale, rolled, undated. Here the
  utilization is freshly fetched with a live reset. "Never optimistic" was written about
  measurements, not about a good measurement of unknown effect.
- **Nobody has watched a Max seat block on a spent window.** personal-0 reads `used 134.43`
  against `limit 125.0` with `enabled:false`, which is not the shape "no credits" predicts.
  Refusing on the field name is the #123 failure again — a plausible mechanism standing in
  for an observation.
- **It is the asymmetry Part A already resolved.** `personal` and `toysim` are composed
  entirely of Max seats with no overflow. Once DO-624 routes `hspawn` through the gate,
  refusing would empty both tenants for up to a week; Part A chose to demote for this seat
  class, and the gate refusing outright where the ranker only demotes is strictly worse.
- **A truly blocked Max seat fails at the first request**, not twenty minutes in — and the
  mid-lane death is what the gate exists to prevent.

`unknown` keeps the refusal, now applying only to the missing data it was written about.

**Which window governs a lane.** clauth 0.15.2 builds a label as `"7d " + name.lowercase()`
from the scope's model `display_name`. The lane's model id loses a trailing `[…]`
(`opus[1m]` → `opus`) and is split on `-`; a label governs when its first word after `7d `
**equals** one of those tokens — whole tokens, so `fablex` does not match `7d fable`, and
`7d sonnet 5` matches `claude-sonnet-5`. **`7d claude` governs nothing**: every model id
begins `claude-`, so it would turn one spent surface window into a refusal for the whole
seat. With no governing label there is no per-model check. When several windows govern,
the **worst** decides — a live refusal outranks any other refusal (`undated`,
`unreadable`), a refusal outranks an allow, then the higher utilization wins — because
highest-utilization alone lets a lapsed 100 (allow) mask a live 100 with no headroom
(refuse), and lets an undated 100 listed first report a walled seat as `gate-unmeasured`
rather than `gate-spend-wall`, which rabota maps differently. The aggregate is evaluated **after** the model windows, so on a tie the
lane's own window is the one reported.

**A lapse needs a real clock.** A per-model window whose reset is past counts as `lapsed`
only when the cache carries `fetched_at`; with only the file mtime it is `undated` and
refuses, because a plan-only rewrite keeps a cache "fresh" while the window lapsed and
refilled (F13: two profiles went 7% → 100% in forty minutes).

**The unreadable aggregate is not a candidate.** Part A maps a lapsed week to
`_CPM_UW = unknown`, so the gate cannot tell a lapsed aggregate from an absent one. When
`uW` is `unknown` the aggregate arm does not run: lapsed already allows, and refusing on the
absent half would invent a refusal on seats the gate passes today. The per-model arm is
unaffected, and the 5h arms still demand a live, fresh, dated window, so a cache that broken
fails there anyway.

**What the gate object reports**, as built — the spec predicted less precise rules:

- `spend` — the `_CPM_SPEND` state that decided.
- `model_window` — `{label, utilization, resets_at, state: live|lapsed|undated|unreadable}`
  for the governing **candidate** window, i.e. one at or past the threshold, or one whose
  utilization is not a number (`unreadable`, with `utilization: null`). `null` when the
  governing window is below the threshold, and `null` when the aggregate decided.
- `bills_credits` — `true` when a live spent window is allowed on headroom; `null` when a
  `disabled` seat is allowed, **and on any refusal** (a refused lane bills nothing and was
  not asked to); `false` when no spent window governs.
- A `CLAUDE_PICK_WEEK_SPENT` that is not a non-negative integer refuses as
  `gate-misconfigured`, naming the variable and the value — beyond the spec, on the gate's
  existing rule that a bad tuning value is never a silent default.

**Measured on the real cache, 2026-09-19** (read-only, `--dry-run`). quantivly-1 was at
spend $252.17 of $250 (`none`) with `seven_day` 100: a Fable lane refused as
`gate-spend-wall` on `7d fable` (`live`), and an Opus lane refused on the aggregate with
`model_window` null. personal-0, `disabled` with a 30% week, allowed a Fable lane. The
plan's verification expected quantivly-1 to still have headroom and a Fable lane to be
allowed on it; by the time the arm ran, the seat had spent through its limit.

**Unreadable data refuses.** A governing window whose utilization is not a number refuses
as `gate-unmeasured` (state `unreadable`), and per-model windows that cannot be decoded at
all refuse as `gate-unmeasured`; a malformed element (a non-string label or reset) is
coerced to one row rather than aborting the decode and taking every later window with it.

Rows: `scripts/test-claude-pick.sh` (the "gate: the weekly spend wall" block — the four
spend states, the pin, scoping, attribution, worst-of-matches, malformed and unreadable
windows, a failed decode (through a jq shim), lapse and precedence, the
aggregate cases and the threshold guard; plus the `disabled` metrics rows),
`scripts/test-hspawn.sh` (a `disabled` seat's wording reaches `claude()`),
`rabota/tests/test_budget.py` (`gate-spend-wall` → `credential:window`). Plan:
`docs/superpowers/plans/2026-09-19-do-623-gate-model-window.md`.

## Tenants and pools (DO-599)

**The pool answered "which account", never "which account for THIS directory".** One flat
`CLAUDE_ACCOUNT_POOL` is directory-blind, so the account a session billed had no relationship to the
code it was working on: a session started in a personal repository could burn a work account, and a
work repository could burn a personal one, with nothing reporting the mismatch. gh identity and git
identity were *already* routed by repository remote (`_gh_route_for`; `hasconfig:remote.*.url` in
`~/.gitconfig.local`), so Claude account selection was the one identity on this machine that ignored
the directory — and the three could disagree about the same repository, silently.

`_claude_tenant_for <dir>` closes that using **the same rule, not a second one**: remote owner first,
a path prefix only for a directory with **no** GitHub remote, then a default. It **reuses**
`_gh_repo_remotes` / `_gh_url_owner` rather than copying them — a second URL parser here would give
the machine two answers to "who owns this repo", which is the drift this layer exists to remove. It
therefore inherits #127's rules verbatim: an unparsable GitHub-looking URL **counts as a GitHub
remote and blocks the path table** (guess nothing), `git-error` **stops** rather than falling through
to the default, and `~user` in a prefix is `bad-table`.

**Mechanism here, accounts as data outside.** The table is `~/.config/claude-tenants.zsh` (override
`$CLAUDE_TENANTS_FILE`), sourced by `zshrc.herdr` itself — *not* from `~/.zshrc.local`, which holds
secrets (the secret-emission hook refuses to read it) and is sourced later anyway:

```zsh
CLAUDE_TENANT_ROUTES=( "quantivly=work" )              # owner-glob=tenant, any remote
CLAUDE_TENANT_PATH_ROUTES=( "$HOME/quantivly=work" )   # only for a dir with NO GitHub remote
CLAUDE_TENANT_DEFAULT=personal                         # empty = indeterminate, state `none`
CLAUDE_TENANT_POOL=( work "quantivly-1 quantivly-2 quantivly-3" personal "personal" )
CLAUDE_TENANT_OVERFLOW=( )                             # used ONLY when a pool has no candidate
CLAUDE_TENANT_GH_DIR=( work "$HOME/.config/gh-quantivly" )
```

**`CLAUDE_ACCOUNT_POOL` keeps its exact meaning.** No table loaded → the resolver is skipped and the
flat pool decides, byte-identically; a row asserts that, because it is what a modular adopter runs
on. `zsh/zshrc.herdr` also stays sourceable **alone**: `_gh_repo_remotes` lives in `github.sh`, which
a modular adopter does not have, so the resolver gates on `(( $+functions[_gh_repo_remotes] ))`,
reports state `unsupported`, warns **once per shell**, and falls back to path routes plus the
default. `unsupported` survives a later path match *and* the default — a caller must be able to tell
a complete answer from one computed with half the table unreadable.

Overrides, highest first: an inherited `CLAUDE_CONFIG_DIR` (never overridden) → `CLAUDE_ACCOUNT_PROFILE`
/ `claude-as` → `CLAUDE_ACCOUNT_TENANT` / `hspawn --tenant` → the resolver. A pinned tenant skips the
resolver but **not** the ranking inside its pool: pinning says where to bill, not which account to burn.

`claude-tenants-apply-gh` derives the gh tables from the same data, so adding a root is one edit
rather than two that can disagree. It is **defined in `zshrc.herdr` and deliberately never called
there**: load order is `zshrc.herdr` → `zshrc.company`, which **assigns** `GH_ACCOUNT_ROUTES=(…)`
wholesale and would discard anything added first → `~/.zshrc.local` → the machine's own overlay,
which calls it as its last line. Only that caller knows the order has ended. It is additive and
idempotent, and never removes or reorders a team default.

Traps this area has, each of which produced a **passing test** first:

- **An unknown tenant WIDENS the pool.** A tenant with no `CLAUDE_TENANT_POOL` entry yields an empty
  member list, and the membership test reads an empty list as "no filter" — i.e. *every* account on
  the machine, which is exactly what this layer exists to prevent. The table check catches a tenant
  named in the table; a caller-supplied one (`CLAUDE_ACCOUNT_TENANT`, `hspawn --tenant`) never passes
  through it, so the picker **refuses** rather than falling back to a pool nobody asked for.
- **An unusable TABLE widens it the same way, and that one shipped.** When the resolver cannot answer
  — `bad-table`, `git-error`, or an empty `CLAUDE_TENANT_DEFAULT` — the caller leaves the tenant empty
  and lands on `CLAUDE_ACCOUNT_POOL`, and an **empty** flat pool means "every registered profile".
  So one mistyped character in the tenant file silently bills personal work to a work account. It was
  latent while `CLAUDE_ACCOUNT_POOL` was still set to the three work accounts (wrong, but bounded);
  deleting that assignment — the very cleanup the tenant table makes correct — is what exposed it.
  **Measured 2026-09-09: with a one-character error in the tenant file, `~/Projects` picked
  `quantivly-3`, and it read as an ordinary successful launch**, because the reason lives in
  `_CLAUDE_TENANT_WHY` and the announcement never showed it. The picker now refuses when a table is
  configured **and** no explicit flat pool is set, naming the state and the reason. Both other
  combinations are unchanged and each is pinned: no table at all with no flat pool still means every
  profile (the modular adopter's whole mechanism), and an explicitly-set flat pool is still honoured
  as the deliberate override it is.
  The general shape is worth more than the instance: **a guard that narrows a set must treat "empty"
  and "unconfigured" as different**, because most collection tests read an empty filter as "match
  everything" — so the failure is always a silent widening, in the direction of the thing the filter
  existed to prevent.
- **A corrupt `.git` directory is not a `git-error` fixture.** git calls that *"not a repository"*, so
  it resolves to `no-repo`, and the row asserting "git-error stops" passed while testing nothing. A
  real one is a `HOME` whose `~/.gitconfig` does not parse — how `test-gh-routing.sh` makes one, and
  reachable in production because `~/.gitconfig` is a managed symlink into this repo.
- **A suite inherits `CLAUDE_CONFIG_DIR` from the developer's own isolated session**, and `claude()`'s
  first act is to honour an inherited one and skip everything below it — so four of five integration
  rows passed while asserting nothing. The same leak `test-hspawn.sh` already records for its spawn
  rows. `claude()`'s isolation block is *also* gated on `clauth` being present and the account-dir
  builder being executable, and a fixture lacking either never reaches the resolver — which matters
  because "the resolver was not called" is precisely what those rows assert.
- **`claude()` calls `_update_gh_config` before the exec** (guarded — it lives in `zshrc.company`).
  gh's token and the GitHub MCP plugin's are both frozen for the life of the process, so that is the
  one moment the pin can still be made right: the DO-596 incident shape, closed where it can be.

**Both overflow rows were decoration on the first pass, and they failed differently** — worth more
than the rows themselves, because neither reason is visible by reading the row:

- *The fixture could not reach the branch.* "Overflow is NOT consulted while the pool still has one"
  used a tenant with **no overflow list at all**, so the loop's second guard (*overflow is empty*)
  ended the pass by itself and the row passed with the "pool still has candidates" check deleted.
  It needs a tenant with a working pool **and** a non-empty overflow.
- *The row's output was identical either way.* "A pool and overflow that are both empty do not claim
  an overflow pick" left the pick failing, so it printed nothing whatever the flag held. A reset only
  matters when the pick still SUCCEEDS by another route, so the fixture needs a working last-resort
  account for the assertion to be about anything.

Ask of every new row: **what single change to the code would make this fail?** If the answer is
"none", it is decoration — and it will look exactly like a passing row until a mutant says otherwise.

**A row that verifies a write HAPPENED is not a row that verifies the write is READABLE.** DO-574's
round-robin ledger was written with `print -r -- "$p\t$v"`, and `-r` is precisely the flag that
disables escape expansion — so every line got a literal backslash-t. The reader found no tab, split
nothing, and discarded every entry. The file was the right size and got a **new inode on every
write**, so the atomicity row passed throughout; the ledger simply read back empty and round-robin
degraded to "always the top score" in silence. Assert the round trip — write, read back, compare —
not the artefacts of writing.

State tables: `scripts/test-hspawn.sh` (269 → 315) and `scripts/test-gh-routing.sh` (199 → 207).
Every fix is pinned by a mutant that dies (19 mutants, 19 deaths), and every mutation is dry-run for
applicability first — a mutation that no longer applies reads exactly like a surviving mutant.
