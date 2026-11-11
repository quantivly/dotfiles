// The extension's client of the cockpit service (service/cockpit.js, run by systemd as cockpit.service) on the session
// bus, io.github.quantivly.dotfiles.Cockpit1: pulseClient.js's sibling, with the same mechanisms. It keeps what the
// cockpit's cards draw from (the layout, the config error and each source's latest object) and tells listeners what
// changed; it does no sampling, no file IO and no subprocess. Gio and GLib only (no Shell, St, Clutter or Meta), so it
// runs under plain gjs, and its link, StartUnit, unit read, connection, clocks and timeouts are all injectable.
//
// It runs inside gnome-shell, the compositor, so, as pulseClient.js:
// - every D-Bus call is asynchronous, with DBUS_CALL_TIMEOUT_MS, and none is ever synchronous;
// - every callback checks for destroy() before it touches anything, and destroy() cancels every pending call, removes
//   every timeout and disconnects every handler: GNOME 50 disables the extension, destroying this client, on every
//   lock and every blank;
// - nothing a timeout or a promise callback runs can throw out of it.
//
// How it follows the service (docs/superpowers/specs/2026-11-09-desktop-cockpit-design.md, "Lifecycle"):
// - start() asks systemd's user manager to start the unit (StartUnit, "replace"), on every start(), with
//   pulseClient.js's chain: a failure is retried after START_RETRY_DELAYS_SECONDS (5, 30, 300 s, then every 300 s);
//   the service appearing on the bus ends the chain.
// - The cockpit is optional, so a unit that is not there to run is "not configured", never a fault to retry (ruling
//   D4). The client is SKIPPED (the chain ends, with one info line and no warning; the cached layout is kept; the next
//   start(), the next enable, asks again, which is how a layout file created mid-session is picked up) in three
//   cases, each a first-class reading of "not configured":
//   - (a) StartUnit is rejected with org.freedesktop.systemd1.NoSuchUnit: no unit file is linked (./install never
//     ran);
//   - after an accepted StartUnit with no service on the bus within START_CONFIRMATION_TIMEOUT_SECONDS, the unit read
//     over systemd's D-Bus gives ConditionResult false, checked (ConditionTimestampMonotonic above 0, so by the job
//     just asked for: a unit never started also reads false, ruling R17): the layout file is absent;
//   - (b) in that same read, GetUnit answers NoSuchUnit after the accepted job: systemd has unloaded the skipped unit.
//   The client never depends on the unit staying loaded after a skipped job: loaded, its condition says skipped;
//   unloaded, (b) says the same. How often (b) happens is unmeasured until the deploy: it is up to systemd's garbage
//   collection, and the unit's PartOf=graphical-session.target points from the unit to the target, not the reverse.
//   Any other answer (a true or unchecked condition, a read that failed otherwise: a timeout, no systemd, another
//   error) counts as a failed attempt and is retried.
// - It follows the service through serviceLink.js (a name watch, a Changed subscription and plain calls to the
//   owner), never through a D-Bus proxy object, which would cost a forced garbage collection after every Changed
//   (docs/superpowers/specs/2026-11-10-resource-pulse-performance-design.md). The name watch is held from the
//   connection's arrival until destroy(); the Changed subscription only while it is wanted (setSubscriptionWanted:
//   while something of the cockpit can be seen), so a hidden cockpit is woken by no Changed at all.
// - It follows the bus name's owner. An owner appearing is asked GetState, wanted subscription or not (the layout
//   decides whether a cockpit layer exists at all, so the first read cannot wait for the layer to be seen), whose
//   answer makes the client LIVE and replaces its layout, config error and sources; a wanted subscription is made
//   first, and a wanted watch asserted again. An owner leaving makes it VANISHED and starts nothing: a service stopped
//   on purpose stays stopped, and a crash is systemd's Restart=. Its sources are kept, so the cards keep their "no
//   data since" times.
// - Wanting the subscription while an owner is there subscribes, then asks GetState: the state then covers every
//   Changed missed while unsubscribed, a restart included, and every Changed sent after that answer is delivered
//   (serviceLink.js's setSubscribed says why the order matters). Unwanting it unsubscribes; a GetState still on its
//   way is applied when it answers.
// - The layout is seeded from cachedLayout (the extension keeps the last one across enables), so the grid can be built
//   before the first answer. A layout event is told only when the layout or the config error changed.
// - Changed replaces the sources it carries and, when it carries one, the layout; a sources event names the sources
//   whose object changed. A Changed before any state from this owner asks for the state instead (it holds the change).
// - A sources event says what brought it (CockpitSourcesCause): a GetState the client asked for of itself (an owner's
//   appearance, the subscription becoming wanted, an early Changed), a Changed, or a pull. The extension draws the
//   first at once and paces the other two to its next Sample (ruling D20).
// - Staleness is decided by pulling, not by a timer (ruling R14): pullIfSuspicious(name) asks GetState once per
//   interval while lib/cockpitStaleness.js suspects a source, stamping when it asked and when the answer came; a pull
//   that answers the same old stamp makes the source stale. A GetState that fails completes the pull too (ruling D6),
//   so a service that keeps its name but hangs reads stale. With no owner a pull asks nobody and completes at once,
//   and an owner leaving while a pull waits completes that pull as a failed GetState does.
//   A source whose stamp changes, by any answer or Changed, has both pull stamps cleared (ruling D5): a refreshed
//   source starts a new suspicion cycle, and reads stale only after a pull of that cycle answers its new stamp. A stamp
//   that moved back (the wall clock stepped back) counts as a change too: the old pull stamps, taken on the old clock,
//   would otherwise make the new sample read stale at its first suspicion.
// - The watch: WatchCockpit and UnwatchCockpit go out only when the wanted flag changes, and only to an owner.
//   destroy() sends UnwatchCockpit, uncancellable and best-effort, while a watch is held: the shell's bus connection
//   outlives the extension, and the service drops a caller's watches only when its connection closes.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {
    CockpitClientEventType, CockpitClientState, CockpitSourcesCause, DBUS_CALL_TIMEOUT_MS, LOG_PREFIX,
    START_CONFIRMATION_TIMEOUT_SECONDS,
} from './lib/constants.js';
import {
    COCKPIT_BUS_NAME, COCKPIT_CHANGED_SIGNAL_NAME, COCKPIT_CHANGED_SIGNAL_SIGNATURE, COCKPIT_FOCUS_ERROR,
    COCKPIT_FOCUS_SESSION_METHOD_NAME, COCKPIT_GET_STATE_METHOD_NAME, COCKPIT_INTERFACE_NAME, COCKPIT_OBJECT_PATH,
    COCKPIT_SOURCE_NAMES, COCKPIT_UNWATCH_METHOD_NAME, COCKPIT_WATCH_METHOD_NAME, parseChangedPayload,
    parseCockpitStatePayload, parseFocusSessionReply,
} from './lib/cockpitProtocol.js';
import {sourceFreshness as decideSourceFreshness} from './lib/cockpitStaleness.js';
import {RateLimitedLogger, describeError} from './lib/errorLog.js';
import {runEveryStep} from './lib/teardown.js';
import {nextStartRetryDelaySeconds} from './lib/wiring.js';
import {createServiceLink} from './serviceLink.js';

