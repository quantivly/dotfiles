// cockpitClient.js with a fake D-Bus proxy, fake timeouts, a fake StartUnit and a fake systemd unit
// (readUnitCondition), so every row runs under plain gjs, on no bus at all, in a fixed order: each fake answers only
// when a row tells it to. The payloads are built with lib/cockpitProtocol.js's builders, as the cockpit service builds
// them. The fakes are copies of client.test.js's, as the repo copies a few classes rather than share them between test
// files. The real proxy, StartUnit and unit read are exercised on a private bus by cockpit-client-dbus.test.js.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
// Read through the namespace, so a missing export fails its row rather than the whole run.
import * as cockpitClientModule from '../extensions/resource-pulse@dotfiles/cockpitClient.js';
import * as constantsModule from '../extensions/resource-pulse@dotfiles/lib/constants.js';
import {RateLimitedLogger} from '../extensions/resource-pulse@dotfiles/lib/errorLog.js';
import {
    buildChangedPayload, buildCockpitStatePayload, buildFocusSessionReply,
} from '../extensions/resource-pulse@dotfiles/lib/cockpitProtocol.js';

const USEC_PER_SECOND = 1_000_000;
/** START_CONFIRMATION_TIMEOUT_SECONDS (15), written out: how long an accepted StartUnit waits for the service. */
const START_CONFIRMATION_SECONDS = 15;
/** START_RETRY_DELAYS_SECONDS (5, 30, 300), then 300 again, written out. */
const RETRY_DELAYS_SECONDS = [5, 30, 300, 300];
const START_USEC = 1_000_000_000;
const OWNER = ':1.42';
const NEXT_OWNER = ':1.77';
/** Stands in for the session bus connection: the client only hands it to createProxy, startUnit and the unit read. */
const FAKE_CONNECTION = {isFakeConnection: true};
const SERVICE_STARTED_AT_USEC = 1_794_000_000_000_000;
/** Wall-clock time every source below was sampled at. */
const SAMPLED_AT_USEC = 1_794_000_001_000_000;
/** A later sample of a source: what a Changed or a fresher state carries. */
const RESAMPLED_AT_USEC = 1_794_000_031_000_000;
const PUBLISHED_AT_USEC = 1_794_000_002_000_000;
/** The wall clock when the first state is answered: a second after the sources were sampled. */
const FIRST_STATE_REAL_USEC = SAMPLED_AT_USEC + USEC_PER_SECOND;
/** systemd's monotonic time of a condition check the start job made: any time after boot. */
const CONDITION_CHECKED_AT_MONOTONIC_USEC = 5_000_000;
/** The wire names, written out rather than imported, so a renamed constant fails here instead of moving with it. */
const GET_STATE = 'GetState';
const WATCH_COCKPIT = 'WatchCockpit';
const UNWATCH_COCKPIT = 'UnwatchCockpit';
const FOCUS_SESSION = 'FocusSession';
const CHANGED_SIGNAL = 'Changed';
const SINGLE_STRING_SIGNATURE = '(s)';
const NAME_OWNER_NOTIFY_SIGNAL = 'notify::g-name-owner';
const PROXY_SIGNAL = 'g-signal';
/** CockpitClientState's values, written out. */
const STARTING = 'starting';
const SKIPPED = 'skipped';
const LIVE = 'live';
const VANISHED = 'vanished';
const FOCUSABLE_SESSION_ID = 'wL:p1';
/** What focusSession resolves to whenever FocusSession gives no readable reply. */
const INTERNAL_FOCUS_REPLY = {focused: false, windowPid: null, error: 'internal', windowPidCandidates: []};
/** Array.at's index of the last element. */
const LATEST_INDEX = -1;
/** What valueOnceSettled gives for a promise still pending. */
const UNSETTLED = 'unsettled';

/** The layout the service answers, in parseLayout's shape so a round trip compares equal. */
const LAYOUT = {
    monitor: {vendor: 'DEL', product: 'DELL U2723QE'},
    groups: [
        {id: 'machine', caption: 'MACHINE', columns: 2, cards: ['system', 'apps', 'connections', 'health']},
        {id: 'agents', caption: 'AGENTS', columns: 1, cards: ['sessions', 'seats']},
    ],
};
/** The layout after the owner edited the config: one group fewer. */
const EDITED_LAYOUT = {...LAYOUT, groups: [LAYOUT.groups[0]]};
const CONFIG_INVALID_ERROR = 'groups[1].columns is not a whole number';

