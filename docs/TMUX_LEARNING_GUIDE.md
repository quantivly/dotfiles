# Tmux Learning Guide

A progressive guide to mastering your tmux setup. Organized by skill level so you can build muscle memory gradually.

> **Your setup**: Ctrl+Space prefix, Terminator-style navigation (Ctrl+Shift+Arrow/E/O), OSC 52 clipboard, tmux-resurrect + continuum, dark theme. See `examples/tmux-workflows.md` for the full reference.

## Level 1: The Basics (Day 1)

**Goal:** Start sessions, split panes, navigate, detach/reattach.

### Start and stop

```bash
tmn work          # Create a named session
tml               # List all sessions
tma work          # Reattach to a session
tmk work          # Kill a session
tms work          # Attach-or-create (idempotent)
```

### Split and navigate

| Action | Keys | Memory aid |
|--------|------|------------|
| Split vertical | `Ctrl+Shift+E` | No prefix needed! |
| Split horizontal | `Ctrl+Shift+O` | No prefix needed! |
| Navigate panes | `Ctrl+Shift+Arrow` | Terminator-style, no prefix |
| Close pane | `Ctrl+Space x` | x marks deletion |
| Detach | `Ctrl+Space d` | d for detach |

> **Vim alternative:** `Alt+h/j/k/l` also navigates panes. `Ctrl+Space |` and `Ctrl+Space -` also split.

### Exercise: First session

```
1. tmn practice
2. Ctrl+Shift+E            → you have 2 vertical panes
3. Ctrl+Shift+Left/Right   → bounce between them
4. Ctrl+Shift+O            → split the right pane horizontally
5. Ctrl+Shift+Up/Down      → navigate up/down
6. Ctrl+Space d            → detach
7. tml                     → see your session still running
8. tma practice            → everything is still there
9. tmk practice            → clean up
```

### What to internalize

- **Sessions persist.** Detaching doesn't kill anything. This is the core mental model.
- **Ctrl+Shift is your tmux modifier.** Splits and navigation are all prefix-free with Ctrl+Shift. Much faster than prefix-based shortcuts.
- **Splits inherit your current directory.** New panes open where you are, not where the session started.

## Level 2: Windows & Workflow (Week 1)

**Goal:** Use windows for different contexts, zoom panes, use the mouse.

### Windows = tabs

| Action | Keys | Memory aid |
|--------|------|------------|
| New window | `Ctrl+Space c` | c for create |
| Switch to window N | `Alt+1` through `Alt+9` | No prefix needed |
| Rename window | `Ctrl+Space ,` | Comma, then type name |
| Close window | `Ctrl+Space &` | Asks confirmation |
| Next/prev window | `Ctrl+Space n/p` | |
| Last window | `Ctrl+Space Tab` | Toggle back and forth |

### Zoom

Press `Ctrl+Space z` to make any pane fullscreen. Press again to restore. The status bar shows `[Z]` when zoomed.

**Use case:** You have a 3-pane layout. You need to focus on one pane for a few minutes. Zoom it, do your work, unzoom.

### Mouse

- **Click** a pane to focus it
- **Drag** borders to resize panes
- **Scroll wheel** to browse history
- **Double-click** to select a word, **triple-click** for a line

### Exercise: Multi-project setup

```
1. tmn projects
2. Ctrl+Space ,       → rename to "api"
3. (work on API here)
4. Ctrl+Space c       → new window
5. Ctrl+Space ,       → rename to "frontend"
6. Alt+1 / Alt+2      → switch between them
7. Ctrl+Space Tab     → toggle to last window (muscle memory!)
```

### The `tdev` function

Your dotfiles include a `tdev` command that creates a standard 3-pane dev layout:

```
┌─────────────────────────┐
│   Main editor (60%)     │
├───────────┬─────────────┤
│  Tests    │   Git/misc  │
└───────────┴─────────────┘
```

Usage:
```bash
tdev myproject ~/code/myproject
# Or just:
tdev    # Uses "dev" session in current directory
```