// systemd's user manager on the session bus, and what the client asks of it.
const SYSTEMD_BUS_NAME = 'org.freedesktop.systemd1';
const SYSTEMD_OBJECT_PATH = '/org/freedesktop/systemd1';
const SYSTEMD_MANAGER_INTERFACE_NAME = 'org.freedesktop.systemd1.Manager';
const SYSTEMD_UNIT_INTERFACE_NAME = 'org.freedesktop.systemd1.Unit';
const DBUS_PROPERTIES_INTERFACE_NAME = 'org.freedesktop.DBus.Properties';
const START_UNIT_METHOD_NAME = 'StartUnit';
const GET_UNIT_METHOD_NAME = 'GetUnit';
const GET_PROPERTY_METHOD_NAME = 'Get';
/** The service's unit: systemd/cockpit.service, linked into the user's unit directory. */
const COCKPIT_UNIT_NAME = 'cockpit.service';
/** StartUnit's job mode: replace a conflicting queued job. Starting a unit that already runs changes nothing. */
const START_UNIT_MODE = 'replace';
/** StartUnit(s name, s mode) → (o job). */
const START_UNIT_PARAMETERS_SIGNATURE = '(ss)';
const START_UNIT_REPLY_SIGNATURE = '(o)';
/** GetUnit(s name) → (o unit): the unit's object, if systemd has it loaded. */
const GET_UNIT_PARAMETERS_SIGNATURE = '(s)';
const GET_UNIT_REPLY_SIGNATURE = '(o)';
/** Properties.Get(s interface, s property) → (v value). */
const GET_PROPERTY_PARAMETERS_SIGNATURE = '(ss)';
const GET_PROPERTY_REPLY_SIGNATURE = '(v)';
/** The unit's properties the skip check reads, each with systemd's type. */
const CONDITION_RESULT_PROPERTY = Object.freeze({name: 'ConditionResult', signature: 'b'});
const CONDITION_TIMESTAMP_MONOTONIC_PROPERTY = Object.freeze({name: 'ConditionTimestampMonotonic', signature: 't'});
const ACTIVE_STATE_PROPERTY = Object.freeze({name: 'ActiveState', signature: 's'});
/** What a unit read that failed gives: nothing known, which is no skip. */
const UNKNOWN_UNIT_CONDITION = Object.freeze({
    conditionResult: null, conditionTimestampMonotonic: null, activeState: null, isUnitMissing: false,
});
/** What a unit read gives when GetUnit answers NoSuchUnit: systemd has no such unit loaded, which is a skip. */
const MISSING_UNIT_CONDITION = Object.freeze({
    conditionResult: null, conditionTimestampMonotonic: null, activeState: null, isUnitMissing: true,
});
/** The D-Bus error systemd answers StartUnit and GetUnit with for a unit it has no file for, or has not loaded. */
const SYSTEMD_NO_SUCH_UNIT_ERROR_NAME = 'org.freedesktop.systemd1.NoSuchUnit';
// Why a client is SKIPPED, for its info line: each completes "cockpit.service <reason>".
const CONDITION_SKIP_REASON = 'was skipped by its start condition (no layout file)';
const UNIT_NOT_FOUND_SKIP_REASON = 'is unknown to systemd (no unit file is linked)';
const UNIT_UNLOADED_SKIP_REASON = 'is no longer loaded after its start job (systemd unloaded it once skipped)';
/** GetState → (s state); FocusSession(s sessionId) → (s reply). */
const STATE_REPLY_SIGNATURE = '(s)';
const FOCUS_SESSION_PARAMETERS_SIGNATURE = '(s)';
const FOCUS_SESSION_REPLY_SIGNATURE = '(s)';
/** No call asks the bus to activate a name: a name nobody owns fails the call at once. */
const CALL_FLAGS = Gio.DBusCallFlags.NO_AUTO_START;
/** GetState, WatchCockpit and UnwatchCockpit take no parameters. */
const NO_PARAMETERS = null;
/**
 * The cockpit as its link follows it (serviceLink.js): its Changed signal, unsubscribed at creation, since the client
 * subscribes only while the subscription is wanted.
 */
const COCKPIT_LINK_DESCRIPTOR = Object.freeze({
    busName: COCKPIT_BUS_NAME,
    objectPath: COCKPIT_OBJECT_PATH,
    interfaceName: COCKPIT_INTERFACE_NAME,
    signalName: COCKPIT_CHANGED_SIGNAL_NAME,
    isSubscribedFromCreation: false,
});

// Template keys of the rate-limited journal lines whose text varies (lib/errorLog.js). Each names the cockpit, so a
// logger the extension shares with pulseClient.js keeps their limits apart.
const START_UNIT_FAILURE_LOG_KEY = 'cockpit StartUnit failed';
const START_UNCONFIRMED_LOG_KEY = 'cockpit StartUnit unconfirmed';
const CONNECT_FAILURE_LOG_KEY = 'cannot follow the cockpit';
const STATE_FAILURE_LOG_KEY = 'cockpit GetState failed';
const UNREADABLE_STATE_LOG_KEY = 'unreadable cockpit state';
const WRONG_CHANGED_SIGNATURE_LOG_KEY = 'cockpit Changed of another signature';
const UNREADABLE_CHANGED_LOG_KEY = 'unreadable cockpit Changed';
const WATCH_CALL_FAILURE_LOG_KEY = 'cockpit watch call failed';
const FOCUS_SESSION_FAILURE_LOG_KEY = 'cockpit FocusSession failed';
const LISTENER_FAILURE_LOG_KEY = 'cockpit listener failed';
const STEP_FAILURE_LOG_KEY = 'cockpit client step failed';
const TEARDOWN_FAILURE_LOG_KEY = 'cockpit client teardown step failed';

/** GLib's timeouts at the default priority: the client's StartUnit chain. */
const GLIB_TIMEOUTS = Object.freeze({
    addSeconds: (intervalSeconds, callback) =>
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, intervalSeconds, callback),
    remove: sourceId => GLib.source_remove(sourceId),
});

/**
 * Asks systemd's user manager, on the session bus, to start the service: StartUnit('cockpit.service', 'replace') on
 * /org/freedesktop/systemd1, asynchronously.
 *
 * @param {Gio.DBusConnection} connection - The session bus, where the user manager lives.
 * @param {Gio.Cancellable} cancellable - Cancels the call.
 * @param {(error: Error|null) => void} onAnswered - Called once: null when systemd took the start job, or the failure.
 * @returns {void}
 */
function startCockpitUnit(connection, cancellable, onAnswered) {
    const startUnitParameters = new GLib.Variant(START_UNIT_PARAMETERS_SIGNATURE, [COCKPIT_UNIT_NAME, START_UNIT_MODE]);
    const startUnitReplyType = new GLib.VariantType(START_UNIT_REPLY_SIGNATURE);
    connection.call(SYSTEMD_BUS_NAME, SYSTEMD_OBJECT_PATH, SYSTEMD_MANAGER_INTERFACE_NAME, START_UNIT_METHOD_NAME,
        startUnitParameters, startUnitReplyType, CALL_FLAGS, DBUS_CALL_TIMEOUT_MS, cancellable,
        (callingConnection, result) => {
            try {
                callingConnection.call_finish(result);
            } catch (error) {
                onAnswered(error);
                return;
            }
            onAnswered(null);
        });
}

/**
 * Starts following the cockpit service on a connection (serviceLink.js's createServiceLink): watching its name from
 * now until destroy(), and not subscribed to Changed until setSubscribed(true).
 *
 * @param {Gio.DBusConnection} connection - The session bus.
 * @param {object} callbacks - Where the link delivers.
 * @param {(nameOwner: string|null) => void} callbacks.onOwnerChanged - The unique name owning the cockpit's bus name
 *     when it appears, null when it vanishes; reported once soon after creation, null when nobody owns the name.
 * @param {(parameters: GLib.Variant) => void} callbacks.onSignal - Each Changed's parameters, while subscribed.
 * @returns {object} The link: isSubscribed, setSubscribed(isSubscribed), call(methodName, parameters, cancellable,
 *     onAnswered) and destroy().
 */
export function createCockpitLink(connection, {onOwnerChanged, onSignal}) {
    return createServiceLink(connection, COCKPIT_LINK_DESCRIPTOR, {onOwnerChanged, onSignal});
}

/**
 * Calls a method of systemd's user manager on the session bus, asynchronously, with DBUS_CALL_TIMEOUT_MS.
 *
 * @param {Gio.DBusConnection} connection - The session bus.
 * @param {object} call - The call.
 * @param {string} call.objectPath - The object called.
 * @param {string} call.interfaceName - The method's interface.
 * @param {string} call.methodName - The method.
 * @param {GLib.Variant} call.parameters - Its arguments.
 * @param {string} call.replySignature - The reply's type; a reply of another type fails the call.
 * @param {Gio.Cancellable} cancellable - Cancels the call.
 * @returns {Promise<GLib.Variant>} The reply; rejects with the failure.
 */
function callSystemd(connection, {objectPath, interfaceName, methodName, parameters, replySignature}, cancellable) {
    const replyType = new GLib.VariantType(replySignature);
    return new Promise((resolve, reject) => {
        connection.call(SYSTEMD_BUS_NAME, objectPath, interfaceName, methodName, parameters, replyType, CALL_FLAGS,
            DBUS_CALL_TIMEOUT_MS, cancellable, (callingConnection, result) => {
                let reply;
                try {
                    reply = callingConnection.call_finish(result);
                } catch (error) {
                    reject(error);
                    return;
                }
                resolve(reply);
            });
    });
}

