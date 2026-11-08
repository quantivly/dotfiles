// Resource Pulse: live CPU and memory in the top bar, from one Sampler. The desktop card joins it in the next
// build step; until then the sampler's app scan stays off, since only the card shows apps.
//
// This runs inside gnome-shell, the Wayland compositor, so a mistake here destabilises the whole desktop. Without
// the unlock-dialog session mode the shell disables the extension on every lock and enables it on unlock, so
// enable() and disable() run many times a day and must leave nothing behind:
// - enable() builds everything synchronously and returns. GNOME 50's extension manager awaits enable() and calls
//   disable() only on an extension it has marked ACTIVE (extensionSystem.js _callExtensionEnable and
//   _callExtensionDisable), so an await inside enable() would let a lock that lands during it go unanswered and
//   leave the indicator on the lock screen.
// - the one asynchronous step, the sampler's initialize(), runs after enable() returns, and the timer starts only
//   if that same enable is still current when it settles.
// - a synchronous failure tears down whatever was built and rethrows, so the shell logs it once and reports the
//   extension as ERROR (which `gnome-extensions info` shows); an asynchronous one is logged once with the
//   journal prefix and tears down the same way.
// - disable() works at any point, whether or not the asynchronous start has finished, and twice in a row.
import Shell from 'gi://Shell';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

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
    }

    /**
     * Creates the sampler and the indicator, puts the indicator just left of the system menu, follows the screen
     * shield to pause while the display is off, then starts sampling once the sampler has initialized.
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
            this._sampler.setAppScanEnabled(false);
            this._indicator = new PulseIndicator(this._sampler);
            Main.panel.addToStatusArea(this.uuid, this._indicator, systemMenuPanelIndex(), PANEL_BOX);
            Main.screenShield?.connectObject('active-changed', () => this._syncPauseWithScreenShield(), this);
            this._syncPauseWithScreenShield();
        } catch (error) {
            this._tearDown();
            throw error;
        }
        this._startSampling(enableToken).catch(error => this._onStartFailed(enableToken, error));
    }

    /**
     * Destroys, in order, the sampler and the indicator, after disconnecting from the screen shield. Safe at any
     * point: before the asynchronous start has finished, after a failed start, or twice.
     *
     * @returns {void}
     */
    disable() {
        this._tearDown();
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
     * Pauses sampling while the screen shield is up (the display is blanked, locked or not) and resumes it after.
     *
     * @returns {void}
     */
    _syncPauseWithScreenShield() {
        const isDisplayOff = Main.screenShield?.active ?? false;
        this._sampler?.setPaused(isDisplayOff);
    }

    /**
     * Undoes enable(), whatever it got to: marks no enable() as current, disconnects from the screen shield,
     * destroys the sampler and then the indicator, and clears every field.
     *
     * @returns {void}
     */
    _tearDown() {
        this._enableToken = null;
        Main.screenShield?.disconnectObject(this);
        this._sampler?.destroy();
        this._indicator?.destroy();
        this._sampler = null;
        this._indicator = null;
    }
}
