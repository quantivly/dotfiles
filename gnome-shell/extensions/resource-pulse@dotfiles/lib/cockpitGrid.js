// The cockpit's grid geometry: which cell each card gets on the cockpit monitor's work area, and whether a work area
// is large enough for the cards' content at all (ruling D36). Pure: no Gio, GLib or Shell import, so it runs under
// plain gjs; the shell glue draws what this returns.
import {
    COCKPIT_CARD_CONTENT_WIDTH_PX, COCKPIT_DRAWN_CARD_IDS, COCKPIT_GRID_MAX_SCALE, COCKPIT_GRID_MIN_SCALE,
    COCKPIT_GRID_REFERENCE,
} from './constants.js';

/** Added before flooring, so a product like 420 x (2/3) that floating point leaves a hair under 280 floors to 280. */
const FLOOR_TOLERANCE = 1e-9;
/** The work area the grid's reference lengths are given for, at the stage's origin. */
const REFERENCE_WORK_AREA = Object.freeze({
    x: 0, y: 0, width: COCKPIT_GRID_REFERENCE.widthPx, height: COCKPIT_GRID_REFERENCE.heightPx,
});

/**
 * @param {number} lengthPx - A length in reference pixels.
 * @param {number} scale - The grid scale.
 * @returns {number} The length scaled, as a floored integer.
 */
function scaledLength(lengthPx, scale) {
    return Math.floor(lengthPx * scale + FLOOR_TOLERANCE);
}

/**
 * @param {{width: number, height: number}} workArea - The cockpit monitor's work area.
 * @returns {number} min(width / reference width, height / reference height), clamped to the min and max scale.
 */
function gridScaleFor(workArea) {
    const rawScale = Math.min(workArea.width / COCKPIT_GRID_REFERENCE.widthPx, workArea.height / COCKPIT_GRID_REFERENCE.heightPx);
    return Math.min(COCKPIT_GRID_MAX_SCALE, Math.max(COCKPIT_GRID_MIN_SCALE, rawScale));
}

/**
 * @param {number} scale - The grid scale.
 * @returns {number} The width a card's content may take before it reaches the next card: its cell's width and the
 *     inner gutter beside it, each scaled and floored as cockpitGridGeometry draws them.
 */
function cardRoomPx(scale) {
    const {cellWidthPx, innerGutterPx} = COCKPIT_GRID_REFERENCE;
    return scaledLength(cellWidthPx, scale) + scaledLength(innerGutterPx, scale);
}

/**
 * Says whether a work area holds the cockpit grid with every card's content clear of the next card (ruling D36). The
 * grid's cells scale with the work area (gridScaleFor) and the cards' content does not, so the grid is drawn only
 * where a scaled cell plus the scaled inner gutter is at least the widest card content, COCKPIT_CARD_CONTENT_WIDTH_PX.
 * At the 1920 x 1080 reference that puts the limit near a scale of 0.94 (a 394 px cell and a 22 px gutter at a
 * 1802 x 1014 work area, leastDrawableWorkArea). Between that limit and 1.0 a card's widest rows can reach into the
 * gutter, by a few pixels near 1.0 and by up to the gutter's width at the limit: that is accepted, since they stay
 * clear of the next card. The height needs no rule of its own: the apps card's rows need about 265 px, and a cell at
 * the limit is 281 px tall. Below it, on the undocked laptop's 1536 x 960 (a scale of 0.8: 336 px cells, a 19 px
 * gutter), the system card's graphs would run into the apps card.
 *
 * @param {{width: number, height: number}} workArea - The cockpit monitor's work area.
 * @returns {boolean} True when the grid may be drawn there.
 */
export function isCockpitGridDrawable(workArea) {
    return cardRoomPx(gridScaleFor(workArea)) >= COCKPIT_CARD_CONTENT_WIDTH_PX;
}

/**
 * Walks a length of the work area down from the reference while the grid still fits one pixel shorter.
 *
 * @param {number} referenceLengthPx - The reference's length, which holds the grid.
 * @param {function(number): boolean} isDrawableAtLengthPx - Whether the grid fits at a length, the other one kept at
 *     the reference.
 * @returns {number} The least length at which it fits.
 */
function leastDrawableLengthPx(referenceLengthPx, isDrawableAtLengthPx) {
    let lengthPx = referenceLengthPx;
    while (lengthPx > 1 && isDrawableAtLengthPx(lengthPx - 1))
        lengthPx -= 1;
    return lengthPx;
}

/**
 * The smallest work area isCockpitGridDrawable holds the grid in, for the journal line that names it. Each length is
 * found alone, the other kept at the reference: the scale is the smaller of the two lengths' ratios, so each must reach
 * the limit by itself. The reference holds the grid, so each walk down from it stops at the last length that does.
 *
 * @returns {{width: number, height: number}} The least width and height, in logical pixels (1802 x 1014).
 */
export function leastDrawableWorkArea() {
    const {widthPx, heightPx} = COCKPIT_GRID_REFERENCE;
    return {
        width: leastDrawableLengthPx(widthPx, width => isCockpitGridDrawable({width, height: heightPx})),
        height: leastDrawableLengthPx(heightPx, height => isCockpitGridDrawable({width: widthPx, height})),
    };
}

/**
 * The journal line for a cockpit monitor whose work area is too small for the grid (isCockpitGridDrawable), in the
 * words of the line for a layer that cannot be drawn: the work area's size and the size the grid needs.
 *
 * @param {{width: number, height: number}} workArea - The cockpit monitor's work area.
 * @returns {string} The line, without the logger's prefix.
 */
