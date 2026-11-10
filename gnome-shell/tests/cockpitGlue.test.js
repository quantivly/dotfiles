// The cockpit's Shell glue (cockpitTooltip.js, and the layer and cards that follow) imports the Shell, so plain gjs
// cannot run it. These rows read its source and the stylesheet as text, and pin the constants it draws with.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {COCKPIT_ICON_NAMES} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

const EXTENSION_DIRECTORY_URI =
    GLib.uri_resolve_relative(import.meta.url, '../extensions/resource-pulse@dotfiles/', GLib.UriFlags.NONE);
const [EXTENSION_DIRECTORY_PATH] = GLib.filename_from_uri(EXTENSION_DIRECTORY_URI);

const TOOLTIP_SOURCE_FILE = 'cockpitTooltip.js';
const STYLESHEET_FILE = 'stylesheet.css';
const TOOLTIP_TIMEOUT_NAME = '[resource-pulse] show the cockpit tooltip';
const SYMBOLIC_SUFFIX = '-symbolic';
const SESSION_STATES = ['working', 'blocked', 'idle', 'done', 'unknown'];
const CONNECTION_KINDS = ['wired', 'wifi', 'offline', 'vpn', 'ssh', 'mountRemovable', 'mountNetwork'];
const COCKPIT_CLASS_NAMES = [
    'rp-cockpit-layer', 'rp-cockpit-caption', 'rp-cockpit-cell', 'rp-cockpit-row', 'rp-cockpit-row-bar',
    'rp-cockpit-state-working', 'rp-cockpit-state-blocked', 'rp-cockpit-state-idle', 'rp-cockpit-state-done',
    'rp-cockpit-state-unknown', 'rp-cockpit-name-waiting', 'rp-cockpit-row-long-idle', 'rp-cockpit-tooltip',
    'rp-cockpit-no-data',
];
const ROW_HOVER_SELECTOR = '.rp-cockpit-row:hover';
/**
 * The stylesheet as it was before the cockpit block: its character count and SHA-256. The new block is only ever
 * appended, so a change to an earlier rule changes this prefix's hash.
 */
const RELEASE_STYLESHEET_LENGTH = 4281;
const RELEASE_STYLESHEET_SHA256 = '8cac746170c054563123fd54783bb6046881a539ad547a44558a6482da54e84f';

/**
 * Reads a file of the extension as text.
 *
 * @param {string} fileName - Path relative to the extension directory.
 * @returns {string} Its contents.
 */
function readExtensionFile(fileName) {
    const path = GLib.build_filenamev([EXTENSION_DIRECTORY_PATH, fileName]);
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

/**
 * How many times a literal text occurs in another.
 *
 * @param {string} haystack - The text searched.
 * @param {string} needle - The literal looked for.
 * @returns {number} The number of non-overlapping occurrences.
 */
function occurrenceCount(haystack, needle) {
    return haystack.split(needle).length - 1;
}

test('COCKPIT_ICON_NAMES: every session state and every connection kind has a -symbolic icon name', () => {
    const names = [...SESSION_STATES, ...CONNECTION_KINDS].map(key => COCKPIT_ICON_NAMES[key]);
    assertEqual(names.map(name => typeof name === 'string' && name.endsWith(SYMBOLIC_SUFFIX)),
        names.map(() => true));
});

test('COCKPIT_ICON_NAMES: holds no key beyond the session states and connection kinds', () =>
    assertEqual(Object.keys(COCKPIT_ICON_NAMES).sort(), [...SESSION_STATES, ...CONNECTION_KINDS].sort()));

test('cockpitTooltip.js: takes the shell\'s Main, adds its label through addTopChrome and places it with ' +
    'tooltipPosition', () => {
    const source = readExtensionFile(TOOLTIP_SOURCE_FILE);
    assertEqual({
        importsMain: occurrenceCount(source, "import * as Main from 'resource:///org/gnome/shell/ui/main.js';"),
        addsToChrome: occurrenceCount(source, 'Main.layoutManager.addTopChrome('),
        usesPlacementRule: source.includes('tooltipPosition('),
        styleClass: occurrenceCount(source, "'rp-cockpit-tooltip'"),
    }, {importsMain: 1, addsToChrome: 1, usesPlacementRule: true, styleClass: 1});
});

test('cockpitTooltip.js: one GLib.timeout_add, named, and removed again in destroy()', () => {
    const source = readExtensionFile(TOOLTIP_SOURCE_FILE);
    const destroyBody = source.slice(source.indexOf('    destroy() {'));
    assertEqual({
        timeouts: occurrenceCount(source, 'GLib.timeout_add('),
        named: occurrenceCount(source, `'${TOOLTIP_TIMEOUT_NAME}'`),
        destroyCancelsIt: destroyBody.includes('this._cancelPendingShow();'),
        destroyRemovesLater: destroyBody.includes('get_laters().remove('),
        destroyDestroysLabel: destroyBody.includes('this._label.destroy();'),
    }, {timeouts: 1, named: 1, destroyCancelsIt: true, destroyRemovesLater: true, destroyDestroysLabel: true});
});

test('cockpitTooltip.js: reuses the top bar\'s delay and fade constants rather than its own numbers', () => {
    const source = readExtensionFile(TOOLTIP_SOURCE_FILE);
    assertEqual(['HOVER_LABEL_DELAY_MS', 'HOVER_LABEL_FADE_IN_MS', 'HOVER_LABEL_FADE_OUT_MS']
        .map(name => source.includes(name)), [true, true, true]);
});

test('stylesheet.css: every cockpit class is selected, once each as a rule of its own', () => {
    const stylesheet = readExtensionFile(STYLESHEET_FILE);
    const ruleCounts = COCKPIT_CLASS_NAMES.map(className => occurrenceCount(stylesheet, `\n.${className} {`));
    assertEqual({ruleCounts, hasRowHover: occurrenceCount(stylesheet, `\n${ROW_HOVER_SELECTOR} {`)},
        {ruleCounts: COCKPIT_CLASS_NAMES.map(() => 1), hasRowHover: 1});
});

test('stylesheet.css: the rules written before the cockpit block are byte for byte what they were', () => {
    const stylesheet = readExtensionFile(STYLESHEET_FILE);
    const prefix = stylesheet.slice(0, RELEASE_STYLESHEET_LENGTH);
    assertEqual(GLib.compute_checksum_for_string(GLib.ChecksumType.SHA256, prefix, -1), RELEASE_STYLESHEET_SHA256);
});

test('stylesheet.css: the cockpit block opens with a comment naming its release', () => {
    const stylesheet = readExtensionFile(STYLESHEET_FILE);
    assertEqual(stylesheet.slice(RELEASE_STYLESHEET_LENGTH).includes('Added in the cockpit drawing release.'), true);
});
