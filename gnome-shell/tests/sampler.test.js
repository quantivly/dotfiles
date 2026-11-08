// The Sampler, run against the fixture roots under fixtures/ with a fake clock. The timer rows wait in real
// time on the GLib.MainLoop that run.js drives.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {Sampler, groupOfCgroup} from '../extensions/resource-pulse@dotfiles/sampler.js';
import {
    APP_SCAN_EVERY_N_TICKS, APP_SCAN_INTERVAL_SECONDS, ERROR_LOG_REPEAT_INTERVAL_USEC, KERNEL_AND_OTHER_LABEL,
    LOG_PREFIX, SAMPLE_INTERVAL_SECONDS,
} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

const [TEST_FILE_PATH] = GLib.filename_from_uri(import.meta.url);
const FIXTURES_DIRECTORY = GLib.build_filenamev([GLib.path_get_dirname(TEST_FILE_PATH), 'fixtures']);
const APP_SCAN_SPACING_USEC = 6_000_000;
const SAMPLE_SPACING_USEC = 2_000_000;
const BYTES_PER_KIB = 1024;
const FIXTURE_MEMORY_USED_KIB = 20_000_000;
const FIXTURE_SWAP_ON_DISK_BYTES = 512_000_000;
const FIXTURE_CLOCK_LABEL = '14:02';
const TIMER_INTERVAL_SECONDS = 1;
const TIMER_RUN_MS = 2500;
const AFTER_STOP_MS = 1500;
/** Lets a sample already in flight when stop() ran finish before counting starts. */
const IN_FLIGHT_SETTLE_MS = 300;
const TICK_FAILURE_SETTLE_MS = 200;
/** An interval long enough that a real firing never lands inside a row that drives the callback itself. */
const QUIET_INTERVAL_SECONDS = 60;
const USER_APP_SLICE = 'user.slice/user-1000.slice/user@1000.service/app.slice';

/**
 * Builds the absolute path of a fixture root.
 *
 * @param {string} rootName - Directory under fixtures/, for example 'root-a'.
 * @returns {string} The path.
 */
function fixtureRoot(rootName) {
    return GLib.build_filenamev([FIXTURES_DIRECTORY, rootName]);
}

/**
 * Creates a Sampler on a fake clock that records what it logs.
 *
 * @param {string} rootName - The fixture root to start from.
 * @param {object} [overrides] - Constructor options replacing the test defaults.
 * @returns {{sampler: Sampler, clock: {nowUsec: number}, logged: string[]}} The sampler and its spies.
 */
function makeSampler(rootName, overrides = {}) {
    const clock = {nowUsec: 0};
    const logged = [];
    const sampler = new Sampler({
        fsRoot: fixtureRoot(rootName),
        nowUsec: () => clock.nowUsec,
        clockLabel: () => FIXTURE_CLOCK_LABEL,
        log: message => logged.push(message),
        ...overrides,
    });
    return {sampler, clock, logged};
}

/**
 * Samples root-a and then root-b, two seconds apart.
 *
 * @param {Sampler} sampler - An initialized sampler.
 * @param {{nowUsec: number}} clock - Its fake clock.
 * @returns {Promise<object>} The second snapshot.
 */
async function sampleTwoTicks(sampler, clock) {
    sampler.fsRoot = fixtureRoot('root-a');
    await sampler.sampleOnce();
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.fsRoot = fixtureRoot('root-b');
    return sampler.sampleOnce();
}

/**
 * Runs two app scans six seconds apart: root-a, then the given root.
 *
 * @param {string} secondRootName - The root of the second scan.
 * @returns {Promise<{ranking: object, logged: string[]}>} The second ranking and what was logged.
 */
async function scanTwice(secondRootName) {
    const {sampler, clock, logged} = makeSampler('root-a');
    await sampler.initialize();
    await sampler.scanAppsOnce();
    clock.nowUsec += APP_SCAN_SPACING_USEC;
    sampler.fsRoot = fixtureRoot(secondRootName);
    const ranking = await sampler.scanAppsOnce();
    sampler.destroy();
    return {ranking, logged};
}

/**
 * Resolves after a real delay, while the main loop keeps running.
 *
 * @param {number} delayMs - Milliseconds to wait.
 * @returns {Promise<void>} Settles after the delay.
 */
