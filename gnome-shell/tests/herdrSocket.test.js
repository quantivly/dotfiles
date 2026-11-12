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
import * as constants from '../extensions/resource-pulse@dotfiles/lib/constants.js';

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
/** The codes a rejection may carry, sorted: service/herdrSocket.js's HERDR_ERROR_CODES must hold exactly these. */
const EXPECTED_ERROR_CODES = ['closed', 'connect-refused', 'malformed', 'no-socket', 'remote-error', 'timeout'];
const HERDR_ERROR_PREFIX = 'herdr: ';
/** What the client appends to herdr's error text when it cuts it. */
const TRUNCATION_MARK = '…';
/** A remote error message far over HERDR_ERROR_MESSAGE_MAX_CHARS. */
const LONG_REMOTE_MESSAGE_CHARS = 2000;
/** Bytes the fake writes at a time when it streams a long reply. */
const FAKE_STREAM_CHUNK_BYTES = 1024 * 1024;
/** What a streamed reply is made of: the byte of 'x', never a newline. */
const FILLER_BYTE = 0x78;
/** A request padding far over a unix socket's send buffer (about 208 KiB here), so no single write can take it. */
const LARGE_REQUEST_PADDING_CHARS = 1024 * 1024;
/** Not UTF-8 in any position. */
const INVALID_UTF8_BYTES = new Uint8Array([0xff, 0xfe]);

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
 * @param {(requestId: string) => (string|Uint8Array)} [behaviour.replyLineFor] - Sends this line (text, or raw bytes)
 *     and a newline to any request instead of herdr's answer: a malformed or an outsized reply.
 * @param {boolean} [behaviour.isSilent] - Reads the request and never answers.
 * @param {boolean} [behaviour.closesWithoutReply] - Reads the request and closes without answering.
 * @param {number} [behaviour.streamedReplyByteCount] - Answers with this many FILLER_BYTEs and no newline, written
 *     FAKE_STREAM_CHUNK_BYTES at a time, then holds the connection open: a reply that never ends.
 * @param {boolean} [behaviour.closesOnAccept] - Closes each connection at once, reading nothing: a client still
 *     writing then finds the connection broken.
 * @param {boolean} [behaviour.closesOnceRequestArrives] - Closes each connection, unread, as soon as the request is in
 *     its receive queue: the kernel then resets it, so a client waiting for the reply finds its read failing.
 * @returns {object} The server: its socketPath, receivedRequestLines, connectionCount, clientClosedCount, and
 *     stopListening() and stop().
 */
