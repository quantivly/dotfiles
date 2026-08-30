# Herdr Guide — the recommended agentic dev setup

Herdr is a terminal workspace manager built for coding agents: it organises terminals into
workspaces → tabs → panes, *recognises* the agent running inside each pane, and exposes the
whole session over a CLI. This repo carries a working configuration for it, and this guide
explains how to adopt it, why each piece is the way it is, and how it fails.

**Status:** herdr 0.8.2, stable channel. In daily use on one workstation
(Ubuntu / GNOME / Wayland + Alacritty). Everything marked *verified* below was tested at the
keyboard; anything not marked is inherited from documentation and should be treated as such.

---

## 0. Read this first: every layer here fails silently

This is the most important section in the guide, and it is not a figure of speech.

A walkthrough of this setup on 2026-08-30 found **five** separately configured features that
were completely dead. Every one of them passed every check the system offers:

| Feature | Symptom | Actual cause |
|---|---|---|
| `ctrl+shift+o` (split down) | nothing happens | Alacritty has a compiled-in binding that eats the key **press** |
| `f12 v` / `f12 -` | nothing happens | setting a key field *replaces* it; the stock defaults were dropped |
| `alt+g` (lazygit) | popup flickers and closes | binary not on the herdr **server's** PATH |
| `alt+y` (yazi) | popup flickers and closes | binary was never installed (its config was) |
| `hspawn` | aborted every run | never answered Claude's trust dialog |

Throughout, `herdr config check` returned `ok` and `herdr server reload-config` returned
`applied` with zero diagnostics.

**`config check: ok` means the file parses. It does not mean anything works.** Herdr validates
its configuration, not its effects. The terminal does not report a key it swallowed. A plugin
pane closes faster than its error can render. Budget time to verify that each binding *does the
thing* — one at a time — and never generalise from one working example to a class.

---

## 1. Who this is for

Herdr costs something real to adopt: a terminal-native workflow, a keymap to learn, a TOML
config to maintain, and a per-machine verification pass (§2). It pays that back when you are
running **several coding agents at once against real repositories**.

Use herdr if you need any of:

- **Git worktree isolation** — several agents on one repo without collisions.
- **Multiple accounts** with automatic rotation as quotas fill.
- **Config as code** — keymap, sidebar and plugin set reviewed and version-controlled.
- **Remote work** — `herdr --remote` onto a server, sessions surviving disconnects.

If none of those apply, you are paying the cost for none of the benefit. See §11.

---

## 2. Prerequisites, and how to verify them

Do these **in order**, before writing any keybinding. Steps 2.1 and 2.2 are where adopters lose
time.

### 2.1 A terminal that speaks the kitty keyboard protocol

Herdr's client unconditionally requests kitty keyboard enhancement (`CSI > 7 u`). If your
terminal ignores it, `ctrl+shift+<letter>`, `ctrl+1..9` and `ctrl+tab` become indistinguishable
from simpler chords and **half the keymap silently does nothing**.

```bash
scripts/herdr-keyprobe.sh   # run in a PLAIN terminal window — not inside herdr, not inside tmux
```

Press each chord you intend to bind. For every one you need a **key-press** event:

```
ctrl+shift+e  ->  ESC[101:69;6u      <- press   (codepoint:shifted;modifiers)
                  ESC[101:69;6:3u    <- release (":3" marks release)
```

**A release with no matching press means the key never reached herdr.** Something upstream —
usually the terminal itself — consumed the key-down.

> **Verified, and it will catch you out:** *one working letter does not validate the class.*
> On Alacritty 0.16.1, `ctrl+shift+e` works with no configuration at all, while
> `ctrl+shift+o` is swallowed by a compiled-in Alacritty binding that appears in no man page
> and in no shipped example config. Probe **every** chord you bind.

Fix for a swallowed chord, in `alacritty.toml`:

```toml
[[keyboard.bindings]]
key = "O"
mods = "Control|Shift"
action = "ReceiveChar"     # "treat as unbound, hand it to the terminal"
```

Prefer `ReceiveChar` over a hardcoded `chars = "<ESC>[111:79;6u"`: it emits whatever the active
encoding calls for — CSI-u under the kitty protocol, plain legacy bytes otherwise — instead of
forcing kitty sequences into a terminal that never asked for them.

### 2.2 No desktop shortcut is stealing your chords

*(GNOME-specific; the principle is universal.)*

```bash
gsettings get org.gnome.desktop.input-sources xkb-options   # want: []
gnome-apply                                                 # clears grp:alt_shift_toggle
```

