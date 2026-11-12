// Test tooling for scripts/resource-pulse-nested.sh `pointer` (and `check cockpit`, which moves and clicks through it),
// never loaded by the extension. The harness sends this file's text to the NESTED shell's Eval, followed by one call of
// resourcePulseNestedPointer('<request>', <options as JSON>), and reads the JSON of its answer. Under plain gjs the
// same text runs against a fake shell, with rows (gnome-shell/tests/cockpitCheck.test.js).
//
// It drives a Clutter virtual pointer device of the nested shell's own seat
// (global.backend.get_default_seat().create_virtual_device(POINTER_DEVICE)), made once and kept for the life of the
// nested shell in globalThis.__resourcePulseNestedPointer, at logical (stage) coordinates. The events it sends are
// queued; the shell handles them after this Eval returns, so a move is confirmed by a later `at`, never by itself.
//
// Requests: 'move' {x, y}; 'click' {x, y, clickCount} (a move, then clickCount presses and releases of the primary
// button, sent together, so the shell sees them before it answers anything they start); 'at' {x, y} (the pointer is
// there, to a pixel). Answers {verdict: 'ok'|'bad'|'could-not-judge', detail, x?, y?}: could-not-judge for a point
// off the stage, a click count that is not 1 or 2, or a seat that makes no virtual pointer.

/**
 * Moves the nested shell's virtual pointer, clicks with it, or says where the pointer is.
 *
 * @param {string} request - 'move', 'click' or 'at'.
 * @param {{x: number, y: number, clickCount?: number}} [options] - The point, in stage pixels, and the clicks.
 * @returns {object} The answer: {verdict, detail, x?, y?}.
 */
function resourcePulseNestedPointer(request, options = {}) {
    const POINTER_STATE_KEY = '__resourcePulseNestedPointer';
    const POSITION_TOLERANCE_PX = 1;
    const MAX_CLICK_COUNT = 2;
    const Clutter = imports.gi.Clutter;

    globalThis[POINTER_STATE_KEY] ??= {virtualPointer: null};
    const pointerState = globalThis[POINTER_STATE_KEY];
    const okAnswer = (detail, data = {}) => ({verdict: 'ok', detail, ...data});
    const couldNotJudge = detail => ({verdict: 'could-not-judge', detail});

    /**
     * @returns {object|null} The virtual pointer device, made on first use; null when the seat makes none.
     */
    function virtualPointer() {
        if (pointerState.virtualPointer === null) {
            const seat = global.backend?.get_default_seat?.() ?? null;
            pointerState.virtualPointer =
                seat?.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE) ?? null;
        }
        return pointerState.virtualPointer;
    }

    /**
     * @param {{x: number, y: number}} point - A point.
     * @returns {string|null} Why it is not a point on the stage, or null when it is.
     */
    function offStageReason({x, y}) {
        const isOnStage = Number.isFinite(x) && Number.isFinite(y) && x >= 0 && y >= 0 &&
            x < global.stage.width && y < global.stage.height;
        return isOnStage ? null : `(${x}, ${y}) is not a point of the ${global.stage.width}x${global.stage.height} stage`;
    }

    /**
     * Sends a move, then the clicks, to the virtual pointer.
     *
     * @param {{x: number, y: number}} point - Where to.
     * @param {number} clickCount - How many primary clicks after the move (0 for none).
     * @returns {object} The answer.
     */
    function moveAndClick({x, y}, clickCount) {
        const offStage = offStageReason({x, y});
        if (offStage !== null)
            return couldNotJudge(offStage);
        const device = virtualPointer();
        if (device === null)
            return couldNotJudge("the nested shell's seat made no virtual pointer");
        device.notify_absolute_motion(GLib.get_monotonic_time(), x, y);
        for (let clickIndex = 0; clickIndex < clickCount; clickIndex++) {
            device.notify_button(GLib.get_monotonic_time(), Clutter.BUTTON_PRIMARY, Clutter.ButtonState.PRESSED);
            device.notify_button(GLib.get_monotonic_time(), Clutter.BUTTON_PRIMARY, Clutter.ButtonState.RELEASED);
        }
        const clickText = clickCount === 0 ? '' : `, then ${clickCount} click(s)`;
        return okAnswer(`sent a move to (${x}, ${y})${clickText}`, {x, y});
    }

    /**
     * @param {{x: number, y: number}} point - Where the pointer should be.
     * @returns {object} at's answer, with where it is.
     */
    function judgePointerAt({x, y}) {
        const [pointerX, pointerY] = global.get_pointer();
        const isThere = Math.abs(pointerX - x) <= POSITION_TOLERANCE_PX && Math.abs(pointerY - y) <= POSITION_TOLERANCE_PX;
        if (!isThere)
            return {verdict: 'bad', detail: `the pointer is at (${pointerX}, ${pointerY}), not (${x}, ${y})`};
        return okAnswer(`the pointer is at (${pointerX}, ${pointerY})`, {x: pointerX, y: pointerY});
    }

    const point = {x: options?.x, y: options?.y};
    switch (request) {
    case 'move':
        return moveAndClick(point, 0);
    case 'click': {
        const clickCount = options?.clickCount ?? 1;
        if (!Number.isInteger(clickCount) || clickCount < 1 || clickCount > MAX_CLICK_COUNT)
            return couldNotJudge(`a click count is 1 to ${MAX_CLICK_COUNT}, got ${clickCount}`);
        return moveAndClick(point, clickCount);
    }
    case 'at':
        return judgePointerAt(point);
    default:
        return couldNotJudge(`unknown request '${request}': move, click or at`);
    }
}
