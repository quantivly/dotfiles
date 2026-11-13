// Compares the constants of the compiled sampler (resource-pulse-sampler --print-constants) with the gjs ones in
// lib/constants.js and lib/protocol.js. Run by scripts/test-resource-pulse-sampler.sh, which gives the program's path:
//   gjs -m gnome-shell/tests/sampler-constants.js <path to resource-pulse-sampler>
// It prints one `CONSTANT-ROW <pass|fail> <NAME> <detail>` line per name, from either side, and a final
// `CONSTANT-TALLY names=<n>` line; an exit other than 0 and 1 means it could not run.
import Gio from 'gi://Gio';
import * as constants from '../extensions/resource-pulse@dotfiles/lib/constants.js';
import * as protocol from '../extensions/resource-pulse@dotfiles/lib/protocol.js';

const COULD_NOT_RUN_EXIT_CODE = 2;
const FAILED_EXIT_CODE = 1;
const PRINT_CONSTANTS_FLAG = '--print-constants';

// Every name the Rust side must print, with the JavaScript value it must equal.
const JAVASCRIPT_CONSTANTS = {
    SAMPLE_INTERVAL_SECONDS: constants.SAMPLE_INTERVAL_SECONDS,
    APP_SCAN_INTERVAL_SECONDS: constants.APP_SCAN_INTERVAL_SECONDS,
    APP_SCAN_UNWATCHED_INTERVAL_SECONDS: constants.APP_SCAN_UNWATCHED_INTERVAL_SECONDS,
    BURST_CPU_RISE_POINTS: constants.BURST_CPU_RISE_POINTS,
    BURST_COOLDOWN_TICKS: constants.BURST_COOLDOWN_TICKS,
    REVEAL_SCAN_COOLDOWN_TICKS: constants.REVEAL_SCAN_COOLDOWN_TICKS,
    MIN_CPU_RANKING_WINDOW_SECONDS: constants.MIN_CPU_RANKING_WINDOW_SECONDS,
    APP_SCAN_SKIPPED_UNIT_SUFFIXES: constants.APP_SCAN_SKIPPED_UNIT_SUFFIXES,
    APP_MEMORY_STAT_MIN_BYTES: constants.APP_MEMORY_STAT_MIN_BYTES,
    CARD_HISTORY_SAMPLES: constants.CARD_HISTORY_SAMPLES,
    PRESSURE_BAND_THRESHOLDS_PERCENT: constants.PRESSURE_BAND_THRESHOLDS_PERCENT,
    PERFORMANCE_CAPACITY_RATIO: constants.PERFORMANCE_CAPACITY_RATIO,
    ERROR_LOG_REPEAT_INTERVAL_USEC: constants.ERROR_LOG_REPEAT_INTERVAL_USEC,
    LOG_PREFIX: constants.LOG_PREFIX,
    KERNEL_LABEL: constants.KERNEL_LABEL,
    SHORT_JOBS_LABEL: constants.SHORT_JOBS_LABEL,
    // A map is a list of [key, value] pairs in key order on the Rust side.
    UNIT_DISPLAY_ALIASES: Object.entries(constants.UNIT_DISPLAY_ALIASES),
    APP_RANKING_LENGTH: constants.APP_RANKING_LENGTH,
    PROTOCOL_VERSION: protocol.PROTOCOL_VERSION,
    RESOURCE_PULSE_BUS_NAME: protocol.RESOURCE_PULSE_BUS_NAME,
    RESOURCE_PULSE_INTERFACE_NAME: protocol.RESOURCE_PULSE_INTERFACE_NAME,
    RESOURCE_PULSE_OBJECT_PATH: protocol.RESOURCE_PULSE_OBJECT_PATH,
    GET_STATE_METHOD_NAME: protocol.GET_STATE_METHOD_NAME,
    WATCH_DETAIL_METHOD_NAME: protocol.WATCH_DETAIL_METHOD_NAME,
    UNWATCH_DETAIL_METHOD_NAME: protocol.UNWATCH_DETAIL_METHOD_NAME,
    SAMPLE_SIGNAL_NAME: protocol.SAMPLE_SIGNAL_NAME,
};

