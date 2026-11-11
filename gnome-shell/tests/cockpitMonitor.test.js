// lib/cockpitMonitor.js: which monitor is the cockpit monitor, and the pure half of reading DisplayConfig.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import * as cockpitMonitor from '../extensions/resource-pulse@dotfiles/lib/cockpitMonitor.js';

const FIXTURE_URI = GLib.uri_resolve_relative(import.meta.url, 'fixtures/cockpit/display-config-two-monitors.json', GLib.UriFlags.NONE);
const [FIXTURE_PATH] = GLib.filename_from_uri(FIXTURE_URI);
const [, FIXTURE_BYTES] = Gio.File.new_for_path(FIXTURE_PATH).load_contents(null);
const DISPLAY_CONFIG_STATE = JSON.parse(new TextDecoder().decode(FIXTURE_BYTES)).state;

const DELL = {index: 1, x: 1920, y: 0, width: 1920, height: 1080, isPrimary: false, vendor: 'DEL', product: 'DELL U2723QE'};
const SAMSUNG = {index: 0, x: 0, y: 0, width: 1920, height: 1080, isPrimary: true, vendor: 'SAM', product: 'S24C650'};
const RULE = {vendor: 'DEL', product: 'DELL U2723QE'};

/**
 * @param {object[]} monitors - Monitors.
 * @param {object|null} rule - The config's monitor rule.
 * @returns {number|null} The chosen index.
 */
function chosen(monitors, rule) {
    return cockpitMonitor.chooseCockpitMonitorIndex({monitors, rule});
}

test('cockpitMonitor: the named monitor wins, the only monitor is the fallback, then the largest non-primary', () => {
    assertEqual(chosen([SAMSUNG, DELL], RULE), 1);
    assertEqual(chosen([DELL, SAMSUNG].map((m, i) => ({...m, index: i})), RULE), 0);
    assertEqual(chosen([SAMSUNG], RULE), 0);
    assertEqual(chosen([SAMSUNG, {...DELL, vendor: 'LG', product: 'x', width: 2560}], RULE), 1);
    assertEqual(chosen([], RULE), null);
});
test('cockpitMonitor: vendor and product must both match, case-sensitively', () => {
    const third = {...DELL, index: 2, vendor: 'LG', product: 'x', width: 3000};
    assertEqual(chosen([SAMSUNG, {...DELL, product: 'OTHER'}, third], RULE), 2);
    assertEqual(chosen([SAMSUNG, {...DELL, vendor: 'del'}, third], RULE), 2);
});
test('cockpitMonitor: without a rule the largest non-primary wins, ties to the lowest index', () => {
    const tied = {...DELL, index: 2};
    assertEqual(chosen([SAMSUNG, DELL, tied], null), 1);
    // The lower index listed LATER: only the explicit tie-break, not a strict `>`, picks it.
    assertEqual(chosen([SAMSUNG, tied, DELL], null), 1);
    assertEqual(chosen([SAMSUNG, DELL, {...tied, width: 2560}], null), 2);
});
test('cockpitMonitor: only primaries and no rule match falls back to the only monitor, else null-safe', () => {
    assertEqual(chosen([SAMSUNG], null), 0);
    assertEqual(chosen([SAMSUNG, {...SAMSUNG, index: 1}], null), null);
});
test('cockpitMonitor: DisplayConfig descriptors match layout monitors by position', () => {
    const descriptors = cockpitMonitor.monitorDescriptorsFromDisplayConfig(DISPLAY_CONFIG_STATE);
    assertEqual(descriptors, [
        {connector: 'eDP-1', vendor: 'CMN', product: 'N140JCN-GT1'},
        {connector: 'DP-1', vendor: 'DEL', product: 'DELL U2723QE'},
    ]);
    const layoutMonitors = [
        {index: 0, x: 0, y: 0, width: 1536, height: 960, isPrimary: true},
        {index: 1, x: 1920, y: 0, width: 1920, height: 1080, isPrimary: false},
    ];
    const matched = cockpitMonitor.matchDescriptorsToMonitors({
        monitors: layoutMonitors, logicalMonitors: DISPLAY_CONFIG_STATE[2], descriptors,
    });
    assertEqual(matched.map(m => [m.index, m.vendor, m.product]), [[0, 'CMN', 'N140JCN-GT1'], [1, 'DEL', 'DELL U2723QE']]);
    assertEqual(chosen(matched, RULE), 1);
});
test('cockpitMonitor: a monitor at no logical monitor position gets null vendor and product; bad input gives no descriptors', () => {
    const matched = cockpitMonitor.matchDescriptorsToMonitors({
        monitors: [{index: 0, x: 5, y: 5, width: 1, height: 1, isPrimary: true}],
        logicalMonitors: DISPLAY_CONFIG_STATE[2], descriptors: [],
    });
    assertEqual([matched[0].vendor, matched[0].product], [null, null]);
    assertEqual(cockpitMonitor.monitorDescriptorsFromDisplayConfig(null), []);
    assertEqual(cockpitMonitor.monitorDescriptorsFromDisplayConfig([1, 'x']), []);
});

