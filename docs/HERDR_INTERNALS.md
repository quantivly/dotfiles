# Herdr in this repo: how it works, how it fails, how it is tested

The maintainer's record behind the **Herdr** rules in [CLAUDE.md](../CLAUDE.md): the two install
paths, the systemd unit and its drop-in, the sidebar publisher, and every trap found so far with
the evidence and the state table that pins it. If you are **adopting** herdr rather than
maintaining this integration, read [HERDR_GUIDE.md](HERDR_GUIDE.md) instead — it is written for
you, and this page is not.

> **Moved verbatim from CLAUDE.md on 2026-09-18 (DO-625), from the tree at `81d4a8e`.** Nothing
> was rewritten, so "this file" below means CLAUDE.md, and "above", "below" and "N sections up"
> refer to its layout at that commit; `git show 81d4a8e:CLAUDE.md` restores the context. **Add new
> evidence here, not to CLAUDE.md** — the rules stay there, the evidence lives here.

---

## Herdr (agent workspace manager)

Terminal workspace manager for coding agents (workspaces → tabs → panes, with agent detection).
Config: `config/herdr/config.toml` → `~/.config/herdr/config.toml`. Full guide:
[docs/HERDR_GUIDE.md](HERDR_GUIDE.md).

**Two install paths, and the modular one is the default recommendation for anyone else
(DO-555).** `./install --herdr` links the FIVE destinations that are actually herdr —
`config.toml`, `plugins.list`, `plugins.lock`, the statusline hook and the systemd unit —
and stops. The full `./install` links 18, among them `~/.zshrc`, `~/.gitconfig`,
`~/.tmux.conf`, `~/.p10k.zsh` and VS Code's `settings.json`; requiring all of that to run
herdr is how an invitation becomes an ultimatum. The modular path deliberately does NOT
link `~/.config/mise/config.toml` (it would pin ~25 tools and override whatever
node/python the machine already runs) — `scripts/herdr-deps-check.sh` reports what is
present, names the one feature each missing tool costs, and offers the exact `mise use -g`
line with versions read out of `.mise.toml` so it cannot drift from the pins. It handles
mise-absent too, by naming the versions and leaving the method alone.

**The linked lockfile assumes push access, and an outside adopter does not have it (DO-566).**
`plugins.list` and `plugins.lock` are symlinks into the checkout in BOTH configs, deliberately,
so `herdr-lazy` writes a plugin change through as a reviewable diff. For anyone who cannot push
here that is permanent local modification of somebody else's repo plus a `git pull` that
conflicts on a file a tool wrote for them — no error, just an update path that stops working.
The answer is a fork with this repo as `upstream`, documented in HERDR_GUIDE §3 "Updating a
modular install you cannot push to" and printed by `./install --herdr`, where the reader is
standing when it matters. Copying the two files for the modular path instead was considered and
rejected: a copy is written once and never reconciled, which is the `~/.config/mise/config.toml`
failure above (one warning, keep the stale local copy, forever), and it costs the reviewable
diff that is most of why the lockfile is in git.

The shell layer is `zsh/zshrc.herdr`, sourced by `zshrc` and **safe to source alone** — a
modular adopter adds one line to their own rc. It needs zsh, and `hdespawn` prefers `confirm`
(`zsh/functions/system.sh`). `hspawn`/`hdespawn`/`hreap` in it are **agent-facing**: a lead
agent drives them to fan work into worktrees and reap it. A human uses the herdr UI and
`clauth`. It also carries `herdr-help`, the in-shell cheat sheet — moved here from
`zsh/zshrc.help` by DO-563, because that module is sourced by the FULL install only, so the one
command that lists `hspawn`/`hreap`/`clauth` was missing on exactly the machines whose owner had
not read the guide.

Two things the modular installer cannot do, both silent: Claude Code's `statusLine` +
agent skill file, and `herdr plugin link` for the local plugin. It prints both, and the first is
now one idempotent command — `scripts/herdr-claude-wire.sh` — rather than a JSON block with the
reader's own home directory to substitute in. `scripts/verify-tools.sh --herdr` is the single
check afterwards: the three herdr sections plus that wiring, and **none** of the eleven
full-install sections, whose mise check would otherwise print a ✗ and offer a paste that pins
~25 tools globally on a machine that deliberately linked no mise config. A checker that needs a
prose disclaimer telling you to ignore it is the permanently-red checker this file warns about
twice, and it had reached the one path written to avoid it.

**The checkout may live anywhere, and getting there needed a drop-in rather than a rendered
unit (DO-564).** The unit's own `ExecStart` is the absolute
`%h/.dotfiles/scripts/herdr-server-launch.sh`, so `--herdr` used to REFUSE any other
directory — the cost landing on the adopter we most want to say yes, someone who already has
their own `~/.dotfiles`, and the team page escalated it to "come and talk to us before you
move anything". `./install` now renders
`~/.config/systemd/user/herdr-server.service.d/10-execstart.conf`
(`scripts/herdr-unit-dropin.sh`, template under `systemd/herdr-server.service.d/`) pinning
ExecStart to the installing checkout. Six things about it are load-bearing:

- **A rendered COPY of the unit was the obvious move and is wrong.** Two checkers derive
  "which checkout is live" from the unit being a **symlink** —
  `reconcile-systemd-units.sh`'s `managed_units()` requires `-L`, and `verify-tools.sh`'s
  enablement assertion walks `~/.config/systemd/user/*` taking `readlink -f`. A copy makes
  both find nothing and **skip silently**, in the section whose own comment says a missing
  checker is not a pass. A copy would also be a copy of *reviewed content* (`OOMPolicy`,
  `KillMode`, `Restart`, `[Install]`) that stops tracking the repo the moment HEAD moves —
  the `~/.config/mise/config.toml` failure DO-566 refused to repeat.
