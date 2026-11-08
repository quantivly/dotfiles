// The one source of numbers for the top bar and the desktop card: asynchronous Gio reads of /proc, /sys and
// the cgroup tree, on one GLib timer. Gio and GLib only (no Shell imports), so it runs under plain `gjs -m`.
//
// It runs inside gnome-shell, the compositor, so a mistake here freezes or destabilises the desktop:
// - every read is asynchronous and nothing here blocks the main loop;
// - a sample or scan already in flight makes the next one a no-op: skipped, never queued;
// - after every await, a destroyed (or restarted-baseline) check comes before any state is touched;
// - the IO helpers are module functions with no access to sampler state, so only methods can change it;
// - nothing a tick does can throw out of the timer callback;
// - a failure becomes the "no data" state on both surfaces: a sample that throws publishes an all-null snapshot
//   and a gap in the histories, and a scan that throws drops its ranking rather than leaving it shown as current.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {
    APP_SCAN_EVERY_N_TICKS, APP_SCAN_SKIPPED_UNIT_SUFFIXES, CARD_HISTORY_SAMPLES, DIRECTORY_LISTING_BATCH_ENTRIES,
    APP_MEMORY_STAT_MIN_BYTES, ERROR_LOG_REPEAT_INTERVAL_USEC, LOG_PREFIX, SAMPLE_INTERVAL_SECONDS,
} from './lib/constants.js';
import {parseMeminfo, parsePressureSomeAvg10, parseProcStat, parseUid, parseZramMmStat} from './lib/procParsers.js';
import {parseCpuStatUsageUsec, parseMemoryStatReclaimableBytes, parseSingleNumber} from './lib/cgroupParsers.js';
import {buildClusterMap, clusterBusyFraction, cpuBusyFraction, parseCpuList} from './lib/cpu.js';
import {memoryUsage, swapSummary} from './lib/memory.js';
import {describeCgroup, displayNameFor, rankApps} from './lib/apps.js';
import {RingBuffer} from './lib/history.js';

Gio._promisify(Gio.File.prototype, 'load_contents_async', 'load_contents_finish');
Gio._promisify(Gio.File.prototype, 'enumerate_children_async', 'enumerate_children_finish');
Gio._promisify(Gio.FileEnumerator.prototype, 'next_files_async', 'next_files_finish');
Gio._promisify(Gio.FileEnumerator.prototype, 'close_async', 'close_finish');

// Paths, relative to the sampler's fsRoot.
const PROC_STAT_PATH = 'proc/stat';
const PROC_MEMINFO_PATH = 'proc/meminfo';
const PROC_SELF_STATUS_PATH = 'proc/self/status';
const CPU_PRESSURE_PATH = 'proc/pressure/cpu';
const MEMORY_PRESSURE_PATH = 'proc/pressure/memory';
const IO_PRESSURE_PATH = 'proc/pressure/io';
const BLOCK_DEVICES_PATH = 'sys/block';
const CORE_PMU_CPUS_PATH = 'sys/devices/cpu_core/cpus';
const ATOM_PMU_CPUS_PATH = 'sys/devices/cpu_atom/cpus';
const CPU_DEVICES_PATH = 'sys/devices/system/cpu';
const CGROUP_ROOT_PATH = 'sys/fs/cgroup';

// Names inside those directories.
const ZRAM_DEVICE_NAME_PATTERN = /^zram\d+$/;
const ZRAM_MM_STAT_FILE = 'mm_stat';
const CPU_DEVICE_NAME_PATTERN = /^cpu(\d+)$/;
const CPU_CAPACITY_FILE = 'cpu_capacity';
const CGROUP_CPU_STAT_FILE = 'cpu.stat';
const CGROUP_MEMORY_CURRENT_FILE = 'memory.current';
const CGROUP_MEMORY_STAT_FILE = 'memory.stat';
const USER_SLICE = 'user.slice';
const SYSTEM_SLICE = 'system.slice';
const USER_SERVICE_SLICES = ['app.slice', 'session.slice', 'background.slice'];
const SLICE_SUFFIX = '.slice';

const NAME_ONLY_ATTRIBUTES = 'standard::name';
const NAME_AND_TYPE_ATTRIBUTES = 'standard::name,standard::type';
const CLOCK_LABEL_FORMAT = '%H:%M';
const PERCENT_SCALE = 100;
const DECIMAL_RADIX = 10;
const UTF8_DECODER = new TextDecoder();

/**
 * @typedef {object} AppRanking
 * @property {{name: string, cpuPercent: number}|null} topCpu - The app using the most CPU, as a share of the
 *     whole machine; null until two scans give a delta.
 * @property {{name: string, memoryBytes: number}|null} topMemory - The app holding the most memory that is not
 *     page cache.
 */

/**
 * @typedef {object} Snapshot
 * @property {number|null} takenAtUsec - nowUsec() when the sample began; null only in a no-data snapshot whose
 *     clock could not be read.
 * @property {string|null} takenAtClockLabel - Wall-clock 'HH:MM' of the sample; null only in a no-data snapshot
 *     whose clock label could not be read (the sampler's lastGoodClockLabel still names the last good one).
 * @property {number|null} cpuBusyPercent - Whole-machine CPU busy, 0–100. Null on the first sample (no delta
 *     yet) and when /proc/stat could not be read.
 * @property {{performancePercent: number|null, efficiencyPercent: number|null}|null} cpuClusters - Busy percent
 *     per core type. Null on a single-cluster machine and whenever cpuBusyPercent has no delta.
 * @property {{usedBytes: number, totalBytes: number}|null} memory - MemTotal − MemAvailable, and MemTotal.
 * @property {{swappedBytes: number, zramStoredBytes: number, zramRamBytes: number, diskBytes: number}|null} swap
 *     - Swap split between zram and disk.
 * @property {{cpu: number|null, memory: number|null, io: number|null}} pressureAvg10 - PSI `some avg10` percents.
 * @property {AppRanking|null} apps - The latest app scan; null before the first one, while scanning is off, and
 *     after a scan that threw.
 * @property {boolean} isComplete - True when every read and parse of this sample succeeded. A first sample's
 *     missing CPU delta is not a failure. A sample that threw publishes a no-data snapshot: every number null,
 *     apps null, and isComplete false.
 */

