#!/usr/bin/env bash
#
# scripts/resource-pulse-nested.sh
# ================================
#
# Runs the checkout's Resource Pulse in a nested, headless GNOME Shell that
# cannot reach the live session, and drives it over that shell's private bus.
#
# Why not `dbus-run-session gnome-shell --devkit --wayland` with its own config,
# data and cache dirs: that shell still writes the LIVE crash-guard file
# ($XDG_RUNTIME_DIR/gnome-shell-disable-extensions, for 60 s), takes a logind
# sleep inhibitor and calls SetLockedHint on the live session, registers with
# GDM and GeoClue on the real system bus, and posts the user's extension uuids
# to extensions.gnome.org. Here each of those has nowhere to go:
#
#   display      --headless --virtual-monitor: no client of the live compositor
#   run dir      one 0700 directory per run, under a private base ($XDG_RUNTIME_DIR by
#                default), so no other user can list, reach or later claim anything in it
#   runtime dir  a private 0700 XDG_RUNTIME_DIR inside it, short (a socket path is at most 108 bytes)
#   session bus  a private dbus-daemon on a path socket in the run dir; its only activatable
#                service is dconf
#   system bus   a fake, empty dbus-daemon on a path socket in the run dir; fake-gdm.js owns
#                org.gnome.DisplayManager on it
#   environment  env -i with an explicit allowlist: no token, no WAYLAND_DISPLAY or DISPLAY,
#                no live bus; HOME, TMPDIR and every XDG dir inside the run directory
#   settings     the nested dconf only: no lock, no idle blank, a dead proxy, no location,
#                no extension installation (which also turns the update check off)
#   apps         the extension-update apps masked, so the shell sees no updater
#   unsafe mode  only through a throwaway helper extension copied into the run's data dir,
#                which refuses to act in any shell but this one
#   requests     eval and screenshot go only to a live run: its supervisor running, and its
#                recorded gnome-shell running, as gnome-shell, in the run's own session
#   lifetime     setsid + timeout --kill-after; stop tears down by the recorded PIDs, and
#                only ever signals processes in the run's own session
#
# Everything it creates is under the run directory. Any isolation step that
# fails stops the run: exit 2, and nothing left running.
#
# Not run in CI: it needs gnome-shell and a GPU render node. Its hermetic rows
# (usage, the bus configs, the environment, the refusals) are in
# scripts/test-resource-pulse.sh.
#
# Usage:
#   scripts/resource-pulse-nested.sh start
#       start a nested shell with the checkout's Resource Pulse enabled; print its
#       private bus address on stdout and the run directory on stderr
#   scripts/resource-pulse-nested.sh eval <javascript>|-
#       run JavaScript in the nested shell (org.gnome.Shell.Eval) and print the
#       JSON result; '-' reads the code from stdin
#   scripts/resource-pulse-nested.sh screenshot <name.png> [x y width height]
#       save the nested stage (or an area of it, in logical pixels) as
#       <run dir>/shots/<name.png>, and print that path
#   scripts/resource-pulse-nested.sh stop
#       stop the nested shell and everything it started; logs and shots stay
#
# Environment:
#   RESOURCE_PULSE_NESTED_DIR     the run directory eval, screenshot and stop act on
#                                 (needed only while more than one run is live)
#   RESOURCE_PULSE_NESTED_BASE    where run directories are made: yours, with no group or
#                                 other access (default $XDG_RUNTIME_DIR, else $TMPDIR)
#   RESOURCE_PULSE_NESTED_LIFETIME_SECONDS  a run's hard lifetime (default 1200)
#
# Exit: 0 ok; 1 the nested shell ran the request and it failed (an Eval that
#       threw, a screenshot it could not take); 2 refused, bad usage or could not run.

set -uo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_PATH")")"
readonly REPO_ROOT
readonly NESTED_FILES_DIR="$REPO_ROOT/gnome-shell/tests/nested"
readonly EXTENSION_UUID='resource-pulse@dotfiles'
readonly EXTENSION_SOURCE_DIR="$REPO_ROOT/gnome-shell/extensions/$EXTENSION_UUID"
readonly UNSAFE_MODE_HELPER_UUID='resource-pulse-nested-unsafe-mode@local'
readonly NESTED_SESSION_MODE='resource-pulse-nested'
readonly NESTED_SHELL_COMM='gnome-shell'
readonly DCONF_SERVICE_FILE='ca.desrt.dconf.service'
readonly DCONF_SERVICE_NAME='ca.desrt.dconf'
readonly DCONF_SERVICE_EXECUTABLE='/usr/libexec/dconf-service'
readonly FAKE_DISPLAY_MANAGER_NAME='org.gnome.DisplayManager'

readonly EXIT_REQUEST_FAILED=1
readonly EXIT_REFUSED=2

readonly RUN_DIR_PREFIX='rpn.'
readonly RUN_DIR_MARKER_FILE='.resource-pulse-nested'
readonly RUN_DIR_MODE='700'
readonly PRIVATE_UMASK='077'
# A mode (as `stat -c %a` prints it) with no group or other bits.
readonly PRIVATE_MODE_PATTERN='^[0-7]*00$'
readonly RUN_SUFFIX_PATTERN='^[A-Za-z0-9]+$'
# Only characters that are safe in a sed replacement, a D-Bus address and an unquoted XML text node.
readonly RUN_DIR_SAFE_PATH_PATTERN='^/[A-Za-z0-9/._-]+$'
# The nested shell makes sockets under <run>/run, and the buses listen under <run>/bus; a Unix socket path is at
# most 108 bytes.
readonly MAX_RUN_DIR_PATH_CHARS=48
readonly SESSION_BUS_SOCKET_RELATIVE_PATH='bus/session.sock'
readonly SYSTEM_BUS_SOCKET_RELATIVE_PATH='bus/system.sock'
readonly NESTED_WAYLAND_DISPLAY='rp-nested-0'
readonly NESTED_MONITOR_SIZE='3072x1920'
readonly NESTED_PATH='/usr/local/bin:/usr/bin:/bin'
readonly NESTED_LOCALE='C.UTF-8'
readonly NESTED_LOGIN_SHELL='/bin/bash'
readonly NESTED_CURRENT_DESKTOP='ubuntu:GNOME'
readonly SYSTEM_XDG_DATA_DIRS='/usr/share/ubuntu:/usr/local/share:/usr/share:/var/lib/snapd/desktop'
readonly SYSTEM_XDG_CONFIG_DIRS='/etc/xdg/xdg-ubuntu:/etc/xdg'
# A closed local port: anything that honours the proxy settings reaches nothing.
readonly DEAD_PROXY_HOST='127.0.0.1'
readonly DEAD_PROXY_PORT=9

