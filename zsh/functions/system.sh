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

  # Memory-pressure kills (earlyoom / systemd-oomd / kernel OOM killer).
  #
  # Worth surfacing because the damage is silent rather than loud: a process
  # killed mid-pipeline still lets the pipeline exit 0 with empty output, so the
  # result is a confident wrong answer, not an error. On 2026-08-03 a 16 GB
  # search was shed this way and its empty output was read as "no matches".
  #
  # Pattern note: match "sending SIG… to process", not just "sending SIG" —
  # earlyoom's startup banner ("sending SIGTERM when mem avail <= 10.00%")
  # otherwise counts as a kill on every boot.
  #
  # Never print the ✓ line when the journal couldn't actually be read: no
  # journalctl at all (macOS), or a user outside adm/systemd-journal, who sees
  # only their own journal — and these kills are logged by root units. A false
  # all-clear is the very failure mode this check exists to catch, so report
  # "skipped" instead. journalctl exits 0 in both the "no access" and "no
  # matches" cases, so the signal is whether those identifiers yield *any* line
  # at all before the kill pattern is applied: all three are system-scope and
  # the kernel alone logs thousands of lines a week (23.8k here), so a readable
  # journal is never empty over 7 days.
  #
  # -t also narrows the read: unfiltered, this dumps every entry of the last 7
  # days (419k lines, 3.3s here) for the same result it gets in 0.4s.
  local oom_pat='earlyoom.*sending SIG[A-Z]+ to process|Killed process [0-9]+|oom-kill:|systemd-oomd.*Killed'
  local oom_log oom_kills oom_last
  if ! has_command journalctl; then
    echo "○ Memory-pressure kills: journalctl not available (skipped)"
  elif [[ -z "$(journalctl --since '7 days ago' --no-pager -n 1 \
        -t earlyoom -t systemd-oomd -t kernel 2>/dev/null)" ]]; then
    echo "○ Memory-pressure kills: system journal unreadable (skipped)"
    echo "    Needs journal access: sudo usermod -aG adm \"\$USER\" (re-login)"
  else
    oom_log=$(journalctl --since "7 days ago" --no-pager \
      -t earlyoom -t systemd-oomd -t kernel 2>/dev/null | grep -E "$oom_pat" || true)
    oom_kills=$(printf '%s' "$oom_log" | grep -c . || true)
    if (( oom_kills > 0 )); then
      # Only earlyoom's format shortens cleanly; kernel/systemd-oomd victims
      # keep their raw line (long, but complete).
      oom_last=$(printf '%s\n' "$oom_log" | tail -1 \
        | sed 's/.*sending SIG[A-Z]* to process /pid /; s/, cmdline.*//')
      echo "⚠️  Memory-pressure kills (7d): ${oom_kills} — latest: ${oom_last}"
      echo "    A killed process usually still exits 0 with empty output, so treat"
      echo "    empty results from around then as unanswered, not as an all-clear."
      echo "    Detail: journalctl --since '7 days ago' | grep -E 'earlyoom|oom-kill'"
    else
      echo "✓ No memory-pressure kills in the last 7 days"
    fi
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

# =============================================================================
# Backup Functions (restic + resticprofile)
# =============================================================================
# Thin, user-facing wrappers over the backup system set up by scripts/setup-backup.sh
# (run via `backup-setup`). Dash-named (like gco-safe / gnome-*). The repos are
# root-owned and the repo key is root-readable, so these run restic/resticprofile
# via sudo with the env loaded from /etc/restic/backup.local.
# See docs/BACKUP_AND_RESTORE_GUIDE.md.  (Note: `backup` in core.sh is a separate
# single-file utility — these are `backup-*`.)
#
# Functions:
#   - backup-now:          Run a backup now (default both, b2 first; external skipped if undocked)
#   - backup-status:       Targets reachable? timers armed? latest snapshots?
#   - backup-doctor:       Full-chain health assertion (perms, drift, drop-ins, age, freshness)
#   - backup-snapshots:    List snapshots for a target (b2|external)
#   - backup-check:        Verify repository integrity (slow / costs B2 reads)
#   - backup-restore:      Guided restore of a snapshot to ~/restore-<ts>/
#   - backup-restore-system: Guarded /etc-slice restore (never clobbers fstab/crypttab/…)
#   - backup-drill:        Prove the backup is COMPLETE + RESTORABLE (content + restore canary)
#   - backup-mount:        Browse a repo via FUSE (~/backup-mnt)
#   - backup-unmount:      Unmount the FUSE browse mount
#   - backup-unlock:       Clear stale restic locks after an interrupted run
#   - backup-prune:        Prune B2 with the OFFLINE full key (append-only key can't)
#   - backup-luks-header:  Re-take the LUKS header backup
#   - backup-kit:          Emergency-kit status + reminder
# =============================================================================

# Internal: read values out of ~/.backup.local, one per line in the order asked
# (blank for anything unset or if the file is unreadable).
#
# Batched deliberately: backup-doctor needs eight of these, and eight separate
# `( . ~/.backup.local; echo $VAR )` subshells both fork eight times and can
# disagree with each other if the file is edited mid-run. Sourcing the file into
# the CALLING shell instead is not an option — it holds the B2 credentials, and
# they must not end up in an interactive environment.
#
# Values must not contain newlines; ~/.backup.local is plain KEY=value (it is
# also read by systemd's EnvironmentFile, which has the same constraint).
_backup_local_get() {
  if [[ ! -r ~/.backup.local ]]; then printf '%.0s\n' "$@"; return 0; fi
  ( . ~/.backup.local 2>/dev/null
    for _bl_v in "$@"; do eval "printf '%s\n' \"\${${_bl_v}-}\""; done )
}

# Internal: is the external HDD actually MOUNTED at $1? findmnt reads
# /proc/self/mountinfo, so this is exact and needs no root.
#
# `test -e "$repo/config"` is NOT equivalent, and every caller here used to use
# it: a leftover directory on the ROOT filesystem satisfies it while the disk
# sits unmounted, so the caller reports "docked" while anything that writes
# lands on the internal disk.
_backup_external_mounted() {
  [[ -n "${1:-}" ]] && findmnt -rno TARGET --mountpoint "$1" >/dev/null 2>&1
}

# Internal: where /etc/fstab mounts UUID $1, or empty. Mirrors
# fstab_target_for_uuid in scripts/setup-backup.sh (bash; not sourceable here).
#
# TWO queries, because `-S UUID=x` resolves the tag through /dev/disk/by-uuid and
# therefore matches a `/dev/disk/by-uuid/x` entry — the form Ubuntu's installer
# writes, and the form /boot uses on this machine — ONLY while the disk is
# attached. Undocked, which is exactly when this check matters, one query alone
# reports "no entry" for a correct fstab and the doctor warns about a defect that
# is not there. The second is a literal match on the table, so it works either way.
_backup_fstab_target_for_uuid() {
  local uuid="${1:-}" out
  [[ -n "$uuid" ]] || return 0
  out="$(LC_ALL=C findmnt --fstab -no TARGET -S "UUID=$uuid" 2>/dev/null | head -1)"
  [[ -n "$out" ]] || out="$(LC_ALL=C findmnt --fstab -no TARGET -S "/dev/disk/by-uuid/$uuid" 2>/dev/null | head -1)"
  printf '%s' "$out"
}

