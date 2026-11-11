// The top-bar indicator: two mini area graphs, CPU then memory, with no text. The numbers appear in a label
// below it once the pointer has rested on it for HOVER_LABEL_DELAY_MS (never while the menu is open). A click opens a
// dropdown: a second card (card.js), unfrozen exactly while the menu is open; under it, once the cockpit has answered
// (ruling D23), a second copy of the cockpit's sessions card (cockpitCards.js), live exactly while the menu is open,
// whose row click closes the menu and takes the user to the session; and an "Open Resources" item (cockpitCards.js
// finds and opens the app, as the cockpit's system card does).
//
// The sessions card is paced as the cockpit layer's own copy is, by the one CockpitSourcePacing and data-card drawing
// they share (cockpitSourceDrawing.js, ruling D22): opening the menu draws it at once from what the cockpit client
// holds; while it is open a read is drawn at once and a Changed on the next Sample (this indicator's history listener);
// closed, it is frozen and nothing waits. The cockpit's part never takes the indicator down (ruling D25): it is built
// under a guard (a failure leaves v2's dropdown), and its every draw, event and click logs a failure on the shared
// error log rather than throw it into a menu signal handler, a client's listener loop or a row's click handler.
//
// Shell glue only: every number comes from the client, every string from lib/format.js, every shape from graph.js
// and every column from lib/topbarColumns.js. A graph asks for a repaint only when its columns, in whole device
// pixels, differ from the ones it last drew, and only while the indicator is mapped: a repaint is neither cheap nor
// lazy, and on an idle machine nearly every one would redraw the same pixels. A graph skipped while unmapped draws
// once when it is mapped again. It runs inside gnome-shell, so destroying it removes everything it added outside
// itself (the hover label, which lives in the layout manager's chrome, its timeout, and its client listener), and
// nothing it schedules can outlive it. The menu is registered with the panel's menu manager by
// Main.panel.addToStatusArea and destroyed with the button, which destroys the dropdown card inside it.
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {PulseCard} from './card.js';
import {SessionsCockpitCard, findResourcesApp, openResourcesApp} from './cockpitCards.js';
import {CockpitSourcePacing, drawCockpitDataCard} from './cockpitSourceDrawing.js';
import {CockpitTooltip} from './cockpitTooltip.js';
import {drawAreaGraph, padWithLeadingGaps} from './graph.js';
import {
    BASELINE_RGBA, COCKPIT_SESSIONS_CARD_ID, CPU_GRAPH_RGBA, CockpitClientEventType, HOVER_LABEL_DELAY_MS,
    HOVER_LABEL_FADE_IN_MS, HOVER_LABEL_FADE_OUT_MS, MEMORY_GRAPH_RGBA, TOPBAR_GRAPH_HEIGHT_PX, TOPBAR_GRAPH_WIDTH_PX,
    TOPBAR_HISTORY_SAMPLES,
} from './lib/constants.js';
import {isDropdownSessionsItemShown} from './lib/cockpitWiring.js';
import {describeErrorWithStack} from './lib/errorLog.js';
import {hoverLabel} from './lib/format.js';
import {hoverLabelPosition} from './lib/layout.js';
import {runEveryStep} from './lib/teardown.js';
import {columnFractions, deviceLevelCount, isGraphRepaintNeeded, quantisedColumns} from './lib/topbarColumns.js';

const ACCESSIBLE_NAME = 'Resource Pulse';
/** PanelMenu.Button's menu alignment: 0.5 puts the dropdown's arrow under the middle of the graphs. */
const MENU_ALIGNMENT = 0.5;
const OPEN_RESOURCES_LABEL = 'Open Resources';
/** The dropdown's card item: the stylesheet gives it its padding. */
const CARD_ITEM_STYLE_CLASS = 'resource-pulse-menu-card-item';
/** The card item is display-only: it takes neither focus nor clicks. */
const CARD_ITEM_PROPERTIES = {reactive: false, can_focus: false, style_class: CARD_ITEM_STYLE_CLASS};
/** The dropdown's sessions item: the stylesheet gives it its padding. */
const SESSIONS_ITEM_STYLE_CLASS = 'rp-cockpit-menu-sessions-item';
/** The sessions item takes neither focus nor clicks itself: its card's rows take the pointer. */
const SESSIONS_ITEM_PROPERTIES = {reactive: false, can_focus: false, style_class: SESSIONS_ITEM_STYLE_CLASS};
/** The sessions item's place in the menu: right under the card item (the first), above "Open Resources". */
const SESSIONS_ITEM_MENU_POSITION = 1;
/** The one cockpit card the dropdown draws: its pacing's drawn card ids. */
const DROPDOWN_COCKPIT_CARD_IDS = Object.freeze([COCKPIT_SESSIONS_CARD_ID]);
/** The dropdown, as its pacing's journal line names it (cockpitSourceDrawing.js). */
const PACING_SURFACE_NAME = 'the dropdown';
/**
 * The open dropdown holds the cockpit's subscription (lib/cockpitInteraction.js isCockpitWatchWanted counts it), so a
 * Sample while it is open pulls the sessions card's suspect sources.
 */
