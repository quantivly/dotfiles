// Rows for graph.js: the Cairo drawing behind the top-bar graphs and the desktop card. It runs inside
// gnome-shell on every repaint, so the first rows pin that no history the sampler can produce makes it throw,
// on a real image surface; the rest pin the geometry, and that the drawing fills exactly that geometry.
import Cairo from 'cairo';

import {test, assertEqual} from './harness.js';
import {
    areaGraphPolygons, drawAreaGraph, drawPressureMeter, drawUsedBar, padWithLeadingGaps, pressureMeterCellRects,
    usedBarFillWidthPx,
} from '../extensions/resource-pulse@dotfiles/graph.js';
import {
    BASELINE_RGBA, CPU_GRAPH_RGBA, GRAPH_BASELINE_THICKNESS_PX, MEMORY_GRAPH_RGBA, PRESSURE_METER_FILL_RGBA,
    PRESSURE_METER_HEIGHT_PX, PRESSURE_METER_TRACK_RGBA, PRESSURE_METER_WIDTH_PX, USED_BAR_TRACK_RGBA,
} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

// The top-bar graph's size, as the brief names it for the no-throw rows.
const SURFACE_WIDTH_PX = 30;
const SURFACE_HEIGHT_PX = 16;
// A small area whose slot edges and heights are whole numbers, for the geometry rows.
const SMALL_WIDTH_PX = 3;
const SMALL_HEIGHT_PX = 10;
const TEST_FILL_RGBA = [1, 0, 0, 1];
const TEST_TRACK_RGBA = [0, 0, 1, 0.5];
const RGBA_COMPONENT_COUNT = 4;
// The card's pressure meter: 22×10, three 6 px cells with 2 px gaps (x 0, 8 and 16), and a 2 px no-data dash
// across the middle (y 4).
const METER_CELL_RECTS = [[0, 0, 6, 10], [8, 0, 6, 10], [16, 0, 6, 10]];
const METER_NO_DATA_DASH_RECT = [0, 4, 22, 2];

/**
 * Runs a drawing callback against a real Cairo context on a fresh ARGB32 image surface, then frees both.
 *
 * @param {number} widthPx - Surface width.
 * @param {number} heightPx - Surface height.
 * @param {(cr: Cairo.Context) => void} draw - The drawing under test.
 * @returns {void}
 */
function drawOnImageSurface(widthPx, heightPx, draw) {
    const surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, widthPx, heightPx);
    const cr = new Cairo.Context(surface);
    try {
        draw(cr);
    } finally {
        cr.$dispose();
        surface.finish();
    }
}

/**
 * Wraps a real Cairo context so every method call is recorded, then forwarded to the real context unchanged.
 *
 * @param {Cairo.Context} cr - The real context.
 * @param {Array<Array<*>>} calls - Receives [methodName, ...args] per call.
 * @returns {Cairo.Context} A context that behaves exactly like cr.
 */
function recordingContext(cr, calls) {
    return new Proxy(cr, {
        get(target, property) {
            const member = target[property];
            if (typeof member !== 'function')
                return member;
            return (...args) => {
                calls.push([property, ...args]);
                return member.apply(target, args);
            };
        },
    });
}

/**
 * Records the Cairo calls a pressure meter makes for one band, leaving out newPath.
 *
 * @param {*} band - What the card would pass: a band, null, or anything else.
 * @returns {Array<Array<*>>} [methodName, ...args] per call.
 */
function pressureMeterCalls(band) {
    const calls = [];
    drawOnImageSurface(PRESSURE_METER_WIDTH_PX, PRESSURE_METER_HEIGHT_PX, cr =>
        drawPressureMeter(recordingContext(cr, calls), PRESSURE_METER_WIDTH_PX, PRESSURE_METER_HEIGHT_PX, band,
            TEST_FILL_RGBA, TEST_TRACK_RGBA));
    return calls.filter(([methodName]) => methodName !== 'newPath');
}

/**
 * The calls that fill some rectangles in one colour.
 *
 * @param {number[]} rgba - The colour.
 * @param {Array<number[]>} rects - [x, y, width, height] each.
 * @returns {Array<Array<*>>} setSourceRGBA, one rectangle per rect, then fill.
 */
const fillCalls = (rgba, rects) => [['setSourceRGBA', ...rgba], ...rects.map(rect => ['rectangle', ...rect]), ['fill']];

/**
 * Says whether a value is an [red, green, blue, alpha] colour with every component a number from 0 to 1.
 *
 * @param {*} rgba - The candidate colour.
 * @returns {boolean} True for a usable Cairo source colour.
 */
function isRgbaInUnitRange(rgba) {
    return Array.isArray(rgba) && rgba.length === RGBA_COMPONENT_COUNT &&
        rgba.every(component => Number.isFinite(component) && component >= 0 && component <= 1);
}

test('drawAreaGraph on a 30×16 surface does not throw for an empty history', () =>
    drawOnImageSurface(SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, cr =>
        drawAreaGraph(cr, SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, [], CPU_GRAPH_RGBA, BASELINE_RGBA)));
