// The cockpit's layer: one actor in the layout manager's background group, above the wallpaper and below every window
// (ding's DESKTOP window included), holding the grid on the cockpit monitor: a caption per group of the layout and a
// card (cockpitCards.js) per card id this release draws, in the cells lib/cockpitGrid.js gives. Shell glue only: what
// is drawn where and when is decided in lib/ (cockpitGrid.js, cockpitWiring.js); this file reads the two clients,
// calls those rules and assigns.
//
// - It is built from the cockpit client's layout. setLayout() keeps the cards a new layout still names (re-placed,
//   never remade), destroys those it no longer names and makes the new ones; there is one caption per group. A card id
//   this release does not know leaves its cell empty; its caption still draws.
// - It holds the extension's v2 card (card.js PulseCard) from its construction to its destroy: in the system cell when
//   the layout names one (SystemCockpitCard adopts it, ruling D11), else out of every parent, drawn nowhere (ruling
//   D21). Its destroy gives the v2 card back unparented, for the extension to destroy or put back top right.
// - placeOnMonitor() lays the grid out on a monitor's work area (cockpitGridGeometry). The extension's cover check
//   reads each drawn card's rectangle (cardRects) and freezes each card on its own (setCardFrozen); setInteractive()
//   follows ding's DESKTOP window, as the extension reads it.
// - What the cards draw: the system card draws itself (the v2 card listens to the pulse client); the apps card the
//   pulse client's snapshots (a snapshot listener); the connections and sessions cards the cockpit client's sources,
//   paced by the CockpitSourcePacing the layer shares with the dropdown (cockpitSourceDrawing.js, ruling D22): a read's
//   at once; a Changed's or a pull's on the next Sample (onSampleTick, from the extension's tick) or, with the sampler
//   silent, by a one-shot timeout of COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS (ruling D20); each drawn by
//   drawCockpitDataCard, so the service gone, or a source stale, draws "no data since HH:MM". A card revealed is first
//   given what the clients hold now, so the reveal draws the latest at once; each Sample while the cockpit is seen
//   pulls its suspect sources (pullIfSuspicious, ruling R14).
// - It draws through no texture of its own (each card draws through its own) and paints nothing itself.
// - Each card's draw runs under its own guard (_guardCardDraw): a card that throws is logged, rate-limited, and holds
//   up neither the other cards nor the extension's cover check that called the layer (ruling D25, per card).
//
// destroy() removes everything the layer added outside itself, each step guarded: both client listeners and the
// pacing (its fallback timeout) first, so nothing runs against a half-destroyed card; then the cards (the system card
// giving the v2 card back), the captions, and last the tooltip, which a card hides as it goes.
import GObject from 'gi://GObject';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

import {AppsCockpitCard, ConnectionsCockpitCard, SessionsCockpitCard, SystemCockpitCard} from './cockpitCards.js';
import {CockpitSourcePacing, drawCockpitDataCard} from './cockpitSourceDrawing.js';
import {CockpitTooltip} from './cockpitTooltip.js';
import {COCKPIT_APPS_CARD_ID} from './lib/constants.js';
import {cockpitCaptionText} from './lib/cockpitFormat.js';
import {cockpitGridGeometry, drawnCockpitCardIds, drawnCockpitCells} from './lib/cockpitGrid.js';
import {describeErrorWithStack, runLoggingFailure} from './lib/errorLog.js';
import {runEveryStep} from './lib/teardown.js';

const LAYER_STYLE_CLASS = 'rp-cockpit-layer';
const CAPTION_STYLE_CLASS = 'rp-cockpit-caption';
/** The layer, as its pacing's journal line names it (cockpitSourceDrawing.js). */
const PACING_SURFACE_NAME = 'the cockpit layer';
/** The context of the journal line for a card whose draw threw: one template key for every card (lib/errorLog.js). */
const CARD_DRAW_FAILURE_CONTEXT = 'cockpit layer could not draw a card';

