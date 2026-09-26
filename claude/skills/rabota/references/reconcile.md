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

Inputs: `rabota brief`'s turn-1 reply no longer carries a tracked-side index (DO-751 — it grew
linearly with the tenant's open-issue count, measured ~303 KB on a synthetic tenant scaled to
@zvi's real one). Once you know which subjects you are classifying, call `rabota tracked <key>
[<key>…]` — one call, no network, answered from `sources/linear.json`/`sources/github.json` on
disk. Never re-read those snapshot files yourself.

Each key in the reply's `results` is exactly one of:

- `{"key", "status": "found", "kind": "linear"|"github", "record": {...}}` — the tracked record
  (a Linear issue with `pr_links`, or a GitHub PR tagged `kind: "own_pr"`/`"merged_recent"`).
- `{"key", "status": "not_found"}` — the source is trustworthy and simply does not name this
  subject. This is what `promised-untracked` needs: proof of absence, not silence.
- `{"key", "status": "unknown", "reason"}` — the source cannot be relied on (unsynced,
  unreadable, or the tenant does not use it). **Never treat this as `not_found`** — that
  conflation is golden `g06`'s bug one level up (a pre-attachment snapshot read as "no PR
  exists" rather than "attachments unknown").
- `{"key", "status": "not_applicable"}` — the subject is a person-plus-topic (a Slack thread, a
  Fireflies transcript), never a Linear identifier or an `owner/repo#n` PR key. `question-owed`
  and `spoken-already-done` are always this — verify them against the connector artifact
  itself, never against `rabota tracked`.

The top-level `linear`/`github` in the reply carry the same source-level `ok`/`reason` as before,
for when nothing you asked for resolved to either side at all.

**`state-contradiction`'s "no PR exists" case (golden `g06`/`g07`, DO-735).** Each Linear issue's
`pr_links` is `null` (snapshot predates attachment sync — treat as unknown, never as "no PR"),
`[]` (checked: no PR linked), or a list of `{key, url, state, title}` (`state` is `"open"`/
`"merged"` when `github.json`'s `own_prs`/`merged_recent` confirms it, else `"unknown"` — never a
live cross-org GitHub search; `title` is that PR's title, carried along from the same match, or
`null` when the state is still `"unknown"`). **`key` can never be the g07 signal**: it is always
`owner/repo#n`, never a Linear identifier, so it cannot "name a different issue" — a non-empty
`pr_links` whose `key` is a real PR is unremarkable on its own. The actual signal is `title`: a
`pr_links` entry whose title reads as belonging to a different piece of work than the issue it's
attached to (golden `g07` — HUB-5812's one attachment resolves to a PR titled `HUB-5693`, not
HUB-5812).

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
