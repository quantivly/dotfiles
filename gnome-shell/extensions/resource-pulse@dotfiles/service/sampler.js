// The sampler service's one source of numbers: synchronous reads of /proc, /sys and the cgroup tree on one GLib
// timer, in its own process (`gjs -m service/main.js` under systemd), never inside gnome-shell. It imports Gio,
// GioUnix, GLib, system, lib/ and service/fileIo.js only, so it runs under plain gjs.
//
// - Reads are synchronous (service/fileIo.js: Gio.File.load_contents, which reads to EOF whatever size kernfs
//   reports). A slow read delays only this process's next tick, and a synchronous scan can never be in flight across
//   ticks, so none of the in-shell sampler's batching, priorities or stall handling is needed here.
// - A tick samples, then runs the app scan when lib/cadence.js says one is due, then publishes one snapshot carrying
//   this tick's ranking. A watch start scans at once, outside the tick, and publishes again. No CPU ranking covers
//   less than MIN_CPU_RANKING_WINDOW_SECONDS.
// - A full garbage collection follows every app scan: without it, native memory piles up between collections.
// - Everything that can throw runs before state changes, and nothing a tick does can throw out of the timer callback.
//   A failure becomes "no data": a sample that throws publishes an all-null snapshot and a gap in the histories, and a
//   scan that throws drops its ranking.
// - Every failure is logged rate-limited by a stable template key, so a failure whose text varies (a count, a path, an
//   error) still logs once per ERROR_LOG_REPEAT_INTERVAL_USEC; one scan's cgroup failures become one line.
import Gio from 'gi://Gio';
import GioUnix from 'gi://GioUnix';
import GLib from 'gi://GLib';
import System from 'system';

import {
    APP_MEMORY_STAT_MIN_BYTES, APP_SCAN_SKIPPED_UNIT_SUFFIXES, CARD_HISTORY_SAMPLES, MIN_CPU_RANKING_WINDOW_SECONDS,
    SAMPLE_INTERVAL_SECONDS,
} from '../lib/constants.js';
import {RateLimitedLogger, describeError, describeErrorWithStack} from '../lib/errorLog.js';
import {
    parseMeminfo, parsePressureSomeAvg10, parseProcStat, parseProcSwaps, parseUid, parseZramMmStat,
} from '../lib/procParsers.js';
import {parseCpuStatUsageUsec, parseMemoryStatReclaimableBytes, parseSingleNumber} from '../lib/cgroupParsers.js';
import {buildClusterMap, clusterBusyFraction, cpuBusyFraction, parseCpuList} from '../lib/cpu.js';
import {memoryUsage, swapSummary, zramSwapDeviceNames} from '../lib/memory.js';
import {describeCgroup, displayNameFor, rankApps} from '../lib/apps.js';
import {armsWarmUp, decideAppScan, isTriggeredScan, pressureBandIndex} from '../lib/cadence.js';
import {RingBuffer} from '../lib/history.js';
import {listSubdirectoryNames, readFileToEnd} from './fileIo.js';

// Paths, relative to the sampler's fsRoot.
const PROC_STAT_PATH = 'proc/stat';
const PROC_MEMINFO_PATH = 'proc/meminfo';
const PROC_SWAPS_PATH = 'proc/swaps';
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
const ZRAM_MM_STAT_FILE = 'mm_stat';
const CPU_DEVICE_NAME_PATTERN = /^cpu(\d+)$/;
const CPU_CAPACITY_FILE = 'cpu_capacity';
const CGROUP_CPU_STAT_FILE = 'cpu.stat';
const CGROUP_MEMORY_CURRENT_FILE = 'memory.current';
const CGROUP_MEMORY_STAT_FILE = 'memory.stat';
/** The top-level slice of every user's session: never a scanned parent, since its users' slices are (ruling R22). */
const USER_SLICE = 'user.slice';
const SLICE_SUFFIX = '.slice';
/** The root cgroup's path relative to the cgroup root (joinPath drops it, leaving the root itself). */
const ROOT_CGROUP_RELATIVE_PATH = '';
/** How a failure log line names the root cgroup, whose path relative to the cgroup root is empty. */
const ROOT_CGROUP_LOG_NAME = 'the cgroup root';

const CLOCK_LABEL_FORMAT = '%H:%M';
const PERCENT_SCALE = 100;
const DECIMAL_RADIX = 10;
const USEC_PER_SECOND = 1_000_000;
const MIN_CPU_RANKING_WINDOW_USEC = MIN_CPU_RANKING_WINDOW_SECONDS * USEC_PER_SECOND;
/** The pressure part of a snapshot with no data. Spread into each snapshot, never shared. */
const NO_DATA_PRESSURE_AVG10 = {cpu: null, memory: null, io: null};
/**
 * The scan reasons a watch start acts on at once, outside the tick. A warm-up, burst or interval scan is paced by the
 * ticks: run here, a warm-up would follow the watch-start scan by milliseconds (a CPU window of almost nothing), and
 * rapid cover and uncover would scan inside the reveal cooldown. Before the first tick (reason "first") there is
 * nothing to reveal, and that tick scans anyway.
 */
const WATCH_START_SCAN_REASONS = ['watch-start'];
/**
 * The scan reasons a tick puts off by one tick when the previous scan is less than MIN_CPU_RANKING_WINDOW_SECONDS old:
 * a warm-up exists only to sharpen the CPU ranking, which over so short a window would be noise. It stays pending.
 */
const WINDOW_DEFERRED_SCAN_REASONS = ['warm-up'];

// Template keys of the rate-limited journal lines whose text varies (lib/errorLog.js).
const SAMPLE_FAILURE_LOG_KEY = 'sample failed';
const APP_SCAN_FAILURE_LOG_KEY = 'app scan failed';
const CGROUP_READ_FAILURES_LOG_KEY = 'cannot read cgroups';
const LISTENER_FAILURE_LOG_KEY = 'listener failed';
const TICK_FAILURE_LOG_KEY = 'tick failed';
const GARBAGE_COLLECTION_FAILURE_LOG_KEY = 'garbage collection failed';
const APP_NAME_LOOKUP_FAILURE_LOG_KEY = 'cannot look up app names';

/**
 * @typedef {object} AppRanking
 * @property {{groupKey: string, name: string, cpuPercent: number}|null} topCpu - The group using the most CPU, as a
 *     share of the whole machine (an app, or the CPU-only "kernel" and "short jobs"); null until two scans give a
 *     delta.
 * @property {{groupKey: string, name: string, memoryBytes: number}|null} topMemory - The real app holding the most
 *     memory that is not page cache; never "kernel" or "short jobs".
 * @property {Array<{groupKey: string, name: string, cpuPercent: number}>} cpuRanking - The groups using the most
 *     CPU, largest first, at most APP_RANKING_LENGTH; its first entry is topCpu, and it is empty when topCpu is
 *     null.
 * @property {Array<{groupKey: string, name: string, memoryBytes: number}>} memoryRanking - The real apps holding the
 *     most memory that is not page cache, largest first, at most APP_RANKING_LENGTH; its first entry is topMemory.
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
 * @property {{zramUsedBytes: number, zramRamBytes: number, diskBytes: number}|null} swap - Swap in use on zram
 *     areas (and the RAM those devices take) and on every other area, from /proc/swaps; null when /proc/swaps or
 *     one of the zram devices it lists could not be read.
 * @property {{cpu: number|null, memory: number|null, io: number|null}} pressureAvg10 - PSI `some avg10` percents.
 * @property {AppRanking|null} apps - The latest app scan; null before the first one and after a scan that threw.
 * @property {boolean} isComplete - True when every read and parse of this sample succeeded. A first sample's
 *     missing CPU delta is not a failure. A sample that threw publishes a no-data snapshot: every number null,
 *     apps null, and isComplete false.
 */

