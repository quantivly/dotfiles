# Scrubbing credentials out of transcripts at rest

A **maintainer's record**: the 2026-09-23 audit, the reasoning behind
`scripts/scrub-transcript-secrets.py` and its timer, and the traps found on the way.
The operative rules live in [CLAUDE.md](../CLAUDE.md); add new evidence here, not there.

Its sibling is [SECRET_EMISSION.md](SECRET_EMISSION.md), which covers **prevention** — the
`PreToolUse` guard and the pipe redactor. This page is about the credentials that got past
all of that and are already on disk. If a secret has been **committed**, that is a third
thing again: [SECURITY_INCIDENTS.md](SECURITY_INCIDENTS.md).

## The audit

A herdr-draft session on 2026-09-23 logged its own environment into its Claude Code
transcript. Sweeping every transcript on the machine found:

| credential | occurrences |
|---|---|
| `CLAUDE_CODE_MESSAGING_TOKEN` | 231 |
| `LINEAR_API_KEY` | 74 |
| `sk-ant-…` | 59 |
| `GH_TOKEN` | 50 |
| `ANTHROPIC_API_KEY` | 49 |
| `gh[pousr]_…` | 29 |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | 8 |
| `ntn_…` | 6 |
| `github_pat_…` | 5 |
| `lin_api_…` | 2 |

**154 of 2,344 `.jsonl` files, 521 occurrences.** All 154 were scrubbed and verified the
same day: 0 files carrying a credential across 2,351 transcripts, 0 leftover backups,
0 unparseable JSON lines.

**Rotation was considered and declined.** That decision stands, and nothing in this tooling
assumes those values are dead. It does mean the honest claim for a scrub is narrow:
transcripts are conversation context, so anything captured has already left the host.
**Scrubbing stops the next reader of the disk, not the last one.** It is worth doing anyway,
because the disk is the copy that persists, accumulates, and gets backed up.

## Why prevention cannot close this

`claude/hooks/secret-emission-guard.sh` is a `PreToolUse` hook on `Bash`. It can refuse a
*command* that would print a credential, and that is all it can do. **It cannot observe a
program's own file write** — and the leak source here is precisely that: a program logging
its own environment into a transcript, with no `Bash` tool call anywhere in the chain.

So the emission is outside every preventive control this repo has, and periodic scrubbing is
what is left. That is the same shape of argument `systemd/wt-gc-sweep.timer`'s header makes
for worktrees: when every in-band mechanism has been tried and does not carry the load, what
remains is something ambient.

## Why it is a second tool and not another rule in `redact-secrets.sh`

`scripts/redact-secrets.sh` has two rule families, and the scrubber carries **both, in
full** — the same 16 rule labels, asserted by the state table (see *Parity* below). What
differs between the two files is not coverage but the **value grammar**: where a redacted
value ends.

Its **shape** rules (`gho_…`, `sk-ant-…`, `lin_api_…`) match anywhere, including inside a
JSON string, and caught most of the audit's findings. Six of the fifteen are *keyed* —
`aws_secret_access_key=`, `SAMLRequest=`, `AUTH_FAILED,CRV1:`, `Bearer `, `-----BEGIN …
PRIVATE KEY-----`, `https://user:…@` — and those need translating rather than copying,
because their value ends where a **line** ends and here a line is a whole JSON record. Its
**name** rules are the problem the tool was built for:

```
(^|[[:space:]])[A-Z][A-Z0-9_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|CREDENTIAL)[A-Z0-9_]*=[^[:space:]]+
```

**Both ends are wrong for a credential at rest, not just one.** This is the part worth
writing down, because the obvious fix is wrong:

- The **leading boundary** never matches. Inside a `.jsonl` transcript the newlines are
  escaped `\n` *within* a JSON string, so there is no real whitespace character before the
  variable name.
- The **terminator** `[^[:space:]]+` would then run to the next *real* space — that is, it
  would swallow the rest of the JSON line. Loosening the anchor alone would **mangle**
  transcripts rather than redact them.

A JSON string is a different value grammar, so it needs different rules: the scrubber's name
rules end a value at a quote, a backslash, whitespace or a separator. That is why this is a
separate tool and not a seventeenth `-e`.

**None of this is a bug in `redact-secrets.sh`.** It is a pipe filter, and in a pipe the
whitespace is real. Its own header argues, correctly, that it is "deliberately NOT a general
secret scanner", and it is named as the remedy by the emission guard's deny message — so a
false positive there costs the whole pipeline. The two jobs have genuinely different boundary
rules and stay apart.

That premise is pinned by a row in `scripts/test-scrub-transcript-secrets.sh` which runs the
**same bytes through both tools** and asserts that one misses what the other catches. If
either half ever changes, the row fails rather than the argument quietly rotting.

