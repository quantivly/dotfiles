// lib/cockpitProtocol.js: the names and the interface of Cockpit1, the JSON its builders write and its skew-tolerant
// parsers read. Every builder runs each source and the layout through the reader the parser uses, so a field no reader
// lists never leaves the service.
import Gio from 'gi://Gio';
import {test, assertEqual} from './harness.js';
// The member names are read through the namespace, so a missing export fails its row rather than the whole run.
import * as cockpitProtocol from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';

/**
 * A state with every field set to a value its reader accepts, in the order the parser lists the fields: two session
 * rows of different states, counts for every state, one mount of each kind, and a config error beside a layout.
 */
const FULL_STATE = {
    serviceStartedAtUsec: 1_794_000_000_000_000,
    latestPublishedAtUsec: 1_794_000_004_000_000,
    layout: {
        monitor: {vendor: 'DEL', product: 'DELL U2723QE'},
        groups: [
            {id: 'machine', caption: 'MACHINE', columns: 2, cards: ['system', 'apps']},
            {id: 'agents', caption: 'AGENTS', columns: 1, cards: ['sessions']},
        ],
    },
    configError: "groups[2].cards[0]: unknown card id 'weather'",
    sources: {
        sessions: {
            sampledAtUsec: 1_794_000_003_000_000,
            intervalSeconds: 5,
            herdrRunning: true,
            totalMemoryBytes: 4_000_000_000,
            counts: {working: 1, blocked: 1, idle: 0, done: 0, unknown: 0},
            rows: [
                {
                    id: 'w1:p1', name: 'host-sync', state: 'working', idleSeconds: 12, idleFromProcessAge: false,
                    memoryBytes: 3_000_000_000, workspaceId: 'w1', paneId: 'p1', account: 'quantivly-1',
                    contextPercent: 42,
                },
                {
                    id: 'w2:p3', name: 'zvi/cockpit', state: 'blocked', idleSeconds: 600, idleFromProcessAge: true,
                    memoryBytes: 1_000_000_000, workspaceId: 'w2', paneId: 'p3', account: 'toysim-1',
                    contextPercent: 7.5,
                },
            ],
        },
        network: {
            sampledAtUsec: 1_794_000_003_500_000,
            intervalSeconds: 10,
            uplink: {kind: 'wired', connectivity: 'full', wifiEnabled: false},
            vpn: {isUp: true, interfaceName: 'tun0'},
            sshMasterCount: 2,
        },
        mounts: {
            sampledAtUsec: 1_794_000_002_000_000,
            intervalSeconds: 30,
            rows: [
                {
                    mountPoint: '/media/user/BACKUP', label: 'BACKUP', kind: 'removable', filesystemType: 'ext4',
                    freeBytes: 500_000_000_000, totalBytes: 2_000_000_000_000,
                },
                {
                    mountPoint: '/mnt/share', label: 'share', kind: 'network', filesystemType: 'cifs', freeBytes: null,
                    totalBytes: null,
                },
            ],
        },
    },
};

