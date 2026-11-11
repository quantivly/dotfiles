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
const USEC_PER_SECOND = 1_000_000;
/** FROZEN_REPAINT_INTERVAL_SECONDS (30), written out. */
const FROZEN_REPAINT_SECONDS = 30;
const FROZEN_AT_USEC = 5_000_000_000;
const ONE_USEC = 1;
const SAMPLED_AT_USEC = 1_794_000_001_000_000;
const LATER_SAMPLED_AT_USEC = 1_794_000_031_000_000;

test('cockpitWiring: the card ids, the sampler\'s cards and each card\'s cockpit sources are constants: system and ' +
    'apps draw no cockpit source, connections draws network and mounts, sessions sessions', () => {
    const {COCKPIT_SYSTEM_CARD_ID, COCKPIT_SNAPSHOT_CARD_IDS, COCKPIT_SOURCE_NAMES_BY_CARD_ID} = constantsModule;
    assertEqual({
        systemCardId: COCKPIT_SYSTEM_CARD_ID, snapshotCardIds: COCKPIT_SNAPSHOT_CARD_IDS,
        sourceNamesByCardId: COCKPIT_SOURCE_NAMES_BY_CARD_ID,
        areFrozen: [COCKPIT_SNAPSHOT_CARD_IDS, COCKPIT_SOURCE_NAMES_BY_CARD_ID,
            ...Object.values(COCKPIT_SOURCE_NAMES_BY_CARD_ID ?? {})].map(value => Object.isFrozen(value)),
        fallbackSeconds: constantsModule.COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS,
    }, {
        systemCardId: 'system', snapshotCardIds: ['system', 'apps'],
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
        wiring.cockpitLayerChange({isLayerShown, clientState, layout, isLayoutEvent});
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
