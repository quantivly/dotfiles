# Fix: Claude Code output corruption when scrolling tmux scrollback

**Date:** 2026-05-27
**Status:** Approved (pending spec review)

## Problem

When running Claude Code inside a tmux session and scrolling up through tmux's
scrollback (copy-mode), older output is corrupted: it looks re-rendered on top
of itself, with overlapping/duplicated lines that are hard to follow. Only the
most recent screen renders cleanly.

## Root cause (why this is not a tmux bug)

Claude Code's *classic* renderer (built on Ink, React-for-terminals) draws on
the terminal's **normal screen** and repaints each frame by moving the cursor
**up** N lines, clearing, and redrawing in place. This works only while the
frame fits within the viewport, because a terminal can never move the cursor
above a line that has already scrolled into history.

When Claude's output is taller than the pane, each streaming frame scrolls the
top off-screen. The cursor-up clamps at row 1, so the redraw lands at the wrong
anchor, and every intermediate frame gets committed to tmux's scrollback
offset-by-a-bit. tmux is behaving correctly — it faithfully records throwaway
render frames it has no way to know are disposable. That stack of
half-overwritten frames is the "overlapping content" seen when scrolling up.

A second, sharper failure mode: Ink's full-clear path emits `ESC[3J` (erase
*saved* lines) on its render loop, which actively wipes scrollback.

**This cannot be fixed from tmux or Alacritty configuration.** No
`terminal-overrides`, `terminal-features`, or history setting can distinguish an
intermediate render frame ("discard") from real output ("keep"). Confirmed
upstream: anthropics/claude-code#29937 (exact symptom: tmux,
`TERM=tmux-256color`), vadimdemedes/ink#382.

## Solution

Enable Claude Code's **Fullscreen rendering** mode (research preview, available
since v2.1.89; local version is 2.1.152). It draws on the terminal's
*alternate* screen buffer like `vim`/`htop` and only renders currently visible
messages, so intermediate frames never touch native scrollback. The corruption
disappears entirely.

### Mechanism: global env var in zsh

Set `CLAUDE_CODE_NO_FLICKER=1` as an exported environment variable in the
dotfiles zsh config. Per Claude Code docs, the env var and the `/tui fullscreen`
slash command (which writes a `tui` key to `~/.claude/settings.json`) are
equivalent.

The env var is chosen over the settings key because `~/.claude/settings.json` is
**not** symlinked from this dotfiles repo (it holds machine-specific
permissions), so the settings route would be neither version-controlled nor
portable. The env-var route lives in zsh — repo-managed, portable across
machines, and inherited by every launch path (interactive shell, claude-squad
panes, tmux teammate agents).

### Accepted trade-off

Because the conversation now lives on the alternate screen, tmux copy-mode,
mouse drag-select → OSC 52, and tmux-thumbs no longer see Claude's output
directly. Recovery is `Ctrl+o` (transcript mode) then `[` to dump the full
conversation into native scrollback, or `/` for in-app search. This trade-off
was reviewed and explicitly accepted.

## Changes

### 1. zsh config — `zsh/zshrc.conditionals.tools`

In the existing `if command -v claude &>/dev/null` block (currently ~line 383,
which already wraps `claude` to suppress tmux `monitor-activity` alerts during
redraws), add two exports:

- `export CLAUDE_CODE_NO_FLICKER=1` — enables fullscreen rendering (the fix).
- `export CLAUDE_CODE_SCROLL_SPEED=3` — smooth mouse-wheel scrolling inside the
  fullscreen view (matches vim's default; without it Alacritty/tmux send one
  line per notch). Re-tunable at runtime via `/scroll-speed`.

The exports run at file-source time (outside the `claude()` function body) so
they are inherited by all child processes, not only interactive invocations
that go through the wrapper.

No tmux config changes are required: `tmux.conf` already sets `mouse on`
(line 58, needed for wheel scroll) and `set-clipboard on` (line 130, so in-app
selection still reaches the system clipboard via OSC 52) — the two
prerequisites fullscreen needs.

### 2. Documentation — new `docs/CLAUDE_CODE_TMUX.md`

A focused doc covering the workflow change (the existing tmux doc set teaches
copy-mode heavily, so the change needs to be discoverable):

- Why fullscreen is enabled (the fix; link to claude-code#29937).
- Scroll/search *inside* Claude: `PgUp`/`PgDn`, `Ctrl+Home`/`Ctrl+End`,
  `Ctrl+o` transcript mode, `/` to search.
- Recover text into tmux scrollback when copy-mode/thumbs/OSC 52 are genuinely
  needed: `Ctrl+o` then `[`.
- One-off native text selection: `Shift`+drag (bypasses Claude's mouse capture).
- Toggle off: unset `CLAUDE_CODE_NO_FLICKER` (note: `/tui default` alone will
  not stick while the export is live, because a fresh shell re-exports it).
- Adjust scroll speed: `/scroll-speed` or change `CLAUDE_CODE_SCROLL_SPEED`.

Plus one-line pointers from `CLAUDE.md` and `docs/TMUX_LEARNING_GUIDE.md`.

## Verification (must pass before claiming done)

Launch Claude Code in a tmux pane and confirm:

1. **Fullscreen active** — the input box stays pinned at the bottom of the
   screen while Claude works (the documented "is it on?" tell). `/tui` with no
   arg also reports the active renderer.
2. **No corruption** — scrolling up (in-app `PgUp` / mouse wheel) shows clean,
   non-overlapping history.
3. **Scrollback recovery** — `Ctrl+o` then `[` writes clean conversation text
   into tmux native scrollback; tmux copy-mode can then select it.
4. **Clipboard** — in-app selection (drag) copies to the system clipboard via
   OSC 52 / tmux buffer.
5. **claude-squad intact** — the claude-squad pane preview still shows content
   and ready/running state detection still works (this session runs inside
   claude-squad, so a regression is immediately visible). This is the primary
   risk to validate.

Rollback: remove the two exports.

## Risks

- **Research preview** — fullscreen behavior may change in future Claude Code
  versions. Acceptable; the classic renderer remains available via
  `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` if needed.
- **claude-squad interaction** — alt-screen layout could affect claude-squad's
  pane capture or prompt detection. Must be validated (see verification step 5);
  if it regresses, that is a blocker and we reconsider scoping the env var to
  exclude claude-squad-launched sessions.
- **More flicker in tmux** — tmux lacks synchronized-output, so redraws may
  flicker slightly more than a bare terminal. Documented and accepted.
- **Toggle-off ergonomics** — `/tui default` won't persist while the env var is
  exported; documented in the new doc.

## Out of scope

- Any tmux/Alacritty rendering tweaks (cannot fix the root cause).
- Changes to `~/.claude/settings.json` (not repo-managed).
- Upstream Ink/Claude Code fixes to the classic renderer.
