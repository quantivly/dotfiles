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
| every pane since 2026-08-29: `tmn`, `tmux kill-server`, `clauth start` sessions | `tmux -V` → `teammux: unrecognized verb`; every Claude session is a team of one; `$status` on every row | the herdr **server** was restarted from inside a team-lead pane, and every pane inherits the server's environment (§2.4) |

Throughout, `herdr config check` returned `ok` and `herdr server reload-config` returned
`applied` with zero diagnostics.

The sixth row came from an independent evaluation the same day and is different in kind:
nothing in it was misconfigured. The *server* had been started from the wrong place, and the
runbooks' own pre-flight checks passed *because* of the contamination. §2.4 has the rule and the
check.

**`config check: ok` means the file parses and its keys, chords and `[ui]` schema are internally
consistent. It says nothing about effects.** Probed on 2026-08-30 with deliberately broken copies:
a bogus key, a bogus inline field, a non-hex `fg` and a duplicate chord each produced `issues
found`, including cross-action and `[[keys.command]]` chord collisions ("kept X, disabled Y").
What it does **not** catch: a chord that collides with an *unlisted* stock default
(`prefix+shift+d`, `prefix+s` → `ok`), whether a chord ever reaches herdr through the terminal,
whether a popup's binary exists, or whether a token is ever published. Herdr validates its
configuration, not its effects. The terminal does not report a key it swallowed. A plugin pane
closes faster than its error can render. Budget time to verify that each binding *does the thing*
— one at a time — and never generalise from one working example to a class.

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
> `ctrl+shift+o` is swallowed by an Alacritty default. It is a **hints** binding, not a
> `keyboard.bindings` one — `man 5 alacritty` documents it as a shipped `[[hints.enabled]]`
> default (`binding = { key = "O", mods = "Control|Shift" }`), which is why it is absent from
> `man 5 alacritty-bindings` and from the example config. Probe **every** chord you bind, and
> when one is missing, check the hints section too.

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

> **Known inconsistency.** `examples/alacritty.toml.template` — what `alacritty-init` installs —
> still carries the hardcoded `chars = "[111;6u"` form for `ctrl+shift+{e,o,w,t,s,f}`; it
> predates this finding and has not been converted. The live config on this workstation uses
> `ReceiveChar`. After `alacritty-init`, replace those entries. The `chars` form has not been
> re-verified against herdr (UNVERIFIED), so do not assume it works because the template ships it.

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

**The herdr server's PATH is frozen at the moment the server starts.** mise exposes only
*globally* configured tools, so a tool declared solely in a project `.mise.toml` is invisible to
the server — its popup or plugin opens and closes instantly, with no error anywhere.

> **Precise version, corrected after review.** The server PATH does *not* contain mise's `shims`
> directory, but it **does** contain the per-tool `installs/<tool>/<version>` directories for
> whatever was globally configured when the server launched (9 of them on this machine). So the
> operative rule is not "mise is invisible to the server" — it is **"the server's view of PATH is
> a snapshot"**. A tool you add globally *after* the server started stays invisible until the
> server restarts. The `~/.local/bin` symlinks below are what make it work *immediately*, without
> a restart; after a restart the global config alone would have sufficed.

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
# NOTE: `command -v a b c` takes ONE operand in POSIX sh and exits 0 if the FIRST
# resolves — it will happily "pass" with the other two missing. Check one at a time.
env -i PATH="$spath" HOME="$HOME" /bin/sh -c \
  'for b in lazygit yazi bun; do command -v "$b" >/dev/null || echo "MISSING: $b"; done'
