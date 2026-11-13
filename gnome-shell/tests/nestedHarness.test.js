// Rows for the nested harness's own pure modules (scripts/resource-pulse-nested.sh):
// - the unsafe-mode helper's check that keeps it from turning on unsafe mode in any shell but the nested one that
//   script started. nestedRun.js has no Shell import, so it runs here; the helper's extension.js imports the Shell
//   and only calls it.
// - the replay service's generator and scenario requests (replayGenerator.js), which has no gi import: the input
//   every `start --replay` run publishes, the same in every run of every version of the extension, and when a
//   `scenario` request restarts it; and the apps its snapshots carry, read as the extension reads them, ranked
//   afresh as often as the real sampler scans them (ReplayAppScanner, and replay-service.js's use of it, read as text:
//   the service runs at import, so no row can load it).
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {isNestedRunRuntimeDir} from './nested/resource-pulse-nested-unsafe-mode@local/nestedRun.js';
import {
    REPLAY_SCENARIO_NAMES, ReplayGenerator, isNewScenarioRequest, parseScenarioRequest,
} from './nested/replayGenerator.js';
// Read through the namespace, so that a missing export fails its own rows rather than every row of the run.
import * as replayGeneratorModule from './nested/replayGenerator.js';
import {
    APP_SCAN_INTERVAL_SECONDS, APPS_CARD_ROW_LIMIT, BYTES_PER_GIBIBYTE, SAMPLE_INTERVAL_SECONDS,
} from '../extensions/resource-pulse@dotfiles/lib/constants.js';
import {buildStatePayload, parseStatePayload} from '../extensions/resource-pulse@dotfiles/lib/protocol.js';

const RUN_DIR = '/run/user/1000/rpn.Abc12345';
/** The replay service's file, read as text by its row. */
const REPLAY_SERVICE_URI = GLib.uri_resolve_relative(import.meta.url, './nested/replay-service.js', GLib.UriFlags.NONE);
/**
 * The real sampler's app scan interval while a detail watch is held, in its ticks (lib/cadence.js counts it so): the
 * snapshots a replay's apps are held for.
 */
const APP_SCAN_INTERVAL_SNAPSHOTS = APP_SCAN_INTERVAL_SECONDS / SAMPLE_INTERVAL_SECONDS;
/** How many scan intervals of busy snapshots the pace row reads. */
const SCAN_INTERVALS_CHECKED = 3;
/** Intervals ReplayAppScanner must refuse: none is a whole number of snapshots, one or more. */
const REFUSED_SCAN_INTERVALS = [0, -APP_SCAN_INTERVAL_SNAPSHOTS, 2.5, Number.NaN, String(APP_SCAN_INTERVAL_SNAPSHOTS),
    null];
/** The CPU busy percents the apps rows read the replay's rankings at: idle's lowest, busy's highest, and one between. */
const IDLE_CPU_BUSY_PERCENT = 1;
const BUSY_CPU_BUSY_PERCENT = 90;
const TEN_CPU_BUSY_PERCENT = 10;
/**
 * The two winners the replay published before the rankings (replay-service.js's topCpu and topMemory at 10 % CPU
 * busy), written out: the rankings must leave them as they were.
 */
const WINNERS_AT_TEN_CPU_BUSY_PERCENT = {
    topCpu: {groupKey: 'app.slice/chromium', name: 'Chromium', cpuPercent: 6},
    topMemory: {groupKey: 'app.slice/herdr-server.service', name: 'herdr agents', memoryBytes: 15.7 * BYTES_PER_GIBIBYTE},
};
/** A state payload's fields other than the snapshot, as the real service sends them before its first Sample. */
const STATE_PAYLOAD_REST = Object.freeze({histories: {cpu: [], memory: []}, serviceStartedAtUsec: 1, sequence: 0});
/** How many of a scenario's first values the range rows read. */
const REPLAY_VALUES_CHECKED = 10;
/** How many of busy's first values its walk row reads: far enough for the walk to meet both bounds many times. */
const BUSY_WALK_VALUES_CHECKED = 630;
/** Decimal places a pinned value is compared to: well inside a double, and far finer than any pixel. */
const PINNED_VALUE_DECIMALS = 6;
/**
 * The first three CPU values of each scenario, as the session's spike (spike/replayService.js, mulberry32 seeded
 * with 20261110) produced them from a fresh seed. Pinned, so a changed seed or algorithm, or one seeded from the
 * clock, fails here: every run must be measured against this same input.
 */