`grp:alt_shift_toggle` makes Alt+Shift a keyboard-layout switch, so **every** chord holding both
loses a modifier before the terminal sees it. This masqueraded as "3-modifier chords are
unreliable" for weeks. `apply-gnome-settings.sh` also moves GNOME's workspace switching off
`Ctrl+Alt+Arrow` so pane resize works.

### 2.3 Tools must be reachable by the herdr *server*

**The herdr server's PATH is frozen when the server starts**, and mise only puts *globally*
configured tools on PATH. A tool declared solely in a project `.mise.toml` is invisible to the
server — its popup or plugin will open and close instantly, with no error anywhere.

```bash
mise use -g lazygit@0.42.0 yazi@26.8.15 bun@1.4.0
ln -sf "$(mise which lazygit)" ~/.local/bin/lazygit   # ~/.local/bin is on the server PATH,
ln -sf "$(mise which yazi)"    ~/.local/bin/yazi      # so this takes effect without a
ln -sf "$(mise which bun)"     ~/.local/bin/bun       # server restart. bun: gh-pr plugin.
```

Verify the way the *server* resolves them, not the way your shell does:

```bash
pid=$(pgrep -f 'herdr server' | head -1)
spath=$(tr '\0' '\n' < /proc/$pid/environ | sed -n 's/^PATH=//p')
env -i PATH="$spath" HOME="$HOME" /bin/sh -c 'command -v lazygit yazi bun'
```

`scripts/verify-tools.sh` covers the wider toolchain.

---

## 3. Install and update

```bash
herdr update                                        # stable channel
herdr --skill > ~/.claude/skills/herdr/SKILL.md     # regenerate after EVERY update
```

The agent skill is version-specific — it is the CLI reference a lead Claude uses to drive other
panes, and a stale copy teaches the wrong flags.

Config lives at `~/.config/herdr/config.toml`, symlinked here to `config/herdr/config.toml`.
Compare it against `herdr --default-config` after an upgrade; the file deliberately mirrors the
default's section order to keep that diff readable.

**Never run bare `herdr`** from a script or an agent — it attaches a client. Use subcommands.
(At a keyboard it is simply how you re-attach after `ctrl+alt+q`.)

---

## 4. Accounts

Claude Code accounts are managed with **clauth**, which owns credentials and per-session config
directories. Profiles rotate automatically as quotas fill:

```
quantivly-3 (home) → quantivly-1 → quantivly-2      thresholds 95%/5h, 98%/7d
```

A `clauth-daemon.service` systemd **user** unit runs the refresh/auto-switch loop, so rotation
happens without a TUI open. `max_auto_spend = 0` — no unattended pay-as-you-go spend.

> **The distinction that bites:** `clauth start <profile>` spawns the claude *binary*, bypassing
> the `claude()` shell function. You get the right account but **no team-lead capability**. For
> a session that will lead a team, use `clauth <profile>` and then `claude`.

---

## 5. Keymap

`f12` is the prefix. The stock `ctrl+b` collides three ways here: Claude Code binds it to
"background this task", tmux wants it, and it clashed with the previous orchestrator.

Every daily action **also** has a direct chord, so the prefix is an escape hatch rather than the
main path — useful for muscle memory and for `herdr --remote` onto hosts where your chords may
not survive. `f12 ?` shows both bindings per action.

| Action | Chord | Prefix | Rationale |
|---|---|---|---|
| split right / down | `ctrl+shift+e` / `ctrl+shift+o` | `f12 v` / `f12 -` | tmux `C-S-e` / `C-S-o` |
| close pane | `ctrl+shift+w` | `f12 x` | tmux; **autorepeats — tap it** |
| focus pane | `ctrl+shift+←↓↑→` | `f12 h/j/k/l` | tmux |
| resize pane | `ctrl+alt+←↓↑→` | `f12 r` for mode | direct, no mode |
| zoom | `alt+z` | `f12 z` | tmux `M-z` |
| new / close / rename tab | `ctrl+shift+t` / `ctrl+shift+x` / `ctrl+shift+r` | `f12 c` / `f12 shift+x` / `f12 shift+t` | — |
| next / previous tab | `ctrl+tab` / `ctrl+shift+tab` | — | browser habit |
| move tab | `alt+shift+←` / `alt+shift+→` | `f12 shift+←/→` | tmux `S-Left/Right` |
| tab 1–9 | `ctrl+1..9` | `f12 1..9` | — |
| **agent 1–9** | `alt+1..9` | — | the attention queue |
| next / previous agent | `alt+j` / `alt+k` | — | — |
| last pane | `alt+a` | — | tmux `M-a` |
| goto / navigator | `alt+s` | — | tmux `M-s` |
| new workspace / worktree | `ctrl+shift+n` / `ctrl+shift+g` | `f12 shift+n` / `f12 shift+g` | — |
| sidebar · scrollback · detach · notification target | `ctrl+alt+b` · `ctrl+alt+e` · `ctrl+alt+q` · `ctrl+alt+o` | — | — |
| close/rename workspace, swap panes, copy mode, reload, help | — | prefix only | rare or destructive |
| lazygit · yazi popups | `alt+g` · `alt+y` | — | tmux `M-g` / `M-y` |

