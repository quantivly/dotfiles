# Claude Code accounts: mechanisms, traps and incidents

The evidence behind the **Claude Code accounts & MCP** rules in [CLAUDE.md](../CLAUDE.md): how the
credential file, per-session account dirs and clauth interact, what broke, and what was measured.
The rules themselves stay in CLAUDE.md, because a rule moved behind a pointer stops being read;
this page is where the *why* lives. Companions: [CLAUDE_ACCOUNT_PICKER.md](CLAUDE_ACCOUNT_PICKER.md)
(which account a session gets) and [CLAUDE_ACCOUNT_MCP.md](CLAUDE_ACCOUNT_MCP.md) (the operational
runbook: what to run, what to click).

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-622), from the tree at `dab17b3`.**
> Nothing was rewritten — paraphrase is the one loss no check can see. So in the text below
> "this file" means CLAUDE.md, and "above", "below" and "N sections up" refer to its layout at
> that commit; `git show dab17b3:CLAUDE.md` restores the context. **Add new evidence here, not to
> CLAUDE.md** — the rules stay there, the evidence lives here.

---

## Claude Code accounts & MCP (`claude-doctor`)

**One unlocked file holds the login AND every MCP token, and ~23 processes write it.**
`~/.claude/.credentials.json` (0600) carries both `claudeAiOauth` — the claude.ai login —
and an `mcpOAuth` map with each plugin MCP server's own OAuth tokens. There is a
`~/.claude/.claude.json.lock` for the *config* file and **nothing for the credentials**, so
every token refresh is a read-modify-write of the whole file by whichever process gets there
first. `CLAUDE_CONFIG_DIR` **does** isolate credentials here (the file moves under it, and the
macOS Keychain entry is keyed to it) — the **opposite** of `GH_CONFIG_DIR` two sections up, so
do not carry that intuition across. Isolation working is what makes `clauth start` a fix.

The race is not theoretical, and the damage moves between entries. Four reads of the same file
on 2026-09-06:

| time  | slack | Notion | linear | Claude procs |
|-------|-------|--------|--------|--------------|
| 10:48 | `accessToken` **zero-length**, `refreshToken`/`expiresAt`/`scope` absent | valid 23 h | valid 23 h | ~23 |
| 11:00 | `expiresAt: null`, no refresh | valid 23 h | valid 23 h | 25 |
| 11:38 | token length 0 | **entry absent** | **entry absent** | 26 |
| 12:00 | valid 11 h (re-authed via `/mcp`) | token length 0 | token length 0 | 27 |
| 12:09 | valid 11 h | valid 23 h (re-authed) | valid 23 h (re-authed) | 30 |

**Expiries do not grow keys back, a 23-hour token does not decay into a blank string, and
entries do not vanish and reappear.** Those are interleaved writes. The 12:00 row is the
sharpest: authenticating *one* server through `/mcp` is what blanked the other two, because all
three live in the one file and the writer that added Slack carried a stale copy of the rest. It
is also why sessions log `No access token in storage` → `UnauthorizedError` while the file on
disk holds an unexpired token, and why the daily counts track concurrency, not token lifetime.

**CORRECTED 2026-09-06 — the 10:48 row is not a race, and reading it as one cost five false
failures.** `mcpOAuth` is stored **per config dir**, and the entry Claude Code writes after OAuth
*discovery* but before *authorisation* has an empty `accessToken` with `clientId`,
`discoveryState`, `issuer`, `redirectUri`, `serverName` and `serverUrl` — and **no** `refreshToken`,
`expiresAt` or `scope` at all. That is exactly the 10:48 signature. Every isolated session starts
there, so `hspawn` workers have had no plugin Notion/Linear/Slack since #107 made isolation the
default, and `claude-doctor` reported three ✗ "interleaved write" against a perfectly healthy
session while the same three entries read `✓ valid, refreshable` out of the global file in the
same minute.

**The discriminator is the metadata, not the token.** An authorised entry that loses its
`accessToken` *keeps* its `expiresAt` and `scope`, because a token cannot shed its own string and
keep its bookkeeping by expiring. Empty token **with** that metadata is a lost race; empty token
**without** it is a server nobody has authorised in this config dir. The rows from 11:38 and 12:00
— entries that were valid for 23 h and then went to length 0, or vanished outright — remain
genuine interleaved writes; only the 10:48 shape was misread.

**The per-config-dir storage is the unpaid cost of isolation, and it has a cheap answer.** Adopting
a profile otherwise means one browser OAuth flow per plugin MCP server per profile. The **claude.ai
connectors** for the same three services need no `mcpOAuth` entry at all — they ride the login
token — and already work in an isolated session. `claude-doctor` has warned that all three are
duplicated across both paths since it was written; retiring the plugin copies makes the per-profile
MCP cost zero and clears the warnings at the same time.

**But read the last row before drawing a threshold.** Two back-to-back re-auths at the *highest*
concurrency of the day left all three intact. This is a race, not a limit: more writers raise the
odds of losing it, they do not decide the outcome. So "it worked" is never evidence that a
sequence is safe, and one clean run is not a fix — which is exactly why the check after any
`/mcp` authentication has to be *all* the entries, every time.

**The two symptoms are one report.** The login's scopes include `user:mcp_servers`, and the
claude.ai connectors are fetched *with that token* — so a login that goes bad drops all of them
at once. "I get randomly logged out" and "my MCP servers keep disconnecting" are the same event
seen from two sides. Measured: `/login` run 8 times in 30 days across 665 transcripts.

**A logout is not one session's problem — it takes the whole box at once.** Caught with
timestamps on 2026-09-06, and this is the dominant mechanism, above the partial-write race:

```
12:23:33  clauth rewrites ~/.clauth/profiles/quantivly-3/credentials.json  (the LIVE profile)
12:23:35  six sessions begin failing "Login expired · Please run /login"
12:24:16  ...the last of them, 41 seconds end to end
12:25:09  /login recovery writes a `max` (personal) credential into the GLOBAL file
```

Refresh-token rotation is **server-side**: when any one session refreshes, the old refresh token
is invalidated *everywhere*. The fix is therefore isolation (`CLAUDE_CONFIG_DIR` per session)
rather than anything that makes the file-writing safer — even a perfectly atomic, perfectly
locked write would not help, because the invalidation happens at Anthropic, not on disk.

**But do not over-read that into "N holders, and the first rotation orphans the other N−1".** An
earlier version of this section said exactly that, and the transcript record does not support it.
Counting `isApiErrorMessage` login-expiry events across 694 transcripts and grouping them into
incidents, the eight days to 2026-09-06 gave:

| when (UTC) | sessions hit | | when (UTC) | sessions hit |
|---|---|---|---|---|
| 08-30 06:36 | 1 | | 09-03 05:43 | 1 |
| 08-31 09:46 | 1 | | 09-05 10:13 | 1 |
| **09-01 14:52** | **5** | | **09-06 01:46–04:16** | **3** |
| **09-02 06:23** | **4** | | **09-06 09:23** | **6** |
| **09-02 14:09** | **3** | | | |

