/**
 * Memory in use, as the kernel's own estimate: MemTotal - MemAvailable.
 *
 * @param {Map<string, number>} meminfo - parseMeminfo output, in bytes.
 * @returns {{usedBytes: number, totalBytes: number}|null} Null when a field is missing.
 */
export function memoryUsage(meminfo) {
    const totalBytes = meminfo.get('MemTotal');
    const availableBytes = meminfo.get('MemAvailable');
    if (totalBytes === undefined || availableBytes === undefined)
        return null;
    return {usedBytes: totalBytes - availableBytes, totalBytes};
}

/**
 * Swap split between compressed zram and real disk.
 *
 * @param {Map<string, number>} meminfo - parseMeminfo output, in bytes.
 * @param {Array<{storedBytes: number, ramBytes: number}>} zramDevices - zram mm_stat per device.
 * @returns {{swappedBytes: number, zramStoredBytes: number, zramRamBytes: number, diskBytes: number}|null}
 *     Null when SwapTotal or SwapFree is missing.
 */
export function swapSummary(meminfo, zramDevices) {
    const swapTotalBytes = meminfo.get('SwapTotal');
    const swapFreeBytes = meminfo.get('SwapFree');
    if (swapTotalBytes === undefined || swapFreeBytes === undefined)
        return null;
    const swappedBytes = swapTotalBytes - swapFreeBytes;
    const zramStoredBytes = zramDevices.reduce((sum, device) => sum + device.storedBytes, 0);
    const zramRamBytes = zramDevices.reduce((sum, device) => sum + device.ramBytes, 0);
    const diskBytes = Math.max(0, swappedBytes - zramStoredBytes);
    return {swappedBytes, zramStoredBytes, zramRamBytes, diskBytes};
}
