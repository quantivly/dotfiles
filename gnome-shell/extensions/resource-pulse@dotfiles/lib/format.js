// Every string the top-bar label and the desktop card show. Pure functions; the Shell glue only calls these.
import {
    BYTES_PER_GIBIBYTE, PRESSURE_METER_CELLS, PRESSURE_METER_EMPTY_CELL, PRESSURE_METER_FILLED_CELL,
    PRESSURE_METER_NO_DATA,
} from './constants.js';
import {APP_NAME_MAX_CHARS} from './constants.js';
import {pressureBand} from './pressure.js';

const NO_DATA_TEXT = 'no data';
const SEPARATOR = ' · ';
const ELLIPSIS = '…';
const EM_DASH = '—';
const WAITING_ON_GROUP_SEPARATOR = '  ';

/**
 * Formats a byte count as GiB with one decimal and no unit.
 *
 * @param {number} bytes - Size in bytes.
 * @returns {string} For example '19.1'.
 */
export function formatGibibytes(bytes) {
    return (bytes / BYTES_PER_GIBIBYTE).toFixed(1);
}

/**
 * Formats a percentage as a whole number with a percent sign.
 *
 * @param {number} percent - Percentage.
 * @returns {string} For example '23%'.
 */
export function formatWholePercent(percent) {
    return `${Math.round(percent)}%`;
}

/**
 * Describes memory use.
 *
 * @param {{usedBytes: number, totalBytes: number}|null} memory - Memory usage.
 * @returns {string} For example '19.1 of 30.5 GiB', or 'no data'.
 */
export function memoryLine(memory) {
    if (memory === null || memory === undefined)
        return NO_DATA_TEXT;
    return `${formatGibibytes(memory.usedBytes)} of ${formatGibibytes(memory.totalBytes)} GiB`;
}

/**
 * Describes swap use, split into what zram holds (and the RAM that costs) and what is on disk.
 *
 * @param {{swappedBytes: number, zramStoredBytes: number, zramRamBytes: number, diskBytes: number}|null} swap
 *     Swap summary.
 * @returns {string} For example 'swap 1.9 GiB (0.4 in RAM) + 0.5 on disk', 'swap none' or 'swap no data'.
 */
export function swapLine(swap) {
    if (swap === null || swap === undefined)
        return `swap ${NO_DATA_TEXT}`;
    if (swap.swappedBytes <= 0)
        return 'swap none';
    const swappedText = formatGibibytes(swap.swappedBytes);
    // Without zram everything is on disk, so a "(0.0 in RAM)" would only be noise.
    if (swap.zramStoredBytes <= 0)
        return `swap ${swappedText} GiB on disk`;
    const inRamText = `(${formatGibibytes(swap.zramRamBytes)} in RAM)`;
    const onDiskText = swap.diskBytes > 0 ? ` + ${formatGibibytes(swap.diskBytes)} on disk` : '';
    return `swap ${swappedText} GiB ${inRamText}${onDiskText}`;
}

/**
 * Describes per-cluster CPU load. A side with no data is left out (a machine with no efficiency cores has none).
 *
 * @param {{performancePercent: number|null, efficiencyPercent: number|null}|null} cpuClusters - Cluster loads.
 * @returns {string} For example 'P 80 · E 40', or '' when there is nothing to show.
 */
export function clusterSuffix(cpuClusters) {
    if (cpuClusters === null || cpuClusters === undefined)
        return '';
    const parts = [];
    if (cpuClusters.performancePercent !== null)
        parts.push(`P ${Math.round(cpuClusters.performancePercent)}`);
    if (cpuClusters.efficiencyPercent !== null)
        parts.push(`E ${Math.round(cpuClusters.efficiencyPercent)}`);
    return parts.join(SEPARATOR);
}

/**
 * Draws a three-cell pressure meter.
 *
 * @param {0|1|2|3|null} band - Pressure band, or null for no data.
 * @returns {string} '▯▯▯' to '▮▮▮', or '···'.
 */
