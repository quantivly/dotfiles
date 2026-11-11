// The shell's link to one of its services on the session bus, with no D-Bus proxy object: a name watch reports the
// bus name's owner, a signal subscription on the connection delivers the service's one signal, and a method is a plain
// connection.call to the owner the watch last reported. A D-Bus proxy object owned only by JavaScript, with handlers
// connected, is referenced by GDBus on every incoming signal, and that makes GJS schedule a forced full garbage
// collection on the compositor thread 10 s later: once per signal
// (docs/superpowers/specs/2026-11-10-resource-pulse-performance-design.md). The watch and the subscription are GDBus's
// own records and their callbacks plain functions, so no object that only JavaScript holds is touched when a signal
// arrives.
//
// Two services are followed this way, each described by a ServiceLinkDescriptor (the names, and whether the link
// subscribes from creation):
// - Resource Pulse (createResourcePulseLink, here; its client is pulseClient.js): subscribed to its Sample signal from
//   creation until destroy(), since a Sample is the card's tick.
// - the cockpit (its maker lives in cockpitClient.js, so this file names no cockpit constant): unsubscribed from its
//   Changed signal at creation, and subscribed only while something of the cockpit can be seen (setSubscribed).
// The name watch is held from creation until destroy() either way: the client needs the owner to end its StartUnit
// chain and to call the service, subscribed or not.
//
// Calls go to the owner's unique name, as a proxy's do, never to the well-known name: a call meant for an owner that
// has just left must not reach the next one. Otherwise a watch call sent to the old owner could land on the new one,
// which the client then asserts its watch to again: two watches, and one unwatch later leaves one held.
//
// Gio and GLib only (no Shell, St, Clutter or Meta), so it runs under plain gjs. Every call is asynchronous, with
// DBUS_CALL_TIMEOUT_MS, and never asks the bus to start the service: systemd does that (each client's StartUnit).
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
/** Every signal of the subscribed name, whatever its first argument. */
const ANY_FIRST_ARGUMENT = null;
/** The reply's type is not checked here: the caller reads its signature, and logs one it does not expect. */
const ANY_REPLY_TYPE = null;

/**
 * @typedef {object} ServiceLinkDescriptor
 * @property {string} busName - The service's well-known bus name: the name watched, and the sender of the signal the
 *     link delivers (GDBus and the bus then deliver only what its current owner sends).
 * @property {string} objectPath - The service's object: where the signal comes from and the methods are called.
 * @property {string} interfaceName - The interface of the signal and of the methods.
 * @property {string} signalName - The one signal the link delivers.
 * @property {boolean} isSubscribedFromCreation - True to subscribe to the signal before the name watch starts, and
 *     hold the subscription until setSubscribed(false) or destroy(); false to start with none.
 */

/** Resource Pulse as its link follows it: every Sample, from creation until destroy(). */
const RESOURCE_PULSE_LINK_DESCRIPTOR = Object.freeze({
    busName: RESOURCE_PULSE_BUS_NAME,
    objectPath: RESOURCE_PULSE_OBJECT_PATH,
    interfaceName: RESOURCE_PULSE_INTERFACE_NAME,
    signalName: SAMPLE_SIGNAL_NAME,
    isSubscribedFromCreation: true,
});

/**
 * A service on the bus, as a client follows it: the owner of its name from creation until destroy(), its signal while
 * subscribed, and its methods, called on that owner. Made by createServiceLink; destroy() ends the watch and the
 * subscription.
 */
class ServiceLink {
    /**
     * Subscribes to the signal first when the descriptor says so, then watches the name. GDBus delivers a well-known
     * name's signals only from the owner it knows of, and asks for that owner when the subscription is made;
     * subscribing first means it asks before the watch does, so it knows the owner by the time the watch reports it.
     *
     * @param {Gio.DBusConnection} connection - The session bus connection, shared with the rest of the shell.
     * @param {ServiceLinkDescriptor} descriptor - The service's names, and whether to subscribe from creation.
     * @param {{onOwnerChanged: (nameOwner: string|null) => void, onSignal: (parameters: GLib.Variant) => void}}
     *     callbacks - See createServiceLink.
     */
    constructor(connection, descriptor, {onOwnerChanged, onSignal}) {
        this._connection = connection;
        this._descriptor = descriptor;
        this._onOwnerChanged = onOwnerChanged;
        this._onSignal = onSignal;
        this._isDestroyed = false;
        // The unique name owning the service's bus name, as the watch last reported it; null while nobody does, and
        // once destroyed.
        this._nameOwner = null;
        // The signal subscription's id while one is held, else null.
        this._signalSubscriptionId = null;
        if (descriptor.isSubscribedFromCreation)
            this._subscribeToSignal();
        this._nameWatcherId = Gio.bus_watch_name_on_connection(connection, descriptor.busName, NAME_WATCHER_FLAGS,
            (_connection, _busName, nameOwner) => this._reportNameOwner(nameOwner),
            () => this._reportNameOwner(null));
    }

    /** @returns {boolean} True while the signal is subscribed to, so delivered. */
    get isSubscribed() {
        return this._signalSubscriptionId !== null;
    }

