// lib/cockpitFormat.js: every word and fraction a cockpit card and its tooltip draw, as pure functions.
import {test, assertEqual} from './harness.js';
import * as cockpitFormat from '../extensions/resource-pulse@dotfiles/lib/cockpitFormat.js';

/** A session row with every field set; a row below overrides what it is testing. */
const BASE_ROW = {
    id: 'w1:p1', name: 'host-sync', state: 'working', idleSeconds: 12, idleFromProcessAge: false,
    memoryBytes: 3_000_000_000, workspaceId: 'w1', paneId: 'p1', account: 'quantivly-1', contextPercent: 42,
};
const SESSIONS = {
    sampledAtUsec: 1_794_000_003_000_000, intervalSeconds: 5, herdrRunning: true, totalMemoryBytes: 4_000_000_000,
    counts: {working: 1, blocked: 1, idle: 0, done: 0, unknown: 0},
    rows: [BASE_ROW, {...BASE_ROW, id: 'w2:p3', name: 'zvi/cockpit', state: 'blocked', idleSeconds: 600,
        idleFromProcessAge: true, memoryBytes: 1_000_000_000, paneId: 'p3', account: 'toysim-1', contextPercent: 7.5}],
};
const NETWORK = {
    sampledAtUsec: 1, intervalSeconds: 10, uplink: {kind: 'wired', connectivity: 'full', wifiEnabled: false},
    vpn: {isUp: true, interfaceName: 'tun0'}, sshMasterCount: 2,
};
const MOUNTS = {
    sampledAtUsec: 1, intervalSeconds: 30,
    rows: [
        {mountPoint: '/media/user/BACKUP', label: 'BACKUP', kind: 'removable', filesystemType: 'ext4',
            freeBytes: 500_000_000_000, totalBytes: 2_000_000_000_000},
        {mountPoint: '/mnt/share', label: 'share', kind: 'network', filesystemType: 'cifs', freeBytes: null,
            totalBytes: null},
    ],
};

/**
 * Sessions with `count` rows copied from BASE_ROW, each with a distinct id.
 *
 * @param {number} count - Number of rows.
 * @returns {object} A sessions source.
 */
function sessionsWithRowCount(count) {
    const rows = Array.from({length: count}, (_, index) => ({...BASE_ROW, id: `w:p${index}`}));
    return {...SESSIONS, rows};
}

/**
 * The idle text of a single row.
 *
 * @param {object} overrides - Fields of BASE_ROW to change.
 * @returns {string} The row's idleText.
 */
function idleTextOf(overrides) {
    return cockpitFormat.sessionRows({...SESSIONS, rows: [{...BASE_ROW, ...overrides}]}).rows[0].idleText;
}

test('cockpitFormat: header counts in SESSION_STATES order, zeros included; memory and row count', () => {
    assertEqual(cockpitFormat.sessionsHeader(SESSIONS), {
        title: 'SESSIONS', count: '2',
        counts: [{state: 'working', count: 1}, {state: 'blocked', count: 1}, {state: 'idle', count: 0},
            {state: 'done', count: 0}, {state: 'unknown', count: 0}],
        totalMemory: '3.7G',
    });
    assertEqual(cockpitFormat.sessionsHeader({...SESSIONS, rows: [], totalMemoryBytes: null}).count, '0');
    assertEqual(cockpitFormat.sessionsHeader({...SESSIONS, totalMemoryBytes: null}).totalMemory, '—');
});

test('cockpitFormat: eight rows draw six and say +2 more; six or fewer say nothing', () => {
    const eight = cockpitFormat.sessionRows(sessionsWithRowCount(8));
    assertEqual(eight.rows.length, 6);
    assertEqual(eight.overflowText, '+2 more');
    assertEqual(eight.rows.map(row => row.id), ['w:p0', 'w:p1', 'w:p2', 'w:p3', 'w:p4', 'w:p5']);
    assertEqual(cockpitFormat.sessionRows(sessionsWithRowCount(6)).overflowText, null);
    assertEqual(cockpitFormat.sessionRows(sessionsWithRowCount(0)), {rows: [], overflowText: null});
});

