// The cockpit's Shell glue (cockpitTooltip.js, cockpitCards.js, and the layer that follows) imports the Shell, so
// plain gjs cannot run it. These rows read its source and the stylesheet as text, and pin the constants it draws with.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {CockpitClient} from '../extensions/resource-pulse@dotfiles/cockpitClient.js';
import {
    COCKPIT_ICON_NAMES, COCKPIT_LONG_IDLE_ROW_OPACITY, COCKPIT_ROW_ICON_SIZE_PX, ERROR_LOG_REPEAT_INTERVAL_USEC,
} from '../extensions/resource-pulse@dotfiles/lib/constants.js';
import {
    COCKPIT_FOCUS_SESSION_METHOD_NAME, COCKPIT_GET_STATE_METHOD_NAME, COCKPIT_UNWATCH_METHOD_NAME,
    COCKPIT_WATCH_METHOD_NAME,
} from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';

const EXTENSION_DIRECTORY_URI =
    GLib.uri_resolve_relative(import.meta.url, '../extensions/resource-pulse@dotfiles/', GLib.UriFlags.NONE);
const [EXTENSION_DIRECTORY_PATH] = GLib.filename_from_uri(EXTENSION_DIRECTORY_URI);

const TOOLTIP_SOURCE_FILE = 'cockpitTooltip.js';
const STYLESHEET_FILE = 'stylesheet.css';
const TOOLTIP_TIMEOUT_NAME = '[resource-pulse] show the cockpit tooltip';
/** The tooltip's raise in _show(): its label on top of its parent (the top chrome's uiGroup), above an open menu. */
const TOOLTIP_RAISE_STATEMENT = 'label.get_parent()?.set_child_above_sibling(label, null);';
const SYMBOLIC_SUFFIX = '-symbolic';
const SESSION_STATES = ['working', 'blocked', 'idle', 'done', 'unknown'];
const CONNECTION_KINDS = ['wired', 'wifi', 'offline', 'online', 'vpn', 'ssh', 'mountRemovable', 'mountNetwork'];
const COCKPIT_CLASS_NAMES = [
    'rp-cockpit-layer', 'rp-cockpit-caption', 'rp-cockpit-cell', 'rp-cockpit-row', 'rp-cockpit-row-bar',
    'rp-cockpit-state-working', 'rp-cockpit-state-blocked', 'rp-cockpit-state-idle', 'rp-cockpit-state-done',
    'rp-cockpit-state-unknown', 'rp-cockpit-name-waiting', 'rp-cockpit-row-long-idle', 'rp-cockpit-tooltip',
    'rp-cockpit-no-data', 'rp-cockpit-menu-sessions-item',
];
const OPACITY_PROPERTY_PATTERN = /(?:^|[\s{;])opacity\s*:/;
const TEXT_TRANSFORM_PROPERTY_PATTERN = /(?:^|[\s{;])text-transform\s*:/;
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
const CARDS_SOURCE_FILE = 'cockpitCards.js';
const PULSE_CARD_SOURCE_FILE = 'card.js';
const INDICATOR_SOURCE_FILE = 'indicator.js';
/** The four cards of stage one, each a CockpitCardBase. */
const CARD_CLASS_NAMES = ['SystemCockpitCard', 'AppsCockpitCard', 'ConnectionsCockpitCard', 'SessionsCockpitCard'];
/** The three cards that draw rows of their own (the system card wraps the v2 card). */
const DATA_CARD_CLASS_NAMES = ['AppsCockpitCard', 'ConnectionsCockpitCard', 'SessionsCockpitCard'];
/** The line that closes a class's GObject.registerClass( call. */
const CLASS_CLOSING_LINE = '});';
/** The row icon size the brief fixes. */
const ROW_ICON_SIZE_PX = 16;
/** A quoted string of this extension's style classes, one or several, as the cards name them. */
const QUOTED_STYLE_CLASSES_PATTERN = /'((?:rp-cockpit|resource-pulse)-[\w -]*)'/g;
/** A static import statement, its clause possibly over several lines, and its specifier. */
const IMPORT_STATEMENT_PATTERN = /^import\s[^;]*?from\s+'([^']+)';/gm;
/** A static import of named bindings: its clause's names (possibly over several lines), and its specifier. */
const NAMED_IMPORT_STATEMENT_PATTERN = /^import\s*\{([^}]*)\}\s*from\s+'([^']+)';/gm;
const IMPORT_NAME_SEPARATOR = ',';
const RELATIVE_SPECIFIER_PREFIX = './';
const CARDS_IMPORT_SPECIFIER = './cockpitCards.js';
/** The Resources helpers cockpitCards.js holds once (ruling D10). */
const RESOURCES_HELPER_NAMES = ['findResourcesApp', 'openResourcesApp'];
/** The apps card's divider, between its CPU rows and its memory rows: the faint row bar's line, across the card. */
const APPS_DIVIDER_STATEMENT = 'rowsBox.add_child(new St.Widget({style_class: ROW_BAR_STYLE_CLASS, x_expand: true}));';

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

/**
 * A file of the extension with its comments removed, so that no needle can match a comment. A string holding `//`
 * (an import URL) loses its tail too; no row reads one from this text.
 *
 * @param {string} fileName - Path relative to the extension directory.
 * @returns {string} Its code.
 */
function codeOf(fileName) {
    return readExtensionFile(fileName).replace(JS_COMMENT_PATTERN, '');
}

/**
 * One class of a file that holds several: from its declaration line to the line that closes its
 * GObject.registerClass( call, so that a method several classes define is read from the right one.
 *
 * @param {string} sourceText - The file's text.
 * @param {string} className - The class's name.
 * @returns {string} The class's text, or '' when there is no such class.
 */
function classBody(sourceText, className) {
    const lines = sourceText.split('\n');
    const startIndex = lines.findIndex(line => line.startsWith(`class ${className} extends `));
    if (startIndex < 0)
        return '';
    const endIndex = lines.findIndex((line, lineIndex) => lineIndex > startIndex && line === CLASS_CLOSING_LINE);
    return lines.slice(startIndex, endIndex < 0 ? undefined : endIndex + 1).join('\n');
}

/**
 * The names a file imports from one module by its named-import statements, whatever else each statement names.
 *
 * @param {string} sourceText - The file's text.
 * @param {string} specifier - The module, as the statement names it, for example './cockpitCards.js'.
 * @returns {string[]} The imported names, in order; none when no named import has that specifier.
 */
function importedNames(sourceText, specifier) {
    return [...sourceText.matchAll(NAMED_IMPORT_STATEMENT_PATTERN)]
        .filter(([, , statementSpecifier]) => statementSpecifier === specifier)
        .flatMap(([, importClause]) => importClause.split(IMPORT_NAME_SEPARATOR))
        .map(importedName => importedName.trim())
        .filter(importedName => importedName !== '');
}

/**
 * The statements of a body, one per line, trimmed, blank lines left out.
 *
 * @param {string} bodyText - What methodBody returned.
 * @returns {string[]} Its lines.
 */
function statementsOf(bodyText) {
    return bodyText.split('\n').map(line => line.trim()).filter(line => line !== '');
}

/**
 * The body of one method of one class of cockpitCards.js, comments removed.
 *
 * @param {string} className - The class.
 * @param {string} declarationLine - The method's declaration as it starts its line.
 * @returns {string} The body, or ''.
 */
function cardMethodBody(className, declarationLine) {
    return methodBody(classBody(readExtensionFile(CARDS_SOURCE_FILE), className), declarationLine);
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
        ellipsizedAtItsEnd: occurrenceCount(methodBody(source, 'constructor() {'),
            'this._label.clutter_text.ellipsize = Pango.EllipsizeMode.END;'),
    }, {
        importsMain: 1, addsToChrome: 1, usesPlacementRule: 1, styleClassUsedByTheLabel: 1, styleClassDefined: 1,
        ellipsizedAtItsEnd: 1,
    });
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

test('cockpitTooltip.js: _show() raises its label above its siblings before it shows it, so a menu opened since (GNOME ' +
    'Shell raises the menu on every open) cannot cover it', () => {
    const showStatements = statementsOf(methodBody(readExtensionFile(TOOLTIP_SOURCE_FILE), '_show() {'));
    const raiseIndex = showStatements.indexOf(TOOLTIP_RAISE_STATEMENT);
    assertEqual({
        raises: showStatements.filter(statement => statement === TOOLTIP_RAISE_STATEMENT).length,
        raisedBeforeShown: raiseIndex >= 0 && raiseIndex < showStatements.indexOf('label.show();'),
    }, {raises: 1, raisedBeforeShown: true});
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
        takesTheAnchorThroughTheHandler: occurrenceCount(showForBody, 'this._setAnchor(anchorActor);'),
    }, {sameAnchorGuard: 1, cancelsOnlyForAnotherAnchor: true, takesTheAnchorThroughTheHandler: 1});
});

test('cockpitTooltip.js: only _setAnchor() and _releaseAnchor() assign the anchor (and the constructor, to null)', () => {
    const source = readExtensionFile(TOOLTIP_SOURCE_FILE).replace(JS_COMMENT_PATTERN, '');
    const anchorAssignment = 'this._anchor = ';
    assertEqual({
        inTheWholeFile: occurrenceCount(source, anchorAssignment),
        inSetAnchor: occurrenceCount(methodBody(source, '_setAnchor('), anchorAssignment),
        inReleaseAnchor: occurrenceCount(methodBody(source, '_releaseAnchor('), anchorAssignment),
        constructorInitialisesToNull: occurrenceCount(methodBody(source, 'constructor('), 'this._anchor = null;'),
    }, {inTheWholeFile: 3, inSetAnchor: 1, inReleaseAnchor: 1, constructorInitialisesToNull: 1});
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

test('stylesheet.css: no rule of the cockpit block declares text-transform (St reads none; the layer upper-cases ' +
    'the caption in code), and the guard sees one', () =>
    assertEqual({
        inTheBlock: TEXT_TRANSFORM_PROPERTY_PATTERN.test(cockpitStylesheetBlockText()),
        guardSeesOne: [' text-transform: uppercase;', '{text-transform:none'].map(text =>
            TEXT_TRANSFORM_PROPERTY_PATTERN.test(text)),
    }, {inTheBlock: false, guardSeesOne: [true, true]}));

test('stylesheet.css: the tooltip is at most 40em wide (St reads max-width), so its label\'s ellipsize cuts a long ' +
    'line (a mount point, a group key) rather than drawing it across the monitor\'s edge', () => {
    const block = cockpitStylesheetBlockText();
    const tooltipRule = block.split('.rp-cockpit-tooltip {')[1]?.split('}')[0] ?? '';
    const maxWidthDeclarations = statementsOf(tooltipRule).filter(declaration => declaration.startsWith('max-width'));
    assertEqual(maxWidthDeclarations, ['max-width: 40em;']);
});

test('stylesheet.css: the opacity guard sees a bare opacity but not -rp-graph-opacity', () =>
    assertEqual([' opacity: 140;', '{opacity:140', ' -rp-graph-opacity: 0.4;'].map(text => OPACITY_PROPERTY_PATTERN.test(text)),
        [true, true, false]));

test('COCKPIT_LONG_IDLE_ROW_OPACITY: the design\'s 0.55 of the 0-255 scale', () =>
    assertEqual(COCKPIT_LONG_IDLE_ROW_OPACITY, Math.round(LONG_IDLE_OPACITY_FRACTION * OPAQUE_OPACITY)));

// The four cards (cockpitCards.js).

test('cockpitCards.js: exports the base, the four cards (each a CockpitCardBase) and the two Resources helpers', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const exportedClass = (className, baseName) => occurrenceCount(source,
        `export const ${className} = GObject.registerClass(\nclass ${className} extends ${baseName} {`);
    assertEqual({
        base: exportedClass('CockpitCardBase', 'St.BoxLayout'),
        cards: CARD_CLASS_NAMES.map(className => exportedClass(className, 'CockpitCardBase')),
        findResourcesApp: occurrenceCount(source, '\nexport function findResourcesApp() {'),
        openResourcesApp: occurrenceCount(source, '\nexport function openResourcesApp() {'),
    }, {base: 1, cards: CARD_CLASS_NAMES.map(() => 1), findResourcesApp: 1, openResourcesApp: 1});
});

test('cockpitCards.js: a card is a vertical box with the cell surface by default, built reactive: false and drawn ' +
    'through its own offscreen texture by default; only the system card asks for no surface and no texture (the v2 ' +
    'card it adopts draws through its own)', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const baseInitBody = cardMethodBody('CockpitCardBase', '_init(');
    const baseInitStatements = statementsOf(baseInitBody);
    const textureGuardIndex = baseInitStatements.indexOf('if (isDrawnThroughOwnTexture)');
    const superInitProperties = ['style_class: cellStyleClass,', 'orientation: Clutter.Orientation.VERTICAL,',
        'reactive: false,'];
    assertEqual({
        surfaceDefined: occurrenceCount(source, "const CELL_STYLE_CLASS = 'resource-pulse-card rp-cockpit-cell';"),
        surfaceAndTextureByDefault: occurrenceCount(baseInitBody, '_init({tooltip, onRowActivated = null, ' +
            'cellStyleClass = CELL_STYLE_CLASS, isDrawnThroughOwnTexture = true}) {'),
        superInitProperties: superInitProperties.map(property => occurrenceCount(baseInitBody, property)),
        textureWhenAsked: textureGuardIndex < 0 ? [] : baseInitStatements.slice(textureGuardIndex, textureGuardIndex + 2),
        cardsAskingForAStyle: CARD_CLASS_NAMES.filter(className =>
            cardMethodBody(className, '_init(').includes('cellStyleClass')),
        cardsAskingAboutTheTexture: CARD_CLASS_NAMES.filter(className =>
            cardMethodBody(className, '_init(').includes('isDrawnThroughOwnTexture')),
        systemCardAsksForNone: occurrenceCount(cardMethodBody('SystemCockpitCard', '_init('),
            'super._init({tooltip, cellStyleClass: null, isDrawnThroughOwnTexture: false});'),
    }, {
        surfaceDefined: 1, surfaceAndTextureByDefault: 1, superInitProperties: superInitProperties.map(() => 1),
        textureWhenAsked: ['if (isDrawnThroughOwnTexture)',
            'this.set_offscreen_redirect(Clutter.OffscreenRedirect.ALWAYS);'],
        cardsAskingForAStyle: ['SystemCockpitCard'], cardsAskingAboutTheTexture: ['SystemCockpitCard'],
        systemCardAsksForNone: 1,
    });
});

