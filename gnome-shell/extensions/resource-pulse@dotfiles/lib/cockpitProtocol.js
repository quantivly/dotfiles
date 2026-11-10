// What the cockpit service (service/cockpit.js) and the extension's cockpit client say to each other on the session
// bus: the names, the interface, and the JSON in its strings. Pure: no Gio and no Shell import, so both sides load it,
// and it runs under plain gjs.
//
// The secrets allowlist is enforced here, once. A panel may only draw typed fields the service chose (an enum, a
// number, an id, a short name), never free text from another program. So every builder runs each source object and
// the layout through the same reader its parser uses before it stringifies: a field no reader lists never leaves the
// service, whatever a source module put in its object.
//
// Version skew is the normal state, as in lib/protocol.js: after a deploy the service restarts with new code, while
// the shell keeps the extension it loaded at login. So within Cockpit1 the JSON is additive only, and the parsers are
// the reader's half of that promise:
// - a field the reader does not know is ignored, at any depth;
// - a field that is missing, or not of its type, is null for that field alone, so only its own row shows no data;
// - a list entry without what identifies and names it (a session row, a mount row, a layout group) is dropped, and
//   the rest of the list kept;
// - an id longer than COCKPIT_ID_MAX_CHARS reads as null, and a mount row whose mount point is longer than
//   COCKPIT_PATH_MAX_CHARS is dropped;
// - text that is not JSON, or JSON that is not an object, parses to null as a whole.
// A breaking change needs a new interface, Cockpit2, served beside this one.
import {COCKPIT_ID_MAX_CHARS, COCKPIT_PATH_MAX_CHARS} from './constants.js';
import {
    booleanOrNull, countOrNull, enumOrNull, finiteNumberOrNull, isPlainObject, nonNegativeNumberOrNull, parseJsonObject,
    stringOrNull,
} from './jsonFields.js';

/** The `protocol` field of GetState's JSON. Within Cockpit1 it stays 1: changes there are additive. */
export const COCKPIT_PROTOCOL_VERSION = 1;
/** The well-known session bus name the cockpit service owns. */
export const COCKPIT_BUS_NAME = 'io.github.quantivly.dotfiles.Cockpit1';
/** The D-Bus interface; it carries the same name as the bus name. */
export const COCKPIT_INTERFACE_NAME = COCKPIT_BUS_NAME;
/** Where the cockpit service exports its one object. */
export const COCKPIT_OBJECT_PATH = '/io/github/quantivly/dotfiles/Cockpit1';
/** The method a client calls for the whole state, once connected. */
export const COCKPIT_GET_STATE_METHOD_NAME = 'GetState';
/** The method a client calls while the cockpit monitor is visible. */
export const COCKPIT_WATCH_METHOD_NAME = 'WatchCockpit';
/** The method that ends one WatchCockpit. */
export const COCKPIT_UNWATCH_METHOD_NAME = 'UnwatchCockpit';
/** The method a click on a session row calls, to bring that session's herdr pane to the front. */
export const COCKPIT_FOCUS_SESSION_METHOD_NAME = 'FocusSession';
/** The signal the service sends when a source or the layout changes, never on a timer with nothing new. */
export const COCKPIT_CHANGED_SIGNAL_NAME = 'Changed';
/** The Changed signal's parameters as a GLib.Variant type: one string, the changed JSON. */
export const COCKPIT_CHANGED_SIGNAL_SIGNATURE = '(s)';
/**
 * The interface, for Gio.DBusExportedObject.wrapJSObject on the service side and a proxy on the client side:
 * - GetState() → s: the state JSON (buildCockpitStatePayload), for a client that has just connected, and for
 *   gnome-status;
 * - WatchCockpit() and UnwatchCockpit(): a caller holds a watch while the cockpit monitor is visible; the service
 *   counts them per caller and drops a caller's watches when its connection closes;
 * - FocusSession(s sessionId) → s: the reply JSON (buildFocusSessionReply) for focusing one session row's pane,
 *   its error a code from COCKPIT_FOCUS_ERROR_CODES;
 * - Changed(s): the changed JSON (buildChangedPayload), once per change.
 */
