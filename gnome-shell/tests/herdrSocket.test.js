// service/herdrSocket.js against a fake herdr on a unix socket in a temp dir. The fake speaks herdr's framing as
// measured on herdr 0.9.1 (protocol 22): it answers only a request line ending in a newline, only a JSON object with a
// string `id`, a string `method` and an object `params`, with ONE reply line, and then closes the connection; a
// request it cannot read (not JSON, a missing or mistyped field, an unknown method) gets an `invalid_request` error
// whose id is empty, as herdr's does. So a client that does not speak herdr's protocol fails these rows.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// The member names are read through the namespace, so a missing export fails its row rather than the whole run.
import * as herdrSocket from '../extensions/resource-pulse@dotfiles/service/herdrSocket.js';

const FAKE_CONFIG_HOME_TEMPLATE = 'herdr-socket-test-XXXXXX';
const HERDR_DIRECTORY_NAME = 'herdr';
const HERDR_SOCKET_FILE_NAME = 'herdr.sock';
const HERDR_DIRECTORY_MODE = 0o700;
/** The id herdr gives the reply to a request it could not read. */
const UNREADABLE_REQUEST_ID = '';
const INVALID_REQUEST_CODE = 'invalid_request';
const SNAPSHOT_METHOD = 'session.snapshot';
const PING_METHOD = 'ping';
const PROCESS_INFO_METHOD = 'pane.process_info';
/** Synthetic results, in the shapes herdr's schema gives them (each carries its `type`). */
const SNAPSHOT_RESULT = {type: 'session_snapshot', snapshot: {agents: [], workspaces: []}};
const PONG_RESULT = {type: 'pong', version: '0.0.0', protocol: 22};
const PANE_NOT_FOUND_ERROR = {code: 'pane_not_found', message: 'pane not found'};
const REQUEST_ID_PREFIX = 'cockpit:';
const SHORT_TIMEOUT_MS = 50;
/** A timeout no row should reach: a row that waits for it has hung. */
const LONG_TIMEOUT_MS = 5000;
/** A failure that needs no waiting (no socket, nothing listening) arrives well inside this. */
const PROMPT_FAILURE_BOUND_MS = 1000;
const CLIENT_CLOSE_WAIT_MS = 1000;
/**
 * How long a row waits for a request to settle before failing on its own: past every client timeout the rows use, so
 * it fires only when the client's own timeout never did, and a row fails instead of hanging the run.
 */
const ROW_GUARD_MS = 2 * LONG_TIMEOUT_MS;
/** What a row reads when its request never settled. */
const NEVER_SETTLED_MESSAGE = `the request did not settle within ${ROW_GUARD_MS} ms`;
const POLL_INTERVAL_MS = 10;
const MICROSECONDS_PER_MILLISECOND = 1000;

/**
 * True for a JSON object (not null, not an array).
 *
 * @param {*} value - A parsed JSON value.
 * @returns {boolean} Whether it is an object.
 */
function isJsonObject(value) {
    return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * What herdr answers to one request line, given what this fake knows: an `invalid_request` with an empty id for a
 * line it cannot read or a method it does not know, else the method's error or result under the request's id.
 *
 * @param {string} requestLine - The request line, without its newline.
 * @param {object} knownMethods - The fake's methods.
 * @param {Object<string, object>} knownMethods.resultsByMethod - The result of each method that succeeds.
 * @param {Object<string, {code: string, message: string}>} knownMethods.errorsByMethod - The error of each method
 *     that fails.
 * @returns {object} The reply object.
 */
function herdrReplyFor(requestLine, {resultsByMethod, errorsByMethod}) {
    const unreadable = reason => ({
        id: UNREADABLE_REQUEST_ID, error: {code: INVALID_REQUEST_CODE, message: `invalid request: ${reason}`},
    });
    let request;
    try {
        request = JSON.parse(requestLine);
    } catch (error) {
        return unreadable(error.message);
    }
    if (!isJsonObject(request))
        return unreadable('expected a JSON object');
    if (typeof request.id !== 'string')
        return unreadable('missing or non-string field `id`');
    if (typeof request.method !== 'string')
        return unreadable('missing or non-string field `method`');
    if (!isJsonObject(request.params))
        return unreadable('missing or non-object field `params`');
    if (Object.hasOwn(errorsByMethod, request.method))
        return {id: request.id, error: errorsByMethod[request.method]};
    if (Object.hasOwn(resultsByMethod, request.method))
        return {id: request.id, result: resultsByMethod[request.method]};
    return unreadable(`unknown variant \`${request.method}\``);
}

/**
 * The id a request line carries, for a fake that answers with a line of its own.
 *
 * @param {string} requestLine - The request line, without its newline.
 * @returns {*} Its `id`, or null for a line that is not a JSON object.
 */
function requestIdOf(requestLine) {
    try {
        const request = JSON.parse(requestLine);
        return isJsonObject(request) ? request.id : null;
    } catch (error) {
        if (!(error instanceof SyntaxError))
            throw error;
        return null;
    }
}

/**
 * Removes a path if it exists, quietly: cleanup must not mask the row's own failure.
 *
 * @param {string} path - A file or an empty directory.
 * @returns {void}
 */
function removePathQuietly(path) {
    try {
        Gio.File.new_for_path(path).delete(null);
    } catch (error) {
        if (!error.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.NOT_FOUND))
            printerr(`herdrSocket.test: could not remove ${path}: ${error.message}`);
    }
}

