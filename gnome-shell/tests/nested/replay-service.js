// Test double for scripts/resource-pulse-nested.sh: with `start --replay`, the run's copy of this file stands in for
// the sampler service (service/main.js) on the nested run's PRIVATE session bus, and publishes synthetic Samples from
// a seeded generator (replayGenerator.js), so every run of every version of the extension is measured against the
// same input. Ported from the performance session's spike (spike/replayService.js), without its top-bar pixel signal
// and its samples-when-watched switch.
//
// - It says exactly what the real service's protocol module builds: the interface, the bus name and both payloads
//   come from the given extension's own lib/protocol.js, and the tick and the history length from its
//   lib/constants.js, so it cannot drift from ResourcePulse1. It answers GetState, accepts WatchDetail and
//   UnwatchDetail, and publishes one Sample every SAMPLE_INTERVAL_SECONDS once it owns the name, watched or not.
// - The scenario is the first word of $XDG_RUNTIME_DIR/rp-scenario (the run's run/rp-scenario, which the harness's
//   `scenario` request writes with a token new to each request), read on every tick; with no such file, or a word
//   that is not a scenario, busy plays. Each new request, the word already playing included, starts that scenario's
//   sequence again from the fixed seed, refills both histories from it and numbers the Samples from 1 again, which
//   makes the client re-read GetState, as after a real service restart. Reading the same request again does not.
// - It reads that word and nothing else: no /proc and no cgroup file.
// - It serves only on the private session bus of the run named by RESOURCE_PULSE_NESTED_DIR, and refuses any other
//   before connecting: it owns the real service's bus name, so it must never answer on the live session bus. That
//   directory must be one the harness could have made, and the address never a list.
//
// Usage (inside a run's environment): gjs -m replay-service.js <extension dir>
// Exit status: 0 when the bus connection closes after the name was owned; 1 when it cannot connect, cannot export
// its object or never owns the name; 2 for a bad argument, a bus that is not the run's, or an extension directory
// it cannot load the two modules from.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import System from 'system';

import {
    DEFAULT_REPLAY_SCENARIO_NAME, REPLAY_TOTAL_MEMORY_BYTES, ReplayAppScanner, ReplayGenerator, isNewScenarioRequest,
    parseScenarioRequest,
} from './replayGenerator.js';

const LOG_PREFIX = 'replay-service:';
const EXIT_STATUS_SUCCESS = 0;
const EXIT_STATUS_FAILURE = 1;
const EXIT_STATUS_REFUSED = 2;
/** Set by scripts/resource-pulse-nested.sh to the run directory, in the nested processes' environment only. */
const NESTED_RUN_DIR_VARIABLE = 'RESOURCE_PULSE_NESTED_DIR';
const SESSION_BUS_ADDRESS_VARIABLE = 'DBUS_SESSION_BUS_ADDRESS';
/** Where the run's private session bus listens, relative to the run directory. */
const PRIVATE_SESSION_BUS_SOCKET_RELATIVE_PATH = 'bus/session.sock';
/** All dbus-daemon adds after the address it prints: its guid. */
const DBUS_GUID_SUFFIX_PATTERN = /^,guid=[0-9a-f]+$/;
/** A run directory the harness could have made: scripts/resource-pulse-nested.sh's RUN_DIR_SAFE_PATH_PATTERN. */
const RUN_DIR_SAFE_PATH_PATTERN = /^\/[A-Za-z0-9/._-]+$/;
/** What separates the addresses of a D-Bus address list, which GLib would try in turn. */
const DBUS_ADDRESS_LIST_SEPARATOR = ';';
/** The extension's two modules the service speaks through, relative to the extension directory. */
const EXTENSION_CONSTANTS_RELATIVE_PATH = 'lib/constants.js';
const EXTENSION_PROTOCOL_RELATIVE_PATH = 'lib/protocol.js';
/** The scenario word's file, in the runtime dir. */
const SCENARIO_FILE_NAME = 'rp-scenario';
/** wrapJSObject calls <Method><suffix>(parameters, invocation) for a method it finds no plain handler for. */
const INVOCATION_HANDLER_SUFFIX = 'Async';
/** GetState's reply as a GLib.Variant type: one string, the state JSON. */
const GET_STATE_REPLY_SIGNATURE = '(s)';
/** The standard D-Bus error GetState answers with when its state could not be built. */
const DBUS_FAILED_ERROR_NAME = 'org.freedesktop.DBus.Error.Failed';
const CLOCK_LABEL_FORMAT = '%H:%M';
const PERCENT = 100;