/** Each source as the service publishes it, its fields in the reader's order so a round trip compares equal. */
const SESSIONS_SOURCE = {
    sampledAtUsec: SAMPLED_AT_USEC,
    intervalSeconds: 60,
    herdrRunning: true,
    totalMemoryBytes: 500_000_000,
    counts: {working: 1, blocked: 0, idle: 0, done: 0, unknown: 0},
    rows: [{
        id: FOCUSABLE_SESSION_ID, name: 'host-sync', state: 'working', idleSeconds: 12, idleFromProcessAge: false,
        memoryBytes: 500_000_000, workspaceId: 'wL', paneId: 'p1', account: 'work', contextPercent: 21,
    }],
};
const NETWORK_SOURCE = {
    sampledAtUsec: SAMPLED_AT_USEC,
    intervalSeconds: 10,
    uplink: {kind: 'wired', connectivity: 'full', wifiEnabled: false},
    vpn: {isUp: true, interfaceName: 'tun0'},
    sshMasterCount: 2,
};
const MOUNTS_SOURCE = {
    sampledAtUsec: SAMPLED_AT_USEC,
    intervalSeconds: 30,
    rows: [{
        mountPoint: '/media/user/USB', label: 'USB', kind: 'removable', filesystemType: 'vfat', freeBytes: 1_000,
        totalBytes: 2_000,
    }],
};
/** The mounts source resampled: a new stamp and the USB disk gone. */
const RESAMPLED_MOUNTS_SOURCE = {...MOUNTS_SOURCE, sampledAtUsec: RESAMPLED_AT_USEC, rows: []};
const SOURCES = {sessions: SESSIONS_SOURCE, network: NETWORK_SOURCE, mounts: MOUNTS_SOURCE};

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
        const matchingEntries = [...this._sourcesById]
            .filter(([, source]) => source.intervalSeconds === intervalSeconds);
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
        /** @type {Array<{methodName: string, parameters: GLib.Variant|null, timeoutMs: number,
         *     cancellable: Gio.Cancellable|null, callback: Function, isAnswered: boolean}>} Every call, in order. */
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
     * @param {GLib.Variant|null} parameters - Its parameters.
     * @param {Gio.DBusCallFlags} _flags - Call flags.
     * @param {number} timeoutMs - The call's timeout.
     * @param {Gio.Cancellable|null} cancellable - Its cancellable.
     * @param {(proxy: FakeProxy, result: object) => void} callback - Called with the answer.
     * @returns {void}
     */
    call(methodName, parameters, _flags, timeoutMs, cancellable, callback) {
        this.calls.push({methodName, parameters, timeoutMs, cancellable, callback, isAnswered: false});
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
        this.requests.at(LATEST_INDEX).onCreated(null, proxy);
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
        this.attempts.at(LATEST_INDEX).onAnswered(null);
    }

    /** @returns {void} */
    fail() {
        this.attempts.at(LATEST_INDEX).onAnswered(new GLib.Error(Gio.DBusError, Gio.DBusError.SERVICE_UNKNOWN,
            'The name org.freedesktop.systemd1 was not provided by any .service files'));
    }
}

/**
 * A fake readUnitCondition: what systemd's D-Bus says of cockpit.service. Records each read; a row answers the latest
 * with the three properties.
 */
class FakeSystemdUnit {
    constructor() {
        /** @type {Array<{connection: object, cancellable: Gio.Cancellable, resolve: Function}>} */
        this.reads = [];
        this.readUnitCondition = (connection, cancellable) =>
            new Promise(resolve => this.reads.push({connection, cancellable, resolve}));
    }

    /**
     * @param {{conditionResult: boolean|null, conditionTimestampMonotonic: number|null,
     *     activeState: string|null}} unitCondition - What the latest read resolves to.
     * @returns {void}
     */
    answer(unitCondition) {
        this.reads.at(LATEST_INDEX).resolve(unitCondition);
    }
}

/**
 * Lets every promise callback the client chained run: resolves on the next idle of the main loop, which runs only
 * after the job queue is empty.
 *
 * @returns {Promise<void>}
 */
function settlePromiseCallbacks() {
    return new Promise(resolve => {
        GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            resolve();
            return GLib.SOURCE_REMOVE;
        });
    });
}

/**
 * What a client promise settled to once every promise callback has run, without waiting on it: a promise a regression
 * leaves unsettled fails its row instead of hanging the run.
 *
 * @param {Promise<*>} promise - A promise the client returned.
 * @returns {Promise<*>} Its value; {rejectedWith: message} when it rejected; UNSETTLED when it has not settled.
 */
async function valueOnceSettled(promise) {
    let settledValue = UNSETTLED;
    promise.then(value => {
        settledValue = value;
    }, error => {
        settledValue = {rejectedWith: error?.message ?? String(error)};
    });
    await settlePromiseCallbacks();
    return settledValue;
}

