// displayConfig.js on a fake connection, under plain gjs: the one GetCurrentState call the cockpit's monitor rule
// needs, asynchronous with DBUS_CALL_TIMEOUT_MS, only the latest request's answer handed on, a failure handed on as null and
// logged once, and nothing handed on after destroy(). The reply is a real GLib.Variant of Mutter's signature, built
// from the DisplayConfig fixture, so the row also shows lib/cockpitMonitor.js reading what the reader hands on.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// Read through the namespace, so a missing export fails its row rather than the whole run.
import * as displayConfigModule from '../extensions/resource-pulse@dotfiles/displayConfig.js';
import {monitorDescriptorsFromDisplayConfig} from '../extensions/resource-pulse@dotfiles/lib/cockpitMonitor.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';

const FIXTURE_URI = GLib.uri_resolve_relative(import.meta.url, 'fixtures/cockpit/display-config-two-monitors.json',
    GLib.UriFlags.NONE);
const [FIXTURE_PATH] = GLib.filename_from_uri(FIXTURE_URI);
const [, FIXTURE_BYTES] = Gio.File.new_for_path(FIXTURE_PATH).load_contents(null);
const DISPLAY_CONFIG_STATE = JSON.parse(new TextDecoder().decode(FIXTURE_BYTES)).state;
/** GetCurrentState's reply type, from org.gnome.Mutter.DisplayConfig's introspection. */
const GET_CURRENT_STATE_REPLY_SIGNATURE = '(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})';
/** The wire names and numbers, written out rather than imported, so a renamed constant fails here. */
const DISPLAY_CONFIG_NAME = 'org.gnome.Mutter.DisplayConfig';
const DISPLAY_CONFIG_PATH = '/org/gnome/Mutter/DisplayConfig';
const GET_CURRENT_STATE = 'GetCurrentState';
const CALL_TIMEOUT_MS = 2000;
const START_USEC = 1_000_000_000;

/**
 * A fake session bus connection: records each call; a row answers or fails it by index.
 */
class FakeConnection {
    constructor() {
        /** @type {Array<object>} Every call, with its arguments and callback. */
        this.calls = [];
    }

    /**
     * Records a call, as Gio.DBusConnection.call takes it.
     *
     * @param {string} busName - The callee's name.
     * @param {string} objectPath - The object.
     * @param {string} interfaceName - The interface.
     * @param {string} methodName - The method.
     * @param {GLib.Variant|null} parameters - Its parameters.
     * @param {GLib.VariantType|null} replyType - The reply type asked for.
     * @param {Gio.DBusCallFlags} flags - The call's flags.
     * @param {number} timeoutMs - Its timeout.
     * @param {Gio.Cancellable|null} cancellable - Its cancellable.
     * @param {(connection: FakeConnection, result: object) => void} callback - Called with the answer.
     * @returns {void}
     */
    call(busName, objectPath, interfaceName, methodName, parameters, replyType, flags, timeoutMs, cancellable,
        callback) {
        this.calls.push({
            busName, objectPath, interfaceName, methodName, parameters, replyType, flags, timeoutMs, cancellable,
            callback,
        });
    }

    /**
     * What call_finish gives for a fake result: the reply, or the error thrown.
     *
     * @param {{reply: GLib.Variant|null, error: Error|null}} result - What answer() or fail() passed.
     * @returns {GLib.Variant} The reply.
     * @throws {Error} The failure.
     */
    call_finish(result) {
        if (result.error !== null)
            throw result.error;
        return result.reply;
    }

    /**
     * Answers a call; a call never made answers nothing, so the row's assertion (each asserts the calls made or what
     * their answers did) names it.
     *
     * @param {number} callIndex - Which call.
     * @param {GLib.Variant} reply - Its reply.
     * @returns {void}
     */
    answer(callIndex, reply) {
        this.calls[callIndex]?.callback(this, {reply, error: null});
    }

    /**
     * Fails a call; a call never made fails nothing, as answer() does.
     *
     * @param {number} callIndex - Which call.
     * @param {Error} error - Its failure.
     * @returns {void}
     */
    fail(callIndex, error) {
        this.calls[callIndex]?.callback(this, {reply: null, error});
    }
}

/**
 * A reader on a fake connection, recording what it hands on and what it logs.
 *
 * @param {object} [options] - The fixture's shape.
 * @param {(state: *) => void} [options.onStateRead] - Replaces the recording callback.
 * @returns {{reader: object, connection: FakeConnection, statesRead: Array<*>, logged: string[]}} The fixture.
 */
function makeReaderFixture({onStateRead = null} = {}) {
    const connection = new FakeConnection();
    const statesRead = [];
    const logged = [];
    const reader = new displayConfigModule.DisplayConfigReader({
        connection,
        errorLog: new RateLimitedLogger({nowUsec: () => START_USEC, write: line => logged.push(line)}),
        onStateRead: onStateRead ?? (state => statesRead.push(state)),
    });
    return {reader, connection, statesRead, logged};
}

