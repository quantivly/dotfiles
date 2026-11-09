// The extension's one source of numbers: a client of the Resource Pulse sampler service (service/, run by systemd as
// resource-pulse.service) on the session bus. It keeps the interface the card and the indicator draw from (cpuHistory,
// memoryHistory, latestSnapshot, lastGoodClockLabel, addListener and removeListener) and does no sampling, no file IO
// and no subprocess. Gio and GLib only (no Shell, St, Clutter or Meta), so it runs under plain gjs, and its proxy,
// StartUnit, connection, clock and timeouts are all injectable.
//
// It runs inside gnome-shell, the compositor, so:
// - every D-Bus call is asynchronous, with DBUS_CALL_TIMEOUT_MS, and none is ever synchronous;
// - every callback checks for destroy() before it touches anything, and destroy() cancels every pending call, removes
//   every timeout and disconnects every handler: GNOME 50 disables the extension, destroying this client, on every
//   lock and every blank, so a teardown must leave nothing behind;
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
// - No data, once: when no Sample has come for longer than SAMPLE_STALL_TICKS intervals, or the service's sequence
//   restarts, it publishes one all-null snapshot and a gap in both histories. After a stall the next Sample of the
//   same run draws again; after a restart nothing is drawn until a fresh GetState answers.
// - The detail watch: WatchDetail and UnwatchDetail go out only when the wanted flag changes, and only to an owner.
//   destroy() sends UnwatchDetail, uncancellable and best-effort, while a watch is held: the shell's bus connection
//   outlives the extension, and the service drops a caller's watches only when its connection closes.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {
    CARD_HISTORY_SAMPLES, DBUS_CALL_TIMEOUT_MS, SAMPLE_INTERVAL_SECONDS, START_CONFIRMATION_TIMEOUT_SECONDS,
} from './lib/constants.js';
import {RateLimitedLogger, describeError} from './lib/errorLog.js';
import {RingBuffer} from './lib/history.js';
import {
    GET_STATE_METHOD_NAME, RESOURCE_PULSE_BUS_NAME, RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_OBJECT_PATH,
    SAMPLE_SIGNAL_NAME, SAMPLE_SIGNAL_SIGNATURE, UNWATCH_DETAIL_METHOD_NAME, WATCH_DETAIL_METHOD_NAME,
    parseSamplePayload, parseStatePayload,
} from './lib/protocol.js';
import {runEveryStep} from './lib/teardown.js';
import {isSampleStale, nextStartRetryDelaySeconds} from './lib/wiring.js';

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
/**
 * The proxy loads no properties (the interface has none) and never asks the bus to activate the service: systemd
 * starts it, through StartUnit.
 */
const PROXY_FLAGS = Gio.DBusProxyFlags.DO_NOT_LOAD_PROPERTIES | Gio.DBusProxyFlags.DO_NOT_AUTO_START;
/** No call asks the bus to activate a name: a name nobody owns fails the call at once. */
const CALL_FLAGS = Gio.DBusCallFlags.NO_AUTO_START;
/** The GObject signal a GDBusProxy emits when the bus name's owner changes. */
const NAME_OWNER_NOTIFY_SIGNAL = 'notify::g-name-owner';
/** The GObject signal a GDBusProxy emits for each D-Bus signal from the owner. */
const PROXY_DBUS_SIGNAL_SIGNAL = 'g-signal';

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

