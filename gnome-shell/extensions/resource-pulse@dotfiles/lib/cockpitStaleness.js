// When a cockpit source is suspected stale, pulled, and called stale (ruling R14). The service emits Changed only when
// something changed, so the shell decides for itself: a source older than COCKPIT_SOURCE_STALE_INTERVALS of its own
// intervals is suspect; the shell then pulls GetState once per interval; and only a pull that completed without
// refreshing the stamp makes the source stale. Pure: the clock and the pull times come in as microseconds.
import {COCKPIT_FALLBACK_INTERVAL_SECONDS, COCKPIT_SOURCE_STALE_INTERVALS} from './constants.js';

const MICROSECONDS_PER_SECOND = 1e6;

/**
 * The interval a source is judged against.
 *
 * @param {*} intervalSeconds What the source published; null, 0 or a non-number means it published none.
 * @returns {number} intervalSeconds, or COCKPIT_FALLBACK_INTERVAL_SECONDS.
 */
function effectiveIntervalSeconds(intervalSeconds) {
    const isUsable = typeof intervalSeconds === 'number' && Number.isFinite(intervalSeconds) && intervalSeconds > 0;
    return isUsable ? intervalSeconds : COCKPIT_FALLBACK_INTERVAL_SECONDS;
}

/**
 * Decide whether a source is fresh, whether to pull its state now, and whether it is stale.
 *
 * @param {object} input
 * @param {number|null} input.sampledAtUsec The source's wall-clock stamp; null if never sampled or absent.
 * @param {number|null} input.intervalSeconds The source's sampling interval; null or 0 uses the fallback.
 * @param {number} input.nowRealUsec The wall clock now.
 * @param {number|null} input.lastPullRequestedAtUsec When the shell last asked for GetState, or null.
 * @param {number|null} input.lastPullCompletedAtUsec When the last GetState reply arrived, or null.
 * @returns {{isStale: boolean, shouldPull: boolean, ageSeconds: number|null}} ageSeconds is unrounded and negative if
 *   the clock stepped back (then the source reads as fresh); null for a source with no stamp, which is stale and
 *   never worth a pull.
 */
export function sourceFreshness({
    sampledAtUsec, intervalSeconds, nowRealUsec, lastPullRequestedAtUsec, lastPullCompletedAtUsec,
}) {
    if (sampledAtUsec === null)
        return {isStale: true, shouldPull: false, ageSeconds: null};
    const interval = effectiveIntervalSeconds(intervalSeconds);
    const ageSeconds = (nowRealUsec - sampledAtUsec) / MICROSECONDS_PER_SECOND;
    const isSuspect = ageSeconds > COCKPIT_SOURCE_STALE_INTERVALS * interval;
    if (!isSuspect)
        return {isStale: false, shouldPull: false, ageSeconds};
    const secondsSinceLastPullRequest = lastPullRequestedAtUsec === null
        ? null
        : (nowRealUsec - lastPullRequestedAtUsec) / MICROSECONDS_PER_SECOND;
    const shouldPull = secondsSinceLastPullRequest === null || secondsSinceLastPullRequest > interval;
    const isStale = lastPullCompletedAtUsec !== null && lastPullCompletedAtUsec > sampledAtUsec;
    return {isStale, shouldPull, ageSeconds};
}

/**
 * The line a stale card draws in place of its numbers.
 *
 * @param {number|null} sampledAtUsec The source's last stamp, or null if it never sampled.
 * @param {function(number): string} formatClock Turns a wall-clock microsecond stamp into 'HH:MM'.
 * @returns {string} 'no data since HH:MM', or 'no data' without a stamp.
 */
export function noDataSinceLabel(sampledAtUsec, formatClock) {
    if (sampledAtUsec === null)
        return 'no data';
    return `no data since ${formatClock(sampledAtUsec)}`;
}