/**
 * Makes an empty config home in a fresh temp dir, with its herdr/ directory.
 *
 * @returns {{configHome: string, herdrDirectory: string, socketPath: string, remove: () => void}} The paths, and a
 *     way to remove all of them.
 */
function makeFakeConfigHome() {
    const configHome = GLib.dir_make_tmp(FAKE_CONFIG_HOME_TEMPLATE);
    const herdrDirectory = GLib.build_filenamev([configHome, HERDR_DIRECTORY_NAME]);
    GLib.mkdir_with_parents(herdrDirectory, HERDR_DIRECTORY_MODE);
    const socketPath = GLib.build_filenamev([herdrDirectory, HERDR_SOCKET_FILE_NAME]);
    return {
        configHome, herdrDirectory, socketPath,
        remove: () => [socketPath, herdrDirectory, configHome].forEach(removePathQuietly),
    };
}

/**
 * Starts a fake herdr listening at <temp config home>/herdr/herdr.sock.
 *
 * @param {object} [behaviour] - How it answers; by default it knows no method.
 * @param {Object<string, object>} [behaviour.resultsByMethod] - The result of each method that succeeds.
 * @param {Object<string, object>} [behaviour.errorsByMethod] - The error of each method that fails.
 * @param {(requestId: string) => string} [behaviour.replyLineFor] - Sends this line (and a newline) to any request
 *     instead of herdr's answer: a malformed reply.
 * @param {boolean} [behaviour.isSilent] - Reads the request and never answers.
 * @param {boolean} [behaviour.closesWithoutReply] - Reads the request and closes without answering.
 * @returns {object} The server: its socketPath, receivedRequestLines, connectionCount, clientClosedCount, and
 *     stopListening() and stop().
 */