/**
 * @typedef {object} AppendedHistory
 * @property {number|null} cpu - The CPU busy fraction 0–1 a fast tick appended to cpuHistory; null for a gap.
 * @property {number|null} memory - The memory used fraction 0–1 it appended to memoryHistory; null for a gap.
 */

/**
 * Joins path segments with the platform separator; an empty segment is dropped.
 *
 * @param {...string} segments - Path pieces; a piece may itself contain separators.
 * @returns {string} The joined path.
 */
function joinPath(...segments) {
    return GLib.build_filenamev(segments);
}

/**
 * Looks up a `.desktop` id's display name: the service's stand-in for Shell.AppSystem, which exists only in the
 * shell. GioUnix, not Gio: gjs 1.88 warns that Gio.DesktopAppInfo moved there.
 *
 * @param {string} desktopId - For example 'org.gnome.Nautilus.desktop'.
 * @returns {string|null} The app's name; null for an unknown id.
 * @throws {Error} On an unexpected failure, which the sampler logs (see ServiceSampler._lookUpAppName).
 */
function resolveDesktopAppName(desktopId) {
    return GioUnix.DesktopAppInfo.new(desktopId)?.get_name() ?? null;
}

/**
 * Runs a full garbage collection, so the native memory behind a scan's objects is returned now, not whenever the
 * engine next decides to collect.
 *
 * @returns {void}
 */
function collectGarbageNow() {
    System.gc();
}

/**
 * Says whether an error is Gio's "no such file or directory".
 *
 * @param {*} error - A caught value.
 * @returns {boolean} True for G_IO_ERROR_NOT_FOUND.
 */
function isNotFoundError(error) {
    return error instanceof GLib.Error && error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.NOT_FOUND);
}

/**
 * Says whether a cgroup read failed because the cgroup is gone: no such file (it vanished before the open), or no
 * such device (ENODEV: kernfs answers a file already open in a removed cgroup that way, so a scope that exits
 * between open and read lands here).
 *
 * @param {*} error - A caught value.
 * @returns {boolean} True for G_IO_ERROR_NOT_FOUND and G_IO_ERROR_NO_SUCH_DEVICE.
 */
function isVanishedCgroupError(error) {
    return isNotFoundError(error) ||
        (error instanceof GLib.Error && error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.NO_SUCH_DEVICE));
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
 * Builds a snapshot from a sample's fields and an app ranking, in the order the Snapshot typedef lists them.
 *
 * @param {object} sampleFields - Every Snapshot field except apps.
 * @param {AppRanking|null} apps - The ranking to carry.
 * @returns {Snapshot} The snapshot.
 */
function buildSnapshot(sampleFields, apps) {
    const {
        takenAtUsec, takenAtClockLabel, cpuBusyPercent, cpuClusters, memory, swap, pressureAvg10, isComplete,
    } = sampleFields;
    return {takenAtUsec, takenAtClockLabel, cpuBusyPercent, cpuClusters, memory, swap, pressureAvg10, apps, isComplete};
}

/**
 * The cpu, memory and io pressure bands of a sample, in lib/cadence.js's order.
 *
 * @param {{cpu: number|null, memory: number|null, io: number|null}} pressureAvg10 - PSI `some avg10` percents.
 * @returns {Array<number|null>} One band index per kind, null for no data.
 */
function pressureBandsOf(pressureAvg10) {
    return [pressureAvg10.cpu, pressureAvg10.memory, pressureAvg10.io].map(pressureBandIndex);
}

/**
 * Ticks since an earlier tick, for lib/cadence.js.
 *
 * @param {number|null} earlierTickNumber - The earlier tick, or null for never.
 * @param {number} tickNumber - The tick now.
 * @returns {number|null} The difference; null (never undefined, which compares false with every number) for never.
 */
function ticksSince(earlierTickNumber, tickNumber) {
    return earlierTickNumber === null ? null : tickNumber - earlierTickNumber;
}

/**
 * A cumulative counter's change between two readings. A counter that went backwards belongs to a cgroup recreated at
 * the same path, so all of its current count is new (the rule lib/apps.js applies to leaves).
 *
 * @param {number} previousUsec - The earlier reading.
 * @param {number} currentUsec - The later reading.
 * @returns {number} The change, never negative.
 */
