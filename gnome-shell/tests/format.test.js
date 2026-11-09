import {test, assertEqual} from './harness.js';
import {
    formatGibibytes, formatWholePercent, memoryLine, swapLine, swapAmount, clusterSuffix, waitingOnMeters,
    heaviestParts, hoverLabel, cardText,
} from '../extensions/resource-pulse@dotfiles/lib/format.js';
// The heaviest row's parts, read through the namespace, so a missing export fails its rows rather than the whole run.
import * as formatModule from '../extensions/resource-pulse@dotfiles/lib/format.js';
import {cardPosition, hoverLabelPosition} from '../extensions/resource-pulse@dotfiles/lib/layout.js';

const GIB = 1024 ** 3;
const CARD_WIDTH_PX = 340;
const CARD_MARGIN_PX = 24;
const SECOND_MONITOR_X_PX = 1536;
// The hover label's rows: a 1536 px wide monitor, a 32 px panel, the indicator's size, the label's width as the
// nested run measured it, and the stylesheet's 8 px gap under the indicator.
const MONITOR_WIDTH_PX = 1536;
const INDICATOR_WIDTH_PX = 88;
const INDICATOR_HEIGHT_PX = 32;
const HOVER_LABEL_WIDTH_PX = 236;
const HOVER_LABEL_GAP_PX = 8;
const LEFT_MONITOR = {x: 0, width: MONITOR_WIDTH_PX};
/** A monitor to the right of a 1920 px wide one, so it is not the leftmost. */
const RIGHT_MONITOR = {x: 1920, width: MONITOR_WIDTH_PX};

/**
 * The indicator's stage rectangle at a given x, in the top bar.
 *
 * @param {number} x - Its left edge.
 * @returns {{x: number, y: number, width: number, height: number}} The rectangle.
 */
const indicatorAt = x => ({x, y: 0, width: INDICATOR_WIDTH_PX, height: INDICATOR_HEIGHT_PX});

/**
 * Builds a swap summary in the shape lib/memory.js produces.
 *
 * @param {number} zramUsedBytes - Swap in use on zram areas.
 * @param {number} zramRamBytes - RAM those zram devices take.
 * @param {number} diskBytes - Swap in use on every other area.
 * @returns {object} A swap summary.
 */
const swapOf = (zramUsedBytes, zramRamBytes, diskBytes) => ({zramUsedBytes, zramRamBytes, diskBytes});

const FULL_SNAPSHOT = {
    cpuBusyPercent: 23, memory: {usedBytes: 16.4 * GIB, totalBytes: 30.3 * GIB},
};

// A whole Snapshot as the sampler publishes it (service/sampler.js), for the desktop card's rows.
const CARD_SNAPSHOT = {
    takenAtUsec: 1_000_000,
    takenAtClockLabel: '14:02',
    cpuBusyPercent: 23,
    cpuClusters: {performancePercent: 41, efficiencyPercent: 6},
    memory: FULL_SNAPSHOT.memory,
    swap: swapOf(1.6 * GIB, 0.4 * GIB, 0),
    pressureAvg10: {cpu: 12, memory: 3, io: 0},
    apps: {topCpu: {name: 'Chromium', cpuPercent: 31}, topMemory: {name: 'herdr agents', memoryBytes: 15.7 * GIB}},
    isComplete: true,
};
// The snapshot a failed tick publishes (service/sampler.js _publishNoDataSnapshot): every number null.
const FAILED_TICK_SNAPSHOT = {
    takenAtUsec: 3_000_000,
    takenAtClockLabel: '14:04',
    cpuBusyPercent: null,
    cpuClusters: null,
    memory: null,
    swap: null,
    pressureAvg10: {cpu: null, memory: null, io: null},
    apps: null,
    isComplete: false,
};
// The card's muted labels, the same in every state.
const CARD_LABELS = {
    cpuLabel: 'CPU', memoryLabel: 'MEM', swapLabel: 'swap', waitingOnLabel: 'waiting on:', heaviestLabel: 'heaviest:',
};
// What the card shows with no numbers at all, before the CPU row's "since".
const CARD_NO_DATA_VALUES = {
    cpuClusterSuffix: '', memoryValue: 'no data', swapValue: 'no data',
    waitingOnMeters: [{label: 'CPU', band: null}, {label: 'mem', band: null}, {label: 'io', band: null}],
    heaviestRow: {cpuName: '—', cpuValue: '', separator: '', memoryName: '', memoryValue: ''},
};

