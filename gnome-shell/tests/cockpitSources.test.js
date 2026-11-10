// The cockpit's three sources (service/sources/) and their scheduler (service/cockpitSources.js), with every IO
// faked: hand-driven timeouts and clock, a fake herdr client, fake file readers and listings, a fake NetworkManager
// proxy, a fake mount monitor. A few rows exercise the real IO defaults on a temp dir. Every herdr reply, registry
// entry and /proc text here is synthetic, in the shapes measured on herdr 0.9.1.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// The member names are read through the namespace, so a missing export fails its row rather than the whole run.
import * as cockpitSources from '../extensions/resource-pulse@dotfiles/service/cockpitSources.js';
import * as sessionsSource from '../extensions/resource-pulse@dotfiles/service/sources/sessions.js';
import * as networkSource from '../extensions/resource-pulse@dotfiles/service/sources/network.js';
import * as mountsSource from '../extensions/resource-pulse@dotfiles/service/sources/mounts.js';
import * as sourceIo from '../extensions/resource-pulse@dotfiles/service/sources/sourceIo.js';
import * as constants from '../extensions/resource-pulse@dotfiles/lib/constants.js';
import * as cockpitProtocol from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';

const MICROSECONDS_PER_SECOND = 1e6;
/** The fake wall clock's start: a plausible epoch time, in microseconds. */
const FAKE_START_USEC = 1_800_000_000 * MICROSECONDS_PER_SECOND;
const SOURCE_NAMES = ['sessions', 'network', 'mounts'];
const FAKE_HOME = '/home/tester';
const FAKE_CONFIG_HOME = `${FAKE_HOME}/.config`;
const FAKE_STATE_HOME = `${FAKE_HOME}/.local/state`;
const REGISTRY_DIRECTORY = `${FAKE_STATE_HOME}/hspawn`;
const CLAUDE_PROJECTS_ROOT = `${FAKE_HOME}/.claude/projects`;
const CLAUTH_PROFILES_ROOT = `${FAKE_HOME}/.clauth/profiles`;
const SSH_SOCKETS_DIRECTORY = `${FAKE_HOME}/.ssh/sockets`;
const PROC_NET_ROUTE_PATH = '/proc/net/route';
const PROC_STAT_PATH = '/proc/stat';
/** The boot time /proc/stat's btime line gives in the rows, in seconds since the epoch. */
const FAKE_BOOT_TIME_SECONDS = 1_799_990_000;
/** The clock ticks per second the source assumes for /proc/<pid>/stat's starttime. */
const CLOCK_TICKS_PER_SECOND = 100;
const SNAPSHOT_METHOD = 'session.snapshot';
const PROCESS_INFO_METHOD = 'pane.process_info';
const BYTES_PER_KIB = 1024;
const HERDR_TIMEOUT_MESSAGE = 'herdr: no reply within 2000 ms';
const ROUTE_TABLE_HEADER = 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT';
/** A route table with a default route over a tunnel interface, so the VPN reads as up. */
const TUNNEL_ROUTE_TABLE = [
    ROUTE_TABLE_HEADER,
    'enp0s1\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0',
    'tun0\t00000000\t00000000\t0001\t0\t0\t50\t00000000\t0\t0\t0',
].join('\n');
const NETWORK_MANAGER_OWNER = ':1.7';
/** NMConnectivityState FULL. */
const NM_CONNECTIVITY_FULL = 4;
const WIRED_CONNECTION_TYPE = '802-3-ethernet';
const GIB = 1024 ** 3;
const TEMP_DIRECTORY_TEMPLATE = 'cockpit-sources-test-XXXXXX';
/** What the secret files the refusal row plants hold: a row fails if it ever reads back. */
const PLANTED_SECRET_TEXT = 'planted-secret-text';
// The stat-only files the refusal row plants under a fake home, built from parts so no guarded path is written whole
// in this file: a file in each stat-only directory, a Claude credential, and the three machine-local files.
const SECRET_DIRECTORY_FILES = [['.aws', 'credentials'], ['.ssh', 'id_ed25519'], ['.claude', '.credentials.json']];
const LOCAL_FILE_STEMS = ['.zshrc', '.gitconfig', '.backup'];
const LOCAL_FILE_SUFFIX = '.local';

/**
 * Resolves after the main loop has run every pending microtask and one idle pass, so the promises a fired timeout
 * started have settled.
 *
 * @returns {Promise<void>} Settles on the next low-priority idle.
 */
function settle() {
    return new Promise(resolve => GLib.idle_add(GLib.PRIORITY_LOW, () => {
        resolve();
        return GLib.SOURCE_REMOVE;
    }));
}

/** A hand-driven wall clock and the timeouts on it: advanceSeconds fires each due timeout in time order. */
class FakeClock {
    constructor() {
        this.nowUsec = FAKE_START_USEC;
        this._timersById = new Map();
        this._nextTimerId = 1;
        this.timeouts = {
            addSeconds: (intervalSeconds, callback) => this._addSeconds(intervalSeconds, callback),
            remove: timerId => this._remove(timerId),
        };
    }

    /**
     * @param {number} intervalSeconds - Seconds until the callback, and between calls while it continues.
     * @param {() => boolean} callback - Returns GLib.SOURCE_CONTINUE or GLib.SOURCE_REMOVE.
     * @returns {number} The timer id.
     */
    _addSeconds(intervalSeconds, callback) {
        const timerId = this._nextTimerId++;
        this._timersById.set(timerId,
            {intervalSeconds, callback, dueUsec: this.nowUsec + intervalSeconds * MICROSECONDS_PER_SECOND});
        return timerId;
    }

    /**
     * @param {number} timerId - An id _addSeconds returned.
     * @returns {void}
     * @throws {Error} For an id that is not pending, as GLib.source_remove warns of one.
     */
    _remove(timerId) {
        if (!this._timersById.delete(timerId))
            throw new Error(`removed timer ${timerId}, which is not pending`);
    }

    /** @returns {number[]} The intervals of the pending timers, smallest first. */
    pendingIntervalsSeconds() {
        return [...this._timersById.values()].map(timer => timer.intervalSeconds).sort((a, b) => a - b);
    }

    /**
     * Moves the clock forward, firing every timer that falls due on the way, earliest first (ties by id), and
     * settling after each.
     *
     * @param {number} seconds - How far to move; may be fractional.
     * @returns {Promise<void>} Settles once the clock reached the end and everything fired has settled.
     */
    async advanceSeconds(seconds) {
        const endUsec = this.nowUsec + seconds * MICROSECONDS_PER_SECOND;
        // GLib runs pending promise jobs before any timeout fires: so does the fake.
        await settle();
        for (;;) {
            const dueTimers = [...this._timersById].filter(([, timer]) => timer.dueUsec <= endUsec);
            if (dueTimers.length === 0)
                break;
            dueTimers.sort(([firstId, first], [secondId, second]) =>
                first.dueUsec - second.dueUsec || firstId - secondId);
            const [[timerId, timer]] = dueTimers;
            this.nowUsec = timer.dueUsec;
            const shouldContinue = timer.callback();
            if (shouldContinue === GLib.SOURCE_CONTINUE && this._timersById.has(timerId))
                timer.dueUsec += timer.intervalSeconds * MICROSECONDS_PER_SECOND;
            else
                this._timersById.delete(timerId);
            // Settling twice lets a sample's promise chain (sample, stamp, listeners) run out between two firings.
            await settle();
            await settle();
        }
        this.nowUsec = endUsec;
        await settle();
    }
}