**Note that the digits moved.** In tmux, `M-1..9` switched *windows*. Here `alt+1..9` focuses
**agents** and tabs moved to `ctrl+1..9`. This is the binding most likely to fight old habits.

### The layering rule — the one way to break this file

Every rebound action is an **array**, and setting a field **replaces** it wholesale:

```toml
split_horizontal = ["prefix+minus", "ctrl+alt+s", "ctrl+shift+o"]
#                    ^^^^^^^^^^^^ omit this and `f12 -` silently ceases to exist
```

An action that relied on a stock prefix default **must list that default explicitly** or it is
lost, with no warning. Only never-defaulted actions (`next_agent`, `previous_agent`,
`move_tab_*`, `resize_pane_*`) take a bare value.

---

## 6. The sidebar

`agent_panel_sort = "priority"` makes the sidebar an **attention queue**, not a directory:
blocked agents float to the top, so `alt+1` is always whatever most needs you.

Claude panes get six rows: identity (state, workspace, tab, account, PR chip) · terminal title ·
model + effort · context ramp · two herdmates team rows that vanish when empty.

> **Rate limits and session cost are deliberately *not* in the sidebar** (removed 2026-08-30).
> The clauth daemon already rotates accounts at its thresholds, so those numbers explained why
> a rotation had happened rather than prompting any action — and every published token is one
> more thing that can fail silently. Both are still printed in the **in-pane** status line,
> where you are already looking, at no extra cost. The context ramp stays: it is the only
> warning before a forced compaction, and nothing else surfaces it across panes.

### How the colour works

Token *values* are plain text — the wire schema has no style fields, and nothing inspects a
value. The only styling knob is per token **occurrence** in the config. So colour is carried by
**mutually exclusive band tokens**: the publisher sets exactly one of
`ctx_ok` / `ctx_warn` / `ctx_crit` and clears its siblings in the same call. Empty tokens elide
along with their separator, so only the applicable band draws, in its own colour.

Fed by `claude/hooks/session-statusline.sh` in this repo, symlinked to
`~/.claude/hooks/session-statusline.sh` by `./install`. **It also has to be wired up as Claude
Code's `statusLine`**, which `./install` does not do — add this to `~/.claude/settings.json`:

```json
{ "statusLine": { "type": "command",
                  "command": "~/.claude/hooks/session-statusline.sh",
                  "refreshInterval": 60 } }
```

Without that, the script never runs, every `$mdl` / `$eff_*` / `$ctx_*` token resolves to nothing,
and those sidebar rows render empty — with no error anywhere. It doubles as your in-pane status
line, so if you can see model/context text inside the pane, the publisher is alive.

Constraints worth knowing:

- One `report-metadata` call per tick; `--seq` so a cancelled run's straggler cannot overwrite a
  newer report; `--ttl-ms 240000` so a dead Claude leaves a clean row within four minutes.
- Limits: names `[A-Za-z0-9_-]{1,32}`, ≤16 keys per call, ≤32 retained per pane, 80-char values.
- Token names are **global per pane, last writer wins** — herdmates publishes `model`, so ours
  is `mdl`.
- Never put `·` in a value; it is indistinguishable from herdr's own separator.
- Under width pressure herdr grows tokens round-robin, so truncation hits the **longest** value,
  not the rightmost. Keep identifying text at the start.
- Tokens are **not** persisted across a server restart; they repopulate within a minute.

> **An error anywhere inside `[ui]` silently reverts ALL of `[ui]`** and reports `partial` with
> no error text. After any config edit:
> `herdr server reload-config | jq '.result.status'` — it must say `applied`.

Also: `session.json` pins the live sidebar width, so a width change in the config does nothing
until you **double-click the divider**.

### How much sidebar do you actually need?

Less than you might think — see §7. Identity fields are cheap and answer "which agent is this,
and whose quota is it burning". The telemetry fields cost a subprocess per pane per minute plus
all the band machinery above. Start minimal and add only what changes a decision.

---

## 7. Interrupts — the part that matters most

