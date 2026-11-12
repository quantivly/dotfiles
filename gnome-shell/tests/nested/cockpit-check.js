// Test tooling for scripts/resource-pulse-nested.sh `check cockpit` and `window`, never loaded by the extension. The
// harness sends this file's text to the NESTED shell's Eval (org.gnome.Shell.Eval on the run's private bus), followed
// by one call of resourcePulseCockpitCheck('<request>', <options as JSON>), and reads the JSON of its answer. The same
// text runs under plain gjs against a fake shell, with rows (gnome-shell/tests/cockpitCheck.test.js).
//
// Each request reads the nested shell once (a few also act on it: a window moved, minimized or focused, the dropdown
// opened, the extension disabled and enabled) and judges what it read:
//   {verdict: 'ok', detail, ...data}      what the step asks for holds; data carries what the harness needs next
//   {verdict: 'bad', detail}              it does not; detail names every fault found
//   {verdict: 'pending', detail}          draw-watch-read and window-clear only: what it waits for has not happened
//                                         yet (the harness asks again, and one still pending at the end is
//                                         could-not-judge)
//   {verdict: 'could-not-judge', detail}  a part it reads is not there, or not of the shape it reads (the extension
//                                         or the shell changed shape), or a precondition of the step does not hold:
//                                         never ok and never bad, and the harness makes it exit 2
// It reads the extension's private fields, as the perf probe does. A field that is not there at all (undefined) is a
// could-not-judge, since reading on would judge nothing; a part that is null where the step needs one (no layer, no
// sessions item) is bad: the extension is not drawing what it should. A failure of the harness's own setup (a window
// it cannot place clear of the card, or minimize) is could-not-judge too: it is no fault of the extension.
//
// GNOME 50.1's Eval awaits the value its code evaluates to (shellDBus.js EvalAsync), so lock-path answers with a
// Promise and waits inside the shell. Every other request answers at once; the harness does the waiting between
// requests. Its state outlives each Eval in globalThis.__resourcePulseCockpitCheck (a remembered window snapshot, a
// FocusSession count, a draw watch and its final answer), and each handler it connects is removed when its answer is
// final.
//
// Requests (options in braces):
//   extension-active                    the extension is ACTIVE
//   layer-placement                     one cockpit layer, the extension's, in the background group, on monitor 0
//                                       (the only one); DisplayConfig answered and names that monitor; the v2 card
//                                       inside the system cell and none top right
//   grid-geometry {expectedCaptions,    the layer holds the layout's groups, draws exactly the known card ids, none of
//     expectedCardIds, unknownCardIds}  the unknown ones; each card on screen at its cell, inside the work area; each
//                                       caption shown with its text
//   layer-interactive                   the layer takes the pointer, no DESKTOP window, the session rows reactive
//   session-row-point {surface}         the middle of the first session row of the layer's or the dropdown's card, in
//                                       stage pixels, with its session id, name and tooltip text
//   tooltip-shown {surface,             that surface's tooltip shown with that text, on screen, drawn above the card
//     tooltipText}                      (the layer) or the open menu (the dropdown)
//   tooltip-hidden {surface}            that surface's tooltip not shown
//   window-count                        how many normal windows the nested session has
//   window-shown {pid}                  a normal window of that pid exists
//   place-window-clear {pid, cardId}    moves that window to the first corner of the work area where it does not
//                                       overlap the card; window-clear {pid, cardId} judges that it does not, pending
//                                       while it does (the move may not have landed yet)
//   activate-window {pid}               activates that window (Main.activateWindow), as the harness's own step
//   focused-window {pid}                that window has the focus, is not minimized, is the topmost normal window and
//                                       does not only demand attention
//   minimize-all, maximize-window {pid}, minimize-window {pid}   (maximize as Mutter 50.1 declares it: no argument)
//   remember-windows, windows-unchanged the focus and the minimized windows now, then judged unchanged since
//   focus-calls-arm, focus-calls-read   counts the extension's FocusSession calls between the two (the client's
//     {expectedCount}                   method wrapped on its object, then put back)
//   cover-state {expect}                'covered': no card visible, every drawn card frozen, both subscriptions
//                                       dropped; 'visible': every drawn card visible, none frozen, both wanted
//   row-name {surface, name}            the first session row of that surface shows that name
//   draw-watch-arm {surface, name},     watches for that name drawn on that surface (the dropdown's only while its
//     draw-watch-read                   menu is open): drawn on the first Sample after the sessions' change came is ok,
//                                       at the change itself or later is bad, with no Sample at all (the pacing's
//                                       fallback drew it) could-not-judge, unless sooner than that fallback can fire
//                                       (bad); a final answer is given again on every read until the watch is armed
//                                       again
//   stale-card {cardId, expect}         'stale': the card shows "no data since ..."; 'fresh': its rows, no such line
//   dropdown-order                      the sessions item is the menu's second item, under the card's and above
//                                       "Open Resources", shown, with the cockpit LIVE
//   dropdown-open {names?},             opens or closes the top bar dropdown, with no animation; given names, the
//     dropdown-close                    open also judges that the sessions card shows them at once, in this request
//   dropdown-card {names}               open: the sessions card unfrozen, showing those names, as wide as the system
//                                       card, its bars wider than zero, drawn through its own texture in its item
//   dropdown-closed                     closed: the menu closed, the sessions card frozen, its tooltip not shown
//   lock-path {timeoutMs}               disables the extension: nothing of it left in the shell; enables it: new
//                                       parts, and the grid back at once, from the kept layout
//   monotonic-time                      the shell's monotonic clock in µs (GLib.get_monotonic_time, the clock the
//                                       extension's log limiter keeps time by), as monotonicUsec

/**
 * Runs one request of `check cockpit` in the shell and judges what it reads.
 *
 * @param {string} request - One of the requests in the header.
 * @param {object} [options] - The request's options (see the header).
 * @returns {object|Promise<object>} The answer: {verdict, detail, ...data}.
 */