test('cockpitCards.js: every row is built once, in a card\'s _init, as a reactive: false, track_hover: true ' +
    'rp-cockpit-row of an icon, a name that ellipsizes, two values that never do and a widget bar in its track', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const buildRowBody = cardMethodBody('CockpitCardBase', '_buildRow(');
    const rowParts = [
        'actor: new St.BoxLayout({style_class: ROW_STYLE_CLASS, reactive: false, track_hover: true, visible: false}),',
        'nameLabel: newNameLabel(),', 'firstValueLabel: newValueLabel(),', 'secondValueLabel: newValueLabel(),',
        "const ROW_STYLE_CLASS = 'rp-cockpit-row';",
    ];
    assertEqual({
        rowParts: rowParts.map(part => occurrenceCount(part.startsWith('const') ? source : buildRowBody, part)),
        nameEllipsizes: occurrenceCount(methodBody(source, 'function newNameLabel('),
            'nameLabel.clutter_text.ellipsize = Pango.EllipsizeMode.END;'),
        valuesNeverDo: occurrenceCount(methodBody(source, 'function newValueLabel('),
            'valueLabel.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;'),
        builtInInits: DATA_CARD_CLASS_NAMES.map(className =>
            occurrenceCount(cardMethodBody(className, '_init('), 'this._buildRow(rowsBox)')),
        builtAnywhere: occurrenceCount(source, '._buildRow('),
        rowsKept: occurrenceCount(buildRowBody, 'this._rows.push(row);'),
    }, {
        rowParts: rowParts.map(() => 1), nameEllipsizes: 1, valuesNeverDo: 1, builtInInits: [2, 1, 1],
        builtAnywhere: 4, rowsKept: 1,
    });
});

test('cockpitCards.js: each card builds the rows it can show (APPS_CARD_ROW_LIMIT twice, CONNECTIONS_CARD_ROW_LIMIT, ' +
    'SESSIONS_CARD_ROW_LIMIT); an update makes no actor and destroys none, and hides the rows beyond the data', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const rowLimitOf = limitName => `Array.from({length: ${limitName}}, () => this._buildRow(rowsBox))`;
    const updatePathBodies = [
        ...DATA_CARD_CLASS_NAMES.map(className => cardMethodBody(className, 'update(')),
        cardMethodBody('AppsCockpitCard', '_renderApps('),
        cardMethodBody('ConnectionsCockpitCard', '_renderConnections('),
        cardMethodBody('SessionsCockpitCard', '_renderSessions('),
        cardMethodBody('SessionsCockpitCard', '_showHeader('),
        ...['_showRow(', '_showRowIcon(', '_showRowState(', '_showRowBar(', '_hideRowsFrom(', '_renderNoData(',
            '_setDataShown(', '_hasHoveredRow('].map(declaration => cardMethodBody('CockpitCardBase', declaration)),
        cardMethodBody('SessionsCockpitCard', '_setDataShown('),
        ...['setLabelText(', 'setOptionalLabelText(', 'setStyleClass(', 'appRowContent(', 'connectionRowContent(',
            'sessionRowContent('].map(functionName => methodBody(source, `function ${functionName}`)),
    ];
    /** Each list's rows, hidden past its data in the method that draws that list. */
    const listsHidingTheirRest = [
        ['AppsCockpitCard', '_renderApps(', 'this._cpuRows, cpu.length'],
        ['AppsCockpitCard', '_renderApps(', 'this._memoryRows, memory.length'],
        ['ConnectionsCockpitCard', '_renderConnections(', 'this._connectionRows, rows.length'],
        ['SessionsCockpitCard', '_renderSessions(', 'this._sessionRows, rows.length'],
    ];
    assertEqual({
        apps: occurrenceCount(cardMethodBody('AppsCockpitCard', '_init('), rowLimitOf('APPS_CARD_ROW_LIMIT')),
        connections: occurrenceCount(cardMethodBody('ConnectionsCockpitCard', '_init('),
            rowLimitOf('CONNECTIONS_CARD_ROW_LIMIT')),
        sessions: occurrenceCount(cardMethodBody('SessionsCockpitCard', '_init('),
            rowLimitOf('SESSIONS_CARD_ROW_LIMIT')),
        updatePathsRead: updatePathBodies.map(body => body !== ''),
        updatePathsMakingActors: updatePathBodies.filter(body => body.includes('new ')).length,
        destroys: occurrenceCount(source, 'destroy('),
        hidesTheRest: occurrenceCount(cardMethodBody('CockpitCardBase', '_hideRowsFrom('),
            'row.actor.visible = false;'),
        eachListHidesItsRest: listsHidingTheirRest.map(([className, declaration, rowsArguments]) =>
            occurrenceCount(cardMethodBody(className, declaration), `this._hideRowsFrom(${rowsArguments});`)),
    }, {
        apps: 2, connections: 1, sessions: 1, updatePathsRead: updatePathBodies.map(() => true),
        updatePathsMakingActors: 0, destroys: 0, hidesTheRest: 1, eachListHidesItsRest: [1, 1, 1, 1],
    });
});

test('cockpitCards.js: every icon name comes from COCKPIT_ICON_NAMES through lib/cockpitFormat.js (no -symbolic ' +
    'literal), and every St.Icon is COCKPIT_ROW_ICON_SIZE_PX, which is 16', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const iconNameValues = [...source.matchAll(/\biconName: ([^,\n]+)/g)].map(([, value]) => value.trim());
    assertEqual({
        symbolicLiterals: occurrenceCount(source, SYMBOLIC_SUFFIX),
        icons: occurrenceCount(source, 'new St.Icon('),
        sizedIcons: occurrenceCount(source, 'icon_size: COCKPIT_ROW_ICON_SIZE_PX,'),
        headerIconName: occurrenceCount(cardMethodBody('SessionsCockpitCard', '_addStateCount('),
            'icon_name: stateIconName(state),'),
        iconNameValues,
        rowIconTakesTheName: occurrenceCount(cardMethodBody('CockpitCardBase', '_showRowIcon('),
            'row.icon.icon_name = iconName;'),
        iconSizePx: COCKPIT_ROW_ICON_SIZE_PX,
    }, {
        symbolicLiterals: 0, icons: 2, sizedIcons: 2, headerIconName: 1,
        iconNameValues: ['null', 'connectionRow.icon', 'row.iconName'],
        rowIconTakesTheName: 1, iconSizePx: ROW_ICON_SIZE_PX,
    });
});

test('cockpitCards.js: setInteractive sets reactive on the card and on every row and nothing else, and ' +
    'setInteractive(false) also hides the tooltip', () =>
    assertEqual(statementsOf(cardMethodBody('CockpitCardBase', 'setInteractive(')), [
        'setInteractive(isInteractive) {',
        'this.reactive = isInteractive;',
        'for (const row of this._rows)',
        'row.actor.reactive = isInteractive;',
        'if (!isInteractive)',
        'this._tooltip.hide();',
        '}',
    ]));

test('cockpitCards.js: no St.DrawingArea or cairo: the bar is a widget whose width is its fraction of the track; ' +
    'the bar is set only when its width changed', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    assertEqual({
        drawingAreas: occurrenceCount(source, 'DrawingArea'),
        cairoContexts: occurrenceCount(source, 'get_context('),
        bar: occurrenceCount(cardMethodBody('CockpitCardBase', '_buildRow('), 'bar: new St.Widget({'),
        showRowBar: statementsOf(cardMethodBody('CockpitCardBase', '_showRowBar(')),
    }, {
        drawingAreas: 0, cairoContexts: 0, bar: 1,
        showRowBar: [
            '_showRowBar(row) {',
            'const barWidthPx = rowBarWidthPx(row.barFraction, this._barTrackWidthPx);',
            'if (barWidthPx === row.barWidthPx)',
            'return;',
            'row.bar.set_width(barWidthPx);',
            'row.barWidthPx = barWidthPx;',
            '}',
        ],
    });
});

test('cockpitCards.js: a card\'s width gives its rows\' bars their track (ruling D29): setCardWidth sets the card\'s ' +
    'width and every row\'s track to its share of that width, redrawing each bar, and nothing more when the track\'s ' +
    'width is unchanged; it sets no height (the dropdown gives a card only a width), and setCellSize goes through ' +
    'it, then sets the height', () =>
    assertEqual({
        setCardWidth: statementsOf(cardMethodBody('CockpitCardBase', 'setCardWidth(')),
        setCellSize: statementsOf(cardMethodBody('CockpitCardBase', 'setCellSize(')),
    }, {
        setCardWidth: [
            'setCardWidth(widthPx) {',
            'this.set_width(widthPx);',
            'const barTrackWidthPx = Math.round(widthPx * COCKPIT_ROW_BAR_TRACK_SHARE_OF_CELL_WIDTH);',
            'if (barTrackWidthPx === this._barTrackWidthPx)',
            'return;',
            'this._barTrackWidthPx = barTrackWidthPx;',
            'for (const row of this._rows) {',
            'row.barTrack.set_width(barTrackWidthPx);',
            'this._showRowBar(row);',
            '}',
            '}',
        ],
        setCellSize: [
            'setCellSize(widthPx, heightPx) {', 'this.setCardWidth(widthPx);', 'this.set_height(heightPx);', '}',
        ],
    }));

test('cockpitCards.js: a handler is either on the card itself or tied to it by connectObject(..., this), and ' +
    'destroying a card hides the shared tooltip', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const buildRowBody = cardMethodBody('CockpitCardBase', '_buildRow(');
    assertEqual({
        connects: occurrenceCount(source, '.connect('),
        connectsOnTheCardItself: occurrenceCount(source, 'this.connect('),
        destroyHandler: occurrenceCount(cardMethodBody('CockpitCardBase', '_init('),
            "this.connect('destroy', () => this._onDestroy());"),
        connectObjects: occurrenceCount(source, '.connectObject('),
        rowHandlersTiedToTheCard: /row\.actor\.connectObject\([^;]*\bthis\);/.test(buildRowBody),
        pulseCardHandlerTiedToTheCard: /pulseCard\.connectObject\([^;]*\bthis\);/
            .test(cardMethodBody('SystemCockpitCard', '_adoptPulseCard(')),
        disconnects: occurrenceCount(source, 'disconnect'),
        disconnectsTheAdoptedCard: occurrenceCount(cardMethodBody('SystemCockpitCard', '_releasePulseCard('),
            'pulseCard.disconnectObject(this);'),
        destroyHidesTheTooltip: occurrenceCount(cardMethodBody('CockpitCardBase', '_onDestroy('),
            'this._tooltip?.hide();'),
    }, {
        connects: 2, connectsOnTheCardItself: 2, destroyHandler: 1, connectObjects: 2, rowHandlersTiedToTheCard: true,
        pulseCardHandlerTiedToTheCard: true, disconnects: 1, disconnectsTheAdoptedCard: 1, destroyHidesTheTooltip: 1,
    });
});

test('cockpitCards.js: every style class the cards name is selected in stylesheet.css', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const stylesheet = readExtensionFile(STYLESHEET_FILE).replace(CSS_COMMENT_PATTERN, '');
    const namedClasses = [...new Set([...source.matchAll(QUOTED_STYLE_CLASSES_PATTERN)]
        .flatMap(([, styleClasses]) => styleClasses.split(' ')))].sort();
    const isSelected = className => new RegExp(`\\.${className}(?![\\w-])`).test(stylesheet);
    assertEqual({namedClasses, unselected: namedClasses.filter(className => !isSelected(className))}, {
        namedClasses: [
            'resource-pulse-card', 'resource-pulse-card-label', 'rp-cockpit-cell', 'rp-cockpit-name-waiting',
            'rp-cockpit-no-data', 'rp-cockpit-row', 'rp-cockpit-row-bar', 'rp-cockpit-row-long-idle',
        ],
        unselected: [],
    });
});

test('cockpitCards.js: entering a row shows its lines in the shared tooltip, leaving hides it, and a primary-button ' +
    'release on a session row activates that session; only a session row carries an id', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const buildRowBody = cardMethodBody('CockpitCardBase', '_buildRow(');
    assertEqual({
        handlers: ["'enter-event', () => this._onRowEntered(row),", "'leave-event', () => this._onRowLeft(),",
            "'button-release-event', (_actor, event) => this._onRowReleased(row, event),"]
            .map(handler => occurrenceCount(buildRowBody, handler)),
        entered: occurrenceCount(cardMethodBody('CockpitCardBase', '_onRowEntered('),
            'this._tooltip.showFor(row.actor, row.tooltipLines);'),
        left: occurrenceCount(cardMethodBody('CockpitCardBase', '_onRowLeft('), 'this._tooltip.hide();'),
        released: statementsOf(cardMethodBody('CockpitCardBase', '_onRowReleased(')),
        sessionIds: [...source.matchAll(/\bsessionId: ([^,\n]+)/g)].map(([, value]) => value.trim()),
    }, {
        handlers: [1, 1, 1], entered: 1, left: 1,
        released: [
            '_onRowReleased(row, event) {',
            'if (row.sessionId === null || this._onRowActivated === null || ' +
                'event.get_button() !== Clutter.BUTTON_PRIMARY)',
            'return Clutter.EVENT_PROPAGATE;',
            'this._onRowActivated(row.sessionId);',
            'return Clutter.EVENT_STOP;',
            '}',
        ],
        sessionIds: ['null', 'row.id', 'null'],
    });
});

test('cockpitCards.js: a long-idle row gets rp-cockpit-row-long-idle AND the actor opacity ' +
    'COCKPIT_LONG_IDLE_ROW_OPACITY, any other row opacity 255 (St reads no CSS opacity: ruling D8); a waiting ' +
    'session\'s name is tinted', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    assertEqual({
        showRowState: statementsOf(cardMethodBody('CockpitCardBase', '_showRowState(')),
        opaque: occurrenceCount(source, 'const OPAQUE_OPACITY = 255;'),
        fromTheSessionRow: ['isLongIdle: row.isLongIdle,', 'isWaiting: row.isWaiting,']
            .map(field => occurrenceCount(methodBody(source, 'function sessionRowContent('), field)),
        appliedToEveryShownRow: occurrenceCount(cardMethodBody('CockpitCardBase', '_showRow('),
            'this._showRowState(row, content);'),
    }, {
        showRowState: [
            '_showRowState(row, {isLongIdle, isWaiting}) {',
            'setStyleClass(row.actor, LONG_IDLE_ROW_STYLE_CLASS, isLongIdle);',
            'setStyleClass(row.nameLabel, WAITING_NAME_STYLE_CLASS, isWaiting);',
            'const rowOpacity = isLongIdle ? COCKPIT_LONG_IDLE_ROW_OPACITY : OPAQUE_OPACITY;',
            'if (row.actor.opacity !== rowOpacity)',
            'row.actor.opacity = rowOpacity;',
            '}',
        ],
        opaque: 1, fromTheSessionRow: [1, 1], appliedToEveryShownRow: 1,
    });
});

test('cockpitCards.js: a label\'s text, an icon\'s name and the hovered row\'s tooltip are set only when they ' +
    'changed, so an unchanged update queues no relayout', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const showRowBody = cardMethodBody('CockpitCardBase', '_showRow(');
    assertEqual({
        setLabelText: statementsOf(methodBody(source, 'function setLabelText(')),
        textAssignments: occurrenceCount(source, '.text = '),
        setTextCalls: occurrenceCount(source, 'set_text('),
        iconNameCompared: occurrenceCount(cardMethodBody('CockpitCardBase', '_showRowIcon('),
            'if (iconName !== null && row.icon.icon_name !== iconName)'),
        hoveredTooltipCompared: occurrenceCount(showRowBody,
            'if (row.actor.hover && !areSameLines(row.tooltipLines, content.tooltipLines))'),
    }, {
        setLabelText: ['function setLabelText(label, text) {', 'if (label.text !== text)', 'label.text = text;', '}'],
        textAssignments: 1, setTextCalls: 0, iconNameCompared: 1, hoveredTooltipCompared: 1,
    });
});