/**
 * Joins path segments with the platform separator.
 *
 * @param {...string} segments - Path pieces; a piece may itself contain separators.
 * @returns {string} The joined path.
 */
function joinPath(...segments) {
    return GLib.build_filenamev(segments);
}

/**
 * Says whether an error is Gio's "no such file or directory".
 *
 * @param {*} error - A rejection reason.
 * @returns {boolean} True for G_IO_ERROR_NOT_FOUND.
 */
function isNotFoundError(error) {
    return error instanceof GLib.Error && error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.NOT_FOUND);
}

/**
 * Gives an error's message and, when it has one, its stack: for failures that point at a bug, not at IO.
 *
 * @param {*} error - A caught value.
 * @returns {string} The message, then the stack on the following lines.
 */
function describeErrorWithStack(error) {
    const stackText = error?.stack ? `\n${error.stack}` : '';
    return `${describeError(error)}${stackText}`;
}

/**
 * Calls an injected callback for a best-effort value. Used only while publishing "no data" after a failure that
 * is being logged anyway, where this callback may well be what failed; a second throw from it is not news.
 *
 * @param {() => *} callback - nowUsec or clockLabel.
 * @returns {*} Its value, or null when it throws.
 */
function callOrNull(callback) {
    try {
        return callback();
    } catch {
        return null;
    }
}

/**
 * Gives an error's message, whatever was thrown.
 *
 * @param {*} error - A rejection reason or caught value.
 * @returns {string} Its message, or its string form.
 */
function describeError(error) {
    return error?.message ?? String(error);
}

/**
 * Converts a busy fraction to a percentage, clamped to 0–100. /proc/stat's iowait can step backwards, which can
 * push a raw fraction just outside 0–1.
 *
 * @param {number|null} fraction - Busy fraction, or null for no data.
 * @returns {number|null} The percentage, or null.
 */
function fractionToPercent(fraction) {
    if (fraction === null)
        return null;
    return Math.min(1, Math.max(0, fraction)) * PERCENT_SCALE;
}

/**
 * Parses /proc/stat, treating a file without an aggregate `cpu` line as unparseable.
 *
 * @param {string} text - File contents.
 * @returns {{aggregate: object, perCpu: Map<number, object>}|null} The parsed times, or null.
 */
function parseUsableProcStat(text) {
    const procStat = parseProcStat(text);
    return procStat.aggregate === null ? null : procStat;
}

/**
 * Reads a whole file asynchronously as UTF-8. /proc and cgroup files report size 0 but read to EOF.
 *
 * @param {string} path - Absolute path.
 * @param {Gio.Cancellable} cancellable - Cancels the read.
 * @returns {Promise<string>} The contents; rejects with a GLib.Error when unreadable.
 */
async function readTextFile(path, cancellable) {
    const [contentBytes] = await Gio.File.new_for_path(path).load_contents_async(cancellable);
    return UTF8_DECODER.decode(contentBytes);
}

/**
 * Lists a directory asynchronously at low priority, closing the enumerator whatever happens.
 *
 * @param {string} directoryPath - Absolute path.
 * @param {string} attributes - Gio file attributes to fetch for each entry.
 * @param {Gio.Cancellable} cancellable - Cancels the listing (the close always runs).
 * @returns {Promise<Gio.FileInfo[]>} One info per entry.
 */
async function listDirectory(directoryPath, attributes, cancellable) {
    const enumerator = await Gio.File.new_for_path(directoryPath).enumerate_children_async(
        attributes, Gio.FileQueryInfoFlags.NONE, GLib.PRIORITY_LOW, cancellable);
    try {
        return await collectFileInfos(enumerator, cancellable);
    } finally {
        // Release the directory's descriptor now, not whenever the garbage collector finalizes the enumerator.
        await enumerator.close_async(GLib.PRIORITY_LOW, null);
    }
}

/**
 * Drains an enumerator in batches.
 *
 * @param {Gio.FileEnumerator} enumerator - An open enumerator.
 * @param {Gio.Cancellable} cancellable - Cancels the listing.
 * @returns {Promise<Gio.FileInfo[]>} Every remaining entry.
 */
async function collectFileInfos(enumerator, cancellable) {
    const fileInfos = [];
    let batch;
    do {
        batch = await enumerator.next_files_async(DIRECTORY_LISTING_BATCH_ENTRIES, GLib.PRIORITY_LOW, cancellable);
        fileInfos.push(...batch);
    } while (batch.length > 0);
    return fileInfos;
}

/**
 * Lists the names in a directory, without stat()ing the entries.
 *
 * @param {string} directoryPath - Absolute path.
 * @param {Gio.Cancellable} cancellable - Cancels the listing.
 * @returns {Promise<string[]>} Entry names.
 */
async function listChildNames(directoryPath, cancellable) {
    const fileInfos = await listDirectory(directoryPath, NAME_ONLY_ATTRIBUTES, cancellable);
    return fileInfos.map(fileInfo => fileInfo.get_name());
}

/**
 * Lists the subdirectories of a directory.
 *
 * @param {string} directoryPath - Absolute path.
 * @param {Gio.Cancellable} cancellable - Cancels the listing.
 * @returns {Promise<string[]>} Names of the entries that are directories.
 */
async function listChildDirectoryNames(directoryPath, cancellable) {
    const fileInfos = await listDirectory(directoryPath, NAME_AND_TYPE_ATTRIBUTES, cancellable);
    return fileInfos
        .filter(fileInfo => fileInfo.get_file_type() === Gio.FileType.DIRECTORY)
        .map(fileInfo => fileInfo.get_name());
}

/**
 * Reads mm_stat of every zram device.
 *
 * @param {string} fsRoot - The filesystem root.
 * @param {Gio.Cancellable} cancellable - Cancels the reads.
 * @returns {Promise<Array<{storedBytes: number, ramBytes: number}>>} One entry per device; empty without zram.
 */
