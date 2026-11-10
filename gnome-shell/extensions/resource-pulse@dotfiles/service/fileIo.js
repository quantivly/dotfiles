// Synchronous file reads and directory listing, shared by the sampler (service/sampler.js) and the cockpit's sources
// (service/sources/sourceIo.js), so the cockpit service loads these two functions without the sampler's closure.
// Synchronous on purpose: each service is its own process, never the shell.
import Gio from 'gi://Gio';

const NAME_AND_TYPE_ATTRIBUTES = 'standard::name,standard::type';
const UTF8_DECODER = new TextDecoder();

/**
 * Reads a whole file synchronously as UTF-8. Gio.File.load_contents reads until EOF, so the size kernfs reports for a
 * /proc, /sys or cgroup file (0, or a whole page) is never trusted.
 *
 * @param {string} path - Absolute path.
 * @returns {string} The contents.
 * @throws {GLib.Error} When the file cannot be opened or read (G_IO_ERROR_NOT_FOUND when it does not exist).
 */
export function readFileToEnd(path) {
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return UTF8_DECODER.decode(contentBytes);
}

/**
 * Names the subdirectories of a directory, closing the listing whatever happens.
 *
 * @param {string} directoryPath - Absolute path.
 * @returns {string[]} The names of the entries that are directories, in listing order; files are left out.
 * @throws {GLib.Error} When the directory cannot be listed (G_IO_ERROR_NOT_FOUND when it does not exist).
 */
export function listSubdirectoryNames(directoryPath) {
    const enumerator = Gio.File.new_for_path(directoryPath)
        .enumerate_children(NAME_AND_TYPE_ATTRIBUTES, Gio.FileQueryInfoFlags.NONE, null);
    try {
        const subdirectoryNames = [];
        for (let fileInfo = enumerator.next_file(null); fileInfo !== null; fileInfo = enumerator.next_file(null)) {
            if (fileInfo.get_file_type() === Gio.FileType.DIRECTORY)
                subdirectoryNames.push(fileInfo.get_name());
        }
        return subdirectoryNames;
    } finally {
        // Release the directory's descriptor now, not whenever the garbage collector finalizes the enumerator.
        enumerator.close(null);
    }
}
