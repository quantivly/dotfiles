// The cockpit service's entry point: `gjs -m service/cockpit.js`, run by systemd/cockpit.service (Type=dbus), and by
// the tests on a private bus. It owns lib/cockpitProtocol.js's bus name on the session bus, serves the cockpit's
// sources (service/cockpitSources.js) and the layout config there (service/cockpitDbusService.js), and runs until
// SIGTERM or SIGINT (a stop) or until it loses the name. It mirrors service/main.js, and imports nothing of the
// sampler's: a sampler change must not restart the cockpit, nor a cockpit change the sampler.
//
// - The object is exported when the bus connection is up, before the name is requested, so a client that sees the
//   name can call it at once; systemd counts the unit started at the same moment. The sources start once the name is
//   owned.
// - A second copy never owns the name: GLib reports a name it cannot own at once as lost, so that copy exits 1.
//   DO_NOT_QUEUE also keeps it out of the bus's queue behind the first in the moment before it exits.
// - The layout config (cockpitConfigPath under the user's config home) is read at start and watched with a
//   GFileMonitor on the file itself. Measured with gjs 1.88 on GLib's inotify backend: it reports the file created,
//   written, deleted, moved away and renamed into place (an atomic editor's save), even while the file or its
//   directory does not exist yet, so its directory is not watched separately. WATCH_MOVES makes a rename into place
//   one RENAMED event; without it, it is a DELETED of the temp file and a CREATED, read again all the same. A burst
//   of events reads the file once, CONFIG_RELOAD_DEBOUNCE_MS after the first. A file that cannot be read gives the
//   configError COCKPIT_CONFIG_MISSING_ERROR, one that does not parse the parser's error; either way the layout is
//   null and the sources keep serving. A read that gives the same layout and error as the one before reports nothing.
// - FocusSession finds the row with the id it is given in the latest sessions sample, and asks herdr over its socket
//   to focus the row's workspace (when it has one), then its pane. A failure answers a code from
//   COCKPIT_FOCUS_ERROR_CODES (ruling R18); herdr's own message goes to the journal, never to the bus.
// - Every shutdown destroys the sources, never only stops them.
// - Exit status: 0 for a signal, or for losing the name once owned (the bus connection closed: the session ended);
//   1 when the name was never owned, or the object could not be exported.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GLibUnix from 'gi://GLibUnix';
import System from 'system';

import {cockpitConfigPath, parseCockpitConfig} from '../lib/cockpitConfig.js';
import {COCKPIT_BUS_NAME, COCKPIT_FOCUS_ERROR, COCKPIT_PROTOCOL_VERSION} from '../lib/cockpitProtocol.js';
import {COCKPIT_LOG_PREFIX, HERDR_REQUEST_TIMEOUT_MS} from '../lib/constants.js';
import {RateLimitedLogger, describeError, describeErrorWithStack} from '../lib/errorLog.js';
import {isPlainObject, stringOrNull} from '../lib/jsonFields.js';
import {runEveryStep} from '../lib/teardown.js';
import {COCKPIT_LAYOUT_CHANGE_NAME, CockpitDBusService} from './cockpitDbusService.js';
import {CockpitSources} from './cockpitSources.js';
import {readFileToEnd} from './fileIo.js';
import {HERDR_ERROR_CODES, HerdrSocketClient, herdrSocketPath} from './herdrSocket.js';
import {MountsSource} from './sources/mounts.js';
import {NetworkSource} from './sources/network.js';
import {SessionsSource} from './sources/sessions.js';

const SIGINT_NUMBER = 2;
const SIGTERM_NUMBER = 15;
const SHUTDOWN_SIGNAL_NAMES_BY_NUMBER = new Map([[SIGTERM_NUMBER, 'SIGTERM'], [SIGINT_NUMBER, 'SIGINT']]);
const EXIT_STATUS_SUCCESS = 0;
const EXIT_STATUS_FAILURE = 1;
/**
 * Adds a Unix signal source: GLibUnix.signal_add on a current GLib. An older GLibUnix typelib names it
 * signal_add_full (gjs 1.88 keeps that name only as a deprecated alias, which warns), and CI may run such a GLib.
 * signal_add is taken first, so a current gjs never touches the alias.
 */