/** The timing a real source writes before the scheduler stamps over it (ruling R2). */
const PLACEHOLDER_TIMING = {sampledAtUsec: 0, intervalSeconds: 0};

/**
 * @param {string} name - One of SOURCE_NAMES.
 * @param {number} sampleNumber - Which sample of the source this is, from 1.
 * @returns {object} A reader-valid source object of that name, with the placeholder timing a real source writes.
 */
function sourceObjectFor(name, sampleNumber) {
    if (name === 'sessions') {
        const counts = Object.fromEntries(cockpitProtocol.SESSION_STATES.map(state => [state, 0]));
        return {...PLACEHOLDER_TIMING, herdrRunning: true, totalMemoryBytes: sampleNumber, counts, rows: []};
    }
    if (name === 'network') {
        return {
            ...PLACEHOLDER_TIMING,
            uplink: {kind: 'wired', connectivity: 'full', wifiEnabled: false},
            vpn: {isUp: false, interfaceName: null},
            sshMasterCount: sampleNumber,
        };
    }
    return {...PLACEHOLDER_TIMING, rows: [{mountPoint: `/media/disk${sampleNumber}`, label: 'disk', kind: 'removable',
        filesystemType: 'vfat', freeBytes: null, totalBytes: null}]};
}

/**
 * A fake source: counts its sample() calls in `calls[name]`, resolves a fresh object each time (unless the row
 * swaps sample), records its watchChanges callback and its destroy calls.
 *
 * @param {string} name - Its name.
 * @param {Object<string, number>} calls - Sample counts by source name.
 * @returns {object} The fake.
 */
function countingSource(name, calls) {
    return {
        name,
        destroyCount: 0,
        onChange: null,
        sample: async () => {
            calls[name]++;
            return sourceObjectFor(name, calls[name]);
        },
        watchChanges(onChange) {
            this.onChange = onChange;
        },
        destroy() {
            this.destroyCount++;
        },
    };
}

/**
 * The scheduler over three counting sources on a fake clock.
 *
 * @param {object} [options] - The setup.
 * @param {boolean} [options.watched] - Whether a client watches the cockpit (set before start).
 * @param {boolean} [options.onBattery] - What isOnBattery answers (a row may change `power.onBattery` later).
 * @returns {object} `{sources, clock, calls, fakeSources, loggedLines, power}`.
 */
function fakeSetup({watched = false, onBattery = false} = {}) {
    const clock = new FakeClock();
    const calls = Object.fromEntries(SOURCE_NAMES.map(name => [name, 0]));
    const fakeSources = SOURCE_NAMES.map(name => countingSource(name, calls));
    const loggedLines = [];
    const power = {onBattery};
    const sources = new cockpitSources.CockpitSources({
        sources: fakeSources,
        timeouts: clock.timeouts,
        nowUsec: () => clock.nowUsec,
        isOnBattery: () => power.onBattery,
        logWriter: line => loggedLines.push(line),
    });
    sources.setWatched(watched);
    return {sources, clock, calls, fakeSources, loggedLines, power};
}

/**
 * @param {string} code - One of HERDR_ERROR_CODES.
 * @param {string} message - The message, starting 'herdr: '.
 * @returns {Error} A rejection as service/herdrSocket.js gives one.
 */
function herdrError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
}

/**
 * @param {string} path - A path.
 * @returns {GLib.Error} What Gio throws for a path that does not exist.
 */
function notFoundError(path) {
    return new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.NOT_FOUND, `${path}: No such file or directory`);
}

test('cockpitSources: each source samples at its own interval, and watched sessions sample at 10 s', async () => {
    const {sources, clock, calls} = fakeSetup({watched: true});
    sources.start();
    await clock.advanceSeconds(60);
    assertEqual(calls, {sessions: 7, network: 7, mounts: 3});
    sources.destroy();
});

test('cockpitSources: unwatched sessions sample at 60 s', async () => {
    const {sources, clock, calls} = fakeSetup({watched: false});
    sources.start();
    await clock.advanceSeconds(120);
    assertEqual(calls.sessions, 3);
    sources.destroy();
});

test('cockpitSources: on battery every interval triples, and the objects carry the tripled interval', async () => {
    const {sources, clock, calls} = fakeSetup({watched: true, onBattery: true});
    sources.start();
    await clock.advanceSeconds(90);
    assertEqual(calls, {sessions: 4, network: 4, mounts: 2});
    assertEqual(sources.sourcesByName.sessions.intervalSeconds, 30);
    assertEqual(sources.sourcesByName.mounts.intervalSeconds, 90);
    sources.destroy();
});

test('cockpitSources: going on battery takes effect at the next firing, which samples at the new interval',
    async () => {
    const {sources, clock, calls, power} = fakeSetup({watched: true});
    sources.start();
    await clock.advanceSeconds(5);
    power.onBattery = true;
    await clock.advanceSeconds(5);
    assertEqual(sources.sourcesByName.network.intervalSeconds, 30, 'the sample at 10 s carries the next wait');
    await clock.advanceSeconds(29);
    assertEqual(calls.network, 2, 'nothing between 10 s and 40 s');
    await clock.advanceSeconds(1);
    assertEqual(calls.network, 3);
    assertEqual(clock.pendingIntervalsSeconds(), [30, 30, 90]);
    sources.destroy();
});

test('cockpitSources: a source that rejects keeps its last object and does not stop the others', async () => {
    const clock = new FakeClock();
    const loggedLines = [];
    const failingSessions = {
        name: 'sessions',
        sample: () => Promise.reject(herdrError('timeout', HERDR_TIMEOUT_MESSAGE)),
        watchChanges() {},
        destroy() {},
    };
    const okNetwork = countingSource('network', {network: 0});
    const sources = new cockpitSources.CockpitSources({
        sources: [failingSessions, okNetwork], timeouts: clock.timeouts, nowUsec: () => clock.nowUsec,
        isOnBattery: () => false, logWriter: line => loggedLines.push(line),
    });
    sources.start();
    await settle();
    await settle();
    assertEqual(sources.sourcesByName.network.uplink.kind, 'wired');
    assertEqual(sources.sourcesByName.sessions, null);
    assertEqual(loggedLines, [`cockpit: sessions: ${HERDR_TIMEOUT_MESSAGE}`]);
    await clock.advanceSeconds(60);
    assertEqual(loggedLines.length, 1, 'the same failure is rate-limited per source');
    sources.destroy();
});

test('cockpitSources: a rejection after a success keeps the earlier object, its stamp included', async () => {
    const {sources, clock, fakeSources} = fakeSetup({watched: true});
    sources.start();
    await settle();
    await settle();
    const firstSessions = sources.sourcesByName.sessions;
    fakeSources[0].sample = () => Promise.reject(herdrError('timeout', HERDR_TIMEOUT_MESSAGE));
    await clock.advanceSeconds(10);
    assertEqual(sources.sourcesByName.sessions, firstSessions);
    assertEqual(sources.sourcesByName.sessions.sampledAtUsec, FAKE_START_USEC);
    sources.destroy();
});

