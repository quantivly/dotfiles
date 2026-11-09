// The service's ServiceSampler: synchronous reads against the fixture roots under fixtures/ (or an in-memory tree),
// on a fake clock. Every tick is driven by calling runTick, except the timer rows, which drive the GLib timer.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {
    ServiceSampler, groupOfCgroup, listSubdirectoryNames, readFileToEnd,
} from '../extensions/resource-pulse@dotfiles/service/sampler.js';
import {cardText} from '../extensions/resource-pulse@dotfiles/lib/format.js';
import {
    CARD_HISTORY_SAMPLES, ERROR_LOG_REPEAT_INTERVAL_USEC, KERNEL_LABEL, LOG_PREFIX, SHORT_JOBS_LABEL,
} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

const [TEST_FILE_PATH] = GLib.filename_from_uri(import.meta.url);
const FIXTURES_DIRECTORY = GLib.build_filenamev([GLib.path_get_dirname(TEST_FILE_PATH), 'fixtures']);
const APP_SCAN_SPACING_USEC = 6_000_000;
const SAMPLE_SPACING_USEC = 2_000_000;
const BYTES_PER_KIB = 1024;
const FIXTURE_MEMORY_USED_KIB = 20_000_000;
/** root-a's memory used fraction: 20,000,000 KiB of 32,000,000 KiB. */
const FIXTURE_MEMORY_USED_FRACTION = 0.625;
/** root-a's /dev/zram0 Used (1,600,000 KiB), above its orig_data_size of 1,536,000,000 B; /swap.img Used is 0. */
const FIXTURE_ZRAM_SWAP_USED_BYTES = 1_600_000 * BYTES_PER_KIB;
const FIXTURE_ZRAM_RAM_BYTES = 400_000_000;
/** root-swap-disk's zram0 mm_stat mem_used_total: the only zram device its /proc/swaps lists. */
const SWAP_DISK_ZRAM0_RAM_BYTES = 209_715_200;
const FIXTURE_CLOCK_LABEL = '14:02';
const LATER_CLOCK_LABEL = '14:04';
const TIMER_INTERVAL_SECONDS = 1;
const TIMER_RUN_MS = 2500;
const AFTER_STOP_MS = 1500;
/** start()'s own tick plus at least one firing of a real 1 s timer within TIMER_RUN_MS. */
const MIN_TICKS_WHILE_TIMER_RUNS = 2;
/** An interval long enough that a real firing never lands inside a row that drives the callback itself. */
const QUIET_INTERVAL_SECONDS = 60;
const USER_SERVICE_PATH = 'user.slice/user-1000.slice/user@1000.service';
const APP_SLICE = `${USER_SERVICE_PATH}/app.slice`;
const SESSION_SLICE = `${USER_SERVICE_PATH}/session.slice`;
const BACKGROUND_SLICE = `${USER_SERVICE_PATH}/background.slice`;
const SYSTEM_SLICE = 'system.slice';
const SCANNED_PARENT_PATHS = [APP_SLICE, SESSION_SLICE, BACKGROUND_SLICE, SYSTEM_SLICE];
const EDITOR_LEAF = `${APP_SLICE}/app-org.example.Editor-1.scope`;
const BUILDER_LEAF = `${APP_SLICE}/app-org.example.Builder-7.scope`;
const SHELL_LEAF = `${SESSION_SLICE}/org.gnome.Shell@ubuntu.service`;
const DAEMON_LEAF = `${SYSTEM_SLICE}/example-daemon.service`;
/** The end of the root cgroup's cpu.stat path: read once per app scan, so a read of it marks a scan. */
const ROOT_CGROUP_CPU_STAT_SUFFIX = '/sys/fs/cgroup/cpu.stat';
const CGROUP_ROOT_RELATIVE_PATH = 'sys/fs/cgroup';
/** The root cgroup's key in a counters object: its path relative to the cgroup root. */
const ROOT_CGROUP_KEY = '';
const BLOCK_DEVICES_SUFFIX = '/sys/block';
/** Linux's errno for "No such device": what reading a removed kernfs (cgroup) file returns. */
const ENODEV_ERRNO = 19;
const HERDR_LEAF_NAME = 'herdr-server.service';
const DOCKER_LEAF_NAME = 'docker-abc.scope';
/** The tick of the first interval scan with no watch held: the warm-up at tick 1, then 30 ticks (60 s). */
const FIRST_UNWATCHED_INTERVAL_SCAN_TICK = 31;
/** The last tick makeSamplerPastItsWarmUp runs: ticks 0 (first scan), 1 (warm-up scan), 2 and 3 (no scan). */
const WARM_UP_SETUP_LAST_TICK = 3;
/** Where the in-memory tree pretends to live; nothing is ever read from there. */
const FAKE_ROOT_PATH = '/resource-pulse-fake-root';
/**
 * root-a's files that initialize() and the fast tick read, copied into an in-memory tree so it initializes cleanly and
 * its ticks read complete samples.
 */
const SAMPLE_FIXTURE_FILES = [
    'proc/stat', 'proc/meminfo', 'proc/swaps', 'proc/pressure/cpu', 'proc/pressure/memory', 'proc/pressure/io',
    'proc/self/status', 'sys/block/zram0/mm_stat', 'sys/devices/cpu_core/cpus', 'sys/devices/cpu_atom/cpus',
];
const LEAF_MEMORY_BYTES = 1_000_000;
/** Counters of the first of two scans in the in-memory tree; the second adds a scenario's deltas. */
const FIRST_SCAN_COUNTERS_USEC = {
    [ROOT_CGROUP_KEY]: 10_000_000,
    [APP_SLICE]: 1_000_000, [SESSION_SLICE]: 1_000_000, [BACKGROUND_SLICE]: 1_000_000, [SYSTEM_SLICE]: 1_000_000,
    [EDITOR_LEAF]: 500_000, [SHELL_LEAF]: 500_000, [DAEMON_LEAF]: 500_000,
};
/**
 * What each parent and leaf spends between the two scans (2 s on 2 CPUs: 4,000,000 µs is the whole machine). The
 * parents spend 1,000,000 in all, 400,000 of it beyond their leaves: 100,000 in app.slice, 100,000 in a
 * background.slice with no leaf, and 200,000 in system.slice. That is short jobs at 10%.
 */