const SPIKE_FIRST_CPU_PERCENTS_BY_SCENARIO = {
    idle: [2.427566, 3.321091, 2.041461],
    light: [7.710263, 11.284362, 6.165845],
    busy: [49.275657, 57.486563, 52.901175],
};

/**
 * The first values a fresh generator gives for a scenario.
 *
 * @param {string} scenarioName - One of REPLAY_SCENARIO_NAMES.
 * @param {number} valueCount - How many to take.
 * @returns {Array<{cpuBusyPercent: number, usedMemoryBytes: number}>} The values, in order.
 */
function firstReplayValues(scenarioName, valueCount) {
    const generator = new ReplayGenerator(scenarioName);
    return Array.from({length: valueCount}, () => generator.nextValues());
}

/**
 * The first CPU percents of a scenario that lie outside a range, and how many were read.
 *
 * @param {string} scenarioName - One of REPLAY_SCENARIO_NAMES.
 * @param {number} minPercent - The lowest allowed value.
 * @param {number} maxPercent - The highest allowed value.
 * @param {number} [valueCount] - How many values to read.
 * @returns {{readCount: number, outside: number[]}} How many values were read (an empty read has nothing outside
 *     the range either, so a row asserts the count too), and those outside the range.
 */
function cpuPercentsOutsideRange(scenarioName, minPercent, maxPercent, valueCount = REPLAY_VALUES_CHECKED) {
    const cpuPercents = firstReplayValues(scenarioName, valueCount).map(values => values.cpuBusyPercent);
    const outside = cpuPercents.filter(cpuPercent => !(cpuPercent >= minPercent && cpuPercent <= maxPercent));
    return {readCount: cpuPercents.length, outside};
}

/**
 * The positions of a scenario's first CPU percents that repeat the value before them.
 *
 * @param {string} scenarioName - One of REPLAY_SCENARIO_NAMES.
 * @param {number} valueCount - How many values to read.
 * @returns {number[]} Each index whose value equals the previous one.
 */
function repeatedCpuPercentIndexes(scenarioName, valueCount) {
    const cpuPercents = firstReplayValues(scenarioName, valueCount).map(values => values.cpuBusyPercent);
    const isRepeatAt = index => index > 0 && cpuPercents[index] === cpuPercents[index - 1];
    return cpuPercents.flatMap((_cpuPercent, index) => (isRepeatAt(index) ? [index] : []));
}

/**
 * A number rounded to PINNED_VALUE_DECIMALS places.
 *
 * @param {number} value - Any number.
 * @returns {number} The rounded number.
 */
function roundedForPin(value) {
    return Number(value.toFixed(PINNED_VALUE_DECIMALS));
}

/**
 * The replay service's text, every run of whitespace made one space, so a row can find a statement however it wraps.
 *
 * @returns {string} The text.
 */
function replayServiceTextOnOneLine() {
    const [servicePath] = GLib.filename_from_uri(REPLAY_SERVICE_URI);
    const [, contentBytes] = GLib.file_get_contents(servicePath);
    return new TextDecoder().decode(contentBytes).replace(/\s+/g, ' ');
}

/**
 * How many times a text holds a part.
 *
 * @param {string} text - The text.
 * @param {string} part - The part, matched as it is.
 * @returns {number} The count.
 */
function countOf(text, part) {
    return text.split(part).length - 1;
}

test('nested helper: unsafe mode only when the runtime dir is exactly <run dir>/run', () => {
    assertEqual([
        isNestedRunRuntimeDir(RUN_DIR, `${RUN_DIR}/run`),
        isNestedRunRuntimeDir(RUN_DIR, `${RUN_DIR}/run/nested`),
        isNestedRunRuntimeDir(RUN_DIR, `${RUN_DIR}/home`),
        isNestedRunRuntimeDir(RUN_DIR, '/run/user/1000'),
        isNestedRunRuntimeDir(RUN_DIR, `${RUN_DIR}/run/`),
        isNestedRunRuntimeDir(null, `${RUN_DIR}/run`),
        isNestedRunRuntimeDir('', '/run'),
    ], [true, false, false, false, false, false, false]);
});

test('replay generator: the first ten idle CPU values lie in 1–4 %', () => {
    assertEqual(cpuPercentsOutsideRange('idle', 1, 4), {readCount: REPLAY_VALUES_CHECKED, outside: []});
});

test('replay generator: the first ten light CPU values lie in 2–14 %', () => {
    assertEqual(cpuPercentsOutsideRange('light', 2, 14), {readCount: REPLAY_VALUES_CHECKED, outside: []});
});

