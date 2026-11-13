// cockpitSourceDrawing.js under plain gjs, on fakes: the one pacing the cockpit's layer and the dropdown's sessions
// card share (ruling D22: a read drawn at once, a Changed or a pull on the next Sample, the one-shot fallback for a
// silent sampler, the suspicion pulls of a Sample, reset and destroy), and the one data-card drawing ("no data since
// HH:MM" for a stale source or a vanished service, else the card's own update).
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// Read through the namespace, so a missing export fails its row rather than the whole run.
import * as sourceDrawingModule from '../extensions/resource-pulse@dotfiles/cockpitSourceDrawing.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';

/** The client's event types, sources causes and states, written out. */
const SOURCES_EVENT = 'sources';
const STATE_EVENT = 'state';
const LAYOUT_EVENT = 'layout';
const READ = 'read';
const CHANGED = 'changed';
const PULL = 'pull';
const LIVE = 'live';
const VANISHED = 'vanished';
const STARTING = 'starting';
const SKIPPED = 'skipped';
/** COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS (3), written out. */
const FALLBACK_SECONDS = 3;
/**
 * Where a real fallback's ready time may fall, from now: GLib.timeout_add_seconds coalesces it to the second (moving
 * it by less than a second, by a perturbation fixed per session), so a 3 s timeout is ready more than 2 s and at most
 * 4 s after it is armed, and a timeout of 0 s or 1 s, or of 3 ms, never is.
 */
const FALLBACK_READY_AFTER_MORE_THAN_SECONDS = FALLBACK_SECONDS - 1;
const FALLBACK_READY_AT_MOST_SECONDS = FALLBACK_SECONDS + 1;
const MICROSECONDS_PER_SECOND = 1_000_000;
const FALLBACK_TIMEOUT_NAME = '[resource-pulse] draw the pending cockpit sources';
/** GLib.SOURCE_REMOVE, written out: a one-shot callback's answer. */
const SOURCE_REMOVE = false;
/** The cards the grid draws (every one this release knows) and the one the dropdown draws. */
const GRID_CARD_IDS = ['system', 'apps', 'connections', 'sessions'];
const DROPDOWN_CARD_IDS = ['sessions'];
const SURFACE_NAME = 'the cockpit layer';
/** LOG_PREFIX, written out. */
const LOG_PREFIX = 'resource-pulse:';
const START_USEC = 1_000_000_000;
/** Wall-clock stamps hours apart, so each writes another HH:MM in any time zone. */
const NETWORK_SAMPLED_AT_USEC = 1_794_000_001_000_000;
const MOUNTS_SAMPLED_AT_USEC = NETWORK_SAMPLED_AT_USEC + 3 * 3600 * 1_000_000;
const SESSIONS_SAMPLED_AT_USEC = NETWORK_SAMPLED_AT_USEC + 7 * 3600 * 1_000_000;
/** A stamp GLib.DateTime cannot place (past the year 9999). */
const UNPLACEABLE_REAL_USEC = 1e18;
const SESSIONS_SOURCE = {sampledAtUsec: SESSIONS_SAMPLED_AT_USEC, intervalSeconds: 60, herdrRunning: true, rows: []};
const NETWORK_SOURCE = {sampledAtUsec: NETWORK_SAMPLED_AT_USEC, intervalSeconds: 10, sshMasterCount: 2};
const MOUNTS_SOURCE = {sampledAtUsec: MOUNTS_SAMPLED_AT_USEC, intervalSeconds: 30, rows: []};
const SOURCES = {sessions: SESSIONS_SOURCE, network: NETWORK_SOURCE, mounts: MOUNTS_SOURCE};
const MICROSECONDS_PER_MILLISECOND = 1000;
const CLOCK_DIGITS = 2;

/**
 * The local time of day of a wall-clock stamp, as JavaScript's Date reads the same instant: the oracle the module's
 * GLib.DateTime reading is held to.
 *
 * @param {number} realUsec - Wall-clock microseconds.
 * @returns {string} 'HH:MM'.
 */
function localClockOf(realUsec) {
    const date = new Date(realUsec / MICROSECONDS_PER_MILLISECOND);
    const hours = String(date.getHours()).padStart(CLOCK_DIGITS, '0');
    const minutes = String(date.getMinutes()).padStart(CLOCK_DIGITS, '0');
    return `${hours}:${minutes}`;
}

/**
 * A sources event, as the client tells it.
 *
 * @param {string[]} names - The sources.
 * @param {string} cause - What brought them.
 * @returns {object} The event.
 */
const sourcesEvent = (names, cause) => ({type: SOURCES_EVENT, names, cause});