/** GLib's timeouts at the default priority: the client's staleness check and its StartUnit retries. */
const GLIB_TIMEOUTS = Object.freeze({
    addSeconds: (intervalSeconds, callback) =>
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, intervalSeconds, callback),
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
 * Creates the proxy for the service's object, asynchronously. The proxy follows the bus name's owner
 * (notify::g-name-owner) and delivers the owner's signals (g-signal).
 *
 * @param {Gio.DBusConnection} connection - The session bus.
 * @param {Gio.Cancellable} cancellable - Cancels the creation.
 * @param {(error: Error|null, proxy: Gio.DBusProxy|null) => void} onCreated - Called once, with the proxy or the
 *     failure.
 * @returns {void}
 */
function createResourcePulseProxy(connection, cancellable, onCreated) {
    Gio.DBusProxy.new(connection, PROXY_FLAGS, null, RESOURCE_PULSE_BUS_NAME, RESOURCE_PULSE_OBJECT_PATH,
        RESOURCE_PULSE_INTERFACE_NAME, cancellable, (_source, result) => {
            let proxy;
            try {
                proxy = Gio.DBusProxy.new_finish(result);
            } catch (error) {
                onCreated(error, null);
                return;
            }
            onCreated(null, proxy);
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
 * Says whether a snapshot has the numbers "no data since" counts from: CPU or memory.
 *
 * @param {Snapshot|null} snapshot - A snapshot.
 * @returns {boolean} True when it has either.
 */
function hasNumbers(snapshot) {
    return snapshot !== null && (snapshot.cpuBusyPercent !== null || snapshot.memory !== null);
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
     * @param {(connection: Gio.DBusConnection, cancellable: Gio.Cancellable,
     *     onCreated: (error: Error|null, proxy: Gio.DBusProxy|null) => void) => void} [options.createProxy] - Creates
     *     the service's proxy.
     * @param {() => number} [options.nowUsec] - Monotonic microseconds, for staleness.
     * @param {{addSeconds: (intervalSeconds: number, callback: () => boolean) => number,
     *     remove: (sourceId: number) => void}} [options.timeouts] - Adds and removes timeouts.
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
        createProxy = createResourcePulseProxy,
        nowUsec = () => GLib.get_monotonic_time(),
        timeouts = GLIB_TIMEOUTS,
        errorLog = new RateLimitedLogger({nowUsec, write: line => console.warn(line)}),
        lastGoodClockLabel = null,
    } = {}) {
        this._busType = busType;
        this._connection = connection;
        this._startUnit = startUnit;
        this._createProxy = createProxy;
        this._nowUsec = nowUsec;
        this._timeouts = timeouts;
        this._errorLog = errorLog;

        // Cancels every call and creation in flight, at destroy(); the best-effort UnwatchDetail uses none.
        this._cancellable = new Gio.Cancellable();
        this._isStarted = false;
        this._isDestroyed = false;
        this._proxy = null;
        this._proxyHandlerIds = [];
        // The unique name owning the service's bus name, as last seen; null while nobody does.
        this._nameOwner = null;
        this._staleCheckSourceId = null;
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
        this._lastFreshDataAtUsec = null;
        this._isDetailWatchWanted = false;
        // True from a WatchDetail sent to the current owner until an UnwatchDetail follows or that owner leaves (its
        // watches leave with it).
        this._isDetailWatchHeld = false;
        this._latestSnapshot = null;
        this._lastGoodClockLabel = lastGoodClockLabel;
        this._cpuHistory = new RingBuffer(CARD_HISTORY_SAMPLES);
        this._memoryHistory = new RingBuffer(CARD_HISTORY_SAMPLES);
        this._listeners = new Map();
        this._nextListenerId = 1;
    }

    /** @returns {Snapshot|null} The most recent snapshot, or null before the first state. */
    get latestSnapshot() {
        return this._latestSnapshot;
    }

    /** @returns {string|null} 'HH:MM' of the last snapshot with CPU or memory data, for "no data since". */
    get lastGoodClockLabel() {
        return this._lastGoodClockLabel;
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
     * Asks systemd to start the service, and the first time also starts following it: the bus connection, the proxy
     * and the staleness check. Every call asks systemd again (each enable makes one), restarting the retries; nothing
     * is connected twice. Does nothing once destroyed.
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
        this._staleCheckSourceId = this._timeouts.addSeconds(SAMPLE_INTERVAL_SECONDS,
            () => this._onStaleCheckTimeout());
        this._connect();
    }

    /**
     * Stops everything for good: releases a held detail watch (an UnwatchDetail no cancel can stop), cancels every
     * call in flight, removes every timeout, disconnects from the proxy and forgets every listener. Each step runs
     * whatever the others throw. Safe twice.
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
            {name: 'remove the timeouts', run: () => this._removeTimeouts()},
            {name: 'disconnect from the proxy', run: () => this._disconnectFromProxy()},
            {name: 'forget the listeners', run: () => this._listeners.clear()},
        ], (stepName, error) => {
            const errorText = describeError(error);
            this._errorLog.log(`client teardown: ${stepName} failed: ${errorText}`, TEARDOWN_FAILURE_LOG_KEY);
        });
    }

    /**
     * Says whether a detail watch is wanted (lib/wiring.js isDetailWatchWanted). Only a change is sent, and only to an
     * owner: WatchDetail when it becomes wanted, UnwatchDetail when it stops being. With no owner it is only recorded,
     * and sent when one appears.
     *
     * @param {boolean} isWanted - True while the card can be seen or the dropdown is open.
     * @returns {void}
     */
    setDetailWatchWanted(isWanted) {
        if (this._isDestroyed || isWanted === this._isDetailWatchWanted)
            return;
        this._isDetailWatchWanted = isWanted;
        if (this._nameOwner === null)
            return;
        if (isWanted)
            this._sendWatchDetail();
        else
            this._sendUnwatchDetail(this._cancellable);
    }

    /**
     * Adds a callback for each new snapshot: every state, every Sample drawn, and every no-data snapshot.
     *
     * @param {(snapshot: Snapshot|null) => void} callback - Called with the new latest snapshot.
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
     * Sends a StartUnit that waited for the connection, and creates the service's proxy.
     *
     * @param {Gio.DBusConnection} connection - The bus connection.
     * @returns {void}
     */
    _onConnected(connection) {
        if (this._isDestroyed)
            return;
        this._connection = connection;
        this._attemptServiceStartIfConnected();
        this._createProxy(connection, this._cancellable, (error, proxy) => this._onProxyCreated(error, proxy));
    }

    /**
     * Connects to the new proxy's owner changes and signals, and takes its owner as it is now.
     *
     * @param {Error|null} error - Why it could not be created, or null.
     * @param {Gio.DBusProxy|null} proxy - The proxy.
     * @returns {void}
     */
    _onProxyCreated(error, proxy) {
        if (this._isDestroyed)
            return;
        if (error !== null) {
            this._logFollowFailure(error);
            return;
        }
        this._proxy = proxy;
        this._proxyHandlerIds = [
            proxy.connect(NAME_OWNER_NOTIFY_SIGNAL, () => this._followNameOwner()),
            proxy.connect(PROXY_DBUS_SIGNAL_SIGNAL,
                (_proxy, _senderName, signalName, parameters) => this._onServiceSignal(signalName, parameters)),
        ];
        this._followNameOwner();
    }

    /**
     * Logs that the client cannot follow the service at all (no bus connection, or no proxy), unless destroyed.
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
     * Acts on the proxy's owner as it is now: an owner that left vanished, a new one appeared (both, for a direct
     * change from one to another).
     *
     * @returns {void}
     */
    _followNameOwner() {
        if (this._isDestroyed)
            return;
        const nameOwner = this._proxy.get_name_owner();
        if (nameOwner === this._nameOwner)
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
     * Calls GetState. Only the answer to the latest call is applied.
     *
     * @returns {void}
     */
    _requestState() {
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
     * than its old numbers as live; the next Sample of the same run draws again.
     *
     * @param {object} state - lib/protocol.js parseStatePayload's result.
     * @returns {void}
     */
    _applyState(state) {
        replaceHistory(this._cpuHistory, state.histories.cpu);
        replaceHistory(this._memoryHistory, state.histories.memory);
        this._lastAppliedSequence = state.sequence;
        this._lastFreshDataAtUsec = freshnessOfStateSnapshot(state.snapshot, this._nowUsec());
        this._dataState = DataState.LIVE;
        if (this._isLiveDataStale()) {
            this._recordLastGoodClockLabel(state.snapshot);
            this._stopDrawing(DataState.STALLED);
            return;
        }
        this._publish(state.snapshot);
    }

    /**
     * Reads a D-Bus signal from the service: a Sample of signature '(s)' holding a JSON object is drawn; another signal
     * is ignored, and a malformed Sample is logged and dropped.
     *
     * @param {string} signalName - The D-Bus signal's name.
     * @param {GLib.Variant} parameters - Its parameters.
     * @returns {void}
     */
    _onServiceSignal(signalName, parameters) {
        if (this._isDestroyed || signalName !== SAMPLE_SIGNAL_NAME)
            return;
        const sampleText = stringOfVariant(parameters, SAMPLE_SIGNAL_SIGNATURE);
        if (sampleText === null) {
            this._errorLog.log(`dropped a ${SAMPLE_SIGNAL_NAME} whose parameters are not ${SAMPLE_SIGNAL_SIGNATURE}`,
                WRONG_SAMPLE_SIGNATURE_LOG_KEY);
            return;
        }
        const sample = parseSamplePayload(sampleText);
        if (sample === null) {
            this._errorLog.log(`dropped a ${SAMPLE_SIGNAL_NAME} that is not a JSON object`, UNREADABLE_SAMPLE_LOG_KEY);
            return;
        }
        this._onSample(sample);
    }

    /**
     * Draws a Sample, unless no state is held (then it waits for one, asking if no GetState is on its way: the state
     * includes this Sample) or its sequence restarted (then no data, until a fresh GetState).
     *
     * @param {object} sample - lib/protocol.js parseSamplePayload's result.
     * @returns {void}
     */
    _onSample(sample) {
        if (this._dataState === DataState.AWAITING_STATE) {
            if (!this._isStateRequestInFlight && this._nameOwner !== null)
                this._requestState();
            return;
        }
        if (isSequenceRestart(this._lastAppliedSequence, sample.sequence)) {
            this._stopDrawing(DataState.AWAITING_STATE);
            this._requestState();
            return;
        }
        this._applySample(sample);
    }

    /**
     * Appends what a Sample appended (nothing for a null appendedHistory), makes its snapshot the latest and tells
     * listeners. A stall ends here.
     *
     * @param {object} sample - lib/protocol.js parseSamplePayload's result.
     * @returns {void}
     */
    _applySample(sample) {
        const {appendedHistory} = sample;
        if (appendedHistory !== null) {
            this._cpuHistory.push(appendedHistory.cpu);
            this._memoryHistory.push(appendedHistory.memory);
        }
        this._lastAppliedSequence = sample.sequence;
        this._lastFreshDataAtUsec = this._nowUsec();
        this._dataState = DataState.LIVE;
        this._publish(sample.snapshot);
    }

    /**
     * Stops drawing the service's data: moves to the given state, and publishes no data if the data was live, so it
     * happens once however many reasons follow.
     *
     * @param {string} nextDataState - DataState.AWAITING_STATE or DataState.STALLED.
     * @returns {void}
     */
    _stopDrawing(nextDataState) {
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
     * Makes a snapshot the latest, moves "no data since" on when it has numbers and a time, and tells listeners.
     *
     * @param {Snapshot|null} snapshot - The new latest snapshot.
     * @returns {void}
     */
    _publish(snapshot) {
        this._latestSnapshot = snapshot;
        this._recordLastGoodClockLabel(snapshot);
        this._notifyListeners(snapshot);
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
     * Calls every listener with a snapshot. One that throws is logged, and the rest still run.
     *
     * @param {Snapshot|null} snapshot - The new latest snapshot.
     * @returns {void}
     */
    _notifyListeners(snapshot) {
        for (const [listenerId, listener] of [...this._listeners]) {
            // A listener may destroy the client or remove a later listener.
            if (this._isDestroyed)
                return;
            if (!this._listeners.has(listenerId))
                continue;
            try {
                listener(snapshot);
            } catch (error) {
                this._errorLog.log(`listener failed: ${describeError(error)}`, LISTENER_FAILURE_LOG_KEY);
            }
        }
    }

    /**
     * The staleness check, every SAMPLE_INTERVAL_SECONDS. Runs as a GLib timeout, so it never throws.
     *
     * @returns {boolean} GLib.SOURCE_CONTINUE, always.
     */
    _onStaleCheckTimeout() {
        this._runWithoutThrowing('check for a stale Sample', () => this._stopDrawingIfStale());
        return GLib.SOURCE_CONTINUE;
    }

    /**
     * Shows no data once live data has had no Sample for longer than the stall (lib/wiring.js isSampleStale).
     *
     * @returns {void}
     */
    _stopDrawingIfStale() {
        if (this._dataState === DataState.LIVE && this._isLiveDataStale())
            this._stopDrawing(DataState.STALLED);
    }

    /**
     * Says whether the data last received is older than the stall (lib/wiring.js isSampleStale).
     *
     * @returns {boolean} True when stale.
     */
    _isLiveDataStale() {
        return isSampleStale({lastSampleReceivedAtUsec: this._lastFreshDataAtUsec, nowUsec: this._nowUsec()});
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
     * Sends WatchDetail to the owner, and records that it holds the watch.
     *
     * @returns {void}
     */
    _sendWatchDetail() {
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
     * Calls a method of the service, asynchronously, with DBUS_CALL_TIMEOUT_MS.
     *
     * @param {string} methodName - GetState, WatchDetail or UnwatchDetail.
     * @param {Gio.Cancellable|null} cancellable - The call's cancellable.
     * @param {(error: Error|null, reply: GLib.Variant|null) => void} onAnswered - Called once, with the reply or the
     *     failure.
     * @returns {void}
     */
    _callService(methodName, cancellable, onAnswered) {
        this._proxy.call(methodName, null, CALL_FLAGS, DBUS_CALL_TIMEOUT_MS, cancellable, (proxy, result) => {
            let reply;
            try {
                reply = proxy.call_finish(result);
            } catch (error) {
                onAnswered(error, null);
                return;
            }
            onAnswered(null, reply);
        });
    }

    /**
     * Removes the staleness check and the StartUnit chain's pending step.
     *
     * @returns {void}
     */
    _removeTimeouts() {
        this._cancelStartChainStep();
        if (this._staleCheckSourceId === null)
            return;
        const staleCheckSourceId = this._staleCheckSourceId;
        this._staleCheckSourceId = null;
        this._timeouts.remove(staleCheckSourceId);
    }

    /**
     * Disconnects every handler from the proxy and lets it go.
     *
     * @returns {void}
     */
    _disconnectFromProxy() {
        const proxy = this._proxy;
        const proxyHandlerIds = this._proxyHandlerIds;
        this._proxy = null;
        this._proxyHandlerIds = [];
        for (const handlerId of proxyHandlerIds)
            proxy.disconnect(handlerId);
    }
}
