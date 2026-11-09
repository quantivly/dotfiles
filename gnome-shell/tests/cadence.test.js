import {test, assertEqual} from './harness.js';
import {
    decideAppScan, armsWarmUp, isTriggeredScan, pressureBandIndex,
} from '../extensions/resource-pulse@dotfiles/lib/cadence.js';
import {
    APP_SCAN_INTERVAL_SECONDS, APP_SCAN_UNWATCHED_INTERVAL_SECONDS, BURST_COOLDOWN_TICKS,
    REVEAL_SCAN_COOLDOWN_TICKS, SAMPLE_INTERVAL_SECONDS,
} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

const WATCHED_INTERVAL_TICKS = 10;
const UNWATCHED_INTERVAL_TICKS = 30;
const CALM_BANDS = [0, 0, 0];
const SETTLED_TICKS = 5;

/**
 * A state in which nothing is due: watched, mid-interval, steady load, settled cooldowns.
 *
 * @param {object} overrides - Fields to replace.
 * @returns {object} The state for decideAppScan.
 */
const quietState = (overrides = {}) => ({
    isWatched: true, watchStartedThisTick: false, ticksSinceLastScan: 3, warmUpPending: false,
    ticksSinceTriggeredScan: SETTLED_TICKS, cpuBusyPercentNow: 40, cpuBusyPercentAtLastScan: 40,
    pressureBandsNow: CALM_BANDS, pressureBandsAtLastScan: CALM_BANDS, ...overrides,
});

/**
 * The reason decideAppScan gives for a state.
 *
 * @param {object} overrides - Fields to replace in the quiet state.
 * @returns {string|null} The scan reason, or null for no scan.
 */
const reasonFor = overrides => decideAppScan(quietState(overrides)).reason;

test('cadence: the intervals are derived from the seconds constants', () =>
    assertEqual([
        APP_SCAN_INTERVAL_SECONDS / SAMPLE_INTERVAL_SECONDS,
        APP_SCAN_UNWATCHED_INTERVAL_SECONDS / SAMPLE_INTERVAL_SECONDS,
    ], [WATCHED_INTERVAL_TICKS, UNWATCHED_INTERVAL_TICKS]));

test('cadence: a quiet state does not scan', () =>
    assertEqual(decideAppScan(quietState()), {shouldScan: false, reason: null}));

test('cadence: with no scan yet, scan with reason first', () =>
    assertEqual(decideAppScan(quietState({ticksSinceLastScan: null})), {shouldScan: true, reason: 'first'}));

test('cadence: first beats watch-start', () =>
    assertEqual(reasonFor({ticksSinceLastScan: null, watchStartedThisTick: true}), 'first'));

test('cadence: watched interval scans at 10 ticks', () =>
    assertEqual(reasonFor({ticksSinceLastScan: WATCHED_INTERVAL_TICKS}), 'interval'));

test('cadence: watched interval does not scan at 9 ticks', () =>
    assertEqual(reasonFor({ticksSinceLastScan: WATCHED_INTERVAL_TICKS - 1}), null));

test('cadence: unwatched interval scans at 30 ticks', () =>
    assertEqual(reasonFor({isWatched: false, ticksSinceLastScan: UNWATCHED_INTERVAL_TICKS}), 'interval'));

test('cadence: unwatched interval does not scan at 29 ticks', () =>
    assertEqual(reasonFor({isWatched: false, ticksSinceLastScan: UNWATCHED_INTERVAL_TICKS - 1}), null));

test('cadence: unwatched does not scan at the watched interval', () =>
    assertEqual(reasonFor({isWatched: false, ticksSinceLastScan: WATCHED_INTERVAL_TICKS}), null));

test('cadence: a watch starting scans at once', () =>
    assertEqual(reasonFor({watchStartedThisTick: true}), 'watch-start'));

test('cadence: a watch starting with no triggered scan yet scans', () =>
    assertEqual(reasonFor({watchStartedThisTick: true, ticksSinceTriggeredScan: null}), 'watch-start'));

test('cadence: a watch starting inside the reveal cooldown does not scan', () =>
    assertEqual(
        reasonFor({watchStartedThisTick: true, ticksSinceTriggeredScan: REVEAL_SCAN_COOLDOWN_TICKS - 1}), null));

test('cadence: a watch starting at the end of the reveal cooldown scans', () =>
    assertEqual(
        reasonFor({watchStartedThisTick: true, ticksSinceTriggeredScan: REVEAL_SCAN_COOLDOWN_TICKS}),
        'watch-start'));

