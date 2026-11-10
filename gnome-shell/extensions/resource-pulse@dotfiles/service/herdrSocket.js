// herdr's JSON API over its unix socket, for the cockpit service: asynchronous, one connection per request, never a
// subprocess, and every request bounded by a timeout, so a hung herdr fails a request instead of stalling the service.
//
// The framing, measured on herdr 0.9.1 (`herdr api schema --json` reports protocol 22) with read-only requests (ping,
// session.snapshot, pane.process_info on a pane that does not exist, and malformed lines):
// - A request is ONE line: a JSON object {"id": <string>, "method": <string>, "params": <object>} and a newline.
//   herdr answers nothing until the newline arrives. `id` must be a string and `params` must be present (an empty
//   object for a method that takes none); a field beyond these three is ignored.
// - The reply is ONE line: {"id": <the request's id>, "result": {"type": <the result's kind>, ...}} on success, or
//   {"id": <the request's id>, "error": {"code": <string>, "message": <string>}} on failure. A request herdr cannot
//   read (not JSON, a missing or mistyped field, an unknown method) gets {"id": "", "error": {"code":
//   "invalid_request", ...}}: an empty id, since it could not read one.
// - herdr closes the connection after its one reply, and does not answer a second request on it. So: one connection
//   per request, as herdr's own CLI does.
// The protocol number comes only in a `ping` reply (its result's `protocol`), a round trip of its own rather than
// anything sent at connect time, so this client does not check it.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {HERDR_REQUEST_TIMEOUT_MS, HERDR_SOCKET_RELATIVE_PATH} from '../lib/constants.js';
import {describeError} from '../lib/errorLog.js';

/** Every request id this process sends is this prefix and a number never reused within the process. */
const REQUEST_ID_PREFIX = 'cockpit:';
/** Ends a request line; herdr's reply line ends with it too. */
const LINE_TERMINATOR = '\n';
/** The id herdr gives the reply to a request it could not read. */
const UNREADABLE_REQUEST_REPLY_ID = '';
/** What every request still in flight, and every later one, rejects with once close() is called. */
const CLOSED_MESSAGE = 'herdr: closed';

/** The number in the next request's id. */
let nextRequestNumber = 1;

/**
 * The path of herdr's API socket.
 *
 * @param {string} configHome - The user's config home (XDG_CONFIG_HOME, normally ~/.config).
 * @returns {string} configHome joined with HERDR_SOCKET_RELATIVE_PATH.
 */
export function herdrSocketPath(configHome) {
    return `${configHome.replace(/\/+$/, '')}/${HERDR_SOCKET_RELATIVE_PATH}`;
}

/**
 * True for a JSON object: not null, not an array.
 *
 * @param {*} value - A parsed JSON value.
 * @returns {boolean} Whether it is an object.
 */
function isJsonObject(value) {
    return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * @param {string} reason - What was wrong with the reply; never the reply's text, which can carry terminal titles.
 * @returns {Error} The rejection for a reply that is not herdr's shape.
 */
function malformedReplyError(reason) {
    return new Error(`herdr: malformed reply: ${reason}`);
}

/**
 * Connects to a unix socket.
 *
 * @param {string} socketPath - The socket's path.
 * @param {Gio.Cancellable} cancellable - Cancels the connect.
 * @returns {Promise<Gio.SocketConnection>} The connection; rejects with a herdr: error naming the path.
 */
function connectToSocket(socketPath, cancellable) {
    return new Promise((resolve, reject) => {
        const socketClient = new Gio.SocketClient();
        socketClient.connect_async(Gio.UnixSocketAddress.new(socketPath), cancellable, (_client, result) => {
            let connection;
            try {
                connection = socketClient.connect_finish(result);
            } catch (error) {
                const isSocketMissing = error instanceof GLib.Error &&
                    error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.NOT_FOUND);
                reject(isSocketMissing
                    ? new Error(`herdr: no socket at ${socketPath}`)
                    : new Error(`herdr: cannot connect to ${socketPath}: ${describeError(error)}`));
                return;
            }
            resolve(connection);
        });
    });
}

/**
 * Writes the whole request line.
 *
 * @param {Gio.SocketConnection} connection - The connection to herdr.
 * @param {string} requestLine - The request, with its newline.
 * @param {Gio.Cancellable} cancellable - Cancels the write.
 * @returns {Promise<void>} Resolves once every byte is written; rejects with a herdr: error.
 */