test('cockpitFormat: idle text is one unit rounded down; * only from process age; unknown is a dash', () => {
    assertEqual(idleTextOf({idleSeconds: 59}), '59s');
    assertEqual(idleTextOf({idleSeconds: 60}), '1m');
    assertEqual(idleTextOf({idleSeconds: 61}), '1m');
    assertEqual(idleTextOf({idleSeconds: 3599}), '59m');
    assertEqual(idleTextOf({idleSeconds: 3600}), '1h');
    assertEqual(idleTextOf({idleSeconds: 86399}), '23h');
    assertEqual(idleTextOf({idleSeconds: 86400}), '1d');
    assertEqual(idleTextOf({idleSeconds: 2 * 3600 + 1800}), '2h');
    assertEqual(idleTextOf({idleSeconds: 3 * 86400 + 5}), '3d');
    assertEqual(idleTextOf({idleSeconds: 600, idleFromProcessAge: true}), '10m*');
    assertEqual(idleTextOf({idleSeconds: null, idleFromProcessAge: true}), '—');
});

test('cockpitFormat: long idle only for idle or done at or past the dim threshold', () => {
    const isLongIdleOf = (state, idleSeconds) =>
        cockpitFormat.sessionRows({...SESSIONS, rows: [{...BASE_ROW, state, idleSeconds}]}).rows[0].isLongIdle;
    assertEqual(isLongIdleOf('idle', 1800), true);
    assertEqual(isLongIdleOf('done', 7200), true);
    assertEqual(isLongIdleOf('idle', 1799), false);
    assertEqual(isLongIdleOf('working', 7200), false);
    assertEqual(isLongIdleOf('blocked', 7200), false);
    assertEqual(isLongIdleOf('idle', null), false);
});

test('cockpitFormat: memory text and fraction; the largest row is 1, unknown is 0, waiting is blocked', () => {
    const rows = cockpitFormat.sessionRows(SESSIONS).rows;
    assertEqual(rows.map(row => [row.memoryText, row.memoryFraction, row.isWaiting]),
        [['2.8G', 1, false], ['954M', 1 / 3, true]]);
    const mixed = cockpitFormat.sessionRows({...SESSIONS, rows: [
        {...BASE_ROW, memoryBytes: null}, {...BASE_ROW, memoryBytes: 340 * 1024 * 1024}]}).rows;
    assertEqual(mixed.map(row => [row.memoryText, row.memoryFraction]), [['—', 0], ['340M', 1]]);
    const memoryTextOf = memoryBytes =>
        cockpitFormat.sessionRows({...SESSIONS, rows: [{...BASE_ROW, memoryBytes}]}).rows[0].memoryText;
    assertEqual(memoryTextOf(1024 ** 3), '1.0G');
    assertEqual(memoryTextOf(1024 ** 3 - 1), '1024M');
    const allZero = cockpitFormat.sessionRows({...SESSIONS, rows: [{...BASE_ROW, memoryBytes: 0}]}).rows;
    assertEqual(allZero[0].memoryFraction, 0);
});

test('cockpitFormat: a redacted name passes through unchanged', () => {
    const rows = cockpitFormat.sessionRows({...SESSIONS, rows: [{...BASE_ROW, name: '—'}]}).rows;
    assertEqual(rows[0].name, '—');
});

