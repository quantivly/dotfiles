#!/usr/bin/env bash
#
# scripts/resource-pulse-cost.sh
# ==============================
#
# Measure what Resource Pulse costs. It has three parts, and each is measured
# on its own:
#   - the extension, which only draws, lives inside gnome-shell, so its cost is
#     gnome-shell's: take a reading with the extension off, another with it on,
#     and compare;
#   - the sampler service (resource-pulse.service) is a process of its own:
#     --service measures it directly, the same way;
#   - so is the cockpit service (cockpit.service): --cockpit measures it.
#
# CPU is read from the scheduler's own nanosecond counters, one per thread
# (<proc root>/<pid>/task/<tid>/schedstat, first field: time on a CPU), never
# from stat's clock ticks, which over a minute resolve only about 0.02% of one
# core. A thread that starts during a window counts from 0; one that ends
# during it is left out, as the scheduler keeps no counter for a thread that
# is gone. A counter that cannot be read is exit 2, never a reading of 0.
#
# Usage:
#   scripts/resource-pulse-cost.sh [--service|--cockpit] --cpu-percent <seconds>
#       CPU over a window, as a % of ONE core, every thread
#   scripts/resource-pulse-cost.sh [--service|--cockpit] --tick-median <seconds>
#       the median of the main thread's CPU per Sample tick (SAMPLE_INTERVAL_SECONDS)
#       over a window of at least one tick, in ms: the steady work of a tick,
#       where a mean would also carry the occasional collection or other one-off
#   scripts/resource-pulse-cost.sh [--service|--cockpit] --rss-kib
#       resident memory, KiB
#   scripts/resource-pulse-cost.sh --rss-check <baseline_kib>
#       gnome-shell only: exit 0 when its resident memory grew by at most
#       RSS_GROWTH_TOLERANCE_MIB since the baseline, 1 otherwise; prints both
#       numbers either way. Each service's RSS budget is absolute, not a growth
#       (the sampler at most SERVICE_RSS_BUDGET_MIB, the cockpit at most
#       COCKPIT_RSS_BUDGET_MIB): read it with --service --rss-kib or
#       --cockpit --rss-kib, and --rss-check under either says that budget.
# --service or --cockpit may stand anywhere on the line, and only one of them.
# Any other argument left over, or a mode without its value, is a usage error
# (exit 2): an ignored word could make a reading of gnome-shell pass for one of
# a service.
#
# Finding gnome-shell: the one process of this user whose comm is "gnome-shell".
# GNOME_SHELL_PID names it outright. More than one candidate, or none, is exit 2:
# a guess would measure the wrong process and look like a result.
# Finding a service: its unit's MainPID, from
# `systemctl --user show -p MainPID --value <unit>` (resource-pulse.service or
# cockpit.service). MainPID 0 (not running, or skipped for want of its config
# file) is exit 2.
#
# Reads only <proc root>/<pid>/comm, /status and /task/<tid>/schedstat: no
# argument list, no environment and no process-listing tool, all of which print
# what other processes were started with and so end up in a transcript.
#
# Environment: PROC_ROOT (default /proc, overridable for the test fixture),
#              GNOME_SHELL_PID (never consulted with --service or --cockpit).
# Exit: 0 ok, 1 --rss-check failed, 2 could not measure or bad usage.

set -uo pipefail

