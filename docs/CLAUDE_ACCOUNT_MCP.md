# Claude Code accounts & MCP: runbook

Companion to the **Claude Code accounts & MCP (`claude-doctor`)** rules in
[CLAUDE.md](../CLAUDE.md). The mechanisms and the traps behind them are in
[CLAUDE_ACCOUNTS.md](CLAUDE_ACCOUNTS.md) and [CLAUDE_ACCOUNT_PICKER.md](CLAUDE_ACCOUNT_PICKER.md).
This file is the operational half: what to run, what to click, and what to do when
something drops.

`claude-doctor` is the entry point. It is read-only — it switches no profile,
writes no config and refreshes no token — and it reports **effect**, read from
the log store Claude Code already writes, never from configuration.

```bash
claude-doctor              # auth + MCP health
claude-doctor --all        # include the servers that are fine
claude-doctor --days 30    # widen the MCP window from the default 7
```

---

## 1. The one rule

**Prefer `claude-as <profile>` to `clauth <profile>`, and run `claude-doctor`
before you use the latter at all.**

`claude-as` puts *your* session on that account and touches nothing else.
`clauth <profile>` rewrites the machine-wide `~/.claude/.credentials.json` under
every session still using it — which is the mechanism behind the mass logouts, not
a side effect of them. Of the nine login-expiry incidents in the eight days to
2026-09-06, five hit 3–6 sessions **at the same instant**.

A profile switch restores that profile's *stored* tokens over the live ones.
Claude Code rotates refresh tokens, and clauth only notices on a ~90 s poll, so
between a rotation and that poll the stored copy is a **superseded** token.
Restoring it can log out every running session at once.

If the doctor says:

```
⚠ stored copy of '<profile>' DIFFERS from the live credential
```

…wait for clauth's poll and re-run, rather than switching. If it says
`matches the live credential`, a switch is safe.

---

## 2. One-time cleanup

These cannot be done from the shell — the claude.ai connectors are configured
server-side and are fetched with your login. Do them at
**claude.ai → Settings → Connectors**.

### 2.1 Remove the dead Linear connector

Its server id has gone dead upstream: it returns `mcp_endpoint_not_found` on
every call while still advertising a full tool list, so nothing about the tool
list reveals it. Measured 1,936 failures, and 136 failures against 0 successes
on the day it was found.

Either **remove** it (the `linear` plugin's own MCP server already works and
holds a valid token) or **remove and re-add** it so a fresh id is issued. Do not
leave both a dead connector and a working plugin in place.

### 2.2 The `authenticate`-only connectors are the catalogue, not your config

An earlier draft of this file said to disconnect these twelve:

> Apollo.io · Attio · Canva · Clay · Doc360 · Figma · Granola · HubSpot ·
> Lightfield · Miro · Superhuman Mail · Sybill

**That was wrong, and checking beats inferring.** They surface in the session's
tool list as `authenticate` / `complete_authentication` pairs, which reads like
twelve broken servers. They are not connected at claude.ai at all — they are the
*available connector catalogue*, advertised so a session can offer to set one up.
There is nothing to disconnect, and the two stub tools each are the cost of the
offer, not evidence of a fault.

An earlier version of this page said a connector you have merely been *offered*
"writes nothing" to the log store, so its presence there proved you had connected
it. **That is false.** Every advertised connector is attempted and logged: Apollo,
Attio, Canva and the rest had **24 attempt files each** — Miro 73 — all ending in

```
authentication_error … error_code: mcp_unauthorized_no_token
```

So presence in the log store proves nothing, and neither does volume — a
minimum-attempts floor was tried and does not separate them. **The error code is
the only discriminator**, and there are three failing states worth telling apart:

