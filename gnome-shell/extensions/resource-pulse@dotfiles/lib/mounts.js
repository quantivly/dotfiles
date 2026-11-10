// The mounts source's pure part: network shares and removable disks from the mount entries the IO layer read
// (service/cockpit.js), as the rows parseMountsSource in lib/cockpitProtocol.js rebuilds. No Gio, no GLib and no Shell
// import, so it runs under plain gjs.
import {NETWORK_FILESYSTEM_TYPES, REMOVABLE_MOUNT_PREFIXES} from './constants.js';
import {guardDisplayName} from './nameGuard.js';
import {nonNegativeNumberOrNull} from './jsonFields.js';

/**
 * @param {string} mountPoint - An absolute mount point.
 * @param {string} filesystemType - The mount's filesystem type.
 * @returns {string|null} 'network' for a network filesystem type (it wins over the mount point), 'removable' for a
 *     mount point under a REMOVABLE_MOUNT_PREFIXES entry, otherwise null.
 */
function mountKindOf(mountPoint, filesystemType) {
    if (NETWORK_FILESYSTEM_TYPES.includes(filesystemType))
        return 'network';
    if (REMOVABLE_MOUNT_PREFIXES.some(prefix => mountPoint.startsWith(prefix)))
        return 'removable';
    return null;
}

/**
 * @param {string} mountPoint - An absolute mount point.
 * @returns {string} Its last non-empty segment ('/mnt/nas/' gives 'nas').
 */
function lastSegmentOf(mountPoint) {
    const segments = mountPoint.split('/').filter(segment => segment !== '');
    return segments.length > 0 ? segments[segments.length - 1] : mountPoint;
}

/**
 * @param {{mountPoint: string}} first - A row.
 * @param {{mountPoint: string}} second - Another row.
 * @returns {number} Negative, zero or positive by plain string comparison of the mount points.
 */
function compareMountPoints(first, second) {
    if (first.mountPoint === second.mountPoint)
        return 0;
    return first.mountPoint < second.mountPoint ? -1 : 1;
}

/**
 * Builds the mount rows: the network shares and removable disks among the mounts.
 *
 * @param {Array<{mountPoint: string, filesystemType: string, devicePath: string, label: string|null,
 *     freeBytes: number|null, totalBytes: number|null}>} entries - The mounts, as the IO layer read them.
 * @returns {Array<{mountPoint: string, label: string, kind: string, filesystemType: string|null,
 *     freeBytes: number|null, totalBytes: number|null}>} A row for each entry with a string mount point that is a
 *     network share or under a removable prefix, sorted by mount point. The label is the entry's label, else the
 *     mount point's last segment, through guardDisplayName; sizes pass through as non-negative numbers or null.
 */
export function mountRowsFrom(entries) {
    if (!Array.isArray(entries))
        return [];
    const rows = [];
    entries.forEach(entry => {
        if (entry === null || typeof entry !== 'object' || typeof entry.mountPoint !== 'string')
            return;
        const kind = mountKindOf(entry.mountPoint, entry.filesystemType);
        if (kind === null)
            return;
        const hasLabel = typeof entry.label === 'string' && entry.label !== '';
        rows.push({
            mountPoint: entry.mountPoint,
            label: guardDisplayName(hasLabel ? entry.label : lastSegmentOf(entry.mountPoint)),
            kind,
            filesystemType: typeof entry.filesystemType === 'string' ? entry.filesystemType : null,
            freeBytes: nonNegativeNumberOrNull(entry.freeBytes),
            totalBytes: nonNegativeNumberOrNull(entry.totalBytes),
        });
    });
    return rows.sort(compareMountPoints);
}