test('cockpitCards.js: a hovered row whose tooltip lines changed shows its new lines, as entering it does, or, when ' +
    'its new content has none, hides the tooltip rather than showing an empty one or what the row showed before', () =>
    assertEqual({
        showRowTellsIt: occurrenceCount(cardMethodBody('CockpitCardBase', '_showRow('),
            'this._showHoveredRowTooltip(row, content.tooltipLines);'),
        hovered: statementsOf(cardMethodBody('CockpitCardBase', '_showHoveredRowTooltip(')),
    }, {
        showRowTellsIt: 1,
        hovered: [
            '_showHoveredRowTooltip(row, tooltipLines) {',
            'if (tooltipLines.length > 0)',
            'this._tooltip.showFor(row.actor, tooltipLines);',
            'else',
            'this._tooltip.hide();',
            '}',
        ],
    }));

test('cockpitCards.js: frozen, a card only records its latest render; unfreezing undims and draws it, the frozen ' +
    'repaint draws it still dimmed, and every update and no-data line goes through that record', () => {
    const renderThroughTheRecord = /this\._renderUnlessFrozen\(\(\) => this\._render\w+\(/;
    assertEqual({
        recordOrRender: statementsOf(cardMethodBody('CockpitCardBase', '_renderUnlessFrozen(')),
        setFrozen: statementsOf(cardMethodBody('CockpitCardBase', 'setFrozen(')),
        repaintFrozen: statementsOf(cardMethodBody('CockpitCardBase', 'repaintFrozen(')),
        updatesThroughTheRecord: DATA_CARD_CLASS_NAMES.map(className =>
            renderThroughTheRecord.test(cardMethodBody(className, 'update('))),
        noDataThroughTheRecord: occurrenceCount(cardMethodBody('CockpitCardBase', 'showNoData('),
            'this._renderUnlessFrozen(() => this._renderNoData(text));'),
    }, {
        recordOrRender: ['_renderUnlessFrozen(render) {', 'this._latestRender = render;', 'if (!this._isFrozen)',
            'render();', '}'],
        setFrozen: [
            'setFrozen(isFrozen) {', 'if (isFrozen === this._isFrozen)', 'return;', 'this._isFrozen = isFrozen;',
            'if (isFrozen) {', 'this.add_style_pseudo_class(FROZEN_PSEUDO_CLASS);', 'return;', '}',
            'this.remove_style_pseudo_class(FROZEN_PSEUDO_CLASS);', 'this._latestRender?.();', '}',
        ],
        repaintFrozen: ['repaintFrozen() {', 'if (this._isFrozen)', 'this._latestRender?.();', '}'],
        updatesThroughTheRecord: DATA_CARD_CLASS_NAMES.map(() => true),
        noDataThroughTheRecord: 1,
    });
});

test('cockpitCards.js: each card\'s update takes exactly what it draws, with no clock (ruling D9), the apps card the ' +
    'system card\'s clock label too, so with no apps it says no data since when the system card does; a source it ' +
    'cannot draw is no data, and a sessions source with herdr down says so, each returning before any render', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const updateDeclarations = CARD_CLASS_NAMES.map(className =>
        statementsOf(cardMethodBody(className, 'update('))[0]);
    const noDataBranch = guard => [guard, 'this.showNoData(NO_SOURCE_TEXT);', 'return;', '}'];
    assertEqual({
        updateDeclarations,
        clocks: occurrenceCount(source, 'nowRealUsec'),
        dataCardUpdates: DATA_CARD_CLASS_NAMES.map(className => statementsOf(cardMethodBody(className, 'update('))),
        herdrLine: statementsOf(cardMethodBody('CockpitCardBase', 'showHerdrNotRunning(')),
    }, {
        updateDeclarations: ['update(snapshot, lastGoodClockLabel) {', 'update(apps, lastGoodClockLabel) {',
            'update(network, mounts) {', 'update(sessions) {'],
        clocks: 0,
        dataCardUpdates: [
            ['update(apps, lastGoodClockLabel) {', 'if (!canDrawApps(apps)) {',
                'this.showNoData(appsNoDataText(lastGoodClockLabel));', 'return;', '}',
                'this._renderUnlessFrozen(() => this._renderApps(apps));', '}'],
            ['update(network, mounts) {', ...noDataBranch('if (!canDrawConnections(network, mounts)) {'),
                'this._renderUnlessFrozen(() => this._renderConnections(network, mounts));', '}'],
            ['update(sessions) {', 'if (sessions?.herdrRunning === false) {', 'this.showHerdrNotRunning();', 'return;',
                '}', ...noDataBranch('if (!canDrawSessions(sessions)) {'),
                'this._renderUnlessFrozen(() => this._renderSessions(sessions));', '}'],
        ],
        herdrLine: ['showHerdrNotRunning() {', 'this.showNoData(herdrNotRunningText);', '}'],
    });
});

test('cockpitCards.js: the sessions card draws its header, rows and "+N more" from lib/cockpitFormat.js, each row ' +
    'with the icon, class, tooltip and id sessionRows gives it; no card reads a source row or a ranking entry by ' +
    'index', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const renderBody = cardMethodBody('SessionsCockpitCard', '_renderSessions(');
    assertEqual({
        header: occurrenceCount(renderBody, 'this._showHeader(sessionsHeader(sessions));'),
        headerAssignsTexts: statementsOf(cardMethodBody('SessionsCockpitCard', '_showHeader(')),
        rows: occurrenceCount(renderBody, 'const {rows, overflowText} = sessionRows(sessions);'),
        rowContent: occurrenceCount(renderBody,
            'this._showRow(this._sessionRows[rowIndex], sessionRowContent(row)));'),
        sourceReadsByIndex: ['sessions.rows[', 'cpuRanking[', 'memoryRanking[']
            .map(needle => occurrenceCount(source, needle)),
        overflow: occurrenceCount(renderBody, "setOptionalLabelText(this._overflowLabel, overflowText ?? '');"),
        sessionRowContent: statementsOf(methodBody(source, 'function sessionRowContent(')),
        headerTitle: occurrenceCount(cardMethodBody('SessionsCockpitCard', '_buildHeader('),
            'headerBox.add_child(newMutedLabel(sessionsCardTitle));'),
        stateCountsInOrder: occurrenceCount(cardMethodBody('SessionsCockpitCard', '_buildHeader('),
            'this._stateCountLabels = SESSION_STATES.map(state => this._addStateCount(state));'),
        stateIconClass: occurrenceCount(cardMethodBody('SessionsCockpitCard', '_addStateCount('),
            'style_class: stateStyleClass(state),'),
    }, {
        header: 1,
        headerAssignsTexts: ['_showHeader(header) {', 'setLabelText(this._sessionCountLabel, header.count);',
            'header.counts.forEach(({count}, stateIndex) => setLabelText(this._stateCountLabels[stateIndex], count));',
            'setLabelText(this._totalMemoryLabel, header.totalMemory);', '}'],
        rows: 1, rowContent: 1, sourceReadsByIndex: [0, 0, 0], overflow: 1,
        sessionRowContent: [
            'function sessionRowContent(row) {', 'return {', 'iconName: row.iconName,',
            'iconStyleClass: row.iconStyleClass,', 'name: row.name,', 'firstValue: row.idleText,',
            'secondValue: row.memoryText,', 'fraction: row.memoryFraction,',
            'tooltipLines: row.tooltip,', 'isLongIdle: row.isLongIdle,',
            'isWaiting: row.isWaiting,', 'sessionId: row.id,', '};', '}',
        ],
        headerTitle: 1, stateCountsInOrder: 1, stateIconClass: 1,
    });
});

test('cockpitCards.js: the apps card draws appsRows\' CPU rows, a divider, then its memory rows, each row\'s ' +
    'tooltip the one appsRows gives it (its own entry\'s group key)', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const appsInitBody = cardMethodBody('AppsCockpitCard', '_init(');
    const renderAppsBody = cardMethodBody('AppsCockpitCard', '_renderApps(');
    assertEqual({
        title: occurrenceCount(appsInitBody, 'this.add_child(newMutedLabel(appsCardTitle));'),
        dividerBetween: appsInitBody.indexOf('this._cpuRows = ') < appsInitBody.indexOf(APPS_DIVIDER_STATEMENT) &&
            appsInitBody.indexOf(APPS_DIVIDER_STATEMENT) < appsInitBody.indexOf('this._memoryRows = '),
        rankings: occurrenceCount(renderAppsBody, 'const {cpu, memory} = appsRows(apps);'),
        rowContents: ['appRowContent(entry.name, entry.cpuText, entry.cpuFraction, entry.tooltip)',
            'appRowContent(entry.name, entry.memoryText, entry.memoryFraction, entry.tooltip)']
            .map(rowContent => occurrenceCount(renderAppsBody, rowContent)),
        appRowContent: statementsOf(methodBody(source, 'function appRowContent(')),
    }, {
        title: 1, dividerBetween: true, rankings: 1, rowContents: [1, 1],
        appRowContent: ['function appRowContent(name, valueText, fraction, tooltipLines) {',
            'return {...EMPTY_ROW_CONTENT, name, firstValue: valueText, fraction, tooltipLines};', '}'],
    });
});

test('cockpitCards.js: the connections card draws connectionsRows and below them their "+N more" line, in a muted ' +
    'label built once, so rows past CONNECTIONS_CARD_ROW_LIMIT never vanish silently', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const initBody = cardMethodBody('ConnectionsCockpitCard', '_init(');
    const renderBody = cardMethodBody('ConnectionsCockpitCard', '_renderConnections(');
    const overflowLabelBuilt = 'this._overflowLabel = newMutedLabel();';
    assertEqual({
        title: occurrenceCount(initBody, 'this.add_child(newMutedLabel(connectionsCardTitle));'),
        overflowLabelBelowTheRows: initBody.indexOf('this._connectionRows = ') < initBody.indexOf(overflowLabelBuilt),
        overflowLabelAdded: [overflowLabelBuilt, 'rowsBox.add_child(this._overflowLabel);']
            .map(statement => occurrenceCount(initBody, statement)),
        rowsAndOverflow: occurrenceCount(renderBody, 'const {rows, overflowText} = connectionsRows(network, mounts);'),
        overflowDrawn: occurrenceCount(renderBody, "setOptionalLabelText(this._overflowLabel, overflowText ?? '');"),
        cutInTheCard: occurrenceCount(renderBody, '.slice('),
        connectionContent: ['iconName: connectionRow.icon,', 'iconStyleClass: connectionRow.iconStyleClass,',
            'name: connectionRow.text,', 'fraction: connectionRow.fraction,', 'tooltipLines: connectionRow.tooltip,']
            .map(field => occurrenceCount(methodBody(source, 'function connectionRowContent('), field)),
    }, {
        title: 1, overflowLabelBelowTheRows: true, overflowLabelAdded: [1, 1], rowsAndOverflow: 1, overflowDrawn: 1,
        cutInTheCard: 0, connectionContent: [1, 1, 1, 1, 1],
    });
});

test('cockpitCards.js: the system card adopts the extension\'s v2 card (ruling D11): it reparents it into the cell ' +
    'and lays it out there, forwards setCellSize, update, setFrozen and repaintFrozen, and gives it back on destroy, ' +
    'never destroying it', () => {
    const systemBody = declarationLine => statementsOf(cardMethodBody('SystemCockpitCard', declarationLine));
    assertEqual({
        init: systemBody('_init('),
        adopt: systemBody('_adoptPulseCard('),
        setCellSize: systemBody('setCellSize('),
        update: systemBody('update('),
        setFrozen: systemBody('setFrozen('),
        repaintFrozen: systemBody('repaintFrozen('),
        onDestroy: systemBody('_onDestroy('),
    }, {
        init: ['_init({pulseCard, tooltip}) {',
            'super._init({tooltip, cellStyleClass: null, isDrawnThroughOwnTexture: false});',
            'this._pulseCard = pulseCard;', 'this._adoptPulseCard();',
            "this.connect('button-release-event', (_actor, event) => this._onCardReleased(event));", '}'],
        adopt: ['_adoptPulseCard() {', 'const pulseCard = this._pulseCard;',
            'pulseCard.get_parent()?.remove_child(pulseCard);', 'pulseCard.fixed_position_set = false;',
            'this.add_child(pulseCard);',
            "pulseCard.connectObject('destroy', () => this._onPulseCardDestroyed(), this);", '}'],
        setCellSize: ['setCellSize(widthPx, heightPx) {', 'this.set_size(widthPx, heightPx);',
            'this._pulseCard?.setCellSize(widthPx, heightPx);', '}'],
        update: ['update(snapshot, lastGoodClockLabel) {', 'this._pulseCard?.update(snapshot, lastGoodClockLabel);',
            '}'],
        setFrozen: ['setFrozen(isFrozen) {', 'this._pulseCard?.setFrozen(isFrozen);', '}'],
        repaintFrozen: ['repaintFrozen() {', 'this._pulseCard?.repaintFrozen();', '}'],
        onDestroy: ['_onDestroy() {', 'this._releasePulseCard();', 'super._onDestroy();', '}'],
    });
});

test('cockpitCards.js: the system card survives a v2 card destroyed before it: a destroy handler tied to the ' +
    'system card clears the v2 card, every use of it is guarded, and giving it back releases the handler', () => {
    const systemCode = classBody(codeOf(CARDS_SOURCE_FILE), 'SystemCockpitCard');
    assertEqual({
        connected: occurrenceCount(methodBody(systemCode, '_adoptPulseCard('),
            "pulseCard.connectObject('destroy', () => this._onPulseCardDestroyed(), this);"),
        cleared: statementsOf(methodBody(systemCode, '_onPulseCardDestroyed(')),
        released: statementsOf(methodBody(systemCode, '_releasePulseCard(')),
        guardedUses: occurrenceCount(systemCode, 'this._pulseCard?.'),
        unguardedUses: occurrenceCount(systemCode, 'this._pulseCard.'),
    }, {
        connected: 1,
        cleared: ['_onPulseCardDestroyed() {', 'this._pulseCard = null;', '}'],
        released: ['_releasePulseCard() {', 'const pulseCard = this._pulseCard ?? null;', 'if (pulseCard === null)',
            'return;', 'this._pulseCard = null;', 'pulseCard.disconnectObject(this);',
            'if (pulseCard.get_parent() === this)', 'this.remove_child(pulseCard);', '}'],
        guardedUses: 4,
        unguardedUses: 0,
    });
});

test('cockpitCards.js: hiding a row under the pointer hides the tooltip (no leave-event reaches an actor hidden ' +
    'under the pointer); a row hidden already is left alone, and a hidden row keeps its actors', () =>
    assertEqual(statementsOf(cardMethodBody('CockpitCardBase', '_hideRowsFrom(')), [
        '_hideRowsFrom(rows, firstHiddenIndex) {',
        'for (const row of rows.slice(firstHiddenIndex)) {',
        'if (row.actor.visible && row.actor.hover)',
        'this._tooltip.hide();',
        'row.actor.visible = false;',
        '}',
        '}',
    ]));

