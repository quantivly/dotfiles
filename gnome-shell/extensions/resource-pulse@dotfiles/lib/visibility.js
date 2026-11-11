// The pure decisions behind the desktop card's covered check (extension.js): which windows can cover the card, whether
// one does and which ones do, how the windows it follows change, on which Sample a covered card is checked again
// (the backstop), when the fallback timeout runs (only while the card is covered and the service is silent), and when
// the frozen card is repainted. The card sits above the wallpaper and below every window, so a window hides it most of
// the day; while one does, the extension freezes the card (dimmed, repainted only every
// FROZEN_REPAINT_INTERVAL_SECONDS) and releases the detail watch.
//
// Rectangles are {x, y, width, height} in stage (logical) pixels: a window's frame rect and the card's placed position
// both are, under fractional scaling too, so they are compared directly. Pure: no Shell, St, Clutter or Meta import,
// so it runs under plain gjs.
import {COVER_BACKSTOP_TICKS, FROZEN_REPAINT_INTERVAL_SECONDS} from './constants.js';

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
 * Which rectangles contain the whole card, edges included: the windows that cover it, which the extension follows
 * (their moves, resizes and closing) while the card is covered. A card with no area yet (not sized) has none.
 *
 * @param {object} layout - The card and the windows.
 * @param {Rect} layout.cardRect - The card.
 * @param {Rect[]} layout.windowRects - The frames of the windows that can cover it (canWindowCoverCard).
 * @returns {number[]} The indexes in windowRects of those that contain the card, in order.
 */
export function indexesOfRectsCoveringCard({cardRect, windowRects}) {
    if (!hasArea(cardRect))
        return [];
    return windowRects.flatMap((windowRect, windowIndex) => (rectContains(windowRect, cardRect) ? [windowIndex] : []));
}

/**
 * Says whether the card is fully covered: true only when ONE window's rectangle contains the whole card, edges
 * included (indexesOfRectsCoveringCard finds at least one). A card partly covered, or covered only by several windows
 * together, counts as visible: the safe direction, since it keeps painting a card nobody may see rather than freezing
 * one somebody can. A card with no area yet (not sized) is never covered.
 *
 * @param {Rect} cardRect - The card.
 * @param {Rect[]} windowRects - The frames of the windows that can cover it (canWindowCoverCard).
 * @returns {boolean} True when one of them contains the card.
 */
export function isRectFullyCovered(cardRect, windowRects) {
    return indexesOfRectsCoveringCard({cardRect, windowRects}).length > 0;
}

/**
 * How the windows the extension follows must change for a new covering set: follow those it does not hold yet,
 * release those that no longer cover the card, and touch none of the rest, so a cover check that finds the same
 * windows connects and disconnects nothing. Windows are compared by identity (the extension's are Meta.Window
 * objects; anything works here).
 *
 * @param {object} windows - The windows held and the ones covering the card now.
 * @param {object[]} windows.heldWindows - The windows followed now.
 * @param {object[]} windows.coveringWindows - The windows that cover the card now.
 * @returns {{windowsToFollow: object[], windowsToRelease: object[]}} The windows to connect to and to disconnect
 *     from.
 */
export function coveringWindowChanges({heldWindows, coveringWindows}) {
    const heldWindowSet = new Set(heldWindows);
    const coveringWindowSet = new Set(coveringWindows);
    return {
        windowsToFollow: [...coveringWindowSet].filter(coveringWindow => !heldWindowSet.has(coveringWindow)),
        windowsToRelease: [...heldWindowSet].filter(heldWindow => !coveringWindowSet.has(heldWindow)),
    };
}

/**
 * Says whether a Sample must check the cover at once (the cover backstop). A visible card is checked on every Sample,
 * so a window moved over it from the keyboard, which no signal reports, is seen within a tick. A covered card is
 * checked on its windows' signals instead, and by a Sample only once COVER_BACKSTOP_TICKS have passed since its last
 * check: a backstop for what no signal reports.
 *
 * @param {object} state - The cover and the count.
 * @param {boolean} state.isCovered - The card is covered now.
 * @param {number} state.ticksSinceCoverCheck - Samples (history notifications) since the cover was last checked,
 *     this one included.
 * @returns {boolean} True when this Sample must check the cover.
 */
export function isCoverBackstopDue({isCovered, ticksSinceCoverCheck}) {
    return !isCovered || ticksSinceCoverCheck >= COVER_BACKSTOP_TICKS;
}

/** What the cover fallback timeout must do (coverFallbackTimerChange). */
export const CoverFallbackTimerChange = Object.freeze({START: 'start', STOP: 'stop', NONE: 'none'});

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
 * What the cover fallback timeout must do. A covered card is checked again by its windows' signals and by the
 * Samples' backstop (isCoverBackstopDue), but with the service silent no Sample comes, so the timeout runs exactly
 * while the card is covered and the service is not live: the stall watchdog's no data starts it, and the next Sample
 * (live again) or the reveal stops it. It never runs while Samples flow.
 *
 * @param {object} state - The cover, the service and the timeout.
 * @param {boolean} state.isCovered - The card is covered now.
 * @param {boolean} state.isServiceLive - The client is drawing the service's Samples (PulseClient isLive).
 * @param {boolean} state.isTimerRunning - The timeout is running.
 * @returns {string} CoverFallbackTimerChange.START when covered, not live and not running; STOP when running and the
 *     card is visible or the service live; else NONE.
 */
export function coverFallbackTimerChange({isCovered, isServiceLive, isTimerRunning}) {
    const isTimerWanted = isCovered && !isServiceLive;
    if (isTimerWanted && !isTimerRunning)
        return CoverFallbackTimerChange.START;
    if (!isTimerWanted && isTimerRunning)
        return CoverFallbackTimerChange.STOP;
    return CoverFallbackTimerChange.NONE;
}

/**
 * Says whether the frozen card must be repainted now: FROZEN_REPAINT_INTERVAL_SECONDS have passed since it was last
 * painted while frozen, by the freeze itself or by the previous frozen repaint. Asked on every Sample while the card is
 * covered, and by the fallback timeout while the service is silent. A card misjudged as covered then shows the
 * client's latest numbers, dimmed, at most that old, never stale ones silently.
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
