// The cockpit's Shell glue (cockpitTooltip.js, and the layer and cards that follow) imports the Shell, so plain gjs
// cannot run it. These rows read its source and the stylesheet as text, and pin the constants it draws with.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {COCKPIT_ICON_NAMES, COCKPIT_LONG_IDLE_ROW_OPACITY} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

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
const OPACITY_PROPERTY_PATTERN = /(?:^|[\s{;])opacity\s*:/;
const CSS_COMMENT_PATTERN = /\/\*[\s\S]*?\*\//g;
const JS_COMMENT_PATTERN = /\/\*[\s\S]*?\*\/|\/\/[^\n]*/g;
const COCKPIT_BLOCK_MARKER = 'Added in the cockpit drawing release.';
const LONG_IDLE_OPACITY_FRACTION = 0.55;
const OPAQUE_OPACITY = 255;
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

/**
 * The body of a class method: from its declaration line to the first line that closes it at the declaration's own
 * indent, comments removed so that a comment can never satisfy a needle.
 *
 * @param {string} sourceText - The file's text.
 * @param {string} declarationLine - The declaration as it starts its line, for example 'destroy() {'.
 * @returns {string} The body without comments, or '' when there is no such declaration.
 */
function methodBody(sourceText, declarationLine) {
    const lines = sourceText.split('\n');
    const startIndex = lines.findIndex(line => line.trimStart().startsWith(declarationLine));
    if (startIndex < 0)
        return '';
    const indent = lines[startIndex].length - lines[startIndex].trimStart().length;
    const closingLine = `${' '.repeat(indent)}}`;
    const endIndex = lines.findIndex((line, lineIndex) => lineIndex > startIndex && line === closingLine);
    return lines.slice(startIndex, endIndex < 0 ? undefined : endIndex + 1).join('\n')
        .replace(JS_COMMENT_PATTERN, '');
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
        usesPlacementRule: occurrenceCount(methodBody(source, '_placeLabel() {'), 'tooltipPosition({'),
        styleClassUsedByTheLabel: occurrenceCount(source, 'style_class: TOOLTIP_STYLE_CLASS'),
        styleClassDefined: occurrenceCount(source, "TOOLTIP_STYLE_CLASS = 'rp-cockpit-tooltip'"),
    }, {importsMain: 1, addsToChrome: 1, usesPlacementRule: 1, styleClassUsedByTheLabel: 1, styleClassDefined: 1});
});

test('cockpitTooltip.js: one GLib.timeout_add, named at its use, and removed again in destroy()', () => {
    const source = readExtensionFile(TOOLTIP_SOURCE_FILE);
    const destroyBody = methodBody(source, 'destroy() {');
    assertEqual({
        timeouts: occurrenceCount(source, 'GLib.timeout_add('),
        namedAtItsUse: occurrenceCount(source,
            'GLib.Source.set_name_by_id(this._showTimeoutId, SHOW_TIMEOUT_NAME)'),
        nameDefined: occurrenceCount(source, `SHOW_TIMEOUT_NAME = '${TOOLTIP_TIMEOUT_NAME}'`),
        destroyCancelsIt: destroyBody.includes('this._cancelPendingShow();'),
        destroyRemovesLater: destroyBody.includes('get_laters().remove('),
        destroyDestroysLabel: destroyBody.includes('this._label.destroy();'),
    }, {
        timeouts: 1, namedAtItsUse: 1, nameDefined: 1,
        destroyCancelsIt: true, destroyRemovesLater: true, destroyDestroysLabel: true,
    });
});