// The rest of each snapshot, as the spike published it: fixed figures, or a fixed share of the CPU figure.
const PERFORMANCE_CLUSTER_CPU_RATIO = 1.3;
const EFFICIENCY_CLUSTER_CPU_RATIO = 0.7;
const ZRAM_USED_GIBIBYTES = 1.6;
const ZRAM_RAM_GIBIBYTES = 0.4;
const DISK_SWAP_BYTES = 0;
const CPU_PRESSURE_PER_CPU_PERCENT = 0.25;
const MEMORY_PRESSURE_PERCENT = 0.1;
const IO_PRESSURE_PERCENT = 0.2;
// The apps (both winners and both rankings) come from replayGenerator.js ReplayAppScanner, ranked afresh as often as
// the real sampler scans them and held between; a row reads them as the extension's reader does.

/**
 * Succeeds only for the address of the run's own private session bus, as dbus-run-session hands it over: exactly
 * the run's socket, with at most dbus-daemon's guid after it. The run directory must pass the harness's own rule
 * first: one that does not (holding a ';' or a space, say) could build an address list that matches itself.
 * Anything else is refused, a list of addresses (which GLib would try in turn) included.
 *
 * @param {string|null} address - The session bus address in the environment.
 * @param {string|null} nestedRunDir - The run directory in the environment.
 * @returns {boolean} True for the run's private bus alone.
 */
function isRunPrivateSessionBusAddress(address, nestedRunDir) {
    if (!address || !nestedRunDir)
        return false;
    if (!RUN_DIR_SAFE_PATH_PATTERN.test(nestedRunDir))
        return false;
    // Never a list. The rule above already keeps ';' out of the directory, and so out of the run's address; this
    // stays so that a wider rule could not let a list through.
    if (address.includes(DBUS_ADDRESS_LIST_SEPARATOR))
        return false;
    const runBusAddress = `unix:path=${nestedRunDir}/${PRIVATE_SESSION_BUS_SOCKET_RELATIVE_PATH}`;
    if (!address.startsWith(runBusAddress))
        return false;
    const addressSuffix = address.slice(runBusAddress.length);
    return addressSuffix === '' || DBUS_GUID_SUFFIX_PATTERN.test(addressSuffix);
}

/**
 * Loads the extension's constants and protocol modules from its directory.
 *
 * @param {string} extensionDirectoryPath - The extension's directory (the run's copy of it).
 * @returns {Promise<{constants: object, protocol: object}>} Both module namespaces.
 * @throws {Error} When either module cannot be loaded.
 */
async function loadExtensionModules(extensionDirectoryPath) {
    const extensionDirectory = Gio.File.new_for_path(extensionDirectoryPath);
    const constantsUri = extensionDirectory.resolve_relative_path(EXTENSION_CONSTANTS_RELATIVE_PATH).get_uri();
    const protocolUri = extensionDirectory.resolve_relative_path(EXTENSION_PROTOCOL_RELATIVE_PATH).get_uri();
    const constants = await import(constantsUri);
    const protocol = await import(protocolUri);
    return {constants, protocol};
}

/**
 * Connects to a message bus by its address.
 *
 * @param {string} address - The bus address, already checked to be the run's private bus.
 * @returns {Gio.DBusConnection} The connection.
 * @throws {GLib.Error} When the bus cannot be reached.
 */
