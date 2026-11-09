// pulseClient.js with a fake D-Bus proxy, fake timeouts and a fake StartUnit, so every row runs under plain gjs, on no
// bus at all, in a fixed order: each fake answers only when a row tells it to. The payloads are built with
// lib/protocol.js's builders, as the real service builds them. The real proxy and the real StartUnit are exercised on a
// private bus by client-dbus.test.js.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// Read through the namespace, so a missing export fails its row rather than the whole run.
import * as pulseClientModule from '../extensions/resource-pulse@dotfiles/pulseClient.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';
import {cardText} from '../extensions/resource-pulse@dotfiles/lib/format.js';
import {buildSamplePayload, buildStatePayload} from '../extensions/resource-pulse@dotfiles/lib/protocol.js';
import * as constantsModule from '../extensions/resource-pulse@dotfiles/lib/constants.js';

const USEC_PER_SECOND = 1_000_000;
const SAMPLE_INTERVAL_SECONDS = 2;
const SAMPLE_INTERVAL_USEC = SAMPLE_INTERVAL_SECONDS * USEC_PER_SECOND;
/** SAMPLE_STALL_TICKS (3) × SAMPLE_INTERVAL_SECONDS: the design's 6 s, written out. */
const STALL_USEC = 6 * USEC_PER_SECOND;
const ONE_MICROSECOND = 1;
const START_USEC = 1_000_000_000;
/** Well past any staleness, for rows that wait out the clock. */
const LONG_WAIT_USEC = 60 * USEC_PER_SECOND;
const OWNER = ':1.42';
const NEXT_OWNER = ':1.77';
/** Stands in for the session bus connection: the client only hands it to createProxy and startUnit. */
const FAKE_CONNECTION = {isFakeConnection: true};
const SERVICE_STARTED_AT_USEC = 1_794_000_000_000_000;
const SAMPLED_AT_USEC = 1_794_000_002_000_000;
const STATE_REPLY_SIGNATURE = '(s)';
const SAMPLE_SIGNAL_SIGNATURE = '(s)';
const GET_STATE = 'GetState';
const WATCH_DETAIL = 'WatchDetail';
const UNWATCH_DETAIL = 'UnwatchDetail';
const SAMPLE_SIGNAL = 'Sample';
const NAME_OWNER_NOTIFY_SIGNAL = 'notify::g-name-owner';
const PROXY_SIGNAL = 'g-signal';
const NO_DATA_TEXT = 'no data';

/** The snapshot GetState answers: every field set. */
const STATE_SNAPSHOT = {
    takenAtUsec: 120_000_000,
    takenAtClockLabel: '14:02',
    cpuBusyPercent: 23.5,
    cpuClusters: {performancePercent: 41, efficiencyPercent: 6},
    memory: {usedBytes: 16_000_000_000, totalBytes: 32_000_000_000},
    swap: {zramUsedBytes: 1_600_000_000, zramRamBytes: 400_000_000, diskBytes: 0},
    pressureAvg10: {cpu: 1.5, memory: 0, io: 0.25},
    apps: {
        topCpu: {groupKey: 'app:org.example.Editor', name: 'Editor', cpuPercent: 31},
        topMemory: {groupKey: 'herdr-server', name: 'herdr agents', memoryBytes: 15_700_000_000},
    },
    isComplete: true,
};
const STATE_HISTORIES = {cpu: [0.25, null, 0.5], memory: [0.6, 0.61, null]};
const STATE_SEQUENCE = 7;
/** The next fast tick's snapshot, a minute later. */
const TICK_SNAPSHOT = {...STATE_SNAPSHOT, takenAtUsec: 122_000_000, takenAtClockLabel: '14:03', cpuBusyPercent: 50};
const TICK_APPENDED_HISTORY = {cpu: 0.5, memory: 0.25};
/** A watch start's reveal: the tick's values with a new ranking, appending nothing. */
const REVEAL_SNAPSHOT = {
    ...TICK_SNAPSHOT,
    apps: {...TICK_SNAPSHOT.apps, topCpu: {groupKey: 'kernel', name: 'kernel', cpuPercent: 12}},
};
/** What a restarted service answers GetState with: a history of its own, numbered from 1 again. */
const RESTARTED_SNAPSHOT = {...STATE_SNAPSHOT, takenAtUsec: 4_000_000, takenAtClockLabel: '14:05', cpuBusyPercent: 9};
const RESTARTED_HISTORIES = {cpu: [0.09], memory: [0.4]};
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

