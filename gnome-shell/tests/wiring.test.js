// lib/wiring.js: the pure decisions behind the extension's client: when to hold a detail watch, when the data a state
// carries (the service's latest sample) is too old to draw as live, and how long to wait before asking systemd to start
// the service again.
import {test, assertEqual} from './harness.js';
// Read through the namespace, so a missing export fails its row rather than the whole run.
import * as wiringModule from '../extensions/resource-pulse@dotfiles/lib/wiring.js';

const USEC_PER_SECOND = 1_000_000;
/** SAMPLE_STALL_TICKS (3) × SAMPLE_INTERVAL_SECONDS (2), in microseconds: the design's 6 s, written out. */
const STALL_USEC = 6 * USEC_PER_SECOND;
const LAST_FRESH_DATA_AT_USEC = 50_000_000;
const ONE_MICROSECOND = 1;

test('wiring: a detail watch is wanted while the card is visible outside the overview, or the dropdown is open', () => {
    const wantedByCombination = [];
    for (const isCardVisible of [false, true]) {
        for (const isDropdownOpen of [false, true]) {
            for (const isOverviewVisible of [false, true]) {
                const isWanted = wiringModule.isDetailWatchWanted({isCardVisible, isDropdownOpen, isOverviewVisible});
                wantedByCombination.push(
                    `card=${isCardVisible} dropdown=${isDropdownOpen} overview=${isOverviewVisible}: ${isWanted}`);
            }
        }
    }
    assertEqual(wantedByCombination, [
        'card=false dropdown=false overview=false: false',
        'card=false dropdown=false overview=true: false',
        'card=false dropdown=true overview=false: true',
        'card=false dropdown=true overview=true: true',
        'card=true dropdown=false overview=false: true',
        'card=true dropdown=false overview=true: false',
        'card=true dropdown=true overview=false: true',
        'card=true dropdown=true overview=true: true',
    ]);
});

test('wiring: a Sample exactly 6 s old is not stale, 6 s + 1 µs is, and a client that never had one is', () => {
    const isStaleAt = nowUsec =>
        wiringModule.isSampleStale({lastFreshDataAtUsec: LAST_FRESH_DATA_AT_USEC, nowUsec});
    assertEqual({
        exactlyStall: isStaleAt(LAST_FRESH_DATA_AT_USEC + STALL_USEC),
        justPastStall: isStaleAt(LAST_FRESH_DATA_AT_USEC + STALL_USEC + ONE_MICROSECOND),
        neverReceived: wiringModule.isSampleStale({lastFreshDataAtUsec: null, nowUsec: STALL_USEC}),
    }, {exactlyStall: false, justPastStall: true, neverReceived: true});
});

test('wiring: StartUnit retries wait 5, 30, 300, then 300 s after each failed attempt', () => {
    const failedAttemptNumbers = [1, 2, 3, 4, 10];
    assertEqual(failedAttemptNumbers.map(attemptNumber => wiringModule.nextStartRetryDelaySeconds(attemptNumber)),
        [5, 30, 300, 300, 300]);
});
