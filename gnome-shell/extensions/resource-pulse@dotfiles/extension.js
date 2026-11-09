// Resource Pulse: live CPU and memory in the top bar and on a desktop card. The numbers come from the sampler service
// (service/, the systemd user unit resource-pulse.service, outside the shell) through one PulseClient, which follows it
// on the session bus; this file only draws. The card sits in the layout manager's background group (above the
// wallpaper, below every window), at the top right of the primary monitor's work area, and follows that work area as
// monitors and panels change. Only the card shows apps, so the client asks the service for its detail watch (the faster
// app scan) only while the card can be seen (lib/wiring.js isDetailWatchWanted): the overview hides it, and so does a
// window covering it, which is most of the day. While one does, the card is frozen as well: it records each snapshot
// and repaints nothing until the reveal, which repaints it at once (lib/visibility.js decides what covers it). The
// window-manager and display signals that trigger that check come in bursts, so they are coalesced into one check
// before the next frame; every Sample checks at once, and so, while the card is frozen, does a timer, since no Sample
// may come (the service may be down). Neither of those schedules a frame: the shell's budget is under 0.1% of a core.
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
// - disable() works at any point, and twice in a row. It disconnects every signal (the covered check's too) and removes
//   its client listener before destroying anything, so no handler runs against a half-destroyed card.
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
import {SAMPLE_INTERVAL_SECONDS} from './lib/constants.js';
import {RateLimitedLogger, describeErrorWithStack} from './lib/errorLog.js';
import {runEveryStep} from './lib/teardown.js';
import {
    CoverRecheckTimerChange, canWindowCoverCard, coverRecheckTimerChange, doRectsOverlap, isCardCovered,
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
        this._coverRecheckSourceId = null;
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
            this._client = new PulseClient({errorLog: this._clientLog});
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
     * - Every client update (a Sample, about every 2 s) checks at once, with no later: it comes at most once a tick,
     *   and a later would schedule a frame each time, even under a covered card. It catches what no signal reports,
     *   such as a window moved over the card from the keyboard. While the card is frozen a timer does the same every
     *   SAMPLE_INTERVAL_SECONDS (_syncCoverRecheckTimer), since no Sample comes while the service is down.
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
        this._cardCoverListenerId = this._client.addListener(() => this._syncCardCover());
    }

    /**
     * Checks the cover before the next frame, once however many window-manager and display signals come before then
     * (a restack can come several times in one frame), in a BEFORE_REDRAW later as _queueCardPlacement does.
     *
     * @returns {void}
     */
    _queueCardCoverCheck() {
        if (this._cardCoverCheckLaterId !== null)
            return;
        this._cardCoverCheckLaterId = global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
            this._cardCoverCheckLaterId = null;
            this._syncCardCover();
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
     * Freezes the card while a window covers it and unfreezes it, repainting it at once, when none does; runs the
     * re-check timer exactly while it is covered; then updates the detail watch, wanted only while the card can be
     * seen. Does nothing without a card.
     *
     * @returns {void}
     */
    _syncCardCover() {
        if (this._card === null)
            return;
        const isCovered = this._isCardCovered();
        this._card.setFrozen(isCovered);
        this._isCardVisible = !isCovered;
        this._syncCoverRecheckTimer(isCovered);
        this._syncDetailWatch();
    }

    /**
     * Starts the timer that re-checks a covered card every SAMPLE_INTERVAL_SECONDS, or removes it on the reveal
     * (lib/visibility.js coverRecheckTimerChange).
     *
     * @param {boolean} isCovered - The card is covered now.
     * @returns {void}
     */
    _syncCoverRecheckTimer(isCovered) {
        const timerChange = coverRecheckTimerChange({isCovered, isTimerRunning: this._coverRecheckSourceId !== null});
        if (timerChange === CoverRecheckTimerChange.START) {
            this._coverRecheckSourceId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, SAMPLE_INTERVAL_SECONDS,
                () => this._onCoverRecheckTimeout());
        } else if (timerChange === CoverRecheckTimerChange.STOP) {
            this._removeCoverRecheckTimer();
        }
    }

    /**
     * The re-check timer: checks the cover at once, with no later, so a covered card schedules no frame. A reveal
     * removes this very source from inside it (_syncCoverRecheckTimer), which GLib allows; the value returned after
     * that is ignored. It never throws out of the callback, which would end the source behind the id the extension
     * keeps; a failure is logged, rate-limited.
     *
     * @returns {boolean} GLib.SOURCE_CONTINUE, always.
     */
    _onCoverRecheckTimeout() {
        try {
            this._syncCardCover();
        } catch (error) {
            const errorText = describeErrorWithStack(error);
            this._errorLog.log(`could not check the cover: ${errorText}`);
        }
        return GLib.SOURCE_CONTINUE;
    }

    /**
     * Removes the re-check timer, if it runs.
     *
     * @returns {void}
     */
    _removeCoverRecheckTimer() {
        if (this._coverRecheckSourceId === null)
            return;
        const sourceId = this._coverRecheckSourceId;
        this._coverRecheckSourceId = null;
        GLib.source_remove(sourceId);
    }

    /**
     * Says whether the card is covered (lib/visibility.js isCardCovered): the primary monitor is fullscreen, or one
     * window that can cover it contains its whole rectangle. With no monitor at all it counts as visible.
     *
     * @returns {boolean} True when covered.
     */
    _isCardCovered() {
        const {primaryMonitor} = Main.layoutManager;
        if (!primaryMonitor)
            return false;
        return isCardCovered({
            isPrimaryMonitorInFullscreen: primaryMonitor.inFullscreen,
            cardRect: this._cardRectOnStage(),
            windowRects: this._coveringWindowRects(primaryMonitor),
        });
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
     * The frame rectangles of the windows that can cover the card: those whose state allows it (lib/visibility.js
     * canWindowCoverCard: normal and dialog windows, not minimized, showing on their workspace, on the active
     * workspace or on all of them), and whose frame overlaps the primary monitor. The state is checked first, so only
     * those windows' frames are read. Frame rects are in stage (logical) coordinates, as the card's rectangle is.
     *
     * @param {{x: number, y: number, width: number, height: number}} primaryMonitor - The primary monitor's geometry.
     * @returns {Array<{x: number, y: number, width: number, height: number}>} The rectangles.
     */
    _coveringWindowRects(primaryMonitor) {
        const activeWorkspace = global.workspace_manager.get_active_workspace();
        const coveringWindowRects = [];
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
            if (doRectsOverlap(frameRect, primaryMonitor))
                coveringWindowRects.push(frameRect);
        }
        return coveringWindowRects;
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
     * Undoes enable(), whatever it got to, and never throws: clears every field; then disconnects from the overview,
     * the layout manager, the display, the window manager, the workspace manager, the card and the dropdown menu, removes the covered
     * check's client listener, its pending check and its re-check timer, and a pending card placement; then destroys
     * the card (which also takes it out of the background group), the indicator and the client. Each step runs under
     * its own guard (lib/teardown.js runEveryStep): one that throws is logged, rate-limited, and the rest still run.
     *
     * @returns {void}
     */
    _tearDown() {
        const card = this._card;
        const indicator = this._indicator;
        const client = this._client;
        const cardCoverListenerId = this._cardCoverListenerId;
        const dropdownMenu = this._dropdownMenu;
        // Cleared first: whatever a step below throws, no later enable() or disable() finds a half-destroyed part.
        this._card = null;
        this._indicator = null;
        this._client = null;
        this._cardCoverListenerId = null;
        this._dropdownMenu = null;
        this._isDropdownOpen = false;
        this._isOverviewVisible = false;
        this._isCardVisible = IS_CARD_VISIBLE_BEFORE_COVER_CHECK;
        runEveryStep([
            {name: 'disconnect from the overview', run: () => Main.overview.disconnectObject(this)},
            {name: 'disconnect from the layout manager', run: () => Main.layoutManager.disconnectObject(this)},
            {name: 'disconnect from the display', run: () => global.display.disconnectObject(this)},
            {name: 'disconnect from the window manager', run: () => global.window_manager.disconnectObject(this)},
            {name: 'disconnect from the workspace manager', run: () => global.workspace_manager.disconnectObject(this)},
            {name: 'disconnect from the card', run: () => card?.disconnectObject(this)},
            {name: 'disconnect from the dropdown menu', run: () => dropdownMenu?.disconnectObject(this)},
            {name: 'remove the covered check\'s client listener', run: () => {
                if (cardCoverListenerId !== null)
                    client?.removeListener(cardCoverListenerId);
            }},
            {name: 'cancel the pending cover check', run: () => this._cancelCardCoverCheck()},
            {name: 'remove the cover re-check timer', run: () => this._removeCoverRecheckTimer()},
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
