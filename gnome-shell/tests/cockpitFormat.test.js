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

/** The memory caveat every session tooltip ends with. */
const MEMORY_NOTE = 'memory: process only; MCP servers and tool shells not counted';
/** The uplink row's icons, written out rather than imported, so a changed icon fails here instead of moving with it. */
const WIRED_ICON = 'network-wired-symbolic';
const WIFI_ICON = 'network-wireless-symbolic';
const OFFLINE_ICON = 'network-offline-symbolic';
const ONLINE_ICON = 'network-transmit-receive-symbolic';
const UNKNOWN_ICON = 'dialog-question-symbolic';
/** The uplink tooltip's line for a primary connection that is neither wired nor Wi-Fi. */
const OTHER_PRIMARY_CONNECTION_NOTE = 'primary connection: neither wired nor Wi-Fi';

/**
 * A mounts source with `count` removable mounts labelled m0, m1, …, sizes unknown.
 *
 * @param {number} count - Number of mounts.
 * @returns {object} A mounts source.
 */
function mountsWithRowCount(count) {
    const rows = Array.from({length: count}, (_, index) => ({...MOUNTS.rows[0], label: `m${index}`,
        mountPoint: `/media/user/m${index}`, freeBytes: null, totalBytes: null}));
    return {...MOUNTS, rows};
}

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

