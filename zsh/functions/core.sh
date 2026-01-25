# shellcheck shell=bash
#==============================================================================
# Core Shell Utility Functions
#==============================================================================
# Provides essential file/directory, clipboard, network, and process utilities.
# All functions include inline "Usage: ..." documentation.
#
# Functions:
#   - pathadd: Safely add directories to PATH (prevents duplicates)
#   - mkcd: Create directory and cd into it
#   - backup: Create timestamped backup of file
#   - extract: Universal archive extractor (handles tar, zip, gz, etc.)
#   - osc52: Copy text to local clipboard via OSC 52 (works over SSH!)
#   - copyfile: Copy file contents to clipboard (auto-detects SSH, uses OSC 52 or xclip/pbcopy)
#   - catcopy: View file with bat and copy raw contents to clipboard
#   - myip: Get public IP address
#   - localip: Get local IP address
#   - note: Quick note taking with timestamps
#   - psgrep: Search for processes by pattern
#   - killnamed: Kill process by name (with confirmation)
#   - mkdate: Create dated directory with optional prefix
#   - dirsize: Show directory sizes sorted by size
#==============================================================================

# Add directories to PATH if not already present
pathadd() {
  # Usage: pathadd <directory1> [directory2 ...]
  # Adds one or more directories to PATH only if they exist and aren't already in PATH
  for dir in "$@"; do
    if [ -d "$dir" ]; then
      if [[ ":$PATH:" != *":$dir:"* ]]; then
        PATH="${PATH:+"$PATH:"}$dir"
      fi
    fi
  done
}

# Create directory and cd into it
mkcd() {
  # Usage: mkcd <directory>
  # Creates a directory (including parents) and changes into it
  if [ $# -ne 1 ]; then
    echo "Usage: mkcd <directory>"
    return 1
  fi
  mkdir -p "$1" && cd "$1"
}

# Quick backup of a file
backup() {
  # Usage: backup <file>
  # Creates a timestamped backup copy of a file
  if [ $# -ne 1 ]; then
    echo "Usage: backup <file>"
    return 1
  fi

  # Check if file exists and is readable
  if [ ! -f "$1" ]; then
    echo "Error: File '$1' does not exist or is not a regular file"
    return 1
  fi

  if [ ! -r "$1" ]; then
    echo "Error: Cannot read file '$1' (permission denied)"
    return 1
  fi

  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_name="${1}.backup_${timestamp}"

  # Check if backup already exists (very unlikely but possible)
  if [ -f "$backup_name" ]; then
    echo "Warning: Backup file '$backup_name' already exists"
    printf "Overwrite? [y/N] "
    read -r response
    case "$response" in
      [yY]|[yY][eE][sS]) ;;
      *)
        echo "Backup cancelled."
        return 1
        ;;
    esac
  fi

  # Attempt to copy the file
  if cp "$1" "$backup_name"; then
    echo "Created backup: $backup_name"
  else
    echo "Error: Failed to create backup of '$1'"
    return 1
  fi
}

# Extract archives of any type
extract() {
  # Usage: extract <file>
  # Note: oh-my-zsh extract plugin also provides this, but this is a fallback
  if [ $# -ne 1 ]; then
    echo "Usage: extract <file>"
    return 1
  fi
  if [ -f "$1" ]; then
    case "$1" in
      *.tar.bz2)   tar xjf "$1"     ;;
      *.tar.gz)    tar xzf "$1"     ;;
      *.bz2)       bunzip2 "$1"     ;;
      *.rar)       unrar x "$1"     ;;
      *.gz)        gunzip "$1"      ;;
      *.tar)       tar xf "$1"      ;;
      *.tbz2)      tar xjf "$1"     ;;
      *.tgz)       tar xzf "$1"     ;;
      *.zip)       unzip "$1"       ;;
      *.Z)         uncompress "$1"  ;;
      *.7z)        7z x "$1"        ;;
      *)           echo "'$1' cannot be extracted via extract()" ;;
    esac
  else
    echo "'$1' is not a valid file"
  fi
}

