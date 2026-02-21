#!/usr/bin/env bash
# Opens files from Yazi sidebar in a Neovim tmux pane.
# - First call: creates a new pane with nvim --listen
# - Subsequent calls: sends files to existing instance via --remote

FILE="$1"
[ -z "$FILE" ] && exit 1

# Socket unique per tmux session+window (allows multiple sidebar instances)
SOCKET="/tmp/nvim-yazi-$(tmux display-message -p '#{session_name}-#{window_index}').sock"

# Detect existing Neovim pane in current window
panes=$(tmux list-panes -F "#{pane_id} #{pane_current_command}")
nvim_pane=$(echo "$panes" | grep " nvim$" | head -1 | cut -d" " -f1)

if [ -n "$nvim_pane" ] && [ -S "$SOCKET" ]; then
  # Verify socket is live (nvim might have crashed)
  if nvim --server "$SOCKET" --remote-expr 'v:true' 2>/dev/null; then
    nvim --server "$SOCKET" --remote "$FILE"
    tmux select-pane -t "$nvim_pane"
    exit 0
  fi
  # Stale socket — clean up and fall through to create new instance
  rm -f "$SOCKET"
fi

# Find the first non-yazi pane (the "main" pane) to split
target=$(echo "$panes" | grep -v " yazi$" | head -1 | cut -d" " -f1)

if [ -n "$target" ]; then
  # Split the main pane: Neovim on top (80%), terminal shrinks to bottom (20%)
  tmux split-window -v -b -t "$target" -l 80% \
    "nvim --listen '$SOCKET' '$FILE'"
else
  # Fallback: no other pane exists, create full-height split from Yazi
  tmux split-window -fh "nvim --listen '$SOCKET' '$FILE'"
fi
