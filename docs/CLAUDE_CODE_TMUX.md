# Claude Code in tmux: Fullscreen Rendering

This repo enables Claude Code's **fullscreen rendering** mode by default (via
`CLAUDE_CODE_NO_FLICKER=1` in `zsh/zshrc.conditionals.tools`). This page explains
why, and how the workflow changes inside tmux.

## Why it's enabled

Running Claude Code's *classic* renderer inside tmux corrupts the scrollback:
scroll up and older output appears re-rendered on top of itself, with
overlapping lines that are hard to follow.

The cause is not tmux. Claude Code's classic renderer (built on Ink) repaints
in place on the terminal's **normal screen** — it moves the cursor up, clears,
and redraws each frame. Once output grows taller than the pane, the cursor
can't reach lines that have already scrolled into history, so every
intermediate frame gets committed to tmux's scrollback at the wrong anchor.
tmux is faithfully recording throwaway render frames it can't know are
disposable. No tmux or Alacritty setting can fix this (see
[anthropics/claude-code#29937](https://github.com/anthropics/claude-code/issues/29937),
[vadimdemedes/ink#382](https://github.com/vadimdemedes/ink/issues/382)).

**Fullscreen rendering** (research preview, Claude Code v2.1.89+) draws on the
terminal's *alternate* screen buffer like `vim` or `htop` and renders only
visible messages, so intermediate frames never touch native scrollback. The
corruption disappears.

**Confirm it's active:** the input box stays pinned at the bottom of the screen
while Claude works. Run `/tui` with no argument to print the active renderer.

## The trade-off

Because the conversation now lives on the alternate screen, **tmux copy-mode,
mouse drag-select → OSC 52, and tmux-thumbs no longer see Claude's output
directly.** Scrolling and searching move *inside* Claude instead. The shortcuts
below cover everything you previously did with tmux copy-mode.

## Scroll and search inside Claude

| Key | Action |
| :-- | :----- |
| `PgUp` / `PgDn` | Scroll up / down half a screen |
| `Ctrl+Home` / `Ctrl+End` | Jump to start / latest (re-enables auto-follow) |
| Mouse wheel | Scroll a few lines (needs tmux `mouse on` — already set) |
| `Ctrl+o` | Toggle transcript mode (less-style navigation) |

In transcript mode (`Ctrl+o`):

| Key | Action |
| :-- | :----- |
| `/` | Search; `Enter` accept, `Esc` cancel |
| `n` / `N` | Next / previous match |
| `j`/`k`, `g`/`G`, `Ctrl+u`/`Ctrl+d` | Line / top-bottom / half-page |
| `Esc` or `q` | Exit transcript mode |

## Get Claude's text back into tmux scrollback

When you genuinely need tmux copy-mode, tmux-thumbs, or OSC 52 on Claude's
output:

1. Press `Ctrl+o` to enter transcript mode.
2. Press `[` — this writes the full conversation (tool output expanded) into
   tmux's native scrollback. It's now ordinary terminal text, so tmux copy-mode
   (`Ctrl+s v`), thumbs (`Ctrl+Shift+F`), and OSC-52 copy all work on it.

This lasts until you exit transcript mode (`Esc`/`q`); the next `Ctrl+o` starts
fresh. Press `v` instead of `[` to open the conversation in `$EDITOR`.

## One-off native text selection

To select with the mouse the terminal's native way (bypassing Claude's mouse
capture for a single drag), hold **`Shift`** while you click and drag. The
selection is then handled by Alacritty/tmux, so `Ctrl+Shift+C` and tmux's own
copy work on it.

(In-app drag-select also copies automatically on release via OSC 52 / the tmux
paste buffer — both `mouse on` and `set-clipboard on` are set in `tmux.conf`.)

## Adjusting and toggling

- **Scroll speed:** `CLAUDE_CODE_SCROLL_SPEED=3` is set so the mouse wheel moves
  a sensible amount per notch (Alacritty/tmux otherwise send one line per
  notch). Change it (1–20) or run `/scroll-speed` for an interactive ruler.
- **Toggle off for one session:** the renderer is forced on by the exported env
  var, so `/tui default` alone won't stick — a fresh shell re-exports it. To
  truly disable, unset the var: `CLAUDE_CODE_NO_FLICKER= claude`, or comment out
  the export in `zsh/zshrc.conditionals.tools` and reload. To force the classic
  renderer regardless, set `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`.
- **Keep native selection always:** add `CLAUDE_CODE_DISABLE_MOUSE=1` to keep
  flicker-free rendering but let the terminal handle all selection (you lose
  in-app wheel scroll and click-to-expand).

## Notes

- Fullscreen rendering is a research preview; behavior may change upstream.
- tmux lacks synchronized-output, so redraws may flicker slightly more than a
  bare terminal — most noticeable over SSH. If it bothers you, run Claude Code
  in its own terminal tab outside tmux.
- Incompatible with iTerm2's `tmux -CC` integration mode (not used here).

See the design/root-cause write-up in
`docs/superpowers/specs/2026-05-27-claude-code-fullscreen-tmux-rendering-design.md`
and the official docs at <https://code.claude.com/docs/en/fullscreen>.
