// Resource Pulse: live CPU and memory in the top bar and on a desktop card, and, where the cockpit is configured, a
// desktop cockpit. The numbers come from the sampler service (service/, the systemd user unit resource-pulse.service,
// outside the shell) through one PulseClient, and the cockpit's from the cockpit service (service/cockpit.js,
// cockpit.service) through one CockpitClient; this file only draws. Both follow their service on the session bus.
//
// Where it draws (ruling D19): while the cockpit's layout is known (the one cached from the last enable, or one the
// service sent) and the cockpit is not SKIPPED, the cockpit's layer (cockpitLayer.js) holds a grid of cards on the
// cockpit monitor (lib/cockpitMonitor.js: the monitor the layout names, as Mutter's DisplayConfig identifies it, else
// the only one, else the largest non-primary), and the v2 card sits in its system cell; with none, the v2 card sits
// top right of the primary monitor's work area, as it always has. Both live in the layout manager's background group
// (above the wallpaper, below every window) and follow their work area as monitors and panels change, placed in one
// later before the next frame.
//
// Only a card can show apps, so the pulse client asks the service for its detail watch (the faster app scan) only while
// a card that draws the sampler's snapshot can be seen (lib/wiring.js isDetailWatchWanted: the v2 card, the system or
// the apps cell), and the cockpit client holds the cockpit's watch and its Changed subscription only while a card of
// the cockpit can be seen (lib/cockpitInteraction.js isCockpitWatchWanted); the overview hides them all, and so does a
// window covering them, which is most of the day. Each drawn card is checked on its own (lib/visibility.js cardsCover);
// while a window covers it, it is frozen: dimmed, told nothing new and repainting nothing until the reveal, which draws
// it at once from the latest, except once every FROZEN_REPAINT_INTERVAL_SECONDS, still dimmed (ruling D18), so a card
// misjudged as covered never shows stale numbers as live. The cover is checked on the window-manager and display
// signals, and, while a card is covered, on the moves, resizes, closing and workspace changes of the windows that cover
// it (so a window moved from the keyboard, or sent to another workspace, is seen); those come in bursts, so they are
// coalesced into one check before the next frame. The Samples that append to the histories check it at once, with no
// later of their own: every one while a card is visible, every COVER_BACKSTOP_TICKS-th while all are covered (a
// backstop for what no signal reports), and each one asks whether a frozen repaint is due and hands the cockpit's layer
// its Sample (a Changed is drawn on the next Sample, ruling D20). Nothing here runs on a timer while Samples flow. Only
// with every card covered and the service silent (the client's stall watchdog has published no data, so no Sample
// comes) does a COVER_FALLBACK_INTERVAL_SECONDS timeout check the cover and make the frozen repaint, and the next
// Sample removes it. The same check reads whether ding's DESKTOP window shows on the cockpit monitor: the cockpit's
// cards take the pointer only while none does. The shell's budgets are per state: docs/GNOME_CONFIGURATION_GUIDE.md,
// "What it costs".
//
// This runs inside gnome-shell, the Wayland compositor, so a mistake here destabilises the whole desktop. Without
// the unlock-dialog session mode the shell disables the extension whenever that mode is pushed and enables it
// when it pops. In GNOME 50 that is every lock AND every idle blank: a blank goes through ScreenShield.activate(),
// which pushes unlock-dialog even with locking off. The services keep sampling meanwhile, so the histories survive:
// the next enable's clients read them back with GetState. enable() and disable() still run many times a day and
// must leave nothing behind:
// - enable() builds everything synchronously and returns. GNOME 50's extension manager awaits enable() and calls
//   disable() only on an extension it has marked ACTIVE (extensionSystem.js _callExtensionEnable and
//   _callExtensionDisable), so an await inside enable() would let a lock that lands during it go unanswered and
//   leave the indicator on the lock screen.
// - the clients' D-Bus work (StartUnit, GetState, the Samples, the Changed) and the DisplayConfig read are
//   asynchronous and run after enable() returns; a failure there shows "no data" and is retried or logged, never
//   thrown.
// - a synchronous failure tears down whatever was built and rethrows, so the shell logs it once and reports the
//   extension as ERROR (which `gnome-extensions info` shows). Except the cockpit's layer (ruling D25): it is optional
//   and drawn from what the cockpit service sends, so a layer that cannot be built, at enable() or on an event,
//   rebuilt or placed is logged and the v2 card drawn top right instead, as with no cockpit; that layout is not drawn
//   again in this enable while the cockpit client holds it, nor kept for the next.
// - disable() works at any point, and twice in a row. It disconnects every signal (the covered check's and the
//   covering windows' too), removes its client listeners, its pending check and placement, the fallback timeout and
//   the DisplayConfig read before destroying anything, so no handler runs against a half-destroyed card.
// - each teardown step runs under its own guard (lib/teardown.js), the layer first, then the card: a step that throws
//   is logged and the rest still run, so one failure can neither leave a frozen card drawn as live nor mask the error
//   enable() is already rethrowing, and the fields are cleared first, so a later enable() starts clean.
// - the clients' destroy() release their watches and cancel their calls, so a disable never leaves a service scanning
//   for a card nobody can see.
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {PulseCard} from './card.js';
import {CockpitClient} from './cockpitClient.js';
import {CockpitLayer} from './cockpitLayer.js';
import {DisplayConfigReader} from './displayConfig.js';
import {PulseIndicator} from './indicator.js';
import {PulseClient} from './pulseClient.js';
import {
    COCKPIT_SYSTEM_CARD_ID, COVER_FALLBACK_INTERVAL_SECONDS, CockpitClientEventType,
} from './lib/constants.js';
import {DESKTOP_WINDOW_TYPE, isCockpitWatchWanted, isDesktopInteractive} from './lib/cockpitInteraction.js';
import {cockpitMonitorIndexFor} from './lib/cockpitMonitor.js';
import {
    CockpitLayerChange, cockpitLayerChange, cockpitLayoutToKeep, cockpitSurfacesSeen, frozenCardsDueRepaint,
    isPulseCardHeldHidden,
} from './lib/cockpitWiring.js';
import {RateLimitedLogger, describeErrorWithStack} from './lib/errorLog.js';
import {runEveryStep} from './lib/teardown.js';
import {
    CoverFallbackTimerChange, canWindowCoverCard, cardsCover, coverFallbackTimerChange, coveringWindowChanges,
    doRectsOverlap, frozenPaintStamps, isCoverBackstopDue,
} from './lib/visibility.js';
import {isDetailWatchWanted} from './lib/wiring.js';

/** The panel box the indicator goes in. */
const PANEL_BOX = 'right';
/** Where the indicator goes when the system menu cannot be found. */
const FALLBACK_PANEL_INDEX = 0;
/** The drawn cards count as visible until the first covered check, which runs as soon as they are placed. */
const IS_CARD_VISIBLE_BEFORE_COVER_CHECK = true;
/** Which cards count as visible until then: the v2 card, which is checked under the system card's id. */
const VISIBLE_CARD_IDS_BEFORE_COVER_CHECK = Object.freeze([COCKPIT_SYSTEM_CARD_ID]);
/**
 * The window types that can cover a card: ordinary windows and dialogs. Never ding's desktop window, which spans the
 * whole screen, a dock or a popup.
 */
