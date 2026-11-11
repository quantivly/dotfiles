// What the sampler service (service/) and the extension's client say to each other on the session bus: the names,
// the interface, and the JSON in its two strings. Pure: no Gio and no Shell import, so both sides load it, and it runs
// under plain gjs.
//
// Version skew is the normal state: after a deploy the service restarts with new code, while the shell keeps the
// extension it loaded at login. So within ResourcePulse1 the JSON is additive only, and the parsers here are the
// reader's half of that promise:
// - a field the reader does not know is ignored, at any depth;
// - a field that is missing, or not of its type, is null for that field alone, so only its own row shows no data;
//   out of its range is not of its type: a negative byte count or percentage, a history fraction outside 0–1, a
//   number JSON could only read as infinite, a sequence past 2^53;
// - a history longer than CARD_HISTORY_SAMPLES keeps its newest values, as the client's ring buffer would;
// - text that is not JSON, or JSON that is not an object, parses to null as a whole.
// A breaking change needs a new interface, ResourcePulse2, served beside this one.
import {CARD_HISTORY_SAMPLES} from './constants.js';
import {
    booleanOrNull, countOrNull, finiteNumberOrNull, fractionOrNull, isPlainObject, nonNegativeNumberOrNull, parseJsonObject,
    stringOrNull,
} from './jsonFields.js';

/** The `protocol` field of GetState's JSON. Within ResourcePulse1 it stays 1: changes there are additive. */
export const PROTOCOL_VERSION = 1;
/** The well-known session bus name the service owns. */
export const RESOURCE_PULSE_BUS_NAME = 'io.github.quantivly.dotfiles.ResourcePulse1';
/** The D-Bus interface; it carries the same name as the bus name. */
export const RESOURCE_PULSE_INTERFACE_NAME = RESOURCE_PULSE_BUS_NAME;
/** Where the service exports its one object. */
export const RESOURCE_PULSE_OBJECT_PATH = '/io/github/quantivly/dotfiles/ResourcePulse1';
/** The method a client calls for the whole state, once connected. */
export const GET_STATE_METHOD_NAME = 'GetState';
/** The method a client calls while its card is visible or its dropdown open. */
export const WATCH_DETAIL_METHOD_NAME = 'WatchDetail';
/** The method that ends one WatchDetail. */
export const UNWATCH_DETAIL_METHOD_NAME = 'UnwatchDetail';
/** The signal the service sends once per publish. */
export const SAMPLE_SIGNAL_NAME = 'Sample';
/** The Sample signal's parameters as a GLib.Variant type: one string, the sample JSON. */
export const SAMPLE_SIGNAL_SIGNATURE = '(s)';
/**
 * The interface, for Gio.DBusExportedObject.wrapJSObject on the service side; the client (serviceLink.js) calls and
 * subscribes by the names above:
 * - GetState() → s: the state JSON (buildStatePayload), for a client that has just connected, and for gnome-status;
 * - WatchDetail() and UnwatchDetail(): a caller holds a detail watch while its card is visible or its dropdown open;
 *   the service counts them per caller and drops a caller's watches when its connection closes;
 * - Sample(s): the sample JSON (buildSamplePayload), once per publish.
 */
export const RESOURCE_PULSE_INTERFACE_XML = `<node>
  <interface name="${RESOURCE_PULSE_INTERFACE_NAME}">
    <method name="${GET_STATE_METHOD_NAME}">
      <arg name="state" type="s" direction="out"/>
    </method>
    <method name="${WATCH_DETAIL_METHOD_NAME}"/>
    <method name="${UNWATCH_DETAIL_METHOD_NAME}"/>
    <signal name="${SAMPLE_SIGNAL_NAME}">
      <arg name="sample" type="s"/>
    </signal>
  </interface>
</node>`;