test('cockpitFormat: header counts in SESSION_STATES order, zeros included, each written as text; memory and row ' +
    'count', () => {
    assertEqual(cockpitFormat.sessionsHeader(SESSIONS), {
        title: 'SESSIONS', count: '2',
        counts: [{state: 'working', count: '1'}, {state: 'blocked', count: '1'}, {state: 'idle', count: '0'},
            {state: 'done', count: '0'}, {state: 'unknown', count: '0'}],
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
    assertEqual(memoryTextOf(1024 ** 3 - 1), '1.0G');
    assertEqual(memoryTextOf(1023.5 * 1024 * 1024), '1.0G');
    assertEqual(memoryTextOf(1023.4 * 1024 * 1024), '1023M');
    const allZero = cockpitFormat.sessionRows({...SESSIONS, rows: [{...BASE_ROW, memoryBytes: 0}]}).rows;
    assertEqual(allZero[0].memoryFraction, 0);
});

test('cockpitFormat: a redacted name passes through unchanged', () => {
    const rows = cockpitFormat.sessionRows({...SESSIONS, rows: [{...BASE_ROW, name: '—'}]}).rows;
    assertEqual(rows[0].name, '—');
});

test('cockpitFormat: tooltip lines with and without account and context', () => {
    assertEqual(cockpitFormat.sessionTooltip(BASE_ROW, {account: 'quantivly-1', contextPercent: 42, paneId: 'p1'}),
        ['working', 'pane p1', 'account quantivly-1', 'context 42%', MEMORY_NOTE]);
    assertEqual(cockpitFormat.sessionTooltip(BASE_ROW, {account: null, contextPercent: null, paneId: 'p1'}),
        ['working', 'pane p1', MEMORY_NOTE]);
    assertEqual(cockpitFormat.sessionTooltip(BASE_ROW, {account: 'toysim-1', contextPercent: null, paneId: 'p3'}),
        ['working', 'pane p3', 'account toysim-1', MEMORY_NOTE]);
});

test('cockpitFormat: a session whose pane is unknown (an id too long, or none) gets no pane line, never "pane null"',
    () => assertEqual([null, undefined].map(paneId =>
        cockpitFormat.sessionTooltip(BASE_ROW, {account: 'quantivly-1', contextPercent: 42, paneId})), [
        ['working', 'account quantivly-1', 'context 42%', MEMORY_NOTE],
        ['working', 'account quantivly-1', 'context 42%', MEMORY_NOTE],
    ]));

test('cockpitFormat: each session row carries its state\'s icon and class and the tooltip of its own source row, ' +
    'whatever the order, so no row can show another session\'s details', () => {
    const ownDetailsOf = sessions => cockpitFormat.sessionRows(sessions).rows
        .map(row => [row.id, row.iconName, row.iconStyleClass, row.tooltip]);
    const first = ['w1:p1', 'media-playback-start-symbolic', 'rp-cockpit-state-working',
        ['working', 'pane p1', 'account quantivly-1', 'context 42%', MEMORY_NOTE]];
    const second = ['w2:p3', 'dialog-warning-symbolic', 'rp-cockpit-state-blocked',
        ['waiting on you', 'pane p3', 'account toysim-1', 'context 8%', MEMORY_NOTE]];
    assertEqual({
        asPublished: ownDetailsOf(SESSIONS),
        reversed: ownDetailsOf({...SESSIONS, rows: [...SESSIONS.rows].reverse()}),
        paneUnknown: ownDetailsOf({...SESSIONS, rows: [{...BASE_ROW, paneId: null}]})[0][3],
    }, {
        asPublished: [first, second],
        reversed: [second, first],
        paneUnknown: ['working', 'account quantivly-1', 'context 42%', MEMORY_NOTE],
    });
});

test('cockpitFormat: apps rows cap at the limit, scale to the first memory entry, and null lists are empty', () => {
    const cpuRanking = Array.from({length: 8}, (_, i) => ({groupKey: `g${i}`, name: `app${i}`, cpuPercent: 150 - i * 20}));
    const memoryRanking = [{groupKey: 'a', name: 'big', memoryBytes: 2 * 1024 ** 3}, {groupKey: 'b', name: 'small',
        memoryBytes: 512 * 1024 ** 2}];
    const rows = cockpitFormat.appsRows({cpuRanking, memoryRanking});
    assertEqual(rows.cpu.length, 6);
    assertEqual(rows.cpu[0], {name: 'app0', cpuText: '150%', cpuFraction: 1, tooltip: ['g0']});
    assertEqual(rows.cpu[2], {name: 'app2', cpuText: '110%', cpuFraction: 1, tooltip: ['g2']});
    assertEqual(rows.cpu[5], {name: 'app5', cpuText: '50%', cpuFraction: 0.5, tooltip: ['g5']});
    assertEqual(rows.memory, [{name: 'big', memoryText: '2.0G', memoryFraction: 1, tooltip: ['a']},
        {name: 'small', memoryText: '512M', memoryFraction: 0.25, tooltip: ['b']}]);
    assertEqual(cockpitFormat.appsRows({cpuRanking, memoryRanking}, {limit: 2}).cpu.length, 2);
    assertEqual(cockpitFormat.appsRows({cpuRanking: null, memoryRanking: null}), {cpu: [], memory: []});
});

test('cockpitFormat: each apps row carries its own ranking entry\'s group key as its tooltip, in both rankings and ' +
    'under a limit', () => {
    const cpuRanking = [{groupKey: 'unit-b.scope', name: 'Firefox', cpuPercent: 40},
        {groupKey: 'org.gnome.Ptyxis', name: 'Ptyxis', cpuPercent: 10}];
    const memoryRanking = [{groupKey: 'org.gnome.Ptyxis', name: 'Ptyxis', memoryBytes: 2048},
        {groupKey: 'unit-b.scope', name: 'Firefox', memoryBytes: 1024}];
    const keysOf = rows => rows.map(row => [row.name, row.tooltip]);
    const rows = cockpitFormat.appsRows({cpuRanking, memoryRanking});
    assertEqual({
        cpu: keysOf(rows.cpu),
        memory: keysOf(rows.memory),
        limited: keysOf(cockpitFormat.appsRows({cpuRanking, memoryRanking}, {limit: 1}).memory),
    }, {
        cpu: [['Firefox', ['unit-b.scope']], ['Ptyxis', ['org.gnome.Ptyxis']]],
        memory: [['Ptyxis', ['org.gnome.Ptyxis']], ['Firefox', ['unit-b.scope']]],
        limited: [['Ptyxis', ['org.gnome.Ptyxis']]],
    });
});

test('cockpitFormat: connections rows for the fixture, in order uplink, vpn, ssh, mounts, with nothing cut', () => {
    assertEqual(cockpitFormat.connectionsRows(NETWORK, MOUNTS), {rows: [
        {kind: 'uplink', icon: 'network-wired-symbolic', text: 'wired · wifi off', tooltip: ['internet: full'],
            fraction: null, iconStyleClass: null},
        {kind: 'vpn', icon: 'network-vpn-symbolic', text: 'VPN up (tun0)', tooltip: ['VPN up (tun0)'], fraction: null,
            iconStyleClass: 'rp-cockpit-state-working'},
        {kind: 'ssh', icon: 'utilities-terminal-symbolic', text: '2 live ssh masters', tooltip: ['2 live ssh masters'],
            fraction: null, iconStyleClass: null},
        {kind: 'mount', icon: 'drive-removable-media-symbolic', text: 'BACKUP · 465.7G free',
            tooltip: ['/media/user/BACKUP', 'ext4', '465.7G free of 1862.6G'], fraction: 0.75, iconStyleClass: null},
        {kind: 'mount', icon: 'folder-remote-symbolic', text: 'share', tooltip: ['/mnt/share', 'cifs'], fraction: null,
            iconStyleClass: null},
    ], overflowText: null});
});

test('cockpitFormat: connections rows stop at CONNECTIONS_CARD_ROW_LIMIT (8): at the limit nothing is cut; past it ' +
    'only mounts are, the first ones kept in order, and "+N more" says how many', () => {
    const shapeOf = ({rows, overflowText}) => ({texts: rows.map(row => row.text), overflowText});
    const fixedTexts = ['wired · wifi off', 'VPN up (tun0)', '2 live ssh masters'];
    const mountTexts = count => Array.from({length: count}, (_, index) => `m${index}`);
    assertEqual({
        atTheLimit: shapeOf(cockpitFormat.connectionsRows(NETWORK, mountsWithRowCount(5))),
        onePast: shapeOf(cockpitFormat.connectionsRows(NETWORK, mountsWithRowCount(6))),
        fourPastAGivenLimit: shapeOf(cockpitFormat.connectionsRows(NETWORK, mountsWithRowCount(5), {limit: 4})),
    }, {
        atTheLimit: {texts: [...fixedTexts, ...mountTexts(5)], overflowText: null},
        onePast: {texts: [...fixedTexts, ...mountTexts(5)], overflowText: '+1 more'},
        fourPastAGivenLimit: {texts: [...fixedTexts, ...mountTexts(1)], overflowText: '+4 more'},
    });
});

test('cockpitFormat: a row bar is its fraction of the track in whole pixels, clamped to the track; no fraction (or ' +
    'not a number) is an empty bar', () => {
    const trackWidthPx = 63;
    assertEqual([0.5, 1, 0.25, 1.4, -0.2, 0, null, undefined, NaN]
        .map(fraction => cockpitFormat.rowBarWidthPx(fraction, trackWidthPx)), [32, 63, 16, 63, 0, 0, 0, 0, 0]);
    assertEqual(cockpitFormat.rowBarWidthPx(0.5, 0), 0);
});

test('cockpitFormat: uplink kinds, vpn states and ssh counts', () => {
    const uplinkOf = (uplink) => cockpitFormat.connectionsRows({...NETWORK, uplink}, MOUNTS).rows[0];
    assertEqual(uplinkOf({kind: 'wired', connectivity: 'full', wifiEnabled: true}).text, 'wired');
    assertEqual(uplinkOf({kind: 'wired', connectivity: 'full', wifiEnabled: null}).text, 'wired');
    const wifi = uplinkOf({kind: 'wifi', connectivity: 'portal', wifiEnabled: true});
    assertEqual([wifi.icon, wifi.text, wifi.tooltip],
        ['network-wireless-symbolic', 'wifi · portal', ['internet: portal']]);
    const none = uplinkOf({kind: 'none', connectivity: null, wifiEnabled: null});
    assertEqual([none.icon, none.text, none.tooltip], ['network-offline-symbolic', 'offline', ['internet: unknown']]);
    const vpnOf = (vpn) => cockpitFormat.connectionsRows({...NETWORK, vpn}, MOUNTS).rows[1].text;
    assertEqual(vpnOf({isUp: true, interfaceName: null}), 'VPN up');
    assertEqual(vpnOf({isUp: false, interfaceName: null}), 'VPN down');
    assertEqual(vpnOf({isUp: null, interfaceName: null}), 'VPN unknown');
    const sshTextOf = (sshMasterCount) =>
        cockpitFormat.connectionsRows({...NETWORK, sshMasterCount}, MOUNTS).rows[2].text;
    assertEqual(sshTextOf(0), 'no ssh masters');
    assertEqual(sshTextOf(1), '1 live ssh master');
    assertEqual(sshTextOf(null), 'ssh masters unknown');
    assertEqual(cockpitFormat.connectionsRows(NETWORK, {...MOUNTS, rows: []}).rows.length, 3);
});


test('cockpitFormat: a session row\'s tooltip opens with its state\'s word: "waiting on you" for blocked, herdr\'s ' +
    'own word for the others', () => {
    const firstTooltipLineOf = state => cockpitFormat.sessionTooltip({...BASE_ROW, state},
        {account: null, contextPercent: null, paneId: null})[0];
    assertEqual(['working', 'blocked', 'idle', 'done', 'unknown'].map(firstTooltipLineOf),
        ['working', 'waiting on you', 'idle', 'done', 'unknown']);
});

test('cockpitFormat: a mount with no filesystem type has no tooltip line for it, never an empty one', () => {
    const mountOf = mount => cockpitFormat.connectionsRows(NETWORK, {...MOUNTS, rows: [mount]}).rows[3];
    assertEqual([
        mountOf({...MOUNTS.rows[0], filesystemType: null}).tooltip,
        mountOf({...MOUNTS.rows[1], filesystemType: null}).tooltip,
    ], [['/media/user/BACKUP', '465.7G free of 1862.6G'], ['/mnt/share']]);
});

/**
 * The uplink row for an uplink.
 *
 * @param {{kind: string|null, connectivity: string|null, wifiEnabled: boolean|null}} uplink - The uplink.
 * @returns {{icon: string, text: string, tooltip: string[]}} Its row's icon, words and tooltip.
 */
function uplinkLookOf(uplink) {
    const {icon, text, tooltip} = cockpitFormat.connectionsRows({...NETWORK, uplink}, MOUNTS).rows[0];
    return {icon, text, tooltip};
}

test('cockpitFormat: a wired or Wi-Fi uplink with full connectivity reads its kind alone (docked: wired · wifi off); ' +
    'limited and portal keep the kind\'s icon and name the verdict after it', () => assertEqual([
    {kind: 'wired', connectivity: 'full', wifiEnabled: false},
    {kind: 'wifi', connectivity: 'full', wifiEnabled: true},
    {kind: 'wired', connectivity: 'limited', wifiEnabled: false},
    {kind: 'wifi', connectivity: 'portal', wifiEnabled: true},
].map(uplinkLookOf), [
    {icon: WIRED_ICON, text: 'wired · wifi off', tooltip: ['internet: full']},
    {icon: WIFI_ICON, text: 'wifi', tooltip: ['internet: full']},
    {icon: WIRED_ICON, text: 'wired · limited', tooltip: ['internet: limited']},
    {icon: WIFI_ICON, text: 'wifi · portal', tooltip: ['internet: portal']},
]));

test('cockpitFormat: a wired or Wi-Fi uplink with connectivity none draws the offline icon and says there is no ' +
    'internet, so a link with no route out never reads as a healthy one', () => assertEqual([
    {kind: 'wired', connectivity: 'none', wifiEnabled: false},
    {kind: 'wifi', connectivity: 'none', wifiEnabled: true},
].map(uplinkLookOf), [
    {icon: OFFLINE_ICON, text: 'wired · no internet', tooltip: ['internet: none']},
    {icon: OFFLINE_ICON, text: 'wifi · no internet', tooltip: ['internet: none']},
]));

test('cockpitFormat: a primary connection neither wired nor Wi-Fi (kind none: a VPN on a full tunnel, a tethered ' +
    'phone) that reaches the internet reads online, the part named, with a tooltip line saying so; one that does not ' +
    'reads offline', () => assertEqual([
    {kind: 'none', connectivity: 'full', wifiEnabled: true},
    {kind: 'none', connectivity: 'limited', wifiEnabled: true},
    {kind: 'none', connectivity: 'none', wifiEnabled: true},
    {kind: 'none', connectivity: 'unknown', wifiEnabled: null},
].map(uplinkLookOf), [
    {icon: ONLINE_ICON, text: 'online', tooltip: ['internet: full', OTHER_PRIMARY_CONNECTION_NOTE]},
    {icon: ONLINE_ICON, text: 'online · limited', tooltip: ['internet: limited', OTHER_PRIMARY_CONNECTION_NOTE]},
    {icon: OFFLINE_ICON, text: 'offline', tooltip: ['internet: none']},
    {icon: OFFLINE_ICON, text: 'offline', tooltip: ['internet: unknown']},
]));

test('cockpitFormat: an uplink nothing is known of (no NetworkManager: kind and connectivity null) reads "uplink ' +
    'unknown" with the unknown icon, never offline', () =>
    assertEqual(uplinkLookOf({kind: null, connectivity: null, wifiEnabled: null}),
        {icon: UNKNOWN_ICON, text: 'uplink unknown', tooltip: ['internet: unknown']}));

test('cockpitFormat: the VPN row\'s icon carries the working state\'s class while up and the idle state\'s while ' +
    'down or unknown; the uplink, ssh and mount rows carry none', () => {
    const vpnClassOf = vpn => cockpitFormat.connectionsRows({...NETWORK, vpn}, MOUNTS).rows[1].iconStyleClass;
    assertEqual({
        vpn: [{isUp: true, interfaceName: 'tun0'}, {isUp: false, interfaceName: null},
            {isUp: null, interfaceName: null}].map(vpnClassOf),
        others: cockpitFormat.connectionsRows(NETWORK, MOUNTS).rows
            .filter(row => row.kind !== 'vpn').map(row => row.iconStyleClass),
    }, {
        vpn: ['rp-cockpit-state-working', 'rp-cockpit-state-idle', 'rp-cockpit-state-idle'],
        others: [null, null, null, null],
    });
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