readonly DEFAULT_LIFETIME_SECONDS=1200
readonly KILL_AFTER_SECONDS=10
readonly STARTUP_TIMEOUT_SECONDS=120
readonly FAKE_SYSTEM_BUS_TIMEOUT_SECONDS=10
readonly STOP_GRACE_SECONDS=15
readonly SWEEP_GRACE_SECONDS=3
readonly POLL_INTERVAL_SECONDS=0.2
readonly EVAL_TIMEOUT_SECONDS=60
readonly SCREENSHOT_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
readonly WHOLE_NUMBER_PATTERN='^[0-9]+$'
readonly POSITIVE_WHOLE_NUMBER_PATTERN='^[1-9][0-9]*$'
readonly DBUS_GUID_SUFFIX_PATTERN=',guid=[0-9a-f]+'
readonly PNG_SUFFIX='.png'
# /proc/<pid>/stat after the last ") ": state (field 3), ppid, pgrp, session (field 6).
readonly STAT_STATE_INDEX_AFTER_COMM=0
readonly STAT_SESSION_INDEX_AFTER_COMM=3
readonly DEAD_PROCESS_STATES='ZX'

# The one environment every nested process gets, filled by build_isolated_env_command.
ISOLATED_ENV_COMMAND=()
# The fields of the last stat line read_stat_fields read, from the state (field 3) on.
STAT_FIELDS_AFTER_COMM=()

#######################################
# Print a message to stderr.
# Arguments:
#   $@ - message
#######################################
note() {
    printf 'resource-pulse-nested: %s\n' "$*" >&2
}

#######################################
# Print a message to stderr and exit 2: refused, or could not run.
# Arguments:
#   $@ - message
#######################################
die() {
    note "$*"
    exit "$EXIT_REFUSED"
}

#######################################
# Print the usage block.
#######################################
print_usage() {
    cat <<'USAGE'
usage: scripts/resource-pulse-nested.sh start
       scripts/resource-pulse-nested.sh eval <javascript>|-
       scripts/resource-pulse-nested.sh screenshot <name.png> [x y width height]
       scripts/resource-pulse-nested.sh stop
USAGE
}

#######################################
# Print a usage error and the usage to stderr, then exit 2.
# Arguments:
#   $1 - what was wrong
#######################################
usage_error() {
    note "$1"
    print_usage >&2
    exit "$EXIT_REFUSED"
}

#######################################
# Exit 2 unless every named command exists.
# Arguments:
#   $@ - command names
#######################################
require_tools() {
    local tool_name
    for tool_name in "$@"; do
        command -v "$tool_name" >/dev/null || die "$tool_name is required"
    done
}

#######################################
# Print the directory run directories are made in.
#######################################
nested_base_dir() {
    printf '%s' "${RESOURCE_PULSE_NESTED_BASE:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}}"
}

#######################################
# Succeed when a directory is this user's and nobody else can enter or list it.
# Arguments:
#   $1 - directory
#######################################
is_private_directory() {
    [[ -d "$1" && -O "$1" && "$(stat -c %a "$1")" =~ $PRIVATE_MODE_PATTERN ]]
}

#######################################
# Read a process's stat line into STAT_FIELDS_AFTER_COMM; fail when the
# process is gone, unreadable, or a zombie. comm may hold spaces and ") ", so
# the fields are counted after the LAST ") ". Reads only <pid>/stat: never an
# argument list or an environment.
# Arguments:
#   $1 - proc root (/proc, or a fixture)
#   $2 - pid
#######################################
read_stat_fields() {
    local stat_line
    STAT_FIELDS_AFTER_COMM=()
    read -r stat_line 2>/dev/null <"$1/$2/stat" || return 1
    read -r -a STAT_FIELDS_AFTER_COMM <<<"${stat_line##*) }"
    [[ "$DEAD_PROCESS_STATES" != *"${STAT_FIELDS_AFTER_COMM[$STAT_STATE_INDEX_AFTER_COMM]:-Z}"* ]] || return 1
    [[ "${STAT_FIELDS_AFTER_COMM[$STAT_SESSION_INDEX_AFTER_COMM]:-}" =~ $WHOLE_NUMBER_PATTERN ]]
}

#######################################
# Print the session id of a running process; fail when it is not running.
# Arguments:
#   $1 - proc root
#   $2 - pid
#######################################
session_id_of_process() {
    read_stat_fields "$1" "$2" || return 1
    printf '%s' "${STAT_FIELDS_AFTER_COMM[$STAT_SESSION_INDEX_AFTER_COMM]}"
}

#######################################
# Print, one per line, every running pid under a proc root whose session is
# the given one.
# Arguments:
#   $1 - proc root
#   $2 - session id
#######################################
pids_in_session() {
    local proc_root="$1" session_id="$2" process_dir pid
    for process_dir in "$proc_root"/[0-9]*; do
        pid="${process_dir##*/}"
        read_stat_fields "$proc_root" "$pid" || continue
        if [[ "${STAT_FIELDS_AFTER_COMM[$STAT_SESSION_INDEX_AFTER_COMM]}" == "$session_id" ]]; then
            printf '%s\n' "$pid"
        fi
    done
    return 0
}

#######################################
# Succeed when no process is left in a session.
# Arguments:
#   $1 - session id
#######################################
is_session_empty() {
    [[ -z "$(pids_in_session /proc "$1")" ]]
}

#######################################
# Append name=value to the run's record of what it started.
# Arguments:
#   $1 - run directory
#   $2 - name
#   $3 - value
#######################################
record_run_value() {
    printf '%s=%s\n' "$2" "$3" >>"$1/state/run.values"
}

#######################################
# Print the last value recorded under a name, or nothing.
# Arguments:
#   $1 - run directory
#   $2 - name
#######################################
recorded_run_value() {
    local values_path="$1/state/run.values" values_line recorded_value=""
    [[ -r "$values_path" ]] || return 0
    while IFS= read -r values_line; do
        [[ "$values_line" == "$2="* ]] && recorded_value="${values_line#"$2="}"
    done <"$values_path"
    printf '%s' "$recorded_value"
}

#######################################
# Record why a run refused to go on, where `start` reads it, then exit 2.
# Arguments:
#   $1 - run directory
#   $2 - reason
#######################################
refuse_run() {
    printf '%s\n' "$2" >>"$1/state/refused"
    die "refusing: $2"
}