```

`scripts/verify-tools.sh` covers the wider toolchain, and also asserts that
`~/.config/mise/config.toml` is still symlinked to the repo and that every declared tool
actually contributes a binary. Run it after any mise change — a version pin that no longer
exists in its backend "installs" successfully and yields **no binary at all** while
`mise install` reports success.

### 2.4 The server's environment is inherited by every pane

§2.3 is one instance of a wider rule: **the herdr server's whole environment is a snapshot of
whoever launched it**, and every pane, plugin subprocess and agent the server creates inherits
that snapshot — not the environment of the shell you happen to be typing in.

Launch it from the wrong place and the mistake is copied everywhere. Verified on this machine
(independent evaluation, 2026-08-30, finding F1): the live server had been
restarted on 2026-08-29 from *inside a herdmates team-lead pane*, so its environment carried
`HERDR_PANE_ID=w2:p1`, `TMUX=teammux,0,0`, `TEAMMUX_STATE_PATH=…/w2_p1.json`,
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, herdmates' `HERDR_PLUGIN_STATE_DIR` /
`HERDR_PLUGIN_CONFIG_DIR`, and the teammux shim directory ahead of `/usr/bin` on PATH. Symptoms,
in the order you notice them:

- `tmux -V` in any pane prints `teammux: unrecognized verb '-V'`. `tmn`, `tma`, `qmux` and the
  documented `tmux kill-server` all hit the shim, which understands ten tmux verbs.
  `/usr/bin/tmux` still works.
- `~/.claude/teams/` fills with one team-of-one directory per Claude session (13–15 here): every
  session inherits the teams flag and a fake `TMUX`.
- herdmates' `$status` row appears on almost every Claude pane, not just team leads (§6).
- The runbooks' pre-flight for team-lead capability — `command -v tmux` "must resolve to the
  shim" — passes for everyone, so it proves nothing.

**Rule: never start or restart the herdr server from inside a herdr pane or a Claude session.**
Use the systemd user unit, which builds a declared, clean environment every time:

```bash
# systemd/herdr-server.service → ~/.config/systemd/user/herdr-server.service (linked by ./install)
# Wanted by graphical-session.target, so it starts once GNOME has imported the session
# environment (DISPLAY/WAYLAND_DISPLAY/XAUTHORITY) — and survives logout, because WantedBy
# propagates START only; stop propagation would need PartOf=, which the unit does not have.
# Linger=yes here means default.target is reached at BOOT, before any session exists, which is
# why hanging off it would hand the server an environment with none of those set.
systemctl --user daemon-reload && systemctl --user enable --now herdr-server.service
systemctl --user disable herdr-server.service    # only if it was enabled under an OLD target:
                                                 # changing [Install] moves no existing symlink
systemctl --user restart herdr-server.service    # the only sanctioned restart
scripts/herdr-server-launch.sh --print-env       # the environment the unit hands the server (secrets masked)
```

The launcher (`scripts/herdr-server-launch.sh`) refuses to start when `HERDR_ENV=1` (a herdr
pane) or `CLAUDECODE` / `CLAUDE_CODE_SESSION_ID` is set (a Claude session) — `--print-env` is
exempt — and then `exec`s herdr by absolute path under `env -i` with exactly: PATH built from
`~/.local/bin` + every `mise bin-paths` entry + system directories (it refuses a PATH containing a
`teammux/bin` dir), the session-bus and display variables toasts need (§7), `SSH_AUTH_SOCK` when
set, `LINEAR_API_KEY` read from `~/.zshrc.local` in a non-interactive zsh, and
`GH_CONFIG_DIR=~/.config/gh-quantivly` when that directory exists (so the gh-pr plugin's `gh` runs
as the work account — **UNVERIFIED** which account actually resolves; check the `$pr` chip on a
work-repo pane after the first start). Stopping or restarting the unit ends every hosted agent
session, exactly like `herdr server stop`. *(Unit and launcher landed alongside this section on
2026-08-30 — read `--print-env` on your machine before enabling.)*

**How to check.** `scripts/verify-tools.sh` has two sections for this: *herdr server environment
hygiene* (the running server carries none of the variables above and no shim directory on PATH;
warns if `LINEAR_API_KEY` is absent) and *Plugin dependencies under the herdr SERVER PATH* (each
dependency resolved one at a time under the server's own PATH). The one-liner the first section
wraps (Linux — it reads `/proc`):

```bash
pid=$(pgrep -f '(^|/)herdr server$' | head -1)   # anchored: the loose form also matches a shell whose cmdline contains the string
tr '\0' '\n' < /proc/$pid/environ | grep -E '^(TMUX|TMUX_PANE|TEAMMUX_STATE_PATH|HERDR_PANE_ID|HERDR_TAB_ID|HERDR_WORKSPACE_ID|HERDR_PLUGIN_STATE_DIR|HERDR_PLUGIN_CONFIG_DIR|CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS|CLAUDECODE|CLAUDE_CODE_SESSION_ID)='
# Any output means contaminated. macOS has no /proc: `ps eww -p $pid` prints the environment after
# the command line (UNVERIFIED here — no Mac available; BSD ps may want `-E` instead of `e`).
```

The repo used to guard the mirror-image hazard for Atrium with an `atrium()` wrapper that
stripped `HERDR_*`, `TMUX` and `TEAMMUX_STATE_PATH` before exec, because a tmux server likewise
inherits whichever client first started it. That wrapper went away with Atrium itself (89d3517),
and this guide kept citing it for months afterwards. What enforces the rule today is
`scripts/herdr-server-launch.sh`, which builds the environment from `env -i` rather than
scrubbing an inherited one, and `scripts/verify-tools.sh`, whose `HERDR_FORBIDDEN_VARS` asserts
none of those variables reached the running server.

---

## 3. Install and update

### From zero

An earlier version of this guide jumped straight to `herdr update` and never said how to get
any of this in the first place. Full sequence:

**Pick a path first.** `./install --herdr` (DO-555) links only the five destinations that
are herdr — `config.toml`, `plugins.list`, `plugins.lock`, the statusline hook, the systemd
unit — and leaves your `~/.zshrc`, `~/.gitconfig`, `~/.tmux.conf`, `~/.p10k.zsh` and VS Code
settings alone. That is the right path for anyone adopting herdr rather than adopting this
repo, and it is what the team-facing write-up documents. The bare `./install` below is the
full 18-link version, correct only if you want this whole configuration.

Two differences that matter if you take the modular path:

- **The shell layer is not linked.** Add `[ -f ~/.dotfiles/zsh/zshrc.herdr ] && source
  ~/.dotfiles/zsh/zshrc.herdr` to your own rc. It needs **zsh** — it is not bash-parseable —
  and `hdespawn` prefers `confirm` (`zsh/functions/system.sh`) but falls back to its own
  `read -q` prompt, so it is not a dependency. That file is where `hspawn`/`hdespawn`/`hreap`,
  the `claude` team-lead wrapper and `herdr-lazy` live.
- **mise is not configured for you**, so step 0's `python3`/`node`/`bun` are yours to
  provide. `scripts/herdr-deps-check.sh` says what is missing, what each one costs, and —
  if you have mise — the exact `mise use -g` line at the versions pinned here.

Either way the checkout must be at `~/.dotfiles`: the unit's `ExecStart` is the absolute
`%h/.dotfiles/scripts/herdr-server-launch.sh`.

```bash
# 0. Prerequisites the earlier version of this list left implicit. Each one strands a step below.
#    - rustup (https://rustup.rs): herdmates is compiled by its plugin build hook
#      (`cargo install --path . --root ~/.local`). Rust is deliberately NOT in .mise.toml —
#      cargo comes from ~/.cargo/bin (see the comment in .mise.toml).
#    - jq: hspawn / hdespawn / hreap read herdr's JSON replies and refuse to run without it.
#      Not managed by mise here — `apt install jq` (or brew).
#    - mise ITSELF: nothing in this repo installs it, and ./install gates its entire tool
#      section on mise already being present (the mise gate in `install`). No mise means no node/python/bun
#      and no message saying so. `curl https://mise.run | sh`.
#    - python3, node, bun: the sidebar publisher AND herdr's own Claude hook need python3; the
#      Linear plugin runs on node; gh-pr on bun. All three are pinned in .mise.toml, and
#      ./install runs `mise install`, so step 1 provides them.
#    - LINEAR_API_KEY in ~/.zshrc.local BEFORE the server first starts (step 5). The launcher
#      reads it from there, and a running server never re-reads shell config — add it later and
#      you need `systemctl --user restart herdr-server.service` (§2.4).