/**
 * A fake bus fetch, for a reader made with no connection (as extension.js makes it): records each fetch as
 * Gio.bus_get takes it; a row completes or fails it by index, and busGetFinish gives what that completion carried.
 */
class FakeBusFetch {
    constructor() {
        /** @type {Array<{busType: Gio.BusType, cancellable: Gio.Cancellable, callback: Function}>} Every fetch. */
        this.fetches = [];
    }

    /**
     * Records a fetch, as Gio.bus_get takes it.
     *
     * @param {Gio.BusType} busType - The bus.
     * @param {Gio.Cancellable} cancellable - Its cancellable.
     * @param {(source: null, result: object) => void} callback - Called when the fetch completes.
     * @returns {void}
     */
    busGet(busType, cancellable, callback) {
        this.fetches.push({busType, cancellable, callback});
    }

    /**
     * What Gio.bus_get_finish gives for a fake result: the connection, or the error thrown.
     *
     * @param {{connection: FakeConnection|null, error: Error|null}} result - What connect() or fail() passed.
     * @returns {FakeConnection} The connection.
     * @throws {Error} The failure.
     */
    busGetFinish(result) {
        if (result.error !== null)
            throw result.error;
        return result.connection;
    }

    /**
     * Completes a fetch with a connection; a fetch never made completes nothing, so the row's assertion names it.
     *
     * @param {number} fetchIndex - Which fetch.
     * @param {FakeConnection} connection - The connection it gives.
     * @returns {void}
     */
    connect(fetchIndex, connection) {
        this.fetches[fetchIndex]?.callback(null, {connection, error: null});
    }

    /**
     * Fails a fetch; a fetch never made fails nothing, so the row's assertion names it.
     *
     * @param {number} fetchIndex - Which fetch.
     * @param {Error} error - Its failure.
     * @returns {void}
     */
    fail(fetchIndex, error) {
        this.fetches[fetchIndex]?.callback(null, {connection: null, error});
    }
}

/**
 * A reader with no connection, which fetches its own through a fake bus fetch, recording what it hands on and logs.
 *
 * @returns {{reader: object, busFetch: FakeBusFetch, connection: FakeConnection, statesRead: Array<*>,
 *     logged: string[]}} The fixture; connection is what the fetch gives when a row completes it.
 */
function makeFetchingReaderFixture() {
    const busFetch = new FakeBusFetch();
    const statesRead = [];
    const logged = [];
    const reader = new displayConfigModule.DisplayConfigReader({
        busGet: (busType, cancellable, callback) => busFetch.busGet(busType, cancellable, callback),
        busGetFinish: result => busFetch.busGetFinish(result),
        errorLog: new RateLimitedLogger({nowUsec: () => START_USEC, write: line => logged.push(line)}),
        onStateRead: state => statesRead.push(state),
    });
    return {reader, busFetch, connection: new FakeConnection(), statesRead, logged};
}

/** @returns {GLib.Variant} GetCurrentState's reply holding the fixture's state. */
function currentStateReply() {
    return new GLib.Variant(GET_CURRENT_STATE_REPLY_SIGNATURE, DISPLAY_CONFIG_STATE);
}

/** @returns {GLib.Error} A call that timed out. */
function timedOutError() {
    return new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.TIMED_OUT, 'Timeout was reached');
}

test('displayConfig: a request calls Mutter\'s GetCurrentState asynchronously (no parameters, any reply type, ' +
    'NO_AUTO_START, DBUS_CALL_TIMEOUT_MS, the reader\'s cancellable) and hands on the reply unpacked, which ' +
    'lib/cockpitMonitor.js reads', () => {
    const {reader, connection, statesRead} = makeReaderFixture();
    reader.requestState();
    const [stateCall] = connection.calls;
    connection.answer(0, currentStateReply());
    assertEqual({
        callCount: connection.calls.length,
        call: stateCall && [stateCall.busName, stateCall.objectPath, stateCall.interfaceName, stateCall.methodName,
            stateCall.parameters, stateCall.replyType, stateCall.flags, stateCall.timeoutMs],
        isCancellable: stateCall?.cancellable instanceof Gio.Cancellable,
        statesRead,
        descriptors: monitorDescriptorsFromDisplayConfig(statesRead[0]),
    }, {
        callCount: 1,
        call: [DISPLAY_CONFIG_NAME, DISPLAY_CONFIG_PATH, DISPLAY_CONFIG_NAME, GET_CURRENT_STATE, null, null,
            Gio.DBusCallFlags.NO_AUTO_START, CALL_TIMEOUT_MS],
        isCancellable: true,
        statesRead: [DISPLAY_CONFIG_STATE],
        descriptors: [
            {connector: 'eDP-1', vendor: 'CMN', product: 'N140JCN-GT1'},
            {connector: 'DP-1', vendor: 'DEL', product: 'DELL U2723QE'},
        ],
    });
});

