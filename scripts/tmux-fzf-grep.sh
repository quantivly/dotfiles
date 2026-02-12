#!/usr/bin/env bash
# =============================================================================
# tmux-fzf-grep.sh — Live ripgrep search for tmux popup
# =============================================================================
# Launched by tmux display-popup. Live-reloads ripgrep as you type.
#
# Usage: tmux-fzf-grep.sh <pane_id>
#   <pane_id>  The tmux pane to send commands back to (for Ctrl+O)
#
# Requires: ripgrep (rg)
#
# Keys:
#   Enter   — Open file at matching line in vim (inside the popup)
#   Ctrl+O  — Send "$EDITOR +line <file>" to the originating pane
# =============================================================================

set -euo pipefail

PANE_ID="${1:-}"

# ---------------------------------------------------------------------------
# Require ripgrep
# ---------------------------------------------------------------------------
if ! command -v rg &>/dev/null; then
    echo "ripgrep (rg) is required for content search."
    echo "Install: apt install ripgrep  OR  mise use -g ripgrep@latest"
    read -r -p "Press Enter to close..."
    exit 1
fi

# ---------------------------------------------------------------------------
# Tool detection
# ---------------------------------------------------------------------------
BAT_CMD=""
if command -v bat &>/dev/null; then
    BAT_CMD="bat"
elif command -v batcat &>/dev/null; then
    BAT_CMD="batcat"
fi

# ---------------------------------------------------------------------------
# Build preview command
# ---------------------------------------------------------------------------
if [[ -n "$BAT_CMD" ]]; then
    # Preview: bat with line highlighting at the match
    PREVIEW="$BAT_CMD --color=always --style=numbers --highlight-line {2} {1}"
else
    PREVIEW="head -500 {1}"
fi

# ---------------------------------------------------------------------------
# Run fzf with live ripgrep reload
# ---------------------------------------------------------------------------
# --disabled: don't filter internally, let rg do the searching
# change:reload: re-run rg on every keystroke
RESULT=$(: | fzf \
    --expect=ctrl-o \
    --disabled \
    --ansi \
    --delimiter ':' \
    --bind "change:reload:rg --line-number --no-heading --color=always --smart-case -- {q} || true" \
    --preview "$PREVIEW" \
    --preview-window 'right:60%:+{2}/2' \
    --header 'Type to search │ Enter=edit in popup │ Ctrl+O=open in pane' \
    --border \
    --bind 'ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up' \
) || exit 0  # User pressed Escape

# Parse fzf output
KEY=$(head -1 <<< "$RESULT")
LINE=$(tail -1 <<< "$RESULT")

[[ -z "$LINE" ]] && exit 0

# Extract file and line number from rg output (file:line:content)
FILE=$(cut -d: -f1 <<< "$LINE")
LINE_NUM=$(cut -d: -f2 <<< "$LINE")

[[ -z "$FILE" ]] && exit 0

if [[ "$KEY" == "ctrl-o" && -n "$PANE_ID" ]]; then
    # Send open command to the originating pane
    EDITOR_CMD="${EDITOR:-vim}"
    tmux send-keys -t "$PANE_ID" "$EDITOR_CMD +$LINE_NUM $(printf '%q' "$FILE")" Enter
else
    # Open in vim inside the popup at the matching line
    POPUP_EDITOR="${TMUX_EDITOR:-vim}"
    exec "$POPUP_EDITOR" "+$LINE_NUM" "$FILE"
fi