const STEADY_DELTAS_USEC = {
    [APP_SLICE]: 400_000, [EDITOR_LEAF]: 300_000,
    [SESSION_SLICE]: 200_000, [SHELL_LEAF]: 200_000,
    [BACKGROUND_SLICE]: 100_000,
    [SYSTEM_SLICE]: 300_000, [DAEMON_LEAF]: 100_000,
};
/** A new app leaf's whole usage, and what its parent spends with it: Editor 300,000, Builder this, short 100,000. */
const BUILDER_USAGE_USEC = 1_500_000;
const APP_SLICE_DELTA_WITH_BUILDER_USEC = 1_900_000;
/** Generated leaves whose cpu.stat cannot be read: far more than one journal line each could be allowed. */
const FAILING_LEAF_COUNT = 109;
const GENERATED_LEAF_INDEX_DIGITS = 3;
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
 * Creates a ServiceSampler on a fake clock that records what it logs, with no name lookup and no garbage
 * collection (a full collection per scan would only slow the rows).
 *
 * @param {string} fsRoot - The root it reads under.
 * @param {object} [overrides] - Constructor options replacing the test defaults.
 * @returns {{sampler: ServiceSampler, clock: {nowUsec: number}, logged: string[]}} The sampler and its spies.
 */
function makeSamplerAt(fsRoot, overrides = {}) {
    const clock = {nowUsec: 0};
    const logged = [];
    const sampler = new ServiceSampler({
        fsRoot,
        nowUsec: () => clock.nowUsec,
        clockLabel: () => FIXTURE_CLOCK_LABEL,
        resolveAppName: () => null,
        collectGarbage: () => {},
        logWriter: line => logged.push(line),
        ...overrides,
    });
    return {sampler, clock, logged};
}

/**
 * Creates a ServiceSampler on a fixture root (see makeSamplerAt).
 *
 * @param {string} rootName - The fixture root to start from.
 * @param {object} [overrides] - Constructor options replacing the test defaults.
 * @returns {{sampler: ServiceSampler, clock: {nowUsec: number}, logged: string[]}} The sampler and its spies.
 */
function makeSampler(rootName, overrides = {}) {
    return makeSamplerAt(fixtureRoot(rootName), overrides);
}

/**
 * Creates a ServiceSampler that reads an in-memory tree (see makeSamplerAt).
 *
 * @param {object} tree - makeFakeFileTree's tree.
 * @param {object} [overrides] - Constructor options replacing the test defaults.
 * @returns {{sampler: ServiceSampler, clock: {nowUsec: number}, logged: string[]}} The sampler and its spies.
 */
function makeTreeSampler(tree, overrides = {}) {
    return makeSamplerAt(tree.rootPath,
        {readFile: tree.readFile, listDirectoryNames: tree.listDirectoryNames, ...overrides});
}

/**
 * Ticks root-a and then root-b, two seconds apart.
 *
 * @param {ServiceSampler} sampler - An initialized sampler.
 * @param {{nowUsec: number}} clock - Its fake clock.
 * @returns {object} The second snapshot.
 */
function tickRootAThenRootB(sampler, clock) {
    sampler.fsRoot = fixtureRoot('root-a');
    sampler.runTick(0);
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.fsRoot = fixtureRoot('root-b');
    sampler.runTick(1);
    return sampler.latestSnapshot;
}

/**
 * Runs two app scans six seconds apart through the cadence: the first tick's scan on root-a, then the warm-up
 * tick's on the given root.
 *
 * @param {string} secondRootName - The root of the second scan.
 * @returns {{ranking: object, logged: string[]}} The second tick's ranking and what was logged.
 */
function scanTwice(secondRootName) {
    const {sampler, clock, logged} = makeSampler('root-a');
    sampler.initialize();
    sampler.runTick(0);
    clock.nowUsec += APP_SCAN_SPACING_USEC;
    sampler.fsRoot = fixtureRoot(secondRootName);
    sampler.runTick(1);
    const ranking = sampler.latestSnapshot.apps;
    sampler.destroy();
    return {ranking, logged};
}

/**
 * Wraps the real reader to call back whenever the root cgroup's cpu.stat is read, which happens once per app scan.
 *
 * @param {() => void} onAppScan - Called as a scan reads the root cgroup.
 * @returns {(path: string) => string} The reader.
 */
function makeScanSpottingReader(onAppScan) {
    return path => {
        if (path.endsWith(ROOT_CGROUP_CPU_STAT_SUFFIX))
            onAppScan();
        return readFileToEnd(path);
    };
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
 * @param {(spy: {added: Array<{sourceId: number, callback: Function}>, removed: number[]}) => (void|Promise<void>)}
 *     body - The test body.
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

/**
 * Builds Gio's "not found" error for a path, as a real read or listing of a missing path throws it.
 *
 * @param {string} path - The missing path.
 * @returns {GLib.Error} The error.
 */
function notFoundError(path) {
    return new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.NOT_FOUND,
        `Error opening ${path}: No such file or directory`);
}

/**
 * Builds Gio's "permission denied" error, with a message naming what was being done.
 *
 * @param {string} message - The error's message.
 * @returns {GLib.Error} The error.
 */
function permissionDeniedError(message) {
    return new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.PERMISSION_DENIED, message);
}

/**
 * An in-memory file tree under FAKE_ROOT_PATH, standing in for the sampler's readFile and listDirectoryNames.
 * A directory exists while a file lies somewhere under it; a path can be made to fail with any error.
 *
 * @returns {object} The tree: rootPath, readPaths (every path read, oldest first), writeFile(relativePath, text),
 *     failWith(relativePath, error), clearFailure(relativePath), readFile(path) and listDirectoryNames(path).
 */
function makeFakeFileTree() {
    const fileTextByPath = new Map();
    const failureByPath = new Map();
    const absolutePathOf = relativePath => GLib.build_filenamev([FAKE_ROOT_PATH, relativePath]);
    const tree = {
        rootPath: FAKE_ROOT_PATH,
        readPaths: [],
        writeFile: (relativePath, text) => fileTextByPath.set(absolutePathOf(relativePath), text),
        failWith: (relativePath, error) => failureByPath.set(absolutePathOf(relativePath), error),
        clearFailure: relativePath => failureByPath.delete(absolutePathOf(relativePath)),
        readFile: path => {
            tree.readPaths.push(path);
            if (failureByPath.has(path))
                throw failureByPath.get(path);
            if (!fileTextByPath.has(path))
                throw notFoundError(path);
            return fileTextByPath.get(path);
        },
        listDirectoryNames: directoryPath => {
            if (failureByPath.has(directoryPath))
                throw failureByPath.get(directoryPath);
            const directoryPrefix = `${directoryPath}/`;
            const descendantRelativePaths = [...fileTextByPath.keys()]
                .filter(path => path.startsWith(directoryPrefix))
                .map(path => path.slice(directoryPrefix.length));
            if (descendantRelativePaths.length === 0)
                throw notFoundError(directoryPath);
            const subdirectoryNames = descendantRelativePaths
                .filter(relativePath => relativePath.includes('/'))
                .map(relativePath => relativePath.split('/')[0]);
            return [...new Set(subdirectoryNames)].sort();
        },
    };
    return tree;
}

