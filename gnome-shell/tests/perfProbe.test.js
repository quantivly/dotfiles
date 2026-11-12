// Rows for the in-shell probe of the nested harness's `perf` request (nested/perf-probe.js). The harness sends that
// file's text through the nested shell's Eval; here the same text is evaluated under plain gjs against fakes of the
// shell's objects (Main.extensionManager, global.stage, the extension's indicator, graphs, card and client), with the
// same free names in scope and in strict mode, as the shell's Eval runs it. What they pin is what keeps the probe from
// lying: it refuses, naming each missing part, rather than attach to nothing and count zero; it counts from zero at
// every attach, once per event; and it attaches again, to the new objects, after the extension is enabled again.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';

const PROBE_URI = GLib.uri_resolve_relative(import.meta.url, './nested/perf-probe.js', GLib.UriFlags.NONE);
const [PROBE_PATH] = GLib.filename_from_uri(PROBE_URI);
/** The function the probe's text declares, which the harness calls with one request. */
const PROBE_FUNCTION_NAME = 'resourcePulsePerfProbe';
const EXTENSION_UUID = 'resource-pulse@dotfiles';
/** Clutter.OffscreenRedirect's values, as the shell's Clutter has them. */
const OFFSCREEN_REDIRECT = Object.freeze({AUTOMATIC_FOR_OPACITY: 1, ALWAYS: 2, ON_IDLE: 4});
/** Every part the probe attaches to with the extension enabled, by the name it reports a missing one under. */
const ALL_PART_NAMES = ['extension', 'indicator', 'cpuGraphArea', 'memoryGraphArea', 'card', 'client'];
/** The two facts an enabled read answers, as the fake shell starts: the card visible, the indicator mapped. */
const VISIBLE_AND_SHOWN = Object.freeze({isCardVisible: true, isIndicatorMapped: true});

/**
 * The probe's source, read when a row runs (a missing file then fails that row, not the whole run).
 *
 * @returns {string} The text of nested/perf-probe.js.
 */
