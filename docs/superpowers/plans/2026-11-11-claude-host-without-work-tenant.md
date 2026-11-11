# host-sync on a host that serves no work tenant — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scripts/host-sync` report truthfully on a host whose profile serves no work tenant and
that was set up without sudo, and give it the GitHub-token row the design promised (D11), so program
step 8 (the third host joins) can be verified the way dev was.

**Architecture:** Two row changes in the host half of `scripts/host-sync`, each pinned by rows in its
hermetic state table, and one documentation task. No new script, no new unit, no `install.conf.yaml`
change. The host-specific procedure (what is run on which machine, in which order) is a private
runbook and is not part of this repository.

**Tech Stack:** bash (`set -uo pipefail`), jq, `gh api`, GNU and uutils `date -d`, the existing
recording stubs of `scripts/test-host-sync.sh`.

**Spec:** `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md` — D8 (amendments H1–H11),
D11, "Sequencing" item 8, "Verification".

Revision 2, 2026-11-11, after an independent review (1 Critical, 9 Important, 11 Minor; the ones
that concern this document are folded in: the rows of Task 1 and Task 2, every mutant's
attribution, the empty-header case, and the design items Task 3 records).

## Why this PR exists (measured 2026-11-11, read-only, on the host that joins next)

Probing the next host before planning, as step 7 did for dev, found three things `host-sync` gets
wrong or leaves out there. None blocks a first run; each leaves a row that is false or missing forever.

1. **The Linear row demands a work credential on a host that must hold none.** `here_mcp` prints
   `⚠ LINEAR_API_KEY is not in this host's ~/.zshrc.local … add it by hand` on every laptop-driven
   run, whatever the profile. `claude/settings/base.json` enables `linear-key@dotfiles` for every
   profile, so the plugin is installed there, and the row then asks a person for a key the host's
   tenant boundary forbids. `here_clones` already skips the work clones under the same condition
   (`tenants_exclude "$WORK_TENANT"`).
2. **D11's token row was never built.** The design says of that host's GitHub token: "`host-sync`
   reports its age as it does the Claude token's". Nothing in `host-sync` reads it. GitHub does not
   expose a token's creation date; it does send `Github-Authentication-Token-Expiration` on every
   authenticated response for a token that expires. Measured on the host:
   `gh api --include user --jq .login` prints `HTTP/2.0 200 OK` (no CR), 26 header lines each ending
   in CR, a CR-only line, then the login (no CR); the value has the shape
   `YYYY-MM-DD HH:MM:SS UTC`; a token with no expiry sends no such header. GNU `date` 9.4 and uutils
   `date` 0.10 both parse that value, with or without a trailing CR, and both parse an empty string
   as today.
3. **The documented first run assumes a host that already has a checkout.** `host-sync` answers a
   host with no `~/.dotfiles` with "bootstrap it (scripts/server-bootstrap.sh)", and that script
   requires sudo. A host without sudo is bootstrapped by hand, and that path has traps: zsh is a
   hard requirement (`scripts/tenant-route` and `scripts/gh-route` are zsh scripts, and the memory
   link and sync call them); sshd runs every remote command, forced commands and sftp included,
   through the login shell, and a zsh login shell reads only `~/.zshenv` for them, so a `PATH` the
   old shell's rc file supplied disappears with a `chsh`; `./install` creates `~/.gitconfig.local`
   from an example whose `[user]` block is a placeholder, and replaces `~/.gitconfig`, so commits
   made afterwards carry the placeholder identity unless the file exists first; `./install` creates
   `~/.zshrc.local` from the workstation template, which starts an `ssh-agent` in every shell that
   has none; `./install` links the full mise tool list when mise is present and no config exists,
   and the herdr server's launcher puts every mise directory ahead of the system's on every pane's
   `PATH`; and `host-sync` never runs `scripts/herdr-claude-wire.sh`.

## Global Constraints

- bash with `set -uo pipefail`; no GNU-only `grep` or `awk` extension (`grep` is a `ugrep` shim and
  `awk` is mawk on the laptop; CI has GNU). No variable named `PROMPT`.