# Internal: is the external HDD physically ATTACHED (mounted or not)?
# $1 = BACKUP_EXTERNAL_UUID (may be blank), $2 = mount point.
#
# Deliberately not gated on the UUID alone. That key went unread for the entire
# life of the backup system, so every pre-existing install has it blank — which
# is exactly the population that needs "attached but not mounted" to fire. Falls
# back to whatever /etc/fstab names as the source for that mount point.
#
# There is deliberately NO fallback to the mount point's basename as a filesystem
# label. udisks does name the directory after the label, so it looks tempting —
# but it identifies the drive by a name COINCIDENCE, and the caller turns a true
# answer into a hard, non-zero-exit failure. Any unrelated volume labelled
# "Backup" would then make backup-doctor insist that a drive which is not plugged
# in is attached-but-unmounted. backup-doctor reports a missing /etc/fstab entry
# on its own line anyway, so nothing is lost by declining to guess.
_backup_external_attached() {
  local uuid="${1:-}" mnt="${2:-}" src
  [[ -n "$uuid" && -e "/dev/disk/by-uuid/$uuid" ]] && return 0
  [[ -n "$mnt" ]] || return 1
  src="$(findmnt --fstab -no SOURCE --target "$mnt" 2>/dev/null)"
  case "$src" in
    UUID=*)  [[ -e "/dev/disk/by-uuid/${src#UUID=}"   ]] && return 0 ;;
    LABEL=*) [[ -e "/dev/disk/by-label/${src#LABEL=}" ]] && return 0 ;;
    /dev/*)  [[ -b "$src" ]] && return 0 ;;
  esac
  return 1
}

# Internal: run resticprofile as root with the backup env loaded.
_backup_rp() {
  sudo bash -c 'set -a; . /etc/restic/backup.local 2>/dev/null; set +a; exec resticprofile -c /etc/resticprofile/profiles.toml "$@"' _ "$@"
}

# Internal: run raw restic as root against a target repo. $1=b2|external, rest=args.
_backup_restic() {
  local target="${1:?usage: _backup_restic <b2|external> <restic args...>}"; shift
  sudo env TARGET="$target" bash -c '
    set -a; . /etc/restic/backup.local 2>/dev/null; set +a
    case "$TARGET" in
      external) export RESTIC_REPOSITORY="${BACKUP_EXTERNAL_REPO:?external repo not configured}" ;;
      b2)       export RESTIC_REPOSITORY="${BACKUP_B2_REPO:?b2 repo not configured}" ;;
      *) echo "unknown target: $TARGET (use b2 or external)" >&2; exit 2 ;;
    esac
    exec restic "$@"
  ' _ "$@"
}

# Internal: choose a snapshot id for a target. fzf picker if available, else a
# prompt; both default to "latest" on empty. Prompts/listing go to stderr so the
# chosen id is the only thing on stdout (safe to capture). $1 = b2|external.
_backup_pick_snapshot() {
  local target="$1" snap=""
  if has_command fzf; then
    snap="$(_backup_restic "$target" snapshots 2>/dev/null | grep -E '^[0-9a-f]{8} ' \
            | fzf --tac --header="Select a $target snapshot (Esc = latest)" | awk '{print $1}')"
  else
    _backup_restic "$target" snapshots >&2
    printf "Snapshot ID to restore (or 'latest'): " >&2; read -r snap
  fi
  [[ -n "$snap" ]] || snap="latest"
  printf '%s' "$snap"
}

# Run a backup now. Default 'full' group = both targets (b2 first, so the
# offsite copy completes even when the external HDD is not docked). For the
# default group, the external target is skipped when the drive isn't docked —
# otherwise it would fail and fire a false "Backup FAILED" alert + healthcheck
# /fail ping. An explicit `backup-now external` still runs (and reports) as asked.
backup-now() {
  # Usage: backup-now [b2|external|full]
  local target="${1:-full}"
  if [[ "$target" == "full" ]]; then
    local extrepo extmnt
    extrepo="$(_backup_local_get BACKUP_EXTERNAL_REPO)"
    extmnt="${extrepo:+$(dirname "$extrepo")}"
    # Both conditions matter: the mount check is what stops a leftover directory
    # on the internal disk from passing for a docked drive, and the repo check
    # is what keeps a mounted-but-uninitialised drive from raising a false
    # "Backup FAILED" alert.
    if ! _backup_external_mounted "$extmnt" || [[ ! -e "$extrepo/config" ]]; then
      echo "External HDD not docked — backing up to B2 only (run 'backup-now external' once docked)."
      target="b2"
    fi
  fi
  _backup_rp --name "$target" backup
}

# Quick health summary of the backup system
backup-status() {
  # Usage: backup-status
  echo "=== Backup Status ($(hostname)) ==="
  if [[ -f ~/.backup.local ]]; then echo "Config:     ~/.backup.local present"; else
    echo "Config:     ✗ missing — run 'backup-init', edit it, then 'backup-setup'"; return 1; fi
  echo "restic:     $(restic version 2>/dev/null | head -1 || echo 'not installed')"
  echo "profile:    $(resticprofile version 2>/dev/null | head -1 || echo 'resticprofile not installed')"
  echo "Timers:"
  systemctl list-timers --all 2>/dev/null | grep -iE 'restic|NEXT' | sed 's/^/  /' || echo "  (none — run backup-setup)"
  echo "External timer: $(systemctl is-enabled restic-backup-external.timer 2>/dev/null || echo 'n/a — run backup-setup')"
  local extuuid extrepo extmnt
  { read -r extuuid; read -r extrepo; } <<< "$(_backup_local_get BACKUP_EXTERNAL_UUID BACKUP_EXTERNAL_REPO)"
  extmnt="${extrepo:+$(dirname "$extrepo")}"
  # "not configured" is its own answer. With no BACKUP_EXTERNAL_REPO there is no
  # mount point to ask about, and both predicates are false for that reason
  # alone — so the else branch below would report a disk state this command has
  # no way to know, in the command users reach for first.
  if [[ -z "$extrepo" ]]; then
    echo "External:   not configured (set BACKUP_EXTERNAL_REPO in ~/.backup.local, then run backup-setup)"
  elif _backup_external_mounted "$extmnt"; then
    echo "External:   docked ✓ ($extmnt)"
  elif _backup_external_attached "$extuuid" "$extmnt"; then
    echo "External:   ✗ attached but NOT MOUNTED — every scheduled run is being skipped (see backup-doctor)"
  else
    echo "External:   not attached"
  fi
  echo "Last B2 snapshot:"
  timeout 25 sudo bash -c 'set -a; . /etc/restic/backup.local 2>/dev/null; set +a; export RESTIC_REPOSITORY="$BACKUP_B2_REPO"; restic snapshots --latest 1 2>/dev/null' \
    | sed 's/^/  /' || echo "  (unreachable or none — try 'backup-snapshots b2')"
}

# List snapshots for a target
backup-snapshots() {
  # Usage: backup-snapshots [b2|external]
  _backup_restic "${1:-b2}" snapshots
}

# Verify repository integrity (uses the profile's check config)
backup-check() {
  # Usage: backup-check [b2|external]
  local target="${1:-b2}"
  confirm "Run integrity check on '$target' (can be slow / costs B2 read API calls)?" || return 1
  _backup_rp --name "$target" check
}

# Guided restore of a snapshot to a fresh ~/restore-<timestamp>/ directory
backup-restore() {
  # Usage: backup-restore [b2|external]
  local target="${1:-b2}" snap dest
  dest="$HOME/restore-$(date +%Y%m%d-%H%M%S)"
  snap="$(_backup_pick_snapshot "$target")"
  confirm "Restore $target snapshot '$snap' into $dest ?" || return 1
  mkdir -p "$dest"
  _backup_restic "$target" restore "$snap" --target "$dest" \
    && sudo chown -R "$USER" "$dest" 2>/dev/null \
    && echo "✓ Restored to $dest"
}

# Browse a repository via FUSE (read-only). Ctrl-C to stop.
backup-mount() {
  # Usage: backup-mount [b2|external]
  local mnt="$HOME/backup-mnt"
  mkdir -p "$mnt"
  echo "Mounting ${1:-b2} at $mnt — browse in another terminal; Ctrl-C here to unmount."
  _backup_restic "${1:-b2}" mount "$mnt"
}

# Unmount the FUSE browse mount
backup-unmount() {
  # Usage: backup-unmount
  fusermount -u "$HOME/backup-mnt" 2>/dev/null || sudo umount "$HOME/backup-mnt" 2>/dev/null
  echo "✓ Unmounted ~/backup-mnt"
}

# Prune B2 with the OFFLINE full-access key (the stored append-only key cannot delete)
backup-prune() {
  # Usage: export B2_FULL_KEY_ID=... B2_FULL_KEY=... ; backup-prune
  echo "B2 prune needs the FULL-access key from your emergency kit (the stored key is append-only)."
  if [[ -z "${B2_FULL_KEY_ID:-}" || -z "${B2_FULL_KEY:-}" ]]; then
    echo "  Export it first:  export B2_FULL_KEY_ID=<keyID>  B2_FULL_KEY=<applicationKey>"
    return 1
  fi
  confirm "Prune B2 with retention (7d/4w/12m/3y) — this permanently deletes old data?" || return 1
  # Feed the full-access key via stdin (NOT argv) so the secret never appears in
  # `ps`/`/proc/<pid>/cmdline`. sudo still reads its password from the tty.
  printf '%s\n%s\n' "$B2_FULL_KEY_ID" "$B2_FULL_KEY" | sudo bash -c '
    IFS= read -r full_id; IFS= read -r full_key
    set -a; . /etc/restic/backup.local 2>/dev/null; set +a
    export RESTIC_REPOSITORY="$BACKUP_B2_REPO"
    export AWS_ACCESS_KEY_ID="$full_id" AWS_SECRET_ACCESS_KEY="$full_key"
    restic forget --prune \
      --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3 --keep-last 3 \
      || exit $?
    # Stamp the prune so backup-doctor can remind when the next one is due.
    install -d /var/lib/restic 2>/dev/null || true
    date +%s > /var/lib/restic/last-b2-prune 2>/dev/null || true'
}

# Re-take the LUKS header backup (store the output in the offline kit)
backup-luks-header() {
  # Usage: backup-luks-header
  local dev out
  dev="$(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print "/dev/"$1; exit}')"
  [[ -n "$dev" ]] || { echo "No crypto_LUKS device found."; return 1; }
  out="$HOME/luks-header-$(hostname)-$(date +%Y%m%d).img"
  confirm "Back up the LUKS header of $dev to $out ?" || return 1
  sudo cryptsetup luksHeaderBackup "$dev" --header-backup-file "$out" \
    && sudo chown "$USER" "$out" \
    && echo "✓ $out — copy this into your OFFLINE emergency kit (re-take after any passphrase change)."
}

# Emergency-kit status + reminder
backup-kit() {
  # Usage: backup-kit
  echo "=== Emergency Kit ==="
  [[ -f ~/.config/age/emergency-kit-identity.txt ]] && echo "✓ age identity present" || echo "✗ no age identity (run backup-setup)"
  [[ -f ~/emergency-kit.age ]] && echo "✓ emergency-kit.age built" \
    || { [[ -f ~/emergency-kit.txt ]] && echo "… emergency-kit.txt drafted (fill, encrypt, shred)" || echo "✗ emergency kit not built (run backup-setup)"; }
  echo "Keep the age identity on PAPER + an OFFLINE USB; keep emergency-kit.age on the USB"
  echo "and inside the restic repo. See docs/BACKUP_AND_RESTORE_GUIDE.md (Disaster Recovery)."
}

# Internal: backup-doctor result emitters. They mutate the globals _BD_FAIL/_BD_WARN
# (backup-doctor resets + unsets them) — separate functions can't share a `local`.
_backup_doctor_ok()   { printf '  ✓ %s\n' "$*"; }
_backup_doctor_warn() { printf '  ⚠ %s\n' "$*"; _BD_WARN=$((_BD_WARN+1)); }
_backup_doctor_bad()  { printf '  ✗ %s\n' "$*"; _BD_FAIL=$((_BD_FAIL+1)); }

# Internal: compare a live /etc file against its ~/.dotfiles source. $1 live, $2 repo, $3 label.
_backup_doctor_cmp() {
  if [[ ! -f "$2" ]]; then _backup_doctor_warn "$3: repo copy not found ($2)"; return; fi
  if sudo cmp -s "$1" "$2"; then _backup_doctor_ok "$3 matches version control"
  else _backup_doctor_warn "$3 differs from ~/.dotfiles — re-run backup-setup to resync (or commit local edits)"; fi
}

# Internal: compare a live /etc file against the RENDERED repo template — the
# same scripts/backup-render.sh substitution backup-setup used at install, so
# templated files don't report permanent drift. Rendered output goes to cmp
# via stdin ("-"), not process substitution: sudo closes fds >2, which breaks
# <(...); sudo is required because /etc/restic is 0700 root.
_backup_doctor_cmp_rendered() {
  if [[ ! -f "$2" ]]; then _backup_doctor_warn "$3: repo copy not found ($2)"; return; fi
  if bash "${HOME}/.dotfiles/scripts/backup-render.sh" "$2" | sudo cmp -s "$1" -; then
    _backup_doctor_ok "$3 matches version control (rendered)"
  else _backup_doctor_warn "$3 differs from the rendered ~/.dotfiles template — re-run backup-setup to resync (or commit local edits)"; fi
}

# Internal: warn if a file is missing or older than N days. $1 file, $2 max-days, $3 label.
_backup_doctor_age_check() {
  if [[ -f "$1" ]]; then
    local d=$(( ( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || date +%s) ) / 86400 ))
    if (( d > $2 )); then _backup_doctor_warn "$3 is ${d}d old (>$2d) — rebuild it"
    else _backup_doctor_ok "$3 present (${d}d old)"; fi
  else
    _backup_doctor_warn "$3 not built — see backup-kit / the guide"
  fi
}

# Internal: backup-doctor's external-HDD section. $1 = ~/.dotfiles, $2 =
# BACKUP_EXTERNAL_UUID, $3 = BACKUP_EXTERNAL_REPO, $4 = its mount point. Split
# out of backup-doctor so its branch selection can be exercised without root or
# a real disk (scripts/test-backup-external.sh); reports through the same
# _BD_FAIL/_BD_WARN globals as every other check.
_backup_doctor_external() {
  local dotfiles="$1" extuuid="$2" extrepo="$3" extmnt="$4"
  local extcfg extunit extrules extfstab
  extcfg="$(sed -n 's/^ConditionPathExists=\(.*\)/\1/p' /etc/systemd/system/restic-backup-external.service 2>/dev/null | tail -1)"

  if [[ -z "$extrepo" ]]; then
    _backup_doctor_warn "BACKUP_EXTERNAL_REPO blank — there is no external target at all (set it in ~/.backup.local, re-run backup-setup)"
  else
    # The unit is gated on ConditionPathExists, so if that path and the
    # configured repo disagree it skips forever regardless of what the disk is
    # doing -- and being skipped is not a failure, so nothing else in the chain
    # would ever say so.
    if [[ -n "$extcfg" && "$extcfg" != "$extrepo/config" ]]; then
      _backup_doctor_bad "restic-backup-external.service gates on $extcfg but the repo is $extrepo — every run is skipped (re-run backup-setup)"
    fi

    # Is it MOUNTED -- not "does a path under the mount point exist". A leftover
    # directory on the internal disk satisfies the latter, and then this reports
    # a healthy external target while writes land on the root filesystem.
    if _backup_external_mounted "$extmnt"; then
      _backup_doctor_ok "external HDD docked ($extmnt)"
    elif _backup_external_attached "$extuuid" "$extmnt"; then
      # Attached but unmounted is the one external fault that looks like
      # success: ConditionPathExists fails, so systemd SKIPS the unit, which is
      # not a failure -- no failed unit, no notification, no healthcheck ping.
      # Reported as a hard fault because nothing else will ever mention it.
      _backup_doctor_bad "external HDD attached but NOT MOUNTED — every scheduled external run is being skipped silently (mount: sudo mount '$extmnt')"
    else
      # Deliberately does not claim B2 has this covered: when this last bit, B2
      # was capped and failing too. Point at the freshness check instead.
      printf '  • external HDD not attached (offsite falls to B2 — see its snapshot freshness above)\n'
    fi

    # Boot-time mountability: without an fstab entry an attached disk reverts to
    # unmounted after every reboot, which lands back in the branch above. Asked
    # of the PARSED table, not grep: a substring match counts a commented-out
    # entry, and one pointing at the wrong mount point, as present.
    #
    # Nested under "a repo is configured" on purpose. Blank UUID *and* blank repo
    # is one non-configuration, and reporting it twice tells someone with no
    # external drive to set up auto-mount for a target that does not exist — in
    # a checker whose worth rests on every line being actionable, that trains
    # readers to skim.
    if [[ -z "$extuuid" ]]; then
      _backup_doctor_warn "BACKUP_EXTERNAL_UUID blank — external HDD cannot be auto-mounted (set it in ~/.backup.local, re-run backup-setup)"
    else
      extfstab="$(_backup_fstab_target_for_uuid "$extuuid")"
      if [[ -z "$extfstab" ]]; then
        _backup_doctor_warn "BACKUP_EXTERNAL_UUID set but absent from /etc/fstab — the disk will not mount after a reboot (re-run backup-setup)"
      elif [[ -n "$extmnt" && "$extfstab" != "$extmnt" ]]; then
        _backup_doctor_bad "/etc/fstab mounts UUID=$extuuid at $extfstab but the repo implies $extmnt — ConditionPathExists can never become true (resolve by hand)"
      else
        _backup_doctor_ok "external HDD has an /etc/fstab entry (mounts at boot)"
      fi
    fi
  fi

  # fstab only covers BOOT. On a laptop the disk leaves and returns with every
  # dock cycle, and without the udev rule each return leaves it unmounted until
  # the next reboot -- landing back in the silent-skip branch above.
  #
  # Compared against the RENDERED repo template rather than grepped for the
  # UUID: the load-bearing half of that rule is the systemd-escaped .mount unit
  # name, which goes stale the moment the repo path changes and yields a rule
  # that still contains the UUID, still passes udevadm verify, and never fires.
  #
  # The unconfigured case is checked too, not gated away. A rule left behind by
  # an earlier install names a UUID that may now belong to a different disk;
  # skipping the check whenever there is nothing to compare against is precisely
  # how that rule stays invisible.
  extrules=/etc/udev/rules.d/99-backup-external.rules
  if [[ -z "$extuuid" || -z "$extmnt" ]]; then
    if sudo test -f "$extrules"; then
      _backup_doctor_warn "$extrules exists but no external HDD is configured — a stale hotplug rule for an unknown disk (re-run backup-setup to remove it)"
    fi
  else
    extunit="$(systemd-escape -p --suffix=mount "$extmnt" 2>/dev/null)"
    if ! sudo test -f "$extrules"; then
      _backup_doctor_warn "no udev hotplug rule — the disk will stay unmounted after an undock/re-dock until reboot (re-run backup-setup)"
    elif env BACKUP_RENDER_EXTERNAL_UUID="$extuuid" BACKUP_RENDER_EXTERNAL_MOUNT_UNIT="$extunit" \
              bash "$dotfiles/scripts/backup-render.sh" "$dotfiles/udev/99-backup-external.rules" 2>/dev/null \
         | sudo cmp -s "$extrules" -; then
      _backup_doctor_ok "external HDD has a udev hotplug rule (remounts on re-dock)"
    else
      _backup_doctor_warn "udev hotplug rule differs from the rendered ~/.dotfiles template (stale mount unit after a repo-path change? hand-edited?) — re-run backup-setup"
    fi
  fi
}

# Full-chain health assertion: is the backup system not just running, but CORRECT?
# Catches the silent lies backup-status can't see (config drift, missing env drop-in,
# stale snapshots, inert alerting, stale recovery assets). Non-zero exit on any FAIL.
backup-doctor() {
  # Usage: backup-doctor
  _BD_FAIL=0 _BD_WARN=0
  local dotfiles="${HOME}/.dotfiles"
  echo "=== Backup Doctor ($(hostname)) ==="
  sudo -v 2>/dev/null || { echo "sudo required (reads /etc/restic, drop-ins, /root)."; return 1; }

  # Every ~/.backup.local value this run needs, read in ONE subshell — see
  # _backup_local_get for why not eight, and why not sourced into this shell.
  local warngb churnmb prunedays hcb hcv hce extuuid extrepo extmnt
  { read -r warngb; read -r churnmb; read -r prunedays
    read -r hcb; read -r hcv; read -r hce
    read -r extuuid; read -r extrepo
  } <<< "$(_backup_local_get BACKUP_B2_SIZE_WARN_GB BACKUP_B2_CHURN_WARN_MB BACKUP_B2_PRUNE_REMIND_DAYS \
                             BACKUP_HC_URL_B2 BACKUP_HC_URL_VERIFY BACKUP_HC_URL_EXTERNAL \
                             BACKUP_EXTERNAL_UUID BACKUP_EXTERNAL_REPO)"
  : "${prunedays:=120}"
  extmnt="${extrepo:+$(dirname "$extrepo")}"

  echo "Config & permissions:"
  if [[ -f ~/.backup.local ]]; then
    local m; m="$(stat -c '%a' ~/.backup.local 2>/dev/null)"
    [[ "$m" == "600" ]] && _backup_doctor_ok "~/.backup.local present (mode $m)" \
      || _backup_doctor_warn "~/.backup.local mode $m (want 600: chmod 600 ~/.backup.local)"
  else
    _backup_doctor_bad "~/.backup.local missing — run backup-init"
  fi
  if sudo test -f /etc/restic/backup.local; then
    local em; em="$(sudo stat -c '%a %U' /etc/restic/backup.local 2>/dev/null)"
    [[ "$em" == "600 root" ]] && _backup_doctor_ok "/etc/restic/backup.local ($em)" \
      || _backup_doctor_warn "/etc/restic/backup.local is '$em' (want '600 root') — re-run backup-setup"
  else
    _backup_doctor_bad "/etc/restic/backup.local missing — run backup-setup"
  fi
  sudo test -s /etc/restic/repo.key && _backup_doctor_ok "/etc/restic/repo.key present" \
    || _backup_doctor_bad "/etc/restic/repo.key missing — backups are UNRECOVERABLE without it"

  echo "Config drift (live /etc vs ~/.dotfiles):"
  _backup_doctor_cmp /etc/resticprofile/profiles.toml "$dotfiles/resticprofile/profiles.toml" "profiles.toml"
  _backup_doctor_cmp_rendered /etc/restic/includes.txt "$dotfiles/examples/backup-includes.txt" "includes.txt"
  _backup_doctor_cmp_rendered /etc/restic/excludes.txt "$dotfiles/examples/backup-excludes.txt" "excludes.txt"

  echo "Scheduled-unit env wiring (DO-448 guard):"
  local t
  for t in resticprofile-backup resticprofile-check; do
    sudo test -f "/etc/systemd/system/${t}@.service.d/10-backup-env.conf" \
      && _backup_doctor_ok "${t}@ EnvironmentFile drop-in present" \
      || _backup_doctor_bad "${t}@ drop-in MISSING — scheduled runs would get an empty repo (re-run backup-setup)"
  done

  echo "Timers:"
  local tmr st
  for tmr in restic-backup-external.timer restic-verify.timer; do
    st="$(systemctl is-enabled "$tmr" 2>/dev/null)"
    [[ "$st" == "enabled" ]] && _backup_doctor_ok "$tmr enabled" \
      || _backup_doctor_warn "$tmr is '${st:-absent}' — run backup-setup"
  done
  systemctl list-timers --all 2>/dev/null | grep -q 'resticprofile-backup' \
    && _backup_doctor_ok "B2 scheduled backup timer present" \
    || _backup_doctor_bad "no resticprofile B2 backup timer — run backup-setup"
  local failed; failed="$(systemctl list-units --state=failed '*restic*' --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  [[ -n "$failed" ]] && _backup_doctor_bad "failed units: $failed(journalctl -u <unit>)"

  echo "Snapshot freshness:"
  local snaptime now age hrs
  snaptime="$(timeout 25 sudo bash -c 'set -a; . /etc/restic/backup.local 2>/dev/null; set +a; export RESTIC_REPOSITORY="$BACKUP_B2_REPO"; restic snapshots --latest 1 --json 2>/dev/null' | grep -o '"time":"[^"]*"' | head -1 | cut -d'"' -f4)"
  if [[ -n "$snaptime" ]]; then
    now="$(date +%s)"; age=$(( now - $(date -d "$snaptime" +%s 2>/dev/null || echo "$now") )); hrs=$(( age / 3600 ))
    if   (( age > 93600 )); then _backup_doctor_bad "latest B2 snapshot is ${hrs}h old (>26h — backups have stopped)"
    elif (( age > 10800 )); then _backup_doctor_warn "latest B2 snapshot is ${hrs}h old (a scheduled 2h run was missed)"
    else _backup_doctor_ok "latest B2 snapshot ${hrs}h old"; fi
  else
    _backup_doctor_warn "could not read latest B2 snapshot (offline? try 'backup-snapshots b2')"
  fi

  echo "Repo size & growth (B2):"
  # The B2 repo is append-only (no scheduled prune), so it grows monotonically —
  # these checks fire BEFORE the Backblaze storage cap does (which kills backups
  # outright: restic can't even write its lock file once the cap is hit).
  local rawsz rawgb
  if [[ -z "$warngb" ]]; then
    _backup_doctor_warn "BACKUP_B2_SIZE_WARN_GB blank — cap-proximity check is INERT (set it in ~/.backup.local)"
  else
    # --no-lock is safe here: stats only reads snapshot/index metadata.
    rawsz="$(timeout 60 sudo bash -c 'set -a; . /etc/restic/backup.local 2>/dev/null; set +a; export RESTIC_REPOSITORY="$BACKUP_B2_REPO"; restic stats --json --mode raw-data --no-lock 2>/dev/null' | grep -o '"total_size":[0-9]*' | cut -d: -f2)"
    if [[ "$rawsz" =~ ^[0-9]+$ ]]; then
      rawgb=$(( rawsz / 1073741824 ))
      if (( rawsz > warngb * 1073741824 )); then
        _backup_doctor_warn "B2 repo raw size ${rawgb}GB exceeds ${warngb}GB — run backup-prune (offline full key) before the Backblaze cap bites"
      else
        _backup_doctor_ok "B2 repo raw size ${rawgb}GB (warn at ${warngb}GB)"
      fi
    else
      _backup_doctor_warn "could not read B2 repo size (offline? try 'backup-snapshots b2')"
    fi
  fi
  # Churn guard: catches a NEW churn source (an app rewriting big blobs between
  # runs) within one run instead of weeks later via the size check. Journal
  # parsing is best-effort — a missing/unparsable line is a neutral note, not a
  # warning we can't substantiate.
  local churnln storedmb
  churnln="$(journalctl -u 'resticprofile-backup@profile-b2.service' --no-pager -n 400 2>/dev/null | grep 'Added to the repository' | tail -1)"
  storedmb="$(printf '%s' "$churnln" | sed -n 's/.*(\([0-9.]*\) \([KMGT]\)iB stored).*/\1 \2/p' \
    | awk '{v=$1; if($2=="K")v/=1024; else if($2=="G")v*=1024; else if($2=="T")v*=1048576; printf "%d", v}')"
  if [[ -z "$churnmb" || -z "$storedmb" ]]; then
    printf '  • no churn reading (journal rotated / no scheduled run yet / BACKUP_B2_CHURN_WARN_MB blank)\n'
  elif (( storedmb > churnmb )); then
    _backup_doctor_warn "last scheduled run stored ${storedmb}MB (>${churnmb}MB) — a new churn source? check excludes (journalctl -u 'resticprofile-backup@profile-b2.service')"
  else
    _backup_doctor_ok "last scheduled run stored ${storedmb}MB (warn at ${churnmb}MB)"
  fi
  # Prune cadence: backup-prune stamps /var/lib/restic/last-b2-prune on success.
  local stamp pdays
  stamp="$(sudo cat /var/lib/restic/last-b2-prune 2>/dev/null)"
  if [[ "$stamp" =~ ^[0-9]+$ ]]; then
    pdays=$(( ( $(date +%s) - stamp ) / 86400 ))
    if (( pdays > prunedays )); then
      _backup_doctor_warn "last B2 prune was ${pdays}d ago (>${prunedays}d) — run backup-prune with the offline full key"
    else
      _backup_doctor_ok "last B2 prune ${pdays}d ago"
    fi
  else
    _backup_doctor_warn "B2 has never been pruned — append-only repos grow monotonically (run backup-prune)"
  fi

  echo "Alerting (healthchecks.io):"
  [[ -n "$hcb" ]] && _backup_doctor_ok "B2 healthcheck URL set" \
    || _backup_doctor_warn "BACKUP_HC_URL_B2 blank — overdue-backup alerting is INERT (set it in ~/.backup.local)"
  [[ -n "$hcv" ]] && _backup_doctor_ok "verify healthcheck URL set" \
    || _backup_doctor_warn "BACKUP_HC_URL_VERIFY blank — weekly verify is not externally monitored"
  # A skipped external run pings nothing, so without this the external target
  # has no dead-man's switch of any kind.
  [[ -n "$hce" ]] && _backup_doctor_ok "external healthcheck URL set" \
    || _backup_doctor_warn "BACKUP_HC_URL_EXTERNAL blank — a silently skipped external run is invisible"

  echo "External HDD:"
  _backup_doctor_external "$dotfiles" "$extuuid" "$extrepo" "$extmnt"

  echo "Recovery assets:"
  [[ -f ~/.config/age/emergency-kit-identity.txt ]] && _backup_doctor_ok "age identity present" \
    || _backup_doctor_bad "age identity missing — cold-start recovery impossible (run backup-setup)"
  # The encrypted kit is meant to live OFFLINE (USB) and inside the repo — not
  # necessarily in $HOME. So only freshness-check a $HOME copy if present; absence
  # is a neutral note (it's likely on the USB), not a warning we can't substantiate.
  if [[ -f ~/emergency-kit.age ]]; then
    _backup_doctor_age_check ~/emergency-kit.age 180 "emergency-kit.age"
  else
    printf '  • emergency-kit.age not in $HOME — OK if it lives on your offline USB / in the repo (rebuild periodically)\n'
  fi
  local lh="/root/luks-header-$(hostname).img"
  if sudo test -s "$lh"; then
    local lmt ld; lmt="$(sudo stat -c %Y "$lh" 2>/dev/null)"; ld=$(( ( $(date +%s) - lmt ) / 86400 ))
    (( ld > 180 )) && _backup_doctor_warn "LUKS header backup is ${ld}d old — re-take after any passphrase change (backup-luks-header)" \
      || _backup_doctor_ok "LUKS header backup present (${ld}d old)"
  else
    _backup_doctor_warn "no LUKS header backup at $lh (run backup-luks-header)"
  fi

  echo "Disk space:"
  # `command df` bypasses the df='df -h' alias (which, on a `source ~/.zshrc`
  # reload, gets baked into this function and breaks `--output=pcent`). `-P` gives
  # portable columns; field 5 is Use%.
  local rootpct; rootpct="$(command df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
  [[ -n "$rootpct" ]] && { (( rootpct > 90 )) && _backup_doctor_warn "root / at ${rootpct}% full" \
    || _backup_doctor_ok "root / at ${rootpct}%"; } \
    || _backup_doctor_warn "could not read root / disk usage"
  # Only when the drive is really mounted: df on an unmounted mount point
  # silently reports the ROOT filesystem's usage, labelled "external HDD".
  if _backup_external_mounted "$extmnt"; then
    local extpct; extpct="$(command df -P "$extmnt" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
    [[ -n "$extpct" ]] && { (( extpct > 90 )) && _backup_doctor_warn "external HDD at ${extpct}% full" \
      || _backup_doctor_ok "external HDD at ${extpct}%"; }
  fi

  echo
  if (( _BD_FAIL > 0 )); then
    echo "✗ ${_BD_FAIL} failure(s), ${_BD_WARN} warning(s) — fix the ✗ items above."
    unset _BD_FAIL _BD_WARN; return 1
  elif (( _BD_WARN > 0 )); then
    echo "⚠ ${_BD_WARN} warning(s), no failures — review the ⚠ items above."
    unset _BD_FAIL _BD_WARN; return 0
  else
    echo "✓ All checks passed — the backup chain is correct end-to-end."
    unset _BD_FAIL _BD_WARN; return 0
  fi
}

