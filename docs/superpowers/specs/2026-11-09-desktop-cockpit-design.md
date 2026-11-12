# Desktop cockpit on Resource Pulse v2: design

**Status:** approved by Zvi 2026-11-09 (brainstorm with mockups, builder check and his answers recorded below). Data side built 2026-11-10 (#375) from [2026-11-09-desktop-cockpit-data-side.md](../plans/2026-11-09-desktop-cockpit-data-side.md); drawing side built 2026-11-12 from [2026-11-10-desktop-cockpit-drawing-side.md](../plans/2026-11-10-desktop-cockpit-drawing-side.md). **Builds on**
[2026-11-08-resource-pulse-service-design.md](2026-11-08-resource-pulse-service-design.md) (v2) and
[2026-11-07-resource-pulse-design.md](2026-11-07-resource-pulse-design.md) (v1). Where this document
reopens a v1 or v2 decision it says so; everything it does not mention stands.

## Why

Resource Pulse v2 answers "why is it slow?" with one card and two mini graphs. Zvi wants the desktop to become
a cockpit: the wallpaper gone, replaced by a dark solid, and the desktop filled with live panels on the same
pattern (a service samples, the extension only draws). Three moments drove the design, in his priority order:

1. **The lag moment.** The cause is known before he looks: parallel agent sessions (rabota and herdr-draft
   gates have made it rarer). The cockpit's job is confirmation and choice: how many sessions, in which states,
   which is heaviest, so the right one can be reaped. It must be reachable without clearing windows.
2. **The glance moment.** A sense of what is running, what the machine is connected to (network, VPN, mounted
   drives) and whether those are up right now.
3. **The Sol moment.** A summary of active work and recently completed items from Sol (nanoclaw).

Then, incrementally: Claude seat usage, backups, timer health, PRs and CI. "The order you listed them is also
correct."

## Decided by the owner (2026-11-09)

1. **Three moments, in the order above;** the four extra surfaces (seats, backups, timers, PRs/CI) are wanted
   too, "incrementally", after them.
2. **Connections** means the network side (VPN, the dev link, wired vs wifi, docked) plus mounted drives
   ("would also add mapped drives and such").
3. **The lag moment is reached from the top-bar dropdown**, not by clearing the desktop. Confirmed.
4. **Where it is seen:** docked, two screens. Work: left Slack or browser, right terminal with herdr. Personal:
   left browser, right WhatsApp/Telegram and lately Sol. "The desktop is not generally shown, but Super+D is
   easy enough for a quick toggle." A third screen above the pair is a hypothetical future upgrade: "We should
   be focusing on the Super+D version."
5. **Layout C: one cockpit screen.** Everything on the 27", the primary left alone. His worry that it "should
   go on the primary" was resolved by two facts: GNOME draws the top bar, and so the dropdown, on the primary
   only, and the 27" has no top bar and no dock.
6. **Background: near-black with a prussian tint** (mockup `#121a1a`), the same on both desktops. He clicked it
   and accepted it as my recommendation. The lock screen gets the same solid colour and no panels (my default,
   accepted "as recommended").
7. **Agents card: one row per session,** then "less verbose, better leverage icons and colors": a symbolic icon
   in colour for the state, a faint memory bar behind each row, short units.
8. **Tooltips replace the legend.**
9. **Interactive.** ding goes off on this machine so the desktop cockpit takes hover and clicks.
10. **A session row click takes him to the session** ("focus", then, after the builder check pointed out
    that a pane focused inside a window Super+D just hid shows nothing: "Take me there"): herdr focuses the
    pane and the shell activates the terminal window that hosts herdr, which ends show-desktop. Reaping
    from the card is not in stage one.
10a. **SESSIONS counts herdr panes only** in stage one; rabota's headless lanes stay in APPS under their unit
    name ("herdr panes only").
11. **Connections card and apps card as proposed** ("looks good").
12. **No notifications** ("none"). "Waiting on you" and "needs you" are drawn states only.
13. **Grid:** the uniform 4 × 3 grid, then **grouped** into Machine, Agents and Work with captions and spacing
    only (A), no trays. He asked for grouping "based on reasonable categories" and did not object to the split.
14. **Later cards get real designs:** "make sure that we will be populating the Sol, Work, and Backups cards
    with nicer designs and more complete information." Each later stage gets its own design pass with a mockup.

Guesses he did not correct, so they stand as mine: the glance cards only pay off if the cockpit is seen without
effort; the Sol panel is its own stage; the primary desktop goes bare.

## Goals, non-goals, anti-goals

- **Goals:**
  - the lag answer at session granularity, reachable from the top bar;
  - a glanceable cockpit on the 27" behind Super+D, on a grid, grouped, in the quiet-card look;
  - every new source outside the shell, on the service-plus-drawing pattern, portable to another desktop;
  - layout changes and most content changes deploy with no logout;
  - measured cost and memory budgets, per service;
  - a path for the later stages that does not require redesigning stage one.
- **Non-goals:**
  - the third screen (the design only keeps a named-monitor pin possible);
  - reaping, or any destructive action, from the cockpit;
  - notifications or alerts of any kind;
  - server-side Sol data (initiatives, scheduled tasks, chat), which needs the tailnet API;
  - per-session cgroups (still a separate follow-up; this design names what it would improve).
- **Anti-goals:**
  - a panel that can render a credential, a path with a token in it, or model or operator prose;
  - a stale number drawn as live, on any card, across either service boundary;
  - the shell waiting on either service, or doing any IO itself;
  - a cockpit deploy that resets the sampler's histories;
  - anything that runs, or costs, for a colleague who has not opted in.

## Constraints

- The four deal-breakers, all binding: desktop instability; wrong or laggy numbers; cost (CPU, memory,
  battery); upkeep.
- Meaning is never carried by colour alone (v1). Icons are GNOME's symbolic set drawn with `St.Icon`, never
  glyphs: Ubuntu Sans has no ▮▯ (v1 found that).
- One in-repo, opt-in extension; no third-party extensions or themes. Stock extensions stay as shipped **unless
  the owner's local layer says otherwise** (this document reopens that line for ding, below).
- The repo is public and adopted through `dev-setup`: nothing here switches itself on, and personal data (the
  config file, the background colour, ding off) lives in `~/.gnome-settings.local` and a personal config file,
  never in the repo.
- `CLAUDE.md`'s "Keeping secrets out of transcripts" applies to anything drawn on screen.
- No `[Install]` on any unit of ours; never `enable` or `reenable` a dotbot-installed unit.
- Logouts are cheap on this box but still his call: drawing changes wait for a login, so the drawing layer
  must be generic enough that stages land data-side.

## Facts this design rests on (read on this machine, 2026-11-09)

- **Monitors** (`~/.config/monitors.xml`, docked): left `DP-4`/`DP-6` Samsung S24C650 1920×1080 scale 1,
  **primary**; right `DP-5`/`DP-7` Dell U2723QE 3840×2160 scale 2 (logical 1920×1080) at x=1920. Other saved
  layouts: the laptop panel eDP-1 1920×1200 at 1.25 with one HDMI 24"; a single HDMI 24". Connector ids
  change between dock sessions; the vendor and product strings do not.
- **ding** (`ding@rastersoft.com`) is ACTIVE with every icon hidden; `disabled-extensions` is `[]`. ding has no
  per-monitor setting; v2 states its DESKTOP window spans the screen and takes every pointer event. GNOME's
  `Eval` is off here, so that claim is to be re-verified in the nested shell, not assumed.
- **The sampler** publishes `apps: {topCpu, topMemory}` only (one entry each, `lib/protocol.js`). The ranking it
  computes each scan is longer; publishing more of it is an additive field.
- **herdr** serves a JSON API on `~/.config/herdr/herdr.sock` with a published schema (`herdr api schema
  --json`, `protocol` 22, 162 request kinds). `herdr api snapshot` returns `agents[]` with `agent`,
  `agent_status`, `cwd`, `agent_session.value` (session id), and workspaces with `label` and
  `worktree.checkout_path`. Request kinds `pane.focus` and `workspace.focus` take ids. The hspawn registry is
  one JSON per pane under `~/.local/state/hspawn/` with `branch`, `created_at`, `creator_session`, `name`,
  `pane_id`, `path`, `profile`, `repo`, `slug`, `workspace_id`. `hreap`'s per-row recipe: idle age = mtime of
  the session transcript (`~/.claude/projects/<cwd-mangled>/<session>.jsonl`, else under
  `~/.clauth/profiles/*/runtime-*/projects/`), else process age marked `*`; memory = VmRSS+VmSwap of the
  claude process only; pids from `herdr pane process-info`.
- **Sol / nanoclaw** (read-only recon, no data file opened): the server and PWA are remote on the tailnet; the
  laptop runs `nanoclaw-orchestrate.service` (daemon) and `nanoclaw-fleet-agent.timer` (10 s push). The daemon
  rewrites `~/.nanoclaw/orchestrate/fleet-snapshot.json` atomically about every 60 s (`version: 1`;
  `lanes`, `campaigns`, `escalations`, `events`, `report`, `tick`, `unavailable`) and `heartbeat.json`
  (`tickedAt`, `lastError`). "Active" = a lane in queued, running, parked, held, paused-quota or paused-auth;
  "completed" = `report.merged[]` plus lanes retired in the window. Lane titles live in
  `~/.nanoclaw/orchestrate/base/docs/improvements/{active,done}/IMP-*.md` frontmatter. The snapshot's free-text
  fields (`lanes[].last_text`, `last_tool`, `waiting_on`, `retire_reason`, `escalations[].question/options/
  evidence/answer/reasoning`, `events[].payload`, `report.parked_items[].question`, `campaigns[].goal/why`,
  `tick.last_error`, `unavailable[]`) are unredacted on disk. No plugin or extension point exists in nanoclaw;
  server-side data needs the tailnet `/api/*.json` endpoints and tailscale identity.
- **VPN up** is, by `vpn-doctor`'s own test, "the tunnel interface has a gateway route". `/proc/net/route`
  carries that without a subprocess.
- **SSH masters** use `ControlPath ~/.ssh/sockets/%C` (a hash), so a socket cannot be matched to a host by
  name alone.
- **Resource Pulse v2 costs** (merged eb711be): service 0.07% of one core unwatched, 0.16% watched, about
  39 MiB; in-shell under 0.1%.

## Design

### Where it is seen

- **The cockpit monitor is a named choice**, never "primary" or "not primary": the personal config names it by
  vendor and product (`DEL` / `DELL U2723QE`), with a fallback rule of "the only monitor" when one is connected,
  and "the largest non-primary" when the named one is absent and more than one is present. It repositions on
  `monitors-changed` and work-area changes, as the card does today.
- **The primary's desktop goes bare**: today's card moves to the cockpit screen as the system card. The top-bar
  indicator and the dropdown stay on the primary, which is where the lag moment lives.
- **Super+D is the reveal.** The cockpit reuses v2's covered logic per card: a card fully under a normal or
  dialog window on its monitor freezes and dims; partly covered counts as visible; reveal repaints at once.
  When docked the 27" holds the terminal with herdr, or the chat apps and Sol, so **the cockpit is covered
  most of the day**: its standing cost is the unwatched one, and the watched cadences apply only while a card
  is revealed or the dropdown is open (the dropdown holds the cockpit watch, as it holds v2's detail watch).
- **Undocked** (one screen): the cockpit sits on that screen, behind Super+D, covered most of the day; the
  freeze rule makes that cheap.
- **The overview** hides it, as the card is hidden today. **The lock screen** shows the solid colour only.

### Background

- `org.gnome.desktop.background`: `picture-options 'none'`, `primary-color '#121a1a'` (near-black pulled toward
  Yaru-prussiangreen's hue; the exact value is tuned on the real screen). The same for the lock screen,
  `org.gnome.desktop.screensaver`. Both in `~/.gnome-settings.local`; the template gains them commented.
- Cards keep v1's quiet look: white at about 6% over the background, a 1 px border at 13%, rounded corners,
  Ubuntu Sans with tabular numerals, muted labels and bright values.

### Layout

- **Grid:** 4 columns × 3 rows on the cockpit monitor's logical work area, centred. At 1920×1080 logical:
  cards 420 wide, rows 300 tall, inner gutter 24 (between cards of one group), group gap 48, caption row 28,
  margins about 52. A card fills its cell exactly; content is top-aligned inside it. The numbers scale with
  the work area; the builder derives them from the cell count, not the pixels.
- **Groups**, left to right, each under a small uppercase caption in the muted label colour:
  - **MACHINE** (2 × 2): system, apps / connections, health;
  - **AGENTS** (1 × 2): sessions, seats;
  - **WORK** (1 × 2): Sol, PRs & rabota.
  Row three stays free; a group grows down into it when a later stage needs a cell.
- **Stage one draws four solid cards:** system, apps, connections, sessions. Cells of later stages are empty
  (plain background), never placeholders.
- **Layout is data.** The cockpit service sends the layout with the data (groups, their captions, the ordered
  card ids, the monitor rule), read from the personal config file. A layout change is a data-side deploy.

### The cards, stage one

Each card has: a title, a fixed set of rows, a tooltip per row or icon, a click action or none, and a no-data
state. Icons are symbolic and coloured; the shape differs per state so colour is never the only carrier.
Rows carry a faint bar proportional to the row's value where a magnitude is shown.

- **SYSTEM** (today's card, verbatim content: CPU with P/E, sparkline, memory bar, swap, waiting-on meters,
  heaviest line). Click: open Resources (the dropdown's existing fallback order). Source: the sampler,
  unchanged.
- **APPS.** The heaviest line grown into rows: name, CPU share, memory, faint bars; six rows fit a cell.
  "kernel" and "short jobs" appear on the CPU side exactly as v2 defines them; memory names real apps only.
  Source: the sampler publishes an additive field, the top 10 by CPU and the top 10 by memory, from the
  ranking it already computes; this is the only sampler change in stage one, and its deploy restarts the
  sampler once. No click.
- **CONNECTIONS.** Rows, each an icon plus a few words, details in the tooltip:
  - **Uplink:** wired or wifi, and whether the internet is reachable, from NetworkManager over D-Bus
    (`PrimaryConnection`'s type, and the `Connectivity` verdict: full, limited, portal, none); docked reads
    "wired · wifi off". Updated on NetworkManager's own signals, no polling. The SSID is never shown.
  - **VPN:** up or down by vpn-doctor's test, a gateway route through a `tun*` interface, read from
    `/proc/net/route` every 10 s (it is one small file). No probe, no packet.
  - **SSH:** the count of live SSH masters (sockets in `~/.ssh/sockets/`, stat only), as "N live ssh masters".
    Naming the dev link is **stage four** (health), where `dev-link-doctor`'s verdict belongs; the `%C` hash
    makes a per-host answer from the socket name alone a guess.
  - **Mounts:** network filesystems and removable disks from `Gio.UnixMountMonitor` (signals on change, no
    polling), one row each with free space from `g_file_query_filesystem_info`; the backup disk by its label.
    The panel never reads `~/.backup.local`, which holds keys.
  No click.
- **SESSIONS** (the agents card). Header: `SESSIONS 6`, state counts as icon + number, the bucket total
  (today's "herdr agents" memory from the sampler). Rows, sorted by memory, largest first, six fit, the rest
  fold into "+N more":
  - **icon** = state, mapped one-to-one from herdr's `AgentStatus` enum (`idle`, `working`, `blocked`,
    `done`, `unknown`, read from `herdr api schema --json`): working (teal play), waiting on you (amber mark;
    `blocked`), idle (grey pause), done (green check; the agent finished its turn and the pane is alive),
    unknown (grey question; an undetected teammate or a trust-dialog pane). Idle and done both dim after
    30 min, which is also hreap's reapable pair;
  - **name** = the hspawn registry's `slug`, else the registry's `branch`, else the workspace `label`, else the
    cwd's basename; ellipsized by width, never cut in the numbers;
  - **idle age** = transcript age as hreap measures it, `*` when only the process age is known;
  - **memory** = VmRSS+VmSwap of the pane's claude process, whose pid comes from the socket request
    `pane.process_info` (it exists; no subprocess), read from `/proc/<pid>/status` (an undercount, said in
    the tooltip: "process only; MCP servers and tool shells not counted"), with the faint bar.
  Long-idle rows (over 30 min) are dimmed; a waiting row's name is tinted. **Click a row: take me there.**
  The service asks herdr to focus the pane (`workspace.focus`, then `pane.focus`, by ids from the snapshot)
  and answers with what the shell needs to find the window that hosts herdr's client; the shell activates
  that window, which ends show-desktop, so the cockpit gives way to the pane that was clicked. From the
  dropdown the same click does the same and closes the dropdown. If the window cannot be found the pane is
  still focused and nothing else happens. **Hover: tooltip** with the state word, the pane id, the
  account and context usage from the snapshot's `tokens` (the sidebar publisher's `acct` and `ctx_*`
  tokens, which are already on screen in herdr), and the memory caveat. Source: the cockpit service, over
  herdr's socket, every 10 s while watched and every 60 s otherwise, plus at once on a herdr event when the
  schema offers one the builder can subscribe to cheaply. No-data: "herdr not running" when the socket is
  absent; "no data since HH:MM" when a read fails.
  - **Scope:** herdr panes only in stage one (the socket and the hspawn registry). rabota's headless lanes run
    under systemd outside herdr and show in APPS under their unit name; a lanes row is a later stage.
  - **After per-session cgroups** (a separate follow-up that changes `claude()`/`hspawn`), memory and CPU per
    row come from the sampler's leaf ranking exactly, and this card's memory column switches source with no
    layout change.

### Interaction

- **ding is turned off on this machine** through `~/.gnome-settings.local` (a new `gdisable_extension` helper
  in `scripts/apply-gnome-settings.sh`, the counterpart of `genable_extension`, which appends to
  `disabled-extensions`, the key that wins in GNOME 50). This reopens v1's "display-only" card and the "stock
  extensions as shipped" rule, which becomes "as shipped unless the owner's local layer says otherwise". ding
  does nothing visible here (every icon hidden); losing it costs the desktop right-click menu, which nothing
  uses.
- **Cards are reactive actors** in the background group. With no DESKTOP window above them they receive
  enter, leave and button events. **Under a DESKTOP window (a colleague with ding on) they receive nothing and
  must behave exactly as v2's card does today:** display-only, frozen when covered, no error. Hover shows the
  tooltip after about 300 ms, like the indicator's hover label. A click runs one safe action or nothing;
  there is no action that destroys, closes or sends.
- **The shell never does IO.** A click sends a D-Bus method call to the cockpit service (`FocusSession(id)`),
  which talks to herdr's socket; the call is asynchronous with a 2 s timeout and the card shows nothing on
  failure beyond the journal line. **The one shell-side action is activating a window** (`Meta.Window`
  activation, which is what a dock click does): the service's reply identifies the herdr client's window
  (its pid, or whatever the snapshot and `pane.process_info` can give; the mapping is the builder's), the
  shell matches it against the window list and activates it, ending show-desktop. No match, no action.

### Architecture

- **Two services.** The sampler (`resource-pulse.service`, `ResourcePulse1`) stays as it is, apart from the
  additive apps field. A second unit, **`cockpit.service`**, serves every new source on the session bus as
  `io.github.quantivly.dotfiles.Cockpit1` at `/io/github/quantivly/dotfiles/Cockpit1`, from
  `gnome-shell/extensions/resource-pulse@dotfiles/service/cockpit.js` (inside the extension tree for the same
  import reason as v2). The decisive reason for a second process is deploy churn: the cockpit will change with
  every stage, each data-side deploy restarts its service, and that must never reset the sampler's five-minute
  histories. More than two processes would cost about 40 MiB each, and memory is the binding constraint.
- **Sources** are modules inside the cockpit service, each with its own cadence, error isolation and
  staleness: `sessions` (herdr socket + registry + transcript stat), `network` (NetworkManager D-Bus +
  `/proc/net/route` + `~/.ssh/sockets` stat), `mounts` (`Gio.UnixMountMonitor`), and later `sol`
  (`GFileMonitor` on the snapshot), `seats`, `health`, `work`. A source that throws marks only its own card
  "no data"; the tick goes on.
- **Interface `Cockpit1`:**
  - `GetState() → s`: JSON with `protocol` (1), `serviceStartedAtUsec`, `latestPublishedAtUsec`, `layout`
    (groups, captions, card ids, monitor rule), and one object per source with its own `sampledAtUsec`.
  - Signal `Changed(s)`: JSON naming the sources that changed and their new objects, emitted on change, never
    on a timer with nothing new.
  - `WatchCockpit()` / `UnwatchCockpit()`: held while the cockpit monitor is visible; counted per caller and
    dropped when the caller's connection closes (v2's rule).
  - `FocusSession(s id) → s`: JSON with `focused` (bool) and what identifies the herdr client's window
    (`windowPid`, and anything else the builder finds reliable); empty fields mean "focused in herdr, window
    unknown".
  - **Additive-only JSON**, unknown fields ignored, a missing field blanks only its row; a breaking change is
    `Cockpit2` beside `1` (v2's skew rule). Staleness: a source whose `sampledAtUsec` is older than three of
    its intervals is drawn "no data since HH:MM".
- **Layout as data, opt-in by file.** The cockpit service reads `~/.config/resource-pulse/cockpit.json`
  (personal, not in the repo; a template in `examples/`): the monitor rule, the groups and cards. The unit
  carries `ConditionPathExists=%h/.config/resource-pulse/cockpit.json`, so for anyone without the file
  systemd **skips** it (not failed; `gnome-status` must read `LoadState` and the condition, per CLAUDE.md's
  rule on judging a unit) and the extension draws nothing beyond v2.
- **Lifecycle:** the extension's `enable()` calls `StartUnit` for both units, idempotently, with v2's retry
  and confirmation rules; the cockpit's bus name appearing ends its retries; a deliberate stop is never
  undone. **A skipped unit ends the chain too:** after the cockpit's `StartUnit` is accepted, the client reads
  the unit's `ConditionResult` and `ActiveState` over systemd's D-Bus; `ConditionResult=false` means "not
  configured", so no retry, no warning, nothing drawn beyond v2, and the next `enable()` (unlock, blank,
  login) asks again, which is how a config file created mid-session is picked up. A colleague without the
  file therefore costs one accepted-and-skipped job per enable and nothing else. Unit settings mirror v2's: `PartOf=graphical-session.target`, `Restart=on-failure`, `RestartSec=5`,
  the start limit, `Slice=background.slice`, `Nice=10`, `CPUQuota=10%`, `MemoryHigh=64M`, `MemoryMax=96M`.
  `./install` links the unit and try-restarts it when its import closure or unit file changed after it
  started (the existing refresh script generalised to two units).
- **Config changes** (`cockpit.json`) take effect on the service's next read: the service watches the file
  with `GFileMonitor` and republishes the layout; no restart, no logout.
- **The extension** gains a `CockpitClient` beside `PulseClient`, a `CockpitLayer` actor per monitor rule, and
  card classes per card id. Cards it does not know (a newer service) are skipped; sources it knows but the
  service does not send show "no data". Drawing changes still wait for a login; the stylesheet rule
  (add classes, never rename) stands.
- **Before the layout is known, nothing is drawn.** The extension keeps the last layout it received in the
  extension object across enable and disable (as `_lastGoodClockLabel` survives today), so after an unlock
  or blank the grid is rebuilt from the cached layout at once and refreshed when `GetState` answers; no card
  ever appears on the primary and then jumps. Only when the cockpit unit reports skipped (no config) does
  v2's card appear top-right on the primary, as today. **If the cockpit service dies mid-session** the grid
  stays where it is: the system card keeps drawing from the sampler, every cockpit card shows "no data since
  HH:MM", and the extension never retries a service that ran and then failed (v2's rule); the next
  `enable()` starts it again.

### Secrets rule: the data path

A panel can only draw what the service hands it, and the service hands only **typed fields it chose**:

- **Allowlist by field.** Each source has a schema of enum, number, id and short-name fields; anything not in
  the schema is not published. No source publishes free text from another program (herdr's `last_text`, Sol's
  `escalations[].question`, a doctor's output, a journal line).
- **Stat, never open:** anything under `~/.aws`, `~/.ssh`, `~/.clauth/profiles/*/.credentials*`,
  `~/.claude/.credentials.json`, `~/.zshrc.local`, `~/.gitconfig.local`, `~/.backup.local` is never opened by
  either service; a file's mtime or existence may be used.
- **Names are checked:** a name field (a slug, a branch, a workspace label, a mount label) is rejected and
  replaced by "—" when it matches the repo's secret shapes (`scripts/redact-secrets.sh`'s rule sets, ported
  to one `lib/` module with rows) or exceeds 64 characters.
- **The static check** (`scripts/test-resource-pulse.sh`) keeps forbidding file IO and subprocesses in the
  shell, and gains rows: the cockpit service never reads the stat-only paths, and every published field name
  is in the schema.

### Cost budget

| What | Budget |
|---|---|
| gnome-shell, added by the whole extension | under 0.1% of one core at idle; no new repaints except on hover and on `Changed` |
| cockpit service, unwatched (the standing case: covered most of the day) | under 0.05% of one core |
| cockpit service, watched (revealed, or the dropdown open) | under 0.1% of one core |
| cockpit service RSS | at most 48 MiB, flat over 24 h |
| sampler | unchanged: 0.25% / 0.1% / 64 MiB (v2) |
| gnome-shell RSS | flat over 24 h (the existing tripwire) |
| on battery (UPower `OnBattery`) | every cockpit cadence triples |

Nothing polls that can be told: NetworkManager, `Gio.UnixMountMonitor`, `GFileMonitor` and UPower signal.
Over budget, the remedy is a longer interval or a dropped row, never a shorter history or a missing "no data".
`scripts/resource-pulse-cost.sh` gains a `--cockpit` mode.

### The dropdown

The top-bar dropdown holds the system card today. It gains the **sessions card** under it, live while open,
with the same rows, tooltips and row click (focus closes the dropdown). The dropdown is the lag moment's
surface: nothing else goes in it in stage one.

### Later stages (roadmap, each with its own design pass and mockup before it is built)

The data paths below were verified in this brainstorm; the content lists are what the recon showed is
available, so "complete information" is defined. Each stage amends this document with a dated section, a
mockup in the companion, and its own rows and budget line.

- **Stage 2, SOL (Work group).** Source: `~/.nanoclaw/orchestrate/fleet-snapshot.json` via `GFileMonitor`,
  staleness from `heartbeat.json`'s `tickedAt`. Rows: active lanes (IMP id joined to its title from the
  backlog frontmatter, state icon, phase, turn / turns total, cost), merged today (PR number, IMP id,
  verdict), retired lanes in the window, open escalations **as counts by priority** (never their text),
  spend today, last tick age. Click: open the PWA. Allowlist: enum, number and id fields only.
  Server-side work stays out until nanoclaw exposes it (nanoclaw work, its own tracker).
- **Stage 3, SEATS (Agents group).** Source: clauth's status (`~/.clauth/status.json`, the file `claude-doctor`
  already reads for `fetch_status`) and profile metadata, stat-only on credentials. Rows per profile: window
  usage % with a bar, reset time, sessions on it (from the registry), week usage, quarantine (`auth_broken`).
  Open question for its design pass: which file carries usage and how fresh it is.
- **Stage 4, HEALTH (Machine group).** Source: each doctor's **verdict**, never its output: `backup-doctor`,
  timer health (`verify-tools.sh`'s rule), `claude-doctor` (stored vs live, quarantines), `gnome-status`,
  `vpn-doctor`, `dev-link-doctor --offline`. Rows: name, verdict icon, age, and the **name** of the failing
  check. Mechanism to decide in its design pass: a timer that runs the doctors through the redactor and
  writes an allowlisted JSON verdict file the cockpit service reads (the doctors are shell functions, and
  neither service may run them).
- **Stage 5, PRS & RABOTA (Work group).** Source: `gh` through the interactive wrapper on a timer writing an
  allowlisted JSON file (PR number, title, CI verdict, review state, mine/theirs), and `rabota brief`'s
  ranked items and "needs you" count the same way. Never a token, never a PR body.
- **Named for later, not scheduled:** a reap action with a confirm step; per-session cgroups (own design);
  the third screen (a second monitor rule in the config).

### Repo wiring

- `install.conf.yaml`: one new link, `~/.config/systemd/user/cockpit.service`; inert without the config file.
- `scripts/apply-gnome-settings.sh`: `gdisable_extension`; the template gains commented lines for the
  background colours and for disabling ding.
- `examples/resource-pulse-cockpit.json.template` (the layout config); `~/.config/resource-pulse/cockpit.json`
  is created by hand or by a `cockpit-init` helper, never by `./install`.
- `gnome-status`: a cockpit line (unit state with the condition read correctly; protocol; age of the last
  publish; which sources are stale; "skipped: no config" when the file is absent).
- `scripts/resource-pulse-service-refresh.sh`: generalised to both units and their closures.
- Docs: the guide's Resource Pulse section gains a Cockpit subsection; `CHANGELOG.md`; this document linked
  from the v2 spec and `docs/README.md`.
- No Linear issue (personal desktop work; precedent #365, #367). Branch `zvi/desktop-cockpit-design` for the
  spec; the build gets its own branch per stage.

### Testing

- **Cockpit service:** parser and schema rows per source against fixtures (a herdr snapshot, a registry entry,
  `/proc/net/route` with and without a tunnel, a mount list, a NetworkManager property set); an allowlist row
  per source that fails when an unknown field is published; a staleness row per source; one D-Bus round trip
  on a private bus (`GetState`, `Changed`, a watch dropped on disconnect, `FocusSession` against a fake
  socket).
- **Extension:** pure decision functions in `lib/` with rows: the monitor rule (named present, absent, single
  screen), the grid geometry from a work area, covered per card, stale per source, tooltip text, which click
  maps to which action.
- **Nested shell (`scripts/resource-pulse-nested.sh`):** both services on the private bus; the cockpit layer
  on a second fake monitor if the harness can make one, else on the single one; **a reactive card receives
  enter/leave/click with no DESKTOP window, and receives nothing with a DESKTOP-type window present**;
  Super+D (show-desktop) works without ding; a row click activates a real window opened in the harness and
  ends show-desktop; the dropdown shows both cards; lock mode pushed and popped;
  no extension errors in the log.
- **Cost:** `--cockpit` readings over 10 idle minutes watched and unwatched; the live in-shell reading after
  the owner's login; the 24 h RSS checks scheduled with `rabota schedule add`.

### My calls (flagged for the owner to check)

- The grid geometry numbers (420 × 300, gutters 24/48, margins about 52).
- Group names MACHINE / AGENTS / WORK and the cell order inside each.
- The sessions card's row limit (6, then "+N more") and the 30-minute dim threshold.
- "SSH: N live masters" in stage one; the dev link named only in stage four.
- The apps card's row limit (6 of the published 10).
- `Cockpit1`'s method and signal names, and the `Changed`-on-change rule.
- `ConditionPathExists` on the config file as the opt-in, and the config path.
- The cockpit unit's caps (64M / 96M) and budgets.
- Tripled cadences on battery.
- The additive apps field in the sampler as stage one's only sampler change.
- Later stages' content lists are what is available, not promises of layout; each gets a design pass.
- From the builder check: a skipped cockpit unit (no config) ends the start chain with no retries and no
  warning, read from `ConditionResult`; the layout is cached in the extension object and nothing is drawn
  before it is known; a dead cockpit service leaves the grid in place with "no data" cards; the five states
  map one-to-one from herdr's enum, idle and done both dimming at 30 min; the pid comes from
  `pane.process_info` over the socket; the standing cost is the unwatched one.

### Left to the builder

- The herdr wire framing and which event, if any, to subscribe to (from `herdr api schema --json`).
- How to find the window that hosts herdr's client from the service's reply (pid match, WM class, title),
  and what to do when several herdr clients are attached; verified in the nested shell with a real window.
- The exact NetworkManager properties and signals; the `/proc/net/route` flag test for a gateway route.
- The tooltip actor and its timing; the icon names from the symbolic set.
- How the config file's JSON is validated and what a bad file does (the service must publish "config
  invalid" rather than stay silent).
- The `cockpit.json` schema beyond groups, cards and the monitor rule.
- Whether the harness can present two monitors.

### Follow-ups (not in this project)

- Per-session cgroups for agent sessions (own design).
- Reap from the card, with a confirm step.
- Server-side Sol data (nanoclaw work).
- The third screen.

## Verification (end to end, after a stage is built)

1. The unit rows and static checks are green and the row totals match; `pre-commit run --all-files`;
   `./scripts/check-claude-md.sh`.
2. The nested-shell checks above, from the worktree, with the live `enabled-extensions` proven unchanged.
3. After merge and ff-deploy, and one login: the background is solid on both screens and the lock screen;
   ding is off and `Super+D` reveals the cockpit on the 27"; every stage-one card shows live data that agrees
   with `hreap`, `nmcli`, `vpn-doctor`, `findmnt` and Resources within rounding; hover shows tooltips; a row
   click focuses the pane in herdr; covering a card freezes and dims it; 20 lock/unlock cycles, a dock and
   undock, overview in and out, then `gnome-extensions info` says ACTIVE and the journal holds no
   `resource-pulse:` errors.
4. Cost: the `--cockpit` readings and the live in-shell reading are within budget; the 24 h RSS checks are
   scheduled with `rabota schedule add`.
