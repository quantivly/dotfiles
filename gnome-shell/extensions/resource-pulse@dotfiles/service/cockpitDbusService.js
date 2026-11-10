// The cockpit service's face on the session bus: lib/cockpitProtocol.js's interface, exported for one cockpit
// (service/cockpit.js's CockpitServiceProcess).
// - GetState() answers the layout, the config error and every source's latest object as they are at the call.
// - Every cockpit listener call becomes one Changed signal: the sources it names, and the layout with its config
//   error when it names the pseudo-source COCKPIT_LAYOUT_CHANGE_NAME.
// - WatchCockpit() / UnwatchCockpit() are counted per caller (its unique bus name). A caller's watches all drop when
//   its name vanishes, so a shell that crashes or disables the extension cannot leave a watch held. The cockpit hears
//   setWatched only when "any watch held" changes.
// - FocusSession(id) hands the id to the cockpit and answers its reply JSON; a failure there is logged and answered
//   as a reply with focused false and the code internal, never as a D-Bus error or its text.
// It never owns the bus name: service/cockpit.js does, after this object is exported. The watch counting mirrors
// service/dbusService.js's on purpose; the two are kept apart rather than generalised.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {COCKPIT_LOG_PREFIX} from '../lib/constants.js';
import {RateLimitedLogger, describeError} from '../lib/errorLog.js';
import {
    COCKPIT_CHANGED_SIGNAL_NAME, COCKPIT_CHANGED_SIGNAL_SIGNATURE, COCKPIT_FOCUS_ERROR,
    COCKPIT_FOCUS_SESSION_METHOD_NAME, COCKPIT_GET_STATE_METHOD_NAME, COCKPIT_INTERFACE_XML, COCKPIT_OBJECT_PATH,
    COCKPIT_UNWATCH_METHOD_NAME, COCKPIT_WATCH_METHOD_NAME, buildChangedPayload, buildCockpitStatePayload,
    buildFocusSessionReply,
} from '../lib/cockpitProtocol.js';
import {runEveryStep} from '../lib/teardown.js';

/**
 * The name a cockpit puts among a listener call's changed source names when the layout config changed: the Changed
 * it becomes then carries `layout` and `configError` beside the sources.
 */
export const COCKPIT_LAYOUT_CHANGE_NAME = 'layout';
/** wrapJSObject calls <Method><suffix>(parameters, invocation) for a method it finds no plain handler for. */
const INVOCATION_HANDLER_SUFFIX = 'Async';
/** The standard D-Bus error a watch call answers with when it could not be applied. */
const DBUS_FAILED_ERROR_NAME = 'org.freedesktop.DBus.Error.Failed';
/** FocusSession's reply as a GLib.Variant type: one string, the reply JSON. */
const FOCUS_SESSION_REPLY_SIGNATURE = '(s)';
const WATCH_CALL_FAILURE_LOG_KEY = 'watch call failed';
const VANISHED_SENDER_FAILURE_LOG_KEY = 'dropping a vanished caller failed';
const FOCUS_SESSION_FAILURE_LOG_KEY = 'FocusSession failed';
const FOCUS_SESSION_ANSWER_FAILURE_LOG_KEY = 'FocusSession answer failed';
const TEARDOWN_FAILURE_LOG_KEY = 'D-Bus teardown step failed';

/**
 * Exports the Cockpit1 interface on one bus connection for one cockpit.
 *
 * Staleness contract (ruling R14): Changed is sent only when the cockpit reports a change, once per listener call;
 * never on a timer, and never for a source whose object did not change. GetState is built from the cockpit's live
 * objects at each call, never from a cached Changed, so it carries every source's latest `sampledAtUsec`, refreshed
 * by every sample, changed or not. A client that has heard nothing for a while asks GetState to tell a stale source
 * from a stable one.
 */
