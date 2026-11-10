// The network source's IO: the uplink from NetworkManager's cached properties, the VPN tunnel from /proc/net/route,
// and the count of SSH control-master sockets (their directory listed by name, never a socket opened), gathered for
// lib/network.js. Every read is injectable; the defaults are the real ones.
//
// NetworkManager is read through a proxy on the system bus that never starts it: its cached `PrimaryConnectionType`
// is the `Type` of the active connection `PrimaryConnection` names (empty when that is '/', none), so one cache read
// covers what a second call on the connection's object would. NetworkManager not running (no name owner, or no system
// bus) is an uplink of nulls, not an error.
import GLib from 'gi://GLib';

import {parseRouteTable, tunnelFromRoutes, uplinkFromNetworkManager} from '../../lib/network.js';
import {
    isNotFoundError, listEntryNames, readFileRefusingSecrets, systemBusProxyOrNull,
} from './sourceIo.js';

/** The source's name, as COCKPIT_SOURCE_NAMES lists it. */
const SOURCE_NAME = 'network';
const NETWORK_MANAGER_BUS_NAME = 'org.freedesktop.NetworkManager';
const NETWORK_MANAGER_OBJECT_PATH = '/org/freedesktop/NetworkManager';
const NETWORK_MANAGER_INTERFACE_NAME = 'org.freedesktop.NetworkManager';
const PRIMARY_CONNECTION_TYPE_PROPERTY = 'PrimaryConnectionType';
const CONNECTIVITY_PROPERTY = 'Connectivity';
const WIRELESS_ENABLED_PROPERTY = 'WirelessEnabled';
/** The manager properties whose change changes the uplink: a PropertiesChanged naming none of them is ignored. */
const UPLINK_PROPERTY_NAMES = [
    'PrimaryConnection', PRIMARY_CONNECTION_TYPE_PROPERTY, CONNECTIVITY_PROPERTY, WIRELESS_ENABLED_PROPERTY,
];
/** GDBusProxy's signal for a PropertiesChanged on its interface. */
const PROPERTIES_CHANGED_SIGNAL = 'g-properties-changed';
const PROC_NET_ROUTE_PATH = '/proc/net/route';
/** Where the SSH config's ControlPath puts the control masters' sockets (named by a hash), under the home directory. */
const SSH_SOCKETS_RELATIVE_PATH = '.ssh/sockets';
/** The uplink while NetworkManager is not running: nothing known. */
const UNKNOWN_UPLINK = Object.freeze({kind: null, connectivity: null, wifiEnabled: null});
/** The interval the source writes; the scheduler stamps the effective one over it (ruling R2). */
const PLACEHOLDER_INTERVAL_SECONDS = 0;

/**
 * @returns {object|null} The real NetworkManager proxy; null without a system bus.
 */
function networkManagerProxyOrNull() {
    return systemBusProxyOrNull({
        busName: NETWORK_MANAGER_BUS_NAME,
        objectPath: NETWORK_MANAGER_OBJECT_PATH,
        interfaceName: NETWORK_MANAGER_INTERFACE_NAME,
    });
}

/** The network source: the uplink, the VPN tunnel and the live SSH control masters. */
export class NetworkSource {
    /**
     * @param {object} [dependencies] - The IO; each defaults to the real one.
     * @param {object|null} [dependencies.networkManagerProxy] - A Gio.DBusProxy on NetworkManager's manager object
     *     (or a fake with get_name_owner, get_cached_property, connect and disconnect); null when there is none.
     * @param {(path: string) => string} [dependencies.readFile] - Reads a file; throws when it cannot.
     * @param {(path: string) => string[]} [dependencies.listDirectory] - A directory's entry names; throws when it
     *     cannot list it.
     * @param {string} [dependencies.homeDirectory] - The user's home, under which the SSH sockets are.
     * @param {() => number} [dependencies.nowUsec] - Wall-clock microseconds; the placeholder sampledAtUsec.
     */
    constructor({
        networkManagerProxy = networkManagerProxyOrNull(),
        readFile = readFileRefusingSecrets,
        listDirectory = listEntryNames,
        homeDirectory = GLib.get_home_dir(),
        nowUsec = () => GLib.get_real_time(),
    } = {}) {
        this._networkManagerProxy = networkManagerProxy;
        this._readFile = readFile;
        this._listDirectory = listDirectory;
        this._sshSocketsDirectory = `${homeDirectory}/${SSH_SOCKETS_RELATIVE_PATH}`;
        this._nowUsec = nowUsec;
        this._propertiesChangedHandlerId = null;
    }

