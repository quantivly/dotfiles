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

/** Fake GLib timeouts: a row fires one by its interval, and sees which are still pending. */
class FakeTimeouts {
    constructor() {
        this._sourcesById = new Map();
        this._nextSourceId = 1;
    }

    /**
     * @param {number} intervalSeconds - Seconds until the callback, and between calls while it continues.
     * @param {() => boolean} callback - Returns GLib.SOURCE_CONTINUE or GLib.SOURCE_REMOVE.
     * @returns {number} The source id.
     */
    addSeconds(intervalSeconds, callback) {
        const sourceId = this._nextSourceId++;
        this._sourcesById.set(sourceId, {intervalSeconds, callback});
        return sourceId;
    }

    /**
     * @param {number} sourceId - An id addSeconds returned.
     * @returns {void}
     * @throws {Error} For an id that is not pending, as GLib.source_remove warns of one.
     */
    remove(sourceId) {
        if (!this._sourcesById.delete(sourceId))
            throw new Error(`removed source ${sourceId}, which is not pending`);
    }

    /** @returns {number[]} The intervals of the pending sources, smallest first. */
    pendingIntervalsSeconds() {
        return [...this._sourcesById.values()].map(source => source.intervalSeconds).sort((a, b) => a - b);
    }

    /**
     * Runs the one pending source with this interval, as GLib would when it is due.
     *
     * @param {number} intervalSeconds - Its interval.
     * @returns {boolean} What the callback returned.
     * @throws {Error} Unless exactly one pending source has that interval.
     */
    fire(intervalSeconds) {
        const matchingEntries = [...this._sourcesById].filter(([, source]) => source.intervalSeconds === intervalSeconds);
        if (matchingEntries.length !== 1)
            throw new Error(`${matchingEntries.length} pending sources of ${intervalSeconds} s, not one`);
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

    /** @returns {boolean} True while Samples are delivered: from creation until unsubscribed or destroyed. */
    get isSampleSubscribed() {
        return this._isSampleSubscribed;
    }

    /** @returns {boolean} True once the client has destroyed the link. */
    get isDestroyed() {
        return this._isDestroyed;
    }

    /**
     * @param {boolean} isSubscribed - Whether Samples are delivered; nothing changes once destroyed.
     * @returns {void}
     */
    setSampleSubscribed(isSubscribed) {
        if (!this._isDestroyed)
            this._isSampleSubscribed = isSubscribed;
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
 * @returns {object} {client, clock, timeouts, serviceStarter, linkFactory, link, notifications, logged}.
 */
function makeClientFixture({nameOwner = OWNER, isOwnerReported = true, lastGoodClockLabel = undefined} = {}) {
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
 * @returns {object} makeClientFixture's fixture.
 */
function makeLiveClientFixture() {
    const fixture = makeClientFixture();
    fixture.serviceStarter.succeed();
    answerState(fixture.link, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    return fixture;
}

/**
 * The pending step of the StartUnit chain: every pending timeout but the staleness check.
 *
 * @param {FakeTimeouts} timeouts - The fixture's timeouts.
 * @returns {number[]} Their intervals, in seconds.
 */
function pendingStartChainSeconds(timeouts) {
    return timeouts.pendingIntervalsSeconds().filter(intervalSeconds => intervalSeconds !== SAMPLE_INTERVAL_SECONDS);
}

/**
 * @param {object} fixture - A fixture.
 * @returns {{cpu: Array<number|null>, memory: Array<number|null>}} The client's histories now.
 */
function historiesOf({client}) {
    return {cpu: client.cpuHistory.values(), memory: client.memoryHistory.values()};
}

test('client: before the first state it draws nothing, not even a Sample: no snapshot, no history, no listener call',
    () => {
        const {client, clock, timeouts, link, notifications} = makeClientFixture();
        emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
            sequence: STATE_SEQUENCE + 1});
        clock.nowUsec += LONG_WAIT_USEC;
        timeouts.fire(SAMPLE_INTERVAL_SECONDS);
        // A staleness check while no state is held must not let later Samples through either.
        emitSample(link, {snapshot: REVEAL_SNAPSHOT, appendedHistory: null, sequence: STATE_SEQUENCE + 2});
        assertEqual({
            latestSnapshot: client.latestSnapshot, histories: historiesOf({client}),
            lastGoodClockLabel: client.lastGoodClockLabel, notificationCount: notifications.length,
            stateCallCount: link.callsOf(GET_STATE).length,
        }, {
            latestSnapshot: null, histories: {cpu: [], memory: []}, lastGoodClockLabel: null, notificationCount: 0,
            stateCallCount: 1,
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

test('client: a Sample appends its values to both histories and tells listeners its snapshot', () => {
    const fixture = makeLiveClientFixture();
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
    const fixture = makeLiveClientFixture();
    emitSample(fixture.link, {snapshot: REVEAL_SNAPSHOT, appendedHistory: null, sequence: STATE_SEQUENCE + 1});
    assertEqual({histories: historiesOf(fixture), notifications: fixture.notifications},
        {histories: STATE_HISTORIES, notifications: [STATE_SNAPSHOT, REVEAL_SNAPSHOT]});
});

test('client: no Sample for more than 6 s publishes one no-data snapshot (and a gap in both histories), keeps the ' +
    'last good time, and the next Sample of the same run draws again', () => {
    const fixture = makeLiveClientFixture();
    const {clock, timeouts, notifications} = fixture;
    clock.nowUsec = START_USEC + STALL_USEC;
    timeouts.fire(SAMPLE_INTERVAL_SECONDS);
    const notificationsAtExactlyStall = notifications.length;
    clock.nowUsec += ONE_MICROSECOND;
    timeouts.fire(SAMPLE_INTERVAL_SECONDS);
    clock.nowUsec += SAMPLE_INTERVAL_USEC;
    timeouts.fire(SAMPLE_INTERVAL_SECONDS);
    const lastGoodClockLabelWhileStale = fixture.client.lastGoodClockLabel;
    const historiesWhileStale = historiesOf(fixture);
    emitSample(fixture.link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 1});
    assertEqual({
        notificationsAtExactlyStall, notifications, lastGoodClockLabelWhileStale, historiesWhileStale,
        stateCallCount: fixture.link.callsOf(GET_STATE).length,
    }, {
        notificationsAtExactlyStall: 1,
        notifications: [STATE_SNAPSHOT, NO_DATA_SNAPSHOT, TICK_SNAPSHOT],
        lastGoodClockLabelWhileStale: '14:02',
        historiesWhileStale: {cpu: [...STATE_HISTORIES.cpu, null], memory: [...STATE_HISTORIES.memory, null]},
        stateCallCount: 1,
    });
});

test('client: a sequence that restarts publishes no data once, and draws nothing until a fresh GetState', () => {
    const fixture = makeLiveClientFixture();
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
            const pendingRetryDelaysSeconds = timeouts.pendingIntervalsSeconds()
                .filter(intervalSeconds => intervalSeconds !== SAMPLE_INTERVAL_SECONDS);
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
            pendingAfterSuccess: [SAMPLE_INTERVAL_SECONDS, START_CONFIRMATION_SECONDS], startUnitLogLines: 1,
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
        pendingAfterFailure: [SAMPLE_INTERVAL_SECONDS, 5], pendingAfterOwner: [SAMPLE_INTERVAL_SECONDS],
        attemptCount: 1, calledMethodNames: [GET_STATE],
    });
});

test('client: the name losing its owner publishes no data once and never calls StartUnit (a stop stays stopped); ' +
    'a new owner is read with GetState and drawn', () => {
    const fixture = makeLiveClientFixture();
    const {clock, timeouts, serviceStarter, link, notifications} = fixture;
    emitSample(link, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    link.setNameOwner(null);
    clock.nowUsec += LONG_WAIT_USEC;
    timeouts.fire(SAMPLE_INTERVAL_SECONDS);
    const notificationsWhileGone = [...notifications];
    const pendingWhileGone = timeouts.pendingIntervalsSeconds();
    link.setNameOwner(NEXT_OWNER);
    const returnedSnapshot = {...RESTARTED_SNAPSHOT, takenAtUsec: clock.nowUsec};
    answerState(link, {snapshot: returnedSnapshot, histories: RESTARTED_HISTORIES, sequence: 1});
    assertEqual({
        notificationsWhileGone, pendingWhileGone, attemptCount: serviceStarter.attempts.length,
        notificationsAfterReturn: notifications.slice(notificationsWhileGone.length), histories: historiesOf(fixture),
    }, {
        notificationsWhileGone: [STATE_SNAPSHOT, TICK_SNAPSHOT, NO_DATA_SNAPSHOT],
        pendingWhileGone: [SAMPLE_INTERVAL_SECONDS], attemptCount: 1,
        notificationsAfterReturn: [returnedSnapshot], histories: RESTARTED_HISTORIES,
    });
});

test('client: Samples are drawn although StartUnit failed (no systemd, as in the nested harness), and a StartUnit ' +
    'answered while the service runs, failed or accepted, schedules nothing', () => {
    const fixture = makeClientFixture();
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
        pendingAfterFailureWhileRunning: [SAMPLE_INTERVAL_SECONDS],
        pendingAfterAcceptedWhileRunning: [SAMPLE_INTERVAL_SECONDS],
    });
});

test('client: an accepted StartUnit with no owner within 15 s is no success: the chain goes on, 5, 30, 300, then ' +
    '300 s after each unconfirmed attempt, and each is logged', () => {
    const {timeouts, serviceStarter, logged} = makeClientFixture({nameOwner: null});
    const confirmationWaitsSeconds = [];
    const retryDelaysSeconds = [];
    for (const _unconfirmedAttempt of [1, 2, 3, 4]) {
        serviceStarter.succeed();
        confirmationWaitsSeconds.push(...pendingStartChainSeconds(timeouts));
        timeouts.fire(START_CONFIRMATION_SECONDS);
        const pendingRetryDelaysSeconds = pendingStartChainSeconds(timeouts);
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
        pendingWhileWaiting: [SAMPLE_INTERVAL_SECONDS, START_CONFIRMATION_SECONDS],
        pendingAfterOwner: [SAMPLE_INTERVAL_SECONDS], pendingAfterLeaving: [SAMPLE_INTERVAL_SECONDS], attemptCount: 1,
    });
});

test('client: destroy() while an accepted StartUnit waits for the service leaves no timeout behind', () => {
    const {client, timeouts, serviceStarter} = makeClientFixture({nameOwner: null});
    serviceStarter.succeed();
    const pendingWhileWaiting = timeouts.pendingIntervalsSeconds();
    client.destroy();
    assertEqual({pendingWhileWaiting, pending: timeouts.pendingIntervalsSeconds()},
        {pendingWhileWaiting: [SAMPLE_INTERVAL_SECONDS, START_CONFIRMATION_SECONDS], pending: []});
});

test('client: a StartUnit still on its way when the service appears is superseded: its failure, after the owner ' +
    'left again, schedules no retry', () => {
    const {timeouts, serviceStarter, link, logged} = makeClientFixture({nameOwner: null});
    link.setNameOwner(OWNER);
    link.setNameOwner(null);
    serviceStarter.fail();
    assertEqual({pending: timeouts.pendingIntervalsSeconds(), attemptCount: serviceStarter.attempts.length,
        startUnitLogLines: logged.filter(line => line.includes('StartUnit')).length},
    {pending: [SAMPLE_INTERVAL_SECONDS], attemptCount: 1, startUnitLogLines: 0});
});

test('client: a state whose snapshot was taken more than 6 s before it arrived (a service that answers while its ' +
    'sampler has stopped) shows no data at once, since that snapshot\'s time; the next Sample of the run draws', () => {
    const fixture = makeClientFixture();
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
    'and stale 1 µs later', () => {
    const {clock, timeouts, link, notifications} = makeClientFixture();
    const oldSnapshot = {...STATE_SNAPSHOT, takenAtUsec: START_USEC - STALL_USEC};
    answerState(link, {snapshot: oldSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    timeouts.fire(SAMPLE_INTERVAL_SECONDS);
    const notificationsAtExactlyStall = [...notifications];
    clock.nowUsec += ONE_MICROSECOND;
    timeouts.fire(SAMPLE_INTERVAL_SECONDS);
    assertEqual({notificationsAtExactlyStall, notifications},
        {notificationsAtExactlyStall: [oldSnapshot], notifications: [oldSnapshot, NO_DATA_SNAPSHOT]});
});

test('client: a state snapshot with no time counts from its arrival, and one stamped in the future counts from now',
    () => {
        const untimed = makeClientFixture();
        const untimedSnapshot = {...STATE_SNAPSHOT, takenAtUsec: null};
        answerState(untimed.link, {snapshot: untimedSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
        untimed.clock.nowUsec += STALL_USEC;
        untimed.timeouts.fire(SAMPLE_INTERVAL_SECONDS);
        const untimedAtExactlyStall = untimed.notifications.length;
        untimed.clock.nowUsec += ONE_MICROSECOND;
        untimed.timeouts.fire(SAMPLE_INTERVAL_SECONDS);
        const future = makeClientFixture();
        const futureSnapshot = {...STATE_SNAPSHOT, takenAtUsec: START_USEC + LONG_WAIT_USEC};
        answerState(future.link, {snapshot: futureSnapshot, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
        future.clock.nowUsec += STALL_USEC + ONE_MICROSECOND;
        future.timeouts.fire(SAMPLE_INTERVAL_SECONDS);
        assertEqual({untimedAtExactlyStall, untimed: untimed.notifications, future: future.notifications}, {
            untimedAtExactlyStall: 1, untimed: [untimedSnapshot, NO_DATA_SNAPSHOT],
            future: [futureSnapshot, NO_DATA_SNAPSHOT],
        });
    });

test('client: a Sample from another version (an unknown field, swap missing) notifies with swap null and every ' +
    'other row intact', () => {
    const fixture = makeLiveClientFixture();
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
        pendingBeforeDestroy: [SAMPLE_INTERVAL_SECONDS, 5], isLinkDestroyed: true, calledMethodNames: [], pending: [],
    });
});

test('client: a Sample of another signature, or text that is not JSON, changes nothing, and each is logged', () => {
    const fixture = makeLiveClientFixture();
    fixture.link.emitSample(new GLib.Variant('(i)', [STATE_SEQUENCE + 1]));
    fixture.link.emitSample(new GLib.Variant(SAMPLE_SIGNAL_SIGNATURE, ['{"sequence": 8,']));
    assertEqual({notifications: fixture.notifications, histories: historiesOf(fixture),
        sampleLogLines: fixture.logged.filter(line => line.includes(SAMPLE_SIGNAL)).length},
    {notifications: [STATE_SNAPSHOT], histories: STATE_HISTORIES, sampleLogLines: 2});
});

test('client: a GetState that fails is logged and leaves no data, and the next Sample asks for the state again', () => {
    const fixture = makeClientFixture();
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
        pendingAfterSupersededFailure: [SAMPLE_INTERVAL_SECONDS], loggedAfterSupersededFailure: 0,
        pending: [SAMPLE_INTERVAL_SECONDS, 5],
    });
});

test('client: no data is published once however many reasons follow: a stall, then a sequence that does not move on ' +
    '(a new run that counted back up to the last one drawn), then the owner leaving', () => {
    const fixture = makeLiveClientFixture();
    const {clock, timeouts, link, notifications} = fixture;
    clock.nowUsec += LONG_WAIT_USEC;
    timeouts.fire(SAMPLE_INTERVAL_SECONDS);
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
