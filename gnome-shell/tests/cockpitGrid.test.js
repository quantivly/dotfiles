// lib/cockpitGrid.js: where each cockpit card goes on the cockpit monitor's work area.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import * as cockpitGrid from '../extensions/resource-pulse@dotfiles/lib/cockpitGrid.js';
import * as cockpitConfig from '../extensions/resource-pulse@dotfiles/lib/cockpitConfig.js';
import * as constantsModule from '../extensions/resource-pulse@dotfiles/lib/constants.js';

const REPO_ROOT_URI = GLib.uri_resolve_relative(import.meta.url, '../../', GLib.UriFlags.NONE);
const [REPO_ROOT] = GLib.filename_from_uri(REPO_ROOT_URI);
const TEMPLATE_PATH = GLib.build_filenamev([REPO_ROOT, 'examples', 'resource-pulse-cockpit.json.template']);
const [, TEMPLATE_BYTES] = Gio.File.new_for_path(TEMPLATE_PATH).load_contents(null);
const TEMPLATE_GROUPS = cockpitConfig.parseCockpitConfig(new TextDecoder().decode(TEMPLATE_BYTES)).layout.groups;
const FULL_HD = {x: 0, y: 0, width: 1920, height: 1080};
const TEMPLATE_CARD_COUNT = 8;

/**
 * @param {object} geometry - A cockpitGridGeometry result.
 * @param {string} cardId - A card id.
 * @returns {object} That card's cell.
 */
function cellOf(geometry, cardId) {
    return geometry.cells.find(cell => cell.cardId === cardId);
}

test('cockpitGrid: the spec grid at 1920x1080 has 420-wide cells, 300-tall rows and a 28 px caption row', () => {
    const geometry = cockpitGrid.cockpitGridGeometry({workArea: FULL_HD, groups: TEMPLATE_GROUPS});
    const system = cellOf(geometry, 'system');
    assertEqual([system.x, system.y, system.width, system.height], [60, 80, 420, 300]);
    assertEqual(cellOf(geometry, 'connections').row, 1);
    assertEqual(cellOf(geometry, 'connections').y, 80 + 300 + 24);
    assertEqual(cellOf(geometry, 'sessions').x, 60 + 2 * 420 + 24 + 48);
    assertEqual(geometry.captions.map(c => c.text), ['MACHINE', 'AGENTS', 'WORK']);
});
test('cockpitGrid: a caption spans its group above its first row', () => {
    const {captions} = cockpitGrid.cockpitGridGeometry({workArea: FULL_HD, groups: TEMPLATE_GROUPS});
    assertEqual(captions[0], {groupId: 'machine', text: 'MACHINE', x: 60, y: 52, width: 2 * 420 + 24, height: 28});
    assertEqual([captions[2].x, captions[2].width], [60 + 420 * 3 + 24 + 96, 420]);
});
test('cockpitGrid: a work area offset and a smaller monitor scale every length, never the cell count', () => {
    const workArea = {x: 1920, y: 0, width: 1280, height: 720};
    const geometry = cockpitGrid.cockpitGridGeometry({workArea, groups: TEMPLATE_GROUPS});
    assertEqual(geometry.cells.length, TEMPLATE_CARD_COUNT);
    const system = cellOf(geometry, 'system');
    assertEqual([system.width, system.height], [280, 200]);
    assertEqual(cellOf(geometry, 'apps').x - system.x, 280 + 16);
    assertEqual(cellOf(geometry, 'sessions').x - cellOf(geometry, 'apps').x, 280 + 32);
    assertEqual(cellOf(geometry, 'connections').y - system.y, 200 + 16);
    // Grid 1200 x 650 (18 caption + 3 x 200 + 2 x 16): margins (1280 - 1200) / 2 = 40 and (720 - 650) / 2 = 35.
    assertEqual([system.x, system.y], [1920 + 40, 35 + 18]);
    geometry.cells.forEach(cell => {
        const isInside = cell.x >= workArea.x && cell.y >= workArea.y &&
            cell.x + cell.width <= workArea.x + workArea.width && cell.y + cell.height <= workArea.y + workArea.height;
        assertEqual(isInside, true);
    });
});
test('cockpitGrid: the scale is clamped to 0.5 and 2', () => {
    const tiny = cockpitGrid.cockpitGridGeometry({workArea: {x: 0, y: 0, width: 640, height: 360}, groups: TEMPLATE_GROUPS});
    assertEqual([cellOf(tiny, 'system').width, cellOf(tiny, 'system').height], [210, 150]);
    const huge = cockpitGrid.cockpitGridGeometry({workArea: {x: 0, y: 0, width: 7680, height: 4320}, groups: TEMPLATE_GROUPS});
    assertEqual([cellOf(huge, 'system').width, cellOf(huge, 'system').height], [840, 600]);
});
test('cockpitGrid: cards fill a group left to right, then the next row; extra cards get no cell', () => {
    const groups = [{id: 'g', caption: 'G', columns: 2, cards: ['system', 'apps', 'connections', 'health', 'sessions', 'seats', 'sol']}];
    const {cells} = cockpitGrid.cockpitGridGeometry({workArea: FULL_HD, groups});
    assertEqual(cells.map(c => [c.cardId, c.column, c.row]), [
        ['system', 0, 0], ['apps', 1, 0], ['connections', 0, 1], ['health', 1, 1], ['sessions', 0, 2], ['seats', 1, 2],
    ]);
});
test('cockpitGrid: an unknown card id still gets a cell', () => {
    const groups = [{id: 'g', caption: 'G', columns: 1, cards: ['weather']}];
    assertEqual(cockpitGrid.cockpitGridGeometry({workArea: FULL_HD, groups}).cells.length, 1);
    assertEqual(cockpitGrid.isKnownCockpitCard('weather'), false);
    assertEqual(['system', 'apps', 'connections', 'sessions'].map(cockpitGrid.isKnownCockpitCard), [true, true, true, true]);
});
test('cockpitGrid: the cockpit draws a card in the first cell of each id it knows; an unknown id\'s cell and a known ' +
    'id\'s second cell stay empty (drawnCockpitCells), and the ids drawn are the same whatever the work area', () => {
    const groups = [
        {id: 'machine', caption: 'MACHINE', columns: 2, cards: ['system', 'weather', 'apps', 'system']},
        {id: 'agents', caption: 'AGENTS', columns: 1, cards: ['sessions', 'seats']},
    ];
    const {cells} = cockpitGrid.cockpitGridGeometry({workArea: FULL_HD, groups});
    const drawnCells = cockpitGrid.drawnCockpitCells(cells);
    const smallerWorkArea = {x: 1920, y: 0, width: 1280, height: 720};
    const smallerCells = cockpitGrid.cockpitGridGeometry({workArea: smallerWorkArea, groups}).cells;
    assertEqual({
        drawn: drawnCells.map(cell => [cell.cardId, cell.groupId, cell.column, cell.row]),
        drawnCellIsTheGridCell: drawnCells[0] === cells[0],
        drawnCardIds: cockpitGrid.drawnCockpitCardIds(groups),
        drawnAtAnotherWorkArea: cockpitGrid.drawnCockpitCells(smallerCells).map(cell => cell.cardId),
        noGroups: cockpitGrid.drawnCockpitCardIds([]),
        onlyUnknown: cockpitGrid.drawnCockpitCardIds([{id: 'g', caption: 'G', columns: 1, cards: ['weather']}]),
    }, {
        drawn: [['system', 'machine', 0, 0], ['apps', 'machine', 0, 1], ['sessions', 'agents', 0, 0]],
        drawnCellIsTheGridCell: true,
        drawnCardIds: ['system', 'apps', 'sessions'],
        drawnAtAnotherWorkArea: ['system', 'apps', 'sessions'],
        noGroups: [],
        onlyUnknown: [],
    });
});
test('cockpitGrid: a card past what its group\'s block holds gets no cell, so it is not drawn either', () => {
    const groups = [{id: 'g', caption: 'G', columns: 1, cards: ['health', 'seats', 'sol', 'sessions']}];
    assertEqual(cockpitGrid.drawnCockpitCardIds(groups), []);
});

