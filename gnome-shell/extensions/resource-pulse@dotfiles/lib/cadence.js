import {
    APP_SCAN_INTERVAL_SECONDS, APP_SCAN_UNWATCHED_INTERVAL_SECONDS, BURST_COOLDOWN_TICKS, BURST_CPU_RISE_POINTS,
    REVEAL_SCAN_COOLDOWN_TICKS, SAMPLE_INTERVAL_SECONDS,
} from './constants.js';
import {pressureBand} from './pressure.js';

const WATCHED_INTERVAL_TICKS = APP_SCAN_INTERVAL_SECONDS / SAMPLE_INTERVAL_SECONDS;
const UNWATCHED_INTERVAL_TICKS = APP_SCAN_UNWATCHED_INTERVAL_SECONDS / SAMPLE_INTERVAL_SECONDS;
/** Scan reasons after which the next tick scans again, to sharpen the CPU ranking. */
const WARM_UP_ARMING_REASONS = ['first', 'watch-start', 'burst'];
/** Scan reasons that start the watch-start and burst cooldowns. */
const TRIGGERED_REASONS = ['watch-start', 'burst'];

/**
 * Maps a pressure percentage to its band index (the same bands the meters draw).
 *
 * @param {number|null} avg10Percent - Stall percentage, or null when unavailable.
 * @returns {0|1|2|3|null} Band index, or null for no data.
 */
export function pressureBandIndex(avg10Percent) {
    return pressureBand(avg10Percent);
}

/**
 * Whether a scan of this reason arms a warm-up scan for the next tick.
 *
 * @param {string|null} reason - The reason the scan ran.
 * @returns {boolean} True for first, watch-start and burst; false for interval and warm-up scans.
 */
export function armsWarmUp(reason) {
    return WARM_UP_ARMING_REASONS.includes(reason);
}

/**
 * Whether a scan of this reason counts toward the watch-start and burst cooldowns.
 *
 * @param {string|null} reason - The reason the scan ran.
 * @returns {boolean} True for watch-start and burst.
 */
export function isTriggeredScan(reason) {
    return TRIGGERED_REASONS.includes(reason);
}

/**
 * Whether a cooldown measured in ticks since the last triggered scan has run out.
 *
 * @param {number|null} ticksSinceTriggeredScan - Ticks since the last triggered scan, null for never.
 * @param {number} cooldownTicks - The cooldown's length.
 * @returns {boolean} True when no triggered scan is recent enough to hold the cooldown.
 */
function hasCooledDown(ticksSinceTriggeredScan, cooldownTicks) {
    return ticksSinceTriggeredScan === null || ticksSinceTriggeredScan >= cooldownTicks;
}

/**
 * Whether CPU busy rose by the burst threshold since the last scan. No data on either side never bursts.
 *
 * @param {object} state - The decideAppScan state.
 * @returns {boolean} True for a CPU burst.
 */
function hasCpuBurst(state) {
    const {cpuBusyPercentNow: now, cpuBusyPercentAtLastScan: atLastScan} = state;
    if (now === null || atLastScan === null)
        return false;
    return now - atLastScan >= BURST_CPU_RISE_POINTS;
}

/**
 * Whether any pressure meter's band rose since the last scan. A band with no data on either side never bursts.
 *
 * @param {object} state - The decideAppScan state.
 * @returns {boolean} True for a pressure burst.
 */
function hasPressureBurst(state) {
    return state.pressureBandsNow.some((bandNow, index) => {
        const bandAtLastScan = state.pressureBandsAtLastScan[index];
        if (bandNow === null || bandAtLastScan === null || bandAtLastScan === undefined)
            return false;
        return bandNow > bandAtLastScan;
    });
}

/**
 * Decides whether the app scan runs now. Pure: the caller keeps the counters and applies armsWarmUp and
 * isTriggeredScan to the reason of each scan it runs. Precedence: first, watch-start, warm-up, burst, interval.
 *
 * @param {object} state - What the decision reads.
 * @param {boolean} state.isWatched - Whether a detail watch is held.
 * @param {boolean} state.watchStartedThisTick - Whether a watch started since the last decision.
 * @param {number|null} state.ticksSinceLastScan - Ticks since any scan, null for never.
 * @param {boolean} state.warmUpPending - Whether the last scan armed a warm-up not yet run.
 * @param {number|null} state.ticksSinceTriggeredScan - Ticks since a watch-start or burst scan, null for never.
 * @param {number|null} state.cpuBusyPercentNow - CPU busy now, null for no data.
 * @param {number|null} state.cpuBusyPercentAtLastScan - CPU busy at the last scan, null for no data.
 * @param {Array<number|null>} state.pressureBandsNow - Cpu, memory and io pressure bands now.
 * @param {Array<number|null>} state.pressureBandsAtLastScan - The same bands at the last scan.
 * @returns {{shouldScan: boolean, reason: 'first'|'interval'|'burst'|'watch-start'|'warm-up'|null}} The decision.
 */
export function decideAppScan(state) {
    const scan = reason => ({shouldScan: true, reason});
    if (state.ticksSinceLastScan === null)
        return scan('first');
    if (state.watchStartedThisTick && hasCooledDown(state.ticksSinceTriggeredScan, REVEAL_SCAN_COOLDOWN_TICKS))
        return scan('watch-start');
    if (state.warmUpPending)
        return scan('warm-up');
    const burstAllowed = state.isWatched && hasCooledDown(state.ticksSinceTriggeredScan, BURST_COOLDOWN_TICKS);
    if (burstAllowed && (hasCpuBurst(state) || hasPressureBurst(state)))
        return scan('burst');
    const intervalTicks = state.isWatched ? WATCHED_INTERVAL_TICKS : UNWATCHED_INTERVAL_TICKS;
    if (state.ticksSinceLastScan >= intervalTicks)
        return scan('interval');
    return {shouldScan: false, reason: null};
}
