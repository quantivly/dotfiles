// Resource Pulse: live CPU and memory in the top bar and on a desktop card. The numbers come from the sampler service
// (service/, the systemd user unit resource-pulse.service, outside the shell) through one PulseClient, which follows it
// on the session bus; this file only draws. The card sits in the layout manager's background group (above the
// wallpaper, below every window), at the top right of the primary monitor's work area, and follows that work area as
// monitors and panels change. Only the card shows apps, so the client asks the service for its detail watch (the faster
// app scan) only while the card can be seen (lib/wiring.js isDetailWatchWanted): the overview hides it, and so does a
// window covering it, which is most of the day. While one does, the card is frozen as well: it is dimmed, is told no
// snapshot while the watch is released (the client tells the cards only while it is wanted) and repaints nothing until
// the reveal, which repaints it at once and wants the watch again, so the client gives it the latest snapshot
// (lib/visibility.js decides what covers it), except once every FROZEN_REPAINT_INTERVAL_SECONDS, still dimmed, from the
// latest snapshot, so a card misjudged as covered never shows stale numbers as live. The cover is checked on the
// window-manager and display signals, and, while the card is covered, on the moves, resizes, closing and workspace
// changes of the windows that cover it (so a window moved from the keyboard, or sent to another workspace, is seen);
// those come in bursts, so they are coalesced into one check before the next frame. The Samples that append to the
// histories check it at once, with no later of their own: every one while the card is visible, every
// COVER_BACKSTOP_TICKS-th while it is covered (a backstop for what no signal reports), and each one while it is
// covered asks whether the frozen repaint is due. Nothing here runs on a timer while Samples flow. Only with the card
// covered and the service silent (the client's stall watchdog has published no data, so no Sample comes) does a
// COVER_FALLBACK_INTERVAL_SECONDS timeout check the cover and make the frozen repaint, and the next Sample removes it.
// The shell's budgets are per state: docs/GNOME_CONFIGURATION_GUIDE.md, "What it costs".
//
// This runs inside gnome-shell, the Wayland compositor, so a mistake here destabilises the whole desktop. Without
// the unlock-dialog session mode the shell disables the extension whenever that mode is pushed and enables it
// when it pops. In GNOME 50 that is every lock AND every idle blank: a blank goes through ScreenShield.activate(),
// which pushes unlock-dialog even with locking off. The service keeps sampling meanwhile, so the histories survive:
// the next enable's client reads them back with GetState. enable() and disable() still run many times a day and
// must leave nothing behind:
// - enable() builds everything synchronously and returns. GNOME 50's extension manager awaits enable() and calls
//   disable() only on an extension it has marked ACTIVE (extensionSystem.js _callExtensionEnable and
//   _callExtensionDisable), so an await inside enable() would let a lock that lands during it go unanswered and
//   leave the indicator on the lock screen.
// - the client's D-Bus work (StartUnit, GetState, the Samples) is asynchronous and runs after enable() returns; a
//   failure there shows "no data" and is retried or logged by the client, never thrown.
// - a synchronous failure tears down whatever was built and rethrows, so the shell logs it once and reports the
//   extension as ERROR (which `gnome-extensions info` shows).
// - disable() works at any point, and twice in a row. It disconnects every signal (the covered check's and the
//   covering windows' too), removes its client listener, its pending check and the fallback timeout before destroying
//   anything, so no handler runs against a half-destroyed card.
// - each teardown step runs under its own guard (lib/teardown.js), card first: a step that throws is logged and
//   the rest still run, so one failure can neither leave a frozen card drawn as live nor mask the error enable()
//   is already rethrowing, and the fields are cleared first, so a later enable() starts clean.
// - the client's destroy() releases its detail watch and cancels its calls, so a disable never leaves the service
//   scanning for a card nobody can see.
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {PulseCard} from './card.js';
import {PulseIndicator} from './indicator.js';
import {PulseClient} from './pulseClient.js';
import {COVER_FALLBACK_INTERVAL_SECONDS} from './lib/constants.js';
import {RateLimitedLogger, describeErrorWithStack} from './lib/errorLog.js';
import {runEveryStep} from './lib/teardown.js';
import {
    CoverFallbackTimerChange, canWindowCoverCard, coverFallbackTimerChange, coveringWindowChanges, doRectsOverlap,
    indexesOfRectsCoveringCard, isCardCovered, isCoverBackstopDue, isFrozenRepaintDue,
} from './lib/visibility.js';
import {isDetailWatchWanted} from './lib/wiring.js';