function sendRequestLine(connection, requestLine, cancellable) {
    const requestBytes = new TextEncoder().encode(requestLine);
    return new Promise((resolve, reject) => {
        connection.get_output_stream().write_all_async(requestBytes, GLib.PRIORITY_DEFAULT, cancellable,
            (outputStream, result) => {
                try {
                    outputStream.write_all_finish(result);
                } catch (error) {
                    reject(new Error(`herdr: cannot send the request: ${describeError(error)}`));
                    return;
                }
                resolve();
            });
    });
}

/**
 * Reads herdr's one reply line.
 *
 * @param {Gio.SocketConnection} connection - The connection to herdr.
 * @param {Gio.Cancellable} cancellable - Cancels the read.
 * @returns {Promise<string>} The reply line without its newline; rejects with a herdr: error, also when herdr
 *     closes the connection before sending anything.
 */
function readReplyLine(connection, cancellable) {
    // close_base_stream false: the connection is closed as a whole by exchangeOneRequest, never through this reader.
    const lineReader = new Gio.DataInputStream({base_stream: connection.get_input_stream(), close_base_stream: false});
    return new Promise((resolve, reject) => {
        lineReader.read_line_async(GLib.PRIORITY_DEFAULT, cancellable, (_stream, result) => {
            let replyLine;
            try {
                [replyLine] = lineReader.read_line_finish_utf8(result);
            } catch (error) {
                reject(new Error(`herdr: cannot read the reply: ${describeError(error)}`));
                return;
            }
            if (replyLine === null) {
                reject(new Error('herdr: connection closed before a reply'));
                return;
            }
            resolve(replyLine);
        });
    });
}

/**
 * Closes a connection whose exchange is over. A failure to close is not reported: the exchange's outcome is already
 * decided, and close(2) releases the descriptor even when it reports an error.
 *
 * @param {Gio.SocketConnection} connection - The connection to herdr.
 * @returns {void}
 */
function closeConnection(connection) {
    try {
        connection.close(null);
    } catch (error) {
        if (!(error instanceof GLib.Error))
            throw error;
    }
}

/**
 * Sends one request line on a connection of its own and reads the reply line, closing the connection after the last
 * operation has returned (closing a stream with an operation pending fails).
 *
 * @param {string} socketPath - herdr's socket.
 * @param {string} requestLine - The request, with its newline.
 * @param {Gio.Cancellable} cancellable - Cancels whichever operation is pending.
 * @returns {Promise<string>} The reply line; rejects with a herdr: error (or a cancellation, once cancelled).
 */
async function exchangeOneRequest(socketPath, requestLine, cancellable) {
    const connection = await connectToSocket(socketPath, cancellable);
    try {
        await sendRequestLine(connection, requestLine, cancellable);
        return await readReplyLine(connection, cancellable);
    } finally {
        closeConnection(connection);
    }
}

/**
 * The result of a reply line, checked against herdr's reply shape.
 *
 * @param {string} replyLine - herdr's reply line.
 * @param {string} requestId - The id the request carried.
 * @returns {object} The reply's `result`, exactly as herdr sent it.
 * @throws {Error} `herdr: <message> (<code>)` for a reply carrying an error, or `herdr: malformed reply: <reason>`.
 */
function resultFromReplyLine(replyLine, requestId) {
    let reply;
    try {
        reply = JSON.parse(replyLine);
    } catch (error) {
        if (!(error instanceof SyntaxError))
            throw error;
        throw malformedReplyError('not JSON');
    }
    if (!isJsonObject(reply))
        throw malformedReplyError('not an object');
    if (Object.hasOwn(reply, 'error')) {
        // herdr answers a request it could not read with an empty id: that error is still the answer to this request.
        if (reply.id !== requestId && reply.id !== UNREADABLE_REQUEST_REPLY_ID)
            throw malformedReplyError('not the id of the request');
        const {code, message} = isJsonObject(reply.error) ? reply.error : {};
        if (typeof code !== 'string' || typeof message !== 'string')
            throw malformedReplyError('an error without a string code and message');
        throw new Error(`herdr: ${message} (${code})`);
    }
    if (reply.id === UNREADABLE_REQUEST_REPLY_ID)
        throw malformedReplyError('an empty id on a result');
    if (reply.id !== requestId)
        throw malformedReplyError('not the id of the request');
    if (!Object.hasOwn(reply, 'result'))
        throw malformedReplyError('neither result nor error');
    if (!isJsonObject(reply.result))
        throw malformedReplyError('a result that is not an object');
    return reply.result;
}

