// gnome-shell/tests/liveSessionBarrier.js: the plain-gjs rows run only in a process started with every message bus
// address naming a bus that cannot exist and a config home that cannot exist, so a fake a row leaves out (an injected
// connection, link, config home or herdr socket path) falls through to nothing, never to the live session or system
// bus or the live herdr socket. The process is also started in one fixed time zone (ruling D31), so a row that reads a
// local time reads it in one known zone on every machine. No row here opens a connection: each reads what GIO or GLib
// would use, what the process was started with, the zone both clocks read, or run.js's text.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {herdrSocketPath} from '../extensions/resource-pulse@dotfiles/service/herdrSocket.js';
import {HERDR_SOCKET_RELATIVE_PATH} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

/** The barrier's address, written out: a socket under /dev/null, which is not a directory, so none can ever exist. */
const BARRIER_ADDRESS = 'unix:path=/dev/null/resource-pulse-plain-gjs-rows-have-no-bus';
/** The barrier's config home, written out: under /dev/null too, so nothing (herdr's socket included) is under it. */
const BARRIER_CONFIG_HOME = '/dev/null/resource-pulse-plain-gjs-rows-have-no-config-home';
/**
 * The variables the barrier sets, each with its value. GIO's starter bus is one of the two buses, by
 * DBUS_STARTER_BUS_TYPE (measured on GLib 2.88: DBUS_STARTER_ADDRESS is never read).
 */
const BARRED_VALUES_BY_VARIABLE_NAME = Object.freeze({
    DBUS_SESSION_BUS_ADDRESS: BARRIER_ADDRESS,
    DBUS_SYSTEM_BUS_ADDRESS: BARRIER_ADDRESS,
    XDG_CONFIG_HOME: BARRIER_CONFIG_HOME,
});
/**
 * The rows' time zone, written out: Asia/Kolkata, 5 h 30 min east of UTC with no daylight saving time, so a row whose
 * oracle reads a local time can tell it from UTC (and from a whole-hour offset) on a UTC machine too.
 */
const ROWS_TIME_ZONE_VARIABLE_NAME = 'TZ';
const ROWS_TIME_ZONE = 'Asia/Kolkata';
const ROWS_TIME_ZONE_UTC_OFFSET_MINUTES = 5 * 60 + 30;
/** A wall-clock instant both clocks place in the rows' zone: 2026-11-06 21:20:01 UTC. */
const ZONE_PROBE_UNIX_SECONDS = 1_794_000_001;
const MILLISECONDS_PER_SECOND = 1000;
const MICROSECONDS_PER_MINUTE = 60_000_000;
/** The process's environment as it was at exec: setenv() in the process never changes it (Linux). */
const EXEC_ENVIRONMENT_PATH = '/proc/self/environ';
const ENVIRONMENT_ENTRY_SEPARATOR = '\0';
const [TEST_FILE_PATH] = GLib.filename_from_uri(import.meta.url);
const TESTS_DIRECTORY_PATH = GLib.path_get_dirname(TEST_FILE_PATH);
const RUNNER_FILE_NAME = 'run.js';
const BARRIER_IMPORT_STATEMENT = "import './liveSessionBarrier.js';";
const IMPORT_STATEMENT_PREFIX = 'import ';

/**
 * The address GIO would connect to for a bus, read without connecting (Gio.dbus_address_get_for_bus_sync).
 *
 * @param {Gio.BusType} busType - The bus.
 * @returns {string} The address, or what GIO said when it could not tell one.
 */
function busAddressGioWouldUse(busType) {
    try {
        return Gio.dbus_address_get_for_bus_sync(busType, null);
    } catch (error) {
        return `no address: ${error.message}`;
    }
}

/**
 * The entries of the environment this process was started with, each 'NAME=value'.
 *
 * @returns {string[]} The entries at exec.
 */
function environmentEntriesAtExec() {
    const [, environmentBytes] = GLib.file_get_contents(EXEC_ENVIRONMENT_PATH);
    return new TextDecoder().decode(environmentBytes).split(ENVIRONMENT_ENTRY_SEPARATOR);
}

/**
 * Whether each variable the barrier sets had the barrier's value when this process started. Only that answer is read
 * out of the environment, never a value, so no failure can print one.
 *
 * @returns {Object<string, boolean>} By variable name: true when it had the barrier's value at exec.
 */
function barredVariablesAtExec() {
    const environmentEntries = environmentEntriesAtExec();
    return Object.fromEntries(Object.entries(BARRED_VALUES_BY_VARIABLE_NAME).map(([variableName, barredValue]) => [
        variableName, environmentEntries.includes(`${variableName}=${barredValue}`),
    ]));
}