function counterDeltaUsec(previousUsec, currentUsec) {
    return currentUsec >= previousUsec ? currentUsec - previousUsec : currentUsec;
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

/**
 * Reads one cgroup leaf's CPU usage and its memory net of page cache. memory.stat is read only when memory.current
 * exceeds APP_MEMORY_STAT_MIN_BYTES; a smaller leaf is ranked uncorrected.
 *
 * @param {string} leafPath - Absolute path of the cgroup directory.
 * @param {(path: string) => string} readFile - Reads one file.
 * @returns {{usageUsec: number, memoryBytes: number}} The leaf's readings.
 * @throws {Error} When a required file cannot be read (the cgroup may have vanished) or parsed.
 */
function readCgroupLeaf(leafPath, readFile) {
    const cpuStatPath = joinPath(leafPath, CGROUP_CPU_STAT_FILE);
    const usageUsec = parseCpuStatUsageUsec(readFile(cpuStatPath));
    if (usageUsec === null)
        throw new Error(`cannot parse ${cpuStatPath}`);
    const memoryCurrentPath = joinPath(leafPath, CGROUP_MEMORY_CURRENT_FILE);
    const memoryCurrentBytes = parseSingleNumber(readFile(memoryCurrentPath));
    if (memoryCurrentBytes === null)
        throw new Error(`cannot parse ${memoryCurrentPath}`);
    if (memoryCurrentBytes <= APP_MEMORY_STAT_MIN_BYTES)
        return {usageUsec, memoryBytes: memoryCurrentBytes};
    const memoryStatPath = joinPath(leafPath, CGROUP_MEMORY_STAT_FILE);
    const reclaimableBytes = parseMemoryStatReclaimableBytes(readFile(memoryStatPath));
    if (reclaimableBytes === null)
        throw new Error(`cannot parse ${memoryStatPath}`);
    return {usageUsec, memoryBytes: Math.max(0, memoryCurrentBytes - reclaimableBytes)};
}

/**
 * The root cgroup's CPU delta between two scans.
 *
 * @param {object|null} previousScan - The previous scan's readings, or null.
 * @param {object} currentScan - This scan's readings.
 * @returns {number|null} The delta, or null when either scan could not read the root.
 */
function rootCpuDeltaUsec(previousScan, currentScan) {
    if (previousScan === null || previousScan.rootUsageUsec === null || currentScan.rootUsageUsec === null)
        return null;
    return currentScan.rootUsageUsec - previousScan.rootUsageUsec;
}

/**
 * Each scanned parent's CPU delta, for the parents read in both scans. A parent this scan could not list has leaves
 * it cannot see, whose CPU would read as "short jobs" (or, with the parent left out, as "kernel"); so unless every
 * parent was listed, the map is empty and rankApps ranks neither.
 *
 * @param {object|null} previousScan - The previous scan's readings, or null.
 * @param {object} currentScan - This scan's readings.
 * @returns {Map<string, number>} Delta by parent path relative to the cgroup root.
 */
function parentCpuDeltasUsec(previousScan, currentScan) {
    const deltasUsec = new Map();
    if (previousScan === null || !currentScan.isEveryParentFullyListed)
        return deltasUsec;
    for (const [parentPath, currentUsec] of currentScan.parentUsageUsecByPath) {
        const previousUsec = previousScan.parentUsageUsecByPath.get(parentPath);
        if (previousUsec !== undefined)
            deltasUsec.set(parentPath, counterDeltaUsec(previousUsec, currentUsec));
    }
    return deltasUsec;
}

/**
 * The parents whose every leaf this scan knows: listed completely, and each leaf read or seen to vanish. The next scan
 * counts a new leaf in full only under one of these. A leaf that exists but could not be read (EACCES, EIO, a parse
 * failure) is missing from this scan's readings, so in the next it would look new and count its whole lifetime's
 * usage: its parent is left out, its leaves are skipped next time, and their CPU stays in "short jobs".
 *
 * @param {{fullyListedParentPaths: Set<string>, parentOfLeaf: Map<string, string>}} cgroupTree - The scan's listing.
 * @param {string[]} unreadLeafPaths - The leaves that exist but could not be read.
 * @returns {Set<string>} Parent paths relative to the cgroup root.
 */
function fullyAccountedParentPaths(cgroupTree, unreadLeafPaths) {
    const parentsWithUnreadLeaves = new Set(unreadLeafPaths.map(leafPath => cgroupTree.parentOfLeaf.get(leafPath)));
    const accountedParentPaths = [...cgroupTree.fullyListedParentPaths]
        .filter(parentPath => !parentsWithUnreadLeaves.has(parentPath));
    return new Set(accountedParentPaths);
}

/** The cgroup reads and listings that failed in one app scan, logged together as one line. */
class CgroupReadFailures {
    constructor() {
        this.count = 0;
        this._firstRelativePath = null;
        this._firstError = null;
    }

    /**
     * Counts a failure, keeping the first one's path and error for the log line.
     *
     * @param {string} relativePath - What failed (a cgroup, a directory or a file), relative to the cgroup root.
     * @param {*} error - What the read or listing threw.
     * @returns {void}
     */
    note(relativePath, error) {
        if (this.count === 0) {
            this._firstRelativePath = relativePath;
            this._firstError = error;
        }
        this.count++;
    }

    /**
     * The journal line for every failure counted.
     *
     * @returns {string} For example 'cannot read 3 cgroups, first: system.slice/x.service: Permission denied'; a
     *     first failure at the root cgroup itself names it ROOT_CGROUP_LOG_NAME.
     */
    describe() {
        const firstErrorText = describeError(this._firstError);
        const isRootFirst = this._firstRelativePath === ROOT_CGROUP_RELATIVE_PATH;
        const firstPathText = isRootFirst ? ROOT_CGROUP_LOG_NAME : this._firstRelativePath;
        return `cannot read ${this.count} cgroups, first: ${firstPathText}: ${firstErrorText}`;
    }
}

/** Samples CPU, memory, swap and pressure on a timer, scans apps on lib/cadence.js's cadence, and tells listeners. */
export class ServiceSampler {
    /**
     * @param {object} [options] - Everything injectable, so tests can run against fixture trees; each has a real
     *     default.
     * @param {string} [options.fsRoot] - Root under which proc/ and sys/ are read; public, tests reassign it.
     * @param {(path: string) => string} [options.readFile] - Reads a whole file; throws a GLib.Error when it cannot.
     * @param {(path: string) => string[]} [options.listDirectoryNames] - Names the subdirectories of a directory;
     *     throws a GLib.Error when it cannot list it.
     * @param {() => number} [options.nowUsec] - Monotonic microseconds.
     * @param {() => string} [options.clockLabel] - Wall-clock 'HH:MM'.
     * @param {(desktopId: string) => string|null} [options.resolveAppName] - Real name of a `.desktop` id; null for
     *     an unknown one. A throw is logged, and the app keeps the name its unit gives. Each id is looked up once.
     * @param {() => void} [options.collectGarbage] - Runs a full garbage collection, after each app scan.
     * @param {(line: string) => void} [options.logWriter] - Where rate-limited journal lines go.
     * @param {number} [options.sampleIntervalSeconds] - Seconds between timer ticks. Tests change it; the scan
     *     cadence counts ticks, so the service always runs at SAMPLE_INTERVAL_SECONDS.
     */
    constructor({
        fsRoot = '/',
        readFile = readFileToEnd,
        listDirectoryNames = listSubdirectoryNames,
        nowUsec = () => GLib.get_monotonic_time(),
        clockLabel = () => GLib.DateTime.new_now_local().format(CLOCK_LABEL_FORMAT),
        resolveAppName = resolveDesktopAppName,
        collectGarbage = collectGarbageNow,
        logWriter = line => console.warn(line),
        sampleIntervalSeconds = SAMPLE_INTERVAL_SECONDS,
    } = {}) {
        this.fsRoot = fsRoot;
        this._readFile = readFile;
        this._listDirectoryNames = listDirectoryNames;
        this._nowUsec = nowUsec;
        this._clockLabel = clockLabel;
        this._resolveAppName = resolveAppName;
        this._collectGarbage = collectGarbage;
        this._errorLog = new RateLimitedLogger({nowUsec, write: logWriter});
        this._sampleIntervalSeconds = sampleIntervalSeconds;

        this._isDestroyed = false;
        this._isStarted = false;
        this._timeoutSourceId = null;
        this._nextTickNumber = 0;

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
        // True while the latest snapshot is a no-data one (its sample threw): a watch start then publishes nothing.
        this._isLatestSnapshotNoData = false;
        // Resolved app names by desktop id, misses (null) included, for as long as the service runs: an app's
        // .desktop file is read once, not on every scan.
        this._appNameByDesktopId = new Map();

        // What lib/cadence.js's decideAppScan reads. Ticks since a scan are a difference of tick numbers, and null
        // (never undefined, which compares false with every number, so nothing would ever scan) means never.
        this._isDetailWatched = false;
        this._latestTickNumber = null;
        this._lastAppScanTickNumber = null;
        this._lastTriggeredScanTickNumber = null;
        this._isWarmUpPending = false;
        this._lastAppScanReason = null;
        this._cpuBusyPercentAtLastScan = null;
        this._pressureBandsAtLastScan = pressureBandsOf(NO_DATA_PRESSURE_AVG10);
    }

    /** @returns {Snapshot|null} The most recent snapshot, or null before the first. */
    get latestSnapshot() {
        return this._latestSnapshot;
    }

    /** @returns {string|null} 'HH:MM' of the last snapshot with CPU or memory data. */
    get lastGoodClockLabel() {
        return this._lastGoodClockLabel;
    }

    /** @returns {RingBuffer} CPU busy fractions 0–1, null for no data, oldest first: one per fast tick. */
    get cpuHistory() {
        return this._cpuHistory;
    }

    /** @returns {RingBuffer} Memory used fractions 0–1, null for no data, oldest first: one per fast tick. */
    get memoryHistory() {
        return this._memoryHistory;
    }

    /** @returns {string|null} Why the latest app scan ran (a lib/cadence.js reason), or null before the first. */
    get lastAppScanReason() {
        return this._lastAppScanReason;
    }

    /**
     * Reads what does not change while the service runs: the uid, the CPU count and the cluster map. Never throws
     * for a read or parse failure; each one is logged and leaves its value unknown.
     *
     * The CPU count is the number of per-CPU lines in /proc/stat. Every later successful sample refreshes it, so
     * a failed read here recovers on its own.
     *
     * @returns {void}
     */
    initialize() {
        if (this._isDestroyed)
            return;
        const fsRoot = this.fsRoot;
        this._uid = this._readAndParse(joinPath(fsRoot, PROC_SELF_STATUS_PATH), parseUid);
        const procStat = this._readAndParse(joinPath(fsRoot, PROC_STAT_PATH), parseUsableProcStat);
        if (procStat !== null && procStat.perCpu.size > 0)
            this._cpuCount = procStat.perCpu.size;
        this._clusterMap = this._readClusterMap(fsRoot);
    }

    /**
     * Starts the timer and runs its first tick at once, so memory and swap show without waiting an interval (CPU
     * needs a second sample). Calling it again while started adds nothing; once destroyed nothing runs.
     *
     * @returns {void}
     */
    start() {
        this._isStarted = true;
        this._syncTimer();
    }

    /**
     * Stops the timer.
     *
     * @returns {void}
     */
    stop() {
        this._isStarted = false;
        this._syncTimer();
    }

    /**
     * Stops everything for good: the timer, and every listener.
     *
     * @returns {void}
     */
    destroy() {
        if (this._isDestroyed)
            return;
        this._isDestroyed = true;
        this.stop();
        this._listeners.clear();
    }

    /**
     * Says whether a client holds a detail watch, which sets the scan cadence (lib/cadence.js). A watch that starts
     * scans at once, outside the tick, and publishes a snapshot with the new ranking (see _scanForWatchStart); the
     * warm-up scan follows on the next tick. It does not scan inside the reveal cooldown, nor less than
     * MIN_CPU_RANKING_WINDOW_SECONDS after the last scan, and publishes nothing after a tick that had no data. Ending
     * a watch only changes the cadence: the ranking stays.
     *
     * @param {boolean} isWatched - True while any client holds a watch.
     * @returns {void}
     */
    setDetailWatched(isWatched) {
        if (this._isDestroyed)
            return;
        const isWatchStarting = isWatched && !this._isDetailWatched;
        this._isDetailWatched = isWatched;
        if (isWatchStarting)
            this._scanForWatchStart();
    }

    /**
     * Adds a callback for each published snapshot.
     *
     * @param {(snapshot: Snapshot, appendedHistory: AppendedHistory|null) => void} callback - Called with every
     *     snapshot: after each fast tick, with the history values that tick appended, and after a watch start's scan,
     *     with null (it appends nothing to the histories).
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
     * Does one tick's work: a fast sample, then an app scan when lib/cadence.js says one is due, then one published
     * snapshot that carries this tick's ranking, then a garbage collection when a scan ran. A sample that throws
     * publishes no data (and skips the scan), and a scan that throws drops the ranking, so this does not throw.
     *
     * @param {number} tickNumber - The timer's tick count, rising by one per tick: the cadence counts ticks as the
     *     difference of two tick numbers.
     * @returns {void}
     */
    runTick(tickNumber) {
        if (this._isDestroyed)
            return;
        this._latestTickNumber = tickNumber;
        let fastSample;
        try {
            fastSample = this._takeFastSample();
        } catch (error) {
            this._publishNoDataSnapshot(`sample failed: ${describeErrorWithStack(error)}`);
            return;
        }
        if (fastSample.procStat !== null)
            this._recordProcStat(fastSample.procStat);
        const didScan = this._scanAppsIfDue(tickNumber, fastSample.fields);
        this._isLatestSnapshotNoData = false;
        this._publishTickSnapshot(buildSnapshot(fastSample.fields, this._latestAppRanking));
        if (didScan)
            this._collectGarbageAfterScan();
    }

    /**
     * Adds the timer source when it should run and has none, running its first tick at once, and removes it when
     * it should not run.
     *
     * @returns {void}
     */
    _syncTimer() {
        const shouldRun = this._isStarted && !this._isDestroyed;
        if (shouldRun && this._timeoutSourceId === null) {
            this._timeoutSourceId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, this._sampleIntervalSeconds,
                () => this._onTimeout());
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
     * Runs the next tick so that it cannot throw out of the timer callback, where a throw would end the GLib source
     * silently. runTick does not throw today; should it, the failure is logged, and a failure of that logging is
     * dropped, since there is nowhere left to report it and the timer must go on.
     *
     * @returns {void}
     */
    _runNextTick() {
        const tickNumber = this._nextTickNumber++;
        try {
            this.runTick(tickNumber);
        } catch (error) {
            try {
                this._logRateLimited(`tick failed: ${describeErrorWithStack(error)}`, TICK_FAILURE_LOG_KEY);
            } catch {
                // The log writer itself is failing; the next tick still has to run.
            }
        }
    }

    /**
     * Reads the fast tick's files and works out every snapshot field but apps. Everything that can throw (the clock
     * label included) runs here, before any state is changed.
     *
     * @returns {{fields: object, procStat: object|null}} The snapshot fields, and the /proc/stat reading to keep as
     *     the next CPU baseline.
     */
    _takeFastSample() {
        const fsRoot = this.fsRoot;
        const takenAtUsec = this._nowUsec();
        const {procStat, memory, swap, pressureAvg10} = this._readFastTickFiles(fsRoot);
        const previousProcStat = this._previousProcStat;
        const cpuBusyPercent = previousProcStat === null || procStat === null ? null
            : fractionToPercent(cpuBusyFraction(previousProcStat.aggregate, procStat.aggregate));
        const requiredParts = [procStat, memory, swap, pressureAvg10.cpu, pressureAvg10.memory, pressureAvg10.io];
        const fields = {
            takenAtUsec,
            takenAtClockLabel: this._clockLabel(),
            cpuBusyPercent,
            cpuClusters: cpuBusyPercent === null ? null : this._clusterPercents(previousProcStat, procStat),
            memory,
            swap,
            pressureAvg10,
            isComplete: requiredParts.every(part => part !== null),
        };
        return {fields, procStat};
    }

    /**
     * Reads and parses /proc/stat, meminfo, swaps, the three pressure files and the mm_stat of each zram device that
     * /proc/swaps lists. Any failed read or parse is logged and gives its part no data.
     *
     * @param {string} fsRoot - The filesystem root.
     * @returns {{procStat: object|null, memory: object|null, swap: object|null, pressureAvg10: object}} The parts.
     */
    _readFastTickFiles(fsRoot) {
        const meminfoPath = joinPath(fsRoot, PROC_MEMINFO_PATH);
        const procStat = this._readAndParse(joinPath(fsRoot, PROC_STAT_PATH), parseUsableProcStat);
        const meminfo = this._readAndParse(meminfoPath, parseMeminfo);
        const swapAreas = this._readAndParse(joinPath(fsRoot, PROC_SWAPS_PATH), parseProcSwaps);
        const zramDevices = swapAreas === null ? null : this._readZramSwapDevices(fsRoot, swapAreas);
        const pressureAvg10 = {
            cpu: this._readAndParse(joinPath(fsRoot, CPU_PRESSURE_PATH), parsePressureSomeAvg10),
            memory: this._readAndParse(joinPath(fsRoot, MEMORY_PRESSURE_PATH), parsePressureSomeAvg10),
            io: this._readAndParse(joinPath(fsRoot, IO_PRESSURE_PATH), parsePressureSomeAvg10),
        };
        const memory = meminfo === null ? null
            : this._requirePart(memoryUsage(meminfo), `cannot find MemTotal and MemAvailable in ${meminfoPath}`);
        const swap = zramDevices === null ? null : swapSummary(swapAreas, zramDevices);
        return {procStat, memory, swap, pressureAvg10};
    }

    /**
     * Reads mm_stat of the zram devices that are swap areas, by the names /proc/swaps gives them; /sys/block is
     * never listed.
     *
     * @param {string} fsRoot - The filesystem root.
     * @param {Array<{filename: string}>} swapAreas - parseProcSwaps output.
     * @returns {Array<{deviceName: string, storedBytes: number, ramBytes: number}>|null} One entry per zram swap
     *     device (empty without one); null when any of them could not be read or parsed (logged).
     */
    _readZramSwapDevices(fsRoot, swapAreas) {
        const zramDevices = [];
        for (const deviceName of zramSwapDeviceNames(swapAreas)) {
            const mmStatPath = joinPath(fsRoot, BLOCK_DEVICES_PATH, deviceName, ZRAM_MM_STAT_FILE);
            const zramDevice = this._readAndParse(mmStatPath, parseZramMmStat);
            if (zramDevice === null)
                return null;
            zramDevices.push({deviceName, ...zramDevice});
        }
        return zramDevices;
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
     * Publishes a fast tick's snapshot: appends it to the histories, makes it the latest and tells listeners.
     *
     * @param {Snapshot} snapshot - The tick's snapshot.
     * @returns {void}
     */
    _publishTickSnapshot(snapshot) {
        const appendedHistory = this._recordHistory(snapshot);
        this._notifyListeners(snapshot, appendedHistory);
    }

    /**
     * Publishes the no-data state after a sample threw: an all-null, incomplete snapshot and a gap in both
     * histories, so no surface goes on showing the last good numbers as live. The failure is logged last, so the
     * listeners hear about it even if logging fails. lastGoodClockLabel is left alone (the snapshot has no data), so
     * "no data since" still names the last good sample.
     *
     * @param {string} failureMessage - What went wrong, for the journal.
     * @returns {void}
     */
    _publishNoDataSnapshot(failureMessage) {
        const noDataFields = {
            takenAtUsec: callOrNull(this._nowUsec),
            takenAtClockLabel: callOrNull(this._clockLabel),
            cpuBusyPercent: null,
            cpuClusters: null,
            memory: null,
            swap: null,
            pressureAvg10: {...NO_DATA_PRESSURE_AVG10},
            isComplete: false,
        };
        this._isLatestSnapshotNoData = true;
        this._publishTickSnapshot(buildSnapshot(noDataFields, null));
        this._logRateLimited(failureMessage, SAMPLE_FAILURE_LOG_KEY);
    }

    /**
     * Appends a snapshot to the histories and makes it the latest.
     *
     * @param {Snapshot} snapshot - The new snapshot.
     * @returns {AppendedHistory} The values appended.
     */
    _recordHistory(snapshot) {
        const {cpuBusyPercent, memory} = snapshot;
        const hasMemoryFraction = memory !== null && memory.totalBytes > 0;
        const appendedHistory = {
            cpu: cpuBusyPercent === null ? null : cpuBusyPercent / PERCENT_SCALE,
            memory: hasMemoryFraction ? memory.usedBytes / memory.totalBytes : null,
        };
        this._cpuHistory.push(appendedHistory.cpu);
        this._memoryHistory.push(appendedHistory.memory);
        this._latestSnapshot = snapshot;
        if (cpuBusyPercent !== null || memory !== null)
            this._lastGoodClockLabel = snapshot.takenAtClockLabel;
        return appendedHistory;
    }

    /**
     * Calls every listener with a snapshot. One that throws is logged, and the rest still run.
     *
     * @param {Snapshot} snapshot - The new snapshot.
     * @param {AppendedHistory|null} appendedHistory - What a fast tick appended to the histories; null otherwise.
     * @returns {void}
     */
    _notifyListeners(snapshot, appendedHistory) {
        for (const [listenerId, listener] of [...this._listeners]) {
            // A listener may destroy the sampler or remove a later listener.
            if (this._isDestroyed)
                return;
            if (!this._listeners.has(listenerId))
                continue;
            try {
                listener(snapshot, appendedHistory);
            } catch (error) {
                this._logRateLimited(`listener failed: ${describeError(error)}`, LISTENER_FAILURE_LOG_KEY);
            }
        }
    }

    /**
     * The state lib/cadence.js's decideAppScan reads, at a tick and for a sample.
     *
     * @param {number} tickNumber - The tick deciding (for a watch start, the latest tick run).
     * @param {{cpuBusyPercent: number|null, pressureAvg10: object}} sampleFields - That tick's sample.
     * @param {boolean} watchStartedThisTick - True only for a watch start's own decision.
     * @returns {object} The decideAppScan state.
     */
    _cadenceState(tickNumber, sampleFields, watchStartedThisTick) {
        return {
            isWatched: this._isDetailWatched,
            watchStartedThisTick,
            ticksSinceLastScan: ticksSince(this._lastAppScanTickNumber, tickNumber),
            warmUpPending: this._isWarmUpPending,
            ticksSinceTriggeredScan: ticksSince(this._lastTriggeredScanTickNumber, tickNumber),
            cpuBusyPercentNow: sampleFields.cpuBusyPercent,
            cpuBusyPercentAtLastScan: this._cpuBusyPercentAtLastScan,
            pressureBandsNow: pressureBandsOf(sampleFields.pressureAvg10),
            pressureBandsAtLastScan: this._pressureBandsAtLastScan,
        };
    }

    /**
     * Runs the app scan when lib/cadence.js says one is due at this tick. A warm-up due less than
     * MIN_CPU_RANKING_WINDOW_SECONDS after the previous scan waits a tick (WINDOW_DEFERRED_SCAN_REASONS): nothing is
     * recorded, so it is still pending at the next tick.
     *
     * @param {number} tickNumber - The tick.
     * @param {object} sampleFields - The tick's sample (its CPU and pressure feed the burst rule; its time measures the
     *     window).
     * @returns {boolean} True when a scan ran (whether or not it succeeded).
     */
    _scanAppsIfDue(tickNumber, sampleFields) {
        const decision = decideAppScan(this._cadenceState(tickNumber, sampleFields, false));
        if (!decision.shouldScan)
            return false;
        const isDeferredForItsWindow = WINDOW_DEFERRED_SCAN_REASONS.includes(decision.reason) &&
            this._isCpuRankingWindowTooShort(sampleFields.takenAtUsec);
        if (isDeferredForItsWindow)
            return false;
        this._runAppScan(decision.reason, tickNumber, sampleFields);
        return true;
    }

    /**
     * Says whether a scan now would rank CPU over less than MIN_CPU_RANKING_WINDOW_SECONDS. With no previous scan to
     * diff against, a scan is only a baseline, so its window does not matter.
     *
     * @param {number} nowUsec - When the scan would run, on the nowUsec clock.
     * @returns {boolean} True when the previous scan is too recent.
     */
    _isCpuRankingWindowTooShort(nowUsec) {
        const previousScan = this._previousAppScan;
        return previousScan !== null && nowUsec - previousScan.takenAtUsec < MIN_CPU_RANKING_WINDOW_USEC;
    }

    /**
     * A watch start's own decision, outside the tick: a watch-start scan (the reveal cooldown lives in
     * decideAppScan) runs at once, and a snapshot of the latest fast tick's values with the new ranking is published,
     * without touching the histories. Any other reason is left to the ticks (see WATCH_START_SCAN_REASONS).
     *
     * It does not scan less than MIN_CPU_RANKING_WINDOW_SECONDS after the last scan: the client already has that
     * ranking, so nothing is published and no warm-up is armed. After a tick that had no data it scans but publishes
     * nothing, since there are no fast-tick values to reuse and a no-data snapshot keeps apps null; the next tick
     * that samples carries the ranking.
     *
     * @returns {void}
     */
    _scanForWatchStart() {
        const latestSnapshot = this._latestSnapshot;
        if (this._latestTickNumber === null || latestSnapshot === null)
            return;
        const nowUsec = callOrNull(this._nowUsec);
        if (nowUsec === null || this._isCpuRankingWindowTooShort(nowUsec))
            return;
        const decision = decideAppScan(this._cadenceState(this._latestTickNumber, latestSnapshot, true));
        if (!decision.shouldScan || !WATCH_START_SCAN_REASONS.includes(decision.reason))
            return;
        this._runAppScan(decision.reason, this._latestTickNumber, latestSnapshot);
        if (!this._isLatestSnapshotNoData) {
            const revealSnapshot = {...latestSnapshot, apps: this._latestAppRanking};
            this._latestSnapshot = revealSnapshot;
            this._notifyListeners(revealSnapshot, null);
        }
        this._collectGarbageAfterScan();
    }

    /**
     * Records a scan in the cadence, then scans. A scan that throws drops the ranking; it still counts as a scan for
     * the cadence, so a lasting failure costs one scan per interval, never one per tick.
     *
     * @param {string} reason - Why it runs (a decideAppScan reason).
     * @param {number} tickNumber - The tick it counts as.
     * @param {{cpuBusyPercent: number|null, pressureAvg10: object}} sampleFields - The sample a burst is measured
     *     from next time.
     * @returns {void}
     */
    _runAppScan(reason, tickNumber, sampleFields) {
        this._recordAppScanInCadence(reason, tickNumber, sampleFields);
        try {
            this._scanApps();
        } catch (error) {
            this._dropRankingAfterFailure(error);
        }
    }

    /**
     * Notes a scan for lib/cadence.js: when it ran, whether it arms a warm-up (armsWarmUp) and starts the cooldowns
     * (isTriggeredScan), and the CPU and pressure a later burst is measured against.
     *
     * @param {string} reason - Why the scan runs.
     * @param {number} tickNumber - The tick it counts as.
     * @param {{cpuBusyPercent: number|null, pressureAvg10: object}} sampleFields - The sample at the scan.
     * @returns {void}
     */
    _recordAppScanInCadence(reason, tickNumber, sampleFields) {
        this._lastAppScanTickNumber = tickNumber;
        if (isTriggeredScan(reason))
            this._lastTriggeredScanTickNumber = tickNumber;
        this._isWarmUpPending = armsWarmUp(reason);
        this._lastAppScanReason = reason;
        this._cpuBusyPercentAtLastScan = sampleFields.cpuBusyPercent;
        this._pressureBandsAtLastScan = pressureBandsOf(sampleFields.pressureAvg10);
    }

    /**
     * Drops the last ranking (and its baseline) after a scan threw, so the next snapshot carries no apps rather
     * than a ranking from before the failure, then logs the failure.
     *
     * @param {*} error - What the scan threw.
     * @returns {void}
     */
    _dropRankingAfterFailure(error) {
        this._previousAppScan = null;
        this._latestAppRanking = null;
        this._logRateLimited(`app scan failed: ${describeErrorWithStack(error)}`, APP_SCAN_FAILURE_LOG_KEY);
    }

    /**
     * Runs the full garbage collection that follows each app scan; a failure is logged, never thrown.
     *
     * @returns {void}
     */
    _collectGarbageAfterScan() {
        try {
            this._collectGarbage();
        } catch (error) {
            this._logRateLimited(`garbage collection failed: ${describeError(error)}`,
                GARBAGE_COLLECTION_FAILURE_LOG_KEY);
        }
    }

    /**
     * Scans the app cgroups once and ranks them: lists the leaves under the scanned parents, reads cpu.stat of the
     * root and of each parent, reads each leaf, logs the failures as one line, and hands rankApps everything it
     * needs for kernel and short jobs.
     *
     * @returns {void}
     * @throws {Error} On a bug in the scan; no state has changed by then.
     */
    _scanApps() {
        const fsRoot = this.fsRoot;
        const takenAtUsec = this._nowUsec();
        const cgroupRootPath = joinPath(fsRoot, CGROUP_ROOT_PATH);
        const failures = new CgroupReadFailures();
        const cgroupTree = this._listCgroupTree(cgroupRootPath, failures);
        const rootUsageUsec = this._readCgroupUsageUsec(cgroupRootPath, ROOT_CGROUP_RELATIVE_PATH, failures);
        const parentUsageUsecByPath = this._readParentUsage(cgroupRootPath, cgroupTree.parentRelativePaths, failures);
        const leafReadings = this._readCgroupLeaves(cgroupRootPath, [...cgroupTree.parentOfLeaf.keys()], failures);
        if (failures.count > 0)
            this._logRateLimited(failures.describe(), CGROUP_READ_FAILURES_LOG_KEY);
        const currentScan = {
            takenAtUsec,
            rootUsageUsec,
            parentUsageUsecByPath,
            usageUsecByCgroup: leafReadings.usageUsecByCgroup,
            fullyAccountedParentPaths: fullyAccountedParentPaths(cgroupTree, leafReadings.unreadLeafPaths),
            isEveryParentFullyListed: cgroupTree.isEveryParentFullyListed,
        };
        // Everything that can throw runs before any state below is changed.
        const ranking = rankApps(this._rankingInputs(currentScan, cgroupTree.parentOfLeaf,
            leafReadings.memoryBytesByCgroup));
        this._previousAppScan = currentScan;
        this._latestAppRanking = ranking;
    }

    /**
     * Builds rankApps' input from this scan and the previous one. All three parent inputs are passed explicitly:
     * rankApps defaults them to empty, which would silently drop "kernel" and "short jobs".
     *
     * @param {object} currentScan - This scan's readings.
     * @param {Map<string, string>} parentOfLeaf - Each listed leaf's scanned parent.
     * @param {Map<string, number>} memoryBytesByCgroup - Each read leaf's memory net of page cache.
     * @returns {object} The rankApps input.
     */
    _rankingInputs(currentScan, parentOfLeaf, memoryBytesByCgroup) {
        const previousScan = this._previousAppScan;
        const lookUpAppName = desktopId => this._lookUpAppName(desktopId);
        return {
            previousUsageUsec: previousScan === null ? new Map() : previousScan.usageUsecByCgroup,
            currentUsageUsec: currentScan.usageUsecByCgroup,
            memoryBytesByCgroup,
            // The real time between the two scans, never the nominal interval: ticks can run late.
            elapsedUsec: previousScan === null ? 0 : currentScan.takenAtUsec - previousScan.takenAtUsec,
            cpuCount: this._cpuCount ?? 0,
            rootCpuDeltaUsec: rootCpuDeltaUsec(previousScan, currentScan),
            parentOfLeaf,
            // A new leaf counts in full only when its parent's listing in the previous scan proves it did not exist
            // then. A new leaf whose parent's previous listing failed is skipped (it may be an old leaf that was
            // merely unlisted), so its CPU stays inside its parent's Δ and is counted as "short jobs".
            parentsListedPreviously: previousScan === null ? new Set() : previousScan.fullyAccountedParentPaths,
            parentCpuDeltaUsec: parentCpuDeltasUsec(previousScan, currentScan),
            nameOfCgroup: cgroupPath => groupOfCgroup(cgroupPath, lookUpAppName),
        };
    }

    /**
     * Looks up an app's name once per desktop id for as long as the service runs, misses included. A lookup that
     * throws is logged (rate-limited) and counts as a miss, so the app keeps the name its unit gives and the scan
     * goes on.
     *
     * @param {string} desktopId - For example 'org.chromium.Chromium.desktop'.
     * @returns {string|null} The name, or null for none.
     */
    _lookUpAppName(desktopId) {
        if (this._appNameByDesktopId.has(desktopId))
            return this._appNameByDesktopId.get(desktopId);
        let appName = null;
        try {
            appName = this._resolveAppName(desktopId) ?? null;
        } catch (error) {
            const errorText = describeError(error);
            this._logRateLimited(`cannot look up ${desktopId}: ${errorText}`, APP_NAME_LOOKUP_FAILURE_LOG_KEY);
        }
        this._appNameByDesktopId.set(desktopId, appName);
        return appName;
    }

    /**
     * Lists the cgroup leaves to rank under each scanned parent (see _listLeavesUnder), and which parents were
     * listed completely.
     *
     * @param {string} cgroupRootPath - Absolute path of the cgroup v2 root.
     * @param {CgroupReadFailures} failures - Collects the listings that failed.
     * @returns {{parentRelativePaths: string[], parentOfLeaf: Map<string, string>, fullyListedParentPaths: Set<string>,
     *     isEveryParentFullyListed: boolean}} The scanned parents, each leaf's parent (paths relative to the cgroup
     *     root), the parents whose every listing succeeded, and whether that is all of them, every parent was found,
     *     and the uid is known.
     */
    _listCgroupTree(cgroupRootPath, failures) {
        const {parentRelativePaths, isEveryParentFound} = this._findAppScanParents(cgroupRootPath, failures);
        const parentOfLeaf = new Map();
        const fullyListedParentPaths = new Set();
        for (const parentRelativePath of parentRelativePaths) {
            const {leafRelativePaths, isFullyListed} =
                this._listLeavesUnder(cgroupRootPath, parentRelativePath, failures);
            for (const leafRelativePath of leafRelativePaths)
                parentOfLeaf.set(leafRelativePath, parentRelativePath);
            if (isFullyListed)
                fullyListedParentPaths.add(parentRelativePath);
        }
        // Without the uid the user service's slices are not scanned at all, so "kernel" (the root minus the scanned
        // parents) would take in the whole user session: it counts as a parent that could not be listed. So does a
        // parent that may exist unfound, behind a listing of the root or the user's manager that failed.
        const isEveryParentFullyListed = this._uid !== null && isEveryParentFound &&
            fullyListedParentPaths.size === parentRelativePaths.length;
        return {parentRelativePaths, parentOfLeaf, fullyListedParentPaths, isEveryParentFullyListed};
    }

    /**
     * Lists the leaves under one scanned parent: its children, descending one level more into a child that is
     * itself a slice. Leaves of a unit type that never hosts an app (APP_SCAN_SKIPPED_UNIT_SUFFIXES) are left out at
     * both depths, unread.
     *
     * @param {string} cgroupRootPath - Absolute path of the cgroup v2 root.
     * @param {string} parentRelativePath - The parent, relative to the cgroup root.
     * @param {CgroupReadFailures} failures - Collects the listings that failed.
     * @returns {{leafRelativePaths: string[], isFullyListed: boolean}} The leaves found, and whether the parent's
     *     listing and every sub-slice's succeeded (so a leaf missing from them did not exist).
     */
    _listLeavesUnder(cgroupRootPath, parentRelativePath, failures) {
        const childRelativePaths = this._listChildPaths(cgroupRootPath, parentRelativePath, failures);
        if (childRelativePaths === null)
            return {leafRelativePaths: [], isFullyListed: false};
        const leafRelativePaths = [];
        let isFullyListed = true;
        for (const childRelativePath of childRelativePaths) {
            if (!childRelativePath.endsWith(SLICE_SUFFIX)) {
                if (canHostApp(childRelativePath))
                    leafRelativePaths.push(childRelativePath);
                continue;
            }
            const grandchildRelativePaths = this._listChildPaths(cgroupRootPath, childRelativePath, failures);
            if (grandchildRelativePaths === null)
                isFullyListed = false;
            else
                leafRelativePaths.push(...grandchildRelativePaths.filter(canHostApp));
        }
        return {leafRelativePaths, isFullyListed};
    }

    /**
     * Finds the cgroups whose children an app scan ranks, listed afresh every scan (ruling R22), so a VM, a rootless
     * container or a `systemd-run --user --slice=` job is named rather than counted as "kernel":
     * - every slice directly under the user's manager, user.slice/user-<uid>.slice/user@<uid>.service: app.slice,
     *   session.slice, background.slice and any other;
     * - every top-level slice but user.slice: system.slice, machine.slice and any other. user.slice holds the user's
     *   slices above, so as a parent too it would count their CPU twice.
     * That is two directory listings per scan. A listing of a cgroup that does not exist finds no parent and is no
     * failure (_listChildPaths); without a known uid the user's manager is not listed at all (initialize has already
     * logged why).
     *
     * @param {string} cgroupRootPath - Absolute path of the cgroup v2 root.
     * @param {CgroupReadFailures} failures - Collects the listings that failed.
     * @returns {{parentRelativePaths: string[], isEveryParentFound: boolean}} The parents, relative to the cgroup
     *     root, and whether both listings succeeded: when one failed, a parent may exist unfound, and its CPU would
     *     read as kernel.
     */
    _findAppScanParents(cgroupRootPath, failures) {
        const parentRelativePaths = [];
        let isEveryParentFound = true;
        /**
         * Adds a listing's slices to the parents, or notes that it failed.
         *
         * @param {string[]|null} childRelativePaths - _listChildPaths' answer.
         * @param {(sliceRelativePath: string) => boolean} isParent - Which of its slices are parents.
         * @returns {void}
         */
        const addSlices = (childRelativePaths, isParent) => {
            if (childRelativePaths === null) {
                isEveryParentFound = false;
                return;
            }
            const sliceRelativePaths = childRelativePaths.filter(childPath => childPath.endsWith(SLICE_SUFFIX));
            parentRelativePaths.push(...sliceRelativePaths.filter(isParent));
        };
        if (this._uid !== null) {
            const userSliceName = `user-${this._uid}.slice`;
            const userManagerName = `user@${this._uid}.service`;
            const userManagerRelativePath = joinPath(USER_SLICE, userSliceName, userManagerName);
            addSlices(this._listChildPaths(cgroupRootPath, userManagerRelativePath, failures), () => true);
        }
        addSlices(this._listChildPaths(cgroupRootPath, ROOT_CGROUP_RELATIVE_PATH, failures),
            sliceRelativePath => sliceRelativePath !== USER_SLICE);
        return {parentRelativePaths, isEveryParentFound};
    }

    /**
     * Lists a cgroup's child cgroups. A missing cgroup is a definite answer, not a failure: systemd removes an empty
     * slice, and a scope can exit mid-scan (isVanishedCgroupError), and nothing can be under a cgroup that does not
     * exist. Any other failure is counted.
     *
     * @param {string} cgroupRootPath - Absolute path of the cgroup v2 root.
     * @param {string} directoryRelativePath - The cgroup to list, relative to the cgroup root.
     * @param {CgroupReadFailures} failures - Collects the failure.
     * @returns {string[]|null} Child paths relative to the cgroup root in JavaScript's default string order (none for
     *     a vanished cgroup), so a group takes the name of the same first leaf in every scan; null when the listing
     *     failed.
     */
    _listChildPaths(cgroupRootPath, directoryRelativePath, failures) {
        let childNames;
        try {
            childNames = this._listDirectoryNames(joinPath(cgroupRootPath, directoryRelativePath));
        } catch (error) {
            if (isVanishedCgroupError(error))
                return [];
            failures.note(directoryRelativePath, error);
            return null;
        }
        // Sorted (JavaScript's default string order) because a directory lists in no defined order, and a group takes
        // the name of its first leaf: unsorted, a group whose leaves resolve to different names could change name
        // between scans. The compiled sampler lists in this same order.
        return [...childNames].sort().map(childName => joinPath(directoryRelativePath, childName));
    }

    /**
     * Reads usage_usec from each scanned parent's cpu.stat.
     *
     * @param {string} cgroupRootPath - Absolute path of the cgroup v2 root.
     * @param {string[]} parentRelativePaths - The scanned parents, relative to the cgroup root.
     * @param {CgroupReadFailures} failures - Collects the failed reads.
     * @returns {Map<string, number>} usage_usec by parent path; a parent that could not be read is absent.
     */
    _readParentUsage(cgroupRootPath, parentRelativePaths, failures) {
        const usageUsecByParentPath = new Map();
        for (const parentRelativePath of parentRelativePaths) {
            const usageUsec = this._readCgroupUsageUsec(cgroupRootPath, parentRelativePath, failures);
            if (usageUsec !== null)
                usageUsecByParentPath.set(parentRelativePath, usageUsec);
        }
        return usageUsecByParentPath;
    }

    /**
     * Reads one cgroup's usage_usec. A vanished cgroup is silent; any other failure is counted.
     *
     * @param {string} cgroupRootPath - Absolute path of the cgroup v2 root.
     * @param {string} cgroupRelativePath - The cgroup, relative to the cgroup root (ROOT_CGROUP_RELATIVE_PATH for
     *     the root).
     * @param {CgroupReadFailures} failures - Collects the failure.
     * @returns {number|null} The usage, or null when it could not be read or parsed.
     */
    _readCgroupUsageUsec(cgroupRootPath, cgroupRelativePath, failures) {
        const cpuStatRelativePath = joinPath(cgroupRelativePath, CGROUP_CPU_STAT_FILE);
        let cpuStatText;
        try {
            cpuStatText = this._readFile(joinPath(cgroupRootPath, cpuStatRelativePath));
        } catch (error) {
            if (!isVanishedCgroupError(error))
                failures.note(cpuStatRelativePath, error);
            return null;
        }
        const usageUsec = parseCpuStatUsageUsec(cpuStatText);
        if (usageUsec === null)
            failures.note(cpuStatRelativePath, new Error('no usage_usec line'));
        return usageUsec;
    }

    /**
     * Reads every leaf. A leaf with any failed read is skipped from both rankings: silently when the cgroup vanished
     * between listing and reading (isVanishedCgroupError), counted (and returned as unread) otherwise.
     *
     * @param {string} cgroupRootPath - Absolute path of the cgroup v2 root.
     * @param {string[]} leafRelativePaths - Leaf paths relative to the cgroup root.
     * @param {CgroupReadFailures} failures - Collects the failed reads.
     * @returns {{usageUsecByCgroup: Map<string, number>, memoryBytesByCgroup: Map<string, number>,
     *     unreadLeafPaths: string[]}} The readings, and the leaves that exist but could not be read.
     */
    _readCgroupLeaves(cgroupRootPath, leafRelativePaths, failures) {
        const usageUsecByCgroup = new Map();
        const memoryBytesByCgroup = new Map();
        const unreadLeafPaths = [];
        for (const leafRelativePath of leafRelativePaths) {
            let leafReading;
            try {
                leafReading = readCgroupLeaf(joinPath(cgroupRootPath, leafRelativePath), this._readFile);
            } catch (error) {
                if (!isVanishedCgroupError(error)) {
                    failures.note(leafRelativePath, error);
                    unreadLeafPaths.push(leafRelativePath);
                }
                continue;
            }
            usageUsecByCgroup.set(leafRelativePath, leafReading.usageUsec);
            memoryBytesByCgroup.set(leafRelativePath, leafReading.memoryBytes);
        }
        return {usageUsecByCgroup, memoryBytesByCgroup, unreadLeafPaths};
    }

    /**
     * Reads which CPUs are performance and which efficiency cores: the hybrid PMU lists, else cpu_capacity.
     *
     * @param {string} fsRoot - The filesystem root.
     * @returns {{performanceCpus: number[], efficiencyCpus: number[]}|null} Null for a single-cluster machine.
     */
    _readClusterMap(fsRoot) {
        const corePmuCpus = this._readPmuCpuList(joinPath(fsRoot, CORE_PMU_CPUS_PATH));
        const atomPmuCpus = this._readPmuCpuList(joinPath(fsRoot, ATOM_PMU_CPUS_PATH));
        const hasHybridPmu = corePmuCpus.length > 0 && atomPmuCpus.length > 0;
        const capacities = hasHybridPmu ? new Map() : this._readCpuCapacities(fsRoot);
        // The capacity fallback walks CPUs 0..cpuCount−1, so cpuCount is one past the highest CPU with a capacity.
        const cpuCount = capacities.size === 0 ? 0 : Math.max(...capacities.keys()) + 1;
        return buildClusterMap({corePmuCpus, atomPmuCpus, capacities, cpuCount});
    }

    /**
     * Reads a PMU CPU list. A missing list is normal (no hybrid cores); an unreadable or malformed one is logged.
     * Either way it counts as empty, so the caller falls back to cpu_capacity.
     *
     * @param {string} path - The list's path.
     * @returns {number[]} CPU numbers; empty on any failure.
     */
    _readPmuCpuList(path) {
        let cpuListText;
        try {
            cpuListText = this._readFile(path);
        } catch (error) {
            if (!isNotFoundError(error))
                this._logReadFailure(path, error);
            return [];
        }
        try {
            return parseCpuList(cpuListText);
        } catch (error) {
            this._logRateLimited(`cannot parse ${path}: ${describeError(error)}`, `cannot parse ${path}`);
            return [];
        }
    }

    /**
     * Reads cpu_capacity of every CPU. A CPU without one is normal (most non-hybrid machines have none).
     *
     * @param {string} fsRoot - The filesystem root.
     * @returns {Map<number, number>} Capacity by CPU number; empty on failure.
     */
    _readCpuCapacities(fsRoot) {
        const cpuDevicesPath = joinPath(fsRoot, CPU_DEVICES_PATH);
        let deviceNames;
        try {
            deviceNames = this._listDirectoryNames(cpuDevicesPath);
        } catch (error) {
            this._logRateLimited(`cannot list ${cpuDevicesPath}: ${describeError(error)}`,
                `cannot list ${cpuDevicesPath}`);
            return new Map();
        }
        const capacities = new Map();
        for (const deviceName of deviceNames) {
            const cpuMatch = CPU_DEVICE_NAME_PATTERN.exec(deviceName);
            if (cpuMatch === null)
                continue;
            const capacity = this._readCpuCapacity(joinPath(cpuDevicesPath, deviceName, CPU_CAPACITY_FILE));
            if (capacity !== null)
                capacities.set(parseInt(cpuMatch[1], DECIMAL_RADIX), capacity);
        }
        return capacities;
    }

    /**
     * Reads one CPU's cpu_capacity. A missing file is normal; an unreadable or malformed one is logged.
     *
     * @param {string} capacityPath - The file's path.
     * @returns {number|null} The capacity, or null.
     */
    _readCpuCapacity(capacityPath) {
        let capacityText;
        try {
            capacityText = this._readFile(capacityPath);
        } catch (error) {
            if (!isNotFoundError(error))
                this._logReadFailure(capacityPath, error);
            return null;
        }
        return this._parseOrLog(capacityText, capacityPath, parseSingleNumber);
    }

    /**
     * Reads and parses a file, logging a failed read or an unparseable file.
     *
     * @param {string} path - The file's path.
     * @param {(contents: string) => *} parse - Parser returning null for unparseable contents.
     * @returns {*} The parsed value, or null on any failure.
     */
    _readAndParse(path, parse) {
        let contents;
        try {
            contents = this._readFile(path);
        } catch (error) {
            this._logReadFailure(path, error);
            return null;
        }
        return this._parseOrLog(contents, path, parse);
    }

    /**
     * Parses a file's contents, logging when they are unparseable.
     *
     * @param {string} contents - The file's contents.
     * @param {string} path - The file's path, for the log line.
     * @param {(contents: string) => *} parse - Parser returning null for unparseable contents.
     * @returns {*} The parsed value, or null.
     */
    _parseOrLog(contents, path, parse) {
        const parsed = parse(contents);
        if (parsed === null)
            this._logRateLimited(`cannot parse ${path}`);
        return parsed;
    }

    /**
     * Logs a failed read, rate-limited per path whatever the error says.
     *
     * @param {string} path - The file that could not be read.
     * @param {*} error - What the read threw.
     * @returns {void}
     */
    _logReadFailure(path, error) {
        this._logRateLimited(`cannot read ${path}: ${describeError(error)}`, `cannot read ${path}`);
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
     * Logs a message with the journal prefix, at most once per ERROR_LOG_REPEAT_INTERVAL_USEC for its template key
     * (lib/errorLog.js). Silent once destroyed.
     *
     * @param {string} message - The message, without the prefix.
     * @param {string} [templateKey] - A stable name for a message whose text varies; defaults to the message.
     * @returns {void}
     */
    _logRateLimited(message, templateKey = message) {
        if (this._isDestroyed)
            return;
        this._errorLog.log(message, templateKey);
    }
}