/**
 * A client of herdr's API socket. Each request opens its own connection and is bounded by the timeout; close()
 * abandons every request in flight.
 */
export class HerdrSocketClient {
    /**
     * Opens nothing yet: each request connects on its own.
     *
     * @param {object} options - Where herdr is, and how long to wait for it.
     * @param {string} options.socketPath - herdr's socket (herdrSocketPath of the config home).
     * @param {number} [options.timeoutMs] - Milliseconds one request may take, connect to reply.
     */
    constructor({socketPath, timeoutMs = HERDR_REQUEST_TIMEOUT_MS}) {
        this._socketPath = socketPath;
        this._timeoutMs = timeoutMs;
        this._isClosed = false;
        /** @type {Set<{cancellable: Gio.Cancellable, timeoutSourceId: number, reject: (error: Error) => void}>} */
        this._pendingRequests = new Set();
    }

    /**
     * Sends one request and waits for herdr's reply, at most timeoutMs.
     *
     * @param {string} method - The request's kind, as herdr's schema names it: `session.snapshot`,
     *     `pane.process_info`, `pane.focus` and so on.
     * @param {object} [params] - Its parameters; herdr requires the field, so an empty object for a method with none.
     * @returns {Promise<object>} The reply's `result`, exactly as herdr sent it (it carries a `type` naming its kind).
     *     Rejects with an Error whose message starts with 'herdr: ' for a missing socket, a refused connection, a
     *     timeout, a malformed reply, a reply carrying an error, or a client that is closed.
     */
    request(method, params = {}) {
        if (this._isClosed)
            return Promise.reject(new Error(CLOSED_MESSAGE));
        const requestId = `${REQUEST_ID_PREFIX}${nextRequestNumber++}`;
        let requestLine;
        try {
            requestLine = `${JSON.stringify({id: requestId, method, params})}${LINE_TERMINATOR}`;
        } catch (error) {
            return Promise.reject(new Error(`herdr: cannot encode the request: ${describeError(error)}`));
        }
        return new Promise((resolve, reject) => {
            const pendingRequest = {cancellable: new Gio.Cancellable(), timeoutSourceId: 0, reject};
            this._pendingRequests.add(pendingRequest);
            pendingRequest.timeoutSourceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, this._timeoutMs, () => {
                // Cleared first: the source is ending by returning SOURCE_REMOVE, so it must not also be removed.
                pendingRequest.timeoutSourceId = 0;
                this._abandon(pendingRequest, `herdr: timed out after ${this._timeoutMs} ms`);
                return GLib.SOURCE_REMOVE;
            });
            exchangeOneRequest(this._socketPath, requestLine, pendingRequest.cancellable).then(replyLine => {
                if (!this._settle(pendingRequest))
                    return;
                let result;
                try {
                    result = resultFromReplyLine(replyLine, requestId);
                } catch (error) {
                    reject(error);
                    return;
                }
                resolve(result);
            }, error => {
                // A request abandoned by the timeout or close() has already rejected; its cancellation lands here.
                if (this._settle(pendingRequest))
                    reject(error);
            });
        });
    }

    /**
     * Rejects every request in flight with `herdr: closed`, cancelling its IO, and every later request too.
     * Idempotent.
     *
     * @returns {void}
     */
    close() {
        this._isClosed = true;
        for (const pendingRequest of [...this._pendingRequests])
            this._abandon(pendingRequest, CLOSED_MESSAGE);
    }

    /**
     * Marks a request settled, removing its timeout: only the first of its reply, its timeout and close() counts.
     *
     * @param {object} pendingRequest - A request in flight.
     * @returns {boolean} True when this call settled it; false when it was settled already.
     */
    _settle(pendingRequest) {
        if (!this._pendingRequests.delete(pendingRequest))
            return false;
        if (pendingRequest.timeoutSourceId !== 0) {
            GLib.source_remove(pendingRequest.timeoutSourceId);
            pendingRequest.timeoutSourceId = 0;
        }
        return true;
    }

    /**
     * Settles a request in flight as a failure and cancels its IO; the exchange closes the connection once the
     * cancelled operation returns.
     *
     * @param {object} pendingRequest - A request in flight.
     * @param {string} message - The rejection's message.
     * @returns {void}
     */
    _abandon(pendingRequest, message) {
        if (!this._settle(pendingRequest))
            return;
        pendingRequest.cancellable.cancel();
        pendingRequest.reject(new Error(message));
    }
}
