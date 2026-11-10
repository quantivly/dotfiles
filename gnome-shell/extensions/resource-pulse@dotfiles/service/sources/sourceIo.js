// The real IO the cockpit's sources default to, in one place: the file reader that refuses the stat-only paths, a
// directory's entry names, a file's modification time, and a read-only proxy on the system bus. Synchronous, as the
// sampler service's reads are (service/fileIo.js): the cockpit service is its own process, never the shell. Every
// source takes these as injectable dependencies, so its rows run with fakes.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {COCKPIT_LOG_PREFIX, STAT_ONLY_PATH_FRAGMENTS} from '../../lib/constants.js';
import {readFileToEnd} from '../fileIo.js';

/** The attribute a directory listing asks for: the name only, never a file's contents. */
const ENTRY_NAME_ATTRIBUTE = 'standard::name';
/** The attributes a modification-time stat asks for: seconds and their microseconds. */
const MODIFICATION_TIME_ATTRIBUTES = 'time::modified,time::modified-usec';

/**
 * Reads a whole file as UTF-8, unless its path contains a STAT_ONLY_PATH_FRAGMENTS entry: such a path is refused
 * before anything opens it. The one file reader every cockpit source defaults to, so the spec's "stat, never open"
 * rule has one enforcement point. It matches the path as given: a symlink elsewhere that points into a stat-only
 * directory is not caught, so it is a guard against a source's own mistakes, not a boundary.
 *
 * @param {string} path - Absolute path.
 * @returns {string} The file's contents.
 * @throws {Error} `cockpit: refused to open <path>` for a stat-only path; a GLib.Error when the file cannot be
 *     opened or read.
 */
export function readFileRefusingSecrets(path) {
    if (STAT_ONLY_PATH_FRAGMENTS.some(fragment => path.includes(fragment)))
        throw new Error(`${COCKPIT_LOG_PREFIX} refused to open ${path}`);
    return readFileToEnd(path);
}

/**
 * Names every entry of a directory, files and directories alike, without opening any of them; closes the listing
 * whatever happens.
 *
 * @param {string} directoryPath - Absolute path.
 * @returns {string[]} The entry names, in listing order.
 * @throws {GLib.Error} When the directory cannot be listed (isNotFoundError is true when it does not exist).
 */
export function listEntryNames(directoryPath) {
    const enumerator = Gio.File.new_for_path(directoryPath)
        .enumerate_children(ENTRY_NAME_ATTRIBUTE, Gio.FileQueryInfoFlags.NONE, null);
    try {
        const entryNames = [];
        for (let fileInfo = enumerator.next_file(null); fileInfo !== null; fileInfo = enumerator.next_file(null))
            entryNames.push(fileInfo.get_name());
        return entryNames;
    } finally {
        // Release the directory's descriptor now, not whenever the garbage collector finalizes the enumerator.
        enumerator.close(null);
    }
}

/**
 * A file's modification time, from a stat: the file is never opened.
 *
 * @param {string} path - Absolute path.
 * @returns {number|null} Microseconds since the epoch; null when the file does not exist or cannot be stat'ed.
 */
export function modificationTimeUsecOrNull(path) {
    let fileInfo;
    try {
        fileInfo = Gio.File.new_for_path(path)
            .query_info(MODIFICATION_TIME_ATTRIBUTES, Gio.FileQueryInfoFlags.NONE, null);
    } catch (error) {
        if (error instanceof GLib.Error)
            return null;
        throw error;
    }
    return fileInfo.get_modification_date_time()?.to_unix_usec() ?? null;
}

/**
 * @param {*} error - A caught value.
 * @returns {boolean} Whether it is Gio's "no such file or directory".
 */
export function isNotFoundError(error) {
    return error instanceof GLib.Error && error.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.NOT_FOUND);
}

/**
 * A proxy on the system bus that never starts its service (DO_NOT_AUTO_START): it reports what the service
 * publishes while the service runs, and no name owner otherwise. Its properties load once and then follow
 * PropertiesChanged, so reading one is a cache read, never a call.
 *
 * @param {object} target - The object to proxy.
 * @param {string} target.busName - The service's well-known name.
 * @param {string} target.objectPath - The object's path.
 * @param {string} target.interfaceName - The interface whose properties are read.
 * @returns {Gio.DBusProxy|null} The proxy; null when the system bus cannot be reached.
 */
export function systemBusProxyOrNull({busName, objectPath, interfaceName}) {
    try {
        return Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SYSTEM, Gio.DBusProxyFlags.DO_NOT_AUTO_START, null,
            busName, objectPath, interfaceName, null);
    } catch (error) {
        if (error instanceof GLib.Error)
            return null;
        throw error;
    }
}