| in the logs | means | what to do |
|---|---|---|
| `mcp_unauthorized_no_token` on every attempt | never authorised — offered, not configured | nothing; `claude-doctor` shows it only under `--all` |
| `OAuth token has been invalidated` | it *did* work and the token died | re-authenticate from `/mcp` or at claude.ai |
| `mcp_endpoint_not_found` | the connector id is dead upstream | remove and re-add it at claude.ai (the Linear case, §2.1) |
| anything else with 0 successes | genuinely broken | diagnose from the newest log (§4) |

To list every connector that has ever been attempted:

```bash
ls -d ~/.cache/claude-cli-nodejs/*/mcp-logs-claude-ai-* | sed 's#.*mcp-logs-##' | sort -u
```

`claude-doctor` applies that table, so a never-authorised connector stays quiet by
default and only the last three rows raise a `✗`.

**One trap if you grep these logs by hand:** the claude.ai proxy writes lowercase
`connection failed`, while stdio and HTTP servers write `Connection failed`. A
case-sensitive grep for the capitalised form finds nothing for any claude.ai
connector — which is exactly how the first attempt at this fix became a silent
no-op.

### 2.3 Pick one path per duplicated service

Linear, Notion and Slack are each reachable **twice** — once as a claude.ai
connector, once as a plugin MCP server. That is two credentials, two failure
modes and two tool surfaces for one capability.

Decide from the log store, not from which one shows tools:

```bash
claude-doctor --all --days 30      # per-server success/failure counts
```

Note before removing a plugin: `notion`, `slack` and `desktop-commander` also
ship **skills and slash commands**, which go away with the plugin. `linear` and
`github` are MCP-only, so disabling those costs nothing but the server.

| service | plugin also brings | current reading |
|---|---|---|
| Linear | nothing (MCP only) | keep the **plugin**; the connector is dead |
| Notion | 1 skill, 6 commands  | keep the plugin for the skills; drop one MCP path |
| Slack  | 7 skills, 5 commands | keep the **plugin**; it is the only working Slack |

### 2.4 Re-authenticating one server can blank the others — check all three

A server left with a **zero-length `accessToken`** and no
`refreshToken`/`expiresAt`/`scope` cannot renew itself and needs a manual
re-auth: `/mcp`, select it, authenticate.

**Then immediately check every other entry.** Observed on 2026-09-06, about an
hour apart:

| time  | slack | Notion | linear | Claude procs |
|-------|-------|--------|--------|--------------|
| 11:00 | `expiresAt: null`, no refresh | valid 23 h | valid 23 h | 25 |
| 11:38 | token length 0 | **entry absent** | **entry absent** | 26 |
| 12:00 | valid 11 h (re-authed) | token length 0 | token length 0 | 27 |
| 12:09 | valid 11 h | valid 23 h (re-authed) | valid 23 h (re-authed) | 30 |

A 23-hour token does not expire into a blank string, and entries do not vanish
and reappear on their own. Every server's OAuth token lives in the *same*
unlocked file as the login, so a write that fixes one can carry a stale copy of
the rest — fixing Slack is when Notion and linear went blank.

**And the last row is why you check rather than follow a rule of thumb.** Two
back-to-back re-auths at the highest concurrency of the day left all three
intact. It is a race: more writers raise the odds of losing it, they do not
decide it. A clean run proves nothing about the next one.

So the check after any `/mcp` authentication is all of them, not the one you
just fixed:

```bash
claude-doctor | sed -n '/MCP OAuth entries/,/^$/p'
```

---

## 3. Routine health

Run `claude-doctor` when something feels wrong, and always before a profile
switch. What its findings mean:

