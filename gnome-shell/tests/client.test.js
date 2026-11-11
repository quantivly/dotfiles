// pulseClient.js with a fake link to the service (in place of serviceLink.js), fake timeouts and a fake StartUnit, so
// every row runs under plain gjs, on no bus at all, in a fixed order: each fake answers only when a row tells it to.
// The payloads are built with lib/protocol.js's builders, as the real service builds them. The real link and the real
// StartUnit are exercised on a private bus by client-dbus.test.js.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// Read through the namespace, so a missing export fails its row rather than the whole run.
import * as pulseClientModule from '../extensions/resource-pulse@dotfiles/pulseClient.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';
import {cardText} from '../extensions/resource-pulse@dotfiles/lib/format.js';
import {buildSamplePayload, buildStatePayload} from '../extensions/resource-pulse@dotfiles/lib/protocol.js';

const USEC_PER_SECOND = 1_000_000;
const SAMPLE_INTERVAL_SECONDS = 2;
const SAMPLE_INTERVAL_USEC = SAMPLE_INTERVAL_SECONDS * USEC_PER_SECOND;
/** SAMPLE_STALL_TICKS (3) × SAMPLE_INTERVAL_SECONDS: the design's 6 s, written out. */
const STALL_USEC = 6 * USEC_PER_SECOND;
/** SAMPLE_STALL_MS: the same 6 s in the milliseconds the stall watchdog is armed for, written out. */
const STALL_MS = 6000;
const ONE_MICROSECOND = 1;
/** START_CONFIRMATION_TIMEOUT_SECONDS (15), written out: how long an accepted StartUnit waits for the service. */
const START_CONFIRMATION_SECONDS = 15;
const START_USEC = 1_000_000_000;
/** Well past any staleness, for rows that wait out the clock. */
const LONG_WAIT_USEC = 60 * USEC_PER_SECOND;
const OWNER = ':1.42';
const NEXT_OWNER = ':1.77';
/** Stands in for the session bus connection: the client only hands it to createLink and startUnit. */
const FAKE_CONNECTION = {isFakeConnection: true};
const SERVICE_STARTED_AT_USEC = 1_794_000_000_000_000;
const SAMPLED_AT_USEC = 1_794_000_002_000_000;
const STATE_REPLY_SIGNATURE = '(s)';
const SAMPLE_SIGNAL_SIGNATURE = '(s)';
const GET_STATE = 'GetState';
const WATCH_DETAIL = 'WatchDetail';
const UNWATCH_DETAIL = 'UnwatchDetail';
const SAMPLE_SIGNAL = 'Sample';
const NO_DATA_TEXT = 'no data';
/** The last good time a previous client saw, before a lock or a blank: earlier than any snapshot here. */
const SEEDED_CLOCK_LABEL = '13:58';
/** Array.at's index of the last element. */
const LATEST_ATTEMPT_INDEX = -1;
const FIRST_ATTEMPT_INDEX = 0;

/** The snapshot GetState answers: every field set, taken at START_USEC on the clock both sides share. */
const STATE_SNAPSHOT = {
    takenAtUsec: START_USEC,
    takenAtClockLabel: '14:02',
    cpuBusyPercent: 23.5,
    cpuClusters: {performancePercent: 41, efficiencyPercent: 6},
    memory: {usedBytes: 16_000_000_000, totalBytes: 32_000_000_000},
    swap: {zramUsedBytes: 1_600_000_000, zramRamBytes: 400_000_000, diskBytes: 0},
    pressureAvg10: {cpu: 1.5, memory: 0, io: 0.25},
    apps: {
        topCpu: {groupKey: 'app:org.example.Editor', name: 'Editor', cpuPercent: 31},
        topMemory: {groupKey: 'herdr-server', name: 'herdr agents', memoryBytes: 15_700_000_000},
        cpuRanking: [{groupKey: 'app:org.example.Editor', name: 'Editor', cpuPercent: 31}],
        memoryRanking: [{groupKey: 'herdr-server', name: 'herdr agents', memoryBytes: 15_700_000_000}],
    },
    isComplete: true,
};
const STATE_HISTORIES = {cpu: [0.25, null, 0.5], memory: [0.6, 0.61, null]};
const STATE_SEQUENCE = 7;
/** The next fast tick's snapshot, a minute later. */
const TICK_SNAPSHOT = {
    ...STATE_SNAPSHOT, takenAtUsec: START_USEC + SAMPLE_INTERVAL_USEC, takenAtClockLabel: '14:03', cpuBusyPercent: 50,
};
const TICK_APPENDED_HISTORY = {cpu: 0.5, memory: 0.25};
/** The tick after that one, a minute later again: another label and another CPU figure. */
const NEXT_TICK_SNAPSHOT = {
    ...TICK_SNAPSHOT, takenAtUsec: START_USEC + 2 * SAMPLE_INTERVAL_USEC, takenAtClockLabel: '14:04',
    cpuBusyPercent: 61,
};
const NEXT_TICK_APPENDED_HISTORY = {cpu: 0.61, memory: 0.26};
/** What a Sample appends when the service's sample had no numbers: a gap in both histories. */
const NUMBERLESS_APPENDED_HISTORY = {cpu: null, memory: null};
/**
 * A snapshot field a row sends missing, so that lib/protocol.js reading it, which it does only while parsing that
 * snapshot, can be counted (countReadsOfMissingField).
 */
const SPIED_SNAPSHOT_FIELD = 'swap';
/** A watch start's reveal: the tick's values with a new ranking, appending nothing. */
const REVEAL_SNAPSHOT = {
    ...TICK_SNAPSHOT,
    apps: {...TICK_SNAPSHOT.apps, topCpu: {groupKey: 'kernel', name: 'kernel', cpuPercent: 12}},
};
/** What a restarted service answers GetState with: a history of its own, numbered from 1 again. */
const RESTARTED_SNAPSHOT = {...STATE_SNAPSHOT, takenAtClockLabel: '14:05', cpuBusyPercent: 9};
const RESTARTED_HISTORIES = {cpu: [0.09], memory: [0.4]};
/** What the service publishes when its sample threw: a time and a label, but no numbers. */
const SERVICE_NO_DATA_SNAPSHOT = {
    takenAtUsec: START_USEC + 2 * SAMPLE_INTERVAL_USEC,
    takenAtClockLabel: '14:04',
    cpuBusyPercent: null,
    cpuClusters: null,
    memory: null,
    swap: null,
    pressureAvg10: {cpu: null, memory: null, io: null},
    apps: null,
    isComplete: false,
};
/** What the client publishes when it has no fresh data: every number null, no ranking. */
const NO_DATA_SNAPSHOT = {
    takenAtUsec: null,
    takenAtClockLabel: null,
    cpuBusyPercent: null,
    cpuClusters: null,
    memory: null,
    swap: null,
    pressureAvg10: {cpu: null, memory: null, io: null},
    apps: null,
    isComplete: false,
};

/** The unit of a fake timeout added with addSeconds (the StartUnit chain). */
const SECONDS_UNIT = 's';
/** The unit of a fake timeout added with addMilliseconds (the stall watchdog). */
const MILLISECONDS_UNIT = 'ms';

/**
 * Fake GLib timeouts: a row fires one by its interval, and sees which are still pending. Whole-second timeouts and
 * millisecond ones are kept apart by unit, so a row asks about one kind at a time.
 */
class FakeTimeouts {
    constructor() {
        this._sourcesById = new Map();
        this._nextSourceId = 1;
        this._addedIntervalsMs = [];
    }

    /**
     * @param {number} intervalSeconds - Seconds until the callback, and between calls while it continues.
     * @param {() => boolean} callback - Returns GLib.SOURCE_CONTINUE or GLib.SOURCE_REMOVE.
     * @returns {number} The source id.
     */
    addSeconds(intervalSeconds, callback) {
        return this._addSource(SECONDS_UNIT, intervalSeconds, callback);
    }

    /**
     * @param {number} intervalMs - Milliseconds until the callback, and between calls while it continues.
     * @param {() => boolean} callback - Returns GLib.SOURCE_CONTINUE or GLib.SOURCE_REMOVE.
     * @returns {number} The source id.
     */
    addMilliseconds(intervalMs, callback) {
        this._addedIntervalsMs.push(intervalMs);
        return this._addSource(MILLISECONDS_UNIT, intervalMs, callback);
    }

    /**
     * @param {number} sourceId - An id addSeconds or addMilliseconds returned.
     * @returns {void}
     * @throws {Error} For an id that is not pending, as GLib.source_remove warns of one.
     */
    remove(sourceId) {
        if (!this._sourcesById.delete(sourceId))
            throw new Error(`removed source ${sourceId}, which is not pending`);
    }

    /** @returns {number[]} The intervals of the pending whole-second sources, smallest first. */
    pendingIntervalsSeconds() {
        return this._pendingIntervals(SECONDS_UNIT);
    }