#######################################
# Print a run directory's suffix (the part after "rpn."); fail unless the
# directory is a run directory of this script: ours, private, and marked with
# the same suffix as its name.
# Arguments:
#   $1 - run directory
#######################################
verified_run_suffix() {
    local run_dir="$1" run_suffix marker_suffix
    [[ "$run_dir" =~ $RUN_DIR_SAFE_PATH_PATTERN && -d "$run_dir" && -O "$run_dir" ]] || return 1
    [[ "$(stat -c %a "$run_dir")" == "$RUN_DIR_MODE" ]] || return 1
    [[ -f "$run_dir/$RUN_DIR_MARKER_FILE" && -O "$run_dir/$RUN_DIR_MARKER_FILE" ]] || return 1
    run_suffix="${run_dir##*/"$RUN_DIR_PREFIX"}"
    read -r marker_suffix <"$run_dir/$RUN_DIR_MARKER_FILE" || return 1
    [[ "$run_suffix" =~ $RUN_SUFFIX_PATTERN && "$run_suffix" == "$marker_suffix" ]] || return 1
    printf '%s' "$run_suffix"
}

#######################################
# Print the address of a run's fake system bus (its path socket).
# Arguments:
#   $1 - run directory
#######################################
fake_system_bus_address() {
    printf 'unix:path=%s/%s' "$1" "$SYSTEM_BUS_SOCKET_RELATIVE_PATH"
}

