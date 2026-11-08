import {test, assertEqual} from './harness.js';

/**
 * Asserts that calling the body throws.
 *
 * @param {() => void} body - Call expected to throw.
 * @param {string} description - Names the case in the failure message.
 * @returns {void}
 */
function assertThrows(body, description) {
    let didThrow = false;
    try {
        body();
    } catch (_error) {
        didThrow = true;
    }
    if (!didThrow)
        throw new Error(`expected a throw: ${description}`);
}

test('harness: assertEqual(NaN, null) fails, so a NaN-returning parser cannot pass', () =>
    assertThrows(() => assertEqual(NaN, null), 'NaN vs null'));
test('harness: assertEqual distinguishes Infinity, -Infinity and NaN from null and each other', () => {
    assertThrows(() => assertEqual(Infinity, null), 'Infinity vs null');
    assertThrows(() => assertEqual(-Infinity, null), '-Infinity vs null');
    assertThrows(() => assertEqual(Infinity, -Infinity), 'Infinity vs -Infinity');
    assertThrows(() => assertEqual({value: NaN}, {value: null}), 'nested NaN vs null');
    assertEqual(NaN, NaN);
});