# Guarded restore of the /etc slice (+ AWS VPN client) for bare-metal recovery.
# ALWAYS excludes the regenerate-don't-restore set, so it can never produce an
# unbootable system — the one stress-prone step of the DR runbook, made safe.
backup-restore-system() {
  # Usage: backup-restore-system [b2|external] [--in-place]
  local target="b2" inplace=0 a
  for a in "$@"; do
    case "$a" in
      b2|external) target="$a" ;;
      --in-place)  inplace=1 ;;
      *) echo "usage: backup-restore-system [b2|external] [--in-place]" >&2; return 2 ;;
    esac
  done
  local snap dest; snap="$(_backup_pick_snapshot "$target")"
  echo "Excluded (never restored — regenerate on a fresh install):"
  echo "  /etc/fstab  /etc/crypttab  /etc/machine-id  /etc/ssh/ssh_host_*"
  if (( inplace )); then
    dest="/"
    confirm "IN-PLACE restore $target '$snap' onto the LIVE /etc (overwrites current files)?" || return 1
  else
    dest="$HOME/restore-system-$(date +%Y%m%d-%H%M%S)"
    confirm "Restore $target '$snap' (/etc slice) into $dest ?" || return 1
    mkdir -p "$dest"
  fi
  if _backup_restic "$target" restore "$snap" --target "$dest" \
       --include /etc --include /opt/awsvpnclient \
       --exclude /etc/fstab --exclude /etc/crypttab \
       --exclude /etc/machine-id --exclude '/etc/ssh/ssh_host_*'; then
    if (( inplace )); then
      echo "✓ Restored the /etc slice in place (the four boot/identity files were skipped)."
    else
      sudo chown -R "$USER" "$dest" 2>/dev/null
      echo "✓ Restored to $dest — copy what you need from $dest/etc."
      echo "  The four boot/identity files were intentionally skipped; do NOT bulk-copy onto a fresh install."
    fi
  else
    echo "✗ Restore failed." >&2; return 1
  fi
}