#######################################
# Fill ISOLATED_ENV_COMMAND with `env -i` and the allowlist: a command run
# through it inherits nothing from the caller.
# Arguments:
#   $1 - run directory
#######################################
build_isolated_env_command() {
    local -a assignments
    mapfile -t assignments < <(nested_environment_assignments "$1")
    (( ${#assignments[@]} > 0 )) || return 1
    ISOLATED_ENV_COMMAND=(env -i "${assignments[@]}")
}

#######################################
# Print, one NAME=value per line, the whole environment of every nested
# process. Nothing is passed through from the caller: no token, no live
# display, no live bus.
# Arguments:
#   $1 - run directory
#######################################
nested_environment_assignments() {
    local run_dir="$1" user_name
    user_name="$(id -un)" || return 1
    printf '%s\n' \
        "HOME=$run_dir/home" \
        "USER=$user_name" \
        "LOGNAME=$user_name" \
        "SHELL=$NESTED_LOGIN_SHELL" \
        "PATH=$NESTED_PATH" \
        "LANG=$NESTED_LOCALE" \
        "LC_ALL=$NESTED_LOCALE" \
        "TMPDIR=$run_dir/tmp" \
        "XDG_CONFIG_HOME=$run_dir/config" \
        "XDG_DATA_HOME=$run_dir/data" \
        "XDG_CACHE_HOME=$run_dir/cache" \
        "XDG_RUNTIME_DIR=$run_dir/run" \
        "XDG_DATA_DIRS=$run_dir/sysdata:$SYSTEM_XDG_DATA_DIRS" \
        "XDG_CONFIG_DIRS=$SYSTEM_XDG_CONFIG_DIRS" \
        "XDG_CURRENT_DESKTOP=$NESTED_CURRENT_DESKTOP" \
        "XDG_SESSION_TYPE=wayland" \
        "DBUS_SYSTEM_BUS_ADDRESS=$(fake_system_bus_address "$run_dir")" \
        "GIO_USE_VFS=local" \
        "GIO_USE_VOLUME_MONITOR=unix" \
        "NO_AT_BRIDGE=1" \
        "GTK_A11Y=none" \
        "RESOURCE_PULSE_NESTED_DIR=$run_dir"
}

#######################################
# Run a command with only the nested environment (used by the hermetic rows;
# the launch itself uses ISOLATED_ENV_COMMAND directly, so env execs in place).
# Arguments:
#   $1 - run directory
#   $@ - command
#######################################
run_isolated() {
    build_isolated_env_command "$1" || return "$EXIT_REFUSED"
    shift
    "${ISOLATED_ENV_COMMAND[@]}" "$@"
}

#######################################
# Print a bus config template with the run directory and its session service
# dir filled in.
# Arguments:
#   $1 - template path
#   $2 - run directory
#######################################
render_bus_config() {
    local template_path="$1" run_dir="$2"
    [[ "$run_dir" =~ $RUN_DIR_SAFE_PATH_PATTERN ]] || return 1
    sed -e "s|@RUN_DIR@|$run_dir|g" -e "s|@SESSION_SERVICE_DIR@|$run_dir/bus/session-services|g" "$template_path"
}

#######################################
# Lay out a fresh run directory: the private homes and runtime dir, the bus
# configs, the one dconf service, the session mode, the app masks, the
# unsafe-mode helper and a copy of the checkout's extension.
# Arguments:
#   $1 - run directory (exists, empty, 0700)
#   $2 - run suffix
#######################################
prepare_run_directory() {
    local run_dir="$1" run_suffix="$2"
    local -a subdirectories=(run config cache home tmp data/applications data/gnome-shell/extensions
        sysdata/gnome-shell/modes bus/session-services state log shots)
    # Every directory private to the user, intermediate ones included (the runtime dir must be 0700).
    (umask "$PRIVATE_UMASK" && mkdir -p "${subdirectories[@]/#/$run_dir/}") || return 1
    printf '%s\n' "$run_suffix" >"$run_dir/$RUN_DIR_MARKER_FILE" || return 1
    render_bus_config "$NESTED_FILES_DIR/session-bus.conf.in" "$run_dir" >"$run_dir/bus/session-bus.conf" || return 1
    render_bus_config "$NESTED_FILES_DIR/system-bus.conf.in" "$run_dir" >"$run_dir/bus/system-bus.conf" || return 1
    cp -- "$NESTED_FILES_DIR/session-services/$DCONF_SERVICE_FILE" "$run_dir/bus/session-services/" || return 1
    cp -- "$NESTED_FILES_DIR/$NESTED_SESSION_MODE.json" "$run_dir/sysdata/gnome-shell/modes/" || return 1
    cp -- "$NESTED_FILES_DIR"/applications/*.desktop "$run_dir/data/applications/" || return 1
    cp -R -- "$NESTED_FILES_DIR/$UNSAFE_MODE_HELPER_UUID" "$run_dir/data/gnome-shell/extensions/" || return 1
    cp -R -- "$EXTENSION_SOURCE_DIR" "$run_dir/data/gnome-shell/extensions/" || return 1
}

#######################################
# Succeed only when a session bus config can activate dconf and nothing else:
# one service dir, the run's own, holding only the dconf service file, and no
# standard service dirs, included configs or activation helper.
# Arguments:
#   $1 - config path
#   $2 - the run's session service dir
#######################################
session_bus_config_permits_only_dconf() {
    local config_path="$1" services_dir="$2" config_line service_dir_count=0 service_file_names service_line
    local has_dconf_name=false has_dconf_executable=false
    [[ -r "$config_path" ]] || return 1
    while IFS= read -r config_line; do
        case "$config_line" in
            *'<standard_session_servicedirs'* | *'<standard_system_servicedirs'* | *'<include'* | *'<servicehelper'*)
                return 1 ;;
            *'<servicedir>'*)
                service_dir_count=$((service_dir_count + 1))
                [[ "$config_line" == *"<servicedir>$services_dir</servicedir>"* ]] || return 1 ;;
        esac
    done <"$config_path"
    (( service_dir_count == 1 )) || return 1
    service_file_names="$(shopt -s dotglob nullglob && cd "$services_dir" && printf '%s\n' *)" || return 1
    [[ "$service_file_names" == "$DCONF_SERVICE_FILE" ]] || return 1
    while IFS= read -r service_line; do
        case "$service_line" in
            "Name=$DCONF_SERVICE_NAME") has_dconf_name=true ;;
            "Exec=$DCONF_SERVICE_EXECUTABLE") has_dconf_executable=true ;;
            Name=* | Exec=* | SystemdService=*) return 1 ;;
        esac
    done <"$services_dir/$DCONF_SERVICE_FILE"
    [[ "$has_dconf_name" == true && "$has_dconf_executable" == true ]]
}

#######################################
# Succeed only when a bus config can activate nothing at all: no service dir of
# any kind, no included config, no activation helper.
# Arguments:
#   $1 - config path
#######################################
system_bus_config_activates_nothing() {
    local config_path="$1" config_line
    [[ -r "$config_path" ]] || return 1
    while IFS= read -r config_line; do
        case "$config_line" in
            *'<servicedir'* | *'_servicedirs'* | *'<include'* | *'<servicehelper'*) return 1 ;;
        esac
    done <"$config_path"
    return 0
}

#######################################
# Succeed only inside a nested run's own environment: the run directory named,
# every home and the runtime dir inside it, the fake system bus, no display.
# Arguments:
#   $1 - run directory
#######################################
is_isolated_environment() {
    local run_dir="$1" variable_name
    [[ "${RESOURCE_PULSE_NESTED_DIR:-}" == "$run_dir" ]] || { note "RESOURCE_PULSE_NESTED_DIR is not $run_dir"; return 1; }
    for variable_name in HOME TMPDIR XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR; do
        if [[ "${!variable_name:-}" != "$run_dir/"* ]]; then
            note "$variable_name is outside the run directory: '${!variable_name:-}'"
            return 1
        fi
    done
    if [[ "${DBUS_SYSTEM_BUS_ADDRESS:-}" != "$(fake_system_bus_address "$run_dir")" ]]; then
        note "the system bus is not the fake one: '${DBUS_SYSTEM_BUS_ADDRESS:-}'"
        return 1
    fi
    [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]] || { note "a display is set"; return 1; }
}

#######################################
# Succeed when an address is exactly a bus socket of this run (as dbus-daemon
# prints it, with or without its guid).
# Arguments:
#   $1 - address
#   $2 - run directory
#   $3 - the socket's path relative to the run directory
#######################################
is_run_bus_address() {
    local run_bus_address="unix:path=$2/$3"
    [[ "$1" == "$run_bus_address" || "$1" =~ ^"$run_bus_address"$DBUS_GUID_SUFFIX_PATTERN$ ]]
}

#######################################
# Succeed when an address is exactly this run's private session bus.
# Arguments:
#   $1 - address
#   $2 - run directory
#######################################
is_private_session_bus_address() {
    is_run_bus_address "$1" "$2" "$SESSION_BUS_SOCKET_RELATIVE_PATH"
}

#######################################
# Print the run's recorded session bus address; refuse (exit 2) unless it is
# this run's private bus, so nothing below can ever reach the live one.
# Arguments:
#   $1 - run directory
#######################################
verified_session_address() {
    local recorded_address=""
    [[ -r "$1/state/session.addr" ]] && read -r recorded_address <"$1/state/session.addr"
    is_private_session_bus_address "$recorded_address" "$1" \
        || die "refusing: '$recorded_address' is not this run's private session bus"
    printf '%s' "$recorded_address"
}

#######################################
# Succeed while a process is running (not gone, not a zombie).
# Arguments:
#   $1 - pid
#######################################
is_process_running() {
    [[ -n "$1" ]] && session_id_of_process /proc "$1" >/dev/null
}

#######################################
# Succeed while the run's supervisor, or before it has recorded itself the
# launcher, is still running: either is alive for the whole run.
# Arguments:
#   $1 - run directory
#######################################
is_run_alive() {
    is_process_running "$(recorded_run_value "$1" supervisor)" ||
        is_process_running "$(recorded_run_value "$1" launcher)"
}

#######################################
# Succeed only when the run is alive and its recorded gnome-shell is running,
# under that name, in the run's own session: the bus it recorded is then still
# the one that shell owns, not a socket left from an ended run.
# Arguments:
#   $1 - run directory
#######################################
is_nested_shell_live() {
    local run_dir="$1" session_id shell_pid shell_comm=""
    is_run_alive "$run_dir" || { note "the run's supervisor is not running"; return 1; }
    session_id="$(recorded_run_value "$run_dir" session)"
    shell_pid="$(recorded_run_value "$run_dir" gnome-shell)"
    if ! [[ "$session_id" =~ $POSITIVE_WHOLE_NUMBER_PATTERN && "$shell_pid" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]]; then
        note "the run has no recorded session or gnome-shell"
        return 1
    fi
    if [[ "$(session_id_of_process /proc "$shell_pid")" != "$session_id" ]]; then
        note "the recorded gnome-shell ($shell_pid) is not running in the run's session ($session_id)"
        return 1
    fi
    read -r shell_comm 2>/dev/null <"/proc/$shell_pid/comm"
    [[ "$shell_comm" == "$NESTED_SHELL_COMM" ]] || { note "process $shell_pid is '$shell_comm', not $NESTED_SHELL_COMM"; return 1; }
}

#######################################
# Print the run directory eval, screenshot and stop act on:
# RESOURCE_PULSE_NESTED_DIR, else the one run under the base that is not
# stopped. Exit 2 when there is none, or more than one.
#######################################
resolve_run_directory() {
    local base_dir marker_path run_dir
    local -a live_run_dirs=()
    if [[ -n "${RESOURCE_PULSE_NESTED_DIR:-}" ]]; then
        verified_run_suffix "$RESOURCE_PULSE_NESTED_DIR" >/dev/null \
            || die "RESOURCE_PULSE_NESTED_DIR is not a run directory of this script: $RESOURCE_PULSE_NESTED_DIR"
        printf '%s' "$RESOURCE_PULSE_NESTED_DIR"
        return 0
    fi
    base_dir="$(nested_base_dir)"
    for marker_path in "$base_dir/$RUN_DIR_PREFIX"*/"$RUN_DIR_MARKER_FILE"; do
        run_dir="${marker_path%/*}"
        [[ -e "$marker_path" && ! -e "$run_dir/state/stopped" ]] || continue
        verified_run_suffix "$run_dir" >/dev/null && live_run_dirs+=("$run_dir")
    done
    case "${#live_run_dirs[@]}" in
        0) die "no live run under $base_dir: start one with: $0 start" ;;
        1) printf '%s' "${live_run_dirs[0]}" ;;
        *) die "several live runs; set RESOURCE_PULSE_NESTED_DIR to one of: ${live_run_dirs[*]}" ;;
    esac
}