function connectToBus(address) {
    const connectionFlags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
        Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION;
    return Gio.DBusConnection.new_for_address_sync(address, connectionFlags, null, null);
}

/**
 * Runs a callback that GLib or Gio calls, so that nothing it throws escapes into the main loop: it is logged.
 *
 * @param {string} callbackDescription - What the callback does, for the log.
 * @param {() => void} callback - The callback's body.
 * @returns {void}
 */
function runWithoutThrowing(callbackDescription, callback) {
    try {
        callback();
    } catch (error) {
        console.error(`${LOG_PREFIX} ${callbackDescription} failed: ${error?.stack ?? error}`);
    }
}

/** One run of the replay service: its D-Bus face, its scenario, its histories and its tick. */
class ReplayService {
    /**
     * Builds the D-Bus face; nothing is exported or owned until start().
     *
     * @param {{constants: object, protocol: object}} extensionModules - The extension's lib/constants.js and
     *     lib/protocol.js.
     * @param {Gio.DBusConnection} connection - The run's private session bus.
     */
    constructor({constants, protocol}, connection) {
        this._constants = constants;
        this._protocol = protocol;
        this._connection = connection;
        this._mainLoop = new GLib.MainLoop(null, false);
        this._exitStatus = null;
        this._hasOwnedName = false;
        this._tickSourceId = null;
        this._serviceStartedAtUsec = GLib.get_real_time();
        this._generator = null;
        this._appScanner = null;
        this._sequence = 0;
        this._cpuHistory = [];
        this._memoryHistory = [];
        this._latestSnapshot = null;
        this._latestSampledAtUsec = null;
        this._lastScenarioRequest = null;
        this._lastScenarioProblem = null;
        this._exportedObject = Gio.DBusExportedObject.wrapJSObject(protocol.RESOURCE_PULSE_INTERFACE_XML, {
            [`${protocol.GET_STATE_METHOD_NAME}${INVOCATION_HANDLER_SUFFIX}`]: (_parameters, invocation) =>
                this._answerGetState(invocation),
            // Accepted and answered, as the client expects; replay publishes on every tick, watched or not.
            [protocol.WATCH_DETAIL_METHOD_NAME]: () => {},
            [protocol.UNWATCH_DETAIL_METHOD_NAME]: () => {},
        });
    }

    /**
     * Fills the histories, exports the object and asks for the name: publishing starts once it is owned.
     *
     * @returns {void}
     * @throws {GLib.Error} When the object cannot be exported.
     */
    start() {
        this._lastScenarioRequest = this._readScenarioRequest();
        this._restartWithScenario(this._lastScenarioRequest.scenarioName);
        this._exportedObject.export(this._connection, this._protocol.RESOURCE_PULSE_OBJECT_PATH);
        this._connection.connect('closed', () => runWithoutThrowing('the connection-closed handler',
            () => this._quit('the bus connection closed', EXIT_STATUS_SUCCESS)));
        Gio.bus_own_name_on_connection(this._connection, this._protocol.RESOURCE_PULSE_BUS_NAME,
            Gio.BusNameOwnerFlags.DO_NOT_QUEUE,
            () => runWithoutThrowing('the name-acquired handler', () => this._onNameAcquired()),
            () => runWithoutThrowing('the name-lost handler', () => this._onNameLost()));
    }

    /**
     * Runs the main loop until the service quits.
     *
     * @returns {number} The process exit status.
     */
    runUntilQuit() {
        this._mainLoop.run();
        return this._exitStatus ?? EXIT_STATUS_SUCCESS;
    }

