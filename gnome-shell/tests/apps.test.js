import {test, assertEqual} from './harness.js';
import {unescapeSystemdName, describeCgroup, displayNameFor, rankApps}
    from '../extensions/resource-pulse@dotfiles/lib/apps.js';

const GIB = 1024 ** 3;
const ELAPSED_USEC = 2_000_000;
const CPU_COUNT = 8;
const KERNEL_AND_OTHER = 'kernel & other';

test('Chromium scope → app org.chromium.Chromium', () =>
    assertEqual(describeCgroup('app-org.chromium.Chromium-50164.scope').appId, 'org.chromium.Chromium'));
test('gnome launcher with an escaped id', () =>
    assertEqual(describeCgroup('app-gnome-aws\\x2dvpn\\x2dclient-59401.scope').appId, 'aws-vpn-client'));
test('snap scope → snap name', () =>
    assertEqual(describeCgroup('snap.slack.slack-6dac35ea-863e-4f4f-a9a2-1c50d93840a1.scope').fallbackName, 'slack'));
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
    assertEqual(ranking.topCpu, {name: 'herdr agents', cpuPercent: 50});
});
test('two scopes of one app are summed', () => {
    // chrome 2M + 2M = 4M beats alpha's 3M; ranking scopes singly would pick alpha.
    const ranking = rankApps(input({
        'chrome#1': [0, 2_000_000, 1], 'chrome#2': [0, 2_000_000, 1], 'alpha': [0, 3_000_000, 1],
    }));
    assertEqual(ranking.topCpu, {name: 'chrome', cpuPercent: 25});
});
test('two scopes of one app have their memory summed', () => {
    const ranking = rankApps(input({
        'chrome#1': [0, 0, 3 * GIB], 'chrome#2': [0, 0, 3 * GIB], 'alpha': [0, 0, 5 * GIB],
    }));
    assertEqual(ranking.topMemory, {name: 'chrome', memoryBytes: 6 * GIB});
});
test('a cgroup new this scan is left out of CPU but counted in memory', () => {
    // 'fresh' has no previous reading; treating it as 0 would give it 100% CPU.
    const ranking = rankApps(input({'old': [0, 1_000_000, 1 * GIB], 'fresh': [null, 16_000_000, 9 * GIB]}));
    assertEqual([ranking.topCpu.name, ranking.topMemory.name], ['old', 'fresh']);
});
test('"kernel & other" tops CPU when the scanned leaves are small', () => {
    // root Δ 12M, leaves Δ 1M → 11M of 16M capacity.
    const ranking = rankApps(input({'app': [0, 1_000_000, 1]}, {rootCpuDeltaUsec: 12_000_000}));
    assertEqual(ranking.topCpu, {name: KERNEL_AND_OTHER, cpuPercent: 68.75});
});
test('the memory half names real apps only: "kernel & other" never wins memory, however much is unattributed', () => {
    // memoryUsedBytes is what the pseudo-app's memory was once derived from (used − Σapps = 8 GiB here); passing it
    // proves rankApps no longer makes the pseudo-app a memory candidate. Unattributed memory still counts in MEM.
    const ranking = rankApps(input({'app': [0, 0, 2 * GIB]}, {memoryUsedBytes: 10 * GIB}));
    assertEqual(ranking.topMemory, {name: 'app', memoryBytes: 2 * GIB});
});
test('"kernel & other" stays a CPU candidate while the memory half names a real app', () => {
    // root Δ 12M, leaves Δ 1M → 11M of 16M capacity for the pseudo-app; memory goes to the app.
    const ranking = rankApps(input({'app': [0, 1_000_000, 3 * GIB]},
        {rootCpuDeltaUsec: 12_000_000, memoryUsedBytes: 10 * GIB}));
    assertEqual(ranking, {
        topCpu: {name: KERNEL_AND_OTHER, cpuPercent: 68.75},
        topMemory: {name: 'app', memoryBytes: 3 * GIB},
    });
});
test('"kernel & other" is the root CPU minus the leaves\', so leaves that used more than the root reported still top CPU',
    () => {
        // The pseudo-app gets nothing here (1M − 4M), so the app wins; crediting it the root's 1M plus the leaves'
        // 4M instead would make it win. Whether its negative share is clamped cannot show here: any leaf with a
        // delta outranks it. The next row is where the clamp decides.
        const ranking = rankApps(input({'app': [0, 4_000_000, 1]}, {rootCpuDeltaUsec: 1_000_000}));
        assertEqual(ranking.topCpu, {name: 'app', cpuPercent: 25});
    });
test('a root CPU counter that went backwards gives "kernel & other" 0%, never a negative share', () => {
    // No leaf has a delta (all new this scan), so the pseudo-app is the only CPU candidate and its clamp decides.
    const ranking = rankApps(input({'fresh': [null, 1_000_000, 1]}, {rootCpuDeltaUsec: -2_000_000}));
    assertEqual(ranking.topCpu, {name: KERNEL_AND_OTHER, cpuPercent: 0});
});
test('without a root CPU delta there is no "kernel & other"', () => {
    const ranking = rankApps(input({'app': [0, 0, 0]}));
    assertEqual([ranking.topCpu.name, ranking.topMemory.name], ['app', 'app']);
});
test('equal values break ties by name ascending, in either insertion order', () => {
    const betaFirst = rankApps(input({'beta': [0, 1_000_000, 5], 'alpha': [0, 1_000_000, 5]}));
    const alphaFirst = rankApps(input({'alpha': [0, 1_000_000, 5], 'beta': [0, 1_000_000, 5]}));
    assertEqual([betaFirst.topCpu.name, betaFirst.topMemory.name, alphaFirst.topCpu.name, alphaFirst.topMemory.name],
        ['alpha', 'alpha', 'alpha', 'alpha']);
});
test('a real app tied with "kernel & other" (always ranked last) wins or loses by name, not by being first', () => {
    // root Δ 2M and the one leaf's Δ 1M: the leaf and the pseudo-app both have 1M.
    const alphaTie = rankApps(input({'alpha': [0, 1_000_000, 5]}, {rootCpuDeltaUsec: 2_000_000}));
    const zetaTie = rankApps(input({'zeta': [0, 1_000_000, 5]}, {rootCpuDeltaUsec: 2_000_000}));
    assertEqual([alphaTie.topCpu.name, zetaTie.topCpu.name], ['alpha', KERNEL_AND_OTHER]);
});
test('nothing scanned gives null rankings, not zeros', () =>
    assertEqual(rankApps(input({})), {topCpu: null, topMemory: null}));
test('no cgroup with a delta gives topCpu null while memory still ranks', () => {
    const ranking = rankApps(input({'fresh': [null, 5_000_000, 2 * GIB]}));
    assertEqual(ranking, {topCpu: null, topMemory: {name: 'fresh', memoryBytes: 2 * GIB}});
});
test('a counter that went backwards counts as no usage, not negative', () => {
    const ranking = rankApps(input({'reset': [9_000_000, 1_000_000, 1]}));
    assertEqual(ranking.topCpu, {name: 'reset', cpuPercent: 0});
});