function readProbeSource() {
    const [, contentBytes] = Gio.File.new_for_path(PROBE_PATH).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

/** A GObject-like signal source: connect and emit by signal name, and how many handlers each signal has. */
class FakeSignalSource {
    constructor() {
        this._handlersBySignal = new Map();
    }

    /**
     * Connects a handler, as GObject's connect does.
     *
     * @param {string} signalName - The signal.
     * @param {Function} callback - Its handler.
     * @returns {number} A handler id.
     */
    connect(signalName, callback) {
        const handlers = this._handlersBySignal.get(signalName) ?? [];
        handlers.push(callback);
        this._handlersBySignal.set(signalName, handlers);
        return handlers.length;
    }

    /**
     * Emits a signal some number of times, calling every handler connected to it each time.
     *
     * @param {string} signalName - The signal.
     * @param {number} times - How many emissions.
     * @returns {void}
     */
    emit(signalName, times) {
        for (let emission = 0; emission < times; emission++) {
            for (const handler of this._handlersBySignal.get(signalName) ?? [])
                handler(this);
        }
    }

    /**
     * How many handlers a signal has: a probe that connected twice would count every event twice.
     *
     * @param {string} signalName - The signal.
     * @returns {number} How many handlers are connected to it.
     */
    handlerCount(signalName) {
        return (this._handlersBySignal.get(signalName) ?? []).length;
    }
}

/** The client's history listeners, as PulseClient keeps them. */
class FakeClient {
    constructor() {
        this.historyListeners = [];
    }

    /**
     * Adds a history listener, as PulseClient.addHistoryListener does.
     *
     * @param {Function} callback - Told once per Sample that appended to the histories.
     * @returns {number} A listener id.
     */
    addHistoryListener(callback) {
        this.historyListeners.push(callback);
        return this.historyListeners.length;
    }

    /**
     * Tells every history listener of some number of Samples, one call each.
     *
     * @param {number} sampleCount - How many Samples to append.
     * @returns {void}
     */
    appendSamples(sampleCount) {
        for (let sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++)
            this.historyListeners.forEach(listener => listener());
    }
}

/**
 * One enable's worth of the extension's parts.
 *
 * @returns {{indicator: object, cpuArea: FakeSignalSource, memoryArea: FakeSignalSource, card: object,
 *     client: FakeClient}} The parts, and the two graphs' drawing areas on their own.
 */
function makeExtensionParts() {
    const cpuArea = new FakeSignalSource();
    const memoryArea = new FakeSignalSource();
    return {
        // Mapped, as a shown indicator is; Clutter's mapped property.
        indicator: {_cpuGraph: {drawingArea: cpuArea}, _memoryGraph: {drawingArea: memoryArea}, mapped: true},
        cpuArea,
        memoryArea,
        card: {redirect: OFFSCREEN_REDIRECT.ALWAYS, get_offscreen_redirect() {
            return this.redirect;
        }},
        client: new FakeClient(),
    };
}

/**
 * A fake nested shell: the stage, the extension's object holding the given parts, and the names the probe uses.
 *
 * @param {object|null} parts - From makeExtensionParts, or null for an extension whose parts are all gone.
 * @returns {{stage: FakeSignalSource, extension: object, scope: object, setLookupAnswersNothing: Function}} The
 *     shell; `extension` is the object whose fields a row may replace.
 */
function makeFakeShell(parts) {
    const stage = new FakeSignalSource();
    const extension = {
        _indicator: parts?.indicator ?? null,
        _card: parts?.card ?? null,
        _client: parts?.client ?? null,
        // The extension's own until its first cover check (IS_CARD_VISIBLE_BEFORE_COVER_CHECK), kept while disabled.
        _isCardVisible: true,
    };
    let doesLookupFindExtension = true;
    const extensionManager = {
        lookup: uuid => (uuid === EXTENSION_UUID && doesLookupFindExtension ? {stateObj: extension} : undefined),
    };
    return {
        stage,
        extension,
        scope: {
            Main: {extensionManager},
            global: {stage},
            imports: {gi: {Clutter: {OffscreenRedirect: OFFSCREEN_REDIRECT}}},
            globalThis: {},
        },
        setLookupAnswersNothing: () => {
            doesLookupFindExtension = false;
        },
    };
}

/**
 * Runs the probe's text with one request, as the harness sends it: the text, then a call of its function, evaluated
 * in strict mode with the shell's free names (Main, global, imports, globalThis) bound to the fake's.
 *
 * @param {object} scope - The fake shell's names.
 * @param {string} request - The request.
 * @returns {object} The probe's answer.
 */
function runProbe(scope, request) {
    const probeCode = `${readProbeSource()}\n${PROBE_FUNCTION_NAME}(${JSON.stringify(request)});`;
    // The probe is a script for the shell's Eval, not a module, so it is run the way Eval runs it: a direct eval of
    // this repository's own file, with a fixed function body (nothing is interpolated into it) that binds the names.
    // eslint-disable-next-line no-new-func
    const evaluateInShellScope = new Function('Main', 'global', 'imports', 'globalThis', 'probeCode',
        "'use strict'; return eval(probeCode);");
    const {Main, global, imports, globalThis: probeGlobal} = scope;
    return evaluateInShellScope(Main, global, imports, probeGlobal, probeCode);
}

/**
 * How many handlers the probe has on every source of a fake shell.
 *
 * @param {object} shell - From makeFakeShell.
 * @param {object} parts - Its parts.
 * @returns {{stage: number, cpuArea: number, memoryArea: number, client: number}} Handler counts.
 */
function handlerCounts(shell, parts) {
    return {
        stage: shell.stage.handlerCount('after-paint'),
        cpuArea: parts.cpuArea.handlerCount('repaint'),
        memoryArea: parts.memoryArea.handlerCount('repaint'),
        client: parts.client.historyListeners.length,
    };
}

test('perf probe: attach-enabled refuses, naming each missing part, and connects nothing', () => {
    /** @type {Object<string, (shell: object, parts: object) => void>} How each case takes a part away. */
    const removals = {
        'no-extension': shell => shell.setLookupAnswersNothing(),
        'extension-without-card-visibility': shell => {
            delete shell.extension._isCardVisible;
        },
        'no-indicator': shell => {
            shell.extension._indicator = null;
        },
        'indicator-without-mapped': (_shell, parts) => {
            delete parts.indicator.mapped;
        },
        'no-cpu-graph-area': (_shell, parts) => {
            delete parts.indicator._cpuGraph.drawingArea;
        },
        'no-memory-graph-area': (_shell, parts) => {
            parts.indicator._memoryGraph = null;
        },
        'no-card': shell => {
            shell.extension._card = null;
        },
        'card-without-redirect': (_shell, parts) => {
            delete parts.card.get_offscreen_redirect;
        },
        'no-client': shell => {
            shell.extension._client = null;
        },
        'client-without-history-listeners': shell => {
            shell.extension._client = {};
        },
    };
    const outcomes = {};
    for (const [caseName, removePart] of Object.entries(removals)) {
        const parts = makeExtensionParts();
        const shell = makeFakeShell(parts);
        removePart(shell, parts);
        const answer = runProbe(shell.scope, 'attach-enabled');
        outcomes[caseName] = {
            refused: typeof answer.refused === 'string' && answer.refused.length > 0,
            missing: answer.missing,
            handlers: handlerCounts(shell, parts),
        };
    }
    const nothingConnected = {stage: 0, cpuArea: 0, memoryArea: 0, client: 0};
    const refusal = missing => ({refused: true, missing, handlers: nothingConnected});
    assertEqual(outcomes, {
        'no-extension': refusal(ALL_PART_NAMES),
        'extension-without-card-visibility': refusal(['extension']),
        'no-indicator': refusal(['indicator', 'cpuGraphArea', 'memoryGraphArea']),
        'indicator-without-mapped': refusal(['indicator']),
        'no-cpu-graph-area': refusal(['cpuGraphArea']),
        'no-memory-graph-area': refusal(['memoryGraphArea']),
        'no-card': refusal(['card']),
        'card-without-redirect': refusal(['card']),
        'no-client': refusal(['client']),
        'client-without-history-listeners': refusal(['client']),
    });
});

test('perf probe: attach-disabled refuses while the extension has parts, and once they are gone counts frames ' +
    'only', () => {
    const parts = makeExtensionParts();
    const enabledShell = makeFakeShell(parts);
    const refusedAnswer = runProbe(enabledShell.scope, 'attach-disabled');
    const disabledShell = makeFakeShell(null);
    const attachAnswer = runProbe(disabledShell.scope, 'attach-disabled');
    disabledShell.stage.emit('after-paint', 3);
    const readAnswer = runProbe(disabledShell.scope, 'read');
    // The extension enabled again during the window: its counts are void.
    disabledShell.extension._client = new FakeClient();
    const enabledMeanwhileAnswer = runProbe(disabledShell.scope, 'read');
    assertEqual({
        whileEnabled: {
            refused: typeof refusedAnswer.refused,
            stageHandlers: enabledShell.stage.handlerCount('after-paint'),
        },
        attached: attachAnswer.attached,
        saysFramesOnly: typeof attachAnswer.counts === 'string' && attachAnswer.counts.startsWith('frames only'),
        read: readAnswer,
        enabledMeanwhile: typeof enabledMeanwhileAnswer.refused,
    }, {
        whileEnabled: {refused: 'string', stageHandlers: 0},
        attached: 'disabled',
        saysFramesOnly: true,
        read: {mode: 'disabled', frames: 3},
        enabledMeanwhile: 'string',
    });
});

test('perf probe: attach-enabled counts frames, Samples and both graphs\' paints from zero, once each, and a read ' +
    'answers the card\'s redirect', () => {
    const parts = makeExtensionParts();
    const shell = makeFakeShell(parts);
    const firstAttach = runProbe(shell.scope, 'attach-enabled');
    shell.stage.emit('after-paint', 2);
    parts.client.appendSamples(3);
    parts.cpuArea.emit('repaint', 2);
    parts.memoryArea.emit('repaint', 1);
    const firstRead = runProbe(shell.scope, 'read');
    const secondAttach = runProbe(shell.scope, 'attach-enabled');
    const zeroedRead = runProbe(shell.scope, 'read');
    parts.card.redirect = OFFSCREEN_REDIRECT.ON_IDLE;
    shell.stage.emit('after-paint', 1);
    const otherRedirectRead = runProbe(shell.scope, 'read');
    assertEqual({
        firstAttach, firstRead, secondAttach, zeroedRead, otherRedirectRead, handlers: handlerCounts(shell, parts),
    }, {
        firstAttach: {attached: 'enabled', reattached: true},
        firstRead: {
            mode: 'enabled', frames: 2, samples: 3, topbarPaints: 3, cardRedirect: 'ALWAYS', ...VISIBLE_AND_SHOWN,
        },
        secondAttach: {attached: 'enabled', reattached: false},
        zeroedRead: {
            mode: 'enabled', frames: 0, samples: 0, topbarPaints: 0, cardRedirect: 'ALWAYS', ...VISIBLE_AND_SHOWN,
        },
        otherRedirectRead: {
            mode: 'enabled', frames: 1, samples: 0, topbarPaints: 0, cardRedirect: '4', ...VISIBLE_AND_SHOWN,
        },
        handlers: {stage: 1, cpuArea: 1, memoryArea: 1, client: 1},
    });
});

test('perf probe: after the extension is enabled again it attaches to the new parts, and a read refuses parts that ' +
    'changed since the attach', () => {
    const oldParts = makeExtensionParts();
    const shell = makeFakeShell(oldParts);
    runProbe(shell.scope, 'attach-enabled');
    const newParts = makeExtensionParts();
    shell.extension._indicator = newParts.indicator;
    shell.extension._card = newParts.card;
    shell.extension._client = newParts.client;
    const staleRead = runProbe(shell.scope, 'read');
    const reattach = runProbe(shell.scope, 'attach-enabled');
    // The old parts are gone; whatever they still report must not count.
    oldParts.cpuArea.emit('repaint', 5);
    oldParts.client.appendSamples(5);
    newParts.cpuArea.emit('repaint', 1);
    newParts.memoryArea.emit('repaint', 1);
    newParts.client.appendSamples(2);
    const newRead = runProbe(shell.scope, 'read');
    assertEqual({
        staleRead: typeof staleRead.refused, reattach, newRead,
        newHandlers: handlerCounts(shell, newParts), stageHandlers: shell.stage.handlerCount('after-paint'),
    }, {
        staleRead: 'string',
        reattach: {attached: 'enabled', reattached: true},
        newRead: {
            mode: 'enabled', frames: 0, samples: 2, topbarPaints: 2, cardRedirect: 'ALWAYS', ...VISIBLE_AND_SHOWN,
        },
        newHandlers: {stage: 1, cpuArea: 1, memoryArea: 1, client: 1},
        stageHandlers: 1,
    });
});

test('perf probe: a read answers whether the card counts as visible and whether the indicator is mapped, as they ' +
    'are at the end of the window, and refuses when either cannot be read', () => {
    const parts = makeExtensionParts();
    const shell = makeFakeShell(parts);
    runProbe(shell.scope, 'attach-enabled');
    // Covered and hidden after the attach, as topbar-hidden-covered is: the read answers them as they are now.
    shell.extension._isCardVisible = false;
    parts.indicator.mapped = false;
    const coveredAndHiddenRead = runProbe(shell.scope, 'read');
    delete shell.extension._isCardVisible;
    const noCardVisibilityRead = runProbe(shell.scope, 'read');
    shell.extension._isCardVisible = false;
    delete parts.indicator.mapped;
    const noMappedRead = runProbe(shell.scope, 'read');
    const factsOf = answer => ({isCardVisible: answer.isCardVisible, isIndicatorMapped: answer.isIndicatorMapped});
    const refusalOf = answer => ({refused: typeof answer.refused, missing: answer.missing});
    assertEqual({
        coveredAndHidden: factsOf(coveredAndHiddenRead),
        noCardVisibility: refusalOf(noCardVisibilityRead),
        noMapped: refusalOf(noMappedRead),
    }, {
        coveredAndHidden: {isCardVisible: false, isIndicatorMapped: false},
        noCardVisibility: {refused: 'string', missing: ['extension']},
        noMapped: {refused: 'string', missing: ['indicator']},
    });
});

test('perf probe: a read before any attach, and an unknown request, are refused', () => {
    const shell = makeFakeShell(makeExtensionParts());
    const readFirst = runProbe(shell.scope, 'read');
    const unknownRequest = runProbe(shell.scope, 'detach-everything');
    assertEqual({readFirst: typeof readFirst.refused, unknownRequest: typeof unknownRequest.refused},
        {readFirst: 'string', unknownRequest: 'string'});
});

/** The grid's card ids as the nested fixture's layout draws them, in the layer's order. */
const GRID_CARD_IDS = ['system', 'apps', 'connections', 'sessions'];
/** Clutter's offscreen redirect of none, which the layer and the system cell's wrapper keep (ruling D12). */
const NO_REDIRECT = 0;

/**
 * A fake cockpit layer drawing the given cards, each with the redirect ruling D12 wants unless told otherwise, its
 * pacing's fallback timeout not armed.
 *
 * @param {string[]} cardIds - The drawn card ids, in the layer's order.
 * @returns {{layer: object, cardsById: Map<string, object>}} The layer, and its cards by id.
 */
function makeFakeLayer(cardIds) {
    const redirectFor = cardId => (cardId === 'system' ? NO_REDIRECT : OFFSCREEN_REDIRECT.ALWAYS);
    const cardsById = new Map(cardIds.map(cardId => [cardId, {
        redirect: redirectFor(cardId),
        get_offscreen_redirect() {
            return this.redirect;
        },
    }]));
    const layer = {
        redirect: NO_REDIRECT,
        get_offscreen_redirect() {
            return this.redirect;
        },
        get drawnCardIds() {
            return [...cardsById.keys()];
        },
        _cardsById: cardsById,
        _pacing: {_fallbackSourceId: null},
    };
    return {layer, cardsById};
}

/**
 * Gives a fake shell's extension the cockpit fields read-cockpit reads: a layer (or none), the visible card ids, no
 * cover fallback armed, and a dropdown pacing with no fallback armed.
 *
 * @param {object} shell - From makeFakeShell.
 * @param {object} parts - Its parts.
 * @param {object|null} layer - From makeFakeLayer, or null for no layer.
 * @param {string[]} visibleCardIds - The extension's _visibleCardIds.
 * @returns {void}
 */
function addFakeCockpit(shell, parts, layer, visibleCardIds) {
    shell.extension._layer = layer;
    shell.extension._visibleCardIds = visibleCardIds;
    shell.extension._coverFallbackSourceId = null;
    parts.indicator._sessionsPacing = {_fallbackSourceId: null};
}

test('perf probe: read-cockpit answers the grid\'s visible and drawn card ids sorted, each part\'s redirect and no ' +
    'armed fallback, as they are at the end of the window', () => {
    const parts = makeExtensionParts();
    const shell = makeFakeShell(parts);
    const {layer} = makeFakeLayer(GRID_CARD_IDS);
    addFakeCockpit(shell, parts, layer, ['sessions', 'apps', 'system', 'connections']);
    runProbe(shell.scope, 'attach-enabled');
    const visibleAnswer = runProbe(shell.scope, 'read-cockpit');
    // Covered after the attach, as the covered states are: the answer reads the ids as they are now.
    shell.extension._visibleCardIds = [];
    const coveredAnswer = runProbe(shell.scope, 'read-cockpit');
    const expectedRedirects = {layer: 'NONE', system: 'NONE', apps: 'ALWAYS', connections: 'ALWAYS', sessions: 'ALWAYS'};
    const expectedAnswer = visibleCardIds => ({
        mode: 'enabled', visibleCardIds, layerCardIds: ['apps', 'connections', 'sessions', 'system'],
        cockpitRedirects: expectedRedirects, armedCockpitTimers: [],
    });
    assertEqual({visibleAnswer, coveredAnswer}, {
        visibleAnswer: expectedAnswer(['apps', 'connections', 'sessions', 'system']),
        coveredAnswer: expectedAnswer([]),
    });
});

test('perf probe: read-cockpit names each armed fallback timeout (the cover check\'s, the layer\'s pacing\'s, the ' +
    'dropdown\'s) and a redirect that is neither ALWAYS nor none by its number', () => {
    const parts = makeExtensionParts();
    const shell = makeFakeShell(parts);
    const {layer, cardsById} = makeFakeLayer(GRID_CARD_IDS);
    addFakeCockpit(shell, parts, layer, GRID_CARD_IDS);
    runProbe(shell.scope, 'attach-enabled');
    const armedOneAtATime = {};
    const armers = {
        'cover-fallback': () => {
            shell.extension._coverFallbackSourceId = 41;
        },
        'layer-pacing-fallback': () => {
            layer._pacing._fallbackSourceId = 42;
        },
        'dropdown-pacing-fallback': () => {
            parts.indicator._sessionsPacing._fallbackSourceId = 43;
        },
    };
    for (const [timerName, arm] of Object.entries(armers)) {
        shell.extension._coverFallbackSourceId = null;
        layer._pacing._fallbackSourceId = null;
        parts.indicator._sessionsPacing._fallbackSourceId = null;
        arm();
        armedOneAtATime[timerName] = runProbe(shell.scope, 'read-cockpit').armedCockpitTimers;
    }
    Object.values(armers).forEach(arm => arm());
    cardsById.get('apps').redirect = OFFSCREEN_REDIRECT.AUTOMATIC_FOR_OPACITY;
    layer.redirect = OFFSCREEN_REDIRECT.ALWAYS;
    const allArmedAnswer = runProbe(shell.scope, 'read-cockpit');
    assertEqual({
        armedOneAtATime,
        allArmed: allArmedAnswer.armedCockpitTimers,
        redirects: allArmedAnswer.cockpitRedirects,
    }, {
        armedOneAtATime: {
            'cover-fallback': ['cover-fallback'],
            'layer-pacing-fallback': ['layer-pacing-fallback'],
            'dropdown-pacing-fallback': ['dropdown-pacing-fallback'],
        },
        allArmed: ['cover-fallback', 'layer-pacing-fallback', 'dropdown-pacing-fallback'],
        redirects: {layer: 'ALWAYS', system: 'NONE', apps: '1', connections: 'ALWAYS', sessions: 'ALWAYS'},
    });
});

test('perf probe: read-cockpit with no layer (the v2 card top right) answers null drawn ids and redirects, and with ' +
    'no sessions item no dropdown timer', () => {
    const parts = makeExtensionParts();
    const shell = makeFakeShell(parts);
    addFakeCockpit(shell, parts, null, ['system']);
    parts.indicator._sessionsPacing = null;
    runProbe(shell.scope, 'attach-enabled');
    assertEqual(runProbe(shell.scope, 'read-cockpit'), {
        mode: 'enabled', visibleCardIds: ['system'], layerCardIds: null, cockpitRedirects: null,
        armedCockpitTimers: [],
    });
});

test('perf probe: read-cockpit refuses with nothing attached, in the disabled mode, after the parts changed, and when ' +
    'a field it reads is not there, naming each', () => {
    /** @type {Object<string, (shell: object, parts: object, layer: object) => void>} How each case breaks a field. */
    const removals = {
        extensionLayer: shell => {
            delete shell.extension._layer;
        },
        extensionVisibleCardIds: shell => {
            shell.extension._visibleCardIds = 'apps';
        },
        extensionCoverFallback: shell => {
            delete shell.extension._coverFallbackSourceId;
        },
        layerCards: (_shell, _parts, layer) => {
            delete layer._cardsById;
        },
        layerRedirect: (_shell, _parts, layer) => {
            delete layer.get_offscreen_redirect;
        },
        layerPacing: (_shell, _parts, layer) => {
            layer._pacing = {};
        },
        dropdownPacing: (_shell, parts) => {
            delete parts.indicator._sessionsPacing;
        },
        dropdownPacingTimer: (_shell, parts) => {
            parts.indicator._sessionsPacing = {};
        },
    };
    const refusalOf = answer => ({refused: typeof answer.refused, missing: answer.missing});
    const outcomes = {};
    for (const [caseName, removeField] of Object.entries(removals)) {
        const parts = makeExtensionParts();
        const shell = makeFakeShell(parts);
        const {layer} = makeFakeLayer(GRID_CARD_IDS);
        addFakeCockpit(shell, parts, layer, GRID_CARD_IDS);
        runProbe(shell.scope, 'attach-enabled');
        removeField(shell, parts, layer);
        outcomes[caseName] = refusalOf(runProbe(shell.scope, 'read-cockpit'));
    }
    const freshParts = makeExtensionParts();
    const freshShell = makeFakeShell(freshParts);
    addFakeCockpit(freshShell, freshParts, makeFakeLayer(GRID_CARD_IDS).layer, GRID_CARD_IDS);
    outcomes.nothingAttached = refusalOf(runProbe(freshShell.scope, 'read-cockpit'));
    const disabledShell = makeFakeShell(null);
    runProbe(disabledShell.scope, 'attach-disabled');
    outcomes.disabledMode = refusalOf(runProbe(disabledShell.scope, 'read-cockpit'));
    runProbe(freshShell.scope, 'attach-enabled');
    freshShell.extension._card = makeExtensionParts().card;
    outcomes.partsChanged = refusalOf(runProbe(freshShell.scope, 'read-cockpit'));
    const missingField = fieldKey => ({refused: 'string', missing: [fieldKey]});
    assertEqual(outcomes, {
        extensionLayer: missingField('extensionLayer'),
        extensionVisibleCardIds: missingField('extensionVisibleCardIds'),
        extensionCoverFallback: missingField('extensionCoverFallback'),
        layerCards: missingField('layerCards'),
        layerRedirect: missingField('layerRedirect'),
        layerPacing: missingField('layerPacing'),
        dropdownPacing: missingField('dropdownPacing'),
        dropdownPacingTimer: missingField('dropdownPacing'),
        nothingAttached: {refused: 'string'},
        disabledMode: {refused: 'string'},
        partsChanged: {refused: 'string'},
    });
});
