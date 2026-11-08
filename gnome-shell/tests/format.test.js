import {test, assertEqual} from './harness.js';
import {
    formatGibibytes, formatWholePercent, memoryLine, swapLine, clusterSuffix, pressureMeter,
    waitingOnLine, ellipsize, heaviestLine, hoverLabel,
} from '../extensions/resource-pulse@dotfiles/lib/format.js';
import {cardPosition} from '../extensions/resource-pulse@dotfiles/lib/layout.js';

const GIB = 1024 ** 3;
const CARD_WIDTH_PX = 340;
const CARD_MARGIN_PX = 24;
const SECOND_MONITOR_X_PX = 1536;

/**
 * Builds a swap summary in the shape lib/memory.js produces.
 *
 * @param {number} swappedBytes - Swap in use.
 * @param {number} zramStoredBytes - Of it, held in zram.
 * @param {number} zramRamBytes - RAM the zram itself takes.
 * @returns {object} A swap summary.
 */
const swapOf = (swappedBytes, zramStoredBytes, zramRamBytes) => ({
    swappedBytes, zramStoredBytes, zramRamBytes, diskBytes: Math.max(0, swappedBytes - zramStoredBytes),
});

const FULL_SNAPSHOT = {
    cpuBusyPercent: 23, memory: {usedBytes: 16.4 * GIB, totalBytes: 30.3 * GIB},
};

test('formatGibibytes uses 1024^3, not 1000^3', () => assertEqual(formatGibibytes(20480000000), '19.1'));
test('formatGibibytes rounds to one decimal rather than truncating', () => assertEqual(formatGibibytes(1.96 * GIB), '2.0'));
test('formatWholePercent rounds (22.5 → 23%, not 22%)', () => assertEqual(formatWholePercent(22.5), '23%'));
test('memoryLine: used of total GiB', () =>
    assertEqual(memoryLine({usedBytes: 20480000000, totalBytes: 32768000000}), '19.1 of 30.5 GiB'));
test('memoryLine: null is "no data"', () => assertEqual(memoryLine(null), 'no data'));

test('swapLine with zram and disk', () =>
    assertEqual(swapLine(swapOf(2048000000, 1536000000, 400000000)), 'swap 1.9 GiB (0.4 in RAM) + 0.5 on disk'));
test('swapLine all in zram omits the disk part', () =>
    assertEqual(swapLine(swapOf(1536000000, 1536000000, 400000000)), 'swap 1.4 GiB (0.4 in RAM)'));
test('swapLine with nothing swapped is "swap none"', () => assertEqual(swapLine(swapOf(0, 0, 0)), 'swap none'));
test('swapLine null is "swap no data"', () => assertEqual(swapLine(null), 'swap no data'));
test('swapLine without zram shows disk only, no "0.0 in RAM"', () =>
    assertEqual(swapLine(swapOf(2 * GIB, 0, 0)), 'swap 2.0 GiB on disk'));

test('clusterSuffix both sides', () =>
    assertEqual(clusterSuffix({performancePercent: 80, efficiencyPercent: 40}), 'P 80 · E 40'));
test('clusterSuffix rounds each side', () =>
    assertEqual(clusterSuffix({performancePercent: 79.6, efficiencyPercent: 40.4}), 'P 80 · E 40'));
test('clusterSuffix null is empty', () => assertEqual(clusterSuffix(null), ''));
test('clusterSuffix with one side null shows only the other', () =>
    assertEqual([clusterSuffix({performancePercent: 80, efficiencyPercent: null}),
        clusterSuffix({performancePercent: null, efficiencyPercent: 40}),
        clusterSuffix({performancePercent: null, efficiencyPercent: null})], ['P 80', 'E 40', '']));

test('pressureMeter draws each band and no data', () =>
    assertEqual([0, 1, 2, 3, null].map(pressureMeter), ['▯▯▯', '▮▯▯', '▮▮▯', '▮▮▮', '···']));
test('waitingOnLine bands avg10 percents (not bands) and keeps two spaces between groups', () =>
    assertEqual(waitingOnLine({cpu: 12, memory: 3, io: 0}), 'CPU ▮▯▯  mem ▯▯▯  io ▯▯▯'));
