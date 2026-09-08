# Claude Code accounts & MCP: runbook

Companion to the **Claude Code accounts & MCP (`claude-doctor`)** section of
[CLAUDE.md](../CLAUDE.md), which carries the mechanisms and the traps. This file
is the operational half: what to run, what to click, and what to do when
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
  `scripts/claude-account-dirs.sh`, and prints which account it took. The profile
  is the registered one with the fewest live sessions, so sessions spread rather
  than piling onto whichever account happens to be active.
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

**How many groups you get is how many logins you have.** Four profiles against
18–30 concurrent sessions means groups of five to seven; `clauth login <name>`
is the only thing that makes them smaller. `claude-doctor`'s concurrency section
prints the current grouping, and the number to drive to zero is the one on
**the SHARED global file** — it was 17 of 18 when this was written.

### Adopting a new profile

A profile's `mcpOAuth` entries are its own, so a fresh one starts with none and
`claude-doctor` lists each plugin MCP server as *never authorised in this config
dir*. Two ways to settle that, and the second is usually right:

1. Authorise each server once from `/mcp` inside a session on that profile.
2. Use the **claude.ai connector** for that service instead of the plugin MCP
   server. Connectors ride the login token, need no per-config-dir OAuth at all,
   and `claude-doctor` already warns that Linear, Notion and Slack are reachable
   on both paths.

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