### What to internalize

- **Windows = different tasks.** One window for editing, one for tests, one for logs.
- **Alt+number is instant.** Switching windows should feel as fast as switching browser tabs.
- **Zoom replaces window switching** for quick focus. Faster than switching to a dedicated full-screen window.

## Level 3: Copy Mode & Clipboard (Week 2)

**Goal:** Search scrollback, copy text, use clipboard over SSH.

### Enter copy mode

Press `Ctrl+Space [`. You're now in a vim-like mode where you can navigate the scrollback buffer (50,000 lines of history).

### Navigate in copy mode

| Action | Keys |
|--------|------|
| Move cursor | `h/j/k/l` |
| Page up/down | `Ctrl+u / Ctrl+d` |
| Top/bottom of buffer | `gg / G` |
| Start/end of line | `0 / $` |
| Search forward | `/pattern` then `n/N` |
| Search backward | `?pattern` then `n/N` |
| Exit copy mode | `q` |

### Select and copy

```
1. Ctrl+Space [       → enter copy mode
2. Navigate to text you want
3. v                  → start selection (like vim visual mode)
4. Move to extend selection
5. y                  → yank (copy) and exit copy mode
6. Ctrl+Space ]       → paste
```

For rectangular selection: press `r` after starting visual mode with `v`.

### OSC 52: Clipboard over SSH

Your config has OSC 52 enabled. When you yank with `y` in copy mode, the text goes to your **local machine's clipboard** - even if you're SSH'd into a remote server inside tmux. This is seamless; no extra steps needed.

From the shell:
```bash
echo "some text" | osc52      # Copy to local clipboard
cat some-file.txt | osc52     # Copy file contents
```

### Exercise: Search and copy from scrollback

```
1. Run a few commands to generate output
2. Ctrl+Space [       → enter copy mode
3. /error             → search for "error" in scrollback
4. n                  → next match
5. 0                  → go to start of line
6. v                  → start selection
7. $                  → select to end of line
8. y                  → copy
9. Ctrl+Space ]       → paste into a pane
```

### What to internalize

- **Copy mode is your pager.** Instead of piping to `less`, just scroll up in copy mode.
- **Search works like vim.** `/pattern` then `n/N` to jump between matches.
- **OSC 52 is invisible.** You don't need to think about it - `y` just works, even over SSH.

## Level 4: Session Power User (Week 3-4)

**Goal:** Manage multiple sessions, resize panes, reorder windows, use resurrect.

### Session management

| Action | Keys / Command |
|--------|---------------|
| List sessions interactively | `Ctrl+Space s` |
| Switch to last session | `Ctrl+Space B` |
| Fuzzy session picker | `ftmux` (shell command) |

### `ftmux`: The fuzzy session manager

Your dotfiles include `ftmux` which uses fzf to manage sessions:

```bash
ftmux
# Enter     → attach to selected session
# Ctrl+K    → kill selected session
# Ctrl+N    → create new session
# Preview   → shows live pane content
```

### Resize panes

With prefix (repeatable - hold the key):

| Action | Keys |
|--------|------|
| Resize left | `Ctrl+Space H` |
| Resize down | `Ctrl+Space J` |
| Resize up | `Ctrl+Space K` |
| Resize right | `Ctrl+Space L` |

The `-r` flag means you can press prefix once, then tap H/J/K/L multiple times. Or just drag borders with the mouse.

### Reorder windows

| Action | Keys |
|--------|------|
| Move window left | `Ctrl+Space Shift+Left` |
| Move window right | `Ctrl+Space Shift+Right` |

### Swap panes

| Action | Keys |
|--------|------|
| Swap with next pane | `Ctrl+Space >` |
| Swap with previous pane | `Ctrl+Space <` |
| Break pane to new window | `Ctrl+Space !` |
| Cycle layouts | `Ctrl+Space Space` |

### Synchronized panes

Type the same command in all panes at once:

