// The pure decisions behind the desktop card's covered check (extension.js): which windows can cover the card, and
// whether one does. The card sits above the wallpaper and below every window, so a window hides it most of the day;
// while one does, the extension stops repainting the card and releases the detail watch.
//
// Rectangles are {x, y, width, height} in stage (logical) pixels: a window's frame rect and the card's placed position
// both are, under fractional scaling too, so they are compared directly. Pure: no Shell, St, Clutter or Meta import,
// so it runs under plain gjs.

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
 * @param {Rect[]} windowRects - The frames of the windows that can cover it (windowCountsForCover).
 * @returns {boolean} True when one of them contains the card.
 */
export function isRectFullyCovered(cardRect, windowRects) {
    if (!hasArea(cardRect))
        return false;
    return windowRects.some(windowRect => rectContains(windowRect, cardRect));
}

/**
 * Says whether a window can cover the card: an ordinary window or a dialog (so never ding's desktop window, which spans
 * the whole screen, nor a dock or a popup), not minimized, showing (not hidden by "show desktop"), on the active
 * workspace or on all of them, and over the primary monitor, which the card is on.
 *
 * @param {object} window - What the Shell glue read from the window.
 * @param {boolean} window.isNormalOrDialog - Its type is Meta.WindowType.NORMAL or DIALOG.
 * @param {boolean} window.isMinimized - It is minimized.
 * @param {boolean} window.isShowing - It shows on its workspace (showing_on_its_workspace()).
 * @param {boolean} window.isOnActiveWorkspace - It is on the active workspace, or on every workspace.
 * @param {boolean} window.overlapsPrimaryMonitor - Its frame overlaps the primary monitor (doRectsOverlap).
 * @returns {boolean} True when it counts.
 */
export function windowCountsForCover({
    isNormalOrDialog, isMinimized, isShowing, isOnActiveWorkspace, overlapsPrimaryMonitor,
}) {
    return Boolean(isNormalOrDialog && !isMinimized && isShowing && isOnActiveWorkspace && overlapsPrimaryMonitor);
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
