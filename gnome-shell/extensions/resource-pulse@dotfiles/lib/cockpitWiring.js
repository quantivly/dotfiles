// The pure decisions behind the cockpit's wiring (extension.js and cockpitLayer.js): whether the cockpit's layer is
// drawn (ruling D19) and which layout is kept across enables, where the v2 card goes (ruling D21), which surfaces a
// cover leaves seen, what a cockpit client event changes and when (ruling D20), what a data card draws, which sources a
// tick pulls on suspicion, and which frozen cards a tick repaints (ruling D18). The glue reads the shell and the
// clients into the plain inputs below, calls these, and assigns. Pure: no Gio, GLib, Shell, St, Clutter or Meta
// import, so it runs under plain gjs.
import {
    COCKPIT_SNAPSHOT_CARD_IDS, COCKPIT_SOURCE_NAMES_BY_CARD_ID, COCKPIT_SYSTEM_CARD_ID, CockpitClientEventType,
    CockpitClientState, CockpitSourcesCause,
} from './constants.js';
import {COCKPIT_SOURCE_NAMES} from './cockpitProtocol.js';
import {isFrozenRepaintDue} from './visibility.js';

/** What a cockpit client event does to the layer (cockpitLayerChange). */
export const CockpitLayerChange = Object.freeze({ADD: 'add', REMOVE: 'remove', REBUILD: 'rebuild', NONE: 'none'});

/**
 * When the cards are given what a cockpit client event brought (cockpitEventEffect):
 * - NOW: drawn at once;
 * - NEXT_TICK: on the next Sample, the fallback timeout already armed;
 * - NEXT_TICK_WITH_FALLBACK: on the next Sample, arming the one-shot fallback for a silent sampler;
 * - NEVER: the event changes nothing a card draws.
 */
export const CockpitApplyTiming = Object.freeze({
    NOW: 'now', NEXT_TICK: 'next-tick', NEXT_TICK_WITH_FALLBACK: 'next-tick-with-fallback', NEVER: 'never',
});

/** What an event that changes nothing a card draws touches. */
const NO_EFFECT = Object.freeze({timing: CockpitApplyTiming.NEVER, sourceNames: Object.freeze([])});

/**
 * The cockpit sources a card draws.
 *
 * @param {string} cardId - A card id; one the cockpit does not draw has none.
 * @returns {readonly string[]} Its sources, from COCKPIT_SOURCE_NAMES_BY_CARD_ID.
 */
function sourceNamesDrawnBy(cardId) {
    return COCKPIT_SOURCE_NAMES_BY_CARD_ID[cardId] ?? [];
}

/**
 * Says whether the cockpit's layer is drawn (ruling D19): while a layout is known (the one cached from the last enable,
 * or one the service sent; the service gone keeps it, so the grid stays) and the cockpit is not SKIPPED (not
 * configured). Otherwise the v2 card is drawn top right on the primary monitor, as without a cockpit.
 *
 * @param {object} cockpit - What the cockpit client knows.
 * @param {string} cockpit.clientState - Its CockpitClientState.
 * @param {object|null} cockpit.layout - Its layout (lib/cockpitProtocol.js parseLayout's shape), or null.
 * @returns {boolean} True while the layer is drawn.
 */
export function isCockpitLayerWanted({clientState, layout}) {
    return layout !== null && clientState !== CockpitClientState.SKIPPED;
}

/**
 * The layout the extension keeps across enables (as it keeps the last good clock label): the one the layer is drawn
 * from, so the next enable rebuilds the grid at once; none once the cockpit is SKIPPED, so a user who removed the
 * cockpit's config does not see the grid for a moment after each unlock.
 *
 * @param {object} cockpit - What the cockpit client knows.
 * @param {string} cockpit.clientState - Its CockpitClientState.
 * @param {object|null} cockpit.layout - Its layout, or null.
 * @returns {object|null} The layout to seed the next client with, or null.
 */
export function cockpitLayoutToKeep({clientState, layout}) {
    return isCockpitLayerWanted({clientState, layout}) ? layout : null;
}

/**
 * What a cockpit client event does to the layer: adds it once it is wanted, removes it once it is not, rebuilds a
 * shown layer's grid on a layout event (its cards kept, re-placed), and otherwise nothing.
 *
 * @param {object} situation - The layer and the client.
 * @param {boolean} situation.isLayerShown - The layer exists now.
 * @param {string} situation.clientState - The client's CockpitClientState.
 * @param {object|null} situation.layout - The client's layout, or null.
 * @param {boolean} situation.isLayoutEvent - The event is a layout event.
 * @returns {string} One of CockpitLayerChange's values.
 */