```
Ctrl+Space S    → toggle sync (status shows "Sync ON/OFF")
```

**Use case:** SSH'd into 4 servers in 4 panes. Run the same deployment command on all of them simultaneously.

### Save and restore sessions (Resurrect + Continuum)

Your sessions are **automatically saved every 15 minutes** by tmux-continuum. After a reboot:

```bash
tmux                          # Continuum auto-restores your last session layout
```

Manual controls:
```
Ctrl+Space Ctrl+s    → save sessions now (resurrect)
Ctrl+Space Ctrl+r    → restore sessions (resurrect)
```

What gets saved: window layouts, pane directories, pane contents, running programs (vim, less, etc.).

### Exercise: Multi-session workflow

```
1. tmn backend          → work on API
2. Ctrl+Shift+E        → split for tests
3. Ctrl+Space c         → new window for logs
4. Ctrl+Space d         → detach

5. tmn frontend         → separate session for frontend
6. Ctrl+Shift+E        → split

7. ftmux               → fuzzy switch between sessions
   (or Ctrl+Space s from inside tmux)

8. Ctrl+Space B        → toggle back to last session
```

## Level 5: Advanced Techniques

**Goal:** Scripted layouts, command mode, integration with your workflow.

### Scripted session layouts

Create repeatable development environments:

```bash
#!/bin/bash
# ~/bin/dev-layout.sh
SESSION="myproject"
DIR="$HOME/code/myproject"

tmux new-session -d -s $SESSION -c "$DIR" -n "editor"
tmux send-keys -t $SESSION "vim ." C-m

tmux new-window -t $SESSION -n "server" -c "$DIR"
tmux send-keys -t $SESSION "npm run dev" C-m

tmux new-window -t $SESSION -n "test" -c "$DIR"
tmux split-window -h -t $SESSION -c "$DIR"
tmux send-keys -t $SESSION:3.1 "npm test -- --watch" C-m
tmux send-keys -t $SESSION:3.2 "git log --oneline -20" C-m

tmux select-window -t $SESSION:1
tmux attach-session -t $SESSION
```

### Command mode

Press `Ctrl+Space :` to enter command mode. Useful commands:

```
:list-keys                  # All keybindings
:show-options -g            # All settings
:display-panes              # Show pane numbers
:join-pane -s 2             # Pull window 2 into current as a pane
:move-window -t othersession  # Move window to another session
:select-layout tiled        # Apply tiled layout
```

### Pipe pane output to a file

```
:pipe-pane -o 'cat >> ~/tmux-log.txt'   # Start logging
:pipe-pane                               # Stop logging
```

### Monitor for silence or content

```
:setw monitor-silence 30     # Alert if pane is silent for 30s
:setw monitor-activity on    # Alert on any output (already enabled)
```

Useful for long-running builds: go work in another window, get notified when it finishes (silence) or fails (output).

### Integration with your dotfiles

Your setup has these tmux integrations built in:

| Feature | What it does |
|---------|-------------|
| SSH agent persistence | `SSH_AUTH_SOCK` always works in new panes, even after reconnecting |
| `osc52()` | Copy to local clipboard from any pane, even over SSH |
| `tdev` | Create standard 3-pane dev layout with one command |
| `ftmux` | Fuzzy session picker with fzf |
| Shell aliases | `tm`, `tma`, `tmn`, `tml`, `tms`, `tmk`, `tmka` |
| `tmux_help` | Quick reference from the shell |
| Auto-save | Continuum saves sessions every 15 minutes |

## Keybinding Cheat Sheet

### No prefix needed (instant)

| Keys | Action |
|------|--------|
| `Ctrl+Shift+E` | Split vertical |
| `Ctrl+Shift+O` | Split horizontal |
| `Ctrl+Shift+Arrow` | Navigate panes |
| `Alt+h/j/k/l` | Navigate panes (vim alternative) |
| `Alt+1-9` | Switch to window N |

