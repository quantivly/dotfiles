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
//
// The methods the cockpit needs, by their live names: `session.snapshot` (params {}) answers {type:
// 'session_snapshot', snapshot: {agents, workspaces, ...}}, so the data sits under result.snapshot;
// `pane.process_info` (params {pane_id}) answers {type: 'pane_process_info', process_info: {...}}, and a pane that
// does not exist is an error reply with code `pane_not_found`.
//
// Every rejection is an Error whose message starts with 'herdr: ' and whose `code` is one of HERDR_ERROR_CODES, so a
// caller decides by code, never by message text.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {
    HERDR_ERROR_MESSAGE_MAX_CHARS, HERDR_REPLY_MAX_BYTES, HERDR_REQUEST_TIMEOUT_MS, HERDR_SOCKET_RELATIVE_PATH,
} from '../lib/constants.js';
import {describeError} from '../lib/errorLog.js';

/**
 * The `code` of every rejection:
 * - NO_SOCKET: nothing exists at the socket path (herdr is not running).
 * - CONNECT_REFUSED: something exists at the path but no connection was made, or it broke before the request was
 *   sent (a stale socket after a crash, a plain file, a refused connection).
 * - TIMEOUT: no reply within the client's timeoutMs.
 * - MALFORMED: the reply is not herdr's shape (not UTF-8, not JSON, not an object, a wrong id, no result or error, a
 *   result that is not an object), longer than HERDR_REPLY_MAX_BYTES, unreadable, or never came before herdr closed
 *   the connection; also a request whose params cannot be encoded as JSON.
 * - REMOTE_ERROR: herdr answered with an error.
 * - CLOSED: close() was called before the request settled, or before it was made.
 */
export const HERDR_ERROR_CODES = Object.freeze({
    NO_SOCKET: 'no-socket',
    CONNECT_REFUSED: 'connect-refused',
    TIMEOUT: 'timeout',
    MALFORMED: 'malformed',
    REMOTE_ERROR: 'remote-error',
    CLOSED: 'closed',
});

/** Every request id this process sends is this prefix and a number never reused within the process. */
const REQUEST_ID_PREFIX = 'cockpit:';
/** Ends a request line; herdr's reply line ends with it too. */
const LINE_TERMINATOR = '\n';
/** The byte that ends herdr's reply line. */
const NEWLINE_BYTE = 0x0a;
/** Bytes asked of the socket per read while a reply line is read: a live snapshot (about 63 KB) takes one or two. */
const READ_CHUNK_BYTES = 64 * 1024;
/** The id herdr gives the reply to a request it could not read. */
const UNREADABLE_REQUEST_REPLY_ID = '';
/** The rejection message, after the prefix, of every request close() abandons and every later one. */
const CLOSED_DESCRIPTION = 'closed';
/** Appended to herdr's error text when it is cut to HERDR_ERROR_MESSAGE_MAX_CHARS. */
const TRUNCATION_MARK = '…';
/** The first half of a surrogate pair at the end of a string: a character a cut split in two. */
const TRAILING_HIGH_SURROGATE_PATTERN = /[\uD800-\uDBFF]$/;
/** Decodes a reply line, throwing a TypeError on any byte sequence that is not UTF-8. */
const STRICT_UTF8_DECODER = new TextDecoder('utf-8', {fatal: true});

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
 * @param {string} code - One of HERDR_ERROR_CODES.
 * @param {string} description - What failed, after the 'herdr: ' prefix.
 * @returns {Error} A rejection carrying the code.
 */
function herdrError(code, description) {
    const error = new Error(`herdr: ${description}`);
    error.code = code;
    return error;
}

/**
 * @param {string} reason - What was wrong with the reply; never the reply's text, which can carry terminal titles.
 * @returns {Error} The MALFORMED rejection for a reply that is not herdr's shape.
 */
function malformedReplyError(reason) {
    return herdrError(HERDR_ERROR_CODES.MALFORMED, `malformed reply: ${reason}`);
}

/**
 * herdr's error text cut to HERDR_ERROR_MESSAGE_MAX_CHARS (UTF-16 code units), never inside a character, with
 * TRUNCATION_MARK when cut.
 *
 * @param {string} remoteText - herdr's code and message.
 * @returns {string} The text, at most HERDR_ERROR_MESSAGE_MAX_CHARS plus the mark long.
 */
function boundedRemoteText(remoteText) {
    if (remoteText.length <= HERDR_ERROR_MESSAGE_MAX_CHARS)
        return remoteText;
    const keptText = remoteText.slice(0, HERDR_ERROR_MESSAGE_MAX_CHARS).replace(TRAILING_HIGH_SURROGATE_PATTERN, '');
    return `${keptText}${TRUNCATION_MARK}`;
}