#######################################
# Print the private bus address of the run eval and screenshot act on; exit 2
# unless the address is the run's own and the run is live.
#######################################
live_run_session_address() {
    local run_dir address
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    verified_run_suffix "$run_dir" >/dev/null || die "not a run directory of this script: $run_dir"
    address="$(verified_session_address "$run_dir")" || exit "$EXIT_REFUSED"
    is_nested_shell_live "$run_dir" || die "refusing: the run in $run_dir is not live"
    printf '%s' "$address"
}

#######################################
# Run JavaScript in the nested shell over its private bus and print the JSON
# result. Returns 0 on success, 1 when the code threw, 2 when the call failed.
# Arguments:
#   $1 - verified private bus address
#   $2 - JavaScript
#######################################
eval_in_nested_shell() {
    local address="$1" code="$2" reply has_succeeded result
    reply="$(busctl --address="$address" --json=short --timeout="$EVAL_TIMEOUT_SECONDS" \
        call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s "$code" 2>&1)" \
        || { note "the Eval call failed: $reply"; return "$EXIT_REFUSED"; }
    has_succeeded="$(jq -r '.data[0]' <<<"$reply")" || return "$EXIT_REFUSED"
    result="$(jq -r '.data[1]' <<<"$reply")" || return "$EXIT_REFUSED"
    if [[ "$has_succeeded" != true ]]; then
        note "the nested shell reported: $result"
        return "$EXIT_REQUEST_FAILED"
    fi
    printf '%s\n' "$result"
}

#######################################
# Print the session a run lives in: the one its supervisor recorded, else the
# launcher's own (setsid makes the launcher a session leader). Prints nothing
# when neither is known or running.
# Arguments:
#   $1 - run directory
#######################################
run_session_id() {
    local recorded_session_id launcher_pid
    recorded_session_id="$(recorded_run_value "$1" session)"
    if [[ -n "$recorded_session_id" ]]; then
        printf '%s' "$recorded_session_id"
        return 0
    fi
    launcher_pid="$(recorded_run_value "$1" launcher)"
    if [[ -n "$launcher_pid" && "$(session_id_of_process /proc "$launcher_pid")" == "$launcher_pid" ]]; then
        printf '%s' "$launcher_pid"
    fi
}

#######################################
# Send a signal to every process in a session but the excluded ones, then wait
# up to a grace period for them to go. Only pids read from /proc as members of
# that session are ever signalled.
# Arguments:
#   $1 - session id
#   $2 - signal name
#   $3 - grace seconds
#   $@ - pids to leave alone
#######################################
signal_session() {
    local session_id="$1" signal_name="$2" grace_seconds="$3" session_pid deadline
    shift 3
    local -a excluded_pids=("$@")
    for session_pid in $(pids_in_session /proc "$session_id"); do
        [[ " ${excluded_pids[*]} " == *" $session_pid "* ]] && continue
        kill "-$signal_name" "$session_pid" 2>/dev/null
    done
    deadline=$((SECONDS + grace_seconds))
    while (( SECONDS < deadline )); do
        [[ -z "$(remaining_session_pids "$session_id" "${excluded_pids[@]}")" ]] && return 0
        sleep "$POLL_INTERVAL_SECONDS"
    done
    [[ -z "$(remaining_session_pids "$session_id" "${excluded_pids[@]}")" ]]
}

#######################################
# Print the session's pids other than the excluded ones.
# Arguments:
#   $1 - session id
#   $@ - pids to leave out
#######################################
remaining_session_pids() {
    local session_id="$1" session_pid
    shift
    for session_pid in $(pids_in_session /proc "$session_id"); do
        [[ " $* " == *" $session_pid "* ]] || printf '%s ' "$session_pid"
    done
}

#######################################
# The supervisor's exit: end every process left in its session (SIGTERM, then
# SIGKILL after a grace), whatever ended the run.
# Arguments:
#   $1 - run directory
#   $2 - session id
#######################################
end_supervised_session() {
    local run_dir="$1" session_id="$2"
    signal_session "$session_id" TERM "$SWEEP_GRACE_SECONDS" "$$" "$PPID" \
        || signal_session "$session_id" KILL "$SWEEP_GRACE_SECONDS" "$$" "$PPID" \
        || note "processes outlived SIGKILL in session $session_id"
    record_run_value "$run_dir" supervisor-exited "$(date -Is)"
}

#######################################
# Wait until a condition command succeeds, up to a number of seconds.
# Arguments:
#   $1 - seconds
#   $@ - condition command
#######################################
wait_until() {
    local deadline=$((SECONDS + $1))
    shift
    while (( SECONDS < deadline )); do
        "$@" && return 0
        sleep "$POLL_INTERVAL_SECONDS"
    done
    "$@"
}

#######################################
# Succeed once the fake system bus has printed this run's address.
# Arguments:
#   $1 - run directory
#######################################
has_fake_system_bus_address() {
    local printed_address=""
    [[ -s "$1/state/system.addr" ]] && read -r printed_address <"$1/state/system.addr"
    is_run_bus_address "$printed_address" "$1" "$SYSTEM_BUS_SOCKET_RELATIVE_PATH"
}

