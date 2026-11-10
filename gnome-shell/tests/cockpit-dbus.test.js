// service/cockpitDbusService.js on a PRIVATE message bus, with a fake cockpit. Run only by run-private-bus.js under
// `dbus-run-session`, never by run.js. Every connection is opened by address through service-dbus.test.js's
// openPrivateBusConnection, which refuses anything but the private bus. The cockpit process itself
// (service/cockpit.js) runs in scripts/test-resource-pulse.sh's real-entry rows; here a FakeCockpit stands in for it.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {openPrivateBusConnection, waitUntil} from './service-dbus.test.js';
import {CockpitDBusService} from '../extensions/resource-pulse@dotfiles/service/cockpitDbusService.js';
import {parseCockpitConfig} from '../extensions/resource-pulse@dotfiles/lib/cockpitConfig.js';
import {
    COCKPIT_INTERFACE_NAME, COCKPIT_OBJECT_PATH, parseCockpitStatePayload, parseFocusSessionReply,
} from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';

const REPO_ROOT_URI = GLib.uri_resolve_relative(import.meta.url, '../../', GLib.UriFlags.NONE);
const [REPO_ROOT] = GLib.filename_from_uri(REPO_ROOT_URI);
const CONFIG_TEMPLATE_PATH = GLib.build_filenamev([REPO_ROOT, 'examples', 'resource-pulse-cockpit.json.template']);
const CALL_TIMEOUT_MS = 2000;
/** The design's budget for dropping a vanished caller's watch. */
const VANISHED_WATCH_DROP_TIMEOUT_MS = 2000;
const CHANGED_SIGNAL_TIMEOUT_MS = 2000;
const SERVICE_STARTED_AT_USEC = 1_794_000_000_000_000;
const SAMPLED_AT_USEC = 1_794_000_001_000_000;
/** A later sample of the same source: only its stamp differs. */
const RESAMPLED_AT_USEC = 1_794_000_031_000_000;
const PUBLISHED_AT_USEC = 1_794_000_002_000_000;
/** The wire names, written out rather than imported, so a renamed constant fails here instead of moving with it. */
const GET_STATE_METHOD = 'GetState';
const WATCH_COCKPIT_METHOD = 'WatchCockpit';
const UNWATCH_COCKPIT_METHOD = 'UnwatchCockpit';
const FOCUS_SESSION_METHOD = 'FocusSession';
const CHANGED_SIGNAL_NAME = 'Changed';
/** The pseudo-source name the cockpit process reports a layout change with. */
const LAYOUT_CHANGE_NAME = 'layout';
const SINGLE_STRING_TYPE = new GLib.VariantType('(s)');
const FOCUSABLE_SESSION_ID = 'wL:p1';
const UNKNOWN_SESSION_ID = 'wL:p99';
const UNKNOWN_SESSION_ERROR = 'unknown-session';
/** The code the face answers when the cockpit rejects or throws: its message goes to the journal alone. */
const INTERNAL_FOCUS_ERROR = 'internal';
/** A rejection that is not herdr's: the real cockpit answers herdr's rejections itself, so only a fault rejects. */
const FOCUS_FAULT_MESSAGE = 'sessionRows.find is not a function';
const CONFIG_MISSING_ERROR = 'missing';
/** What the stubbed emit throws, as GLib does on a closed connection. */
const EMIT_FAILURE_MESSAGE = 'The connection is closed';

/** The sessions source as the scheduler stores it, its fields in the reader's order so a round trip compares equal. */
const SESSIONS_SOURCE = {
    sampledAtUsec: SAMPLED_AT_USEC,
    intervalSeconds: 60,
    herdrRunning: true,
    totalMemoryBytes: 500_000_000,
    counts: {working: 1, blocked: 0, idle: 0, done: 0, unknown: 0},
    rows: [{
        id: FOCUSABLE_SESSION_ID, name: 'host-sync', state: 'working', idleSeconds: 12, idleFromProcessAge: false,
        memoryBytes: 500_000_000, workspaceId: 'wL', paneId: 'p1', account: 'work', contextPercent: 21,
    }],
};
const NETWORK_SOURCE = {
    sampledAtUsec: SAMPLED_AT_USEC,
    intervalSeconds: 10,
    uplink: {kind: 'wired', connectivity: 'full', wifiEnabled: false},
    vpn: {isUp: true, interfaceName: 'tun0'},
    sshMasterCount: 2,
};
const MOUNTS_SOURCE = {
    sampledAtUsec: SAMPLED_AT_USEC,
    intervalSeconds: 30,
    rows: [
        {mountPoint: '/media/user/USB', label: 'USB', kind: 'removable', filesystemType: 'vfat', freeBytes: 1_000,
            totalBytes: 2_000},
        {mountPoint: '/mnt/share', label: 'share', kind: 'network', filesystemType: 'cifs', freeBytes: null,
            totalBytes: null},
    ],
};