/**
 * Connects to a unix socket.
 *
 * @param {string} socketPath - The socket's path.
 * @param {Gio.Cancellable} cancellable - Cancels the connect.
 * @returns {Promise<Gio.SocketConnection>} The connection; rejects NO_SOCKET or CONNECT_REFUSED, naming the path.
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
                    ? herdrError(HERDR_ERROR_CODES.NO_SOCKET, `no socket at ${socketPath}`)
                    : herdrError(HERDR_ERROR_CODES.CONNECT_REFUSED,
                        `cannot connect to ${socketPath}: ${describeError(error)}`));
                return;
            }
            resolve(connection);
        });
    });
}

/**
 * Writes some of a GLib.Bytes: one write, which may take fewer bytes than offered.
 *
 * @param {Gio.OutputStream} outputStream - The connection's output.
 * @param {GLib.Bytes} bytes - What to write.
 * @param {Gio.Cancellable} cancellable - Cancels the write.
 * @returns {Promise<number>} How many bytes were written; rejects CONNECT_REFUSED (the connection broke).
 */
function writeSomeBytes(outputStream, bytes, cancellable) {
    return new Promise((resolve, reject) => {
        outputStream.write_bytes_async(bytes, GLib.PRIORITY_DEFAULT, cancellable, (stream, result) => {
            let writtenByteCount;
            try {
                writtenByteCount = stream.write_bytes_finish(result);
            } catch (error) {
                const sendFailure = `cannot send the request: ${describeError(error)}`;
                reject(herdrError(HERDR_ERROR_CODES.CONNECT_REFUSED, sendFailure));
                return;
            }
            resolve(writtenByteCount);
        });
    });
}

/**
 * Writes the whole request line, in as many writes as it takes.
 *
 * @param {Gio.SocketConnection} connection - The connection to herdr.
 * @param {string} requestLine - The request, with its newline.
 * @param {Gio.Cancellable} cancellable - Cancels the pending write.
 * @returns {Promise<void>} Resolves once every byte is written; rejects CONNECT_REFUSED (the connection broke).
 */
async function sendRequestLine(connection, requestLine, cancellable) {
    // The line goes out of a GLib.Bytes, which owns a copy, and never out of a JS Uint8Array: write_all_async on one
    // can find the array's memory freed or moved by the garbage collector mid-write (measured on gjs 1.88: "Error
    // sending data: Bad address" on an 8 MiB array).
    const requestBytes = new GLib.Bytes(new TextEncoder().encode(requestLine));
    const requestByteCount = requestBytes.get_size();
    const outputStream = connection.get_output_stream();
    let writtenByteCount = 0;
    while (writtenByteCount < requestByteCount) {
        // A slice shares the data rather than copying it.
        const unwrittenBytes = GLib.Bytes.new_from_bytes(requestBytes, writtenByteCount,
            requestByteCount - writtenByteCount);
        writtenByteCount += await writeSomeBytes(outputStream, unwrittenBytes, cancellable);
    }
}

/**
 * Reads up to READ_CHUNK_BYTES, whatever has arrived.
 *
 * @param {Gio.InputStream} inputStream - The connection's input.
 * @param {Gio.Cancellable} cancellable - Cancels the read.
 * @returns {Promise<Uint8Array>} The bytes read, none at the end of the stream; rejects MALFORMED.
 */
function readChunk(inputStream, cancellable) {
    return new Promise((resolve, reject) => {
        inputStream.read_bytes_async(READ_CHUNK_BYTES, GLib.PRIORITY_DEFAULT, cancellable, (stream, result) => {
            let chunkBytes;
            try {
                chunkBytes = stream.read_bytes_finish(result);
            } catch (error) {
                reject(herdrError(HERDR_ERROR_CODES.MALFORMED, `cannot read the reply: ${describeError(error)}`));
                return;
            }
            resolve(chunkBytes.toArray());
        });
    });
}

/**
 * @param {Uint8Array[]} chunks - Consecutive pieces.
 * @param {number} totalByteCount - Their lengths added up.
 * @returns {Uint8Array} The pieces in one array.
 */
function joinChunks(chunks, totalByteCount) {
    const joinedBytes = new Uint8Array(totalByteCount);
    let offset = 0;
    for (const chunk of chunks) {
        joinedBytes.set(chunk, offset);
        offset += chunk.length;
    }
    return joinedBytes;
}

