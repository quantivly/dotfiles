// Pure parsers for /proc and /sys text. No GNOME Shell imports. A line that
// cannot be parsed yields null, never NaN.

const BYTES_PER_KIB = 1024;
const CPU_TIMES_FIELD_NAMES = [
    'user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal', 'guest', 'guestNice',
];
const PER_CPU_LINE_PATTERN = /^cpu(\d+)$/;
const MEMINFO_LINE_PATTERN = /^([^:\s]+):\s+(\d+)(?:\s+(kB))?\s*$/;
const PSI_SOME_AVG10_PATTERN = /^some\s.*\bavg10=(\d+(?:\.\d+)?)/;
const UID_LINE_PATTERN = /^Uid:\s+(\d+)/;
const ZRAM_MM_STAT_STORED_FIELD_INDEX = 0;
const ZRAM_MM_STAT_RAM_FIELD_INDEX = 2; // mem_used_total, not compr_data_size
const ZRAM_MM_STAT_MIN_FIELD_COUNT = 3;
const PROC_SWAPS_FILENAME_COLUMN = 'Filename';
const PROC_SWAPS_USED_KIB_COLUMN = 'Used';
const WHITESPACE_RUN_PATTERN = /\s+/;
const DECIMAL_RADIX = 10;

/**
 * Parses whitespace-separated non-negative integers; null if any is not one.
 *
 * @param {string[]} fields - Candidate numeric tokens.
 * @returns {number[]|null} The numbers, or null on any malformed token.
 */
function parseNonNegativeIntegers(fields) {
    const numbers = fields.map(field => (/^\d+$/.test(field) ? parseInt(field, DECIMAL_RADIX) : NaN));
    return numbers.some(Number.isNaN) ? null : numbers;
}

/**
 * Parses one `cpu`/`cpuN` line's counters into a CpuTimes object.
 * Older kernels omit trailing fields; missing ones count as 0.
 *
 * @param {string[]} counterFields - Tokens after the label.
 * @returns {object|null} CpuTimes, or null when malformed.
 */
function parseCpuTimes(counterFields) {
    const counters = parseNonNegativeIntegers(counterFields);
    if (counters === null || counters.length < 4)
        return null;
    const cpuTimes = {};
    CPU_TIMES_FIELD_NAMES.forEach((fieldName, index) => {
        cpuTimes[fieldName] = counters[index] ?? 0;
    });
    return cpuTimes;
}

/**
 * Parses /proc/stat.
 *
 * @param {string} text - File contents.
 * @returns {{aggregate: object|null, perCpu: Map<number, object>}} Aggregate
 *     CPU times (null if absent or malformed) and per-CPU times by index.
 */
export function parseProcStat(text) {
    let aggregate = null;
    const perCpu = new Map();
    for (const line of text.split('\n')) {
        const [label, ...counterFields] = line.trim().split(/\s+/);
        if (label === 'cpu') {
            aggregate = parseCpuTimes(counterFields);
            continue;
        }
        const perCpuMatch = PER_CPU_LINE_PATTERN.exec(label);
        const cpuTimes = perCpuMatch ? parseCpuTimes(counterFields) : null;
        if (cpuTimes !== null)
            perCpu.set(parseInt(perCpuMatch[1], DECIMAL_RADIX), cpuTimes);
    }
    return {aggregate, perCpu};
}

/**
 * Parses /proc/meminfo, converting kB values to bytes.
 *
 * @param {string} text - File contents.
 * @returns {Map<string, number>} Field name to bytes (or a bare count when
 *     the line has no unit, e.g. HugePages_Total).
 */
export function parseMeminfo(text) {
    const fields = new Map();
    for (const line of text.split('\n')) {
        const match = MEMINFO_LINE_PATTERN.exec(line);
        if (!match)
            continue;
        const value = parseInt(match[2], DECIMAL_RADIX);
        fields.set(match[1], match[3] ? value * BYTES_PER_KIB : value);
    }
    return fields;
}

/**
 * Parses a /proc/pressure/* file's `some` line avg10 (percent).
 *
 * @param {string} text - File contents.
 * @returns {number|null} The some avg10 value, or null if absent.
 */
export function parsePressureSomeAvg10(text) {
    for (const line of text.split('\n')) {
        const match = PSI_SOME_AVG10_PATTERN.exec(line);
        if (match)
            return parseFloat(match[1]);
    }
    return null;
}

/**
 * Parses /sys/block/zramN/mm_stat.
 *
 * @param {string} text - File contents.
 * @returns {{storedBytes: number, ramBytes: number}|null} Uncompressed bytes
 *     stored (field 1) and RAM actually used (field 3, mem_used_total).
 */
export function parseZramMmStat(text) {
    const fields = parseNonNegativeIntegers(text.trim().split(/\s+/));
    if (fields === null || fields.length < ZRAM_MM_STAT_MIN_FIELD_COUNT)
        return null;
    return {
        storedBytes: fields[ZRAM_MM_STAT_STORED_FIELD_INDEX],
        ramBytes: fields[ZRAM_MM_STAT_RAM_FIELD_INDEX],
    };
}

/**
 * Parses /proc/swaps: a header naming the columns, then one row per active swap area. Columns are separated by
 * runs of tabs and spaces, and the kernel escapes whitespace inside a file name, so a name is always one field.
 *
 * @param {string} text - File contents.
 * @returns {Array<{filename: string, usedBytes: number}>|null} Each area's file name and the swap in use there
 *     (the Used column, KiB → bytes); an empty list when no area is active. Null when the header has no Filename
 *     or Used column, or any row is malformed.
 */
export function parseProcSwaps(text) {
    const [headerLine, ...rowLines] = text.split('\n');
    const columnNames = headerLine.trim().split(WHITESPACE_RUN_PATTERN);
    const filenameIndex = columnNames.indexOf(PROC_SWAPS_FILENAME_COLUMN);
    const usedKibIndex = columnNames.indexOf(PROC_SWAPS_USED_KIB_COLUMN);
    if (filenameIndex === -1 || usedKibIndex === -1)
        return null;
    const swapAreas = [];
    for (const rowLine of rowLines) {
        if (rowLine.trim() === '')
            continue;
        const fields = rowLine.trim().split(WHITESPACE_RUN_PATTERN);
        const usedKib = fields.length === columnNames.length ? parseNonNegativeIntegers([fields[usedKibIndex]]) : null;
        if (usedKib === null)
            return null;
        swapAreas.push({filename: fields[filenameIndex], usedBytes: usedKib[0] * BYTES_PER_KIB});
    }
    return swapAreas;
}

/**
 * Parses the real UID from /proc/<pid>/status.
 *
 * @param {string} statusText - File contents.
 * @returns {number|null} The first field of the Uid line, or null.
 */
export function parseUid(statusText) {
    for (const line of statusText.split('\n')) {
        const match = UID_LINE_PATTERN.exec(line);
        if (match)
            return parseInt(match[1], DECIMAL_RADIX);
    }
    return null;
}