    /** @returns {string} 'network'. */
    get name() {
        return SOURCE_NAME;
    }

    /**
     * Samples the network.
     *
     * @returns {Promise<object>} The source in parseNetworkSource's shape; sampledAtUsec and intervalSeconds are
     *     placeholders the scheduler overwrites. sshMasterCount is 0 without a sockets directory and null when it
     *     exists but cannot be listed.
     * @throws {Error} (as a rejection) When /proc/net/route cannot be read.
     */
    async sample() {
        const routes = parseRouteTable(this._readFile(PROC_NET_ROUTE_PATH));
        return {
            sampledAtUsec: this._nowUsec(),
            intervalSeconds: PLACEHOLDER_INTERVAL_SECONDS,
            uplink: this._readUplink(),
            vpn: tunnelFromRoutes(routes),
            sshMasterCount: this._countSshMasters(),
        };
    }

    /**
     * Calls onChange when NetworkManager reports a change to a property the uplink is built from.
     *
     * @param {() => void} onChange - Called with no arguments.
     * @returns {void}
     */
    watchChanges(onChange) {
        if (this._networkManagerProxy === null || this._propertiesChangedHandlerId !== null)
            return;
        this._propertiesChangedHandlerId = this._networkManagerProxy.connect(PROPERTIES_CHANGED_SIGNAL,
            (_proxy, changedProperties, invalidatedPropertyNames) => {
                const touchedPropertyNames = [
                    ...Object.keys(changedProperties.deep_unpack()), ...(invalidatedPropertyNames ?? []),
                ];
                if (touchedPropertyNames.some(propertyName => UPLINK_PROPERTY_NAMES.includes(propertyName)))
                    onChange();
            });
    }

    /**
     * Disconnects from NetworkManager's signal. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        if (this._propertiesChangedHandlerId === null)
            return;
        this._networkManagerProxy.disconnect(this._propertiesChangedHandlerId);
        this._propertiesChangedHandlerId = null;
    }

    /**
     * @returns {{kind: string|null, connectivity: string|null, wifiEnabled: boolean|null}} The uplink from
     *     NetworkManager's cached properties; every field null while NetworkManager is not running.
     */
    _readUplink() {
        const proxy = this._networkManagerProxy;
        if (proxy === null || proxy.get_name_owner() === null)
            return {...UNKNOWN_UPLINK};
        const cachedValue = propertyName => proxy.get_cached_property(propertyName)?.unpack() ?? null;
        return uplinkFromNetworkManager({
            primaryConnectionType: cachedValue(PRIMARY_CONNECTION_TYPE_PROPERTY),
            connectivity: cachedValue(CONNECTIVITY_PROPERTY),
            wirelessEnabled: cachedValue(WIRELESS_ENABLED_PROPERTY),
        });
    }

    /**
     * @returns {number|null} The entries of the SSH sockets directory, each a control master's socket: listed by
     *     name, never opened. 0 when the directory does not exist; null when it exists but cannot be listed.
     */
    _countSshMasters() {
        try {
            return this._listDirectory(this._sshSocketsDirectory).length;
        } catch (error) {
            return isNotFoundError(error) ? 0 : null;
        }
    }
}