test('replay generator: the first 630 busy CPU values lie in 15–90 % and each differs from the one before', () => {
    assertEqual({
        range: cpuPercentsOutsideRange('busy', 15, 90, BUSY_WALK_VALUES_CHECKED),
        repeatedIndexes: repeatedCpuPercentIndexes('busy', BUSY_WALK_VALUES_CHECKED),
    }, {range: {readCount: BUSY_WALK_VALUES_CHECKED, outside: []}, repeatedIndexes: []});
});

test('replay generator: two runs give the same sequence, the fixed seed\'s (the spike\'s first values)', () => {
    for (const scenarioName of REPLAY_SCENARIO_NAMES) {
        const firstRunValues = firstReplayValues(scenarioName, REPLAY_VALUES_CHECKED);
        const secondRunValues = firstReplayValues(scenarioName, REPLAY_VALUES_CHECKED);
        assertEqual(secondRunValues, firstRunValues, `${scenarioName}: the second run differs`);
        const pinnedCpuPercents = SPIKE_FIRST_CPU_PERCENTS_BY_SCENARIO[scenarioName];
        const leadingCpuPercents = firstRunValues.slice(0, pinnedCpuPercents.length)
            .map(values => roundedForPin(values.cpuBusyPercent));
        assertEqual(leadingCpuPercents, pinnedCpuPercents, `${scenarioName}: not the fixed seed's sequence`);
    }
});

test('replay generator: exactly the scenarios idle, light and busy; any other name is refused', () => {
    const refusedNames = ['silent', 'IDLE', '', 'idle '].filter(scenarioName => {
        try {
            new ReplayGenerator(scenarioName);
            return false;
        } catch (_error) {
            return true;
        }
    });
    assertEqual([REPLAY_SCENARIO_NAMES, refusedNames], [['idle', 'light', 'busy'], ['silent', 'IDLE', '', 'idle ']]);
});

test('replay request: each scenario request restarts the replay, the word playing included; a re-read does not', () => {
    const nothingAsked = parseScenarioRequest(null);
    const busyAsked = parseScenarioRequest('busy Ab12Cd\n');
    const idleAsked = parseScenarioRequest('idle Ef34Gh\n');
    const restartsByCase = {
        'busy asked on a fresh run': isNewScenarioRequest(nothingAsked, busyAsked),
        'the same request read again': isNewScenarioRequest(busyAsked, parseScenarioRequest('busy Ab12Cd')),
        'busy asked again': isNewScenarioRequest(busyAsked, parseScenarioRequest('busy Ij56Kl\n')),
        'idle asked while busy plays': isNewScenarioRequest(busyAsked, idleAsked),
        'the file gone while idle plays': isNewScenarioRequest(idleAsked, parseScenarioRequest(null)),
        'a bad word while busy plays': isNewScenarioRequest(busyAsked, parseScenarioRequest('turbo Mn78Op')),
        'an empty file while busy plays': isNewScenarioRequest(busyAsked, parseScenarioRequest('')),
        'nothing asked, read again': isNewScenarioRequest(nothingAsked, parseScenarioRequest(null)),
    };
    const playedByFileText = ['busy Ab12Cd\n', 'idle Ef34Gh', ' light  Qr90St \n', 'turbo Mn78Op', 'IDLE x', '']
        .map(fileText => parseScenarioRequest(fileText).scenarioName);
    assertEqual({restartsByCase, playedByFileText, nothingAskedPlays: nothingAsked.scenarioName}, {
        restartsByCase: {
            'busy asked on a fresh run': true,
            'the same request read again': false,
            'busy asked again': true,
            'idle asked while busy plays': true,
            'the file gone while idle plays': true,
            'a bad word while busy plays': false,
            'an empty file while busy plays': false,
            'nothing asked, read again': false,
        },
        playedByFileText: ['busy', 'idle', 'light', 'busy', 'busy', 'busy'],
        nothingAskedPlays: 'busy',
    });
});

/**
 * Whether a ranking is largest first by one field.
 *
 * @param {Array<object>} ranking - A ranking's entries.
 * @param {string} valueFieldName - 'cpuPercent' or 'memoryBytes'.
 * @returns {boolean} True when no entry is larger than the one before it.
 */
function isLargestFirst(ranking, valueFieldName) {
    return ranking.every((entry, entryIndex) => entryIndex === 0 ||
        ranking[entryIndex - 1][valueFieldName] >= entry[valueFieldName]);
}