/**
 * An in-memory tree holding root-a's sample files (SAMPLE_FIXTURE_FILES), so its sampler logs nothing of its own.
 *
 * @returns {object} makeFakeFileTree's tree.
 */
function makeFakeTreeWithSampleFiles() {
    const tree = makeFakeFileTree();
    for (const relativePath of SAMPLE_FIXTURE_FILES)
        tree.writeFile(relativePath, readFileToEnd(GLib.build_filenamev([fixtureRoot('root-a'), relativePath])));
    return tree;
}

/**
 * Writes cgroup counters into an in-memory tree: a cpu.stat for each cgroup, and a memory.current for each one that
 * is neither the root nor a scanned parent (a leaf).
 *
 * @param {object} tree - makeFakeFileTree's tree.
 * @param {Object<string, number>} usageUsecByCgroup - usage_usec by cgroup path relative to the cgroup root.
 * @returns {void}
 */
function writeCgroupCounters(tree, usageUsecByCgroup) {
    for (const [cgroupPath, usageUsec] of Object.entries(usageUsecByCgroup)) {
        const cgroupDirectory = GLib.build_filenamev([CGROUP_ROOT_RELATIVE_PATH, cgroupPath]);
        tree.writeFile(GLib.build_filenamev([cgroupDirectory, 'cpu.stat']), `usage_usec ${usageUsec}\n`);
        const isLeaf = cgroupPath !== ROOT_CGROUP_KEY && !SCANNED_PARENT_PATHS.includes(cgroupPath);
        if (isLeaf)
            tree.writeFile(GLib.build_filenamev([cgroupDirectory, 'memory.current']), `${LEAF_MEMORY_BYTES}\n`);
    }
}

/**
 * Adds deltas to counters; a cgroup with no earlier count starts from 0 (a new leaf).
 *
 * @param {Object<string, number>} countersUsec - The earlier counters.
 * @param {Object<string, number>} deltasUsec - What each cgroup spent since.
 * @returns {Object<string, number>} The later counters.
 */
function countersAfter(countersUsec, deltasUsec) {
    const laterCountersUsec = {...countersUsec};
    for (const [cgroupPath, deltaUsec] of Object.entries(deltasUsec))
        laterCountersUsec[cgroupPath] = (laterCountersUsec[cgroupPath] ?? 0) + deltaUsec;
    return laterCountersUsec;
}

/**
 * Scans an in-memory tree twice, two seconds apart (the first tick, then the warm-up tick): FIRST_SCAN_COUNTERS_USEC,
 * then those plus the deltas.
 *
 * @param {Object<string, number>} deltasUsec - What each cgroup spends between the scans.
 * @param {object} [hooks] - Changes to the tree before each scan.
 * @param {(tree: object) => void} [hooks.beforeFirstScan] - Runs before the first.
 * @param {(tree: object) => void} [hooks.beforeSecondScan] - Runs before the second.
 * @returns {{topCpu: object|null, logged: string[]}} The second scan's top CPU entry, and what was logged.
 */
function topCpuAfterTwoScans(deltasUsec, {beforeFirstScan = () => {}, beforeSecondScan = () => {}} = {}) {
    const tree = makeFakeTreeWithSampleFiles();
    writeCgroupCounters(tree, FIRST_SCAN_COUNTERS_USEC);
    const {sampler, clock, logged} = makeTreeSampler(tree);
    sampler.initialize();
    beforeFirstScan(tree);
    sampler.runTick(0);
    clock.nowUsec += SAMPLE_SPACING_USEC;
    writeCgroupCounters(tree, countersAfter(FIRST_SCAN_COUNTERS_USEC, deltasUsec));
    beforeSecondScan(tree);
    sampler.runTick(1);
    const topCpu = sampler.latestSnapshot.apps?.topCpu ?? null;
    sampler.destroy();
    return {topCpu, logged};
}

/**
 * Runs ticks 0..lastTickNumber two seconds apart and records which ones scanned apps, and why.
 *
 * @param {boolean} isWatched - Whether a detail watch is held from before the first tick.
 * @param {number} lastTickNumber - The last tick to run.
 * @returns {Array<[number|null, string|null]>} [tick number, scan reason] of each scan; a scan outside a tick has
 *     tick number null.
 */
function scanTicksAndReasons(isWatched, lastTickNumber) {
    let currentTickNumber = null;
    let didScan = false;
    const {sampler, clock} = makeSampler('root-a', {
        readFile: makeScanSpottingReader(() => {
            didScan = true;
        }),
    });
    const scans = [];
    sampler.initialize();
    sampler.setDetailWatched(isWatched);
    if (didScan)
        scans.push([currentTickNumber, sampler.lastAppScanReason]);
    for (currentTickNumber = 0; currentTickNumber <= lastTickNumber; currentTickNumber++) {
        didScan = false;
        clock.nowUsec += SAMPLE_SPACING_USEC;
        sampler.runTick(currentTickNumber);
        if (didScan)
            scans.push([currentTickNumber, sampler.lastAppScanReason]);
    }
    sampler.destroy();
    return scans;
}

/**
 * A sampler on root-a that counts its app scans and records what it publishes, run through ticks 0 to 3: the first
 * scan, the warm-up scan, then two quiet ticks.
 *
 * @returns {object} The sampler, its clock, published ({snapshot, appendedHistory} per publish) and scanCount().
 */
function makeSamplerPastItsWarmUp() {
    let scanCount = 0;
    const {sampler, clock} = makeSampler('root-a', {
        readFile: makeScanSpottingReader(() => {
            scanCount++;
        }),
    });
    const published = [];
    sampler.addListener((snapshot, appendedHistory) => published.push({snapshot, appendedHistory}));
    sampler.initialize();
    for (let tickNumber = 0; tickNumber <= WARM_UP_SETUP_LAST_TICK; tickNumber++) {
        clock.nowUsec += SAMPLE_SPACING_USEC;
        sampler.runTick(tickNumber);
    }
    return {sampler, clock, published, scanCount: () => scanCount};
}

/**
 * Name of the generated cgroup leaf at an index, zero-padded so the names sort as the indices do.
 *
 * @param {number} leafIndex - The leaf's index.
 * @returns {string} For example 'generated-007.service'.
 */
const generatedLeafName = leafIndex =>
    `generated-${String(leafIndex).padStart(GENERATED_LEAF_INDEX_DIGITS, '0')}.service`;

test('service sampler: root-a then root-b gives CPU 60% with P 80 and E 40, complete', () => {
    const {sampler, clock} = makeSampler('root-a');
    sampler.initialize();
    const snapshot = tickRootAThenRootB(sampler, clock);
    // The history holds fractions, and the first sample is a gap (null), never 0.
    assertEqual([snapshot.cpuBusyPercent, snapshot.cpuClusters, snapshot.isComplete, sampler.cpuHistory.values()],
        [60, {performancePercent: 80, efficiencyPercent: 40}, true, [null, 0.6]]);
});