#######################################
# Succeed once fake-gdm owns its name on the fake system bus.
#######################################
does_fake_display_manager_own_its_name() {
    [[ "$(busctl --address="$DBUS_SYSTEM_BUS_ADDRESS" call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus NameHasOwner s "$FAKE_DISPLAY_MANAGER_NAME" 2>/dev/null)" == 'b true' ]]
}

#######################################
# Stage 2, inside `setsid timeout` with the isolated environment: start the
# fake system bus, fake-gdm on it, then the private session bus with stage 3
# inside it, and wait. Its exit ends every process left in its session.
# Arguments:
#   $1 - run directory
#######################################
supervise_run() {
    local run_dir="$1" own_session_id shell_session_pid shell_session_status
    verified_run_suffix "$run_dir" >/dev/null || die "not a run directory of this script: $run_dir"
    is_isolated_environment "$run_dir" || refuse_run "$run_dir" "the supervisor is not isolated"
    [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || refuse_run "$run_dir" "the supervisor inherited a session bus"
    own_session_id="$(session_id_of_process /proc "$$")" || refuse_run "$run_dir" "cannot read the supervisor's session"
    [[ "$own_session_id" == "$PPID" ]] || refuse_run "$run_dir" "the supervisor is not in the session setsid made"
    record_run_value "$run_dir" supervisor "$$"
    record_run_value "$run_dir" session "$own_session_id"
    # run_dir and own_session_id are checked above to hold no quote or space, so expanding them now is safe.
    # shellcheck disable=SC2064
    trap "end_supervised_session '$run_dir' '$own_session_id'" EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT

    dbus-daemon --config-file="$run_dir/bus/system-bus.conf" --nofork --print-address=1 \
        >"$run_dir/state/system.addr" 2>"$run_dir/log/system-bus.log" &
    record_run_value "$run_dir" fake-system-bus "$!"
    wait_until "$FAKE_SYSTEM_BUS_TIMEOUT_SECONDS" has_fake_system_bus_address "$run_dir" \
        || refuse_run "$run_dir" "the fake system bus did not start (log/system-bus.log)"

    gjs -m "$NESTED_FILES_DIR/fake-gdm.js" "$DBUS_SYSTEM_BUS_ADDRESS" >"$run_dir/log/fake-gdm.log" 2>&1 &
    record_run_value "$run_dir" fake-gdm "$!"
    wait_until "$FAKE_SYSTEM_BUS_TIMEOUT_SECONDS" does_fake_display_manager_own_its_name \
        || refuse_run "$run_dir" "fake-gdm did not take $FAKE_DISPLAY_MANAGER_NAME (log/fake-gdm.log)"

    dbus-run-session --config-file="$run_dir/bus/session-bus.conf" -- \
        bash "$SCRIPT_PATH" __inside-session-bus "$run_dir" >"$run_dir/log/shell.log" 2>&1 &
    shell_session_pid=$!
    record_run_value "$run_dir" dbus-run-session "$shell_session_pid"
    wait "$shell_session_pid"
    shell_session_status=$?
    record_run_value "$run_dir" dbus-run-session-exit "$shell_session_status"
}

#######################################
# Set one key in the NESTED dconf database (only ever called inside the
# private session bus, after is_isolated_environment).
# Arguments:
#   $1 - schema
#   $2 - key
#   $3 - value
#######################################
set_nested_key() {
    gsettings set "$1" "$2" "$3" || { note "gsettings set $1 $2 $3 failed"; return 1; }
}

#######################################
# Write the nested shell's settings: the two extensions; what keeps it from
# locking, blanking, reaching the network or checking for extension updates;
# and the reference laptop's look (Ubuntu's defaults plus
# scripts/apply-gnome-settings.sh), so the card is judged against the real theme.
#######################################
write_nested_settings() {
    set_nested_key org.gnome.shell enabled-extensions "['$UNSAFE_MODE_HELPER_UUID', '$EXTENSION_UUID']" &&
    set_nested_key org.gnome.shell allow-extension-installation false &&
    set_nested_key org.gnome.desktop.screensaver lock-enabled false &&
    set_nested_key org.gnome.desktop.screensaver ubuntu-lock-on-suspend false &&
    set_nested_key org.gnome.desktop.lockdown disable-lock-screen true &&
    set_nested_key org.gnome.desktop.session idle-delay 0 &&
    set_nested_key org.gnome.system.location enabled false &&
    set_nested_key org.gnome.system.proxy mode "'manual'" &&
    set_nested_key org.gnome.system.proxy.http host "'$DEAD_PROXY_HOST'" &&
    set_nested_key org.gnome.system.proxy.http port "$DEAD_PROXY_PORT" &&
    set_nested_key org.gnome.system.proxy.https host "'$DEAD_PROXY_HOST'" &&
    set_nested_key org.gnome.system.proxy.https port "$DEAD_PROXY_PORT" &&
    set_nested_key org.gnome.desktop.interface color-scheme "'prefer-dark'" &&
    set_nested_key org.gnome.desktop.interface gtk-theme "'Yaru-prussiangreen-dark'" &&
    set_nested_key org.gnome.desktop.interface icon-theme "'Yaru-prussiangreen-dark'" &&
    set_nested_key org.gnome.desktop.interface accent-color "'teal'" &&
    set_nested_key org.gnome.desktop.interface font-name "'Ubuntu Sans 11'" &&
    set_nested_key org.gnome.desktop.background picture-uri "'file:///usr/share/backgrounds/warty-final-ubuntu.png'" &&
    set_nested_key org.gnome.desktop.background picture-uri-dark "'file:///usr/share/backgrounds/ubuntu-wallpaper-d.png'" &&
    set_nested_key org.gnome.desktop.background picture-options "'zoom'"
}

#######################################
# Stage 3, inside the private session bus: refuse unless isolated, write the
# nested settings, record the bus, then become gnome-shell (same pid).
# Arguments:
#   $1 - run directory
#######################################
run_inside_private_session_bus() {
    local run_dir="$1"
    verified_run_suffix "$run_dir" >/dev/null || die "not a run directory of this script: $run_dir"
    is_isolated_environment "$run_dir" || refuse_run "$run_dir" "the in-bus stage is not isolated"
    is_private_session_bus_address "${DBUS_SESSION_BUS_ADDRESS:-}" "$run_dir" \
        || refuse_run "$run_dir" "the session bus is not this run's private one: '${DBUS_SESSION_BUS_ADDRESS:-}'"
    write_nested_settings || refuse_run "$run_dir" "a nested setting could not be written"
    [[ -s "$XDG_CONFIG_HOME/dconf/user" ]] || refuse_run "$run_dir" "the settings did not land in the nested dconf"
    record_run_value "$run_dir" gnome-shell "$$"
    printf '%s\n' "$DBUS_SESSION_BUS_ADDRESS" >"$run_dir/state/session.addr"
    exec gnome-shell --headless --wayland --no-x11 --virtual-monitor "$NESTED_MONITOR_SIZE" \
        --wayland-display "$NESTED_WAYLAND_DISPLAY" --mode "$NESTED_SESSION_MODE"
}

#######################################
# Succeed once the nested shell is live and answers Eval with unsafe mode on.
# Arguments:
#   $1 - run directory
#######################################
does_nested_shell_answer() {
    local recorded_address=""
    [[ -r "$1/state/session.addr" ]] && read -r recorded_address <"$1/state/session.addr"
    is_private_session_bus_address "$recorded_address" "$1" || return 1
    is_nested_shell_live "$1" 2>/dev/null || return 1
    [[ "$(eval_in_nested_shell "$recorded_address" 'global.context.unsafe_mode' 2>/dev/null)" == true ]]
}

#######################################
# Wait for the nested shell to answer; fail as soon as the run refused or
# died, or after STARTUP_TIMEOUT_SECONDS.
# Arguments:
#   $1 - run directory
#######################################
wait_for_nested_shell() {
    local run_dir="$1" deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        does_nested_shell_answer "$run_dir" && return 0
        if [[ -s "$run_dir/state/refused" ]]; then
            note "the run refused: $(<"$run_dir/state/refused")"
            return 1
        fi
        if ! is_run_alive "$run_dir"; then
            note "the nested session ended before the shell answered; see $run_dir/log/"
            return 1
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    note "the nested shell did not answer within $STARTUP_TIMEOUT_SECONDS s; see $run_dir/log/shell.log"
    return 1
}

#######################################
# Ask the running nested shell to confirm its own isolation: unsafe mode on
# (only the helper sets it), its runtime dir the run's, and extension updates
# unsupported (so it never contacts extensions.gnome.org). Prints Resource
# Pulse's state on stderr.
# Arguments:
#   $1 - run directory
#   $2 - verified private bus address
#######################################
confirm_nested_shell_isolation() {
    local run_dir="$1" address="$2" isolation_report is_isolated
    local isolation_probe_js
    isolation_probe_js="(() => ({
        unsafeMode: global.context.unsafe_mode,
        runtimeDir: imports.gi.GLib.get_user_runtime_dir(),
        updatesSupported: Main.extensionManager.updatesSupported,
        resourcePulseState: Main.extensionManager.lookup('$EXTENSION_UUID')?.state ?? null,
    }))()"
    isolation_report="$(eval_in_nested_shell "$address" "$isolation_probe_js")" || return 1
    is_isolated="$(jq -r --arg runtime_dir "$run_dir/run" \
        '.unsafeMode == true and .runtimeDir == $runtime_dir and .updatesSupported == false' \
        <<<"$isolation_report")" || return 1
    note "nested shell: $isolation_report"
    [[ "$is_isolated" == true ]] || { note "the nested shell is not isolated as required"; return 1; }
}

