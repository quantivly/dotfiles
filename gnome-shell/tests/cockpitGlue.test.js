// The cockpit's Shell glue (cockpitTooltip.js, cockpitCards.js, and the layer that follows) imports the Shell, so
// plain gjs cannot run it. These rows read its source and the stylesheet as text, and pin the constants it draws with.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {
    COCKPIT_ICON_NAMES, COCKPIT_LONG_IDLE_ROW_OPACITY, COCKPIT_ROW_ICON_SIZE_PX,
} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

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
const RELATIVE_SPECIFIER_PREFIX = './';
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

test('cockpitCards.js: no St.DrawingArea or cairo: the bar is a widget whose width is its fraction of the track, ' +
    'whose width is a share of the cell\'s; the bar is set only when its width changed', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    const setCellSizeBody = cardMethodBody('CockpitCardBase', 'setCellSize(');
    assertEqual({
        drawingAreas: occurrenceCount(source, 'DrawingArea'),
        cairoContexts: occurrenceCount(source, 'get_context('),
        bar: occurrenceCount(cardMethodBody('CockpitCardBase', '_buildRow('), 'bar: new St.Widget({'),
        showRowBar: statementsOf(cardMethodBody('CockpitCardBase', '_showRowBar(')),
        trackFromTheCell: occurrenceCount(setCellSizeBody,
            'const barTrackWidthPx = Math.round(widthPx * COCKPIT_ROW_BAR_TRACK_SHARE_OF_CELL_WIDTH);'),
        cellSized: occurrenceCount(setCellSizeBody, 'this.set_size(widthPx, heightPx);'),
        tracksResized: occurrenceCount(setCellSizeBody, 'row.barTrack.set_width(barTrackWidthPx);'),
        barsRedrawn: occurrenceCount(setCellSizeBody, 'this._showRowBar(row);'),
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
        trackFromTheCell: 1, cellSized: 1, tracksResized: 1, barsRedrawn: 1,
    });
});

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

test('cockpitCards.js: each card\'s update takes exactly what it draws, with no clock (ruling D9); a source it ' +
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
        updateDeclarations: ['update(snapshot, lastGoodClockLabel) {', 'update(apps) {', 'update(network, mounts) {',
            'update(sessions) {'],
        clocks: 0,
        dataCardUpdates: [
            ['update(apps) {', ...noDataBranch('if (!canDrawApps(apps)) {'),
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
        connectionContent: ['iconName: connectionRow.icon,', 'name: connectionRow.text,',
            'fraction: connectionRow.fraction,', 'tooltipLines: connectionRow.tooltip,']
            .map(field => occurrenceCount(methodBody(source, 'function connectionRowContent('), field)),
    }, {
        title: 1, overflowLabelBelowTheRows: true, overflowLabelAdded: [1, 1], rowsAndOverflow: 1, overflowDrawn: 1,
        cutInTheCard: 0, connectionContent: [1, 1, 1, 1],
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
        baseRedirects: occurrenceCount(classBody(source, 'CockpitCardBase'),
            'this.set_offscreen_redirect(Clutter.OffscreenRedirect.ALWAYS);'),
    }, {paintVfuncs: 0, offscreenRedirectUses: 1, offscreenRedirectPropertyUses: 0, baseRedirects: 1});
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
    assertEqual({
        relativeSpecifiers,
        indicatorImportsThem: occurrenceCount(readExtensionFile(INDICATOR_SOURCE_FILE),
            "\nimport {findResourcesApp, openResourcesApp} from './cockpitCards.js';\n"),
        indicatorCopies: ['_findResourcesApp', '_openResources()', 'Shell.AppSystem', 'lookup_app(']
            .filter(needle => indicatorCode.includes(needle)),
    }, {
        relativeSpecifiers: ['./lib/constants.js', './lib/cockpitFormat.js', './lib/cockpitProtocol.js'],
        indicatorImportsThem: 1,
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
            'this._cockpitListenerId = cockpitClient.addListener(event => this._onCockpitEvent(event));',
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
    }));

