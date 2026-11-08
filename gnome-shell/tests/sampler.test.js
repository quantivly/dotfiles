// The Sampler, run against the fixture roots under fixtures/ with a fake clock. The timer rows wait in real
// time on the GLib.MainLoop that run.js drives.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {Sampler, groupOfCgroup, readTextFile} from '../extensions/resource-pulse@dotfiles/sampler.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';
import {cardText} from '../extensions/resource-pulse@dotfiles/lib/format.js';
import {
    APP_SCAN_EVERY_N_TICKS, APP_SCAN_INTERVAL_SECONDS, APP_SCAN_READ_BATCH_LEAVES, ERROR_LOG_REPEAT_INTERVAL_USEC,
    FILE_READ_CHUNK_BYTES, KERNEL_AND_OTHER_LABEL, LOG_PREFIX, SAMPLE_INTERVAL_SECONDS, SAMPLE_STALL_TICKS,
} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

const [TEST_FILE_PATH] = GLib.filename_from_uri(import.meta.url);
const FIXTURES_DIRECTORY = GLib.build_filenamev([GLib.path_get_dirname(TEST_FILE_PATH), 'fixtures']);
const APP_SCAN_SPACING_USEC = 6_000_000;
const SAMPLE_SPACING_USEC = 2_000_000;
const BYTES_PER_KIB = 1024;
const FIXTURE_MEMORY_USED_KIB = 20_000_000;
/** root-a's /dev/zram0 Used (1,600,000 KiB), above its orig_data_size of 1,536,000,000 B; /swap.img Used is 0. */
const FIXTURE_ZRAM_SWAP_USED_BYTES = 1_600_000 * BYTES_PER_KIB;
const FIXTURE_ZRAM_RAM_BYTES = 400_000_000;
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
const LATER_CLOCK_LABEL = '14:04';
/** The end of the /proc/stat path the sampler reads under its fsRoot. */
const PROC_STAT_FIXTURE_SUFFIX = '/proc/stat';
/** Mode of every directory a row creates: the user's own. */
const PRIVATE_DIRECTORY_MODE = 0o700;
/** Digits in a generated leaf's index, so the generated names sort as their indices do. */
const GENERATED_LEAF_INDEX_DIGITS = 3;
/** Full batches of leaves in a generated scan root (plus one leaf, so a last, partial batch exists too). */
const GENERATED_SCAN_BATCHES = 3;
const GENERATED_LEAF_MEMORY_BYTES = 1_000_000;
const HEAVIEST_GENERATED_LEAF_MEMORY_BYTES = 9_000_000;
/** Chunks in the file the multi-chunk read row reads (it is a little over this many). */
const MULTI_CHUNK_FILE_CHUNKS = 3;
/** What a failed sample publishes, apart from its two timestamps (in the order a snapshot lists its fields). */
const NO_DATA_SNAPSHOT_FIELDS = {
    cpuBusyPercent: null,
    cpuClusters: null,
    memory: null,
    swap: null,
    pressureAvg10: {cpu: null, memory: null, io: null},
    apps: null,
    isComplete: false,
};

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
 * Records every tick a sampler runs, through whichever path runs it (start(), a resume, the timer callback), so a
 * row can read the tick numbers and await each tick.
 *
 * @param {Sampler} sampler - The sampler.
 * @returns {Array<{tickNumber: number, tickRun: Promise<void>}>} Filled as ticks run, oldest first.
 */