const COVERING_WINDOW_TYPES = new Set([Meta.WindowType.NORMAL, Meta.WindowType.DIALOG]);
/** The windows read on no monitor: none, so every card counts as visible and no DESKTOP window shows. */
const NO_WINDOWS_ON_MONITOR = Object.freeze({metaWindows: [], frameRects: [], desktopWindows: []});
/** The template key of the journal line for a layer that could not be built, rebuilt or placed (lib/errorLog.js). */
const COCKPIT_LAYER_FAILURE_LOG_KEY = 'could not draw the cockpit layer';

/**
 * The index in its panel box of the system menu (quick settings), so an indicator inserted there sits just left
 * of it.
 *
 * @returns {number} That index, or FALLBACK_PANEL_INDEX when the system menu is not in a box.
 */
function systemMenuPanelIndex() {
    const systemMenuContainer = Main.panel.statusArea.quickSettings?.container;
    const systemMenuSiblings = systemMenuContainer?.get_parent()?.get_children() ?? [];
    const systemMenuIndex = systemMenuSiblings.indexOf(systemMenuContainer);
    return systemMenuIndex >= 0 ? systemMenuIndex : FALLBACK_PANEL_INDEX;
}

/**
 * A DESKTOP window (ding's) as lib/cockpitInteraction.js isDesktopInteractive reads it.
 *
 * @param {Meta.Window} metaWindow - A window of Meta.WindowType.DESKTOP.
 * @returns {{windowType: string, isShowing: boolean}} Its type name and whether it shows on its workspace.
 */
function desktopWindowOf(metaWindow) {
    return {windowType: DESKTOP_WINDOW_TYPE, isShowing: metaWindow.showing_on_its_workspace()};
}

/**
 * The shell's monitors as lib/cockpitMonitor.js takes them: plain objects, the primary one marked.
 *
 * @returns {Array<{index: number, x: number, y: number, width: number, height: number, isPrimary: boolean}>} One per
 *     monitor of Main.layoutManager.monitors, in its order.
 */
function shellMonitors() {
    const {monitors, primaryIndex} = Main.layoutManager;
    return monitors.map(monitor => ({
        index: monitor.index, x: monitor.x, y: monitor.y, width: monitor.width, height: monitor.height,
        isPrimary: monitor.index === primaryIndex,
    }));
}

export default class ResourcePulseExtension extends Extension {
    /**
     * @param {object} metadata - The extension's metadata, from the shell.
     */
    constructor(metadata) {
        super(metadata);
        this._client = null;
        this._cockpitClient = null;
        this._indicator = null;
        this._card = null;
        this._layer = null;
        this._displayConfigReader = null;
        // DisplayConfig's last GetCurrentState answer (unpacked), or null: none yet, or the monitors changed since.
        this._displayConfigState = null;
        // The cockpit's layout the layer could not be built, rebuilt or placed with in this enable, or null (ruling
        // D25): not drawn again while the cockpit client holds it (lib/cockpitWiring.js cockpitLayerChange), nor kept
        // for the next enable (cockpitLayoutToKeep).
        this._failedCockpitLayout = null;
        this._cardPlacementLaterId = null;
        this._cardCoverListenerId = null;
        this._cockpitListenerId = null;
        this._cardCoverCheckLaterId = null;
        this._coverFallbackSourceId = null;
        // The windows that covered a card at the last check, each followed (_followCoveringWindows).
        this._coveringWindows = new Set();
        // History notifications since the cover was last checked, for the backstop (lib/visibility.js
        // isCoverBackstopDue).
        this._ticksSinceCoverCheck = 0;
        // Monotonic µs of each frozen card's last paint, by card id: its freeze's own, then each frozen repaint's.
        this._frozenCardPaintedAtUsecByCardId = {};
        this._isOverviewVisible = false;
        // True while some drawn card can be seen right now (ruling D24: the backstop and the fallback timeout count a
        // cockpit with any card visible as visible, and the performance probe reads it, so false means nothing drawn
        // can be seen); then the drawn cards visible at the last check, by card id.
        this._isCardVisible = IS_CARD_VISIBLE_BEFORE_COVER_CHECK;
        this._visibleCardIds = VISIBLE_CARD_IDS_BEFORE_COVER_CHECK;
        // The answer the cockpit's watch and subscription were last given (lib/cockpitInteraction.js
        // isCockpitWatchWanted).
        this._isCockpitSubscriptionWanted = false;
        this._dropdownMenu = null;
        this._isDropdownOpen = false;
        // Both limiters are kept across enable() and disable(), so a failure that repeats on every enable (every
        // unlock and blank) is still logged at most once per 10 minutes. The extension's own failures (a teardown
        // step that threw) leave it broken: errors. The clients' (StartUnit refused, a call timed out, a payload they
        // could not read) heal by themselves: warnings.
        const nowUsec = () => GLib.get_monotonic_time();
        this._errorLog = new RateLimitedLogger({nowUsec, write: line => console.error(line)});
        this._clientLog = new RateLimitedLogger({nowUsec, write: line => console.warn(line)});
        // Kept across enable() and disable() as well, the same way: 'HH:MM' of the last snapshot with data, saved from
        // each client as teardown destroys it and seeded into the next. A client lives for one enable, so without it
        // the surfaces would say a bare "no data" after an unlock with the service down, rather than "no data since".
        this._lastGoodClockLabel = null;
        // Kept the same way: the cockpit's layout the layer was drawn from (lib/cockpitWiring.js cockpitLayoutToKeep),
        // seeded into the next cockpit client, so after an unlock or a blank the grid is drawn at once.
        this._lastCockpitLayout = null;
    }

    /**
     * Creates the clients, holding the detail watch and the cockpit's watch only while a card that needs them can be
     * seen; puts the indicator just left of the system menu; puts the v2 card on the desktop, keeps it placed and
     * freezes it while a window covers it; follows the cockpit, drawing its layer at once from the layout the last
     * enable kept; then starts the clients, which ask systemd for their services and follow them on the bus, all after
     * enable() returns.
     *
     * @returns {void}
     * @throws {Error} Whatever a synchronous step threw, after tearing down everything built so far; never what the
     *     cockpit's layer threw while being built or placed (ruling D25: the v2 card is drawn top right instead).
     */
    enable() {
        // GNOME never enables twice without disabling in between; if it ever did, replace rather than duplicate.
        this._tearDown();
        try {
            this._client = new PulseClient({errorLog: this._clientLog, lastGoodClockLabel: this._lastGoodClockLabel});
            this._cockpitClient = new CockpitClient({errorLog: this._clientLog, cachedLayout: this._lastCockpitLayout});
            this._followOverviewWithDetailWatch();
            this._indicator = new PulseIndicator(this._client);
            Main.panel.addToStatusArea(this.uuid, this._indicator, systemMenuPanelIndex(), PANEL_BOX);
            this._followDropdown();
            this._addCard();
            this._followCardCover();
            this._client.start();
            this._followCockpit();
            this._cockpitClient.start();
        } catch (error) {
            this._tearDown();
            throw error;
        }
    }