export const COCKPIT_INTERFACE_XML = `<node>
  <interface name="${COCKPIT_INTERFACE_NAME}">
    <method name="${COCKPIT_GET_STATE_METHOD_NAME}">
      <arg name="state" type="s" direction="out"/>
    </method>
    <method name="${COCKPIT_WATCH_METHOD_NAME}"/>
    <method name="${COCKPIT_UNWATCH_METHOD_NAME}"/>
    <method name="${COCKPIT_FOCUS_SESSION_METHOD_NAME}">
      <arg name="sessionId" type="s" direction="in"/>
      <arg name="reply" type="s" direction="out"/>
    </method>
    <signal name="${COCKPIT_CHANGED_SIGNAL_NAME}">
      <arg name="changed" type="s"/>
    </signal>
  </interface>
</node>`;
/** What a session row's `state` may hold, and the keys of the sessions source's `counts`, in this order. */
export const SESSION_STATES = ['working', 'blocked', 'idle', 'done', 'unknown'];
/** What the network source's `uplink.kind` may hold. */
export const UPLINK_KINDS = ['wired', 'wifi', 'none'];
/** What the network source's `uplink.connectivity` may hold: NetworkManager's connectivity states, by name. */
export const CONNECTIVITY_STATES = ['full', 'limited', 'portal', 'none', 'unknown'];
/** What a mount row's `kind` may hold. */
export const MOUNT_KINDS = ['network', 'removable'];
/**
 * What a FocusSession reply's `error` may hold, by name: a short code, never another program's text (ruling R18).
 * - UNKNOWN_SESSION: no session row of the latest sessions sample carries the id;
 * - NO_PANE: the row names no herdr pane, so there is nothing to focus;
 * - HERDR_REJECTED: herdr answered with an error or a malformed reply, or closed the connection without one;
 * - HERDR_UNREACHABLE: no herdr socket, a refused connection, or no reply in time;
 * - INTERNAL: a fault in the cockpit service itself.
 */
export const COCKPIT_FOCUS_ERROR = Object.freeze({
    UNKNOWN_SESSION: 'unknown-session',
    NO_PANE: 'no-pane',
    HERDR_REJECTED: 'herdr-rejected',
    HERDR_UNREACHABLE: 'herdr-unreachable',
    INTERNAL: 'internal',
});
/** Every code a FocusSession reply's `error` may hold; the reader reads any other value as null. */
export const COCKPIT_FOCUS_ERROR_CODES = Object.freeze(Object.values(COCKPIT_FOCUS_ERROR));

/** Each source's reader, in the order the JSON lists the sources. The one place a source is tied to its reader. */
const SOURCE_READERS_BY_NAME = {
    sessions: parseSessionsSource,
    network: parseNetworkSource,
    mounts: parseMountsSource,
};
/** The sources Cockpit1 carries, in the order the JSON lists them: sessions, network, mounts. */
export const COCKPIT_SOURCE_NAMES = Object.keys(SOURCE_READERS_BY_NAME);

/**
 * @typedef {object} CockpitState
 * @property {number|null} serviceStartedAtUsec - Real time the service started, in microseconds.
 * @property {number|null} latestPublishedAtUsec - Real time of the latest Changed, in microseconds; null before the
 *     first.
 * @property {object|null} layout - The layout (parseLayout's shape); null when there is none.
 * @property {string|null} configError - Why the layout config could not be read; null when it could.
 * @property {{sessions: object|null, network: object|null, mounts: object|null}} sources - Each source as its reader
 *     gives it; null for a source with no data.
 */

/**
 * The JSON GetState returns: everything a client needs to draw from scratch. Each source and the layout go through
 * their readers first, so a field no reader lists is not written.
 *
 * The top-level numbers (protocol and the two times) are written before the layout and the sources on purpose:
 * gnome-status reads them out of gdbus's text with a pattern, from the part before "sources" only, so a field of the
 * same name nested in a source is never mistaken for one of them.
 *
 * @param {object} state - The service's state.
 * @param {object|null} state.layout - The layout read from the config; null when there is none.
 * @param {string|null} state.configError - Why the config could not be read; null when it could.
 * @param {object} state.sources - Each source's latest object by name (COCKPIT_SOURCE_NAMES); a missing one is null.
 * @param {number} state.serviceStartedAtUsec - Real time the service started, in microseconds.
 * @param {number|null} state.latestPublishedAtUsec - Real time of the latest Changed, in microseconds; null before
 *     the first.
 * @returns {string} The JSON, with `protocol` set to COCKPIT_PROTOCOL_VERSION.
 */
