// The client's link to the Resource Pulse service on the session bus, with no D-Bus proxy object: a name watch
// reports the bus name's owner, a signal subscription on the connection delivers each Sample, and a method is a plain
// connection.call to the owner the watch last reported. A D-Bus proxy object owned only by JavaScript, with handlers
// connected, is referenced by GDBus on every incoming signal, and that makes GJS schedule a forced full garbage
// collection on the compositor thread 10 s later: once per Sample
// (docs/superpowers/specs/2026-11-10-resource-pulse-performance-design.md). The watch and the subscription are GDBus's
// own records and their callbacks plain functions, so no object that only JavaScript holds is touched when a Sample
// arrives.
//
// Calls go to the owner's unique name, as a proxy's do, never to the well-known name: a call meant for an owner that
// has just left must not reach the next one. Otherwise a WatchDetail sent to the old owner could land on the new one,
// which the client then asserts its watch to again: two watches, and one UnwatchDetail later leaves one held.
//
// Gio and GLib only (no Shell, St, Clutter or Meta), so it runs under plain gjs. Every call is asynchronous, with
// DBUS_CALL_TIMEOUT_MS, and never asks the bus to start the service: systemd does that (pulseClient.js's StartUnit).
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {DBUS_CALL_TIMEOUT_MS} from './lib/constants.js';
import {
    RESOURCE_PULSE_BUS_NAME, RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_OBJECT_PATH, SAMPLE_SIGNAL_NAME,
} from './lib/protocol.js';

/** The watch never asks the bus to start the service either. */
const NAME_WATCHER_FLAGS = Gio.BusNameWatcherFlags.NONE;
/** No call asks the bus to activate a name. */
const CALL_FLAGS = Gio.DBusCallFlags.NO_AUTO_START;
/** What a call made while nobody owns the service's name answers, without sending anything. */
const NO_OWNER_ERROR_MESSAGE = `nobody owns ${RESOURCE_PULSE_BUS_NAME}`;
/** Every Sample, whatever its first argument. */
const ANY_FIRST_ARGUMENT = null;
/** None of the service's methods takes parameters. */
const NO_PARAMETERS = null;
/** The reply's type is not checked here: the caller reads its signature, and logs one it does not expect. */
const ANY_REPLY_TYPE = null;

/**
 * The service on the bus, as the client follows it: the owner of its name, its Samples while subscribed, and its
 * methods, called on that owner. Made by createResourcePulseLink; destroy() ends the watch and the subscription.
 */
class ResourcePulseLink {
    /**
     * Subscribes to Samples, then watches the name. GDBus delivers a well-known name's signals only from the owner it
     * knows of, and asks for that owner when the subscription is made; subscribing first means it asks before the
     * watch does, so it knows the owner by the time the watch reports it.
     *
     * @param {Gio.DBusConnection} connection - The session bus connection, shared with the rest of the shell.
     * @param {{onOwnerChanged: (nameOwner: string|null) => void, onSample: (parameters: GLib.Variant) => void}}
     *     callbacks - See createResourcePulseLink.
     */
    constructor(connection, {onOwnerChanged, onSample}) {
        this._connection = connection;
        this._onOwnerChanged = onOwnerChanged;
        this._onSample = onSample;
        this._isDestroyed = false;
        // The unique name owning the service's bus name, as the watch last reported it; null while nobody does, and
        // once destroyed.
        this._nameOwner = null;
        // The subscription's id while subscribed, else null.
        this._sampleSubscriptionId = null;
        this._subscribeToSamples();
        this._nameWatcherId = Gio.bus_watch_name_on_connection(connection, RESOURCE_PULSE_BUS_NAME, NAME_WATCHER_FLAGS,
            (_connection, _busName, nameOwner) => this._reportNameOwner(nameOwner),
            () => this._reportNameOwner(null));
    }

    /** @returns {boolean} True while Samples are delivered: from creation until unsubscribed or destroyed. */
    get isSampleSubscribed() {
        return this._sampleSubscriptionId !== null;
    }

    /**
     * Subscribes to Samples or drops the subscription; asking for what already holds, or anything once destroyed,
     * does nothing.
     *
     * @param {boolean} isSubscribed - True to have Samples delivered.
     * @returns {void}
     */
    setSampleSubscribed(isSubscribed) {
        if (this._isDestroyed || isSubscribed === this.isSampleSubscribed)
            return;
        if (isSubscribed)
            this._subscribeToSamples();
        else
            this._unsubscribeFromSamples();
    }