// The fields each part of a snapshot or sample is read with, in the order the parsed result lists them.
const CPU_CLUSTER_FIELDS = ['performancePercent', 'efficiencyPercent'];
const MEMORY_FIELDS = ['usedBytes', 'totalBytes'];
const SWAP_FIELDS = ['zramUsedBytes', 'zramRamBytes', 'diskBytes'];
const PRESSURE_FIELDS = ['cpu', 'memory', 'io'];
const APPENDED_HISTORY_FIELDS = ['cpu', 'memory'];
const TOP_CPU_VALUE_FIELD = 'cpuPercent';
const TOP_MEMORY_VALUE_FIELD = 'memoryBytes';

/**
 * @typedef {object} Histories
 * @property {Array<number|null>|null} cpu - CPU busy fractions 0–1, null for a gap, oldest first (up to
 *     CARD_HISTORY_SAMPLES); null as a whole when the payload has none.
 * @property {Array<number|null>|null} memory - Memory used fractions, in the same shape.
 */

/**
 * @typedef {object} AppendedHistory
 * @property {number|null} cpu - The CPU busy fraction one fast tick appended; null for a gap.
 * @property {number|null} memory - The memory used fraction it appended; null for a gap.
 */

/**
 * The JSON GetState returns: everything a client needs to draw from scratch.
 *
 * The top-level numbers (protocol, the two times and the sequence) are written before the snapshot on purpose:
 * gnome-status reads them out of gdbus's text with a pattern, from the part before "snapshot" only, so a field of the
 * same name nested in the snapshot is never mistaken for one of them.
 *
 * @param {object} state - The service's state.
 * @param {object|null} state.snapshot - The latest snapshot (service/sampler.js's Snapshot), or null before the first.
 * @param {{cpu: Array<number|null>, memory: Array<number|null>}} state.histories - Both histories, oldest first.
 * @param {number} state.serviceStartedAtUsec - Real time the service started, in microseconds.
 * @param {number|null} [state.latestSampledAtUsec] - Real time of the latest publish (its Sample's sampledAtUsec), in
 *     microseconds; null before the first. Real time, unlike the snapshot's monotonic takenAtUsec, so a shell outside
 *     the service can tell the age of the last sample.
 * @param {number} state.sequence - The sequence of the latest Sample sent; 0 before the first.
 * @returns {string} The JSON, with `protocol` set to PROTOCOL_VERSION.
 */
export function buildStatePayload({snapshot, histories, serviceStartedAtUsec, latestSampledAtUsec = null, sequence}) {
    return JSON.stringify({
        protocol: PROTOCOL_VERSION,
        serviceStartedAtUsec,
        latestSampledAtUsec,
        sequence,
        snapshot,
        histories: {cpu: histories.cpu, memory: histories.memory},
    });
}

/**
 * The JSON of one Sample signal.
 *
 * @param {object} sample - One publish.
 * @param {object} sample.snapshot - The snapshot published.
 * @param {AppendedHistory|null} sample.appendedHistory - What a fast tick appended to the histories; null for a
 *     publish that appended nothing (a watch start's reveal), which the client must not append.
 * @param {number} sample.sequence - 1 for the service run's first Sample, one more for each after it.
 * @param {number} sample.sampledAtUsec - Real time of the publish, in microseconds.
 * @returns {string} The JSON.
 */
export function buildSamplePayload({snapshot, appendedHistory, sequence, sampledAtUsec}) {
    return JSON.stringify({sequence, sampledAtUsec, snapshot, appendedHistory});
}

/**
 * Reads GetState's JSON, skew-tolerantly (see the file header). latestSampledAtUsec is optional: a service from before
 * it existed sends none, which reads as null like any other missing field.
 *
 * @param {*} text - The JSON text.
 * @returns {{protocol: number|null, snapshot: object|null, histories: Histories, serviceStartedAtUsec: number|null,
 *     latestSampledAtUsec: number|null, sequence: number|null}|null} The state, or null for text that is not a JSON
 *     object.
 */
export function parseStatePayload(text) {
    const payload = parseJsonObject(text);
    if (payload === null)
        return null;
    return {
        protocol: countOrNull(payload.protocol),
        snapshot: parseSnapshot(payload.snapshot),
        histories: parseHistories(payload.histories),
        serviceStartedAtUsec: finiteNumberOrNull(payload.serviceStartedAtUsec),
        latestSampledAtUsec: finiteNumberOrNull(payload.latestSampledAtUsec),
        sequence: countOrNull(payload.sequence),
    };
}