- A row never prints a credential. The new row reads one response header and the login name, never
  `hosts.yml`, never `gh auth token`, never `gh auth status`.
- Rows: `row ok|drift|oper|info <area> <message>`; `oper` (⚠) is a person's step and does not change
  the exit status; exit 0/1/2/64 keep their meaning; "could not run" is exit 2, never a pass.
- `scripts/test-host-sync.sh` stays hermetic under its fixture `HOME`, asserts its own row total
  (`EXPECTED_ROWS`, 649 today, all passing at `20b6ad0`), and every existing row passes unchanged. A
  row that fails because a new line appears in the output is fixed by making its needle specific,
  never by dropping the line.
- A needle is unique to the rule it pins, carries the row's glyph where the row's KIND is the rule,
  and is checked against what the pass path prints. Every mutant gets an expected verdict for both
  environments (GNU on CI, uutils on the laptop), is dry-run for applicability and diffed against
  its name, and is run one at a time under `setsid timeout --kill-after=5 <cap>` in a copy under
  `~/.cache/tmp/mutant-<id>`; commit before the sweep. Read the tally line, never a count of marks.
- Never run the renderer, the link or sync scripts, `./install` or `host-sync --apply` against the
  real machine from a test or a probe.
- Names say what a value means; a literal with a role is a named constant with its unit; new and
  modified functions carry a comment saying what they take, set and return.
- No pre-commit hook runs on commit in a dotfiles worktree: run `pre-commit run --all-files`
  explicitly, and `./scripts/check-claude-md.sh`.
- Nothing about a personal tenant, its repositories or its hosts' private details goes into this
  repository or into Quantivly's Linear: the text here speaks of "a host that serves no work tenant".

## Review Focus

1. **Tenants unknown must fail closed.** With a marker and no overlay checkout the profile's tenants
   are unknown; the Linear row must stay the ⚠, never the information row (Task 1, row L4).
2. **A `gh` that hangs.** The call is bounded, the row says it did not answer, and the hung child
   does not finish its work behind the run's back (Task 2, row G9).
3. **An expiry that is empty or that `date -d` cannot parse.** A ⚠ naming the unreadable value,
   never "expires today" and never an arithmetic error under `set -u` (Task 2, rows G7 and G14).
4. **Header spelling and line endings.** GitHub's capitalised name and an all-lower-case one both
   parse, and no CR reaches a printed row (Task 2, rows G3, G10 and G13).
5. **Where clauth manages accounts, `gh` is routed per directory.** No `gh` call and no row there: a
   host-wide answer would be whichever account the working directory routes to (Task 2, row G11).

---

### Task 1: The Linear key row applies only where the work tenant is served (H12)