/**
 * A state event, as the client tells it.
 *
 * @param {string} state - The client's new state.
 * @returns {object} The event.
 */
const stateEvent = state => ({type: STATE_EVENT, state});

/** Fake one-shot timeouts: records each one added and removed; a row fires one by its id. */
class FakeTimeouts {
    constructor() {
        /** @type {Array<{sourceId: number, intervalSeconds: number, timeoutName: string, callback: Function}>} */
        this.added = [];
        this.removedIds = [];
        this.firedIds = [];
        this._nextSourceId = 1;
    }

    /**
     * Adds a named one-shot timeout, as the module's seam does.
     *
     * @param {number} intervalSeconds - Seconds until it fires.
     * @param {string} timeoutName - Its name.
     * @param {() => boolean} callback - What it runs.
     * @returns {number} Its id, counted from 1.
     */
    addSeconds(intervalSeconds, timeoutName, callback) {
        const sourceId = this._nextSourceId++;
        this.added.push({sourceId, intervalSeconds, timeoutName, callback});
        return sourceId;
    }

    /**
     * Removes a timeout.
     *
     * @param {number} sourceId - Its id.
     * @returns {void}
     */
    remove(sourceId) {
        this.removedIds.push(sourceId);
    }

    /**
     * Fires a timeout that was added and neither removed nor fired.
     *
     * @param {number} sourceId - Its id.
     * @returns {boolean} What its callback answered.
     * @throws {Error} For a timeout that cannot fire.
     */
    fire(sourceId) {
        if (!this.armedIds.includes(sourceId))
            throw new Error(`timeout ${sourceId} is not armed`);
        this.firedIds.push(sourceId);
        return this.added.find(timeout => timeout.sourceId === sourceId).callback();
    }

    /** @returns {number[]} The ids added and neither removed nor fired. */
    get armedIds() {
        return this.added.map(timeout => timeout.sourceId)
            .filter(sourceId => !this.removedIds.includes(sourceId) && !this.firedIds.includes(sourceId));
    }
}

/**
 * A pacing on fakes: every card draw and every pull is one line of `calls`, in order.
 *
 * @param {object} [options] - The surface.
 * @param {string[]} [options.drawnCardIds] - The cards it draws.
 * @param {((cardId: string) => void)|null} [options.drawCard] - Draws a card instead of recording it.
 * @returns {{pacing: object, timeouts: FakeTimeouts, calls: string[], loggedLines: string[]}} The fixture.
 */
function makePacingFixture({drawnCardIds = GRID_CARD_IDS, drawCard = null} = {}) {
    const timeouts = new FakeTimeouts();
    const calls = [];
    const loggedLines = [];
    const cockpitClient = {
        pullIfSuspicious: sourceName => {
            calls.push(`pull ${sourceName}`);
            return Promise.resolve({pulled: true});
        },
    };
    const errorLog = new RateLimitedLogger({nowUsec: () => START_USEC, write: line => loggedLines.push(line)});
    const pacing = new sourceDrawingModule.CockpitSourcePacing({
        cockpitClient,
        drawnCardIds: () => drawnCardIds,
        drawCard: drawCard ?? (cardId => calls.push(`draw ${cardId}`)),
        errorLog,
        surfaceName: SURFACE_NAME,
        timeouts,
    });
    return {pacing, timeouts, calls, loggedLines};
}

/** The pacing's Sample with no suspicion pulls, for the rows about drawing only. */
const SAMPLE_WITHOUT_PULLS = Object.freeze({isSubscriptionWanted: false});

test('cockpitSourceDrawing: a read is drawn at once, the cards that draw its sources in drawn order and no other; a ' +
    'LIVE state draws every data card at once; nothing waits for the Sample and no fallback is armed; a layout, ' +
    'STARTING or SKIPPED draws nothing', () => {
    const {pacing, timeouts, calls} = makePacingFixture();
    const drawnBy = event => {
        const callCountBefore = calls.length;
        pacing.onCockpitEvent(event);
        return calls.slice(callCountBefore);
    };
    const drawn = {
        sessionsRead: drawnBy(sourcesEvent(['sessions'], READ)),
        mountsAndSessionsRead: drawnBy(sourcesEvent(['mounts', 'sessions'], READ)),
        live: drawnBy(stateEvent(LIVE)),
        others: [
            drawnBy({type: LAYOUT_EVENT, layout: null, configError: null}), drawnBy(stateEvent(STARTING)),
            drawnBy(stateEvent(SKIPPED)),
        ],
    };
    const callCountBeforeSample = calls.length;
    pacing.onSample(SAMPLE_WITHOUT_PULLS);
    assertEqual({drawn, onTheSample: calls.slice(callCountBeforeSample), armed: timeouts.added.length}, {
        drawn: {
            sessionsRead: ['draw sessions'], mountsAndSessionsRead: ['draw connections', 'draw sessions'],
            live: ['draw connections', 'draw sessions'], others: [[], [], []],
        },
        onTheSample: [], armed: 0,
    });
});

