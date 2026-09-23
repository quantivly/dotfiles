# GitHub account routing: how gh picks an account, and how it gets it wrong

The maintainer's record behind the **GitHub Account Routing** rules in [CLAUDE.md](../CLAUDE.md):
the measured `gh` keyring collapse that makes `GH_CONFIG_DIR` useless on its own, the routing
table and its precedence, and every trap found in `gh-doctor` and the `chpwd` hook — each of which
produced a green tick or a confident wrong answer before it was found. The rules an agent acts on
are in CLAUDE.md; this page is the evidence behind them.

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-627), from the tree at `18c70fb`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 18c70fb:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

## GitHub Account Routing (`gh-doctor`)

**`GH_CONFIG_DIR` does not isolate the credential, and `gh auth status` will not tell
you.** gh stores its tokens in the system keyring keyed by **host**, not by config dir,
so `GH_CONFIG_DIR` isolates `hosts.yml` and `config.yml` and nothing else. Observed here
on 2026-09-01:

```
config dir      hosts.yml declares    an API call resolves to
gh              zvi-quantivly      →  zvi-quantivly
gh-personal     ZviBaratz          →  zvi-quantivly   ← mismatch
gh-quantivly    zvi-quantivly      →  zvi-quantivly
```

`gh auth status` reports the *declared* user throughout — so it says `ZviBaratz` while
the API answers `zvi-quantivly`. **A status command describing intent rather than
effect**, the same shape as the `backup-doctor` bug and the live-config guard's false
all-clear. The direction matters: with `GH_TOKEN` unset it falls back to the **work**
account, in any directory, so a personal repo silently gets work credentials while git
correctly signs the commits as personal.

`zshrc.company` already works around it by caching per-account tokens
(`~/.cache/gh-token-cache/{personal,quantivly}`, 600, refreshed on shell start) and
exporting the right one as `GH_TOKEN`; its own comment notes that `gh auth token`
**without `--user`** "returns a shared default that may be wrong". So the mechanism was
known — **the defect is the failure mode**, which is invisible and biased toward work.

There is one deliberate escape hatch: `GH_ACCOUNT_ROUTING_OFF=1` makes the hook return
without touching anything, for a supervisor that provisions per-session credentials of its
own. It replaces the Atrium deferral, whose problem was the *detection* (`$ATRIUM`, or a
tmux socket named `*/atrium` — anything could set either), not the capability; being named
rather than sniffed also lets `gh-doctor` report such a shell as deliberate instead of
faulty.

`gh-doctor` (`zsh/functions/github.sh`) makes it visible. For a directory it prints the
account the **remote** routes to, the account gh **declares**, the account an actual
`GET /user` **returns**, and which mechanism decided (`GH_TOKEN` / `GITHUB_TOKEN` /
config-dir keyring). Everything it says about "effective" comes from a real request;
nothing is inferred from configuration, because that inference *is* the bug. It also
proves the workaround still works — for each config dir it probes twice, once with the
token env cleared (which reproduces the collapse) and once pinned with
`gh auth token --user <login>` (which does isolate) — so nobody is told to rely on a
mechanism that has itself broken.

