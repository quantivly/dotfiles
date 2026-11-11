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
#   settings     the nested dconf only: no lock, no idle blank, a dead proxy, no location
#   apps         the extension-update apps masked, so the shell sees no updater and never
#                checks extensions.gnome.org (updatesSupported is false, which start confirms);
#                allow-extension-installation stays on, because GNOME 50 skips the user
#                extension dir, where both extensions are copied, without it
#   unsafe mode  only through a throwaway helper extension copied into the run's data dir,
#                which refuses to act in any shell but this one
#   service      the run's copy of the sampler service (service/main.js under gjs), started
#                on the private session bus before the shell, with the same allowlist and
#                nothing more; the extension's StartUnit finds no systemd there, and it
#                draws from the service's Samples whatever StartUnit answered. With --replay
#                the run's copy of tests/nested/replay-service.js starts in its place, given
#                the run's copy of the extension: the same bus name and protocol, synthetic
#                Samples from a fixed seed, and it refuses any bus but the run's private one
#   gc log       with --gc-log, gnome-shell alone gets JS_GC_PROFILE=0 and
#                JS_GC_PROFILE_NURSERY=0 on top of the allowlist (set after both services
#                start), so SpiderMonkey logs every collection (MajorGC: and MinorGC:
#                lines) to its stderr, log/shell.log
#   cockpit      the run's copy of the cockpit service (service/cockpit.js under gjs), started
#                the same way after the sampler, reading the config template copied into the
#                run's XDG_CONFIG_HOME; it finds no herdr (whose socket it looks for under that
#                config home) and no NetworkManager or UPower on the fake system bus
#   identity     a run's launcher, supervisor, services and gnome-shell are recorded by pid AND start
#                time (stat field 22), and count only while both match: a pid alone can be
#                reused once its process ends
#   requests     eval, screenshot, scenario and perf go only to a live run: its supervisor
#                running, and its recorded gnome-shell running, as gnome-shell, in the run's
#                own session; scenario and perf also need the run started with --replay, and
#                its replay service running; perf also needs --gc-log
#   perf         measures that recorded gnome-shell and nothing else: the cost script is given
#                its pid, never left to look for "the" gnome-shell (the live one is the
#                user's); the window it opens is a client of the nested shell only (the run's
#                environment, its Wayland display in the run's runtime dir, its private bus)
#   lifetime     setsid + timeout --kill-after. stop signals only the run's own session, and
#                only while that session is still led by the run's recorded launcher
#                (timeout, same pid and start time); a run whose session is gone is only
#                cleaned up
#
# Everything it creates is under the run directory. Any isolation step that
# fails stops the run: exit 2, and nothing left running.
#
# Not run in CI: it needs gnome-shell and a GPU render node. Its hermetic rows
# (usage, the bus configs, the environment, the refusals) are in
# scripts/test-resource-pulse.sh.
#
# Usage:
#   scripts/resource-pulse-nested.sh start [--gc-log] [--replay]
#       start a nested shell with the checkout's Resource Pulse enabled, and its
#       sampler and cockpit services on the same private bus; print that bus's
#       address on stdout and the run directory on stderr. Each option at most
#       once, in either order, recorded in state/run.values (gc-log=1, replay=1):
#         --gc-log  SpiderMonkey logs every collection to log/shell.log
#         --replay  the replay service publishes fixed, synthetic input in place of
#                   the sampler's (busy until a scenario is asked for)
#   scripts/resource-pulse-nested.sh eval <javascript>|-
#       run JavaScript in the nested shell (org.gnome.Shell.Eval) and print the
#       JSON result; '-' reads the code from stdin
#   scripts/resource-pulse-nested.sh screenshot <name.png> [x y width height]
#       save the nested stage (or an area of it, in logical pixels) as
#       <run dir>/shots/<name.png>, and print that path
#   scripts/resource-pulse-nested.sh scenario <idle|light|busy>
#       write the word, and a token new to this request, to <run dir>/run/rp-scenario
#       of a live --replay run; from its next tick the replay service plays that
#       scenario from the start of its sequence, even when it is the one playing:
#       idle CPU 1-4%, light 2-14%, busy a walk between 15% and 90%
#   scripts/resource-pulse-nested.sh perf
#       measure a live run started with --gc-log --replay against the count budgets,
#       in about nine minutes: open one gnome-calculator window, then for each state
#       (disabled; card covered, idle input; covered, busy; top bar hidden, covered,
#       busy; card visible, busy) request its scenario, set it up, wait 40 s, and
#       measure one 60 s window with no eval running. Prints a line per state (CPU %
#       of one core and the main thread's median per tick, reported only; major
#       collections, frames, Samples, top-bar paints and the card's redirect, counted
#       by an in-shell probe), then one verdict line naming each broken budget
#   scripts/resource-pulse-nested.sh stop
#       stop the nested shell, its two services and everything else it started;
#       logs (log/service.log is the sampler's, or with --replay the replay
#       service's; log/cockpit.log the cockpit's) and shots stay
#
# Environment:
#   RESOURCE_PULSE_NESTED_DIR     the run directory eval, screenshot, scenario, perf and stop act on
#                                 (needed only while more than one run is live)
#   RESOURCE_PULSE_NESTED_BASE    where run directories are made: yours, with no group or
#                                 other access (default $XDG_RUNTIME_DIR, else $TMPDIR)
#   RESOURCE_PULSE_NESTED_LIFETIME_SECONDS  a run's hard lifetime (default 1200)
#
# Exit: 0 ok; 1 the nested shell ran the request and it failed (an Eval that
#       threw, a screenshot it could not take, a perf count over its budget);
#       2 refused, bad usage or could not run (for perf, also a count it could not
#       judge: never a pass and never a breach).

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
# The run's own copy of the extension, relative to the run directory.
readonly RUN_EXTENSION_RELATIVE_PATH="data/gnome-shell/extensions/$EXTENSION_UUID"
# The sampler service: the run's own copy of it, and the name it owns on the private session bus.
readonly SERVICE_MAIN_RELATIVE_PATH="$RUN_EXTENSION_RELATIVE_PATH/service/main.js"
readonly SERVICE_BUS_NAME='io.github.quantivly.dotfiles.ResourcePulse1'
# The cockpit service: the run's own copy of it, and the name it owns on the private session bus.
readonly COCKPIT_MAIN_RELATIVE_PATH="$RUN_EXTENSION_RELATIVE_PATH/service/cockpit.js"
readonly COCKPIT_BUS_NAME='io.github.quantivly.dotfiles.Cockpit1'
# The replay service (--replay): the checkout's files copied into this directory of the run, and its entry module,
# which owns the sampler's bus name in the sampler's place.
readonly REPLAY_RELATIVE_DIR='replay'
readonly REPLAY_MAIN_FILE_NAME='replay-service.js'
readonly -a REPLAY_FILE_NAMES=("$REPLAY_MAIN_FILE_NAME" replayGenerator.js)
readonly REPLAY_MAIN_RELATIVE_PATH="$REPLAY_RELATIVE_DIR/$REPLAY_MAIN_FILE_NAME"
# The replay service's scenario words, and the file it reads the current one from: in the run's runtime dir.
readonly IDLE_SCENARIO_NAME='idle'
readonly LIGHT_SCENARIO_NAME='light'
readonly BUSY_SCENARIO_NAME='busy'
readonly -a REPLAY_SCENARIO_NAMES=("$IDLE_SCENARIO_NAME" "$LIGHT_SCENARIO_NAME" "$BUSY_SCENARIO_NAME")
readonly REPLAY_SCENARIO_RELATIVE_PATH='run/rp-scenario'

# perf: the cost script that reads the nested shell's CPU (always given the shell's pid, never left to find one),
# the in-shell probe sent through Eval (gnome-shell/tests/nested/perf-probe.js) and the function its text declares,
# with its three requests.
readonly COST_SCRIPT_PATH="$REPO_ROOT/scripts/resource-pulse-cost.sh"
readonly PERF_PROBE_PATH="$NESTED_FILES_DIR/perf-probe.js"
readonly PERF_PROBE_FUNCTION_NAME='resourcePulsePerfProbe'
readonly PERF_PROBE_ATTACH_DISABLED_REQUEST='attach-disabled'
readonly PERF_PROBE_ATTACH_ENABLED_REQUEST='attach-enabled'
readonly PERF_PROBE_READ_REQUEST='read'
# The window perf opens over the card, started as a client of the nested shell only, on Wayland alone.
readonly PERF_WINDOW_COMMAND_NAME='gnome-calculator'
readonly PERF_WINDOW_GDK_BACKEND='wayland'
readonly PERF_WINDOW_APPEAR_TIMEOUT_SECONDS=30
readonly PERF_WINDOW_POLL_INTERVAL_SECONDS=1
# Each state: its scenario request, PERF_WARM_UP_SECONDS for the shell to settle into it (the performance design's
# 40 s warm-up), then one window of PERF_WINDOW_SECONDS with no eval running.
readonly PERF_WARM_UP_SECONDS=40
readonly PERF_WINDOW_SECONDS=60
# Where a window's CPU % is written while the main thread's median is read at the same time, in the run directory.
readonly PERF_CPU_PERCENT_RELATIVE_PATH='state/perf-cpu-percent'
# The extension's SAMPLE_INTERVAL_SECONDS (lib/constants.js): the disabled state has no client to count Samples, so
# they are counted by time there, for the report only.
readonly PERF_SAMPLE_INTERVAL_SECONDS=2
# The five states, in the order perf measures them. Each begins with its own scenario request, so every run sees the
# same input: idle while disabled and covered; busy, which changes the top bar on every tick, for the rest, the top
# bar hidden included, so that a top bar painting while unmapped would paint on every tick there.
readonly PERF_DISABLED_STATE='disabled'
readonly PERF_COVERED_IDLE_STATE='covered-idle'
readonly PERF_COVERED_BUSY_STATE='covered-busy'
readonly PERF_TOPBAR_HIDDEN_STATE='topbar-hidden-covered'
readonly PERF_VISIBLE_BUSY_STATE='visible-busy'
readonly -a PERF_ENABLED_STATE_NAMES=("$PERF_COVERED_IDLE_STATE" "$PERF_COVERED_BUSY_STATE" "$PERF_TOPBAR_HIDDEN_STATE"
    "$PERF_VISIBLE_BUSY_STATE")
