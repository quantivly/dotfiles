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
        indicator: {_cpuGraph: {drawingArea: cpuArea}, _memoryGraph: {drawingArea: memoryArea}},
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
    const extension = {_indicator: parts?.indicator ?? null, _card: parts?.card ?? null, _client: parts?.client ?? null};
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
        'no-indicator': shell => {
            shell.extension._indicator = null;
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
        'no-indicator': refusal(['indicator', 'cpuGraphArea', 'memoryGraphArea']),
        'no-cpu-graph-area': refusal(['cpuGraphArea']),
        'no-memory-graph-area': refusal(['memoryGraphArea']),
        'no-card': refusal(['card']),
        'card-without-redirect': refusal(['card']),
        'no-client': refusal(['client']),
        'client-without-history-listeners': refusal(['client']),
    });
});

test('perf probe: attach-disabled refuses while the extension has parts, and once they are gone counts frames only', () => {
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
        whileEnabled: {refused: typeof refusedAnswer.refused, stageHandlers: enabledShell.stage.handlerCount('after-paint')},
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
        firstRead: {mode: 'enabled', frames: 2, samples: 3, topbarPaints: 3, cardRedirect: 'ALWAYS'},
        secondAttach: {attached: 'enabled', reattached: false},
        zeroedRead: {mode: 'enabled', frames: 0, samples: 0, topbarPaints: 0, cardRedirect: 'ALWAYS'},
        otherRedirectRead: {mode: 'enabled', frames: 1, samples: 0, topbarPaints: 0, cardRedirect: '4'},
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
        newRead: {mode: 'enabled', frames: 0, samples: 2, topbarPaints: 2, cardRedirect: 'ALWAYS'},
        newHandlers: {stage: 1, cpuArea: 1, memoryArea: 1, client: 1},
        stageHandlers: 1,
    });
});

test('perf probe: a read before any attach, and an unknown request, are refused', () => {
    const shell = makeFakeShell(makeExtensionParts());
    const readFirst = runProbe(shell.scope, 'read');
    const unknownRequest = runProbe(shell.scope, 'detach-everything');
    assertEqual({readFirst: typeof readFirst.refused, unknownRequest: typeof unknownRequest.refused},
        {readFirst: 'string', unknownRequest: 'string'});
});