test('cockpitFormat: tooltip lines with and without account and context', () => {
    const note = 'memory: process only; MCP servers and tool shells not counted';
    assertEqual(cockpitFormat.sessionTooltip(BASE_ROW, {account: 'quantivly-1', contextPercent: 42, paneId: 'p1'}),
        ['working', 'pane p1', 'account quantivly-1', 'context 42%', note]);
    assertEqual(cockpitFormat.sessionTooltip(BASE_ROW, {account: null, contextPercent: null, paneId: 'p1'}),
        ['working', 'pane p1', note]);
    assertEqual(cockpitFormat.sessionTooltip(BASE_ROW, {account: 'toysim-1', contextPercent: null, paneId: 'p3'}),
        ['working', 'pane p3', 'account toysim-1', note]);
});

test('cockpitFormat: apps rows cap at the limit, scale to the first memory entry, and null lists are empty', () => {
    const cpuRanking = Array.from({length: 8}, (_, i) => ({groupKey: `g${i}`, name: `app${i}`, cpuPercent: 150 - i * 20}));
    const memoryRanking = [{groupKey: 'a', name: 'big', memoryBytes: 2 * 1024 ** 3}, {groupKey: 'b', name: 'small',
        memoryBytes: 512 * 1024 ** 2}];
    const rows = cockpitFormat.appsRows({cpuRanking, memoryRanking});
    assertEqual(rows.cpu.length, 6);
    assertEqual(rows.cpu[0], {name: 'app0', cpuText: '150%', cpuFraction: 1});
    assertEqual(rows.cpu[2], {name: 'app2', cpuText: '110%', cpuFraction: 1});
    assertEqual(rows.cpu[5], {name: 'app5', cpuText: '50%', cpuFraction: 0.5});
    assertEqual(rows.memory, [{name: 'big', memoryText: '2.0G', memoryFraction: 1},
        {name: 'small', memoryText: '512M', memoryFraction: 0.25}]);
    assertEqual(cockpitFormat.appsRows({cpuRanking, memoryRanking}, {limit: 2}).cpu.length, 2);
    assertEqual(cockpitFormat.appsRows({cpuRanking: null, memoryRanking: null}), {cpu: [], memory: []});
});

test('cockpitFormat: connections rows for the fixture, in order uplink, vpn, ssh, mounts', () => {
    const rows = cockpitFormat.connectionsRows(NETWORK, MOUNTS);
    assertEqual(rows, [
        {kind: 'uplink', icon: 'network-wired-symbolic', text: 'wired · wifi off', tooltip: ['internet: full'], fraction: null},
        {kind: 'vpn', icon: 'network-vpn-symbolic', text: 'VPN up (tun0)', tooltip: ['VPN up (tun0)'], fraction: null},
        {kind: 'ssh', icon: 'utilities-terminal-symbolic', text: '2 live ssh masters', tooltip: ['2 live ssh masters'], fraction: null},
        {kind: 'mount', icon: 'drive-removable-media-symbolic', text: 'BACKUP · 465.7G free',
            tooltip: ['/media/user/BACKUP', 'ext4', '465.7G free of 1862.6G'], fraction: 0.75},
        {kind: 'mount', icon: 'folder-remote-symbolic', text: 'share', tooltip: ['/mnt/share', 'cifs'], fraction: null},
    ]);
});

test('cockpitFormat: uplink kinds, vpn states and ssh counts', () => {
    const uplinkOf = (uplink) => cockpitFormat.connectionsRows({...NETWORK, uplink}, MOUNTS)[0];
    assertEqual(uplinkOf({kind: 'wired', connectivity: 'full', wifiEnabled: true}).text, 'wired');
    assertEqual(uplinkOf({kind: 'wired', connectivity: 'full', wifiEnabled: null}).text, 'wired');
    const wifi = uplinkOf({kind: 'wifi', connectivity: 'portal', wifiEnabled: true});
    assertEqual([wifi.icon, wifi.text, wifi.tooltip], ['network-wireless-symbolic', 'wifi', ['internet: portal']]);
    const none = uplinkOf({kind: 'none', connectivity: null, wifiEnabled: null});
    assertEqual([none.icon, none.text, none.tooltip], ['network-offline-symbolic', 'offline', ['internet: unknown']]);
    const vpnOf = (vpn) => cockpitFormat.connectionsRows({...NETWORK, vpn}, MOUNTS)[1].text;
    assertEqual(vpnOf({isUp: true, interfaceName: null}), 'VPN up');
    assertEqual(vpnOf({isUp: false, interfaceName: null}), 'VPN down');
    assertEqual(vpnOf({isUp: null, interfaceName: null}), 'VPN unknown');
    const sshTextOf = (sshMasterCount) => cockpitFormat.connectionsRows({...NETWORK, sshMasterCount}, MOUNTS)[2].text;
    assertEqual(sshTextOf(0), 'no ssh masters');
    assertEqual(sshTextOf(1), '1 live ssh master');
    assertEqual(sshTextOf(null), 'ssh masters unknown');
    assertEqual(cockpitFormat.connectionsRows(NETWORK, {...MOUNTS, rows: []}).length, 3);
});