test('cockpitTooltip.js: arms its timer with the top bar\'s delay and eases with its fades, not its own numbers', () => {
    const source = readExtensionFile(TOOLTIP_SOURCE_FILE);
    assertEqual({
        delayAtTheTimer: occurrenceCount(source, 'GLib.timeout_add(GLib.PRIORITY_DEFAULT, HOVER_LABEL_DELAY_MS,'),
        fadeIn: occurrenceCount(methodBody(source, '_show() {'), 'duration: HOVER_LABEL_FADE_IN_MS'),
        fadeOut: occurrenceCount(methodBody(source, 'hide() {'), 'duration: HOVER_LABEL_FADE_OUT_MS'),
    }, {delayAtTheTimer: 1, fadeIn: 1, fadeOut: 1});
});

test('cockpitTooltip.js: holds one destroy handler on its anchor, which hides the tooltip', () => {
    const source = readExtensionFile(TOOLTIP_SOURCE_FILE);
    assertEqual({
        connects: occurrenceCount(source, ".connect('destroy'"),
        connectedInSetAnchor: occurrenceCount(methodBody(source, '_setAnchor('), "anchorActor.connect('destroy', () => this.hide())"),
        storesTheHandlerId: methodBody(source, '_setAnchor(').includes('this._anchorDestroyId = anchorActor.connect('),
    }, {connects: 1, connectedInSetAnchor: 1, storesTheHandlerId: true});
});

test('cockpitTooltip.js: releases the anchor\'s destroy handler when the anchor is dropped, replaced or on destroy()', () => {
    const source = readExtensionFile(TOOLTIP_SOURCE_FILE);
    const callsRelease = declaration => occurrenceCount(methodBody(source, declaration), 'this._releaseAnchor();');
    assertEqual({
        disconnects: occurrenceCount(source, '.disconnect('),
        releaseDisconnectsTheStoredId: occurrenceCount(methodBody(source, '_releaseAnchor('),
            'this._anchor.disconnect(this._anchorDestroyId);'),
        hide: callsRelease('hide() {'),
        destroy: callsRelease('destroy() {'),
        replace: callsRelease('_setAnchor('),
    }, {disconnects: 1, releaseDisconnectsTheStoredId: 1, hide: 1, destroy: 1, replace: 1});
});

test('cockpitTooltip.js: showFor() for the anchor it already serves keeps a pending timer and only updates the text', () => {
    const source = readExtensionFile(TOOLTIP_SOURCE_FILE);
    const showForBody = methodBody(source, 'showFor(');
    assertEqual({
        sameAnchorGuard: occurrenceCount(showForBody,
            'anchorActor === this._anchor && (this._isShown || this._showTimeoutId !== null)'),
        cancelsOnlyForAnotherAnchor: showForBody.indexOf('this._cancelPendingShow();') >
            showForBody.indexOf('this._showTimeoutId !== null)'),
    }, {sameAnchorGuard: 1, cancelsOnlyForAnotherAnchor: true});
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

/**
 * The cockpit block's rules (everything after its opening comment), comments removed.
 *
 * @returns {string} The block's text.
 */
function cockpitStylesheetBlockText() {
    const stylesheet = readExtensionFile(STYLESHEET_FILE);
    return stylesheet.slice(stylesheet.indexOf(COCKPIT_BLOCK_MARKER)).replace(CSS_COMMENT_PATTERN, '');
}

test('stylesheet.css: no rule of the cockpit block declares opacity (St reads none; the card sets the actor\'s)', () =>
    assertEqual(OPACITY_PROPERTY_PATTERN.test(cockpitStylesheetBlockText()), false));

test('stylesheet.css: the opacity guard sees a bare opacity but not -rp-graph-opacity', () =>
    assertEqual([' opacity: 140;', '{opacity:140', ' -rp-graph-opacity: 0.4;'].map(text => OPACITY_PROPERTY_PATTERN.test(text)),
        [true, true, false]));

test('COCKPIT_LONG_IDLE_ROW_OPACITY: the design\'s 0.55 of the 0-255 scale', () =>
    assertEqual(COCKPIT_LONG_IDLE_ROW_OPACITY, Math.round(LONG_IDLE_OPACITY_FRACTION * OPAQUE_OPACITY)));