test('displayConfig: only the latest request\'s answer is handed on: an earlier one answering later is dropped', () => {
    const {reader, connection, statesRead} = makeReaderFixture();
    reader.requestState();
    reader.requestState();
    connection.answer(1, currentStateReply());
    connection.answer(0, new GLib.Variant('(u)', [1]));
    assertEqual({callCount: connection.calls.length, statesRead}, {callCount: 2, statesRead: [DISPLAY_CONFIG_STATE]});
});

test('displayConfig: a failed call hands on null (so the monitor rule falls back) and is logged once per 10 minutes',
    () => {
        const {reader, connection, statesRead, logged} = makeReaderFixture();
        reader.requestState();
        connection.fail(0, timedOutError());
        reader.requestState();
        connection.fail(1, timedOutError());
        assertEqual({statesRead, logLines: logged.length, namesTheCall: logged[0]?.includes(GET_CURRENT_STATE)},
            {statesRead: [null, null], logLines: 1, namesTheCall: true});
    });

test('displayConfig: destroy() cancels the call in flight; its answer then hands on nothing and logs nothing, and a ' +
    'request after it calls nothing', () => {
    const {reader, connection, statesRead, logged} = makeReaderFixture();
    reader.requestState();
    reader.destroy();
    const isCancelled = connection.calls[0].cancellable.is_cancelled();
    connection.fail(0, new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED, 'Operation was cancelled'));
    reader.requestState();
    reader.destroy();
    assertEqual({isCancelled, statesRead, logged, callCount: connection.calls.length},
        {isCancelled: true, statesRead: [], logged: [], callCount: 1});
});

test('displayConfig: a callback that throws is logged, never thrown out of the D-Bus callback', () => {
    const {reader, connection, logged} = makeReaderFixture({
        onStateRead: () => {
            throw new Error('placement failed');
        },
    });
    reader.requestState();
    let escapedError = null;
    try {
        connection.answer(0, currentStateReply());
    } catch (error) {
        escapedError = error.message;
    }
    assertEqual({escapedError, logLines: logged.length, namesTheFailure: logged[0]?.includes('placement failed')},
        {escapedError: null, logLines: 1, namesTheFailure: true});
});

test('displayConfig: with no connection (the shell\'s path) requests made while the session bus is being fetched ' +
    'wait for it: one fetch with the reader\'s cancellable, then one call for the latest request once connected; a ' +
    'request after that calls at once, fetching nothing', () => {
    const {reader, busFetch, connection, statesRead} = makeFetchingReaderFixture();
    reader.requestState();
    reader.requestState();
    const callsWhileConnecting = connection.calls.length;
    busFetch.connect(0, connection);
    connection.answer(0, currentStateReply());
    reader.requestState();
    const [fetch] = busFetch.fetches;
    assertEqual({
        fetchCount: busFetch.fetches.length,
        fetchedBus: fetch?.busType,
        isCancellable: fetch?.cancellable instanceof Gio.Cancellable,
        callsWhileConnecting,
        callCount: connection.calls.length,
        statesRead,
    }, {
        fetchCount: 1, fetchedBus: Gio.BusType.SESSION, isCancellable: true, callsWhileConnecting: 0, callCount: 2,
        statesRead: [DISPLAY_CONFIG_STATE],
    });
});

test('displayConfig: destroy() while the session bus is being fetched cancels the fetch; a fetch that completes ' +
    'anyway then calls nothing, hands on nothing and logs nothing', () => {
    const {reader, busFetch, connection, statesRead, logged} = makeFetchingReaderFixture();
    reader.requestState();
    reader.destroy();
    const isCancelled = busFetch.fetches[0]?.cancellable.is_cancelled();
    busFetch.connect(0, connection);
    assertEqual({isCancelled, callCount: connection.calls.length, statesRead, logged},
        {isCancelled: true, callCount: 0, statesRead: [], logged: []});
});

test('displayConfig: a failed fetch of the session bus hands on null once (so the monitor rule falls back) and is ' +
    'logged; a later request fetches the bus again', () => {
    const {reader, busFetch, connection, statesRead, logged} = makeFetchingReaderFixture();
    reader.requestState();
    busFetch.fail(0, new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.FAILED, 'Cannot autolaunch D-Bus'));
    const statesReadAfterTheFailure = [...statesRead];
    reader.requestState();
    busFetch.connect(1, connection);
    connection.answer(0, currentStateReply());
    assertEqual({
        statesReadAfterTheFailure,
        logLines: logged.length,
        namesTheFetch: logged[0]?.includes('cannot reach DisplayConfig on the bus'),
        fetchCount: busFetch.fetches.length,
        statesRead,
    }, {
        statesReadAfterTheFailure: [null], logLines: 1, namesTheFetch: true, fetchCount: 2,
        statesRead: [null, DISPLAY_CONFIG_STATE],
    });
});
