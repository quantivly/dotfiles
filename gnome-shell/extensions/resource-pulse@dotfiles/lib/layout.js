/**
 * Places the desktop card at the top-right of a work area.
 *
 * @param {{x: number, y: number, width: number, height: number}} workArea - Monitor work area, in pixels.
 * @param {number} cardWidthPx - Card width in pixels.
 * @param {number} marginPx - Inset from the work area's top and right edges, in pixels.
 * @returns {{x: number, y: number}} Card origin; x never falls left of the work area.
 */
export function cardPosition(workArea, cardWidthPx, marginPx) {
    const rightAlignedX = workArea.x + workArea.width - cardWidthPx - marginPx;
    return {x: Math.max(workArea.x, rightAlignedX), y: workArea.y + marginPx};
}