**Routing follows the repo REMOTE, not `$PWD`** — the rule git identity already uses
(#67, `hasconfig:remote.*.url` in `~/.gitconfig.local`), so a work repo routes correctly
wherever it is checked out and a personal repo under `~/quantivly/` does not get the work
account. Like `hasconfig`, **any** remote can match, not just `origin`: in a fork workflow
origin is the personal fork and upstream is the work repo, and matching origin alone would
hand that repo the personal account while git signs its commits as work.

**A path route decides only what the remote cannot.** `GH_ACCOUNT_PATH_ROUTES` is
consulted for a directory with *no* GitHub remote — not a repository, a repository with no
remotes, or only non-GitHub remotes — and never for one that has a remote, matched or not: a
GitHub remote whose owner matches no route means *personal, by remote*, exactly what git
identity concludes. Precedence is remote owner route → path route → `GH_ACCOUNT_DEFAULT_DIR`,
with `git-error` stopping before any of them. It exists for the work tree's roots that are
not repositories (`~/quantivly/qspace` holds two repositories and is itself none; `drafts`,
`comms-style`, `handoffs`). On 2026-09-09 a Claude Code session started in
`~/quantivly/qspace` took the personal default; Claude's Bash-tool shells are `zsh -c` with
no `.zshrc`, so they inherit Claude's environment verbatim, and the GitHub MCP plugin's
`Authorization` header is expanded from that environment once at startup — so every `gh`
call and every MCP request in the session was the personal account, 404ing on private work
repositories until the session was restarted from a correctly routed shell. One deliberate
trade-off: a repository with *no* GitHub remote under `~/quantivly` (a fresh `git init`, a
GitLab checkout) is routed by place, while git identity stays personal until a quantivly
remote is added — the state `docs/TROUBLESHOOTING.md` already documents for git alone. A
GitHub URL the parser rejects is *not* that case: it counts as a GitHub remote, blocks the
path table, and `gh-doctor` flags it.

The `chpwd` hook (`_update_gh_config` in `zshrc.company`) uses the same
`_gh_route_for` the doctor does — one implementation, so the oracle cannot drift from the
thing it checks — then **pins** the account by exporting `GH_TOKEN` from
`~/.cache/gh-token-cache/<config-dir-basename>`. It routed on `$PWD` first until
2026-09-01, which let gh and git disagree about the same repository: a quantivly clone
outside `~/quantivly/` got the personal account from gh and the work identity from git.

**Every directory now pins an account explicitly; the keyring never decides.** Outside a
repo — `$HOME` is the normal resting state of a shell — the routing falls through to
`GH_ACCOUNT_DEFAULT_DIR` (personal), which is what git identity does there too. That is
deliberately *not* treated as a failure: warning on every `cd` into a non-repo directory is
how a warning stops being read. The loud path is reserved for the states where nothing can
be pinned — no default configured, an unusable table, or a routed account with no cached
token — and even then the message is printed **at most once per distinct message per
shell**, and never before the first prompt (output during initialization lands inside
p10k's instant-prompt warning box, the same reason the live-config guard defers).

The token cache is keyed by the config dir's **basename** (`gh-quantivly`, `gh-personal`),
not by a nickname, so the routing table is the single place an account is named — adding a
route needs no matching edit to the refresher, and a stale nickname cannot address the
wrong dir. `gh-refresh-tokens` and the shell-start background job are both driven by
`_gh_configured_dirs`, and both delete the pre-2026-09-01 nickname files, which would
otherwise sit there as a second, never-refreshed copy of a live credential.

```bash
gh-doctor                 # this directory
gh-doctor --offline       # config only — every network answer marked NOT CHECKED
gh-doctor ~/some/repo
```

Configuration is data, in `zsh/zshrc.company` (or `~/.zshrc.local`), read by the doctor:

```zsh
GH_ACCOUNT_ROUTES=( "quantivly=$HOME/.config/gh-quantivly" )             # owner-glob=config-dir
GH_ACCOUNT_PATH_ROUTES=( "$HOME/quantivly=$HOME/.config/gh-quantivly" )  # absolute-prefix=config-dir; only a dir with NO GitHub remote
GH_ACCOUNT_DEFAULT_DIR="$HOME/.config/gh-personal"                       # empty = indeterminate
```

Traps this area has, each of which produced a green tick or a confident wrong answer:

- **A route whose config dir does not exist can never fire**, and reporting that only when
  the route happens to match means the fault first surfaces on the day it was finally
  needed. The whole table is checked every run, matched or not. This is not hypothetical:
  writing the entry in **single** quotes (`'quantivly=$HOME/...'`) leaves a literal
  `$HOME` that never exists, and the route silently never matches.
- **`${~pat}` enables tilde expansion as well as globbing**, so a route pattern beginning
  with `~` aborted the lookup with "no such user or named directory" and took every later
  route with it. Owner patterns are restricted to `[A-Za-z0-9_.-]` plus `*` and `?`, and
  anything else is named as a bad table entry rather than left to misfire at match time.
- **An unparseable routing table selects nothing, and nothing reads as "this repo is
  personal"** — the unparseable-link-map failure from the live-config guard, in a new
  place. `bad-table` is its own state and is reported as UNUSABLE.
- **zsh's `local NAME` on a name already local in that scope is a DISPLAY command**, so a
  `local` inside a loop printed `du=zvi-quantivly` into the middle of the report.
- **An unfixable condition is a ⚠, not a ✗.** The keyring collapse is a property of `gh`;
  nothing here can repair it. Reporting it as a failure made `gh-doctor` exit 1 on *every*
  run — the permanently-red checker this file warns about two sections up, in the command
  written to avoid it, found only once it was deployed and run for real. The isolation
  section is the *rationale* for pinning (here is the collapse; here is proof the per-user
  token defeats it); ✗ is reserved for what someone can act on — the route disagreeing with
  the effective account, a missing route dir, an unreachable API, and a per-user token that
  resolves to the wrong login, which means that account needs `gh auth login`.
- **An empty answer is never agreement.** A failed or timed-out API call is a ✗ with the
  error, and every comparison that depended on it is reported as *skipped*, never passed.
  `--offline` marks its answers NOT CHECKED for the same reason.
- **The environment, not argv — and the severity of that was overstated once already.**
  `/proc/<pid>/cmdline` is world-readable (444) while `/proc/<pid>/environ` is owner-only
  (400), so `env GH_TOKEN=gho_… gh api user` looks like a leak. **It mostly is not**:
  measured, `env` *consumes* its assignments and then execs, so the token never reaches the
  exec'd program's cmdline — only the short-lived `env` process's own, between fork and
  exec. A microsecond race, not the length of the call, and **not** the same shape as the
  28-day tmux server this machine actually found. `_gh_run` uses a subshell anyway: it
  closes even the race, and — the real payoff — retires the whole `env`-argv class, which
  had already produced two bugs here (a shell function after `env`; `-u` after an
  assignment), both surfacing as *"could not resolve the account"*.
  The correction matters as much as the fix: a checker whose findings are inflated is a
  checker whose findings stop being believed.
- **`exec` resolves shell functions; `env` could not.** So the subshell form introduced a
  hazard the old one lacked — a user's `gh` wrapper in `~/.zshrc.local` being run instead
  of the binary, and its output taken as the effective login. `exec command gh`. Reachable
  only on the no-`timeout` fallback, which is why the test needs a PATH fixture that has
  `gh` but not `timeout`; without that it silently exercises the safe path.
- **git's exit status is load-bearing.** 0 = matched, 1 = no match, **128 = git could not
  read the repository at all** — which a malformed `~/.gitconfig` produces, and
  `~/.gitconfig` is itself a managed symlink in this repo, so a bad branch causes it.
  Discarding the status left the state at its initialised `no-repo`, which falls through to
  the personal default: a quantivly clone silently authenticating as the personal account,
  on the one path that deliberately does not warn. `git-error` is its own state, it stops
  rather than falling through, and it is loud.
- **The first prompt re-runs the routing; it does not replay what startup recorded.** The
  startup call routinely loses a race it is *meant* to lose — the token cache is
  repopulated by a background job that lands a second later — so the shell starts unpinned.
  Replaying that message printed something no longer true *and* left `GH_TOKEN` unset for
  the life of the shell, putting every `gh` call back on the keyring default inside a
  personal repo. The defect this mechanism exists to close, reintroduced in the one shell
  per boot nobody would re-check.
- **`GITHUB_TOKEN` is cleared everywhere `GH_TOKEN` is.** gh ranks it second, so leaving it
  set on an unpinned path means a third account nobody named wins — while the warning
  blames the keyring.
- **`gh-doctor <dir>` is not `gh-doctor`.** The effective-account probe reads *this
  shell's* environment, which the hook pinned for `$PWD`; comparing it against a different
  directory's route produced a confident ✗ for a state that cannot occur, since cd-ing
  there repins first. The comparison now runs only for `$PWD`.
- **The legacy-nickname purge subtracts the configured basenames.** `quantivly` and
  `personal` are also legal config-dir basenames, so purging *after* the writes deleted a
  token just cached, and purging *before* them discarded a still-valid one whenever that
  iteration's `gh auth token` failed transiently. Naming the exception removes the ordering
  question rather than answering it.
- **Helpers used outside the opt-in gate must be defined outside it.** `gh-refresh-tokens`
  sits outside `[[ -d ~/.config/gh-quantivly ]]` while its cache helpers sat inside, so on
  a personal-only box — the exact machine the gate exists for — it hit `command not found`,
  took an *empty* cache path, wrote a live token to `/<basename>` at the filesystem root,
  and printed `✓ … cached token` with exit 0.
- **A chpwd helper may not be a `$(...)` call.** Replacing a parameter with a function to
  deduplicate a path put a fork back in the hot path this file had just been cut down to
  one git fork. One assignment deduplicates just as well.
- **The first-prompt hook retires only once it has pinned something.** Unhooking after a
  single attempt meant a shell that lost the cache race twice — the refresher does two `gh`
  forks, and p10k's instant prompt can beat them — stayed on the keyring default for life.
  Later prompts are free: it short-circuits on `[[ -n $GH_TOKEN ]]` before any fork.
- **`GITHUB_TOKEN` is cleared on the SUCCESS path too, not just the failures.** gh outranks
  it, but the GitHub MCP server, `act`, `hub` and most Actions-shaped tooling do not — so
  an inherited one kept authenticating as a third account inside a correctly-routed
  directory, with `gh-doctor` reporting `credential: $GH_TOKEN` and showing nothing wrong.
- **Keep git's own error.** Collapsing every non-0/1 status into one sentence blaming
  `~/.gitconfig` was wrong for most of them: git missing is 127, `$PWD` may be deleted, and
  "detected dubious ownership" is ordinary on external media and wants `safe.directory`.
  stderr is folded into the capture (a temp file would need `rm`, and a broken PATH is one
  of the states being diagnosed), and the parser shape-checks `remote.<name>.url` so a
  warning cannot become a phantom remote.
- **`local` outside a function is an error in zsh**, and the shell-start refresher was an
  inline `{ … } &!` block — so the error went to a backgrounded subshell's stderr where
  nobody sees it, the cache stayed empty, and every directory reported "account NOT
  pinned". It is a function now. (Writing a credential out of dynamically-scoped globals
  would have been the other way to get that wrong.)
- **A `chpwd` hook cannot afford a `gh` fork.** The doctor may spend ~50 ms per config dir
  asking gh what it declares; the hook may not, so it reads the cache file directly and
  `_gh_repo_remotes` was reduced to a single `git` fork on the common path — `git config
  --get-regexp` exits non-zero for "not a repo" and "no such key" alike, so the `rev-parse`
  that tells them apart runs only when there was nothing to parse.
- **A workspace root is not a repository, and "not a repository" fell to the personal
  default.** `~/quantivly/qspace` holds two work repositories and has no remote of its own,
  so the remote rule had nothing to say and the default answered — inside the work tree. A
  Claude Code session started there inherited the personal `GH_TOKEN` and
  `GITHUB_PERSONAL_ACCESS_TOKEN`; its Bash-tool shells (`zsh -c`, no `.zshrc`) kept them,
  and the GitHub MCP plugin's bearer header was fixed to them at startup, so every private
  work repository 404'd for the life of the session (2026-09-09). `GH_ACCOUNT_PATH_ROUTES`
  answers exactly that case and only that case — a directory with a GitHub remote is still
  the remote's to decide, so a personal repository under the work tree stays personal, as
  git signs it.
- **`printf > file` truncates before it writes.** The refresher runs on every interactive
  shell start and rewrote both cache files in place, so a shell starting while another
  shell's refresher was mid-write read an *empty* token and started unpinned — and a Claude
  Code session launched from it carried no GitHub credential at all. herdr and Herdmates
  start several panes at once, which is that state. `_gh_cache_write` writes a temp and
  renames it into place: a reader sees the old token or the new one, never nothing. The
  chmod before the rename guarantees the live file's mode; the `umask 077` only closes the
  moment before it, inside a 700 directory, and is deliberately not what the rows measure.
  Independent review then found two more traps in the writer, both now pinned: the temp
  was named by `$$.$RANDOM`, and **both are inherited unchanged across a zsh fork**, so the
  disowned shell-start refresher and a foreground `gh-refresh-tokens` shared one name and
  the loser printed a false ✗ (`sysparams[pid]` is the real PID); and `mv -f` onto a
  *directory* moves into it and succeeds, so a directory at the cache path got a live token
  inside it and a ✓ (refused now, as `main`'s writer refused it). The state table tells a
  replace from a truncate by the live file's inode — which only holds with one fixture HOME
  per row, because a leftover refresher from an earlier row can free the recorded inode and
  hand it straight back to the new temp.
- **A deduplicated table hides a route.** `_gh_configured_dirs` deduplicates by config dir,
  and on the shipped configuration the path route names the *same* dir as the owner route —
  so the path table vanished from `gh-doctor` entirely, and a mistyped prefix was a silently
  inert route under a fully green report: the exact fault the table check exists to name,
  two lines above the code that hid it. A shared dir now carries every reason
  (`route 'quantivly' + path route '~/quantivly'`), and a prefix that does not exist on disk
  is a ⚠ that "can never fire" — a ⚠, not a ✗, because a machine with the work config dir
  and no work tree has nothing to route there and must not carry a permanently red doctor.
  Found by an independent review pass, not by the author.
- **"No GitHub remote" had a fourth case.** A GitHub URL the parser rejects left the owner
  slot empty exactly like a non-GitHub remote did, so it took the path route: a repository
  under the work tree whose only remote is `git@github.com:someone` was pinned to work while
  git signs it personal, with a reason that said "no route matched". `_gh_repo_remotes` now
  records the parse state per remote; `unparsable` counts as a GitHub remote, blocks the path
  table, and the doctor lists it as a ⚠.

State table: `scripts/test-gh-routing.sh` (209 checks, run in CI, hermetic — `gh` is
stubbed, so it needs no network, no keyring and no GitHub account; the stub reproduces the
keyring collapse, which a real `gh` cannot be made to do on demand). Each trap above is a
row, and each is pinned by mutation: reverting the fix in a copy of the tree has to make
the row that names it fail.
