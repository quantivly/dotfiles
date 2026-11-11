// cockpitClient.js with its REAL defaults (serviceLink.js's name watch, Changed subscription and calls, as
// createCockpitLink makes them; the StartUnit call; the unit read over systemd's D-Bus) on a PRIVATE message bus, and
// the cockpit's link on its own. Run only by run-private-bus.js under `dbus-run-session`, never by run.js. Every
// connection is opened by address through service-dbus.test.js's openPrivateBusConnection, which refuses anything but
// the private bus. The service side is the real service/cockpitDbusService.js over a FakeCockpit (a copy of
// cockpit-dbus.test.js's, trimmed to what these rows drive), owning the real bus name; systemd's side is either absent
// (nothing owns org.freedesktop.systemd1 here) or a fake Manager and Unit that answer StartUnit, GetUnit and the unit's
// properties.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {openPrivateBusConnection, waitUntil} from './service-dbus.test.js';
import {CockpitClient, createCockpitLink} from '../extensions/resource-pulse@dotfiles/cockpitClient.js';
import {CockpitDBusService} from '../extensions/resource-pulse@dotfiles/service/cockpitDbusService.js';
import {COCKPIT_BUS_NAME, parseFocusSessionReply} from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';
import {DBUS_CALL_TIMEOUT_MS} from '../extensions/resource-pulse@dotfiles/lib/constants.js';
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
const FOCUS_SESSION_METHOD = 'FocusSession';
/** The signature of FocusSession's argument and reply, and of a Changed's parameters: one string. */
const ONE_STRING_SIGNATURE = '(s)';
/** A signal of another name than Changed, sent on the cockpit's object and interface. */
const OTHER_SIGNAL_NAME = 'Sample';
/** emit_signal's destination for a broadcast. */
const BROADCAST_DESTINATION = null;
/** What recordSubscriptions records for a signal_subscribe and a signal_unsubscribe. */
const SUBSCRIBE = 'subscribe';
const UNSUBSCRIBE = 'unsubscribe';
/** What withLiveCockpitClient records for each callback the client's link calls: an owner report, a Changed. */
const OWNER_CALLBACK = 'owner';
const SIGNAL_CALLBACK = 'signal';
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
/** Another error GetUnit could answer: the read fails, but the unit is not known to be missing. */
const ACCESS_DENIED_ERROR_NAME = 'org.freedesktop.DBus.Error.AccessDenied';
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
const RESAMPLED_NETWORK_SOURCE = {...NETWORK_SOURCE, sampledAtUsec: RESAMPLED_AT_USEC, sshMasterCount: 3};
const RESAMPLED_SESSIONS_SOURCE = {...SESSIONS_SOURCE, sampledAtUsec: RESAMPLED_AT_USEC, herdrRunning: false};
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
        // The publish armed by publishAfterNextStateRead, until the next read of sourcesByName takes it; else null.
        this._publishAfterStateRead = null;
    }

    /**
     * Each source's latest object by name: a new object on each read, as the scheduler gives. The service reads it to
     * answer GetState; a publish armed by publishAfterNextStateRead goes out once that answer has.
     *
     * @returns {object} The sources.
     */
    get sourcesByName() {
        const publishAfterStateRead = this._publishAfterStateRead;
        if (publishAfterStateRead !== null) {
            this._publishAfterStateRead = null;
            // An idle runs once the method call that read this has returned, so after its reply was queued.
            GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                this.publishSource(publishAfterStateRead.sourceName, publishAfterStateRead.sourceObject);
                return GLib.SOURCE_REMOVE;
            });
        }
        return {...this._sourcesByName};
    }

    /**
     * Arms one publish to go out right after the service answers the next GetState: the Changed then follows that
     * answer on the bus, with nothing between them.
     *
     * @param {string} sourceName - The source.
     * @param {object} sourceObject - Its new object.
     * @returns {void}
     */
    publishAfterNextStateRead(sourceName, sourceObject) {
        this._publishAfterStateRead = {sourceName, sourceObject};
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
        const sourcesByName = {...this._sourcesByName};
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
 * Records where each call made through a connection's call() goes, with its parameters, flags and timeout, and passes
 * the call on unchanged.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @returns {Array<{busName: string, objectPath: string, interfaceName: string, methodName: string,
 *     parameters: Array<*>|null, flags: Gio.DBusCallFlags, timeoutMs: number}>} The calls so far, in order, each
 *     one's parameters unpacked.
 */
function recordCalls(connection) {
    const recordedCalls = [];
    const callThroughConnection = connection.call.bind(connection);
    connection.call = (busName, objectPath, interfaceName, methodName, parameters, ...callArguments) => {
        const [, flags, timeoutMs] = callArguments;
        const unpackedParameters = parameters?.deepUnpack() ?? null;
        recordedCalls.push({busName, objectPath, interfaceName, methodName, parameters: unpackedParameters, flags,
            timeoutMs});
        callThroughConnection(busName, objectPath, interfaceName, methodName, parameters, ...callArguments);
    };
    return recordedCalls;
}

/**
 * Records each signal_subscribe and signal_unsubscribe made through a connection, and passes each on unchanged. Only
 * calls made from JavaScript are seen: GDBus's own subscriptions (a name watch's) are not.
 *
 * @param {Gio.DBusConnection} connection - The subscriber.
 * @returns {string[]} SUBSCRIBE or UNSUBSCRIBE for each, in order.
 */
function recordSubscriptions(connection) {
    const subscriptionCalls = [];
    const subscribeThroughConnection = connection.signal_subscribe.bind(connection);
    const unsubscribeThroughConnection = connection.signal_unsubscribe.bind(connection);
    connection.signal_subscribe = (...subscribeArguments) => {
        subscriptionCalls.push(SUBSCRIBE);
        return subscribeThroughConnection(...subscribeArguments);
    };
    connection.signal_unsubscribe = subscriptionId => {
        subscriptionCalls.push(UNSUBSCRIBE);
        unsubscribeThroughConnection(subscriptionId);
    };
    return subscriptionCalls;
}

/**
 * Makes a cockpit link on a connection that records what it delivers.
 *
 * @param {Gio.DBusConnection} connection - The connection.
 * @returns {{link: object, owners: Array<string|null>, signals: GLib.Variant[]}} The link (unsubscribed, as made), and
 *     every owner and every Changed's parameters it delivered, in order.
 */
function makeRecordingCockpitLink(connection) {
    const owners = [];
    const signals = [];
    const link = createCockpitLink(connection, {
        onOwnerChanged: nameOwner => owners.push(nameOwner),
        onSignal: parameters => signals.push(parameters),
    });
    return {link, owners, signals};
}

/**
 * The source names a delivered Changed carries.
 *
 * @param {GLib.Variant} parameters - The Changed's parameters, as a link delivered them.
 * @returns {string[]} Its sources' names, in the payload's order.
 */
function sourceNamesOfChanged(parameters) {
    const [changedText] = parameters.deepUnpack();
    return Object.keys(JSON.parse(changedText).sources);
}

/**
 * Calls a method through a link and waits for its answer.
 *
 * @param {object} link - The cockpit's link.
 * @param {string} methodName - The method.
 * @param {GLib.Variant|null} parameters - Its arguments.
 * @returns {Promise<{error: Error|null, reply: GLib.Variant|null}>} What the link answered.
 */
function callThroughLink(link, methodName, parameters) {
    return new Promise(resolve => link.call(methodName, parameters, null, (error, reply) => resolve({error, reply})));
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
 * Serves the Cockpit1 interface for a FakeCockpit under the real bus name on the private bus, runs a row against it,
 * and takes it all down whatever happens.
 *
 * @param {(fixture: object) => Promise<void>} body - The row; gets {cockpit, service, serviceConnection, serviceName,
 *     clientConnection, isNameOwned, releaseName}: serviceName is the owner's unique name, and releaseName() gives the
 *     bus name up before the row ends.
 * @returns {Promise<void>}
 */
async function withServedCockpit(body) {
    const cockpit = new FakeCockpit();
    const serviceConnection = openPrivateBusConnection();
    const clientConnection = openPrivateBusConnection();
    let service = null;
    let ownerId = null;
    const releaseName = () => {
        if (ownerId === null)
            return;
        Gio.bus_unown_name(ownerId);
        ownerId = null;
    };
    try {
        service = new CockpitDBusService(cockpit, serviceConnection,
            {serviceStartedAtUsec: SERVICE_STARTED_AT_USEC, nowRealUsec: () => PUBLISHED_AT_USEC, logWriter: () => {}});
        const ownership = await ownName(serviceConnection, COCKPIT_BUS_NAME);
        ownerId = ownership.ownerId;
        await body({
            cockpit, service, serviceConnection, serviceName: serviceConnection.get_unique_name(), clientConnection,
            isNameOwned: ownership.isOwned, releaseName,
        });
    } finally {
        releaseName();
        service?.destroy();
        closeConnections([clientConnection, serviceConnection]);
    }
}

/**
 * Serves the cockpit (withServedCockpit), starts a client with its real defaults (no systemd here, so its StartUnit
 * fails), waits for it to be LIVE, runs a row, and destroys the client whatever happens. The client's link is the real
 * one, made by createCockpitLink through a wrapper that keeps it and records each callback it calls.
 *
 * @param {(fixture: object) => Promise<void>} body - The row; gets withServedCockpit's fixture and {client, events,
 *     isLive, clientLinks, clientLinkCallbacks}: the links the client made, and OWNER_CALLBACK or SIGNAL_CALLBACK for
 *     each callback they called, in order.
 * @returns {Promise<void>}
 */
async function withLiveCockpitClient(body) {
    await withServedCockpit(async servedCockpit => {
        const clientLinks = [];
        const clientLinkCallbacks = [];
        const createRecordedCockpitLink = (connection, {onOwnerChanged, onSignal}) => {
            const link = createCockpitLink(connection, {
                onOwnerChanged: nameOwner => {
                    clientLinkCallbacks.push(OWNER_CALLBACK);
                    onOwnerChanged(nameOwner);
                },
                onSignal: parameters => {
                    clientLinkCallbacks.push(SIGNAL_CALLBACK);
                    onSignal(parameters);
                },
            });
            clientLinks.push(link);
            return link;
        };
        let client = null;
        try {
            const started = startClient(servedCockpit.clientConnection, {createLink: createRecordedCockpitLink});
            client = started.client;
            const isLive = await waitUntil(() => client.state === LIVE, BUS_ROUND_TRIP_TIMEOUT_MS);
            await body({...servedCockpit, client, events: started.events, isLive, clientLinks, clientLinkCallbacks});
        } finally {
            client?.destroy();
        }
    });
}

/**
 * Serves a fake systemd (Manager and cockpit.service's Unit, the Unit's properties those of a skipped unit) under its
 * real name on the private bus, starts a client whose timeouts a row fires, and runs a row; nothing owns the cockpit's
 * name. Takes it all down whatever happens.
 *
 * @param {object} systemd - How the fake systemd answers.
 * @param {string|null} systemd.startUnitErrorName - The D-Bus error StartUnit answers; null to accept the job.
 * @param {string|null} systemd.getUnitErrorName - The D-Bus error GetUnit answers; null for the unit's object.
 * @param {(fixture: object) => Promise<void>} body - The row; gets {client, timeouts, startUnitCalls, getUnitCalls,
 *     infoLines, logged, isNameOwned, waitOutConfirmation}, waitOutConfirmation firing the accepted StartUnit's 15 s
 *     wait once it is pending, and saying whether it was.
 * @returns {Promise<void>}
 */
async function withFakeSystemd({startUnitErrorName, getUnitErrorName}, body) {
    const systemdConnection = openPrivateBusConnection();
    const clientConnection = openPrivateBusConnection();
    const startUnitCalls = [];
    const getUnitCalls = [];
    const exportedManager = Gio.DBusExportedObject.wrapJSObject(SYSTEMD_MANAGER_INTERFACE_XML, {
        StartUnitAsync: ([unitName, mode], invocation) => {
            startUnitCalls.push({unitName, mode});
            if (startUnitErrorName === null)
                invocation.return_value(new GLib.Variant('(o)', [START_UNIT_JOB_PATH]));
            else
                invocation.return_dbus_error(startUnitErrorName, `Unit ${unitName} not found.`);
        },
        GetUnitAsync: ([unitName], invocation) => {
            getUnitCalls.push(unitName);
            if (getUnitErrorName === null)
                invocation.return_value(new GLib.Variant('(o)', [COCKPIT_UNIT_PATH]));
            else
                invocation.return_dbus_error(getUnitErrorName, `Unit ${unitName} not loaded.`);
        },
    });
    const exportedUnit = Gio.DBusExportedObject.wrapJSObject(SYSTEMD_UNIT_INTERFACE_XML, {...SKIPPED_UNIT_PROPERTIES});
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
        const waitOutConfirmation = async () => {
            const isWaitingForService = await waitUntil(
                () => timeouts.pendingIntervalsSeconds().includes(START_CONFIRMATION_SECONDS),
                BUS_ROUND_TRIP_TIMEOUT_MS);
            if (isWaitingForService)
                timeouts.fire(START_CONFIRMATION_SECONDS);
            return isWaitingForService;
        };
        await body({
            client, timeouts, startUnitCalls, getUnitCalls, infoLines: started.infoLines, logged: started.logged,
            isNameOwned: ownership.isOwned, waitOutConfirmation,
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
        client.setSubscriptionWanted(true);
        // A round trip first, so the subscription is in place on the bus, and the GetState that followed it answered,
        // before anything is published.
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
            didArrive: true, isRoundTripDone: true,
            eventsAfter: [{type: 'sources', names: ['mounts'], cause: 'changed'}],
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

test('cockpit link on a private bus: it starts unsubscribed; setSubscribed(true) twice makes one subscription, which ' +
    'delivers Changed and no signal of another name; setSubscribed(false) twice drops it once; destroy() drops a ' +
    'held subscription, and setSubscribed after it does nothing', () =>
    withServedCockpit(async ({cockpit, serviceConnection, clientConnection}) => {
        const subscriptionCalls = recordSubscriptions(clientConnection);
        const recording = makeRecordingCockpitLink(clientConnection);
        try {
            const isSubscribedAtCreation = recording.link.isSubscribed;
            const isOwnerSeen = await waitUntil(() => recording.owners.length >= 1, BUS_ROUND_TRIP_TIMEOUT_MS);
            recording.link.setSubscribed(true);
            recording.link.setSubscribed(true);
            const isSubscribedWhenWanted = recording.link.isSubscribed;
            // The subscription is in place on the bus once a call sent after it is answered.
            await roundTripToCockpit(clientConnection);
            const otherSignalParameters = new GLib.Variant(ONE_STRING_SIGNATURE, ['{}']);
            serviceConnection.emit_signal(BROADCAST_DESTINATION, COCKPIT_OBJECT_PATH, COCKPIT_INTERFACE_NAME,
                OTHER_SIGNAL_NAME, otherSignalParameters);
            cockpit.publishSource('mounts', RESAMPLED_MOUNTS_SOURCE);
            const isChangedSeen = await waitUntil(() => recording.signals.length >= 1, BUS_ROUND_TRIP_TIMEOUT_MS);
            // The service sends in order, so the other signal came before the Changed, if it came at all; anything
            // sent after it has arrived once this answer has.
            const isRoundTripDone = await roundTripToCockpit(clientConnection);
            recording.link.setSubscribed(false);
            recording.link.setSubscribed(false);
            const subscriptionCallsWhileLive = [...subscriptionCalls];
            recording.link.setSubscribed(true);
            recording.link.destroy();
            const isSubscribedAfterDestroy = recording.link.isSubscribed;
            recording.link.setSubscribed(true);
            assertEqual({
                isSubscribedAtCreation, isOwnerSeen, isSubscribedWhenWanted, isChangedSeen, isRoundTripDone,
                deliveredSourceNames: recording.signals.map(sourceNamesOfChanged), subscriptionCallsWhileLive,
                subscriptionCalls, isSubscribedAfterDestroy,
            }, {
                isSubscribedAtCreation: false, isOwnerSeen: true, isSubscribedWhenWanted: true, isChangedSeen: true,
                isRoundTripDone: true, deliveredSourceNames: [['mounts']],
                subscriptionCallsWhileLive: [SUBSCRIBE, UNSUBSCRIBE],
                subscriptionCalls: [SUBSCRIBE, UNSUBSCRIBE, SUBSCRIBE, UNSUBSCRIBE], isSubscribedAfterDestroy: false,
            });
        } finally {
            recording.link.destroy();
        }
    }));

test('cockpit link on a private bus: call() passes its parameters, to the owner\'s unique name, with NO_AUTO_START ' +
    'and DBUS_CALL_TIMEOUT_MS', () =>
    withServedCockpit(async ({serviceName, clientConnection}) => {
        const recordedCalls = recordCalls(clientConnection);
        const recording = makeRecordingCockpitLink(clientConnection);
        try {
            const isOwnerSeen = await waitUntil(() => recording.owners.length >= 1, BUS_ROUND_TRIP_TIMEOUT_MS);
            const focusParameters = new GLib.Variant(ONE_STRING_SIGNATURE, [FOCUSABLE_SESSION_ID]);
            const focusAnswer = await callThroughLink(recording.link, FOCUS_SESSION_METHOD, focusParameters);
            const [replyText] = focusAnswer.reply?.deepUnpack() ?? [null];
            assertEqual({
                isOwnerSeen, calls: recordedCalls, error: focusAnswer.error, reply: parseFocusSessionReply(replyText),
            }, {
                isOwnerSeen: true,
                calls: [{
                    busName: serviceName, objectPath: COCKPIT_OBJECT_PATH, interfaceName: COCKPIT_INTERFACE_NAME,
                    methodName: FOCUS_SESSION_METHOD, parameters: [FOCUSABLE_SESSION_ID],
                    flags: Gio.DBusCallFlags.NO_AUTO_START, timeoutMs: DBUS_CALL_TIMEOUT_MS,
                }],
                error: null,
                reply: {focused: true, windowPid: null, error: null, windowPidCandidates: WINDOW_PID_CANDIDATES},
            });
        } finally {
            recording.link.destroy();
        }
    }));

test('cockpit client on a private bus: with the subscription not wanted GetState makes it LIVE and a Changed reaches ' +
    'no listener; wanting it reads the state afresh, and a Changed the service sends right after answering that ' +
    'GetState is delivered, as is the next', () =>
    withLiveCockpitClient(async ({cockpit, clientConnection, client, events, isLive, clientLinks}) => {
        // A live link on the same connection, subscribed: it seeing a Changed proves the Changed reached the
        // connection.
        const control = makeRecordingCockpitLink(clientConnection);
        control.link.setSubscribed(true);
        try {
            await waitUntil(() => control.owners.length >= 1, BUS_ROUND_TRIP_TIMEOUT_MS);
            await roundTripToCockpit(clientConnection);
            const [clientLink] = clientLinks;
            const isSubscribedWhileUnwanted = clientLink.isSubscribed;
            const eventCountBeforeChanges = events.length;
            cockpit.publishSource('mounts', RESAMPLED_MOUNTS_SOURCE);
            const hasControlSeenChange = await waitUntil(() => control.signals.length >= 1, BUS_ROUND_TRIP_TIMEOUT_MS);
            const eventsWhileUnwanted = events.slice(eventCountBeforeChanges);
            cockpit.publishAfterNextStateRead('network', RESAMPLED_NETWORK_SOURCE);
            client.setSubscriptionWanted(true);
            const isChangedAfterStateSeen = await waitUntil(
                () => client.sourcesByName.network?.sampledAtUsec === RESAMPLED_AT_USEC, BUS_ROUND_TRIP_TIMEOUT_MS);
            cockpit.publishSource('sessions', RESAMPLED_SESSIONS_SOURCE);
            const isNextChangedSeen = await waitUntil(
                () => client.sourcesByName.sessions?.sampledAtUsec === RESAMPLED_AT_USEC, BUS_ROUND_TRIP_TIMEOUT_MS);
            assertEqual({
                isLive, isSubscribedWhileUnwanted, hasControlSeenChange, eventsWhileUnwanted, isChangedAfterStateSeen,
                isNextChangedSeen, isSubscribedWhileWanted: clientLink.isSubscribed,
                eventsAfterChanges: events.slice(eventCountBeforeChanges), sourcesByName: client.sourcesByName,
            }, {
                isLive: true, isSubscribedWhileUnwanted: false, hasControlSeenChange: true, eventsWhileUnwanted: [],
                isChangedAfterStateSeen: true, isNextChangedSeen: true, isSubscribedWhileWanted: true,
                eventsAfterChanges: [
                    {type: 'sources', names: ['mounts'], cause: 'read'},
                    {type: 'sources', names: ['network'], cause: 'changed'},
                    {type: 'sources', names: ['sessions'], cause: 'changed'},
                ],
                sourcesByName: {
                    sessions: RESAMPLED_SESSIONS_SOURCE, network: RESAMPLED_NETWORK_SOURCE,
                    mounts: RESAMPLED_MOUNTS_SOURCE,
                },
            });
        } finally {
            control.link.destroy();
        }
    }));

test('cockpit client on a private bus: after destroy() its link calls back nothing, neither for a Changed nor for ' +
    'the owner leaving, both of which a live link on the same connection sees', () =>
    withLiveCockpitClient(async ({
        cockpit, clientConnection, client, releaseName, clientLinks, clientLinkCallbacks,
    }) => {
        client.setSubscriptionWanted(true);
        const control = makeRecordingCockpitLink(clientConnection);
        control.link.setSubscribed(true);
        try {
            await waitUntil(() => control.owners.length >= 1, BUS_ROUND_TRIP_TIMEOUT_MS);
            await roundTripToCockpit(clientConnection);
            const [clientLink] = clientLinks;
            const isSubscribedBeforeDestroy = clientLink.isSubscribed;
            const callbackCountBeforeDestroy = clientLinkCallbacks.length;
            client.destroy();
            cockpit.publishSource('mounts', RESAMPLED_MOUNTS_SOURCE);
            releaseName();
            const hasControlSeenBoth = await waitUntil(
                () => control.signals.length >= 1 && control.owners.at(-1) === null, BUS_ROUND_TRIP_TIMEOUT_MS);
            assertEqual({
                isSubscribedBeforeDestroy, hasControlSeenBoth, isSubscribedAfterDestroy: clientLink.isSubscribed,
                callbacksAfterDestroy: clientLinkCallbacks.slice(callbackCountBeforeDestroy),
            }, {
                isSubscribedBeforeDestroy: true, hasControlSeenBoth: true, isSubscribedAfterDestroy: false,
                callbacksAfterDestroy: [],
            });
        } finally {
            control.link.destroy();
        }
    }));

test('cockpit client on a private bus: an accepted StartUnit("cockpit.service", "replace") with no name in 15 s ' +
    'reads the unit over systemd\'s D-Bus (GetUnit, then its properties), and a skipped unit makes it SKIPPED', () =>
    withFakeSystemd({startUnitErrorName: null, getUnitErrorName: null},
        async ({client, timeouts, startUnitCalls, getUnitCalls, infoLines, logged, isNameOwned,
            waitOutConfirmation}) => {
            const isWaitingForService = await waitOutConfirmation();
            const isSkipped = await waitUntil(() => client.state === SKIPPED, BUS_ROUND_TRIP_TIMEOUT_MS);
            assertEqual({
                isNameOwned, isWaitingForService, isSkipped, startUnitCalls, getUnitCalls,
                pending: timeouts.pendingIntervalsSeconds(), infoLineCount: infoLines.length, logged,
            }, {
                isNameOwned: true, isWaitingForService: true, isSkipped: true,
                startUnitCalls: [{unitName: 'cockpit.service', mode: 'replace'}], getUnitCalls: ['cockpit.service'],
                pending: [], infoLineCount: 1, logged: [],
            });
        }));

test('cockpit client on a private bus: a unit systemd no longer has loaded after an accepted job (GetUnit answers ' +
    'NoSuchUnit) is not configured: SKIPPED, no retry, no warning', () =>
    withFakeSystemd({startUnitErrorName: null, getUnitErrorName: NO_SUCH_UNIT_ERROR_NAME},
        async ({client, timeouts, getUnitCalls, infoLines, logged, waitOutConfirmation}) => {
            const isWaitingForService = await waitOutConfirmation();
            const isSkipped = await waitUntil(() => client.state === SKIPPED, BUS_ROUND_TRIP_TIMEOUT_MS);
            assertEqual({
                isWaitingForService, isSkipped, getUnitCalls, pending: timeouts.pendingIntervalsSeconds(),
                infoLineCount: infoLines.length, logged,
            }, {
                isWaitingForService: true, isSkipped: true, getUnitCalls: ['cockpit.service'], pending: [],
                infoLineCount: 1, logged: [],
            });
        }));

test('cockpit client on a private bus: a unit read that fails with another error (GetUnit answers AccessDenied) ' +
    'reads as nothing known, so the retry chain goes on', () =>
    withFakeSystemd({startUnitErrorName: null, getUnitErrorName: ACCESS_DENIED_ERROR_NAME},
        async ({client, timeouts, getUnitCalls, infoLines, waitOutConfirmation}) => {
            const isWaitingForService = await waitOutConfirmation();
            const isRetryPending = await waitUntil(
                () => timeouts.pendingIntervalsSeconds().includes(FIRST_RETRY_DELAY_SECONDS),
                BUS_ROUND_TRIP_TIMEOUT_MS);
            assertEqual({isWaitingForService, isRetryPending, getUnitCalls, state: client.state, infoLines}, {
                isWaitingForService: true, isRetryPending: true, getUnitCalls: ['cockpit.service'], state: STARTING,
                infoLines: [],
            });
        }));

test('cockpit client on a private bus: a StartUnit systemd rejects with NoSuchUnit (the unit not linked) is not ' +
    'configured: SKIPPED at once, no unit read, no retry, no warning', () =>
    withFakeSystemd({startUnitErrorName: NO_SUCH_UNIT_ERROR_NAME, getUnitErrorName: null},
        async ({client, timeouts, startUnitCalls, getUnitCalls, infoLines, logged}) => {
            const isSkipped = await waitUntil(() => client.state === SKIPPED, BUS_ROUND_TRIP_TIMEOUT_MS);
            assertEqual({
                isSkipped, startUnitCalls, getUnitCalls, pending: timeouts.pendingIntervalsSeconds(),
                infoLineCount: infoLines.length, logged,
            }, {
                isSkipped: true, startUnitCalls: [{unitName: 'cockpit.service', mode: 'replace'}], getUnitCalls: [],
                pending: [], infoLineCount: 1, logged: [],
            });
        }));