# On-demand proof-of-restore: the data half of the quarterly DR drill. Runs the
# content + restore canary (backup-verify.sh) then a quick structural check.
backup-drill() {
  # Usage: backup-drill [b2|external]
  local target="${1:-b2}" vscript=/usr/local/bin/backup-verify.sh v c
  [[ -x "$vscript" ]] || vscript="$HOME/.dotfiles/scripts/backup-verify.sh"
  echo "=== backup-drill ($target) ==="
  sudo "$vscript" "$target"; v=$?
  echo "Structural integrity check ($target)…"
  # `check` needs an EXCLUSIVE lock, so it collides with a concurrent backup
  # (every 2h) or the drill's own restore canary. --retry-lock waits it out; if the
  # repo is still busy after that, that's "busy", NOT an integrity failure — don't
  # cry wolf (the content + restore canary above already proved restorability).
  local checkout
  checkout="$(_backup_restic "$target" check --retry-lock 2m 2>&1)"; c=$?
  printf '%s\n' "$checkout"
  if (( c != 0 )) && grep -qiE 'already locked|unable to create lock' <<<"$checkout"; then
    echo "ℹ Structural check skipped — repo is busy (a backup is running). Re-run when idle; the canary already passed."
    c=0
  fi
  echo
  if [[ $v -eq 0 && $c -eq 0 ]]; then
    echo "✓ Drill passed — restore proven for '$target'."
    echo "  The FULL bare-metal drill (network→vault→HTTPS clone→reinstall) is still manual:"
    echo "  see docs/BACKUP_AND_RESTORE_GUIDE.md (Disaster recovery runbook). Do it quarterly."
    return 0
  fi
  echo "✗ Drill FAILED (verify=$v, check=$c) — investigate before trusting '$target'." >&2
  return 1
}