/**
 * Builds a client on fakes and starts it.
 *
 * @param {object} [options] - The fixture's shape.
 * @param {string|null} [options.nameOwner] - The service's owner when the proxy arrives; null for none.
 * @param {boolean} [options.isProxyDelivered] - False to leave the proxy still being created.
 * @param {object|null} [options.cachedLayout] - The layout the extension seeds the client with; none by default.
 * @returns {object} {client, clock, timeouts, serviceStarter, proxyFactory, proxy, systemdUnit, events, logged,
 *     infoLines}.
 */
function makeClientFixture({nameOwner = OWNER, isProxyDelivered = true, cachedLayout = undefined} = {}) {
    const clock = {nowUsec: START_USEC, nowRealUsec: FIRST_STATE_REAL_USEC};
    const timeouts = new FakeTimeouts();
    const serviceStarter = new FakeServiceStarter();
    const proxyFactory = new FakeProxyFactory();
    const systemdUnit = new FakeSystemdUnit();
    const logged = [];
    const infoLines = [];
    const client = new cockpitClientModule.CockpitClient({
        connection: FAKE_CONNECTION,
        startUnit: serviceStarter.startUnit,
        createProxy: proxyFactory.createProxy,
        readUnitCondition: systemdUnit.readUnitCondition,
        nowUsec: () => clock.nowUsec,
        nowRealUsec: () => clock.nowRealUsec,
        timeouts,
        errorLog: new RateLimitedLogger({nowUsec: () => clock.nowUsec, write: line => logged.push(line)}),
        writeInfoLine: line => infoLines.push(line),
        cachedLayout,
    });
    const events = [];
    client.addListener(event => events.push(event));
    client.start();
    const proxy = new FakeProxy(nameOwner);
    if (isProxyDelivered)
        proxyFactory.deliver(proxy);
    return {client, clock, timeouts, serviceStarter, proxyFactory, proxy, systemdUnit, events, logged, infoLines};
}

/**
 * Answers the oldest GetState with a state payload.
 *
 * @param {FakeProxy} proxy - The fixture's proxy.
 * @param {object} [state] - {layout, configError, sources}; LAYOUT, no error and SOURCES by default.
 * @returns {void}
 */
function answerState(proxy, {layout = LAYOUT, configError = null, sources = SOURCES} = {}) {
    const statePayload = buildCockpitStatePayload({
        layout, configError, sources, serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
        latestPublishedAtUsec: PUBLISHED_AT_USEC,
    });
    proxy.answer(GET_STATE, new GLib.Variant(SINGLE_STRING_SIGNATURE, [statePayload]));
}

/**
 * Emits one Changed signal.
 *
 * @param {FakeProxy} proxy - The fixture's proxy.
 * @param {object} change - buildChangedPayload's argument, without the publish time.
 * @returns {void}
 */
function emitChanged(proxy, change) {
    const changedPayload = buildChangedPayload({publishedAtUsec: PUBLISHED_AT_USEC, ...change});
    proxy.emitSignal(CHANGED_SIGNAL, new GLib.Variant(SINGLE_STRING_SIGNATURE, [changedPayload]));
}

/**
 * A started client whose owner was there when the proxy arrived, whose StartUnit was accepted, and whose first
 * GetState was answered with LAYOUT and SOURCES at FIRST_STATE_REAL_USEC. Its events so far are cleared.
 *
 * @returns {object} makeClientFixture's fixture.
 */
function makeLiveClientFixture() {
    const fixture = makeClientFixture();
    fixture.serviceStarter.succeed();
    answerState(fixture.proxy);
    fixture.events.length = 0;
    return fixture;
}

/**
 * Lets an accepted StartUnit's wait run out with no owner, and answers the unit read that follows.
 *
 * @param {object} fixture - A fixture with no owner.
 * @param {object} unitCondition - What systemd says of the unit.
 * @returns {Promise<void>}
 */
async function waitOutAcceptedStart(fixture, unitCondition) {
    fixture.serviceStarter.succeed();
    fixture.timeouts.fire(START_CONFIRMATION_SECONDS);
    fixture.systemdUnit.answer(unitCondition);
    await settlePromiseCallbacks();
}

/** What systemd answers for a unit the start job just skipped: its condition false, checked at a real time. */
const SKIPPED_UNIT_CONDITION = {
    conditionResult: false, conditionTimestampMonotonic: CONDITION_CHECKED_AT_MONOTONIC_USEC, activeState: 'inactive',
};

test('cockpitClient: CockpitClientState names the four states and CockpitClientEventType the three events, frozen',
    () => {
        const {CockpitClientState, CockpitClientEventType} = constantsModule;
        assertEqual({
            states: CockpitClientState, eventTypes: CockpitClientEventType,
            areFrozen: [CockpitClientState, CockpitClientEventType].map(table => Object.isFrozen(table)),
        }, {
            states: {STARTING, SKIPPED, LIVE, VANISHED},
            eventTypes: {STATE: 'state', LAYOUT: 'layout', SOURCES: 'sources'},
            areFrozen: [true, true],
        });
    });

