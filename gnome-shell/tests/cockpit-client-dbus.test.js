// cockpitClient.js with its REAL defaults (a Gio.DBusProxy, the StartUnit call, the unit read over systemd's D-Bus) on
// a PRIVATE message bus. Run only by run-private-bus.js under `dbus-run-session`, never by run.js. Every connection is
// opened by address through service-dbus.test.js's openPrivateBusConnection, which refuses anything but the private
// bus. The service side is the real service/cockpitDbusService.js over a FakeCockpit (a copy of cockpit-dbus.test.js's,
// trimmed to what these rows drive), owning the real bus name; systemd's side is either absent (nothing owns
// org.freedesktop.systemd1 here) or a fake Manager and Unit that answer StartUnit, GetUnit and the unit's properties.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {openPrivateBusConnection, waitUntil} from './service-dbus.test.js';
import {CockpitClient} from '../extensions/resource-pulse@dotfiles/cockpitClient.js';
import {CockpitDBusService} from '../extensions/resource-pulse@dotfiles/service/cockpitDbusService.js';
import {COCKPIT_BUS_NAME} from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';

const BUS_ROUND_TRIP_TIMEOUT_MS = 2000;
const SERVICE_STARTED_AT_USEC = 1_794_000_000_000_000;
const SAMPLED_AT_USEC = 1_794_000_001_000_000;
const RESAMPLED_AT_USEC = 1_794_000_031_000_000;
const PUBLISHED_AT_USEC = 1_794_000_002_000_000;
/** The wire names, written out rather than imported, so a renamed constant fails here instead of moving with it. */
const COCKPIT_OBJECT_PATH = '/io/github/quantivly/dotfiles/Cockpit1';
const COCKPIT_INTERFACE_NAME = 'io.github.quantivly.dotfiles.Cockpit1';
const GET_STATE_METHOD = 'GetState';
/** CockpitClientState's values, written out. */
const LIVE = 'live';
const SKIPPED = 'skipped';
const STARTING = 'starting';
const FOCUSABLE_SESSION_ID = 'wL:p1';
const UNKNOWN_SESSION_ID = 'wL:p99';
/** The windows the cockpit names for a focused session: a herdr client, then its terminal. */
const WINDOW_PID_CANDIDATES = [4242, 4100];
const UNKNOWN_SESSION_ERROR = 'unknown-session';
/** START_CONFIRMATION_TIMEOUT_SECONDS and the first of START_RETRY_DELAYS_SECONDS, written out. */
const START_CONFIRMATION_SECONDS = 15;
const FIRST_RETRY_DELAY_SECONDS = 5;
const SYSTEMD_BUS_NAME = 'org.freedesktop.systemd1';
const SYSTEMD_OBJECT_PATH = '/org/freedesktop/systemd1';
const SYSTEMD_MANAGER_INTERFACE_NAME = 'org.freedesktop.systemd1.Manager';
const SYSTEMD_UNIT_INTERFACE_NAME = 'org.freedesktop.systemd1.Unit';
/** Where systemd serves cockpit.service: its name, bus-escaped ('.' is _2e). */
const COCKPIT_UNIT_PATH = '/org/freedesktop/systemd1/unit/cockpit_2eservice';
const START_UNIT_JOB_PATH = '/org/freedesktop/systemd1/job/1';
const NO_SUCH_UNIT_ERROR_NAME = 'org.freedesktop.systemd1.NoSuchUnit';
/** systemd's Manager as the client uses it: StartUnit and GetUnit. */
const SYSTEMD_MANAGER_INTERFACE_XML = `<node>
  <interface name="${SYSTEMD_MANAGER_INTERFACE_NAME}">
    <method name="StartUnit">
      <arg name="name" type="s" direction="in"/>
      <arg name="mode" type="s" direction="in"/>
      <arg name="job" type="o" direction="out"/>
    </method>
    <method name="GetUnit">
      <arg name="name" type="s" direction="in"/>
      <arg name="unit" type="o" direction="out"/>
    </method>
  </interface>
</node>`;
/** The three properties of systemd's Unit interface the client reads, with systemd's types. */
const SYSTEMD_UNIT_INTERFACE_XML = `<node>
  <interface name="${SYSTEMD_UNIT_INTERFACE_NAME}">
    <property name="ConditionResult" type="b" access="read"/>
    <property name="ConditionTimestampMonotonic" type="t" access="read"/>
    <property name="ActiveState" type="s" access="read"/>
  </interface>
</node>`;
/** What the fake systemd says of a unit its start job skipped: the condition false, checked 5 s after boot. */
const SKIPPED_UNIT_PROPERTIES = {
    ConditionResult: false, ConditionTimestampMonotonic: 5_000_000, ActiveState: 'inactive',
};