# Remove restic locks from a target repo after an interrupted run. Plain unlock
# removes only locks restic deems stale; --force removes ALL locks and must be used
# ONLY when no backup/check is running (it can corrupt a concurrent operation).
backup-unlock() {
  # Usage: backup-unlock [b2|external] [--force]
  local target="b2" force=0 a
  for a in "$@"; do
    case "$a" in
      b2|external) target="$a" ;;
      --force)     force=1 ;;
      *) echo "usage: backup-unlock [b2|external] [--force]" >&2; return 2 ;;
    esac
  done
  if (( force )); then
    confirm "Remove ALL locks on '$target'? Do this ONLY if no backup/check is running (it can corrupt a live run)." || return 1
    _backup_restic "$target" unlock --remove-all && echo "✓ Removed all locks on $target."
  else
    _backup_restic "$target" unlock \
      && echo "✓ Cleared stale locks on $target (use 'backup-unlock $target --force' for a stubborn lock when idle)."
  fi
}

# =============================================================================
# Audit Functions (broadcast-kill tripwire)
# =============================================================================
# Thin wrappers over the audit rule installed by scripts/setup-audit-rules.sh
# (run via `audit-setup`). The rule records any real kill(-1, sig) — "signal
# every process I may signal", which on a desktop is the whole session — and the
# audit record names the sender, its exe, cmdline and parent.
#
# Why this exists: a broadcast kill produces a perfectly orderly session
# teardown. No crash, no OOM, no coredump, nothing in the journal explaining it.
# Without this rule there is simply no evidence to find. See
# docs/TROUBLESHOOTING.md ("Desktop session suddenly logged out").
#
# auditd is root-only, so these shell out via sudo.
#
# Functions:
#   - audit-setup:   Install + load the tripwire (idempotent; resyncs after edits)
#   - audit-status:  Is it armed, switched on, recording to disk, and in sync?
#   - audit-sweeps:  Show broadcast-kill events (default: last 24h)
#
# Both readers are built so that "nothing found" can only mean "nothing
# happened". Every way this instrumentation can go quiet — rules rejected,
# auditing switched off, no daemon persisting records, records dropped, /etc
# drifted from the repo, ausearch unable to read the log — is reported as its own
# distinct failure rather than as an all-clear.
# =============================================================================