function waitMs(delayMs) {
    return new Promise(resolve => {
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, delayMs, () => {
            resolve();
            return GLib.SOURCE_REMOVE;
        });
    });
}

/**
 * Runs a body while GLib.timeout_add_seconds and GLib.source_remove are spied on (the sources stay real).
 *
 * @param {(spy: {added: Array<{sourceId: number, callback: Function}>, removed: number[]}) => Promise<void>} body
 *     The test body.
 * @returns {Promise<void>} Settles when the body has, with the originals restored.
 */
async function withTimerSpy(body) {
    const originalTimeoutAddSeconds = GLib.timeout_add_seconds;
    const originalSourceRemove = GLib.source_remove;
    const spy = {added: [], removed: []};
    GLib.timeout_add_seconds = (priority, intervalSeconds, callback) => {
        const sourceId = originalTimeoutAddSeconds(priority, intervalSeconds, callback);
        spy.added.push({sourceId, callback});
        return sourceId;
    };
    GLib.source_remove = sourceId => {
        spy.removed.push(sourceId);
        return originalSourceRemove(sourceId);
    };
    try {
        await body(spy);
    } finally {
        GLib.timeout_add_seconds = originalTimeoutAddSeconds;
        GLib.source_remove = originalSourceRemove;
    }
}

/**
 * Says whether a GLib source still exists on the default main context.
 *
 * @param {number} sourceId - The id timeout_add_seconds returned.
 * @returns {boolean} True while the source is attached.
 */
function isSourceAttached(sourceId) {
    return GLib.MainContext.default().find_source_by_id(sourceId) !== null;
}

test('sampler: root-a then root-b gives CPU 60% with P 80 and E 40, complete', async () => {
    const {sampler, clock} = makeSampler('root-a');
    await sampler.initialize();
    const snapshot = await sampleTwoTicks(sampler, clock);
    // The history holds fractions, and the first sample is a gap (null), never 0.
    assertEqual([snapshot.cpuBusyPercent, snapshot.cpuClusters, snapshot.isComplete, sampler.cpuHistory.values()],
        [60, {performancePercent: 80, efficiencyPercent: 40}, true, [null, 0.6]]);
});

test('sampler: the first sample is no data for CPU, never 0%, while memory is present', async () => {
    const {sampler} = makeSampler('root-a');
    await sampler.initialize();
    const labelBefore = sampler.lastGoodClockLabel;
    const snapshot = await sampler.sampleOnce();
    assertEqual([snapshot.cpuBusyPercent, snapshot.cpuClusters, snapshot.memory !== null, snapshot.isComplete,
        labelBefore, sampler.lastGoodClockLabel], [null, null, true, true, null, FIXTURE_CLOCK_LABEL]);
});

test('sampler: memory used is MemTotal − MemAvailable in bytes, and its history is the used fraction', async () => {
    const {sampler} = makeSampler('root-a');
    const snapshot = await sampler.sampleOnce();
    assertEqual([snapshot.memory, sampler.memoryHistory.values()],
        [{usedBytes: FIXTURE_MEMORY_USED_KIB * BYTES_PER_KIB, totalBytes: 32_768_000_000}, [0.625]]);
});

test('sampler: swap on disk is swapped minus what zram stores', async () => {
    const {sampler} = makeSampler('root-a');
    const snapshot = await sampler.sampleOnce();
    assertEqual([snapshot.swap.diskBytes, snapshot.swap.zramStoredBytes, snapshot.swap.zramRamBytes],
        [FIXTURE_SWAP_ON_DISK_BYTES, 1_536_000_000, 400_000_000]);
});

test('sampler: PSI cpu some avg10 is 12.5, memory and io 0', async () => {
    const {sampler} = makeSampler('root-a');
    const snapshot = await sampler.sampleOnce();
    assertEqual(snapshot.pressureAvg10, {cpu: 12.5, memory: 0, io: 0});
});

test('sampler: without /proc/pressure every pressure is null, memory stays, the sample is incomplete', async () => {
    const {sampler} = makeSampler('root-no-psi');
    const snapshot = await sampler.sampleOnce();
    assertEqual([snapshot.pressureAvg10, snapshot.memory !== null, snapshot.isComplete],
        [{cpu: null, memory: null, io: null}, true, false]);
});