export function buildCockpitStatePayload(state) {
    return JSON.stringify({protocol: COCKPIT_PROTOCOL_VERSION, ...readCockpitState(state)});
}

/**
 * The JSON of one Changed signal: the sources that changed, and the layout with its error when the layout changed.
 * Each goes through its reader first, so a field no reader lists is not written.
 *
 * @param {object} changed - One change.
 * @param {number} changed.publishedAtUsec - Real time of the publish, in microseconds.
 * @param {object} changed.sources - The changed sources' new objects by name; a source left out did not change.
 * @param {object|null} [changed.layout] - The new layout, given only when the layout changed (null when there is
 *     none now).
 * @param {string|null} [changed.configError] - The new config error, given with the layout.
 * @returns {string} The JSON; it holds `layout` and `configError` only when either was given.
 */
export function buildChangedPayload({publishedAtUsec, sources, layout, configError}) {
    const readChange = readChanged({publishedAtUsec, sources, layout, configError});
    const isLayoutChange = layout !== undefined || configError !== undefined;
    const layoutFields = isLayoutChange ? {layout: readChange.layout, configError: readChange.configError} : {};
    return JSON.stringify({publishedAtUsec: readChange.publishedAtUsec, ...layoutFields, sources: readChange.sources});
}

/**
 * The JSON FocusSession answers. Its error goes through the reader too, so only a code from
 * COCKPIT_FOCUS_ERROR_CODES is written; any other text is written as null.
 *
 * @param {object} reply - What focusing found.
 * @param {boolean|null} reply.focused - Whether herdr focused the session's pane.
 * @param {number|null} reply.windowPid - The process of the herdr client's window; null when not known (focused in
 *     herdr, window unknown).
 * @param {string|null} reply.error - Why focusing failed, a code from COCKPIT_FOCUS_ERROR_CODES; null when it did
 *     not.
 * @returns {string} The JSON.
 */
export function buildFocusSessionReply(reply) {
    return JSON.stringify(readFocusSessionReply(reply));
}

/**
 * Reads GetState's JSON, skew-tolerantly (see the file header).
 *
 * @param {*} text - The JSON text.
 * @returns {({protocol: number|null} & CockpitState)|null} The state, or null for text that is not a JSON object.
 */
export function parseCockpitStatePayload(text) {
    const payload = parseJsonObject(text);
    if (payload === null)
        return null;
    return {protocol: countOrNull(payload.protocol), ...readCockpitState(payload)};
}

/**
 * Reads a Changed signal's JSON, skew-tolerantly (see the file header).
 *
 * @param {*} text - The JSON text.
 * @returns {{publishedAtUsec: number|null, sources: object, layout: object|null, configError: string|null}|null} The
 *     change, or null for text that is not a JSON object. `sources` holds only the sources the JSON names; `layout`
 *     and `configError` are null when the JSON carries none (the layout did not change).
 */
export function parseChangedPayload(text) {
    const payload = parseJsonObject(text);
    return payload === null ? null : readChanged(payload);
}

/**
 * Reads FocusSession's reply JSON, skew-tolerantly (see the file header).
 *
 * @param {*} text - The JSON text.
 * @returns {{focused: boolean|null, windowPid: number|null, error: string|null}|null} The reply, each field null when
 *     missing or mistyped, and `error` null unless a code from COCKPIT_FOCUS_ERROR_CODES; null for text that is not a
 *     JSON object.
 */
export function parseFocusSessionReply(text) {
    const payload = parseJsonObject(text);
    return payload === null ? null : readFocusSessionReply(payload);
}

/**
 * Reads the sessions source: the herdr panes running Claude.
 *
 * @param {*} value - A parsed JSON value, or the object a source module built.
 * @returns {{sampledAtUsec: number|null, intervalSeconds: number|null, herdrRunning: boolean|null,
 *     totalMemoryBytes: number|null, counts: object|null, rows: Array<object>|null}|null} The source; null unless the
 *     value is an object. `counts` has one count per SESSION_STATES entry, in that order; `rows` keeps the rows
 *     parseSessionRow accepts.
 */