test('cockpitSources: a pending sample is skipped when its interval comes again, never queued', async () => {
    const {sources, clock, calls, fakeSources} = fakeSetup({watched: true});
    let resolveSample = null;
    fakeSources[0].sample = () => {
        calls.sessions++;
        return new Promise(resolve => {
            resolveSample = resolve;
        });
    };
    sources.start();
    await clock.advanceSeconds(25);
    assertEqual(calls.sessions, 1, 'the 10 s and 20 s firings found the first sample pending');
    resolveSample(sourceObjectFor('sessions', 1));
    await settle();
    await settle();
    assertEqual(calls.sessions, 1, 'nothing ran when it settled');
    assertEqual(sources.sourcesByName.sessions.totalMemoryBytes, 1);
    const pendingAgain = sources.sampleNow('sessions');
    assertEqual(calls.sessions, 2, 'sampleNow starts one when none is pending');
    assertEqual(sources.sampleNow('sessions') === pendingAgain, true, 'and hands back the pending one when one is');
    assertEqual(calls.sessions, 2);
    resolveSample(sourceObjectFor('sessions', 2));
    const sampledObject = await pendingAgain;
    assertEqual(sampledObject.totalMemoryBytes, 2);
    sources.destroy();
});

test('cockpitSources: a signal samples its source at once, once per cooldown, with one sample at its end', async () => {
    const {sources, clock, calls, fakeSources} = fakeSetup({watched: true});
    sources.start();
    await settle();
    assertEqual(calls.network, 1);
    const networkFake = fakeSources[1];
    networkFake.onChange();
    await settle();
    assertEqual(calls.network, 2, 'the first signal samples at once');
    await clock.advanceSeconds(0.5);
    networkFake.onChange();
    networkFake.onChange();
    await settle();
    assertEqual(calls.network, 2, 'signals inside the cooldown do not sample at once');
    // GLib's timeouts are whole seconds, so the 1.5 s left of the cooldown rounds up to 2: the sample comes at 2.5 s.
    await clock.advanceSeconds(1.9);
    assertEqual(calls.network, 2, 'not before the cooldown ends');
    await clock.advanceSeconds(0.1);
    assertEqual(calls.network, 3, 'they give one sample when the cooldown ends');
    networkFake.onChange();
    await settle();
    assertEqual(calls.network, 3, 'that sample starts a cooldown of its own');
    await clock.advanceSeconds(2);
    assertEqual(calls.network, 4);
    await clock.advanceSeconds(5);
    assertEqual(calls.network, 4, 'and nothing more before the interval');
    assertEqual(calls.sessions, 1, 'another source is not sampled by the signal');
    sources.destroy();
});

test('cockpitSources: the listener fires only for a changed source, with its name and the latest objects', async () => {
    const {sources, clock, fakeSources} = fakeSetup({watched: true});
    const sameNetworkObject = sourceObjectFor('network', 1);
    fakeSources[1].sample = async () => JSON.parse(JSON.stringify(sameNetworkObject));
    const listenerCalls = [];
    sources.addListener((changedSourceNames, sourcesByName) =>
        listenerCalls.push({changedSourceNames, networkCount: sourcesByName.network?.sshMasterCount ?? null}));
    sources.start();
    await settle();
    await settle();
    const networkCalls = () => listenerCalls.filter(call => call.changedSourceNames.includes('network'));
    assertEqual(networkCalls(), [{changedSourceNames: ['network'], networkCount: 1}]);
    await clock.advanceSeconds(10);
    assertEqual(networkCalls().length, 1, 'the same object under a new sampledAtUsec is no change');
    sameNetworkObject.sshMasterCount = 4;
    await clock.advanceSeconds(10);
    assertEqual(networkCalls().length, 2);
    assertEqual(networkCalls()[1].networkCount, 4);
    sources.destroy();
});

test('cockpitSources: a removed listener is not called; one that throws is logged and the next still runs',
    async () => {
    const {sources, clock, loggedLines} = fakeSetup({watched: true});
    const removedCalls = [];
    const keptCalls = [];
    const removedId = sources.addListener(names => removedCalls.push(names));
    sources.addListener(() => {
        throw new Error('listener bug');
    });
    sources.addListener(names => keptCalls.push(names));
    sources.removeListener(removedId);
    sources.start();
    await clock.advanceSeconds(1);
    assertEqual(removedCalls, []);
    assertEqual(keptCalls.flat().sort(), [...SOURCE_NAMES].sort());
    assertEqual(loggedLines.some(line => line.startsWith('cockpit: listener failed: listener bug')), true);
    sources.destroy();
});

test('cockpitSources: setWatched reschedules sessions at once with the new interval, without an extra sample',
    async () => {
    const {sources, clock, calls} = fakeSetup({watched: false});
    sources.start();
    await clock.advanceSeconds(30);
    assertEqual(calls.sessions, 1);
    sources.setWatched(true);
    await settle();
    assertEqual(calls.sessions, 1, 'watching does not sample');
    await clock.advanceSeconds(10);
    assertEqual(calls.sessions, 2, 'the next sample is 10 s after the watch, not 60 s after start');
    sources.setWatched(false);
    await clock.advanceSeconds(59);
    assertEqual(calls.sessions, 2);
    await clock.advanceSeconds(1);
    assertEqual(calls.sessions, 3);
    sources.destroy();
});

test('cockpitSources: destroy removes every timer, destroys every source once, and silences a pending sample',
    async () => {
    const {sources, clock, calls, fakeSources} = fakeSetup({watched: true});
    let resolveSample = null;
    fakeSources[2].sample = () => {
        calls.mounts++;
        return new Promise(resolve => {
            resolveSample = resolve;
        });
    };
    const listenerCalls = [];
    sources.addListener(names => listenerCalls.push(...names));
    sources.start();
    await settle();
    fakeSources[1].onChange();
    await clock.advanceSeconds(0.5);
    fakeSources[1].onChange();
    sources.destroy();
    assertEqual(clock.pendingIntervalsSeconds(), [], 'the interval timers and the cooldown timer are gone');
    assertEqual(fakeSources.map(fake => fake.destroyCount), [1, 1, 1]);
    resolveSample(sourceObjectFor('mounts', 1));
    await settle();
    assertEqual(listenerCalls.includes('mounts'), false, 'a sample settling after destroy reaches no listener');
    assertEqual(sources.sourcesByName.mounts, null, 'and is not kept');
    sources.destroy();
    assertEqual(fakeSources.map(fake => fake.destroyCount), [1, 1, 1], 'destroy twice is safe');
});

test('cockpitSources: a source with no cadence, or a name given twice, is refused at construction', () => {
    const constructionError = sourceNames => {
        const calls = Object.fromEntries(sourceNames.map(name => [name, 0]));
        try {
            new cockpitSources.CockpitSources({sources: sourceNames.map(name => countingSource(name, calls)),
                timeouts: new FakeClock().timeouts, nowUsec: () => FAKE_START_USEC, isOnBattery: () => false,
                logWriter: () => {}});
        } catch (error) {
            return error.message;
        }
        return null;
    };
    assertEqual([constructionError(['weather']), constructionError(['network', 'network']), constructionError([])], [
        'cockpit: the source named weather has no cadence', 'cockpit: the source named network is given twice', null,
    ]);
});

test('cockpitSources: the cadence constants and the stat-only fragments hold the design values', () => {
    assertEqual([
        constants.SESSIONS_WATCHED_INTERVAL_SECONDS, constants.SESSIONS_UNWATCHED_INTERVAL_SECONDS,
        constants.NETWORK_INTERVAL_SECONDS, constants.MOUNTS_INTERVAL_SECONDS, constants.BATTERY_CADENCE_MULTIPLIER,
        constants.SOURCE_SIGNAL_COOLDOWN_SECONDS,
    ], [10, 60, 10, 30, 3, 2]);
    assertEqual(constants.STAT_ONLY_PATH_FRAGMENTS,
        ['/.aws/', '/.ssh/', '/.credentials', '/.zshrc.local', '/.gitconfig.local', '/.backup.local']);
});