/** A fake Gio.DBusProxy: the name owner, the two signals the client connects, and calls a row answers. */
class FakeProxy {
    /**
     * @param {string|null} nameOwner - The unique name owning the service's name, or null for none.
     */
    constructor(nameOwner) {
        this._nameOwner = nameOwner;
        this._handlersById = new Map();
        this._nextHandlerId = 1;
        /** @type {Array<{methodName: string, timeoutMs: number, cancellable: Gio.Cancellable|null,
         *     callback: Function, isAnswered: boolean}>} Every call, in order. */
        this.calls = [];
    }

    /** @returns {string|null} The name owner. */
    get_name_owner() {
        return this._nameOwner;
    }

    /**
     * @param {string} signalName - 'notify::g-name-owner' or 'g-signal'.
     * @param {Function} handler - The handler.
     * @returns {number} A handler id.
     */
    connect(signalName, handler) {
        const handlerId = this._nextHandlerId++;
        this._handlersById.set(handlerId, {signalName, handler});
        return handlerId;
    }

    /**
     * @param {number} handlerId - An id connect returned.
     * @returns {void}
     */
    disconnect(handlerId) {
        this._handlersById.delete(handlerId);
    }

    /** @returns {number} Handlers still connected. */
    get connectedHandlerCount() {
        return this._handlersById.size;
    }

    /**
     * Records a call; a row answers it with answer() or fail().
     *
     * @param {string} methodName - The method.
     * @param {GLib.Variant|null} _parameters - Its parameters (none of the service's methods takes any).
     * @param {Gio.DBusCallFlags} _flags - Call flags.
     * @param {number} timeoutMs - The call's timeout.
     * @param {Gio.Cancellable|null} cancellable - Its cancellable.
     * @param {(proxy: FakeProxy, result: object) => void} callback - Called with the answer.
     * @returns {void}
     */
    call(methodName, _parameters, _flags, timeoutMs, cancellable, callback) {
        this.calls.push({methodName, timeoutMs, cancellable, callback, isAnswered: false});
    }

    /**
     * @param {{reply: GLib.Variant|null, error: Error|null}} result - What answer() or fail() passed.
     * @returns {GLib.Variant|null} The reply.
     * @throws {Error} The failure.
     */
    call_finish(result) {
        if (result.error !== null)
            throw result.error;
        return result.reply;
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
     * Changes the name owner and notifies, as GDBusProxy does on NameOwnerChanged.
     *
     * @param {string|null} nameOwner - The new owner, or null for none.
     * @returns {void}
     */
    setNameOwner(nameOwner) {
        this._nameOwner = nameOwner;
        this._emit(NAME_OWNER_NOTIFY_SIGNAL, [this, null]);
    }

    /**
     * Delivers a D-Bus signal from the owner, as GDBusProxy's g-signal does.
     *
     * @param {string} signalName - The signal's name.
     * @param {GLib.Variant} parameters - Its parameters.
     * @returns {void}
     */
    emitSignal(signalName, parameters) {
        this._emit(PROXY_SIGNAL, [this, this._nameOwner, signalName, parameters]);
    }

    /**
     * @param {string} methodName - The method.
     * @param {object} result - {reply, error}.
     * @returns {void}
     * @throws {Error} When no call of that method is waiting.
     */
    _settleOldestCall(methodName, result) {
        const call = this.calls.find(pendingCall => pendingCall.methodName === methodName && !pendingCall.isAnswered);
        if (call === undefined)
            throw new Error(`no unanswered ${methodName} call`);
        call.isAnswered = true;
        call.callback(this, result);
    }

    /**
     * @param {string} signalName - The GObject signal.
     * @param {Array<*>} signalArguments - Its arguments.
     * @returns {void}
     */
    _emit(signalName, signalArguments) {
        for (const {signalName: handledSignalName, handler} of [...this._handlersById.values()]) {
            if (handledSignalName === signalName)
                handler(...signalArguments);
        }
    }
}

/** A fake createProxy: a row delivers the proxy when it chooses. */
class FakeProxyFactory {
    constructor() {
        /** @type {Array<{connection: object, cancellable: Gio.Cancellable, onCreated: Function}>} */
        this.requests = [];
        this.createProxy = (connection, cancellable, onCreated) =>
            this.requests.push({connection, cancellable, onCreated});
    }

