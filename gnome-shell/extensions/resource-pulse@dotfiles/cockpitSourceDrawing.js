// When and how a surface of the cockpit draws the cockpit service's sources (ruling D22): the one pacing and the one
// data-card drawing that the cockpit's layer (cockpitLayer.js) and the top-bar dropdown's sessions card (indicator.js)
// share. GLib and lib/ only (no Shell, St, Clutter or Meta): the cards and the client are reached through the methods
// they offer, so it runs under plain gjs, with its timeouts injectable.
//
// - CockpitSourcePacing acts on each cockpit client event as lib/cockpitWiring.js cockpitEventEffect says (ruling D20):
//   a read's sources are drawn at once; a Changed's or a pull's wait for the surface's next Sample (onSample), one tick
//   and one frame, or, with the sampler silent, for a one-shot timeout of COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS, armed
//   once however many events wait and removed by each Sample. A Sample then pulls on suspicion the sources its cards
//   draw while the cockpit's subscription is wanted (ruling R14). reset() forgets what waits and removes the timeout
//   (the dropdown closing); destroy() does the same for good, and nothing is drawn, armed or pulled after it.
// - drawCockpitDataCard draws a data card (connections or sessions) from the cockpit client: "no data since HH:MM" (the
//   oldest stamp of its sources, local time) while the service is gone or one of its sources is stale, else its
//   sources, through the card's own update (ruling D9). A frozen card only records it (cockpitCards.js).
//
// It runs inside gnome-shell: the timeout's callback never throws out (a failure is logged, rate-limited by the
// surface), and nothing it arms outlives reset() or destroy().
import GLib from 'gi://GLib';

import {
    COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS, COCKPIT_CLOCK_LABEL_FORMAT, COCKPIT_SOURCE_NAMES_BY_CARD_ID,
    MICROSECONDS_PER_SECOND,
} from './lib/constants.js';
import {noDataText} from './lib/cockpitFormat.js';
import {
    CockpitApplyTiming, cockpitCardIdsDrawing, cockpitDataCardDrawing, cockpitEventEffect, cockpitSourceNamesToPull,
} from './lib/cockpitWiring.js';
import {describeErrorWithStack} from './lib/errorLog.js';

const FALLBACK_TIMEOUT_NAME = '[resource-pulse] draw the pending cockpit sources';
/** What "no data since" names for a stamp GLib cannot place as a local time (out of GLib.DateTime's range). */
const UNPLACEABLE_CLOCK_LABEL = '';

/** GLib's one-shot timeouts at the default priority, each named at its use: the pacing's fallback. */
const GLIB_TIMEOUTS = Object.freeze({
    addSeconds: (intervalSeconds, timeoutName, callback) => {
        const sourceId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, intervalSeconds, callback);
        GLib.Source.set_name_by_id(sourceId, timeoutName);
        return sourceId;
    },
    remove: sourceId => GLib.source_remove(sourceId),
});

/** Gives each card that draws cockpit sources its sources, through its update (ruling D9). */
const DATA_CARD_UPDATERS_BY_ID = Object.freeze({
    connections: (card, sourcesByName) => card.update(sourcesByName.network, sourcesByName.mounts),
    sessions: (card, sourcesByName) => card.update(sourcesByName.sessions),
});

/**
 * Writes a wall-clock stamp as a local time of day, for "no data since HH:MM".
 *
 * @param {number} realUsec - Wall-clock microseconds (a source's sampledAtUsec).
 * @returns {string} 'HH:MM', or UNPLACEABLE_CLOCK_LABEL for a stamp GLib cannot place.
 */
export function formatClockLabel(realUsec) {
    const unixSeconds = Math.floor(realUsec / MICROSECONDS_PER_SECOND);
    const localTime = GLib.DateTime.new_from_unix_local(unixSeconds);
    return localTime?.format(COCKPIT_CLOCK_LABEL_FORMAT) ?? UNPLACEABLE_CLOCK_LABEL;
}

