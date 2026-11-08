// For scripts/resource-pulse-nested.sh only, never a real session: turns on unsafe mode in the NESTED shell, so
// org.gnome.Shell.Eval and Screenshot answer on its private bus. The script copies it into the run directory's own
// data dir; it is not under gnome-shell/extensions/, so ./install never links it anywhere.
//
// It refuses (the shell then marks it ERROR, and unsafe mode stays off) unless this shell runs inside a run
// directory of that script: RESOURCE_PULSE_NESTED_DIR is set and the shell's runtime directory is exactly
// <run dir>/run (nestedRun.js, which the suite tests). Its
// session-modes keep it enabled on the lock screen, because the harness blanks the nested shell and still needs
// Eval while it is blanked.
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import {isNestedRunRuntimeDir} from './nestedRun.js';

/** Set by scripts/resource-pulse-nested.sh to the run directory, in the nested shell's environment only. */
const NESTED_RUN_DIR_VARIABLE = 'RESOURCE_PULSE_NESTED_DIR';

/**
 * Says whether this shell runs inside a run directory of scripts/resource-pulse-nested.sh.
 *
 * @returns {boolean} True only in the nested shell that script started.
 */
function isInsideNestedRun() {
    return isNestedRunRuntimeDir(GLib.getenv(NESTED_RUN_DIR_VARIABLE), GLib.get_user_runtime_dir());
}

export default class NestedUnsafeModeHelper extends Extension {
    /**
     * Turns on unsafe mode, inside a nested run only.
     *
     * @returns {void}
     * @throws {Error} Outside a nested run, before changing anything.
     */
    enable() {
        if (!isInsideNestedRun())
            throw new Error(`refusing to turn on unsafe mode: this shell's runtime directory is not ${NESTED_RUN_DIR_VARIABLE}/run`);
        global.context.unsafe_mode = true;
    }

    /**
     * Turns unsafe mode off again.
     *
     * @returns {void}
     */
    disable() {
        global.context.unsafe_mode = false;
    }
}