/**
 * Picks the given fields of an object, so a row compares only what it is about.
 *
 * @param {object} source - The object.
 * @param {string[]} fieldNames - Fields to keep.
 * @returns {object} Those fields, in the order given.
 */
const pickFields = (source, fieldNames) => Object.fromEntries(fieldNames.map(fieldName => [fieldName, source[fieldName]]));

test('formatGibibytes uses 1024^3, not 1000^3', () => assertEqual(formatGibibytes(20480000000), '19.1'));
test('formatGibibytes rounds to one decimal rather than truncating', () => assertEqual(formatGibibytes(1.96 * GIB), '2.0'));
test('formatWholePercent rounds (22.5 → 23%, not 22%)', () => assertEqual(formatWholePercent(22.5), '23%'));
test('memoryLine: used of total GiB', () =>
    assertEqual(memoryLine({usedBytes: 20480000000, totalBytes: 32768000000}), '19.1 of 30.5 GiB'));
test('memoryLine: null is "no data"', () => assertEqual(memoryLine(null), 'no data'));

test('swapLine with zram and disk', () =>
    assertEqual(swapLine(swapOf(2048000000, 400000000, 512000000)), 'swap 1.9 GiB (0.4 in RAM) + 0.5 on disk'));
test('swapLine leads with the zram part alone, so "+ X on disk" adds to it rather than being inside it', () =>
    assertEqual(swapLine(swapOf(GIB, 0.2 * GIB, GIB)), 'swap 1.0 GiB (0.2 in RAM) + 1.0 on disk'));
test('swapLine all in zram omits the disk part', () =>
    assertEqual(swapLine(swapOf(1536000000, 400000000, 0)), 'swap 1.4 GiB (0.4 in RAM)'));
test('swapLine with nothing swapped is "swap none"', () => assertEqual(swapLine(swapOf(0, 0, 0)), 'swap none'));
test('swapLine null is "swap no data"', () => assertEqual(swapLine(null), 'swap no data'));
test('swapLine without zram swap shows disk only, no "0.0 in RAM"', () =>
    assertEqual(swapLine(swapOf(0, 0, 2 * GIB)), 'swap 2.0 GiB on disk'));

test('clusterSuffix both sides', () =>
    assertEqual(clusterSuffix({performancePercent: 80, efficiencyPercent: 40}), 'P 80 · E 40'));
test('clusterSuffix rounds each side', () =>
    assertEqual(clusterSuffix({performancePercent: 79.6, efficiencyPercent: 40.4}), 'P 80 · E 40'));
test('clusterSuffix null is empty', () => assertEqual(clusterSuffix(null), ''));
test('clusterSuffix with one side null shows only the other', () =>
    assertEqual([clusterSuffix({performancePercent: 80, efficiencyPercent: null}),
        clusterSuffix({performancePercent: null, efficiencyPercent: 40}),
        clusterSuffix({performancePercent: null, efficiencyPercent: null})], ['P 80', 'E 40', '']));

test('waitingOnMeters bands avg10 percents (not bands), labelled CPU, mem and io in that order', () =>
    assertEqual(waitingOnMeters({cpu: 12, memory: 3, io: 0}),
        [{label: 'CPU', band: 1}, {label: 'mem', band: 0}, {label: 'io', band: 0}]));
test('waitingOnMeters: a null avg10 is no data (band null) while the others still band', () =>
    assertEqual(waitingOnMeters({cpu: null, memory: 60, io: 30}),
        [{label: 'CPU', band: null}, {label: 'mem', band: 3}, {label: 'io', band: 2}]));

test('heaviestParts: docker.service (CPU) and docker-x.scope (memory) share a name, not a group, so they do not collapse',
    () => {
        const parts = heaviestParts({topCpu: {groupKey: 'unit:docker', name: 'docker', cpuPercent: 20},
            topMemory: {groupKey: 'docker:docker', name: 'docker', memoryBytes: GIB}});
        assertEqual([parts.isCollapsed, parts.cpuHalf, parts.memoryHalf],
            [false, {name: 'docker', valueText: '20%'}, {name: 'docker', valueText: '1.0 GiB'}]);
    });
test('heaviestParts: the same groupKey on both halves collapses', () =>
    assertEqual(heaviestParts({topCpu: {groupKey: 'app:x', name: 'X', cpuPercent: 20},
        topMemory: {groupKey: 'app:x', name: 'X', memoryBytes: GIB}}).isCollapsed, true));
