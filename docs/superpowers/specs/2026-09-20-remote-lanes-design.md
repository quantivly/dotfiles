# Remote lanes: dispatch, measure, close — design

**Status:** approved in brainstorming 2026-09-20 (Zvi, sections 1–5). Not yet a plan.
**Next step:** `superpowers:writing-plans` produces the implementation plan from this document.
**Supersedes:** DO-635 Part D (`dev-spawn`, filed as DO-642). See §3.

**Goal:** dispatch a *measured* agent lane to a remote machine and close it, through the one gate
every spawner shares. Concretely: make `rabota lane recipe --machine dev --run` work.

**Objectives it serves** (Zvi, 2026-09-20, in his order): total throughput across machines; seat
efficiency; reliability with less hand-maintained state.

---

## 1. Problem

The laptop (`cilantro`) is saturated while two remote boxes idle. Measured 2026-09-20:

| | cilantro | dev (EC2) | nanoclaw (Hetzner) |
|---|---|---|---|
| cores / load1 | 8 threads · 13.4 (DO-635) | 16 · 0.2 | 4 · 0.00 |
| memory | 56% swap | 13 GiB avail of 61 | 13 GiB avail of 15 |
| herdr | 0.9.0 · ~22 sessions | 0.9.0 · 1 pane, 0 agents | 0.9.0 · 1 pane, 0 agents |
| claude | 2.1.278 | 2.1.272 | 2.1.273 |
| clauth | yes | absent | absent |
| seat | personal-0, quantivly-1/3, toysim | quantivly-0 | personal-1 |
| other load | everything | 47 swarm services / 70 containers | Sol production |

rabota v2 already models the solution: lanes are systemd units placed by `(tenant, machine, seat)`,
gated on credential → machine → counts, with `claude-pick --gate` as "the one gate every spawner
shares" (`rabota/rabota/budget.py`). `[machines.dev]` is already declared in the live tenant config.

**It cannot dispatch a lane anywhere today.** Four things block it:

1. `~/.dotfiles-local/rabota/tenants/quantivly.toml` has no `[seats]` table and no
   `[machines.dev].profile`, so `budget.seat_for()` raises `Refused("no seat configured…")` — for
   `local` as well as `dev`.