test('cockpitFormat: noDataText goes through the stub clock; the herdr line is fixed', () => {
    const clock = usec => `T${usec}`;
    assertEqual(cockpitFormat.noDataText(null, clock), 'no data');
    assertEqual(cockpitFormat.noDataText(5, clock), 'no data since T5');
    assertEqual(cockpitFormat.herdrNotRunningText, 'herdr not running');
});

test('cockpitFormat: the card titles, and the sessions header\'s title is the sessions card\'s', () =>
    assertEqual([cockpitFormat.appsCardTitle, cockpitFormat.connectionsCardTitle, cockpitFormat.sessionsCardTitle,
        cockpitFormat.sessionsHeader(SESSIONS).title], ['APPS', 'CONNECTIONS', 'SESSIONS', 'SESSIONS']));

test('cockpitFormat: the apps card draws any apps object, even with null rankings, and no data for none', () =>
    assertEqual([{cpuRanking: null, memoryRanking: null}, null, undefined].map(cockpitFormat.canDrawApps),
        [true, false, false]));

test('cockpitFormat: the sessions card draws a source with its rows and a count for every state, empty rows ' +
    'included; a missing source, rows, counts, or first or last count is no data', () => {
    const withCounts = countOverrides => ({...SESSIONS, counts: {...SESSIONS.counts, ...countOverrides}});
    assertEqual([
        SESSIONS, {...SESSIONS, rows: []}, null, undefined, {...SESSIONS, rows: null}, {...SESSIONS, counts: null},
        withCounts({working: null}), withCounts({unknown: null}), withCounts({unknown: undefined}),
    ].map(cockpitFormat.canDrawSessions), [true, true, false, false, false, false, false, false, false]);
});

test('cockpitFormat: the connections card draws both sources with the uplink, the VPN and the mount rows; an ' +
    'unknown ssh count is still drawn; any missing part is no data', () => {
    const cases = [
        [NETWORK, MOUNTS], [{...NETWORK, sshMasterCount: null}, MOUNTS], [NETWORK, {...MOUNTS, rows: []}],
        [null, MOUNTS], [NETWORK, null], [undefined, MOUNTS], [{...NETWORK, uplink: null}, MOUNTS],
        [{...NETWORK, vpn: null}, MOUNTS], [NETWORK, {...MOUNTS, rows: null}],
    ];
    assertEqual(cases.map(([network, mounts]) => cockpitFormat.canDrawConnections(network, mounts)),
        [true, true, true, false, false, false, false, false, false]);
});

test('cockpitFormat: state icons and style classes for the five states', () => {
    assertEqual(['working', 'blocked', 'idle', 'done', 'unknown'].map(cockpitFormat.stateIconName), [
        'media-playback-start-symbolic', 'dialog-warning-symbolic', 'media-playback-pause-symbolic',
        'emblem-ok-symbolic', 'dialog-question-symbolic']);
    assertEqual(cockpitFormat.stateStyleClass('blocked'), 'rp-cockpit-state-blocked');
});