test('sampler: a missing /proc/stat nulls CPU and logs once per 10 minutes, prefixed', async () => {
    const {sampler, clock, logged} = makeSampler('root-a');
    await sampler.initialize();
    sampler.fsRoot = fixtureRoot('root-no-stat');
    const snapshot = await sampler.sampleOnce();
    const loggedAfterFirst = logged.length;
    clock.nowUsec += SAMPLE_SPACING_USEC;
    await sampler.sampleOnce();
    const loggedInsideInterval = logged.length;
    clock.nowUsec = ERROR_LOG_REPEAT_INTERVAL_USEC + 1;
    await sampler.sampleOnce();
    assertEqual([snapshot.cpuBusyPercent, snapshot.isComplete, loggedAfterFirst, loggedInsideInterval, logged.length,
        logged.every(message => message.startsWith(`${LOG_PREFIX} `))], [null, false, 1, 1, 2, true]);
});

test('sampler: a second sampleOnce (or scanAppsOnce) while one is in flight is skipped, not queued', async () => {
    const {sampler} = makeSampler('root-a');
    const first = sampler.sampleOnce();
    const second = sampler.sampleOnce();
    const firstScan = sampler.scanAppsOnce();
    const secondScan = sampler.scanAppsOnce();
    const [secondSnapshot, firstSnapshot] = [await second, await first];
    const [secondRanking, firstRanking] = [await secondScan, await firstScan];
    assertEqual([secondSnapshot, firstSnapshot !== null, sampler.cpuHistory.values().length,
        sampler.memoryHistory.values().length, secondRanking, firstRanking !== null], [null, true, 1, 1, null, true]);
});

test('sampler: destroy() while a sample is in flight resolves it null, calls no listener, keeps history', async () => {
    const {sampler} = makeSampler('root-a');
    await sampler.sampleOnce();
    const snapshotBefore = sampler.latestSnapshot;
    let listenerCalls = 0;
    sampler.addListener(() => listenerCalls++);
    const pending = sampler.sampleOnce();
    sampler.destroy();
    const result = await pending;
    assertEqual([result, listenerCalls, sampler.cpuHistory.values().length, sampler.memoryHistory.values().length,
        sampler.latestSnapshot === snapshotBefore], [null, 0, 1, 1, true]);
});

test('sampler: app scan root-a → root-b ranks herdr agents top for CPU (50%) and memory (15 GB)', async () => {
    const {ranking, logged} = await scanTwice('root-b');
    assertEqual([ranking, logged], [{
        topCpu: {name: 'herdr agents', cpuPercent: 50},
        topMemory: {name: 'herdr agents', memoryBytes: 15_000_000_000},
    }, []]);
});

test('sampler: the app scan interval is exactly APP_SCAN_EVERY_N_TICKS sample intervals', () =>
    assertEqual(APP_SCAN_INTERVAL_SECONDS, SAMPLE_INTERVAL_SECONDS * APP_SCAN_EVERY_N_TICKS));

test('sampler: the app scan skips units that never host an app (.mount, .socket), at both depths', async () => {
    // boot.mount (5 MB, in system.slice) and example.socket (9 MB, in a sub-slice) would each top memory if scanned.
    const {sampler} = makeSampler('root-unit-types');
    const ranking = await sampler.scanAppsOnce();
    assertEqual(ranking.topMemory, {name: 'example-daemon', memoryBytes: 1_000_000});
});

test('sampler: app CPU divides by the real time between scans, not the nominal interval', async () => {
    // The second scan runs 12 s after the first: herdr's 6 s of CPU over 12 s × 2 CPUs is 25%, not 50%.
    const {sampler, clock} = makeSampler('root-a');
    await sampler.initialize();
    await sampler.scanAppsOnce();
    clock.nowUsec += 2 * APP_SCAN_SPACING_USEC;
    sampler.fsRoot = fixtureRoot('root-b');
    const ranking = await sampler.scanAppsOnce();
    assertEqual(ranking.topCpu, {name: 'herdr agents', cpuPercent: 25});
});

