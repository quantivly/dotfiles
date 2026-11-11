// The extension's one source of numbers: a client of the Resource Pulse sampler service (service/, run by systemd as
// resource-pulse.service) on the session bus. It keeps the interface the card and the indicator draw from (cpuHistory,
// memoryHistory, latestSnapshot, lastGoodClockLabel, isLive, and the two kinds of listener below) and does no
// sampling, no file IO and no subprocess. Gio and GLib only (no Shell, St, Clutter or Meta), so it runs under plain
// gjs, and its link to the service, StartUnit, connection, clock and timeouts are all injectable.
//
// It runs inside gnome-shell, the compositor, so:
// - every D-Bus call is asynchronous, with DBUS_CALL_TIMEOUT_MS, and none is ever synchronous;
// - it follows the service through serviceLink.js (a name watch, a Sample subscription and plain calls), never
//   through a D-Bus proxy object, which would make GJS force a full garbage collection after every Sample;
// - every callback checks for destroy() before it touches anything, and destroy() cancels every pending call, removes
//   every timeout and ends the name watch and the subscription: GNOME 50 disables the extension, destroying this
//   client, on every lock and every blank, so a teardown must leave nothing behind;
// - nothing a timeout runs can throw out of its callback, which would end the GLib source.
//
// How it follows the service (docs/superpowers/specs/2026-11-08-resource-pulse-service-design.md, "Lifecycle"):
// - start() asks systemd's user manager to start the unit (StartUnit, "replace"), on every start(). A failure, or an
//   accepted StartUnit after which the service does not appear on the bus within START_CONFIRMATION_TIMEOUT_SECONDS
//   (systemd accepts the job before it checks the start limit), is retried after START_RETRY_DELAYS_SECONDS (5, 30,
//   300 s, then every 300 s). The service appearing on the bus ends the retries, and supersedes a StartUnit still on
//   its way.
// - It follows the bus name's owner. When an owner appears it calls GetState, whose histories and snapshot replace the
//   client's, and asserts the detail watch again if one is wanted. When the owner vanishes it shows no data and starts
//   nothing: a service stopped on purpose stays stopped until the next start(), and a crash is systemd's Restart=.
// - It draws every Sample, whatever StartUnit answered (the nested harness runs the service with no systemd): the
//   snapshot becomes the latest, and what the Sample appended is appended. A null appendedHistory (a watch start's
//   reveal) appends nothing.
// - Two kinds of listener. A history listener (the top bar) is told, with no argument, after every Sample that
//   appended to the histories, every state and every no data. A snapshot listener (addListener: the card and the
//   dropdown card) is told the snapshot on every state and every no data, on every Sample only while the detail
//   watch is wanted, and the latest snapshot once when the watch becomes wanted while the data is live. When both
//   kinds are told of one Sample, history listeners go first.
// - A Sample's snapshot is parsed late, never skipped: the Sample keeps it unread, and it is parsed when first read
//   (latestSnapshot, lastGoodClockLabel, or snapshot listeners being told). Whatever replaces an unread snapshot
//   parses it first (a numberless Sample, a reveal, no data), except a Sample that appended a number, so "no data
//   since" names the last Sample with numbers whether anything read it or not.
// - No data, once: when no Sample has come for SAMPLE_STALL_MS, or the service's sequence restarts, it publishes one
//   all-null snapshot and a gap in both histories. After a stall the next Sample of the same run draws again; after a
//   restart nothing is drawn until a fresh GetState answers.
// - The stall is one watchdog, not a periodic check: each Sample drawn removes the pending timeout and adds one of
//   SAMPLE_STALL_MS, so it fires only on silence, exactly the stall after the last Sample, and nothing in the client
//   wakes the shell while Samples flow. A fresh state arms it for what is left of the stall after its snapshot was
//   taken. It is pending only while the data is live: no data, however it comes, removes it.
// - The detail watch: WatchDetail and UnwatchDetail go out only when the wanted flag changes, and only to an owner.
//   destroy() sends UnwatchDetail, uncancellable and best-effort, while a watch is held: the shell's bus connection
//   outlives the extension, and the service drops a caller's watches only when its connection closes.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {
    CARD_HISTORY_SAMPLES, DBUS_CALL_TIMEOUT_MS, SAMPLE_STALL_MS, START_CONFIRMATION_TIMEOUT_SECONDS,
} from './lib/constants.js';
import {RateLimitedLogger, describeError} from './lib/errorLog.js';
import {RingBuffer} from './lib/history.js';
import {
    GET_STATE_METHOD_NAME, SAMPLE_SIGNAL_NAME, SAMPLE_SIGNAL_SIGNATURE, UNWATCH_DETAIL_METHOD_NAME,
    WATCH_DETAIL_METHOD_NAME, parseEnvelopeSnapshot, parseSampleEnvelope, parseStatePayload,
} from './lib/protocol.js';
import {runEveryStep} from './lib/teardown.js';
import {isSampleStale, nextStartRetryDelaySeconds} from './lib/wiring.js';
import {createResourcePulseLink} from './serviceLink.js';

// systemd's user manager on the session bus, and what the client asks of it.
const SYSTEMD_BUS_NAME = 'org.freedesktop.systemd1';
const SYSTEMD_OBJECT_PATH = '/org/freedesktop/systemd1';
const SYSTEMD_MANAGER_INTERFACE_NAME = 'org.freedesktop.systemd1.Manager';
const START_UNIT_METHOD_NAME = 'StartUnit';
/** The service's unit: systemd/resource-pulse.service, linked into the user's unit directory. */
const RESOURCE_PULSE_UNIT_NAME = 'resource-pulse.service';
/** StartUnit's job mode: replace a conflicting queued job. Starting a unit that already runs changes nothing. */
const START_UNIT_MODE = 'replace';
/** StartUnit(s name, s mode). */
const START_UNIT_PARAMETERS_SIGNATURE = '(ss)';
/** StartUnit → (o job). */
const START_UNIT_REPLY_SIGNATURE = '(o)';
/** GetState → (s state). */
const STATE_REPLY_SIGNATURE = '(s)';
/** StartUnit does not ask the bus to activate systemd's name: with nobody owning it, the call fails at once. */
const START_UNIT_CALL_FLAGS = Gio.DBusCallFlags.NO_AUTO_START;