# The count budgets (docs/superpowers/specs/2026-11-10-resource-pulse-performance-design.md, "Budgets"), each over
# the disabled state of the same run: an enabled state's major collections at most the disabled state's plus one;
# its frames at most its Samples plus the disabled state's frames plus two; covered and idle, at most the disabled
# state's frames plus three (the nested panel's clock and the covered card's dimmed repaint draw a few frames in any
# window); no top-bar paint while the top bar is hidden; the card drawn through an offscreen texture (ALWAYS).
readonly PERF_MAJOR_COLLECTIONS_ALLOWANCE=1
readonly PERF_FRAMES_OVER_SAMPLES_ALLOWANCE=2
readonly PERF_COVERED_IDLE_FRAMES_ALLOWANCE=3
readonly PERF_HIDDEN_TOPBAR_PAINTS_ALLOWED=0
readonly PERF_WANTED_CARD_REDIRECT='ALWAYS'
# How many words an enabled state's record has: major collections, frames, Samples, top-bar paints, card redirect.
readonly PERF_ENABLED_RECORD_WORD_COUNT=5
# A count as perf's readings write it: no leading zero, which bash arithmetic would read as octal.
readonly PERF_COUNT_PATTERN='^(0|[1-9][0-9]*)$'
# SpiderMonkey's collection lines in the shell's log (`start --gc-log`): the line's first column, then its pid.
readonly MAJOR_COLLECTION_LINE_PREFIX='MajorGC:'
readonly MINOR_COLLECTION_LINE_PREFIX='MinorGC:'
# What perf runs in the nested shell around the probe: the windows of the session, the one window perf opened (an
# error unless there is exactly one), and each state's steps. Each answers a word, or throws.
readonly PERF_NORMAL_WINDOWS_JS='global.display.list_all_windows().filter(window => window.get_window_type() === Meta.WindowType.NORMAL)'
readonly PERF_ONE_WINDOW_JS="(() => {
    const normalWindows = $PERF_NORMAL_WINDOWS_JS;
    if (normalWindows.length !== 1)
        throw new Error('perf expects exactly one window in the nested session, found ' + normalWindows.length);
    return normalWindows[0];
})()"
readonly PERF_EXTENSION_JS="Main.extensionManager.lookup('$EXTENSION_UUID').stateObj"
readonly PERF_COUNT_WINDOWS_JS="$PERF_NORMAL_WINDOWS_JS.length"
readonly PERF_DISABLE_EXTENSION_JS="(() => { Main.extensionManager.disableExtension('$EXTENSION_UUID'); return 'disabled'; })()"
readonly PERF_ENABLE_EXTENSION_JS="(() => { Main.extensionManager.enableExtension('$EXTENSION_UUID'); return 'enabled'; })()"
readonly PERF_COVER_CARD_JS="(() => {
    const coveringWindow = $PERF_ONE_WINDOW_JS;
    coveringWindow.unminimize();
    coveringWindow.maximize(Meta.MaximizeFlags.BOTH);
    return 'covered';
})()"
readonly PERF_UNCOVER_CARD_JS="(() => { $PERF_ONE_WINDOW_JS.minimize(); return 'uncovered'; })()"
readonly PERF_HIDE_TOPBAR_JS="(() => { $PERF_EXTENSION_JS._indicator.hide(); return 'hidden'; })()"
readonly PERF_SHOW_TOPBAR_JS="(() => { $PERF_EXTENSION_JS._indicator.show(); return 'shown'; })()"

# start's options, and the run value each records as requested (name=1) in state/run.values.
readonly GC_LOG_OPTION='--gc-log'
readonly REPLAY_OPTION='--replay'
readonly GC_LOG_RUN_VALUE_NAME='gc-log'
readonly REPLAY_RUN_VALUE_NAME='replay'
readonly REQUESTED_RUN_VALUE='1'
# With --gc-log, the nested gnome-shell's environment gains these and nothing else. Each is a threshold (in ms for
# major collections, in µs for nursery ones) past which SpiderMonkey logs a collection to stderr, as MajorGC: and
# MinorGC: lines: 0 logs every one.
readonly -a GC_LOG_ENVIRONMENT_ASSIGNMENTS=(JS_GC_PROFILE=0 JS_GC_PROFILE_NURSERY=0)
# The cockpit's layout config: the checkout's template, copied to this path under the run's XDG_CONFIG_HOME.
readonly COCKPIT_CONFIG_TEMPLATE="$REPO_ROOT/examples/resource-pulse-cockpit.json.template"
readonly COCKPIT_CONFIG_RELATIVE_PATH='resource-pulse/cockpit.json'

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
# Once the shell answers on its bus, how long the unsafe-mode helper gets to turn unsafe mode on (it loads with
# the other extensions, about a second after the shell does) before start reports that it did not load.
readonly HELPER_ENABLE_GRACE_SECONDS=15
readonly FAKE_SYSTEM_BUS_TIMEOUT_SECONDS=10
# How long each service gets to own its bus name before the run refuses to go on.
readonly SERVICE_START_TIMEOUT_SECONDS=15
readonly STOP_GRACE_SECONDS=15
readonly SWEEP_GRACE_SECONDS=3
readonly POLL_INTERVAL_SECONDS=0.2
readonly EVAL_TIMEOUT_SECONDS=60
readonly SCREENSHOT_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
readonly WHOLE_NUMBER_PATTERN='^[0-9]+$'
readonly POSITIVE_WHOLE_NUMBER_PATTERN='^[1-9][0-9]*$'
readonly DBUS_GUID_SUFFIX_PATTERN=',guid=[0-9a-f]+'
readonly PNG_SUFFIX='.png'
# busctl --json=short replies to Eval('global.context.unsafe_mode'): unsafe mode on, and Eval refused because it
# is off (GNOME 50's Eval answers (false, '') then).
readonly UNSAFE_MODE_ON_REPLY='{"type":"bs","data":[true,"true"]}'
readonly EVAL_REFUSED_REPLY_PREFIX='{"type":"bs","data":[false,'
# /proc/<pid>/stat after the last ") ": state (field 3), ppid, pgrp, session (field 6).
readonly STAT_STATE_INDEX_AFTER_COMM=0
readonly STAT_SESSION_INDEX_AFTER_COMM=3
# Field 22, the start time in clock ticks after boot: with the pid it names one process, even after a reuse.
readonly STAT_STARTTIME_INDEX_AFTER_COMM=19
readonly DEAD_PROCESS_STATES='ZX'
# A run's launcher: `setsid timeout ...` makes timeout the leader of the run's session.
readonly LAUNCHER_COMM='timeout'
# Markers in a run's state/: `stop` ran on it; its supervisor exited (the run ended, stopped or not).
readonly RUN_STOPPED_MARKER='state/stopped'
readonly RUN_ENDED_MARKER='state/ended'