export function cockpitLayerChange({isLayerShown, clientState, layout, isLayoutEvent}) {
    const isLayerWanted = isCockpitLayerWanted({clientState, layout});
    if (isLayerWanted && !isLayerShown)
        return CockpitLayerChange.ADD;
    if (!isLayerWanted && isLayerShown)
        return CockpitLayerChange.REMOVE;
    if (isLayerWanted && isLayoutEvent)
        return CockpitLayerChange.REBUILD;
    return CockpitLayerChange.NONE;
}

/**
 * Says whether the v2 card is held hidden (ruling D21): the layer is shown and its layout names no system card, so the
 * card is drawn nowhere (the layer holds it out of the background group), is kept frozen, and no cover check counts
 * it. In the system cell, or top right with no layer, it is not.
 *
 * @param {object} layer - The layer.
 * @param {boolean} layer.isCockpitLayerShown - The layer exists now.
 * @param {string[]} layer.drawnCardIds - The card ids it draws.
 * @returns {boolean} True while the v2 card is held hidden.
 */
export function isPulseCardHeldHidden({isCockpitLayerShown, drawnCardIds}) {
    return isCockpitLayerShown && !drawnCardIds.includes(COCKPIT_SYSTEM_CARD_ID);
}

/**
 * Which surfaces the cover leaves seen: a cockpit card (the layer shown, a card of it visible), which the cockpit's
 * watch and subscription follow; and a card that draws the sampler's snapshot (the system or apps cell, or with no
 * layer the v2 card top right, checked under the system card's id), which the detail watch follows.
 *
 * @param {object} cover - The layer and the cover.
 * @param {boolean} cover.isCockpitLayerShown - The layer exists now.
 * @param {string[]} cover.visibleCardIds - The drawn cards the cover check found visible.
 * @returns {{isAnyCockpitCardVisible: boolean, isSnapshotCardVisible: boolean}} The two answers.
 */
export function cockpitSurfacesSeen({isCockpitLayerShown, visibleCardIds}) {
    return {
        isAnyCockpitCardVisible: isCockpitLayerShown && visibleCardIds.length > 0,
        isSnapshotCardVisible: visibleCardIds.some(cardId => COCKPIT_SNAPSHOT_CARD_IDS.includes(cardId)),
    };
}

/**
 * When the cards wait for something drawn later: on the next Sample, arming the fallback timeout unless it is armed.
 *
 * @param {boolean} isFallbackArmed - The fallback timeout is armed.
 * @returns {string} CockpitApplyTiming.NEXT_TICK or NEXT_TICK_WITH_FALLBACK.
 */
function nextTickTiming(isFallbackArmed) {
    return isFallbackArmed ? CockpitApplyTiming.NEXT_TICK : CockpitApplyTiming.NEXT_TICK_WITH_FALLBACK;
}

/**
 * What a cockpit client event changes in what the cards draw, and when (ruling D20):
 * - a sources event's sources: drawn at once when a read the client asked for of itself brought them (the read a reveal
 *   or an owner's appearance makes: a revealed card must not show what it knew when it was covered); on the next
 *   Sample when a Changed or a pull brought them (one tick, one frame), with the fallback for a silent sampler;
 * - a state event touches every source: VANISHED (every card then says "no data since") on the next Sample, LIVE (a
 *   service back, whose read follows) at once, STARTING and SKIPPED nothing (SKIPPED removes the layer);
 * - a layout event draws nothing here: the layer is rebuilt from it and draws every card.
 *
 * @param {object} situation - The event and the fallback.
 * @param {object} situation.event - The event: {type, names, cause}, {type, state} or {type, layout, configError}.
 * @param {boolean} situation.isFallbackArmed - The fallback timeout is armed.
 * @returns {{timing: string, sourceNames: string[]}} A CockpitApplyTiming and the sources it touches.
 */
export function cockpitEventEffect({event, isFallbackArmed}) {
    if (event.type === CockpitClientEventType.SOURCES) {
        const isRead = event.cause === CockpitSourcesCause.READ;
        const timing = isRead ? CockpitApplyTiming.NOW : nextTickTiming(isFallbackArmed);
        return {timing, sourceNames: event.names};
    }
    if (event.type !== CockpitClientEventType.STATE)
        return NO_EFFECT;
    if (event.state === CockpitClientState.VANISHED)
        return {timing: nextTickTiming(isFallbackArmed), sourceNames: COCKPIT_SOURCE_NAMES};
    if (event.state === CockpitClientState.LIVE)
        return {timing: CockpitApplyTiming.NOW, sourceNames: COCKPIT_SOURCE_NAMES};
    return NO_EFFECT;
}