test('replay: the apps a snapshot carries reach the extension\'s reader (lib/protocol.js) field for field, both ' +
    'winners and both rankings, nothing dropped', () => {
    const sentApps = replayGeneratorModule.replayApps(BUSY_CPU_BUSY_PERCENT);
    const statePayload = buildStatePayload({...STATE_PAYLOAD_REST, snapshot: {apps: sentApps}});
    assertEqual(parseStatePayload(statePayload).snapshot.apps, sentApps);
});

test('replay: each ranking holds as many entries as the apps card shows (APPS_CARD_ROW_LIMIT), each named, with a ' +
    'group key of its own, largest first; topCpu and topMemory are their first entries, as the replay published them ' +
    'before the rankings', () => {
    const {topCpu, topMemory, cpuRanking, memoryRanking} = replayGeneratorModule.replayApps(TEN_CPU_BUSY_PERCENT);
    const distinctGroupKeyCount = ranking => new Set(ranking.map(entry => entry.groupKey)).size;
    assertEqual({
        lengths: [cpuRanking.length, memoryRanking.length],
        distinctGroupKeys: [distinctGroupKeyCount(cpuRanking), distinctGroupKeyCount(memoryRanking)],
        named: [...cpuRanking, ...memoryRanking].every(entry => typeof entry.name === 'string' && entry.name !== ''),
        largestFirst: [isLargestFirst(cpuRanking, 'cpuPercent'), isLargestFirst(memoryRanking, 'memoryBytes')],
        winnersAreFirstEntries: JSON.stringify([topCpu, topMemory]) === JSON.stringify([cpuRanking[0], memoryRanking[0]]),
        winners: {topCpu, topMemory},
    }, {
        lengths: [APPS_CARD_ROW_LIMIT, APPS_CARD_ROW_LIMIT],
        distinctGroupKeys: [APPS_CARD_ROW_LIMIT, APPS_CARD_ROW_LIMIT],
        named: true,
        largestFirst: [true, true],
        winnersAreFirstEntries: true,
        winners: WINNERS_AT_TEN_CPU_BUSY_PERCENT,
    });
});

test('replay: the CPU ranking follows the snapshot\'s CPU figure (each entry the same share of it, in the same ' +
    'order, idle\'s near 0 % and busy\'s tens of percent, together never above it); the memory ranking is fixed', () => {
    const idleApps = replayGeneratorModule.replayApps(IDLE_CPU_BUSY_PERCENT);
    const busyApps = replayGeneratorModule.replayApps(BUSY_CPU_BUSY_PERCENT);
    const sharesOf = ({cpuRanking}, cpuBusyPercent) =>
        cpuRanking.map(entry => Number((entry.cpuPercent / cpuBusyPercent).toFixed(PINNED_VALUE_DECIMALS)));
    const idleShares = sharesOf(idleApps, IDLE_CPU_BUSY_PERCENT);
    const busyCpuTotal = busyApps.cpuRanking.reduce((total, entry) => total + entry.cpuPercent, 0);
    assertEqual({
        sameShares: JSON.stringify(idleShares) === JSON.stringify(sharesOf(busyApps, BUSY_CPU_BUSY_PERCENT)),
        everyShareAboveZero: idleShares.every(share => share > 0),
        sameOrder: JSON.stringify(idleApps.cpuRanking.map(entry => entry.name)) ===
            JSON.stringify(busyApps.cpuRanking.map(entry => entry.name)),
        busyTotalWithinBusy: busyCpuTotal <= BUSY_CPU_BUSY_PERCENT,
        memoryFixed: JSON.stringify(idleApps.memoryRanking) === JSON.stringify(busyApps.memoryRanking),
    }, {sameShares: true, everyShareAboveZero: true, sameOrder: true, busyTotalWithinBusy: true, memoryFixed: true});
});

