// The desktop card while windows cover it: lib/visibility.js, which decides whether one window covers the card, and
// lib/cardRepaint.js, which decides what the card repaints (nothing while it is frozen, everything at once on the
// reveal, and a meter or the memory bar only when the value it draws changed). card.js, stylesheet.css and
// extension.js are Shell glue that plain gjs cannot run, so the last rows read their sources for the rules the glue
// must keep: only app names ellipsize, the stylesheet keeps every class the previous release's code sets, the card has
// a fixed width, and every signal the covered check follows is disconnected on teardown.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// Read through the namespaces, so a missing export fails its rows rather than the whole run.
import * as visibilityModule from '../extensions/resource-pulse@dotfiles/lib/visibility.js';
import * as cardRepaintModule from '../extensions/resource-pulse@dotfiles/lib/cardRepaint.js';

const EXTENSION_DIRECTORY_URI =
    GLib.uri_resolve_relative(import.meta.url, '../extensions/resource-pulse@dotfiles/', GLib.UriFlags.NONE);
const [EXTENSION_DIRECTORY_PATH] = GLib.filename_from_uri(EXTENSION_DIRECTORY_URI);

// The covered rows' geometry, in stage pixels: a 1920 × 1080 primary monitor with a 32 px top bar, and the card at the
// top right of its work area, 24 px in.
const PRIMARY_MONITOR_RECT = {x: 0, y: 0, width: 1920, height: 1080};
const MAXIMIZED_WINDOW_RECT = {x: 0, y: 32, width: 1920, height: 1048};
const CARD_RECT = {x: 1480, y: 56, width: 416, height: 224};
/** The share of the card's width a window covers in the "99% is not covered" row. */
const NINETY_NINE_PERCENT = 0.99;
const ONE_PIXEL = 1;
/** How wide (or tall) a window beside the card is, in the rows where it only touches an edge. */
const NEIGHBOUR_WINDOW_SIZE_PX = 100;

// The repaint rows' snapshots, in the shape the client publishes. The pressure percents band as [1, 0, 0]; raising
// io to 30 bands it 2 (lib/pressure.js).
const GIB = 1024 ** 3;
const QUIET_PRESSURE = {cpu: 12, memory: 3, io: 0};
const IO_BOUND_PRESSURE = {cpu: 12, memory: 3, io: 30};
const SNAPSHOT = {
    cpuBusyPercent: 23,
    cpuClusters: null,
    memory: {usedBytes: 16.4 * GIB, totalBytes: 30.3 * GIB},
    swap: null,
    pressureAvg10: QUIET_PRESSURE,
    apps: null,
};
const BUSIER_SNAPSHOT = {...SNAPSHOT, cpuBusyPercent: 57};
const IO_BOUND_SNAPSHOT = {...SNAPSHOT, pressureAvg10: IO_BOUND_PRESSURE};
/** What the client publishes when the service went quiet: every number null. */
const NO_DATA_SNAPSHOT = {
    cpuBusyPercent: null,
    cpuClusters: null,
    memory: null,
    swap: null,
    pressureAvg10: {cpu: null, memory: null, io: null},
    apps: null,
};
const MEMORY_FRACTION = 0.54;
const HIGHER_MEMORY_FRACTION = 0.61;
const CLOCK_LABEL = '14:02';
const LATER_CLOCK_LABEL = '14:05';
const ALL_METER_INDEXES = [0, 1, 2];
const IO_METER_INDEX = 2;

// The previous release's stylesheet classes (git show f28b216:gnome-shell/extensions/resource-pulse@dotfiles/
// stylesheet.css). GNOME re-reads the stylesheet on every enable but the code only at login, so until the next login
// that code meets this stylesheet: every one of these must keep its rule.
const V1_STYLESHEET_CLASS_NAMES = [
    'resource-pulse-graphs', 'resource-pulse-hover-label', 'resource-pulse-card', 'resource-pulse-card-meters',
    'resource-pulse-card-figure', 'resource-pulse-card-label', 'resource-pulse-card-suffix',
    'resource-pulse-card-cpu-figure', 'resource-pulse-card-details', 'resource-pulse-card-detail-row',
    'resource-pulse-card-pressure-meters', 'resource-pulse-card-pressure-group',
];
/** The previous release's card width: its .resource-pulse-card min-width. */
const V1_CARD_MIN_WIDTH = '25em';
const CARD_CLASS_NAME = 'resource-pulse-card';
const FIXED_WIDTH_CLASS_NAME = 'rp-card-fixed';