/**
 * Draws a data card from the cockpit client: "no data since" the oldest stamp of its sources while the service is gone
 * or one of them is stale (lib/cockpitWiring.js cockpitDataCardDrawing), else its sources.
 *
 * @param {object} drawing - The card and the client.
 * @param {string} drawing.cardId - The card's id: connections or sessions.
 * @param {import('./cockpitCards.js').CockpitCardBase} drawing.card - The card; a frozen one only records it.
 * @param {import('./cockpitClient.js').CockpitClient} drawing.cockpitClient - Its state, sources and their freshness.
 * @returns {void}
 */
export function drawCockpitDataCard({cardId, card, cockpitClient}) {
    const sourcesByName = cockpitClient.sourcesByName;
    const sources = COCKPIT_SOURCE_NAMES_BY_CARD_ID[cardId].map(sourceName => ({
        sampledAtUsec: sourcesByName[sourceName]?.sampledAtUsec ?? null,
        isStale: cockpitClient.sourceFreshness(sourceName).isStale,
    }));
    const drawing = cockpitDataCardDrawing({clientState: cockpitClient.state, sources});
    if (drawing.isNoData)
        card.showNoData(noDataText(drawing.noDataSinceUsec, formatClockLabel));
    else
        DATA_CARD_UPDATERS_BY_ID[cardId](card, sourcesByName);
}

/** One surface's pacing of what the cockpit client's events bring (ruling D20), shared by every surface (D22). */
export class CockpitSourcePacing {
    /**
     * @param {object} options - The surface's parts, and the timeouts (injectable, so the rows run on fakes).
     * @param {{pullIfSuspicious: (sourceName: string) => Promise}} options.cockpitClient - Asked to pull on suspicion.
     * @param {() => string[]} options.drawnCardIds - The ids of the cards the surface draws now.
     * @param {(cardId: string) => void} options.drawCard - Draws one of them from what the clients hold now.
     * @param {import('./lib/errorLog.js').RateLimitedLogger} options.errorLog - Where the fallback's failure goes.
     * @param {string} options.surfaceName - The surface, as the fallback's journal line names it ('the cockpit
     *     layer'); it keys the line's rate limit, so one surface's failure never silences another's.
     * @param {{addSeconds: (intervalSeconds: number, timeoutName: string, callback: () => boolean) => number,
     *     remove: (sourceId: number) => void}} [options.timeouts] - Adds a named one-shot timeout, and removes one.
     */
    constructor({cockpitClient, drawnCardIds, drawCard, errorLog, surfaceName, timeouts = GLIB_TIMEOUTS}) {
        this._cockpitClient = cockpitClient;
        this._drawnCardIds = drawnCardIds;
        this._drawCard = drawCard;
        this._errorLog = errorLog;
        this._fallbackFailureContext = `could not draw the pending cockpit sources of ${surfaceName}`;
        this._timeouts = timeouts;
        // The sources a Changed, a pull or a VANISHED brought, drawn on the next Sample or by the fallback.
        this._pendingSourceNames = new Set();
        this._fallbackSourceId = null;
        this._isDestroyed = false;
    }

    /**
     * Acts on a cockpit client event as lib/cockpitWiring.js cockpitEventEffect says (ruling D20): draws its sources at
     * once, or leaves them pending for the next Sample, arming the fallback when it says to. Nothing once destroyed.
     *
     * @param {object} event - The client's event.
     * @returns {void}
     */
    onCockpitEvent(event) {
        if (this._isDestroyed)
            return;
        const isFallbackArmed = this._fallbackSourceId !== null;
        const {timing, sourceNames} = cockpitEventEffect({event, isFallbackArmed});
        if (timing === CockpitApplyTiming.NEVER)
            return;
        if (timing === CockpitApplyTiming.NOW) {
            this._drawSources(sourceNames);
            return;
        }
        for (const sourceName of sourceNames)
            this._pendingSourceNames.add(sourceName);
        if (timing === CockpitApplyTiming.NEXT_TICK_WITH_FALLBACK)
            this._armFallback();
    }

