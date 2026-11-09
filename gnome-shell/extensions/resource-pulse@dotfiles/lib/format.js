// Every string the top-bar label and the desktop card show, and the bands of the card's drawn pressure meters.
// Pure functions; the Shell glue only calls these.
import {APP_NAME_MAX_CHARS, BYTES_PER_GIBIBYTE, CPU_IDLE_LABEL, CPU_IDLE_THRESHOLD_PERCENT} from './constants.js';
import {pressureBand} from './pressure.js';

const NO_DATA_TEXT = 'no data';
const NO_SWAP_TEXT = 'none';
const SEPARATOR = ' · ';
const ELLIPSIS = '…';
const EM_DASH = '—';
const SWAP_LABEL = 'swap';
// The desktop card's row labels, as in the mockup the user picked (the spec's "Decided by the user", item 1).
const CARD_CPU_LABEL = 'CPU';
const CARD_MEMORY_LABEL = 'MEM';
const CARD_WAITING_ON_LABEL = 'waiting on:';
const CARD_HEAVIEST_LABEL = 'heaviest:';
// The labels before the card's three "waiting on" meters.
const WAITING_ON_CPU_LABEL = 'CPU';
const WAITING_ON_MEMORY_LABEL = 'mem';
const WAITING_ON_IO_LABEL = 'io';
const NO_PRESSURE_DATA = {cpu: null, memory: null, io: null};

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
 * Describes swap use without the leading "swap": what zram holds (and the RAM that costs), then what is on disk.
 * The lead number is zram's part alone, so "+ X on disk" adds to it. The desktop card shows "swap" as a separate,
 * muted label.
 *
 * @param {{zramUsedBytes: number, zramRamBytes: number, diskBytes: number}|null} swap - Swap summary.
 * @returns {string} For example '1.9 GiB (0.4 in RAM) + 0.5 on disk', '2.0 GiB on disk', 'none' or 'no data'.
 */
export function swapAmount(swap) {
    if (swap === null || swap === undefined)
        return NO_DATA_TEXT;
    if (swap.zramUsedBytes <= 0 && swap.diskBytes <= 0)
        return NO_SWAP_TEXT;
    const diskText = formatGibibytes(swap.diskBytes);
    // With no zram swap in use everything is on disk, so a "0.0 GiB (0.0 in RAM)" would only be noise.
    if (swap.zramUsedBytes <= 0)
        return `${diskText} GiB on disk`;
    const zramText = `${formatGibibytes(swap.zramUsedBytes)} GiB (${formatGibibytes(swap.zramRamBytes)} in RAM)`;
    return swap.diskBytes > 0 ? `${zramText} + ${diskText} on disk` : zramText;
}

/**
 * Describes swap use on one line.
 *
 * @param {{zramUsedBytes: number, zramRamBytes: number, diskBytes: number}|null} swap - Swap summary.
 * @returns {string} For example 'swap 1.9 GiB (0.4 in RAM) + 0.5 on disk', 'swap none' or 'swap no data'.
 */
