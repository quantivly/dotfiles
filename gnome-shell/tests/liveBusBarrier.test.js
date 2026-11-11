// gnome-shell/tests/liveBusBarrier.js: the plain-gjs rows run only in a process started with every message bus
// address naming a bus that cannot exist, so a fake a row leaves out (an injected connection or link) falls through to
// no bus at all, never to the live session or system bus. No row here opens a connection: each reads what GIO would
// connect to, what the process was started with, or run.js's text.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';

/** The barrier's address, written out: a socket under /dev/null, which is not a directory, so none can ever exist. */
const BARRIER_ADDRESS = 'unix:path=/dev/null/resource-pulse-plain-gjs-rows-have-no-bus';
/**
 * The variables GIO reads the buses' addresses from. Its starter bus is one of the two, by DBUS_STARTER_BUS_TYPE
 * (measured on GLib 2.88: DBUS_STARTER_ADDRESS is never read).
 */
const BUS_ADDRESS_VARIABLE_NAMES = ['DBUS_SESSION_BUS_ADDRESS', 'DBUS_SYSTEM_BUS_ADDRESS'];
/** The process's environment as it was at exec: setenv() in the process never changes it (Linux). */
const EXEC_ENVIRONMENT_PATH = '/proc/self/environ';
const ENVIRONMENT_ENTRY_SEPARATOR = '\0';
const [TEST_FILE_PATH] = GLib.filename_from_uri(import.meta.url);
const TESTS_DIRECTORY_PATH = GLib.path_get_dirname(TEST_FILE_PATH);
const RUNNER_FILE_NAME = 'run.js';
const BARRIER_IMPORT_STATEMENT = "import './liveBusBarrier.js';";
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
 * Whether each bus address variable named the barrier's address when this process started. Only that answer is read
 * out of the environment, never a value, so no failure can print one.
 *
 * @returns {Object<string, boolean>} By variable name: true when it was the barrier's address at exec.
 */
function busAddressesBarredAtExec() {
    const [, environmentBytes] = GLib.file_get_contents(EXEC_ENVIRONMENT_PATH);
    const environmentEntries = new TextDecoder().decode(environmentBytes).split(ENVIRONMENT_ENTRY_SEPARATOR);
    return Object.fromEntries(BUS_ADDRESS_VARIABLE_NAMES.map(variableName => [
        variableName, environmentEntries.includes(`${variableName}=${BARRIER_ADDRESS}`),
    ]));
}

test('liveBusBarrier.js: the session bus GIO would connect to in the rows\' process is the barrier\'s, which cannot ' +
    'exist (an unset address would fall back to $XDG_RUNTIME_DIR/bus, the live one)', () =>
    assertEqual(busAddressGioWouldUse(Gio.BusType.SESSION), BARRIER_ADDRESS));

test('liveBusBarrier.js: the system bus GIO would connect to in the rows\' process is the barrier\'s', () =>
    assertEqual(busAddressGioWouldUse(Gio.BusType.SYSTEM), BARRIER_ADDRESS));

test('liveBusBarrier.js: the rows\' process was STARTED with every bus address the barrier\'s, not given it later: ' +
    'gjs connects to the session bus (GVfs) and the system bus (the memory monitor) before its first line of ' +
    'JavaScript, and Gio.bus_get hands that session connection back whatever the variables say afterwards', () =>
    assertEqual(busAddressesBarredAtExec(), {DBUS_SESSION_BUS_ADDRESS: true, DBUS_SYSTEM_BUS_ADDRESS: true}));

test('liveBusBarrier.js: run.js imports the barrier first, so no test module is evaluated in a process that can ' +
    'reach a live bus (static imports are evaluated in order)', () => {
    const runnerPath = GLib.build_filenamev([TESTS_DIRECTORY_PATH, RUNNER_FILE_NAME]);
    const [, runnerBytes] = GLib.file_get_contents(runnerPath);
    const runnerLines = new TextDecoder().decode(runnerBytes).split('\n');
    assertEqual(runnerLines.find(line => line.startsWith(IMPORT_STATEMENT_PREFIX)) ?? null, BARRIER_IMPORT_STATEMENT);
});
