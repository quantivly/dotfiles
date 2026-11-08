// Cairo drawing for the top-bar graphs and the desktop card. Pure functions of a Cairo context and plain numbers,
// with no Shell or St import (the Shell glue hands in the context), so they run under plain `gjs -m` against an
// image surface.
//
// They run inside gnome-shell on every repaint, so no history can make them throw: a value that is not a finite
// number is a gap (no data, drawn as nothing), every value is clamped to 0–1, and an area with no size draws
// nothing. Sizes are in the context's units; St's drawing area hands over logical pixels with the context
// already scaled to the monitor, so the shapes stay sharp at any scale factor.
import {
    GRAPH_BASELINE_THICKNESS_PX, PRESSURE_METER_CELL_GAP_PX, PRESSURE_METER_CELLS,
    PRESSURE_METER_NO_DATA_DASH_THICKNESS_PX,
} from './lib/constants.js';

/**
 * Clamps a fraction to 0–1, treating anything that is not a finite number as a gap.
 *
 * @param {*} value - A history entry: a fraction, or null for no data.
 * @returns {number|null} The clamped fraction, or null for a gap.
 */
function clampedFractionOrGap(value) {
    if (typeof value !== 'number' || !Number.isFinite(value))
        return null;
    return Math.min(1, Math.max(0, value));
}

/**
 * Says whether an area has something to draw into.
 *
 * @param {number} widthPx - Area width.
 * @param {number} heightPx - Area height.
 * @returns {boolean} False for a zero, negative or non-finite size.
 */
function hasDrawableArea(widthPx, heightPx) {
    return Number.isFinite(widthPx) && Number.isFinite(heightPx) && widthPx > 0 && heightPx > 0;
}

/**
 * Right-aligns a history in a fixed number of slots, so the newest sample always sits at the right edge and the
 * graph does not stretch while its history fills. Slots older than the history are gaps.
 *
 * @param {Array<number|null>} fractions - The history, oldest first.
 * @param {number} slotCount - Slots in the graph.
 * @returns {Array<number|null>} Exactly slotCount entries: leading nulls, then the newest fractions.
 */
export function padWithLeadingGaps(fractions, slotCount) {
    if (slotCount <= 0)
        return [];
    const newestFractions = fractions.slice(-slotCount);
    const gapCount = slotCount - newestFractions.length;
    return [...new Array(gapCount).fill(null), ...newestFractions];
}

/**
 * The shapes of a stepped area graph. Each sample owns one equal-width slot, filled from the bottom up to its
 * value; consecutive samples with data form one polygon, and a gap ends it, so no data is never bridged.
 *
 * @param {Array<number|null>} fractions - The history, oldest first, one slot each.
 * @param {number} widthPx - Graph width.
 * @param {number} heightPx - Graph height.
 * @returns {Array<Array<[number, number]>>} One closed polygon per run of samples with data, as [x, y] points
 *     starting and ending on the bottom edge; empty when there is nothing to fill.
 */
export function areaGraphPolygons(fractions, widthPx, heightPx) {
    if (fractions.length === 0 || !hasDrawableArea(widthPx, heightPx))
        return [];
    const slotWidthPx = widthPx / fractions.length;
    const polygons = [];
    let currentPolygon = null;
    fractions.forEach((value, slotIndex) => {
        const fraction = clampedFractionOrGap(value);
        if (fraction === null) {
            currentPolygon = null;
            return;
        }
        const slotLeftPx = slotIndex * slotWidthPx;
        const slotRightPx = slotLeftPx + slotWidthPx;
        const valueTopPx = heightPx - fraction * heightPx;
        if (currentPolygon === null) {
            currentPolygon = [[slotLeftPx, heightPx]];
            polygons.push(currentPolygon);
        }
        currentPolygon.push([slotLeftPx, valueTopPx], [slotRightPx, valueTopPx]);
    });
    for (const polygon of polygons) {
        const [lastX] = polygon[polygon.length - 1];
        polygon.push([lastX, heightPx]);
    }
    return polygons;
}

/**
 * Draws a history as a stepped area graph over a faint baseline. The baseline spans the whole width, so a graph
 * with no data still reads as a graph (a muted flat line), and a gap shows as baseline only.
 *
 * @param {Cairo.Context} cr - Where to draw.
 * @param {number} widthPx - Graph width.
 * @param {number} heightPx - Graph height.
 * @param {Array<number|null>} fractions - The history, oldest first; values are clamped to 0–1 and a null is a
 *     gap.
 * @param {number[]} fillRgba - Area colour, as [red, green, blue, alpha], each 0–1.
 * @param {number[]} baselineRgba - Baseline colour, as [red, green, blue, alpha], each 0–1.
 * @returns {void}
 */
export function drawAreaGraph(cr, widthPx, heightPx, fractions, fillRgba, baselineRgba) {
    if (!hasDrawableArea(widthPx, heightPx))
        return;
    const baselineThicknessPx = Math.min(GRAPH_BASELINE_THICKNESS_PX, heightPx);
    cr.newPath();
    cr.setSourceRGBA(...baselineRgba);
    cr.rectangle(0, heightPx - baselineThicknessPx, widthPx, baselineThicknessPx);
    cr.fill();

    const polygons = areaGraphPolygons(fractions, widthPx, heightPx);
    if (polygons.length === 0)
        return;
    cr.setSourceRGBA(...fillRgba);
    for (const [[startX, startY], ...followingPoints] of polygons) {
        cr.moveTo(startX, startY);
        for (const [x, y] of followingPoints)
            cr.lineTo(x, y);
        cr.closePath();
    }
    cr.fill();
}

