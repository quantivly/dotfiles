#!/usr/bin/env bash
# =============================================================================
# tmux-session-preview.sh — Render a tmux session preview for fzf
# =============================================================================
# Shows choose-tree-style thumbnail boxes for each window in a 2-column grid.
# Each box has a bordered label and a snapshot from the active pane's bottom.
#
# Usage: tmux-session-preview.sh <session_name>
# Environment: FZF_PREVIEW_LINES, FZF_PREVIEW_COLUMNS (set by fzf)
# =============================================================================

session=$1
cols=${FZF_PREVIEW_COLUMNS:-80}
lines=${FZF_PREVIEW_LINES:-30}

if ! tmux has-session -t "$session" 2>/dev/null; then
  echo "  New session: $session"
  exit 0
fi

# --- Gather session data ---

win_data=$(tmux list-windows -t "$session" \
  -F '#{window_index}|#{window_name}|#{?window_active,1,0}|#{window_panes}' 2>/dev/null)
win_count=$(echo "$win_data" | wc -l)

attached=$(tmux list-sessions -F '#{session_name}|#{session_attached}' 2>/dev/null |
  awk -F'|' -v s="$session" '$1==s{print $2}')
att_str=""
[ "$attached" -gt 0 ] 2>/dev/null && att_str=" · attached"

# --- Header ---

printf "\033[1;36m ── %s ──\033[0m \033[38;5;244m%d windows%s\033[0m\n" \
  "$session" "$win_count" "$att_str"

# --- Grid layout ---

grid_cols=2
[ "$win_count" -le 1 ] && grid_cols=1
[ "$cols" -lt 50 ] && grid_cols=1

grid_rows=$(( (win_count + grid_cols - 1) / grid_cols ))
gap=2

box_width=$(( (cols - gap * (grid_cols - 1)) / grid_cols ))
inner_w=$((box_width - 2))  # minus │ left + │ right
[ "$inner_w" -lt 10 ] && inner_w=10

avail_h=$((lines - 1))  # minus header
box_height=$((avail_h / grid_rows))
inner_h=$((box_height - 2))  # minus top/bottom borders
[ "$inner_h" -lt 1 ] && inner_h=1

# --- Capture all windows ---

declare -a win_lines   # win_lines[i] = captured text (newline-separated)
declare -a win_label
declare -a win_is_active

i=0
while IFS='|' read -r idx name active pane_count; do
  # Build label
  lbl="${idx}: ${name}"
  [ "$active" = "1" ] && lbl="${lbl} *"
  [ "$pane_count" -gt 1 ] 2>/dev/null && lbl="${lbl} (${pane_count}p)"
  win_label[$i]="$lbl"
  win_is_active[$i]="$active"

  # Get active pane (or first pane)
  pid=$(tmux list-panes -t "${session}:${idx}" \
    -F '#{?pane_active,#{pane_id},}' 2>/dev/null | command grep .)
  [ -z "$pid" ] && pid=$(tmux list-panes -t "${session}:${idx}" \
    -F '#{pane_id}' 2>/dev/null | head -1)

  # Capture plain text (no ANSI), strip trailing blanks, take bottom lines
  if [ -n "$pid" ]; then
    win_lines[$i]=$(tmux capture-pane -J -t "$pid" -p 2>/dev/null | \
      expand | \
      awk '/[^[:space:]]/{last=NR} {a[NR]=$0} END{for(i=1;i<=last;i++)print a[i]}' | \
      tail -n "$inner_h")
  else
    win_lines[$i]=""
  fi

  i=$((i + 1))
done <<< "$win_data"

# Pre-split captured lines into flat array for O(1) lookup in render loop
declare -a _line
for ((w = 0; w < i; w++)); do
  _tmp=()
  [[ -n "${win_lines[w]}" ]] && mapfile -t _tmp <<< "${win_lines[w]}"
  for ((l = 0; l < inner_h; l++)); do
    _line[w * inner_h + l]="${_tmp[l]:-}"
  done
done

# --- Helpers ---

# Truncate or pad a string to exactly N characters
fit() {
  local str="$1" w="$2"
  local len=${#str}
  if [ "$len" -gt "$w" ]; then
    printf '%s' "${str:0:$((w - 1))}…"
  elif [ "$len" -lt "$w" ]; then
    printf '%s' "$str"
    printf '%*s' "$((w - len))" ""
  else
    printf '%s' "$str"
  fi
}

# Repeat a character N times
rep() {
  local s='' i
  for ((i = 0; i < $2; i++)); do s+="$1"; done
  printf '%s' "$s"
}

# --- Render grid ---

for ((row = 0; row < grid_rows; row++)); do
  start=$((row * grid_cols))

  # ┌─ label ──────┐  ┌─ label ──────┐
  for ((col = 0; col < grid_cols; col++)); do
    wi=$((start + col))
    [ "$wi" -ge "$win_count" ] && break
    [ "$col" -gt 0 ] && printf '%*s' "$gap" ""

    lbl=" ${win_label[$wi]} "
    lbl_len=${#lbl}
    if [ "$lbl_len" -gt "$((inner_w - 1))" ]; then
      lbl="${lbl:0:$((inner_w - 3))}.."
      lbl_len=${#lbl}
    fi
    fill_len=$((inner_w - lbl_len))
    [ "$fill_len" -lt 0 ] && fill_len=0
    fill=$(rep '─' "$fill_len")

    if [ "${win_is_active[$wi]}" = "1" ]; then
      printf '\033[1;37m┌─%s%s┐\033[0m' "$lbl" "$fill"
    else
      printf '\033[38;5;244m┌─%s%s┐\033[0m' "$lbl" "$fill"
    fi
  done
  printf '\n'

  # │ content │  │ content │
  for ((li = 0; li < inner_h; li++)); do
    for ((col = 0; col < grid_cols; col++)); do
      wi=$((start + col))
      [ "$wi" -ge "$win_count" ] && break
      [ "$col" -gt 0 ] && printf '%*s' "$gap" ""

      # Get line from pre-split flat array
      content="${_line[wi * inner_h + li]}"
      padded=$(fit "$content" "$inner_w")

      if [ "${win_is_active[$wi]}" = "1" ]; then
        printf '\033[1;37m│\033[0m%s\033[1;37m│\033[0m' "$padded"
      else
        printf '\033[38;5;238m│\033[0m\033[38;5;250m%s\033[0m\033[38;5;238m│\033[0m' "$padded"
      fi
    done
    printf '\n'
  done

  # └──────────────┘  └──────────────┘
  for ((col = 0; col < grid_cols; col++)); do
    wi=$((start + col))
    [ "$wi" -ge "$win_count" ] && break
    [ "$col" -gt 0 ] && printf '%*s' "$gap" ""

    fill=$(rep '─' "$inner_w")
    if [ "${win_is_active[$wi]}" = "1" ]; then
      printf '\033[1;37m└%s┘\033[0m' "$fill"
    else
      printf '\033[38;5;244m└%s┘\033[0m' "$fill"
    fi
  done
  printf '\n'
done