    /**
     * Disconnects every signal, then destroys the layer, the card, the indicator and the clients, each step guarded.
     * Safe at any point, and twice.
     *
     * @returns {void}
     */
    disable() {
        this._tearDown();
    }

    /**
     * Releases the watches while the overview is showing. The detail watch makes the service scan apps at the watched
     * cadence, which feeds only the cards' app lines, and the overview hides the cards (it hides the window group they
     * live in). 'showing' comes as the overview starts to open and 'hidden' once it has fully closed, so the watches
     * are released for the whole time the cards cannot be seen; enabled while the overview is already open (or
     * closing), the clients start without them.
     *
     * @returns {void}
     */
    _followOverviewWithDetailWatch() {
        Main.overview.connectObject(
            'showing', () => this._onOverviewVisibilityChanged(true),
            'hidden', () => this._onOverviewHidden(),
            this);
        this._onOverviewVisibilityChanged(Main.overview.visible);
    }

    /**
     * Follows the indicator's menu opening and closing: the dropdown shows the apps line like the desktop card, so
     * it wants the detail watch while open, and the cockpit's watch. Disconnected in _tearDown.
     *
     * @returns {void}
     */
    _followDropdown() {
        this._dropdownMenu = this._indicator.menu;
        this._dropdownMenu.connectObject(
            'open-state-changed', (_menu, isOpen) => this._onDropdownOpenStateChanged(isOpen),
            this);
    }

    /**
     * Records whether the dropdown is open, and updates both watches.
     *
     * @param {boolean} isOpen - True once the menu is open, false once it is closed.
     * @returns {void}
     */
    _onDropdownOpenStateChanged(isOpen) {
        this._isDropdownOpen = isOpen;
        this._syncDetailWatch();
        this._syncCockpitWatch();
    }

    /**
     * Once the overview has closed, records it and checks the cover again: windows may have been closed, moved or
     * minimized from the overview.
     *
     * @returns {void}
     */
    _onOverviewHidden() {
        this._onOverviewVisibilityChanged(false);
        this._syncCardCover();
    }

    /**
     * Records whether the overview is showing, and updates both watches.
     *
     * @param {boolean} isOverviewVisible - True while the overview is showing or opening.
     * @returns {void}
     */
    _onOverviewVisibilityChanged(isOverviewVisible) {
        this._isOverviewVisible = isOverviewVisible;
        this._syncDetailWatch();
        this._syncCockpitWatch();
    }

    /**
     * Which surfaces the last cover check left seen (lib/cockpitWiring.js cockpitSurfacesSeen): a card of the cockpit,
     * and a card that draws the sampler's snapshot.
     *
     * @returns {{isAnyCockpitCardVisible: boolean, isSnapshotCardVisible: boolean}} The two answers.
     */
    _surfacesSeen() {
        return cockpitSurfacesSeen({isCockpitLayerShown: this._layer !== null, visibleCardIds: this._visibleCardIds});
    }

    /**
     * Tells the pulse client whether a detail watch is wanted (lib/wiring.js isDetailWatchWanted), from whether a card
     * that draws the sampler's snapshot can be seen, whether the overview is showing and whether the dropdown is open,
     * if there is a client. The client sends only a change.
     *
     * @returns {void}
     */
    _syncDetailWatch() {
        const {isSnapshotCardVisible} = this._surfacesSeen();
        const isWanted = isDetailWatchWanted({
            isCardVisible: isSnapshotCardVisible,
            isDropdownOpen: this._isDropdownOpen,
            isOverviewVisible: this._isOverviewVisible,
        });
        this._client?.setDetailWatchWanted(isWanted);
    }

    /**
     * Tells the cockpit client whether its watch and its Changed subscription are wanted, both the same answer
     * (lib/cockpitInteraction.js isCockpitWatchWanted): a card of the cockpit can be seen outside the overview, or the
     * dropdown is open. Kept for the layer's Sample (its suspicion pulls) and the frozen repaint (ruling D18). The
     * client sends only a change.
     *
     * @returns {void}
     */
    _syncCockpitWatch() {
        const {isAnyCockpitCardVisible} = this._surfacesSeen();
        const isWanted = isCockpitWatchWanted({
            isAnyCockpitCardVisible,
            isDropdownOpen: this._isDropdownOpen,
            isOverviewVisible: this._isOverviewVisible,
        });
        this._isCockpitSubscriptionWanted = isWanted;
        this._cockpitClient?.setWatchWanted(isWanted);
        this._cockpitClient?.setSubscriptionWanted(isWanted);
    }

    /**
     * Creates the v2 card, puts it top right (_putCardTopRight: in the background group, above the wallpaper, below
     * every window; a new wallpaper actor goes to the bottom of that group, so the card stays above it), places it, and
     * places the cards again whenever the monitors change, a work area changes (a panel or dock strut) or the v2
     * card's own width changes while it is top right, each just before the next frame (_queueCardPlacement).
     *
     * @returns {void}
     */
    _addCard() {
        this._card = new PulseCard(this._client);
        Main.layoutManager.connectObject('monitors-changed', () => this._onMonitorsChanged(), this);
        global.display.connectObject('workareas-changed', () => this._queueCardPlacement(), this);
        this._putCardTopRight();
        this._placeCard();
    }

    /**
     * Puts the v2 card back where it is drawn with no cockpit: out of any parent (the layer gives it back unparented;
     * this is for a failure that did not), in the background group, at its fixed width (clearCellSize), its width
     * followed again so a change of it re-places the card.
     *
     * @returns {void}
     */
    _putCardTopRight() {
        this._card.get_parent()?.remove_child(this._card);
        Main.layoutManager._backgroundGroup.add_child(this._card);
        this._card.clearCellSize();
        this._followCardWidth();
    }

    /**
     * Follows the v2 card's width while it sits top right, where its left edge depends on it. The system cell sizes
     * it otherwise, so _addCockpitLayer disconnects this.
     *
     * @returns {void}
     */
    _followCardWidth() {
        this._card.connectObject('notify::width', () => this._queueCardPlacement(), this);
    }

    /**
     * The monitors changed: DisplayConfig's answer describes the old ones, so it is forgotten and asked for again while
     * a layer is shown (until it answers, the monitor rule falls back), and the cards are placed before the next frame.
     *
     * @returns {void}
     */
    _onMonitorsChanged() {
        this._displayConfigState = null;
        if (this._layer !== null)
            this._displayConfigReader?.requestState();
        this._queueCardPlacement();
    }