const IS_COCKPIT_SUBSCRIPTION_WANTED_WHILE_OPEN = true;
const GRAPH_BOX_STYLE_CLASS = 'resource-pulse-graphs';
const HOVER_LABEL_STYLE_CLASS = 'resource-pulse-hover-label';
/** The stylesheet's gap between the indicator's bottom edge and the label's top, as the dash's labels use. */
const HOVER_LABEL_Y_OFFSET_PROPERTY = '-y-offset';
const HOVER_LABEL_TIMEOUT_NAME = '[resource-pulse] show the hover label';
const GRAPH_WIDTH_STYLE = `width: ${TOPBAR_GRAPH_WIDTH_PX}px;`;
const GRAPH_HEIGHT_STYLE = `height: ${TOPBAR_GRAPH_HEIGHT_PX}px;`;
// St scales CSS lengths by the theme's scale factor, so sizing the graphs in CSS keeps them right at any scale.
const GRAPH_SIZE_STYLE = `${GRAPH_WIDTH_STYLE} ${GRAPH_HEIGHT_STYLE}`;
const TRANSPARENT_OPACITY = 0;
const OPAQUE_OPACITY = 255;
/** Clutter's for_height of -1: the label's width for its own height, with no height constraint. */
const UNCONSTRAINED_HEIGHT = -1;
/** The stage's left edge, for the fallback when the indicator is on no monitor. */
const STAGE_LEFT_EDGE_PX = 0;

/**
 * The columns a graph last drew (a GraphColumns of lib/topbarColumns.js), with the height it drew them at.
 *
 * @typedef {object} DrawnColumns
 * @property {number[]} columns - One level per slot, or GAP_COLUMN for a gap.
 * @property {number} levelCount - deviceLevelCount() of heightPx and the resource scale they were drawn at.
 * @property {number} heightPx - The graph's height in logical pixels at that repaint. St reports a drawing area's
 *     size only inside its repaint handler (anywhere else it logs a CRITICAL and the size reads 0), and repaints by
 *     itself on any change of size, so this is the height the comparison quantises at between repaints.
 */

/**
 * One top-bar graph: its drawing area, what it draws, and the columns it last drew.
 *
 * @typedef {object} TopbarGraph
 * @property {St.DrawingArea} drawingArea - The graph's actor.
 * @property {import('./lib/history.js').RingBuffer} history - The fractions it draws.
 * @property {number[]} fillRgba - Its colour, as [red, green, blue, alpha], each 0–1.
 * @property {DrawnColumns|null} drawnColumns - What its repaint handler last drew; null until it first draws.
 */