test('cockpitCards.js: hiding a card\'s data (its no-data or herdr line) while one of its rows is under the pointer ' +
    'hides the tooltip; a box hidden already, or no row of this card hovered, leaves the shared tooltip alone', () =>
    assertEqual({
        setDataShown: statementsOf(cardMethodBody('CockpitCardBase', '_setDataShown(')),
        hasHoveredRow: statementsOf(cardMethodBody('CockpitCardBase', '_hasHoveredRow(')),
        noDataGoesThroughIt: occurrenceCount(cardMethodBody('CockpitCardBase', '_renderNoData('),
            'this._setDataShown(false);'),
        sessionsOverrideGoesThroughIt: statementsOf(cardMethodBody('SessionsCockpitCard', '_setDataShown('))[1],
    }, {
        setDataShown: [
            '_setDataShown(isDataShown) {',
            'if (!isDataShown && this._contentBox.visible && this._hasHoveredRow())',
            'this._tooltip.hide();',
            'this._contentBox.visible = isDataShown;',
            'this._noDataLabel.visible = !isDataShown;',
            '}',
        ],
        hasHoveredRow: ['_hasHoveredRow() {', 'return this._rows.some(row => row.actor.visible && row.actor.hover);',
            '}'],
        noDataGoesThroughIt: 1,
        sessionsOverrideGoesThroughIt: 'super._setDataShown(isDataShown);',
    }));

test('cockpitCards.js: no card paints itself (no vfunc_paint or vfunc_paint_node in the code: ruling D12), and the ' +
    'base\'s one offscreen redirect is the file\'s only one (nor is the camelCase property set: GJS accepts ' +
    'offscreenRedirect too), so a data card is drawn only through the texture the base gives it and the system cell ' +
    'holds one texture, the adopted v2 card\'s', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    assertEqual({
        paintVfuncs: occurrenceCount(source, 'vfunc_paint'),
        offscreenRedirectUses: occurrenceCount(source, 'offscreen_redirect'),
        offscreenRedirectPropertyUses: occurrenceCount(source, 'offscreenRedirect'),
        // A kebab-case 'offscreen-redirect' constructor property matches neither needle above, but takes the enum.
        offscreenRedirectEnumUses: occurrenceCount(source, 'OffscreenRedirect'),
        baseRedirects: occurrenceCount(classBody(source, 'CockpitCardBase'),
            'this.set_offscreen_redirect(Clutter.OffscreenRedirect.ALWAYS);'),
    }, {
        paintVfuncs: 0, offscreenRedirectUses: 1, offscreenRedirectPropertyUses: 0, offscreenRedirectEnumUses: 1,
        baseRedirects: 1,
    });
});

test('cockpitCards.js: a primary-button release on the system card opens Resources; the system card draws no ' +
    'no-data line of its own (the v2 card says "no data" itself)', () =>
    assertEqual({
        released: statementsOf(cardMethodBody('SystemCockpitCard', '_onCardReleased(')),
        showNoData: statementsOf(cardMethodBody('SystemCockpitCard', 'showNoData(')),
    }, {
        released: ['_onCardReleased(event) {', 'if (event.get_button() !== Clutter.BUTTON_PRIMARY)',
            'return Clutter.EVENT_PROPAGATE;', 'openResourcesApp();', 'return Clutter.EVENT_STOP;', '}'],
        showNoData: ['showNoData(_text) {', '}'],
    }));

test('cockpitCards.js imports nothing from indicator.js, extension.js or cockpitLayer.js, and indicator.js takes ' +
    'the Resources helpers from it, keeping no copy (ruling D10)', () => {
    const cardsSource = readExtensionFile(CARDS_SOURCE_FILE);
    const indicatorCode = codeOf(INDICATOR_SOURCE_FILE);
    const relativeSpecifiers = [...cardsSource.matchAll(IMPORT_STATEMENT_PATTERN)].map(([, specifier]) => specifier)
        .filter(specifier => specifier.startsWith(RELATIVE_SPECIFIER_PREFIX));
    const namesTakenFromTheCards = importedNames(readExtensionFile(INDICATOR_SOURCE_FILE), CARDS_IMPORT_SPECIFIER);
    assertEqual({
        relativeSpecifiers,
        indicatorImportsThem: RESOURCES_HELPER_NAMES.filter(name => namesTakenFromTheCards.includes(name)),
        indicatorCopies: ['_findResourcesApp', '_openResources()', 'Shell.AppSystem', 'lookup_app(']
            .filter(needle => indicatorCode.includes(needle)),
    }, {
        relativeSpecifiers: ['./lib/constants.js', './lib/cockpitFormat.js', './lib/cockpitProtocol.js'],
        indicatorImportsThem: RESOURCES_HELPER_NAMES,
        indicatorCopies: [],
    });
});

test('card.js: setCellSize drops the fixed width and takes the cell\'s size, clearCellSize gives the fixed width and ' +
    'the natural size back, and placeOnPrimaryMonitor still places the card top right', () => {
    const cardSource = readExtensionFile(PULSE_CARD_SOURCE_FILE);
    assertEqual({
        setCellSize: statementsOf(methodBody(cardSource, 'setCellSize(')),
        clearCellSize: statementsOf(methodBody(cardSource, 'clearCellSize(')),
        unsetSize: occurrenceCount(cardSource, '\nconst UNSET_SIZE = -1;\n'),
        placesTopRight: occurrenceCount(methodBody(cardSource, 'placeOnPrimaryMonitor() {'),
            'this.set_position(Math.floor(x), Math.floor(y));'),
    }, {
        setCellSize: ['setCellSize(widthPx, heightPx) {', 'this.remove_style_class_name(FIXED_WIDTH_STYLE_CLASS);',
            'this.set_size(widthPx, heightPx);', '}'],
        clearCellSize: ['clearCellSize() {', 'this.add_style_class_name(FIXED_WIDTH_STYLE_CLASS);',
            'this.set_size(UNSET_SIZE, UNSET_SIZE);', '}'],
        unsetSize: 1,
        placesTopRight: 1,
    });
});

// cockpitLayer.js: the layer that holds the cockpit's grid in the background group.
const LAYER_SOURCE_FILE = 'cockpitLayer.js';

/**
 * The body of a method of cockpitLayer.js, comments removed.
 *
 * @param {string} declarationLine - The method's declaration as it starts its line.
 * @returns {string} The body, or ''.
 */
function layerMethodBody(declarationLine) {
    return methodBody(readExtensionFile(LAYER_SOURCE_FILE), declarationLine);
}

/**
 * The statements of a method of cockpitLayer.js between its declaration and its closing brace.
 *
 * @param {string} declarationLine - The method's declaration as it starts its line.
 * @returns {string[]} Its statements, trimmed.
 */
function layerMethodStatements(declarationLine) {
    return statementsOf(layerMethodBody(declarationLine)).slice(1, -1);
}

test('cockpitLayer.js: the layer is a non-reactive St.Widget of class rp-cockpit-layer that, once built (its ' +
    'tooltip, the v2 card out of its parent, the layout, both client listeners), adds itself to the background group ' +
    'last; a failure while building destroys what was built and rethrows', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    const initStatements = layerMethodStatements('_init(');
    const tryIndex = initStatements.indexOf('try {');
    const catchIndex = initStatements.indexOf('} catch (error) {');
    assertEqual({
        classDeclared: occurrenceCount(source, '\nclass CockpitLayer extends St.Widget {\n'),
        styleClassDefined: occurrenceCount(source, "const LAYER_STYLE_CLASS = 'rp-cockpit-layer';"),
        superInit: occurrenceCount(source, 'super._init({style_class: LAYER_STYLE_CLASS, reactive: false});'),
        built: tryIndex < 0 || catchIndex < 0 ? [] : initStatements.slice(tryIndex + 1, catchIndex),
        onFailure: catchIndex < 0 ? [] : initStatements.slice(catchIndex + 1, catchIndex + 3),
        backgroundGroupAdds: occurrenceCount(source, '_backgroundGroup.add_child('),
    }, {
        classDeclared: 1, styleClassDefined: 1, superInit: 1,
        built: [
            'this._tooltip = new CockpitTooltip();',
            'pulseCard.get_parent()?.remove_child(pulseCard);',
            'this.setLayout(cockpitClient.layout);',
            'this._cockpitListenerId = cockpitClient.addListener(event => this._pacing.onCockpitEvent(event));',
            'this._snapshotListenerId = pulseClient.addListener(snapshot => this._onSnapshot(snapshot));',
            'Main.layoutManager._backgroundGroup.add_child(this);',
        ],
        onFailure: ['this.destroy();', 'throw error;'],
        backgroundGroupAdds: 1,
    });
});

test('cockpitLayer.js: placeOnMonitor lays the grid out from cockpitGridGeometry, each caption at its rectangle and ' +
    'each card in the first cell of its id (drawnCockpitCells: an unknown id\'s cell stays empty), sized by ' +
    'setCellSize; cardRects gives those cells; setLayout makes the cards drawnCockpitCardIds names', () =>
    assertEqual({
        place: layerMethodStatements('placeOnMonitor('),
        cardRects: layerMethodStatements('cardRects('),
        layoutMakesTheDrawnIds: occurrenceCount(layerMethodBody('setLayout('),
            'this._syncCards(drawnCockpitCardIds(layout.groups));'),
        captionStyleClassDefined: occurrenceCount(codeOf(LAYER_SOURCE_FILE),
            "const CAPTION_STYLE_CLASS = 'rp-cockpit-caption';"),
        captionsUseIt: occurrenceCount(layerMethodBody('_syncCaptions('),
            'new St.Label({style_class: CAPTION_STYLE_CLASS})'),
        captionText: layerMethodStatements('_syncCaptions(').slice(-6),
    }, {
        place: [
            'this._monitorIndex = monitorIndex;',
            'const {captions, cells} = cockpitGridGeometry({workArea, groups: this._layout.groups});',
            'captions.forEach((caption, captionIndex) => placeActor(this._captionLabels[captionIndex], caption));',
            'this._drawnCells = drawnCockpitCells(cells);',
            'for (const cell of this._drawnCells) {',
            'const card = this._cardsById.get(cell.cardId);',
            'card.set_position(cell.x, cell.y);',
            'card.setCellSize(cell.width, cell.height);',
            '}',
        ],
        cardRects: [
            'return this._drawnCells.map(({cardId, x, y, width, height}) => ({cardId, rect: {x, y, width, height}}));',
        ],
        layoutMakesTheDrawnIds: 1, captionStyleClassDefined: 1, captionsUseIt: 1,
        captionText: [
            'groups.forEach((group, groupIndex) => {',
            'const captionLabel = this._captionLabels[groupIndex];',
            'const captionText = cockpitCaptionText(group.caption);',
            'if (captionLabel.text !== captionText)',
            'captionLabel.text = captionText;',
            '});',
        ],
    }));

test('cockpitLayer.js: a layout change keeps the cards it still names (never remade for a re-placement), destroys ' +
    'those it no longer names and makes only the missing ones, each taking the layer\'s interactivity, which ' +
    'setInteractive forwards to every card on a change; cards are made for exactly COCKPIT_DRAWN_CARD_IDS', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    const makersBlock = source.split('const CARD_MAKERS_BY_ID = Object.freeze({')[1]?.split('\n});')[0] ?? '';
    assertEqual({
        sync: layerMethodStatements('_syncCards('),
        added: layerMethodStatements('_addCard(').slice(-2),
        setInteractive: layerMethodStatements('setInteractive('),
        makerIds: [...makersBlock.matchAll(/^ {4}(\w+): /gm)].map(([, cardId]) => cardId),
        sessionClick: occurrenceCount(makersBlock,
            'new SessionsCockpitCard({tooltip, onRowActivated: onSessionActivated})'),
        systemAdopts: occurrenceCount(makersBlock, 'new SystemCockpitCard({pulseCard, tooltip})'),
    }, {
        // A card destroyed is forgotten (so drawnCardIds never names it, ruling D21) before it is destroyed.
        sync: [
            'for (const [cardId, card] of [...this._cardsById]) {',
            'if (cardIds.includes(cardId))',
            'continue;',
            'this._cardsById.delete(cardId);',
            'this._frozenCardIds.delete(cardId);',
            'card.destroy();',
            '}',
            'for (const cardId of cardIds) {',
            'if (!this._cardsById.has(cardId))',
            'this._addCard(cardId);',
            '}',
        ],
        added: ['this.add_child(card);', 'card.setInteractive(this._isInteractive);'],
        setInteractive: [
            'if (isInteractive === this._isInteractive)', 'return;', 'this._isInteractive = isInteractive;',
            'for (const card of this._cardsById.values())', 'card.setInteractive(isInteractive);',
        ],
        makerIds: ['system', 'apps', 'connections', 'sessions'],
        sessionClick: 1, systemAdopts: 1,
    });
});

test('cockpitLayer.js: the layer draws through no offscreen texture of its own (one texture per card, never one for ' +
    'the layer: no offscreen redirect in snake or camel case, nor the enum a kebab-case \'offscreen-redirect\' ' +
    'property would take), overrides no paint vfunc and has no drawing area', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    assertEqual({
        offscreenRedirect: occurrenceCount(source, 'offscreen_redirect'),
        offscreenRedirectProperty: occurrenceCount(source, 'offscreenRedirect'),
        offscreenRedirectEnum: occurrenceCount(source, 'OffscreenRedirect'),
        paintVfuncs: occurrenceCount(source, 'vfunc_paint'),
        drawingAreas: occurrenceCount(source, 'DrawingArea'),
        isRead: source.length > 0,
    }, {
        offscreenRedirect: 0, offscreenRedirectProperty: 0, offscreenRedirectEnum: 0, paintVfuncs: 0, drawingAreas: 0,
        isRead: true,
    });
});

test('cockpitLayer.js: the layer paces its data cards through one CockpitSourcePacing (cockpitSourceDrawing.js, ' +
    'shared with the dropdown: ruling D22), made before the build with the layer\'s client, its drawn card ids, ' +
    '_drawCard, its error log and its name; each client event goes to it and each Sample (onSampleTick, from the ' +
    'extension\'s tick) is its onSample; the layer keeps no pending set, timeout, event rule or pull of its ' +
    'own', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    const initStatements = layerMethodStatements('_init(');
    const pacingIndex = initStatements.indexOf('this._pacing = new CockpitSourcePacing({');
    const ownPacingNeedles = [
        'timeout_add', 'source_remove', '_pendingSourceNames', 'cockpitEventEffect', 'CockpitApplyTiming',
        'cockpitCardIdsDrawing', 'cockpitSourceNamesToPull', 'pullIfSuspicious',
    ];
    assertEqual({
        pacing: pacingIndex < 0 ? [] : initStatements.slice(pacingIndex, pacingIndex + 4),
        madeBeforeTheBuild: pacingIndex >= 0 && pacingIndex < initStatements.indexOf('try {'),
        surfaceName: occurrenceCount(source, "const PACING_SURFACE_NAME = 'the cockpit layer';"),
        eventsGoToIt: occurrenceCount(source, 'cockpitClient.addListener(event => this._pacing.onCockpitEvent(event))'),
        sample: layerMethodStatements('onSampleTick('),
        ownPacing: ownPacingNeedles.filter(needle => source.includes(needle)),
    }, {
        pacing: [
            'this._pacing = new CockpitSourcePacing({',
            'cockpitClient, drawnCardIds: () => this.drawnCardIds, drawCard: cardId => this._drawCard(cardId),',
            'errorLog, surfaceName: PACING_SURFACE_NAME,',
            '});',
        ],
        madeBeforeTheBuild: true, surfaceName: 1, eventsGoToIt: 1,
        sample: ['this._pacing.onSample({isSubscriptionWanted});'],
        ownPacing: [],
    });
});