const CSS_COMMENT_PATTERN = /\/\*[\s\S]*?\*\//g;
/** One CSS rule: its selector list, then its declarations. */
const CSS_RULE_PATTERN = /([^{}]+)\{([^{}]*)\}/g;
const CSS_CLASS_SELECTOR_PATTERN = /\.([A-Za-z][\w-]*)/g;
const CSS_DECLARATION_PATTERN = /^\s*([\w-]+)\s*:\s*(.*?)\s*$/;
/** A line of card.js that sets a label's ellipsizing, in any of the forms GJS allows. */
const ELLIPSIZE_SETTING_PATTERN = /\.ellipsize\s*=|\bellipsize\s*:|set_ellipsize\s*\(/;
const COMMENT_LINE_PATTERN = /^\s*(\/\/|\*|\/\*)/;
/** `<receiver>.connectObject(<signal, handler pairs>, this);`, the arguments possibly over several lines. */
const CONNECT_OBJECT_PATTERN = /([\w.]+)\.connectObject\(([\s\S]*?)\bthis\);/g;
const QUOTED_SIGNAL_NAME_PATTERN = /'([\w:-]+)'/g;
const DISCONNECT_OBJECT_PATTERN = /([\w.]+)\??\.disconnectObject\(this\)/g;
/** extension.js names its card this._card, and its teardown reads it into a local, card. */
const OWN_FIELD_PREFIX_PATTERN = /^this\._/;

/**
 * Reads a file of the extension as text (tests may block).
 *
 * @param {string} fileName - Its path inside the extension directory.
 * @returns {string} Its contents.
 */
function readExtensionFile(fileName) {
    const path = GLib.build_filenamev([EXTENSION_DIRECTORY_PATH, fileName]);
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

/**
 * The body of a top-level function or a class method: from its declaration line to the first line that closes it at
 * the declaration's own indent.
 *
 * @param {string} sourceText - The file's text.
 * @param {string} declarationLine - The declaration as it starts its line, for example 'function newCardLabel('.
 * @returns {string} The lines of the body, or '' when there is no such declaration.
 */
function declarationBody(sourceText, declarationLine) {
    const lines = sourceText.split('\n');
    const startIndex = lines.findIndex(line => line.trimStart().startsWith(declarationLine));
    if (startIndex < 0)
        return '';
    const indent = lines[startIndex].length - lines[startIndex].trimStart().length;
    const closingLine = `${' '.repeat(indent)}}`;
    const endIndex = lines.findIndex((line, lineIndex) => lineIndex > startIndex && line === closingLine);
    return lines.slice(startIndex, endIndex < 0 ? undefined : endIndex + 1).join('\n');
}

/**
 * Every rule of a stylesheet, comments removed.
 *
 * @param {string} stylesheetText - The stylesheet.
 * @returns {Array<{classNames: string[], declarations: Object<string, string>}>} Each rule's class selectors and its
 *     declarations by property name.
 */
function stylesheetRules(stylesheetText) {
    const uncommentedText = stylesheetText.replace(CSS_COMMENT_PATTERN, '');
    return [...uncommentedText.matchAll(CSS_RULE_PATTERN)].map(([, selectorText, declarationText]) => {
        const classNames = [...selectorText.matchAll(CSS_CLASS_SELECTOR_PATTERN)].map(([, className]) => className);
        const declarationEntries = declarationText.split(';')
            .map(declaration => CSS_DECLARATION_PATTERN.exec(declaration))
            .filter(declarationMatch => declarationMatch !== null)
            .map(([, propertyName, value]) => [propertyName, value]);
        return {classNames, declarations: Object.fromEntries(declarationEntries)};
    });
}

/**
 * The declarations of the rules whose selector is exactly one class.
 *
 * @param {ReturnType<typeof stylesheetRules>} rules - The stylesheet's rules.
 * @param {string} className - The class.
 * @returns {Object<string, string>} Its declarations merged, or {} when no rule selects it alone.
 */
function declarationsOfClass(rules, className) {
    const ownRules = rules.filter(rule => rule.classNames.length === 1 && rule.classNames[0] === className);
    return Object.assign({}, ...ownRules.map(rule => rule.declarations));
}

/**
 * The parts of a repaint plan a row compares, or null when there is no plan.
 *
 * @param {object|null} repaintPlan - What CardRepaintPlanner returned.
 * @returns {object|null} Its CPU value text, the meters and bar it repaints, and the fraction the bar draws.
 */
function summarizeRepaintPlan(repaintPlan) {
    if (repaintPlan === null)
        return null;
    const {text, changedMeterIndexes, isMemoryBarChanged, memoryFraction} = repaintPlan;
    return {cpuValue: text.cpuValue, changedMeterIndexes, isMemoryBarChanged, memoryFraction};
}

/**
 * What the card asks the planner to show: a snapshot, the clock label of the last good one, and the newest memory
 * fraction in the client's history.
 *
 * @param {object|null} snapshot - The snapshot.
 * @param {number|null} newestMemoryFraction - The memory bar's value.
 * @param {string|null} [lastGoodClockLabel] - 'HH:MM'.
 * @returns {{snapshot: object|null, lastGoodClockLabel: string|null, newestMemoryFraction: number|null}} The input.
 */
const shownState = (snapshot, newestMemoryFraction, lastGoodClockLabel = CLOCK_LABEL) =>
    ({snapshot, lastGoodClockLabel, newestMemoryFraction});

test('visibility: a maximized window containing the card covers it; one covering 99% of it does not', () => {
    const ninetyNinePercentRect = {...CARD_RECT, width: CARD_RECT.width * NINETY_NINE_PERCENT};
    assertEqual([
        visibilityModule.isRectFullyCovered(CARD_RECT, [MAXIMIZED_WINDOW_RECT]),
        visibilityModule.isRectFullyCovered(CARD_RECT, [ninetyNinePercentRect]),
    ], [true, false]);
});

test('visibility: with no windows the card is not covered', () =>
    assertEqual(visibilityModule.isRectFullyCovered(CARD_RECT, []), false));

test('visibility: edges count as inside: a window exactly the card covers it, one a pixel short on any side does ' +
    'not, and windows that only touch its edges do not', () => {
    const onePixelShortRects = {
        left: {...CARD_RECT, x: CARD_RECT.x + ONE_PIXEL, width: CARD_RECT.width - ONE_PIXEL},
        top: {...CARD_RECT, y: CARD_RECT.y + ONE_PIXEL, height: CARD_RECT.height - ONE_PIXEL},
        right: {...CARD_RECT, width: CARD_RECT.width - ONE_PIXEL},
        bottom: {...CARD_RECT, height: CARD_RECT.height - ONE_PIXEL},
    };
    const touchingRects = [
        {...CARD_RECT, x: CARD_RECT.x - NEIGHBOUR_WINDOW_SIZE_PX, width: NEIGHBOUR_WINDOW_SIZE_PX},
        {...CARD_RECT, x: CARD_RECT.x + CARD_RECT.width, width: NEIGHBOUR_WINDOW_SIZE_PX},
        {...CARD_RECT, y: CARD_RECT.y - NEIGHBOUR_WINDOW_SIZE_PX, height: NEIGHBOUR_WINDOW_SIZE_PX},
        {...CARD_RECT, y: CARD_RECT.y + CARD_RECT.height, height: NEIGHBOUR_WINDOW_SIZE_PX},
    ];
    const isCoveredBy = windowRects => visibilityModule.isRectFullyCovered(CARD_RECT, windowRects);
    assertEqual({
        exactlyTheCard: isCoveredBy([{...CARD_RECT}]),
        onePixelShort: Object.fromEntries(
            Object.entries(onePixelShortRects).map(([side, windowRect]) => [side, isCoveredBy([windowRect])])),
        touchingEveryEdge: isCoveredBy(touchingRects),
    }, {
        exactlyTheCard: true,
        onePixelShort: {left: false, top: false, right: false, bottom: false},
        touchingEveryEdge: false,
    });
});

test('visibility: only one window covers the card: two that cover it only together leave it visible', () => {
    const halfWidth = CARD_RECT.width / 2;
    const leftHalfRect = {...CARD_RECT, width: halfWidth};
    const rightHalfRect = {...CARD_RECT, x: CARD_RECT.x + halfWidth, width: halfWidth};
    assertEqual(visibilityModule.isRectFullyCovered(CARD_RECT, [leftHalfRect, rightHalfRect]), false);
});

test('visibility: a card with no area yet is never covered, even under a maximized window', () =>
    assertEqual([
        visibilityModule.isRectFullyCovered({...CARD_RECT, width: 0}, [MAXIMIZED_WINDOW_RECT]),
        visibilityModule.isRectFullyCovered({...CARD_RECT, height: 0}, [MAXIMIZED_WINDOW_RECT]),
    ], [false, false]));

test('visibility: a window counts for cover only when it is a normal or dialog window, not minimized, showing, on ' +
    'the active workspace and over the primary monitor', () => {
    const countingWindow = {
        isNormalOrDialog: true, isMinimized: false, isShowing: true, isOnActiveWorkspace: true,
        overlapsPrimaryMonitor: true,
    };
    const countsWithOneChanged = Object.keys(countingWindow).map(conditionName => {
        const changedWindow = {...countingWindow, [conditionName]: !countingWindow[conditionName]};
        return `${conditionName}: ${visibilityModule.windowCountsForCover(changedWindow)}`;
    });
    assertEqual([visibilityModule.windowCountsForCover(countingWindow), ...countsWithOneChanged], [
        true,
        'isNormalOrDialog: false',
        'isMinimized: false',
        'isShowing: false',
        'isOnActiveWorkspace: false',
        'overlapsPrimaryMonitor: false',
    ]);
});

test('visibility: rectangles overlap only when they share area: touching along an edge or at a corner is not ' +
    'overlapping', () => {
    const rightOfPrimaryRect = {x: PRIMARY_MONITOR_RECT.width, y: 0, width: 800, height: 600};
    const overlaps = windowRect => visibilityModule.doRectsOverlap(windowRect, PRIMARY_MONITOR_RECT);
    assertEqual({
        maximized: overlaps(MAXIMIZED_WINDOW_RECT),
        onePixelOver: overlaps({...rightOfPrimaryRect, x: rightOfPrimaryRect.x - ONE_PIXEL}),
        touchingTheRightEdge: overlaps(rightOfPrimaryRect),
        touchingTheBottomRightCorner: overlaps({...rightOfPrimaryRect, y: PRIMARY_MONITOR_RECT.height}),
        noArea: overlaps({...CARD_RECT, width: 0}),
    }, {
        maximized: true, onePixelOver: true, touchingTheRightEdge: false, touchingTheBottomRightCorner: false,
        noArea: false,
    });
});

test('visibility: a fullscreen primary monitor covers the card even with no window over it; otherwise the windows ' +
    'decide', () => {
    const isCovered = (isPrimaryMonitorInFullscreen, windowRects) =>
        visibilityModule.isCardCovered({isPrimaryMonitorInFullscreen, cardRect: CARD_RECT, windowRects});
    assertEqual([isCovered(true, []), isCovered(false, []), isCovered(false, [MAXIMIZED_WINDOW_RECT])],
        [true, false, true]);
});

test('card repaint: an unfrozen card renders every snapshot, and its first render repaints the memory bar and all ' +
    'three meters', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    assertEqual(summarizeRepaintPlan(planner.show(shownState(SNAPSHOT, MEMORY_FRACTION))), {
        cpuValue: '23%', changedMeterIndexes: ALL_METER_INDEXES, isMemoryBarChanged: true,
        memoryFraction: MEMORY_FRACTION,
    });
});

test('card repaint: a meter or the memory bar repaints only when the value it draws changes', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    assertEqual([
        planner.show(shownState(BUSIER_SNAPSHOT, MEMORY_FRACTION)),
        planner.show(shownState(IO_BOUND_SNAPSHOT, MEMORY_FRACTION)),
        planner.show(shownState(IO_BOUND_SNAPSHOT, HIGHER_MEMORY_FRACTION)),
    ].map(summarizeRepaintPlan), [
        {cpuValue: '57%', changedMeterIndexes: [], isMemoryBarChanged: false, memoryFraction: MEMORY_FRACTION},
        {cpuValue: '23%', changedMeterIndexes: [IO_METER_INDEX], isMemoryBarChanged: false,
            memoryFraction: MEMORY_FRACTION},
        {cpuValue: '23%', changedMeterIndexes: [], isMemoryBarChanged: true, memoryFraction: HIGHER_MEMORY_FRACTION},
    ]);
});