/** The panel box the indicator goes in. */
const PANEL_BOX = 'right';
/** Where the indicator goes when the system menu cannot be found. */
const FALLBACK_PANEL_INDEX = 0;
/** The desktop card counts as visible until the first covered check, which runs as soon as it is placed. */
const IS_CARD_VISIBLE_BEFORE_COVER_CHECK = true;
/**
 * The window types that can cover the card: ordinary windows and dialogs. Never ding's desktop window, which spans the
 * whole screen, a dock or a popup.
 */
const COVERING_WINDOW_TYPES = new Set([Meta.WindowType.NORMAL, Meta.WindowType.DIALOG]);

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

export default class ResourcePulseExtension extends Extension {
    /**
     * @param {object} metadata - The extension's metadata, from the shell.
     */
    constructor(metadata) {
        super(metadata);
        this._client = null;
        this._indicator = null;
        this._card = null;
        this._cardPlacementLaterId = null;
        this._cardCoverListenerId = null;
        this._cardCoverCheckLaterId = null;
        this._coverFallbackSourceId = null;
        // The windows that covered the card at the last check, each followed (_followCoveringWindows).
        this._coveringWindows = new Set();
        // History notifications since the cover was last checked, for the backstop (lib/visibility.js
        // isCoverBackstopDue).
        this._ticksSinceCoverCheck = 0;
        // Monotonic µs of the frozen card's last paint: the freeze's own, then each frozen repaint's.
        this._frozenCardPaintedAtUsec = null;
        this._isOverviewVisible = false;
        this._isCardVisible = IS_CARD_VISIBLE_BEFORE_COVER_CHECK;
        this._dropdownMenu = null;
        this._isDropdownOpen = false;
        // Both limiters are kept across enable() and disable(), so a failure that repeats on every enable (every
        // unlock and blank) is still logged at most once per 10 minutes. The extension's own failures (a teardown
        // step that threw) leave it broken: errors. The client's (StartUnit refused, a call timed out, a payload it
        // could not read) heal by themselves: warnings.
        const nowUsec = () => GLib.get_monotonic_time();
        this._errorLog = new RateLimitedLogger({nowUsec, write: line => console.error(line)});
        this._clientLog = new RateLimitedLogger({nowUsec, write: line => console.warn(line)});
        // Kept across enable() and disable() as well, the same way: 'HH:MM' of the last snapshot with data, saved from
        // each client as teardown destroys it and seeded into the next. A client lives for one enable, so without it
        // the surfaces would say a bare "no data" after an unlock with the service down, rather than "no data since".
        this._lastGoodClockLabel = null;
    }

    /**
     * Creates the client, holding a detail watch only while the card can be seen; puts the indicator just left of the
     * system menu; puts the card on the desktop, keeps it placed and freezes it while a window covers it; then starts
     * the client, which asks systemd for the service and follows it on the bus, all after enable() returns.
     *
     * @returns {void}
     * @throws {Error} Whatever a synchronous step threw, after tearing down everything built so far.
     */
    enable() {
        // GNOME never enables twice without disabling in between; if it ever did, replace rather than duplicate.
        this._tearDown();
        try {
            this._client = new PulseClient({errorLog: this._clientLog, lastGoodClockLabel: this._lastGoodClockLabel});
            this._followOverviewWithDetailWatch();
            this._indicator = new PulseIndicator(this._client);
            Main.panel.addToStatusArea(this.uuid, this._indicator, systemMenuPanelIndex(), PANEL_BOX);
            this._followDropdown();
            this._addCard();
            this._followCardCover();
            this._client.start();
        } catch (error) {
            this._tearDown();
            throw error;
        }
    }

    /**
     * Disconnects every signal, then destroys the card, the indicator and the client, each step guarded. Safe at any
     * point, and twice.
     *
     * @returns {void}
     */
    disable() {
        this._tearDown();
    }