test('cockpitClient: start() calls StartUnit; the name appearing calls GetState, whose answer makes it LIVE with the ' +
    'layout and every source, told as one state, one layout and one sources event', () => {
    const {client, serviceStarter, proxy, timeouts, events} = makeClientFixture({nameOwner: null});
    const stateBeforeOwner = client.state;
    serviceStarter.succeed();
    proxy.setNameOwner(OWNER);
    const stateWhileAsking = client.state;
    answerState(proxy);
    assertEqual({
        stateBeforeOwner, stateWhileAsking, state: client.state, events, layout: client.layout,
        configError: client.configError, sourcesByName: client.sourcesByName,
        startUnitConnections: serviceStarter.attempts.map(attempt => attempt.connection),
        calledMethodNames: proxy.calledMethodNames, pending: timeouts.pendingIntervalsSeconds(),
    }, {
        stateBeforeOwner: STARTING, stateWhileAsking: STARTING, state: LIVE,
        events: [
            {type: 'state', state: LIVE}, {type: 'layout', layout: LAYOUT, configError: null},
            {type: 'sources', names: ['sessions', 'network', 'mounts']},
        ],
        layout: LAYOUT, configError: null, sourcesByName: SOURCES, startUnitConnections: [FAKE_CONNECTION],
        calledMethodNames: [GET_STATE], pending: [],
    });
});

test('cockpitClient: an accepted StartUnit with no name in 15 s whose unit reads ConditionResult false, checked ' +
    '(timestamp above 0), is SKIPPED: no retry, the cached layout kept, one info line and no warning', async () => {
    const fixture = makeClientFixture({nameOwner: null, cachedLayout: LAYOUT});
    const {client, timeouts, serviceStarter, systemdUnit, events, logged, infoLines} = fixture;
    await waitOutAcceptedStart(fixture, SKIPPED_UNIT_CONDITION);
    assertEqual({
        state: client.state, events, pending: timeouts.pendingIntervalsSeconds(), layout: client.layout,
        attemptCount: serviceStarter.attempts.length, readConnections: systemdUnit.reads.map(read => read.connection),
        infoLineCount: infoLines.length, mentionsUnit: infoLines.every(line => line.includes('cockpit.service')),
        logged,
    }, {
        state: SKIPPED, events: [{type: 'state', state: SKIPPED}], pending: [], layout: LAYOUT, attemptCount: 1,
        readConnections: [FAKE_CONNECTION], infoLineCount: 1, mentionsUnit: true, logged: [],
    });
});

test('cockpitClient: an accepted StartUnit with no name in 15 s whose unit reads ConditionResult true is retried ' +
    'after 5, 30, 300, then 300 s, each unconfirmed attempt reading the unit and the failure logged', async () => {
    const fixture = makeClientFixture({nameOwner: null});
    const {client, timeouts, serviceStarter, systemdUnit, logged, infoLines} = fixture;
    const retryDelaysSeconds = [];
    for (const _unconfirmedAttempt of RETRY_DELAYS_SECONDS) {
        await waitOutAcceptedStart(fixture,
            {conditionResult: true, conditionTimestampMonotonic: CONDITION_CHECKED_AT_MONOTONIC_USEC,
                activeState: 'failed'});
        const pendingRetryDelaysSeconds = timeouts.pendingIntervalsSeconds();
        retryDelaysSeconds.push(...pendingRetryDelaysSeconds);
        timeouts.fire(pendingRetryDelaysSeconds[0]);
    }
    assertEqual({
        retryDelaysSeconds, attemptCount: serviceStarter.attempts.length, readCount: systemdUnit.reads.length,
        state: client.state, infoLines, hasUnconfirmedLine: logged.some(line => line.includes('did not appear')),
    }, {
        retryDelaysSeconds: RETRY_DELAYS_SECONDS, attemptCount: RETRY_DELAYS_SECONDS.length + 1,
        readCount: RETRY_DELAYS_SECONDS.length, state: STARTING, infoLines: [], hasUnconfirmedLine: true,
    });
});

