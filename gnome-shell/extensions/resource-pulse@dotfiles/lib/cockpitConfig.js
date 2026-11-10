// The cockpit layout config: the personal, opt-in file that names the cockpit monitor and lays out its card groups.
// This module turns the file's text into a layout or into the first error found, and knows where the file lives;
// reading the file and watching it are the service's job. Pure: no Gio and no Shell import, so it runs under plain gjs.
//
// The layout it returns is exactly the shape cockpitProtocol.parseLayout rebuilds, so what the service publishes is
// what the config said. Keys the parser does not know are ignored, `_`-prefixed ones (the template's `_comment`)
// included, so the format can grow additively like the protocol.
import {COCKPIT_CARD_IDS, COCKPIT_CONFIG_RELATIVE_PATH, COCKPIT_GRID_COLUMNS} from './constants.js';
import {isPlainObject, parseJsonObject, stringOrNull} from './jsonFields.js';

/** The only `version` this parser reads. */
const SUPPORTED_CONFIG_VERSION = 1;
/** The `columns` values a group may ask for, as the error message says them. */
const GROUP_COLUMN_CHOICES = [1, 2];
/** The error for a config that is not text at all. */
const NOT_TEXT_ERROR = 'config: expected JSON text';
/** The error for text that is not a JSON object. */
const NOT_OBJECT_ERROR = 'config: expected a JSON object';

/**
 * @typedef {object} CockpitLayout
 * @property {{vendor: string|null, product: string|null}} monitor - Which monitor is the cockpit's.
 * @property {Array<{id: string, caption: string, columns: number, cards: string[]}>} groups - The card groups.
 */

/**
 * Parses and validates the layout config. Never throws.
 *
 * @param {*} text - The config file's text.
 * @returns {{layout: CockpitLayout|null, error: string|null}} The layout when the config is valid, otherwise null
 *     and the error naming the first offending field.
 */
export function parseCockpitConfig(text) {
    if (typeof text !== 'string')
        return {layout: null, error: NOT_TEXT_ERROR};
    const config = parseJsonObject(text);
    if (config === null)
        return {layout: null, error: NOT_OBJECT_ERROR};
    const error = firstConfigError(config);
    if (error !== null)
        return {layout: null, error};
    return {layout: buildLayout(config), error: null};
}

/**
 * The path of the layout config.
 *
 * @param {string} configHome - The user's config home (XDG_CONFIG_HOME, normally ~/.config).
 * @returns {string} configHome joined with COCKPIT_CONFIG_RELATIVE_PATH.
 */
export function cockpitConfigPath(configHome) {
    return `${configHome.replace(/\/+$/, '')}/${COCKPIT_CONFIG_RELATIVE_PATH}`;
}

/**
 * @param {object} config - The parsed config object.
 * @returns {string|null} The first error, checking version, monitor, groups in that order; null when valid.
 */
function firstConfigError(config) {
    if (config.version !== SUPPORTED_CONFIG_VERSION)
        return `version: expected ${SUPPORTED_CONFIG_VERSION}, got ${String(config.version)}`;
    const monitorError = firstMonitorError(config.monitor);
    if (monitorError !== null)
        return monitorError;
    return firstGroupsError(config.groups);
}

/**
 * @param {*} monitor - The config's `monitor`, which may be absent.
 * @returns {string|null} The first error; null when absent or valid.
 */
function firstMonitorError(monitor) {
    if (monitor === undefined)
        return null;
    if (!isPlainObject(monitor))
        return 'monitor: expected an object';
    for (const fieldName of ['vendor', 'product']) {
        if (monitor[fieldName] !== undefined && stringOrNull(monitor[fieldName]) === null)
            return `monitor.${fieldName}: expected a string`;
    }
    return null;
}

/**
 * @param {*} groups - The config's `groups`.
 * @returns {string|null} The first error over the array's shape, each group, the repeats, then the column total.
 */