async function readZramDevices(fsRoot, cancellable) {
    const blockDevicesPath = joinPath(fsRoot, BLOCK_DEVICES_PATH);
    const deviceNames = await listChildNames(blockDevicesPath, cancellable);
    const zramDeviceNames = deviceNames.filter(deviceName => ZRAM_DEVICE_NAME_PATTERN.test(deviceName));
    return Promise.all(zramDeviceNames.map(async deviceName => {
        const mmStatPath = joinPath(blockDevicesPath, deviceName, ZRAM_MM_STAT_FILE);
        const zramDevice = parseZramMmStat(await readTextFile(mmStatPath, cancellable));
        if (zramDevice === null)
            throw new Error(`cannot parse ${mmStatPath}`);
        return zramDevice;
    }));
}

/**
 * Reads one cgroup leaf's CPU usage and its memory net of page cache. memory.stat is read only when
 * memory.current exceeds APP_MEMORY_STAT_MIN_BYTES; a smaller leaf is ranked uncorrected.
 *
 * @param {string} leafPath - Absolute path of the cgroup directory.
 * @param {Gio.Cancellable} cancellable - Cancels the reads.
 * @returns {Promise<{usageUsec: number, memoryBytes: number}>} The leaf's readings; rejects when a required file
 *     is missing (the cgroup vanished) or unparseable.
 */
async function readCgroupLeaf(leafPath, cancellable) {
    const cpuStatPath = joinPath(leafPath, CGROUP_CPU_STAT_FILE);
    const memoryCurrentPath = joinPath(leafPath, CGROUP_MEMORY_CURRENT_FILE);
    const [cpuStatText, memoryCurrentText] = await Promise.all([
        readTextFile(cpuStatPath, cancellable), readTextFile(memoryCurrentPath, cancellable),
    ]);
    const usageUsec = parseCpuStatUsageUsec(cpuStatText);
    if (usageUsec === null)
        throw new Error(`cannot parse ${cpuStatPath}`);
    const memoryCurrentBytes = parseSingleNumber(memoryCurrentText);
    if (memoryCurrentBytes === null)
        throw new Error(`cannot parse ${memoryCurrentPath}`);
    if (memoryCurrentBytes <= APP_MEMORY_STAT_MIN_BYTES)
        return {usageUsec, memoryBytes: memoryCurrentBytes};
    const memoryStatPath = joinPath(leafPath, CGROUP_MEMORY_STAT_FILE);
    const reclaimableBytes = parseMemoryStatReclaimableBytes(await readTextFile(memoryStatPath, cancellable));
    if (reclaimableBytes === null)
        throw new Error(`cannot parse ${memoryStatPath}`);
    return {usageUsec, memoryBytes: Math.max(0, memoryCurrentBytes - reclaimableBytes)};
}

/**
 * Says whether a cgroup leaf belongs to a unit type that can host an app (a service, a scope, or a slice too deep
 * to descend into), as opposed to a mount, socket, timer and the like.
 *
 * @param {string} cgroupPath - The leaf's path.
 * @returns {boolean} False for a suffix in APP_SCAN_SKIPPED_UNIT_SUFFIXES.
 */
function canHostApp(cgroupPath) {
    return !APP_SCAN_SKIPPED_UNIT_SUFFIXES.some(unitSuffix => cgroupPath.endsWith(unitSuffix));
}

/**
 * Names the app a cgroup leaf belongs to, and the key its scopes are summed under.
 *
 * @param {string} cgroupPath - The leaf's path (only its last component is used).
 * @param {(desktopId: string) => string|null} resolveAppName - Looks up a `.desktop` id's real name.
 * @returns {{groupKey: string, name: string}} The group, for rankApps' nameOfCgroup.
 */
export function groupOfCgroup(cgroupPath, resolveAppName) {
    const description = describeCgroup(GLib.path_get_basename(cgroupPath));
    return {groupKey: description.groupKey, name: displayNameFor(description, resolveAppName)};
}

/** Samples CPU, memory, swap and pressure on a timer, scans apps every few ticks, and tells listeners. */
export class Sampler {
    /**
     * @param {object} [options] - Everything injectable, so tests can run against fixture trees.
     * @param {string} [options.fsRoot] - Root under which proc/ and sys/ are read; public, tests reassign it.
     * @param {(desktopId: string) => string|null} [options.resolveAppName] - Real name of a `.desktop` id.
     * @param {() => number} [options.nowUsec] - Monotonic microseconds.
     * @param {() => string} [options.clockLabel] - Wall-clock 'HH:MM'.
     * @param {(message: string) => void} [options.log] - Where rate-limited error lines go.
     * @param {number} [options.sampleIntervalSeconds] - Seconds between ticks.
     */
    constructor({
        fsRoot = '/',
        resolveAppName = () => null,
        nowUsec = () => GLib.get_monotonic_time(),
        clockLabel = () => GLib.DateTime.new_now_local().format(CLOCK_LABEL_FORMAT),
        log = message => console.warn(message),
        sampleIntervalSeconds = SAMPLE_INTERVAL_SECONDS,
    } = {}) {
        this.fsRoot = fsRoot;
        this._resolveAppName = resolveAppName;
        this._nowUsec = nowUsec;
        this._clockLabel = clockLabel;
        this._log = log;
        this._sampleIntervalSeconds = sampleIntervalSeconds;

        this._cancellable = new Gio.Cancellable();
        this._isDestroyed = false;
        this._isStarted = false;
        this._isPaused = false;
        this._isAppScanEnabled = true;
        this._timeoutSourceId = null;
        this._nextTickNumber = 0;
        this._isSampleInFlight = false;
        this._isAppScanInFlight = false;
        // Bumped whenever a baseline is thrown away, so a read begun before that cannot reinstate it.
        this._cpuBaselineEpoch = 0;
        this._appBaselineEpoch = 0;

        this._uid = null;
        this._cpuCount = null;
        this._clusterMap = null;
        this._previousProcStat = null;
        this._previousAppScan = null;
        this._latestAppRanking = null;
        this._latestSnapshot = null;
        this._lastGoodClockLabel = null;
        this._cpuHistory = new RingBuffer(CARD_HISTORY_SAMPLES);
        this._memoryHistory = new RingBuffer(CARD_HISTORY_SAMPLES);
        this._listeners = new Map();
        this._nextListenerId = 1;
        this._lastLoggedUsecByMessage = new Map();
    }