**Verified end to end.** With `[ui.toast] delivery = "system"`, a background agent that finishes
or blocks raises a real desktop notification:

```
summary: "claude needs attention"
body:    "~ · 1 · toast-test"        <- the tab label, so you know which agent
```

Confirmed by instrumenting the D-Bus session bus and driving an agent to `blocked` in an
unfocused tab. Implementation detail: herdr shells out to `notify-send`, so that binary must be
on the **server's** PATH (§2.3) and the server needs the session-bus environment.

This is the difference between *watching* a dashboard and *being told*. Bind
`open_notification_target` (`ctrl+alt+o`) and let the queue come to you. `[ui.sound] enabled`
adds a second channel that needs no screen at all.

---

## 8. Plugins

**Plugins cannot declare their own keybindings.** The binding must be wired into `config.toml`
by hand, or the action is unreachable no matter what the plugin's README claims. Verify action
IDs against reality before binding them:

```bash
herdr plugin action list
```

| Chord | Action ID | Plugin |
|---|---|---|
| `ctrl+shift+a` | `clauth.open` | account dashboard |
| `ctrl+shift+y` | `persiyanov.reviewr.toggle` | diff review pane |
| `ctrl+shift+l` | `tdi.worktree-from-linear.pick` | Linear issue → worktree |
| `f12 shift+l` | `herdr-lazy.manage` | plugin management |

