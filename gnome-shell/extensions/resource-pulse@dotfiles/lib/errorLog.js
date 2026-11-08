// Journal lines for failures, shared by the sampler and the extension: each distinct message at most once per
// ERROR_LOG_REPEAT_INTERVAL_USEC, with the journal prefix. Pure: the clock and the writer are injected, so it runs
// under plain gjs.
import {ERROR_LOG_REPEAT_INTERVAL_USEC, LOG_PREFIX} from './constants.js';

/**
 * Gives an error's message, whatever was thrown.
 *
 * @param {*} error - A rejection reason or caught value.
 * @returns {string} Its message, or its string form.
 */
export function describeError(error) {
    return error?.message ?? String(error);
}

/**
 * Gives an error's message and, when it has one, its stack: for failures that point at a bug, not at IO.
 *
 * @param {*} error - A caught value.
 * @returns {string} The message, then the stack on the following lines.
 */
export function describeErrorWithStack(error) {
    const stackText = error?.stack ? `\n${error.stack}` : '';
    return `${describeError(error)}${stackText}`;
}

/** Writes each distinct message at most once per ERROR_LOG_REPEAT_INTERVAL_USEC, prefixed with LOG_PREFIX. */
export class RateLimitedLogger {
    /**
     * @param {object} options - The clock and the writer.
     * @param {() => number} options.nowUsec - Monotonic microseconds.
     * @param {(line: string) => void} options.write - Where a line goes (the journal, in the shell).
     */
    constructor({nowUsec, write}) {
        this._nowUsec = nowUsec;
        this._write = write;
        this._lastLoggedUsecByMessage = new Map();
    }

    /**
     * Writes a message with the journal prefix, unless the same message was written less than
     * ERROR_LOG_REPEAT_INTERVAL_USEC ago. Entries old enough to write again are forgotten, so the table stays
     * small.
     *
     * @param {string} message - The message, without the prefix.
     * @returns {void}
     */
    log(message) {
        const nowUsec = this._nowUsec();
        const lastLoggedUsec = this._lastLoggedUsecByMessage.get(message);
        if (lastLoggedUsec !== undefined && nowUsec - lastLoggedUsec < ERROR_LOG_REPEAT_INTERVAL_USEC)
            return;
        for (const [loggedMessage, loggedAtUsec] of this._lastLoggedUsecByMessage) {
            if (nowUsec - loggedAtUsec >= ERROR_LOG_REPEAT_INTERVAL_USEC)
                this._lastLoggedUsecByMessage.delete(loggedMessage);
        }
        this._lastLoggedUsecByMessage.set(message, nowUsec);
        this._write(`${LOG_PREFIX} ${message}`);
    }
}