export const PulseIndicator = GObject.registerClass(
class PulseIndicator extends PanelMenu.Button {
    /**
     * Builds the graphs, the dropdown and the hover label, and starts listening to the client and to the display
     * scale. The hover label is added to the chrome, and the outside signals connected, only after everything
     * that could throw, so a failed construction leaves nothing in the shell. The dropdown's sessions card is built
     * last, since it adds to the chrome too (its tooltip), under its own guard (ruling D25): it never throws, and its
     * failure leaves v2's dropdown.
     *
     * @param {import('./pulseClient.js').PulseClient} client - The one client; the indicator draws its histories.
     * @param {object} cockpit - The cockpit's part of the dropdown.
     * @param {import('./cockpitClient.js').CockpitClient} cockpit.cockpitClient - The cockpit client: the sessions
     *     card's source, its state and its events.
     * @param {import('./lib/errorLog.js').RateLimitedLogger} cockpit.errorLog - The extension's shared error log, where
     *     the cockpit part's failures go.
     * @param {function(string): void} cockpit.onSessionActivated - Called with a session's id when its row is clicked,
     *     once the menu is closed: the extension's activation path.
     * @returns {void}
     */
    _init(client, {cockpitClient, errorLog, onSessionActivated}) {
        super._init(MENU_ALIGNMENT, ACCESSIBLE_NAME);
        // Every field _onDestroy reads is set before anything below can throw.
        this._client = client;
        this._cockpitClient = cockpitClient;
        this._errorLog = errorLog;
        this._activateSession = onSessionActivated;
        this._hoverLabel = null;
        this._isHoverLabelShown = false;
        this._showHoverLabelTimeoutId = null;
        this._placeHoverLabelLaterId = null;
        this._historyListenerId = null;
        this._dropdownCard = null;
        // The dropdown's sessions card, its item, its own tooltip and its pacing, and its cockpit client listener;
        // all null while it is not built (or its build failed: ruling D25).
        this._sessionsItem = null;
        this._sessionsCard = null;
        this._sessionsTooltip = null;
        this._sessionsPacing = null;
        this._cockpitListenerId = null;
        this._openResourcesItem = null;

        const graphBox = new St.BoxLayout({style_class: GRAPH_BOX_STYLE_CLASS});
        this._cpuGraph = this._addGraph(graphBox, client.cpuHistory, CPU_GRAPH_RGBA);
        this._memoryGraph = this._addGraph(graphBox, client.memoryHistory, MEMORY_GRAPH_RGBA);
        this.add_child(graphBox);

        // PanelMenu.Button toggles the menu on a click. The card is frozen until the menu opens: a closed menu
        // draws nothing, and the first unfreeze repaints it at once from the client's latest state.
        this._buildDropdown();
        this._dropdownCard.setFrozen(true);
        // Disconnected first in _onDestroy: destroying an open menu closes it, which emits this again.
        this.menu.connectObject('open-state-changed', (_menu, isOpen) => this._onMenuOpenStateChanged(isOpen),
            this);

        this.connect('notify::hover', () => this._syncHoverLabel());
        // Hidden while hovered (say, a fullscreen window hides the panel): the label must not stay up above it.
        // Mapped again, a graph whose columns changed while it was hidden draws once.
        this.connect('notify::mapped', () => this._onMappedChanged());

        this._hoverLabel = new St.Label({style_class: HOVER_LABEL_STYLE_CLASS, visible: false});
        // The label's first width after it is shown can be stale: one hidden across a display-scale change
        // measures at the old scale until it is allocated again. Placing it again once its width settles (and
        // when the scale changes while it is up) keeps it centred. The label is destroyed with the indicator,
        // and its handlers with it.
        this._hoverLabel.connect('notify::width', () => this._queuePlaceShownHoverLabel());
        Main.layoutManager.addTopChrome(this._hoverLabel);
        this._historyListenerId = client.addHistoryListener(() => this._onHistoriesChanged());
        St.ThemeContext.get_for_stage(global.stage).connectObject(
            'notify::scale-factor', () => this._queuePlaceShownHoverLabel(), this);
        this._addSessionsItem();
    }

    /**
     * Fills the menu: a second card, in a non-reactive item (it is display-only, and takes neither focus nor
     * clicks), and the "Open Resources" item; the sessions item goes between them, added last (_addSessionsItem). The
     * card is not placed on a monitor: the menu lays it out.
     *
     * @returns {void}
     */
    _buildDropdown() {
        const cardItem = new PopupMenu.PopupBaseMenuItem(CARD_ITEM_PROPERTIES);
        this._dropdownCard = new PulseCard(this._client);
        cardItem.add_child(this._dropdownCard);
        this.menu.addMenuItem(cardItem);

        this._openResourcesItem = new PopupMenu.PopupMenuItem(OPEN_RESOURCES_LABEL);
        this._openResourcesItem.connect('activate', () => openResourcesApp());
        this.menu.addMenuItem(this._openResourcesItem);
        this._syncOpenResourcesVisibility();
    }

    /**
     * Adds the sessions item under the card item, under a guard (ruling D25: the cockpit never takes the indicator
     * down): on a failure it is logged, whatever was half-built is destroyed and the item is left out, so the dropdown
     * is v2's. It runs last in _init, after every step that can throw, as everything that adds to the shell does.
     *
     * @returns {void}
     */
    _addSessionsItem() {
        try {
            this._buildSessionsItem();
        } catch (error) {
            this._logCockpitFailure('be built, so the dropdown shows the system card alone', error);
            this._destroySessionsItem();
        }
    }

    /**
     * Builds the sessions item: a SessionsCockpitCard with its own tooltip, whose row click reaches
     * _onSessionActivated, in a non-reactive, unfocusable item, put in the menu right under the card item. The card
     * always takes the pointer (the open menu is above every window) and is frozen until the menu opens, as the system
     * card is; its own CockpitSourcePacing paces it (ruling D22). The item is shown or hidden by the client's state
     * (ruling D23); the client listener is added last.
     *
     * @returns {void}
     * @throws {Error} Whatever a step threw; _addSessionsItem destroys what was built.
     */
    _buildSessionsItem() {
        this._sessionsTooltip = new CockpitTooltip();
        this._sessionsCard = new SessionsCockpitCard({
            tooltip: this._sessionsTooltip, onRowActivated: sessionId => this._onSessionActivated(sessionId),
        });
        this._sessionsCard.setInteractive(true);
        this._sessionsCard.setFrozen(true);
        this._sessionsItem = new PopupMenu.PopupBaseMenuItem(SESSIONS_ITEM_PROPERTIES);
        this._sessionsItem.add_child(this._sessionsCard);
        this.menu.addMenuItem(this._sessionsItem, SESSIONS_ITEM_MENU_POSITION);
        this._sessionsPacing = new CockpitSourcePacing({
            cockpitClient: this._cockpitClient, drawnCardIds: () => DROPDOWN_COCKPIT_CARD_IDS,
            drawCard: () => this._drawSessionsCard(), errorLog: this._errorLog, surfaceName: PACING_SURFACE_NAME,
        });
        this._syncSessionsItemVisibility();
        this._cockpitListenerId = this._cockpitClient.addListener(event => this._onCockpitEvent(event));
    }

    /**
     * Shows the sessions item only once the cockpit has answered (lib/cockpitWiring.js isDropdownSessionsItemShown,
     * ruling D23).
     *
     * @returns {void}
     */
    _syncSessionsItemVisibility() {
        this._sessionsItem.visible = isDropdownSessionsItemShown(this._cockpitClient.state);
    }

    /**
     * A cockpit client event: a state event shows or hides the sessions item; while the menu is open, the pacing acts
     * on every event (a read drawn at once, a Changed or a pull on the next Sample); closed, nothing else. Never thrown
     * into the client's listener loop (ruling D25).
     *
     * @param {object} event - The client's event.
     * @returns {void}
     */
    _onCockpitEvent(event) {
        this._runCockpitStep('follow a cockpit event', () => {
            if (event.type === CockpitClientEventType.STATE)
                this._syncSessionsItemVisibility();
            if (this.menu.isOpen)
                this._sessionsPacing.onCockpitEvent(event);
        });
    }

    /**
     * Reacts to the menu opening or closing: the dropdown card is unfrozen (and repaints at once) while the menu
     * is open and frozen while it is closed, and so is the sessions card; "Open Resources" is shown only if an app is
     * installed (checked at every change, since apps come and go), and the hover label is hidden on open and may come
     * back on close.
     *
     * @param {boolean} isOpen - True once the menu is open, false once it is closed.
     * @returns {void}
     */
    _onMenuOpenStateChanged(isOpen) {
        this._dropdownCard.setFrozen(!isOpen);
        this._followMenuWithSessionsCard(isOpen);
        this._syncOpenResourcesVisibility();
        this._syncHoverLabel();
    }

    /**
     * The sessions card follows the menu: opening shows the latest at once (_showLatestSessions), closing freezes it
     * (_freezeSessionsCard). Nothing when it was not built; never thrown into the menu's signal handler (ruling D25).
     *
     * @param {boolean} isOpen - True once the menu is open, false once it is closed.
     * @returns {void}
     */
    _followMenuWithSessionsCard(isOpen) {
        if (this._sessionsCard === null)
            return;
        if (isOpen)
            this._runCockpitStep('be drawn as the menu opens', () => this._showLatestSessions());
        else
            this._runCockpitStep('be frozen as the menu closes', () => this._freezeSessionsCard());
    }

    /**
     * Draws the sessions card from what the cockpit client holds now, while it is still frozen (so it only records
     * it), then unfreezes it, which draws that record: the latest at once, drawn once, waiting for no event (the
     * layer's reveal, setCardFrozen, does the same). The read the open dropdown's subscription asks for is drawn when
     * it comes.
     *
     * @returns {void}
     */
    _showLatestSessions() {
        this._drawSessionsCard();
        this._sessionsCard.setFrozen(false);
    }

    /**
     * Forgets what the pacing holds (the pending sources and the fallback timeout), freezes the sessions card and hides
     * its tooltip: no leave-event reaches a row whose menu closed under the pointer, and a pending show would bring the
     * tooltip up over a closed menu.
     *
     * @returns {void}
     */
    _freezeSessionsCard() {
        this._sessionsPacing.reset();
        this._sessionsCard.setFrozen(true);
        this._sessionsTooltip.hide();
    }

    /**
     * Draws the sessions card from the cockpit client (cockpitSourceDrawing.js drawCockpitDataCard: its sessions, or
     * "no data since HH:MM" while the service is gone or the source is stale). A frozen card only records it.
     *
     * @returns {void}
     */
    _drawSessionsCard() {
        drawCockpitDataCard({
            cardId: COCKPIT_SESSIONS_CARD_ID, card: this._sessionsCard, cockpitClient: this._cockpitClient,
        });
    }

    /**
     * A session row of the dropdown's card was clicked: the menu closes first, whatever the activation then does
     * (Review Focus 3), then the extension's activation path takes the user to the session. Neither step throws into
     * the row's click handler (ruling D25): each failure is logged, and a failed close still activates.
     *
     * @param {string} sessionId - The clicked session's id.
     * @returns {void}
     */
    _onSessionActivated(sessionId) {
        this._runCockpitStep('close the menu for a session', () => this.menu.close());
        this._runCockpitStep('activate a session', () => this._activateSession(sessionId));
    }

    /**
     * Reacts to the indicator being mapped or unmapped: the hover label follows, and once the indicator is mapped
     * again each graph whose columns changed while it was not draws once, now (the repaint owed).
     *
     * @returns {void}
     */
    _onMappedChanged() {
        this._syncHoverLabel();
        this._queueRepaintsOfChangedGraphs();
    }

    /**
     * Adds one mini graph, which draws its history on every repaint.
     *
     * @param {St.BoxLayout} graphBox - Where the graph goes.
     * @param {import('./lib/history.js').RingBuffer} history - The fractions it draws.
     * @param {number[]} fillRgba - The graph's colour, as [red, green, blue, alpha], each 0–1.
     * @returns {TopbarGraph} The graph, which has drawn nothing yet.
     */
    _addGraph(graphBox, history, fillRgba) {
        const drawingArea = new St.DrawingArea({style: GRAPH_SIZE_STYLE, y_align: Clutter.ActorAlign.CENTER});
        const topbarGraph = {drawingArea, history, fillRgba, drawnColumns: null};
        drawingArea.connect('repaint', () => this._paintGraph(topbarGraph));
        graphBox.add_child(drawingArea);
        return topbarGraph;
    }

    /**
     * The columns a graph's history gives now: its newest TOPBAR_HISTORY_SAMPLES, right-aligned, quantised to whole
     * device pixels of the given height and resource scale.
     *
     * @param {TopbarGraph} topbarGraph - The graph.
     * @param {number} heightPx - Its height in logical pixels.
     * @param {number} resourceScale - Its resource scale.
     * @returns {import('./lib/topbarColumns.js').GraphColumns} The columns, with the level count they were quantised
     *     to.
     */
    _currentColumns(topbarGraph, heightPx, resourceScale) {
        const newestFractions = topbarGraph.history.lastValues(TOPBAR_HISTORY_SAMPLES);
        const slotFractions = padWithLeadingGaps(newestFractions, TOPBAR_HISTORY_SAMPLES);
        return {
            columns: quantisedColumns(slotFractions, heightPx, resourceScale),
            levelCount: deviceLevelCount(heightPx, resourceScale),
        };
    }

    /**
     * Draws a graph's current columns (columnFractions, so the levels drawn are the levels compared), records them as
     * the columns it last drew with the height it drew them at, and frees the context whatever happens (as the
     * shell's own drawing areas do). The repaint handler is the one place the graph's size and cairo context may be
     * read: St allows both only while it repaints. St emits repaint on its own too (at the first allocation, on a
     * style or a scale change), so the columns are always computed here, from the history at the size and scale
     * being drawn: it never draws stale levels, and the next comparison is against what is on screen.
     *
     * @param {TopbarGraph} topbarGraph - The graph being repainted.
     * @returns {void}
     */
    _paintGraph(topbarGraph) {
        const {drawingArea, fillRgba} = topbarGraph;
        const [widthPx, heightPx] = drawingArea.get_surface_size();
        const resourceScale = drawingArea.get_resource_scale();
        const columnsToDraw = this._currentColumns(topbarGraph, heightPx, resourceScale);
        const slotFractions = columnFractions(columnsToDraw.columns, heightPx, resourceScale);
        const cr = drawingArea.get_context();
        try {
            drawAreaGraph(cr, widthPx, heightPx, slotFractions, fillRgba, BASELINE_RGBA);
            topbarGraph.drawnColumns = {...columnsToDraw, heightPx};
        } finally {
            cr.$dispose();
        }
    }

    /**
     * Says whether a graph must draw again (lib/topbarColumns.js isGraphRepaintNeeded): only while the indicator is
     * mapped, and only when it has drawn nothing yet or the columns its history gives now differ from the ones it
     * last drew, or were quantised to another number of device pixels. The current columns are quantised at the
     * height recorded by the last repaint and the live resource scale: St reports a drawing area's size only inside
     * its repaint handler, and repaints by itself on any change of size, so the size is never read here. Unmapped it
     * computes nothing and answers false, and the columns last drawn stay as they are: the repaint is owed, and the
     * first comparison once the indicator is mapped again (notify::mapped) draws it. False once destroyed.
     *
     * @param {TopbarGraph} topbarGraph - The graph.
     * @returns {boolean} True when a repaint would change what the graph shows.
     */
    _isRepaintNeeded(topbarGraph) {
        if (this._client === null || !this.mapped)
            return false;
        const {drawingArea, drawnColumns} = topbarGraph;
        // Nothing drawn yet means no height to quantise at; isGraphRepaintNeeded answers true without one.
        const currentColumns = drawnColumns === null ? null
            : this._currentColumns(topbarGraph, drawnColumns.heightPx, drawingArea.get_resource_scale());
        return isGraphRepaintNeeded({drawnColumns, currentColumns});
    }

    /**
     * Asks each graph that must draw again for a repaint: the one place the indicator asks, since St.DrawingArea's
     * repaint is neither cheap nor lazy. Both graphs are asked in the same notification, so a tick costs one frame at
     * most, and none when no column changed or the indicator is unmapped.
     *
     * @returns {void}
     */
    _queueRepaintsOfChangedGraphs() {
        for (const topbarGraph of [this._cpuGraph, this._memoryGraph]) {
            if (this._isRepaintNeeded(topbarGraph))
                topbarGraph.drawingArea.queue_repaint();
        }
    }

    /**
     * Redraws the graphs whose columns changed once the client's histories have changed (a Sample, a state, or no
     * data), refreshes the hover label while it is up, from the latest snapshot, so it never shows an older sample
     * than the graphs do, and last gives the dropdown's sessions card its Sample (_onCockpitSample).
     *
     * @returns {void}
     */
    _onHistoriesChanged() {
        this._queueRepaintsOfChangedGraphs();
        if (this._isHoverLabelShown) {
            this._updateHoverLabelText();
            this._placeHoverLabel();
        }
        this._onCockpitSample();
    }

    /**
     * The dropdown's share of a Sample (this history listener is the dropdown's tick, as the extension's own is the
     * layer's), while the menu is open: the pacing draws what a Changed or a pull left pending, then pulls the
     * sessions card's suspect sources (with no layer, or a layout without a sessions card, nothing else pulls them;
     * the client refuses a second ask about the same source within its interval, so the layer's ask in the same Sample
     * makes no second GetState). Nothing while the menu is closed or the card was not built; never thrown into the
     * client's listener loop (ruling D25).
     *
     * @returns {void}
     */
    _onCockpitSample() {
        if (this._sessionsPacing === null || !this.menu.isOpen)
            return;
        this._runCockpitStep('take its Sample', () =>
            this._sessionsPacing.onSample({isSubscriptionWanted: IS_COCKPIT_SUBSCRIPTION_WANTED_WHILE_OPEN}));
    }

    /**
     * Shows the hover label after the delay while the pointer is on the indicator and the menu is closed, and hides
     * it at once when the pointer leaves, the indicator is hidden or the menu opens. A no-op once destroyed.
     *
     * @returns {void}
     */
    _syncHoverLabel() {
        if (this._hoverLabel === null)
            return;
        if (this.hover && this.mapped && !this.menu.isOpen) {
            this._scheduleHoverLabel();
        } else {
            this._cancelHoverLabelTimeout();
            this._hideHoverLabel();
        }
    }

    /**
     * Starts the delay before the hover label shows, unless it is already pending or shown.
     *
     * @returns {void}
     */
    _scheduleHoverLabel() {
        if (this._showHoverLabelTimeoutId !== null || this._isHoverLabelShown)
            return;
        this._showHoverLabelTimeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, HOVER_LABEL_DELAY_MS, () => {
            this._showHoverLabelTimeoutId = null;
            this._showHoverLabel();
            return GLib.SOURCE_REMOVE;
        });
        GLib.Source.set_name_by_id(this._showHoverLabelTimeoutId, HOVER_LABEL_TIMEOUT_NAME);
    }

    /**
     * Removes the pending show of the hover label, if any.
     *
     * @returns {void}
     */
    _cancelHoverLabelTimeout() {
        if (this._showHoverLabelTimeoutId === null)
            return;
        GLib.source_remove(this._showHoverLabelTimeoutId);
        this._showHoverLabelTimeoutId = null;
    }

    /**
     * Fades the hover label in below the indicator, with the latest numbers.
     *
     * @returns {void}
     */
    _showHoverLabel() {
        const label = this._hoverLabel;
        this._isHoverLabelShown = true;
        this._updateHoverLabelText();
        label.opacity = TRANSPARENT_OPACITY;
        label.show();
        this._placeHoverLabel();
        label.ease({
            opacity: OPAQUE_OPACITY,
            duration: HOVER_LABEL_FADE_IN_MS,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        });
    }

    /**
     * Fades the hover label out. A show that starts meanwhile replaces the fade, and the label then stays up.
     *
     * @returns {void}
     */
    _hideHoverLabel() {
        if (!this._isHoverLabelShown)
            return;
        this._isHoverLabelShown = false;
        const label = this._hoverLabel;
        label.ease({
            opacity: TRANSPARENT_OPACITY,
            duration: HOVER_LABEL_FADE_OUT_MS,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            // Runs only when the fade finishes, never when a show or a destroy stops it first.
            onComplete: () => label.hide(),
        });
    }

    /**
     * Sets the hover label's text from the client's latest snapshot; lib/format.js says "no data since HH:MM"
     * rather than show a stale number as live.
     *
     * @returns {void}
     */
    _updateHoverLabelText() {
        this._hoverLabel.text = hoverLabel(this._client.latestSnapshot, this._client.lastGoodClockLabel);
    }

    /**
     * Places the hover label again before the next frame, if it is up. notify::width comes during allocation, and
     * moving an actor then leaves it needing an allocation, which Clutter warns about; a BEFORE_REDRAW later moves
     * it before the next frame instead, as the shell's own layout.js does. Several calls before then queue one.
     *
     * @returns {void}
     */
    _queuePlaceShownHoverLabel() {
        if (this._placeHoverLabelLaterId !== null || !this._isHoverLabelShown)
            return;
        this._placeHoverLabelLaterId = global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
            this._placeHoverLabelLaterId = null;
            this._placeShownHoverLabel();
            return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * Places the hover label again if it is up; a no-op while it is hidden or once the indicator is destroyed.
     *
     * @returns {void}
     */
    _placeShownHoverLabel() {
        if (this._isHoverLabelShown && this._hoverLabel !== null)
            this._placeHoverLabel();
    }

    /**
     * Centres the hover label below the indicator, kept inside the indicator's monitor (lib/layout.js
     * hoverLabelPosition). Called only after the label's text is set, and it measures the label's natural width
     * for that text: get_width() can still answer with the allocation of the previous text, which put the label
     * off-centre by a pixel or two.
     *
     * @returns {void}
     */
    _placeHoverLabel() {
        const label = this._hoverLabel;
        const [indicatorX, indicatorY] = this.get_transformed_position();
        const indicatorRect = {
            x: indicatorX,
            y: indicatorY,
            width: this.allocation.get_width(),
            height: this.allocation.get_height(),
        };
        const [, labelNaturalWidthPx] = label.get_preferred_width(UNCONSTRAINED_HEIGHT);
        // findMonitorForActor answers null only for an actor on no monitor; the whole stage is the fallback then.
        const monitorRect = Main.layoutManager.findMonitorForActor(this) ??
            {x: STAGE_LEFT_EDGE_PX, width: global.stage.width};
        const gapPx = label.get_theme_node().get_length(HOVER_LABEL_Y_OFFSET_PROPERTY);
        const {x, y} = hoverLabelPosition(indicatorRect, labelNaturalWidthPx, gapPx, monitorRect);
        label.set_position(x, y);
    }

    /**
     * Shows "Open Resources" only while a system monitor is installed.
     *
     * @returns {void}
     */
    _syncOpenResourcesVisibility() {
        this._openResourcesItem.visible = findResourcesApp() !== undefined;
    }

    /**
     * Runs one step of the dropdown's cockpit part and logs its failure instead of throwing it (ruling D25: the
     * cockpit never takes the indicator down, and no menu signal handler, client listener loop or row click handler
     * is thrown into).
     *
     * @param {string} stepName - What the step does, as "could not ..." words it, for example 'take its Sample'.
     * @param {function(): void} step - The step.
     * @returns {void}
     */
    _runCockpitStep(stepName, step) {
        try {
            step();
        } catch (error) {
            this._logCockpitFailure(stepName, error);
        }
    }

    /**
     * Logs a failure of the dropdown's cockpit part on the shared error log, rate-limited by its context (the template
     * key), so one failure repeating with another error text or stack is still written once per interval.
     *
     * @param {string} stepName - What failed, as "could not ..." words it.
     * @param {*} error - What it threw.
     * @returns {void}
     */
    _logCockpitFailure(stepName, error) {
        const context = `the dropdown's sessions card could not ${stepName}`;
        const errorText = describeErrorWithStack(error);
        this._errorLog.log(`${context}: ${errorText}`, context);
    }

    /**
     * Removes the dropdown's cockpit part, each step guarded (lib/teardown.js runEveryStep), in an order that never
     * calls into a destroyed actor: the cockpit client listener first, so no event reaches what follows; the pacing
     * (its fallback timeout); the card (which hides the tooltip as it goes, and leaves the item); the item (which
     * leaves the menu); last the tooltip (its label leaves the chrome). The fields are cleared first. What was never
     * built is skipped, so it also undoes a build that failed half-way.
     *
     * @returns {void}
     */
    _destroySessionsItem() {
        const cockpitListenerId = this._cockpitListenerId;
        const sessionsPacing = this._sessionsPacing;
        const sessionsCard = this._sessionsCard;
        const sessionsItem = this._sessionsItem;
        const sessionsTooltip = this._sessionsTooltip;
        this._cockpitListenerId = null;
        this._sessionsPacing = null;
        this._sessionsCard = null;
        this._sessionsItem = null;
        this._sessionsTooltip = null;
        runEveryStep([
            {name: 'remove the cockpit listener', run: () => this._cockpitClient.removeListener(cockpitListenerId)},
            {name: 'destroy the pacing', run: () => sessionsPacing?.destroy()},
            {name: 'destroy the card', run: () => sessionsCard?.destroy()},
            {name: 'destroy the item', run: () => sessionsItem?.destroy()},
            {name: 'destroy the tooltip', run: () => sessionsTooltip?.destroy()},
        ], (stepName, error) => this._logCockpitFailure(stepName, error));
    }

    /**
     * Removes everything the indicator added outside itself: the display-scale handler, the hover label's pending
     * placement and pending show, its client listener, the dropdown's cockpit part (_destroySessionsItem: its cockpit
     * client listener, its pacing, its card and its tooltip), the dropdown card (its own listener goes with it) and
     * the hover label itself (destroying it also takes it out of the chrome, with its own handlers). Runs on the
     * 'destroy' signal, which PanelMenu.Button connects, so it runs however the indicator is destroyed.
     *
     * @returns {void}
     */
    _onDestroy() {
        this.menu.disconnectObject(this);
        St.ThemeContext.get_for_stage(global.stage).disconnectObject(this);
        if (this._placeHoverLabelLaterId !== null) {
            global.compositor.get_laters().remove(this._placeHoverLabelLaterId);
            this._placeHoverLabelLaterId = null;
        }
        this._cancelHoverLabelTimeout();
        if (this._historyListenerId !== null) {
            this._client.removeHistoryListener(this._historyListenerId);
            this._historyListenerId = null;
        }
        this._destroySessionsItem();
        this._dropdownCard?.destroy();
        this._dropdownCard = null;
        this._openResourcesItem = null;
        this._hoverLabel?.destroy();
        this._hoverLabel = null;
        this._isHoverLabelShown = false;
        this._client = null;
        this._cockpitClient = null;
        this._activateSession = null;
        super._onDestroy();
    }
});