function firstGroupsError(groups) {
    if (!Array.isArray(groups) || groups.length === 0)
        return 'groups: expected a non-empty array';
    for (let index = 0; index < groups.length; index++) {
        const error = firstGroupError(groups[index], index);
        if (error !== null)
            return error;
    }
    return firstRepeatError(groups) ?? firstColumnTotalError(groups);
}

/**
 * @param {*} group - One entry of `groups`.
 * @param {number} index - Its position.
 * @returns {string|null} The first error in its fields, in the order id, caption, columns, cards; null when valid.
 */
function firstGroupError(group, index) {
    const where = `groups[${index}]`;
    if (!isPlainObject(group))
        return `${where}: expected an object`;
    for (const fieldName of ['id', 'caption']) {
        if (stringOrNull(group[fieldName]) === null || group[fieldName] === '')
            return `${where}.${fieldName}: expected a non-empty string`;
    }
    if (!GROUP_COLUMN_CHOICES.includes(group.columns))
        return `${where}.columns: expected ${GROUP_COLUMN_CHOICES.join(' or ')}`;
    return firstCardsError(group.cards, where);
}

/**
 * @param {*} cards - A group's `cards`.
 * @param {string} where - The group's position, as `groups[1]`.
 * @returns {string|null} The first error; null when a non-empty array of known card ids.
 */
function firstCardsError(cards, where) {
    if (!Array.isArray(cards) || cards.length === 0)
        return `${where}.cards: expected a non-empty array`;
    const unknownIndex = cards.findIndex(cardId => !COCKPIT_CARD_IDS.includes(cardId));
    if (unknownIndex !== -1)
        return `${where}.cards[${unknownIndex}]: unknown card id '${String(cards[unknownIndex])}'`;
    return null;
}

/**
 * @param {object[]} groups - The groups, each already valid on its own.
 * @returns {string|null} The first group id, then card id, seen a second time; null when none repeats. Group ids are
 *     checked first across all groups, as the order the rule is documented in.
 */
function firstRepeatError(groups) {
    const seenGroupIds = new Set();
    const seenCardIds = new Set();
    for (let groupIndex = 0; groupIndex < groups.length; groupIndex++) {
        const group = groups[groupIndex];
        if (seenGroupIds.has(group.id))
            return `groups[${groupIndex}].id: repeated group id '${group.id}'`;
        seenGroupIds.add(group.id);
        const repeatedIndex = group.cards.findIndex(cardId => seenCardIds.has(cardId));
        if (repeatedIndex !== -1)
            return `groups[${groupIndex}].cards[${repeatedIndex}]: repeated card id '${group.cards[repeatedIndex]}'`;
        group.cards.forEach(cardId => seenCardIds.add(cardId));
    }
    return null;
}

/**
 * @param {object[]} groups - The groups, each valid on its own.
 * @returns {string|null} An error naming the first group whose columns push the total past the grid; null when the
 *     total fits.
 */
function firstColumnTotalError(groups) {
    let columnTotal = 0;
    for (let groupIndex = 0; groupIndex < groups.length; groupIndex++) {
        columnTotal += groups[groupIndex].columns;
        if (columnTotal > COCKPIT_GRID_COLUMNS)
            return `groups[${groupIndex}].columns: columns total ${columnTotal} exceeds ${COCKPIT_GRID_COLUMNS}`;
    }
    return null;
}

/**
 * @param {object} config - A config that passed firstConfigError.
 * @returns {CockpitLayout} The layout, built field by field so no unknown key is carried along.
 */
function buildLayout(config) {
    const monitor = isPlainObject(config.monitor) ? config.monitor : {};
    return {
        monitor: {vendor: stringOrNull(monitor.vendor), product: stringOrNull(monitor.product)},
        groups: config.groups.map(({id, caption, columns, cards}) => ({id, caption, columns, cards: [...cards]})),
    };
}
