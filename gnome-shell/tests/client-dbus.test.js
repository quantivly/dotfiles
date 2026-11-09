// pulseClient.js with its REAL defaults (a Gio.DBusProxy, GLib timeouts, the StartUnit call) on a PRIVATE message bus.
// Run only by run-private-bus.js under `dbus-run-session`, never by run.js. Every connection is opened by address
// through service-dbus.test.js's openPrivateBusConnection, which refuses anything but the private bus. The service side
// is the real service/dbusService.js over a fake sampler, owning the real bus name; systemd's side is either absent
// (nothing owns org.freedesktop.systemd1 here) or a fake Manager that records StartUnit.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {FakeSampler, openPrivateBusConnection, waitUntil} from './service-dbus.test.js';
import {PulseClient} from '../extensions/resource-pulse@dotfiles/pulseClient.js';
import {ResourcePulseDBusService} from '../extensions/resource-pulse@dotfiles/service/dbusService.js';
import {RESOURCE_PULSE_BUS_NAME} from '../extensions/resource-pulse@dotfiles/lib/protocol.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';

const BUS_ROUND_TRIP_TIMEOUT_MS = 2000;
const SYSTEMD_BUS_NAME = 'org.freedesktop.systemd1';
const SYSTEMD_OBJECT_PATH = '/org/freedesktop/systemd1';
const SYSTEMD_MANAGER_INTERFACE_NAME = 'org.freedesktop.systemd1.Manager';
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
 * @param {(fixture: object) => Promise<void>} body - The row; gets {sampler, service, isNameOwned, clientConnection,
 *     logged, makeClient}.
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
    try {
        service = new ResourcePulseDBusService(sampler, serviceConnection);
        const ownership = await ownName(serviceConnection, RESOURCE_PULSE_BUS_NAME);
        ownerId = ownership.ownerId;
        await body({
            sampler, service, clientConnection, logged, isNameOwned: ownership.isOwned,
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
        if (ownerId !== null)
            Gio.bus_unown_name(ownerId);
        service?.destroy();
        closeConnections([clientConnection, serviceConnection]);
    }
}

test('client on a private bus with no systemd: StartUnit fails, yet it follows the service\'s name, fills its ' +
    'histories from GetState, draws each Sample and holds a watch while wanted', () =>
    withServedResourcePulse(async ({sampler, service, isNameOwned, logged, makeClient}) => {
        sampler.cpuHistory.push(0.25);
        sampler.memoryHistory.push(0.6);
        sampler.latestSnapshot = STATE_SNAPSHOT;
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
            isNameOwned: true, isReady: true, hasDrawnSample: true, notifications: [STATE_SNAPSHOT, TICK_SNAPSHOT],
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
        assertEqual({isNameOwned: ownership.isOwned, didCall, startUnitCalls, logged},
            {isNameOwned: true, didCall: true, startUnitCalls: [{unitName: 'resource-pulse.service', mode: 'replace'}],
                logged: []});
    } finally {
        client?.destroy();
        if (ownerId !== null)
            Gio.bus_unown_name(ownerId);
        exportedManager.unexport();
        closeConnections([clientConnection, systemdConnection]);
    }
});