/** The layout the cockpit holds, in parseLayout's shape so a round trip compares equal. */
const LAYOUT = {
    monitor: {vendor: 'DEL', product: 'DELL U2723QE'},
    groups: [{id: 'machine', caption: 'MACHINE', columns: 2, cards: ['system', 'apps', 'connections', 'sessions']}],
};
/** Each source as the scheduler stores it, its fields in the reader's order so a round trip compares equal. */
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
    rows: [{
        mountPoint: '/media/user/USB', label: 'USB', kind: 'removable', filesystemType: 'vfat', freeBytes: 1_000,
        totalBytes: 2_000,
    }],
};
const RESAMPLED_MOUNTS_SOURCE = {...MOUNTS_SOURCE, sampledAtUsec: RESAMPLED_AT_USEC, rows: []};
const SOURCES = {sessions: SESSIONS_SOURCE, network: NETWORK_SOURCE, mounts: MOUNTS_SOURCE};

/** Stands in for service/cockpit.js's CockpitServiceProcess: the surface the D-Bus face uses, plus a publish(). */
class FakeCockpit {
    constructor() {
        this.layout = LAYOUT;
        this.configError = null;
        this._sourcesByName = {...SOURCES};
        /** @type {boolean[]} Every setWatched argument, in order. */
        this.watchedCalls = [];
        this._listenersById = new Map();
        this._nextListenerId = 1;
    }

    /** @returns {object} Each source's latest object by name: a new object on each read, as the scheduler gives. */
    get sourcesByName() {
        return {...this._sourcesByName};
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
     * Answers as the real cockpit does for a row it knows or one it does not.
     *
     * @param {string} sessionId - The session row's id.
     * @returns {Promise<{focused: boolean, windowPid: null, error: string|null, windowPidCandidates: number[]}>} The
     *     reply.
     */
    focusSession(sessionId) {
        const isKnownSession = this._sourcesByName.sessions.rows.some(row => row.id === sessionId);
        const reply = isKnownSession
            ? {focused: true, windowPid: null, error: null, windowPidCandidates: WINDOW_PID_CANDIDATES}
            : {focused: false, windowPid: null, error: UNKNOWN_SESSION_ERROR, windowPidCandidates: []};
        return Promise.resolve(reply);
    }

    /**
     * Replaces one source's object and tells every listener it changed, as the cockpit process does.
     *
     * @param {string} sourceName - The source.
     * @param {object} sourceObject - Its new object.
     * @returns {void}
     */
    publishSource(sourceName, sourceObject) {
        this._sourcesByName[sourceName] = sourceObject;
        const sourcesByName = this.sourcesByName;
        for (const listener of [...this._listenersById.values()])
            listener([sourceName], sourcesByName);
    }
}

/** Fake GLib timeouts, so a row can let the 15 s confirmation wait run out at once. */
class FakeTimeouts {
    constructor() {
        this._sourcesById = new Map();
        this._nextSourceId = 1;
    }

    /**
     * @param {number} intervalSeconds - Seconds until the callback.
     * @param {() => boolean} callback - Returns GLib.SOURCE_CONTINUE or GLib.SOURCE_REMOVE.
     * @returns {number} The source id.
     */
    addSeconds(intervalSeconds, callback) {
        const sourceId = this._nextSourceId++;
        this._sourcesById.set(sourceId, {intervalSeconds, callback});
        return sourceId;
    }

    /**
     * @param {number} sourceId - An id addSeconds returned.
     * @returns {void}
     */
    remove(sourceId) {
        this._sourcesById.delete(sourceId);
    }

    /** @returns {number[]} The intervals of the pending sources, smallest first. */
    pendingIntervalsSeconds() {
        return [...this._sourcesById.values()].map(source => source.intervalSeconds).sort((a, b) => a - b);
    }