# Copy to clipboard using OSC 52 (works over SSH!)
osc52() {
  # Usage: osc52 <text> or echo "text" | osc52
  # Copies text to local clipboard using OSC 52 escape sequence
  # Works over SSH with modern terminals (iTerm2, tmux, Windows Terminal, etc.)
  local input

  if [ $# -gt 0 ]; then
    input="$*"
  else
    input=$(cat)
  fi

  local len=${#input}
  local encoded=$(printf "%s" "$input" | base64 | tr -d '\n')

  # Send OSC 52 escape sequence
  if [ -n "$TMUX" ]; then
    # Inside tmux, wrap the escape sequence
    printf "\033Ptmux;\033\033]52;c;%s\007\033\\" "$encoded"
  else
    printf "\033]52;c;%s\007" "$encoded"
  fi

  echo "✓ Copied ${len} characters to clipboard via OSC 52"
}

# Copy file contents to clipboard
copyfile() {
  # Usage: copyfile <file>
  # Copies the contents of a file to the clipboard
  # Tries multiple methods: OSC 52 (SSH-friendly), xclip, pbcopy, wl-copy
  if [ $# -ne 1 ]; then
    echo "Usage: copyfile <file>"
    return 1
  fi

  if [ ! -f "$1" ]; then
    echo "Error: File '$1' not found"
    return 1
  fi

  # Try OSC 52 first (works over SSH!)
  if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_CLIENT" ]; then
    cat "$1" | osc52
    return 0
  fi

  # Fall back to local clipboard utilities
  if command -v xclip &> /dev/null && [ -n "$DISPLAY" ]; then
    cat "$1" | xclip -selection clipboard
    echo "✓ Copied '$1' to clipboard (xclip)"
  elif command -v pbcopy &> /dev/null; then
    cat "$1" | pbcopy
    echo "✓ Copied '$1' to clipboard (pbcopy)"
  elif command -v wl-copy &> /dev/null; then
    cat "$1" | wl-copy
    echo "✓ Copied '$1' to clipboard (wl-copy)"
  else
    # Last resort: use OSC 52 anyway
    echo "⚠ No local clipboard utility found, using OSC 52"
    cat "$1" | osc52
  fi
}

# View file with bat and copy to clipboard
catcopy() {
  # Usage: catcopy <file>
  # Displays file with bat (syntax highlighted) and copies raw contents to clipboard
  if [ $# -ne 1 ]; then
    echo "Usage: catcopy <file>"
    return 1
  fi

  if [ ! -f "$1" ]; then
    echo "Error: File '$1' not found"
    return 1
  fi

  # Show with bat for nice viewing
  if command -v bat &> /dev/null; then
    bat "$1"
  elif command -v batcat &> /dev/null; then
    batcat "$1"
  else
    cat "$1"
  fi

  # Copy raw contents to clipboard
  echo ""
  copyfile "$1"
}

# Get public IP address
myip() {
  # Usage: myip
  # Displays your public IP address
  curl -s https://api.ipify.org && echo
}

# Get local IP address
localip() {
  # Usage: localip
  # Displays your local IP address
  hostname -I | awk '{print $1}'
}

# Quick note taking
note() {
  # Usage: note <message>
  # Appends a timestamped note to ~/notes.txt
  local notes_file="${HOME}/notes.txt"
  if [ $# -eq 0 ]; then
    # Display notes if no arguments
    if [ -f "$notes_file" ]; then
      cat "$notes_file"
    else
      echo "No notes found. Use: note <message> to create one."
    fi
  else
    # Add note with timestamp
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$notes_file"
    echo "Note added to $notes_file"
  fi
}

# Search for a running process
psgrep() {
  # Usage: psgrep <pattern>
  # Greps for a process by name
  ps aux | grep -v grep | grep -i -e VSZ -e "$@"
}

# Kill process by name
killnamed() {
  # Usage: killnamed <process_name>
  # Kills all processes matching the given name (with confirmation)
  if [ $# -ne 1 ]; then
    echo "Usage: killnamed <process_name>"
    return 1
  fi

  # Find matching processes
  local processes=$(ps aux | grep -v grep | grep "$1")

  if [ -z "$processes" ]; then
    echo "No processes found matching: $1"
    return 1
  fi

  echo "Found processes matching '$1':"
  echo "$processes"
  echo

  # Count number of processes
  local count=$(echo "$processes" | wc -l)

  # Confirmation prompt
  printf "Kill $count process(es)? [y/N] "
  read -r response
  case "$response" in
    [yY]|[yY][eE][sS])
      # Extract PIDs and validate they're numeric before killing
      local pids=$(echo "$processes" | awk '{print $2}')
      local killed=0
      local failed=0

      while IFS= read -r pid; do
        # Validate PID is numeric
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
          # Safety check: Skip system-critical PIDs
          if [[ "$pid" -le 10 ]]; then
            echo "⚠️  Skipping system PID $pid (safety check)"
            ((failed++))
            continue
          fi

          if kill "$pid" 2>/dev/null; then
            echo "✓ Killed PID $pid"
            ((killed++))
          else
            echo "✗ Failed to kill PID $pid (may require sudo or already terminated)"
            ((failed++))
          fi
        else
          echo "✗ Invalid PID: $pid (skipping)"
          ((failed++))
        fi
      done <<< "$pids"

      echo ""
      echo "Summary: $killed killed, $failed failed"
      [ $failed -eq 0 ] && return 0 || return 1
      ;;
    *)
      echo "Operation cancelled."
      return 1
      ;;
  esac
}

# Create a dated directory
mkdate() {
  # Usage: mkdate [prefix]
  # Creates a directory with current date (YYYY-MM-DD format)
  local date_str=$(date +%Y-%m-%d)
  local dir_name="${1:+${1}_}${date_str}"
  mkdir -p "$dir_name" && cd "$dir_name"
}

# Show directory sizes
dirsize() {
  # Usage: dirsize [directory]
  # Shows sizes of directories in human-readable format
  du -sh "${1:-.}"/* 2>/dev/null | sort -h
}