    /**
     * One Sample of the pulse client (the surface's tick): draws the pending sources, then pulls on suspicion each
     * source a drawn card draws while the subscription is wanted (lib/cockpitWiring.js cockpitSourceNamesToPull,
     * ruling R14). Nothing once destroyed.
     *
     * @param {object} cockpit - What the surface knows of the cockpit.
     * @param {boolean} cockpit.isSubscriptionWanted - The cockpit's subscription is wanted (something of it is seen).
     * @returns {void}
     */
    onSample({isSubscriptionWanted}) {
        if (this._isDestroyed)
            return;
        this._drawPendingSources();
        const drawnCardIds = this._drawnCardIds();
        const sourceNamesToPull = cockpitSourceNamesToPull({drawnCardIds, isSubscriptionWanted});
        for (const sourceName of sourceNamesToPull)
            this._cockpitClient.pullIfSuspicious(sourceName);
    }

    /**
     * Forgets the pending sources and removes the fallback, if armed: the surface stops drawing them (the dropdown
     * closing), and its next draw reads what the client holds then.
     *
     * @returns {void}
     */
    reset() {
        this._pendingSourceNames.clear();
        this._removeFallback();
    }

    /**
     * Resets for good: no event or Sample draws, arms or pulls after it. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        this._isDestroyed = true;
        this.reset();
    }

    /**
     * Draws the drawn cards that draw some sources (lib/cockpitWiring.js cockpitCardIdsDrawing), from what the client
     * holds now; those sources are pending no longer.
     *
     * @param {string[]} sourceNames - The sources.
     * @returns {void}
     */
    _drawSources(sourceNames) {
        for (const sourceName of sourceNames)
            this._pendingSourceNames.delete(sourceName);
        const cardIds = cockpitCardIdsDrawing({drawnCardIds: this._drawnCardIds(), sourceNames});
        for (const cardId of cardIds)
            this._drawCard(cardId);
    }

    /**
     * Draws the pending sources, removing the fallback first: each Sample, and the fallback itself.
     *
     * @returns {void}
     */
    _drawPendingSources() {
        this._removeFallback();
        if (this._pendingSourceNames.size === 0)
            return;
        this._drawSources([...this._pendingSourceNames]);
    }

    /**
     * Arms the one-shot fallback that draws the pending sources when no Sample comes within
     * COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS (the sampler silent).
     *
     * @returns {void}
     */
    _armFallback() {
        this._fallbackSourceId = this._timeouts.addSeconds(COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS,
            FALLBACK_TIMEOUT_NAME, () => this._onFallbackTimeout());
    }

    /**
     * The fallback: forgets its id first (it ends here, so nothing removes it again), draws the pending sources, and
     * never throws out of the callback, which runs in the compositor's main loop: a failure is logged, rate-limited by
     * the surface's context (the template key), whatever its error text and stack.
     *
     * @returns {boolean} GLib.SOURCE_REMOVE: it runs once.
     */
    _onFallbackTimeout() {
        this._fallbackSourceId = null;
        try {
            this._drawPendingSources();
        } catch (error) {
            const errorText = describeErrorWithStack(error);
            this._errorLog.log(`${this._fallbackFailureContext}: ${errorText}`, this._fallbackFailureContext);
        }
        return GLib.SOURCE_REMOVE;
    }

    /**
     * Removes the fallback, if armed; the id is forgotten first.
     *
     * @returns {void}
     */
    _removeFallback() {
        if (this._fallbackSourceId === null)
            return;
        const sourceId = this._fallbackSourceId;
        this._fallbackSourceId = null;
        this._timeouts.remove(sourceId);
    }
}