- **What is rendered is machine IDENTITY, not content, which is why DO-566's objection does
  not transfer.** The drop-in holds one fact — where the checkout is — and HEAD cannot stale
  it. That is the `__BACKUP_*__` case (DO-459), not the mise case: the mise file is written
  by a *tool* and diverges from a reviewed source, a rendered path diverges from nothing.
- **The empty assignment before each value is required, not stylistic.** `ExecStart` is a
  list, so a drop-in that merely adds one gets you two, and systemd then refuses the unit:
  *"Service has more than one ExecStart= setting, which is only allowed for Type=oneshot
  services."* Verified both ways with `systemd-analyze verify --user` under
  `SYSTEMD_UNIT_PATH`, which needs **no manager and no running server** — the only way to
  test this at all, since a running server keeps its original `ExecStart` until a restart
  that would end every agent session.
- **The check asks the outcome, never the mechanism.** "A drop-in exists" is permanently red
  on a healthy machine at `~/.dotfiles`, where the unit's own value is already correct.
  `herdr-unit-dropin.sh --check` asks instead whether the **effective** `ExecStart` — base
  unit merged with its drop-ins, reset semantics applied — names an executable launcher
  inside the checkout the unit symlink resolves to. One rule, no severity branch, and it
  catches both real states: a foreign checkout nobody rendered for, and a drop-in left
  behind by a checkout that has since moved. Both sides are canonicalised before comparing,
  because `want` comes from a physical `readlink -f` and `bin` from `%h` expanded to `$HOME`
  — on the supported `~/.dotfiles -> ~/src/dotfiles` layout a naive compare reports drift on
  a correct machine forever.
- **The rendered value is QUOTED, and a local review pass is what caught why.** systemd splits
  an unquoted setting on whitespace, so a checkout at `~/my dotfiles` rendered
  `ExecStart=/home/me/my dotfiles/scripts/…` and systemd went hunting for a binary called
  `/home/me/my` — **203/EXEC, the exact failure this change removes, reintroduced for anyone
  with a space in their path.** Quoting unconditionally rather than only-when-needed is
  deliberate: a conditional puts the space case on a branch that never runs on our machines,
  and this repo has already shipped a row that could not reach the branch it named. The
  parser side had to learn quoting too, or `--check` could not read its own output back.
- **Only `%h` is expanded, and anything else is NOT CHECKED rather than guessed.** An earlier
  version also mapped `%%` → `%` and did it in the wrong order, so `%%h` — a literal `%h` —
  became `%$HOME`: dead code that was also wrong. A value carrying an unexpanded specifier is
  declined, because comparing it would report "wrong launcher" about a unit somebody
  legitimately extended, i.e. a permanently-red assertion. "No `ExecStart` at all" stays a
  hard FAIL, so the two empties are kept apart — an empty answer is never agreement.

**A mutation that no longer APPLIES reads exactly like a surviving mutant, and that cost two
full sweeps here.** `str.replace` on a pattern that stopped matching is a silent no-op, so
after the drop-in template was reworded the row-pinning mutant "survived" twice while
changing nothing. The mutation harness must diff the mutated tree against the original and
treat "nothing changed" as a harness error, never as a result — the same rule this file
already states for rows ("a row that cannot reach the branch it names is unfailable"), one
level up. Dry-run every mutation for applicability before paying for the suite runs.

**The governing fact: every layer of this stack fails silently.** A 2026-08-30 walkthrough found
five separately configured features completely dead — a keybinding, a prefix fallback, two
popups, and `hspawn` — while `herdr config check` returned `ok` and `herdr server reload-config`
returned `applied` with zero diagnostics throughout. **`config check: ok` means the file parses and
its keys, chords and `[ui]` schema are internally consistent; it says nothing about effects.** It
does catch bogus keys, bad inline fields, non-hex colours and chord collisions among *listed*
actions (probed 2026-08-30) — but not a collision with an unlisted stock default, a chord the
terminal swallows, a missing popup binary, or a token that is never published. Verify effects, one
binding at a time, and never generalise from one working example to a class.

Gotchas, in the order they bite:

- **Never run bare `herdr`** from a script or an agent — it attaches a client and hijacks the
  user's UI. Subcommands only. (At a keyboard it is just how you re-attach after `ctrl+alt+q`.)
- **Closing one terminal in the spaces sidebar can close the whole space, silently.** A close
  aimed at a single pane issues a **`tab.close`**, which kills every pane in that tab — and when
  the space holds only that one tab, the space goes with it. On 2026-09-07 at 09:57 an empty root
  terminal was closed in a space containing two nested Claude sessions; the server log shows one
  `method="tab.close"` followed by three `pane.exit` records (`code: 1`, and a `Hangup` for the
  third), and the space disappeared from the sidebar. Five sessions went that way across four such
  closes that morning. **There is no undo**: `herdr session` manages server *sessions*, not closed
  workspaces, and `~/.config/herdr/session-history.json` mirrors the LIVE set rather than retaining
  closed ones — verified, its entry count tracks `herdr workspace list` exactly. The layout is
  unrecoverable; the conversations are not, because Claude Code transcripts outlive the pane
  (`claude --resume <session-id>` from the original cwd). Two things make the post-mortem possible
  and are worth knowing before you need them: a killed pane's transcript stops at the instant of
  `pane.exit`, so matching transcript last-write times against exit timestamps identifies which
  session died where **to the second**; and the log records a workspace's *creation* and *closure*
  but **never its label**, so afterwards you can prove what was in a space and not what it was
  called.