test('sampler: a sample in flight across a pause, or a scan in flight when scanning stops, is dropped', async () => {
    // Kept, either would reinstate a baseline from before the interruption that was just thrown away.
    const {sampler} = makeSampler('root-a');
    await sampler.initialize();
    const pendingSample = sampler.sampleOnce();
    sampler.setPaused(true);
    sampler.setPaused(false);
    const pendingScan = sampler.scanAppsOnce();
    sampler.setAppScanEnabled(false);
    const [sampleResult, scanResult] = [await pendingSample, await pendingScan];
    const nextSnapshot = await sampler.sampleOnce();
    assertEqual([sampleResult, scanResult, sampler.cpuHistory.values().length, nextSnapshot.cpuBusyPercent,
        nextSnapshot.apps], [null, null, 1, null, null]);
});

test('sampler: a scan turned off between its cgroup listing and its reads is dropped too', async () => {
    // The scan awaits twice; the first file read starts only after the listing has settled.
    const {sampler} = makeSampler('root-a');
    await sampler.initialize();
    const originalLoadContentsAsync = Gio.File.prototype.load_contents_async;
    Gio.File.prototype.load_contents_async = function (...readArguments) {
        sampler.setAppScanEnabled(false);
        return originalLoadContentsAsync.apply(this, readArguments);
    };
    let scanResult;
    try {
        scanResult = await sampler.scanAppsOnce();
    } finally {
        Gio.File.prototype.load_contents_async = originalLoadContentsAsync;
    }
    const nextSnapshot = await sampler.sampleOnce();
    assertEqual([scanResult, nextSnapshot.apps], [null, null]);
});

test('sampler: two Chrome scopes are one app (one group key, one name)', () => {
    const groups = ['app-com.google.Chrome-2.scope', 'app-com.google.Chrome-3.scope']
        .map(leafName => groupOfCgroup(`${USER_APP_SLICE}/${leafName}`, () => null));
    assertEqual([groups[0], groups[0].groupKey === groups[1].groupKey],
        [{groupKey: 'app:com.google.Chrome', name: 'Chrome'}, true]);
});

test('sampler: a cgroup that vanished mid-scan is skipped in both rankings and the scan succeeds', async () => {
    // Σ apps without herdr = 4.0 + 2×0.5 + 0.3 + 0.3 GB = 5.6 GB of 20.48 GB used; leaf CPU Δ 4.5 s of root Δ 12 s.
    // Had herdr been kept, it would top both rankings (see the row above).
    const {ranking, logged} = await scanTwice('root-vanished');
    assertEqual([ranking, logged], [{
        topCpu: {name: KERNEL_AND_OTHER_LABEL, cpuPercent: 62.5},
        topMemory: {name: KERNEL_AND_OTHER_LABEL, memoryBytes: 14_880_000_000},
    }, []]);
});

test('sampler: a leaf inside a sub-slice is found, and at or under 64 MiB it is uncorrected', async () => {
    // The leaf sits in system.slice/system-example.slice/, so a scan that does not descend into a sub-slice finds
    // nothing. Its memory.stat says all 1,000,000 bytes are page cache; reading it would rank it at 0 bytes.
    const {sampler} = makeSampler('root-small-leaf');
    await sampler.initialize();
    const ranking = await sampler.scanAppsOnce();
    assertEqual(ranking.topMemory, {name: 'example-tool', memoryBytes: 1_000_000});
});

test('sampler: runTick(0) scans apps only while enabled, and disabling drops the old ranking', async () => {
    const {sampler} = makeSampler('root-a');
    await sampler.initialize();
    sampler.setAppScanEnabled(false);
    await sampler.runTick(0);
    const appsWhileDisabled = sampler.latestSnapshot.apps;
    sampler.setAppScanEnabled(true);
    await sampler.runTick(0);
    const appsWhileEnabled = sampler.latestSnapshot.apps;
    sampler.setAppScanEnabled(false);
    await sampler.runTick(1);
    assertEqual([appsWhileDisabled, appsWhileEnabled !== null, sampler.latestSnapshot.apps], [null, true, null]);
});

test('sampler: after a pause the CPU and app baselines restart (no average across the gap)', async () => {
    const {sampler, clock} = makeSampler('root-a');
    await sampler.initialize();
    await sampler.scanAppsOnce();
    await sampler.sampleOnce();
    sampler.setPaused(true);
    sampler.setPaused(false);
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.fsRoot = fixtureRoot('root-b');
    const snapshot = await sampler.sampleOnce();
    assertEqual([snapshot.cpuBusyPercent, snapshot.apps], [null, null]);
});

