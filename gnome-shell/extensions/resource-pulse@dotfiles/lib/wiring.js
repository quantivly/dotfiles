// The pure decisions behind the extension's client (pulseClient.js): when to hold a detail watch on the service, when
// the data a state carries (the service's latest sample) is too old to draw as live, and how long to wait before asking
// systemd to start the service again.
// Pure: no Gio and no Shell import, so it runs under plain gjs.
import {SAMPLE_INTERVAL_SECONDS, SAMPLE_STALL_TICKS, START_RETRY_DELAYS_SECONDS} from './constants.js';

const USEC_PER_SECOND = 1_000_000;
/** How old a Sample may be and still be drawn as live: SAMPLE_STALL_TICKS whole intervals, 6 s. */
const SAMPLE_STALL_USEC = SAMPLE_STALL_TICKS * SAMPLE_INTERVAL_SECONDS * USEC_PER_SECOND;
/** The number of the first StartUnit attempt; the delay after it is the first of START_RETRY_DELAYS_SECONDS. */
const FIRST_START_ATTEMPT_NUMBER = 1;

/**
 * Says whether the client should hold a detail watch, which makes the service scan apps at the watched cadence: while
 * the desktop card can be seen (it is visible, and the overview, which hides it, is not), or while the dropdown is
 * open, whose card the overview does not hide.
 *
 * @param {object} surfaces - What can be seen now.
 * @param {boolean} surfaces.isCardVisible - The desktop card is not covered by a window.
 * @param {boolean} surfaces.isDropdownOpen - The top-bar dropdown, holding its own card, is open.
 * @param {boolean} surfaces.isOverviewVisible - The overview is showing (or opening), which hides the desktop card.
 * @returns {boolean} True when a watch is wanted.
 */
export function isDetailWatchWanted({isCardVisible, isDropdownOpen, isOverviewVisible}) {
    const isDesktopCardSeen = isCardVisible && !isOverviewVisible;
    return Boolean(isDesktopCardSeen || isDropdownOpen);
}

/**
 * Says whether the service's latest sample, as a state's snapshot carries it, is too old to draw as live: taken more
 * than SAMPLE_STALL_TICKS intervals (6 s) ago. Exactly that old is not stale yet.
 *
 * @param {object} times - Monotonic times, in microseconds.
 * @param {number|null} times.lastFreshDataAtUsec - When the client's data was last fresh: the time of the sample the
 *     latest state's snapshot was taken from; null when it never had any, which counts as stale.
 * @param {number} times.nowUsec - Now.
 * @returns {boolean} True when stale.
 */
export function isSampleStale({lastFreshDataAtUsec, nowUsec}) {
    if (lastFreshDataAtUsec === null)
        return true;
    return nowUsec - lastFreshDataAtUsec > SAMPLE_STALL_USEC;
}

/**
 * How long to wait after a failed StartUnit before the next attempt: START_RETRY_DELAYS_SECONDS in order, the last one
 * repeating, so the retries back off to one every 5 minutes and never stop while systemd refuses.
 *
 * @param {number} attemptNumber - The number of the attempt that failed, from 1. Anything that is not a whole number
 *     of at least 1 counts as the first.
 * @returns {number} Seconds to wait.
 */
export function nextStartRetryDelaySeconds(attemptNumber) {
    const isCountable = Number.isSafeInteger(attemptNumber) && attemptNumber >= FIRST_START_ATTEMPT_NUMBER;
    const failedAttemptsBefore = isCountable ? attemptNumber - FIRST_START_ATTEMPT_NUMBER : 0;
    const lastDelayIndex = START_RETRY_DELAYS_SECONDS.length - 1;
    return START_RETRY_DELAYS_SECONDS[Math.min(failedAttemptsBefore, lastDelayIndex)];
}