# The one environment every nested process gets, filled by build_isolated_env_command.
ISOLATED_ENV_COMMAND=()
# The fields of the last stat line read_stat_fields read, from the state (field 3) on.
STAT_FIELDS_AFTER_COMM=()
# The pids collect_session_pids found, and how many of them count_remaining_session_pids left in.
SESSION_PIDS=()
REMAINING_SESSION_PID_COUNT=0
# The run values start's options ask for (gc-log, replay), in the order given, filled by parse_start_options.
REQUESTED_START_RUN_VALUE_NAMES=()
# The window perf opened over the card, by pid and start time (end_perf_window ends only that process).
PERF_WINDOW_PID=""
PERF_WINDOW_STARTTIME=""
# What measure_perf_window read of the window just measured.
PERF_WINDOW_CPU_PERCENT=""
PERF_WINDOW_TICK_MEDIAN_MS=""
PERF_WINDOW_MAJOR_COLLECTIONS=""
# The disabled state's readings, which every enabled state is judged and reported against.
PERF_DISABLED_MAJOR_COLLECTIONS=""
PERF_DISABLED_FRAMES=""
PERF_DISABLED_CPU_PERCENT=""
# Each enabled state's record for perf_count_verdict, in PERF_ENABLED_STATE_NAMES's order.
PERF_ENABLED_STATE_RECORDS=()

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
usage: scripts/resource-pulse-nested.sh start [--gc-log] [--replay]
       scripts/resource-pulse-nested.sh eval <javascript>|-
       scripts/resource-pulse-nested.sh screenshot <name.png> [x y width height]
       scripts/resource-pulse-nested.sh scenario <idle|light|busy>
       scripts/resource-pulse-nested.sh perf
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
# Fill REQUESTED_START_RUN_VALUE_NAMES from start's options: --gc-log and
# --replay, in either order, each at most once. Anything else is a usage error
# (exit 2), before anything is looked at or made.
# Arguments:
#   $@ - the arguments after `start`
#######################################
parse_start_options() {
    local start_option
    REQUESTED_START_RUN_VALUE_NAMES=()
    for start_option in "$@"; do
        case "$start_option" in
            "$GC_LOG_OPTION") add_requested_start_run_value "$GC_LOG_RUN_VALUE_NAME" "$start_option" ;;
            "$REPLAY_OPTION") add_requested_start_run_value "$REPLAY_RUN_VALUE_NAME" "$start_option" ;;
            *) usage_error "start takes only $GC_LOG_OPTION and $REPLAY_OPTION, got: '$start_option'" ;;
        esac
    done
}

#######################################
# Add one run value to REQUESTED_START_RUN_VALUE_NAMES; a usage error (exit 2)
# when its option was already given.
# Arguments:
#   $1 - run value name
#   $2 - the option that asks for it
#######################################
add_requested_start_run_value() {
    local run_value_name="$1" start_option="$2" requested_name
    for requested_name in "${REQUESTED_START_RUN_VALUE_NAMES[@]}"; do
        [[ "$requested_name" == "$run_value_name" ]] && usage_error "start takes $start_option at most once"
    done
    REQUESTED_START_RUN_VALUE_NAMES+=("$run_value_name")
}

#######################################
# Record each run value start's options asked for as name=1 in the run's
# state/run.values, where the in-bus stage and `scenario` read them: an option
# crosses the `env -i` launch only through the run directory, so the isolated
# environment never grows for it.
# Arguments:
#   $1 - run directory
#######################################
record_requested_start_options() {
    local run_value_name
    for run_value_name in "${REQUESTED_START_RUN_VALUE_NAMES[@]}"; do
        record_run_value "$1" "$run_value_name" "$REQUESTED_RUN_VALUE" || return 1
    done
}

