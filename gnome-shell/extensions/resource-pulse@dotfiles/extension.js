// Resource Pulse: live CPU and memory in the top bar and on a desktop card, from one Sampler. The card sits in the
// layout manager's background group (above the wallpaper, below every window), at the top right of the primary
// monitor's work area, and follows that work area as monitors and panels change. Only the card shows apps, and the
// overview hides it, so the sampler's app scan runs only while the overview is hidden.
//
// This runs inside gnome-shell, the Wayland compositor, so a mistake here destabilises the whole desktop. Without
// the unlock-dialog session mode the shell disables the extension whenever that mode is pushed and enables it
// when it pops. In GNOME 50 that is every lock AND every idle blank: a blank goes through ScreenShield.activate(),
// which pushes unlock-dialog even with locking off. So the histories restart after every blank and every lock
// (by the user's decision they are not kept), and enable() and disable() run many times a day and must leave
// nothing behind:
// - enable() builds everything synchronously and returns. GNOME 50's extension manager awaits enable() and calls
//   disable() only on an extension it has marked ACTIVE (extensionSystem.js _callExtensionEnable and
//   _callExtensionDisable), so an await inside enable() would let a lock that lands during it go unanswered and
//   leave the indicator on the lock screen.
// - the one asynchronous step, the sampler's initialize(), runs after enable() returns, and the timer starts only
//   if that same enable is still current when it settles.
// - a synchronous failure tears down whatever was built and rethrows, so the shell logs it once and reports the
//   extension as ERROR (which `gnome-extensions info` shows); an asynchronous one is logged once with the
//   journal prefix and tears down the same way.
// - disable() works at any point, whether or not the asynchronous start has finished, and twice in a row. It
//   disconnects every signal before destroying anything, so no handler runs against a half-destroyed card.
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {PulseCard} from './card.js';
import {PulseIndicator} from './indicator.js';
import {LOG_PREFIX} from './lib/constants.js';
import {Sampler} from './sampler.js';

/** The panel box the indicator goes in. */
const PANEL_BOX = 'right';
/** Where the indicator goes when the system menu cannot be found. */
const FALLBACK_PANEL_INDEX = 0;
const START_FAILURE_MESSAGE = `${LOG_PREFIX} sampling could not start, so the indicator was removed:`;

/**
 * Looks up the real name of an installed app, for naming app cgroups.
 *
 * @param {string} desktopId - A desktop file id, such as 'org.chromium.Chromium.desktop'.
 * @returns {string|null} The app's name, or null when no such app is installed.
 */
