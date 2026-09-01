# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **`apply-gnome-settings.sh` now says when the machine-specific layer overrides the portable
  one** (`scripts/apply-gnome-settings.sh`). Both layers log a plain `✓`, so a `~/.gnome-settings.local`
  line that undoes a setting three lines after the portable layer applied it was invisible: two
  successes that cancel, reported as two successes. That is exactly how `grp:alt_shift_toggle`
  stayed enabled — `apply_input_sources` cleared it, the local file re-enabled it every run, and
  all four of herdr's `alt+shift+arrow` bindings were dead for as long as they had existed while
  `gnome-apply` reported success and `gsettings get` showed the override as though it were the
  applied value. An overriding set now reads `✓ key → value  (overrides <previous>, set above)`.
  A NOTE rather than a warning, deliberately: overriding is what that layer is *for* — the
  workspace-switch keys are legitimate overrides — and a warning on each would be noise in the
  normal case, which is how a diagnostic becomes one nobody reads. `GNOME_LOCAL_OVERRIDES` makes
  the path injectable so the behaviour can be exercised against a fixture.

### Fixed

- **Backups: the mount-point guard's last enumerated case is now a structural rule.**
  `external_mount_point_sane` refused `/media/$USER` and `/run/media/$USER` as literal
  strings, and both holes ever found in that guard were in exactly those two entries — an
  empty `$USER` collapsed them to `/media/`, and `/media/./<user>` resolved past them. That
  is not a coincidence: for every other entry on the deny-list the list is belt-and-braces,
  because `/etc`, `/usr` and `$HOME` are non-empty and the content checks refuse them
  unlisted. The udisks parents are the one dangerous directory that is *legitimately empty*
  whenever no drive is docked — and legitimately the parent of the correct answer — so
  there the string list was load-bearing and alone. `path_is_account_directory` replaces
  them: `<parent>/<leaf>` under `/home`, `/media` or `/run/media` is refused when
  `getent passwd` says `<leaf>` names a **regular login account** — uid within login.defs'
  `UID_MIN`..`UID_MAX`, **or** a home directory under `/home/`. The window alone is right
  for local accounts and useless for the ones the `getent` call was justified by: SSSD's
  AD id-mapping starts at 200000 by default, real AD-mapped uids land in the millions, and
  systemd-homed allocates above `UID_MAX`, so a domain-joined workstation had no protection
  past the current user. Their home is `/home/<name>`, which catches them while still
  matching none of `backup` (`/var/backups`), `games`, `nobody` or `root` (`/root`). It covers every account rather than just the current one, and it
  asks nothing about who is running the installer, so the `$USER` class of bug cannot recur
  in it. The literals stay as belt-and-braces but no longer carry the guard.
  The uid bound is the discriminator, not a detail: matching *any* passwd entry would
  refuse `/media/backup` — a plausible hand-made mount point, `backup` being a stock uid-34
  account — and that is not a harmless over-rejection, because `install_external_udev`
  treats an unusable mount point as a reason to **remove** the hotplug rule, so a working
  install would silently lose its remount-on-dock. It is also not a depth rule ("three
  components under `/media`"), which would reject `/media/backup-hdd`, `/media/external`
  and `/mnt/store`. The passwd *name* field is compared back so a numeric key
  (`getent passwd 1000`) does not make `/media/1000` look like a user directory, and the
  lookup runs under `timeout` so an unreachable NSS source cannot hang the installer.
  An **unanswered** lookup is not read as a clean "no": only `getent`'s exit 2 means "no
  such key", while `timeout`'s 124 and a missing `getent` (127) mean the question never
  ran, and folding those into "not an account" switched the whole rule off in silence on
  precisely the LDAP/SSSD hosts the timeout was added for. The guard now reports a third
  status for "could not determine" and refuses — a correct mount point is one component
  under `/media` too, so guessing would wave through `/media/<another-login-user>` just as
  readily — with a message that names the lookup rather than blaming the path, since the
  fix is name-service resolution and not `BACKUP_EXTERNAL_REPO`. That refusal is issued from the **end** of
  the function, after every check that could settle the path with certainty: returning it
  as soon as the lookup failed downgraded certain refusals to uncertain ones, turning
  `BACKUP_EXTERNAL_REPO=$HOME/restic` — the most canonical error there is — into "could not
  check, keeping the rule" on any host whose name service was merely slow, and leaving the
  `/media/$USER` literals unreachable in the one state where anything rests on them.
  **Every** step that installs
  persistent state keys on that status to change nothing at all, so a transient NSS failure
  cannot undo what an earlier successful run got right; only a genuinely unusable mount
  point still tears state down. All four consumers were checked individually: the fstab
  write skips, `install_external_udev` keeps the existing rule, `init_repos` skips and says
  "could not be checked" rather than "unusable", and `install_external_schedule` returns
  **before it writes** — that ordering matters, because it re-renders the unit from the
  template first and that resets `ConditionPathExists` to the template's own path, so a
  later bail-out has already destroyed what it meant to preserve, and it then removes the
  `After=` ordering drop-in. A unit whose `ConditionPathExists` names a nonexistent path is
  *skipped, not failed*, and `backup-doctor` has no check for `10-external-mount.conf`, so
  the whole loss would have been invisible. The lookup bound is 5s rather than 2, since an
  unanswered lookup is now a refusal and a cold SSSD cache over a VPN routinely takes
  several seconds — too tight a bound makes a healthy host permanently unconfigurable.
  68 checks → 99, driven by a fake `getent` on PATH
  (a shell function is invisible to a lookup made through `timeout`, so a stub would have
  passed vacuously), and the two sub-shell probes now print a positive token so a broken
  probe fails loudly instead of asserting an absence it would produce anyway.

### Added
- **Dotfiles live-config guard** (`dotfiles-doctor`, `dotfiles-work`, a one-line warning on
  the first prompt of an off-pin shell; `zsh/functions/system.sh`, `zshrc`). This repo is
  installed with dotbot `link:`, so every managed file is a symlink into the working tree
  and `git checkout` is a **deploy**: HEAD moves and `~/.zshrc`, `~/.gitconfig`,
  `~/.config/git/ignore` and the gh account configs change under the running system, with
  no install step and a clean `git status` throughout. Both directions bit us on
  2026-08-31 — a checkout predating #87 kept `backup-doctor` printing its false
  "external HDD not docked (normal — B2 covers offsite)" reassurance long after the fix
  merged, and ~830 lines of an open PR's `zshrc.company` were live in every new shell.
  The convention is now: primary checkout pinned to `main`, feature work in worktrees
  (nothing symlinks into one). `dotfiles-doctor` reports pin state, **how stale the
  `origin/main` ref it compares against is** (nothing here fetches on a schedule, so
  "not behind" is only as current as the last `git fetch`; `--fetch` refreshes it),
  ahead/behind, the file-level blast radius — the link list *plus* `zsh/` and `scripts/`,
  both of which are live without being linked — uncommitted changes to those files, and
  link integrity in four directions (declared-but-not-installed, installed-but-dangling,
  linked-but-pointing-outside-the-checkout, and linked-inside-it-but-at-the-wrong-file:
  rename a source without re-running `./install` and the other three all pass while the
  live file stays the old source). The startup check reads `.git/HEAD` and
  the two ref files directly rather than forking git — 0.07 ms / 0.3 ms against 2–5 ms for
  one `git symbolic-ref` — and fires both when the checkout is off `main` and when it is
  on `main` at a different commit than `origin/main`, which is the #87 case and the one
  with no other detection path — and, since both of those shas come off local disk and so
  agree the moment the machine stops fetching, when the ref they came from is older than
  `DOTFILES_STALE_WARN_HOURS` (168 = 7d, far more forgiving than the doctor's 24h because
  this one fires unasked). Deferred to the first prompt so p10k's instant prompt does not
  turn it into a warning box, and shown once per *shell* rather than once per source, so
  `zshreload` does not reprint it. `DOTFILES_GUARD_QUIET=1` opts out;
  `DOTFILES_PIN_BRANCH`, `DOTFILES_ROOT`, `DOTFILES_WORKTREES`,
  `DOTFILES_FETCH_MAX_AGE_HOURS`, `DOTFILES_STALE_WARN_HOURS` and
  `DOTFILES_EXPECTED_DIRTY` (scalar or zsh array) override the rest.
- **`./install` refuses to run from a git worktree** — git-dir ≠ git-common-dir, which is
  git's own definition, and unlike `[[ -f .git ]]` does not also catch a
  `--separate-git-dir` clone or a submodule (`DOTFILES_ALLOW_WORKTREE_INSTALL=1`
  overrides). Installing from a worktree re-points every managed symlink — `~/.zshrc`,
  `~/.gitconfig`, the gh configs — at a feature branch, with a clean `git status` either
  side and nothing but `readlink` to reveal it; one `./install` in the wrong directory
  defeated the whole feature. `dotfiles-doctor` now also resolves each link and fails when
  one lands outside the checkout, and the startup line resolves `~/.zshrc` (forklessly,
  with zsh's `:A`) to report a shell sourced from somewhere else entirely — between them
  they catch the machines already installed that way.
- **[scripts/test-dotfiles-guard.sh](scripts/test-dotfiles-guard.sh)** — 195-check state
  table for the guard, run in CI. Every bug found in the guard so far printed a green tick
  rather than an error, so each is a row: `local path` in zsh is tied to the `PATH` array,
  so declaring it blanked PATH and every later external command vanished — git's empty
  output then read as "no drift" and the doctor announced "none — every live file
  matches"; folding git's stderr into the parsed value with `2>&1` produced a section that
  printed nothing at all; a stale remote-tracking ref made a merged-but-not-running fix
  report "not behind"; an unparseable `install.conf.yaml` resolved no live paths, which
  read as no drift; a symlink into another worktree passed as "17/17 links present"; and a
  malformed `~/.gitconfig` turned every git failure into a confident wrong claim. The
  fixture builds its own repo, remote and `HOME`, so the table is hermetic. A second
  review pass added rows for every way a link source can be got wrong without anything
  saying so — a quoted YAML scalar, dotbot's null form, an entry left open past the end of
  the `link:` block, and a declared source absent from the tree — because a git pathspec
  that matches nothing exits 0 with empty output, so each of those *narrowed* the drift
  check rather than failing it. Plus: `--separate-git-dir` and linked-worktree layouts,
  the mise symlink `install` creates itself, spaced and renamed paths in the working-tree
  check, a stale-but-identical ref, `./install`'s refusal end to end, the startup line
  surviving a reload, and a run whose ✓ printf fails for real (`/dev/full` — a closed fd
  does not do it: zsh's printf warns and returns 0 there).

- **`bun` pinned in `.mise.toml`** (1.4.0) — runtime for the herdr `gh-pr` plugin. herdr's
  server PATH carries no mise shims, so it must also be reachable as `~/.local/bin/bun`
  (`ln -s "$(mise which bun)" ~/.local/bin/bun`).
- **[docs/HERDR_GUIDE.md](docs/HERDR_GUIDE.md)** — the team-facing guide to the recommended
  agentic dev setup: prerequisites and how to verify them, keymap with rationale, sidebar
  semantics, plugins, `hspawn`, troubleshooting, and criteria for who should use herdr at all
  (non-developers are pointed at Orca, with the evaluation's limits stated). Leads with the
  lesson that cost the most time: **every layer of this stack fails silently** — `config
  check: ok` means the file parses, nothing more.
- **`yazi` pinned in `.mise.toml`** (26.8.15) and added to `scripts/verify-tools.sh`. It was
  bound to `alt+y` with its config symlinked into `~/.config/yazi`, but the binary had never
  been installed, so the popup opened and closed instantly.
- **herdr chord-first keymap and coloured agent sidebar** (`config/herdr/config.toml`,
  `scripts/herdr-keyprobe.sh`, `hspawn` in `zsh/zshrc.company`, local `sidebar-icons`
  plugin). Root cause of the earlier "3-modifier chords don't work": GNOME's
  `grp:alt_shift_toggle` xkb option made Alt+Shift the layout switch and swallowed one
  modifier of every Alt+Shift chord — now cleared by `apply-gnome-settings.sh`
  (Super+space remains the switch).
- **`system_health` now reports memory-pressure kills** (earlyoom / systemd-oomd /
  kernel OOM killer) over the last 7 days, with the most recent victim. These are
  worth surfacing because the damage is *silent*: a process killed mid-pipeline
  still lets the pipeline exit 0 with empty output, so the result is a confident
  wrong answer rather than an error. Observed on 2026-08-03, when a 16 GB search
  was shed this way and its empty output was read as "no matches". The match
  pattern requires `sending SIG… to process` — earlyoom's startup banner
  (`sending SIGTERM when mem avail <= 10.00%`) otherwise counts as a kill on every
  boot. When the system journal can't be read at all (no `journalctl`; a user
  outside `adm`/`systemd-journal`, who sees only their own journal while these
  kills are logged by root units) the check reports `skipped` rather than a clean
  ✓ — a false all-clear would reproduce the exact failure mode it exists to catch.
  The journal read is narrowed to the `earlyoom`/`systemd-oomd`/`kernel`
  identifiers, which is the same answer in 0.3s instead of 3.3s.
- **Broadcast-kill audit tripwire** — a two-line auditd rule
  (`audit/99-logout-catch.rules`, installed root-owned by `audit-setup` /
  `scripts/setup-audit-rules.sh`) that records any real `kill(-1, sig)`: *"signal
  every process I may signal"*, which on a desktop is the whole graphical
  session. Motivated by three unexplained GNOME logouts (2026-08-02/03) in which
  a broadcast kill from a project test suite produced a completely orderly
  teardown — no crash, no OOM, no coredump, nothing in the journal — leaving the
  audit log as the only place the sender's identity could exist.
  - `audit-status` reports every way this instrumentation can go quiet as its own
    distinct failure, so that "nothing found" can only mean "nothing happened":
    a rejected rule field leaves zero rules loaded with no error; auditing
    switched off (`enabled 0`); **no daemon registered (`pid 0`)** — rules live in
    the kernel, so `auditctl -l` lists them happily while records go to the ring
    buffer instead of `/var/log/audit/audit.log`, leaving `ausearch` blind
    forever; a climbing `lost` counter dropping records; `/etc` drifted from
    `~/.dotfiles` (the file is *copied*, so editing the repo alone changes
    nothing); and auditd's `SUSPEND` disk actions, which stop logging quietly
    when `/var` runs low. Exits non-zero on the fatal ones.
  - `audit-sweeps [hours]` reads hits, encoding the fact that `ausearch -ts`
    takes the date and time as **two** arguments — quoting them as one string
    matches nothing and prints no error. It validates `hours`, and distinguishes
    ausearch's benign "no matches" from a real read failure rather than
    reporting both as an all-clear.
  - `audit-setup` asserts all three arms (rules loaded, auditing on, daemon
    recording) and fails loudly otherwise; it prompts before installing the
    auditd package, since that has a system-wide side effect (`--yes` to skip).
  - Scope is `kill(-1, …)` only; `audit/99-logout-catch.rules` documents why
    `kill(0, …)` and `kill(-pgid, …)` are deliberately excluded.
  - Note: installing auditd moves AppArmor denials out of `journalctl -k` into
    `sudo ausearch -m AVC`. See CLAUDE.md → Audit Tripwire and
    docs/TROUBLESHOOTING.md → "Desktop session suddenly logged out".
- **DO-449 — Backup hardening (verification, health checks, safe-restore guardrails)**:
  closes the *silent-failure* class for the backup system.
  - `backup-doctor` — full-chain correctness assertion (file perms, config drift vs.
    `~/.dotfiles`, the DO-448 EnvironmentFile drop-in, snapshot age, that healthcheck URLs are
    actually set, emergency-kit/LUKS-header freshness, disk space); non-zero exit on any failure.
  - Weekly verification — `scripts/backup-verify.sh` + `systemd/restic-verify.{service,timer}`
    run a **content canary** (critical paths still present in the latest snapshot, catching a
    regressed exclude) and a **restore canary** (one file actually restored), decoupled from the
    `[b2.check]` integrity check and skipping cleanly when offline. `backup-drill` is the
    on-demand equivalent. `restic check` proves *intact*; this proves *complete + restorable*.
  - `backup-restore-system` — guarded `/etc`-slice restore that always excludes
    `fstab`/`crypttab`/`machine-id`/`ssh_host_*`, so the bare-metal restore can't break boot.
  - `setup-backup.sh` now warns when `BACKUP_HC_URL_*` are blank (alerting would be inert),
    re-takes the LUKS header when stale, and points to `backup-doctor`. New
    `BACKUP_HC_URL_VERIFY` / `BACKUP_CANARY_PATHS` knobs; optional `timeshift-autosnap` apt hook.
  See [docs/BACKUP_AND_RESTORE_GUIDE.md](docs/BACKUP_AND_RESTORE_GUIDE.md).
- **Backup & restore workflow** — encrypted 3-2-1 backups via restic + resticprofile to an
  external HDD (dock-triggered) and Backblaze B2 (offsite, append-only key + lifecycle for
  ransomware resistance). Declarative policy in `resticprofile/profiles.toml`; machine config
  in `~/.backup.local` (template + `backup-init`); one-time installer `scripts/setup-backup.sh`
  (`backup-setup`) wires repos, systemd timers, the dock trigger, Timeshift, a LUKS header
  backup, and an age-encrypted offline emergency kit. New `backup-*` functions in
  `zsh/functions/system.sh`. See
  [docs/BACKUP_AND_RESTORE_GUIDE.md](docs/BACKUP_AND_RESTORE_GUIDE.md).

### Changed
- **Three more findings from the independent review of #89.** (1) The launcher preferred the
  CALLER's `SSH_AUTH_SOCK` over the stable `~/.ssh/ssh_auth_sock` symlink, which made the symlink
  branch dead on the one restart path the runbooks sanction — `systemctl --user restart` carries
  the manager's environment, so the live snap path always won and the server got the snapshot the
  indirection exists to avoid. The header already described the intended order; the code did the
  opposite. (2) `hdespawn`'s worktree-path recovery was gated on a live workspace, so it was
  unreachable in the post-`hreap --close` state it exists for: hdespawn then said "no worktree dir
  on disk", removed the registry entry anyway, and orphaned the worktree and its branch. It now
  runs ungated and falls back to `git worktree list`, which knows even when herdr does not.
  (3) `plugins.lock` still pinned `herdr-auto-pilot` after `plugins.list` dropped it, so
  `herdr-lazy restore` would have reinstated the plugin the change exists to keep out.
- **`./install` reconciles systemd user unit enablement, and `verify-tools.sh` fails when it has
  drifted** (`scripts/reconcile-systemd-units.sh`, `install.conf.yaml`, `scripts/verify-tools.sh`,
  `systemd/herdr-server.service`). A linked unit is not a reconciled one: systemd records
  `[Install]` at `enable` time as a `<target>.target.wants/` symlink, and editing `WantedBy=`
  afterwards moves nothing — not even after `daemon-reload`, which re-reads the unit but never
  revisits the symlink. The obvious primitive is a trap: `systemctl reenable` (= `disable` +
  `enable`) DESTROYS a dotbot-installed unit, because `disable` removes every symlink in the unit
  search path pointing at it — and the entry in `~/.config/systemd/user` is such a symlink, into
  the checkout. The enable half then fails with "Unit does not exist" and the unit is left neither
  linked nor enabled; this happened on a real machine on 2026-09-01, following advice added in the
  same series of commits. The reconciler therefore `enable`s (which only ADDS `.wants` links) and
  prunes the stale link itself, enable first so a failure leaves the unit enabled under the old
  target rather than off. This repo manufactures that drift, because
  `git checkout` here is a deploy and install is not in that path — so reconciliation at install
  time is necessary but not sufficient, and the load-bearing half is the check, which runs
  whenever anyone asks about the machine. The reconciler is gated twice: it no-ops without a user
  manager (servers, containers, CI), and it acts only on a unit already enabled, so it reconciles
  a decision and never makes one. It also
  says plainly that a RUNNING server keeps the old unit until a restart, which ends every agent
  session, rather than printing a success nobody can act on. `--check` reports, `--plan` lists
  what `--apply` would touch (which is how the gate became testable without systemd).
- **`verify-tools.sh` now asserts the server environment is COMPLETE, not just uncontaminated.**
  It only ever asked whether anything forbidden was present, so a server started at boot — before
  any graphical session existed to import an environment from — carried no forbidden variable and
  printed "environment is clean" while every pane had lost `gh --web`, `xdg-open` and the ssh
  agent. It now compares against the user manager's own environment (so a headless box correctly
  reports nothing), FAILs on a variable the session offers and the server lacks, and WARNs when
  `DISPLAY`/`WAYLAND_DISPLAY` name a previous login. `SSH_AUTH_SOCK` is excluded from the value
  comparison because the launcher substitutes a stable symlink for it by design.
- **[scripts/test-systemd-reconcile.sh](scripts/test-systemd-reconcile.sh)** — 130-check state
  table for the reconciler, in CI as `systemd-reconcile-test`, needing no systemd user manager
  because the read-only comparison is filesystem state and the mutating half runs against a
  recording `systemctl` **stub** at the front of `PATH` (a runner has no manager, and a suite that
  skips in CI is one that never runs; but "hermetic" has to mean answered-by-a-fake, not
  tool-happens-to-be-absent — this box has a real systemctl wired to the user manager holding the
  herdr server). Each fix is pinned by mutation, which is how four hollow assertions
  were caught before this landed: a note-prefix check that passed when two different notes
  collapsed into one, a "plain file ignored" row that was really testing containment, a dead
  comment-skip rule in the awk that could not fire because the pattern is anchored, and — worst —
  the reconcile gate, which was unpinnable while it sat inside a manager-gated loop. A later,
  costlier lesson from the same change is pinned too: the suite now asserts the script never
  reaches for `reenable`/`disable`, because the first version did and it cost a machine its unit.
- **One doctor-reporting implementation** (`_doctor_ok`/`_doctor_bad`/`_doctor_warn`/
  `_doctor_note`/`_doctor_summary` in `zsh/functions/system.sh`). `backup-doctor` had a
  byte-for-byte duplicate of the ✓/✗/⚠ emitters and its own hand-rolled summary; both now
  delegate, so a change to how results are emitted is made once. Their counters are also
  no longer globals — zsh scopes locals dynamically, so each doctor declares them and a
  run leaves nothing behind in the shell (four `_D*` variables used to persist in every
  shell, and a nested call clobbered the outer count). The summary's wording and exit
  status had no coverage in either suite before this — `backup-doctor`'s own table asserts
  printed findings, never the verdict — so the state table now pins all three paths, the
  dynamic-scoping mechanism, the `_backup_doctor_*` delegation, and the local-counter
  convention across every doctor entry point. `backup-doctor`'s three remaining
  hand-rolled `• …` note lines now go through `_doctor_note` too, so the neutral marker
  is not a fourth glyph in the one function the consolidation was about.
- **CI runs `zsh -n` over `zsh/functions/*.sh`** (`.github/workflows/ci.yml`). It is the
  largest zsh in the repo and no static check read it: the ShellCheck job selects files by
  a `^#!` shebang and these have none (they are sourced, not run), and pre-commit excludes
  the directory because the syntax is zsh, not bash. A syntax error there was caught only
  when some test happened to source the file.
- **`~/.config/mise/config.toml` is checked like any other managed link.** `install`
  creates it itself rather than via dotbot, so it appeared in no `link:` block and in
  nothing `dotfiles-doctor` looked at — while CLAUDE.md already records what its drifting
  cost once: ~11 tools missing from `PATH` and `git diff` dead with "unable to execute
  pager 'delta'". Emitted under both halves of `install`'s own gate, so a machine without
  mise is not permanently red for a link that correctly does not exist.

### Fixed
- **External-HDD auto-mount: the review follow-up to #87.** An independent xhigh review of
  the merged change found fifteen defects, all confirmed. The dangerous one: the `/etc/fstab`
  mount point was a blind `dirname` of the hand-edited `BACKUP_EXTERNAL_REPO`, with no floor
  at all — a repo path one level too shallow resolves to `/media/<user>` and a typo resolves
  to `$HOME`, and every check downstream passed, so the external disk would have been mounted
  over the user's home at every boot. `nofail` is no help there; the mount *succeeds*.
  `external_mount_point_sane` now refuses non-absolute, unnormalised (`/./` included) and
  symlinked paths, a deny-list of system directories (`$HOME`, `/media/$USER`,
  `/run/media/$USER`, … — the user resolved with `id -un`, never the login-set `$USER`,
  which is empty under `sudo -u`/`env -i`), and any existing directory that is not already a
  mount point and is either non-empty or unlistable. It gates the `/etc/fstab` write, the
  udev rule, `restic init` **and** the `ConditionPathExists`/`After=` wiring — the repo
  init is the step that would otherwise create the "external" repository on the internal
  disk for a `BACKUP_EXTERNAL_REPO` of `/restic`, since `/` is a mount point.
  - **`render … | sudo tee /etc/…` truncates on failure.** `backup-render.sh` became fallible
    when unresolved placeholders were made a hard error, but three call sites still piped it
    into `tee`, which empties the destination before the renderer's status is known — leaving
    a zero-byte `includes.txt` (restic backs up nothing) or `.service` (a unit that does
    nothing), both installed and reading as present. Replaced with `render_install`
    (render → temp → check → `install`), the pattern the udev step already used.
  - **`findmnt -S UUID=x` misses `/dev/disk/by-uuid/x` entries while the disk is undocked**,
    because it resolves the tag through `/dev/disk/by-uuid`. That is the form Ubuntu's
    installer writes (and what `/boot` uses here), so a correct `/etc/fstab` read as empty in
    exactly the state the feature exists for — producing a duplicate entry, a refused udev
    rule, and a false "will not mount after a reboot" warning. Both the installer and
    `backup-doctor` now query the literal device path as a second step.
  - **`findmnt`'s summary is translated.** Both `N parse errors, …` and `Success, no errors or
    warnings detected` are gettext-marked in util-linux; under a translated locale the parse
    returned the 999 "unusable" sentinel for every clean table and the step refused to install
    anything, permanently. Now read under `LC_ALL=C`.
  - **A failed mount no longer leaves a root-owned mount point behind** — udisks owns
    `/run/media/<user>` and creates it user-owned, and the leftover is precisely the
    directory that makes `test -e "$repo/config"` report a drive that is not there.
  - **Stale udev rules are removed and reported.** Every path on which the step declines to
    install now removes a rule an earlier run left, and `backup-doctor` checks for one even
    when nothing is configured — the check used to be gated on "is anything configured",
    which is how a rule naming a since-reassigned UUID stayed invisible.
  - `fstab_escape` covers the full fstab(5) set (`\011`, `\012`, `\134`, not just `\040`);
    `backup-status` reports "not configured" instead of asserting "not attached" for a disk
    it cannot know about; `backup-doctor` no longer warns twice about a single
    non-configuration; `_backup_external_attached` no longer treats *any* volume whose label
    matches the mount point's basename as the backup drive (a name coincidence was enough to
    raise a hard, non-zero-exit failure); the dead `_backup_external_mnt` helper and the
    unused `out_of` test helper are gone; and the udev template's own documentation header no
    longer names the placeholder tokens inline, which had the renderer replacing the
    explanation with the values in the only copy an administrator ever opens.
- **`scripts/test-backup-external.sh` now runs in CI** (`backup-external-test`) and checks its
  own harness first. Sourcing `setup-backup.sh` also runs that script's `set -euo pipefail`,
  so the suite re-declares `set +e` — without it the first expected-to-fail assignment killed
  the run mid-table with no failure count printed. It also aborts unless every function under
  test is defined and every required tool present: most of these assertions are "nothing was
  installed", which is exactly what a suite that loaded nothing produces. 27 checks → 68.

- **Backups: the external HDD stopped mounting, and every layer said it was fine.**
  `BACKUP_EXTERNAL_UUID` had been declared in `backup.local.template` since the backup
  system was written and nothing ever read it. Without an `/etc/fstab` entry the drive
  stays unmounted, `restic-backup-external.service` fails its `ConditionPathExists`, and
  systemd **skips** it — which is not a failure: no error, nothing in `--state=failed`, no
  notification, and no healthchecks ping, because a skipped unit pings nothing. On a laptop
  it compounds, since the drive leaves and returns with every dock cycle (twelve times in
  seven days on the machine this came from) and fstab alone only covers boot. `backup-doctor`
  reported all of it as a neutral note claiming `B2 covers offsite`, a reassurance it never
  checked — while B2 was simultaneously failing on a storage cap.

  `backup-setup` now installs three things from that key, covering three different windows:
  an `/etc/fstab` entry for **boot** (`nofail` + `x-systemd.device-timeout=10s`, so an absent
  disk can never break or stall it, and the filesystem type is read off the disk rather than
  assumed), [`udev/99-backup-external.rules`](udev/99-backup-external.rules) for **dock
  cycles**, and a `service.d` drop-in ordering the run `After=` the mount unit so the timer's
  `Persistent=true` catch-up cannot lose a race against USB enumeration at boot. The ordering
  is `After=` only — `Requires=`/`RequiresMountsFor=` would turn an undocked disk into a
  *failed* unit every six hours, which is the false alarm the `ConditionPathExists` design
  exists to avoid.

  `backup-status` and `backup-doctor` now distinguish **attached-but-unmounted** (a hard
  failure: it is the one external fault that looks exactly like "nothing was due") from
  genuinely absent, without depending on `BACKUP_EXTERNAL_UUID` being set — the population
  that has this bug is precisely the one that never set it. Both now test whether the mount
  point *is a mount point*, rather than whether a path under it exists: a leftover directory
  on the internal disk satisfied the old check, so "docked ✓" could be reported while writes
  landed on the root filesystem. `backup-doctor` also checks `BACKUP_HC_URL_EXTERNAL` (the
  external target's only possible dead-man's switch), that the unit's `ConditionPathExists`
  and the configured repo agree, and compares the live udev rule against the rendered repo
  template — its load-bearing half is the `systemd-escape`'d mount unit name, which goes
  stale on a repo-path change and leaves a rule that still contains the UUID, still passes
  `udevadm verify`, and never fires.

  [`scripts/test-backup-external.sh`](scripts/test-backup-external.sh) pins the install and
  doctor decisions against a fake fstab, with no root and no real disk. Two traps it exists
  to hold down: `findmnt --verify` reports "unreachable on boot" as an **error** for a
  `nofail` entry whenever the disk is undocked or its mount point directory is absent, so
  gating on its exit code rejects every correct entry in exactly the two states this fix
  targets; and a hardcoded `ext4` passes `findmnt --verify` (a type mismatch is only a
  warning) and then fails to mount, which `nofail` converts straight back into a silent
  non-mount.
- **herdr: the 2026-08-30 independent-evaluation batch** (`~/herdr-eval-findings.md`, F1–F11).
  The live herdr server had been restarted from inside a herdmates team-lead pane, so every pane
  inherited a fake `TMUX`, the teammux shim as `tmux`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`
  and herdmates' plugin dirs: every Claude session became a team of one, `tmn` / `tmux
  kill-server` hit the shim, `$status` appeared on nearly every sidebar row, and the runbooks'
  own pre-flight (`command -v tmux` → the shim) passed for everyone. Nothing detected it.
  - The server now runs from a declared, clean environment: `systemd/herdr-server.service` +
    `scripts/herdr-server-launch.sh` (`--print-env`; refuses to start from inside a pane or a
    Claude session; PATH from `~/.local/bin` + `mise bin-paths`, never a plugin shim;
    `LINEAR_API_KEY` from `~/.zshrc.local`; the session-bus variables toasts need). The unit is
    wanted by `graphical-session.target`, not `default.target`: `Linger=yes` here means the user
    manager comes up at boot, so a `default.target` unit would start before GNOME imports
    `DISPLAY`/`WAYLAND_DISPLAY`/`XAUTHORITY` and get none of them. `WantedBy` propagates start
    only and the unit has no `PartOf`, so it still survives logout with every session alive.
    `SSH_AUTH_SOCK` resolves to the stable `~/.ssh/ssh_auth_sock` symlink rather than the live
    snap path, because the Bitwarden agent that owns it autostarts *after* that target.
    `scripts/verify-tools.sh` gained "herdr server environment hygiene" (the running server's env
    carries none of the pane/team/plugin variables) and "Plugin dependencies under the herdr
    SERVER PATH" (each dependency resolved one at a time under the *server's* PATH).
  - Cleanup is executable instead of prose: `hspawn` gained `-p/-m/-e/--mode/-b/-n` and a
    registry (`~/.local/state/hspawn/`), plus `hdespawn <slug>` and `hreap [--close] [--mine]
    [--older MIN]` — every Claude process herdr hosts, detected or not, with idle age, memory and
    creator. `herdr agent list` had been the documented "what is alive", and it misses herdmates
    teammates and trust-dialog panes (14 agents shown while 33 claude processes ran, 15 of them
    finished teammates holding 4.5 GB).
  - Sidebar: an idle band `$idle_ok|$idle_warn|$idle_crit` (5/10 min, matching herdmates'
    quiet/stalled tiers) published by `session-statusline.sh` — the sidebar had no time
    dimension; the tab bar shows `agents <detected>/<claude procs>`; `remove_worktree` and
    `previous_workspace`/`next_workspace` bound; the `$task $status` comment corrected (`$status`
    is not team-only in practice, and `stale` = no transcript write for 10 min);
    `0xGosu/herdr-auto-pilot` dropped from `plugins.list`.
  - Guide + CLAUDE.md corrected: the from-zero sequence no longer strands a new hire at step 4
    (rustup, jq, `herdr plugin install natori-hrj/herdr-lazy` *before* `herdr-lazy check`,
    `LINEAR_API_KEY` before the server first starts, the unit, then `verify-tools.sh`);
    `clauth start` lacks `teammateMode: tmux`, not "team capability"; five sidebar rows, not
    six; the hspawn branch is `${HSPAWN_BRANCH_PREFIX:-$USER}/<slug>`, not `zvi/<slug>`; the
    keymap table's "swap panes / copy mode" row (no such actions exist) replaced with the real
    prefix actions; macOS labels on rotation, `/proc` and `notify-send`; `herdr agent explain`
    and named test sessions in troubleshooting. `config check` turned out stricter than §0 had
    said — probing showed it catches bogus keys, bad inline fields, non-hex colours and chord
    collisions among listed actions — but it still misses collisions with unlisted stock
    defaults, terminal-swallowed chords, missing popup binaries and unpublished tokens; §0 and
    the CLAUDE.md intro now say exactly that.
  - Upstream: teammates go undetected because Claude Code execs them via its versioned binary
    (process name `2.1.251`, not `claude`) while `herdr agent explain --file` accepts the same
    screen. Issue drafts for herdr (same class as herdrdev/herdr#803) and herdmates
    (`HERDR_AGENT=claude` on the respawned command, or `pane report-agent` from its hooks) are
    under `~/herdr-eval-upstream/`.
- **herdr: `hspawn` never worked.** Both code paths failed on every invocation. It creates a
  fresh worktree each run, so Claude's trust-folder dialog is guaranteed, and neither path
  answered it: the profile path called `herdr agent wait` before herdr had detected any agent
  (`agent wait` resolves its target up front and cannot wait *for* detection, so it died with
  `agent_not_found`), and the no-profile path died with `agent_not_ready`. Now polls for
  detection first, then answers the dialog on the agent surface — sending the keys at the pane
  level as the dialog renders does not work, because Claude's TUI is not yet accepting input
  and the keys vanish without error. Both paths verified end to end.
- **herdr: `f12 v` and `f12 -` had been silently deleted.** `split_vertical` /
  `split_horizontal` were arrays that omitted the stock prefix defaults, and setting a key
  field replaces it wholesale — leaving the two splits as the only actions with no prefix
  escape hatch.
- **herdr: `ctrl+shift+o` (split down) was dead**, because *Alacritty* has a compiled-in
  default binding that consumes the key press; the keyprobe signature is a release event with
  no matching press. Fixed in `~/.config/alacritty/alacritty.toml` (not symlinked from this
  repo) with an explicit `{ key = "O", mods = "Control|Shift", action = "ReceiveChar" }`.
  A sweep of the other 15 bound chords found `o` the only casualty — "one letter works, so the
  class works" is an unsound inference, and `CLAUDE.md` has been corrected accordingly.
- **DO-452**: the verification canary (`backup-verify.sh`) now runs its read-only `restic ls`
  / `restore` with `--no-lock`, so it no longer takes a repo lock that blocked the structural
  `restic check` in `backup-drill` (the check was being skipped rather than run). Added a
  `backup-unlock [b2|external] [--force]` command to clear stale restic locks after an
  interrupted run.
- **DO-451**: `backup-drill` no longer reports a false "DRILL FAILED" when a backup is running
  concurrently. `restic check` needs an exclusive lock, which collides with the every-2h
  backup; the drill now passes `--retry-lock 2m` and treats a still-held lock as "repo busy /
  skipped" rather than an integrity failure (the content + restore canary already proves
  restorability).
- **DO-450**: `backup-doctor` fixes found in live verification — its disk-space check used
  `df` (aliased to `duf`) so it silently printed nothing; now uses `command df -P` to bypass
  the alias. Also stops false-warning when `emergency-kit.age` isn't in `$HOME` (it's meant to
  live offline on the USB / in the repo) — now a neutral note instead of a warning.
- **DO-155**: Fixed CI ShellCheck error suppression - Shell script errors now fail CI builds instead of being silently ignored
- **DO-160**: Fixed mise activation error suppression in install script
  - Replaced `|| true` with explicit error checking
  - Shows warning message when activation fails
  - Provides remediation instructions
  - Users now informed when mise tools unavailable