Curated set managed by **herdr-lazy** (`config/herdr/plugins/plugins.list`): herdmates (Claude
Code's native teams as herdr panes), clauth, gh-pr (`$pr` chip, needs `bun`), reviewr, the tdi
worktree tooling, and a local `sidebar-icons` plugin.

- `herdr plugin link` state is **herdr-local and is not restored by herdr-lazy after a
  rebuild.** Re-link local plugins after a refresh; nothing will report an error.
- Plugin CLIs leak environment out of a herdmates lead session (upstream bug). Prefix with
  `env -u HERDR_PLUGIN_STATE_DIR -u HERDR_PLUGIN_CONFIG_DIR`.
- Actions listed by `plugin action list` are **not** proof a plugin is enabled — disabled
  plugins still advertise theirs.
- **A plugin pane that flickers and vanishes means the command exited.** Its error is real but
  unreadable. Reproduce it in a shell. Example: the Linear picker requires the focused pane's
  cwd to be inside a git repository, and says so — for about forty milliseconds.

---

## 9. Spawning work

### `hspawn` — one isolated worker per task

```bash
hspawn <repo-dir> <slug> [profile|-] [prompt...]
```

Creates a worktree on `zvi/<slug>`, starts Claude in it, optionally pinned to a clauth profile,
and sends a first prompt. Deliberately **no team lead** — these are isolated single-account
workers, which is the point of the worktree.

Two things it has to handle, and any homegrown equivalent must too:

1. **`herdr agent wait` requires an already-detected agent.** It resolves its target up front
   and fails with `agent_not_found` if herdr has not noticed the agent yet. It cannot wait *for*
   detection; poll for that separately.
2. **Claude's trust-folder dialog defaults to "No, exit"**, and a fresh worktree triggers it
   every single time. Answer it on the **agent** surface (`herdr agent send-keys <pane> down`,
   then `enter`) *after* detection. Sending the keys at the pane level as soon as the dialog
   renders does not work — the TUI is not accepting input yet and the keys vanish silently.

`herdr agent prompt` refuses to type into a blocked agent, so an unanswered dialog resurfaces
later as `agent_blocked`.

### Teams

**herdmates** hosts Claude Code's *native* agent teams as herdr panes. It ships a `teammux`
binary that shims `tmux` on the pane PATH, so teammates materialise as real herdr panes and show
up in the sidebar and `herdr agent list` like anything else.

Choosing between the two:

- **Independent tasks that would collide on disk** (several unrelated issues in one repo), or
  work that should burn different accounts → `hspawn` worktrees.
- **One goal that decomposes into parts needing shared findings or ordering** → a team, so you
  state the goal once instead of becoming the message bus yourself.

### Orchestrating from an agent

`~/.claude/skills/herdr/SKILL.md` teaches a lead Claude `herdr agent list/read/prompt/wait`.
Regenerate it after every `herdr update`.

---

## 10. Troubleshooting

| Symptom | Cause |
|---|---|
| A chord does nothing | Something upstream ate the key press. Keyprobe it (§2.1); look for a release with no press. |
| A `[ui]` change does nothing | Reload reported `partial` and **all** of `[ui]` reverted. Check `.result.status`. |
| Popup opens and closes instantly | Binary not on the **server** PATH, or not installed at all (§2.3). |
| Plugin pane flickers | The command exited. Run it in a shell to see the error. |
| Popup will not close with its own chord | Popups swallow every key, including `f12`. Quit with `q`. |
| Sidebar row stale after a crash | Tokens expire on the four-minute TTL. |
| Sidebar width ignores the config | `session.json` pins the live width; double-click the divider. |
| Agent never receives its prompt | It is `blocked` — usually an unanswered trust dialog. |
| Alt-letter chords dead | See the layout note below. |

**Machine-specific notes.** These describe this workstation (Ubuntu / GNOME / Wayland +
Alacritty, `us`+`il` layouts). Label them as such when adopting elsewhere; on macOS or another
terminal the specifics differ but §2.1 still applies.

- **Non-Latin keyboard layouts:** with a Hebrew (`il`) layout active, *unshifted* letter chords
  — and `Ctrl+C` itself — carry Hebrew codepoints and match nothing. Shifted letters, digits,
  arrows and F-keys are unaffected. Switch to `us` first. This is the most likely "herdr is
  broken" moment in daily use.
- **Kitty-lapse hazard:** with herdr inside tmux, or Alacritty in vi/search mode,
  `ctrl+shift+X` collapses to `ctrl+X` in the pane. Nothing is bound to `ctrl+shift+d` for that
  reason — `ctrl+d` is EOF.
- **Reserved by Claude Code:** never bind `alt+w` (`meta+w`); `alt+p` / `alt+o` / `alt+t` are
  its own toggles.
- **Reserved by the terminal and desktop here:** `ctrl+shift+{c,v,f,b,space}` (Alacritty),
  `ctrl+shift+u` (IBus), `ctrl+shift+m` and `ctrl+alt+{t,d,tab,esc,del}` (GNOME).
- **Cost of the alt-letter chords:** `alt+{a,g,j,k,s,y,z}` are intercepted globally, so zsh and
  pane TUIs never see them — the same trade tmux already made here.

---

## 11. Not a developer? Use Orca instead

**Recommendation: non-developers should use [Orca](https://github.com/stablyai/orca), not
herdr.**

Orca is Stably AI's MIT-licensed agent development environment: a desktop app (plus iOS, Android
and VPS) that runs 30+ CLI coding agents side by side, each in its own git worktree, with an
integrated editor, GitHub and **Linear** task workflows, SSH remote worktrees, and push
notifications so you can steer an agent from your phone. It uses your own subscription or API
keys and does not proxy them.

**Why the split — stated as criteria, not as a rule.** You want herdr if you need worktree
isolation, multi-account rotation, config-as-code, or remote terminal sessions (§1). If you need
*none* of those, herdr's terminal-native workflow, chord keymap and TOML config are pure cost.
Anyone who *does* need them is a "developer" for this purpose, whatever their job title.

What makes Orca the better fit for non-devs is the **GUI and the phone app**, not a smaller
feature set — its capabilities overlap herdr's substantially, worktrees included. Arriving from
a GUI rather than a terminal is the whole point.

**One hard constraint if you try both.** Orca installs its own Claude Code `statusLine` hook,
and Claude Code has exactly **one** `statusLine` slot — the same one the herdr sidebar publisher
occupies (§6). On a shared `~/.claude` the two cannot coexist. Orca's earlier trial here added
11 hook entries and grew `settings.json` from 3 KB to 26 KB; removal was clean, but plan on one
or the other per machine, not both.

> **Honest caveat, and please treat it as one.** This recommendation rests on research and a
> short hands-on evaluation — **not** on running Orca end to end on real work. Nobody here has
> shipped anything with it yet. It is a starting point, not a verdict, and **feedback from
> anyone who actually uses it is very welcome** and will be folded back into this guide. If it
> turns out to be the wrong call, please say so.

---

## 12. Reference

| | |
|---|---|
| Config | `config/herdr/config.toml` → `~/.config/herdr/config.toml` |
| Key encoding probe | `scripts/herdr-keyprobe.sh` |
| Sidebar publisher | `claude/hooks/session-statusline.sh` → `~/.claude/hooks/` (+ `statusLine` in `~/.claude/settings.json`) |
| Agent skill | `~/.claude/skills/herdr/SKILL.md` (`herdr --skill`) |
| Spawn helper | `hspawn` in `zsh/zshrc.company` |
| Plugin list | `config/herdr/plugins/plugins.list` |
| Local plugin | `config/herdr/plugins/local/sidebar-icons` |
| Tool check | `scripts/verify-tools.sh` |
| Desktop keys | `scripts/apply-gnome-settings.sh` (`gnome-apply`) |
