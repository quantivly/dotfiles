// lib/cockpitWiring.js: whether the cockpit's layer is drawn and what a layout keeps across enables, where the v2 card
// goes, which surfaces a cover leaves seen, what a client event changes and when (ruling D20), what a data card draws,
// which sources a tick pulls, and which frozen cards a tick repaints (ruling D18).
import {test, assertEqual} from './harness.js';
// Read through the namespace, so a missing export fails its row rather than the whole run.
import * as wiring from '../extensions/resource-pulse@dotfiles/lib/cockpitWiring.js';
import * as constantsModule from '../extensions/resource-pulse@dotfiles/lib/constants.js';

/** CockpitClientState's and CockpitClientEventType's values, written out. */
const STARTING = 'starting';
const SKIPPED = 'skipped';
const LIVE = 'live';
const VANISHED = 'vanished';
const STATE_EVENT = 'state';
const LAYOUT_EVENT = 'layout';
const SOURCES_EVENT = 'sources';
/** CockpitSourcesCause's values, written out. */
const READ = 'read';
const CHANGED = 'changed';
const PULL = 'pull';
/** CockpitApplyTiming's values, written out. */
const NOW = 'now';
const NEXT_TICK = 'next-tick';
const NEXT_TICK_WITH_FALLBACK = 'next-tick-with-fallback';
const NEVER = 'never';
const ALL_SOURCE_NAMES = ['sessions', 'network', 'mounts'];
const LAYOUT = {
    monitor: {vendor: 'DEL', product: 'DELL U2723QE'},
    groups: [{id: 'machine', caption: 'MACHINE', columns: 2, cards: ['system', 'apps', 'connections', 'health']}],
};
/** LAYOUT edited: another grid, so another layout. */
const EDITED_LAYOUT = {
    monitor: LAYOUT.monitor,
    groups: [{id: 'machine', caption: 'MACHINE', columns: 2, cards: ['system', 'apps']}],
};
const USEC_PER_SECOND = 1_000_000;
/** FROZEN_REPAINT_INTERVAL_SECONDS (30), written out. */
const FROZEN_REPAINT_SECONDS = 30;
const FROZEN_AT_USEC = 5_000_000_000;
const ONE_USEC = 1;
const SAMPLED_AT_USEC = 1_794_000_001_000_000;
const LATER_SAMPLED_AT_USEC = 1_794_000_031_000_000;

test('cockpitWiring: the card ids, the sampler\'s cards and each card\'s cockpit sources are constants: system and ' +
    'apps draw no cockpit source, connections draws network and mounts, sessions sessions', () => {
    const {
        COCKPIT_SYSTEM_CARD_ID, COCKPIT_SESSIONS_CARD_ID, COCKPIT_SNAPSHOT_CARD_IDS, COCKPIT_SOURCE_NAMES_BY_CARD_ID,
    } = constantsModule;
    assertEqual({
        systemCardId: COCKPIT_SYSTEM_CARD_ID, sessionsCardId: COCKPIT_SESSIONS_CARD_ID,
        snapshotCardIds: COCKPIT_SNAPSHOT_CARD_IDS,
        sourceNamesByCardId: COCKPIT_SOURCE_NAMES_BY_CARD_ID,
        areFrozen: [COCKPIT_SNAPSHOT_CARD_IDS, COCKPIT_SOURCE_NAMES_BY_CARD_ID,
            ...Object.values(COCKPIT_SOURCE_NAMES_BY_CARD_ID ?? {})].map(value => Object.isFrozen(value)),
        fallbackSeconds: constantsModule.COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS,
    }, {
        systemCardId: 'system', sessionsCardId: 'sessions', snapshotCardIds: ['system', 'apps'],
        sourceNamesByCardId: {system: [], apps: [], connections: ['network', 'mounts'], sessions: ['sessions']},
        areFrozen: [true, true, true, true, true, true], fallbackSeconds: 3,
    });
});

test('cockpitWiring: the layer is drawn while a layout is known (cached or received, the service gone included) and ' +
    'the cockpit is not SKIPPED (ruling D19); the layout kept across enables is the one drawn', () => {
    const states = [STARTING, LIVE, VANISHED, SKIPPED];
    assertEqual({
        withLayout: states.map(clientState => wiring.isCockpitLayerWanted({clientState, layout: LAYOUT})),
        withoutLayout: states.map(clientState => wiring.isCockpitLayerWanted({clientState, layout: null})),
        keptWithLayout: states.map(clientState => wiring.cockpitLayoutToKeep({clientState, layout: LAYOUT})),
        keptWithoutLayout: states.map(clientState => wiring.cockpitLayoutToKeep({clientState, layout: null})),
    }, {
        withLayout: [true, true, true, false], withoutLayout: [false, false, false, false],
        keptWithLayout: [LAYOUT, LAYOUT, LAYOUT, null], keptWithoutLayout: [null, null, null, null],
    });
});

