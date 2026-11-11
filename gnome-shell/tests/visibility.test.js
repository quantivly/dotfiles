// The desktop card while windows cover it: lib/visibility.js, which decides whether one window covers the card, and
// lib/cardRepaint.js, which decides what the card repaints (nothing while it is frozen, everything at once on the
// reveal, and a meter or the memory bar only when what it draws changed). card.js, stylesheet.css and extension.js are
// Shell glue that plain gjs cannot run, so the last rows read their sources for the rules the glue must keep: only app
// names ellipsize, the stylesheet keeps every class the previous release's code sets, the card's fixed width fits its
// widest rows (measured with Pango, in the card's font), and extension.js wires the covered check and tears it down.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {
    CARD_CPU_GRAPH_WIDTH_PX, CARD_MEMORY_BAR_WIDTH_PX, PRESSURE_METER_WIDTH_PX,
} from '../extensions/resource-pulse@dotfiles/lib/constants.js';
import {cardText} from '../extensions/resource-pulse@dotfiles/lib/format.js';
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
// The memory bar redraws only when its filled width, in whole pixels of CARD_MEMORY_BAR_WIDTH_PX, changes: these
// fractions fill 81 px, 81.49 px (still 81 once rounded) and 81.51 px (82).
const WHOLE_PIXEL_FILL_PX = 81;
const SAME_PIXEL_FILL_PX = 81.49;
const NEXT_PIXEL_FILL_PX = 81.51;
const CLOCK_LABEL = '14:02';
const LATER_CLOCK_LABEL = '14:05';
const ALL_METER_INDEXES = [0, 1, 2];
const IO_METER_INDEX = 2;
/** How often a frozen card is repainted, as ruling R21 set it, and how often a Sample comes, in seconds. */
const FROZEN_REPAINT_SECONDS = 30;
const SAMPLE_TICK_SECONDS = 2;
/** How long the frozen-repaint row runs the Samples for: past its second repaint. */
const FROZEN_RUN_SECONDS = 62;
/** The tick from which a covered card's cover is checked again: 30 s of Samples, R21's repaint interval. */
const COVER_BACKSTOP_TICK = 15;
const USEC_PER_SECOND = 1_000_000;
const ONE_USEC = 1;

// The previous release's stylesheet classes (git show f28b216:gnome-shell/extensions/resource-pulse@dotfiles/
// stylesheet.css). GNOME re-reads the stylesheet on every enable but the code only at login, so until the next login
// that code meets this stylesheet: every one of these must keep its rule.
const V1_STYLESHEET_CLASS_NAMES = [
    'resource-pulse-graphs', 'resource-pulse-hover-label', 'resource-pulse-card', 'resource-pulse-card-meters',
    'resource-pulse-card-figure', 'resource-pulse-card-label', 'resource-pulse-card-suffix',
    'resource-pulse-card-cpu-figure', 'resource-pulse-card-details', 'resource-pulse-card-detail-row',
    'resource-pulse-card-pressure-meters', 'resource-pulse-card-pressure-group',
];
const CARD_CLASS_NAME = 'resource-pulse-card';
const FIXED_WIDTH_CLASS_NAME = 'rp-card-fixed';
// The frozen card's dim (ruling R21): card.js's pseudo-class, the stylesheet property it reads for its graphs'
// opacity, and the stylesheet selector of the frozen card.
const FROZEN_PSEUDO_CLASS_NAME = 'frozen';
const GRAPH_OPACITY_PROPERTY_NAME = '-rp-graph-opacity';
const FROZEN_CARD_SELECTOR = `.${CARD_CLASS_NAME}:${FROZEN_PSEUDO_CLASS_NAME}`;
/** The card's value labels, which set no colour of their own and so take the card's. */
const VALUE_CLASS_NAMES = ['resource-pulse-card-value', 'resource-pulse-card-figure'];
/** `rgba(r, g, b, a)`: a CSS colour, its alpha captured. */
const CSS_RGBA_ALPHA_PATTERN = /^rgba\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*([\d.]+)\s*\)$/;
/** Each graph colour card.js scales by the stylesheet's opacity: the CPU graph's, the bar's and the meters' two each. */
const DIMMED_GRAPH_COLOUR_COUNT = 6;

// The card's text, as GNOME on Ubuntu draws it: the card's own font family at the shell's 11 pt font-name
// ("Ubuntu Sans 11"), at 96 dpi with no text scaling, with tabular digits.
const CARD_FONT_FAMILY = 'Ubuntu Sans';
const SHELL_FONT_SIZE_PT = 11;
const FONT_RESOLUTION_DPI = 96;
const POINTS_PER_INCH = 72;
const EM_PX = SHELL_FONT_SIZE_PT * FONT_RESOLUTION_DPI / POINTS_PER_INCH;
const TABULAR_DIGITS_FEATURE = 'tnum';
/** Room the widest row leaves inside the fixed width, for any difference between Pango here and St on screen. */
const CARD_WIDTH_MARGIN_PX = 8;
/** How much of each long app name the widest "heaviest" row still shows before its ellipsis. */
const HEAVIEST_NAME_SHOWN_CHARS = 10;
const ELLIPSIS = '…';
/** A CSS length the width row reads from the stylesheet: a number and px or em. */
const CSS_LENGTH_PATTERN = /^([\d.]+)(px|em)$/;
const CSS_FIRST_FONT_FAMILY_PATTERN = /^\s*"([^"]+)"/;
const BOLD_FONT_WEIGHT = 'bold';
// The widest values each row of the card can show.
const LATEST_CLOCK_LABEL = '23:58';
const FULL_CPU_SNAPSHOT = {
    ...SNAPSHOT, cpuBusyPercent: 100, cpuClusters: {performancePercent: 100, efficiencyPercent: 100},
};
const LARGE_MACHINE_SNAPSHOT = {
    ...SNAPSHOT,
    memory: {usedBytes: 123.4 * GIB, totalBytes: 125.6 * GIB},
    swap: {zramUsedBytes: 123.4 * GIB, zramRamBytes: 12.3 * GIB, diskBytes: 123.4 * GIB},
    apps: {
        topCpu: {groupKey: 'app:code', name: 'Visual Studio Code', cpuPercent: 100},
        topMemory: {groupKey: 'unit:calendar', name: 'gnome-shell-calendar-server', memoryBytes: 123.4 * GIB},
    },
};

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
/** One `'signal', handler` pair of a connectObject call, the handler up to the next comma. */
const SIGNAL_HANDLER_PAIR_PATTERN = /'([\w:-]+)',\s*([^,]+?)\s*,/g;
/**
 * The receivers the covered check connects to: in _followCardCover, and in _startFollowingCoveringWindow, whose
 * receiver is each window that covers the card.
 */