test('service sampler: the first tick is no data for CPU, never 0%, while memory is present', () => {
    const {sampler} = makeSampler('root-a');
    sampler.initialize();
    const labelBefore = sampler.lastGoodClockLabel;
    sampler.runTick(0);
    const snapshot = sampler.latestSnapshot;
    assertEqual([snapshot.cpuBusyPercent, snapshot.cpuClusters, snapshot.memory !== null, snapshot.isComplete,
        labelBefore, sampler.lastGoodClockLabel], [null, null, true, true, null, FIXTURE_CLOCK_LABEL]);
});

test('service sampler: memory used is MemTotal − MemAvailable in bytes, and its history is the used fraction', () => {
    const {sampler} = makeSampler('root-a');
    sampler.runTick(0);
    assertEqual([sampler.latestSnapshot.memory, sampler.memoryHistory.values()], [
        {usedBytes: FIXTURE_MEMORY_USED_KIB * BYTES_PER_KIB, totalBytes: 32_768_000_000},
        [FIXTURE_MEMORY_USED_FRACTION],
    ]);
});

test('service sampler: swap comes from /proc/swaps, so zram holding more swap than orig_data_size shows no disk swap',
    () => {
        const {sampler} = makeSampler('root-a');
        sampler.runTick(0);
        const snapshot = sampler.latestSnapshot;
        assertEqual([snapshot.swap, cardText(snapshot, null).swapValue], [
            {zramUsedBytes: FIXTURE_ZRAM_SWAP_USED_BYTES, zramRamBytes: FIXTURE_ZRAM_RAM_BYTES, diskBytes: 0},
            '1.5 GiB (0.4 in RAM)',
        ]);
    });

test('service sampler: swap on disk is real disk Used, and a zram device that is not swap (zram1) adds no "in RAM"',
    () => {
        // root-swap-disk: /dev/zram0 1 GiB used with 200 MiB of RAM, /swap.img 0.5 GiB used, and a zram1 that is
        // not in /proc/swaps whose 300 MiB of RAM must not count.
        const {sampler} = makeSampler('root-swap-disk');
        sampler.runTick(0);
        const snapshot = sampler.latestSnapshot;
        assertEqual([snapshot.swap, cardText(snapshot, null).swapValue], [
            {
                zramUsedBytes: 1_048_576 * BYTES_PER_KIB, zramRamBytes: SWAP_DISK_ZRAM0_RAM_BYTES,
                diskBytes: 524_288 * BYTES_PER_KIB,
            },
            '1.0 GiB (0.2 in RAM) + 0.5 on disk',
        ]);
    });

test('service sampler: only the zram devices /proc/swaps lists are read, and /sys/block is never listed', () => {
    const blockDevicePathsRead = [];
    const blockDeviceListings = [];
    const swapDiskRoot = fixtureRoot('root-swap-disk');
    const {sampler} = makeSampler('root-swap-disk', {
        readFile: path => {
            if (path.includes(`${BLOCK_DEVICES_SUFFIX}/`))
                blockDevicePathsRead.push(path.slice(swapDiskRoot.length + 1));
            return readFileToEnd(path);
        },
        listDirectoryNames: path => {
            if (path.endsWith(BLOCK_DEVICES_SUFFIX)) {
                blockDeviceListings.push(path);
                throw new Error('the fast tick must not list /sys/block');
            }
            return listSubdirectoryNames(path);
        },
    });
    sampler.runTick(0);
    assertEqual([blockDevicePathsRead, blockDeviceListings, sampler.latestSnapshot.swap?.zramRamBytes],
        [['sys/block/zram0/mm_stat'], [], SWAP_DISK_ZRAM0_RAM_BYTES]);
});

test('service sampler: an unreadable /proc/swaps is swap no data (logged), while memory stays', () => {
    const {sampler, logged} = makeSampler('root-no-swaps');
    sampler.runTick(0);
    const snapshot = sampler.latestSnapshot;
    assertEqual([snapshot.swap, cardText(snapshot, null).swapValue, snapshot.memory !== null, snapshot.isComplete,
        logged.some(line => line.includes('proc/swaps'))], [null, 'no data', true, false, true]);
});

test('service sampler: PSI cpu some avg10 is 12.5, memory and io 0', () => {
    const {sampler} = makeSampler('root-a');
    sampler.runTick(0);
    assertEqual(sampler.latestSnapshot.pressureAvg10, {cpu: 12.5, memory: 0, io: 0});
});

test('service sampler: without /proc/pressure every pressure is null, memory stays, the sample is incomplete', () => {
    const {sampler} = makeSampler('root-no-psi');
    sampler.runTick(0);
    const snapshot = sampler.latestSnapshot;
    assertEqual([snapshot.pressureAvg10, snapshot.memory !== null, snapshot.isComplete],
        [{cpu: null, memory: null, io: null}, true, false]);
});

test('service sampler: a missing /proc/stat nulls CPU and logs once per 10 minutes, prefixed', () => {
    const {sampler, clock, logged} = makeSampler('root-a');
    sampler.initialize();
    sampler.fsRoot = fixtureRoot('root-no-stat');
    sampler.runTick(0);
    const snapshot = sampler.latestSnapshot;
    const loggedAfterFirst = logged.length;
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.runTick(1);
    const loggedInsideInterval = logged.length;
    clock.nowUsec = ERROR_LOG_REPEAT_INTERVAL_USEC + 1;
    sampler.runTick(2);
    assertEqual([snapshot.cpuBusyPercent, snapshot.isComplete, loggedAfterFirst, loggedInsideInterval, logged.length,
        logged.every(message => message.startsWith(`${LOG_PREFIX} `))], [null, false, 1, 1, 2, true]);
});

test('service sampler: app scans root-a → root-b rank herdr agents top for CPU (50%) and memory (15 GB)', () => {
    const {ranking, logged} = scanTwice('root-b');
    assertEqual([ranking, logged], [{
        topCpu: {groupKey: 'unit:herdr-server', name: 'herdr agents', cpuPercent: 50},
        topMemory: {groupKey: 'unit:herdr-server', name: 'herdr agents', memoryBytes: 15_000_000_000},
    }, []]);
});

test('service sampler: the app scan skips units that never host an app (.mount, .socket), at both depths', () => {
    // boot.mount (5 MB, in system.slice) and example.socket (9 MB, in a sub-slice) would each top memory if scanned.
    const {sampler} = makeSampler('root-unit-types');
    sampler.runTick(0);
    assertEqual(sampler.latestSnapshot.apps.topMemory,
        {groupKey: 'unit:example-daemon', name: 'example-daemon', memoryBytes: 1_000_000});
});