> Getting that row right took two attempts, and the first failure is instructive: the fixture
> read `export SONIOX_API_KEY=…`, which hands `redact-secrets.sh` a **real space** before the
> name, so its anchor matched and the row proved the opposite of what it claimed. The
> condition being tested is an escaped newline hard against the name, with no real whitespace
> anywhere on the line.

## The eight shapes that were missing, and what translating them costs

Measured 2026-09-23 (DO-700): the scrubber shipped with **seven of the redactor's fifteen**
shapes, inherited from the out-of-repo handoff script it grew from, while its own docstring
said they were "reused verbatim". Two of the missing eight were DO-692's, added to
`redact-secrets.sh` the same week and never propagated — which is the drift the *Parity*
section below exists to stop. Upper-bound counts across both roots, 2,438 files (this grep
does not apply the `PLACEHOLDER` guard, so some hits are already-redacted or prose):

| shape | files |
|---|---|
| `url-password` (`https://u:pw@`) | 68 |
| `bearer` | 12 |
| `vpn-auth-challenge` (`AUTH_FAILED,CRV1:`) | 8 |
| `aws-temp-key-id` (`ASIA…`) | 7 |
| `private-key` (`-----BEGIN … PRIVATE KEY-----`) | 6 |
| `aws-access-key-id` (`AKIA…`) | 3 |
| `saml-request` | 2 |
| `aws-secret` (`aws_secret_access_key=`) | 0 |

**Three translations from POSIX ERE to Python `re` on bytes**, each forced by the grammar:

1. `[[:space:]]` becomes `[ \t]`, never `\s`. sed is line-oriented, so its whitespace class
   cannot cross a record; the scrubber matches the whole file at once, where `\s` would let
   a rule bridge two JSON records. Unobservable on well-formed JSONL — a record always
   closes with `"` — and kept anyway, because relying on that is relying on the input being
   well formed.
2. A value class gains `"` and `\` wherever sed's ended at whitespace. Same reasoning as the
   name rules: in a pipe the whitespace is real, in a JSON string it is an escaped `\n`.
3. A value class also gains `<`, so a replacement cannot be re-matched. That is what makes a
   second run a byte-for-byte no-op **and a no-count one**. A rule that re-matches its own
   output reports replacements it did not make, on every nightly run, forever — and it is
   invisible to a `cmp`-based idempotence check, because the bytes are identical.

**`private-key` is the one that needed real thought, and the naive translation is a trap.**
In sed the rule is `(-----BEGIN [A-Z ]*PRIVATE KEY-----).*` — eat to end of line. Inside a
JSON string "end of line" is the end of the whole **record**, so `.*` swallows the closing
`"}`, `unparseable()` refuses the file, and the key sits there un-scrubbed while the run
reports a refusal. Verified: that spelling produces exactly one unparseable line on a
one-record fixture. So the body is matched as what a PEM in a JSON string actually is —
base64 runs and escaped newlines, `(?:\n|[A-Za-z0-9+/=])+` — stopping at the `-` of the END
marker, which is **kept**, so a redacted record still reads as what it was. The `+` rather
than `*` is load-bearing: with `*`, a bare mention of the header in prose would match,
append a marker, and append another on every run after that.

## The name rule: a pattern, not an allowlist

This is the judgement call in DO-700, and it is **not a free win**. The scrubber shipped with
a hardcoded seven-name allowlist where `redact-secrets.sh` has a generic suffix pattern. The
argument for keeping an allowlist is real and worth stating plainly: a pipe filter's false
positive is a mangled line on a screen, but this job runs **unattended, nightly, and shreds
its own backup** — so a false positive here permanently rewrites a transcript with no undo.

It is now the pattern. Four reasons, in order of weight:

1. **The measured miss is not a tail, it is the bulk.** Across 2,438 transcripts, none of
   these was reachable by the seven: `DB_PASSWORD` 75 files, `OPENAI_API_KEY` 55,
   `GITHUB_TOKEN` 51, `DEFAULT_API_KEY` 45, `POSTGRES_PASSWORD` 41, `TEXTQL_API_KEY` 34,
   `OIDC_CLIENT_SECRET` 22, `SMTP_PASSWORD` 20, `AZURE_OPENAI_API_KEY` 18,
   `CLAUDE_CODE_OAUTH_TOKEN` 15. An allowlist cannot name what the next project calls its
   secret, and the standing cost of under-scrubbing is a live credential on disk.
2. **A false positive here is bounded in a way the pipe case never was.** Only the value is
   replaced and the name stays; the value grammar stops at the JSON string boundary; and
   `unparseable()` refuses anything that would not survive the edit. The worst case is one
   lost token in one record — not a mangled line, and never an unreadable file.
