// The cockpit service's scheduler: runs each source (service/sources/) on its own cadence, isolates their failures,
// keeps each one's latest object, and tells listeners which sources changed. The timeouts, the clock, the battery
// check and the log writer are injectable, so its rows drive time by hand under plain gjs.
//
// - Cadence: sessions every SESSIONS_WATCHED_INTERVAL_SECONDS while a client watches the cockpit and every
//   SESSIONS_UNWATCHED_INTERVAL_SECONDS otherwise; network every NETWORK_INTERVAL_SECONDS and mounts every
//   MOUNTS_INTERVAL_SECONDS either way; each multiplied by BATTERY_CADENCE_MULTIPLIER while on battery. The battery
//   check runs at each firing, so a change of power takes effect at the source's next firing. Becoming watched
//   samples sessions at once, as its own signal would (so at most once per cooldown).
// - A source's own signal (watchChanges) samples it at once, at most once per SOURCE_SIGNAL_COOLDOWN_SECONDS; signals
//   inside the cooldown give one sample when it ends, so the last change is never lost to it. A signal while the
//   source's sample is pending arms the same timer; if that sample is still pending when the timer fires, one
//   trailing sample starts as soon as it settles, so a change mid-sample waits neither a full interval nor in line.
//   The cooldown runs on the monotonic clock, so a wall clock set back or forward does not stretch it.
// - A source whose watchChanges throws is logged and still sampled on its interval; the others are untouched.
// - A sample still pending when its source's turn comes again is skipped, never queued.
// - A sample that rejects keeps the source's previous object and logs `cockpit: <source>: <error>`, rate-limited per
//   source; the other sources are untouched.
// - The scheduler stamps `sampledAtUsec` (wall clock, when the sample started) and `intervalSeconds` (the effective
//   interval) on every object a source resolves with, over whatever the source wrote (ruling R2).
import GLib from 'gi://GLib';

import {
    BATTERY_CADENCE_MULTIPLIER, COCKPIT_LOG_PREFIX, MICROSECONDS_PER_SECOND, MOUNTS_INTERVAL_SECONDS,
    NETWORK_INTERVAL_SECONDS, SESSIONS_UNWATCHED_INTERVAL_SECONDS, SESSIONS_WATCHED_INTERVAL_SECONDS, SOURCE_SIGNAL_COOLDOWN_SECONDS,
} from '../lib/constants.js';
import {RateLimitedLogger, describeError, describeErrorWithStack} from '../lib/errorLog.js';
import {isPlainObject} from '../lib/jsonFields.js';
import {systemBusProxyOrNull} from './sources/sourceIo.js';

/** GLib's timeouts at the default priority: each source's interval and its signal cooldown. */
const GLIB_TIMEOUTS = Object.freeze({
    addSeconds: (intervalSeconds, callback) =>
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, intervalSeconds, callback),
    remove: sourceId => GLib.source_remove(sourceId),
});
/** Each source's interval, in seconds, before the battery multiplier: while watched and while not. */
const BASE_INTERVAL_SECONDS_BY_SOURCE_NAME = {
    sessions: {watched: SESSIONS_WATCHED_INTERVAL_SECONDS, unwatched: SESSIONS_UNWATCHED_INTERVAL_SECONDS},
    network: {watched: NETWORK_INTERVAL_SECONDS, unwatched: NETWORK_INTERVAL_SECONDS},
    mounts: {watched: MOUNTS_INTERVAL_SECONDS, unwatched: MOUNTS_INTERVAL_SECONDS},
};
const UPOWER_BUS_NAME = 'org.freedesktop.UPower';
const UPOWER_OBJECT_PATH = '/org/freedesktop/UPower';
const UPOWER_INTERFACE_NAME = 'org.freedesktop.UPower';
const ON_BATTERY_PROPERTY = 'OnBattery';
const SIGNAL_COOLDOWN_USEC = SOURCE_SIGNAL_COOLDOWN_SECONDS * MICROSECONDS_PER_SECOND;
/** The shortest wait GLib's whole-second timeouts can give: a cooldown's remainder is rounded up to it. */
const MIN_TIMEOUT_SECONDS = 1;
/** Template keys of the scheduler's own log lines, so each logs once per ERROR_LOG_REPEAT_INTERVAL_USEC. */
const LISTENER_LOG_KEY = 'listener';
const ON_BATTERY_LOG_KEY = 'on-battery';
const SOURCE_DESTROY_LOG_KEY = 'source destroy';
const WATCH_CHANGES_LOG_KEY = 'watchChanges failed';

