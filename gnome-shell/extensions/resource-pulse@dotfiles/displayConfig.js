// The cockpit's read of Mutter's display configuration: org.gnome.Mutter.DisplayConfig's GetCurrentState, whose
// monitors carry the vendor and product the cockpit's monitor rule names (lib/cockpitMonitor.js reads the reply). Gio
// and GLib only (no Shell, St, Clutter or Meta), so it runs under plain gjs, with its connection injectable, or, as the
// shell makes it (with none), the fetch of the session bus's connection (Gio.bus_get and Gio.bus_get_finish).
//
// It runs inside gnome-shell, which is itself the process that answers (Mutter owns the name), so:
// - the call is asynchronous, with DBUS_CALL_TIMEOUT_MS, never synchronous: a synchronous call would block the very
//   main loop that must answer it;
// - requestState() makes one call; only the latest request's answer is handed on (a request made since, on a later
//   monitors-changed, supersedes it), as GLib.Variant.deepUnpack() gives it, or null for a failure (logged,
//   rate-limited), so the monitor rule falls back to the only, or the largest non-primary, monitor;
// - no proxy object: a call on the connection (a proxy owned only by JavaScript, with handlers, costs a forced garbage
//   collection per signal: docs/superpowers/specs/2026-11-10-resource-pulse-performance-design.md);
// - destroy() cancels the call in flight and the connection's fetch, and nothing is handed on after it; neither a
//   D-Bus callback nor onStateRead can throw out of it (a failure is logged).
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {DBUS_CALL_TIMEOUT_MS} from './lib/constants.js';
import {describeError} from './lib/errorLog.js';

const DISPLAY_CONFIG_BUS_NAME = 'org.gnome.Mutter.DisplayConfig';
const DISPLAY_CONFIG_OBJECT_PATH = '/org/gnome/Mutter/DisplayConfig';
const DISPLAY_CONFIG_INTERFACE_NAME = 'org.gnome.Mutter.DisplayConfig';
const GET_CURRENT_STATE_METHOD_NAME = 'GetCurrentState';
/** GetCurrentState takes no parameters. */
const NO_PARAMETERS = null;
/**
 * No reply type is asked for: lib/cockpitMonitor.js reads only the parts it knows, so a Mutter whose reply grew a field
 * still identifies the monitors, rather than failing the call on its type.
 */
const ANY_REPLY_TYPE = null;
/** No call asks the bus to activate a name. */
const CALL_FLAGS = Gio.DBusCallFlags.NO_AUTO_START;
// Template keys of the rate-limited journal lines (lib/errorLog.js).
const READ_FAILURE_LOG_KEY = 'display config read failed';
const CONNECT_FAILURE_LOG_KEY = 'display config connection failed';
const CALLBACK_FAILURE_LOG_KEY = 'display config callback failed';

/** Reads DisplayConfig's state when asked, handing on the latest answer. */
export class DisplayConfigReader {
    /**
     * @param {object} options - Everything injectable, so the rows can run it on a fake connection or a fake fetch.
     * @param {Gio.BusType} [options.busType] - The bus whose connection is fetched when none is given: the session bus.
     * @param {Gio.DBusConnection|null} [options.connection] - A connection to use instead of fetching busType's.
     * @param {Function} [options.busGet] - Starts the connection's fetch, as Gio.bus_get(busType, cancellable,
     *     callback) does: Gio.bus_get unless a row passes a fake.
     * @param {Function} [options.busGetFinish] - Ends it, as Gio.bus_get_finish(result) does, giving the connection or
     *     throwing: Gio.bus_get_finish unless a row passes a fake.
     * @param {import('./lib/errorLog.js').RateLimitedLogger} options.errorLog - Where failures go.
     * @param {(state: *) => void} options.onStateRead - Called with the latest request's answer: the unpacked reply,
     *     or null when the call failed.
     */
    constructor({
        busType = Gio.BusType.SESSION, connection = null, busGet = Gio.bus_get, busGetFinish = Gio.bus_get_finish,
        errorLog, onStateRead,
    }) {
        this._busType = busType;
        this._connection = connection;
        this._busGet = busGet;
        this._busGetFinish = busGetFinish;
        this._errorLog = errorLog;
        this._onStateRead = onStateRead;
        // Cancels the call in flight and the connection's fetch, at destroy().
        this._cancellable = new Gio.Cancellable();
        this._isDestroyed = false;
        this._isConnecting = false;
        // Each request takes the next number; only the answer to the latest one is handed on.
        this._latestRequestNumber = 0;
    }

