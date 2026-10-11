# Scheduled agent runs — design

**Status:** @zvi approved the plan for this design on 2026-10-11. The decisions in §11 are still
open: approving the plan did not answer them. There is no implementation plan yet.
**Next step:** `superpowers:writing-plans`, starting from phase 1 (§9).
**Builds on:** [remote lanes](2026-09-20-remote-lanes-design.md), which made the lane the one door
for a headless agent.

**Goal:** an agent schedules work that runs later on this laptop, with no human present. The work
survives a poweroff or a suspend, is monitored while it runs, and its result reaches @zvi and the
next agent. Concretely, `rabota schedule add` replaces "paste this prompt on Tuesday".

---

## 1. Problem

When a check comes due days later, it is handed to a human today. The agent writes a prompt file
and a date, and @zvi pastes the prompt into a fresh session on that date. A calendar reminder
works too. Either way, a person spends a round trip on work that needs no judgement until there
is a result. The need recurs in dotfiles, in nanoclaw, and in Quantivly work.

The latest instance had three read-only checks on the account-manager plan, all of them stat,
`jq`, `journalctl` and `systemctl show` reads with a mechanical bar. Their record lives in
`~/Projects/handoffs/` (private; cited by path only). They are now covered by a **stopgap**: a
read-only script, and two one-shot `OnCalendar=` user timers with `Persistent=true` that append
to a results file and call `notify-send`. The stopgap works, and it shows what a framework has to
replace:

- hand-written units outside the checkout, invisible to `check-timer-health.sh`;
- cleanup by hand afterwards;
- no listing;
- no expiry;
- no retry;
- nothing that reads the result except @zvi.

There is also a second gap, separate from firing. **Nothing reads a result and follows it up.**
`rabota escalate` stores a question with answer options and sends a herdr notification. The only
code that reads open escalations is `rabota close` (`commands/close.py`). Neither `brief` nor
`rank` shows them, and no command lists them.

## 2. What exists, and what each piece decides

| Fact (verified 2026-10-11) | Consequence |
|---|---|
| `run_recipe` refuses the local `--run` form: "the local --run form is not implemented; use --machine dev" (`commands/lane.py`). | The laptop-local lane door has to be built. It also always creates a worktree, which a read-only check does not want. |
| The door is `seat_for` → `credential_gate` (`claude-pick --gate`) → census freshness, load, memory, swap → `counts:cap` (`budget.py`). Then `systemd-run --user` with `MemoryMax`, `CLAUDE_CONFIG_DIR=<seat account dir>`, and `stream.jsonl`. | Reuse it unchanged. A scheduler that called `claude -p` itself would be the second spawner the remote-lanes design rules out (§3 there). |
| The stream-json `result` line carries `permission_denials`, which the docs call "the authoritative record". | "Refused → escalate" can be mechanical rather than left to the agent's honesty. |
| `census._settle_row` settles a lane from its `result` line, and settles it `failed` when `out_dir` holds no `*.json`. | Scheduled agent runs keep the `verdict.json` contract. |
| A calendar timer that elapses during suspend fires on resume, **with or without** `Persistent=`. `Persistent=` is what covers poweroff. Monotonic timers pause during suspend. (`man systemd.timer`; the journal shows two calendar units starting in the same second as a 2026-10-10 resume.) | One `OnCalendar=` tick with `Persistent=true` covers both cases. `WakeSystem=` needs privileges and is not used. |
| A transient `systemd-run --on-calendar` timer lives under `$XDG_RUNTIME_DIR` and is released at reboot (`man org.freedesktop.systemd1`). cron skips runs while the machine is off. anacron catches up only to day granularity, and only as root. | Neither fits. |
| User lingering is on. | User timers fire after boot, before anyone logs in. |
| `check-timer-health.sh` covers every unit symlinked from the checkout, automatically, and so does the first-prompt warning. | A repo-owned, linked timer gets health checking for free. The stopgap's units get none. |
| Claude Code's built-in schedulers: `/loop` and CronCreate are session-scoped, with no catch-up for missed fires. Cloud routines run on a fresh clone in Anthropic's cloud. Desktop local tasks "only fire while the app is open and your computer is awake". | None of them can run on this laptop's files, credentials and tools after a suspend. |
| Headless `-p` loads no plugin MCP server that duplicates a connector, so a run has no Slack, Linear or Notion. | That is acceptable. Anything outward becomes an escalation anyway (§5). |

