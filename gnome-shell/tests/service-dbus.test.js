// service/dbusService.js on a PRIVATE message bus, with a fake sampler. Run only by run-private-bus.js under
// `dbus-run-session`, never by run.js: that runs on whatever session bus its caller has, which at a desk is the live
// one. Every connection here is opened by address, and only once requirePrivateBusAddress has said the address is a
// path socket inside RESOURCE_PULSE_TEST_BUS_DIR, so a run anywhere else fails instead of reaching the live session.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {ResourcePulseDBusService} from '../extensions/resource-pulse@dotfiles/service/dbusService.js';
import {
    RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_OBJECT_PATH, parseSamplePayload, parseStatePayload,
} from '../extensions/resource-pulse@dotfiles/lib/protocol.js';
import {RingBuffer} from '../extensions/resource-pulse@dotfiles/lib/history.js';
import {CARD_HISTORY_SAMPLES} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

/** Names the directory the private bus listens in; scripts/test-resource-pulse.sh sets it. */
const PRIVATE_BUS_DIRECTORY_VARIABLE = 'RESOURCE_PULSE_TEST_BUS_DIR';
const SESSION_BUS_ADDRESS_VARIABLE = 'DBUS_SESSION_BUS_ADDRESS';
const RUNTIME_DIRECTORY_VARIABLE = 'XDG_RUNTIME_DIR';
const PATH_SOCKET_ADDRESS_PREFIX = 'unix:path=';
/** Where the live session bus listens, under XDG_RUNTIME_DIR. */
const LIVE_SESSION_BUS_SOCKET_NAME = 'bus';
/**
 * What may lead an address that starts inside the bus directory out of it: an address list (another address after
 * the separator), a parent segment, and a percent escape (D-Bus decodes them, so %2e%2e is ..).
 */
const ADDRESS_ESCAPE_MARKERS = [';', '/../', '%'];
const CONNECTION_FLAGS = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
    Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION;
const CALL_TIMEOUT_MS = 2000;
/** The design's budget for dropping a vanished caller's watch. */
const VANISHED_WATCH_DROP_TIMEOUT_MS = 2000;
const SAMPLE_SIGNAL_TIMEOUT_MS = 2000;
const POLL_INTERVAL_MS = 20;
const SERVICE_STARTED_AT_USEC = 1_794_000_000_000_000;
const SAMPLED_AT_USEC = 1_794_000_002_000_000;
/** How much later a second publish happens, in real microseconds. */
const LATER_PUBLISH_OFFSET_USEC = 2_000_000;
const STATE_REPLY_TYPE = new GLib.VariantType('(s)');
const SAMPLE_SIGNAL_NAME = 'Sample';
const GET_STATE_METHOD = 'GetState';
const WATCH_DETAIL_METHOD = 'WatchDetail';
const UNWATCH_DETAIL_METHOD = 'UnwatchDetail';

/** A snapshot with every field set, as the service would publish it after a scan. */
const TICK_SNAPSHOT = {
    takenAtUsec: 123_000_000,
    takenAtClockLabel: '14:02',
    cpuBusyPercent: 50,
    cpuClusters: {performancePercent: 60, efficiencyPercent: 20},
    memory: {usedBytes: 8_000_000_000, totalBytes: 32_000_000_000},
    swap: {zramUsedBytes: 0, zramRamBytes: 0, diskBytes: 0},
    pressureAvg10: {cpu: 0.5, memory: 0, io: 0},
    apps: {
        topCpu: {groupKey: 'app:org.example.Editor', name: 'Editor', cpuPercent: 31},
        topMemory: {groupKey: 'app:org.example.Editor', name: 'Editor', memoryBytes: 2_000_000_000},
        cpuRanking: [{groupKey: 'app:org.example.Editor', name: 'Editor', cpuPercent: 31}],
        memoryRanking: [{groupKey: 'app:org.example.Editor', name: 'Editor', memoryBytes: 2_000_000_000}],
    },
    isComplete: true,
};
/** What a watch start's reveal publishes: the tick's values with a new ranking, appending nothing. */
const REVEAL_SNAPSHOT = {
    ...TICK_SNAPSHOT,
    apps: {...TICK_SNAPSHOT.apps, topCpu: {groupKey: 'herdr-server', name: 'herdr agents', cpuPercent: 40}},
};
const TICK_APPENDED_HISTORY = {cpu: 0.5, memory: 0.25};