test('cockpitClient: a unit that reads ConditionResult false never checked (timestamp 0: R17, a unit never started), ' +
    'or a unit read that failed (all null), is no skip: the retry chain goes on', async () => {
    const unitConditions = {
        neverChecked: {conditionResult: false, conditionTimestampMonotonic: 0, activeState: 'inactive'},
        readFailed: {conditionResult: null, conditionTimestampMonotonic: null, activeState: null},
    };
    const outcomes = {};
    for (const [caseName, unitCondition] of Object.entries(unitConditions)) {
        const fixture = makeClientFixture({nameOwner: null});
        await waitOutAcceptedStart(fixture, unitCondition);
        outcomes[caseName] = {state: fixture.client.state, pending: fixture.timeouts.pendingIntervalsSeconds()};
    }
    assertEqual(outcomes, {
        neverChecked: {state: STARTING, pending: [RETRY_DELAYS_SECONDS[0]]},
        readFailed: {state: STARTING, pending: [RETRY_DELAYS_SECONDS[0]]},
    });
});

test('cockpitClient: a failed StartUnit is retried without reading the unit (only an accepted job can be skipped)',
    () => {
        const {timeouts, serviceStarter, systemdUnit} = makeClientFixture({nameOwner: null});
        serviceStarter.fail();
        assertEqual({pending: timeouts.pendingIntervalsSeconds(), readCount: systemdUnit.reads.length},
            {pending: [RETRY_DELAYS_SECONDS[0]], readCount: 0});
    });

test('cockpitClient: the name appearing while the unit is being read supersedes the read: no SKIPPED, no retry, ' +
    'LIVE once GetState answers', async () => {
    const {client, timeouts, serviceStarter, proxy, systemdUnit, events} = makeClientFixture({nameOwner: null});
    serviceStarter.succeed();
    timeouts.fire(START_CONFIRMATION_SECONDS);
    proxy.setNameOwner(OWNER);
    systemdUnit.answer(SKIPPED_UNIT_CONDITION);
    await settlePromiseCallbacks();
    const stateAfterRead = client.state;
    answerState(proxy);
    assertEqual({stateAfterRead, state: client.state, pending: timeouts.pendingIntervalsSeconds(),
        stateEvents: events.filter(event => event.type === 'state')},
    {stateAfterRead: STARTING, state: LIVE, pending: [], stateEvents: [{type: 'state', state: LIVE}]});
});

test('cockpitClient: start() on a SKIPPED client asks systemd again, from STARTING and a first attempt', async () => {
    const fixture = makeClientFixture({nameOwner: null});
    const {client, timeouts, serviceStarter, events} = fixture;
    await waitOutAcceptedStart(fixture, SKIPPED_UNIT_CONDITION);
    client.start();
    const stateAfterStart = client.state;
    serviceStarter.fail();
    assertEqual({
        stateAfterStart, attemptCount: serviceStarter.attempts.length, pending: timeouts.pendingIntervalsSeconds(),
        events,
    }, {
        stateAfterStart: STARTING, attemptCount: 2, pending: [RETRY_DELAYS_SECONDS[0]],
        events: [{type: 'state', state: SKIPPED}, {type: 'state', state: STARTING}],
    });
});

test('cockpitClient: seeded with a cached layout it has that layout before any answer, and a GetState with the same ' +
    'layout tells no layout event', () => {
    const {client, proxy, events} = makeClientFixture({cachedLayout: LAYOUT});
    const layoutBeforeAnswer = client.layout;
    answerState(proxy);
    assertEqual({layoutBeforeAnswer, eventTypes: events.map(event => event.type)},
        {layoutBeforeAnswer: LAYOUT, eventTypes: ['state', 'sources']});
});

test('cockpitClient: a Changed carrying mounts alone tells one sources event naming mounts only, and replaces only ' +
    'that source', () => {
    const {client, proxy, events} = makeLiveClientFixture();
    emitChanged(proxy, {sources: {mounts: RESAMPLED_MOUNTS_SOURCE}});
    assertEqual({events, sourcesByName: client.sourcesByName}, {
        events: [{type: 'sources', names: ['mounts']}],
        sourcesByName: {...SOURCES, mounts: RESAMPLED_MOUNTS_SOURCE},
    });
});

test('cockpitClient: a Changed carrying the layout and the config error tells one layout event, and no sources event',
    () => {
        const {client, proxy, events} = makeLiveClientFixture();
        emitChanged(proxy, {sources: {}, layout: EDITED_LAYOUT, configError: CONFIG_INVALID_ERROR});
        assertEqual({events, layout: client.layout, configError: client.configError}, {
            events: [{type: 'layout', layout: EDITED_LAYOUT, configError: CONFIG_INVALID_ERROR}],
            layout: EDITED_LAYOUT, configError: CONFIG_INVALID_ERROR,
        });
    });