test('cockpitLayer.js: a card revealed is first drawn from what the clients hold, then unfrozen, so the reveal draws ' +
    'the latest at once (ruling D20); a frozen repaint draws it so too, still dimmed', () => {
    assertEqual({
        freeze: layerMethodStatements('setCardFrozen('),
        repaint: layerMethodStatements('repaintFrozenCard(').slice(-2),
    }, {
        // A frozen card is recorded, so its reveal (only from frozen) first draws it from the clients (ruling D20).
        freeze: [
            'const card = this._cardsById.get(cardId);',
            'if (card === undefined)',
            'return;',
            'const isRevealed = !isFrozen && this._frozenCardIds.has(cardId);',
            'if (isFrozen)',
            'this._frozenCardIds.add(cardId);',
            'else',
            'this._frozenCardIds.delete(cardId);',
            'if (isRevealed)',
            'this._drawCard(cardId);',
            'this._guardCardDraw(() => card.setFrozen(isFrozen));',
        ],
        repaint: ['this._drawCard(cardId);', 'this._guardCardDraw(() => card.repaintFrozen());'],
    });
});

test('cockpitLayer.js: the apps card draws the pulse client\'s snapshots (a snapshot listener), the system card the ' +
    'pulse client\'s latest, each through its own update (ruling D9), the apps card with the clock label only while ' +
    'the snapshot carries no numbers (appsNoDataSinceClockLabel), dispatched by _drawCard: a card of the ' +
    'snapshot through its drawer, else drawCockpitDataCard (cockpitSourceDrawing.js, shared with the dropdown: ' +
    'ruling D22); the layer keeps no data-card drawing of its own', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    const ownDataCardNeedles = ['_drawDataCard', 'DATA_CARD_UPDATERS_BY_ID', 'cockpitDataCardDrawing', 'noDataText',
        'formatClockLabel', 'GLib.DateTime'];
    assertEqual({
        drawCard: layerMethodStatements('_drawCard('),
        onSnapshot: layerMethodStatements('_onSnapshot('),
        snapshotDrawers: [
            'system: (card, pulseClient) => card.update(pulseClient.latestSnapshot, pulseClient.lastGoodClockLabel),',
            'apps: (card, pulseClient) => card.update(pulseClient.latestSnapshot?.apps ?? null,',
            'appsNoDataSinceClockLabel(pulseClient.latestSnapshot, pulseClient.lastGoodClockLabel)),',
        ].map(needle => occurrenceCount(source, needle)),
        ownDataCardDrawing: ownDataCardNeedles.filter(needle => source.includes(needle)),
    }, {
        drawCard: [
            'const card = this._cardsById.get(cardId);',
            'const drawSnapshotCard = SNAPSHOT_CARD_DRAWERS_BY_ID[cardId];',
            'if (drawSnapshotCard)',
            'this._guardCardDraw(() => drawSnapshotCard(card, this._pulseClient));',
            'else',
            'this._guardCardDraw(() => drawCockpitDataCard({cardId, card, cockpitClient: this._cockpitClient}));',
        ],
        onSnapshot: [
            'const appsCard = this._cardsById.get(COCKPIT_APPS_CARD_ID);',
            'this._guardCardDraw(() => appsCard?.update(snapshot?.apps ?? null,',
            'appsNoDataSinceClockLabel(snapshot, this._pulseClient.lastGoodClockLabel)));',
        ],
        snapshotDrawers: [1, 1, 1], ownDataCardDrawing: [],
    });
});

test('cockpitLayer.js: destroy removes both client listeners and destroys the pacing (its fallback timeout) before ' +
    'destroying anything, ' +
    'then destroys the cards (the system card giving the v2 card back), the captions and last the tooltip, each ' +
    'step guarded (runEveryStep); its handler is connected before the build\'s try, so a failed build undoes it all; ' +
    'every listener it adds it removes', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    const destroyBody = layerMethodBody('_onDestroy(');
    const initStatements = layerMethodStatements('_init(');
    const destroyHandlerIndex = initStatements.indexOf("this.connect('destroy', () => this._onDestroy());");
    assertEqual({
        destroyHandler: occurrenceCount(layerMethodBody('_init('), "this.connect('destroy', () => this._onDestroy());"),
        destroyHandlerBeforeTheBuild: destroyHandlerIndex >= 0 && destroyHandlerIndex < initStatements.indexOf('try {'),
        guarded: occurrenceCount(destroyBody, 'runEveryStep(['),
        steps: statementsOf(destroyBody).filter(statement => statement.startsWith('{name: ')),
        listenersAdded: occurrenceCount(source, '.addListener('),
        listenersRemoved: [
            layerMethodStatements('_removeCockpitListener(')
                .includes('this._cockpitClient.removeListener(listenerId);'),
            layerMethodStatements('_removeSnapshotListener(').includes('this._pulseClient.removeListener(listenerId);'),
        ],
        everyCardDestroyed: occurrenceCount(layerMethodBody('_destroyCards('), 'run: () => card.destroy()'),
    }, {
        destroyHandler: 1, destroyHandlerBeforeTheBuild: true, guarded: 1,
        steps: [
            "{name: 'remove the cockpit client listener', run: () => this._removeCockpitListener()},",
            "{name: 'remove the snapshot listener', run: () => this._removeSnapshotListener()},",
            "{name: 'destroy the pacing', run: () => this._pacing.destroy()},",
            "{name: 'destroy the cards', run: () => this._destroyCards()},",
            "{name: 'destroy the captions', run: () => this._destroyCaptions()},",
            "{name: 'destroy the tooltip', run: () => this._tooltip?.destroy()},",
        ],
        listenersAdded: 2, listenersRemoved: [true, true], everyCardDestroyed: 1,
    });
});

test('cockpitLayer.js: each card\'s draw runs under its own guard (runLoggingFailure, the layer\'s error log, one ' +
    'context for every card), so a card that throws holds up neither the other cards nor the cover check that ' +
    'called the layer (ruling D25, per card)', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    assertEqual({
        guard: layerMethodStatements('_guardCardDraw('),
        context: occurrenceCount(source, "const CARD_DRAW_FAILURE_CONTEXT = 'cockpit layer could not draw a card';"),
        imported: importedNames(readExtensionFile(LAYER_SOURCE_FILE), './lib/errorLog.js'),
        guardedSteps: occurrenceCount(source, 'this._guardCardDraw(() => '),
    }, {
        guard: ['runLoggingFailure({run: drawStep, errorLog: this._errorLog, context: CARD_DRAW_FAILURE_CONTEXT});'],
        context: 1,
        imported: ['describeErrorWithStack', 'runLoggingFailure'],
        // The two draws of _drawCard, the reveal's unfreeze, the frozen repaint and the apps card's snapshot.
        guardedSteps: 5,
    });
});

test('cockpitLayer.js: the layer\'s own failures are logged rate-limited by their context (the template key), not by ' +
    'the whole message, whose error text and stack vary', () =>
    assertEqual(layerMethodStatements('_logFailure('), [
        'const errorText = describeErrorWithStack(error);',
        'this._errorLog.log(`${context}: ${errorText}`, context);',
    ]));

// extension.js: the cockpit client, the layer, the cockpit monitor, the cover per card, the watch and the subscription.
const EXTENSION_SOURCE_FILE = 'extension.js';

/**
 * The statements of a method of extension.js between its declaration and its closing brace, comments removed.
 *
 * @param {string} declarationLine - The method's declaration as it starts its line.
 * @returns {string[]} Its statements, trimmed.
 */
function extensionMethodStatements(declarationLine) {
    return statementsOf(methodBody(readExtensionFile(EXTENSION_SOURCE_FILE), declarationLine)).slice(1, -1);
}

test('extension.js: enable() makes the cockpit client right after the pulse client, with the shared client logger ' +
    'and the layout kept from the last enable, and follows the cockpit (the DisplayConfig reader, the client\'s ' +
    'events, a layer from that layout at once) before starting it', () => {
    const enableStatements = extensionMethodStatements('enable() {');
    const pulseClientIndex = enableStatements.findIndex(statement =>
        statement.startsWith('this._client = new PulseClient('));
    const pulseStartIndex = enableStatements.indexOf('this._client.start();');
    assertEqual({
        cockpitClient: pulseClientIndex < 0 ? null : enableStatements[pulseClientIndex + 1],
        followsThenStarts: pulseStartIndex < 0 ? [] : enableStatements.slice(pulseStartIndex, pulseStartIndex + 3),
        follow: extensionMethodStatements('_followCockpit() {'),
    }, {
        cockpitClient: 'this._cockpitClient = new CockpitClient({errorLog: this._clientLog, ' +
            'cachedLayout: this._lastCockpitLayout});',
        followsThenStarts: ['this._client.start();', 'this._followCockpit();', 'this._cockpitClient.start();'],
        follow: [
            'this._displayConfigReader = new DisplayConfigReader({',
            'errorLog: this._clientLog, onStateRead: displayConfigState => ' +
                'this._onDisplayConfigRead(displayConfigState),',
            '});',
            'this._cockpitListenerId = this._cockpitClient.addListener(event => this._onCockpitClientEvent(event));',
            'this._syncCockpitLayer(false);',
        ],
    });
});

test('extension.js: a cockpit client event adds, removes or rebuilds the layer as cockpitLayerChange says (never the ' +
    'layout that failed in this enable): a removal, then the hold of a hidden v2 card (ruling D21) and the ' +
    'placement, unguarded, with no layer left; else the guarded draw; the v2 card stops following its width while ' +
    'the layer holds it, and is put back top right, following it again, when the layer goes', () =>
    assertEqual({
        onEvent: extensionMethodStatements('_onCockpitClientEvent(event) {'),
        configErrorLogKey: occurrenceCount(codeOf(EXTENSION_SOURCE_FILE),
            "const COCKPIT_CONFIG_ERROR_LOG_KEY = 'could not read the cockpit layout';"),
        sync: extensionMethodStatements('_syncCockpitLayer(isLayoutEvent) {'),
        holdHidden: extensionMethodStatements('_holdHiddenPulseCardFrozen() {'),
        addStopsFollowingTheWidthFirst: extensionMethodStatements('_addCockpitLayer() {')[0],
        addHandsTheCardOver: extensionMethodStatements('_addCockpitLayer() {')
            .includes('cockpitClient: this._cockpitClient, pulseClient: this._client, pulseCard: this._card,'),
        addReadsTheDisplayConfig: extensionMethodStatements('_addCockpitLayer() {').at(-1),
        remove: extensionMethodStatements('_removeCockpitLayer() {'),
        putTopRight: extensionMethodStatements('_putCardTopRight() {'),
    }, {
        onEvent: [
            'const configErrorLine = cockpitConfigErrorLine(event);',
            'if (configErrorLine !== null)',
            'this._clientLog.log(configErrorLine, COCKPIT_CONFIG_ERROR_LOG_KEY);',
            'this._syncCockpitLayer(event.type === CockpitClientEventType.LAYOUT);',
        ],
        configErrorLogKey: 1,
        sync: [
            'const layerChange = this._cockpitLayerChangeNow(isLayoutEvent);',
            'if (layerChange === CockpitLayerChange.REMOVE) {',
            'this._removeCockpitLayer();',
            'this._placeAfterLayerChange();',
            '} else if (layerChange !== CockpitLayerChange.NONE) {',
            'this._drawCockpitLayer(layerChange);',
            '}',
            'return layerChange;',
        ],
        holdHidden: [
            'const isHeldHidden = isPulseCardHeldHidden({',
            'isCockpitLayerShown: this._layer !== null, drawnCardIds: this._layer?.drawnCardIds ?? [],',
            '});',
            'if (isHeldHidden)',
            'this._card.setFrozen(true);',
        ],
        addStopsFollowingTheWidthFirst: 'this._card.disconnectObject(this);',
        addHandsTheCardOver: true,
        addReadsTheDisplayConfig: 'this._displayConfigReader.requestState();',
        remove: [
            'const layer = this._layer;', 'this._layer = null;', 'layer.destroy();', 'this._putCardTopRight();',
        ],
        putTopRight: [
            'this._card.get_parent()?.remove_child(this._card);',
            'Main.layoutManager._backgroundGroup.add_child(this._card);',
            'this._card.clearCellSize();',
            'this._followCardWidth();',
        ],
    }));

test('extension.js: a layer that cannot be built or rebuilt never takes the extension down (ruling D25): the add and ' +
    'the rebuild run in a try whose catch first remembers the client\'s layout for this enable, logs on the error ' +
    'log under a template key, destroys a half-rebuilt layer and puts the v2 card back top right; the add itself ' +
    'lets the layer\'s failure out to that catch', () => {
    const drawStatements = extensionMethodStatements('_drawCockpitLayer(layerChange) {');
    const catchIndex = drawStatements.indexOf('} catch (error) {');
    assertEqual({
        buildInTheTry: drawStatements.slice(0, 5),
        catchFallsBackFirst: catchIndex < 0 ? null : drawStatements[catchIndex + 1],
        fallBack: extensionMethodStatements('_fallBackToTopRightCard(error) {'),
        failureLogKey: occurrenceCount(codeOf(EXTENSION_SOURCE_FILE),
            "const COCKPIT_LAYER_FAILURE_LOG_KEY = 'could not draw the cockpit layer';"),
        add: extensionMethodStatements('_addCockpitLayer() {'),
    }, {
        buildInTheTry: [
            'try {',
            'if (layerChange === CockpitLayerChange.ADD)',
            'this._addCockpitLayer();',
            'else if (layerChange === CockpitLayerChange.REBUILD)',
            'this._layer.setLayout(this._cockpitClient.layout);',
        ],
        catchFallsBackFirst: 'this._fallBackToTopRightCard(error);',
        fallBack: [
            'this._failedCockpitLayout = this._cockpitClient.layout;',
            'const errorText = describeErrorWithStack(error);',
            'this._errorLog.log(`could not draw the cockpit layer, so the card is drawn top right: ${errorText}`,',
            'COCKPIT_LAYER_FAILURE_LOG_KEY);',
            'const layer = this._layer;',
            'this._layer = null;',
            'layer?.destroy();',
            'this._putCardTopRight();',
        ],
        failureLogKey: 1,
        add: [
            'this._card.disconnectObject(this);',
            'this._layer = new CockpitLayer({',
            'cockpitClient: this._cockpitClient, pulseClient: this._client, pulseCard: this._card,',
            'errorLog: this._errorLog, onSessionActivated: sessionId => this._activateSession(sessionId),',
            '});',
            'this._displayConfigReader.requestState();',
        ],
    });
});

