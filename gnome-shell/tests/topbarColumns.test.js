// Rows for lib/topbarColumns.js: the arithmetic that decides whether a top-bar graph draws again. The indicator asks
// for a repaint only when the columns its history gives now, in whole device pixels, differ from the columns it last
// drew, and it draws those very levels; these rows pin the quantising, the comparison and the way back to fractions,
// at scales 1, 1.25 and 2.
import {test, assertEqual} from './harness.js';
// Read through the namespace, so a missing export fails its row rather than the whole run.
import * as topbarColumnsModule from '../extensions/resource-pulse@dotfiles/lib/topbarColumns.js';

/** The top-bar graph's height in logical pixels, as lib/constants.js sets it. */
const GRAPH_HEIGHT_PX = 16;
const UNIT_SCALE = 1;
const FRACTIONAL_SCALE = 1.25;
const DOUBLE_SCALE = 2;

test('columns: a value inside one pixel does not change its column', () => {
    const {quantisedColumns} = topbarColumnsModule;
    assertEqual(quantisedColumns([0.01, 0.06, 0.07], GRAPH_HEIGHT_PX, UNIT_SCALE), [1, 1, 2]);
});

test('columns: zero is 0, any other value at least 1, a gap is GAP_COLUMN, and values outside 0–1 are clamped', () => {
    const {GAP_COLUMN, quantisedColumns} = topbarColumnsModule;
    assertEqual({
        gapColumn: GAP_COLUMN,
        columns: quantisedColumns([0, 0.001, null, NaN, 1.5, -0.5], GRAPH_HEIGHT_PX, UNIT_SCALE),
    }, {
        gapColumn: -1,
        columns: [0, 1, -1, -1, 16, 0],
    });
});

test('columns: a fractional scale counts whole device pixels', () => {
    const {deviceLevelCount, quantisedColumns} = topbarColumnsModule;
    assertEqual({
        levelsAtUnitScale: deviceLevelCount(GRAPH_HEIGHT_PX, UNIT_SCALE),
        levelsAtFractionalScale: deviceLevelCount(GRAPH_HEIGHT_PX, FRACTIONAL_SCALE),
        levelsAtDoubleScale: deviceLevelCount(GRAPH_HEIGHT_PX, DOUBLE_SCALE),
        columnsAtFractionalScale: quantisedColumns([1, 0.5], GRAPH_HEIGHT_PX, FRACTIONAL_SCALE),
        columnsAtDoubleScale: quantisedColumns([1, 0.5], GRAPH_HEIGHT_PX, DOUBLE_SCALE),
    }, {
        levelsAtUnitScale: 16,
        levelsAtFractionalScale: 32,
        levelsAtDoubleScale: 32,
        columnsAtFractionalScale: [32, 16],
        columnsAtDoubleScale: [32, 16],
    });
});

test('columns: equal only when both exist, have one length and match slot for slot', () => {
    const {areColumnsEqual} = topbarColumnsModule;
    assertEqual({
        sameColumns: areColumnsEqual([1, -1, 2], [1, -1, 2]),
        bothEmpty: areColumnsEqual([], []),
        firstNull: areColumnsEqual(null, [1, -1, 2]),
        secondNull: areColumnsEqual([1, -1, 2], null),
        bothNull: areColumnsEqual(null, null),
        otherLength: areColumnsEqual([1, -1], [1, -1, 2]),
        oneSlotDiffers: areColumnsEqual([1, -1, 2], [1, -1, 3]),
        gapAgainstZero: areColumnsEqual([0], [-1]),
    }, {
        sameColumns: true,
        bothEmpty: true,
        firstNull: false,
        secondNull: false,
        bothNull: false,
        otherLength: false,
        oneSlotDiffers: false,
        gapAgainstZero: false,
    });
});

test('columns: the fractions drawn are the columns\' own', () => {
    const {GAP_COLUMN, columnFractions, quantisedColumns} = topbarColumnsModule;
    const fractionsDrawnAt = resourceScale => columnFractions(
        quantisedColumns([0.5, null, 0.06], GRAPH_HEIGHT_PX, resourceScale), GRAPH_HEIGHT_PX, resourceScale);
    assertEqual({
        atUnitScale: fractionsDrawnAt(UNIT_SCALE),
        atFractionalScale: fractionsDrawnAt(FRACTIONAL_SCALE),
        withNoHeightYet: columnFractions([0, GAP_COLUMN], 0, UNIT_SCALE),
    }, {
        atUnitScale: [0.5, null, 0.0625],
        atFractionalScale: [0.5, null, 0.0625],
        withNoHeightYet: [0, null],
    });
});