**Files:**
- Modify: `scripts/host-sync` (`here_mcp`, and the `LINEAR_API_KEY` bullet of the header's "WHAT IT
  WILL NOT DO" list)
- Test: `scripts/test-host-sync.sh` (section `== MCP sign-ins and LINEAR_API_KEY`, `EXPECTED_ROWS`)

**Interfaces:**
- Consumes: `tenants_exclude <tenant>` (0 when the profile's tenants are known and leave it out),
  `WORK_TENANT`, `row`.
- Produces: the information row
  `linear-key: no LINEAR_API_KEY is expected on this host (its profile serves no <WORK_TENANT> tenant)`.

- [ ] **Step 1: Write the failing rows** in the MCP section, after the existing
  "a key in the CALLER's environment" row. Fixture for L1–L3: `new_case`, then
  `echo '{"tenants":["personal"]}' >"$H/.dotfiles-local/hosts/p.json"`. That fixture also prints a
  ⚠ and a ✗ in the `memory` area (the stores of the table no longer match the profile), so no row
  here asserts on the summary lines.

  | row | fixture | assertion |
  |---|---|---|
  | L1 | empty `~/.zshrc.local` | `has "$OUT" "· mcp            linear-key: no LINEAR_API_KEY is expected on this host (its profile serves no quantivly tenant)"` |
  | L2 | same run | `hasnt "$OUT" "LINEAR_API_KEY is not in this host's"` |
  | L3 | `~/.zshrc.local` exporting `$FAKE_KEY` | `hasnt "$OUT" "LINEAR_API_KEY is set"`, and `hasnt "$OUT" "$FAKE_KEY"` (two rows) |
  | L4 | `new_case`, empty `~/.zshrc.local`, `rm -rf "$H/.dotfiles-local"` (marker kept: tenants unknown) | `has "$OUT" "⚠ mcp            LINEAR_API_KEY is not in this host's ~/.zshrc.local"` |

  Five rows. `EXPECTED_ROWS` 649 → 654.

- [ ] **Step 2: Run the table, expect L1–L3 to fail and L4 to pass**

  Run: `bash scripts/test-host-sync.sh 2>&1 | tail -n 5`
  Expected: the tally reads 650 passed and 4 failed.

- [ ] **Step 3: Implement.** In `here_mcp`, after the slack/notion loop and before the key is read:
  when `tenants_exclude "$WORK_TENANT"`, print the information row and return 0 without sourcing
  `~/.zshrc.local`. Update the header bullet to say the key is checked only where the profile
  serves the work tenant or the tenants are unknown.

- [ ] **Step 4: Run the table**

  Run: `bash scripts/test-host-sync.sh 2>&1 | tail -n 5`
  Expected: 654 rows, all ✓, exit 0.

- [ ] **Step 5: Three mutants, one at a time, each KILLED by the row named, in both environments:**
  the new branch deleted (L1); `tenants_exclude` replaced by `! has_tenant` (L4); the row's kind
  `info` → `oper` (L1, whose needle carries the `·`).

- [ ] **Step 6: Commit**

  ```bash
  git add scripts/host-sync scripts/test-host-sync.sh
  git commit -m "Ask for the Linear key only where the work tenant is served"
  ```

### Task 2: A `gh` row for the GitHub token's expiry (H13)

**Files:**
- Modify: `scripts/host-sync` (constants beside `TOKEN_WARN_D`; new `here_gh_token`; one call in
  `here_rows` after `here_auth`; the header's rows paragraph and its test-override list)
- Test: `scripts/test-host-sync.sh` (`write_stubs` gains a `gh` stub; a new section
  `== the GitHub token`; `EXPECTED_ROWS`)

**Interfaces:**
- Consumes: `CLAUTH_DIR`, `row`.
- Produces:
  - constants `GH_BIN="${HOST_SYNC_GH_BIN:-gh}"`, `GH_API_TIMEOUT_SECONDS="${HOST_SYNC_GH_TIMEOUT_S:-30}"`,
    `GH_TOKEN_WARN_DAYS="${HOST_SYNC_GH_TOKEN_WARN_D:-14}"`,
    `GH_EXPIRY_HEADER='github-authentication-token-expiration'`, `SECONDS_PER_DAY=86400`;
  - `here_gh_token` — no arguments; prints at most one row in area `gh`; always returns 0.

**The rule `here_gh_token` implements, in order:**

1. `~/.clauth` exists → no row, no call (H9's reason: `gh` is routed per directory there).
2. `GH_BIN` is not on `PATH` → `row info gh "no gh on this host"`.
3. In a subshell that has changed to `$HOME`: `timeout "$GH_API_TIMEOUT_SECONDS" "$GH_BIN" api --include user --jq .login`,
   stdin from `/dev/null`, stderr discarded. Unless the first line matches `^HTTP/[0-9.]+ 200`:
   `row oper gh "gh did not answer for this host's GitHub login (gh api user): its token may be missing, revoked or expired"`.
4. Strip every CR from the answer. The login is the last non-empty line; shown as `?` unless it
   matches `^[A-Za-z0-9-]+$`. The expiry is the value of the header whose name equals
   `GH_EXPIRY_HEADER` compared case-insensitively.
5. No such header → `row ok gh "logged in as <login>; its token carries no expiry"`.
6. The value is empty, or `TZ=UTC date -d "<expiry>" +%s` fails →
   `row oper gh "logged in as <login>, but its token's expiry cannot be read (<expiry with every character outside [A-Za-z0-9 :+-] replaced by ?>)"`.
7. Expiry at or before now → `row oper gh "the GitHub token of <login> expired on <YYYY-MM-DD>: issue a new one and store it with gh auth login --with-token"`.
8. Whole days left (floor) below `GH_TOKEN_WARN_DAYS` → `row oper gh "the GitHub token of <login> expires on <YYYY-MM-DD>, in <N> day(s): regenerate it on GitHub and store it with gh auth login --with-token"`.
9. Otherwise → `row ok gh "logged in as <login>; its token expires on <YYYY-MM-DD> (<N> day(s))"`.

`<YYYY-MM-DD>` is the parsed instant printed in UTC.

- [ ] **Step 1: Add the `gh` stub to `write_stubs`** (`$1/.local/bin/gh`), so no case can reach a
  real `gh` (without it the script's `PATH` reaches `/usr/bin/gh` on the laptop and on CI). It
  appends `gh $*` to `$S/calls`. For the arguments `api --include user --jq .login`:
  - `$S/gh-hang` present → `sleep 5`, then `: >"$S/gh-hang-finished"`, then exit 0 with no output;
  - `$S/gh-fail` present → exit 1 with no output;
  - otherwise it prints `HTTP/2.0 200 OK` (no CR); then, when `$S/gh-expiry` exists, one line
    `<header name>: <content of gh-expiry>` ending in CR, where the header name is
    `Github-Authentication-Token-Expiration` (GitHub's spelling) unless `$S/gh-header-lowercase`
    exists (then all lower case); then a CR-only line; then `stub-login` (no CR).

  Any other arguments: exit 0.

- [ ] **Step 2: Run the table with the stub alone**

  Run: `bash scripts/test-host-sync.sh 2>&1 | tail -n 5`
  Expected: 654 rows, all ✓ (the stub is not called yet).

- [ ] **Step 3: Write the failing rows** in a new section `== the GitHub token`. Each expiry is one
  string computed once by the table (`expiry="$(date -u -d '+100 days' '+%F %T UTC')"`), written to
  `gh-expiry`, and the row's date needle is `${expiry%% *}` of that same string. Rows assert the
  date, never the day count, so a second ticking over cannot flip them.

  | row | fixture | assertion |
  |---|---|---|
  | G1 | `new_case` | `has "$OUT" "✓ gh             logged in as stub-login; its token carries no expiry"` |
  | G2 | same run | `has "$(calls)" "gh api --include user --jq .login"` |
  | G3 | `gh-expiry` = +100 days | `has "$OUT" "✓ gh             logged in as stub-login; its token expires on <date>"` |
  | G4 | `gh-expiry` = +5 days | `has "$OUT" "⚠ gh             the GitHub token of stub-login expires on <date>"` |
  | G5 | same run | `has "$OUT" "1 step(s) need a person"` and `check "$RC" 0` (two rows) |
  | G6 | `gh-expiry` = −1 day | `has "$OUT" "⚠ gh             the GitHub token of stub-login expired on <date>"` |
  | G7 | `gh-expiry` = `soon; rm x` | `has "$OUT" "its token's expiry cannot be read (soon? rm x)"` |
  | G8 | `gh-fail` | `has "$OUT" "⚠ gh             gh did not answer for this host's GitHub login"` |
  | G9 | `gh-hang`, run with `HOST_SYNC_GH_TIMEOUT_S=1` | the same needle as G8, and `check "$(present "$H/stub/gh-hang-finished")" gone` (two rows) |
  | G10 | `gh-expiry` = +100 days, `gh-header-lowercase` | the same needle as G3 |
  | G11 | `mkdir "$H/.clauth"` | `check "$(area_rows gh)" 0` and `hasnt "$(calls)" "gh api"` (two rows) |
  | G12 | SUT called directly with `HOST_SYNC_GH_BIN=gh-not-installed` | `has "$OUT" "· gh             no gh on this host"` |
  | G13 | the G3 run | `hasnt "$OUT" $'\r'` |
  | G14 | `gh-expiry` an empty file | `has "$OUT" "its token's expiry cannot be read ()"` |

  Seventeen rows. `EXPECTED_ROWS` 654 → 671. G9 and G12 call the SUT the way the existing
  "a key in the CALLER's environment" row does, with the one extra variable.

- [ ] **Step 4: Run, expect twelve of the seventeen to fail**

  Run: `bash scripts/test-host-sync.sh 2>&1 | tail -n 5`
  Expected: the tally reads 659 passed and 12 failed. Five rows are true before the code exists
  (G5's exit status, G9's marker, both of G11, G13); the mutants of Step 7 are what pin them.

- [ ] **Step 5: Implement the constants, `here_gh_token` and its call** as the rule above says.

- [ ] **Step 6: Run the table and shellcheck**

  Run: `bash scripts/test-host-sync.sh 2>&1 | tail -n 5 && shellcheck -x scripts/host-sync scripts/test-host-sync.sh`
  Expected: 671 rows, all ✓; shellcheck silent.

- [ ] **Step 7: Nine mutants, one at a time, each KILLED by the row named, in both environments:**

  | mutant | killed by |
  |---|---|
  | the clauth gate deleted | G11 |
  | the header name compared case-sensitively against the lower-case constant | G3 |
  | the constant spelled as GitHub capitalises it, compared case-sensitively | G10 |
  | the CR strip deleted | G7 (the sanitised value then ends in `?`) and G13 |
  | the expired branch deleted | G6 |
  | the warning branch's `oper` → `ok` | G4 |
  | an answer with no status line treated as "no expiry" | G8 |
  | the `timeout` removed from the call | G9's second row (the stub then finishes and leaves its marker) |
  | the empty-value test deleted | G14 (both `date`s read an empty string as today) |

  A mutant that survives is either equivalent or a missing row, and is reported as one or the
  other, never dropped. G13 is pinned by the CR-strip mutant only where a CR can reach a printed
  row; if the implementation reformats every value it prints, say so in the kill table.

- [ ] **Step 8: Commit**

  ```bash
  git add scripts/host-sync scripts/test-host-sync.sh
  git commit -m "Report the GitHub token's expiry in host-sync"
  ```

### Task 3: The first-run documentation, the design amendments, the PR

**Files:**
- Modify: `docs/CLAUDE_SETUP.md` ("A host's first run"), `docs/superpowers/specs/2026-11-04-shared-claude-config-design.md`
  (D8, D11, "Verification"), any document that states the table's row count (`git grep -n '649'`)
- Create: none

- [ ] **Step 1: `docs/CLAUDE_SETUP.md`, "A host's first run".** Add a subsection **"A host with no
  checkout yet"** before "Preflight", stating, in this order and each with its one-line reason from
  "Why this PR exists" above:
  1. zsh on `PATH` before anything else; linger for the account, or its timers stop at logout.
  2. Where the login shell is to change: a silent `~/.zshenv` carrying the `PATH` its
     non-interactive ssh commands, forced commands and sftp relied on, written and tested
     (`env -i HOME=$HOME PATH=<sshd's default> zsh -c 'command -v <tool>'`, one tool per call)
     **before** the change; and the check after the change run with `ssh -o ControlPath=none`,
     since a live multiplexed connection keeps the shell it authenticated with.
  3. `~/.gitconfig.local` with the account's `[user]` block and `~/.zshrc.local`, both before
     `./install`, which never overwrites either.
  4. `git clone --recursive`, `scripts/install-prerequisites.sh`, mise. Go (the herdr-draft build)
     and delta (the tracked git pager) must come from it. A host whose own Node or Python must stay
     the one its work uses gets its own `~/.config/mise/config.toml` as a regular file before
     `./install`, which keeps a config that differs from the repository's; otherwise the launcher
     puts mise's versions ahead of the system's in every pane.
  5. `./install`, then the documented preflight again (the checkouts just made are new glob
     matches), then the marker and the `--apply` the section already describes, then
     `scripts/herdr-claude-wire.sh` once, since `host-sync` does not run it.

  Say that `scripts/server-bootstrap.sh` needs sudo and is not this path. Say that a host which
  should hold no memory names, in its profile, a tenant no store serves: nothing is cloned and the
  link row reads `0 linked`, and `N without a store` then counts memory written there that no
  store reaches. Add to "Three reads prove it" one sentence on the `gh` row and one on the Linear
  row, and replace "no ✗, and read every ⚠" with the rows a person is expected to see on a host
  with no `agents.slice` unit and with abandoned session scopes.

- [ ] **Step 2: The design.**
  - Under D8, after H11: "**Amended 2026-11-11 (DO-900):** two amendments, from the plan
    `docs/superpowers/plans/2026-11-11-claude-host-without-work-tenant.md`. **(H12)** The
    `LINEAR_API_KEY` row is a person's step only where the profile serves the work tenant or its
    tenants are unknown; elsewhere it is one information row and the local rc file is not read.
    **(H13)** A `gh` row reports the expiry of the host's GitHub token from the
    `github-authentication-token-expiration` response header: ✓ with the date, ⚠ inside 14 days,
    after it, and for a value that cannot be read, ✓ 'carries no expiry' for a token that sends
    none, no row where clauth manages accounts."
  - Under D11: "**Amended 2026-11-11:** `scripts/server-bootstrap.sh` requires sudo, so a host
    without it is bootstrapped by hand (`docs/CLAUDE_SETUP.md`, 'A host with no checkout yet').
    'Reports its age' reads 'reports its expiry' (H13): GitHub exposes no creation date. Which
    credential reads the overlay, whether the host serves a memory store, and whether its login
    shell and herdr server change in the joining step are that host's decisions, recorded with its
    run, and may be narrower than this section: a credential that can write the overlay can change
    what every other host installs. A host's own rules are a user-level rule file linked on that
    host only, not a variant of a root `CLAUDE.md` (D0 and step 3 said 'host-root variants'): two
    conditional links cannot share one target under the link checker, and a root file is not read
    from a worktree outside that root."
  - Under "Verification", after the dev and sol-build bullet: "**Amended 2026-11-11:** 'all ✓' reads
    'no ✗, and every ⚠ a step the host's run record names': a host with no `agents.slice` unit, an
    unsigned MCP server or abandoned session scopes carries ⚠ rows that `--apply` cannot clear."

- [ ] **Step 3: Checks**

  Run: `./scripts/check-claude-md.sh && pre-commit run --all-files && bash scripts/test-host-sync.sh 2>&1 | tail -n 3`
  Expected: all pass; 671 rows.

- [ ] **Step 4: Commit, then the whole-branch review** (one reviewer on the most capable model, its
  findings to a file; at most one fix wave and a scoped re-review).

  ```bash
  git add docs/CLAUDE_SETUP.md docs/superpowers/specs/2026-11-04-shared-claude-config-design.md docs/superpowers/plans/2026-11-11-claude-host-without-work-tenant.md
  git commit -m "Document a host's first run without a checkout or sudo"
  ```

- [ ] **Step 5: PR** titled `DO-900 Make host-sync truthful on a host that serves no work tenant`,
  body rewritten to the final diff. No `install.conf.yaml` change, no unit armed.

## Calls made here

- `linear-key@dotfiles` stays enabled by `base.json` on every profile. Turning it off per tenant
  needs a way for a fragment to negate another, which nothing else wants; the row is what was false.
- The `gh` row reports expiry, not age, and makes one network call per run, the timer's included:
  an expired token is what a daily unattended run should say before a sync starts skipping.
- No row on a clauth host rather than an information row: H9 already prints one for the auth rows,
  and a second line saying "does not apply" on the laptop is noise.
- Carried to step 10 with the other deferred minors: the `server-bootstrap.sh` hint for a missing
  checkout and the `dev-link-doctor` hint for any unreachable host (both pinned by table rows);
  `herdr-claude-wire.sh` as a row rather than a documented hand step; D5's
  `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` for sessions, which no remote host exports today; a `gh` row
  whose ⚠ reaches a person without a laptop-driven `--check`; one reader of "is the work tenant
  served", shared by `claude-doctor`'s Linear section, `scripts/verify-tools.sh` and
  `scripts/herdr-server-launch.sh`, which all still warn about a missing `LINEAR_API_KEY` on a host
  that serves no work tenant; the table's "a key in the CALLER's environment" row, which calls the
  script directly and so skips the overrides `run` sets (an optional array of caller assignments in
  `run` fixes it); and a host with several gh config dirs and no clauth, where the `gh` row reads
  only the token gh resolves by default.

## Amendments during execution (2026-11-11)

The tasks above are the plan as approved. These are the changes made while it ran, each a ruling
recorded with the run.

- **Task 1's RED tally is 651 passed and 3 failed**, not 650 and 4: L3's value row is true before the
  code exists, since the value is never printed today. After the task review the L3 run gained one
  `has` row for the information row, so that a run which printed nothing cannot pass it.
- **Task 2 has 21 rows, not 17, and the table ends at 676, not 671** (677 after the fix wave,
  below). The nine planned mutants left four rules free to change under a green table, so four rows
  were added before the task review:
  - G15: a real `HTTP/2.0 401 Unauthorized` answer, expiry header and all, reads ⚠ "did not answer".
    G8 and G9 give an empty answer, which does not stand in for it (measured: a rejected token exits
    1 and prints 22 lines).
  - G16 and G17: the 14-day threshold from an hour above and an hour below (`+337 hours` and
    `+335 hours`, measured under both `date` implementations).
  - G18: a login that is not a GitHub login is shown as `?`.
  - G7 and G14 carry the ⚠ glyph in their needles.

  Five more mutants, each killed by the row named: the status pattern loosened to `^HTTP/` (G15), `<`
  to `<=` at the threshold (G16), the default 14 to 13 (G17), the login check removed (G18), the
  unreadable-expiry row's kind `oper` to `ok` (G7 and G14).
- **G9 and G12 put their one variable in front of `run_level --check`** instead of calling the script
  directly: the direct call skips the run's overrides and reaches the real network and `/proc`.
- **G13 can fail under no single change**: each value the row prints has two defences against a CR,
  the strip and its own (the login check for the login, the date reformat for the date). It stays,
  named as that guard; the strip itself is pinned by G7 and G14.
- **Two behaviours the task review questioned stay as built.** The call's exit status is not read: a
  `200` status line proves the token was accepted, and the header block is complete before the body.
  The row reports the credential `gh` resolves in the run's own environment, which is the one the
  run's own fetches use.
- **Task 3 also adds the `CHANGELOG.md` entry** and runs `scripts/check-doc-tokens.sh` by hand, which
  CI runs and pre-commit does not. Its expected tally was 676 rows, and is 677 after the fix wave
  below.
- **The fix wave after the whole-branch review.** The review measured that a forced colour variable
  (`CLICOLOR_FORCE` other than `0`, or `GH_FORCE_TTY`) makes gh colour every header name even into
  a pipe, which hid the expiry header and turned a token five days from expiry into ✓ "carries no
  expiry". The call now clears both variables, the stub colours its header names as gh does when
  either forces it, row G19 runs the row under `CLICOLOR_FORCE=1`, and a fifteenth mutant (the
  clearing removed) is killed by G19 alone; the table ends at 677. The "did not answer" row's text
  now also names an unreachable GitHub and, for an expired token, the remedy: GitHub answers an
  expired token with 401, so that row, not the dated one, is what a person sees after expiry.
