// lib/network.js: the VPN tunnel from synthetic /proc/net/route text, and the uplink from NetworkManager's values.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// The member names are read through the namespace, so a missing export fails its row rather than the whole run.
import * as network from '../extensions/resource-pulse@dotfiles/lib/network.js';
import * as cockpitProtocol from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';

const FIXTURE_DIRECTORY_URI = GLib.uri_resolve_relative(import.meta.url, 'fixtures/cockpit/', GLib.UriFlags.NONE);
const [FIXTURE_DIRECTORY] = GLib.filename_from_uri(FIXTURE_DIRECTORY_URI);
const NM_CONNECTIVITY_NOT_DEFINED = 9;
const SAMPLED_AT_USEC = 1;
const INTERVAL_SECONDS = 10;
const SSH_MASTER_COUNT = 2;

/**
 * @param {string} relativePath - A path under gnome-shell/tests/fixtures/cockpit.
 * @returns {string} The file's text.
 */
function readFixture(relativePath) {
    const path = GLib.build_filenamev([FIXTURE_DIRECTORY, relativePath]);
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

test('network: a tunnel with a gateway route is up, one without is down, no tunnel is down', () => {
    assertEqual(network.tunnelFromRoutes(network.parseRouteTable(readFixture('proc-net-route-tunnel.txt'))), {isUp: true, interfaceName: 'tun0'});
    assertEqual(network.tunnelFromRoutes(network.parseRouteTable(readFixture('proc-net-route-no-gateway.txt'))), {isUp: false, interfaceName: 'tun0'});
    assertEqual(network.tunnelFromRoutes(network.parseRouteTable(readFixture('proc-net-route-plain.txt'))), {isUp: false, interfaceName: null});
});
test('network: an empty or headerless table is no routes, never a throw', () => {
    assertEqual(network.parseRouteTable(''), []);
    assertEqual(network.parseRouteTable(null), []);
});
test('network: a route line gives its interface, hex columns and numeric flags', () => {
    const routes = network.parseRouteTable(readFixture('proc-net-route-tunnel.txt'));
    assertEqual(routes[0], {interfaceName: 'tun0', destinationHex: '00000000', gatewayHex: '0100000A', flags: 3});
    assertEqual(routes.length, 3);
});
test('network: blank, short and non-hex-flag lines are skipped', () => {
    const text = 'Iface\tDestination\tGateway\tFlags\n\nwg0\t00000000\n\nwg0\t00000000\t00000000\tZZ\nwg0\t00000000\t00000000\t0001\n';
    assertEqual(network.parseRouteTable(text).map(route => route.flags), [1]);
});
test('network: a tunnel prefix matches the start of the interface name only', () => {
    const route = {destinationHex: '00000000', gatewayHex: '00000000', flags: 3};
    assertEqual(network.tunnelFromRoutes([{...route, interfaceName: 'stunnel0'}]), {isUp: false, interfaceName: null});
    assertEqual(network.tunnelFromRoutes([{...route, interfaceName: 'wg0'}]), {isUp: true, interfaceName: 'wg0'});
    assertEqual(network.tunnelFromRoutes([]), {isUp: false, interfaceName: null});
});
test('network: a default route on a tunnel without the gateway flag is up', () => {
    const routes = [{interfaceName: 'tap1', destinationHex: '00000000', gatewayHex: '00000000', flags: 1}];
    assertEqual(network.tunnelFromRoutes(routes), {isUp: true, interfaceName: 'tap1'});
});
test('network: a non-default tunnel route is up only through the gateway flag, tested as a bit', () => {
    const nonDefaultTunnelRoute = {interfaceName: 'tun0', destinationHex: '0100000A', gatewayHex: '0100000A'};
    assertEqual(network.tunnelFromRoutes([{...nonDefaultTunnelRoute, flags: 3}]), {isUp: true, interfaceName: 'tun0'});
    assertEqual(network.tunnelFromRoutes([{...nonDefaultTunnelRoute, flags: 1}]), {isUp: false, interfaceName: 'tun0'});
});
test('network: NetworkManager values map to the uplink enums', () => {
    assertEqual(network.uplinkFromNetworkManager({primaryConnectionType: '802-3-ethernet', connectivity: 4, wirelessEnabled: false}), {kind: 'wired', connectivity: 'full', wifiEnabled: false});
    assertEqual(network.uplinkFromNetworkManager({primaryConnectionType: null, connectivity: 1, wirelessEnabled: null}), {kind: 'none', connectivity: 'none', wifiEnabled: null});
    assertEqual(network.uplinkFromNetworkManager({primaryConnectionType: '802-11-wireless', connectivity: NM_CONNECTIVITY_NOT_DEFINED, wirelessEnabled: true}).connectivity, 'unknown');
});
test('network: every NetworkManager connectivity number and an odd wireless flag map as documented', () => {
    const connectivityOf = connectivity => network.uplinkFromNetworkManager({primaryConnectionType: 'vpn', connectivity, wirelessEnabled: 'yes'});
    assertEqual([0, 1, 2, 3, 4, null].map(connectivity => connectivityOf(connectivity).connectivity), ['unknown', 'none', 'portal', 'limited', 'full', 'unknown']);
    assertEqual(connectivityOf(4), {kind: 'none', connectivity: 'full', wifiEnabled: null});
});
test('network: the built uplink and tunnel round-trip through parseNetworkSource', () => {
    const source = {
        sampledAtUsec: SAMPLED_AT_USEC,
        intervalSeconds: INTERVAL_SECONDS,
        uplink: network.uplinkFromNetworkManager({primaryConnectionType: '802-11-wireless', connectivity: 3, wirelessEnabled: true}),
        vpn: network.tunnelFromRoutes(network.parseRouteTable(readFixture('proc-net-route-tunnel.txt'))),
        sshMasterCount: SSH_MASTER_COUNT,
    };
    assertEqual(cockpitProtocol.parseNetworkSource(source), source);
});
