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
//   of events reads the file once, WATCHED_FILE_RELOAD_DEBOUNCE_MS after the first. A file that cannot be read gives
//   the configError COCKPIT_CONFIG_MISSING_ERROR, one that does not parse the parser's error; either way the layout
//   is null and the sources keep serving. A read that gives the same layout and error as the one before reports
//   nothing.
// - FocusSession finds the row with the id it is given in the latest sessions sample, and asks herdr over its socket
//   to focus the row's workspace (when it has one), then its pane. A failure answers a code from
//   COCKPIT_FOCUS_ERROR_CODES (ruling R18); herdr's own message goes to the journal, never to the bus. Once herdr
//   focused the pane, the reply names the windows that may show herdr's client, which the shell (no IO of its own)
//   then activates: herdr's API lists no clients, so the stat line of every process in /proc is read (through the
//   sources' refusing reader) and lib/processTree.js picks the herdr clients and their parents. A /proc that cannot
//   be read leaves the candidates read so far, none at worst, and a fault in naming them leaves none; either way
//   the reply stays focused, with one rate-limited journal line.
// - Fixture mode, for the nested test harness: when COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE names a file, the process
//   runs no source, reads no config and never asks herdr. It serves the file's `state` (layout, configError and
//   sources), reads the file again on change as it does the config (a change publishes Changed for the layout or the
//   sources that differ; a file that no longer reads keeps the one before, logged), and answers every FocusSession
//   with the file's `focusReply`, whatever the id. The file is read through the sources' refusing reader, so a path
//   under a stat-only fragment is never opened: the start fails instead. The variable unset or empty is no fixture;
//   cockpit.service unsets it, so a user manager whose environment carries it cannot make the unit serve one.
// - Every shutdown destroys the sources, never only stops them.
// - Exit status: 0 for a signal, or for losing the name once owned (the bus connection closed: the session ended);
//   1 when the name was never owned, the object could not be exported, or the fixture could not be served at start.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GLibUnix from 'gi://GLibUnix';
import System from 'system';

import {cockpitConfigPath, parseCockpitConfig} from '../lib/cockpitConfig.js';
import {
    COCKPIT_BUS_NAME, COCKPIT_FOCUS_ERROR, COCKPIT_PROTOCOL_VERSION, COCKPIT_SOURCE_NAMES,
} from '../lib/cockpitProtocol.js';
import {
    COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE, COCKPIT_LOG_PREFIX, HERDR_FOCUS_REQUEST_TIMEOUT_MS, HERDR_REQUEST_TIMEOUT_MS,
    PROC_PID_STAT_FILE_NAME, PROC_ROOT_PATH,
} from '../lib/constants.js';
import {RateLimitedLogger, describeError, describeErrorWithStack} from '../lib/errorLog.js';
import {isPlainObject, isSameAsJson, parseJsonObject, stringOrNull} from '../lib/jsonFields.js';
import {focusWindowPidCandidates, parseProcStat} from '../lib/processTree.js';
import {runEveryStep} from '../lib/teardown.js';
import {COCKPIT_LAYOUT_CHANGE_NAME, CockpitDBusService} from './cockpitDbusService.js';
import {CockpitSources} from './cockpitSources.js';
import {readFileToEnd} from './fileIo.js';
import {HERDR_ERROR_CODES, HerdrSocketClient, herdrSocketPath} from './herdrSocket.js';
import {MountsSource} from './sources/mounts.js';
import {NetworkSource} from './sources/network.js';
import {SessionsSource} from './sources/sessions.js';
import {
    StatOnlyPathRefusedError, isNotFoundError, listEntryNames, readFileRefusingSecrets,
} from './sources/sourceIo.js';

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
/**
 * Why a fixture file that can be read gives nothing to serve: it is not a JSON object holding a `state` object and a
 * `focusReply` object.
 */
const COCKPIT_FIXTURE_MALFORMED_ERROR = 'not a JSON object with a state object and a focusReply object';
/**
 * Why a fixture whose path holds a STAT_ONLY_PATH_FRAGMENTS entry is not served: the refusing reader never opens it.
 */
const COCKPIT_FIXTURE_REFUSED_ERROR =
    'refused before opening it: its path names a file the cockpit may stat, never open';