| finding | meaning | action |
|---|---|---|
| `accessToken is EMPTY` | interleaved write, not an expiry | re-auth that server from `/mcp` |
| `no refreshToken` | it can only die and need manual re-auth | re-auth; expect recurrence until concurrency drops |
| `0 successful connections in N attempts` | this server has **never** worked in the window | see §4 |
| `stored copy ... DIFFERS` | a switch now can log out every session | wait for clauth's poll, re-run |
| `N Claude processes ... no lock` | the race is likely at this concurrency | `hreap` and close what you are done with |
| `configured on BOTH` | duplicate service | §2.3 |
| `pool '<t>': '<b>' differs from '<a>' in …` | in-place `clauth switch <sid>` between them is refused, in the journal only | make the two `config.toml` files agree (§5, step 3) |
| `pool '<t>' names '<n>', a compat symlink` / `a retired name` / `which has no clauth profile store` | the picker drops that name without a word | put the real profile's name in the pool, or remove it |
| `profiles '<a>', '<b>' are logged in to the SAME account` | two names for one seat | `clauth delete` the newer one, and drop it from its pool |
| `'<b>' is in a different organisation` / `a claude_max account in a pool of team seats` | the login went to the browser's claude.ai account, not the seat | `clauth login <b>` again with the browser on the right account |
| `'<b>' is not signed in to plugin:…, which another member uses` | that seat never signed in to a plugin server its pool uses | `claude-as <b>`, then `/mcp` |
| `'<b>' has broken plugin MCP sign-ins: …` | a token blanked by a lost write, or one with no refresh token | re-authorise from a session on it, then §2.4 |

---

## 4. When an MCP server is dead

**Stdio servers are never auto-reconnected.** If one dies at session start it
stays dead for the whole session. Remote (HTTP/SSE) servers retry five times
with 1/2/4/8/16 s backoff and can be retried by hand from `/mcp`.

Diagnose from the per-server log — it is already being written, and reading it
is the whole reason the two long-running failures below went unnoticed:

```bash
ls -t ~/.cache/claude-cli-nodejs/*/mcp-logs-<server>/*.jsonl | head -1 | xargs tail -20
```

`Successfully connected` versus `Connection failed` is the only pair that
distinguishes health. **Attempt count is not health**: a server that has never
worked writes exactly as many log files as one that always does.

### A stdio server that fails with `ENOTEMPTY`

An npx cache corrupted by a half-finished install. This kept
`plugin:desktop-commander` at **0 successes in 509 attempts across 34 days**,
in every working directory, with every status surface green.

```bash
# find the cache dir that is missing its lockfile — that is the corrupt one
for d in ~/.npm/_npx/*/; do
  [ -e "$d/node_modules/.package-lock.json" ] || echo "CORRUPT: $d"
done
rm -rf ~/.npm/_npx/<hash>          # remove the WHOLE tree, not one package
```

Remove the whole tree: the blocking rename moves to the next stale sibling
otherwise (`md-to-pdf` ×275, then `pdf-lib` ×29, then `pizzip`).

Verify with a real MCP handshake rather than `--version`:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
  | npx -y @wonderwhy-er/desktop-commander@latest | head -c 400