    /**
     * Asks for DisplayConfig's state once: at once on a connection, or once the connection's asynchronous fetch is
     * done. Supersedes every earlier request. Does nothing once destroyed.
     *
     * @returns {void}
     */
    requestState() {
        if (this._isDestroyed)
            return;
        this._latestRequestNumber++;
        if (this._connection !== null) {
            this._callGetCurrentState(this._latestRequestNumber);
            return;
        }
        if (this._isConnecting)
            return;
        this._isConnecting = true;
        this._busGet(this._busType, this._cancellable, (_source, result) => this._onConnected(result));
    }

    /**
     * Cancels the call in flight and the connection's fetch; nothing is handed on afterwards. Safe twice.
     *
     * @returns {void}
     */
    destroy() {
        if (this._isDestroyed)
            return;
        this._isDestroyed = true;
        this._cancellable.cancel();
    }

    /**
     * Takes the fetched connection and makes the latest request on it; a failed fetch hands on null, logged, and the
     * next request fetches again. After destroy() it does nothing, whatever the fetch gave.
     *
     * @param {Gio.AsyncResult} result - The fetch's result.
     * @returns {void}
     */
    _onConnected(result) {
        this._isConnecting = false;
        if (this._isDestroyed)
            return;
        try {
            this._connection = this._busGetFinish(result);
        } catch (error) {
            this._logFailure(`cannot reach DisplayConfig on the bus: ${describeError(error)}`, CONNECT_FAILURE_LOG_KEY);
            this._handOn(this._latestRequestNumber, null);
            return;
        }
        this._callGetCurrentState(this._latestRequestNumber);
    }

    /**
     * Calls GetCurrentState, asynchronously.
     *
     * @param {number} requestNumber - The request's number.
     * @returns {void}
     */
    _callGetCurrentState(requestNumber) {
        this._connection.call(DISPLAY_CONFIG_BUS_NAME, DISPLAY_CONFIG_OBJECT_PATH, DISPLAY_CONFIG_INTERFACE_NAME,
            GET_CURRENT_STATE_METHOD_NAME, NO_PARAMETERS, ANY_REPLY_TYPE, CALL_FLAGS, DBUS_CALL_TIMEOUT_MS,
            this._cancellable,
            (callingConnection, result) => this._onAnswered(requestNumber, callingConnection, result));
    }

    /**
     * Reads GetCurrentState's answer and hands it on, unpacked, if it answers the latest request; a failure is logged
     * (a cancel by destroy() is not) and hands on null.
     *
     * @param {number} requestNumber - The request's number.
     * @param {Gio.DBusConnection} callingConnection - The connection the call went out on.
     * @param {Gio.AsyncResult} result - The call's result.
     * @returns {void}
     */
    _onAnswered(requestNumber, callingConnection, result) {
        let currentState = null;
        try {
            currentState = callingConnection.call_finish(result).deepUnpack();
        } catch (error) {
            const errorText = describeError(error);
            this._logFailure(`DisplayConfig ${GET_CURRENT_STATE_METHOD_NAME} failed: ${errorText}`,
                READ_FAILURE_LOG_KEY);
        }
        this._handOn(requestNumber, currentState);
    }

    /**
     * Hands an answer on, if it answers the latest request and the reader is not destroyed; a callback that throws is
     * logged.
     *
     * @param {number} requestNumber - The request answered.
     * @param {*} currentState - The unpacked reply, or null.
     * @returns {void}
     */
    _handOn(requestNumber, currentState) {
        if (this._isDestroyed || requestNumber !== this._latestRequestNumber)
            return;
        try {
            this._onStateRead(currentState);
        } catch (error) {
            this._logFailure(`could not use DisplayConfig's state: ${describeError(error)}`, CALLBACK_FAILURE_LOG_KEY);
        }
    }

    /**
     * Logs a failure, rate-limited by its key, unless the reader is destroyed (a cancelled call's failure is not one).
     *
     * @param {string} line - The journal line.
     * @param {string} logKey - Its rate limit's key.
     * @returns {void}
     */
    _logFailure(line, logKey) {
        if (!this._isDestroyed)
            this._errorLog.log(line, logKey);
    }
}
