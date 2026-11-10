// Typed readers of untrusted JSON values, shared by every protocol module. Each returns the value when it is of its
// type and range, and null otherwise, so a reader can treat a missing or mistyped field as no data for that field alone.
// Pure: no Gio and no Shell import, so it runs under plain gjs.

/**
 * Parses JSON text whose top level must be an object.
 *
 * @param {*} text - The text.
 * @returns {object|null} The object; null for a non-string, invalid JSON, or JSON that is not an object.
 */
export function parseJsonObject(text) {
    if (typeof text !== 'string')
        return null;
    let value;
    try {
        value = JSON.parse(text);
    } catch (error) {
        if (error instanceof SyntaxError)
            return null;
        throw error;
    }
    return isPlainObject(value) ? value : null;
}

/**
 * Says whether a parsed JSON value is an object (not null, not an array).
 *
 * @param {*} value - The value.
 * @returns {boolean} True for an object.
 */
export function isPlainObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * @param {*} value - A parsed JSON value.
 * @returns {number|null} The value when it is a finite number; null otherwise.
 */
export function finiteNumberOrNull(value) {
    return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/**
 * @param {*} value - A parsed JSON value.
 * @returns {number|null} The value when it is a finite number of zero or more (a byte count, a percentage); null
 *     otherwise.
 */
export function nonNegativeNumberOrNull(value) {
    const number = finiteNumberOrNull(value);
    return number !== null && number >= 0 ? number : null;
}

/**
 * @param {*} value - A parsed JSON value.
 * @returns {number|null} The value when it is a fraction from 0 to 1 (a history value); null (a gap) otherwise.
 */
export function fractionOrNull(value) {
    const number = finiteNumberOrNull(value);
    return number !== null && number >= 0 && number <= 1 ? number : null;
}

/**
 * @param {*} value - A parsed JSON value.
 * @returns {number|null} The value when it is a whole number of zero or more; null otherwise.
 */
export function countOrNull(value) {
    return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

/**
 * @param {*} value - A parsed JSON value.
 * @returns {string|null} The value when it is a string; null otherwise.
 */
export function stringOrNull(value) {
    return typeof value === 'string' ? value : null;
}

/**
 * @param {*} value - A parsed JSON value.
 * @returns {boolean|null} The value when it is a boolean; null otherwise.
 */
export function booleanOrNull(value) {
    return typeof value === 'boolean' ? value : null;
}

/**
 * @param {*} value - A parsed JSON value.
 * @param {string[]} allowedValues - The strings the field may hold.
 * @returns {string|null} The value when it is a string strictly equal to one of allowedValues; null otherwise.
 */
export function enumOrNull(value, allowedValues) {
    return typeof value === 'string' && allowedValues.includes(value) ? value : null;
}