test('cockpitSourceDrawing: a Changed waits for the next Sample: nothing is drawn at the event, one named one-shot ' +
    'fallback of COCKPIT_CHANGED_APPLY_FALLBACK_SECONDS is armed (a pull\'s answer that follows waits too and arms ' +
    'no second), then the Sample draws each waiting card once and removes the fallback, and the next Sample draws ' +
    'nothing', () => {
    const {pacing, timeouts, calls} = makePacingFixture();
    pacing.onCockpitEvent(sourcesEvent(['sessions'], CHANGED));
    pacing.onCockpitEvent(sourcesEvent(['network'], PULL));
    const atTheEvents = [...calls];
    const armed = timeouts.added.map(({intervalSeconds, timeoutName}) => ({intervalSeconds, timeoutName}));
    pacing.onSample(SAMPLE_WITHOUT_PULLS);
    const onTheSample = [...calls];
    const removedOnTheSample = [...timeouts.removedIds];
    pacing.onSample(SAMPLE_WITHOUT_PULLS);
    assertEqual({atTheEvents, armed, onTheSample, removedOnTheSample, onTheNextSample: calls.slice(onTheSample.length)},
        {
            atTheEvents: [], armed: [{intervalSeconds: FALLBACK_SECONDS, timeoutName: FALLBACK_TIMEOUT_NAME}],
            onTheSample: ['draw connections', 'draw sessions'], removedOnTheSample: [1], onTheNextSample: [],
        });
});

test('cockpitSourceDrawing: with no Sample the fallback draws what waits, once (a VANISHED state waits like a ' +
    'Changed, for every data card): it returns SOURCE_REMOVE having forgotten its id, so no Sample removes a timeout ' +
    'that already ended and none draws it again; the next Changed arms a new one', () => {
    const {pacing, timeouts, calls} = makePacingFixture();
    pacing.onCockpitEvent(stateEvent(VANISHED));
    pacing.onCockpitEvent(sourcesEvent(['sessions'], CHANGED));
    const armedBeforeTheFallback = timeouts.armedIds;
    const fallbackAnswer = timeouts.fire(1);
    const byTheFallback = [...calls];
    pacing.onSample(SAMPLE_WITHOUT_PULLS);
    const onTheSampleAfter = calls.slice(byTheFallback.length);
    pacing.onCockpitEvent(sourcesEvent(['sessions'], CHANGED));
    assertEqual({
        armedBeforeTheFallback, fallbackAnswer, byTheFallback, onTheSampleAfter, removedIds: timeouts.removedIds,
        armedAfterTheNextChanged: timeouts.armedIds,
    }, {
        armedBeforeTheFallback: [1], fallbackAnswer: SOURCE_REMOVE,
        byTheFallback: ['draw connections', 'draw sessions'],
        onTheSampleAfter: [], removedIds: [], armedAfterTheNextChanged: [2],
    });
});

test('cockpitSourceDrawing: reset() forgets what waits and removes the fallback, so the next Sample draws nothing; ' +
    'destroy() does the same for good: after it no event or Sample draws, arms or pulls', () => {
    const {pacing, timeouts, calls} = makePacingFixture();
    pacing.onCockpitEvent(sourcesEvent(['sessions'], CHANGED));
    pacing.reset();
    const removedByReset = [...timeouts.removedIds];
    pacing.onSample(SAMPLE_WITHOUT_PULLS);
    const onTheSampleAfterReset = [...calls];
    pacing.onCockpitEvent(sourcesEvent(['sessions'], CHANGED));
    pacing.destroy();
    const removedByDestroy = timeouts.removedIds.slice(removedByReset.length);
    pacing.onCockpitEvent(sourcesEvent(['sessions'], READ));
    pacing.onCockpitEvent(sourcesEvent(['network'], CHANGED));
    pacing.onSample({isSubscriptionWanted: true});
    assertEqual({
        removedByReset, onTheSampleAfterReset, removedByDestroy, afterDestroy: calls, added: timeouts.added.length,
    }, {removedByReset: [1], onTheSampleAfterReset: [], removedByDestroy: [2], afterDestroy: [], added: 2});
});