test('waitingOnLine with a null avg10 shows ···', () =>
    assertEqual(waitingOnLine({cpu: null, memory: 60, io: 30}), 'CPU ···  mem ▮▮▮  io ▮▮▯'));

test('ellipsize leaves a name of exactly maxChars alone', () =>
    assertEqual(ellipsize('a'.repeat(18), 18), 'a'.repeat(18)));
test('ellipsize cuts a 25-character name to 17 characters plus …', () =>
    assertEqual(ellipsize('abcdefghijklmnopqrstuvwxy', 18), 'abcdefghijklmnopq…'));

test('heaviestLine: two different apps', () =>
    assertEqual(heaviestLine({topCpu: {name: 'Chromium', cpuPercent: 31},
        topMemory: {name: 'herdr agents', memoryBytes: 15.7 * GIB}}), 'Chromium 31% · herdr agents 15.7 GiB'));
test('heaviestLine collapses when one app tops both', () =>
    assertEqual(heaviestLine({topCpu: {name: 'herdr agents', cpuPercent: 31},
        topMemory: {name: 'herdr agents', memoryBytes: 15.7 * GIB}}), 'herdr agents 31% · 15.7 GiB'));
test('heaviestLine ellipsizes a long name, including "kernel & other"', () =>
    assertEqual(heaviestLine({topCpu: {name: 'a-very-long-application-name', cpuPercent: 5},
        topMemory: {name: 'kernel & other', memoryBytes: 2 * GIB}}), 'a-very-long-appli… 5% · kernel & other 2.0 GiB'));
test('heaviestLine with only one ranking shows just that half', () =>
    assertEqual([heaviestLine({topCpu: {name: 'Chromium', cpuPercent: 31}, topMemory: null}),
        heaviestLine({topCpu: null, topMemory: {name: 'Chromium', memoryBytes: GIB}})],
    ['Chromium 31%', 'Chromium 1.0 GiB']));
test('heaviestLine with no data is an em dash', () =>
    assertEqual([heaviestLine(null), heaviestLine({topCpu: null, topMemory: null})], ['—', '—']));

test('hoverLabel with cpu and memory', () =>
    assertEqual(hoverLabel(FULL_SNAPSHOT, '14:02'), 'cpu 23% · mem 16.4 of 30.3 GiB'));
test('hoverLabel without a snapshot says since when, never stale numbers', () =>
    assertEqual(hoverLabel(null, '14:02'), 'no data since 14:02'));
test('hoverLabel with neither cpu nor memory is "no data since"', () =>
    assertEqual(hoverLabel({cpuBusyPercent: null, memory: null}, '14:02'), 'no data since 14:02'));
test('hoverLabel partial: the missing half says "no data", the present half stays', () =>
    assertEqual([hoverLabel({cpuBusyPercent: 23, memory: null}, '14:02'),
        hoverLabel({cpuBusyPercent: null, memory: FULL_SNAPSHOT.memory}, '14:02')],
    ['cpu 23% · mem no data', 'cpu no data · mem 16.4 of 30.3 GiB']));
test('hoverLabel with no last-good time is plain "no data"', () => assertEqual(hoverLabel(null, null), 'no data'));

test('cardPosition: top-right of the work area, inset by the margin', () =>
    assertEqual(cardPosition({x: 0, y: 32, width: 1536, height: 928}, CARD_WIDTH_PX, CARD_MARGIN_PX), {x: 1172, y: 56}));
test('cardPosition on a monitor that does not start at x 0 offsets by the work area', () =>
    assertEqual(cardPosition({x: SECOND_MONITOR_X_PX, y: 32, width: 1536, height: 928}, CARD_WIDTH_PX, CARD_MARGIN_PX),
        {x: 2708, y: 56}));
test('cardPosition clamps x to the work area when the card is wider than it', () =>
    assertEqual(cardPosition({x: 100, y: 0, width: 300, height: 600}, CARD_WIDTH_PX, CARD_MARGIN_PX), {x: 100, y: 24}));
