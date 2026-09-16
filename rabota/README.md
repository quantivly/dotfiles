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

Entry point: `scripts/rabota` (linked to `~/.local/bin/rabota` by `install.conf.yaml`).

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
