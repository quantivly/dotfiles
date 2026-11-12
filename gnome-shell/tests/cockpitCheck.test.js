// Rows for the in-shell halves of the nested harness's `check cockpit`, `window` and `pointer`
// (nested/cockpit-check.js and nested/pointer.js). The harness sends each file's text through the nested shell's Eval;
// here the same text is evaluated under plain gjs, in strict mode, with the shell's free names (Main, global, imports,
// globalThis, Meta, GLib, ExtensionUtils) bound to a fake shell that draws the cockpit as the nested fixture lays it
// out. For each request: the healthy shell answers ok; each fault the step exists to catch answers bad, naming it; and
// a part the request cannot read, or a precondition that does not hold, answers could-not-judge, never ok or bad.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';

const NESTED_DIR_URI = GLib.uri_resolve_relative(import.meta.url, './nested/', GLib.UriFlags.NONE);
const CHECK_FUNCTION_NAME = 'resourcePulseCockpitCheck';
const POINTER_FUNCTION_NAME = 'resourcePulseNestedPointer';
const EXTENSION_UUID = 'resource-pulse@dotfiles';
const OK = 'ok';
const BAD = 'bad';
const PENDING = 'pending';
const COULD_NOT_JUDGE = 'could-not-judge';
const OFFSCREEN_REDIRECT = Object.freeze({AUTOMATIC_FOR_OPACITY: 1, ALWAYS: 2});
const EXTENSION_STATE = Object.freeze({ACTIVE: 1, INACTIVE: 2, ERROR: 3});
const WINDOW_TYPE = Object.freeze({NORMAL: 0, DESKTOP: 1});
const SOURCE_REMOVE = false;
const SOURCE_CONTINUE = true;
/** The nested run's one monitor and its work area under the top bar, in stage pixels. */
const MONITOR = Object.freeze({index: 0, x: 0, y: 0, width: 3072, height: 1920});
const WORK_AREA = Object.freeze({x: 0, y: 32, width: 3072, height: 1888});
/** The fixture's layout, its captions, and the cells the layer placed the four known cards in. */
const LAYOUT = Object.freeze({groups: [
    {caption: 'MACHINE', cards: ['system', 'apps', 'connections', 'health']},
    {caption: 'AGENTS', cards: ['sessions', 'seats']},
    {caption: 'WORK', cards: ['sol', 'work']},
]});
const CAPTIONS = ['MACHINE', 'AGENTS', 'WORK'];
const KNOWN_CARD_IDS = ['system', 'apps', 'connections', 'sessions'];
const UNKNOWN_CARD_IDS = ['health', 'seats', 'sol', 'work'];
const CELLS_BY_CARD_ID = Object.freeze({
    system: {x: 40, y: 80, width: 600, height: 500},
    apps: {x: 680, y: 80, width: 600, height: 500},
    connections: {x: 40, y: 620, width: 600, height: 500},
    sessions: {x: 1320, y: 80, width: 600, height: 500},
});
const GRID_OPTIONS = Object.freeze({
    expectedCaptions: CAPTIONS, expectedCardIds: KNOWN_CARD_IDS, unknownCardIds: UNKNOWN_CARD_IDS,
});
const SESSION_NAMES = ['alpha-sync', 'beta-docs'];
const PROBE_PID = 4242;
const DECOY_PID = 4343;
const WINDOW_SIZE = Object.freeze({width: 320, height: 200});
const DROPDOWN_CARD_WIDTH_PX = 400;
/** A wait short enough for the rows, long enough for the fake's timeouts to look a few times. */
const SHORT_TIMEOUT_MS = 200;

/**
 * A file of nested/, read when a row runs.
 *
 * @param {string} fileName - Its name.
 * @returns {string} Its text.
 */