/**
 * Reads one property of a systemd unit (Properties.Get on the unit's object).
 *
 * @param {Gio.DBusConnection} connection - The session bus.
 * @param {string} unitObjectPath - The unit's object, as GetUnit answered it.
 * @param {{name: string, signature: string}} property - The property, and the type systemd gives it.
 * @param {Gio.Cancellable} cancellable - Cancels the call.
 * @returns {Promise<boolean|number|string|null>} Its value; null when it is not of that type. Rejects when the call
 *     fails.
 */
async function readUnitProperty(connection, unitObjectPath, property, cancellable) {
    const parameters = new GLib.Variant(GET_PROPERTY_PARAMETERS_SIGNATURE,
        [SYSTEMD_UNIT_INTERFACE_NAME, property.name]);
    const reply = await callSystemd(connection, {
        objectPath: unitObjectPath, interfaceName: DBUS_PROPERTIES_INTERFACE_NAME, methodName: GET_PROPERTY_METHOD_NAME,
        parameters, replySignature: GET_PROPERTY_REPLY_SIGNATURE,
    }, cancellable);
    const [propertyValue] = reply.deepUnpack();
    return propertyValue.get_type_string() === property.signature ? propertyValue.deepUnpack() : null;
}

/**
 * Says whether a D-Bus call failed because systemd has no such unit: the remote error
 * org.freedesktop.systemd1.NoSuchUnit, read from the error's name, never from its text.
 *
 * @param {*} error - The failure.
 * @returns {boolean} True for NoSuchUnit.
 */
function isNoSuchUnitError(error) {
    return error instanceof GLib.Error && Gio.DBusError.is_remote_error(error) &&
        Gio.DBusError.get_remote_error(error) === SYSTEMD_NO_SUCH_UNIT_ERROR_NAME;
}

/**
 * Finds cockpit.service's object on systemd's D-Bus (GetUnit): there only while systemd has the unit loaded.
 *
 * @param {Gio.DBusConnection} connection - The session bus.
 * @param {Gio.Cancellable} cancellable - Cancels the call.
 * @returns {Promise<string>} The unit's object path. Rejects when the call fails (NoSuchUnit for a unit not loaded).
 */
async function findCockpitUnitObjectPath(connection, cancellable) {
    const getUnitParameters = new GLib.Variant(GET_UNIT_PARAMETERS_SIGNATURE, [COCKPIT_UNIT_NAME]);
    const getUnitReply = await callSystemd(connection, {
        objectPath: SYSTEMD_OBJECT_PATH, interfaceName: SYSTEMD_MANAGER_INTERFACE_NAME,
        methodName: GET_UNIT_METHOD_NAME, parameters: getUnitParameters, replySignature: GET_UNIT_REPLY_SIGNATURE,
    }, cancellable);
    const [unitObjectPath] = getUnitReply.deepUnpack();
    return unitObjectPath;
}

/**
 * Reads the three properties the skip check needs from a loaded unit's object.
 *
 * @param {Gio.DBusConnection} connection - The session bus.
 * @param {string} unitObjectPath - The unit's object, as GetUnit answered it.
 * @param {Gio.Cancellable} cancellable - Cancels the calls.
 * @returns {Promise<{conditionResult: boolean|null, conditionTimestampMonotonic: number|null,
 *     activeState: string|null, isUnitMissing: boolean}>} Each property, null when not of its type; isUnitMissing
 *     false. Rejects when a call fails.
 */
async function readUnitConditionProperties(connection, unitObjectPath, cancellable) {
    const conditionProperties =
        [CONDITION_RESULT_PROPERTY, CONDITION_TIMESTAMP_MONOTONIC_PROPERTY, ACTIVE_STATE_PROPERTY];
    const [conditionResult, conditionTimestampMonotonic, activeState] = await Promise.all(
        conditionProperties.map(property => readUnitProperty(connection, unitObjectPath, property, cancellable)));
    return {conditionResult, conditionTimestampMonotonic, activeState, isUnitMissing: false};
}

/**
 * The real readUnitCondition: cockpit.service's condition as systemd reports it, asynchronously, never rejecting.
 *
 * @param {Gio.DBusConnection} connection - The session bus.
 * @param {Gio.Cancellable} cancellable - Cancels the calls.
 * @returns {Promise<{conditionResult: boolean|null, conditionTimestampMonotonic: number|null,
 *     activeState: string|null, isUnitMissing: boolean}>} The three properties, isUnitMissing false. When GetUnit
 *     answers NoSuchUnit, every property null and isUnitMissing true (a skip: systemd unloaded the unit). When any
 *     other call fails (no systemd, a timeout, another error, a cancel), every property null and isUnitMissing false
 *     (no skip).
 */
async function readCockpitUnitCondition(connection, cancellable) {
    let unitObjectPath;
    try {
        unitObjectPath = await findCockpitUnitObjectPath(connection, cancellable);
    } catch (error) {
        return isNoSuchUnitError(error) ? MISSING_UNIT_CONDITION : UNKNOWN_UNIT_CONDITION;
    }
    return readUnitConditionProperties(connection, unitObjectPath, cancellable).catch(() => UNKNOWN_UNIT_CONDITION);
}

/**
 * Says whether systemd skipped the start job for the unit's condition: ConditionResult false, checked by a job
 * (ConditionTimestampMonotonic above 0). A unit never started reads false too, with no check time (ruling R17).
 *
 * @param {{conditionResult: boolean|null, conditionTimestampMonotonic: number|null}} unitCondition - The unit read.
 * @returns {boolean} True for a skip.
 */
function isSkippedByCondition({conditionResult, conditionTimestampMonotonic}) {
    const wasConditionChecked = typeof conditionTimestampMonotonic === 'number' && conditionTimestampMonotonic > 0;
    return conditionResult === false && wasConditionChecked;
}

/**
 * The one string a reply or a signal carries, when it is of the signature expected.
 *
 * @param {*} variant - A GLib.Variant, or anything else.
 * @param {string} signature - The signature expected: '(s)'.
 * @returns {string|null} The string; null for anything else.
 */
function stringOfVariant(variant, signature) {
    if (!(variant instanceof GLib.Variant) || variant.get_type_string() !== signature)
        return null;
    const [text] = variant.deepUnpack();
    return text;
}

/**
 * Says whether a call failed only because the client cancelled it (destroy()).
 *
 * @param {*} error - The failure.
 * @returns {boolean} True for Gio's CANCELLED.
 */
function isCancelledError(error) {
    return error instanceof GLib.Error && error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED);
}

/**
 * The reply focusSession gives when FocusSession gave no readable one: a fault on the way, as the service's own
 * internal code says.
 *
 * @returns {{focused: boolean, windowPid: null, error: string, windowPidCandidates: number[]}} A new one each time.
 */
function internalFocusSessionReply() {
    return {focused: false, windowPid: null, error: COCKPIT_FOCUS_ERROR.INTERNAL, windowPidCandidates: []};
}

/**
 * Says whether two values read the same as JSON: how the client tells a layout or a source that changed.
 *
 * @param {*} firstValue - A parsed value.
 * @param {*} secondValue - Another.
 * @returns {boolean} True when their JSON texts are equal.
 */
function isSameAsJson(firstValue, secondValue) {
    return JSON.stringify(firstValue) === JSON.stringify(secondValue);
}

/**
 * Says whether a source's new object carries another sample stamp than the one the client holds (ruling D5): a
 * refresh, which ends the source's suspicion cycle. A first stamp counts, and so does an earlier one (the wall clock
 * stepped back); the same stamp does not.
 *
 * @param {object|null} previousSource - The source object the client holds, or null.
 * @param {object|null} nextSource - The source object an answer or a Changed carries, or null.
 * @returns {boolean} True when the two sampledAtUsec differ, a missing one reading as null.
 */
function isSampleStampChanged(previousSource, nextSource) {
    const previousSampledAtUsec = previousSource?.sampledAtUsec ?? null;
    const nextSampledAtUsec = nextSource?.sampledAtUsec ?? null;
    return nextSampledAtUsec !== previousSampledAtUsec;
}

/**
 * The pull stamps of a source with no pull asked for in its current suspicion cycle.
 *
 * @returns {{requestedAtUsec: null, completedAtUsec: null}} A new one each time.
 */
function emptyPullStamps() {
    return {requestedAtUsec: null, completedAtUsec: null};
}