readonly PROC_ROOT="${PROC_ROOT:-/proc}"
readonly SHELL_COMM="gnome-shell"
readonly SERVICE_UNIT="resource-pulse.service"
readonly SERVICE_FLAG="--service"
readonly COCKPIT_UNIT="cockpit.service"
readonly COCKPIT_FLAG="--cockpit"
# What is measured: gnome-shell (the default), the sampler service, or the cockpit service.
readonly MEASURED_GNOME_SHELL="gnome-shell"
readonly MEASURED_SERVICE="service"
readonly MEASURED_COCKPIT="cockpit"
readonly RSS_GROWTH_TOLERANCE_MIB=64
# The design's budget for the sampler service's resident memory (docs/GNOME_CONFIGURATION_GUIDE.md).
readonly SERVICE_RSS_BUDGET_MIB=64
# The design's budget for the cockpit service's resident memory
# (docs/superpowers/specs/2026-11-09-desktop-cockpit-design.md).
readonly COCKPIT_RSS_BUDGET_MIB=48
# How each service gets started, for the line that says it is not running.
readonly SERVICE_START_HINT="its extension starts it, or: systemctl --user start $SERVICE_UNIT"
readonly COCKPIT_START_HINT="it needs ~/.config/resource-pulse/cockpit.json, then: systemctl --user start $COCKPIT_UNIT"
readonly KIB_PER_MIB=1024
readonly EXIT_BAD_USAGE_OR_NO_MEASUREMENT=2
# A process's threads, each with the scheduler's counters in <tid>/schedstat.
readonly TASK_DIR_NAME="task"
readonly SCHEDSTAT_FILE_NAME="schedstat"
readonly NANOSECONDS_PER_SECOND=1000000000
readonly NANOSECONDS_PER_MILLISECOND=1000000
readonly PERCENT_PER_FRACTION=100
# The extension's SAMPLE_INTERVAL_SECONDS (gnome-shell/extensions/resource-pulse@dotfiles/lib/constants.js): the
# tick --tick-median reads the main thread at. The --tick-median row in scripts/test-resource-pulse.sh reads its
# expected tick from lib/constants.js, so the two cannot drift apart unseen.
readonly SAMPLE_INTERVAL_SECONDS=2
readonly WHOLE_NUMBER_PATTERN='^[0-9]+$'
readonly POSITIVE_WHOLE_NUMBER_PATTERN='^[1-9][0-9]*$'

# Each thread's time on a CPU (ns), keyed by tid, as read_thread_run_nanoseconds last read it.
declare -A THREAD_RUN_NANOSECONDS=()
# The main thread's time on a CPU (ns), as read_main_thread_run_nanoseconds last read it.
MAIN_THREAD_RUN_NANOSECONDS=0
# The first field of the schedstat file read_schedstat_run_nanoseconds last read, or empty.
RUN_NANOSECONDS_READ=""

#######################################
# Print a message to stderr and exit 2.
# Arguments:
#   $@ - message
#######################################
die() {
    printf 'resource-pulse-cost: %s\n' "$*" >&2
    exit "$EXIT_BAD_USAGE_OR_NO_MEASUREMENT"
}

#######################################
# Print the pid of this user's gnome-shell; die when there are zero or several.
# Honours GNOME_SHELL_PID.
#######################################
find_gnome_shell_pid() {
    if [[ -n "${GNOME_SHELL_PID:-}" ]]; then
        [[ "$GNOME_SHELL_PID" =~ ^[0-9]+$ ]] || die "GNOME_SHELL_PID is not a number: $GNOME_SHELL_PID"
        printf '%s' "$GNOME_SHELL_PID"
        return
    fi
    local own_uid process_dir comm_value
    local -a candidate_pids=()
    own_uid="$(id -u)"
    for process_dir in "$PROC_ROOT"/[0-9]*; do
        [[ -r "$process_dir/comm" ]] || continue
        comm_value="$(<"$process_dir/comm")"
        [[ "$comm_value" == "$SHELL_COMM" ]] || continue
        [[ "$(stat -c %u "$process_dir")" == "$own_uid" ]] || continue
        candidate_pids+=("${process_dir##*/}")
    done
    (( ${#candidate_pids[@]} == 1 )) \
        || die "expected one $SHELL_COMM owned by uid $own_uid, found ${#candidate_pids[@]} (set GNOME_SHELL_PID to choose)"
    printf '%s' "${candidate_pids[0]}"
}

#######################################
# Print the pid of a service: its unit's MainPID. Die when systemctl cannot
# answer, or the unit has no running main process (MainPID 0).
# Arguments:
#   $1 - the unit: SERVICE_UNIT or COCKPIT_UNIT
#   $2 - how it gets started, said when it is not running
#######################################
find_unit_main_pid() {
    local unit="$1" start_hint="$2" main_pid
    main_pid="$(systemctl --user show -p MainPID --value "$unit")" \
        || die "systemctl --user show $unit failed: is a user manager running?"
    [[ "$main_pid" =~ ^[0-9]+$ ]] || die "$unit's MainPID is not a number: '$main_pid'"
    (( main_pid > 0 )) || die "$unit is not running (MainPID 0): $start_hint"
    printf '%s' "$main_pid"
}

#######################################
# Print the pid of what is measured: the sampler service, the cockpit service,
# or gnome-shell.
# Arguments:
#   $1 - MEASURED_SERVICE, MEASURED_COCKPIT or MEASURED_GNOME_SHELL
#######################################
find_measured_pid() {
    case "$1" in
        "$MEASURED_SERVICE") find_unit_main_pid "$SERVICE_UNIT" "$SERVICE_START_HINT" ;;
        "$MEASURED_COCKPIT") find_unit_main_pid "$COCKPIT_UNIT" "$COCKPIT_START_HINT" ;;
        *) find_gnome_shell_pid ;;
    esac
}