/**
 * A fake herdr client answering session.snapshot and pane.process_info from tables, recording each request.
 *
 * @param {object} replies - What it answers.
 * @param {object} [replies.snapshot] - The `snapshot` of session.snapshot's result.
 * @param {Error} [replies.snapshotError] - Rejects session.snapshot with this instead.
 * @param {Object<string, object>} [replies.processInfoByPaneId] - The `process_info` of each pane; a pane missing
 *     here is a `pane_not_found` remote error.
 * @returns {{request: Function, requests: Array<{method: string, params: object}>}} The fake.
 */
function fakeHerdrClient({snapshot, snapshotError = null, processInfoByPaneId = {}}) {
    const requests = [];
    return {
        requests,
        request(method, params = {}) {
            requests.push({method, params});
            if (method === SNAPSHOT_METHOD)
                return snapshotError
                    ? Promise.reject(snapshotError) : Promise.resolve({type: 'session_snapshot', snapshot});
            if (method === PROCESS_INFO_METHOD && Object.hasOwn(processInfoByPaneId, params.pane_id))
                return Promise.resolve({type: 'pane_process_info', process_info: processInfoByPaneId[params.pane_id]});
            return Promise.reject(herdrError('remote-error', 'herdr: pane_not_found: pane not found'));
        },
        close() {},
    };
}

/**
 * @param {object} fields - The agent's own fields.
 * @returns {object} A claude agent of herdr's snapshot, in the live shape.
 */
function claudeAgent({paneId, workspaceId, sessionId, status, cwd, tokens = {}}) {
    return {
        agent: 'claude', agent_session: {agent: 'claude', kind: 'session', source: 'hook', value: sessionId},
        agent_status: status, cwd, focused: false, foreground_cwd: cwd, pane_id: paneId, revision: 1,
        state_change_seq: 1, tab_id: `${workspaceId}:t1`, terminal_id: `term-${paneId}`, terminal_title: 'claude',
        terminal_title_stripped: 'claude', tokens, workspace_id: workspaceId,
    };
}

/**
 * @param {number} pid - The claude process's pid.
 * @param {object} identity - How herdr reports the process.
 * @param {string[]} identity.argv - Its argv.
 * @param {string} identity.name - Its name (the kernel's comm).
 * @param {string} cwd - Its cwd.
 * @returns {object} A pane's process_info with an MCP server and the claude process in the foreground, in the live
 *     shape.
 */
function processInfoWithClaude(pid, {argv, name}, cwd) {
    return {
        pane_id: 'unused', shell_pid: pid - 1, foreground_process_group_id: pid,
        foreground_processes: [
            {pid: pid + 1, name: 'node', argv: ['node', 'mcp-server.js'], cmdline: 'node mcp-server.js', cwd},
            {pid, name, argv, cmdline: argv.join(' '), cwd},
        ],
    };
}

/**
 * @param {number} pid - A pid.
 * @param {number} startTicks - Its start time, in clock ticks after boot.
 * @returns {string} A /proc/<pid>/stat line whose command holds spaces and a parenthesis, as a renamed process can.
 */
function procPidStatText(pid, startTicks) {
    // Fields 3 to 21, then starttime (field 22), then the rest.
    const fieldsBeforeStartTime = ['S', '1', String(pid), String(pid), '0', '-1', '4194560', '100', '0', '0', '0',
        '50', '10', '0', '0', '20', '0', '12', '0'];
    return `${pid} (claude (x) y) ${fieldsBeforeStartTime.join(' ')} ${startTicks} 1000000 2000 18446744073709551615\n`;
}

/**
 * @param {number} residentKib - VmRSS.
 * @param {number} swapKib - VmSwap.
 * @returns {string} A /proc/<pid>/status text.
 */
function procPidStatusText(residentKib, swapKib) {
    return `Name:\tclaude\nVmRSS:\t ${residentKib} kB\nVmSwap:\t ${swapKib} kB\nThreads:\t12\n`;
}

/**
 * A fake file system for the sessions source: file texts and mtimes by path, directory listings by path, each read,
 * stat and listing recorded.
 *
 * @param {object} tables - What exists.
 * @param {Object<string, string>} [tables.files] - File texts by path.
 * @param {Object<string, number>} [tables.mtimesUsec] - Modification times by path.
 * @param {Object<string, string[]>} [tables.directories] - Entry names by directory path.
 * @returns {object} `{readFile, statFile, listDirectory, readPaths, statPaths, listedPaths}`.
 */
function fakeFileSystem({files = {}, mtimesUsec = {}, directories = {}}) {
    const readPaths = [];
    const statPaths = [];
    const listedPaths = [];
    return {
        readPaths, statPaths, listedPaths,
        readFile(path) {
            readPaths.push(path);
            if (!Object.hasOwn(files, path))
                throw notFoundError(path);
            return files[path];
        },
        statFile(path) {
            statPaths.push(path);
            return Object.hasOwn(mtimesUsec, path) ? mtimesUsec[path] : null;
        },
        listDirectory(path) {
            listedPaths.push(path);
            if (!Object.hasOwn(directories, path))
                throw notFoundError(path);
            return directories[path];
        },
    };
}

/**
 * The sessions fixture: three claude agents and one codex agent. p1 is in the hspawn registry and its transcript
 * sits at the exact path; p2's transcript is found only under a clauth profile's runtime projects; p3 has no
 * transcript, so its idle age comes from its process start time; its process is a versioned binary.
 *
 * @returns {object} `{herdrClient, fileSystem, nowUsec}`.
 */