test('extension.js: while a layer is shown its hold and its placement, so the cover check over its cards, run inside ' +
    'the build\'s guard: a failure there is a failed build (the fallback), after which they run once more for the v2 ' +
    'card top right, unguarded, so the core\'s own failures are still rethrown (ruling D25)', () => {
    const drawStatements = extensionMethodStatements('_drawCockpitLayer(layerChange) {');
    const rebuildIndex = drawStatements.indexOf('this._layer.setLayout(this._cockpitClient.layout);');
    const catchIndex = drawStatements.indexOf('} catch (error) {');
    const isTryFound = rebuildIndex >= 0 && catchIndex > rebuildIndex;
    assertEqual({
        guardedAfterTheBuild: isTryFound ? drawStatements.slice(rebuildIndex + 1, catchIndex) : null,
        catchAfterTheFallback: isTryFound ? drawStatements.slice(catchIndex + 2) : null,
        placeAfterLayerChange: extensionMethodStatements('_placeAfterLayerChange() {'),
    }, {
        guardedAfterTheBuild: ['this._placeAfterLayerChange();'],
        catchAfterTheFallback: ['this._placeAfterLayerChange();', '}'],
        placeAfterLayerChange: ['this._holdHiddenPulseCardFrozen();', 'this._placeCard();'],
    });
});

test('extension.js: the layer goes on the monitor cockpitMonitorIndexFor chooses from the shell\'s monitors, ' +
    'DisplayConfig\'s last answer and the layout\'s rule, at its work area (getWorkAreaForMonitor); a monitors ' +
    'change forgets that answer, asks again while a layer is shown and places the cards in the coalesced later, as a ' +
    'work-area change and a new answer do; the later never throws out of its callback', () => {
    const extensionCode = codeOf(EXTENSION_SOURCE_FILE);
    const queueStatements = extensionMethodStatements('_queueCardPlacement() {');
    const placeIndex = queueStatements.indexOf('this._placeCardsAgain();');
    assertEqual({
        place: extensionMethodStatements('_placeCockpitLayer() {'),
        onMonitorsChanged: extensionMethodStatements('_onMonitorsChanged() {'),
        onAnswer: extensionMethodStatements('_onDisplayConfigRead(displayConfigState) {'),
        connects: [
            "Main.layoutManager.connectObject('monitors-changed', () => this._onMonitorsChanged(), this);",
            "global.display.connectObject('workareas-changed', () => this._queueCardPlacement(), this);",
        ].map(needle => occurrenceCount(extensionCode, needle)),
        laterGuarded: placeIndex < 1 ? [] : queueStatements.slice(placeIndex - 1, placeIndex + 4),
    }, {
        place: [
            'const monitorIndex = cockpitMonitorIndexFor({',
            'monitors: shellMonitors(),',
            'displayConfigState: this._displayConfigState,',
            'monitorRule: this._layer.layout.monitor,',
            '});',
            'if (monitorIndex === null)',
            'return;',
            'const workArea = Main.layoutManager.getWorkAreaForMonitor(monitorIndex);',
            'this._layer.placeOnMonitor(monitorIndex, workArea);',
        ],
        onMonitorsChanged: [
            'this._displayConfigState = null;', 'if (this._layer !== null)',
            'this._displayConfigReader?.requestState();', 'this._queueCardPlacement();',
        ],
        onAnswer: [
            'this._displayConfigState = displayConfigState;', 'if (this._layer !== null)',
            'this._queueCardPlacement();',
        ],
        connects: [1, 1],
        // Logged, never swallowed in silence.
        laterGuarded: [
            'try {', 'this._placeCardsAgain();', '} catch (error) {',
            'const errorText = describeErrorWithStack(error);',
            'this._errorLog.log(`could not place the cards: ${errorText}`);',
        ],
    });
});

test('extension.js: the layer is decided with the grid\'s fit on its monitor (ruling D36): the work area of the ' +
    'monitor _placeCockpitLayer would choose, drawable when the grid fits it or while DisplayConfig\'s answer could ' +
    'still move it; held back, one warning as that begins, under its own template key, naming the work area', () => {
    const extensionCode = codeOf(EXTENSION_SOURCE_FILE);
    assertEqual({
        decide: extensionMethodStatements('_cockpitLayerChangeNow(isLayoutEvent) {'),
        fit: extensionMethodStatements('_cockpitGridFit(layout) {'),
        note: extensionMethodStatements('_noteCockpitGridHeldBack(isHeldBack, workArea) {'),
        logKey: occurrenceCount(extensionCode,
            "const COCKPIT_GRID_TOO_SMALL_LOG_KEY = 'the cockpit grid needs a larger work area';"),
        noLayoutFit: occurrenceCount(extensionCode,
            'const NO_LAYOUT_GRID_FIT = Object.freeze({workArea: null, isGridDrawable: true});'),
    }, {
        decide: [
            'const clientState = this._cockpitClient.state;',
            'const layout = this._cockpitClient.layout;',
            'const failedLayout = this._failedCockpitLayout;',
            'const {workArea, isGridDrawable} = layout === null ? NO_LAYOUT_GRID_FIT : this._cockpitGridFit(layout);',
            'const isHeldBack = isCockpitGridHeldBack({clientState, layout, failedLayout, isGridDrawable});',
            'this._noteCockpitGridHeldBack(isHeldBack, workArea);',
            'return cockpitLayerChange({',
            'isLayerShown: this._layer !== null, clientState, layout, isLayoutEvent, failedLayout, isGridDrawable,',
            '});',
        ],
        fit: [
            'const monitors = shellMonitors();',
            'const displayConfigState = this._displayConfigState;',
            'const monitorRule = layout.monitor;',
            'const monitorIndex = cockpitMonitorIndexFor({monitors, displayConfigState, monitorRule});',
            'const workArea = monitorIndex === null ? null : Main.layoutManager.getWorkAreaForMonitor(monitorIndex);',
            'const isMonitorChoiceSettled =',
            'isCockpitMonitorChoiceSettled({monitorCount: monitors.length, displayConfigState, monitorRule});',
            'return {workArea, isGridDrawable: isCockpitGridDrawableNow({workArea, isMonitorChoiceSettled})};',
        ],
        note: [
            'if (isHeldBack && !this._isCockpitGridHeldBack)',
            'this._clientLog.log(cockpitGridTooSmallLine(workArea), COCKPIT_GRID_TOO_SMALL_LOG_KEY);',
            'this._isCockpitGridHeldBack = isHeldBack;',
        ],
        logKey: 1,
        noLayoutFit: 1,
    });
});

test('extension.js: every placement the monitors, a work area, DisplayConfig\'s answer or the v2 card\'s width ' +
    'queue decides the layer again first (ruling D36: a dock brings the grid back, an undock puts the card top ' +
    'right); when that changed nothing, a shown layer is placed inside the build\'s guard, so a placement that ' +
    'throws at any time is ruling D25\'s fallback, and the v2 card top right is placed as it always was', () => {
    const extensionCode = codeOf(EXTENSION_SOURCE_FILE);
    assertEqual({
        placeAgain: extensionMethodStatements('_placeCardsAgain() {'),
        placeCardCallers: occurrenceCount(extensionCode, 'this._placeCard();'),
        layerPlacements: occurrenceCount(extensionCode, 'this._placeCockpitLayer();'),
    }, {
        placeAgain: [
            'const layerChange = this._syncCockpitLayer(false);',
            'if (layerChange !== CockpitLayerChange.NONE)',
            'return;',
            'if (this._layer === null)',
            'this._placeCard();',
            'else',
            'this._drawCockpitLayer(CockpitLayerChange.NONE);',
        ],
        // _addCard (no layer yet), _placeAfterLayerChange (inside the guard, or after a removal) and the line above.
        placeCardCallers: 3,
        layerPlacements: 1,
    });
});

test('extension.js: whether the grid is held back by its work area is kept across enables, as the layout is, so its ' +
    'line is not written again at each unlock while it lasts: set in the constructor and by the note alone, never ' +
    'cleared by teardown', () => {
    const extensionCode = codeOf(EXTENSION_SOURCE_FILE);
    assertEqual({
        assignments: occurrenceCount(extensionCode, 'this._isCockpitGridHeldBack ='),
        inTheConstructor: extensionMethodStatements('constructor(metadata) {')
            .includes('this._isCockpitGridHeldBack = false;'),
        inTeardown: extensionMethodStatements('_tearDown() {')
            .some(statement => statement.includes('_isCockpitGridHeldBack')),
    }, {assignments: 2, inTheConstructor: true, inTeardown: false});
});

test('extension.js: the cockpit\'s watch and its subscription get the same answer, isCockpitWatchWanted\'s, from ' +
    'whether a cockpit card is seen, the dropdown and the overview, synced wherever the detail watch is; the detail ' +
    'watch counts a card that draws the sampler\'s snapshot (cockpitSurfacesSeen)', () => {
    const extensionCode = codeOf(EXTENSION_SOURCE_FILE);
    const detailSyncs = occurrenceCount(extensionCode, '\n        this._syncDetailWatch();\n');
    assertEqual({
        cockpitWatch: extensionMethodStatements('_syncCockpitWatch() {'),
        surfaces: extensionMethodStatements('_surfacesSeen() {'),
        detailWatchCountsTheSnapshotCards: extensionMethodStatements('_syncDetailWatch() {').slice(0, 3),
        detailSyncs,
        cockpitSyncRightAfterEach: occurrenceCount(extensionCode,
            '\n        this._syncDetailWatch();\n        this._syncCockpitWatch();\n'),
    }, {
        cockpitWatch: [
            'const {isAnyCockpitCardVisible} = this._surfacesSeen();',
            'const isWanted = isCockpitWatchWanted({',
            'isAnyCockpitCardVisible,',
            'isDropdownOpen: this._isDropdownOpen,',
            'isOverviewVisible: this._isOverviewVisible,',
            '});',
            'this._isCockpitSubscriptionWanted = isWanted;',
            'this._cockpitClient?.setWatchWanted(isWanted);',
            'this._cockpitClient?.setSubscriptionWanted(isWanted);',
        ],
        surfaces: ['return cockpitSurfacesSeen({isCockpitLayerShown: this._layer !== null, visibleCardIds: ' +
            'this._visibleCardIds});'],
        detailWatchCountsTheSnapshotCards: [
            'const {isSnapshotCardVisible} = this._surfacesSeen();', 'const isWanted = isDetailWatchWanted({',
            'isCardVisible: isSnapshotCardVisible,',
        ],
        detailSyncs: 3,
        cockpitSyncRightAfterEach: 3,
    });
});

test('extension.js: every drawn card is checked on its own (cardsCover) against the windows on its monitor (the ' +
    'primary for the v2 card, the cockpit monitor for the layer\'s cards), frozen on its own, and the layer\'s ' +
    'interactivity follows a DESKTOP window showing there (isDesktopInteractive), read in the same pass', () => {
    const extensionCode = codeOf(EXTENSION_SOURCE_FILE);
    const readStatements = extensionMethodStatements('_readCardCover() {');
    assertEqual({
        monitor: extensionMethodStatements('_coverMonitor() {'),
        cards: extensionMethodStatements('_drawnCardRects() {'),
        freezeOne: extensionMethodStatements('_setCardFrozen(cardId, isFrozen) {'),
        readsTheMonitorWindows: readStatements.slice(2, 4),
        interactivity: readStatements.includes('isCockpitInteractive: isDesktopInteractive({windowsOnMonitor: ' +
            'desktopWindows}),'),
        desktopWindowsRead: [
            occurrenceCount(extensionCode, 'desktopWindows.push(desktopWindowOf(metaWindow));'),
            occurrenceCount(extensionCode, 'return {windowType: DESKTOP_WINDOW_TYPE, ' +
                'isShowing: metaWindow.showing_on_its_workspace()};'),
        ],
        desktopWindowTypeRead: occurrenceCount(extensionCode, 'if (windowType === Meta.WindowType.DESKTOP)'),
    }, {
        monitor: [
            'if (this._layer === null)', 'return Main.layoutManager.primaryMonitor ?? null;',
            'return Main.layoutManager.monitors[this._layer.monitorIndex] ?? null;',
        ],
        cards: [
            'if (this._layer !== null)', 'return this._layer.cardRects();',
            'return [{cardId: COCKPIT_SYSTEM_CARD_ID, rect: this._cardRectOnStage()}];',
        ],
        freezeOne: [
            'if (this._layer === null)', 'this._card.setFrozen(isFrozen);', 'else',
            'this._layer.setCardFrozen(cardId, isFrozen);',
        ],
        readsTheMonitorWindows: [
            'const {metaWindows, frameRects: windowRects, desktopWindows} =',
            'monitor ? this._readWindowsOnMonitor(monitor) : NO_WINDOWS_ON_MONITOR;',
        ],
        interactivity: true, desktopWindowsRead: [1, 1], desktopWindowTypeRead: 1,
    });
});

test('extension.js: each tick, after the cover and the frozen repaint, hands the layer its Sample (onSampleTick: the ' +
    'pending sources drawn, the suspect sources pulled) with whether the subscription is wanted', () =>
    assertEqual(extensionMethodStatements('_onCardCoverTick() {').slice(-2), [
        'this._repaintFrozenCardsIfDue();',
        'this._layer?.onSampleTick({isSubscriptionWanted: this._isCockpitSubscriptionWanted});',
    ]));

test('extension.js: a session row\'s click, on the layer\'s card or the dropdown\'s, reaches _activateSession; the ' +
    'indicator is made with the cockpit client and the shared error log', () => {
    const enableStatements = extensionMethodStatements('enable() {');
    const indicatorIndex = enableStatements.indexOf('this._indicator = new PulseIndicator(this._client, {');
    assertEqual({
        handedToTheLayer: extensionMethodStatements('_addCockpitLayer() {')
            .includes('errorLog: this._errorLog, onSessionActivated: sessionId => this._activateSession(sessionId),'),
        handedToTheIndicator: indicatorIndex < 0 ? [] : enableStatements.slice(indicatorIndex, indicatorIndex + 4),
    }, {
        handedToTheLayer: true,
        handedToTheIndicator: [
            'this._indicator = new PulseIndicator(this._client, {',
            'cockpitClient: this._cockpitClient, errorLog: this._errorLog,',
            'onSessionActivated: sessionId => this._activateSession(sessionId),',
            '});',
        ],
    });
});

// extension.js: the click's one action (Task 10). FocusSession through the cockpit client, then at most one
// Main.activateWindow. Glue: these rows read it.

/** The click's entry, which both cards' rows call. */
const ACTIVATE_SESSION_DECLARATION = '_activateSession(sessionId) {';
/** The activation itself, asynchronous: FocusSession, then the window. */
const FOCUS_THEN_ACTIVATE_DECLARATION = 'async _focusSessionThenActivateWindow(sessionId) {';
/** The step that acts on the cockpit service's answer. */
const ACTIVATE_WINDOW_DECLARATION = '_activateWindowForFocusReply(focusReply) {';
/** The module function that reads the windows as lib/cockpitInteraction.js pickWindowToActivate takes them. */
const ACTIVATABLE_WINDOWS_DECLARATION = 'function activatableWindowsByStacking() {';
/** The statement that awaits the cockpit service's answer. */
const FOCUS_SESSION_AWAIT_STATEMENT = 'const focusReply = await cockpitClient.focusSession(sessionId);';
/** The call whose first statement reads the windows. */
const WINDOWS_READ_CALL_STATEMENT = 'this._activateWindowForFocusReply(focusReply);';
/** The try statement around the answer, and its catch and finally, as they open their lines. */
const TRY_OPENING_LINE = 'try {';
const CATCH_OPENING_LINE = '} catch (error) {';
const FINALLY_OPENING_LINE = '} finally {';
/** What a statement line that closes a block starts with. */
const BLOCK_CLOSING_PREFIX = '}';
/**
 * Calls that would bring a window forward on the shell side: the shell's own activation (Main.activateWindow), a
 * workspace's (activate_with_focus), an app's for one of its windows (Shell.App.activate_window), Mutter's own
 * (Meta.Window.activate, which Main.activateWindow calls; the same needle matches Shell.App.activate, whose one use is
 * cockpitCards.js openResourcesApp's), and a window's focus, raise and unminimize.
 */