function startFakeHerdr({
    resultsByMethod = {}, errorsByMethod = {}, replyLineFor = null, isSilent = false, closesWithoutReply = false,
    streamedReplyByteCount = 0, closesOnAccept = false, closesOnceRequestArrives = false,
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
        /** Connections the client closed while the fake still held them open (a silent or streaming fake's). */
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
     * Holds a connection open until the client closes it, counting that close.
     *
     * @param {Gio.SocketConnection} connection - The client's connection.
     * @param {Gio.DataInputStream} lineReader - Its input: a read on it ends only when the client closes.
     * @returns {void}
     */
    function holdOpenUntilClientCloses(connection, lineReader) {
        readOneLine(lineReader, line => {
            if (line === null && openConnections.has(connection))
                server.clientClosedCount++;
            closeConnection(connection);
        });
    }

    /**
     * Writes bytes, in as many writes as it takes, then calls onWritten; a failed write (the client closed first, or
     * stop() cancelled it) closes the connection instead. The bytes go out of a GLib.Bytes, which owns a copy:
     * write_all_async on a JS Uint8Array can find its memory freed or moved mid-write (EFAULT on 8 MiB, gjs 1.88).
     *
     * @param {Gio.SocketConnection} connection - The client's connection.
     * @param {Uint8Array} bytes - What to write.
     * @param {() => void} onWritten - Called once every byte is written.
     * @returns {void}
     */
    function writeBytes(connection, bytes, onWritten) {
        const ownedBytes = new GLib.Bytes(bytes);
        const totalByteCount = ownedBytes.get_size();
        const writeFrom = writtenByteCount => {
            if (writtenByteCount === totalByteCount) {
                onWritten();
                return;
            }
            const unwrittenBytes = GLib.Bytes.new_from_bytes(ownedBytes, writtenByteCount,
                totalByteCount - writtenByteCount);
            connection.get_output_stream().write_bytes_async(unwrittenBytes, GLib.PRIORITY_DEFAULT, cancellable,
                (stream, result) => {
                    let justWrittenByteCount;
                    try {
                        justWrittenByteCount = stream.write_bytes_finish(result);
                    } catch {
                        closeConnection(connection);
                        return;
                    }
                    writeFrom(writtenByteCount + justWrittenByteCount);
                });
        };
        writeFrom(0);
    }

    /**
     * Writes FILLER_BYTEs, FAKE_STREAM_CHUNK_BYTES at a time.
     *
     * @param {Gio.SocketConnection} connection - The client's connection.
     * @param {number} remainingByteCount - How many are still to write.
     * @param {() => void} onStreamed - Called once all are written.
     * @returns {void}
     */
    function streamFillerBytes(connection, remainingByteCount, onStreamed) {
        if (remainingByteCount === 0) {
            onStreamed();
            return;
        }
        const chunkByteCount = Math.min(remainingByteCount, FAKE_STREAM_CHUNK_BYTES);
        const fillerChunk = new Uint8Array(chunkByteCount).fill(FILLER_BYTE);
        writeBytes(connection, fillerChunk,
            () => streamFillerBytes(connection, remainingByteCount - chunkByteCount, onStreamed));
    }

    /**
     * Answers one request line on a connection, as the behaviour says.
     *
     * @param {Gio.SocketConnection} connection - The client's connection.
     * @param {Gio.DataInputStream} lineReader - Its input.
     * @param {string} requestLine - The request, without its newline.
     * @returns {void}
     */
    function answer(connection, lineReader, requestLine) {
        if (closesWithoutReply) {
            closeConnection(connection);
            return;
        }
        if (isSilent) {
            holdOpenUntilClientCloses(connection, lineReader);
            return;
        }
        if (streamedReplyByteCount > 0) {
            streamFillerBytes(connection, streamedReplyByteCount,
                () => holdOpenUntilClientCloses(connection, lineReader));
            return;
        }
        const replyLine = replyLineFor
            ? replyLineFor(requestIdOf(requestLine))
            : JSON.stringify(herdrReplyFor(requestLine, {resultsByMethod, errorsByMethod}));
        const lineBytes = replyLine instanceof Uint8Array ? replyLine : new TextEncoder().encode(replyLine);
        const replyBytes = new Uint8Array(lineBytes.length + 1);
        replyBytes.set(lineBytes);
        replyBytes[lineBytes.length] = '\n'.charCodeAt(0);
        writeBytes(connection, replyBytes, () => closeConnection(connection));
    }

    socketService.add_address(Gio.UnixSocketAddress.new(paths.socketPath), Gio.SocketType.STREAM,
        Gio.SocketProtocol.DEFAULT, null);
    socketService.connect('incoming', (_service, connection) => {
        server.connectionCount++;
        openConnections.add(connection);
        if (closesOnAccept) {
            closeConnection(connection);
            return true;
        }
        if (closesOnceRequestArrives) {
            // The source fires when the request is readable, or when stop() cancels it; either way, close unread.
            const readableSource = connection.get_input_stream().create_source(cancellable);
            readableSource.set_callback(() => {
                closeConnection(connection);
                return GLib.SOURCE_REMOVE;
            });
            readableSource.attach(null);
            return true;
        }
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
 * @returns {Promise<{result?: object, errorMessage?: string, errorCode?: string, elapsedMs: number}>} The outcome.
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
            error => settle({errorMessage: error.message, errorCode: error.code, elapsedMs: elapsedMs()}));
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

test('herdrSocket: a request larger than the socket\'s buffer is sent whole, over several writes, and answered', () =>
    withFakeHerdr({resultsByMethod: {[PING_METHOD]: PONG_RESULT}}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const largeParams = {padding: 'p'.repeat(LARGE_REQUEST_PADDING_CHARS)};
        const {result, errorMessage} = await outcomeOf(client.request(PING_METHOD, largeParams));
        assertEqual(result, PONG_RESULT, errorMessage);
        const receivedPaddingLength = JSON.parse(server.receivedRequestLines[0]).params.padding.length;
        assertEqual(receivedPaddingLength, LARGE_REQUEST_PADDING_CHARS);
    }));

test('herdrSocket: a server that closes before reading the request rejects as connect-refused (the send breaks)', () =>
    withFakeHerdr({closesOnAccept: true}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const largeParams = {padding: 'p'.repeat(LARGE_REQUEST_PADDING_CHARS)};
        const {errorMessage, errorCode} = await outcomeOf(client.request(PING_METHOD, largeParams));
        assertEqual(errorMessage?.startsWith('herdr: cannot send the request: '), true, `got ${errorMessage}`);
        assertEqual(errorCode, 'connect-refused');
    }));

test('herdrSocket: a connection reset while the reply is awaited rejects as malformed (the read breaks)', () =>
    withFakeHerdr({closesOnceRequestArrives: true}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const {errorMessage, errorCode} = await outcomeOf(client.request(PING_METHOD, {}));
        assertEqual(errorMessage?.startsWith('herdr: cannot read the reply: '), true, `got ${errorMessage}`);
        assertEqual(errorCode, 'malformed');
    }));