test('cockpitClient: a signal other than Changed, a Changed of another signature or text that is not JSON changes ' +
    'nothing; each malformed Changed is logged', () => {
    const {client, proxy, events, logged} = makeLiveClientFixture();
    const changedPayload = buildChangedPayload({publishedAtUsec: PUBLISHED_AT_USEC,
        sources: {mounts: RESAMPLED_MOUNTS_SOURCE}});
    proxy.emitSignal('Sample', new GLib.Variant(SINGLE_STRING_SIGNATURE, [changedPayload]));
    proxy.emitSignal(CHANGED_SIGNAL, new GLib.Variant('(i)', [7]));
    proxy.emitSignal(CHANGED_SIGNAL, new GLib.Variant(SINGLE_STRING_SIGNATURE, ['{"sources": {']));
    assertEqual({events, sourcesByName: client.sourcesByName,
        changedLogLines: logged.filter(line => line.includes(CHANGED_SIGNAL)).length},
    {events: [], sourcesByName: SOURCES, changedLogLines: 2});
});

test('cockpitClient: a GetState that fails is logged and leaves it STARTING; the next Changed asks for the state ' +
    'again rather than draw a part of it', () => {
    const {client, proxy, events, logged} = makeClientFixture();
    proxy.fail(GET_STATE, new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.TIMED_OUT, 'Timeout was reached'));
    const stateAfterFailure = client.state;
    emitChanged(proxy, {sources: {mounts: RESAMPLED_MOUNTS_SOURCE}});
    const eventsBeforeState = [...events];
    answerState(proxy);
    assertEqual({
        stateAfterFailure, eventsBeforeState, state: client.state,
        stateCallCount: proxy.callsOf(GET_STATE).length,
        stateLogLines: logged.filter(line => line.includes(GET_STATE)).length,
    }, {
        stateAfterFailure: STARTING, eventsBeforeState: [], state: LIVE, stateCallCount: 2, stateLogLines: 1,
    });
});

test('cockpitClient: pullIfSuspicious(\'mounts\') (a 30 s interval) calls GetState at 100 s, not again at 110 s, ' +
    'and again at 131 s', async () => {
    const {client, clock, proxy} = makeLiveClientFixture();
    const pullResults = [];
    const stateCallCounts = [];
    for (const secondsAfterSample of [100, 110, 131]) {
        clock.nowRealUsec = SAMPLED_AT_USEC + secondsAfterSample * USEC_PER_SECOND;
        const pullPromise = client.pullIfSuspicious('mounts');
        stateCallCounts.push(proxy.callsOf(GET_STATE).length);
        if (proxy.calls.at(LATEST_INDEX).isAnswered === false)
            answerState(proxy);
        pullResults.push(await valueOnceSettled(pullPromise));
    }
    assertEqual({pullResults, stateCallCounts}, {
        pullResults: [{pulled: true}, {pulled: false}, {pulled: true}], stateCallCounts: [2, 2, 3],
    });
});

test('cockpitClient: a source past three intervals is suspect but not stale; a pull answering its same old stamp ' +
    'makes it stale and tells a sources event naming it; a fresher stamp makes it fresh again', async () => {
    const {client, clock, proxy, events} = makeLiveClientFixture();
    clock.nowRealUsec = SAMPLED_AT_USEC + 100 * USEC_PER_SECOND;
    const beforePull = client.sourceFreshness('mounts');
    const pullPromise = client.pullIfSuspicious('mounts');
    clock.nowRealUsec += USEC_PER_SECOND;
    answerState(proxy);
    const pullResult = await valueOnceSettled(pullPromise);
    const afterSameStamp = client.sourceFreshness('mounts');
    const eventsAfterSameStamp = [...events];
    emitChanged(proxy, {sources: {mounts: {...RESAMPLED_MOUNTS_SOURCE,
        sampledAtUsec: clock.nowRealUsec - USEC_PER_SECOND}}});
    assertEqual({
        beforePull: beforePull.isStale, beforePullShouldPull: beforePull.shouldPull, pullResult,
        afterSameStamp: afterSameStamp.isStale, eventsAfterSameStamp,
        afterFresherStamp: client.sourceFreshness('mounts').isStale,
    }, {
        beforePull: false, beforePullShouldPull: true, pullResult: {pulled: true}, afterSameStamp: true,
        eventsAfterSameStamp: [{type: 'sources', names: ['mounts']}], afterFresherStamp: false,
    });
});

test('cockpitClient: a pull whose GetState fails is logged, leaves the source suspect but not stale, and is not ' +
    'repeated within the interval', async () => {
    const {client, clock, proxy, logged} = makeLiveClientFixture();
    clock.nowRealUsec = SAMPLED_AT_USEC + 100 * USEC_PER_SECOND;
    const pullPromise = client.pullIfSuspicious('mounts');
    proxy.fail(GET_STATE, new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.TIMED_OUT, 'Timeout was reached'));
    const pullResult = await valueOnceSettled(pullPromise);
    clock.nowRealUsec += USEC_PER_SECOND;
    assertEqual({
        pullResult, freshness: client.sourceFreshness('mounts'),
        stateLogLines: logged.filter(line => line.includes(GET_STATE)).length,
    }, {
        pullResult: {pulled: true}, freshness: {isStale: false, shouldPull: false, ageSeconds: 101},
        stateLogLines: 1,
    });
});