test('cockpitWiring: a client event adds the layer once it is wanted, removes it once it is not, rebuilds a shown ' +
    'layer on a layout event, and otherwise changes nothing (CockpitLayerChange, frozen)', () => {
    const change = (isLayerShown, clientState, layout, isLayoutEvent) =>
        wiring.cockpitLayerChange({isLayerShown, clientState, layout, isLayoutEvent, isGridDrawable: true});
    assertEqual({
        changes: wiring.CockpitLayerChange, isFrozen: Object.isFrozen(wiring.CockpitLayerChange),
        cachedAtEnable: change(false, STARTING, LAYOUT, false),
        firstLayoutArrives: change(false, LIVE, LAYOUT, true),
        skipped: change(true, SKIPPED, LAYOUT, false),
        layoutGone: change(true, LIVE, null, true),
        layoutEdited: change(true, LIVE, LAYOUT, true),
        sourcesWhileShown: change(true, LIVE, LAYOUT, false),
        vanishedWhileShown: change(true, VANISHED, LAYOUT, false),
        nothingKnown: change(false, STARTING, null, false),
        layoutEventWhileSkipped: change(false, SKIPPED, LAYOUT, true),
    }, {
        changes: {ADD: 'add', REMOVE: 'remove', REBUILD: 'rebuild', NONE: 'none'}, isFrozen: true,
        cachedAtEnable: 'add', firstLayoutArrives: 'add', skipped: 'remove', layoutGone: 'remove',
        layoutEdited: 'rebuild', sourcesWhileShown: 'none', vanishedWhileShown: 'none', nothingKnown: 'none',
        layoutEventWhileSkipped: 'none',
    });
});

/**
 * LAYOUT as the client holds it after a later answer: a new object with the same JSON (cockpitClient.js replaces its
 * layout object on every GetState answer and every Changed that carries one, and tells a layout event only when the
 * JSON differs).
 *
 * @returns {object} A copy of LAYOUT.
 */
function layoutFromALaterAnswer() {
    return JSON.parse(JSON.stringify(LAYOUT));
}

test('cockpitWiring: the layout that failed to build in this enable is not tried again while the client holds it ' +
    '(the same JSON in a new object, as the client tells a changed layout), on any event; another layout is added ' +
    'or rebuilt as usual, and a layer no longer wanted is still removed (ruling D25)', () => {
    const change = (isLayerShown, clientState, layout, isLayoutEvent) =>
        wiring.cockpitLayerChange({
            isLayerShown, clientState, layout, isLayoutEvent, failedLayout: LAYOUT, isGridDrawable: true,
        });
    assertEqual({
        failedOneOnAState: change(false, LIVE, layoutFromALaterAnswer(), false),
        failedOneOnALayoutEvent: change(false, LIVE, layoutFromALaterAnswer(), true),
        anotherArrives: change(false, LIVE, EDITED_LAYOUT, true),
        anotherWhileShown: change(true, LIVE, EDITED_LAYOUT, true),
        skippedWhileShown: change(true, SKIPPED, layoutFromALaterAnswer(), false),
        goneWhileShown: change(true, LIVE, null, true),
    }, {
        failedOneOnAState: 'none', failedOneOnALayoutEvent: 'none',
        anotherArrives: 'add', anotherWhileShown: 'rebuild', skippedWhileShown: 'remove', goneWhileShown: 'remove',
    });
});

test('cockpitWiring: the layout that failed comes back while a layer drawn from another is shown: the layer is ' +
    'removed, so the v2 card is drawn top right as when it first failed, never the grid of a layout the client no ' +
    'longer holds (ruling D25)', () => {
    const change = isLayoutEvent => wiring.cockpitLayerChange({
        isLayerShown: true, clientState: LIVE, layout: layoutFromALaterAnswer(), isLayoutEvent, failedLayout: LAYOUT,
        isGridDrawable: true,
    });
    assertEqual({onItsLayoutEvent: change(true), onALaterEvent: change(false)},
        {onItsLayoutEvent: 'remove', onALaterEvent: 'remove'});
});

