// cockpitClient.js with a fake link to the service (in place of serviceLink.js's), fake timeouts, a fake StartUnit
// and a fake systemd unit (readUnitCondition), so every row runs under plain gjs, on no bus at all, in a fixed order:
// each fake answers only when a row tells it to. The payloads are built with lib/cockpitProtocol.js's builders, as the
// cockpit service builds them. The fakes are copies of client.test.js's, as the repo copies a few classes rather than
// share them between test files. The real link, StartUnit and unit read are exercised on a private bus by
// cockpit-client-dbus.test.js.
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
/** Stands in for the session bus connection: the client only hands it to createLink, startUnit and the unit read. */
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
/** What FakeLink records in its actions for a subscribe and an unsubscribe; a call records its method's name. */
const SUBSCRIBE = 'subscribe';
const UNSUBSCRIBE = 'unsubscribe';
/** CockpitClientState's values, written out. */
const STARTING = 'starting';
const SKIPPED = 'skipped';
const LIVE = 'live';
const VANISHED = 'vanished';
const FOCUSABLE_SESSION_ID = 'wL:p1';
/** The D-Bus error systemd answers for a unit it has not loaded, or has no file for. */
const NO_SUCH_UNIT_ERROR_NAME = 'org.freedesktop.systemd1.NoSuchUnit';
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
/** COCKPIT_SOURCE_STALE_INTERVALS (3), written out: how many of its intervals a source ages before it is suspect. */
const STALE_INTERVALS = 3;
/** The interval of mounts, the source the pull rows suspect. */
const MOUNTS_INTERVAL_SECONDS = MOUNTS_SOURCE.intervalSeconds;
/** How old a mounts stamp may be before it is suspect: past this, the first pull is due. */
const MOUNTS_SUSPECT_AFTER_SECONDS = STALE_INTERVALS * MOUNTS_INTERVAL_SECONDS;
/** How far the wall clock steps back in the row where it does: an hour. */
const CLOCK_STEP_BACK_SECONDS = 3600;

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

/**
 * A fake link to the service (serviceLink.js's link, as cockpitClient.js's createCockpitLink makes it): a row reports
 * the owner, emits Changed and answers each call. It starts unsubscribed, as the cockpit's link does, and records every
 * subscribe, unsubscribe and call in one ordered list, so a row can read their order.
 */
class FakeLink {
    /**
     * @param {object} connection - The connection the client passed.
     * @param {{onOwnerChanged: (nameOwner: string|null) => void, onSignal: (parameters: GLib.Variant) => void}}
     *     callbacks - The client's.
     */
    constructor(connection, {onOwnerChanged, onSignal}) {
        this.connection = connection;
        this._onOwnerChanged = onOwnerChanged;
        this._onSignal = onSignal;
        this._isSubscribed = false;
        this._isDestroyed = false;
        /** @type {Array<{methodName: string, parameters: GLib.Variant|null, cancellable: Gio.Cancellable|null,
         *     onAnswered: Function, isAnswered: boolean}>} Every call, in order. */
        this.calls = [];
        /** @type {string[]} SUBSCRIBE, UNSUBSCRIBE, or a call's method name, for each in order. */
        this.actions = [];
    }

    /** @returns {boolean} True while Changed is delivered. */
    get isSubscribed() {
        return this._isSubscribed;
    }

    /** @returns {boolean} True once the client has destroyed the link. */
    get isDestroyed() {
        return this._isDestroyed;
    }

    /**
     * Subscribes or unsubscribes, as the real link does: a change only, and nothing after destroy().
     *
     * @param {boolean} isSubscribed - True to deliver Changed from now on.
     * @returns {void}
     */
    setSubscribed(isSubscribed) {
        if (this._isDestroyed || isSubscribed === this._isSubscribed)
            return;
        this._isSubscribed = isSubscribed;
        this.actions.push(isSubscribed ? SUBSCRIBE : UNSUBSCRIBE);
    }

    /**
     * Records a call; a row answers it with answer() or fail().
     *
     * @param {string} methodName - The method.
     * @param {GLib.Variant|null} parameters - Its parameters.
     * @param {Gio.Cancellable|null} cancellable - Its cancellable.
     * @param {(error: Error|null, reply: GLib.Variant|null) => void} onAnswered - Called with the answer.
     * @returns {void}
     */
    call(methodName, parameters, cancellable, onAnswered) {
        this.calls.push({methodName, parameters, cancellable, onAnswered, isAnswered: false});
        this.actions.push(methodName);
    }