    /**
     * Releases the client's detail watch while the overview is showing. The watch makes the service scan apps at the
     * watched cadence, which feeds only the card's "heaviest" line, and the overview hides the card (it hides the
     * window group the card lives in). 'showing' comes as the overview starts to open and 'hidden' once it has fully
     * closed, so the watch is released for the whole time the card cannot be seen; enabled while the overview is
     * already open (or closing), the client starts without one.
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
     * it wants the detail watch while open. Disconnected in _tearDown.
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
     * Records whether the dropdown is open, and updates the detail watch.
     *
     * @param {boolean} isOpen - True once the menu is open, false once it is closed.
     * @returns {void}
     */
    _onDropdownOpenStateChanged(isOpen) {
        this._isDropdownOpen = isOpen;
        this._syncDetailWatch();
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
     * Records whether the overview is showing, and updates the detail watch.
     *
     * @param {boolean} isOverviewVisible - True while the overview is showing or opening.
     * @returns {void}
     */
    _onOverviewVisibilityChanged(isOverviewVisible) {
        this._isOverviewVisible = isOverviewVisible;
        this._syncDetailWatch();
    }

    /**
     * Tells the client whether a detail watch is wanted (lib/wiring.js isDetailWatchWanted), from whether the card is
     * covered, whether the overview is showing and whether the dropdown is open, if there is a client. The client sends only a change.
     *
     * @returns {void}
     */
    _syncDetailWatch() {
        const isWanted = isDetailWatchWanted({
            isCardVisible: this._isCardVisible,
            isDropdownOpen: this._isDropdownOpen,
            isOverviewVisible: this._isOverviewVisible,
        });
        this._client?.setDetailWatchWanted(isWanted);
    }

    /**
     * Creates the card, adds it to the background group (above the wallpaper, below every window; a new wallpaper
     * actor goes to the bottom of that group, so the card stays above it), and keeps it at the top right of the
     * primary monitor's work area: again whenever the monitors change, a work area changes (a panel or dock
     * strut), or the card's own width changes (that one just before the next frame: see _queueCardPlacement).
     *
     * @returns {void}
     */
    _addCard() {
        this._card = new PulseCard(this._client);
        Main.layoutManager._backgroundGroup.add_child(this._card);
        Main.layoutManager.connectObject('monitors-changed', () => this._placeCard(), this);
        global.display.connectObject('workareas-changed', () => this._placeCard(), this);
        this._card.connectObject('notify::width', () => this._queueCardPlacement(), this);
        this._placeCard();
    }

    /**
     * Moves the card to the primary monitor's work area, if there is a card, and checks whether a window covers it
     * there.
     *
     * @returns {void}
     */
    _placeCard() {
        this._card?.placeOnPrimaryMonitor();
        this._syncCardCover();
    }

    /**
     * Keeps the card frozen, and the detail watch released, while a window covers it (_syncCardCover).
     * - The window-manager and display signals come in bursts (a restack can come several times in one frame), so each
     *   queues one coalesced check before the next frame (_queueCardCoverCheck): every restack (a window raised,
     *   opened or closed), the primary monitor entering or leaving fullscreen, a minimize, an unminimize, a maximize,
     *   unmaximize or tile (size-changed), the end of a drag (grab-op-end), a workspace switch, and "show desktop"
     *   (Super+D) being toggled, which hides windows without minimizing them.
     * - While the card is covered, each window that covers it is followed too: a move or a resize of it (even from the
     *   keyboard, which no other signal reports) or its being sent to another workspace queues the same check, and its
     *   closing drops it and queues the check (_followCoveringWindows).
     * - Every history update (a Sample that appends to the histories, about every 2 s, a state, or no data) is a tick
     *   (_onCardCoverTick, a client history listener). While the card is visible each tick checks at once, with no
     *   later: it comes at most once a tick, and a later would schedule a frame each time. While it is covered only
     *   every COVER_BACKSTOP_TICKS-th tick checks, as a backstop, and every tick asks whether the frozen repaint is
     *   due. With the service silent no tick comes, so the fallback timeout checks instead (_syncCoverFallbackTimer).
     * - The card's placement (_placeCard, which already checked once in _addCard) and the overview closing
     *   (_onOverviewHidden) check at once too.
     *
     * @returns {void}
     */
    _followCardCover() {
        const queueCardCoverCheck = () => this._queueCardCoverCheck();
        global.display.connectObject(
            'restacked', queueCardCoverCheck,
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
     * while the card is visible, every COVER_BACKSTOP_TICKS-th while it is covered), which also starts or removes the
     * fallback timeout, or else only starts or removes it, as the service's liveness says, so it is asked once a tick;
     * then, whether or not it checked, repaints a covered card once its frozen repaint is due, so the repaint keeps to
     * FROZEN_REPAINT_INTERVAL_SECONDS rather than to the backstop. No later, so a tick schedules no frame of its own.
     * The client logs a listener that throws.
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
        this._repaintFrozenCardIfDue();
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
     * Freezes the card while a window covers it and unfreezes it, repainting it at once, when none does, and stamps the
     * freeze's paint, which the frozen repaint counts from; restarts the backstop's count; starts or removes the
     * fallback timeout; updates the detail watch, wanted only while the card can be seen; and only then follows the
     * windows that cover it, so a failure connecting or disconnecting one can never skip the freeze, the reveal, or the
     * detail watch a revealed card needs to be told its snapshots. Does nothing without a card.
     *
     * @returns {void}
     */
    _syncCardCover() {
        if (this._card === null)
            return;
        const {isCovered, coveringWindows} = this._readCardCover();
        this._ticksSinceCoverCheck = 0;
        if (isCovered && this._isCardVisible)
            this._frozenCardPaintedAtUsec = GLib.get_monotonic_time();
        this._card.setFrozen(isCovered);
        this._isCardVisible = !isCovered;
        this._syncCoverFallbackTimer();
        this._syncDetailWatch();
        this._followCoveringWindows(coveringWindows);
    }

    /**
     * Starts the fallback timeout, which checks a covered card every COVER_FALLBACK_INTERVAL_SECONDS while the service
     * is silent, or removes it once the card is revealed or the service is live again (lib/visibility.js
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
     * The fallback timeout: checks the cover at once, with no later, then repaints a card still covered once its frozen
     * repaint is due (_repaintFrozenCardIfDue). A reveal removes this very source from inside it
     * (_syncCoverFallbackTimer), which GLib allows; the value returned after that is ignored, and the id is already
     * forgotten, so nothing removes the source again. It never throws out of the callback, which would end the source
     * behind the id the extension keeps; a failure is logged, rate-limited.
     *
     * @returns {boolean} GLib.SOURCE_CONTINUE, always.
     */
    _onCoverFallbackTimeout() {
        try {
            this._syncCardCover();
            this._repaintFrozenCardIfDue();
        } catch (error) {
            const errorText = describeErrorWithStack(error);
            this._errorLog.log(`could not check the cover: ${errorText}`);
        }
        return GLib.SOURCE_CONTINUE;
    }

    /**
     * While the card is still covered, gives it the client's latest snapshot and repaints it, dimmed, once
     * FROZEN_REPAINT_INTERVAL_SECONDS have passed since it was last painted (lib/visibility.js isFrozenRepaintDue), so
     * a card misjudged as covered updates, dimmed, rather than showing stale numbers. Asked on every tick and by the
     * fallback timeout. The snapshot is given here because the client tells a covered card none while the detail watch
     * is released (unless the dropdown is open). A revealed card is left alone: the reveal repainted it at once. Does
     * nothing without a card.
     *
     * @returns {void}
     */
    _repaintFrozenCardIfDue() {
        if (this._card === null || this._isCardVisible)
            return;
        const nowUsec = GLib.get_monotonic_time();
        if (!isFrozenRepaintDue({lastFrozenPaintAtUsec: this._frozenCardPaintedAtUsec, nowUsec}))
            return;
        this._frozenCardPaintedAtUsec = nowUsec;
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
     * Reads the card's cover: whether it is covered (lib/visibility.js isCardCovered: the primary monitor is
     * fullscreen, or one window that can cover it contains its whole rectangle), and the windows that contain it
     * (indexesOfRectsCoveringCard), which _followCoveringWindows follows. With no monitor at all it counts as visible,
     * with no covering window.
     *
     * @returns {{isCovered: boolean, coveringWindows: Meta.Window[]}} The cover.
     */
    _readCardCover() {
        const {primaryMonitor} = Main.layoutManager;
        if (!primaryMonitor)
            return {isCovered: false, coveringWindows: []};
        const cardRect = this._cardRectOnStage();
        const {metaWindows, frameRects: windowRects} = this._windowsThatCanCoverCard(primaryMonitor);
        const isPrimaryMonitorInFullscreen = primaryMonitor.inFullscreen;
        const coveringIndexes = indexesOfRectsCoveringCard({cardRect, windowRects});
        return {
            isCovered: isCardCovered({isPrimaryMonitorInFullscreen, cardRect, windowRects}),
            coveringWindows: coveringIndexes.map(windowIndex => metaWindows[windowIndex]),
        };
    }

    /**
     * Follows exactly the windows that cover the card now: connects to those it does not follow yet and disconnects
     * from those that stopped covering it (lib/visibility.js coveringWindowChanges), so a check that finds the same
     * windows connects and disconnects nothing.
     *
     * @param {Meta.Window[]} coveringWindows - The windows that contain the card now.
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
     * Follows a window that covers the card: its move and its resize (from a drag, the keyboard or the application),
     * and its being sent to another workspace (which no global signal reports when the user does not follow it), queue
     * the coalesced cover check, and its closing drops it at once (_onCoveringWindowUnmanaged).
     *
     * @param {Meta.Window} metaWindow - A window that contains the card.
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
     * checked again before the next frame (the card may now be visible).
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
     * The card's rectangle in stage coordinates, read now: the card moves on monitor and work-area changes. It is
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
     * The windows that can cover the card, with their frame rectangles: those whose state allows it (lib/visibility.js
     * canWindowCoverCard: normal and dialog windows, not minimized, showing on their workspace, on the active
     * workspace or on all of them), and whose frame overlaps the primary monitor. The state is checked first, so only
     * those windows' frames are read. Frame rects are in stage (logical) coordinates, as the card's rectangle is.
     *
     * @param {{x: number, y: number, width: number, height: number}} primaryMonitor - The primary monitor's geometry.
     * @returns {{metaWindows: Meta.Window[], frameRects: Array<{x: number, y: number, width: number, height: number}>}}
     *     The windows, and each one's frame rectangle at the same index.
     */
    _windowsThatCanCoverCard(primaryMonitor) {
        const activeWorkspace = global.workspace_manager.get_active_workspace();
        const metaWindows = [];
        const frameRects = [];
        for (const metaWindow of global.display.list_all_windows()) {
            const canCover = canWindowCoverCard({
                isNormalOrDialog: COVERING_WINDOW_TYPES.has(metaWindow.get_window_type()),
                isMinimized: metaWindow.minimized,
                isShowing: metaWindow.showing_on_its_workspace(),
                isOnActiveWorkspace: metaWindow.is_on_all_workspaces() ||
                    metaWindow.get_workspace() === activeWorkspace,
            });
            if (!canCover)
                continue;
            const frameRect = metaWindow.get_frame_rect();
            if (doRectsOverlap(frameRect, primaryMonitor)) {
                metaWindows.push(metaWindow);
                frameRects.push(frameRect);
            }
        }
        return {metaWindows, frameRects};
    }

    /**
     * Moves the card before the next frame. Its notify::width comes during allocation, and moving an actor then
     * leaves it needing an allocation, which Clutter warns about; a BEFORE_REDRAW later moves it before the next
     * frame instead, as the shell's own layout.js does. Several calls before then queue one.
     *
     * @returns {void}
     */
    _queueCardPlacement() {
        if (this._cardPlacementLaterId !== null)
            return;
        this._cardPlacementLaterId = global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
            this._cardPlacementLaterId = null;
            this._placeCard();
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
     * Undoes enable(), whatever it got to, and never throws: keeps the client's last good clock label for the next
     * enable (a getter's read, before anything is destroyed, guarded as each step is: on a failure the label already
     * held stays); clears every field; then disconnects from the overview, the layout manager, the display, the window
     * manager, the workspace manager, the card, the dropdown menu and the windows covering the card, removes the
     * covered check's client listener, its pending check and its fallback timeout, and a pending card placement; then
     * destroys the card (which also takes it out of the background group), the indicator and the client. Each step runs
     * under its own guard (lib/teardown.js runEveryStep): one that throws is logged, rate-limited, and the rest still
     * run.
     *
     * @returns {void}
     */
    _tearDown() {
        const card = this._card;
        const indicator = this._indicator;
        const client = this._client;
        const cardCoverListenerId = this._cardCoverListenerId;
        const dropdownMenu = this._dropdownMenu;
        // The getter parses a Sample still unread, so it can throw: the label already held is kept then.
        try {
            this._lastGoodClockLabel = client?.lastGoodClockLabel ?? this._lastGoodClockLabel;
        } catch (error) {
            this._logTearDownFailure('read the client\'s last good clock label', error);
        }
        // Cleared first: whatever a step below throws, no later enable() or disable() finds a half-destroyed part.
        this._card = null;
        this._indicator = null;
        this._client = null;
        this._cardCoverListenerId = null;
        this._dropdownMenu = null;
        this._isDropdownOpen = false;
        this._isOverviewVisible = false;
        this._isCardVisible = IS_CARD_VISIBLE_BEFORE_COVER_CHECK;
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
            {name: 'cancel the pending cover check', run: () => this._cancelCardCoverCheck()},
            {name: 'remove the cover fallback timeout', run: () => this._removeCoverFallbackTimer()},
            {name: 'cancel the pending card placement', run: () => this._cancelCardPlacement()},
            // The card first: it is the most visible part, and one left behind would show frozen numbers as live.
            {name: 'destroy the card', run: () => card?.destroy()},
            {name: 'destroy the indicator', run: () => indicator?.destroy()},
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
