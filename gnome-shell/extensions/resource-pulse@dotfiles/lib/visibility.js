// The pure decisions behind the desktop card's covered check (extension.js): which windows can cover the card, whether
// one does, when a timer must re-check it, and when that timer must repaint the frozen card. The card sits above the
// wallpaper and below every window, so a window hides it most of the day; while one does, the extension freezes the
// card (dimmed, repainted only every FROZEN_REPAINT_INTERVAL_SECONDS) and releases the detail watch.
//
// Rectangles are {x, y, width, height} in stage (logical) pixels: a window's frame rect and the card's placed position
// both are, under fractional scaling too, so they are compared directly. Pure: no Shell, St, Clutter or Meta import,
// so it runs under plain gjs.
import {FROZEN_REPAINT_INTERVAL_SECONDS} from './constants.js';

const USEC_PER_SECOND = 1_000_000;
const FROZEN_REPAINT_INTERVAL_USEC = FROZEN_REPAINT_INTERVAL_SECONDS * USEC_PER_SECOND;

/**
 * @typedef {object} Rect
 * @property {number} x - Left edge.
 * @property {number} y - Top edge.
 * @property {number} width - Width; zero or less is no area.
 * @property {number} height - Height; zero or less is no area.
 */

/**
 * Says whether a rectangle has any area.
 *
 * @param {Rect} rect - The rectangle.
 * @returns {boolean} True when it is wider and taller than zero.
 */
function hasArea(rect) {
    return rect.width > 0 && rect.height > 0;
}

/**
 * Says whether one rectangle contains the whole of another, edges included: a window exactly the card's size and
 * place contains it.
 *
 * @param {Rect} outerRect - The containing rectangle (a window).
 * @param {Rect} innerRect - The contained one (the card).
 * @returns {boolean} True when no part of innerRect lies outside outerRect.
 */
function rectContains(outerRect, innerRect) {
    const isInsideHorizontally = outerRect.x <= innerRect.x &&
        outerRect.x + outerRect.width >= innerRect.x + innerRect.width;
    const isInsideVertically = outerRect.y <= innerRect.y &&
        outerRect.y + outerRect.height >= innerRect.y + innerRect.height;
    return isInsideHorizontally && isInsideVertically;
}

/**
 * Says whether two rectangles share some area. Rectangles that only touch, along an edge or at a corner, do not, and
 * neither does one with no area.
 *
 * @param {Rect} firstRect - One rectangle (a window's frame).
 * @param {Rect} secondRect - The other (the primary monitor).
 * @returns {boolean} True when they overlap.
 */
export function doRectsOverlap(firstRect, secondRect) {
    if (!hasArea(firstRect) || !hasArea(secondRect))
        return false;
    const isOverlappingHorizontally = firstRect.x < secondRect.x + secondRect.width &&
        secondRect.x < firstRect.x + firstRect.width;
    const isOverlappingVertically = firstRect.y < secondRect.y + secondRect.height &&
        secondRect.y < firstRect.y + firstRect.height;
    return isOverlappingHorizontally && isOverlappingVertically;
}

/**
 * Says whether the card is fully covered: true only when ONE window's rectangle contains the whole card, edges
 * included. A card partly covered, or covered only by several windows together, counts as visible: the safe
 * direction, since it keeps painting a card nobody may see rather than freezing one somebody can. A card with no area
 * yet (not sized) is never covered.
 *
 * @param {Rect} cardRect - The card.
 * @param {Rect[]} windowRects - The frames of the windows that can cover it (canWindowCoverCard).
 * @returns {boolean} True when one of them contains the card.
 */
export function isRectFullyCovered(cardRect, windowRects) {
    if (!hasArea(cardRect))
        return false;
    return windowRects.some(windowRect => rectContains(windowRect, cardRect));
}

/** What the cover re-check timer must do (coverRecheckTimerChange). */
export const CoverRecheckTimerChange = Object.freeze({START: 'start', STOP: 'stop', NONE: 'none'});

/**
 * Says whether a window's state lets it cover the card: an ordinary window or a dialog (so never ding's desktop
 * window, which spans the whole screen, nor a dock or a popup), not minimized, showing (not hidden by "show desktop"),
 * and on the active workspace or on all of them. Only such a window's frame is read, and it counts when that frame
 * overlaps the primary monitor, which the card is on (doRectsOverlap).
 *
 * @param {object} windowState - What the Shell glue read from the window.
 * @param {boolean} windowState.isNormalOrDialog - Its type is Meta.WindowType.NORMAL or DIALOG.
 * @param {boolean} windowState.isMinimized - It is minimized.
 * @param {boolean} windowState.isShowing - It shows on its workspace (showing_on_its_workspace()).
 * @param {boolean} windowState.isOnActiveWorkspace - It is on the active workspace, or on every workspace.
 * @returns {boolean} True when it can cover the card.
 */
export function canWindowCoverCard({isNormalOrDialog, isMinimized, isShowing, isOnActiveWorkspace}) {
    return Boolean(isNormalOrDialog && !isMinimized && isShowing && isOnActiveWorkspace);
}

/**
 * What the timer that re-checks a frozen card's cover must do. While the card is covered nothing else may come to
 * re-check it (no Sample comes while the service is down, and no signal reports, for example, a window moved from the
 * keyboard), so a timer runs exactly while it is covered.
 *
 * @param {object} state - The cover and the timer.
 * @param {boolean} state.isCovered - The card is covered now.
 * @param {boolean} state.isTimerRunning - The timer is running.
 * @returns {string} CoverRecheckTimerChange.START when covered with no timer, STOP when revealed with one, else NONE.
 */
export function coverRecheckTimerChange({isCovered, isTimerRunning}) {
    if (isCovered && !isTimerRunning)
        return CoverRecheckTimerChange.START;
    if (!isCovered && isTimerRunning)
        return CoverRecheckTimerChange.STOP;
    return CoverRecheckTimerChange.NONE;
}

/**
 * Says whether the cover re-check timer must repaint the frozen card now: FROZEN_REPAINT_INTERVAL_SECONDS have passed
 * since the card was last painted while frozen, by the freeze itself or by the timer's previous repaint. A card
 * misjudged as covered then shows the client's latest numbers, dimmed, at most that old, never stale ones silently.
 *
 * @param {object} times - Monotonic clock readings, in microseconds.
 * @param {number} times.lastFrozenPaintAtUsec - When the frozen card was last painted.
 * @param {number} times.nowUsec - Now.
 * @returns {boolean} True from FROZEN_REPAINT_INTERVAL_SECONDS after that paint on, never before.
 */
export function isFrozenRepaintDue({lastFrozenPaintAtUsec, nowUsec}) {
    return nowUsec - lastFrozenPaintAtUsec >= FROZEN_REPAINT_INTERVAL_USEC;
}

/**
 * Says whether the card is covered: a fullscreen window fills the primary monitor, or one window contains the whole
 * card (isRectFullyCovered).
 *
 * @param {object} surroundings - What the Shell glue read.
 * @param {boolean} surroundings.isPrimaryMonitorInFullscreen - The primary monitor is fullscreen.
 * @param {Rect} surroundings.cardRect - The card.
 * @param {Rect[]} surroundings.windowRects - The frames of the windows that can cover it.
 * @returns {boolean} True when covered.
 */
export function isCardCovered({isPrimaryMonitorInFullscreen, cardRect, windowRects}) {
    return isPrimaryMonitorInFullscreen === true || isRectFullyCovered(cardRect, windowRects);
}