2. `_machine_reasons()` and `_count_reasons()` are `return []` stubs (`budget.py`, "replaced in
   Task 4").
3. `census.py` carries `DEFERRED = ["deferred:sol", "deferred:machines"]`; `census.json` holds a
   single `machine{}`, the local one.
4. There is no `lane` command. `rabota/rabota/commands/` holds `brief budget census doctor inbox
   ingest precompute preflight rank sync`.

## 2. Decisions taken

| # | Question | Decision |
|---|---|---|
| 1 | `dev-spawn` or `lane recipe` for remote dispatch | **`lane recipe`.** DO-642 is superseded (§3) |
| 2 | Does dev need rabota installed | **No** (§4.4). WS6.3 shrinks accordingly |
| 3 | Does the gate read dev's window from dev | **No, not in S0** (§4.2). The laptop's monitoring grant is authoritative |
| 4 | nanoclaw as a lane target | **No.** "Hetzner never runs lanes" (consolidation-design §6) stands; it is a production box |
| 5 | Brief transport | **stdin**, never argv (§4.4) |
| 6 | Evaluate lanes across machines | **Same machine as the lane they evaluate** (§4.5) |

## 3. Why not `dev-spawn`

`dev-spawn` (DO-635 Part D, DO-642) calls none of `seat_for`, `credential_gate`, `budget`, the lane
store or `census`. It is a second spawner that skips the gate rabota's design names as shared. Against
the three objectives: it cannot place work by measured load (throughput), it spends a window unmetered
(seat efficiency), and `CLAUDE_TENANT_MACHINE_OWNED` becomes a second hand-kept copy of a mapping
`[machines.<m>].profile` already expresses (reliability).

Its review findings F1 (no `HERDR_PLUGIN_*` exports), F2 (no `--permission-mode`), F3 (bash `%q`
re-parsed by dev's zsh) and F6 (unvalidated `DEV_SPAWN_HOST`) are all defects of reimplementing what
herdr-draft and rabota already do. They become moot rather than fixed.
Evidence: `~/quantivly/handoffs/2026-09-20-do-635-plan-review.md`.

**Why it was built:** STATUS.md "Blocker A" — the auto-mode classifier refused
`ssh dev "systemd-run --user …"` twice, so "no lane could be dispatched at all." An architectural fork
was created to route around a permissions problem. §4.6 addresses the permissions problem directly.

**herdr-draft is not the alternative either.** consolidation-design §4.7: "**It does not run headless
lanes.** It types into a PTY and needs `HERDR_ENV=1` … Panes as a lane runtime is the audit's named
failure class … The lane's cgroup, `MemoryMax`, journal and clean stop come from systemd." This
retracts recommendation #2 of the 2026-09-20 plan review, which was wrong.

## 4. Design

### 4.1 Config

Add to `~/.dotfiles-local/rabota/tenants/` (private repo; a gated write):

```toml
# quantivly.toml
[seats]
local = "quantivly-1"

[machines.dev]
profile = "quantivly-0"      # joins the existing ssh / tenants / repos / state_dir

# personal.toml, toysim.toml
[seats]
local = "personal-0"
```

`[budget]` needs no change: `max_local_sessions`, `max_lanes_local`, `load1_per_cpu`,
`swap_pct_max`, `mem_available_min_gib`, `profile_5h_pct_max` are all present.

This is the first change to make and the cheapest. Until it lands nothing else is testable.

**`--machine` is already wired.** `rabota budget` declares
`--machine` with `choices=["local", "dev"]` (`rabota/rabota/commands/budget.py`). Adding a machine
therefore means editing that list as well as the tenant config — a place a third machine would fail
with an argparse error rather than a named refusal. `lane recipe` should take its machine from the
same constrained source rather than declaring a second one.

### 4.2 The gate for a remote seat

`rabota budget --machine dev` runs **on the laptop**:

```
seat_for(tenant, "dev") → [machines.dev].profile → quantivly-0
credential_gate(...)    → claude-pick --gate --profile quantivly-0
                        → the laptop's clauth cache for quantivly-0
```

The 5h and weekly windows are server-side per *account*, so the laptop's **monitoring** grant reports
what dev's own login would. Dev never needs clauth. This is why DO-635 decision 2 keeps that grant and
DO-641 refuses `clauth start` but permits `clauth login`.

**Load-bearing coupling, to be documented and asserted.** `CLAUDE_PICK_CACHE_MAX_AGE` defaults to
600 s. A cache older than that yields `gate-unmeasured` → `credential:unmeasured` → `budget` refuses →
no dev lane starts. The laptop's clauth daemon polling quantivly-0 is therefore a hard dependency of
dispatching work to dev.

**Requirement:** `rabota doctor` asserts the age of each machine-owned seat's usage cache against
`CLAUDE_PICK_CACHE_MAX_AGE` and names this consequence when it fails.

Measured 2026-09-20 09:40Z, all caches fresh: quantivly-0 1 s, quantivly-1 52 s, quantivly-3 47 s,
personal-0 96 s, personal-1 35 s.

### 4.3 The machine dimension and remote census

**Sequencing constraint — these two land together or neither.** `census.json` holds one `machine{}`
and it is the laptop's. Implementing `_machine_reasons` against it while `--machine dev` is permitted
means a saturated laptop refuses dev lanes: load 13.4 on cilantro blocking a box at 0.2. That is worse
than today's stub, which fails open on this dimension.

**Reading dev, in one ssh call, with no interface change.** `sysinfo.py` already takes the proc root as
a parameter (placed there so the state table can hand it a fixture tree). Reuse that seam:

```
ssh -o BatchMode=yes dev 'cat /proc/loadavg; echo ---; cat /proc/meminfo; echo ---; nproc;
    echo ---; systemctl --user list-units --plain --no-legend "rabota-lane-*"'
```

Materialise the first two into a `/proc`-shaped temporary tree and pass that root to `SysInfo`. One
code path serves local, fixture and remote; existing rows keep working. Refactoring `sysinfo` to take a
reader callable is the nicer abstraction and is deliberately **not** done — it churns an interface the
state table depends on, for no behaviour.

**Shape.** Extend `census.json` with the already-designed
`machines[]{name, reachable, load1, ncpu, mem_available_gib, swap_used_pct, units[]}`
(consolidation-design §4.2). Remove `deferred:machines` from `DEFERRED` only when it is genuinely
measured. `_machine_reasons` reads `machines[]` for a remote target and `machine{}` for local,
comparing against the same `[budget]` keys either way.

**Unreachable refuses.** `reachable: false` → `machine:unmeasured` → exit 3. Never a silent fallback to
local: that sends a dev lane to the laptop, which is the saturation this work exists to remove.

**Remote counts** come from the `rabota-lane-*` units in the same call. `max_lanes_local` is
per-machine in meaning but not in name; renaming it to `[machines.<m>].max_lanes` is a config
migration and is **out of scope for S0** — recorded here so it is not rediscovered.

### 4.4 The dev form of `lane recipe`

**Dev needs no rabota.** Everything rabota does happens on the laptop: render the argv, create the
worktree, write the lane row, later observe. The unit runs `claude -p`, which invokes nothing of
rabota's. §4.1 of consolidation-design mentions "`python3.11` for rabota there" — a leftover from the
deleted `lane start` design, which had a rabota-side runtime.

Verified present on dev 2026-09-20: `/usr/bin/systemd-run`, `/usr/bin/git`, user manager `running`,
`Linger=yes`, claude at `/home/ubuntu/.local/share/claude/versions/2.1.272`.

**Brief transport is stdin, never argv.** The prompt is `Read <brief> and execute.`, so the brief must
exist as a file on dev. Write it with `ssh dev 'cat > <path>'` and the content on stdin. Nothing but
generated paths crosses a command line, which is what makes the bash-`%q`-into-zsh hazard (review F3;
dev's login shell is zsh 5.8.1) structurally absent rather than handled.

**Worktree.** `git worktree add` over ssh into `[machines.dev].state_dir/worktrees/<tenant>/<lane>/`,
deliberately a separate root from herdr's. DO-639 landed HTTPS-through-gh on dev; verified 2026-09-20
that `ls-remote` succeeds with `ForwardAgent=no ControlPath=none` on `.dotfiles`, `sre-sdk` and `hub`.
Push was not tested by this review.

**Two additions to the unit line of consolidation-design §4.1:**

1. **Resolve the claude binary at render time.** Dev's path is version-pinned
   (`…/versions/2.1.272`), and census already knows headless lanes exec the versioned binary directly.
   A hardcoded path breaks every stored recipe at the next claude upgrade.
2. **Pass `--slice=agents.slice`.** A lane started as a systemd unit inside that slice is inside
   DO-640's memory budget. This is how the review's F4 resolves.

### 4.5 Closing a remote lane

The census ssh call of §4.3 does triple duty: `/proc` for the machine dimension, `rabota-lane-*` for
counts, and a tail of each lane's `stream.jsonl` for its `result` line. Unit absent **and** result line
present → write `ended_at` and `cost_usd` (`result.total_cost_usd`) to the lane row.
`five_h_pct_at_end` is read from the laptop's clauth cache for that seat, since the window is
server-side — no extra remote work.

`reap` marks a `started` row whose unit has been absent for 6 hours `abandoned`, unchanged.

**Evaluate lanes run on the machine of the lane they evaluate.** `--kind evaluate --of <lane>` needs
that lane's `verdict.json`; this constraint keeps the file local to where it was written and builds no
transport for it. It preserves the mechanism consolidation-design §4.1 calls "the highest-value gate
the epic has run."

### 4.6 Permissions

**The classifier is non-deterministic, so no command shape is a design.** Blocker A refused
`ssh dev "systemd-run --user …"` twice. On 2026-09-20 the classifier refused a Linear `commentCreate`
as `[External System Writes]` and then allowed the identical payload on retry. The durable answer is an
explicit rule, not a safer-looking command.

**`Bash(rabota lane recipe:*)` is narrow in a way `Bash(dev-spawn:*)` is not.** Machines and seats
resolve only from `~/.dotfiles-local/rabota/tenants/*.toml`. Verified 2026-09-20: rabota's global flags
are `--tenant --state-dir --text --dry-run`, the config base defaults to `~/.dotfiles-local/rabota`, and
no environment variable redirects it. By contrast `dev-spawn` reads its target host from
`DEV_SPAWN_HOST`, which a command-string rule cannot see (review F6).

**Close the one seam:** `--state-dir` *is* overridable and `budget` reads `census.json` from it, so a
stale or hand-written census in a chosen state dir could manufacture room. Either refuse `--state-dir`
on `lane recipe --run`, or have `budget` refuse a census older than a configured max age. Pick one in
the plan; do not ship neither.

The rule goes in user-level `~/.claude/settings.json` (a gated write). Account dirs copy it on their
next build; `scripts/claude-account-dirs.sh --all` applies it immediately.

## 5. Sequencing

1. **§4.1 config.** Nothing else is testable until `seat_for()` stops refusing.
2. **§4.3 machine dimension + remote census, together.** Never `_machine_reasons` alone.
3. **§4.4 the dev form of `lane recipe`**, local form first.
4. **§4.5 closing**, which needs §4.3's ssh call to already exist.
5. **§4.6 the permission rule**, which gates the live smoke and nothing earlier.

## 6. What changes elsewhere

**DO-640 (Part B, in flight):**

- B4 `Description=` → herdr panes **and rabota lanes**; the recipe passes `--slice=agents.slice` (F4).
- B4 states the real ceiling: swap is uncapped so 10 GiB bounds resident pages only, and `MemoryHigh`
  throttles everything in the slice including the herdr server. Cite the unit's existing
  `OOMPolicy=continue`, so nobody "fixes" it (F7).
- B4 Step 1 names what the restart kills, including the `ssh-agent` in the server's cgroup (F9).
- B3 gains `timeout 120` and the laptop-side cost of a token refresh (F8).
- B2 gains `"timeout": 5` on the hook entry, matching the laptop's.
- B1 corrects "23 behind" to name the ref it was measured against (F10).
- B5's herdr-draft ref downgrades from blocking to optional: herdr-draft is attended-only, so it no
  longer gates the lane path (F5).
- B6 documents both doors — attended via herdr-draft in the dev machine view, headless via
  `rabota lane recipe --machine dev --run` — and explicitly not `dev-spawn`.

**DO-641 (Part C): ship as-is.** Record two things rather than build them: why `clauth login` must stay
permitted for a machine-owned profile (§4.2), and that `CLAUDE_TENANT_MACHINE_OWNED` becomes derivable
from `[machines.<m>].profile` once that key exists.

**DO-642: rescope in place, do not mark Duplicate.** Its goal — agents start sessions on dev through
one narrow door — is what this design delivers; only the mechanism changed, and there is no canonical
issue to consolidate into (`quantivly-conventions:linear`). A dated comment recording the decision was
posted 2026-09-20.

**Stale documents, in priority order:**

1. `consolidation-plan.md` §3.4 Task 6.3(d) prescribes
   `git config --global url."https://github.com/quantivly/".insteadOf …` **on dev**, and Step 4
   verifies it with `git config --global --get`. That writes through the `~/.gitconfig` symlink into
   the tracked, public `gitconfig`. DO-639 did it correctly in `~/.gitconfig.local`. **Highest
   priority — this one can corrupt a repo.**
2. `plans/WS6-remote-dev.md` — its Goal line and Task 6.4 still specify `rabota lane start`,
   `rabota/rabota/lanes/runtime.py` and `commands/lane.py`, all deleted by consolidation §4.1/§7, with
   live-smoke steps for them. Read top-down it builds a deleted command.
3. `docs/superpowers/plans/2026-09-19-do-635-dev-box-offload.md` on `main` (`886efa9`) — §4's "Move:
   headless `claude -p` lanes", the `agents.slice` `Description=`, and Part D.
4. WS6.3's own scope: §3.4 (b) and (c) provision rabota, a `python3.11` shim and tenant config on dev.
   Per §4.4 none of that is needed.
5. `consolidation-design.md` §4.2 specifies the gate as `--est-hours <h>`. The shipped code uses
   **`--est-minutes`** (default 30) in both `scripts/claude-pick` and `rabota budget`, and computes
   `rate × est_minutes / 60`. The code is correct; the design doc is stale. An implementer following
   §4.2 literally passes a flag that does not exist.

## 7. Verification

- **Config:** `rabota budget --machine dev --model sonnet --effort medium` returns a budget rather than
  `Refused("no seat configured…")`, with `seat_pick: "quantivly-0"`.
- **Gate:** with quantivly-0's usage cache aged past `CLAUDE_PICK_CACHE_MAX_AGE`, `budget` refuses with
  `credential:unmeasured` and `rabota doctor` names the coupling.
- **Machine dimension:** a hermetic row per `[budget]` threshold, against a fixture `machines[]`; and a
  row proving a *local* load figure cannot refuse a `--machine dev` lane.
- **Unreachable:** an ssh failure yields `machine:unmeasured` and exit 3, never a local fallback.
- **Recipe:** `lane recipe --machine dev` without `--run` prints argv containing an absolute,
  render-time-resolved claude path, `--slice=agents.slice`, `--setenv CLAUDE_CONFIG_DIR=…`,
  `StandardOutput=append:…/stream.jsonl`, and no brief content on any command line.
- **Closing:** a fixture `stream.jsonl` with a `result` line and an absent unit writes `ended_at` and
  `cost_usd` to the row.
- **Live smoke** (after §4.6): one real lane on dev, observed in `ssh dev 'systemctl --user list-units
  "rabota-lane-*"'`, landing in `agents.slice`, closing with a cost on the row.
- **Mutation sweep** per repo convention: each new guard gets a mutation that kills a named row, dry-run
  for applicability first.

## 8. Out of scope

nanoclaw as a lane target (decision 4) · `lane attach` (deferred on herdr-draft `--resume`) · window
warming · census `sol{}` · sharing one seat across machines (refresh-token rotation makes two holders
log each other out; this design makes placement *measured*, not shared) · renaming `max_lanes_local`
(§4.3) · herdr 0.9.1 and `herdr --machine` (DO-635 §9).

## 9. Open questions

1. **Push from dev is untested.** `ls-remote` was verified with no agent and no mux; the push path that
   a lane's PR depends on was not. DO-640 Step 4 covers it — confirm before the live smoke.
2. **quantivly-0 read `five_h 0.0 / seven_d 0.0` on 2026-09-20** while DO-635 measured 66% of its week
   on 2026-09-19. The 5 h reset is expected; the weekly drop is not obviously right. If that `0.0` is
   "unmeasured" rather than "empty", the gate reads it as room. DO-623 landed the weekly wall on
   2026-09-19; check this before the gate is trusted.
3. **Whether the classifier accepts `rabota lane recipe --run`** is unknown and deliberately untested —
   it is non-deterministic, so a pass would not be evidence. §4.6's rule is the answer either way.