test('replay: the apps are ranked afresh as often as the real sampler scans them with a detail watch held (every ' +
    'APP_SCAN_INTERVAL_SECONDS / SAMPLE_INTERVAL_SECONDS snapshots, from the first, at that snapshot\'s CPU ' +
    'figure) and held between: inside one scan interval every snapshot carries the same apps, the next interval\'s ' +
    'differ under busy input; topCpu and topMemory are the first entries at every snapshot', () => {
    const scanner = new replayGeneratorModule.ReplayAppScanner(APP_SCAN_INTERVAL_SNAPSHOTS);
    const cpuBusyPercents = firstReplayValues('busy', SCAN_INTERVALS_CHECKED * APP_SCAN_INTERVAL_SNAPSHOTS)
        .map(values => values.cpuBusyPercent);
    const appsBySnapshot = cpuBusyPercents.map(cpuBusyPercent => scanner.appsOfNextSnapshot(cpuBusyPercent));
    const scanSnapshotIndexOf = snapshotIndex => snapshotIndex - (snapshotIndex % APP_SCAN_INTERVAL_SNAPSHOTS);
    const appsOfScanAt = snapshotIndex =>
        replayGeneratorModule.replayApps(cpuBusyPercents[scanSnapshotIndexOf(snapshotIndex)]);
    const intervalIndexes = Array.from({length: SCAN_INTERVALS_CHECKED}, (_, intervalIndex) => intervalIndex);
    const appsOfInterval = intervalIndex => appsBySnapshot.slice(intervalIndex * APP_SCAN_INTERVAL_SNAPSHOTS,
        (intervalIndex + 1) * APP_SCAN_INTERVAL_SNAPSHOTS).map(apps => JSON.stringify(apps));
    const winnersAreFirstEntries = apps => JSON.stringify([apps.topCpu, apps.topMemory]) ===
        JSON.stringify([apps.cpuRanking[0], apps.memoryRanking[0]]);
    assertEqual({
        heldForMoreThanOneSnapshot: APP_SCAN_INTERVAL_SNAPSHOTS > 1,
        snapshotCount: appsBySnapshot.length,
        snapshotsNotCarryingTheirScan: appsBySnapshot.flatMap((apps, snapshotIndex) =>
            (JSON.stringify(apps) === JSON.stringify(appsOfScanAt(snapshotIndex)) ? [] : [snapshotIndex])),
        distinctAppsInEachInterval: intervalIndexes.map(intervalIndex => new Set(appsOfInterval(intervalIndex)).size),
        distinctIntervals: new Set(intervalIndexes.map(intervalIndex => appsOfInterval(intervalIndex)[0])).size,
        winnersAreFirstEntries: appsBySnapshot.every(winnersAreFirstEntries),
    }, {
        heldForMoreThanOneSnapshot: true,
        snapshotCount: SCAN_INTERVALS_CHECKED * APP_SCAN_INTERVAL_SNAPSHOTS,
        snapshotsNotCarryingTheirScan: [],
        distinctAppsInEachInterval: intervalIndexes.map(() => 1),
        distinctIntervals: SCAN_INTERVALS_CHECKED,
        winnersAreFirstEntries: true,
    });
});

test('replay: a scan interval that is not a whole number of snapshots, one or more, is refused, naming it; one ' +
    'snapshot and the sampler\'s own interval are taken', () => {
    const outcomeOf = scanIntervalSnapshots => {
        try {
            new replayGeneratorModule.ReplayAppScanner(scanIntervalSnapshots);
            return 'taken';
        } catch (error) {
            return error.message.includes(`got ${scanIntervalSnapshots}`) ? 'refused, named' : `refused: ${error}`;
        }
    };
    assertEqual({
        refused: REFUSED_SCAN_INTERVALS.map(outcomeOf),
        taken: [1, APP_SCAN_INTERVAL_SNAPSHOTS].map(outcomeOf),
    }, {
        refused: REFUSED_SCAN_INTERVALS.map(() => 'refused, named'),
        taken: ['taken', 'taken'],
    });
});

test('replay service: each scenario\'s snapshots take their apps from one ReplayAppScanner made with the ' +
    'extension\'s own APP_SCAN_INTERVAL_SECONDS / SAMPLE_INTERVAL_SECONDS, never from replayApps on every ' +
    'snapshot', () => {
    const serviceText = replayServiceTextOnOneLine();
    assertEqual({
        imported: countOf(serviceText, 'REPLAY_TOTAL_MEMORY_BYTES, ReplayAppScanner, ReplayGenerator,'),
        intervalFromTheExtension: countOf(serviceText, 'const appScanIntervalSnapshots = ' +
            'this._constants.APP_SCAN_INTERVAL_SECONDS / this._constants.SAMPLE_INTERVAL_SECONDS;'),
        scannerPerScenario: countOf(serviceText, 'this._generator = new ReplayGenerator(scenarioName); ' +
            'this._appScanner = new ReplayAppScanner(appScanIntervalSnapshots);'),
        appsFromTheScanner: countOf(serviceText, 'apps: this._appScanner.appsOfNextSnapshot(cpuBusyPercent),'),
        rankedEverySnapshot: countOf(serviceText, 'replayApps('),
    }, {
        imported: 1, intervalFromTheExtension: 1, scannerPerScenario: 1, appsFromTheScanner: 1, rankedEverySnapshot: 0,
    });
});