    /** @returns {Snapshot|null} The most recent snapshot, or null before the first. */
    get latestSnapshot() {
        return this._latestSnapshot;
    }

    /** @returns {string|null} 'HH:MM' of the last snapshot with CPU or memory data. */
    get lastGoodClockLabel() {
        return this._lastGoodClockLabel;
    }

    /** @returns {RingBuffer} CPU busy fractions 0–1, null for no data, oldest first. */
    get cpuHistory() {
        return this._cpuHistory;
    }

    /** @returns {RingBuffer} Memory used fractions 0–1, null for no data, oldest first. */
    get memoryHistory() {
        return this._memoryHistory;
    }

    /**
     * Reads what does not change while the extension runs: the uid, the CPU count and the cluster map. Never
     * throws for a read or parse failure; each one is logged and leaves its value unknown.
     *
     * The CPU count is the number of per-CPU lines in /proc/stat. Every later successful sample refreshes it, so
     * a failed read here recovers on its own.
     *
     * @returns {Promise<void>} Settles when done, or at once when destroyed.
     */
    async initialize() {
        if (this._isDestroyed)
            return;
        const fsRoot = this.fsRoot;
        const statusPath = joinPath(fsRoot, PROC_SELF_STATUS_PATH);
        const statPath = joinPath(fsRoot, PROC_STAT_PATH);
        const [statusRead, statRead] = await Promise.allSettled([
            readTextFile(statusPath, this._cancellable), readTextFile(statPath, this._cancellable),
        ]);
        if (this._isDestroyed)
            return;
        this._uid = this._parseSettledRead(statusRead, statusPath, parseUid);
        const procStat = this._parseSettledRead(statRead, statPath, parseUsableProcStat);
        if (procStat !== null && procStat.perCpu.size > 0)
            this._cpuCount = procStat.perCpu.size;
        const clusterMap = await this._readClusterMap(fsRoot);
        if (this._isDestroyed)
            return;
        this._clusterMap = clusterMap;
    }

    /**
     * Starts the timer and runs its first tick at once, so memory and swap show without waiting an interval (CPU
     * needs a second sample). Calling it again while started adds nothing; while paused or destroyed nothing
     * runs.
     *
     * @returns {void}
     */
    start() {
        this._isStarted = true;
        this._syncTimer();
    }

    /**
     * Stops the timer. A sample already in flight still completes and is delivered.
     *
     * @returns {void}
     */
    stop() {
        this._isStarted = false;
        this._syncTimer();
    }

    /**
     * Stops everything for good: the timer, the IO in flight (whose results are dropped) and every listener.
     *
     * @returns {void}
     */
    destroy() {
        if (this._isDestroyed)
            return;
        this._isDestroyed = true;
        this.stop();
        this._cancellable.cancel();
        this._listeners.clear();
    }

    /**
     * Pauses or resumes ticking (while the screen shield is up). On resume the CPU and app baselines restart,
     * so no delta averages across the pause and no ranking from before it is shown as current, and the first tick
     * runs at once.
     *
     * @param {boolean} isPaused - True to pause.
     * @returns {void}
     */
    setPaused(isPaused) {
        const isResuming = this._isPaused && !isPaused;
        this._isPaused = isPaused;
        if (isResuming)
            this._restartBaselines();
        this._syncTimer();
    }

    /**
     * Turns the periodic app scan on or off. Off drops the last ranking and its baseline; on scans at the next
     * tick.
     *
     * @param {boolean} isEnabled - True while the card could be visible.
     * @returns {void}
     */
    setAppScanEnabled(isEnabled) {
        if (isEnabled === this._isAppScanEnabled)
            return;
        this._isAppScanEnabled = isEnabled;
        if (isEnabled)
            this._nextTickNumber = 0;
        else
            this._forgetAppScans();
    }

    /**
     * Adds a callback for each new snapshot.
     *
     * @param {(snapshot: Snapshot) => void} callback - Called after every completed sample.
     * @returns {number} An id for removeListener.
     */
    addListener(callback) {
        const listenerId = this._nextListenerId++;
        this._listeners.set(listenerId, callback);
        return listenerId;
    }

    /**
     * Removes a callback added with addListener; an unknown id is ignored.
     *
     * @param {number} listenerId - The id addListener returned.
     * @returns {void}
     */
    removeListener(listenerId) {
        this._listeners.delete(listenerId);
    }

    /**
     * Does one tick's work: a sample, then an app scan when one is due and enabled. The sample comes first, so a
     * slow or failing scan can never delay or skip it; a ranking from this tick's scan appears in the next tick's
     * snapshot. Neither step rejects: a sample that throws publishes no data, and a scan that throws drops the
     * ranking.
     *
     * @param {number} tickNumber - The timer's tick count; it restarts at 0 on resume and when the scan is
     *     re-enabled, so the first tick after either scans at once.
     * @returns {Promise<void>} Settles when the tick is done.
     */
    async runTick(tickNumber) {
        if (this._isDestroyed)
            return;
        await this.sampleOnce();
        const isAppScanDue = this._isAppScanEnabled && tickNumber % APP_SCAN_EVERY_N_TICKS === 0;
        if (isAppScanDue && !this._isDestroyed)
            await this.scanAppsOnce();
    }

    /**
     * Samples CPU, memory, swap and pressure once, records the history and tells listeners. When the sample
     * throws, it publishes the no-data state instead (see _publishNoDataSnapshot), so it never rejects.
     *
     * @returns {Promise<Snapshot|null>} The snapshot (a no-data one after a throw), or null when skipped (one
     *     already in flight), destroyed, or overtaken by a pause.
     */
    async sampleOnce() {
        if (this._isDestroyed || this._isSampleInFlight)
            return null;
        // Set before the first await, so a second call in the same turn already sees it.
        this._isSampleInFlight = true;
        try {
            return await this._takeSample();
        } catch (error) {
            return this._publishNoDataSnapshot(error);
        } finally {
            this._isSampleInFlight = false;
        }
    }