// Template keys of the rate-limited journal lines whose text varies (lib/errorLog.js).
const START_UNIT_FAILURE_LOG_KEY = 'StartUnit failed';
const START_UNCONFIRMED_LOG_KEY = 'StartUnit unconfirmed';
const CONNECT_FAILURE_LOG_KEY = 'cannot follow the service';
const STATE_FAILURE_LOG_KEY = 'GetState failed';
const UNREADABLE_STATE_LOG_KEY = 'unreadable state';
const WRONG_SAMPLE_SIGNATURE_LOG_KEY = 'Sample of another signature';
const UNREADABLE_SAMPLE_LOG_KEY = 'unreadable Sample';
const WATCH_CALL_FAILURE_LOG_KEY = 'watch call failed';
const LISTENER_FAILURE_LOG_KEY = 'listener failed';
const TIMEOUT_STEP_FAILURE_LOG_KEY = 'client timeout failed';
const TEARDOWN_FAILURE_LOG_KEY = 'client teardown step failed';

/** Microseconds in a millisecond: a state's age is in microseconds, the watchdog's interval in milliseconds. */
const USEC_PER_MILLISECOND = 1000;
/**
 * The shortest the stall watchdog is armed for: a state exactly as old as the stall is still drawn (it is not stale
 * yet), and nothing of the stall is left, so its watchdog fires at once.
 */
const MIN_STALL_WATCHDOG_MS = 1;

/** What the client knows of the service's data. */
const DataState = Object.freeze({
    /** No state since the start, since the owner last appeared, or since the sequence restarted: Samples wait. */
    AWAITING_STATE: 'awaiting state',
    /** Drawing every Sample. */
    LIVE: 'live',
    /** No Sample for too long: no data shown; the next Sample of the same run draws again. */
    STALLED: 'stalled',
});

/**
 * A snapshot as the client publishes it: the service's (see service/sampler.js) as lib/protocol.js reads it, so each
 * field is of its type or null (missing from a service of another version, or mistyped), and only its own row shows
 * no data. The client's own no-data snapshot has every number null and apps null.
 *
 * @typedef {object} Snapshot
 * @property {number|null} takenAtUsec - The service's monotonic time of the sample.
 * @property {string|null} takenAtClockLabel - Wall-clock 'HH:MM' of the sample.
 * @property {number|null} cpuBusyPercent - Whole-machine CPU busy, 0–100.
 * @property {{performancePercent: number|null, efficiencyPercent: number|null}|null} cpuClusters - Busy percent per
 *     core type.
 * @property {{usedBytes: number, totalBytes: number}|null} memory - Memory in use, and in all.
 * @property {{zramUsedBytes: number, zramRamBytes: number, diskBytes: number}|null} swap - Swap in use.
 * @property {{cpu: number|null, memory: number|null, io: number|null}|null} pressureAvg10 - PSI `some avg10`
 *     percents.
 * @property {{topCpu: object|null, topMemory: object|null}|null} apps - The app ranking.
 * @property {boolean|null} isComplete - True when every read of the sample succeeded.
 */

/**
 * GLib's timeouts at the default priority: whole seconds for the StartUnit chain, milliseconds for the stall watchdog
 * (a whole-second timeout may fire up to a second late, as GLib groups them on the second).
 */
const GLIB_TIMEOUTS = Object.freeze({
    addSeconds: (intervalSeconds, callback) =>
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, intervalSeconds, callback),
    addMilliseconds: (intervalMs, callback) => GLib.timeout_add(GLib.PRIORITY_DEFAULT, intervalMs, callback),
    remove: sourceId => GLib.source_remove(sourceId),
});

/**
 * Asks systemd's user manager, on the session bus, to start the service: StartUnit('resource-pulse.service',
 * 'replace') on /org/freedesktop/systemd1, asynchronously.
 *
 * @param {Gio.DBusConnection} connection - The session bus, where the user manager lives.
 * @param {Gio.Cancellable} cancellable - Cancels the call.
 * @param {(error: Error|null) => void} onAnswered - Called once: null when systemd took the start job, or the failure.
 * @returns {void}
 */
