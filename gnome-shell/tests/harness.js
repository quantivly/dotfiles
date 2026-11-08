// Minimal plain-gjs test harness: no dependencies, runs under `gjs -m`.

/** @type {Array<{name: string, body: () => (void|Promise<void>)}>} */
const registeredTests = [];

/**
 * Registers a test to be run by runAll().
 *
 * @param {string} name - Row name printed for the test.
 * @param {() => (void|Promise<void>)} body - Test body; throws to fail.
 * @returns {void}
 */
export function test(name, body) {
    registeredTests.push({name, body});
}

/**
 * Converts a value to a comparable JSON string; Maps become arrays of entries.
 *
 * @param {*} value - Any value.
 * @returns {string} JSON text.
 */
function toComparableJson(value) {
    // JSON.stringify turns NaN and +/-Infinity into null, which would make
    // assertEqual(NaN, null) pass; tag them so they stay distinct.
    return JSON.stringify(value, (_key, inner) => {
        if (inner instanceof Map)
            return [...inner.entries()];
        if (typeof inner === 'number' && !Number.isFinite(inner))
            return `<non-finite number ${String(inner)}>`;
        return inner;
    });
}

/**
 * Fails unless actual and expected are JSON-equal.
 *
 * @param {*} actual - The value produced by the code under test.
 * @param {*} expected - The value it must equal.
 * @param {string} [detail] - Extra context for the failure message.
 * @returns {void}
 */
export function assertEqual(actual, expected, detail) {
    const actualJson = toComparableJson(actual);
    const expectedJson = toComparableJson(expected);
    if (actualJson !== expectedJson) {
        const suffix = detail ? ` (${detail})` : '';
        throw new Error(`expected ${expectedJson}, got ${actualJson}${suffix}`);
    }
}

/**
 * Fails unless two numbers differ by at most epsilon.
 *
 * @param {number} actual - The value produced by the code under test.
 * @param {number} expected - The value it must be close to.
 * @param {number} epsilon - Largest allowed absolute difference.
 * @returns {void}
 */
export function assertClose(actual, expected, epsilon) {
    if (typeof actual !== 'number' || Number.isNaN(actual) ||
        Math.abs(actual - expected) > epsilon)
        throw new Error(`expected ${expected} +/- ${epsilon}, got ${actual}`);
}

/**
 * Runs every registered test in order.
 *
 * @returns {Promise<{passCount: number, failCount: number, rows: string[]}>}
 *     Counts plus one printable row per test.
 */
export async function runAll() {
    let passCount = 0;
    let failCount = 0;
    const rows = [];
    for (const {name, body} of registeredTests) {
        try {
            await body();
            passCount++;
            rows.push(`  ✓ ${name}`);
        } catch (error) {
            failCount++;
            rows.push(`  ✗ ${name} — ${error.message}`);
        }
    }
    return {passCount, failCount, rows};
}