test('cockpitProtocol: the names and the interface', () => {
    assertEqual(cockpitProtocol.COCKPIT_BUS_NAME, 'io.github.quantivly.dotfiles.Cockpit1');
    assertEqual(cockpitProtocol.COCKPIT_OBJECT_PATH, '/io/github/quantivly/dotfiles/Cockpit1');
    const nodeInfo = Gio.DBusNodeInfo.new_for_xml(cockpitProtocol.COCKPIT_INTERFACE_XML);
    const iface = nodeInfo.lookup_interface(cockpitProtocol.COCKPIT_INTERFACE_NAME);
    assertEqual(iface.methods.map(m => m.name).sort(), ['FocusSession', 'GetState', 'UnwatchCockpit', 'WatchCockpit']);
    assertEqual(iface.signals.map(s => s.name), ['Changed']);
});
test('cockpitProtocol: a full state round-trips', () => {
    assertEqual(cockpitProtocol.parseCockpitStatePayload(cockpitProtocol.buildCockpitStatePayload(FULL_STATE)),
        {protocol: 1, ...FULL_STATE});
});
test('cockpitProtocol: an unknown field is ignored and a mistyped one is null for itself alone', () => {
    const text = JSON.stringify({...JSON.parse(cockpitProtocol.buildCockpitStatePayload(FULL_STATE)), extra: 1,
        sources: {...FULL_STATE.sources, network: {...FULL_STATE.sources.network, sshMasterCount: 'two'}}});
    const parsed = cockpitProtocol.parseCockpitStatePayload(text);
    assertEqual(parsed.extra, undefined);
    assertEqual(parsed.sources.network.sshMasterCount, null);
    assertEqual(parsed.sources.network.vpn, FULL_STATE.sources.network.vpn);
});
test('cockpitProtocol: a session row with an unlisted state is dropped, the others kept', () => {
    const rows = [
        ...FULL_STATE.sources.sessions.rows, {...FULL_STATE.sources.sessions.rows[0], id: 'x', state: 'napping'},
    ];
    const parsed = cockpitProtocol.parseSessionsSource({...FULL_STATE.sources.sessions, rows});
    assertEqual(parsed.rows.length, FULL_STATE.sources.sessions.rows.length);
});
test('cockpitProtocol: Changed carries only the sources named', () => {
    const changed = cockpitProtocol.parseChangedPayload(cockpitProtocol.buildChangedPayload(
        {publishedAtUsec: 5, sources: {mounts: FULL_STATE.sources.mounts}}));
    assertEqual(Object.keys(changed.sources), ['mounts']);
    assertEqual(changed.sources.mounts, FULL_STATE.sources.mounts);
});
test('cockpitProtocol: a FocusSession reply with nothing known reads as all null', () => {
    assertEqual(cockpitProtocol.parseFocusSessionReply('{}'), {focused: null, windowPid: null, error: null});
});
test('cockpitProtocol: a field no reader lists never leaves the builder', () => {
    const sessions = {
        ...FULL_STATE.sources.sessions, lastText: 'model prose',
        rows: [{...FULL_STATE.sources.sessions.rows[0], cwd: '/home/x'}],
    };
    const text = cockpitProtocol.buildCockpitStatePayload({...FULL_STATE, sources: {...FULL_STATE.sources, sessions}});
    assertEqual(text.includes('lastText'), false);
    assertEqual(text.includes('"cwd"'), false);
});
test('cockpitProtocol: text that is not a JSON object parses to null as a whole', () => {
    assertEqual(cockpitProtocol.parseCockpitStatePayload('[]'), null);
});
test('cockpitProtocol: the state writes its top-level numbers before the layout and the sources', () => {
    const text = cockpitProtocol.buildCockpitStatePayload(FULL_STATE);
    const firstNestedIndex = Math.min(text.indexOf('"layout"'), text.indexOf('"sources"'));
    const isWrittenBeforeNested = quotedFieldName =>
        text.indexOf(quotedFieldName) >= 0 && text.indexOf(quotedFieldName) < firstNestedIndex;
    assertEqual(['"protocol"', '"serviceStartedAtUsec"', '"latestPublishedAtUsec"'].map(isWrittenBeforeNested),
        [true, true, true]);
});
test('cockpitProtocol: a layout drops an incomplete group and reads a missing monitor as unknown', () => {
    const groups = [
        ...FULL_STATE.layout.groups,
        {id: 'no-caption', columns: 1, cards: ['sol']},
        {id: 'bad-columns', caption: 'X', columns: 1.5, cards: ['sol']},
        {id: 'bad-cards', caption: 'X', columns: 1, cards: ['sol', 7]},
    ];
    assertEqual(cockpitProtocol.parseLayout({groups}),
        {monitor: {vendor: null, product: null}, groups: FULL_STATE.layout.groups});
    assertEqual(cockpitProtocol.parseLayout({monitor: FULL_STATE.layout.monitor}), null);
});
test('cockpitProtocol: a mount row of an unlisted kind is dropped, the others kept', () => {
    const rows = [...FULL_STATE.sources.mounts.rows, {...FULL_STATE.sources.mounts.rows[0], kind: 'local'}];
    assertEqual(cockpitProtocol.parseMountsSource({...FULL_STATE.sources.mounts, rows}), FULL_STATE.sources.mounts);
});
test('cockpitProtocol: Changed carries the layout and its error beside the sources only when given', () => {
    const withLayout = cockpitProtocol.parseChangedPayload(cockpitProtocol.buildChangedPayload(
        {publishedAtUsec: 5, sources: {}, layout: FULL_STATE.layout, configError: null}));
    assertEqual(withLayout, {publishedAtUsec: 5, sources: {}, layout: FULL_STATE.layout, configError: null});
    const withoutLayout = cockpitProtocol.buildChangedPayload({publishedAtUsec: 5, sources: {}});
    assertEqual([withoutLayout.includes('"layout"'), withoutLayout.includes('"configError"')], [false, false]);
});
test('cockpitProtocol: a FocusSession reply round-trips, and a mistyped field is null for itself alone', () => {
    const reply = {focused: true, windowPid: 4242, error: null};
    assertEqual(cockpitProtocol.parseFocusSessionReply(cockpitProtocol.buildFocusSessionReply(reply)), reply);
    assertEqual(cockpitProtocol.parseFocusSessionReply('{"focused":"yes","windowPid":-1,"error":"herdr: gone"}'),
        {focused: null, windowPid: null, error: 'herdr: gone'});
});
