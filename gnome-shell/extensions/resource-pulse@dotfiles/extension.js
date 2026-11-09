// Resource Pulse: live CPU and memory in the top bar and on a desktop card. The numbers come from the sampler service
// (service/, the systemd user unit resource-pulse.service, outside the shell) through one PulseClient, which follows it
// on the session bus; this file only draws. The card sits in the layout manager's background group (above the
// wallpaper, below every window), at the top right of the primary monitor's work area, and follows that work area as
// monitors and panels change. Only the card shows apps, and the overview hides it, so the client asks the service for
// its detail watch (the faster app scan) only while the overview is hidden (lib/wiring.js isDetailWatchWanted).
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
// - disable() works at any point, and twice in a row. It disconnects every signal before destroying anything, so no
//   handler runs against a half-destroyed card.
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
import {RateLimitedLogger, describeErrorWithStack} from './lib/errorLog.js';
import {runEveryStep} from './lib/teardown.js';
import {isDetailWatchWanted} from './lib/wiring.js';

/** The panel box the indicator goes in. */
const PANEL_BOX = 'right';
/** Where the indicator goes when the system menu cannot be found. */
const FALLBACK_PANEL_INDEX = 0;
/** The desktop card counts as visible (outside the overview) until a window covering it is tracked. */
const IS_CARD_VISIBLE_UNTIL_COVER_TRACKED = true;
/** The dropdown counts as closed until the indicator has one. */
const IS_DROPDOWN_OPEN_UNTIL_DROPDOWN_EXISTS = false;

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
        // Both limiters are kept across enable() and disable(), so a failure that repeats on every enable (every
        // unlock and blank) is still logged at most once per 10 minutes. The extension's own failures (a teardown
        // step that threw) leave it broken: errors. The client's (StartUnit refused, a call timed out, a payload it
        // could not read) heal by themselves: warnings.
        const nowUsec = () => GLib.get_monotonic_time();
        this._errorLog = new RateLimitedLogger({nowUsec, write: line => console.error(line)});
        this._clientLog = new RateLimitedLogger({nowUsec, write: line => console.warn(line)});
    }

    /**
     * Creates the client, holding a detail watch only while the overview is hidden; puts the indicator just left of
     * the system menu; puts the card on the desktop and keeps it placed; then starts the client, which asks systemd
     * for the service and follows it on the bus, all after enable() returns.
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
            this._addCard();
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
     * Holds the client's detail watch only while the overview is hidden. The watch makes the service scan apps at the
     * watched cadence, which feeds only the card's "heaviest" line, and the overview hides the card (it hides the
     * window group the card lives in). 'showing' comes as the overview starts to open and 'hidden' once it has fully
     * closed, so the watch is released for the whole time the card cannot be seen; enabled while the overview is
     * already open (or closing), the client starts without one.
     *
     * @returns {void}
     */
    _followOverviewWithDetailWatch() {
        Main.overview.connectObject(
            'showing', () => this._syncDetailWatch(true),
            'hidden', () => this._syncDetailWatch(false),
            this);
        this._syncDetailWatch(Main.overview.visible);
    }

    /**
     * Tells the client whether a detail watch is wanted (lib/wiring.js isDetailWatchWanted), if there is a client.
     *
     * @param {boolean} isOverviewVisible - True while the overview is showing or opening.
     * @returns {void}
     */
    _syncDetailWatch(isOverviewVisible) {
        const isWanted = isDetailWatchWanted({
            isCardVisible: IS_CARD_VISIBLE_UNTIL_COVER_TRACKED,
            isDropdownOpen: IS_DROPDOWN_OPEN_UNTIL_DROPDOWN_EXISTS,
            isOverviewVisible,
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
     * Moves the card to the primary monitor's work area, if there is a card.
     *
     * @returns {void}
     */
    _placeCard() {
        this._card?.placeOnPrimaryMonitor();
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
     * the layout manager, the display and the card, and removes a pending card placement; then destroys the card
     * (which also takes it out of the background group), the indicator and the client. Each step runs under its own
     * guard (lib/teardown.js runEveryStep): one that throws is logged, rate-limited, and the rest still run.
     *
     * @returns {void}
     */
    _tearDown() {
        const card = this._card;
        const indicator = this._indicator;
        const client = this._client;
        // Cleared first: whatever a step below throws, no later enable() or disable() finds a half-destroyed part.
        this._card = null;
        this._indicator = null;
        this._client = null;
        runEveryStep([
            {name: 'disconnect from the overview', run: () => Main.overview.disconnectObject(this)},
            {name: 'disconnect from the layout manager', run: () => Main.layoutManager.disconnectObject(this)},
            {name: 'disconnect from the display', run: () => global.display.disconnectObject(this)},
            {name: 'disconnect from the card', run: () => card?.disconnectObject(this)},
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
