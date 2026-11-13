// The private message bus every bus row runs on, and the guard that refuses any other. It registers no rows: a
// runner imports it without taking on another file's tests (service-dbus.test.js re-exports it for the rows that
// import it from there). Every connection a row opens is opened by address, and only once requirePrivateBusAddress
// has said the address is a path socket inside RESOURCE_PULSE_TEST_BUS_DIR, so a run anywhere else fails instead of
// reaching the live session.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

/** Names the directory the private bus listens in; the state tables that run the bus rows set it. */
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
const POLL_INTERVAL_MS = 20;

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

/**
 * Opens a new connection to the private bus: each one is a separate caller with its own unique name.
 *
 * @returns {Gio.DBusConnection} The connection.
 */
export function openPrivateBusConnection() {
    return Gio.DBusConnection.new_for_address_sync(requirePrivateBusAddress(), CONNECTION_FLAGS, null, null);
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
