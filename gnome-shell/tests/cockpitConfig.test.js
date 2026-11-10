// lib/cockpitConfig.js: the cockpit layout config's parser and validator, and the shipped template it must accept.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// The member names are read through the namespaces, so a missing export fails its row rather than the whole run.
import * as cockpitConfig from '../extensions/resource-pulse@dotfiles/lib/cockpitConfig.js';
import * as cockpitProtocol from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';

const REPO_ROOT_URI = GLib.uri_resolve_relative(import.meta.url, '../../', GLib.UriFlags.NONE);
const [REPO_ROOT] = GLib.filename_from_uri(REPO_ROOT_URI);
const TEMPLATE_PATH = GLib.build_filenamev([REPO_ROOT, 'examples', 'resource-pulse-cockpit.json.template']);

/**
 * Reads a file as text (tests may block).
 *
 * @param {string} path - Absolute path.
 * @returns {string} Its contents.
 */
function readSource(path) {
    const [, contentBytes] = Gio.File.new_for_path(path).load_contents(null);
    return new TextDecoder().decode(contentBytes);
}

/**
 * A config text with one group per given [id, columns, cards] row, each captioned with its id.
 *
 * @param {Array<[string, number, string[]]>} groupRows - The groups.
 * @returns {string} The JSON text of a version 1 config.
 */
function configTextOf(groupRows) {
    const groups = groupRows.map(([id, columns, cards]) => ({id, caption: id.toUpperCase(), columns, cards}));
    return JSON.stringify({version: 1, groups});
}

/**
 * @param {string} text - Config text.
 * @returns {string|null} The error parseCockpitConfig gives for it.
 */
function errorOf(text) {
    return cockpitConfig.parseCockpitConfig(text).error;
}

const SINGLE_GROUP_ROW = ['g', 1, ['system']];

