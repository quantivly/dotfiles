// The input the replay service (replay-service.js) publishes in place of the real sampler's, ported from the
// performance session's spike (spike/replayService.js): per tick, one CPU busy percent and one used-memory figure,
// drawn from a small seeded generator. A fresh generator always starts from the same seed, so every run of every
// version of the extension is measured against the same sequence.
//   idle   CPU 1–4 %: inside one pixel of a 16-pixel graph
//   light  CPU 2–14 %: crosses a pixel boundary on some ticks
//   busy   CPU a walk between 15 % and 90 % that reflects off both bounds, so it changes on every tick. The spike
//          clamped it instead, and so sat at a bound, repeating itself; the first values, well inside the bounds,
//          are the spike's.
// It also reads the scenario file the harness's `scenario` request writes, and says when a read must restart the
// replay (parseScenarioRequest, isNewScenarioRequest).
// Pure: no gi import, no clock, no file, so it runs under plain gjs (gnome-shell/tests/nestedHarness.test.js).

const IDLE_SCENARIO_NAME = 'idle';
const LIGHT_SCENARIO_NAME = 'light';
const BUSY_SCENARIO_NAME = 'busy';
/** The scenario words, in the order scripts/resource-pulse-nested.sh's `scenario` request lists them. */
export const REPLAY_SCENARIO_NAMES = Object.freeze([IDLE_SCENARIO_NAME, LIGHT_SCENARIO_NAME, BUSY_SCENARIO_NAME]);
/** What plays until a scenario is asked for, and while the scenario file names none. */
export const DEFAULT_REPLAY_SCENARIO_NAME = BUSY_SCENARIO_NAME;
/** Separates the scenario file's fields: the word, then the token the harness writes with each request. */
const SCENARIO_FILE_FIELD_SEPARATOR_PATTERN = /\s+/;
/** How a request's fields are joined back into its text, whatever spacing the file had. */
const SCENARIO_REQUEST_FIELD_JOINER = ' ';
/** The seed of every generator: the spike's, so the port publishes the sequence the session measured. */
export const REPLAY_RANDOM_SEED = 20261110;

const BYTES_PER_MEBIBYTE = 1024 ** 2;
const BYTES_PER_GIBIBYTE = 1024 ** 3;
/** The memory every snapshot reports in total: the reference laptop's. The walk's bounds use it unrounded. */
const TOTAL_MEMORY_BYTES = 30.3 * BYTES_PER_GIBIBYTE;
/** The same total in whole bytes, as a snapshot reports it. */
export const REPLAY_TOTAL_MEMORY_BYTES = Math.round(TOTAL_MEMORY_BYTES);
/** Where the used-memory walk starts. */
const START_USED_MEMORY_BYTES = 16.4 * BYTES_PER_GIBIBYTE;
/** The used-memory walk stays between these fractions of the total. */
const MIN_USED_MEMORY_FRACTION = 0.3;
const MAX_USED_MEMORY_FRACTION = 0.9;
/** The width of one tick's used-memory step (half of it either way): busy, and the two quiet scenarios. */
const BUSY_MEMORY_STEP_SPAN_BYTES = 60 * BYTES_PER_MEBIBYTE;
const QUIET_MEMORY_STEP_SPAN_BYTES = 2 * BYTES_PER_MEBIBYTE;

/** idle and light draw each tick's CPU uniformly from [min, max). */
const IDLE_CPU_MIN_PERCENT = 1;
const IDLE_CPU_MAX_PERCENT = 4;
const LIGHT_CPU_MIN_PERCENT = 2;
const LIGHT_CPU_MAX_PERCENT = 14;
/** busy walks from its start by up to half the step span either way per tick, reflected off min and max. */
const BUSY_CPU_MIN_PERCENT = 15;
const BUSY_CPU_MAX_PERCENT = 90;
const BUSY_CPU_START_PERCENT = 50;
const BUSY_CPU_STEP_SPAN_PERCENT = 30;
/** A step is (draw - this) * span: a draw from [0, 1) centred on zero. */
const STEP_CENTRE = 0.5;

