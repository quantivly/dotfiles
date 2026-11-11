// Rows for the nested harness's own pure modules (scripts/resource-pulse-nested.sh):
// - the unsafe-mode helper's check that keeps it from turning on unsafe mode in any shell but the nested one that
//   script started. nestedRun.js has no Shell import, so it runs here; the helper's extension.js imports the Shell
//   and only calls it.
// - the replay service's generator and scenario requests (replayGenerator.js), which has no gi import: the input
//   every `start --replay` run publishes, the same in every run of every version of the extension, and when a
//   `scenario` request restarts it.
import {test, assertEqual} from './harness.js';
import {isNestedRunRuntimeDir} from './nested/resource-pulse-nested-unsafe-mode@local/nestedRun.js';
import {
    REPLAY_SCENARIO_NAMES, ReplayGenerator, isNewScenarioRequest, parseScenarioRequest,
} from './nested/replayGenerator.js';

const RUN_DIR = '/run/user/1000/rpn.Abc12345';
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