function startResourcePulseUnit(connection, cancellable, onAnswered) {
    const startUnitParameters = new GLib.Variant(START_UNIT_PARAMETERS_SIGNATURE,
        [RESOURCE_PULSE_UNIT_NAME, START_UNIT_MODE]);
    const startUnitReplyType = new GLib.VariantType(START_UNIT_REPLY_SIGNATURE);
    connection.call(SYSTEMD_BUS_NAME, SYSTEMD_OBJECT_PATH, SYSTEMD_MANAGER_INTERFACE_NAME, START_UNIT_METHOD_NAME,
        startUnitParameters, startUnitReplyType, START_UNIT_CALL_FLAGS, DBUS_CALL_TIMEOUT_MS, cancellable,
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
 * Says whether a Sample's sequence shows that the service restarted: it is not past the last one applied. A sequence
 * that either side lacks (a version without one) shows nothing.
 *
 * @param {number|null} lastAppliedSequence - The sequence of the last Sample drawn, or of the state.
 * @param {number|null} sampleSequence - The new Sample's sequence.
 * @returns {boolean} True for a restart.
 */
function isSequenceRestart(lastAppliedSequence, sampleSequence) {
    return lastAppliedSequence !== null && sampleSequence !== null && sampleSequence <= lastAppliedSequence;
}

/**
 * When a state's data was fresh: its snapshot's own time, on the monotonic clock the service and the client share, so
 * a state served by a service whose sampler has stopped is as old as its snapshot. A snapshot with no time counts from
 * now (its arrival), and one stamped in the future from now.
 *
 * @param {Snapshot|null} snapshot - The state's snapshot.
 * @param {number} nowUsec - Monotonic microseconds now.
 * @returns {number} Monotonic microseconds.
 */
function freshnessOfStateSnapshot(snapshot, nowUsec) {
    const takenAtUsec = snapshot?.takenAtUsec ?? null;
    return takenAtUsec === null ? nowUsec : Math.min(takenAtUsec, nowUsec);
}

/**
 * What is left of the stall for data of a given age, for the watchdog a state arms: SAMPLE_STALL_MS less the age,
 * rounded up to a whole millisecond so the watchdog never fires before the stall, and at least MIN_STALL_WATCHDOG_MS.
 *
 * @param {number} dataAgeUsec - How old the data is, in microseconds: from 0 to the stall (older data is stale, and
 *     arms no watchdog).
 * @returns {number} Whole milliseconds, from MIN_STALL_WATCHDOG_MS to SAMPLE_STALL_MS.
 */
function stallRemainderMs(dataAgeUsec) {
    const stallRemainderUsec = SAMPLE_STALL_MS * USEC_PER_MILLISECOND - dataAgeUsec;
    const roundedUpRemainderMs = Math.ceil(stallRemainderUsec / USEC_PER_MILLISECOND);
    return Math.max(MIN_STALL_WATCHDOG_MS, roundedUpRemainderMs);
}

/**
 * Says whether a snapshot has the numbers "no data since" counts from: CPU or memory.
 *
 * @param {Snapshot|null} snapshot - A snapshot.
 * @returns {boolean} True when it has either.
 */
function hasNumbers(snapshot) {
    return snapshot !== null && (snapshot.cpuBusyPercent !== null || snapshot.memory !== null);
}

/**
 * Says whether a Sample appended a number to either history. One that did comes from a sample with numbers, so the
 * unread snapshot it replaces need not be parsed for "no data since"; one that did not (a numberless sample, or a
 * reveal) may come from a service whose sampling fails.
 *
 * @param {{cpu: number|null, memory: number|null}|null} appendedHistory - What the Sample appended; null for nothing.
 * @returns {boolean} True when it appended a CPU or a memory value.
 */
function hasAppendedNumber(appendedHistory) {
    return appendedHistory !== null && (appendedHistory.cpu !== null || appendedHistory.memory !== null);
}

/**
 * The snapshot the client publishes when it has no fresh data: every number null, no ranking.
 *
 * @returns {Snapshot} A new one each time.
 */
function noDataSnapshot() {
    return {
        takenAtUsec: null,
        takenAtClockLabel: null,
        cpuBusyPercent: null,
        cpuClusters: null,
        memory: null,
        swap: null,
        pressureAvg10: {cpu: null, memory: null, io: null},
        apps: null,
        isComplete: false,
    };
}

/**
 * Replaces a history with the values a state carried.
 *
 * @param {RingBuffer} history - The client's history.
 * @param {Array<number|null>|null} values - The state's, oldest first; null (none sent) empties the history.
 * @returns {void}
 */
function replaceHistory(history, values) {
    history.clear();
    for (const value of values ?? [])
        history.push(value);
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

/** Follows the sampler service on the bus, and keeps what the card and the indicator draw. */
export class PulseClient {
    /**
     * @param {object} [options] - Everything injectable, so the rows can run it on fakes; each has a real default.
     * @param {Gio.BusType} [options.busType] - The bus whose connection is fetched when none is given: the session bus,
     *     where both the service and systemd's user manager live.
     * @param {Gio.DBusConnection|null} [options.connection] - A connection to use instead of fetching busType's.
     * @param {(connection: Gio.DBusConnection, cancellable: Gio.Cancellable,
     *     onAnswered: (error: Error|null) => void) => void} [options.startUnit] - Asks systemd to start the service.
     * @param {(connection: Gio.DBusConnection, callbacks: {onOwnerChanged: (nameOwner: string|null) => void,
     *     onSample: (parameters: GLib.Variant) => void}) => object} [options.createLink] - Starts following the
     *     service: serviceLink.js's createResourcePulseLink, whose link reports the owner, delivers each Sample and
     *     makes the calls.
     * @param {() => number} [options.nowUsec] - Monotonic microseconds, for a state's age.
     * @param {{addSeconds: (intervalSeconds: number, callback: () => boolean) => number,
     *     addMilliseconds: (intervalMs: number, callback: () => boolean) => number,
     *     remove: (sourceId: number) => void}} [options.timeouts] - Adds and removes timeouts: whole seconds for the
     *     StartUnit chain, milliseconds for the stall watchdog.
     * @param {RateLimitedLogger} [options.errorLog] - Where failures go. The extension passes one that outlives every
     *     client (it makes one per enable: every blank and every lock), so a lasting failure is logged once per
     *     10 minutes, not once per enable.
     * @param {string|null} [options.lastGoodClockLabel] - 'HH:MM' of the last snapshot with data that an earlier
     *     client saw. The extension keeps it across enables, so a client made after an unlock with the service down
     *     says "no data since" that time rather than a bare "no data"; good data moves it on as usual.
     */
    constructor({
        busType = Gio.BusType.SESSION,
        connection = null,
        startUnit = startResourcePulseUnit,
        createLink = createResourcePulseLink,
        nowUsec = () => GLib.get_monotonic_time(),
        timeouts = GLIB_TIMEOUTS,
        errorLog = new RateLimitedLogger({nowUsec, write: line => console.warn(line)}),
        lastGoodClockLabel = null,
    } = {}) {
        this._busType = busType;
        this._connection = connection;
        this._startUnit = startUnit;
        this._createLink = createLink;
        this._nowUsec = nowUsec;
        this._timeouts = timeouts;
        this._errorLog = errorLog;

        // Cancels every call in flight, and the bus connection's fetch, at destroy(); the best-effort UnwatchDetail
        // uses none.
        this._cancellable = new Gio.Cancellable();
        this._isStarted = false;
        this._isDestroyed = false;
        // The service on the bus (serviceLink.js), from the connection's arrival until destroy().
        this._link = null;
        // The unique name owning the service's bus name, as last seen; null while nobody does.
        this._nameOwner = null;
        // The stall watchdog's pending timeout: armed anew by each Sample drawn and each fresh state, so pending exactly
        // while the data is live; null otherwise, and from the moment it fires.
        this._stallWatchdogSourceId = null;
        // The StartUnit chain's pending step, at most one: a retry after a failure, or the wait for the service to
        // appear after an accepted StartUnit. Every way the chain ends or restarts removes it.
        this._startChainSourceId = null;
        // The latest StartUnit sent: {attemptNumber}, counted from 1 by each start(). An answer to an older one is
        // ignored, so two start() calls in a row cannot both schedule a retry.
        this._latestStartAttempt = null;
        // True while a StartUnit is due but the connection is not up yet.
        this._isServiceStartPending = false;
        this._dataState = DataState.AWAITING_STATE;
        // Each GetState sent takes the next number; only the answer to the latest one is applied.
        this._stateRequestNumber = 0;
        this._isStateRequestInFlight = false;
        this._lastAppliedSequence = null;
        this._isDetailWatchWanted = false;
        // True from a WatchDetail sent to the current owner until an UnwatchDetail follows or that owner leaves (its
        // watches leave with it).
        this._isDetailWatchHeld = false;
        // The latest snapshot parsed. The newest Sample's, while unread, is not here yet: see _unreadSampleEnvelope.
        this._latestSnapshot = null;
        // The newest Sample drawn while its snapshot is still unread (lib/protocol.js parseSampleEnvelope's result),
        // so it is newer than _latestSnapshot; null once parsed (_parseUnreadSnapshot), and before any Sample.
        this._unreadSampleEnvelope = null;
        this._lastGoodClockLabel = lastGoodClockLabel;
        this._cpuHistory = new RingBuffer(CARD_HISTORY_SAMPLES);
        this._memoryHistory = new RingBuffer(CARD_HISTORY_SAMPLES);
        // The two kinds of listener, by id. Both take ids from one sequence, so no id is in both.
        this._historyListeners = new Map();
        this._snapshotListeners = new Map();
        this._nextListenerId = 1;
    }

    /**
     * The most recent snapshot. The newest Sample's is parsed here when first read after it arrived, then kept, so a
     * second read gives the same object.
     *
     * @returns {Snapshot|null} The snapshot, or null before the first state.
     */
    get latestSnapshot() {
        this._parseUnreadSnapshot();
        return this._latestSnapshot;
    }

    /**
     * 'HH:MM' of the last snapshot with CPU or memory data, for "no data since". Right with latestSnapshot never
     * read: the newest Sample, while unread, is parsed here too.
     *
     * @returns {string|null} The label, or null when no snapshot has had data and none was seeded.
     */
    get lastGoodClockLabel() {
        this._parseUnreadSnapshot();
        return this._lastGoodClockLabel;
    }

    /**
     * @returns {boolean} True while drawing Samples: from a fresh state until no data, and never once destroyed (a
     *     destroyed client keeps the data state it had, but draws nothing more).
     */
    get isLive() {
        return !this._isDestroyed && this._dataState === DataState.LIVE;
    }

    /** @returns {RingBuffer} CPU busy fractions 0–1, null for no data, oldest first: the service's, as received. */
    get cpuHistory() {
        return this._cpuHistory;
    }

    /** @returns {RingBuffer} Memory used fractions 0–1, null for no data, oldest first: the service's, as received. */
    get memoryHistory() {
        return this._memoryHistory;
    }

    /**
     * Asks systemd to start the service, and the first time also starts following it: the bus connection and the
     * link. Every call asks systemd again (each enable makes one), restarting the retries; nothing is connected twice.
     * Does nothing once destroyed.
     *
     * @returns {void}
     */
    start() {
        if (this._isDestroyed)
            return;
        this._restartServiceStartAttempts();
        if (this._isStarted)
            return;
        this._isStarted = true;
        this._connect();
    }

    /**
     * Stops everything for good: releases a held detail watch (an UnwatchDetail no cancel can stop), cancels every
     * call in flight, removes every timeout, destroys the link (its name watch and its subscription) and forgets every
     * listener. Each step runs whatever the others throw. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        if (this._isDestroyed)
            return;
        this._isDestroyed = true;
        runEveryStep([
            {name: 'release the detail watch', run: () => this._sendUnwatchDetail(null)},
            {name: 'cancel the calls in flight', run: () => this._cancellable.cancel()},
            {name: 'remove the StartUnit chain step', run: () => this._cancelStartChainStep()},
            {name: 'remove the stall watchdog', run: () => this._disarmStallWatchdog()},
            {name: 'destroy the link', run: () => this._destroyLink()},
            {name: 'forget the history listeners', run: () => this._historyListeners.clear()},
            {name: 'forget the snapshot listeners', run: () => this._snapshotListeners.clear()},
        ], (stepName, error) => {
            const errorText = describeError(error);
            this._errorLog.log(`client teardown: ${stepName} failed: ${errorText}`, TEARDOWN_FAILURE_LOG_KEY);
        });
    }

    /**
     * Says whether a detail watch is wanted (lib/wiring.js isDetailWatchWanted). Only a change is sent, and only to an
     * owner: WatchDetail when it becomes wanted, UnwatchDetail when it stops being. With no owner it is only recorded,
     * and sent when one appears. Becoming wanted while the data is live also tells snapshot listeners the latest
     * snapshot at once, since they were told of no Sample while it was not; with no data they already hold the no-data
     * snapshot.
     *
     * @param {boolean} isWanted - True while the card can be seen or the dropdown is open.
     * @returns {void}
     */
    setDetailWatchWanted(isWanted) {
        if (this._isDestroyed || isWanted === this._isDetailWatchWanted)
            return;
        this._isDetailWatchWanted = isWanted;
        this._sendDetailWatchChange(isWanted);
        if (isWanted && this.isLive)
            this._notifySnapshotListeners(this.latestSnapshot);
    }

    /**
     * Adds a history listener (the top bar): told, with no argument, after every Sample that appended to the
     * histories, every state and every no data. It reads the histories, and latestSnapshot if it shows numbers.
     *
     * @param {() => void} callback - Called once the histories have changed.
     * @returns {number} An id for removeHistoryListener.
     */
    addHistoryListener(callback) {
        return this._registerListener(this._historyListeners, callback);
    }

    /**
     * Removes a callback added with addHistoryListener; an unknown id is ignored.
     *
     * @param {number} listenerId - The id addHistoryListener returned.
     * @returns {void}
     */
    removeHistoryListener(listenerId) {
        this._historyListeners.delete(listenerId);
    }

    /**
     * Adds a snapshot listener (the card, the dropdown card): told the snapshot on every state and every no data, on
     * every Sample drawn while the detail watch is wanted, and the latest snapshot once when the watch becomes wanted
     * while the data is live.
     *
     * @param {(snapshot: Snapshot|null) => void} callback - Called with the snapshot, which is the latest.
     * @returns {number} An id for removeListener.
     */
    addListener(callback) {
        return this._registerListener(this._snapshotListeners, callback);
    }

    /**
     * Removes a callback added with addListener; an unknown id is ignored.
     *
     * @param {number} listenerId - The id addListener returned.
     * @returns {void}
     */
    removeListener(listenerId) {
        this._snapshotListeners.delete(listenerId);
    }

    /**
     * Adds a listener of one kind under the next id.
     *
     * @param {Map<number, Function>} listeners - The kind's listeners, by id.
     * @param {Function} callback - The listener.
     * @returns {number} Its id.
     */
    _registerListener(listeners, callback) {
        const listenerId = this._nextListenerId++;
        listeners.set(listenerId, callback);
        return listenerId;
    }

    /**
     * Sends a change of the wanted detail watch to the owner, if there is one: WatchDetail when it became wanted,
     * UnwatchDetail when it stopped being. With no owner nothing goes out; the owner that appears is sent a wanted
     * watch then (_onServiceAppeared).
     *
     * @param {boolean} isWanted - The watch is wanted now.
     * @returns {void}
     */
    _sendDetailWatchChange(isWanted) {
        if (this._nameOwner === null)
            return;
        if (isWanted)
            this._sendWatchDetail();
        else
            this._sendUnwatchDetail(this._cancellable);
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
     * superseded, is ignored). A failure is logged. While the service is on the bus nothing follows: there is nothing
     * left to start, and a retry could restart it after someone stopped it on purpose. Otherwise an accepted StartUnit
     * waits for the service to appear, and a failure is retried after nextStartRetryDelaySeconds.
     *
     * @param {{attemptNumber: number}} startAttempt - The attempt answered.
     * @param {Error|null} error - Null when systemd accepted the start job.
     * @returns {void}
     */
    _onServiceStartAnswered(startAttempt, error) {
        if (this._isDestroyed || startAttempt !== this._latestStartAttempt)
            return;
        if (error !== null) {
            const errorText = describeError(error);
            this._errorLog.log(`StartUnit ${RESOURCE_PULSE_UNIT_NAME} failed: ${errorText}`,
                START_UNIT_FAILURE_LOG_KEY);
        }
        if (this._nameOwner !== null)
            return;
        if (error === null)
            this._awaitServiceAppearance(startAttempt);
        else
            this._scheduleStartRetry(startAttempt);
    }

    /**
     * Waits START_CONFIRMATION_TIMEOUT_SECONDS for the service an accepted StartUnit started to appear on the bus. Its
     * appearing ends the chain (and removes this wait); otherwise the attempt counts as failed.
     *
     * @param {{attemptNumber: number}} startAttempt - The accepted attempt.
     * @returns {void}
     */
    _awaitServiceAppearance(startAttempt) {
        this._startChainSourceId = this._timeouts.addSeconds(START_CONFIRMATION_TIMEOUT_SECONDS,
            () => this._onStartConfirmationTimeout(startAttempt));
    }

    /**
     * The service did not appear after an accepted StartUnit (the unit at its start limit, or exiting at once): logs
     * it and retries, as for a failure. Runs as a GLib timeout, so it never throws.
     *
     * @param {{attemptNumber: number}} startAttempt - The accepted attempt.
     * @returns {boolean} GLib.SOURCE_REMOVE: each step of the chain is a timeout of its own.
     */
    _onStartConfirmationTimeout(startAttempt) {
        this._startChainSourceId = null;
        this._runWithoutThrowing('retry an unconfirmed StartUnit', () => {
            this._errorLog.log(`StartUnit ${RESOURCE_PULSE_UNIT_NAME} was accepted, but the service did not appear ` +
                `on the bus within ${START_CONFIRMATION_TIMEOUT_SECONDS} s`, START_UNCONFIRMED_LOG_KEY);
            this._scheduleStartRetry(startAttempt);
        });
        return GLib.SOURCE_REMOVE;
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
     * Removes the StartUnit chain's pending step, if any: a retry, or the wait for the service to appear.
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
     * Sends a StartUnit that waited for the connection, and starts following the service: the link reports its
     * owner (soon after, even when nobody owns the name) and delivers its Samples.
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
            onSample: parameters => this._onSampleSignal(parameters),
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
        this._errorLog.log(`cannot follow the service on the bus: ${errorText}`, CONNECT_FAILURE_LOG_KEY);
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
        if (nameOwner !== null)
            this._onServiceAppeared(nameOwner);
    }

    /**
     * The service left the bus: no data until a new owner's state, its watch gone with it, and no StartUnit (a stop
     * stays a stop until the next start()).
     *
     * @returns {void}
     */
    _onServiceVanished() {
        this._nameOwner = null;
        this._isDetailWatchHeld = false;
        // An answer still on its way comes from the owner that left.
        this._stateRequestNumber++;
        this._isStateRequestInFlight = false;
        this._stopDrawing(DataState.AWAITING_STATE);
    }

    /**
     * A service is on the bus: it runs, so the StartUnit chain ends (its pending step removed, and a StartUnit still
     * on its way superseded, so its answer cannot start a retry once this owner has left again); its state is read,
     * and a wanted watch asserted.
     *
     * @param {string} nameOwner - Its unique name.
     * @returns {void}
     */
    _onServiceAppeared(nameOwner) {
        this._nameOwner = nameOwner;
        this._cancelStartChainStep();
        this._latestStartAttempt = null;
        this._requestState();
        if (this._isDetailWatchWanted)
            this._sendWatchDetail();
    }

    /**
     * Calls GetState. Only the answer to the latest call is applied. Does nothing once destroyed: a listener told no
     * data (a sequence restart, an owner that changed) may have destroyed the client, and its link with it, just
     * before.
     *
     * @returns {void}
     */
    _requestState() {
        if (this._isDestroyed)
            return;
        this._stateRequestNumber++;
        const stateRequestNumber = this._stateRequestNumber;
        this._isStateRequestInFlight = true;
        this._callService(GET_STATE_METHOD_NAME, this._cancellable,
            (error, reply) => this._onStateAnswered(stateRequestNumber, error, reply));
    }

    /**
     * Applies GetState's answer, if it answers the latest call. A failure or an unreadable state is logged and leaves
     * no data; the next Sample asks again.
     *
     * @param {number} stateRequestNumber - The call's number.
     * @param {Error|null} error - Why the call failed, or null.
     * @param {GLib.Variant|null} reply - The reply.
     * @returns {void}
     */
    _onStateAnswered(stateRequestNumber, error, reply) {
        if (this._isDestroyed || stateRequestNumber !== this._stateRequestNumber)
            return;
        this._isStateRequestInFlight = false;
        if (error !== null) {
            const errorText = describeError(error);
            this._errorLog.log(`${GET_STATE_METHOD_NAME} failed: ${errorText}`, STATE_FAILURE_LOG_KEY);
            return;
        }
        const state = parseStatePayload(stringOfVariant(reply, STATE_REPLY_SIGNATURE));
        if (state === null) {
            this._errorLog.log(`${GET_STATE_METHOD_NAME} answered something that is not a state`,
                UNREADABLE_STATE_LOG_KEY);
            return;
        }
        this._applyState(state);
    }

    /**
     * Takes a state whole: both histories and the snapshot replace the client's, and Samples are drawn from here on.
     * Its freshness is its snapshot's own time (freshnessOfStateSnapshot), so a state whose snapshot is already stale
     * (a service that answers while its sampler has stopped) shows no data at once, since that snapshot's time, rather
     * than its old numbers as live, and arms no watchdog; the next Sample of the same run draws again. A fresh state
     * arms the watchdog for what is left of the stall (stallRemainderMs), so its numbers show as live for no longer
     * than the stall after they were taken.
     *
     * @param {object} state - lib/protocol.js parseStatePayload's result.
     * @returns {void}
     */
    _applyState(state) {
        replaceHistory(this._cpuHistory, state.histories.cpu);
        replaceHistory(this._memoryHistory, state.histories.memory);
        this._lastAppliedSequence = state.sequence;
        this._dataState = DataState.LIVE;
        const nowUsec = this._nowUsec();
        const freshAtUsec = freshnessOfStateSnapshot(state.snapshot, nowUsec);
        if (isSampleStale({lastFreshDataAtUsec: freshAtUsec, nowUsec})) {
            this._recordLastGoodClockLabel(state.snapshot);
            this._stopDrawing(DataState.STALLED);
            return;
        }
        // Armed before listeners are told, so one that destroys the client leaves no watchdog behind.
        this._armStallWatchdog(stallRemainderMs(nowUsec - freshAtUsec));
        this._publish(state.snapshot);
    }

    /**
     * Reads a Sample signal the link delivered: one of signature '(s)' holding a JSON object is drawn, its snapshot
     * left unread, and a malformed one is logged and dropped.
     *
     * @param {GLib.Variant} parameters - The signal's parameters.
     * @returns {void}
     */
    _onSampleSignal(parameters) {
        if (this._isDestroyed)
            return;
        const sampleText = stringOfVariant(parameters, SAMPLE_SIGNAL_SIGNATURE);
        if (sampleText === null) {
            this._errorLog.log(`dropped a ${SAMPLE_SIGNAL_NAME} whose parameters are not ${SAMPLE_SIGNAL_SIGNATURE}`,
                WRONG_SAMPLE_SIGNATURE_LOG_KEY);
            return;
        }
        const sampleEnvelope = parseSampleEnvelope(sampleText);
        if (sampleEnvelope === null) {
            this._errorLog.log(`dropped a ${SAMPLE_SIGNAL_NAME} that is not a JSON object`, UNREADABLE_SAMPLE_LOG_KEY);
            return;
        }
        this._onSample(sampleEnvelope);
    }

    /**
     * Draws a Sample, unless no state is held (then it waits for one, asking if no GetState is on its way: the state
     * includes this Sample) or its sequence restarted (then no data, until a fresh GetState).
     *
     * @param {object} sampleEnvelope - lib/protocol.js parseSampleEnvelope's result.
     * @returns {void}
     */
    _onSample(sampleEnvelope) {
        if (this._dataState === DataState.AWAITING_STATE) {
            if (!this._isStateRequestInFlight && this._nameOwner !== null)
                this._requestState();
            return;
        }
        if (isSequenceRestart(this._lastAppliedSequence, sampleEnvelope.sequence)) {
            this._stopDrawing(DataState.AWAITING_STATE);
            this._requestState();
            return;
        }
        this._applySample(sampleEnvelope);
    }

    /**
     * Appends what a Sample appended (nothing for a null appendedHistory), makes it the newest Sample with its snapshot
     * unread, re-arms the watchdog for the whole stall, and tells listeners. A stall ends here.
     *
     * @param {object} sampleEnvelope - lib/protocol.js parseSampleEnvelope's result.
     * @returns {void}
     */
    _applySample(sampleEnvelope) {
        const {appendedHistory} = sampleEnvelope;
        if (appendedHistory !== null) {
            this._cpuHistory.push(appendedHistory.cpu);
            this._memoryHistory.push(appendedHistory.memory);
        }
        this._lastAppliedSequence = sampleEnvelope.sequence;
        this._dataState = DataState.LIVE;
        // Armed before listeners are told, so one that destroys the client leaves no watchdog behind.
        this._armStallWatchdog(SAMPLE_STALL_MS);
        this._keepSampleUnread(sampleEnvelope);
        this._notifyOfSample(appendedHistory !== null);
    }

    /**
     * Makes a Sample the newest, with its snapshot unread. One that appended no number (a numberless sample, or a
     * reveal) has the unread snapshot it replaces parsed first, so "no data since" still names the last Sample with
     * numbers; one that appended a number replaces it unparsed, which is the parse a Sample nobody shows saves.
     *
     * @param {object} sampleEnvelope - lib/protocol.js parseSampleEnvelope's result.
     * @returns {void}
     */
    _keepSampleUnread(sampleEnvelope) {
        if (!hasAppendedNumber(sampleEnvelope.appendedHistory))
            this._parseUnreadSnapshot();
        this._unreadSampleEnvelope = sampleEnvelope;
    }

    /**
     * Tells listeners of the Sample just drawn: history listeners if it appended to the histories, then, unless one of
     * them destroyed the client, snapshot listeners while the detail watch is wanted, with its snapshot parsed now.
     *
     * @param {boolean} hasAppendedHistory - The Sample appended to the histories (its appendedHistory is not null).
     * @returns {void}
     */
    _notifyOfSample(hasAppendedHistory) {
        if (hasAppendedHistory)
            this._notifyHistoryListeners();
        if (!this._isDestroyed && this._isDetailWatchWanted)
            this._notifySnapshotListeners(this.latestSnapshot);
    }

    /**
     * Stops drawing the service's data: removes the stall watchdog, since nothing waits for a Sample while the data is
     * not live (the owner left, the sequence restarted, a state was already stale, or the watchdog itself fired), moves
     * to the given state, and publishes no data if the data was live, so it happens once however many reasons follow.
     *
     * @param {string} nextDataState - DataState.AWAITING_STATE or DataState.STALLED.
     * @returns {void}
     */
    _stopDrawing(nextDataState) {
        this._disarmStallWatchdog();
        const wasLive = this._dataState === DataState.LIVE;
        this._dataState = nextDataState;
        if (wasLive)
            this._publishNoData();
    }

    /**
     * Publishes the no-data state: a gap in both histories (so the memory bar and the graphs' newest slot show no
     * data) and the all-null snapshot. lastGoodClockLabel is kept, so "no data since" names the last good sample.
     *
     * @returns {void}
     */
    _publishNoData() {
        this._cpuHistory.push(null);
        this._memoryHistory.push(null);
        this._publish(noDataSnapshot());
    }

    /**
     * Makes a state's snapshot or the no-data one the latest, moves "no data since" on when it has numbers and a time,
     * and tells both kinds of listener. A Sample still unread is parsed first: this snapshot replaces it, and "no data
     * since" counts it.
     *
     * @param {Snapshot|null} snapshot - The new latest snapshot.
     * @returns {void}
     */
    _publish(snapshot) {
        this._parseUnreadSnapshot();
        this._latestSnapshot = snapshot;
        this._recordLastGoodClockLabel(snapshot);
        this._notifyHistoryListeners();
        this._notifySnapshotListeners(snapshot);
    }

    /**
     * Parses the newest Sample's snapshot if it is still unread: it becomes the latest, and moves "no data since" on
     * as it would have on arrival. A snapshot that is not an object parses to null, as it did on arrival.
     *
     * @returns {void}
     */
    _parseUnreadSnapshot() {
        const sampleEnvelope = this._unreadSampleEnvelope;
        if (sampleEnvelope === null)
            return;
        this._unreadSampleEnvelope = null;
        const snapshot = parseEnvelopeSnapshot(sampleEnvelope.rawSnapshot);
        this._latestSnapshot = snapshot;
        this._recordLastGoodClockLabel(snapshot);
    }

    /**
     * Moves "no data since" to a snapshot's time, when it has numbers and a time.
     *
     * @param {Snapshot|null} snapshot - A snapshot from the service.
     * @returns {void}
     */
    _recordLastGoodClockLabel(snapshot) {
        if (hasNumbers(snapshot) && snapshot.takenAtClockLabel !== null)
            this._lastGoodClockLabel = snapshot.takenAtClockLabel;
    }

    /**
     * Tells every history listener that the histories changed. They take no argument.
     *
     * @returns {void}
     */
    _notifyHistoryListeners() {
        this._callEachListener(this._historyListeners, historyListener => historyListener());
    }

    /**
     * Tells every snapshot listener the latest snapshot.
     *
     * @param {Snapshot|null} snapshot - The latest snapshot.
     * @returns {void}
     */
    _notifySnapshotListeners(snapshot) {
        this._callEachListener(this._snapshotListeners, snapshotListener => snapshotListener(snapshot));
    }

    /**
     * Calls every listener of one kind, in the order they were added. One that throws is logged, and the rest still
     * run.
     *
     * @param {Map<number, Function>} listeners - The kind's listeners, by id.
     * @param {(listener: Function) => void} callListener - Calls one listener with what its kind is told.
     * @returns {void}
     */
    _callEachListener(listeners, callListener) {
        for (const [listenerId, listener] of [...listeners]) {
            // A listener may destroy the client or remove a later listener.
            if (this._isDestroyed)
                return;
            if (!listeners.has(listenerId))
                continue;
            try {
                callListener(listener);
            } catch (error) {
                const errorText = describeError(error);
                this._errorLog.log(`listener failed: ${errorText}`, LISTENER_FAILURE_LOG_KEY);
            }
        }
    }

    /**
     * Arms the stall watchdog anew: removes the pending one, if any, and adds one that shows no data after intervalMs
     * with no Sample. Each Sample drawn calls it, so while Samples flow it never fires.
     *
     * @param {number} intervalMs - Milliseconds until no data: SAMPLE_STALL_MS after a Sample, what is left of it
     *     after a state.
     * @returns {void}
     */
    _armStallWatchdog(intervalMs) {
        this._disarmStallWatchdog();
        this._stallWatchdogSourceId = this._timeouts.addMilliseconds(intervalMs,
            () => this._onStallWatchdogTimeout());
    }

    /**
     * Removes the stall watchdog's pending timeout, if any.
     *
     * @returns {void}
     */
    _disarmStallWatchdog() {
        if (this._stallWatchdogSourceId === null)
            return;
        const stallWatchdogSourceId = this._stallWatchdogSourceId;
        this._stallWatchdogSourceId = null;
        this._timeouts.remove(stallWatchdogSourceId);
    }

    /**
     * The stall watchdog fired: no Sample came for as long as it was armed. Shows no data, once. Runs as a GLib
     * timeout, so it never throws, and forgets its id first: its source ends as it returns.
     *
     * @returns {boolean} GLib.SOURCE_REMOVE: the next Sample, or the next fresh state, arms a new one.
     */
    _onStallWatchdogTimeout() {
        this._stallWatchdogSourceId = null;
        this._runWithoutThrowing('show no data after a stall', () => this._stopDrawing(DataState.STALLED));
        return GLib.SOURCE_REMOVE;
    }

    /**
     * Runs one step of a timeout callback, logging (never throwing) what it throws, even should the logging throw.
     *
     * @param {string} stepName - What the step does, for the journal.
     * @param {() => void} step - The step.
     * @returns {void}
     */
    _runWithoutThrowing(stepName, step) {
        runEveryStep([{name: stepName, run: step}], (failedStepName, error) => {
            const errorText = describeError(error);
            this._errorLog.log(`could not ${failedStepName}: ${errorText}`, TIMEOUT_STEP_FAILURE_LOG_KEY);
        });
    }

    /**
     * Sends WatchDetail to the owner, and records that it holds the watch. Does nothing once destroyed, as
     * _requestState: a new owner is sent both, after a listener told no data by the old one leaving may have destroyed
     * the client.
     *
     * @returns {void}
     */
    _sendWatchDetail() {
        if (this._isDestroyed)
            return;
        this._isDetailWatchHeld = true;
        this._callService(WATCH_DETAIL_METHOD_NAME, this._cancellable,
            error => this._logWatchCallFailure(WATCH_DETAIL_METHOD_NAME, error));
    }

    /**
     * Sends UnwatchDetail, if the current owner holds a watch of this client's. destroy() passes no cancellable: its
     * cancel must not stop the one call that releases the watch.
     *
     * @param {Gio.Cancellable|null} cancellable - The call's cancellable.
     * @returns {void}
     */
    _sendUnwatchDetail(cancellable) {
        if (!this._isDetailWatchHeld)
            return;
        this._isDetailWatchHeld = false;
        this._callService(UNWATCH_DETAIL_METHOD_NAME, cancellable,
            error => this._logWatchCallFailure(UNWATCH_DETAIL_METHOD_NAME, error));
    }

    /**
     * Logs a watch call that failed, other than by the client's own cancel. Touches nothing else, so it is safe after
     * destroy().
     *
     * @param {string} methodName - WatchDetail or UnwatchDetail.
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
     * Calls a method of the service's owner through the link: asynchronously, with DBUS_CALL_TIMEOUT_MS. Only with an
     * owner, so the link is there and holds the same owner (it records each one before reporting it).
     *
     * @param {string} methodName - GetState, WatchDetail or UnwatchDetail.
     * @param {Gio.Cancellable|null} cancellable - The call's cancellable.
     * @param {(error: Error|null, reply: GLib.Variant|null) => void} onAnswered - Called once, with the reply or the
     *     failure.
     * @returns {void}
     */
    _callService(methodName, cancellable, onAnswered) {
        this._link.call(methodName, cancellable, onAnswered);
    }

    /**
     * Destroys the link, if there is one, and lets it go: its name watch and its subscription end.
     *
     * @returns {void}
     */
    _destroyLink() {
        const link = this._link;
        this._link = null;
        link?.destroy();
    }
}