/**
 * The session bus address, refusing anything but a private bus: one path socket inside the directory
 * RESOURCE_PULSE_TEST_BUS_DIR names, with nothing that could lead it out (ADDRESS_ESCAPE_MARKERS), and never the
 * live bus's socket under XDG_RUNTIME_DIR. scripts/test-resource-pulse.sh's is_private_bus_address is its twin.
 *
 * @returns {string} The private bus address.
 * @throws {Error} When the address is not provably the private bus.
 */
export function requirePrivateBusAddress() {
    const busDirectory = GLib.getenv(PRIVATE_BUS_DIRECTORY_VARIABLE);
    const address = GLib.getenv(SESSION_BUS_ADDRESS_VARIABLE);
    const runtimeDirectory = GLib.getenv(RUNTIME_DIRECTORY_VARIABLE);
    const isInsideBusDirectory = Boolean(busDirectory) &&
        Boolean(address?.startsWith(`${PATH_SOCKET_ADDRESS_PREFIX}${busDirectory}/`));
    const liveBusAddressPrefix = runtimeDirectory
        ? `${PATH_SOCKET_ADDRESS_PREFIX}${runtimeDirectory}/${LIVE_SESSION_BUS_SOCKET_NAME}`
        : null;
    const isLiveBus = liveBusAddressPrefix !== null && Boolean(address?.startsWith(liveBusAddressPrefix));
    const canLeadElsewhere = ADDRESS_ESCAPE_MARKERS.some(marker => Boolean(address?.includes(marker)));
    if (!isInsideBusDirectory || isLiveBus || canLeadElsewhere) {
        throw new Error(`refusing to run: ${SESSION_BUS_ADDRESS_VARIABLE} (${address}) is not a private bus ` +
            `inside ${PRIVATE_BUS_DIRECTORY_VARIABLE} (${busDirectory})`);
    }
    return address;
}

/** Stands in for ServiceSampler: the surface the D-Bus service uses, plus a publish() the rows drive. */
export class FakeSampler {
    constructor() {
        this.latestSnapshot = null;
        this.cpuHistory = new RingBuffer(CARD_HISTORY_SAMPLES);
        this.memoryHistory = new RingBuffer(CARD_HISTORY_SAMPLES);
        /** @type {boolean[]} Every setDetailWatched argument, in order. */
        this.detailWatchedCalls = [];
        this._listeners = new Map();
        this._nextListenerId = 1;
    }

    /** @returns {number} How many listeners are attached. */
    get listenerCount() {
        return this._listeners.size;
    }

    /**
     * @param {(snapshot: object, appendedHistory: object|null) => void} callback - Called on each publish.
     * @returns {number} An id for removeListener.
     */
    addListener(callback) {
        const listenerId = this._nextListenerId++;
        this._listeners.set(listenerId, callback);
        return listenerId;
    }

    /**
     * @param {number} listenerId - The id addListener returned.
     * @returns {void}
     */
    removeListener(listenerId) {
        this._listeners.delete(listenerId);
    }

    /**
     * Records the call.
     *
     * @param {boolean} isWatched - True while any client holds a watch.
     * @returns {void}
     */
    setDetailWatched(isWatched) {
        this.detailWatchedCalls.push(isWatched);
    }

    /**
     * Publishes as the real sampler does: a tick appends to the histories, a reveal (appendedHistory null) does not.
     *
     * @param {object} snapshot - The snapshot.
     * @param {{cpu: number|null, memory: number|null}|null} appendedHistory - What this publish appended.
     * @returns {void}
     */
    publish(snapshot, appendedHistory) {
        if (appendedHistory !== null) {
            this.cpuHistory.push(appendedHistory.cpu);
            this.memoryHistory.push(appendedHistory.memory);
        }
        this.latestSnapshot = snapshot;
        for (const listener of [...this._listeners.values()])
            listener(snapshot, appendedHistory);
    }
}

