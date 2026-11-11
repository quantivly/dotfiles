// The cockpit's interaction rules, pure: when the WatchCockpit watch is wanted, whether the desktop may be clicked,
// which window a FocusSession reply activates, and what to do with the reply. The glue (client, layer, click handler)
// reads the shell into the plain inputs below; nothing here imports Gio, GLib or Shell.
import {COCKPIT_LOG_PREFIX} from './constants.js';

/** The type name the glue gives a Meta.WindowType.DESKTOP window (a desktop-icons extension's), for the rule below. */
export const DESKTOP_WINDOW_TYPE = 'desktop';
const FOCUS_LOG_PREFIX = `${COCKPIT_LOG_PREFIX} focus:`;

/**
 * Whether the shell should hold the WatchCockpit watch: while a cockpit card is visible outside the overview, or
 * while the dropdown is open.
 *
 * @param {object} input
 * @param {boolean} input.isAnyCockpitCardVisible Some cockpit card is on screen.
 * @param {boolean} input.isDropdownOpen The panel dropdown is open.
 * @param {boolean} input.isOverviewVisible The overview is showing (it hides the desktop layer).
 * @returns {boolean} True if the watch is wanted.
 */
export function isCockpitWatchWanted({isAnyCockpitCardVisible, isDropdownOpen, isOverviewVisible}) {
    return (isAnyCockpitCardVisible && !isOverviewVisible) || isDropdownOpen;
}

/**
 * Whether the desktop layer takes clicks: not while a DESKTOP-type window (a desktop-icons extension) is showing on
 * the monitor, since that window would receive them instead.
 *
 * @param {object} input
 * @param {Array<{windowType: string, isShowing: boolean}>} input.windowsOnMonitor Windows on the monitor; the glue
 *   maps Meta.WindowType.DESKTOP to 'desktop'.
 * @returns {boolean} False when any showing window is of type 'desktop'.
 */
export function isDesktopInteractive({windowsOnMonitor}) {
    return !windowsOnMonitor.some(window => window.isShowing && window.windowType === DESKTOP_WINDOW_TYPE);
}

/**
 * Pick the window a FocusSession reply should activate: among the windows whose pid is a candidate, one on the
 * active workspace over one elsewhere, then the highest stack index. Minimization does not rank: activating
 * unminimizes.
 *
 * @param {object} input
 * @param {Array<{pid: number, stackIndex: number, isOnActiveWorkspace: boolean, isMinimized: boolean}>} input.windows
 * @param {number[]} input.candidatePids Pids the service named (windowPidCandidates).
 * @returns {number|null} The stackIndex of the window to activate, or null if none matches.
 */
export function pickWindowToActivate({windows, candidatePids}) {
    const matches = windows.filter(window => candidatePids.includes(window.pid));
    if (matches.length === 0)
        return null;
    const best = matches.reduce((leading, window) => {
        if (window.isOnActiveWorkspace !== leading.isOnActiveWorkspace)
            return window.isOnActiveWorkspace ? window : leading;
        return window.stackIndex > leading.stackIndex ? window : leading;
    });
    return best.stackIndex;
}

/**
 * What to do with a FocusSession reply once a window has (or has not) been picked.
 *
 * @param {object} input
 * @param {{focused: boolean, error: string|null, windowPidCandidates: number[]}} input.reply The parsed reply.
 * @param {number|null} input.pickedStackIndex What pickWindowToActivate returned.
 * @returns {{activateWindow: boolean, logLine: string|null}} Activate, or a log line; never both.
 */
export function focusSessionOutcome({reply, pickedStackIndex}) {
    if (!reply.focused) {
        const reason = reply.error ?? 'not focused';
        return {activateWindow: false, logLine: `${FOCUS_LOG_PREFIX} ${reason}`};
    }
    if (typeof pickedStackIndex === 'number')
        return {activateWindow: true, logLine: null};
    const candidateList = `[${(reply.windowPidCandidates ?? []).join(', ')}]`;
    return {activateWindow: false, logLine: `${FOCUS_LOG_PREFIX} no window for pids ${candidateList}`};
}