#######################################
# Succeed when the run recorded a run value as requested (name=1).
# Arguments:
#   $1 - run directory
#   $2 - run value name (gc-log, replay)
#######################################
is_requested_in_run() {
    [[ "$(recorded_run_value "$1" "$2")" == "$REQUESTED_RUN_VALUE" ]]
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
# Print a running process's start time (stat field 22); fail when it is not
# running.
# Arguments:
#   $1 - proc root
#   $2 - pid
#######################################
starttime_of_process() {
    read_stat_fields "$1" "$2" || return 1
    [[ "${STAT_FIELDS_AFTER_COMM[$STAT_STARTTIME_INDEX_AFTER_COMM]:-}" =~ $WHOLE_NUMBER_PATTERN ]] || return 1
    printf '%s' "${STAT_FIELDS_AFTER_COMM[$STAT_STARTTIME_INDEX_AFTER_COMM]}"
}

#######################################
# Fill SESSION_PIDS with every running pid under a proc root whose session is
# the given one. It runs in the calling shell and never in a subshell: a
# subshell of a process inside that session is itself a member, so a sweep
# run from inside the session would always find itself left over.
# Arguments:
#   $1 - proc root
#   $2 - session id
#######################################
collect_session_pids() {
    local proc_root="$1" session_id="$2" process_dir pid
    SESSION_PIDS=()
    for process_dir in "$proc_root"/[0-9]*; do
        pid="${process_dir##*/}"
        read_stat_fields "$proc_root" "$pid" || continue
        if [[ "${STAT_FIELDS_AFTER_COMM[$STAT_SESSION_INDEX_AFTER_COMM]}" == "$session_id" ]]; then
            SESSION_PIDS+=("$pid")
        fi
    done
    return 0
}

#######################################
# Print, one per line, every running pid under a proc root whose session is
# the given one (for a caller outside that session, and the hermetic rows).
# Arguments:
#   $1 - proc root
#   $2 - session id
#######################################
pids_in_session() {
    collect_session_pids "$1" "$2"
    if (( ${#SESSION_PIDS[@]} > 0 )); then
        printf '%s\n' "${SESSION_PIDS[@]}"
    fi
}

#######################################
# Succeed when no process is left in a session.
# Arguments:
#   $1 - session id
#######################################
is_session_empty() {
    collect_session_pids /proc "$1"
    (( ${#SESSION_PIDS[@]} == 0 ))
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
# Record one of the run's processes by pid and start time (<name> and
# <name>-starttime), so a later check can tell it from a process that reused
# its pid.
# Arguments:
#   $1 - run directory
#   $2 - name (launcher, supervisor, service, cockpit, gnome-shell)
#   $3 - pid
#######################################
record_running_process() {
    local run_dir="$1" process_name="$2" pid="$3" starttime
    starttime="$(starttime_of_process /proc "$pid")" || starttime=""
    record_run_value "$run_dir" "$process_name" "$pid"
    record_run_value "$run_dir" "$process_name-starttime" "$starttime"
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
# unsafe-mode helper, a copy of the checkout's extension, a copy of the replay
# service (which only --replay starts), and the cockpit's config template in
# the run's config home.
# Arguments:
#   $1 - run directory (exists, empty, 0700)
#   $2 - run suffix
#######################################
prepare_run_directory() {
    local run_dir="$1" run_suffix="$2" replay_file_name
    local cockpit_config_dir="config/${COCKPIT_CONFIG_RELATIVE_PATH%/*}"
    local -a subdirectories=(run config "$cockpit_config_dir" cache home tmp data/applications
        data/gnome-shell/extensions sysdata/gnome-shell/modes bus/session-services state log shots
        "$REPLAY_RELATIVE_DIR")
    # Every directory private to the user, intermediate ones included (the runtime dir must be 0700).
    (umask "$PRIVATE_UMASK" && mkdir -p "${subdirectories[@]/#/$run_dir/}") || return 1
    for replay_file_name in "${REPLAY_FILE_NAMES[@]}"; do
        cp -- "$NESTED_FILES_DIR/$replay_file_name" "$run_dir/$REPLAY_RELATIVE_DIR/" || return 1
    done
    printf '%s\n' "$run_suffix" >"$run_dir/$RUN_DIR_MARKER_FILE" || return 1
    render_bus_config "$NESTED_FILES_DIR/session-bus.conf.in" "$run_dir" >"$run_dir/bus/session-bus.conf" || return 1
    render_bus_config "$NESTED_FILES_DIR/system-bus.conf.in" "$run_dir" >"$run_dir/bus/system-bus.conf" || return 1
    cp -- "$NESTED_FILES_DIR/session-services/$DCONF_SERVICE_FILE" "$run_dir/bus/session-services/" || return 1
    cp -- "$NESTED_FILES_DIR/$NESTED_SESSION_MODE.json" "$run_dir/sysdata/gnome-shell/modes/" || return 1
    cp -- "$NESTED_FILES_DIR"/applications/*.desktop "$run_dir/data/applications/" || return 1
    cp -R -- "$NESTED_FILES_DIR/$UNSAFE_MODE_HELPER_UUID" "$run_dir/data/gnome-shell/extensions/" || return 1
    cp -R -- "$EXTENSION_SOURCE_DIR" "$run_dir/data/gnome-shell/extensions/" || return 1
    cp -- "$COCKPIT_CONFIG_TEMPLATE" "$run_dir/config/$COCKPIT_CONFIG_RELATIVE_PATH" || return 1
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
# Succeed while a recorded process of the run is still the process recorded:
# its pid runs, with the start time recorded for it. A process recorded with
# no start time never counts.
# Arguments:
#   $1 - run directory
#   $2 - name (launcher, supervisor, service, gnome-shell)
#######################################
is_recorded_process_running() {
    local run_dir="$1" process_name="$2" pid recorded_starttime
    pid="$(recorded_run_value "$run_dir" "$process_name")"
    recorded_starttime="$(recorded_run_value "$run_dir" "$process_name-starttime")"
    [[ -n "$pid" && -n "$recorded_starttime" ]] || return 1
    [[ "$(starttime_of_process /proc "$pid")" == "$recorded_starttime" ]]
}

#######################################
# Succeed while the run's supervisor, or before it has recorded itself the
# launcher, is still running: either is alive for the whole run.
# Arguments:
#   $1 - run directory
#######################################
is_run_alive() {
    is_recorded_process_running "$1" supervisor || is_recorded_process_running "$1" launcher
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
    if ! is_recorded_process_running "$run_dir" gnome-shell; then
        note "the recorded gnome-shell ($shell_pid) is not running, or its pid now belongs to another process"
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
# Print the run directory eval, screenshot, scenario, perf and stop act on:
# RESOURCE_PULSE_NESTED_DIR, else the one run under the base that is live: not
# stopped, not ended, and with its supervisor or launcher still running (a run
# whose lifetime ran out, or that crashed, is skipped). Exit 2 when there is
# none, or more than one.
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
        [[ -e "$marker_path" && ! -e "$run_dir/$RUN_STOPPED_MARKER" && ! -e "$run_dir/$RUN_ENDED_MARKER" ]] || continue
        verified_run_suffix "$run_dir" >/dev/null && is_run_alive "$run_dir" && live_run_dirs+=("$run_dir")
    done
    case "${#live_run_dirs[@]}" in
        0) die "no live run under $base_dir: start one with: $0 start" ;;
        1) printf '%s' "${live_run_dirs[0]}" ;;
        *) die "several live runs; set RESOURCE_PULSE_NESTED_DIR to one of: ${live_run_dirs[*]}" ;;
    esac
}

#######################################
# Print a run's private bus address for eval and screenshot; exit 2 unless the
# directory is a run directory, the address is the run's own and the run is
# live.
# Arguments:
#   $1 - run directory (from resolve_run_directory)
#######################################
live_run_session_address() {
    local run_dir="$1" address
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
# Succeed when a session is still led by this run's launcher: its leader (the
# process whose pid is the session id) is the launcher the run recorded (same
# pid and start time), leads that session, and is `timeout`. A session id is a
# pid: once a run's processes are all gone, another session can take the same
# id, and that session must never be signalled as the run's.
# Arguments:
#   $1 - run directory
#   $2 - session id
#######################################
is_session_led_by_run_launcher() {
    local run_dir="$1" session_id="$2" leader_comm=""
    [[ "$(recorded_run_value "$run_dir" launcher)" == "$session_id" ]] || return 1
    is_recorded_process_running "$run_dir" launcher || return 1
    [[ "$(session_id_of_process /proc "$session_id")" == "$session_id" ]] || return 1
    read -r leader_comm 2>/dev/null <"/proc/$session_id/comm"
    [[ "$leader_comm" == "$LAUNCHER_COMM" ]]
}

#######################################
# Succeed when a pid is one of the given ones.
# Arguments:
#   $1 - pid
#   $@ - the pids to look in
#######################################
is_excluded_pid() {
    local candidate_pid="$1" excluded_pid
    shift
    for excluded_pid in "$@"; do
        [[ "$candidate_pid" == "$excluded_pid" ]] && return 0
    done
    return 1
}

#######################################
# Set REMAINING_SESSION_PID_COUNT to how many of the session's pids are not
# excluded, in the calling shell (see collect_session_pids).
# Arguments:
#   $1 - session id
#   $@ - pids to leave out
#######################################
count_remaining_session_pids() {
    local session_id="$1" session_pid
    shift
    REMAINING_SESSION_PID_COUNT=0
    collect_session_pids /proc "$session_id"
    for session_pid in "${SESSION_PIDS[@]}"; do
        is_excluded_pid "$session_pid" "$@" || REMAINING_SESSION_PID_COUNT=$((REMAINING_SESSION_PID_COUNT + 1))
    done
}

#######################################
# Send a signal to every process in a session but the excluded ones, then wait
# up to a grace period for them to go. Only pids read from /proc as members of
# that session are ever signalled, and the scan runs in the calling shell, so
# a caller inside the session sees it empty once only it is left.
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
    collect_session_pids /proc "$session_id"
    for session_pid in "${SESSION_PIDS[@]}"; do
        is_excluded_pid "$session_pid" "${excluded_pids[@]}" && continue
        kill "-$signal_name" "$session_pid" 2>/dev/null
    done
    deadline=$((SECONDS + grace_seconds))
    while true; do
        count_remaining_session_pids "$session_id" "${excluded_pids[@]}"
        (( REMAINING_SESSION_PID_COUNT == 0 )) && return 0
        (( SECONDS < deadline )) || return 1
        sleep "$POLL_INTERVAL_SECONDS"
    done
}

#######################################
# The supervisor's exit: end every process left in its session (SIGTERM, then
# SIGKILL after a grace), whatever ended the run, and mark the run ended, so
# looking for a live run never finds it.
# Arguments:
#   $1 - run directory
#   $2 - session id
#######################################
end_supervised_session() {
    local run_dir="$1" session_id="$2" ended_at
    signal_session "$session_id" TERM "$SWEEP_GRACE_SECONDS" "$$" "$PPID" \
        || signal_session "$session_id" KILL "$SWEEP_GRACE_SECONDS" "$$" "$PPID" \
        || note "processes outlived SIGKILL in session $session_id"
    ended_at="$(date -Is)"
    record_run_value "$run_dir" supervisor-exited "$ended_at"
    : >"$run_dir/$RUN_ENDED_MARKER"
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
    record_running_process "$run_dir" supervisor "$$"
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
# locking, blanking or reaching the network; and the reference laptop's look
# (Ubuntu's defaults plus scripts/apply-gnome-settings.sh), so the card is
# judged against the real theme. allow-extension-installation is left on: GNOME
# 50 scans the user extension dir, where both extensions are, only while it is
# on. The update check stays off through the app masks (see the header).
#######################################
write_nested_settings() {
    set_nested_key org.gnome.shell enabled-extensions "['$UNSAFE_MODE_HELPER_UUID', '$EXTENSION_UUID']" &&
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
# Succeed once a service owns its name on the private session bus (only ever
# called inside it, after is_private_session_bus_address).
# Arguments:
#   $1 - bus name
#######################################
does_nested_service_own_its_name() {
    [[ "$(busctl --address="$DBUS_SESSION_BUS_ADDRESS" call org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus NameHasOwner s "$1" 2>/dev/null)" == 'b true' ]]
}

#######################################
# Wait until a service owns its name. Fail as soon as its recorded process is
# gone (it exited), or after SERVICE_START_TIMEOUT_SECONDS.
# Arguments:
#   $1 - run directory
#   $2 - the name the service is recorded under (service, cockpit)
#   $3 - bus name
#######################################
wait_for_nested_service() {
    local run_dir="$1" process_name="$2" bus_name="$3" deadline=$((SECONDS + SERVICE_START_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        does_nested_service_own_its_name "$bus_name" && return 0
        is_recorded_process_running "$run_dir" "$process_name" || return 1
        sleep "$POLL_INTERVAL_SECONDS"
    done
    does_nested_service_own_its_name "$bus_name"
}

#######################################
# Start the run's copy of a service (the sampler, or the cockpit) on the private
# session bus, and wait until it owns its name: the extension then finds the
# sampler at its first enable. The extension's StartUnit has no systemd to
# reach here, and it draws from the Samples whatever StartUnit answered. The
# service inherits this stage's environment, which is the isolated allowlist
# plus the private bus address and nothing else. Recorded by pid and start
# time, for `stop`, and logged to log/<recorded name>.log. Refuses the run when
# the service exits before owning its name (as gjs does at once with a module it
# cannot load), or does not own it in time.
# Arguments:
#   $1 - run directory
#   $2 - the name to record it under (service, cockpit)
#   $3 - its entry module, relative to the run directory
#   $4 - the bus name it owns
#   $@ - the entry module's own arguments, if any
#######################################
start_nested_service() {
    local run_dir="$1" process_name="$2" main_relative_path="$3" bus_name="$4"
    local log_relative_path="log/$process_name.log"
    shift 4
    gjs -m "$run_dir/$main_relative_path" "$@" >"$run_dir/$log_relative_path" 2>&1 &
    record_running_process "$run_dir" "$process_name" "$!"
    wait_for_nested_service "$run_dir" "$process_name" "$bus_name" \
        || refuse_run "$run_dir" "the service at $main_relative_path did not take $bus_name ($log_relative_path)"
}

#######################################
# Start what publishes the Samples, recorded as the run's `service`: the run's
# copy of the sampler service, or with --replay (replay=1 recorded) the run's
# copy of the replay service in its place, given the run's copy of the
# extension, whose protocol it speaks.
# Arguments:
#   $1 - run directory
#######################################
start_nested_sampler() {
    local run_dir="$1"
    if is_requested_in_run "$run_dir" "$REPLAY_RUN_VALUE_NAME"; then
        start_nested_service "$run_dir" service "$REPLAY_MAIN_RELATIVE_PATH" "$SERVICE_BUS_NAME" \
            "$run_dir/$RUN_EXTENSION_RELATIVE_PATH"
    else
        start_nested_service "$run_dir" service "$SERVICE_MAIN_RELATIVE_PATH" "$SERVICE_BUS_NAME"
    fi
}

#######################################
# With --gc-log (gc-log=1 recorded), export the two collection-log variables
# and nothing else. Called last before `exec gnome-shell`, after both services
# started, so the shell alone gets them.
# Arguments:
#   $1 - run directory
#######################################
export_gc_log_variables_when_requested() {
    is_requested_in_run "$1" "$GC_LOG_RUN_VALUE_NAME" || return 0
    export "${GC_LOG_ENVIRONMENT_ASSIGNMENTS[@]}"
}

#######################################
# Stage 3, inside the private session bus: refuse unless isolated, write the
# nested settings, start the sampler service (or the replay service) and then
# the cockpit service, record the bus, then become gnome-shell (same pid), with
# the collection log's two variables when asked for.
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
    start_nested_sampler "$run_dir"
    start_nested_service "$run_dir" cockpit "$COCKPIT_MAIN_RELATIVE_PATH" "$COCKPIT_BUS_NAME"
    record_running_process "$run_dir" gnome-shell "$$"
    printf '%s\n' "$DBUS_SESSION_BUS_ADDRESS" >"$run_dir/state/session.addr"
    export_gc_log_variables_when_requested "$run_dir"
    exec gnome-shell --headless --wayland --no-x11 --virtual-monitor "$NESTED_MONITOR_SIZE" \
        --wayland-display "$NESTED_WAYLAND_DISPLAY" --mode "$NESTED_SESSION_MODE"
}

#######################################
# Print what the nested shell's answer to the unsafe-mode probe means:
# "ready" (unsafe mode on), "unsafe-mode-off" (the shell answered, but Eval is
# refused) or "not-answering" (no shell on the bus yet, or a reply of any other
# shape). Pure: it reads only busctl's exit status and its --json=short reply.
# Arguments:
#   $1 - busctl's exit status
#   $2 - busctl's reply
#######################################
classify_unsafe_mode_probe() {
    local busctl_status="$1" reply="$2"
    if (( busctl_status != 0 )); then
        printf 'not-answering'
    elif [[ "$reply" == "$UNSAFE_MODE_ON_REPLY" ]]; then
        printf 'ready'
    elif [[ "$reply" == "$EVAL_REFUSED_REPLY_PREFIX"* ]]; then
        printf 'unsafe-mode-off'
    else
        printf 'not-answering'
    fi
}

#######################################
# Print the state of a starting nested shell, as classify_unsafe_mode_probe
# names it; "not-answering" until the run is live and its address recorded.
# Arguments:
#   $1 - run directory
#######################################
probe_nested_shell() {
    local run_dir="$1" recorded_address="" reply busctl_status
    [[ -r "$run_dir/state/session.addr" ]] && read -r recorded_address <"$run_dir/state/session.addr"
    if ! is_private_session_bus_address "$recorded_address" "$run_dir" || ! is_nested_shell_live "$run_dir" 2>/dev/null
    then
        printf 'not-answering'
        return 0
    fi
    reply="$(busctl --address="$recorded_address" --json=short --timeout="$EVAL_TIMEOUT_SECONDS" \
        call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s 'global.context.unsafe_mode' 2>&1)"
    busctl_status=$?
    classify_unsafe_mode_probe "$busctl_status" "$reply"
}

#######################################
# Wait for the nested shell to answer with unsafe mode on. Fail as soon as the
# run refused or died; HELPER_ENABLE_GRACE_SECONDS after the shell first
# answered with unsafe mode still off (the helper did not load); or after
# STARTUP_TIMEOUT_SECONDS.
# Arguments:
#   $1 - run directory
#######################################
wait_for_nested_shell() {
    local run_dir="$1" deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS)) probe_state first_answer_seconds=""
    while (( SECONDS < deadline )); do
        probe_state="$(probe_nested_shell "$run_dir")"
        [[ "$probe_state" == ready ]] && return 0
        if [[ "$probe_state" == unsafe-mode-off ]]; then
            [[ -n "$first_answer_seconds" ]] || first_answer_seconds=$SECONDS
            if (( SECONDS - first_answer_seconds >= HELPER_ENABLE_GRACE_SECONDS )); then
                note "the nested shell answers on its bus, but unsafe mode is still off $HELPER_ENABLE_GRACE_SECONDS s" \
                    "later: the unsafe-mode helper did not load from $run_dir/data/gnome-shell/extensions" \
                    "(see $run_dir/log/shell.log)"
                return 1
            fi
        fi
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
# `start [--gc-log] [--replay]` (the options already parsed into
# REQUESTED_START_RUN_VALUE_NAMES): make and lay out a run directory under a
# private base, check the bus configs, record the options, launch the
# supervisor under setsid + timeout with the isolated environment, wait for the
# shell, confirm its isolation, and print its private bus address.
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
    if ! record_requested_start_options "$run_dir"; then
        rm -rf -- "$run_dir"
        die "could not record start's options in $run_dir/state/run.values"
    fi
    build_isolated_env_command "$run_dir" || die "cannot build the isolated environment"

    "${ISOLATED_ENV_COMMAND[@]}" setsid timeout --kill-after="$KILL_AFTER_SECONDS" "$lifetime_seconds" \
        bash "$SCRIPT_PATH" __supervise "$run_dir" </dev/null >"$run_dir/log/supervisor.log" 2>&1 &
    record_running_process "$run_dir" launcher "$!"
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
# Exit 2 unless a session id may be stopped at all: a whole number above 1, and
# not the caller's own session.
# Arguments:
#   $1 - session id
#######################################
refuse_unstoppable_session() {
    local session_id="$1" own_session_id
    [[ "$session_id" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]] || die "refusing to stop session '$session_id': not a session id"
    (( session_id > 1 )) || die "refusing to stop session '$session_id': a session id must be above 1"
    own_session_id="$(session_id_of_process /proc "$$")"
    [[ "$session_id" != "$own_session_id" ]] \
        || die "refusing to stop session '$session_id': it is the caller's own session"
}

#######################################
# Send SIGTERM to one of the run's recorded processes, only while it is still
# the process recorded (same pid and start time) and runs in the run's session.
# Arguments:
#   $1 - run directory
#   $2 - name (gnome-shell, service, cockpit)
#   $3 - the run's session id
#######################################
terminate_recorded_process_in_session() {
    local run_dir="$1" process_name="$2" session_id="$3" pid
    pid="$(recorded_run_value "$run_dir" "$process_name")"
    if is_recorded_process_running "$run_dir" "$process_name" &&
        [[ "$(session_id_of_process /proc "$pid")" == "$session_id" ]]; then
        kill -TERM "$pid" 2>/dev/null
    fi
}

#######################################
# Stop a run: SIGTERM the nested gnome-shell and the two services by their
# recorded pids, wait for the session to empty (the supervisor's exit sweeps
# it), then signal whatever is left in that session. It signals only while the
# session is still led by the run's own launcher
# (is_session_led_by_run_launcher), never the caller's session, and never one
# numbered 1 or below; a run whose session is gone is only cleaned up. Removes
# the runtime dir and the bus sockets; keeps logs and shots.
# Arguments:
#   $1 - run directory
#######################################
stop_run() {
    local run_dir="$1" session_id
    session_id="$(recorded_run_value "$run_dir" session)"
    [[ -n "$session_id" ]] || session_id="$(recorded_run_value "$run_dir" launcher)"
    if [[ -n "$session_id" ]]; then
        refuse_unstoppable_session "$session_id"
        if is_session_led_by_run_launcher "$run_dir" "$session_id"; then
            terminate_recorded_process_in_session "$run_dir" gnome-shell "$session_id"
            terminate_recorded_process_in_session "$run_dir" service "$session_id"
            terminate_recorded_process_in_session "$run_dir" cockpit "$session_id"
            if ! wait_until "$STOP_GRACE_SECONDS" is_session_empty "$session_id"; then
                signal_session "$session_id" TERM "$SWEEP_GRACE_SECONDS" ||
                    signal_session "$session_id" KILL "$SWEEP_GRACE_SECONDS"
            fi
            if ! is_session_empty "$session_id"; then
                note "processes are still running in session $session_id; the run directory is kept: $run_dir"
                return 1
            fi
        else
            note "session $session_id is no longer led by this run's launcher ($LAUNCHER_COMM): nothing is signalled"
        fi
    fi
    rm -rf -- "${run_dir:?}/run" "${run_dir:?}/$SESSION_BUS_SOCKET_RELATIVE_PATH" \
        "${run_dir:?}/$SYSTEM_BUS_SOCKET_RELATIVE_PATH"
    : >"$run_dir/$RUN_STOPPED_MARKER"
    note "stopped; logs and screenshots stay in $run_dir"
}

#######################################
# `eval <javascript>|-`
# Arguments:
#   $1 - JavaScript, or '-' to read it from stdin
#######################################
eval_subcommand() {
    local code="$1" run_dir address
    [[ "$code" == - ]] && code="$(cat)"
    [[ -n "$code" ]] || usage_error "eval needs JavaScript"
    require_tools stat
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    address="$(live_run_session_address "$run_dir")" || exit "$EXIT_REFUSED"
    # Looked for only now: a refusal above never depends on which tools are installed.
    require_tools busctl jq
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
    require_tools stat
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    address="$(live_run_session_address "$run_dir")" || exit "$EXIT_REFUSED"
    # Looked for only now: a refusal above never depends on which tools are installed.
    require_tools busctl jq
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
# Succeed when a word is one of the replay service's scenarios.
# Arguments:
#   $1 - word
#######################################
is_replay_scenario_name() {
    local scenario_name
    for scenario_name in "${REPLAY_SCENARIO_NAMES[@]}"; do
        [[ "$1" == "$scenario_name" ]] && return 0
    done
    return 1
}

#######################################
# Replace a run's scenario file with one request, in one rename, so the replay
# service never reads it half written: the word, then a token new to this
# request (request_id: the random suffix of the staging file's mktemp name).
# The replay service restarts whenever the request it reads is not the one it
# read last, so asking again for the word already playing restarts it too. The
# run directory is the user's own and 0700 (verified_run_suffix), so nothing
# else can have placed a link there.
# Arguments:
#   $1 - run directory
#   $2 - scenario word
#######################################
write_scenario_word() {
    local run_dir="$1" scenario_name="$2" scenario_path staging_path request_id
    scenario_path="$run_dir/$REPLAY_SCENARIO_RELATIVE_PATH"
    [[ -d "${scenario_path%/*}" && ! -L "${scenario_path%/*}" ]] || return 1
    staging_path="$(mktemp "$scenario_path.XXXXXX")" || return 1
    request_id="${staging_path##*.}"
    if ! printf '%s %s\n' "$scenario_name" "$request_id" >"$staging_path" ||
        ! mv -f -- "$staging_path" "$scenario_path"; then
        rm -f -- "$staging_path"
        return 1
    fi
}

#######################################
# `scenario <idle|light|busy>`: write the word and a new request token to
# <run dir>/run/rp-scenario of a live run started with --replay. From its next
# tick the replay service plays that scenario from the start of its sequence,
# even when it is the one playing. Any other word is a usage error, refused
# before a run is looked for; a run not started with --replay, not live, or
# whose replay service is not running is refused (exit 2), and nothing is
# written.
# Arguments:
#   $1 - scenario word
#######################################
scenario_subcommand() {
    local scenario_name="$1" run_dir
    is_replay_scenario_name "$scenario_name" \
        || usage_error "not a scenario: '$scenario_name' (one of: ${REPLAY_SCENARIO_NAMES[*]})"
    require_tools stat mktemp mv
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    verified_run_suffix "$run_dir" >/dev/null || die "not a run directory of this script: $run_dir"
    is_requested_in_run "$run_dir" "$REPLAY_RUN_VALUE_NAME" \
        || die "refusing: the run in $run_dir was not started with $REPLAY_OPTION"
    is_nested_shell_live "$run_dir" || die "refusing: the run in $run_dir is not live"
    is_recorded_process_running "$run_dir" service \
        || die "refusing: the run's replay service is not running (see $run_dir/log/service.log)"
    write_scenario_word "$run_dir" "$scenario_name" \
        || die "could not write $run_dir/$REPLAY_SCENARIO_RELATIVE_PATH"
    note "scenario $scenario_name: the replay service takes it at its next tick, from the start of its sequence"
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

#######################################
# Print how many major collections the nested shell logged past a byte offset
# of its log: the MajorGC: lines whose pid column is the shell's. The column
# header, MinorGC: lines, another process's lines and a line that only mentions
# MajorGC: are not counted. Fails when the log cannot be read: never a count of
# 0 that would pass for one.
# Arguments:
#   $1 - log path
#   $2 - the byte offset the window began at
#   $3 - the nested shell's pid
#######################################
count_major_collections_since() {
    local log_path="$1" window_start_offset="$2" shell_pid="$3" first_window_byte
    first_window_byte=$(( window_start_offset + 1 ))
    tail -c "+$first_window_byte" "$log_path" \
        | awk -v line_prefix="$MAJOR_COLLECTION_LINE_PREFIX" -v shell_pid="$shell_pid" \
            '$1 == line_prefix && $2 == shell_pid { major_collection_count++ }
            END { print major_collection_count + 0 }'
}

#######################################
# Succeed when the shell's log holds a collection line (MajorGC: or MinorGC:)
# of the given pid: SpiderMonkey logs that shell's collections. Without one,
# every count of collections would read 0.
# Arguments:
#   $1 - log path
#   $2 - the nested shell's pid
#######################################
has_collection_lines_of() {
    awk -v major_prefix="$MAJOR_COLLECTION_LINE_PREFIX" -v minor_prefix="$MINOR_COLLECTION_LINE_PREFIX" \
        -v shell_pid="$2" \
        '($1 == major_prefix || $1 == minor_prefix) && $2 == shell_pid { has_collection_line = 1; exit }
        END { exit !has_collection_line }' "$1"
}

#######################################
# Print the line perf_count_verdict prints for counts it cannot judge.
# Arguments:
#   $1 - why
#######################################
print_unjudgeable_counts() {
    printf 'perf: could not judge the counts: %s\n' "$1"
}

#######################################
# Succeed when every argument is a count: a whole number written with no
# leading zero (PERF_COUNT_PATTERN).
# Arguments:
#   $@ - words
#######################################
are_counts() {
    local word
    for word in "$@"; do
        [[ "$word" =~ $PERF_COUNT_PATTERN ]] || return 1
    done
    return 0
}

#######################################
# Judge a perf run's counts against the count budgets and print one line: the
# pass, each broken budget by name, or why the counts cannot be judged. Pure:
# it reads no file and starts nothing. Every enabled state is judged against
# the disabled state of the same run: its major collections, at most the
# disabled state's plus PERF_MAJOR_COLLECTIONS_ALLOWANCE; its frames, at most
# its Samples plus the disabled state's frames plus
# PERF_FRAMES_OVER_SAMPLES_ALLOWANCE; covered and idle, its frames at most the
# disabled state's plus PERF_COVERED_IDLE_FRAMES_ALLOWANCE; with the top bar
# hidden, no top-bar paint; and the card's offscreen redirect ALWAYS.
# Arguments:
#   $1 - the disabled state's major collections
#   $2 - the disabled state's frames
#   $3.. - each enabled state, in PERF_ENABLED_STATE_NAMES's order, as one word
#          list: "<major collections> <frames> <Samples> <top-bar paints>
#          <card redirect>"
# Returns:
#   0 every count within its budget; 1 a budget broken; 2 the counts cannot be
#   judged: a state missing, a record of the wrong length, a count that is not
#   a whole number, or a visible-busy window in which the probe counted no
#   frame, no Sample or no paint, where each must happen (a probe that is not
#   counting would make every budget pass)
#######################################
perf_count_verdict() {
    local disabled_major_collections="${1:-}" disabled_frames="${2:-}" state_index state_name breach
    local major_collections frames samples topbar_paints card_redirect joined_breaches budget_noun
    local major_collections_limit frames_limit covered_idle_frames_limit
    local expected_argument_count=$(( 2 + ${#PERF_ENABLED_STATE_NAMES[@]} ))
    local -a enabled_records=("${@:3}") record_words breaches=()
    if (( $# != expected_argument_count )); then
        print_unjudgeable_counts "wanted the disabled state's two counts and a record per enabled state ($expected_argument_count arguments), got $#"
        return "$EXIT_REFUSED"
    fi
    if ! are_counts "$disabled_major_collections" "$disabled_frames"; then
        print_unjudgeable_counts "the disabled state's counts are not whole numbers: '$disabled_major_collections' '$disabled_frames'"
        return "$EXIT_REFUSED"
    fi
    # Every record is checked before any is judged: a count that cannot be trusted voids the run, breaches included.
    for state_index in "${!PERF_ENABLED_STATE_NAMES[@]}"; do
        state_name="${PERF_ENABLED_STATE_NAMES[state_index]}"
        read -r -a record_words <<<"${enabled_records[state_index]}"
        if (( ${#record_words[@]} != PERF_ENABLED_RECORD_WORD_COUNT )) || ! are_counts "${record_words[@]:0:4}"
        then
            print_unjudgeable_counts "$state_name's record is not four whole numbers and the card's redirect: '${enabled_records[state_index]}'"
            return "$EXIT_REFUSED"
        fi
        if [[ "$state_name" == "$PERF_VISIBLE_BUSY_STATE" ]] &&
            (( record_words[1] == 0 || record_words[2] == 0 || record_words[3] == 0 )); then
            print_unjudgeable_counts "the probe counted no frame, Sample or top-bar paint in $state_name, where each must happen: it is not counting"
            return "$EXIT_REFUSED"
        fi
    done
    major_collections_limit=$(( disabled_major_collections + PERF_MAJOR_COLLECTIONS_ALLOWANCE ))
    covered_idle_frames_limit=$(( disabled_frames + PERF_COVERED_IDLE_FRAMES_ALLOWANCE ))
    for state_index in "${!PERF_ENABLED_STATE_NAMES[@]}"; do
        state_name="${PERF_ENABLED_STATE_NAMES[state_index]}"
        read -r major_collections frames samples topbar_paints card_redirect <<<"${enabled_records[state_index]}"
        frames_limit=$(( samples + disabled_frames + PERF_FRAMES_OVER_SAMPLES_ALLOWANCE ))
        if (( major_collections > major_collections_limit )); then
            breaches+=("collections: $state_name had $major_collections major collections, more than the disabled state's $disabled_major_collections plus $PERF_MAJOR_COLLECTIONS_ALLOWANCE")
        fi
        if (( frames > frames_limit )); then
            breaches+=("frames-per-sample: $state_name drew $frames frames, more than its $samples Samples plus the disabled state's $disabled_frames frames plus $PERF_FRAMES_OVER_SAMPLES_ALLOWANCE")
        fi
        if [[ "$state_name" == "$PERF_COVERED_IDLE_STATE" ]] && (( frames > covered_idle_frames_limit )); then
            breaches+=("covered-idle-frames: $state_name drew $frames frames, more than the disabled state's $disabled_frames frames plus $PERF_COVERED_IDLE_FRAMES_ALLOWANCE")
        fi
        if [[ "$state_name" == "$PERF_TOPBAR_HIDDEN_STATE" ]] && (( topbar_paints > PERF_HIDDEN_TOPBAR_PAINTS_ALLOWED )); then
            breaches+=("hidden-topbar-paints: $state_name painted the top bar while it was hidden (top-bar paints $topbar_paints, allowed $PERF_HIDDEN_TOPBAR_PAINTS_ALLOWED)")
        fi
        if [[ "$card_redirect" != "$PERF_WANTED_CARD_REDIRECT" ]]; then
            breaches+=("card-redirect: $state_name found the card's offscreen redirect $card_redirect, not $PERF_WANTED_CARD_REDIRECT")
        fi
    done
    if (( ${#breaches[@]} == 0 )); then
        printf 'perf: PASS: every count within its budget\n'
        return 0
    fi
    joined_breaches="${breaches[0]}"
    for breach in "${breaches[@]:1}"; do
        joined_breaches+="; $breach"
    done
    budget_noun='budgets'
    (( ${#breaches[@]} == 1 )) && budget_noun='budget'
    printf 'perf: FAIL: %s count %s broken: %s\n' "${#breaches[@]}" "$budget_noun" "$joined_breaches"
    return "$EXIT_REQUEST_FAILED"
}

#######################################
# Run one of perf's steps in the nested shell; exit 2 when it did not run or
# threw, since the state it was setting up is then unknown.
# Arguments:
#   $1 - verified private bus address
#   $2 - what the step does, for the message
#   $3 - JavaScript
#######################################
run_perf_step() {
    eval_in_nested_shell "$1" "$3" >/dev/null || die "perf could not $2 in the nested shell"
}

#######################################
# Print the in-shell probe's JSON answer to one request: perf-probe.js's text,
# then one call of its function, through Eval. Exit 2 when the call fails, the
# probe throws, or it refuses (naming why): it never attaches to nothing.
# Arguments:
#   $1 - verified private bus address
#   $2 - request (attach-disabled, attach-enabled, read)
#######################################
run_perf_probe() {
    local address="$1" probe_request="$2" probe_source probe_call probe_code probe_answer probe_refusal
    probe_source="$(<"$PERF_PROBE_PATH")" || die "cannot read $PERF_PROBE_PATH"
    probe_call="$PERF_PROBE_FUNCTION_NAME('$probe_request');"
    probe_code="$probe_source"$'\n'"$probe_call"
    probe_answer="$(eval_in_nested_shell "$address" "$probe_code")" \
        || die "the in-shell probe's $probe_request did not run"
    probe_refusal="$(jq -r '.refused // empty' <<<"$probe_answer")" \
        || die "the in-shell probe's answer to $probe_request is not a JSON object: $probe_answer"
    [[ -z "$probe_refusal" ]] || die "the in-shell probe refused $probe_request: $probe_refusal"
    printf '%s\n' "$probe_answer"
}

#######################################
# Print one field of the probe's JSON answer, or nothing when it has none
# (perf_count_verdict then refuses to judge the record).
# Arguments:
#   $1 - the probe's answer
#   $2 - field name
#######################################
perf_probe_answer_field() {
    jq -r --arg field_name "$2" '.[$field_name] // empty' <<<"$1"
}

#######################################
# Start the window perf covers the card with: gnome-calculator, as a client of
# the nested shell only, through the run's isolated environment plus its
# Wayland display (a socket in the run's runtime dir), the Wayland backend and
# the run's private bus; logged to log/gnome-calculator.log. Records it in
# PERF_WINDOW_PID and PERF_WINDOW_STARTTIME for end_perf_window.
# Arguments:
#   $1 - run directory
#   $2 - verified private bus address
#   $3 - gnome-calculator's path
#######################################
start_perf_window() {
    local run_dir="$1" address="$2" window_command_path="$3"
    local window_log_path="$run_dir/log/$PERF_WINDOW_COMMAND_NAME.log"
    build_isolated_env_command "$run_dir" || die "cannot build the isolated environment"
    "${ISOLATED_ENV_COMMAND[@]}" "WAYLAND_DISPLAY=$NESTED_WAYLAND_DISPLAY" "GDK_BACKEND=$PERF_WINDOW_GDK_BACKEND" \
        "DBUS_SESSION_BUS_ADDRESS=$address" "$window_command_path" </dev/null >"$window_log_path" 2>&1 &
    PERF_WINDOW_PID=$!
    PERF_WINDOW_STARTTIME="$(starttime_of_process /proc "$PERF_WINDOW_PID")" || PERF_WINDOW_STARTTIME=""
}

#######################################
# Succeed while the window perf started is still the process it recorded.
#######################################
is_perf_window_running() {
    [[ -n "$PERF_WINDOW_PID" && -n "$PERF_WINDOW_STARTTIME" &&
        "$(starttime_of_process /proc "$PERF_WINDOW_PID")" == "$PERF_WINDOW_STARTTIME" ]]
}

#######################################
# perf's exit: end the window it started, only while it is still that process.
#######################################
end_perf_window() {
    is_perf_window_running && kill -TERM "$PERF_WINDOW_PID" 2>/dev/null
    return 0
}

#######################################
# Wait until the nested session holds exactly one window (the one perf
# started); fail as soon as that process is gone, or after
# PERF_WINDOW_APPEAR_TIMEOUT_SECONDS.
# Arguments:
#   $1 - verified private bus address
#######################################
wait_for_perf_window() {
    local address="$1" deadline=$((SECONDS + PERF_WINDOW_APPEAR_TIMEOUT_SECONDS)) window_count
    while (( SECONDS < deadline )); do
        window_count="$(eval_in_nested_shell "$address" "$PERF_COUNT_WINDOWS_JS")" || return 1
        [[ "$window_count" == 1 ]] && return 0
        is_perf_window_running || { note "$PERF_WINDOW_COMMAND_NAME exited before its window appeared"; return 1; }
        sleep "$PERF_WINDOW_POLL_INTERVAL_SECONDS"
    done
    note "no single window appeared within $PERF_WINDOW_APPEAR_TIMEOUT_SECONDS s"
    return 1
}

#######################################
# Write a scenario request for the run's replay service, after checking it
# still runs; exit 2 otherwise.
# Arguments:
#   $1 - run directory
#   $2 - scenario word
#######################################
request_perf_scenario() {
    local run_dir="$1" scenario_name="$2"
    is_recorded_process_running "$run_dir" service \
        || die "refusing: the run's replay service is not running (see $run_dir/log/service.log)"
    write_scenario_word "$run_dir" "$scenario_name" || die "could not write $run_dir/$REPLAY_SCENARIO_RELATIVE_PATH"
}

#######################################
# Measure one window of PERF_WINDOW_SECONDS with no eval running: the nested
# shell's CPU % and its main thread's median per tick (the cost script, both at
# once, given the nested shell's pid and the real /proc, never left to look for
# a gnome-shell), and the major collections it logged meanwhile. Sets
# PERF_WINDOW_CPU_PERCENT, PERF_WINDOW_TICK_MEDIAN_MS and
# PERF_WINDOW_MAJOR_COLLECTIONS; exit 2 when any of them cannot be read.
# Arguments:
#   $1 - run directory
#   $2 - the nested shell's pid
#######################################
measure_perf_window() {
    local run_dir="$1" shell_pid="$2" window_start_offset cpu_percent_job_pid
    local shell_log_path="$run_dir/log/shell.log" cpu_percent_path="$run_dir/$PERF_CPU_PERCENT_RELATIVE_PATH"
    local -a cost_command=(env "GNOME_SHELL_PID=$shell_pid" PROC_ROOT=/proc bash "$COST_SCRIPT_PATH")
    window_start_offset="$(stat -c %s "$shell_log_path")" || die "cannot read the size of $shell_log_path"
    "${cost_command[@]}" --cpu-percent "$PERF_WINDOW_SECONDS" >"$cpu_percent_path" &
    cpu_percent_job_pid=$!
    if ! PERF_WINDOW_TICK_MEDIAN_MS="$("${cost_command[@]}" --tick-median "$PERF_WINDOW_SECONDS")"; then
        kill "$cpu_percent_job_pid" 2>/dev/null
        die "the cost script could not read the nested shell's main thread"
    fi
    wait "$cpu_percent_job_pid" || die "the cost script could not read the nested shell's CPU"
    PERF_WINDOW_CPU_PERCENT="$(<"$cpu_percent_path")"
    PERF_WINDOW_MAJOR_COLLECTIONS="$(count_major_collections_since "$shell_log_path" "$window_start_offset" \
        "$shell_pid")" || die "cannot count the collections in $shell_log_path"
}

#######################################
# Keep and print one state's readings: the window's (measure_perf_window) and
# the probe's read. The disabled state's are kept for the others, with its
# Samples counted by time (no client); an enabled state's record is appended to
# PERF_ENABLED_STATE_RECORDS, and its CPU reported over the disabled state's.
# Arguments:
#   $1 - state name
#   $2 - the probe's answer to read
#######################################
record_perf_state() {
    local state_name="$1" probe_answer="$2" frames samples topbar_paints card_redirect cpu_over_disabled
    local samples_by_time cpu_report
    frames="$(perf_probe_answer_field "$probe_answer" frames)"
    if [[ "$state_name" == "$PERF_DISABLED_STATE" ]]; then
        PERF_DISABLED_MAJOR_COLLECTIONS="$PERF_WINDOW_MAJOR_COLLECTIONS"
        PERF_DISABLED_FRAMES="$frames"
        PERF_DISABLED_CPU_PERCENT="$PERF_WINDOW_CPU_PERCENT"
        samples_by_time=$(( PERF_WINDOW_SECONDS / PERF_SAMPLE_INTERVAL_SECONDS ))
        printf '%s: cpu=%s%% tick-median=%sms major-collections=%s frames=%s samples=%s (by time: no client while disabled) top-bar-paints=- card-redirect=-\n' \
            "$state_name" "$PERF_WINDOW_CPU_PERCENT" "$PERF_WINDOW_TICK_MEDIAN_MS" "$PERF_WINDOW_MAJOR_COLLECTIONS" \
            "$frames" "$samples_by_time"
        return 0
    fi
    samples="$(perf_probe_answer_field "$probe_answer" samples)"
    topbar_paints="$(perf_probe_answer_field "$probe_answer" topbarPaints)"
    card_redirect="$(perf_probe_answer_field "$probe_answer" cardRedirect)"
    PERF_ENABLED_STATE_RECORDS+=("$PERF_WINDOW_MAJOR_COLLECTIONS $frames $samples $topbar_paints $card_redirect")
    cpu_over_disabled="$(awk -v state_percent="$PERF_WINDOW_CPU_PERCENT" -v disabled_percent="$PERF_DISABLED_CPU_PERCENT" \
        'BEGIN { printf "%+.3f", state_percent - disabled_percent }')"
    cpu_report="$PERF_WINDOW_CPU_PERCENT% ($cpu_over_disabled over disabled)"
    printf '%s: cpu=%s tick-median=%sms major-collections=%s frames=%s samples=%s top-bar-paints=%s card-redirect=%s\n' \
        "$state_name" "$cpu_report" "$PERF_WINDOW_TICK_MEDIAN_MS" "$PERF_WINDOW_MAJOR_COLLECTIONS" "$frames" \
        "$samples" "$topbar_paints" "$card_redirect"
}

#######################################
# Measure one state: request its scenario (so every run sees the same input),
# run its setup steps, wait PERF_WARM_UP_SECONDS, attach or reset the probe for
# it, measure one window with no eval running, read the probe, then keep and
# print the readings.
# Arguments:
#   $1 - run directory
#   $2 - verified private bus address
#   $3 - the nested shell's pid
#   $4 - state name
#   $5 - its scenario
#   $@ - its setup steps' JavaScript, in order
#######################################
measure_perf_state() {
    local run_dir="$1" address="$2" shell_pid="$3" state_name="$4" scenario_name="$5" setup_js
    local attach_request="$PERF_PROBE_ATTACH_ENABLED_REQUEST" probe_answer
    shift 5
    note "perf: $state_name: $scenario_name input, $PERF_WARM_UP_SECONDS s to settle, then a $PERF_WINDOW_SECONDS s window"
    request_perf_scenario "$run_dir" "$scenario_name"
    for setup_js in "$@"; do
        run_perf_step "$address" "set up $state_name" "$setup_js"
    done
    sleep "$PERF_WARM_UP_SECONDS"
    [[ "$state_name" == "$PERF_DISABLED_STATE" ]] && attach_request="$PERF_PROBE_ATTACH_DISABLED_REQUEST"
    run_perf_probe "$address" "$attach_request" >/dev/null
    measure_perf_window "$run_dir" "$shell_pid"
    probe_answer="$(run_perf_probe "$address" "$PERF_PROBE_READ_REQUEST")" || exit "$EXIT_REFUSED"
    record_perf_state "$state_name" "$probe_answer"
}

#######################################
# `perf`: measure a live run started with --gc-log --replay against the count
# budgets (see the header). Refuses (exit 2) before anything runs in the nested
# shell unless the run is a verified, live run of this script started with
# both options, its replay service runs, gnome-calculator is on PATH and the
# shell's log holds a collection line of the recorded gnome-shell. Returns
# perf_count_verdict's status: 0 within every budget, 1 a budget broken, 2 the
# counts cannot be judged.
#######################################
perf_subcommand() {
    local run_dir address shell_pid window_command_path window_count verdict_status header_line
    require_tools stat
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    verified_run_suffix "$run_dir" >/dev/null || die "not a run directory of this script: $run_dir"
    is_requested_in_run "$run_dir" "$GC_LOG_RUN_VALUE_NAME" \
        || die "refusing: the run in $run_dir was not started with $GC_LOG_OPTION"
    is_requested_in_run "$run_dir" "$REPLAY_RUN_VALUE_NAME" \
        || die "refusing: the run in $run_dir was not started with $REPLAY_OPTION"
    address="$(live_run_session_address "$run_dir")" || exit "$EXIT_REFUSED"
    is_recorded_process_running "$run_dir" service \
        || die "refusing: the run's replay service is not running (see $run_dir/log/service.log)"
    # Looked for only now: a refusal above never depends on which tools are installed.
    require_tools "$PERF_WINDOW_COMMAND_NAME"
    require_tools busctl jq awk tail sort env mktemp mv
    window_command_path="$(command -v "$PERF_WINDOW_COMMAND_NAME")"
    # The pid is_nested_shell_live just verified as the run's gnome-shell (same start time, in the run's session).
    shell_pid="$(recorded_run_value "$run_dir" gnome-shell)"
    [[ "$shell_pid" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]] || die "refusing: the run has no recorded gnome-shell pid"
    has_collection_lines_of "$run_dir/log/shell.log" "$shell_pid" \
        || die "refusing: $run_dir/log/shell.log holds no collection line of the nested shell ($shell_pid): is the GC log on?"

    window_count="$(eval_in_nested_shell "$address" "$PERF_COUNT_WINDOWS_JS")" || exit "$EXIT_REFUSED"
    [[ "$window_count" == 0 ]] \
        || die "refusing: the nested session already has $window_count window(s); perf covers the card with its own"
    trap end_perf_window EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    start_perf_window "$run_dir" "$address" "$window_command_path"
    wait_for_perf_window "$address" || die "the $PERF_WINDOW_COMMAND_NAME window did not open (see $run_dir/log/)"

    header_line="perf: nested gnome-shell $shell_pid of $run_dir; each state: its scenario, $PERF_WARM_UP_SECONDS s to settle, one $PERF_WINDOW_SECONDS s window with no eval running"
    header_line+="; cpu is % of one core for the whole nested shell, the probe's own per-frame counting included, reported and not gated; the counts are gated"
    printf '%s\n' "$header_line"
    measure_perf_state "$run_dir" "$address" "$shell_pid" "$PERF_DISABLED_STATE" "$IDLE_SCENARIO_NAME" \
        "$PERF_DISABLE_EXTENSION_JS"
    measure_perf_state "$run_dir" "$address" "$shell_pid" "$PERF_COVERED_IDLE_STATE" "$IDLE_SCENARIO_NAME" \
        "$PERF_ENABLE_EXTENSION_JS" "$PERF_COVER_CARD_JS"
    measure_perf_state "$run_dir" "$address" "$shell_pid" "$PERF_COVERED_BUSY_STATE" "$BUSY_SCENARIO_NAME"
    measure_perf_state "$run_dir" "$address" "$shell_pid" "$PERF_TOPBAR_HIDDEN_STATE" "$BUSY_SCENARIO_NAME" \
        "$PERF_HIDE_TOPBAR_JS"
    measure_perf_state "$run_dir" "$address" "$shell_pid" "$PERF_VISIBLE_BUSY_STATE" "$BUSY_SCENARIO_NAME" \
        "$PERF_SHOW_TOPBAR_JS" "$PERF_UNCOVER_CARD_JS"
    perf_count_verdict "$PERF_DISABLED_MAJOR_COLLECTIONS" "$PERF_DISABLED_FRAMES" "${PERF_ENABLED_STATE_RECORDS[@]}"
    verdict_status=$?
    return "$verdict_status"
}

main() {
    local subcommand="${1:-}"
    case "$subcommand" in
        start)
            shift
            parse_start_options "$@"
            start_subcommand ;;
        eval)
            (( $# == 2 )) || usage_error "eval takes one argument: the JavaScript, or -"
            eval_subcommand "$2" ;;
        screenshot)
            shift
            screenshot_subcommand "$@" ;;
        scenario)
            (( $# == 2 )) || usage_error "scenario takes one word: ${REPLAY_SCENARIO_NAMES[*]}"
            scenario_subcommand "$2" ;;
        perf)
            (( $# == 1 )) || usage_error "perf takes no arguments"
            perf_subcommand ;;
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
    # Exit inside this block, which bash has already read: a run's supervisor waits in main for up to 20 minutes,
    # and on return bash would go on reading this file from where it stopped, through any edit made meanwhile.
    exit "$?"
fi