test('cockpitLayer.js: a layout change keeps the cards it still names (never remade for a re-placement), destroys ' +
    'those it no longer names and makes only the missing ones, each taking the layer\'s interactivity, which ' +
    'setInteractive forwards to every card on a change; cards are made for exactly COCKPIT_DRAWN_CARD_IDS', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    const syncStatements = layerMethodStatements('_syncCards(');
    const makersBlock = source.split('const CARD_MAKERS_BY_ID = Object.freeze({')[1]?.split('\n});')[0] ?? '';
    assertEqual({
        keeps: syncStatements.slice(1, 3),
        destroysTheRest: syncStatements.includes('card.destroy();'),
        makesTheMissing: syncStatements.slice(-3),
        added: layerMethodStatements('_addCard(').slice(-2),
        setInteractive: layerMethodStatements('setInteractive('),
        makerIds: [...makersBlock.matchAll(/^ {4}(\w+): /gm)].map(([, cardId]) => cardId),
        sessionClick: occurrenceCount(makersBlock,
            'new SessionsCockpitCard({tooltip, onRowActivated: onSessionActivated})'),
        systemAdopts: occurrenceCount(makersBlock, 'new SystemCockpitCard({pulseCard, tooltip})'),
    }, {
        keeps: ['if (cardIds.includes(cardId))', 'continue;'],
        destroysTheRest: true,
        makesTheMissing: ['if (!this._cardsById.has(cardId))', 'this._addCard(cardId);', '}'],
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
    'the layer), overrides no paint vfunc and has no drawing area', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    assertEqual({
        offscreenRedirect: occurrenceCount(source, 'offscreen_redirect'),
        offscreenRedirectProperty: occurrenceCount(source, 'offscreenRedirect'),
        paintVfuncs: occurrenceCount(source, 'vfunc_paint'),
        drawingAreas: occurrenceCount(source, 'DrawingArea'),
        isRead: source.length > 0,
    }, {offscreenRedirect: 0, offscreenRedirectProperty: 0, paintVfuncs: 0, drawingAreas: 0, isRead: true});
});

test('cockpitLayer.js: a cockpit client event goes through cockpitEventEffect (ruling D20): drawn at once, or its ' +
    'sources pending for the next Sample, arming the fallback only when it says so; drawing sources takes them out ' +
    'of the pending ones and redraws the cards cockpitCardIdsDrawing names', () =>
    assertEqual({
        onEvent: layerMethodStatements('_onCockpitEvent('),
        drawSources: layerMethodStatements('_drawSources('),
    }, {
        onEvent: [
            'const isFallbackArmed = this._applyFallbackSourceId !== null;',
            'const {timing, sourceNames} = cockpitEventEffect({event, isFallbackArmed});',
            'if (timing === CockpitApplyTiming.NEVER)',
            'return;',
            'if (timing === CockpitApplyTiming.NOW) {',
            'this._drawSources(sourceNames);',
            'return;',
            '}',
            'for (const sourceName of sourceNames)',
            'this._pendingSourceNames.add(sourceName);',
            'if (timing === CockpitApplyTiming.NEXT_TICK_WITH_FALLBACK)',
            'this._armApplyFallback();',
        ],
        drawSources: [
            'for (const sourceName of sourceNames)',
            'this._pendingSourceNames.delete(sourceName);',
            'const cardIds = cockpitCardIdsDrawing({drawnCardIds: this.drawnCardIds, sourceNames});',
            'for (const cardId of cardIds)',
            'this._drawCard(cardId);',
        ],
    }));

test('cockpitLayer.js: the fallback is the file\'s one timeout, a named one-shot GLib.timeout_add_seconds of ' +
    'COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS whose callback forgets its id, draws the pending sources in a try whose ' +
    'catch logs, and returns SOURCE_REMOVE; drawing the pending sources (each Sample) removes it first', () =>
    assertEqual({
        timeouts: occurrenceCount(codeOf(LAYER_SOURCE_FILE), 'timeout_add'),
        arm: layerMethodStatements('_armApplyFallback('),
        callback: layerMethodStatements('_onApplyFallbackTimeout('),
        drawPendingRemovesItFirst: layerMethodStatements('_drawPendingSources(')[0],
        remove: layerMethodStatements('_removeApplyFallback(').slice(-3),
    }, {
        timeouts: 1,
        arm: [
            'this._applyFallbackSourceId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT,',
            'COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS, () => this._onApplyFallbackTimeout());',
            'GLib.Source.set_name_by_id(this._applyFallbackSourceId, APPLY_FALLBACK_TIMEOUT_NAME);',
        ],
        callback: [
            'this._applyFallbackSourceId = null;',
            'try {',
            'this._drawPendingSources();',
            '} catch (error) {',
            "this._logFailure('could not draw the pending cockpit sources', error);",
            '}',
            'return GLib.SOURCE_REMOVE;',
        ],
        drawPendingRemovesItFirst: 'this._removeApplyFallback();',
        remove: [
            'const sourceId = this._applyFallbackSourceId;', 'this._applyFallbackSourceId = null;',
            'GLib.source_remove(sourceId);',
        ],
    }));

test('cockpitLayer.js: each Sample (onSampleTick, from the extension\'s tick) draws the pending sources, then pulls ' +
    'on suspicion every source cockpitSourceNamesToPull names (none while the subscription is not wanted)', () =>
    assertEqual(layerMethodStatements('onSampleTick('), [
        'this._drawPendingSources();',
        'const sourceNamesToPull = cockpitSourceNamesToPull({drawnCardIds: this.drawnCardIds, isSubscriptionWanted});',
        'for (const sourceName of sourceNamesToPull)',
        'this._cockpitClient.pullIfSuspicious(sourceName);',
    ]));

test('cockpitLayer.js: a card revealed is first drawn from what the clients hold, then unfrozen, so the reveal draws ' +
    'the latest at once (ruling D20); a frozen repaint draws it so too, still dimmed; a data card draws "no data ' +
    'since" when cockpitDataCardDrawing says so, else its sources', () => {
    const dataStatements = layerMethodStatements('_drawDataCard(');
    assertEqual({
        revealedOnlyFromFrozen: occurrenceCount(layerMethodBody('setCardFrozen('),
            'const isRevealed = !isFrozen && this._frozenCardIds.has(cardId);'),
        revealDrawsBeforeUnfreezing: layerMethodStatements('setCardFrozen(').slice(-3),
        repaint: layerMethodStatements('repaintFrozenCard(').slice(-2),
        decides: dataStatements.includes(
            'const drawing = cockpitDataCardDrawing({clientState: client.state, sources});'),
        draws: dataStatements.slice(-4),
    }, {
        revealedOnlyFromFrozen: 1,
        revealDrawsBeforeUnfreezing: ['if (isRevealed)', 'this._drawCard(cardId);', 'card.setFrozen(isFrozen);'],
        repaint: ['this._drawCard(cardId);', 'card.repaintFrozen();'],
        decides: true,
        draws: [
            'if (drawing.isNoData)', 'card.showNoData(noDataText(drawing.noDataSinceUsec, formatClockLabel));', 'else',
            'DATA_CARD_UPDATERS_BY_ID[cardId](card, sourcesByName);',
        ],
    });
});

test('cockpitLayer.js: the apps card draws the pulse client\'s snapshots (a snapshot listener), the system card the ' +
    'pulse client\'s latest, and each data card its sources, each through its own update (ruling D9)', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    assertEqual({
        onSnapshot: layerMethodStatements('_onSnapshot('),
        snapshotDrawers: [
            'system: (card, pulseClient) => card.update(pulseClient.latestSnapshot, pulseClient.lastGoodClockLabel),',
            'apps: (card, pulseClient) => card.update(pulseClient.latestSnapshot?.apps ?? null),',
        ].map(needle => occurrenceCount(source, needle)),
        dataUpdaters: [
            'connections: (card, sourcesByName) => card.update(sourcesByName.network, sourcesByName.mounts),',
            'sessions: (card, sourcesByName) => card.update(sourcesByName.sessions),',
        ].map(needle => occurrenceCount(source, needle)),
    }, {
        onSnapshot: ['this._cardsById.get(COCKPIT_APPS_CARD_ID)?.update(snapshot?.apps ?? null);'],
        snapshotDrawers: [1, 1], dataUpdaters: [1, 1],
    });
});

