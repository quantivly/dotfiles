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
| `rabota/store.py` | SQLite schema v1 at `<state_dir>/rabota.db` |
| `rabota/context.py` | per-command `Context` (config, tenant, store, runner, scrubbed env) |
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

## Running tests

```bash
~/.dotfiles/scripts/test-rabota.sh          # python3 -m unittest discover, needs Python ≥ 3.11
~/.dotfiles/scripts/test-rabota.sh -k Store # one class
rabota doctor                               # install link, config, schema, timer
```