test('card repaint: while frozen a snapshot is only recorded; unfreezing renders at once from the latest one, with ' +
    'its clock label', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    const plansWhileFrozen = [
        planner.setFrozen(true),
        planner.show(shownState(BUSIER_SNAPSHOT, HIGHER_MEMORY_FRACTION)),
        planner.show(shownState(NO_DATA_SNAPSHOT, null, LATER_CLOCK_LABEL)),
    ];
    assertEqual({
        plansWhileFrozen: plansWhileFrozen.map(summarizeRepaintPlan),
        reveal: summarizeRepaintPlan(planner.setFrozen(false)),
    }, {
        plansWhileFrozen: [null, null, null],
        reveal: {cpuValue: 'no data since 14:05', changedMeterIndexes: ALL_METER_INDEXES, isMemoryBarChanged: true,
            memoryFraction: null},
    });
});

test('card repaint: setFrozen to the state the card already has does nothing: a second freeze or unfreeze renders ' +
    'nothing', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    const plans = [
        planner.setFrozen(false),
        planner.setFrozen(true),
        planner.setFrozen(true),
        planner.setFrozen(false),
        planner.setFrozen(false),
    ];
    assertEqual(plans.map(repaintPlan => repaintPlan !== null), [false, false, false, true, false]);
});

