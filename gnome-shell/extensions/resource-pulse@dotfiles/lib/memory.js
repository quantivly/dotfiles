/** A /proc/swaps file name that is a zram device, capturing the device's name in /sys/block. */
const ZRAM_SWAP_AREA_PATTERN = /^\/dev\/(zram\d+)$/;

/**
 * Names the zram devices that are swap areas, as /sys/block names them.
 *
 * @param {Array<{filename: string}>} swapAreas - parseProcSwaps output.
 * @returns {string[]} For example ['zram0'], in /proc/swaps order; empty without zram swap.
 */
export function zramSwapDeviceNames(swapAreas) {
    return swapAreas
        .map(({filename}) => ZRAM_SWAP_AREA_PATTERN.exec(filename))
        .filter(zramMatch => zramMatch !== null)
        .map(zramMatch => zramMatch[1]);
}

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
 * Swap in use, split between compressed zram and real disk, from each swap area's own Used. zram's share is never
 * derived from its orig_data_size: that leaves out same-filled pages and slot use, so it under-counts zram and
 * turned the difference into swap "on disk" that did not exist.
 *
 * @param {Array<{filename: string, usedBytes: number}>} swapAreas - parseProcSwaps output.
 * @param {Array<{deviceName: string, ramBytes: number}>} zramDevices - Every zram device's mm_stat, with its
 *     /sys/block name.
 * @returns {{zramUsedBytes: number, zramRamBytes: number, diskBytes: number}} Swap in use on /dev/zram* areas,
 *     the RAM those same devices take (a zram device that is not a swap area adds nothing), and swap in use on
 *     every other area.
 */
export function swapSummary(swapAreas, zramDevices) {
    const zramSwapDeviceNames = new Set();
    let zramUsedBytes = 0;
    let diskBytes = 0;
    for (const {filename, usedBytes} of swapAreas) {
        const zramMatch = ZRAM_SWAP_AREA_PATTERN.exec(filename);
        if (zramMatch === null) {
            diskBytes += usedBytes;
            continue;
        }
        zramSwapDeviceNames.add(zramMatch[1]);
        zramUsedBytes += usedBytes;
    }
    const zramRamBytes = zramDevices
        .filter(zramDevice => zramSwapDeviceNames.has(zramDevice.deviceName))
        .reduce((sum, zramDevice) => sum + zramDevice.ramBytes, 0);
    return {zramUsedBytes, zramRamBytes, diskBytes};
}
