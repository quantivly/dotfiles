# Reconcile — classifying commitments

Six classes, fixed vocabulary (`rabota/tests/fixtures/reconcile/golden.json` is the golden set).
**A class names the KIND of commitment, not its current state.** "Already answered" or "already
done" is an `outcome`, never a `class` — the six names below have no seventh slot for state, and
folding state into the class name is the one blind-evaluate mistake seen so far (a run once wrote
`Class: question owed → already answered`, which is a `question-owed` item whose `outcome` is
that it was already answered — not a new class).

Read `blocks`/`blockedBy` relations before description prose: a Linear description can be stale
in a way the relation graph is not.

| Class | Meaning | Example |
|---|---|---|
| `promised-untracked` | A spoken or written commitment with no Linear issue or PR behind it. | Fireflies transcript action item attributed by speaker, no issue filed (golden `g08`). |
| `tracked-satisfied` | Already tracked, and the tracked state shows it needs nothing further. | PR `reviewDecision: APPROVED`, someone else already reviewed, author merges their own (golden `g03`). |
| `spoken-already-done` | A promise that was discharged, verified against the artifact, not the handoff. | A drafted Slack reply verified as sent at a specific `ts` (golden `g11`). |
| `question-owed` | Someone is waiting on a reply from @zvi specifically. | Named in a group DM with a direct ask, no reply yet (golden `g02`). |
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
