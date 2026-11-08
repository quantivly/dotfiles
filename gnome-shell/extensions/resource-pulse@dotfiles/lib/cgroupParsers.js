// Pure parsers for cgroup v2 files. No GNOME Shell imports. A value that cannot
// be parsed yields null, never NaN.

const DECIMAL_RADIX = 10;
const USAGE_USEC_PATTERN = /^usage_usec\s+(\d+)$/m;
const ACTIVE_FILE_PATTERN = /^active_file\s+(\d+)$/m;
const INACTIVE_FILE_PATTERN = /^inactive_file\s+(\d+)$/m;
const SINGLE_NUMBER_PATTERN = /^\s*(\d+)\s*$/;

/**
 * Reads usage_usec (cumulative CPU microseconds) from a cgroup cpu.stat.
 *
 * @param {string} text - File contents.
 * @returns {number|null} Microseconds, or null if absent.
 */
export function parseCpuStatUsageUsec(text) {
    const match = USAGE_USEC_PATTERN.exec(text);
    return match ? parseInt(match[1], DECIMAL_RADIX) : null;
}

/**
 * Computes reclaimable page cache from a cgroup memory.stat.
 *
 * @param {string} text - File contents.
 * @returns {number|null} active_file + inactive_file in bytes, or null if
 *     either is absent.
 */
export function parseMemoryStatReclaimableBytes(text) {
    const active = ACTIVE_FILE_PATTERN.exec(text);
    const inactive = INACTIVE_FILE_PATTERN.exec(text);
    if (!active || !inactive)
        return null;
    return parseInt(active[1], DECIMAL_RADIX) + parseInt(inactive[1], DECIMAL_RADIX);
}

/**
 * Parses a file holding one integer, such as memory.current.
 *
 * @param {string} text - File contents.
 * @returns {number|null} The integer, or null (e.g. for "max").
 */
export function parseSingleNumber(text) {
    const match = SINGLE_NUMBER_PATTERN.exec(text);
    return match ? parseInt(match[1], DECIMAL_RADIX) : null;
}
