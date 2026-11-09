#!/usr/bin/env bash
#
# scripts/resource-pulse-cost.sh
# ==============================
#
# Measure what Resource Pulse costs. It has two parts, and each is measured on
# its own:
#   - the extension, which only draws, lives inside gnome-shell, so its cost is
#     gnome-shell's: take a reading with the extension off, another with it on,
#     and compare;
#   - the sampler service (resource-pulse.service) is a process of its own:
#     --service measures it directly, the same way.
#
# Usage:
#   scripts/resource-pulse-cost.sh [--service] --cpu-percent <seconds>
#       CPU over a window, as a % of ONE core
#   scripts/resource-pulse-cost.sh [--service] --rss-kib
#       resident memory, KiB
#   scripts/resource-pulse-cost.sh --rss-check <baseline_kib>
#       gnome-shell only: exit 0 when its resident memory grew by at most
#       RSS_GROWTH_TOLERANCE_MIB since the baseline, 1 otherwise; prints both
#       numbers either way. The service's RSS budget is absolute, not a growth
#       (at most SERVICE_RSS_BUDGET_MIB): read it with --service --rss-kib.
#
# Finding gnome-shell: the one process of this user whose comm is "gnome-shell".
# GNOME_SHELL_PID names it outright. More than one candidate, or none, is exit 2:
# a guess would measure the wrong process and look like a result.
# Finding the service: its unit's MainPID, from
# `systemctl --user show -p MainPID --value resource-pulse.service`. MainPID 0
# (not running) is exit 2.
#
# Reads only <proc root>/<pid>/comm, /stat and /status: no argument list, no
# environment and no process-listing tool, all of which print what other
# processes were started with and so end up in a transcript.
#
# Environment: PROC_ROOT (default /proc, overridable for the test fixture),
#              GNOME_SHELL_PID (never consulted with --service).
# Exit: 0 ok, 1 --rss-check failed, 2 could not measure or bad usage.

set -uo pipefail

readonly PROC_ROOT="${PROC_ROOT:-/proc}"
readonly SHELL_COMM="gnome-shell"
readonly SERVICE_UNIT="resource-pulse.service"
readonly SERVICE_FLAG="--service"
# What is measured: gnome-shell (the default), or the sampler service.
readonly MEASURED_GNOME_SHELL="gnome-shell"
readonly MEASURED_SERVICE="service"
readonly RSS_GROWTH_TOLERANCE_MIB=64
# The design's budget for the service's resident memory (docs/GNOME_CONFIGURATION_GUIDE.md).
readonly SERVICE_RSS_BUDGET_MIB=64
readonly KIB_PER_MIB=1024
readonly EXIT_BAD_USAGE_OR_NO_MEASUREMENT=2

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
# Print the pid of the sampler service: its unit's MainPID. Die when systemctl
# cannot answer, or the unit has no running main process (MainPID 0).
#######################################
find_service_pid() {
    local main_pid
    main_pid="$(systemctl --user show -p MainPID --value "$SERVICE_UNIT")" \
        || die "systemctl --user show $SERVICE_UNIT failed: is a user manager running?"
    [[ "$main_pid" =~ ^[0-9]+$ ]] || die "$SERVICE_UNIT's MainPID is not a number: '$main_pid'"
    (( main_pid > 0 )) \
        || die "$SERVICE_UNIT is not running (MainPID 0): its extension starts it, or: systemctl --user start $SERVICE_UNIT"
    printf '%s' "$main_pid"
}

#######################################
# Print the pid of what is measured: the sampler service, or gnome-shell.
# Arguments:
#   $1 - MEASURED_SERVICE or MEASURED_GNOME_SHELL
#######################################
find_measured_pid() {
    if [[ "$1" == "$MEASURED_SERVICE" ]]; then
        find_service_pid
    else
        find_gnome_shell_pid
    fi
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
# Print utime+stime of a process in clock ticks, from its stat file. The comm
# field may contain spaces and parentheses, so everything up to the LAST ")" is
# dropped before the fields are counted.
# Arguments:
#   $1 - pid
#######################################
read_cpu_ticks() {
    local stat_path="$PROC_ROOT/$1/stat" stat_line after_comm
    local -a fields
    [[ -r "$stat_path" ]] || die "cannot read $stat_path"
    stat_line="$(<"$stat_path")"
    after_comm="${stat_line##*) }"
    read -r -a fields <<<"$after_comm"
    # after_comm starts at field 3 (state), so utime (14) and stime (15) are indices 11 and 12.
    [[ "${fields[11]:-}" =~ ^[0-9]+$ && "${fields[12]:-}" =~ ^[0-9]+$ ]] || die "malformed $stat_path"
    printf '%s' "$(( fields[11] + fields[12] ))"
}

#######################################
# Print a process's CPU use over a window as a percent of one core.
# Arguments:
#   $1 - pid
#   $2 - window length in seconds (positive integer)
#######################################
measure_cpu_percent() {
    local pid="$1" window_seconds="$2" ticks_per_second ticks_before ticks_after
    ticks_per_second="$(getconf CLK_TCK)" || die "getconf CLK_TCK failed"
    ticks_before="$(read_cpu_ticks "$pid")" || exit $?
    sleep "$window_seconds"
    ticks_after="$(read_cpu_ticks "$pid")" || exit $?
    awk -v before="$ticks_before" -v after="$ticks_after" -v hz="$ticks_per_second" -v window="$window_seconds" \
        'BEGIN { printf "%.2f\n", (after - before) / (hz * window) * 100 }'
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

main() {
    local measured="$MEASURED_GNOME_SHELL" mode measured_pid
    if [[ "${1:-}" == "$SERVICE_FLAG" ]]; then
        measured="$MEASURED_SERVICE"
        shift
    fi
    mode="${1:-}"
    case "$mode" in
        --cpu-percent)
            [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "usage: [$SERVICE_FLAG] --cpu-percent <whole seconds>"
            measured_pid="$(find_measured_pid "$measured")" || exit $?
            measure_cpu_percent "$measured_pid" "$2" ;;
        --rss-kib)
            measured_pid="$(find_measured_pid "$measured")" || exit $?
            read_rss_kib "$measured_pid" || exit $?
            printf '\n' ;;
        --rss-check)
            [[ "$measured" == "$MEASURED_GNOME_SHELL" ]] || die "--rss-check is gnome-shell's growth tripwire; the service's" \
                "budget is absolute: $SERVICE_FLAG --rss-kib must read at most $(( SERVICE_RSS_BUDGET_MIB * KIB_PER_MIB ))"
            [[ -n "${2:-}" ]] || die "usage: --rss-check <baseline_kib>"
            measured_pid="$(find_gnome_shell_pid)" || exit $?
            check_rss_growth "$measured_pid" "$2" ;;
        *) die "usage: $0 [$SERVICE_FLAG] --cpu-percent <seconds> | [$SERVICE_FLAG] --rss-kib | --rss-check <baseline_kib>" ;;
    esac
}

main "$@"