#######################################
# `start`: make and lay out a run directory under a private base, check the
# bus configs, launch the supervisor under setsid + timeout with the isolated
# environment, wait for the shell, confirm its isolation, and print its private
# bus address.
#######################################
start_subcommand() {
    local base_dir run_dir run_suffix lifetime_seconds address
    base_dir="$(nested_base_dir)"
    # Checked first: nothing is made, and no tool is looked for, under a base others can read.
    is_private_directory "$base_dir" \
        || die "the base directory $base_dir is not private (it must be yours, with no group or other access):" \
            "set RESOURCE_PULSE_NESTED_BASE to one that is"
    require_tools gnome-shell dbus-daemon dbus-run-session gjs gsettings busctl jq setsid timeout mktemp stat sed
    [[ -x "$DCONF_SERVICE_EXECUTABLE" ]] || die "$DCONF_SERVICE_EXECUTABLE is required"
    lifetime_seconds="${RESOURCE_PULSE_NESTED_LIFETIME_SECONDS:-$DEFAULT_LIFETIME_SECONDS}"
    [[ "$lifetime_seconds" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]] \
        || die "RESOURCE_PULSE_NESTED_LIFETIME_SECONDS is not a whole number of seconds: $lifetime_seconds"
    run_dir="$(mktemp -d "$base_dir/${RUN_DIR_PREFIX}XXXXXXXX")" || die "cannot make a run directory under $base_dir"
    run_suffix="${run_dir##*/"$RUN_DIR_PREFIX"}"
    if (( ${#run_dir} > MAX_RUN_DIR_PATH_CHARS )) || ! [[ "$run_dir" =~ $RUN_DIR_SAFE_PATH_PATTERN ]]; then
        rm -rf -- "$run_dir"
        die "the run directory must be at most $MAX_RUN_DIR_PATH_CHARS plain characters (sockets live in it):" \
            "set RESOURCE_PULSE_NESTED_BASE to a shorter directory than $base_dir"
    fi
    if ! prepare_run_directory "$run_dir" "$run_suffix" || ! verified_run_suffix "$run_dir" >/dev/null; then
        rm -rf -- "$run_dir"
        die "could not lay out the run directory"
    fi
    if ! session_bus_config_permits_only_dconf "$run_dir/bus/session-bus.conf" "$run_dir/bus/session-services" ||
        ! system_bus_config_activates_nothing "$run_dir/bus/system-bus.conf"; then
        rm -rf -- "$run_dir"
        die "refusing: a rendered bus config could activate more than dconf"
    fi
    build_isolated_env_command "$run_dir" || die "cannot build the isolated environment"

    "${ISOLATED_ENV_COMMAND[@]}" setsid timeout --kill-after="$KILL_AFTER_SECONDS" "$lifetime_seconds" \
        bash "$SCRIPT_PATH" __supervise "$run_dir" </dev/null >"$run_dir/log/supervisor.log" 2>&1 &
    record_run_value "$run_dir" launcher "$!"
    if ! wait_for_nested_shell "$run_dir"; then
        stop_run "$run_dir"
        exit "$EXIT_REFUSED"
    fi
    address="$(verified_session_address "$run_dir")" || { stop_run "$run_dir"; exit "$EXIT_REFUSED"; }
    if ! confirm_nested_shell_isolation "$run_dir" "$address"; then
        stop_run "$run_dir"
        exit "$EXIT_REFUSED"
    fi
    note "running for at most $lifetime_seconds s; run directory: $run_dir"
    note "with more than one run live: export RESOURCE_PULSE_NESTED_DIR=$run_dir"
    printf '%s\n' "$address"
}

#######################################
# Stop a run: SIGTERM the nested gnome-shell by its recorded pid, wait for the
# session to empty (the supervisor's exit sweeps it), then signal whatever is
# left in that session. Never signals outside the run's own session, and never
# the caller's session. Removes the runtime dir and the bus sockets; keeps logs
# and shots.
# Arguments:
#   $1 - run directory
#######################################
stop_run() {
    local run_dir="$1" session_id own_session_id shell_pid
    session_id="$(run_session_id "$run_dir")"
    if [[ -n "$session_id" ]]; then
        own_session_id="$(session_id_of_process /proc "$$")"
        if ! [[ "$session_id" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]] || (( session_id <= 1 )) ||
            [[ "$session_id" == "$own_session_id" ]]; then
            die "refusing to stop session '$session_id': it is not the run's own"
        fi
        shell_pid="$(recorded_run_value "$run_dir" gnome-shell)"
        if [[ -n "$shell_pid" && "$(session_id_of_process /proc "$shell_pid")" == "$session_id" ]]; then
            kill -TERM "$shell_pid" 2>/dev/null
        fi
        if ! wait_until "$STOP_GRACE_SECONDS" is_session_empty "$session_id"; then
            signal_session "$session_id" TERM "$SWEEP_GRACE_SECONDS" ||
                signal_session "$session_id" KILL "$SWEEP_GRACE_SECONDS"
        fi
        if ! is_session_empty "$session_id"; then
            note "processes are still running in session $session_id; the run directory is kept: $run_dir"
            return 1
        fi
    fi
    rm -rf -- "${run_dir:?}/run" "${run_dir:?}/$SESSION_BUS_SOCKET_RELATIVE_PATH" \
        "${run_dir:?}/$SYSTEM_BUS_SOCKET_RELATIVE_PATH"
    : >"$run_dir/state/stopped"
    note "stopped; logs and screenshots stay in $run_dir"
}

#######################################
# `eval <javascript>|-`
# Arguments:
#   $1 - JavaScript, or '-' to read it from stdin
#######################################
eval_subcommand() {
    local code="$1" address
    [[ "$code" == - ]] && code="$(cat)"
    [[ -n "$code" ]] || usage_error "eval needs JavaScript"
    require_tools busctl jq stat
    address="$(live_run_session_address)" || exit "$EXIT_REFUSED"
    eval_in_nested_shell "$address" "$code"
}

#######################################
# `screenshot <name.png> [x y width height]`: the nested shell writes the PNG
# into the run's shots/ (never anywhere else); prints its path.
# Arguments:
#   $1 - file name
#   $2..$5 - optional area, in logical pixels
#######################################
screenshot_subcommand() {
    local shot_name="${1:-}" run_dir address shot_path reply has_succeeded
    [[ "$shot_name" =~ $SCREENSHOT_NAME_PATTERN ]] \
        || usage_error "a screenshot name is a plain file name (letters, digits, . _ -), got: '$shot_name'"
    [[ "$shot_name" == *"$PNG_SUFFIX" ]] || shot_name+="$PNG_SUFFIX"
    shift
    local -a area=("$@")
    local area_value
    case "${#area[@]}" in
        0) ;;
        4)
            for area_value in "${area[@]}"; do
                [[ "$area_value" =~ $WHOLE_NUMBER_PATTERN ]] || usage_error "an area is four whole numbers: x y width height"
            done
            [[ "${area[2]}" =~ $POSITIVE_WHOLE_NUMBER_PATTERN && "${area[3]}" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]] \
                || usage_error "an area's width and height must be above 0" ;;
        *) usage_error "screenshot takes a name, then either no area or x y width height" ;;
    esac
    require_tools busctl jq stat
    address="$(live_run_session_address)" || exit "$EXIT_REFUSED"
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    shot_path="$run_dir/shots/$shot_name"
    if (( ${#area[@]} == 0 )); then
        reply="$(busctl --address="$address" --json=short call org.gnome.Shell.Screenshot \
            /org/gnome/Shell/Screenshot org.gnome.Shell.Screenshot Screenshot bbs false false "$shot_path" 2>&1)"
    else
        reply="$(busctl --address="$address" --json=short call org.gnome.Shell.Screenshot \
            /org/gnome/Shell/Screenshot org.gnome.Shell.Screenshot ScreenshotArea iiiibs "${area[@]}" false \
            "$shot_path" 2>&1)"
    fi || die "the Screenshot call failed: $reply"
    has_succeeded="$(jq -r '.data[0]' <<<"$reply")" || die "unreadable Screenshot reply: $reply"
    [[ "$has_succeeded" == true ]] || { note "the nested shell could not take the screenshot"; exit "$EXIT_REQUEST_FAILED"; }
    printf '%s\n' "$shot_path"
}

#######################################
# `stop`
#######################################
stop_subcommand() {
    require_tools stat
    local run_dir
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    verified_run_suffix "$run_dir" >/dev/null || die "not a run directory of this script: $run_dir"
    stop_run "$run_dir" || exit "$EXIT_REFUSED"
}

main() {
    local subcommand="${1:-}"
    case "$subcommand" in
        start)
            (( $# == 1 )) || usage_error "start takes no arguments"
            start_subcommand ;;
        eval)
            (( $# == 2 )) || usage_error "eval takes one argument: the JavaScript, or -"
            eval_subcommand "$2" ;;
        screenshot)
            shift
            screenshot_subcommand "$@" ;;
        stop)
            (( $# == 1 )) || usage_error "stop takes no arguments"
            stop_subcommand ;;
        # The internal stages, run only by this script inside the isolated environment; each refuses elsewhere.
        __supervise)
            (( $# == 2 )) || usage_error "internal stage: __supervise <run dir>"
            supervise_run "$2" ;;
        __inside-session-bus)
            (( $# == 2 )) || usage_error "internal stage: __inside-session-bus <run dir>"
            run_inside_private_session_bus "$2" ;;
        '') usage_error "a subcommand is required" ;;
        *) usage_error "unknown subcommand: '$subcommand'" ;;
    esac
}

# Sourced (by the hermetic rows), it only defines functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