    /** @returns {number[]} The intervals of the pending millisecond sources, smallest first. */
    pendingIntervalsMs() {
        return this._pendingIntervals(MILLISECONDS_UNIT);
    }

    /**
     * @returns {number[]} Every interval addMilliseconds was given, in order, pending or not: one per watchdog armed,
     *     so a row sees a watchdog armed anew where pendingIntervalsMs alone shows the same interval still pending.
     */
    addedIntervalsMs() {
        return [...this._addedIntervalsMs];
    }

    /**
     * Runs the one pending whole-second source with this interval, as GLib would when it is due.
     *
     * @param {number} intervalSeconds - Its interval.
     * @returns {boolean} What the callback returned.
     * @throws {Error} Unless exactly one pending whole-second source has that interval.
     */
    fire(intervalSeconds) {
        return this._fireOnlySource(SECONDS_UNIT, intervalSeconds);
    }

    /**
     * Runs the one pending millisecond source with this interval, as GLib would when it is due.
     *
     * @param {number} intervalMs - Its interval.
     * @returns {boolean} What the callback returned.
     * @throws {Error} Unless exactly one pending millisecond source has that interval.
     */
    fireMs(intervalMs) {
        return this._fireOnlySource(MILLISECONDS_UNIT, intervalMs);
    }

    /**
     * @param {string} unit - SECONDS_UNIT or MILLISECONDS_UNIT.
     * @param {number} interval - In that unit.
     * @param {() => boolean} callback - The source's callback.
     * @returns {number} The source id.
     */
    _addSource(unit, interval, callback) {
        const sourceId = this._nextSourceId++;
        this._sourcesById.set(sourceId, {unit, interval, callback});
        return sourceId;
    }

    /**
     * @param {string} unit - SECONDS_UNIT or MILLISECONDS_UNIT.
     * @returns {number[]} The intervals of the pending sources of that unit, smallest first.
     */
    _pendingIntervals(unit) {
        const pendingSources = [...this._sourcesById.values()].filter(source => source.unit === unit);
        return pendingSources.map(source => source.interval).sort((a, b) => a - b);
    }

    /**
     * Runs the one pending source of a unit and interval; one that returns anything but GLib.SOURCE_CONTINUE has
     * ended, so a later remove() of its id throws.
     *
     * @param {string} unit - SECONDS_UNIT or MILLISECONDS_UNIT.
     * @param {number} interval - In that unit.
     * @returns {boolean} What the callback returned.
     * @throws {Error} Unless exactly one pending source of that unit has that interval.
     */
    _fireOnlySource(unit, interval) {
        const matchingEntries = [...this._sourcesById]
            .filter(([, source]) => source.unit === unit && source.interval === interval);
        if (matchingEntries.length !== 1)
            throw new Error(`${matchingEntries.length} pending sources of ${interval} ${unit}, not one`);
        const [[sourceId, source]] = matchingEntries;
        const shouldContinue = source.callback();
        if (shouldContinue !== GLib.SOURCE_CONTINUE)
            this._sourcesById.delete(sourceId);
        return shouldContinue;
    }
}

/**
 * A fake link to the service (serviceLink.js's ResourcePulseLink): a row reports the owner and delivers Samples, and
 * answers each call.
 */
class FakeLink {
    /**
     * @param {object} connection - The connection the client passed.
     * @param {{onOwnerChanged: (nameOwner: string|null) => void, onSample: (parameters: GLib.Variant) => void}}
     *     callbacks - The client's.
     */
    constructor(connection, {onOwnerChanged, onSample}) {
        this.connection = connection;
        this._onOwnerChanged = onOwnerChanged;
        this._onSample = onSample;
        this._isSampleSubscribed = true;
        this._isDestroyed = false;
        /** @type {Array<{methodName: string, cancellable: Gio.Cancellable|null, onAnswered: Function,
         *     isAnswered: boolean}>} Every call, in order. */
        this.calls = [];
    }

    /** @returns {boolean} True while Samples are delivered: from creation until destroy(). */
    get isSampleSubscribed() {
        return this._isSampleSubscribed;
    }

    /** @returns {boolean} True once the client has destroyed the link. */
    get isDestroyed() {
        return this._isDestroyed;
    }

    /**
     * Records a call; a row answers it with answer() or fail().
     *
     * @param {string} methodName - The method.
     * @param {Gio.Cancellable|null} cancellable - Its cancellable.
     * @param {(error: Error|null, reply: GLib.Variant|null) => void} onAnswered - Called with the answer.
     * @returns {void}
     */
    call(methodName, cancellable, onAnswered) {
        this.calls.push({methodName, cancellable, onAnswered, isAnswered: false});
    }

    /**
     * Records the destroy and stops the Samples, as the real link's unsubscribe does. Owner reports go on (see
     * setNameOwner).
     *
     * @returns {void}
     */
    destroy() {
        this._isDestroyed = true;
        this._isSampleSubscribed = false;
    }

    /**
     * @param {string} methodName - A method.
     * @returns {object[]} Its calls, in order.
     */
    callsOf(methodName) {
        return this.calls.filter(call => call.methodName === methodName);
    }

    /** @returns {string[]} The method of every call, in order. */
    get calledMethodNames() {
        return this.calls.map(call => call.methodName);
    }

    /**
     * Answers the oldest unanswered call of a method.
     *
     * @param {string} methodName - The method.
     * @param {GLib.Variant|null} reply - The reply.
     * @returns {void}
     */
    answer(methodName, reply) {
        this._settleOldestCall(methodName, {reply, error: null});
    }

    /**
     * Fails the oldest unanswered call of a method.
     *
     * @param {string} methodName - The method.
     * @param {Error} error - The failure.
     * @returns {void}
     */
    fail(methodName, error) {
        this._settleOldestCall(methodName, {reply: null, error});
    }

    /**
     * Reports the bus name's owner, as the name watch does: once when it starts (null when nobody owns the name), then
     * on each change. Reported after destroy() too, so a row sees the client ignore a late report.
     *
     * @param {string|null} nameOwner - The unique name owning the service's name, or null for none.
     * @returns {void}
     */
    setNameOwner(nameOwner) {
        this._onOwnerChanged(nameOwner);
    }

    /**
     * Delivers a Sample's parameters, as the subscription does: only while subscribed.
     *
     * @param {GLib.Variant} parameters - The signal's parameters.
     * @returns {void}
     */
    emitSample(parameters) {
        if (this._isSampleSubscribed)
            this._onSample(parameters);
    }

    /**
     * @param {string} methodName - The method.
     * @param {{reply: GLib.Variant|null, error: Error|null}} result - The answer.
     * @returns {void}
     * @throws {Error} When no call of that method is waiting.
     */
    _settleOldestCall(methodName, {reply, error}) {
        const call = this.calls.find(pendingCall => pendingCall.methodName === methodName && !pendingCall.isAnswered);
        if (call === undefined)
            throw new Error(`no unanswered ${methodName} call`);
        call.isAnswered = true;
        call.onAnswered(error, reply);
    }
}

/** A fake createLink: records each link the client makes. */
class FakeLinkFactory {
    constructor() {
        /** @type {FakeLink[]} Every link made, in order. */
        this.links = [];
        this.createLink = (connection, callbacks) => {
            const link = new FakeLink(connection, callbacks);
            this.links.push(link);
            return link;
        };
    }
}

/** A fake startUnit: records each attempt; a row succeeds or fails the latest. */
class FakeServiceStarter {
    constructor() {
        /** @type {Array<{connection: object, cancellable: Gio.Cancellable, onAnswered: Function}>} */
        this.attempts = [];
        this.startUnit = (connection, cancellable, onAnswered) =>
            this.attempts.push({connection, cancellable, onAnswered});
    }

    /**
     * @param {number} [attemptIndex] - Which attempt answers; the latest by default.
     * @returns {void}
     */
    succeed(attemptIndex = LATEST_ATTEMPT_INDEX) {
        this.attempts.at(attemptIndex).onAnswered(null);
    }

    /**
     * @param {number} [attemptIndex] - Which attempt fails; the latest by default.
     * @returns {void}
     */
    fail(attemptIndex = LATEST_ATTEMPT_INDEX) {
        this.attempts.at(attemptIndex).onAnswered(new GLib.Error(Gio.DBusError, Gio.DBusError.SERVICE_UNKNOWN,
            'The name org.freedesktop.systemd1 was not provided by any .service files'));
    }
}