# 1. The dotfiles themselves — this is what symlinks config.toml, the statusline publisher,
#    the plugin list, the plugin lock and the herdr-server unit into place (and runs mise install).
git clone git@github.com:quantivly/dotfiles.git ~/.dotfiles && cd ~/.dotfiles && ./install

# 2. herdr itself (see herdr.dev for the current installer; this repo does not vendor it).
herdr --version          # confirm it is on PATH before continuing (~/.local/bin/herdr here)

# 3. Wire the statusline publisher into Claude Code. ./install creates the symlink but
#    CANNOT edit ~/.claude/settings.json — see §6. Without this the sidebar rows are empty.

# 4. Plugins. herdr-lazy is the manager — and it is itself a plugin, so it does not exist until
#    you install it. (The earlier version of this list began at `herdr-lazy check`; on a fresh
#    machine that dies inside the herdr-lazy() shell function with a python IndexError, because
#    the function looks the binary up in `herdr plugin list`.)
herdr plugin install natori-hrj/herdr-lazy
herdr-lazy check         # read-only: installed vs listed in config/herdr/plugins/plugins.list
herdr-lazy install       # install what is missing, restore drifted pins (herdmates compiles here)

#    The LOCAL sidebar-icons plugin is not in the list — it is linked, not installed:
herdr plugin link ~/.dotfiles/config/herdr/plugins/local/sidebar-icons
#    Link state is herdr-local and is NOT restored by herdr-lazy after a rebuild.

# 5. Start the server from a clean, declared environment — never from inside a pane or a
#    Claude session (§2.4). ./install links the unit; enabling it is yours to do. It is wanted
#    by graphical-session.target, so on a desktop it comes up by itself at every login and
#    needs nothing manual; on a headless/SSH-only boot that target is never reached, so start
#    it by hand there with `systemctl --user start herdr-server.service`.
systemctl --user daemon-reload && systemctl --user enable --now herdr-server.service