test('herdrSocket: a server that never answers rejects at the timeout (timeout), and the connection is closed', () =>
    withFakeHerdr({isSilent: true}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: SHORT_TIMEOUT_MS});
        const {errorMessage, errorCode, elapsedMs} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual([errorMessage, errorCode], [`herdr: timed out after ${SHORT_TIMEOUT_MS} ms`, 'timeout']);
        assertEqual(elapsedMs >= SHORT_TIMEOUT_MS, true, `rejected after ${elapsedMs} ms`);
        assertEqual(server.receivedRequestLines.length, 1, 'the request reached the server before the timeout');
        assertEqual(await waitUntil(() => server.clientClosedCount === 1, CLIENT_CLOSE_WAIT_MS), true,
            'the client closed its connection');
    }));

test('herdrSocket: a request given its own timeoutMs is bounded by it rather than by the client\'s', () =>
    withFakeHerdr({isSilent: true}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const {errorMessage, errorCode, elapsedMs} =
            await outcomeOf(client.request(SNAPSHOT_METHOD, {}, {timeoutMs: SHORT_TIMEOUT_MS}));
        assertEqual([errorMessage, errorCode], [`herdr: timed out after ${SHORT_TIMEOUT_MS} ms`, 'timeout']);
        assertEqual(elapsedMs < PROMPT_FAILURE_BOUND_MS, true, `rejected after ${elapsedMs} ms`);
    }));

test('herdrSocket: FocusSession\'s two herdr requests, each at HERDR_FOCUS_REQUEST_TIMEOUT_MS, and the margin left ' +
    'for its /proc scan and the bus fit under the client\'s DBUS_CALL_TIMEOUT_MS, so a slow herdr is answered ' +
    'herdr-unreachable before the client gives up', () => {
    const {HERDR_FOCUS_REQUEST_TIMEOUT_MS, FOCUS_SESSION_REPLY_MARGIN_MS, DBUS_CALL_TIMEOUT_MS} = constants;
    const focusSessionBudgetMs = 2 * HERDR_FOCUS_REQUEST_TIMEOUT_MS + FOCUS_SESSION_REPLY_MARGIN_MS;
    assertEqual({
        areWholePositiveMs: [HERDR_FOCUS_REQUEST_TIMEOUT_MS, FOCUS_SESSION_REPLY_MARGIN_MS]
            .map(valueMs => Number.isSafeInteger(valueMs) && valueMs > 0),
        fitsUnderTheClientsTimeout: focusSessionBudgetMs < DBUS_CALL_TIMEOUT_MS,
    }, {areWholePositiveMs: [true, true], fitsUnderTheClientsTimeout: true});
});