test('card repaint: the reveal compares with what is drawn, so a value that changed while frozen and changed back ' +
    'repaints nothing', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    planner.setFrozen(true);
    planner.show(shownState(IO_BOUND_SNAPSHOT, HIGHER_MEMORY_FRACTION));
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    const reveal = summarizeRepaintPlan(planner.setFrozen(false));
    assertEqual([reveal?.changedMeterIndexes, reveal?.isMemoryBarChanged], [[], false]);
});

test('card.js: only the "heaviest" row\'s two app names ellipsize; every other label is made with ellipsizing off, ' +
    'so no number is ever cut', () => {
    const cardSource = readExtensionFile('card.js');
    const codeLines = cardSource.split('\n').filter(line => !COMMENT_LINE_PATTERN.test(line));
    const ellipsizeSettings = codeLines.filter(line => ELLIPSIZE_SETTING_PATTERN.test(line)).map(line => line.trim());
    const appNameLabelCalls = codeLines
        .filter(line => line.includes('newAppNameLabel()') && !line.includes('function newAppNameLabel('))
        .map(line => line.trim());
    const labelConstructionCount = codeLines.filter(line => line.includes('new St.Label(')).length;
    assertEqual({
        ellipsizeSettings,
        newCardLabelTurnsItOff: declarationBody(cardSource, 'function newCardLabel(')
            .includes('cardLabel.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;'),
        newAppNameLabelTurnsItOn: declarationBody(cardSource, 'function newAppNameLabel(')
            .includes('appNameLabel.clutter_text.ellipsize = Pango.EllipsizeMode.END;'),
        newAppNameLabelStartsFromACardLabel: declarationBody(cardSource, 'function newAppNameLabel(')
            .includes('const appNameLabel = newCardLabel('),
        appNameLabelCalls,
        labelConstructionCount,
    }, {
        ellipsizeSettings: [
            'cardLabel.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;',
            'appNameLabel.clutter_text.ellipsize = Pango.EllipsizeMode.END;',
        ],
        newCardLabelTurnsItOff: true,
        newAppNameLabelTurnsItOn: true,
        newAppNameLabelStartsFromACardLabel: true,
        appNameLabelCalls: [
            'this._heaviestCpuNameLabel = newAppNameLabel();',
            'this._heaviestMemoryNameLabel = newAppNameLabel();',
        ],
        labelConstructionCount: 1,
    });
});