test('drawAreaGraph on a 30×16 surface does not throw for an all-null history', () =>
    drawOnImageSurface(SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, cr =>
        drawAreaGraph(cr, SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, new Array(SURFACE_WIDTH_PX).fill(null),
            CPU_GRAPH_RGBA, BASELINE_RGBA)));
test('drawAreaGraph on a 30×16 surface does not throw for mixed values and gaps', () =>
    drawOnImageSurface(SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, cr =>
        drawAreaGraph(cr, SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, [null, 0, 0.25, null, 0.5, 1, 0.75, null],
            MEMORY_GRAPH_RGBA, BASELINE_RGBA)));
test('drawAreaGraph on a 30×16 surface does not throw for values above 1', () =>
    drawOnImageSurface(SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, cr =>
        drawAreaGraph(cr, SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, [1.5, 2, 100, 0.5],
            CPU_GRAPH_RGBA, BASELINE_RGBA)));
test('drawPressureMeter on a 22×10 surface does not throw for any band, no data, or nonsense', () =>
    drawOnImageSurface(PRESSURE_METER_WIDTH_PX, PRESSURE_METER_HEIGHT_PX, cr => {
        for (const band of [0, 1, 2, 3, null, undefined, NaN, Infinity, 4, -1, 1.5, '2'])
            drawPressureMeter(cr, PRESSURE_METER_WIDTH_PX, PRESSURE_METER_HEIGHT_PX, band, TEST_FILL_RGBA, TEST_TRACK_RGBA);
    }));
test('drawUsedBar on a 30×16 surface does not throw for null, NaN, above 1 or below 0', () =>
    drawOnImageSurface(SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, cr => {
        for (const fraction of [null, NaN, 1.5, -0.5])
            drawUsedBar(cr, SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, fraction, TEST_FILL_RGBA, TEST_TRACK_RGBA);
    }));

test('areaGraphPolygons: one slot per sample, filled from the baseline up to its value', () =>
    assertEqual(areaGraphPolygons([0.5, 1], 2, SMALL_HEIGHT_PX),
        [[[0, 10], [0, 5], [1, 5], [1, 0], [2, 0], [2, 10]]]));
test('areaGraphPolygons: a null splits the history into two runs (a gap, never a bridge)', () =>
    assertEqual(areaGraphPolygons([0.5, null, 0.5], SMALL_WIDTH_PX, SMALL_HEIGHT_PX), [
        [[0, 10], [0, 5], [1, 5], [1, 10]],
        [[2, 10], [2, 5], [3, 5], [3, 10]],
    ]));
test('areaGraphPolygons: values clamp to 0–1, so 1.5 stops at the top and −0.5 at the baseline', () =>
    assertEqual(areaGraphPolygons([1.5, -0.5], 2, SMALL_HEIGHT_PX),
        [[[0, 10], [0, 0], [1, 0], [1, 10], [2, 10], [2, 10]]]));
test('areaGraphPolygons: NaN, undefined and a string are gaps, so nothing non-finite reaches Cairo', () =>
    assertEqual(areaGraphPolygons([NaN, 0.5, undefined, '0.5'], 4, SMALL_HEIGHT_PX),
        [[[1, 10], [1, 5], [2, 5], [2, 10]]]));
test('areaGraphPolygons: nothing to fill for [], all-null, or a zero-sized area', () => {
    assertEqual(areaGraphPolygons([], SMALL_WIDTH_PX, SMALL_HEIGHT_PX), [], 'empty history');
    assertEqual(areaGraphPolygons([null, null], SMALL_WIDTH_PX, SMALL_HEIGHT_PX), [], 'all null');
    assertEqual(areaGraphPolygons([0.5], 0, SMALL_HEIGHT_PX), [], 'zero width');
    assertEqual(areaGraphPolygons([0.5], SMALL_WIDTH_PX, 0), [], 'zero height');
});

test('padWithLeadingGaps right-aligns a short history and keeps the newest of a long one', () => {
    assertEqual(padWithLeadingGaps([0.1, 0.2], 4), [null, null, 0.1, 0.2], 'short history');
    assertEqual(padWithLeadingGaps([0.1, 0.2, 0.3, 0.4, 0.5], 3), [0.3, 0.4, 0.5], 'long history');
    assertEqual(padWithLeadingGaps([0.1, 0.2], 0), [], 'no slots');
});

test('usedBarFillWidthPx: the used share of the width, clamped; null and NaN fill nothing', () => {
    assertEqual(usedBarFillWidthPx(200, 0.25), 50, 'a quarter');
    assertEqual(usedBarFillWidthPx(200, 1.5), 200, 'above 1');
    assertEqual(usedBarFillWidthPx(200, -0.5), 0, 'below 0');
    assertEqual(usedBarFillWidthPx(200, null), 0, 'null is no data');
    assertEqual(usedBarFillWidthPx(200, NaN), 0, 'NaN is no data');
});