/**
 * @param {number} width - A work area's width.
 * @param {number} height - Its height.
 * @returns {boolean} isCockpitGridDrawable for that work area, at the stage's origin.
 */
function isDrawableAt(width, height) {
    return cockpitGrid.isCockpitGridDrawable({x: 0, y: 0, width, height});
}

test('cockpitGrid: the grid is drawn only where a scaled cell and its inner gutter are at least the widest card ' +
    'content, COCKPIT_CARD_CONTENT_WIDTH_PX (ruling D36): at the 1920x1080 reference and at the nested run\'s ' +
    '3072x1920 it is; on the undocked laptop\'s 1536x960 (a scale of 0.8: a 336 px cell and a 19 px gutter), with or ' +
    'without its top bar, it is not', () => {
    assertEqual({
        contentWidthPx: constantsModule.COCKPIT_CARD_CONTENT_WIDTH_PX,
        reference: isDrawableAt(1920, 1080),
        nestedRun: isDrawableAt(3072, 1920),
        laptop: isDrawableAt(1536, 960),
        laptopUnderItsTopBar: isDrawableAt(1536, 928),
    }, {contentWidthPx: 416, reference: true, nestedRun: true, laptop: false, laptopUnderItsTopBar: false});
});

test('cockpitGrid: the limit is a work area of 1802x1014, a scale of about 0.94 whose 394 px cell and 22 px gutter ' +
    'make 416; one pixel less in either length is under it, and leastDrawableWorkArea names that size', () => {
    const atTheLimit = cockpitGrid.cockpitGridGeometry({
        workArea: {x: 0, y: 0, width: 1802, height: 1014}, groups: TEMPLATE_GROUPS,
    });
    const system = cellOf(atTheLimit, 'system');
    assertEqual({
        atTheLimit: isDrawableAt(1802, 1014),
        oneNarrower: isDrawableAt(1801, 1014),
        oneShorter: isDrawableAt(1802, 1013),
        cellAndGutterAtTheLimit: [system.width, cellOf(atTheLimit, 'apps').x - system.x - system.width],
        least: cockpitGrid.leastDrawableWorkArea(),
    }, {
        atTheLimit: true, oneNarrower: false, oneShorter: false, cellAndGutterAtTheLimit: [394, 22],
        least: {width: 1802, height: 1014},
    });
});

test('cockpitGrid: the journal line for a work area too small for the grid names its size and the size needed, so ' +
    'the card is drawn top right', () =>
    assertEqual(cockpitGrid.cockpitGridTooSmallLine({x: 0, y: 32, width: 1536, height: 928}),
        'the cockpit grid needs a larger work area than 1536x928 (at least 1802x1014), ' +
        'so the card is drawn top right'));