    /**
     * Subscribes to the signal, or drops the subscription. Setting the state it already has does nothing, and so does
     * any call after destroy(). The name watch goes on either way.
     *
     * GDBus asks the bus for the well-known name's owner when the subscription is made, and delivers that name's
     * signals only once it knows the owner. So a client that subscribes late (while an owner is already there) must
     * subscribe first and call the service's state method second: the bus answers GDBus's owner query before it
     * passes that call on, so GDBus knows the owner before the state's answer arrives, and every signal the service
     * sends after answering is delivered. Asking for the state first could miss a signal sent between that answer and
     * the subscription.
     *
     * @param {boolean} isSubscribed - True to deliver the signal from now on, false to stop.
     * @returns {void}
     */
    setSubscribed(isSubscribed) {
        if (this._isDestroyed || isSubscribed === this.isSubscribed)
            return;
        if (isSubscribed)
            this._subscribeToSignal();
        else
            this._unsubscribeFromSignal();
    }

    /**
     * Calls a method of the service on the unique name of the owner the watch last reported, asynchronously, with
     * DBUS_CALL_TIMEOUT_MS. With no owner (none reported yet, the last one gone, or the link destroyed) nothing is
     * sent, and onAnswered gets a NAME_HAS_NO_OWNER error at once, before call() returns.
     *
     * @param {string} methodName - The method, on the descriptor's interface.
     * @param {GLib.Variant|null} parameters - Its arguments as a tuple, or null for a method that takes none.
     * @param {Gio.Cancellable|null} cancellable - The call's cancellable.
     * @param {(error: Error|null, reply: GLib.Variant|null) => void} onAnswered - Called once, with the reply or the
     *     failure.
     * @returns {void}
     */
    call(methodName, parameters, cancellable, onAnswered) {
        if (this._nameOwner === null) {
            const noOwnerErrorMessage = `nobody owns ${this._descriptor.busName}`;
            onAnswered(new GLib.Error(Gio.DBusError, Gio.DBusError.NAME_HAS_NO_OWNER, noOwnerErrorMessage), null);
            return;
        }
        this._connection.call(this._nameOwner, this._descriptor.objectPath, this._descriptor.interfaceName,
            methodName, parameters, ANY_REPLY_TYPE, CALL_FLAGS, DBUS_CALL_TIMEOUT_MS, cancellable,
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
     * Ends the name watch and a held subscription, and forgets the owner; neither callback is called after it, and a
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
            this._unsubscribeFromSignal();
        }
    }

    /**
     * Subscribes to the descriptor's signal from its well-known name, at its object. Each subscription's callback
     * carries its own id, so a signal GDBus had queued for a subscription since dropped is never delivered.
     *
     * @returns {void}
     */
    _subscribeToSignal() {
        const {busName, interfaceName, signalName, objectPath} = this._descriptor;
        const signalSubscriptionId = this._connection.signal_subscribe(busName, interfaceName, signalName, objectPath,
            ANY_FIRST_ARGUMENT, Gio.DBusSignalFlags.NONE,
            (_connection, _senderName, _objectPath, _interfaceName, _signalName, parameters) =>
                this._deliverSignal(signalSubscriptionId, parameters));
        this._signalSubscriptionId = signalSubscriptionId;
    }

    /**
     * Drops the subscription, if one is held.
     *
     * @returns {void}
     */
    _unsubscribeFromSignal() {
        const signalSubscriptionId = this._signalSubscriptionId;
        if (signalSubscriptionId === null)
            return;
        this._signalSubscriptionId = null;
        this._connection.signal_unsubscribe(signalSubscriptionId);
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
     * Hands a signal's parameters to the client, if it came through the subscription held now; nothing once
     * destroyed.
     *
     * @param {number} signalSubscriptionId - The subscription it came through.
     * @param {GLib.Variant} parameters - The signal's parameters.
     * @returns {void}
     */
    _deliverSignal(signalSubscriptionId, parameters) {
        if (!this._isDestroyed && signalSubscriptionId === this._signalSubscriptionId)
            this._onSignal(parameters);
    }
}

/**
 * Starts following a service on a connection: watching its name from now until destroy(), and subscribed to its
 * signal from now on when the descriptor says so.
 *
 * @param {Gio.DBusConnection} connection - The session bus connection.
 * @param {ServiceLinkDescriptor} descriptor - The service's names, and whether to subscribe from creation.
 * @param {object} callbacks - Where the link delivers.
 * @param {(nameOwner: string|null) => void} callbacks.onOwnerChanged - The unique name owning the service's bus name
 *     when it appears, null when it vanishes. The watch reports once soon after creation, null when nobody owns the
 *     name (from Gio.bus_watch_name_on_connection).
 * @param {(parameters: GLib.Variant) => void} callbacks.onSignal - Each of the signal's parameters, while subscribed.
 * @returns {ServiceLink} The link.
 */
export function createServiceLink(connection, descriptor, {onOwnerChanged, onSignal}) {
    return new ServiceLink(connection, descriptor, {onOwnerChanged, onSignal});
}

/**
 * Starts following the Resource Pulse service on a connection: subscribed to Samples from the start until destroy(),
 * and watching its name.
 *
 * @param {Gio.DBusConnection} connection - The session bus connection.
 * @param {object} callbacks - Where the link delivers.
 * @param {(nameOwner: string|null) => void} callbacks.onOwnerChanged - The unique name owning the service's bus name
 *     when it appears, null when it vanishes. The watch reports once soon after creation, null when nobody owns the
 *     name (from Gio.bus_watch_name_on_connection).
 * @param {(parameters: GLib.Variant) => void} callbacks.onSample - Each Sample's parameters, from creation
 *     until destroy().
 * @returns {ServiceLink} The link.
 */
export function createResourcePulseLink(connection, {onOwnerChanged, onSample}) {
    return createServiceLink(connection, RESOURCE_PULSE_LINK_DESCRIPTOR, {onOwnerChanged, onSignal: onSample});
}