/**
 * @param {Uint8Array} lineBytes - A reply line, without its newline.
 * @returns {string} The line as text.
 * @throws {Error} MALFORMED for bytes that are not UTF-8.
 */
function decodeReplyLine(lineBytes) {
    try {
        return STRICT_UTF8_DECODER.decode(lineBytes);
    } catch (error) {
        if (!(error instanceof TypeError))
            throw error;
        throw malformedReplyError('not UTF-8');
    }
}

/**
 * Reads herdr's one reply line, chunk by chunk, keeping at most HERDR_REPLY_MAX_BYTES of it: a line longer than that
 * rejects as soon as the cap is passed, without waiting for its newline or the end of the stream.
 *
 * @param {Gio.SocketConnection} connection - The connection to herdr.
 * @param {Gio.Cancellable} cancellable - Cancels the pending read.
 * @returns {Promise<string>} The reply line without its newline (or everything before the end of the stream, if
 *     herdr closed without one); rejects MALFORMED, also when herdr closes the connection before sending anything.
 */
async function readReplyLine(connection, cancellable) {
    const inputStream = connection.get_input_stream();
    const lineChunks = [];
    let lineByteCount = 0;
    let hasLineEnded = false;
    while (!hasLineEnded) {
        const chunk = await readChunk(inputStream, cancellable);
        if (chunk.length === 0)
            break;
        const newlineIndex = chunk.indexOf(NEWLINE_BYTE);
        hasLineEnded = newlineIndex !== -1;
        // Anything after the newline is not part of the reply (herdr sends nothing more).
        const lineChunk = hasLineEnded ? chunk.subarray(0, newlineIndex) : chunk;
        lineByteCount += lineChunk.length;
        if (lineByteCount > HERDR_REPLY_MAX_BYTES)
            throw herdrError(HERDR_ERROR_CODES.MALFORMED, 'reply too large');
        lineChunks.push(lineChunk);
    }
    if (!hasLineEnded && lineByteCount === 0)
        throw herdrError(HERDR_ERROR_CODES.MALFORMED, 'connection closed before a reply');
    return decodeReplyLine(joinChunks(lineChunks, lineByteCount));
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
 * @returns {Promise<string>} The reply line; rejects with a coded herdr: error.
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
 * @throws {Error} REMOTE_ERROR `herdr: <code>: <message>` (cut to HERDR_ERROR_MESSAGE_MAX_CHARS) for a reply carrying
 *     an error, or MALFORMED `herdr: malformed reply: <reason>`.
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
        throw herdrError(HERDR_ERROR_CODES.REMOTE_ERROR, boundedRemoteText(`${code}: ${message}`));
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
     *     Rejects with an Error whose message starts with 'herdr: ' and whose `code` is one of HERDR_ERROR_CODES.
     */
    request(method, params = {}) {
        if (this._isClosed)
            return Promise.reject(herdrError(HERDR_ERROR_CODES.CLOSED, CLOSED_DESCRIPTION));
        const requestId = `${REQUEST_ID_PREFIX}${nextRequestNumber++}`;
        let requestLine;
        try {
            requestLine = `${JSON.stringify({id: requestId, method, params})}${LINE_TERMINATOR}`;
        } catch (error) {
            return Promise.reject(herdrError(HERDR_ERROR_CODES.MALFORMED,
                `cannot encode the request: ${describeError(error)}`));
        }
        return new Promise((resolve, reject) => {
            const pendingRequest = {cancellable: new Gio.Cancellable(), timeoutSourceId: 0, reject};
            this._pendingRequests.add(pendingRequest);
            pendingRequest.timeoutSourceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, this._timeoutMs, () => {
                // Cleared first: the source is ending by returning SOURCE_REMOVE, so it must not also be removed.
                pendingRequest.timeoutSourceId = 0;
                this._abandon(pendingRequest,
                    herdrError(HERDR_ERROR_CODES.TIMEOUT, `timed out after ${this._timeoutMs} ms`));
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
     * Rejects every request in flight as CLOSED, cancelling its IO, and every later request too. Idempotent.
     *
     * @returns {void}
     */
    close() {
        this._isClosed = true;
        for (const pendingRequest of [...this._pendingRequests])
            this._abandon(pendingRequest, herdrError(HERDR_ERROR_CODES.CLOSED, CLOSED_DESCRIPTION));
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
     * @param {Error} error - The rejection, carrying its code.
     * @returns {void}
     */
    _abandon(pendingRequest, error) {
        if (!this._settle(pendingRequest))
            return;
        pendingRequest.cancellable.cancel();
        pendingRequest.reject(error);
    }
}
