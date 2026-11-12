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
#                the same way after the sampler, in fixture mode: start writes the run's
#                state/cockpit-fixture.json from tests/fixtures/cockpit/nested-state.json, every
#                source stamped now with an interval of the run's lifetime (so none goes stale
#                within it) and no window candidates, and RESOURCE_PULSE_COCKPIT_FIXTURE names it
#                to that service alone. It then runs no source, reads no config and never asks
#                herdr (its client is never built), and answers every FocusSession with the file's
#                focusReply; it reads the file again on change. Its config home is the run's too,
#                so even outside fixture mode it would find no herdr socket
#   identity     a run's launcher, supervisor, services and gnome-shell are recorded by pid AND start
#                time (stat field 22), and count only while both match: a pid alone can be
#                reused once its process ends
#   requests     eval, screenshot, scenario, perf, window, pointer and check go only to a live
#                run: its supervisor running, and its recorded gnome-shell running, as
#                gnome-shell, in the run's own session; scenario and perf also need the run
#                started with --replay, and its replay service running; perf also needs
#                --gc-log; window, a click and check also need the cockpit in fixture mode,
#                where a session row's click can reach no herdr; check also needs --gc-log
#                --replay, for the perf pass that ends it
#   windows      window's Gtk 4 window (tests/nested/probe-window.js) refuses to open outside
#                a nested run's own environment; it gets the run's environment, its Wayland
#                display, the Wayland backend and its private bus, and nothing of the
#                caller's; it runs in a session of its own, recorded by pid and start time,
#                and stop and the supervisor's exit end it while it is still that process
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
# (usage, the bus configs, the environment, the refusals, check cockpit against
# a stand-in shell) are in scripts/test-resource-pulse.sh, and the in-shell
# files' own rows (run against a fake shell under plain gjs) in
# gnome-shell/tests/perfProbe.test.js and gnome-shell/tests/cockpitCheck.test.js.
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
#       (exit 1): an enabled state's major collections more than the disabled
#       state's plus one; its frames more than its Samples plus the disabled
#       state's frames plus two; covered and idle, more frames than the disabled
#       state's plus three; a top-bar paint while the top bar is hidden; the card
#       not drawn through its offscreen texture; and the disabled state's own
#       major collections more than four (a defect that outlives disable()).
#       Every nested run draws the cockpit's grid, so after each enabled state's
#       counts it reads the grid (a line per state), and a second verdict line
#       names each broken cockpit budget (exit 1): a data card not drawn
#       through its own texture, the layer or the system cell's wrapper drawn
#       through one (ruling D12), and a fallback timeout armed while Samples
#       flow; a state whose record reads no redirect of one of those parts
#       cannot be judged (exit 2). An enabled state the probe does not find set
#       up as it is named (the card covered in the covered states and visible in
#       visible-busy; the grid of the run's fixture drawn, every card of it, in
#       every enabled state; none of it visible in the covered states and all of
#       it in visible-busy; the top bar hidden only in topbar-hidden-covered)
#       stops it there, with exit 2.
#       Every exit once it acts on the run (a breach, a failure or a signal too)
#       puts the run back: its window and its background measurement ended, the
#       extension enabled and the top bar shown again
#   scripts/resource-pulse-nested.sh window <title>
#       open a small Gtk 4 window titled <title> (a plain name) in a live run whose
#       cockpit serves the run's fixture, as a client of the nested shell only (see
#       windows above); record it in state/windows/<title>.pid and .starttime; name its
#       pid as the one window candidate of the fixture's focusReply; wait until the
#       shell shows it; print its pid. stop, and the run's end, close it
#   scripts/resource-pulse-nested.sh pointer <x> <y> [click]
#       move the nested shell's own virtual pointer (a Clutter virtual device of its
#       seat: tests/nested/pointer.js) to a point in stage pixels, click the primary
#       button there when asked (only in a run whose cockpit serves the fixture), and
#       wait until the shell moved it: a pointer that never arrives is exit 2
#   scripts/resource-pulse-nested.sh check cockpit
#       judge the cockpit of a live run started with --gc-log --replay whose cockpit
#       serves the run's fixture and whose session has no window yet (refused
#       otherwise, before it acts), one line per step (ok, bad, or could not judge:
#       never ok), each in-shell step a request of tests/nested/cockpit-check.js:
#       the extension ACTIVE, and the log so far free of its errors; the layer and
#       the grid; hover; two windows of its own (a decoy holding the focus, then
#       herdr-probe, the fixture's one candidate); the clicks (from the decoy's focus,
#       from every window minimized, a reply naming no window, one not focused, two
#       quick clicks); cover and reveal; a source made stale and put back; the
#       dropdown; the lock path (disable, enable); shots/cockpit-<pass>.png; the log;
#       and the count budgets through perf (about nine minutes more). It may run
#       again in the same run: each pass is numbered in state/run.values, judges the
#       log only from where it began (the first pass from the run's start), keeps its
#       own screenshot, and cannot judge the two clicks whose one log line the
#       extension's limiter (10 minutes, kept across disable and enable) still holds
#       from an earlier pass, naming how long is left. It rewrites only the run's copy
#       of the fixture, and puts it back and closes its windows on every exit. A TERM
#       or an interrupt during its perf pass ends that pass too: perf puts the run
#       back once its current wait ends (up to a minute), and the check waits for it.
#       Exit 1 when a step is bad, else 2 when one could not be judged
#   scripts/resource-pulse-nested.sh stop
#       stop the nested shell, its two services, the windows `window` opened and
#       everything else it started;
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
#       threw, a screenshot it could not take, a perf count over its budget, a
#       check step bad);
#       2 refused, bad usage or could not run (for perf, also a count it could not
#       judge, or a state not set up as it is named: never a pass and never a
#       breach).

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
# The probe's fourth request: the cockpit grid's facts at the end of an enabled state's window, after its read.
readonly PERF_PROBE_READ_COCKPIT_REQUEST='read-cockpit'
# The probe's two modes, and where an answer shows which one it ran in: .attached after an attach, .mode after a read.
readonly PERF_PROBE_DISABLED_MODE='disabled'
readonly PERF_PROBE_ENABLED_MODE='enabled'
readonly PERF_PROBE_ATTACHED_KEY='attached'
readonly PERF_PROBE_MODE_KEY='mode'
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
# The count budgets (docs/superpowers/specs/2026-11-10-resource-pulse-performance-design.md, "Budgets"), the counted
# ones over the disabled state of the same run: an enabled state's major collections at most the disabled state's
# plus one; its frames at most its Samples plus the disabled state's frames plus two; covered and idle, at most the
# disabled state's frames plus three (the nested panel's clock and the covered card's dimmed repaint draw a few frames
# in any window); no top-bar paint while the top bar is hidden; the card drawn through an offscreen texture (ALWAYS).
readonly PERF_MAJOR_COLLECTIONS_ALLOWANCE=1
# And one absolute bound, on the disabled state itself, since the counted budgets are relative to it: an idle nested
# shell makes one or two major collections a minute (three have been seen), and a forced-collection defect five or
# six. One that outlives disable() (a proxy left receiving Samples, say) raises the disabled state with the rest, and
# would pass a budget measured against it.
readonly PERF_MAX_DISABLED_MAJOR_COLLECTIONS=4
readonly PERF_FRAMES_OVER_SAMPLES_ALLOWANCE=2
readonly PERF_COVERED_IDLE_FRAMES_ALLOWANCE=3
readonly PERF_HIDDEN_TOPBAR_PAINTS_ALLOWED=0
readonly PERF_WANTED_CARD_REDIRECT='ALWAYS'
# How many words an enabled state's record has: major collections, frames, Samples, top-bar paints, card redirect.
readonly PERF_ENABLED_RECORD_WORD_COUNT=5
# The fields of the two facts a read answers about how an enabled state was set up (the extension's _isCardVisible,
# the indicator's mapped), and what jq prints for a fact: check_perf_state_setup compares them with each state's name.
readonly PERF_CARD_VISIBLE_FIELD='isCardVisible'
readonly PERF_INDICATOR_MAPPED_FIELD='isIndicatorMapped'
readonly PERF_FACT_PATTERN='^(true|false)$'
# A count as perf's readings write it: no leading zero, which bash arithmetic would read as octal.
readonly PERF_COUNT_PATTERN='^(0|[1-9][0-9]*)$'
# The cockpit's grid, drawn in every nested run (read-cockpit): each enabled state's facts as words, and its record
# for perf_cockpit_verdict, "<redirects> <armed fallbacks>". A list of ids or names is one word, joined with commas,
# or PERF_NONE_WORD when empty; the drawn ids and the redirects are PERF_NO_GRID_WORD with no layer; a redirect is
# "<part>:<name>". The jq program prints the four words (visible ids, drawn ids, redirects, armed fallbacks), or
# nothing when a fact is not of its type or a name is not one plain word.
readonly PERF_NONE_WORD='none'
readonly PERF_NO_GRID_WORD='no-grid'
readonly PERF_COCKPIT_RECORD_WORD_COUNT=2
readonly PERF_COCKPIT_WORDS_JQ='
    def is_word_list: type == "array" and all(.[]; type == "string" and test("^[A-Za-z0-9_-]+$"));
    def word: if length == 0 then "none" else join(",") end;
    if (.visibleCardIds | is_word_list) and (.armedCockpitTimers | is_word_list)
        and ((.layerCardIds == null and .cockpitRedirects == null)
            or ((.layerCardIds | is_word_list) and (.cockpitRedirects | type) == "object"
                and (.cockpitRedirects | keys_unsorted | is_word_list)
                and ([.cockpitRedirects[]] | is_word_list)))
    then [(.visibleCardIds | word),
        (if .layerCardIds == null then "no-grid" else (.layerCardIds | word) end),
        (if .cockpitRedirects == null then "no-grid"
            else (.cockpitRedirects | to_entries | map("\(.key):\(.value)") | join(",")) end),
        (.armedCockpitTimers | word)] | join(" ")
    else empty end'
# The system cell's card id: the cell that adopts the v2 card.
readonly PERF_V2_CARD_ID='system'
# The cards the run's fixture lays out that this release draws (its layout's ids among COCKPIT_KNOWN_CARD_IDS_JSON),
# as read-cockpit's sorted words. Every nested run serves that fixture, so in every enabled state the layer draws
# exactly these: no layer, or another set, is a state not set up as it is named, never a grid budget passed on a
# shell that drew no grid.
readonly PERF_FIXTURE_GRID_CARD_IDS_WORD='apps,connections,sessions,system'
# Ruling D12: the layer and the system cell's wrapper draw through no texture of their own (the v2 card the wrapper
# adopts keeps its own, which the cardRedirect budget checks); each data card draws through its own.
readonly PERF_LAYER_REDIRECT_PART='layer'
readonly PERF_WANTED_LAYER_REDIRECT='NONE'
readonly PERF_WANTED_SYSTEM_WRAPPER_REDIRECT='NONE'
readonly PERF_WANTED_DATA_CARD_REDIRECT='ALWAYS'
readonly -a PERF_DATA_CARD_IDS=(apps connections sessions)
# Every part ruling D12 rules on: a grid record must read the redirect of each, or it cannot be judged.
readonly -a PERF_REDIRECT_PART_NAMES=("$PERF_LAYER_REDIRECT_PART" "$PERF_V2_CARD_ID" "${PERF_DATA_CARD_IDS[@]}")
readonly PERF_REDIRECT_PAIR_PATTERN='^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$'
# SpiderMonkey's collection lines in the shell's log (`start --gc-log`): the line's first column, then its pid.
readonly MAJOR_COLLECTION_LINE_PREFIX='MajorGC:'
readonly MINOR_COLLECTION_LINE_PREFIX='MinorGC:'
# What perf runs in the nested shell around the probe: the windows of the session, the one window perf opened (an
# error unless there is exactly one), and each state's steps. Each answers a word, or throws.
readonly PERF_NORMAL_WINDOWS_JS='global.display.list_all_windows()
    .filter(window => window.get_window_type() === Meta.WindowType.NORMAL)'
readonly PERF_ONE_WINDOW_JS="(() => {
    const normalWindows = $PERF_NORMAL_WINDOWS_JS;
    if (normalWindows.length !== 1)
        throw new Error('perf expects exactly one window in the nested session, found ' + normalWindows.length);
    return normalWindows[0];
})()"
readonly PERF_EXTENSION_JS="Main.extensionManager.lookup('$EXTENSION_UUID').stateObj"
readonly PERF_COUNT_WINDOWS_JS="$PERF_NORMAL_WINDOWS_JS.length"
readonly PERF_DISABLE_EXTENSION_JS="(() => {
    Main.extensionManager.disableExtension('$EXTENSION_UUID');
    return 'disabled';
})()"
readonly PERF_ENABLE_EXTENSION_JS="(() => {
    Main.extensionManager.enableExtension('$EXTENSION_UUID');
    return 'enabled';
})()"
# Mutter 50.1's meta_window_maximize takes no flags (its Meta-18.typelib records no argument): one passed would only
# make GJS log "Too many arguments" into the shell's log.
readonly PERF_COVER_CARD_JS="(() => {
    const coveringWindow = $PERF_ONE_WINDOW_JS;
    coveringWindow.unminimize();
    coveringWindow.maximize();
    return 'covered';
})()"
readonly PERF_UNCOVER_CARD_JS="(() => { $PERF_ONE_WINDOW_JS.minimize(); return 'uncovered'; })()"
readonly PERF_HIDE_TOPBAR_JS="(() => { $PERF_EXTENSION_JS._indicator.hide(); return 'hidden'; })()"
readonly PERF_SHOW_TOPBAR_JS="(() => { $PERF_EXTENSION_JS._indicator.show(); return 'shown'; })()"
# perf's exit, on every path, puts the run back as perf found it: the extension enabled when it has no indicator
# (perf disabled it), then the indicator shown when it has one (perf hid it). Neither throws for a part that is not
# there.
readonly PERF_INDICATOR_OR_NULL_JS="Main.extensionManager.lookup('$EXTENSION_UUID')?.stateObj?._indicator ?? null"
readonly PERF_RESTORE_EXTENSION_JS="(() => {
    if ($PERF_INDICATOR_OR_NULL_JS)
        return 'enabled already';
    Main.extensionManager.enableExtension('$EXTENSION_UUID');
    return 'enabled';
})()"
readonly PERF_RESTORE_TOPBAR_JS="(() => {
    const indicator = $PERF_INDICATOR_OR_NULL_JS;
    indicator?.show();
    return indicator ? 'shown' : 'no indicator';
})()"

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
# The cockpit service's fixture mode (service/cockpit.js: it runs no source, reads no config, never asks herdr, and
# answers every FocusSession with the file's focusReply): the checkout's nested fixture, written into the run with
# fresh stamps (write_run_cockpit_fixture) beside a copy as written, recorded as cockpit-fixture= in state/run.values,
# and named to the cockpit service alone by its variable.
readonly COCKPIT_FIXTURE_TEMPLATE="$REPO_ROOT/gnome-shell/tests/fixtures/cockpit/nested-state.json"
readonly COCKPIT_FIXTURE_RELATIVE_PATH='state/cockpit-fixture.json'
readonly COCKPIT_FIXTURE_START_RELATIVE_PATH='state/cockpit-fixture.start.json'
readonly COCKPIT_FIXTURE_RUN_VALUE_NAME='cockpit-fixture'
readonly COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE='RESOURCE_PULSE_COCKPIT_FIXTURE'
# Every source stamped now ($now_usec) with an interval of the run's lifetime ($interval_seconds), no window candidates.
# shellcheck disable=SC2016  # A jq program: jq binds $now_usec and $interval_seconds.
readonly COCKPIT_FIXTURE_FRESH_JQ='
    .state.sources |= with_entries(.value.sampledAtUsec = $now_usec | .value.intervalSeconds = $interval_seconds)
    | .focusReply.windowPidCandidates = []'