test('cockpitConfig: the shipped template parses to the spec layout', () => {
    const {layout, error} = cockpitConfig.parseCockpitConfig(readSource(TEMPLATE_PATH));
    assertEqual(error, null);
    assertEqual(layout.monitor, {vendor: 'DEL', product: 'DELL U2723QE'});
    assertEqual(layout.groups.map(g => [g.id, g.columns, g.cards]), [
        ['machine', 2, ['system', 'apps', 'connections', 'health']],
        ['agents', 1, ['sessions', 'seats']],
        ['work', 1, ['sol', 'work']],
    ]);
    assertEqual(layout.groups.map(g => g.caption), ['MACHINE', 'AGENTS', 'WORK']);
});
test('cockpitConfig: the layout for the template survives cockpitProtocol.parseLayout unchanged', () => {
    const {layout} = cockpitConfig.parseCockpitConfig(readSource(TEMPLATE_PATH));
    assertEqual(cockpitProtocol.parseLayout(layout), layout);
});
test('cockpitConfig: an unknown card id is an error naming the field', () => {
    const text = JSON.stringify({version: 1, groups: [{id: 'g', caption: 'G', columns: 1, cards: ['weather']}]});
    assertEqual(cockpitConfig.parseCockpitConfig(text), {layout: null, error: "groups[0].cards[0]: unknown card id 'weather'"});
});
test('cockpitConfig: a card repeated across groups is an error', () => {
    const text = configTextOf([['machine', 1, ['system']], ['agents', 1, ['system']]]);
    assertEqual(errorOf(text), "groups[1].cards[0]: repeated card id 'system'");
});
test('cockpitConfig: a group id repeated is an error', () => {
    const text = configTextOf([['machine', 1, ['system']], ['machine', 1, ['apps']]]);
    assertEqual(errorOf(text), "groups[1].id: repeated group id 'machine'");
});
test('cockpitConfig: columns above the grid width is an error', () => {
    const text = configTextOf([['a', 2, ['system']], ['b', 2, ['apps']], ['c', 1, ['sol']]]);
    assertEqual(errorOf(text), 'groups[2].columns: columns total 5 exceeds 4');
});
test('cockpitConfig: columns filling the grid exactly are accepted', () => {
    const text = configTextOf([['a', 2, ['system']], ['b', 2, ['apps']]]);
    assertEqual(errorOf(text), null);
});
test('cockpitConfig: malformed JSON and a wrong version are errors, never a throw', () => {
    assertEqual(cockpitConfig.parseCockpitConfig('{').layout, null);
    assertEqual(cockpitConfig.parseCockpitConfig('{"version": 2, "groups": []}').error, 'version: expected 1, got 2');
});
test('cockpitConfig: text that is not an object, or not text, is an error', () => {
    assertEqual(errorOf('{'), 'config: expected a JSON object');
    assertEqual(errorOf('[1]'), 'config: expected a JSON object');
    assertEqual(cockpitConfig.parseCockpitConfig(null), {layout: null, error: 'config: expected JSON text'});
    assertEqual(cockpitConfig.parseCockpitConfig(undefined), {layout: null, error: 'config: expected JSON text'});
});
test('cockpitConfig: a missing version names the field', () => {
    assertEqual(errorOf('{"groups": []}'), 'version: expected 1, got undefined');
});
test('cockpitConfig: the monitor is optional and its fields are null when absent', () => {
    const text = configTextOf([SINGLE_GROUP_ROW]);
    assertEqual(cockpitConfig.parseCockpitConfig(text).layout.monitor, {vendor: null, product: null});
    const vendorOnly = JSON.stringify({version: 1, monitor: {vendor: 'DEL'}, groups: JSON.parse(text).groups});
    assertEqual(cockpitConfig.parseCockpitConfig(vendorOnly).layout.monitor, {vendor: 'DEL', product: null});
});
test('cockpitConfig: a mistyped monitor is an error naming the field', () => {
    const groups = JSON.parse(configTextOf([SINGLE_GROUP_ROW])).groups;
    assertEqual(errorOf(JSON.stringify({version: 1, monitor: 'DEL', groups})), 'monitor: expected an object');
    assertEqual(errorOf(JSON.stringify({version: 1, monitor: {vendor: 5}, groups})), 'monitor.vendor: expected a string');
    assertEqual(errorOf(JSON.stringify({version: 1, monitor: {product: []}, groups})), 'monitor.product: expected a string');
});
test('cockpitConfig: groups must be a non-empty array', () => {
    assertEqual(errorOf('{"version": 1}'), 'groups: expected a non-empty array');
    assertEqual(errorOf('{"version": 1, "groups": []}'), 'groups: expected a non-empty array');
    assertEqual(errorOf('{"version": 1, "groups": {}}'), 'groups: expected a non-empty array');
});
test('cockpitConfig: a group that is not an object is an error', () => {
    assertEqual(errorOf('{"version": 1, "groups": [5]}'), 'groups[0]: expected an object');
});
test('cockpitConfig: a bad group field is an error naming that field', () => {
    const goodGroup = {id: 'a', caption: 'A', columns: 1, cards: ['system']};
    const errorWith = override => errorOf(JSON.stringify({version: 1, groups: [goodGroup, {...goodGroup, id: 'b', cards: ['apps'], ...override}]}));
    assertEqual(errorWith({id: ''}), 'groups[1].id: expected a non-empty string');
    assertEqual(errorWith({id: 3}), 'groups[1].id: expected a non-empty string');
    assertEqual(errorWith({caption: ''}), 'groups[1].caption: expected a non-empty string');
    assertEqual(errorWith({columns: 3}), 'groups[1].columns: expected 1 or 2');
    assertEqual(errorWith({columns: '1'}), 'groups[1].columns: expected 1 or 2');
    assertEqual(errorWith({cards: []}), 'groups[1].cards: expected a non-empty array');
    assertEqual(errorWith({cards: 'apps'}), 'groups[1].cards: expected a non-empty array');
    assertEqual(errorWith({cards: [4]}), "groups[1].cards[0]: unknown card id '4'");
});
test('cockpitConfig: keys starting with an underscore and unknown keys are ignored', () => {
    const text = JSON.stringify({
        _comment: 'x', version: 1, extra: true, monitor: {_note: 1, vendor: 'DEL', other: 2},
        groups: [{_note: 'y', id: 'g', caption: 'G', columns: 1, cards: ['system'], future: 1}],
    });
    assertEqual(cockpitConfig.parseCockpitConfig(text), {
        layout: {monitor: {vendor: 'DEL', product: null}, groups: [{id: 'g', caption: 'G', columns: 1, cards: ['system']}]},
        error: null,
    });
});
test('cockpitConfig: cockpitConfigPath joins the config home and the relative path', () => {
    assertEqual(cockpitConfig.cockpitConfigPath('/tmp/xdg'), '/tmp/xdg/resource-pulse/cockpit.json');
});