/** Follows the cockpit service on the bus, and keeps what the cockpit's cards draw. */
export class CockpitClient {
    /**
     * @param {object} [options] - Everything injectable, so the rows can run it on fakes; each has a real default.
     * @param {Gio.BusType} [options.busType] - The bus whose connection is fetched when none is given: the session bus,
     *     where both the service and systemd's user manager live.
     * @param {Gio.DBusConnection|null} [options.connection] - A connection to use instead of fetching busType's.
     * @param {(connection: Gio.DBusConnection, cancellable: Gio.Cancellable,
     *     onAnswered: (error: Error|null) => void) => void} [options.startUnit] - Asks systemd to start the service.
     * @param {(connection: Gio.DBusConnection, callbacks: {onOwnerChanged: (nameOwner: string|null) => void,
     *     onSignal: (parameters: GLib.Variant) => void}) => object} [options.createLink] - Starts following the
     *     service: createCockpitLink, whose link reports the owner, delivers each Changed while subscribed and makes
     *     the calls.
     * @param {(connection: Gio.DBusConnection, cancellable: Gio.Cancellable) => Promise<{conditionResult: boolean|null,
     *     conditionTimestampMonotonic: number|null, activeState: string|null, isUnitMissing: boolean}>}
     *     [options.readUnitCondition] - Reads cockpit.service's condition over systemd's D-Bus; a failure resolves to
     *     every property null, with isUnitMissing true only when GetUnit answered NoSuchUnit.
     * @param {() => number} [options.nowUsec] - Monotonic microseconds, for the log's rate limit.
     * @param {() => number} [options.nowRealUsec] - Wall-clock microseconds, the clock of the sources' sampledAtUsec:
     *     for staleness and the pull stamps.
     * @param {{addSeconds: (intervalSeconds: number, callback: () => boolean) => number,
     *     remove: (sourceId: number) => void}} [options.timeouts] - Adds and removes timeouts.
     * @param {RateLimitedLogger} [options.errorLog] - Where failures go. The extension passes one that outlives every
     *     client, so a lasting failure is logged once per 10 minutes, not once per enable.
     * @param {(line: string) => void} [options.writeInfoLine] - Where the one info line of a skipped unit goes: the
     *     journal at info level, never as a warning.
     * @param {object|null} [options.cachedLayout] - The last layout an earlier client received (the extension keeps
     *     it across enables), so the grid can be built before this client's first answer.
     */
    constructor({
        busType = Gio.BusType.SESSION,
        connection = null,
        startUnit = startCockpitUnit,
        createLink = createCockpitLink,
        readUnitCondition = readCockpitUnitCondition,
        nowUsec = () => GLib.get_monotonic_time(),
        nowRealUsec = () => GLib.get_real_time(),
        timeouts = GLIB_TIMEOUTS,
        errorLog = new RateLimitedLogger({nowUsec, write: line => console.warn(line)}),
        writeInfoLine = line => console.info(line),
        cachedLayout = null,
    } = {}) {
        this._busType = busType;
        this._connection = connection;
        this._startUnit = startUnit;
        this._createLink = createLink;
        this._readUnitCondition = readUnitCondition;
        this._nowRealUsec = nowRealUsec;
        this._timeouts = timeouts;
        this._errorLog = errorLog;
        this._writeInfoLine = writeInfoLine;

        // Cancels every call and read in flight, and the bus connection's fetch, at destroy(); the best-effort
        // UnwatchCockpit uses none.
        this._cancellable = new Gio.Cancellable();
        this._isStarted = false;
        this._isDestroyed = false;
        this._state = CockpitClientState.STARTING;
        // The service on the bus (serviceLink.js), from the connection's arrival until destroy().
        this._link = null;
        // True while the Changed subscription is wanted (setSubscriptionWanted); the link holds it while an owner
        // has appeared since.
        this._isSubscriptionWanted = false;
        // The unique name owning the service's bus name, as last seen; null while nobody does.
        this._nameOwner = null;
        // The StartUnit chain's pending timeout, at most one: a retry after a failure, or the wait for the service to
        // appear after an accepted StartUnit. Every way the chain ends or restarts removes it.
        this._startChainSourceId = null;
        // The latest StartUnit sent: {attemptNumber}, counted from 1 by each start(). An answer to an older one, or a
        // unit read for one, is ignored, so two start() calls in a row cannot both schedule a retry.
        this._latestStartAttempt = null;
        // True while a StartUnit is due but the connection is not up yet.
        this._isServiceStartPending = false;
        // True once a GetState of the current owner was applied; until then a Changed asks for the state instead.
        this._hasStateFromOwner = false;
        // Each GetState sent takes the next number; only the answer to the latest one is applied.
        this._stateRequestNumber = 0;
        this._isStateRequestInFlight = false;
        // The pulls waiting for the GetState in flight: {sourceName, resolve}.
        this._pendingPulls = [];
        this._isWatchWanted = false;
        // True from a WatchCockpit sent to the current owner until an UnwatchCockpit follows or that owner leaves (its
        // watches leave with it).
        this._isWatchHeld = false;
        this._layout = cachedLayout;
        this._configError = null;
        this._sourcesByName = new Map(COCKPIT_SOURCE_NAMES.map(sourceName => [sourceName, null]));
        // When the client last asked for each source's state on suspicion, and when that answer came: wall clock. Both
        // are cleared when the source's stamp changes (_storeSources).
        this._pullStampsBySourceName = new Map(COCKPIT_SOURCE_NAMES.map(sourceName =>
            [sourceName, emptyPullStamps()]));
        this._listeners = new Map();
        this._nextListenerId = 1;
    }

    /** @returns {string} One of CockpitClientState's values. */
    get state() {
        return this._state;
    }

    /** @returns {object|null} The latest layout (lib/cockpitProtocol.js parseLayout's shape), or the cached one. */
    get layout() {
        return this._layout;
    }

    /** @returns {string|null} Why the service could not read its layout config; null when it could. */
    get configError() {
        return this._configError;
    }

    /** @returns {{sessions: object|null, network: object|null, mounts: object|null}} Each source's latest object. */
    get sourcesByName() {
        return Object.fromEntries(this._sourcesByName);
    }

    /**
     * Judges one source now (lib/cockpitStaleness.js sourceFreshness), from its latest stamp and the pulls made for it.
     * A source the client does not know reads as one with no data.
     *
     * @param {string} sourceName - One of COCKPIT_SOURCE_NAMES.
     * @returns {{isStale: boolean, shouldPull: boolean, ageSeconds: number|null}} The verdict.
     */
    sourceFreshness(sourceName) {
        const source = this._sourcesByName.get(sourceName) ?? null;
        const pullStamps = this._pullStampsBySourceName.get(sourceName);
        return decideSourceFreshness({
            sampledAtUsec: source?.sampledAtUsec ?? null,
            intervalSeconds: source?.intervalSeconds ?? null,
            nowRealUsec: this._nowRealUsec(),
            lastPullRequestedAtUsec: pullStamps?.requestedAtUsec ?? null,
            lastPullCompletedAtUsec: pullStamps?.completedAtUsec ?? null,
        });
    }

    /**
     * Asks systemd to start the service, and the first time also starts following it: the bus connection and the
     * link. Every call asks systemd again (each enable makes one), restarting the retries; a SKIPPED client is
     * STARTING again, so a layout file created since is picked up. Nothing is connected twice. Does nothing once
     * destroyed.
     *
     * @returns {void}
     */
    start() {
        if (this._isDestroyed)
            return;
        if (this._state === CockpitClientState.SKIPPED) {
            this._setState(CockpitClientState.STARTING);
            // A listener may have destroyed the client.
            if (this._isDestroyed)
                return;
        }
        this._restartServiceStartAttempts();
        if (this._isStarted)
            return;
        this._isStarted = true;
        this._connect();
    }