test('herdrSocket: no socket file rejects at once (no-socket) with a herdr: error naming the path', async () => {
    const paths = makeFakeConfigHome();
    try {
        const client = new herdrSocket.HerdrSocketClient({socketPath: paths.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const {errorMessage, errorCode, elapsedMs} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual([errorMessage, errorCode], [`herdr: no socket at ${paths.socketPath}`, 'no-socket']);
        assertEqual(elapsedMs < PROMPT_FAILURE_BOUND_MS, true, `rejected after ${elapsedMs} ms`);
    } finally {
        paths.remove();
    }
});

test('herdrSocket: a socket file nothing listens on (herdr crashed) rejects at once as connect-refused', () =>
    withFakeHerdr({}, async server => {
        server.stopListening();
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const {errorMessage, errorCode, elapsedMs} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual(errorMessage?.startsWith(`herdr: cannot connect to ${server.socketPath}: `), true,
            `got ${errorMessage}`);
        assertEqual(errorCode, 'connect-refused');
        assertEqual(elapsedMs < PROMPT_FAILURE_BOUND_MS, true, `rejected after ${elapsedMs} ms`);
    }));

test('herdrSocket: a plain file at the socket path rejects at once as connect-refused', async () => {
    const paths = makeFakeConfigHome();
    try {
        GLib.file_set_contents(paths.socketPath, 'not a socket');
        const client = new herdrSocket.HerdrSocketClient({socketPath: paths.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const {errorMessage, errorCode, elapsedMs} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual(errorMessage?.startsWith(`herdr: cannot connect to ${paths.socketPath}: `), true,
            `got ${errorMessage}`);
        assertEqual(errorCode, 'connect-refused');
        assertEqual(elapsedMs < PROMPT_FAILURE_BOUND_MS, true, `rejected after ${elapsedMs} ms`);
    } finally {
        paths.remove();
    }
});

test('herdrSocket: a reply carrying error rejects as remote-error with herdr\'s code and message', () =>
    withFakeHerdr({errorsByMethod: {[PROCESS_INFO_METHOD]: PANE_NOT_FOUND_ERROR}}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
        const {errorMessage, errorCode} = await outcomeOf(client.request(PROCESS_INFO_METHOD, {pane_id: 'w9:p9'}));
        assertEqual([errorMessage, errorCode], ['herdr: pane_not_found: pane not found', 'remote-error']);
    }));

test('herdrSocket: a method herdr does not know rejects as remote-error (its reply carries an empty id)', () =>
    withFakeHerdr({}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
        const {errorMessage, errorCode} = await outcomeOf(client.request('no.such.method', {}));
        assertEqual([errorMessage, errorCode],
            ['herdr: invalid_request: invalid request: unknown variant `no.such.method`', 'remote-error']);
    }));

test('herdrSocket: a remote error\'s text is cut to HERDR_ERROR_MESSAGE_MAX_CHARS, never inside a character',
    async () => {
        const maxChars = constants.HERDR_ERROR_MESSAGE_MAX_CHARS;
        const codePrefix = `${PANE_NOT_FOUND_ERROR.code}: `;
        const longMessage = 'y'.repeat(LONG_REMOTE_MESSAGE_CHARS);
        // Puts the high half of a surrogate pair at the last kept position, so a plain cut would split the character.
        const fillerBeforePair = 'z'.repeat(maxChars - 1 - codePrefix.length);
        const splitPairMessage = `${fillerBeforePair}${'\u{1F600}'.repeat(10)}`;
        const cases = [
            {remoteMessage: longMessage, keptText: `${codePrefix}${longMessage}`.slice(0, maxChars)},
            // The lone high half is dropped, so one code unit fewer is kept.
            {remoteMessage: splitPairMessage, keptText: `${codePrefix}${fillerBeforePair}`},
        ];
        for (const {remoteMessage, keptText} of cases) {
            const expectedMessage = `${HERDR_ERROR_PREFIX}${keptText}${TRUNCATION_MARK}`;
            const remoteError = {code: PANE_NOT_FOUND_ERROR.code, message: remoteMessage};
            // One fake per case, in turn.
            await withFakeHerdr({errorsByMethod: {[PING_METHOD]: remoteError}}, async server => {
                const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
                const {errorMessage, errorCode} = await outcomeOf(client.request(PING_METHOD, {}));
                assertEqual([errorMessage, errorCode], [expectedMessage, 'remote-error']);
                const maxMessageLength = HERDR_ERROR_PREFIX.length + maxChars + TRUNCATION_MARK.length;
                assertEqual(errorMessage.length <= maxMessageLength && errorMessage.isWellFormed(), true,
                    `${errorMessage.length} code units`);
            });
        }
    });

test('herdrSocket: a malformed reply rejects as malformed, and names what was wrong', async () => {
    const pong = {type: 'pong'};
    const casesByExpectedMessage = {
        'herdr: malformed reply: not UTF-8': () => INVALID_UTF8_BYTES,
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
            const {errorMessage, errorCode} = await outcomeOf(client.request(PING_METHOD, {}));
            assertEqual([errorMessage, errorCode], [expectedMessage, 'malformed']);
        });
    }
});