```

A `"result"` carrying `serverInfo` is a working server.

---

## 5. Reducing the race

Every Claude session on the shared `~/.claude/.credentials.json` is one more
member of the group that a single bad write destroys.

- **`claude` isolates by default.** It runs in
  `~/.local/state/claude-account-dirs/<profile>/`, built on demand by
  `scripts/claude-account-dirs.sh`, and prints which account it took. Which
  account that is comes from the picker below — not from "whichever is active",
  which inside an isolated pane means *this* session's own profile and would herd
  every launch into its parent's credential group.
- **`claude-as <profile>`** does the same on a named account.
- **`hspawn` isolates by default** and, since 2026-09-06, its workers can also
  **lead a herdr team** — it launches `CLAUDE_CONFIG_DIR=<dir> claude` rather than
  `clauth start`, so the pane's own `claude()` supplies `teammateMode: tmux`.
- **`hspawn --shared`** and **`CLAUDE_ISOLATION_OFF=1`** opt back in to the shared
  credential. Needed only when there is no clauth profile to use.
- **`clauth start <profile>`** remains the *supervised* path, and is the only one
  with `--with-fallback` quota rotation. It launches the claude binary directly,
  so it never reaches `claude()` and cannot lead a team.
- **`hreap`** enumerates Claude processes in herdr panes with idle age and
  memory; `hreap --close --mine` closes your own idle spawns. An idle agent
  still holds its memory *and* still refreshes its token.

**How many groups you get is how many logins you have.** Seven profiles (2026-09-30; the
number moves, `clauth list` has today's) against 18–30 concurrent sessions; `clauth login <name>`
is the only thing that makes them smaller. `claude-doctor`'s concurrency section
prints the current grouping, and the number to drive to zero is the one on
**the SHARED global file** — it was 17 of 18 when this was written.

### Which account a launch takes, and how to ask before launching

The choice is a score, not a sort, and `claude-pick` is the same code path as a
command — so you can ask what a directory would get without starting anything:

```bash
claude-pick                       # the profile name, one line
claude-pick --explain             # ...and the per-candidate table, on stderr
claude-pick --dir ~/work/api --json --dry-run   # what herdr-draft asks
```

`--dry-run` writes no round-robin ledger entry and builds no account dir, so it
is safe to run repeatedly.

**What the score is made of.** 5h headroom is the backbone; a window close to its
reset earns a use-it-or-lose-it bonus *scaled by how much headroom is left*, so a
nearly-spent window resetting soon earns almost nothing; weekly headroom is a
**multiplier**, so a spent week sinks an account below anything with room while
leaving it choosable when it is all there is; and each live holder costs more on
an account that is already busy. Accounts within `CLAUDE_PICK_RR_BAND` of the top
score are treated as tied and the **least recently picked** wins, which is what
stops every session in a quiet minute landing on the same seat.

**The classes matter more than the score.** `excluded` (disabled, or quarantined
by clauth as `auth_broken`) is never chosen. `unknown` — no usage cache, or one
older than `CLAUDE_PICK_CACHE_MAX_AGE` — ranks after *every* measured candidate
but is still chosen when nothing else is left. `exhausted` means the 5h window is
spent, and that is where the two callers deliberately differ:

| caller | an exhausted pool |
|---|---|
| `claude`, `claude-as`, `claude-pick` | proceeds on the least-bad member and prints a loud block saying so |
| `hspawn`, `claude-pick --strict`, herdr-draft | **refuses**, naming each member's window and the earliest reset |

A human blocked by a window that clears itself in minutes is the worse outcome; a
worker started on a spent window burns the seat and dies mid-task with nobody
watching. The escape from the refusal is `-p <profile>` / `--profile <p>`, which
skips the ranking entirely — it still warns on stderr when the account you named
is spent or quarantined, but it never refuses, because overriding the ranking is
what the flag is for.

**A reset time it will not print.** Where a member's window has already rolled,
the report says *"5h window already rolled — this reading is stale"* rather than
naming a moment in the past — the usage figure beside it belongs to the previous
window. That is the ordinary state of a cache nobody has refreshed, not an edge
case. Where no reset instant is known at all (which is what an unstarted window
looks like), it says so and offers no retry time, because the alternative is the
same invented date for every account.

**Exit codes**, which is how herdr-draft's `--on-failure` decides what to say:
`0` picked · `2` refused, exhausted · `3` refused, a machine ceiling ·
`4` the tenant table is unusable (a fix in `~/.config/claude-tenants.zsh`) ·
`5` no profile has a credential (`clauth login <name>`) · `64` usage error.

**Backpressure is warn-only.** `claude-pick --explain` prints the machine's load
and swap, and every caller warns past `CLAUDE_PICK_LOAD_WARN` (150% of threads)
or `CLAUDE_PICK_SWAP_WARN` (60%), but nothing refuses unless
`CLAUDE_PICK_LOAD_MAX` / `CLAUDE_PICK_SWAP_MAX` is explicitly set. This box is
deliberately oversubscribed; the picker's job is to choose an account, not to
police the machine.

**The usage numbers are as fresh as the daemon's last poll — 90 s while
`clauth-daemon.service` runs, the last TUI open when it does not.** There is no
`clauth refresh`: clauth's only writer of `usage_cache.json` is lease-gated to its
TUI and its daemon. So a profile whose cache has aged past the threshold silently
stops being ranked, and `claude-doctor` reports the oldest age on every run
precisely because nothing can be done about it from a script. If the picker's
choices look arbitrary, check that line first, then the daemon unit.

### Adding an account to the pool

One command, plus the steps only a person can do. On 2026-09-30 this took a whole
session by hand, and three of its seven steps failed silently when skipped.

```bash
scripts/claude-seat add --dry-run <tenant>    # propose a name, show the plan
scripts/claude-seat add <tenant>              # do it
```

**Before it: create the seat.** That means the Workspace alias, the Team invite,
and accepting the invite by emailed link. Team has no API for any of it.

**What the command does,** in this order. The pool is the last thing it touches,
so the pool never names a seat that failed a check. Each step checks the state
first, so a run that stopped can be run again with the same name.

1. **Name.** It proposes the tenant's prefix with the next number nobody has used,
   or checks the one you give. A name is never reused: one that exists anywhere
   as a profile, an account dir, a compat symlink, a retired dir, a tenant-table
   entry, rabota's seat or the picker's ledger is refused. A renamed profile
   leaves a compat symlink at its old name (the 2026-09-10 rename left
   `quantivly-2 -> quantivly-1`), so a free-looking slot can resolve to another
   account. The name must also fit rabota's prefix rule.
2. **Login: `clauth login <name>`, the one step a person does.** The grant goes
   to whichever claude.ai account the page is signed in to, so open the URL clauth
   prints in a browser profile signed in to claude.ai **as the new seat**.
3. **Distinct.** The new account id must repeat no other profile's: a second login
   to an existing seat is refused.
4. **Settings.** It copies the pool's `config.toml`. `clauth login` writes an
   all-commented template, and `clauth switch <sid> <profile>` refuses to move a
   live session between seats whose `[models]` differ. The refusal appears only in
   the daemon's journal (`… is not swappable (its model routing differs from the
   launch snapshot)`), while the CLI prints `pointed session … at …` either way.
5. **Account dir.** It runs `scripts/claude-account-dirs.sh <name>`, and checks
   that the credential is a link into the store.
6. **Identity.** It reads the seat's account and organisation, from
   `claude auth status`, or with `--yes` from one tiny first launch. For a pool of
   team seats, the new one must be a team seat in the same organisation:
   anything else is the browser's account, not the seat. `--email <addr>` also
   checks the address.
7. **Pool.** It adds the name through `scripts/claude-tenants-edit` (below) and
   commits the tenants file alone. Then it confirms with the picker's dry run.

**After it: the steps that stay manual.** The command prints them.

- **Plugin MCP servers (Slack, Notion, Linear).** Run `claude-as <name>`, then
  `/mcp`, and sign in to each server the other seats use. The redirect goes to
  `localhost`, so it does not matter which claude.ai account the browser is on.
  `claude-doctor`'s `--- Pools ---` section names any server a sibling uses that
  this seat is not signed in to.
- **claude.ai connectors (Gmail, Calendar, Drive) follow the tenant.** The
  claude.ai side is the seat; the Google side is the tenant's identity. A
  connector authorised from `/mcp` is saved to the claude.ai account the
  **browser** is on: with the browser on the main account, it "succeeded" and the
  seat still got `mcp_unauthorized_no_token`. So connect from claude.ai →
  Settings → Connectors in a browser profile signed in as the seat. Record each
  tenant's connectors in `CLAUDE_TENANT_CONNECTORS` and
  `CLAUDE_TENANT_CONNECTOR_ACCOUNT`, and the command will name them.
- **Watch where the next launches land.** A fresh seat's week is empty. If that
  week also resets within a couple of days, the picker's consume-first bonus
  (DO-621) is worth up to twice the entire 5h score, against 300 points per
  session already on a seat whose 5h reads 0%. At the 2026-09-29 restore, that put
  the new seat 14,050 points ahead, and every restored session landed on it.
  Sessions keep the seat they launched on, so its 5h window was spent the next
  morning while two siblings sat at 0%. Until
  [DO-792](https://linear.app/quantivly/issue/DO-792) changes the weights, expect
  this after every seat added mid-week. See
  [Moving sessions off a spent seat](#moving-sessions-off-a-spent-seat) below.

**The tenants file by hand: `scripts/claude-tenants-edit`.** `claude-seat` uses
it, and it is the way to change a pool directly:

```bash
scripts/claude-tenants-edit --dry-run pool-add <tenant> <name>   # see the change
scripts/claude-tenants-edit --commit  pool-add <tenant> <name>   # make and commit it
```

It changes one pool line and nothing else. It refuses a name that has no profile
store, is machine-owned, is a compat symlink or is retired. It never empties a
pool. It writes only after checking a copy: the copy parses, loads cleanly the way
a launch loads it, and differs from the original by exactly that change. It keeps
a backup under `~/.local/state/claude-tenants-edit/`. `pool-remove` and
`retire-name` work the same way, and a retired name goes into
`CLAUDE_TENANT_RETIRED` so it is never handed out again.

Leave `CLAUDE_TENANT_MACHINE_OWNED` and `CLAUDE_TENANT_MACHINE_ID` alone unless
another machine will own the seat. Leave `CLAUDE_TENANT_BUCKETS` alone until the
new seat's usage has been measured against the others.

### Moving sessions off a spent seat

- **A `clauth start` session** (its config dir is
  `~/.clauth/profiles/<p>/runtime-<pid>-<seq>`) moves in place with
  `clauth switch <sid> <profile>`, at its next request, with nothing restarted.
  This only works when the two profiles' model settings match (step 3). Confirm
  it moved from `current_member` in `~/.clauth/live_sessions/<sid>.json` or from
  the daemon journal, not from the CLI's reply.
- **Any other session** has to be stopped and resumed. Type `/exit` in its pane,
  then relaunch it the way it was started: `claude-as <p> --resume <id>` for a
  `claude()` session, `clauth start <p> -- --resume <id>` for a clauth one. The
  transcript survives, but whatever was running in the process does not. So
  check first for a background shell (`ps -o pid,etime,comm --ppid <pid>`) and
  for a subagent the limit stopped partway (its transcript sits under
  `<transcript-dir>/<session>/subagents/`). Leave a session with either one until
  the reset.
- **A session that is not blocked has nothing to gain from moving.** A session
  waiting on you uses no quota. Resume it on another seat when you next need it.
- `claude()` keeps an inherited `CLAUDE_CONFIG_DIR`, so check that the pane's
  shell does not export one before relying on `claude-as` there.

---

## 6. What not to do

**Do not put MCP or auth environment variables in `~/.claude/settings.json`'s
`env` block.** clauth merges a profile's `[env]` into it on switch and **clears
it on switch away** — it is `{}` for that reason. Anything set there is silently
wiped at the next profile switch. Use `zsh/zshrc.herdr` instead.

**Do not reach for `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN`** as a fix
for the logouts. It is a one-year token with no refresh and no race, which makes
it tempting — but the documentation is explicit that it *"can only make model
requests, so it can't establish Remote Control sessions or fetch claude.ai
connectors."* It would trade the logouts for permanently dead connectors.

**Do not read an empty `accessToken` as damage on its own.** An `mcpOAuth` entry
with an empty token and **no** `expiresAt`, `scope` or `refreshToken` is a
*discovery record* — a server nobody has authorised in this config dir yet, which
is the normal starting state for every isolated session. Only an empty token that
**kept** its `expiresAt`/`scope` is the fossil of a lost race. `claude-doctor`
distinguishes them; a person reading the file by hand should too.

**Do not measure `/login` recoveries by grepping transcripts without excluding
the running session.** The pattern `<command-name>/login</command-name>` gets
written into the current transcript by the grep itself, so the number climbs as
you measure it.