/**
 * Reads a file as text (tests may block).
 *
 * @param {string} path - Absolute path.
 * @returns {string} Its contents.
 */
function readText(path) {
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

/**
 * @returns {object} The layout the shipped config template gives.
 * @throws {Error} When the template does not parse: the rows would compare against nothing.
 */
function templateLayout() {
    const {layout, error} = parseCockpitConfig(readText(CONFIG_TEMPLATE_PATH));
    if (layout === null)
        throw new Error(`the config template does not parse: ${error}`);
    return layout;
}

/** Stands in for service/cockpit.js's CockpitServiceProcess: the surface the D-Bus face uses, plus a publish(). */
class FakeCockpit {
    /**
     * @param {object} state - What the cockpit holds.
     * @param {object|null} state.layout - The layout.
     * @param {string|null} state.configError - The config error.
     * @param {object} state.sourcesByName - Each source's latest object by name.
     */
    constructor({layout, configError, sourcesByName}) {
        this.layout = layout;
        this.configError = configError;
        this._sourcesByName = {...sourcesByName};
        /** @type {boolean[]} Every setWatched argument, in order. */
        this.watchedCalls = [];
        /** @type {string[]} Every id focusSession was given, in order. */
        this.focusedSessionIds = [];
        /** @type {Error|null} When set, focusSession rejects with it. */
        this.focusRejection = null;
        this._listenersById = new Map();
        this._nextListenerId = 1;
    }

    /** @returns {object} Each source's latest object by name: a new object on each read, as the scheduler gives. */
    get sourcesByName() {
        return {...this._sourcesByName};
    }

    /** @returns {number} How many listeners are attached. */
    get listenerCount() {
        return this._listenersById.size;
    }

    /**
     * Replaces one source's object without telling the listeners, as a sample that changed nothing but its stamp.
     *
     * @param {string} sourceName - The source.
     * @param {object} sourceObject - Its new object.
     * @returns {void}
     */
    replaceSource(sourceName, sourceObject) {
        this._sourcesByName[sourceName] = sourceObject;
    }

    /**
     * @param {(changedSourceNames: string[], sourcesByName: object) => void} listener - Called on each publish.
     * @returns {number} An id for removeListener.
     */
    addListener(listener) {
        const listenerId = this._nextListenerId++;
        this._listenersById.set(listenerId, listener);
        return listenerId;
    }

    /**
     * @param {number} listenerId - The id addListener returned.
     * @returns {void}
     */
    removeListener(listenerId) {
        this._listenersById.delete(listenerId);
    }

    /**
     * Records the call.
     *
     * @param {boolean} isWatched - True while any client holds a watch.
     * @returns {void}
     */
    setWatched(isWatched) {
        this.watchedCalls.push(isWatched);
    }

    /**
     * Records the id, and answers as the real cockpit does for a row it knows or one it does not.
     *
     * @param {string} sessionId - The session row's id.
     * @returns {Promise<{focused: boolean, windowPid: null, error: string|null}>} The reply; rejects with
     *     focusRejection when that is set.
     */
    focusSession(sessionId) {
        this.focusedSessionIds.push(sessionId);
        if (this.focusRejection !== null)
            return Promise.reject(this.focusRejection);
        const isKnownSession = this._sourcesByName.sessions?.rows?.some(row => row.id === sessionId) ?? false;
        const reply = isKnownSession
            ? {focused: true, windowPid: null, error: null}
            : {focused: false, windowPid: null, error: UNKNOWN_SESSION_ERROR};
        return Promise.resolve(reply);
    }

    /**
     * Tells every listener that these sources (or 'layout') changed, as the cockpit process does.
     *
     * @param {string[]} changedSourceNames - The changed sources' names.
     * @returns {void}
     */
    publish(changedSourceNames) {
        const sourcesByName = this.sourcesByName;
        for (const listener of [...this._listenersById.values()])
            listener(changedSourceNames, sourcesByName);
    }
}

/**
 * Exports a CockpitDBusService for a FakeCockpit on its own connection, runs a row against it, and closes every
 * connection the row opened whatever happens.
 *
 * @param {(fixture: object) => Promise<void>} body - The row; gets {cockpit, service, serviceName, openClient,
 *     logLines}, logLines being every line the service wrote to its log.
 * @returns {Promise<void>}
 */
async function withExportedCockpit(body) {
    const cockpit = new FakeCockpit({
        layout: templateLayout(),
        configError: null,
        sourcesByName: {sessions: SESSIONS_SOURCE, network: NETWORK_SOURCE, mounts: MOUNTS_SOURCE},
    });
    const serviceConnection = openPrivateBusConnection();
    const clientConnections = [];
    const logLines = [];
    let service = null;
    try {
        service = new CockpitDBusService(cockpit, serviceConnection, {
            serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
            nowRealUsec: () => PUBLISHED_AT_USEC,
            logWriter: line => logLines.push(line),
        });
        await body({
            cockpit,
            service,
            logLines,
            serviceName: serviceConnection.get_unique_name(),
            openClient: () => {
                const clientConnection = openPrivateBusConnection();
                clientConnections.push(clientConnection);
                return clientConnection;
            },
        });
    } finally {
        service?.destroy();
        for (const connection of [...clientConnections, serviceConnection]) {
            if (!connection.is_closed())
                connection.close_sync(null);
        }
    }
}

/**
 * Calls a method of the cockpit's interface.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @param {string} serviceName - The service connection's unique name.
 * @param {string} methodName - The method.
 * @param {object} [call] - Its arguments and reply.
 * @param {GLib.Variant|null} [call.parameters] - The arguments, or null for none.
 * @param {GLib.VariantType|null} [call.replyType] - The reply's type, or null for none.
 * @returns {Promise<GLib.Variant>} The reply; rejects with the D-Bus error.
 */
function callCockpitMethod(connection, serviceName, methodName, {parameters = null, replyType = null} = {}) {
    return new Promise((resolve, reject) => {
        connection.call(serviceName, COCKPIT_OBJECT_PATH, COCKPIT_INTERFACE_NAME, methodName, parameters, replyType,
            Gio.DBusCallFlags.NONE, CALL_TIMEOUT_MS, null, (callingConnection, result) => {
                try {
                    resolve(callingConnection.call_finish(result));
                } catch (error) {
                    reject(error);
                }
            });
    });
}

/**
 * Calls GetState and parses its JSON.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @param {string} serviceName - The service connection's unique name.
 * @returns {Promise<object|null>} parseCockpitStatePayload's result.
 */
async function fetchState(connection, serviceName) {
    const reply = await callCockpitMethod(connection, serviceName, GET_STATE_METHOD, {replyType: SINGLE_STRING_TYPE});
    const [stateText] = reply.deepUnpack();
    return parseCockpitStatePayload(stateText);
}

/**
 * Calls FocusSession and gives its reply's JSON text, or the D-Bus error's message.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @param {string} serviceName - The service connection's unique name.
 * @param {string} sessionId - The id to focus.
 * @returns {Promise<{replyText: string|null, dbusError: string|null}>} Exactly one of the two set.
 */
async function callFocusSession(connection, serviceName, sessionId) {
    const parameters = new GLib.Variant('(s)', [sessionId]);
    try {
        const reply = await callCockpitMethod(connection, serviceName, FOCUS_SESSION_METHOD,
            {parameters, replyType: SINGLE_STRING_TYPE});
        const [replyText] = reply.deepUnpack();
        return {replyText, dbusError: null};
    } catch (error) {
        return {replyText: null, dbusError: error.message};
    }
}

/**
 * Collects the Changed signals a connection receives from the service, as their raw JSON parsed, until stopped.
 * Raw, not through parseChangedPayload, so a row can tell a field written as null from one left out.
 *
 * @param {Gio.DBusConnection} connection - The listener.
 * @param {string} serviceName - The service connection's unique name.
 * @returns {{changes: object[], stop: () => void}} The changes so far, and a way to unsubscribe.
 */
function collectChanges(connection, serviceName) {
    const changes = [];
    const subscriptionId = connection.signal_subscribe(serviceName, COCKPIT_INTERFACE_NAME, CHANGED_SIGNAL_NAME,
        COCKPIT_OBJECT_PATH, null, Gio.DBusSignalFlags.NONE, (...signalArguments) => {
            const [changedText] = signalArguments.at(-1).deepUnpack();
            changes.push(JSON.parse(changedText));
        });
    return {changes, stop: () => connection.signal_unsubscribe(subscriptionId)};
}

/**
 * Publishes a change and collects what the client receives for it: the Changed signals up to a GetState round trip
 * after the first one arrived, which every signal the publish emitted precedes.
 *
 * @param {object} fixture - withExportedCockpit's fixture.
 * @param {string[]} changedSourceNames - What the cockpit reports as changed.
 * @returns {Promise<{didArrive: boolean, changes: object[], state: object|null}>} The signals and the state after.
 */
async function publishAndCollect({cockpit, serviceName, openClient}, changedSourceNames) {
    const clientConnection = openClient();
    const changeCollector = collectChanges(clientConnection, serviceName);
    // A round trip first, so the subscription is in place on the bus before anything is published.
    await fetchState(clientConnection, serviceName);
    cockpit.publish(changedSourceNames);
    const didArrive = await waitUntil(() => changeCollector.changes.length >= 1, CHANGED_SIGNAL_TIMEOUT_MS);
    const state = await fetchState(clientConnection, serviceName);
    changeCollector.stop();
    return {didArrive, changes: changeCollector.changes, state};
}

test('cockpit-dbus: GetState answers the layout and every source', () =>
    withExportedCockpit(async ({serviceName, openClient}) => {
        const state = await fetchState(openClient(), serviceName);
        assertEqual({state, mountRowCount: state?.sources?.mounts?.rows?.length}, {
            state: {
                protocol: 1,
                serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
                latestPublishedAtUsec: SERVICE_STARTED_AT_USEC,
                layout: templateLayout(),
                configError: null,
                sources: {sessions: SESSIONS_SOURCE, network: NETWORK_SOURCE, mounts: MOUNTS_SOURCE},
            },
            mountRowCount: 2,
        });
    }));

test('cockpit-dbus: GetState answers each source as it is when called, a resample that changed nothing included',
    () => withExportedCockpit(async ({cockpit, serviceName, openClient}) => {
        const clientConnection = openClient();
        const stampBefore = (await fetchState(clientConnection, serviceName))?.sources?.mounts?.sampledAtUsec;
        cockpit.replaceSource('mounts', {...MOUNTS_SOURCE, sampledAtUsec: RESAMPLED_AT_USEC});
        const stampAfter = (await fetchState(clientConnection, serviceName))?.sources?.mounts?.sampledAtUsec;
        assertEqual({stampBefore, stampAfter}, {stampBefore: SAMPLED_AT_USEC, stampAfter: RESAMPLED_AT_USEC});
    }));

test('cockpit-dbus: a listener call becomes one Changed naming only the changed sources', () =>
    withExportedCockpit(async fixture => {
        const {didArrive, changes, state} = await publishAndCollect(fixture, ['network']);
        assertEqual({didArrive, changes, latestPublishedAtUsec: state?.latestPublishedAtUsec}, {
            didArrive: true,
            changes: [{publishedAtUsec: PUBLISHED_AT_USEC, sources: {network: NETWORK_SOURCE}}],
            latestPublishedAtUsec: PUBLISHED_AT_USEC,
        });
    }));

test('cockpit-dbus: a Changed whose emit throws leaves GetState\'s latest publish time where it was', () =>
    withExportedCockpit(async ({cockpit, service, serviceName, openClient}) => {
        // The exported object's emit, replaced on this one instance: the only way to make a live emit throw while
        // GetState can still be asked over the same connection.
        service._exportedObject.emit_signal = () => {
            throw new Error(EMIT_FAILURE_MESSAGE);
        };
        let publishError = null;
        try {
            cockpit.publish(['network']);
        } catch (error) {
            publishError = error.message;
        }
        const state = await fetchState(openClient(), serviceName);
        assertEqual({publishError, latestPublishedAtUsec: state?.latestPublishedAtUsec},
            {publishError: EMIT_FAILURE_MESSAGE, latestPublishedAtUsec: SERVICE_STARTED_AT_USEC});
    }));

test('cockpit-dbus: a layout change becomes one Changed carrying the layout and the config error beside no source',
    () => withExportedCockpit(async fixture => {
        fixture.cockpit.layout = null;
        fixture.cockpit.configError = CONFIG_MISSING_ERROR;
        const {didArrive, changes, state} = await publishAndCollect(fixture, [LAYOUT_CHANGE_NAME]);
        assertEqual({didArrive, changes, stateLayout: state?.layout, stateConfigError: state?.configError}, {
            didArrive: true,
            changes: [{publishedAtUsec: PUBLISHED_AT_USEC, layout: null, configError: CONFIG_MISSING_ERROR,
                sources: {}}],
            stateLayout: null,
            stateConfigError: CONFIG_MISSING_ERROR,
        });
    }));

test('cockpit-dbus: WatchCockpit is counted per caller and dropped when the caller vanishes', () =>
    withExportedCockpit(async ({cockpit, service, serviceName, openClient}) => {
        const vanishingConnection = openClient();
        const unwatchingConnection = openClient();
        await callCockpitMethod(vanishingConnection, serviceName, WATCH_COCKPIT_METHOD);
        await callCockpitMethod(vanishingConnection, serviceName, WATCH_COCKPIT_METHOD);
        await callCockpitMethod(unwatchingConnection, serviceName, WATCH_COCKPIT_METHOD);
        const countWithBoth = service.watchCount;
        await callCockpitMethod(unwatchingConnection, serviceName, UNWATCH_COCKPIT_METHOD);
        const countAfterUnwatch = service.watchCount;
        const callsWhileWatched = [...cockpit.watchedCalls];
        vanishingConnection.close_sync(null);
        const didDrop = await waitUntil(() => service.watchCount === 0, VANISHED_WATCH_DROP_TIMEOUT_MS);
        assertEqual({countWithBoth, countAfterUnwatch, callsWhileWatched, didDrop, calls: cockpit.watchedCalls}, {
            countWithBoth: 3, countAfterUnwatch: 2, callsWhileWatched: [true], didDrop: true, calls: [true, false],
        });
    }));

test('cockpit-dbus: FocusSession hands the id to the cockpit and answers its reply', () =>
    withExportedCockpit(async ({cockpit, serviceName, openClient}) => {
        const {replyText, dbusError} = await callFocusSession(openClient(), serviceName, FOCUSABLE_SESSION_ID);
        assertEqual({reply: parseFocusSessionReply(replyText), dbusError, ids: cockpit.focusedSessionIds},
            {reply: {focused: true, windowPid: null, error: null}, dbusError: null, ids: [FOCUSABLE_SESSION_ID]});
    }));

test('cockpit-dbus: FocusSession with an unknown id answers focused false and its code, not a D-Bus error', () =>
    withExportedCockpit(async ({cockpit, serviceName, openClient}) => {
        const {replyText, dbusError} = await callFocusSession(openClient(), serviceName, UNKNOWN_SESSION_ID);
        assertEqual({reply: parseFocusSessionReply(replyText), dbusError, ids: cockpit.focusedSessionIds}, {
            reply: {focused: false, windowPid: null, error: UNKNOWN_SESSION_ERROR},
            dbusError: null,
            ids: [UNKNOWN_SESSION_ID],
        });
    }));

test('cockpit-dbus: a FocusSession the cockpit rejects answers focused false and the code internal, not a D-Bus ' +
    'error nor its message, which is logged', () => withExportedCockpit(async ({cockpit, logLines, serviceName,
    openClient}) => {
    cockpit.focusRejection = new Error(FOCUS_FAULT_MESSAGE);
    const {replyText, dbusError} = await callFocusSession(openClient(), serviceName, FOCUSABLE_SESSION_ID);
    assertEqual(String(replyText).includes(FOCUS_FAULT_MESSAGE), false, 'the message of the fault stays off the bus');
    assertEqual({reply: parseFocusSessionReply(replyText), dbusError, logLines}, {
        reply: {focused: false, windowPid: null, error: INTERNAL_FOCUS_ERROR},
        dbusError: null,
        logLines: [`cockpit: FocusSession failed: ${FOCUS_FAULT_MESSAGE}`],
    });
}));

test('cockpit-dbus: destroy() unexports the object and detaches from the cockpit', () =>
    withExportedCockpit(async ({cockpit, service, serviceName, openClient}) => {
        const clientConnection = openClient();
        const listenersBefore = cockpit.listenerCount;
        service.destroy();
        let callError = null;
        try {
            await fetchState(clientConnection, serviceName);
        } catch (error) {
            callError = error;
        }
        const isUnknownMethodOrObject = callError instanceof GLib.Error &&
            (callError.matches(Gio.DBusError, Gio.DBusError.UNKNOWN_METHOD) ||
             callError.matches(Gio.DBusError, Gio.DBusError.UNKNOWN_OBJECT));
        assertEqual({listenersBefore, listenersAfter: cockpit.listenerCount, isUnknownMethodOrObject},
            {listenersBefore: 1, listenersAfter: 0, isUnknownMethodOrObject: true});
    }));