    /**
     * Scans the app cgroups once and ranks them. The ranking appears in the following snapshots. When the scan
     * throws, the last ranking is dropped and the failure logged, so it never rejects.
     *
     * @returns {Promise<AppRanking|null>} The ranking, or null when skipped (one already in flight), destroyed,
     *     overtaken by the scan being turned off, or failed.
     */
    async scanAppsOnce() {
        if (this._isDestroyed || this._isAppScanInFlight)
            return null;
        // Set before the first await, so a second call in the same turn already sees it.
        this._isAppScanInFlight = true;
        try {
            return await this._scanApps();
        } catch (error) {
            this._dropRankingAfterFailure(error);
            return null;
        } finally {
            this._isAppScanInFlight = false;
        }
    }

    /**
     * Publishes the no-data state after a sample threw: an all-null, incomplete snapshot and a gap in both
     * histories, so neither surface goes on showing the last good numbers as live. The failure is logged last, so
     * the surfaces hear about it even if logging fails. lastGoodClockLabel is left alone (the snapshot has no
     * data), so "no data since" still names the last good sample.
     *
     * Everything in _takeSample that can throw runs before it changes any state, so this never follows a
     * half-recorded sample.
     *
     * @param {*} error - What the sample threw.
     * @returns {Snapshot|null} The no-data snapshot, or null when destroyed.
     */
    _publishNoDataSnapshot(error) {
        if (this._isDestroyed)
            return null;
        const snapshot = {
            takenAtUsec: callOrNull(this._nowUsec),
            takenAtClockLabel: callOrNull(this._clockLabel),
            cpuBusyPercent: null,
            cpuClusters: null,
            memory: null,
            swap: null,
            pressureAvg10: {cpu: null, memory: null, io: null},
            apps: null,
            isComplete: false,
        };
        this._recordHistory(snapshot);
        this._notifyListeners(snapshot);
        this._logRateLimited(`sample failed: ${describeErrorWithStack(error)}`);
        return snapshot;
    }

    /**
     * Drops the last ranking (and its baseline) after a scan threw, so the next snapshot carries no apps rather
     * than a ranking from before the failure, then logs the failure.
     *
     * @param {*} error - What the scan threw.
     * @returns {void}
     */
    _dropRankingAfterFailure(error) {
        if (this._isDestroyed)
            return;
        this._forgetAppScans();
        this._logRateLimited(`app scan failed: ${describeErrorWithStack(error)}`);
    }