/**
 * The drawn cards that draw any of some sources, in drawn order: the cards a sources event redraws.
 *
 * @param {object} selection - The cards and the sources.
 * @param {string[]} selection.drawnCardIds - The card ids the layer draws.
 * @param {string[]} selection.sourceNames - The sources.
 * @returns {string[]} The card ids.
 */
export function cockpitCardIdsDrawing({drawnCardIds, sourceNames}) {
    return drawnCardIds.filter(cardId =>
        sourceNamesDrawnBy(cardId).some(sourceName => sourceNames.includes(sourceName)));
}

/**
 * What a data card draws: "no data since" the oldest stamp of its sources while the service is gone (Review Focus 5:
 * the grid stays, every data card says when it last had data) or while any of its sources is stale (ruling R14);
 * with no stamp for one of them, a plain "no data". Otherwise it draws its sources.
 *
 * @param {object} reading - The client and the card's sources.
 * @param {string} reading.clientState - The client's CockpitClientState.
 * @param {Array<{sampledAtUsec: number|null, isStale: boolean}>} reading.sources - Each source the card draws: its
 *     stamp, and whether the client judges it stale (sourceFreshness).
 * @returns {{isNoData: boolean, noDataSinceUsec: number|null}} Whether it draws no data, and since which wall-clock
 *     stamp (null for a plain "no data", and when it draws its sources).
 */
export function cockpitDataCardDrawing({clientState, sources}) {
    const isNoData = clientState === CockpitClientState.VANISHED || sources.some(source => source.isStale);
    if (!isNoData)
        return {isNoData: false, noDataSinceUsec: null};
    const stamps = sources.map(source => source.sampledAtUsec);
    const noDataSinceUsec = stamps.includes(null) || stamps.length === 0 ? null : Math.min(...stamps);
    return {isNoData: true, noDataSinceUsec};
}

/**
 * The sources a Sample pulls on suspicion (pullIfSuspicious): every cockpit source a drawn card draws, in
 * COCKPIT_SOURCE_NAMES's order, while the subscription is wanted (a card of the cockpit, or the dropdown, is seen);
 * none otherwise, since the reveal's GetState is itself the fresh read.
 *
 * @param {object} situation - The cards and the subscription.
 * @param {string[]} situation.drawnCardIds - The card ids the layer draws.
 * @param {boolean} situation.isSubscriptionWanted - The cockpit subscription is wanted.
 * @returns {string[]} The source names to ask pullIfSuspicious about.
 */
export function cockpitSourceNamesToPull({drawnCardIds, isSubscriptionWanted}) {
    if (!isSubscriptionWanted)
        return [];
    const drawnSourceNames = new Set(drawnCardIds.flatMap(cardId => sourceNamesDrawnBy(cardId)));
    return COCKPIT_SOURCE_NAMES.filter(sourceName => drawnSourceNames.has(sourceName));
}

/**
 * The frozen cards whose dimmed repaint is due (ruling D18): FROZEN_REPAINT_INTERVAL_SECONDS after each one's last
 * paint (lib/visibility.js isFrozenRepaintDue). A card that draws the sampler's snapshot is repainted from the pulse
 * client's latest; a card that draws cockpit sources only while the cockpit subscription is held, since with none held
 * nothing it draws changed since the freeze.
 *
 * @param {object} situation - The frozen cards, the clock and the subscription.
 * @param {Object<string, number>} situation.frozenPaintedAtUsecByCardId - Each frozen card's last paint, monotonic µs.
 * @param {number} situation.nowUsec - Now, monotonic µs.
 * @param {boolean} situation.isCockpitSubscriptionWanted - The cockpit subscription is wanted.
 * @returns {string[]} The ids of the cards to repaint, in the object's order.
 */
export function frozenCardsDueRepaint({frozenPaintedAtUsecByCardId, nowUsec, isCockpitSubscriptionWanted}) {
    return Object.entries(frozenPaintedAtUsecByCardId)
        .filter(([cardId, lastFrozenPaintAtUsec]) => {
            const isRepaintable = isCockpitSubscriptionWanted || sourceNamesDrawnBy(cardId).length === 0;
            return isRepaintable && isFrozenRepaintDue({lastFrozenPaintAtUsec, nowUsec});
        })
        .map(([cardId]) => cardId);
}