    /**
     * Records the destroy and drops the subscription, as the real link does. Owner reports go on (see setNameOwner).
     *
     * @returns {void}
     */
    destroy() {
        this._isDestroyed = true;
        this._isSubscribed = false;
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
     * Delivers a D-Bus signal from the owner as the subscription does: only while subscribed, and only Changed (the
     * member the cockpit's link subscribes to).
     *
     * @param {string} signalName - The signal's name.
     * @param {GLib.Variant} parameters - Its parameters.
     * @returns {void}
     */
    emitSignal(signalName, parameters) {
        if (this._isSubscribed && signalName === CHANGED_SIGNAL)
            this._onSignal(parameters);
    }

    /**
     * Hands parameters straight to the client's signal callback, subscribed or not: what reaches the client then is
     * the client's own doing.
     *
     * @param {GLib.Variant} parameters - A signal's parameters.
     * @returns {void}
     */
    handToSignalCallback(parameters) {
        this._onSignal(parameters);
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

    /** @returns {void} */
    succeed() {
        this.attempts.at(LATEST_INDEX).onAnswered(null);
    }

    /** @returns {void} */
    fail() {
        this.attempts.at(LATEST_INDEX).onAnswered(new GLib.Error(Gio.DBusError, Gio.DBusError.SERVICE_UNKNOWN,
            'The name org.freedesktop.systemd1 was not provided by any .service files'));
    }

    /**
     * Fails the latest attempt as systemd does for a unit it has no file for: the remote error NoSuchUnit.
     *
     * @returns {void}
     */
    failWithUnitNotFound() {
        this.attempts.at(LATEST_INDEX).onAnswered(
            Gio.DBusError.new_for_dbus_error(NO_SUCH_UNIT_ERROR_NAME, 'Unit cockpit.service not found.'));
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
     * @param {{conditionResult: boolean|null, conditionTimestampMonotonic: number|null, activeState: string|null,
     *     isUnitMissing: boolean}} unitCondition - What the latest read resolves to.
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
 * @param {string|null} [options.nameOwner] - The service's owner when the name watch first reports; null for none.
 * @param {boolean} [options.isOwnerReported] - False to leave the name watch's first report still to come.
 * @param {object|null} [options.cachedLayout] - The layout the extension seeds the client with; none by default.
 * @param {boolean} [options.isSubscriptionWanted] - True to want the Changed subscription from the start, as the
 *     extension does while a cockpit card can be seen. False by default, as the client starts.
 * @returns {object} {client, clock, timeouts, serviceStarter, linkFactory, link, systemdUnit, events, logged,
 *     infoLines}.
 */
function makeClientFixture({
    nameOwner = OWNER, isOwnerReported = true, cachedLayout = undefined, isSubscriptionWanted = false,
} = {}) {
    const clock = {nowUsec: START_USEC, nowRealUsec: FIRST_STATE_REAL_USEC};
    const timeouts = new FakeTimeouts();
    const serviceStarter = new FakeServiceStarter();
    const linkFactory = new FakeLinkFactory();
    const systemdUnit = new FakeSystemdUnit();
    const logged = [];
    const infoLines = [];
    const client = new cockpitClientModule.CockpitClient({
        connection: FAKE_CONNECTION,
        startUnit: serviceStarter.startUnit,
        createLink: linkFactory.createLink,
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
    client.setSubscriptionWanted(isSubscriptionWanted);
    client.start();
    const [link] = linkFactory.links;
    if (isOwnerReported)
        link?.setNameOwner(nameOwner);
    return {client, clock, timeouts, serviceStarter, linkFactory, link, systemdUnit, events, logged, infoLines};
}

/**
 * Answers the oldest GetState with a state payload.
 *
 * @param {FakeLink} link - The fixture's link.
 * @param {object} [state] - {layout, configError, sources}; LAYOUT, no error and SOURCES by default.
 * @returns {void}
 */
function answerState(link, {layout = LAYOUT, configError = null, sources = SOURCES} = {}) {
    const statePayload = buildCockpitStatePayload({
        layout, configError, sources, serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
        latestPublishedAtUsec: PUBLISHED_AT_USEC,
    });
    link.answer(GET_STATE, new GLib.Variant(SINGLE_STRING_SIGNATURE, [statePayload]));
}

/**
 * Answers the oldest GetState with SOURCES, except that mounts carries another stamp.
 *
 * @param {FakeLink} link - The fixture's link.
 * @param {number} sampledAtUsec - The wall-clock stamp mounts carries.
 * @returns {void}
 */
function answerStateWithMountsSampledAt(link, sampledAtUsec) {
    answerState(link, {sources: {...SOURCES, mounts: {...MOUNTS_SOURCE, sampledAtUsec}}});
}

/**
 * A wall-clock time some seconds after another.
 *
 * @param {number} stampUsec - Wall-clock microseconds.
 * @param {number} seconds - How many seconds later.
 * @returns {number} The later time, in microseconds.
 */
function usecAfter(stampUsec, seconds) {
    return stampUsec + seconds * USEC_PER_SECOND;
}

/**
 * A Changed signal's parameters, as the service sends them.
 *
 * @param {object} change - buildChangedPayload's argument, without the publish time.
 * @returns {GLib.Variant} The '(s)' tuple holding the payload.
 */
function changedParameters(change) {
    const changedPayload = buildChangedPayload({publishedAtUsec: PUBLISHED_AT_USEC, ...change});
    return new GLib.Variant(SINGLE_STRING_SIGNATURE, [changedPayload]);
}

/**
 * Emits one Changed signal.
 *
 * @param {FakeLink} link - The fixture's link.
 * @param {object} change - buildChangedPayload's argument, without the publish time.
 * @returns {void}
 */
function emitChanged(link, change) {
    link.emitSignal(CHANGED_SIGNAL, changedParameters(change));
}

/**
 * A started client that wants the Changed subscription, whose owner was there at the name watch's first report, whose
 * StartUnit was accepted, and whose first GetState was answered with LAYOUT and SOURCES at FIRST_STATE_REAL_USEC. Its
 * events so far are cleared.
 *
 * @returns {object} makeClientFixture's fixture.
 */
function makeLiveClientFixture() {
    const fixture = makeClientFixture({isSubscriptionWanted: true});
    fixture.serviceStarter.succeed();
    answerState(fixture.link);
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
    isUnitMissing: false,
};
/** What the read gives when GetUnit answers NoSuchUnit: systemd has unloaded the unit since its start job. */
const MISSING_UNIT_CONDITION = {
    conditionResult: null, conditionTimestampMonotonic: null, activeState: null, isUnitMissing: true,
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
    const {client, serviceStarter, link, timeouts, events} = makeClientFixture({nameOwner: null});
    const stateBeforeOwner = client.state;
    serviceStarter.succeed();
    link.setNameOwner(OWNER);
    const stateWhileAsking = client.state;
    answerState(link);
    assertEqual({
        stateBeforeOwner, stateWhileAsking, state: client.state, events, layout: client.layout,
        configError: client.configError, sourcesByName: client.sourcesByName,
        startUnitConnections: serviceStarter.attempts.map(attempt => attempt.connection),
        calledMethodNames: link.calledMethodNames, pending: timeouts.pendingIntervalsSeconds(),
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
    'or a unit read that failed for another reason than a missing unit (all null), is no skip: the retry chain goes ' +
    'on', async () => {
    const unitConditions = {
        neverChecked: {conditionResult: false, conditionTimestampMonotonic: 0, activeState: 'inactive',
            isUnitMissing: false},
        readFailed: {conditionResult: null, conditionTimestampMonotonic: null, activeState: null,
            isUnitMissing: false},
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

test('cockpitClient: a StartUnit that fails otherwise than NoSuchUnit (no systemd here) is retried without reading ' +
    'the unit',
    () => {
        const {timeouts, serviceStarter, systemdUnit} = makeClientFixture({nameOwner: null});
        serviceStarter.fail();
        assertEqual({pending: timeouts.pendingIntervalsSeconds(), readCount: systemdUnit.reads.length},
            {pending: [RETRY_DELAYS_SECONDS[0]], readCount: 0});
    });

test('cockpitClient: a StartUnit rejected with NoSuchUnit (the unit not linked) is SKIPPED at once: no unit read, no ' +
    'retry, the cached layout kept, one info line and no warning', () => {
    const {client, timeouts, serviceStarter, systemdUnit, events, logged, infoLines} =
        makeClientFixture({nameOwner: null, cachedLayout: LAYOUT});
    serviceStarter.failWithUnitNotFound();
    assertEqual({
        state: client.state, events, pending: timeouts.pendingIntervalsSeconds(), layout: client.layout,
        readCount: systemdUnit.reads.length, infoLineCount: infoLines.length, logged,
    }, {
        state: SKIPPED, events: [{type: 'state', state: SKIPPED}], pending: [], layout: LAYOUT, readCount: 0,
        infoLineCount: 1, logged: [],
    });
});

test('cockpitClient: an accepted StartUnit with no name in 15 s whose unit read finds no unit (GetUnit answered ' +
    'NoSuchUnit: unloaded after a skipped job) is SKIPPED: no retry, the cached layout kept, one info line and no ' +
    'warning', async () => {
    const fixture = makeClientFixture({nameOwner: null, cachedLayout: LAYOUT});
    const {client, timeouts, serviceStarter, events, logged, infoLines} = fixture;
    await waitOutAcceptedStart(fixture, MISSING_UNIT_CONDITION);
    assertEqual({
        state: client.state, events, pending: timeouts.pendingIntervalsSeconds(), layout: client.layout,
        attemptCount: serviceStarter.attempts.length, infoLineCount: infoLines.length, logged,
    }, {
        state: SKIPPED, events: [{type: 'state', state: SKIPPED}], pending: [], layout: LAYOUT, attemptCount: 1,
        infoLineCount: 1, logged: [],
    });
});

test('cockpitClient: the name appearing while the unit is being read supersedes the read: no SKIPPED, no retry, ' +
    'LIVE once GetState answers', async () => {
    const {client, timeouts, serviceStarter, link, systemdUnit, events} = makeClientFixture({nameOwner: null});
    serviceStarter.succeed();
    timeouts.fire(START_CONFIRMATION_SECONDS);
    link.setNameOwner(OWNER);
    systemdUnit.answer(SKIPPED_UNIT_CONDITION);
    await settlePromiseCallbacks();
    const stateAfterRead = client.state;
    answerState(link);
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
    const {client, link, events} = makeClientFixture({cachedLayout: LAYOUT});
    const layoutBeforeAnswer = client.layout;
    answerState(link);
    assertEqual({layoutBeforeAnswer, eventTypes: events.map(event => event.type)},
        {layoutBeforeAnswer: LAYOUT, eventTypes: ['state', 'sources']});
});

test('cockpitClient: a Changed carrying mounts alone tells one sources event naming mounts only, and replaces only ' +
    'that source', () => {
    const {client, link, events} = makeLiveClientFixture();
    emitChanged(link, {sources: {mounts: RESAMPLED_MOUNTS_SOURCE}});
    assertEqual({events, sourcesByName: client.sourcesByName}, {
        events: [{type: 'sources', names: ['mounts']}],
        sourcesByName: {...SOURCES, mounts: RESAMPLED_MOUNTS_SOURCE},
    });
});

test('cockpitClient: a Changed carrying the layout and the config error tells one layout event, and no sources event',
    () => {
        const {client, link, events} = makeLiveClientFixture();
        emitChanged(link, {sources: {}, layout: EDITED_LAYOUT, configError: CONFIG_INVALID_ERROR});
        assertEqual({events, layout: client.layout, configError: client.configError}, {
            events: [{type: 'layout', layout: EDITED_LAYOUT, configError: CONFIG_INVALID_ERROR}],
            layout: EDITED_LAYOUT, configError: CONFIG_INVALID_ERROR,
        });
    });

test('cockpitClient: a signal other than Changed, a Changed of another signature or text that is not JSON changes ' +
    'nothing; each malformed Changed is logged', () => {
    const {client, link, events, logged} = makeLiveClientFixture();
    const changedPayload = buildChangedPayload({publishedAtUsec: PUBLISHED_AT_USEC,
        sources: {mounts: RESAMPLED_MOUNTS_SOURCE}});
    // A signal of another name is the subscription's to drop: the link subscribes to Changed alone (pinned on the
    // private bus by cockpit-client-dbus.test.js), and the fake drops it as the subscription does.
    link.emitSignal('Sample', new GLib.Variant(SINGLE_STRING_SIGNATURE, [changedPayload]));
    link.emitSignal(CHANGED_SIGNAL, new GLib.Variant('(i)', [7]));
    link.emitSignal(CHANGED_SIGNAL, new GLib.Variant(SINGLE_STRING_SIGNATURE, ['{"sources": {']));
    assertEqual({events, sourcesByName: client.sourcesByName,
        changedLogLines: logged.filter(line => line.includes(CHANGED_SIGNAL)).length},
    {events: [], sourcesByName: SOURCES, changedLogLines: 2});
});

test('cockpitClient: a GetState that fails is logged and leaves it STARTING; the next Changed asks for the state ' +
    'again rather than draw a part of it', () => {
    const {client, link, events, logged} = makeClientFixture({isSubscriptionWanted: true});
    link.fail(GET_STATE, new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.TIMED_OUT, 'Timeout was reached'));
    const stateAfterFailure = client.state;
    emitChanged(link, {sources: {mounts: RESAMPLED_MOUNTS_SOURCE}});
    const eventsBeforeState = [...events];
    answerState(link);
    assertEqual({
        stateAfterFailure, eventsBeforeState, state: client.state,
        stateCallCount: link.callsOf(GET_STATE).length,
        stateLogLines: logged.filter(line => line.includes(GET_STATE)).length,
    }, {
        stateAfterFailure: STARTING, eventsBeforeState: [], state: LIVE, stateCallCount: 2, stateLogLines: 1,
    });
});

test('cockpitClient: pullIfSuspicious(\'mounts\') (a 30 s interval) calls GetState at 100 s, not again at 110 s, ' +
    'and again at 131 s', async () => {
    const {client, clock, link} = makeLiveClientFixture();
    const pullResults = [];
    const stateCallCounts = [];
    for (const secondsAfterSample of [100, 110, 131]) {
        clock.nowRealUsec = SAMPLED_AT_USEC + secondsAfterSample * USEC_PER_SECOND;
        const pullPromise = client.pullIfSuspicious('mounts');
        stateCallCounts.push(link.callsOf(GET_STATE).length);
        if (link.calls.at(LATEST_INDEX).isAnswered === false)
            answerState(link);
        pullResults.push(await valueOnceSettled(pullPromise));
    }
    assertEqual({pullResults, stateCallCounts}, {
        pullResults: [{pulled: true}, {pulled: false}, {pulled: true}], stateCallCounts: [2, 2, 3],
    });
});

test('cockpitClient: a source past three intervals is suspect but not stale; a pull answering its same old stamp ' +
    'makes it stale and tells a sources event naming it; a fresher stamp makes it fresh again', async () => {
    const {client, clock, link, events} = makeLiveClientFixture();
    clock.nowRealUsec = SAMPLED_AT_USEC + 100 * USEC_PER_SECOND;
    const beforePull = client.sourceFreshness('mounts');
    const pullPromise = client.pullIfSuspicious('mounts');
    clock.nowRealUsec += USEC_PER_SECOND;
    answerState(link);
    const pullResult = await valueOnceSettled(pullPromise);
    const afterSameStamp = client.sourceFreshness('mounts');
    const eventsAfterSameStamp = [...events];
    emitChanged(link, {sources: {mounts: {...RESAMPLED_MOUNTS_SOURCE,
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

test('cockpitClient: a pull whose GetState fails completes the pull (D6): a service that keeps its name but hangs ' +
    'reads stale after one failed pull, told as a sources event and logged once; the next interval pulls again, and ' +
    'a later pull answering a fresh stamp makes the source fresh again, and three intervals after that stamp ' +
    'suspect, not stale (D5: the fresh stamp cleared the failed pulls\' stamps)', async () => {
    const {client, clock, link, events, logged} = makeLiveClientFixture();
    const stateCallsBeforePulls = link.callsOf(GET_STATE).length;
    const hungServiceError = new GLib.Error(Gio.IOErrorEnum, Gio.IOErrorEnum.TIMED_OUT, 'Timeout was reached');
    const freshnessAfterEachPull = [];
    const pullResults = [];
    for (const secondsAfterSample of [100, 131]) {
        clock.nowRealUsec = usecAfter(SAMPLED_AT_USEC, secondsAfterSample);
        const failedPull = client.pullIfSuspicious('mounts');
        link.fail(GET_STATE, hungServiceError);
        pullResults.push(await valueOnceSettled(failedPull));
        freshnessAfterEachPull.push(client.sourceFreshness('mounts'));
    }
    clock.nowRealUsec = usecAfter(SAMPLED_AT_USEC, 162);
    const answeredPull = client.pullIfSuspicious('mounts');
    const freshSampledAtUsec = usecAfter(SAMPLED_AT_USEC, 161);
    answerStateWithMountsSampledAt(link, freshSampledAtUsec);
    pullResults.push(await valueOnceSettled(answeredPull));
    freshnessAfterEachPull.push(client.sourceFreshness('mounts'));
    // Without the reset, the answered pull's completion (S+162 s) is later than the fresh stamp, and this reads stale.
    clock.nowRealUsec = usecAfter(freshSampledAtUsec, MOUNTS_SUSPECT_AFTER_SECONDS + 1);
    const atNextSuspicion = client.sourceFreshness('mounts');
    const mountsEvent = {type: 'sources', names: ['mounts']};
    assertEqual({
        pullResults, freshnessAfterEachPull, atNextSuspicion, state: client.state,
        pullStateCallCount: link.callsOf(GET_STATE).length - stateCallsBeforePulls, events,
        stateLogLines: logged.filter(line => line.includes(GET_STATE)).length,
    }, {
        pullResults: [{pulled: true}, {pulled: true}, {pulled: true}],
        freshnessAfterEachPull: [
            {isStale: true, shouldPull: false, ageSeconds: 100}, {isStale: true, shouldPull: false, ageSeconds: 131},
            {isStale: false, shouldPull: false, ageSeconds: 1},
        ],
        atNextSuspicion: {isStale: false, shouldPull: true, ageSeconds: 91},
        state: LIVE, pullStateCallCount: 3, events: [mountsEvent, mountsEvent, mountsEvent], stateLogLines: 1,
    });
});

test('cockpitClient: a pull answering a fresher stamp clears the source\'s pull stamps (D5): three intervals after ' +
    'that stamp it is suspect but not stale, and only a pull answering that same stamp makes it stale', async () => {
    const {client, clock, link} = makeLiveClientFixture();
    const firstSuspicionUsec = usecAfter(SAMPLED_AT_USEC, MOUNTS_SUSPECT_AFTER_SECONDS + 1);
    // The service resampled mounts a second before the pull, and sent no Changed: the data did not change.
    const refreshedSampledAtUsec = usecAfter(firstSuspicionUsec, -1);
    clock.nowRealUsec = firstSuspicionUsec;
    const refreshingPull = client.pullIfSuspicious('mounts');
    clock.nowRealUsec = usecAfter(firstSuspicionUsec, 1);
    answerStateWithMountsSampledAt(link, refreshedSampledAtUsec);
    const refreshingPullResult = await valueOnceSettled(refreshingPull);
    const afterRefresh = client.sourceFreshness('mounts');
    clock.nowRealUsec = usecAfter(refreshedSampledAtUsec, MOUNTS_SUSPECT_AFTER_SECONDS + 1);
    const atNextSuspicion = client.sourceFreshness('mounts');
    const sameStampPull = client.pullIfSuspicious('mounts');
    clock.nowRealUsec = usecAfter(clock.nowRealUsec, 1);
    answerStateWithMountsSampledAt(link, refreshedSampledAtUsec);
    const sameStampPullResult = await valueOnceSettled(sameStampPull);
    assertEqual({
        refreshingPullResult, afterRefresh, atNextSuspicion, sameStampPullResult,
        afterSameStamp: client.sourceFreshness('mounts'),
    }, {
        refreshingPullResult: {pulled: true}, afterRefresh: {isStale: false, shouldPull: false, ageSeconds: 2},
        atNextSuspicion: {isStale: false, shouldPull: true, ageSeconds: 91}, sameStampPullResult: {pulled: true},
        afterSameStamp: {isStale: true, shouldPull: false, ageSeconds: 92},
    });
});

test('cockpitClient: the review\'s counter-example (D5): mounts (a 30 s interval) sampled at S, pulled at S+100 s ' +
    'with the answer a fresh stamp S+99 s, the pull requested and completed at S+100 s: at S+190 s it is not stale, ' +
    'and a pull is due', async () => {
    const {client, clock, link} = makeLiveClientFixture();
    clock.nowRealUsec = usecAfter(SAMPLED_AT_USEC, 100);
    const pullPromise = client.pullIfSuspicious('mounts');
    answerStateWithMountsSampledAt(link, usecAfter(SAMPLED_AT_USEC, 99));
    const pullResult = await valueOnceSettled(pullPromise);
    clock.nowRealUsec = usecAfter(SAMPLED_AT_USEC, 190);
    assertEqual({intervalSeconds: MOUNTS_INTERVAL_SECONDS, pullResult, freshness: client.sourceFreshness('mounts')}, {
        intervalSeconds: 30, pullResult: {pulled: true},
        freshness: {isStale: false, shouldPull: true, ageSeconds: 91},
    });
});

test('cockpitClient: a Changed refreshing a source while its pull\'s GetState is in flight ends that pull\'s cycle ' +
    '(D5): the answer, carrying the same fresh stamp, stamps no completion, so three intervals after that stamp the ' +
    'source is suspect but not stale', async () => {
    const {client, clock, link} = makeLiveClientFixture();
    const suspicionUsec = usecAfter(SAMPLED_AT_USEC, MOUNTS_SUSPECT_AFTER_SECONDS + 1);
    clock.nowRealUsec = suspicionUsec;
    const pullPromise = client.pullIfSuspicious('mounts');
    emitChanged(link, {sources: {mounts: {...MOUNTS_SOURCE, sampledAtUsec: suspicionUsec}}});
    clock.nowRealUsec = usecAfter(suspicionUsec, 1);
    answerStateWithMountsSampledAt(link, suspicionUsec);
    const pullResult = await valueOnceSettled(pullPromise);
    clock.nowRealUsec = usecAfter(suspicionUsec, MOUNTS_SUSPECT_AFTER_SECONDS + 1);
    assertEqual({pullResult, freshness: client.sourceFreshness('mounts')},
        {pullResult: {pulled: true}, freshness: {isStale: false, shouldPull: true, ageSeconds: 91}});
});

test('cockpitClient: pulls for two sources made while one GetState is in flight join it: exactly one GetState, ' +
    'both settle only when it answers, and one sources event names both', async () => {
    const {client, clock, link, events} = makeLiveClientFixture();
    const stateCallsBeforePulls = link.callsOf(GET_STATE).length;
    clock.nowRealUsec = usecAfter(SAMPLED_AT_USEC, MOUNTS_SUSPECT_AFTER_SECONDS + 1);
    const mountsPull = client.pullIfSuspicious('mounts');
    const networkPull = client.pullIfSuspicious('network');
    const pullStateCallCount = link.callsOf(GET_STATE).length - stateCallsBeforePulls;
    const beforeAnswer = [await valueOnceSettled(mountsPull), await valueOnceSettled(networkPull)];
    answerState(link);
    const afterAnswer = [await valueOnceSettled(mountsPull), await valueOnceSettled(networkPull)];
    assertEqual({
        pullStateCallCount, beforeAnswer, afterAnswer, events,
        isStaleByName: {mounts: client.sourceFreshness('mounts').isStale,
            network: client.sourceFreshness('network').isStale},
    }, {
        pullStateCallCount: 1, beforeAnswer: [UNSETTLED, UNSETTLED], afterAnswer: [{pulled: true}, {pulled: true}],
        events: [{type: 'sources', names: ['network', 'mounts']}], isStaleByName: {mounts: true, network: true},
    });
});

test('cockpitClient: a Changed carrying an earlier stamp than the one held (the wall clock stepped back) clears the ' +
    'source\'s pull stamps too: three intervals after that stamp it is suspect, not stale', async () => {
    const {client, clock, link} = makeLiveClientFixture();
    clock.nowRealUsec = usecAfter(SAMPLED_AT_USEC, MOUNTS_SUSPECT_AFTER_SECONDS + 10);
    const sameStampPull = client.pullIfSuspicious('mounts');
    answerState(link);
    const sameStampPullResult = await valueOnceSettled(sameStampPull);
    const afterSameStampPull = client.sourceFreshness('mounts');
    // The wall clock steps back an hour, and the service samples mounts on it: the new stamp is earlier than the old
    // one, and than the completed pull's stamp, which is taken on the old clock.
    const steppedBackSampledAtUsec = usecAfter(clock.nowRealUsec, -CLOCK_STEP_BACK_SECONDS);
    clock.nowRealUsec = steppedBackSampledAtUsec;
    emitChanged(link, {sources: {mounts: {...MOUNTS_SOURCE, sampledAtUsec: steppedBackSampledAtUsec}}});
    clock.nowRealUsec = usecAfter(steppedBackSampledAtUsec, MOUNTS_SUSPECT_AFTER_SECONDS + 1);
    assertEqual({sameStampPullResult, afterSameStampPull, atNextSuspicion: client.sourceFreshness('mounts')}, {
        sameStampPullResult: {pulled: true}, afterSameStampPull: {isStale: true, shouldPull: false, ageSeconds: 100},
        atNextSuspicion: {isStale: false, shouldPull: true, ageSeconds: 91},
    });
});

test('cockpitClient: the owner leaving while a pull\'s GetState is in flight completes that pull (D6): it settles, ' +
    'the source reads stale, and a sources event naming it follows the VANISHED state event', async () => {
    const {client, clock, link, events} = makeLiveClientFixture();
    clock.nowRealUsec = usecAfter(SAMPLED_AT_USEC, MOUNTS_SUSPECT_AFTER_SECONDS + 10);
    const pullPromise = client.pullIfSuspicious('mounts');
    const beforeVanish = await valueOnceSettled(pullPromise);
    link.setNameOwner(null);
    assertEqual({
        beforeVanish, afterVanish: await valueOnceSettled(pullPromise), freshness: client.sourceFreshness('mounts'),
        events,
    }, {
        beforeVanish: UNSETTLED, afterVanish: {pulled: true},
        freshness: {isStale: true, shouldPull: false, ageSeconds: 100},
        events: [{type: 'state', state: VANISHED}, {type: 'sources', names: ['mounts']}],
    });
});

test('cockpitClient: the name losing its owner makes it VANISHED with its sources kept, calls no StartUnit and arms ' +
    'no retry for one (both read before destroy(), which would remove a timer), and sends no UnwatchCockpit, then or ' +
    'at destroy() (the watch left with the owner)', () => {
    const {client, timeouts, serviceStarter, link, events} = makeLiveClientFixture();
    client.setWatchWanted(true);
    link.setNameOwner(null);
    client.setWatchWanted(false);
    const pendingAfterVanish = timeouts.pendingIntervalsSeconds();
    const attemptCountAfterVanish = serviceStarter.attempts.length;
    client.destroy();
    assertEqual({
        events, sourcesByName: client.sourcesByName, layout: client.layout, pendingAfterVanish,
        attemptCountAfterVanish, calledMethodNames: link.calledMethodNames,
    }, {
        events: [{type: 'state', state: VANISHED}], sourcesByName: SOURCES, layout: LAYOUT, pendingAfterVanish: [],
        attemptCountAfterVanish: 1, calledMethodNames: [GET_STATE, WATCH_COCKPIT],
    });
});

test('cockpitClient: once VANISHED, a suspect source\'s pull asks nobody and completes at once, so it reads stale; ' +
    'a new owner is read with GetState and makes it LIVE', async () => {
    const {client, clock, link, events} = makeLiveClientFixture();
    link.setNameOwner(null);
    clock.nowRealUsec = SAMPLED_AT_USEC + 100 * USEC_PER_SECOND;
    const pullResult = await valueOnceSettled(client.pullIfSuspicious('mounts'));
    const freshnessWhileGone = client.sourceFreshness('mounts');
    const stateCallsWhileGone = link.callsOf(GET_STATE).length;
    link.setNameOwner(NEXT_OWNER);
    answerState(link, {sources: {...SOURCES, mounts: {...MOUNTS_SOURCE, sampledAtUsec: clock.nowRealUsec}}});
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

// How each call goes out (to the owner's unique name, with DBUS_CALL_TIMEOUT_MS) is the link's, pinned by the link rows
// in cockpit-client-dbus.test.js.
test('cockpitClient: setWatchWanted(true) before the owner exists sends WatchCockpit once it appears; only a change ' +
    'is sent, and every call is asynchronous', () => {
    const {client, link} = makeClientFixture({nameOwner: null});
    client.setWatchWanted(true);
    const calledBeforeOwner = [...link.calledMethodNames];
    link.setNameOwner(OWNER);
    client.setWatchWanted(true);
    client.setWatchWanted(false);
    client.setWatchWanted(false);
    const callShapes = new Set(link.calls.map(call => typeof call.onAnswered));
    assertEqual({calledBeforeOwner, calledMethodNames: link.calledMethodNames, callShapes: [...callShapes]}, {
        calledBeforeOwner: [], calledMethodNames: [GET_STATE, WATCH_COCKPIT, UNWATCH_COCKPIT], callShapes: ['function'],
    });
});

test('cockpitClient: destroy() sends UnwatchCockpit (uncancellable) while the watch is held, cancels the pending ' +
    'GetState, destroys the link, removes its timeouts, and nothing after it does anything', () => {
    const {client, timeouts, serviceStarter, link, events} = makeClientFixture();
    client.setWatchWanted(true);
    serviceStarter.fail();
    const pendingStateCall = link.callsOf(GET_STATE)[0];
    client.destroy();
    const unwatchCalls = link.callsOf(UNWATCH_COCKPIT);
    answerState(link);
    client.setWatchWanted(false);
    client.start();
    assertEqual({
        unwatchCancellables: unwatchCalls.map(call => call.cancellable),
        isStateCallCancelled: pendingStateCall.cancellable?.is_cancelled() ?? null,
        isLinkDestroyed: link.isDestroyed, pending: timeouts.pendingIntervalsSeconds(),
        events, calledMethodNames: link.calledMethodNames, attemptCount: serviceStarter.attempts.length,
        state: client.state,
    }, {
        unwatchCancellables: [null], isStateCallCancelled: true, isLinkDestroyed: true, pending: [], events: [],
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
    const {client, link} = makeLiveClientFixture();
    const replyPromise = client.focusSession(FOCUSABLE_SESSION_ID);
    const [focusCall] = link.callsOf(FOCUS_SESSION);
    const replyText = buildFocusSessionReply({focused: true, windowPid: null, error: null,
        windowPidCandidates: [4242, 4100]});
    link.answer(FOCUS_SESSION, new GLib.Variant(SINGLE_STRING_SIGNATURE, [replyText]));
    assertEqual({parameters: focusCall.parameters.deepUnpack(), reply: await valueOnceSettled(replyPromise)}, {
        parameters: [FOCUSABLE_SESSION_ID],
        reply: {focused: true, windowPid: null, error: null, windowPidCandidates: [4242, 4100]},
    });
});

test('cockpitClient: focusSession resolves (never rejects) to the internal reply when the call fails or the reply ' +
    'is not JSON, logged once', async () => {
    const {client, link, logged} = makeLiveClientFixture();
    const failedPromise = client.focusSession(FOCUSABLE_SESSION_ID);
    link.fail(FOCUS_SESSION, new GLib.Error(Gio.DBusError, Gio.DBusError.NO_REPLY, 'Did not receive a reply'));
    const unreadablePromise = client.focusSession(FOCUSABLE_SESSION_ID);
    link.answer(FOCUS_SESSION, new GLib.Variant(SINGLE_STRING_SIGNATURE, ['focused']));
    assertEqual({
        failed: await valueOnceSettled(failedPromise), unreadable: await valueOnceSettled(unreadablePromise),
        focusLogLines: logged.filter(line => line.includes(FOCUS_SESSION)).length,
    }, {failed: INTERNAL_FOCUS_REPLY, unreadable: INTERNAL_FOCUS_REPLY, focusLogLines: 1});
});

test('cockpitClient: a listener that throws is logged and the next still runs; a removed one is not called', () => {
    const {client, link, logged} = makeLiveClientFixture();
    const seenByLater = [];
    const removedListenerId = client.addListener(() => seenByLater.push('removed'));
    client.addListener(() => {
        throw new Error('listener bug');
    });
    client.addListener(event => seenByLater.push(event.type));
    client.removeListener(removedListenerId);
    emitChanged(link, {sources: {mounts: RESAMPLED_MOUNTS_SOURCE}});
    assertEqual({seenByLater, listenerLogLines: logged.filter(line => line.includes('listener bug')).length},
        {seenByLater: ['sources'], listenerLogLines: 1});
});

test('cockpitClient: with the subscription not wanted (as it starts) it holds none, yet the owner\'s appearance ' +
    'reads GetState once and makes it LIVE; a Changed handed to its signal callback reaches no listener', () => {
    const {client, link, events} = makeClientFixture();
    answerState(link);
    const eventCountAfterState = events.length;
    link.handToSignalCallback(changedParameters({sources: {mounts: RESAMPLED_MOUNTS_SOURCE}}));
    assertEqual({
        isSubscribed: link.isSubscribed, actions: link.actions, state: client.state,
        eventsAfterChanged: events.slice(eventCountAfterState), mounts: client.sourcesByName.mounts,
    }, {
        isSubscribed: false, actions: [GET_STATE], state: LIVE, eventsAfterChanged: [], mounts: MOUNTS_SOURCE,
    });
});

test('cockpitClient: wanting the subscription while the service has an owner subscribes, then reads GetState, in ' +
    'that order; the answer is applied, and a Changed then reaches listeners', () => {
    const {client, link, events} = makeClientFixture();
    answerState(link);
    const actionCountBeforeWant = link.actions.length;
    events.length = 0;
    client.setSubscriptionWanted(true);
    const actionsOnWant = link.actions.slice(actionCountBeforeWant);
    answerState(link, {sources: {...SOURCES, mounts: RESAMPLED_MOUNTS_SOURCE}});
    emitChanged(link, {sources: {network: {...NETWORK_SOURCE, sampledAtUsec: RESAMPLED_AT_USEC}}});
    assertEqual({actionsOnWant, isSubscribed: link.isSubscribed, events}, {
        actionsOnWant: [SUBSCRIBE, GET_STATE], isSubscribed: true,
        events: [{type: 'sources', names: ['mounts']}, {type: 'sources', names: ['network']}],
    });
});

test('cockpitClient: wanting the subscription with no owner sends nothing; the owner\'s appearance then subscribes ' +
    'and reads GetState once', () => {
    const {client, link} = makeClientFixture({nameOwner: null});
    client.setSubscriptionWanted(true);
    const actionsBeforeOwner = [...link.actions];
    link.setNameOwner(OWNER);
    assertEqual({actionsBeforeOwner, actions: link.actions}, {
        actionsBeforeOwner: [], actions: [SUBSCRIBE, GET_STATE],
    });
});

test('cockpitClient: unwanting the subscription unsubscribes, and a GetState still in flight is applied when it ' +
    'answers; a Changed of a new owner sent while unsubscribed is missed, and read afresh by the GetState that ' +
    'follows the subscribe on return', () => {
    const {client, link, events} = makeClientFixture({isSubscriptionWanted: true});
    client.setSubscriptionWanted(false);
    const isSubscribedAfterUnwant = link.isSubscribed;
    answerState(link);
    const stateAfterInFlightAnswer = client.state;
    link.setNameOwner(NEXT_OWNER);
    answerState(link);
    emitChanged(link, {sources: {mounts: RESAMPLED_MOUNTS_SOURCE}});
    const mountsWhileUnsubscribed = client.sourcesByName.mounts;
    events.length = 0;
    client.setSubscriptionWanted(true);
    answerState(link, {sources: {...SOURCES, mounts: RESAMPLED_MOUNTS_SOURCE}});
    assertEqual({
        isSubscribedAfterUnwant, stateAfterInFlightAnswer, mountsWhileUnsubscribed, actions: link.actions,
        eventsOnReturn: events, mountsOnReturn: client.sourcesByName.mounts,
    }, {
        isSubscribedAfterUnwant: false, stateAfterInFlightAnswer: LIVE, mountsWhileUnsubscribed: MOUNTS_SOURCE,
        actions: [SUBSCRIBE, GET_STATE, UNSUBSCRIBE, GET_STATE, SUBSCRIBE, GET_STATE],
        eventsOnReturn: [{type: 'sources', names: ['mounts']}], mountsOnReturn: RESAMPLED_MOUNTS_SOURCE,
    });
});

test('cockpitClient: wanting the subscription as it already is does nothing, nor does setSubscriptionWanted after ' +
    'destroy()', () => {
    const {client, link} = makeClientFixture();
    answerState(link);
    const actionCountBeforeWant = link.actions.length;
    client.setSubscriptionWanted(false);
    client.setSubscriptionWanted(true);
    client.setSubscriptionWanted(true);
    answerState(link);
    const actionsWhileWanted = link.actions.slice(actionCountBeforeWant);
    client.destroy();
    const actionCountAtDestroy = link.actions.length;
    client.setSubscriptionWanted(false);
    client.setSubscriptionWanted(true);
    assertEqual({actionsWhileWanted, actionsAfterDestroy: link.actions.slice(actionCountAtDestroy)}, {
        actionsWhileWanted: [SUBSCRIBE, GET_STATE], actionsAfterDestroy: [],
    });
});