    /**
     * Adds the timer source when it should run and has none, running its first tick at once, and removes it when
     * it should not run.
     *
     * @returns {void}
     */
    _syncTimer() {
        const shouldRun = this._isStarted && !this._isPaused && !this._isDestroyed;
        if (shouldRun && this._timeoutSourceId === null) {
            this._timeoutSourceId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, this._sampleIntervalSeconds,
                () => this._onTimeout());
            // The first tick now, not one interval from now: the timer's own path, so a sample already in flight
            // makes it a no-op.
            this._runNextTick();
        } else if (!shouldRun && this._timeoutSourceId !== null) {
            GLib.source_remove(this._timeoutSourceId);
            this._timeoutSourceId = null;
        }
    }

    /**
     * The timer callback: runs the next tick.
     *
     * @returns {boolean} GLib.SOURCE_CONTINUE: only source_remove ends the source, so its id is never stale.
     */
    _onTimeout() {
        this._runNextTick();
        return GLib.SOURCE_CONTINUE;
    }

    /**
     * Runs the next tick without waiting for it. runTick is async, so it cannot throw here, and it does not
     * reject today; should a future change make it reject, the rejection is logged rather than left unhandled.
     *
     * @returns {void}
     */
    _runNextTick() {
        const tickNumber = this._nextTickNumber++;
        this.runTick(tickNumber).catch(error =>
            this._logRateLimited(`tick failed: ${describeErrorWithStack(error)}`));
    }

    /**
     * Throws away the CPU and app baselines after a pause.
     *
     * @returns {void}
     */
    _restartBaselines() {
        this._cpuBaselineEpoch++;
        this._previousProcStat = null;
        this._forgetAppScans();
        this._nextTickNumber = 0;
    }

    /**
     * Throws away the last app ranking and the usage it would be diffed against.
     *
     * @returns {void}
     */
    _forgetAppScans() {
        this._appBaselineEpoch++;
        this._previousAppScan = null;
        this._latestAppRanking = null;
    }

    /**
     * The body of sampleOnce, run with the in-flight flag set.
     *
     * @returns {Promise<Snapshot|null>} The snapshot, or null when destroyed or a pause overtook it.
     */
    async _takeSample() {
        const fsRoot = this.fsRoot;
        const cpuBaselineEpoch = this._cpuBaselineEpoch;
        const takenAtUsec = this._nowUsec();
        const statPath = joinPath(fsRoot, PROC_STAT_PATH);
        const meminfoPath = joinPath(fsRoot, PROC_MEMINFO_PATH);
        const cpuPressurePath = joinPath(fsRoot, CPU_PRESSURE_PATH);
        const memoryPressurePath = joinPath(fsRoot, MEMORY_PRESSURE_PATH);
        const ioPressurePath = joinPath(fsRoot, IO_PRESSURE_PATH);
        const blockDevicesPath = joinPath(fsRoot, BLOCK_DEVICES_PATH);
        const [statRead, meminfoRead, cpuPressureRead, memoryPressureRead, ioPressureRead, zramRead] =
            await Promise.allSettled([
                readTextFile(statPath, this._cancellable),
                readTextFile(meminfoPath, this._cancellable),
                readTextFile(cpuPressurePath, this._cancellable),
                readTextFile(memoryPressurePath, this._cancellable),
                readTextFile(ioPressurePath, this._cancellable),
                readZramDevices(fsRoot, this._cancellable),
            ]);
        if (this._isDestroyed || cpuBaselineEpoch !== this._cpuBaselineEpoch)
            return null;

        const procStat = this._parseSettledRead(statRead, statPath, parseUsableProcStat);
        const meminfo = this._parseSettledRead(meminfoRead, meminfoPath, parseMeminfo);
        const zramDevices = this._parseSettledRead(zramRead, blockDevicesPath, devices => devices);
        const pressureAvg10 = {
            cpu: this._parseSettledRead(cpuPressureRead, cpuPressurePath, parsePressureSomeAvg10),
            memory: this._parseSettledRead(memoryPressureRead, memoryPressurePath, parsePressureSomeAvg10),
            io: this._parseSettledRead(ioPressureRead, ioPressurePath, parsePressureSomeAvg10),
        };
        const memory = meminfo === null ? null
            : this._requirePart(memoryUsage(meminfo), `cannot find MemTotal and MemAvailable in ${meminfoPath}`);
        const missingSwapMessage = `cannot find SwapTotal and SwapFree in ${meminfoPath}`;
        const swap = meminfo === null || zramDevices === null ? null
            : this._requirePart(swapSummary(meminfo, zramDevices), missingSwapMessage);
        const previousProcStat = this._previousProcStat;
        const cpuBusyPercent = previousProcStat === null || procStat === null ? null
            : fractionToPercent(cpuBusyFraction(previousProcStat.aggregate, procStat.aggregate));
        const requiredParts = [procStat, memory, swap, pressureAvg10.cpu, pressureAvg10.memory, pressureAvg10.io];
        // Everything that can throw (the clock label included) runs before any state below is changed.
        const snapshot = {
            takenAtUsec,
            takenAtClockLabel: this._clockLabel(),
            cpuBusyPercent,
            cpuClusters: cpuBusyPercent === null ? null : this._clusterPercents(previousProcStat, procStat),
            memory,
            swap,
            pressureAvg10,
            apps: this._latestAppRanking,
            isComplete: requiredParts.every(part => part !== null),
        };

        if (procStat !== null)
            this._recordProcStat(procStat);
        this._recordHistory(snapshot);
        this._notifyListeners(snapshot);
        return snapshot;
    }

    /**
     * Busy percent of each core type between two /proc/stat readings.
     *
     * @param {{perCpu: Map<number, object>}} previousProcStat - The earlier reading.
     * @param {{perCpu: Map<number, object>}} procStat - The later reading.
     * @returns {{performancePercent: number|null, efficiencyPercent: number|null}|null} Null on a single-cluster
     *     machine.
     */
    _clusterPercents(previousProcStat, procStat) {
        if (this._clusterMap === null)
            return null;
        const {performanceCpus, efficiencyCpus} = this._clusterMap;
        return {
            performancePercent: fractionToPercent(
                clusterBusyFraction(previousProcStat.perCpu, procStat.perCpu, performanceCpus)),
            efficiencyPercent: fractionToPercent(
                clusterBusyFraction(previousProcStat.perCpu, procStat.perCpu, efficiencyCpus)),
        };
    }

    /**
     * Keeps a /proc/stat reading as the next baseline and refreshes the CPU count from it.
     *
     * @param {{perCpu: Map<number, object>}} procStat - A parsed reading.
     * @returns {void}
     */
    _recordProcStat(procStat) {
        this._previousProcStat = procStat;
        if (procStat.perCpu.size > 0)
            this._cpuCount = procStat.perCpu.size;
    }

    /**
     * Appends a snapshot to the histories and makes it the latest.
     *
     * @param {Snapshot} snapshot - The new snapshot.
     * @returns {void}
     */
    _recordHistory(snapshot) {
        const {cpuBusyPercent, memory} = snapshot;
        const hasMemoryFraction = memory !== null && memory.totalBytes > 0;
        this._cpuHistory.push(cpuBusyPercent === null ? null : cpuBusyPercent / PERCENT_SCALE);
        this._memoryHistory.push(hasMemoryFraction ? memory.usedBytes / memory.totalBytes : null);
        this._latestSnapshot = snapshot;
        if (cpuBusyPercent !== null || memory !== null)
            this._lastGoodClockLabel = snapshot.takenAtClockLabel;
    }

    /**
     * Calls every listener with a snapshot. One that throws is logged, and the rest still run.
     *
     * @param {Snapshot} snapshot - The new snapshot.
     * @returns {void}
     */
    _notifyListeners(snapshot) {
        for (const [listenerId, listener] of [...this._listeners]) {
            // A listener may destroy the sampler or remove a later listener.
            if (this._isDestroyed)
                return;
            if (!this._listeners.has(listenerId))
                continue;
            try {
                listener(snapshot);
            } catch (error) {
                this._logRateLimited(`listener failed: ${describeError(error)}`);
            }
        }
    }

    /**
     * The body of scanAppsOnce, run with the in-flight flag set.
     *
     * @returns {Promise<AppRanking|null>} The ranking, or null when destroyed or the scan was turned off meanwhile.
     */
    async _scanApps() {
        const fsRoot = this.fsRoot;
        const appBaselineEpoch = this._appBaselineEpoch;
        const takenAtUsec = this._nowUsec();
        const cgroupRootPath = joinPath(fsRoot, CGROUP_ROOT_PATH);
        const leafRelativePaths = await this._listCgroupLeaves(cgroupRootPath);
        if (this._isDestroyed || appBaselineEpoch !== this._appBaselineEpoch)
            return null;
        const rootCpuStatPath = joinPath(cgroupRootPath, CGROUP_CPU_STAT_FILE);
        const meminfoPath = joinPath(fsRoot, PROC_MEMINFO_PATH);
        const [rootCpuStatRead, meminfoRead, ...leafReads] = await Promise.allSettled([
            readTextFile(rootCpuStatPath, this._cancellable),
            readTextFile(meminfoPath, this._cancellable),
            ...leafRelativePaths.map(leafRelativePath =>
                readCgroupLeaf(joinPath(cgroupRootPath, leafRelativePath), this._cancellable)),
        ]);
        if (this._isDestroyed || appBaselineEpoch !== this._appBaselineEpoch)
            return null;

        const rootUsageUsec = this._parseSettledRead(rootCpuStatRead, rootCpuStatPath, parseCpuStatUsageUsec);
        const meminfo = this._parseSettledRead(meminfoRead, meminfoPath, parseMeminfo);
        const memory = meminfo === null ? null
            : this._requirePart(memoryUsage(meminfo), `cannot find MemTotal and MemAvailable in ${meminfoPath}`);
        const {usageUsecByCgroup, memoryBytesByCgroup} = this._collectLeafReadings(leafRelativePaths, leafReads);
        const previousScan = this._previousAppScan;
        const hasRootDelta = previousScan !== null && previousScan.rootUsageUsec !== null && rootUsageUsec !== null;
        // Everything that can throw (resolveAppName included) runs before any state below is changed.
        const ranking = rankApps({
            previousUsageUsec: previousScan === null ? new Map() : previousScan.usageUsecByCgroup,
            currentUsageUsec: usageUsecByCgroup,
            memoryBytesByCgroup,
            // The real time between the two scans, never the nominal interval: ticks can run late.
            elapsedUsec: previousScan === null ? 0 : takenAtUsec - previousScan.takenAtUsec,
            cpuCount: this._cpuCount ?? 0,
            rootCpuDeltaUsec: hasRootDelta ? rootUsageUsec - previousScan.rootUsageUsec : null,
            memoryUsedBytes: memory === null ? null : memory.usedBytes,
            nameOfCgroup: cgroupPath => groupOfCgroup(cgroupPath, this._resolveAppName),
        });

        this._previousAppScan = {usageUsecByCgroup, rootUsageUsec, takenAtUsec};
        this._latestAppRanking = ranking;
        return ranking;
    }

    /**
     * Lists the cgroup leaves to rank: the children of the user service's app, session and background slices and
     * of system.slice, descending one level more into a child that is itself a slice. Leaves of a unit type that
     * never hosts an app (APP_SCAN_SKIPPED_UNIT_SUFFIXES) are left out at both depths, unread.
     *
     * @param {string} cgroupRootPath - Absolute path of the cgroup v2 root.
     * @returns {Promise<string[]>} Leaf paths relative to the cgroup root (stable across fsRoot changes); empty
     *     when destroyed meanwhile.
     */
    async _listCgroupLeaves(cgroupRootPath) {
        const parentRelativePaths = this._appScanParentPaths();
        const parentListings = await Promise.allSettled(parentRelativePaths.map(parentRelativePath =>
            listChildDirectoryNames(joinPath(cgroupRootPath, parentRelativePath), this._cancellable)));
        if (this._isDestroyed)
            return [];
        const leafRelativePaths = [];
        const subSliceRelativePaths = [];
        parentListings.forEach((parentListing, index) => {
            for (const childRelativePath of this._childPaths(parentListing, parentRelativePaths[index])) {
                if (childRelativePath.endsWith(SLICE_SUFFIX))
                    subSliceRelativePaths.push(childRelativePath);
                else if (canHostApp(childRelativePath))
                    leafRelativePaths.push(childRelativePath);
            }
        });
        const subSliceListings = await Promise.allSettled(subSliceRelativePaths.map(subSliceRelativePath =>
            listChildDirectoryNames(joinPath(cgroupRootPath, subSliceRelativePath), this._cancellable)));
        if (this._isDestroyed)
            return [];
        subSliceListings.forEach((subSliceListing, index) => {
            const childRelativePaths = this._childPaths(subSliceListing, subSliceRelativePaths[index]);
            leafRelativePaths.push(...childRelativePaths.filter(canHostApp));
        });
        return leafRelativePaths;
    }

    /**
     * The cgroups whose children an app scan ranks. Without a known uid only system.slice is scanned (initialize
     * has already logged why).
     *
     * @returns {string[]} Paths relative to the cgroup root.
     */
    _appScanParentPaths() {
        const parentRelativePaths = [];
        if (this._uid !== null) {
            const userSliceName = `user-${this._uid}.slice`;
            const userServiceName = `user@${this._uid}.service`;
            for (const sliceName of USER_SERVICE_SLICES)
                parentRelativePaths.push(joinPath(USER_SLICE, userSliceName, userServiceName, sliceName));
        }
        parentRelativePaths.push(SYSTEM_SLICE);
        return parentRelativePaths;
    }

    /**
     * Turns a settled directory listing into child paths. A missing directory is normal (systemd removes an empty
     * slice, and a scope can exit mid-scan); any other failure is logged.
     *
     * @param {PromiseSettledResult<string[]>} listing - The settled listChildDirectoryNames call.
     * @param {string} parentRelativePath - The listed directory, relative to the cgroup root.
     * @returns {string[]} Child paths relative to the cgroup root; empty on failure.
     */
    _childPaths(listing, parentRelativePath) {
        if (listing.status === 'rejected') {
            if (!isNotFoundError(listing.reason))
                this._logRateLimited(`cannot list cgroup ${parentRelativePath}: ${describeError(listing.reason)}`);
            return [];
        }
        return listing.value.map(childName => joinPath(parentRelativePath, childName));
    }

    /**
     * Gathers the leaves whose reads all succeeded. A leaf with any failed read is skipped from both rankings:
     * silently when a file is missing (the cgroup vanished between listing and reading), logged otherwise.
     *
     * @param {string[]} leafRelativePaths - Leaf paths relative to the cgroup root.
     * @param {Array<PromiseSettledResult<{usageUsec: number, memoryBytes: number}>>} leafReads - Same order.
     * @returns {{usageUsecByCgroup: Map<string, number>, memoryBytesByCgroup: Map<string, number>}} The readings.
     */
    _collectLeafReadings(leafRelativePaths, leafReads) {
        const usageUsecByCgroup = new Map();
        const memoryBytesByCgroup = new Map();
        leafReads.forEach((leafRead, index) => {
            const leafRelativePath = leafRelativePaths[index];
            if (leafRead.status === 'fulfilled') {
                usageUsecByCgroup.set(leafRelativePath, leafRead.value.usageUsec);
                memoryBytesByCgroup.set(leafRelativePath, leafRead.value.memoryBytes);
            } else if (!isNotFoundError(leafRead.reason)) {
                this._logRateLimited(`cannot read cgroup ${leafRelativePath}: ${describeError(leafRead.reason)}`);
            }
        });
        return {usageUsecByCgroup, memoryBytesByCgroup};
    }

    /**
     * Reads which CPUs are performance and which efficiency cores: the hybrid PMU lists, else cpu_capacity.
     *
     * @param {string} fsRoot - The filesystem root.
     * @returns {Promise<{performanceCpus: number[], efficiencyCpus: number[]}|null>} Null for a single-cluster
     *     machine, or when destroyed meanwhile.
     */
    async _readClusterMap(fsRoot) {
        const corePmuPath = joinPath(fsRoot, CORE_PMU_CPUS_PATH);
        const atomPmuPath = joinPath(fsRoot, ATOM_PMU_CPUS_PATH);
        const [corePmuRead, atomPmuRead] = await Promise.allSettled([
            readTextFile(corePmuPath, this._cancellable), readTextFile(atomPmuPath, this._cancellable),
        ]);
        if (this._isDestroyed)
            return null;
        const corePmuCpus = this._cpuListFromRead(corePmuRead, corePmuPath);
        const atomPmuCpus = this._cpuListFromRead(atomPmuRead, atomPmuPath);
        const hasHybridPmu = corePmuCpus.length > 0 && atomPmuCpus.length > 0;
        const capacities = hasHybridPmu ? new Map() : await this._readCpuCapacities(fsRoot);
        if (this._isDestroyed)
            return null;
        // The capacity fallback walks CPUs 0..cpuCount−1, so cpuCount is one past the highest CPU with a capacity.
        const cpuCount = capacities.size === 0 ? 0 : Math.max(...capacities.keys()) + 1;
        return buildClusterMap({corePmuCpus, atomPmuCpus, capacities, cpuCount});
    }

    /**
     * Parses a settled PMU CPU-list read. A missing list is normal (no hybrid cores); an unreadable or malformed
     * one is logged. Either way it counts as empty, so the caller falls back to cpu_capacity.
     *
     * @param {PromiseSettledResult<string>} settledRead - The settled read.
     * @param {string} path - The file read, for the log line.
     * @returns {number[]} CPU numbers; empty on any failure.
     */
    _cpuListFromRead(settledRead, path) {
        if (settledRead.status === 'rejected') {
            if (!isNotFoundError(settledRead.reason))
                this._logRateLimited(`cannot read ${path}: ${describeError(settledRead.reason)}`);
            return [];
        }
        try {
            return parseCpuList(settledRead.value);
        } catch (error) {
            this._logRateLimited(`cannot parse ${path}: ${describeError(error)}`);
            return [];
        }
    }

    /**
     * Reads cpu_capacity of every CPU. A CPU without one is normal (most non-hybrid machines have none).
     *
     * @param {string} fsRoot - The filesystem root.
     * @returns {Promise<Map<number, number>>} Capacity by CPU number; empty on failure or when destroyed.
     */
    async _readCpuCapacities(fsRoot) {
        const cpuDevicesPath = joinPath(fsRoot, CPU_DEVICES_PATH);
        const [deviceListing] = await Promise.allSettled([listChildNames(cpuDevicesPath, this._cancellable)]);
        if (this._isDestroyed)
            return new Map();
        if (deviceListing.status === 'rejected') {
            this._logRateLimited(`cannot list ${cpuDevicesPath}: ${describeError(deviceListing.reason)}`);
            return new Map();
        }
        const cpuNumbers = deviceListing.value
            .map(deviceName => CPU_DEVICE_NAME_PATTERN.exec(deviceName))
            .filter(match => match !== null)
            .map(match => parseInt(match[1], DECIMAL_RADIX));
        const capacityPaths = cpuNumbers.map(cpuNumber =>
            joinPath(cpuDevicesPath, `cpu${cpuNumber}`, CPU_CAPACITY_FILE));
        const capacityReads = await Promise.allSettled(capacityPaths.map(capacityPath =>
            readTextFile(capacityPath, this._cancellable)));
        if (this._isDestroyed)
            return new Map();
        const capacities = new Map();
        capacityReads.forEach((capacityRead, index) => {
            const isAbsent = capacityRead.status === 'rejected' && isNotFoundError(capacityRead.reason);
            const capacity = isAbsent ? null
                : this._parseSettledRead(capacityRead, capacityPaths[index], parseSingleNumber);
            if (capacity !== null)
                capacities.set(cpuNumbers[index], capacity);
        });
        return capacities;
    }

    /**
     * Parses a settled read, logging a failed read or an unparseable file.
     *
     * @param {PromiseSettledResult<*>} settledRead - The settled read.
     * @param {string} path - What was read, for the log line.
     * @param {(contents: *) => *} parse - Parser returning null for unparseable contents.
     * @returns {*} The parsed value, or null on any failure.
     */
    _parseSettledRead(settledRead, path, parse) {
        if (settledRead.status === 'rejected') {
            this._logRateLimited(`cannot read ${path}: ${describeError(settledRead.reason)}`);
            return null;
        }
        const parsed = parse(settledRead.value);
        if (parsed === null)
            this._logRateLimited(`cannot parse ${path}`);
        return parsed;
    }

    /**
     * Passes a derived value through, logging when it is missing.
     *
     * @param {*} value - A value computed from a successful read, or null.
     * @param {string} failureMessage - What to log when it is null.
     * @returns {*} The value.
     */
    _requirePart(value, failureMessage) {
        if (value === null)
            this._logRateLimited(failureMessage);
        return value;
    }

    /**
     * Logs a message with the journal prefix, at most once per ERROR_LOG_REPEAT_INTERVAL_USEC for each distinct
     * message. Silent once destroyed. Entries old enough to log again are forgotten, so the table stays small.
     *
     * @param {string} message - The message, without the prefix.
     * @returns {void}
     */
    _logRateLimited(message) {
        if (this._isDestroyed)
            return;
        const nowUsec = this._nowUsec();
        const lastLoggedUsec = this._lastLoggedUsecByMessage.get(message);
        if (lastLoggedUsec !== undefined && nowUsec - lastLoggedUsec < ERROR_LOG_REPEAT_INTERVAL_USEC)
            return;
        for (const [loggedMessage, loggedAtUsec] of this._lastLoggedUsecByMessage) {
            if (nowUsec - loggedAtUsec >= ERROR_LOG_REPEAT_INTERVAL_USEC)
                this._lastLoggedUsecByMessage.delete(loggedMessage);
        }
        this._lastLoggedUsecByMessage.set(message, nowUsec);
        this._log(`${LOG_PREFIX} ${message}`);
    }
}