test('cockpitWiring: the layout that failed to build in this enable is not kept for the next (the same JSON in a new ' +
    'object), which then starts with none and tries the layout the service sends once; another layout is kept', () => {
    const kept = (layout, failedLayout) => wiring.cockpitLayoutToKeep({clientState: LIVE, layout, failedLayout});
    assertEqual({
        failedOne: kept(layoutFromALaterAnswer(), LAYOUT),
        anotherAfterAFailure: kept(EDITED_LAYOUT, LAYOUT),
        noFailure: kept(LAYOUT, null),
    }, {failedOne: null, anotherAfterAFailure: EDITED_LAYOUT, noFailure: LAYOUT});
});

test('cockpitWiring: a work area too small for the grid keeps the layer away (ruling D36): never added, removed ' +
    'while shown on any event, and added again once the grid fits, as when no layout is known', () => {
    const change = (isLayerShown, clientState, layout, isLayoutEvent, isGridDrawable) => wiring.cockpitLayerChange({
        isLayerShown, clientState, layout, isLayoutEvent, failedLayout: null, isGridDrawable,
    });
    assertEqual({
        cachedAtEnable: change(false, STARTING, LAYOUT, false, false),
        firstLayoutArrives: change(false, LIVE, LAYOUT, true, false),
        shownOnAPlacement: change(true, LIVE, LAYOUT, false, false),
        shownOnALayoutEvent: change(true, LIVE, LAYOUT, true, false),
        fitsAgain: change(false, LIVE, LAYOUT, false, true),
        skippedAndTooSmall: change(true, SKIPPED, LAYOUT, false, false),
    }, {
        cachedAtEnable: 'none', firstLayoutArrives: 'none', shownOnAPlacement: 'remove', shownOnALayoutEvent: 'remove',
        fitsAgain: 'add', skippedAndTooSmall: 'remove',
    });
});

test('cockpitWiring: the grid is held back by its work area only while a layout would be drawn (wanted, not the one ' +
    'that failed) and does not fit; the journal line is written as that begins (ruling D36)', () => {
    const isHeldBack = (clientState, layout, failedLayout, isGridDrawable) =>
        wiring.isCockpitGridHeldBack({clientState, layout, failedLayout, isGridDrawable});
    assertEqual({
        tooSmall: isHeldBack(LIVE, LAYOUT, null, false),
        cachedAndTooSmall: isHeldBack(STARTING, LAYOUT, null, false),
        fits: isHeldBack(LIVE, LAYOUT, null, true),
        noLayout: isHeldBack(LIVE, null, null, false),
        skipped: isHeldBack(SKIPPED, LAYOUT, null, false),
        theLayoutThatFailed: isHeldBack(LIVE, layoutFromALaterAnswer(), LAYOUT, false),
    }, {
        tooSmall: true, cachedAndTooSmall: true, fits: false, noLayout: false, skipped: false,
        theLayoutThatFailed: false,
    });
});

test('cockpitWiring: the grid may be drawn on its monitor\'s work area when it fits there, with no monitor at all ' +
    '(the layer stays as it is), and while DisplayConfig\'s answer could still move it to another monitor (the add ' +
    'asks for that answer, which decides); a settled choice too small holds it back', () => {
    const laptop = {x: 0, y: 32, width: 1536, height: 928};
    const external = {x: 1536, y: 32, width: 1920, height: 1048};
    const isDrawableNow = (workArea, isMonitorChoiceSettled) =>
        wiring.isCockpitGridDrawableNow({workArea, isMonitorChoiceSettled});
    assertEqual({
        settledAndTooSmall: isDrawableNow(laptop, true),
        settledAndFits: isDrawableNow(external, true),
        unsettledAndTooSmall: isDrawableNow(laptop, false),
        noMonitor: isDrawableNow(null, true),
    }, {settledAndTooSmall: false, settledAndFits: true, unsettledAndTooSmall: true, noMonitor: true});
});

test('cockpitWiring: the v2 card is held hidden (not drawn, kept frozen) only while the layer is shown and draws no ' +
    'system card (ruling D21); in the system cell or top right it is not', () => {
    const isHidden = (isCockpitLayerShown, drawnCardIds) =>
        wiring.isPulseCardHeldHidden({isCockpitLayerShown, drawnCardIds});
    assertEqual([
        isHidden(true, ['apps', 'connections', 'sessions']), isHidden(true, []),
        isHidden(true, ['system', 'apps']), isHidden(false, []), isHidden(false, ['apps']),
    ], [true, true, false, false, false]);
});