function recordTickRuns(sampler) {
    const tickRuns = [];
    const runTickForReal = sampler.runTick.bind(sampler);
    sampler.runTick = tickNumber => {
        const tickRun = runTickForReal(tickNumber);
        tickRuns.push({tickNumber, tickRun});
        return tickRun;
    };
    return tickRuns;
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

test('sampler: swap comes from /proc/swaps, so zram holding more swap than orig_data_size shows no disk swap',
    async () => {
        // root-a is this laptop's case: zram0's Used is above its orig_data_size and /swap.img is idle. The old
        // formula (SwapTotal − SwapFree − Σ orig_data_size) put 0.1 GiB "on disk" with nothing on disk.
        const {sampler} = makeSampler('root-a');
        const snapshot = await sampler.sampleOnce();
        assertEqual([snapshot.swap, cardText(snapshot, null).swapValue], [
            {zramUsedBytes: FIXTURE_ZRAM_SWAP_USED_BYTES, zramRamBytes: FIXTURE_ZRAM_RAM_BYTES, diskBytes: 0},
            '1.5 GiB (0.4 in RAM)',
        ]);
    });

test('sampler: swap on disk is real disk Used, and a zram device that is not swap (zram1) adds no "in RAM"',
    async () => {
        // root-swap-disk: /dev/zram0 1 GiB used with 200 MiB of RAM, /swap.img 0.5 GiB used, and a zram1 that is
        // not in /proc/swaps whose 300 MiB of RAM must not count.
        const {sampler} = makeSampler('root-swap-disk');
        const snapshot = await sampler.sampleOnce();
        assertEqual([snapshot.swap, cardText(snapshot, null).swapValue], [
            {zramUsedBytes: 1_048_576 * BYTES_PER_KIB, zramRamBytes: 209_715_200, diskBytes: 524_288 * BYTES_PER_KIB},
            '1.0 GiB (0.2 in RAM) + 0.5 on disk',
        ]);
    });

test('sampler: an unreadable /proc/swaps is swap no data (logged), while memory stays', async () => {
    const {sampler, logged} = makeSampler('root-no-swaps');
    const snapshot = await sampler.sampleOnce();
    assertEqual([snapshot.swap, cardText(snapshot, null).swapValue, snapshot.memory !== null, snapshot.isComplete,
        logged.some(line => line.includes('proc/swaps'))], [null, 'no data', true, false, true]);
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

test('sampler: a scan turned off during its first file read is dropped and reads nothing after it', async () => {
    // The scan awaits more than once; its first file read (the root cgroup's cpu.stat) starts only after the
    // listing has settled. Once the scan is turned off, no leaf's files are read: that work would be thrown away.
    let isTurningScanOff = false;
    const readPathsAfterTurningOff = [];
    const {sampler} = makeSampler('root-a', {
        readTextFile: (path, ...readArguments) => {
            if (isTurningScanOff) {
                readPathsAfterTurningOff.push(path);
                sampler.setAppScanEnabled(false);
            }
            return readTextFile(path, ...readArguments);
        },
    });
    await sampler.initialize();
    isTurningScanOff = true;
    const scanResult = await sampler.scanAppsOnce();
    isTurningScanOff = false;
    const nextSnapshot = await sampler.sampleOnce();
    assertEqual([scanResult, nextSnapshot.apps, readPathsAfterTurningOff.map(path => GLib.path_get_basename(path))],
        [null, null, ['cpu.stat']]);
});

test('sampler: two Chrome scopes are one app (one group key, one name)', () => {
    const groups = ['app-com.google.Chrome-2.scope', 'app-com.google.Chrome-3.scope']
        .map(leafName => groupOfCgroup(`${USER_APP_SLICE}/${leafName}`, () => null));
    assertEqual([groups[0], groups[0].groupKey === groups[1].groupKey],
        [{groupKey: 'app:com.google.Chrome', name: 'Chrome'}, true]);
});

test('sampler: a cgroup that vanished mid-scan is skipped in both rankings and the scan succeeds', async () => {
    // Leaf CPU Δ 4.5 s of root Δ 12 s, so "kernel & other" tops CPU. Memory names real apps only: Chromium's
    // 4.0 GB tops Chrome 2×0.5, GNOME Shell 0.3 and docker 0.3, although 14.88 of the 20.48 GB used is
    // unattributed. Had herdr been kept, it would top both rankings (see the row above).
    const {ranking, logged} = await scanTwice('root-vanished');
    assertEqual([ranking, logged], [{
        topCpu: {name: KERNEL_AND_OTHER_LABEL, cpuPercent: 62.5},
        topMemory: {name: 'Chromium', memoryBytes: 4_000_000_000},
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

test('sampler: runTick samples first, scans only while enabled, and disabling drops the ranking', async () => {
    // The sample comes first, so tick 0's own snapshot cannot carry tick 0's scan yet; tick 1's does.
    const {sampler} = makeSampler('root-a');
    await sampler.initialize();
    sampler.setAppScanEnabled(false);
    await sampler.runTick(0);
    await sampler.runTick(1);
    const appsWhileDisabled = sampler.latestSnapshot.apps;
    sampler.setAppScanEnabled(true);
    await sampler.runTick(0);
    const appsInTheScanningTick = sampler.latestSnapshot.apps;
    await sampler.runTick(1);
    const appsInTheNextTick = sampler.latestSnapshot.apps;
    sampler.setAppScanEnabled(false);
    await sampler.runTick(2);
    assertEqual([appsWhileDisabled, appsInTheScanningTick, appsInTheNextTick !== null, sampler.latestSnapshot.apps],
        [null, null, true, null]);
});

test('sampler: a scan that throws is logged, drops the ranking, and never costs the tick its sample', async () => {
    let isNameLookupBroken = false;
    const {sampler, logged} = makeSampler('root-a', {
        resolveAppName: () => {
            if (isNameLookupBroken)
                throw new Error('name lookup exploded');
            return null;
        },
    });
    await sampler.initialize();
    await sampler.runTick(0);
    await sampler.runTick(1);
    const appsBeforeTheFailure = sampler.latestSnapshot.apps;
    isNameLookupBroken = true;
    const historyLengthBefore = sampler.cpuHistory.values().length;
    await sampler.runTick(APP_SCAN_EVERY_N_TICKS);
    const historyLengthAfterFailingTick = sampler.cpuHistory.values().length;
    await sampler.runTick(APP_SCAN_EVERY_N_TICKS + 1);
    assertEqual([appsBeforeTheFailure !== null, historyLengthAfterFailingTick - historyLengthBefore,
        sampler.latestSnapshot.apps, logged.length, logged[0]?.startsWith(LOG_PREFIX),
        logged[0]?.includes('name lookup exploded')], [true, 1, null, 1, true, true]);
});

test('sampler: a throwing sample publishes an all-null, incomplete snapshot and a gap in both histories', async () => {
    const clockLabels = [FIXTURE_CLOCK_LABEL, LATER_CLOCK_LABEL];
    const {sampler, clock, logged} = makeSampler('root-a', {clockLabel: () => clockLabels.shift()});
    await sampler.sampleOnce();
    // A ranking is on hand, so the no-data snapshot's apps: null is a choice, not an accident.
    const ranking = await sampler.scanAppsOnce();
    const published = [];
    sampler.addListener(snapshot => published.push(snapshot));
    clock.nowUsec += SAMPLE_SPACING_USEC;
    Object.defineProperty(sampler, 'fsRoot', {
        get() {
            throw new Error('fsRoot exploded');
        },
    });
    const snapshot = await sampler.sampleOnce();
    const {takenAtUsec, takenAtClockLabel, ...dataFields} = snapshot;
    assertEqual([ranking !== null, dataFields, takenAtUsec, takenAtClockLabel, published.length,
        published[0] === snapshot, sampler.cpuHistory.values(), sampler.memoryHistory.values(),
        sampler.lastGoodClockLabel, logged.length, logged[0]?.includes('fsRoot exploded')],
    [true, NO_DATA_SNAPSHOT_FIELDS, SAMPLE_SPACING_USEC, LATER_CLOCK_LABEL, 1, true, [null, null], [0.625, null],
        FIXTURE_CLOCK_LABEL, 1, true]);
});

test('sampler: a sample whose clock label throws publishes no label, and "no data since" keeps the last good one',
    async () => {
        let isClockBroken = false;
        const {sampler} = makeSampler('root-a', {
            clockLabel: () => {
                if (isClockBroken)
                    throw new Error('clock exploded');
                return FIXTURE_CLOCK_LABEL;
            },
        });
        await sampler.sampleOnce();
        isClockBroken = true;
        const snapshot = await sampler.sampleOnce();
        assertEqual([snapshot.takenAtClockLabel, snapshot.isComplete, snapshot.memory, sampler.lastGoodClockLabel],
            [null, false, null, FIXTURE_CLOCK_LABEL]);
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

test('sampler: the timer callback never throws; a tick whose sample throws publishes no data, timer continues',
    async () => {
        await withTimerSpy(async spy => {
            const {sampler, logged} = makeSampler('root-a', {
                sampleIntervalSeconds: QUIET_INTERVAL_SECONDS,
                clockLabel: () => {
                    throw new Error('clock exploded');
                },
            });
            const published = [];
            sampler.addListener(snapshot => published.push(snapshot));
            sampler.start();
            // start() runs the first tick itself; let it finish, so the callback's own tick is not skipped as
            // one in flight.
            await waitMs(TICK_FAILURE_SETTLE_MS);
            const publishedByStart = published.length;
            const callbackResult = spy.added[0].callback();
            await waitMs(TICK_FAILURE_SETTLE_MS);
            const isStillAttached = isSourceAttached(spy.added[0].sourceId);
            sampler.destroy();
            // How many lines the two failures log depends on their stacks (the rate limit keys on the whole
            // message, and its own row pins it); here every line must be this failure, prefixed.
            const isEveryLineThisFailure = logged.length > 0 &&
                logged.every(line => line.startsWith(LOG_PREFIX) && line.includes('clock exploded'));
            assertEqual([callbackResult, isStillAttached, publishedByStart, published.length,
                published[1]?.isComplete, published[1]?.memory, isEveryLineThisFailure],
            [GLib.SOURCE_CONTINUE, true, 1, 2, false, null, true]);
        });
    });

test('sampler: start() samples at once, so memory shows before the first interval and CPU after it', async () => {
    await withTimerSpy(async spy => {
        const {sampler} = makeSampler('root-a', {sampleIntervalSeconds: QUIET_INTERVAL_SECONDS});
        const published = [];
        sampler.addListener(snapshot => published.push(snapshot));
        sampler.start();
        await waitMs(IN_FLIGHT_SETTLE_MS);
        const [firstSnapshot] = published;
        sampler.destroy();
        sampler.start();
        await waitMs(IN_FLIGHT_SETTLE_MS);
        // One sample from start(), none from the 60 s timer, and none from a start() after destroy().
        assertEqual([published.length, firstSnapshot?.memory !== null, firstSnapshot?.cpuBusyPercent, spy.added.length],
            [1, true, null, 1]);
    });
});

test('sampler: resuming from a pause samples at once; start() while paused samples nothing', async () => {
    await withTimerSpy(async () => {
        const {sampler} = makeSampler('root-a', {sampleIntervalSeconds: QUIET_INTERVAL_SECONDS});
        let listenerCalls = 0;
        sampler.addListener(() => listenerCalls++);
        sampler.setPaused(true);
        sampler.start();
        await waitMs(IN_FLIGHT_SETTLE_MS);
        const callsWhilePaused = listenerCalls;
        sampler.setPaused(false);
        await waitMs(IN_FLIGHT_SETTLE_MS);
        sampler.destroy();
        assertEqual([callsWhilePaused, listenerCalls], [0, 1]);
    });
});

test('sampler: start() while a sample is in flight adds no second one (the in-flight guard holds)', async () => {
    await withTimerSpy(async () => {
        const {sampler} = makeSampler('root-a', {sampleIntervalSeconds: QUIET_INTERVAL_SECONDS});
        let listenerCalls = 0;
        sampler.addListener(() => listenerCalls++);
        const pendingSample = sampler.sampleOnce();
        sampler.start();
        await pendingSample;
        await waitMs(IN_FLIGHT_SETTLE_MS);
        sampler.destroy();
        assertEqual([listenerCalls, sampler.cpuHistory.values().length], [1, 1]);
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

test('sampler: an injected logger keeps its rate limit across samplers, one per enable (every blank and lock)',
    async () => {
        const clock = {nowUsec: 0};
        const written = [];
        const errorLog = new RateLimitedLogger({nowUsec: () => clock.nowUsec, write: line => written.push(line)});
        for (const _enable of [1, 2]) {
            const sampler = new Sampler({fsRoot: fixtureRoot('root-no-stat'), nowUsec: () => clock.nowUsec,
                clockLabel: () => FIXTURE_CLOCK_LABEL, errorLog});
            await sampler.sampleOnce();
            sampler.destroy();
            clock.nowUsec += SAMPLE_SPACING_USEC;
        }
        // The same failure (proc/stat unreadable) from two samplers inside 10 minutes is one line.
        assertEqual([written.length, written[0]?.startsWith(LOG_PREFIX), written[0]?.includes('proc/stat')],
            [1, true, true]);
    });

/**
 * Writes a file, making its directory first (tests may block).
 *
 * @param {string} directoryPath - Absolute directory path.
 * @param {string} fileName - File name inside it.
 * @param {string} contents - UTF-8 text.
 * @returns {string} The file's path.
 */
function writeFixtureFile(directoryPath, fileName, contents) {
    GLib.mkdir_with_parents(directoryPath, PRIVATE_DIRECTORY_MODE);
    const filePath = GLib.build_filenamev([directoryPath, fileName]);
    GLib.file_set_contents(filePath, contents);
    return filePath;
}

/**
 * Deletes a directory tree made by a row (tests may block).
 *
 * @param {string} path - The tree's root.
 * @returns {void}
 */
function removeTree(path) {
    const file = Gio.File.new_for_path(path);
    if (file.query_file_type(Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null) === Gio.FileType.DIRECTORY) {
        const enumerator = file.enumerate_children('standard::name', Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        for (let info = enumerator.next_file(null); info !== null; info = enumerator.next_file(null))
            removeTree(GLib.build_filenamev([path, info.get_name()]));
        enumerator.close(null);
    }
    file.delete(null);
}

/**
 * Name of the generated cgroup leaf at an index, zero-padded so the names sort as the indices do.
 *
 * @param {number} leafIndex - The leaf's index.
 * @returns {string} For example 'generated-007.service'.
 */
const generatedLeafName = leafIndex =>
    `generated-${String(leafIndex).padStart(GENERATED_LEAF_INDEX_DIGITS, '0')}.service`;

/**
 * Builds a fixture root in a new temporary directory whose system.slice holds leafCount service leaves (a cpu.stat
 * and a memory.current each); the last leaf holds the most memory, so a ranking that names it read every batch.
 *
 * @param {number} leafCount - How many leaves.
 * @returns {{rootPath: string, cgroupRootPath: string, heaviestLeafName: string}} The tree, and the name the
 *     ranking gives its heaviest leaf.
 */
function makeGeneratedCgroupRoot(leafCount) {
    const rootPath = GLib.dir_make_tmp('resource-pulse-scan-XXXXXX');
    const cgroupRootPath = GLib.build_filenamev([rootPath, 'sys', 'fs', 'cgroup']);
    writeFixtureFile(cgroupRootPath, 'cpu.stat', 'usage_usec 1000000\n');
    for (let leafIndex = 0; leafIndex < leafCount; leafIndex++) {
        const leafPath = GLib.build_filenamev([cgroupRootPath, 'system.slice', generatedLeafName(leafIndex)]);
        const isHeaviest = leafIndex === leafCount - 1;
        const memoryBytes = isHeaviest ? HEAVIEST_GENERATED_LEAF_MEMORY_BYTES : GENERATED_LEAF_MEMORY_BYTES;
        writeFixtureFile(leafPath, 'cpu.stat', `usage_usec ${leafIndex}\n`);
        writeFixtureFile(leafPath, 'memory.current', `${memoryBytes}\n`);
    }
    const heaviestLeafName = generatedLeafName(leafCount - 1).replace(/\.service$/, '');
    return {rootPath, cgroupRootPath, heaviestLeafName};
}

/**
 * Wraps the real reader to record the priorities it is asked for and the most cgroup leaves with a read in flight
 * at once (a read of the cgroup root's own cpu.stat is not a leaf's).
 *
 * @param {string} cgroupRootPath - The cgroup root, whose own files are not a leaf's.
 * @param {(leafDirectoryPath: string, distinctLeafCount: number) => void} [onLeafReadStart] - Called as each read
 *     of a leaf starts, with how many distinct leaves have started so far.
 * @returns {{readTextFile: Function, record: {priorities: Set<number>, maxLeavesInFlight: number}}} The reader
 *     and what it saw.
 */
function makeLeafTrackingReader(cgroupRootPath, onLeafReadStart = () => {}) {
    const record = {priorities: new Set(), maxLeavesInFlight: 0};
    const inFlightReadsByLeaf = new Map();
    const startedLeaves = new Set();
    const trackingReadTextFile = async (path, priority, cancellable) => {
        record.priorities.add(priority);
        const leafDirectoryPath = GLib.path_get_dirname(path);
        if (leafDirectoryPath === cgroupRootPath)
            return readTextFile(path, priority, cancellable);
        inFlightReadsByLeaf.set(leafDirectoryPath, (inFlightReadsByLeaf.get(leafDirectoryPath) ?? 0) + 1);
        record.maxLeavesInFlight = Math.max(record.maxLeavesInFlight, inFlightReadsByLeaf.size);
        startedLeaves.add(leafDirectoryPath);
        onLeafReadStart(leafDirectoryPath, startedLeaves.size);
        try {
            return await readTextFile(path, priority, cancellable);
        } finally {
            const remainingReads = inFlightReadsByLeaf.get(leafDirectoryPath) - 1;
            if (remainingReads === 0)
                inFlightReadsByLeaf.delete(leafDirectoryPath);
            else
                inFlightReadsByLeaf.set(leafDirectoryPath, remainingReads);
        }
    };
    return {readTextFile: trackingReadTextFile, record};
}

/**
 * Runs a body while Gio's file-open, stream-read and stream-close calls are spied on (each still runs for real).
 *
 * @param {(spy: {openPriorities: number[], readPriorities: number[], closePriorities: number[],
 *     streams: Gio.InputStream[]}) => Promise<void>} body - The test body.
 * @param {(inputStream: Gio.InputStream, readArguments: Array) => (Promise|null)} [replaceRead] - Returns a promise
 *     to use instead of a real read_bytes_async, or null to read for real.
 * @returns {Promise<void>} Settles when the body has, with the originals restored.
 */
async function withStreamSpy(body, replaceRead = () => null) {
    const originalReadAsync = Gio.File.prototype.read_async;
    const originalReadBytesAsync = Gio.InputStream.prototype.read_bytes_async;
    const originalCloseAsync = Gio.InputStream.prototype.close_async;
    const spy = {openPriorities: [], readPriorities: [], closePriorities: [], streams: []};
    Gio.File.prototype.read_async = function (priority, ...rest) {
        spy.openPriorities.push(priority);
        const pendingStream = originalReadAsync.call(this, priority, ...rest);
        pendingStream.then(inputStream => spy.streams.push(inputStream), () => {});
        return pendingStream;
    };
    Gio.InputStream.prototype.read_bytes_async = function (...readArguments) {
        spy.readPriorities.push(readArguments[1]);
        return replaceRead(this, readArguments) ?? originalReadBytesAsync.apply(this, readArguments);
    };
    Gio.InputStream.prototype.close_async = function (priority, ...rest) {
        spy.closePriorities.push(priority);
        return originalCloseAsync.call(this, priority, ...rest);
    };
    try {
        await body(spy);
    } finally {
        Gio.File.prototype.read_async = originalReadAsync;
        Gio.InputStream.prototype.read_bytes_async = originalReadBytesAsync;
        Gio.InputStream.prototype.close_async = originalCloseAsync;
    }
}

test('readTextFile reads a file of several chunks to EOF at the priority given (open, reads, close) and closes it',
    async () => {
        // One ASCII byte first, so two-byte characters straddle every chunk boundary: decoding chunk by chunk
        // would mangle them.
        const contents = `a${'é'.repeat(MULTI_CHUNK_FILE_CHUNKS * FILE_READ_CHUNK_BYTES / 2)}`;
        const directoryPath = GLib.dir_make_tmp('resource-pulse-read-XXXXXX');
        const filePath = writeFixtureFile(directoryPath, 'multi-chunk.txt', contents);
        try {
            await withStreamSpy(async spy => {
                const text = await readTextFile(filePath, GLib.PRIORITY_LOW, null);
                const priorities = [...spy.openPriorities, ...spy.readPriorities, ...spy.closePriorities];
                assertEqual([text === contents, spy.readPriorities.length > MULTI_CHUNK_FILE_CHUNKS,
                    [...new Set(priorities)], spy.closePriorities.length,
                    spy.streams.map(inputStream => inputStream.is_closed())],
                [true, true, [GLib.PRIORITY_LOW], 1, [true]]);
            });
        } finally {
            removeTree(directoryPath);
        }
    });

test('readTextFile closes the stream when a read after the open fails, and rejects with that failure', async () => {
    const directoryPath = GLib.dir_make_tmp('resource-pulse-read-XXXXXX');
    const filePath = writeFixtureFile(directoryPath, 'small.txt', 'usage_usec 1\n');
    const readFailure = new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.FAILED, 'read exploded');
    try {
        await withStreamSpy(async spy => {
            const failureMessage = await readTextFile(filePath, GLib.PRIORITY_LOW, null)
                .then(() => 'resolved', error => error.message);
            assertEqual([failureMessage, spy.streams.map(inputStream => inputStream.is_closed())],
                ['read exploded', [true]]);
        }, () => Promise.reject(readFailure));
    } finally {
        removeTree(directoryPath);
    }
});

test('sampler: the app scan reads at PRIORITY_LOW, at most APP_SCAN_READ_BATCH_LEAVES leaves at once, and every leaf',
    async () => {
        const leafCount = GENERATED_SCAN_BATCHES * APP_SCAN_READ_BATCH_LEAVES + 1;
        const {rootPath, cgroupRootPath, heaviestLeafName} = makeGeneratedCgroupRoot(leafCount);
        try {
            const {readTextFile: trackingReadTextFile, record} = makeLeafTrackingReader(cgroupRootPath);
            const {sampler} = makeSampler('root-a', {fsRoot: rootPath, readTextFile: trackingReadTextFile});
            const ranking = await sampler.scanAppsOnce();
            sampler.destroy();
            assertEqual([[...record.priorities], record.maxLeavesInFlight, ranking?.topMemory],
                [[GLib.PRIORITY_LOW], APP_SCAN_READ_BATCH_LEAVES,
                    {name: heaviestLeafName, memoryBytes: HEAVIEST_GENERATED_LEAF_MEMORY_BYTES}]);
        } finally {
            removeTree(rootPath);
        }
    });

test('sampler: a scan turned off between two batches of leaf reads is dropped', async () => {
    const leafCount = GENERATED_SCAN_BATCHES * APP_SCAN_READ_BATCH_LEAVES + 1;
    const {rootPath, cgroupRootPath} = makeGeneratedCgroupRoot(leafCount);
    try {
        let sampler = null;
        const {readTextFile: trackingReadTextFile} = makeLeafTrackingReader(cgroupRootPath,
            (_leafDirectoryPath, distinctLeafCount) => {
                // The first read of the second batch: the first batch has settled by now.
                if (distinctLeafCount === APP_SCAN_READ_BATCH_LEAVES + 1)
                    sampler.setAppScanEnabled(false);
            });
        ({sampler} = makeSampler('root-a', {fsRoot: rootPath, readTextFile: trackingReadTextFile}));
        const scanResult = await sampler.scanAppsOnce();
        const nextSnapshot = await sampler.sampleOnce();
        sampler.destroy();
        assertEqual([scanResult, nextSnapshot.apps], [null, null]);
    } finally {
        removeTree(rootPath);
    }
});

test('sampler: runTick scans at tick 0, at the warm-up tick 1, then every APP_SCAN_EVERY_N_TICKS-th tick, no other',
    async () => {
        // A scan every tick would cost five times as much; a missing warm-up scan leaves "heaviest" without its
        // CPU half for about 12 s after every enable (see the next row).
        const {sampler, clock} = makeSampler('root-a');
        await sampler.initialize();
        const scannedTicks = [];
        let currentTick = null;
        const scanAppsOnceForReal = sampler.scanAppsOnce.bind(sampler);
        sampler.scanAppsOnce = () => {
            scannedTicks.push(currentTick);
            return scanAppsOnceForReal();
        };
        for (currentTick = 0; currentTick <= 2 * APP_SCAN_EVERY_N_TICKS + 1; currentTick++) {
            clock.nowUsec += SAMPLE_SPACING_USEC;
            await sampler.runTick(currentTick);
        }
        sampler.destroy();
        assertEqual(scannedTicks, [0, 1, APP_SCAN_EVERY_N_TICKS, 2 * APP_SCAN_EVERY_N_TICKS]);
    });

test('sampler: after enable, a resume and the scan turned back on, "heaviest" has its CPU half again by tick 2',
    async () => {
        // Each of the three restarts drops the app baseline and restarts the tick count at 0, so tick 0's scan is
        // only a baseline; the warm-up scan at tick 1 gives the CPU delta that tick 2's snapshot carries.
        await withTimerSpy(async spy => {
            const {sampler, clock} = makeSampler('root-a', {sampleIntervalSeconds: QUIET_INTERVAL_SECONDS});
            await sampler.initialize();
            const tickRuns = recordTickRuns(sampler);
            /** @returns {Promise<void>} Fires the timer's callback once and waits for the tick it runs. */
            const fireTimer = async () => {
                clock.nowUsec += SAMPLE_SPACING_USEC;
                spy.added.at(-1).callback();
                await tickRuns.at(-1).tickRun;
            };
            /**
             * @param {number} firstTickIndex - Index in tickRuns of the restart's first tick.
             * @returns {{ticks: number[], hasCpuHalf: boolean}} The restart's tick numbers and whether tick 2's
             *     snapshot names a top app by CPU.
             */
            const describeRestart = firstTickIndex => ({
                ticks: tickRuns.slice(firstTickIndex).map(tickRun => tickRun.tickNumber),
                hasCpuHalf: (sampler.latestSnapshot.apps?.topCpu ?? null) !== null,
            });

            clock.nowUsec += SAMPLE_SPACING_USEC;
            sampler.start();
            await tickRuns.at(-1).tickRun;
            await fireTimer();
            await fireTimer();
            const afterEnable = describeRestart(0);

            let firstTickIndex = tickRuns.length;
            sampler.setPaused(true);
            clock.nowUsec += SAMPLE_SPACING_USEC;
            sampler.setPaused(false);
            await tickRuns.at(-1).tickRun;
            await fireTimer();
            await fireTimer();
            const afterResume = describeRestart(firstTickIndex);

            firstTickIndex = tickRuns.length;
            sampler.setAppScanEnabled(false);
            sampler.setAppScanEnabled(true);
            await fireTimer();
            await fireTimer();
            await fireTimer();
            const afterScanTurnedBackOn = describeRestart(firstTickIndex);
            sampler.destroy();

            const expectedRestart = {ticks: [0, 1, 2], hasCpuHalf: true};
            assertEqual([afterEnable, afterResume, afterScanTurnedBackOn],
                [expectedRestart, expectedRestart, expectedRestart]);
        });
    });

/**
 * A sampler on root-a whose /proc/stat read can be made to hang, driven through its own timer callback.
 *
 * @param {{added: Array<{callback: Function}>}} spy - withTimerSpy's spy.
 * @returns {object} The sampler, its clock, log and published snapshots, its tick runs, fireTimer() (one interval
 *     passing), setStatReadStuck(isStuck) for the reads that start next, releaseStuckRead() and statReadCount().
 */
function makeStuckStatSampler(spy) {
    let isStatReadStuck = false;
    let releaseStuckRead = null;
    let statReadCount = 0;
    const {sampler, clock, logged} = makeSampler('root-a', {
        sampleIntervalSeconds: QUIET_INTERVAL_SECONDS,
        readTextFile: (path, ...readArguments) => {
            if (!path.endsWith(PROC_STAT_FIXTURE_SUFFIX))
                return readTextFile(path, ...readArguments);
            statReadCount++;
            if (!isStatReadStuck)
                return readTextFile(path, ...readArguments);
            return new Promise(resolve => {
                releaseStuckRead = () => resolve(readTextFile(path, ...readArguments));
            });
        },
    });
    const published = [];
    sampler.addListener(snapshot => published.push(snapshot));
    return {
        sampler, clock, logged, published,
        tickRuns: recordTickRuns(sampler),
        fireTimer: () => {
            clock.nowUsec += SAMPLE_SPACING_USEC;
            spy.added.at(-1).callback();
        },
        setStatReadStuck: isStuck => {
            isStatReadStuck = isStuck;
        },
        releaseStuckRead: () => releaseStuckRead(),
        statReadCount: () => statReadCount,
    };
}

test('sampler: a sample stuck in flight for more than SAMPLE_STALL_TICKS intervals publishes no data once, queues no ' +
    'read, and its late result is dropped', async () => {
    await withTimerSpy(async spy => {
        const stuck = makeStuckStatSampler(spy);
        const {sampler, logged, published, tickRuns} = stuck;

        stuck.setStatReadStuck(true);
        sampler.start();
        for (let interval = 0; interval < SAMPLE_STALL_TICKS; interval++)
            stuck.fireTimer();
        const publishedWithinStallTicks = published.length;
        stuck.fireTimer();
        stuck.fireTimer();
        stuck.fireTimer();
        const publishedWhileStuck = published.map(snapshot => ({...snapshot, takenAtUsec: null}));
        const statReadsWhileStuck = stuck.statReadCount();
        const historiesWhileStuck = [sampler.cpuHistory.values(), sampler.memoryHistory.values()];

        stuck.setStatReadStuck(false);
        stuck.releaseStuckRead();
        await tickRuns[0].tickRun;
        const publishedAfterLateResult = published.length;
        // Against root-a's /proc/stat as a baseline, root-b's is 60% busy: a kept late result would show it.
        sampler.fsRoot = fixtureRoot('root-b');
        stuck.fireTimer();
        await tickRuns.at(-1).tickRun;
        const nextSnapshot = published.at(-1);
        sampler.destroy();

        const stallLines = logged.filter(line => line.includes('stalled'));
        assertEqual([publishedWithinStallTicks, publishedWhileStuck, statReadsWhileStuck, historiesWhileStuck,
            publishedAfterLateResult, nextSnapshot.memory !== null, nextSnapshot.cpuBusyPercent, stallLines.length,
            stallLines[0]?.startsWith(LOG_PREFIX)],
        [0, [{takenAtUsec: null, takenAtClockLabel: FIXTURE_CLOCK_LABEL, ...NO_DATA_SNAPSHOT_FIELDS}], 1,
            [[null], [null]], 1, true, null, 1, true]);
    });
});

test('sampler: once a stuck sample settles the stall count starts over, so a later stall is declared too', async () => {
    await withTimerSpy(async spy => {
        const stuck = makeStuckStatSampler(spy);
        const {sampler, published, tickRuns} = stuck;
        /** @returns {number} How many no-data snapshots have been published so far. */
        const noDataCount = () => published.filter(snapshot => !snapshot.isComplete).length;
        /**
         * Lets the stuck sample finish, and waits for its tick.
         *
         * @param {number} stuckTickIndex - Index in tickRuns of the tick whose sample is stuck.
         * @returns {Promise<void>} Settles when that tick has.
         */
        const releaseStuckTick = async stuckTickIndex => {
            stuck.setStatReadStuck(false);
            stuck.releaseStuckRead();
            await tickRuns[stuckTickIndex].tickRun;
        };

        stuck.setStatReadStuck(true);
        sampler.start();
        for (let interval = 0; interval <= SAMPLE_STALL_TICKS; interval++)
            stuck.fireTimer();
        const noDataAfterFirstStall = noDataCount();
        await releaseStuckTick(0);
        stuck.fireTimer();
        await tickRuns.at(-1).tickRun;
        const noDataAfterRecovery = noDataCount();

        stuck.setStatReadStuck(true);
        stuck.fireTimer();
        const secondStuckTickIndex = tickRuns.length - 1;
        for (let interval = 0; interval <= SAMPLE_STALL_TICKS; interval++)
            stuck.fireTimer();
        const noDataAfterSecondStall = noDataCount();
        await releaseStuckTick(secondStuckTickIndex);
        sampler.destroy();
        assertEqual([noDataAfterFirstStall, noDataAfterRecovery, noDataAfterSecondStall], [1, 1, 2]);
    });
});