# The wall clock in microseconds, as current_time_usec prints it: sixteen digits until the year 2286.
readonly TIME_USEC_PATTERN='^[1-9][0-9]{15}$'

# The in-shell halves of window, pointer and check cockpit, each a file the harness sends through Eval followed by one
# call of the function it declares (gnome-shell/tests/cockpitCheck.test.js runs the same texts under plain gjs against
# a fake shell), and the Gtk 4 window `window` opens, which refuses outside a nested run.
readonly COCKPIT_CHECK_PATH="$NESTED_FILES_DIR/cockpit-check.js"
readonly COCKPIT_CHECK_FUNCTION_NAME='resourcePulseCockpitCheck'
readonly POINTER_SCRIPT_PATH="$NESTED_FILES_DIR/pointer.js"
readonly POINTER_FUNCTION_NAME='resourcePulseNestedPointer'
readonly PROBE_WINDOW_SCRIPT_PATH="$NESTED_FILES_DIR/probe-window.js"
# window: a title is a plain name; the run records each window it opened by pid and start time, under its title.
readonly WINDOW_TITLE_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
readonly WINDOWS_RELATIVE_DIR='state/windows'
readonly WINDOW_PID_SUFFIX='.pid'
readonly WINDOW_STARTTIME_SUFFIX='.starttime'
readonly PROBE_WINDOW_GDK_BACKEND='wayland'
# shellcheck disable=SC2016  # jq programs: jq binds the $ names.
readonly WINDOW_FOCUS_REPLY_JQ='.focusReply = {focused: true, windowPid: null, error: null, windowPidCandidates: [$pid]}'
# pointer: a coordinate in stage pixels (written as JSON writes a number: no leading zero), and the word for a click.
readonly POINTER_COORDINATE_PATTERN='^(0|[1-9][0-9]*)([.][0-9]+)?$'
readonly POINTER_CLICK_WORD='click'
readonly CHECK_COCKPIT_WORD='cockpit'
# The verdicts the in-shell answers carry.
readonly CHECK_OK_VERDICT='ok'
readonly CHECK_BAD_VERDICT='bad'
readonly CHECK_PENDING_VERDICT='pending'
readonly CHECK_COULD_NOT_JUDGE_VERDICT='could-not-judge'
# A request is asked again every CHECK_POLL_INTERVAL_SECONDS while its answer is bad or pending, at most this often:
readonly CHECK_POLL_INTERVAL_SECONDS=0.25
readonly WINDOW_APPEAR_ATTEMPTS=120   # 30 s for a window to appear
readonly POINTER_SETTLE_ATTEMPTS=20   # 5 s for the shell to move the pointer
readonly TOOLTIP_APPEAR_ATTEMPTS=12   # 3 s: the hover delay is 300 ms, the fade-in 150 ms
readonly FOCUS_ANSWER_ATTEMPTS=20     # 5 s: a FocusSession call times out at 2 s
readonly STATE_SETTLE_ATTEMPTS=20     # 5 s for a cover, a reveal or the menu to be read
readonly REVEAL_DRAW_ATTEMPTS=8       # 2 s, one Sample's interval: a reveal's read draws at once
readonly DRAW_WATCH_ATTEMPTS=60       # 15 s for a change to reach the shell, and the next Sample
readonly STALE_ATTEMPTS=120           # 30 s: going stale takes a change, a pull and its answer, each on a Sample
# Fixed waits: the cockpit service reads its fixture again 200 ms after the first change event; a click that must
# activate nothing has had its chance once its answer is in; three Samples pass while the cards are covered.
readonly FIXTURE_RELOAD_WAIT_SECONDS=2
readonly NO_ACTIVATION_WAIT_SECONDS=3
readonly COVERED_SAMPLES_WAIT_SECONDS=6
readonly LOCK_PATH_TIMEOUT_MS=10000
# The windows check cockpit opens, in this order: a decoy that holds the focus, then the window the fixture's
# focusReply names, as herdr's terminal.
readonly DECOY_WINDOW_TITLE='rp-decoy'
readonly HERDR_PROBE_WINDOW_TITLE='herdr-probe'
# A pid above the kernel's largest (2^22): a candidate that matches no window.
readonly NO_WINDOW_PID=4194305
readonly HERDR_UNREACHABLE_CODE='herdr-unreachable'
# The fixture's rewrites check cockpit makes in the run's copy (never the checkout's).
# shellcheck disable=SC2016  # jq programs: jq binds the $ names.
readonly NOT_FOCUSED_REPLY_JQ='.focusReply = {focused: false, windowPid: null, error: $code, windowPidCandidates: []}'
# shellcheck disable=SC2016  # jq programs: jq binds the $ names.
readonly SESSION_RENAME_JQ='.state.sources.sessions.rows[0].name = $name'
# shellcheck disable=SC2016  # jq programs: jq binds the $ names.
readonly STALE_NETWORK_JQ='.state.sources.network.sampledAtUsec -=
    ($intervals * .state.sources.network.intervalSeconds * 1000000)'
# Past lib/constants.js COCKPIT_SOURCE_STALE_INTERVALS (3), so the network source is stale.
readonly STALE_NETWORK_INTERVALS=4
readonly STALE_CARD_ID='connections'
readonly COVERED_NAME_SUFFIX='-covered'
readonly VISIBLE_NAME_SUFFIX='-visible'
readonly DROPDOWN_NAME_SUFFIX='-dropdown'
readonly LAYER_SURFACE='layer'
readonly DROPDOWN_SURFACE='dropdown'
# lib/constants.js COCKPIT_DRAWN_CARD_IDS: the card ids this release draws; the fixture names others too.
readonly COCKPIT_KNOWN_CARD_IDS_JSON='["system","apps","connections","sessions"]'
# shellcheck disable=SC2016  # jq programs: jq binds the $ names.
readonly GRID_OPTIONS_JQ='{expectedCaptions: [.state.layout.groups[].caption],
    expectedCardIds: ([.state.layout.groups[].cards[] | select(IN($known[]))] | unique),
    unknownCardIds: ([.state.layout.groups[].cards[] | select(IN($known[]) | not)] | unique)}'