test('service sampler: app CPU divides by the real time between scans, not the nominal interval', () => {
    // The second scan runs 12 s after the first: herdr's 6 s of CPU over 12 s × 2 CPUs is 25%, not 50%.
    const {sampler, clock} = makeSampler('root-a');
    sampler.initialize();
    sampler.runTick(0);
    clock.nowUsec += 2 * APP_SCAN_SPACING_USEC;
    sampler.fsRoot = fixtureRoot('root-b');
    sampler.runTick(1);
    assertEqual(sampler.latestSnapshot.apps.topCpu,
        {groupKey: 'unit:herdr-server', name: 'herdr agents', cpuPercent: 25});
});

test('service sampler: two Chrome scopes are one app (one group key, one name)', () => {
    const groups = ['app-com.google.Chrome-2.scope', 'app-com.google.Chrome-3.scope']
        .map(leafName => groupOfCgroup(`${APP_SLICE}/${leafName}`, () => null));
    assertEqual([groups[0], groups[0].groupKey === groups[1].groupKey],
        [{groupKey: 'app:com.google.Chrome', name: 'Chrome'}, true]);
});

test('service sampler: a cgroup that vanished mid-scan is skipped in both rankings and the scan succeeds', () => {
    // The fixtures carry no parent cpu.stat, so neither kernel nor short jobs is ranked and Chromium tops CPU too.
    // Memory names real apps only: Chromium's 4.0 GB tops Chrome 2×0.5, GNOME Shell 0.3 and docker 0.3. Had herdr
    // been kept, it would top both rankings (see the row above).
    const {ranking, logged} = scanTwice('root-vanished');
    assertEqual([ranking, logged], [{
        topCpu: {groupKey: 'app:org.chromium.Chromium', name: 'Chromium', cpuPercent: 16.666666666666664},
        topMemory: {groupKey: 'app:org.chromium.Chromium', name: 'Chromium', memoryBytes: 4_000_000_000},
    }, []]);
});

test('service sampler: a leaf whose file is gone with ENODEV (a scope that exited mid-read) is skipped silently, ' +
    'like ENOENT; any other read error is logged', () => {
    // A removed cgroup's open file reads as ENODEV, which GLib maps to its own code; build the error the way GLib
    // does, from the errno, so the row follows GLib's real mapping.
    const vanishedError = new GLib.Error(Gio.IOErrorEnum, Gio.io_error_from_errno(ENODEV_ERRNO),
        `Error reading from file: ${GLib.strerror(ENODEV_ERRNO)}`);
    const deniedError = permissionDeniedError('Error opening file: Permission denied');
    const {sampler, logged} = makeSampler('root-a', {
        readFile: path => {
            if (path.endsWith(`${HERDR_LEAF_NAME}/memory.current`))
                throw vanishedError;
            if (path.endsWith(`${DOCKER_LEAF_NAME}/cpu.stat`))
                throw deniedError;
            return readFileToEnd(path);
        },
    });
    sampler.initialize();
    sampler.runTick(0);
    // Without herdr's 15 GB, Chromium's 4 GB tops memory.
    assertEqual([sampler.latestSnapshot.apps?.topMemory?.name, logged],
        ['Chromium', [`${LOG_PREFIX} cannot read 1 cgroups, first: ${SYSTEM_SLICE}/${DOCKER_LEAF_NAME}: ` +
            'Error opening file: Permission denied']]);
});

test('service sampler: a leaf inside a sub-slice is found, and at or under 64 MiB it is uncorrected', () => {
    // The leaf sits in system.slice/system-example.slice/, so a scan that does not descend into a sub-slice finds
    // nothing. Its memory.stat says all 1,000,000 bytes are page cache; reading it would rank it at 0 bytes.
    const {sampler} = makeSampler('root-small-leaf');
    sampler.initialize();
    sampler.runTick(0);
    assertEqual(sampler.latestSnapshot.apps.topMemory,
        {groupKey: 'unit:example-tool', name: 'example-tool', memoryBytes: 1_000_000});
});

test('service sampler: the app scan reads cpu.stat of the root, of app, session and background slices under ' +
    'user@<uid>.service and of system.slice, and of each leaf', () => {
    const tree = makeFakeTreeWithSampleFiles();
    writeCgroupCounters(tree, FIRST_SCAN_COUNTERS_USEC);
    const {sampler} = makeTreeSampler(tree);
    sampler.initialize();
    sampler.runTick(0);
    const cgroupRootPrefix = `${FAKE_ROOT_PATH}/${CGROUP_ROOT_RELATIVE_PATH}/`;
    const cpuStatPathsRead = tree.readPaths
        .filter(path => path.startsWith(cgroupRootPrefix) && path.endsWith('/cpu.stat'))
        .map(path => path.slice(cgroupRootPrefix.length))
        .sort();
    const expectedCpuStatPaths = Object.keys(FIRST_SCAN_COUNTERS_USEC)
        .map(cgroupPath => GLib.build_filenamev([cgroupPath, 'cpu.stat']))
        .sort();
    assertEqual(cpuStatPathsRead, expectedCpuStatPaths);
});

test('service sampler: kernel (the root beyond its scanned parents) and short jobs (the parents beyond their ' +
    'leaves) each top CPU when theirs is the biggest share', () => {
    // The parents spend 1,000,000 µs (STEADY_DELTAS_USEC). A root delta of 3,000,000 leaves kernel 2,000,000 (50%);
    // one of 1,100,000 leaves kernel 100,000 (2.5%), and short jobs' 400,000 (10%) tops Editor's 300,000 (7.5%).
    const kernelHeavy = topCpuAfterTwoScans({...STEADY_DELTAS_USEC, [ROOT_CGROUP_KEY]: 3_000_000});
    const shortJobsHeavy = topCpuAfterTwoScans({...STEADY_DELTAS_USEC, [ROOT_CGROUP_KEY]: 1_100_000});
    assertEqual([kernelHeavy.topCpu, shortJobsHeavy.topCpu, kernelHeavy.logged, shortJobsHeavy.logged], [
        {groupKey: 'pseudo:kernel', name: KERNEL_LABEL, cpuPercent: 50},
        {groupKey: 'pseudo:short-jobs', name: SHORT_JOBS_LABEL, cpuPercent: 10},
        [], [],
    ]);
});