**Nine incidents, five of them simultaneous across 3–6 sessions.** Literal per-holder orphaning
would not look like this: access tokens last **28800 s — 8 h** (measured 2026-09-14: 28799 s on
three fresh logins and 28800 s on a clauth refresh; this line said ~7.5 h, which was close, and a
2026-09-14 edit briefly replaced it with a WRONG 5 h — see the correction in "A long suspend
expires every account at once" below), so ~25 processes produce roughly three rotations an hour, and a holder orphaned by every other holder's rotation would be logged out
within the hour — dozens of times a day. This box averages about one. The reconcilable reading is
that Claude Code re-reads the credential file when it refreshes, so same-file holders mostly heal,
and the damage comes from **a third party writing a superseded credential into the shared file** —
a `clauth <profile>` switch, or a lost interleaved write.

Two consequences, and they decide the design rather than decorating it:

- **Removing the third writer and emptying the shared-global group is the high-value move.** Going
  finer than one credential file per *login* buys little.
- **A per-session credential COPY would make things worse**, turning the rare singleton class into
  the common one by creating genuinely independent holders of a single grant. Every per-session
  config dir in this repo therefore *symlinks* its credential to a profile store; none copies one.
  (The symlink is written *through*, not replaced — the profile stores carry `mcpOAuth` discovery
  records that only Claude Code writes.)

One more number from the same day, because it is the one the whole mechanism is aimed at: **17 of
18 live Claude processes had no `CLAUDE_CONFIG_DIR` at all**, so they were seventeen holders of one
file — and that file matched no registered clauth profile, so they were billing an account nobody
had selected. #107 isolated `hspawn` workers and touched none of them, because a human's own
`claude` does not go through `hspawn`.

Two things follow, and both bit during this investigation:

- **Count only `isApiErrorMessage` records.** A raw grep for `Login expired` over the same window
  returned nine hits across nine files; one file contained only *prose* — an agent quoting the
  error in an instruction. Six sessions actually failed. The transcript is both the evidence and
  a place the evidence is discussed, so the marker is what separates them.
- **After a `/login`, the live credential belongs to no clauth profile.** `clauth which` answers
  `unknown`, clauth holds no copy of it, and the next `clauth <profile>` overwrites it with
  nothing to restore. `claude-doctor` reports that as a ⚠ (it rendered as two `·` notes until
  2026-09-06), and separately names the case where the live credential belongs to a *different*
  profile than the active one — every other check passes while the session bills another account.

**clauth is a third writer, and it holds a stale copy.** `clauth <profile>` replaces the
`claudeAiOauth` subtree with the profile's **stored** tokens; its own strings say *"a session on
the global credentials adopts the change on its next token refresh"* and *"claude code's freshly
written credentials will be overwritten with the account's stored tokens."* Claude Code **rotates
refresh tokens** — clauth's log proves it (`adopted the live session's rotated login … the
running claude refreshed first`) — and clauth only notices on a ~90 s poll. In that window the
stored copy is a **superseded** refresh token, and restoring it can log out every live session.
`claude-doctor` compares live against stored and says so **before** a switch.

**And a switch leaves no record, so "it has not happened" is not a readable state.** The
investigation first concluded auto-switch had never fired, because 39 log lines since 08-29
contain no switch event — only `adopted the live session's rotated login` (twice) and
`another instance holds the usage-fetch lease` (35 times). That conclusion was **wrong**: the
active profile went `quantivly-3` → `quantivly-2` → `quantivly-3` inside about five minutes
*during the session that wrote this section*, the live credential's hash tracked each move, and
**`clauth.log` records none of it**. `status.json` shows only the current value and
`pending_switch: null`. So the fallback chain (95 %/5 h, 98 %/7 d) rewrites the shared
credential under every running session and the only evidence is the before-and-after value.
Read the active profile, never the log, and do not infer quiescence from a quiet log file.

Be precise about the rate, though: a 15-second sample over the following two minutes was
perfectly stable, so this is occasional switching, **not** constant flapping — the daemon's
90-second poll is a refresh cycle, not a switch cycle. Overstating it as flapping would put the
blame on the wrong mechanism.

**Most MCP noise was two deterministic bugs, not the race** — and both were invisible because
nothing read the log store Claude Code had been writing all along
(`~/.cache/claude-cli-nodejs/<slugified-cwd>/mcp-logs-<server>/<ISO>.jsonl`, 6,663 files):

- **`plugin:desktop-commander` had connected 0 times in 509 attempts over 34 days.** Its
  `npx -y @wonderwhy-er/desktop-commander@latest` hit a half-finished npm reify from 2026-06-30
  in `~/.npm/_npx/4b4c857f6efdfb61/` — 414 orphaned `.<pkg>-<random>` staging dirs, **no
  `.package-lock.json`** (the only one of 17 npx caches missing it), and an **empty**
  `@wonderwhy-er/` — so npm's rename-to-staging failed `ENOTEMPTY` every launch. `rm -rf` on the
  whole tree fixed it; removing one directory would not have, because `md-to-pdf` (×275),
  `pdf-lib` (×29) and `pizzip` each take over as the blocking rename in turn.
- **The `claude.ai Linear` connector id had gone dead upstream**, returning
  `mcp_endpoint_not_found` 1,936 times and accelerating (136 failures / 0 successes on the day
  it was found). It still advertised a full tool list, so **the tool list is not evidence of
  health** — only the log store is.

**Attempt count is not health.** A server that has never worked writes exactly as many log files
as one that always does; the only discriminator is the `Successfully connected` marker against
`Connection failed`. Counting files is how 34 days of total failure read as activity.

**Stdio MCP servers are never auto-reconnected** (documented). Remote ones retry five times with
1/2/4/8/16 s backoff; a stdio server that dies at startup stays dead for the whole session, which
is why desktop-commander's failure was once per session rather than once ever.

**Do not put MCP or auth env vars in `~/.claude/settings.json`'s `env` block.** clauth merges a
profile's `[env]` into it on switch and **clears it on switch away** — it is `{}` for that reason.
Anything set there is silently wiped at the next profile switch. Shell-level (`zsh/zshrc.herdr`)
is the durable place. Note also that `settings.json` is user-level and **not** in this repo, so
`./install` does not deploy it and nothing version-controls the MCP surface.

### Every session on its own credential (`claude-account-dirs`)

`scripts/claude-account-dirs.sh <profile>` builds `~/.local/state/claude-account-dirs/<profile>/`
and prints its path: **`clauth start`'s own runtime layout at a stable path.** Everything in
`~/.claude/` is symlinked back except three files — `.credentials.json` (a symlink to
`~/.clauth/profiles/<p>/credentials.json`), `settings.json` (a real file, refreshed from the
global one on every build) and `.claude.json` (a real file, seeded once). So a session gets an
isolated credential and loses **no** plugin, hook, skill, statusline or user-level `CLAUDE.md`.

`claude()` in `zsh/zshrc.herdr` now uses one by default, which is what finally moves the
seventeen shared-file processes counted above. It composes with the teammux launch because
`CLAUDE_CONFIG_DIR=<dir> claude` is a prefix assignment on a *function* call, and **zsh exports
those into the function's children** (`zsh -f -c 'f(){ printenv V; }; V=x f'` prints `x`) — the
single fact the whole path rests on, and not obvious. So **isolation no longer costs a team
lead**, and `hspawn`'s isolated path stopped running `clauth start` for the same reason.

```bash
claude                     # isolated onto the least-used profile, AND a team lead
claude-as quantivly-1      # the same, on a named account
CLAUDE_ISOLATION_OFF=1 …   # opt out; CLAUDE_ACCOUNT_PROFILE pins, CLAUDE_ACCOUNT_QUIET silences
```

Design points that are load-bearing rather than preferences:

- **The credential is a symlink, never a copy** — see the correction above. A copy is an
  independent holder of one grant, which is the failure this exists to remove rather than to
  manufacture. **CORRECTED 2026-09-08: the claim that followed here — "the symlink is written
  *through*, not replaced" — was FALSE, and it was never checked.** Claude Code writes
  `.credentials.json` **atomically** (temp file + rename), and a rename *replaces* a symlink with a
  real file holding the freshly rotated token. That much is survivable; what was not is what the
  builder then did with it. Its step 3 ran an unconditional `ln -sfn`, restoring the store's
  **superseded** token — and since rotation is server-side, that invalidated credential logged out
  every live session on the account. `claude()` runs the builder on **every** launch, so each new
  session on a profile re-armed the trap for the ones already running.
  Measured that morning: three of four account dirs held real, diverged files, `personal` was
  already quarantined by clauth as `auth_broken`, and every check on the machine was green.
  The builder now **reconciles** (`reconcile_credential`) instead of relinking: it decides which
  side is live from the `expiresAt` inside each file (falling back to mtime with no `jq`), adopts a
  session's rotation *into* the store, copies the loser aside first, and **refuses** when it cannot
  tell. A discovery stub — empty `accessToken`, no `expiresAt` — never counts as live. State table:
  `scripts/test-claude-account-dirs.sh` (156 checks at `6661472`, 9 mutants, all died), and
  `scripts/claude-account-dirs.sh --reconcile` is the same code path on a 2-minute
  `systemd --user` timer, because launch-time alone leaves the store stale between a rotation and
  the next launch — which is precisely how `personal` got quarantined.
  **The invariant, stated once: for each account there is exactly ONE credential file, and every
  process using that account reads it.** `claude-doctor`'s "Account dirs" section asserts it, along
  with the pooled-sharing one below.
  **A LOCK IS A WRITE, and this one landed where nothing could be reconciled.**
  `exec {fd}>"$pdir/.reconcile.lock"` *creates* that file, and it was created before anything
  established that `$pdir` is a real profile store — so an empty directory under
  `~/.clauth/profiles/` collected a 0-byte `.reconcile.lock`, again on every timer tick, two minutes
  apart, forever. **Not "every" such directory**, which this file claimed on first writing and no run
  supports: `reconcile_all` iterates *account dirs* and reconciles a profile only where a matching one
  exists, so a store with no account dir is never visited and never got a lock — measured against the
  pre-fix script, and the tell is that the row covering it has to `mkdir` both to reach the path.
  There is effectively nothing to serialise in that state: the locked function's second
  test is `[[ ! -f "$S" ]]` and it refuses immediately with `refused-no-store`. **"Effectively", not
  "pure side effect"** — that stronger claim is untrue, and a weak justification is how a correct
  change gets reverted: the refusal path still calls `cred_write_verdict`, which truncates and
  rewrites `.reconcile-status`, and the lock *was* serialising that. What makes dropping it safe is
  the absence of a CONTENDER — the only concurrent writers are timer-vs-timer, and a systemd
  `oneshot` does not overlap itself. During a profile rename the cost compounds — each stage leaves a compat symlink at the
  old account-dir path, the reconciler visits it, and the lock reappears at exactly the store name
  the NEXT stage needs free, so the migration stalls on the reconciler's own leftovers and has to
  sweep them before every stage. The gate is `credentials.json` present, which is the same
  "is this a launchable profile" test `--all` already uses — no new notion of what a profile is, and
  no TOML parser, both deliberate. **It was written as `-f` OR `-L`** on the reasoning that a
  dangling store credential had to keep reaching the diagnosis that names it; a mutant proved that
  false and the `-L` was removed. The gate only decides whether to LOCK:
  `_reconcile_credential_locked` runs either way, and its first test reports
  `the clauth store credential is itself a symlink` and returns without writing. A branch whose only
  mutant cannot die reads as coverage, so it went.
  **The remedy text was part of the loop.** The refusal said `Run 'clauth login <p>'`, and following
  that during a rename is what *materialises* the store at a name the migration needs free. It now
  says so: `clauth login` if it should be a profile, otherwise remove the empty store dir, because
  `clauth login` would make the name real again.
  **And the stated cause was wrong, which is why it is written down.** The phantom directories were
  attributed to `reconcile_all` creating them, and `reconcile_all` has always guarded on
  `[[ -d "$PROFILES_DIR/$profile" ]]` — measured: an orphaned account dir, and a compat-symlink one,
  each create nothing. What this code does is *write into* a phantom somebody else created, on every
  tick. Rows now pin both halves, because the honest diagnosis is the one that stays true: the
  "creates nothing" rows pass today and exist so they keep passing.
  Two bugs inside the fix, both of which reported success: `exec {fd}>file 2>/dev/null` has **no
  command**, so *both* redirections applied to the shell permanently and the script's own stderr
  went to `/dev/null` for the rest of the run — every later `warn()` and `die()` silently lost, in
  the file whose whole purpose is to say what it did to a credential. And `cond && cmd` as a bare
  statement is a *failing command* when `cond` is false, which under `set -e` exits the script with
  no message at all (the SC2015 class this file already records twice).

  **An adversarial review then found six more that DESTROYED a credential while reporting success,
  and the first is the one to remember.** The decision function ranked on `expiresAt` alone and
  never looked at `accessToken` — but this file's own discriminator for an interleaved write is
  that the victim *keeps* its `expiresAt` and `scope` and *loses* its `accessToken`. So the victim
  of a lost race outranked the credential that still worked, and adopting it copied an **empty
  token over a good one**, after which clauth polls with nothing and quarantines the account: the
  exact outcome the whole change exists to prevent. Reproduced, then fixed by requiring a non-empty
  `accessToken` before a file counts as live at all. The lesson generalises past this file: **a
  freshness signal is not an aliveness signal**, and ranking on the one while meaning the other is
  how a broken thing wins.
  The other five, each now a state-table row and a dead mutant: an **equal** expiry with different
  content was "resolved" by discarding the account dir's file, silently dropping the `mcpOAuth`
  logins it had gained (one browser OAuth flow per server per profile, every time the timer ran) —
  identical logins now adopt rather than discard; a non-integer expiry made `(( ea > es ))` a bash
  **arithmetic error** whose failure read as a decision; **UNKNOWN on one side** handed the other a
  confident win, because "does not parse" and "parses but is unusable" had been collapsed into one
  return code — they are now distinct, and either side being unreadable is a refusal; `cred_backup`
  used **`cp -p`**, stamping the *source's* mtime on the backup while the prune ranked by mtime, so
  the call could delete the copy it had just made and still return its path — the only safety net
  under every decision above; and `cred_relink`'s status was discarded at all four call sites next
  to a bare `ln -s`, so an unwritable account dir yielded **exit 0 with no credential**, which
  Claude Code answers by writing a fresh independent login — manufacturing the very independent
  holder the design forbids.
  Three more from the same review that were not credential-destroying but were the familiar shapes:
  the `auth_broken` exclusion matched a **single line** while clauth already writes `profiles = [`
  multi-line in that same file with the same writer (the `fallback_chain` recurrence — a `sed`
  range fixes it, again); the new doctor section made **the machine's ordinary post-refresh state a
  ✗**, three lines above its own note calling that state expected — the permanently-red checker,
  **fifth** recurrence, now a ⚠; and `--reconcile` returned non-zero for states only a human can
  resolve, which as a 2-minute `oneshot` is a unit that fails 720 times a day forever. A timer's
  `ExecStart` must distinguish "I could not decide" from "the machine is broken", and only the
  second deserves a failed unit. Also: **`<->` is a zsh numeric glob and a syntax error in bash** —
  `bash -n` caught it, which is the argument for running the checker rather than reading it.
  And the review's own design finding, taken: when every pool member is excluded the picker used to
  fall through to the **shared** credential — but exclusions correlate with load, so that path was
  rare in calm weather and concentrated in bad, which is the opposite of a safe degradation. It now
  falls back to an *account* (clauth's active profile, isolated) and reserves the shared file for an
  explicit `CLAUDE_ISOLATION_OFF=1`.

  **A second review round found more than the first, and the framing is the part to keep: the
  decision function implemented ONE QUARTER of the upstream one.** clauth's `try_adopt_live_rotation`
  gates an adopt on four things — a refresh token present, both expiries present, live > stored
  **strictly**, and identity **proven** — and refuses on any. This kept the expiry comparison and
  turned its *refusal* case into a destructive relink: on a tie upstream does nothing, where this
  relinked and discarded. When mirroring a tool's mechanism, mirror its **refusals**, not just its
  happy path — they are most of what the mechanism is.
  What that omission cost, all reproduced: a `/login` as a **different account** inside an isolated
  session was adopted into the wrong profile's store on the strength of a later expiry (this machine's
  journal holds 8 upstream refusals of exactly that event), which bills the wrong account, poisons
  that profile's usage numbers so the picker ranks on them, and would be installed machine-wide by
  `clauth <profile>` — while the new doctor printed **✓** for it, because it compared paths and never
  identity. Fixed with a **rotation-shape gate**: adopt only when the two files differ in the fields a
  refresh rewrites, refuse everything else by name. Be honest about its strength — measured here it
  separates `personal` from the work accounts and `quantivly-3` from the other two, but `quantivly-1`
  and `quantivly-2` carry an identical residual, so it is a filter, not a proof.
  **And the store was written holding only OUR lock.** clauth serialises every credential write on
  `~/.clauth/.lock` (`runtime.rs:3095` carries a `debug_assert` demanding it), so an adopt could land
  on top of a rotation clauth had just performed and restore the pre-rotation token — the original
  logout bug, re-created from the other end of the same pipe. Take the other tool's lock, not only
  your own, whenever you write a file it owns.
  The **mcpOAuth union** mattered more than it looked: `quantivly-3`'s store held *zero* MCP logins
  against one in its account dir, so whichever side happened to rotate last decided whether they
  survived — twice an hour per profile once the timer runs, at a browser OAuth flow each to get back.
  Merging both sides means there is no losing side at all, which also makes the tie harmless rather
  than destructive.

  **Five mutants survived, and every one was a row that could not fail** — the class this file
  already warns about, met five times in one change. Worth the pattern rather than the list: a
  fixture that does not reach the branch (`expiresAt: 1.5e12` renders as an integer, so the
  non-integer guard was never entered); a fixture below the threshold (six backups were needed to
  reach a prune that only runs past five — and giving all six the *same* ancient mtime made the
  prune's choice arbitrary rather than wrong, so the count matched either way); a row whose failure
  came from somewhere else (an unwritable dir failed on `settings.json` first, so the link guard was
  never exercised — `--reconcile` writes no settings, which is the path that isolates it); and a row
  testing the wrong side (the MCP union only matters when the side WITHOUT the logins wins, so a
  fixture where the MCP-bearing side won proved nothing). **Ask of every new row: what single change
  to the code would make this fail? If the answer is "none", the row is decoration.**
  One survivor was not a missing pin but genuinely unreachable code: the shape gate now refuses an
  unparseable file before the decision function sees it, so that function's own UNKNOWN branch cannot
  be entered. It is kept as defence in depth and the mutant retired, with both facts written down —
  a mutant that can never die is worse than no mutant, because it reads as coverage.
  A fixture bug worth its own line: one row wrote **through** the credential symlink with `>` and so
  clobbered the store instead of creating the real file it meant to test. Claude Code's atomic rename
  *replaces* a symlink; a shell redirect follows it. The code was right and the test was wrong, which
  is the harder direction to spot.

  **clauth's store keeps 5 of the 7 keys Claude Code writes, and its own writes DESTROY the other
  two — plus every MCP login.** Read out of clauth's source (on disk at
  `~/.config/herdr/plugins/github/clauth-4596d4a41686`, commit `ff25762`):
  `profile.rs:2236 serialize_credentials_preserving_extra` serialises a typed `ClaudeCredentials`,
  then `preserve_extra_blocks` (`:2251`) re-attaches every top-level block the existing file has
  **except** `claudeAiOauth` — an explicit `if key == "claudeAiOauth" { continue; }`. So siblings
  survive and any SUBKEY clauth does not model is dropped; `rateLimitTier` appears nowhere in its
  source. The doc comment justifying the sibling rule says *"Dropping it here would lose data no
  other writer holds"*, and does not apply that argument one level down.
  Measured live on 2026-09-08: with the daemon running, all four profile stores were rewritten
  within ~20 minutes (staggered, matching the 90 s poll) and lost **both** `rateLimitTier` **and
  every `mcpOAuth` entry** — 2/3/3/1 logins to zero. The shape is the discriminator and it is not
  ambiguous: the reconciler here unions `mcpOAuth` and always writes it, so a 509-byte five-key
  file with no siblings can only be clauth's serializer. Recoverable from
  `~/.cache/cred-backup-*/account-dirs/*` and the `.superseded-*` copies.

  **CORRECTED 2026-09-14, twice — and the second correction retracts the first, which had
  retracted too much.** This entry said *"The clauth daemon is paused
  (`systemctl --user stop|disable clauth-daemon.service`) pending an upstream fix"*. It has
  been running since **2026-09-10 16:13:52**. A first correction then generalised from four
  quiet days to "the loss is not reproducing", which is wrong in both directions:

  - **The `mcpOAuth` half was a VERSION change, not a behaviour that stopped, and it was
    already measured.** The binary at `~/.local/bin/clauth` was replaced **2026-09-08 20:58**,
    *after* the 09-08 measurement window above (its `cred-backup` dirs are 10:35 and 20:44).
    A hermetic fixture on 09-09 had already established the rule: `rateLimitTier`,
    `refreshTokenExpiresAt` and `clientId` are dropped by **0.14.1 and 0.15.1 alike**, and
    0.15.1 fixed only the SIBLING case (`mcpOAuth`, which 0.14.1 destroyed on every write).
    So the 09-08 loss was 0.14.1's. "The serializer was not re-read" was itself false.
  - **The subkey half never stopped, and is measurable right now.** No live credential on
    this machine carries `rateLimitTier` or `refreshTokenExpiresAt` — all five clauth stores
    and all seven account-dir credentials are the 5-key set
    `{accessToken, expiresAt, refreshToken, scopes, subscriptionType}`. The last file
    carrying the 7-key shape is `quantivly-3/credentials.json.superseded-20260910-094338`.

  The one thing the four quiet days do support is narrow and worth keeping: the shape test
  this paragraph names — a ~509-byte five-key file with no siblings — appears **exactly once**
  across 25 superseded copies (`quantivly-3/…-20260909-101756`) and never after the upgrade.
  **A window of no evidence is not evidence, unless you can say what would have shown up in
  it**; here that shape is what would have, so the absence counts. Generalising past it to
  "the loss" did not.

  **CORRECTED 2026-09-08, hours after it shipped: `rateLimitTier` does NOT cause the "Fable ·
  Requires usage credits" banner, and the commit message of #123 says it does.** That claim was
  written from a measured correlation (clauth's store lacks the field) plus a teammate's report,
  and was never tested. A peer session read the Claude Code bundle (2.1.263) and closed the path:
  the suffix comes from `sxe()`, gated on `EF()` and `OW()`; the only tier-dependent arm of `EF()`
  tests `rateLimitTier === "default_claude_zero"`, which a real tier string is not — so the
  field's ABSENCE cannot flip it. The credits state is a server-set latch
  (`fableCreditsRequired()`) plus gates keyed on `subscriptionType`, which clauth preserves; where
  the tier IS read for entitlement there is a network fallback to `organization.rate_limit_tier`,
  so losing it costs a round-trip, not the entitlement.
  **The teammate's A/B cannot isolate credential contents**: a clauth switch changes the ACCOUNT as
  well as the file, so it has two variables, and what it isolates is which account. Two lessons,
  both cheap to state and expensive to relearn: a correlation plus a plausible mechanism is not a
  cause; and an untested causal claim in a COMMIT MESSAGE outlives the mistake, because a squash
  merge makes it the permanent record — this one had to be corrected by a follow-up commit rather
  than an amend, since #123 had already landed.

  **SECOND RECURRENCE, 2026-09-17, and this time the commit message WAS the payload (#152).**
  That PR existed to retract a claim about who owns `~/.claude/.credentials.json`, spent six
  commits doing it, and then merged as `23d588e` carrying the retracted claim as its **title** —
  over a body that calls the restored, true sentence "wrong". Nobody wrote that message:
  **`gh pr merge --squash` composes the commit from the PR's title and body**, and neither had
  been touched since the first commit, so the squash published the PR's opening position as the
  permanent record of its conclusion. `git log --grep nanoclaw` on `main` now shows a false claim
  as the headline of the commit that disproves it. The rule is mechanical rather than a matter of
  care: **before a squash merge, read the PR title and body as the commit message they are about
  to become**, and on any PR whose content changed during review, rewrite them first —
  `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -F body=@file -f title='…'`, because `gh pr
  edit` is refused here by a Projects-classic GraphQL error. Afterwards there is no good remedy:
  the commit is on a protected branch, so it is a correction header on the PR page (where a
  reader arriving from `(#152)` lands) plus a follow-up like this one. **Reviewing the diff is
  not reviewing the merge** — this one was merged by a session that had read the #123 lesson
  above in the same sitting, and checked the file content on `main` afterwards but not the
  message.

  **A sixth survivor was a row that passed because the TEST raced, not because the fix was missing.**
  Both lock rows started a background holder and then `sleep 0.4` before measuring — and on a loaded
  machine, which a mutation run guarantees, the holder had sometimes not acquired yet, so the
  reconcile took the lock uncontended, returned fast, and the row passed with the locking removed.
  Run alone it pinned its fix perfectly; run under load it pinned nothing, which is the worst of both
  (it looks like coverage and reports green exactly when the suite is working hardest). The holder now
  **signals** that it holds the lock and the row waits for the signal. **A timing-based row is a
  probabilistic row unless something synchronises it** — and its flakiness will show up first in
  mutation testing, where the machine is busiest, not in the clean single run you wrote it against.
- **Everything except the credential is SHARED, and that is the point of a pool.** Each account dir
  symlinks `projects/` (so memory and every transcript), `plugins/`, `skills/`, `hooks/`, `teams/`,
  `tasks/` and the user-level `CLAUDE.md` back to `~/.claude/`, derived from the live directory
  rather than a list. So accounts in a pool share memory, plugin configuration and skills; only the
  identity differs. `claude-doctor` asserts it per account dir, because nothing about a session
  reveals that it has quietly stopped sharing.
  The one genuine exception is **plugin MCP OAuth**: `mcpOAuth` lives *inside* `.credentials.json`,
  so it is per-account by construction and each profile needs its own browser flow per plugin MCP
  server. The **claude.ai connectors** for the same services ride the login token and need no such
  entry, which is why retiring the duplicated plugin copies makes the per-profile MCP cost zero.

- **`settings.json` is a copy, not a symlink.** clauth rewrites the global file's `env` and
  `[models]` on a profile switch (which is how `model` came to be `null` there), and a symlink
  would import that churn into every account dir. A persistent dir has no fresh-launch moment to
  re-snapshot at, so the builder is that moment and says when the copy had drifted.
- **`.claude.json` is seeded from `~/.claude.json`, NOT `~/.claude/.claude.json`.** Claude Code
  keeps it in `$HOME` and only moves it under `CLAUDE_CONFIG_DIR` when that is set. On this
  machine `~/.claude/.claude.json` is a **1,156-byte husk** with `projects: {}`, no
  `hasCompletedOnboarding` and a *different* `machineID`, untouched since 2026-08-28, while
  `~/.claude.json` is 95 kB with 21 projects and matches what clauth seeds. Seeding from the husk
  gives every account dir first-run onboarding and a trust dialog in every worktree — silently,
  because a husk is still valid JSON. An implausibly small seed is a hard error for that reason.
- **The default profile is the pool member with the most HEADROOM, not `clauth which`.** That call
  answers from `$CLAUDE_CONFIG_DIR`, so **inside an isolated pane it returns the parent session's
  profile** — measured, it names the parent session's profile in an isolated shell and `unknown` in
  a bare one. Defaulting to it puts every spawn in its parent's credential group, which is the
  concentration being undone.
  **`CLAUDE_ACCOUNT_POOL` is the pool** (set it in `~/.zshrc.local`; empty = every registered
  profile, which is what a one-account adopter wants). A profile outside it is never chosen
  automatically — only by name with `claude-as` — which is how a personal account stops being spent
  by a work session that merely happened to start next.
  Ranked by a **score** over 5h headroom, use-it-or-lose-it timing, weekly headroom as a multiplier
  and crowding, with eligibility classes and a round-robin ledger — see "The smart account picker"
  below. It was the worse of the 5h and 7d utilization then live holders then name until DO-574,
  which could not distinguish an account at 3% of a window resetting in four minutes from one at 20%
  with the whole window ahead of it. A reading that is missing or older than
  `CLAUDE_PICK_CACHE_MAX_AGE` (3600 s) is class `unknown` and ranks after **every** measured
  candidate — unknown must not outrank a measured 0%.
  **Accounts clauth has excluded are skipped, and this is not cosmetic.** `disabled` comes from the
  profile's `config.toml`, `auth_broken` from clauth's own quarantine list. Until 2026-09-08 the
  picker ranked on holder count alone and chose `personal` — *because* it was quarantined and so had
  nothing running on it. **The emptiness that a quarantine causes read as headroom.** A quarantined
  account also stops being polled, so its usage numbers freeze at whatever they were (`personal`'s
  were 21.7 h stale when this was found), which is why a stale reading can never be believed.
  Holders are still counted from pidfiles under `<dir>/holders/`, pruned by `kill -0` as they are
  counted; `claude()` blocks for the session, so the shell's pid stands in for it.
  **The picker sets `REPLY` and must be called DIRECTLY.** A `$(...)` call is a subshell, and the
  two globals it reports through — the load that won, and every account it refused — would die with
  it, leaving the announcement silent in exactly the case it exists for. It printed to stdout at
  first, and did. Also `${${(o)arr}[1]}` **joins the array into one scalar and indexes its first
  CHARACTER**: it returned `0` from the zero-padded sort key, and the picker silently chose nothing.
- **Credential groups can only equal logins.** Four profiles against 18–30 sessions gives groups
  of five to seven; `clauth login <name>` is what makes them smaller. Whether two logins can hold
  *the same* account independently is **observed, not yet tested**: everything below happened to
  two grants that already existed, and no `/login` was performed to see what a *new* authorisation
  does to an old one. That is the experiment still owed, and it wants a non-preferred profile and
  nothing in flight.
  What is observed, both directions, on `quantivly-0` (one login on the laptop, one on dev):
  dev's login is from 09-15 and the laptop's grant **re-issued on 09-19 12:02Z** without it
  breaking; the laptop's grant polled continuously on 09-18 (944 polls) while dev's refreshed at
  05:54Z; and on 09-20 dev served a live `claude -p` from its own grant at 09:13:26Z (DO-640 Task
  B3, PR #181) while this laptop's `~/.clauth/status.json` still reported `auth_status=ok` for the
  same account, with no `auth_broken` entry in `profiles.toml`. Neither side has knocked the other
  out in five days of overlap. Note what that evidence is NOT: `fetch_status`/`fetched_at` are
  clauth's usage-poll state, not proof of a live credential, and an access token minted before a
  refresh stays valid for its 8 h regardless. `auth_status` is firmer but is poll-derived too — a
  401 on a poll is what sets `auth_broken` — so it means "no poll has failed", not "the credential
  is live". The load-bearing observation is the RE-ISSUE: a grant that rotated after the other
  machine's login is one the other login did not revoke.
  If it holds, each `/login` is an independent grant and groups shrink without new accounts; if it
  does not, a second authorisation may revoke the first and log out every holder.
  Either way this says nothing about window ACCOUNTING: each machine's spend stays invisible to the
  other's picker. That is why `CLAUDE_TENANT_MACHINE_OWNED` (DO-641) refuses only LAUNCHES on another
  machine's profile, never the login — the laptop's grant is how it sees that seat's window.
- **`preferred = true` on `quantivly-3` should be REMOVED — corrected 2026-09-09.** This line
  previously read "stays", on the reasoning that once nothing reads the global credential the
  daemon's walk-back rewrites a file with no readers. That argument only holds while **both** halves
  stay true, and it quietly depends on the more fragile one. Per-session placement makes a "home"
  account meaningless in the first place, and the flag is inert **only** while the daemon is
  disabled — so the day the daemon is re-enabled (after its serializer is fixed upstream, which is
  the plan) it starts walking the machine-global credential back to one account underneath every
  session still on the shared file, with nothing announcing it. A setting whose safety rests on
  another component staying broken is not a setting to keep. **DONE, verified 2026-09-14**: no live profile
  `config.toml` carries it, and it survives only in
  `~/.clauth/profiles/quantivly-3/config.toml.bak-preferred` (2026-09-10), clauth's own backup of
  the edit. The line this replaces — *"Verified 2026-09-09: it is still present … the removal is
  pending, not done"* — was true when written and stale within a day. That is an argument for
  re-measuring a state claim before repeating it, not for writing fewer of them.
- **`zsh/zshrc.herdr` is portable**, so the whole block is gated on clauth *and* the builder both
  being present, and the fallback is the previous behaviour byte for byte. A modular adopter with
  neither sees no change, and a state-table row asserts it.

Traps specific to the checker, each of which produced a green tick first:

- **THE SECTION FIXED THIS ONE AXIS OVER AND LEFT THE OTHER — and then the fix for
  THAT fixed one axis and left another, which is the part worth keeping.** The clauth
  block's header says everything in it is about the GLOBAL file, and
  `_claude_global_cred_file` exists because writing these checks against
  `_claude_cred_file` made them silently stop working once #107 made isolation the
  default. The credential FILE was fixed then; the active PROFILE was not.
  `clauth which` answers from `$CLAUDE_CONFIG_DIR`, so in an isolated session — very
  nearly every session now — it returns THAT session's profile. Measured 2026-09-14:
  `personal-1` machine-wide, `quantivly-0` from a session isolated onto quantivly-0.
  It is not one wrong line, because `$active` feeds the two comparisons below it: the
  doctor then reported `stored copy of 'quantivly-0' DIFFERS from the live credential`
  and `the live credential belongs to 'personal-1', but the active profile is
  'quantivly-0'` — two confident warnings about a healthy machine.

  **The first fix cleared the environment and was still wrong, because `clauth which`
  answers a different question entirely.** Its own help says so — *"Print the profile
  owning the loaded .credentials.json … CLAUDE_CONFIG_DIR-aware; prints `unknown` when
  nothing matches"* — that is credential OWNERSHIP, not selection, and measured against
  0.15.1 it matches on the **refreshToken alone**: with `active_profile = "B"`
  configured and the global credential equal to A's store, it answers `A`
  (`accessToken` and `expiresAt` varied independently, both irrelevant). So with the
  environment cleared it returns exactly what `_claude_cred_owner` computes from the
  same file, and the two consumers collapse: `the live credential belongs to X, but the
  active profile is Y` **can never fire** (`which`=P ⟹ P's store shares the refresh
  token; `_claude_cred_owner`=Q ⟹ the whole triple matches Q, so its refresh token does
  too, so P=Q — and when `which` says `unknown`, no store's refresh token matches, so
  the triple cannot either and the orphan branch runs instead), while
  `stored copy of 'X' matches` compares a file with itself whenever the global path is a
  symlink into a store, **which on this machine it now is**. Demonstrated end to end
  against the real binary: declared active `p1`, global credential owned by `p2` → the
  cleared-environment version prints `active profile: p2`, a ✓, and nothing else. Worse
  than the bug it replaced in that one state, where the pre-fix isolated shell had been
  right.

  **The source is clauth's CONFIG, and which config file is not arbitrary.**
  `active_profile` lives in `profiles.toml` as part of clauth's config state, written by
  the switch primitive under the config lock (`profile.rs` `LockedSlot`,
  `actions.rs` "switch primitive that can write `active_profile`"); `status.json` is the
  **daemon's published feed** of the same value, and clauth's own TUI has a notion of it
  being stale ("wedging / pre-abort / just booted"). So config first, feed second, and a
  stopped daemon cannot make the doctor name the wrong account. It is also forkless, and
  it retires the `unknown` sentinel along with the call that produced it.

  **The state table could not see any of it, twice over, and the second blindness was
  built by the first fix.** The `clauth` stub answered `which` identically with and
  without `CLAUDE_CONFIG_DIR`, so every isolated-session row got the right answer for
  the wrong reason. Teaching the stub that one behaviour let three new rows fail — and
  left the stub answering a question the real command does not, so the row asserting the
  misattribution warning passed against a report production could no longer emit. **A
  stub is a claim about the real thing, and a row over a stub is only as true as that
  claim.** There is no `which` handler now: the doctor must not shell out to clauth for
  this at all, and the recording stub's log staying EMPTY is itself an assertion, because
  no assertion on the report can tell "read the config" from "asked the binary and the
  binary happened to agree".

- **A HASH OF NOTHING IS A HASH, and it matches every other hash of nothing.**
  `_claude_cred_id` piped `jq` straight into `sha256sum`, so a parse failure hashed
  jq's *empty* output — the constant `e3b0c442…`. Two unreadable credential files
  therefore had the same id and "matched", printing `✓ stored copy matches —
  switching away and back is safe` across two corrupt files, and making all three
  of the function's own `NOT CHECKED` branches dead code. Its doc comment
  ("empty output means could not read it") was false. A file that parses but has
  no `claudeAiOauth` was the same bug one level up: `{accessToken:null,…}` is also
  a constant. **Check the exit status, never the emptiness of a pipeline's output**
  — `jq -e`, and a `select(. != null)` so a missing block produces none. This
  survived 13 mutants because no row ever fed the comparison a broken file: a
  mutation suite only proves the rows it has.
- **Fixing a line-based match by removing the lines removes the bound as well.**
  `grep -oE 'fallback_chain[^]]*\]'` never fired against clauth's multi-line array,
  so the first fix flattened the file with `tr '\n' ' '` — and the pattern then ran
  from anywhere those words appear to the next `]` **anywhere in the file**. It
  reported an armed chain on a machine whose chain was commented out, and printed a
  neighbouring line verbatim into a report that lands in transcripts, in the file
  whose own header says NEVER PRINTS A CREDENTIAL. Also `fallback_chain = []` is
  configured, not armed.
  **CORRECTED 2026-09-17 — this entry used to end "A `sed` *range* from an anchored
  assignment to the first `]`, quitting there, is bounded by construction", and that
  is FALSE.** A range ends at the first LINE carrying `]`, so it is bounded to a line
  range and not to an assignment: on `fallback_chain = [` followed by
  `profiles = [ "p1", "p2", ]` it takes the other array's bracket and the `*'"'*`
  armed test passes on the other array's names. Measured, and it left the third fix to
  this one match printing the neighbouring line anyway. "Bounded by construction" was the
  sentence that made a fourth attempt necessary — and the fourth, interior validation, did
  not hold either: it checked the separators BETWEEN the names and never a name. What holds
  is the interior check PLUS a member class, the fifth attempt, recorded in "A standing
  `auth_broken` is reported" below. Naming only the interior check here, as this paragraph
  did until 2026-09-18, points the next reader at the same half-technique.
  **And do not read that as a description of this machine.** The chain here was
  `["quantivly-3","quantivly-1","quantivly-2"]` with a live daemon until 2026-09-08, while 15 of 21
  Claude processes had no `CLAUDE_CONFIG_DIR` at all and so read the very file the chain repoints —
  which is what a login-expiry incident hitting five sessions in the same minute looks like. It is
  empty now **by decision**: with every session placed on its own account dir at launch, an account
  is chosen where choosing is free, instead of being swapped underneath sessions already running.
  Per-session rotation is still available where it is actually wanted, via
  `clauth start <p> --with-fallback`, which moves that one session and touches no other.
- **Read the type before indexing — the second recurrence.** CLAUDE.md already
  records this for `herdr-claude-wire.sh` (`//` substitutes for null, never for a
  type error). An `mcpOAuth` value that is a string — a plausible product of the
  interleaved write this doctor hunts — made four `.mcpOAuth[$k].x` calls fail with
  `Cannot index string with string`, printed all four into the middle of the
  report, and then the empty captures read as a benign shape so the entry was
  *excused*. One `| type` check before the loop body, once.
- **`test -f` follows symlinks, so a dangling credential link is "no credential
  file".** It reported `not logged in — run /login` and sent the reader to
  re-authenticate instead of at the broken link; a deleted clauth profile leaving a
  live `clauth start` runtime dir behind is a real way to reach it.
- **The account-dir glob `*(N/)` matched no symlink, so a symlinked account dir was
  never checked at all — DO-604.** The `/` qualifier means "is a directory", and a
  symlink *to* one is not, unless `-` makes the qualifiers follow links
  (`mkdir real; ln -s real link` → `*(N/)` yields `real`, `*(N-/)` yields both).
  Not skipped, not reported: the whole section behaved as though such a dir did not
  exist, taking out its credential-mode, dangling-link, store-divergence,
  points-at-another-profile's-store and shared-subtree checks. Two existed on this
  machine (compat links from an in-progress profile rename), so `quantivly-1`'s
  credential had never been checked once. **`-/` is still not enough**: it follows
  the link, so a *dangling* one matches neither pattern — precisely the
  half-finished rename worth reporting — hence `*(N-/)` plus `*(N@)`, deduplicated.
  A symlinked dir is a **note** when it resolves to a registered profile and a ⚠
  naming the target when it does not, because a rename in progress is an expected
  state, not a fault; and the store is repointed at the target, or a compat link
  reads as "an account dir with no clauth profile store" and sends the reader to
  `clauth login` for a name that is deliberately no longer a profile.
  **`${x:A}` cannot name a dangling link's target** — it resolves only as far as the
  path exists and otherwise returns the link's own path, so the warning said
  "p9 is a symlink to …/p9". `zstat +link` reads the target itself and is a zsh
  *module*, not the `readlink` PATH dependency this file already records as having
  silently produced nothing here. Two of the five rows were decoration first: one
  asserted the output contained `p1`, which the backing dir `p1real` satisfies as a
  substring, and one used a fixture whose link target was not a registered profile,
  so the store-repoint branch it named never ran.
- **Widening an enumeration changes the checker's ADVICE, not just its coverage — and
  #132 applied that lesson to one input class and stopped one short.** It added a
  pre-classification branch so a *compat symlink* would not be told to
  `clauth login` a name deliberately no longer a profile; the store check below it
  remained the fall-through for **every** name, still assuming each one was a
  would-be profile. So a deliberately dot-prefixed archive directory read as "an
  account dir with no clauth profile store" and the reader was told to run
  `clauth login .personal.stray-20260910-112747`, which cannot succeed. Every
  enumeration needs a **total** classification: for each name it can see, either the
  remedy is actionable or the name is explicitly classified as not the checker's.
  Fixed with one shared `_claude_name_cannot_be_profile`, used by the account-dir
  and the profile-store enumerations, which had the identical fall-through.
  **The obvious fix is the wrong one.** Re-narrowing the glob would hide a
  dot-prefixed directory that HOLDS A CREDENTIAL — the blind spot the widening
  exists to close — so the enumeration stays wide and the classification gets
  wider: a credential under such a name is a ⚠ (nothing manages it, nothing rotates
  it), no credential is a note. The test is a **leading dot and nothing wider**;
  `[[ "$name" != [A-Za-z0-9]* ]]` also rejects `_weird` and `-dash`, which are
  unusual rather than impossible, and a checker that misfiles a real account dir as
  "not mine" reintroduces the blind spot from the other side.
- **DO NOT ASSUME A GLOB NARROWS, and do not let a checker's coverage depend on the
  caller's shell options.** `setopt GLOB_DOTS` is set repo-wide in `zshrc`, so
  `*(N/)` in this codebase has **never** excluded dotfiles — the first diagnosis of
  the defect above blamed #132 for widening the glob into dotfiles, and #132 had
  only added symlinks. The reverse also bit: because the state table runs `zsh -c`,
  where GLOB_DOTS is **off**, the dot-directory branch was unreachable from the
  suite, which is why #132's own rows could not catch any of this — and a modular
  adopter without this repo's `zshrc` had a doctor that silently skipped a
  dot-prefixed account dir holding a credential. Both globs now carry the `D`
  qualifier, which forces dotfile matching regardless of the option, and a row
  asserts the directory is seen with GLOB_DOTS **off** — the state the suite runs in.
  **The matching GLOB_DOTS-ON row was decoration and is gone**: with `D` present both
  states see it, and with `D` deleted the option itself still does, so the mutant
  dropping `D` failed the OFF row and left the ON row green. Its replacement — assert
  the entry is reported exactly ONCE, since `*(ND-/)` and `*(ND@)` overlap and only
  `${(u)...}` dedupes — was decoration too, measured: a plain directory matches only
  the first glob. The two overlap solely on a **symlink to a directory**, which `-`
  makes match both, so the once-ness row needs that fixture and now has it.
- **"IS THERE A CREDENTIAL HERE" CANNOT ANSWER WHAT TO SAY ABOUT ONE, and answering it
  with `[[ -e || -L ]]` produced advice that destroyed the thing it reported.** The
  designed shape of a per-account credential is a **symlink** into
  `~/.clauth/profiles/<p>/credentials.json` — the invariant stated above as *"the
  credential is a symlink, never a copy"* — so the presence test is true for the
  managed case. A dot-named archive holding that link was reported as *"not a profile
  name, but it holds a credential … an unmanaged copy of a login"* with the remedy
  *"move it into a real profile or shred it"*. Both claims are false for that input,
  and the remedy is destructive: **`shred` follows a symlink and overwrites the
  TARGET in place** — measured, the target file survives and its contents do not — so
  following the doctor's own advice logs out every session on that account, the
  outcome the account-dir design exists to prevent. `-L` folded in a **dangling** link
  as well, reporting "it holds a credential" about a link with no target, in the one
  state (a half-finished rename) the section exists to describe.
  `_claude_cred_shape` answers the real question in four states — `file` (the only
  unmanaged copy), `managed <profile>`, `dangling <path>`, `foreign <path>` — and
  **one helper serves both loops**, because the store-side comment already recorded
  why: *a fix that is right on one side of a report and wrong on the other is worse
  than one wrong on both, since the correct half is the reason nobody re-reads the
  other.*
  **CI was 22/22 green over all of it, and the reason is one grep:** every fixture in
  the section built the credential with `printf >`, so there was **no `ln -s` anywhere
  in it**. The rows exercised the exceptional shape and never the invariant one, in a
  check whose entire subject is whether a credential is managed. Each of the four
  shapes has a fixture now, on both sides. Found by an independent review pass, not by
  the author — the same shape as every other entry in this list.
- **"Order-independent" has to mean it, and locale collation differs between this box
  and CI.** A row asserting two names in one report line was written as the substring
  `no credential: realprofile` — which does not remove the ordering dependency, it
  pins the other order. zsh sorts that glob by the current locale's collation:
  `en_US.UTF-8` here yields `realprofile, _underscore`, and CI's `C` locale yields
  `_underscore, realprofile`, because `_` is 0x5F and `r` is 0x72. So the row passed
  locally and failed in CI, which is the "green here, red there" split the hspawn
  suite already records in the other direction. The fix is to extract the LINE and
  test each name in it independently; the verification is to run the suite once under
  `LC_ALL=C`, which reproduces the runner's collation in about the time one CI round
  trip costs.
- **zsh's `local NAME` re-declaration display, second recurrence — three lines from
  the comment forbidding it.** `claude-doctor` is one ~950-line function, zsh has no
  block scope, and its top declaration block says so explicitly ("every loop-body
  variable is declared once, here"). #132 then added `local pdir pname` 900 lines
  down, and because `pdir` already held a value the deployed doctor printed a bare
  `pdir=/home/…/.clauth/profiles/<alphabetically last profile>` onto stdout between
  two sections — loop residue from the `preferred` check 555 lines earlier. **And it
  was never confined to machines that have profiles:** on a modular-adopter fixture
  with no clauth, no `~/.clauth` and no credential at all, the same build prints
  `pdir=''` — an empty residue is still a bare `name=value` line in a report, and it
  is the machine class least likely to have anyone who would recognise it. Nothing
  in the repo echoes `pdir`. The row added for it is **generic**: it greps the
  report with `^[A-Za-z_][A-Za-z0-9_]*=` and fails on any bare `name=value` line, so
  it catches the next one whatever the variable is called — including the
  capitalised and digit-bearing names `^[a-z_]*=` would miss, which is what an
  earlier draft of this paragraph claimed it used. A convention stated in a comment
  is not enforcement; the row is — and neither is a comment *about* the row, so the
  pattern is quoted here exactly as the code spells it.
- **A fix that is right on ONE SIDE of a report is worse than one that is wrong on
  both.** The account-dir enumeration splits a name clauth cannot own into two cases
  — holds a credential (a ✗, because nothing rotates it) and does not (a note). The
  profile-store enumeration one block down tested the *name* and stopped, so a
  dot-named store holding a **live credential** was filed as benign archived state,
  as a note. That is the exact shape the wide enumeration exists to surface, caught
  on one side and mislabelled on the other — and the correct half is precisely why
  nobody re-reads the other. Found by independent review, not by the author.
  **The premise underneath is now VERIFIED rather than assumed, and two people got
  it wrong first.** Both a reviewer and the orchestrating session concluded clauth
  has no profile-name validation — the reviewer could not test it because doing so
  "means running a browser OAuth flow", and a source read found only `preserved`
  matching `reserved`. Both are wrong. `actions::validate_profile_name` rejects a
  leading dot outright, `cmd_login`'s `LoginRoute::New` arm calls it, and on the
  **installed 0.15.1 binary** `clauth login .dottest` exits
  `name: letters, digits and - _ . @ + only, and can't start with '.'` **before any
  browser opens** — so the test is free, and the control (an ordinary name) goes
  straight to the OAuth URL, which is what proves validation is the only thing in
  between. The greps that missed it are instructive: the function is named
  `validate_profile_name` but its message contains neither "profile" nor "invalid".
  So `clauth login <name>` genuinely cannot be offered as the remedy, which is what
  the new ✗ says. **The fix does not rest on the premise either way**, which is the
  point: it keys on the observable shape — a credential is present, or it is not —
  the same reasoning `2026-09-10`'s migration guard used, and it would still be
  right if the naming question were ever settled the other way.
- **A new external tool is a new way for a check to go quiet, twice in one day.**
  The `readlink -f` note below was written, and then an `awk`-based rewrite of the
  chain match reintroduced exactly the same failure — awk is not on the state
  table's from-scratch `PATH`, so the check silently produced nothing. Prefer a zsh
  builtin or a tool the file already uses.
- **A checker can go blind in the configuration the repo just made default, and this one did.**
  Run inside a `clauth start` session — what `hspawn` has used since #107 — `claude-doctor`
  reported `✗ mode 777` (`stat -c %a` does not dereference, so it read the *symlink's* mode
  against a target that was 600), three `✗ accessToken is EMPTY` against discovery stubs, a
  vacuous `✓ stored copy matches` (it compared the profile store with itself through the symlink),
  and it **missed** a genuinely orphaned global credential. Four wrong answers, no error, in the
  newest checker in the repo. The fixes: `stat -Lc`, the metadata discriminator above, and
  `_claude_global_cred_file` — every clauth check reads `~/.claude/.credentials.json` explicitly,
  because that is the file a switch overwrites regardless of where the shell running the doctor
  is pointed. **When adding a check, run it in both shells and diff the output.**
- **A check that cannot fire is indistinguishable from a healthy machine.** The "auto-switch armed
  … AND IS NOT LOGGED" note matched `fallback_chain[^]]*\]` with a line-based `grep -oE`, and
  clauth writes that array over several lines — so on the box it was written for it matched
  nothing, exited 1, and had never once printed. The suite's single-line fixture hid it exactly.
- **`clauth which` answers the literal string `unknown`**, a sentinel and not a profile name.
  Taken as one it produced "no stored credentials for 'unknown'", which reads like a missing file,
  and it skipped the `status.json` fallback that names the real active profile. **RETIRED
  2026-09-14 with the call that produced it** — the doctor reads `active_profile` out of clauth's
  config now (see the entry above), so no sentinel can arrive and the two rows that pinned this
  are gone rather than left passing over a branch nothing reaches. Recorded, not deleted: the
  sentinel is still real, and anything else here that learns to call `clauth which` inherits it.
- **Four legacy `~/.claude-*` config dirs still hold full credential files**, three written on
  2026-09-01 — four days after `zsh/zshrc.company` records that scheme as removed. Untracked
  logins and untracked rotation participants; nothing on the machine mentioned them until the
  doctor was taught to.
- **`readlink -f` is a dependency; `${path:A}` is not.** The state table builds a `PATH` from
  scratch, `readlink` was not on it, and path resolution silently returned nothing — degrading two
  findings on exactly the machines whose `PATH` is unusual. Same modifier the live-config guard
  uses in `zshrc`, and forkless.
- **A row that cannot reach the branch it names is unfailable.** The "absent log store is NOT
  CHECKED" row matched the bare string `NOT CHECKED`, which the *duplicated-services* section
  also prints — so it passed with the line it names replaced by a `✓`. Mutation testing found it;
  the row now matches that section's own wording.
- **A suite that inherits `$PATH` is not hermetic, whatever its header says.** The first draft's
  "clauth is absent" row found the **real** `~/.local/bin/clauth`. This box has one wired to a
  daemon owning four live accounts, and `clauth <profile>` rewrites the machine's credentials.
  The suite now builds its `PATH` from scratch and prepends a recording stub only when a row asks
  for it — the same rule as the `herdr` and `systemctl` stubs above.
- **A diagnostic that prints a credential is worse than no diagnostic.** `claude-doctor` reports
  lengths, expiries, presence and truncated hashes, never a token; a state-table row feeds it a
  canary secret and asserts the canary never reaches the output, on the success *and* failure
  paths. See "Keeping secrets out of transcripts".
- The `/login`-count metric **self-contaminates**: grepping transcripts for
  `<command-name>/login</command-name>` writes that string into the current transcript. Exclude
  the running session, or the number climbs as you measure it.

State tables, all in CI, all hermetic via a fixture `$HOME` and a from-scratch `PATH`:

- `scripts/test-claude-doctor.sh` (**279 checks at `6661472`** after DO-613's quarantine rows and the review fixes; 235 at `f07faae`;
  215 at `c839d48`, 218 at `62c83d3`, and it was written here as "103 checks" and
  had been stale for weeks — a figure without the commit it was measured at is the thing this
  file warns about two sections down, so these carry theirs. This one read "at the tip of
  `claude-doctor-active-profile`" for two days, which is the same defect wearing a branch name:
  the branch auto-deleted on merge and took the anchor with it. **A branch is not an anchor** —
  only a commit is, and a squash sha does not exist until after the body that would have cited
  it. So cite the merge commit in a follow-up rather than the branch in the original.)
  — `claude-doctor-test`, recording `clauth` stub,
  and a fixture process tree (`CLAUDE_DOCTOR_PROC_ROOT`) so the concurrency grouping can be pinned
  without depending on what happens to be running. 25 mutants, all died, plus **9 for the active
  profile, all died** — the last only after its row was rewritten: `:A` on a store path with no
  symlinked component is a no-op, so the fixture could not reach the branch it named and the
  mutant survived a 233-check green. Twelve of those rows
  exist only because a review found the fixes unpinned: the first pass shipped 13 mutants and a
  false green underneath them.
- `scripts/test-claude-account-dirs.sh` (**156 checks at `6661472`**; this line read 36, and 70 one
  section up, and both had been stale for weeks — `claude-account-dirs-test`) — the builder.
  10 mutants, all died, including "seed `.claude.json` from the husk" and "copy the credential
  instead of symlinking it".
- `scripts/test-hspawn.sh` (`hspawn-test`) — now also covers `claude()`/`claude-as`. Its count is
  owned by [HERDR_INTERNALS.md](HERDR_INTERNALS.md), not repeated here: this line said 269 while the
  suite ran 464, and two other pages carried two further wrong numbers (DO-701).
  Two leaks found while writing those rows, both the same class and both worth remembering: the
  suite inherited **`CLAUDE_CONFIG_DIR`** from the developer's own isolated session, so every
  isolation row took the "already placed" branch and asserted nothing; and it inherited
  **`HERDR_PANE_ID`**, so rows written for the plain `command claude` path all took the herdmates
  branch instead. Both shapes pass on CI and fail on the machine — the least useful way round.

```bash
claude-doctor              # auth + MCP health, from the log store
claude-doctor --all        # include the servers that are fine
claude-doctor --days 30    # widen the MCP window
```

**clauth silently removes keys from `~/.claude/settings.json`, and that file is not in this
repo.** It merges a profile's `[env]` on switch and clears it on switch away (which is why `env`
is `{}`), and it writes the profile's `[models]` block — on 2026-09-06 that removed
`model: opus[1m]` outright, so every new session defaulted to a different model for a day before
anyone noticed. The same file carries the statusLine publisher, the secret-emission guard hook
and 23 enabled plugins, so a key vanishing from it is not cosmetic.

It is deliberately **not** dotbot-managed: a symlink would make clauth write through it on every
profile switch, i.e. a permanently dirty tracked file — the churn `DOTFILES_EXPECTED_DIRTY` exists
to paper over elsewhere. `claude-doctor` detects the damage instead of fighting for ownership of
the file, the same choice it already makes about the credential. The check reads the **global**
settings.json, never `$CLAUDE_CONFIG_DIR`'s: `clauth start` gives its runtime its own real
settings.json, so a check written against the session would read a copy and miss the global losing
a key — the defect #109 fixed for credentials, one file over.

Silent by default, because a hardcoded list of required keys is a permanently-red check on any
machine that legitimately sets none of them. Unarmed it still *prints* `model`, `statusLine.command`
and the plugin/hook counts, so a removal is visible without being an alarm. Arm it in
`~/.zshrc.local` with the keys you actually care about — jq paths, tested for present-and-non-empty:

```zsh
CLAUDE_SETTINGS_REQUIRE=( model statusLine.command )
```

Operational half — the connector cleanup that has to be done at claude.ai, what each finding
means, and how to revive a dead stdio server: [docs/CLAUDE_ACCOUNT_MCP.md](CLAUDE_ACCOUNT_MCP.md).

Which plugins are enabled at user scope and which are per-project — the two stdio MCP
servers cost a forked process per session, and neither settings file is in this repo, so that
page is the only record: [docs/CLAUDE_SETUP.md](CLAUDE_SETUP.md).

### A long suspend expires every account at once (2026-09-14)

**Three accounts needed `clauth login` on the morning of 09-14, and the cause was a laptop
suspend.** Access tokens live **28800 s — 8 h** (measured), so a long enough suspend takes every
account past its expiry while nothing is running, and on resume ~21 sessions and the clauth daemon
all have to refresh inside the same two minutes.

**State it as the measured expiries, not as a duration threshold.** The first version of this
section said "a suspend longer than 5 h", which was built on a wrong lifetime (correction below)
and was the weaker claim regardless: what decides it is how much validity a token had LEFT when the
machine went down. Both storms are confirmed directly from the `expiresAt` inside the superseded
copies the reconciler kept:

| suspend | the tokens' own expiry | storm |
|---|---|---|
| 09-12 11:27:48 → 18:39:19 (7.2 h) | 16:55:28 – 17:47:28 — during it | 4 accounts, 18:40:26/27 |
| 09-14 00:04:19 → 08:27:19 (8.4 h) | 01:55:52 – 01:59:39 — during it | 4 accounts, 08:29:28 |

The other eight suspends since the reconciler landed on 09-08 were all ≤ 1 h 32 m and produced
none. (That bound is the measurement, not a round number: the longest of them, 09-09 10:45:57 →
12:17:27, is 1 h 31 m 30 s — an earlier draft said "≤ 1.5 h", which it exceeds by ninety seconds.)
Note what the 09-12 row shows: a **7.2 h suspend spanned an 8 h lifetime**, because those tokens
were already ~2.5 h old when the machine went down. clauth refreshes near expiry, not continuously,
so "suspend duration vs token lifetime" is not the rule and never was.

**CORRECTED 2026-09-14, within hours of writing it, by a mechanism this file already records.**
The lifetime above first went in as "18000 s — 5 h exactly". It is 28800 s. The error came from
`jq`'s `mktime`, which reads a broken-down time as **UTC**, applied to an `mtime` string that is
**local** — so every computed difference was short by exactly the UTC+3 offset. This file already
carries the mirror of it for `_claude_ts_delta`, where `strftime -r` parses through the same
`mktime`. Two things let it survive: 18000 s is a real and very nearby number on this machine — the
**5-hour rate-limit window** `r5` measures — so it read as familiar; and the table that carried the
error also carried its own refutation, printing `written 09:42:41` next to `expires 17:42:40` on
the same row. **A derived column that disagrees with the raw columns beside it is the cheapest
defect there is to catch, and it was still missed.** Compute a delta in one place, in a language
whose parser you have checked, and print the raw values next to it so the contradiction is visible.

**What breaks is clauth's view of the accounts, not the sessions**, which is why it looks like a
credential disaster and reads like nothing in the transcripts. Zero `isApiErrorMessage` login
expiries across **1,431 transcripts and 868,562 records with 0 unparsable** for 09-11..09-14 (last
genuine one: 2026-09-10T08:10:52Z) — the unparsable count is reported because an empty answer from
a scanner that silently skipped half its input is not agreement — and
no session ever reported one. **clauth, however, DID quarantine all three accounts — see
"CORRECTED 2026-09-16 (second)" below, which retracts this paragraph's original claim that
`clauth.log` proved it had not.** What actually
degraded was clauth's per-profile polling: normal cadence ~59 s (mean gap; note that gaps of
873–879 s occur in ordinary operation too, so one ~880 s gap is not by itself a fault signal),
and the three broken accounts fell to one success per **~1010 s**.

That figure reproduces exactly, and saying where the last 20 s come from matters, because
otherwise the next reader computes 90 + 900 = 990, sees 1010, and concludes the mechanism is
wrong. **The 900 s is `auth_broken`'s flat widen, NOT the `rate_limit_backoff_ms` ladder** — this
paragraph said the ladder until 2026-09-17, and that was refuted by reading v0.15.1 rather than the
0.14.1 checkout: `poll_backoff_ms` (`scheduler.rs:304` at v0.15.1) returns
`AUTH_BROKEN_BACKOFF_MS` on its FIRST line when the flag is set, so for a quarantined profile the
ladder branch below it is unreachable. Both constants happen to be 900 s, which is why the
arithmetic never looked wrong. The **shape** is what separates them: the ladder climbs
(10 → 30 → 90 → 270 → 810 → 900 s, so gaps of ~100, 120, 180, 360, 900, 990), while the measured
gaps are flat from the first one — 992, 994, 999, 1009, 1010, 1011, 1012, 1013, all within 23 s of
each other. On top of the 90 s interval, the deterministic per-profile spread (`:1430`) adds
`[0, interval/4)` = `[0, 22.5) s`, which survives under either mechanism and is where the last
~20 s come from. Predicted 990–1012.5 s from the `auth_broken` widen; measured as above.
Two things the section does not otherwise say: `quantivly-3` was NOT on that ladder and had a
single **3,897 s** gap from 08:29:05 instead — a longer outage of a different shape — and the
refresh-failure axis is its own streak (`update_streaks`, `:1455`), not the 429 one.

**Every line number in this section is from commit `ff25762` — the tree at
`~/.config/herdr/plugins/github/clauth-4596d4a41686`, which sits BETWEEN releases: 318 commits
after `v0.14.1` and 122 before `v0.15.1` — while the binary that ran is 0.15.1, installed
2026-09-08 20:58.** Name the commit and its position, never a release: an earlier version of
this line called that tree "clauth 0.14.1", which its own `Cargo.toml` says only because the
version string was never bumped, and a release label invites the reader to look a line up in a
release that does not contain it. Measured with
`gh api repos/uwuclxdy/clauth/compare/v0.14.1...ff25762` and the mirror against `v0.15.1`; the
drift is real and small — `if is_active` is at 859/895 in `ff25762` and 878/914 in v0.15.1. The
installed source has since been read wherever a claim turned on it (`poll_backoff_ms` above,
`RefreshError` in the correction below, both fetched with `?ref=v0.15.1`), never in whole — so
the gap stays, and it is exactly the one the `mcpOAuth` correction above turns on, stated rather
than left to be discovered. What makes the mechanism claims here more than a source read is that
the timing above *reproduces* from that tree's constants; treat the line numbers as
corroboration, not as provenance.

**Three forensic techniques, because none of them is obvious and all three were needed:**

- **`expiresAt − mtime` tells a NEWLY ISSUED token from an adopt** — not a `/login` from a
  refresh, which is what an earlier draft claimed. A grant is written the instant it is issued,
  so the difference is the full lifetime (28799–28800 s); a reconciler adopt writes a token
  issued earlier, so it is less. That is how `quantivly-0`'s 09:39:41 store write was identified
  as an adopt of an 08:29:41 token rather than a fourth re-authentication — the first draft of
  the timeline had it as a login. But a successful *refresh* is also written at issuance, so the
  test cannot separate those two: applied to the current disk it names **four** full-lifetime
  09-14 writes, and `quantivly-3`'s (mtime 08:29:00, expiry 16:29:00, Δ 28800) is a refresh on
  resume — quantivly-3 is not one of the three accounts that laddered. What identifies the three
  logins is the ladder plus a new grant after it, not this difference alone.
- **Gaps in `~/.clauth/profiles/*/usage_history.jsonl` are the per-account failure record.** Only
  a LIVE fetch appends a line, so a gap is a failed poll. It is the only per-profile history on
  disk and it survives restarts.
- **Reconcile-timer gaps plus `PM: suspend` from the kernel journal** give the trigger. Nothing
  else on the box records that the machine was away.

**The reconciler is not the suspect, and cannot be.** `cred_live_side` ranks on `expiresAt` and
never compares refresh tokens — but a refresh rewrites the access token and the refresh token
*together*, so the side with the later expiry is by construction the later link in the chain, and
adopting it cannot install a refresh token older than the one it discards. Its real limitation is
different and worth stating: **it compares exactly two files** and cannot know whether a third
holder has advanced the chain past both.

**clauth's own double-spend guard is blind to this machine's architecture.** `fresher_disk_pair`
(`src/usage/scheduler.rs:491`) decides whether a 400 is a benign double-spend or a real revocation
by re-reading **the clauth profile store** and checking whether its refresh token moved past the
one just spent. The comment naming the racer it expects — *"CC writing THROUGH an intact
symlink"* — is at `:916`, on the CALL SITE (`carry_external_rotation`, `:507`, which wraps it),
not in the function's own doc block; an earlier draft cited `:507` for `fresher_disk_pair` itself
and attributed the caller's comment to it. Here Claude Code's write is atomic, so it REPLACES the account-dir symlink with a real
file and the store does not advance — the guard sees "unchanged", concludes "real revocation", and
can quarantine a healthy account. `try_adopt_live_rotation`, the fast path that would catch it,
runs only `if is_active`, so four of five profiles never get it. **This DID fire on 09-14, and it
is this incident's cause** — see the correction immediately below.

**CORRECTED 2026-09-16 (second — these corrections are numbered by order of DISCOVERY, not by
position, so "(second)" is met before the first, which is the nanoclaw note below): clauth
quarantined all three accounts, it said so at the time, and the original search grepped the
wrong log.** This section claimed *"no `auth_broken` was ever logged"* and built a whole
paragraph on the rejection class being unrecoverable. Both are false.
`journalctl --user -u clauth-daemon.service` carries it verbatim:

```
08:29:13  clauth: login for 'quantivly-1' has expired: refresh token revoked or invalid … (flagged auth_broken)
08:29:17  clauth: login for 'personal-1'  …
08:29:27  clauth: login for 'personal-0'  …
```

— exactly the three accounts that were re-authenticated, 114–128 s after resume. **The daemon's
`logline!` output goes to the JOURNAL, not to `~/.clauth/clauth.log`**, which carries only TUI and
CLI lines: measured, `clauth.log` contains **0** lines mentioning `daemon` while the journal
contains **511**. The original search grepped `clauth.log`, found nothing, and reported absence.
**That is the same error as the nanoclaw one below, made twice in one investigation: absence in
the one place you looked is not absence.** Ask where a process's output actually goes before
reading its silence.

What the corrected evidence settles, which the original left open:

- **The rejection was terminal, not transient.** "refresh token revoked or invalid" is
  `RefreshError::Invalid`, whose own doc comment reads *"The endpoint confirmed the refresh token
  itself is dead"* — a 401, or a 400/403 carrying `invalid_grant`. The paragraph claiming
  otherwise is withdrawn, along with its conclusion that "one log line upstream would close it";
  the upstream observability gap is real but was never what this incident hit. **Terminal is not
  the same as double-spent, though.** The class establishes only that the endpoint confirmed the
  token is dead, which a genuine server-side revocation produces just as well — so it cannot
  distinguish the two, and a double-spend is the **live hypothesis** rather than a settled fact.
  What makes it the live one is the third bullet's account-dir/store divergence, not this
  bullet's error class. An earlier version of this line read "So it WAS a plain double-spend":
  an inference rendered as an entailment, inside a correction whose stated purpose is to stop
  doing that.
- **The ~1010 s is `auth_broken`'s own widen, not a `refresh_fail` ladder.** `poll_backoff_ms`
  returns `AUTH_BROKEN_BACKOFF_MS` — the same 900 s ceiling — *before* it consults any streak, and
  90 s + 900 s is the observed spacing. The accounts stayed flagged ~70 minutes until
  `clauth login`, so nothing in the ordinary poll path cleared it.
- **The blind spot is ours, not upstream's, and it is the cause — and this is the bullet that
  carries the double-spend evidence.** A session refreshed first and its rotation landed in the
  ACCOUNT DIR; `fresher_disk_pair` re-read the STORE, which had not
  advanced, and concluded a real revocation. That divergence is what says the dead token was one
  *we* had already spent rather than one the server withdrew. clauth's own watchdog (`runtime.rs`
  `sync_credentials_unlocked`) would have advanced it — but only for `clauth start` runtime dirs,
  and `claude-account-dirs` dirs are not those. Our reconciler adopted the fresh credentials into
  those three stores at 08:29:28: **1–15 s too late.**

**The actionable consequence is local.** After the reconciler adopts a rotation into a store,
nothing tells clauth the chain is alive again. `claude-account-dirs.sh --reconcile` or
`claude-doctor` should at least REPORT a standing `auth_broken` on a profile whose store it has
just refreshed. Not built, and deliberately not designed here: whether clauth's reload re-reads
`credentials.json`, and whether clearing that flag out of band is supported at all, are both
unanswered.

**A NOTE ON NANOCLAW, AND A TILDE — corrected twice, 2026-09-16 then 2026-09-17.** nanoclaw's
`src/oauth-refresh.ts` names `~/.claude/.credentials.json` as its `default` profile (personal
Claude Max), alongside `~/.claude-work-home/.claude/.credentials.json` for Teams, and it
**deliberately refuses `CLAUDE_CONFIG_DIR`** — its IMP-2521 exemption selects an account by
overriding `HOME`, "not by config dir", and declines to "repoint a live credential read on the
strength of a variable production never sets".

**That `~` is nanoclaw's, not this machine's, and a 09-16 edit to this file conflated them.** That
edit declared the path "IS owned — by nanoclaw", retracted the sentence above it, and told readers
`claude-doctor`'s orphan warning was expected noise. All three were wrong **on cilantro**, and the
measurements are one-liners: `getent passwd nanoclaw` → no such user; `/home/nanoclaw` → does not
exist; `/home` contains only `zvi`; no system `nanoclaw.service`; and
`HOME_DIR = process.env.HOME || '/home/nanoclaw'` (`oauth-refresh.ts:94`), with
`nanoclaw.service` declaring `Environment=HOME=/home/nanoclaw`. `~/.claude-work-home/` does not
exist here either. The writer cannot run here at all: `persistRotatedCredentials` is reached only
through `initOAuthRefresh`, whose sole non-test caller is the daemon entry point, and the three
nanoclaw units that DO run here as `zvi` (`nanoclaw-orchestrate`, `-fleet-agent`,
`-memory-curator`) import none of those modules.

So **on this machine the original sentence stands: nothing reconciles that path**, and
`claude-doctor`'s `⚠ the live credential matches NO registered clauth profile` is a **real
signal, not expected noise** — treating it as noise would retire a working orphan-detector. The
09-14 relink did not touch "nanoclaw's refresh target"; it repointed a path nanoclaw does not
maintain here. Where nanoclaw's claim IS true is the **nanoclaw server**, under
`/home/nanoclaw`, which this checkout cannot see.

**The lesson, which is why this is kept rather than deleted: a path read out of another
project's source arrives in that project's frame.** `~` is whoever's `HOME` the process has, and
a service unit can set it to a user that does not exist on your box. Before importing a path from
a neighbouring repo, resolve the `~` — `getent passwd`, the unit's `Environment=HOME`, and
whether the writing code path runs here at all. Found by an independent review, not by the author,
which is also the pattern.

**How the mistake was made, which is the part worth carrying.** The brief this section came from
said the symlink shape at that path was "undocumented", and that was read as evidence the path had
no owner. The search behind it covered this repository and clauth's source, and stopped there.
**"Nothing I searched owns this" is not "nothing owns this"**, and the distance between them was
one `grep` over `~/Projects`. A relink was made on 09-14 on the strength of it, pointing nanoclaw's
refresh target into a clauth profile store; an ordinary atomic write replaced it on 09-15 13:39
before it cost anything. The outcome was luck; the reasoning was wrong when it was made.

**So the statement above stands as written:** `reconcile_all` walks only
`~/.local/state/claude-account-dirs/*`, and on this machine nothing reconciles the global path.
clauth rewrites it whenever it installs an active profile, and Claude Code replaces it on any
unisolated session's refresh — two writers, no reconciler, which is exactly what the orphan
warning is detecting.

**The Chrome native host was reading that path, and was pinned off it on 09-14.** Both the Chrome
and Chromium native-messaging manifests point at one four-line wrapper,
`~/.claude-personal/chrome/chrome-native-host`, which ran the binary with no `CLAUDE_CONFIG_DIR`;
two such processes had been holding whatever credential sat at the global path since 09-08. The
wrapper now execs with `CLAUDE_CONFIG_DIR=…/claude-account-dirs/personal-1`. **That pin was made on the
wrong model** — the path was believed unowned — **but the evidence says it lands in the right place
for a different reason, and an earlier draft of this paragraph overstated what it does.** That draft
said the pin "changes which account it bills", and a second draft replaced that with
**"the host spends nothing"**, which is also wrong and was refuted by this file's own companion
document. The symlink-survival argument behind it fails three ways: the link WAS replaced, at
11:00:33 on 09-14, recorded to the nanosecond in
`~/Projects/handoffs/credential-breakage-2026-09-14-FINDINGS.md`; the six days of continuity were
extrapolated from a single observation at 10:53 on 09-14 and never measured; and **link shape is
not a refresh detector once a second writer exists** — that 11:00:33 replacement was clauth
installing an active profile, not a refresh. Nor does "no refresh" imply "no spend": a process
that read a credential at startup can spend against that access token for up to its 8 h life and
only then 401. **What is actually established:** the host reads a credential at startup and acts
as the extension's transport; no refresh by it was ever observed; the global path's shape changed
at least three times on 09-14, at least once by clauth rather than by a refresh; so its spend is
**bounded but not zero, and was never measured**. It
reads a credential at startup and acts as the browser extension's transport, while the session that
drives the browser spends on its own account dir. What the pin actually does is take a Claude Code
helper off the **unreconciled global path** — the one clauth and Claude Code both replace and
nothing here reconciles — and put it on the account-dir scheme every other Claude Code process
here already uses. That sentence read "off a file nanoclaw owns" until 2026-09-17: a residue of
the retracted claim, left standing forty lines below its own retraction, which is the
carry-the-correction-all-the-way-through failure this section already names twice.

Two traps that creates, neither of which anything checks:

- **`~/.claude-personal` can no longer be deleted casually.** Both manifests point INTO it, and the
  pin lives there. The "remove the legacy `~/.claude-*` dirs" cleanup must re-point them first or
  the browser extension breaks — and `claude-doctor` will keep telling you to remove that directory,
  because it reasons about the credential in it and knows nothing about the manifests.
- **The wrapper says "Generated by Claude Code - do not edit manually."** It may be regenerated and
  silently drop the pin — the `~/.config/mise/config.toml` failure shape again.

**A reconciler arm for the global path was designed and deliberately NOT built.** Keeping that path
symlinked into a store makes clauth's `active_diverged_unsaved` guard — which refuses a switch when
the outgoing active profile has an uncaptured re-login, by comparing the live file against the
store — compare a file with itself, so it can never fire. Removing the readers instead costs one
`env` assignment in a wrapper and leaves both tools' invariants intact. **A 09-16 edit claimed a
second, stronger reason — "that path is not this repository's to reconcile, and the arm would be
fighting nanoclaw for a file nanoclaw refreshes" — and that is withdrawn: nanoclaw does not run
here (see the tilde note above).** The guard argument is the only reason, and it is enough on its
own; an arm remains defensible if someone wants one. Full analysis:
`~/Projects/handoffs/credential-breakage-2026-09-14-FINDINGS.md`.

### A standing `auth_broken` is reported, not cleared (DO-613)

**On 2026-09-14 clauth quarantined three accounts, our reconciler fixed the cause 1–15
seconds later, and the flag stood for 70 minutes with every check on the machine green.**
The flags are at 08:29:13/17/27 (`login for 'X' has expired: refresh token revoked or
invalid … (flagged auth_broken)`), the adopt at 08:29:28, and the next clauth line of any
kind is at **09:39:37** — 70 minutes of silence, ended by `clauth login`. `claude-doctor`
now reports the state; nothing in this repo had ever printed the word `auth_broken` outside
a comment.

**The binary's identity is proven rather than assumed, which is the one thing the previous
investigation could not say.** `sha256sum ~/.local/bin/clauth` is
`3d7a06aec6c81a8d4ddd0bc7dc1d5f7b2a689624b74ee9de0798061a49d8b928` at 12,348,208 bytes, and
that is byte-for-byte the `clauth-linux-x86_64` asset of GitHub release **v0.15.1**. So the
source at tag `v0.15.1` *is* the code that runs here, and the line numbers below are the
running version's — not the 0.14.1 plugin checkout's, which this file already warns about.

**Three questions were answered before anything was designed. Two of them refuted the
premise they were asked under.**

- **Does the config reload re-read `credentials.json`?** The *trigger* does not:
  `reload_fingerprint` (`src/profile.rs:1391`) is the mtime of `profiles.toml`, of every
  `profiles/<p>/config.toml`, and of every `profiles/<p>/session-token.json` — and
  **`credentials.json` is in none of them**, so writing a store credential does not wake the
  daemon. The *effect* does: once triggered, `load_config` → `load_profile` (`:2220`) reads
  each store. **The `reloaded config after an external change` line seconds after each flag
  was clauth reacting to its OWN write** — `mark_auth_broken` persists `profiles.toml` and
  the daemon does not update its own `last_reload_fp` when it writes, so the next tick sees a
  changed fingerprint. Nothing was watching credentials. The journal shows the pairs in the
  same second, three times.
- **Is clearing it out of band supported?** No — and **the number that used to head this bullet
  did not come from the grep beside it.** It read "exactly **seven** mutation sites … (`grep -rn
  'set_auth_broken(\|mark_auth_broken('`)". Seven is the count of `mark_auth_broken(` **call**
  sites alone (`oauth.rs:2602, 2663, 2676, 2686`; `scheduler.rs:533, 943, 967`); that grep also
  matches `oauth.rs:1802`, `actions.rs:1084` and `actions.rs:1309` — three of the **five clearing
  paths this same bullet lists** — plus the definitions in `profile.rs`. So "seven" and "five"
  cannot both be derived from it and seven is not a superset of five. Checked at tag `v0.15.1` by
  an independent review, 2026-09-17. What is true, and is what the bullet was for: **every
  mutation site is internal to clauth** — there is no out-of-band clear. It is
  persisted only by `set_auth_broken_persisted` under clauth's state flock; `clauth --help`
  has no subcommand for it, the TUI only *renders* it (`src/tui/` has reads and no writes),
  the MCP surface only publishes it, and `clauth enable` touches `disabled` alone — upstream's
  own comment says that is "never `auth_broken`'s". Every refusal string prescribes
  `clauth login <name>`. **A sentence attributed to upstream's own tests here — *"which only a
  login, a carry, or an adopt lifts"* — is UNVERIFIED and is kept only as a paraphrase of the
  five clearing paths above, not as a quotation.** Searched 2026-09-17 at tag `v0.15.1`:
  absent from `profile.rs`, `oauth.rs`, `actions.rs`, `scheduler.rs`, `tests/inline/actions.rs`
  and `tests/inline/claude.rs`, and GitHub code search over the repo returns 0. That is not
  proof of absence — code search does not index everything and `tests/inline/` has ~30 more
  files — which is exactly why it is labelled rather than deleted or defended. The claim it
  decorates stands on the call sites, which were checked.
- **Does a later successful fetch clear it on 0.15.1?** **No, and the distinction is the
  whole finding: a successful *refresh* clears it, a successful *fetch* does not.** The five
  clearing paths are `clauth login`/capture (`actions.rs:1084`, `:1309`), an adopt from the
  live mirror (`oauth.rs:1802`), an adopt from disk at switch time (`:2602`), a carry after a
  terminal 400 (`scheduler.rs:533`), and a successful refresh (`:967`, `oauth.rs:2676`). None
  is on the plain-fetch path.

**So our own fix is what makes the flag permanent, and that is the part worth carrying
forward.** Upstream's design assumes the quarantined poll keeps failing — the comment on
`AUTH_BROKEN_BACKOFF_MS` (`scheduler.rs:39`) says each such poll "spends a guaranteed-dead
401 → refresh → 400 pair", which is what reaches `carry_external_rotation` and lifts the flag.
The reconciler adopting the live token removes that 401. The poll then succeeds, the rotation
leg is never entered, and nothing clears anything until the access token nears expiry hours
later. **A repair that removes another tool's recovery trigger is a repair that has to
announce itself.**

Be exact about what is measured and what is inferred. Measured: the flag stood 70 minutes,
and no `auth_broken cleared` line exists in that window — `mark_auth_broken` logs on every
*transition*, so that absence is evidence. Inferred: that the polls in those 70 minutes
*succeeded*. It cannot be confirmed, because `usage_history.jsonl` has been pruned back to
09-14 16:12 (after the window) and the scheduler's poll path has **no `logline!`** on either
a success or a refresh failure — the gap this file already records. What the absent `cleared`
line does establish is that neither the carry nor a successful refresh ran, which leaves the
successful-fetch path as the only one left.

**REPORT ONLY, and the ceiling is upstream's, not ours.** Clearing the flag means writing
`profiles.toml`, which clauth owns and serialises under its own flock — the third-writer
problem this whole area exists to remove. Answer 2 means there is no sanctioned out-of-band
clear to call instead. So:

- **`claude-doctor` is the surface**, in §3, and it is a **⚠ never a ✗**: the remedy needs a
  human and a browser, so a retired-but-still-registered quarantined account would otherwise
  make the doctor exit non-zero forever — the permanently-red checker, **seventh** recurrence.
  It reports, per profile, whether the *store* credential is `usable` / `expired` / `dead` /
  unreadable, because that is the difference between clauth refusing an account that works and
  clauth agreeing with what is on disk. The check is deliberately **outside** the Account dirs
  section: that section is skipped wholesale when no account dir exists, and a machine that has
  never run an isolated session can still have a quarantined profile.
- **`claude-account-dirs.sh` adds one sentence at the ADOPT**, and only there. That moment is
  the only place the two facts meet, and this process is the only thing that sees it:
  `.reconcile-status` is overwritten every two minutes, so the `adopted` verdict — which
  `claude-doctor` reads — is gone before anyone runs the doctor. `kept-store` gets no line (the
  store's own login won, so nothing about the chain changed) and `linked` gets none (it is the
  resting state, on most of the 720 runs a day the timer makes). The exit code is untouched: a
  timer's `ExecStart` must not start failing for a state only a human can fix.
- **Acting on the flag is what conceals it**, which is the argument for reporting at all.
  `_claude_profile_excluded` already drops a quarantined account from the picker, correctly — so
  no session ever launches on it, nobody sees a launch-time message about it, and work silently
  concentrates on the accounts that are left. The one repair the reconciler *could* announce at
  launch is on the account nobody is launching.

**The parse has three readers and two failure directions, and the row that mattered failed
first.** `auth_broken` is a multi-line TOML array (`toml::to_string_pretty`), and serde's
`skip_serializing_if = "Vec::is_empty"` means an **empty list is an ABSENT key** — verified
against the live file, 13 lines with no `auth_broken` among them — so "no key" must read as
"none" and only an unreadable file as NOT CHECKED. In the other direction, **checking that the
span contains a `]` is not enough**: an `auth_broken = [` with no members followed by
`profiles = [ "p1", ]` closes on the *other* array's bracket, and the first version reported p1
as quarantined. Both readers now validate the span's **interior** — between the first `[` and
the first `]`, an array of names holds nothing but quoted strings, commas and whitespace — and
the closing-bracket test stays because it is the only thing that catches a truncation landing
right after the `[`, where the interior has nothing to object to and the answer would be a
confident all-clear over a list never read.

Recorded and deliberately **not** fixed here: `_claude_profile_excluded` (the picker) and the
doctor's own `fallback_chain` reader use the older shape and take the foreign-bracket runaway.
**An earlier version of this paragraph called that safe on the grounds that "the picker excludes
an account it cannot vouch for … neither invents a finding". Both clauses are false, and an
independent review measured it.** On `auth_broken = [` followed by `profiles = ["p1","p2"]` the
runaway span swallows the profile list, so `claude-pick --explain` marks **every registered
profile** `excluded`, each with the specific and wrong reason `auth broken — clauth login p1`,
and then `refused: unusable — no usable account`, **exit 2** — reproduced here 2026-09-17 against
a fixture `$HOME` with two healthy credentials. That is not a disagreement about a malformed
file: the pool collapses, so every headless caller (`hspawn`, `claude-pick --strict`,
herdr-draft) refuses to start anything at all, and the picker invents a per-profile finding
naming healthy accounts. The doctor meanwhile says NOT CHECKED and never points at the picker,
so nothing on the machine connects the two.

**FIXED for the picker, same day.** The parse is `_claude_quarantine_scan` in `zsh/zshrc.herdr`
— the canonical validated shape, copied from `_claude_quarantined_profiles` rather than called,
because that file is sourceable ALONE by a modular adopter who has neither `claude.sh` nor the
reconciler. That makes **three readers of this one key and a change belongs in all three**; the
cross-check row exists to catch them drifting.

**The asymmetry is the design, and it is the part to carry.** An unreadable or malformed
`auth_broken` list now excludes **nobody**, where it used to exclude everybody. Neither is
"safe" in the abstract, so the question is which error costs more: failing to exclude a
quarantined account costs ONE session, which then fails at auth and names `clauth login`;
excluding every account costs all work on the machine and blames accounts that are fine. The
same reasoning already decided the pool-exhaustion fallback above — *exclusions correlate with
load, so a path that is rare in calm weather and concentrated in bad is the opposite of a safe
degradation.* Silence is not part of the trade: `_claude_pick_for_dir` scans once itself and
warns, because `_claude_pick_class` runs inside `$(...)` and anything the classifier learns
about an unusable list dies with that subshell — the same rule this file already records for the
picker's own `REPLY`.

**One overclaim caught while writing it**, worth keeping because the correction is the lesson:
the new membership test was first justified as "exact, so `p1` cannot match `p10`". Measured, the
OLD `*"\"$name\""*` was already exact — `"p10"` does not contain `"p1"`, the quotes see to it.
Testing membership against the parsed name list is what makes the runaway unreachable; it buys
no precision the old test lacked, and saying otherwise would have shipped a defect that does not
exist alongside a fix for one that does.

**The remaining instance was `fallback_chain` in `claude-doctor`. FIXED 2026-09-17, and it took
a FIFTH attempt at one match.** Measured before the fix on `fallback_chain = [` followed by
`profiles = [...]`: the span ran into the other array, the `*'"'*` test passed on ITS quoted
names, and the doctor printed
`auto-switch armed: fallback_chain = [ profiles = [ "p1", "p2", ]` — a neighbouring line quoted
verbatim into a report that lands in transcripts, in the function whose own comment says that is
the thing it must never do, while claiming an auto-switch is armed on a machine whose chain is
deliberately empty. `_claude_fallback_chain` validates the interior AND every member, then
returns the member NAMES; the report is the doctor's own prose around them
(`auto-switch armed: the chain walks p1, p2`), so no span reaches it at all.

**The history is worth more than the fix.** A line-based `grep -oE` that never once fired against
clauth's multi-line array; a `tr`-flattened file, which removed the only boundary the match had;
then a bounded `sed` RANGE — and **a range ends at the first line carrying `]`, so it is bounded
to a LINE RANGE and not to one assignment.** Each of the three was reported as closing the
runaway, and the third carried a comment describing the runaway as a hazard it had already closed.
**Terminating a span is not validating one**, and the interior is the only test that has ever told
the two apart.

**An unusable span is a ⚠ `NOT CHECKED`, not silence.** Saying nothing would let a genuinely armed
chain go unreported in precisely the file state that hides it — an empty answer is never
agreement. A ✗ would exit non-zero over a hand-edit of another tool's config, which is the
permanently-red checker this file has now recorded seven times; it is avoided here by choosing the
severity deliberately rather than by remembering to. It is the same severity the quarantine reader
gives the same file being malformed, on purpose: two readers of one file must not disagree about
what unreadable costs. **The row that had to ship with it runs the other way** — an absent assignment must be silent on BOTH counts,
or every machine without a fallback chain carries a permanent warning about a setting it has
deliberately not set. That is the failure mode any new ⚠ path can introduce, and the reason the
new arm has a row for the resting state and not only for the broken one.

**`claude.sh` now holds ONE copy of the parse for TWO keys** — `_claude_toml_name_array`, called
by `_claude_quarantined_profiles` and `_claude_fallback_chain`. That is the reverse of the
decision made for the other two readers, for the reason those decisions were made: `zsh/zshrc.herdr`
must be sourceable ALONE by a modular adopter and `scripts/claude-account-dirs.sh` is bash, but
nothing separates `auth_broken` from `fallback_chain`, which sit forty lines apart in one file, and
a verbatim copy differing by one word is the drift this file keeps paying for. The evidence it was
worth doing is in the sweep rather than the argument: four of the eight mutants — the interior
check, the closing-bracket test, sed's exit status and the absent-key return — each killed rows for
**both** keys.

**The mutation driver had the defect it was built to measure.** It scored a mutant `DIED` by
grepping the suite's output for `✗`, and one row's own LABEL contains that character — "absent
credential file is not a ✗" — so a mutant could have been recorded as killed by a row that passed.
It was caught before it scored anything, by a `DIED` verdict whose failing-row list began with a
`✓`. **A needle must be unique to the thing it measures**: this file's rule for checkers, met in
the harness that checks them. It reads the `=== N passed, M failed ===` summary now, and refuses to
score a mutant whose find-string is absent, whose replacement is a byte-for-byte no-op, or that
does not parse — all three as harness errors, never as results.

**AND THE FIX DID NOT ESTABLISH ITS OWN INVARIANT. An independent review found that under a
291-check green suite and an 8-of-8 mutation sweep** — which is the fifth attempt at this one
match, and the entry that earns the section. **Validating the interior validated only the ODD
fields of the `"`-split: what sits BETWEEN the names, and never a name.** A span truncated
MID-MEMBER flips quote parity, so the neighbouring assignment lands in an EVEN field and is
emitted as a member. Measured against the fix, `fallback_chain = ["` over `profiles = ["` printed
`auto-switch armed: the chain walks profiles = [` — both halves of the defect the PR existed to
remove, reproduced by it — and on `auth_broken` the same span reached a **remedy**:
`Do NOT run 'clauth login profiles = ['`, advice built out of raw file content. All four readers
of this shape shared the hole, and **all three that parse it now carry the member class** —
`claude.sh` (both keys), `_claude_quarantine_scan` in `zsh/zshrc.herdr` and
`profile_is_quarantined` in `scripts/claude-account-dirs.sh`, in one change. Fixing only the
doctor is what a third pass caught: for one round the three gave **three answers to one file**,
the doctor saying NOT CHECKED while the picker returned 0 over a list it could not validate and
its malformed-list warning therefore never fired. The catastrophic direction was never reachable
— a bogus member matches no registered profile, confirmed independently over thousands of
randomised malformed files — so what the divergence cost was LOUDNESS, which is the entire
purpose of the NOT CHECKED state. **The PR that fixes one reader owns the divergence it creates**,
so this belonged here and not in a follow-up.

The bash reader's copy is **unkillable through its call site and is labelled rather than
counted**: measured, `profile_is_quarantined <real name>` answers 1 with the class and without
it, because the only query whose answer moves is the bogus member itself, and no caller passes
that. It is kept for the reason the file gives for having three copies at all — one rule in three
languages — and because a future caller that ENUMERATES rather than tests membership would
inherit the hole in silence. Its row therefore probes the FUNCTION'S CONTRACT directly rather
than its behaviour, which is the only thing that can fail.

**The general rule, which is the thing to carry: a parity-based parse is only as validated as its
UNCHECKED fields.** Splitting on a delimiter and checking alternate fields feels total and is
half a check — an unterminated delimiter renumbers every field after it, so the half you did not
check becomes the half that corruption controls. The fix is one more pass: every member must
match clauth's own name class (`validate_profile_name`: letters, digits and `- _ . @ +`), as
**its own loop before the emit loop**, because folding it into the emit loop would print the good
members before refusing — a partial emission *and* a `return 1`.

Four more from the same review, each now a row and a dead mutant:

- **The severity was defended in four sentences and pinned by nothing.** `_doctor_warn` →
  `_doctor_bad` survived all 291 checks, and measured, it flips `claude-doctor` to rc 1
  permanently on any malformed `profiles.toml` — the permanently-red checker, self-inflicted by
  the arm written to avoid it. **If a comment defends a choice by name, a row must measure the
  choice**; no `want_rc` in the suite touched a malformed `profiles.toml`. The row needs a
  fixture carrying no ✗ of its own, or it cannot fail.
- **A copied comment is a copied CLAIM, and factoring the code does not factor the claims.**
  "clauth omits the key entirely when the list is empty" is verified for `auth_broken` (serde
  `skip_serializing_if`) and **false for `fallback_chain`**, which has no such attribute and sits
  in the live file as `fallback_chain = []` — measured 2026-09-17, one such assignment present
  and zero `auth_broken`. It was copied from the quarantine reader along with the parse, so the
  drift the sharing removed from the code reappeared in the prose, and it was the stated
  rationale for a row labelled "THE RESTING STATE OF THIS MACHINE" whose fixture is a state this
  machine is not in.
- **Two guards are genuinely unkillable and are now labelled as such**: the `-r` test (sed's own
  status already returns 1 for an unreadable file) and the opening-bracket test (with no `[` to
  strip, the key name itself lands in odd field 1, which is never clean). The author had labelled
  exactly one such site and left these two reading as coverage.
- **The remedy named two causes out of four.** On the `sed`-missing path — which this PR gave its
  own row — the file is fine and `PATH` is not, so the reader was sent to inspect another tool's
  config over a `PATH` fault: the "the remedy the guard names did not remedy" class. A comment
  inside the array and TOML literal `'single-quoted'` strings are legal and are refused, so the
  message says so rather than letting a hand-edit look like a truncation.

**And one the review did not find, caught while writing the mutant for the fix: the new check was
WIDER than any fixture reached.** The member class allows `- _ . @ +` and every row in the suite
named its profiles `p1`/`p2`, so narrowing it to `[A-Za-z0-9]` would have survived everything
while refusing this machine's own file — the live profiles are `quantivly-3`, `personal-1`, a
hyphen in every one. **Ask of a new guard not only "what does it reject" but "what does it accept
that nothing here exercises".** A permissive branch with no fixture is as unpinned as a missing
one, and it fails in the direction that breaks working machines.

**A SECOND, INDEPENDENT PASS ASKED ONLY "WHICH OF THESE ROWS CANNOT FAIL?" AND FOUND TWO MORE
SURVIVORS UNDER 304/0 — BOTH ON THE ARMED PATH.** Every raw-content negative in the suite sat on
the NOT CHECKED arm, so a note that kept its prose and dumped the span *beside* it was invisible,
and `_doctor_note` → `_doctor_bad` on the armed note was invisible too — that one makes
`claude-doctor` exit 1 forever on every machine that has a chain configured. **When a block has
two output arms, an assertion on one arm is not an assertion on the rule.** "Never print raw file
content" was this change's one rule with no trade-off and it was enforced on one of the two paths
that can print; the severity was pinned on the arm whose ⚠ had a row and not on the arm whose `·`
did not. Enumerate the arms that can print, not the failure you happened to be thinking about.

- **Two rows could not fail, and the REASON is the useful part.** The paired
  `no_out "auto-switch armed"` on the sed-missing and truncated-at-bracket fixtures survived every
  applicable mutant: the chain's unarmed state is **silence**, so there is no positive string to
  forbid and no single mutation on those fixtures can produce one. The quarantine twin's
  equivalent works only because its all-clear is a printed LINE. Both are deleted with that
  reasoning in their place rather than labelled — a row that always passes reads as coverage. The
  two that LOOK identical on the runaway and mid-member fixtures are kept, because those spans do
  hold text and deleting the member class really does print `auto-switch armed`.
- **A needle that CAN fail may still not be unique to the rule.** `p2` was measured failable here
  and is a generic fixture name this suite reuses throughout, on many other fixtures' own pass
  paths, so it was sound only because this one fixture happens to create no `p2` profile. **No
  count is given deliberately**: two independent measurements disagreed (10 vs 13) because
  "mentions `p2`" and "prints `p2` on its pass path" are different questions, and a figure whose
  method is ambiguous decays faster than the claim it decorates. A `zzcanary` member that appears nowhere else
  now sits beside it. The comment claiming "the two halves of the defect fail independently" was
  also measured half-true and is corrected: the member needle subsumes the raw-assignment one.
- **A MUTANT THAT DIES FOR THE WRONG REASON IS WORSE THAN ONE THAT CANNOT APPLY.** A mutation
  written `_doctor_warn` → `_doctor_fail` was scored DIED on three rows. There is no
  `_doctor_fail` in this repo — the emitter is `_doctor_bad`, and the counter `_DOCTOR_FAIL` is
  what makes the wrong name plausible — so it replaced the emitter with an **undefined command**,
  the line printed nothing, and the rows that failed were the ones asserting the message is
  PRESENT. **An inapplicable mutation survives, which is expensive but sends you looking; this one
  read as already covered, and a false all-clear is never investigated.** No gate this file had
  sees it: find-string present ✓, bytes changed ✓, `zsh -n` ✓, because an undefined function is a
  runtime failure and not a parse error. Two cheap gates do: assert `(( $+functions[<name>] ))`
  for every function name the REPLACEMENT introduces (measured over all **18** entries in the
  driver, 0 offenders), and **attribute a death to a row whose SUBJECT is the mutated property** — all three
  dead rows there were about message text and none about an exit code, which is this file's
  "a needle must be unique to the RULE" applied to the mutation side.
- **A row built on a false premise, withdrawn rather than shipped.** The second pass built a
  cross-key independence row and then measured that the mutation which would justify it *cannot
  change behaviour*: both readers run inside `$( … )`, so globals set there die with the subshell.
  Recording the withdrawal, because a row resting on a false premise is exactly what such an audit
  is for.

**THE ROW WRITTEN FOR THAT GAP WAS DECORATION, AND A MISLEADING VARIABLE NAME IS WHY.** The
mutant meant to prove the armed note cannot leak file content dumped `$cspan` — a variable whose
name says span and whose contents are the reader's **validated member names**, `p1` and `p2`. It
leaked nothing and **SURVIVED**, which reads as a missing row when the truth is the opposite:
**no raw span is in scope on that path at all**, because the reader returns approved names only.
So the paired `no_out` could not have failed either way. Three things came out of it, and the
first is the one that generalises:

- **A variable named for the wrong thing is a defect, not a style point.** It misled the person
  who wrote both the mutant and the row — the same person who had just written the comment
  explaining the invariant. Renamed to say what it holds, with the structural guarantee stated
  once beside it: a leak there now needs a NEW file read, not a slip with an existing variable.
  The mutant that reproduces *that* (`sed` re-read, dump the real span) dies on exactly one row,
  by name.
- **An adjacent-content canary was written and removed as unfailable, and the reason is worth
  more than the row.** On a well-formed chain the span stops at the first `]`, so no neighbouring
  line is in it; on a malformed one the odd-field and member checks refuse before anything
  prints. For adjacent content to reach the *armed* note it must pass the member class — i.e. be
  a bare name-shaped token, indistinguishable from a legitimate member, so no assertion could
  tell them apart.
- **Two mutants were misnamed in the same way**, and a misnamed mutant is a small lie in the
  record: one "prints the raw span" actually dropped the prose and the join (it died, for that
  reason), and the retired one could never die. Both are relabelled rather than deleted, because
  a retired mutant with its reason is evidence and a silently dropped one is not.

**The harness lesson got a PRODUCTION row, which is where it belonged.** The typo'd-emitter
mutant is not just a harness hazard: the same typo in `claude.sh` makes that finding print
**nothing**, never increments `_DOCTOR_FAIL`, and so gets the doctor's **exit code** wrong too —
a silent failure inside the checker whose entire subject is silent failures, invisible to
`zsh -n` and to the suite's own `$+functions` preflight, which lists the names the SUITE knows
and not the ones `claude.sh` calls. A row now reads every `_doctor_*` call out of the file and
asserts each resolves. It fires by name under the mutant (`calls undefined emitter(s):
_doctor_fail`) while **seven** message-text rows fail beside it — which is the fake-death shape,
now with something in the output naming the real cause instead of leaving seven rows to imply it.
The applicability gate gained the same rule plus **one allowlisted exception**, declared by name
with its reason, since the mutant proving the row works must introduce an undefined emitter on
purpose.

**THE LEGAL-TOML REFUSALS ARE NOW A DECISION RATHER THAN AN ACCIDENT, AND THE PARSER IS
DELIBERATELY NOT BUILT.** Three shapes that are valid TOML and that clauth never writes — a
comment after the opening bracket, a commented-out member, and literal `'single-quoted'` strings
— come back as ⚠ NOT CHECKED. Nothing asserted that, so an edit could have started accepting a
comment-bearing array in silence. What decided the shape of the fix is the direction of the
danger, measured: with the odd-field check removed, `fallback_chain = ['a', 'b']` returns **rc=0
with no members**, so an armed chain reads as *unarmed* — the report goes quiet on exactly the
state it exists to announce. Refusing is loud; accepting a shape the parse was never designed for
is not. Hence "never silently empty" as the assertion.

Two fixes were considered and declined, and the second is the tempting one:

- **A real TOML parser** is what the workflow guard's history argues for ("those are YAML
  questions, and each round of patching produced a new way to answer one wrongly"). Here it means
  python3 + `tomllib`, which is **3.11+** — the exact dependency `verify-tools.sh` was corrected
  for, on the Ubuntu 20.04 box (python 3.8) that is the first outside adopter's. A new external
  tool in a checker is a new way for a check to go quiet.
- **Stripping whole-line comments only** — a line whose first non-whitespace character is `#`
  cannot be inside a string, *unless* it is inside a multi-line basic string, which cannot
  plausibly hold a profile name, and which the member class would refuse anyway. That chain of
  three corner-case arguments about TOML is precisely how the previous four fixes to this one
  match were justified. Declined for the shape of the reasoning, not for a defect anybody found
  in it.

**The asymmetry is what makes refusing cheap here, and it is worth stating because the same
refusal is wrong one file over.** This consumer is a DISPLAY: a conservative refusal costs one
sentence of report, moves no account and changes no exit code. In the picker the identical rule
is inverted — a malformed list excludes **nobody** — because there a refusal costs account
selection. Same parse, opposite safe direction, decided by what the caller does with the answer.

What would change the decision: clauth starting to write comments, or somebody actually meeting
the ⚠ and being misled by it. The message names all four causes, so the reader who just
commented out a member is told what happened.

**A THIRD PASS AUDITED THE PROSE ITSELF, AND THE WORST FINDING WAS THAT A RETRACTION IS NOT A
CORRECTION.** The `skip_serializing_if` claim above was retracted at the code site — and left
standing, asserted, in the header of the very function that retracts it, fifty-five lines apart
in one body. The same claim also survived in this file as a row's stated rationale. **When you
retract a claim, grep for every instance of it, starting with the file you are editing**; the
retraction is the easy half and it is the half that feels like the work.

Four more from the same pass, each verified before acting on it:

- **"A fix that is right on ONE SIDE of a report is worse than one wrong on both" — met on the
  MESSAGE side, one round after being quoted in the comment that fixed the other side.** The
  chain arm's remedy was corrected to name all four causes; the quarantine arm was left naming
  two, for a full round, while both missing causes reach it (measured: a comment and a literal
  string each give rc=1 there, and `sed` missing does too). Both arms name four now, and **both
  have rows**, so the next divergence fails instead of waiting for a reviewer.
- **A document contradicted itself about its own history**: "a FOURTH attempt" in one paragraph,
  "the fifth attempt" and "the previous four fixes" in two others. Five is right, and the count
  is now the same everywhere.
- **A pointer written by one of these corrections pointed at the retracted technique.** The 2026-09-17
  entry ended "the fix that does hold is the interior check" — which is precisely what did not
  hold, as the round after it established. A correction is a claim like any other and goes stale
  like any other.
- **A precise count whose measurement method is ambiguous decays faster than the claim it
  decorates.** "Nine other fixtures print `p2`" was re-measured as 10 by one method and 13 by
  another, because "mentions it" and "prints it on its pass path" are different questions. The
  claim needed no number at all, so it no longer carries one — and that is the better fix than
  picking whichever figure was defensible.

**THREE MORE FROM THE SAME PASS, AND TWO OF THEM WERE UNPINNED FIXES IN THE FIX.**

- **A loop's upper BOUND was unpinned, and the reason is a property of every fixture at once.**
  Changing the member loop's `i <= ${#parts}` to `i < ${#parts}` survived all 320 rows *and*
  reproduced the defect. Every malformed fixture in the suite had an **even** number of quotes,
  so the runaway sat at index 2 where `<` still reaches it; a **one-quote** span puts it in the
  LAST even field — exactly the one `<` drops — and one stray quote is the likelier torn write.
  **A fixture family can share a property that makes a whole class of mutation unreachable**, and
  no amount of adding more fixtures of the same shape reveals it; ask what every fixture has in
  common, not how many there are.
- **A row that greps for a defect matches the comment explaining the defect — THIRD time in one
  change.** The `_doctor_*` emitter row grepped the bare name, so it matched PROSE: `claude.sh`
  carries three such mentions in comments and the row was green only because all three happen to
  name real functions. One comment naming `_doctor_fail` turned the suite red asserting a call
  that does not exist — a permanently-red checker armed by a comment. Matched as a **call** now
  (line-start, `&&`, `||`, `;`, `{`), and deliberately **not** by stripping comments first: a `#`
  inside a quoted string would drop a real call, which is the direction that makes the row go
  quiet rather than loud.
- **The rename lesson applied to one of two identical siblings.** `qspan` held names, not a span,
  forty lines from the `cspan` it was renamed with. One-side-only fixes are this file's most
  repeated shape and they are hardest to see when the two sides are adjacent.

**And two row-quality findings that are worth more than the rows they fixed.** Four assertions
labelled "the message names a comment as a cause" and "names a literal string as a cause" were
**two halves of one constant echo block**, printed on every NOT CHECKED — so each was satisfied by
any input reaching that arm, and four rows pinned one fact while reading as per-cause coverage.
**A needle taken from a constant block measures the block, not the case that produced it**; one
row per arm now, labelled for what it measures. Separately, the class's width was pinned only
DOWNWARD (`n9` refuses a narrowing that would reject this machine's hyphenated profiles) — adding
a single space to it survived the whole suite, so a row over `["a b"]` now pins it upward too. A
space cannot be in a clauth profile name, so that row is honest rather than invented to kill a
mutant, which is the distinction to keep when closing a surviving-mutant gap.

Rows: `scripts/test-claude-doctor.sh` **281 → 325 at `d2848f6`** (#160's squash), and
`scripts/test-claude-account-dirs.sh` 156 → 159 in the same commit.

**The intermediate figures deliberately carry no shas, and that is the lesson of this
follow-up.** Inside #160 the count moved 291 → 304 → 306 → 314 → 320 → 326 → 325 across six
review rounds, and the first version of this paragraph anchored each number to the branch commit
it was measured at — all seven of which **ceased to exist the moment the PR was squashed and the
branch deleted**. `git merge-base --is-ancestor` puts every one of them off `origin/main`. So the
rule this file already states for branch NAMES — "a branch is not an anchor" — applies to the
COMMITS on that branch too, and it is sharper: a branch name is visibly a branch, where a
seven-character sha looks exactly like a durable anchor and fails silently.

**For work that lands as a squash, the only durable anchors are the squash sha and the PR
number.** Everything measured during review collapses into one commit, so the honest record is
the final figure against that commit plus the progression in prose. Two of the movements are
worth keeping precisely because a bare delta hides them: two rows were **deleted as unfailable**
in one round, and four duplicated assertions were **consolidated into two** in another, so the
count went DOWN by one while coverage went UP — the clearest case there is for never reading a
row count as a quality measure. **21 live mutants, 21 deaths, 0 survivors, 0 harness errors**, plus one retired
by design. Two of the last three were written by an independent pass against fixes this file had
already called pinned, and one of those (the bash reader's class) killed nothing until its row
was rewritten to probe the FUNCTION'S CONTRACT instead of its behaviour — a surviving mutant is
what said the first row was decoration. After the last edits every entry was **dry-run for applicability against
the current tree — 19 entries, 0 stale, 0 no-ops** — and the three whose subject touches the
changed lines were re-run and re-died; the rest are untouched by a comment-only edit, and no row
was ever deleted, so their kills stand. That last step is reasoning and is labelled as such
rather than presented as a fresh sweep. The whole set was re-run against the tree rather than carried
over, three times, because a mutant measured against a previous version of the code proves
nothing about this one. Twice that
re-running paid: a rename left one mutant's find-string matching nothing (`find-string occurs 0
times`, reported as a harness error and not a survivor), and the mutant written for the armed
path's leak rule **survived**, which is what exposed the misleading variable name above. An
EIGHTEENTH — `M14` in the driver's numbering, which does not renumber — is **retired with its
reason** rather than dropped — it dumped the names variable, so
it could never die, and a retired mutant with a reason is evidence where a silently dropped one
is a gap nobody can see.

State tables: `scripts/test-claude-doctor.sh` (235 → 279 at `6661472`) and
`scripts/test-claude-account-dirs.sh` (137 → 156; CLAUDE.md said 70, then 36, and both were
stale — a count without its commit is the thing this file warns about). The cross-check row is
worth more than its size: it sources `zshrc.herdr` and `claude.sh` into one shell and asserts
the picker's exclusion and the doctor's enumeration answer the same for the same file, on the
single-line two-name fixture — the shape a greedy extract gets wrong. **19 mutants, 19 deaths**,
each killed by the row that names it, every mutation dry-run for applicability first. One of them
was DEAD-ELSEWHERE until its expectation was corrected: the closing-bracket test is isolated only
by the truncation landing AT the bracket, because the interior check already answers every other
shape — count how many independent deletions it takes to reach a silent pass, not how many guards
there are.

**That figure does not cover the guard it appears to, and saying so is the point of writing it
down.** An independent review measured a twentieth mutant: in `profile_is_quarantined`,
`(( inside && closed ))` → `(( inside ))` **survives 156/156**. It is redundant by construction
— `closed=0` means no line in the span held a `]`, so `body` holds none either and the very next
test returns 1 — and the paragraph above defends it with an argument that is true of the **zsh**
reader's `[[ "$body" == *']'* ]]` (mutant D4 kills that one) and was carried across to the bash
`closed` where it does not apply. The clause stays as defence in depth, **labelled unkillable
rather than counted**, because a mutant that can never die reads as coverage — this file's own
rule, applied to its own figure. So: 19 mutants killed by rows, 1 known survivor that is
documented instead.

**The review that found it also found two defects in the shipped code of this PR**, both under
273 green checks: a discarded `sed` exit status that turned "could not ask" into a confident
all-clear, and a classification that told the reader NOT to run the one command that repairs a
registered profile. Both are fixed at `6661472` and each is now pinned by a mutant that dies.
Full report: `~/Projects/handoffs/2026-09-17-pr153-adversarial-review.md`.

### Holder attribution, and the shell that has half this file's functions (DO-612)

**`claude()` announced `account 'home'` — a profile that has never existed — and registered
no holder, on every invocation from a Claude Code Bash-tool shell.** The guard was
`[[ "$CLAUDE_CONFIG_DIR" == "$(_claude_account_root)/"* ]]`. With an empty root the pattern
collapses to `/*`, which matches **every** absolute path; the strip then removes only the
leading slash and `%%/*` yields the first path component. This is DO-603/#131 one level
down — an empty pool filter meaning "every profile", here an empty path prefix meaning
"every path" — and it fails in the same permissive direction. Since #135 the holder count
feeds the picker's crowding term, so the account a session is actually burning reads as the
emptiest one and the next session is sent there too: **a missing holder is indistinguishable
from an idle account.**

**The trigger, measured rather than assumed, is the part worth keeping.** Claude Code's Bash
tool sources a shell snapshot (`~/.claude/shell-snapshots/snapshot-zsh-*.sh`) that captures
every function **except those whose name begins with a single underscore** — the zsh
completion convention. Measured 2026-09-12 on this box: the snapshot contains `claude ()`,
`hspawn ()`, `hreap ()` and `dotfiles-doctor ()`, and **none** of `_claude_account_root`,
`_claude_account_builder`, `_claude_pick_for_dir`, `_claude_holder_sessions`,
`_claude_tenant_for` or `_gh_route_for`; double-underscore names (`__zoxide_cd`) survive.
So in a Bash-tool shell every *public* function in `zsh/zshrc.herdr` is defined and its
entire *private* helper layer is not, and `claude --version` there reproduced the live
output exactly, first try:

```
zsh: command not found: _claude_account_root   (×3 — lines 1641, 1642, 1643)
claude: account 'home' (isolated: ~/.local/state/claude-account-dirs/quantivly-1)
```

Three findings from reproducing it, each of which corrects something that had been asserted:

- **The "no `<root>/home/` directory on disk" puzzle is not a puzzle.** With the root empty
  the path is not `<root>/home/holders/$$` but literally `/home/holders/$$`, and `/home` is
  root-owned — so `mkdir -p` fails EACCES, `2>/dev/null` swallows it, and `holder=""`. The
  search had been made under the real root, which by definition is not where an empty root
  puts anything. On a machine whose `$HOME` sits under a writable first component it would
  litter instead.
- **An empty `CLAUDE_ACCOUNT_DIRS_ROOT` is NOT a second way to reach the empty root**, which
  had been stated as fact. `${VAR:-default}` substitutes the default for an empty value as
  well as an unset one (measured), so the override falls back to
  `$HOME/.local/state/claude-account-dirs`. Only an unreachable helper can empty it — which
  is why the fix resolves through `$+functions` rather than merely testing for emptiness,
  and why a row pins the `:-` fallback: switching it to `${VAR-default}` would manufacture
  the state the guard now refuses.
- **The exposure is the public→private boundary, not this one line.** Stated as a figure
  anyone can re-derive with two greps rather than as a call count: `zsh/zshrc.herdr` defines
  **42** private functions and **8** public ones
  (`grep -cE '^_[A-Za-z0-9_]+\(\) *\{' zsh/zshrc.herdr`, and the same without the leading
  `_`), and in a Bash-tool shell **0 of the 42 are present and all 8 of the 8 are**. An
  earlier draft said "`claude` calls 27 private helpers and `hspawn` 35"; an independent
  review could not reproduce those under any methodology, and it was right — they came from
  a script whose function-body parser silently swallowed everything after the first
  **one-line** definition (`_claude_account_root() { … }` is one), so the bodies it counted
  over were not those functions' bodies. A per-function call count needs a real shell parser
  to be honest; the two greps do not, and they carry the whole point.
- **Only `claude`'s holder guard *failed open*.** Everything else in that shell either errors
  visibly (`hreap` prints three `command not found` lines and blank columns) or fails closed
  (`hspawn`'s builder guard is `[[ ! -x "$(…)" ]]`, so an empty result refuses the spawn
  loudly). This one matched everything, invented a name, and printed a confident line — which
  is the generalisable half: **when auditing a public/private split, look first at the sites
  whose failure mode is a *match* rather than an error.**

The fix resolves the root once into a local, requires it to be non-empty before the pattern
can match, and classifies the derived component before writing anything: rejected unless it
is a plausible profile name, is not `.` or `..`, **and** is an existing directory under the
root. **One real behaviour change falls out of that last clause, and it is not only the
refusal of invented names:** a config dir under the root whose profile directory has since
been *deleted* — the `.personal.stray-*` shape DO-604 cleanup leaves behind — used to have
that directory silently re-created by `mkdir -p` and a holder registered in it. It is now
refused with a message and no holder. That is the right trade, and it is a state someone can
meet in the field rather than a hypothetical. `..` needs naming explicitly — it passes a character class *and* a `-d` test, and
writes the pidfile above the root entirely. "Cannot tell" is its own state and says so:
registering nothing is right, doing it silently is not, since that trades a lying
announcement for an invisible absence — the same failure the count feeds.

Two things about the rows are worth more than the rows:

- **The builder stub only printed the account-dir path; the real builder creates it.** The
  new `-d` requirement therefore broke three *pre-existing* rows — correctly, because the
  fixture differed from production in the one property the guard decides on, the `reenable`
  shape this file already records. The stub `mkdir -p`s now.
- **A row naming `home` is decoration on CI.** The invented name is the first component of
  whatever `$TMPDIR` the fixture landed in, so `account 'home'` passes vacuously on a runner
  whose temp dir is `/tmp`. The rows assert that *no* account is named.

Surveyed for the same shape and **not** fixed, with the reason: `claude-account-dirs.sh:817`
(`"$GLOBAL_DIR/"*`) cannot collapse — `GLOBAL_DIR="$HOME/.claude"`, so the literal `.claude`
survives an empty `$HOME`. `verify-tools.sh:276` and `herdr-deps-check.sh:197` compare
`"$(readlink -f a)" == "$(readlink -f b)"`, and **two unresolvable paths both yield empty and
compare equal** (measured) — the hash-of-nothing class, reporting "correctly symlinked" over
two broken paths. It is unreachable today because the right-hand side is a path inside this
repo, which exists whenever the script does; recorded because that is one deleted directory
away and neither site would say anything.

Two smaller things an independent review found, fixed here rather than deferred because both
are about the same invariant. `_claude_account_builder` was still being called blind two
lines above — it fails *closed* (`[[ -x "" ]]` is false, so isolation is skipped rather than
misdirected), so it was noise and not a defect, but a row asserting "the helper is never
called blind" while its sibling is called blind in the same function is an invariant held by
half. And the refusal's second clause — "the picker will read this session's account as
idle" — is untrue when `CLAUDE_CONFIG_DIR` is empty, because isolation was skipped entirely
and there is no account to read; the two outcomes now get separate sentences.

State table: `scripts/test-hspawn.sh` (328 → 346). 9 mutants, 9 deaths, every mutation
dry-run for applicability first — and one of them, M5, **stopped matching** when the refusal
was reworded, which the harness reported as an error rather than as a survivor. That is the
rule this file already states one section up, working: a mutation that no longer applies
reads exactly like a surviving mutant.

### `claude()` exported an EMPTY `CLAUDE_CONFIG_DIR`, and no machine with clauth could see it

**On a clauth-less machine this broke Claude Code outright: every `/login` printed "Login
successful" and the box could never log in.** `claude()` opened with

```zsh
local -x CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}"
```

and `-x` exports **whatever the value is, including empty**. With clauth present the block below
assigns a real account dir, so every machine we develop on was fine. Without clauth — the
modular adopter DO-555 and DO-566 exist to serve — nothing ever assigns it, so the binary was
exec'd with `CLAUDE_CONFIG_DIR` set-and-empty and resolved its config dir from an empty string.
Unset and empty are **different things** to Claude Code: unset means `~/.claude`, empty does not.

Measured on a real box (an EC2 dev machine, 2026-09-15): the OAuth handshake completed every
time — `oauthAccount` with emailAddress, organizationName, seatTier and a fresh
`profileFetchedAt` reached `~/.claude.json` at the exact login minute, repeatedly — and the token
was never persisted. Proof, same machine, same minute, same valid credential on disk:

| invocation | result |
|---|---|
| the binary directly, wrapper bypassed | `AUTH_OK` |
| `claude`, through this function | `Not logged in · Please run /login` |

`CLAUDE_ISOLATION_OFF=1` was broken the same way, which matters more than it looks: the
documented escape hatch from isolation did not restore the previous behaviour, it exported an
empty config dir instead. So did a failed builder and "no profile has a credential".

The fix keeps the original intent — the comment arguing for `local -x` over a bare `export` was
right, an export at the top would leak the dir into the pane's shell — and moves the `-x` to
where a real value exists: `local` at the declaration, then
`[[ -n "$CLAUDE_CONFIG_DIR" ]] && typeset -x CLAUDE_CONFIG_DIR` after the isolation block.
Every path that leaves it empty now exports nothing at all, which is the byte-for-byte fallback
this file already promises a modular adopter.

**Three existing rows were decoration, and the reason is written down two sections above.** The
claude and herdmates stubs both recorded `printf 'CFG %s\n' "${CLAUDE_CONFIG_DIR:-<unset>}"` —
and `${VAR:-x}` substitutes for an **empty** value as well as an unset one, so the probe
collapsed the defect into the expected answer. `with no clauth the launch is unchanged`,
`CLAUDE_ISOLATION_OFF=1 restores the shared path` and `and it does share the global credential`
all passed while the bug was live. This is **DO-612's own finding** (`${VAR:-default}`
substitutes for empty too) reappearing inside the suite written to catch that class. The stubs
now separate three states — `<unset>`, `<empty>`, and the value — and the honest probe failed all
three rows immediately.

**The diagnostic that ends this class of hunt: compare the credential file's mtime against the
login instant.** A file that was never written cannot have been overwritten. Two earlier theories
— a blanked credential diverting the write, and failing figma/linear MCP plugins clobbering it
(both plausible; the plugins really do write `mcpOAuth` into the same unlocked file and had never
connected on that box) — each survived a fix attempt because "Login successful" was being read as
evidence of persistence. One `stat` killed both.

Rows: `scripts/test-hspawn.sh` (343 → 347), including the explicit
`and CLAUDE_CONFIG_DIR is not exported EMPTY`. 3 mutants, 3 deaths, each dry-run for
applicability first: restoring `local -x`, deleting the conditional export, and exporting
unconditionally.