function sessionsFixture() {
    const nowUsec = FAKE_START_USEC;
    const snapshot = {
        version: '0.9.1', protocol: 22, agents: [
            claudeAgent({paneId: 'p1', workspaceId: 'w1', sessionId: 'sess-one', status: 'working',
                cwd: '/home/tester/dev/host-sync', tokens: {acct: 'quantivly-1', ctx_ok: '▅ 62%'}}),
            claudeAgent({paneId: 'p2', workspaceId: 'w2', sessionId: 'sess-two', status: 'idle',
                cwd: '/home/tester/dev/reports'}),
            claudeAgent({paneId: 'p3', workspaceId: 'w2', sessionId: 'sess-three', status: 'blocked',
                cwd: '/home/tester/dev/teammate'}),
            {...claudeAgent({paneId: 'p4', workspaceId: 'w1', sessionId: 'sess-codex', status: 'working', cwd: '/'}),
                agent: 'codex'},
        ],
        workspaces: [
            {workspace_id: 'w1', label: 'Host sync', number: 1, active_tab_id: 'w1:t1'},
            {workspace_id: 'w2', label: 'Reports', number: 2, active_tab_id: 'w2:t1'},
        ],
    };
    const herdrClient = fakeHerdrClient({
        snapshot,
        // Each pane's process is Claude by one of hreap's rules only: its name, its argv[0]'s basename, its
        // versioned binary's path.
        processInfoByPaneId: {
            p1: processInfoWithClaude(1001, {argv: ['node', '/opt/claude-code/cli.js'], name: 'claude'},
                '/home/tester/dev/host-sync'),
            p2: processInfoWithClaude(1002, {argv: ['/usr/local/bin/claude'], name: 'node'},
                '/home/tester/dev/reports'),
            p3: processInfoWithClaude(1003, {argv: ['/home/tester/.local/share/claude/versions/2.1.251'],
                name: '2.1.251'}, '/home/tester/dev/teammate'),
        },
    });
    const p3StartTicks = 500 * CLOCK_TICKS_PER_SECOND;
    const fileSystem = fakeFileSystem({
        files: {
            [`${REGISTRY_DIRECTORY}/wL_p1.json`]: JSON.stringify({pane_id: 'p1', slug: 'host-sync', branch: 'zvi/hs'}),
            [`${REGISTRY_DIRECTORY}/notes.txt`]: 'not a registry entry',
            '/proc/1001/status': procPidStatusText(3 * GIB / BYTES_PER_KIB, 0),
            '/proc/1002/status': procPidStatusText(GIB / BYTES_PER_KIB, GIB / BYTES_PER_KIB),
            '/proc/1003/status': procPidStatusText(GIB / 2 / BYTES_PER_KIB, 0),
            '/proc/1003/stat': procPidStatText(1003, p3StartTicks),
            [PROC_STAT_PATH]: `cpu  1 2 3 4\nintr 1\nbtime ${FAKE_BOOT_TIME_SECONDS}\nprocesses 5\n`,
        },
        mtimesUsec: {
            [`${CLAUDE_PROJECTS_ROOT}/-home-tester-dev-host-sync/sess-one.jsonl`]:
                nowUsec - 30 * MICROSECONDS_PER_SECOND,
            [`${CLAUTH_PROFILES_ROOT}/quantivly-2/runtime-ab12/projects/-elsewhere/sess-two.jsonl`]:
                nowUsec - 600 * MICROSECONDS_PER_SECOND,
        },
        directories: {
            [REGISTRY_DIRECTORY]: ['wL_p1.json', 'notes.txt'],
            [CLAUDE_PROJECTS_ROOT]: ['-home-tester-dev-host-sync', '-other'],
            [CLAUTH_PROFILES_ROOT]: ['quantivly-1', 'quantivly-2'],
            [`${CLAUTH_PROFILES_ROOT}/quantivly-1`]: ['settings.json'],
            [`${CLAUTH_PROFILES_ROOT}/quantivly-2`]: ['runtime-ab12', 'settings.json'],
            [`${CLAUTH_PROFILES_ROOT}/quantivly-2/runtime-ab12/projects`]: ['-elsewhere'],
        },
    });
    return {herdrClient, fileSystem, nowUsec, p3StartedAtUsec:
        (FAKE_BOOT_TIME_SECONDS + p3StartTicks / CLOCK_TICKS_PER_SECOND) * MICROSECONDS_PER_SECOND};
}

/**
 * @param {object} fixture - sessionsFixture's result, or the same shape.
 * @param {object} [extra] - More dependencies (a logWriter).
 * @returns {object} A SessionsSource over the fixture's fakes.
 */
function sessionsSourceOver({herdrClient, fileSystem, nowUsec}, extra = {}) {
    return new sessionsSource.SessionsSource({
        herdrClient, configHome: FAKE_CONFIG_HOME, stateHome: FAKE_STATE_HOME, homeDirectory: FAKE_HOME,
        readFile: path => fileSystem.readFile(path), statFile: path => fileSystem.statFile(path),
        listDirectory: path => fileSystem.listDirectory(path), nowUsec: () => nowUsec, ...extra,
    });
}

test('SessionsSource: a sample builds the rows from the snapshot, registry, transcripts and /proc, reader-valid',
    async () => {
    const fixture = sessionsFixture();
    const source = sessionsSourceOver(fixture);
    assertEqual(source.name, 'sessions');
    const sessions = await source.sample();
    assertEqual(cockpitProtocol.parseSessionsSource(sessions), sessions, 'the reader keeps every field');
    assertEqual(sessions.herdrRunning, true);
    assertEqual(sessions.rows.map(row => [row.id, row.name, row.state, row.memoryBytes, row.idleSeconds,
        row.idleFromProcessAge]), [
        ['w1:p1', 'host-sync', 'working', 3 * GIB, 30, false],
        ['w2:p2', 'Reports', 'idle', 2 * GIB, 600, false],
        ['w2:p3', 'Reports', 'blocked', GIB / 2, Math.floor((fixture.nowUsec - fixture.p3StartedAtUsec) / 1e6), true],
    ]);
    assertEqual(sessions.rows[0].account, 'quantivly-1');
    assertEqual(sessions.totalMemoryBytes, 5.5 * GIB);
    assertEqual(sessions.counts, {working: 1, blocked: 1, idle: 1, done: 0, unknown: 0});
    assertEqual(fixture.herdrClient.requests.map(request => [request.method, request.params.pane_id ?? null]), [
        [SNAPSHOT_METHOD, null], [PROCESS_INFO_METHOD, 'p1'], [PROCESS_INFO_METHOD, 'p2'], [PROCESS_INFO_METHOD, 'p3'],
    ], 'one snapshot, then one process_info per claude agent, in order');
});

test('SessionsSource: each directory is listed at most once per sample, and the registry only once', async () => {
    const fixture = sessionsFixture();
    const source = sessionsSourceOver(fixture);
    await source.sample();
    const listedOnce = new Set(fixture.fileSystem.listedPaths);
    assertEqual(fixture.fileSystem.listedPaths.length, listedOnce.size, fixture.fileSystem.listedPaths.join(' '));
    assertEqual(listedOnce.has(REGISTRY_DIRECTORY), true);
    assertEqual(fixture.fileSystem.listedPaths.includes(CLAUDE_PROJECTS_ROOT), true);
    await source.sample();
    assertEqual(fixture.fileSystem.listedPaths.filter(path => path === REGISTRY_DIRECTORY).length, 2,
        'a second sample lists again: nothing is cached across samples');
});

test('SessionsSource: a transcript at the exact path, named by the claude process\'s cwd, needs no listing',
    async () => {
        const snapshot = {
            agents: [claudeAgent({paneId: 'p1', workspaceId: 'w1', sessionId: 'sess-one', status: 'working',
                cwd: '/home/tester/dev/host-sync/subdirectory'})],
            workspaces: [],
        };
        const herdrClient = fakeHerdrClient({snapshot, processInfoByPaneId: {
            p1: processInfoWithClaude(1001, {argv: ['claude'], name: 'claude'}, '/home/tester/dev/host-sync'),
        }});
        const fileSystem = fakeFileSystem({
            files: {'/proc/1001/status': procPidStatusText(1024, 0)},
            mtimesUsec: {[`${CLAUDE_PROJECTS_ROOT}/-home-tester-dev-host-sync/sess-one.jsonl`]:
                FAKE_START_USEC - 30 * MICROSECONDS_PER_SECOND},
            directories: {[CLAUDE_PROJECTS_ROOT]: ['-home-tester-dev-host-sync']},
        });
        const sessions = await sessionsSourceOver({herdrClient, fileSystem, nowUsec: FAKE_START_USEC}).sample();
        assertEqual(sessions.rows[0].idleSeconds, 30);
        assertEqual(fileSystem.listedPaths, [REGISTRY_DIRECTORY], 'only the registry is listed');
    });

