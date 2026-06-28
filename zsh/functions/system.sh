# shellcheck shell=bash
#==============================================================================
# System Functions
#==============================================================================
# Consolidated system utilities and performance monitoring functions.
# This module combines common utilities and performance diagnostics
# into a single, logically organized file.
#
# Sections:
#   1. Utility Functions - Common helper functions used throughout dotfiles
#   2. Performance Functions - Shell profiling and system health monitoring
#
# See individual section headers below for detailed function listings.
#==============================================================================

# =============================================================================
# Utility Functions
# =============================================================================
# Common utility functions for zsh configuration
# Reduces code duplication across dotfiles modules
#
# Functions:
#   - has_command: Check if a command exists
#   - confirm: Interactive confirmation prompt
# =============================================================================

# Check if a command exists
# Usage: if has_command bat; then ... fi
# Replaces: if command -v bat &> /dev/null; then ... fi
has_command() {
    command -v "$1" &>/dev/null
}

# Interactive confirmation prompt
# Usage: if confirm "Delete all files?"; then ... fi
# Returns: 0 (success) if yes, 1 (failure) if no
confirm() {
    local message="${1:-Proceed?}"
    printf "%s [y/N] " "$message"
    read -r response
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Performance & System Monitoring Functions
# =============================================================================
# Shell performance profiling, tool status checking, and system health monitoring.
# All functions include inline "Usage: ..." documentation.
#
# Functions:
#   - zsh_bench: Benchmark zsh startup time with iterations
#   - zsh_profile: Profile zsh startup with detailed timing breakdown
#   - tool_status: Show modern CLI tool installation status
#   - check_tool: Helper function for tool checking
#   - startup_monitor: Monitor shell startup performance with alerts
#   - startup_profile: Enhanced startup profiling with recommendations
#   - system_health: Comprehensive system health check
# =============================================================================

# Performance monitoring for zsh startup
zsh_bench() {
  # Usage: zsh_bench [iterations]
  # Benchmarks zsh startup time with detailed breakdown
  local iterations="${1:-5}"
  echo "Benchmarking zsh startup time ($iterations iterations)..."

  for i in $(seq 1 $iterations); do
    echo "Run $i:"
    /usr/bin/time -f "  Real: %e seconds, User: %U, Sys: %S" zsh -i -c exit
  done

  echo ""
  echo "To profile what's slow, run: zsh_profile"
}

# Profile zsh startup with detailed timing
zsh_profile() {
  # Usage: zsh_profile
  # Shows detailed timing of zsh startup components
  echo "Profiling zsh startup with detailed timing..."
  echo "This will show which parts of .zshrc are slowest:"
  echo ""

  PS4='+ %D{%s.%.} %N:%i> ' zsh -i -x -c exit 2>&1 | \
    awk '/\+.*source.*zshrc/ { start = $2; next }
         /\+.*\[/ { if (start) { print $2 - start " seconds: " $0; start = 0 } }' | \
    sort -n | tail -10

  echo ""
  echo "For a simpler benchmark, run: zsh_bench"
}

# Show tool installation status
tool_status() {
  # Usage: tool_status
  # Shows which modern CLI tools are installed and available
  echo "=== Modern CLI Tools Status ==="

  local core_tools=(
    "fd:fdfind:Better find"
    "bat:batcat:Syntax highlighting cat"
    "eza:exa:Better ls with icons"
    "rg::Better grep (ripgrep)"
    "delta::Better git diff"
    "fzf::Fuzzy finder"
    "gh::GitHub CLI"
  )

  local monitoring_tools=(
    "btop:htop:Modern resource monitor"
    "ctop::Container monitoring"
    "procs::Modern ps replacement"
    "duf::Better df with visualization"
    "dust::Intuitive du replacement"
  )

  local developer_tools=(
    "lazygit::Git TUI"
    "dive::Docker image analyzer"
    "just::Modern command runner"
    "hyperfine::Command benchmarking"
    "glow::Markdown renderer"
    "difft::Structural diff tool"
  )

  local productivity_tools=(
    "zoxide::Smart cd replacement"
    "tldr::Simplified man pages"
    "cheat::Interactive cheatsheets"
    "fastfetch:neofetch:System info display"
  )

  local security_tools=(
    "gitleaks::Git secrets scanner"
    "pre-commit::Code quality automation"
    "sops::Encrypted secrets management"
  )

  echo "🚀 Core Tools:"
  for tool_info in "${core_tools[@]}"; do
    IFS=':' read -r primary alternative description <<< "$tool_info"
    check_tool "$primary" "$alternative" "$description"
  done

  echo
  echo "📊 Monitoring & System:"
  for tool_info in "${monitoring_tools[@]}"; do
    IFS=':' read -r primary alternative description <<< "$tool_info"
    check_tool "$primary" "$alternative" "$description"
  done

  echo
  echo "💻 Developer Tools:"
  for tool_info in "${developer_tools[@]}"; do
    IFS=':' read -r primary alternative description <<< "$tool_info"
    check_tool "$primary" "$alternative" "$description"
  done

  echo
  echo "⚡ Productivity:"
  for tool_info in "${productivity_tools[@]}"; do
    IFS=':' read -r primary alternative description <<< "$tool_info"
    check_tool "$primary" "$alternative" "$description"
  done

  echo
  echo "🔒 Security & Quality:"
  for tool_info in "${security_tools[@]}"; do
    IFS=':' read -r primary alternative description <<< "$tool_info"
    check_tool "$primary" "$alternative" "$description"
  done

  echo
  echo "🔧 Optional Development Tools:"
  check_tool "direnv" "" "Per-directory env vars"
  check_tool "poetry" "" "Python dependency management"
  check_tool "docker" "" "Container platform"
  check_tool "nvm" "" "Node.js version manager (lazy-loaded)"
  check_tool "pyenv" "" "Python version manager (lazy-loaded)"

  echo
  echo "Environment variables set:"
  [[ -n "$_HAS_FD" ]] && echo "  _HAS_FD=$_HAS_FD"
  [[ -n "$_HAS_BAT" ]] && echo "  _HAS_BAT=$_HAS_BAT"
  [[ -n "$_HAS_MODERN_LS" ]] && echo "  _HAS_MODERN_LS=$_HAS_MODERN_LS"
  [[ -n "$_HAS_RG" ]] && echo "  _HAS_RG=$_HAS_RG"
}

# Helper function for tool checking
check_tool() {
  local primary="$1"
  local alternative="$2"
  local description="$3"

  if command -v "$primary" &> /dev/null; then
    echo "  ✓ $primary - $description"
  elif [[ -n "$alternative" ]] && command -v "$alternative" &> /dev/null; then
    echo "  ✓ $alternative - $description (as $alternative)"
  else
    echo "  ✗ $primary - $description (not installed)"
  fi
}

# startup_monitor - Monitor shell startup performance with alerts
startup_monitor() {
  local threshold="${1:-1.0}"  # Default threshold: 1 second
  local iterations="${2:-3}"
  local total_time=0
  local warning_shown=false

  echo "Monitoring shell startup performance..."
  echo "Threshold: ${threshold}s, Iterations: $iterations"
  echo

  for i in $(seq 1 $iterations); do
    local start_time=$(date +%s.%N)
    zsh -i -c exit 2>/dev/null
    local end_time=$(date +%s.%N)
    local elapsed=$(echo "$end_time - $start_time" | bc -l)

    printf "Run %d: %.3fs" "$i" "$elapsed"

    # Check if above threshold
    if (( $(echo "$elapsed > $threshold" | bc -l) )); then
      echo " ⚠️  SLOW"
      warning_shown=true
    else
      echo " ✓"
    fi

    total_time=$(echo "$total_time + $elapsed" | bc -l)
  done

  local avg_time=$(echo "scale=3; $total_time / $iterations" | bc -l)
  echo
  echo "Average startup time: ${avg_time}s"

  if [[ "$warning_shown" == "true" ]]; then
    echo
    echo "⚠️  Performance Alert: Startup time exceeded threshold!"
    echo "Suggestions to improve performance:"
    echo "1. Run 'startup_profile' to identify slow components"
    echo "2. Consider disabling slow plugins in ~/.zshrc.local:"
    echo "   plugins=(\${plugins:#poetry})  # Remove poetry plugin"
    echo "3. Use lazy loading for heavy tools (nvm, pyenv already optimized)"
    echo "4. Check for slow functions with 'zsh_profile'"
  fi
}

# startup_profile - Enhanced startup profiling with recommendations
startup_profile() {
  echo "Profiling shell startup components..."
  echo "This will identify the slowest parts of your configuration."
  echo

  local profile_file="/tmp/zsh_profile_$$.log"

  # Run with detailed timing
  PS4='+ %D{%s.%.} %N:%i> ' zsh -i -x -c exit 2>"$profile_file"

  echo "=== Slowest Configuration Components ==="

  # Extract and analyze timing data
  awk '
    /^\+ [0-9]+\.[0-9]+ .*source/ {
      start_time = $2;
      source_file = $0;
      next
    }
    /^\+ [0-9]+\.[0-9]+ / {
      if (start_time && $2 > start_time) {
        duration = $2 - start_time
        if (duration > 0.001) {  # Only show operations > 1ms
          printf "%.3fs - %s\n", duration, source_file
        }
        start_time = 0
      }
    }
  ' "$profile_file" | sort -rn | head -15

  echo
  echo "=== Plugin Loading Times ==="

  # Analyze plugin loading specifically
  grep -E '(plugins|source.*plugin)' "$profile_file" | \
    awk '/^\+ [0-9]+\.[0-9]+/ {
      if (prev_time) {
        duration = $2 - prev_time
        if (duration > 0.01) printf "%.3fs - %s\n", duration, prev_line
      }
      prev_time = $2; prev_line = $0
    }' | sort -rn | head -10

  echo
  echo "=== Recommendations ==="

  # Check for specific slow components and provide recommendations
  if grep -q "poetry" "$profile_file"; then
    echo "📝 Poetry detected - already optimized with lazy loading"
  fi

  if grep -q "nvm" "$profile_file"; then
    echo "📝 NVM detected - already optimized with lazy loading"
  fi

  if grep -q "pyenv" "$profile_file"; then
    echo "📝 Pyenv detected - already optimized with lazy loading"
  fi

  local total_plugins=$(grep -c "plugins" "$profile_file" 2>/dev/null || echo "0")
  if (( total_plugins > 15 )); then
    echo "⚠️  Consider reducing plugin count (currently ~$total_plugins loaded)"
  fi

  echo
  echo "Full profile saved to: $profile_file"
  echo "Run 'startup_monitor' to check if improvements helped"

  # Cleanup
  # rm -f "$profile_file"
}

# system_health - Comprehensive system health check
system_health() {
  echo "=== System Health Check ==="
  echo

  # Disk space
  echo "📊 Disk Usage:"
  if command -v duf &> /dev/null; then
    duf | head -10
  else
    df -h | head -10
  fi
  echo

  # Memory usage
  echo "💾 Memory Usage:"
  if command -v free &> /dev/null; then
    free -h
  else
    vm_stat 2>/dev/null || echo "Memory info not available"
  fi
  echo

  # Top processes by CPU/Memory
  echo "🔥 Resource Usage:"
  if command -v procs &> /dev/null; then
    echo "Top CPU processes:"
    procs --sortd cpu | head -5
    echo
    echo "Top Memory processes:"
    procs --sortd memory | head -5
  else
    echo "Top processes:"
    ps aux --sort=-%cpu | head -6
  fi
  echo

  # Check for common issues
  echo "🔍 Health Checks:"

  # Check shell startup time
  local startup_time
  startup_time=$( (/usr/bin/time -f "%e" zsh -i -c exit) 2>&1)
  if (( $(echo "$startup_time > 2.0" | bc -l 2>/dev/null || echo "0") )); then
    echo "⚠️  Slow shell startup: ${startup_time}s (consider optimization)"
  else
    echo "✓ Shell startup time: ${startup_time}s"
  fi

  # Check git repository status
  if git status &>/dev/null; then
    local git_status=$(git status --porcelain 2>/dev/null | wc -l)
    if (( git_status > 0 )); then
      echo "📝 Git: $git_status uncommitted changes"
    else
      echo "✓ Git: Working directory clean"
    fi
  fi

  # Check for Docker resource usage
  if command -v docker &> /dev/null && docker ps &>/dev/null; then
    local running_containers=$(docker ps -q | wc -l)
    echo "🐳 Docker: $running_containers containers running"
  fi
}

# =============================================================================
# GNOME Desktop Functions
# =============================================================================
# Inspect and back up the GNOME desktop configuration applied by
# scripts/apply-gnome-settings.sh (run via the `gnome-apply` alias).
# User-facing, dash-named (like gco-safe). See docs/GNOME_CONFIGURATION_GUIDE.md.
#
# Functions:
#   - gnome-status:  Summary of GNOME version, session, theme, dock, extensions
#   - gnome-backup:  Dump the full GNOME dconf tree to a timestamped file
#   - gnome-restore: Load a GNOME dconf backup file (with confirmation)
# =============================================================================

# Quick summary of the current GNOME desktop state
gnome-status() {
  # Usage: gnome-status
  if ! has_command gsettings; then
    echo "gsettings not found — GNOME not detected."
    return 1
  fi
  # Subshell: drop GIO_MODULE_DIR so gsettings uses the real dconf backend even
  # from a snap-confined terminal (see scripts/apply-gnome-settings.sh).
  (
    unset GIO_MODULE_DIR
    dtd="org.gnome.shell.extensions.dash-to-dock"
    echo "=== GNOME Status ==="
    echo "Shell:      $(gnome-shell --version 2>/dev/null || echo 'n/a')"
    echo "Session:    ${XDG_SESSION_TYPE:-?} (${XDG_CURRENT_DESKTOP:-?})"
    echo "Color:      $(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null)"
    echo "GTK theme:  $(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null)"
    echo "Accent:     $(gsettings get org.gnome.desktop.interface accent-color 2>/dev/null)"
    echo "Dock:       $(gsettings get "$dtd" dock-position 2>/dev/null) (extend-height=$(gsettings get "$dtd" extend-height 2>/dev/null))"
    echo "Overrides:  $([ -f ~/.gnome-settings.local ] && echo '~/.gnome-settings.local present' || echo 'none (run gnome-init)')"
    if has_command gnome-extensions; then
      echo "Enabled extensions:"
      gnome-extensions list --enabled 2>/dev/null | sed 's/^/  /'
    fi
  )
}

# Back up the full GNOME dconf subtree to a timestamped file (local, not tracked)
gnome-backup() {
  # Usage: gnome-backup [output-file]
  if ! has_command dconf; then
    echo "dconf not found — GNOME not detected."
    return 1
  fi
  local out="${1:-$HOME/gnome-dconf-$(date +%F-%H%M).conf}"
  dconf dump /org/gnome/ > "$out" && echo "✓ Saved GNOME settings to $out"
}

# Restore a GNOME dconf backup file (overwrites current settings)
gnome-restore() {
  # Usage: gnome-restore <backup-file>
  if ! has_command dconf; then
    echo "dconf not found — GNOME not detected."
    return 1
  fi
  local in="${1:-}"
  if [[ -z "$in" || ! -f "$in" ]]; then
    echo "Usage: gnome-restore <backup-file>"
    return 1
  fi
  if confirm "Load '$in' into /org/gnome/ (overwrites current GNOME settings)?"; then
    dconf load /org/gnome/ < "$in" && echo "✓ Restored GNOME settings from $in"
  fi
}
