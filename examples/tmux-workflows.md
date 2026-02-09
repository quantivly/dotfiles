# Tmux Workflows and Examples

Comprehensive guide to using tmux for terminal multiplexing and session management.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Session Management](#session-management)
- [Pane Management](#pane-management)
- [Window Management](#window-management)
- [Copy Mode](#copy-mode)
- [Common Workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)
- [Advanced Tips](#advanced-tips)

## Quick Reference

| Category | Command | Description |
|----------|---------|-------------|
| **Start/Stop** | `tmn mysession` | Create new named session |
| | `tma mysession` | Attach to existing session |
| | `tml` | List all sessions |
| | `tmux kill-session -t name` | Kill a specific session |
| **Splits** | `Ctrl+Shift+E` | Split vertically (no prefix!) |
| | `Ctrl+Shift+O` | Split horizontally (no prefix!) |
| | `Ctrl+Shift+Arrow` | Navigate panes (no prefix!) |
| | `Ctrl+Shift+W` | Close pane (no prefix!) |
| | `Ctrl+Alt+Arrow` | Resize panes (no prefix!) |
| | `Alt+z` | Zoom pane toggle (no prefix!) |
| | `Alt+h/j/k/l` | Navigate panes (vim alternative) |
| **Windows** | `Ctrl+Shift+T` | New window (no prefix!) |
| | `Ctrl+PageUp/Down` | Next/previous window (no prefix!) |
| | `Ctrl+Shift+PageUp/Down` | Reorder windows (no prefix!) |
| | `Alt+1-9` | Switch to window 1-9 |
| | `Ctrl+Space ,` | Rename current window |
| **Sessions** | `Ctrl+Shift+S` | Switch sessions (no prefix!) |
| | `Ctrl+Space s` | Session picker (with prefix) |
| | `Ctrl+Space d` | Detach (session keeps running) |
| **Copy** | `Ctrl+Space [` | Enter copy mode |
| | `v` | Start selection (vim-style) |
| | `y` | Copy selection and exit |
| | `Ctrl+Space ]` | Paste |
| **Misc** | `Ctrl+Space ?` | Show all keybindings |
| | `Ctrl+Space r` | Reload config |

## Session Management

### Starting Sessions

```bash
# Create a new named session
tmn work
tmn personal
tmn myproject

# Start with a specific directory
tmux new -s project -c ~/code/myproject

# Start with a specific command
tmux new -s logs "tail -f /var/log/syslog"
```

### Attaching to Sessions

```bash
# Attach to a specific session
tma work

# Attach to most recent session
tmux attach

# Attach and detach other clients (force exclusive access)
tmux attach -t work -d
```

### Listing and Switching Sessions

```bash
# List all sessions
tml
# or
tmux list-sessions

# Switch to another session (while inside tmux)
Ctrl+Shift+S      # Interactive session tree (no prefix!)
# Ctrl+Space s    # Interactive session list (with prefix)

# Switch to specific session by name
tmux switch-client -t othersession
```

### Killing Sessions

```bash
# Kill a specific session
tmux kill-session -t work

# Kill all sessions except current
tmux kill-session -a

# Kill all sessions
tmux kill-server
```

**Important:** Sessions persist after detaching! Use `tml` to see what's running and kill sessions you don't need.

## Pane Management

### Creating Panes (Splits)

```bash
# Inside tmux:
Ctrl+Space |  # Split vertically (left/right)
Ctrl+Space -  # Split horizontally (top/bottom)
```

All splits open in the **current pane's directory** (not the session's starting directory).

### Navigating Panes

```bash
# Vim-style navigation (NO PREFIX NEEDED!)
Alt+h  # Move left
Alt+j  # Move down
Alt+k  # Move up
Alt+l  # Move right

# Or with prefix (traditional)
Ctrl+Space ←/↓/↑/→  # Arrow keys
```

### Resizing Panes

```bash
# No prefix needed! (2 cells per press)
Ctrl+Alt+Left   # Resize left
Ctrl+Alt+Down   # Resize down
Ctrl+Alt+Up     # Resize up
Ctrl+Alt+Right  # Resize right

# With prefix (5 cells, repeatable - tap H/J/K/L multiple times)
Ctrl+Space Shift+H  # Resize left
Ctrl+Space Shift+J  # Resize down
Ctrl+Space Shift+K  # Resize up
Ctrl+Space Shift+L  # Resize right

# Or drag borders with mouse
```

### Closing Panes

```bash
# Close current pane (no prefix needed!)
Ctrl+Shift+W  # Prompts for confirmation
# or
exit          # No confirmation
# or
Ctrl+d        # No confirmation
```

### Zooming Panes

```bash
# Toggle fullscreen for current pane (no prefix needed!)
Alt+z

# Zoomed pane shows [Z] indicator in status bar
# Press Alt+z again to restore layout
```

## Window Management

### Creating Windows

```bash
# Create new window (no prefix needed!)
Ctrl+Shift+T

# Create with specific name
Ctrl+Shift+T
Ctrl+Space ,  # Then type new name

# Create with command
tmux new-window -n logs "tail -f /var/log/syslog"
```

### Navigating Windows

```bash
# Quick window switching (NO PREFIX NEEDED!)
Alt+1  # Switch to window 1
Alt+2  # Switch to window 2
Alt+3  # Switch to window 3
Alt+4  # Switch to window 4
Alt+5  # Switch to window 5

# Next/previous window (NO PREFIX NEEDED! Like browser tab switching)
Ctrl+PageDown  # Next window
Ctrl+PageUp    # Previous window

# Reorder windows (NO PREFIX NEEDED! Like browser tab reordering)
Ctrl+Shift+PageDown  # Move window right
Ctrl+Shift+PageUp    # Move window left

# Or with prefix
Ctrl+Space 0-9  # Switch to window 0-9
Ctrl+Space l    # Last used window

# Interactive window list
Ctrl+Space w
```

### Renaming Windows

```bash
# Rename current window
Ctrl+Space ,
# Type new name and press Enter

# Rename from shell
tmux rename-window newname
```

### Closing Windows

```bash
# Close current window
Ctrl+Space &  # Prompts for confirmation
# or
exit          # Close last pane in window
```

## Copy Mode

Tmux copy mode uses **vim keybindings** for navigation and selection.

### Entering Copy Mode

```bash
# Enter copy mode
Ctrl+Space [

# Now you can:
# - Navigate with vim keys: h/j/k/l, w/b, gg/G, etc.
# - Scroll with mouse wheel
# - Search: / (forward), ? (backward)
```

### Selecting and Copying

```bash
# In copy mode:
v       # Start selection (vim visual mode)
y       # Copy selection and exit copy mode

# Alternative: Use mouse
# - Click and drag to select
# - Selection is automatically copied when you release

# Rectangle selection
v       # Start selection
r       # Toggle rectangle mode
y       # Copy
```

### Pasting

```bash
# Paste most recent buffer
Ctrl+Space ]

# List all buffers
Ctrl+Space =
# Then select buffer to paste
```

### Copy Mode Navigation

```bash
# In copy mode:
h/j/k/l       # Move cursor
w/b           # Next/previous word
0/$           # Start/end of line
gg/G          # Top/bottom of buffer
Ctrl+d/Ctrl+u # Page down/up
/pattern      # Search forward
?pattern      # Search backward
n/N           # Next/previous match
q             # Exit copy mode
```

### OSC 52 Clipboard Integration

Tmux integrates with your local clipboard via OSC 52 (works over SSH!):

```bash
# Copy from shell to local clipboard
echo "text to copy" | osc52

# Copy file contents
cat file.txt | osc52

# In tmux copy mode, 'y' automatically uses OSC 52
# So copied text appears in your local clipboard!
```

See `zsh/functions/core.sh:osc52()` for implementation details.

## Common Workflows

### Development Layout

Create a 3-pane layout for development:

```bash
# Start session
tmn dev

# Split horizontally (editor on top, terminal on bottom)
Ctrl+Space -

# Split bottom pane vertically (two terminals side by side)
Alt+j  # Move to bottom pane
Ctrl+Space |

# Navigate to top pane and start editor
Alt+k
vim myfile.py

# Bottom-left: run tests
Alt+j
pytest --watch

# Bottom-right: git status
Alt+l
git status
```

**Result:**
```
┌─────────────────────────┐
│   Editor (vim)          │
├───────────┬─────────────┤
│  Tests    │   Git       │
└───────────┴─────────────┘
```

### Multiple Projects

Use one session per project:

```bash
# Create project sessions
tmn api-backend
tmn frontend
tmn database

# Switch between them
Ctrl+Space s  # Interactive list

# Or detach and attach
Ctrl+Space d
tma frontend
```

### Remote Development (SSH)

Tmux is perfect for SSH sessions - your work persists if you disconnect:

```bash
# On remote server
ssh user@server
tmn work

# Do work...
# Connection drops? No problem!

# Reconnect and resume
ssh user@server
tma work  # Everything is still there!
```

### Pair Programming

Share a tmux session with another user:

```bash
# User 1: Start session
tmn pairing

# User 2: Attach to same session
tmux attach -t pairing

# Both users see the same screen
# Both can type and control tmux
# Great for remote pair programming!
```

### Monitoring Multiple Logs

```bash
# Start session
tmn logs

# Create windows for different logs
Ctrl+Space c
tmux rename-window "API logs"
tail -f /var/log/api.log

Ctrl+Space c
tmux rename-window "Database"
tail -f /var/log/postgresql.log

Ctrl+Space c
tmux rename-window "Nginx"
tail -f /var/log/nginx/access.log

# Switch between logs with Alt+1, Alt+2, Alt+3
```

### Long-Running Tasks

Perfect for builds, downloads, or deployments:

```bash
# Start session and run task
tmn build
./long-running-build.sh

# Detach and let it run
Ctrl+Space d

# Check on it later
tma build
```

## Troubleshooting

### Colors Look Wrong

**Problem:** Colors are washed out or broken in tmux.

**Solution:**
```bash
# Check COLORTERM outside tmux
echo $COLORTERM
# Should be: truecolor

# Check TERM inside tmux
echo $TERM
# Should be: screen-256color or tmux-256color

# If wrong, reload zsh config
source ~/.zshrc

# Or restart tmux
tmux kill-server
tmn test
```

The dotfiles automatically set `COLORTERM=truecolor` in `zsh/zshrc.terminal`.

### Prefix Not Working

**Problem:** Ctrl+Space doesn't work as prefix.

**Solution:**
```bash
# Check if config is loaded
Ctrl+Space r  # Try to reload config

# If that doesn't work, check config
cat ~/.tmux.conf | grep "prefix"
# Should see: set -g prefix C-Space

# Verify symlink
ls -la ~/.tmux.conf
# Should point to: ~/.dotfiles/tmux.conf

# Re-run installer
cd ~/.dotfiles
./install

# Kill tmux and restart
tmux kill-server
tmn test
```

### Clipboard Not Working Over SSH

**Problem:** Copy mode doesn't copy to local clipboard.

**Solution:**

1. **Check OSC 52 support:** Your terminal must support OSC 52 (most modern terminals do: iTerm2, WezTerm, Alacritty, Windows Terminal, etc.)

2. **Test OSC 52 directly:**
   ```bash
   echo "test" | osc52
   # Should copy "test" to your local clipboard
   ```

3. **Check tmux config:**
   ```bash
   tmux show-options -g set-clipboard
   # Should be: on
   ```

4. **If still not working:**
   - Some SSH configurations block OSC 52
   - Try: `ssh -o "SetEnv TERM=xterm-256color" user@host`
   - Or add to `~/.ssh/config`: `SetEnv TERM=xterm-256color`

### Mouse Not Working

**Problem:** Can't click panes or drag borders.

**Solution:**
```bash
# Check mouse setting
tmux show-options -g mouse
# Should be: on

# If off, enable it
tmux set-option -g mouse on

# Or add to ~/.tmux.conf and reload
Ctrl+Space r
```

### Ctrl+Alt+Arrow (Resize) Not Working

**Problem:** Ctrl+Alt+Arrow doesn't resize panes.

**Solution:**

GNOME intercepts Ctrl+Alt+Arrow for workspace switching. Remove those defaults (your Super+PgUp/PgDown shortcuts are unaffected):

```bash
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-up "['<Super>Page_Up']"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-down "['<Super>Page_Down']"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-left "['<Super><Alt>Left']"
gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-right "['<Super><Alt>Right']"
```

Changes take effect immediately — no logout needed.

### Alt Key Not Working

**Problem:** Alt+h/j/k/l don't navigate panes.

**Solution:**

This is usually a terminal configuration issue, not tmux:

1. **Terminal.app (macOS):** Preferences → Profiles → Keyboard → "Use Option as Meta key"

2. **iTerm2 (macOS):** Preferences → Profiles → Keys → Left/Right Option Key → "Esc+"

3. **GNOME Terminal (Linux):** Usually works by default

4. **Test Alt key:**
   ```bash
   # Press Alt+h
   # Should navigate to left pane

   # If it doesn't work, use prefix navigation instead
   Ctrl+Space ←
   ```

### Panes Not Synchronized

**Problem:** Want to type in all panes at once (not covered in basic config).

**Solution:**
```bash
# Temporarily enable synchronize-panes
tmux setw synchronize-panes on

# Type commands (appears in all panes!)

# Disable when done
tmux setw synchronize-panes off

# Or toggle with a keybinding (add to ~/.tmux.conf):
# bind S setw synchronize-panes
```

## Advanced Tips

### Synchronize Panes

Type the same command in all panes simultaneously:

```bash
# Enable synchronization
tmux setw synchronize-panes on

# Now typing appears in ALL panes
# Great for: Running same command on multiple servers

# Disable when done
tmux setw synchronize-panes off
```

**Add keybinding:** Edit `~/.tmux.conf`:
```conf
bind S setw synchronize-panes
```

Then: `Ctrl+Space S` to toggle sync.

### Swap Panes

```bash
# Rotate panes clockwise
Ctrl+Space Ctrl+o

# Swap current pane with next pane
Ctrl+Space }

# Swap current pane with previous pane
Ctrl+Space {
```

### Break Pane into New Window

```bash
# Move current pane to its own window
Ctrl+Space !

# Pane becomes window in same session
```

### Join Pane from Another Window

```bash
# Join window 2 as a pane in current window
tmux join-pane -s 2

# Join specific pane from window 2
tmux join-pane -s 2.1  # Window 2, pane 1
```

### Custom Layouts

```bash
# Cycle through preset layouts
Ctrl+Space Space

# Available layouts:
# - even-horizontal
# - even-vertical
# - main-horizontal
# - main-vertical
# - tiled

# Or set specific layout
tmux select-layout main-vertical
```

### Scripted Session Setup

Create a script to launch your development environment:

```bash
#!/bin/bash
# ~/bin/dev-session.sh

SESSION="dev"

# Create session and first window
tmux new-session -d -s $SESSION -n "editor"
tmux send-keys -t $SESSION "cd ~/code/myproject && vim" C-m

# Create second window for tests
tmux new-window -t $SESSION -n "tests"
tmux send-keys -t $SESSION "cd ~/code/myproject && pytest --watch" C-m

# Create third window split for git and logs
tmux new-window -t $SESSION -n "git"
tmux send-keys -t $SESSION "cd ~/code/myproject && git status" C-m
tmux split-window -h -t $SESSION
tmux send-keys -t $SESSION "cd ~/code/myproject && tail -f logs/dev.log" C-m

# Return to first window and attach
tmux select-window -t $SESSION:1
tmux attach-session -t $SESSION
```

Usage:
```bash
chmod +x ~/bin/dev-session.sh
~/bin/dev-session.sh
```

### Save and Restore Sessions

**Note:** This requires [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) plugin (not included in basic config).

Basic manual approach:

```bash
# Save layout to file
tmux list-windows -a -F "#{session_name}:#{window_index} #{window_layout}" > ~/.tmux-layout.txt

# Restore manually (create windows/panes as needed)
# Then apply layout:
tmux select-layout "$(cat ~/.tmux-layout.txt | grep "session:window" | cut -d' ' -f2)"
```

For automated save/restore, consider adding TPM and tmux-resurrect plugin later.

### Command History

```bash
# Show command history
Ctrl+Space :  # Enter command mode

# Previous commands
Up/Down arrows

# Useful commands:
:list-keys        # Show all keybindings
:list-commands    # Show all commands
:show-options -g  # Show all options
```

## See Also

- **Quick help:** `help tmux` (in zsh)
- **All keybindings:** `Ctrl+Space ?` (inside tmux)
- **Config file:** `~/.tmux.conf`
- **Official docs:** `man tmux`
- **Online manual:** https://tmux.github.io/

## Tips for Beginners

1. **Start simple:** Use `tmn`, split a few panes, detach/attach. That's 80% of what you need!

2. **Learn gradually:** Don't try to memorize everything. Use `Ctrl+Space ?` to look up keybindings.

3. **Mouse is your friend:** When starting out, use the mouse! Click panes, drag borders, scroll. The keybindings can come later.

4. **One session per project:** It's easier to manage sessions when they're focused on specific tasks.

5. **Detach often:** Get comfortable detaching (Ctrl+Space d). Your work is safe and waiting for you!

6. **Name your sessions:** `tmn backend` is clearer than `tmux new`. Use descriptive names.

7. **Kill old sessions:** Use `tml` regularly to see what's running. Kill sessions you don't need anymore.

8. **Zoom is powerful:** When focusing on one pane, zoom it (Ctrl+Space z). Zoom again to restore.

9. **Alt navigation:** Once you learn Alt+hjkl for pane navigation, you'll never go back. No prefix needed!

10. **Read examples:** The "Common Workflows" section above shows realistic usage patterns. Try them!

## Quick Start for Complete Beginners

If this is your first time using tmux:

```bash
# 1. Start a session
tmn practice

# 2. Split horizontally
Ctrl+Space -

# 3. Move to bottom pane
Alt+j

# 4. Split vertically
Ctrl+Space |

# 5. Navigate around
Alt+h  # left
Alt+j  # down
Alt+k  # up
Alt+l  # right

# 6. Detach (session keeps running)
Ctrl+Space d

# 7. Check sessions
tml

# 8. Reattach
tma practice

# 9. Everything is still there!

# 10. When done, kill session
tmux kill-session -t practice
```

Congratulations! You now know the basics of tmux. Everything else builds on these fundamentals.