test('cockpitWiring: a cockpit card is seen while the layer is shown with a card visible; a card that draws the ' +
    'sampler\'s snapshot (the system or apps cell, or top right the v2 card) is seen for the detail watch', () => {
    const seen = (isCockpitLayerShown, visibleCardIds) =>
        wiring.cockpitSurfacesSeen({isCockpitLayerShown, visibleCardIds});
    assertEqual({
        v2CardVisible: seen(false, ['system']),
        v2CardCovered: seen(false, []),
        onlySessionsVisible: seen(true, ['sessions']),
        onlyAppsVisible: seen(true, ['apps']),
        systemAndConnectionsVisible: seen(true, ['system', 'connections']),
        everyCardCovered: seen(true, []),
    }, {
        v2CardVisible: {isAnyCockpitCardVisible: false, isSnapshotCardVisible: true},
        v2CardCovered: {isAnyCockpitCardVisible: false, isSnapshotCardVisible: false},
        onlySessionsVisible: {isAnyCockpitCardVisible: true, isSnapshotCardVisible: false},
        onlyAppsVisible: {isAnyCockpitCardVisible: true, isSnapshotCardVisible: true},
        systemAndConnectionsVisible: {isAnyCockpitCardVisible: true, isSnapshotCardVisible: true},
        everyCardCovered: {isAnyCockpitCardVisible: false, isSnapshotCardVisible: false},
    });
});

test('cockpitWiring: a read\'s sources are drawn at once; a Changed\'s and a pull\'s wait for the next tick, arming ' +
    'the fallback only when it is not armed (ruling D20; CockpitApplyTiming, frozen)', () => {
    const effect = (cause, isFallbackArmed) => wiring.cockpitEventEffect({
        event: {type: SOURCES_EVENT, names: ['network', 'mounts'], cause}, isFallbackArmed,
    });
    assertEqual({
        timings: wiring.CockpitApplyTiming, isFrozen: Object.isFrozen(wiring.CockpitApplyTiming),
        read: [effect(READ, false), effect(READ, true)],
        changed: [effect(CHANGED, false), effect(CHANGED, true)],
        pull: [effect(PULL, false), effect(PULL, true)],
    }, {
        timings: {NOW, NEXT_TICK, NEXT_TICK_WITH_FALLBACK, NEVER}, isFrozen: true,
        read: [{timing: NOW, sourceNames: ['network', 'mounts']}, {timing: NOW, sourceNames: ['network', 'mounts']}],
        changed: [
            {timing: NEXT_TICK_WITH_FALLBACK, sourceNames: ['network', 'mounts']},
            {timing: NEXT_TICK, sourceNames: ['network', 'mounts']},
        ],
        pull: [
            {timing: NEXT_TICK_WITH_FALLBACK, sourceNames: ['network', 'mounts']},
            {timing: NEXT_TICK, sourceNames: ['network', 'mounts']},
        ],
    });
});

test('cockpitWiring: a state event touches every source: VANISHED waits for the next tick with the pending sources, ' +
    'LIVE (a service back) is drawn at once, STARTING and SKIPPED draw nothing, and a layout event draws nothing ' +
    '(the layer is rebuilt from it)', () => {
    const stateEffect = state => wiring.cockpitEventEffect({event: {type: STATE_EVENT, state}, isFallbackArmed: false});
    assertEqual({
        vanished: stateEffect(VANISHED), live: stateEffect(LIVE), starting: stateEffect(STARTING),
        skipped: stateEffect(SKIPPED),
        layout: wiring.cockpitEventEffect({
            event: {type: LAYOUT_EVENT, layout: LAYOUT, configError: null}, isFallbackArmed: false,
        }),
    }, {
        vanished: {timing: NEXT_TICK_WITH_FALLBACK, sourceNames: ALL_SOURCE_NAMES},
        live: {timing: NOW, sourceNames: ALL_SOURCE_NAMES},
        starting: {timing: NEVER, sourceNames: []}, skipped: {timing: NEVER, sourceNames: []},
        layout: {timing: NEVER, sourceNames: []},
    });
});

test('cockpitWiring: the cards a source touches are the drawn cards that draw it, in drawn order', () => {
    const drawnCardIds = ['system', 'apps', 'connections', 'sessions'];
    const touched = sourceNames => wiring.cockpitCardIdsDrawing({drawnCardIds, sourceNames});
    assertEqual({
        mounts: touched(['mounts']), sessionsAndNetwork: touched(['sessions', 'network']), none: touched([]),
        all: touched(ALL_SOURCE_NAMES),
        sessionsNotDrawn: wiring.cockpitCardIdsDrawing({drawnCardIds: ['system', 'apps'], sourceNames: ['sessions']}),
    }, {
        mounts: ['connections'], sessionsAndNetwork: ['connections', 'sessions'], none: [],
        all: ['connections', 'sessions'], sessionsNotDrawn: [],
    });
});