test('heaviestParts: a top CPU entry at 0.6% is idle, at 1.0% it keeps its name and percent', () => {
    const memory = {groupKey: 'app:m', name: 'M', memoryBytes: GIB};
    const idle = heaviestParts({topCpu: {groupKey: 'app:x', name: 'X', cpuPercent: 0.6}, topMemory: memory});
    const busy = heaviestParts({topCpu: {groupKey: 'app:x', name: 'X', cpuPercent: 1.0}, topMemory: memory});
    assertEqual([idle.cpuHalf, busy.cpuHalf], [{name: 'idle', valueText: ''}, {name: 'X', valueText: '1%'}]);
});

// The card's "heaviest" row is four labels (each half's name and value) and a separator; '' hides a label.
const NO_HEAVIEST_LABELS = {cpuName: '', cpuValue: '', separator: '', memoryName: '', memoryValue: ''};
test('heaviestRowTexts: two different apps give each half its name and value, with the separator between them', () =>
    assertEqual(formatModule.heaviestRowTexts({topCpu: {groupKey: 'app:chromium', name: 'Chromium', cpuPercent: 31},
        topMemory: {groupKey: 'unit:herdr-server', name: 'herdr agents', memoryBytes: 15.7 * GIB}}),
    {cpuName: 'Chromium', cpuValue: '31%', separator: '·', memoryName: 'herdr agents', memoryValue: '15.7 GiB'}));
test('heaviestRowTexts: names are whole, never cut to a character count (the card ellipsizes them by width)', () =>
    assertEqual(formatModule.heaviestRowTexts({topCpu: null,
        topMemory: {groupKey: 'a', name: 'a-very-long-application-name', memoryBytes: 2 * GIB}}).memoryName,
    'a-very-long-application-name'));
test('heaviestRowTexts: one group topping both halves shows its name once, with both values', () =>
    assertEqual(formatModule.heaviestRowTexts({
        topCpu: {groupKey: 'unit:herdr-server', name: 'herdr agents', cpuPercent: 31},
        topMemory: {groupKey: 'unit:herdr-server', name: 'herdr agents', memoryBytes: 15.7 * GIB},
    }), {cpuName: 'herdr agents', cpuValue: '31%', separator: '·', memoryName: '', memoryValue: '15.7 GiB'}));
test('heaviestRowTexts: an idle CPU half shows "idle" with an empty value, and never collapses', () =>
    assertEqual(formatModule.heaviestRowTexts({topCpu: {groupKey: 'app:x', name: 'X', cpuPercent: 0.6},
        topMemory: {groupKey: 'app:x', name: 'X', memoryBytes: GIB}}),
    {cpuName: 'idle', cpuValue: '', separator: '·', memoryName: 'X', memoryValue: '1.0 GiB'}));
test('heaviestRowTexts: one ranking alone shows just that half, with no separator', () =>
    assertEqual([
        formatModule.heaviestRowTexts({topCpu: {name: 'Chromium', cpuPercent: 31}, topMemory: null}),
        formatModule.heaviestRowTexts({topCpu: null, topMemory: {name: 'Chromium', memoryBytes: GIB}}),
    ], [
        {...NO_HEAVIEST_LABELS, cpuName: 'Chromium', cpuValue: '31%'},
        {...NO_HEAVIEST_LABELS, memoryName: 'Chromium', memoryValue: '1.0 GiB'},
    ]));
test('heaviestRowTexts: no data is one em dash', () =>
    assertEqual([formatModule.heaviestRowTexts(null), formatModule.heaviestRowTexts({topCpu: null, topMemory: null})],
        [{...NO_HEAVIEST_LABELS, cpuName: '—'}, {...NO_HEAVIEST_LABELS, cpuName: '—'}]));

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