    /**
     * @param {FakeProxy} proxy - The proxy to hand the latest request.
     * @returns {void}
     */
    deliver(proxy) {
        this.requests.at(-1).onCreated(null, proxy);
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

    /** @returns {void} */
    succeed() {
        this.attempts.at(-1).onAnswered(null);
    }

    /**
     * @param {Error} [error] - The failure; by default systemd's name not being on the bus.
     * @returns {void}
     */
    fail(error = new GLib.Error(Gio.DBusError, Gio.DBusError.SERVICE_UNKNOWN,
        'The name org.freedesktop.systemd1 was not provided by any .service files')) {
        this.attempts.at(-1).onAnswered(error);
    }
}

/**
 * Builds a client on fakes and starts it.
 *
 * @param {object} [options] - The fixture's shape.
 * @param {string|null} [options.nameOwner] - The service's owner when the proxy arrives; null for none.
 * @param {boolean} [options.isProxyDelivered] - False to leave the proxy still being created.
 * @returns {object} {client, clock, timeouts, serviceStarter, proxyFactory, proxy, notifications, logged}.
 */
function makeClientFixture({nameOwner = OWNER, isProxyDelivered = true} = {}) {
    const clock = {nowUsec: START_USEC};
    const timeouts = new FakeTimeouts();
    const serviceStarter = new FakeServiceStarter();
    const proxyFactory = new FakeProxyFactory();
    const logged = [];
    const client = new pulseClientModule.PulseClient({
        connection: FAKE_CONNECTION,
        startUnit: serviceStarter.startUnit,
        createProxy: proxyFactory.createProxy,
        nowUsec: () => clock.nowUsec,
        timeouts,
        errorLog: new RateLimitedLogger({nowUsec: () => clock.nowUsec, write: line => logged.push(line)}),
    });
    const notifications = [];
    client.addListener(snapshot => notifications.push(snapshot));
    client.start();
    const proxy = new FakeProxy(nameOwner);
    if (isProxyDelivered)
        proxyFactory.deliver(proxy);
    return {client, clock, timeouts, serviceStarter, proxyFactory, proxy, notifications, logged};
}

/**
 * Answers the oldest GetState with a state payload.
 *
 * @param {FakeProxy} proxy - The fixture's proxy.
 * @param {object} state - {snapshot, histories, sequence}.
 * @returns {void}
 */
function answerState(proxy, {snapshot, histories, sequence}) {
    const statePayload = buildStatePayload({
        snapshot, histories, serviceStartedAtUsec: SERVICE_STARTED_AT_USEC, sequence,
    });
    proxy.answer(GET_STATE, new GLib.Variant(STATE_REPLY_SIGNATURE, [statePayload]));
}

/**
 * Emits one Sample signal.
 *
 * @param {FakeProxy} proxy - The fixture's proxy.
 * @param {object} sample - {snapshot, appendedHistory, sequence}.
 * @returns {void}
 */
function emitSample(proxy, {snapshot, appendedHistory, sequence}) {
    const samplePayload = buildSamplePayload({snapshot, appendedHistory, sequence, sampledAtUsec: SAMPLED_AT_USEC});
    proxy.emitSignal(SAMPLE_SIGNAL, new GLib.Variant(SAMPLE_SIGNAL_SIGNATURE, [samplePayload]));
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
    answerState(fixture.proxy, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    return fixture;
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
        const {client, clock, timeouts, proxy, notifications} = makeClientFixture();
        emitSample(proxy, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
            sequence: STATE_SEQUENCE + 1});
        clock.nowUsec += LONG_WAIT_USEC;
        timeouts.fire(SAMPLE_INTERVAL_SECONDS);
        assertEqual({
            latestSnapshot: client.latestSnapshot, histories: historiesOf({client}),
            lastGoodClockLabel: client.lastGoodClockLabel, notificationCount: notifications.length,
            stateCallCount: proxy.callsOf(GET_STATE).length,
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
    emitSample(fixture.proxy, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
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
    emitSample(fixture.proxy, {snapshot: REVEAL_SNAPSHOT, appendedHistory: null, sequence: STATE_SEQUENCE + 1});
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
    emitSample(fixture.proxy, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY,
        sequence: STATE_SEQUENCE + 1});
    assertEqual({
        notificationsAtExactlyStall, notifications, lastGoodClockLabelWhileStale, historiesWhileStale,
        stateCallCount: fixture.proxy.callsOf(GET_STATE).length,
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
    const {proxy, notifications} = fixture;
    emitSample(proxy, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    emitSample(proxy, {snapshot: RESTARTED_SNAPSHOT, appendedHistory: {cpu: 0.09, memory: 0.4}, sequence: 1});
    emitSample(proxy, {snapshot: RESTARTED_SNAPSHOT, appendedHistory: {cpu: 0.1, memory: 0.4}, sequence: 2});
    const notificationsBeforeState = [...notifications];
    answerState(proxy, {snapshot: RESTARTED_SNAPSHOT, histories: RESTARTED_HISTORIES, sequence: 2});
    const historiesFromState = historiesOf(fixture);
    emitSample(proxy, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: 3});
    assertEqual({
        notificationsBeforeState, historiesFromState, notificationsAfter: notifications.slice(3),
        histories: historiesOf(fixture), stateCallCount: proxy.callsOf(GET_STATE).length,
    }, {
        notificationsBeforeState: [STATE_SNAPSHOT, TICK_SNAPSHOT, NO_DATA_SNAPSHOT],
        historiesFromState: RESTARTED_HISTORIES,
        notificationsAfter: [RESTARTED_SNAPSHOT, TICK_SNAPSHOT],
        histories: {cpu: [0.09, 0.5], memory: [0.4, 0.25]},
        stateCallCount: 2,
    });
});

test('client: a failed StartUnit is retried after 5, 30, 300, then 300 s, logged once, and a success ends the retries',
    () => {
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
            retryDelaysSeconds: [5, 30, 300, 300], attemptCount: 5, pendingAfterSuccess: [SAMPLE_INTERVAL_SECONDS],
            startUnitLogLines: 1,
        });
    });

test('client: the service appearing ends the StartUnit retries, since it runs: no retry is left pending', () => {
    const {timeouts, serviceStarter, proxy} = makeClientFixture({nameOwner: null});
    serviceStarter.fail();
    const pendingAfterFailure = timeouts.pendingIntervalsSeconds();
    proxy.setNameOwner(OWNER);
    assertEqual({
        pendingAfterFailure, pendingAfterOwner: timeouts.pendingIntervalsSeconds(),
        attemptCount: serviceStarter.attempts.length, calledMethodNames: proxy.calledMethodNames,
    }, {
        pendingAfterFailure: [SAMPLE_INTERVAL_SECONDS, 5], pendingAfterOwner: [SAMPLE_INTERVAL_SECONDS],
        attemptCount: 1, calledMethodNames: [GET_STATE],
    });
});

test('client: the name losing its owner publishes no data once and never calls StartUnit (a stop stays stopped); ' +
    'a new owner is read with GetState and drawn', () => {
    const fixture = makeLiveClientFixture();
    const {clock, timeouts, serviceStarter, proxy, notifications} = fixture;
    emitSample(proxy, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    proxy.setNameOwner(null);
    clock.nowUsec += LONG_WAIT_USEC;
    timeouts.fire(SAMPLE_INTERVAL_SECONDS);
    const notificationsWhileGone = [...notifications];
    const pendingWhileGone = timeouts.pendingIntervalsSeconds();
    proxy.setNameOwner(NEXT_OWNER);
    answerState(proxy, {snapshot: RESTARTED_SNAPSHOT, histories: RESTARTED_HISTORIES, sequence: 1});
    assertEqual({
        notificationsWhileGone, pendingWhileGone, attemptCount: serviceStarter.attempts.length,
        notificationsAfterReturn: notifications.slice(notificationsWhileGone.length), histories: historiesOf(fixture),
    }, {
        notificationsWhileGone: [STATE_SNAPSHOT, TICK_SNAPSHOT, NO_DATA_SNAPSHOT],
        pendingWhileGone: [SAMPLE_INTERVAL_SECONDS], attemptCount: 1,
        notificationsAfterReturn: [RESTARTED_SNAPSHOT], histories: RESTARTED_HISTORIES,
    });
});

test('client: Samples are drawn although StartUnit failed (no systemd, as in the nested harness), and a failure ' +
    'while the service runs schedules no retry', () => {
    const fixture = makeClientFixture();
    const {timeouts, serviceStarter, proxy, notifications} = fixture;
    serviceStarter.fail();
    answerState(proxy, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    emitSample(proxy, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    assertEqual({notifications, histories: historiesOf(fixture), pending: timeouts.pendingIntervalsSeconds()}, {
        notifications: [STATE_SNAPSHOT, TICK_SNAPSHOT],
        histories: {cpu: [...STATE_HISTORIES.cpu, 0.5], memory: [...STATE_HISTORIES.memory, 0.25]},
        pending: [SAMPLE_INTERVAL_SECONDS],
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
    fixture.proxy.emitSignal(SAMPLE_SIGNAL,
        new GLib.Variant(SAMPLE_SIGNAL_SIGNATURE, [JSON.stringify(samplePayload)]));
    const drawnSnapshot = fixture.notifications.at(-1);
    const drawnText = cardText(drawnSnapshot, fixture.client.lastGoodClockLabel);
    const fullText = cardText(TICK_SNAPSHOT, fixture.client.lastGoodClockLabel);
    assertEqual({drawnSnapshot, swapValue: drawnText.swapValue, otherRows: {...drawnText, swapValue: null}}, {
        drawnSnapshot: {...TICK_SNAPSHOT, swap: null}, swapValue: NO_DATA_TEXT, otherRows: {...fullText, swapValue: null},
    });
});

test('client: WatchDetail and UnwatchDetail go out only when the wanted flag changes, with an owner, and the watch ' +
    'is asserted again to each new owner; every call is asynchronous with DBUS_CALL_TIMEOUT_MS', () => {
    const {client, proxyFactory, proxy} = makeClientFixture({isProxyDelivered: false});
    client.setDetailWatchWanted(true);
    proxyFactory.deliver(proxy);
    client.setDetailWatchWanted(true);
    client.setDetailWatchWanted(false);
    client.setDetailWatchWanted(false);
    client.setDetailWatchWanted(true);
    proxy.setNameOwner(null);
    proxy.setNameOwner(NEXT_OWNER);
    client.setDetailWatchWanted(false);
    proxy.setNameOwner(null);
    client.setDetailWatchWanted(true);
    client.setDetailWatchWanted(false);
    proxy.setNameOwner(OWNER);
    const callShapes = new Set(proxy.calls.map(call => `${call.timeoutMs}/${typeof call.callback}`));
    assertEqual({calledMethodNames: proxy.calledMethodNames, callShapes: [...callShapes]}, {
        calledMethodNames: [GET_STATE, WATCH_DETAIL, UNWATCH_DETAIL, WATCH_DETAIL, GET_STATE, WATCH_DETAIL,
            UNWATCH_DETAIL, GET_STATE],
        callShapes: [`${constantsModule.DBUS_CALL_TIMEOUT_MS}/function`],
    });
});

test('client: destroy() unwatches (uncancellable), cancels the pending GetState, disconnects from the proxy, removes ' +
    'its timeouts, and nothing after it (a late reply, a watch change, start()) does anything', () => {
    const {client, timeouts, serviceStarter, proxy, notifications} = makeClientFixture();
    client.setDetailWatchWanted(true);
    const pendingStateCall = proxy.callsOf(GET_STATE)[0];
    client.destroy();
    const unwatchCalls = proxy.callsOf(UNWATCH_DETAIL);
    answerState(proxy, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    client.setDetailWatchWanted(false);
    client.start();
    assertEqual({
        unwatchCancellables: unwatchCalls.map(call => call.cancellable),
        isStateCallCancelled: pendingStateCall.cancellable?.is_cancelled() ?? null,
        connectedHandlerCount: proxy.connectedHandlerCount, pending: timeouts.pendingIntervalsSeconds(),
        notificationCount: notifications.length, calledMethodNames: proxy.calledMethodNames,
        attemptCount: serviceStarter.attempts.length, latestSnapshot: client.latestSnapshot,
    }, {
        unwatchCancellables: [null], isStateCallCancelled: true, connectedHandlerCount: 0, pending: [],
        notificationCount: 0, calledMethodNames: [GET_STATE, WATCH_DETAIL, UNWATCH_DETAIL], attemptCount: 1,
        latestSnapshot: null,
    });
});

test('client: destroy() while the proxy is still being created cancels it and its StartUnit retry, and a proxy that ' +
    'arrives later is never used', () => {
    const {client, timeouts, serviceStarter, proxyFactory, proxy} = makeClientFixture({isProxyDelivered: false});
    serviceStarter.fail();
    const pendingBeforeDestroy = timeouts.pendingIntervalsSeconds();
    client.destroy();
    proxyFactory.deliver(proxy);
    assertEqual({
        pendingBeforeDestroy, isProxyRequestCancelled: proxyFactory.requests[0].cancellable.is_cancelled(),
        connectedHandlerCount: proxy.connectedHandlerCount, calledMethodNames: proxy.calledMethodNames,
        pending: timeouts.pendingIntervalsSeconds(),
    }, {
        pendingBeforeDestroy: [SAMPLE_INTERVAL_SECONDS, 5], isProxyRequestCancelled: true, connectedHandlerCount: 0,
        calledMethodNames: [], pending: [],
    });
});

test('client: a signal other than Sample, a Sample of another signature, or text that is not JSON changes nothing; ' +
    'each malformed Sample is logged', () => {
    const fixture = makeLiveClientFixture();
    const samplePayload = buildSamplePayload({
        snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1,
        sampledAtUsec: SAMPLED_AT_USEC,
    });
    fixture.proxy.emitSignal('Sampled', new GLib.Variant(SAMPLE_SIGNAL_SIGNATURE, [samplePayload]));
    fixture.proxy.emitSignal(SAMPLE_SIGNAL, new GLib.Variant('(i)', [STATE_SEQUENCE + 1]));
    fixture.proxy.emitSignal(SAMPLE_SIGNAL, new GLib.Variant(SAMPLE_SIGNAL_SIGNATURE, ['{"sequence": 8,']));
    assertEqual({notifications: fixture.notifications, histories: historiesOf(fixture),
        sampleLogLines: fixture.logged.filter(line => line.includes(SAMPLE_SIGNAL)).length},
    {notifications: [STATE_SNAPSHOT], histories: STATE_HISTORIES, sampleLogLines: 2});
});

test('client: a GetState that fails is logged and leaves no data, and the next Sample asks for the state again', () => {
    const fixture = makeClientFixture();
    const {proxy, notifications, logged} = fixture;
    proxy.fail(GET_STATE, new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.TIMED_OUT, 'Timeout was reached'));
    const stateCallsAfterFailure = proxy.callsOf(GET_STATE).length;
    emitSample(proxy, {snapshot: TICK_SNAPSHOT, appendedHistory: TICK_APPENDED_HISTORY, sequence: STATE_SEQUENCE + 1});
    const notificationsBeforeState = notifications.length;
    answerState(proxy, {snapshot: TICK_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE + 1});
    emitSample(proxy, {snapshot: REVEAL_SNAPSHOT, appendedHistory: null, sequence: STATE_SEQUENCE + 2});
    assertEqual({
        stateCallsAfterFailure, notificationsBeforeState, stateCallCount: proxy.callsOf(GET_STATE).length,
        notifications, stateLogLines: logged.filter(line => line.includes(GET_STATE)).length,
    }, {
        stateCallsAfterFailure: 1, notificationsBeforeState: 0, stateCallCount: 2,
        notifications: [TICK_SNAPSHOT, REVEAL_SNAPSHOT], stateLogLines: 1,
    });
});

test('client: every start() asks systemd to start the service again, but connects and follows the service once', () => {
    const {client, timeouts, serviceStarter, proxyFactory} = makeClientFixture();
    serviceStarter.succeed();
    client.start();
    assertEqual({
        attemptConnections: serviceStarter.attempts.map(attempt => attempt.connection),
        proxyRequestCount: proxyFactory.requests.length, proxyConnection: proxyFactory.requests[0].connection,
        pending: timeouts.pendingIntervalsSeconds(),
    }, {
        attemptConnections: [FAKE_CONNECTION, FAKE_CONNECTION], proxyRequestCount: 1, proxyConnection: FAKE_CONNECTION,
        pending: [SAMPLE_INTERVAL_SECONDS],
    });
});

test('client: a listener that throws is logged and the next still runs; a removed one is not called', () => {
    const {client, proxy, logged} = makeClientFixture();
    const calledListeners = [];
    client.addListener(() => {
        calledListeners.push('throwing');
        throw new Error('listener bug');
    });
    const removedListenerId = client.addListener(() => calledListeners.push('removed'));
    client.addListener(() => calledListeners.push('last'));
    client.removeListener(removedListenerId);
    answerState(proxy, {snapshot: STATE_SNAPSHOT, histories: STATE_HISTORIES, sequence: STATE_SEQUENCE});
    assertEqual({calledListeners, listenerLogLines: logged.filter(line => line.includes('listener bug')).length},
        {calledListeners: ['throwing', 'last'], listenerLogLines: 1});
});
