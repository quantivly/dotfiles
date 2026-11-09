import {test, assertEqual} from './harness.js';
import {unescapeSystemdName, describeCgroup, displayNameFor, rankApps}
    from '../extensions/resource-pulse@dotfiles/lib/apps.js';

const GIB = 1024 ** 3;
const ELAPSED_USEC = 2_000_000;
const CPU_COUNT = 8;

test('Chromium scope → app org.chromium.Chromium', () =>
    assertEqual(describeCgroup('app-org.chromium.Chromium-50164.scope').appId, 'org.chromium.Chromium'));
test('gnome launcher with an escaped id', () =>
    assertEqual(describeCgroup('app-gnome-aws\\x2dvpn\\x2dclient-59401.scope').appId, 'aws-vpn-client'));
test('snap scope → snap name', () =>
    assertEqual(describeCgroup('snap.slack.slack-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope').fallbackName, 'slack'));
test('the launcher is matched before unescaping: an escaped hyphen after "gnome" is part of the app id', () =>
    assertEqual(describeCgroup('app-gnome\\x2dcalculator-1234.scope').appId, 'gnome-calculator'));
test('a GNOME settings daemon is named gsd-<x> in lowercase', () =>
    assertEqual(describeCgroup('org.gnome.SettingsDaemon.Power.service').fallbackName, 'gsd-power'));
test('another reverse-DNS unit drops its first two segments', () =>
    assertEqual(describeCgroup('org.freedesktop.IBus.session.GNOME.service').fallbackName, 'IBus.session.GNOME'));
test('a snap asks the resolver for <snap>_<app>.desktop, and falls back to the snap name', () => {
    const asked = [];
    const description = describeCgroup('snap.slack.slack-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope');
    const resolved = displayNameFor(description, desktopId => { asked.push(desktopId); return 'Slack Desktop'; });
    const fallback = displayNameFor(description, () => null);
    assertEqual([asked, resolved, fallback], [['slack_slack.desktop'], 'Slack Desktop', 'slack']);
});
test('herdr service → "herdr agents"', () => assertEqual(describeCgroup('herdr-server.service').fallbackName, 'herdr agents'));
test('templated unit drops its instance', () =>
    assertEqual(describeCgroup('gnome-session-manager@ubuntu.service').fallbackName, 'gnome-session-manager'));
test('docker scopes group as one "docker"', () =>
    assertEqual(describeCgroup('docker-0123abcd.scope').groupKey, describeCgroup('docker-89ef.scope').groupKey));
test('display name falls back to the capitalised last id segment', () =>
    assertEqual(displayNameFor(describeCgroup('app-org.chromium.Chromium-1.scope'), () => null), 'Chromium'));

test('every \\xNN escape is unescaped, not just the first (and a plain name is untouched)', () =>
    assertEqual([unescapeSystemdName('a\\x2db\\x2dc'), unescapeSystemdName('plain.service')], ['a-b-c', 'plain.service']));
test('a launcherless app id keeps its hyphen; a flatpak launcher is stripped', () =>
    assertEqual([describeCgroup('app-my-tool-12.scope').appId, describeCgroup('app-flatpak-org.mozilla.firefox-9.scope').appId],
        ['my-tool', 'org.mozilla.firefox']));
test('the resolver answer for <appId>.desktop wins over the fallback', () => {
    const asked = [];
    const name = displayNameFor(describeCgroup('app-gnome-alacritty-66279.scope'),
        desktopId => { asked.push(desktopId); return 'Alacritty Terminal'; });
    assertEqual([name, asked], ['Alacritty Terminal', ['alacritty.desktop']]);
});
test('a non-app kind ignores the resolver', () =>
    assertEqual(displayNameFor(describeCgroup('dbus.service'), () => 'WRONG'), 'dbus'));