function startFakeHerdr({
    resultsByMethod = {}, errorsByMethod = {}, replyLineFor = null, isSilent = false, closesWithoutReply = false,
} = {}) {
    const paths = makeFakeConfigHome();
    const cancellable = new Gio.Cancellable();
    const openConnections = new Set();
    const socketService = new Gio.SocketService();
    const server = {
        socketPath: paths.socketPath,
        /** @type {string[]} Each request line read, without its newline. */
        receivedRequestLines: [],
        connectionCount: 0,
        /** Connections the client closed while the fake still held them open (a silent fake's). */
        clientClosedCount: 0,
        stopListening: () => {
            socketService.stop();
            socketService.close();
        },
        stop: () => {
            server.stopListening();
            cancellable.cancel();
            openConnections.forEach(closeConnection);
            paths.remove();
        },
    };

    /**
     * @param {Gio.SocketConnection} connection - One accepted connection.
     * @returns {void}
     */
    function closeConnection(connection) {
        openConnections.delete(connection);
        try {
            connection.close(null);
        } catch (error) {
            printerr(`herdrSocket.test: closing a fake connection failed: ${error.message}`);
        }
    }

    /**
     * Reads one line; null at the end of the stream or on any failure (a cancelled read at stop()).
     *
     * @param {Gio.DataInputStream} lineReader - The connection's input.
     * @param {(line: string|null) => void} onLine - Called once.
     * @returns {void}
     */
    function readOneLine(lineReader, onLine) {
        lineReader.read_line_async(GLib.PRIORITY_DEFAULT, cancellable, (_stream, result) => {
            let line;
            try {
                [line] = lineReader.read_line_finish_utf8(result);
            } catch {
                onLine(null);
                return;
            }
            onLine(line);
        });
    }

    /**
     * Answers one request line on a connection, as the behaviour says, and closes it unless silent.
     *
     * @param {Gio.SocketConnection} connection - The client's connection.
     * @param {Gio.DataInputStream} lineReader - Its input.
     * @param {string} requestLine - The request, without its newline.
     * @returns {void}
     */
    function answer(connection, lineReader, requestLine) {
        if (isSilent) {
            // Hold the connection open; a second read ends only when the client closes it.
            readOneLine(lineReader, line => {
                if (line === null && openConnections.has(connection))
                    server.clientClosedCount++;
                closeConnection(connection);
            });
            return;
        }
        if (closesWithoutReply) {
            closeConnection(connection);
            return;
        }
        const replyLine = replyLineFor
            ? replyLineFor(requestIdOf(requestLine))
            : JSON.stringify(herdrReplyFor(requestLine, {resultsByMethod, errorsByMethod}));
        const replyBytes = new TextEncoder().encode(`${replyLine}\n`);
        connection.get_output_stream().write_all_async(replyBytes, GLib.PRIORITY_DEFAULT, cancellable,
            (stream, result) => {
                try {
                    stream.write_all_finish(result);
                } catch (error) {
                    printerr(`herdrSocket.test: the fake's reply failed: ${error.message}`);
                }
                closeConnection(connection);
            });
    }

    socketService.add_address(Gio.UnixSocketAddress.new(paths.socketPath), Gio.SocketType.STREAM,
        Gio.SocketProtocol.DEFAULT, null);
    socketService.connect('incoming', (_service, connection) => {
        server.connectionCount++;
        openConnections.add(connection);
        const lineReader = new Gio.DataInputStream({base_stream: connection.get_input_stream()});
        readOneLine(lineReader, requestLine => {
            if (requestLine === null) {
                closeConnection(connection);
                return;
            }
            server.receivedRequestLines.push(requestLine);
            answer(connection, lineReader, requestLine);
        });
        return true;
    });
    socketService.start();
    return server;
}

/**
 * Runs a row against a fake herdr, and stops it (removing its temp dir) whatever happens.
 *
 * @param {object} behaviour - startFakeHerdr's behaviour.
 * @param {(server: object) => Promise<void>} body - The row.
 * @returns {Promise<void>}
 */
async function withFakeHerdr(behaviour, body) {
    const server = startFakeHerdr(behaviour);
    try {
        await body(server);
    } finally {
        server.stop();
    }
}

/**
 * Waits on the main loop until a condition holds or the time runs out.
 *
 * @param {() => boolean} isDone - The condition, polled every POLL_INTERVAL_MS.
 * @param {number} timeoutMs - How long to wait at most.
 * @returns {Promise<boolean>} True when the condition held in time.
 */
function waitUntil(isDone, timeoutMs) {
    const deadlineUsec = GLib.get_monotonic_time() + timeoutMs * MICROSECONDS_PER_MILLISECOND;
    return new Promise(resolve => {
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, POLL_INTERVAL_MS, () => {
            const isFinished = isDone() || GLib.get_monotonic_time() >= deadlineUsec;
            if (isFinished)
                resolve(isDone());
            return isFinished ? GLib.SOURCE_REMOVE : GLib.SOURCE_CONTINUE;
        });
    });
}

/**
 * Settles a request into something a row can compare: its result, or its rejection's message, and how long it took.
 * A request still unsettled after ROW_GUARD_MS reads as a rejection with NEVER_SETTLED_MESSAGE.
 *
 * @param {Promise<object>} requestPromise - A client request.
 * @returns {Promise<{result?: object, errorMessage?: string, elapsedMs: number}>} The outcome.
 */
