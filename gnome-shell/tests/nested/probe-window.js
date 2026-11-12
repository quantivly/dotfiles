// The window scripts/resource-pulse-nested.sh `window <title>` opens in a nested run: a small Gtk 4 window with that
// title, a Wayland client of the nested shell only (`gjs -m probe-window.js <title>`, with the run's environment, the
// run's WAYLAND_DISPLAY and GDK_BACKEND=wayland). It runs until closed or signalled.
//
// It refuses (exit 2) before Gtk is even loaded unless it runs inside a nested run's own environment:
// RESOURCE_PULSE_NESTED_DIR names the run, XDG_RUNTIME_DIR is exactly <run>/run (the guard the unsafe-mode helper
// uses, nestedRun.js), and WAYLAND_DISPLAY is the nested shell's, a socket in that runtime dir. Started any other way
// it would open on the live desktop. A title is a plain name: letters, digits, '.', '_', '-'.
import GLib from 'gi://GLib';
import System from 'system';

import {isNestedRunRuntimeDir} from './resource-pulse-nested-unsafe-mode@local/nestedRun.js';

const EXIT_REFUSED = 2;
const NESTED_WAYLAND_DISPLAY = 'rp-nested-0';
const WINDOW_TITLE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const WINDOW_WIDTH_PX = 320;
const WINDOW_HEIGHT_PX = 200;

/**
 * Prints why it refuses, and exits 2.
 *
 * @param {string} reason - Why.
 * @returns {never} It exits.
 */
function refuse(reason) {
    printerr(`probe-window: refusing: ${reason}`);
    System.exit(EXIT_REFUSED);
}

/**
 * @returns {string|null} Why this process is not in a nested run's own environment, or null when it is.
 */
function outsideNestedRunReason() {
    const nestedRunDir = GLib.getenv('RESOURCE_PULSE_NESTED_DIR');
    const runtimeDir = GLib.getenv('XDG_RUNTIME_DIR') ?? '';
    if (!isNestedRunRuntimeDir(nestedRunDir, runtimeDir))
        return `XDG_RUNTIME_DIR '${runtimeDir}' is not a nested run's (RESOURCE_PULSE_NESTED_DIR '${nestedRunDir}')`;
    if (GLib.getenv('WAYLAND_DISPLAY') !== NESTED_WAYLAND_DISPLAY)
        return `WAYLAND_DISPLAY is not the nested shell's ${NESTED_WAYLAND_DISPLAY}`;
    return null;
}

const [windowTitle, ...extraArguments] = System.programArgs;
if (windowTitle === undefined || extraArguments.length > 0 || !WINDOW_TITLE_PATTERN.test(windowTitle))
    refuse('usage: probe-window.js <title>, a title of letters, digits, . _ -');
const outsideReason = outsideNestedRunReason();
if (outsideReason !== null)
    refuse(outsideReason);

// Loaded only now, once the run is confirmed: nothing before this line can reach a display.
const {default: Gtk} = await import('gi://Gtk?version=4.0');
Gtk.init();
const mainLoop = new GLib.MainLoop(null, false);
const probeWindow = new Gtk.Window({
    title: windowTitle, default_width: WINDOW_WIDTH_PX, default_height: WINDOW_HEIGHT_PX,
});
probeWindow.connect('close-request', () => {
    mainLoop.quit();
    return false;
});
probeWindow.present();
mainLoop.run();