/**
 * The real battery check: UPower's OnBattery, read from a proxy's property cache (UPower signals its changes), never
 * a call.
 *
 * @param {object|null} [upowerProxy] - A Gio.DBusProxy on UPower's manager object; null when there is none.
 * @returns {() => boolean} True while UPower says the machine runs on battery; false when UPower is absent.
 */
export function createOnBatteryReader(upowerProxy = systemBusProxyOrNull({
    busName: UPOWER_BUS_NAME, objectPath: UPOWER_OBJECT_PATH, interfaceName: UPOWER_INTERFACE_NAME,
})) {
    return () => upowerProxy?.get_cached_property(ON_BATTERY_PROPERTY)?.unpack() === true;
}

/**
 * Runs the cockpit's sources on their cadences and keeps their latest objects.
 *
 * A source object counts as changed when its JSON text, `sampledAtUsec` left out, differs from the previous one's:
 * otherwise every sample would be a change. The stored object still carries the new stamp, and `intervalSeconds` is
 * part of the comparison, so a change of cadence is a change.
 */
export class CockpitSources {
    /**
     * @param {object} options - The sources and the IO.
     * @param {Array<{name: string, sample: () => Promise<object>, watchChanges: (onChange: () => void) => void,
     *     destroy: () => void}>} options.sources - The sources, each named one of sessions, network and mounts, at
     *     most once.
     * @param {{addSeconds: (intervalSeconds: number, callback: () => boolean) => number,
     *     remove: (sourceId: number) => void}} [options.timeouts] - Adds and removes timeouts.
     * @param {() => number} [options.nowUsec] - Wall-clock microseconds since the epoch: the stamp a card turns into
     *     "no data since HH:MM".
     * @param {() => number} [options.monotonicNowUsec] - Monotonic microseconds: the signal cooldown's clock and the
     *     log's rate limit, which a wall clock set back would stretch.
     * @param {() => boolean} [options.isOnBattery] - Whether the machine runs on battery (default: UPower's
     *     OnBattery, false when UPower is absent).
     * @param {(line: string) => void} [options.logWriter] - Where rate-limited journal lines go.
     * @throws {Error} For a source whose name the scheduler has no cadence for, or a name given twice.
     */
    constructor({
        sources,
        timeouts = GLIB_TIMEOUTS,
        nowUsec = () => GLib.get_real_time(),
        monotonicNowUsec = () => GLib.get_monotonic_time(),
        isOnBattery = createOnBatteryReader(),
        logWriter = line => console.warn(line),
    }) {
        this._timeouts = timeouts;
        this._nowUsec = nowUsec;
        this._monotonicNowUsec = monotonicNowUsec;
        this._isOnBatteryReader = isOnBattery;
        this._errorLog = new RateLimitedLogger({
            nowUsec: monotonicNowUsec, write: logWriter, prefix: COCKPIT_LOG_PREFIX,
        });
        this._stateByName = new Map();
        for (const source of sources) {
            const hasCadence = Object.hasOwn(BASE_INTERVAL_SECONDS_BY_SOURCE_NAME, source.name);
            if (!hasCadence || this._stateByName.has(source.name)) {
                const problem = hasCadence ? 'is given twice' : 'has no cadence';
                throw new Error(`${COCKPIT_LOG_PREFIX} the source named ${source.name} ${problem}`);
            }
            this._stateByName.set(source.name, {
                source,
                latestObject: null,
                latestComparableJson: null,
                pendingSample: null,
                intervalTimerId: null,
                scheduledIntervalSeconds: null,
                lastSignalSampleUsec: null,
                cooldownTimerId: null,
                isTrailingSampleArmed: false,
            });
        }
        this._listenersById = new Map();
        this._nextListenerId = 1;
        this._isWatched = false;
        this._isStarted = false;
        this._isDestroyed = false;
    }

    /**
     * Subscribes to every source's signal, samples every source once at once, then schedules each on its interval.
     * A source whose subscription throws is logged and still scheduled, and so are the sources after it. Safe twice;
     * does nothing after destroy.
     *
     * @returns {void}
     */
    start() {
        if (this._isStarted || this._isDestroyed)
            return;
        this._isStarted = true;
        for (const sourceState of this._stateByName.values()) {
            this._watchSourceChanges(sourceState);
            this._scheduleInterval(sourceState);
            this._startSample(sourceState);
        }
    }