# 6. Prove it the way the SERVER sees it — mise symlink and binaries, server-env hygiene, and
#    every plugin dependency resolved under the server's PATH:
scripts/verify-tools.sh

# 7. clauth, only if you need several Claude accounts. Not required for single-account use.
```

**Three things `./install` cannot do for you**, and all fail silently: the `statusLine` entry in
`~/.claude/settings.json` (§6), `herdr plugin link` for the local plugin, and enabling the
`herdr-server` unit (it links the file, nothing more). None produces an error — you just get empty
sidebar rows, no agent glyphs, or a server started by hand from wherever you happened to be.

### Updating

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
*Linux-verified.* On macOS this is **UNVERIFIED**: `clauth start --help` says `--with-fallback`
(the in-session chain switch) is "not available … on macOS", and nobody here has run the daemon
on a Mac — do not assume rotation there until you have watched it happen.

> **The distinction that bites — corrected 2026-08-30.** `clauth start <profile>` spawns the
> claude *binary*, bypassing the `claude()` shell function in `zsh/zshrc.herdr`. That function
> adds two things: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, and a launch through
> `herdmates teammux-launch`, which passes `--settings '{"teammateMode":"tmux"}'` so teammates
> materialise as herdr *panes* (a detected lead's argv shows exactly that). An earlier version of
> this note said `clauth start` gives "no team-lead capability". Not quite: whether teams are
> enabled at all depends on the flag *reaching the process*, and on a contaminated server (§2.4)
> every pane inherits it — so a `clauth start` session there is a team-capable lead whose
> teammates run **in-process** rather than as panes (INFERRED from Claude Code's default
> `teammateMode`, not observed), invisible to herdr and easy to misread as "herdmates is broken".
> What `clauth start` reliably lacks is the `teammateMode: tmux` setting. For a session that
> will lead a team, use `clauth <profile>` and then `claude`, and prove it with
> `herdr pane process-info --pane <id>` showing `--settings {"teammateMode":"tmux"}` — not with
> `command -v tmux`, which passes for everyone on a contaminated server.

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
| close pane | `ctrl+alt+x` | `f12 x` | **not** `ctrl+shift+w` — see below |
| focus pane | `ctrl+shift+←↓↑→` | `f12 h/j/k/l` | tmux |
| resize pane | `ctrl+alt+←↓↑→` | `f12 r` for mode | direct, no mode |
| zoom | `alt+z` | `f12 z` | tmux `M-z` |
| new / close / rename tab | `ctrl+shift+t` / `ctrl+shift+x` / `ctrl+shift+r` | `f12 c` / `f12 shift+x` / `f12 shift+t` | — |
| next / previous tab | `ctrl+tab` / `ctrl+shift+tab` | `f12 n` / `f12 p` | browser habit |
| move tab | `alt+shift+←` / `alt+shift+→` | `f12 shift+←/→` | tmux `S-Left/Right` |
| tab 1–9 | `ctrl+1..9` | `f12 1..9` | — |
| **agent 1–9** | `alt+1..9` | — | the attention queue |
| next / previous agent | `alt+j` / `alt+k` | — | — |
| last pane | `alt+a` | — (unbound by default) | tmux `M-a` |
| goto / navigator | `alt+s` | `f12 g` | tmux `M-s` |
| new workspace / worktree | `ctrl+shift+n` / `ctrl+shift+g` | `f12 shift+n` / `f12 shift+g` | — |
| sidebar · scrollback · detach · notification target | `ctrl+alt+b` · `ctrl+alt+e` · `ctrl+alt+q` · `ctrl+alt+o` | `f12 b` · `f12 e` · `f12 q` · `f12 o` | — |
| rename / close workspace · reload config · help · settings | — | `f12 shift+w` / `f12 shift+d` · `f12 shift+r` · `f12 ?` · `f12 s` | prefix only — rare or destructive. Stock defaults, left untouched in `config.toml` (checked against `herdr --default-config`; not re-probed at the keyboard) |
| remove worktree | — | `f12 shift+k` | bound 2026-08-30 for tearing down `hspawn` worktrees; opens herdr's confirmation. Prefix-only because it is destructive. Not yet probed at the keyboard — `config.toml` is the source of truth |
| previous / next workspace | `alt+shift+↑` / `alt+shift+↓` | `f12 shift+↑` / `f12 shift+↓` | bound 2026-08-30 (same family as move-tab on `alt+shift+←→`); cycling between many live workspaces. Not yet probed at the keyboard — `config.toml` is the source of truth |
| lazygit · yazi popups | `alt+g` · `alt+y` | — | tmux `M-g` / `M-y` |

An earlier version of this table listed "swap panes" and "copy mode" as prefix-only actions.
`herdr --default-config` has no `swap_pane` or `copy_mode` action and nobody has seen either at
the keyboard, so they are gone; if you find them, they belong back here with evidence.

**Note that the digits moved.** In tmux, `M-1..9` switched *windows*. Here `alt+1..9` focuses
**agents** and tabs moved to `ctrl+1..9`. This is the binding most likely to fight old habits.

### The layering rule — the one way to break this file

Every rebound action is an **array**, and setting a field **replaces** it wholesale:

```toml
split_horizontal = ["prefix+minus", "ctrl+alt+s", "ctrl+shift+o"]
#                    ^^^^^^^^^^^^ omit this and `f12 -` silently ceases to exist
```

An action that relied on a stock prefix default **must list that default explicitly** or it is
lost, with no warning — and `herdr config check` will not tell you: it flags duplicate chords among
the actions *listed* in the file, but a chord that collides with a stock default you have not
re-listed still reports `ok` (§0). A bare value is only safe for actions whose stock default is **empty**
(`""`, i.e. unbound out of the box) — there is nothing to preserve. Those are `focus_agent`,
`next_agent`, `previous_agent`, `move_tab_*` and `resize_pane_*`. (An earlier version of this
line called them "never-defaulted" and omitted `focus_agent`; they *are* defaulted, just
defaulted to nothing.)

This is easy to get wrong at scale: an audit of this config on 2026-08-30 found **15 of 25
rebound actions had silently dropped their prefix binding**, which would have left most of the
keymap unreachable over `herdr --remote` on a host where the chords don't survive. Diff against
`herdr --default-config` after any keymap change.

### Why `close_pane` is not on `ctrl+shift+w`

It was, and it closed a live agent session by accident. `ctrl+shift+w` is a decade of browser
"close tab" muscle memory, and herdr's `close_pane` **autorepeats** if the chord is held.

herdr has **no pane-level close confirmation** — `[ui] confirm_close` covers *workspaces* only —
so there is nothing to switch on. The mitigation is to not offer the accident-prone chord:
`close_pane` is `["prefix+x", "ctrl+alt+x"]`. Worth copying if you value your sessions.

---

## 6. The sidebar

`agent_panel_sort = "priority"` makes the sidebar an **attention queue**, not a directory:
blocked agents float to the top, so `alt+1` is always whatever most needs you.

Claude panes get five rows (six before 2026-08-30, when model, effort and context were merged
onto one line): identity (state, workspace, tab, account, PR chip) · terminal title · model +
effort + context ramp · herdmates' `$task` (omitted when empty — it has never populated here) ·
a **time row**: herdmates' `$status` word plus the **idle band**.

The **idle band** is the sidebar's only time dimension. The publisher `stat`s the session's
transcript and sets exactly one of `$idle_ok` / `$idle_warn` / `$idle_crit` (under 5 min ·
5–9 min · 10 min and over, matching herdmates' quiet/stalled tiers; values like `idle 2m`,
`idle 3h`), so a pane that has been silent for an hour is *coloured*, not merely labelled. It
shares `$status`'s row on purpose — the row reads `stale · idle 47m` when herdmates publishes and
`idle 47m` alone when it does not — because adding it to the model row would push that row's
worst case from ~25 to ~39 columns against a 40-column sidebar. It is the visual cue for §9's
cleanup rule.

herdmates' `$status` is one token with a varying value (its five-state word: `online`,
`waiting`, `blocked`, `stale`, `!! needs-you`), so unlike the band tokens it cannot be coloured
per state — `stale` renders exactly like `online`. `stale` means **no transcript write for 10
minutes or more** (herdmates `signal_engine.rs`: quiet at 5 min, stalled at 10; `waiting` covers
the soft tier). And despite what the config comment said until 2026-08-30, it is *not* team-only
in practice: herdmates publishes it on any pane whose session has a directory under
`~/.claude/teams/`, which on a contaminated server (§2.4) is nearly every Claude pane.

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
                  "command": "bash /home/<you>/.claude/hooks/session-statusline.sh",
                  "refreshInterval": 60 } }
```