/** The two monitors of the fixture, as the glue reads Main.layoutManager.monitors: no vendor or product yet. */
const LAYOUT_MONITORS = [
    {index: 0, x: 0, y: 0, width: 1536, height: 960, isPrimary: true},
    {index: 1, x: 1920, y: 0, width: 1920, height: 1080, isPrimary: false},
];
/** A monitor rule that names nothing, as parseLayout reads a layout without one. */
const NO_RULE = {vendor: null, product: null};

test('cockpitMonitor: the cockpit monitor is the one DisplayConfig names as the rule\'s, even when it is not the ' +
    'largest non-primary; with no DisplayConfig answer the rule falls back to the largest non-primary', () => {
    const laptopRule = {vendor: 'CMN', product: 'N140JCN-GT1'};
    const indexFor = (displayConfigState, monitorRule) =>
        cockpitMonitor.cockpitMonitorIndexFor({monitors: LAYOUT_MONITORS, displayConfigState, monitorRule});
    assertEqual({
        named: indexFor(DISPLAY_CONFIG_STATE, laptopRule),
        dell: indexFor(DISPLAY_CONFIG_STATE, RULE),
        noAnswer: indexFor(null, laptopRule),
        noRule: indexFor(DISPLAY_CONFIG_STATE, NO_RULE),
    }, {named: 0, dell: 1, noAnswer: 1, noRule: 1});
});

test('cockpitMonitor: a rule that names no vendor and product matches no monitor, so monitors DisplayConfig left ' +
    'unidentified are not taken for it: the fallback chooses', () =>
    assertEqual(cockpitMonitor.cockpitMonitorIndexFor({
        monitors: LAYOUT_MONITORS, displayConfigState: null, monitorRule: NO_RULE,
    }), 1));

test('cockpitMonitor: undocked, the named monitor gone and only the primary left, the cockpit moves to it (Review ' +
    'Focus 1)', () =>
    assertEqual(cockpitMonitor.cockpitMonitorIndexFor({
        monitors: [LAYOUT_MONITORS[0]], displayConfigState: null, monitorRule: RULE,
    }), 0));

test('cockpitMonitor: a DisplayConfig answer of an unexpected shape identifies nothing and never throws; no monitor ' +
    'at all is no cockpit monitor', () => {
    const malformedStates = [
        [1, [], null, {}], [1, [], [null, 'x', [0, 0]], {}], [1, [[['DP-1']]], [[1920, 0, 1, 0, false, [null]]], {}],
        'not a state',
    ];
    assertEqual({
        malformed: malformedStates.map(displayConfigState => cockpitMonitor.cockpitMonitorIndexFor({
            monitors: LAYOUT_MONITORS, displayConfigState, monitorRule: RULE,
        })),
        noMonitors: cockpitMonitor.cockpitMonitorIndexFor({
            monitors: [], displayConfigState: DISPLAY_CONFIG_STATE, monitorRule: RULE,
        }),
    }, {malformed: [1, 1, 1, 1], noMonitors: null});
});