test('drawAreaGraph fills the baseline in its colour, then exactly areaGraphPolygons in the fill colour', () => {
    const fractions = [0.5, null, 1];
    const calls = [];
    drawOnImageSurface(SMALL_WIDTH_PX, SMALL_HEIGHT_PX, cr =>
        drawAreaGraph(recordingContext(cr, calls), SMALL_WIDTH_PX, SMALL_HEIGHT_PX, fractions,
            TEST_FILL_RGBA, BASELINE_RGBA));
    const baselineTopPx = SMALL_HEIGHT_PX - GRAPH_BASELINE_THICKNESS_PX;
    const expectedPathCalls = areaGraphPolygons(fractions, SMALL_WIDTH_PX, SMALL_HEIGHT_PX).flatMap(polygon => [
        ['moveTo', ...polygon[0]],
        ...polygon.slice(1).map(point => ['lineTo', ...point]),
        ['closePath'],
    ]);
    assertEqual(calls.filter(([methodName]) => methodName !== 'newPath'), [
        ['setSourceRGBA', ...BASELINE_RGBA],
        ['rectangle', 0, baselineTopPx, SMALL_WIDTH_PX, GRAPH_BASELINE_THICKNESS_PX],
        ['fill'],
        ['setSourceRGBA', ...TEST_FILL_RGBA],
        ...expectedPathCalls,
        ['fill'],
    ]);
});

test('drawUsedBar fills the used share in the fill colour and only the rest in the track colour', () => {
    const calls = [];
    drawOnImageSurface(SURFACE_WIDTH_PX, SURFACE_HEIGHT_PX, cr =>
        drawUsedBar(recordingContext(cr, calls), 200, SURFACE_HEIGHT_PX, 0.25, TEST_FILL_RGBA, TEST_TRACK_RGBA));
    assertEqual(calls.filter(([methodName]) => methodName !== 'newPath'), [
        ['setSourceRGBA', ...TEST_TRACK_RGBA],
        ['rectangle', 50, 0, 150, SURFACE_HEIGHT_PX],
        ['fill'],
        ['setSourceRGBA', ...TEST_FILL_RGBA],
        ['rectangle', 0, 0, 50, SURFACE_HEIGHT_PX],
        ['fill'],
    ]);
});

test('pressureMeterCellRects: three equal full-height cells with 2 px gaps; none in a zero-sized area', () => {
    assertEqual(pressureMeterCellRects(PRESSURE_METER_WIDTH_PX, PRESSURE_METER_HEIGHT_PX), METER_CELL_RECTS);
    assertEqual(pressureMeterCellRects(0, PRESSURE_METER_HEIGHT_PX), [], 'zero width');
    assertEqual(pressureMeterCellRects(PRESSURE_METER_WIDTH_PX, 0), [], 'zero height');
});
test('drawPressureMeter band 1: the first cell in the fill colour, the other two as empty cells in the track colour',
    () => assertEqual(pressureMeterCalls(1),
        [...fillCalls(TEST_FILL_RGBA, METER_CELL_RECTS.slice(0, 1)), ...fillCalls(TEST_TRACK_RGBA, METER_CELL_RECTS.slice(1))]));
test('drawPressureMeter band 0 draws three empty cells and band 3 three filled ones', () => {
    assertEqual(pressureMeterCalls(0), fillCalls(TEST_TRACK_RGBA, METER_CELL_RECTS), 'band 0');
    assertEqual(pressureMeterCalls(3), fillCalls(TEST_FILL_RGBA, METER_CELL_RECTS), 'band 3');
});
test('drawPressureMeter with no data draws no cell at all, only a dash across the middle: a shape, not a colour', () =>
    assertEqual(pressureMeterCalls(null), fillCalls(TEST_TRACK_RGBA, [METER_NO_DATA_DASH_RECT])));
test('drawPressureMeter clamps a band above 3 or below 0, and draws anything not a finite number as no data', () => {
    assertEqual(pressureMeterCalls(4), pressureMeterCalls(3), 'above 3');
    assertEqual(pressureMeterCalls(-1), pressureMeterCalls(0), 'below 0');
    for (const notABand of [undefined, NaN, Infinity, '2'])
        assertEqual(pressureMeterCalls(notABand), pressureMeterCalls(null), String(notABand));
});

test('graph colour constants are [red, green, blue, alpha], each 0–1', () => {
    assertEqual(isRgbaInUnitRange(CPU_GRAPH_RGBA), true, 'CPU_GRAPH_RGBA');
    assertEqual(isRgbaInUnitRange(MEMORY_GRAPH_RGBA), true, 'MEMORY_GRAPH_RGBA');
    assertEqual(isRgbaInUnitRange(BASELINE_RGBA), true, 'BASELINE_RGBA');
    assertEqual(isRgbaInUnitRange(USED_BAR_TRACK_RGBA), true, 'USED_BAR_TRACK_RGBA');
    assertEqual(isRgbaInUnitRange(PRESSURE_METER_FILL_RGBA), true, 'PRESSURE_METER_FILL_RGBA');
    assertEqual(isRgbaInUnitRange(PRESSURE_METER_TRACK_RGBA), true, 'PRESSURE_METER_TRACK_RGBA');
});