export function parseSessionsSource(value) {
    if (!isPlainObject(value))
        return null;
    return {
        ...parseSourceTiming(value),
        herdrRunning: booleanOrNull(value.herdrRunning),
        totalMemoryBytes: nonNegativeNumberOrNull(value.totalMemoryBytes),
        counts: parseSessionStateCounts(value.counts),
        rows: parseAcceptedEntries(value.rows, parseSessionRow),
    };
}

/**
 * Reads the network source: the uplink, the VPN tunnel and the SSH control masters.
 *
 * @param {*} value - A parsed JSON value, or the object a source module built.
 * @returns {{sampledAtUsec: number|null, intervalSeconds: number|null,
 *     uplink: {kind: string|null, connectivity: string|null, wifiEnabled: boolean|null}|null,
 *     vpn: {isUp: boolean|null, interfaceName: string|null}|null, sshMasterCount: number|null}|null} The source;
 *     null unless the value is an object. `uplink` and `vpn` are each null unless an object.
 */
export function parseNetworkSource(value) {
    if (!isPlainObject(value))
        return null;
    return {
        ...parseSourceTiming(value),
        uplink: parseUplink(value.uplink),
        vpn: parseVpnTunnel(value.vpn),
        sshMasterCount: countOrNull(value.sshMasterCount),
    };
}

/**
 * Reads the mounts source: the network and removable mounts.
 *
 * @param {*} value - A parsed JSON value, or the object a source module built.
 * @returns {{sampledAtUsec: number|null, intervalSeconds: number|null, rows: Array<object>|null}|null} The source;
 *     null unless the value is an object. `rows` keeps the rows parseMountRow accepts.
 */
export function parseMountsSource(value) {
    if (!isPlainObject(value))
        return null;
    return {...parseSourceTiming(value), rows: parseAcceptedEntries(value.rows, parseMountRow)};
}

/**
 * Reads the layout: which monitor the cockpit draws on, and its groups of cards.
 *
 * @param {*} value - A parsed JSON value, or the layout lib/cockpitConfig.js read.
 * @returns {{monitor: {vendor: string|null, product: string|null},
 *     groups: Array<{id: string, caption: string, columns: number, cards: string[]}>}|null} The layout; null unless
 *     the value is an object with a `groups` list (a layout without groups draws nothing). A missing or mistyped
 *     monitor reads as both fields null; a group without an id, a caption, a whole number of columns or a list of
 *     card ids that are all strings is dropped.
 */
export function parseLayout(value) {
    if (!isPlainObject(value) || !Array.isArray(value.groups))
        return null;
    return {monitor: parseMonitorRule(value.monitor), groups: parseAcceptedEntries(value.groups, parseLayoutGroup)};
}

/**
 * Reads the fields GetState's JSON and the state the builder is given share, so both go through the same readers.
 *
 * @param {object} state - The state to read: a parsed payload, or the service's state.
 * @returns {CockpitState} Every field of its type or null; `sources` always an object.
 */
function readCockpitState(state) {
    return {
        serviceStartedAtUsec: finiteNumberOrNull(state.serviceStartedAtUsec),
        latestPublishedAtUsec: finiteNumberOrNull(state.latestPublishedAtUsec),
        layout: parseLayout(state.layout),
        configError: stringOrNull(state.configError),
        sources: parseNamedSources(state.sources, COCKPIT_SOURCE_NAMES),
    };
}

/**
 * Reads the fields a Changed's JSON and the change the builder is given share.
 *
 * @param {object} changed - The change to read: a parsed payload, or the service's change.
 * @returns {{publishedAtUsec: number|null, sources: object, layout: object|null, configError: string|null}} Every
 *     field of its type or null; `sources` holds only the known sources the change names.
 */
function readChanged(changed) {
    const sources = isPlainObject(changed.sources) ? changed.sources : {};
    const changedSourceNames = COCKPIT_SOURCE_NAMES.filter(sourceName => Object.hasOwn(sources, sourceName));
    return {
        publishedAtUsec: finiteNumberOrNull(changed.publishedAtUsec),
        sources: parseNamedSources(sources, changedSourceNames),
        layout: parseLayout(changed.layout),
        configError: stringOrNull(changed.configError),
    };
}