3. **The allowlist *was* the drift.** Two hand-kept parallel lists are what this issue is
   about. Replacing one of them with the pattern the other already uses removes the thing
   that rotted instead of re-stating it.
4. **What actually bounds false positives is `PLACEHOLDER`, and it is name-independent.**
   `$VAR`, `<REDACTED:…>`, `your-token`, `xxxx`, `…` are exempt whatever the variable is
   called, and an 8-character floor drops `TOKENIZERS_PARALLELISM=false` and
   `MAX_TOKENS=4096`. Both are rows.

**What is knowingly accepted:** a path-shaped value under a credential-shaped name —
`GOOGLE_APPLICATION_CREDENTIALS=/home/u/key.json` — is redacted. A guard for it would have to
exempt values starting `/`, and base64 secrets start with `/` too; that trades a harmless
false positive for a real miss, which is the wrong direction for this tool.

**The value grammar is not widened and must not be.** It ends at a quote, a backslash,
whitespace or a separator. `_PAT` stays a rule of its own for `redact-secrets.sh`'s measured
reason — inside the alternation, the trailing `[A-Z0-9_]*=` absorbs whatever follows and
`SOME_PATH=`, `MY_PATHS=` and `COMPATIBLE=` all redact. All five of those names are a row.

One consequence worth knowing: a name-rule hit is counted under the **variable name**, not
under `by-name`, so `--dry-run --json` lists exactly which variables a run would rewrite.
With the rule a pattern rather than a list, that is the only review surface there is.

## Parity: the mechanism, which is the actual fix

Nothing asserted that the two files carried the same rules, so they drifted — seven shapes of
fifteen here, and DO-692's two in one file and never in the other. Any fix that is only a fix
rots the same way.

`scrub-transcript-secrets.py --rules` prints the redaction labels it applies, **derived from
the compiled rules** rather than from a second list, because a hand-kept inventory is exactly
what drifted. The state table compares that against the labels it reads out of
`redact-secrets.sh`'s `sed` program and fails if either side has a rule the other does not.

**The comparison is over rule labels, not patterns, and that is deliberate.** The two files
are in different languages against different value grammars, so their patterns *should*
differ; an assertion that they match textually would be wrong as well as fragile. What must
never differ is the set of credentials either one claims to cover, and a label is exactly
that claim.

Three rows exist because the obvious version of this check passes vacuously:

- **Both counts are asserted against a literal.** Two extractors that harvest nothing agree
  perfectly with each other, and that looks identical to a pass.
- **A rule deleted from a *copy* of `redact-secrets.sh` must be detected and named.** A row
  showing the extractor agrees with the scrubber proves nothing on its own — a function that
  returned the scrubber's own list would pass it.
- **An unreadable redactor is not a pass.** "No labels" compares equal to an empty list.
  `test-secret-guard.sh` grew the same row after a mutation sweep found its docs check
  reporting *could not run* as a pass, with every other row green because none reached that
  branch.

A fourth closes the loop the other way: **every advertised label must have a fixture in the
suite.** A rule can reach both files, pass every parity row, and still never be exercised.

## Roots are derived, and the reason is measured

`~/.claude/projects` is not the only transcript tree on a machine running these dotfiles.
`claude()` gives **every session its own account dir**, and each of those carries a
`projects/` of its own.

Measured on cilantro, 2026-09-23, after the scrub was reported complete:

```
2367  ~/.claude/projects
  58  ~/.local/state/claude-account-dirs/toysim-0/projects   <-- never scanned
   0  (nine other account dirs)
```

Those 58 were clean, but nothing had ever looked at them: the original scrubber's root was a
hardcoded `/home/zvi/.claude/projects`. **A hardcoded root is how the next one gets missed**,
so discovery enumerates `~/.claude/projects` plus every
`~/.local/state/claude-account-dirs/*/projects` that exists.

Discovery also **drops a root nested inside another**. Scanning one file twice in a single
run makes the second pass see the mtime the first pass just set, and report a live-session
skip that never happened — a fault that looks exactly like the mechanism working.

## The safety rules, and which one is load-bearing

1. **Never prints a matched value.** Output is counts and filenames. A diagnostic that
   prints the credential it found is the failure this whole area exists to stop.
2. **Refuses any file whose scrubbed form would not parse as JSON**, per line. Replacements
   are `<REDACTED:kind>` — no quote, no backslash — so a value inside a JSON string stays a
   valid JSON string.
3. **Re-checks size and `mtime_ns` immediately before writing**, and skips a file that
   changed. This is the one with real teeth: rewriting a transcript a live session is
   appending to silently drops whatever landed between the read and the write. A scheduled
   run meets live sessions routinely, so **skips are the normal case and are not a failure**
   — the next run catches them, the tool being idempotent.
