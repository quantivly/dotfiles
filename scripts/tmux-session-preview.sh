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
win_count=0
[[ -n "$win_data" ]] && win_count=$(printf '%s\n' "$win_data" | wc -l)

attached=$(tmux list-sessions -F '#{session_name}|#{session_attached}' 2>/dev/null |
  awk -F'|' -v s="$session" '$1==s{print $2}')
att_str=""
[ "${attached:-0}" -gt 0 ] && att_str=" · attached"

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
  win_label[i]="$lbl"
  win_is_active[i]="$active"

  # Get active pane ID directly (tmux 1.9+)
  pid=$(tmux display-message -t "${session}:${idx}" -p '#{pane_id}' 2>/dev/null)

  # Capture with ANSI colors, strip trailing blanks, take bottom lines,
  # and format to exact width (ANSI-aware) — all in one perl call
  if [ -n "$pid" ]; then
    win_lines[i]=$(tmux capture-pane -e -J -t "$pid" -p 2>/dev/null | \
      perl -CSD -e '
        use strict; use warnings;
        my $W = $ARGV[0];
        my $H = $ARGV[1];
        my @lines = <STDIN>;
        chomp @lines;

        # Strip trailing blank lines (ignore SGR when checking blankness)
        while (@lines) {
          my $vis = $lines[-1];
          $vis =~ s/\033\[[0-9;]*m//g;
          last if $vis =~ /\S/;
          pop @lines;
        }

        # Take last $H lines (bottom of pane where prompts live)
        if (@lines > $H) {
          @lines = @lines[-$H .. -1];
        }

        # Pad to exactly $H lines if fewer exist
        while (@lines < $H) {
          unshift @lines, "";
        }

        for my $line (@lines) {
          # Count visible width and truncate/pad
          my $out = "";
          my $vw = 0;
          my $truncated = 0;

          while ($line =~ /(\033\[[0-9;]*m)|(.)/gs) {
            if (defined $1) {
              # SGR escape — zero width, always include unless truncated
              $out .= $1 unless $truncated;
            } else {
              if ($vw >= $W) {
                $truncated = 1;
                next;
              }
              if ($vw == $W - 1 && length($line) > pos($line)) {
                # Check if remaining has visible chars
                my $rest = substr($line, pos($line));
                my $vis_rest = $rest;
                $vis_rest =~ s/\033\[[0-9;]*m//g;
                if (length($vis_rest) > 0) {
                  $out .= "\x{2026}";  # ellipsis
                  $vw++;
                  $truncated = 1;
                  next;
                }
              }
              $out .= $2;
              $vw++;
            }
          }

          # Pad short lines with spaces
          if ($vw < $W) {
            $out .= " " x ($W - $vw);
          }
          $out .= "\033[0m";
          print "$out\n";
        }
      ' "$inner_w" "$inner_h")
  else
    win_lines[i]=""
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

    lbl=" ${win_label[wi]} "
    lbl_len=${#lbl}
    if [ "$lbl_len" -gt "$((inner_w - 1))" ]; then
      lbl="${lbl:0:$((inner_w - 3))}.."
      lbl_len=${#lbl}
    fi
    fill_len=$((inner_w - lbl_len))
    [ "$fill_len" -lt 0 ] && fill_len=0
    fill=$(rep '─' "$fill_len")

    if [ "${win_is_active[wi]}" = "1" ]; then
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

      # Get pre-formatted line from flat array (already exact width + reset)
      content="${_line[wi * inner_h + li]}"

      if [ "${win_is_active[wi]}" = "1" ]; then
        printf '\033[1;37m│\033[0m%s\033[1;37m│\033[0m' "$content"
      else
        printf '\033[38;5;238m│\033[0m%s\033[38;5;238m│\033[0m' "$content"
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
    if [ "${win_is_active[wi]}" = "1" ]; then
      printf '\033[1;37m└%s┘\033[0m' "$fill"
    else
      printf '\033[38;5;244m└%s┘\033[0m' "$fill"
    fi
  done
  printf '\n'
done