const addUnixSignalSource = GLibUnix.signal_add ?? GLibUnix.signal_add_full;
/** The configError while the config file does not exist or cannot be read. */
const COCKPIT_CONFIG_MISSING_ERROR = 'missing';
/** How long after the first of a burst of config file events the file is read, once, in milliseconds. */
const CONFIG_RELOAD_DEBOUNCE_MS = 200;
/**
 * The file monitor events after which the config is read again: every one that can change what its path holds.
 * ATTRIBUTE_CHANGED (permissions, times) and the unmount events are left out.
 */
const CONFIG_RELOAD_EVENTS = new Set([
    Gio.FileMonitorEvent.CHANGED, Gio.FileMonitorEvent.CHANGES_DONE_HINT, Gio.FileMonitorEvent.CREATED,
    Gio.FileMonitorEvent.DELETED, Gio.FileMonitorEvent.MOVED_IN, Gio.FileMonitorEvent.MOVED_OUT,
    Gio.FileMonitorEvent.RENAMED,
]);
/** The source whose rows FocusSession looks the id up in. */
const SESSIONS_SOURCE_NAME = 'sessions';
/** herdr's methods for focusing, and their parameters (from `herdr api schema --json`: WorkspaceTarget, PaneTarget). */
const WORKSPACE_FOCUS_METHOD = 'workspace.focus';
const PANE_FOCUS_METHOD = 'pane.focus';
/**
 * FocusSession's error code for each code a HerdrSocketClient rejection carries (ruling R18): herdr not there or not
 * answering is unreachable; herdr answering with an error, or with nothing it could read, is rejected. A rejection
 * with any other code is not herdr's, but a fault here.
 */
const FOCUS_ERROR_BY_HERDR_ERROR_CODE = new Map([
    [HERDR_ERROR_CODES.NO_SOCKET, COCKPIT_FOCUS_ERROR.HERDR_UNREACHABLE],
    [HERDR_ERROR_CODES.CONNECT_REFUSED, COCKPIT_FOCUS_ERROR.HERDR_UNREACHABLE],
    [HERDR_ERROR_CODES.TIMEOUT, COCKPIT_FOCUS_ERROR.HERDR_UNREACHABLE],
    [HERDR_ERROR_CODES.REMOTE_ERROR, COCKPIT_FOCUS_ERROR.HERDR_REJECTED],
    [HERDR_ERROR_CODES.MALFORMED, COCKPIT_FOCUS_ERROR.HERDR_REJECTED],
    [HERDR_ERROR_CODES.CLOSED, COCKPIT_FOCUS_ERROR.HERDR_REJECTED],
]);
/** Template keys of this process's own log lines, so each logs once per ERROR_LOG_REPEAT_INTERVAL_USEC. */
const CONFIG_WATCH_FAILURE_LOG_KEY = 'config watch failed';
const CONFIG_RELOAD_FAILURE_LOG_KEY = 'config reload failed';
const LISTENER_FAILURE_LOG_KEY = 'listener failed';
/** Prefix of the template key of a herdr rejection's journal line: one key per herdr code. */
const FOCUS_FAILURE_LOG_KEY_PREFIX = 'focus failed';

/**
 * Reads and parses the layout config file.
 *
 * @param {string} configPath - Absolute path of the file.
 * @returns {{layout: object|null, error: string|null}} parseCockpitConfig's reading of the file; layout null and
 *     COCKPIT_CONFIG_MISSING_ERROR when the file does not exist or cannot be read.
 */
function readCockpitConfigFile(configPath) {
    let configText;
    try {
        configText = readFileToEnd(configPath);
    } catch (error) {
        if (error instanceof GLib.Error)
            return {layout: null, error: COCKPIT_CONFIG_MISSING_ERROR};
        throw error;
    }
    return parseCockpitConfig(configText);
}