/**
 * Builds a rankApps input from per-cgroup usage deltas and memory, naming each cgroup after itself.
 *
 * @param {object} spec - cgroups as {path: [previousUsec|null, currentUsec, memoryBytes|null]}, plus overrides.
 * @param {object} [overrides] - fields replacing or adding to the defaults (rootCpuDeltaUsec, nameOfCgroup).
 * @returns {object} The argument for rankApps.
 */
const input = (spec, overrides = {}) => {
    const previousUsageUsec = new Map();
    const currentUsageUsec = new Map();
    const memoryBytesByCgroup = new Map();
    for (const [path, [previous, current, memory]] of Object.entries(spec)) {
        if (previous !== null)
            previousUsageUsec.set(path, previous);
        currentUsageUsec.set(path, current);
        if (memory !== null)
            memoryBytesByCgroup.set(path, memory);
    }
    return {
        previousUsageUsec, currentUsageUsec, memoryBytesByCgroup,
        elapsedUsec: ELAPSED_USEC, cpuCount: CPU_COUNT, rootCpuDeltaUsec: null,
        nameOfCgroup: path => ({groupKey: path.split('#')[0], name: path.split('#')[0]}),
        ...overrides,
    };
};

test('app CPU is a share of the whole machine (top-style would be 400%)', () => {
    const ranking = rankApps(input({'herdr agents': [0, 8_000_000, 1 * GIB]}));
    assertEqual(ranking.topCpu, {groupKey: 'herdr agents', name: 'herdr agents', cpuPercent: 50});
});
test('two scopes of one app are summed', () => {
    // chrome 2M + 2M = 4M beats alpha's 3M; ranking scopes singly would pick alpha.
    const ranking = rankApps(input({
        'chrome#1': [0, 2_000_000, 1], 'chrome#2': [0, 2_000_000, 1], 'alpha': [0, 3_000_000, 1],
    }));
    assertEqual(ranking.topCpu, {groupKey: 'chrome', name: 'chrome', cpuPercent: 25});
});
test('two scopes of one app have their memory summed', () => {
    const ranking = rankApps(input({
        'chrome#1': [0, 0, 3 * GIB], 'chrome#2': [0, 0, 3 * GIB], 'alpha': [0, 0, 5 * GIB],
    }));
    assertEqual(ranking.topMemory, {groupKey: 'chrome', name: 'chrome', memoryBytes: 6 * GIB});
});
test('a cgroup new this scan is left out of CPU but counted in memory', () => {
    // 'fresh' has no previous reading; treating it as 0 would give it 100% CPU.
    const ranking = rankApps(input({'old': [0, 1_000_000, 1 * GIB], 'fresh': [null, 16_000_000, 9 * GIB]}));
    assertEqual([ranking.topCpu.name, ranking.topMemory.name], ['old', 'fresh']);
});
/**
 * Builds the parent inputs rankApps needs for kernel and short jobs.
 *
 * @param {object} spec - {leafPath: parentPath}, the parents each leaf sits under.
 * @param {object} parentDeltas - {parentPath: usage_usec delta}, the parents read in both scans.
 * @param {string[]} [listedPreviously] - parents whose leaves were listed in the previous scan.
 * @returns {object} The three fields to spread into rankApps' input.
 */
const parents = (spec, parentDeltas, listedPreviously = []) => ({
    parentOfLeaf: new Map(Object.entries(spec)),
    parentCpuDeltaUsec: new Map(Object.entries(parentDeltas)),
    parentsListedPreviously: new Set(listedPreviously),
});