function outcomeOf(requestPromise) {
    const startedAtUsec = GLib.get_monotonic_time();
    const elapsedMs = () => (GLib.get_monotonic_time() - startedAtUsec) / MICROSECONDS_PER_MILLISECOND;
    return new Promise(resolve => {
        let guardSourceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ROW_GUARD_MS, () => {
            guardSourceId = 0;
            resolve({errorMessage: NEVER_SETTLED_MESSAGE, elapsedMs: elapsedMs()});
            return GLib.SOURCE_REMOVE;
        });
        // A request settling after the guard fired changes nothing: the outcome is resolved already.
        const settle = outcome => {
            if (guardSourceId !== 0) {
                GLib.source_remove(guardSourceId);
                guardSourceId = 0;
            }
            resolve(outcome);
        };
        requestPromise.then(
            result => settle({result, elapsedMs: elapsedMs()}),
            error => settle({errorMessage: error.message, elapsedMs: elapsedMs()}));
    });
}

test('herdrSocket: a request gets its result back, exactly as herdr sent it', () =>
    withFakeHerdr({resultsByMethod: {[SNAPSHOT_METHOD]: SNAPSHOT_RESULT}}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
        const {result, errorMessage} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual(result, SNAPSHOT_RESULT, errorMessage);
    }));

test('herdrSocket: the request on the wire is one line, {id, method, params}, the id a cockpit: string', () =>
    withFakeHerdr({resultsByMethod: {[PROCESS_INFO_METHOD]: {type: 'pane_process_info', process_info: {}}}},
        async server => {
            const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
            const {errorMessage} = await outcomeOf(client.request(PROCESS_INFO_METHOD, {pane_id: 'w1:p2'}));
            assertEqual(errorMessage, undefined);
            assertEqual(server.receivedRequestLines.length, 1);
            const request = JSON.parse(server.receivedRequestLines[0]);
            assertEqual(Object.keys(request).sort(), ['id', 'method', 'params']);
            assertEqual([request.method, request.params], [PROCESS_INFO_METHOD, {pane_id: 'w1:p2'}]);
            assertEqual(typeof request.id === 'string' && request.id.startsWith(REQUEST_ID_PREFIX), true,
                `id ${JSON.stringify(request.id)}`);
        }));

test('herdrSocket: two requests at once each get their own result, on their own connection, with distinct ids', () =>
    withFakeHerdr({resultsByMethod: {[SNAPSHOT_METHOD]: SNAPSHOT_RESULT, [PING_METHOD]: PONG_RESULT}},
        async server => {
            const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
            const outcomes = await Promise.all([
                outcomeOf(client.request(PING_METHOD, {})), outcomeOf(client.request(SNAPSHOT_METHOD, {})),
            ]);
            const resultsOrErrors = outcomes.map(({result, errorMessage}) => result ?? errorMessage);
            assertEqual(resultsOrErrors, [PONG_RESULT, SNAPSHOT_RESULT]);
            assertEqual(server.connectionCount, 2);
            const requestIds = server.receivedRequestLines.map(line => JSON.parse(line).id);
            assertEqual(new Set(requestIds).size, 2, `ids ${JSON.stringify(requestIds)}`);
        }));

test('herdrSocket: a server that never answers rejects at the timeout, and the connection is closed', () =>
    withFakeHerdr({isSilent: true}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: SHORT_TIMEOUT_MS});
        const {errorMessage, elapsedMs} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual(errorMessage, `herdr: timed out after ${SHORT_TIMEOUT_MS} ms`);
        assertEqual(elapsedMs >= SHORT_TIMEOUT_MS, true, `rejected after ${elapsedMs} ms`);
        assertEqual(server.receivedRequestLines.length, 1, 'the request reached the server before the timeout');
        assertEqual(await waitUntil(() => server.clientClosedCount === 1, CLIENT_CLOSE_WAIT_MS), true,
            'the client closed its connection');
    }));

