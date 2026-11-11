// pulseClient.js with its REAL defaults (serviceLink.js's name watch, Sample subscription and calls, GLib timeouts, the
// StartUnit call) on a PRIVATE message bus, and serviceLink.js on its own. Run only by run-private-bus.js under
// `dbus-run-session`, never by run.js. Every connection is opened by address through service-dbus.test.js's
// openPrivateBusConnection, which refuses anything but the private bus. The service side is the real
// service/dbusService.js over a fake sampler, owning the real bus name; systemd's side is either absent (nothing owns
// org.freedesktop.systemd1 here) or a fake Manager that records StartUnit.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {FakeSampler, openPrivateBusConnection, waitUntil} from './service-dbus.test.js';
import {PulseClient} from '../extensions/resource-pulse@dotfiles/pulseClient.js';
import {createResourcePulseLink} from '../extensions/resource-pulse@dotfiles/serviceLink.js';
import {ResourcePulseDBusService} from '../extensions/resource-pulse@dotfiles/service/dbusService.js';
import {
    GET_STATE_METHOD_NAME, RESOURCE_PULSE_BUS_NAME, RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_OBJECT_PATH,
    parseSamplePayload, parseStatePayload,
} from '../extensions/resource-pulse@dotfiles/lib/protocol.js';
import {DBUS_CALL_TIMEOUT_MS} from '../extensions/resource-pulse@dotfiles/lib/constants.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';

const BUS_ROUND_TRIP_TIMEOUT_MS = 2000;
/** The signature of GetState's reply and of a Sample's parameters: one string. */
const ONE_STRING_SIGNATURE = '(s)';
const SYSTEMD_BUS_NAME = 'org.freedesktop.systemd1';
const SYSTEMD_OBJECT_PATH = '/org/freedesktop/systemd1';
const SYSTEMD_MANAGER_INTERFACE_NAME = 'org.freedesktop.systemd1.Manager';
/** The standard interface every GDBus connection answers on any path; Ping returns once earlier replies are sent. */
const PEER_INTERFACE_NAME = 'org.freedesktop.DBus.Peer';
const PING_METHOD_NAME = 'Ping';
const START_UNIT_JOB_PATH = '/org/freedesktop/systemd1/job/1';
/** Just StartUnit of systemd's Manager interface, as the user manager serves it. */
const SYSTEMD_MANAGER_INTERFACE_XML = `<node>
  <interface name="${SYSTEMD_MANAGER_INTERFACE_NAME}">
    <method name="StartUnit">
      <arg name="name" type="s" direction="in"/>
      <arg name="mode" type="s" direction="in"/>
      <arg name="job" type="o" direction="out"/>
    </method>
  </interface>
</node>`;
/** The snapshot the fake sampler holds when the client first asks for the state. */
const STATE_SNAPSHOT = {
    takenAtUsec: 120_000_000,
    takenAtClockLabel: '14:02',
    cpuBusyPercent: 23.5,
    cpuClusters: {performancePercent: 41, efficiencyPercent: 6},
    memory: {usedBytes: 16_000_000_000, totalBytes: 32_000_000_000},
    swap: {zramUsedBytes: 0, zramRamBytes: 0, diskBytes: 0},
    pressureAvg10: {cpu: 1.5, memory: 0, io: 0.25},
    apps: {
        topCpu: {groupKey: 'app:org.example.Editor', name: 'Editor', cpuPercent: 31},
        topMemory: {groupKey: 'herdr-server', name: 'herdr agents', memoryBytes: 15_700_000_000},
        cpuRanking: [{groupKey: 'app:org.example.Editor', name: 'Editor', cpuPercent: 31}],
        memoryRanking: [{groupKey: 'herdr-server', name: 'herdr agents', memoryBytes: 15_700_000_000}],
    },
    isComplete: true,
};
/** The next fast tick's snapshot. */
const TICK_SNAPSHOT = {...STATE_SNAPSHOT, takenAtUsec: 122_000_000, takenAtClockLabel: '14:03', cpuBusyPercent: 50};
const TICK_APPENDED_HISTORY = {cpu: 0.5, memory: 0.25};

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
 * Pings a peer and waits for its answer. A peer answers in order, so by then every reply it sent before has been
 * received, and its callback run.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @param {string} busName - The peer.
 * @returns {Promise<boolean>} True once answered; false on an error.
 */