- **`request_id="cli:…"` in the herdr log does NOT mean a program did it.** All 6,183 requests in
  this machine's server log carry that prefix — the TUI is a client speaking the same API — so the
  field cannot tell a human's click from an agent's CLI call. It was read as proof that "an agent
  closed these, not the user", and that was wrong. Nothing in the log attributes an action to a
  human.
- **Never start or restart the herdr server from inside a pane or a Claude session.** The server's
  environment is a snapshot of whoever launched it, and every pane inherits it. The live server was
  once relaunched from a team-lead pane (2026-08-29), so every pane got the teammux shim as `tmux`,
  a fake `TMUX`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and herdmates' plugin dirs — a dozen-plus
  team-of-one sessions, `tmn`/`tmux kill-server` dead, `$status` on every row, and the runbooks'
  `command -v tmux` pre-flight passing for everyone. Use the unit:
  `systemctl --user restart herdr-server.service` (`systemd/herdr-server.service`, launcher
  `scripts/herdr-server-launch.sh`; `--print-env` shows the environment it builds, and it refuses to
  start when `HERDR_ENV`, `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` is set). `scripts/verify-tools.sh`
  asserts the running server's env is clean. The unit is wanted by `graphical-session.target`, **not
  `default.target`**: `Linger=yes` on this account brings the user manager up at *boot*, so a
  `default.target` unit would start before GNOME imports `DISPLAY`/`WAYLAND_DISPLAY`/`XAUTHORITY`
  and get none of them. It still survives logout — `WantedBy` propagates start only, and the unit
  has no `PartOf` — so every agent session stays alive. Nothing is manual per boot. See
  HERDR_GUIDE §2.4.
- **An error anywhere in `[ui]` silently reverts ALL of `[ui]`** and reports `partial` with no
  error text. After any config edit, `herdr server reload-config | jq '.result.status'` must say
  `applied`. If an edit "did nothing", this is the first thing to check.
- **Setting a key field REPLACES it wholesale.** An action relying on a stock prefix default must
  re-list that default explicitly or it is silently lost (this is how `f12 v` / `f12 -`
  disappeared — an audit found 15 of 25 rebound actions had lost theirs). A bare value is only
  safe for actions whose stock default is empty (`focus_agent`, `next_agent`, `previous_agent`,
  `move_tab_*`, `resize_pane_*`). Diff against `herdr --default-config` after any keymap edit.
- **A LINKED systemd unit is not a RECONCILED one, and the difference is invisible.** systemd
  records `[Install]` at `enable` time, as a symlink under `<target>.target.wants/`. Editing
  `WantedBy=` afterwards changes nothing about what starts — **not even after `daemon-reload`**,
  which re-reads the unit but never revisits the symlink. **And the obvious fix is a trap:
  `systemctl reenable` (= `disable` + `enable`) DESTROYS a dotbot-installed unit.** `disable`
  removes every symlink in the unit search path pointing at the unit, and the entry in
  `~/.config/systemd/user` is exactly such a symlink, into the checkout — so the enable half then
  fails with "Unit does not exist" and the unit is left neither linked nor enabled. That happened
  here on 2026-09-01. What is safe is `enable` (it only ADDS `.wants` links) plus pruning the
  stale link by hand, in that order. A probe using a real FILE rather than a symlink showed
  `reenable` working perfectly, which is how the advice got written — **a fixture that differs
  from production in the one property that decides the outcome proves nothing.** Meanwhile
  `systemctl status` is happy, so the unit file under review says one thing and what boots is
  another. This repo *manufactures* that drift, because `git checkout` here is a deploy and
  `./install` is not in that path: HEAD moves, the linked unit file changes under systemd, nothing
  re-enables anything. It cost one reboot's worth of every pane losing `gh --web`, `xdg-open` and
  the ssh agent, with every check on the machine green. Now: `./install` reconciles
  (`scripts/reconcile-systemd-units.sh`, gated — no-op without a user manager, and it re-enables
  only a unit that is *already* enabled, so it reconciles a decision rather than making one), and
  `scripts/verify-tools.sh` **fails** when the enablement has drifted. `--check` reports,
  `--plan` lists what `--apply` would touch. State table: `scripts/test-systemd-reconcile.sh`
  (130 checks, in CI as `systemd-reconcile-test`) — hermetic via a recording **`systemctl` stub**
  at the front of `PATH`, never via systemctl's absence: this box has a real one wired to the live
  user manager that holds the herdr server. Reading "the comparison is filesystem state, so no
  manager is needed" as "set `RECONCILE_NO_SYSTEMCTL=1` on every row" left `do_reconcile`'s body
  executing **zero times** across a 44/44 pass — the read-only decision layer pinned completely,
  the layer that DELETES SYMLINKS not at all. Making `do_reconcile` also `rm -f` the unit symlink,
  i.e. reproducing the incident the file exists to prevent, passed 44/44.