test('SessionsSource: the socket absent is herdrRunning false with no rows and no error', async () => {
    const fileSystem = fakeFileSystem({});
    const herdrClient = fakeHerdrClient({snapshotError: herdrError('no-socket', 'herdr: no socket at /x/herdr.sock')});
    const loggedLines = [];
    const source = sessionsSourceOver({herdrClient, fileSystem, nowUsec: FAKE_START_USEC},
        {logWriter: line => loggedLines.push(line)});
    const sessions = await source.sample();
    assertEqual(sessions.herdrRunning, false);
    assertEqual(sessions.rows, []);
    assertEqual(sessions.totalMemoryBytes, null);
    assertEqual(sessions.counts, {working: 0, blocked: 0, idle: 0, done: 0, unknown: 0});
    assertEqual(cockpitProtocol.parseSessionsSource(sessions), sessions);
    assertEqual([fileSystem.readPaths, fileSystem.listedPaths, fileSystem.statPaths], [[], [], []]);
    assertEqual(loggedLines, [], 'herdr not running is not an error');
});

test('SessionsSource: a refused connection is herdr not running, logged once per interval', async () => {
    const fileSystem = fakeFileSystem({});
    const refusedError = herdrError('connect-refused', 'herdr: cannot connect to /x/herdr.sock: Connection refused');
    const herdrClient = fakeHerdrClient({snapshotError: refusedError});
    const loggedLines = [];
    const source = sessionsSourceOver({herdrClient, fileSystem, nowUsec: FAKE_START_USEC},
        {logWriter: line => loggedLines.push(line)});
    const sessions = await source.sample();
    await source.sample();
    assertEqual([sessions.herdrRunning, sessions.rows.length], [false, 0]);
    assertEqual(loggedLines.length, 1);
    assertEqual(loggedLines[0].startsWith('cockpit: sessions: herdr: connect-refused'), true, loggedLines[0]);
});

test('SessionsSource: any other herdr failure rejects the sample, for the scheduler to log', async () => {
    const herdrClient = fakeHerdrClient({snapshotError: herdrError('timeout', HERDR_TIMEOUT_MESSAGE)});
    const source = sessionsSourceOver({herdrClient, fileSystem: fakeFileSystem({}), nowUsec: FAKE_START_USEC});
    let rejection = null;
    await source.sample().catch(error => {
        rejection = error;
    });
    assertEqual(rejection?.code, 'timeout');
});

test('SessionsSource: a pid with no claude process gives memoryBytes null and keeps the row', async () => {
    const snapshot = {
        agents: [
            claudeAgent({paneId: 'p1', workspaceId: 'w1', sessionId: 's1', status: 'idle', cwd: '/srv/a'}),
            claudeAgent({paneId: 'p2', workspaceId: 'w1', sessionId: 's2', status: 'idle', cwd: '/srv/b'}),
            claudeAgent({paneId: 'p3', workspaceId: 'w1', sessionId: 's3', status: 'done', cwd: '/srv/c'}),
        ],
        workspaces: [],
    };
    const herdrClient = fakeHerdrClient({
        snapshot,
        processInfoByPaneId: {
            // p1: only a shell in the foreground; p2: a claude pid whose /proc entry is gone; p3: no reply (closed).
            p1: {pane_id: 'p1', shell_pid: 10, foreground_process_group_id: 10,
                foreground_processes: [{pid: 10, name: 'zsh', argv: ['-zsh'], cmdline: '-zsh', cwd: '/srv/a'}]},
            p2: processInfoWithClaude(2002, {argv: ['claude'], name: 'claude'}, '/srv/b'),
        },
    });
    const fileSystem = fakeFileSystem({files: {[PROC_STAT_PATH]: `btime ${FAKE_BOOT_TIME_SECONDS}\n`}});
    const sessions = await sessionsSourceOver({herdrClient, fileSystem, nowUsec: FAKE_START_USEC}).sample();
    assertEqual(sessions.rows.map(row => [row.paneId, row.memoryBytes, row.idleSeconds]),
        [['p1', null, null], ['p2', null, null], ['p3', null, null]]);
    assertEqual(fileSystem.readPaths.filter(path => path.startsWith('/proc/10/')), [],
        'a shell is never read as the session');
    assertEqual(cockpitProtocol.parseSessionsSource(sessions), sessions);
});

test('SessionsSource: nothing under ~/.ssh or ~/.aws is ever opened; reads are /proc and the registry only',
    async () => {
    const fixture = sessionsFixture();
    await sessionsSourceOver(fixture).sample();
    const unexpectedReads = fixture.fileSystem.readPaths.filter(path =>
        !path.startsWith('/proc/') && !path.startsWith(`${REGISTRY_DIRECTORY}/`));
    assertEqual(unexpectedReads, []);
    assertEqual(fixture.fileSystem.readPaths.some(path => path.endsWith('.jsonl')), false, 'transcripts are stat only');
    assertEqual(fixture.fileSystem.readPaths.includes(`${REGISTRY_DIRECTORY}/notes.txt`), false,
        'only *.json registry files are read');
});

test('SessionsSource: a malformed registry file is skipped with one log line, and the others still name rows',
    async () => {
    const fixture = sessionsFixture();
    const files = {
        [`${REGISTRY_DIRECTORY}/broken.json`]: '{"pane_id": ',
        [`${REGISTRY_DIRECTORY}/wL_p1.json`]: JSON.stringify({pane_id: 'p1', slug: 'host-sync'}),
    };
    const registryFileSystem =
        fakeFileSystem({files, directories: {[REGISTRY_DIRECTORY]: ['broken.json', 'wL_p1.json']}});
    const fileSystem = {
        ...fixture.fileSystem,
        readFile: path =>
            (path.startsWith(REGISTRY_DIRECTORY) ? registryFileSystem : fixture.fileSystem).readFile(path),
        listDirectory: path =>
            (path === REGISTRY_DIRECTORY ? registryFileSystem : fixture.fileSystem).listDirectory(path),
    };
    const loggedLines = [];
    const source = sessionsSourceOver({...fixture, fileSystem}, {logWriter: line => loggedLines.push(line)});
    const sessions = await source.sample();
    await source.sample();
    assertEqual(sessions.rows[0].name, 'host-sync');
    assertEqual(loggedLines.length, 1, loggedLines.join(' | '));
    assertEqual(loggedLines[0].startsWith(`cockpit: sessions: skipped registry file ${REGISTRY_DIRECTORY}/broken.json`),
        true, loggedLines[0]);
});

/** A fake NetworkManager proxy: a name owner, cached properties, and the g-properties-changed signal. */
class FakeNetworkManagerProxy {
    /**
     * @param {object} state - What it reports.
     * @param {string|null} state.nameOwner - NetworkManager's unique name; null when it is not running.
     * @param {Object<string, GLib.Variant>} state.properties - Cached properties by name.
     */
    constructor({nameOwner, properties}) {
        this._nameOwner = nameOwner;
        this._properties = properties;
        this.handlersById = new Map();
        this._nextHandlerId = 1;
    }

    /** @returns {string|null} The name owner. */
    get_name_owner() {
        return this._nameOwner;
    }

    /**
     * @param {string} propertyName - A property.
     * @returns {GLib.Variant|null} Its cached value.
     */
    get_cached_property(propertyName) {
        return this._properties[propertyName] ?? null;
    }

    /**
     * @param {string} signalName - Only 'g-properties-changed' is emitted.
     * @param {Function} handler - The handler.
     * @returns {number} The handler id.
     */
    connect(signalName, handler) {
        const handlerId = this._nextHandlerId++;
        this.handlersById.set(handlerId, {signalName, handler});
        return handlerId;
    }