test('cockpitClient: the name losing its owner makes it VANISHED with its sources kept, calls no StartUnit and sends ' +
    'no UnwatchCockpit, then or at destroy() (the watch left with the owner)', () => {
    const {client, timeouts, serviceStarter, proxy, events} = makeLiveClientFixture();
    client.setWatchWanted(true);
    proxy.setNameOwner(null);
    client.setWatchWanted(false);
    client.destroy();
    assertEqual({
        events, sourcesByName: client.sourcesByName, layout: client.layout,
        attemptCount: serviceStarter.attempts.length, calledMethodNames: proxy.calledMethodNames,
        pending: timeouts.pendingIntervalsSeconds(),
    }, {
        events: [{type: 'state', state: VANISHED}], sourcesByName: SOURCES, layout: LAYOUT, attemptCount: 1,
        calledMethodNames: [GET_STATE, WATCH_COCKPIT], pending: [],
    });
});

test('cockpitClient: once VANISHED, a suspect source\'s pull asks nobody and completes at once, so it reads stale; ' +
    'a new owner is read with GetState and makes it LIVE', async () => {
    const {client, clock, proxy, events} = makeLiveClientFixture();
    proxy.setNameOwner(null);
    clock.nowRealUsec = SAMPLED_AT_USEC + 100 * USEC_PER_SECOND;
    const pullResult = await valueOnceSettled(client.pullIfSuspicious('mounts'));
    const freshnessWhileGone = client.sourceFreshness('mounts');
    const stateCallsWhileGone = proxy.callsOf(GET_STATE).length;
    proxy.setNameOwner(NEXT_OWNER);
    answerState(proxy, {sources: {...SOURCES, mounts: {...MOUNTS_SOURCE, sampledAtUsec: clock.nowRealUsec}}});
    assertEqual({
        pullResult, isStaleWhileGone: freshnessWhileGone.isStale, stateCallsWhileGone, state: client.state,
        isStaleAfterReturn: client.sourceFreshness('mounts').isStale, events,
    }, {
        pullResult: {pulled: true}, isStaleWhileGone: true, stateCallsWhileGone: 1, state: LIVE,
        isStaleAfterReturn: false,
        events: [
            {type: 'state', state: VANISHED}, {type: 'sources', names: ['mounts']}, {type: 'state', state: LIVE},
            {type: 'sources', names: ['mounts']},
        ],
    });
});

test('cockpitClient: setWatchWanted(true) before the owner exists sends WatchCockpit once it appears; only a change ' +
    'is sent, and every call is asynchronous with DBUS_CALL_TIMEOUT_MS', () => {
    const {client, proxy} = makeClientFixture({nameOwner: null});
    client.setWatchWanted(true);
    const calledBeforeOwner = [...proxy.calledMethodNames];
    proxy.setNameOwner(OWNER);
    client.setWatchWanted(true);
    client.setWatchWanted(false);
    client.setWatchWanted(false);
    const callShapes = new Set(proxy.calls.map(call => `${call.timeoutMs}/${typeof call.callback}`));
    assertEqual({calledBeforeOwner, calledMethodNames: proxy.calledMethodNames, callShapes: [...callShapes]}, {
        calledBeforeOwner: [], calledMethodNames: [GET_STATE, WATCH_COCKPIT, UNWATCH_COCKPIT],
        callShapes: [`${constantsModule.DBUS_CALL_TIMEOUT_MS}/function`],
    });
});

test('cockpitClient: destroy() sends UnwatchCockpit (uncancellable) while the watch is held, cancels the pending ' +
    'GetState, disconnects from the proxy, removes its timeouts, and nothing after it does anything', () => {
    const {client, timeouts, serviceStarter, proxy, events} = makeClientFixture();
    client.setWatchWanted(true);
    serviceStarter.fail();
    const pendingStateCall = proxy.callsOf(GET_STATE)[0];
    client.destroy();
    const unwatchCalls = proxy.callsOf(UNWATCH_COCKPIT);
    answerState(proxy);
    client.setWatchWanted(false);
    client.start();
    assertEqual({
        unwatchCancellables: unwatchCalls.map(call => call.cancellable),
        isStateCallCancelled: pendingStateCall.cancellable?.is_cancelled() ?? null,
        connectedHandlerCount: proxy.connectedHandlerCount, pending: timeouts.pendingIntervalsSeconds(),
        events, calledMethodNames: proxy.calledMethodNames, attemptCount: serviceStarter.attempts.length,
        state: client.state,
    }, {
        unwatchCancellables: [null], isStateCallCancelled: true, connectedHandlerCount: 0, pending: [], events: [],
        calledMethodNames: [GET_STATE, WATCH_COCKPIT, UNWATCH_COCKPIT], attemptCount: 1, state: STARTING,
    });
});