export function pressureMeter(band) {
    if (band === null || band === undefined)
        return PRESSURE_METER_NO_DATA;
    return PRESSURE_METER_FILLED_CELL.repeat(band) + PRESSURE_METER_EMPTY_CELL.repeat(PRESSURE_METER_CELLS - band);
}

/**
 * Describes what the machine is waiting on.
 *
 * @param {{cpu: number|null, memory: number|null, io: number|null}} pressureAvg10 - PSI some avg10 percents.
 * @returns {string} For example 'CPU ▮▯▯  mem ▯▯▯  io ▯▯▯'.
 */
export function waitingOnLine(pressureAvg10) {
    const meterOf = avg10Percent => pressureMeter(pressureBand(avg10Percent));
    return [
        `CPU ${meterOf(pressureAvg10.cpu)}`,
        `mem ${meterOf(pressureAvg10.memory)}`,
        `io ${meterOf(pressureAvg10.io)}`,
    ].join(WAITING_ON_GROUP_SEPARATOR);
}

/**
 * Shortens a name to at most maxChars characters.
 *
 * @param {string} name - Name to shorten.
 * @param {number} maxChars - Longest result, in characters.
 * @returns {string} The name, or its first maxChars − 1 characters plus '…'.
 */
export function ellipsize(name, maxChars) {
    if (name.length <= maxChars)
        return name;
    return name.slice(0, maxChars - 1) + ELLIPSIS;
}

/**
 * Describes the heaviest apps on one line.
 *
 * @param {{topCpu: {name: string, cpuPercent: number}|null, topMemory: {name: string, memoryBytes: number}|null}|null}
 *     apps - App ranking.
 * @returns {string} 'Chromium 31% · herdr agents 15.7 GiB', 'herdr agents 31% · 15.7 GiB' when one app tops
 *     both, one half alone when the other is missing, or '—' with no data.
 */
export function heaviestLine(apps) {
    const topCpu = apps?.topCpu ?? null;
    const topMemory = apps?.topMemory ?? null;
    if (topCpu === null && topMemory === null)
        return EM_DASH;
    const cpuText = topCpu === null ? null : formatWholePercent(topCpu.cpuPercent);
    const memoryText = topMemory === null ? null : `${formatGibibytes(topMemory.memoryBytes)} GiB`;
    if (topCpu === null)
        return `${ellipsize(topMemory.name, APP_NAME_MAX_CHARS)} ${memoryText}`;
    if (topMemory === null)
        return `${ellipsize(topCpu.name, APP_NAME_MAX_CHARS)} ${cpuText}`;
    if (topCpu.name === topMemory.name)
        return `${ellipsize(topCpu.name, APP_NAME_MAX_CHARS)} ${cpuText}${SEPARATOR}${memoryText}`;
    const cpuHalf = `${ellipsize(topCpu.name, APP_NAME_MAX_CHARS)} ${cpuText}`;
    const memoryHalf = `${ellipsize(topMemory.name, APP_NAME_MAX_CHARS)} ${memoryText}`;
    return `${cpuHalf}${SEPARATOR}${memoryHalf}`;
}

/**
 * Builds the top-bar hover label. A missing half says 'no data' rather than showing a stale number.
 *
 * @param {{cpuBusyPercent: number|null, memory: {usedBytes: number, totalBytes: number}|null}|null} snapshot
 *     Latest snapshot.
 * @param {string|null} lastGoodClockLabel - 'HH:MM' of the last snapshot with data.
 * @returns {string} For example 'cpu 23% · mem 16.4 of 30.3 GiB', or 'no data since 14:02'.
 */
export function hoverLabel(snapshot, lastGoodClockLabel) {
    const cpuPercent = snapshot?.cpuBusyPercent ?? null;
    const memory = snapshot?.memory ?? null;
    if (cpuPercent === null && memory === null) {
        return lastGoodClockLabel === null || lastGoodClockLabel === undefined
            ? NO_DATA_TEXT
            : `${NO_DATA_TEXT} since ${lastGoodClockLabel}`;
    }
    const cpuText = cpuPercent === null ? NO_DATA_TEXT : formatWholePercent(cpuPercent);
    return `cpu ${cpuText}${SEPARATOR}mem ${memoryLine(memory)}`;
}
