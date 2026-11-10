// lib/cockpitStaleness.js: when a cockpit source is suspected, pulled and called stale (ruling R14), and the label a
// stale card draws.
import {test, assertEqual} from './harness.js';
import * as staleness from '../extensions/resource-pulse@dotfiles/lib/cockpitStaleness.js';

const BASE_INPUT = {sampledAtUsec: 0, intervalSeconds: 10, lastPullRequestedAtUsec: null, lastPullCompletedAtUsec: null};

test('cockpitStaleness: fresh, suspicious-but-unpulled, pulled-and-still-old', () => {
    const base = BASE_INPUT;
    assertEqual(staleness.sourceFreshness({...base, nowRealUsec: 20e6}), {isStale: false, shouldPull: false, ageSeconds: 20});
    assertEqual(staleness.sourceFreshness({...base, nowRealUsec: 31e6}), {isStale: false, shouldPull: true, ageSeconds: 31});
    assertEqual(staleness.sourceFreshness({...base, nowRealUsec: 31e6, lastPullRequestedAtUsec: 25e6}), {isStale: false, shouldPull: false, ageSeconds: 31});
    assertEqual(staleness.sourceFreshness({...base, nowRealUsec: 31e6, lastPullRequestedAtUsec: 30.5e6, lastPullCompletedAtUsec: 30.6e6}), {isStale: true, shouldPull: false, ageSeconds: 31});
    assertEqual(staleness.sourceFreshness({...base, sampledAtUsec: null, nowRealUsec: 1}), {isStale: true, shouldPull: false, ageSeconds: null});
});

test('cockpitStaleness: exactly three intervals old is still fresh; a pull older than one interval may be repeated', () => {
    assertEqual(staleness.sourceFreshness({...BASE_INPUT, nowRealUsec: 30e6}).shouldPull, false);
    const repeated = staleness.sourceFreshness({
        ...BASE_INPUT, nowRealUsec: 45e6, lastPullRequestedAtUsec: 31e6, lastPullCompletedAtUsec: 31.1e6,
    });
    assertEqual(repeated, {isStale: true, shouldPull: true, ageSeconds: 45});
});

test('cockpitStaleness: a pull that completed before the stamp does not make a source stale', () => {
    const result = staleness.sourceFreshness({
        ...BASE_INPUT, sampledAtUsec: 5e6, nowRealUsec: 40e6, lastPullRequestedAtUsec: 1e6, lastPullCompletedAtUsec: 2e6,
    });
    assertEqual(result.isStale, false);
});

test('cockpitStaleness: a null, zero or non-number interval counts as 60 seconds', () => {
    for (const intervalSeconds of [null, 0, 'ten']) {
        const input = {...BASE_INPUT, intervalSeconds};
        assertEqual(staleness.sourceFreshness({...input, nowRealUsec: 179e6}).shouldPull, false);
        assertEqual(staleness.sourceFreshness({...input, nowRealUsec: 181e6}).shouldPull, true);
    }
});

test('cockpitStaleness: a clock that stepped back gives a negative age and a fresh source', () => {
    assertEqual(staleness.sourceFreshness({...BASE_INPUT, sampledAtUsec: 50e6, nowRealUsec: 40e6}),
        {isStale: false, shouldPull: false, ageSeconds: -10});
});

test('cockpitStaleness: the no-data label uses the injected clock, and says so when nothing was ever sampled', () => {
    const formatClock = usec => `clock(${usec})`;
    assertEqual(staleness.noDataSinceLabel(7e6, formatClock), 'no data since clock(7000000)');
    assertEqual(staleness.noDataSinceLabel(null, formatClock), 'no data');
});