test('swapAmount is swapLine without its "swap" label, in every case', () => {
    const swapCases = [
        swapOf(2048000000, 400000000, 512000000), swapOf(1536000000, 400000000, 0), swapOf(0, 0, 0),
        null, swapOf(0, 0, 2 * GIB),
    ];
    assertEqual(swapCases.map(swapAmount),
        ['1.9 GiB (0.4 in RAM) + 0.5 on disk', '1.4 GiB (0.4 in RAM)', 'none', 'no data', '2.0 GiB on disk']);
    assertEqual(swapCases.map(swap => `swap ${swapAmount(swap)}`), swapCases.map(swapLine), 'swapLine');
});
test('cardText with every part: the mockup\'s labels and rows, from the same formatters as the top bar', () => {
    const expected = {
        ...CARD_LABELS,
        cpuValue: '23%', cpuClusterSuffix: 'P 41 · E 6', memoryValue: '16.4 of 30.3 GiB',
        swapValue: '1.6 GiB (0.4 in RAM)',
        waitingOnMeters: [{label: 'CPU', band: 1}, {label: 'mem', band: 0}, {label: 'io', band: 0}],
        heaviestRow: {
            cpuName: 'Chromium', cpuValue: '31%', separator: '·', memoryName: 'herdr agents', memoryValue: '15.7 GiB',
        },
    };
    assertEqual(pickFields(cardText(CARD_SNAPSHOT, '14:02'), Object.keys(expected)), expected);
});
test('cardText before any snapshot: no number anywhere, never 0%', () => {
    const expected = {...CARD_LABELS, ...CARD_NO_DATA_VALUES, cpuValue: 'no data'};
    assertEqual(pickFields(cardText(null, null), Object.keys(expected)), expected);
});
test('cardText after a failed tick: the CPU row says since when, every other row no data', () => {
    const expected = {...CARD_LABELS, ...CARD_NO_DATA_VALUES, cpuValue: 'no data since 14:02'};
    assertEqual(pickFields(cardText(FAILED_TICK_SNAPSHOT, '14:02'), Object.keys(expected)), expected);
});
test('cardText partial: a first sample says plain "no data" for CPU, a missing memory says "no data"', () => {
    const shownFields = ['cpuValue', 'cpuClusterSuffix', 'memoryValue'];
    const firstSample = {...CARD_SNAPSHOT, cpuBusyPercent: null, cpuClusters: null};
    const memoryMissing = {...CARD_SNAPSHOT, memory: null};
    assertEqual([pickFields(cardText(firstSample, '14:02'), shownFields),
        pickFields(cardText(memoryMissing, '14:02'), shownFields)], [
        {cpuValue: 'no data', cpuClusterSuffix: '', memoryValue: '16.4 of 30.3 GiB'},
        {cpuValue: '23%', cpuClusterSuffix: 'P 41 · E 6', memoryValue: 'no data'},
    ]);
});

test('cardPosition: top-right of the work area, inset by the margin', () =>
    assertEqual(cardPosition({x: 0, y: 32, width: 1536, height: 928}, CARD_WIDTH_PX, CARD_MARGIN_PX), {x: 1172, y: 56}));
test('cardPosition on a monitor that does not start at x 0 offsets by the work area', () =>
    assertEqual(cardPosition({x: SECOND_MONITOR_X_PX, y: 32, width: 1536, height: 928}, CARD_WIDTH_PX, CARD_MARGIN_PX),
        {x: 2708, y: 56}));
test('cardPosition clamps x to the work area when the card is wider than it', () =>
    assertEqual(cardPosition({x: 100, y: 0, width: 300, height: 600}, CARD_WIDTH_PX, CARD_MARGIN_PX), {x: 100, y: 24}));

test('hoverLabelPosition: centred below the indicator, the gap under it', () =>
    assertEqual(hoverLabelPosition(indicatorAt(1000), HOVER_LABEL_WIDTH_PX, HOVER_LABEL_GAP_PX, LEFT_MONITOR),
        {x: 926, y: 40}));
test('hoverLabelPosition: on a primary that is not the rightmost monitor, a label wider than the space to its ' +
    'right edge stops at that edge, not at the stage\'s', () =>
    // Centred it would start at 1366 and run onto the monitor to the right; the stage is 3456 px wide.
    assertEqual(hoverLabelPosition(indicatorAt(1440), HOVER_LABEL_WIDTH_PX, HOVER_LABEL_GAP_PX, LEFT_MONITOR),
        {x: 1300, y: 40}));
test('hoverLabelPosition: on a monitor right of another, the label never crosses onto the left one', () =>
    // Centred it would start at 1856, on the monitor to the left; the stage's left edge (0) is no limit here.
    assertEqual(hoverLabelPosition(indicatorAt(1930), HOVER_LABEL_WIDTH_PX, HOVER_LABEL_GAP_PX, RIGHT_MONITOR),
        {x: 1920, y: 40}));
test('hoverLabelPosition: a label wider than its monitor starts at the monitor\'s left edge', () =>
    assertEqual(hoverLabelPosition(indicatorAt(1930), HOVER_LABEL_WIDTH_PX, HOVER_LABEL_GAP_PX,
        {x: RIGHT_MONITOR.x, width: 200}), {x: 1920, y: 40}));
test('hoverLabelPosition: a fractional width or gap lands on whole pixels, still inside the monitor', () =>
    // Flush right the label would start at 1300.5; whole pixels round that left, to 1300, never past the edge.
    assertEqual(hoverLabelPosition(indicatorAt(1500), 235.5, 8.5, LEFT_MONITOR), {x: 1300, y: 40}));