function pingPeer(connection, busName) {
    return new Promise(resolve => {
        connection.call(busName, SYSTEMD_OBJECT_PATH, PEER_INTERFACE_NAME, PING_METHOD_NAME, null, null,
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
 * Records where each call made through a connection's call() goes, with its flags and timeout, and passes the call on
 * unchanged.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @returns {Array<{busName: string, objectPath: string, interfaceName: string, methodName: string,
 *     flags: Gio.DBusCallFlags, timeoutMs: number}>} The calls so far, in order.
 */
function recordCalls(connection) {
    const recordedCalls = [];
    const callThroughConnection = connection.call.bind(connection);
    connection.call = (busName, objectPath, interfaceName, methodName, ...callArguments) => {
        const [, , flags, timeoutMs] = callArguments;
        recordedCalls.push({busName, objectPath, interfaceName, methodName, flags, timeoutMs});
        callThroughConnection(busName, objectPath, interfaceName, methodName, ...callArguments);
    };
    return recordedCalls;
}

/**
 * Calls a method through a link and waits for its answer.
 *
 * @param {object} link - serviceLink.js's ResourcePulseLink.
 * @param {string} methodName - The method.
 * @returns {Promise<{error: Error|null, reply: GLib.Variant|null}>} What the link answered.
 */
function callThroughLink(link, methodName) {
    return new Promise(resolve => link.call(methodName, null, (error, reply) => resolve({error, reply})));
}

/**
 * Makes a link on a connection that records what it delivers.
 *
 * @param {Gio.DBusConnection} connection - The connection.
 * @returns {{link: object, owners: Array<string|null>, samples: GLib.Variant[]}} The link, and every owner and every
 *     Sample's parameters it delivered, in order.
 */
function makeRecordingLink(connection) {
    const owners = [];
    const samples = [];
    const link = createResourcePulseLink(connection, {
        onOwnerChanged: nameOwner => owners.push(nameOwner),
        onSample: parameters => samples.push(parameters),
    });
    return {link, owners, samples};
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
 * Serves the Resource Pulse interface for a fake sampler under the real bus name on the private bus, runs a row
 * against it, and takes it all down whatever happens.
 *
 * @param {(fixture: object) => Promise<void>} body - The row; gets {sampler, service, isNameOwned, serviceName,
 *     releaseName, clientConnection, logged, makeClient}: serviceName is the owner's unique name, and releaseName()
 *     gives the bus name up before the row ends.
 * @returns {Promise<void>}
 */
async function withServedResourcePulse(body) {
    const sampler = new FakeSampler();
    const serviceConnection = openPrivateBusConnection();
    const clientConnection = openPrivateBusConnection();
    const logged = [];
    const clients = [];
    let service = null;
    let ownerId = null;
    const releaseName = () => {
        if (ownerId === null)
            return;
        Gio.bus_unown_name(ownerId);
        ownerId = null;
    };
    try {
        service = new ResourcePulseDBusService(sampler, serviceConnection);
        const ownership = await ownName(serviceConnection, RESOURCE_PULSE_BUS_NAME);
        ownerId = ownership.ownerId;
        await body({
            sampler, service, clientConnection, logged, isNameOwned: ownership.isOwned, releaseName,
            serviceName: serviceConnection.get_unique_name(),
            makeClient: () => {
                const client = new PulseClient({
                    connection: clientConnection,
                    errorLog: new RateLimitedLogger({nowUsec: () => GLib.get_monotonic_time(),
                        write: line => logged.push(line)}),
                });
                clients.push(client);
                return client;
            },
        });
    } finally {
        for (const client of clients)
            client.destroy();
        releaseName();
        service?.destroy();
        closeConnections([clientConnection, serviceConnection]);
    }
}

test('link: the owner appears, GetState answers, a Sample arrives, and after destroy() no callback is called', () =>
    withServedResourcePulse(async ({sampler, isNameOwned, serviceName, releaseName, clientConnection}) => {
        const recordedCalls = recordCalls(clientConnection);
        const recording = makeRecordingLink(clientConnection);
        const isSubscribedFromCreation = recording.link.isSampleSubscribed;
        // A second link on the same connection stays live: that it sees the Sample and the owner leaving after the
        // first is destroyed proves both reached this connection, and that one link's destroy() spares the other.
        const control = makeRecordingLink(clientConnection);
        try {
            const isOwnerSeen = await waitUntil(() => recording.owners.length >= 1 && control.owners.length >= 1,
                BUS_ROUND_TRIP_TIMEOUT_MS);
            const stateAnswer = await callThroughLink(recording.link, GET_STATE_METHOD_NAME);
            sampler.publish(TICK_SNAPSHOT, TICK_APPENDED_HISTORY);
            const isSampleSeen = await waitUntil(() => recording.samples.length >= 1, BUS_ROUND_TRIP_TIMEOUT_MS);
            recording.link.destroy();
            recording.link.destroy();
            sampler.publish(TICK_SNAPSHOT, TICK_APPENDED_HISTORY);
            releaseName();
            const hasControlSeenBoth = await waitUntil(
                () => control.samples.length >= 2 && control.owners.at(-1) === null, BUS_ROUND_TRIP_TIMEOUT_MS);
            const [stateText] = stateAnswer.reply?.deepUnpack() ?? [null];
            const [sampleText] = recording.samples[0]?.deepUnpack() ?? [null];
            const sample = parseSamplePayload(sampleText);
            // The call's shape carries what the client's rows cannot see: every call has DBUS_CALL_TIMEOUT_MS.
            assertEqual({
                isNameOwned, isOwnerSeen, isSampleSeen, hasControlSeenBoth, isSubscribedFromCreation,
                isSubscribedAfterDestroy: recording.link.isSampleSubscribed,
                owners: recording.owners, sampleCount: recording.samples.length,
                calls: recordedCalls, stateError: stateAnswer.error,
                stateSignature: stateAnswer.reply?.get_type_string() ?? null,
                stateSequence: parseStatePayload(stateText)?.sequence ?? null,
                sampleSignature: recording.samples[0]?.get_type_string() ?? null,
                sample: {snapshot: sample?.snapshot ?? null, sequence: sample?.sequence ?? null},
                control: {owners: control.owners, sampleCount: control.samples.length},
            }, {
                isNameOwned: true, isOwnerSeen: true, isSampleSeen: true, hasControlSeenBoth: true,
                isSubscribedFromCreation: true, isSubscribedAfterDestroy: false,
                owners: [serviceName], sampleCount: 1,
                calls: [{
                    busName: RESOURCE_PULSE_BUS_NAME, objectPath: RESOURCE_PULSE_OBJECT_PATH,
                    interfaceName: RESOURCE_PULSE_INTERFACE_NAME, methodName: GET_STATE_METHOD_NAME,
                    flags: Gio.DBusCallFlags.NO_AUTO_START, timeoutMs: DBUS_CALL_TIMEOUT_MS,
                }],
                stateError: null, stateSignature: ONE_STRING_SIGNATURE, stateSequence: 0,
                sampleSignature: ONE_STRING_SIGNATURE, sample: {snapshot: TICK_SNAPSHOT, sequence: 1},
                control: {owners: [serviceName, null], sampleCount: 2},
            });
        } finally {
            recording.link.destroy();
            control.link.destroy();
        }
    }));

test('client on a private bus with no systemd: StartUnit fails, yet it follows the service\'s name, fills its ' +
    'histories from GetState, draws each Sample and holds a watch while wanted', () =>
    withServedResourcePulse(async ({sampler, service, isNameOwned, logged, makeClient}) => {
        sampler.cpuHistory.push(0.25);
        sampler.memoryHistory.push(0.6);
        // Taken now, on the monotonic clock the service and the client share, so the state is fresh.
        const stateSnapshot = {...STATE_SNAPSHOT, takenAtUsec: GLib.get_monotonic_time()};
        sampler.latestSnapshot = stateSnapshot;
        const client = makeClient();
        const notifications = [];
        client.addListener(snapshot => notifications.push(snapshot));
        client.start();
        client.setDetailWatchWanted(true);
        const hasStartUnitFailed = () => logged.some(line => line.includes('StartUnit'));
        const isReady = await waitUntil(
            () => notifications.length >= 1 && service.detailWatchCount === 1 && hasStartUnitFailed(),
            BUS_ROUND_TRIP_TIMEOUT_MS);
        sampler.publish(TICK_SNAPSHOT, TICK_APPENDED_HISTORY);
        const hasDrawnSample = await waitUntil(() => notifications.length >= 2, BUS_ROUND_TRIP_TIMEOUT_MS);
        assertEqual({
            isNameOwned, isReady, hasDrawnSample, notifications,
            histories: {cpu: client.cpuHistory.values(), memory: client.memoryHistory.values()},
            detailWatchCount: service.detailWatchCount,
        }, {
            isNameOwned: true, isReady: true, hasDrawnSample: true, notifications: [stateSnapshot, TICK_SNAPSHOT],
            histories: {cpu: [0.25, 0.5], memory: [0.6, 0.25]}, detailWatchCount: 1,
        });
    }));

test('client on a private bus: destroy() releases its watch on the service although its connection stays open, as ' +
    'the shell\'s does', () =>
    withServedResourcePulse(async ({service, clientConnection, makeClient}) => {
        const client = makeClient();
        client.start();
        client.setDetailWatchWanted(true);
        const isWatched = await waitUntil(() => service.detailWatchCount === 1, BUS_ROUND_TRIP_TIMEOUT_MS);
        client.destroy();
        const isReleased = await waitUntil(() => service.detailWatchCount === 0, BUS_ROUND_TRIP_TIMEOUT_MS);
        assertEqual({isWatched, isReleased, isConnectionOpen: !clientConnection.is_closed()},
            {isWatched: true, isReleased: true, isConnectionOpen: true});
    }));

test('client on a private bus: start() asks the session bus\'s systemd for StartUnit("resource-pulse.service", ' +
    '"replace") on its Manager at /org/freedesktop/systemd1', async () => {
    const systemdConnection = openPrivateBusConnection();
    const clientConnection = openPrivateBusConnection();
    const startUnitCalls = [];
    const exportedManager = Gio.DBusExportedObject.wrapJSObject(SYSTEMD_MANAGER_INTERFACE_XML, {
        StartUnit: (unitName, mode) => {
            startUnitCalls.push({unitName, mode});
            return START_UNIT_JOB_PATH;
        },
    });
    let ownerId = null;
    let client = null;
    try {
        exportedManager.export(systemdConnection, SYSTEMD_OBJECT_PATH);
        const ownership = await ownName(systemdConnection, SYSTEMD_BUS_NAME);
        ownerId = ownership.ownerId;
        const logged = [];
        client = new PulseClient({
            connection: clientConnection,
            errorLog: new RateLimitedLogger({nowUsec: () => GLib.get_monotonic_time(), write: line => logged.push(line)}),
        });
        client.start();
        const didCall = await waitUntil(() => startUnitCalls.length >= 1, BUS_ROUND_TRIP_TIMEOUT_MS);
        // The client has handled systemd's (o) reply once a later round trip to the same peer is back.
        const isReplyHandled = await pingPeer(clientConnection, SYSTEMD_BUS_NAME);
        assertEqual({isNameOwned: ownership.isOwned, didCall, isReplyHandled, startUnitCalls, logged},
            {isNameOwned: true, didCall: true, isReplyHandled: true,
                startUnitCalls: [{unitName: 'resource-pulse.service', mode: 'replace'}], logged: []});
    } finally {
        client?.destroy();
        if (ownerId !== null)
            Gio.bus_unown_name(ownerId);
        exportedManager.unexport();
        closeConnections([clientConnection, systemdConnection]);
    }
});