/**
 * Reads a FocusSession reply's fields.
 *
 * @param {object} reply - The reply to read: a parsed payload, or the service's reply.
 * @returns {{focused: boolean|null, windowPid: number|null, error: string|null}} Each field of its type or null;
 *     `error` a code from COCKPIT_FOCUS_ERROR_CODES or null, so no other program's text passes.
 */
function readFocusSessionReply(reply) {
    return {
        focused: booleanOrNull(reply.focused),
        windowPid: countOrNull(reply.windowPid),
        error: enumOrNull(reply.error, COCKPIT_FOCUS_ERROR_CODES),
    };
}

/**
 * Reads the named sources of an object, each through its own reader.
 *
 * @param {*} value - A parsed JSON value: the object holding the sources by name.
 * @param {string[]} sourceNames - The sources to read, from COCKPIT_SOURCE_NAMES, in the order the result lists them.
 * @returns {object} Each named source as its reader gives it (null when missing or not an object); a value that is
 *     not an object reads as every named source missing.
 */
function parseNamedSources(value, sourceNames) {
    const sources = isPlainObject(value) ? value : {};
    return Object.fromEntries(sourceNames.map(sourceName =>
        [sourceName, SOURCE_READERS_BY_NAME[sourceName](sources[sourceName])]));
}

/**
 * Reads the two fields every source carries, so a client can tell when one has gone stale.
 *
 * @param {object} source - A source object.
 * @returns {{sampledAtUsec: number|null, intervalSeconds: number|null}} Real time of the source's latest sample in
 *     microseconds, and the seconds between its samples.
 */
function parseSourceTiming(source) {
    return {
        sampledAtUsec: finiteNumberOrNull(source.sampledAtUsec),
        intervalSeconds: countOrNull(source.intervalSeconds),
    };
}

/**
 * Reads a list, keeping the entries its reader accepts.
 *
 * @param {*} value - A parsed JSON value.
 * @param {(entry: *) => object|null} parseEntry - Reads one entry; null drops it.
 * @returns {Array<object>|null} The accepted entries, in order; null unless the value is an array.
 */
function parseAcceptedEntries(value, parseEntry) {
    if (!Array.isArray(value))
        return null;
    return value.map(entry => parseEntry(entry)).filter(entry => entry !== null);
}

/**
 * Reads the sessions source's counts by state.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {object|null} One count per SESSION_STATES entry, in that order, each null when missing or mistyped; null
 *     unless the value is an object.
 */
function parseSessionStateCounts(value) {
    if (!isPlainObject(value))
        return null;
    return Object.fromEntries(SESSION_STATES.map(sessionState => [sessionState, countOrNull(value[sessionState])]));
}

/**
 * Reads one session row: a herdr pane running Claude. Its id, name and state are needed to show it at all. An empty
 * id or name is never valid: FocusSession finds a row by its id, and a source publishes COCKPIT_REDACTED_NAME in place
 * of a name it rejects, never an empty one.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {{id: string, name: string, state: string, idleSeconds: number|null, idleFromProcessAge: boolean|null,
 *     memoryBytes: number|null, workspaceId: string|null, paneId: string|null, account: string|null,
 *     contextPercent: number|null}|null} The row; null unless an object with a non-empty string id, a non-empty
 *     string name and a state from SESSION_STATES. `workspaceId` and `paneId` are null when longer than
 *     COCKPIT_ID_MAX_CHARS.
 */
function parseSessionRow(value) {
    if (!isPlainObject(value))
        return null;
    const id = nonEmptyStringOrNull(value.id);
    const name = nonEmptyStringOrNull(value.name);
    const state = enumOrNull(value.state, SESSION_STATES);
    if (id === null || name === null || state === null)
        return null;
    return {
        id,
        name,
        state,
        idleSeconds: countOrNull(value.idleSeconds),
        idleFromProcessAge: booleanOrNull(value.idleFromProcessAge),
        memoryBytes: nonNegativeNumberOrNull(value.memoryBytes),
        workspaceId: boundedStringOrNull(value.workspaceId, COCKPIT_ID_MAX_CHARS),
        paneId: boundedStringOrNull(value.paneId, COCKPIT_ID_MAX_CHARS),
        account: stringOrNull(value.account),
        contextPercent: nonNegativeNumberOrNull(value.contextPercent),
    };
}