Use the absolute path — that is the form running here. Whether `~` is expanded inside
`statusLine.command` is UNVERIFIED, and a publisher that never starts is indistinguishable from
an empty sidebar.

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
>
> *Confidence note:* this rests on a **single observation** during the original config work and
> has not been deliberately reproduced. Checking that reload says `applied` costs nothing and is
> worth doing regardless, but if you are debugging something specific, do not treat the
> total-revert behaviour as established — verify it first.

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
on the **server's** PATH (§2.3) and the server needs the session-bus environment — which is why
the launcher in §2.4 passes `DBUS_SESSION_BUS_ADDRESS` and the display variables through.
Linux-verified; the macOS delivery path is **UNVERIFIED**.

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
worktree tooling (`worktree-setup`, and `worktree-from-linear`, which needs `LINEAR_API_KEY` in
the **server** environment — §2.4), and herdr-lazy itself. `0xGosu/herdr-auto-pilot` was dropped
from the list on 2026-08-30: it had been installed-but-disabled since 2026-08-28 because it runs
a live auto-prompting daemon, and a teammate running `herdr-lazy install` would have built a
daemon they never enable. (Its `pause/resume/status` actions still show in `plugin action list`
wherever it remains installed — see the third bullet below.) The local `sidebar-icons` plugin is
**not** in the list: it is linked (`herdr plugin link`, §3 step 4), not installed.

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
hspawn [-p profile] [-m model] [-e effort] [--mode auto|acceptEdits|plan|dontAsk|default(=manual)] [-b base] [-n name] [--] <repo> <slug> [prompt…]
hdespawn <slug|pane-id> [--yes]                  # tear one worker down: pane, workspace, worktree, registry entry
hreap [--close] [--mine] [--older N] [--json]    # Claude processes herdr hosts, with idle age and memory (default: idle >= 30 min; --older 0 = all)
```

Creates a worktree on `${HSPAWN_BRANCH_PREFIX:-$USER}/<slug>` (so `zvi/<slug>` here — an earlier
version of this guide hardcoded that), starts Claude in it, optionally pinned to a clauth profile,
and sends a first prompt. `-m` / `-e` pass `--model` / `--effort` to Claude; `--mode` sets the
permission mode (default `auto`); `-b` chooses the base ref for the worktree (herdr's default
otherwise); `-n` names the agent. Every spawn is recorded in `~/.local/state/hspawn/` — one JSON
file per pane with the slug, branch, workspace and creating session — which is what lets
`hdespawn` and `hreap --close` tell your panes from everyone else's. Deliberately **no team lead**
— these are isolated single-account workers, which is the point of the worktree.

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

**A pane id is not a permanent name, and the registry is permanent.** herdr allocates workspace
ids from a short alphabet whose counter lives only in the running server, so a restart reissues
them from the start — `~/.config/herdr/herdr-server.log` on this box shows `w4`, `w5`, `wN` and
`wP` each created twice in five days — and every new workspace's first pane is `p1`. The registry
under `~/.local/state/hspawn/` is a file, so it outlives all of that, and its entries are
deliberately long-lived: every hspawn bail-out keeps its entry, and `hreap --close` annotates
rather than deletes so `hdespawn` can finish the teardown later. Three consequences worth knowing:

- hspawn **never overwrites** an existing entry for a reused pane id. It renames it to
  `<pane>.stale-<timestamp>.json` (still a `*.json`, so `hdespawn <slug>` still finds it) and says
  so. Before, the older spawn's worktree and branch were orphaned silently.
- **`hdespawn <pane-id>` is the exact form** — it is a direct file lookup. `hdespawn <slug>` scans
  every entry and refuses when two match, which `hreap --close` makes likely by design. That is
  why hreap's `Finish with:` line and hspawn's failure messages print the pane id.
- If the workspace id in an entry now holds **someone else's** worktree, hdespawn disowns the live
  workspace — it touches nothing herdr owns — and finishes the teardown from the path the entry
  recorded, behind the same uncommitted/unpushed guard.

`--` means what it says: after it, nothing is parsed as an option *or* as the deprecated
positional `[profile|-]` slot, so `hspawn -- <repo> <slug> - "prompt"` keeps the literal `-`.

State table: `scripts/test-hspawn.sh` (126 checks, in CI as `hspawn-test`). It is hermetic in a
specific way — a recording `herdr` **stub** goes at the front of `PATH` for every run, rather than
relying on `herdr` being absent, because the machine this was written on has a real one talking to
a live server and hdespawn's job is to remove workspaces.

### Teams

**herdmates** hosts Claude Code's *native* agent teams as herdr panes. It ships a `teammux`
binary that shims `tmux` on the pane PATH — Claude Code's team feature requires tmux, and teammux
translates those calls into herdr panes.

> **Corrected 2026-08-30, after actually running a team.** An earlier version of this guide said
> teammates "show up in the sidebar and `herdr agent list` like anything else". They do **not**.
> Teammates appear as real *panes*, but herdr does not detect them as *agents* — so they are
> absent from `herdr agent list`, from the sidebar's agent rows, from the priority sort, and from
> toasts. The lead is detected; its teammates are not. That claim was inferred from the shim's
> existence rather than observed, which is the same mistake §0 warns about.
>
> Two further observations from that run, both worth knowing before you rely on the sidebar to
> supervise a team:
> - **A lead reports `done` while its teammates are still working.** A lead waiting on its team
>   looks finished. Read the lead's own roster (it lists each teammate with elapsed time), not the
>   agent state.
> - Of the herdmates sidebar tokens, `$status` populated (`online`, later `waiting`); **`$task`
>   never did.**

> **Why, specifically (evaluation of 2026-08-30, F3 — reported upstream).** Claude Code execs
> each teammate through its resolved versioned binary, so the pane's foreground process is named
> `2.1.251` (`herdr pane process-info --pane <id>`), while a lead launched as `claude` is named
> `claude` — the same file, reached through the `~/.local/bin/claude` symlink. That name is the
> one thing that differs between a detected lead and an undetected teammate: herdr's own detector
> accepts the teammate's screen when run offline (`herdr pane read <id> --source detection
> --lines 40 > s; herdr agent explain --file s --agent claude` → `state: idle`, rule
> `live_prompt_box`), yet `herdr agent explain <id>` on the live pane returns `agent_not_found`.
> INFERRED, not confirmed by upstream: herdr detects the foreground process first and never
> consults the Claude manifest for an unrecognised name — the same class as herdrdev/herdr#803,
> where a nix wrapper named `.claude-unwrapped` is invisible in the same way. Drafts of the two
> issues (herdr: recognise `…/claude/versions/<v>`, or trust the hook-reported
> `agent_session.agent`; herdmates: set `HERDR_AGENT=claude` on the respawned command, or report
> state through `herdr pane report-agent`) are written but not yet filed.

**Related blind spot:** a pane sitting on Claude's trust dialog is *also* undetected as an agent,
so it never enters the attention queue and never raises a toast. Since a fresh directory triggers
that dialog every time, the interrupt path is blind precisely at startup — when agents most
commonly block. Two review agents sat stalled this way and were only noticed by eye.

Choosing between the two:

- **Independent tasks that would collide on disk** (several unrelated issues in one repo), or
  work that should burn different accounts → `hspawn` worktrees.
- **One goal that decomposes into parts needing shared findings or ordering** → a team, so you
  state the goal once instead of becoming the message bus yourself.

### Clean up what you spawn

Whether you spawn with `hspawn`, a team, or `herdr agent start`, **close the pane once you have
the output.** An idle agent holds its memory regardless of whether it is doing anything, and on a
constrained box memory is what runs out first — silently. In one session six spawned panes left
running after delivering took this machine to **load 27 and 96% swap across 33 claude processes**,
putting ten unrelated working sessions at risk; closing them recovered it to load 11.5 / 84% / 23.

```bash
hreap --older 0                        # every Claude process herdr hosts — detected or not — with idle age, memory, creator
hreap                                  # the same, filtered to idle >= 30 min (the default; `--older N` to change it)
hreap --close --mine                   # close YOUR idle hspawn panes (registry-tagged only; never touches anything else)
hdespawn <slug>                        # one hspawn worker: pane, workspace, worktree, registry entry
herdr pane list --workspace <ws>       # every pane in a workspace, whether or not herdr detected an agent in it
herdr pane close <pane_id>             # panes YOU created, once their work is collected
herdr worktree remove --workspace <ws> --force    # what hdespawn runs underneath
```

**Not `herdr agent list`.** An earlier version of this recipe used it as "what is alive". It lists
*detected* agents only — herdmates teammates and any pane on Claude's trust dialog are absent from
it — so on 2026-08-30 it reported 14 agents while 33 claude processes were running, 15 of them
finished teammates that had idled for three hours holding 4.5 GB. Cleanup has to enumerate panes
or processes. `hreap` does (it joins `herdr api snapshot` panes with `herdr pane process-info`,
`/proc` memory and transcript age), and `hspawn`'s registry (`~/.local/state/hspawn/`) is what
lets it tell your spawns from everyone else's. The tab bar's second right-hand widget,
`agents <detected>/<claude procs>` (`tab_bar_right` in `config.toml`, Linux-only like its
`load · mem` neighbour), shows the same gap at a glance — the difference between the two numbers
*is* the undetected population.

Reuse a pane only when you have a concrete next task for it. Do not close panes you did not
create.

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
| A pane runs Claude but is not in the sidebar or `herdr agent list` | `herdr agent explain <pane>` says why. If it returns `agent_not_found`, herdr never detected an agent there at all: check `herdr pane process-info --pane <pane>` — a foreground process named like `2.1.251` (Claude's versioned binary, which is what herdmates teammates run as) is not recognised (upstream, drafted but not yet filed — §9), and a pane on the trust dialog is not detected either. |
| `tmux` prints `teammux: unrecognized verb` | The herdr server was started from inside a team-lead pane and every pane inherits the teammux shim on PATH (§2.4). Restart it through the unit; meanwhile `/usr/bin/tmux` is the real one. |
| `~/.claude/teams/` fills with team-of-one directories; `$status` on every Claude pane | Same cause: the server hands `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and a fake `TMUX` to everyone (§2.4). |

