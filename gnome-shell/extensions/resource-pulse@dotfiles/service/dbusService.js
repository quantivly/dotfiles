// The sampler service's face on the session bus: lib/protocol.js's interface, exported for one ServiceSampler.
// - GetState() answers the latest snapshot, both histories, the service's start time and the current sequence.
// - Every sampler publish becomes one Sample signal, numbered from 1 for this service run.
// - WatchDetail() / UnwatchDetail() are counted per caller (its unique bus name). A caller's watches all drop when its
//   name vanishes, so a shell that crashes or disables the extension cannot leave a watch held. The sampler hears
//   setDetailWatched only when "any watch held" changes.
// It never owns the bus name: service/main.js does, after this object is exported.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {RateLimitedLogger, describeError} from '../lib/errorLog.js';
import {
    RESOURCE_PULSE_INTERFACE_XML, RESOURCE_PULSE_OBJECT_PATH, buildSamplePayload, buildStatePayload,
} from '../lib/protocol.js';
import {runEveryStep} from '../lib/teardown.js';

const SAMPLE_SIGNAL_NAME = 'Sample';
const SAMPLE_SIGNAL_SIGNATURE = '(s)';
/** The standard D-Bus error a watch call answers with when it could not be applied. */
const DBUS_FAILED_ERROR_NAME = 'org.freedesktop.DBus.Error.Failed';
const WATCH_CALL_FAILURE_LOG_KEY = 'watch call failed';
const VANISHED_SENDER_FAILURE_LOG_KEY = 'dropping a vanished caller failed';
const TEARDOWN_FAILURE_LOG_KEY = 'D-Bus teardown step failed';

/** Exports the Resource Pulse interface on one bus connection for one sampler. */
export class ResourcePulseDBusService {
    /**
     * Exports the object at RESOURCE_PULSE_OBJECT_PATH and starts forwarding the sampler's publishes.
     *
     * @param {object} sampler - A ServiceSampler (service/sampler.js), or anything with its latestSnapshot,
     *     cpuHistory, memoryHistory, addListener, removeListener and setDetailWatched.
     * @param {Gio.DBusConnection} connection - A message bus connection: callers are told apart by unique name.
     * @param {object} [options] - Injectable for tests; each has a real default.
     * @param {number} [options.serviceStartedAtUsec] - Real time the service started, in microseconds.
     * @param {() => number} [options.nowRealUsec] - Real time now, in microseconds: each Sample's sampledAtUsec.
     * @param {() => number} [options.nowUsec] - Monotonic microseconds, for the log's rate limit.
     * @param {(line: string) => void} [options.logWriter] - Where rate-limited journal lines go.
     * @throws {GLib.Error} When the object cannot be exported (the path is already taken on this connection).
     */
    constructor(sampler, connection, {
        serviceStartedAtUsec = GLib.get_real_time(),
        nowRealUsec = () => GLib.get_real_time(),
        nowUsec = () => GLib.get_monotonic_time(),
        logWriter = line => console.warn(line),
    } = {}) {
        this._sampler = sampler;
        this._connection = connection;
        this._serviceStartedAtUsec = serviceStartedAtUsec;
        this._nowRealUsec = nowRealUsec;
        this._errorLog = new RateLimitedLogger({nowUsec, write: logWriter});
        this._sequence = 0;
        this._watchCountBySender = new Map();
        this._nameWatcherIdBySender = new Map();
        this._isDetailWatchedForSampler = false;
        this._isDestroyed = false;

        // wrapJSObject calls GetState for its return value, and a method named <Name>Async with the invocation,
        // which is what carries the caller's unique name.
        this._exportedObject = Gio.DBusExportedObject.wrapJSObject(RESOURCE_PULSE_INTERFACE_XML, {
            GetState: () => this._buildStatePayload(),
            WatchDetailAsync: (_parameters, invocation) =>
                this._answerWatchCall(invocation, sender => this._addWatch(sender)),
            UnwatchDetailAsync: (_parameters, invocation) =>
                this._answerWatchCall(invocation, sender => this._removeWatch(sender)),
        });
        this._exportedObject.export(connection, RESOURCE_PULSE_OBJECT_PATH);
        this._samplerListenerId = sampler.addListener(
            (snapshot, appendedHistory) => this._emitSample(snapshot, appendedHistory));
    }

    /** @returns {number} Detail watches held now, across every caller. */
    get detailWatchCount() {
        let watchCount = 0;
        for (const senderWatchCount of this._watchCountBySender.values())
            watchCount += senderWatchCount;
        return watchCount;
    }

    /**
     * Unexports the object, stops forwarding samples and stops following callers' names. Each step runs whatever the
     * others throw. The sampler is left as it is: its owner destroys it.
     *
     * @returns {void}
     */
    destroy() {
        if (this._isDestroyed)
            return;
        this._isDestroyed = true;
        runEveryStep([
            {name: 'stop forwarding samples', run: () => this._sampler.removeListener(this._samplerListenerId)},
            {name: 'unexport the object', run: () => this._exportedObject.unexport()},
            {name: 'stop following callers', run: () => this._unwatchEverySender()},
        ], (stepName, error) => {
            const errorText = describeError(error);
            this._errorLog.log(`D-Bus teardown: ${stepName} failed: ${errorText}`, TEARDOWN_FAILURE_LOG_KEY);
        });
    }

    /**
     * GetState's JSON: the sampler's latest snapshot and both histories, the start time and the current sequence.
     *
     * @returns {string} The JSON (lib/protocol.js's buildStatePayload).
     */
    _buildStatePayload() {
        return buildStatePayload({
            snapshot: this._sampler.latestSnapshot,
            histories: {cpu: this._sampler.cpuHistory.values(), memory: this._sampler.memoryHistory.values()},
            serviceStartedAtUsec: this._serviceStartedAtUsec,
            sequence: this._sequence,
        });
    }