test('cadence: a pending warm-up scans with reason warm-up', () =>
    assertEqual(reasonFor({warmUpPending: true}), 'warm-up'));

test('cadence: a pending warm-up scans when unwatched too', () =>
    assertEqual(reasonFor({warmUpPending: true, isWatched: false}), 'warm-up'));

test('cadence: watch-start beats warm-up', () =>
    assertEqual(reasonFor({watchStartedThisTick: true, warmUpPending: true}), 'watch-start'));

test('cadence: warm-up beats burst', () =>
    assertEqual(reasonFor({warmUpPending: true, cpuBusyPercentNow: 90}), 'warm-up'));

test('cadence: burst beats interval', () =>
    assertEqual(reasonFor({ticksSinceLastScan: WATCHED_INTERVAL_TICKS, cpuBusyPercentNow: 90}), 'burst'));

test('cadence: CPU 40 to 55 bursts when watched', () =>
    assertEqual(reasonFor({cpuBusyPercentAtLastScan: 40, cpuBusyPercentNow: 55}), 'burst'));

test('cadence: CPU 40 to 54 does not burst', () =>
    assertEqual(reasonFor({cpuBusyPercentAtLastScan: 40, cpuBusyPercentNow: 54}), null));

test('cadence: unwatched never bursts on CPU', () =>
    assertEqual(reasonFor({isWatched: false, cpuBusyPercentAtLastScan: 0, cpuBusyPercentNow: 100}), null));

test('cadence: a null CPU value now never bursts', () =>
    assertEqual(reasonFor({cpuBusyPercentNow: null}), null));

test('cadence: a null CPU value at the last scan never bursts', () =>
    assertEqual(reasonFor({cpuBusyPercentAtLastScan: null, cpuBusyPercentNow: 100}), null));

test('cadence: a pressure band rising 1 to 2 bursts', () =>
    assertEqual(reasonFor({pressureBandsAtLastScan: [0, 1, 0], pressureBandsNow: [0, 2, 0]}), 'burst'));

test('cadence: a pressure band falling does not burst', () =>
    assertEqual(reasonFor({pressureBandsAtLastScan: [0, 2, 0], pressureBandsNow: [0, 1, 0]}), null));

test('cadence: a pressure band staying does not burst', () =>
    assertEqual(reasonFor({pressureBandsAtLastScan: [1, 1, 1], pressureBandsNow: [1, 1, 1]}), null));

test('cadence: a null pressure band now never bursts', () =>
    assertEqual(reasonFor({pressureBandsAtLastScan: [0, 0, 0], pressureBandsNow: [null, 0, 0]}), null));

test('cadence: a null pressure band at the last scan never bursts', () =>
    assertEqual(reasonFor({pressureBandsAtLastScan: [null, 0, 0], pressureBandsNow: [3, 0, 0]}), null));

test('cadence: unwatched never bursts on pressure', () =>
    assertEqual(reasonFor({isWatched: false, pressureBandsAtLastScan: [0, 0, 0], pressureBandsNow: [0, 0, 3]}), null));

test('cadence: no burst inside the burst cooldown', () =>
    assertEqual(reasonFor({cpuBusyPercentNow: 90, ticksSinceTriggeredScan: BURST_COOLDOWN_TICKS - 1}), null));

test('cadence: a burst is allowed at the end of the burst cooldown', () =>
    assertEqual(reasonFor({cpuBusyPercentNow: 90, ticksSinceTriggeredScan: BURST_COOLDOWN_TICKS}), 'burst'));

test('cadence: a burst is allowed with no triggered scan yet', () =>
    assertEqual(reasonFor({cpuBusyPercentNow: 90, ticksSinceTriggeredScan: null}), 'burst'));

test('cadence: armsWarmUp is true for first, watch-start and burst only', () =>
    assertEqual(
        ['first', 'watch-start', 'burst', 'interval', 'warm-up', null].map(armsWarmUp),
        [true, true, true, false, false, false]));

test('cadence: isTriggeredScan is true for watch-start and burst only', () =>
    assertEqual(
        ['first', 'watch-start', 'burst', 'interval', 'warm-up', null].map(isTriggeredScan),
        [false, true, true, false, false, false]));

test('cadence: pressureBandIndex follows the band thresholds and passes no data through', () =>
    assertEqual([0, 9.9, 10, 24.9, 25, 49.9, 50, 100, null].map(pressureBandIndex),
        [0, 0, 1, 1, 2, 2, 3, 3, null]));
