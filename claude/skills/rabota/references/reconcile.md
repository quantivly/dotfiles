# Reconcile — classifying commitments

Six classes, fixed vocabulary (`rabota/tests/fixtures/reconcile/golden.json` is the golden set).
**A class names the KIND of commitment, not its current state.** "Already answered" or "already
done" is an `outcome`, never a `class` — the six names below have no seventh slot for state, and
folding state into the class name is the one blind-evaluate mistake seen so far (a run once wrote
`Class: question owed → already answered`, which is a `question-owed` item whose `outcome` is
that it was already answered — not a new class).

The axis that separates the six is the KIND of commitment — a question, a promise, a tracked
item — never whether it is currently outstanding. `question-owed` and `spoken-already-done` are the
pair this trips people on: they differ because one is a question and the other a promise, **not**
because one is open and the other closed. Golden `g01` is a question that was already answered and
is still `question-owed`, with "already answered" as its `outcome`; `g11` is a promise that was
discharged and is `spoken-already-done`. Ask "what kind of thing was committed?", never "is it done
yet?" — the second question is what `outcome` records.

Read `blocks`/`blockedBy` relations before description prose: a Linear description can be stale
in a way the relation graph is not.

Inputs: turn 1's `rabota brief` reply carries `tracked.{linear,github}` — a slim projection of
`sources/linear.json` and `sources/github.json` built by `reconcile.build_tracked_index`. Use it
directly; do not re-read the snapshot files. `tracked.<side>.ok` means "you can rely on this",
with `reason` saying why not when it is false and `skipped: true` marking a source the tenant
does not use rather than one that failed.

**`state-contradiction`'s "no PR exists" case (golden `g06`) is not decidable from `tracked`
alone.** `github.json` carries only `own_prs`/`review_requests`/`merged_recent`, and Linear's
`ISSUE_FIELDS` never selects `attachments` — so "no PR exists" and "a PR exists attached to the
issue that you cannot see in this projection" (golden `g07`) look identical from the index. Do
not assert "no PR exists" from `tracked` alone; that gap is open as DO-735.

| Class | Meaning | Example |
|---|---|---|
| `promised-untracked` | A spoken or written commitment with no Linear issue or PR behind it. | Fireflies transcript action item attributed by speaker, no issue filed (golden `g08`). |
| `tracked-satisfied` | Already tracked, and the tracked state shows it needs nothing further. | PR `reviewDecision: APPROVED`, someone else already reviewed, author merges their own (golden `g03`). |
| `spoken-already-done` | A **promise** @zvi made, discharged — verified against the artifact, not the handoff. | A drafted Slack reply verified as sent at a specific `ts` (golden `g11`). |
| `question-owed` | A **question** put to @zvi that a reply was owed on — whether or not one has since been given. | Named in a group DM with a direct ask (golden `g02`, unanswered; golden `g01`, already answered — **both** are `question-owed`). |
| `state-contradiction` | The tracked state and the real state disagree. | "In Review" with no PR to review (golden `g06`). |
| `stale-blocked` | A recorded blocker no longer holds. | A "needs SSH" caveat that no longer applies once VPN is confirmed (golden `g12`). |

## Recording a classification

- `question-owed` → `rabota escalate --question "<what they asked>" --evidence "<source>" --option "<option>" [--option "<option>"]`
- `promised-untracked` (dated) → `rabota pin <key> --bucket 2 --rationale "<why now>"`
- `spoken-already-done` / `tracked-satisfied` → no CLI write; say it in the brief delta, citing
  the artifact, as confidently as "overdue".
- `state-contradiction` / `stale-blocked` → escalate if it changes what's actionable; otherwise
  note the correction in the brief delta.

Every record cites its evidence (a URL, an issue key, a transcript ID) — never "the handoff said
so".