/**
 * Builds a client on fakes and starts it.
 *
 * @param {object} [options] - The fixture's shape.
 * @param {string|null} [options.nameOwner] - The service's owner when the name watch first reports; null for none.
 * @param {boolean} [options.isOwnerReported] - False to leave the name watch's first report still to come.
 * @param {string|null} [options.lastGoodClockLabel] - The label the extension seeds the client with; none by default.
 * @param {boolean} [options.isDetailWatchWanted] - True to want the detail watch from the start, as the extension does
 *     while the card can be seen, so the snapshot listener (notifications) is told of every Sample drawn. False by
 *     default, as while the card is covered: that listener then hears only states and no data.
 * @returns {object} {client, clock, timeouts, serviceStarter, linkFactory, link, notifications, logged}.
 */
function makeClientFixture({
    nameOwner = OWNER, isOwnerReported = true, lastGoodClockLabel = undefined, isDetailWatchWanted = false,
} = {}) {
    const clock = {nowUsec: START_USEC};
    const timeouts = new FakeTimeouts();
    const serviceStarter = new FakeServiceStarter();
    const linkFactory = new FakeLinkFactory();
    const logged = [];
    const client = new pulseClientModule.PulseClient({
        connection: FAKE_CONNECTION,
        startUnit: serviceStarter.startUnit,
        createLink: linkFactory.createLink,
        nowUsec: () => clock.nowUsec,
        timeouts,
        errorLog: new RateLimitedLogger({nowUsec: () => clock.nowUsec, write: line => logged.push(line)}),
        lastGoodClockLabel,
    });
    const notifications = [];
    client.addListener(snapshot => notifications.push(snapshot));
    // Before start(), as the extension asks: the watch goes out to the owner with its first GetState.
    if (isDetailWatchWanted)
        client.setDetailWatchWanted(true);
    client.start();
    const [link] = linkFactory.links;
    if (isOwnerReported)
        link.setNameOwner(nameOwner);
    return {client, clock, timeouts, serviceStarter, linkFactory, link, notifications, logged};
}

/**
 * Answers the oldest GetState with a state payload.
 *
 * @param {FakeLink} link - The fixture's link.
 * @param {object} state - {snapshot, histories, sequence}.
 * @returns {void}
 */
function answerState(link, {snapshot, histories, sequence}) {
    const statePayload = buildStatePayload({
        snapshot, histories, serviceStartedAtUsec: SERVICE_STARTED_AT_USEC, sequence,
    });
    link.answer(GET_STATE, new GLib.Variant(STATE_REPLY_SIGNATURE, [statePayload]));
}

/**
 * Delivers one Sample signal.
 *
 * @param {FakeLink} link - The fixture's link.
 * @param {object} sample - {snapshot, appendedHistory, sequence}.
 * @returns {void}
 */
function emitSample(link, {snapshot, appendedHistory, sequence}) {
    const samplePayload = buildSamplePayload({snapshot, appendedHistory, sequence, sampledAtUsec: SAMPLED_AT_USEC});
    link.emitSample(new GLib.Variant(SAMPLE_SIGNAL_SIGNATURE, [samplePayload]));
}

/**
 * A started client whose StartUnit succeeded and whose first GetState was answered with STATE_SNAPSHOT,
 * STATE_HISTORIES and STATE_SEQUENCE, at START_USEC.
 *
 * @param {object} [options] - The fixture's shape.
 * @param {boolean} [options.isDetailWatchWanted] - As makeClientFixture's; false by default.
 * @returns {object} makeClientFixture's fixture.
 */
function makeLiveClientFixture({isDetailWatchWanted = false} = {}) {
    const fixture = makeClientFixture({isDetailWatchWanted});
    fixture.serviceStarter.succeed();
    answerState(fixture.link, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    return fixture;
}

/**
 * @param {object} fixture - A fixture.
 * @returns {{cpu: Array<number|null>, memory: Array<number|null>}} The client's histories now.
 */
/**
 * The timeouts a client fixture has pending, by unit.
 *
 * @param {{timeouts: FakeTimeouts}} fixture - A client fixture.
 * @returns {{seconds: number[], ms: number[]}} The intervals of its pending seconds timeouts and millisecond ones.
 */
function pendingTimeoutsOf({timeouts}) {
    return {seconds: timeouts.pendingIntervalsSeconds(), ms: timeouts.pendingIntervalsMs()};
}

function historiesOf({client}) {
    return {cpu: client.cpuHistory.values(), memory: client.memoryHistory.values()};
}

/**
 * Adds a history listener that records the arguments of each call.
 *
 * @param {object} client - The fixture's client.
 * @returns {Array<Array<*>>} One entry per call, filled as the calls come: the arguments it was called with.
 */
function recordHistoryListenerCalls(client) {
    const historyListenerCalls = [];
    client.addHistoryListener((...listenerArguments) => historyListenerCalls.push(listenerArguments));
    return historyListenerCalls;
}

/**
 * Runs a body while every read of one field, from an object that lacks it, is counted: a getter on Object.prototype,
 * removed afterwards whatever the body throws. lib/protocol.js reads each snapshot field only while it parses a
 * snapshot, so for a snapshot sent without that field the count says when, and how often, the client parsed it.
 *
 * @param {string} fieldName - The field sent missing.
 * @param {(fieldReads: {count: number}) => object} body - The row's steps; it reads the count as it goes.
 * @returns {object} What the body returned.
 */
function countReadsOfMissingField(fieldName, body) {
    const fieldReads = {count: 0};
    Object.defineProperty(Object.prototype, fieldName, {
        get() {
            fieldReads.count++;
            return undefined;
        },
        configurable: true,
    });
    try {
        return body(fieldReads);
    } finally {
        delete Object.prototype[fieldName];
    }
}

test('client: before the first state it draws nothing, not even a Sample: no snapshot, no history, no listener call',
    () => {
        const {client, timeouts, link, notifications} = makeClientFixture();
        emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
            sequence: STATE_SEQUENCE + 1});
        emitSample(link, {snapshot: REVEAL_SNAPSHOT, appendedHistory: null, sequence: STATE_SEQUENCE + 2});
        assertEqual({
            latestSnapshot: client.latestSnapshot, histories: historiesOf({client}),
            lastGoodClockLabel: client.lastGoodClockLabel, notificationCount: notifications.length,
            stateCallCount: link.callsOf(GET_STATE).length, pendingMs: timeouts.pendingIntervalsMs(),
        }, {
            // A Sample that waits for a state arms no watchdog either.
            latestSnapshot: null, histories: {cpu: [], memory: []}, lastGoodClockLabel: null, notificationCount: 0,
            stateCallCount: 1, pendingMs: [],
        });
    });

test('client: GetState fills both histories, the latest snapshot and the last good time, and tells listeners once',
    () => {
        const fixture = makeLiveClientFixture();
        assertEqual({
            histories: historiesOf(fixture), latestSnapshot: fixture.client.latestSnapshot,
            lastGoodClockLabel: fixture.client.lastGoodClockLabel, notifications: fixture.notifications,
        }, {
            histories: STATE_HISTORIES, latestSnapshot: STATE_SNAPSHOT, lastGoodClockLabel: '14:02',
            notifications: [STATE_SNAPSHOT],
        });
    });

test('client: a Sample appends its values to both histories and, while the detail watch is wanted, tells listeners ' +
    'its snapshot', () => {
    const fixture = makeLiveClientFixture({isDetailWatchWanted: true});
    emitSample(fixture.link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 1});
    assertEqual({
        histories: historiesOf(fixture), latestSnapshot: fixture.client.latestSnapshot,
        lastGoodClockLabel: fixture.client.lastGoodClockLabel, notifications: fixture.notifications,
    }, {
        histories: {cpu: [...STATE_HISTORIES.cpu, 0.5], memory: [...STATE_HISTORIES.memory, 0.25]},
        latestSnapshot: TICK_SNAPSHOT, lastGoodClockLabel: '14:03', notifications: [STATE_SNAPSHOT, TICK_SNAPSHOT],
    });
});

test('client: a Sample that appends nothing (a watch start\'s reveal: appendedHistory null) is drawn, and adds no ' +
    'history point', () => {
    // Watched, as a reveal answers a watch start.
    const fixture = makeLiveClientFixture({isDetailWatchWanted: true});
    emitSample(fixture.link, {snapshot: REVEAL_SNAPSHOT, appendedHistory: null, sequence: STATE_SEQUENCE + 1});
    assertEqual({histories: historiesOf(fixture), notifications: fixture.notifications},
        {histories: STATE_HISTORIES, notifications: [STATE_SNAPSHOT, REVEAL_SNAPSHOT]});
});