function resourcePulseCockpitCheck(request, options = {}) {
    const EXTENSION_UUID = 'resource-pulse@dotfiles';
    const CHECK_STATE_KEY = '__resourcePulseCockpitCheck';
    const LAYER_STYLE_CLASS = 'rp-cockpit-layer';
    const V2_CARD_STYLE_CLASS = 'resource-pulse-card';
    /**
     * The style classes of everything the extension adds to the shell: none may be left after disable(). The top bar's
     * hover label is in the top chrome, as the tooltips are; the captions are the layer's own.
     */
    const LEFT_BEHIND_STYLE_CLASSES = [LAYER_STYLE_CLASS, 'rp-cockpit-tooltip', 'rp-cockpit-cell', 'rp-cockpit-caption',
        V2_CARD_STYLE_CLASS, 'resource-pulse-hover-label'];
    const SYSTEM_CARD_ID = 'system';
    const SESSIONS_CARD_ID = 'sessions';
    const LAYER_SURFACE = 'layer';
    const DROPDOWN_SURFACE = 'dropdown';
    const COVERED_EXPECTATION = 'covered';
    const VISIBLE_EXPECTATION = 'visible';
    const STALE_EXPECTATION = 'stale';
    const FRESH_EXPECTATION = 'fresh';
    const COCKPIT_LIVE_STATE = 'live';
    const SOURCES_EVENT_TYPE = 'sources';
    const SESSIONS_SOURCE_NAME = 'sessions';
    const NO_DATA_SINCE_PREFIX = 'no data since ';
    const ONLY_MONITOR_INDEX = 0;
    const POSITION_TOLERANCE_PX = 1;
    const TOOLTIP_LINE_SEPARATOR = '\n';
    /** The sessions item's place in the dropdown, under the card's item (0) and above "Open Resources" (2). */
    const CARD_ITEM_INDEX = 0;
    const SESSIONS_ITEM_INDEX = 1;
    const OPEN_RESOURCES_ITEM_INDEX = 2;
    /** How often lock-path looks at the extension's state while it waits, and how long it waits by default. */
    const STATE_POLL_INTERVAL_MS = 50;
    const DEFAULT_LOCK_PATH_TIMEOUT_MS = 10000;
    /**
     * lib/constants.js COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS: a surface's pacing arms its one-shot fallback at a
     * cockpit event that finds none armed, and the fallback draws what is pending when no Sample came within it.
     */
    const COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS = 3;
    /**
     * How much sooner than its interval the fallback can fire: GLib.timeout_add_seconds lands on a whole second of its
     * own phase, up to a quarter second before the interval is up (gmain.c g_timeout_set_expiration; a 3 s one, armed
     * at forty phases under plain gjs, fired 2754 ms after it was armed at the earliest), and as much again is left for
     * the dispatch.
     */
    const FALLBACK_EARLIEST_MARGIN_MS = 500;
    /**
     * The most a name can be drawn before the draw watch counts the Sample that followed for the draw to be that
     * Sample's own: the extension draws inside the Sample's dispatch and the watch's history listener runs later in the
     * same dispatch, so the gap is the rest of one dispatch. What it trades: a stall that long inside one dispatch
     * would read as a stray draw, and a stray draw less than that before a Sample still reads ok.
     */
    const SAMPLE_OWN_DRAW_MAX_GAP_MS = 250;
    /** The field each surface's pacing holds its fallback's id in, as read from the extension's object. */
    const PACING_FALLBACK_FIELD_PATHS = Object.freeze({
        [LAYER_SURFACE]: '_layer._pacing._fallbackSourceId',
        [DROPDOWN_SURFACE]: '_indicator._sessionsPacing._fallbackSourceId',
    });
    const MS_PER_SECOND = 1000;
    const USEC_PER_MS = 1000;
    const OK_VERDICT = 'ok';
    const BAD_VERDICT = 'bad';
    const PENDING_VERDICT = 'pending';
    const COULD_NOT_JUDGE_VERDICT = 'could-not-judge';
    const Clutter = imports.gi.Clutter;

    /** Thrown when a step cannot be judged; the answer is could-not-judge with its message. */
    class CouldNotJudgeError extends Error {}
    /** Thrown when a part the step needs is missing from what the extension draws; the answer is bad. */
    class MissingPartError extends Error {}

    // A state made by an earlier version of this file (a pass of the same run before a fix) may lack a newer field:
    // each such field is read with `?? null`.
    globalThis[CHECK_STATE_KEY] ??= {rememberedWindows: null, focusCount: null, drawWatch: null, drawWatchAnswer: null};
    const checkState = globalThis[CHECK_STATE_KEY];

    const okAnswer = (detail, data = {}) => ({verdict: OK_VERDICT, detail, ...data});
    const badAnswer = faults => ({verdict: BAD_VERDICT, detail: faults.join('; ')});
    const pendingAnswer = detail => ({verdict: PENDING_VERDICT, detail});
    const couldNotJudgeAnswer = detail => ({verdict: COULD_NOT_JUDGE_VERDICT, detail});
    const judged = (faults, okDetail, data = {}) => (faults.length === 0 ? okAnswer(okDetail, data) : badAnswer(faults));

    /**
     * A field of one of the shell's objects, refusing one that is not there.
     *
     * @param {object|null} holder - The object.
     * @param {string} fieldName - The field.
     * @param {string} description - What the field is, for the could-not-judge.
     * @returns {*} The field's value (null included).
     * @throws {CouldNotJudgeError} When the field is undefined.
     */
    function readField(holder, fieldName, description) {
        const value = holder?.[fieldName];
        if (value === undefined)
            throw new CouldNotJudgeError(`cannot read ${description} (${fieldName})`);
        return value;
    }

    /**
     * @returns {object} The extension's object (its stateObj).
     * @throws {CouldNotJudgeError} When the shell does not know the extension or it has no object.
     */
    function extensionObject() {
        const extension = Main.extensionManager.lookup(EXTENSION_UUID);
        if (!extension?.stateObj)
            throw new CouldNotJudgeError(`the shell knows no object of ${EXTENSION_UUID}`);
        return extension.stateObj;
    }

    /**
     * @param {object} stateObj - The extension's object.
     * @returns {object} The cockpit layer.
     * @throws {MissingPartError} When the extension draws no layer.
     */
    function cockpitLayer(stateObj) {
        const layer = readField(stateObj, '_layer', "the extension's cockpit layer");
        if (layer === null)
            throw new MissingPartError('no cockpit layer: the grid is not drawn (look for "could not draw the cockpit layer")');
        return layer;
    }

    /**
     * @param {object} stateObj - The extension's object.
     * @returns {object} The top bar indicator.
     * @throws {MissingPartError} When there is none.
     */
    function topBarIndicator(stateObj) {
        const indicator = readField(stateObj, '_indicator', "the extension's top bar indicator");
        if (indicator === null)
            throw new MissingPartError('no top bar indicator');
        return indicator;
    }

    /**
     * @param {object} layer - The cockpit layer.
     * @param {string} cardId - A card id.
     * @returns {object} The layer's card of that id.
     * @throws {MissingPartError} When the layer draws none.
     */
    function layerCard(layer, cardId) {
        const card = readField(layer, '_cardsById', "the layer's cards").get(cardId);
        if (!card)
            throw new MissingPartError(`the layer draws no ${cardId} card`);
        return card;
    }

    /**
     * The sessions card of a surface: the layer's, or the dropdown's.
     *
     * @param {object} stateObj - The extension's object.
     * @param {string} surface - LAYER_SURFACE or DROPDOWN_SURFACE.
     * @returns {object} The card.
     * @throws {CouldNotJudgeError|MissingPartError} For an unknown surface, or a card that is not there.
     */
    function sessionsCard(stateObj, surface) {
        if (surface === LAYER_SURFACE)
            return layerCard(cockpitLayer(stateObj), SESSIONS_CARD_ID);
        if (surface !== DROPDOWN_SURFACE)
            throw new CouldNotJudgeError(`unknown surface '${surface}': ${LAYER_SURFACE} or ${DROPDOWN_SURFACE}`);
        const card = readField(topBarIndicator(stateObj), '_sessionsCard', "the dropdown's sessions card");
        if (card === null)
            throw new MissingPartError('the dropdown has no sessions card');
        return card;
    }

    /**
     * @param {object} card - A sessions card.
     * @returns {Array<object>} Its session rows (CardRow: actor, nameLabel, bar, barTrack, tooltipLines, sessionId).
     */
    function sessionRowsOf(card) {
        const rows = readField(card, '_sessionRows', "the sessions card's rows");
        if (!Array.isArray(rows))
            throw new CouldNotJudgeError("the sessions card's rows are not a list");
        return rows;
    }

    /**
     * @param {object} card - A sessions card.
     * @returns {object|null} Its first row shown with a session, or null.
     */
    function firstShownSessionRow(card) {
        return sessionRowsOf(card).find(row => row.actor.visible && row.sessionId !== null) ?? null;
    }

    /**
     * @param {object} actor - A Clutter actor.
     * @returns {{x: number, y: number, width: number, height: number}} Its rectangle on the stage.
     */
    function stageRect(actor) {
        const [x, y] = actor.get_transformed_position();
        const [width, height] = actor.get_transformed_size();
        return {x, y, width, height};
    }

    /**
     * @param {{x: number, y: number, width: number, height: number}} first - A rectangle.
     * @param {{x: number, y: number, width: number, height: number}} second - Another.
     * @returns {boolean} True when they share any area.
     */
    function doRectsOverlap(first, second) {
        return first.x < second.x + second.width && second.x < first.x + first.width &&
            first.y < second.y + second.height && second.y < first.y + first.height;
    }

    /**
     * @param {{x: number, y: number, width: number, height: number}} inner - A rectangle.
     * @param {{x: number, y: number, width: number, height: number}} outer - Another.
     * @returns {boolean} True when inner lies inside outer, to POSITION_TOLERANCE_PX.
     */
    function isRectInside(inner, outer) {
        return inner.x >= outer.x - POSITION_TOLERANCE_PX && inner.y >= outer.y - POSITION_TOLERANCE_PX &&
            inner.x + inner.width <= outer.x + outer.width + POSITION_TOLERANCE_PX &&
            inner.y + inner.height <= outer.y + outer.height + POSITION_TOLERANCE_PX;
    }

    /**
     * @param {{x: number, y: number, width: number, height: number}} actual - Where something is.
     * @param {{x: number, y: number, width: number, height: number}} expected - Where it should be.
     * @returns {boolean} True when every edge is within POSITION_TOLERANCE_PX.
     */
    function isSameRect(actual, expected) {
        return ['x', 'y', 'width', 'height'].every(key => Math.abs(actual[key] - expected[key]) <= POSITION_TOLERANCE_PX);
    }

    /**
     * @param {{x: number, y: number, width: number, height: number}} rect - A rectangle.
     * @returns {string} It as "WxH+X+Y", rounded.
     */
    function describeRect({x, y, width, height}) {
        return `${Math.round(width)}x${Math.round(height)}+${Math.round(x)}+${Math.round(y)}`;
    }

    /**
     * Whether one actor is painted above another: at the first ancestor they share, the child holding the first comes
     * later in the paint order (Clutter paints its children first to last).
     *
     * @param {object} upperActor - The actor that should be on top.
     * @param {object} lowerActor - The one it should cover.
     * @returns {boolean|null} The answer; null when they share no ancestor or one holds the other.
     */
    function isPaintedAbove(upperActor, lowerActor) {
        const ancestryOf = actor => {
            const ancestry = [];
            for (let ancestor = actor; ancestor; ancestor = ancestor.get_parent())
                ancestry.unshift(ancestor);
            return ancestry;
        };
        const upperAncestry = ancestryOf(upperActor);
        const lowerAncestry = ancestryOf(lowerActor);
        if (upperAncestry[0] !== lowerAncestry[0])
            return null;
        let depth = 0;
        while (depth < upperAncestry.length && depth < lowerAncestry.length &&
            upperAncestry[depth] === lowerAncestry[depth])
            depth++;
        if (depth === upperAncestry.length || depth === lowerAncestry.length)
            return null;
        const siblings = upperAncestry[depth - 1].get_children();
        return siblings.indexOf(upperAncestry[depth]) > siblings.indexOf(lowerAncestry[depth]);
    }

    /**
     * Every actor under a root, the root included, that carries one of the style classes.
     *
     * @param {object} rootActor - Where to look.
     * @param {string[]} styleClasses - The classes.
     * @returns {object[]} The actors found.
     */
    function actorsWithStyleClasses(rootActor, styleClasses) {
        const found = [];
        const pending = [rootActor];
        while (pending.length > 0) {
            const actor = pending.pop();
            if (styleClasses.some(styleClass => actor.has_style_class_name?.(styleClass)))
                found.push(actor);
            pending.push(...actor.get_children());
        }
        return found;
    }

    /** @returns {object[]} The nested session's normal windows. */
    function normalWindows() {
        return global.display.list_all_windows().filter(window => window.get_window_type() === Meta.WindowType.NORMAL);
    }

    /**
     * @param {number} pid - A process id.
     * @returns {object} The normal window of that process.
     * @throws {CouldNotJudgeError} When there is none: the step's own window is gone.
     */
    function windowOfPid(pid) {
        const window = normalWindows().find(candidate => candidate.get_pid() === pid);
        if (!window)
            throw new CouldNotJudgeError(`the nested session has no window of pid ${pid}`);
        return window;
    }

    /**
     * @param {string} cardId - A card id the layer draws.
     * @returns {{x: number, y: number, width: number, height: number}} Its cell, in stage pixels.
     */
    function layerCardRect(cardId) {
        const cell = cockpitLayer(extensionObject()).cardRects().find(cardRect => cardRect.cardId === cardId);
        if (!cell)
            throw new MissingPartError(`the layer has no cell for ${cardId}`);
        return cell.rect;
    }

    /**
     * Whether DisplayConfig's GetCurrentState answer names a monitor at a shell monitor's position: a logical monitor
     * at its x and y showing a monitor the answer lists.
     *
     * @param {Array} displayConfigState - The unpacked reply: (serial, monitors, logical monitors, properties).
     * @param {{x: number, y: number}} monitor - The shell's monitor.
     * @returns {boolean} True when it does.
     */
    function doesDisplayConfigNameMonitor(displayConfigState, monitor) {
        const [, physicalMonitors, logicalMonitors] = displayConfigState;
        if (!Array.isArray(physicalMonitors) || !Array.isArray(logicalMonitors))
            return false;
        const connectors = new Set(physicalMonitors.map(physicalMonitor => physicalMonitor?.[0]?.[0]));
        return logicalMonitors.some(([x, y, , , , monitorSpecs]) => x === monitor.x && y === monitor.y &&
            Array.isArray(monitorSpecs) && monitorSpecs.some(monitorSpec => connectors.has(monitorSpec?.[0])));
    }

    /** @returns {object} extension-active's answer. */
    function judgeExtensionActive() {
        const extension = Main.extensionManager.lookup(EXTENSION_UUID);
        if (!extension)
            throw new CouldNotJudgeError(`the shell does not know ${EXTENSION_UUID}`);
        const extensionStates = ExtensionUtils.ExtensionState;
        if (extension.state === extensionStates.ACTIVE)
            return okAnswer('ACTIVE');
        const stateName = Object.keys(extensionStates).find(name => extensionStates[name] === extension.state);
        const errorText = extension.error ? `: ${extension.error}` : '';
        return badAnswer([`the extension is ${stateName ?? extension.state}, not ACTIVE${errorText}`]);
    }

    /** @returns {object} layer-placement's answer. */
    function judgeLayerPlacement() {
        const stateObj = extensionObject();
        const layer = cockpitLayer(stateObj);
        const backgroundGroup = readField(Main.layoutManager, '_backgroundGroup', "the shell's background group");
        const monitors = Main.layoutManager.monitors;
        if (monitors.length !== 1)
            throw new CouldNotJudgeError(`the run has ${monitors.length} monitors, not the one the only-monitor rule needs`);
        const faults = [];
        const layerActors = backgroundGroup.get_children()
            .filter(actor => actor.has_style_class_name?.(LAYER_STYLE_CLASS));
        if (layerActors.length !== 1)
            faults.push(`the background group holds ${layerActors.length} cockpit layers, not one`);
        else if (layerActors[0] !== layer)
            faults.push("the background group's cockpit layer is not the extension's");
        if (layer.monitorIndex !== ONLY_MONITOR_INDEX)
            faults.push(`the layer is on monitor ${layer.monitorIndex}, not ${ONLY_MONITOR_INDEX}, the only one`);
        const displayConfigState = readField(stateObj, '_displayConfigState', "DisplayConfig's answer");
        if (displayConfigState === null)
            faults.push('DisplayConfig has not answered, or its read failed');
        else if (!doesDisplayConfigNameMonitor(displayConfigState, monitors[ONLY_MONITOR_INDEX]))
            faults.push("DisplayConfig's answer names no monitor at the shell's monitor 0");
        const v2Card = readField(stateObj, '_card', "the extension's v2 card");
        if (v2Card === null || v2Card.get_parent() !== layerCard(layer, SYSTEM_CARD_ID))
            faults.push('the v2 card is not inside the system cell');
        if (backgroundGroup.get_children().some(actor => actor.has_style_class_name?.(V2_CARD_STYLE_CLASS)))
            faults.push('a v2 card is also top right, in the background group');
        return judged(faults, 'one layer, on monitor 0, which DisplayConfig names; the v2 card in the system cell');
    }

    /**
     * @param {{expectedCaptions: string[], expectedCardIds: string[], unknownCardIds: string[]}} expectation - What the
     *     fixture's layout names.
     * @returns {object} grid-geometry's answer.
     */
    function judgeGridGeometry({expectedCaptions, expectedCardIds, unknownCardIds}) {
        if (!Array.isArray(expectedCaptions) || !Array.isArray(expectedCardIds) || !Array.isArray(unknownCardIds))
            throw new CouldNotJudgeError('grid-geometry needs expectedCaptions, expectedCardIds and unknownCardIds');
        const layer = cockpitLayer(extensionObject());
        const faults = [];
        const layoutCaptions = readField(layer, 'layout', "the layer's layout").groups.map(group => group.caption);
        if (JSON.stringify(layoutCaptions) !== JSON.stringify(expectedCaptions))
            faults.push(`the layer's layout has the groups ${layoutCaptions.join(', ')}, not ${expectedCaptions.join(', ')}`);
        const drawnCardIds = [...layer.drawnCardIds].sort();
        if (JSON.stringify(drawnCardIds) !== JSON.stringify([...expectedCardIds].sort()))
            faults.push(`the layer draws ${drawnCardIds.join(', ')}, not ${[...expectedCardIds].sort().join(', ')}`);
        const cardsById = readField(layer, '_cardsById', "the layer's cards");
        const drawnUnknownIds = unknownCardIds.filter(cardId => cardsById.has(cardId));
        if (drawnUnknownIds.length > 0)
            faults.push(`the layer draws a card for the unknown ${drawnUnknownIds.join(', ')}`);
        // Every expected card is judged, at the cell the layer laid out for it: a card with no cell (a placement the
        // layer skipped) is a fault, never a card left out of the loop. A missing cell or card is named above or here.
        const cellsByCardId = new Map(layer.cardRects().map(({cardId, rect}) => [cardId, rect]));
        const cellCardIds = [...cellsByCardId.keys()].sort();
        const sortedExpectedCardIds = [...expectedCardIds].sort();
        if (JSON.stringify(cellCardIds) !== JSON.stringify(sortedExpectedCardIds)) {
            const laidOutText = cellCardIds.length === 0 ? 'no card' : cellCardIds.join(', ');
            faults.push(`the layer lays out cells for ${laidOutText}, not ${sortedExpectedCardIds.join(', ')}`);
        }
        const workArea = Main.layoutManager.getWorkAreaForMonitor(ONLY_MONITOR_INDEX);
        for (const cardId of expectedCardIds) {
            const rect = cellsByCardId.get(cardId);
            const card = cardsById.get(cardId);
            if (!rect || !card)
                continue;
            const cardRect = stageRect(card);
            if (!card.mapped)
                faults.push(`the ${cardId} card is not on screen`);
            else if (!isSameRect(cardRect, rect))
                faults.push(`the ${cardId} card is at ${describeRect(cardRect)}, not its cell ${describeRect(rect)}`);
            if (!isRectInside(rect, workArea))
                faults.push(`the ${cardId} cell ${describeRect(rect)} is outside the work area ${describeRect(workArea)}`);
        }
        const captionLabels = readField(layer, '_captionLabels', "the layer's captions");
        captionLabels.forEach((captionLabel, captionIndex) => {
            const captionRect = stageRect(captionLabel);
            if (captionLabel.text !== expectedCaptions[captionIndex])
                faults.push(`caption ${captionIndex} reads '${captionLabel.text}', not '${expectedCaptions[captionIndex]}'`);
            else if (!captionLabel.mapped || captionRect.width <= 0 || captionRect.height <= 0)
                faults.push(`the caption ${captionLabel.text} is not drawn`);
        });
        if (captionLabels.length !== expectedCaptions.length)
            faults.push(`the layer has ${captionLabels.length} captions, not ${expectedCaptions.length}`);
        return judged(faults, `${drawnCardIds.join(', ')} at their cells; captions ${expectedCaptions.join(', ')}`);
    }

    /** @returns {object} layer-interactive's answer. */
    function judgeLayerInteractive() {
        const stateObj = extensionObject();
        const layer = cockpitLayer(stateObj);
        const faults = [];
        if (readField(layer, '_isInteractive', "the layer's interactive mark") !== true)
            faults.push('the layer does not take the pointer');
        const desktopWindows = global.display.list_all_windows()
            .filter(window => window.get_window_type() === Meta.WindowType.DESKTOP);
        if (desktopWindows.length > 0)
            faults.push(`a DESKTOP window shows (${desktopWindows.length}): the cards cannot take the pointer`);
        const shownRows = sessionRowsOf(sessionsCard(stateObj, LAYER_SURFACE)).filter(row => row.actor.visible);
        if (shownRows.length === 0)
            faults.push('the sessions card shows no row');
        else if (!shownRows.every(row => row.actor.reactive))
            faults.push('a shown session row does not take the pointer');
        return judged(faults, 'the layer takes the pointer; no DESKTOP window; the session rows are reactive');
    }

    /**
     * @param {{surface: string}} target - Which sessions card.
     * @returns {object} session-row-point's answer, with x, y, sessionId, name and tooltipText.
     */
    function sessionRowPoint({surface}) {
        const row = firstShownSessionRow(sessionsCard(extensionObject(), surface));
        if (row === null)
            return badAnswer([`the ${surface}'s sessions card shows no session row`]);
        const rowRect = stageRect(row.actor);
        if (!row.actor.mapped || rowRect.width <= 0 || rowRect.height <= 0)
            return badAnswer([`the ${surface}'s first session row is not on screen`]);
        const tooltipText = row.tooltipLines.join(TOOLTIP_LINE_SEPARATOR);
        return okAnswer(`the first session row, ${row.nameLabel.text}, at ${describeRect(rowRect)}`, {
            x: rowRect.x + rowRect.width / 2, y: rowRect.y + rowRect.height / 2, sessionId: row.sessionId,
            name: row.nameLabel.text, tooltipText,
        });
    }

    /**
     * @param {object} stateObj - The extension's object.
     * @param {string} surface - LAYER_SURFACE or DROPDOWN_SURFACE.
     * @returns {object} That surface's tooltip (CockpitTooltip).
     */
    function surfaceTooltip(stateObj, surface) {
        if (surface === LAYER_SURFACE)
            return readField(cockpitLayer(stateObj), '_tooltip', "the layer's tooltip");
        sessionsCard(stateObj, surface);
        return readField(topBarIndicator(stateObj), '_sessionsTooltip', "the dropdown's tooltip");
    }

    /**
     * @param {{surface: string, tooltipText: string}} expectation - Which tooltip, and its text.
     * @returns {object} tooltip-shown's answer.
     */
    function judgeTooltipShown({surface, tooltipText}) {
        const stateObj = extensionObject();
        const tooltip = surfaceTooltip(stateObj, surface);
        const label = readField(tooltip, '_label', "the tooltip's label");
        if (readField(tooltip, '_isShown', "the tooltip's shown mark") !== true || label === null)
            return badAnswer([`the ${surface}'s tooltip is not shown`]);
        const faults = [];
        if (!label.visible || !label.mapped)
            faults.push(`the ${surface}'s tooltip is marked shown but not on screen`);
        if (label.text !== tooltipText)
            faults.push(`the ${surface}'s tooltip reads '${label.text}', not '${tooltipText}'`);
        const coveredActor = surface === LAYER_SURFACE
            ? sessionsCard(stateObj, LAYER_SURFACE)
            : readField(topBarIndicator(stateObj).menu, 'actor', "the dropdown's menu actor");
        const isAbove = isPaintedAbove(label, coveredActor);
        if (isAbove === null)
            throw new CouldNotJudgeError(`cannot tell the ${surface}'s tooltip's stacking: no shared ancestor`);
        if (!isAbove)
            faults.push(`the ${surface}'s tooltip is drawn under the ${surface === LAYER_SURFACE ? 'card' : 'menu'}`);
        return judged(faults, `the ${surface}'s tooltip shows the row's text, above the ${surface}`);
    }

    /**
     * @param {{surface: string}} target - Which tooltip.
     * @returns {object} tooltip-hidden's answer.
     */
    function judgeTooltipHidden({surface}) {
        const isShown = readField(surfaceTooltip(extensionObject(), surface), '_isShown', "the tooltip's shown mark");
        return judged(isShown ? [`the ${surface}'s tooltip is still shown`] : [], `the ${surface}'s tooltip is hidden`);
    }

    /**
     * @param {{pid: number}} target - The window's process.
     * @returns {object} window-shown's answer, with the window's title.
     */
    function judgeWindowShown({pid}) {
        const window = normalWindows().find(candidate => candidate.get_pid() === pid);
        if (!window)
            return badAnswer([`no window of pid ${pid} yet`]);
        return okAnswer(`a window of pid ${pid}`, {title: window.get_title()});
    }

    /**
     * Moves a window to the first corner of the work area where its frame does not overlap a card's cell.
     *
     * @param {{pid: number, cardId: string}} target - The window's process, and the card to keep clear of.
     * @returns {object} place-window-clear's answer, with the corner's x and y.
     */
    function placeWindowClear({pid, cardId}) {
        const window = windowOfPid(pid);
        const cardRect = layerCardRect(cardId);
        const workArea = Main.layoutManager.getWorkAreaForMonitor(ONLY_MONITOR_INDEX);
        const {width, height} = window.get_frame_rect();
        const rightX = workArea.x + workArea.width - width;
        const bottomY = workArea.y + workArea.height - height;
        const corners = [[workArea.x, workArea.y], [rightX, workArea.y], [workArea.x, bottomY], [rightX, bottomY]];
        const clearCorner = corners.find(([x, y]) => !doRectsOverlap({x, y, width, height}, cardRect));
        if (!clearCorner) {
            throw new CouldNotJudgeError(
                `no corner of the work area keeps a ${width}x${height} window clear of the ${cardId} card`);
        }
        const [x, y] = clearCorner;
        window.move_frame(true, x, y);
        return okAnswer(`moved to ${x},${y}`, {x, y});
    }

    /**
     * Whether the harness's window is clear of a card: pending while it overlaps, since place-window-clear's move may
     * not have landed yet (the harness asks again; still overlapping at the end is could-not-judge, its own setup).
     *
     * @param {{pid: number, cardId: string}} target - The window's process, and the card.
     * @returns {object} window-clear's answer: ok or pending.
     */
    function judgeWindowClear({pid, cardId}) {
        const frameRect = windowOfPid(pid).get_frame_rect();
        if (doRectsOverlap(frameRect, layerCardRect(cardId)))
            return pendingAnswer(`the window of pid ${pid} at ${describeRect(frameRect)} overlaps the ${cardId} card`);
        return okAnswer(`the window of pid ${pid} is clear of the ${cardId} card`);
    }

    /**
     * @param {{pid: number}} target - The window's process.
     * @returns {object} focused-window's answer.
     */
    function judgeFocusedWindow({pid}) {
        const window = windowOfPid(pid);
        const focusWindow = global.display.focus_window;
        const faults = [];
        if (focusWindow === null)
            faults.push('no window has the focus');
        else if (focusWindow !== window)
            faults.push(`the focus is on pid ${focusWindow.get_pid()}'s window, not ${pid}'s`);
        if (window.minimized)
            faults.push(`pid ${pid}'s window is still minimized`);
        const stackedWindows = global.display.sort_windows_by_stacking(normalWindows());
        if (stackedWindows[stackedWindows.length - 1] !== window)
            faults.push(`pid ${pid}'s window is not the topmost: it did not rise`);
        if (window.demands_attention)
            faults.push(`pid ${pid}'s window demands attention: it flashed rather than rose`);
        return judged(faults, `pid ${pid}'s window has the focus, unminimized and on top`);
    }

    /**
     * Minimizes every normal window: the harness's own setup, so a window that did not minimize could not be judged.
     *
     * @returns {object} minimize-all's answer, with the count of windows.
     * @throws {CouldNotJudgeError} When a window did not minimize.
     */
    function minimizeAll() {
        const windows = normalWindows();
        windows.forEach(window => window.minimize());
        const stillShown = windows.filter(window => !window.minimized).length;
        if (stillShown > 0)
            throw new CouldNotJudgeError(`${stillShown} windows did not minimize`);
        return okAnswer(`${windows.length} windows minimized`, {count: windows.length});
    }

    /**
     * @returns {{focusPid: number|null, minimizedPids: number[]}} The focus and the minimized windows now.
     */
    function windowsSnapshot() {
        const focusWindow = global.display.focus_window;
        const minimizedPids = normalWindows().filter(window => window.minimized)
            .map(window => window.get_pid()).sort((first, second) => first - second);
        return {focusPid: focusWindow === null ? null : focusWindow.get_pid(), minimizedPids};
    }

    /** @returns {object} windows-unchanged's answer. */
    function judgeWindowsUnchanged() {
        if (checkState.rememberedWindows === null)
            throw new CouldNotJudgeError('nothing remembered: remember-windows comes first');
        const remembered = checkState.rememberedWindows;
        const now = windowsSnapshot();
        checkState.rememberedWindows = null;
        const faults = [];
        if (now.focusPid !== remembered.focusPid)
            faults.push(`the focus moved from pid ${remembered.focusPid} to pid ${now.focusPid}`);
        if (JSON.stringify(now.minimizedPids) !== JSON.stringify(remembered.minimizedPids))
            faults.push(`minimized were ${remembered.minimizedPids.join(',')}, now ${now.minimizedPids.join(',')}`);
        return judged(faults, 'no window was activated');
    }

    /** @returns {object} focus-calls-arm's answer: the cockpit client's focusSession wrapped to count its calls. */
    function armFocusCount() {
        const cockpitClient = readField(extensionObject(), '_cockpitClient', "the extension's cockpit client");
        if (typeof cockpitClient?.focusSession !== 'function')
            throw new CouldNotJudgeError('the cockpit client has no focusSession');
        disarmFocusCount();
        const focusCount = {cockpitClient, callCount: 0};
        const originalFocusSession = cockpitClient.focusSession;
        cockpitClient.focusSession = function (...focusArguments) {
            focusCount.callCount++;
            return originalFocusSession.apply(this, focusArguments);
        };
        checkState.focusCount = focusCount;
        return okAnswer('counting FocusSession calls');
    }

    /** Puts the cockpit client's own focusSession back (the prototype's), if it was wrapped. */
    function disarmFocusCount() {
        if (checkState.focusCount === null)
            return;
        delete checkState.focusCount.cockpitClient.focusSession;
        checkState.focusCount = null;
    }

    /**
     * @param {{expectedCount: number}} expectation - How many calls there must have been.
     * @returns {object} focus-calls-read's answer.
     */
    function readFocusCount({expectedCount}) {
        const focusCount = checkState.focusCount;
        if (focusCount === null)
            throw new CouldNotJudgeError('nothing is counted: focus-calls-arm comes first');
        const isSameClient = extensionObject()._cockpitClient === focusCount.cockpitClient;
        disarmFocusCount();
        if (!isSameClient)
            throw new CouldNotJudgeError('the cockpit client changed while counting: disabled or enabled meanwhile');
        const fault = `${focusCount.callCount} FocusSession calls, not ${expectedCount}`;
        return judged(focusCount.callCount === expectedCount ? [] : [fault], `${expectedCount} FocusSession call(s)`);
    }

    /**
     * @param {{expect: string}} expectation - COVERED_EXPECTATION or VISIBLE_EXPECTATION.
     * @returns {object} cover-state's answer.
     */
    function judgeCoverState({expect}) {
        if (expect !== COVERED_EXPECTATION && expect !== VISIBLE_EXPECTATION)
            throw new CouldNotJudgeError(`cover-state expects '${COVERED_EXPECTATION}' or '${VISIBLE_EXPECTATION}'`);
        const stateObj = extensionObject();
        const layer = cockpitLayer(stateObj);
        const isCardVisible = readField(stateObj, '_isCardVisible', "the extension's visible mark");
        const visibleCardIds = [...readField(stateObj, '_visibleCardIds', "the extension's visible card ids")].sort();
        const frozenCardIds = readField(layer, '_frozenCardIds', "the layer's frozen card ids");
        const drawnCardIds = [...layer.drawnCardIds].sort();
        const cockpitClient = readField(stateObj, '_cockpitClient', "the extension's cockpit client");
        const subscriptionMarks = [
            readField(stateObj, '_isCockpitSubscriptionWanted', "the extension's subscription mark"),
            readField(cockpitClient, '_isSubscriptionWanted', "the cockpit client's subscription mark"),
        ];
        const isCovered = expect === COVERED_EXPECTATION;
        const faults = [];
        if (isCardVisible === isCovered)
            faults.push(`_isCardVisible is ${isCardVisible}`);
        const wantedVisibleIds = isCovered ? [] : drawnCardIds;
        if (JSON.stringify(visibleCardIds) !== JSON.stringify(wantedVisibleIds))
            faults.push(`the visible cards are [${visibleCardIds.join(', ')}], not [${wantedVisibleIds.join(', ')}]`);
        const wronglyFrozenIds = drawnCardIds.filter(cardId => frozenCardIds.has(cardId) !== isCovered);
        if (wronglyFrozenIds.length > 0)
            faults.push(`${wronglyFrozenIds.join(', ')} ${isCovered ? 'not frozen' : 'still frozen'}`);
        if (subscriptionMarks.some(isWanted => isWanted === isCovered))
            faults.push(`the cockpit subscription is ${isCovered ? 'still wanted' : 'not wanted'}`);
        return judged(faults, isCovered ? 'every card frozen, the subscription dropped'
            : 'every card visible and drawn, the subscription wanted');
    }

    /**
     * @param {{surface: string, name: string}} expectation - Which card, and the name its first row must show.
     * @returns {object} row-name's answer.
     */
    function judgeRowName({surface, name}) {
        const row = firstShownSessionRow(sessionsCard(extensionObject(), surface));
        const shownName = row?.nameLabel.text ?? null;
        return judged(shownName === name ? [] : [`the ${surface}'s first session row shows ${shownName}, not ${name}`],
            `the ${surface}'s first session row shows ${name}`);
    }

    /** Removes the draw watch's handlers, if one is armed. */
    function disarmDrawWatch() {
        const watch = checkState.drawWatch;
        if (watch === null)
            return;
        watch.pulseClient.removeHistoryListener(watch.historyListenerId);
        watch.cockpitClient.removeListener(watch.cockpitListenerId);
        watch.labelHandlers.forEach(([nameLabel, handlerId]) => nameLabel.disconnect(handlerId));
        checkState.drawWatch = null;
    }

    /**
     * Whether a surface's pacing has its one-shot fallback armed now: the layer's (_pacing) or the dropdown's
     * (_sessionsPacing on the top bar indicator).
     *
     * @param {object} stateObj - The extension's object.
     * @param {string} surface - LAYER_SURFACE or DROPDOWN_SURFACE.
     * @returns {boolean|null} Armed or not; null when the pacing or its fallback's id cannot be read.
     */
    function isSurfaceFallbackArmed(stateObj, surface) {
        const pacing = surface === DROPDOWN_SURFACE ? topBarIndicator(stateObj)._sessionsPacing
            : cockpitLayer(stateObj)._pacing;
        const fallbackSourceId = pacing?._fallbackSourceId;
        return fallbackSourceId === undefined ? null : fallbackSourceId !== null;
    }

    /**
     * Watches for a name drawn on a surface's sessions card: counts the Samples (a history listener added after the
     * extension's and the indicator's, so for one Sample theirs run first), notes the Sample count when the
     * sessions' change comes (a cockpit listener added after theirs), and notes, when a row's name becomes the name,
     * the Sample count and whether the change had come. It notes the shell's monotonic time of the first cockpit event
     * it sees, of the change, of the draw and of the first Sample it counts after the draw, and whether the surface's
     * pacing had its fallback armed when it was armed.
     *
     * Arming forgets the previous watch's final answer. The dropdown's card draws only while its menu is open, so a
     * closed menu could not be judged: the next Sample would draw nothing, and that would read as the pacing's fault.
     *
     * @param {{surface: string, name: string}} target - Which card, and the name to watch for.
     * @returns {object} draw-watch-arm's answer.
     * @throws {CouldNotJudgeError} When the name is shown already, or the dropdown's menu is not open.
     */
    function armDrawWatch({surface, name}) {
        disarmDrawWatch();
        checkState.drawWatchAnswer = null;
        const stateObj = extensionObject();
        if (surface === DROPDOWN_SURFACE && !topBarIndicator(stateObj).menu.isOpen)
            throw new CouldNotJudgeError('the dropdown is not open: its card is frozen and draws nothing');
        const rows = sessionRowsOf(sessionsCard(stateObj, surface));
        if (rows.some(row => row.actor.visible && row.nameLabel.text === name))
            throw new CouldNotJudgeError(`the ${surface}'s card already shows ${name}: nothing to watch`);
        const pulseClient = readField(stateObj, '_client', "the extension's pulse client");
        const cockpitClient = readField(stateObj, '_cockpitClient', "the extension's cockpit client");
        const watch = {
            name, surface, pulseClient, cockpitClient, sampleCount: 0, changeSampleCount: null, drawn: null,
            labelHandlers: [], isFallbackArmedAtArm: isSurfaceFallbackArmed(stateObj, surface), firstEventUsec: null,
            changeUsec: null,
        };
        watch.historyListenerId = pulseClient.addHistoryListener(() => {
            if (watch.drawn !== null)
                watch.drawn.nextSampleUsec ??= GLib.get_monotonic_time();
            watch.sampleCount++;
        });
        watch.cockpitListenerId = cockpitClient.addListener(event => {
            const eventUsec = GLib.get_monotonic_time();
            watch.firstEventUsec ??= eventUsec;
            const isSessionsChange = event?.type === SOURCES_EVENT_TYPE && event.names?.includes(SESSIONS_SOURCE_NAME);
            if (isSessionsChange && watch.changeSampleCount === null) {
                watch.changeSampleCount = watch.sampleCount;
                watch.changeUsec = eventUsec;
            }
        });
        for (const row of rows) {
            const handlerId = row.nameLabel.connect('notify::text', nameLabel => {
                if (nameLabel.text === name && watch.drawn === null) {
                    watch.drawn = {sampleCount: watch.sampleCount, hadChangeCome: watch.changeSampleCount !== null,
                        drawnUsec: GLib.get_monotonic_time(), nextSampleUsec: null};
                }
            });
            watch.labelHandlers.push([row.nameLabel, handlerId]);
        }
        checkState.drawWatch = watch;
        return okAnswer(`watching the ${surface}'s card for ${name}`);
    }

    /**
     * Whether a draw was the Sample's own that the watch counted after it: that Sample was counted no later than
     * SAMPLE_OWN_DRAW_MAX_GAP_MS after the draw. With no Sample counted since the draw (no time noted), it was not.
     *
     * @param {object} drawn - The watch's draw.
     * @returns {boolean} Whether the Sample counted after the draw drew it.
     */
    function isDrawnByTheSampleAfterIt(drawn) {
        const nextSampleUsec = drawn.nextSampleUsec ?? null;
        if (nextSampleUsec === null)
            return false;
        return nextSampleUsec - drawn.drawnUsec <= SAMPLE_OWN_DRAW_MAX_GAP_MS * USEC_PER_MS;
    }

    /**
     * The bad for a name drawn too soon for the fallback: the milliseconds after the sessions' change, and, when a
     * Sample was counted after the draw, the milliseconds before it.
     *
     * @param {object} watch - The armed watch, drawn after the change.
     * @param {number} earliestFallbackMs - The soonest the fallback can fire after the first cockpit event.
     * @returns {object} bad.
     */
    function drawnTooSoonAnswer(watch, earliestFallbackMs) {
        const {drawnUsec} = watch.drawn;
        const nextSampleUsec = watch.drawn.nextSampleUsec ?? null;
        const sinceChangeMs = Math.round((drawnUsec - watch.changeUsec) / USEC_PER_MS);
        let beforeNextSample = '';
        if (nextSampleUsec !== null) {
            const beforeNextSampleMs = Math.round((nextSampleUsec - drawnUsec) / USEC_PER_MS);
            beforeNextSample = `, ${beforeNextSampleMs} ms before the next Sample (more than ` +
                `${SAMPLE_OWN_DRAW_MAX_GAP_MS} ms, so not that Sample's draw)`;
        }
        return badAnswer([`${watch.name} was drawn ${sinceChangeMs} ms after the change with no Sample ` +
            `since${beforeNextSample}: sooner than the pacing's fallback can fire (${earliestFallbackMs} ms at the ` +
            'earliest), so the pacing did not draw it']);
    }

    /**
     * A name drawn after the change with no Sample counted since, or with the Sample counted after it too late to be
     * that Sample's draw (the extension draws in its own history listener, before the watch counts that Sample): no
     * Sample's draw. With the surface's pacing unreadable at the arm, or its fallback armed then, the fallback may have
     * drawn it: it could not be judged, each saying which. Sooner than the pacing's fallback can fire, counted from the
     * first cockpit event the watch saw (an event arms the fallback in the extension's listener, which runs before the
     * watch's), nothing the pacing has drew it: bad, naming the milliseconds. Otherwise the fallback drew it, with the
     * sampler silent: it could not be judged.
     *
     * @param {object} watch - The armed watch, drawn after the change.
     * @returns {object} bad or could-not-judge.
     */
    function judgeDrawnWithNoSample(watch) {
        const drawnWithNoSample = `${watch.name} was drawn with no Sample since the change`;
        const isFallbackArmedAtArm = watch.isFallbackArmedAtArm ?? null;
        if (isFallbackArmedAtArm === null) {
            const fieldPath = PACING_FALLBACK_FIELD_PATHS[watch.surface];
            return couldNotJudgeAnswer(`${drawnWithNoSample}: cannot read the ${watch.surface}'s pacing ` +
                `(${fieldPath}), so cannot tell whether its fallback drew it`);
        }
        if (isFallbackArmedAtArm) {
            return couldNotJudgeAnswer(`${drawnWithNoSample}: a fallback the ${watch.surface}'s pacing armed before ` +
                'the watch was armed may have drawn it, so the sampler is not known to be silent');
        }
        const earliestFallbackMs = COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS * MS_PER_SECOND - FALLBACK_EARLIEST_MARGIN_MS;
        const sinceFirstEventMs = (watch.drawn.drawnUsec - watch.firstEventUsec) / USEC_PER_MS;
        if (sinceFirstEventMs < earliestFallbackMs)
            return drawnTooSoonAnswer(watch, earliestFallbackMs);
        return couldNotJudgeAnswer(`${drawnWithNoSample}: the pacing's fallback timeout drew it, so the sampler was ` +
            'silent');
    }

    /**
     * A watch's final answer, once what it watches for has settled; null while it waits. Drawn with the change, or
     * after the Sample that followed it, is bad; drawn on the next Sample (counted no later than
     * SAMPLE_OWN_DRAW_MAX_GAP_MS after the draw) is ok; drawn with no Sample counted since, or with that Sample counted
     * later, is judgeDrawnWithNoSample's.
     *
     * @param {object} watch - The armed watch.
     * @returns {object|null} ok, bad or could-not-judge; null while it waits.
     */
    function finalDrawWatchAnswer(watch) {
        if (watch.drawn !== null) {
            if (!watch.drawn.hadChangeCome)
                return badAnswer([`${watch.name} was drawn before the next Sample: with the change itself`]);
            const samplesLate = watch.drawn.sampleCount - watch.changeSampleCount;
            if (samplesLate > 0)
                return badAnswer([`${watch.name} was drawn ${samplesLate} Sample(s) after the next one`]);
            if (!isDrawnByTheSampleAfterIt(watch.drawn))
                return judgeDrawnWithNoSample(watch);
            return okAnswer(`${watch.name} was drawn on the next Sample after the change`);
        }
        if (watch.changeSampleCount !== null && watch.sampleCount > watch.changeSampleCount)
            return badAnswer([`the change came and the next Sample did not draw ${watch.name}`]);
        return null;
    }

    /**
     * Reads the draw watch. Its final answer disarms it and is kept, and given again on every read until the watch is
     * armed again: the harness asks again after a bad.
     *
     * @returns {object} draw-watch-read's answer: ok, bad, could-not-judge, or pending until the change and a Sample
     *     came.
     */
    function readDrawWatch() {
        const watch = checkState.drawWatch;
        if (watch === null) {
            const keptAnswer = checkState.drawWatchAnswer ?? null;
            if (keptAnswer === null)
                throw new CouldNotJudgeError('nothing is watched: draw-watch-arm comes first');
            return keptAnswer;
        }
        const finalAnswer = finalDrawWatchAnswer(watch);
        if (finalAnswer === null) {
            return pendingAnswer(watch.changeSampleCount === null ? 'no change to the sessions has come yet'
                : 'the change came; no Sample since');
        }
        disarmDrawWatch();
        checkState.drawWatchAnswer = finalAnswer;
        return finalAnswer;
    }

    /**
     * @param {{cardId: string, expect: string}} expectation - The card, and STALE_EXPECTATION or FRESH_EXPECTATION.
     * @returns {object} stale-card's answer.
     */
    function judgeStaleCard({cardId, expect}) {
        if (expect !== STALE_EXPECTATION && expect !== FRESH_EXPECTATION)
            throw new CouldNotJudgeError(`stale-card expects '${STALE_EXPECTATION}' or '${FRESH_EXPECTATION}'`);
        const card = layerCard(cockpitLayer(extensionObject()), cardId);
        const noDataLabel = readField(card, '_noDataLabel', "the card's no-data line");
        const contentBox = readField(card, '_contentBox', "the card's rows");
        const isStaleShown = noDataLabel.visible && noDataLabel.text.startsWith(NO_DATA_SINCE_PREFIX);
        if (expect === STALE_EXPECTATION) {
            return judged(isStaleShown ? [] : [`the ${cardId} card shows no '${NO_DATA_SINCE_PREFIX}…' line`],
                `the ${cardId} card reads '${noDataLabel.text}'`);
        }
        const isFresh = !noDataLabel.visible && contentBox.visible;
        return judged(isFresh ? [] : [`the ${cardId} card does not show its rows (it reads '${noDataLabel.text}')`],
            `the ${cardId} card shows its rows again`);
    }

    /** @returns {object} dropdown-order's answer. */
    function judgeDropdownOrder() {
        const stateObj = extensionObject();
        const indicator = topBarIndicator(stateObj);
        const sessionsItem = readField(indicator, '_sessionsItem', "the dropdown's sessions item");
        if (sessionsItem === null)
            return badAnswer(['the dropdown has no sessions item']);
        const cockpitState = readField(stateObj, '_cockpitClient', "the extension's cockpit client").state;
        if (cockpitState !== COCKPIT_LIVE_STATE)
            throw new CouldNotJudgeError(`the cockpit is ${cockpitState}, not ${COCKPIT_LIVE_STATE}`);
        const menuItems = indicator.menu._getMenuItems();
        const dropdownCard = readField(indicator, '_dropdownCard', "the dropdown's system card");
        const openResourcesItem = readField(indicator, '_openResourcesItem', 'the "Open Resources" item');
        const faults = [];
        if (dropdownCard?.get_parent() !== menuItems[CARD_ITEM_INDEX])
            faults.push("the menu's first item is not the system card's");
        if (menuItems[SESSIONS_ITEM_INDEX] !== sessionsItem)
            faults.push(`the sessions item is item ${menuItems.indexOf(sessionsItem)}, not ${SESSIONS_ITEM_INDEX}`);
        if (menuItems[OPEN_RESOURCES_ITEM_INDEX] !== openResourcesItem)
            faults.push(`"Open Resources" is not item ${OPEN_RESOURCES_ITEM_INDEX}`);
        if (!sessionsItem.visible)
            faults.push('the sessions item is hidden while the cockpit is live');
        return judged(faults, 'the sessions item second, under the card and above "Open Resources", shown');
    }

    /**
     * Opens or closes the dropdown. Opening with names also judges, in this same request, that the sessions card shows
     * them at once: the open draws the card synchronously, so "the rows at once" is read before anything else runs.
     *
     * @param {boolean} isOpening - True to open the dropdown, false to close it.
     * @param {{names?: string[]}} [expectation] - The names the open card's rows must show at once, in order.
     * @returns {object} dropdown-open's or dropdown-close's answer.
     * @throws {CouldNotJudgeError} When names is given and is not a list.
     */
    function setDropdownOpen(isOpening, {names} = {}) {
        if (names !== undefined && !Array.isArray(names))
            throw new CouldNotJudgeError('dropdown-open takes names as a list');
        const stateObj = extensionObject();
        const menu = topBarIndicator(stateObj).menu;
        if (isOpening)
            menu.open(false);
        else
            menu.close(false);
        const wantedState = isOpening ? 'open' : 'closed';
        const faults = menu.isOpen === isOpening ? [] : [`the dropdown is not ${wantedState}`];
        if (isOpening && names !== undefined) {
            const shownNames = sessionRowsOf(sessionsCard(stateObj, DROPDOWN_SURFACE)).filter(row => row.actor.visible)
                .map(row => row.nameLabel.text);
            if (JSON.stringify(shownNames) !== JSON.stringify(names))
                faults.push(`at the open, the rows show ${shownNames.join(', ')}, not ${names.join(', ')}`);
        }
        return judged(faults, `the dropdown is ${wantedState}`);
    }

    /**
     * @param {{names: string[]}} expectation - The names the open card's rows must show, in order.
     * @returns {object} dropdown-card's answer.
     */
    function judgeDropdownCard({names}) {
        const stateObj = extensionObject();
        const indicator = topBarIndicator(stateObj);
        const card = sessionsCard(stateObj, DROPDOWN_SURFACE);
        const faults = [];
        if (!indicator.menu.isOpen)
            throw new CouldNotJudgeError('the dropdown is not open');
        if (readField(card, '_isFrozen', "the card's frozen mark"))
            faults.push('the sessions card is frozen while the menu is open');
        const shownRows = sessionRowsOf(card).filter(row => row.actor.visible);
        const shownNames = shownRows.map(row => row.nameLabel.text);
        if (JSON.stringify(shownNames) !== JSON.stringify(names))
            faults.push(`the rows show ${shownNames.join(', ')}, not ${names.join(', ')}`);
        const systemCardWidth = readField(indicator, '_dropdownCard', "the dropdown's system card").width;
        if (Math.abs(card.width - systemCardWidth) > POSITION_TOLERANCE_PX)
            faults.push(`the sessions card is ${card.width} px wide, the system card ${systemCardWidth} px`);
        const zeroBarNames = shownRows.filter(row => !(row.bar.width > 0 && row.barTrack.width > 0))
            .map(row => row.nameLabel.text);
        if (zeroBarNames.length > 0)
            faults.push(`the bars of ${zeroBarNames.join(', ')} are zero wide`);
        if (card.get_offscreen_redirect() !== Clutter.OffscreenRedirect.ALWAYS)
            faults.push('the sessions card does not draw through its own texture');
        if (card.get_parent() !== indicator._sessionsItem)
            faults.push('the sessions card is not inside its menu item');
        return judged(faults, `the open card shows ${names.join(', ')}, as wide as the system card`);
    }

    /** @returns {object} dropdown-closed's answer. */
    function judgeDropdownClosed() {
        const stateObj = extensionObject();
        const indicator = topBarIndicator(stateObj);
        const card = sessionsCard(stateObj, DROPDOWN_SURFACE);
        const faults = [];
        if (indicator.menu.isOpen)
            faults.push('the dropdown is still open');
        if (!readField(card, '_isFrozen', "the card's frozen mark"))
            faults.push('the sessions card is not frozen while the menu is closed');
        if (readField(surfaceTooltip(stateObj, DROPDOWN_SURFACE), '_isShown', "the tooltip's shown mark"))
            faults.push("the dropdown's tooltip is still shown");
        return judged(faults, 'closed: the card frozen, its tooltip hidden');
    }

    /**
     * Waits until a condition holds, looking every STATE_POLL_INTERVAL_MS, at most timeoutMs.
     *
     * @param {function(): boolean} condition - What to wait for.
     * @param {number} timeoutMs - How long at most.
     * @returns {Promise<boolean>} Whether it held in time.
     */
    function waitUntil(condition, timeoutMs) {
        return new Promise(resolve => {
            let waitedMs = 0;
            const look = () => {
                if (condition()) {
                    resolve(true);
                    return GLib.SOURCE_REMOVE;
                }
                waitedMs += STATE_POLL_INTERVAL_MS;
                if (waitedMs > timeoutMs) {
                    resolve(false);
                    return GLib.SOURCE_REMOVE;
                }
                return GLib.SOURCE_CONTINUE;
            };
            if (!condition())
                GLib.timeout_add(GLib.PRIORITY_DEFAULT, STATE_POLL_INTERVAL_MS, look);
            else
                resolve(true);
        });
    }

    /**
     * The lock path: disables the extension, then judges that nothing of it is left in the shell; enables it, and
     * judges at the moment it becomes ACTIVE (inside the state-changed signal, before any D-Bus answer can be read)
     * that the grid is already back, from the layout kept at disable(), and that its parts are new objects.
     *
     * @param {{timeoutMs?: number}} limits - How long each wait may take.
     * @returns {Promise<object>} lock-path's answer.
     */
    async function judgeLockPath({timeoutMs = DEFAULT_LOCK_PATH_TIMEOUT_MS}) {
        const extension = Main.extensionManager.lookup(EXTENSION_UUID);
        const stateObj = extensionObject();
        const extensionStates = ExtensionUtils.ExtensionState;
        const oldParts = {
            layer: cockpitLayer(stateObj), card: readField(stateObj, '_card', "the extension's v2 card"),
            client: readField(stateObj, '_client', "the extension's pulse client"),
            indicator: topBarIndicator(stateObj),
        };
        const oldDrawnCardIds = [...oldParts.layer.drawnCardIds].sort();
        const faults = [];
        Main.extensionManager.disableExtension(EXTENSION_UUID);
        if (!await waitUntil(() => extension.state === extensionStates.INACTIVE, timeoutMs))
            throw new CouldNotJudgeError(`the extension did not become INACTIVE within ${timeoutMs} ms`);
        const leftBehind = actorsWithStyleClasses(global.stage, LEFT_BEHIND_STYLE_CLASSES);
        if (leftBehind.length > 0)
            faults.push(`after disable, ${leftBehind.length} actors of the extension are left in the stage`);
        if (stateObj._layer !== null)
            faults.push('after disable, the extension still holds a layer');
        let activation = null;
        const stateChangedId = Main.extensionManager.connect('extension-state-changed', (_manager, changed) => {
            if (changed.uuid === EXTENSION_UUID && changed.state === extensionStates.ACTIVE && activation === null)
                activation = {layer: stateObj._layer, drawnCardIds: stateObj._layer?.drawnCardIds ?? null};
        });
        try {
            Main.extensionManager.enableExtension(EXTENSION_UUID);
            if (!await waitUntil(() => activation !== null, timeoutMs))
                throw new CouldNotJudgeError(`the extension did not become ACTIVE within ${timeoutMs} ms`);
        } finally {
            Main.extensionManager.disconnect(stateChangedId);
        }
        if (activation.layer === null)
            faults.push('the grid is not back at once: no layer when the extension became ACTIVE');
        else if (JSON.stringify([...activation.drawnCardIds].sort()) !== JSON.stringify(oldDrawnCardIds))
            faults.push(`back at once with ${activation.drawnCardIds.join(', ')}, not ${oldDrawnCardIds.join(', ')}`);
        const newParts = {layer: stateObj._layer, card: stateObj._card, client: stateObj._client,
            indicator: stateObj._indicator};
        const reusedPartNames = Object.keys(oldParts).filter(partName => newParts[partName] === oldParts[partName]);
        if (reusedPartNames.length > 0)
            faults.push(`after enable, ${reusedPartNames.join(', ')} are the old objects`);
        const layerActors = Main.layoutManager._backgroundGroup.get_children()
            .filter(actor => actor.has_style_class_name?.(LAYER_STYLE_CLASS));
        if (layerActors.length !== 1 || layerActors[0] !== newParts.layer)
            faults.push(`after enable the background group holds ${layerActors.length} layers, not the new one alone`);
        return judged(faults, 'nothing left after disable; new parts and the grid back at once after enable');
    }

    /** @type {Object<string, function(object): (object|Promise<object>)>} Each request's handler, by name. */
    const HANDLERS_BY_REQUEST = {
        'extension-active': judgeExtensionActive,
        'layer-placement': judgeLayerPlacement,
        'grid-geometry': judgeGridGeometry,
        'layer-interactive': judgeLayerInteractive,
        'session-row-point': sessionRowPoint,
        'tooltip-shown': judgeTooltipShown,
        'tooltip-hidden': judgeTooltipHidden,
        'window-count': () => okAnswer(`${normalWindows().length} normal windows`, {count: normalWindows().length}),
        'window-shown': judgeWindowShown,
        'place-window-clear': placeWindowClear,
        'window-clear': judgeWindowClear,
        'activate-window': ({pid}) => {
            Main.activateWindow(windowOfPid(pid));
            return okAnswer(`activated pid ${pid}'s window`);
        },
        'focused-window': judgeFocusedWindow,
        'minimize-all': minimizeAll,
        'maximize-window': ({pid}) => {
            const window = windowOfPid(pid);
            window.unminimize();
            // Mutter 50.1's meta_window_maximize takes no flags (Meta-18.typelib): an argument would only make GJS log
            // "Too many arguments" into the log the check judges.
            window.maximize();
            return okAnswer(`maximized pid ${pid}'s window`);
        },
        'minimize-window': ({pid}) => {
            windowOfPid(pid).minimize();
            return okAnswer(`minimized pid ${pid}'s window`);
        },
        'remember-windows': () => {
            checkState.rememberedWindows = windowsSnapshot();
            return okAnswer('remembered the focus and the minimized windows');
        },
        'windows-unchanged': judgeWindowsUnchanged,
        'focus-calls-arm': armFocusCount,
        'focus-calls-read': readFocusCount,
        'cover-state': judgeCoverState,
        'row-name': judgeRowName,
        'draw-watch-arm': armDrawWatch,
        'draw-watch-read': readDrawWatch,
        'stale-card': judgeStaleCard,
        'dropdown-order': judgeDropdownOrder,
        'dropdown-open': expectation => setDropdownOpen(true, expectation),
        'dropdown-close': () => setDropdownOpen(false),
        'dropdown-card': judgeDropdownCard,
        'dropdown-closed': judgeDropdownClosed,
        'lock-path': judgeLockPath,
        'monotonic-time': () => okAnswer("the shell's monotonic clock", {monotonicUsec: GLib.get_monotonic_time()}),
    };

    /**
     * Turns a failure into the answer it stands for: a MissingPartError is bad, a CouldNotJudgeError could-not-judge;
     * anything else is rethrown, so Eval reports it as a failure (the harness makes that exit 2 too).
     *
     * @param {Error} error - What the handler threw.
     * @returns {object} The answer.
     */
    function answerForFailure(error) {
        if (error instanceof MissingPartError)
            return badAnswer([error.message]);
        if (error instanceof CouldNotJudgeError)
            return {verdict: COULD_NOT_JUDGE_VERDICT, detail: error.message};
        throw error;
    }

    const handler = HANDLERS_BY_REQUEST[request];
    if (!handler)
        return {verdict: COULD_NOT_JUDGE_VERDICT, detail: `unknown request '${request}'`};
    try {
        const answer = handler(options ?? {});
        return answer instanceof Promise ? answer.catch(answerForFailure) : answer;
    } catch (error) {
        return answerForFailure(error);
    }
}
