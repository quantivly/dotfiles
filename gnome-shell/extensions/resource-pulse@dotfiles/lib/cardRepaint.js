// What the desktop card repaints, decided without the Shell; card.js applies each plan to its labels and drawing areas.
//
// - While the card is frozen (a window covers it: extension.js), a new snapshot is only recorded, and nothing is
//   repainted or relaid out, except the frozen repaint extension.js asks for every FROZEN_REPAINT_INTERVAL_SECONDS.
// - A frozen card is dimmed (ruling R21), so one misjudged as covered reads as stale, never as live: freezing renders
//   once, dimmed (a render nobody sees when the card really is covered), and so does each frozen repaint.
// - Unfreezing renders at once, undimmed, from the latest snapshot recorded.
// - Each render sets every label (card.js skips a label whose text is unchanged) and redraws the CPU graph, whose
//   history moves on with every sample. A "waiting on" meter and the memory bar are redrawn only when what they draw
//   differs from what they last drew: a meter's band, which changes rarely, the bar's filled width in whole pixels,
//   which a memory change of a few MiB leaves alone, and the dim, which changes their opacity.
//
// Pure: no Shell, St, Clutter or Meta import, so it runs under plain gjs.
import {CARD_MEMORY_BAR_WIDTH_PX} from './constants.js';
import {cardText} from './format.js';

/** What a meter or the memory bar has drawn before the first render: nothing, so its first value is a change. */
const NOTHING_DRAWN_YET = Symbol('nothing drawn yet');

/**
 * How much of the memory bar a fraction fills, in whole logical pixels: what decides whether the bar is redrawn.
 *
 * @param {number|null} memoryFraction - Memory used, 0–1; null for no data.
 * @returns {number|null} The filled width, rounded; null for no data (an all-track bar).
 */
function memoryBarFillPx(memoryFraction) {
    return memoryFraction === null ? null : Math.round(memoryFraction * CARD_MEMORY_BAR_WIDTH_PX);
}

/**
 * @typedef {object} ShownState
 * @property {import('../pulseClient.js').Snapshot|null} snapshot - The latest snapshot, or null before the first.
 * @property {string|null} lastGoodClockLabel - 'HH:MM' of the last snapshot with data, for "no data since".
 * @property {number|null} newestMemoryFraction - The newest memory used fraction in the client's history, which the
 *     memory bar draws; null for no data.
 */

/**
 * @typedef {object} RepaintPlan
 * @property {import('./format.js').CardText} text - Every string on the card, and each meter's band
 *     (text.waitingOnMeters).
 * @property {number[]} changedMeterIndexes - The "waiting on" meters whose band differs from the one they drew, in
 *     waitingOnMeters order: only these are redrawn.
 * @property {boolean} isMemoryBarChanged - The memory bar's filled width, in whole pixels, differs from the one it
 *     drew: only then is it redrawn.
 * @property {number|null} memoryFraction - The fraction the memory bar draws when it is redrawn.
 * @property {boolean} isDimmed - The card is frozen, so the render is dimmed (card.js's frozen pseudo-class).
 * @property {boolean} isDimChanged - The dim differs from the last render's: card.js adds or removes the pseudo-class
 *     only then, and every meter and the memory bar are redrawn at the new opacity.
 */

export class CardRepaintPlanner {
    /**
     * Starts unfrozen and undimmed, with nothing recorded and nothing drawn.
     */
    constructor() {
        this._isFrozen = false;
        /** @type {ShownState|null} */
        this._latestShownState = null;
        /** @type {Array<0|1|2|3|null>|symbol} */
        this._drawnMeterBands = NOTHING_DRAWN_YET;
        /** @type {number|null|symbol} */
        this._drawnMemoryBarFillPx = NOTHING_DRAWN_YET;
        this._isDrawnDimmed = false;
    }

    /** @returns {boolean} True while the card is frozen. */
    get isFrozen() {
        return this._isFrozen;
    }

    /**
     * Records the state the card should show, and plans its render unless the card is frozen.
     *
     * @param {ShownState} shownState - The latest snapshot, its clock label and the newest memory fraction.
     * @returns {RepaintPlan|null} What to repaint now, or null while frozen (recorded only).
     */
    show(shownState) {
        this._latestShownState = shownState;
        return this._isFrozen ? null : this._planRender();
    }

    /**
     * Freezes or unfreezes the card, planning a render of the latest recorded state at once either way: freezing
     * renders it dimmed, unfreezing undimmed. Setting the state the card already has plans nothing, and so does a
     * change with nothing recorded yet.
     *
     * @param {boolean} isFrozen - True while a window covers the card.
     * @returns {RepaintPlan|null} The freeze's or the reveal's render, or null.
     */
    setFrozen(isFrozen) {
        if (isFrozen === this._isFrozen)
            return null;
        this._isFrozen = isFrozen;
        if (this._latestShownState === null)
            return null;
        return this._planRender();
    }

    /**
     * Plans the frozen card's periodic repaint (extension.js asks every FROZEN_REPAINT_INTERVAL_SECONDS while the card
     * counts as covered): the latest recorded state, still dimmed. A card misjudged as covered then shows numbers at
     * most that old, dimmed, rather than stale ones.
     *
     * @returns {RepaintPlan|null} The dimmed render, or null when unfrozen (an unfrozen card renders every snapshot
     *     already) or with nothing recorded yet.
     */
    repaintFrozen() {
        if (!this._isFrozen || this._latestShownState === null)
            return null;
        return this._planRender();
    }

    /**
     * Plans a render of the latest recorded state, dimmed while the card is frozen. Each meter's band and the memory
     * bar's filled width are compared with what was last drawn, and a change of dim redraws them all, since each draws
     * at the new opacity. The new values are recorded as drawn: card.js applies every plan it is given.
     *
     * @returns {RepaintPlan} The plan.
     */
    _planRender() {
        const {snapshot, lastGoodClockLabel, newestMemoryFraction} = this._latestShownState;
        const text = cardText(snapshot, lastGoodClockLabel);
        const isDimmed = this._isFrozen;
        const isDimChanged = isDimmed !== this._isDrawnDimmed;
        const meterBands = text.waitingOnMeters.map(meter => meter.band);
        const haveMetersDrawn = this._drawnMeterBands !== NOTHING_DRAWN_YET;
        const changedMeterIndexes = meterBands.flatMap((band, meterIndex) => {
            const isUnchanged = !isDimChanged && haveMetersDrawn && band === this._drawnMeterBands[meterIndex];
            return isUnchanged ? [] : [meterIndex];
        });
        const memoryBarFillPxNow = memoryBarFillPx(newestMemoryFraction);
        const isMemoryBarChanged = isDimChanged || memoryBarFillPxNow !== this._drawnMemoryBarFillPx;
        this._drawnMeterBands = meterBands;
        this._drawnMemoryBarFillPx = memoryBarFillPxNow;
        this._isDrawnDimmed = isDimmed;
        return {
            text, changedMeterIndexes, isMemoryBarChanged, memoryFraction: newestMemoryFraction, isDimmed, isDimChanged,
        };
    }
}
