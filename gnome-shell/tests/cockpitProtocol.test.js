// lib/cockpitProtocol.js: the names and the interface of Cockpit1, the JSON its builders write and its skew-tolerant
// parsers read. Every builder runs each source and the layout through the reader the parser uses, so a field no reader
// lists never leaves the service.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
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
/** One field name no reader lists per object level of a state; withUnlistedFieldAtEveryLevel plants each. */
const UNLISTED_FIELD_NAME_BY_LEVEL = {
    state: 'unlistedInState',
    layout: 'unlistedInLayout',
    monitor: 'unlistedInMonitor',
    layoutGroup: 'unlistedInLayoutGroup',
    sources: 'unlistedInSources',
    sessions: 'unlistedInSessions',
    counts: 'unlistedInCounts',
    sessionRow: 'unlistedInSessionRow',
    network: 'unlistedInNetwork',
    uplink: 'unlistedInUplink',
    vpn: 'unlistedInVpn',
    mounts: 'unlistedInMounts',
    mountRow: 'unlistedInMountRow',
};
const UNLISTED_FIELD_NAMES = Object.values(UNLISTED_FIELD_NAME_BY_LEVEL);
/** The field no reader lists, planted in a FocusSession reply. */
const UNLISTED_REPLY_FIELD_NAME = 'unlistedInReply';
/** herdr's own text for a pane that is gone: what a FocusSession reply's error must never carry (ruling R18). */
const HERDR_FREE_TEXT_ERROR = 'herdr: pane_not_found: pane not found';
/** The readers' caps, written out rather than imported, so a changed constant fails here instead of moving with it. */
const ID_MAX_CHARS = 128;
const PATH_MAX_CHARS = 1024;
/** The most window candidates a FocusSession reply carries, written out as the caps above are. */
const WINDOW_PID_CANDIDATES_MAX = 64;
/** A character outside the Basic Multilingual Plane: one code point, two UTF-16 code units. */
const WIDE_CHARACTER = '\u{1F642}';

/**
 * A copy of a state with one unlisted field planted at every object level: the state, the layout, its monitor and
 * each group, the sources object, each source, the session counts, each session row, the uplink, the VPN tunnel and
 * each mount row.
 *
 * @param {object} state - A state shaped as FULL_STATE.
 * @returns {object} The copy.
 */
function withUnlistedFieldAtEveryLevel(state) {
    const unlistedField = level => ({[UNLISTED_FIELD_NAME_BY_LEVEL[level]]: 'leaked'});
    const {layout, sources: {sessions, network, mounts}} = state;
    return {
        ...state, ...unlistedField('state'),
        layout: {
            ...layout, ...unlistedField('layout'),
            monitor: {...layout.monitor, ...unlistedField('monitor')},
            groups: layout.groups.map(group => ({...group, ...unlistedField('layoutGroup')})),
        },
        sources: {
            ...unlistedField('sources'),
            sessions: {
                ...sessions, ...unlistedField('sessions'),
                counts: {...sessions.counts, ...unlistedField('counts')},
                rows: sessions.rows.map(row => ({...row, ...unlistedField('sessionRow')})),
            },
            network: {
                ...network, ...unlistedField('network'),
                uplink: {...network.uplink, ...unlistedField('uplink')},
                vpn: {...network.vpn, ...unlistedField('vpn')},
            },
            mounts: {
                ...mounts, ...unlistedField('mounts'),
                rows: mounts.rows.map(row => ({...row, ...unlistedField('mountRow')})),
            },
        },
    };
}

/**
 * The planted unlisted field names a text holds.
 *
 * @param {string} text - Built JSON.
 * @returns {string[]} Those of UNLISTED_FIELD_NAMES found in it, in their order.
 */
function unlistedFieldNamesIn(text) {
    return UNLISTED_FIELD_NAMES.filter(fieldName => text.includes(fieldName));
}

/**
 * @param {string} relativePath - A path under gnome-shell/tests/fixtures/cockpit.
 * @returns {string} The file's text.
 */