test('service sampler: a new leaf counts its whole usage when its parent was listed in the previous scan', () => {
    // Builder appears between the scans with 1,500,000 µs (37.5%); its parent's previous listing proves it is new.
    const {topCpu} = topCpuAfterTwoScans({
        ...STEADY_DELTAS_USEC, [APP_SLICE]: APP_SLICE_DELTA_WITH_BUILDER_USEC, [BUILDER_LEAF]: BUILDER_USAGE_USEC,
        [ROOT_CGROUP_KEY]: 2_600_000,
    });
    assertEqual(topCpu, {groupKey: 'app:org.example.Builder', name: 'Builder', cpuPercent: 37.5});
});

test('service sampler: a new leaf whose parent could not be listed in the previous scan is skipped, so its CPU is ' +
    'counted as short jobs, and the failed listing is logged', () => {
    // Editor and Builder are both unlisted in the first scan, so neither can prove itself new: app.slice's whole
    // 1,900,000 µs, plus the other parents' 300,000 beyond their leaves, is short jobs (2,200,000 of 4,000,000).
    const listingError = permissionDeniedError('Error opening directory: Permission denied');
    const {topCpu, logged} = topCpuAfterTwoScans({
        ...STEADY_DELTAS_USEC, [APP_SLICE]: APP_SLICE_DELTA_WITH_BUILDER_USEC, [BUILDER_LEAF]: BUILDER_USAGE_USEC,
        [ROOT_CGROUP_KEY]: 2_600_000,
    }, {
        beforeFirstScan: tree => tree.failWith(GLib.build_filenamev([CGROUP_ROOT_RELATIVE_PATH, APP_SLICE]),
            listingError),
        beforeSecondScan: tree => tree.clearFailure(GLib.build_filenamev([CGROUP_ROOT_RELATIVE_PATH, APP_SLICE])),
    });
    assertEqual([topCpu?.name, topCpu?.cpuPercent, logged], [SHORT_JOBS_LABEL, 2_200_000 / 4_000_000 * 100,
        [`${LOG_PREFIX} cannot read 1 cgroups, first: ${APP_SLICE}: Error opening directory: Permission denied`]]);
});

test('service sampler: a scan in which a parent cannot be listed ranks neither kernel nor short jobs', () => {
    // Its leaves are unknown, so its whole delta would read as short jobs (here 700,000 µs, 17.5%) and top the
    // ranking. Withheld, GNOME Shell's 200,000 (5%) tops it.
    const listingError = permissionDeniedError('Error opening directory: Permission denied');
    const {topCpu} = topCpuAfterTwoScans({...STEADY_DELTAS_USEC, [ROOT_CGROUP_KEY]: 1_100_000}, {
        beforeSecondScan: tree => tree.failWith(GLib.build_filenamev([CGROUP_ROOT_RELATIVE_PATH, APP_SLICE]),
            listingError),
    });
    assertEqual(topCpu, {groupKey: 'unit:org.gnome.Shell', name: 'GNOME Shell', cpuPercent: 5});
});

test('service sampler: unwatched, a fresh sampler scans at tick 0 (first), 1 (warm-up) and 31, and no other', () =>
    assertEqual(scanTicksAndReasons(false, FIRST_UNWATCHED_INTERVAL_SCAN_TICK + 4),
        [[0, 'first'], [1, 'warm-up'], [FIRST_UNWATCHED_INTERVAL_SCAN_TICK, 'interval']]));

test('service sampler: watched from before the first tick, it scans at tick 0 (first), 1 (warm-up), 11 and 21', () =>
    // A watch started before any tick does not scan at once: the first tick scans anyway.
    assertEqual(scanTicksAndReasons(true, 25), [[0, 'first'], [1, 'warm-up'], [11, 'interval'], [21, 'interval']]));

test('service sampler: a watch start scans at once and publishes the latest fast-tick values with the new ranking, ' +
    'appending no history', () => {
    const {sampler, clock, published, scanCount} = makeSamplerPastItsWarmUp();
    const lastTickSnapshot = sampler.latestSnapshot;
    const historyLengthBefore = sampler.cpuHistory.values().length;
    const [publishedBefore, scansBefore] = [published.length, scanCount()];
    // The last scan ran at tick 1 (4 s); against root-b 6 s later, herdr's 6 s of CPU on 2 CPUs is 50%.
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.fsRoot = fixtureRoot('root-b');
    sampler.setDetailWatched(true);
    const reveal = published.at(-1);
    sampler.destroy();
    assertEqual([published.length - publishedBefore, scanCount() - scansBefore, sampler.lastAppScanReason,
        reveal.appendedHistory, sampler.cpuHistory.values().length - historyLengthBefore,
        {...reveal.snapshot, apps: null}, reveal.snapshot.apps.topCpu, sampler.latestSnapshot === reveal.snapshot],
    [1, 1, 'watch-start', null, 0, {...lastTickSnapshot, apps: null},
        {groupKey: 'unit:herdr-server', name: 'herdr agents', cpuPercent: 50}, true]);
});

test('service sampler: a watch start inside the reveal cooldown does not scan; the warm-up follows on the next tick; ' +
    'unwatching only changes the cadence', () => {
    const {sampler, clock, published, scanCount} = makeSamplerPastItsWarmUp();
    /** @returns {number[]} [scans, publishes] so far. */
    const counts = () => [scanCount(), published.length];
    sampler.setDetailWatched(true);
    const afterFirstWatchStart = counts();
    const appsAfterFirstWatchStart = sampler.latestSnapshot.apps;
    sampler.setDetailWatched(false);
    const afterUnwatch = counts();
    const isRankingKeptAfterUnwatch = sampler.latestSnapshot.apps === appsAfterFirstWatchStart;
    sampler.setDetailWatched(true);
    const afterWatchStartInCooldown = counts();
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.runTick(WARM_UP_SETUP_LAST_TICK + 1);
    const reasonOfNextTickScan = sampler.lastAppScanReason;
    const afterNextTick = counts();
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.runTick(WARM_UP_SETUP_LAST_TICK + 2);
    const afterSecondTick = counts();
    // Two ticks (REVEAL_SCAN_COOLDOWN_TICKS) after the watch-start scan, made after tick 3, a watch start scans again.
    sampler.setDetailWatched(false);
    sampler.setDetailWatched(true);
    const afterCooledWatchStart = counts();
    sampler.destroy();
    const [scansAtStart, publishesAtStart] = afterFirstWatchStart;
    assertEqual([afterUnwatch, isRankingKeptAfterUnwatch, afterWatchStartInCooldown, reasonOfNextTickScan,
        afterNextTick, afterSecondTick, afterCooledWatchStart],
    [afterFirstWatchStart, true, afterFirstWatchStart, 'warm-up', [scansAtStart + 1, publishesAtStart + 1],
        [scansAtStart + 1, publishesAtStart + 2], [scansAtStart + 2, publishesAtStart + 3]]);
});

