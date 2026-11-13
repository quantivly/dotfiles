// lib/processTree.js: /proc/<pid>/stat lines read into processes, the herdr clients among them, and the parent chains
// FocusSession names as the windows that may show herdr. The fixtures under fixtures/cockpit/proc-stat/ are one stat
// line per file, named by pid: pid 1, a herdr server with no terminal (2001), and a herdr client (3003) in a shell
// (3002) in a terminal (3001) whose comm holds a space and parentheses.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// The member names are read through the namespace, so a missing export fails its row rather than the whole run.
import * as processTree from '../extensions/resource-pulse@dotfiles/lib/processTree.js';

const PROC_STAT_FIXTURE_DIRECTORY_URI =
    GLib.uri_resolve_relative(import.meta.url, 'fixtures/cockpit/proc-stat/', GLib.UriFlags.NONE);
const [PROC_STAT_FIXTURE_DIRECTORY] = GLib.filename_from_uri(PROC_STAT_FIXTURE_DIRECTORY_URI);
/** The modules' bounds, written out rather than imported, so a changed constant fails here instead of moving with it. */
const ANCESTOR_MAX_DEPTH = 16;
const WINDOW_PID_CANDIDATES_MAX = 64;
/** The fixture processes, by role. */
const INIT_PID = 1;
const HERDR_SERVER_PID = 2001;
const TERMINAL_PID = 3001;
const SHELL_PID = 3002;
const HERDR_CLIENT_PID = 3003;
/** The fixture terminal's controlling tty: /dev/pts/0, major 136. */
const PTS_0_TTY_NR = 34816;
/** A second client, its shell and the terminal's other tab, added to the fixtures by the rows that need two. */
const SECOND_SHELL_PID = 3004;
const SECOND_HERDR_CLIENT_PID = 3005;
/** The first pid of a synthetic chain deeper than the default bound, each process the parent of the one before. */
const DEEP_CHAIN_FIRST_PID = 100;
const DEEP_CHAIN_LENGTH = 20;
/** More herdr clients than the candidates' bound, each with its own terminal and pid 1 as its parent. */
const MANY_CLIENTS_FIRST_PID = 5000;
const MANY_CLIENTS_COUNT = 70;

/**
 * @param {string} fileName - A file under fixtures/cockpit/proc-stat/.
 * @returns {string} Its text.
 */
function readProcStatFixture(fileName) {
    const path = GLib.build_filenamev([PROC_STAT_FIXTURE_DIRECTORY, fileName]);
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

/**
 * Every fixture stat line read by parseProcStat, keyed by the pid it holds, in pid order.
 *
 * @returns {Map<number, object>} The fixture processes.
 * @throws {Error} When a fixture does not parse: every row would compare against a smaller tree.
 */
function fixtureStatByPid() {
    const enumerator = Gio.File.new_for_path(PROC_STAT_FIXTURE_DIRECTORY)
        .enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null);
    const fileNames = [];
    for (let fileInfo = enumerator.next_file(null); fileInfo !== null; fileInfo = enumerator.next_file(null))
        fileNames.push(fileInfo.get_name());
    enumerator.close(null);
    const processStats = fileNames.map(fileName => {
        const processStat = processTree.parseProcStat(readProcStatFixture(fileName));
        if (processStat === null)
            throw new Error(`the fixture proc-stat/${fileName} does not parse`);
        return processStat;
    });
    processStats.sort((left, right) => left.pid - right.pid);
    return new Map(processStats.map(processStat => [processStat.pid, processStat]));
}

/**
 * @param {number} pid - The process.
 * @param {string} comm - Its command name.
 * @param {number} ppid - Its parent.
 * @param {number} ttyNr - Its controlling terminal; 0 for none.
 * @returns {object} The process as parseProcStat gives it.
 */
function processStat(pid, comm, ppid, ttyNr) {
    return {pid, comm, ppid, ttyNr};
}

/**
 * @returns {Map<number, object>} The fixtures plus a second herdr client, in a second shell of the same terminal,
 *     inserted before the first client's entries are looked up, its pid above the first's.
 */
function statByPidWithSecondClient() {
    const statByPid = fixtureStatByPid();
    statByPid.set(SECOND_SHELL_PID, processStat(SECOND_SHELL_PID, 'zsh', TERMINAL_PID, PTS_0_TTY_NR));
    statByPid.set(SECOND_HERDR_CLIENT_PID, processStat(SECOND_HERDR_CLIENT_PID, 'herdr', SECOND_SHELL_PID,
        PTS_0_TTY_NR));
    return statByPid;
}