### Test a config change in a named session, not on the live server

`herdr --session <name>` starts (or re-attaches to) a **separate** server with its own socket, so a
keymap or `[ui]` experiment cannot take down the session your agents live in. `herdr session list`
shows what exists; `herdr session stop <name>` ends it, and `herdr session delete <name>` is needed
for a truly clean next start — a stopped name auto-resumes whatever it last recorded. This is a
keyboard action: `herdr --session` attaches a client, so it carries the same "never from a script
or an agent" rule as bare `herdr`. `HERDR_CONFIG_PATH=<file>` points the read-only
`herdr config check` at a candidate file — the cheap first step (verified: a broken file reports
`config: issues found` with the parse error). **But a path that does not exist validates the
defaults and prints `config: ok`** — typo the path and you have checked nothing, in exactly the
style §0 warns about. Whether the same variable steers a `--session` server is UNVERIFIED. One
hazard, seen: launched from inside a Claude pane, the nested server inherits
`CLAUDE_CODE_SESSION_ID` / `CLAUDE_CODE_CHILD_SESSION` and Claude panes in it stop writing
transcripts — start it from a plain terminal (§2.4), or scrub with `env -u` first.

### Portability gaps to fix before adopting on macOS

Two pieces of this setup are Linux-only and **fail silently** rather than erroring — the exact
class §0 is about. Neither matters on Linux; both matter the moment a teammate adopts this.