/**
 * Reads a Sample's small fields and leaves its snapshot unread, so a client that does not show the snapshot on this
 * tick never pays for parsing it. Skew-tolerant (see the file header).
 *
 * @param {*} text - The JSON text.
 * @returns {{sequence: number|null, sampledAtUsec: number|null, appendedHistory: AppendedHistory|null,
 *     rawSnapshot: *}|null} The envelope, or null for text that is not a JSON object. A missing or mistyped
 *     appendedHistory is null, like a reveal's: the client appends nothing for it. rawSnapshot is the payload's
 *     `snapshot` value as parsed from JSON, for parseEnvelopeSnapshot.
 */
export function parseSampleEnvelope(text) {
    const payload = parseJsonObject(text);
    if (payload === null)
        return null;
    return {
        sequence: countOrNull(payload.sequence),
        sampledAtUsec: finiteNumberOrNull(payload.sampledAtUsec),
        appendedHistory: parseAppendedHistory(payload.appendedHistory),
        rawSnapshot: payload.snapshot,
    };
}

/**
 * Reads the snapshot an envelope carried, skew-tolerantly: the second step of reading a Sample.
 *
 * @param {*} rawSnapshot - A parseSampleEnvelope result's rawSnapshot.
 * @returns {object|null} The snapshot, field by field as parseStatePayload reads GetState's; null unless an object.
 */
export function parseEnvelopeSnapshot(rawSnapshot) {
    return parseSnapshot(rawSnapshot);
}

/**
 * Reads a Sample's JSON, skew-tolerantly (see the file header): parseSampleEnvelope, then parseEnvelopeSnapshot on
 * the envelope's snapshot.
 *
 * @param {*} text - The JSON text.
 * @returns {{snapshot: object|null, appendedHistory: AppendedHistory|null, sequence: number|null,
 *     sampledAtUsec: number|null}|null} The sample, or null for text that is not a JSON object. A missing or
 *     mistyped appendedHistory is null, like a reveal's: the client appends nothing for it.
 */
export function parseSamplePayload(text) {
    const envelope = parseSampleEnvelope(text);
    if (envelope === null)
        return null;
    return {
        snapshot: parseEnvelopeSnapshot(envelope.rawSnapshot),
        appendedHistory: envelope.appendedHistory,
        sequence: envelope.sequence,
        sampledAtUsec: envelope.sampledAtUsec,
    };
}

/**
 * Reads an object whose every listed field must be a byte count, as one value: memory or swap is no use in part.
 *
 * @param {*} value - A parsed JSON value.
 * @param {string[]} fieldNames - The fields, in the order the result lists them.
 * @returns {object|null} Those fields; null unless the value is an object holding a finite number of zero or more
 *     in each.
 */
function parseAllByteCounts(value, fieldNames) {
    if (!isPlainObject(value) || !fieldNames.every(fieldName => nonNegativeNumberOrNull(value[fieldName]) !== null))
        return null;
    return Object.fromEntries(fieldNames.map(fieldName => [fieldName, value[fieldName]]));
}

/**
 * Reads an object whose listed fields are each a number or null, field by field.
 *
 * @param {*} value - A parsed JSON value.
 * @param {string[]} fieldNames - The fields, in the order the result lists them.
 * @param {(fieldValue: *) => number|null} readNumber - Reads one field: nonNegativeNumberOrNull or fractionOrNull.
 * @returns {object|null} Each field as readNumber gives it; null unless the value is an object.
 */
function parseEachNumber(value, fieldNames, readNumber) {
    if (!isPlainObject(value))
        return null;
    return Object.fromEntries(fieldNames.map(fieldName => [fieldName, readNumber(value[fieldName])]));
}