test('processTree: parseProcStat reads each fixture line\'s pid, comm, parent and tty, a comm with a space and ' +
    'parentheses included', () => {
    const readings = ['1', '2001', '3001', '3002', '3003']
        .map(fileName => processTree.parseProcStat(readProcStatFixture(fileName)));
    assertEqual(readings, [
        processStat(INIT_PID, 'systemd', 0, 0),
        processStat(HERDR_SERVER_PID, 'herdr', INIT_PID, 0),
        processStat(TERMINAL_PID, 'alacritty (1)', INIT_PID, 0),
        processStat(SHELL_PID, 'zsh', TERMINAL_PID, PTS_0_TTY_NR),
        processStat(HERDR_CLIENT_PID, 'herdr', SHELL_PID, PTS_0_TTY_NR),
    ]);
});
test('processTree: parseProcStat reads text that is not a stat line as null', () => {
    // Each differs from a good line in one way: empty; no parenthesis around the comm; no opening one; too few
    // fields after the comm; a parent, a tty or a pid that is not a number; a pid of 0, which no process has; not
    // text at all.
    const notStatLines = [
        '', '3003 herdr S 3002 3003 3002 34816 3003', '3003 herdr) S 3002 3003 3002 34816 3003',
        '3003 (herdr) S 3002 3003 3002', '3003 (herdr) S zsh 3003 3002 34816 3003',
        '3003 (herdr) S 3002 3003 3002 pts0 3003', 'x (herdr) S 3002 3003 3002 34816 3003',
        '0 (herdr) S 3002 3003 3002 34816 3003', null,
    ];
    assertEqual(notStatLines.map(text => processTree.parseProcStat(text)), notStatLines.map(() => null));
});
test('processTree: herdrClientPids names the herdr processes with a terminal, ascending, never the server', () => {
    assertEqual(processTree.herdrClientPids(fixtureStatByPid()), [HERDR_CLIENT_PID]);
    // The second client is entered first, so a list kept in insertion order would come out descending.
    const statByPidSecondFirst = new Map([
        [SECOND_HERDR_CLIENT_PID, processStat(SECOND_HERDR_CLIENT_PID, 'herdr', SECOND_SHELL_PID, PTS_0_TTY_NR)],
        ...fixtureStatByPid(),
    ]);
    assertEqual(processTree.herdrClientPids(statByPidSecondFirst), [HERDR_CLIENT_PID, SECOND_HERDR_CLIENT_PID]);
});
test('processTree: ancestorChain runs from the client through its shell and terminal to pid 1', () => {
    assertEqual(processTree.ancestorChain(HERDR_CLIENT_PID, fixtureStatByPid()),
        [HERDR_CLIENT_PID, SHELL_PID, TERMINAL_PID, INIT_PID]);
});
test('processTree: ancestorChain stops at a parent it has no entry for, and is empty for a pid it has none for', () => {
    const statByPidWithoutShell = fixtureStatByPid();
    statByPidWithoutShell.delete(SHELL_PID);
    assertEqual({
        withoutShell: processTree.ancestorChain(HERDR_CLIENT_PID, statByPidWithoutShell),
        unknownPid: processTree.ancestorChain(SECOND_HERDR_CLIENT_PID, fixtureStatByPid()),
    }, {withoutShell: [HERDR_CLIENT_PID], unknownPid: []});
});
test(`processTree: ancestorChain holds at most maxDepth entries, ${ANCESTOR_MAX_DEPTH} by default`, () => {
    const deepChainPids = Array.from({length: DEEP_CHAIN_LENGTH}, (_unused, index) => DEEP_CHAIN_FIRST_PID + index);
    const deepStatByPid = new Map(deepChainPids.map(pid =>
        [pid, processStat(pid, 'sh', pid === deepChainPids.at(-1) ? INIT_PID : pid + 1, 0)]));
    assertEqual({
        bounded: processTree.ancestorChain(HERDR_CLIENT_PID, fixtureStatByPid(), 2),
        byDefault: processTree.ancestorChain(DEEP_CHAIN_FIRST_PID, deepStatByPid),
    }, {bounded: [HERDR_CLIENT_PID, SHELL_PID], byDefault: deepChainPids.slice(0, ANCESTOR_MAX_DEPTH)});
});
test('processTree: the window candidates are each client\'s chain in turn, without repeats and without pid 1', () => {
    const serverOnly = new Map([...fixtureStatByPid()].filter(([pid]) => pid !== HERDR_CLIENT_PID));
    assertEqual({
        oneClient: processTree.focusWindowPidCandidates(fixtureStatByPid()),
        twoClients: processTree.focusWindowPidCandidates(statByPidWithSecondClient()),
        noClient: processTree.focusWindowPidCandidates(serverOnly),
    }, {
        oneClient: [HERDR_CLIENT_PID, SHELL_PID, TERMINAL_PID],
        twoClients: [HERDR_CLIENT_PID, SHELL_PID, TERMINAL_PID, SECOND_HERDR_CLIENT_PID, SECOND_SHELL_PID],
        noClient: [],
    });
});
test(`processTree: the window candidates stop at maxCount, ${WINDOW_PID_CANDIDATES_MAX} by default`, () => {
    const manyClientPids = Array.from({length: MANY_CLIENTS_COUNT}, (_unused, index) => MANY_CLIENTS_FIRST_PID + index);
    const manyClients = new Map(manyClientPids.map(pid => [pid, processStat(pid, 'herdr', INIT_PID, PTS_0_TTY_NR)]));
    assertEqual({
        bounded: processTree.focusWindowPidCandidates(statByPidWithSecondClient(), 2),
        byDefault: processTree.focusWindowPidCandidates(manyClients),
    }, {
        bounded: [HERDR_CLIENT_PID, SHELL_PID],
        byDefault: manyClientPids.slice(0, WINDOW_PID_CANDIDATES_MAX),
    });
});
