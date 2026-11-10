// The network source's pure parts: the VPN tunnel from /proc/net/route text, and the uplink from the values
// NetworkManager reports (both read by the IO layer, service/cockpit.js). They build the objects parseNetworkSource in
// lib/cockpitProtocol.js rebuilds. No Gio, no GLib and no Shell import, so it runs under plain gjs.
import {TUNNEL_INTERFACE_PREFIXES, ROUTE_FLAG_GATEWAY} from './constants.js';

/** A /proc/net/route line has at least Iface, Destination, Gateway and Flags. */
const MIN_ROUTE_COLUMNS = 4;
const ROUTE_COLUMN_SEPARATOR = /\s+/;
const HEX_RADIX = 16;
/** The Destination of a default route, as /proc/net/route writes it. */
const DEFAULT_ROUTE_DESTINATION_HEX = '00000000';
const CONNECTION_TYPE_WIRED = '802-3-ethernet';
const CONNECTION_TYPE_WIFI = '802-11-wireless';
/** NetworkManager's NMConnectivityState numbers, as the connectivity strings of CONNECTIVITY_STATES. */
const CONNECTIVITY_BY_NM_STATE = new Map([[1, 'none'], [2, 'portal'], [3, 'limited'], [4, 'full']]);

/**
 * Parses the text of /proc/net/route.
 *
 * @param {string} text - The file's text: a header line, then one line per route.
 * @returns {Array<{interfaceName: string, destinationHex: string, gatewayHex: string, flags: number}>} The routes
 *     in file order. The header, blank lines, lines with fewer than four columns and lines whose flags are not hex
 *     are skipped; a non-string gives no routes.
 */
export function parseRouteTable(text) {
    if (typeof text !== 'string')
        return [];
    const routes = [];
    text.split('\n').slice(1).forEach(line => {
        const columns = line.trim().split(ROUTE_COLUMN_SEPARATOR);
        if (columns.length < MIN_ROUTE_COLUMNS)
            return;
        const [interfaceName, destinationHex, gatewayHex, flagsHex] = columns;
        const flags = parseInt(flagsHex, HEX_RADIX);
        if (Number.isNaN(flags))
            return;
        routes.push({interfaceName, destinationHex, gatewayHex, flags});
    });
    return routes;
}

/**
 * Reads the VPN tunnel off the route table.
 *
 * @param {Array<{interfaceName: string, destinationHex: string, flags: number}>} routes - parseRouteTable's routes.
 * @returns {{isUp: boolean, interfaceName: string|null}} The tunnel is up when a route on a tunnel interface (name
 *     starting with a TUNNEL_INTERFACE_PREFIXES entry) goes via a gateway or is a default route; interfaceName is the
 *     first tunnel interface in the table, up or not, null when there is none.
 */
export function tunnelFromRoutes(routes) {
    const tunnelRoutes = routes.filter(route =>
        TUNNEL_INTERFACE_PREFIXES.some(prefix => route.interfaceName.startsWith(prefix)));
    const isUp = tunnelRoutes.some(route =>
        (route.flags & ROUTE_FLAG_GATEWAY) !== 0 || route.destinationHex === DEFAULT_ROUTE_DESTINATION_HEX);
    return {isUp, interfaceName: tunnelRoutes.length > 0 ? tunnelRoutes[0].interfaceName : null};
}

/**
 * Maps NetworkManager's values onto the uplink the protocol carries.
 *
 * @param {{primaryConnectionType: *, connectivity: *, wirelessEnabled: *}} networkManagerValues - The primary
 *     connection's type string, the NMConnectivityState number and the wireless-enabled flag.
 * @returns {{kind: string, connectivity: string, wifiEnabled: boolean|null}} kind is 'wired' or 'wifi' for those
 *     connection types and 'none' otherwise; connectivity is the state's name, 'unknown' for 0, null or a number
 *     NetworkManager does not define; wifiEnabled is the flag when boolean, else null.
 */
export function uplinkFromNetworkManager({primaryConnectionType, connectivity, wirelessEnabled}) {
    let kind = 'none';
    if (primaryConnectionType === CONNECTION_TYPE_WIRED)
        kind = 'wired';
    else if (primaryConnectionType === CONNECTION_TYPE_WIFI)
        kind = 'wifi';
    return {
        kind,
        connectivity: CONNECTIVITY_BY_NM_STATE.get(connectivity) ?? 'unknown',
        wifiEnabled: typeof wirelessEnabled === 'boolean' ? wirelessEnabled : null,
    };
}