const COVER_SIGNAL_RECEIVERS = new Set([
    'global.display', 'global.window_manager', 'global.workspace_manager', 'metaWindow',
]);
// The client's two kinds of listener, counted apart: a history listener added must be removed as one, since
// removeListener on its id is a silent no-op on the other kind's map. A snapshot listener is the pulse client's
// (extension.js's this._client, or client in teardown); the cockpit client's listeners (this._cockpitClient, or
// cockpitClient in teardown) are its one kind, counted apart too. Both are also counted on any receiver, so a listener
// added through another name (an alias, a new client) cannot go unseen.
const ADD_HISTORY_LISTENER_PATTERN = /\.addHistoryListener\(/g;
const ADD_ANY_LISTENER_PATTERN = /\.addListener\(/g;
const REMOVE_ANY_LISTENER_PATTERN = /\.removeListener\(/g;
const REMOVE_HISTORY_LISTENER_PATTERN = /\.removeHistoryListener\(/g;
const ADD_SNAPSHOT_LISTENER_PATTERN = /(?<![\w.])(?:this\._)?client\??\.addListener\(/g;
const REMOVE_SNAPSHOT_LISTENER_PATTERN = /(?<![\w.])(?:this\._)?client\??\.removeListener\(/g;
const ADD_COCKPIT_LISTENER_PATTERN = /(?<![\w.])(?:this\._)?cockpitClient\??\.addListener\(/g;
const REMOVE_COCKPIT_LISTENER_PATTERN = /(?<![\w.])(?:this\._)?cockpitClient\??\.removeListener\(/g;
/** How far extension.js indents a class method's own statements; one level more is inside an if. */
const METHOD_STATEMENT_INDENT = ' '.repeat(8);

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
 * The trimmed lines of a declaration body, for rows that look for one statement.
 *
 * @param {string} bodyText - What declarationBody returned.
 * @returns {string[]} Its lines, trimmed.
 */
const trimmedLines = bodyText => bodyText.split('\n').map(line => line.trim());

/**
 * How many lines of a body are exactly a statement.
 *
 * @param {string} bodyText - What declarationBody returned.
 * @param {string} statement - The statement, trimmed.
 * @returns {number} Its count.
 */
const statementCount = (bodyText, statement) => trimmedLines(bodyText).filter(line => line === statement).length;

/**
 * The handler of each signal that a source text's connectObject calls connect.
 *
 * @param {string} sourceText - A body, or a whole file.
 * @returns {string[]} '<receiver> <signal>: <handler>' for each pair, in order.
 */
function connectedSignalHandlers(sourceText) {
    return [...sourceText.matchAll(CONNECT_OBJECT_PATTERN)].flatMap(([, receiver, connectArguments]) =>
        [...connectArguments.matchAll(SIGNAL_HANDLER_PAIR_PATTERN)]
            .map(([, signalName, handler]) => `${receiver} ${signalName}: ${handler}`));
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
        return {selectorText: selectorText.trim(), classNames, declarations: Object.fromEntries(declarationEntries)};
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
 * One line for a planner step: what it rendered (its CPU text, whether it is dimmed, and whether it changes the dim),
 * or nothing.
 *
 * @param {[string, object|null]} step - The step's name and the plan it returned.
 * @returns {string} For example 'freeze: 23% dimmed=true dimChanged=true', or 'freeze again: nothing'.
 */
function describeDimStep([stepName, repaintPlan]) {
    if (repaintPlan === null)
        return `${stepName}: nothing`;
    const {text, isDimmed, isDimChanged} = repaintPlan;
    return `${stepName}: ${text.cpuValue} dimmed=${isDimmed} dimChanged=${isDimChanged}`;
}

/**
 * The drawing areas a plan redraws besides the CPU graph (which every plan redraws), or null when there is no plan.
 *
 * @param {object|null} repaintPlan - What CardRepaintPlanner returned.
 * @returns {{changedMeterIndexes: number[], isMemoryBarChanged: boolean}|null} The meters and the bar it redraws.
 */
function redrawnGraphics(repaintPlan) {
    if (repaintPlan === null)
        return null;
    const {changedMeterIndexes, isMemoryBarChanged} = repaintPlan;
    return {changedMeterIndexes, isMemoryBarChanged};
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

/**
 * What the cover fallback timer must do (lib/visibility.js coverFallbackTimerChange), read through the namespace.
 *
 * @param {{isCovered: boolean, isServiceLive: boolean, isTimerRunning: boolean}} state - The cover, the service and
 *     the timer.
 * @returns {string} 'start', 'stop' or 'none'.
 */
const fallbackTimerChange = state => visibilityModule.coverFallbackTimerChange(state);

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

test('visibility: a window can cover the card only when it is a normal or dialog window, not minimized, showing ' +
    'and on the active workspace (its frame is read only then, for the overlap with the primary monitor)', () => {
    const coveringWindow = {isNormalOrDialog: true, isMinimized: false, isShowing: true, isOnActiveWorkspace: true};
    const canCoverWithOneChanged = Object.keys(coveringWindow).map(conditionName => {
        const changedWindow = {...coveringWindow, [conditionName]: !coveringWindow[conditionName]};
        return `${conditionName}: ${visibilityModule.canWindowCoverCard(changedWindow)}`;
    });
    assertEqual([visibilityModule.canWindowCoverCard(coveringWindow), ...canCoverWithOneChanged], [
        true,
        'isNormalOrDialog: false',
        'isMinimized: false',
        'isShowing: false',
        'isOnActiveWorkspace: false',
    ]);
});

test('visibility: the windows covering the card are the ones whose rectangle contains all of it, the rule ' +
    'isCardCovered applies; a card with no area has none', () => {
    const ninetyNinePercentRect = {...CARD_RECT, width: CARD_RECT.width * NINETY_NINE_PERCENT};
    const touchingRect = {...CARD_RECT, x: CARD_RECT.x + CARD_RECT.width, width: NEIGHBOUR_WINDOW_SIZE_PX};
    const windowRects = [MAXIMIZED_WINDOW_RECT, ninetyNinePercentRect, {...CARD_RECT}, touchingRect];
    const coveringIndexes = cardRect => visibilityModule.indexesOfRectsCoveringCard({cardRect, windowRects});
    assertEqual({
        covering: coveringIndexes(CARD_RECT),
        withNoArea: coveringIndexes({...CARD_RECT, width: 0}),
        withNoWindows: visibilityModule.indexesOfRectsCoveringCard({cardRect: CARD_RECT, windowRects: []}),
    }, {covering: [0, 2], withNoArea: [], withNoWindows: []});
});

test('visibility: the covering windows are followed by difference: one that starts covering the card is followed, ' +
    'one that stops is released, and the same set in any order follows and releases nothing', () => {
    const [firstWindow, secondWindow, thirdWindow] = ['first', 'second', 'third'].map(name => ({name}));
    const firstWindowAgain = {name: 'first'};
    const describeChanges = (heldWindows, coveringWindows) => {
        const {windowsToFollow, windowsToRelease} =
            visibilityModule.coveringWindowChanges({heldWindows, coveringWindows});
        return {follow: windowsToFollow.map(({name}) => name), release: windowsToRelease.map(({name}) => name)};
    };
    assertEqual({
        changed: describeChanges([firstWindow, secondWindow], [secondWindow, thirdWindow]),
        sameInAnotherOrder: describeChanges([firstWindow, secondWindow], [secondWindow, firstWindow]),
        anotherWindowOfTheSameName: describeChanges([firstWindow], [firstWindowAgain]),
        noneHeldNoneCovering: describeChanges([], []),
    }, {
        changed: {follow: ['third'], release: ['first']},
        sameInAnotherOrder: {follow: [], release: []},
        anotherWindowOfTheSameName: {follow: ['first'], release: ['first']},
        noneHeldNoneCovering: {follow: [], release: []},
    });
});

test('visibility: the cover is checked on every tick while the card is visible', () =>
    assertEqual(visibilityModule.isCoverBackstopDue({isCovered: false, ticksSinceCoverCheck: 0}), true));

test('visibility: a covered card is checked again from the fifteenth tick, not before', () => {
    const isDueAfterTicks = ticksSinceCoverCheck =>
        visibilityModule.isCoverBackstopDue({isCovered: true, ticksSinceCoverCheck});
    assertEqual([COVER_BACKSTOP_TICK - 1, COVER_BACKSTOP_TICK, COVER_BACKSTOP_TICK + 1].map(isDueAfterTicks),
        [false, true, true]);
});

test('visibility: the fallback timer starts for a covered card whose service is silent', () =>
    assertEqual(fallbackTimerChange({isCovered: true, isServiceLive: false, isTimerRunning: false}), 'start'));

test('visibility: the fallback timer stops when the service is live again or the card is revealed', () =>
    assertEqual({
        liveAgain: fallbackTimerChange({isCovered: true, isServiceLive: true, isTimerRunning: true}),
        revealed: fallbackTimerChange({isCovered: false, isServiceLive: false, isTimerRunning: true}),
        revealedAndLive: fallbackTimerChange({isCovered: false, isServiceLive: true, isTimerRunning: true}),
    }, {liveAgain: 'stop', revealed: 'stop', revealedAndLive: 'stop'}));

test('visibility: the fallback timer changes nothing otherwise', () =>
    assertEqual({
        coveredSilentRunning: fallbackTimerChange({isCovered: true, isServiceLive: false, isTimerRunning: true}),
        coveredLiveStopped: fallbackTimerChange({isCovered: true, isServiceLive: true, isTimerRunning: false}),
        visibleSilentStopped: fallbackTimerChange({isCovered: false, isServiceLive: false, isTimerRunning: false}),
        visibleLiveStopped: fallbackTimerChange({isCovered: false, isServiceLive: true, isTimerRunning: false}),
    }, {coveredSilentRunning: 'none', coveredLiveStopped: 'none', visibleSilentStopped: 'none',
        visibleLiveStopped: 'none'}));

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

test('visibility: a fullscreen monitor covers the card on it even with no window over it; otherwise the windows ' +
    'decide', () => {
    const isCovered = (isMonitorInFullscreen, windowRects) =>
        visibilityModule.isCardCovered({isMonitorInFullscreen, cardRect: CARD_RECT, windowRects});
    assertEqual([isCovered(true, []), isCovered(false, []), isCovered(false, [MAXIMIZED_WINDOW_RECT])],
        [true, false, true]);
});

test('visibility: every drawn card is checked on its own (cardsCover): a card one window contains is covered, one ' +
    'only partly under a window is visible; the windows followed are those containing any card, once each, in ' +
    'order; a fullscreen monitor covers every card', () => {
    const neighbourCardRect = {...CARD_RECT, y: CARD_RECT.y + CARD_RECT.height + NEIGHBOUR_WINDOW_SIZE_PX};
    const overFirstCardRect = {...CARD_RECT};
    const overBothCardsRect = {x: CARD_RECT.x, y: CARD_RECT.y, width: CARD_RECT.width,
        height: neighbourCardRect.y + neighbourCardRect.height - CARD_RECT.y};
    const partlyOverNeighbourRect = {...neighbourCardRect, width: neighbourCardRect.width - ONE_PIXEL};
    const cards = [{cardId: 'system', rect: CARD_RECT}, {cardId: 'apps', rect: neighbourCardRect}];
    const cover = (isMonitorInFullscreen, windowRects) =>
        visibilityModule.cardsCover({cards, isMonitorInFullscreen, windowRects});
    assertEqual({
        firstCovered: cover(false, [partlyOverNeighbourRect, overFirstCardRect]),
        bothUnderOneWindow: cover(false, [overBothCardsRect, overFirstCardRect]),
        noWindows: cover(false, []),
        fullscreen: cover(true, [overFirstCardRect]),
    }, {
        firstCovered: {isEveryCardCovered: false, coveredCardIds: ['system'], visibleCardIds: ['apps'],
            coveringWindowIndexes: [1]},
        bothUnderOneWindow: {isEveryCardCovered: true, coveredCardIds: ['system', 'apps'], visibleCardIds: [],
            coveringWindowIndexes: [0, 1]},
        noWindows: {isEveryCardCovered: false, coveredCardIds: [], visibleCardIds: ['system', 'apps'],
            coveringWindowIndexes: []},
        fullscreen: {isEveryCardCovered: true, coveredCardIds: ['system', 'apps'], visibleCardIds: [],
            coveringWindowIndexes: [0]},
    });
});

test('visibility: with no card drawn (a layout naming none this release knows) every card counts as covered, so ' +
    'nothing is checked on every tick and no watch is held for it', () =>
    assertEqual(visibilityModule.cardsCover({cards: [], isMonitorInFullscreen: false, windowRects: []}), {
        isEveryCardCovered: true, coveredCardIds: [], visibleCardIds: [], coveringWindowIndexes: [],
    }));

test('visibility: a card newly covered is stamped as painted now (its freeze), one still covered keeps its stamp, ' +
    'and a revealed card loses its stamp (frozenPaintStamps)', () => {
    const systemPaintedAtUsec = 7 * USEC_PER_SECOND;
    const appsPaintedAtUsec = 9 * USEC_PER_SECOND;
    const nowUsec = 40 * USEC_PER_SECOND;
    assertEqual(visibilityModule.frozenPaintStamps({
        stampsByCardId: {system: systemPaintedAtUsec, apps: appsPaintedAtUsec},
        coveredCardIds: ['system', 'sessions'],
        nowUsec,
    }), {system: systemPaintedAtUsec, sessions: nowUsec});
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

test('card repaint: data after no data repaints all three meters and the memory bar', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(NO_DATA_SNAPSHOT, null));
    const dataPlan = summarizeRepaintPlan(planner.show(shownState(SNAPSHOT, MEMORY_FRACTION)));
    assertEqual([dataPlan?.changedMeterIndexes, dataPlan?.isMemoryBarChanged], [ALL_METER_INDEXES, true]);
});

test('card repaint: the memory bar repaints only when its filled width changes by a whole pixel', () => {
    const fractionFilling = fillPx => fillPx / CARD_MEMORY_BAR_WIDTH_PX;
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(SNAPSHOT, fractionFilling(WHOLE_PIXEL_FILL_PX)));
    assertEqual([
        planner.show(shownState(SNAPSHOT, fractionFilling(SAME_PIXEL_FILL_PX))),
        planner.show(shownState(SNAPSHOT, fractionFilling(NEXT_PIXEL_FILL_PX))),
    ].map(repaintPlan => repaintPlan?.isMemoryBarChanged), [false, true]);
});

test('card repaint: while frozen a snapshot is only recorded; unfreezing renders at once from the latest one, with ' +
    'its clock label', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    planner.setFrozen(true);
    const plansWhileFrozen = [
        planner.show(shownState(BUSIER_SNAPSHOT, HIGHER_MEMORY_FRACTION)),
        planner.show(shownState(NO_DATA_SNAPSHOT, null, LATER_CLOCK_LABEL)),
    ];
    assertEqual({
        plansWhileFrozen: plansWhileFrozen.map(summarizeRepaintPlan),
        reveal: summarizeRepaintPlan(planner.setFrozen(false)),
    }, {
        plansWhileFrozen: [null, null],
        reveal: {cpuValue: 'no data since 14:05', changedMeterIndexes: ALL_METER_INDEXES, isMemoryBarChanged: true,
            memoryFraction: null},
    });
});

test('card repaint: freezing and unfreezing each render once (the freeze dimmed, the reveal at once and undimmed), ' +
    'and setFrozen to the state the card already has does nothing: a second freeze or unfreeze renders nothing', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    const plans = [
        planner.setFrozen(false),
        planner.setFrozen(true),
        planner.setFrozen(true),
        planner.setFrozen(false),
        planner.setFrozen(false),
    ];
    assertEqual(plans.map(repaintPlan => repaintPlan !== null), [false, true, false, true, false]);
});

test('card repaint: a frozen repaint compares with what is drawn, so a value that changed while frozen and changed ' +
    'back repaints nothing', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    planner.setFrozen(true);
    planner.show(shownState(IO_BOUND_SNAPSHOT, HIGHER_MEMORY_FRACTION));
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    const frozenRepaint = summarizeRepaintPlan(planner.repaintFrozen());
    assertEqual([frozenRepaint?.changedMeterIndexes, frozenRepaint?.isMemoryBarChanged], [[], false]);
});

test('card repaint: the dim follows the freeze exactly: freezing renders once, dimmed (card.js adds the frozen ' +
    'pseudo-class); a frozen repaint renders the latest state, still dimmed; unfreezing renders at once, undimmed ' +
    '(the pseudo-class removed); nothing else changes the dim', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    const steps = [
        ['live', planner.show(shownState(SNAPSHOT, MEMORY_FRACTION))],
        ['freeze', planner.setFrozen(true)],
        ['freeze again', planner.setFrozen(true)],
        ['sample while frozen', planner.show(shownState(BUSIER_SNAPSHOT, MEMORY_FRACTION))],
        ['frozen repaint', planner.repaintFrozen()],
        ['unfreeze', planner.setFrozen(false)],
        ['unfreeze again', planner.setFrozen(false)],
        ['frozen repaint while live', planner.repaintFrozen()],
        ['live again', planner.show(shownState(SNAPSHOT, MEMORY_FRACTION))],
    ];
    assertEqual(steps.map(describeDimStep), [
        'live: 23% dimmed=false dimChanged=false',
        'freeze: 23% dimmed=true dimChanged=true',
        'freeze again: nothing',
        'sample while frozen: nothing',
        'frozen repaint: 57% dimmed=true dimChanged=false',
        'unfreeze: 57% dimmed=false dimChanged=true',
        'unfreeze again: nothing',
        'frozen repaint while live: nothing',
        'live again: 23% dimmed=false dimChanged=false',
    ]);
});

test('card repaint: a change of dim redraws all three meters and the memory bar, which paint at the new opacity; a ' +
    'frozen repaint with the dim unchanged redraws only what changed', () => {
    const planner = new cardRepaintModule.CardRepaintPlanner();
    planner.show(shownState(SNAPSHOT, MEMORY_FRACTION));
    const freezePlan = planner.setFrozen(true);
    planner.show(shownState(IO_BOUND_SNAPSHOT, MEMORY_FRACTION));
    const frozenRepaintPlan = planner.repaintFrozen();
    const revealPlan = planner.setFrozen(false);
    assertEqual([freezePlan, frozenRepaintPlan, revealPlan].map(redrawnGraphics), [
        {changedMeterIndexes: ALL_METER_INDEXES, isMemoryBarChanged: true},
        {changedMeterIndexes: [IO_METER_INDEX], isMemoryBarChanged: false},
        {changedMeterIndexes: ALL_METER_INDEXES, isMemoryBarChanged: true},
    ]);
});

test('visibility: a frozen card is due a repaint 30 s after it was last painted, and not before; asked on every 2 s ' +
    'Sample from the freeze, it repaints at 30 s and at 60 s', () => {
    const isDueAfterUsec = elapsedUsec =>
        visibilityModule.isFrozenRepaintDue({lastFrozenPaintAtUsec: 0, nowUsec: elapsedUsec});
    const repaintSeconds = [];
    let lastFrozenPaintAtUsec = 0;
    for (let elapsedSeconds = SAMPLE_TICK_SECONDS; elapsedSeconds <= FROZEN_RUN_SECONDS;
        elapsedSeconds += SAMPLE_TICK_SECONDS) {
        const nowUsec = elapsedSeconds * USEC_PER_SECOND;
        if (visibilityModule.isFrozenRepaintDue({lastFrozenPaintAtUsec, nowUsec})) {
            repaintSeconds.push(elapsedSeconds);
            lastFrozenPaintAtUsec = nowUsec;
        }
    }
    assertEqual({
        justBefore: isDueAfterUsec(FROZEN_REPAINT_SECONDS * USEC_PER_SECOND - ONE_USEC),
        atTheInterval: isDueAfterUsec(FROZEN_REPAINT_SECONDS * USEC_PER_SECOND),
        repaintSeconds,
    }, {justBefore: false, atTheInterval: true, repaintSeconds: [FROZEN_REPAINT_SECONDS, 2 * FROZEN_REPAINT_SECONDS]});
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

/**
 * Converts a CSS length the card's stylesheet uses to pixels.
 *
 * @param {string|undefined} cssLength - For example '12px' or '1.3em'.
 * @param {number} emPx - One em, in pixels.
 * @returns {number} The length in pixels.
 * @throws {Error} For a length this row does not read, or none.
 */
function cssLengthPx(cssLength, emPx) {
    const lengthMatch = CSS_LENGTH_PATTERN.exec(cssLength ?? '');
    if (lengthMatch === null)
        throw new Error(`cannot read the CSS length '${cssLength}'`);
    const [, amountText, unit] = lengthMatch;
    return unit === 'em' ? Number(amountText) * emPx : Number(amountText);
}

test('the card\'s fixed width fits its widest rows plus a small margin, measured with Pango in its font: "no data ' +
    'since", a full CPU line, a 100+ GiB memory line, the widest swap line, "waiting on", and "heaviest" with both ' +
    'names cut short', async () => {
    const {default: Pango} = await import('gi://Pango?version=1.0');
    const {default: PangoCairo} = await import('gi://PangoCairo?version=1.0');
    const rules = stylesheetRules(readExtensionFile('stylesheet.css'));
    const style = className => declarationsOfClass(rules, className);
    const fixedWidth = style(FIXED_WIDTH_CLASS_NAME);
    const fontFamily = CSS_FIRST_FONT_FAMILY_PATTERN.exec(style(CARD_CLASS_NAME)['font-family'] ?? '')?.[1];
    const pangoContext = PangoCairo.FontMap.get_default().create_context();
    PangoCairo.context_set_resolution(pangoContext, FONT_RESOLUTION_DPI);
    const fontDescriptionOf = (sizeEm, fontWeight) => {
        const fontDescription = Pango.FontDescription.from_string(fontFamily ?? CARD_FONT_FAMILY);
        fontDescription.set_size(Math.round(SHELL_FONT_SIZE_PT * sizeEm * Pango.SCALE));
        fontDescription.set_weight(fontWeight === BOLD_FONT_WEIGHT ? Pango.Weight.BOLD : Pango.Weight.NORMAL);
        return fontDescription;
    };
    const textPx = (text, sizeEm = 1, fontWeight = undefined) => {
        const layout = Pango.Layout.new(pangoContext);
        layout.set_font_description(fontDescriptionOf(sizeEm, fontWeight));
        const attributes = new Pango.AttrList();
        attributes.insert(Pango.attr_font_features_new(TABULAR_DIGITS_FEATURE));
        layout.set_attributes(attributes);
        layout.set_text(text, -1);
        const [, logicalRect] = layout.get_pixel_extents();
        return logicalRect.width;
    };
    const figureStyle = style('resource-pulse-card-figure');
    const figurePx = text => textPx(text, cssLengthPx(figureStyle['font-size'], 1), figureStyle['font-weight']);
    const suffixPx = text => textPx(text, cssLengthPx(style('resource-pulse-card-suffix')['font-size'], 1));
    const spacingPx = className => cssLengthPx(style(className).spacing, EM_PX);
    const gridColumnSpacingPx = cssLengthPx(style('resource-pulse-card-meters')['spacing-columns'], EM_PX);
    const detailRowSpacingPx = spacingPx('resource-pulse-card-detail-row');
    const heaviestPartsSpacingPx = spacingPx('rp-card-heaviest-parts');

    const noDataText = cardText(NO_DATA_SNAPSHOT, LATEST_CLOCK_LABEL);
    const fullCpuText = cardText(FULL_CPU_SNAPSHOT, LATEST_CLOCK_LABEL);
    const largeMachineText = cardText(LARGE_MACHINE_SNAPSHOT, LATEST_CLOCK_LABEL);
    const labelColumnPx = Math.max(...[noDataText.cpuLabel, noDataText.memoryLabel, noDataText.swapLabel].map(
        label => textPx(label)));
    const fullCpuFigurePx = figurePx(fullCpuText.cpuValue) + spacingPx('resource-pulse-card-cpu-figure') +
        suffixPx(fullCpuText.cpuClusterSuffix);
    const gridRowPx = valuePx => labelColumnPx + gridColumnSpacingPx + valuePx + gridColumnSpacingPx +
        CARD_CPU_GRAPH_WIDTH_PX;
    const pressureMetersPx = noDataText.waitingOnMeters
        .map(({label}) => textPx(label) + spacingPx('resource-pulse-card-pressure-group') + PRESSURE_METER_WIDTH_PX)
        .reduce((sumPx, meterPx) => sumPx + meterPx, 0) +
        (noDataText.waitingOnMeters.length - 1) * spacingPx('resource-pulse-card-pressure-meters');
    const {heaviestRow} = largeMachineText;
    const shortenedName = name => `${name.slice(0, HEAVIEST_NAME_SHOWN_CHARS)}${ELLIPSIS}`;
    const heaviestPartTexts = [shortenedName(heaviestRow.cpuName), heaviestRow.cpuValue, heaviestRow.separator,
        shortenedName(heaviestRow.memoryName), heaviestRow.memoryValue];
    const heaviestPartsPx = heaviestPartTexts.map(partText => textPx(partText))
        .reduce((sumPx, partPx) => sumPx + partPx, 0) + (heaviestPartTexts.length - 1) * heaviestPartsSpacingPx;
    const rowWidthsPx = {
        'no data since': gridRowPx(figurePx(noDataText.cpuValue)),
        'full CPU': gridRowPx(fullCpuFigurePx),
        '100+ GiB memory': gridRowPx(figurePx(largeMachineText.memoryValue)),
        'widest swap': labelColumnPx + gridColumnSpacingPx + textPx(largeMachineText.swapValue),
        'waiting on': textPx(noDataText.waitingOnLabel) + detailRowSpacingPx + pressureMetersPx,
        'heaviest': textPx(largeMachineText.heaviestLabel) + detailRowSpacingPx + heaviestPartsPx,
    };
    const [widestRowName, widestRowPx] = Object.entries(rowWidthsPx)
        .reduce((widest, row) => (row[1] > widest[1] ? row : widest));
    const contentWidthPx = cssLengthPx(fixedWidth.width, EM_PX);
    const neededWidthPx = widestRowPx + CARD_WIDTH_MARGIN_PX;
    const loadedFamily = pangoContext.load_font(fontDescriptionOf(1)).describe().get_family();
    assertEqual({
        loadedFamily,
        isFixed: fixedWidth['min-width'] === fixedWidth.width && fixedWidth['max-width'] === fixedWidth.width,
        fitsWithMargin: neededWidthPx <= contentWidthPx,
        isAtMostOneEmWider: contentWidthPx <= neededWidthPx + EM_PX,
        keepsTheV1MinWidthRule: style(CARD_CLASS_NAME)['min-width'] !== undefined,
    }, {
        loadedFamily: CARD_FONT_FAMILY,
        isFixed: true,
        fitsWithMargin: true,
        isAtMostOneEmWider: true,
        keepsTheV1MinWidthRule: true,
    }, `widest row "${widestRowName}" is ${widestRowPx} px, plus ${CARD_WIDTH_MARGIN_PX} px margin; ` +
        `rp-card-fixed is ${fixedWidth.width} = ${contentWidthPx.toFixed(1)} px; rows ${JSON.stringify(rowWidthsPx)}`);
});

test('card.js puts the fixed-width class on the card', () => {
    const cardSource = readExtensionFile('card.js');
    assertEqual([
        cardSource.includes(`const FIXED_WIDTH_STYLE_CLASS = '${FIXED_WIDTH_CLASS_NAME}';`),
        cardSource.includes('style_class: `${CARD_STYLE_CLASS} ${FIXED_WIDTH_STYLE_CLASS}`,'),
    ], [true, true]);
});

test('card.js: a dim change adds the frozen pseudo-class (dimmed) or removes it (undimmed), and nothing else touches ' +
    'it; the frozen repaint applies the planner\'s plan; every graph colour is scaled by the opacity the stylesheet ' +
    'gives', () => {
    const cardSource = readExtensionFile('card.js');
    const applyLines = trimmedLines(declarationBody(cardSource, '_applyRepaintPlan(repaintPlan) {'));
    const showDimmedLines = trimmedLines(declarationBody(cardSource, '_showDimmed(isDimmed) {'));
    const lineAfter = (lines, line) => (lines.includes(line) ? lines[lines.indexOf(line) + 1] : null);
    const pseudoClassCalls = cardSource.split('\n').filter(line => !COMMENT_LINE_PATTERN.test(line))
        .filter(line => line.includes('_style_pseudo_class(')).map(line => line.trim());
    assertEqual({
        pseudoClassName: cardSource.includes(`const FROZEN_PSEUDO_CLASS = '${FROZEN_PSEUDO_CLASS_NAME}';`),
        onADimChange: lineAfter(applyLines, 'if (isDimChanged)'),
        whenDimmed: lineAfter(showDimmedLines, 'if (isDimmed)'),
        otherwise: lineAfter(showDimmedLines, 'else'),
        pseudoClassCalls,
        repaintFrozenApplies: statementCount(declarationBody(cardSource, 'repaintFrozen() {'),
            'this._applyRepaintPlan(this._repaintPlanner.repaintFrozen());'),
        opacityProperty: cardSource.includes(`const GRAPH_OPACITY_PROPERTY = '${GRAPH_OPACITY_PROPERTY_NAME}';`),
        readsTheProperty: declarationBody(cardSource, '_graphOpacity() {')
            .includes('this.get_theme_node().lookup_double(GRAPH_OPACITY_PROPERTY, false);'),
        dimmedGraphColours: (cardSource.match(/withOpacity\([A-Z_]+_RGBA, graphOpacity\)/g) ?? []).length,
    }, {
        pseudoClassName: true,
        onADimChange: 'this._showDimmed(isDimmed);',
        whenDimmed: 'this.add_style_pseudo_class(FROZEN_PSEUDO_CLASS);',
        otherwise: 'this.remove_style_pseudo_class(FROZEN_PSEUDO_CLASS);',
        pseudoClassCalls: [
            'this.add_style_pseudo_class(FROZEN_PSEUDO_CLASS);',
            'this.remove_style_pseudo_class(FROZEN_PSEUDO_CLASS);',
        ],
        repaintFrozenApplies: 1,
        opacityProperty: true,
        readsTheProperty: true,
        dimmedGraphColours: DIMMED_GRAPH_COLOUR_COUNT,
    });
});

test('stylesheet.css dims the frozen card in a rule of its own (.resource-pulse-card:frozen): the colour its value ' +
    'labels take, and the opacity card.js gives its graphs, each to a fraction', () => {
    const rules = stylesheetRules(readExtensionFile('stylesheet.css'));
    const frozenCardStyle = Object.assign({}, ...rules
        .filter(rule => rule.selectorText === FROZEN_CARD_SELECTOR).map(rule => rule.declarations));
    const valueColourAlpha = Number(CSS_RGBA_ALPHA_PATTERN.exec(frozenCardStyle.color ?? '')?.[1]);
    const graphOpacity = Number(frozenCardStyle[GRAPH_OPACITY_PROPERTY_NAME]);
    const isFraction = value => value > 0 && value < 1;
    assertEqual({
        valuesDimmed: isFraction(valueColourAlpha),
        graphsDimmed: isFraction(graphOpacity),
        valueLabelsTakeTheCardsColour: VALUE_CLASS_NAMES.filter(className =>
            declarationsOfClass(rules, className).color !== undefined),
    }, {valuesDimmed: true, graphsDimmed: true, valueLabelsTakeTheCardsColour: []},
    `frozen card rule: ${JSON.stringify(frozenCardStyle)}`);
});

test('extension.js: while a card is frozen every tick, whether or not the backstop checked the cover, and the ' +
    'fallback timeout repaint it, dimmed, once frozenCardsDueRepaint says so, timing from its freeze and then from ' +
    'each repaint (only frozen cards hold a stamp: a revealed card is left to the reveal); the v2 card top right ' +
    'repaints from the client\'s latest, the cockpit\'s cards through the layer', () => {
    const extensionSource = readExtensionFile('extension.js');
    const tickLines = declarationBody(extensionSource, '_onCardCoverTick() {').split('\n');
    const timeoutLines = trimmedLines(declarationBody(extensionSource, '_onCoverFallbackTimeout() {'));
    const repaintBody = declarationBody(extensionSource, '_repaintFrozenCardsIfDue() {');
    const repaintOneLines = trimmedLines(declarationBody(extensionSource, '_repaintFrozenCard(cardId) {'));
    const syncLines = trimmedLines(declarationBody(extensionSource, '_syncCardCover() {'));
    const lineAfter = (lines, line) => (lines.includes(line) ? lines[lines.indexOf(line) + 1] : null);
    const stampStatement = 'this._frozenCardPaintedAtUsecByCardId = frozenPaintStamps({';
    const stampIndex = syncLines.indexOf(stampStatement);
    assertEqual({
        everyTickAsksOutsideTheBackstop: tickLines
            .filter(line => line === `${METHOD_STATEMENT_INDENT}this._repaintFrozenCardsIfDue();`).length,
        afterTheFallbackCheck: lineAfter(timeoutLines, 'this._syncCardCover();'),
        decides: repaintBody.includes('const dueCardIds = frozenCardsDueRepaint({'),
        // Only the due cards: iterating every stamp would repaint every frozen card on every tick.
        iteratesTheDueCards: statementCount(repaintBody, 'for (const cardId of dueCardIds) {'),
        readsTheFrozenStamps: statementCount(repaintBody,
            'frozenPaintedAtUsecByCardId: this._frozenCardPaintedAtUsecByCardId,'),
        recordsEachRepaint: statementCount(repaintBody, 'this._frozenCardPaintedAtUsecByCardId[cardId] = nowUsec;'),
        repaintsEachDueCard: statementCount(repaintBody, 'this._repaintFrozenCard(cardId);'),
        repaintsOne: repaintOneLines.slice(1, -1),
        timesFromTheFreeze: lineAfter(syncLines, stampStatement),
        stampsBeforeRecordingTheCover: stampIndex >= 0 &&
            stampIndex < syncLines.indexOf('this._isCardVisible = !isCovered;'),
    }, {
        everyTickAsksOutsideTheBackstop: 1,
        afterTheFallbackCheck: 'this._repaintFrozenCardsIfDue();',
        decides: true,
        iteratesTheDueCards: 1,
        readsTheFrozenStamps: 1,
        recordsEachRepaint: 1,
        repaintsEachDueCard: 1,
        repaintsOne: [
            'if (this._layer !== null) {', 'this._layer.repaintFrozenCard(cardId);', 'return;', '}',
            'const client = this._client;', 'this._card.update(client.latestSnapshot, client.lastGoodClockLabel);',
            'this._card.repaintFrozen();',
        ],
        timesFromTheFreeze: 'stampsByCardId: this._frozenCardPaintedAtUsecByCardId, coveredCardIds, ' +
            'nowUsec: GLib.get_monotonic_time(),',
        stampsBeforeRecordingTheCover: true,
    });
});

test('extension.js checks the cover on a restack, a window created or leaving a monitor, a fullscreen change, a ' +
    'minimize, an unminimize, a size change, the end of a drag, a workspace switch, "show desktop", every client ' +
    'update and a covering window\'s move, ' +
    'resize, move to another workspace or close, and its teardown disconnects every object it connects to (the ' +
    'covering windows through _disconnectCoveringWindows) and removes that history listener as one', () => {
    const extensionSource = readExtensionFile('extension.js');
    const tearDownBody = declarationBody(extensionSource, '_tearDown() {');
    const tearDownDisconnectsTheCoveringWindows = tearDownBody.includes('() => this._disconnectCoveringWindows()');
    const disconnectingText = tearDownDisconnectsTheCoveringWindows
        ? `${tearDownBody}\n${declarationBody(extensionSource, '_disconnectCoveringWindows() {')}`
        : tearDownBody;
    const connectedSignals = [...extensionSource.matchAll(CONNECT_OBJECT_PATTERN)].flatMap(
        ([, receiver, connectArguments]) => [...connectArguments.matchAll(QUOTED_SIGNAL_NAME_PATTERN)]
            .map(([, signalName]) => `${receiver} ${signalName}`));
    const connectedReceivers = new Set([...extensionSource.matchAll(CONNECT_OBJECT_PATTERN)]
        .map(([, receiver]) => receiver.replace(OWN_FIELD_PREFIX_PATTERN, '')));
    const disconnectedReceivers = new Set([...disconnectingText.matchAll(DISCONNECT_OBJECT_PATTERN)]
        .map(([, receiver]) => receiver.replace(OWN_FIELD_PREFIX_PATTERN, '')));
    const countMatches = (text, pattern) => (text.match(pattern) ?? []).length;
    assertEqual({
        connectedSignals: connectedSignals.sort(),
        receiversNeverDisconnected: [...connectedReceivers].filter(receiver => !disconnectedReceivers.has(receiver)),
        historyListenersAdded: countMatches(extensionSource, ADD_HISTORY_LISTENER_PATTERN),
        snapshotListenersAdded: countMatches(extensionSource, ADD_SNAPSHOT_LISTENER_PATTERN),
        cockpitListenersAdded: countMatches(extensionSource, ADD_COCKPIT_LISTENER_PATTERN),
        historyListenersRemovedOnTeardown: countMatches(tearDownBody, REMOVE_HISTORY_LISTENER_PATTERN),
        snapshotListenersRemovedOnTeardown: countMatches(tearDownBody, REMOVE_SNAPSHOT_LISTENER_PATTERN),
        cockpitListenersRemovedOnTeardown: countMatches(tearDownBody, REMOVE_COCKPIT_LISTENER_PATTERN),
        listenersAddedOnAnyReceiver: countMatches(extensionSource, ADD_ANY_LISTENER_PATTERN),
        listenersRemovedOnTeardownFromAnyReceiver: countMatches(tearDownBody, REMOVE_ANY_LISTENER_PATTERN),
    }, {
        connectedSignals: [
            'Main.layoutManager monitors-changed',
            'Main.overview hidden',
            'Main.overview showing',
            'global.display grab-op-end',
            'global.display in-fullscreen-changed',
            'global.display restacked',
            'global.display window-created',
            'global.display window-left-monitor',
            'global.display workareas-changed',
            'global.window_manager minimize',
            'global.window_manager size-changed',
            'global.window_manager switch-workspace',
            'global.window_manager unminimize',
            'global.workspace_manager showing-desktop-changed',
            'metaWindow position-changed',
            'metaWindow size-changed',
            'metaWindow unmanaged',
            'metaWindow workspace-changed',
            'this._card notify::width',
            'this._dropdownMenu open-state-changed',
        ],
        receiversNeverDisconnected: [],
        historyListenersAdded: 1,
        snapshotListenersAdded: 0,
        cockpitListenersAdded: 1,
        historyListenersRemovedOnTeardown: 1,
        snapshotListenersRemovedOnTeardown: 0,
        cockpitListenersRemovedOnTeardown: 1,
        listenersAddedOnAnyReceiver: 1,
        listenersRemovedOnTeardownFromAnyReceiver: 1,
    });
});

test('extension.js: enable() follows the cover right after adding the card, before starting the client', () => {
    const enableBody = declarationBody(readExtensionFile('extension.js'), 'enable() {');
    const stepStatements = ['this._addCard();', 'this._followCardCover();', 'this._client.start();'];
    const stepLineIndexes = stepStatements.map(statement => trimmedLines(enableBody).indexOf(statement));
    assertEqual({
        counts: stepStatements.map(statement => statementCount(enableBody, statement)),
        areConsecutive: stepLineIndexes.every((lineIndex, stepIndex) =>
            stepIndex === 0 || lineIndex === stepLineIndexes[stepIndex - 1] + 1),
    }, {counts: [1, 1, 1], areConsecutive: true});
});

test('extension.js: _placeCard() places the v2 card top right only while no cockpit layer is shown (the system ' +
    'cell holds it otherwise, so it is never drawn twice: Review Focus 1), else the layer, and checks the cover ' +
    'right after placing', () =>
    assertEqual(trimmedLines(declarationBody(readExtensionFile('extension.js'), '_placeCard() {')).slice(1, -1), [
        'if (this._layer === null)', 'this._card?.placeOnPrimaryMonitor();', 'else', 'this._placeCockpitLayer();',
        'this._syncCardCover();',
    ]));

test('extension.js: _syncCardCover() freezes each covered card and unfreezes each visible one, records whether any ' +
    'can be seen and which, restarts the backstop\'s count, sets the layer\'s interactivity, follows the covering ' +
    'windows, and updates the fallback timeout, the detail watch and the cockpit\'s watch; each loop freezes the ' +
    'cards it names as its pair says (the covered frozen, the visible unfrozen)', () => {
    const syncBody = declarationBody(readExtensionFile('extension.js'), '_syncCardCover() {');
    const syncLines = trimmedLines(syncBody);
    const lineAfter = (lines, line) => (lines.includes(line) ? lines[lines.indexOf(line) + 1] : null);
    const statements = [
        'const {isCovered, coveredCardIds, visibleCardIds, coveringWindows, isCockpitInteractive} =',
        'this._readCardCover();',
        'this._ticksSinceCoverCheck = 0;',
        'this._followCoveringWindows(coveringWindows);',
        'for (const cardId of coveredCardIds)',
        'this._setCardFrozen(cardId, true);',
        'for (const cardId of visibleCardIds)',
        'this._setCardFrozen(cardId, false);',
        'this._isCardVisible = !isCovered;',
        'this._visibleCardIds = visibleCardIds;',
        'this._layer?.setInteractive(isCockpitInteractive);',
        'this._syncCoverFallbackTimer();',
        'this._syncDetailWatch();',
        'this._syncCockpitWatch();',
    ];
    assertEqual({
        counts: statements.map(statement => statementCount(syncBody, statement)),
        coveredLoopFreezes: lineAfter(syncLines, 'for (const cardId of coveredCardIds)'),
        visibleLoopUnfreezes: lineAfter(syncLines, 'for (const cardId of visibleCardIds)'),
    }, {
        counts: statements.map(() => 1),
        coveredLoopFreezes: 'this._setCardFrozen(cardId, true);',
        visibleLoopUnfreezes: 'this._setCardFrozen(cardId, false);',
    });
});

test('extension.js: the bursty window-manager, display and covering-window triggers queue the one coalesced cover ' +
    'check, while each client tick (counted first, then behind the backstop) and the fallback timeout check at once ' +
    'with no later', () => {
    const extensionSource = readExtensionFile('extension.js');
    const followBody = declarationBody(extensionSource, '_followCardCover() {');
    const followWindowBody = declarationBody(extensionSource, '_startFollowingCoveringWindow(metaWindow) {');
    const tickBody = declarationBody(extensionSource, '_onCardCoverTick() {');
    const timeoutBody = declarationBody(extensionSource, '_onCoverFallbackTimeout() {');
    const tickLines = trimmedLines(tickBody);
    const coverSignalHandlers = connectedSignalHandlers(`${followBody}\n${followWindowBody}`)
        .filter(signalHandler => COVER_SIGNAL_RECEIVERS.has(signalHandler.split(' ')[0]));
    const queueingStatement = 'const queueCardCoverCheck = () => this._queueCardCoverCheck();';
    const backstopCondition = 'if (isCoverBackstopDue({isCovered, ticksSinceCoverCheck: this._ticksSinceCoverCheck}))';
    const linesQueuingALater = bodyText =>
        trimmedLines(bodyText).filter(line => line.includes('_queueCardCoverCheck')).length;
    assertEqual({
        coverSignalHandlers,
        queuesTheCheck: [statementCount(followBody, queueingStatement), statementCount(followWindowBody,
            queueingStatement)],
        clientListenerTicks: statementCount(followBody,
            'this._cardCoverListenerId = this._client.addHistoryListener(() => this._onCardCoverTick());'),
        tickCountedBeforeTheBackstop: tickLines[1] === 'this._ticksSinceCoverCheck += 1;' &&
            tickLines.indexOf(backstopCondition) > 1,
        backstopChecksAtOnce: tickLines.includes(backstopCondition)
            ? tickLines[tickLines.indexOf(backstopCondition) + 1] : null,
        fallbackChecksAtOnce: statementCount(timeoutBody, 'this._syncCardCover();'),
        linesQueuingALater: [linesQueuingALater(tickBody), linesQueuingALater(timeoutBody)],
    }, {
        coverSignalHandlers: [
            'global.display restacked: queueCardCoverCheck',
            'global.display window-created: queueCardCoverCheck',
            'global.display window-left-monitor: queueCardCoverCheck',
            'global.display in-fullscreen-changed: queueCardCoverCheck',
            'global.display grab-op-end: queueCardCoverCheck',
            'global.window_manager minimize: queueCardCoverCheck',
            'global.window_manager unminimize: queueCardCoverCheck',
            'global.window_manager size-changed: queueCardCoverCheck',
            'global.window_manager switch-workspace: queueCardCoverCheck',
            'global.workspace_manager showing-desktop-changed: queueCardCoverCheck',
            'metaWindow position-changed: queueCardCoverCheck',
            'metaWindow size-changed: queueCardCoverCheck',
            'metaWindow workspace-changed: queueCardCoverCheck',
            'metaWindow unmanaged: () => this._onCoveringWindowUnmanaged(metaWindow)',
        ],
        queuesTheCheck: [1, 1],
        clientListenerTicks: 1,
        tickCountedBeforeTheBackstop: true,
        backstopChecksAtOnce: 'this._syncCardCover();',
        fallbackChecksAtOnce: 1,
        linesQueuingALater: [0, 0],
    });
});

test('extension.js follows exactly the windows covering the card, connecting and disconnecting only the ' +
    'difference (coveringWindowChanges); a covering window closed is dropped at once, before the cover is checked ' +
    'again; teardown empties the set and disconnects every one', () => {
    const extensionSource = readExtensionFile('extension.js');
    const followBody = declarationBody(extensionSource, '_followCoveringWindows(coveringWindows) {');
    const readBody = declarationBody(extensionSource, '_readCardCover() {');
    const disconnectLines = trimmedLines(declarationBody(extensionSource, '_disconnectCoveringWindows() {'));
    assertEqual({
        coveringFromThePureRule: readBody.includes('coveringWindows: coveringWindowIndexes.map(windowIndex => ' +
            'metaWindows[windowIndex]),') && readBody.includes('= cardsCover({'),
        decidesByDifference: followBody.includes('coveringWindowChanges({'),
        releasesTheOnesToRelease: statementCount(followBody, 'this._stopFollowingCoveringWindow(metaWindow);'),
        followsTheOnesToFollow: statementCount(followBody, 'this._startFollowingCoveringWindow(metaWindow);'),
        recordsAFollowedWindow: statementCount(declarationBody(extensionSource,
            '_startFollowingCoveringWindow(metaWindow) {'), 'this._coveringWindows.add(metaWindow);'),
        stopForgetsThenDisconnects: trimmedLines(declarationBody(extensionSource,
            '_stopFollowingCoveringWindow(metaWindow) {')).slice(1, 3),
        onClose: trimmedLines(declarationBody(extensionSource, '_onCoveringWindowUnmanaged(metaWindow) {')).slice(1, 3),
        teardownEmptiesThenDisconnects: [
            disconnectLines.indexOf('this._coveringWindows.clear();') >= 0,
            disconnectLines.indexOf('this._coveringWindows.clear();') <
                disconnectLines.indexOf('metaWindow.disconnectObject(this);'),
        ],
    }, {
        coveringFromThePureRule: true,
        decidesByDifference: true,
        releasesTheOnesToRelease: 1,
        followsTheOnesToFollow: 1,
        recordsAFollowedWindow: 1,
        stopForgetsThenDisconnects: ['this._coveringWindows.delete(metaWindow);', 'metaWindow.disconnectObject(this);'],
        onClose: ['this._stopFollowingCoveringWindow(metaWindow);', 'this._queueCardCoverCheck();'],
        teardownEmptiesThenDisconnects: [true, true],
    });
});

test('extension.js: the cover check is coalesced into one BEFORE_REDRAW later that runs the cover sync, and ' +
    'teardown cancels it', () => {
    const extensionSource = readExtensionFile('extension.js');
    const queueBody = declarationBody(extensionSource, '_queueCardCoverCheck() {');
    assertEqual({
        returnsWhileQueued: statementCount(queueBody, 'if (this._cardCoverCheckLaterId !== null)'),
        addsABeforeRedrawLater: queueBody.includes('global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW,'),
        runsTheCoverSync: statementCount(queueBody, 'this._syncCardCover();'),
        cancelRemovesIt: statementCount(declarationBody(extensionSource, '_cancelCardCoverCheck() {'),
            'global.compositor.get_laters().remove(laterId);'),
        teardownCancels: statementCount(declarationBody(extensionSource, '_tearDown() {'),
            '{name: \'cancel the pending cover check\', run: () => this._cancelCardCoverCheck()},'),
    }, {
        returnsWhileQueued: 1, addsABeforeRedrawLater: true, runsTheCoverSync: 1, cancelRemovesIt: 1,
        teardownCancels: 1,
    });
});

test('extension.js: the cover check\'s later never throws out of its callback, which runs inside the compositor\'s ' +
    'frame: it forgets its id, runs the cover sync inside a try whose catch logs the failure, and returns ' +
    'GLib.SOURCE_REMOVE after the try, on every path', () => {
    const queueLines = trimmedLines(declarationBody(readExtensionFile('extension.js'), '_queueCardCoverCheck() {'));
    const addLineIndex = queueLines.findIndex(line =>
        line.startsWith('this._cardCoverCheckLaterId = global.compositor.get_laters().add('));
    assertEqual({
        callbackOpening: addLineIndex < 0 ? [] : queueLines.slice(addLineIndex + 1, addLineIndex + 5),
        catchLogs: queueLines.filter(line => line.startsWith('this._errorLog.log(')).length,
        callbackClosing: queueLines.slice(-4),
    }, {
        callbackOpening: [
            'this._cardCoverCheckLaterId = null;', 'try {', 'this._syncCardCover();', '} catch (error) {',
        ],
        catchLogs: 1,
        callbackClosing: ['}', 'return GLib.SOURCE_REMOVE;', '});', '}'],
    });
});

test('extension.js: teardown attempts every covering window: each window\'s disconnectObject sits in a try of its ' +
    'own inside the loop, a failure logged as a teardown failure, so one that throws leaves none of the rest ' +
    'connected', () => {
    const disconnectLines = trimmedLines(
        declarationBody(readExtensionFile('extension.js'), '_disconnectCoveringWindows() {'));
    const loopIndex = disconnectLines.indexOf('for (const metaWindow of coveringWindows) {');
    assertEqual(loopIndex < 0 ? [] : disconnectLines.slice(loopIndex + 1, loopIndex + 6), [
        'try {',
        'metaWindow.disconnectObject(this);',
        '} catch (error) {',
        'this._logTearDownFailure(\'disconnect from a covering window\', error);',
        '}',
    ]);
});

test('extension.js: the fallback timeout runs exactly while coverFallbackTimerChange says so, from the cover, the ' +
    'client\'s isLive and whether it runs, asked on each cover check and, once a tick, on a tick that did not check ' +
    'the cover; its callback keeps it, and its removal forgets the id before it removes the source', () => {
    const extensionSource = readExtensionFile('extension.js');
    const timerLines = trimmedLines(declarationBody(extensionSource, '_syncCoverFallbackTimer() {'));
    const removeLines = trimmedLines(declarationBody(extensionSource, '_removeCoverFallbackTimer() {'));
    const tickBody = declarationBody(extensionSource, '_onCardCoverTick() {');
    const tickLines = trimmedLines(tickBody);
    const lineAfter = (lines, line) => (lines.includes(line) ? lines[lines.indexOf(line) + 1] : null);
    const startIndex = timerLines.indexOf('if (timerChange === CoverFallbackTimerChange.START) {');
    const askingStatement = 'this._syncCoverFallbackTimer();';
    const backstopCondition = 'if (isCoverBackstopDue({isCovered, ticksSinceCoverCheck: this._ticksSinceCoverCheck}))';
    const backstopIndex = tickLines.indexOf(backstopCondition);
    assertEqual({
        decides: timerLines.slice(1, 5),
        startsOnStart: startIndex < 0 ? [] : timerLines.slice(startIndex + 1, startIndex + 4),
        stopsOnStop: lineAfter(timerLines, '} else if (timerChange === CoverFallbackTimerChange.STOP) {'),
        removeForgetsThenRemoves: removeLines.slice(-4, -1),
        keepsRunning: statementCount(declarationBody(extensionSource, '_onCoverFallbackTimeout() {'),
            'return GLib.SOURCE_CONTINUE;'),
        askedOnEachCheck: statementCount(declarationBody(extensionSource, '_syncCardCover() {'), askingStatement),
        // The tick asks itself only when the backstop did not check the cover, whose sync already asked.
        askedOnceATick: [
            statementCount(tickBody, askingStatement),
            backstopIndex < 0 ? [] : tickLines.slice(backstopIndex, backstopIndex + 4),
        ],
    }, {
        decides: [
            'const timerChange = coverFallbackTimerChange({',
            'isCovered: !this._isCardVisible,',
            'isServiceLive: this._client?.isLive === true,',
            'isTimerRunning: this._coverFallbackSourceId !== null,',
        ],
        startsOnStart: [
            'const onFallbackTimeout = () => this._onCoverFallbackTimeout();',
            'this._coverFallbackSourceId =',
            'GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, COVER_FALLBACK_INTERVAL_SECONDS, onFallbackTimeout);',
        ],
        stopsOnStop: 'this._removeCoverFallbackTimer();',
        removeForgetsThenRemoves: [
            'const sourceId = this._coverFallbackSourceId;',
            'this._coverFallbackSourceId = null;',
            'GLib.source_remove(sourceId);',
        ],
        keepsRunning: 1,
        askedOnEachCheck: 1,
        askedOnceATick: [1, [backstopCondition, 'this._syncCardCover();', 'else', askingStatement]],
    });
});

test('extension.js: when the overview has closed, the cover is checked again', () => {
    const extensionSource = readExtensionFile('extension.js');
    const followOverviewBody = declarationBody(extensionSource, '_followOverviewWithDetailWatch() {');
    const overviewHandlers = connectedSignalHandlers(followOverviewBody);
    assertEqual({
        hiddenHandler: overviewHandlers.filter(signalHandler => signalHandler.startsWith('Main.overview hidden:')),
        hiddenChecksTheCover: statementCount(declarationBody(extensionSource, '_onOverviewHidden() {'),
            'this._syncCardCover();'),
    }, {hiddenHandler: ['Main.overview hidden: () => this._onOverviewHidden()'], hiddenChecksTheCover: 1});
});

// The top-bar dropdown: indicator.js is a PanelMenu.Button whose menu holds a second card and "Open Resources".
const INDICATOR_SOURCE_FILE = 'indicator.js';

test('indicator.js is a PanelMenu.Button with a menu of its own, and the click that launched Resources directly is ' +
    'gone', () => {
    const indicatorSource = readExtensionFile(INDICATOR_SOURCE_FILE);
    assertEqual({
        extendsPanelMenuButton: indicatorSource.includes('class PulseIndicator extends PanelMenu.Button {'),
        createsItsMenu: statementCount(declarationBody(indicatorSource, '_init(client) {'),
            'super._init(MENU_ALIGNMENT, ACCESSIBLE_NAME);'),
        suppressesItsMenu: indicatorSource.includes('DONT_CREATE_MENU'),
        hasItsOwnClickGesture: indicatorSource.includes('ClickGesture'),
        launchesOnClick: indicatorSource.includes('_openSystemMonitor') || indicatorSource.includes('\'recognize\''),
    }, {
        extendsPanelMenuButton: true, createsItsMenu: 1, suppressesItsMenu: false, hasItsOwnClickGesture: false,
        launchesOnClick: false,
    });
});

test('indicator.js: the menu holds a non-reactive item with the second card, and an "Open Resources" item that ' +
    'launches the first installed id in RESOURCES_APP_IDS (cockpitCards.js finds and opens it) and is hidden when ' +
    'none is installed', () => {
    const indicatorSource = readExtensionFile(INDICATOR_SOURCE_FILE);
    const cockpitCardsSource = readExtensionFile('cockpitCards.js');
    const buildBody = declarationBody(indicatorSource, '_buildDropdown() {');
    const findBody = declarationBody(cockpitCardsSource, 'export function findResourcesApp() {');
    const openBody = declarationBody(cockpitCardsSource, 'export function openResourcesApp() {');
    const visibilityBody = declarationBody(indicatorSource, '_syncOpenResourcesVisibility() {');
    assertEqual({
        cardItemIsInert: buildBody.includes('new PopupMenu.PopupBaseMenuItem(CARD_ITEM_PROPERTIES)') &&
            indicatorSource.includes('const CARD_ITEM_PROPERTIES = {reactive: false, can_focus: false, style_class:'),
        secondCardIsBuilt: statementCount(buildBody, 'this._dropdownCard = new PulseCard(this._client);'),
        cardIsInTheItem: statementCount(buildBody, 'cardItem.add_child(this._dropdownCard);'),
        cardIsNeverPlaced: indicatorSource.includes('placeOnPrimaryMonitor'),
        openItemLabel: statementCount(buildBody,
            'this._openResourcesItem = new PopupMenu.PopupMenuItem(OPEN_RESOURCES_LABEL);'),
        labelIsTheSpecifiedOne: indicatorSource.includes('const OPEN_RESOURCES_LABEL = \'Open Resources\';'),
        activationLaunches: buildBody.includes(
            'this._openResourcesItem.connect(\'activate\', () => openResourcesApp());'),
        lookupUsesTheSharedIds: findBody.includes('RESOURCES_APP_IDS') && findBody.includes('.find(app => app !== null)'),
        launchActivates: statementCount(openBody, 'resourcesApp.activate();'),
        launchLeavesTheOverview: statementCount(openBody, 'Main.overview.hide();'),
        hiddenWhenNoneInstalled: statementCount(visibilityBody,
            'this._openResourcesItem.visible = findResourcesApp() !== undefined;'),
    }, {
        cardItemIsInert: true, secondCardIsBuilt: 1, cardIsInTheItem: 1, cardIsNeverPlaced: false, openItemLabel: 1,
        labelIsTheSpecifiedOne: true, activationLaunches: true, lookupUsesTheSharedIds: true, launchActivates: 1,
        launchLeavesTheOverview: 1, hiddenWhenNoneInstalled: 1,
    });
});

test('indicator.js: the dropdown card is never frozen while the menu is open: closing freezes it, opening unfreezes ' +
    'it (a repaint at once), and opening re-checks whether Resources is installed', () => {
    const indicatorSource = readExtensionFile(INDICATOR_SOURCE_FILE);
    const openStateBody = declarationBody(indicatorSource, '_onMenuOpenStateChanged(isOpen) {');
    const initBody = declarationBody(indicatorSource, '_init(client) {');
    assertEqual({
        freezesExactlyWhileClosed: statementCount(openStateBody, 'this._dropdownCard.setFrozen(!isOpen);'),
        recheckedOnEveryChange: statementCount(openStateBody, 'this._syncOpenResourcesVisibility();'),
        startsFrozen: statementCount(initBody, 'this._dropdownCard.setFrozen(true);'),
        listensToTheMenu: statementCount(initBody,
            'this.menu.connectObject(\'open-state-changed\', (_menu, isOpen) => this._onMenuOpenStateChanged(isOpen),'),
    }, {freezesExactlyWhileClosed: 1, recheckedOnEveryChange: 1, startsFrozen: 1, listensToTheMenu: 1});
});

test('indicator.js: the hover label is suppressed while the menu is open, and opening it hides one that is up', () => {
    const indicatorSource = readExtensionFile(INDICATOR_SOURCE_FILE);
    const syncBody = declarationBody(indicatorSource, '_syncHoverLabel() {');
    const openStateBody = declarationBody(indicatorSource, '_onMenuOpenStateChanged(isOpen) {');
    assertEqual({
        showsOnlyWhenHoveredMappedAndMenuClosed: statementCount(syncBody,
            'if (this.hover && this.mapped && !this.menu.isOpen) {'),
        reSyncsOnOpenStateChange: statementCount(openStateBody, 'this._syncHoverLabel();'),
    }, {showsOnlyWhenHoveredMappedAndMenuClosed: 1, reSyncsOnOpenStateChange: 1});
});

test('indicator.js: destroying the indicator destroys the dropdown card and the hover label, cancels the pending show, and nothing is ' +
    'connected outside the indicator, its menu or its label', () => {
    const indicatorSource = readExtensionFile(INDICATOR_SOURCE_FILE);
    const onDestroyBody = declarationBody(indicatorSource, '_onDestroy() {');
    assertEqual({
        destroysTheDropdownCard: statementCount(onDestroyBody, 'this._dropdownCard?.destroy();'),
        clearsTheDropdownCard: statementCount(onDestroyBody, 'this._dropdownCard = null;'),
        cancelsTheShowTimeout: statementCount(onDestroyBody, 'this._cancelHoverLabelTimeout();'),
        destroysTheLabel: statementCount(onDestroyBody, 'this._hoverLabel?.destroy();'),
        outsideConnectionsDisconnected: statementCount(onDestroyBody,
            'St.ThemeContext.get_for_stage(global.stage).disconnectObject(this);'),
        outsideConnections: (indicatorSource.match(/St\.ThemeContext\.get_for_stage\(global\.stage\)\.connectObject\(/g) ?? [])
            .length,
    }, {
        destroysTheDropdownCard: 1, clearsTheDropdownCard: 1, cancelsTheShowTimeout: 1, destroysTheLabel: 1,
        outsideConnectionsDisconnected: 1, outsideConnections: 1,
    });
});

test('extension.js: the menu\'s open-state-changed drives the dropdown flag of isDetailWatchWanted, and teardown ' +
    'disconnects it', () => {
    const extensionSource = readExtensionFile('extension.js');
    const followBody = declarationBody(extensionSource, '_followDropdown() {');
    const syncBody = declarationBody(extensionSource, '_syncDetailWatch() {');
    const tearDownBody = declarationBody(extensionSource, '_tearDown() {');
    assertEqual({
        receiver: [...followBody.matchAll(CONNECT_OBJECT_PATTERN)].map(([, receiver]) => receiver),
        handler: statementCount(followBody,
            '\'open-state-changed\', (_menu, isOpen) => this._onDropdownOpenStateChanged(isOpen),'),
        recordsTheState: statementCount(declarationBody(extensionSource, '_onDropdownOpenStateChanged(isOpen) {'),
            'this._isDropdownOpen = isOpen;'),
        resyncsTheWatch: statementCount(declarationBody(extensionSource, '_onDropdownOpenStateChanged(isOpen) {'),
            'this._syncDetailWatch();'),
        watchReadsTheFlag: statementCount(syncBody, 'isDropdownOpen: this._isDropdownOpen,'),
        placeholderGone: extensionSource.includes('IS_DROPDOWN_OPEN_UNTIL_DROPDOWN_EXISTS'),
        teardownDisconnects: statementCount(tearDownBody,
            '{name: \'disconnect from the dropdown menu\', run: () => dropdownMenu?.disconnectObject(this)},'),
        teardownClearsTheFlag: statementCount(tearDownBody, 'this._isDropdownOpen = false;'),
    }, {
        receiver: ['this._dropdownMenu'], handler: 1, recordsTheState: 1, resyncsTheWatch: 1, watchReadsTheFlag: 1, placeholderGone: false,
        teardownDisconnects: 1, teardownClearsTheFlag: 1,
    });
});

test('stylesheet.css styles the dropdown with classes of its own, added beside the old ones', () => {
    const selectedClassNames = new Set(stylesheetRules(readExtensionFile('stylesheet.css'))
        .flatMap(rule => rule.classNames));
    assertEqual(['resource-pulse-menu-card-item'].filter(className => !selectedClassNames.has(className)), []);
});

test('indicator.js: _onDestroy disconnects the menu handler first, before it clears the dropdown fields and before ' +
    'super._onDestroy() destroys the menu (whose close() emits open-state-changed against a cleared card)', () => {
    const onDestroyLines = trimmedLines(declarationBody(readExtensionFile(INDICATOR_SOURCE_FILE), '_onDestroy() {'));
    const indexOfLine = statement => onDestroyLines.indexOf(statement);
    const disconnectIndex = indexOfLine('this.menu.disconnectObject(this);');
    assertEqual({
        disconnects: disconnectIndex >= 0,
        beforeClearingTheCard: disconnectIndex < indexOfLine('this._dropdownCard = null;'),
        beforeDestroyingTheMenu: disconnectIndex < indexOfLine('super._onDestroy();'),
    }, {disconnects: true, beforeClearingTheCard: true, beforeDestroyingTheMenu: true});
});