    /**
     * Starts the tick once the name is owned.
     *
     * @returns {void}
     */
    _onNameAcquired() {
        if (this._tickSourceId !== null)
            return;
        this._hasOwnedName = true;
        this._tickSourceId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT,
            this._constants.SAMPLE_INTERVAL_SECONDS, () => this._onTick());
        const busName = this._protocol.RESOURCE_PULSE_BUS_NAME;
        console.log(`${LOG_PREFIX} serving ${busName}, playing ${this._generator.scenarioName}`);
    }

    /**
     * Quits when the name is lost: a failure if it was never owned (another copy holds it), and the end of the run if
     * it was (only a closed connection takes it away).
     *
     * @returns {void}
     */
    _onNameLost() {
        const busName = this._protocol.RESOURCE_PULSE_BUS_NAME;
        if (this._hasOwnedName)
            this._quit(`lost ${busName}: the bus connection closed`, EXIT_STATUS_SUCCESS);
        else
            this._quit(`cannot own ${busName}: another copy holds it`, EXIT_STATUS_FAILURE);
    }

    /**
     * Stops the tick and the main loop once; the first reason sets the exit status.
     *
     * @param {string} reason - Why, for the log.
     * @param {number} exitStatus - The status the process will exit with.
     * @returns {void}
     */
    _quit(reason, exitStatus) {
        if (this._exitStatus !== null)
            return;
        this._exitStatus = exitStatus;
        console.log(`${LOG_PREFIX} quitting: ${reason}`);
        if (this._tickSourceId !== null) {
            GLib.source_remove(this._tickSourceId);
            this._tickSourceId = null;
        }
        this._mainLoop.quit();
    }

    /**
     * One tick: publishes the next Sample, logging anything that throws, and keeps the tick going.
     *
     * @returns {boolean} GLib.SOURCE_CONTINUE.
     */
    _onTick() {
        runWithoutThrowing('a tick', () => this._publishNextSample());
        return GLib.SOURCE_CONTINUE;
    }

    /**
     * Restarts on a new scenario request (isNewScenarioRequest), then appends the next snapshot and sends it as one
     * Sample.
     *
     * @returns {void}
     */
    _publishNextSample() {
        const scenarioRequest = this._readScenarioRequest();
        if (isNewScenarioRequest(this._lastScenarioRequest, scenarioRequest))
            this._restartWithScenario(scenarioRequest.scenarioName);
        this._lastScenarioRequest = scenarioRequest;
        const snapshot = this._nextSnapshot();
        const appendedHistory = this._appendSnapshot(snapshot);
        this._sequence += 1;
        this._latestSampledAtUsec = GLib.get_real_time();
        const samplePayload = this._protocol.buildSamplePayload({
            snapshot, appendedHistory, sequence: this._sequence, sampledAtUsec: this._latestSampledAtUsec,
        });
        const sampleParameters = new GLib.Variant(this._protocol.SAMPLE_SIGNAL_SIGNATURE, [samplePayload]);
        this._exportedObject.emit_signal(this._protocol.SAMPLE_SIGNAL_NAME, sampleParameters);
    }

    /**
     * What the run's scenario file asks for (parseScenarioRequest): the default while there is none, or it names
     * none. A problem with the file is logged once, until the file names a scenario again.
     *
     * @returns {import('./replayGenerator.js').ScenarioRequest} The request read.
     */
    _readScenarioRequest() {
        const scenarioPath = GLib.build_filenamev([GLib.get_user_runtime_dir(), SCENARIO_FILE_NAME]);
        let scenarioBytes;
        try {
            [, scenarioBytes] = GLib.file_get_contents(scenarioPath);
        } catch (error) {
            // No file is the state before the first `scenario` request; anything else is worth a line.
            if (!error.matches?.(GLib.FileError, GLib.FileError.NOENT))
                this._reportScenarioProblem(`cannot read ${scenarioPath}: ${error.message}`);
            return parseScenarioRequest(null);
        }
        const scenarioRequest = parseScenarioRequest(new TextDecoder().decode(scenarioBytes));
        if (scenarioRequest.rejectedText !== null)
            this._reportScenarioProblem(`'${scenarioRequest.rejectedText}' in ${scenarioPath} names no scenario`);
        else
            this._lastScenarioProblem = null;
        return scenarioRequest;
    }

    /**
     * Logs a problem with the scenario file unless it is the one logged last, so a bad word logs once, not per tick.
     *
     * @param {string} problem - What is wrong.
     * @returns {void}
     */
    _reportScenarioProblem(problem) {
        if (problem === this._lastScenarioProblem)
            return;
        this._lastScenarioProblem = problem;
        console.warn(`${LOG_PREFIX} ${problem}; playing ${DEFAULT_REPLAY_SCENARIO_NAME}`);
    }

    /**
     * Starts a scenario's sequence from the fixed seed, and its apps from a first scan, refills both histories from it
     * and numbers the Samples from 1 again.
     *
     * @param {string} scenarioName - One of REPLAY_SCENARIO_NAMES.
     * @returns {void}
     * @throws {Error} When the extension's scan interval is not a whole number of its ticks (ReplayAppScanner).
     */
    _restartWithScenario(scenarioName) {
        // The real sampler's app scan interval while a detail watch is held, in its ticks: the replay's snapshots.
        const appScanIntervalSnapshots = this._constants.APP_SCAN_INTERVAL_SECONDS /
            this._constants.SAMPLE_INTERVAL_SECONDS;
        this._generator = new ReplayGenerator(scenarioName);
        this._appScanner = new ReplayAppScanner(appScanIntervalSnapshots);
        this._sequence = 0;
        this._cpuHistory = [];
        this._memoryHistory = [];
        for (let historyIndex = 0; historyIndex < this._constants.CARD_HISTORY_SAMPLES; historyIndex++)
            this._appendSnapshot(this._nextSnapshot());
        console.log(`${LOG_PREFIX} playing ${scenarioName} from the start of its sequence`);
    }

    /**
     * The next snapshot of the current scenario, in the real sampler's shape (service/sampler.js's Snapshot).
     *
     * @returns {object} The snapshot.
     */
    _nextSnapshot() {
        const {cpuBusyPercent, usedMemoryBytes} = this._generator.nextValues();
        const bytesPerGibibyte = this._constants.BYTES_PER_GIBIBYTE;
        const takenAtClockLabel = GLib.DateTime.new_now_local().format(CLOCK_LABEL_FORMAT);
        const performancePercent = Math.min(PERCENT, cpuBusyPercent * PERFORMANCE_CLUSTER_CPU_RATIO);
        const efficiencyPercent = cpuBusyPercent * EFFICIENCY_CLUSTER_CPU_RATIO;
        return {
            takenAtUsec: GLib.get_monotonic_time(),
            takenAtClockLabel,
            cpuBusyPercent,
            cpuClusters: {performancePercent, efficiencyPercent},
            memory: {usedBytes: usedMemoryBytes, totalBytes: REPLAY_TOTAL_MEMORY_BYTES},
            swap: {
                zramUsedBytes: ZRAM_USED_GIBIBYTES * bytesPerGibibyte,
                zramRamBytes: ZRAM_RAM_GIBIBYTES * bytesPerGibibyte,
                diskBytes: DISK_SWAP_BYTES,
            },
            pressureAvg10: {
                cpu: cpuBusyPercent * CPU_PRESSURE_PER_CPU_PERCENT,
                memory: MEMORY_PRESSURE_PERCENT,
                io: IO_PRESSURE_PERCENT,
            },
            apps: this._appScanner.appsOfNextSnapshot(cpuBusyPercent),
            isComplete: true,
        };
    }

    /**
     * Appends a snapshot's two fractions to the histories, keeping the newest CARD_HISTORY_SAMPLES, and makes it the
     * latest snapshot.
     *
     * @param {object} snapshot - A snapshot from _nextSnapshot.
     * @returns {{cpu: number, memory: number}} What it appended: the Sample's appendedHistory.
     */
    _appendSnapshot(snapshot) {
        const appendedHistory = {
            cpu: snapshot.cpuBusyPercent / PERCENT,
            memory: snapshot.memory.usedBytes / snapshot.memory.totalBytes,
        };
        this._cpuHistory.push(appendedHistory.cpu);
        this._memoryHistory.push(appendedHistory.memory);
        if (this._cpuHistory.length > this._constants.CARD_HISTORY_SAMPLES) {
            this._cpuHistory.shift();
            this._memoryHistory.shift();
        }
        this._latestSnapshot = snapshot;
        return appendedHistory;
    }

    /**
     * Answers GetState with the state JSON, or with a D-Bus error when it could not be built: nothing it throws
     * reaches Gio.
     *
     * @param {Gio.DBusMethodInvocation} invocation - The call.
     * @returns {void}
     */
    _answerGetState(invocation) {
        let statePayload;
        try {
            statePayload = this._protocol.buildStatePayload({
                snapshot: this._latestSnapshot,
                histories: {cpu: this._cpuHistory, memory: this._memoryHistory},
                serviceStartedAtUsec: this._serviceStartedAtUsec,
                latestSampledAtUsec: this._latestSampledAtUsec,
                sequence: this._sequence,
            });
        } catch (error) {
            console.error(`${LOG_PREFIX} GetState failed: ${error?.stack ?? error}`);
            invocation.return_dbus_error(DBUS_FAILED_ERROR_NAME, `cannot build the state: ${error?.message ?? error}`);
            return;
        }
        invocation.return_value(new GLib.Variant(GET_STATE_REPLY_SIGNATURE, [statePayload]));
    }
}