/**
 * Reads one entry of an app ranking: a group key, a name and a value, all needed to show it.
 *
 * @param {*} value - A parsed JSON value.
 * @param {string} valueFieldName - 'cpuPercent' or 'memoryBytes'.
 * @returns {object|null} {groupKey, name, <valueFieldName>}; null unless all three are of their types, the value
 *     zero or more.
 */
function parseRankedApp(value, valueFieldName) {
    if (!isPlainObject(value))
        return null;
    const groupKey = stringOrNull(value.groupKey);
    const name = stringOrNull(value.name);
    const rankedValue = nonNegativeNumberOrNull(value[valueFieldName]);
    if (groupKey === null || name === null || rankedValue === null)
        return null;
    return {groupKey, name, [valueFieldName]: rankedValue};
}

/**
 * Reads a ranked list of apps.
 *
 * @param {*} value - A parsed JSON value.
 * @param {string} valueFieldName - The field each entry carries its value in.
 * @returns {Array<object>|null} The entries parseRankedApp accepts, in order; null unless the value is an array
 *     (so a service from before the rankings reads as no list).
 */
function parseRankedAppList(value, valueFieldName) {
    if (!Array.isArray(value))
        return null;
    return value.map(entry => parseRankedApp(entry, valueFieldName)).filter(entry => entry !== null);
}

/**
 * Reads an app ranking.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {{topCpu: object|null, topMemory: object|null, cpuRanking: Array<object>|null,
 *     memoryRanking: Array<object>|null}|null} Each part on its own; null unless an object.
 */
function parseAppRanking(value) {
    if (!isPlainObject(value))
        return null;
    return {
        topCpu: parseRankedApp(value.topCpu, TOP_CPU_VALUE_FIELD),
        topMemory: parseRankedApp(value.topMemory, TOP_MEMORY_VALUE_FIELD),
        cpuRanking: parseRankedAppList(value.cpuRanking, TOP_CPU_VALUE_FIELD),
        memoryRanking: parseRankedAppList(value.memoryRanking, TOP_MEMORY_VALUE_FIELD),
    };
}

/**
 * Reads a snapshot (service/sampler.js's Snapshot) field by field, in that typedef's order.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {object|null} The snapshot, each field of its type or null; null unless the value is an object.
 */
function parseSnapshot(value) {
    if (!isPlainObject(value))
        return null;
    return {
        takenAtUsec: finiteNumberOrNull(value.takenAtUsec),
        takenAtClockLabel: stringOrNull(value.takenAtClockLabel),
        cpuBusyPercent: nonNegativeNumberOrNull(value.cpuBusyPercent),
        cpuClusters: parseEachNumber(value.cpuClusters, CPU_CLUSTER_FIELDS, nonNegativeNumberOrNull),
        memory: parseAllByteCounts(value.memory, MEMORY_FIELDS),
        swap: parseAllByteCounts(value.swap, SWAP_FIELDS),
        pressureAvg10: parseEachNumber(value.pressureAvg10, PRESSURE_FIELDS, nonNegativeNumberOrNull),
        apps: parseAppRanking(value.apps),
        isComplete: booleanOrNull(value.isComplete),
    };
}

/**
 * Reads one history: a list of fractions, where anything not a fraction from 0 to 1 is a gap, so the list keeps its
 * length. A list longer than CARD_HISTORY_SAMPLES keeps its newest values.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {Array<number|null>|null} The values, oldest first; null unless the value is an array.
 */
function parseHistoryValues(value) {
    return Array.isArray(value) ? value.slice(-CARD_HISTORY_SAMPLES).map(fractionOrNull) : null;
}

/**
 * Reads both histories.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {Histories} Both, always an object; each null when missing or not a list.
 */
function parseHistories(value) {
    const histories = isPlainObject(value) ? value : {};
    return {cpu: parseHistoryValues(histories.cpu), memory: parseHistoryValues(histories.memory)};
}

/**
 * Reads what one Sample appended.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {AppendedHistory|null} Each fraction from 0 to 1, or a gap; null (append nothing) unless the value is an
 *     object.
 */
function parseAppendedHistory(value) {
    return parseEachNumber(value, APPENDED_HISTORY_FIELDS, fractionOrNull);
}