4. **Backs up, writes, re-reads, verifies, rolls back on mismatch, and shreds the backup at
   once.** A backup is a second copy of the same credentials. A `shred` that fails is
   reported and exits non-zero; a missing `shred` refuses the run outright rather than
   leaving one behind.
5. **`SCRUB_SELF_TRANSCRIPT`** excludes a path substring. Nothing sets it automatically, so
   it is inert unless passed; under systemd there is no session and rule 3 covers the case.

Rule 3 guards a race nothing can provoke on purpose, so the script carries exactly one test
seam — `SCRUB_TRANSCRIPT_PRE_WRITE_HOOK`, a command run between the read and the re-stat —
and the state table uses it. An untestable branch is an untested branch, and this repo's
records say so in three places.

## Exit codes

| | |
|---|---|
| `0` | ran clean. **Skips count as clean**: a skipped live session is the mechanism working. |
| `1` | a file was REFUSED, ROLLED BACK, or left with an unshredded backup. |
| `2` | **COULD NOT RUN** — no transcript root exists, `shred` is missing, or the state dir could not be created. |

Exit 2 is never a pass, for the house reason: *"0 credentials found"* and *"I never looked"*
are the same sentence otherwise, and the second one reads as success. The original version of
this script returned `0` on every path, which made it useless as a systemd unit — it could
not signal failure at all.

Every run appends one line to `~/.local/state/scrub-transcript-secrets/log`:

```
<UTC ISO8601> mode=<dry|apply> roots=N scanned=N scrubbed=N replacements=N skipped=N refused=N shred_failed=N
```

`mode=` is there for the reason `wt-gc-sweep.sh` has it: a dry run logging `scrubbed=0`
otherwise reads exactly like an apply that did nothing.

## Cadence, and why the argument differs from wt-gc-sweep's

`wt-gc-sweep` is daily because it is the most network-expensive job on this machine and
running it faster buys nothing. This one makes **no network call at all**: 4.2 GB of
transcripts across both roots, and a full counts-only pass over them measured **6.1 s wall**.
Cost does not bound the cadence.

**Skip rate does.** Every run rewrites files that live sessions may be appending to, and rule
3 turns those into skips — so the useful work a run does is inversely proportional to how
many sessions are awake. An hourly timer would rewrite the same ~2,400 files twenty-four
times a day over a corpus that gained a handful of lines, and would spend most of its runs
skipping exactly the transcripts that matter most: the active ones. Once a day, when the
fewest sessions are live, is when the fewest files are skipped.

03:00 rather than `wt-gc-sweep`'s 04:00, because `Persistent=true` means a desktop asleep at
the scheduled time runs the job on the next resume, alongside everything else that was
missed. Both carry half an hour of jitter for the same reason.

A missed night costs nothing: a second pass over an already-scrubbed transcript is a
byte-for-byte no-op.

## Linked, not enabled

`./install` symlinks both units and enables neither. Arming is a typed command after one real
dry run:

```bash
scripts/scrub-transcript-secrets.py --dry-run
systemctl --user daemon-reload
systemctl --user enable --now scrub-transcript-secrets.timer
```

Never `systemctl --user reenable` — its disable half deletes the dotbot symlink that *is* the
unit. `scripts/reconcile-systemd-units.sh` derives its unit list from symlinks resolving
inside the checkout, and `scripts/check-timer-health.sh` derives its list from that, so both
pick the unit up automatically and report `linked, not enabled — not checked` rather than
going red.

The gate is not ceremony. **The Claude Code permission classifier refuses an agent running
this script at all**, `--dry-run` included, with `[Session Transcript Tampering]` — measured
2026-09-23 while planning this change, and again during the original scrub, where the batch
`--apply` was refused while a single-file write had been allowed. Whatever one makes of the
boundary, an unattended job that does the thing an agent is refused is worth one human
decision before it starts running nightly.

## State table

`scripts/test-scrub-transcript-secrets.sh` (111 checks, hermetic, run in CI as
**Transcript Scrub State Table**). It carries the same 16 rule labels as
`scripts/redact-secrets.sh`, and a row asserts that — see *Parity* above. Every row runs against a throwaway `mktemp` tree reached
through `SCRUB_TRANSCRIPT_ROOTS`; nothing in the file names `~/.claude/projects`. Fixture
credentials are assembled at runtime so the file contains no literal that `gitleaks` or
`detect-private-key` would flag over its own test data — the same trick
`scripts/test-secret-guard.sh` uses.

One defect found in the suite itself, and worth the warning: the runner originally stashed
the subject's exit status in a variable, but every capturing row invokes it inside a command
substitution, where the assignment cannot reach the calling shell. Those rows read whatever
the **previous** run had left in the variable — one was green for entirely the wrong reason
until a genuine failure elsewhere exposed it.