export function cockpitGridTooSmallLine(workArea) {
    const leastWorkArea = leastDrawableWorkArea();
    const workAreaSize = `${workArea.width}x${workArea.height}`;
    const leastWorkAreaSize = `${leastWorkArea.width}x${leastWorkArea.height}`;
    return `the cockpit grid needs a larger work area than ${workAreaSize} (at least ${leastWorkAreaSize}), ` +
        'so the card is drawn top right';
}

/**
 * The cells and captions of the cockpit grid. Every reference length (cells, gutters, caption) scales by
 * min(width / 1920, height / 1080), clamped to [COCKPIT_GRID_MIN_SCALE, COCKPIT_GRID_MAX_SCALE], and is floored to an
 * integer. The grid is centred in the work area (the margins take the remainder, so it is always as tall as the
 * reference's caption row plus COCKPIT_GRID_REFERENCE.rows rows, whatever the groups hold). Groups sit left to right,
 * each `columns` cells wide, one inner gutter between the cells of a group and one group gap between groups. A group's
 * cards fill its columns left to right, then the next row; every card id gets a cell, known or not, except that a
 * group with more cards than `columns x COCKPIT_GRID_REFERENCE.rows` leaves the extra cards without a cell. The caption
 * spans its group's width above its first row. Coordinates are absolute stage coordinates (the work area's origin
 * included).
 *
 * @param {object} options - The inputs.
 * @param {{x: number, y: number, width: number, height: number}} options.workArea - The cockpit monitor's work area.
 * @param {Array<{id: string, caption: string, columns: number, cards: string[]}>} options.groups - The layout's groups.
 * @returns {{captions: Array<{groupId: string, text: string, x: number, y: number, width: number, height: number}>,
 *     cells: Array<{cardId: string, groupId: string, column: number, row: number, x: number, y: number, width: number,
 *     height: number}>}} The captions and cells.
 */
export function cockpitGridGeometry({workArea, groups}) {
    const scale = gridScaleFor(workArea);
    const cellWidth = scaledLength(COCKPIT_GRID_REFERENCE.cellWidthPx, scale);
    const cellHeight = scaledLength(COCKPIT_GRID_REFERENCE.cellHeightPx, scale);
    const innerGutter = scaledLength(COCKPIT_GRID_REFERENCE.innerGutterPx, scale);
    const groupGap = scaledLength(COCKPIT_GRID_REFERENCE.groupGapPx, scale);
    const rowGutter = scaledLength(COCKPIT_GRID_REFERENCE.rowGutterPx, scale);
    const captionHeight = scaledLength(COCKPIT_GRID_REFERENCE.captionHeightPx, scale);

    const groupWidths = groups.map(group => group.columns * cellWidth + (group.columns - 1) * innerGutter);
    const gridWidth = groupWidths.reduce((sum, width) => sum + width, 0) + Math.max(0, groups.length - 1) * groupGap;
    const rowCount = COCKPIT_GRID_REFERENCE.rows;
    const gridHeight = captionHeight + rowCount * cellHeight + (rowCount - 1) * rowGutter;
    const gridLeft = workArea.x + Math.floor((workArea.width - gridWidth) / 2);
    const gridTop = workArea.y + Math.floor((workArea.height - gridHeight) / 2);
    const cellsTop = gridTop + captionHeight;

    const captions = [];
    const cells = [];
    let groupLeft = gridLeft;
    groups.forEach((group, groupIndex) => {
        captions.push({
            groupId: group.id, text: group.caption, x: groupLeft, y: gridTop, width: groupWidths[groupIndex], height: captionHeight,
        });
        group.cards.slice(0, group.columns * rowCount).forEach((cardId, cardIndex) => {
            const column = cardIndex % group.columns;
            const row = Math.floor(cardIndex / group.columns);
            cells.push({
                cardId, groupId: group.id, column, row,
                x: groupLeft + column * (cellWidth + innerGutter),
                y: cellsTop + row * (cellHeight + rowGutter),
                width: cellWidth, height: cellHeight,
            });
        });
        groupLeft += groupWidths[groupIndex] + groupGap;
    });
    return {captions, cells};
}

/**
 * @param {string} cardId - A card id from the layout.
 * @returns {boolean} True when the cockpit draws this card (COCKPIT_DRAWN_CARD_IDS); other ids get a cell left empty.
 */
export function isKnownCockpitCard(cardId) {
    return COCKPIT_DRAWN_CARD_IDS.includes(cardId);
}

/**
 * The cells the cockpit draws a card in: the first cell of each card id it knows (isKnownCockpitCard). The cell of an
 * id it does not know (a newer service's) and a second cell of a known id stay empty, and nothing throws for them.
 *
 * @param {Array<{cardId: string}>} cells - cockpitGridGeometry's cells.
 * @returns {Array<object>} The cells drawn, the same objects, in order.
 */
export function drawnCockpitCells(cells) {
    const drawnCardIds = new Set();
    return cells.filter(cell => {
        if (!isKnownCockpitCard(cell.cardId) || drawnCardIds.has(cell.cardId))
            return false;
        drawnCardIds.add(cell.cardId);
        return true;
    });
}

/**
 * The card ids the cockpit draws for a layout's groups: those of drawnCockpitCells, in order. Which cards get a cell
 * depends on the groups alone, never on the work area, so the reference work area serves.
 *
 * @param {Array<{id: string, caption: string, columns: number, cards: string[]}>} groups - The layout's groups.
 * @returns {string[]} The card ids drawn.
 */
export function drawnCockpitCardIds(groups) {
    const {cells} = cockpitGridGeometry({workArea: REFERENCE_WORK_AREA, groups});
    return drawnCockpitCells(cells).map(cell => cell.cardId);
}