/**
 * The rows' time zone as each clock a row reads places one instant in it: GLib's DateTime and JavaScript's Date (two
 * readers of TZ that need not agree: SpiderMonkey's Date keeps the machine's zone for a POSIX rule string such as
 * XST-5:30, measured on gjs 1.88, where GLib follows it).
 *
 * @returns {{glibUtcOffsetMinutes: number, dateUtcOffsetMinutes: number}} Each clock's offset east of UTC.
 */
function utcOffsetMinutesOfEachClock() {
    const glibLocalTime = GLib.DateTime.new_from_unix_local(ZONE_PROBE_UNIX_SECONDS);
    const dateLocalTime = new Date(ZONE_PROBE_UNIX_SECONDS * MILLISECONDS_PER_SECOND);
    return {
        glibUtcOffsetMinutes: glibLocalTime.get_utc_offset() / MICROSECONDS_PER_MINUTE,
        // getTimezoneOffset() counts west of UTC.
        dateUtcOffsetMinutes: -dateLocalTime.getTimezoneOffset(),
    };
}

test('liveSessionBarrier.js: the session bus GIO would connect to in the rows\' process is the barrier\'s, which ' +
    'cannot exist (an unset address would fall back to $XDG_RUNTIME_DIR/bus, the live one)', () =>
    assertEqual(busAddressGioWouldUse(Gio.BusType.SESSION), BARRIER_ADDRESS));

test('liveSessionBarrier.js: the system bus GIO would connect to in the rows\' process is the barrier\'s', () =>
    assertEqual(busAddressGioWouldUse(Gio.BusType.SYSTEM), BARRIER_ADDRESS));

test('liveSessionBarrier.js: the config home GLib answers in the rows\' process is the barrier\'s, which cannot ' +
    'exist, and the herdr socket the service defaults to lies under it, never the live ~/.config/herdr/herdr.sock, ' +
    'where a focus request moves the owner\'s panes', () => {
    const configHome = GLib.get_user_config_dir();
    assertEqual({configHome, defaultHerdrSocketPath: herdrSocketPath(configHome)}, {
        configHome: BARRIER_CONFIG_HOME,
        defaultHerdrSocketPath: `${BARRIER_CONFIG_HOME}/${HERDR_SOCKET_RELATIVE_PATH}`,
    });
});

test('liveSessionBarrier.js: the rows\' process was STARTED with every variable the barrier sets at its value, not ' +
    'given it later: gjs connects to the session bus (GVfs) and the system bus (the memory monitor) before its first ' +
    'line of JavaScript, and Gio.bus_get hands that session connection back whatever the variables say afterwards',
() => assertEqual(barredVariablesAtExec(),
    {DBUS_SESSION_BUS_ADDRESS: true, DBUS_SYSTEM_BUS_ADDRESS: true, XDG_CONFIG_HOME: true}));

test('liveSessionBarrier.js: the rows\' process was STARTED in one fixed time zone, Asia/Kolkata (5 h 30 min east ' +
    'of UTC, no daylight saving time), and both clocks a row reads, GLib\'s and Date\'s, place an instant in it: a ' +
    'row whose oracle reads a local time is then never hollow on a UTC machine, CI included (ruling D31)', () =>
    assertEqual({
        startedInTheZone: environmentEntriesAtExec().includes(`${ROWS_TIME_ZONE_VARIABLE_NAME}=${ROWS_TIME_ZONE}`),
        ...utcOffsetMinutesOfEachClock(),
    }, {
        startedInTheZone: true, glibUtcOffsetMinutes: ROWS_TIME_ZONE_UTC_OFFSET_MINUTES,
        dateUtcOffsetMinutes: ROWS_TIME_ZONE_UTC_OFFSET_MINUTES,
    }));

test('liveSessionBarrier.js: run.js imports the barrier first, so no test module is evaluated in a process that can ' +
    'reach the live session (static imports are evaluated in order)', () => {
    const runnerPath = GLib.build_filenamev([TESTS_DIRECTORY_PATH, RUNNER_FILE_NAME]);
    const [, runnerBytes] = GLib.file_get_contents(runnerPath);
    const runnerLines = new TextDecoder().decode(runnerBytes).split('\n');
    assertEqual(runnerLines.find(line => line.startsWith(IMPORT_STATEMENT_PREFIX)) ?? null, BARRIER_IMPORT_STATEMENT);
});