const WINDOW_ACTIVATION_CALL_NEEDLES = [
    'activateWindow(', 'activate_with_focus(', 'activate_window(', '.activate(', '.unminimize(', '.raise(', '.focus(',
];
/** The shell side's directory beside the top level (service/ is the services'). */
const LIB_DIRECTORY_NAME = 'lib';
const JAVASCRIPT_SUFFIX = '.js';
/** The method names of the cockpit service's D-Bus interface. */
const COCKPIT_SERVICE_METHOD_NAMES = [
    COCKPIT_GET_STATE_METHOD_NAME, COCKPIT_WATCH_METHOD_NAME, COCKPIT_UNWATCH_METHOD_NAME,
    COCKPIT_FOCUS_SESSION_METHOD_NAME,
];
/** A class prototype's own property that is not one of its members. */
const CONSTRUCTOR_PROPERTY_NAME = 'constructor';
/** Review Focus 3's bound: at most one journal line a minute. */
const MICROSECONDS_PER_MINUTE = 60_000_000;

/**
 * The JavaScript files of one directory of the extension, by name.
 *
 * @param {string} directoryPath - The directory's absolute path.
 * @returns {string[]} The names of its .js files, sorted.
 */
function javaScriptFileNamesIn(directoryPath) {
    const enumerator = Gio.File.new_for_path(directoryPath)
        .enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null);
    const fileNames = [];
    for (let fileInfo = enumerator.next_file(null); fileInfo !== null; fileInfo = enumerator.next_file(null)) {
        if (fileInfo.get_name().endsWith(JAVASCRIPT_SUFFIX))
            fileNames.push(fileInfo.get_name());
    }
    enumerator.close(null);
    return fileNames.sort();
}

/**
 * The shell side's files, relative to the extension directory: every .js file at its top level and in lib/ (which
 * also holds a few modules only the services import; none of them may activate a window either).
 *
 * @returns {string[]} The relative paths.
 */
function shellSideFileNames() {
    const libDirectoryPath = GLib.build_filenamev([EXTENSION_DIRECTORY_PATH, LIB_DIRECTORY_NAME]);
    const libFileNames = javaScriptFileNamesIn(libDirectoryPath)
        .map(fileName => `${LIB_DIRECTORY_NAME}/${fileName}`);
    return [...javaScriptFileNamesIn(EXTENSION_DIRECTORY_PATH), ...libFileNames];
}

/**
 * The activation's statements (_focusSessionThenActivateWindow), comments removed, between its declaration and its
 * closing brace.
 *
 * @returns {string[]} Its statements, trimmed; none when it is not declared as asynchronous.
 */
function activationStatements() {
    return extensionMethodStatements(FOCUS_THEN_ACTIVATE_DECLARATION);
}

test('extension.js: one activation at a time: a click while one is in flight does nothing; otherwise ' +
    '_activateSession marks one in flight, starts it and returns nothing, and the activation clears the mark in ' +
    'its finally, unless teardown has (it was asked of a cockpit client since replaced), so an earlier activation ' +
    'never clears a later one\'s mark', () => {
    const statements = activationStatements();
    const finallyIndex = statements.indexOf(FINALLY_OPENING_LINE);
    assertEqual({
        activate: extensionMethodStatements(ACTIVATE_SESSION_DECLARATION),
        finally: finallyIndex < 0 ? [] : statements.slice(finallyIndex),
    }, {
        activate: [
            'if (this._isActivationInFlight)', 'return;', 'this._isActivationInFlight = true;',
            'this._focusSessionThenActivateWindow(sessionId);',
        ],
        finally: [
            FINALLY_OPENING_LINE, 'if (cockpitClient === this._cockpitClient)', 'this._isActivationInFlight = false;',
            '}',
        ],
    });
});

// The activation's body is pinned whole by four rows, so the answer is used inside the try only: before the try and
// the try's first statement (this row), the rest of the try (the stale-answer row), the catch (the failure row), and
// the finally to the end (the one-at-a-time row).
test('extension.js: the activation\'s one statement before its try captures the cockpit client it is started with, ' +
    'and the try\'s first statement awaits FocusSession from that client', () => {
    const statements = activationStatements();
    const tryIndex = statements.indexOf(TRY_OPENING_LINE);
    const isTryFound = tryIndex >= 0;
    assertEqual({
        beforeTheTry: isTryFound ? statements.slice(0, tryIndex) : null,
        firstInTheTry: isTryFound ? statements[tryIndex + 1] : null,
    }, {
        beforeTheTry: ['const cockpitClient = this._cockpitClient;'],
        firstInTheTry: FOCUS_SESSION_AWAIT_STATEMENT,
    });
});

test('extension.js: a failure in the activation is one journal line on the error log, rate-limited by its template ' +
    'key, never a throw into the click handler (ruling D25)', () => {
    const statements = activationStatements();
    const catchIndex = statements.indexOf(CATCH_OPENING_LINE);
    // The catch block ends at the next line that closes a block: the finally's opening, or the try's own end.
    const catchEndIndex = statements.findIndex((statement, statementIndex) =>
        statementIndex > catchIndex && statement.startsWith(BLOCK_CLOSING_PREFIX));
    assertEqual({
        catch: catchIndex < 0 || catchEndIndex < 0 ? null : statements.slice(catchIndex, catchEndIndex),
        failureLogKey: occurrenceCount(codeOf(EXTENSION_SOURCE_FILE),
            "const SESSION_ACTIVATION_FAILURE_LOG_KEY = 'could not activate a session';"),
    }, {
        catch: [
            CATCH_OPENING_LINE, 'const errorText = describeErrorWithStack(error);',
            'this._errorLog.log(`could not activate a session: ${errorText}`, SESSION_ACTIVATION_FAILURE_LOG_KEY);',
        ],
        failureLogKey: 1,
    });
});

test('extension.js: an answer that comes after disable(), or after a later enable(), does nothing, and an answer is ' +
    'used only to bring its window forward: from the await to the try\'s end, the activation returns unless the ' +
    'cockpit client it asked is still the extension\'s, then hands the answer to the call that reads the windows, ' +
    'and does nothing more', () => {
    const statements = activationStatements();
    const answerIndex = statements.indexOf(FOCUS_SESSION_AWAIT_STATEMENT);
    // The try's block ends at the next line that closes a block: the catch's opening, or the finally's without one.
    const tryEndIndex = statements.findIndex((statement, statementIndex) =>
        statementIndex > answerIndex && statement.startsWith(BLOCK_CLOSING_PREFIX));
    const isOrdered = answerIndex >= 0 && tryEndIndex > answerIndex;
    assertEqual(isOrdered ? statements.slice(answerIndex + 1, tryEndIndex) : null,
        ['if (cockpitClient !== this._cockpitClient)', 'return;', WINDOWS_READ_CALL_STATEMENT]);
});

test('extension.js: the answer goes through lib/cockpitInteraction.js as it is: the windows read first, then ' +
    'pickWindowToActivate among the reply\'s candidate pids, then focusSessionOutcome on the reply and pick', () =>
    assertEqual(extensionMethodStatements(ACTIVATE_WINDOW_DECLARATION).slice(0, 3), [
        'const {metaWindows, windows} = activatableWindowsByStacking();',
        'const pickedStackIndex = pickWindowToActivate({windows, candidatePids: focusReply.windowPidCandidates});',
        'const focusOutcome = focusSessionOutcome({reply: focusReply, pickedStackIndex});',
    ]));

test('extension.js: the outcome is acted on as given: the picked window brought forward by Main.activateWindow ' +
    '(it switches to the window\'s workspace, unminimizes and raises it, ending show-desktop), else the outcome\'s ' +
    'line logged as a warning under the template key the outcome gave, one per reason (ruling D32)', () =>
    assertEqual(extensionMethodStatements(ACTIVATE_WINDOW_DECLARATION).slice(3), [
        'if (focusOutcome.activateWindow)', 'Main.activateWindow(metaWindows[pickedStackIndex]);', 'else',
        'this._clientLog.log(focusOutcome.logLine, focusOutcome.logTemplateKey);',
    ]));

test('lib/constants.js: each of the outcome\'s template keys gives at most one line a minute (Review Focus 3, per ' +
    'reason): ERROR_LOG_REPEAT_INTERVAL_USEC is at least a minute', () =>
    assertEqual(ERROR_LOG_REPEAT_INTERVAL_USEC >= MICROSECONDS_PER_MINUTE, true));

test('extension.js: the windows are read as pickWindowToActivate takes them: the display\'s normal and dialog ' +
    'windows (never an override-redirect one, which Mutter neither activates nor stacks), sorted by stacking bottom ' +
    'first so each one\'s index is its stackIndex, each with its pid, whether it is on the active workspace or on ' +
    'all, and whether it is minimized', () =>
    assertEqual({
        read: extensionMethodStatements(ACTIVATABLE_WINDOWS_DECLARATION),
        windowTypes: occurrenceCount(codeOf(EXTENSION_SOURCE_FILE),
            'const ACTIVATABLE_WINDOW_TYPES = new Set([Meta.WindowType.NORMAL, Meta.WindowType.DIALOG]);'),
    }, {
        read: [
            'const activeWorkspace = global.workspace_manager.get_active_workspace();',
            'const activatableWindows = global.display.list_all_windows()',
            '.filter(metaWindow => ACTIVATABLE_WINDOW_TYPES.has(metaWindow.get_window_type()));',
            'const metaWindows = global.display.sort_windows_by_stacking(activatableWindows);',
            'const windows = metaWindows.map((metaWindow, stackIndex) => ({',
            'pid: metaWindow.get_pid(),',
            'stackIndex,',
            'isOnActiveWorkspace: metaWindow.is_on_all_workspaces() || ' +
                'metaWindow.get_workspace() === activeWorkspace,',
            'isMinimized: metaWindow.minimized,',
            '}));',
            'return {metaWindows, windows};',
        ],
        windowTypes: 1,
    }));

// The one .activate( this row allows in cockpitCards.js is openResourcesApp's: visibility.test.js's "Open Resources"
// row pins resourcesApp.activate() in openResourcesApp's body (launchActivates), and this row allows no second one.
test('extension.js: Main.activateWindow is the shell side\'s one call that brings a window forward: exactly one, ' +
    'in extension.js, and no file outside service/ otherwise activates (Meta.Window.activate included), focuses, ' +
    'raises or unminimizes one; the one other activation is cockpitCards.js openResourcesApp\'s ' +
    'resourcesApp.activate(), which launches or raises the Resources app', () => {
    const activationCallsByFile = {};
    for (const fileName of shellSideFileNames()) {
        const code = codeOf(fileName);
        const callCounts = WINDOW_ACTIVATION_CALL_NEEDLES
            .map(needle => [needle, occurrenceCount(code, needle)])
            .filter(([, callCount]) => callCount > 0);
        if (callCounts.length > 0)
            activationCallsByFile[fileName] = Object.fromEntries(callCounts);
    }
    assertEqual(activationCallsByFile, {'cockpitCards.js': {'.activate(': 1}, 'extension.js': {'activateWindow(': 1}});
});

test('extension.js: a click asks the cockpit service for FocusSession and nothing else: the activation uses no ' +
    'member of the cockpit client but focusSession, and names none of the service\'s D-Bus methods', () => {
    const extensionSource = readExtensionFile(EXTENSION_SOURCE_FILE);
    const handlerBodies = [
        ACTIVATE_SESSION_DECLARATION, FOCUS_THEN_ACTIVATE_DECLARATION, ACTIVATE_WINDOW_DECLARATION,
        ACTIVATABLE_WINDOWS_DECLARATION,
    ].map(declarationLine => methodBody(extensionSource, declarationLine));
    const handlerText = handlerBodies.join('\n');
    const clientMemberNames = Object.getOwnPropertyNames(CockpitClient.prototype)
        .filter(propertyName => propertyName !== CONSTRUCTOR_PROPERTY_NAME);
    assertEqual({
        // Every part read, so a part renamed away cannot hide a call.
        partsRead: handlerBodies.filter(bodyText => bodyText !== '').length,
        clientMembersUsed: clientMemberNames.filter(memberName => new RegExp(`\\.${memberName}\\b`).test(handlerText)),
        serviceMethodsNamed: COCKPIT_SERVICE_METHOD_NAMES.filter(methodName =>
            new RegExp(`\\b${methodName}\\b`).test(handlerText)),
    }, {
        partsRead: 4,
        clientMembersUsed: ['focusSession'],
        serviceMethodsNamed: [],
    });
});

test('extension.js: teardown keeps the layout to cache before anything is destroyed, clears the cockpit\'s fields ' +
    '(the layout that failed included, so each enable tries again, and the activation in flight, so the next ' +
    'enable\'s first click is taken), removes the cockpit client listener, cancels the DisplayConfig read and ' +
    'destroys the layer first', () => {
    const tearDownStatements = extensionMethodStatements('_tearDown() {');
    const clearedFields = [
        'this._layer = null;', 'this._cockpitClient = null;', 'this._displayConfigReader = null;',
        'this._displayConfigState = null;', 'this._cockpitListenerId = null;', 'this._failedCockpitLayout = null;',
        'this._visibleCardIds = VISIBLE_CARD_IDS_BEFORE_COVER_CHECK;', 'this._frozenCardPaintedAtUsecByCardId = {};',
        'this._isCockpitSubscriptionWanted = false;', 'this._isActivationInFlight = false;',
    ];
    const firstDestroyIndex = tearDownStatements.findIndex(statement => statement.includes('?.destroy()'));
    const layerDestroyIndex =
        tearDownStatements.indexOf('{name: \'destroy the cockpit layer\', run: () => layer?.destroy()},');
    const cardDestroyIndex = tearDownStatements.indexOf('{name: \'destroy the card\', run: () => card?.destroy()},');
    assertEqual({
        cleared: clearedFields.map(field => tearDownStatements.filter(statement => statement === field).length),
        listenerRemoved: tearDownStatements.includes('cockpitClient?.removeListener(cockpitListenerId);'),
        firstDestroy: tearDownStatements[firstDestroyIndex],
        layerBeforeTheCard: layerDestroyIndex >= 0 && layerDestroyIndex < cardDestroyIndex,
    }, {
        cleared: clearedFields.map(() => 1),
        listenerRemoved: true,
        firstDestroy: '{name: \'cancel the display config read\', run: () => displayConfigReader?.destroy()},',
        layerBeforeTheCard: true,
    });
});