test('client: a sequence that restarts publishes no data once, and draws nothing until a fresh GetState', () => {
    const fixture = makeLiveClientFixture({isDetailWatchWanted: true});
    const {link, notifications} = fixture;
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    emitSample(link, {snapshot: RESTARTED_SNAPSHOT, appendedHistory: {cpu: 0.09, memory: 0.4}, sequence: 1});
    emitSample(link, {snapshot: RESTARTED_SNAPSHOT, appendedHistory: {cpu: 0.1, memory: 0.4}, sequence: 2});
    const notificationsBeforeState = [...notifications];
    answerState(link, {snapshot: RESTARTED_SNAPSHOT, histories: RESTARTED_HISTORIES, sequence: 2});
    const historiesFromState = historiesOf(fixture);
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: 3});
    assertEqual({
        notificationsBeforeState, historiesFromState, notificationsAfter: notifications.slice(3),
        histories: historiesOf(fixture), stateCallCount: link.callsOf(GET_STATE).length,
    }, {
        notificationsBeforeState: [STATE_SNAPSHOT, TICK_SNAPSHOT, NO_DATA_SNAPSHOT],
        historiesFromState: RESTARTED_HISTORIES,
        notificationsAfter: [RESTARTED_SNAPSHOT, TICK_SNAPSHOT],
        histories: {cpu: [0.09, 0.5], memory: [0.4, 0.25]},
        stateCallCount: 2,
    });
});

test('client: a failed StartUnit is retried after 5, 30, 300, then 300 s and logged once; an accepted one then waits ' +
    `${START_CONFIRMATION_SECONDS} s for the service to appear`, () => {
        const {timeouts, serviceStarter, logged} = makeClientFixture({nameOwner: null});
        const retryDelaysSeconds = [];
        for (const _failedAttempt of [1, 2, 3, 4]) {
            serviceStarter.fail();
            const pendingRetryDelaysSeconds = timeouts.pendingIntervalsSeconds();
            retryDelaysSeconds.push(...pendingRetryDelaysSeconds);
            timeouts.fire(pendingRetryDelaysSeconds[0]);
        }
        serviceStarter.succeed();
        assertEqual({
            retryDelaysSeconds, attemptCount: serviceStarter.attempts.length,
            pendingAfterSuccess: timeouts.pendingIntervalsSeconds(),
            startUnitLogLines: logged.filter(line => line.includes('StartUnit')).length,
        }, {
            retryDelaysSeconds: [5, 30, 300, 300], attemptCount: 5,
            pendingAfterSuccess: [START_CONFIRMATION_SECONDS], startUnitLogLines: 1,
        });
    });

test('client: the service appearing ends the StartUnit retries, since it runs: no retry is left pending', () => {
    const {timeouts, serviceStarter, link} = makeClientFixture({nameOwner: null});
    serviceStarter.fail();
    const pendingAfterFailure = timeouts.pendingIntervalsSeconds();
    link.setNameOwner(OWNER);
    assertEqual({
        pendingAfterFailure, pendingAfterOwner: timeouts.pendingIntervalsSeconds(),
        attemptCount: serviceStarter.attempts.length, calledMethodNames: link.calledMethodNames,
    }, {
        pendingAfterFailure: [5], pendingAfterOwner: [], attemptCount: 1, calledMethodNames: [GET_STATE],
    });
});

test('client: the name losing its owner publishes no data once and never calls StartUnit (a stop stays stopped); ' +
    'a new owner is read with GetState and drawn', () => {
    const fixture = makeLiveClientFixture({isDetailWatchWanted: true});
    const {clock, timeouts, serviceStarter, link, notifications} = fixture;
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    link.setNameOwner(null);
    clock.nowUsec += LONG_WAIT_USEC;
    const notificationsWhileGone = [...notifications];
    const pendingWhileGone = timeouts.pendingIntervalsSeconds();
    link.setNameOwner(NEXT_OWNER);
    const returnedSnapshot = {...RESTARTED_SNAPSHOT, takenAtUsec: clock.nowUsec};
    answerState(link, {snapshot: returnedSnapshot, histories: RESTARTED_HISTORIES, sequence: 1});
    assertEqual({
        notificationsWhileGone, pendingWhileGone, attemptCount: serviceStarter.attempts.length,
        notificationsAfterReturn: notifications.slice(notificationsWhileGone.length), histories: historiesOf(fixture),
    }, {
        notificationsWhileGone: [STATE_SNAPSHOT, TICK_SNAPSHOT, NO_DATA_SNAPSHOT], pendingWhileGone: [], attemptCount: 1,
        notificationsAfterReturn: [returnedSnapshot], histories: RESTARTED_HISTORIES,
    });
});