test('cockpitWiring: a data card draws no data while the service is gone or any of its sources is stale, since its ' +
    'oldest stamp (none when a source has none); otherwise it draws its sources', () => {
    const drawing = (clientState, sources) => wiring.cockpitDataCardDrawing({clientState, sources});
    const fresh = {sampledAtUsec: LATER_SAMPLED_AT_USEC, isStale: false};
    const older = {sampledAtUsec: SAMPLED_AT_USEC, isStale: false};
    const stale = {sampledAtUsec: LATER_SAMPLED_AT_USEC, isStale: true};
    const neverSampled = {sampledAtUsec: null, isStale: true};
    assertEqual({
        live: drawing(LIVE, [fresh, older]),
        vanished: drawing(VANISHED, [fresh, older]),
        oneStale: drawing(LIVE, [stale, older]),
        neverSampled: drawing(STARTING, [neverSampled]),
        vanishedWithOneNeverSampled: drawing(VANISHED, [fresh, {sampledAtUsec: null, isStale: true}]),
    }, {
        live: {isNoData: false, noDataSinceUsec: null},
        vanished: {isNoData: true, noDataSinceUsec: SAMPLED_AT_USEC},
        oneStale: {isNoData: true, noDataSinceUsec: SAMPLED_AT_USEC},
        neverSampled: {isNoData: true, noDataSinceUsec: null},
        vanishedWithOneNeverSampled: {isNoData: true, noDataSinceUsec: null},
    });
});

test('cockpitWiring: a tick pulls on suspicion every cockpit source a drawn card draws, once each in protocol order, ' +
    'only while the subscription is wanted', () => {
    const toPull = (drawnCardIds, isSubscriptionWanted) =>
        wiring.cockpitSourceNamesToPull({drawnCardIds, isSubscriptionWanted});
    assertEqual({
        everyCard: toPull(['system', 'apps', 'connections', 'sessions'], true),
        sessionsBeforeConnections: toPull(['sessions', 'connections'], true),
        connectionsOnly: toPull(['connections'], true),
        snapshotCardsOnly: toPull(['system', 'apps'], true),
        notWanted: toPull(['system', 'apps', 'connections', 'sessions'], false),
    }, {
        everyCard: ALL_SOURCE_NAMES, sessionsBeforeConnections: ALL_SOURCE_NAMES,
        connectionsOnly: ['network', 'mounts'], snapshotCardsOnly: [], notWanted: [],
    });
});

test('cockpitWiring: a frozen card is due its dimmed repaint 30 s after its last paint, not before; a card drawing ' +
    'cockpit sources only while the subscription is held (ruling D18), the sampler\'s cards always', () => {
    const due = (secondsSincePaint, isCockpitSubscriptionWanted, extraUsec = 0) => wiring.frozenCardsDueRepaint({
        frozenPaintedAtUsecByCardId: {system: FROZEN_AT_USEC, apps: FROZEN_AT_USEC, sessions: FROZEN_AT_USEC},
        nowUsec: FROZEN_AT_USEC + secondsSincePaint * USEC_PER_SECOND + extraUsec,
        isCockpitSubscriptionWanted,
    });
    assertEqual({
        justBefore: due(FROZEN_REPAINT_SECONDS, true, -ONE_USEC),
        atInterval: due(FROZEN_REPAINT_SECONDS, true),
        atIntervalWithoutSubscription: due(FROZEN_REPAINT_SECONDS, false),
        noneFrozen: wiring.frozenCardsDueRepaint({
            frozenPaintedAtUsecByCardId: {}, nowUsec: FROZEN_AT_USEC, isCockpitSubscriptionWanted: true,
        }),
    }, {
        justBefore: [], atInterval: ['system', 'apps', 'sessions'], atIntervalWithoutSubscription: ['system', 'apps'],
        noneFrozen: [],
    });
});

test('cockpitWiring: the dropdown\'s sessions item is shown only once the cockpit has answered (ruling D23): LIVE ' +
    'and VANISHED, never STARTING (no answer yet) or SKIPPED (no cockpit: the dropdown stays v2\'s)', () => {
    const clientStates = [STARTING, SKIPPED, LIVE, VANISHED];
    assertEqual(clientStates.map(clientState => wiring.isDropdownSessionsItemShown?.(clientState)),
        [false, false, true, true]);
});