/**
 * Opens a new connection to the private bus: each one is a separate caller with its own unique name.
 *
 * @returns {Gio.DBusConnection} The connection.
 */
export function openPrivateBusConnection() {
    return Gio.DBusConnection.new_for_address_sync(requirePrivateBusAddress(), CONNECTION_FLAGS, null, null);
}

/**
 * Exports a ResourcePulseDBusService for a fake sampler on its own connection, runs a row against it, and closes
 * every connection the row opened whatever happens.
 *
 * @param {(fixture: object) => Promise<void>} body - The row; gets {sampler, service, serviceName, openClient}.
 * @param {object} [options] - The service's clock.
 * @param {() => number} [options.nowRealUsec] - Real time now, in microseconds; SAMPLED_AT_USEC by default.
 * @returns {Promise<void>}
 */
async function withExportedService(body, {nowRealUsec = () => SAMPLED_AT_USEC} = {}) {
    const sampler = new FakeSampler();
    const serviceConnection = openPrivateBusConnection();
    const clientConnections = [];
    let service = null;
    try {
        service = new ResourcePulseDBusService(sampler, serviceConnection,
            {serviceStartedAtUsec: SERVICE_STARTED_AT_USEC, nowRealUsec});
        await body({
            sampler,
            service,
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
 * Calls a method of the service's interface.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @param {string} serviceName - The service connection's unique name.
 * @param {string} methodName - The method.
 * @param {GLib.VariantType|null} [replyType] - The reply's type, or null for none.
 * @returns {Promise<GLib.Variant>} The reply.
 */
function callServiceMethod(connection, serviceName, methodName, replyType = null) {
    return new Promise((resolve, reject) => {
        connection.call(serviceName, RESOURCE_PULSE_OBJECT_PATH, RESOURCE_PULSE_INTERFACE_NAME, methodName, null,
            replyType, Gio.DBusCallFlags.NONE, CALL_TIMEOUT_MS, null, (callingConnection, result) => {
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
 * @returns {Promise<object|null>} parseStatePayload's result.
 */
async function fetchState(connection, serviceName) {
    const reply = await callServiceMethod(connection, serviceName, GET_STATE_METHOD, STATE_REPLY_TYPE);
    const [stateText] = reply.deepUnpack();
    return parseStatePayload(stateText);
}

/**
 * Waits on the main loop until a condition holds or the time runs out.
 *
 * @param {() => boolean} isDone - The condition, polled every POLL_INTERVAL_MS.
 * @param {number} timeoutMs - How long to wait at most.
 * @returns {Promise<boolean>} True when the condition held in time.
 */
export function waitUntil(isDone, timeoutMs) {
    const deadlineUsec = GLib.get_monotonic_time() + timeoutMs * 1000;
    return new Promise(resolve => {
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, POLL_INTERVAL_MS, () => {
            if (isDone()) {
                resolve(true);
                return GLib.SOURCE_REMOVE;
            }
            if (GLib.get_monotonic_time() >= deadlineUsec) {
                resolve(false);
                return GLib.SOURCE_REMOVE;
            }
            return GLib.SOURCE_CONTINUE;
        });
    });
}

/**
 * Collects the Sample signals a connection receives from the service, parsed, until stopped.
 *
 * @param {Gio.DBusConnection} connection - The listener.
 * @param {string} serviceName - The service connection's unique name.
 * @returns {{samples: object[], stop: () => void}} The samples so far, and a way to unsubscribe.
 */
function collectSamples(connection, serviceName) {
    const samples = [];
    const subscriptionId = connection.signal_subscribe(serviceName, RESOURCE_PULSE_INTERFACE_NAME, SAMPLE_SIGNAL_NAME,
        RESOURCE_PULSE_OBJECT_PATH, null, Gio.DBusSignalFlags.NONE, (...signalArguments) => {
            const [sampleText] = signalArguments.at(-1).deepUnpack();
            samples.push(parseSamplePayload(sampleText));
        });
    return {samples, stop: () => connection.signal_unsubscribe(subscriptionId)};
}

test('service D-Bus: before any sample GetState answers protocol 1, sequence 0, the start time and the histories',
    () => withExportedService(async ({sampler, serviceName, openClient}) => {
        sampler.cpuHistory.push(0.25);
        sampler.cpuHistory.push(null);
        sampler.memoryHistory.push(0.5);
        sampler.memoryHistory.push(0.6);
        assertEqual(await fetchState(openClient(), serviceName), {
            protocol: 1,
            snapshot: null,
            histories: {cpu: [0.25, null], memory: [0.5, 0.6]},
            serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
            latestSampledAtUsec: null,
            sequence: 0,
        });
    }));

test('service D-Bus: each publish sends one Sample (sequence from 1; a reveal appends nothing), and GetState follows',
    () => withExportedService(async ({sampler, serviceName, openClient}) => {
        const clientConnection = openClient();
        const sampleCollector = collectSamples(clientConnection, serviceName);
        // A round trip first, so the subscription is in place on the bus before anything is published.
        await fetchState(clientConnection, serviceName);
        sampler.publish(TICK_SNAPSHOT, TICK_APPENDED_HISTORY);
        sampler.publish(REVEAL_SNAPSHOT, null);
        const didArrive = await waitUntil(() => sampleCollector.samples.length >= 2, SAMPLE_SIGNAL_TIMEOUT_MS);
        sampleCollector.stop();
        const state = await fetchState(clientConnection, serviceName);
        assertEqual({didArrive, samples: sampleCollector.samples, state}, {
            didArrive: true,
            samples: [
                {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: 1,
                    sampledAtUsec: SAMPLED_AT_USEC},
                {snapshot: REVEAL_SNAPSHOT, appendedHistory: null, sequence: 2, sampledAtUsec: SAMPLED_AT_USEC},
            ],
            state: {
                protocol: 1,
                snapshot: REVEAL_SNAPSHOT,
                histories: {cpu: [0.5], memory: [0.25]},
                serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
                latestSampledAtUsec: SAMPLED_AT_USEC,
                sequence: 2,
            },
        });
    }));

test('service D-Bus: GetState\'s latestSampledAtUsec is the real time of the latest publish, a reveal\'s included',
    () => {
        const publishRealTimesUsec = [SAMPLED_AT_USEC, SAMPLED_AT_USEC + LATER_PUBLISH_OFFSET_USEC];
        const remainingRealTimesUsec = [...publishRealTimesUsec];
        return withExportedService(async ({sampler, serviceName, openClient}) => {
            const clientConnection = openClient();
            sampler.publish(TICK_SNAPSHOT, TICK_APPENDED_HISTORY);
            const afterTick = (await fetchState(clientConnection, serviceName)).latestSampledAtUsec;
            sampler.publish(REVEAL_SNAPSHOT, null);
            const afterReveal = (await fetchState(clientConnection, serviceName)).latestSampledAtUsec;
            assertEqual({afterTick, afterReveal},
                {afterTick: publishRealTimesUsec[0], afterReveal: publishRealTimesUsec[1]});
        }, {nowRealUsec: () => remainingRealTimesUsec.shift()});
    });

test('service D-Bus: a caller that closes its connection holding a watch loses it: setDetailWatched(false) in 2 s',
    () => withExportedService(async ({sampler, serviceName, openClient}) => {
        const clientConnection = openClient();
        await callServiceMethod(clientConnection, serviceName, WATCH_DETAIL_METHOD);
        const callsWhileWatched = [...sampler.detailWatchedCalls];
        clientConnection.close_sync(null);
        const didDrop = await waitUntil(() => sampler.detailWatchedCalls.length >= 2, VANISHED_WATCH_DROP_TIMEOUT_MS);
        assertEqual({callsWhileWatched, didDrop, calls: sampler.detailWatchedCalls},
            {callsWhileWatched: [true], didDrop: true, calls: [true, false]});
    }));

test('service D-Bus: a caller holding two watches that vanishes drops both: setDetailWatched(false), count 0', () =>
    withExportedService(async ({sampler, service, serviceName, openClient}) => {
        const clientConnection = openClient();
        await callServiceMethod(clientConnection, serviceName, WATCH_DETAIL_METHOD);
        await callServiceMethod(clientConnection, serviceName, WATCH_DETAIL_METHOD);
        const countWhileWatched = service.detailWatchCount;
        clientConnection.close_sync(null);
        const didDropBoth = await waitUntil(() => service.detailWatchCount === 0, VANISHED_WATCH_DROP_TIMEOUT_MS);
        assertEqual({countWhileWatched, didDropBoth, calls: sampler.detailWatchedCalls,
            countAfter: service.detailWatchCount}, {countWhileWatched: 2, didDropBoth: true, calls: [true, false],
            countAfter: 0});
    }));

test('service D-Bus: two watches from one caller need two unwatches', () =>
    withExportedService(async ({sampler, serviceName, openClient}) => {
        const clientConnection = openClient();
        const callsAfterEachStep = [];
        for (const methodName of [WATCH_DETAIL_METHOD, WATCH_DETAIL_METHOD, UNWATCH_DETAIL_METHOD,
            UNWATCH_DETAIL_METHOD]) {
            // In sequence: each step is checked after the one before it has been answered.
            await callServiceMethod(clientConnection, serviceName, methodName);
            callsAfterEachStep.push(sampler.detailWatchedCalls.join(','));
        }
        assertEqual(callsAfterEachStep, ['true', 'true', 'true', 'true,false']);
    }));

test('service D-Bus: UnwatchDetail from a caller holding no watch is a no-op, not an error', () =>
    withExportedService(async ({sampler, service, serviceName, openClient}) => {
        const watchingConnection = openClient();
        const idleConnection = openClient();
        await callServiceMethod(idleConnection, serviceName, UNWATCH_DETAIL_METHOD);
        const callsAfterLoneUnwatch = [...sampler.detailWatchedCalls];
        await callServiceMethod(watchingConnection, serviceName, WATCH_DETAIL_METHOD);
        await callServiceMethod(idleConnection, serviceName, UNWATCH_DETAIL_METHOD);
        assertEqual({callsAfterLoneUnwatch, calls: sampler.detailWatchedCalls, watchCount: service.detailWatchCount},
            {callsAfterLoneUnwatch: [], calls: [true], watchCount: 1});
    }));

test('service D-Bus: one caller vanishing leaves another\'s watch, and the sampler hears only changes', () =>
    withExportedService(async ({sampler, service, serviceName, openClient}) => {
        const vanishingConnection = openClient();
        const stayingConnection = openClient();
        await callServiceMethod(vanishingConnection, serviceName, WATCH_DETAIL_METHOD);
        await callServiceMethod(stayingConnection, serviceName, WATCH_DETAIL_METHOD);
        const countWithBoth = service.detailWatchCount;
        vanishingConnection.close_sync(null);
        const didDropVanished = await waitUntil(() => service.detailWatchCount === 1, VANISHED_WATCH_DROP_TIMEOUT_MS);
        const callsAfterVanish = [...sampler.detailWatchedCalls];
        await callServiceMethod(stayingConnection, serviceName, UNWATCH_DETAIL_METHOD);
        assertEqual({countWithBoth, didDropVanished, callsAfterVanish, calls: sampler.detailWatchedCalls},
            {countWithBoth: 2, didDropVanished: true, callsAfterVanish: [true], calls: [true, false]});
    }));

test('service D-Bus: destroy() unexports the object and detaches from the sampler', () =>
    withExportedService(async ({sampler, service, serviceName, openClient}) => {
        const clientConnection = openClient();
        const listenersBefore = sampler.listenerCount;
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
        assertEqual({listenersBefore, listenersAfter: sampler.listenerCount, isUnknownMethodOrObject},
            {listenersBefore: 1, listenersAfter: 0, isUnknownMethodOrObject: true});
    }));
