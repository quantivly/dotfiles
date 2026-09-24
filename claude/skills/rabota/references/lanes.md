# Lanes — dispatch, budget, verdict

Enumerate. Never hand a lane a live query — a lane gets a brief, not a socket into your session.

## Dispatch (exists today)

```
rabota lane recipe --brief <path> --repo <key> --machine dev [--base <ref>] \
  [--seat <name>] [--model <name>] [--effort <level>] [--est-minutes <n>] [--run]
```

Without `--run` this only prints the argv (a dry-run recipe), and `--machine` may be omitted.
On a remote machine `--repo` is a **key** into `[machines.<m>].repos` (`dotfiles`, `hub`),
not a path; locally it is a path fragment under the tenant root. The error quotes your path
back as though a path were wanted.
With `--run`, `--machine dev` is **required** — the local `--run` form is not implemented and
refuses. With `--run` it is one call, one unit: `rabota budget` gates the seat before anything starts, and the CLI refuses with the seat's
`resets_at` when the window is spent — do not retry around a refusal, print it and continue.

Watch with `rabota --text census`, which is also what settles a lane row from `started` to a
terminal status once the unit exits — you never poll a unit or a pane directly. When a lane is
settled, read only its `verdict.json` (≤4 KB) — never a pane, never `journalctl`. That file is
at `<machine state_dir>/out/<tenant>/<lane_id>/verdict.json` **on the machine the lane ran on**
(for `dev`, `~/.local/state/rabota/out/<tenant>/<lane_id>/`); no subcommand prints it, so fetch
that one file and nothing else from the out dir.

**Pending DO-670:** `rabota lane recipe --kind evaluate --of <lane> --run`, for a second lane that
judges the first lane's verdict before it reaches a critical reader, is not implemented on `main`
as of this writing — `rabota lane recipe` takes no `--kind`/`--of`. Document and use it once
DO-670 lands; until then, a critical-reader deliverable is a gate (typed OK), not an evaluate lane.

## The brief template (seven headings)

`# <title>` · `## Common rules` · `## Role` · `## Assignment` · `## Ownership` · `## Outputs` ·
`## Summary`. Example, abbreviated:

```markdown
# Task 5.3: the rabota v2 skill

## Common rules
Read `_common-rules.md`, in this brief's own directory, first; if it is not there, stop and
say so in your verdict. You are one lane, push back with evidence.

## Role
You write the v2 skill and its three references. No Python, no new subcommand.

## Assignment
Primary spec: `plans/WS5-skill-timer-migration.md` §Task 5.3, amended by §3.3.

## Ownership
Detached HEAD at `origin/main`; `git switch -c <branch>` before the first commit.

## Outputs
out_dir: <path>. Write `verdict.json` per the schema below.

## Summary
One or two sentences a reader can act on without opening the brief.
```

## Verdict schema

`{"lane", "status", "claims": [{"id", "text", "evidence": {"cmd", "expected", "observed"},
"confidence"}], "deliverables", "followups"}`. A claim you could not actually verify gets
`confidence: "low"` and says why — never silently drop it.
