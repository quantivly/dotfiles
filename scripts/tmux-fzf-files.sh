#!/usr/bin/env bash
# =============================================================================
# tmux-fzf-files.sh — Fuzzy file finder for tmux popup
# =============================================================================
# Launched by tmux display-popup. Finds files with fzf + bat preview.
#
# Usage: tmux-fzf-files.sh <pane_id>
#   <pane_id>  The tmux pane to send commands back to (for Ctrl+O)
#
# Keys:
#   Enter   — Open file in vim (inside the popup)
#   Ctrl+O  — Send "$EDITOR <file>" to the originating pane
# =============================================================================

set -euo pipefail

PANE_ID="${1:-}"

# ---------------------------------------------------------------------------
# Tool detection (same fallback logic as zshrc.conditionals.tools)
# ---------------------------------------------------------------------------
FD_CMD=""
if command -v fd &>/dev/null; then
    FD_CMD="fd"
elif command -v fdfind &>/dev/null; then
    FD_CMD="fdfind"
fi

BAT_CMD=""
if command -v bat &>/dev/null; then
    BAT_CMD="bat"
elif command -v batcat &>/dev/null; then
    BAT_CMD="batcat"
fi

# ---------------------------------------------------------------------------
# Build fzf command
# ---------------------------------------------------------------------------

# File listing command
if [[ -n "$FD_CMD" ]]; then
    FILE_CMD="$FD_CMD --type f --hidden --follow --exclude .git"
else
    FILE_CMD="find . -type f -not -path '*/.git/*'"
fi

# Preview command
if [[ -n "$BAT_CMD" ]]; then
    PREVIEW="$BAT_CMD --color=always --style=numbers --line-range=:500 {}"
else
    PREVIEW="head -500 {}"
fi

# ---------------------------------------------------------------------------
# Run fzf
# ---------------------------------------------------------------------------
RESULT=$(eval "$FILE_CMD" | fzf \
    --expect=ctrl-o \
    --preview "$PREVIEW" \
    --preview-window 'right:60%' \
    --header 'Enter=edit in popup │ Ctrl+O=open in pane' \
    --border \
    --bind 'ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up' \
) || exit 0  # User pressed Escape

# Parse fzf output: first line is the key pressed, second line is the selection
KEY=$(head -1 <<< "$RESULT")
FILE=$(tail -1 <<< "$RESULT")

[[ -z "$FILE" ]] && exit 0

if [[ "$KEY" == "ctrl-o" && -n "$PANE_ID" ]]; then
    # Send open command to the originating pane
    EDITOR_CMD="${EDITOR:-vim}"
    tmux send-keys -t "$PANE_ID" "$EDITOR_CMD $(printf '%q' "$FILE")" Enter
else
    # Open in vim inside the popup
    POPUP_EDITOR="${TMUX_EDITOR:-vim}"
    exec "$POPUP_EDITOR" "$FILE"
fi