// indicator.js: the sessions card in the top-bar dropdown (a second copy, live while the menu is open).

/**
 * The statements of a method of indicator.js between its declaration and its closing brace, comments removed.
 *
 * @param {string} declarationLine - The method's declaration as it starts its line.
 * @returns {string[]} Its statements, trimmed.
 */
function indicatorMethodStatements(declarationLine) {
    return statementsOf(methodBody(readExtensionFile(INDICATOR_SOURCE_FILE), declarationLine)).slice(1, -1);
}

/** The open step's statement that gives the sessions card the system card's width (ruling D29). */
const SIZE_TO_SYSTEM_CARD_STATEMENT = 'this._sizeSessionsCardToSystemCard();';
/** The indicator's constructor: the pulse client, then the cockpit's options (the dropdown's sessions card). */
const INDICATOR_INIT_DECLARATION = '_init(client, {cockpitClient, errorLog, onSessionActivated}) {';
/** A statement that puts an item into the indicator's menu: an add method of the menu, or a child of its box. */
const MENU_ADDITION_PATTERN = /\bthis\.menu\.(?:add\w*|box\.(?:add|insert)\w*)\(/;

test('indicator.js: takes the pulse client, then one options object (the cockpit client, the shared error log and ' +
    'the session activation), and sets every new field _onDestroy reads before anything can throw', () => {
    const initStatements = indicatorMethodStatements(INDICATOR_INIT_DECLARATION);
    const firstThrowingIndex = initStatements.indexOf('const graphBox = new St.BoxLayout({style_class: ' +
        'GRAPH_BOX_STYLE_CLASS});');
    const earlyFields = [
        'this._cockpitClient = cockpitClient;', 'this._errorLog = errorLog;',
        'this._activateSessionInExtension = onSessionActivated;', 'this._sessionsItem = null;',
        'this._sessionsCard = null;', 'this._sessionsTooltip = null;', 'this._sessionsPacing = null;',
        'this._cockpitListenerId = null;',
    ];
    assertEqual(earlyFields.map(field => {
        const fieldIndex = initStatements.indexOf(field);
        return fieldIndex >= 0 && fieldIndex < firstThrowingIndex;
    }), earlyFields.map(() => true));
});

test('indicator.js: the sessions item is added last in _init, after every step that can throw (it adds its tooltip ' +
    'to the chrome), and goes into the menu right under the system card\'s item, which is the menu\'s first (the ' +
    'menu\'s only additions: the system card\'s item, "Open Resources", then the sessions item at position 1); it is ' +
    'built under a guard (ruling D25): a failure first destroys whatever was half-built, then is logged, and the ' +
    'item is left out, so the dropdown is v2\'s', () =>
    assertEqual({
        lastInInit: indicatorMethodStatements(INDICATOR_INIT_DECLARATION).at(-1),
        menuAdditions: statementsOf(codeOf(INDICATOR_SOURCE_FILE))
            .filter(statement => MENU_ADDITION_PATTERN.test(statement)),
        positionUnderTheCardItem: occurrenceCount(codeOf(INDICATOR_SOURCE_FILE),
            'const SESSIONS_ITEM_MENU_POSITION = 1;'),
        guard: indicatorMethodStatements('_addSessionsItem() {'),
    }, {
        lastInInit: 'this._addSessionsItem();',
        menuAdditions: [
            'this.menu.addMenuItem(cardItem);',
            'this.menu.addMenuItem(this._openResourcesItem);',
            'this.menu.addMenuItem(this._sessionsItem, SESSIONS_ITEM_MENU_POSITION);',
        ],
        positionUnderTheCardItem: 1,
        guard: [
            'try {',
            'this._buildSessionsItem();',
            '} catch (error) {',
            'this._destroySessionsItem();',
            "this._logCockpitFailure('be built, so the dropdown shows the system card alone', error);",
            '}',
        ],
    }));

test('indicator.js: the sessions item is a non-reactive, unfocusable PopupBaseMenuItem of class ' +
    'rp-cockpit-menu-sessions-item holding a SessionsCockpitCard with its own CockpitTooltip, whose row click ' +
    'reaches _onSessionActivated; the card is interactive (the menu is above every window) and frozen at build, ' +
    'paced by its own CockpitSourcePacing of the one sessions card, the item\'s visibility synced, and the client ' +
    'listener added last', () => {
    const code = codeOf(INDICATOR_SOURCE_FILE);
    assertEqual({
        build: indicatorMethodStatements('_buildSessionsItem() {'),
        constants: [
            "const SESSIONS_ITEM_STYLE_CLASS = 'rp-cockpit-menu-sessions-item';",
            'const SESSIONS_ITEM_PROPERTIES = {reactive: false, can_focus: false, style_class: ' +
                'SESSIONS_ITEM_STYLE_CLASS};',
            'const DROPDOWN_COCKPIT_CARD_IDS = Object.freeze([COCKPIT_SESSIONS_CARD_ID]);',
            "const PACING_SURFACE_NAME = 'the dropdown';",
        ].map(needle => occurrenceCount(code, needle)),
    }, {
        build: [
            'this._sessionsTooltip = new CockpitTooltip();',
            'this._sessionsCard = new SessionsCockpitCard({',
            'tooltip: this._sessionsTooltip, onRowActivated: sessionId => this._onSessionActivated(sessionId),',
            '});',
            'this._sessionsCard.setInteractive(true);',
            'this._sessionsCard.setFrozen(true);',
            'this._sessionsItem = new PopupMenu.PopupBaseMenuItem(SESSIONS_ITEM_PROPERTIES);',
            'this._sessionsItem.add_child(this._sessionsCard);',
            'this.menu.addMenuItem(this._sessionsItem, SESSIONS_ITEM_MENU_POSITION);',
            'this._sessionsPacing = new CockpitSourcePacing({',
            'cockpitClient: this._cockpitClient, drawnCardIds: () => DROPDOWN_COCKPIT_CARD_IDS,',
            'drawCard: () => this._drawSessionsCard(), errorLog: this._errorLog, surfaceName: PACING_SURFACE_NAME,',
            '});',
            'this._syncSessionsItemVisibility();',
            'this._cockpitListenerId = this._cockpitClient.addListener(event => this._onCockpitEvent(event));',
        ],
        constants: [1, 1, 1, 1],
    });
});

test('indicator.js: the item is shown only once the cockpit has answered (ruling D23: isDropdownSessionsItemShown of ' +
    'the client\'s state), synced at build and on each state event; while the menu is open every event goes to the ' +
    'pacing (a read drawn at once, a Changed on the next Sample), while it is closed none; never thrown into the ' +
    'client\'s listener loop', () =>
    assertEqual({
        visibility: indicatorMethodStatements('_syncSessionsItemVisibility() {'),
        onEvent: indicatorMethodStatements('_onCockpitEvent(event) {'),
    }, {
        visibility: ['this._sessionsItem.visible = isDropdownSessionsItemShown(this._cockpitClient.state);'],
        onEvent: [
            "this._runCockpitStep('follow a cockpit event', () => {",
            'if (event.type === CockpitClientEventType.STATE)',
            'this._syncSessionsItemVisibility();',
            'if (this.menu.isOpen)',
            'this._sessionsPacing.onCockpitEvent(event);',
            '});',
        ],
    }));

test('indicator.js: opening the menu draws the sessions card from what the cockpit client holds, then unfreezes it ' +
    '(the latest at once, drawn once, waiting for no event); closing forgets what its pacing holds (the pending ' +
    'sources, the fallback), freezes it and hides its tooltip; each guarded, and nothing without the card', () => {
    const openStateStatements = indicatorMethodStatements('_onMenuOpenStateChanged(isOpen) {');
    assertEqual({
        followsTheSystemCard: openStateStatements.slice(0, 2),
        follow: indicatorMethodStatements('_followMenuWithSessionsCard(isOpen) {'),
        // The card's width (SIZE_TO_SYSTEM_CARD_STATEMENT) is the next row's.
        open: indicatorMethodStatements('_showLatestSessions() {')
            .filter(statement => statement !== SIZE_TO_SYSTEM_CARD_STATEMENT),
        close: indicatorMethodStatements('_freezeSessionsCard() {'),
        draw: indicatorMethodStatements('_drawSessionsCard() {'),
    }, {
        followsTheSystemCard: ['this._dropdownCard.setFrozen(!isOpen);', 'this._followMenuWithSessionsCard(isOpen);'],
        follow: [
            'if (this._sessionsCard === null)',
            'return;',
            'if (isOpen)',
            "this._runCockpitStep('be drawn as the menu opens', () => this._showLatestSessions());",
            'else',
            "this._runCockpitStep('be frozen as the menu closes', () => this._freezeSessionsCard());",
        ],
        open: ['this._drawSessionsCard();', 'this._sessionsCard.setFrozen(false);'],
        close: [
            'this._sessionsPacing.reset();', 'this._sessionsCard.setFrozen(true);', 'this._sessionsTooltip.hide();',
        ],
        draw: [
            'drawCockpitDataCard({',
            'cardId: COCKPIT_SESSIONS_CARD_ID, card: this._sessionsCard, cockpitClient: this._cockpitClient,',
            '});',
        ],
    });
});

test('indicator.js: as the menu opens, before the sessions card is drawn, it takes the system card\'s preferred ' +
    '(natural) width, which the stylesheet gives it (ruling D29: the cards line up, a long name ellipsizes at that ' +
    'width, the rows\' bars get a track), not its allocated width, which the opening menu has not laid out yet; a ' +
    'width only (setCardWidth): nothing in the indicator sets a cockpit card\'s height or size', () => {
    const indicatorCode = codeOf(INDICATOR_SOURCE_FILE);
    const openStatements = indicatorMethodStatements('_showLatestSessions() {');
    const sizeIndex = openStatements.indexOf(SIZE_TO_SYSTEM_CARD_STATEMENT);
    assertEqual({
        sizedBeforeTheDraw: sizeIndex >= 0 && sizeIndex < openStatements.indexOf('this._drawSessionsCard();'),
        size: indicatorMethodStatements('_sizeSessionsCardToSystemCard() {'),
        unconstrainedHeight: occurrenceCount(indicatorCode, 'const UNCONSTRAINED_HEIGHT = -1;'),
        heightOrSizeSet: ['set_height(', 'set_size(', 'setCellSize('].filter(needle => indicatorCode.includes(needle)),
    }, {
        sizedBeforeTheDraw: true,
        size: [
            'const [, systemCardNaturalWidthPx] = this._dropdownCard.get_preferred_width(UNCONSTRAINED_HEIGHT);',
            'this._sessionsCard.setCardWidth(systemCardNaturalWidthPx);',
        ],
        unconstrainedHeight: 1,
        heightOrSizeSet: [],
    });
});

test('indicator.js: each Sample (the indicator\'s history listener) ends, after the graphs and the hover label, with ' +
    'the dropdown\'s share: while the menu is open, its pacing\'s onSample with the subscription wanted (what ' +
    'waits drawn, the sessions source pulled on suspicion); nothing while it is closed; guarded', () =>
    assertEqual({
        lastOfTheTick: indicatorMethodStatements('_onHistoriesChanged() {').at(-1),
        sample: indicatorMethodStatements('_onCockpitSample() {'),
        wantedWhileOpen: occurrenceCount(codeOf(INDICATOR_SOURCE_FILE),
            'const IS_COCKPIT_SUBSCRIPTION_WANTED_WHILE_OPEN = true;'),
    }, {
        lastOfTheTick: 'this._onCockpitSample();',
        sample: [
            'if (this._sessionsPacing === null || !this.menu.isOpen)',
            'return;',
            "this._runCockpitStep('take its Sample', () =>",
            'this._sessionsPacing.onSample({isSubscriptionWanted: IS_COCKPIT_SUBSCRIPTION_WANTED_WHILE_OPEN}));',
        ],
        wantedWhileOpen: 1,
    }));

test('indicator.js: a session row\'s click closes the menu first, as an activated menu item does (itemActivated: ' +
    'the stock fade, ruling D30; the menu\'s state and its grab change at once), then asks the extension to activate ' +
    'the session (Review Focus 3: the menu closes whatever the activation does); each step guarded, so neither ' +
    'throws into the row\'s click handler and a failed close still activates; a failure is logged by its own ' +
    'context', () =>
    assertEqual({
        activated: indicatorMethodStatements('_onSessionActivated(sessionId) {'),
        guard: indicatorMethodStatements('_runCockpitStep(stepName, step) {'),
        log: indicatorMethodStatements('_logCockpitFailure(stepName, error) {'),
    }, {
        activated: [
            "this._runCockpitStep('close the menu for a session', () => this.menu.itemActivated());",
            "this._runCockpitStep('activate a session', () => this._activateSessionInExtension(sessionId));",
        ],
        guard: ['try {', 'step();', '} catch (error) {', 'this._logCockpitFailure(stepName, error);', '}'],
        log: [
            "const context = `the dropdown's sessions card could not ${stepName}`;",
            'const errorText = describeErrorWithStack(error);',
            'this._errorLog.log(`${context}: ${errorText}`, context);',
        ],
    }));

test('indicator.js: destroying the indicator removes the dropdown\'s cockpit part after the history listener and ' +
    'before the system card, its fields cleared first, each step guarded, in an order that never calls into a ' +
    'destroyed actor: the cockpit listener, the pacing (its fallback), the card, the item, last the tooltip', () => {
    const destroyStatements = indicatorMethodStatements('_onDestroy() {');
    const teardownStatements = indicatorMethodStatements('_destroySessionsItem() {');
    const stepsIndex = teardownStatements.indexOf('runEveryStep([');
    const clearedFields = [
        'this._cockpitListenerId = null;', 'this._sessionsPacing = null;', 'this._sessionsCard = null;',
        'this._sessionsItem = null;', 'this._sessionsTooltip = null;',
    ];
    const sessionsTeardownIndex = destroyStatements.indexOf('this._destroySessionsItem();');
    assertEqual({
        afterTheHistoryListener: sessionsTeardownIndex > destroyStatements.indexOf(
            'this._client.removeHistoryListener(this._historyListenerId);'),
        beforeTheSystemCard: sessionsTeardownIndex >= 0 &&
            sessionsTeardownIndex < destroyStatements.indexOf('this._dropdownCard?.destroy();'),
        clearedFirst: clearedFields.map(field => {
            const fieldIndex = teardownStatements.indexOf(field);
            return fieldIndex >= 0 && fieldIndex < stepsIndex;
        }),
        steps: teardownStatements.filter(statement => statement.startsWith('{name: ')),
        reported: teardownStatements.at(-1),
    }, {
        afterTheHistoryListener: true, beforeTheSystemCard: true, clearedFirst: clearedFields.map(() => true),
        steps: [
            "{name: 'remove the cockpit listener', run: () => this._cockpitClient.removeListener(cockpitListenerId)},",
            "{name: 'destroy the pacing', run: () => sessionsPacing?.destroy()},",
            "{name: 'destroy the card', run: () => sessionsCard?.destroy()},",
            "{name: 'destroy the item', run: () => sessionsItem?.destroy()},",
            "{name: 'destroy the tooltip', run: () => sessionsTooltip?.destroy()},",
        ],
        reported: '], (stepName, error) => this._logCockpitFailure(stepName, error));',
    });
});
