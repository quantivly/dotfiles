# rabota — work-day orchestrator substrate (v2)

`rabota` is a stdlib-only Python CLI: every deterministic step the `/rabota` skill used
to compose by hand is a subcommand that prints JSON on stdout (`--text` for human lines)
and JSON errors on stderr. Exit codes: `0` ok · `2` usage · `3` refused · `4` partial ·
`5` error. Spec: `~/quantivly/handoffs/rabota-v2/2026-09-16-rabota-v2-design.md` (§C1–C3).

## Layout

| Path | Role |
|---|---|
| `rabota/cli.py` | argparse dispatch, command registry, exception → exit-code mapping |
| `rabota/errors.py`, `rabota/emit.py` | error hierarchy; JSON/text output helpers |
| `rabota/secrets.py` | env scrubbing (`gh` runs without its token vars) and leak assertion |
| `rabota/runner.py` | the only place subprocesses run; `FakeRunner` for tests |
| `rabota/config.py` | tenant TOML loading and cwd/env → tenant resolution |
| `rabota/store.py` | SQLite store at `<state_dir>/rabota.db`; `SCHEMA_VERSION` and its `MIGRATIONS` |
| `rabota/context.py` | per-command `Context` (config, tenant, store, runner, scrubbed env) |
| `rabota/scheduler.py` | the schedule tick: settle, expire, dispatch; the record, escalations, answer actions, export |
| `rabota/commands/*.py` | one module per subcommand; each calls `cli.register` on import |
| `tests/` | `unittest` suite with synthetic fixtures under `tests/fixtures/` |

Entry point: `scripts/rabota` (linked to `~/.local/bin/rabota` by `install.conf.yaml`). It
**picks an interpreter rather than exec'ing a bare `python3`** (DO-712): `config.py` imports
`tomllib`, which is 3.11+, and a box whose `python3` is older but which has a `python3.11` beside
it — dev, measured 2026-09-24 — otherwise got `ModuleNotFoundError` with nothing to act on.
`python3` is tried first, so a current box pays one probe and nothing else.

| Path | Role |
|---|---|
| `briefs/_common-rules.md` | the lane rules, **shipped into every lane's `out_dir` beside `brief.md`** |
| `briefs/smoke.md`, `briefs/evaluate.md.tmpl` | the shipped work brief and the evaluate template |

A brief names the rules **relatively**, never by absolute path: `lane recipe` copies them next to
the brief it sends, which is the one directory `--add-dir` grants the lane and the one a
verbatim-shipped work brief can name without substitution. `lanes/brief.py:validate` refuses any
absolute path under `## Common rules`, and `run_recipe` runs it before the budget gate — until
DO-711 it ran nowhere, and both shipped briefs pointed every dev lane at `/home/zvi/...`.

## Where data lives

- **Mechanism** is here, in `~/.dotfiles`. **Data** is in the private overlay
  `~/.dotfiles-local/rabota/`: `config.toml` (cwd → tenant routes, default) and
  `tenants/<name>.toml` (identity pins, thresholds, lane defaults).
- **State** is per tenant at `<tenant state_dir>/rabota.db` plus day directories of prose.

## Scheduled runs

`rabota schedule add|list|show|cancel` (DO-816) declares work that runs later as a row in the
tenant's `schedules` table — design: `docs/superpowers/specs/2026-10-11-scheduled-agent-runs-design.md`
§3 and §8. `rabota schedule tick` (DO-817, `rabota/scheduler.py`) fires and follows it up, from
`rabota-schedule@<tenant>.timer` every ten minutes; agent-run execution is phase 2 (DO-820).

- `add` freezes the prompt (`--prompt-file`, an agent run) or the script (`--command <script>
  [-- args]`) into `<state_dir>/schedules/<id>/` with a `SHA256SUMS`, stores the row, and prints
  the whole declaration, including an agent run's effective permissions. `show` re-hashes the
  frozen payload as `payload_intact`.
- Its refusals (exit 3) each name what failed: a past `--at`, an `--expires` not after it or
  more than 30 days after it, an `--at` over 30 days ahead, a `--timeout` over 6 h, a `--cwd`
  containing the run's out_dir, a script or argument that invokes `claude` or a launcher of it, a
  `--record` git tracks or the secret guard protects, and a tenant whose
  `rabota-schedule@<tenant>.timer` is not enabled. That last one is checked last, and **the
  global `--dry-run` refuses on it too**: a dry run validates what the real `add` would do, and
  one that exited 0 for a run nothing would ever fire would be a green answer to the wrong question.
- The defaults and bounds (expiry, horizon, timeouts and their 6 h cap, attempts, the retry delay, memory, budget) are named constants at the
  top of `rabota/commands/schedule.py`, one line each.
- **The tick** takes an `flock`, then settles finished command runs, expires overdue ones and
  dispatches due ones, in that order. A command runs as a transient
  `rabota-sched-<tenant>-<id>-a<n>.service` under `MemoryMax`, `RuntimeMaxSec`, `Nice=10` and
  `KillMode=control-group`, with `~/.local/bin` on its `PATH`, and no seat or budget gate. Its exit
  code is its outcome: 0 `pass`, 1 `fail`, anything else (or none) `could-not-run`, retried once
  30 minutes later. A frozen payload that no longer hashes to its declaration is never run. An
  agent run is deferred until phase 2, so it expires and escalates. The claim is written before
  `systemd-run`, so a crash is adopted on the next tick, never re-run blind.
- **What the tick leaves.** One keyed section per attempt in the `--record` file (before a
  `<!-- rabota-schedule-results -->` marker if it has one), an escalation of kind `scheduled-run` for
  every outcome but a clean pass, and `~/.local/state/rabota/schedule-export.json`, which covers
  every tenant and never carries a result body. `rabota answer` executes only an option's declared
  `rerun[:+<n>]` or `cancel-followups`; any other option executes nothing.
- **Arming** a tenant is @zvi's step: `systemctl --user enable --now rabota-schedule@<tenant>.timer`.
  `install.conf.yaml` only links the units.

## Reconcile classification notes

Evidence behind two rules in `claude/skills/rabota/references/reconcile.md`, trimmed there for the
skill's byte budget (`scripts/test-rabota.sh`):

- **Folding state into the class name.** A blind-evaluate run once wrote
  `Class: question owed → already answered`, scoring it as a new, seventh class. It is a
  `question-owed` item whose `outcome` happens to be "already answered" — the class names the KIND
  of commitment, never whether it is currently outstanding.
- **DO-751: `rabota brief`'s turn-1 reply dropped its tracked-side index.** It grew linearly with
  the tenant's open-issue count, measured ~303 KB on a synthetic tenant scaled to @zvi's real one.
  `rabota tracked <key> [<key>…]` replaced it: one call, no network, answered from
  `sources/linear.json`/`sources/github.json` on disk.

## Running tests

```bash
~/.dotfiles/scripts/test-rabota.sh          # python3 -m unittest discover, needs Python ≥ 3.11
~/.dotfiles/scripts/test-rabota.sh -k Store # one class
rabota doctor                               # install link, config, schema, timer, tenant root
```
