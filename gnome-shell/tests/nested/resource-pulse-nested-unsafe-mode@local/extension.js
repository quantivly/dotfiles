// For scripts/resource-pulse-nested.sh only, never a real session: turns on unsafe mode in the NESTED shell, so
// org.gnome.Shell.Eval and Screenshot answer on its private bus. The script copies it into the run directory's own
// data dir; it is not under gnome-shell/extensions/, so ./install never links it anywhere.
//
// It refuses (the shell then marks it ERROR, and unsafe mode stays off) unless this shell runs inside a run
// directory of that script: RESOURCE_PULSE_NESTED_DIR is set and holds the shell's runtime directory. Its
// session-modes keep it enabled on the lock screen, because the harness blanks the nested shell and still needs
// Eval while it is blanked.
import GLib from 'gi://GLib';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

/** Set by scripts/resource-pulse-nested.sh to the run directory, in the nested shell's environment only. */
const NESTED_RUN_DIR_VARIABLE = 'RESOURCE_PULSE_NESTED_DIR';

/**
 * Says whether this shell runs inside a run directory of scripts/resource-pulse-nested.sh: the run directory is
 * named in the environment and the shell's runtime directory is inside it.
 *
 * @returns {boolean} True only in the nested shell that script started.
 */
function isInsideNestedRun() {
    const nestedRunDir = GLib.getenv(NESTED_RUN_DIR_VARIABLE);
    if (!nestedRunDir)
        return false;
    return GLib.get_user_runtime_dir().startsWith(`${nestedRunDir}/`);
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
            throw new Error(`refusing to turn on unsafe mode: ${NESTED_RUN_DIR_VARIABLE} does not hold this shell's runtime directory`);
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