test('kernel is the root delta minus the parents\' delta: root 90 ms, one 40 ms parent, 50 ms of machine time', () => {
    // The leaf equals its parent (no short jobs), so kernel's 50 ms of 16 s is the only other candidate.
    const ranking = rankApps(input({'app': [0, 40_000, 1]},
        {rootCpuDeltaUsec: 90_000, ...parents({'app': 'p'}, {'p': 40_000})}));
    assertEqual(ranking.topCpu, {groupKey: 'pseudo:kernel', name: 'kernel', cpuPercent: 50_000 / 16_000_000 * 100});
});
test('kernel tops CPU when the parents are small: root 12 s, parents 1 s', () => {
    const ranking = rankApps(input({'app': [0, 1_000_000, 1]},
        {rootCpuDeltaUsec: 12_000_000, ...parents({'app': 'p'}, {'p': 1_000_000})}));
    assertEqual(ranking.topCpu, {groupKey: 'pseudo:kernel', name: 'kernel', cpuPercent: 68.75});
});
test('kernel is root minus parents, not minus leaves: a leaf total below its parent\'s does not inflate it', () => {
    // Root 12 s, parent 11 s, its leaf 1 s: kernel is 1 s, short jobs 10 s. Root minus leaves would be 11 s.
    const ranking = rankApps(input({'app': [0, 1_000_000, 1]},
        {rootCpuDeltaUsec: 12_000_000, ...parents({'app': 'p'}, {'p': 11_000_000})}));
    assertEqual(ranking.topCpu, {groupKey: 'pseudo:short-jobs', name: 'short jobs', cpuPercent: 62.5});
});
test('a parent missing from the parent deltas: neither kernel nor short jobs is ranked', () => {
    const ranking = rankApps(input({'a': [0, 1_000, 1], 'b': [0, 2_000, 1]},
        {rootCpuDeltaUsec: 12_000_000, ...parents({'a': 'p1', 'b': 'p2'}, {'p1': 9_000_000})}));
    assertEqual(ranking.topCpu.name, 'b');
});
test('empty parent maps: neither kernel nor short jobs is ranked, even with a root delta', () => {
    // Root minus zero parents would name the whole machine as kernel.
    const ranking = rankApps(input({'app': [0, 1_000_000, 1]}, {rootCpuDeltaUsec: 12_000_000}));
    assertEqual(ranking.topCpu, {groupKey: 'app', name: 'app', cpuPercent: 6.25});
});
test('short jobs is a parent\'s delta beyond its leaves\': 300 ms parent, 200 ms of leaves, 100 ms', () => {
    const ranking = rankApps(input({'a': [0, 120_000, 1], 'b': [0, 80_000, 1]},
        {rootCpuDeltaUsec: null, ...parents({'a': 'p', 'b': 'p'}, {'p': 300_000})}));
    assertEqual(ranking.topCpu.name, 'a');
    // Lift short jobs above the leaves to read its size: 100 ms of 16 s.
    const small = rankApps(input({'a': [0, 20_000, 1], 'b': [0, 20_000, 1]},
        {rootCpuDeltaUsec: null, ...parents({'a': 'p', 'b': 'p'}, {'p': 300_000})}));
    assertEqual(small.topCpu, {groupKey: 'pseudo:short-jobs', name: 'short jobs', cpuPercent: 260_000 / 16_000_000 * 100});
});
test('short jobs sums over parents, and a parent whose leaves exceed its delta (read skew) adds 0, never less', () => {
    // p1: 900 − 100 = 800. p2: leaf 300 > delta 100 → 0, not −200 (which would leave 600). 800 ms of 16 s is 5%.
    const ranking = rankApps(input({'a': [0, 100_000, 1], 'b': [0, 300_000, 1]},
        {rootCpuDeltaUsec: null, ...parents({'a': 'p1', 'b': 'p2'}, {'p1': 900_000, 'p2': 100_000})}));
    assertEqual(ranking.topCpu, {groupKey: 'pseudo:short-jobs', name: 'short jobs', cpuPercent: 5});
});
test('a recreated leaf (counter went backwards: prev 9 s, now 3 s) counts 3 s, not 0', () => {
    const ranking = rankApps(input({'reset': [9_000_000, 3_000_000, 1]}));
    assertEqual(ranking.topCpu, {groupKey: 'reset', name: 'reset', cpuPercent: 3_000_000 / 16_000_000 * 100});
});
test('a new leaf counts its full usage when its parent was listed before', () => {
    const ranking = rankApps(input({'fresh': [null, 4_000_000, 1], 'old': [0, 1_000_000, 1]},
        {...parents({'fresh': 'p', 'old': 'p'}, {'p': 5_000_000}, ['p'])}));
    assertEqual([ranking.topCpu.name, ranking.topCpu.cpuPercent], ['fresh', 25]);
});
test('a new leaf is skipped when its parent was not listed before (a failed listing is not a burst)', () => {
    const ranking = rankApps(input({'fresh': [null, 4_000_000, 1], 'old': [0, 1_000_000, 1]},
        {...parents({'fresh': 'p', 'old': 'p'}, {'p': 5_000_000}, [])}));
    // fresh is out; short jobs = 5 s − old's 1 s = 4 s would win if fresh were counted too (then 0).
    assertEqual(ranking.topCpu.name, 'short jobs');
});
test('the memory half is never kernel or short jobs, however much is unattributed', () => {
    const ranking = rankApps(input({'app': [0, 1_000, 2 * GIB]},
        {rootCpuDeltaUsec: 12_000_000, memoryUsedBytes: 10 * GIB, ...parents({'app': 'p'}, {'p': 11_000_000})}));
    assertEqual(ranking.topMemory, {groupKey: 'app', name: 'app', memoryBytes: 2 * GIB});
});
test('a root CPU counter that went backwards gives kernel 0%, never a negative share', () => {
    // The parent has no leaf delta and zero delta: short jobs 0 too, so kernel's clamp decides the only candidate.
    const ranking = rankApps(input({'fresh': [null, 1_000_000, 1]},
        {rootCpuDeltaUsec: -2_000_000, ...parents({'fresh': 'p'}, {'p': 0})}));
    assertEqual(ranking.topCpu, {groupKey: 'pseudo:kernel', name: 'kernel', cpuPercent: 0});
});
test('without a root CPU delta there is no kernel', () => {
    const ranking = rankApps(input({'app': [0, 0, 0]}, {...parents({'app': 'p'}, {'p': 0})}));
    assertEqual([ranking.topCpu.name, ranking.topMemory.name], ['app', 'app']);
});
test('equal values break ties by name ascending, in either insertion order', () => {
    const betaFirst = rankApps(input({'beta': [0, 1_000_000, 5], 'alpha': [0, 1_000_000, 5]}));
    const alphaFirst = rankApps(input({'alpha': [0, 1_000_000, 5], 'beta': [0, 1_000_000, 5]}));
    assertEqual([betaFirst.topCpu.name, betaFirst.topMemory.name, alphaFirst.topCpu.name, alphaFirst.topMemory.name],
        ['alpha', 'alpha', 'alpha', 'alpha']);
});
test('a real app tied with kernel (always ranked last) wins or loses by name, not by being first', () => {
    // root Δ 2M, parent Δ 1M, the leaf equals its parent: the leaf and kernel both have 1M.
    const tie = name => rankApps(input({[name]: [0, 1_000_000, 5]},
        {rootCpuDeltaUsec: 2_000_000, ...parents({[name]: 'p'}, {'p': 1_000_000})}));
    assertEqual([tie('alpha').topCpu.name, tie('zeta').topCpu.name], ['alpha', 'kernel']);
});
test('nothing scanned gives null rankings, not zeros', () =>
    assertEqual(rankApps(input({})), {topCpu: null, topMemory: null}));
test('no cgroup with a delta gives topCpu null while memory still ranks', () => {
    const ranking = rankApps(input({'fresh': [null, 5_000_000, 2 * GIB]}));
    assertEqual(ranking, {topCpu: null, topMemory: {groupKey: 'fresh', name: 'fresh', memoryBytes: 2 * GIB}});
});