# Install/refresh the broadcast-kill audit rule. Prefers the repo you are sitting
# in, so running it from a worktree tests THAT branch's script rather than
# whatever ~/.dotfiles happens to be checked out at.
audit-setup() {
  local script="${PWD}/scripts/setup-audit-rules.sh"
  [[ -f "$script" && -f "${PWD}/audit/99-logout-catch.rules" ]] \
    || script="${HOME}/.dotfiles/scripts/setup-audit-rules.sh"
  bash "$script" "$@"
}

# Internal: read one field from `auditctl -s`, which prints "key value" per line
# on audit 3.x but a single "AUDIT_STATUS: key=value ..." line on 2.x. Flatten
# both to one token per line and take the token after the key. $1 raw, $2 key.
_audit_stat_field() {
  printf '%s\n' "$1" | tr '=' ' ' | tr -s '[:space:]' '\n' \
    | awk -v k="$2" 'found { print; exit } $0 == k { found = 1 }'
}

# Is the tripwire actually armed, and is auditd in a state where it would record?
# "Armed" is three independent things, each of which can be false while the other
# two look fine: the rules are in the kernel, auditing is switched on, and a
# daemon is persisting records to disk where ausearch can find them.
audit-status() {
  # NOTE: no local named `status` — that is read-only in zsh.
  if ! command -v auditctl >/dev/null 2>&1; then
    echo "✗ auditd not installed — run: audit-setup"; return 1
  fi
  local rules astat enabled_ pid_ lost_ rc=0
  rules=$(sudo auditctl -l 2>/dev/null | grep -c 'logoutsweep' || true)
  if [[ "${rules:-0}" -lt 1 ]]; then
    echo "✗ tripwire NOT armed (0 rules) — run: audit-setup"; return 1
  fi
  echo "✓ tripwire armed (${rules} rule(s))"

  astat=$(sudo auditctl -s 2>/dev/null || true)
  if [[ -z "$astat" ]]; then
    echo "✗ could not read 'auditctl -s' — cannot confirm auditing is live."; return 1
  fi
  enabled_=$(_audit_stat_field "$astat" enabled)
  pid_=$(_audit_stat_field "$astat" pid)
  lost_=$(_audit_stat_field "$astat" lost)

  # enabled 0 means the rules can never match. enabled 2 is immutable-until-reboot.
  case "${enabled_:-0}" in
    0) echo "✗ kernel auditing is DISABLED (enabled 0) — rules will never match."
       echo "  Fix: sudo auditctl -e 1"; rc=1 ;;
    2) echo "✓ auditing enabled (immutable until reboot)" ;;
    *) echo "✓ auditing enabled" ;;
  esac

  # pid 0 = no daemon holds the netlink socket, so records go to the kernel ring
  # buffer instead of /var/log/audit/audit.log. `auditctl -l` still lists the
  # rules, so this reads as "armed" while audit-sweeps is permanently blind.
  if [[ "${pid_:-0}" == "0" ]]; then
    echo "✗ NO audit daemon registered (pid 0) — nothing is being written to disk."
    echo "  Rules are loaded but audit-sweeps will report nothing regardless."
    echo "  Fix: sudo systemctl enable --now auditd"; rc=1
  else
    echo "✓ recording to disk (auditd pid ${pid_}, $(systemctl is-active auditd 2>/dev/null))"
  fi

  # A climbing `lost` counter means records were dropped — and a dropped record
  # looks exactly like a quiet machine.
  if [[ -n "$lost_" && "$lost_" != "0" ]]; then
    echo "⚠ lost records: ${lost_}  ← RECORDS DROPPED (raise backlog_limit)"
  else
    echo "✓ lost records: 0"
  fi

  # The rules file is copied, not symlinked, so editing the repo copy leaves /etc
  # stale with no signal. Same drift check backup-doctor does for /etc/restic.
  local repo_rules="${HOME}/.dotfiles/audit/99-logout-catch.rules"
  local live_rules=/etc/audit/rules.d/99-logout-catch.rules
  if [[ ! -f "$repo_rules" ]]; then
    echo "⚠ repo copy not found (${repo_rules}) — cannot check for drift"
  elif sudo cmp -s "$live_rules" "$repo_rules" 2>/dev/null; then
    echo "✓ rules file matches version control"
  else
    echo "⚠ ${live_rules} differs from ~/.dotfiles — re-run audit-setup to resync"
    echo "  (or commit the local edits)"
  fi

  # /var filling up is the remaining silent stop, and it is a config policy we
  # deliberately leave at SUSPEND rather than a value we can read back.
  # `command df` bypasses the df='duf' / df='df -h' aliases, which on a
  # `source ~/.zshrc` reload get baked into this function and silently produce
  # nothing (DO-450 fixed exactly this in backup-doctor). Reporting "unknown" for
  # the one signal that catches auditd's silent SUSPEND would defeat the point.
  # `-P` gives portable columns; field 4 is Avail.
  local varfree
  varfree=$(command df -Ph /var 2>/dev/null | awk 'NR==2{print $4}')
  echo "  note: disk_full/admin_space actions are SUSPEND — auditd stops logging"
  echo "        (silently) if /var runs low. /var avail: ${varfree:-unknown}"
  return $rc
}

