// What the desktop card repaints, decided without the Shell; card.js applies each plan to its labels and drawing areas.
//
// - While the card is frozen (a window covers it: extension.js), a new snapshot is only recorded, and nothing is
//   repainted or relaid out.
// - Unfreezing renders at once, from the latest snapshot recorded.
// - Each render sets every label (card.js skips a label whose text is unchanged) and redraws the CPU graph, whose
//   history moves on with every sample. A "waiting on" meter and the memory bar are redrawn only when what they draw
//   differs from what they last drew: a meter's band, which changes rarely, and the bar's filled width in whole
//   pixels, which a memory change of a few MiB leaves alone.
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
 */

export class CardRepaintPlanner {
    /**
     * Starts unfrozen, with nothing recorded and nothing drawn.
     */
    constructor() {
        this._isFrozen = false;
        /** @type {ShownState|null} */
        this._latestShownState = null;
        /** @type {Array<0|1|2|3|null>|symbol} */
        this._drawnMeterBands = NOTHING_DRAWN_YET;
        /** @type {number|null|symbol} */
        this._drawnMemoryBarFillPx = NOTHING_DRAWN_YET;
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
     * Freezes or unfreezes the card. Unfreezing plans a render of the latest recorded state at once; freezing, and
     * setting the state the card already has, plan nothing.
     *
     * @param {boolean} isFrozen - True while a window covers the card.
     * @returns {RepaintPlan|null} The reveal's render, or null.
     */
    setFrozen(isFrozen) {
        if (isFrozen === this._isFrozen)
            return null;
        this._isFrozen = isFrozen;
        if (isFrozen || this._latestShownState === null)
            return null;
        return this._planRender();
    }

    /**
     * Plans a render of the latest recorded state, comparing each meter's band and the memory bar's filled width with
     * what was last drawn, and records the new values as drawn: card.js applies every plan it is given.
     *
     * @returns {RepaintPlan} The plan.
     */
    _planRender() {
        const {snapshot, lastGoodClockLabel, newestMemoryFraction} = this._latestShownState;
        const text = cardText(snapshot, lastGoodClockLabel);
        const meterBands = text.waitingOnMeters.map(meter => meter.band);
        const haveMetersDrawn = this._drawnMeterBands !== NOTHING_DRAWN_YET;
        const changedMeterIndexes = meterBands.flatMap((band, meterIndex) => {
            const isUnchanged = haveMetersDrawn && band === this._drawnMeterBands[meterIndex];
            return isUnchanged ? [] : [meterIndex];
        });
        const memoryBarFillPxNow = memoryBarFillPx(newestMemoryFraction);
        const isMemoryBarChanged = memoryBarFillPxNow !== this._drawnMemoryBarFillPx;
        this._drawnMeterBands = meterBands;
        this._drawnMemoryBarFillPx = memoryBarFillPxNow;
        return {text, changedMeterIndexes, isMemoryBarChanged, memoryFraction: newestMemoryFraction};
    }
}