/**
 * @param {string} focusErrorCode - Why the session was not focused: a code from COCKPIT_FOCUS_ERROR_CODES.
 * @returns {{focused: boolean, windowPid: null, error: string}} FocusSession's reply for a session not focused.
 */
function focusFailureReply(focusErrorCode) {
    return {focused: false, windowPid: null, error: focusErrorCode};
}

/** The layout config file: its latest reading, read again whenever its file monitor reports a change to it. */
class CockpitLayoutConfig {
    /**
     * @param {object} options - The file and who hears of its changes.
     * @param {string} options.configPath - Absolute path of the config file.
     * @param {() => void} options.onChange - Called after a read gave a layout or an error other than the one before.
     * @param {RateLimitedLogger} options.errorLog - Where a monitor that cannot start, or a read that throws, goes.
     */
    constructor({configPath, onChange, errorLog}) {
        this._configPath = configPath;
        this._onChange = onChange;
        this._errorLog = errorLog;
        this._reading = {layout: null, error: COCKPIT_CONFIG_MISSING_ERROR};
        this._readingJson = JSON.stringify(this._reading);
        this._fileMonitor = null;
        this._fileMonitorHandlerId = null;
        this._reloadSourceId = null;
    }

    /** @returns {object|null} The layout of the latest read; null when the file is missing or invalid. */
    get layout() {
        return this._reading.layout;
    }

    /** @returns {string|null} Why the latest read gave no layout; null when it gave one. */
    get configError() {
        return this._reading.error;
    }

