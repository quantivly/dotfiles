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
#   - backup-prune:        Prune B2 with the OFFLINE full key (append-only key can't)
#   - backup-luks-header:  Re-take the LUKS header backup
#   - backup-kit:          Emergency-kit status + reminder
# =============================================================================

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

# Run a backup now. Default 'cilantro' group = both targets (b2 first, so the
# offsite copy completes even when the external HDD is not docked). For the
# default group, the external target is skipped when the drive isn't docked —
# otherwise it would fail and fire a false "Backup FAILED" alert + healthcheck
# /fail ping. An explicit `backup-now external` still runs (and reports) as asked.
backup-now() {
  # Usage: backup-now [b2|external|cilantro]
  local target="${1:-cilantro}"
  if [[ "$target" == "cilantro" ]]; then
    local extrepo=""
    [[ -r ~/.backup.local ]] && \
      extrepo="$(. ~/.backup.local 2>/dev/null; printf '%s' "${BACKUP_EXTERNAL_REPO:-}")"
    if [[ -z "$extrepo" || ! -e "$extrepo/config" ]]; then
      echo "External HDD not docked — backing up to B2 only (run 'backup-now external' once docked)."
      target="b2"
    fi
  fi
  _backup_rp --name "$target" backup
}

# Quick health summary of the backup system
backup-status() {
  # Usage: backup-status
  echo "=== Backup Status (cilantro) ==="
  if [[ -f ~/.backup.local ]]; then echo "Config:     ~/.backup.local present"; else
    echo "Config:     ✗ missing — run 'backup-init', edit it, then 'backup-setup'"; return 1; fi
  echo "restic:     $(restic version 2>/dev/null | head -1 || echo 'not installed')"
  echo "profile:    $(resticprofile version 2>/dev/null | head -1 || echo 'resticprofile not installed')"
  echo "Timers:"
  systemctl list-timers --all 2>/dev/null | grep -iE 'restic|NEXT' | sed 's/^/  /' || echo "  (none — run backup-setup)"
  echo "External timer: $(systemctl is-enabled restic-backup-external.timer 2>/dev/null || echo 'n/a — run backup-setup')"
  local extcfg; extcfg="$(sed -n 's/^ConditionPathExists=\(.*\)/\1/p' /etc/systemd/system/restic-backup-external.service 2>/dev/null)"
  if [[ -n "$extcfg" ]] && sudo test -e "$extcfg" 2>/dev/null; then
    echo "External:   docked ✓ ($extcfg present)"
  else
    echo "External:   not docked / external repo not reachable"
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
    exec restic forget --prune \
      --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3 --keep-last 3'
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

# Full-chain health assertion: is the backup system not just running, but CORRECT?
# Catches the silent lies backup-status can't see (config drift, missing env drop-in,
# stale snapshots, inert alerting, stale recovery assets). Non-zero exit on any FAIL.
backup-doctor() {
  # Usage: backup-doctor
  _BD_FAIL=0 _BD_WARN=0
  local dotfiles="${HOME}/.dotfiles"
  echo "=== Backup Doctor (cilantro) ==="
  sudo -v 2>/dev/null || { echo "sudo required (reads /etc/restic, drop-ins, /root)."; return 1; }

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
  _backup_doctor_cmp /etc/restic/includes.txt "$dotfiles/examples/backup-includes.txt" "includes.txt"
  _backup_doctor_cmp /etc/restic/excludes.txt "$dotfiles/examples/backup-excludes.txt" "excludes.txt"

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

  echo "Alerting (healthchecks.io):"
  local hcb hcv
  hcb="$(. ~/.backup.local 2>/dev/null; printf '%s' "${BACKUP_HC_URL_B2:-}")"
  hcv="$(. ~/.backup.local 2>/dev/null; printf '%s' "${BACKUP_HC_URL_VERIFY:-}")"
  [[ -n "$hcb" ]] && _backup_doctor_ok "B2 healthcheck URL set" \
    || _backup_doctor_warn "BACKUP_HC_URL_B2 blank — overdue-backup alerting is INERT (set it in ~/.backup.local)"
  [[ -n "$hcv" ]] && _backup_doctor_ok "verify healthcheck URL set" \
    || _backup_doctor_warn "BACKUP_HC_URL_VERIFY blank — weekly verify is not externally monitored"

  echo "Recovery assets:"
  local extcfg; extcfg="$(sed -n 's/^ConditionPathExists=\(.*\)/\1/p' /etc/systemd/system/restic-backup-external.service 2>/dev/null)"
  if [[ -n "$extcfg" ]] && sudo test -e "$extcfg"; then _backup_doctor_ok "external HDD docked"
  else printf '  • external HDD not docked (normal — B2 covers offsite)\n'; fi
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
  if [[ -n "$extcfg" ]] && sudo test -e "$extcfg"; then
    local extpct; extpct="$(command df -P "$(dirname "$extcfg")" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
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
  _backup_restic "$target" check; c=$?
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