    /**
     * Stops everything for good: releases a held watch (an UnwatchCockpit no cancel can stop), cancels every call in
     * flight, removes every timeout, destroys the link (its name watch and any subscription), settles every pull and
     * forgets every listener. Each step runs whatever the others throw. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        if (this._isDestroyed)
            return;
        this._isDestroyed = true;
        runEveryStep([
            {name: 'release the cockpit watch', run: () => this._sendUnwatchCockpit(null)},
            {name: 'cancel the calls in flight', run: () => this._cancellable.cancel()},
            {name: 'remove the timeouts', run: () => this._cancelStartChainStep()},
            {name: 'destroy the link', run: () => this._destroyLink()},
            {name: 'settle the pulls in flight', run: () => this._settlePulls(this._takePendingPulls())},
            {name: 'forget the listeners', run: () => this._listeners.clear()},
        ], (stepName, error) => {
            const errorText = describeError(error);
            this._errorLog.log(`cockpit client teardown: ${stepName} failed: ${errorText}`, TEARDOWN_FAILURE_LOG_KEY);
        });
    }

    /**
     * Says whether a cockpit watch is wanted (lib/cockpitInteraction.js isCockpitWatchWanted). Only a change is sent,
     * and only to an owner: WatchCockpit when it becomes wanted, UnwatchCockpit when it stops being. With no owner it
     * is only recorded, and sent when one appears.
     *
     * @param {boolean} isWanted - True while a cockpit card is visible or the dropdown is open.
     * @returns {void}
     */
    setWatchWanted(isWanted) {
        if (this._isDestroyed || isWanted === this._isWatchWanted)
            return;
        this._isWatchWanted = isWanted;
        if (this._nameOwner === null)
            return;
        if (isWanted)
            this._sendWatchCockpit();
        else
            this._sendUnwatchCockpit(this._cancellable);
    }

    /**
     * Says whether the Changed subscription is wanted: while something of the cockpit can be seen. It starts false,
     * and a client that does not want it hears no Changed (an owner appearing is still read with GetState). Only a
     * change acts: becoming wanted with an owner subscribes, then reads GetState (a fresh read: whatever changed while
     * unsubscribed, a restart included); with no owner it is only recorded, and the owner's appearance subscribes and
     * reads once. Becoming unwanted unsubscribes, and a GetState still on its way is applied when it answers. Does
     * nothing once destroyed. Independent of setWatchWanted.
     *
     * @param {boolean} isWanted - True while a cockpit card or the dropdown can be seen.
     * @returns {void}
     */
    setSubscriptionWanted(isWanted) {
        if (this._isDestroyed || isWanted === this._isSubscriptionWanted)
            return;
        this._isSubscriptionWanted = isWanted;
        if (!isWanted) {
            this._link?.setSubscribed(false);
            return;
        }
        if (this._nameOwner === null)
            return;
        this._link.setSubscribed(true);
        this._requestState(CockpitSourcesCause.READ);
    }

    /**
     * Adds a callback for each event: {type: 'state', state}, {type: 'layout', layout, configError} or
     * {type: 'sources', names, cause} (CockpitClientEventType; cause is a CockpitSourcesCause), in that order when one
     * answer brings several.
     *
     * @param {(event: object) => void} callback - Called with each event.
     * @returns {number} An id for removeListener.
     */
    addListener(callback) {
        const listenerId = this._nextListenerId++;
        this._listeners.set(listenerId, callback);
        return listenerId;
    }

    /**
     * Removes a callback added with addListener; an unknown id is ignored.
     *
     * @param {number} listenerId - The id addListener returned.
     * @returns {void}
     */
    removeListener(listenerId) {
        this._listeners.delete(listenerId);
    }

    /**
     * Pulls the state once when a source is suspected stale (ruling R14): when lib/cockpitStaleness.js says to pull
     * (past COCKPIT_SOURCE_STALE_INTERVALS of its interval, and no pull asked for within one interval), it stamps the
     * request and calls GetState, joining one already in flight. The answer stamps the completion, replaces the
     * state, and tells a sources event naming this source (its freshness may have changed) and any other that changed.
     * An answer that refreshes the source's stamp clears both pull stamps instead (ruling D5), so it reads stale only
     * after a later pull answers that same stamp. With no owner it asks nobody: the pull completes at once, so a
     * suspect source reads stale. A GetState that fails, or answers no readable state, completes the pull too (ruling
     * D6): it is logged once per key, the completion is stamped and the source told, so a service that keeps its name
     * but hangs reads stale; the next interval asks again.
     *
     * @param {string} sourceName - One of COCKPIT_SOURCE_NAMES.
     * @returns {Promise<{pulled: boolean}>} Settles once the pull did (never rejects): pulled is true when one was
     *     made, whatever it answered.
     */
    pullIfSuspicious(sourceName) {
        if (this._isDestroyed || !this.sourceFreshness(sourceName).shouldPull)
            return Promise.resolve({pulled: false});
        const pullStamps = this._pullStampsBySourceName.get(sourceName);
        pullStamps.requestedAtUsec = this._nowRealUsec();
        if (this._nameOwner === null) {
            pullStamps.completedAtUsec = pullStamps.requestedAtUsec;
            this._notifyListeners({
                type: CockpitClientEventType.SOURCES, names: [sourceName], cause: CockpitSourcesCause.PULL,
            });
            return Promise.resolve({pulled: true});
        }
        return new Promise(resolve => {
            this._pendingPulls.push({sourceName, resolve});
            if (!this._isStateRequestInFlight)
                this._requestState(CockpitSourcesCause.PULL);
        });
    }

    /**
     * Asks the service to bring one session's herdr pane to the front (FocusSession).
     *
     * @param {string} sessionId - The session row's id.
     * @returns {Promise<{focused: boolean|null, windowPid: number|null, error: string|null,
     *     windowPidCandidates: number[]}>} The reply as lib/cockpitProtocol.js parseFocusSessionReply reads it. Never
     *     rejects: a call that fails (no owner included), a reply that cannot be read, no link yet, an id that is not
     *     a string or a destroyed client give the internal reply, the failures logged at most once per 10 minutes.
     */
    focusSession(sessionId) {
        if (this._isDestroyed || this._link === null || typeof sessionId !== 'string') {
            this._logFocusSessionFailure('the client is not following the cockpit, or the id is not a string');
            return Promise.resolve(internalFocusSessionReply());
        }
        const focusSessionParameters = new GLib.Variant(FOCUS_SESSION_PARAMETERS_SIGNATURE, [sessionId]);
        return new Promise(resolve => {
            this._callService(COCKPIT_FOCUS_SESSION_METHOD_NAME, focusSessionParameters, this._cancellable,
                (error, reply) => resolve(this._readFocusSessionReply(error, reply)));
        });
    }

    /**
     * Reads FocusSession's answer.
     *
     * @param {Error|null} error - Why the call failed, or null.
     * @param {GLib.Variant|null} reply - The reply.
     * @returns {object} The parsed reply, or the internal reply.
     */
    _readFocusSessionReply(error, reply) {
        if (error !== null) {
            if (!isCancelledError(error))
                this._logFocusSessionFailure(describeError(error));
            return internalFocusSessionReply();
        }
        const focusReply = parseFocusSessionReply(stringOfVariant(reply, FOCUS_SESSION_REPLY_SIGNATURE));
        if (focusReply === null) {
            this._logFocusSessionFailure('it answered something that is not a reply');
            return internalFocusSessionReply();
        }
        return focusReply;
    }

    /**
     * Logs why a FocusSession gave no reply, unless destroyed.
     *
     * @param {string} reasonText - What went wrong.
     * @returns {void}
     */
    _logFocusSessionFailure(reasonText) {
        if (this._isDestroyed)
            return;
        this._errorLog.log(`${COCKPIT_FOCUS_SESSION_METHOD_NAME} failed: ${reasonText}`, FOCUS_SESSION_FAILURE_LOG_KEY);
    }

    /**
     * Moves to a state and tells listeners, when it is a change.
     *
     * @param {string} nextState - One of CockpitClientState's values.
     * @returns {void}
     */
    _setState(nextState) {
        if (nextState === this._state)
            return;
        this._state = nextState;
        this._notifyListeners({type: CockpitClientEventType.STATE, state: nextState});
    }

    /**
     * Starts a new StartUnit chain: removes a pending retry, counts attempts from 1 again, and sends the first now if
     * the connection is up (else once it is).
     *
     * @returns {void}
     */
    _restartServiceStartAttempts() {
        this._cancelStartChainStep();
        this._latestStartAttempt = null;
        this._isServiceStartPending = true;
        this._attemptServiceStartIfConnected();
    }

    /**
     * Sends the StartUnit that is due, if one is and the connection is up.
     *
     * @returns {void}
     */
    _attemptServiceStartIfConnected() {
        if (!this._isServiceStartPending || this._connection === null)
            return;
        this._isServiceStartPending = false;
        const previousAttemptNumber = this._latestStartAttempt?.attemptNumber ?? 0;
        const startAttempt = {attemptNumber: previousAttemptNumber + 1};
        this._latestStartAttempt = startAttempt;
        this._startUnit(this._connection, this._cancellable,
            error => this._onServiceStartAnswered(startAttempt, error));
    }