function readFixture(relativePath) {
    const fixtureDirectoryUri = GLib.uri_resolve_relative(import.meta.url, 'fixtures/cockpit/', GLib.UriFlags.NONE);
    const [fixtureDirectory] = GLib.filename_from_uri(fixtureDirectoryUri);
    const path = GLib.build_filenamev([fixtureDirectory, relativePath]);
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

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
test('cockpitProtocol: a FocusSession reply with nothing known reads as all null and no window candidates', () => {
    assertEqual(cockpitProtocol.parseFocusSessionReply('{}'),
        {focused: null, windowPid: null, error: null, windowPidCandidates: []});
});
test('cockpitProtocol: a field no reader lists never leaves the builder', () => {
    const sessions = {
        ...FULL_STATE.sources.sessions, lastText: 'model prose',
        rows: [{...FULL_STATE.sources.sessions.rows[0], cwd: '/home/x'}],
    };
    const text = cockpitProtocol.buildCockpitStatePayload({...FULL_STATE, sources: {...FULL_STATE.sources, sessions}});
    assertEqual(text.includes('lastText'), false);
    assertEqual(text.includes('"cwd"'), false);
    // The same at every object level. The input is checked to hold every planted field, so the row cannot pass on a
    // plant that went nowhere.
    const plantedState = withUnlistedFieldAtEveryLevel(FULL_STATE);
    assertEqual(unlistedFieldNamesIn(JSON.stringify(plantedState)), UNLISTED_FIELD_NAMES);
    assertEqual(unlistedFieldNamesIn(cockpitProtocol.buildCockpitStatePayload(plantedState)), []);
});
test('cockpitProtocol: a field no reader lists, at any level, never leaves the Changed builder', () => {
    const plantedState = withUnlistedFieldAtEveryLevel(FULL_STATE);
    const plantedChange = {
        publishedAtUsec: 5, sources: plantedState.sources, layout: plantedState.layout,
        configError: plantedState.configError, [UNLISTED_FIELD_NAME_BY_LEVEL.state]: 'leaked',
    };
    assertEqual(unlistedFieldNamesIn(JSON.stringify(plantedChange)), UNLISTED_FIELD_NAMES);
    assertEqual(unlistedFieldNamesIn(cockpitProtocol.buildChangedPayload(plantedChange)), []);
});
test('cockpitProtocol: a field no reader lists, or herdr\'s text as the error, never leaves the FocusSession reply ' +
    'builder', () => {
    const text = cockpitProtocol.buildFocusSessionReply({
        focused: false, windowPid: 4242, error: HERDR_FREE_TEXT_ERROR, [UNLISTED_REPLY_FIELD_NAME]: 'leaked',
    });
    assertEqual([text.includes(UNLISTED_REPLY_FIELD_NAME), text.includes(HERDR_FREE_TEXT_ERROR)], [false, false]);
    assertEqual(JSON.parse(text), {focused: false, windowPid: 4242, error: null, windowPidCandidates: []});
});
test('cockpitProtocol: a FocusSession reply\'s error is one of five codes; any other string reads as null', () => {
    assertEqual(cockpitProtocol.COCKPIT_FOCUS_ERROR_CODES,
        ['unknown-session', 'no-pane', 'herdr-rejected', 'herdr-unreachable', 'internal']);
    assertEqual(Object.isFrozen(cockpitProtocol.COCKPIT_FOCUS_ERROR_CODES), true);
    const readErrors = cockpitProtocol.COCKPIT_FOCUS_ERROR_CODES.map(errorCode =>
        cockpitProtocol.parseFocusSessionReply(JSON.stringify({focused: false, error: errorCode})).error);
    assertEqual(readErrors, cockpitProtocol.COCKPIT_FOCUS_ERROR_CODES);
    const unlistedReply = JSON.stringify({focused: false, windowPid: null, error: 'herdr-on-fire'});
    assertEqual(cockpitProtocol.parseFocusSessionReply(unlistedReply),
        {focused: false, windowPid: null, error: null, windowPidCandidates: []});
});
test('cockpitProtocol: a session row with an empty id or an empty name is dropped, the others kept', () => {
    const [firstRow] = FULL_STATE.sources.sessions.rows;
    const rows = [...FULL_STATE.sources.sessions.rows, {...firstRow, id: ''}, {...firstRow, id: 'x', name: ''}];
    const parsed = cockpitProtocol.parseSessionsSource({...FULL_STATE.sources.sessions, rows});
    assertEqual(parsed.rows, FULL_STATE.sources.sessions.rows);
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
test('cockpitProtocol: a workspace or pane id over 128 characters reads as null, its row kept; one of 128 passes',
    () => {
    const [firstRow] = FULL_STATE.sources.sessions.rows;
    const idAtCap = 'w'.repeat(ID_MAX_CHARS);
    const wideIdAtCap = WIDE_CHARACTER.repeat(ID_MAX_CHARS);
    const idOverCap = 'w'.repeat(ID_MAX_CHARS + 1);
    const rows = [
        {...firstRow, workspaceId: idOverCap, paneId: idOverCap},
        {...firstRow, workspaceId: idAtCap, paneId: wideIdAtCap},
    ];
    const parsed = cockpitProtocol.parseSessionsSource({...FULL_STATE.sources.sessions, rows});
    assertEqual(parsed.rows.map(row => [row.workspaceId, row.paneId]), [[null, null], [idAtCap, wideIdAtCap]]);
});
test('cockpitProtocol: a session row whose id is over 257 characters (a "<workspace>:<pane>" of two 128-character ' +
    'ids) is dropped, the others kept; one of 257 passes', () => {
    const [firstRow] = FULL_STATE.sources.sessions.rows;
    const sessionIdAtCap = `${'w'.repeat(ID_MAX_CHARS)}:${WIDE_CHARACTER.repeat(ID_MAX_CHARS)}`;
    const sessionIdOverCap = `${sessionIdAtCap}x`;
    const rows = [{...firstRow, id: sessionIdOverCap}, {...firstRow, id: sessionIdAtCap}];
    const parsed = cockpitProtocol.parseSessionsSource({...FULL_STATE.sources.sessions, rows});
    assertEqual(parsed.rows.map(row => row.id), [sessionIdAtCap]);
});
test('cockpitProtocol: a mount row whose mount point is over 1024 characters is dropped, the others kept', () => {
    const [firstMount] = FULL_STATE.sources.mounts.rows;
    const mountPointAtCap = `/${'m'.repeat(PATH_MAX_CHARS - 1)}`;
    const mountPointOverCap = `/${'m'.repeat(PATH_MAX_CHARS)}`;
    const rows = [
        ...FULL_STATE.sources.mounts.rows,
        {...firstMount, mountPoint: mountPointOverCap},
        {...firstMount, mountPoint: mountPointAtCap},
    ];
    const parsed = cockpitProtocol.parseMountsSource({...FULL_STATE.sources.mounts, rows});
    const keptMountPoints = [...FULL_STATE.sources.mounts.rows.map(row => row.mountPoint), mountPointAtCap];
    assertEqual(parsed.rows.map(row => row.mountPoint), keptMountPoints);
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
    const reply = {focused: true, windowPid: 4242, error: null, windowPidCandidates: [4242, 4100]};
    assertEqual(cockpitProtocol.parseFocusSessionReply(cockpitProtocol.buildFocusSessionReply(reply)), reply);
    const failedReply = {focused: false, windowPid: null, error: 'herdr-unreachable', windowPidCandidates: []};
    assertEqual(cockpitProtocol.parseFocusSessionReply(cockpitProtocol.buildFocusSessionReply(failedReply)),
        failedReply);
    assertEqual(cockpitProtocol.parseFocusSessionReply('{"focused":"yes","windowPid":-1,"error":"herdr-rejected"}'),
        {focused: null, windowPid: null, error: 'herdr-rejected', windowPidCandidates: []});
});
test('cockpitProtocol: a FocusSession reply\'s windowPidCandidates missing, or not a list, reads as no candidates',
    () => {
        const readCandidates = replyText => cockpitProtocol.parseFocusSessionReply(replyText).windowPidCandidates;
        assertEqual([
            readCandidates('{"focused":true}'), readCandidates('{"focused":true,"windowPidCandidates":4242}'),
            readCandidates('{"focused":true,"windowPidCandidates":{"0":4242}}'),
            readCandidates('{"focused":true,"windowPidCandidates":null}'),
        ], [[], [], [], []]);
    });
test(`cockpitProtocol: a FocusSession reply keeps the first ${WINDOW_PID_CANDIDATES_MAX} window candidates and drops ` +
    'the rest', () => {
    const manyPids = Array.from({length: WINDOW_PID_CANDIDATES_MAX + 6}, (_unused, index) => 5000 + index);
    const replyText = JSON.stringify({focused: true, windowPidCandidates: manyPids});
    assertEqual(cockpitProtocol.parseFocusSessionReply(replyText).windowPidCandidates,
        manyPids.slice(0, WINDOW_PID_CANDIDATES_MAX));
});
test('cockpitProtocol: a FocusSession reply drops a window candidate that is not a count, the others kept', () => {
    const replyText = JSON.stringify(
        {focused: true, windowPidCandidates: [4242, '4243', -1, 1.5, null, true, [4244], 4100, 9007199254740992]});
    assertEqual(cockpitProtocol.parseFocusSessionReply(replyText).windowPidCandidates, [4242, 4100]);
});
test('cockpitProtocol: the nested harness\'s fixture state and focus reply read back unchanged', () => {
    const {state, focusReply} = JSON.parse(readFixture('nested-state.json'));
    const stateTimes = {serviceStartedAtUsec: 1_794_000_000_000_000, latestPublishedAtUsec: 1_794_000_000_000_000};
    const readState = cockpitProtocol.parseCockpitStatePayload(
        cockpitProtocol.buildCockpitStatePayload({...state, ...stateTimes}));
    const readReply = cockpitProtocol.parseFocusSessionReply(cockpitProtocol.buildFocusSessionReply(focusReply));
    assertEqual({readState, readReply}, {readState: {protocol: 1, ...stateTimes, ...state}, readReply: focusReply});
});