**A correction made on the way.** `docs/TIMER_HEALTH.md` credited `Persistent=true` with the
2026-09-23 catch-up. A single boot covers 09-22 through 09-29, so the laptop was suspended, not
off, and what fired was the ordinary calendar catch-up on resume. This PR fixes that line.

## 3. Declaration

A scheduled run is a row in a new `schedules` table. It lives in the **tenant's** `rabota.db`
(store `SCHEMA_VERSION` 4→5, through the existing `MIGRATIONS` mechanism). The tenant comes from
the run's directory through `tenant-route`, as every other rabota command's does.

| field | meaning / default |
|---|---|
| `id` | `s-<8hex>` |
| `kind` | `agent` or `command` (§7) |
| `title` | one line, shown on every surface |
| `cwd` | absolute directory the run starts in; refused if it contains the run's `out_dir` |
| payload | agent: the prompt, **frozen** at add time to `<state_dir>/schedules/<id>/prompt.md` with its sha256. command: the script, frozen the same way, plus its args |
| `not_before`, `expires_at` | entered in local time, stored in UTC. Default expiry is due + 48 h; the maximum horizon is 30 days |
| `seat`, `model`, `effort`, `est_minutes` | agent only. Defaults come from `seat_for(tenant, "local")` and the tenant's `[lanes]` |
| `allow[]`, `read[]` | agent only: the declared permission rules (§5) |
| `record` | optional: an existing regular file the result is appended to (§6). **Refused** if git tracks it, because the live dotfiles checkout *is* the deployment, or if it is a path the secret guard protects |
| `ask`, `options[]` | optional: the question @zvi will be asked, written now, while the context exists (§6) |
| `then_prompt`, `then_on` | optional: a follow-up agent run that interprets the result (§6) |
| `timeout`, `memory_max`, `max_budget_usd` | agent: 20 min, the tenant's `memory_max`, $3. command: 15 min, 1G |
| `max_attempts` | 2 |
| state | `status` (pending, running, done, failed, expired, cancelled); `attempt`; `last_reason`; `unit`; `lane_id`; `out_dir`; `outcome` (§6); `cost_usd`; `escalation_id`; timestamps; `created_from` (the scheduling session's cwd and its `CLAUDE_CODE_SESSION_ID`) |

The prompt is frozen at add time, so editing or deleting the source cannot change what runs.
`add` prints the whole declaration, including the effective permissions, so the scheduling
session's own transcript shows exactly what will run unattended.

## 4. Firing

**One ticking timer per tenant. The store is the queue.**

- `systemd/rabota-schedule@.timer`:
  - `OnCalendar=*:0/10`
  - `Persistent=true`
  - `RandomizedDelaySec=30`
- `systemd/rabota-schedule@.service`:
  - oneshot
  - `ExecStart=%h/.local/bin/rabota --tenant %i schedule tick`
  - `TimeoutStartSec=5min`, `Nice=10`

  `install.conf.yaml` links both, and @zvi arms them (the precedent is `rabota-precompute@`).
  Because the link points into the checkout, the timer is under timer-health with no extra work.
- **Why not one unit per job.** Transient timers die at reboot. Per-job unit files are the
  stopgap: they accumulate, need cleanup by hand, are invisible to timer-health, and cannot be
  listed. And none of them can *defer* when the budget refuses.
- **A tick** takes an `flock`, then works through four steps in order:
  1. Settle finished runs: `census.settle_finished` for agent lanes, unit state for commands.
  2. Process their outcomes (§6).
  3. Expire pending runs past `expires_at`, escalating each one.
  4. Dispatch due runs. Before the first agent dispatch, the tick refreshes the local census
     itself, skipping the worktree scan. `budget` refuses a census older than 900 s, and only
     one tenant has a precompute timer to keep its census fresh.
- **When the laptop was off or asleep at the due time.** After a poweroff, `Persistent=` fires
  the missed tick at boot. After a suspend, the calendar tick fires on resume. Either way, a
  due time is met within about ten minutes of the laptop being awake.
- **A deferral is not an attempt.** A gate refusal is recorded in `last_reason`, and the run
  stays pending for the next tick. That covers four situations: a spent window; a stale usage
  cache straight after a resume (`credential:unmeasured`); credentials broken after a long
  suspend; a busy laptop. If the run is still pending at expiry, its escalation names the last
  reason.
- **"Could not run" is an attempt.** These all count as one:
  - an `is_error` result;
  - no verdict;
  - a `RuntimeMaxSec` kill;
  - an abandoned unit;
  - a command that exits 2.

  The run goes back to pending with `not_before = now + 30 min` until `max_attempts`, and then
  escalates. **A run that finished and found its bar unmet is a `fail` outcome.** That is a
  result, not a fault, and it is never re-run automatically.
- **Idempotence:**
  - The claim and the record write share one `BEGIN IMMEDIATE` transaction.
  - The unit name and lane id are generated and stored on the row *before* `systemd-run`, and
    systemd refuses a duplicate unit name.
  - A row left `running` with no live unit is adopted from its `out_dir` on the next tick:
    settled if it finished, abandoned if not. It is never re-dispatched blind.
  - Record appends carry a key, and are skipped when the key is already present.
  - The run's brief requires its work to be safe to repeat.

## 5. Execution and monitoring

**Agent runs go through the one door.** The tick calls `run_recipe` in-process, so the seat,
the gate, the lane row and census are exactly what a lane dispatched by hand gets. That needs a
new **local, in-place, read-only** form of `lane recipe --run`:

- **No worktree.** The unit gets `--working-directory=<cwd>` and `--add-dir <out_dir>`, and
  `out_dir` is the usual `<state_dir>/out/<tenant>/<lane_id>`.
- **Unit properties.** `systemd-run --user` gains `-p RuntimeMaxSec=<timeout>` (documented to
  apply to the default `Type=simple`) and `-p Nice=10`, next to the existing `MemoryMax` and
  `CLAUDE_CONFIG_DIR=<seat account dir>`. `PATH` is set explicitly and includes `~/.local/bin`,
  which is the DO-712 lesson. `KillMode=control-group` stops claude and its children together.
- **The claude invocation:**
  ```
  claude -p "Read <out_dir>/brief.md and execute." --output-format stream-json --verbose \
      --session-id … --model … --effort … --max-budget-usd … --strict-mcp-config \
      --permission-mode dontAsk --permission-prompts none --settings <out_dir>/settings.json
  ```

**Confinement is declared, not classified.** The auto-mode classifier refuses some actions and
not others, unpredictably, and the remote-lanes design (§4.6) settled that "no command shape is a
design". So scheduled runs do not use `auto`. `dontAsk` denies anything not pre-approved,
without prompting, and each denial lands in `permission_denials`. The run's `settings.json` is
built from the declaration, following code.claude.com/docs/en/permissions:

- **allow**
  - `Edit(//<out_dir>/**)`. Path rules on `Write` are never consulted, and an `Edit` rule
    covers Write and `>` redirects.
  - the declared `allow[]` Bash rules. A prefix rule never matches a compound command: every
    `&&`, `|` or `;` part has to match on its own.
  - the declared `read[]` paths, as `Read(...)` rules.
- **`blockReadsOutsideWorkingDirectories: true`.** Without it, built-in read-only Bash
  commands (`cat`, `grep`) read anywhere, even under `dontAsk`.
- **deny** (deny always wins over allow)
  - credential paths: `~/.clauth/profiles/**`, `**/.credentials.json`, `~/.zshrc.local`, and
    the other files the secret guard protects;
  - a fixed list of verbs no run may use, even when the user's own allow rules permit them:
    `clauth`, `claude`, `rabota lane`, `rabota schedule add`, `rabota answer`,
    `systemctl --user start|stop|restart|enable|disable`, `git push`, `gh`. **A run cannot
    schedule a run.**

`--settings` merges with the user's settings. The user's hooks, including the secret-emission
guard, therefore still run, and so do the user's allow rules. The deny list above is what
neutralises those allow rules. The alternative is `--restricted`, which loads only `--settings`
and would need the guard hook declared again.

**Measured in the agent smoke, because the docs do not answer them:**

- whether `--restricted` or a merge is used;
- whether `--strict-mcp-config` also drops plugin MCP servers (connectors are documented as
  dropped);
- whether `--max-budget-usd` binds on a subscription seat. It is a client-side estimate either
  way, so the real bounds are `RuntimeMaxSec` and the seat gate;
- how `RuntimeMaxSec` counts time across a suspend.

**The brief** is a rabota template, `rabota/briefs/scheduled.md.tmpl`, wrapped around the
frozen prompt. It names `_common-rules.md` the way every lane brief does, and adds these rules:

- the run is read-only;
- it writes `verdict.json` (the existing contract) and `result.md` into `out_dir`;
- anything @zvi must act on goes in `followups`, prefixed `zvi:`. That includes a rollback
  command, a refused action, and an unmet bar;
- the work must be safe to repeat;
- a denial is reported, never routed around.

**"Monitored", concretely.**

- **While it runs:**
  - the unit appears in `systemctl --user list-units 'rabota-*'`, which `rabota census`
    already reads;
  - `rabota schedule list` shows it as running, with elapsed time and seat;
  - its journal (`journalctl --user -u <unit>`);
  - its `stream.jsonl`.
- **It is bounded by** `MemoryMax`, `RuntimeMaxSec`, `--max-budget-usd`, the seat window gate,
  and `max_lanes_local`.
- **The scheduler itself is watched three ways:**
  - **Timer-health** covers the linked timer: armed, last tick succeeded, still firing. The
    first-prompt warning shows a failure.
  - **`rabota doctor`** gains three checks:
    1. every tenant with pending runs has its `rabota-schedule@` timer enabled;
    2. no run is overdue, meaning due more than 30 minutes ago and still pending (its
       `last_reason` is printed);
    3. no run has been `running` longer than its timeout plus a grace period.
  - **`schedule add` refuses** when the tenant's timer is not enabled, so a run can never sit
    in a queue that nothing reads.

## 6. The consumer: who reads a result and follows it up

Today the only consumer is @zvi, reached through a notification and a results file. The design
closes the loop in five steps, and only the last one needs him.

1. **Pick up.** The tick settles the run deterministically. It reads the exit status or the
   `result` line, `verdict.json`, `permission_denials`, and the cost, and assigns exactly one
   **outcome**: `pass`, `fail`, `inconclusive`, `could-not-run`, `denied` or `expired`.
2. **Interpret.** This happens in one of three places:
   - **Mechanically.** A command is judged by its exit code (§7). An agent is judged by its own
     `verdict.json`: its prompt carries the bar, so the run that gathered the evidence judges
     it.
   - **By a declared follow-up agent.** `--then-prompt <file> --then-on fail|inconclusive|always`
     makes the tick enqueue a read-only agent run, due at once. It is given the parent's
     `result.md` and the record, and holds the parent's permissions or narrower ones, never
     wider. Its job is to read the result in context and write the decision for @zvi. A cheap
     command check therefore spends a seat only when something needs judgement.
   - **When the run is scheduled, for the decision itself.** `--ask '<question>' --option
     '<label>' …` is written while the scheduling session still holds the context. The run
     supplies the evidence, and a follow-up agent may sharpen the question. Nobody has to
     reconstruct the intent afterwards.
3. **Record.** The tick does this without judgement. It appends to the declared record a dated
   section, `## <local time> scheduled run <id>: <outcome>`, followed by `result.md`. The section
   goes at a `<!-- rabota-schedule-results -->` marker if the file has one, and at the end
   otherwise. It is keyed by `<!-- rabota-schedule:<id>:<attempt> -->`, so a repeat appends
   nothing, and it is written through `emit.append_file`, which asserts that no secret leaks.
   The tick also updates the row and rewrites the export (below). **The run never holds write
   access to the record**, so "read-only plus one record file" holds by construction, not by
   instruction.
4. **Bring the decision to @zvi, on the surfaces he reads.**
   - **What raises an escalation.** An outcome of `fail`, `inconclusive`, `denied` or
     `expired` raises one, and so does any `zvi:` follow-up. A clean `pass` raises nothing: it
     is recorded, and the export shows it.
   - **Its shape.** The escalation goes in the existing table. Its `subject` is the schedule
     id, its `evidence` the result path, and its options the declared ones. Without declared
     options the defaults are *acknowledge*, *re-run now* and *cancel follow-ups*.
   - **Immediately:** a desktop notification (`notify-send`, critical urgency for `fail`,
     `denied` and `expired`), sent once per escalation, next to the existing herdr
     notification.
   - **Daily:** a **"Needs you" section at the top of `rabota brief`**, listing every open
     escalation of every kind. A new `rabota escalations` command lists them too; the rabota
     skill already promises one. This fixes the close-only gap for all of rabota, not just for
     scheduled runs.
   - **Eventually:** Solomon's PWA (below).
5. **Act on the answer.** `rabota answer <id> <label>` records the choice and appends "decided:
   <label>, @zvi, <time>" to the record. An option can carry only one of three declared,
   scheduling-level actions: `none`, `rerun[:+<duration>]` or `cancel-followups`. **Every other
   option is text for @zvi to carry out himself.** A rollback command shown as an option is
   never executed by rabota.

**What may happen to a result without @zvi:**

| allowed unattended: local, idempotent, reversible bookkeeping | never without him |
|---|---|
| settle a run and assign its outcome | any rollback |
| append the result to the declared record; update the schedule row, the export, the lane row | any credential or auth change, including relinking an account dir |
| defer on a gate refusal; retry `could-not-run` within `max_attempts`; expire | restarting or re-arming a daemon, unit or timer |
| run a **declared** read-only follow-up agent, inside the gate and budget | anything outward: a PR, push, merge, issue, comment or message |
| raise an escalation and send its notifications | editing code or configuration in any repository or live checkout |
| record an answer and perform its declared `rerun` / `cancel-followups` | a run scheduling another run, or widening its own permissions |
| | answering an escalation on his behalf; deleting anything |

**Solomon's PWA, the surface @zvi wants in the long run.**

- **The export.** Every tick, and every `add` or `cancel`, rewrites one file:
  `~/.local/state/rabota/schedule-export.json`. It covers all tenants, is versioned, and is
  redacted on the laptop. It carries titles, statuses, reasons, and open questions with their
  options. It never carries result bodies.
- **nanoclaw has no extension point for it today.** Its fleet push reads named keys under a
  fixed agent version, and its inbox sources are a closed list. So the PWA half is nanoclaw
  work, tracked in nanoclaw's own tracker and not edited from here.
- **How that work goes.** It mirrors a loop nanoclaw already runs for another source:
  1. The fleet agent pushes a section read from the export.
  2. The server adds a `scheduled-run` inbox source. An open escalation becomes a decision
     item whose verbs are its options.
  3. The answer travels back down the existing server-to-laptop path.
  4. The fleet agent runs `rabota answer <id> <label>`.
- **Rejected as an interim:** posting each outcome into Solomon's chat. It costs a model turn
  per message, gives no verbs or badge, and would couple rabota to a nanoclaw secret.

**The next agent** finds results through `rabota schedule list --status done|failed` (or
`schedule show <id>`) and the record file. It never needs a transcript.

## 7. Agentless checks belong in the same framework

The stopgap case has fixed commands, a mechanical verdict and a durable results file. For that
case, `kind=command` keeps everything above:

- declaration;
- the queue;
- catch-up;
- expiry and retry;
- monitoring;
- the record append;
- escalation and the answer path;
- listing;
- the export.

Only the executor changes. A transient unit, `rabota-sched-<tenant>-<id>-a<n>.service`, runs
the frozen script under `MemoryMax` and `RuntimeMaxSec`. It gets no seat and no budget gate,
because it spends no window.

- **Exit codes.** 0 is `pass`. 1 is `fail`. 2 is `could-not-run`, which is the repo's
  convention and is retried. Anything else is `could-not-run` as well.
- **The skill steers agents here.** When the verdict is mechanical, an agent should schedule a
  command: it is cheaper, deterministic, and bills nothing. `--then-prompt` adds judgement only
  when the command fails.
- **A command must not become a back door around the gate.** `add` refuses a script that
  invokes `claude` and points the caller at `kind=agent`.

## 8. The agent-facing surface

```
rabota schedule add --at '<local time>' [--expires …] --title '…' \
    --prompt-file <f> [--cwd <dir>] [--record <file>] \
    [--allow 'Bash(journalctl:*)' …] [--read <path> …] \
    [--ask '<question>' --option '<label>[=rerun:+24h|cancel-followups]' …] \
    [--then-prompt <f> --then-on fail|inconclusive|always] \
    [--model --effort --seat --timeout --max-budget-usd]
rabota schedule add --at … --title … --command <script> [-- args]
rabota schedule list [--status …] [--all-tenants]
rabota schedule show <id>
rabota schedule cancel <id>
rabota schedule tick                # the timer's entry point
rabota escalations [--open]         # the missing reader
```

Output is JSON, with `--text` for lines, and uses rabota's exit codes. The global `--dry-run`
validates a declaration and prints it without storing it.

**How agents learn that it exists:**

- **A user-level skill**, `claude/skills/run-later/`, linked into `~/.claude/skills/`. Every
  account dir's `skills/` resolves there, so the skill reaches every repository and every seat.
  Its description has to win against Claude Code's built-in cloud `schedule` skill for local
  work ("needs this laptop's files, credentials or tools"). It is a separate skill because the
  rabota skill's references budget is nearly spent.
- **One line in the user-level `~/.claude/CLAUDE.md`**, which loads in every project: work due
  later on this laptop goes to `rabota schedule add`, never to a prompt to paste on a date, a
  calendar reminder, or the cloud `schedule` skill. That file is not in this repo; @zvi makes
  the edit.
- **One Common Tasks line in this repo's `CLAUDE.md`**, net zero bytes.
- **Not `quantivly-conventions`.** Teammates have no rabota, so the plugin would tell their
  agents to call a command that does not exist.

**From another repository.** For example, `cd ~/Projects/nanoclaw && rabota schedule add …`.
The tenant comes from `tenant-route`, and so does the seat that run bills. `schedule list` in
that directory shows the tenant's runs, and `--all-tenants` shows every tenant's.

## 9. Phasing

1. **Phase 1: the queue, command runs, and the whole consumer loop.** This is the smallest
   useful slice, because a run whose result nobody reads is not useful. It retires the
   stopgap pattern. It includes:
   - the `schedules` table;
   - `schedule add|list|show|cancel|tick`;
   - the `rabota-schedule@` units;
   - the record append;
   - escalations with declared options, plus `notify-send`;
   - "Needs you" in `rabota brief`, and `rabota escalations`;
   - `answer`'s `rerun` and `cancel-followups` actions;
   - the export;
   - the doctor checks;
   - the `run-later` skill and the `CLAUDE.md` lines.
2. **Phase 2: agent runs.** It includes:
   - the local, in-place, read-only `lane recipe --run`, with `dontAsk`, the declared settings
     and the fixed deny list, `--strict-mcp-config`, `RuntimeMaxSec` and the budget cap;
   - the tick dispatching through `run_recipe`;
   - settle turning `permission_denials` and `zvi:` follow-ups into escalations;
   - `--then-prompt` follow-up runs;
   - one live smoke, with @zvi's go-ahead.
3. **Phase 3: the PWA.** This is nanoclaw work in nanoclaw's tracker, server side first.
4. **Later, only if asked:**
   - write-scope runs in a rabota worktree that stop at a local commit;
   - `--machine dev`;
   - Claude Code's Bash sandbox, as a real write boundary for Bash.

**First customers.** The checks that motivated this design are already covered by the stopgap,
and nothing here runs them. A one-line journal count, such as DO-813's, is the natural first
`kind=command` customer once phase 1 is armed. No date in this design depends on it.

## 10. Verification

**A hermetic state table**, using `FakeRunner`. `systemd-run` is never executed. It needs one row
per transition:

- **Timing:** due, not due, expired.
- **Deferral and retry:**
  - a deferral leaves `attempt` unchanged;
  - `could-not-run` goes to retry and then to escalate;
  - a `fail` outcome is never retried.
- **Concurrency and crashes:**
  - a duplicate tick claims nothing twice;
  - a crash between `systemd-run` and the row write is adopted, not re-run.
- **Outcomes and escalations:**
  - the record append is idempotent;
  - each outcome maps to exactly one escalation decision, and a clean `pass` raises none;
  - a notification is sent once per escalation, never once per tick.
- **Answers and follow-ups:**
  - `answer` with `rerun:+24h` enqueues exactly one run, and an undeclared option executes
    nothing;
  - a `--then-on fail` child is enqueued only on `fail`, and is refused if it declares wider
    permissions than its parent.
- **Run settings:** every run's `settings.json` carries the fixed deny list.
- **The brief:** "Needs you" lists open escalations of every kind.
- **`add` refusals:** `add` refuses each of these:
  - a disarmed timer;
  - a tracked record;
  - a past `--at`;
  - a horizon over 30 days;
  - a command that invokes `claude`.

**Repo checks.** Every new guard gets a mutation sweep, committed first and with every mutant
diffed. Run `scripts/test-rabota.sh`, `pre-commit run --all-files`, `scripts/check-claude-md.sh`
and `scripts/check-doc-tokens.sh`.

**Live**, each step only with @zvi's go-ahead:

1. Arm one tenant's timer.
2. Schedule a `kind=command` run due in ten minutes, and suspend across its due time. Confirm
   that it runs on resume and lands in `schedule list`, the record and the export, and that its
   escalation reaches the desktop notification and the brief, and closes with `rabota answer`.
3. Run one `kind=agent` smoke: a read-only check with a declared allow list, plus one
   deliberately undeclared command, which has to surface as a `denied` escalation. The same smoke
   answers the four questions §5 leaves open.

## 11. Decisions that are @zvi's

Approving the plan did not answer any of these.

1. **Which tenants' timers to arm**, with `systemctl --user enable --now
   rabota-schedule@<tenant>.timer`.
2. **The permission model for agent runs:** a declared allow list under `dontAsk`
   (recommended), or the tenant's `auto`.
3. **Allow rules** in `~/.claude/settings.json` for `rabota schedule add|list|show|cancel`, so
   agents can schedule without a prompt, or his OK for each schedule.
4. **The line in his private `~/.claude/CLAUDE.md`.**
5. **The defaults:**
   - a 10-minute tick;
   - expiry at due + 48 h;
   - a 30-day horizon;
   - 2 attempts;
   - $3 and 20 minutes per agent run.
6. **The autonomy table in §6.** Confirm it, or move a row. For example, should a `--then`
   follow-up agent need his OK before it spends a seat?
7. **The PWA half:** when it happens, in which tracker, and whether work-tenant titles and
   questions may go to the personal server. The proposed default is titles and questions only,
   never result bodies.
8. **A go-ahead for each live step.**

## 12. Proposed issues

These are for team DO in Linear, and are not filed until @zvi says so. The nanoclaw half goes
to nanoclaw's own tracker.

1. Show open escalations in `rabota brief` and add `rabota escalations`, with a desktop
   notification and declared answer actions. This also stands alone, because today only
   `rabota close` reads escalations.
2. Add a `schedules` table and `rabota schedule add|list|show|cancel` (declaration, freezing,
   refusals).
3. Fire scheduled runs from a `rabota-schedule@` timer. The tick covers the claim, the command
   executor, settle, retry, expiry, the record append, escalation and the export.
4. Assert scheduler health in `rabota doctor`.
5. Start a local, in-place, read-only lane with declared permissions: the local form of
   `lane recipe --run`.
6. Dispatch and settle agent runs from the tick, with denials as escalations and
   `--then-prompt` follow-ups.
7. Teach agents to schedule instead of handing over a prompt: the `run-later` skill, the
   `CLAUDE.md` lines, and the allow rules.

## 13. Out of scope

- Waking the laptop to run a job.
- Running on dev or on nanoclaw's server.
- Runs that write code.
- Recurring schedules: a run that should recur asks for `rerun` through its options.
- Migrating the stopgap, which expires on its own.
