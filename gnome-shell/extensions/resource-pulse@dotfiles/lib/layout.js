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

/**
 * Places a cockpit tooltip: centred under its anchor and kept inside the anchor's monitor, or above the anchor when
 * the label would cross the monitor's bottom edge and fits above it, at whole pixels.
 *
 * @param {object} placement - What to place.
 * @param {{x: number, y: number, width: number, height: number}} placement.anchorRect - The anchor's stage position
 *     and size, in pixels.
 * @param {number} placement.labelWidthPx - The label's width for the text it is about to show, in pixels.
 * @param {number} placement.labelHeightPx - The label's height for that text, in pixels.
 * @param {number} placement.gapPx - Space between the anchor and the label, in pixels.
 * @param {{x: number, y: number, width: number, height: number}} placement.monitorRect - The anchor's monitor, in
 *     stage pixels.
 * @returns {{x: number, y: number}} The label's origin. x never falls left of the monitor, nor so far right that the
 *     label crosses the monitor's right edge (a label wider than the monitor starts at its left edge). y is below the
 *     anchor, unless that crosses the monitor's bottom and the label fits above the anchor within the monitor.
 */
export function tooltipPosition({anchorRect, labelWidthPx, labelHeightPx, gapPx, monitorRect}) {
    const centredX = anchorRect.x + (anchorRect.width - labelWidthPx) / 2;
    const rightmostX = monitorRect.x + monitorRect.width - labelWidthPx;
    const x = Math.max(monitorRect.x, Math.min(centredX, rightmostX));
    const belowY = anchorRect.y + anchorRect.height + gapPx;
    const aboveY = anchorRect.y - gapPx - labelHeightPx;
    const crossesBottom = belowY + labelHeightPx > monitorRect.y + monitorRect.height;
    const fitsAbove = aboveY >= monitorRect.y;
    const y = crossesBottom && fitsAbove ? aboveY : belowY;
    return {x: Math.floor(x), y: Math.floor(y)};
}