    /**
     * Handles systemd's answer to the latest StartUnit (an answer to an older one, or to one the service appearing
     * superseded, is ignored). A failure other than NoSuchUnit is logged. While the service is on the bus nothing
     * follows. Otherwise NoSuchUnit (no unit file is linked) is SKIPPED, an accepted StartUnit waits for the service to
     * appear, and any other failure is retried after nextStartRetryDelaySeconds.
     *
     * @param {{attemptNumber: number}} startAttempt - The attempt answered.
     * @param {Error|null} error - Null when systemd accepted the start job.
     * @returns {void}
     */
    _onServiceStartAnswered(startAttempt, error) {
        if (this._isDestroyed || startAttempt !== this._latestStartAttempt)
            return;
        const isUnitNotFound = error !== null && isNoSuchUnitError(error);
        if (error !== null && !isUnitNotFound) {
            const errorText = describeError(error);
            this._errorLog.log(`StartUnit ${COCKPIT_UNIT_NAME} failed: ${errorText}`, START_UNIT_FAILURE_LOG_KEY);
        }
        if (this._nameOwner !== null)
            return;
        if (isUnitNotFound)
            this._onUnitSkipped(UNIT_NOT_FOUND_SKIP_REASON);
        else if (error === null)
            this._awaitServiceAppearance(startAttempt);
        else
            this._scheduleStartRetry(startAttempt);
    }

    /**
     * Waits START_CONFIRMATION_TIMEOUT_SECONDS for the service an accepted StartUnit started to appear on the bus. Its
     * appearing ends the chain (and removes this wait); otherwise the unit's condition is read.
     *
     * @param {{attemptNumber: number}} startAttempt - The accepted attempt.
     * @returns {void}
     */
    _awaitServiceAppearance(startAttempt) {
        this._startChainSourceId = this._timeouts.addSeconds(START_CONFIRMATION_TIMEOUT_SECONDS,
            () => this._onStartConfirmationTimeout(startAttempt));
    }

    /**
     * The service did not appear after an accepted StartUnit: reads the unit's condition, to tell a skipped unit from
     * a failed start. Runs as a GLib timeout, so it never throws.
     *
     * @param {{attemptNumber: number}} startAttempt - The accepted attempt.
     * @returns {boolean} GLib.SOURCE_REMOVE: each step of the chain is a timeout of its own.
     */
    _onStartConfirmationTimeout(startAttempt) {
        this._startChainSourceId = null;
        this._runWithoutThrowing('read the cockpit unit\'s condition', () => this._readUnitConditionFor(startAttempt));
        return GLib.SOURCE_REMOVE;
    }

    /**
     * Reads the unit's condition, then goes on in _onUnitConditionRead. A read that rejects counts as nothing known,
     * and nothing the answer's handling throws escapes the promise.
     *
     * @param {{attemptNumber: number}} startAttempt - The accepted attempt the read is for.
     * @returns {void}
     */
    _readUnitConditionFor(startAttempt) {
        this._readUnitCondition(this._connection, this._cancellable)
            .catch(() => UNKNOWN_UNIT_CONDITION)
            .then(unitCondition => this._runWithoutThrowing('act on the cockpit unit\'s condition',
                () => this._onUnitConditionRead(startAttempt, unitCondition)));
    }

    /**
     * Acts on the unit's condition, if it answers the latest attempt (the service appearing supersedes it, as a new
     * start() does): a unit systemd no longer has loaded, or one skipped by its condition, ends the chain (SKIPPED);
     * anything else is logged and retried, as a failure.
     *
     * @param {{attemptNumber: number}} startAttempt - The accepted attempt the read is for.
     * @param {{conditionResult: boolean|null, conditionTimestampMonotonic: number|null, activeState: string|null,
     *     isUnitMissing: boolean}} unitCondition - What systemd said.
     * @returns {void}
     */
    _onUnitConditionRead(startAttempt, unitCondition) {
        if (this._isDestroyed || startAttempt !== this._latestStartAttempt)
            return;
        if (unitCondition.isUnitMissing === true) {
            this._onUnitSkipped(UNIT_UNLOADED_SKIP_REASON);
            return;
        }
        if (isSkippedByCondition(unitCondition)) {
            this._onUnitSkipped(CONDITION_SKIP_REASON);
            return;
        }
        const unitConditionText = `ConditionResult ${unitCondition.conditionResult}, ` +
            `ActiveState ${unitCondition.activeState}`;
        this._errorLog.log(`StartUnit ${COCKPIT_UNIT_NAME} was accepted, but the service did not appear on the bus ` +
            `within ${START_CONFIRMATION_TIMEOUT_SECONDS} s (${unitConditionText})`, START_UNCONFIRMED_LOG_KEY);
        this._scheduleStartRetry(startAttempt);
    }

    /**
     * The unit is not there to run (skipped for its condition, or unknown to systemd): the cockpit is not configured.
     * The chain ends with one info line (no warning: this is the normal state for anyone without the layout file), and
     * the next start() asks again.
     *
     * @param {string} skipReason - Why, completing "cockpit.service <reason>": CONDITION_SKIP_REASON,
     *     UNIT_NOT_FOUND_SKIP_REASON or UNIT_UNLOADED_SKIP_REASON.
     * @returns {void}
     */
    _onUnitSkipped(skipReason) {
        this._latestStartAttempt = null;
        this._writeInfoLine(`${LOG_PREFIX} ${COCKPIT_UNIT_NAME} ${skipReason}: the cockpit is not configured; ` +
            'the next enable asks again');
        this._setState(CockpitClientState.SKIPPED);
    }

    /**
     * Schedules the next StartUnit after nextStartRetryDelaySeconds for the attempt that failed.
     *
     * @param {{attemptNumber: number}} startAttempt - The failed (or unconfirmed) attempt.
     * @returns {void}
     */
    _scheduleStartRetry(startAttempt) {
        const retryDelaySeconds = nextStartRetryDelaySeconds(startAttempt.attemptNumber);
        this._startChainSourceId = this._timeouts.addSeconds(retryDelaySeconds, () => this._onStartRetryTimeout());
    }

    /**
     * Sends the next StartUnit of the chain. Runs as a GLib timeout, so it never throws.
     *
     * @returns {boolean} GLib.SOURCE_REMOVE: each step of the chain is a timeout of its own.
     */
    _onStartRetryTimeout() {
        this._startChainSourceId = null;
        this._isServiceStartPending = true;
        this._runWithoutThrowing('retry StartUnit', () => this._attemptServiceStartIfConnected());
        return GLib.SOURCE_REMOVE;
    }

    /**
     * Removes the StartUnit chain's pending timeout, if any: a retry, or the wait for the service to appear.
     *
     * @returns {void}
     */
    _cancelStartChainStep() {
        if (this._startChainSourceId === null)
            return;
        const startChainSourceId = this._startChainSourceId;
        this._startChainSourceId = null;
        this._timeouts.remove(startChainSourceId);
    }

    /**
     * Uses the connection given, or fetches busType's asynchronously, then goes on in _onConnected.
     *
     * @returns {void}
     */
    _connect() {
        if (this._connection !== null) {
            this._onConnected(this._connection);
            return;
        }
        Gio.bus_get(this._busType, this._cancellable, (_source, result) => {
            let connection;
            try {
                connection = Gio.bus_get_finish(result);
            } catch (error) {
                this._logFollowFailure(error);
                return;
            }
            this._onConnected(connection);
        });
    }

    /**
     * Sends a StartUnit that waited for the connection, and starts following the service: the link reports its owner
     * (soon after, even when nobody owns the name) and, while subscribed, delivers its Changed.
     *
     * @param {Gio.DBusConnection} connection - The bus connection.
     * @returns {void}
     */
    _onConnected(connection) {
        if (this._isDestroyed)
            return;
        this._connection = connection;
        this._attemptServiceStartIfConnected();
        this._link = this._createLink(connection, {
            onOwnerChanged: nameOwner => this._followNameOwner(nameOwner),
            onSignal: parameters => this._onChangedSignal(parameters),
        });
    }

    /**
     * Logs that the client cannot follow the service at all (no bus connection), unless destroyed.
     *
     * @param {*} error - The failure.
     * @returns {void}
     */
    _logFollowFailure(error) {
        if (this._isDestroyed)
            return;
        const errorText = describeError(error);
        this._errorLog.log(`cannot follow the cockpit service on the bus: ${errorText}`, CONNECT_FAILURE_LOG_KEY);
    }