    /**
     * @param {number} handlerId - An id connect returned.
     * @returns {void}
     */
    disconnect(handlerId) {
        if (!this.handlersById.delete(handlerId))
            throw new Error(`disconnected handler ${handlerId}, which is not connected`);
    }

    /**
     * Emits g-properties-changed as GDBusProxy does on PropertiesChanged.
     *
     * @param {string[]} changedNames - Properties whose new values came with the signal.
     * @param {string[]} invalidatedNames - Properties invalidated without a value.
     * @returns {void}
     */
    emitPropertiesChanged(changedNames, invalidatedNames = []) {
        const changedValues = Object.fromEntries(changedNames.map(name => [name, new GLib.Variant('s', 'changed')]));
        const changedProperties = new GLib.Variant('a{sv}', changedValues);
        for (const {signalName, handler} of this.handlersById.values()) {
            if (signalName === 'g-properties-changed')
                handler(this, changedProperties, invalidatedNames);
        }
    }
}

/** @returns {FakeNetworkManagerProxy} NetworkManager running, on a wired uplink with full connectivity. */
function wiredNetworkManager() {
    return new FakeNetworkManagerProxy({
        nameOwner: NETWORK_MANAGER_OWNER,
        properties: {
            PrimaryConnection: new GLib.Variant('o', '/org/freedesktop/NetworkManager/ActiveConnection/3'),
            PrimaryConnectionType: new GLib.Variant('s', WIRED_CONNECTION_TYPE),
            Connectivity: new GLib.Variant('u', NM_CONNECTIVITY_FULL),
            WirelessEnabled: new GLib.Variant('b', false),
        },
    });
}

/**
 * @param {object} options - The fakes.
 * @param {object} options.networkManagerProxy - The proxy.
 * @param {object} options.fileSystem - fakeFileSystem's result.
 * @returns {object} A NetworkSource over them.
 */
function networkSourceOver({networkManagerProxy, fileSystem}) {
    return new networkSource.NetworkSource({
        networkManagerProxy, homeDirectory: FAKE_HOME,
        readFile: path => fileSystem.readFile(path), listDirectory: path => fileSystem.listDirectory(path),
    });
}

test('NetworkSource: a sample reads the uplink, the tunnel and the ssh masters, reader-valid', async () => {
    const fileSystem = fakeFileSystem({
        files: {[PROC_NET_ROUTE_PATH]: TUNNEL_ROUTE_TABLE},
        directories: {[SSH_SOCKETS_DIRECTORY]: ['0123abcd', '4567ef01']},
    });
    const source = networkSourceOver({networkManagerProxy: wiredNetworkManager(), fileSystem});
    assertEqual(source.name, 'network');
    const network = await source.sample();
    assertEqual(cockpitProtocol.parseNetworkSource(network), network, 'the reader keeps every field');
    assertEqual([network.uplink, network.vpn, network.sshMasterCount], [
        {kind: 'wired', connectivity: 'full', wifiEnabled: false}, {isUp: true, interfaceName: 'tun0'}, 2,
    ]);
});

test('NetworkSource: ~/.ssh/sockets is listed and never opened; missing dir is 0 masters', async () => {
    const fileSystem = fakeFileSystem({
        files: {[PROC_NET_ROUTE_PATH]: ROUTE_TABLE_HEADER},
        directories: {[SSH_SOCKETS_DIRECTORY]: ['a1', 'b2', 'c3']},
    });
    const source = networkSourceOver({networkManagerProxy: wiredNetworkManager(), fileSystem});
    assertEqual((await source.sample()).sshMasterCount, 3);
    assertEqual(fileSystem.listedPaths, [SSH_SOCKETS_DIRECTORY]);
    assertEqual(fileSystem.readPaths, [PROC_NET_ROUTE_PATH], 'the one file opened is /proc/net/route');
    const withoutSockets = fakeFileSystem({files: {[PROC_NET_ROUTE_PATH]: ROUTE_TABLE_HEADER}});
    const network = await networkSourceOver({networkManagerProxy: wiredNetworkManager(), fileSystem: withoutSockets})
        .sample();
    assertEqual(network.sshMasterCount, 0);
    assertEqual(withoutSockets.readPaths, [PROC_NET_ROUTE_PATH]);
});

test('NetworkSource: an ssh sockets directory that cannot be listed for another reason is an unknown count',
    async () => {
    const fileSystem = fakeFileSystem({files: {[PROC_NET_ROUTE_PATH]: ROUTE_TABLE_HEADER}});
    fileSystem.listDirectory = path => {
        throw new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.PERMISSION_DENIED, `${path}: Permission denied`);
    };
    const network = await networkSourceOver({networkManagerProxy: wiredNetworkManager(), fileSystem}).sample();
    assertEqual(network.sshMasterCount, null);
});

test('NetworkSource: NetworkManager absent is an uplink of nulls and no error', async () => {
    const fileSystem = fakeFileSystem({files: {[PROC_NET_ROUTE_PATH]: ROUTE_TABLE_HEADER}});
    const notRunning = new FakeNetworkManagerProxy({nameOwner: null, properties: {}});
    const nullUplink = {kind: null, connectivity: null, wifiEnabled: null};
    assertEqual((await networkSourceOver({networkManagerProxy: notRunning, fileSystem}).sample()).uplink, nullUplink);
    const network = await networkSourceOver({networkManagerProxy: null, fileSystem}).sample();
    assertEqual(network.uplink, nullUplink, 'no proxy at all (no system bus)');
    assertEqual(cockpitProtocol.parseNetworkSource(network), network);
});

test('NetworkSource: only the uplink properties signal a change, and destroy disconnects', () => {
    const networkManagerProxy = wiredNetworkManager();
    const source = networkSourceOver({networkManagerProxy, fileSystem: fakeFileSystem({})});
    let changeCount = 0;
    source.watchChanges(() => changeCount++);
    networkManagerProxy.emitPropertiesChanged(['Metered', 'ActiveConnections']);
    assertEqual(changeCount, 0, 'another property is no change');
    networkManagerProxy.emitPropertiesChanged(['Connectivity']);
    networkManagerProxy.emitPropertiesChanged([], ['PrimaryConnection']);
    networkManagerProxy.emitPropertiesChanged(['WirelessEnabled', 'Devices']);
    assertEqual(changeCount, 3);
    source.destroy();
    assertEqual(networkManagerProxy.handlersById.size, 0);
    source.destroy();
});

/** A fake Gio.UnixMountMonitor: the mounts-changed signal. */
class FakeMountMonitor {
    constructor() {
        this.handlersById = new Map();
        this._nextHandlerId = 1;
    }

    /**
     * @param {string} signalName - The signal.
     * @param {Function} handler - The handler.
     * @returns {number} The handler id.
     */
    connect(signalName, handler) {
        const handlerId = this._nextHandlerId++;
        this.handlersById.set(handlerId, {signalName, handler});
        return handlerId;
    }

    /**
     * @param {number} handlerId - An id connect returned.
     * @returns {void}
     */
    disconnect(handlerId) {
        if (!this.handlersById.delete(handlerId))
            throw new Error(`disconnected handler ${handlerId}, which is not connected`);
    }

    /** @returns {void} Emits mounts-changed. */
    emitMountsChanged() {
        for (const {signalName, handler} of this.handlersById.values()) {
            if (signalName === 'mounts-changed')
                handler(this);
        }
    }
}

