---
name: rabota
description: >
  Orchestrate @zvi's work day over the `rabota` CLI: run preflight, hand connector
  results to the CLI, reconcile spoken/chat commitments against what is tracked,
  print the ≤12-line brief, dispatch and evaluate headless lanes, gate outward
  actions, close to disk. Use for `/rabota`, `/rabota brief`, `/rabota status`,
  `/rabota inbox`, `/rabota close`, or when asked what to work on next, who is
  waiting, or to sequence a day. Do NOT use for a single known task, for PR/issue
  mechanics (`quantivly-conventions:prs` / `:linear`), or for wording a message
  (`zvi-voice`).
---

# rabota v2 — console over the `rabota` CLI

Every deterministic step is a `rabota` subcommand that prints JSON. You do three
things the CLI cannot: fetch connector sources in this session, **reconcile**
commitments, and answer gates with the user. You never implement, never read a
pane, never re-derive state the CLI already measured. Design and provenance:
`~/quantivly/handoffs/rabota-v2/2026-09-16-rabota-v2-design.md`.

## Modes

| Invocation | Steps |
|---|---|
| `/rabota brief` | 1–4 (read-only) |
| `/rabota status` | `rabota --text census`, `rabota lane list --status started`, open escalations (`rabota --text brief` shows the delta) |
| `/rabota` | 1–7 |
| `/rabota inbox` | 1, then §Inbox session |
| `/rabota close` | 7 |

## The cycle

1. **Preflight.** `rabota preflight`. Exit 3 → print the one failure line and stop.
   Never work around a failed identity pin.
2. **Connector delta.** Read `rabota --tenant <t> inbox summary` and the newest
   `sources/*.json` `fetched_at`. Fetch only what the CLI cannot: Slack
   `to:me after:<last fetched_at date>`, Calendar free blocks for today, Fireflies
   action items since then. Write each as
   `{"fetched_at": "<UTC Z>", "ok": true, "error": null, "items": [...]}` to
   `<state_dir>/ingest-<source>.json` and run `rabota ingest <source> --file …`.
   **`ok` must be a JSON boolean and is required** — omit it and `ingest` exits 2.
   A connector that FAILED is still ingested, as `"ok": false` with `"error": "<why>"`
   and `"items": []`; that is what puts its one `!` line in the brief. Do not retry
   more than once, and never drop a failed source silently.
3. **Reconcile** (`references/reconcile.md`). Classify every commitment in the
   connector items against `sources/linear.json` and `sources/github.json`.
   Record: `rabota escalate --question … --evidence … --option …` for questions;
   dated promises become pins: `rabota pin <key> --bucket 2 --rationale …`.
   Say "already done" as confidently as "overdue"; cite the artifact.
4. **Brief.** `rabota rank && rabota --text brief`. Print its output verbatim. You
   may append ≤2 lines of reconcile deltas. Nothing else goes to the terminal.
5. **Dispatch.** `rabota lane recipe --brief <path> --repo <path> --machine dev --run` — one call, one unit,
   seat-gated; the CLI refuses with the seat's `resets_at` when the window is spent. `--machine dev`
   is **required** with `--run`: the local form is not implemented and refuses. Watch with
   `rabota --text census`; read only the lane's `verdict.json` (≤4 KB), which lives at
   `<machine state_dir>/out/<tenant>/<lane_id>/verdict.json` **on the lane's machine** — no command
   prints it, so fetch that one file. Evaluate with
   `rabota lane recipe --kind evaluate --of <lane> --run` (DO-670) and read `evaluation.json` only.
   Never read a pane, never send a keystroke, never `journalctl` a lane into this context.
6. **Monitor and evaluate.** `rabota --text census` settles a finished lane's row — never
   poll on a clock, never read a pane. Read only `verdict.json`, fetched from the path in step 5.
   For anything going to a critical reader, evaluate as in step 5 and read only
   `evaluation.json`. `rabota lane retire <id>` as soon as evaluated.
7. **Close.** `rabota close [--note …]`. Then `rabota --text reap`; apply only
   `--lanes` and `--spaces`; print the session close hints for the user.

## Inbox session (`/rabota inbox`, and offered on the first run of a Monday)

`rabota inbox plan` prints `{path, totals, batches}`; `buckets.confirm_required` is **not** in
that output — read it from the file at `path`. Then print ≤12 decision lines: one line per batch (`due_policy: clear N dates — ok?`,
`stale_backlog: N candidates — list?`), one per `confirm_required` item naming who
to confirm with (SEC → @benoit), one per `project_prompt`. On a typed OK:
`rabota inbox apply --tier propose --batch due_policy --confirmed`. Never apply
`confirm_required`. On Friday `close`, offer `stale_backlog` once.

## Gates

Show the exact text or command, wait for a typed OK, then act and record
`rabota gate --subject "<what>" --label "<the OK's label>"`. Durable records say
"the gate was answered: <label>", never who answered. A real problem gets its
Linear issue filed before the message that mentions it (`quantivly-conventions:linear`).

## Output contract

The screen is ≤12 lines: `rabota --text brief --max-lines 12`; when you append a
reconcile delta, call `--max-lines 11` instead. `--text` is a GLOBAL flag and must
precede the subcommand — `rabota brief --text` exits `unrecognized arguments`. `sol brief` handles its own line.
Narrative lives in `brief.md`; print its path once. On a rerun the same day the
CLI prints the delta. A source that failed gets its one `!` line from the CLI.

## Before reporting

1. Did `preflight` return `ok: true`, or am I trusting an absence?
2. Is every number from a CLI result or an artifact, not from a lane's prose?
3. Is the terminal output ≤12 lines?
4. Did every outward action have a typed OK and a `rabota gate` record?
5. Is anything load-bearing only in my context? If so, write it down now.

## See also

`references/rules.md` (standing invariants) · `references/reconcile.md` ·
`references/lanes.md` · `quantivly-conventions:prs` / `:linear` · `zvi-voice`.