test('cockpitLayer.js: destroy removes both client listeners and the fallback timeout before destroying anything, ' +
    'then destroys the cards (the system card giving the v2 card back), the captions and last the tooltip, each ' +
    'step guarded (runEveryStep); every listener it adds it removes', () => {
    const source = codeOf(LAYER_SOURCE_FILE);
    const destroyBody = layerMethodBody('_onDestroy(');
    assertEqual({
        destroyHandler: occurrenceCount(layerMethodBody('_init('), "this.connect('destroy', () => this._onDestroy());"),
        guarded: occurrenceCount(destroyBody, 'runEveryStep(['),
        stepNames: [...destroyBody.matchAll(/\{name: '([^']+)', run: /g)].map(([, stepName]) => stepName),
        listenersAdded: occurrenceCount(source, '.addListener('),
        listenersRemoved: [
            layerMethodStatements('_removeCockpitListener(')
                .includes('this._cockpitClient.removeListener(listenerId);'),
            layerMethodStatements('_removeSnapshotListener(').includes('this._pulseClient.removeListener(listenerId);'),
        ],
        everyCardDestroyed: occurrenceCount(layerMethodBody('_destroyCards('), 'run: () => card.destroy()'),
    }, {
        destroyHandler: 1, guarded: 1,
        stepNames: [
            'remove the cockpit client listener', 'remove the snapshot listener', 'remove the fallback timeout',
            'destroy the cards', 'destroy the captions', 'destroy the tooltip',
        ],
        listenersAdded: 2, listenersRemoved: [true, true], everyCardDestroyed: 1,
    });
});

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

test('extension.js: a cockpit client event adds, removes or rebuilds the layer as cockpitLayerChange says, then ' +
    'holds a hidden v2 card frozen (ruling D21) and places the cards again; the v2 card stops following its width ' +
    'while the layer holds it, and is put back top right, following it again, when the layer goes', () =>
    assertEqual({
        onEvent: extensionMethodStatements('_onCockpitClientEvent(event) {'),
        sync: extensionMethodStatements('_syncCockpitLayer(isLayoutEvent) {'),
        holdHidden: extensionMethodStatements('_holdHiddenPulseCardFrozen() {'),
        addStopsFollowingTheWidthFirst: extensionMethodStatements('_addCockpitLayer() {')[0],
        addHandsTheCardOver: extensionMethodStatements('_addCockpitLayer() {')
            .includes('cockpitClient: this._cockpitClient, pulseClient: this._client, pulseCard: this._card,'),
        addReadsTheDisplayConfig: extensionMethodStatements('_addCockpitLayer() {').at(-1),
        remove: extensionMethodStatements('_removeCockpitLayer() {'),
        putTopRight: extensionMethodStatements('_putCardTopRight() {'),
    }, {
        onEvent: ['this._syncCockpitLayer(event.type === CockpitClientEventType.LAYOUT);'],
        sync: [
            'const layerChange = cockpitLayerChange({',
            'isLayerShown: this._layer !== null,',
            'clientState: this._cockpitClient.state,',
            'layout: this._cockpitClient.layout,',
            'isLayoutEvent,',
            '});',
            'if (layerChange === CockpitLayerChange.NONE)',
            'return;',
            'if (layerChange === CockpitLayerChange.ADD)',
            'this._addCockpitLayer();',
            'else if (layerChange === CockpitLayerChange.REMOVE)',
            'this._removeCockpitLayer();',
            'else',
            'this._layer.setLayout(this._cockpitClient.layout);',
            'this._holdHiddenPulseCardFrozen();',
            'this._placeCard();',
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

test('extension.js: the layer goes on the monitor cockpitMonitorIndexFor chooses from the shell\'s monitors, ' +
    'DisplayConfig\'s last answer and the layout\'s rule, at its work area (getWorkAreaForMonitor); a monitors ' +
    'change forgets that answer, asks again while a layer is shown and places the cards in the coalesced later, as a ' +
    'work-area change and a new answer do; the later never throws out of its callback', () => {
    const extensionCode = codeOf(EXTENSION_SOURCE_FILE);
    const queueStatements = extensionMethodStatements('_queueCardPlacement() {');
    const placeIndex = queueStatements.indexOf('this._placeCard();');
    assertEqual({
        place: extensionMethodStatements('_placeCockpitLayer() {'),
        onMonitorsChanged: extensionMethodStatements('_onMonitorsChanged() {'),
        onAnswer: extensionMethodStatements('_onDisplayConfigRead(displayConfigState) {'),
        connects: [
            "Main.layoutManager.connectObject('monitors-changed', () => this._onMonitorsChanged(), this);",
            "global.display.connectObject('workareas-changed', () => this._queueCardPlacement(), this);",
        ].map(needle => occurrenceCount(extensionCode, needle)),
        laterGuarded: placeIndex < 1 ? [] : queueStatements.slice(placeIndex - 1, placeIndex + 3),
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
        laterGuarded: [
            'try {', 'this._placeCard();', '} catch (error) {', 'const errorText = describeErrorWithStack(error);',
        ],
    });
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

test('extension.js: a session row\'s click reaches _activateSession, which does nothing yet and logs nothing', () =>
    assertEqual({
        handedToTheLayer: extensionMethodStatements('_addCockpitLayer() {')
            .includes('errorLog: this._errorLog, onSessionActivated: sessionId => this._activateSession(sessionId),'),
        activate: statementsOf(methodBody(readExtensionFile(EXTENSION_SOURCE_FILE), '_activateSession(_sessionId) {')),
    }, {handedToTheLayer: true, activate: ['_activateSession(_sessionId) {', '}']}));

test('extension.js: teardown keeps the layout to cache before anything is destroyed, clears the cockpit\'s fields, ' +
    'removes the cockpit client listener, cancels the DisplayConfig read and destroys the layer first', () => {
    const tearDownStatements = extensionMethodStatements('_tearDown() {');
    const clearedFields = [
        'this._layer = null;', 'this._cockpitClient = null;', 'this._displayConfigReader = null;',
        'this._displayConfigState = null;', 'this._cockpitListenerId = null;',
        'this._visibleCardIds = VISIBLE_CARD_IDS_BEFORE_COVER_CHECK;', 'this._frozenCardPaintedAtUsecByCardId = {};',
        'this._isCockpitSubscriptionWanted = false;',
    ];
    const firstDestroyIndex = tearDownStatements.findIndex(statement => statement.includes('?.destroy()'));
    assertEqual({
        cleared: clearedFields.map(field => tearDownStatements.filter(statement => statement === field).length),
        listenerRemoved: tearDownStatements.includes('cockpitClient?.removeListener(cockpitListenerId);'),
        firstDestroy: tearDownStatements[firstDestroyIndex],
        layerBeforeTheCard: tearDownStatements.indexOf(
            '{name: \'destroy the cockpit layer\', run: () => layer?.destroy()},') <
            tearDownStatements.indexOf('{name: \'destroy the card\', run: () => card?.destroy()},'),
    }, {
        cleared: clearedFields.map(() => 1),
        listenerRemoved: true,
        firstDestroy: '{name: \'cancel the display config read\', run: () => displayConfigReader?.destroy()},',
        layerBeforeTheCard: true,
    });
});