- **The reconciler read the unit FILE and called systemd's own extension mechanism drift.**
  `declared_targets` parsed `WantedBy=` out of one file's `[Install]` and never looked at
  `<unit>.d/*.conf`. A drop-in is exactly how you add an `[Install]` target without editing a
  reviewed unit, and this repo already ships one for `ExecStart` (DO-564) — so the checker
  reported the correct fix as a fault. It bites on a headless box: `herdr-server.service` is
  `WantedBy=graphical-session.target`, which never activates without a graphical session, so an
  EC2 dev box needs a `default.target` drop-in to start the server at boot. Measured on that box,
  the drop-in gave `✗ enabled under default.target graphical-session.target, but its unit file
  declares graphical-session.target` and a permanently red `verify-tools.sh` — the failure this
  file names five times, produced by the checker rather than by the machine. **No drop-in
  spelling avoids it**: clearing and re-setting `WantedBy=` still leaves the unit file declaring
  something else, so the choice was a red checker or no boot autostart. It is now the merged
  value — unit file, then `<unit>.d/*.conf` in filename order, an empty assignment clearing the
  list, which is systemd's own rule for a list-valued `[Install]` key. Scope deliberately matches
  `herdr-unit-dropin.sh`: only the drop-in directory NEXT TO THE UNIT, because a hand-placed one
  in `/etc/systemd/user` cannot be told from an administrator's decision. **DO-564 wrote the
  lesson and the sibling checker did not inherit it** — ask the OUTCOME, never the mechanism.
  Three messages saying "its unit file declares" became "it declares", since the targets no
  longer come from one file. Rows: `scripts/test-systemd-reconcile.sh` (130 → 142). 5 mutants,
  5 deaths — and the fifth only after a row was added: **deleting the reset rule from the
  UNIT-FILE half survived the whole suite**, because every reset fixture put the empty
  assignment in a drop-in. The merge has two halves and only one of them was pinned.