/**
 * Reads the network source's uplink.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {{kind: string|null, connectivity: string|null, wifiEnabled: boolean|null}|null} `kind` from UPLINK_KINDS,
 *     `connectivity` from CONNECTIVITY_STATES, each null when missing or unlisted; null unless an object.
 */
function parseUplink(value) {
    if (!isPlainObject(value))
        return null;
    return {
        kind: enumOrNull(value.kind, UPLINK_KINDS),
        connectivity: enumOrNull(value.connectivity, CONNECTIVITY_STATES),
        wifiEnabled: booleanOrNull(value.wifiEnabled),
    };
}

/**
 * Reads the network source's VPN tunnel.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {{isUp: boolean|null, interfaceName: string|null}|null} Each field of its type or null; null unless an
 *     object.
 */
function parseVpnTunnel(value) {
    if (!isPlainObject(value))
        return null;
    return {isUp: booleanOrNull(value.isUp), interfaceName: stringOrNull(value.interfaceName)};
}

/**
 * Reads one mount row. Its mount point, label and kind are needed to show it at all.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {{mountPoint: string, label: string, kind: string, filesystemType: string|null, freeBytes: number|null,
 *     totalBytes: number|null}|null} The row; null unless an object with a string mount point of at most
 *     COCKPIT_PATH_MAX_CHARS characters, a string label and a kind from MOUNT_KINDS.
 */
function parseMountRow(value) {
    if (!isPlainObject(value))
        return null;
    const mountPoint = boundedStringOrNull(value.mountPoint, COCKPIT_PATH_MAX_CHARS);
    const label = stringOrNull(value.label);
    const kind = enumOrNull(value.kind, MOUNT_KINDS);
    if (mountPoint === null || label === null || kind === null)
        return null;
    return {
        mountPoint,
        label,
        kind,
        filesystemType: stringOrNull(value.filesystemType),
        freeBytes: nonNegativeNumberOrNull(value.freeBytes),
        totalBytes: nonNegativeNumberOrNull(value.totalBytes),
    };
}

/**
 * Reads the layout's monitor rule.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {{vendor: string|null, product: string|null}} Always an object; a field missing or mistyped, or the whole
 *     rule, reads as null (any monitor).
 */
function parseMonitorRule(value) {
    const monitorRule = isPlainObject(value) ? value : {};
    return {vendor: stringOrNull(monitorRule.vendor), product: stringOrNull(monitorRule.product)};
}

/**
 * Reads one layout group: a captioned block of the grid holding some cards.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {{id: string, caption: string, columns: number, cards: string[]}|null} The group; null unless an object
 *     with a string id, a string caption, a whole number of columns and a list of card ids that are all strings.
 */
function parseLayoutGroup(value) {
    if (!isPlainObject(value))
        return null;
    const id = stringOrNull(value.id);
    const caption = stringOrNull(value.caption);
    const columns = countOrNull(value.columns);
    const cards = parseStringList(value.cards);
    if (id === null || caption === null || columns === null || cards === null)
        return null;
    return {id, caption, columns, cards};
}

/**
 * @param {*} value - A parsed JSON value.
 * @returns {string|null} The value when it is a string of at least one character; null otherwise.
 */
function nonEmptyStringOrNull(value) {
    const text = stringOrNull(value);
    return text === '' ? null : text;
}

/**
 * @param {*} value - A parsed JSON value.
 * @param {number} maxChars - The most characters (code points, as lib/nameGuard.js counts them) the string may hold.
 * @returns {string|null} The value when it is a string of at most maxChars characters; null otherwise.
 */
function boundedStringOrNull(value, maxChars) {
    const text = stringOrNull(value);
    return text !== null && [...text].length <= maxChars ? text : null;
}

/**
 * Reads a list of strings, as one value: a list with anything else in it is no use.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {string[]|null} A copy of the list; null unless the value is an array of strings only.
 */
function parseStringList(value) {
    if (!Array.isArray(value) || !value.every(entry => stringOrNull(entry) !== null))
        return null;
    return [...value];
}