/** mulberry32's increment; the shifts and multipliers in createSeededRandom are the algorithm's published ones. */
const MULBERRY32_INCREMENT = 0x6D2B79F5;
/** 2^32: an unsigned 32-bit result over this is a draw from [0, 1). */
const UINT32_RANGE = 2 ** 32;

/**
 * A seeded source of draws from [0, 1): mulberry32, as the spike wrote it, so a seed always gives the same draws.
 *
 * @param {number} seed - The seed, a 32-bit integer.
 * @returns {() => number} Returns the next draw.
 */
function createSeededRandom(seed) {
    let state = seed;
    return () => {
        state = (state + MULBERRY32_INCREMENT) | 0;
        let mixed = Math.imul(state ^ (state >>> 15), 1 | state);
        const remixed = Math.imul(mixed ^ (mixed >>> 7), 61 | mixed);
        mixed = (mixed + remixed) ^ mixed;
        const unsignedResult = (mixed ^ (mixed >>> 14)) >>> 0;
        return unsignedResult / UINT32_RANGE;
    };
}

/**
 * A value held between two bounds.
 *
 * @param {number} value - Any number.
 * @param {number} min - The lowest result.
 * @param {number} max - The highest result.
 * @returns {number} The value, or the bound it crossed.
 */
function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
}

/**
 * A value folded back into a range from the bound it crossed, as a walk bounces off a wall: a value past max by d
 * becomes max - d. One fold is enough while a step is narrower than the range, as busy's is.
 *
 * @param {number} value - The walk's position after a step.
 * @param {number} min - The lower bound.
 * @param {number} max - The upper bound.
 * @returns {number} The position inside [min, max].
 */
function reflectIntoRange(value, min, max) {
    if (value > max)
        return max - (value - max);
    if (value < min)
        return min + (min - value);
    return value;
}

/**
 * @typedef {object} ScenarioRequest
 * @property {string} scenarioName - The scenario to play: the file's word, or the default when it names none.
 * @property {string|null} requestText - The file's fields, single-spaced, when its word is a scenario: two requests
 *     for the same word differ here by their tokens. Null when the default plays because the file names none.
 * @property {string|null} rejectedText - The file's text when its word is not a scenario, for the log; else null.
 */

/**
 * Reads the scenario file's text: its first whitespace-separated field is the word, and what follows (the token the
 * harness writes with each request) only tells one request from the next.
 *
 * @param {string|null} fileText - The file's text; null when there is no readable file.
 * @returns {ScenarioRequest} What it asks for.
 */
export function parseScenarioRequest(fileText) {
    if (fileText === null)
        return {scenarioName: DEFAULT_REPLAY_SCENARIO_NAME, requestText: null, rejectedText: null};
    const trimmedText = fileText.trim();
    const requestFields = trimmedText.split(SCENARIO_FILE_FIELD_SEPARATOR_PATTERN);
    const [scenarioWord] = requestFields;
    if (!REPLAY_SCENARIO_NAMES.includes(scenarioWord))
        return {scenarioName: DEFAULT_REPLAY_SCENARIO_NAME, requestText: null, rejectedText: trimmedText};
    const requestText = requestFields.join(SCENARIO_REQUEST_FIELD_JOINER);
    return {scenarioName: scenarioWord, requestText, rejectedText: null};
}

/**
 * Whether a read of the scenario file must restart the replay: a request not read before restarts it, the word
 * already playing included (each `scenario` request carries a new token), and so does falling back to the default
 * from another scenario. Reading the same request again does not, nor does falling back to the scenario playing.
 *
 * @param {ScenarioRequest} lastRequest - What the previous read asked for.
 * @param {ScenarioRequest} readRequest - What this read asks for.
 * @returns {boolean} True when the replay must start the read scenario again from its seed.
 */
