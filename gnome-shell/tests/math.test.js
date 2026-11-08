import {test, assertEqual, assertClose} from './harness.js';
import {cpuBusyFraction, clusterBusyFraction, parseCpuList, buildClusterMap}
    from '../extensions/resource-pulse@dotfiles/lib/cpu.js';
import {memoryUsage, swapSummary} from '../extensions/resource-pulse@dotfiles/lib/memory.js';
import {pressureBand} from '../extensions/resource-pulse@dotfiles/lib/pressure.js';
import {RingBuffer} from '../extensions/resource-pulse@dotfiles/lib/history.js';

const KIB = 1024;

/**
 * Builds a CpuTimes record with the fields these tests care about.
 *
 * @param {number} user - user ticks.
 * @param {number} system - system ticks.
 * @param {number} idle - idle ticks.
 * @param {number} iowait - iowait ticks.
 * @param {number} [guest] - guest ticks (already inside user in the kernel's accounting).
 * @returns {object} CpuTimes.
 */
const times = (user, system, idle, iowait, guest = 0) =>
    ({user, nice: 0, system, idle, iowait, irq: 0, softirq: 0, steal: 0, guest, guestNice: 0});

test('CPU busy excludes guest from the total (counting it gives 64%)', () =>
    assertClose(cpuBusyFraction(times(100, 100, 700, 100, 50), times(200, 150, 800, 100, 80)), 0.6, 1e-9));
test('iowait counts as idle (counting it busy gives 67%)', () =>
    assertClose(cpuBusyFraction(times(0, 0, 0, 0), times(50, 0, 50, 50)), 1 / 3, 1e-9));
test('first sample is no data, not 0', () => assertEqual(cpuBusyFraction(null, times(1, 1, 1, 1)), null));
test('no delta is no data, not NaN', () =>
    assertEqual(cpuBusyFraction(times(1, 1, 1, 1), times(1, 1, 1, 1)), null));

test('a cluster uses only the CPUs present (offline CPUs have no line)', () => {
    const previous = new Map([[0, times(0, 0, 0, 0)], [1, times(0, 0, 0, 0)]]);
    const current = new Map([[0, times(30, 0, 70, 0)], [1, times(10, 0, 90, 0)]]);
    // 40 busy of 200 total; dividing by all four listed CPUs would give 0.1.
    assertClose(clusterBusyFraction(previous, current, [0, 1, 2, 3]), 0.2, 1e-9);
});
test('a cluster sums deltas rather than averaging fractions', () => {
    const previous = new Map([[0, times(0, 0, 0, 0)], [1, times(0, 0, 0, 0)]]);
    const current = new Map([[0, times(10, 0, 0, 0)], [1, times(0, 0, 90, 0)]]);
    // 10 busy of 100 total = 0.1; averaging 1.0 and 0.0 would give 0.5.
    assertClose(clusterBusyFraction(previous, current, [0, 1]), 0.1, 1e-9);
});
test('a cluster with no CPU present is null', () =>
    assertEqual(clusterBusyFraction(new Map(), new Map(), [0, 1]), null));

test('parseCpuList handles ranges and singles', () =>
    assertEqual(parseCpuList('0-3,6,8-9\n'), [0, 1, 2, 3, 6, 8, 9]));
test('parseCpuList of an empty file is empty', () => assertEqual(parseCpuList('\n'), []));

test('cluster map: hybrid PMU wins', () =>
    assertEqual(buildClusterMap({corePmuCpus: [0, 1, 2, 3], atomPmuCpus: [4, 5, 6, 7], capacities: new Map(), cpuCount: 8}),
        {performanceCpus: [0, 1, 2, 3], efficiencyCpus: [4, 5, 6, 7]}));
test('cluster map: capacity fallback keeps 1024 and 1005 together', () =>
    assertEqual(buildClusterMap({corePmuCpus: [], atomPmuCpus: [],
        capacities: new Map([[0, 1024], [1, 1024], [2, 1005], [3, 1005], [4, 676], [5, 676], [6, 676], [7, 676]]), cpuCount: 8}),
        {performanceCpus: [0, 1, 2, 3], efficiencyCpus: [4, 5, 6, 7]}));
test('cluster map: equal capacities give a single cluster (null)', () =>
    assertEqual(buildClusterMap({corePmuCpus: [], atomPmuCpus: [],
        capacities: new Map([[0, 1024], [1, 1024], [2, 1024], [3, 1024]]), cpuCount: 4}), null));
test('cluster map: no PMU and no capacities is null', () =>
    assertEqual(buildClusterMap({corePmuCpus: [], atomPmuCpus: [], capacities: new Map(), cpuCount: 4}), null));

test('memory used = MemTotal - MemAvailable, not MemTotal - MemFree', () =>
    assertEqual(memoryUsage(new Map([['MemTotal', 32000000 * KIB], ['MemFree', 1000000 * KIB],
        ['MemAvailable', 12000000 * KIB]])).usedBytes, 20000000 * KIB));
test('memory without MemAvailable is no data', () =>
    assertEqual(memoryUsage(new Map([['MemTotal', 1], ['MemFree', 1]])), null));
test('swap on disk = swapped - zram stored', () =>
    assertEqual(swapSummary(new Map([['SwapTotal', 24000000 * KIB], ['SwapFree', 22000000 * KIB]]),
        [{storedBytes: 1536000000, ramBytes: 400000000}]).diskBytes, 2048000000 - 1536000000));
test('no zram: all swap is on disk', () =>
    assertEqual(swapSummary(new Map([['SwapTotal', 100 * KIB], ['SwapFree', 40 * KIB]]), []),
        {swappedBytes: 60 * KIB, zramStoredBytes: 0, zramRamBytes: 0, diskBytes: 60 * KIB}));
test('swap disk bytes never go negative', () =>
    assertEqual(swapSummary(new Map([['SwapTotal', 10 * KIB], ['SwapFree', 9 * KIB]]),
        [{storedBytes: 5 * KIB, ramBytes: 2 * KIB}]).diskBytes, 0));

test('PSI bands at the edges', () =>
    assertEqual([9.99, 10, 24.99, 25, 49.99, 50, null].map(pressureBand), [0, 1, 1, 2, 2, 3, null]));

test('ring buffer drops the oldest and keeps null gaps', () => {
    const ring = new RingBuffer(3);
    [1, null, 3, 4].forEach(value => ring.push(value));
    assertEqual(ring.values(), [null, 3, 4]);
});
test('ring buffer lastValues returns the newest, oldest first, and clear empties it', () => {
    const ring = new RingBuffer(5);
    [1, 2, 3].forEach(value => ring.push(value));
    const newestTwo = ring.lastValues(2);
    ring.clear();
    assertEqual([newestTwo, ring.values()], [[2, 3], []]);
});
