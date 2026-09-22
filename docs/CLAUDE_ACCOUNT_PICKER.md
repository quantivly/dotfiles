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

- **In the ranker, the weekly window DEMOTES; it never refuses** (the gate is another matter —
  see the DO-623 section). §5.3 made `uW >= 100` an exhaustion class that
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
and names the reason. The headless gate, which has no one watching, refuses it instead — see
the DO-623 section below.

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
| `disabled` | `enabled:false` — a Max seat | **refuse** `gate-unmeasured` |
| `unknown` | no spend block, or a non-numeric `used`/`limit` | **refuse** `gate-unmeasured` |

A lapsed window (dated by `fetched_at`) allows whatever the spend; an undated one refuses
as `gate-unmeasured`. rabota maps `gate-spend-wall` to `credential:window`, because
unlisted states fall to `credential:unmeasured` and a measured refusal would then read as
"could not measure".

**Why `disabled` refuses, while the ranker only demotes it.** The DO-623 plan proposed
allowing a Max seat on a spent window, and the branch first shipped that (`bills_credits:
null`), arguing that the utilization is a good measurement whose *consequence* is unknown and
that refusing would empty the all-Max `personal` and `toysim` tenants once DO-624 routes
`hspawn` through the gate. **The user decided on 2026-09-19 to keep the approved spec's rule
instead: refuse, reported as `gate-unmeasured`** (the reason says "no spend limit configured
(a Max seat)" and quotes the seat's own spend figures). The evidence behind the decision:

- **The gate is never optimistic, and nobody has watched a Max seat run past a spent
  window.** "Unknown whether it bills or blocks" is an unmeasured consequence; the gate's
  rule for every unmeasured thing is to refuse.
- **The on-disk API error records (2026-09-05..09) hold many real "You've hit your
  individual spend limit · run /usage-credits to raise it" and "monthly spend limit"
  errors.** The *raise it* wording (not "ask your admin") is consistent with individual
  seats. This is suggestive, not proof: the records could not be attributed to a seat.
- **personal-0's `used 134.43` against `limit 125` with `enabled:false`** fits "extra usage
  was on, overran, and was switched off". Either way the seat has no overflow.
- **It is the cheaper error.** If such a seat would block, refusing loses nothing; if it
  would run, the cost is a refused lane until the window resets — against a lane that dies
  mid-task, which is what the gate exists to prevent.

It is `gate-unmeasured`, not `gate-spend-wall`: the block was never measured, and rabota maps
the two differently. **The ranker and the gate now deliberately differ** (the approved
spec's decision 6): `_claude_pick_class` still only *demotes* a spent Max seat to
`weekly-spent`, because an interactive session that fails at auth names its reason, while
the headless gate refuses. The `disabled` state stays split out of `unknown` — it is what
lets the gate give an accurate reason and the ranker's warning say "no spend limit
configured" rather than "spend headroom unknown". A **lapsed** window still allows on a Max
seat, as on any seat.

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
- `bills_credits` — `true` when a live spent window is allowed on headroom; `null` **on any
  refusal** (a refused lane bills nothing and was not asked to) and when **no weekly figure
  governing the lane was read at all** (the aggregate unreadable and no per-model window for
  the model — `false` would claim a free lane on no measurement); `false` only when at least
  one governing figure was read and none is spent.
- A `CLAUDE_PICK_WEEK_SPENT` that is not a non-negative integer refuses as
  `gate-misconfigured`, naming the variable and the value — beyond the spec, on the gate's
  existing rule that a bad tuning value is never a silent default.

**Measured on the real cache, 2026-09-19** (read-only, `--dry-run`). quantivly-1 was at
spend $252.17 of $250 (`none`) with `seven_day` 100: a Fable lane refused as
`gate-spend-wall` on `7d fable` (`live`), and an Opus lane refused on the aggregate with
`model_window` null. personal-0, `disabled` with a 30% week, allowed a Fable lane (no
window spent, so the `disabled` rule never came into play). The
plan's verification expected quantivly-1 to still have headroom and a Fable lane to be
allowed on it; by the time the arm ran, the seat had spent through its limit.

**Unreadable data refuses.** A governing window whose utilization is not a number refuses
as `gate-unmeasured` (state `unreadable`); so does a spent window with **no `resets_at` at
all** (state `undated` — for the aggregate too, which the metrics layer keeps at its number
when the reset is absent, since an absent reset is not a lapse). Per-model windows that
cannot be decoded at all refuse as `gate-unmeasured` — **unless the aggregate is a measured
live wall** (spend `none`), which the metrics layer read without the decode and which is then
reported as `gate-spend-wall`. A malformed element (a non-string label or reset) is coerced
to one row rather than aborting the decode and taking every later window with it. The lane's
model id is matched **case-insensitively** (`--model Fable` is governed by `7d fable`).

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

## The last resort, and the seat another machine owns (DO-632)

**`_claude_fallback_profile` is the one selection path that consults no pool** — by
construction, since the pool is what has just come up empty. It hands out clauth's *active*
profile so that a session still gets an account of its own rather than the shared global
`~/.claude/.credentials.json`, where one bad write logs every session on the box out. That
much is right and is unchanged.

What was wrong is that a profile is absent from every pool on this machine **for exactly one
reason: another machine owns that seat**. `~/.config/claude-tenants.zsh` says so in its own
words — refresh-token rotation is server-side, so a profile this laptop hands out *and* a
server logs in as are two independent holders of one grant, and they log each other out. The
last resort walked straight past the only place that rule lived.

**Measured, 2026-09-19**: a session in this repo ran on `personal-1`, nanoclaw's seat — the work
pool was unusable (one seat at 100%, one behind the spend wall), so the fallback took clauth's
active profile. That is the part this change stops, and it is the part that was observed.

**The cost is a correlation, and is written as one.** 2026-09-18 22:16:03: `clauth: login for
'quantivly-0' has expired: refresh token revoked or invalid`, then a human `/login`; two laptop
sessions were found on that seat on 09-19, through `clauth start` (a door DO-641 has since
closed), and `quantivly-0` is the EC2 box's, in no pool here. But that rejection is
`RefreshError::Invalid`, which **cannot distinguish a double-spend from a genuine server-side
revocation** — [CLAUDE_ACCOUNTS.md](CLAUDE_ACCOUNTS.md) settles that, inside a correction whose
stated purpose is to stop this inference being rendered as an entailment. A double-spend is
therefore the live hypothesis, not a finding, and the next revocation on this box still has to be
diagnosed from the daemon journal rather than attributed from here. The mechanism the rule rests
on is not in doubt: refresh-token rotation is server-side, so two machines logged in to one
account are two independent holders of one grant.

The fix is DO-641's own predicate, `claude-profile-foreign`, not a second reading of the same
table: it honours `CLAUDE_FOREIGN_PROFILE_OK` for a deliberate borrow, and it **re-reads the
tenants file when the table is not in memory**, which is the shell an agent gets — a Claude
Code Bash-tool snapshot carries functions but no variables, so an in-memory-only check would
be present and blind in precisely the sessions that spent the seat.

- **Where the fallthrough lands matters more than the skip.** Skipping alone would trade a
  visible wrong account for an invisible one: the caller then drops onto the shared credential
  (`claude()`) or refuses (`hspawn`, `--strict`), and a silent decline reads as *"clauth's
  active account did not exist"*. So `_claude_fallback_profile` **sets** rather than prints —
  a global cannot be read out of a `$( )`, the rule this file already records for `REPLY` —
  and publishes `_CLAUDE_FALLBACK_PROFILE` / `_CLAUDE_FALLBACK_WHY`. The picker turns those
  into a `_claude_pick_warnings` entry naming the seat, its owner and what happened instead,
  plus the terse `_claude_pick_skipped` phrase `claude()` joins into its `refused:` list.
  **Which surfaces print it, exactly:** `claude()` and `hspawn` loop over the warnings on every
  launch — those are the two that actually start a session — `claude-pick --explain` / `--json`
  carry both arrays, and since DO-664 the bare `claude-pick` names every refusal on stderr. Its existing block already reads correctly for
  this case: *"NO usable account — not the pool, and not clauth's active one."*
- **Nothing is invented in its place.** Falling through to some other locally-owned profile
  was considered and rejected: `claude()`'s own comment is that *"inventing a profile would
  bill an account nobody picked"*. clauth's active profile is a seat a human chose; the next
  name down is not.
- **Every other decline is now reported too** — quarantined, disabled — because all of them
  were silent, and a session on the shared credential was left to guess which.
- **The boundary, pinned rather than papered over:** a pool that *lists* an owned profile
  still ranks it. That is a table contradicting itself, not a door; closing it would put a
  tenants-file read on every candidate of every pick. A row asserts the current answer, so
  moving it is a decision.
- **DO-664, found by review of this change:** the CLI's one refusal line lived inside the gate
  block (`if (( gate && rc == 0 ))`), so it fired only for a *gate* refusal on an otherwise
  successful pick — while its own comment claimed it served "every other exit-2 refusal".
  Measured: `unusable` (2), `bad-table` (4) and `no-profiles` (5) all exited with **no output on
  either stream**. It now fires for every `rc != 0`, and three states are excluded because
  something else already spoke: `exhausted` (the §5.4 block), `--explain` and `--json`. Each
  exclusion has a row, since "prints twice" and "prints once" are indistinguishable from an exit
  code. The broader lesson is the one this file keeps paying for: **a comment describing what a
  line does is not evidence the line is reachable.**
- **The duplication this named is now closed (DO-665).** rabota kept a second copy of the same
  fact as `[machines.<m>].profile`; it asks instead. See below.

State table: `scripts/test-claude-pick.sh` (452 → 476). **19 mutants, 18 deaths**, each dry-run
for applicability first. What the sweep cost, written down because it is the part worth reusing:

- **A malformed mutation reads as a strong result.** The first sweep's "check order swapped" did
  not swap the two checks, it *nested* them — syntactically valid, semantically a different
  mutant — and recorded 7 kills for a mutation nobody ran. The true swap **survived**, and it is
  not cosmetic: a seat that is both machine-owned and quarantined then reports `auth broken —
  clauth login a1`, telling the operator to log in to the one seat they must not touch. Ownership
  is answered first because it is the stronger statement — about this *machine*, not about the
  credential — and two rows now pin it. Dry-running for applicability catches a mutation that does
  not apply; it does not catch one that applies and means something else. Diff the mutant.
- **Four more survivors, all of them silent drops of the seat's name:** the report raised on the
  *success* path (a session happily running on a seat announces that the last resort declined it);
  the `_claude_pick_skipped` entry gated on `owned by *` alone, which restores the silence for the
  *commoner* quarantine case while every row stays green; the report composed after
  `_claude_pick_reason`, collapsing it to a bare "no usable account" with both arrays still
  correct; and the knob name dropped from the message, leaving seat and owner intact and removing
  the only pointer to the table that decided. Each has a row now.
- **One mutant is EQUIVALENT, not uncovered:** testing `_CLAUDE_FALLBACK_PROFILE` instead of
  `_CLAUDE_FALLBACK_WHY` at the call site. That line is reached only when the function returned 1,
  and every `return 1` path either sets both globals or leaves both empty — which is true only
  *because* the per-call reset is there. Two independent analyses failed to construct a
  divergence. Recorded rather than papered over with a row that would assert nothing.


## The machine registry (DO-665)

**"Which machine owns which clauth seat" was written down twice**, in two files, two formats and
two languages: `CLAUDE_TENANT_MACHINE_OWNED` in the tenants file (profile → a human label) and
`[machines.<m>].profile` in rabota's tenant TOML (machine id → profile). Nothing checked they
agreed, and divergence is silent in both directions — reassign a seat in one and the other goes
on gating the seat that machine no longer bills.

**They were not redundant copies, they were inverse mappings in different vocabularies.** Nothing
connected the label `"dev (EC2)"` to the machine id `dev` except a person reading both files, so
neither could be derived from the other. That is why the fix adds `CLAUDE_TENANT_MACHINE_ID`
(profile → machine id) beside the existing table rather than deleting one side: the missing link
was the machine id, and once it is written down the tenants file can answer both questions.

**Which copy survived, and why that direction is the whole decision.** A stale copy on the
dotfiles side fails **open and silently**: `claude-profile-foreign` reads an empty table as "no
machine owns anything", and the DO-632 / DO-641 guards simply stop refusing with nothing said.
rabota fails **loudly** — a missing seat is a `Refused` naming the file. So the hand-edited copy
stays where staleness would not be noticed, and the loud side asks. Choosing the direction by
"which file feels canonical" would have put the generated artefact on the silent side.

**And nothing is generated.** A rendered file is the same defect one level down, so
`scripts/machines-render` prints on demand and rabota shells out to it at config load — the
same boundary `rabota doctor` already crosses to reach `claude-pick`. One `zsh -f` fork per load.
The fork is `claude-tenants-owner`'s exactly: a bare shell that declares the arrays, sources the
tenants file **at top level** and prints, so a plain assignment, `typeset -A` and `typeset -gA`
all behave alike.

- **A fault is never an empty registry.** An empty registry is a *real* answer — a modular
  adopter owns no machine, and so does a file declaring owners but no machine ids — while every
  other way of ending up with nothing exits non-zero. Conflating the two turns "the renderer is
  missing" into "no machine has a seat", which reads as a configuration choice and disables every
  seat gate without a word. **This took three cuts to get right, and the honest summary is that
  enumerating causes did not work; only a class-wide guard did.**
- **The renderer cross-checks the two halves against each other**: a profile owned but unnamed, a
  machine id for a seat nobody owns, or two profiles claiming one machine are each exit 1 naming
  the offender. `--check` validates and prints nothing, so it is usable from a hook.
- **A leftover `profile` key in a `[machines.<m>]` table is refused, not ignored.** A second copy
  that merely loses is still a second copy, and the losing one is what somebody edits.
- **A label is data.** The document is built by `jq` from typed pieces, never by concatenation:
  one apostrophe in `"Zvi's box"` is the difference between a document and a syntax error, and a
  `printf` implementation passes every other row.
- **Deliberately not moved:** `ssh`, `repos`, `state_dir`. They are machine-ish but they are not
  *duplicated*, so moving them buys tidiness and costs a migration across `remote.py`, `lane.py`
  and `census.py`. Robustness here comes from closing divergence, and there is none there.

**What a cold review found in the first cut, because it is the failure this file keeps paying
for.** The renderer forked `zsh -f`, sourced the tenants file and ignored the fork's status — and
a file that could not be sourced returned `{}` with **exit 0**, which `--check` passed. One
unbalanced quote in the canonical file would have disabled rabota's seat gate while the *other*
reader of that same file stopped refusing, silently: both halves of the pair this change exists
to prevent, at once. Three separate causes, each now its own row:

- **A parse error.** The discriminator is `zsh -n` before sourcing, and it has to be — a `source`
  that fails to parse *returns* to the forked shell, which then runs the loops over empty tables
  and prints any completion sentinel quite happily (measured; the first proposed fix was a
  sentinel and it did not work). The source's *status* cannot serve either: it is the status of
  the file's last command, which is why `claude-tenants-owner` ignores it.
- **A path that is not a regular file.** A directory passes both `-e` and `-r`; `-f` is the test.
- **A subscript assignment to another table.** The fork declared only the two machine tables, so
  `CLAUDE_TENANT_POOL[work]=…` — valid everywhere else, because `zshrc.herdr` declares that name
  `-gA` before sourcing — raised *"assignment to invalid subscript range"* and aborted the source
  at that line. The fork now declares every table `zshrc.herdr` does, and `CLAUDE_TENANT_MACHINE_ID`
  was added to both `-gA` declarations there for the same reason.

**A second review found the first fix covered only the PARSE subset**, and three more shapes
reached `{}` with exit 0 — each of which `zsh -n` passes, the sentinel survives, and the source's
status cannot distinguish:

- **CRLF line endings.** Every line becomes `ARR=( … ) ^M`: a *command-local* assignment for a
  command named `^M` that does not exist. Valid syntax, and no editor shows it.
- **A UTF-8 BOM**, which makes line 1 a command with an invisible name.
- **A subscript assignment to a table the fork does not pre-declare** — the original defect again,
  for any `CLAUDE_TENANT_*` name added after the list was written.

So the guard is the **class**, not a fourth special case: the fork does nothing but declare,
source and print, so **any** byte on its stderr came from the tenants file and is a fault.
Measured 0 bytes for the real file, for a file ending in a false command (which must keep
working), and for every fixture in the state table. The pre-declaration list survives as a
convenience that avoids refusing a file that is fine, and a row cross-checks it against
`zshrc.herdr`'s in both directions — it is a third copy of that list, in a change whose thesis is
that an uncross-checked copy is the defect.

**What still cannot be detected, stated rather than implied:** a tenants file that ends early
*silently* — a `return`, or a guard like `has_command jq && TABLE=( … )` — parses, runs cleanly,
prints nothing, and declares nothing. That is what the file's self-contained contract forbids in
prose, and no reader can tell it from an honestly empty file.

**And declaring no machine ids at all is "not adopted", not drift** — it is every pre-DO-665
tenants file. Refusing it would make every rabota command exit 2, including `rabota doctor`, the
tool you would reach for to find out why. A *partial* pair is still refused.

State tables: `scripts/test-machines-render.sh` (65, new CI job `machines-render-test`) and
`rabota/tests/test_machines.py` (15 of the suite's 422 → 437). **28 mutants, 27 deaths**, each
dry-run for applicability — including the stderr guard discarded, the parse check removed, `-f`
weakened to `-e`, the dangling-symlink test removed, the fork declaring only the two machine
tables again, an empty `_MACHINE_ID` treated as drift, a tab accepted in a label and in a profile
name, each cross-check dropped, faults computed but never refusing, the label concatenated rather
than typed, and a Python-side failure returning an empty registry.

**Two mutants survived the first sweep**, both because the rows asserted an exit code where two
different guards produce the same one: a directory fails `zsh -n` as well as `-f`, and a rejected
label is dropped from the tables so the cross-check refuses it anyway. Asserting the *message*
killed both. A row that cannot distinguish the two answers is decoration however carefully it is
worded.

**A third pass, this one adversarial about the ROWS rather than the code, found 34 surviving
mutants — none of them a wrong answer, all of them unasserted behaviour.** Two were worth the
whole exercise:

- **`config.load` could swallow a renderer failure into `{}` and pass all 436 rabota rows.** Every
  row proving the guarantee lived *inside* `machines.registry`; none sat at the seam where such a
  fallback would actually be written, and `except errors.RabotaError: seats_by_machine = {}` is
  exactly what a well-meaning later edit looks like. A row now asserts the exception reaches the
  caller.
- **The `__DONE__` sentinel looked like dead weight** — four mutants could delete or neuter it
  with the suite green — because every input the suite offered was intercepted by an earlier
  guard. It is not dead: a tenants file that kills its own shell produces no stderr and no
  sentinel, and with the check disabled that fixture renders `{}` and exits 0. The guard was
  unfixtured, not useless, and its message was describing causes that now fail earlier.

The rest were promises without rows: "a tab **or a newline**" with only a tab fixtured, an
identical check in the second table exercised in neither, a pre-declaration list where one of
seven names was covered, refusals carrying `$TENANTS` that no row read, and a two-argument
invocation. Each now has a row. **A row that names a behaviour is not a row that tests it.**

**One mutant is EQUIVALENT and is left alive deliberately:** restoring `val="${key#*\t}"` for a
marker line with no tab. It is unreachable while the key and value checks stand, since a marker
line then always carries exactly one tab — but it is kept as the second line of defence for the
day someone removes the key check, which is the change that made that branch reachable in the
first place.


## The other reader of that same file (DO-674)

**DO-665 hardened the renderer and left the guard exactly as it was**, and the section above says
why that mattered without noticing it had happened: `claude-tenants-owner` forked a bare `zsh -f`,
**ignored its exit status and discarded its stderr**, so any tenants file that ran without
populating the table answered *"nobody owns anything"* and every DO-641 door stopped refusing,
silently. Measured on the live machine on 2026-09-21, after DO-665 had deployed — five files, one
guard off, the other reader refusing all five:

| tenants file | `claude-profile-foreign fz` | `machines-render` |
|---|---|---|
| CRLF line endings | rc 1 — **not foreign, guard OFF** | exit 2 |
| an unterminated quote | rc 1 — **not foreign** | exit 2 |
| a subscript assign to an undeclared table | rc 1 — **not foreign** | exit 2 |
| a UTF-8 BOM | rc 1 — **not foreign** | exit 2 |
| `has_command jq && TABLE=( … )` | rc 1 — **not foreign** | exit 2 |

**The direction is the decision, and it is refuse.** The renderer's consumer is rabota, which
refuses loudly; this function's consumers are `clauth start`, `clauth <p>`, `claude-as`, `hspawn -p`
and the picker's last resort — things a person runs all day — so the obvious reading is that a
stray CR must not stop every launch. The asymmetry says otherwise. Wrongly *allowing* is the DO-641
incident reproduced exactly: a seat spent silently, invisible to both machines, which is how two
sessions came to be billing dev's seat from the laptop. Wrongly *refusing* is a named error
carrying zsh's own complaint, it lands only on someone who has just edited the file, and
`CLAUDE_FOREIGN_PROFILE_OK=1` — which the refusal prints, and which short-circuits the fault check
as well as the ownership one — is one command away.

**DO-665's precedent supports that direction rather than cutting against it**, and the distinction
is worth keeping straight: the renderer is lenient about an **unadopted** registry (an empty
`_MACHINE_ID` is exit 0, so `rabota doctor` still runs) and strict about a **broken** file. Same
split here. No tenants file, and a file that owns nothing, stay rc 1; a file that exists and cannot
be trusted is rc 2 and every door refuses.

**The accepted cost, stated rather than discovered later:** on this machine the tenants file is
also the pool source, so a broken file leaves `claude` with no last resort and it reports no
account until the file is fixed or the escape hatch is used.

**`command claude` bypasses all of this, and is the wrong reach.** It skips the `claude()` wrapper
outright, so there is no ownership guard — but also no picker, no tenant routing and no per-session
account dir: it runs on whatever `CLAUDE_CONFIG_DIR` already holds, which in a fresh shell is the
shared global one, i.e. the many-holders-of-one-grant state this file opens by describing.
`CLAUDE_FOREIGN_PROFILE_OK=1 claude` is the escape to use, and the one the refusal prints: it turns
off *this* guard for one command and leaves every other layer standing.

- **The predicate has three answers now** — 0 + the owning machine, 1 not foreign, 2 + a fault
  description — and the fault text rides on **stdout** beside the owner, because every caller reads
  it through `$( )` and a global cannot cross a command substitution.
- **`claude-foreign-door` is new, and dashed.** Three doors repeated the same presence test and
  command substitution; a third answer would have made that three near-identical `case` statements,
  and the argument for one emitter is the argument for one door. It absorbs the `$+functions` test,
  so the existing fail-open-when-the-predicate-is-absent rows keep their exact meaning.
- **The last resort declines rather than refuses**, reporting through `_CLAUDE_FALLBACK_WHY` with
  its own wording — naming the *file*, never a machine, since none was identified.
- **`has_command jq && TABLE=( … )` was recorded as undetectable in three places and is not.** It
  is a command not found in a bare `zsh -f`, so it writes to the fork's stderr and the class guard
  catches it; `machines-render` had been refusing it since DO-665 while this file's prose said it
  could not be seen. Only the genuinely **silent** early exit — a `return`, `[[ -n "$UNSET" ]] &&
  TABLE=( … )` — remains undetectable, and those three claims now say so.
- **`print -u2 -- "$x" | sed 's/^/    /'` does not indent anything.** The pipe reads fd 1, so
  writing to fd 2 first hands `sed` an empty stdin: the tenants file's own complaint came out flush
  left, reading as a second message rather than as this one's evidence. DO-665's copy had the
  defect; both are fixed and both now have a row, counted as *no line escaped the indent* rather
  than *N lines got it*, so the row is not about the fixture's length.

State tables: `scripts/test-hspawn.sh` (412 → 464), `scripts/test-claude-pick.sh` (497 → 503) and
`scripts/test-machines-render.sh` (65 → 66). **15 mutants, 15 deaths**, each dry-run for
applicability and the mutated region diffed before a kill was booked.

**Two survived the first sweep, and both were real gaps rather than wording.** Trimming the fork's
pre-declaration list survived everything, because every fixture in the suite used a table name that
is undeclared either way — the row that kills it asserts the *mirror* of the undeclared-table row,
that a subscript assignment to a table the list **does** declare is not a fault. And `mktemp`
failing was treated as a clean read, disabling the class guard silently; it is reachable only by
fault injection, so the row puts a failing `mktemp` on `PATH` ahead of the real one for one command.
Note that `test-machines-render.sh`'s list cross-check cannot see the first of those: it compares
the two files' *declaration lines*, and `zshrc.herdr`'s top-level declaration still names every
table however the fork's copy inside it is trimmed.

**The sweep itself destroyed the first attempt**, which is worth recording because the mistake is
invisible in its own output: restoring each mutant with `git checkout --` reverted the *uncommitted
implementation* along with it, so every later mutant reported `NOT APPLICABLE` and two reported
kills against the pre-change file. Back the files up and restore from the copy, or commit first.
