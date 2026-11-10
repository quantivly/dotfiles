// lib/sessions.js: the pure session rows, from a synthetic herdr snapshot, hspawn registry entries and process facts.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// The member names are read through the namespace, so a missing export fails its row rather than the whole run.
import * as sessions from '../extensions/resource-pulse@dotfiles/lib/sessions.js';
import * as cockpitProtocol from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';

const FIXTURE_DIRECTORY_URI = GLib.uri_resolve_relative(import.meta.url, 'fixtures/cockpit/', GLib.UriFlags.NONE);
const [FIXTURE_DIRECTORY] = GLib.filename_from_uri(FIXTURE_DIRECTORY_URI);
const REGISTRY_FILE_NAMES = ['wL_p1.json', 'wL_p2.json', 'wL_p6.json'];
const NOW_USEC = 1_000_000e6;
const SAMPLED_AT_USEC = NOW_USEC;
const INTERVAL_SECONDS = 5;
const BYTES_PER_GIB = 1024 ** 3;
const SECONDS_TO_USEC = 1e6;

/**
 * @param {string} relativePath - A path under gnome-shell/tests/fixtures/cockpit.
 * @returns {string} The file's text.
 */
function readFixture(relativePath) {
    const path = GLib.build_filenamev([FIXTURE_DIRECTORY, relativePath]);
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

/**
 * @returns {object} The inputs of buildSessionsSource, built from the fixtures: five claude agents (working with a
 *     registry slug, blocked with a branch, idle with a workspace label, done with a cwd, unknown whose process
 *     vanished) and one codex agent. Memory falls 2, 1, 0.75, 0.25 GiB in that order (sum 4 GiB), null for the last.
 */
function fixtureInputs() {
    const {agents, workspaces} = JSON.parse(readFixture('herdr-snapshot.json')).result.snapshot;
    const registryEntries = REGISTRY_FILE_NAMES.map(name => JSON.parse(readFixture(`hspawn-registry/${name}`)));
    const secondsAgo = seconds => NOW_USEC - seconds * SECONDS_TO_USEC;
    return {
        agents,
        registryEntriesByPaneId: Object.fromEntries(registryEntries.map(entry => [entry.pane_id, entry])),
        workspaceLabelsById: Object.fromEntries(workspaces.map(workspace => [workspace.id, workspace.label])),
        transcriptMtimeUsecBySessionId: {
            'sess-aaa': secondsAgo(5), 'sess-bbb': secondsAgo(600), 'sess-ccc': secondsAgo(7200),
            'sess-ddd': secondsAgo(90_000),
        },
        processInfoByPaneId: {p_5: {pid: 4242, startedAtUsec: secondsAgo(300)}},
        memoryBytesByPaneId: {
            p_1: 2 * BYTES_PER_GIB, p_2: BYTES_PER_GIB, p_3: 0.75 * BYTES_PER_GIB, p_4: 0.25 * BYTES_PER_GIB, p_5: null,
        },
        nowUsec: NOW_USEC,
        sampledAtUsec: SAMPLED_AT_USEC,
        intervalSeconds: INTERVAL_SECONDS,
        herdrRunning: true,
    };
}

test('sessions: herdr statuses map one-to-one and anything else is unknown', () => {
    for (const status of ['working', 'blocked', 'idle', 'done'])
        assertEqual(sessions.sessionStateFromAgentStatus(status), status);
    assertEqual(sessions.sessionStateFromAgentStatus(undefined), 'unknown');
    assertEqual(sessions.sessionStateFromAgentStatus('Working'), 'unknown');
});
test('sessions: the name falls through slug, branch, label, cwd', () => {
    assertEqual(sessions.displayNameForSession({registryEntry: {slug: 'host-sync', branch: 'b'}, workspaceLabel: 'L', cwd: '/x/y'}), 'host-sync');
    assertEqual(sessions.displayNameForSession({registryEntry: {branch: 'zvi/b'}, workspaceLabel: 'L', cwd: '/x/y'}), 'zvi/b');
    assertEqual(sessions.displayNameForSession({registryEntry: null, workspaceLabel: 'L', cwd: '/x/y'}), 'L');
    assertEqual(sessions.displayNameForSession({registryEntry: null, workspaceLabel: null, cwd: '/x/y'}), 'y');
    assertEqual(sessions.displayNameForSession({registryEntry: {slug: 'ghp_' + 'A'.repeat(36)}, workspaceLabel: null, cwd: null}), '—');
});
test('sessions: the name is the dash when nothing names the session', () => {
    assertEqual(sessions.displayNameForSession({registryEntry: null, workspaceLabel: null, cwd: null}), '—');
    assertEqual(sessions.displayNameForSession({registryEntry: {slug: '', branch: 7}, workspaceLabel: '', cwd: '/'}), '—');
});
test('sessions: idle age prefers the transcript and flags the process age', () => {
    assertEqual(sessions.idleAgeForSession({transcriptMtimeUsec: 90e6, processStartedAtUsec: 10e6, nowUsec: 100e6}), {idleSeconds: 10, idleFromProcessAge: false});
    assertEqual(sessions.idleAgeForSession({transcriptMtimeUsec: null, processStartedAtUsec: 10e6, nowUsec: 100e6}), {idleSeconds: 90, idleFromProcessAge: true});
    assertEqual(sessions.idleAgeForSession({transcriptMtimeUsec: null, processStartedAtUsec: null, nowUsec: 100e6}), {idleSeconds: null, idleFromProcessAge: false});
});
test('sessions: idle age rounds down to whole seconds and never goes negative', () => {
    assertEqual(sessions.idleAgeForSession({transcriptMtimeUsec: 98.6e6, processStartedAtUsec: null, nowUsec: 100e6}).idleSeconds, 1);
    assertEqual(sessions.idleAgeForSession({transcriptMtimeUsec: 101e6, processStartedAtUsec: null, nowUsec: 100e6}).idleSeconds, 0);
});
test('sessions: the transcript path mangles the cwd as hreap does', () => {
    assertEqual(sessions.transcriptPathCandidates({cwd: '/home/u/.dotfiles', sessionId: 'abc', homeDirectory: '/home/u'})[0],
        '/home/u/.claude/projects/-home-u--dotfiles/abc.jsonl');
});
test('sessions: the transcript candidates end with the two roots the IO layer globs under', () => {
    assertEqual(sessions.transcriptPathCandidates({cwd: '/home/u/x', sessionId: 'abc', homeDirectory: '/home/u'}), [
        '/home/u/.claude/projects/-home-u-x/abc.jsonl', '/home/u/.claude/projects', '/home/u/.clauth/profiles',
    ]);
    assertEqual(sessions.transcriptPathCandidates({cwd: null, sessionId: 'abc', homeDirectory: '/home/u'}), []);
    assertEqual(sessions.transcriptPathCandidates({cwd: '/x', sessionId: null, homeDirectory: '/home/u'}), []);
});
test('sessions: memory is VmRSS plus VmSwap in bytes, null without VmRSS', () => {
    assertEqual(sessions.memoryBytesFromProcStatus(readFixture('proc-status-claude.txt')), (3_100_000 + 200_000) * 1024);
    assertEqual(sessions.memoryBytesFromProcStatus('Name:\tclaude\n'), null);
});
test('sessions: memory without VmSwap is VmRSS alone', () => {
    assertEqual(sessions.memoryBytesFromProcStatus('VmRSS:\t 100 kB\n'), 100 * 1024);
});
test('sessions: the source lists claude agents only, largest memory first, with counts and a total', () => {
    const source = sessions.buildSessionsSource(fixtureInputs());
    assertEqual(source.rows.map(r => r.state), ['working', 'blocked', 'idle', 'done', 'unknown']);
    assertEqual(source.counts, {working: 1, blocked: 1, idle: 1, done: 1, unknown: 1});
    assertEqual(source.rows.at(-1).memoryBytes, null);           // the process vanished: kept, null
    assertEqual(source.rows.at(-1).idleFromProcessAge, true);
    assertEqual(source.totalMemoryBytes, 4 * 1024 ** 3);
});
test('sessions: a row carries its names, ids, idle age, account and context percent', () => {
    const source = sessions.buildSessionsSource(fixtureInputs());
    assertEqual(source.rows.map(r => r.name), ['host-sync', 'zvi/fix-it', 'Reports', 'notes', 'ghost']);
    assertEqual(source.rows[0], {
        id: 'w_1:p_1', name: 'host-sync', state: 'working', idleSeconds: 5, idleFromProcessAge: false,
        memoryBytes: 2 * BYTES_PER_GIB, workspaceId: 'w_1', paneId: 'p_1', account: 'quantivly-1', contextPercent: 62,
    });
    assertEqual(source.rows.map(r => r.contextPercent), [62, 80, 95, null, null]);
    assertEqual(source.rows.map(r => r.account), ['quantivly-1', 'quantivly-2', 'personal', null, null]);
    assertEqual(source.rows.at(-1).idleSeconds, 300);
    assertEqual([source.sampledAtUsec, source.intervalSeconds, source.herdrRunning], [SAMPLED_AT_USEC, INTERVAL_SECONDS, true]);
});
test('sessions: the id falls back to the pane id, then the session id', () => {
    const [agent] = fixtureInputs().agents;
    const idFor = changes => sessions.buildSessionsSource({...fixtureInputs(), agents: [{...agent, ...changes}]}).rows[0].id;
    assertEqual(idFor({workspace_id: undefined}), 'p_1');
    assertEqual(idFor({workspace_id: undefined, pane_id: undefined}), 'sess-aaa');
});
test('sessions: rows with no known memory sort last, by name', () => {
    const inputs = fixtureInputs();
    inputs.memoryBytesByPaneId = {p_1: null, p_2: null, p_3: 5, p_4: null, p_5: null};
    assertEqual(sessions.buildSessionsSource(inputs).rows.map(r => r.name), ['Reports', 'ghost', 'host-sync', 'notes', 'zvi/fix-it']);
});
test('sessions: a secret-shaped account is published as the dash', () => {
    const inputs = fixtureInputs();
    inputs.agents[0].tokens.acct = 'ghp_' + 'A'.repeat(36);
    assertEqual(sessions.buildSessionsSource(inputs).rows[0].account, '—');
});
test('sessions: every row passes the protocol reader unchanged', () => {
    const source = sessions.buildSessionsSource(fixtureInputs());
    assertEqual(cockpitProtocol.parseSessionsSource(JSON.parse(JSON.stringify(source))), source);
});