    /**
     * Runs the one pending source with this interval, as GLib would when it is due.
     *
     * @param {number} intervalSeconds - Its interval.
     * @returns {void}
     * @throws {Error} Unless exactly one pending source has that interval.
     */
    fire(intervalSeconds) {
        const matchingEntries = [...this._sourcesById]
            .filter(([, source]) => source.intervalSeconds === intervalSeconds);
        if (matchingEntries.length !== 1)
            throw new Error(`${matchingEntries.length} pending sources of ${intervalSeconds} s, not one`);
        const [[sourceId, source]] = matchingEntries;
        if (source.callback() !== GLib.SOURCE_CONTINUE)
            this._sourcesById.delete(sourceId);
    }
}

/**
 * Owns a name on a connection and waits until the bus says it is owned.
 *
 * @param {Gio.DBusConnection} connection - The owner.
 * @param {string} busName - The well-known name.
 * @returns {Promise<{ownerId: number, isOwned: boolean}>} The id for Gio.bus_unown_name, and whether it was owned in
 *     time.
 */
async function ownName(connection, busName) {
    let isOwned = false;
    const ownerId = Gio.bus_own_name_on_connection(connection, busName, Gio.BusNameOwnerFlags.NONE,
        () => {
            isOwned = true;
        }, null);
    await waitUntil(() => isOwned, BUS_ROUND_TRIP_TIMEOUT_MS);
    return {ownerId, isOwned};
}

/**
 * Closes the connections a row opened that are still open.
 *
 * @param {Gio.DBusConnection[]} connections - The connections.
 * @returns {void}
 */
function closeConnections(connections) {
    for (const connection of connections) {
        if (!connection.is_closed())
            connection.close_sync(null);
    }
}

/**
 * Calls GetState on the cockpit's name from a connection and waits for the answer: every signal the service sent that
 * connection before has then been received, and its handlers run.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @returns {Promise<boolean>} True once answered; false on an error.
 */
function roundTripToCockpit(connection) {
    return new Promise(resolve => {
        connection.call(COCKPIT_BUS_NAME, COCKPIT_OBJECT_PATH, COCKPIT_INTERFACE_NAME, GET_STATE_METHOD, null, null,
            Gio.DBusCallFlags.NONE, BUS_ROUND_TRIP_TIMEOUT_MS, null, (callingConnection, result) => {
                try {
                    callingConnection.call_finish(result);
                } catch {
                    resolve(false);
                    return;
                }
                resolve(true);
            });
    });
}

/**
 * Builds a client with its real defaults on a private bus connection, recording what it logs and its events.
 *
 * @param {Gio.DBusConnection} connection - The client's connection.
 * @param {object} [overrides] - Constructor options to use instead of the real ones (timeouts).
 * @returns {{client: CockpitClient, events: object[], logged: string[], infoLines: string[]}} The client, started.
 */
function startClient(connection, overrides = {}) {
    const logged = [];
    const infoLines = [];
    const client = new CockpitClient({
        connection,
        errorLog: new RateLimitedLogger({nowUsec: () => GLib.get_monotonic_time(), write: line => logged.push(line)}),
        writeInfoLine: line => infoLines.push(line),
        ...overrides,
    });
    const events = [];
    client.addListener(event => events.push(event));
    client.start();
    return {client, events, logged, infoLines};
}

/**
 * Serves the Cockpit1 interface for a FakeCockpit under the real bus name on the private bus, starts a client with its
 * real defaults (no systemd here, so its StartUnit fails), waits for it to be LIVE, runs a row, and takes it all down
 * whatever happens.
 *
 * @param {(fixture: object) => Promise<void>} body - The row; gets {cockpit, service, clientConnection, client, events,
 *     isNameOwned, isLive}.
 * @returns {Promise<void>}
 */
async function withLiveCockpitClient(body) {
    const cockpit = new FakeCockpit();
    const serviceConnection = openPrivateBusConnection();
    const clientConnection = openPrivateBusConnection();
    let service = null;
    let ownerId = null;
    let client = null;
    try {
        service = new CockpitDBusService(cockpit, serviceConnection,
            {serviceStartedAtUsec: SERVICE_STARTED_AT_USEC, nowRealUsec: () => PUBLISHED_AT_USEC, logWriter: () => {}});
        const ownership = await ownName(serviceConnection, COCKPIT_BUS_NAME);
        ownerId = ownership.ownerId;
        const started = startClient(clientConnection);
        client = started.client;
        const isLive = await waitUntil(() => client.state === LIVE, BUS_ROUND_TRIP_TIMEOUT_MS);
        await body({
            cockpit, service, clientConnection, client, events: started.events, isNameOwned: ownership.isOwned, isLive,
        });
    } finally {
        client?.destroy();
        if (ownerId !== null)
            Gio.bus_unown_name(ownerId);
        service?.destroy();
        closeConnections([clientConnection, serviceConnection]);
    }
}

/**
 * Serves a fake systemd (Manager and cockpit.service's Unit) under its real name on the private bus, starts a client
 * whose timeouts a row fires, lets its accepted StartUnit's 15 s wait run out (nothing owns the cockpit's name), and
 * runs a row on what follows; takes it all down whatever happens.
 *
 * @param {object} systemd - How the fake systemd answers.
 * @param {object} systemd.unitProperties - The Unit's ConditionResult, ConditionTimestampMonotonic and ActiveState.
 * @param {boolean} systemd.isUnitLoaded - False to answer GetUnit with NoSuchUnit, as for a unit not loaded.
 * @param {(fixture: object) => Promise<void>} body - The row; gets {client, events, infoLines, timeouts,
 *     startUnitCalls, getUnitCalls, isNameOwned, isWaitingForService}.
 * @returns {Promise<void>}
 */
async function withAcceptedStartAndNoService({unitProperties, isUnitLoaded}, body) {
    const systemdConnection = openPrivateBusConnection();
    const clientConnection = openPrivateBusConnection();
    const startUnitCalls = [];
    const getUnitCalls = [];
    const exportedManager = Gio.DBusExportedObject.wrapJSObject(SYSTEMD_MANAGER_INTERFACE_XML, {
        StartUnit: (unitName, mode) => {
            startUnitCalls.push({unitName, mode});
            return START_UNIT_JOB_PATH;
        },
        GetUnitAsync: ([unitName], invocation) => {
            getUnitCalls.push(unitName);
            if (isUnitLoaded)
                invocation.return_value(new GLib.Variant('(o)', [COCKPIT_UNIT_PATH]));
            else
                invocation.return_dbus_error(NO_SUCH_UNIT_ERROR_NAME, `Unit ${unitName} not loaded.`);
        },
    });
    const exportedUnit = Gio.DBusExportedObject.wrapJSObject(SYSTEMD_UNIT_INTERFACE_XML, {...unitProperties});
    let ownerId = null;
    let client = null;
    try {
        exportedManager.export(systemdConnection, SYSTEMD_OBJECT_PATH);
        exportedUnit.export(systemdConnection, COCKPIT_UNIT_PATH);
        const ownership = await ownName(systemdConnection, SYSTEMD_BUS_NAME);
        ownerId = ownership.ownerId;
        const timeouts = new FakeTimeouts();
        const started = startClient(clientConnection, {timeouts});
        client = started.client;
        const isWaitingForService = await waitUntil(
            () => timeouts.pendingIntervalsSeconds().includes(START_CONFIRMATION_SECONDS), BUS_ROUND_TRIP_TIMEOUT_MS);
        if (isWaitingForService)
            timeouts.fire(START_CONFIRMATION_SECONDS);
        await body({
            client, timeouts, startUnitCalls, getUnitCalls, events: started.events, infoLines: started.infoLines,
            isNameOwned: ownership.isOwned, isWaitingForService,
        });
    } finally {
        client?.destroy();
        if (ownerId !== null)
            Gio.bus_unown_name(ownerId);
        exportedUnit.unexport();
        exportedManager.unexport();
        closeConnections([clientConnection, systemdConnection]);
    }
}

test('cockpit client on a private bus with no systemd: StartUnit fails, yet it follows the cockpit\'s name and its ' +
    'GetState makes it LIVE with the layout and every source', () =>
    withLiveCockpitClient(async ({client, events, isNameOwned, isLive}) => {
        assertEqual({
            isNameOwned, isLive, layout: client.layout, configError: client.configError,
            sourcesByName: client.sourcesByName, eventTypes: events.map(event => event.type),
        }, {
            isNameOwned: true, isLive: true, layout: LAYOUT, configError: null, sourcesByName: SOURCES,
            eventTypes: ['state', 'layout', 'sources'],
        });
    }));

test('cockpit client on a private bus: one Changed naming mounts becomes one sources event naming mounts, and the ' +
    'source is replaced', () =>
    withLiveCockpitClient(async ({cockpit, clientConnection, client, events}) => {
        // A round trip first, so the proxy's signal subscription is in place on the bus before anything is published.
        await roundTripToCockpit(clientConnection);
        const eventCountBefore = events.length;
        cockpit.publishSource('mounts', RESAMPLED_MOUNTS_SOURCE);
        const didArrive = await waitUntil(() => events.length > eventCountBefore, BUS_ROUND_TRIP_TIMEOUT_MS);
        // Every signal the publish sent arrives before this answer.
        const isRoundTripDone = await roundTripToCockpit(clientConnection);
        assertEqual({
            didArrive, isRoundTripDone, eventsAfter: events.slice(eventCountBefore),
            mounts: client.sourcesByName.mounts,
        }, {
            didArrive: true, isRoundTripDone: true, eventsAfter: [{type: 'sources', names: ['mounts']}],
            mounts: RESAMPLED_MOUNTS_SOURCE,
        });
    }));

test('cockpit client on a private bus: the watch is counted on the service while wanted, and destroy() releases it ' +
    'although the connection stays open, as the shell\'s does', () =>
    withLiveCockpitClient(async ({cockpit, service, clientConnection, client}) => {
        client.setWatchWanted(true);
        const isWatched = await waitUntil(() => service.watchCount === 1, BUS_ROUND_TRIP_TIMEOUT_MS);
        client.destroy();
        const isReleased = await waitUntil(() => service.watchCount === 0, BUS_ROUND_TRIP_TIMEOUT_MS);
        assertEqual({
            isWatched, isReleased, watchedCalls: cockpit.watchedCalls, isConnectionOpen: !clientConnection.is_closed(),
        }, {isWatched: true, isReleased: true, watchedCalls: [true, false], isConnectionOpen: true});
    }));

test('cockpit client on a private bus: focusSession sends the id and resolves to the parsed reply, a known row\'s ' +
    'candidates and an unknown row\'s code', () =>
    withLiveCockpitClient(async ({client}) => {
        const knownReply = await client.focusSession(FOCUSABLE_SESSION_ID);
        const unknownReply = await client.focusSession(UNKNOWN_SESSION_ID);
        assertEqual({knownReply, unknownReply}, {
            knownReply: {focused: true, windowPid: null, error: null, windowPidCandidates: WINDOW_PID_CANDIDATES},
            unknownReply: {focused: false, windowPid: null, error: UNKNOWN_SESSION_ERROR, windowPidCandidates: []},
        });
    }));

test('cockpit client on a private bus: an accepted StartUnit("cockpit.service", "replace") with no name in 15 s ' +
    'reads the unit over systemd\'s D-Bus (GetUnit, then its properties), and a skipped unit makes it SKIPPED', () =>
    withAcceptedStartAndNoService({unitProperties: SKIPPED_UNIT_PROPERTIES, isUnitLoaded: true},
        async ({client, timeouts, startUnitCalls, getUnitCalls, infoLines, isNameOwned, isWaitingForService}) => {
            const isSkipped = await waitUntil(() => client.state === SKIPPED, BUS_ROUND_TRIP_TIMEOUT_MS);
            assertEqual({
                isNameOwned, isWaitingForService, isSkipped, startUnitCalls, getUnitCalls,
                pending: timeouts.pendingIntervalsSeconds(), infoLineCount: infoLines.length,
            }, {
                isNameOwned: true, isWaitingForService: true, isSkipped: true,
                startUnitCalls: [{unitName: 'cockpit.service', mode: 'replace'}], getUnitCalls: ['cockpit.service'],
                pending: [], infoLineCount: 1,
            });
        }));

test('cockpit client on a private bus: a unit systemd does not have loaded (GetUnit answers NoSuchUnit) reads as ' +
    'nothing known, so the retry chain goes on', () =>
    withAcceptedStartAndNoService({unitProperties: SKIPPED_UNIT_PROPERTIES, isUnitLoaded: false},
        async ({client, timeouts, getUnitCalls, isWaitingForService}) => {
            const isRetryPending = await waitUntil(
                () => timeouts.pendingIntervalsSeconds().includes(FIRST_RETRY_DELAY_SECONDS),
                BUS_ROUND_TRIP_TIMEOUT_MS);
            assertEqual({isWaitingForService, isRetryPending, getUnitCalls, state: client.state},
                {isWaitingForService: true, isRetryPending: true, getUnitCalls: ['cockpit.service'], state: STARTING});
        }));