# Show broadcast-kill events. Optional arg: hours to look back (default 24).
audit-sweeps() {
  local hours="${1:-24}" date_ time_ raw err count rc
  command -v ausearch >/dev/null 2>&1 || { echo "✗ auditd not installed — run: audit-setup"; return 1; }
  # Reject junk up front: a non-numeric arg makes `date` fail, leaving an empty
  # window that ausearch answers with "nothing found" — a clean bill of health
  # for a query that never ran.
  if [[ ! "$hours" =~ ^[0-9]+$ ]] || (( hours == 0 )); then
    echo "✗ usage: audit-sweeps [hours]  — a positive integer (default 24)" >&2
    return 2
  fi
  # ausearch -ts takes the date and the time as TWO arguments. Passing them as a
  # single quoted string matches nothing and prints no error — indistinguishable
  # from "no events", which is the worst possible failure for a tripwire reader.
  date_=$(date -d "-${hours} hours" "+%m/%d/%Y")
  time_=$(date -d "-${hours} hours" "+%H:%M:%S")

  # Keep stderr. ausearch exits non-zero both for "no matches" (normal) and for
  # real errors (log unreadable, sudo refused, auditd never started so
  # /var/log/audit/audit.log does not exist). Discarding stderr would make a
  # broken query look exactly like a quiet machine — the failure this whole
  # feature exists to prevent.
  err=$(mktemp) || return 1
  raw=$(sudo ausearch -k logoutsweep -ts "$date_" "$time_" -i 2>"$err"); rc=$?
  count=$(printf '%s\n' "$raw" | grep -c '^type=SYSCALL' || true)
  echo "Window: ${date_} ${time_} onward — ${count} record(s)."

  # "no matches" is the one non-zero exit that is good news; anything else that
  # produced no records is an unanswered question, not an all-clear.
  if (( rc != 0 )) && ! grep -qi 'no matches' "$err"; then
    echo "✗ ausearch failed (exit ${rc}) — this is NOT an all-clear:" >&2
    sed 's/^/    /' "$err" >&2
    rm -f "$err"
    echo "  Confirm the tripwire is recording with: audit-status" >&2
    return 1
  fi
  # Surface anything else ausearch said, but not its benign "<no matches>".
  local notes; notes=$(grep -vi 'no matches' "$err" 2>/dev/null)
  [[ -n "$notes" ]] && printf '%s\n' "$notes" | sed 's/^/  note: /'
  rm -f "$err"

  if [[ "${count:-0}" -eq 0 ]]; then
    echo "✓ No broadcast kills. (If this is unexpected, confirm with: audit-status)"
    return 0
  fi
  printf '%s\n' "$raw" | grep '^type=SYSCALL'
  echo
  echo "Each line names the sender (pid/ppid/comm/exe). A burst from pid 1"
  echo "(systemd-shutdown) at a reboot is normal; anything else is not."
}