    /**
     * Subscribes to a source's signal. A watchChanges that throws is logged, rate-limited per source, and leaves the
     * source on its interval alone.
     *
     * @param {object} sourceState - The source's state.
     * @returns {void}
     */
    _watchSourceChanges(sourceState) {
        const sourceName = sourceState.source.name;
        try {
            sourceState.source.watchChanges(() => this._onSourceSignal(sourceState));
        } catch (error) {
            this._errorLog.log(`${sourceName}: watchChanges: ${describeError(error)}`,
                `${WATCH_CHANGES_LOG_KEY}: ${sourceName}`);
        }
    }

    /**
     * Removes every timeout, destroys every source and forgets every listener; a sample that settles afterwards is
     * dropped. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        if (this._isDestroyed)
            return;
        this._isDestroyed = true;
        for (const sourceState of this._stateByName.values()) {
            this._removeTimers(sourceState);
            try {
                sourceState.source.destroy();
            } catch (error) {
                this._errorLog.log(`${sourceState.source.name}: destroy failed: ${describeErrorWithStack(error)}`,
                    SOURCE_DESTROY_LOG_KEY);
            }
        }
        this._listenersById.clear();
    }

    /**
     * Records whether a client watches the cockpit. A source whose interval this changes (sessions) is rescheduled
     * at once with the new interval, counted from now. One whose interval it shortens (becoming watched) is also
     * sampled at once, as its own signal would sample it, so at most once per SOURCE_SIGNAL_COOLDOWN_SECONDS: what
     * a watcher sees then is fresh and stamped with the interval it now runs at, not up to an unwatched interval
     * old. A longer interval (becoming unwatched) takes no extra sample.
     *
     * @param {boolean} isWatched - Whether at least one client watches.
     * @returns {void}
     */
    setWatched(isWatched) {
        const isWatchedNow = Boolean(isWatched);
        if (isWatchedNow === this._isWatched)
            return;
        this._isWatched = isWatchedNow;
        if (!this._isStarted || this._isDestroyed)
            return;
        for (const sourceState of this._stateByName.values()) {
            const previousIntervalSeconds = sourceState.scheduledIntervalSeconds;
            if (this._effectiveIntervalSeconds(sourceState.source.name) === previousIntervalSeconds)
                continue;
            this._timeouts.remove(sourceState.intervalTimerId);
            sourceState.intervalTimerId = null;
            this._scheduleInterval(sourceState);
            if (sourceState.scheduledIntervalSeconds < previousIntervalSeconds)
                this._onSourceSignal(sourceState);
        }
    }

    /**
     * @param {(changedSourceNames: string[], sourcesByName: object) => void} listener - Called after a sample
     *     changed a source's object, with that source's name and every source's latest object.
     * @returns {number} An id for removeListener.
     */
    addListener(listener) {
        const listenerId = this._nextListenerId++;
        this._listenersById.set(listenerId, listener);
        return listenerId;
    }

    /**
     * @param {number} listenerId - An id addListener returned; an unknown one is ignored.
     * @returns {void}
     */
    removeListener(listenerId) {
        this._listenersById.delete(listenerId);
    }

    /**
     * @returns {Object<string, object|null>} Each source's latest object by name, in the order the sources were
     *     given; null for a source with no successful sample yet. A new object on each read.
     */
    get sourcesByName() {
        return Object.fromEntries([...this._stateByName]
            .map(([name, sourceState]) => [name, sourceState.latestObject]));
    }

    /**
     * Samples a source now, unless its previous sample is still pending, in which case that one is handed back.
     *
     * @param {string} name - The source's name.
     * @returns {Promise<object|null>} Settles once the sample settled, with the source's latest object (the earlier
     *     one when the sample failed); rejects for an unknown name, and otherwise only when the log writer throws.
     */
    sampleNow(name) {
        const sourceState = this._stateByName.get(name);
        if (sourceState === undefined)
            return Promise.reject(new Error(`${COCKPIT_LOG_PREFIX} no source named ${name}`));
        if (this._isDestroyed)
            return Promise.resolve(sourceState.latestObject);
        return this._startSample(sourceState);
    }

