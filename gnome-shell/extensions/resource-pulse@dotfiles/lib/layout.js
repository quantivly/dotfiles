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

/**
 * Places the top-bar hover label: centred below the indicator and kept inside the indicator's own monitor, as the
 * dock keeps its labels (not inside the whole stage, which spans every monitor), at whole pixels.
 *
 * @param {{x: number, y: number, width: number, height: number}} indicatorRect - The indicator's stage position
 *     and size, in pixels.
 * @param {number} labelWidthPx - The label's width for the text it is about to show, in pixels.
 * @param {number} gapPx - Space between the indicator's bottom edge and the label's top, in pixels.
 * @param {{x: number, width: number}} monitorRect - The indicator's monitor, in stage pixels.
 * @returns {{x: number, y: number}} The label's origin: x never left of the monitor, and never so far right that
 *     the label crosses the monitor's right edge, unless the label is wider than the monitor (then it starts at
 *     the monitor's left edge).
 */
export function hoverLabelPosition(indicatorRect, labelWidthPx, gapPx, monitorRect) {
    const centredX = indicatorRect.x + (indicatorRect.width - labelWidthPx) / 2;
    const rightmostX = monitorRect.x + monitorRect.width - labelWidthPx;
    const x = Math.max(monitorRect.x, Math.min(centredX, rightmostX));
    // Whole pixels keep the text sharp; rounding down never moves the label past the monitor's right edge.
    return {x: Math.floor(x), y: Math.floor(indicatorRect.y + indicatorRect.height + gapPx)};
}
