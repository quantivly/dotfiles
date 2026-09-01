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
#   - _doctor_*: shared ✓/✗/⚠/· emitters + summary for the doctor commands
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

# -----------------------------------------------------------------------------
# Doctor report emitters (shared by dotfiles-doctor and backup-doctor)
# -----------------------------------------------------------------------------
# One implementation, because there were two identical ones: a fix here (routing
# ✗ to stderr, honouring NO_COLOR, changing the summary wording) previously had
# to be made in both and would have been forgotten in one.
#
# The counters are deliberately NOT globals. zsh — like bash — scopes locals
# dynamically, so a callee assigning to _DOCTOR_FAIL writes the *caller's*
# declaration. Every doctor therefore opens with
#
#     local _DOCTOR_FAIL=0 _DOCTOR_WARN=0
#
# which keeps them out of every interactive shell (the old globals leaked into
# each one) and gives a nested call its own count instead of corrupting the
# outer one. Forgetting that line does not silently lose counts — it recreates
# the leak, which is what the state table asserts against.
_doctor_ok()   { printf '  ✓ %s\n' "$*"; }
_doctor_bad()  { printf '  ✗ %s\n' "$*"; _DOCTOR_FAIL=$((_DOCTOR_FAIL+1)); }
_doctor_warn() { printf '  ⚠ %s\n' "$*"; _DOCTOR_WARN=$((_DOCTOR_WARN+1)); }
# A fact worth showing that is not a finding: an expected-dirty file, a link
# that is conditional and correctly absent. Counted as neither, because a
# checker that reports normal states as warnings is one people stop reading.
_doctor_note() { printf '  · %s\n' "$*"; }

# Closing verdict. Exit status is the doctor's: non-zero iff a ✗ was emitted.
# Usage: _doctor_summary <all-clear-message> [fix-hint]
_doctor_summary() {
  if (( _DOCTOR_FAIL > 0 )); then
    printf '✗ %d failure(s), %d warning(s) — fix the ✗ items above.\n' "$_DOCTOR_FAIL" "$_DOCTOR_WARN"
    [[ -n "${2:-}" ]] && printf '  %s\n' "$2"
    return 1
  fi
  if (( _DOCTOR_WARN > 0 )); then
    printf '⚠ %d warning(s), no failures — review the ⚠ items above.\n' "$_DOCTOR_WARN"
    return 0
  fi
  printf '✓ %s\n' "$1"
  return 0
}