/** How long after the first of a burst of a watched file's events (the config's, the fixture's) it is read, once. */
const WATCHED_FILE_RELOAD_DEBOUNCE_MS = 200;
/**
 * The file monitor events after which a watched file is read again: every one that can change what its path holds.
 * ATTRIBUTE_CHANGED (permissions, times) and the unmount events are left out.
 */
const WATCHED_FILE_RELOAD_EVENTS = new Set([
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
 * How each focus request is bounded: by HERDR_FOCUS_REQUEST_TIMEOUT_MS rather than a sample's timeout, so that a slow
 * herdr is answered herdr-unreachable before the client's FocusSession call gives up.
 */
const FOCUS_REQUEST_OPTIONS = Object.freeze({timeoutMs: HERDR_FOCUS_REQUEST_TIMEOUT_MS});
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
/** The entries of PROC_ROOT_PATH that are processes: the ones named by a pid, in decimal digits alone. */
const PROC_PID_ENTRY_NAME_PATTERN = /^\d+$/;
/** Template keys of this process's own log lines, so each logs once per ERROR_LOG_REPEAT_INTERVAL_USEC. */
const FILE_WATCH_FAILURE_LOG_KEY = 'file watch failed';
const FILE_RELOAD_FAILURE_LOG_KEY = 'file reload failed';
const FIXTURE_RELOAD_FAILURE_LOG_KEY = 'fixture reload failed';
const FOCUS_WINDOW_CANDIDATES_FAILURE_LOG_KEY = 'focus window candidates failed';
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
 * @returns {{focused: boolean, windowPid: null, error: string, windowPidCandidates: number[]}} FocusSession's reply
 *     for a session not focused: no window to bring forward.
 */
function focusFailureReply(focusErrorCode) {
    return {focused: false, windowPid: null, error: focusErrorCode, windowPidCandidates: []};
}

/**
 * @returns {string|null} The fixture file COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE names; null when it is unset or empty,
 *     which is no fixture mode.
 */
function cockpitFixturePathOrNull() {
    const fixturePath = GLib.getenv(COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE);
    return fixturePath === null || fixturePath === '' ? null : fixturePath;
}

/**
 * @typedef {object} CockpitFixtureContent
 * @property {*} layout - The state's layout, as the file holds it.
 * @property {*} configError - The state's config error, as the file holds it.
 * @property {object} sourcesByName - The state's sources by name; an empty object when it has none.
 * @property {object} focusReply - The reply every FocusSession answers.
 * Each is served as the file holds it: the D-Bus face's builders read every field before it reaches the bus.
 */

/**
 * Reads the fixture file fixture mode serves, through the sources' refusing reader: whatever path the environment
 * names, one under a stat-only fragment is never opened.
 *
 * @param {string} fixturePath - Path of the file.
 * @returns {{fixture: CockpitFixtureContent|null, error: string|null}} The fixture and a null error; or a null
 *     fixture and why: COCKPIT_FIXTURE_REFUSED_ERROR for a stat-only path, the read's error for a file that cannot be
 *     read, COCKPIT_FIXTURE_MALFORMED_ERROR for one that holds no JSON object with a `state` object and a
 *     `focusReply` object.
 */
function readCockpitFixtureFile(fixturePath) {
    let fixtureText;
    try {
        fixtureText = readFileRefusingSecrets(fixturePath);
    } catch (error) {
        if (error instanceof StatOnlyPathRefusedError)
            return {fixture: null, error: COCKPIT_FIXTURE_REFUSED_ERROR};
        if (error instanceof GLib.Error)
            return {fixture: null, error: describeError(error)};
        throw error;
    }
    const fixtureObject = parseJsonObject(fixtureText);
    if (fixtureObject === null || !isPlainObject(fixtureObject.state) || !isPlainObject(fixtureObject.focusReply))
        return {fixture: null, error: COCKPIT_FIXTURE_MALFORMED_ERROR};
    const {layout = null, configError = null, sources} = fixtureObject.state;
    const sourcesByName = isPlainObject(sources) ? sources : {};
    return {fixture: {layout, configError, sourcesByName, focusReply: fixtureObject.focusReply}, error: null};
}

/**
 * What a fixture's new reading changed, as a cockpit listener names it.
 *
 * @param {CockpitFixtureContent} previousFixture - The reading served until now.
 * @param {CockpitFixtureContent} fixture - The new reading.
 * @returns {string[]} COCKPIT_LAYOUT_CHANGE_NAME when the layout or the config error differ, then each source of
 *     COCKPIT_SOURCE_NAMES whose object differs, each compared as JSON text; empty when nothing a client is sent did
 *     (a new focus reply alone).
 */
function changedFixtureNames(previousFixture, fixture) {
    const isLayoutSame = isSameAsJson([previousFixture.layout, previousFixture.configError],
        [fixture.layout, fixture.configError]);
    const layoutChangeNames = isLayoutSame ? [] : [COCKPIT_LAYOUT_CHANGE_NAME];
    const changedSourceNames = COCKPIT_SOURCE_NAMES.filter(sourceName =>
        !isSameAsJson(previousFixture.sourcesByName[sourceName], fixture.sourcesByName[sourceName]));
    return [...layoutChangeNames, ...changedSourceNames];
}

/**
 * Reads the stat line of every process in PROC_ROOT_PATH, through the sources' refusing reader: only the entries a
 * pid names are read. A process that exits between the listing and its read is skipped, as is a line that does not
 * parse.
 *
 * @returns {{statByPid: Map<number, object>, readFailure: GLib.Error|null}} Each process read (lib/processTree.js's
 *     ProcStat), by pid; and the first failure that was not a process exiting (the listing itself, which leaves the
 *     map empty, or a stat that could not be read), or null.
 */
function readProcessStats() {
    const statByPid = new Map();
    let pidEntryNames;
    try {
        pidEntryNames = listEntryNames(PROC_ROOT_PATH).filter(entryName => PROC_PID_ENTRY_NAME_PATTERN.test(entryName));
    } catch (error) {
        if (!(error instanceof GLib.Error))
            throw error;
        return {statByPid, readFailure: error};
    }
    let readFailure = null;
    for (const pidEntryName of pidEntryNames) {
        let statText;
        try {
            statText = readFileRefusingSecrets(`${PROC_ROOT_PATH}/${pidEntryName}/${PROC_PID_STAT_FILE_NAME}`);
        } catch (error) {
            if (!(error instanceof GLib.Error))
                throw error;
            if (!isNotFoundError(error))
                readFailure ??= error;
            continue;
        }
        const processStat = parseProcStat(statText);
        if (processStat !== null)
            statByPid.set(processStat.pid, processStat);
    }
    return {statByPid, readFailure};
}

/**
 * One file watched with a GFileMonitor on the file itself (see the file header for what that reports): a burst of
 * the events that can change what its path holds calls onFileChanged once, WATCHED_FILE_RELOAD_DEBOUNCE_MS after the
 * first. The config and the fixture each use one.
 */
class DebouncedFileWatch {
    /**
     * @param {object} options - The file and who hears of its changes.
     * @param {string} options.filePath - Absolute path of the file.
     * @param {() => void} options.onFileChanged - Called after a burst of events, to read the file again; a throw is
     *     logged.
     * @param {RateLimitedLogger} options.errorLog - Where a monitor that cannot start, or an onFileChanged that throws,
     *     goes.
     */
    constructor({filePath, onFileChanged, errorLog}) {
        this._filePath = filePath;
        this._onFileChanged = onFileChanged;
        this._errorLog = errorLog;
        this._fileMonitor = null;
        this._fileMonitorHandlerId = null;
        this._reloadSourceId = null;
    }

    /**
     * Starts watching. A monitor that cannot start is logged: what was read last stays until the service restarts.
     *
     * @returns {void}
     */
    start() {
        try {
            this._fileMonitor = Gio.File.new_for_path(this._filePath)
                .monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, null);
        } catch (error) {
            if (!(error instanceof GLib.Error))
                throw error;
            const errorText = describeError(error);
            this._errorLog.log(`cannot watch ${this._filePath}, so a change needs a restart: ${errorText}`,
                FILE_WATCH_FAILURE_LOG_KEY);
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
     * Arms one read WATCHED_FILE_RELOAD_DEBOUNCE_MS after an event that can change the file, unless one is armed
     * already: a burst of events reads the file once.
     *
     * @param {Gio.FileMonitorEvent} eventType - What the monitor saw.
     * @returns {void}
     */
    _onFileEvent(eventType) {
        if (!WATCHED_FILE_RELOAD_EVENTS.has(eventType) || this._reloadSourceId !== null)
            return;
        this._reloadSourceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, WATCHED_FILE_RELOAD_DEBOUNCE_MS, () => {
            this._reloadSourceId = null;
            this._runOnFileChanged();
            return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * Calls onFileChanged. It runs as a GLib callback, where a throw would only be printed, so one is logged here
     * instead.
     *
     * @returns {void}
     */
    _runOnFileChanged() {
        try {
            this._onFileChanged();
        } catch (error) {
            const errorText = describeErrorWithStack(error);
            this._errorLog.log(`reading ${this._filePath} again failed: ${errorText}`, FILE_RELOAD_FAILURE_LOG_KEY);
        }
    }
}

/** The layout config file: its latest reading, read again whenever its watch reports a change to it. */
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
        this._reading = {layout: null, error: COCKPIT_CONFIG_MISSING_ERROR};
        this._readingJson = JSON.stringify(this._reading);
        this._fileWatch = new DebouncedFileWatch({filePath: configPath, onFileChanged: () => this._reload(), errorLog});
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
     * Reads the file, then watches it.
     *
     * @returns {void}
     */
    start() {
        this._storeReading(readCockpitConfigFile(this._configPath));
        this._fileWatch.start();
    }

    /**
     * Stops watching the file. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        this._fileWatch.destroy();
    }

    /**
     * Reads the file again and calls onChange when the reading differs from the one before.
     *
     * @returns {void}
     */
    _reload() {
        if (this._storeReading(readCockpitConfigFile(this._configPath)))
            this._onChange();
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
 * Fixture mode's content (see the file header): the fixture file's latest reading that could be served, read again
 * whenever its watch reports a change to it.
 */
class CockpitFixture {
    /**
     * @param {object} options - The file and who hears of its changes.
     * @param {string} options.fixturePath - Path of the fixture file.
     * @param {(changedNames: string[]) => void} options.onChange - Called after a read changed the layout or a
     *     source, with what changed (changedFixtureNames).
     * @param {RateLimitedLogger} options.errorLog - Where a monitor that cannot start, or a read that cannot be
     *     served, goes.
     */
    constructor({fixturePath, onChange, errorLog}) {
        this._fixturePath = fixturePath;
        this._onChange = onChange;
        this._errorLog = errorLog;
        /** @type {CockpitFixtureContent|null} The reading served; null until start succeeded. */
        this._fixture = null;
        this._fileWatch = new DebouncedFileWatch({
            filePath: fixturePath, onFileChanged: () => this._reload(), errorLog,
        });
    }

    /** @returns {string} Path of the fixture file. */
    get fixturePath() {
        return this._fixturePath;
    }

    /** @returns {*} The fixture's layout. */
    get layout() {
        return this._fixture.layout;
    }

    /** @returns {*} The fixture's config error. */
    get configError() {
        return this._fixture.configError;
    }

    /** @returns {object} The fixture's sources by name. */
    get sourcesByName() {
        return this._fixture.sourcesByName;
    }

    /** @returns {object} The reply every FocusSession answers. */
    get focusReply() {
        return this._fixture.focusReply;
    }

    /**
     * Reads the file and, when it can be served, watches it.
     *
     * @returns {string|null} Why the file cannot be served (readCockpitFixtureFile's error), nothing being watched;
     *     null once it is served and watched.
     */
    start() {
        const {fixture, error} = readCockpitFixtureFile(this._fixturePath);
        if (fixture === null)
            return error;
        this._fixture = fixture;
        this._fileWatch.start();
        return null;
    }

    /**
     * Stops watching the file. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        this._fileWatch.destroy();
    }

    /**
     * Reads the file again: a reading that can be served replaces the one before, and onChange hears what changed; one
     * that cannot is logged, and the one before stays.
     *
     * @returns {void}
     */
    _reload() {
        const {fixture, error} = readCockpitFixtureFile(this._fixturePath);
        if (fixture === null) {
            this._errorLog.log(`the fixture (${this._fixturePath}) cannot be served, so the one before stays: ${error}`,
                FIXTURE_RELOAD_FAILURE_LOG_KEY);
            return;
        }
        const changedNames = changedFixtureNames(this._fixture, fixture);
        this._fixture = fixture;
        if (changedNames.length > 0)
            this._onChange(changedNames);
    }
}

/**
 * One run of the cockpit service: the sources, the layout config, the herdr client (or, in fixture mode, the fixture
 * alone), their D-Bus face, the bus name and the main loop, and their shutdown. It is the face's cockpit: it gives the
 * layout, the config error and the sources, tells its listeners of every change (a layout change as
 * COCKPIT_LAYOUT_CHANGE_NAME), passes the watch state on to the sources and focuses sessions.
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
        /** @type {CockpitFixture|null} What fixture mode serves; null outside it. */
        this._fixture = null;
        this._dbusService = null;
        this._busOwnerId = null;
        this._signalSourceIds = [];
        this._listenersById = new Map();
        this._nextListenerId = 1;
        this._hasOwnedName = false;
        this._isShuttingDown = false;
        this._exitStatus = EXIT_STATUS_SUCCESS;
    }

    /** @returns {object|null} The layout the config file (or the fixture) gives; null when it is missing or invalid. */
    get layout() {
        return this._fixture !== null ? this._fixture.layout : this._layoutConfig.layout;
    }

    /** @returns {string|null} Why the config file (or the fixture) gives no layout; null when it gives one. */
    get configError() {
        return this._fixture !== null ? this._fixture.configError : this._layoutConfig.configError;
    }

    /**
     * @returns {Object<string, object|null>} Each source's latest object by name, read from the sources (or the
     *     fixture) now.
     */
    get sourcesByName() {
        return this._fixture !== null ? this._fixture.sourcesByName : this._sources.sourcesByName;
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
     * @param {boolean} isWatched - Whether at least one client watches the cockpit; the sources' cadence follows it. A
     *     fixture has no cadence, so fixture mode ignores it.
     * @returns {void}
     */
    setWatched(isWatched) {
        if (this._fixture === null)
            this._sources.setWatched(isWatched);
    }

    /**
     * Brings a session's herdr pane to the front: finds the row with this id in the latest sessions sample, asks
     * herdr to focus its workspace (when the row has one), then its pane, with the ids the row carries, each request
     * bounded by HERDR_FOCUS_REQUEST_TIMEOUT_MS; then names
     * the windows that may show herdr's client (_readFocusWindowPidCandidates), for the shell to activate. windowPid
     * stays null: which of those windows to bring forward is the shell's to decide. In fixture mode it answers the
     * fixture's focusReply instead, whatever the id.
     *
     * @param {string} sessionId - A session row's id.
     * @returns {Promise<{focused: boolean, windowPid: null, error: string|null, windowPidCandidates: number[]}>}
     *     focused true once herdr focused the pane, with the window candidates; otherwise false with a code from
     *     COCKPIT_FOCUS_ERROR_CODES (unknown-session, no-pane, or the code FOCUS_ERROR_BY_HERDR_ERROR_CODE gives
     *     herdr's rejection, whose message is logged as `cockpit: focus: <id>: <message>`) and no candidates.
     * @throws {Error} (as a rejection) A failure that is not herdr's: a fault here, which the D-Bus face answers as
     *     internal.
     */
    async focusSession(sessionId) {
        if (this._fixture !== null)
            return this._fixture.focusReply;
        const sessionRow = this._latestSessionRow(sessionId);
        if (sessionRow === null)
            return focusFailureReply(COCKPIT_FOCUS_ERROR.UNKNOWN_SESSION);
        const paneId = stringOrNull(sessionRow.paneId);
        if (paneId === null)
            return focusFailureReply(COCKPIT_FOCUS_ERROR.NO_PANE);
        const workspaceId = stringOrNull(sessionRow.workspaceId);
        try {
            if (workspaceId !== null)
                await this._herdrClient.request(WORKSPACE_FOCUS_METHOD, {workspace_id: workspaceId},
                    FOCUS_REQUEST_OPTIONS);
            await this._herdrClient.request(PANE_FOCUS_METHOD, {pane_id: paneId}, FOCUS_REQUEST_OPTIONS);
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
        return {
            focused: true, windowPid: null, error: null, windowPidCandidates: this._readFocusWindowPidCandidates(),
        };
    }

    /**
     * Runs the service until it shuts down: in fixture mode when COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE names a file,
     * otherwise with the sources and the config.
     *
     * @returns {number} The process exit status.
     */
    run() {
        const fixturePath = cockpitFixturePathOrNull();
        const startFailure = fixturePath === null ? this._startSourcesAndConfig() : this._startFixture(fixturePath);
        if (startFailure !== null) {
            this._shutDown(startFailure, EXIT_STATUS_FAILURE);
            return this._exitStatus;
        }
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
     * Builds the herdr client, the sources and the layout config, and reads the config; the sources start once the
     * name is owned.
     *
     * @returns {null} Nothing stops this start.
     */
    _startSourcesAndConfig() {
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
        return null;
    }

    /**
     * Reads the fixture and watches it: fixture mode, with no source, no config and no herdr client.
     *
     * @param {string} fixturePath - The file COCKPIT_FIXTURE_ENVIRONMENT_VARIABLE names.
     * @returns {string|null} Why the fixture cannot be served, for the shutdown line; null once it is served.
     */
    _startFixture(fixturePath) {
        const fixture = new CockpitFixture({
            fixturePath,
            onChange: changedNames => this._notifyListeners(changedNames, this._fixture.sourcesByName),
            errorLog: this._errorLog,
        });
        const fixtureError = fixture.start();
        if (fixtureError !== null)
            return `cannot serve the fixture (${fixturePath}): ${fixtureError}`;
        this._fixture = fixture;
        return null;
    }

    /**
     * Names the windows that may show herdr's client: every process's stat line (readProcessStats), handed to
     * lib/processTree.js's focusWindowPidCandidates. It runs once herdr focused the pane, so nothing here may undo
     * that answer. A failure to read /proc leaves the candidates read so far, none at worst; a fault (any other
     * throw, from the scan or the builder) leaves none. Either is logged once per ERROR_LOG_REPEAT_INTERVAL_USEC as
     * `cockpit: focus: window candidates: <error>`.
     *
     * @returns {number[]} The candidates: each herdr client's pid and its parents', without pid 1.
     */
    _readFocusWindowPidCandidates() {
        let processStats;
        let windowPidCandidates;
        try {
            processStats = readProcessStats();
            windowPidCandidates = focusWindowPidCandidates(processStats.statByPid);
        } catch (error) {
            // Not IO, which readProcessStats keeps as readFailure, but a fault here: caught whatever it is, for the
            // reply must stay focused, naming no window, rather than become the face's internal error.
            this._logFocusWindowCandidatesFailure(describeErrorWithStack(error));
            return [];
        }
        if (processStats.readFailure !== null)
            this._logFocusWindowCandidatesFailure(describeError(processStats.readFailure));
        return windowPidCandidates;
    }

    /**
     * @param {string} failureText - What went wrong naming the window candidates.
     * @returns {void}
     */
    _logFocusWindowCandidatesFailure(failureText) {
        this._errorLog.log(`focus: window candidates: ${failureText}`, FOCUS_WINDOW_CANDIDATES_FAILURE_LOG_KEY);
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
     * Starts the sources once the name is owned; each samples at once. In fixture mode there are none, and the
     * fixture's path is logged beside the serving line.
     *
     * @returns {void}
     */
    _onNameAcquired() {
        if (this._isShuttingDown)
            return;
        this._hasOwnedName = true;
        this._sources?.start();
        console.log(`${COCKPIT_LOG_PREFIX} serving ${COCKPIT_BUS_NAME} (protocol ${COCKPIT_PROTOCOL_VERSION})`);
        if (this._fixture !== null)
            console.log(`${COCKPIT_LOG_PREFIX} serving a fixture (${this._fixture.fixturePath})`);
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
     * Stops everything once: the signal handlers, the D-Bus face, the config and fixture watches, the sources
     * (destroyed, never only stopped), the herdr client and the name, each whatever the others throw; then quits the
     * main loop. Each step is safe on what a start that failed never built.
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
            {name: 'stop watching the fixture', run: () => this._fixture?.destroy()},
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