test('service sampler: collectGarbage runs once after each app scan (after its publish), never after a fast tick alone',
    () => {
        const events = [];
        const {sampler, clock} = makeSampler('root-a', {
            readFile: makeScanSpottingReader(() => events.push('scan')),
            collectGarbage: () => events.push('collect garbage'),
        });
        sampler.addListener(() => events.push('publish'));
        sampler.initialize();
        for (let tickNumber = 0; tickNumber <= WARM_UP_SETUP_LAST_TICK; tickNumber++) {
            clock.nowUsec += SAMPLE_SPACING_USEC;
            sampler.runTick(tickNumber);
        }
        sampler.setDetailWatched(true);
        sampler.destroy();
        assertEqual(events, [
            'scan', 'publish', 'collect garbage', // tick 0: first
            'scan', 'publish', 'collect garbage', // tick 1: warm-up
            'publish', 'publish', // ticks 2 and 3
            'scan', 'publish', 'collect garbage', // the watch start
        ]);
    });

test('service sampler: a scan that throws is logged, drops the ranking, and never costs the tick its sample', () => {
    let isNameLookupBroken = false;
    const {sampler, clock, logged} = makeSampler('root-a', {
        resolveAppName: () => {
            if (isNameLookupBroken)
                throw new Error('name lookup exploded');
            return null;
        },
    });
    sampler.initialize();
    sampler.runTick(0);
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.runTick(1);
    const appsBeforeTheFailure = sampler.latestSnapshot.apps;
    isNameLookupBroken = true;
    const historyLengthBefore = sampler.cpuHistory.values().length;
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.runTick(FIRST_UNWATCHED_INTERVAL_SCAN_TICK);
    assertEqual([appsBeforeTheFailure !== null, sampler.cpuHistory.values().length - historyLengthBefore,
        sampler.latestSnapshot.apps, logged.length, logged[0]?.startsWith(LOG_PREFIX),
        logged[0]?.includes('name lookup exploded')], [true, 1, null, 1, true, true]);
});

test('service sampler: a throwing sample publishes an all-null, incomplete snapshot and a gap in both histories',
    () => {
        const clockLabels = [FIXTURE_CLOCK_LABEL, LATER_CLOCK_LABEL];
        const {sampler, clock, logged} = makeSampler('root-a', {clockLabel: () => clockLabels.shift()});
        sampler.runTick(0);
        // A ranking is on hand, so the no-data snapshot's apps: null is a choice, not an accident.
        const ranking = sampler.latestSnapshot.apps;
        const published = [];
        sampler.addListener((snapshot, appendedHistory) => published.push({snapshot, appendedHistory}));
        clock.nowUsec += SAMPLE_SPACING_USEC;
        Object.defineProperty(sampler, 'fsRoot', {
            get() {
                throw new Error('fsRoot exploded');
            },
        });
        sampler.runTick(1);
        const {takenAtUsec, takenAtClockLabel, ...dataFields} = published[0]?.snapshot ?? {};
        assertEqual([ranking !== null, dataFields, takenAtUsec, takenAtClockLabel, published.length,
            published[0]?.appendedHistory, published[0]?.snapshot === sampler.latestSnapshot,
            sampler.cpuHistory.values(), sampler.memoryHistory.values(), sampler.lastGoodClockLabel, logged.length,
            logged[0]?.includes('fsRoot exploded')],
        [true, NO_DATA_SNAPSHOT_FIELDS, SAMPLE_SPACING_USEC, LATER_CLOCK_LABEL, 1, {cpu: null, memory: null}, true,
            [null, null], [FIXTURE_MEMORY_USED_FRACTION, null], FIXTURE_CLOCK_LABEL, 1, true]);
    });

test('service sampler: a tick whose clock label throws publishes no label, and "no data since" keeps the last good one',
    () => {
        let isClockBroken = false;
        const {sampler} = makeSampler('root-a', {
            clockLabel: () => {
                if (isClockBroken)
                    throw new Error('clock exploded');
                return FIXTURE_CLOCK_LABEL;
            },
        });
        sampler.runTick(0);
        isClockBroken = true;
        sampler.runTick(1);
        const snapshot = sampler.latestSnapshot;
        assertEqual([snapshot.takenAtClockLabel, snapshot.isComplete, snapshot.memory, sampler.lastGoodClockLabel],
            [null, false, null, FIXTURE_CLOCK_LABEL]);
    });

test('service sampler: each history keeps the newest CARD_HISTORY_SAMPLES fast ticks, a gap included', () => {
    let isClockBroken = true;
    const {sampler, clock} = makeSampler('root-a', {
        clockLabel: () => {
            if (isClockBroken)
                throw new Error('clock exploded');
            return FIXTURE_CLOCK_LABEL;
        },
    });
    sampler.runTick(0);
    const historiesAfterGap = [sampler.cpuHistory.values(), sampler.memoryHistory.values()];
    isClockBroken = false;
    for (let tickNumber = 1; tickNumber <= CARD_HISTORY_SAMPLES; tickNumber++) {
        clock.nowUsec += SAMPLE_SPACING_USEC;
        sampler.runTick(tickNumber);
    }
    const memoryValues = sampler.memoryHistory.values();
    assertEqual([historiesAfterGap, sampler.cpuHistory.values().length, memoryValues.length,
        memoryValues.every(value => value === FIXTURE_MEMORY_USED_FRACTION)],
    [[[null], [null]], CARD_HISTORY_SAMPLES, CARD_HISTORY_SAMPLES, true]);
});

test('service sampler: a fast tick hands listeners the history values it appended', () => {
    const {sampler, clock} = makeSampler('root-a');
    sampler.initialize();
    const appendedHistories = [];
    sampler.addListener((_snapshot, appendedHistory) => appendedHistories.push(appendedHistory));
    tickRootAThenRootB(sampler, clock);
    // root-b holds as much memory as root-a.
    assertEqual(appendedHistories,
        [{cpu: null, memory: FIXTURE_MEMORY_USED_FRACTION}, {cpu: 0.6, memory: FIXTURE_MEMORY_USED_FRACTION}]);
});

test('service sampler: an unparseable PMU list falls back to cpu_capacity and is logged, not thrown', () => {
    const {sampler, clock, logged} = makeSampler('root-bad-pmu');
    sampler.initialize();
    const snapshot = tickRootAThenRootB(sampler, clock);
    assertEqual([snapshot.cpuClusters, logged.length, logged[0]?.startsWith(LOG_PREFIX),
        logged[0]?.includes('cpu_core/cpus')], [{performancePercent: 80, efficiencyPercent: 40}, 1, true, true]);
});