/** Makes each card this release draws (lib/constants.js COCKPIT_DRAWN_CARD_IDS), by its id. */
const CARD_MAKERS_BY_ID = Object.freeze({
    system: ({pulseCard, tooltip}) => new SystemCockpitCard({pulseCard, tooltip}),
    apps: ({tooltip}) => new AppsCockpitCard({tooltip}),
    connections: ({tooltip}) => new ConnectionsCockpitCard({tooltip}),
    sessions: ({tooltip, onSessionActivated}) => new SessionsCockpitCard({tooltip, onRowActivated: onSessionActivated}),
});

/**
 * Gives each card that draws the sampler's snapshot the pulse client's latest, through its update (ruling D9), with the
 * client's last good clock label, so either card with no data says since when.
 */
const SNAPSHOT_CARD_DRAWERS_BY_ID = Object.freeze({
    system: (card, pulseClient) => card.update(pulseClient.latestSnapshot, pulseClient.lastGoodClockLabel),
    apps: (card, pulseClient) => card.update(pulseClient.latestSnapshot?.apps ?? null, pulseClient.lastGoodClockLabel),
});

/**
 * Places a group's caption at its rectangle of the grid, in the layer's coordinates (the stage's: the layer sits at
 * the background group's origin, which is the stage's). A card is placed by placeOnMonitor and sized by its own
 * setCellSize instead.
 *
 * @param {St.Label} actor - A group's caption.
 * @param {{x: number, y: number, width: number, height: number}} rect - Its rectangle, in logical pixels.
 * @returns {void}
 */
function placeActor(actor, {x, y, width, height}) {
    actor.set_position(x, y);
    actor.set_size(width, height);
}