function lookUpAppName(desktopId) {
    return Shell.AppSystem.get_default().lookup_app(desktopId)?.get_name() ?? null;
}

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
        // A fresh object per enable(); null while disabled. An asynchronous step compares the one it started with,
        // so a step left over from an earlier enable() changes nothing.
        this._enableToken = null;
        this._sampler = null;
        this._indicator = null;
        this._card = null;
    }

    /**
     * Creates the sampler, scanning apps only while the overview is hidden; puts the indicator just left of the
     * system menu; puts the card on the desktop and keeps it placed; keeps sampling paused while the screen shield
     * is still up (an enable as a blank or a lock ends comes just before the shield goes down); then starts
     * sampling once the sampler has initialized.
     *
     * @returns {void}
     * @throws {Error} Whatever a synchronous step threw, after tearing down everything built so far.
     */
    enable() {
        // GNOME never enables twice without disabling in between; if it ever did, replace rather than duplicate.
        this._tearDown();
        const enableToken = {};
        this._enableToken = enableToken;
        try {
            this._sampler = new Sampler({resolveAppName: lookUpAppName});
            this._followOverviewWithAppScan();
            this._indicator = new PulseIndicator(this._sampler);
            Main.panel.addToStatusArea(this.uuid, this._indicator, systemMenuPanelIndex(), PANEL_BOX);
            this._addCard();
            Main.screenShield?.connectObject('active-changed', () => this._syncPauseWithScreenShield(), this);
            this._syncPauseWithScreenShield();
        } catch (error) {
            this._tearDown();
            throw error;
        }
        this._startSampling(enableToken).catch(error => this._onStartFailed(enableToken, error));
    }

    /**
     * Disconnects every signal, then destroys the sampler, the indicator and the card. Safe at any point: before
     * the asynchronous start has finished, after a failed start, or twice.
     *
     * @returns {void}
     */
    disable() {
        this._tearDown();
    }

    /**
     * Runs the sampler's app scan only while the overview is hidden. The scan feeds only the card's "heaviest"
     * line, and the overview hides the card (it hides the window group the card lives in). 'showing' comes as the
     * overview starts to open and 'hidden' once it has fully closed, so the scan is off for the whole time the
     * card cannot be seen; enabled while the overview is already open (or closing), the scan starts off.
     *
     * @returns {void}
     */
    _followOverviewWithAppScan() {
        Main.overview.connectObject(
            'showing', () => this._sampler?.setAppScanEnabled(false),
            'hidden', () => this._sampler?.setAppScanEnabled(true),
            this);
        this._sampler.setAppScanEnabled(!Main.overview.visible);
    }

    /**
     * Creates the card, adds it to the background group (above the wallpaper, below every window; a new wallpaper
     * actor goes to the bottom of that group, so the card stays above it), and keeps it at the top right of the
     * primary monitor's work area: again whenever the monitors change, a work area changes (a panel or dock
     * strut), or the card's own width changes.
     *
     * @returns {void}
     */
    _addCard() {
        this._card = new PulseCard(this._sampler);
        Main.layoutManager._backgroundGroup.add_child(this._card);
        Main.layoutManager.connectObject('monitors-changed', () => this._placeCard(), this);
        global.display.connectObject('workareas-changed', () => this._placeCard(), this);
        this._card.connectObject('notify::width', () => this._placeCard(), this);
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
     * Waits for the sampler to read what does not change, then starts its timer, unless this enable() was undone
     * (or replaced) meanwhile.
     *
     * @param {object} enableToken - The token of the enable() that started this.
     * @returns {Promise<void>} Settles once started, or once found to be stale.
     */
    async _startSampling(enableToken) {
        const sampler = this._sampler;
        await sampler.initialize();
        if (this._enableToken !== enableToken)
            return;
        sampler.start();
    }

    /**
     * Logs a failed asynchronous start once and, if that enable() is still current, removes everything it built.
     *
     * @param {object} enableToken - The token of the enable() whose start failed.
     * @param {*} error - What the start threw.
     * @returns {void}
     */
    _onStartFailed(enableToken, error) {
        console.error(START_FAILURE_MESSAGE, error);
        if (this._enableToken === enableToken)
            this._tearDown();
    }

    /**
     * Pauses sampling while the screen shield is up and resumes it once the shield is down.
     *
     * The shield being up rarely reaches a live extension: in GNOME 50 every blank and every lock pushes the
     * unlock-dialog session mode, which disables this extension outright before the shield reports active. What
     * this bridges is the end of one: the mode pops, and this extension is enabled again, about 250 ms before the
     * shield's 'active-changed' says it is down (measured in the nested shell), so the new sampler starts paused
     * and resumes on that signal. It is also the defence should the shield ever be up while the extension runs.
     *
     * @returns {void}
     */
    _syncPauseWithScreenShield() {
        const isDisplayOff = Main.screenShield?.active ?? false;
        this._sampler?.setPaused(isDisplayOff);
    }

    /**
     * Undoes enable(), whatever it got to: marks no enable() as current; disconnects from the screen shield, the
     * overview, the layout manager, the display and the card; destroys the sampler, the indicator and the card
     * (which also takes the card out of the background group); and clears every field.
     *
     * @returns {void}
     */
    _tearDown() {
        this._enableToken = null;
        Main.screenShield?.disconnectObject(this);
        Main.overview.disconnectObject(this);
        Main.layoutManager.disconnectObject(this);
        global.display.disconnectObject(this);
        this._card?.disconnectObject(this);
        this._sampler?.destroy();
        this._indicator?.destroy();
        this._card?.destroy();
        this._sampler = null;
        this._indicator = null;
        this._card = null;
    }
}