    /**
     * Acts on the owner the link reports: an owner that left vanished, a new one appeared (both, for a direct change
     * from one to another). The same owner again, nobody after nobody included, changes nothing.
     *
     * @param {string|null} nameOwner - The unique name owning the service's bus name now, or null for none.
     * @returns {void}
     */
    _followNameOwner(nameOwner) {
        if (this._isDestroyed || nameOwner === this._nameOwner)
            return;
        if (this._nameOwner !== null)
            this._onServiceVanished();
        if (nameOwner !== null && !this._isDestroyed)
            this._onServiceAppeared(nameOwner);
    }

    /**
     * The service left the bus: VANISHED, its watch gone with it, its sources and their stamps kept (each reads stale
     * on its next pull), and no StartUnit (a stop stays a stop until the next start()). The pulls waiting on it are
     * completed as a failed GetState's are (ruling D6): their completion stamped and told as a sources event after the
     * state event, so a suspect source reads stale now rather than one interval later; then they settle. A held
     * subscription is kept: it is to the well-known name, so it carries on to the next owner.
     *
     * @returns {void}
     */
    _onServiceVanished() {
        this._nameOwner = null;
        this._isWatchHeld = false;
        this._hasStateFromOwner = false;
        // An answer still on its way comes from the owner that left.
        this._stateRequestNumber++;
        this._isStateRequestInFlight = false;
        const pendingPulls = this._takePendingPulls();
        this._setState(CockpitClientState.VANISHED);
        this._completeUnansweredPulls(pendingPulls.map(pendingPull => pendingPull.sourceName));
        this._settlePulls(pendingPulls);
    }

    /**
     * A service is on the bus: it runs, so the StartUnit chain ends (its pending timeout removed, and a StartUnit or a
     * unit read still on its way superseded); a wanted subscription is made, its state is read whether the
     * subscription is wanted or not (in that order: serviceLink.js's setSubscribed), and a wanted watch asserted.
     *
     * @param {string} nameOwner - Its unique name.
     * @returns {void}
     */
    _onServiceAppeared(nameOwner) {
        this._nameOwner = nameOwner;
        this._cancelStartChainStep();
        this._latestStartAttempt = null;
        if (this._isSubscriptionWanted)
            this._link.setSubscribed(true);
        this._requestState(CockpitSourcesCause.READ);
        if (this._isWatchWanted)
            this._sendWatchCockpit();
    }

    /**
     * Calls GetState. Only the answer to the latest call is applied, and its sources event carries the call's cause:
     * pulls that join a call already in flight take its cause, and a call made since supersedes it, cause and all.
     *
     * @param {string} cause - Why the state is asked for: CockpitSourcesCause.READ (an owner's appearance, the
     *     subscription becoming wanted, an early Changed) or CockpitSourcesCause.PULL (pullIfSuspicious).
     * @returns {void}
     */
    _requestState(cause) {
        this._stateRequestNumber++;
        const stateRequestNumber = this._stateRequestNumber;
        this._isStateRequestInFlight = true;
        this._callService(COCKPIT_GET_STATE_METHOD_NAME, NO_PARAMETERS, this._cancellable,
            (error, reply) => this._onStateAnswered(stateRequestNumber, cause, error, reply));
    }

    /**
     * Applies GetState's answer, if it answers the latest call, and settles the pulls that waited for it. A failure or
     * an unreadable state is logged, completes those pulls (ruling D6) and changes nothing else.
     *
     * @param {number} stateRequestNumber - The call's number.
     * @param {string} cause - Why it was called: a CockpitSourcesCause, told with the sources the answer brings.
     * @param {Error|null} error - Why the call failed, or null.
     * @param {GLib.Variant|null} reply - The reply.
     * @returns {void}
     */
    _onStateAnswered(stateRequestNumber, cause, error, reply) {
        if (this._isDestroyed || stateRequestNumber !== this._stateRequestNumber)
            return;
        this._isStateRequestInFlight = false;
        const pendingPulls = this._takePendingPulls();
        const pulledSourceNames = pendingPulls.map(pendingPull => pendingPull.sourceName);
        const state = this._readStateReply(error, reply);
        if (state === null)
            this._completeUnansweredPulls(pulledSourceNames);
        else
            this._applyState(state, pulledSourceNames, cause);
        this._settlePulls(pendingPulls);
    }

    /**
     * Completes the pulls a GetState was for that failed, answered no readable state, or will not be answered because
     * its owner left (ruling D6): their completion is stamped now and they are told as a sources event of cause
     * CockpitSourcesCause.PULL, so a suspect source whose service keeps its name but hangs, or has gone, reads stale,
     * and its card redraws. _readStateReply logged a failure, once per key (a vanish logs nothing); the next interval's
     * suspicion pulls again.
     *
     * @param {string[]} pulledSourceNames - The sources whose pulls the GetState was for; none tells nothing.
     * @returns {void}
     */
    _completeUnansweredPulls(pulledSourceNames) {
        if (pulledSourceNames.length === 0)
            return;
        this._stampPullCompletions(pulledSourceNames);
        const toldSourceNames = COCKPIT_SOURCE_NAMES.filter(sourceName => pulledSourceNames.includes(sourceName));
        this._notifyListeners({
            type: CockpitClientEventType.SOURCES, names: toldSourceNames, cause: CockpitSourcesCause.PULL,
        });
    }

    /**
     * Stamps now as the completion of each pull named (ruling D5). A pull whose source was refreshed, by this very
     * answer or by a Changed while the pull was in flight, had its request stamp cleared with the rest of its cycle
     * (_storeSources), and is not stamped: a stamp would make the refreshed source read stale at its next suspicion,
     * before any pull of the new cycle answered.
     *
     * @param {string[]} pulledSourceNames - The sources whose pulls completed.
     * @returns {void}
     */
    _stampPullCompletions(pulledSourceNames) {
        const completedAtUsec = this._nowRealUsec();
        for (const pulledSourceName of pulledSourceNames) {
            const pullStamps = this._pullStampsBySourceName.get(pulledSourceName);
            const isPullOfCurrentCycle = pullStamps.requestedAtUsec !== null;
            if (isPullOfCurrentCycle)
                pullStamps.completedAtUsec = completedAtUsec;
        }
    }

    /**
     * Reads GetState's answer, logging what cannot be used.
     *
     * @param {Error|null} error - Why the call failed, or null.
     * @param {GLib.Variant|null} reply - The reply.
     * @returns {object|null} lib/cockpitProtocol.js parseCockpitStatePayload's result; null for a failure.
     */
    _readStateReply(error, reply) {
        if (error !== null) {
            const errorText = describeError(error);
            this._errorLog.log(`cockpit ${COCKPIT_GET_STATE_METHOD_NAME} failed: ${errorText}`, STATE_FAILURE_LOG_KEY);
            return null;
        }
        const state = parseCockpitStatePayload(stringOfVariant(reply, STATE_REPLY_SIGNATURE));
        if (state === null) {
            this._errorLog.log(`cockpit ${COCKPIT_GET_STATE_METHOD_NAME} answered something that is not a state`,
                UNREADABLE_STATE_LOG_KEY);
        }
        return state;
    }

    /**
     * Takes a state whole: the layout, the config error and every source replace the client's (a source the answer
     * refreshed has both pull stamps cleared), the pulled sources' completion is stamped (except where that clearing
     * ended the pull's cycle), and the client is LIVE. Then tells, in order, the state, the layout (if it changed) and
     * the sources that changed or were pulled, with the call's cause.
     *
     * @param {object} state - lib/cockpitProtocol.js parseCockpitStatePayload's result.
     * @param {string[]} pulledSourceNames - The sources whose pulls this answer completes.
     * @param {string} cause - Why the GetState was called (a CockpitSourcesCause).
     * @returns {void}
     */
    _applyState(state, pulledSourceNames, cause) {
        this._hasStateFromOwner = true;
        const isLayoutChanged = this._storeLayout(state.layout, state.configError);
        const changedSourceNames = this._storeSources(state.sources);
        this._stampPullCompletions(pulledSourceNames);
        const toldSourceNames = COCKPIT_SOURCE_NAMES.filter(sourceName =>
            changedSourceNames.includes(sourceName) || pulledSourceNames.includes(sourceName));
        this._setState(CockpitClientState.LIVE);
        if (isLayoutChanged)
            this._notifyLayoutChanged();
        if (toldSourceNames.length > 0)
            this._notifyListeners({type: CockpitClientEventType.SOURCES, names: toldSourceNames, cause});
    }