export function isNewScenarioRequest(lastRequest, readRequest) {
    if (readRequest.requestText !== null)
        return readRequest.requestText !== lastRequest.requestText;
    return readRequest.scenarioName !== lastRequest.scenarioName;
}

/** One scenario's sequence of synthetic samples, from the fixed seed. */
export class ReplayGenerator {
    /**
     * Starts a scenario's sequence from the fixed seed.
     *
     * @param {string} scenarioName - One of REPLAY_SCENARIO_NAMES.
     * @throws {Error} For any other name: there are exactly three scenarios.
     */
    constructor(scenarioName) {
        if (!REPLAY_SCENARIO_NAMES.includes(scenarioName))
            throw new Error(`not a replay scenario: '${scenarioName}' (one of ${REPLAY_SCENARIO_NAMES.join(', ')})`);
        this._scenarioName = scenarioName;
        this._nextRandom = createSeededRandom(REPLAY_RANDOM_SEED);
        this._busyCpuPercent = BUSY_CPU_START_PERCENT;
        this._usedMemoryBytes = START_USED_MEMORY_BYTES;
    }

    /** @returns {string} The scenario this sequence plays. */
    get scenarioName() {
        return this._scenarioName;
    }

    /**
     * The next tick's figures: the CPU draw first, then the memory step, in the spike's order.
     *
     * @returns {{cpuBusyPercent: number, usedMemoryBytes: number}} CPU busy 0–100, and used memory in whole bytes.
     */
    nextValues() {
        const cpuBusyPercent = this._nextCpuPercent();
        const usedMemoryBytes = this._nextUsedMemoryBytes();
        return {cpuBusyPercent, usedMemoryBytes};
    }

    /**
     * Draws the next CPU busy percent of this scenario.
     *
     * @returns {number} The percent.
     */
    _nextCpuPercent() {
        if (this._scenarioName === IDLE_SCENARIO_NAME)
            return this._nextUniform(IDLE_CPU_MIN_PERCENT, IDLE_CPU_MAX_PERCENT);
        if (this._scenarioName === LIGHT_SCENARIO_NAME)
            return this._nextUniform(LIGHT_CPU_MIN_PERCENT, LIGHT_CPU_MAX_PERCENT);
        const busyStepPercent = this._nextCentredStep(BUSY_CPU_STEP_SPAN_PERCENT);
        this._busyCpuPercent = reflectIntoRange(this._busyCpuPercent + busyStepPercent, BUSY_CPU_MIN_PERCENT,
            BUSY_CPU_MAX_PERCENT);
        return this._busyCpuPercent;
    }

    /**
     * Steps the used-memory walk: wider while busy.
     *
     * @returns {number} Used memory, in whole bytes.
     */
    _nextUsedMemoryBytes() {
        const stepSpanBytes = this._scenarioName === BUSY_SCENARIO_NAME ? BUSY_MEMORY_STEP_SPAN_BYTES
            : QUIET_MEMORY_STEP_SPAN_BYTES;
        const memoryStepBytes = this._nextCentredStep(stepSpanBytes);
        const minUsedBytes = TOTAL_MEMORY_BYTES * MIN_USED_MEMORY_FRACTION;
        const maxUsedBytes = TOTAL_MEMORY_BYTES * MAX_USED_MEMORY_FRACTION;
        this._usedMemoryBytes = clamp(this._usedMemoryBytes + memoryStepBytes, minUsedBytes, maxUsedBytes);
        return Math.round(this._usedMemoryBytes);
    }

    /**
     * Draws a value uniformly from [min, max).
     *
     * @param {number} min - The lowest value.
     * @param {number} max - The value never reached.
     * @returns {number} The value.
     */
    _nextUniform(min, max) {
        return min + (max - min) * this._nextRandom();
    }

    /**
     * Draws a step from [-span / 2, span / 2).
     *
     * @param {number} span - The width of the range.
     * @returns {number} The step.
     */
    _nextCentredStep(span) {
        return (this._nextRandom() - STEP_CENTRE) * span;
    }
}
