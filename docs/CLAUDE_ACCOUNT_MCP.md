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

Seven steps. Two of them need a person at a browser, and three of them fail
silently if skipped. Worked through end to end on 2026-09-30.

**1. Pick a name that has never existed.** Check `~/.clauth/profiles/` *and*
`~/.local/state/claude-account-dirs/`. A renamed profile leaves a compatibility
symlink at its old name (the 2026-09-10 rename left `quantivly-2 -> quantivly-1`),
so a free-looking slot can still resolve to another account. That kind of
cross-account mix-up is what the staged rename existed to prevent. The number in
the name does not have to match anything in the address.

**2. `clauth login <name>`** — the one step that must be done by a person.
It does not switch the machine's account. The grant goes to whichever claude.ai
account the page that opens is signed in to, so make sure that is the new account.
Then confirm it is a new seat and not a second login to an existing one. No
account id may repeat:

```bash
sha256sum ~/.clauth/profiles/*/account_id.json | awk '{print $1}' | sort | uniq -d | wc -l   # must print 0
```

`claude-doctor`'s `--- Pools ---` section makes the same check on every run, and prints a `✗`
naming both profiles.

The address shows up only after the first launch, at
`jq -r .oauthAccount.emailAddress ~/.local/state/claude-account-dirs/<name>/.claude.json`.

**3. Copy a sibling's settings into `~/.clauth/profiles/<name>/config.toml`.**
`clauth login` writes an all-commented template, while the existing seats set
`[models]`, `auto_start` and `fallback_threshold`. Match them:
`diff ~/.clauth/profiles/<name>/config.toml ~/.clauth/profiles/<sibling>/config.toml`,
then uncomment the differences. **This is what makes a session movable later.**
`clauth switch <sid> <profile>` refuses to move a live session to a profile whose
model settings differ from the ones it launched with. The refusal shows up only
in the daemon's journal (`quantivly-3 is not swappable (its model routing differs
from the launch snapshot)`); the CLI prints `pointed session … at …` either way.
A session launched on the seat before this step can never be moved in place.
`claude-doctor`'s `--- Pools ---` section compares every member of a pool on the settings that
check uses, and prints a `✗` for each difference.

**4. Add it to its tenant's pool.** The tenants file is
`~/.config/claude-tenants.zsh`, which is data outside this repo. Add the name to
`CLAUDE_TENANT_POOL[<tenant>]` and nowhere else. Leave
`CLAUDE_TENANT_MACHINE_OWNED` and `CLAUDE_TENANT_MACHINE_ID` alone unless
another machine will own the seat, and leave `CLAUDE_TENANT_BUCKETS` alone until
the new seat's usage has been measured against the others. Do this after step 2,
so the pool never names a profile with no credential. Then check the file: a
tenants file that exists and cannot be read refuses every launch.

```bash
zsh -n ~/.config/claude-tenants.zsh && scripts/machines-render --check
```

**5. Build and verify.** Run `scripts/claude-account-dirs.sh <name>`. Then
`claude-doctor` should print `✓ <name>: credential shared with the clauth store`,
and `claude-pick --explain --dry-run` from one of that tenant's repos should list
the new name in the pool.

**6. MCP servers.** A profile's `mcpOAuth` entries are its own, so a fresh one
starts with none. There are two kinds of server, and they behave differently:

- **Plugin servers (Slack, Notion, Linear): authorise once, from a session on
  the new profile.** Use `/mcp`, or the server's `authenticate` tool, which hands
  back a URL. The redirect goes to `localhost` and claude.ai is not involved, so
  it does not matter which claude.ai account the browser is on. Sign in to the
  service as yourself. `claude-doctor` then shows
  `✓ plugin:<server>: valid in …, refreshable`, and the token covers every
  session on that profile.
- **claude.ai connectors are saved to the claude.ai account the BROWSER is signed
  in to, not to the seat the session runs on.** With the browser on your main
  account, `/mcp` → *claude.ai Slack* completed and looked successful, while the
  session still got `mcp_unauthorized_no_token`: the grant had gone to the main
  account. So for Slack, Notion and Linear use the plugin servers above. This
  section used to recommend the connectors, which is wrong for a new seat. For a
  service with no plugin server here (Gmail, Calendar, Drive, Fireflies, Figma),
  use a separate browser profile signed in to claude.ai *as the new account*, and
  connect from Settings → Connectors there. If the new address is a Workspace
  alias, it has no Google login of its own: sign in to claude.ai by emailed link,
  and when the service asks for Google, use your normal Google account. That half
  has not yet been verified end to end.

**7. Watch where the next launches land.** A fresh seat's week is empty. If
that week also resets within a couple of days, the picker's consume-first bonus
(DO-621) is worth up to twice the entire 5h score. Meanwhile each session already
on a seat whose 5h reads 0% costs it only 300 points. At the 2026-09-29 restore
that put the new seat 14,050 points ahead, roughly fifty sessions' worth, so every
session restored after the reboot landed on it. Sessions keep the seat they
launched on. So the new seat's 5h window was spent the next morning while two
sibling seats sat at 0%, and every session on it stopped at the same moment.
Until [DO-792](https://linear.app/quantivly/issue/DO-792) changes the weights,
expect this after every seat added mid-week. `claude-doctor`'s concurrency
section shows the count. See
[Moving sessions off a spent seat](#moving-sessions-off-a-spent-seat) below.

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