/**
 * Checks the argument and the bus, loads the extension's modules, connects, and serves until the connection closes.
 *
 * @param {string[]} argv - The arguments: the extension directory alone.
 * @returns {Promise<number>} The process exit status.
 */
async function main(argv) {
    if (argv.length !== 1 || argv[0] === '') {
        console.error(`${LOG_PREFIX} usage: gjs -m replay-service.js <extension dir>`);
        return EXIT_STATUS_REFUSED;
    }
    const [extensionDirectoryPath] = argv;
    const sessionBusAddress = GLib.getenv(SESSION_BUS_ADDRESS_VARIABLE);
    const nestedRunDir = GLib.getenv(NESTED_RUN_DIR_VARIABLE);
    if (!isRunPrivateSessionBusAddress(sessionBusAddress, nestedRunDir)) {
        const shownAddress = sessionBusAddress ?? '';
        console.error(`${LOG_PREFIX} refusing to serve on anything but the private session bus of the run in ` +
            `${NESTED_RUN_DIR_VARIABLE}, got: '${shownAddress}'`);
        return EXIT_STATUS_REFUSED;
    }
    let extensionModules;
    try {
        extensionModules = await loadExtensionModules(extensionDirectoryPath);
    } catch (error) {
        console.error(`${LOG_PREFIX} cannot load ${EXTENSION_CONSTANTS_RELATIVE_PATH} and ` +
            `${EXTENSION_PROTOCOL_RELATIVE_PATH} from ${extensionDirectoryPath}: ${error?.message ?? error}`);
        return EXIT_STATUS_REFUSED;
    }
    let connection;
    try {
        connection = connectToBus(sessionBusAddress);
    } catch (error) {
        console.error(`${LOG_PREFIX} cannot connect to ${sessionBusAddress}: ${error.message}`);
        return EXIT_STATUS_FAILURE;
    }
    const replayService = new ReplayService(extensionModules, connection);
    try {
        replayService.start();
    } catch (error) {
        console.error(`${LOG_PREFIX} cannot start: ${error?.stack ?? error}`);
        return EXIT_STATUS_FAILURE;
    }
    return replayService.runUntilQuit();
}

const exitStatus = await main(ARGV);
System.exit(exitStatus);