    /**
     * Places what is drawn, and checks whether a window covers it there: the v2 card top right of the primary monitor's
     * work area while no cockpit layer is shown, else the layer on the cockpit monitor (the system cell holds the v2
     * card then, and nothing may move it).
     *
     * @returns {void}
     */
    _placeCard() {
        if (this._layer === null)
            this._card?.placeOnPrimaryMonitor();
        else
            this._placeCockpitLayer();
        this._syncCardCover();
    }

    /**
     * Places the layer on the cockpit monitor (lib/cockpitMonitor.js cockpitMonitorIndexFor: the shell's monitors,
     * DisplayConfig's last answer and the layout's rule) at its work area. With no monitor at all the layer stays where
     * it is until the monitors come back.
     *
     * @returns {void}
     */
    _placeCockpitLayer() {
        const monitorIndex = cockpitMonitorIndexFor({
            monitors: shellMonitors(),
            displayConfigState: this._displayConfigState,
            monitorRule: this._layer.layout.monitor,
        });
        if (monitorIndex === null)
            return;
        const workArea = Main.layoutManager.getWorkAreaForMonitor(monitorIndex);
        this._layer.placeOnMonitor(monitorIndex, workArea);
    }

    /**
     * Keeps the cards frozen, and the watches released, while windows cover them (_syncCardCover).
     * - The window-manager and display signals come in bursts (a restack can come several times in one frame), so each
     *   queues one coalesced check before the next frame (_queueCardCoverCheck): every restack (a window raised,
     *   opened or closed), a window created or leaving a monitor (ding's DESKTOP window coming or going, which decides
     *   whether the cockpit takes the pointer), a monitor entering or leaving fullscreen, a minimize, an unminimize, a
     *   maximize, unmaximize or tile (size-changed), the end of a drag (grab-op-end), a workspace switch, and "show
     *   desktop" (Super+D) being toggled, which hides windows without minimizing them.
     * - While a card is covered, each window that covers it is followed too: a move or a resize of it (even from the
     *   keyboard, which no other signal reports) or its being sent to another workspace queues the same check, and its
     *   closing drops it and queues the check (_followCoveringWindows).
     * - Every history update (a Sample that appends to the histories, about every 2 s, a state, or no data) is a tick
     *   (_onCardCoverTick, a client history listener). While a card is visible each tick checks at once, with no
     *   later: it comes at most once a tick, and a later would schedule a frame each time. While every card is covered
     *   only every COVER_BACKSTOP_TICKS-th tick checks, as a backstop, and every tick asks whether a frozen repaint is
     *   due. With the service silent no tick comes, so the fallback timeout checks instead (_syncCoverFallbackTimer).
     * - The placement (_placeCard, which already checked once in _addCard) and the overview closing (_onOverviewHidden)
     *   check at once too.
     *
     * @returns {void}
     */
    _followCardCover() {
        const queueCardCoverCheck = () => this._queueCardCoverCheck();
        global.display.connectObject(
            'restacked', queueCardCoverCheck,
            'window-created', queueCardCoverCheck,
            'window-left-monitor', queueCardCoverCheck,
            'in-fullscreen-changed', queueCardCoverCheck,
            'grab-op-end', queueCardCoverCheck,
            this);
        global.window_manager.connectObject(
            'minimize', queueCardCoverCheck,
            'unminimize', queueCardCoverCheck,
            'size-changed', queueCardCoverCheck,
            'switch-workspace', queueCardCoverCheck,
            this);
        global.workspace_manager.connectObject('showing-desktop-changed', queueCardCoverCheck, this);
        this._cardCoverListenerId = this._client.addHistoryListener(() => this._onCardCoverTick());
    }

    /**
     * One tick of the client (a history notification: a Sample that appended to the histories, a state, or no data):
     * counts it, checks the cover at once when the backstop says so (lib/visibility.js isCoverBackstopDue: every tick
     * while a card is visible, every COVER_BACKSTOP_TICKS-th while all are covered), which also starts or removes the
     * fallback timeout, or else only starts or removes it, as the service's liveness says, so it is asked once a tick;
     * then, whether or not it checked, repaints each covered card whose frozen repaint is due, so the repaint keeps to
     * FROZEN_REPAINT_INTERVAL_SECONDS rather than to the backstop; and last hands the cockpit's layer its Sample (it
     * draws the sources a Changed left pending and pulls its suspect sources). No later, so a tick schedules no frame
     * of its own. The client logs a listener that throws.
     *
     * @returns {void}
     */
    _onCardCoverTick() {
        this._ticksSinceCoverCheck += 1;
        const isCovered = !this._isCardVisible;
        if (isCoverBackstopDue({isCovered, ticksSinceCoverCheck: this._ticksSinceCoverCheck}))
            this._syncCardCover();
        else
            this._syncCoverFallbackTimer();
        this._repaintFrozenCardsIfDue();
        this._layer?.onSampleTick({isSubscriptionWanted: this._isCockpitSubscriptionWanted});
    }