    /**
     * Reads a Changed the link delivered: one of signature '(s)' holding a JSON object is applied, and a malformed one
     * is logged and dropped. Before any state from this owner it asks for the state instead (unless a GetState is on
     * its way): the state holds this change, and a part of a state is not drawn. One that reaches the client while
     * the subscription is not wanted (none should) is dropped: the GetState that follows the next subscribe reads
     * what it carried.
     *
     * @param {GLib.Variant} parameters - The Changed's parameters.
     * @returns {void}
     */
    _onChangedSignal(parameters) {
        if (this._isDestroyed || !this._isSubscriptionWanted)
            return;
        const changedText = stringOfVariant(parameters, COCKPIT_CHANGED_SIGNAL_SIGNATURE);
        if (changedText === null) {
            this._errorLog.log(`dropped a cockpit ${COCKPIT_CHANGED_SIGNAL_NAME} whose parameters are not ` +
                `${COCKPIT_CHANGED_SIGNAL_SIGNATURE}`, WRONG_CHANGED_SIGNATURE_LOG_KEY);
            return;
        }
        const change = parseChangedPayload(changedText);
        if (change === null) {
            this._errorLog.log(`dropped a cockpit ${COCKPIT_CHANGED_SIGNAL_NAME} that is not a JSON object`,
                UNREADABLE_CHANGED_LOG_KEY);
            return;
        }
        if (!this._hasStateFromOwner) {
            if (!this._isStateRequestInFlight && this._nameOwner !== null)
                this._requestState(CockpitSourcesCause.READ);
            return;
        }
        this._applyChange(change);
    }

    /**
     * Applies one Changed: the layout and its config error when it carries either (the service sends both when the
     * layout changed), and each source it carries. Tells the layout if it changed, then the sources that changed.
     *
     * @param {object} change - lib/cockpitProtocol.js parseChangedPayload's result.
     * @returns {void}
     */
    _applyChange(change) {
        const isLayoutChange = change.layout !== null || change.configError !== null;
        const isLayoutChanged = isLayoutChange && this._storeLayout(change.layout, change.configError);
        const changedSourceNames = this._storeSources(change.sources);
        if (isLayoutChanged)
            this._notifyLayoutChanged();
        if (changedSourceNames.length > 0) {
            this._notifyListeners({
                type: CockpitClientEventType.SOURCES, names: changedSourceNames, cause: CockpitSourcesCause.CHANGED,
            });
        }
    }

    /**
     * Keeps a layout and its config error.
     *
     * @param {object|null} layout - The layout.
     * @param {string|null} configError - The config error.
     * @returns {boolean} True when either differs from what the client had.
     */
    _storeLayout(layout, configError) {
        const isChanged = !isSameAsJson({layout, configError}, {layout: this._layout, configError: this._configError});
        this._layout = layout;
        this._configError = configError;
        return isChanged;
    }

    /**
     * Keeps each source an answer or a Changed carries. A source whose stamp changes (forward, or back with the wall
     * clock) has both pull stamps cleared (ruling D5): it was refreshed, so it starts a new suspicion cycle, and reads
     * stale only once a pull of that cycle answers its new stamp.
     *
     * @param {object} sources - Source objects by name; a name the client does not know is ignored.
     * @returns {string[]} The names whose object changed, in COCKPIT_SOURCE_NAMES's order.
     */
    _storeSources(sources) {
        const changedSourceNames = [];
        for (const sourceName of COCKPIT_SOURCE_NAMES) {
            if (!Object.hasOwn(sources, sourceName))
                continue;
            const previousSource = this._sourcesByName.get(sourceName);
            const source = sources[sourceName];
            if (!isSameAsJson(previousSource, source))
                changedSourceNames.push(sourceName);
            if (isSampleStampChanged(previousSource, source))
                this._pullStampsBySourceName.set(sourceName, emptyPullStamps());
            this._sourcesByName.set(sourceName, source);
        }
        return changedSourceNames;
    }

    /**
     * Tells listeners the layout and the config error now.
     *
     * @returns {void}
     */
    _notifyLayoutChanged() {
        this._notifyListeners({
            type: CockpitClientEventType.LAYOUT, layout: this._layout, configError: this._configError,
        });
    }

    /**
     * Takes the pulls waiting for the GetState in flight.
     *
     * @returns {Array<{sourceName: string, resolve: Function}>} Them; none wait afterwards.
     */
    _takePendingPulls() {
        const pendingPulls = this._pendingPulls;
        this._pendingPulls = [];
        return pendingPulls;
    }

    /**
     * Settles pulls: each was made, whatever its GetState answered.
     *
     * @param {Array<{sourceName: string, resolve: Function}>} pendingPulls - The pulls.
     * @returns {void}
     */
    _settlePulls(pendingPulls) {
        for (const pendingPull of pendingPulls)
            pendingPull.resolve({pulled: true});
    }

    /**
     * Calls every listener with an event. One that throws is logged, and the rest still run.
     *
     * @param {object} event - The event.
     * @returns {void}
     */
    _notifyListeners(event) {
        for (const [listenerId, listener] of [...this._listeners]) {
            // A listener may destroy the client or remove a later listener.
            if (this._isDestroyed)
                return;
            if (!this._listeners.has(listenerId))
                continue;
            try {
                listener(event);
            } catch (error) {
                this._errorLog.log(`cockpit listener failed: ${describeError(error)}`, LISTENER_FAILURE_LOG_KEY);
            }
        }
    }

    /**
     * Runs one step of a timeout or promise callback, logging (never throwing) what it throws, even should the
     * logging throw.
     *
     * @param {string} stepName - What the step does, for the journal.
     * @param {() => void} step - The step.
     * @returns {void}
     */
    _runWithoutThrowing(stepName, step) {
        runEveryStep([{name: stepName, run: step}], (failedStepName, error) => {
            const errorText = describeError(error);
            this._errorLog.log(`cockpit client could not ${failedStepName}: ${errorText}`, STEP_FAILURE_LOG_KEY);
        });
    }

    /**
     * Sends WatchCockpit to the owner, and records that it holds the watch.
     *
     * @returns {void}
     */
    _sendWatchCockpit() {
        this._isWatchHeld = true;
        this._callService(COCKPIT_WATCH_METHOD_NAME, NO_PARAMETERS, this._cancellable,
            error => this._logWatchCallFailure(COCKPIT_WATCH_METHOD_NAME, error));
    }

    /**
     * Sends UnwatchCockpit, if the current owner holds a watch of this client's. destroy() passes no cancellable: its
     * cancel must not stop the one call that releases the watch.
     *
     * @param {Gio.Cancellable|null} cancellable - The call's cancellable.
     * @returns {void}
     */
    _sendUnwatchCockpit(cancellable) {
        if (!this._isWatchHeld)
            return;
        this._isWatchHeld = false;
        this._callService(COCKPIT_UNWATCH_METHOD_NAME, NO_PARAMETERS, cancellable,
            error => this._logWatchCallFailure(COCKPIT_UNWATCH_METHOD_NAME, error));
    }

    /**
     * Logs a watch call that failed, other than by the client's own cancel. Touches nothing else, so it is safe after
     * destroy().
     *
     * @param {string} methodName - WatchCockpit or UnwatchCockpit.
     * @param {Error|null} error - The failure, or null.
     * @returns {void}
     */
    _logWatchCallFailure(methodName, error) {
        if (error === null || isCancelledError(error))
            return;
        const errorText = describeError(error);
        this._errorLog.log(`${methodName} failed: ${errorText}`, WATCH_CALL_FAILURE_LOG_KEY);
    }

    /**
     * Calls a method of the service's owner through the link: asynchronously, with DBUS_CALL_TIMEOUT_MS, to the
     * owner's unique name. With no owner the link answers an error at once, sending nothing.
     *
     * @param {string} methodName - GetState, WatchCockpit, UnwatchCockpit or FocusSession.
     * @param {GLib.Variant|null} parameters - Its arguments, or NO_PARAMETERS.
     * @param {Gio.Cancellable|null} cancellable - The call's cancellable.
     * @param {(error: Error|null, reply: GLib.Variant|null) => void} onAnswered - Called once, with the reply or the
     *     failure.
     * @returns {void}
     */
    _callService(methodName, parameters, cancellable, onAnswered) {
        this._link.call(methodName, parameters, cancellable, onAnswered);
    }

    /**
     * Destroys the link, if there is one, and lets it go: its name watch and any subscription end.
     *
     * @returns {void}
     */
    _destroyLink() {
        const link = this._link;
        this._link = null;
        link?.destroy();
    }
}