#######################################
# Print the resident set size of a process in KiB, from its status file.
# Arguments:
#   $1 - pid
#######################################
read_rss_kib() {
    local status_path="$PROC_ROOT/$1/status" status_line
    [[ -r "$status_path" ]] || die "cannot read $status_path"
    while IFS= read -r status_line; do
        if [[ "$status_line" =~ ^VmRSS:[[:space:]]+([0-9]+)[[:space:]]kB ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return
        fi
    done <"$status_path"
    die "no VmRSS line in $status_path"
}

#######################################
# Set RUN_NANOSECONDS_READ to the first field of a schedstat file: the thread's
# time on a CPU, in ns. Fails, leaving it empty, when the file cannot be read;
# exit 2 when it holds no whole number.
# Arguments:
#   $1 - schedstat path
#######################################
read_schedstat_run_nanoseconds() {
    local schedstat_path="$1"
    RUN_NANOSECONDS_READ=""
    read -r RUN_NANOSECONDS_READ _ 2>/dev/null <"$schedstat_path"
    [[ -n "$RUN_NANOSECONDS_READ" ]] || return 1
    [[ "$RUN_NANOSECONDS_READ" =~ $WHOLE_NUMBER_PATTERN ]] || die "malformed $schedstat_path"
}

#######################################
# Fill THREAD_RUN_NANOSECONDS with every thread's time on a CPU (ns), keyed by
# tid. A thread whose directory is gone by the time it is read ended meanwhile
# and is left out; a thread still listed whose schedstat cannot be read (a
# kernel that keeps none), a process with no task directory, or no thread read
# at all, means nothing can be measured: exit 2, never a reading of 0.
# Arguments:
#   $1 - pid
#######################################
read_thread_run_nanoseconds() {
    local task_root="$PROC_ROOT/$1/$TASK_DIR_NAME" task_dir schedstat_path
    THREAD_RUN_NANOSECONDS=()
    [[ -d "$task_root" ]] || die "cannot read $task_root"
    for task_dir in "$task_root"/[0-9]*; do
        schedstat_path="$task_dir/$SCHEDSTAT_FILE_NAME"
        if ! read_schedstat_run_nanoseconds "$schedstat_path"; then
            [[ -d "$task_dir" ]] && die "cannot read $schedstat_path"
            continue
        fi
        THREAD_RUN_NANOSECONDS["${task_dir##*/}"]="$RUN_NANOSECONDS_READ"
    done
    (( ${#THREAD_RUN_NANOSECONDS[@]} > 0 )) || die "no thread's schedstat could be read under $task_root"
}

#######################################
# Set MAIN_THREAD_RUN_NANOSECONDS to the main thread's time on a CPU (ns): the
# thread whose tid is the pid. Exit 2 when it cannot be read.
# Arguments:
#   $1 - pid
#######################################
read_main_thread_run_nanoseconds() {
    local schedstat_path="$PROC_ROOT/$1/$TASK_DIR_NAME/$1/$SCHEDSTAT_FILE_NAME"
    read_schedstat_run_nanoseconds "$schedstat_path" || die "cannot read $schedstat_path"
    MAIN_THREAD_RUN_NANOSECONDS="$RUN_NANOSECONDS_READ"
}

#######################################
# Print a process's CPU use over a window as a percent of one core: the time on
# a CPU every thread gained, from the scheduler's nanosecond counters. A thread
# that started during the window counts from 0.
# Arguments:
#   $1 - pid
#   $2 - window length in seconds (positive integer)
#######################################
measure_cpu_percent() {
    local pid="$1" window_seconds="$2" tid window_run_nanoseconds=0 window_nanoseconds
    local -A run_nanoseconds_before=()
    read_thread_run_nanoseconds "$pid"
    for tid in "${!THREAD_RUN_NANOSECONDS[@]}"; do
        run_nanoseconds_before["$tid"]="${THREAD_RUN_NANOSECONDS[$tid]}"
    done
    sleep "$window_seconds"
    read_thread_run_nanoseconds "$pid"
    for tid in "${!THREAD_RUN_NANOSECONDS[@]}"; do
        window_run_nanoseconds=$(( window_run_nanoseconds + ${THREAD_RUN_NANOSECONDS[$tid]} \
            - ${run_nanoseconds_before[$tid]:-0} ))
    done
    window_nanoseconds=$(( window_seconds * NANOSECONDS_PER_SECOND ))
    awk -v run_ns="$window_run_nanoseconds" -v window_ns="$window_nanoseconds" -v percent="$PERCENT_PER_FRACTION" \
        'BEGIN { printf "%.3f\n", run_ns / window_ns * percent }'
}

#######################################
# Print the median of the main thread's CPU per Sample tick over a window, in
# ms: the main thread's counter read once every SAMPLE_INTERVAL_SECONDS, for as
# many whole ticks as fit in the window. Of an even number of ticks, the upper
# of the two middle ones, as the performance session's tools took it.
# Arguments:
#   $1 - pid
#   $2 - window length in seconds (at least SAMPLE_INTERVAL_SECONDS)
#######################################
measure_tick_median_ms() {
    local pid="$1" window_seconds="$2" tick_count tick_index previous_run_nanoseconds
    local -a tick_run_nanoseconds=()
    tick_count=$(( window_seconds / SAMPLE_INTERVAL_SECONDS ))
    read_main_thread_run_nanoseconds "$pid"
    previous_run_nanoseconds="$MAIN_THREAD_RUN_NANOSECONDS"
    for (( tick_index = 0; tick_index < tick_count; tick_index++ )); do
        sleep "$SAMPLE_INTERVAL_SECONDS"
        read_main_thread_run_nanoseconds "$pid"
        tick_run_nanoseconds+=("$(( MAIN_THREAD_RUN_NANOSECONDS - previous_run_nanoseconds ))")
        previous_run_nanoseconds="$MAIN_THREAD_RUN_NANOSECONDS"
    done
    printf '%s\n' "${tick_run_nanoseconds[@]}" | sort -n \
        | awk -v nanoseconds_per_ms="$NANOSECONDS_PER_MILLISECOND" \
            '{ sorted[NR] = $1 } END { printf "%.2f\n", sorted[int(NR / 2) + 1] / nanoseconds_per_ms }'
}

#######################################
# Compare resident memory with a baseline; exit 1 when growth beats the tolerance.
# Arguments:
#   $1 - pid
#   $2 - baseline in KiB
#######################################
check_rss_growth() {
    local pid="$1" baseline_kib="$2" current_kib growth_kib tolerance_kib
    [[ "$baseline_kib" =~ ^[0-9]+$ ]] || die "baseline must be a whole number of KiB: $baseline_kib"
    current_kib="$(read_rss_kib "$pid")" || exit $?
    growth_kib=$(( current_kib - baseline_kib ))
    tolerance_kib=$(( RSS_GROWTH_TOLERANCE_MIB * KIB_PER_MIB ))
    printf 'baseline %s KiB, now %s KiB, growth %s KiB (tolerance %s KiB)\n' \
        "$baseline_kib" "$current_kib" "$growth_kib" "$tolerance_kib"
    (( growth_kib <= tolerance_kib ))
}

#######################################
# Die, naming the right flag and figure, for --rss-check under a service: the
# growth tripwire is gnome-shell's, and a service's budget is absolute.
# Arguments:
#   $1 - MEASURED_SERVICE or MEASURED_COCKPIT
#######################################
refuse_service_rss_check() {
    local service_flag="$SERVICE_FLAG" budget_mib="$SERVICE_RSS_BUDGET_MIB" budget_kib
    if [[ "$1" == "$MEASURED_COCKPIT" ]]; then
        service_flag="$COCKPIT_FLAG"
        budget_mib="$COCKPIT_RSS_BUDGET_MIB"
    fi
    budget_kib=$(( budget_mib * KIB_PER_MIB ))
    die "--rss-check is gnome-shell's growth tripwire; the service's" \
        "budget is absolute: $service_flag --rss-kib must read at most $budget_kib"
}

main() {
    local measured="$MEASURED_GNOME_SHELL" argument argument_measures mode mode_value measured_pid
    local -a mode_arguments=()
    local service_choice="[$SERVICE_FLAG|$COCKPIT_FLAG]"
    local cpu_modes="$service_choice --cpu-percent <seconds> | $service_choice --tick-median <seconds>"
    local usage_text="usage: $0 $cpu_modes | $service_choice --rss-kib | --rss-check <baseline_kib>"
    # --service or --cockpit anywhere, one of them only; everything else is the
    # mode and its value.
    for argument in "$@"; do
        case "$argument" in
            "$SERVICE_FLAG") argument_measures="$MEASURED_SERVICE" ;;
            "$COCKPIT_FLAG") argument_measures="$MEASURED_COCKPIT" ;;
            *)
                mode_arguments+=("$argument")
                continue ;;
        esac
        if [[ "$measured" != "$MEASURED_GNOME_SHELL" && "$measured" != "$argument_measures" ]]; then
            die "$usage_text"
        fi
        measured="$argument_measures"
    done
    mode="${mode_arguments[0]:-}"
    mode_value="${mode_arguments[1]:-}"
    case "$mode" in
        --cpu-percent)
            if (( ${#mode_arguments[@]} != 2 )) || ! [[ "$mode_value" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]]; then
                die "$usage_text"
            fi
            measured_pid="$(find_measured_pid "$measured")" || exit $?
            measure_cpu_percent "$measured_pid" "$mode_value" ;;
        --tick-median)
            if (( ${#mode_arguments[@]} != 2 )) || ! [[ "$mode_value" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]]; then
                die "$usage_text"
            fi
            (( mode_value >= SAMPLE_INTERVAL_SECONDS )) \
                || die "--tick-median needs at least one tick: a window of $SAMPLE_INTERVAL_SECONDS s or more"
            measured_pid="$(find_measured_pid "$measured")" || exit $?
            measure_tick_median_ms "$measured_pid" "$mode_value" ;;
        --rss-kib)
            (( ${#mode_arguments[@]} == 1 )) || die "$usage_text"
            measured_pid="$(find_measured_pid "$measured")" || exit $?
            read_rss_kib "$measured_pid" || exit $?
            printf '\n' ;;
        --rss-check)
            [[ "$measured" == "$MEASURED_GNOME_SHELL" ]] || refuse_service_rss_check "$measured"
            if (( ${#mode_arguments[@]} != 2 )) || [[ -z "$mode_value" ]]; then
                die "$usage_text"
            fi
            measured_pid="$(find_gnome_shell_pid)" || exit $?
            check_rss_growth "$measured_pid" "$mode_value" ;;
        *) die "$usage_text" ;;
    esac
}

main "$@"