    /**
     * Checks the cover before the next frame, once however many window-manager, display and covering-window signals
     * come before then (a restack can come several times in one frame, a dragged window moves on every one), in a
     * BEFORE_REDRAW later as _queueCardPlacement does. The later forgets its id first, so a failure cannot leave the
     * check marked pending for good; it never throws out of its callback, which runs inside the compositor's frame (a
     * failure is logged, rate-limited); and it returns GLib.SOURCE_REMOVE on every path.
     *
     * @returns {void}
     */
    _queueCardCoverCheck() {
        if (this._cardCoverCheckLaterId !== null)
            return;
        this._cardCoverCheckLaterId = global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
            this._cardCoverCheckLaterId = null;
            try {
                this._syncCardCover();
            } catch (error) {
                const errorText = describeErrorWithStack(error);
                this._errorLog.log(`could not check the cover: ${errorText}`);
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * Removes a pending cover check, if any.
     *
     * @returns {void}
     */
    _cancelCardCoverCheck() {
        if (this._cardCoverCheckLaterId === null)
            return;
        const laterId = this._cardCoverCheckLaterId;
        this._cardCoverCheckLaterId = null;
        global.compositor.get_laters().remove(laterId);
    }

    /**
     * Freezes each drawn card a window covers and unfreezes each one none does (a revealed card draws the latest at
     * once), and stamps each new freeze's paint, which the frozen repaint counts from (lib/visibility.js
     * frozenPaintStamps); records whether any card can be seen, and which; restarts the backstop's count; lets the
     * cockpit's cards take the pointer only while no DESKTOP window shows on their monitor; starts or removes the
     * fallback timeout; updates both watches, wanted only while a card that needs them can be seen; and only then
     * follows the windows that cover a card, so a failure connecting or disconnecting one can never skip a freeze, a
     * reveal, or a watch a revealed card needs. Does nothing without a card.
     *
     * @returns {void}
     */
    _syncCardCover() {
        if (this._card === null)
            return;
        const {isCovered, coveredCardIds, visibleCardIds, coveringWindows, isCockpitInteractive} =
            this._readCardCover();
        this._ticksSinceCoverCheck = 0;
        this._frozenCardPaintedAtUsecByCardId = frozenPaintStamps({
            stampsByCardId: this._frozenCardPaintedAtUsecByCardId, coveredCardIds, nowUsec: GLib.get_monotonic_time(),
        });
        for (const cardId of coveredCardIds)
            this._setCardFrozen(cardId, true);
        for (const cardId of visibleCardIds)
            this._setCardFrozen(cardId, false);
        this._isCardVisible = !isCovered;
        this._visibleCardIds = visibleCardIds;
        this._layer?.setInteractive(isCockpitInteractive);
        this._syncCoverFallbackTimer();
        this._syncDetailWatch();
        this._syncCockpitWatch();
        this._followCoveringWindows(coveringWindows);
    }

    /**
     * Freezes or unfreezes one drawn card: the v2 card top right with no layer (checked under the system card's id),
     * else the layer's card.
     *
     * @param {string} cardId - The card's id.
     * @param {boolean} isFrozen - True while covered.
     * @returns {void}
     */
    _setCardFrozen(cardId, isFrozen) {
        if (this._layer === null)
            this._card.setFrozen(isFrozen);
        else
            this._layer.setCardFrozen(cardId, isFrozen);
    }

    /**
     * Starts the fallback timeout, which checks the cards every COVER_FALLBACK_INTERVAL_SECONDS while all are covered
     * and the service is silent, or removes it once a card is revealed or the service is live again (lib/visibility.js
     * coverFallbackTimerChange). Asked on each cover check (the cover may have changed) and on each tick (the
     * liveness may have: the stall watchdog's no data starts it, the next Sample removes it).
     *
     * @returns {void}
     */
    _syncCoverFallbackTimer() {
        const timerChange = coverFallbackTimerChange({
            isCovered: !this._isCardVisible,
            isServiceLive: this._client?.isLive === true,
            isTimerRunning: this._coverFallbackSourceId !== null,
        });
        if (timerChange === CoverFallbackTimerChange.START) {
            const onFallbackTimeout = () => this._onCoverFallbackTimeout();
            this._coverFallbackSourceId =
                GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, COVER_FALLBACK_INTERVAL_SECONDS, onFallbackTimeout);
        } else if (timerChange === CoverFallbackTimerChange.STOP) {
            this._removeCoverFallbackTimer();
        }
    }

    /**
     * The fallback timeout: checks the cover at once, with no later, then repaints each card still covered whose frozen
     * repaint is due (_repaintFrozenCardsIfDue). A reveal removes this very source from inside it
     * (_syncCoverFallbackTimer), which GLib allows; the value returned after that is ignored, and the id is already
     * forgotten, so nothing removes the source again. It never throws out of the callback, which would end the source
     * behind the id the extension keeps; a failure is logged, rate-limited.
     *
     * @returns {boolean} GLib.SOURCE_CONTINUE, always.
     */
    _onCoverFallbackTimeout() {
        try {
            this._syncCardCover();
            this._repaintFrozenCardsIfDue();
        } catch (error) {
            const errorText = describeErrorWithStack(error);
            this._errorLog.log(`could not check the cover: ${errorText}`);
        }
        return GLib.SOURCE_CONTINUE;
    }

    /**
     * Repaints, dimmed, each covered card whose frozen repaint is due (lib/cockpitWiring.js frozenCardsDueRepaint:
     * FROZEN_REPAINT_INTERVAL_SECONDS since its last paint; a card that draws cockpit sources only while the cockpit's
     * subscription is held, ruling D18), so a card misjudged as covered updates, dimmed, rather than showing stale
     * numbers. Asked on every tick and by the fallback timeout. Only covered cards hold a stamp: a revealed card is
     * left alone, the reveal repainted it at once. Does nothing without a card.
     *
     * @returns {void}
     */
    _repaintFrozenCardsIfDue() {
        if (this._card === null)
            return;
        const nowUsec = GLib.get_monotonic_time();
        const dueCardIds = frozenCardsDueRepaint({
            frozenPaintedAtUsecByCardId: this._frozenCardPaintedAtUsecByCardId,
            nowUsec,
            isCockpitSubscriptionWanted: this._isCockpitSubscriptionWanted,
        });
        for (const cardId of dueCardIds) {
            this._frozenCardPaintedAtUsecByCardId[cardId] = nowUsec;
            this._repaintFrozenCard(cardId);
        }
    }

    /**
     * Repaints one frozen card, dimmed: with no layer the v2 card top right, given the client's latest snapshot here
     * because the client tells a covered card none while the detail watch is released (unless the dropdown is open);
     * else the layer's card, which the layer draws from what the clients hold.
     *
     * @param {string} cardId - The card's id.
     * @returns {void}
     */
    _repaintFrozenCard(cardId) {
        if (this._layer !== null) {
            this._layer.repaintFrozenCard(cardId);
            return;
        }
        const client = this._client;
        this._card.update(client.latestSnapshot, client.lastGoodClockLabel);
        this._card.repaintFrozen();
    }

    /**
     * Removes the fallback timeout, if it runs. The id is forgotten first, so a removal from inside its own callback
     * leaves nothing to remove again.
     *
     * @returns {void}
     */
    _removeCoverFallbackTimer() {
        if (this._coverFallbackSourceId === null)
            return;
        const sourceId = this._coverFallbackSourceId;
        this._coverFallbackSourceId = null;
        GLib.source_remove(sourceId);
    }

    /**
     * Reads the cover of every drawn card on its monitor (lib/visibility.js cardsCover: a card is covered when its
     * monitor is fullscreen or one window that can cover it contains its whole rectangle), the windows that contain a
     * card, which _followCoveringWindows follows, and whether the cockpit's cards may take the pointer
     * (lib/cockpitInteraction.js isDesktopInteractive: no DESKTOP window shows on that monitor). With no monitor at all
     * every card counts as visible, with no covering window.
     *
     * @returns {{isCovered: boolean, coveredCardIds: string[], visibleCardIds: string[],
     *     coveringWindows: Meta.Window[], isCockpitInteractive: boolean}} The cover: isCovered when every drawn card
     *     is.
     */
    _readCardCover() {
        const monitor = this._coverMonitor();
        const cards = this._drawnCardRects();
        const {metaWindows, frameRects: windowRects, desktopWindows} =
            monitor ? this._readWindowsOnMonitor(monitor) : NO_WINDOWS_ON_MONITOR;
        const {isEveryCardCovered, coveredCardIds, visibleCardIds, coveringWindowIndexes} = cardsCover({
            cards, isMonitorInFullscreen: monitor?.inFullscreen === true, windowRects,
        });
        return {
            isCovered: isEveryCardCovered,
            coveredCardIds,
            visibleCardIds,
            coveringWindows: coveringWindowIndexes.map(windowIndex => metaWindows[windowIndex]),
            isCockpitInteractive: isDesktopInteractive({windowsOnMonitor: desktopWindows}),
        };
    }

    /**
     * The monitor the drawn cards are on: the primary one for the v2 card top right, else the layer's monitor.
     *
     * @returns {object|null} The monitor (layout.js Monitor: its geometry and inFullscreen), or null for none.
     */
    _coverMonitor() {
        if (this._layer === null)
            return Main.layoutManager.primaryMonitor ?? null;
        return Main.layoutManager.monitors[this._layer.monitorIndex] ?? null;
    }

    /**
     * Each drawn card's rectangle on the stage: the layer's cards' cells, or with no layer the v2 card, under the
     * system card's id.
     *
     * @returns {Array<{cardId: string, rect: {x: number, y: number, width: number, height: number}}>} One per card.
     */
    _drawnCardRects() {
        if (this._layer !== null)
            return this._layer.cardRects();
        return [{cardId: COCKPIT_SYSTEM_CARD_ID, rect: this._cardRectOnStage()}];
    }

    /**
     * Follows exactly the windows that cover a card now: connects to those it does not follow yet and disconnects
     * from those that stopped covering one (lib/visibility.js coveringWindowChanges), so a check that finds the same
     * windows connects and disconnects nothing.
     *
     * @param {Meta.Window[]} coveringWindows - The windows that contain a card now.
     * @returns {void}
     */
    _followCoveringWindows(coveringWindows) {
        const {windowsToFollow, windowsToRelease} = coveringWindowChanges({
            heldWindows: [...this._coveringWindows],
            coveringWindows,
        });
        for (const metaWindow of windowsToRelease)
            this._stopFollowingCoveringWindow(metaWindow);
        for (const metaWindow of windowsToFollow)
            this._startFollowingCoveringWindow(metaWindow);
    }

    /**
     * Follows a window that covers a card: its move and its resize (from a drag, the keyboard or the application),
     * and its being sent to another workspace (which no global signal reports when the user does not follow it), queue
     * the coalesced cover check, and its closing drops it at once (_onCoveringWindowUnmanaged).
     *
     * @param {Meta.Window} metaWindow - A window that contains a card.
     * @returns {void}
     */
    _startFollowingCoveringWindow(metaWindow) {
        const queueCardCoverCheck = () => this._queueCardCoverCheck();
        metaWindow.connectObject(
            'position-changed', queueCardCoverCheck,
            'size-changed', queueCardCoverCheck,
            'workspace-changed', queueCardCoverCheck,
            'unmanaged', () => this._onCoveringWindowUnmanaged(metaWindow),
            this);
        this._coveringWindows.add(metaWindow);
    }

    /**
     * Stops following a window: forgets it, then disconnects every handler connected to it.
     *
     * @param {Meta.Window} metaWindow - A window followed until now.
     * @returns {void}
     */
    _stopFollowingCoveringWindow(metaWindow) {
        this._coveringWindows.delete(metaWindow);
        metaWindow.disconnectObject(this);
    }

    /**
     * A covering window was closed: it is dropped at once, so no handler runs against it afterwards, and the cover is
     * checked again before the next frame (a card may now be visible).
     *
     * @param {Meta.Window} metaWindow - The window that was unmanaged.
     * @returns {void}
     */
    _onCoveringWindowUnmanaged(metaWindow) {
        this._stopFollowingCoveringWindow(metaWindow);
        this._queueCardCoverCheck();
    }

    /**
     * Stops following every covering window, for teardown. The set is emptied first, so a later enable() starts with
     * none whatever a disconnection throws, and each window is disconnected under its own guard, so one that throws is
     * logged, rate-limited, and every other window is still disconnected.
     *
     * @returns {void}
     */
    _disconnectCoveringWindows() {
        const coveringWindows = [...this._coveringWindows];
        this._coveringWindows.clear();
        for (const metaWindow of coveringWindows) {
            try {
                metaWindow.disconnectObject(this);
            } catch (error) {
                this._logTearDownFailure('disconnect from a covering window', error);
            }
        }
    }

    /**
     * The v2 card's rectangle in stage coordinates, read now: the card moves on monitor and work-area changes. It is
     * where the card is placed, from get_position() and get_size(), which give the placed position and the preferred
     * size until the next allocation, rather than get_transformed_position(), which gives the last allocation's and
     * so the old place right after a placement (and nothing useful before the first, at every enable). The card's
     * parent, the background group, sits at the stage's origin: placeOnPrimaryMonitor already places the card at
     * work-area coordinates, which are the stage's.
     *
     * @returns {{x: number, y: number, width: number, height: number}} The rectangle, in logical pixels.
     */
    _cardRectOnStage() {
        const [x, y] = this._card.get_position();
        const [width, height] = this._card.get_size();
        return {x, y, width, height};
    }

    /**
     * The windows on a monitor that the cover check reads, in one pass over the display's windows: those that can
     * cover a card, with their frame rectangles (lib/visibility.js canWindowCoverCard: normal and dialog windows, not
     * minimized, showing on their workspace, on the active workspace or on all of them, whose frame overlaps the
     * monitor; the state is checked first, so only those windows' frames are read), and the DESKTOP windows (ding's)
     * that overlap it, with whether each shows. Frame rects are in stage (logical) coordinates, as the cards' are.
     *
     * @param {{x: number, y: number, width: number, height: number}} monitor - The monitor's geometry.
     * @returns {{metaWindows: Meta.Window[], frameRects: Array<{x: number, y: number, width: number, height: number}>,
     *     desktopWindows: Array<{windowType: string, isShowing: boolean}>}} The windows that can cover a card, each
     *     one's frame rectangle at the same index, and the DESKTOP windows as lib/cockpitInteraction.js reads them.
     */
    _readWindowsOnMonitor(monitor) {
        const activeWorkspace = global.workspace_manager.get_active_workspace();
        const metaWindows = [];
        const frameRects = [];
        const desktopWindows = [];
        for (const metaWindow of global.display.list_all_windows()) {
            const windowType = metaWindow.get_window_type();
            if (windowType === Meta.WindowType.DESKTOP) {
                if (doRectsOverlap(metaWindow.get_frame_rect(), monitor))
                    desktopWindows.push(desktopWindowOf(metaWindow));
                continue;
            }
            const canCover = canWindowCoverCard({
                isNormalOrDialog: COVERING_WINDOW_TYPES.has(windowType),
                isMinimized: metaWindow.minimized,
                isShowing: metaWindow.showing_on_its_workspace(),
                isOnActiveWorkspace: metaWindow.is_on_all_workspaces() ||
                    metaWindow.get_workspace() === activeWorkspace,
            });
            const frameRect = canCover ? metaWindow.get_frame_rect() : null;
            if (frameRect !== null && doRectsOverlap(frameRect, monitor)) {
                metaWindows.push(metaWindow);
                frameRects.push(frameRect);
            }
        }
        return {metaWindows, frameRects, desktopWindows};
    }

    /**
     * Places the cards before the next frame: the v2 card's notify::width comes during allocation, and moving an actor
     * then leaves it needing an allocation, which Clutter warns about; a monitors or work-area change comes in a burst.
     * A BEFORE_REDRAW later places them before the next frame instead, as the shell's own layout.js does, once however
     * many calls come before then. It forgets its id first and never throws out of its callback, which runs inside the
     * compositor's frame (a failure is logged, rate-limited).
     *
     * @returns {void}
     */
    _queueCardPlacement() {
        if (this._cardPlacementLaterId !== null)
            return;
        this._cardPlacementLaterId = global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
            this._cardPlacementLaterId = null;
            try {
                this._placeCard();
            } catch (error) {
                const errorText = describeErrorWithStack(error);
                this._errorLog.log(`could not place the cards: ${errorText}`);
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    /**
     * Removes a pending card placement, if any.
     *
     * @returns {void}
     */
    _cancelCardPlacement() {
        if (this._cardPlacementLaterId === null)
            return;
        const laterId = this._cardPlacementLaterId;
        this._cardPlacementLaterId = null;
        global.compositor.get_laters().remove(laterId);
    }

    /**
     * Follows the cockpit: makes the DisplayConfig reader the cockpit monitor's rule needs (asked when a layer is
     * shown and on each monitors change), follows the cockpit client's events, and draws the layer at once when the
     * cached layout says so (a login's first enable has none, so the v2 card sits top right until the service's
     * layout comes; a layer that cannot be built from it or placed leaves the v2 card top right too, ruling D25).
     *
     * @returns {void}
     */
    _followCockpit() {
        this._displayConfigReader = new DisplayConfigReader({
            errorLog: this._clientLog, onStateRead: displayConfigState => this._onDisplayConfigRead(displayConfigState),
        });
        this._cockpitListenerId = this._cockpitClient.addListener(event => this._onCockpitClientEvent(event));
        this._syncCockpitLayer(false);
    }

    /**
     * A cockpit client event: the layer follows its state and its layout (_syncCockpitLayer). The layer follows the
     * sources itself. The client logs a listener that throws.
     *
     * @param {object} event - The client's event (CockpitClientEventType).
     * @returns {void}
     */
    _onCockpitClientEvent(event) {
        this._syncCockpitLayer(event.type === CockpitClientEventType.LAYOUT);
    }

    /**
     * Adds, removes or rebuilds the layer as lib/cockpitWiring.js cockpitLayerChange says (ruling D19; never from the
     * layout that failed to draw in this enable, and away from a layer when that layout comes back, ruling D25).
     * After a removal the v2 card is held frozen if nothing draws it and the cards are placed again, unguarded, as
     * with no cockpit; an add or a rebuild does the same inside its own guard (_drawCockpitLayer). Nothing else
     * changes nothing.
     *
     * @param {boolean} isLayoutEvent - The event is a layout event (a shown layer is rebuilt from it).
     * @returns {void}
     */
    _syncCockpitLayer(isLayoutEvent) {
        const layerChange = cockpitLayerChange({
            isLayerShown: this._layer !== null,
            clientState: this._cockpitClient.state,
            layout: this._cockpitClient.layout,
            isLayoutEvent,
            failedLayout: this._failedCockpitLayout,
        });
        if (layerChange === CockpitLayerChange.NONE)
            return;
        if (layerChange === CockpitLayerChange.REMOVE) {
            this._removeCockpitLayer();
            this._placeAfterLayerChange();
        } else {
            this._drawCockpitLayer(layerChange);
        }
    }

    /**
     * Adds the layer, or rebuilds the shown one from the client's layout, then, with the layer shown, holds the v2 card
     * frozen if the layer draws it nowhere and places the layer, which checks the cover over its cards. A layer that
     * cannot be built, rebuilt or placed never takes the extension down, at enable() or on an event (ruling D25): any
     * of those steps failing is a failed build, so the v2 card goes back top right (_fallBackToTopRightCard), and then
     * the hold and the placement run once more for it, outside this guard, as with no cockpit: a failure of the core
     * there (the v2 card, the cover, the watches) is still thrown.
     *
     * @param {string} layerChange - CockpitLayerChange.ADD or CockpitLayerChange.REBUILD.
     * @returns {void}
     */
    _drawCockpitLayer(layerChange) {
        try {
            if (layerChange === CockpitLayerChange.ADD)
                this._addCockpitLayer();
            else
                this._layer.setLayout(this._cockpitClient.layout);
            this._placeAfterLayerChange();
        } catch (error) {
            this._fallBackToTopRightCard(error);
            this._placeAfterLayerChange();
        }
    }

    /**
     * After the layer changed: holds the v2 card frozen if the layer now draws it nowhere (ruling D21), then places
     * what is drawn, which checks the cover.
     *
     * @returns {void}
     */
    _placeAfterLayerChange() {
        this._holdHiddenPulseCardFrozen();
        this._placeCard();
    }

    /**
     * The layer could not be built, rebuilt or placed: remembers the client's layout as the one that failed in this
     * enable (lib/cockpitWiring.js: not drawn again while the client holds it, nor kept for the next enable), logs the
     * failure (an error of the extension's own, rate-limited by its template key), destroys a layer that was built or
     * half-rebuilt (which gives the v2 card back; a layer that failed to build has destroyed itself already) and puts
     * the v2 card back top right, as with no cockpit; the caller places it there. The layer's destroy runs each of its
     * steps under its own guard, so it throws nothing here.
     *
     * @param {*} error - What the build, the rebuild or the placement threw.
     * @returns {void}
     */
    _fallBackToTopRightCard(error) {
        this._failedCockpitLayout = this._cockpitClient.layout;
        const errorText = describeErrorWithStack(error);
        this._errorLog.log(`could not draw the cockpit layer, so the card is drawn top right: ${errorText}`,
            COCKPIT_LAYER_FAILURE_LOG_KEY);
        const layer = this._layer;
        this._layer = null;
        layer?.destroy();
        this._putCardTopRight();
    }

    /**
     * Keeps the v2 card frozen while the layer draws it nowhere (lib/cockpitWiring.js isPulseCardHeldHidden: the
     * layout names no system card), so it does no work for nobody; no cover check counts it then.
     *
     * @returns {void}
     */
    _holdHiddenPulseCardFrozen() {
        const isHeldHidden = isPulseCardHeldHidden({
            isCockpitLayerShown: this._layer !== null, drawnCardIds: this._layer?.drawnCardIds ?? [],
        });
        if (isHeldHidden)
            this._card.setFrozen(true);
    }

    /**
     * Makes the layer, which takes the v2 card out of the background group (into its system cell, or nowhere), and
     * asks DisplayConfig which monitor is which. The v2 card's width no longer places it: the cell sizes it.
     *
     * @returns {void}
     * @throws {Error} What the layer threw while building, having destroyed what it built and given the v2 card back
     *     (_drawCockpitLayer puts the card back top right).
     */
    _addCockpitLayer() {
        this._card.disconnectObject(this);
        this._layer = new CockpitLayer({
            cockpitClient: this._cockpitClient, pulseClient: this._client, pulseCard: this._card,
            errorLog: this._errorLog, onSessionActivated: sessionId => this._activateSession(sessionId),
        });
        this._displayConfigReader.requestState();
    }

    /**
     * Destroys the layer, which gives the v2 card back, and puts the v2 card back top right.
     *
     * @returns {void}
     */
    _removeCockpitLayer() {
        const layer = this._layer;
        this._layer = null;
        layer.destroy();
        this._putCardTopRight();
    }

    /**
     * DisplayConfig answered (or failed: null): the layer is placed again, on the monitor the answer identifies.
     *
     * @param {*} displayConfigState - The unpacked GetCurrentState reply, or null.
     * @returns {void}
     */
    _onDisplayConfigRead(displayConfigState) {
        this._displayConfigState = displayConfigState;
        if (this._layer !== null)
            this._queueCardPlacement();
    }

    /**
     * A click on a session row of the cockpit. It does nothing yet: taking the user to the session's herdr pane
     * (FocusSession, then the window lib/cockpitInteraction.js pickWindowToActivate names) is the next change.
     *
     * @param {string} _sessionId - The clicked session's id.
     * @returns {void}
     */
    _activateSession(_sessionId) {
        // Nothing yet; see above.
    }

    /**
     * Undoes enable(), whatever it got to, and never throws: keeps the client's last good clock label and the
     * cockpit's layout for the next enable (getter reads, before anything is destroyed, guarded as each step is: on a
     * failure what is already kept stays; never a layout that failed to draw); clears every field (the failed layout
     * too, so each enable tries the layout it is sent); then disconnects from the overview, the layout manager,
     * the display, the window manager, the workspace manager, the card, the dropdown menu and the covering windows,
     * removes both client listeners, the pending cover check, the fallback timeout and a pending placement, and
     * cancels the DisplayConfig read; then destroys the layer (which gives the v2 card back), the card (which also
     * takes it out of the background group), the indicator and the clients. Each step runs under its own guard
     * (lib/teardown.js runEveryStep): one that throws is logged, rate-limited, and the rest still run.
     *
     * @returns {void}
     */
    _tearDown() {
        const card = this._card;
        const layer = this._layer;
        const indicator = this._indicator;
        const client = this._client;
        const cockpitClient = this._cockpitClient;
        const displayConfigReader = this._displayConfigReader;
        const cardCoverListenerId = this._cardCoverListenerId;
        const cockpitListenerId = this._cockpitListenerId;
        const dropdownMenu = this._dropdownMenu;
        // The getter parses a Sample still unread, so it can throw: the label already held is kept then.
        try {
            this._lastGoodClockLabel = client?.lastGoodClockLabel ?? this._lastGoodClockLabel;
        } catch (error) {
            this._logTearDownFailure('read the client\'s last good clock label', error);
        }
        // The layout the layer was drawn from (none once SKIPPED, nor one that failed to draw in this enable); with no
        // client the layout already kept stays.
        try {
            this._lastCockpitLayout = cockpitClient === null
                ? this._lastCockpitLayout
                : cockpitLayoutToKeep({
                    clientState: cockpitClient.state, layout: cockpitClient.layout,
                    failedLayout: this._failedCockpitLayout,
                });
        } catch (error) {
            this._logTearDownFailure('read the cockpit client\'s layout', error);
        }
        // Cleared first: whatever a step below throws, no later enable() or disable() finds a half-destroyed part.
        this._card = null;
        this._layer = null;
        this._indicator = null;
        this._client = null;
        this._cockpitClient = null;
        this._displayConfigReader = null;
        this._displayConfigState = null;
        this._failedCockpitLayout = null;
        this._cardCoverListenerId = null;
        this._cockpitListenerId = null;
        this._dropdownMenu = null;
        this._isDropdownOpen = false;
        this._isOverviewVisible = false;
        this._isCardVisible = IS_CARD_VISIBLE_BEFORE_COVER_CHECK;
        this._visibleCardIds = VISIBLE_CARD_IDS_BEFORE_COVER_CHECK;
        this._frozenCardPaintedAtUsecByCardId = {};
        this._isCockpitSubscriptionWanted = false;
        this._ticksSinceCoverCheck = 0;
        runEveryStep([
            {name: 'disconnect from the overview', run: () => Main.overview.disconnectObject(this)},
            {name: 'disconnect from the layout manager', run: () => Main.layoutManager.disconnectObject(this)},
            {name: 'disconnect from the display', run: () => global.display.disconnectObject(this)},
            {name: 'disconnect from the window manager', run: () => global.window_manager.disconnectObject(this)},
            {name: 'disconnect from the workspace manager', run: () => global.workspace_manager.disconnectObject(this)},
            {name: 'disconnect from the card', run: () => card?.disconnectObject(this)},
            {name: 'disconnect from the dropdown menu', run: () => dropdownMenu?.disconnectObject(this)},
            {name: 'disconnect from the covering windows', run: () => this._disconnectCoveringWindows()},
            {name: 'remove the covered check\'s client listener', run: () => {
                if (cardCoverListenerId !== null)
                    client?.removeHistoryListener(cardCoverListenerId);
            }},
            {name: 'remove the cockpit client listener', run: () => {
                if (cockpitListenerId !== null)
                    cockpitClient?.removeListener(cockpitListenerId);
            }},
            {name: 'cancel the pending cover check', run: () => this._cancelCardCoverCheck()},
            {name: 'remove the cover fallback timeout', run: () => this._removeCoverFallbackTimer()},
            {name: 'cancel the pending card placement', run: () => this._cancelCardPlacement()},
            {name: 'cancel the display config read', run: () => displayConfigReader?.destroy()},
            // The layer first: the most visible part, it gives the v2 card back as it goes; then the card, since one
            // left behind would show frozen numbers as live.
            {name: 'destroy the cockpit layer', run: () => layer?.destroy()},
            {name: 'destroy the card', run: () => card?.destroy()},
            {name: 'destroy the indicator', run: () => indicator?.destroy()},
            {name: 'destroy the cockpit client', run: () => cockpitClient?.destroy()},
            {name: 'destroy the client', run: () => client?.destroy()},
        ], (stepName, error) => this._logTearDownFailure(stepName, error));
    }

    /**
     * Logs a teardown step that threw, rate-limited.
     *
     * @param {string} stepName - What the step does, for example 'destroy the card'.
     * @param {*} error - What it threw.
     * @returns {void}
     */
    _logTearDownFailure(stepName, error) {
        const errorText = describeErrorWithStack(error);
        this._errorLog.log(`teardown could not ${stepName}: ${errorText}`);
    }
}
