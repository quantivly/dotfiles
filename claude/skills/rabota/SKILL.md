---
name: rabota
description: >
  Orchestrate @zvi's work day over the `rabota` CLI: call `rabota brief` (it runs
  preflight, rank and brief itself), hand connector results the CLI cannot fetch
  back to it, reconcile spoken/chat commitments against what is tracked, print
  the ≤12-line brief, dispatch and evaluate headless lanes, gate outward
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
pane, never re-derive state the CLI already measured. `/rabota brief` costs at
most 2 model round-trips — 1 when nothing is stale. Design and provenance:
`~/quantivly/handoffs/rabota-v2/2026-09-16-rabota-v2-design.md`.

## Modes

| Invocation | Steps |
|---|---|
| `/rabota brief` | 1; then 2 only if `needs` is non-empty — **2 writes** (ingest, escalate, pin) |
| `/rabota status` | `rabota --text census`, `rabota lane list --status started`, open escalations. **Not free:** `rabota --text brief` shows the delta but also identity-checks and rewrites today's `brief.md` (#237) — skip it unless the delta is what was asked for |
| `/rabota` | 1–2, then 3–5 |
| `/rabota inbox` | 1, then §Inbox session |
| `/rabota close` | 5 |

## The cycle

`rabota brief` runs preflight, rank and brief in one process (#237), so never call `rabota
preflight` or `rabota rank` *instead of* it — including in turn 2, after an ingest: `brief`
re-ranks on its own whenever anything `rank` reads has moved since the day's `sequence.json` was
written, so the fetch you just landed is never silently skipped (DO-738).

1. **Brief, turn 1.** One call: `rabota brief` (JSON, not `--text` — you need its `needs`
   field). Exit 3 → print the one failure line from the report and stop; a failed identity
   pin is not a `needs` and is never worked around.
   - **`needs` empty: print `lines` from the JSON reply, verbatim. That is the whole of
     `/rabota brief` — stop here.** Do not run `preflight`, `rank`, `inbox summary`, or anything
     else out of habit; there is nothing left to do.
   - **`needs` non-empty: print nothing yet.** Turn 2 ends with the brief that includes what you
     fetched, and that is the one screen the reader gets. Printing here too would show the
     pre-fetch brief and then a second, near-empty `no change` block after it.
2. **Fetch, ingest, reconcile — turn 2, only when `needs` is non-empty.** These are tool
   calls inside this one turn, not a turn each:
   - An entry with `fetched: true` (fireflies) already carries its `items` — classify them,
     no fetch and no ingest. Every other entry: fetch exactly its `query` (e.g. Slack
     `to:me after:…`, Calendar free blocks for today). Do not retry more than once; never drop
     a failed source silently.
   - **One** ingest, no files: `rabota ingest --stdin <<'EOF'` with ONE line of compact JSON
     keyed by source, `{"slack": {"fetched_at": "<UTC Z>", "ok": true, "error": null,
     "items": [...]}, "calendar": {...}}` (a failed fetch: `"ok": false`, `"error": "<why>"`,
     `"items": []`), then `EOF`. **`ok` must be a JSON boolean.** Only sources in `needs` that
     you fetched (never fireflies). A bad source among good ones exits 4; the good ones land.
   - **Reconcile** (`references/reconcile.md`): one `rabota tracked <key> [<key>…]` call with
     exactly the subjects you are classifying (issue keys, `owner/repo#n`); it answers `found`,
     `not_found`, `unknown` or `ambiguous` per key. Turn 1 carries no `tracked` field; do not
     re-read `sources/*.json`. Classify every commitment in the fetched and `fetched: true`
     items. Record: `rabota escalate --question … --evidence … --option …` for questions;
     dated promises become pins: `rabota pin <key> --bucket 2 --rationale …`. Say "already
     done" as confidently as "overdue"; cite the artifact.
   - **Brief, turn 2's final call.** `rabota --text brief --max-lines 11 --classified fireflies` —
     `--classified fireflies` is what actually marks the Fireflies items you were just handed as
     classified; omitting it (e.g. a bare `rabota --text brief`) classifies nothing, however many
     items the screen names. Print its lines verbatim, then append ≤2 lines of reconcile delta.
     **This is the only screen `/rabota brief` prints on a stale morning.** Nothing else goes to
     the terminal.
3. **Dispatch.** `rabota lane recipe --brief <path> --repo <path> --machine dev --run` — one call, one unit,
   seat-gated; the CLI refuses with the seat's `resets_at` when the window is spent. `--machine dev`
   is **required** with `--run`: the local form is not implemented and refuses. Watch with
   `rabota --text census`; read only the lane's `verdict.json` (≤4 KB), which lives at
   `<machine state_dir>/out/<tenant>/<lane_id>/verdict.json` **on the lane's machine** — no command
   prints it, so fetch that one file. Evaluate with
   `rabota lane recipe --kind evaluate --of <lane> --run` (DO-670) and read `evaluation.json` only.
   Never read a pane, never send a keystroke, never `journalctl` a lane into this context. A lane
   that settled `failed` with no output file shows why in `rabota lane status <id>`.
4. **Monitor and evaluate.** `rabota --text census` settles a finished lane's row — never
   poll on a clock, never read a pane. Read only `verdict.json`, fetched from the path in step 3.
   For anything going to a critical reader, evaluate as in step 3 and read only
   `evaluation.json`. `rabota lane retire <id>` as soon as evaluated.
5. **Close.** `rabota close [--note …]`. Then `rabota --text reap`; apply only
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

The screen is ≤12 lines, and there is **exactly one** of them per `/rabota brief`. Turn 1's
`rabota brief` is JSON (needed for `needs`), so when `needs` is empty **print its `lines` field**,
not raw stdout — and when `needs` is non-empty print nothing until turn 2's final `rabota --text
brief --max-lines 11 --classified fireflies` (one line reserved for the reconcile delta); print
its lines verbatim. `--text` is a GLOBAL
flag and must precede the subcommand — `rabota brief --text` exits `unrecognized arguments`.
`sol brief` handles its own line. Narrative lives in `brief.md`; print its path once. On a
rerun the same day the CLI prints the delta. A source that failed, or a `linear`/`github`
snapshot the CLI cannot rely on, gets its own `!` line from the CLI — you never compute one.

## Before reporting

1. Did turn 1's `rabota brief` return successfully (not exit 3), or am I trusting an absence?
2. Is every number from a CLI result or an artifact, not from a lane's prose?
3. Is the terminal output ≤12 lines?
4. Did every outward action have a typed OK and a `rabota gate` record?
5. Is anything load-bearing only in my context? If so, write it down now.

## See also

`references/rules.md` (standing invariants) · `references/reconcile.md` ·
`references/lanes.md` · `quantivly-conventions:prs` / `:linear` · `zvi-voice`.