test('cockpitSourceDrawing: a Sample first draws what waits, then pulls on suspicion each source its cards draw, in ' +
    'COCKPIT_SOURCE_NAMES order, while the subscription is wanted, and none while it is not; the dropdown\'s one ' +
    'card pulls sessions only', () => {
    const grid = makePacingFixture();
    grid.pacing.onCockpitEvent(sourcesEvent(['sessions'], CHANGED));
    grid.pacing.onSample({isSubscriptionWanted: true});
    const whileWanted = [...grid.calls];
    grid.pacing.onSample(SAMPLE_WITHOUT_PULLS);
    const dropdown = makePacingFixture({drawnCardIds: DROPDOWN_CARD_IDS});
    dropdown.pacing.onSample({isSubscriptionWanted: true});
    assertEqual({whileWanted, whileNotWanted: grid.calls.slice(whileWanted.length), dropdown: dropdown.calls}, {
        whileWanted: ['draw sessions', 'pull sessions', 'pull network', 'pull mounts'], whileNotWanted: [],
        dropdown: ['pull sessions'],
    });
});

test('cockpitSourceDrawing: one Changed of sessions with both the grid and the open dropdown drawing it (Review ' +
    'Focus 2): neither draws at the event, each draws its own sessions card exactly once on its Sample (the grid\'s ' +
    'copy, frozen under a window, only records it: the card\'s rule), a second Sample of either draws nothing, and ' +
    'no fallback is left armed', () => {
    const grid = makePacingFixture();
    const dropdown = makePacingFixture({drawnCardIds: DROPDOWN_CARD_IDS});
    const changed = sourcesEvent(['sessions'], CHANGED);
    grid.pacing.onCockpitEvent(changed);
    dropdown.pacing.onCockpitEvent(changed);
    const drawnAtTheEvent = [...grid.calls, ...dropdown.calls];
    for (const surface of [dropdown, grid, dropdown, grid])
        surface.pacing.onSample(SAMPLE_WITHOUT_PULLS);
    assertEqual({
        drawnAtTheEvent, grid: grid.calls, dropdown: dropdown.calls,
        armed: [grid.timeouts.armedIds, dropdown.timeouts.armedIds],
    }, {drawnAtTheEvent: [], grid: ['draw sessions'], dropdown: ['draw sessions'], armed: [[], []]});
});

test('cockpitSourceDrawing: a fallback whose draw throws never throws out of its callback: it answers SOURCE_REMOVE ' +
    'and writes one journal line naming the surface, rate-limited by that context however the error text varies; ' +
    'what waited is not drawn again by the next Sample', () => {
    let drawAttemptCount = 0;
    const {pacing, timeouts, loggedLines} = makePacingFixture({
        drawCard: () => {
            drawAttemptCount++;
            throw new Error(`the card is gone (attempt ${drawAttemptCount})`);
        },
    });
    const fallbackAnswers = [];
    for (const sourceId of [1, 2]) {
        pacing.onCockpitEvent(sourcesEvent(['sessions'], CHANGED));
        fallbackAnswers.push(timeouts.fire(sourceId));
    }
    pacing.onSample(SAMPLE_WITHOUT_PULLS);
    assertEqual({fallbackAnswers, drawAttemptCount, firstLines: loggedLines.map(line => line.split('\n')[0])}, {
        fallbackAnswers: [SOURCE_REMOVE, SOURCE_REMOVE], drawAttemptCount: 2,
        firstLines: [
            `${LOG_PREFIX} could not draw the pending cockpit sources of ${SURFACE_NAME}: the card is gone (attempt 1)`,
        ],
    });
});

test('cockpitSourceDrawing: the default timeouts are GLib\'s: a Changed arms a real source of the default priority, ' +
    'named, ready in the fallback\'s 3 s (more than 2 s and at most 4 s from now: GLib coalesces a seconds timeout ' +
    'to the second), and destroy() removes it from the main context', () => {
    const pacing = new sourceDrawingModule.CockpitSourcePacing({
        cockpitClient: {pullIfSuspicious: () => Promise.resolve({pulled: false})}, drawnCardIds: () => GRID_CARD_IDS,
        drawCard: () => {}, errorLog: new RateLimitedLogger({nowUsec: () => START_USEC, write: () => {}}),
        surfaceName: SURFACE_NAME,
    });
    try {
        pacing.onCockpitEvent(sourcesEvent(['sessions'], CHANGED));
        const sourceId = pacing._fallbackSourceId;
        const armedSource = GLib.MainContext.default().find_source_by_id(sourceId);
        const secondsUntilReady = armedSource === null ? null
            : (armedSource.get_ready_time() - GLib.get_monotonic_time()) / MICROSECONDS_PER_SECOND;
        const armed = {
            name: armedSource?.get_name() ?? null, priority: armedSource?.get_priority() ?? null,
            isReadyInTheFallbackSeconds: secondsUntilReady > FALLBACK_READY_AFTER_MORE_THAN_SECONDS &&
                secondsUntilReady <= FALLBACK_READY_AT_MOST_SECONDS,
        };
        pacing.destroy();
        const isGoneAfterDestroy = GLib.MainContext.default().find_source_by_id(sourceId) === null;
        assertEqual({armed, isGoneAfterDestroy}, {
            armed: {name: FALLBACK_TIMEOUT_NAME, priority: GLib.PRIORITY_DEFAULT, isReadyInTheFallbackSeconds: true},
            isGoneAfterDestroy: true,
        });
    } finally {
        pacing.destroy();
    }
});