    /**
     * Calls a method of the service on the unique name of the owner the watch last reported, asynchronously, with
     * DBUS_CALL_TIMEOUT_MS. With no owner (none reported yet, the last one gone, or the link destroyed) nothing is
     * sent, and onAnswered gets a NAME_HAS_NO_OWNER error at once, before call() returns.
     *
     * @param {string} methodName - GetState, WatchDetail or UnwatchDetail.
     * @param {Gio.Cancellable|null} cancellable - The call's cancellable.
     * @param {(error: Error|null, reply: GLib.Variant|null) => void} onAnswered - Called once, with the reply or the
     *     failure.
     * @returns {void}
     */
    call(methodName, cancellable, onAnswered) {
        if (this._nameOwner === null) {
            onAnswered(new GLib.Error(Gio.DBusError, Gio.DBusError.NAME_HAS_NO_OWNER, NO_OWNER_ERROR_MESSAGE), null);
            return;
        }
        this._connection.call(this._nameOwner, RESOURCE_PULSE_OBJECT_PATH, RESOURCE_PULSE_INTERFACE_NAME,
            methodName, NO_PARAMETERS, ANY_REPLY_TYPE, CALL_FLAGS, DBUS_CALL_TIMEOUT_MS, cancellable,
            (callingConnection, result) => {
                let reply;
                try {
                    reply = callingConnection.call_finish(result);
                } catch (error) {
                    onAnswered(error, null);
                    return;
                }
                onAnswered(null, reply);
            });
    }

    /**
     * Ends the name watch and the subscription, and forgets the owner; neither callback is called after it, and a
     * call answers an error at once. The subscription is dropped even if ending the watch throws, and the error then
     * propagates. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        if (this._isDestroyed)
            return;
        this._isDestroyed = true;
        this._nameOwner = null;
        try {
            Gio.bus_unwatch_name(this._nameWatcherId);
        } finally {
            this._unsubscribeFromSamples();
        }
    }

    /**
     * Takes the owner the watch reports, and hands it to the client; nothing once destroyed.
     *
     * @param {string|null} nameOwner - The owner's unique name, or null when nobody owns the name.
     * @returns {void}
     */
    _reportNameOwner(nameOwner) {
        if (this._isDestroyed)
            return;
        this._nameOwner = nameOwner;
        this._onOwnerChanged(nameOwner);
    }

    /**
     * Hands a Sample's parameters to the client; nothing once destroyed.
     *
     * @param {GLib.Variant} parameters - The signal's parameters.
     * @returns {void}
     */
    _deliverSample(parameters) {
        if (!this._isDestroyed)
            this._onSample(parameters);
    }

    /**
     * Subscribes, on the connection, to the Sample signal from the owner of the service's name at its object. The
     * sender is the well-known name: GDBus and the bus then deliver only what its current owner sends.
     *
     * @returns {void}
     */
    _subscribeToSamples() {
        this._sampleSubscriptionId = this._connection.signal_subscribe(RESOURCE_PULSE_BUS_NAME,
            RESOURCE_PULSE_INTERFACE_NAME, SAMPLE_SIGNAL_NAME, RESOURCE_PULSE_OBJECT_PATH, ANY_FIRST_ARGUMENT,
            Gio.DBusSignalFlags.NONE,
            (_connection, _senderName, _objectPath, _interfaceName, _signalName, parameters) =>
                this._deliverSample(parameters));
    }

    /**
     * Drops the subscription, if there is one.
     *
     * @returns {void}
     */
    _unsubscribeFromSamples() {
        if (this._sampleSubscriptionId === null)
            return;
        const sampleSubscriptionId = this._sampleSubscriptionId;
        this._sampleSubscriptionId = null;
        this._connection.signal_unsubscribe(sampleSubscriptionId);
    }
}

/**
 * Starts following the service on a connection: subscribed to Samples from the start, and watching its name.
 *
 * @param {Gio.DBusConnection} connection - The session bus connection.
 * @param {object} callbacks - Where the link delivers.
 * @param {(nameOwner: string|null) => void} callbacks.onOwnerChanged - The unique name owning the service's bus name
 *     when it appears, null when it vanishes. The watch reports once soon after creation, null when nobody owns the
 *     name (from Gio.bus_watch_name_on_connection).
 * @param {(parameters: GLib.Variant) => void} callbacks.onSample - Each Sample's parameters, while subscribed.
 * @returns {ResourcePulseLink} The link.
 */
export function createResourcePulseLink(connection, {onOwnerChanged, onSample}) {
    return new ResourcePulseLink(connection, {onOwnerChanged, onSample});
}