test('cockpitClient: destroy() while an accepted StartUnit waits 15 s, or while a retry waits 5 s, leaves no timeout ' +
    'behind', () => {
    const waiting = makeClientFixture({nameOwner: null});
    waiting.serviceStarter.succeed();
    const pendingWhileWaiting = waiting.timeouts.pendingIntervalsSeconds();
    waiting.client.destroy();
    const retrying = makeClientFixture({nameOwner: null});
    retrying.serviceStarter.fail();
    const pendingWhileRetrying = retrying.timeouts.pendingIntervalsSeconds();
    retrying.client.destroy();
    assertEqual({
        pendingWhileWaiting, pendingWhileRetrying, pendingAfterDestroy: [
            ...waiting.timeouts.pendingIntervalsSeconds(), ...retrying.timeouts.pendingIntervalsSeconds()],
    }, {
        pendingWhileWaiting: [START_CONFIRMATION_SECONDS], pendingWhileRetrying: [RETRY_DELAYS_SECONDS[0]],
        pendingAfterDestroy: [],
    });
});

test('cockpitClient: destroy() while the unit is being read leaves the client as it was when the read answers',
    async () => {
        const {client, timeouts, serviceStarter, systemdUnit, events, infoLines} = makeClientFixture({nameOwner: null});
        serviceStarter.succeed();
        timeouts.fire(START_CONFIRMATION_SECONDS);
        client.destroy();
        systemdUnit.answer(SKIPPED_UNIT_CONDITION);
        await settlePromiseCallbacks();
        assertEqual({state: client.state, events, infoLines, pending: timeouts.pendingIntervalsSeconds(),
            isReadCancelled: systemdUnit.reads[0].cancellable.is_cancelled()},
        {state: STARTING, events: [], infoLines: [], pending: [], isReadCancelled: true});
    });

test('cockpitClient: focusSession sends the id and resolves to the parsed reply', async () => {
    const {client, proxy} = makeLiveClientFixture();
    const replyPromise = client.focusSession(FOCUSABLE_SESSION_ID);
    const [focusCall] = proxy.callsOf(FOCUS_SESSION);
    const replyText = buildFocusSessionReply({focused: true, windowPid: null, error: null,
        windowPidCandidates: [4242, 4100]});
    proxy.answer(FOCUS_SESSION, new GLib.Variant(SINGLE_STRING_SIGNATURE, [replyText]));
    assertEqual({parameters: focusCall.parameters.deepUnpack(), reply: await valueOnceSettled(replyPromise)}, {
        parameters: [FOCUSABLE_SESSION_ID],
        reply: {focused: true, windowPid: null, error: null, windowPidCandidates: [4242, 4100]},
    });
});

test('cockpitClient: focusSession resolves (never rejects) to the internal reply when the call fails or the reply ' +
    'is not JSON, logged once', async () => {
    const {client, proxy, logged} = makeLiveClientFixture();
    const failedPromise = client.focusSession(FOCUSABLE_SESSION_ID);
    proxy.fail(FOCUS_SESSION, new GLib.Error(Gio.DBusError, Gio.DBusError.NO_REPLY, 'Did not receive a reply'));
    const unreadablePromise = client.focusSession(FOCUSABLE_SESSION_ID);
    proxy.answer(FOCUS_SESSION, new GLib.Variant(SINGLE_STRING_SIGNATURE, ['focused']));
    assertEqual({
        failed: await valueOnceSettled(failedPromise), unreadable: await valueOnceSettled(unreadablePromise),
        focusLogLines: logged.filter(line => line.includes(FOCUS_SESSION)).length,
    }, {failed: INTERNAL_FOCUS_REPLY, unreadable: INTERNAL_FOCUS_REPLY, focusLogLines: 1});
});

test('cockpitClient: a listener that throws is logged and the next still runs; a removed one is not called', () => {
    const {client, proxy, logged} = makeLiveClientFixture();
    const seenByLater = [];
    const removedListenerId = client.addListener(() => seenByLater.push('removed'));
    client.addListener(() => {
        throw new Error('listener bug');
    });
    client.addListener(event => seenByLater.push(event.type));
    client.removeListener(removedListenerId);
    emitChanged(proxy, {sources: {mounts: RESAMPLED_MOUNTS_SOURCE}});
    assertEqual({seenByLater, listenerLogLines: logged.filter(line => line.includes('listener bug')).length},
        {seenByLater: ['sources'], listenerLogLines: 1});
});