readonly SESSION_NAMES_JQ='[.state.sources.sessions.rows[].name]'
readonly FIRST_SESSION_NAME_JQ='.state.sources.sessions.rows[0].name'
# Each pass of check cockpit in a run keeps its own screenshot: shots/cockpit-<pass number>.png.
readonly CHECK_SCREENSHOT_NAME_PREFIX='cockpit-'
# check cockpit's passes in a run, counted in state/run.values (the last value is the latest pass's number).
readonly CHECK_PASS_RUN_VALUE_NAME='check-cockpit-pass'
# The extension's log limiter (lib/errorLog.js, lib/constants.js ERROR_LOG_REPEAT_INTERVAL_USEC): one line per reason
# at most once per interval, by the nested shell's monotonic clock, kept across disable() and enable(); it restarts
# only when it lets a line through. click-no-window and click-not-focused each wait for one such line: a pass about
# to judge one records first, by that clock, the end of the step's wait (by when its line is logged), and a later
# pass of the run within the interval of that time cannot judge that step.
readonly EXTENSION_LOG_REPEAT_INTERVAL_USEC=600000000
readonly USEC_PER_SECOND=1000000
readonly NO_WINDOW_LOGGED_RUN_VALUE_NAME='check-no-window-logged-usec'
readonly NOT_FOCUSED_LOGGED_RUN_VALUE_NAME='check-not-focused-logged-usec'
# What a pass records when the nested shell's clock could not be read: a later pass then cannot judge the step.
readonly UNKNOWN_TIME_WORD='unknown'
# Where check cockpit's perf pass writes its lines (perf runs in the background, so a signal ends the check promptly).
readonly CHECK_PERF_OUTPUT_RELATIVE_PATH='log/check-cockpit-perf.log'
# The shell log: the focus lines the click steps provoke (the extension's console.warn), and what shell_log_faults
# reports: an error line of the extension (its prefixes beside a CRITICAL or ERROR mark: console.error is GLib's
# CRITICAL), a JS ERROR whose stack names the extension within JS_ERROR_STACK_LINES lines, Clutter's warnings from a
# reparenting, and Mutter's from an activation with no timestamp.
readonly EXTENSION_LOG_PREFIX='resource-pulse:'
readonly COCKPIT_LOG_PREFIX='cockpit:'
readonly FOCUS_LOG_PREFIX="$EXTENSION_LOG_PREFIX $COCKPIT_LOG_PREFIX focus:"
readonly NO_WINDOW_LOG_NEEDLE="$FOCUS_LOG_PREFIX no window for pids"
readonly NOT_FOCUSED_LOG_NEEDLE="$FOCUS_LOG_PREFIX $HERDR_UNREACHABLE_CODE"
readonly JS_ERROR_STACK_LINES=30
readonly EXTENSION_LOG_FAULT_KIND='extension'
readonly CLUTTER_LOG_FAULT_KIND='clutter'
readonly MUTTER_LOG_FAULT_KIND='mutter'
readonly SHOWN_LOG_FAULTS_LIMIT=5

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
# The parent's pid (field 4), counted the same way.
readonly STAT_PARENT_INDEX_AFTER_COMM=1
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
# What start_nested_service adds to the environment of the one service it starts next (NAME=value words), set and
# cleared by start_nested_cockpit around its call: the fixture's variable reaches the cockpit service alone.
NEXT_SERVICE_ENVIRONMENT_ASSIGNMENTS=()
# window, pointer and check cockpit: the run's verified private bus they ask over, the run and the gjs check cockpit
# opens windows with; what ask_nested kept of the last answer; the window open_probe_window started last; the row
# point_at_session_row pointed at; check cockpit's two windows; and its step counts and the step being collected.
CHECK_ADDRESS=""
CHECK_RUN_DIR=""
CHECK_GJS_PATH=""
CHECK_ANSWER=""
CHECK_VERDICT=""
CHECK_DETAIL=""
OPENED_WINDOW_PID=""
CHECK_ROW_TOOLTIP_TEXT=""
CHECK_PROBE_PID=""
CHECK_DECOY_PID=""
CHECK_OK_STEP_COUNT=0
CHECK_BAD_STEP_COUNT=0
CHECK_UNJUDGED_STEP_COUNT=0
STEP_BAD_DETAILS=()
STEP_UNJUDGED_DETAILS=()
# This pass of check cockpit in its run (begin_check_pass): its number, and the shell log's byte offset its log steps
# judge from.
CHECK_PASS_NUMBER=0
CHECK_LOG_START_OFFSET=0
# Set when the run's fixture could not be put back: the next step (or the one under way) could not be judged.
CHECK_FIXTURE_NOT_RESTORED_NOTE=""
# check cockpit's perf pass while it runs in the background (end_check_perf ends it on a signal).
CHECK_PERF_PID=""
# The window perf opened over the card, by pid and start time (end_perf_window ends only that process, and only
# while it is still perf's own child); the start time stays empty when it could not be read.
PERF_WINDOW_PID=""
PERF_WINDOW_STARTTIME=""
# The run's verified private bus, once perf has it: what end_perf_run restores the run over.
PERF_ADDRESS=""
# The window's --cpu-percent job, while it runs in the background of a measurement (end_perf_cost_job ends it).
PERF_COST_JOB_PID=""
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
# Each enabled state's grid record for perf_cockpit_verdict, "<redirects> <armed fallbacks>", in the same order.
PERF_COCKPIT_STATE_RECORDS=()

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
       scripts/resource-pulse-nested.sh window <title>
       scripts/resource-pulse-nested.sh pointer <x> <y> [click]
       scripts/resource-pulse-nested.sh check cockpit
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
# service (which only --replay starts), the cockpit's config template in the
# run's config home, and the cockpit's fixture (write_run_cockpit_fixture), its
# interval the run's lifetime.
# Arguments:
#   $1 - run directory (exists, empty, 0700)
#   $2 - run suffix
#   $3 - the run's lifetime, in seconds (DEFAULT_LIFETIME_SECONDS when not given)
#######################################
prepare_run_directory() {
    local run_dir="$1" run_suffix="$2" lifetime_seconds="${3:-$DEFAULT_LIFETIME_SECONDS}" replay_file_name now_usec
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
    now_usec="$(current_time_usec)" || return 1
    write_run_cockpit_fixture "$run_dir" "$lifetime_seconds" "$now_usec"
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
# Print the wall clock now in microseconds since the epoch, from bash's own
# EPOCHREALTIME (its decimal separator, whatever the locale's, dropped); fail
# unless that is sixteen digits.
#######################################
current_time_usec() {
    local time_usec="${EPOCHREALTIME//[!0-9]/}"
    [[ "$time_usec" =~ $TIME_USEC_PATTERN ]] || return 1
    printf '%s' "$time_usec"
}

#######################################
# Write the run's cockpit fixture, which the cockpit service serves in fixture
# mode: the checkout's nested-state.json with every source's stamp set to now
# and its interval to the run's lifetime (a source is stale only past three
# intervals, so none goes stale within the run), and no window candidates
# (`window` names its window there). A copy of it as written stays beside it,
# for the check's steps to restore; the checkout's file is never written. The
# fixture's path is recorded in state/run.values (cockpit-fixture=).
# Arguments:
#   $1 - run directory
#   $2 - the run's lifetime, in seconds
#   $3 - now, in microseconds since the epoch
#######################################
write_run_cockpit_fixture() {
    local run_dir="$1" lifetime_seconds="$2" now_usec="$3"
    local fixture_path="$run_dir/$COCKPIT_FIXTURE_RELATIVE_PATH"
    local start_copy_path="$run_dir/$COCKPIT_FIXTURE_START_RELATIVE_PATH"
    (umask "$PRIVATE_UMASK" && jq --argjson now_usec "$now_usec" --argjson interval_seconds "$lifetime_seconds" \
        "$COCKPIT_FIXTURE_FRESH_JQ" "$COCKPIT_FIXTURE_TEMPLATE" >"$start_copy_path") || return 1
    cp -- "$start_copy_path" "$fixture_path" || return 1
    record_run_value "$run_dir" "$COCKPIT_FIXTURE_RUN_VALUE_NAME" "$fixture_path"
}

#######################################
# Succeed when the run's cockpit service serves the run's own fixture: the
# fixture recorded is the run's, and it exists. In fixture mode the service
# never asks herdr (service/cockpit.js _startFixture builds no herdr client),
# so a click on a session row can move no pane.
# Arguments:
#   $1 - run directory
#######################################
is_cockpit_fixture_run() {
    local run_dir="$1"
    [[ "$(recorded_run_value "$run_dir" "$COCKPIT_FIXTURE_RUN_VALUE_NAME")" == "$run_dir/$COCKPIT_FIXTURE_RELATIVE_PATH" &&
        -f "$run_dir/$COCKPIT_FIXTURE_RELATIVE_PATH" ]]
}

#######################################
# Replace the run's cockpit fixture with a jq program's output, in one rename,
# so the cockpit service (which reads it again on change) never reads it half
# written. A program that fails leaves it as it was.
# Arguments:
#   $1 - run directory
#   $2 - jq program
#   $@ - jq's own arguments (--argjson name value ...)
#######################################
replace_run_cockpit_fixture() {
    local run_dir="$1" jq_program="$2" fixture_path staging_path
    shift 2
    fixture_path="$run_dir/$COCKPIT_FIXTURE_RELATIVE_PATH"
    staging_path="$(mktemp "$fixture_path.XXXXXX")" || return 1
    if ! jq "$@" "$jq_program" "$fixture_path" >"$staging_path" || ! mv -f -- "$staging_path" "$fixture_path"; then
        rm -f -- "$staging_path"
        return 1
    fi
}

#######################################
# Put the run's cockpit fixture back as start wrote it, in one rename.
# Arguments:
#   $1 - run directory
#######################################
restore_run_cockpit_fixture() {
    local run_dir="$1" staging_path
    staging_path="$(mktemp "$run_dir/$COCKPIT_FIXTURE_RELATIVE_PATH.XXXXXX")" || return 1
    if ! cp -- "$run_dir/$COCKPIT_FIXTURE_START_RELATIVE_PATH" "$staging_path" ||
        ! mv -f -- "$staging_path" "$run_dir/$COCKPIT_FIXTURE_RELATIVE_PATH"; then
        rm -f -- "$staging_path"
        return 1
    fi
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
# The supervisor's exit: end the windows `window` opened, then every process
# left in its session (SIGTERM, then SIGKILL after a grace), whatever ended the
# run, and mark the run ended, so looking for a live run never finds it.
# Arguments:
#   $1 - run directory
#   $2 - session id
#######################################
end_supervised_session() {
    local run_dir="$1" session_id="$2" ended_at
    end_recorded_windows "$run_dir"
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
# It gets NEXT_SERVICE_ENVIRONMENT_ASSIGNMENTS on top (env execs gjs in place, so
# the pid recorded is the service's).
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
    env "${NEXT_SERVICE_ENVIRONMENT_ASSIGNMENTS[@]}" gjs -m "$run_dir/$main_relative_path" "$@" \
        >"$run_dir/$log_relative_path" 2>&1 &
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
# Start the run's copy of the cockpit service in fixture mode: with
# COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE naming the run's fixture, which only
# this service's environment gets (never this stage's, which becomes
# gnome-shell). Refuses the run when start wrote no fixture.
# Arguments:
#   $1 - run directory
#######################################
start_nested_cockpit() {
    local run_dir="$1"
    is_cockpit_fixture_run "$run_dir" || refuse_run "$run_dir" "no cockpit fixture was written for the run"
    NEXT_SERVICE_ENVIRONMENT_ASSIGNMENTS=("$COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE=$run_dir/$COCKPIT_FIXTURE_RELATIVE_PATH")
    start_nested_service "$run_dir" cockpit "$COCKPIT_MAIN_RELATIVE_PATH" "$COCKPIT_BUS_NAME"
    NEXT_SERVICE_ENVIRONMENT_ASSIGNMENTS=()
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
# the cockpit service in fixture mode, record the bus, then become gnome-shell (same pid), with
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
    start_nested_cockpit "$run_dir"
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
    if ! prepare_run_directory "$run_dir" "$run_suffix" "$lifetime_seconds" ||
        ! verified_run_suffix "$run_dir" >/dev/null; then
        rm -rf -- "$run_dir"
        die "could not lay out the run directory (its cockpit fixture included)"
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
# Stop a run: end the windows `window` opened (end_recorded_windows: they run
# outside the run's session), SIGTERM the nested gnome-shell and the two services by their
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
    end_recorded_windows "$run_dir"
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
# hidden, no top-bar paint; and the card's offscreen redirect ALWAYS. The
# disabled state itself has one absolute bound: at most
# PERF_MAX_DISABLED_MAJOR_COLLECTIONS major collections, so that a defect that
# outlives disable() cannot hide in the state the others are measured against.
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
    local disabled_major_collections="${1:-}" disabled_frames="${2:-}" state_index state_name breach listed_breach
    local major_collections frames samples topbar_paints card_redirect joined_breaches budget_noun unjudgeable_reason
    local major_collections_limit frames_limit covered_idle_frames_limit
    local expected_argument_count=$(( 2 + ${#PERF_ENABLED_STATE_NAMES[@]} ))
    local -a enabled_records=("${@:3}") record_words breaches=()
    if (( $# != expected_argument_count )); then
        unjudgeable_reason="wanted the disabled state's two counts and a record per enabled state"
        print_unjudgeable_counts "$unjudgeable_reason ($expected_argument_count arguments), got $#"
        return "$EXIT_REFUSED"
    fi
    if ! are_counts "$disabled_major_collections" "$disabled_frames"; then
        unjudgeable_reason="the disabled state's counts are not whole numbers"
        print_unjudgeable_counts "$unjudgeable_reason: '$disabled_major_collections' '$disabled_frames'"
        return "$EXIT_REFUSED"
    fi
    # Every record is checked before any is judged: a count that cannot be trusted voids the run, breaches included.
    for state_index in "${!PERF_ENABLED_STATE_NAMES[@]}"; do
        state_name="${PERF_ENABLED_STATE_NAMES[state_index]}"
        read -r -a record_words <<<"${enabled_records[state_index]}"
        if (( ${#record_words[@]} != PERF_ENABLED_RECORD_WORD_COUNT )) || ! are_counts "${record_words[@]:0:4}"
        then
            unjudgeable_reason="$state_name's record is not four whole numbers and the card's redirect"
            print_unjudgeable_counts "$unjudgeable_reason: '${enabled_records[state_index]}'"
            return "$EXIT_REFUSED"
        fi
        if [[ "$state_name" == "$PERF_VISIBLE_BUSY_STATE" ]] &&
            (( record_words[1] == 0 || record_words[2] == 0 || record_words[3] == 0 )); then
            unjudgeable_reason="the probe counted no frame, Sample or top-bar paint in $state_name,"
            print_unjudgeable_counts "$unjudgeable_reason where each must happen: it is not counting"
            return "$EXIT_REFUSED"
        fi
    done
    if (( disabled_major_collections > PERF_MAX_DISABLED_MAJOR_COLLECTIONS )); then
        breach="disabled-collections: $PERF_DISABLED_STATE had $disabled_major_collections major collections,"
        breach+=" more than $PERF_MAX_DISABLED_MAJOR_COLLECTIONS: something outlives disable(), or the run is not idle"
        breaches+=("$breach")
    fi
    major_collections_limit=$(( disabled_major_collections + PERF_MAJOR_COLLECTIONS_ALLOWANCE ))
    covered_idle_frames_limit=$(( disabled_frames + PERF_COVERED_IDLE_FRAMES_ALLOWANCE ))
    for state_index in "${!PERF_ENABLED_STATE_NAMES[@]}"; do
        state_name="${PERF_ENABLED_STATE_NAMES[state_index]}"
        read -r major_collections frames samples topbar_paints card_redirect <<<"${enabled_records[state_index]}"
        frames_limit=$(( samples + disabled_frames + PERF_FRAMES_OVER_SAMPLES_ALLOWANCE ))
        if (( major_collections > major_collections_limit )); then
            breach="collections: $state_name had $major_collections major collections,"
            breach+=" more than the disabled state's $disabled_major_collections plus $PERF_MAJOR_COLLECTIONS_ALLOWANCE"
            breaches+=("$breach")
        fi
        if (( frames > frames_limit )); then
            breach="frames-per-sample: $state_name drew $frames frames, more than its $samples Samples"
            breach+=" plus the disabled state's $disabled_frames frames plus $PERF_FRAMES_OVER_SAMPLES_ALLOWANCE"
            breaches+=("$breach")
        fi
        if [[ "$state_name" == "$PERF_COVERED_IDLE_STATE" ]] && (( frames > covered_idle_frames_limit )); then
            breach="covered-idle-frames: $state_name drew $frames frames,"
            breach+=" more than the disabled state's $disabled_frames frames plus $PERF_COVERED_IDLE_FRAMES_ALLOWANCE"
            breaches+=("$breach")
        fi
        if [[ "$state_name" == "$PERF_TOPBAR_HIDDEN_STATE" ]] &&
            (( topbar_paints > PERF_HIDDEN_TOPBAR_PAINTS_ALLOWED )); then
            breach="hidden-topbar-paints: $state_name painted the top bar while it was hidden"
            breach+=" (top-bar paints $topbar_paints, allowed $PERF_HIDDEN_TOPBAR_PAINTS_ALLOWED)"
            breaches+=("$breach")
        fi
        if [[ "$card_redirect" != "$PERF_WANTED_CARD_REDIRECT" ]]; then
            breach="card-redirect: $state_name found the card's offscreen redirect $card_redirect,"
            breach+=" not $PERF_WANTED_CARD_REDIRECT"
            breaches+=("$breach")
        fi
    done
    if (( ${#breaches[@]} == 0 )); then
        printf 'perf: PASS: every count within its budget\n'
        return 0
    fi
    joined_breaches="${breaches[0]}"
    for listed_breach in "${breaches[@]:1}"; do
        joined_breaches+="; $listed_breach"
    done
    budget_noun='budgets'
    (( ${#breaches[@]} == 1 )) && budget_noun='budget'
    printf 'perf: FAIL: %s count %s broken: %s\n' "${#breaches[@]}" "$budget_noun" "$joined_breaches"
    return "$EXIT_REQUEST_FAILED"
}

#######################################
# Succeed when an enabled state was set up as it is named, from the probe's two
# facts read at the end of its window: the card covered (not visible) in the
# covered states and visible in visible-busy; the top bar indicator unmapped
# in topbar-hidden-covered and mapped in every other. Otherwise print why,
# naming the state and what was expected, and return 2: a window that did not
# maximize or minimize, or a top bar not hidden or not shown again, would
# report its counts under the wrong name, so the state could not be measured,
# which is neither a pass nor a breach. Pure: it reads no file and starts
# nothing.
# Arguments:
#   $1 - state name (one of PERF_ENABLED_STATE_NAMES)
#   $2 - whether the card counts as visible: true or false
#   $3 - whether the indicator is mapped: true or false
# Returns:
#   0 set up as named; 2 not, a fact that is not true or false, or a name that
#   is not an enabled state's
#######################################
check_perf_state_setup() {
    local state_name="$1" is_card_visible="$2" is_indicator_mapped="$3" expected_indicator_mapped=true
    local indicator_mismatch='expected the top bar indicator mapped (shown), and it is unmapped'
    local joined_mismatches listed_mismatch
    local not_set_up_lead="perf: could not measure $state_name: it was not set up as named:"
    local facts_text="card visible '$is_card_visible', indicator mapped '$is_indicator_mapped'"
    local -a mismatches=()
    case "$state_name" in
        "$PERF_COVERED_IDLE_STATE" | "$PERF_COVERED_BUSY_STATE" | "$PERF_TOPBAR_HIDDEN_STATE" | \
            "$PERF_VISIBLE_BUSY_STATE") ;;
        *)
            printf "perf: could not measure '%s': not an enabled state\n" "$state_name"
            return "$EXIT_REFUSED" ;;
    esac
    if [[ ! "$is_card_visible" =~ $PERF_FACT_PATTERN || ! "$is_indicator_mapped" =~ $PERF_FACT_PATTERN ]]; then
        printf "perf: could not measure %s: the probe's facts are not true or false: %s\n" "$state_name" "$facts_text"
        return "$EXIT_REFUSED"
    fi
    # The covered states: perf's window, maximized, covers the card.
    if [[ "$state_name" != "$PERF_VISIBLE_BUSY_STATE" && "$is_card_visible" != false ]]; then
        mismatches+=("expected the card covered (not visible), and it counts as visible")
    fi
    # visible-busy: that window minimized, the card can be seen.
    if [[ "$state_name" == "$PERF_VISIBLE_BUSY_STATE" && "$is_card_visible" != true ]]; then
        mismatches+=("expected the card visible, and it counts as covered")
    fi
    # The top bar: hidden only in topbar-hidden-covered, and shown again before visible-busy.
    if [[ "$state_name" == "$PERF_TOPBAR_HIDDEN_STATE" ]]; then
        expected_indicator_mapped=false
        indicator_mismatch='expected the top bar indicator unmapped (hidden), and it is mapped'
    fi
    if [[ "$is_indicator_mapped" != "$expected_indicator_mapped" ]]; then
        mismatches+=("$indicator_mismatch")
    fi
    (( ${#mismatches[@]} == 0 )) && return 0
    joined_mismatches="${mismatches[0]}"
    for listed_mismatch in "${mismatches[@]:1}"; do
        joined_mismatches+="; $listed_mismatch"
    done
    printf '%s %s\n' "$not_set_up_lead" "$joined_mismatches"
    return "$EXIT_REFUSED"
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
# Succeed only when the probe's answer shows that the request ran: a JSON
# object, no refusal, and the mode it attached in (attach-disabled,
# attach-enabled: .attached) or read in (read, read-cockpit: .mode) the one
# expected. An empty answer, null, an object without that sign or with another
# mode (a completion value lost on the way, or a probe that did not run as
# asked) is not taken for success, so it fails here and not nine minutes later
# at the verdict. Says why on stderr.
# Arguments:
#   $1 - request (attach-disabled, attach-enabled, read, read-cockpit)
#   $2 - the mode the answer must show (disabled, enabled)
#   $3 - the probe's answer
#######################################
is_successful_perf_probe_answer() {
    local probe_request="$1" expected_mode="$2" probe_answer="$3" probe_refusal answered_mode
    local success_key="$PERF_PROBE_ATTACHED_KEY"
    if [[ "$probe_request" == "$PERF_PROBE_READ_REQUEST" || "$probe_request" == "$PERF_PROBE_READ_COCKPIT_REQUEST" ]]
    then
        success_key="$PERF_PROBE_MODE_KEY"
    fi
    if ! probe_refusal="$(jq -r '.refused // empty' <<<"$probe_answer" 2>/dev/null)"; then
        note "the in-shell probe's answer to $probe_request is not a JSON object: '$probe_answer'"
        return 1
    fi
    if [[ -n "$probe_refusal" ]]; then
        note "the in-shell probe refused $probe_request: $probe_refusal"
        return 1
    fi
    answered_mode="$(jq -r --arg success_key "$success_key" '.[$success_key] // empty' <<<"$probe_answer")"
    if [[ "$answered_mode" != "$expected_mode" ]]; then
        note "the in-shell probe's answer to $probe_request shows no sign that it ran" \
            "($success_key is '$answered_mode', not '$expected_mode'): '$probe_answer'"
        return 1
    fi
}

#######################################
# Print the in-shell probe's JSON answer to one request: perf-probe.js's text,
# then one call of its function, through Eval. Exit 2 when the call fails, the
# probe throws or refuses, or its answer shows no sign that it ran in the mode
# expected (is_successful_perf_probe_answer): it never attaches to nothing.
# Arguments:
#   $1 - verified private bus address
#   $2 - request (attach-disabled, attach-enabled, read)
#   $3 - the mode the answer must show (disabled, enabled)
#######################################
run_perf_probe() {
    local address="$1" probe_request="$2" expected_mode="$3" probe_source probe_call probe_code probe_answer
    probe_source="$(<"$PERF_PROBE_PATH")" || die "cannot read $PERF_PROBE_PATH"
    probe_call="$PERF_PROBE_FUNCTION_NAME('$probe_request');"
    probe_code="$probe_source"$'\n'"$probe_call"
    probe_answer="$(eval_in_nested_shell "$address" "$probe_code")" \
        || die "the in-shell probe's $probe_request did not run"
    is_successful_perf_probe_answer "$probe_request" "$expected_mode" "$probe_answer" || exit "$EXIT_REFUSED"
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
# Print one true-or-false field of the probe's JSON answer, or nothing when it
# has none or it is not a boolean (jq's // would print nothing for false, so
# perf_probe_answer_field cannot read one).
# Arguments:
#   $1 - the probe's answer
#   $2 - field name
#######################################
perf_probe_answer_boolean() {
    jq -r --arg field_name "$2" '.[$field_name] | select(type == "boolean")' <<<"$1"
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
# Succeed while a pid is a running child of this shell: what perf started in
# the background and has not reaped. A pid reused by any other process has
# another parent.
# Arguments:
#   $1 - pid
#######################################
is_own_child_process() {
    [[ "$1" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]] || return 1
    read_stat_fields /proc "$1" || return 1
    [[ "${STAT_FIELDS_AFTER_COMM[$STAT_PARENT_INDEX_AFTER_COMM]:-}" == "$$" ]]
}

#######################################
# Succeed while the window perf started is still the process it recorded: its
# own child, with the start time recorded at launch (when that could be read).
#######################################
is_perf_window_running() {
    is_own_child_process "$PERF_WINDOW_PID" || return 1
    [[ -z "$PERF_WINDOW_STARTTIME" ||
        "$(starttime_of_process /proc "$PERF_WINDOW_PID")" == "$PERF_WINDOW_STARTTIME" ]]
}

#######################################
# End the window perf started, only while it is still that process (also when
# its start time could not be read: then by the pid recorded at launch, which
# must still be perf's own child).
#######################################
end_perf_window() {
    is_perf_window_running && kill -TERM "$PERF_WINDOW_PID" 2>/dev/null
    return 0
}

#######################################
# End a window's background --cpu-percent job, only while it is still perf's
# own child.
#######################################
end_perf_cost_job() {
    is_own_child_process "$PERF_COST_JOB_PID" && kill -TERM "$PERF_COST_JOB_PID" 2>/dev/null
    return 0
}

#######################################
# Put the nested run's extension back as perf found it, over the run's verified
# private bus (nothing before perf has one): enabled, then its indicator shown.
# Each step runs whatever the one before did, and a failure is only reported.
#######################################
restore_perf_extension() {
    [[ -n "$PERF_ADDRESS" ]] || return 0
    eval_in_nested_shell "$PERF_ADDRESS" "$PERF_RESTORE_EXTENSION_JS" >/dev/null \
        || note "perf could not enable the extension again in the nested shell"
    eval_in_nested_shell "$PERF_ADDRESS" "$PERF_RESTORE_TOPBAR_JS" >/dev/null \
        || note "perf could not show the top bar again in the nested shell"
    return 0
}

#######################################
# perf's exit, on every path once it has started acting on the run (the EXIT
# trap): end the window it opened and its background measurement job, then
# enable the extension and show the top bar again. Each step is guarded, so one
# that fails never skips the others, and none exits: it acts on the nested run
# and perf's own children only.
#######################################
end_perf_run() {
    end_perf_window
    end_perf_cost_job
    restore_perf_extension
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
    local run_dir="$1" shell_pid="$2" window_start_offset
    local shell_log_path="$run_dir/log/shell.log" cpu_percent_path="$run_dir/$PERF_CPU_PERCENT_RELATIVE_PATH"
    local -a cost_command=(env "GNOME_SHELL_PID=$shell_pid" PROC_ROOT=/proc bash "$COST_SCRIPT_PATH")
    window_start_offset="$(stat -c %s "$shell_log_path")" || die "cannot read the size of $shell_log_path"
    "${cost_command[@]}" --cpu-percent "$PERF_WINDOW_SECONDS" >"$cpu_percent_path" &
    # Kept where perf's exit finds it: a failure below, or a signal, ends the job (end_perf_cost_job).
    PERF_COST_JOB_PID=$!
    if ! PERF_WINDOW_TICK_MEDIAN_MS="$("${cost_command[@]}" --tick-median "$PERF_WINDOW_SECONDS")"; then
        die "the cost script could not read the nested shell's main thread"
    fi
    wait "$PERF_COST_JOB_PID" || die "the cost script could not read the nested shell's CPU"
    PERF_COST_JOB_PID=""
    PERF_WINDOW_CPU_PERCENT="$(<"$cpu_percent_path")"
    PERF_WINDOW_MAJOR_COLLECTIONS="$(count_major_collections_since "$shell_log_path" "$window_start_offset" \
        "$shell_pid")" || die "cannot count the collections in $shell_log_path"
}

#######################################
# Keep and print one state's readings: the window's (measure_perf_window) and
# the probe's read. The disabled state's are kept for the others, with its
# Samples counted by time (no client); an enabled state's record is appended to
# PERF_ENABLED_STATE_RECORDS, and its CPU reported over the disabled state's,
# once the probe's facts show it set up as it is named (check_perf_state_setup):
# exit 2 otherwise, with nothing kept or printed under its name.
# Arguments:
#   $1 - state name
#   $2 - the probe's answer to read
#######################################
record_perf_state() {
    local state_name="$1" probe_answer="$2" frames samples topbar_paints card_redirect cpu_over_disabled
    local samples_by_time cpu_report is_card_visible is_indicator_mapped
    local state_line_format='%s: cpu=%s tick-median=%sms major-collections=%s'
    state_line_format+=' frames=%s samples=%s top-bar-paints=%s card-redirect=%s\n'
    frames="$(perf_probe_answer_field "$probe_answer" frames)"
    if [[ "$state_name" == "$PERF_DISABLED_STATE" ]]; then
        PERF_DISABLED_MAJOR_COLLECTIONS="$PERF_WINDOW_MAJOR_COLLECTIONS"
        PERF_DISABLED_FRAMES="$frames"
        PERF_DISABLED_CPU_PERCENT="$PERF_WINDOW_CPU_PERCENT"
        samples_by_time=$(( PERF_WINDOW_SECONDS / PERF_SAMPLE_INTERVAL_SECONDS ))
        # shellcheck disable=SC2059  # The format is the two literals above, split only for the line's length.
        printf "$state_line_format" "$state_name" "$PERF_WINDOW_CPU_PERCENT%" "$PERF_WINDOW_TICK_MEDIAN_MS" \
            "$PERF_WINDOW_MAJOR_COLLECTIONS" "$frames" "$samples_by_time (by time: no client while disabled)" - -
        return 0
    fi
    is_card_visible="$(perf_probe_answer_boolean "$probe_answer" "$PERF_CARD_VISIBLE_FIELD")"
    is_indicator_mapped="$(perf_probe_answer_boolean "$probe_answer" "$PERF_INDICATOR_MAPPED_FIELD")"
    check_perf_state_setup "$state_name" "$is_card_visible" "$is_indicator_mapped" || exit "$EXIT_REFUSED"
    samples="$(perf_probe_answer_field "$probe_answer" samples)"
    topbar_paints="$(perf_probe_answer_field "$probe_answer" topbarPaints)"
    card_redirect="$(perf_probe_answer_field "$probe_answer" cardRedirect)"
    PERF_ENABLED_STATE_RECORDS+=("$PERF_WINDOW_MAJOR_COLLECTIONS $frames $samples $topbar_paints $card_redirect")
    cpu_over_disabled="$(awk -v state_percent="$PERF_WINDOW_CPU_PERCENT" \
        -v disabled_percent="$PERF_DISABLED_CPU_PERCENT" 'BEGIN { printf "%+.3f", state_percent - disabled_percent }')"
    cpu_report="$PERF_WINDOW_CPU_PERCENT% ($cpu_over_disabled over disabled)"
    # shellcheck disable=SC2059  # The format is the two literals above, split only for the line's length.
    printf "$state_line_format" "$state_name" "$cpu_report" "$PERF_WINDOW_TICK_MEDIAN_MS" \
        "$PERF_WINDOW_MAJOR_COLLECTIONS" "$frames" "$samples" "$topbar_paints" "$card_redirect"
}

#######################################
# Succeed when an enabled state's grid was set up as it is named, from the
# probe's read-cockpit words: in every enabled state the layer draws the cards
# the run's fixture lays out (PERF_FIXTURE_GRID_CARD_IDS_WORD: no layer is no
# grid, never a grid that passes); in the covered states no card of it can be
# seen; in visible-busy every one can. Otherwise print why, naming the state
# and what was expected, and return 2, as check_perf_state_setup does. Pure.
# Arguments:
#   $1 - state name (one of PERF_ENABLED_STATE_NAMES)
#   $2 - the ids that can be seen, as one word (PERF_NONE_WORD for none)
#   $3 - the ids the layer draws, as one word, or PERF_NO_GRID_WORD
# Returns:
#   0 set up as named; 2 not, or a name that is not an enabled state's
#######################################
check_perf_cockpit_setup() {
    local state_name="$1" visible_word="$2" grid_word="$3" mismatch
    local not_set_up_lead="perf: could not measure $state_name: it was not set up as named:"
    case "$state_name" in
        "$PERF_COVERED_IDLE_STATE" | "$PERF_COVERED_BUSY_STATE" | "$PERF_TOPBAR_HIDDEN_STATE" | \
            "$PERF_VISIBLE_BUSY_STATE") ;;
        *)
            printf "perf: could not measure '%s': not an enabled state\n" "$state_name"
            return "$EXIT_REFUSED" ;;
    esac
    if [[ "$grid_word" != "$PERF_FIXTURE_GRID_CARD_IDS_WORD" ]]; then
        mismatch="expected the layer to draw the fixture's cards ($PERF_FIXTURE_GRID_CARD_IDS_WORD), and"
        if [[ "$grid_word" == "$PERF_NO_GRID_WORD" ]]; then
            mismatch+=" there is no layer: no grid is drawn"
        else
            mismatch+=" it draws $grid_word"
        fi
    elif [[ "$state_name" != "$PERF_VISIBLE_BUSY_STATE" ]]; then
        # The covered states: perf's window, maximized over the work area the grid fills, covers every card.
        [[ "$visible_word" == "$PERF_NONE_WORD" ]] && return 0
        mismatch="expected no card of the grid visible, and $visible_word can be seen"
    else
        [[ "$visible_word" == "$grid_word" ]] && return 0
        mismatch="expected every card it draws visible ($grid_word), and"
        if [[ "$visible_word" == "$PERF_NONE_WORD" ]]; then
            mismatch+=" none can be seen"
        else
            mismatch+=" only $visible_word can be seen"
        fi
    fi
    printf '%s %s\n' "$not_set_up_lead" "$mismatch"
    return "$EXIT_REFUSED"
}

#######################################
# Keep and print one enabled state's grid facts, from the probe's read-cockpit
# answer, once they show the grid set up as the state is named
# (check_perf_cockpit_setup): its record is appended to
# PERF_COCKPIT_STATE_RECORDS. Exit 2 when the facts are not of their types (or
# a name is not one plain word), or the grid was not set up as named, with
# nothing kept or printed under the state's name.
# Arguments:
#   $1 - state name (one of PERF_ENABLED_STATE_NAMES)
#   $2 - the probe's read-cockpit answer
#######################################
record_perf_cockpit_state() {
    local state_name="$1" probe_answer="$2" cockpit_words visible_word grid_word redirects_word timers_word
    cockpit_words="$(jq -r "$PERF_COCKPIT_WORDS_JQ" <<<"$probe_answer" 2>/dev/null)" || cockpit_words=""
    read -r visible_word grid_word redirects_word timers_word <<<"$cockpit_words"
    if [[ -z "$timers_word" ]]; then
        printf "perf: could not measure %s: the probe's cockpit facts are not of their types: '%s'\n" \
            "$state_name" "$probe_answer"
        exit "$EXIT_REFUSED"
    fi
    check_perf_cockpit_setup "$state_name" "$visible_word" "$grid_word" || exit "$EXIT_REFUSED"
    PERF_COCKPIT_STATE_RECORDS+=("$redirects_word $timers_word")
    printf '%s: grid visible-cards=%s drawn-cards=%s redirects=%s armed-fallbacks=%s\n' "$state_name" \
        "$visible_word" "$grid_word" "$redirects_word" "$timers_word"
}

#######################################
# Print the offscreen redirect ruling D12 wants for one part of the grid: none
# on the layer and the system cell's wrapper, ALWAYS on each data card; fail
# for a part it does not know.
# Arguments:
#   $1 - part (PERF_LAYER_REDIRECT_PART, or a card id)
#######################################
wanted_cockpit_redirect() {
    local part_name="$1" data_card_id
    case "$part_name" in
        "$PERF_LAYER_REDIRECT_PART") printf '%s' "$PERF_WANTED_LAYER_REDIRECT"; return 0 ;;
        "$PERF_V2_CARD_ID") printf '%s' "$PERF_WANTED_SYSTEM_WRAPPER_REDIRECT"; return 0 ;;
    esac
    for data_card_id in "${PERF_DATA_CARD_IDS[@]}"; do
        [[ "$part_name" == "$data_card_id" ]] && { printf '%s' "$PERF_WANTED_DATA_CARD_REDIRECT"; return 0; }
    done
    return 1
}

#######################################
# Print the line perf_cockpit_verdict prints for records it cannot judge.
# Arguments:
#   $1 - why
#######################################
print_unjudgeable_cockpit() {
    printf 'perf: could not judge the cockpit: %s\n' "$1"
}

#######################################
# Succeed when an enabled state's grid record can be judged: two words, the
# redirects "<part>:<name>" pairs of known parts that read every part of
# PERF_REDIRECT_PART_NAMES (no grid, PERF_NO_GRID_WORD, reads none). Otherwise
# print why (print_unjudgeable_cockpit) and fail.
# Arguments:
#   $1 - state name
#   $2 - its record
#######################################
is_judgeable_cockpit_record() {
    local state_name="$1" cockpit_record="$2" redirect_pair part_name
    local -a record_words redirect_pairs
    local -A is_part_read=()
    read -r -a record_words <<<"$cockpit_record"
    if (( ${#record_words[@]} != PERF_COCKPIT_RECORD_WORD_COUNT )); then
        print_unjudgeable_cockpit "$state_name's record is not the redirects and the armed fallbacks: '$cockpit_record'"
        return 1
    fi
    if [[ "${record_words[0]}" == "$PERF_NO_GRID_WORD" ]]; then
        print_unjudgeable_cockpit "$state_name drew no grid: there is no redirect to judge"
        return 1
    fi
    IFS=, read -r -a redirect_pairs <<<"${record_words[0]}"
    for redirect_pair in "${redirect_pairs[@]}"; do
        if [[ ! "$redirect_pair" =~ $PERF_REDIRECT_PAIR_PATTERN ]] ||
            ! wanted_cockpit_redirect "${redirect_pair%%:*}" >/dev/null; then
            print_unjudgeable_cockpit "$state_name's redirect '$redirect_pair' is not a known part and its redirect"
            return 1
        fi
        is_part_read["${redirect_pair%%:*}"]=1
    done
    for part_name in "${PERF_REDIRECT_PART_NAMES[@]}"; do
        if [[ -z "${is_part_read[$part_name]:-}" ]]; then
            print_unjudgeable_cockpit "$state_name's record reads no redirect for $part_name"
            return 1
        fi
    done
}

#######################################
# Judge a perf run's grid records and print one line: the pass, each broken
# budget by name, or why the records cannot be judged. Pure. In every enabled
# state the layer and the system cell's wrapper draw through no texture of
# their own and each data card through its own (ruling D12: a texture per cell,
# none nested), and no fallback timeout is armed: each is one-shot, armed only
# while a Changed waits with the sampler silent, or every card is covered with
# the service silent, and perf's Samples flow in every state.
# Arguments:
#   $@ - each enabled state's record, in PERF_ENABLED_STATE_NAMES's order:
#        "<redirects> <armed fallbacks>"
# Returns:
#   0 every budget held; 1 a budget broken; 2 the records cannot be judged: a
#   state missing, or a record it cannot read
#######################################
perf_cockpit_verdict() {
    local expected_record_count=${#PERF_ENABLED_STATE_NAMES[@]} state_index state_name redirects_word timers_word
    local redirect_pair part_name redirect_name wanted_redirect breach joined_breaches listed_breach budget_noun
    local -a cockpit_records=("$@") redirect_pairs breaches=()
    if (( $# != expected_record_count )); then
        print_unjudgeable_cockpit "wanted a grid record per enabled state ($expected_record_count), got $#"
        return "$EXIT_REFUSED"
    fi
    # Every record is checked before any is judged, as perf_count_verdict does.
    for state_index in "${!PERF_ENABLED_STATE_NAMES[@]}"; do
        is_judgeable_cockpit_record "${PERF_ENABLED_STATE_NAMES[state_index]}" "${cockpit_records[state_index]}" \
            || return "$EXIT_REFUSED"
    done
    for state_index in "${!PERF_ENABLED_STATE_NAMES[@]}"; do
        state_name="${PERF_ENABLED_STATE_NAMES[state_index]}"
        read -r redirects_word timers_word <<<"${cockpit_records[state_index]}"
        IFS=, read -r -a redirect_pairs <<<"$redirects_word"
        for redirect_pair in "${redirect_pairs[@]}"; do
            part_name="${redirect_pair%%:*}"
            redirect_name="${redirect_pair#*:}"
            wanted_redirect="$(wanted_cockpit_redirect "$part_name")"
            if [[ "$redirect_name" != "$wanted_redirect" ]]; then
                breach="cockpit-redirect: $state_name found $part_name's offscreen redirect $redirect_name,"
                breach+=" not $wanted_redirect"
                breaches+=("$breach")
            fi
        done
        if [[ "$timers_word" != "$PERF_NONE_WORD" ]]; then
            breach="fallback-timers: $state_name found $timers_word armed while Samples flowed: each is one-shot,"
            breach+=" armed only with the sampler silent"
            breaches+=("$breach")
        fi
    done
    if (( ${#breaches[@]} == 0 )); then
        printf "perf: cockpit: PASS: the grid's offscreen redirects as ruling D12 wants, and no fallback armed\n"
        return 0
    fi
    joined_breaches="${breaches[0]}"
    for listed_breach in "${breaches[@]:1}"; do
        joined_breaches+="; $listed_breach"
    done
    budget_noun='budgets'
    (( ${#breaches[@]} == 1 )) && budget_noun='budget'
    printf 'perf: cockpit: FAIL: %s cockpit %s broken: %s\n' "${#breaches[@]}" "$budget_noun" "$joined_breaches"
    return "$EXIT_REQUEST_FAILED"
}

#######################################
# Print the worse of two verdicts' statuses: a broken budget (1) before a
# verdict that could not judge (2), either before a pass (0). A breach found is
# a breach, whatever else could not be judged.
# Arguments:
#   $1 - one verdict's status
#   $2 - the other's
#######################################
worse_verdict_status() {
    if (( $1 == EXIT_REQUEST_FAILED || $2 == EXIT_REQUEST_FAILED )); then
        printf '%s' "$EXIT_REQUEST_FAILED"
    elif (( $1 != 0 || $2 != 0 )); then
        printf '%s' "$EXIT_REFUSED"
    else
        printf '0'
    fi
}

#######################################
# perf's end: the count verdict, then the cockpit verdict, each its own line,
# from the readings perf kept; returns the worse status (worse_verdict_status).
#######################################
judge_perf_run() {
    local count_status cockpit_status
    perf_count_verdict "$PERF_DISABLED_MAJOR_COLLECTIONS" "$PERF_DISABLED_FRAMES" "${PERF_ENABLED_STATE_RECORDS[@]}"
    count_status=$?
    perf_cockpit_verdict "${PERF_COCKPIT_STATE_RECORDS[@]}"
    cockpit_status=$?
    return "$(worse_verdict_status "$count_status" "$cockpit_status")"
}

#######################################
# Measure one state: request its scenario (so every run sees the same input),
# run its setup steps, wait PERF_WARM_UP_SECONDS, attach or reset the probe for
# it, measure one window with no eval running, read the probe, then keep and
# print the readings; for an enabled state, then read and keep the grid's
# facts too (read-cockpit), still after the window.
# Arguments:
#   $1 - run directory
#   $2 - verified private bus address
#   $3 - the nested shell's pid
#   $4 - state name
#   $5 - its scenario
#   $@ - its setup steps' JavaScript, in order
#######################################
measure_perf_state() {
    local run_dir="$1" address="$2" shell_pid="$3" state_name="$4" scenario_name="$5" setup_js cockpit_answer
    local attach_request="$PERF_PROBE_ATTACH_ENABLED_REQUEST" probe_mode="$PERF_PROBE_ENABLED_MODE" probe_answer
    local settling_note="$scenario_name input, $PERF_WARM_UP_SECONDS s to settle, then a $PERF_WINDOW_SECONDS s window"
    shift 5
    note "perf: $state_name: $settling_note"
    request_perf_scenario "$run_dir" "$scenario_name"
    for setup_js in "$@"; do
        run_perf_step "$address" "set up $state_name" "$setup_js"
    done
    sleep "$PERF_WARM_UP_SECONDS"
    if [[ "$state_name" == "$PERF_DISABLED_STATE" ]]; then
        attach_request="$PERF_PROBE_ATTACH_DISABLED_REQUEST"
        probe_mode="$PERF_PROBE_DISABLED_MODE"
    fi
    run_perf_probe "$address" "$attach_request" "$probe_mode" >/dev/null
    measure_perf_window "$run_dir" "$shell_pid"
    probe_answer="$(run_perf_probe "$address" "$PERF_PROBE_READ_REQUEST" "$probe_mode")" || exit "$EXIT_REFUSED"
    record_perf_state "$state_name" "$probe_answer"
    [[ "$state_name" == "$PERF_DISABLED_STATE" ]] && return 0
    cockpit_answer="$(run_perf_probe "$address" "$PERF_PROBE_READ_COCKPIT_REQUEST" "$probe_mode")" \
        || exit "$EXIT_REFUSED"
    record_perf_cockpit_state "$state_name" "$cockpit_answer"
}

#######################################
# `perf`: measure a live run started with --gc-log --replay against the count
# budgets (see the header). Refuses (exit 2) before anything runs in the nested
# shell unless the run is a verified, live run of this script started with
# both options, its replay service runs, gnome-calculator is on PATH and the
# shell's log holds a collection line of the recorded gnome-shell. Exits 2 at
# an enabled state the probe does not find set up as it is named, the grid's
# included. Returns judge_perf_run's status, the worse of the count verdict's
# and the cockpit verdict's: 0 within every budget, 1 a budget broken, 2 what
# could not be judged.
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
        || die "refusing: $run_dir/log/shell.log holds no collection line of the nested shell ($shell_pid):" \
            "is the GC log on?"

    window_count="$(eval_in_nested_shell "$address" "$PERF_COUNT_WINDOWS_JS")" || exit "$EXIT_REFUSED"
    [[ "$window_count" == 0 ]] \
        || die "refusing: the nested session already has $window_count window(s); perf covers the card with its own"
    # From here perf acts on the run: every exit, a failure, a breach or a signal included, puts it back.
    PERF_ADDRESS="$address"
    trap end_perf_run EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    start_perf_window "$run_dir" "$address" "$window_command_path"
    wait_for_perf_window "$address" || die "the $PERF_WINDOW_COMMAND_NAME window did not open (see $run_dir/log/)"

    header_line="perf: nested gnome-shell $shell_pid of $run_dir; each state: its scenario,"
    header_line+=" $PERF_WARM_UP_SECONDS s to settle, one $PERF_WINDOW_SECONDS s window with no eval running;"
    header_line+=" cpu is % of one core for the whole nested shell, the probe's own per-frame counting included,"
    header_line+=" reported and not gated; the counts are gated"
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
    judge_perf_run
    verdict_status=$?
    return "$verdict_status"
}

#######################################
# Print the shell log's faults past a byte offset, one per line, each led by
# its kind: an extension error (a line with the extension's or the cockpit's
# prefix and a CRITICAL or ERROR mark, or a JS ERROR whose stack names the
# extension within JS_ERROR_STACK_LINES lines), a Clutter warning from a
# reparenting ("already has a parent", "needs an allocation"), or a Mutter
# warning from an activation with no timestamp ("timestamp of 0", "This
# shouldn't happen", "META_CURRENT_TIME used to choose focus window",
# "last_user_time" with "more recent" or "greater than comparison timestamp").
# Only the kinds asked for. Fails when the
# log cannot be read: never no faults for a log it did not read.
# Arguments:
#   $1 - log path
#   $2 - the byte offset to read from
#   $3 - the kinds, comma-separated (extension, clutter, mutter)
#######################################
shell_log_faults() {
    local log_path="$1" start_offset="$2" fault_kinds="$3"
    [[ -r "$log_path" ]] || return 1
    tail -c "+$(( start_offset + 1 ))" "$log_path" | awk -v fault_kinds=",$fault_kinds," \
        -v extension_prefix="$EXTENSION_LOG_PREFIX" -v cockpit_prefix="$COCKPIT_LOG_PREFIX" \
        -v extension_uuid="$EXTENSION_UUID" -v stack_lines="$JS_ERROR_STACK_LINES" '
        function wants(kind) { return index(fault_kinds, "," kind ",") > 0 }
        function is_extension_error_line() {
            return (index($0, extension_prefix) || index($0, cockpit_prefix)) &&
                (index($0, "CRITICAL") || index($0, "ERROR"))
        }
        function is_clutter_warning_line() {
            return index($0, "already has a parent") || index($0, "needs an allocation")
        }
        function is_mutter_warning_line() {
            return index($0, "timestamp of 0") || index($0, "This shouldn\047t happen") ||
                index($0, "META_CURRENT_TIME used to choose focus window") ||
                (index($0, "last_user_time") &&
                    (index($0, "more recent") || index($0, "greater than comparison timestamp")))
        }
        index($0, "JS ERROR") {
            pending_js_error = $0
            stack_lines_left = stack_lines
            if (wants("extension") && index($0, extension_uuid)) { print "extension: " $0; pending_js_error = "" }
            next
        }
        stack_lines_left > 0 {
            stack_lines_left--
            if (wants("extension") && pending_js_error != "" && index($0, extension_uuid)) {
                print "extension: " pending_js_error
                pending_js_error = ""
            }
        }
        wants("extension") && is_extension_error_line() { print "extension: " $0; next }
        wants("clutter") && is_clutter_warning_line() { print "clutter: " $0; next }
        wants("mutter") && is_mutter_warning_line() { print "mutter: " $0; next }'
}

#######################################
# Print how many lines of the shell log past a byte offset hold a text.
# Arguments:
#   $1 - log path
#   $2 - the byte offset to read from
#   $3 - the text
#######################################
count_log_lines_since() {
    [[ -r "$1" ]] || return 1
    tail -c "+$(( $2 + 1 ))" "$1" | awk -v needle="$3" 'index($0, needle) { line_count++ } END { print line_count + 0 }'
}

#######################################
# Print the shell log's size in bytes: the offset a later read starts from.
#######################################
check_shell_log_offset() {
    stat -c %s "$CHECK_RUN_DIR/log/shell.log" 2>/dev/null || printf '0'
}

#######################################
# Run one request of an in-shell file in the nested shell and print its JSON
# answer: the file's text, then one call of its function with the request and
# its options, through Eval.
# Arguments:
#   $1 - verified private bus address
#   $2 - the file (COCKPIT_CHECK_PATH or POINTER_SCRIPT_PATH)
#   $3 - the function it declares
#   $4 - request
#   $5 - options, as one JSON object
#######################################
run_nested_request() {
    local address="$1" script_path="$2" function_name="$3" request="$4" options_json="$5" script_text
    script_text="$(<"$script_path")" || return "$EXIT_REFUSED"
    eval_in_nested_shell "$address" "$script_text"$'\n'"$function_name('$request', $options_json);"
}

#######################################
# Ask the nested shell one request of an in-shell file, on the run check
# cockpit, window or pointer acts on (CHECK_ADDRESS), and keep its answer:
# CHECK_ANSWER, CHECK_VERDICT and CHECK_DETAIL. An Eval that failed, or an
# answer with no verdict it knows, is could-not-judge.
# Arguments:
#   $1 - the file
#   $2 - the function it declares
#   $3 - request
#   $4 - options, as one JSON object (default {})
#######################################
ask_nested() {
    local script_path="$1" function_name="$2" request="$3" options_json="${4:-}"
    [[ -n "$options_json" ]] || options_json='{}'
    if ! CHECK_ANSWER="$(run_nested_request "$CHECK_ADDRESS" "$script_path" "$function_name" "$request" \
        "$options_json")"; then
        CHECK_VERDICT="$CHECK_COULD_NOT_JUDGE_VERDICT"
        CHECK_DETAIL="the nested shell did not answer $request (see above)"
        return 0
    fi
    CHECK_VERDICT="$(jq -r '.verdict // empty' <<<"$CHECK_ANSWER" 2>/dev/null)"
    CHECK_DETAIL="$(jq -r '.detail // empty' <<<"$CHECK_ANSWER" 2>/dev/null)"
    case "$CHECK_VERDICT" in
        "$CHECK_OK_VERDICT" | "$CHECK_BAD_VERDICT" | "$CHECK_PENDING_VERDICT" | "$CHECK_COULD_NOT_JUDGE_VERDICT") ;;
        *)
            CHECK_VERDICT="$CHECK_COULD_NOT_JUDGE_VERDICT"
            CHECK_DETAIL="no verdict in the answer to $request: '$CHECK_ANSWER'" ;;
    esac
}

#######################################
# Ask a request of cockpit-check.js (ask_nested).
# Arguments:
#   $1 - request
#   $2 - options, as one JSON object (default {})
#######################################
ask_check() {
    ask_nested "$COCKPIT_CHECK_PATH" "$COCKPIT_CHECK_FUNCTION_NAME" "$@"
}

#######################################
# Ask a request of pointer.js (ask_nested).
# Arguments:
#   $1 - request
#   $2 - options, as one JSON object (default {})
#######################################
ask_pointer() {
    ask_nested "$POINTER_SCRIPT_PATH" "$POINTER_FUNCTION_NAME" "$@"
}

#######################################
# Ask a request again, every CHECK_POLL_INTERVAL_SECONDS, while its answer is
# bad or pending, at most a number of times; keeps the last answer. One still
# pending at the end is could-not-judge: what it waited for never came.
# Arguments:
#   $1 - how many times at most
#   $2 - ask_check or ask_pointer
#   $3 - request
#   $4 - options, as one JSON object (default {})
#######################################
poll_nested() {
    local attempt_limit="$1" ask_function="$2" attempt
    shift 2
    for (( attempt = 1; attempt <= attempt_limit; attempt++ )); do
        "$ask_function" "$@"
        [[ "$CHECK_VERDICT" == "$CHECK_BAD_VERDICT" || "$CHECK_VERDICT" == "$CHECK_PENDING_VERDICT" ]] || return 0
        (( attempt < attempt_limit )) && sleep "$CHECK_POLL_INTERVAL_SECONDS"
    done
    if [[ "$CHECK_VERDICT" == "$CHECK_PENDING_VERDICT" ]]; then
        CHECK_VERDICT="$CHECK_COULD_NOT_JUDGE_VERDICT"
        CHECK_DETAIL="still waiting after $attempt_limit tries: $CHECK_DETAIL"
    fi
}

#######################################
# Print one field of the last answer.
# Arguments:
#   $1 - field name
#######################################
check_answer_field() {
    jq -r --arg field_name "$1" '.[$field_name] // empty' <<<"$CHECK_ANSWER"
}

#######################################
# Start collecting one step's parts (note_answer, note_bad, note_unjudged).
#######################################
begin_check_step() {
    STEP_BAD_DETAILS=()
    STEP_UNJUDGED_DETAILS=()
}

#######################################
# Note, once, that the run's fixture could not be put back (restore_check_fixture),
# as a part of the step under way that could not be judged.
#######################################
note_fixture_not_restored() {
    [[ -n "$CHECK_FIXTURE_NOT_RESTORED_NOTE" ]] || return 0
    note_unjudged "$CHECK_FIXTURE_NOT_RESTORED_NOTE"
    CHECK_FIXTURE_NOT_RESTORED_NOTE=""
}

#######################################
# Count the last answer toward the step: bad and could-not-judge are kept.
#######################################
note_answer() {
    case "$CHECK_VERDICT" in
        "$CHECK_OK_VERDICT") ;;
        "$CHECK_BAD_VERDICT") STEP_BAD_DETAILS+=("$CHECK_DETAIL") ;;
        *) STEP_UNJUDGED_DETAILS+=("$CHECK_DETAIL") ;;
    esac
}

#######################################
# Keep a fault of the step.
# Arguments:
#   $1 - the fault
#######################################
note_bad() {
    STEP_BAD_DETAILS+=("$1")
}

#######################################
# Keep why a part of the step could not be judged.
# Arguments:
#   $1 - why
#######################################
note_unjudged() {
    STEP_UNJUDGED_DETAILS+=("$1")
}

#######################################
# Print one step's line and count it: bad when any part was, else could not
# judge when any part could not be, else ok. A restore of the run's fixture
# that failed since the last step's line (in this step, or before it began)
# is a part of this step that could not be judged: it ran on a rewritten
# fixture.
# Arguments:
#   $1 - step name
#   $2 - what an ok line says
#######################################
end_check_step() {
    local step_name="$1" ok_detail="$2" joined_details
    note_fixture_not_restored
    if (( ${#STEP_BAD_DETAILS[@]} > 0 )); then
        joined_details="$(printf '%s; ' "${STEP_BAD_DETAILS[@]}")"
        CHECK_BAD_STEP_COUNT=$((CHECK_BAD_STEP_COUNT + 1))
        printf 'bad %s: %s\n' "$step_name" "${joined_details%; }"
    elif (( ${#STEP_UNJUDGED_DETAILS[@]} > 0 )); then
        joined_details="$(printf '%s; ' "${STEP_UNJUDGED_DETAILS[@]}")"
        CHECK_UNJUDGED_STEP_COUNT=$((CHECK_UNJUDGED_STEP_COUNT + 1))
        printf 'could not judge %s: %s\n' "$step_name" "${joined_details%; }"
    else
        CHECK_OK_STEP_COUNT=$((CHECK_OK_STEP_COUNT + 1))
        printf 'ok %s: %s\n' "$step_name" "$ok_detail"
    fi
}

#######################################
# A step of one request: ask it (polled when a number of tries is given) and
# print its line from the answer.
# Arguments:
#   $1 - step name
#   $2 - how many times at most (1 asks once)
#   $3 - request
#   $4 - options, as one JSON object (default {})
#######################################
check_step_of_request() {
    local step_name="$1" attempt_limit="$2"
    shift 2
    begin_check_step
    poll_nested "$attempt_limit" ask_check "$@"
    note_answer
    end_check_step "$step_name" "$CHECK_DETAIL"
}

#######################################
# Count the last answer toward a step that sets up the harness's own windows:
# anything but ok could not be judged, since it is no fault of the extension.
#######################################
note_setup_answer() {
    [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]] || STEP_UNJUDGED_DETAILS+=("$CHECK_DETAIL")
}

#######################################
# Print a could-not-judge line for each of several steps whose precondition is
# missing, so that every step has its line and the summary counts them all.
# Arguments:
#   $1 - why
#   $@ - the step names
#######################################
print_unjudged_steps() {
    local unjudged_reason="$1" step_name
    shift
    for step_name in "$@"; do
        begin_check_step
        note_unjudged "$unjudged_reason"
        end_check_step "$step_name" ''
    done
}

#######################################
# Note each fault of the shell log past an offset, of the kinds asked for, as a
# bad part of the step (the first SHOWN_LOG_FAULTS_LIMIT, then how many more);
# a log it cannot read could not be judged.
# Arguments:
#   $1 - the byte offset to read from
#   $2 - the kinds, comma-separated
#######################################
note_shell_log_faults() {
    local fault_text
    local -a fault_lines
    # Captured with its status: a read that failed (the log unreadable, tail or awk failing) is never "no faults".
    if ! fault_text="$(shell_log_faults "$CHECK_RUN_DIR/log/shell.log" "$1" "$2")"; then
        note_unjudged "cannot read $CHECK_RUN_DIR/log/shell.log past byte $1"
        return 0
    fi
    [[ -n "$fault_text" ]] || return 0
    mapfile -t fault_lines <<<"$fault_text"
    note_bad "${#fault_lines[@]} line(s) in log/shell.log: $(printf '%s | ' "${fault_lines[@]:0:SHOWN_LOG_FAULTS_LIMIT}")"
}

#######################################
# Note a mismatch when the shell log past an offset holds a text other than a
# number of times.
# Arguments:
#   $1 - the byte offset to read from
#   $2 - the text
#   $3 - how many lines must hold it
#######################################
note_log_line_count() {
    local seen_count
    if ! seen_count="$(count_log_lines_since "$CHECK_RUN_DIR/log/shell.log" "$1" "$2")"; then
        note_unjudged "cannot read $CHECK_RUN_DIR/log/shell.log"
        return 0
    fi
    (( seen_count == $3 )) || note_bad "log/shell.log gained $seen_count line(s) with '$2', not $3"
}

#######################################
# Path of one of a run's window records.
# Arguments:
#   $1 - run directory
#   $2 - window title
#   $3 - WINDOW_PID_SUFFIX or WINDOW_STARTTIME_SUFFIX
#######################################
window_record_path() {
    printf '%s/%s/%s%s' "$1" "$WINDOWS_RELATIVE_DIR" "$2" "$3"
}

#######################################
# Succeed while a window the run recorded is still the process recorded: its
# pid runs with the start time recorded for it.
# Arguments:
#   $1 - run directory
#   $2 - window title
#######################################
is_recorded_window_running() {
    local window_pid="" window_starttime=""
    read -r window_pid 2>/dev/null <"$(window_record_path "$1" "$2" "$WINDOW_PID_SUFFIX")"
    read -r window_starttime 2>/dev/null <"$(window_record_path "$1" "$2" "$WINDOW_STARTTIME_SUFFIX")"
    [[ "$window_pid" =~ $POSITIVE_WHOLE_NUMBER_PATTERN && -n "$window_starttime" ]] || return 1
    [[ "$(starttime_of_process /proc "$window_pid")" == "$window_starttime" ]]
}

#######################################
# End a window the run recorded, only while it is still the process recorded,
# and forget it.
# Arguments:
#   $1 - run directory
#   $2 - window title
#######################################
end_recorded_window() {
    local window_pid=""
    if is_recorded_window_running "$1" "$2"; then
        read -r window_pid <"$(window_record_path "$1" "$2" "$WINDOW_PID_SUFFIX")"
        kill -TERM "$window_pid" 2>/dev/null
    fi
    rm -f -- "$(window_record_path "$1" "$2" "$WINDOW_PID_SUFFIX")" \
        "$(window_record_path "$1" "$2" "$WINDOW_STARTTIME_SUFFIX")"
}

#######################################
# End every window the run recorded (stop, and the supervisor's exit): they
# run outside the run's session, so its sweep never reaches them.
# Arguments:
#   $1 - run directory
#######################################
end_recorded_windows() {
    local pid_path window_title
    for pid_path in "$1/$WINDOWS_RELATIVE_DIR"/*"$WINDOW_PID_SUFFIX"; do
        [[ -e "$pid_path" ]] || continue
        window_title="${pid_path##*/}"
        end_recorded_window "$1" "${window_title%"$WINDOW_PID_SUFFIX"}"
    done
    return 0
}

#######################################
# Start a probe window (probe-window.js under gjs, which refuses outside a
# nested run) as a client of the nested shell only: the run's isolated
# environment plus its Wayland display, the Wayland backend and the run's
# private bus; in a session of its own, so the caller's terminal closing never
# ends it; logged to log/window-<title>.log. Records it by pid and start time
# under state/windows/, and sets OPENED_WINDOW_PID.
# Arguments:
#   $1 - run directory
#   $2 - verified private bus address
#   $3 - window title
#   $4 - gjs's path
#######################################
start_probe_window() {
    local run_dir="$1" address="$2" window_title="$3" gjs_path="$4" window_starttime
    build_isolated_env_command "$run_dir" || return 1
    (umask "$PRIVATE_UMASK" && mkdir -p "$run_dir/$WINDOWS_RELATIVE_DIR") || return 1
    "${ISOLATED_ENV_COMMAND[@]}" "WAYLAND_DISPLAY=$NESTED_WAYLAND_DISPLAY" "GDK_BACKEND=$PROBE_WINDOW_GDK_BACKEND" \
        "DBUS_SESSION_BUS_ADDRESS=$address" setsid "$gjs_path" -m "$PROBE_WINDOW_SCRIPT_PATH" "$window_title" \
        </dev/null >"$run_dir/log/window-$window_title.log" 2>&1 &
    OPENED_WINDOW_PID=$!
    window_starttime="$(starttime_of_process /proc "$OPENED_WINDOW_PID")" || window_starttime=""
    if ! printf '%s\n' "$OPENED_WINDOW_PID" >"$(window_record_path "$run_dir" "$window_title" "$WINDOW_PID_SUFFIX")" ||
        ! printf '%s\n' "$window_starttime" >"$(window_record_path "$run_dir" "$window_title" \
            "$WINDOW_STARTTIME_SUFFIX")"; then
        end_unrecorded_window "$window_starttime"
        return 1
    fi
}

#######################################
# End the window start_probe_window just started when it could not be
# recorded (no stop or exit could find it by its record): only while it is
# still this shell's own child with the start time read at its launch.
# Arguments:
#   $1 - its start time, as read at launch (empty when it could not be read)
#######################################
end_unrecorded_window() {
    local launch_starttime="$1"
    if is_own_child_process "$OPENED_WINDOW_PID" && [[ -z "$launch_starttime" ||
        "$(starttime_of_process /proc "$OPENED_WINDOW_PID")" == "$launch_starttime" ]]; then
        kill -TERM "$OPENED_WINDOW_PID" 2>/dev/null
    fi
    note "could not record the window of pid $OPENED_WINDOW_PID, so it was ended"
}

#######################################
# Open a probe window (start_probe_window), name it in the run's fixture's
# focusReply (its pid the one candidate), and wait until the nested shell
# shows it. Refuses (2) a title already open; a window that does not appear is
# ended and forgotten (2). Needs CHECK_ADDRESS.
# Arguments:
#   $1 - run directory
#   $2 - window title
#   $3 - gjs's path
#######################################
open_probe_window() {
    local run_dir="$1" window_title="$2" gjs_path="$3" pid_options
    if is_recorded_window_running "$run_dir" "$window_title"; then
        note "a window titled $window_title is open already; stop closes it"
        return "$EXIT_REFUSED"
    fi
    if ! start_probe_window "$run_dir" "$CHECK_ADDRESS" "$window_title" "$gjs_path" ||
        ! replace_run_cockpit_fixture "$run_dir" "$WINDOW_FOCUS_REPLY_JQ" --argjson pid "$OPENED_WINDOW_PID"; then
        end_recorded_window "$run_dir" "$window_title"
        note "could not open the $window_title window, or name it in the run's fixture"
        return "$EXIT_REFUSED"
    fi
    pid_options="$(jq -cn --argjson pid "$OPENED_WINDOW_PID" '{pid: $pid}')"
    poll_nested "$WINDOW_APPEAR_ATTEMPTS" ask_check window-shown "$pid_options"
    if [[ "$CHECK_VERDICT" != "$CHECK_OK_VERDICT" ]]; then
        end_recorded_window "$run_dir" "$window_title"
        note "the $window_title window did not appear (see $run_dir/log/window-$window_title.log): $CHECK_DETAIL"
        return "$EXIT_REFUSED"
    fi
}

#######################################
# Move the nested shell's virtual pointer to a point, then click there a
# number of times (0 for none), and wait until the shell has moved it. Keeps
# the last answer (CHECK_VERDICT): could-not-judge when it never arrived, since
# the headless backend may not take a virtual pointer. Needs CHECK_ADDRESS.
# Arguments:
#   $1 - x, in stage pixels
#   $2 - y
#   $3 - click count (0, 1 or 2)
#######################################
drive_nested_pointer() {
    local pointer_x="$1" pointer_y="$2" click_count="$3" pointer_request=move point_options
    (( click_count > 0 )) && pointer_request=click
    point_options="$(jq -cn --argjson x "$pointer_x" --argjson y "$pointer_y" --argjson click_count "$click_count" \
        '{x: $x, y: $y, clickCount: $click_count}')" || {
        CHECK_VERDICT="$CHECK_COULD_NOT_JUDGE_VERDICT"
        CHECK_DETAIL="not a point: '$pointer_x' '$pointer_y'"
        return 0
    }
    ask_pointer "$pointer_request" "$point_options"
    [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]] || return 0
    poll_nested "$POINTER_SETTLE_ATTEMPTS" ask_pointer at "$point_options"
    if [[ "$CHECK_VERDICT" == "$CHECK_BAD_VERDICT" ]]; then
        CHECK_VERDICT="$CHECK_COULD_NOT_JUDGE_VERDICT"
        CHECK_DETAIL="the pointer never reached ($pointer_x, $pointer_y), so the headless backend may not take a"
        CHECK_DETAIL+=" virtual pointer: $(check_answer_field detail)"
    fi
}

#######################################
# Point at, and click a number of times on, the first session row of a surface
# (the layer's sessions card, or the dropdown's). Keeps the last answer, and
# the row's tooltip text in CHECK_ROW_TOOLTIP_TEXT.
# Arguments:
#   $1 - LAYER_SURFACE or DROPDOWN_SURFACE
#   $2 - click count (0 to point only)
#######################################
point_at_session_row() {
    local surface="$1" click_count="$2" row_x row_y
    ask_check session-row-point "$(jq -cn --arg surface "$surface" '{surface: $surface}')"
    [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]] || return 0
    row_x="$(check_answer_field x)"
    row_y="$(check_answer_field y)"
    CHECK_ROW_TOOLTIP_TEXT="$(check_answer_field tooltipText)"
    drive_nested_pointer "$row_x" "$row_y" "$click_count"
}

#######################################
# Print the options naming one window: {pid}.
# Arguments:
#   $1 - pid
#######################################
pid_options_json() {
    jq -cn --argjson pid "$1" '{pid: $pid}'
}

#######################################
# Rewrite the run's fixture, then give the cockpit service time to read it
# again (FIXTURE_RELOAD_WAIT_SECONDS); a rewrite that fails is noted as could
# not be judged.
# Arguments:
#   $1 - jq program
#   $@ - jq's arguments
#######################################
rewrite_check_fixture() {
    if ! replace_run_cockpit_fixture "$CHECK_RUN_DIR" "$@"; then
        note_unjudged "could not rewrite the run's fixture"
        return 1
    fi
    sleep "$FIXTURE_RELOAD_WAIT_SECONDS"
}

#######################################
# Put the run's fixture back as start wrote it (window candidates empty) and
# give the cockpit service time to read it.
#######################################
restore_check_fixture() {
    if ! restore_run_cockpit_fixture "$CHECK_RUN_DIR"; then
        note "could not restore the run's fixture"
        CHECK_FIXTURE_NOT_RESTORED_NOTE="the run's fixture could not be put back as start wrote it, so this step ran"
        CHECK_FIXTURE_NOT_RESTORED_NOTE+=" on a rewritten one"
    fi
    sleep "$FIXTURE_RELOAD_WAIT_SECONDS"
}

#######################################
# Begin this pass of check cockpit in its run: its number (one more than the
# run's last recorded pass), recorded; and the shell log's offset its log
# steps judge from: 0 for the run's first pass (the enable's reparenting is at
# the run's start), else the log's size now, so that a fault an earlier pass
# found is not found again.
#######################################
begin_check_pass() {
    local previous_pass_number
    previous_pass_number="$(recorded_run_value "$CHECK_RUN_DIR" "$CHECK_PASS_RUN_VALUE_NAME")"
    [[ "$previous_pass_number" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]] || previous_pass_number=0
    CHECK_PASS_NUMBER=$((previous_pass_number + 1))
    CHECK_LOG_START_OFFSET=0
    (( CHECK_PASS_NUMBER > 1 )) && CHECK_LOG_START_OFFSET="$(check_shell_log_offset)"
    record_run_value "$CHECK_RUN_DIR" "$CHECK_PASS_RUN_VALUE_NAME" "$CHECK_PASS_NUMBER"
}

#######################################
# Print the nested shell's monotonic clock in µs (GLib.get_monotonic_time, the
# clock the extension's log limiter keeps time by); fail when it cannot be read.
#######################################
nested_monotonic_usec() {
    local monotonic_usec
    ask_check monotonic-time
    monotonic_usec="$(check_answer_field monotonicUsec)"
    [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" && "$monotonic_usec" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]] || return 1
    printf '%s' "$monotonic_usec"
}

#######################################
# Print why a reason's log line cannot be judged in this pass: an earlier pass
# of this run had it logged (by the time it recorded) less than
# EXTENSION_LOG_REPEAT_INTERVAL_USEC ago, by the nested shell's clock, so the
# extension's limiter cannot have let it through again (naming how long is
# left); or that time, or the clock, cannot be read. Print nothing when it can
# be judged (no earlier pass judged it, or the interval has passed).
# Arguments:
#   $1 - the run value an earlier pass recorded the time under
#######################################
limiter_closed_reason() {
    local logged_usec now_usec reopen_usec left_seconds interval_seconds
    logged_usec="$(recorded_run_value "$CHECK_RUN_DIR" "$1")"
    [[ -n "$logged_usec" ]] || return 0
    if [[ ! "$logged_usec" =~ $POSITIVE_WHOLE_NUMBER_PATTERN ]] || ! now_usec="$(nested_monotonic_usec)"; then
        printf "cannot tell whether the extension's log limiter has let this line through again since an earlier pass"
        printf ' of this run: the time it was logged, or the nested shell'"'"'s clock, cannot be read'
        return 0
    fi
    reopen_usec=$((logged_usec + EXTENSION_LOG_REPEAT_INTERVAL_USEC))
    (( now_usec >= reopen_usec )) && return 0
    interval_seconds=$((EXTENSION_LOG_REPEAT_INTERVAL_USEC / USEC_PER_SECOND))
    left_seconds=$(( (reopen_usec - now_usec + USEC_PER_SECOND - 1) / USEC_PER_SECOND ))
    printf 'the extension logs this line at most once per %s s, across disable and enable, and an earlier pass' \
        "$interval_seconds"
    printf ' of this run had it logged: it can be judged again in %s s' "$left_seconds"
}

#######################################
# Record, under a run value, by when this pass's line for a reason will have
# been logged: the nested shell's clock now plus NO_ACTIVATION_WAIT_SECONDS,
# the step's wait. Recorded before the click, so that a pass ended in the
# middle of the step still holds a later pass to the limiter;
# UNKNOWN_TIME_WORD when the clock cannot be read.
# Arguments:
#   $1 - the run value
#######################################
record_limited_line_time() {
    local now_usec logged_by_usec="$UNKNOWN_TIME_WORD"
    now_usec="$(nested_monotonic_usec)" && logged_by_usec=$((now_usec + NO_ACTIVATION_WAIT_SECONDS * USEC_PER_SECOND))
    record_run_value "$CHECK_RUN_DIR" "$1" "$logged_by_usec"
}

#######################################
# Steps 1 to 3: the extension ACTIVE and the shell log so far clean of its
# errors and of Clutter's reparenting warnings; the layer placed; the grid laid
# out as the fixture's layout names it.
#######################################
check_cockpit_layout_steps() {
    local grid_options
    check_step_of_request extension 1 extension-active
    begin_check_step
    note_shell_log_faults "$CHECK_LOG_START_OFFSET" "$EXTENSION_LOG_FAULT_KIND,$CLUTTER_LOG_FAULT_KIND"
    end_check_step early-log "the shell log since this pass began (the first pass: since the run began) holds no error of the extension and no reparenting warning"
    check_step_of_request layer 1 layer-placement
    begin_check_step
    if grid_options="$(jq -c --argjson known "$COCKPIT_KNOWN_CARD_IDS_JSON" "$GRID_OPTIONS_JQ" \
        "$CHECK_RUN_DIR/$COCKPIT_FIXTURE_START_RELATIVE_PATH")"; then
        ask_check grid-geometry "$grid_options"
        note_answer
    else
        note_unjudged "cannot read the layout of the run's fixture"
    fi
    end_check_step grid "$CHECK_DETAIL"
}

#######################################
# Step 4: the layer takes the pointer, and a pointer over the first session row
# shows its tooltip after the hover delay, above the card.
#######################################
check_cockpit_hover_steps() {
    check_step_of_request interactive 1 layer-interactive
    begin_check_step
    point_at_session_row "$LAYER_SURFACE" 0
    note_answer
    if [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]]; then
        poll_nested "$TOOLTIP_APPEAR_ATTEMPTS" ask_check tooltip-shown \
            "$(jq -cn --arg text "$CHECK_ROW_TOOLTIP_TEXT" '{surface: "layer", tooltipText: $text}')"
        note_answer
    fi
    end_check_step hover "the tooltip shows the row's text after the hover delay, above the card"
}

#######################################
# Open the check's two windows (the decoy, then the probe the fixture's
# focusReply names), move both clear of the sessions card, and give the decoy
# the focus. Sets CHECK_PROBE_PID and CHECK_DECOY_PID; prints the step's line.
# All of it is the harness's own setup, so what fails could not be judged,
# never bad. Returns 1 when the windows could not be set up.
#######################################
open_check_windows() {
    local window_title window_pid clear_options
    begin_check_step
    CHECK_PROBE_PID=""
    CHECK_DECOY_PID=""
    for window_title in "$DECOY_WINDOW_TITLE" "$HERDR_PROBE_WINDOW_TITLE"; do
        if ! open_probe_window "$CHECK_RUN_DIR" "$window_title" "$CHECK_GJS_PATH"; then
            note_unjudged "the $window_title window could not be opened"
            end_check_step windows ''
            return 1
        fi
        window_pid="$OPENED_WINDOW_PID"
        [[ "$window_title" == "$DECOY_WINDOW_TITLE" ]] && CHECK_DECOY_PID="$window_pid"
        [[ "$window_title" == "$HERDR_PROBE_WINDOW_TITLE" ]] && CHECK_PROBE_PID="$window_pid"
        clear_options="$(jq -cn --argjson pid "$window_pid" '{pid: $pid, cardId: "sessions"}')"
        ask_check place-window-clear "$clear_options"
        note_setup_answer
        poll_nested "$STATE_SETTLE_ATTEMPTS" ask_check window-clear "$clear_options"
        note_setup_answer
    done
    ask_check activate-window "$(pid_options_json "$CHECK_DECOY_PID")"
    poll_nested "$FOCUS_ANSWER_ATTEMPTS" ask_check focused-window "$(pid_options_json "$CHECK_DECOY_PID")"
    note_setup_answer
    end_check_step windows "the decoy ($CHECK_DECOY_PID) holds the focus; the probe ($CHECK_PROBE_PID) is named"
    (( ${#STEP_BAD_DETAILS[@]} + ${#STEP_UNJUDGED_DETAILS[@]} == 0 ))
}

#######################################
# Click the layer's first session row a number of times, then wait until the
# probe window has the focus (or the wait ends): its answer is noted.
# Arguments:
#   $1 - click count
#######################################
click_and_expect_probe_focused() {
    point_at_session_row "$LAYER_SURFACE" "$1"
    note_answer
    [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]] || return 0
    poll_nested "$FOCUS_ANSWER_ATTEMPTS" ask_check focused-window "$(pid_options_json "$CHECK_PROBE_PID")"
    note_answer
}

#######################################
# A click that must bring no window forward: remembers the windows, clicks the
# layer's first session row once, waits NO_ACTIVATION_WAIT_SECONDS, and notes
# whether the windows are unchanged and the shell log gained a text a number
# of times. Given the run value of a reason the extension's log limiter holds,
# the line count could not be judged while an earlier pass of the run had that
# line logged within the limiter's interval (limiter_closed_reason); to be
# judged, the time is recorded first, for a later pass.
# Arguments:
#   $1 - the text the click's log line holds
#   $2 - how many such lines it must add
#   $3 - optional: the run value of the limiter's reason
#######################################
click_and_expect_nothing_activated() {
    local log_needle="$1" wanted_line_count="$2" limiter_run_value_name="${3:-}" log_offset limiter_reason=""
    if [[ -n "$limiter_run_value_name" ]]; then
        limiter_reason="$(limiter_closed_reason "$limiter_run_value_name")"
        [[ -z "$limiter_reason" ]] && record_limited_line_time "$limiter_run_value_name"
    fi
    ask_check remember-windows
    note_answer
    log_offset="$(check_shell_log_offset)"
    point_at_session_row "$LAYER_SURFACE" 1
    note_answer
    [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]] || return 0
    sleep "$NO_ACTIVATION_WAIT_SECONDS"
    ask_check windows-unchanged
    note_answer
    if [[ -n "$limiter_reason" ]]; then
        note_unjudged "$limiter_reason"
        return 0
    fi
    note_log_line_count "$log_offset" "$log_needle" "$wanted_line_count"
}

#######################################
# Step 5: a session row's click focuses the window the fixture names (from
# another window's focus, and from every window minimized), with no Mutter
# warning from the activation; a reply naming no window, or not focused,
# activates nothing and logs one line per reason; two quick clicks make one
# FocusSession.
#######################################
check_cockpit_click_steps() {
    local log_offset
    if ! open_check_windows; then
        print_unjudged_steps "the check's windows could not be set up (see the windows step)" click click-log \
            click-show-desktop click-no-window click-no-window-again click-not-focused click-twice
        return 0
    fi
    begin_check_step
    log_offset="$(check_shell_log_offset)"
    click_and_expect_probe_focused 1
    end_check_step click "the click brought the probe forward from the decoy's focus"
    begin_check_step
    note_shell_log_faults "$log_offset" "$MUTTER_LOG_FAULT_KIND"
    end_check_step click-log "the activation logged no Mutter warning (no timestamp, focus or user-time line)"
    begin_check_step
    ask_check minimize-all
    note_answer
    click_and_expect_probe_focused 1
    end_check_step click-show-desktop "with every window minimized, the click unminimized and focused the probe"
    begin_check_step
    if rewrite_check_fixture "$WINDOW_FOCUS_REPLY_JQ" --argjson pid "$NO_WINDOW_PID"; then
        ask_check minimize-all
        click_and_expect_nothing_activated "$NO_WINDOW_LOG_NEEDLE" 1 "$NO_WINDOW_LOGGED_RUN_VALUE_NAME"
    fi
    end_check_step click-no-window "candidates matching no window activated nothing and logged one line"
    begin_check_step
    click_and_expect_nothing_activated "$NO_WINDOW_LOG_NEEDLE" 0
    end_check_step click-no-window-again "a second such click activated nothing and logged nothing more"
    begin_check_step
    if rewrite_check_fixture "$NOT_FOCUSED_REPLY_JQ" --arg code "$HERDR_UNREACHABLE_CODE"; then
        click_and_expect_nothing_activated "$NOT_FOCUSED_LOG_NEEDLE" 1 "$NOT_FOCUSED_LOGGED_RUN_VALUE_NAME"
    fi
    end_check_step click-not-focused "focused: false activated nothing and logged its code at once"
    begin_check_step
    if rewrite_check_fixture "$WINDOW_FOCUS_REPLY_JQ" --argjson pid "$CHECK_PROBE_PID"; then
        ask_check minimize-all
        ask_check focus-calls-arm
        note_answer
        click_and_expect_probe_focused 2
        ask_check focus-calls-read '{"expectedCount": 1}'
        note_answer
    fi
    end_check_step click-twice "two quick clicks made one FocusSession, and the probe came forward"
}

#######################################
# Step 6: the probe maximized freezes every card and drops the subscription; a
# fixture change while covered is not drawn; minimizing it draws every card
# again at once, with the change; a change while visible is drawn on the next
# Sample, not before.
#######################################
check_cockpit_cover_steps() {
    local first_name covered_name visible_name
    if [[ -z "$CHECK_PROBE_PID" ]]; then
        print_unjudged_steps 'no probe window to cover the cards with' cover cover-holds-changes reveal visible-change
        return 0
    fi
    first_name="$(jq -r "$FIRST_SESSION_NAME_JQ" "$CHECK_RUN_DIR/$COCKPIT_FIXTURE_START_RELATIVE_PATH")"
    covered_name="$first_name$COVERED_NAME_SUFFIX"
    visible_name="$first_name$VISIBLE_NAME_SUFFIX"
    begin_check_step
    ask_check minimize-all
    ask_check maximize-window "$(pid_options_json "$CHECK_PROBE_PID")"
    note_answer
    poll_nested "$STATE_SETTLE_ATTEMPTS" ask_check cover-state '{"expect": "covered"}'
    note_answer
    end_check_step cover "a maximized window froze every card and dropped the subscription"
    begin_check_step
    if rewrite_check_fixture "$SESSION_RENAME_JQ" --arg name "$covered_name"; then
        sleep "$COVERED_SAMPLES_WAIT_SECONDS"
        ask_check row-name "$(jq -cn --arg name "$first_name" '{surface: "layer", name: $name}')"
        note_answer
    fi
    end_check_step cover-holds-changes "a fixture change while covered was not drawn"
    begin_check_step
    ask_check minimize-window "$(pid_options_json "$CHECK_PROBE_PID")"
    poll_nested "$STATE_SETTLE_ATTEMPTS" ask_check cover-state '{"expect": "visible"}'
    note_answer
    poll_nested "$REVEAL_DRAW_ATTEMPTS" ask_check row-name \
        "$(jq -cn --arg name "$covered_name" '{surface: "layer", name: $name}')"
    note_answer
    end_check_step reveal "minimizing it drew every card again at once, the change included"
    begin_check_step
    ask_check draw-watch-arm "$(jq -cn --arg name "$visible_name" '{surface: "layer", name: $name}')"
    note_answer
    if [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]] &&
        rewrite_check_fixture "$SESSION_RENAME_JQ" --arg name "$visible_name"; then
        poll_nested "$DRAW_WATCH_ATTEMPTS" ask_check draw-watch-read
        note_answer
    fi
    end_check_step visible-change "a change while visible was drawn on the next Sample, not before"
    restore_check_fixture
}

#######################################
# Step 7: a source's stamp made old in the run's fixture draws "no data since"
# on its card; put back, the card's rows return.
#######################################
check_cockpit_stale_steps() {
    local stale_options fresh_options
    stale_options="$(jq -cn --arg card "$STALE_CARD_ID" '{cardId: $card, expect: "stale"}')"
    fresh_options="$(jq -cn --arg card "$STALE_CARD_ID" '{cardId: $card, expect: "fresh"}')"
    begin_check_step
    if rewrite_check_fixture "$STALE_NETWORK_JQ" --argjson intervals "$STALE_NETWORK_INTERVALS"; then
        poll_nested "$STALE_ATTEMPTS" ask_check stale-card "$stale_options"
        note_answer
    fi
    end_check_step stale "an old stamp drew \"no data since\" on the $STALE_CARD_ID card"
    begin_check_step
    restore_check_fixture
    poll_nested "$STALE_ATTEMPTS" ask_check stale-card "$fresh_options"
    note_answer
    end_check_step stale-recovers "the stamp put back, the $STALE_CARD_ID card's rows returned"
}

#######################################
# Step 8: the dropdown's sessions item, its card open and closed, its tooltip
# above the menu and gone when it closes, a change drawn on the next Sample
# while open, and a row's click closing the menu and focusing the probe.
#######################################
check_cockpit_dropdown_steps() {
    local names_json names_options first_name dropdown_name
    names_json="$(jq -c "$SESSION_NAMES_JQ" "$CHECK_RUN_DIR/$COCKPIT_FIXTURE_START_RELATIVE_PATH")"
    first_name="$(jq -r "$FIRST_SESSION_NAME_JQ" "$CHECK_RUN_DIR/$COCKPIT_FIXTURE_START_RELATIVE_PATH")"
    dropdown_name="$first_name$DROPDOWN_NAME_SUFFIX"
    names_options="$(jq -cn --argjson names "$names_json" '{names: $names}')"
    check_step_of_request dropdown-order 1 dropdown-order
    begin_check_step
    # The rows at once: judged by the request that opens the menu; the widths, which need an allocation, are polled.
    ask_check dropdown-open "$names_options"
    note_answer
    poll_nested "$STATE_SETTLE_ATTEMPTS" ask_check dropdown-card "$names_options"
    note_answer
    end_check_step dropdown-open "open, the card showed the fixture's rows at once, as wide as the system card"
    begin_check_step
    point_at_session_row "$DROPDOWN_SURFACE" 0
    note_answer
    if [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]]; then
        poll_nested "$TOOLTIP_APPEAR_ATTEMPTS" ask_check tooltip-shown \
            "$(jq -cn --arg text "$CHECK_ROW_TOOLTIP_TEXT" '{surface: "dropdown", tooltipText: $text}')"
        note_answer
    fi
    end_check_step dropdown-tooltip "the row's tooltip showed above the open menu"
    begin_check_step
    ask_check dropdown-close
    note_answer
    poll_nested "$STATE_SETTLE_ATTEMPTS" ask_check dropdown-closed
    note_answer
    end_check_step dropdown-closed "closed, the card froze and its tooltip went"
    begin_check_step
    # The dropdown's card draws only while its menu is open: the watch is armed only once the open is ok.
    ask_check dropdown-open
    note_answer
    if [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]]; then
        ask_check draw-watch-arm "$(jq -cn --arg name "$dropdown_name" '{surface: "dropdown", name: $name}')"
        note_answer
    fi
    if [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]] &&
        rewrite_check_fixture "$SESSION_RENAME_JQ" --arg name "$dropdown_name"; then
        poll_nested "$DRAW_WATCH_ATTEMPTS" ask_check draw-watch-read
        note_answer
    fi
    ask_check dropdown-close
    end_check_step dropdown-change "a change while the menu was open was drawn on the next Sample, not before"
    restore_check_fixture
    begin_check_step
    if [[ -z "$CHECK_PROBE_PID" ]] ||
        ! rewrite_check_fixture "$WINDOW_FOCUS_REPLY_JQ" --argjson pid "$CHECK_PROBE_PID"; then
        note_unjudged 'no probe window to focus'
    else
        ask_check minimize-all
        ask_check dropdown-open
        note_answer
        point_at_session_row "$DROPDOWN_SURFACE" 1
        note_answer
        poll_nested "$STATE_SETTLE_ATTEMPTS" ask_check dropdown-closed
        note_answer
        poll_nested "$FOCUS_ANSWER_ATTEMPTS" ask_check focused-window "$(pid_options_json "$CHECK_PROBE_PID")"
        note_answer
    fi
    end_check_step dropdown-click "a row's click inside the menu's grab closed the menu and focused the probe"
}

#######################################
# Steps 9 and 10: the lock path (disable, then enable again), then, with the
# check's windows closed, a screenshot of the stage.
#######################################
check_cockpit_lock_and_screenshot_steps() {
    local shot_path shot_status
    check_step_of_request lock-path 1 lock-path "{\"timeoutMs\": $LOCK_PATH_TIMEOUT_MS}"
    close_check_windows
    begin_check_step
    shot_path="$(screenshot_subcommand "$CHECK_SCREENSHOT_NAME_PREFIX$CHECK_PASS_NUMBER$PNG_SUFFIX")"
    shot_status=$?
    case "$shot_status" in
        0) ;;
        "$EXIT_REQUEST_FAILED") note_bad 'the nested shell could not take the screenshot' ;;
        *) note_unjudged 'the Screenshot call did not run' ;;
    esac
    end_check_step screenshot "$shot_path"
}

#######################################
# End the check's windows and wait until the nested session lists none.
#######################################
close_check_windows() {
    local attempt
    end_recorded_window "$CHECK_RUN_DIR" "$HERDR_PROBE_WINDOW_TITLE"
    end_recorded_window "$CHECK_RUN_DIR" "$DECOY_WINDOW_TITLE"
    for (( attempt = 1; attempt <= WINDOW_APPEAR_ATTEMPTS; attempt++ )); do
        ask_check window-count
        [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" && "$(check_answer_field count)" == 0 ]] && return 0
        sleep "$CHECK_POLL_INTERVAL_SECONDS"
    done
    note "the nested session still lists windows after the check closed its own"
}

#######################################
# The shell log since this pass began (CHECK_LOG_START_OFFSET: the whole log
# for the run's first pass): no error of the extension, no reparenting
# warning, no activation warning. It could not be judged when the whole log
# holds none of the focus lines the click steps provoke: then it may hold none
# of the extension's lines at all. That positive control reads the whole log,
# since a later pass within the limiter's interval provokes none of its own.
#######################################
check_cockpit_log_step() {
    local provoked_line_count
    begin_check_step
    note_shell_log_faults "$CHECK_LOG_START_OFFSET" \
        "$EXTENSION_LOG_FAULT_KIND,$CLUTTER_LOG_FAULT_KIND,$MUTTER_LOG_FAULT_KIND"
    provoked_line_count="$(count_log_lines_since "$CHECK_RUN_DIR/log/shell.log" 0 "$FOCUS_LOG_PREFIX")" ||
        provoked_line_count=0
    if (( provoked_line_count == 0 )); then
        note_unjudged "log/shell.log holds none of the focus lines the clicks provoked: it may hold no line of the extension"
    fi
    end_check_step log "no error of the extension, Clutter or Mutter warning in log/shell.log since this pass began ($provoked_line_count provoked line(s) found in the whole log)"
}

#######################################
# Run the performance harness's own measurement over this run (perf: about
# nine minutes) for check cockpit's count budgets. Run only in the background
# (`&`): it replaces that subshell with perf, so the pid the check holds is
# perf's own, which a signal can reach.
#######################################
run_perf_for_check_cockpit() {
    exec bash "$SCRIPT_PATH" perf
}

#######################################
# End check cockpit's perf pass, if it runs: a TERM, on which perf puts the run
# back (its window ended, the extension enabled, the top bar shown) once its
# current wait ends, then wait for it.
#######################################
end_check_perf() {
    [[ -n "$CHECK_PERF_PID" ]] || return 0
    kill -TERM "$CHECK_PERF_PID" 2>/dev/null
    wait "$CHECK_PERF_PID" 2>/dev/null
    CHECK_PERF_PID=""
}

#######################################
# Step 11: the count budgets with the cockpit drawn, through perf: no fallback
# timer armed while Samples flow, at most one frame a tick, and no more major
# collections than the disabled shell's; perf's lines pass through. perf runs
# in the background and the check waits for it, so that a signal to the check
# is taken at once (end_check_perf ends perf from the check's exit).
#######################################
check_cockpit_count_budgets_step() {
    local perf_output_path="$CHECK_RUN_DIR/$CHECK_PERF_OUTPUT_RELATIVE_PATH" perf_output perf_status verdict_lines
    # Made first: a redirect that failed would end the job with status 1, perf's own word for a broken budget.
    if ! : >"$perf_output_path"; then
        begin_check_step
        note_unjudged "cannot write $perf_output_path for perf's lines"
        end_check_step count-budgets ''
        return 0
    fi
    run_perf_for_check_cockpit >"$perf_output_path" &
    CHECK_PERF_PID=$!
    wait "$CHECK_PERF_PID"
    perf_status=$?
    CHECK_PERF_PID=""
    perf_output="$(<"$perf_output_path")" || perf_output=""
    printf '%s\n' "$perf_output"
    verdict_lines="$(grep -E '^perf: (PASS|FAIL|cockpit: |could not)' <<<"$perf_output" | tr '\n' ' ')"
    begin_check_step
    case "$perf_status" in
        0) ;;
        "$EXIT_REQUEST_FAILED") note_bad "perf: $verdict_lines" ;;
        *) note_unjudged "perf did not judge (exit $perf_status): $verdict_lines" ;;
    esac
    end_check_step count-budgets "perf: every count and cockpit budget held"
}

#######################################
# check cockpit's exit, on every path: its perf pass ended and waited for, the
# check's windows ended, the run's fixture put back, the dropdown closed. Each
# step guarded.
#######################################
end_check_cockpit() {
    end_check_perf
    end_recorded_window "$CHECK_RUN_DIR" "$HERDR_PROBE_WINDOW_TITLE"
    end_recorded_window "$CHECK_RUN_DIR" "$DECOY_WINDOW_TITLE"
    restore_run_cockpit_fixture "$CHECK_RUN_DIR" || note "could not restore the run's fixture"
    ask_check dropdown-close
    return 0
}

#######################################
# `check cockpit`: judge the cockpit in a live run whose cockpit service serves
# the run's fixture (see the header), a line per step: ok, bad or could not
# judge. Refuses (exit 2) a run not in fixture mode, whose cockpit service is
# gone, or whose session has windows already, before it clicks anything.
# Returns 1 when a step is bad, else 2 when one could not be judged, else 0.
#######################################
check_cockpit_subcommand() {
    local run_dir address window_count
    require_tools stat
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    address="$(live_run_session_address "$run_dir")" || exit "$EXIT_REFUSED"
    is_cockpit_fixture_run "$run_dir" \
        || die "refusing: the run's cockpit service was not started in fixture mode (no state/cockpit-fixture.json):" \
            "a session row's click could reach herdr"
    is_recorded_process_running "$run_dir" cockpit \
        || die "refusing: the run's cockpit service is not running (see $run_dir/log/cockpit.log)"
    # Its last step is a perf pass, which needs both: refused here, before the check clicks anything.
    is_requested_in_run "$run_dir" "$GC_LOG_RUN_VALUE_NAME" \
        || die "refusing: the run in $run_dir was not started with $GC_LOG_OPTION, which the count budgets' perf needs"
    is_requested_in_run "$run_dir" "$REPLAY_RUN_VALUE_NAME" \
        || die "refusing: the run in $run_dir was not started with $REPLAY_OPTION, which the count budgets' perf needs"
    require_tools busctl jq gjs setsid mktemp mv awk tail
    CHECK_RUN_DIR="$run_dir"
    CHECK_ADDRESS="$address"
    CHECK_GJS_PATH="$(command -v gjs)"
    # screenshot and perf act on this run too, from their own subshell and child.
    export RESOURCE_PULSE_NESTED_DIR="$run_dir"
    ask_check window-count
    window_count="$(check_answer_field count)"
    [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" && "$window_count" =~ $WHOLE_NUMBER_PATTERN ]] \
        || die "could not count the nested session's windows: $CHECK_DETAIL"
    (( window_count == 0 )) \
        || die "refusing: the nested session has $window_count window(s) already; the check opens its own"
    trap end_check_cockpit EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    begin_check_pass
    check_cockpit_layout_steps
    check_cockpit_hover_steps
    check_cockpit_click_steps
    check_cockpit_cover_steps
    check_cockpit_stale_steps
    check_cockpit_dropdown_steps
    check_cockpit_lock_and_screenshot_steps
    check_cockpit_log_step
    check_cockpit_count_budgets_step
    printf 'check cockpit: %d ok, %d bad, %d could not judge\n' "$CHECK_OK_STEP_COUNT" "$CHECK_BAD_STEP_COUNT" \
        "$CHECK_UNJUDGED_STEP_COUNT"
    (( CHECK_BAD_STEP_COUNT > 0 )) && return "$EXIT_REQUEST_FAILED"
    (( CHECK_UNJUDGED_STEP_COUNT > 0 )) && return "$EXIT_REFUSED"
    return 0
}

#######################################
# `window <title>`: open a probe window in a live run whose cockpit serves the
# run's fixture, record it, name it in the fixture's focusReply, wait until the
# shell shows it, and print its pid. Refuses (exit 2) a title that is not a
# plain name (before looking for a run), no live run, a run not in fixture
# mode, a title open already, and a window that does not appear.
# Arguments:
#   $1 - window title
#######################################
window_subcommand() {
    local window_title="$1" run_dir
    [[ "$window_title" =~ $WINDOW_TITLE_PATTERN ]] \
        || usage_error "a window title is a plain name (letters, digits, . _ -), got: '$window_title'"
    require_tools stat
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    CHECK_ADDRESS="$(live_run_session_address "$run_dir")" || exit "$EXIT_REFUSED"
    is_cockpit_fixture_run "$run_dir" \
        || die "refusing: the run's cockpit service was not started in fixture mode (no state/cockpit-fixture.json)"
    require_tools busctl jq gjs setsid mktemp mv
    open_probe_window "$run_dir" "$window_title" "$(command -v gjs)" || exit "$EXIT_REFUSED"
    note "window $window_title: pid $OPENED_WINDOW_PID, the one candidate of the fixture's focusReply; stop closes it"
    printf '%s\n' "$OPENED_WINDOW_PID"
}

#######################################
# `pointer <x> <y> [click]`: move the nested shell's virtual pointer to a point
# in stage pixels, click there when asked, and wait until the shell moved it.
# Refuses (exit 2) words that are not a point or `click` (before looking for a
# run), no live run, a click in a run not in fixture mode (where a session
# row's click could reach herdr), and a pointer that never arrives.
# Arguments:
#   $1 - x
#   $2 - y
#   $3 - optional: click
#######################################
pointer_subcommand() {
    local pointer_x="$1" pointer_y="$2" click_word="${3:-}" click_count=0 run_dir
    [[ "$pointer_x" =~ $POINTER_COORDINATE_PATTERN && "$pointer_y" =~ $POINTER_COORDINATE_PATTERN ]] \
        || usage_error "a point is two numbers of stage pixels, got: '$pointer_x' '$pointer_y'"
    if [[ -n "$click_word" ]]; then
        [[ "$click_word" == "$POINTER_CLICK_WORD" ]] \
            || usage_error "pointer takes $POINTER_CLICK_WORD after the point, got: '$click_word'"
        click_count=1
    fi
    require_tools stat
    run_dir="$(resolve_run_directory)" || exit "$EXIT_REFUSED"
    CHECK_ADDRESS="$(live_run_session_address "$run_dir")" || exit "$EXIT_REFUSED"
    if (( click_count > 0 )) && ! is_cockpit_fixture_run "$run_dir"; then
        die "refusing to click: the run's cockpit service was not started in fixture mode"
    fi
    require_tools busctl jq
    drive_nested_pointer "$pointer_x" "$pointer_y" "$click_count"
    [[ "$CHECK_VERDICT" == "$CHECK_OK_VERDICT" ]] || die "$CHECK_DETAIL"
    printf 'pointer at (%s, %s)%s\n' "$pointer_x" "$pointer_y" "$( (( click_count > 0 )) && printf ', clicked')"
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
        window)
            (( $# == 2 )) || usage_error "window takes one title"
            window_subcommand "$2" ;;
        pointer)
            (( $# == 3 || $# == 4 )) || usage_error "pointer takes x y and, to click, the word $POINTER_CLICK_WORD"
            shift
            pointer_subcommand "$@" ;;
        check)
            if (( $# != 2 )) || [[ "$2" != "$CHECK_COCKPIT_WORD" ]]; then
                usage_error "check takes one word: $CHECK_COCKPIT_WORD"
            fi
            check_cockpit_subcommand ;;
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