export const CockpitLayer = GObject.registerClass(
class CockpitLayer extends St.Widget {
    /**
     * Builds the layer from the cockpit client's layout, takes the v2 card out of the background group, follows both
     * clients, and adds itself to the background group last. It lays nothing out until placeOnMonitor(). A failure
     * destroys whatever was built (giving the v2 card back) and rethrows.
     *
     * @param {object} options - The layer's parts.
     * @param {import('./cockpitClient.js').CockpitClient} options.cockpitClient - The cockpit client: the layout and
     *     the sources.
     * @param {import('./pulseClient.js').PulseClient} options.pulseClient - The pulse client: the apps card's
     *     snapshots, and the system card's latest for a reveal or a frozen repaint.
     * @param {import('./card.js').PulseCard} options.pulseCard - The extension's v2 card, which the system cell adopts;
     *     the extension owns and destroys it.
     * @param {import('./lib/errorLog.js').RateLimitedLogger} options.errorLog - Where the layer's own failures go.
     * @param {function(string): void} options.onSessionActivated - Called with a session's id when its row is clicked.
     * @returns {void}
     */
    _init({cockpitClient, pulseClient, pulseCard, errorLog, onSessionActivated}) {
        super._init({style_class: LAYER_STYLE_CLASS, reactive: false});
        // Every field _onDestroy reads is set before anything below can throw.
        this._cockpitClient = cockpitClient;
        this._pulseClient = pulseClient;
        this._pulseCard = pulseCard;
        this._errorLog = errorLog;
        this._onSessionActivated = onSessionActivated;
        this._tooltip = null;
        /** @type {Map<string, import('./cockpitCards.js').CockpitCardBase>} The cards drawn, by card id. */
        this._cardsById = new Map();
        /** @type {St.Label[]} One caption per group of the layout, in order. */
        this._captionLabels = [];
        this._layout = null;
        this._monitorIndex = null;
        // The cells of the last placement that hold a card (drawnCockpitCells); none until placeOnMonitor().
        this._drawnCells = [];
        this._frozenCardIds = new Set();
        this._isInteractive = false;
        // What the data cards are given and when (ruling D22): its constructor only assigns, so it cannot throw.
        this._pacing = new CockpitSourcePacing({
            cockpitClient, drawnCardIds: () => this.drawnCardIds, drawCard: cardId => this._drawCard(cardId),
            errorLog, surfaceName: PACING_SURFACE_NAME,
        });
        this._cockpitListenerId = null;
        this._snapshotListenerId = null;
        this.connect('destroy', () => this._onDestroy());
        try {
            this._tooltip = new CockpitTooltip();
            pulseCard.get_parent()?.remove_child(pulseCard);
            this.setLayout(cockpitClient.layout);
            this._cockpitListenerId = cockpitClient.addListener(event => this._pacing.onCockpitEvent(event));
            this._snapshotListenerId = pulseClient.addListener(snapshot => this._onSnapshot(snapshot));
            Main.layoutManager._backgroundGroup.add_child(this);
        } catch (error) {
            this.destroy();
            throw error;
        }
    }

    /** @returns {object} The layout the grid is drawn from (lib/cockpitProtocol.js parseLayout's shape). */
    get layout() {
        return this._layout;
    }

    /** @returns {number|null} The monitor of the last placement, or null before the first. */
    get monitorIndex() {
        return this._monitorIndex;
    }

    /** @returns {string[]} The ids of the cards the layer draws. */
    get drawnCardIds() {
        return [...this._cardsById.keys()];
    }

    /**
     * Takes a layout: keeps the cards it still names, destroys the others and makes the missing ones, keeps one caption
     * per group with the group's caption, and draws every card from what the clients hold. The grid is laid out again
     * by the next placeOnMonitor(), which the extension calls next.
     *
     * @param {object} layout - The layout (lib/cockpitProtocol.js parseLayout's shape).
     * @returns {void}
     */
    setLayout(layout) {
        this._layout = layout;
        this._drawnCells = [];
        this._syncCards(drawnCockpitCardIds(layout.groups));
        this._syncCaptions(layout.groups);
        for (const cardId of this._cardsById.keys())
            this._drawCard(cardId);
    }

    /**
     * Lays the grid out on a monitor's work area (lib/cockpitGrid.js cockpitGridGeometry): each caption at its
     * rectangle, each card in the first cell of its id (drawnCockpitCells), sized to the cell. A cell of an id this
     * release does not know stays empty.
     *
     * @param {number} monitorIndex - The cockpit monitor.
     * @param {{x: number, y: number, width: number, height: number}} workArea - Its work area, in stage pixels.
     * @returns {void}
     */
    placeOnMonitor(monitorIndex, workArea) {
        this._monitorIndex = monitorIndex;
        const {captions, cells} = cockpitGridGeometry({workArea, groups: this._layout.groups});
        captions.forEach((caption, captionIndex) => placeActor(this._captionLabels[captionIndex], caption));
        this._drawnCells = drawnCockpitCells(cells);
        for (const cell of this._drawnCells) {
            const card = this._cardsById.get(cell.cardId);
            card.set_position(cell.x, cell.y);
            card.setCellSize(cell.width, cell.height);
        }
    }

    /**
     * Each drawn card's rectangle, for the extension's cover check: the cell of the last placement, in stage pixels
     * (where the card is placed, whatever its last allocation).
     *
     * @returns {Array<{cardId: string, rect: {x: number, y: number, width: number, height: number}}>} One per drawn
     *     card; none before the first placement.
     */
    cardRects() {
        return this._drawnCells.map(({cardId, x, y, width, height}) => ({cardId, rect: {x, y, width, height}}));
    }

    /**
     * Lets every card take the pointer, or not (ding's DESKTOP window over the cockpit monitor takes it). Only a change
     * reaches the cards.
     *
     * @param {boolean} isInteractive - True while no DESKTOP window shows on the cockpit monitor.
     * @returns {void}
     */
    setInteractive(isInteractive) {
        if (isInteractive === this._isInteractive)
            return;
        this._isInteractive = isInteractive;
        for (const card of this._cardsById.values())
            card.setInteractive(isInteractive);
    }

    /**
     * Freezes one card while a window covers it, or unfreezes it on its reveal, which first draws it from what the
     * clients hold now (still frozen, so only recorded), so the reveal draws the latest at once rather than what it
     * knew when it was covered (ruling D20). A card the layer does not draw is ignored. The frozen state is recorded
     * first and each draw is guarded (_guardCardDraw), so this never throws for a card's draw.
     *
     * @param {string} cardId - The card's id.
     * @param {boolean} isFrozen - True while covered.
     * @returns {void}
     */
    setCardFrozen(cardId, isFrozen) {
        const card = this._cardsById.get(cardId);
        if (card === undefined)
            return;
        const isRevealed = !isFrozen && this._frozenCardIds.has(cardId);
        if (isFrozen)
            this._frozenCardIds.add(cardId);
        else
            this._frozenCardIds.delete(cardId);
        if (isRevealed)
            this._drawCard(cardId);
        this._guardCardDraw(() => card.setFrozen(isFrozen));
    }

    /**
     * A frozen card's dimmed repaint (ruling D18): draws it from what the clients hold now, then repaints it, still
     * dimmed, each draw guarded (_guardCardDraw). The extension decides when (lib/cockpitWiring.js
     * frozenCardsDueRepaint). A card the layer does not draw is ignored.
     *
     * @param {string} cardId - The card's id.
     * @returns {void}
     */
    repaintFrozenCard(cardId) {
        const card = this._cardsById.get(cardId);
        if (card === undefined)
            return;
        this._drawCard(cardId);
        this._guardCardDraw(() => card.repaintFrozen());
    }

    /**
     * One Sample of the pulse client (the extension's tick), handed to the pacing: it draws the sources a Changed or a
     * pull left pending, then pulls on suspicion each source a drawn card draws while the subscription is wanted
     * (ruling R14).
     *
     * @param {object} cockpit - What the extension knows of the cockpit.
     * @param {boolean} cockpit.isSubscriptionWanted - The cockpit's subscription is wanted (something of it is seen).
     * @returns {void}
     */
    onSampleTick({isSubscriptionWanted}) {
        this._pacing.onSample({isSubscriptionWanted});
    }

    /**
     * Destroys the cards a layout no longer names, keeps the others, and makes the missing ones.
     *
     * @param {string[]} cardIds - The card ids the layout's grid draws (lib/cockpitGrid.js drawnCockpitCardIds).
     * @returns {void}
     */
    _syncCards(cardIds) {
        for (const [cardId, card] of [...this._cardsById]) {
            if (cardIds.includes(cardId))
                continue;
            this._cardsById.delete(cardId);
            this._frozenCardIds.delete(cardId);
            card.destroy();
        }
        for (const cardId of cardIds) {
            if (!this._cardsById.has(cardId))
                this._addCard(cardId);
        }
    }

    /**
     * Makes one card, adds it to the layer, and gives it the layer's interactivity.
     *
     * @param {string} cardId - One of COCKPIT_DRAWN_CARD_IDS.
     * @returns {void}
     */
    _addCard(cardId) {
        const card = CARD_MAKERS_BY_ID[cardId]({
            pulseCard: this._pulseCard, tooltip: this._tooltip,
            onSessionActivated: sessionId => this._onSessionActivated(sessionId),
        });
        this._cardsById.set(cardId, card);
        this.add_child(card);
        card.setInteractive(this._isInteractive);
    }

    /**
     * Keeps one caption per group, each showing its group's caption upper-cased (lib/cockpitFormat.js
     * cockpitCaptionText; set only when it changed).
     *
     * @param {Array<{caption: string}>} groups - The layout's groups.
     * @returns {void}
     */
    _syncCaptions(groups) {
        while (this._captionLabels.length > groups.length)
            this._captionLabels.pop().destroy();
        while (this._captionLabels.length < groups.length) {
            const captionLabel = new St.Label({style_class: CAPTION_STYLE_CLASS});
            this.add_child(captionLabel);
            this._captionLabels.push(captionLabel);
        }
        groups.forEach((group, groupIndex) => {
            const captionLabel = this._captionLabels[groupIndex];
            const captionText = cockpitCaptionText(group.caption);
            if (captionLabel.text !== captionText)
                captionLabel.text = captionText;
        });
    }

    /**
     * Draws one card from what the clients hold now, guarded (_guardCardDraw): a card of the sampler's snapshot from
     * the pulse client's latest, a data card from the cockpit client's sources (cockpitSourceDrawing.js
     * drawCockpitDataCard). A frozen card only records it.
     *
     * @param {string} cardId - A drawn card's id.
     * @returns {void}
     */
    _drawCard(cardId) {
        const card = this._cardsById.get(cardId);
        const drawSnapshotCard = SNAPSHOT_CARD_DRAWERS_BY_ID[cardId];
        if (drawSnapshotCard)
            this._guardCardDraw(() => drawSnapshotCard(card, this._pulseClient));
        else
            this._guardCardDraw(() => drawCockpitDataCard({cardId, card, cockpitClient: this._cockpitClient}));
    }

    /**
     * Gives the apps card a pulse snapshot's apps and the client's last good clock label, guarded (_guardCardDraw;
     * the client tells snapshot listeners only while the detail watch is wanted, and the latest once when it becomes
     * wanted).
     *
     * @param {import('./pulseClient.js').Snapshot|null} snapshot - The latest snapshot.
     * @returns {void}
     */
    _onSnapshot(snapshot) {
        const appsCard = this._cardsById.get(COCKPIT_APPS_CARD_ID);
        this._guardCardDraw(() => appsCard?.update(snapshot?.apps ?? null, this._pulseClient.lastGoodClockLabel));
    }

    /**
     * Runs one card's draw under its own guard (lib/errorLog.js runLoggingFailure): a card whose draw, unfreeze or
     * frozen repaint throws holds up neither the other cards nor what called the layer, such as the extension's cover
     * check, which records what is visible, updates the watches and follows the covering windows after it (ruling D25,
     * per card). The failure is the layer's own, logged on its error log under one context for every card, so once per
     * interval however often it repeats.
     *
     * @param {function(): void} drawStep - The draw.
     * @returns {void}
     */
    _guardCardDraw(drawStep) {
        runLoggingFailure({run: drawStep, errorLog: this._errorLog, context: CARD_DRAW_FAILURE_CONTEXT});
    }

    /**
     * Removes the cockpit client listener, if added; the id is forgotten first.
     *
     * @returns {void}
     */
    _removeCockpitListener() {
        if (this._cockpitListenerId === null)
            return;
        const listenerId = this._cockpitListenerId;
        this._cockpitListenerId = null;
        this._cockpitClient.removeListener(listenerId);
    }

    /**
     * Removes the pulse client's snapshot listener, if added; the id is forgotten first.
     *
     * @returns {void}
     */
    _removeSnapshotListener() {
        if (this._snapshotListenerId === null)
            return;
        const listenerId = this._snapshotListenerId;
        this._snapshotListenerId = null;
        this._pulseClient.removeListener(listenerId);
    }

    /**
     * Destroys every card, each under its own guard (the system card gives the v2 card back as it goes); the records
     * are emptied first.
     *
     * @returns {void}
     */
    _destroyCards() {
        const cards = [...this._cardsById.values()];
        this._cardsById.clear();
        this._frozenCardIds.clear();
        this._drawnCells = [];
        runEveryStep(cards.map(card => ({name: 'destroy a card', run: () => card.destroy()})),
            (stepName, error) => this._logFailure(`cockpit layer teardown could not ${stepName}`, error));
    }

    /**
     * Destroys every caption.
     *
     * @returns {void}
     */
    _destroyCaptions() {
        const captionLabels = this._captionLabels;
        this._captionLabels = [];
        for (const captionLabel of captionLabels)
            captionLabel.destroy();
    }

    /**
     * Logs a failure of the layer's own, rate-limited by its context (the template key), so one failure repeating with
     * another error text or stack is still written once per interval.
     *
     * @param {string} context - What failed, without the error.
     * @param {*} error - What it threw.
     * @returns {void}
     */
    _logFailure(context, error) {
        const errorText = describeErrorWithStack(error);
        this._errorLog.log(`${context}: ${errorText}`, context);
    }

    /**
     * Removes everything the layer added outside itself, each step guarded (lib/teardown.js runEveryStep): both client
     * listeners and the pacing (its pending sources and its fallback timeout) first, then the cards, the captions and
     * last the tooltip. Runs on 'destroy', before Clutter destroys the children, however the layer is destroyed.
     *
     * @returns {void}
     */
    _onDestroy() {
        runEveryStep([
            {name: 'remove the cockpit client listener', run: () => this._removeCockpitListener()},
            {name: 'remove the snapshot listener', run: () => this._removeSnapshotListener()},
            {name: 'destroy the pacing', run: () => this._pacing.destroy()},
            {name: 'destroy the cards', run: () => this._destroyCards()},
            {name: 'destroy the captions', run: () => this._destroyCaptions()},
            {name: 'destroy the tooltip', run: () => this._tooltip?.destroy()},
        ], (stepName, error) => this._logFailure(`cockpit layer teardown could not ${stepName}`, error));
    }
});