- **The statusline publisher** (`claude/hooks/session-statusline.sh`) uses `date +%s%N` for its
  `--seq` value and GNU `timeout` to bound the herdr call. BSD `date` emits a literal `N`, and
  macOS has no `timeout` — and the call is wrapped in `|| true` with stderr going to a log file,
  so the sidebar simply never populates and nothing complains. Use `gdate`/`timeout` from
  coreutils, or drop `--seq`/`timeout` on that platform.
- **`tab_bar_right`** (`config/herdr/config.toml`) parses `/proc/loadavg` and `/proc/meminfo`.
  There is no `/proc` on macOS, so the widget renders nothing. This file is symlinked to every
  teammate by `install.conf.yaml`.
- **The server-environment check** (§2.4) reads `/proc/<pid>/environ`, and `hreap` reads
  `/proc/<pid>/status` for its memory column *and* `ps -o etimes` for the process age it falls
  back to when no transcript is found — BSD `ps` has no `etimes`, so `hreap` needs porting on
  both counts, not just the one. On macOS use `ps eww -p <pid>` for the environment
  (UNVERIFIED here; BSD `ps` may want `-E`). Both hook scripts — the publisher and herdr's own
  `~/.claude/hooks/herdr-agent-state.sh` — need `python3`.

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

**One likely constraint if you try both — stated with its evidence, because it is partly
inference.** *Measured:* Orca's leftovers here include its own `claude-statusline.sh` plus an
`installed` marker, and its trial added 11 hook entries, growing `settings.json` from 3 KB to
26 KB; removal was clean. `settings.json` has exactly one `statusLine` key. *Inferred:* that the
two therefore cannot coexist on a shared `~/.claude`. Nobody has actually run them side by side,
and clauth's per-profile config dirs might isolate them. Plan on one or the other per machine,
but treat the conflict as expected rather than proven.

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
| Server unit | `systemd/herdr-server.service` → `~/.config/systemd/user/herdr-server.service` (`systemctl --user enable --now herdr-server.service`; wanted by `graphical-session.target`, survives logout) |
| Server launcher | `scripts/herdr-server-launch.sh` (`--print-env` shows the environment it builds) |
| Spawn helpers | `hspawn`, `hdespawn`, `hreap` in `zsh/zshrc.herdr`; registry `~/.local/state/hspawn/` |
| Detection diagnosis | `herdr agent explain <pane>` · `herdr pane process-info --pane <pane>` |
| Upstream issues | Drafted, not yet filed — herdr: teammate detection; herdmates: report-agent bridge (§9) |
| Plugin list | `config/herdr/plugins/plugins.list` |
| Local plugin | `config/herdr/plugins/local/sidebar-icons` |
| Tool check | `scripts/verify-tools.sh` |
| Desktop keys | `scripts/apply-gnome-settings.sh` (`gnome-apply`) |