    /**
     * @param {string} name - A source's name.
     * @returns {number} Its interval now, in seconds: its base for the current watch state, times
     *     BATTERY_CADENCE_MULTIPLIER on battery.
     */
    _effectiveIntervalSeconds(name) {
        const baseIntervals = BASE_INTERVAL_SECONDS_BY_SOURCE_NAME[name];
        const baseIntervalSeconds = this._isWatched ? baseIntervals.watched : baseIntervals.unwatched;
        return this._isOnBattery() ? baseIntervalSeconds * BATTERY_CADENCE_MULTIPLIER : baseIntervalSeconds;
    }

    /**
     * @returns {boolean} What the injected battery check says; false when it throws, which is logged.
     */
    _isOnBattery() {
        try {
            return this._isOnBatteryReader() === true;
        } catch (error) {
            this._errorLog.log(`on-battery check failed: ${describeError(error)}`, ON_BATTERY_LOG_KEY);
            return false;
        }
    }

    /**
     * Starts a source's interval timeout at its effective interval.
     *
     * @param {object} sourceState - The source's state.
     * @returns {void}
     */
    _scheduleInterval(sourceState) {
        const intervalSeconds = this._effectiveIntervalSeconds(sourceState.source.name);
        sourceState.scheduledIntervalSeconds = intervalSeconds;
        sourceState.intervalTimerId = this._timeouts.addSeconds(intervalSeconds,
            () => this._onIntervalTimeout(sourceState));
    }

    /**
     * A source's turn: when its effective interval changed (power, watch state), its timeout is replaced by one at
     * the new interval first; then it samples, stamped with that interval.
     *
     * @param {object} sourceState - The source's state.
     * @returns {boolean} GLib.SOURCE_CONTINUE, or GLib.SOURCE_REMOVE when a new timeout replaced this one.
     */
    _onIntervalTimeout(sourceState) {
        let shouldContinue = GLib.SOURCE_CONTINUE;
        if (this._effectiveIntervalSeconds(sourceState.source.name) !== sourceState.scheduledIntervalSeconds) {
            // This timeout ends by returning SOURCE_REMOVE, so it is forgotten rather than removed.
            sourceState.intervalTimerId = null;
            this._scheduleInterval(sourceState);
            shouldContinue = GLib.SOURCE_REMOVE;
        }
        this._startSample(sourceState);
        return shouldContinue;
    }

    /**
     * A source's signal: samples it at once unless it was signal-sampled within the cooldown or its sample is
     * pending. Otherwise it arms one timer, for the rest of the cooldown and at least MIN_TIMEOUT_SECONDS, unless a
     * sample after this signal is already coming (a timer, or a trailing sample, is armed).
     *
     * @param {object} sourceState - The source's state.
     * @returns {void}
     */
    _onSourceSignal(sourceState) {
        if (this._isDestroyed)
            return;
        if (sourceState.cooldownTimerId !== null || sourceState.isTrailingSampleArmed)
            return;
        const nowUsec = this._monotonicNowUsec();
        const sinceLastSignalSampleUsec = sourceState.lastSignalSampleUsec === null
            ? Infinity : nowUsec - sourceState.lastSignalSampleUsec;
        const isCooldownOver = sinceLastSignalSampleUsec >= SIGNAL_COOLDOWN_USEC;
        if (isCooldownOver && sourceState.pendingSample === null) {
            this._startSignalSample(sourceState);
            return;
        }
        const cooldownRemainingSeconds = Math.max(MIN_TIMEOUT_SECONDS,
            Math.ceil((SIGNAL_COOLDOWN_USEC - sinceLastSignalSampleUsec) / MICROSECONDS_PER_SECOND));
        sourceState.cooldownTimerId = this._timeouts.addSeconds(cooldownRemainingSeconds,
            () => this._onCooldownTimeout(sourceState));
    }

    /**
     * The timer a signal armed: samples the source now, or, while its sample is still pending, arms one trailing
     * sample that starts as soon as that one settles.
     *
     * @param {object} sourceState - The source's state.
     * @returns {boolean} GLib.SOURCE_REMOVE: the timer fires once.
     */
    _onCooldownTimeout(sourceState) {
        sourceState.cooldownTimerId = null;
        if (sourceState.pendingSample === null) {
            this._startSignalSample(sourceState);
            return GLib.SOURCE_REMOVE;
        }
        sourceState.isTrailingSampleArmed = true;
        const startTrailingSample = () => {
            sourceState.isTrailingSampleArmed = false;
            if (!this._isDestroyed)
                this._startSignalSample(sourceState);
        };
        // Either way it settles: the pending promise rejects only when the log writer throws.
        sourceState.pendingSample.then(startTrailingSample, startTrailingSample);
        return GLib.SOURCE_REMOVE;
    }