test('service sampler: a throwing listener is logged and the next still runs; a removed one is not called', () => {
    const {sampler, logged} = makeSampler('root-a');
    const calls = {afterThrowing: 0, removed: 0};
    sampler.addListener(() => {
        throw new Error('listener exploded');
    });
    sampler.addListener(() => calls.afterThrowing++);
    const removedListenerId = sampler.addListener(() => calls.removed++);
    sampler.removeListener(removedListenerId);
    sampler.runTick(0);
    assertEqual([sampler.latestSnapshot !== null, calls, logged.length, logged[0]?.startsWith(LOG_PREFIX),
        logged[0]?.includes('listener exploded')], [true, {afterThrowing: 1, removed: 0}, 1, true, true]);
});

test('service sampler: 109 cgroups failing with one error log one line per 10 minutes, naming the count and the ' +
    'first path', () => {
    const tree = makeFakeTreeWithSampleFiles();
    const failingLeafPaths = Array.from({length: FAILING_LEAF_COUNT},
        (_unused, leafIndex) => `${SYSTEM_SLICE}/${generatedLeafName(leafIndex)}`);
    writeCgroupCounters(tree, Object.fromEntries([[ROOT_CGROUP_KEY, 1_000_000], [SYSTEM_SLICE, 1_000_000],
        ...failingLeafPaths.map(leafPath => [leafPath, 1_000])]));
    const deniedError = permissionDeniedError('Error opening file: Permission denied');
    const cpuStatOf = leafPath => GLib.build_filenamev([CGROUP_ROOT_RELATIVE_PATH, leafPath, 'cpu.stat']);
    failingLeafPaths.forEach(leafPath => tree.failWith(cpuStatOf(leafPath), deniedError));
    const {sampler, clock, logged} = makeTreeSampler(tree);
    sampler.initialize();
    sampler.runTick(0);
    const linesAfterFirstScan = [...logged];
    // The warm-up scan, 2 s later: another count and another first path, the same template.
    tree.clearFailure(cpuStatOf(failingLeafPaths[0]));
    clock.nowUsec += SAMPLE_SPACING_USEC;
    sampler.runTick(1);
    const lineCountAfterSecondScan = logged.length;
    clock.nowUsec = ERROR_LOG_REPEAT_INTERVAL_USEC + SAMPLE_SPACING_USEC;
    sampler.runTick(FIRST_UNWATCHED_INTERVAL_SCAN_TICK);
    sampler.destroy();
    assertEqual([linesAfterFirstScan, lineCountAfterSecondScan, logged.at(-1)], [
        [`${LOG_PREFIX} cannot read ${FAILING_LEAF_COUNT} cgroups, first: ${failingLeafPaths[0]}: ` +
            'Error opening file: Permission denied'],
        1,
        `${LOG_PREFIX} cannot read ${FAILING_LEAF_COUNT - 1} cgroups, first: ${failingLeafPaths[1]}: ` +
            'Error opening file: Permission denied',
    ]);
});

test('service sampler: start() twice adds one source; stop and destroy remove it; nothing after destroy', async () => {
    await withTimerSpy(spy => {
        const {sampler} = makeSampler('root-a', {sampleIntervalSeconds: QUIET_INTERVAL_SECONDS});
        sampler.start();
        sampler.start();
        const addedByDoubleStart = spy.added.length;
        sampler.stop();
        sampler.start();
        sampler.destroy();
        // Checked before the start() below, which would otherwise tidy up a source destroy() had left behind.
        const addedIds = spy.added.map(entry => entry.sourceId);
        const isAnySourceAttachedAfterDestroy = addedIds.some(isSourceAttached);
        sampler.start();
        assertEqual([addedByDoubleStart, spy.added.length, spy.removed, isAnySourceAttachedAfterDestroy],
            [1, 2, addedIds, false]);
    });
});

test('service sampler: start() ticks at once, so memory shows before the first interval and CPU after it; nothing ' +
    'ticks after destroy()', async () => {
    await withTimerSpy(spy => {
        const {sampler} = makeSampler('root-a', {sampleIntervalSeconds: QUIET_INTERVAL_SECONDS});
        const published = [];
        sampler.addListener(snapshot => published.push(snapshot));
        sampler.start();
        const [firstSnapshot] = published;
        const publishedByStart = published.length;
        sampler.destroy();
        sampler.start();
        sampler.runTick(1);
        sampler.setDetailWatched(true);
        assertEqual([publishedByStart, firstSnapshot?.memory !== null, firstSnapshot?.cpuBusyPercent, published.length,
            spy.added.length], [1, true, null, 1, 1]);
    });
});

test('service sampler: the timer callback never throws: a tick that throws is logged and the source continues',
    async () => {
        await withTimerSpy(spy => {
            const {sampler, logged} = makeSampler('root-a', {sampleIntervalSeconds: QUIET_INTERVAL_SECONDS});
            sampler.start();
            sampler.runTick = () => {
                throw new Error('tick exploded');
            };
            const callbackResult = spy.added[0].callback();
            const isStillAttached = isSourceAttached(spy.added[0].sourceId);
            sampler.destroy();
            assertEqual([callbackResult, isStillAttached, logged.length, logged[0]?.startsWith(LOG_PREFIX),
                logged[0]?.includes('tick exploded')], [GLib.SOURCE_CONTINUE, true, 1, true, true]);
        });
    });

test('service sampler: a real 1 s timer calls listeners, and none fire for 1.5 s after stop()', async () => {
    const {sampler} = makeSampler('root-a', {sampleIntervalSeconds: TIMER_INTERVAL_SECONDS});
    let listenerCalls = 0;
    sampler.addListener(() => listenerCalls++);
    sampler.start();
    await waitMs(TIMER_RUN_MS);
    sampler.stop();
    const callsAtStop = listenerCalls;
    await waitMs(AFTER_STOP_MS);
    sampler.destroy();
    assertEqual([callsAtStop >= MIN_TICKS_WHILE_TIMER_RUNS, listenerCalls - callsAtStop], [true, 0],
        `${callsAtStop} calls while running`);
});

test('readFileToEnd reads a /proc file whole although it reports a size of 0', () => {
    const statusPath = '/proc/self/status';
    const reportedSize = Gio.File.new_for_path(statusPath)
        .query_info('standard::size', Gio.FileQueryInfoFlags.NONE, null).get_size();
    const statusText = readFileToEnd(statusPath);
    assertEqual([reportedSize, statusText.includes('\nUid:'), statusText.endsWith('\n')], [0, true, true]);
});

test('listSubdirectoryNames names the subdirectories of a directory, and leaves its files out', () => {
    // root-bad-pmu's sys/devices/system/cpu holds cpu0/, cpu1/ and the file possible.
    const cpuDevicesPath = GLib.build_filenamev([fixtureRoot('root-bad-pmu'), 'sys', 'devices', 'system', 'cpu']);
    assertEqual(listSubdirectoryNames(cpuDevicesPath).sort(), ['cpu0', 'cpu1']);
});
