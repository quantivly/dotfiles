// Prints what GLib's DesktopAppInfo answers for each desktop id in a list: the reference the compiled sampler's own
// `.desktop` lookup (resource-pulse-sampler/src/desktop_names.rs) is held to. Run by scripts/test-resource-pulse-sampler.sh:
//   gjs -m gnome-shell/tests/desktop-names-reference.js <file of desktop ids, one per line>
// One line per id, in the file's order: `<id>\t<name as a JSON string>` for an app GLib finds and `<id>` alone for a
// miss. A name is quoted so that the empty name, or one with a blank at its end, is still a line with a tab and a
// quote in it, and a miss cannot be mistaken for one.
//
// The expected name files it is compared with (resource-pulse-sampler/tests/fixtures/desktop/expected-*.tsv) are
// GLib 2.88's answers. One of them is new in 2.88: GLib refuses a file whose `Path`, `TryExec` or `Exec` is a bad value
// (a bad escape), where 2.80 to 2.86 load such a file and name it, so on those the rows for those files differ. The
// script prints the GLib version it ran on to stderr first, so a row that differs after a change of runner image reads
// as what it is.
//
// What GLib reads is fixed by the environment the caller sets: XDG_DATA_HOME and XDG_DATA_DIRS (which directories),
// HOME, PATH (for TryExec and Exec), and LANGUAGE, LC_ALL, LC_MESSAGES and LANG (which language's Name). This script
// sets nothing and opens no bus connection. It reads the directories those variables name, and GLib itself also reads
// the system `mimeapps.list` files when it starts. An exit other than 0 means it could not run, among them a GLib
// without GioUnix.DesktopAppInfo (the class's home since 2.86): it says so, with the version it found.
import GLib from 'gi://GLib';
import {exit, programArgs} from 'system';

const COULD_NOT_RUN_EXIT_CODE = 2;
const EXPECTED_ARGUMENT_COUNT = 1;
const IDS_FILE_ENCODING = new TextDecoder('utf-8', {fatal: true});

/**
 * The GLib version this script runs on, as `major.minor.micro`.
 *
 * @returns {string} The version text.
 */
function glibVersionText() {
    return `${GLib.MAJOR_VERSION}.${GLib.MINOR_VERSION}.${GLib.MICRO_VERSION}`;
}

/**
 * Loads the class that reads `.desktop` files, `GioUnix.DesktopAppInfo`.
 *
 * @returns {Promise<Function>} The DesktopAppInfo class, whose static `new(id)` is `g_desktop_app_info_new`.
 * @throws {Error} When this GLib has no GioUnix.DesktopAppInfo; the message names the version.
 */
async function loadDesktopAppInfoClass() {
    let GioUnix = null;
    try {
        ({default: GioUnix} = await import('gi://GioUnix'));
    } catch (importError) {
        if (!(importError instanceof Error) || !/GioUnix/.test(importError.message))
            throw importError;
    }
    if (!GioUnix?.DesktopAppInfo)
        throw new Error(`GioUnix.DesktopAppInfo is missing on GLib ${glibVersionText()}, so there is no reference`);
    return GioUnix.DesktopAppInfo;
}

/**
 * Reads the list of ids to look up.
 *
 * @param {string} idsFilePath - A text file with one desktop id per line.
 * @returns {string[]} The ids, in the file's order, without the empty line at the end.
 */
function readIds(idsFilePath) {
    const [, contents] = GLib.file_get_contents(idsFilePath);
    return IDS_FILE_ENCODING.decode(contents).split('\n').filter(line => line !== '');
}

/**
 * The line the reference prints for one id.
 *
 * @param {Function} DesktopAppInfo - The class loaded by loadDesktopAppInfoClass.
 * @param {string} desktopId - A desktop file id.
 * @returns {string} `<id>\t<name as JSON>` for an app, `<id>` for a miss.
 */
function lineFor(DesktopAppInfo, desktopId) {
    const appInfo = DesktopAppInfo.new(desktopId);
    if (appInfo === null)
        return desktopId;
    return `${desktopId}\t${JSON.stringify(appInfo.get_name())}`;
}

/**
 * Prints the reference's answer for every id in the file named on the command line.
 *
 * @returns {Promise<void>}
 */
async function main() {
    if (programArgs.length !== EXPECTED_ARGUMENT_COUNT) {
        printerr('usage: gjs -m desktop-names-reference.js <file of desktop ids>');
        exit(COULD_NOT_RUN_EXIT_CODE);
    }
    printerr(`desktop-names-reference: GLib ${glibVersionText()}`);
    const DesktopAppInfo = await loadDesktopAppInfoClass();
    for (const desktopId of readIds(programArgs[0]))
        print(lineFor(DesktopAppInfo, desktopId));
}

main().catch(error => {
    printerr(`desktop-names-reference: ${error}`);
    exit(COULD_NOT_RUN_EXIT_CODE);
});