# -----------------------------------------------------------------------------
# Login-group umask guard
# -----------------------------------------------------------------------------
# Ubuntu's pam_umask relaxes the umask from 022 to 002 when the login group is a
# "user private group" — same name as the user — on the reasoning that group
# permissions are then permissions for yourself alone. Sound reasoning, and
# false on this machine: `getent group zvi` returned `zvi:x:1000:quantivly`, so
# the group named after the user had a second member, and under umask 002 nearly
# every file the user created — $HOME dotfiles included — was group-writable by
# a service account (uid 242, /bin/sh, never logged in). `.zshenv` that way is a
# code-execution path, not just a disclosure one.
#
# The real defect is that extra member, and removing it is the fix:
#
#     sudo gpasswd -d <service-account> <login-group>
#
# This is the belt to that braces: while any OTHER account is in the login
# group, refuse the relaxed umask.
#
# GATED ON THE CONDITION, NOT ON THE ORDER the fixes were applied in.
# `dev-setup` adds the service account to the user's group deliberately
# (modules/system.sh) because workspaces are meant to be shared through it — so
# a blanket `umask 022` in a repo that installs on other people's machines would
# silently break that sharing, on exactly the hosts where the grant is real.
# Asking whether the group is actually shared answers correctly for every host,
# needs no ordering discipline, and stops tightening by itself the moment the
# grant is removed. It is also the one form that cannot go stale: it re-reads
# the answer every shell instead of encoding one machine's state in a config.
#
# Forkless — `$(<file)` does not fork in zsh, and `$GID` is a shell parameter —
# because this runs in every interactive shell.
#
# SCOPE, stated because the paragraphs above could be read as a guarantee:
# `zshrc` is sourced only by INTERACTIVE shells, so `zsh -c …`, systemd --user
# units, GUI applications and cron keep whatever pam_umask handed them. This is
# a belt, and a partial one; removing the extra group member is the braces and
# the actual fix. Covering the rest would mean owning `~/.zshenv` — which is
# also where DOTFILES_UMASK goes, and which this repo deliberately does not
# install, since it is machine-local.
#
# "Cannot tell" (no /etc/group entry: SSSD, systemd-homed) leaves the umask
# exactly as the system set it and says so. Guessing in either direction is
# worse than the state the machine is already in: tightening breaks sharing that
# may be load-bearing, relaxing re-creates the exposure.
#
# It only ever RESTRICTS. `umask 022` is an absolute assignment, so on a host
# already hardened to 077 a guard installed to tighten silently LOOSENED the
# mask — and dotfiles-doctor printed that as `✓ 022`. The verdict is now OR-ed
# into the current value.
#
# Override: DOTFILES_UMASK=<mask> in ~/.zshenv, which loads before zshrc.
#
# The decision is separate from the application so dotfiles-doctor can ask
# without doing: a read-only health check that resets the umask of the shell it
# is run in is the predicate-with-side-effects shape, and would quietly undo a
# `umask 077` the user set before handling something sensitive.
_dotfiles_umask_verdict() {
  # Usage: _dotfiles_umask_verdict   (pure — reads nothing but /etc/group)
  # Sets:  _DOTFILES_UMASK_MODE = "" | explicit | restrict
  #        _DOTFILES_UMASK_WANT = "" | the mask an `explicit` verdict applies
  #        _DOTFILES_UMASK_WHY  = one line, for dotfiles-doctor and humans
  # Returns non-zero when it could not determine the answer, INCLUDING when an
  # explicit override is not a usable mask — the validity of DOTFILES_UMASK is
  # part of the verdict, not of applying it. Leaving it to the guard meant the
  # doctor, which only asks for the verdict, called a nonsense override ✓.
  local grpfile="${DOTFILES_GROUP_FILE:-/etc/group}"
  local line me="${USERNAME:-${LOGNAME:-$USER}}"
  local -a fields others
  _DOTFILES_UMASK_MODE=""; _DOTFILES_UMASK_WANT=""; _DOTFILES_UMASK_WHY=""

  if [[ -n "${DOTFILES_UMASK:-}" ]]; then
    # Validity is only knowable by trying it, so try it somewhere harmless. One
    # fork, only when the override is set.
    if ( umask "$DOTFILES_UMASK" ) 2>/dev/null; then
      _DOTFILES_UMASK_MODE=explicit
      _DOTFILES_UMASK_WANT="$DOTFILES_UMASK"
      _DOTFILES_UMASK_WHY="\$DOTFILES_UMASK=$DOTFILES_UMASK — set explicitly"
      return 0
    fi
    _DOTFILES_UMASK_WHY="\$DOTFILES_UMASK='$DOTFILES_UMASK' is not a valid mask — ignored, umask left as the system set it"
    return 1
  fi

  if [[ ! -r "$grpfile" ]]; then
    _DOTFILES_UMASK_WHY="cannot read $grpfile — umask left as the system set it"
    return 1
  fi

  for line in ${(f)"$(<$grpfile)"}; do
    fields=( "${(@s.:.)line}" )
    [[ "${fields[3]:-}" == "$GID" ]] || continue
    # Being listed in your own group is not sharing.
    others=( ${(s.,.)${fields[4]:-}} )
    others=( ${others:#$me} )
    if (( ${#others} )); then
      _DOTFILES_UMASK_MODE=restrict
      _DOTFILES_UMASK_WHY="at least 022 — login group '${fields[1]}' also contains ${(j:, :)others}, so group-write is write access for someone else"
    else
      _DOTFILES_UMASK_WHY="left as the system set it — login group '${fields[1]}' has no other members"
    fi
    return 0
  done

  _DOTFILES_UMASK_WHY="no $grpfile entry for gid $GID — umask left as the system set it"
  return 1
}

_dotfiles_umask_guard() {
  # Usage: _dotfiles_umask_guard   (call from zshrc; APPLIES the verdict)
  # Sets:  _DOTFILES_UMASK_WHY, as above.
  local rc
  local _DOTFILES_UMASK_MODE _DOTFILES_UMASK_WANT
  _dotfiles_umask_verdict; rc=$?
  (( rc == 0 )) || return $rc

  if [[ "$_DOTFILES_UMASK_MODE" == "explicit" ]]; then
    # Already proven applicable by the verdict, so this cannot emit an error —
    # which matters because it runs during initialisation, where output lands
    # inside p10k's instant-prompt warning box.
    umask "$_DOTFILES_UMASK_WANT"
    return 0
  fi
  [[ "$_DOTFILES_UMASK_MODE" == "restrict" ]] || return 0

  # Restrict, never relax — as a SYMBOLIC mask, which is the whole answer.
  #
  # The numeric route needed the current value (a `$(umask)` fork, in a function
  # whose own comment claims to be forkless because it runs in every shell) and
  # then an OR, which brought its own trap: `$(( 8#077 | 8#022 ))` is 63
  # DECIMAL while `umask` parses a bare number as OCTAL, so passing it through
  # set 0o63 on a host at 077 — a further silent loosening by the guard meant to
  # harden — and errored `bad umask` from 002, where the decimal 18 is not valid
  # octal. `umask g-w,o-w` denies exactly those bits relative to whatever is
  # already set: 002→022, 022→022, 077→077, 007→027. No read, no arithmetic, no
  # base confusion, and nothing to get wrong a third time.
  umask g-w,o-w
  return 0
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
# Dotfiles Live-Config Guard
# =============================================================================
# ~/.dotfiles is installed with dotbot `link:` — every managed file is a SYMLINK
# into the working tree (~/.zshrc, ~/.gitconfig, ~/.config/git/ignore, the gh
# account configs, the Claude statusline hook, the herdr server unit). Nothing
# is copied. So `git checkout` in this repo is not a branch switch, it is a
# DEPLOY: the instant HEAD moves, every one of those files changes under the
# running system — no install step, no restart, no log line, and `git status`
# stays clean throughout.
#
# Both directions have caused real failures, both on 2026-08-31:
#
#   behind the default branch — the checkout predated PR #87, so backup-doctor
#     was still printing "external HDD not docked (normal — B2 covers offsite)".
#     That is the exact false reassurance which had already let a backup outage
#     run unnoticed; it was found, fixed, reviewed and merged, and still not
#     running, because nothing re-pointed the symlink target at the fix.
#
#   ahead of it — ~830 lines of an open, unmerged, unreviewed PR's
#     zshrc.company were being sourced by every new interactive shell.
#
# The remedy is a convention plus this guard: the PRIMARY checkout stays pinned
# to the default branch, and feature work happens in `git worktree`s, which no
# symlink points into. `dotfiles-work` creates them, `dotfiles-doctor` reports
# the state, and a one-line warning at shell startup catches the rest — sited
# where the damage actually lands, which is a new shell sourcing whatever the
# working tree happens to hold.
#
# EVERY assertion here is about a state that otherwise looks like success, so
# each one has to survive the question "what does this print when the thing it
# reads is broken?". A missing ref, an unparseable link map, a stale
# remote-tracking ref, a git that cannot run at all, and a symlink pointing into
# somebody else's worktree all produce an *empty* result, and empty reads as
# clean. Where a check cannot answer, it says so; it never returns the answer it
# would have given if everything were fine.
#
# Functions:
#   - dotfiles-work:   create/enter a worktree instead of moving the checkout
#   - dotfiles-doctor: pin state, drift vs the default branch, blast radius
#   - _dotfiles_*:     internals; see each for why it is factored out
# =============================================================================

# The branch the primary checkout must stay on, and where that checkout lives.
# Overridable for a fork, a differently-named default branch, or a test rig.
: "${DOTFILES_PIN_BRANCH:=main}"
: "${DOTFILES_ROOT:=${HOME}/.dotfiles}"

# How old origin/<pin> may be before "not behind" stops meaning anything. This
# machine fetches only when a human types `git fetch`, so the ref can be weeks
# stale while every comparison against it still returns "clean".
: "${DOTFILES_FETCH_MAX_AGE_HOURS:=24}"

# How old origin/<pin> may get before the STARTUP guard says so. Deliberately
# far more forgiving than DOTFILES_FETCH_MAX_AGE_HOURS above: the doctor is
# something you run when you want an answer, so qualifying a day-old ref there
# costs nothing, whereas this fires unasked at a prompt and a line that shows up
# every morning is a line people stop reading. A week without fetching, in a
# repo whose premise is that merged fixes must actually be running, earns one.
: "${DOTFILES_STALE_WARN_HOURS:=168}"

# Working-tree paths whose modification is the documented normal state, so the
# doctor reports them as notes rather than warnings. `herdr-lazy sync` writes
# plugins.lock straight through its symlink into the repo — install.conf.yaml
# says so at the link itself. Space-separated; extend in ~/.zshrc.local — or
# set it as a zsh array there if any path of yours contains a space.
: "${DOTFILES_EXPECTED_DIRTY:=config/herdr/plugins/plugins.lock}"

# Which directory holds this checkout's git metadata — and is this checkout one
# whose files are live at all? `.git` is a DIRECTORY in an ordinary clone but a
# FILE holding "gitdir: <path>" in two other layouts, and those two must not be
# lumped together:
#
#   linked worktree     gitdir points into <primary>/.git/worktrees/<name>, which
#                       git marks with a `commondir` file. Nothing in a worktree
#                       is live — no symlink points there — so no git dir is
#                       returned and every caller answers "unknown", correctly.
#   --separate-git-dir  gitdir points at an ordinary repository elsewhere. This
#                       IS a primary checkout and all of it is live.
#
# Telling them apart by `[[ -f .git ]]` alone puts the second in the first's
# bucket, which made `./install` refuse and `dotfiles-doctor` return 1 on every
# run for such a clone — a permanently-red checker, which this file argues at
# length is a permanently-ignored one.
#
# Forkless, because the startup path calls it. `commondir` is git's own on-disk
# marker for a linked worktree (gitrepository-layout(5)), not a heuristic.
_dotfiles_git_dir() {
  # Usage: _dotfiles_git_dir <checkout-root>
  # Sets:  _DOTFILES_GIT_DIR  = <path> when this is a primary checkout, else ""
  #        _DOTFILES_GIT_KIND = primary | separate | worktree | none
  # Returns non-zero exactly when _DOTFILES_GIT_DIR is empty.
  local root="${1:-}" line=""
  _DOTFILES_GIT_DIR=""
  _DOTFILES_GIT_KIND="none"
  [[ -n "$root" ]] || return 1
  if [[ -d "$root/.git" ]]; then
    _DOTFILES_GIT_DIR="$root/.git"
    _DOTFILES_GIT_KIND="primary"
    return 0
  fi
  [[ -f "$root/.git" && -r "$root/.git" ]] || return 1
  read -r line < "$root/.git" 2>/dev/null
  [[ "$line" == "gitdir: "* ]] || return 1
  line="${line#gitdir: }"
  [[ -n "$line" ]] || return 1
  [[ "$line" == /* ]] || line="$root/$line"
  if [[ -e "$line/commondir" ]]; then
    _DOTFILES_GIT_KIND="worktree"
    return 1
  fi
  [[ -d "$line" ]] || return 1
  _DOTFILES_GIT_DIR="$line"
  _DOTFILES_GIT_KIND="separate"
  return 0
}

# Read HEAD without forking. This runs on EVERY interactive shell start, so it
# must not cost a process: `git symbolic-ref` is a few ms that every shell, on
# every machine, pays forever. One file read costs nothing measurable. Sets a
# global rather than echoing for the same reason — a command substitution is a
# fork, which is the cost being avoided. Callers that do not want it in their
# shell declare it `local` and get it by dynamic scope (see _doctor_ok above).
#
# This deliberately reads a PRIMARY checkout's HEAD only: _dotfiles_git_dir
# declines for a linked worktree, so this reports "unknown" from inside one —
# which is correct, since no symlink points into a worktree.
_dotfiles_head_state() {
  # Usage: _dotfiles_head_state <checkout-root>
  # Sets:  _DOTFILES_HEAD = "branch <name>" | "detached <sha>" | "unknown"
  local head_file="" line=""
  local _DOTFILES_GIT_DIR _DOTFILES_GIT_KIND
  _DOTFILES_HEAD="unknown"
  _dotfiles_git_dir "${1:-}" || return 0
  head_file="$_DOTFILES_GIT_DIR/HEAD"
  [[ -r "$head_file" ]] || return 0
  # No `|| return` on the read: an empty HEAD makes `read` exit non-zero with
  # $line empty, and a HEAD holding only a newline makes it exit zero with $line
  # empty. Both are the same answer, so both fall through to the "" case below.
  # (An earlier version returned early on read failure, which left that case
  # unreachable — and therefore untested while appearing tested.)
  read -r line < "$head_file" 2>/dev/null
  case "$line" in
    "ref: refs/heads/"*) _DOTFILES_HEAD="branch ${line#ref: refs/heads/}" ;;
    "")                  _DOTFILES_HEAD="unknown" ;;
    *)                   _DOTFILES_HEAD="detached ${line}" ;;
  esac
}

# Read a ref's sha, also without forking, and also from the primary checkout
# only. Two storage forms exist and both must be handled: a loose file under
# .git/refs/, and a line in .git/packed-refs after git has packed them. Handling
# only the loose form would make the caller below silently stop checking on any
# repo that has been gc'd — passing forever, for a reason nobody would look for.
_dotfiles_ref_sha() {
  # Usage: _dotfiles_ref_sha <checkout-root> <ref>  (e.g. refs/heads/main)
  # Sets:  _DOTFILES_REF_SHA = <sha> | "" when the ref cannot be read
  local root="${1:-}" ref="${2:-}" line="" gd=""
  local _DOTFILES_GIT_DIR _DOTFILES_GIT_KIND
  _DOTFILES_REF_SHA=""
  [[ -n "$root" && -n "$ref" ]] || return 0
  _dotfiles_git_dir "$root" || return 0
  gd="$_DOTFILES_GIT_DIR"
  if [[ -r "$gd/$ref" ]]; then
    read -r line < "$gd/$ref" 2>/dev/null
    _DOTFILES_REF_SHA="${line%% *}"
    return 0
  fi
  [[ -r "$gd/packed-refs" ]] || return 0
  # A peeled-tag line ("^<sha>") and the header comment carry no ref name, so
  # matching on the trailing " <ref>" skips them without a special case.
  while read -r line; do
    if [[ "$line" == *" $ref" ]]; then
      _DOTFILES_REF_SHA="${line%% *}"
      return 0
    fi
  done < "$gd/packed-refs"
  return 0
}

# Is the pinned branch at the same commit as its remote-tracking ref? Being ON
# main is not the same as being UP TO DATE with main, and "behind" is the
# direction that caused the #87 outage — a merged, reviewed fix that was simply
# not running. Two more forkless file reads, so the startup path can check it.
#
# It cannot say WHICH direction without git (that needs a merge base), so it
# does not claim one. "unknown" whenever either ref is unreadable — including
# from inside a worktree, and on a fresh clone with no remote-tracking ref yet.
#
# Equal shas are NOT by themselves an all-clear, which is the trap this used to
# fall into. Both are read off local disk, so they agree the instant the machine
# stops fetching — permanently, and most emphatically on a machine that has
# never fetched since the fix it is missing was merged. That is #87 exactly, and
# it is reported as "stale", not "same": the comparison is only as good as the
# ref, so the age of the ref is part of the answer.
_dotfiles_pin_divergence() {
  # Usage: _dotfiles_pin_divergence <checkout-root> <pin-branch>
  # Sets:  _DOTFILES_DIVERGED = same | differs | stale | unknown
  #        _DOTFILES_FETCH_AGE_H (via _dotfiles_fetch_age_hours) for the caller
  local root="${1:-}" pin="${2:-}" local_sha="" remote_sha=""
  local _DOTFILES_REF_SHA
  _DOTFILES_DIVERGED="unknown"
  [[ -n "$root" && -n "$pin" ]] || return 0
  _dotfiles_ref_sha "$root" "refs/heads/$pin";          local_sha="$_DOTFILES_REF_SHA"
  _dotfiles_ref_sha "$root" "refs/remotes/origin/$pin"; remote_sha="$_DOTFILES_REF_SHA"
  [[ -n "$local_sha" && -n "$remote_sha" ]] || return 0
  if [[ "$local_sha" != "$remote_sha" ]]; then
    _DOTFILES_DIVERGED="differs"
    return 0
  fi
  # Same sha: now ask how old the ref that produced it is. Unreadable age stays
  # "unknown" rather than falling back to "same" — an unanswerable question must
  # not resolve to the answer it would have had if everything were fine.
  if ! _dotfiles_fetch_age_hours "$root" "$pin"; then
    _DOTFILES_DIVERGED="unknown"
  elif (( _DOTFILES_FETCH_AGE_H > DOTFILES_STALE_WARN_HOURS )); then
    _DOTFILES_DIVERGED="stale"
  else
    _DOTFILES_DIVERGED="same"
  fi
}

# The decision itself, split from both the reading and the printing so the state
# table in scripts/test-dotfiles-guard.sh can drive every case directly, without
# building a repo per case. The bug class this guard exists to catch is "a guard
# that only misfires in a state the author's machine was not in at the time", so
# every verdict must be reachable without first getting the machine into it.
_dotfiles_guard_verdict() {
  # Usage: _dotfiles_guard_verdict "<head-state>" "<pin-branch>"
  # Sets:  _DOTFILES_VERDICT = ok | "off-pin <branch>" | "detached <sha>" | unknown
  local state="$1" pin="$2"
  if [[ -z "$pin" ]]; then
    _DOTFILES_VERDICT="unknown"
    return 0
  fi
  case "$state" in
    "branch $pin") _DOTFILES_VERDICT="ok" ;;
    "branch "*)    _DOTFILES_VERDICT="off-pin ${state#branch }" ;;
    "detached "*)  _DOTFILES_VERDICT="$state" ;;
    *)             _DOTFILES_VERDICT="unknown" ;;
  esac
}

# The startup line. Silence with DOTFILES_GUARD_QUIET=1 — a deliberate opt-out
# for knowingly dogfooding a branch, which is legitimate and should be possible
# without noise on every shell.
#
# "unknown" is silent by design: a machine without this repo, a fresh clone
# mid-install, and a shell inside a worktree are all normal states, and a guard
# that cries wolf in normal states is one people learn to ignore.
_dotfiles_live_config_warn() {
  [[ -n "${DOTFILES_GUARD_QUIET:-}" ]] && return 0
  # Locals, so the helpers' results reach this function by dynamic scope and
  # then vanish, instead of parking four _D* variables in every shell.
  local _DOTFILES_HEAD _DOTFILES_VERDICT _DOTFILES_DIVERGED _DOTFILES_FETCH_AGE_H

  # First: does the shell being started actually come from the checkout every
  # other line below reads? `./install` run from a worktree re-points every
  # managed symlink at a feature branch, and the branch checks are then reporting
  # on a tree that is no longer live — silently, which is how one stray
  # ./install defeated the whole feature. `install` now refuses, but a machine
  # already in that state has to be told. `:A` resolves the link in-shell, so
  # this is still forkless. Only meaningful when ~/.zshrc IS a symlink and
  # DOTFILES_ROOT is a checkout; a copied or hand-written ~/.zshrc is somebody
  # else's arrangement and gets no opinion.
  if [[ -L "${HOME}/.zshrc" && -d "${DOTFILES_ROOT}/.git" ]]; then
    local live_zshrc="${${:-${HOME}/.zshrc}:A}" root_real="${${:-${DOTFILES_ROOT}}:A}"
    if [[ "$live_zshrc" != "$root_real"/* ]]; then
      printf '\033[0;33m⚠ dotfiles: this shell was sourced from %s\033[0m\n' "$live_zshrc"
      printf '  ...which is outside %s — your live config is another checkout or worktree.\n' "$root_real"
      printf '  `dotfiles-doctor` for the full picture; re-run ./install from %s to fix.\n' "$root_real"
      return 0
    fi
  fi

  _dotfiles_head_state "$DOTFILES_ROOT"
  _dotfiles_guard_verdict "$_DOTFILES_HEAD" "$DOTFILES_PIN_BRANCH"
  case "$_DOTFILES_VERDICT" in
    unknown) return 0 ;;
    ok)
      # On the pin branch, but is it the pin branch as reviewed? This is the
      # #87 state, and it is the one with no other detection path: nothing
      # about a checkout sitting on main looks wrong.
      _dotfiles_pin_divergence "$DOTFILES_ROOT" "$DOTFILES_PIN_BRANCH"
      case "$_DOTFILES_DIVERGED" in
        differs)
          printf '\033[0;33m⚠ dotfiles: live config is %s, but not the same commit as origin/%s\033[0m\n' \
            "$DOTFILES_PIN_BRANCH" "$DOTFILES_PIN_BRANCH"
          printf '  Merged fixes may not be running, or unmerged commits may be.\n'
          printf '  `dotfiles-doctor` says which files differ.\n' ;;
        stale)
          # On the pin and matching the ref — but the ref is old enough that
          # "matching" has stopped meaning anything. Saying nothing here is what
          # let a merged fix sit unrun; saying "up to date" would be worse.
          printf '\033[0;33m⚠ dotfiles: origin/%s has not been fetched in %dd — cannot tell if merged fixes are running\033[0m\n' \
            "$DOTFILES_PIN_BRANCH" $(( _DOTFILES_FETCH_AGE_H / 24 ))
          printf '  The live config matches the newest commit this machine has downloaded, which is that old.\n'
          printf '  `dotfiles-doctor --fetch` compares against the actual remote.\n' ;;
      esac
      return 0 ;;
    "off-pin "*)
      printf '\033[0;33m⚠ dotfiles: live config is branch %s, not %s\033[0m\n' \
        "${_DOTFILES_VERDICT#off-pin }" "$DOTFILES_PIN_BRANCH" ;;
    "detached "*)
      printf '\033[0;33m⚠ dotfiles: live config is a detached HEAD (%.12s)\033[0m\n' \
        "${_DOTFILES_VERDICT#detached }" ;;
  esac
  printf '  ~/.zshrc, ~/.gitconfig and the rest of your managed config come from it.\n'
  printf '  `dotfiles-doctor` for detail; `dotfiles-work <branch>` to move work off it.\n'
}

# Parse dotbot's link map. Every form dotbot accepts is handled, because a
# parser that knows only some of them omits the rest *silently* — and silent
# omission is the failure this whole file exists to prevent. An omitted link is
# a file the doctor never checks, reported as a clean bill of health.
#
#   ~/.gitconfig: gitconfig                       (inline)
#   ~/.vimrc:                                     (null — source inferred)
#   ~/.p10k.zsh:                                  (expanded, keys beneath)
#     path: p10k.zsh
#     if: '[ -f p10k.zsh ]'
#   ~/.p10k.zsh: {path: p10k.zsh, if: '[ -f ... ]'}   (flow mapping)
#
# The null form is not a curiosity: dotbot's _default_target() (link.py) infers
# the source from the destination's basename minus one leading dot, and installs
# a real symlink. Dropping those entries hid real live files from every check.
#
# Scalars may be quoted — `~/.zshrc: 'zshrc'` is ordinary YAML — and both the
# destination and the source are unquoted here. Keeping the quotes produced a
# git pathspec matching nothing, and `git diff`/`git status` exit 0 on a
# pathspec that matches nothing, so the file vanished from the drift check while
# still counting as an installed link: a green tick for an unchecked file.
#
# `if:` must be captured, not skipped. A conditional link that is correctly not
# installed is not a fault, and reporting it as one makes `dotfiles-doctor` exit
# non-zero forever on any machine where the condition is false — and a
# permanently-red checker is a permanently-ignored checker.
#
# Emits "<target> <source> <conditional 0|1>". Non-zero when the file cannot be
# read at all, so callers can tell "no links" from "could not look" — and the
# caller does branch on it; see dotfiles-doctor.
_dotfiles_link_map() {
  # Usage: _dotfiles_link_map <checkout-root>
  local conf="${1:-}/install.conf.yaml"
  [[ -r "$conf" ]] || return 1
  awk '
    BEGIN { SQ = sprintf("%c", 39); DQ = "\""; tindent = -1 }
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function unquote(s,   f, l) {
      if (length(s) < 2) return s
      f = substr(s, 1, 1); l = substr(s, length(s), 1)
      if (f == l && (f == DQ || f == SQ)) return substr(s, 2, length(s) - 2)
      return s
    }
    # dotbot: basename of the destination, minus one leading dot (link.py).
    function default_src(t,   n, parts, b) {
      n = split(t, parts, "/"); b = parts[n]; sub(/^\./, "", b); return b
    }
    function flush() {
      if (target != "") {
        if (src == "") src = default_src(target)
        if (src != "") print target, src, cond
      }
      target = ""; src = ""; cond = 0; tindent = -1
    }
    function indent_of(s,   i) { i = match(s, /[^[:space:]]/); return (i == 0 ? -1 : i - 1) }
    {
      # A comment can hold anything, including a plausible-looking link line or
      # a commented-out `path:`. It never declares one.
      if ($0 ~ /^[[:space:]]*#/) next
      # Blank lines are not entry boundaries; treating them as one would flush a
      # half-read expanded entry and invent a default source for it.
      if ($0 ~ /^[[:space:]]*$/) next
      line = trim($0); ind = indent_of($0)
      first = substr(line, 1, 1)
      qt = ((first == DQ || first == SQ) && substr(line, 2, 1) == "~")
      if (first == "~" || qt) {
        flush()
        if (qt) {
          # Split after the CLOSING quote, not at the first ":" — a quoted
          # destination may legitimately contain one.
          j = index(substr(line, 2), first)
          if (j == 0) next
          target = substr(line, 2, j - 1)
          rest   = substr(line, j + 2)
          sub(/^[[:space:]]*:/, "", rest)
        } else {
          i = index(line, ":")
          if (i == 0) next
          target = substr(line, 1, i - 1)
          rest   = substr(line, i + 1)
        }
        tindent = ind
        sub(/[[:space:]]*#.*$/, "", rest)
        rest = trim(rest)
        if (substr(rest, 1, 1) == "{") {
          # Read as an inline source this yields the literal string
          # "{path: x, if: ...}", which then goes into a git pathspec and makes
          # the whole drift check match nothing.
          if (match(rest, /path:[[:space:]]*[^,}]+/)) {
            s = substr(rest, RSTART, RLENGTH); sub(/path:[[:space:]]*/, "", s)
            src = unquote(trim(s))
          }
          if (rest ~ /(^\{|,)[[:space:]]*if:/) cond = 1
          flush()
        } else if (rest != "") {
          src = unquote(rest)
          flush()
        }
        next
      }
      if (target == "") next
      # An entry ends at the first line indented no deeper than its own key.
      # Without this the last link in the block stays "open" to the end of the
      # file, and the next `path:` anywhere below — inside a `- shell:` step,
      # say — is silently adopted as its source.
      if (ind <= tindent) { flush(); next }
      if (line ~ /^path:/) {
        s = line; sub(/^path:[[:space:]]*/, "", s); sub(/[[:space:]]*#.*$/, "", s)
        src = unquote(trim(s)); next
      }
      if (line ~ /^if:/) { cond = 1; next }
    }
    END { flush() }
  ' "$conf"
}

# Symlinks `install` creates ITSELF, outside dotbot's `link:` block, in the same
# "<target> <source> <conditional>" shape so every check below treats them
# exactly like declared links. They are live by the identical mechanism, and
# being invisible to the doctor is worse for these than for the declared ones,
# because no manifest lists them at all.
#
#   ~/.config/mise/config.toml — `install` symlinks it to .mise.toml. CLAUDE.md
#     records the bill for that one drifting: the live config declared 10 tools
#     against the repo's 23, ~11 binaries never reached PATH, and `git diff`
#     died with "unable to execute pager 'delta'" — for months, silently.
#
# Emitted only when `install` would in fact have created the link — both halves
# of its own gate: the source exists in this checkout, and mise is installed. On
# a machine with neither, that link is correctly absent, and reporting a correct
# absence as a fault is precisely how a checker becomes one nobody reads.
_dotfiles_extra_links() {
  # Usage: _dotfiles_extra_links <checkout-root>
  local root="${1:-}"
  [[ -n "$root" && -f "$root/.mise.toml" ]] || return 0
  if has_command mise || [[ -x "${HOME}/.local/bin/mise" ]]; then
    printf '%s\n' '~/.config/mise/config.toml .mise.toml 0'
  fi
}

# Repo-relative paths whose content is LIVE without being linked — whose bytes
# reach the running system the moment HEAD moves, even though no symlink names
# them. Reporting only the link list understates the blast radius.
#
#   zsh/     — ~/.zshrc is linked and sources all of it, so a change to
#              zsh/functions/system.sh is exactly as live as a linked file.
#   scripts/ — executed out of the working tree BY PATH, never copied: every
#              backup-*, audit-*, gnome-apply, xdg-repair and verify-tools
#              command shells out to ~/.dotfiles/scripts/…, and
#              systemd/herdr-server.service has
#              ExecStart=%h/.dotfiles/scripts/herdr-server-launch.sh — a running
#              unit whose next exec comes from whatever HEAD points at. Some of
#              those scripts write root-owned files into /etc.
#
# Deliberately NOT here: resticprofile/, audit/ and udev/ are *copied* to /etc
# by their setup commands, so moving HEAD does not change what is running —
# backup-doctor and audit-status drift-check those against the repo instead.
_dotfiles_static_live_paths() {
  printf '%s\n' zsh scripts
}

# How stale is the ref we are about to compare against? mtime of the newest of
# FETCH_HEAD (rewritten by every fetch, including a pull's) and the loose ref
# file (a fresh clone that never fetched again). packed-refs is deliberately
# excluded: gc rewrites it, which would make a repo look freshly fetched when it
# was only repacked, and overstating freshness is the failure being fixed.
# Forkless, and it SETS a variable rather than printing one, because the startup
# path needs this answer too and a command substitution is precisely the fork
# this section is written to avoid. zstat and EPOCHSECONDS come from zsh's own
# modules; the `stat`/`date` version this replaces cost three forks a call.
_dotfiles_fetch_age_hours() {
  # Usage: _dotfiles_fetch_age_hours <checkout-root> <pin-branch>
  # Sets:  _DOTFILES_FETCH_AGE_H = whole hours since the last fetch
  # Returns non-zero, leaving it empty, when it cannot tell.
  local root="${1:-}" pin="${2:-}" f newest=0
  local _DOTFILES_GIT_DIR _DOTFILES_GIT_KIND
  local -a st
  _DOTFILES_FETCH_AGE_H=""
  [[ -n "$root" && -n "$pin" ]] || return 1
  _dotfiles_git_dir "$root" || return 1
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 1
  zmodload zsh/datetime 2>/dev/null || return 1
  for f in "$_DOTFILES_GIT_DIR/FETCH_HEAD" "$_DOTFILES_GIT_DIR/refs/remotes/origin/$pin"; do
    [[ -f "$f" ]] || continue
    zstat -A st +mtime "$f" 2>/dev/null || continue
    (( st[1] > newest )) && newest=$st[1]
  done
  (( newest > 0 )) || return 1
  # A clock stepped backwards (VM restore, a bad NTP correction) would otherwise
  # yield a huge negative age, which reads as "fetched moments ago".
  if (( EPOCHSECONDS < newest )); then
    _DOTFILES_FETCH_AGE_H=0
  else
    _DOTFILES_FETCH_AGE_H=$(( (EPOCHSECONDS - newest) / 3600 ))
  fi
  return 0
}

dotfiles-doctor() {
  # Usage: dotfiles-doctor [--fetch]
  # Reports whether the live config is the reviewed config, and when it is not,
  # exactly which managed files differ. Read-only by default: no sudo, no
  # network — it compares against the origin/<pin> ref already on disk and says
  # how old that ref is instead of assuming it is current. `--fetch` updates the
  # ref first, which is the only way to get an answer about the actual remote.
  local root="${DOTFILES_ROOT}" pin="${DOTFILES_PIN_BRANCH}" do_fetch=0
  # Locals by dynamic scope — see _doctor_ok. Both the counters and the
  # internals' result variables, so a run leaves nothing behind in the shell.
  local _DOCTOR_FAIL=0 _DOCTOR_WARN=0
  local _DOTFILES_HEAD _DOTFILES_VERDICT

  case "${1:-}" in
    "")        ;;
    --fetch)   do_fetch=1 ;;
    --help|-h) echo "Usage: dotfiles-doctor [--fetch]   (--fetch updates origin/$pin first)"; return 0 ;;
    *)         echo "usage: dotfiles-doctor [--fetch]" >&2; return 2 ;;
  esac

  echo "=== Dotfiles Doctor ==="
  # A LINKED WORKTREE is the one layout with nothing to check: no symlink points
  # into one, so none of it is live. Everything else git can read is a primary
  # checkout — including a --separate-git-dir clone, whose `.git` is a file. The
  # earlier `[[ -d .git ]]` test filed those under "worktree" and returned 1 on
  # every run, forever, which is the permanently-red checker this file argues at
  # length that nobody reads. A root that is no repo at all falls through to the
  # git probe below, which says so with git's own error.
  local _DOTFILES_GIT_DIR _DOTFILES_GIT_KIND
  _dotfiles_git_dir "$root"
  if [[ "$_DOTFILES_GIT_KIND" == "worktree" ]]; then
    echo "  ✗ $root is a linked git worktree, not the primary checkout — nothing there is live"
    return 1
  fi

  # Prove git can read this repo BEFORE any answer depends on it. Four checks
  # below are git invocations, and a repo-wide git failure makes each of them
  # return empty — which two of them would have reported as a definite fact
  # ("no origin/main ref"; "no worktrees"). The trigger is not hypothetical: a
  # malformed ~/.gitconfig does it, and ~/.gitconfig is itself one of the
  # managed symlinks whose content changes on the branch switch this function
  # is about, so a bad branch can blind the guard to that branch.
  local probe prc
  probe="$(git -C "$root" rev-parse --git-dir 2>&1)"; prc=$?
  if (( prc != 0 )); then
    echo "  ✗ git cannot read $root (exit $prc) — every check below would be a guess"
    printf '    %s\n' "$probe"
    echo "    A malformed ~/.gitconfig does this, and ~/.gitconfig is a managed symlink."
    return 1
  fi

  echo "Checkout:  $root"
  echo "Pinned to: $pin"

  if (( do_fetch )); then
    echo "Refreshing origin/$pin:"
    if git -C "$root" fetch --quiet origin "$pin" 2>/dev/null; then
      _doctor_ok "fetched — the comparison below is against the real remote"
    else
      _doctor_warn "fetch failed (offline? no remote?) — falling back to the ref on disk"
    fi
  fi

  echo "Live branch:"
  _dotfiles_head_state "$root"
  _dotfiles_guard_verdict "$_DOTFILES_HEAD" "$pin"
  case "$_DOTFILES_VERDICT" in
    ok)           _doctor_ok "on '$pin' — the pinned branch" ;;
    "off-pin "*)  _doctor_bad "on '${_DOTFILES_VERDICT#off-pin }', not '$pin'" ;;
    "detached "*) _doctor_bad "detached HEAD at ${_DOTFILES_VERDICT#detached }" ;;
    *)            _doctor_warn "could not read HEAD for $root" ;;
  esac

  # Does the ref we are about to compare against actually exist? Every check
  # below is a diff against origin/<pin>; without it they all return empty,
  # which reads identically to "no drift". Establish it once, loudly, and let
  # the rest skip rather than print a clean bill of health they cannot support.
  # git's health is already proven above, so a non-zero status here means the
  # ref is genuinely absent rather than that git could not be asked.
  local have_ref=0
  if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/$pin" >/dev/null 2>&1; then
    have_ref=1
  fi

  # Existence is not currency, and this is the check the whole feature turns on.
  # Nothing on this machine fetches on a schedule — origin/<pin> is exactly as
  # old as the last time a human typed `git fetch`. Against a week-old ref,
  # "not behind" means "not behind what was true a week ago", which is the #87
  # scenario reported as an all-clear. So the age is stated every run, and a
  # stale ref is a warning that suppresses the unqualified ✓ at the end.
  echo "Freshness of origin/$pin:"
  if (( have_ref )); then
    local _DOTFILES_FETCH_AGE_H
    if _dotfiles_fetch_age_hours "$root" "$pin"; then
      if (( _DOTFILES_FETCH_AGE_H > DOTFILES_FETCH_MAX_AGE_HOURS )); then
        _doctor_warn "last fetched ${_DOTFILES_FETCH_AGE_H}h ago (>${DOTFILES_FETCH_MAX_AGE_HOURS}h) — everything below is only as current as that (dotfiles-doctor --fetch)"
      else
        _doctor_ok "last fetched ${_DOTFILES_FETCH_AGE_H}h ago"
      fi
    else
      _doctor_warn "cannot tell when origin/$pin was last fetched — treat the comparison below as of unknown age (dotfiles-doctor --fetch)"
    fi
  else
    _doctor_bad "no origin/$pin ref — cannot tell reviewed from unreviewed"
    echo "    Fix: git -C $root fetch origin"
  fi

  echo "Position vs origin/$pin:"
  if (( have_ref )); then
    local counts behind ahead
    counts="$(git -C "$root" rev-list --left-right --count "origin/$pin...HEAD" 2>/dev/null)"
    read -r behind ahead <<< "$counts"
    if [[ -z "${behind:-}" || -z "${ahead:-}" ]]; then
      _doctor_warn "could not compare against origin/$pin"
    else
      # if/else, not `cond && ok || bad`: _doctor_ok returns printf's status, so
      # on a failed write that idiom runs BOTH branches and counts a failure for
      # a check that passed (ShellCheck SC2015 — a lint this file is excluded
      # from, so the pattern has to be avoided by hand). The write that does it
      # is a full filesystem, not a closed fd: zsh's printf warns and returns 0
      # on a closed fd, but returns 1 on ENOSPC.
      if [[ "$behind" == "0" ]]; then
        _doctor_ok "not behind that ref — every commit it has is live"
      else
        _doctor_bad "$behind commit(s) BEHIND — merged, reviewed fixes are NOT running"
      fi
      if [[ "$ahead" == "0" ]]; then
        _doctor_ok "not ahead — nothing unreviewed is live"
      else
        _doctor_warn "$ahead commit(s) AHEAD — unmerged code IS running"
      fi
    fi
  else
    _doctor_warn "skipped — no origin/$pin to compare against"
  fi

  # The link map is parsed ONCE here and every check below is derived from it.
  # Two reasons: it was parsed twice (two awk forks, two reads, and two
  # consumers that could disagree if the file changed between them), and more
  # importantly a parse failure has to stop the derived checks. An unreadable
  # install.conf.yaml yields no paths, an empty pathspec diffs the whole tree or
  # nothing at all, and the section prints "every live file matches" — a false
  # all-clear produced by not knowing what is live.
  local -a link_lines=()
  local l raw map_rc=0
  # Captured, not read through a process substitution: _dotfiles_link_map
  # returns non-zero when it could not read install.conf.yaml AT ALL, and a
  # process substitution throws that status away — which collapsed "unreadable
  # file", "no awk" and "a link: block declaring nothing" into one message that
  # named only the first of the three.
  raw="$(_dotfiles_link_map "$root")"; map_rc=$?
  if (( map_rc == 0 )); then
    for l in "${(f)raw}"; do
      [[ -n "$l" ]] && link_lines+=("$l")
    done
  fi

  local map_ok=1 map_why=""
  if (( map_rc != 0 )); then
    map_ok=0; map_why="$root/install.conf.yaml is missing or unreadable"
  elif (( ${#link_lines[@]} == 0 )); then
    map_ok=0; map_why="its 'link:' block declares nothing this parser recognises"
  fi

  # install's own symlinks, appended only after the map's health is settled, so
  # they cannot make an unreadable or empty link: block look like a working one.
  if (( map_ok )); then
    while IFS= read -r l; do
      [[ -n "$l" ]] && link_lines+=("$l")
    done < <(_dotfiles_extra_links "$root")
  fi

  local -a live_paths=() missing_src=()
  if (( map_ok )); then
    local mt ms mc
    for l in "${link_lines[@]}"; do
      read -r mt ms mc <<< "$l"
      [[ -n "$ms" ]] || continue
      # A declared source that is not in the tree cannot drift, cannot show up
      # dirty, and cannot be diffed: git exits 0 with empty output for a
      # pathspec matching nothing. So a typo or an un-renamed source in
      # install.conf.yaml silently NARROWS every check below instead of failing
      # one — `~/.zshrc: zshrcc` would take the most live file in the repo out
      # of the drift check and still print a green tick. Assert it once, here.
      [[ -e "$root/$ms" ]] || missing_src+=("$mt → $ms")
      live_paths+=("$ms")
    done
    while IFS= read -r l; do
      [[ -n "$l" ]] && live_paths+=("$l")
    done < <(_dotfiles_static_live_paths)
  fi

  # What the map itself says, before anything derived from it. Every section
  # below is only as good as this one, so its failures belong here and the rest
  # skip rather than each restating a different half of the same problem.
  echo "Link map (what is live):"
  if (( ! map_ok )); then
    _doctor_bad "what is live is UNKNOWN — $map_why"
    echo "    Nothing below that depends on the link map is a clean bill of health."
  elif (( ${#missing_src[@]} > 0 )); then
    _doctor_bad "${#missing_src[@]} declared source(s) absent from this tree — checked by NOTHING below:"
    printf '    %s\n' "${missing_src[@]}"
    echo "    Fix the path in $root/install.conf.yaml, or re-add the file."
  else
    _doctor_ok "${#link_lines[@]} link(s) declared, every source present in the tree"
  fi

  # The blast radius in files. Commit counts say how far apart the trees are;
  # this says whether the difference actually reaches your shell.
  echo "Managed files differing from origin/$pin:"
  if (( ! map_ok )); then
    _doctor_warn "skipped — the link map did not parse, so 'live' is undefined"
  elif (( ! have_ref )); then
    _doctor_warn "skipped — no origin/$pin to compare against"
  else
    # NOT named `path`: in zsh that identifier is tied to the PATH array, so
    # `local path` blanks PATH for the rest of the function and every external
    # command after it silently vanishes. The first draft of this function did
    # exactly that — git was not found, its error went to /dev/null, and the
    # empty result printed as "✓ none — every live file matches". A false
    # all-clear, in the function written to detect false all-clears.
    local diffstat add del relpath rc
    # stderr is DISCARDED, not folded in with 2>&1, and the exit status is what
    # decides. git writes warnings to stderr while still succeeding (a malformed
    # ~/.gitconfig, for one), and merging that into the value being parsed put a
    # non-numstat line into the loop below, where it matched nothing and printed
    # nothing at all — no tick, no cross, an empty section. Status is the only
    # reliable signal; captured output is data and must stay data.
    diffstat="$(git -C "$root" diff --numstat "origin/$pin" HEAD -- "${live_paths[@]}" 2>/dev/null)"
    rc=$?
    if (( rc != 0 )); then
      # Never infer "no drift" from a failed command. An empty result and a
      # broken invocation are indistinguishable downstream, so separate them here.
      _doctor_bad "could not diff against origin/$pin (git exit $rc) — drift UNKNOWN"
      echo "    Re-run to see why: git -C $root diff --numstat origin/$pin HEAD"
    elif [[ -z "$diffstat" ]]; then
      _doctor_ok "none — every live file matches origin/$pin"
    else
      # Fed by here-string, not a pipe: a pipeline's last stage is a subshell
      # in both bash and zsh, so the counters would be incremented in a child
      # and discarded, and the summary would report zero problems after printing
      # a screen of them.
      while IFS=$'\t' read -r add del relpath; do
        [[ -n "$relpath" ]] && _doctor_bad "$relpath (+$add/-$del)"
      done <<< "$diffstat"
    fi
  fi

  # Uncommitted edits are live too. This is the one case `git status` does
  # surface, but only if you happen to run it in this repo — which is not where
  # you notice a shell function behaving oddly.
  #
  # Scoped to the live paths, not the whole repo. Unscoped it reported every
  # scratch file and node_modules/ in the tree as a finding, with untracked
  # directories collapsed so the offending file was not even named — noise in
  # exactly the normal states that teach people to stop reading the output.
  echo "Uncommitted changes to live files:"
  if (( ! map_ok )); then
    _doctor_warn "skipped — the link map did not parse, so 'live' is undefined"
  else
    local line drc dpath dcode dorig expected p i
    local -a recs=() expected_dirty=()
    # -z rather than plain --porcelain, because plain porcelain is not a format
    # you can compare paths against: git C-quotes any path holding a space or a
    # non-ASCII byte (?? "zsh/a b.sh") and writes a rename as "old -> new". Both
    # reach DOTFILES_EXPECTED_DIRTY as a string no entry can ever equal, so such
    # a file was a permanent, inexcusable warning. NUL records are unquoted, and
    # a rename's original path arrives as its own following record.
    #
    # The exit status rides along as a final NUL record: a process substitution
    # discards it, and "no output" from a failed git is the exact false
    # all-clear this function exists to prevent.
    while IFS= read -r -d '' line; do recs+=("$line"); done \
      < <(git -C "$root" status --porcelain -z --untracked-files=all -- "${live_paths[@]}" 2>/dev/null
          printf '%d\0' $?)
    drc="${recs[-1]:-1}"
    recs=("${(@)recs[1,-2]}")

    # Scalar (space-separated) is the documented form and stays supported; an
    # array is honoured too, because word-splitting a scalar makes a path with a
    # space in it impossible to express — and those are exactly the paths plain
    # porcelain used to mangle.
    if [[ "${(t)DOTFILES_EXPECTED_DIRTY}" == array* ]]; then
      expected_dirty=("${DOTFILES_EXPECTED_DIRTY[@]}")
    else
      expected_dirty=(${=DOTFILES_EXPECTED_DIRTY})
    fi

    if (( drc != 0 )); then
      _doctor_bad "could not read working-tree status (git exit $drc)"
    elif (( ${#recs[@]} == 0 )); then
      _doctor_ok "none"
    else
      i=1
      while (( i <= ${#recs[@]} )); do
        line="${recs[i]}"; i=$(( i + 1 ))
        # "XY path": X or Y may be a space. Squeezing the status field keeps the
        # output one column of codes instead of a ragged " M"/"??" mix.
        dcode="${${line:0:2}// /}"
        dpath="${line:3}"
        dorig=""
        # A rename or copy is two records: the new path, then the original.
        if [[ "$dcode" == R* || "$dcode" == C* ]]; then
          dorig="${recs[i]:-}"; i=$(( i + 1 ))
        fi
        expected=0
        for p in "${expected_dirty[@]}"; do
          if [[ "$dpath" == "$p" ]] || [[ -n "$dorig" && "$dorig" == "$p" ]]; then
            expected=1; break
          fi
        done
        [[ -n "$dorig" ]] && dpath="$dorig → $dpath"
        if (( expected )); then
          _doctor_note "$dcode $dpath (expected — see install.conf.yaml)"
        else
          _doctor_warn "$dcode $dpath"
        fi
      done
    fi
  fi

  # Link integrity, in three directions:
  #   declared but not linked — ./install has not run since it was added, so
  #     that file is NOT live and edits to it do nothing (unless the link is
  #     conditional and its `if:` is false, which is correct, not a fault);
  #   linked but dangling — a link installed while on a branch that declares it,
  #     left behind after switching away. The target no longer exists in the
  #     tree. This is not hypothetical: a systemd user unit is in exactly that
  #     state on any machine that ran ./install on the herdr branch;
  #   linked but pointing OUTSIDE this checkout — `./install` run from a
  #     worktree re-points the whole live config at a feature branch. Checking
  #     only "is it a symlink" passed that state with "N/N declared links
  #     present" while every other check in this function inspected the wrong
  #     tree, and the startup warning stayed silent. `install` now refuses to
  #     run from a worktree; this catches the ones already installed, and any
  #     other foreign target.
  echo "Link integrity:"
  if (( ! map_ok )); then
    _doctor_warn "skipped — the link map did not parse, so 'live' is undefined"
  else
    local target src cond abs resolved want rootreal declared=0 linked=0
    local missing="" dangling="" foreign="" mismatched="" skipped=""
    # Canonicalised once: ~/.dotfiles is itself a symlink on some machines, and
    # comparing a resolved target against an unresolved root would then report
    # every correctly-installed link as foreign.
    rootreal="$(readlink -f "$root" 2>/dev/null)" || rootreal=""
    [[ -n "$rootreal" ]] || rootreal="$root"
    for l in "${link_lines[@]}"; do
      read -r target src cond <<< "$l"
      [[ -n "$target" && -n "$src" ]] || continue
      declared=$((declared + 1))
      abs="${HOME}/${target#\~/}"
      if [[ -L "$abs" ]]; then
        linked=$((linked + 1))
        [[ -e "$abs" ]] || dangling+=" $target"
        # -f, not -e: resolves the path even when the target is missing, so a
        # dangling link is still checked for pointing at the wrong tree.
        resolved="$(readlink -f "$abs" 2>/dev/null)" || resolved=""
        want="$(readlink -f "$rootreal/$src" 2>/dev/null)" || want=""
        [[ -n "$want" ]] || want="$rootreal/$src"
        if [[ -n "$resolved" && "$resolved" != "$rootreal" && "$resolved" != "$rootreal"/* ]]; then
          foreign+=" ${target}→${resolved}"
        elif [[ -n "$resolved" && "$resolved" != "$want" ]]; then
          # Inside the checkout, but not at the file install.conf.yaml names.
          # Rename a source and forget to re-run ./install: the old link still
          # resolves to a real file in the tree, so it is neither missing nor
          # dangling nor foreign, and all three checks pass while the live file
          # is the old source — permanently, and with a full green all-clear.
          mismatched+=" ${target}→${resolved#"$rootreal"/} (declared: $src)"
        fi
      elif [[ "$cond" == "1" ]]; then
        skipped+=" $target"
      else
        missing+=" $target"
      fi
    done

    # if/else throughout, not `cond && ok || bad`: see the note in the position
    # section above — that idiom runs both branches when the ✓ printf fails.
    if [[ -z "$missing" ]]; then
      _doctor_ok "$linked/$declared declared links present"
    else
      _doctor_bad "$linked/$declared present — not linked:$missing (run ./install)"
    fi
    if [[ -z "$dangling" ]]; then
      _doctor_ok "no dangling links"
    else
      _doctor_bad "dangling (target absent on this branch):$dangling"
    fi
    if [[ -z "$foreign" ]]; then
      _doctor_ok "every link resolves inside $rootreal"
    else
      _doctor_bad "link points OUTSIDE the checkout — the live config is NOT this tree:$foreign"
    fi
    if [[ -z "$mismatched" ]]; then
      _doctor_ok "every link points at the source install.conf.yaml declares"
    else
      _doctor_bad "link points at the WRONG file in this tree — edits to the declared source do nothing:$mismatched"
    fi
    if [[ -n "$skipped" ]]; then
      _doctor_note "conditional in install.conf.yaml (\`if:\`) and not installed:$skipped"
    fi
  fi

  # Not a dotfiles-link question, but it is a "what is live in this shell"
  # question, and the failure is the same shape: the value looks ordinary and
  # nothing reports the difference. 002 with a shared login group made every
  # file this user creates writable by another account.
  echo "File-creation mask:"
  # _verdict, not _guard: the doctor must not change the umask of the shell it
  # is run in. It reports what is live and what the rule wants, and says so when
  # those differ — which is how you notice a shell that started before the rule
  # existed, or one where an override failed.
  # Ask what the rule WOULD do by running the guard in a subshell and comparing
  # masks — never by re-deriving the comparison here. The re-derived version
  # used `8#$_DOTFILES_UMASK_WANT`, which is a math error for any non-octal
  # DOTFILES_UMASK: `DOTFILES_UMASK=nonsense` printed `bad math expression` and
  # then `✓ … set explicitly`, i.e. it reproduced, in the checker, the exact
  # "reported as applied" defect the guard had just been fixed for. A fork in a
  # doctor is free; a second implementation of the rule is not.
  local _DOTFILES_UMASK_WHY _DOTFILES_UMASK_MODE _DOTFILES_UMASK_WANT
  local _cur _would
  _cur="$(umask)"
  # Ask what the rule WOULD do by running the guard in a subshell, never by
  # re-deriving it here. The re-derived version used `8#$_DOTFILES_UMASK_WANT`,
  # a math error for any non-octal override, and then printed ✓ — reproducing,
  # inside the checker, the "reported as applied" defect the guard had just been
  # fixed for. A fork in a doctor is free; a second implementation is not.
  _would="$(_dotfiles_umask_guard >/dev/null 2>&1; umask)"
  if _dotfiles_umask_verdict; then
    if [[ "$_would" != "$_cur" ]]; then
      _doctor_bad "umask is $_cur but the rule would set $_would — this shell predates the rule ($_DOTFILES_UMASK_WHY)"
    else
      case "$_DOTFILES_UMASK_MODE" in
        "") _doctor_note "umask $_cur — $_DOTFILES_UMASK_WHY" ;;
        *)  _doctor_ok   "umask $_cur — $_DOTFILES_UMASK_WHY" ;;
      esac
    fi
  else
    _doctor_warn "umask $_cur — $_DOTFILES_UMASK_WHY"
  fi

  echo "Worktrees (where feature work belongs):"
  local wt wrc
  wt="$(git -C "$root" worktree list 2>/dev/null)"; wrc=$?
  if (( wrc != 0 )); then
    _doctor_warn "could not list worktrees (git exit $wrc)"
  else
    # Line one is the primary checkout, which is not a worktree in the sense
    # meant here. Split in-shell rather than piping to tail: a pipeline's status
    # would be tail's, and this used to discard git's.
    local -a wt_lines
    wt_lines=("${(f)wt}")
    if (( ${#wt_lines[@]} <= 1 )); then
      echo "  (none) — dotfiles-work <branch> to make one"
    else
      printf '  %s\n' "${wt_lines[@]:1}"
    fi
  fi

  echo
  _doctor_summary "Live config is the reviewed config." \
    "Usual fix: git -C $root checkout $pin && dotfiles-work <branch>"
}

dotfiles-work() {
  # Usage: dotfiles-work <branch>          create/enter a worktree for <branch>
  #        dotfiles-work --list            list existing worktrees
  #        dotfiles-work --remove <branch> remove one
  #
  # Feature work on this repo happens in a worktree, never by moving the primary
  # checkout — because moving the primary checkout is a deploy (see the section
  # header). Nothing symlinks into a worktree, so you can edit, rebase, stash and
  # bisect there without changing the shell you are typing into.
  local root="${DOTFILES_ROOT}" pin="${DOTFILES_PIN_BRANCH}"
  local base="${DOTFILES_WORKTREES:-${HOME}/dotfiles-worktrees}"

  case "${1:-}" in
    --list|-l)
      git -C "$root" worktree list
      return $? ;;
    --remove|-r)
      if [[ -z "${2:-}" ]]; then
        echo "Usage: dotfiles-work --remove <branch>" >&2
        return 1
      fi
      git -C "$root" worktree remove "${base}/${2//\//-}"
      return $? ;;
    ""|--help|-h)
      echo "Usage: dotfiles-work <branch> | --list | --remove <branch>"
      echo "Creates ${base}/<branch> so the primary checkout stays on '$pin'."
      return 0 ;;
  esac

  local branch="$1" dir="${base}/${1//\//-}"

  if [[ -d "$dir" ]]; then
    # A directory at the expected path is not a worktree. It is also what
    # `rm -rf` without `git worktree prune`, a half-failed `worktree remove`,
    # and a plain name collision leave behind — and the previous version cd'd
    # into it, printed "Entered existing worktree" with an empty branch, and
    # returned 0, so the next hour of edits went into a directory git knew
    # nothing about.
    local wt_branch
    if ! wt_branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
      echo "✗ $dir exists but is not a git worktree — refusing to use it" >&2
      echo "  Left over from a removed worktree, or a name collision. Clear it with:" >&2
      echo "    rm -rf '$dir' && git -C '$root' worktree prune" >&2
      return 1
    fi
    # Branch names flatten / to - for the directory name, so two branches can
    # want the same directory. Say which one is actually there.
    if [[ "$wt_branch" != "$branch" ]]; then
      echo "⚠ $dir is on '$wt_branch', not '$branch' — using it as-is" >&2
    fi
    cd "$dir" || return 1
    echo "Entered existing worktree: $dir ($wt_branch)"
    return 0
  fi

  mkdir -p "$base" || return 1

  # Prefer an existing branch; otherwise start from the REMOTE default, not from
  # whatever the primary checkout is sitting on. Branching off a checkout that is
  # itself off-pin is how the divergence spreads instead of being contained.
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" worktree add "$dir" "$branch" || return 1
  elif git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$root" worktree add --track -b "$branch" "$dir" "origin/$branch" || return 1
  else
    git -C "$root" fetch --quiet origin "$pin" 2>/dev/null
    # --no-track is load-bearing. Without it the new branch takes origin/<pin>
    # as its upstream, and under this repo's own push.default=simple a plain
    # `git push` then fails with "the upstream branch of your current branch
    # does not match the name of your current branch" and helpfully suggests
    # `git push origin HEAD:main` — pushing unreviewed feature commits straight
    # onto the branch this whole feature exists to protect. It also made
    # `git status` read "ahead of origin/main by N" and, with pull.rebase=true,
    # made `git pull` rebase onto main unasked. push.autoSetupRemote=true sets
    # the correct upstream on the first push instead.
    git -C "$root" worktree add --no-track -b "$branch" "$dir" "origin/$pin" || return 1
  fi

  cd "$dir" || return 1
  echo "Worktree:  $dir"
  echo "Primary checkout still on: $(git -C "$root" rev-parse --abbrev-ref HEAD)"
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
#
# EVERY distinct target, space-joined, never just the first: two entries for one
# UUID at two mount points is a real defect, and `head -1` would report whichever
# came first — so if that one matched the configured mount point the doctor would
# tick "has an /etc/fstab entry ✓" and never mention the conflicting second one.
# A multi-target answer equals no single mount point, so the caller's `!=` test
# reports it by construction.
_backup_fstab_target_for_uuid() {
  local uuid="${1:-}" out
  [[ -n "$uuid" ]] || return 0
  out="$(LC_ALL=C findmnt --fstab -no TARGET -S "UUID=$uuid" 2>/dev/null | sort -u | tr '\n' ' ')"
  [[ -n "${out// /}" ]] || out="$(LC_ALL=C findmnt --fstab -no TARGET -S "/dev/disk/by-uuid/$uuid" 2>/dev/null | sort -u | tr '\n' ' ')"
  printf '%s' "${out% }"
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
  elif [[ -z "$extuuid" ]] && ! findmnt --fstab -no SOURCE --target "$extmnt" >/dev/null 2>&1; then
    # _backup_external_attached identifies the drive by UUID, or by whatever
    # /etc/fstab names as the source for the mount point. With neither — the
    # state every install predating BACKUP_EXTERNAL_UUID being read is in — it
    # returns false because it has nothing to ask, not because the disk is
    # absent. Saying "not attached" there asserts exactly what this command
    # cannot know, which is the same mistake the "not configured" branch above
    # exists to avoid.
    echo "External:   unknown — no BACKUP_EXTERNAL_UUID and no /etc/fstab entry, so an attached-but-unmounted drive cannot be told from an absent one (set it in ~/.backup.local, then run backup-setup)"
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

# Internal: backup-doctor result emitters. Kept as names (30-odd call sites read
# better with the subject in them) but delegating to the shared _doctor_*
# implementation — there used to be a byte-for-byte duplicate pair here and in
# the dotfiles guard, so any change to how results are emitted had to be made
# twice. The counters they increment are backup-doctor's `local`s, reached by
# zsh's dynamic scoping; see _doctor_ok.
_backup_doctor_ok()   { _doctor_ok   "$@"; }
_backup_doctor_warn() { _doctor_warn "$@"; }
_backup_doctor_bad()  { _doctor_bad  "$@"; }

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
# result counters as every other check (backup-doctor's locals, via dynamic scope).
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
      _doctor_note 'external HDD not attached (offsite falls to B2 — see its snapshot freshness above)'
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
      # Name what is actually missing. "No external HDD is configured" is false
      # when only the UUID is blank, and a checker that misreports the state it
      # is in gets read as noise.
      local extwhy="no external HDD is configured"
      [[ -n "$extmnt" ]] && extwhy="BACKUP_EXTERNAL_UUID is blank"
      _backup_doctor_warn "$extrules exists but $extwhy — a stale hotplug rule for an unknown disk (re-run backup-setup to remove it)"
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
      _backup_doctor_warn "udev hotplug rule differs from the rendered ~/.dotfiles template (stale mount unit after a repo-path change? hand-edited? the shipped template changed since it was installed?) — re-run backup-setup"
    fi
  fi
}

# Full-chain health assertion: is the backup system not just running, but CORRECT?
# Catches the silent lies backup-status can't see (config drift, missing env drop-in,
# stale snapshots, inert alerting, stale recovery assets). Non-zero exit on any FAIL.
backup-doctor() {
  # Usage: backup-doctor
  # Locals, not globals: see _doctor_ok. These used to persist in every shell
  # that ran backup-doctor, and a nested call clobbered the outer count.
  local _DOCTOR_FAIL=0 _DOCTOR_WARN=0
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
    _doctor_note 'no churn reading (journal rotated / no scheduled run yet / BACKUP_B2_CHURN_WARN_MB blank)'
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
    _doctor_note 'emergency-kit.age not in $HOME — OK if it lives on your offline USB / in the repo (rebuild periodically)'
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
  _doctor_summary "All checks passed — the backup chain is correct end-to-end."
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
