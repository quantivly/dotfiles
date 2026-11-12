// Journal lines for failures, shared by the services and the extension: each message at most once per
// ERROR_LOG_REPEAT_INTERVAL_USEC for its template key (its own text unless a caller names one), with the journal
// prefix (LOG_PREFIX unless a caller names another). Pure: the clock and the writer are injected, so it runs under
// plain gjs. Also runLoggingFailure, a step run under its own guard whose failure is such a line.
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

/**
 * Writes each message at most once per ERROR_LOG_REPEAT_INTERVAL_USEC for its template key, prefixed with the
 * logger's prefix. The key defaults to the message itself, so a caller that names none is limited per distinct text.
 */
export class RateLimitedLogger {
    /**
     * @param {object} options - The clock, the writer and the prefix.
     * @param {() => number} options.nowUsec - Monotonic microseconds.
     * @param {(line: string) => void} options.write - Where a line goes (the journal, in the shell).
     * @param {string} [options.prefix] - What every line starts with: LOG_PREFIX unless the caller names another
     *     (the cockpit service passes COCKPIT_LOG_PREFIX).
     */
    constructor({nowUsec, write, prefix = LOG_PREFIX}) {
        this._nowUsec = nowUsec;
        this._write = write;
        this._prefix = prefix;
        this._lastLoggedUsecByTemplateKey = new Map();
    }

    /**
     * Writes a message with the logger's prefix, unless a message with the same template key was written less than
     * ERROR_LOG_REPEAT_INTERVAL_USEC ago. Entries old enough to write again are forgotten, so the table stays
     * small.
     *
     * @param {string} message - The message, without the prefix.
     * @param {string} [templateKey] - What the limit is kept by: a stable name for a message whose text varies (a
     *     count, a path, an error), so that every variant shares one limit. Defaults to the message itself.
     * @returns {void}
     */
    log(message, templateKey = message) {
        const nowUsec = this._nowUsec();
        const lastLoggedUsec = this._lastLoggedUsecByTemplateKey.get(templateKey);
        if (lastLoggedUsec !== undefined && nowUsec - lastLoggedUsec < ERROR_LOG_REPEAT_INTERVAL_USEC)
            return;
        for (const [loggedTemplateKey, loggedAtUsec] of this._lastLoggedUsecByTemplateKey) {
            if (nowUsec - loggedAtUsec >= ERROR_LOG_REPEAT_INTERVAL_USEC)
                this._lastLoggedUsecByTemplateKey.delete(loggedTemplateKey);
        }
        this._lastLoggedUsecByTemplateKey.set(templateKey, nowUsec);
        this._write(`${this._prefix} ${message}`);
    }
}

/**
 * Runs one step under its own guard, for a caller that runs several in a row (the cockpit layer, one per card): a step
 * that throws is logged on a rate-limited logger with its error and stack, under its context, which is also the line's
 * template key, so one step failing again with another error text is still written once per interval; nothing is
 * thrown, so the steps after it still run.
 *
 * @param {object} options - The step and where its failure goes.
 * @param {function(): void} options.run - The step.
 * @param {RateLimitedLogger} options.errorLog - The logger.
 * @param {string} options.context - What failed, without the error: the line's start and its template key.
 * @returns {boolean} True when the step ran to its end, false when it threw.
 */
export function runLoggingFailure({run, errorLog, context}) {
    try {
        run();
    } catch (error) {
        const errorText = describeErrorWithStack(error);
        errorLog.log(`${context}: ${errorText}`, context);
        return false;
    }
    return true;
}