test('sampler: an unparseable PMU list falls back to cpu_capacity and is logged, not thrown', async () => {
    const {sampler, clock, logged} = makeSampler('root-bad-pmu');
    await sampler.initialize();
    const snapshot = await sampleTwoTicks(sampler, clock);
    assertEqual([snapshot.cpuClusters, logged.length, logged[0]?.startsWith(LOG_PREFIX),
        logged[0]?.includes('cpu_core/cpus')], [{performancePercent: 80, efficiencyPercent: 40}, 1, true, true]);
});

test('sampler: a throwing listener is logged and the next still runs; a removed one is not called', async () => {
    const {sampler, logged} = makeSampler('root-a');
    const calls = {afterThrowing: 0, removed: 0};
    sampler.addListener(() => {
        throw new Error('listener exploded');
    });
    sampler.addListener(() => calls.afterThrowing++);
    const removedListenerId = sampler.addListener(() => calls.removed++);
    sampler.removeListener(removedListenerId);
    const snapshot = await sampler.sampleOnce();
    assertEqual([snapshot !== null, calls, logged.length, logged[0]?.startsWith(LOG_PREFIX),
        logged[0]?.includes('listener exploded')], [true, {afterThrowing: 1, removed: 0}, 1, true, true]);
});

test('sampler: start() twice adds one source; stop, pause and destroy remove it; nothing after destroy', async () => {
    await withTimerSpy(async spy => {
        const {sampler} = makeSampler('root-a', {sampleIntervalSeconds: QUIET_INTERVAL_SECONDS});
        sampler.start();
        sampler.start();
        const addedByDoubleStart = spy.added.length;
        sampler.stop();
        sampler.start();
        sampler.setPaused(true);
        const addedWhilePaused = spy.added.length;
        sampler.setPaused(false);
        sampler.destroy();
        // Checked before the start() below, which would otherwise tidy up a source destroy() had left behind.
        const addedIds = spy.added.map(entry => entry.sourceId);
        const isAnySourceAttachedAfterDestroy = addedIds.some(isSourceAttached);
        sampler.start();
        assertEqual([addedByDoubleStart, addedWhilePaused, spy.added.length, spy.removed,
            isAnySourceAttachedAfterDestroy], [1, 2, 3, addedIds, false]);
    });
});

test('sampler: the timer callback never throws; a failing tick is logged and the timer continues', async () => {
    await withTimerSpy(async spy => {
        const {sampler, logged} = makeSampler('root-a', {
            sampleIntervalSeconds: QUIET_INTERVAL_SECONDS,
            clockLabel: () => {
                throw new Error('clock exploded');
            },
        });
        sampler.start();
        const callbackResult = spy.added[0].callback();
        await waitMs(TICK_FAILURE_SETTLE_MS);
        const isStillAttached = isSourceAttached(spy.added[0].sourceId);
        sampler.destroy();
        assertEqual([callbackResult, isStillAttached, logged.length, logged[0]?.startsWith(LOG_PREFIX),
            logged[0]?.includes('clock exploded')], [GLib.SOURCE_CONTINUE, true, 1, true, true]);
    });
});

test('sampler: a real 1 s timer calls listeners, and none fire for 1.5 s after stop()', async () => {
    const {sampler} = makeSampler('root-a', {sampleIntervalSeconds: TIMER_INTERVAL_SECONDS});
    let listenerCalls = 0;
    sampler.addListener(() => listenerCalls++);
    sampler.start();
    await waitMs(TIMER_RUN_MS);
    sampler.stop();
    const callsWhileRunning = listenerCalls;
    await waitMs(IN_FLIGHT_SETTLE_MS);
    const callsAtStop = listenerCalls;
    await waitMs(AFTER_STOP_MS);
    sampler.destroy();
    assertEqual([callsWhileRunning >= 1, listenerCalls - callsAtStop], [true, 0],
        `${callsWhileRunning} calls while running`);
});

test('sampler: paused before start(), a real 1 s timer calls no listener in 2.5 s', async () => {
    const {sampler} = makeSampler('root-a', {sampleIntervalSeconds: TIMER_INTERVAL_SECONDS});
    let listenerCalls = 0;
    sampler.addListener(() => listenerCalls++);
    sampler.setPaused(true);
    sampler.start();
    await waitMs(TIMER_RUN_MS);
    sampler.destroy();
    assertEqual(listenerCalls, 0);
});
