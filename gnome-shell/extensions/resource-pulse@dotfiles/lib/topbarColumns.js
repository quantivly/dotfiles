// The top bar's columns in whole device pixels: what decides whether a top-bar graph draws again (indicator.js).
//
// St.DrawingArea's queue_repaint() is neither cheap nor lazy: it drops the graph's buffer, runs the cairo handler and
// uploads a new texture, mapped or not. On an idle machine a graph's columns rarely move by even one device pixel, so
// the indicator compares the columns its history gives now with the columns it last drew, and asks for a repaint only
// when they differ. It draws those very levels (columnFractions), so what is compared is what is drawn.
//
// A column is a level from 0 to the graph's height in device pixels, rounded up, so any value above zero shows one
// pixel and an idle CPU stays inside one level; GAP_COLUMN is a slot with no data. Pure: no Shell, St, Clutter or
// Meta import, so it runs under plain gjs.

/** The column of a slot with no data: no level at all, so it differs from every level, 0 included. */
export const GAP_COLUMN = -1;

/**
 * A graph's columns with the number of device pixels they were quantised to, so that columns quantised at one
 * resource scale never compare equal to columns quantised at another.
 *
 * @typedef {object} GraphColumns
 * @property {number[]} columns - One level per slot (quantisedColumns()), or GAP_COLUMN for a gap.
 * @property {number} levelCount - deviceLevelCount() of the height and resource scale they were quantised at.
 */

/**
 * Clamps a fraction to 0–1, treating anything that is not a finite number as a gap, as graph.js does with what it
 * draws. Repeated here because graph.js keeps its own private and nothing under lib/ imports from outside lib/.
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
 * How many device pixels a graph's height spans: its height in logical pixels times its resource scale rounded up,
 * since a drawing at a fractional scale goes into a buffer of the next whole scale.
 *
 * @param {number} heightPx - The graph's height in logical pixels, as its drawing area reports it while it repaints.
 * @param {number} resourceScale - The graph's resource scale (Clutter.Actor.get_resource_scale()).
 * @returns {number} The levels a column can take above 0.
 */
export function deviceLevelCount(heightPx, resourceScale) {
    return heightPx * Math.ceil(resourceScale);
}

/**
 * Quantises a graph's slots to whole device pixels: each value's level, rounded up so any value above zero is at
 * least one pixel.
 *
 * @param {Array<number|null>} slotFractions - One entry per slot, oldest first: a fraction, or null for no data.
 * @param {number} heightPx - The graph's height in logical pixels.
 * @param {number} resourceScale - The graph's resource scale.
 * @returns {number[]} One column per slot: a level from 0 to deviceLevelCount(), or GAP_COLUMN for a gap.
 */
export function quantisedColumns(slotFractions, heightPx, resourceScale) {
    const levelCount = deviceLevelCount(heightPx, resourceScale);
    return slotFractions.map(value => {
        const fraction = clampedFractionOrGap(value);
        return fraction === null ? GAP_COLUMN : Math.ceil(fraction * levelCount);
    });
}

/**
 * Says whether two sets of columns draw the same graph.
 *
 * @param {number[]|null} first - Columns, or null for none.
 * @param {number[]|null} second - Columns, or null for none.
 * @returns {boolean} True only when both exist, have one length and match slot for slot; false when either is null.
 */
export function areColumnsEqual(first, second) {
    if (!Array.isArray(first) || !Array.isArray(second) || first.length !== second.length)
        return false;
    return first.every((column, slotIndex) => column === second[slotIndex]);
}

/**
 * Says whether a graph must draw again: when it has drawn nothing yet, when its current columns were quantised to
 * another number of device pixels than the ones it drew (another resource scale), or when a column differs.
 *
 * @param {object} graphColumns - What to compare.
 * @param {GraphColumns|null} graphColumns.drawnColumns - The columns the graph last drew, or null for none yet. Any
 *     other field the caller records with them (the height they were drawn at) is ignored.
 * @param {GraphColumns|null} graphColumns.currentColumns - The columns its history gives now; read only when
 *     something has been drawn, so it may be null before then.
 * @returns {boolean} True when a repaint would change what the graph shows.
 */
export function isGraphRepaintNeeded({drawnColumns, currentColumns}) {
    if (drawnColumns === null || drawnColumns.levelCount !== currentColumns.levelCount)
        return true;
    return !areColumnsEqual(drawnColumns.columns, currentColumns.columns);
}

/**
 * Turns columns back into what the painter draws: each level as a fraction of the graph's height, so the levels
 * drawn are exactly the ones compared.
 *
 * @param {number[]} columns - Columns from quantisedColumns() at the same height and scale.
 * @param {number} heightPx - The graph's height in logical pixels.
 * @param {number} resourceScale - The graph's resource scale.
 * @returns {Array<number|null>} One fraction per column, 0–1, and null for a gap; 0 for every level of a graph with
 *     no height yet, which has nothing to draw.
 */
export function columnFractions(columns, heightPx, resourceScale) {
    const levelCount = deviceLevelCount(heightPx, resourceScale);
    return columns.map(column => {
        if (column === GAP_COLUMN)
            return null;
        return levelCount > 0 ? column / levelCount : 0;
    });
}