    /**
     * Reads the file, then watches it. A monitor that cannot start is logged: the layout read now stays until the
     * service restarts.
     *
     * @returns {void}
     */
    start() {
        this._storeReading(readCockpitConfigFile(this._configPath));
        try {
            this._fileMonitor = Gio.File.new_for_path(this._configPath)
                .monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null);
        } catch (error) {
            if (!(error instanceof GLib.Error))
                throw error;
            const errorText = describeError(error);
            this._errorLog.log(`cannot watch ${this._configPath}, so a change needs a restart: ${errorText}`,
                CONFIG_WATCH_FAILURE_LOG_KEY);
            return;
        }
        this._fileMonitorHandlerId = this._fileMonitor.connect('changed',
            (_fileMonitor, _file, _otherFile, eventType) => this._onFileEvent(eventType));
    }

    /**
     * Stops watching the file, and drops a read still waiting out its debounce. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        if (this._reloadSourceId !== null) {
            GLib.source_remove(this._reloadSourceId);
            this._reloadSourceId = null;
        }
        if (this._fileMonitor !== null) {
            this._fileMonitor.disconnect(this._fileMonitorHandlerId);
            this._fileMonitor.cancel();
            this._fileMonitor = null;
            this._fileMonitorHandlerId = null;
        }
    }

    /**
     * Arms one read CONFIG_RELOAD_DEBOUNCE_MS after an event that can change the file, unless one is armed already:
     * a burst of events reads the file once.
     *
     * @param {Gio.FileMonitorEvent} eventType - What the monitor saw.
     * @returns {void}
     */
    _onFileEvent(eventType) {
        if (!CONFIG_RELOAD_EVENTS.has(eventType) || this._reloadSourceId !== null)
            return;
        this._reloadSourceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, CONFIG_RELOAD_DEBOUNCE_MS, () => {
            this._reloadSourceId = null;
            this._reload();
            return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * Reads the file again and calls onChange when the reading differs from the one before. It runs as a GLib
     * callback, where a throw would only be printed, so one is logged here instead.
     *
     * @returns {void}
     */
    _reload() {
        try {
            if (this._storeReading(readCockpitConfigFile(this._configPath)))
                this._onChange();
        } catch (error) {
            const errorText = describeErrorWithStack(error);
            this._errorLog.log(`reading ${this._configPath} again failed: ${errorText}`,
                CONFIG_RELOAD_FAILURE_LOG_KEY);
        }
    }

    /**
     * @param {{layout: object|null, error: string|null}} reading - A read of the file.
     * @returns {boolean} Whether it differs from the stored one (compared as JSON text), which it then replaces.
     */
    _storeReading(reading) {
        const readingJson = JSON.stringify(reading);
        if (readingJson === this._readingJson)
            return false;
        this._reading = reading;
        this._readingJson = readingJson;
        return true;
    }
}

/**
 * One run of the cockpit service: the sources, the layout config, the herdr client, their D-Bus face, the bus name
 * and the main loop, and their shutdown. It is the face's cockpit: it gives the layout, the config error and the
 * sources, tells its listeners of every change (a layout change as COCKPIT_LAYOUT_CHANGE_NAME), passes the watch
 * state on to the sources and focuses sessions.
 */
class CockpitServiceProcess {
    constructor() {
        this._serviceStartedAtUsec = GLib.get_real_time();
        this._mainLoop = new GLib.MainLoop(null, false);
        this._errorLog = new RateLimitedLogger({
            nowUsec: () => GLib.get_monotonic_time(), write: line => console.warn(line), prefix: COCKPIT_LOG_PREFIX,
        });
        this._herdrClient = null;
        this._sources = null;
        this._layoutConfig = null;
        this._dbusService = null;
        this._busOwnerId = null;
        this._signalSourceIds = [];
        this._listenersById = new Map();
        this._nextListenerId = 1;
        this._hasOwnedName = false;
        this._isShuttingDown = false;
        this._exitStatus = EXIT_STATUS_SUCCESS;
    }

    /** @returns {object|null} The layout the config file gives; null when it is missing or invalid. */
    get layout() {
        return this._layoutConfig.layout;
    }

    /** @returns {string|null} Why the config file gives no layout; null when it gives one. */
    get configError() {
        return this._layoutConfig.configError;
    }

    /** @returns {Object<string, object|null>} Each source's latest object by name, read from the sources now. */
    get sourcesByName() {
        return this._sources.sourcesByName;
    }

    /**
     * @param {(changedSourceNames: string[], sourcesByName: object) => void} listener - Called after a source's
     *     object changed, with its name, or after the layout config changed, with COCKPIT_LAYOUT_CHANGE_NAME; and
     *     with every source's latest object either way.
     * @returns {number} An id for removeListener.
     */
    addListener(listener) {
        const listenerId = this._nextListenerId++;
        this._listenersById.set(listenerId, listener);
        return listenerId;
    }

    /**
     * @param {number} listenerId - An id addListener returned; an unknown one is ignored.
     * @returns {void}
     */
    removeListener(listenerId) {
        this._listenersById.delete(listenerId);
    }

    /**
     * @param {boolean} isWatched - Whether at least one client watches the cockpit; the sources' cadence follows it.
     * @returns {void}
     */
    setWatched(isWatched) {
        this._sources.setWatched(isWatched);
    }

    /**
     * Brings a session's herdr pane to the front: finds the row with this id in the latest sessions sample, asks
     * herdr to focus its workspace (when the row has one), then its pane, with the ids the row carries. The reply's
     * windowPid is null in this plan: which window shows herdr is the drawing side's to decide.
     *
     * @param {string} sessionId - A session row's id.
     * @returns {Promise<{focused: boolean, windowPid: null, error: string|null}>} focused true once herdr focused the
     *     pane; otherwise false with a code from COCKPIT_FOCUS_ERROR_CODES: unknown-session, no-pane, or the code
     *     FOCUS_ERROR_BY_HERDR_ERROR_CODE gives herdr's rejection, whose message is logged as
     *     `cockpit: focus: <id>: <message>`.
     * @throws {Error} (as a rejection) A failure that is not herdr's: a fault here, which the D-Bus face answers as
     *     internal.
     */
    async focusSession(sessionId) {
        const sessionRow = this._latestSessionRow(sessionId);
        if (sessionRow === null)
            return focusFailureReply(COCKPIT_FOCUS_ERROR.UNKNOWN_SESSION);
        const paneId = stringOrNull(sessionRow.paneId);
        if (paneId === null)
            return focusFailureReply(COCKPIT_FOCUS_ERROR.NO_PANE);
        const workspaceId = stringOrNull(sessionRow.workspaceId);
        try {
            if (workspaceId !== null)
                await this._herdrClient.request(WORKSPACE_FOCUS_METHOD, {workspace_id: workspaceId});
            await this._herdrClient.request(PANE_FOCUS_METHOD, {pane_id: paneId});
        } catch (error) {
            const focusErrorCode = FOCUS_ERROR_BY_HERDR_ERROR_CODE.get(error?.code);
            if (focusErrorCode === undefined)
                throw error;
            // herdr's message, bounded by the client, is for the journal only: the bus carries the code.
            const herdrMessage = describeError(error);
            const logTemplateKey = `${FOCUS_FAILURE_LOG_KEY_PREFIX}: ${error.code}`;
            this._errorLog.log(`focus: ${sessionId}: ${herdrMessage}`, logTemplateKey);
            return focusFailureReply(focusErrorCode);
        }
        return {focused: true, windowPid: null, error: null};
    }

    /**
     * Runs the service until it shuts down.
     *
     * @returns {number} The process exit status.
     */
    run() {
        const configHome = GLib.get_user_config_dir();
        this._herdrClient = new HerdrSocketClient({
            socketPath: herdrSocketPath(configHome), timeoutMs: HERDR_REQUEST_TIMEOUT_MS,
        });
        // The sessions source shares the herdr client FocusSession uses: one socket path, one close at shutdown.
        const sessionsSource = new SessionsSource({configHome, herdrClient: this._herdrClient});
        this._sources = new CockpitSources({sources: [sessionsSource, new NetworkSource(), new MountsSource()]});
        this._sources.addListener(
            (changedSourceNames, sourcesByName) => this._notifyListeners(changedSourceNames, sourcesByName));
        this._layoutConfig = new CockpitLayoutConfig({
            configPath: cockpitConfigPath(configHome),
            onChange: () => this._notifyListeners([COCKPIT_LAYOUT_CHANGE_NAME], this._sources.sourcesByName),
            errorLog: this._errorLog,
        });
        this._layoutConfig.start();
        for (const [signalNumber, signalName] of SHUTDOWN_SIGNAL_NAMES_BY_NUMBER) {
            this._signalSourceIds.push(addUnixSignalSource(GLib.PRIORITY_DEFAULT, signalNumber, () => {
                this._shutDown(`received ${signalName}`, EXIT_STATUS_SUCCESS);
                return GLib.SOURCE_CONTINUE;
            }));
        }
        this._busOwnerId = Gio.bus_own_name(Gio.BusType.SESSION, COCKPIT_BUS_NAME,
            Gio.BusNameOwnerFlags.DO_NOT_QUEUE,
            connection => this._onBusAcquired(connection),
            () => this._onNameAcquired(),
            () => this._onNameLost());
        this._mainLoop.run();
        return this._exitStatus;
    }

    /**
     * @param {string} sessionId - A session row's id.
     * @returns {object|null} The row with that id in the latest sessions sample; null when there is none.
     */
    _latestSessionRow(sessionId) {
        const sessionRows = this._sources.sourcesByName[SESSIONS_SOURCE_NAME]?.rows;
        if (!Array.isArray(sessionRows))
            return null;
        return sessionRows.find(sessionRow => isPlainObject(sessionRow) && sessionRow.id === sessionId) ?? null;
    }

    /**
     * Calls every listener; one that throws is logged and does not stop the others.
     *
     * @param {string[]} changedSourceNames - What changed: source names, or COCKPIT_LAYOUT_CHANGE_NAME.
     * @param {object} sourcesByName - Every source's latest object by name.
     * @returns {void}
     */
    _notifyListeners(changedSourceNames, sourcesByName) {
        for (const listener of [...this._listenersById.values()]) {
            try {
                listener(changedSourceNames, sourcesByName);
            } catch (error) {
                this._errorLog.log(`listener failed: ${describeErrorWithStack(error)}`, LISTENER_FAILURE_LOG_KEY);
            }
        }
    }

    /**
     * Exports the object on the new connection, before the name is requested.
     *
     * @param {Gio.DBusConnection} connection - The session bus connection.
     * @returns {void}
     */
    _onBusAcquired(connection) {
        try {
            this._dbusService = new CockpitDBusService(this, connection,
                {serviceStartedAtUsec: this._serviceStartedAtUsec});
        } catch (error) {
            const errorText = describeErrorWithStack(error);
            this._shutDown(`cannot export the D-Bus object: ${errorText}`, EXIT_STATUS_FAILURE);
        }
    }

    /**
     * Starts the sources once the name is owned; each samples at once.
     *
     * @returns {void}
     */
    _onNameAcquired() {
        if (this._isShuttingDown)
            return;
        this._hasOwnedName = true;
        this._sources.start();
        console.log(`${COCKPIT_LOG_PREFIX} serving ${COCKPIT_BUS_NAME} (protocol ${COCKPIT_PROTOCOL_VERSION})`);
    }

    /**
     * Shuts down when the name is lost: a failure if it was never owned (another copy holds it, or there is no bus),
     * and the end of the session if it was (it is not given up to anyone, so only a closed connection loses it).
     *
     * @returns {void}
     */
    _onNameLost() {
        if (this._hasOwnedName)
            this._shutDown(`lost ${COCKPIT_BUS_NAME}: the bus connection closed`, EXIT_STATUS_SUCCESS);
        else
            this._shutDown(`cannot own ${COCKPIT_BUS_NAME}: another copy holds it, or there is no session bus`,
                EXIT_STATUS_FAILURE);
    }

    /**
     * Stops everything once: the signal handlers, the D-Bus face, the config watch, the sources (destroyed, never
     * only stopped), the herdr client and the name, each whatever the others throw; then quits the main loop.
     *
     * @param {string} reason - Why, for the journal.
     * @param {number} exitStatus - The status the process will exit with.
     * @returns {void}
     */
    _shutDown(reason, exitStatus) {
        if (this._isShuttingDown)
            return;
        this._isShuttingDown = true;
        this._exitStatus = exitStatus;
        const logLine = `${COCKPIT_LOG_PREFIX} shutting down: ${reason}`;
        if (exitStatus === EXIT_STATUS_SUCCESS)
            console.log(logLine);
        else
            console.error(logLine);
        runEveryStep([
            {name: 'remove the signal handlers', run: () => this._removeSignalSources()},
            {name: 'destroy the D-Bus face', run: () => this._dbusService?.destroy()},
            {name: 'stop watching the config', run: () => this._layoutConfig?.destroy()},
            {name: 'destroy the sources', run: () => this._sources?.destroy()},
            {name: 'close the herdr client', run: () => this._herdrClient?.close()},
            {name: 'release the bus name', run: () => this._releaseBusName()},
        ], (stepName, error) => {
            const errorText = describeErrorWithStack(error);
            console.error(`${COCKPIT_LOG_PREFIX} shutdown: ${stepName} failed: ${errorText}`);
        });
        this._mainLoop.quit();
    }

    /**
     * Removes the SIGTERM and SIGINT handlers.
     *
     * @returns {void}
     */
    _removeSignalSources() {
        const signalSourceIds = this._signalSourceIds;
        this._signalSourceIds = [];
        for (const signalSourceId of signalSourceIds)
            GLib.source_remove(signalSourceId);
    }

    /**
     * Releases the bus name, once owned. A copy that never owned it leaves it alone: Gio.bus_unown_name would ask the
     * bus to release a name another copy holds, and GLib warns at the refusal (measured for service/main.js:
     * "Unexpected reply 3 when releasing name"). The process exits next, and the bus drops its pending request with
     * its connection.
     *
     * @returns {void}
     */
    _releaseBusName() {
        if (this._busOwnerId === null || !this._hasOwnedName)
            return;
        Gio.bus_unown_name(this._busOwnerId);
        this._busOwnerId = null;
    }
}

const exitStatus = new CockpitServiceProcess().run();
System.exit(exitStatus);