export function swapLine(swap) {
    return `${SWAP_LABEL} ${swapAmount(swap)}`;
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
 * @typedef {object} PressureMeter
 * @property {string} label - What the meter is for: 'CPU', 'mem' or 'io'.
 * @property {0|1|2|3|null} band - How many of its three cells are filled, or null for no data (graph.js
 *     drawPressureMeter draws it).
 */

/**
 * What the machine is waiting on, as the card's three drawn meters: CPU, then memory, then io.
 *
 * @param {{cpu: number|null, memory: number|null, io: number|null}} pressureAvg10 - PSI some avg10 percents.
 * @returns {PressureMeter[]} For example [{label: 'CPU', band: 1}, {label: 'mem', band: 0}, {label: 'io', band: 0}].
 */
export function waitingOnMeters(pressureAvg10) {
    return [
        {label: WAITING_ON_CPU_LABEL, band: pressureBand(pressureAvg10.cpu)},
        {label: WAITING_ON_MEMORY_LABEL, band: pressureBand(pressureAvg10.memory)},
        {label: WAITING_ON_IO_LABEL, band: pressureBand(pressureAvg10.io)},
    ];
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
 * Splits the app ranking into the two halves of "heaviest", and says whether they are one group.
 *
 * @param {{topCpu: {groupKey?: string, name: string, cpuPercent: number}|null,
 *     topMemory: {groupKey?: string, name: string, memoryBytes: number}|null}|null} apps - App ranking.
 * @returns {{cpuHalf: {name: string, valueText: string}|null, memoryHalf: {name: string, valueText: string}|null,
 *     isCollapsed: boolean}} The CPU half reads CPU_IDLE_LABEL (no value) when the top entry is below
 *     CPU_IDLE_THRESHOLD_PERCENT; isCollapsed is true only when both halves are the same group (by groupKey, never
 *     merely by name) and the CPU half is not idle.
 */
export function heaviestParts(apps) {
    const topCpu = apps?.topCpu ?? null;
    const topMemory = apps?.topMemory ?? null;
    const isIdle = topCpu !== null && topCpu.cpuPercent < CPU_IDLE_THRESHOLD_PERCENT;
    let cpuHalf = null;
    if (isIdle)
        cpuHalf = {name: CPU_IDLE_LABEL, valueText: ''};
    else if (topCpu !== null)
        cpuHalf = {name: topCpu.name, valueText: formatWholePercent(topCpu.cpuPercent)};
    const memoryHalf = topMemory === null ? null
        : {name: topMemory.name, valueText: `${formatGibibytes(topMemory.memoryBytes)} GiB`};
    const isCollapsed = !isIdle && topCpu !== null && topMemory !== null &&
        topCpu.groupKey !== undefined && topCpu.groupKey === topMemory.groupKey;
    return {cpuHalf, memoryHalf, isCollapsed};
}

/**
 * Writes one half of "heaviest": its name, ellipsized, then its value when it has one.
 *
 * @param {{name: string, valueText: string}} half - from heaviestParts.
 * @returns {string} For example 'Chromium 31%', or 'idle'.
 */
function halfText(half) {
    const name = ellipsize(half.name, APP_NAME_MAX_CHARS);
    return half.valueText === '' ? name : `${name} ${half.valueText}`;
}

/**
 * Describes the heaviest apps on one line.
 *
 * @param {{topCpu: {groupKey?: string, name: string, cpuPercent: number}|null,
 *     topMemory: {groupKey?: string, name: string, memoryBytes: number}|null}|null} apps - App ranking.
 * @returns {string} 'Chromium 31% · herdr agents 15.7 GiB', 'herdr agents 31% · 15.7 GiB' when one group tops
 *     both, 'idle · Chromium 2.0 GiB' when the CPU is idle, one half alone when the other is missing, or '—' with
 *     no data.
 */
export function heaviestLine(apps) {
    const {cpuHalf, memoryHalf, isCollapsed} = heaviestParts(apps);
    if (cpuHalf === null && memoryHalf === null)
        return EM_DASH;
    if (cpuHalf === null)
        return halfText(memoryHalf);
    if (memoryHalf === null)
        return halfText(cpuHalf);
    if (isCollapsed)
        return `${halfText(cpuHalf)}${SEPARATOR}${memoryHalf.valueText}`;
    return `${halfText(cpuHalf)}${SEPARATOR}${halfText(memoryHalf)}`;
}

/**
 * Says there is no data, and since when when that is known.
 *
 * @param {string|null} lastGoodClockLabel - 'HH:MM' of the last snapshot with data.
 * @returns {string} 'no data since 14:02', or 'no data' without a last good time.
 */
function noDataSince(lastGoodClockLabel) {
    if (lastGoodClockLabel === null || lastGoodClockLabel === undefined)
        return NO_DATA_TEXT;
    return `${NO_DATA_TEXT} since ${lastGoodClockLabel}`;
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
    if (cpuPercent === null && memory === null)
        return noDataSince(lastGoodClockLabel);
    const cpuText = cpuPercent === null ? NO_DATA_TEXT : formatWholePercent(cpuPercent);
    return `cpu ${cpuText}${SEPARATOR}mem ${memoryLine(memory)}`;
}

/**
 * The desktop card's CPU value. When the snapshot has no CPU and no memory (a failed tick, or none yet) it says
 * since when, as the hover label does; when only the CPU is missing (the first sample has no delta) it says plain
 * "no data", never 0%.
 *
 * @param {number|null} cpuPercent - Whole-machine CPU busy percent, or null.
 * @param {boolean} hasNoNumbers - True when the snapshot has neither CPU nor memory.
 * @param {string|null} lastGoodClockLabel - 'HH:MM' of the last snapshot with data.
 * @returns {string} For example '23%', 'no data' or 'no data since 14:02'.
 */
function cardCpuValue(cpuPercent, hasNoNumbers, lastGoodClockLabel) {
    if (cpuPercent !== null)
        return formatWholePercent(cpuPercent);
    return hasNoNumbers ? noDataSince(lastGoodClockLabel) : NO_DATA_TEXT;
}

/**
 * @typedef {object} CardText
 * @property {string} cpuLabel - 'CPU'.
 * @property {string} cpuValue - For example '23%', 'no data' or 'no data since 14:02'.
 * @property {string} cpuClusterSuffix - The dim per-core-type load, for example 'P 41 · E 6'; '' when unknown.
 * @property {string} memoryLabel - 'MEM'.
 * @property {string} memoryValue - memoryLine: for example '16.4 of 30.3 GiB'.
 * @property {string} swapLabel - 'swap'.
 * @property {string} swapValue - swapAmount: for example '1.6 GiB (0.4 in RAM)'.
 * @property {string} waitingOnLabel - 'waiting on:'.
 * @property {PressureMeter[]} waitingOnMeters - waitingOnMeters: a label and a band for CPU, memory and io.
 * @property {string} heaviestLabel - 'heaviest:'.
 * @property {string} heaviestValue - heaviestLine: for example 'Chromium 31% · herdr agents 15.7 GiB'.
 */

/**
 * Every string on the desktop card, from one snapshot: a muted label and a value per row, as in the mockup. A
 * missing part says "no data" (or '—', or a meter band of null) rather than showing a stale number as live.
 *
 * @param {import('../pulseClient.js').Snapshot|null} snapshot - The latest snapshot, or null before the first.
 * @param {string|null} lastGoodClockLabel - 'HH:MM' of the last snapshot with data.
 * @returns {CardText} The card's strings.
 */
export function cardText(snapshot, lastGoodClockLabel) {
    const cpuPercent = snapshot?.cpuBusyPercent ?? null;
    const memory = snapshot?.memory ?? null;
    const hasNoNumbers = cpuPercent === null && memory === null;
    return {
        cpuLabel: CARD_CPU_LABEL,
        cpuValue: cardCpuValue(cpuPercent, hasNoNumbers, lastGoodClockLabel),
        cpuClusterSuffix: clusterSuffix(snapshot?.cpuClusters ?? null),
        memoryLabel: CARD_MEMORY_LABEL,
        memoryValue: memoryLine(memory),
        swapLabel: SWAP_LABEL,
        swapValue: swapAmount(snapshot?.swap ?? null),
        waitingOnLabel: CARD_WAITING_ON_LABEL,
        waitingOnMeters: waitingOnMeters(snapshot?.pressureAvg10 ?? NO_PRESSURE_DATA),
        heaviestLabel: CARD_HEAVIEST_LABEL,
        heaviestValue: heaviestLine(snapshot?.apps ?? null),
    };
}
