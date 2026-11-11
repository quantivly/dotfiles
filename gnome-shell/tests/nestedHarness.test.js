// Rows for the nested harness's own pure modules (scripts/resource-pulse-nested.sh):
// - the unsafe-mode helper's check that keeps it from turning on unsafe mode in any shell but the nested one that
//   script started. nestedRun.js has no Shell import, so it runs here; the helper's extension.js imports the Shell
//   and only calls it.
// - the replay service's generator (replayGenerator.js), which has no gi import: the input every `start --replay`
//   run publishes, the same in every run of every version of the extension.
import {test, assertEqual} from './harness.js';
import {isNestedRunRuntimeDir} from './nested/resource-pulse-nested-unsafe-mode@local/nestedRun.js';
import {REPLAY_SCENARIO_NAMES, ReplayGenerator} from './nested/replayGenerator.js';

const RUN_DIR = '/run/user/1000/rpn.Abc12345';
/** How many of a scenario's first values the range rows read. */
const REPLAY_VALUES_CHECKED = 10;
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
 * @returns {{readCount: number, outside: number[]}} How many values were read (an empty read has nothing outside
 *     the range either, so a row asserts the count too), and those outside the range.
 */
function cpuPercentsOutsideRange(scenarioName, minPercent, maxPercent) {
    const cpuPercents = firstReplayValues(scenarioName, REPLAY_VALUES_CHECKED).map(values => values.cpuBusyPercent);
    const outside = cpuPercents.filter(cpuPercent => !(cpuPercent >= minPercent && cpuPercent <= maxPercent));
    return {readCount: cpuPercents.length, outside};
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

test('replay generator: the first ten busy CPU values lie in 15–90 %', () => {
    assertEqual(cpuPercentsOutsideRange('busy', 15, 90), {readCount: REPLAY_VALUES_CHECKED, outside: []});
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