test('herdrSocket: no socket file rejects at once with a herdr: error naming the path', async () => {
    const paths = makeFakeConfigHome();
    try {
        const client = new herdrSocket.HerdrSocketClient({socketPath: paths.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const {errorMessage, elapsedMs} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual(errorMessage, `herdr: no socket at ${paths.socketPath}`);
        assertEqual(elapsedMs < PROMPT_FAILURE_BOUND_MS, true, `rejected after ${elapsedMs} ms`);
    } finally {
        paths.remove();
    }
});

test('herdrSocket: a socket file nothing listens on (herdr gone) rejects at once with a herdr: error', () =>
    withFakeHerdr({}, async server => {
        server.stopListening();
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const {errorMessage, elapsedMs} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual(errorMessage?.startsWith(`herdr: cannot connect to ${server.socketPath}: `), true,
            `got ${errorMessage}`);
        assertEqual(elapsedMs < PROMPT_FAILURE_BOUND_MS, true, `rejected after ${elapsedMs} ms`);
    }));

test('herdrSocket: a reply carrying error rejects with its message and code', () =>
    withFakeHerdr({errorsByMethod: {[PROCESS_INFO_METHOD]: PANE_NOT_FOUND_ERROR}}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
        const {errorMessage} = await outcomeOf(client.request(PROCESS_INFO_METHOD, {pane_id: 'w9:p9'}));
        assertEqual(errorMessage, 'herdr: pane not found (pane_not_found)');
    }));

test('herdrSocket: a method herdr does not know rejects with herdr\'s own text (its reply carries an empty id)', () =>
    withFakeHerdr({}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
        const {errorMessage} = await outcomeOf(client.request('no.such.method', {}));
        assertEqual(errorMessage, 'herdr: invalid request: unknown variant `no.such.method` (invalid_request)');
    }));

test('herdrSocket: a malformed reply rejects with herdr: malformed reply, and names what was wrong', async () => {
    const pong = {type: 'pong'};
    const casesByExpectedMessage = {
        'herdr: malformed reply: not JSON': () => 'not json',
        'herdr: malformed reply: not an object': () => '[1, 2]',
        'herdr: malformed reply: not the id of the request': () => JSON.stringify({id: 'cockpit:other', result: pong}),
        'herdr: malformed reply: an empty id on a result': () => JSON.stringify({id: '', result: pong}),
        'herdr: malformed reply: neither result nor error': requestId => JSON.stringify({id: requestId}),
        'herdr: malformed reply: a result that is not an object':
            requestId => JSON.stringify({id: requestId, result: 5}),
        'herdr: malformed reply: an error without a string code and message':
            requestId => JSON.stringify({id: requestId, error: 'nope'}),
    };
    for (const [expectedMessage, replyLineFor] of Object.entries(casesByExpectedMessage)) {
        // One fake per case, in turn: each answers its own malformed line.
        await withFakeHerdr({replyLineFor}, async server => {
            const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
            const {errorMessage} = await outcomeOf(client.request(PING_METHOD, {}));
            assertEqual(errorMessage, expectedMessage);
        });
    }
});

test('herdrSocket: a server that closes without a reply rejects with a herdr: error', () =>
    withFakeHerdr({closesWithoutReply: true}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
        const {errorMessage} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual(errorMessage, 'herdr: connection closed before a reply');
    }));

test('herdrSocket: close() rejects a request in flight and every later one with herdr: closed, twice over', () =>
    withFakeHerdr({isSilent: true}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const inFlightOutcome = outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual(await waitUntil(() => server.receivedRequestLines.length === 1, CLIENT_CLOSE_WAIT_MS), true,
            'the request reached the server');
        client.close();
        client.close();
        const {errorMessage, elapsedMs} = await inFlightOutcome;
        assertEqual(errorMessage, 'herdr: closed');
        assertEqual(elapsedMs < PROMPT_FAILURE_BOUND_MS, true, `rejected after ${elapsedMs} ms`);
        assertEqual((await outcomeOf(client.request(SNAPSHOT_METHOD, {}))).errorMessage, 'herdr: closed');
        assertEqual(await waitUntil(() => server.clientClosedCount === 1, CLIENT_CLOSE_WAIT_MS), true,
            'the client closed its connection');
        assertEqual(server.connectionCount, 1, 'a request after close() never connects');
    }));

test('herdrSocket: herdrSocketPath joins the config home', () => {
    assertEqual(herdrSocket.herdrSocketPath('/tmp/c'), '/tmp/c/herdr/herdr.sock');
});