test('herdrSocket: a reply of exactly HERDR_REPLY_MAX_BYTES is read whole', () => {
    const maxBytes = constants.HERDR_REPLY_MAX_BYTES;
    let paddingLength = null;
    // ASCII only, so its length in characters is its length in bytes.
    const replyLineFor = requestId => {
        const unpaddedLength = JSON.stringify({id: requestId, result: {type: 'pong', padding: ''}}).length;
        paddingLength = maxBytes - unpaddedLength;
        return JSON.stringify({id: requestId, result: {type: 'pong', padding: 'x'.repeat(paddingLength)}});
    };
    return withFakeHerdr({replyLineFor}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const {result, errorMessage} = await outcomeOf(client.request(PING_METHOD, {}));
        assertEqual(errorMessage, undefined);
        assertEqual([result.type, result.padding.length], ['pong', paddingLength]);
    });
});

test('herdrSocket: one byte over HERDR_REPLY_MAX_BYTES rejects as malformed at once, with no newline or end in sight',
    () => withFakeHerdr({streamedReplyByteCount: constants.HERDR_REPLY_MAX_BYTES + 1}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const {errorMessage, errorCode} = await outcomeOf(client.request(PING_METHOD, {}));
        assertEqual([errorMessage, errorCode], ['herdr: reply too large', 'malformed']);
        assertEqual(await waitUntil(() => server.clientClosedCount === 1, CLIENT_CLOSE_WAIT_MS), true,
            'the client closed its connection');
    }));

test('herdrSocket: a server that closes without a reply rejects as malformed', () =>
    withFakeHerdr({closesWithoutReply: true}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath});
        const {errorMessage, errorCode} = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual([errorMessage, errorCode], ['herdr: connection closed before a reply', 'malformed']);
    }));

test('herdrSocket: close() rejects a request in flight and every later one as closed, twice over', () =>
    withFakeHerdr({isSilent: true}, async server => {
        const client = new herdrSocket.HerdrSocketClient({socketPath: server.socketPath, timeoutMs: LONG_TIMEOUT_MS});
        const inFlightOutcome = outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual(await waitUntil(() => server.receivedRequestLines.length === 1, CLIENT_CLOSE_WAIT_MS), true,
            'the request reached the server');
        client.close();
        client.close();
        const {errorMessage, errorCode, elapsedMs} = await inFlightOutcome;
        assertEqual([errorMessage, errorCode], ['herdr: closed', 'closed']);
        assertEqual(elapsedMs < PROMPT_FAILURE_BOUND_MS, true, `rejected after ${elapsedMs} ms`);
        const laterOutcome = await outcomeOf(client.request(SNAPSHOT_METHOD, {}));
        assertEqual([laterOutcome.errorMessage, laterOutcome.errorCode], ['herdr: closed', 'closed']);
        assertEqual(await waitUntil(() => server.clientClosedCount === 1, CLIENT_CLOSE_WAIT_MS), true,
            'the client closed its connection');
        assertEqual(server.connectionCount, 1, 'a request after close() never connects');
    }));

test('herdrSocket: HERDR_ERROR_CODES is frozen and holds exactly the six codes', () => {
    const errorCodes = herdrSocket.HERDR_ERROR_CODES;
    assertEqual(Object.isFrozen(errorCodes) && typeof errorCodes === 'object', true);
    assertEqual(Object.values(errorCodes).sort(), EXPECTED_ERROR_CODES);
});

test('herdrSocket: herdrSocketPath joins the config home', () => {
    assertEqual(herdrSocket.herdrSocketPath('/tmp/c'), '/tmp/c/herdr/herdr.sock');
});