/**
 * How much of a used bar to fill.
 *
 * @param {number} widthPx - Bar width.
 * @param {number|null} fraction - Share used, 0–1; null (or anything not a finite number) for no data.
 * @returns {number} The filled width, from 0 to widthPx; 0 for no data.
 */
export function usedBarFillWidthPx(widthPx, fraction) {
    const clampedFraction = clampedFractionOrGap(fraction);
    return clampedFraction === null ? 0 : clampedFraction * widthPx;
}

/**
 * Draws a horizontal bar: the used share from the left in the fill colour, the rest in the track colour. With no
 * data the whole bar is track.
 *
 * @param {Cairo.Context} cr - Where to draw.
 * @param {number} widthPx - Bar width.
 * @param {number} heightPx - Bar height.
 * @param {number|null} fraction - Share used, clamped to 0–1; null for no data.
 * @param {number[]} fillRgba - Used colour, as [red, green, blue, alpha], each 0–1.
 * @param {number[]} trackRgba - Unused colour, as [red, green, blue, alpha], each 0–1.
 * @returns {void}
 */
export function drawUsedBar(cr, widthPx, heightPx, fraction, fillRgba, trackRgba) {
    if (!hasDrawableArea(widthPx, heightPx))
        return;
    const fillWidthPx = usedBarFillWidthPx(widthPx, fraction);
    cr.newPath();
    if (fillWidthPx < widthPx) {
        cr.setSourceRGBA(...trackRgba);
        cr.rectangle(fillWidthPx, 0, widthPx - fillWidthPx, heightPx);
        cr.fill();
    }
    if (fillWidthPx > 0) {
        cr.setSourceRGBA(...fillRgba);
        cr.rectangle(0, 0, fillWidthPx, heightPx);
        cr.fill();
    }
}

/**
 * The cells of a pressure meter, left to right: PRESSURE_METER_CELLS equal, full-height cells with
 * PRESSURE_METER_CELL_GAP_PX between them.
 *
 * @param {number} widthPx - Meter width.
 * @param {number} heightPx - Meter height.
 * @returns {Array<[number, number, number, number]>} One [x, y, width, height] per cell; empty when the area has no
 *     room for them.
 */
export function pressureMeterCellRects(widthPx, heightPx) {
    if (!hasDrawableArea(widthPx, heightPx))
        return [];
    const gapsWidthPx = (PRESSURE_METER_CELLS - 1) * PRESSURE_METER_CELL_GAP_PX;
    const cellWidthPx = (widthPx - gapsWidthPx) / PRESSURE_METER_CELLS;
    if (cellWidthPx <= 0)
        return [];
    return Array.from({length: PRESSURE_METER_CELLS}, (_unused, cellIndex) =>
        [cellIndex * (cellWidthPx + PRESSURE_METER_CELL_GAP_PX), 0, cellWidthPx, heightPx]);
}

/**
 * Turns what the card passes for a pressure band into a cell count, treating anything that is not a finite
 * number as no data.
 *
 * @param {*} band - A band from lib/pressure.js: 0–3, or null for no data.
 * @returns {number|null} Filled cells, 0 to PRESSURE_METER_CELLS, or null for no data.
 */
function filledCellCountOrNoData(band) {
    if (typeof band !== 'number' || !Number.isFinite(band))
        return null;
    return Math.min(PRESSURE_METER_CELLS, Math.max(0, Math.floor(band)));
}

/**
 * Fills some rectangles in one colour, as one path.
 *
 * @param {Cairo.Context} cr - Where to draw.
 * @param {Array<[number, number, number, number]>} rects - [x, y, width, height] each.
 * @param {number[]} rgba - Their colour, as [red, green, blue, alpha], each 0–1.
 * @returns {void}
 */
function fillRects(cr, rects, rgba) {
    if (rects.length === 0)
        return;
    cr.setSourceRGBA(...rgba);
    for (const rect of rects)
        cr.rectangle(...rect);
    cr.fill();
}

/**
 * Draws a pressure meter: the first `band` cells in the fill colour and the rest as empty cells in the track
 * colour. No data draws no cell at all, only a dash across the middle, so it differs from band 0 (three empty
 * cells) in shape and not only in colour.
 *
 * @param {Cairo.Context} cr - Where to draw.
 * @param {number} widthPx - Meter width.
 * @param {number} heightPx - Meter height.
 * @param {0|1|2|3|null} band - Pressure band (clamped to 0–3), or null for no data; anything that is not a finite
 *     number is no data.
 * @param {number[]} fillRgba - Filled cells, as [red, green, blue, alpha], each 0–1.
 * @param {number[]} trackRgba - Empty cells and the no-data dash, as [red, green, blue, alpha], each 0–1.
 * @returns {void}
 */
export function drawPressureMeter(cr, widthPx, heightPx, band, fillRgba, trackRgba) {
    if (!hasDrawableArea(widthPx, heightPx))
        return;
    cr.newPath();
    const filledCellCount = filledCellCountOrNoData(band);
    if (filledCellCount === null) {
        const dashThicknessPx = Math.min(PRESSURE_METER_NO_DATA_DASH_THICKNESS_PX, heightPx);
        fillRects(cr, [[0, (heightPx - dashThicknessPx) / 2, widthPx, dashThicknessPx]], trackRgba);
        return;
    }
    const cellRects = pressureMeterCellRects(widthPx, heightPx);
    fillRects(cr, cellRects.slice(0, filledCellCount), fillRgba);
    fillRects(cr, cellRects.slice(filledCellCount), trackRgba);
}