    /**
     * Sends one Sample for one sampler publish. Runs as a sampler listener, which logs a throw (a closed connection)
     * and carries on; the sequence still moves on, so a client sees the gap.
     *
     * @param {object} snapshot - The snapshot published.
     * @param {{cpu: number|null, memory: number|null}|null} appendedHistory - What the publish appended; null for a
     *     watch start's reveal, which appends nothing.
     * @returns {void}
     */
    _emitSample(snapshot, appendedHistory) {
        this._sequence += 1;
        const samplePayload = buildSamplePayload({
            snapshot, appendedHistory, sequence: this._sequence, sampledAtUsec: this._nowRealUsec(),
        });
        const sampleParameters = new GLib.Variant(SAMPLE_SIGNAL_SIGNATURE, [samplePayload]);
        this._exportedObject.emit_signal(SAMPLE_SIGNAL_NAME, sampleParameters);
    }

    /**
     * Applies a watch change for the caller and answers the call: an empty reply, or a D-Bus error when the change
     * threw, so the caller never waits out its timeout.
     *
     * @param {Gio.DBusMethodInvocation} invocation - The call.
     * @param {(sender: string) => void} changeWatch - Adds or removes one of the sender's watches.
     * @returns {void}
     */
    _answerWatchCall(invocation, changeWatch) {
        const sender = invocation.get_sender();
        try {
            if (sender === null)
                throw new Error('the call has no sender (not a message bus connection)');
            changeWatch(sender);
        } catch (error) {
            const methodName = invocation.get_method_name();
            const errorText = describeError(error);
            const failureMessage = `${methodName} from ${sender} failed: ${errorText}`;
            this._errorLog.log(failureMessage, WATCH_CALL_FAILURE_LOG_KEY);
            invocation.return_dbus_error(DBUS_FAILED_ERROR_NAME, failureMessage);
            return;
        }
        invocation.return_value(null);
    }

    /**
     * Counts one more watch for a caller, following its name from its first watch on.
     *
     * @param {string} sender - The caller's unique name.
     * @returns {void}
     */
    _addWatch(sender) {
        const senderWatchCount = this._watchCountBySender.get(sender) ?? 0;
        if (senderWatchCount === 0)
            this._followSender(sender);
        this._watchCountBySender.set(sender, senderWatchCount + 1);
        this._tellSamplerIfWatchedChanged();
    }

    /**
     * Counts one watch fewer for a caller. A caller holding none is left alone: not an error.
     *
     * @param {string} sender - The caller's unique name.
     * @returns {void}
     */
    _removeWatch(sender) {
        const senderWatchCount = this._watchCountBySender.get(sender) ?? 0;
        if (senderWatchCount === 0)
            return;
        if (senderWatchCount === 1)
            this._forgetSender(sender);
        else
            this._watchCountBySender.set(sender, senderWatchCount - 1);
        this._tellSamplerIfWatchedChanged();
    }

    /**
     * Follows a caller's unique name, to drop its watches when it vanishes. A name already gone by the time the
     * watcher asks is reported vanished at once, so a caller that left right after its call is dropped too.
     *
     * @param {string} sender - The caller's unique name.
     * @returns {void}
     */
    _followSender(sender) {
        const nameWatcherId = Gio.bus_watch_name_on_connection(this._connection, sender,
            Gio.BusNameWatcherFlags.NONE, null, () => this._onSenderVanished(sender));
        this._nameWatcherIdBySender.set(sender, nameWatcherId);
    }

    /**
     * Drops every watch of a caller whose name vanished (its connection closed). It runs as a GLib callback, where a
     * throw would only be printed, so a sampler that throws is logged here instead.
     *
     * @param {string} sender - The caller's unique name.
     * @returns {void}
     */
    _onSenderVanished(sender) {
        if (!this._watchCountBySender.has(sender))
            return;
        this._forgetSender(sender);
        try {
            this._tellSamplerIfWatchedChanged();
        } catch (error) {
            const errorText = describeError(error);
            this._errorLog.log(`dropping the watches of ${sender} failed: ${errorText}`,
                VANISHED_SENDER_FAILURE_LOG_KEY);
        }
    }

    /**
     * Forgets a caller's watches and stops following its name.
     *
     * @param {string} sender - The caller's unique name.
     * @returns {void}
     */
    _forgetSender(sender) {
        this._watchCountBySender.delete(sender);
        const nameWatcherId = this._nameWatcherIdBySender.get(sender);
        this._nameWatcherIdBySender.delete(sender);
        if (nameWatcherId !== undefined)
            Gio.bus_unwatch_name(nameWatcherId);
    }

    /**
     * Stops following every caller's name and forgets every watch.
     *
     * @returns {void}
     */
    _unwatchEverySender() {
        const nameWatcherIds = [...this._nameWatcherIdBySender.values()];
        this._nameWatcherIdBySender.clear();
        this._watchCountBySender.clear();
        for (const nameWatcherId of nameWatcherIds)
            Gio.bus_unwatch_name(nameWatcherId);
    }

    /**
     * Tells the sampler whether any watch is held, but only when that changed. It is recorded only once the sampler
     * took it, so a call that threw is made again at the next change of a count.
     *
     * @returns {void}
     */
    _tellSamplerIfWatchedChanged() {
        const isDetailWatched = this._watchCountBySender.size > 0;
        if (isDetailWatched === this._isDetailWatchedForSampler)
            return;
        this._sampler.setDetailWatched(isDetailWatched);
        this._isDetailWatchedForSampler = isDetailWatched;
    }
}
