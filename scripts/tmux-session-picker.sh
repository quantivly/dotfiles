#!/usr/bin/env bash
# =============================================================================
# tmux-session-picker.sh — Switch or create tmux sessions via fzf
# =============================================================================
# Launched by tmux display-popup (Ctrl+Shift+S).
# Lists existing sessions with metadata (window count, age, attached status).
# Type a new name to create a session.
#
# Keys:
#   Enter      Switch to selected session, or create if name is new
#   Esc        Cancel
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build session list: name<TAB>  name · Nw · age [· attached]
now=$(date +%s)
session_list=$(
  tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{session_activity}' 2>/dev/null |
  while IFS='|' read -r name wins attached activity; do
    # Relative time from last activity
    diff=$((now - activity))
    if [ "$diff" -lt 60 ]; then
      age="${diff}s"
    elif [ "$diff" -lt 3600 ]; then
      age="$((diff / 60))m"
    elif [ "$diff" -lt 86400 ]; then
      age="$((diff / 3600))h"
    elif [ "$diff" -lt 604800 ]; then
      age="$((diff / 86400))d"
    else
      age="$((diff / 604800))w"
    fi

    # Display: name in default color, metadata in grey
    meta="\033[90m· ${wins}w · ${age}"
    [ "$attached" -gt 0 ] && meta="${meta} · attached"
    meta="${meta}\033[0m"

    printf '%s\t  %s %b\n' "$name" "$name" "$meta"
  done
)

[ -z "$session_list" ] && exit 0

selected=$(
  echo "$session_list" |
  fzf --delimiter=$'\t' \
      --with-nth=2.. \
      --nth=1 \
      --accept-nth=1 \
      --print-query \
      --ansi \
      --no-sort \
      --height=100% \
      --layout=reverse \
      --highlight-line \
      --pointer='▸' \
      --border=rounded \
      --border-label=' Sessions ' \
      --header='  Select session or type new name' \
      --preview="$SCRIPT_DIR/tmux-session-preview.sh {1}" \
      --preview-window=down:75%:border-top \
      --preview-label=' Preview ' \
      --color='bg+:236,fg+:39:bold,pointer:39,border:244,header:244,prompt:39,label:39:bold' |
  tail -1 |
  cut -f1
)

[ -z "$selected" ] && exit 0

if tmux has-session -t "$selected" 2>/dev/null; then
  tmux switch-client -t "$selected"
else
  tmux new-session -d -s "$selected" && tmux switch-client -t "$selected"
fi
