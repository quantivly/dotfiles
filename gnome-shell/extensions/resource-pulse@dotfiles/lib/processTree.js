// The process tree FocusSession reads to name the windows that may show herdr: /proc/<pid>/stat lines read into
// processes, the herdr clients among them, and each client's chain of parents. herdr's API lists no clients, so they
// are found here: a herdr process with a controlling terminal is a client attached in one, while the server, started
// by systemd, has none. A client's terminal emulator is among its parents, so the shell can activate the topmost
// window whose pid is among the candidates. Pure: the cockpit service reads /proc and hands the lines in, so this runs
// under plain gjs. Only the service imports it.
import {FOCUS_WINDOW_PID_CANDIDATES_MAX, PROCESS_ANCESTOR_MAX_DEPTH} from './constants.js';

/** herdr's command name (comm): the server's and every client's alike. */
const HERDR_COMM = 'herdr';
/** The init process: every chain ends there, and it never shows a window. */
const INIT_PID = 1;
/** The tty_nr of a process with no controlling terminal. */
const NO_CONTROLLING_TTY_NR = 0;
/**
 * In /proc/<pid>/stat, the fields after the comm's closing parenthesis start at field 3 (state); ppid is field 4 and
 * tty_nr field 7, so indexes 1 and 4 among them. The comm may hold spaces and parentheses, so the fields are split
 * after the LAST closing parenthesis.
 */
const PPID_INDEX_AFTER_COMM = 1;
const TTY_NR_INDEX_AFTER_COMM = 4;
const STAT_FIELD_SEPARATOR = /\s+/;
const DECIMAL_DIGITS_PATTERN = /^\d+$/;

/**
 * @typedef {object} ProcStat
 * @property {number} pid - The process.
 * @property {string} comm - Its command name, without the parentheses around it.
 * @property {number} ppid - Its parent; 0 for pid 1 and the kernel's threads.
 * @property {number} ttyNr - Its controlling terminal's device number; 0 for none.
 */

/**
 * Reads one /proc/<pid>/stat line.
 *
 * @param {*} text - The file's text.
 * @returns {ProcStat|null} The process; null unless the text is a stat line: a positive pid, a comm in parentheses,
 *     and a whole-number ppid and tty_nr after it.
 */
export function parseProcStat(text) {
    if (typeof text !== 'string')
        return null;
    const commStartIndex = text.indexOf('(');
    const commEndIndex = text.lastIndexOf(')');
    if (commStartIndex < 0 || commEndIndex < commStartIndex)
        return null;
    const pid = wholeNumberOrNull(text.slice(0, commStartIndex).trim());
    const fieldsAfterComm = text.slice(commEndIndex + 1).trim().split(STAT_FIELD_SEPARATOR);
    const ppid = wholeNumberOrNull(fieldsAfterComm[PPID_INDEX_AFTER_COMM]);
    const ttyNr = wholeNumberOrNull(fieldsAfterComm[TTY_NR_INDEX_AFTER_COMM]);
    if (pid === null || pid === 0 || ppid === null || ttyNr === null)
        return null;
    return {pid, comm: text.slice(commStartIndex + 1, commEndIndex), ppid, ttyNr};
}

/**
 * @param {Map<number, ProcStat>} statByPid - Every process read, by pid.
 * @returns {number[]} The pids of herdr's clients: the processes named herdr with a controlling terminal (the server
 *     has none), ascending.
 */
export function herdrClientPids(statByPid) {
    return [...statByPid.values()]
        .filter(processStat => processStat.comm === HERDR_COMM && processStat.ttyNr !== NO_CONTROLLING_TTY_NR)
        .map(processStat => processStat.pid)
        .sort((leftPid, rightPid) => leftPid - rightPid);
}

/**
 * A process and its parents, nearest first.
 *
 * @param {number} pid - The process to start from.
 * @param {Map<number, ProcStat>} statByPid - Every process read, by pid.
 * @param {number} [maxDepth] - The most entries the chain holds, the process itself included.
 * @returns {number[]} The pid, then each parent's, ending at pid 1, before the first pid statByPid has no entry for
 *     (a process that exited before it was read), or after maxDepth entries; empty when the pid itself has none.
 */
export function ancestorChain(pid, statByPid, maxDepth = PROCESS_ANCESTOR_MAX_DEPTH) {
    const chainPids = [];
    let currentPid = pid;
    while (chainPids.length < maxDepth && statByPid.has(currentPid)) {
        chainPids.push(currentPid);
        if (currentPid === INIT_PID)
            break;
        currentPid = statByPid.get(currentPid).ppid;
    }
    return chainPids;
}

/**
 * The pids FocusSession names as the windows that may show herdr: each client's chain (ancestorChain), client by
 * client in ascending pid order, each pid once, pid 1 left out.
 *
 * @param {Map<number, ProcStat>} statByPid - Every process read, by pid.
 * @param {number} [maxCount] - The most pids the list holds; the rest are dropped.
 * @returns {number[]} The candidates, in that order; empty when no herdr client is running in a terminal.
 */
export function focusWindowPidCandidates(statByPid, maxCount = FOCUS_WINDOW_PID_CANDIDATES_MAX) {
    const chainPids = herdrClientPids(statByPid).flatMap(clientPid => ancestorChain(clientPid, statByPid));
    const distinctPids = [...new Set(chainPids)].filter(chainPid => chainPid !== INIT_PID);
    return distinctPids.slice(0, maxCount);
}

/**
 * @param {*} text - One field of a stat line.
 * @returns {number|null} Its value when it is a whole number written in decimal digits alone; null otherwise.
 */
function wholeNumberOrNull(text) {
    if (typeof text !== 'string' || !DECIMAL_DIGITS_PATTERN.test(text))
        return null;
    const value = Number(text);
    return Number.isSafeInteger(value) ? value : null;
}