test('stylesheet.css keeps a rule for every class the previous release set (stylesheet skew: its code meets this ' +
    'stylesheet until the next login)', () => {
    const selectedClassNames = new Set(stylesheetRules(readExtensionFile('stylesheet.css'))
        .flatMap(rule => rule.classNames));
    assertEqual(V1_STYLESHEET_CLASS_NAMES.filter(className => !selectedClassNames.has(className)), []);
});

test('the card has a fixed width: rp-card-fixed pins its min-width, width and max-width to the previous release\'s ' +
    '25em, and card.js puts that class on the card', () => {
    const rules = stylesheetRules(readExtensionFile('stylesheet.css'));
    const fixedWidthDeclarations = declarationsOfClass(rules, FIXED_WIDTH_CLASS_NAME);
    const cardSource = readExtensionFile('card.js');
    assertEqual({
        fixedWidth: [
            fixedWidthDeclarations['min-width'], fixedWidthDeclarations.width, fixedWidthDeclarations['max-width'],
        ],
        cardMinWidth: declarationsOfClass(rules, CARD_CLASS_NAME)['min-width'],
        cardJsNamesTheClass: cardSource.includes(`const FIXED_WIDTH_STYLE_CLASS = '${FIXED_WIDTH_CLASS_NAME}';`),
        cardJsSetsIt: cardSource.includes('style_class: `${CARD_STYLE_CLASS} ${FIXED_WIDTH_STYLE_CLASS}`,'),
    }, {
        fixedWidth: [V1_CARD_MIN_WIDTH, V1_CARD_MIN_WIDTH, V1_CARD_MIN_WIDTH],
        cardMinWidth: V1_CARD_MIN_WIDTH,
        cardJsNamesTheClass: true,
        cardJsSetsIt: true,
    });
});