export class CockpitDBusService {
    /**
     * Exports the object at COCKPIT_OBJECT_PATH and starts forwarding the cockpit's changes.
     *
     * @param {object} cockpit - A CockpitServiceProcess (service/cockpit.js), or anything with its layout,
     *     configError, sourcesByName, addListener, removeListener, setWatched and focusSession.
     * @param {Gio.DBusConnection} connection - A message bus connection: callers are told apart by unique name.
     * @param {object} [options] - Injectable for tests; each has a real default.
     * @param {number} [options.serviceStartedAtUsec] - Real time the service started, in microseconds; also
     *     GetState's latestPublishedAtUsec until the first Changed.
     * @param {() => number} [options.nowRealUsec] - Real time now, in microseconds: each Changed's publishedAtUsec.
     * @param {() => number} [options.nowUsec] - Monotonic microseconds, for the log's rate limit.
     * @param {(line: string) => void} [options.logWriter] - Where rate-limited journal lines go.
     * @throws {GLib.Error} When the object cannot be exported (the path is already taken on this connection).
     */
    constructor(cockpit, connection, {
        serviceStartedAtUsec = GLib.get_real_time(),
        nowRealUsec = () => GLib.get_real_time(),
        nowUsec = () => GLib.get_monotonic_time(),
        logWriter = line => console.warn(line),
    } = {}) {
        this._cockpit = cockpit;
        this._connection = connection;
        this._serviceStartedAtUsec = serviceStartedAtUsec;
        this._nowRealUsec = nowRealUsec;
        this._errorLog = new RateLimitedLogger({nowUsec, write: logWriter, prefix: COCKPIT_LOG_PREFIX});
        /** Real time of the latest Changed, in microseconds; the service's start until the first. */
        this._latestPublishedAtUsec = serviceStartedAtUsec;
        this._watchCountBySender = new Map();
        this._nameWatcherIdBySender = new Map();
        this._isWatchedForCockpit = false;
        this._isDestroyed = false;

        // wrapJSObject calls GetState for its return value, and a method named <Name>Async with the unpacked
        // arguments and the invocation, which carries the caller's unique name and lets FocusSession answer later.
        this._exportedObject = Gio.DBusExportedObject.wrapJSObject(COCKPIT_INTERFACE_XML, {
            [COCKPIT_GET_STATE_METHOD_NAME]: () => this._buildStatePayload(),
            [`${COCKPIT_WATCH_METHOD_NAME}${INVOCATION_HANDLER_SUFFIX}`]: (_parameters, invocation) =>
                this._answerWatchCall(invocation, sender => this._addWatch(sender)),
            [`${COCKPIT_UNWATCH_METHOD_NAME}${INVOCATION_HANDLER_SUFFIX}`]: (_parameters, invocation) =>
                this._answerWatchCall(invocation, sender => this._removeWatch(sender)),
            [`${COCKPIT_FOCUS_SESSION_METHOD_NAME}${INVOCATION_HANDLER_SUFFIX}`]: ([sessionId], invocation) =>
                this._answerFocusSession(sessionId, invocation),
        });
        this._exportedObject.export(connection, COCKPIT_OBJECT_PATH);
        this._cockpitListenerId = cockpit.addListener(
            (changedSourceNames, sourcesByName) => this._emitChanged(changedSourceNames, sourcesByName));
    }

    /** @returns {number} Cockpit watches held now, across every caller. */
    get watchCount() {
        let watchCount = 0;
        for (const senderWatchCount of this._watchCountBySender.values())
            watchCount += senderWatchCount;
        return watchCount;
    }

    /**
     * Unexports the object, stops forwarding changes and stops following callers' names. Each step runs whatever the
     * others throw. The cockpit is left as it is: its owner shuts it down.
     *
     * @returns {void}
     */
    destroy() {
        if (this._isDestroyed)
            return;
        this._isDestroyed = true;
        runEveryStep([
            {name: 'stop forwarding changes', run: () => this._cockpit.removeListener(this._cockpitListenerId)},
            {name: 'unexport the object', run: () => this._exportedObject.unexport()},
            {name: 'stop following callers', run: () => this._unwatchEverySender()},
        ], (stepName, error) => {
            const errorText = describeError(error);
            this._errorLog.log(`D-Bus teardown: ${stepName} failed: ${errorText}`, TEARDOWN_FAILURE_LOG_KEY);
        });
    }

    /**
     * GetState's JSON, from the cockpit's live objects at this call (see the class's staleness contract).
     *
     * @returns {string} The JSON (lib/cockpitProtocol.js's buildCockpitStatePayload).
     */
    _buildStatePayload() {
        return buildCockpitStatePayload({
            layout: this._cockpit.layout,
            configError: this._cockpit.configError,
            sources: this._cockpit.sourcesByName,
            serviceStartedAtUsec: this._serviceStartedAtUsec,
            latestPublishedAtUsec: this._latestPublishedAtUsec,
        });
    }