- **Four more ways the reconciler answered "nothing to look at" over real drift**, all fixed and
  each pinned by a row that fails without the fix: `[[ -e ]]` follows symlinks, so a **dangling**
  unit symlink (rename a source, don't re-run `./install`) was skipped and reported
  character-for-character like an empty machine; a unit whose `[Install]` was **deleted** kept its
  `.wants` link forever and read as `static`, "nothing to reconcile"; `pwd` is **logical** while
  the containment test used `readlink -f`, so a checkout reached through a symlink
  (`~/.dotfiles -> ~/src/dotfiles`) yielded zero managed units and a green tick; and the unit glob
  was hardcoded to `*.service`/`*.timer` in the function whose own header argues against
  hardcoding, so a drifted `.socket`/`.path`/`.target` was invisible.
- **"Clean" is not "complete" for the server environment.** `verify-tools.sh` used to ask only
  whether anything FORBIDDEN was present, so a server started at boot — before any graphical
  session existed to import an environment from — carried no forbidden variable and passed as
  clean while every pane had lost `gh --web`, `xdg-open` and the ssh agent. It now also asserts
  that the session variables the *user manager* offers are actually present in the server, and
  warns when `DISPLAY`/`WAYLAND_DISPLAY` name a **previous** login (a server deliberately
  survives logout, so it keeps the dead session's values). `SSH_AUTH_SOCK` is excluded from that
  value comparison on purpose — the launcher substitutes a stable symlink for it by design.
- **The herdr server's PATH is a snapshot taken when the server starts.** It carries the mise
  `installs/<tool>/<version>` dirs for whatever was *globally* configured at that instant (not
  mise's `shims` dir). Two consequences: a tool declared only in a project `.mise.toml` is
  invisible to the server, and a tool added globally *after* launch stays invisible until the
  server restarts — in both cases the popup or plugin opens and closes instantly with no error.
  Symlinking into `~/.local/bin` (also on the server PATH) makes a tool available *without* a
  restart, which is why `bun`, `lazygit` and `yazi` are linked there. An earlier version of this
  note said the server PATH "has no mise shims", which is literally true but misleading — it
  implied mise tools never resolve there, and they do.
- **A plugin pane that flickers and vanishes means the command exited.** The error is real but
  renders too briefly to read; reproduce it in a shell.
- **Plugins cannot declare their own keybindings** — wire them in `config.toml` and verify IDs
  with `herdr plugin action list`. An action appearing there does not mean its plugin is enabled.
- **Claude's trust-folder dialog defaults to "No, exit"** and a fresh worktree triggers it every
  time. Answer it on the **agent** surface (`herdr agent send-keys <pane> down`, then `enter`)
  *after* detection — pane-level keys sent as the dialog renders are silently dropped, because
  the TUI is not accepting input yet. `herdr agent prompt` refuses to type into a blocked agent.
- **`herdr agent wait` requires an already-detected agent.** It resolves its target up front and
  fails `agent_not_found`; it cannot wait *for* detection. Poll separately.
- **herdmates leaks plugin env into lead sessions** (upstream). Prefix plugin CLIs with
  `env -u HERDR_PLUGIN_STATE_DIR -u HERDR_PLUGIN_CONFIG_DIR`.
  **Stripping is only half the rule, and the other half bites (2026-09-14).** A plugin CLI that
  reads its OWN config needs those variables SET, not absent — `herdr-draft create` refused with
  `--account auto needs an account picker: set [clauth] picker in config.toml` on a machine where
  that picker is configured and on PATH, because it had inherited herdmates' `HERDR_PLUGIN_CONFIG_DIR`
  and `HERDR_PLUGIN_STATE_DIR` with no `HERDR_PLUGIN_ID` to say whose they were, so it declined them
  and resolved from built-in defaults. It said so rather than guessing, which is the only reason this
  was five minutes and not an afternoon. Export all three for the plugin you are actually invoking:
  `HERDR_PLUGIN_ID`, `HERDR_PLUGIN_CONFIG_DIR="$(herdr plugin config-dir <id>)"`, and
  `HERDR_PLUGIN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/<id>"` (herdr has a
  CLI for the config dir and none for the state dir). **`HERDR_PLUGIN_ID` is the load-bearing one**:
  it is what says whose the other two are, and a plugin that checks it is protected from this leak
  while one that does not silently uses another plugin's configuration.
- **`clauth start <profile>` bypasses the `claude()` shell function**, so it lacks what that function
  adds: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and a launch via `herdmates teammux-launch`, which
  passes `--settings '{"teammateMode":"tmux"}'` so teammates become herdr panes. Whether teams are
  enabled at all depends on the flag *reaching the process* — a contaminated server hands it to
  everyone, and such a session leads a team whose teammates run in-process, invisible to herdr
  (INFERRED from Claude Code's default `teammateMode`; not observed). Team leads need
  `clauth <profile>` then `claude`; prove it with `herdr pane process-info --pane <id>` showing
  `teammateMode`, not with `command -v tmux`.
- **`herdr plugin link` state is herdr-local** and is not restored by herdr-lazy after a rebuild.
- **If you spawn agents or panes, CLOSE THEM when their work is collected.** This is not tidiness
  — memory is the binding constraint on this box (8 threads, swap runs hot, and `system_health`
  exists because memory-pressure kills here are *silent*). A session that spawned six panes and
  left them idling after they had delivered drove the machine to **load 27 and 96% swap with 33
  claude processes**, endangering ten unrelated in-flight sessions; tearing those six down
  recovered it to load 11.5 / 84% / 23. An idle agent still holds its memory. Close panes you
  created once you have their output; keep one only if you have a concrete next task for it.
  (Closing panes you did *not* create is a different matter — don't, unless asked.) Enumerate with
  `hreap` — every Claude process **in a herdr pane**, detected or not, with idle age, memory and
  creator (default view is idle ≥ 30 min; `--older 0` shows all); `hreap --close --mine` closes
  only your registry-tagged idle spawns — **not** `herdr agent list`, which misses herdmates
  teammates and trust-dialog panes (it showed 14 while 33 claude processes ran — though note ~8 of
  those were Claude under Atrium's tmux, outside herdr panes and so outside `hreap` too; the tab
  bar's `agents <detected>/<procs>` gap is the full census). `hspawn` records each spawn in `~/.local/state/hspawn/`; `hdespawn <slug>` tears one down
  (pane, workspace, worktree, registry entry).
- **A pane id is not a permanent name, and the registry that keys on it is.** herdr allocates
  workspace ids from a short alphabet whose counter lives only in the running server
  (`~/.config/herdr/session.json` persists the workspaces but no next-id counter), so a restart
  reissues them from the start — the server log here shows `w4`, `w5`, `wN` and `wP` each created
  twice in five days — and every new workspace's first pane is `p1`. Meanwhile
  `~/.local/state/hspawn/` is a file tree that outlives every restart, and its entries are
  deliberately long-lived: each hspawn bail-out keeps its entry, and `hreap --close` annotates
  rather than deletes so `hdespawn` can finish later. So `wN:p1` names two different spawns, and
  hspawn's `>` used to destroy the older entry silently, orphaning its worktree and branch with
  nothing on disk pointing at them. It now renames it to `<pane>.stale-<ts>.json` and says so. Two
  habits follow: **`hdespawn <pane-id>` is the exact form** (a direct file lookup — `hdespawn
  <slug>` scans and REFUSES when two entries share a slug, which `--close` makes likely by
  design), and an entry whose workspace id now holds someone else's worktree is finished from the
  recorded path with herdr's live workspace left untouched, rather than refused forever. State
  table: `scripts/test-hspawn.sh` (235 checks, in CI as `hspawn-test`) — hermetic via a recording
  `herdr` **stub** at the front of `PATH`, never via herdr's absence: the box this was written on
  has a real one wired to a live server, and a suite that assumed absence would pass in CI and
  remove a real workspace here.
- **Teammates in a herdmates team are NOT detected as herdr agents.** They exist as panes but are
  absent from `herdr agent list`, the sidebar rows, the priority sort and toasts — only the lead
  is detected. A lead also reports `done` while its teammates are still working, so read the
  lead's own roster for progress, not its agent state. Same blind spot applies to any pane sitting
  on Claude's trust dialog. The cause is the process name: Claude Code execs teammates via its
  versioned binary, so `herdr pane process-info --pane <id>` shows a foreground process named
  `2.1.251` rather than `claude`, and herdr never consults the Claude manifest — although
  `herdr agent explain --file <screen> --agent claude` accepts the same pane's screen (`state: idle`,
  rule `live_prompt_box`). `herdr agent explain <pane>` is the first diagnostic; `agent_not_found`
  means nothing was detected at all. An upstream report is drafted, not yet filed.
  **The reaping consequence, learned the hard way on 2026-09-07:** in `hreap`, a row reading
  `DET no` / `unknown` and idle for many hours is a **teammate**, not an abandoned session. Six
  such rows — 17–20 h idle, named `general-purpose`, ~380 MB each — were about to be closed as
  "stale, pure upside" when `process-info` showed every one of them running `2.1.259`, the
  versioned-binary signature above. They belonged to leads that were still working. CLAUDE.md's
  own words apply to the status field too: `unknown` "does not prove completion". A clean `git
  status` in the pane's cwd is not evidence either — a teammate's work in progress lives in its
  conversation and in findings it has not yet reported to its lead. The reap path for a teammate
  is **`TaskStop` from its lead**, never closing its pane; left alone, those six were reaped
  correctly by their leads within the hour.
- **The build/test parallelism caps key on `$HERDR_PANE_ID`** (`zsh/zshrc.buildlimits`), and
  that gate was `$ATRIUM_SESSION` until 2026-09-01. An *unset* variable selects the LOOSE
  tier, so the day Atrium stopped running, every agent pane silently got the half-the-cores
  budget meant for a solo human — the exact over-subscription the file exists to prevent,
  arriving as a config file that still looked correct. Any migration that moves the marker
  variable has this shape: check what an unset gate falls back to before assuming the old
  name is merely dead. `build-limits` prints which tier is active.
- **The agent tier was a hardcoded 2 and so did not survive leaving the laptop (2026-09-16).**
  `zshrc.buildlimits` capped any pane with `$HERDR_PANE_ID` at 2 workers regardless of
  hardware — right for the 8-thread box it was tuned on, where a dozen agents compete, and
  wrong the moment work moves to a bigger machine. Measured on the 16-core EC2 dev box the
  day it was set up to absorb work: an agent pane got `-j2` while fourteen cores idled, so
  the constraint had travelled with the work instead of being left behind. The tier is
  `cores/4` now, which yields **exactly 2 on 8 threads** — the machine it was written for
  does not move at all — 4 on 16, 16 on 64, with one floor of 2 shared by both tiers.
  `BUILD_LIMITS_JOBS` overrides either tier for a box whose shape you actually know; set it
  in `~/.zshrc.local`, which is sourced after this module. An unusable value (0, negative,
  decimal, non-numeric) leaves the computed tier alone rather than being taken literally —
  `0` disables parallelism outright and the rest land in `MAKEFLAGS` as a malformed flag,
  both worse than the default they were meant to improve. It is not silent: `build-limits`
  gained a `source` line naming the tier, the override, or the override it ignored and why.
  State table: `scripts/test-buildlimits.sh` (35 checks, in CI as `buildlimits-test`) — the
  module's first, since `zsh -n` was all it ever had. Hermetic via an **`nproc` stub on a
  from-scratch PATH**: the whole subject is what the module derives from a core count, and
  the row that matters most ("8 cores is still exactly 2") cannot be written at all without
  choosing the hardware. Two harness defects worth keeping: leaving `/usr/bin` on PATH let
  the "nproc missing" rows find the REAL nproc and measure the host, and the first
  before/after comparison inherited `MAKEFLAGS` from the herdr pane the suite was run in,
  so both modules reported the pane's own `-j2` — the same env-leak this file records for
  `CLAUDE_CONFIG_DIR` in `test-hspawn.sh`, in the one variable being measured. 7 mutants,
  7 deaths.
- **The sidebar's account tag named the wrong account on every isolated pane, and that
  is the surface that hid the concentration (DO-590).** clauth's herdr plugin resolves
  the account from the **machine-wide active profile**, and it cannot see a foreign
  `CLAUDE_CONFIG_DIR` — so once `claude()` started isolating every session by default,
  the one column that says which account a pane is spending stopped tracking it.
  Measured 2026-09-09 on a pane billing `quantivly-2`: the published token was
  `clauth: "unknown"`, the same literal sentinel `clauth which` returns from inside an
  isolated shell. Not a wrong-but-plausible name — no name at all.
  The fix belongs here rather than upstream because our own
  `claude/hooks/session-statusline.sh` runs **inside** the session, so a token it
  derives from that process's own `CLAUDE_CONFIG_DIR` names the credential **file**
  the pane reads rather than a machine-wide setting. **It is not "correct by
  construction"** — that phrasing shipped in the first draft and is the
  declared-vs-effective overclaim this file records twice already. `$acct` is a
  directory name, not an API answer: a `/login` as a different account inside an
  isolated session leaves it unchanged and wrong. What it beats is the alternative,
  which reports an account belonging to a different pane entirely. It publishes `acct`, and the claude
  row in `config/herdr/config.toml` consumes `$acct` in place of `$clauth`. **Both were
  not kept**: two account fields disagreeing, one of them reading `unknown`, is the
  surface being removed, not one to double. `acct=shared` is a **finding, not a
  formatting fallback** — it means the session is on the shared global credential, the
  file a profile switch overwrites under every holder at once.
  Three things the change turned up that outlast the change itself:
  - **A publisher and a consumer that each fail silently can only be checked as a
    PAIR.** An unpublished token renders as nothing; an unconsumed one is never drawn.
    So a half-applied deploy — `./install` relinks `config.toml`, a checkout that moved
    without it does not — looks exactly like a healthy sidebar from either side alone.
    `verify-tools.sh --herdr` asserts the two together, against the **live**
    `~/.config/herdr/config.toml` and never the repo copy: the repo copy always carries
    `$acct` after this change, so reading it would print a green tick for precisely the
    half-applied state the check exists to catch. A mutation that swapped the path
    proved it.
  - **Presence is not correctness, and the state table said otherwise for a while.**
    Every row asserted that `acct` was published and consumed; none asserted its
    VALUE. A hook hardcoded to `acct=shared` therefore passed the entire table while
    showing every pane the same wrong account — the original bug, reintroduced, under
    a green suite. Only mutation testing found it (M6 survived; six derivation rows
    were added to kill it). The derivation *is* the feature: rows that check the
    plumbing and not the answer are decoration.
  - **The pair check itself shipped with two of this file's own recorded faults, and
    CI was 20/20 green over both.** It read the claude row by shelling out to python3
    and its stdlib TOML module. python3 had never been *invoked* in
    `scripts/verify-tools.sh` — it appeared only as a NAME inside
    `HERDR_SERVER_DEPS` — so that was a new dependency in a checker, "a new way for a
    check to go quiet"; and that module is 3.11+, while Ubuntu 20.04, the first
    outside adopter's box, ships 3.8. Worse, **every** non-zero exit (python3 absent,
    module absent, file unreadable) was collapsed into `acct_con=0`, which printed a
    confident `✗ the hook publishes $acct but no claude sidebar row consumes it` — a
    FAIL naming a fault that does not exist, taking the exit code with it. On the one
    machine class the herdr work exists to support, the new check would have been red
    on arrival: the permanently-red checker, **sixth** recurrence, inside the check
    written while citing the rule. Now a bounded `sed` range (the `fallback_chain`
    technique) and a **tri-state**, where "could not read the row" is `NOT CHECKED`
    and never a verdict.
  - **Three of the new rows asserted an exit code against a fixture that was already
    failing something else.** `new_home` does not write the agent-skill file, so
    `verify-tools.sh --herdr` returned 1 regardless of what the account check did, and
    "takes the exit code with it" passed without testing anything — green for no
    reason, which this file already rates as badly as red for no reason. Build the
    fixture with `wire`, which the suite's own end-to-end row proves exits 0, so the
    thing under test is the only thing that can move the code.
  - **A row that greps for a defect will match the comment explaining the defect.**
    The row asserting the checker no longer imports the TOML module matched the
    checker's own comment saying why it does not. Both were right; the pair was
    circular. The comment now says so explicitly, so the next person does not
    reintroduce the literal string.
  - **`tr -d` deletes BYTES, so a multi-byte strip corrupts its neighbours.** The
    guard against U+00B7 (herdr's own token separator) shipped as
    `tr -d '\302\267'`, which removes those two bytes *individually* rather than the
    character they spell — measured, it turns U+00B1 (`C2 B1`) into a lone `\xB1` and
    U+04B7 (`D2 B7`) into a lone `\xD2`, i.e. **invalid UTF-8 published straight into
    the sidebar**, which is worse than the separator it was guarding against. `sed
    's/·//g'` matches the pair as a unit in a UTF-8 *and* a C locale (both checked;
    `/bin/sh` here is dash and the locale is not guaranteed), and sed is already used
    throughout that file so it adds no dependency. **The row that covered this passed
    the entire time**, because it only ever fed in the exact character being stripped:
    a guard needs a row for what it must LEAVE ALONE, not only for what it removes.
    Found by asking what a reviewer would attack — after CI had gone 20/20 green over
    it.
  - **A fixture `$HOME` needs `.cache/`.** The hook redirects the publish call's stderr
    into `$HOME/.cache/`, so without that directory the redirection itself fails,
    `herdr` is never exec'd, and the stub records nothing — which reads identically to
    "the hook published no token". The first draft of those rows failed for exactly
    that reason, and had passed beforehand only because an ad-hoc run used the real
    `$HOME`.

- **The sidebar publisher needs THREE things wired, and `./install` only does one** —
  `scripts/herdr-claude-wire.sh` now does the other two, and `verify-tools.sh --herdr` fails when
  they are missing (before DO-563 nothing checked either, in either install path).
  `claude/hooks/session-statusline.sh` is symlinked to `~/.claude/hooks/` by dotbot, but it must
  also be set as `statusLine` in `~/.claude/settings.json` (user-level, not in this repo), and that
  entry needs `"refreshInterval": 60` — without the interval the idle band freezes when the session
  goes quiet and every token then expires on the 4-minute TTL, blanking the rows. Without the
  statusLine entry it never runs, every `$mdl`/`$eff_*`/`$ctx_*` token resolves to nothing, and those sidebar
  rows render empty with no error. It doubles as the in-pane status line, so visible model/context
  text inside a pane means the publisher is alive.
- **`//` substitutes for null, never for a type error.** `jq -r '.statusLine.command // ""'`
  *errors* on a `statusLine` that is not an object (`Cannot index string with string`), and the
  discarded exit status left an empty capture that read as **the key is absent** — so
  `herdr-claude-wire.sh` overwrote another tool's statusLine and printed "Claude Code is wired",
  exit 0, in exactly the state the script is written to refuse. Read the **type** first
  (`.statusLine | type`), and land "could not read the answer" in the same arm as "it belongs to
  somebody else": ours is a positive test — an object whose `.command` names our own hook — never
  the absence of evidence against. `verify-tools.sh` had the mirror-image bug, reporting the fault
  by leaking jq's parser error into its own message, which satisfied a row that merely looked for
  the word "string". An object is not enough either: `{"command":null}` and
  `{"type":"custom","script":"/opt/x"}` are objects whose `.command` comes back empty.
- **The permanently-red checker recurred inside the change written to remove one.** DO-563 exists
  because `verify-tools.sh` printed a ✗ that the write-up had to tell modular adopters in prose to
  ignore; the Claude-wiring section it added then asserted unconditionally, so any machine without
  herdr and Claude Code was red forever with nothing to act on, and a clean `./install` was red
  before anyone had the chance to wire anything. It reports `○ skipped` when there is nothing to
  wire and fails only when herdr and `~/.claude` are both present. This file already documents the
  class twice (gh-doctor, backup-doctor); a third recurrence means it is not something to remember
  but a question to ask of **every new check**: on a machine that legitimately lacks this subject,
  what does it print, and what can the reader do about it?
- **The first outside adopter's three install failures were one root cause: the modular path
  provides no mise, and step 1 of every write-up assumed it did (2026-09-04).** `./install
  --herdr` deliberately links no `~/.config/mise/config.toml`, so nothing puts mise's node on
  `PATH` — and the documented activation line was the bare `eval "$(mise activate zsh)"`, which
  cannot work at that point because mise is not on `PATH` yet. `zsh/zshrc.conditionals` has had
  the two-branch form (`command -v mise` **elif** `-x ~/.local/bin/mise`) all along; the
  instructions dropped it. Downstream, `node` resolved to `/usr/bin/node` at v10.19.0 and
  `herdr-lazy install` died building `tdi/herdr-worktree-setup` — whose build is `npm ci` — with
  `npm v9.2.0 is known not to run on Node.js v10.19.0`, so the error blamed **npm**, the newer of
  the two. `HERDR_GUIDE.md` §3 step 0 had also attributed node to the Linear plugin, which has no
  build step at all, and told the reader "step 1 provides them", true only of the FULL install.
  Separately `persiyanov/herdr-reviewr`'s build hook runs `curl --retry-all-errors`, added in
  **curl 7.71.0**; an older curl exits **2** on the unknown option and herdr reports `plugin
  build failed … status: exit status: 2`, naming neither curl nor the flag. `apt` only supplies
  what the release ships (Ubuntu 20.04: curl 7.68, node 10.19), so both are floors to state, not
  bugs to chase. **The lesson is about the checker, not the versions:** `herdr-deps-check.sh`
  asked only "is it on `PATH`", so it printed a green tick over both — a presence check cannot
  see a version problem, and two of the three failures were versions. It now carries floors for
  curl and node (18.0.0, npm's own supported floor, not a second opinion about `.mise.toml`'s
  20), checks `npm` at all (it was in no list), reports an unparseable version as its own ⚠
  state rather than as agreement, and compares fields by hand rather than with `sort -V`, which
  BSD sort lacks — a floor that fails open on a Mac is worse than no floor. It also honours
  `-t 1` now: its colour was unconditional, which put escapes into every redirect **and** made
  `✓ curl` un-greppable, so the state-table row asserting an old curl gets no ✓ had been passing
  whatever was printed. A checker whose output cannot be grepped cannot be pinned.
- **`verify-tools.sh` answered a question nobody had asked yet.** The same adopter ran
  `--herdr` four steps early and reasonably asked whether `✗ bun / lazygit / yazi / clauth:
  MISSING under the server PATH` was a problem. It was not — `clauth` is *installed by* the
  plugin step, so a check run before it necessarily shows it missing — and both the page and the
  installer's next-steps text say the plugin-dependency lines do not affect the exit code. But
  neither can control *when* somebody runs the checker, so the advisory now prints in the
  section itself, only when something is missing (unconditionally would make it a line nobody
  reads). His run also took a branch this machine never does — `no server running — resolving
  against the launcher's declared PATH` — which is correct and was phrased as though it were a
  live measurement; it now says it is a **prediction** about the server the enable step will
  start.
- **We shipped a config that depends on an install step none of our instructions mention.**
  `config/herdr/config.toml` sets `[session] resume_agents_on_restore = true`, whose own comment
  says it "Requires the official integration per agent (`herdr integration install claude`)" —
  and that command appeared in **no** install path and **no** checker: not `install`, not
  `install.conf.herdr.yaml`, not `herdr-claude-wire.sh`, not `HERDR_GUIDE.md`, not
  `verify-tools.sh`. It stayed invisible for the most ordinary reason there is: `herdr
  integration status` on this workstation says `claude: current (v8)`, installed here long
  before any of those files were written. Found by the first outside adopter, 2026-09-04.
  **What breaks without it is session resume, NOT agent-state detection** — read off the
  installed hook rather than assumed: it is one `SessionStart` hook calling
  `pane.report_agent_session` with the Claude session id and transcript path, so a server
  restart returns the panes without their conversations, silently. Detection is screen-scraping
  either way; the hook's own comment records that older versions mapped `SubagentStop` to state
  and that this was removed upstream, so do not restate the old behaviour from memory. It now
  lives in `scripts/herdr-claude-wire.sh` — the one script that already owns what dotbot cannot
  write into `~/.claude` — and `verify-tools.sh --herdr` asserts it. Probed in a throwaway
  `$HOME` rather than assumed before wiring it in: it does not prompt, exits 0 with stdin
  closed, is idempotent, and **merges** `settings.json`, so an existing `statusLine`, unrelated
  top-level keys and other `SessionStart` hooks all survive — which is load-bearing, because the
  wirer writes the statusLine into that same file a few lines earlier. The wirer re-reads the
  status afterwards rather than trusting exit 0, and an older herdr with no `integration`
  subcommand is a ⚠, not a ✗: upgrading herdr is not a fix a report can ask for.
- **State table: `scripts/test-herdr-modular.sh`** (170 checks, in CI as `herdr-modular-test`) —
  the two commands a modular adopter runs, hermetic via a recording `herdr` stub and fake `$HOME`.
  Two defects in the suite itself are worth more than most of its rows:
  - **A row that cannot reach the branch it names is unfailable.** The row asserting `--herdr`
    never prints the `ln -sfn` that pins ~25 tools globally passed with the full-install report
    un-gated *entirely* — that string is emitted only from the mise-drift FAIL branch, and the
    fake `$HOME` had no active mise config, so every run took the "nothing to compare" branch
    instead. The one row the whole change's rationale rests on was decorative. The fixture now
    writes a real, differing `~/.config/mise/config.toml` to make the branch reachable. Mutation
    testing is what found it: a row that passes both ways is worthless however carefully worded.
  - **A suite that shells out to the live machine is not hermetic, whatever its header says.** It
    `pgrep`'d for the real herdr server, so a contaminated server turned two exit-code rows red
    for a reason unrelated to the diff *and* made every row expecting `rc=1` pass for the wrong
    reason — red for no reason and green for no reason at once, under a header claiming "no
    server". Stub it, the way `test-systemd-reconcile.sh` stubs `systemctl`; never rely on the
    tool's absence, because this box has the real thing.