test('client: Samples are drawn although StartUnit failed (no systemd, as in the nested harness), and a StartUnit ' +
    'answered while the service runs, failed or accepted, schedules nothing', () => {
    const fixture = makeClientFixture({isDetailWatchWanted: true});
    const {client, timeouts, serviceStarter, link, notifications} = fixture;
    serviceStarter.fail();
    answerState(link, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    client.start();
    serviceStarter.fail();
    const pendingAfterFailureWhileRunning = timeouts.pendingIntervalsSeconds();
    client.start();
    serviceStarter.succeed();
    assertEqual({
        notifications, histories: historiesOf(fixture), pendingAfterFailureWhileRunning,
        pendingAfterAcceptedWhileRunning: timeouts.pendingIntervalsSeconds(),
    }, {
        notifications: [STATE_SNAPSHOT, TICK_SNAPSHOT],
        histories: {cpu: [...STATE_HISTORIES.cpu, 0.5], memory: [...STATE_HISTORIES.memory, 0.25]},
        pendingAfterFailureWhileRunning: [], pendingAfterAcceptedWhileRunning: [],
    });
});

test('client: an accepted StartUnit with no owner within 15 s is no success: the chain goes on, 5, 30, 300, then ' +
    '300 s after each unconfirmed attempt, and each is logged', () => {
    const {timeouts, serviceStarter, logged} = makeClientFixture({nameOwner: null});
    const confirmationWaitsSeconds = [];
    const retryDelaysSeconds = [];
    for (const _unconfirmedAttempt of [1, 2, 3, 4]) {
        serviceStarter.succeed();
        confirmationWaitsSeconds.push(...timeouts.pendingIntervalsSeconds());
        timeouts.fire(START_CONFIRMATION_SECONDS);
        const pendingRetryDelaysSeconds = timeouts.pendingIntervalsSeconds();
        retryDelaysSeconds.push(...pendingRetryDelaysSeconds);
        timeouts.fire(pendingRetryDelaysSeconds[0]);
    }
    assertEqual({
        confirmationWaitsSeconds, retryDelaysSeconds, attemptCount: serviceStarter.attempts.length,
        hasUnconfirmedLogLine: logged.some(line => line.includes('did not appear')),
    }, {
        confirmationWaitsSeconds: Array(4).fill(START_CONFIRMATION_SECONDS), retryDelaysSeconds: [5, 30, 300, 300],
        attemptCount: 5, hasUnconfirmedLogLine: true,
    });
});

test('client: an owner within 15 s of an accepted StartUnit confirms it and ends the chain, and its later leaving ' +
    'starts nothing', () => {
    const {clock, timeouts, serviceStarter, link} = makeClientFixture({nameOwner: null});
    serviceStarter.succeed();
    const pendingWhileWaiting = timeouts.pendingIntervalsSeconds();
    clock.nowUsec += (START_CONFIRMATION_SECONDS - 1) * USEC_PER_SECOND;
    link.setNameOwner(OWNER);
    const pendingAfterOwner = timeouts.pendingIntervalsSeconds();
    link.setNameOwner(null);
    assertEqual({
        pendingWhileWaiting, pendingAfterOwner, pendingAfterLeaving: timeouts.pendingIntervalsSeconds(),
        attemptCount: serviceStarter.attempts.length,
    }, {
        pendingWhileWaiting: [START_CONFIRMATION_SECONDS], pendingAfterOwner: [], pendingAfterLeaving: [],
        attemptCount: 1,
    });
});

test('client: destroy() while an accepted StartUnit waits for the service leaves no timeout behind', () => {
    const {client, timeouts, serviceStarter} = makeClientFixture({nameOwner: null});
    serviceStarter.succeed();
    const pendingWhileWaiting = timeouts.pendingIntervalsSeconds();
    client.destroy();
    assertEqual({pendingWhileWaiting, pending: timeouts.pendingIntervalsSeconds()},
        {pendingWhileWaiting: [START_CONFIRMATION_SECONDS], pending: []});
});

test('client: a StartUnit still on its way when the service appears is superseded: its failure, after the owner ' +
    'left again, schedules no retry', () => {
    const {timeouts, serviceStarter, link, logged} = makeClientFixture({nameOwner: null});
    link.setNameOwner(OWNER);
    link.setNameOwner(null);
    serviceStarter.fail();
    assertEqual({pending: timeouts.pendingIntervalsSeconds(), attemptCount: serviceStarter.attempts.length,
        startUnitLogLines: logged.filter(line => line.includes('StartUnit')).length},
    {pending: [], attemptCount: 1, startUnitLogLines: 0});
});

test('client: a state whose snapshot was taken more than 6 s before it arrived (a service that answers while its ' +
    'sampler has stopped) shows no data at once, since that snapshot\'s time; the next Sample of the run draws', () => {
    const fixture = makeClientFixture({isDetailWatchWanted: true});
    const {link, notifications} = fixture;
    const staleSnapshot = {...STATE_SNAPSHOT, takenAtUsec: START_USEC - STALL_USEC - ONE_MICROSECOND};
    answerState(link, {snapshot: staleSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    const notificationsAfterState = [...notifications];
    const lastGoodClockLabelAfterState = fixture.client.lastGoodClockLabel;
    const historiesAfterState = historiesOf(fixture);
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    assertEqual({notificationsAfterState, lastGoodClockLabelAfterState, historiesAfterState, notifications}, {
        notificationsAfterState: [NO_DATA_SNAPSHOT], lastGoodClockLabelAfterState: '14:02',
        historiesAfterState: {cpu: [...STATE_HISTORIES.cpu, null], memory: [...STATE_HISTORIES.memory, null]},
        notifications: [NO_DATA_SNAPSHOT, TICK_SNAPSHOT],
    });
});

test('client: freshness counts from the state snapshot\'s own time: taken exactly 6 s before it arrived, it is drawn, ' +
    'and the watchdog shows no data 1 ms later', () => {
    const {timeouts, link, notifications} = makeClientFixture();
    const oldSnapshot = {...STATE_SNAPSHOT, takenAtUsec: START_USEC - STALL_USEC};
    answerState(link, {snapshot: oldSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    const notificationsAtExactlyStall = [...notifications];
    const pendingAtExactlyStall = timeouts.pendingIntervalsMs();
    // Nothing of the stall is left: the shortest watchdog, 1 ms.
    timeouts.fireMs(1);
    assertEqual({notificationsAtExactlyStall, pendingAtExactlyStall, notifications}, {
        notificationsAtExactlyStall: [oldSnapshot], pendingAtExactlyStall: [1],
        notifications: [oldSnapshot, NO_DATA_SNAPSHOT],
    });
});

test('client: a state snapshot with no time counts from its arrival, and one stamped in the future counts from now',
    () => {
        const untimed = makeClientFixture();
        const untimedSnapshot = {...STATE_SNAPSHOT, takenAtUsec: null};
        answerState(untimed.link, {snapshot: untimedSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
        const untimedPending = untimed.timeouts.pendingIntervalsMs();
        untimed.timeouts.fireMs(STALL_MS);
        const future = makeClientFixture();
        const futureSnapshot = {...STATE_SNAPSHOT, takenAtUsec: START_USEC + LONG_WAIT_USEC};
        answerState(future.link, {snapshot: futureSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
        const futurePending = future.timeouts.pendingIntervalsMs();
        future.timeouts.fireMs(STALL_MS);
        assertEqual({
            untimedPending, untimed: untimed.notifications, futurePending, future: future.notifications,
        }, {
            // Both are as old as their arrival: the whole stall is left.
            untimedPending: [STALL_MS], untimed: [untimedSnapshot, NO_DATA_SNAPSHOT],
            futurePending: [STALL_MS], future: [futureSnapshot, NO_DATA_SNAPSHOT],
        });
    });

test('client: a Sample from another version (an unknown field, swap missing) notifies with swap null and every ' +
    'other row intact', () => {
    const fixture = makeLiveClientFixture({isDetailWatchWanted: true});
    const samplePayload = JSON.parse(buildSamplePayload({
        snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1,
        sampledAtUsec: SAMPLED_AT_USEC,
    }));
    delete samplePayload.snapshot.swap;
    samplePayload.snapshot.gpu = {busyPercent: 3};
    samplePayload.servedBy = 'a newer service';
    fixture.link.emitSample(new GLib.Variant(SAMPLE_SIGNAL_SIGNATURE, [JSON.stringify(samplePayload)]));
    const drawnSnapshot = fixture.notifications.at(-1);
    const drawnText = cardText(drawnSnapshot, fixture.client.lastGoodClockLabel);
    const fullText = cardText(TICK_SNAPSHOT, fixture.client.lastGoodClockLabel);
    assertEqual({drawnSnapshot, swapValue: drawnText.swapValue, otherRows: {...drawnText, swapValue: null}}, {
        drawnSnapshot: {...TICK_SNAPSHOT, swap: null}, swapValue: NO_DATA_TEXT, otherRows: {...fullText, swapValue: null},
    });
});

// How each call goes out (asynchronously, to the owner, with DBUS_CALL_TIMEOUT_MS) is the link's, pinned by the link
// rows in client-dbus.test.js.
test('client: WatchDetail and UnwatchDetail go out only when the wanted flag changes, with an owner, and the watch ' +
    'is asserted again to each new owner', () => {
    const {client, link} = makeClientFixture({isOwnerReported: false});
    client.setDetailWatchWanted(true);
    link.setNameOwner(OWNER);
    client.setDetailWatchWanted(true);
    client.setDetailWatchWanted(false);
    client.setDetailWatchWanted(false);
    client.setDetailWatchWanted(true);
    link.setNameOwner(null);
    link.setNameOwner(NEXT_OWNER);
    link.setNameOwner(null);
    client.setDetailWatchWanted(false);
    client.setDetailWatchWanted(true);
    client.setDetailWatchWanted(false);
    link.setNameOwner(OWNER);
    assertEqual(link.calledMethodNames,
        [GET_STATE, WATCH_DETAIL, UNWATCH_DETAIL, WATCH_DETAIL, GET_STATE, WATCH_DETAIL, GET_STATE]);
});

test('client: destroy() releases only a watch still held: none after an UnwatchDetail, none after the owner that ' +
    'held it left', () => {
    const unwatched = makeClientFixture();
    unwatched.client.setDetailWatchWanted(true);
    unwatched.client.setDetailWatchWanted(false);
    unwatched.client.destroy();
    const ownerLeft = makeClientFixture();
    ownerLeft.client.setDetailWatchWanted(true);
    ownerLeft.link.setNameOwner(null);
    ownerLeft.client.setDetailWatchWanted(false);
    ownerLeft.link.setNameOwner(NEXT_OWNER);
    ownerLeft.client.destroy();
    assertEqual({unwatched: unwatched.link.calledMethodNames, ownerLeft: ownerLeft.link.calledMethodNames},
        {unwatched: [GET_STATE, WATCH_DETAIL, UNWATCH_DETAIL], ownerLeft: [GET_STATE, WATCH_DETAIL, GET_STATE]});
});

test('client: destroy() unwatches (uncancellable), cancels the pending GetState, destroys the link, removes its ' +
    'timeouts, and nothing after it (a late reply, a watch change, start()) does anything', () => {
    const {client, timeouts, serviceStarter, link, notifications} = makeClientFixture();
    client.setDetailWatchWanted(true);
    const pendingStateCall = link.callsOf(GET_STATE)[0];
    client.destroy();
    const unwatchCalls = link.callsOf(UNWATCH_DETAIL);
    answerState(link, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    client.setDetailWatchWanted(false);
    client.start();
    assertEqual({
        unwatchCancellables: unwatchCalls.map(call => call.cancellable),
        isStateCallCancelled: pendingStateCall.cancellable?.is_cancelled() ?? null,
        isLinkDestroyed: link.isDestroyed, pending: timeouts.pendingIntervalsSeconds(),
        notificationCount: notifications.length, calledMethodNames: link.calledMethodNames,
        attemptCount: serviceStarter.attempts.length, latestSnapshot: client.latestSnapshot,
    }, {
        unwatchCancellables: [null], isStateCallCancelled: true, isLinkDestroyed: true, pending: [],
        notificationCount: 0, calledMethodNames: [GET_STATE, WATCH_DETAIL, UNWATCH_DETAIL], attemptCount: 1,
        latestSnapshot: null,
    });
});

test('client: destroy() before the name watch first reports destroys the link and removes its StartUnit retry, and ' +
    'an owner reported later is never used', () => {
    const {client, timeouts, serviceStarter, link} = makeClientFixture({isOwnerReported: false});
    serviceStarter.fail();
    const pendingBeforeDestroy = timeouts.pendingIntervalsSeconds();
    client.destroy();
    link.setNameOwner(OWNER);
    assertEqual({
        pendingBeforeDestroy, isLinkDestroyed: link.isDestroyed, calledMethodNames: link.calledMethodNames,
        pending: timeouts.pendingIntervalsSeconds(),
    }, {
        pendingBeforeDestroy: [5], isLinkDestroyed: true, calledMethodNames: [], pending: [],
    });
});

test('client: a Sample of another signature, or text that is not JSON, changes nothing, and each is logged', () => {
    // Watched, so a Sample drawn would show in the notifications.
    const fixture = makeLiveClientFixture({isDetailWatchWanted: true});
    fixture.link.emitSample(new GLib.Variant('(i)', [STATE_SEQUENCE + 1]));
    fixture.link.emitSample(new GLib.Variant(SAMPLE_SIGNAL_SIGNATURE, ['{"sequence": 8,']));
    assertEqual({notifications: fixture.notifications, histories: historiesOf(fixture),
        sampleLogLines: fixture.logged.filter(line => line.includes(SAMPLE_SIGNAL)).length},
    {notifications: [STATE_SNAPSHOT], histories: STATE_HISTORIES, sampleLogLines: 2});
});

test('client: a GetState that fails is logged and leaves no data, and the next Sample asks for the state again', () => {
    const fixture = makeClientFixture({isDetailWatchWanted: true});
    const {link, notifications, logged} = fixture;
    link.fail(GET_STATE, new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.TIMED_OUT, 'Timeout was reached'));
    const stateCallsAfterFailure = link.callsOf(GET_STATE).length;
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    const notificationsBeforeState = notifications.length;
    answerState(link, {snapshot: TICK_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE + 1});
    emitSample(link, {snapshot: REVEAL_SNAPSHOT, appendedHistory: null, sequence: STATE_SEQUENCE + 2});
    assertEqual({
        stateCallsAfterFailure, notificationsBeforeState, stateCallCount: link.callsOf(GET_STATE).length,
        notifications, stateLogLines: logged.filter(line => line.includes(GET_STATE)).length,
    }, {
        stateCallsAfterFailure: 1, notificationsBeforeState: 0, stateCallCount: 2,
        notifications: [TICK_SNAPSHOT, REVEAL_SNAPSHOT], stateLogLines: 1,
    });
});

test('client: every start() asks systemd to start the service again, from a first attempt (a 5 s retry), but connects ' +
    'and follows the service once; only the latest StartUnit\'s answer counts', () => {
    const {client, timeouts, serviceStarter, linkFactory, logged} = makeClientFixture({nameOwner: null});
    client.start();
    serviceStarter.fail(FIRST_ATTEMPT_INDEX);
    const pendingAfterSupersededFailure = timeouts.pendingIntervalsSeconds();
    const loggedAfterSupersededFailure = logged.length;
    serviceStarter.fail();
    assertEqual({
        attemptConnections: serviceStarter.attempts.map(attempt => attempt.connection),
        linkCount: linkFactory.links.length, linkConnection: linkFactory.links[0].connection,
        pendingAfterSupersededFailure, loggedAfterSupersededFailure, pending: timeouts.pendingIntervalsSeconds(),
    }, {
        attemptConnections: [FAKE_CONNECTION, FAKE_CONNECTION], linkCount: 1, linkConnection: FAKE_CONNECTION,
        pendingAfterSupersededFailure: [], loggedAfterSupersededFailure: 0, pending: [5],
    });
});

test('client: no data is published once however many reasons follow: a stall, then a sequence that does not move on ' +
    '(a new run that counted back up to the last one drawn), then the owner leaving', () => {
    const fixture = makeLiveClientFixture();
    const {timeouts, link, notifications} = fixture;
    timeouts.fireMs(STALL_MS);
    emitSample(link, {snapshot: RESTARTED_SNAPSHOT, appendedHistory: {cpu: 0.09, memory: 0.4},
        sequence: STATE_SEQUENCE});
    link.setNameOwner(null);
    assertEqual({notifications, histories: historiesOf(fixture), stateCallCount: link.callsOf(GET_STATE).length}, {
        notifications: [STATE_SNAPSHOT, NO_DATA_SNAPSHOT],
        histories: {cpu: [...STATE_HISTORIES.cpu, null], memory: [...STATE_HISTORIES.memory, null]},
        stateCallCount: 2,
    });
});

test('client: "no data since" moves only with a snapshot that has numbers and a time: not with the service\'s own ' +
    'no-data snapshot, nor with a snapshot that lacks its label', () => {
    const fixture = makeLiveClientFixture();
    emitSample(fixture.link, {snapshot: SERVICE_NO_DATA_SNAPSHOT, appendedHistory: {cpu: null, memory: null},
        sequence: STATE_SEQUENCE + 1});
    const labelAfterServiceNoData = fixture.client.lastGoodClockLabel;
    emitSample(fixture.link, {snapshot: {...TICK_SNAPSHOT, takenAtClockLabel: undefined},
        appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 2});
    assertEqual({
        labelAfterServiceNoData, labelAfterUnlabelled: fixture.client.lastGoodClockLabel,
        latestCpuBusyPercent: fixture.client.latestSnapshot.cpuBusyPercent,
    }, {labelAfterServiceNoData: '14:02', labelAfterUnlabelled: '14:02', latestCpuBusyPercent: 50});
});

test('client: seeded with the previous client\'s last good clock label (the extension keeps it across enables), a ' +
    'new client says "no data since" that time before any data, and good data moves it on', () => {
    const fixture = makeClientFixture({lastGoodClockLabel: SEEDED_CLOCK_LABEL});
    const labelBeforeData = fixture.client.lastGoodClockLabel;
    const cpuTextBeforeData = cardText(fixture.client.latestSnapshot, fixture.client.lastGoodClockLabel).cpuValue;
    fixture.serviceStarter.succeed();
    answerState(fixture.link, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    assertEqual({labelBeforeData, cpuTextBeforeData, labelAfterData: fixture.client.lastGoodClockLabel}, {
        labelBeforeData: SEEDED_CLOCK_LABEL, cpuTextBeforeData: `${NO_DATA_TEXT} since ${SEEDED_CLOCK_LABEL}`,
        labelAfterData: STATE_SNAPSHOT.takenAtClockLabel,
    });
});

test('client: a GetState answer from an owner that has since left is dropped; the new owner\'s state is drawn', () => {
    const fixture = makeClientFixture();
    const {link, notifications} = fixture;
    link.setNameOwner(null);
    // Answered while no owner is on the bus, before the next one has asked for anything.
    answerState(link, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    const notificationsAfterOldAnswer = [...notifications];
    link.setNameOwner(NEXT_OWNER);
    answerState(link, {snapshot: RESTARTED_SNAPSHOT, histories: RESTARTED_HISTORIES, sequence: 1});
    assertEqual({notificationsAfterOldAnswer, notifications, histories: historiesOf(fixture)},
        {notificationsAfterOldAnswer: [], notifications: [RESTARTED_SNAPSHOT], histories: RESTARTED_HISTORIES});
});

test('client: a direct change of owner reads as the old one leaving and the new one arriving: no data once, then ' +
    'the new owner\'s state', () => {
    const fixture = makeLiveClientFixture();
    const {link, notifications} = fixture;
    link.setNameOwner(NEXT_OWNER);
    const notificationsBeforeState = [...notifications];
    answerState(link, {snapshot: RESTARTED_SNAPSHOT, histories: RESTARTED_HISTORIES, sequence: 1});
    assertEqual({notificationsBeforeState, notifications, stateCallCount: link.callsOf(GET_STATE).length}, {
        notificationsBeforeState: [STATE_SNAPSHOT, NO_DATA_SNAPSHOT],
        notifications: [STATE_SNAPSHOT, NO_DATA_SNAPSHOT, RESTARTED_SNAPSHOT],
        stateCallCount: 2,
    });
});

test('client: a listener that throws is logged and the next still runs; a removed one is not called', () => {
    const {client, link, logged} = makeClientFixture();
    const calledListeners = [];
    client.addListener(() => {
        calledListeners.push('throwing');
        throw new Error('listener bug');
    });
    const removedListenerId = client.addListener(() => calledListeners.push('removed'));
    client.addListener(() => calledListeners.push('last'));
    client.removeListener(removedListenerId);
    answerState(link, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    assertEqual({calledListeners, listenerLogLines: logged.filter(line => line.includes('listener bug')).length},
        {calledListeners: ['throwing', 'last'], listenerLogLines: 1});
});

// Two kinds of listener: a history listener (the top bar) is told of every Sample that appended to the histories, a
// snapshot listener (addListener: the cards) only while the detail watch is wanted, and a Sample's snapshot is parsed
// only when something reads it.

test('client: a history listener is told on every Sample; a snapshot listener only while the watch is wanted', () => {
    const {client, link} = makeLiveClientFixture();
    // One log for both kinds, so the order they are told in shows too.
    const listenerCalls = [];
    client.addHistoryListener((...listenerArguments) => listenerCalls.push(['history', ...listenerArguments]));
    client.addListener(snapshot => listenerCalls.push(['snapshot', snapshot.cpuBusyPercent]));
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    emitSample(link, {snapshot: NEXT_TICK_SNAPSHOT, appendedHistory: NEXT_TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 2});
    const callsWhileUnwatched = [...listenerCalls];
    client.setDetailWatchWanted(true);
    const callsOnWanting = listenerCalls.slice(callsWhileUnwatched.length);
    const callCountBeforeWatchedSample = listenerCalls.length;
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 3});
    assertEqual({
        callsWhileUnwatched, callsOnWanting, callsOnWatchedSample: listenerCalls.slice(callCountBeforeWatchedSample),
    }, {
        callsWhileUnwatched: [['history'], ['history']],
        callsOnWanting: [['snapshot', NEXT_TICK_SNAPSHOT.cpuBusyPercent]],
        callsOnWatchedSample: [['history'], ['snapshot', TICK_SNAPSHOT.cpuBusyPercent]],
    });
});

test('client: wanting the detail watch tells snapshot listeners the latest snapshot at once, only when it was not ' +
    'wanted and only while the data is live', () => {
    const {client, link, notifications} = makeLiveClientFixture();
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    emitSample(link, {snapshot: NEXT_TICK_SNAPSHOT, appendedHistory: NEXT_TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 2});
    const notificationCountBeforeWanting = notifications.length;
    client.setDetailWatchWanted(true);
    const toldOnWanting = notifications.slice(notificationCountBeforeWanting);
    client.setDetailWatchWanted(true);
    const notificationCountAfterWantingAgain = notifications.length;
    client.setDetailWatchWanted(false);
    link.setNameOwner(null);
    // With no data the listeners already hold the no-data snapshot.
    client.setDetailWatchWanted(true);
    assertEqual({
        notificationCountBeforeWanting, toldOnWanting, notificationCountAfterWantingAgain,
        toldSinceWantingAgain: notifications.slice(notificationCountAfterWantingAgain),
    }, {
        notificationCountBeforeWanting: 1, toldOnWanting: [NEXT_TICK_SNAPSHOT], notificationCountAfterWantingAgain: 2,
        toldSinceWantingAgain: [NO_DATA_SNAPSHOT],
    });
});

test('client: latestSnapshot is parsed when first read, and is the newest Sample\'s', () => {
    const {client, link} = makeLiveClientFixture();
    const tickSnapshotWithoutSpiedField = {...TICK_SNAPSHOT};
    delete tickSnapshotWithoutSpiedField[SPIED_SNAPSHOT_FIELD];
    const reads = countReadsOfMissingField(SPIED_SNAPSHOT_FIELD, fieldReads => {
        emitSample(link, {snapshot: tickSnapshotWithoutSpiedField, appendedHistory: TICK_APPENDED_HISTORY,
            sequence: STATE_SEQUENCE + 1});
        const parsesOnArrival = fieldReads.count;
        const firstRead = client.latestSnapshot;
        const parsesAfterFirstRead = fieldReads.count;
        const isSecondReadTheSameObject = client.latestSnapshot === firstRead;
        return {parsesOnArrival, firstRead, parsesAfterFirstRead, isSecondReadTheSameObject,
            parsesAfterSecondRead: fieldReads.count};
    });
    assertEqual(reads, {
        parsesOnArrival: 0, firstRead: {...TICK_SNAPSHOT, [SPIED_SNAPSHOT_FIELD]: null}, parsesAfterFirstRead: 1,
        isSecondReadTheSameObject: true, parsesAfterSecondRead: 1,
    });
});

test('client: a reveal\'s Sample, with no appended history, tells no history listener and is still the latest ' +
    'snapshot', () => {
    // Review Focus 5: the reveal arrives while only the top bar is seen, and the card is shown afterwards.
    const fixture = makeLiveClientFixture();
    const {client, link, notifications} = fixture;
    const historyListenerCalls = recordHistoryListenerCalls(client);
    emitSample(link, {snapshot: REVEAL_SNAPSHOT, appendedHistory: null, sequence: STATE_SEQUENCE + 1});
    const notificationsBeforeShown = [...notifications];
    client.setDetailWatchWanted(true);
    assertEqual({
        historyListenerCalls, histories: historiesOf(fixture), notificationsBeforeShown, notifications,
        latestSnapshot: client.latestSnapshot,
    }, {
        historyListenerCalls: [], histories: STATE_HISTORIES, notificationsBeforeShown: [STATE_SNAPSHOT],
        notifications: [STATE_SNAPSHOT, REVEAL_SNAPSHOT], latestSnapshot: REVEAL_SNAPSHOT,
    });
});

test('client: no data is told to both kinds of listener, and names the last unread Sample\'s clock label', () => {
    const {client, link, notifications} = makeLiveClientFixture();
    const historyListenerCalls = recordHistoryListenerCalls(client);
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    emitSample(link, {snapshot: NEXT_TICK_SNAPSHOT, appendedHistory: NEXT_TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 2});
    const historyCallCountBeforeNoData = historyListenerCalls.length;
    const notificationCountBeforeNoData = notifications.length;
    link.setNameOwner(null);
    const lastGoodClockLabel = client.lastGoodClockLabel;
    // Read last: a client that kept the 14:04 Sample unread through no data would hand it out here, as live.
    const {latestSnapshot} = client;
    assertEqual({
        historyCallsOnNoData: historyListenerCalls.slice(historyCallCountBeforeNoData),
        toldOnNoData: notifications.slice(notificationCountBeforeNoData), lastGoodClockLabel, latestSnapshot,
    }, {
        historyCallsOnNoData: [[]], toldOnNoData: [NO_DATA_SNAPSHOT], lastGoodClockLabel: '14:04',
        latestSnapshot: NO_DATA_SNAPSHOT,
    });
});

test('client: isLive is true while Samples are drawn and false with no data', () => {
    const {client, timeouts, link} = makeClientFixture();
    const isLiveBeforeState = client.isLive;
    answerState(link, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    const isLiveAfterState = client.isLive;
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    const isLiveAfterSample = client.isLive;
    timeouts.fireMs(STALL_MS);
    const isLiveWhenStalled = client.isLive;
    emitSample(link, {snapshot: NEXT_TICK_SNAPSHOT, appendedHistory: NEXT_TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 2});
    const isLiveAfterNextSample = client.isLive;
    link.setNameOwner(null);
    assertEqual({
        isLiveBeforeState, isLiveAfterState, isLiveAfterSample, isLiveWhenStalled, isLiveAfterNextSample,
        isLiveWithNoOwner: client.isLive,
    }, {
        isLiveBeforeState: false, isLiveAfterState: true, isLiveAfterSample: true, isLiveWhenStalled: false,
        isLiveAfterNextSample: true, isLiveWithNoOwner: false,
    });
});

test('client: a Sample without numbers leaves "no data since" at the last Sample that had them, read or not', () => {
    const sendNumberedSample = ({link}) => emitSample(link, {snapshot: TICK_SNAPSHOT,
        appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    const sendNumberlessSample = ({link}) => emitSample(link, {snapshot: SERVICE_NO_DATA_SNAPSHOT,
        appendedHistory: NUMBERLESS_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 2});
    // The label first, as extension.js reads it at teardown: on its own, with latestSnapshot not read.
    const labelThenCpu = ({client}) => ({
        lastGoodClockLabel: client.lastGoodClockLabel, cpuBusyPercent: client.latestSnapshot.cpuBusyPercent,
    });
    const unread = makeLiveClientFixture();
    sendNumberedSample(unread);
    sendNumberlessSample(unread);
    const readBetween = makeLiveClientFixture();
    sendNumberedSample(readBetween);
    // Read alone, with the numbered Sample still unread.
    const labelReadBetween = readBetween.client.lastGoodClockLabel;
    sendNumberlessSample(readBetween);
    assertEqual({unread: labelThenCpu(unread), readBetween: labelThenCpu(readBetween), labelReadBetween}, {
        unread: {lastGoodClockLabel: '14:03', cpuBusyPercent: null},
        readBetween: {lastGoodClockLabel: '14:03', cpuBusyPercent: null},
        labelReadBetween: '14:03',
    });
});

// The stall watchdog: one timeout, which each Sample drawn and each fresh state arm anew, so it fires only on silence
// and nothing in the client wakes the shell while Samples flow.

test('client: while Samples flow the watchdog is the only pending timeout, at 6000 ms', () => {
    const fixture = makeLiveClientFixture();
    const {clock, timeouts, link} = fixture;
    const pendingAfterState = pendingTimeoutsOf(fixture);
    clock.nowUsec += SAMPLE_INTERVAL_USEC;
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    const pendingAfterFirstSample = pendingTimeoutsOf(fixture);
    clock.nowUsec += SAMPLE_INTERVAL_USEC;
    emitSample(link, {snapshot: NEXT_TICK_SNAPSHOT, appendedHistory: NEXT_TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 2});
    assertEqual({
        pendingAfterState, pendingAfterFirstSample, pendingAfterSecondSample: pendingTimeoutsOf(fixture),
        addedIntervalsMs: timeouts.addedIntervalsMs(),
    }, {
        pendingAfterState: {seconds: [], ms: [STALL_MS]},
        pendingAfterFirstSample: {seconds: [], ms: [STALL_MS]},
        pendingAfterSecondSample: {seconds: [], ms: [STALL_MS]},
        // Armed anew by the state and by each Sample, the one before removed: each Sample pushes the stall back.
        addedIntervalsMs: [STALL_MS, STALL_MS, STALL_MS],
    });
});

test('client: 6000 ms of silence publishes no data once; the next Sample draws again and re-arms the watchdog', () => {
    const fixture = makeLiveClientFixture({isDetailWatchWanted: true});
    const {client, timeouts, link, notifications} = fixture;
    const historyListenerCalls = recordHistoryListenerCalls(client);
    const watchdogReturnValue = timeouts.fireMs(STALL_MS);
    const pendingAfterFiring = timeouts.pendingIntervalsMs();
    const notificationsWhileStalled = [...notifications];
    const historyCallCountWhileStalled = historyListenerCalls.length;
    const lastGoodClockLabelWhileStalled = client.lastGoodClockLabel;
    const historiesWhileStalled = historiesOf(fixture);
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    assertEqual({
        watchdogReturnValue, pendingAfterFiring, notificationsWhileStalled, historyCallCountWhileStalled,
        lastGoodClockLabelWhileStalled, historiesWhileStalled, notifications,
        pendingAfterNextSample: timeouts.pendingIntervalsMs(), stateCallCount: link.callsOf(GET_STATE).length,
    }, {
        // Its source ended, and nothing is left to fire again until a Sample comes: no data is published once.
        watchdogReturnValue: GLib.SOURCE_REMOVE, pendingAfterFiring: [],
        notificationsWhileStalled: [STATE_SNAPSHOT, NO_DATA_SNAPSHOT], historyCallCountWhileStalled: 1,
        lastGoodClockLabelWhileStalled: '14:02',
        historiesWhileStalled: {cpu: [...STATE_HISTORIES.cpu, null], memory: [...STATE_HISTORIES.memory, null]},
        notifications: [STATE_SNAPSHOT, NO_DATA_SNAPSHOT, TICK_SNAPSHOT],
        pendingAfterNextSample: [STALL_MS], stateCallCount: 1,
    });
});

test('client: a state already older than the stall shows no data at once and arms no watchdog', () => {
    const {timeouts, link, notifications} = makeClientFixture();
    const staleSnapshot = {...STATE_SNAPSHOT, takenAtUsec: START_USEC - STALL_USEC - ONE_MICROSECOND};
    answerState(link, {snapshot: staleSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    assertEqual({
        notifications, pendingSeconds: timeouts.pendingIntervalsSeconds(), pendingMs: timeouts.pendingIntervalsMs(),
        addedIntervalsMs: timeouts.addedIntervalsMs(),
    }, {notifications: [NO_DATA_SNAPSHOT], pendingSeconds: [], pendingMs: [], addedIntervalsMs: []});
});

test('client: destroy() unsubscribes, destroys the link, and leaves no pending timeout, also when a listener calls it', () => {
    const {client, timeouts, link, notifications} = makeLiveClientFixture({isDetailWatchWanted: true});
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    const pendingBeforeDestroy = timeouts.pendingIntervalsMs();
    client.destroy();
    // A Sample sent after destroy() reaches nothing, and arms nothing.
    emitSample(link, {snapshot: NEXT_TICK_SNAPSHOT, appendedHistory: NEXT_TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 2});
    // destroy() from a listener told of a state, or of a Sample, leaves no watchdog either: it is armed before they
    // are told.
    const destroyedOnState = makeClientFixture();
    destroyedOnState.client.addListener(() => destroyedOnState.client.destroy());
    answerState(destroyedOnState.link, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    const destroyedOnSample = makeLiveClientFixture();
    destroyedOnSample.client.addHistoryListener(() => destroyedOnSample.client.destroy());
    emitSample(destroyedOnSample.link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 1});
    assertEqual({
        pendingBeforeDestroy, isSampleSubscribed: link.isSampleSubscribed, isLinkDestroyed: link.isDestroyed,
        pendingSeconds: timeouts.pendingIntervalsSeconds(), pendingMs: timeouts.pendingIntervalsMs(), notifications,
        pendingAfterDestroyOnState: destroyedOnState.timeouts.pendingIntervalsMs(),
        pendingAfterDestroyOnSample: destroyedOnSample.timeouts.pendingIntervalsMs(),
    }, {
        pendingBeforeDestroy: [STALL_MS], isSampleSubscribed: false, isLinkDestroyed: true, pendingSeconds: [],
        pendingMs: [], notifications: [STATE_SNAPSHOT, TICK_SNAPSHOT], pendingAfterDestroyOnState: [],
        pendingAfterDestroyOnSample: [],
    });
});

test('client: destroy() twice is harmless', () => {
    // Review Focus 1: a lock or a blank lands while the watchdog and a detail watch are live, and disable() runs twice.
    const {client, timeouts, link, logged} = makeLiveClientFixture({isDetailWatchWanted: true});
    const pendingBeforeDestroy = timeouts.pendingIntervalsMs();
    client.destroy();
    client.destroy();
    assertEqual({
        pendingBeforeDestroy, logged, calledMethodNames: link.calledMethodNames, isLinkDestroyed: link.isDestroyed,
        pendingSeconds: timeouts.pendingIntervalsSeconds(), pendingMs: timeouts.pendingIntervalsMs(),
    }, {
        // Nothing removed twice (the fake throws, and teardown logs it) and the watch released once.
        pendingBeforeDestroy: [STALL_MS], logged: [], calledMethodNames: [GET_STATE, WATCH_DETAIL, UNWATCH_DETAIL],
        isLinkDestroyed: true, pendingSeconds: [], pendingMs: [],
    });
});

test('client: a destroyed client is not live', () => {
    const {client, link} = makeLiveClientFixture();
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    const isLiveBeforeDestroy = client.isLive;
    client.destroy();
    assertEqual({isLiveBeforeDestroy, isLiveAfterDestroy: client.isLive},
        {isLiveBeforeDestroy: true, isLiveAfterDestroy: false});
});

test('client: after a state the watchdog is armed for what is left of the stall', () => {
    const {timeouts, link, notifications} = makeClientFixture();
    // Taken 4 s before it arrived, so 2 s of the 6 s stall are left: its numbers are live until 6 s after they were
    // taken, not for 6 s more.
    const agedSnapshot = {...STATE_SNAPSHOT, takenAtUsec: START_USEC - 4 * USEC_PER_SECOND};
    answerState(link, {snapshot: agedSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    const pendingAfterState = timeouts.pendingIntervalsMs();
    timeouts.fireMs(2000);
    // 1 µs older leaves 1999.999 ms, rounded up, so the watchdog never fires before the stall.
    const justOlder = makeClientFixture();
    const justOlderSnapshot = {...agedSnapshot, takenAtUsec: agedSnapshot.takenAtUsec - ONE_MICROSECOND};
    answerState(justOlder.link, {snapshot: justOlderSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    assertEqual({
        pendingAfterState, notifications, pendingAfterFiring: timeouts.pendingIntervalsMs(),
        justOlderPending: justOlder.timeouts.pendingIntervalsMs(),
    }, {
        pendingAfterState: [2000], notifications: [agedSnapshot, NO_DATA_SNAPSHOT], pendingAfterFiring: [],
        justOlderPending: [2000],
    });
});

test('client: no watchdog stays pending once the data is not live', () => {
    const ownerLeft = makeLiveClientFixture();
    emitSample(ownerLeft.link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 1});
    const pendingBeforeOwnerLeft = pendingTimeoutsOf(ownerLeft);
    ownerLeft.link.setNameOwner(null);
    const restarted = makeLiveClientFixture();
    emitSample(restarted.link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 1});
    const pendingBeforeRestart = pendingTimeoutsOf(restarted);
    emitSample(restarted.link, {snapshot: RESTARTED_SNAPSHOT, appendedHistory: {cpu: 0.09, memory: 0.4}, sequence: 1});
    const isLiveAfterOwnerLeft = ownerLeft.client.isLive;
    const isLiveAfterRestart = restarted.client.isLive;
    assertEqual({
        pendingBeforeOwnerLeft, pendingAfterOwnerLeft: pendingTimeoutsOf(ownerLeft), isLiveAfterOwnerLeft,
        pendingBeforeRestart, pendingAfterRestart: pendingTimeoutsOf(restarted), isLiveAfterRestart,
    }, {
        pendingBeforeOwnerLeft: {seconds: [], ms: [STALL_MS]}, pendingAfterOwnerLeft: {seconds: [], ms: []},
        isLiveAfterOwnerLeft: false,
        pendingBeforeRestart: {seconds: [], ms: [STALL_MS]}, pendingAfterRestart: {seconds: [], ms: []},
        isLiveAfterRestart: false,
    });
});