test('extension.js checks the cover on a restack, a fullscreen change, a minimize, an unminimize, a size change, ' +
    'the end of a drag, a workspace switch, "show desktop" and every client update, and its teardown disconnects ' +
    'every object it connects to and removes that listener', () => {
    const extensionSource = readExtensionFile('extension.js');
    const tearDownBody = declarationBody(extensionSource, '_tearDown() {');
    const connectedSignals = [...extensionSource.matchAll(CONNECT_OBJECT_PATTERN)].flatMap(
        ([, receiver, connectArguments]) => [...connectArguments.matchAll(QUOTED_SIGNAL_NAME_PATTERN)]
            .map(([, signalName]) => `${receiver} ${signalName}`));
    const connectedReceivers = new Set([...extensionSource.matchAll(CONNECT_OBJECT_PATTERN)]
        .map(([, receiver]) => receiver.replace(OWN_FIELD_PREFIX_PATTERN, '')));
    const disconnectedReceivers = new Set([...tearDownBody.matchAll(DISCONNECT_OBJECT_PATTERN)]
        .map(([, receiver]) => receiver.replace(OWN_FIELD_PREFIX_PATTERN, '')));
    assertEqual({
        connectedSignals: connectedSignals.sort(),
        receiversNeverDisconnected: [...connectedReceivers].filter(receiver => !disconnectedReceivers.has(receiver)),
        clientListenersAdded: (extensionSource.match(/\.addListener\(/g) ?? []).length,
        clientListenersRemovedOnTeardown: (tearDownBody.match(/\.removeListener\(/g) ?? []).length,
    }, {
        connectedSignals: [
            'Main.layoutManager monitors-changed',
            'Main.overview hidden',
            'Main.overview showing',
            'global.display grab-op-end',
            'global.display in-fullscreen-changed',
            'global.display restacked',
            'global.display workareas-changed',
            'global.window_manager minimize',
            'global.window_manager size-changed',
            'global.window_manager switch-workspace',
            'global.window_manager unminimize',
            'global.workspace_manager showing-desktop-changed',
            'this._card notify::width',
        ],
        receiversNeverDisconnected: [],
        clientListenersAdded: 1,
        clientListenersRemovedOnTeardown: 1,
    });
});