/**
 * Renders a JavaScript constant as the program prints it: a string as it is, a list or a map as compact JSON, any
 * other scalar through String().
 *
 * @param {*} value - A constant of lib/constants.js or lib/protocol.js.
 * @returns {string} The text the program must print after the `=`.
 */
function renderAsProgramPrints(value) {
    if (typeof value === 'string')
        return value;
    if (typeof value === 'object' && value !== null)
        return JSON.stringify(value);
    return String(value);
}

/**
 * Runs the program with --print-constants and parses its NAME=value lines.
 *
 * @param {string} programPath - Path of the compiled sampler.
 * @returns {Map<string, string>} Printed value by name; a name printed twice keeps the later value.
 */
function readProgramConstants(programPath) {
    const process = new Gio.Subprocess({
        argv: [programPath, PRINT_CONSTANTS_FLAG],
        flags: Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE,
    });
    process.init(null);
    const [, standardOutput] = process.communicate_utf8(null, null);
    if (process.get_exit_status() !== 0)
        throw new Error(`${programPath} ${PRINT_CONSTANTS_FLAG} exited ${process.get_exit_status()}`);
    const printed = new Map();
    for (const line of standardOutput.split('\n')) {
        if (line === '')
            continue;
        const separatorIndex = line.indexOf('=');
        if (separatorIndex < 1)
            throw new Error(`not a NAME=value line: ${line}`);
        printed.set(line.slice(0, separatorIndex), line.slice(separatorIndex + 1));
    }
    return printed;
}

/**
 * Prints one row.
 *
 * @param {boolean} passed - Whether the name agrees on both sides.
 * @param {string} name - The constant's name.
 * @param {string} detail - What differs, or what agrees.
 * @returns {void}
 */
function printRow(passed, name, detail) {
    print(`CONSTANT-ROW ${passed ? 'pass' : 'fail'} ${name} ${detail}`);
}

/**
 * Compares every name from either side and prints a row for each.
 *
 * @param {string} programPath - Path of the compiled sampler.
 * @returns {boolean} True when every name agrees.
 */
function compareAll(programPath) {
    const printed = readProgramConstants(programPath);
    let everyNameAgrees = true;
    const names = new Set([...Object.keys(JAVASCRIPT_CONSTANTS), ...printed.keys()]);
    for (const name of names) {
        const inJavaScript = Object.hasOwn(JAVASCRIPT_CONSTANTS, name);
        const inProgram = printed.has(name);
        let passed = false;
        let detail;
        if (!inJavaScript)
            detail = 'the program prints it and the comparison does not list it';
        else if (!inProgram)
            detail = 'the program does not print it';
        else {
            const javascriptText = renderAsProgramPrints(JAVASCRIPT_CONSTANTS[name]);
            const programText = printed.get(name);
            passed = javascriptText === programText;
            detail = passed ? javascriptText : `javascript ${javascriptText} but program ${programText}`;
        }
        printRow(passed, name, detail);
        everyNameAgrees &&= passed;
    }
    print(`CONSTANT-TALLY names=${names.size}`);
    return everyNameAgrees;
}

const programPath = ARGV[0];
if (!programPath) {
    printerr('usage: gjs -m sampler-constants.js <path to resource-pulse-sampler>');
    imports.system.exit(COULD_NOT_RUN_EXIT_CODE);
}
let agrees;
try {
    agrees = compareAll(programPath);
} catch (error) {
    printerr(`cannot compare constants: ${error.message}`);
    imports.system.exit(COULD_NOT_RUN_EXIT_CODE);
}
imports.system.exit(agrees ? 0 : FAILED_EXIT_CODE);