function readNestedFile(fileName) {
    const [filePath] = GLib.filename_from_uri(GLib.uri_resolve_relative(NESTED_DIR_URI, fileName, GLib.UriFlags.NONE));
    const [, contentBytes] = Gio.File.new_for_path(filePath).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

/** A Clutter actor as the checks read it: a tree, style classes, a stage rectangle, signals, a text. */
class FakeActor {
    constructor({styleClasses = [], rect = {x: 0, y: 0, width: 0, height: 0}, text = '', reactive = false} = {}) {
        this._styleClasses = styleClasses;
        this.rect = {...rect};
        this._text = text;
        this.visible = true;
        this.mapped = true;
        this.reactive = reactive;
        this.redirect = 0;
        this._parent = null;
        this._children = [];
        this._handlers = new Map();
        this._nextHandlerId = 1;
    }

    get text() {
        return this._text;
    }

    set text(newText) {
        this._text = newText;
        for (const [signalName, handler] of this._handlers.values()) {
            if (signalName === 'notify::text')
                handler(this);
        }
    }

    get width() {
        return this.rect.width;
    }

    get height() {
        return this.rect.height;
    }

    add_child(child) {
        child._parent?.remove_child(child);
        child._parent = this;
        this._children.push(child);
        return child;
    }

    remove_child(child) {
        this._children = this._children.filter(existing => existing !== child);
        child._parent = null;
    }

    get_parent() {
        return this._parent;
    }

    /**
     * Clutter's restacking among siblings: the child is painted right above the sibling, or above every other child
     * when the sibling is null.
     *
     * @param {FakeActor} child - A child of this actor.
     * @param {FakeActor|null} sibling - Another child, or null.
     */
    set_child_above_sibling(child, sibling) {
        this._children = this._children.filter(existing => existing !== child);
        const siblingIndex = sibling === null ? this._children.length - 1 : this._children.indexOf(sibling);
        this._children.splice(siblingIndex + 1, 0, child);
    }

    get_children() {
        return [...this._children];
    }

    has_style_class_name(styleClass) {
        return this._styleClasses.includes(styleClass);
    }

    get_transformed_position() {
        return [this.rect.x, this.rect.y];
    }

    get_transformed_size() {
        return [this.rect.width, this.rect.height];
    }

    get_offscreen_redirect() {
        return this.redirect;
    }

    connect(signalName, handler) {
        const handlerId = this._nextHandlerId++;
        this._handlers.set(handlerId, [signalName, handler]);
        return handlerId;
    }

    disconnect(handlerId) {
        this._handlers.delete(handlerId);
    }

    get handlerCount() {
        return this._handlers.size;
    }
}

/** A Meta.Window as the checks read and drive it. */
class FakeWindow {
    constructor(display, pid, title) {
        this._display = display;
        this._pid = pid;
        this._title = title;
        this.windowType = WINDOW_TYPE.NORMAL;
        this.minimized = false;
        this.demands_attention = false;
        this.frame = {x: 1000, y: 700, ...WINDOW_SIZE};
        this.isMaximized = false;
        /** The arguments of each maximize() call: Mutter 50.1's meta_window_maximize takes none (Meta-18.typelib). */
        this.maximizeArgumentLists = [];
        this.isMinimizable = true;
    }

    get_pid() {
        return this._pid;
    }

    get_title() {
        return this._title;
    }

    get_window_type() {
        return this.windowType;
    }

    get_frame_rect() {
        return {...this.frame};
    }

    move_frame(_isUserAction, x, y) {
        this.frame = {...this.frame, x, y};
    }

    minimize() {
        if (!this.isMinimizable)
            return;
        this.minimized = true;
        if (this._display.focus_window === this)
            this._display.focus_window = null;
    }

    unminimize() {
        this.minimized = false;
    }

    maximize(...maximizeArguments) {
        this.maximizeArgumentLists.push(maximizeArguments);
        this.isMaximized = true;
    }
}

/** The pulse and cockpit clients' listeners, as the checks attach to them. */
class FakeListeners {
    constructor() {
        this._listeners = new Map();
        this._nextListenerId = 1;
    }

    add(callback) {
        const listenerId = this._nextListenerId++;
        this._listeners.set(listenerId, callback);
        return listenerId;
    }

    remove(listenerId) {
        this._listeners.delete(listenerId);
    }

    tell(value) {
        [...this._listeners.values()].forEach(listener => listener(value));
    }

    get count() {
        return this._listeners.size;
    }
}

/** The cockpit client: focusSession on its prototype, as the real one has it. */
class FakeCockpitClient {
    constructor() {
        this.state = 'live';
        this._isSubscriptionWanted = true;
        this.listeners = new FakeListeners();
        this.focusSessionCalls = 0;
    }

    addListener(callback) {
        return this.listeners.add(callback);
    }

    removeListener(listenerId) {
        this.listeners.remove(listenerId);
    }

    focusSession(_sessionId) {
        this.focusSessionCalls++;
        return Promise.resolve({focused: true});
    }
}

/**
 * A sessions card with one row per name, each shown, reactive, with a bar, a tooltip and a session id.
 *
 * @param {{x: number, y: number}} origin - Where its rows start, in stage pixels.
 * @returns {FakeActor} The card.
 */
function makeSessionsCard(origin) {
    const card = new FakeActor({rect: {...origin, width: DROPDOWN_CARD_WIDTH_PX, height: 300}});
    card.redirect = OFFSCREEN_REDIRECT.ALWAYS;
    card._isFrozen = false;
    card._sessionRows = SESSION_NAMES.map((name, rowIndex) => {
        const rowRect = {x: origin.x + 10, y: origin.y + 40 + rowIndex * 30, width: 300, height: 24};
        const row = {
            actor: new FakeActor({rect: rowRect, reactive: true}),
            nameLabel: new FakeActor({text: name}),
            bar: new FakeActor({rect: {x: 0, y: 0, width: 30, height: 4}}),
            barTrack: new FakeActor({rect: {x: 0, y: 0, width: 60, height: 4}}),
            tooltipLines: [name, `pane p${rowIndex + 1}`],
            sessionId: `w1:p${rowIndex + 1}`,
        };
        card.add_child(row.actor);
        return row;
    });
    return card;
}

/**
 * A tooltip of the cockpit: shown or not, its label in the given parent.
 *
 * @param {FakeActor} labelParent - Where its label is (the chrome).
 * @returns {{_isShown: boolean, _label: FakeActor}} The tooltip.
 */
function makeTooltip(labelParent) {
    const tooltip = {_isShown: false, _label: labelParent.add_child(new FakeActor({text: ''}))};
    tooltip._label.visible = false;
    return tooltip;
}

/**
 * Builds one enable's worth of the extension's parts into the shell's actor tree: the layer with its four cards and
 * three captions, the v2 card in the system cell, the indicator with its dropdown, and both clients.
 *
 * @param {object} shell - The shell being built (its groups exist already).
 * @returns {object} The parts, as the extension's fields hold them.
 */
function buildExtensionParts(shell) {
    const layer = shell.backgroundGroup.add_child(new FakeActor({styleClasses: ['rp-cockpit-layer']}));
    const cardsById = new Map();
    for (const cardId of KNOWN_CARD_IDS) {
        const cell = CELLS_BY_CARD_ID[cardId];
        const card = cardId === 'sessions' ? makeSessionsCard(cell)
            : new FakeActor({styleClasses: ['rp-cockpit-cell'], rect: cell});
        card.rect = {...cell};
        card.redirect = cardId === 'system' ? 0 : OFFSCREEN_REDIRECT.ALWAYS;
        card._noDataLabel = card.add_child(new FakeActor({text: ''}));
        card._noDataLabel.visible = false;
        card._contentBox = card.add_child(new FakeActor());
        cardsById.set(cardId, layer.add_child(card));
    }
    const v2Card = cardsById.get('system').add_child(new FakeActor({styleClasses: ['resource-pulse-card']}));
    Object.assign(layer, {
        monitorIndex: 0,
        layout: LAYOUT,
        _cardsById: cardsById,
        _captionLabels: CAPTIONS.map((caption, captionIndex) => layer.add_child(new FakeActor({
            styleClasses: ['rp-cockpit-caption'], text: caption,
            rect: {x: 40 + captionIndex * 1280, y: 40, width: 120, height: 30},
        }))),
        _isInteractive: true,
        _frozenCardIds: new Set(),
        _tooltip: makeTooltip(shell.uiGroup),
        cardRects: () => KNOWN_CARD_IDS.map(cardId => ({cardId, rect: {...CELLS_BY_CARD_ID[cardId]}})),
    });
    Object.defineProperty(layer, 'drawnCardIds', {get: () => [...cardsById.keys()]});
    const menuActor = shell.uiGroup.add_child(new FakeActor());
    const cardItem = menuActor.add_child(new FakeActor());
    const sessionsItem = menuActor.add_child(new FakeActor());
    const openResourcesItem = menuActor.add_child(new FakeActor());
    const dropdownCard = cardItem.add_child(new FakeActor({rect: {x: 2600, y: 40, width: DROPDOWN_CARD_WIDTH_PX,
        height: 200}}));
    const dropdownSessionsCard = sessionsItem.add_child(makeSessionsCard({x: 2600, y: 260}));
    dropdownSessionsCard._isFrozen = true;
    const menu = {
        isOpen: false,
        actor: menuActor,
        // GNOME Shell 50.1's PopupMenu.open() (js/ui/popupMenu.js) raises the menu's actor to the top of its parent,
        // Main.uiGroup, on every open: above the top chrome a tooltip's label was added to when it was made.
        open() {
            this.isOpen = true;
            this.actor.get_parent().set_child_above_sibling(this.actor, null);
            dropdownSessionsCard._isFrozen = false;
        },
        close() {
            this.isOpen = false;
            dropdownSessionsCard._isFrozen = true;
        },
        _getMenuItems: () => [cardItem, sessionsItem, openResourcesItem],
    };
    const indicator = {
        menu, _sessionsItem: sessionsItem, _sessionsCard: dropdownSessionsCard, _dropdownCard: dropdownCard,
        _openResourcesItem: openResourcesItem, _sessionsTooltip: makeTooltip(shell.uiGroup),
        // The top bar's own hover label, in the top chrome as indicator.js adds it.
        _hoverLabel: shell.uiGroup.add_child(new FakeActor({styleClasses: ['resource-pulse-hover-label']})),
    };
    const pulseListeners = new FakeListeners();
    const pulseClient = {
        historyListeners: pulseListeners,
        addHistoryListener: callback => pulseListeners.add(callback),
        removeHistoryListener: listenerId => pulseListeners.remove(listenerId),
    };
    return {
        _layer: layer, _card: v2Card, _client: pulseClient, _cockpitClient: new FakeCockpitClient(),
        _indicator: indicator, _isCardVisible: true, _visibleCardIds: [...KNOWN_CARD_IDS],
        _isCockpitSubscriptionWanted: true,
        _displayConfigState: [1, [[['Virtual-1', 'MetaVendor', 'MetaVirtualMonitor', '0x1'], [], {}]],
            [[0, 0, 1, 0, true, [['Virtual-1', 'MetaVendor', 'MetaVirtualMonitor', '0x1']], {}]], {}],
    };
}

/**
 * Takes one enable's parts out of the shell, as disable() does, but for the hover label when asked to leave it.
 *
 * @param {object} stateObj - The extension's object.
 * @param {{leaveHoverLabelBehind?: boolean}} [faults] - What this disable leaves behind.
 * @returns {void}
 */
function tearDownExtensionParts(stateObj, {leaveHoverLabelBehind = false} = {}) {
    const layer = stateObj._layer;
    layer?.get_parent()?.remove_child(layer);
    for (const tooltip of [layer?._tooltip, stateObj._indicator?._sessionsTooltip])
        tooltip?._label.get_parent()?.remove_child(tooltip._label);
    const hoverLabel = stateObj._indicator?._hoverLabel;
    if (!leaveHoverLabelBehind)
        hoverLabel?.get_parent()?.remove_child(hoverLabel);
    const menuActor = stateObj._indicator?.menu.actor;
    menuActor?.get_parent()?.remove_child(menuActor);
    Object.assign(stateObj, {_layer: null, _card: null, _client: null, _cockpitClient: null, _indicator: null});
}

/**
 * Timeouts that run on the microtask queue, so a row's async request settles without a main loop.
 *
 * @returns {object} The GLib names the checks use.
 */
function makeFakeGLib() {
    return {
        PRIORITY_DEFAULT: 0,
        SOURCE_REMOVE,
        SOURCE_CONTINUE,
        get_monotonic_time: () => 1000,
        timeout_add(_priority, _intervalMs, callback) {
            const runOnce = () => {
                if (callback() === SOURCE_CONTINUE)
                    Promise.resolve().then(runOnce);
            };
            Promise.resolve().then(runOnce);
            return 1;
        },
    };
}

/**
 * A fake nested shell drawing the cockpit healthily: the extension ACTIVE, the grid on the only monitor, two windows
 * (the probe focused on top, the decoy under it), the virtual pointer's seat.
 *
 * @returns {object} The shell: its parts by name, and `scope`, the free names the checks are evaluated with.
 */
function makeHealthyShell() {
    const stage = new FakeActor({rect: {x: 0, y: 0, width: MONITOR.width, height: MONITOR.height}});
    const uiGroup = stage.add_child(new FakeActor());
    const windowGroup = uiGroup.add_child(new FakeActor());
    const backgroundGroup = windowGroup.add_child(new FakeActor());
    const shell = {stage, uiGroup, windowGroup, backgroundGroup};
    const stateObj = buildExtensionParts(shell);
    const extension = {uuid: EXTENSION_UUID, state: EXTENSION_STATE.ACTIVE, error: '', stateObj};
    const managerListeners = new FakeListeners();
    const display = {focus_window: null, windows: [], stackOrder: []};
    display.list_all_windows = () => [...display.windows];
    display.sort_windows_by_stacking = windows => [...windows]
        .sort((first, second) => display.stackOrder.indexOf(first) - display.stackOrder.indexOf(second));
    const decoyWindow = new FakeWindow(display, DECOY_PID, 'rp-decoy');
    const probeWindow = new FakeWindow(display, PROBE_PID, 'herdr-probe');
    display.windows.push(decoyWindow, probeWindow);
    display.stackOrder.push(decoyWindow, probeWindow);
    display.focus_window = probeWindow;
    const lifecycle = {leaveActorBehind: false, leaveHoverLabelBehind: false, leaveCaptionBehind: false,
        buildLayerAfterActivation: false, reuseOldCard: false, neverDeactivates: false};
    const extensionManager = {
        lookup: uuid => (uuid === EXTENSION_UUID ? extension : undefined),
        connect: (_signalName, handler) => managerListeners.add(changed => handler(extensionManager, changed)),
        disconnect: listenerId => managerListeners.remove(listenerId),
        disableExtension() {
            if (lifecycle.neverDeactivates)
                return true;
            const keptLayer = stateObj._layer;
            if (lifecycle.leaveCaptionBehind)
                backgroundGroup.add_child(keptLayer._captionLabels[0]);
            tearDownExtensionParts(stateObj, lifecycle);
            if (lifecycle.leaveActorBehind)
                backgroundGroup.add_child(keptLayer);
            extension.state = EXTENSION_STATE.INACTIVE;
            return true;
        },
        enableExtension() {
            const oldCard = shell.oldCard;
            const newParts = buildExtensionParts(shell);
            if (lifecycle.reuseOldCard)
                newParts._card = oldCard;
            const builtLayer = newParts._layer;
            if (lifecycle.buildLayerAfterActivation)
                newParts._layer = null;
            Object.assign(stateObj, newParts);
            extension.state = EXTENSION_STATE.ACTIVE;
            managerListeners.tell(extension);
            stateObj._layer = builtLayer;
            return true;
        },
    };
    const devices = [];
    const seat = {
        create_virtual_device(deviceType) {
            const device = {deviceType, motions: [], buttons: [],
                notify_absolute_motion(_timeUs, x, y) {
                    this.motions.push([x, y]);
                },
                notify_button(_timeUs, button, buttonState) {
                    this.buttons.push([button, buttonState]);
                }};
            devices.push(device);
            return device;
        },
    };
    const pointerPosition = {x: 0, y: 0};
    Object.assign(shell, {
        stateObj, extension, display, decoyWindow, probeWindow, lifecycle, devices, seat, pointerPosition,
        managerListeners,
        scope: {
            Main: {
                extensionManager,
                layoutManager: {
                    _backgroundGroup: backgroundGroup, monitors: [{...MONITOR}], uiGroup,
                    getWorkAreaForMonitor: () => ({...WORK_AREA}),
                },
                activateWindow(window) {
                    window.unminimize();
                    display.focus_window = window;
                    display.stackOrder = [...display.stackOrder.filter(other => other !== window), window];
                },
            },
            global: {
                stage, display, backend: {get_default_seat: () => seat},
                get_pointer: () => [pointerPosition.x, pointerPosition.y, 0],
            },
            imports: {gi: {Clutter: {
                OffscreenRedirect: OFFSCREEN_REDIRECT, InputDeviceType: {POINTER_DEVICE: 1}, BUTTON_PRIMARY: 1,
                ButtonState: {RELEASED: 0, PRESSED: 1},
            }}},
            globalThis: {},
            Meta: {WindowType: WINDOW_TYPE, MaximizeFlags: {BOTH: 3}},
            GLib: makeFakeGLib(),
            ExtensionUtils: {ExtensionState: EXTENSION_STATE},
        },
    });
    shell.oldCard = stateObj._card;
    return shell;
}

/**
 * Runs one of nested/'s files with one request, as the harness sends it: the text, then a call of its function,
 * evaluated in strict mode with the shell's free names bound to the fake's.
 *
 * @param {string} fileName - 'cockpit-check.js' or 'pointer.js'.
 * @param {string} functionName - The function the file declares.
 * @param {object} scope - The fake shell's names.
 * @param {string} request - The request.
 * @param {object} [options] - Its options.
 * @returns {object|Promise<object>} The answer.
 */
function runNestedFile(fileName, functionName, scope, request, options = {}) {
    const code = `${readNestedFile(fileName)}\n${functionName}(${JSON.stringify(request)}, ${JSON.stringify(options)});`;
    // A script for the shell's Eval, run the way Eval runs it: a direct eval of this repository's own file, in a fixed
    // function body (nothing is interpolated into it) that binds the names.
    // eslint-disable-next-line no-new-func
    const evaluateInShellScope = new Function('Main', 'global', 'imports', 'globalThis', 'Meta', 'GLib',
        'ExtensionUtils', 'code', "'use strict'; return eval(code);");
    const {Main, global, imports, globalThis: checkGlobal, Meta, GLib: shellGLib, ExtensionUtils} = scope;
    return evaluateInShellScope(Main, global, imports, checkGlobal, Meta, shellGLib, ExtensionUtils, code);
}

/**
 * @param {object} shell - From makeHealthyShell.
 * @param {string} request - A request of cockpit-check.js.
 * @param {object} [options] - Its options.
 * @returns {object|Promise<object>} The answer.
 */
function check(shell, request, options) {
    return runNestedFile('cockpit-check.js', CHECK_FUNCTION_NAME, shell.scope, request, options);
}

/**
 * Runs a request once per case, each on a fresh healthy shell the case may break first, and gives each case's verdict
 * and whether the answer's detail holds the case's needle.
 *
 * @param {string} request - The request.
 * @param {Object<string, {breakShell?: function(object): void, options?: object, needle?: string}>} cases - By name.
 * @returns {Promise<Object<string, string>>} "<verdict>" per case, plus "+needle" when its needle is in the detail.
 */
async function verdictsOfCases(request, cases) {
    const verdicts = {};
    for (const [caseName, {breakShell = () => {}, options, needle}] of Object.entries(cases)) {
        const shell = makeHealthyShell();
        breakShell(shell);
        // eslint-disable-next-line no-await-in-loop
        const answer = await check(shell, request, typeof options === 'function' ? options(shell) : options);
        const needleMark = needle !== undefined && answer.detail?.includes(needle) ? '+needle' : '';
        verdicts[caseName] = `${answer.verdict}${needleMark}`;
    }
    return verdicts;
}

/** Shows the probe's window as the cover step's covering window: maximized over everything. */
const PROBE_OPTIONS = Object.freeze({pid: PROBE_PID});

test('cockpit check: extension-active is ok while ACTIVE, bad naming another state, and could-not-judge for an ' +
    'extension the shell does not know', async () => {
    assertEqual(await verdictsOfCases('extension-active', {
        healthy: {},
        error: {breakShell: shell => {
            shell.extension.state = EXTENSION_STATE.ERROR;
            shell.extension.error = 'boom';
        }, needle: 'the extension is ERROR, not ACTIVE: boom'},
        unknown: {breakShell: shell => {
            shell.scope.Main.extensionManager.lookup = () => undefined;
        }},
    }), {healthy: OK, error: `${BAD}+needle`, unknown: COULD_NOT_JUDGE});
});

test('cockpit check: layer-placement is ok for one layer on the only monitor, named by DisplayConfig, the v2 card in ' +
    'the system cell; bad for each fault; could-not-judge without the layer field or with two monitors', async () => {
    assertEqual(await verdictsOfCases('layer-placement', {
        healthy: {},
        'no-layer': {breakShell: shell => {
            shell.stateObj._layer = null;
        }, needle: 'no cockpit layer'},
        'two-layers': {breakShell: shell => {
            shell.backgroundGroup.add_child(new FakeActor({styleClasses: ['rp-cockpit-layer']}));
        }, needle: 'holds 2 cockpit layers'},
        'another-layer': {breakShell: shell => {
            shell.backgroundGroup.remove_child(shell.stateObj._layer);
            shell.backgroundGroup.add_child(new FakeActor({styleClasses: ['rp-cockpit-layer']}));
        }, needle: "is not the extension's"},
        'monitor-1': {breakShell: shell => {
            shell.stateObj._layer.monitorIndex = 1;
        }, needle: 'on monitor 1, not 0'},
        'no-display-config': {breakShell: shell => {
            shell.stateObj._displayConfigState = null;
        }, needle: 'DisplayConfig has not answered'},
        'display-config-elsewhere': {breakShell: shell => {
            shell.stateObj._displayConfigState[2][0][0] = 3072;
        }, needle: 'names no monitor'},
        'v2-card-top-right': {breakShell: shell => {
            shell.backgroundGroup.add_child(shell.stateObj._card);
        }, needle: 'is also top right'},
        'no-layer-field': {breakShell: shell => {
            delete shell.stateObj._layer;
        }},
        'two-monitors': {breakShell: shell => {
            shell.scope.Main.layoutManager.monitors.push({...MONITOR, index: 1, x: 3072});
        }},
    }), {
        healthy: OK, 'no-layer': `${BAD}+needle`, 'two-layers': `${BAD}+needle`, 'another-layer': `${BAD}+needle`,
        'monitor-1': `${BAD}+needle`, 'no-display-config': `${BAD}+needle`,
        'display-config-elsewhere': `${BAD}+needle`, 'v2-card-top-right': `${BAD}+needle`,
        'no-layer-field': COULD_NOT_JUDGE, 'two-monitors': COULD_NOT_JUDGE,
    });
});

test('cockpit check: grid-geometry is ok for the known cards at their cells and the three captions; bad for a card ' +
    'off its cell or not shown, an unknown card drawn, a known one missing, a known card with no cell (none at all ' +
    'included), a cell off the work area, a caption wrong or hidden; could-not-judge without its options', async () => {
    assertEqual(await verdictsOfCases('grid-geometry', {
        healthy: {options: GRID_OPTIONS},
        'card-off-cell': {breakShell: shell => {
            shell.stateObj._layer._cardsById.get('apps').rect.x += 5;
        }, options: GRID_OPTIONS, needle: 'the apps card is at 600x500+685+80, not its cell 600x500+680+80'},
        'card-not-shown': {breakShell: shell => {
            shell.stateObj._layer._cardsById.get('connections').mapped = false;
        }, options: GRID_OPTIONS, needle: 'the connections card is not on screen'},
        'unknown-drawn': {breakShell: shell => {
            shell.stateObj._layer._cardsById.set('health', new FakeActor());
        }, options: GRID_OPTIONS, needle: 'a card for the unknown health'},
        'known-missing': {breakShell: shell => {
            shell.stateObj._layer._cardsById.delete('apps');
        }, options: GRID_OPTIONS, needle: 'the layer draws connections, sessions, system, not apps,'},
        'no-cells': {breakShell: shell => {
            shell.stateObj._layer.cardRects = () => [];
        }, options: GRID_OPTIONS, needle: 'the layer lays out cells for no card, not apps, connections, sessions, system'},
        'cell-missing': {breakShell: shell => {
            shell.stateObj._layer.cardRects = () => KNOWN_CARD_IDS.filter(cardId => cardId !== 'apps')
                .map(cardId => ({cardId, rect: {...CELLS_BY_CARD_ID[cardId]}}));
        }, options: GRID_OPTIONS,
        needle: 'the layer lays out cells for connections, sessions, system, not apps, connections, sessions, system'},
        'cell-off-work-area': {breakShell: shell => {
            const sessionsCell = {x: 1320, y: 10, width: 600, height: 500};
            shell.stateObj._layer.cardRects = () => [{cardId: 'sessions', rect: sessionsCell}];
            shell.stateObj._layer._cardsById.get('sessions').rect = {...sessionsCell};
        }, options: GRID_OPTIONS, needle: 'the sessions cell 600x500+1320+10 is outside the work area'},
        'caption-wrong': {breakShell: shell => {
            shell.stateObj._layer._captionLabels[2].text = 'LATER';
        }, options: GRID_OPTIONS, needle: "caption 2 reads 'LATER', not 'WORK'"},
        'caption-hidden': {breakShell: shell => {
            shell.stateObj._layer._captionLabels[1].mapped = false;
        }, options: GRID_OPTIONS, needle: 'the caption AGENTS is not drawn'},
        'no-options': {options: {}},
    }), {
        healthy: OK, 'card-off-cell': `${BAD}+needle`, 'card-not-shown': `${BAD}+needle`,
        'unknown-drawn': `${BAD}+needle`, 'known-missing': `${BAD}+needle`, 'no-cells': `${BAD}+needle`,
        'cell-missing': `${BAD}+needle`, 'cell-off-work-area': `${BAD}+needle`,
        'caption-wrong': `${BAD}+needle`, 'caption-hidden': `${BAD}+needle`, 'no-options': COULD_NOT_JUDGE,
    });
});

test('cockpit check: layer-interactive is ok while the layer takes the pointer with no DESKTOP window and reactive ' +
    'rows; bad for each of those; could-not-judge without the interactive mark', async () => {
    assertEqual(await verdictsOfCases('layer-interactive', {
        healthy: {},
        'not-interactive': {breakShell: shell => {
            shell.stateObj._layer._isInteractive = false;
        }, needle: 'does not take the pointer'},
        'desktop-window': {breakShell: shell => {
            const desktopWindow = new FakeWindow(shell.display, 99, 'ding');
            desktopWindow.windowType = WINDOW_TYPE.DESKTOP;
            shell.display.windows.push(desktopWindow);
        }, needle: 'a DESKTOP window shows'},
        'row-not-reactive': {breakShell: shell => {
            shell.stateObj._layer._cardsById.get('sessions')._sessionRows[1].actor.reactive = false;
        }, needle: 'a shown session row does not take the pointer'},
        'no-row': {breakShell: shell => {
            shell.stateObj._layer._cardsById.get('sessions')._sessionRows.forEach(row => {
                row.actor.visible = false;
            });
        }, needle: 'the sessions card shows no row'},
        'no-mark': {breakShell: shell => {
            delete shell.stateObj._layer._isInteractive;
        }},
    }), {
        healthy: OK, 'not-interactive': `${BAD}+needle`, 'desktop-window': `${BAD}+needle`,
        'row-not-reactive': `${BAD}+needle`, 'no-row': `${BAD}+needle`, 'no-mark': COULD_NOT_JUDGE,
    });
});

test('cockpit check: session-row-point gives the middle of the first session row of the layer\'s or the dropdown\'s ' +
    'card with its id, name and tooltip; bad with no row shown or off screen; could-not-judge for an unknown surface ' +
    'or rows it cannot read', async () => {
    const shell = makeHealthyShell();
    const layerPoint = check(shell, 'session-row-point', {surface: 'layer'});
    const dropdownPoint = check(shell, 'session-row-point', {surface: 'dropdown'});
    const pick = ({verdict, x, y, sessionId, name, tooltipText}) => ({verdict, x, y, sessionId, name, tooltipText});
    assertEqual({layer: pick(layerPoint), dropdown: pick(dropdownPoint)}, {
        layer: {verdict: OK, x: 1480, y: 132, sessionId: 'w1:p1', name: 'alpha-sync', tooltipText: 'alpha-sync\npane p1'},
        dropdown: {verdict: OK, x: 2760, y: 312, sessionId: 'w1:p1', name: 'alpha-sync',
            tooltipText: 'alpha-sync\npane p1'},
    });
    assertEqual(await verdictsOfCases('session-row-point', {
        'no-row': {breakShell: shell_ => {
            shell_.stateObj._layer._cardsById.get('sessions')._sessionRows.forEach(row => {
                row.sessionId = null;
            });
        }, options: {surface: 'layer'}, needle: 'shows no session row'},
        'off-screen': {breakShell: shell_ => {
            shell_.stateObj._indicator._sessionsCard._sessionRows[0].actor.mapped = false;
        }, options: {surface: 'dropdown'}, needle: 'is not on screen'},
        'no-dropdown-card': {breakShell: shell_ => {
            shell_.stateObj._indicator._sessionsCard = null;
        }, options: {surface: 'dropdown'}, needle: 'the dropdown has no sessions card'},
        'unknown-surface': {options: {surface: 'panel'}},
        'rows-unreadable': {breakShell: shell_ => {
            delete shell_.stateObj._layer._cardsById.get('sessions')._sessionRows;
        }, options: {surface: 'layer'}},
    }), {
        'no-row': `${BAD}+needle`, 'off-screen': `${BAD}+needle`, 'no-dropdown-card': `${BAD}+needle`,
        'unknown-surface': COULD_NOT_JUDGE, 'rows-unreadable': COULD_NOT_JUDGE,
    });
});

/**
 * Shows a surface's tooltip with a text, as the tooltip's own show does (CockpitTooltip._show(), which raises its
 * label above its siblings first).
 *
 * @param {object} shell - From makeHealthyShell.
 * @param {string} surface - 'layer' or 'dropdown'.
 * @param {string} text - Its text.
 * @param {{isRaised?: boolean}} [how] - isRaised false shows it as the extension did before it raised the label.
 * @returns {object} The tooltip.
 */
function showTooltip(shell, surface, text, {isRaised = true} = {}) {
    const tooltip = surface === 'layer' ? shell.stateObj._layer._tooltip : shell.stateObj._indicator._sessionsTooltip;
    tooltip._isShown = true;
    if (isRaised)
        tooltip._label.get_parent()?.set_child_above_sibling(tooltip._label, null);
    tooltip._label.visible = true;
    tooltip._label.text = text;
    return tooltip;
}

/**
 * Opens the dropdown as the shell does (the fake's open() raises the menu's actor, as PopupMenu.open() does).
 *
 * @param {object} shell - From makeHealthyShell.
 * @returns {void}
 */
function openDropdown(shell) {
    shell.stateObj._indicator.menu.open(false);
}

test('cockpit check: tooltip-shown is ok for the row\'s text drawn above the card or the open menu; bad when not ' +
    'shown, off screen, with another text, or under the card or the menu (a label not raised since the menu opened ' +
    'raised itself); could-not-judge when the stacking cannot be told; tooltip-hidden judges the reverse', async () => {
    const shownText = 'alpha-sync\npane p1';
    const shownOptions = surface => ({surface, tooltipText: shownText});
    assertEqual(await verdictsOfCases('tooltip-shown', {
        'layer-shown': {breakShell: shell => showTooltip(shell, 'layer', shownText), options: shownOptions('layer')},
        'dropdown-shown': {breakShell: shell => {
            openDropdown(shell);
            showTooltip(shell, 'dropdown', shownText);
        }, options: shownOptions('dropdown')},
        'not-shown': {options: shownOptions('layer'), needle: "the layer's tooltip is not shown"},
        'off-screen': {breakShell: shell => {
            showTooltip(shell, 'layer', shownText)._label.mapped = false;
        }, options: shownOptions('layer'), needle: 'marked shown but not on screen'},
        'other-text': {breakShell: shell => showTooltip(shell, 'layer', 'beta-docs'), options: shownOptions('layer'),
            needle: "reads 'beta-docs'"},
        'under-the-card': {breakShell: shell => {
            const label = showTooltip(shell, 'layer', shownText)._label;
            shell.windowGroup.add_child(label);
            shell.windowGroup.remove_child(shell.backgroundGroup);
            shell.windowGroup.add_child(shell.backgroundGroup);
        }, options: shownOptions('layer'), needle: 'drawn under the card'},
        'under-the-menu': {breakShell: shell => {
            openDropdown(shell);
            showTooltip(shell, 'dropdown', shownText, {isRaised: false});
        }, options: shownOptions('dropdown'), needle: 'drawn under the menu'},
        'no-shared-ancestor': {breakShell: shell => {
            const label = showTooltip(shell, 'layer', shownText)._label;
            label.get_parent().remove_child(label);
        }, options: shownOptions('layer')},
    }), {
        'layer-shown': OK, 'dropdown-shown': OK, 'not-shown': `${BAD}+needle`, 'off-screen': `${BAD}+needle`,
        'other-text': `${BAD}+needle`, 'under-the-card': `${BAD}+needle`, 'under-the-menu': `${BAD}+needle`,
        'no-shared-ancestor': COULD_NOT_JUDGE,
    });
    assertEqual(await verdictsOfCases('tooltip-hidden', {
        hidden: {options: {surface: 'dropdown'}},
        shown: {breakShell: shell => showTooltip(shell, 'dropdown', shownText), options: {surface: 'dropdown'},
            needle: "the dropdown's tooltip is still shown"},
        unreadable: {breakShell: shell => {
            delete shell.stateObj._layer._tooltip._isShown;
        }, options: {surface: 'layer'}},
    }), {hidden: OK, shown: `${BAD}+needle`, unreadable: COULD_NOT_JUDGE});
});

test('cockpit check: window-count counts normal windows; window-shown is ok for a window of the pid and bad until ' +
    'there is one; place-window-clear moves it to the first corner clear of the card, and window-clear is pending ' +
    'while it overlaps (the move may not have landed); no clear corner could not be judged: the harness\'s own setup',
    async () => {
    const shell = makeHealthyShell();
    const count = check(shell, 'window-count');
    const shown = check(shell, 'window-shown', PROBE_OPTIONS);
    const notYet = check(shell, 'window-shown', {pid: 77});
    // The sessions cell starts at the work area's top-left corner here, so the first corner does not do.
    shell.stateObj._layer.cardRects = () => [{cardId: 'sessions', rect: {x: 0, y: 32, width: 600, height: 500}}];
    const placed = check(shell, 'place-window-clear', {pid: PROBE_PID, cardId: 'sessions'});
    const clear = check(shell, 'window-clear', {pid: PROBE_PID, cardId: 'sessions'});
    shell.probeWindow.frame = {x: 10, y: 40, ...WINDOW_SIZE};
    const overlapping = check(shell, 'window-clear', {pid: PROBE_PID, cardId: 'sessions'});
    shell.stateObj._layer.cardRects = () => [{cardId: 'sessions', rect: {...WORK_AREA}}];
    const nowhere = check(shell, 'place-window-clear', {pid: PROBE_PID, cardId: 'sessions'});
    const noWindow = check(shell, 'place-window-clear', {pid: 77, cardId: 'sessions'});
    assertEqual({
        count: [count.verdict, count.count], shown: [shown.verdict, shown.title], notYet: notYet.verdict,
        placed: [placed.verdict, placed.x, placed.y], clear: clear.verdict,
        overlapping: [overlapping.verdict, overlapping.detail.includes('overlaps the sessions card')],
        nowhere: [nowhere.verdict, nowhere.detail.includes('no corner of the work area')], noWindow: noWindow.verdict,
    }, {
        count: [OK, 2], shown: [OK, 'herdr-probe'], notYet: BAD, placed: [OK, 2752, 32], clear: OK,
        overlapping: [PENDING, true], nowhere: [COULD_NOT_JUDGE, true], noWindow: COULD_NOT_JUDGE,
    });
});

test('cockpit check: focused-window is ok once the window has the focus, unminimized and on top; bad when the focus ' +
    'is elsewhere, it is minimized, it did not rise, or it only demands attention; could-not-judge with no such ' +
    'window', async () => {
    assertEqual(await verdictsOfCases('focused-window', {
        healthy: {options: PROBE_OPTIONS},
        'focus-elsewhere': {breakShell: shell => {
            shell.display.focus_window = shell.decoyWindow;
        }, options: PROBE_OPTIONS, needle: "the focus is on pid 4343's window, not 4242's"},
        'no-focus': {breakShell: shell => {
            shell.display.focus_window = null;
        }, options: PROBE_OPTIONS, needle: 'no window has the focus'},
        minimized: {breakShell: shell => {
            shell.probeWindow.minimized = true;
        }, options: PROBE_OPTIONS, needle: 'still minimized'},
        'not-on-top': {breakShell: shell => {
            shell.display.stackOrder.reverse();
        }, options: PROBE_OPTIONS, needle: 'is not the topmost: it did not rise'},
        flashing: {breakShell: shell => {
            shell.probeWindow.demands_attention = true;
        }, options: PROBE_OPTIONS, needle: 'it flashed rather than rose'},
        'no-window': {options: {pid: 77}},
    }), {
        healthy: OK, 'focus-elsewhere': `${BAD}+needle`, 'no-focus': `${BAD}+needle`, minimized: `${BAD}+needle`,
        'not-on-top': `${BAD}+needle`, flashing: `${BAD}+needle`, 'no-window': COULD_NOT_JUDGE,
    });
});

test('cockpit check: activate-window, minimize-all, maximize-window (with no argument: Mutter 50.1 takes none) and ' +
    'minimize-window act on the windows; a window minimize-all cannot minimize could not be judged; ' +
    'windows-unchanged is ok when nothing moved since remember-windows, bad naming what did, could-not-judge with ' +
    'nothing remembered', () => {
    const shell = makeHealthyShell();
    check(shell, 'activate-window', {pid: DECOY_PID});
    const decoyFocused = check(shell, 'focused-window', {pid: DECOY_PID}).verdict;
    const minimized = check(shell, 'minimize-all');
    const allMinimized = shell.display.windows.every(window => window.minimized);
    check(shell, 'remember-windows');
    const unchanged = check(shell, 'windows-unchanged').verdict;
    const forgotten = check(shell, 'windows-unchanged').verdict;
    check(shell, 'remember-windows');
    check(shell, 'maximize-window', PROBE_OPTIONS);
    const maximizeArgumentLists = shell.probeWindow.maximizeArgumentLists;
    const unminimizedByMaximize = !shell.probeWindow.minimized;
    const moved = check(shell, 'windows-unchanged');
    check(shell, 'remember-windows');
    shell.scope.Main.activateWindow(shell.probeWindow);
    const focusMoved = check(shell, 'windows-unchanged');
    check(shell, 'minimize-window', PROBE_OPTIONS);
    const stuckShell = makeHealthyShell();
    stuckShell.probeWindow.isMinimizable = false;
    const stuck = check(stuckShell, 'minimize-all');
    assertEqual({
        decoyFocused, minimized: [minimized.verdict, minimized.count], allMinimized, unchanged, forgotten,
        maximizeArgumentLists, unminimizedByMaximize,
        stuck: [stuck.verdict, stuck.detail.includes('1 windows did not minimize')],
        moved: [moved.verdict, moved.detail.includes('minimized were 4242,4343, now 4343')],
        focusMoved: [focusMoved.verdict, focusMoved.detail.includes('the focus moved from pid null to pid 4242')],
        minimizedAgain: shell.probeWindow.minimized,
    }, {
        decoyFocused: OK, minimized: [OK, 2], allMinimized: true, unchanged: OK, forgotten: COULD_NOT_JUDGE,
        maximizeArgumentLists: [[]], unminimizedByMaximize: true, stuck: [COULD_NOT_JUDGE, true],
        moved: [BAD, true], focusMoved: [BAD, true],
        minimizedAgain: true,
    });
});

test('cockpit check: focus-calls counts the extension\'s FocusSession calls between arm and read, ok at the count ' +
    'expected and bad at another, then gives the client its own method back; could-not-judge unarmed or after the ' +
    'client changed', () => {
    const shell = makeHealthyShell();
    const client = shell.stateObj._cockpitClient;
    check(shell, 'focus-calls-arm');
    client.focusSession('w1:p1');
    const once = check(shell, 'focus-calls-read', {expectedCount: 1});
    const restored = Object.hasOwn(client, 'focusSession');
    check(shell, 'focus-calls-arm');
    client.focusSession('w1:p1');
    client.focusSession('w1:p1');
    const twice = check(shell, 'focus-calls-read', {expectedCount: 1});
    const unarmed = check(shell, 'focus-calls-read', {expectedCount: 1});
    check(shell, 'focus-calls-arm');
    shell.stateObj._cockpitClient = new FakeCockpitClient();
    const clientChanged = check(shell, 'focus-calls-read', {expectedCount: 0});
    assertEqual({
        once: once.verdict, restored, reachedTheClient: client.focusSessionCalls,
        twice: [twice.verdict, twice.detail], unarmed: unarmed.verdict, clientChanged: clientChanged.verdict,
        restoredAfterChange: Object.hasOwn(client, 'focusSession'),
    }, {
        once: OK, restored: false, reachedTheClient: 3, twice: [BAD, '2 FocusSession calls, not 1'],
        unarmed: COULD_NOT_JUDGE, clientChanged: COULD_NOT_JUDGE, restoredAfterChange: false,
    });
});

/**
 * Covers every card, as a maximized window does: none visible, each frozen, the subscription dropped.
 *
 * @param {object} shell - From makeHealthyShell.
 * @returns {void}
 */
function coverEveryCard(shell) {
    Object.assign(shell.stateObj, {_isCardVisible: false, _visibleCardIds: [], _isCockpitSubscriptionWanted: false});
    shell.stateObj._cockpitClient._isSubscriptionWanted = false;
    KNOWN_CARD_IDS.forEach(cardId => shell.stateObj._layer._frozenCardIds.add(cardId));
}

test('cockpit check: cover-state is ok covered (nothing visible, every card frozen, both subscriptions dropped) and ' +
    'visible (every card visible, none frozen, both wanted); bad for each part that does not match', async () => {
    const covered = {expect: 'covered'};
    const visible = {expect: 'visible'};
    assertEqual(await verdictsOfCases('cover-state', {
        covered: {breakShell: coverEveryCard, options: covered},
        visible: {options: visible},
        'covered-but-marked-visible': {breakShell: shell => {
            coverEveryCard(shell);
            shell.stateObj._isCardVisible = true;
        }, options: covered, needle: '_isCardVisible is true'},
        'covered-one-not-frozen': {breakShell: shell => {
            coverEveryCard(shell);
            shell.stateObj._layer._frozenCardIds.delete('apps');
        }, options: covered, needle: 'apps not frozen'},
        'covered-subscription-held': {breakShell: shell => {
            coverEveryCard(shell);
            shell.stateObj._cockpitClient._isSubscriptionWanted = true;
        }, options: covered, needle: 'the cockpit subscription is still wanted'},
        'visible-one-frozen': {breakShell: shell => {
            shell.stateObj._layer._frozenCardIds.add('sessions');
        }, options: visible, needle: 'sessions still frozen'},
        'visible-one-not-seen': {breakShell: shell => {
            shell.stateObj._visibleCardIds = ['system', 'apps', 'connections'];
        }, options: visible, needle: 'the visible cards are [apps, connections, system]'},
        'unknown-expectation': {options: {expect: 'dim'}},
    }), {
        covered: OK, visible: OK, 'covered-but-marked-visible': `${BAD}+needle`,
        'covered-one-not-frozen': `${BAD}+needle`, 'covered-subscription-held': `${BAD}+needle`,
        'visible-one-frozen': `${BAD}+needle`, 'visible-one-not-seen': `${BAD}+needle`,
        'unknown-expectation': COULD_NOT_JUDGE,
    });
});

test('cockpit check: row-name is ok when the first session row shows the name, bad naming what it shows', () => {
    const shell = makeHealthyShell();
    assertEqual([
        check(shell, 'row-name', {surface: 'layer', name: 'alpha-sync'}).verdict,
        check(shell, 'row-name', {surface: 'dropdown', name: 'alpha-sync-2'}).detail,
    ], [OK, "the dropdown's first session row shows alpha-sync, not alpha-sync-2"]);
});

/**
 * Tells the clients' listeners what the shell would: a Sample, and the sessions' change.
 *
 * @param {object} shell - From makeHealthyShell.
 * @returns {{sample: function(): void, change: function(): void}} The two events.
 */
function clientEvents(shell) {
    return {
        sample: () => shell.stateObj._client.historyListeners.tell(),
        change: () => shell.stateObj._cockpitClient.listeners.tell({type: 'sources', names: ['sessions'],
            cause: 'changed'}),
    };
}

test('cockpit check: draw-watch is ok for the name drawn on the first Sample after the change, bad drawn with the ' +
    'change itself or a Sample late or not at all, could-not-judge drawn with no Sample since the change (the ' +
    'fallback drew it) or armed on a closed dropdown, pending until the change and a Sample came, and removes its ' +
    'handlers once final', () => {
    const newName = 'alpha-sync-2';
    const watchOptions = {surface: 'layer', name: newName};
    /**
     * Arms a watch on a fresh shell, plays a script of events, reads it once.
     *
     * @param {function(object, object, object): void} play - (events, nameLabel, shell).
     * @returns {string} The verdict, with the detail for a bad or a could-not-judge.
     */
    const playAndRead = play => {
        const shell = makeHealthyShell();
        const nameLabel = shell.stateObj._layer._cardsById.get('sessions')._sessionRows[0].nameLabel;
        check(shell, 'draw-watch-arm', watchOptions);
        play(clientEvents(shell), nameLabel, shell);
        const answer = check(shell, 'draw-watch-read');
        const hasDetail = answer.verdict === BAD || answer.verdict === COULD_NOT_JUDGE;
        return hasDetail ? `${answer.verdict}: ${answer.detail}` : answer.verdict;
    };
    const openDropdownShell = makeHealthyShell();
    openDropdown(openDropdownShell);
    const handlerShell = makeHealthyShell();
    const handlerLabel = handlerShell.stateObj._layer._cardsById.get('sessions')._sessionRows[0].nameLabel;
    check(handlerShell, 'draw-watch-arm', watchOptions);
    const armedCounts = [handlerShell.stateObj._client.historyListeners.count,
        handlerShell.stateObj._cockpitClient.listeners.count, handlerLabel.handlerCount];
    const handlerEvents = clientEvents(handlerShell);
    handlerEvents.sample();
    handlerEvents.change();
    handlerLabel.text = newName;
    check(handlerShell, 'draw-watch-read');
    const finalCounts = [handlerShell.stateObj._client.historyListeners.count,
        handlerShell.stateObj._cockpitClient.listeners.count, handlerLabel.handlerCount];
    const alreadyShell = makeHealthyShell();
    assertEqual({
        onNextSample: playAndRead((events, nameLabel) => {
            events.sample();
            events.change();
            // The next Sample: the extension draws in its own history listener, which runs before the watch's, so the
            // text changes before the watch counts that Sample.
            nameLabel.text = newName;
            events.sample();
        }),
        withTheChange: playAndRead((events, nameLabel) => {
            nameLabel.text = newName;
            events.change();
        }),
        aSampleLate: playAndRead((events, nameLabel) => {
            events.change();
            events.sample();
            nameLabel.text = newName;
        }),
        never: playAndRead(events => {
            events.change();
            events.sample();
        }),
        // The pacing's one-shot fallback drew it, with the sampler silent: not "on the next Sample".
        drawnWithNoSample: playAndRead((events, nameLabel) => {
            events.sample();
            events.change();
            nameLabel.text = newName;
        }),
        noChangeYet: playAndRead(events => events.sample()),
        noSampleYet: playAndRead(events => events.change()),
        closedDropdown: check(makeHealthyShell(), 'draw-watch-arm', {surface: 'dropdown', name: newName}).verdict,
        openDropdown: check(openDropdownShell, 'draw-watch-arm', {surface: 'dropdown', name: newName}).verdict,
        alreadyShown: (() => {
            alreadyShell.stateObj._layer._cardsById.get('sessions')._sessionRows[0].nameLabel.text = newName;
            return check(alreadyShell, 'draw-watch-arm', watchOptions).verdict;
        })(),
        unarmed: check(makeHealthyShell(), 'draw-watch-read').verdict,
        armedCounts, finalCounts,
    }, {
        onNextSample: OK,
        withTheChange: `${BAD}: alpha-sync-2 was drawn before the next Sample: with the change itself`,
        aSampleLate: `${BAD}: alpha-sync-2 was drawn 1 Sample(s) after the next one`,
        never: `${BAD}: the change came and the next Sample did not draw alpha-sync-2`,
        drawnWithNoSample: `${COULD_NOT_JUDGE}: alpha-sync-2 was drawn with no Sample since the change: the ` +
            'pacing\'s fallback timeout drew it, so the sampler was silent',
        noChangeYet: PENDING, noSampleYet: PENDING, closedDropdown: COULD_NOT_JUDGE, openDropdown: OK,
        alreadyShown: COULD_NOT_JUDGE, unarmed: COULD_NOT_JUDGE,
        armedCounts: [1, 1, 1], finalCounts: [0, 0, 0],
    });
});

test('cockpit check: draw-watch-read gives its final answer again on every read until the watch is armed again (an ' +
    'arm that fails forgets it too), so a poll that asks again after a bad reads that bad, not "nothing is watched"',
() => {
    const newName = 'alpha-sync-2';
    const watchOptions = {surface: 'layer', name: newName};
    const shell = makeHealthyShell();
    const nameLabel = shell.stateObj._layer._cardsById.get('sessions')._sessionRows[0].nameLabel;
    const events = clientEvents(shell);
    const readTwice = () => [check(shell, 'draw-watch-read'), check(shell, 'draw-watch-read')]
        .map(({verdict, detail}) => `${verdict}: ${detail}`);
    check(shell, 'draw-watch-arm', watchOptions);
    nameLabel.text = newName;
    events.change();
    const badReads = readTwice();
    check(shell, 'draw-watch-arm', {surface: 'dropdown', name: newName});
    const afterFailedArm = check(shell, 'draw-watch-read');
    nameLabel.text = SESSION_NAMES[0];
    check(shell, 'draw-watch-arm', watchOptions);
    const afterArmingAgain = check(shell, 'draw-watch-read').verdict;
    events.sample();
    events.change();
    nameLabel.text = newName;
    events.sample();
    const okReads = readTwice();
    const drawnOnTime = `${OK}: alpha-sync-2 was drawn on the next Sample after the change`;
    const drawnWithTheChange = `${BAD}: alpha-sync-2 was drawn before the next Sample: with the change itself`;
    assertEqual({badReads, afterFailedArm: `${afterFailedArm.verdict}: ${afterFailedArm.detail}`, afterArmingAgain,
        okReads}, {
        badReads: [drawnWithTheChange, drawnWithTheChange],
        afterFailedArm: `${COULD_NOT_JUDGE}: nothing is watched: draw-watch-arm comes first`, afterArmingAgain: PENDING,
        okReads: [drawnOnTime, drawnOnTime],
    });
});

test('cockpit check: stale-card is ok stale while the card shows "no data since", fresh while it shows its rows, bad ' +
    'otherwise, could-not-judge for an unknown expectation or a card without its no-data line', async () => {
    const showStale = shell => {
        const card = shell.stateObj._layer._cardsById.get('connections');
        card._noDataLabel.visible = true;
        card._noDataLabel.text = 'no data since 09:41';
        card._contentBox.visible = false;
    };
    assertEqual(await verdictsOfCases('stale-card', {
        stale: {breakShell: showStale, options: {cardId: 'connections', expect: 'stale'}},
        'not-stale': {options: {cardId: 'connections', expect: 'stale'}, needle: "shows no 'no data since …' line"},
        fresh: {options: {cardId: 'connections', expect: 'fresh'}},
        'not-fresh': {breakShell: showStale, options: {cardId: 'connections', expect: 'fresh'},
            needle: "does not show its rows (it reads 'no data since 09:41')"},
        'unknown-expectation': {options: {cardId: 'connections', expect: 'old'}},
        'no-line': {breakShell: shell => {
            delete shell.stateObj._layer._cardsById.get('connections')._noDataLabel;
        }, options: {cardId: 'connections', expect: 'stale'}},
    }), {
        stale: OK, 'not-stale': `${BAD}+needle`, fresh: OK, 'not-fresh': `${BAD}+needle`,
        'unknown-expectation': COULD_NOT_JUDGE, 'no-line': COULD_NOT_JUDGE,
    });
});

test('cockpit check: dropdown-order is ok for the sessions item second, under the card\'s, above "Open Resources", ' +
    'shown; bad for each fault; could-not-judge while the cockpit is not live', async () => {
    assertEqual(await verdictsOfCases('dropdown-order', {
        healthy: {},
        'out-of-order': {breakShell: shell => {
            const indicator = shell.stateObj._indicator;
            indicator.menu._getMenuItems = () => [indicator._dropdownCard.get_parent(), indicator._openResourcesItem,
                indicator._sessionsItem];
        }, needle: 'the sessions item is item 2, not 1'},
        hidden: {breakShell: shell => {
            shell.stateObj._indicator._sessionsItem.visible = false;
        }, needle: 'hidden while the cockpit is live'},
        'no-item': {breakShell: shell => {
            shell.stateObj._indicator._sessionsItem = null;
        }, needle: 'the dropdown has no sessions item'},
        'not-live': {breakShell: shell => {
            shell.stateObj._cockpitClient.state = 'vanished';
        }},
    }), {
        healthy: OK, 'out-of-order': `${BAD}+needle`, hidden: `${BAD}+needle`, 'no-item': `${BAD}+needle`,
        'not-live': COULD_NOT_JUDGE,
    });
});

test('cockpit check: dropdown-open given names judges the rows at once, in the request that opens the menu; ' +
    'dropdown-card is ok open (unfrozen, the names, the system card\'s width, bars wider than zero, its own texture, ' +
    'in its item), bad for each fault, could-not-judge closed; dropdown-closed is ok closed with the card frozen and ' +
    'its tooltip hidden', async () => {
    const open = shell => check(shell, 'dropdown-open');
    const cardOptions = {names: SESSION_NAMES};
    const dropdownCard = shell => shell.stateObj._indicator._sessionsCard;
    assertEqual(await verdictsOfCases('dropdown-card', {
        healthy: {breakShell: open, options: cardOptions},
        frozen: {breakShell: shell => {
            open(shell);
            dropdownCard(shell)._isFrozen = true;
        }, options: cardOptions, needle: 'frozen while the menu is open'},
        'other-names': {breakShell: open, options: {names: ['alpha-sync']}, needle: 'the rows show alpha-sync, beta-docs'},
        narrower: {breakShell: shell => {
            open(shell);
            dropdownCard(shell).rect.width = 300;
        }, options: cardOptions, needle: 'the sessions card is 300 px wide, the system card 400 px'},
        'zero-bar': {breakShell: shell => {
            open(shell);
            dropdownCard(shell)._sessionRows[1].bar.rect.width = 0;
        }, options: cardOptions, needle: 'the bars of beta-docs are zero wide'},
        'no-texture': {breakShell: shell => {
            open(shell);
            dropdownCard(shell).redirect = 0;
        }, options: cardOptions, needle: 'does not draw through its own texture'},
        'out-of-item': {breakShell: shell => {
            open(shell);
            shell.uiGroup.add_child(dropdownCard(shell));
        }, options: cardOptions, needle: 'not inside its menu item'},
        closed: {options: cardOptions},
    }), {
        healthy: OK, frozen: `${BAD}+needle`, 'other-names': `${BAD}+needle`, narrower: `${BAD}+needle`,
        'zero-bar': `${BAD}+needle`, 'no-texture': `${BAD}+needle`, 'out-of-item': `${BAD}+needle`,
        closed: COULD_NOT_JUDGE,
    });
    assertEqual(await verdictsOfCases('dropdown-closed', {
        healthy: {},
        'still-open': {breakShell: open, needle: 'the dropdown is still open'},
        'tooltip-up': {breakShell: shell => showTooltip(shell, 'dropdown', 'x'), needle: 'tooltip is still shown'},
        'not-frozen': {breakShell: shell => {
            dropdownCard(shell)._isFrozen = false;
        }, needle: 'not frozen while the menu is closed'},
    }), {healthy: OK, 'still-open': `${BAD}+needle`, 'tooltip-up': `${BAD}+needle`, 'not-frozen': `${BAD}+needle`});
    const shell = makeHealthyShell();
    assertEqual([check(shell, 'dropdown-open').verdict, shell.stateObj._indicator.menu.isOpen,
        check(shell, 'dropdown-close').verdict, shell.stateObj._indicator.menu.isOpen], [OK, true, OK, false]);
    assertEqual(await verdictsOfCases('dropdown-open', {
        'rows-at-once': {options: cardOptions},
        'other-rows-at-once': {options: {names: ['alpha-sync']},
            needle: 'at the open, the rows show alpha-sync, beta-docs, not alpha-sync'},
        'names-not-a-list': {options: {names: 'alpha-sync'}},
    }), {'rows-at-once': OK, 'other-rows-at-once': `${BAD}+needle`, 'names-not-a-list': COULD_NOT_JUDGE});
});

test('cockpit check: lock-path is ok when disable leaves nothing and enable brings new parts with the grid back at ' +
    'once; bad for an actor left behind (the layer, the top bar\'s hover label, a caption), no layer at the ' +
    'activation, or an old part kept; could-not-judge when the extension never becomes INACTIVE', async () => {
    const timeoutOptions = {timeoutMs: SHORT_TIMEOUT_MS};
    assertEqual(await verdictsOfCases('lock-path', {
        healthy: {options: timeoutOptions},
        'left-behind': {breakShell: shell => {
            shell.lifecycle.leaveActorBehind = true;
        }, options: timeoutOptions, needle: 'actors of the extension are left in the stage'},
        'hover-label-left': {breakShell: shell => {
            shell.lifecycle.leaveHoverLabelBehind = true;
        }, options: timeoutOptions, needle: 'after disable, 1 actors of the extension are left in the stage'},
        'caption-left': {breakShell: shell => {
            shell.lifecycle.leaveCaptionBehind = true;
        }, options: timeoutOptions, needle: 'after disable, 1 actors of the extension are left in the stage'},
        'layer-later': {breakShell: shell => {
            shell.lifecycle.buildLayerAfterActivation = true;
        }, options: timeoutOptions, needle: 'the grid is not back at once'},
        'old-card-kept': {breakShell: shell => {
            shell.lifecycle.reuseOldCard = true;
        }, options: timeoutOptions, needle: 'after enable, card are the old objects'},
        'never-inactive': {breakShell: shell => {
            shell.lifecycle.neverDeactivates = true;
        }, options: timeoutOptions},
    }), {
        healthy: OK, 'left-behind': `${BAD}+needle`, 'hover-label-left': `${BAD}+needle`,
        'caption-left': `${BAD}+needle`, 'layer-later': `${BAD}+needle`, 'old-card-kept': `${BAD}+needle`,
        'never-inactive': COULD_NOT_JUDGE,
    });
});

test('cockpit check: an unknown request could not be judged, and a failure that is neither a fault nor a missing ' +
    'part is thrown out to Eval', () => {
    const shell = makeHealthyShell();
    const unknown = check(shell, 'everything');
    shell.scope.Main.layoutManager.getWorkAreaForMonitor = () => {
        throw new TypeError('no work area');
    };
    let thrownMessage = null;
    try {
        check(shell, 'grid-geometry', GRID_OPTIONS);
    } catch (error) {
        thrownMessage = error.message;
    }
    assertEqual([unknown.verdict, thrownMessage], [COULD_NOT_JUDGE, 'no work area']);
});

/**
 * @param {object} shell - From makeHealthyShell.
 * @param {string} request - A request of pointer.js.
 * @param {object} [options] - Its options.
 * @returns {object} The answer.
 */
function pointer(shell, request, options) {
    return runNestedFile('pointer.js', POINTER_FUNCTION_NAME, shell.scope, request, options);
}

test('nested pointer: one virtual pointer of the seat moves to a point, clicks once or twice there, and `at` says ' +
    'whether the pointer arrived; a point off the stage, a click count past two, or a seat with no virtual pointer ' +
    'could not be judged', () => {
    const shell = makeHealthyShell();
    const moved = pointer(shell, 'move', {x: 1480, y: 132});
    const clicked = pointer(shell, 'click', {x: 1480, y: 132});
    const doubleClicked = pointer(shell, 'click', {x: 1480, y: 132, clickCount: 2});
    const [device] = shell.devices;
    shell.pointerPosition.x = 1480.4;
    shell.pointerPosition.y = 131.8;
    const arrived = pointer(shell, 'at', {x: 1480, y: 132});
    const elsewhere = pointer(shell, 'at', {x: 1500, y: 132});
    const offStage = pointer(shell, 'move', {x: 4000, y: 10});
    const notANumber = pointer(shell, 'move', {x: 'left', y: 10});
    const threeClicks = pointer(shell, 'click', {x: 10, y: 10, clickCount: 3});
    const unknown = pointer(shell, 'drag', {x: 10, y: 10});
    const seatlessShell = makeHealthyShell();
    seatlessShell.scope.global.backend = {get_default_seat: () => null};
    const seatless = pointer(seatlessShell, 'move', {x: 10, y: 10});
    assertEqual({
        verdicts: [moved.verdict, clicked.verdict, doubleClicked.verdict, arrived.verdict, elsewhere.verdict],
        devicesMade: shell.devices.length, deviceType: device.deviceType, motions: device.motions,
        buttons: device.buttons,
        couldNotJudge: [offStage.verdict, notANumber.verdict, threeClicks.verdict, unknown.verdict, seatless.verdict],
    }, {
        verdicts: [OK, OK, OK, OK, BAD], devicesMade: 1, deviceType: 1,
        motions: [[1480, 132], [1480, 132], [1480, 132]],
        buttons: [[1, 1], [1, 0], [1, 1], [1, 0], [1, 1], [1, 0]],
        couldNotJudge: [COULD_NOT_JUDGE, COULD_NOT_JUDGE, COULD_NOT_JUDGE, COULD_NOT_JUDGE, COULD_NOT_JUDGE],
    });
});