/** A data card that records each update and each no-data line. */
class FakeDataCard {
    constructor() {
        this.updates = [];
        this.noDataTexts = [];
    }

    /**
     * Records an update.
     *
     * @param {...*} sources - What the card was given.
     * @returns {void}
     */
    update(...sources) {
        this.updates.push(sources);
    }

    /**
     * Records a no-data line.
     *
     * @param {string} text - The line.
     * @returns {void}
     */
    showNoData(text) {
        this.noDataTexts.push(text);
    }
}

/**
 * What a data card is drawn with, for one cockpit client.
 *
 * @param {object} client - The client's reading.
 * @param {string} client.cardId - The card's id.
 * @param {string} client.state - The client's state.
 * @param {string[]} [client.staleSourceNames] - The sources sourceFreshness calls stale.
 * @param {object} [client.sourcesByName] - The sources it holds.
 * @returns {{updates: Array, noDataTexts: string[]}} What the card was given.
 */
function drawnDataCard({cardId, state, staleSourceNames = [], sourcesByName = SOURCES}) {
    const card = new FakeDataCard();
    const cockpitClient = {
        state,
        get sourcesByName() {
            return {...sourcesByName};
        },
        sourceFreshness: sourceName =>
            ({isStale: staleSourceNames.includes(sourceName), shouldPull: false, ageSeconds: 0}),
    };
    sourceDrawingModule.drawCockpitDataCard({cardId, card, cockpitClient});
    return {updates: card.updates, noDataTexts: card.noDataTexts};
}

test('cockpitSourceDrawing: drawCockpitDataCard gives a LIVE card its fresh sources through its own update (sessions ' +
    'its sessions; connections its network, then its mounts); while one of its sources is stale or the service is ' +
    'gone, "no data since" the oldest stamp of its sources in local time, and a plain "no data" when one has ' +
    'none', () =>
    assertEqual({
        sessions: drawnDataCard({cardId: 'sessions', state: LIVE}),
        connections: drawnDataCard({cardId: 'connections', state: LIVE}),
        mountsStale: drawnDataCard({cardId: 'connections', state: LIVE, staleSourceNames: ['mounts']}),
        vanished: drawnDataCard({cardId: 'sessions', state: VANISHED}),
        noStamp: drawnDataCard({
            cardId: 'sessions', state: LIVE, staleSourceNames: ['sessions'],
            sourcesByName: {...SOURCES, sessions: null},
        }),
    }, {
        sessions: {updates: [[SESSIONS_SOURCE]], noDataTexts: []},
        connections: {updates: [[NETWORK_SOURCE, MOUNTS_SOURCE]], noDataTexts: []},
        mountsStale: {updates: [], noDataTexts: [`no data since ${localClockOf(NETWORK_SAMPLED_AT_USEC)}`]},
        vanished: {updates: [], noDataTexts: [`no data since ${localClockOf(SESSIONS_SAMPLED_AT_USEC)}`]},
        noStamp: {updates: [], noDataTexts: ['no data']},
    }));

test('cockpitSourceDrawing: formatClockLabel writes a wall-clock stamp as its local HH:MM (as Date reads the same ' +
    'instant), and a stamp GLib cannot place as an empty time', () => {
    const stamps = [NETWORK_SAMPLED_AT_USEC, MOUNTS_SAMPLED_AT_USEC, SESSIONS_SAMPLED_AT_USEC];
    assertEqual({
        labels: stamps.map(realUsec => sourceDrawingModule.formatClockLabel?.(realUsec)),
        unplaceable: sourceDrawingModule.formatClockLabel?.(UNPLACEABLE_REAL_USEC),
    }, {labels: stamps.map(localClockOf), unplaceable: ''});
});