    /**
     * Sends one Changed for one cockpit listener call, and records its real time for GetState. Runs as a cockpit
     * listener, which logs a throw (a closed connection) and carries on.
     *
     * @param {string[]} changedSourceNames - The sources that changed; COCKPIT_LAYOUT_CHANGE_NAME among them when the
     *     layout config did.
     * @param {object} sourcesByName - Every source's latest object by name.
     * @returns {void}
     */
    _emitChanged(changedSourceNames, sourcesByName) {
        const publishedAtUsec = this._nowRealUsec();
        this._latestPublishedAtUsec = publishedAtUsec;
        // COCKPIT_LAYOUT_CHANGE_NAME lands among the sources here too: buildChangedPayload writes only the names
        // COCKPIT_SOURCE_NAMES lists, so it never reaches the JSON as a source.
        const changedSourceEntries = changedSourceNames
            .map(changedName => [changedName, sourcesByName[changedName] ?? null]);
        const change = {publishedAtUsec, sources: Object.fromEntries(changedSourceEntries)};
        if (changedSourceNames.includes(COCKPIT_LAYOUT_CHANGE_NAME)) {
            change.layout = this._cockpit.layout;
            change.configError = this._cockpit.configError;
        }
        const changedParameters = new GLib.Variant(COCKPIT_CHANGED_SIGNAL_SIGNATURE, [buildChangedPayload(change)]);
        this._exportedObject.emit_signal(COCKPIT_CHANGED_SIGNAL_NAME, changedParameters);
    }

    /**
     * Answers a FocusSession call once the cockpit has: with its reply, or with focused false and the code internal
     * when it rejected or threw. The call is always answered, so the caller never waits out its timeout.
     *
     * @param {string} sessionId - The session row's id, as the caller sent it.
     * @param {Gio.DBusMethodInvocation} invocation - The call.
     * @returns {void}
     */
    _answerFocusSession(sessionId, invocation) {
        this._focusSessionReplyText(sessionId)
            .then(replyText => {
                invocation.return_value(new GLib.Variant(FOCUS_SESSION_REPLY_SIGNATURE, [replyText]));
            })
            .catch(error => {
                const errorText = describeError(error);
                this._errorLog.log(`FocusSession: cannot answer: ${errorText}`, FOCUS_SESSION_ANSWER_FAILURE_LOG_KEY);
            });
    }

    /**
     * @param {string} sessionId - The session row's id.
     * @returns {Promise<string>} The reply JSON (buildFocusSessionReply): the cockpit's reply, or focused false,
     *     windowPid null and the code internal when the cockpit rejected, threw or answered something that is not a
     *     reply. The error's message goes to the journal, never to the bus.
     */
    async _focusSessionReplyText(sessionId) {
        try {
            const reply = await this._cockpit.focusSession(sessionId);
            return buildFocusSessionReply(reply);
        } catch (error) {
            const errorText = describeError(error);
            this._errorLog.log(`FocusSession failed: ${errorText}`, FOCUS_SESSION_FAILURE_LOG_KEY);
            return buildFocusSessionReply({focused: false, windowPid: null, error: COCKPIT_FOCUS_ERROR.INTERNAL});
        }
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
        this._tellCockpitIfWatchedChanged();
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
        this._tellCockpitIfWatchedChanged();
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
     * throw would only be printed, so a cockpit that throws is logged here instead.
     *
     * @param {string} sender - The caller's unique name.
     * @returns {void}
     */
    _onSenderVanished(sender) {
        if (!this._watchCountBySender.has(sender))
            return;
        this._forgetSender(sender);
        try {
            this._tellCockpitIfWatchedChanged();
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
     * Tells the cockpit whether any watch is held, but only when that changed. It is recorded only once the cockpit
     * took it, so a call that threw is made again at the next change of a count.
     *
     * @returns {void}
     */
    _tellCockpitIfWatchedChanged() {
        const isWatched = this._watchCountBySender.size > 0;
        if (isWatched === this._isWatchedForCockpit)
            return;
        this._cockpit.setWatched(isWatched);
        this._isWatchedForCockpit = isWatched;
    }
}
