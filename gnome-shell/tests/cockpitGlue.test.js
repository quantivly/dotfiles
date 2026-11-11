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
    'base\'s one offscreen redirect is the file\'s only one, so a data card is drawn only through the texture the ' +
    'base gives it and the system cell holds one texture, the adopted v2 card\'s', () => {
    const source = codeOf(CARDS_SOURCE_FILE);
    assertEqual({
        paintVfuncs: occurrenceCount(source, 'vfunc_paint'),
        offscreenRedirectUses: occurrenceCount(source, 'offscreen_redirect'),
        baseRedirects: occurrenceCount(classBody(source, 'CockpitCardBase'),
            'this.set_offscreen_redirect(Clutter.OffscreenRedirect.ALWAYS);'),
    }, {paintVfuncs: 0, offscreenRedirectUses: 1, baseRedirects: 1});
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
