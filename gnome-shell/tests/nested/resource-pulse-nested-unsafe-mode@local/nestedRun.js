// The unsafe-mode helper's guard, with no Shell import, so the suite's plain-gjs rows can run it.

/** Where scripts/resource-pulse-nested.sh puts a run's XDG_RUNTIME_DIR, relative to the run directory. */
const NESTED_RUNTIME_DIR_NAME = 'run';

/**
 * Says whether a shell runs inside a run directory of scripts/resource-pulse-nested.sh: its runtime directory is
 * exactly the one the script gives a run, <run dir>/run. A prefix match is not enough: any directory under the
 * run would pass it.
 *
 * @param {string|null} nestedRunDir - RESOURCE_PULSE_NESTED_DIR from the shell's environment, or null.
 * @param {string} runtimeDir - The shell's runtime directory (GLib.get_user_runtime_dir()).
 * @returns {boolean} True only in the nested shell that script started.
 */
export function isNestedRunRuntimeDir(nestedRunDir, runtimeDir) {
    if (!nestedRunDir)
        return false;
    return runtimeDir === `${nestedRunDir}/${NESTED_RUNTIME_DIR_NAME}`;
}