### With prefix (Ctrl+Space, then...)

| Key | Action | Category |
|-----|--------|----------|
| `\|` | Split vertical (alternative) | Panes |
| `-` | Split horizontal (alternative) | Panes |
| `x` | Close pane | Panes |
| `z` | Zoom/unzoom pane | Panes |
| `H/J/K/L` | Resize pane (repeat) | Panes |
| `>` / `<` | Swap pane down/up | Panes |
| `S` | Toggle synchronized panes | Panes |
| `!` | Break pane to window | Panes |
| `c` | New window | Windows |
| `,` | Rename window | Windows |
| `&` | Close window | Windows |
| `n/p` | Next/prev window | Windows |
| `Tab` | Last window | Windows |
| `BSpace` | Last pane | Windows |
| `Shift+Left/Right` | Reorder window | Windows |
| `[` | Enter copy mode | Copy |
| `]` | Paste | Copy |
| `d` | Detach | Sessions |
| `s` | Session picker | Sessions |
| `B` | Last session | Sessions |
| `r` | Reload config | Config |
| `?` | Show all keybindings | Help |
| `Ctrl+s` | Save sessions (resurrect) | Plugins |
| `Ctrl+r` | Restore sessions (resurrect) | Plugins |
| `I` | Install plugins (TPM) | Plugins |
| `U` | Update plugins (TPM) | Plugins |

### In copy mode

| Key | Action |
|-----|--------|
| `h/j/k/l` | Move cursor |
| `v` | Start selection |
| `r` | Toggle rectangle selection |
| `y` | Copy and exit |
| `/` / `?` | Search forward/backward |
| `n` / `N` | Next/prev match |
| `gg` / `G` | Top/bottom of buffer |
| `0` / `$` | Start/end of line |
| `Ctrl+u/d` | Page up/down |
| `q` | Exit copy mode |

## Shell Aliases Reference

```bash
tm                 # tmux
tma <name>         # Attach to session
tmn <name>         # New session
tml                # List sessions
tms <name>         # Attach-or-create (idempotent)
tmk <name>         # Kill session
tmka               # Kill all sessions except current
tdev [name] [dir]  # Create 3-pane dev layout
ftmux              # Fuzzy session picker (fzf)
tmux_help          # Quick reference card
```

## Troubleshooting

### After config changes
```bash
# Reload from inside tmux:
Ctrl+Space r

# Or from shell:
tmux source-file ~/.tmux.conf
```

### After adding new plugins
```bash
# Inside tmux:
Ctrl+Space I       # TPM installs new plugins
```

### Session not restoring after reboot
```bash
# Manual restore:
Ctrl+Space Ctrl+r

# Check resurrect saved files:
ls ~/.tmux/resurrect/
```

### Ctrl+Shift+E/O not working
Ctrl+Shift+**letter** bindings require two things:
1. **Alacritty key bindings** in `~/.config/alacritty/alacritty.toml` that send CSI u sequences (e.g., `\x1b[101;6u` for E)
2. **tmux extended-keys** enabled with `terminal-features` matching your `$TERM` (usually `xterm-256color`, not `alacritty`)

Ctrl+Shift+**Arrow** works natively without either — different encoding mechanism.

After changing `extended-keys` or `terminal-features`, you must restart the tmux server (`tmux kill-server`), not just reload config.

### Alt key not working
This is a terminal setting, not tmux:
- **iTerm2**: Preferences > Profiles > Keys > Left Option Key > "Esc+"
- **GNOME Terminal**: Usually works by default
- **VS Code terminal**: Usually works by default

### Colors look wrong
```bash
echo $TERM         # Should be: tmux-256color (inside tmux)
echo $COLORTERM    # Should be: truecolor (outside tmux)
```

## See Also

- `examples/tmux-workflows.md` - Full workflow reference with visual diagrams
- `tmux_help` - Quick reference from the shell
- `Ctrl+Space ?` - All keybindings inside tmux
- `man tmux` - Official manual