    /**
     * Starts a sample a signal asked for, and starts the cooldown from now.
     *
     * @param {object} sourceState - The source's state.
     * @returns {void}
     */
    _startSignalSample(sourceState) {
        sourceState.lastSignalSampleUsec = this._monotonicNowUsec();
        this._startSample(sourceState);
    }

    /**
     * Starts a sample of a source, unless one is pending.
     *
     * @param {object} sourceState - The source's state.
     * @returns {Promise<object|null>} The pending sample's promise: it settles with the source's latest object once
     *     the sample was accepted or its failure logged; it rejects only when the log writer itself throws.
     */
    _startSample(sourceState) {
        if (sourceState.pendingSample !== null)
            return sourceState.pendingSample;
        const stamp = {
            sampledAtUsec: this._nowUsec(),
            intervalSeconds: sourceState.scheduledIntervalSeconds ??
                this._effectiveIntervalSeconds(sourceState.source.name),
        };
        let samplePromise;
        try {
            samplePromise = Promise.resolve(sourceState.source.sample());
        } catch (error) {
            // A sample() that throws instead of rejecting fails the same way.
            samplePromise = Promise.reject(error);
        }
        sourceState.pendingSample = samplePromise
            .then(sourceObject => this._acceptSample(sourceState, sourceObject, stamp))
            .catch(error => this._logSampleFailure(sourceState, error))
            // Cleared whatever happened above, so no failure can leave the source pending, and so skipped, for good.
            .finally(() => {
                sourceState.pendingSample = null;
            })
            .then(() => sourceState.latestObject);
        return sourceState.pendingSample;
    }

    /**
     * Stamps and stores a sampled object, and tells the listeners when it changed.
     *
     * @param {object} sourceState - The source's state.
     * @param {*} sourceObject - What sample() resolved with.
     * @param {{sampledAtUsec: number, intervalSeconds: number}} stamp - The sample's timing.
     * @returns {void}
     * @throws {Error} When sample() resolved with something other than an object.
     */
    _acceptSample(sourceState, sourceObject, stamp) {
        if (this._isDestroyed)
            return;
        if (!isPlainObject(sourceObject))
            throw new Error(`sample() resolved ${typeof sourceObject}, not an object`);
        const stampedObject = {...sourceObject, ...stamp};
        const {sampledAtUsec: _sampledAtUsec, ...comparedFields} = stampedObject;
        const comparableJson = JSON.stringify(comparedFields);
        sourceState.latestObject = stampedObject;
        if (comparableJson === sourceState.latestComparableJson)
            return;
        sourceState.latestComparableJson = comparableJson;
        this._notifyListeners([sourceState.source.name]);
    }

    /**
     * @param {object} sourceState - The source whose sample failed.
     * @param {*} error - Why.
     * @returns {void}
     */
    _logSampleFailure(sourceState, error) {
        if (this._isDestroyed)
            return;
        const sourceName = sourceState.source.name;
        this._errorLog.log(`${sourceName}: ${describeError(error)}`, `sample failed: ${sourceName}`);
    }

    /**
     * Calls every listener; one that throws is logged and does not stop the others.
     *
     * @param {string[]} changedSourceNames - The sources whose objects changed.
     * @returns {void}
     */
    _notifyListeners(changedSourceNames) {
        const sourcesByName = this.sourcesByName;
        for (const listener of [...this._listenersById.values()]) {
            try {
                listener(changedSourceNames, sourcesByName);
            } catch (error) {
                this._errorLog.log(`listener failed: ${describeErrorWithStack(error)}`, LISTENER_LOG_KEY);
            }
        }
    }

    /**
     * @param {object} sourceState - The source's state.
     * @returns {void} Its interval and cooldown timeouts removed.
     */
    _removeTimers(sourceState) {
        if (sourceState.intervalTimerId !== null)
            this._timeouts.remove(sourceState.intervalTimerId);
        if (sourceState.cooldownTimerId !== null)
            this._timeouts.remove(sourceState.cooldownTimerId);
        sourceState.intervalTimerId = null;
        sourceState.cooldownTimerId = null;
    }
}