/** The mounts the mounts rows list: the root (not a row), a removable disk and a network share. */
const FAKE_MOUNT_ENTRIES = [
    {mountPoint: '/', filesystemType: 'ext4', devicePath: '/dev/nvme0n1p2', label: 'Filesystem root'},
    {mountPoint: '/media/tester/USB', filesystemType: 'vfat', devicePath: '/dev/sda1', label: 'USB'},
    {mountPoint: '/mnt/nas', filesystemType: 'nfs4', devicePath: 'nas:/export', label: 'nas'},
];

test('MountsSource: a sample lists the mounts and queries sizes only for the rows, reader-valid', async () => {
    const queriedMountPoints = [];
    const source = new mountsSource.MountsSource({
        mountMonitor: new FakeMountMonitor(),
        listMountEntries: () => FAKE_MOUNT_ENTRIES,
        queryFilesystem: mountPoint => {
            queriedMountPoints.push(mountPoint);
            return Promise.resolve({freeBytes: GIB, totalBytes: 4 * GIB});
        },
    });
    assertEqual(source.name, 'mounts');
    const mounts = await source.sample();
    assertEqual(cockpitProtocol.parseMountsSource(mounts), mounts, 'the reader keeps every field');
    assertEqual(queriedMountPoints.sort(), ['/media/tester/USB', '/mnt/nas']);
    assertEqual(mounts.rows, [
        {mountPoint: '/media/tester/USB', label: 'USB', kind: 'removable', filesystemType: 'vfat', freeBytes: GIB,
            totalBytes: 4 * GIB},
        {mountPoint: '/mnt/nas', label: 'nas', kind: 'network', filesystemType: 'nfs4', freeBytes: GIB,
            totalBytes: 4 * GIB},
    ]);
});

test('MountsSource: a filesystem query that fails gives null sizes, the row kept', async () => {
    const source = new mountsSource.MountsSource({
        mountMonitor: new FakeMountMonitor(),
        listMountEntries: () => FAKE_MOUNT_ENTRIES,
        queryFilesystem: mountPoint => (mountPoint === '/mnt/nas'
            ? Promise.reject(new Error('filesystem query of /mnt/nas timed out after 2000 ms'))
            : Promise.resolve({freeBytes: GIB, totalBytes: 4 * GIB})),
    });
    const mounts = await source.sample();
    assertEqual(mounts.rows.map(row => [row.mountPoint, row.freeBytes, row.totalBytes]),
        [['/media/tester/USB', GIB, 4 * GIB], ['/mnt/nas', null, null]]);
    assertEqual(cockpitProtocol.parseMountsSource(mounts), mounts);
});

test('MountsSource: mounts-changed signals a change, and destroy disconnects', () => {
    const mountMonitor = new FakeMountMonitor();
    const source = new mountsSource.MountsSource({
        mountMonitor, listMountEntries: () => [], queryFilesystem: () => Promise.resolve(null),
    });
    let changeCount = 0;
    source.watchChanges(() => changeCount++);
    mountMonitor.emitMountsChanged();
    assertEqual(changeCount, 1);
    source.destroy();
    mountMonitor.emitMountsChanged();
    assertEqual([changeCount, mountMonitor.handlersById.size], [1, 0]);
    source.destroy();
});

/**
 * @returns {string} A fresh temp directory, standing in for a home directory.
 */
function makeTempHome() {
    return GLib.dir_make_tmp(TEMP_DIRECTORY_TEMPLATE);
}

/**
 * @param {string} path - A file to create, with its parent directories.
 * @param {string} text - Its contents.
 * @returns {void}
 */
function plantFile(path, text) {
    GLib.mkdir_with_parents(GLib.path_get_dirname(path), 0o700);
    GLib.file_set_contents(path, text);
}

/**
 * Removes a temp tree the rows made: files and directories, depth first.
 *
 * @param {string} path - The tree's root.
 * @returns {void}
 */
function removeTree(path) {
    const file = Gio.File.new_for_path(path);
    const fileType = file.query_file_type(Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
    if (fileType === Gio.FileType.DIRECTORY) {
        const enumerator = file.enumerate_children('standard::name', Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        for (let info = enumerator.next_file(null); info !== null; info = enumerator.next_file(null))
            removeTree(GLib.build_filenamev([path, info.get_name()]));
        enumerator.close(null);
    }
    file.delete(null);
}

test('readFileRefusingSecrets: every stat-only path is refused before it is opened; an ordinary file is read', () => {
    const fakeHome = makeTempHome();
    try {
        const secretPaths = [
            ...SECRET_DIRECTORY_FILES.map(([directoryName, fileName]) => `${fakeHome}/${directoryName}/${fileName}`),
            ...LOCAL_FILE_STEMS.map(stem => `${fakeHome}/${stem}${LOCAL_FILE_SUFFIX}`),
        ];
        secretPaths.forEach(path => plantFile(path, PLANTED_SECRET_TEXT));
        const outcomes = secretPaths.map(path => {
            try {
                return `read: ${sourceIo.readFileRefusingSecrets(path)}`;
            } catch (error) {
                return error.message;
            }
        });
        assertEqual(outcomes, secretPaths.map(path => `cockpit: refused to open ${path}`));
        const ordinaryPath = `${fakeHome}/dev/notes.json`;
        plantFile(ordinaryPath, '{"ok": true}');
        assertEqual(sourceIo.readFileRefusingSecrets(ordinaryPath), '{"ok": true}');
        assertEqual(sourceIo.listEntryNames(`${fakeHome}/.ssh`), ['id_ed25519'],
            'listing a stat-only directory is allowed');
    } finally {
        removeTree(fakeHome);
    }
});

test('sourceIo: listEntryNames names files and directories alike; a stat gives an mtime, null when missing', () => {
    const fakeHome = makeTempHome();
    try {
        plantFile(`${fakeHome}/registry/a.json`, '{}');
        plantFile(`${fakeHome}/registry/sub/b.json`, '{}');
        assertEqual(sourceIo.listEntryNames(`${fakeHome}/registry`).sort(), ['a.json', 'sub']);
        let listingError = null;
        try {
            sourceIo.listEntryNames(`${fakeHome}/missing`);
        } catch (error) {
            listingError = error;
        }
        assertEqual(sourceIo.isNotFoundError(listingError), true);
        assertEqual(sourceIo.isNotFoundError(new Error('plain')), false);
        const mtimeUsec = sourceIo.modificationTimeUsecOrNull(`${fakeHome}/registry/a.json`);
        const nowUsec = GLib.get_real_time();
        assertEqual(Number.isInteger(mtimeUsec) && Math.abs(nowUsec - mtimeUsec) < 60 * MICROSECONDS_PER_SECOND, true,
            String(mtimeUsec));
        assertEqual(sourceIo.modificationTimeUsecOrNull(`${fakeHome}/registry/missing.jsonl`), null);
    } finally {
        removeTree(fakeHome);
    }
});

test('mounts: the real filesystem query gives a directory\'s sizes and rejects for a missing path', async () => {
    const queryFilesystem = mountsSource.createFilesystemSizeQuery();
    const sizes = await queryFilesystem(GLib.get_tmp_dir());
    assertEqual(Number.isFinite(sizes.freeBytes) && Number.isFinite(sizes.totalBytes) &&
        sizes.totalBytes >= sizes.freeBytes && sizes.totalBytes > 0, true, JSON.stringify(sizes));
    let rejection = null;
    await queryFilesystem('/nonexistent-cockpit-mount').catch(error => {
        rejection = error;
    });
    assertEqual(rejection !== null, true);
});
