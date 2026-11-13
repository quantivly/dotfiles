// The compiled sampler (resource-pulse-sampler/) on a PRIVATE message bus: the rules its bus link must keep. Run only
// by run-sampler-program.js under `dbus-run-session`, which scripts/test-resource-pulse-sampler.sh starts with the
// program's path. Every copy of the program a row starts is given the private bus's address, checked by
// requirePrivateBusAddress, as its session bus, and is stopped again by that row whatever happens; the last row
// asserts from the rows' own bookkeeping that none is left running.
//
// Until the sampler is wired (task 12), the program serves a counter in place of the sampler: each tick raises it and
// emits Sample {"sequence": n}; GetState answers {"sequence": n, "vanishedCallers": k}, where k counts the
// NameVanished events of the callers it follows (the sender of every WatchDetail).
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {openPrivateBusConnection, requirePrivateBusAddress, waitUntil} from './privateBus.js';
import {
    GET_STATE_METHOD_NAME, RESOURCE_PULSE_BUS_NAME, RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_INTERFACE_XML,
    RESOURCE_PULSE_OBJECT_PATH, SAMPLE_SIGNAL_NAME, WATCH_DETAIL_METHOD_NAME,
} from '../extensions/resource-pulse@dotfiles/lib/protocol.js';

const SESSION_BUS_ADDRESS_VARIABLE = 'DBUS_SESSION_BUS_ADDRESS';
const TICK_INTERVAL_FLAG = '--tick-interval-ms';
/** Ticks this fast give the order row hundreds of Samples to interleave its replies with. */
const FAST_TICK_INTERVAL_MS = 20;
const ORDER_RUN_DURATION_MS = 10_000;
/** Below these the order row could pass on a run that hardly ticked or hardly asked. */
const MIN_ORDER_REPLY_COUNT = 200;
const MIN_ORDER_SAMPLE_COUNT = 400;
/** How many violations a failing order row names. */
const REPORTED_VIOLATION_COUNT = 5;
const START_COUNT = 50;
const CALL_TIMEOUT_MS = 2000;
/** How long a started program may take to own the name. */
const NAME_OWNED_TIMEOUT_MS = 5000;
/** How long the bus may take to free the name once its owner has exited. */
const NAME_FREED_TIMEOUT_MS = 2000;
/** How long a program may take to exit after a signal, or a second copy to give up. */
const PROGRAM_EXIT_TIMEOUT_MS = 5000;
const TERMINATE_SIGNAL = 15;
const NAME_HELD_EXIT_STATUS = 1;
const BUS_DAEMON_NAME = 'org.freedesktop.DBus';
const BUS_DAEMON_OBJECT_PATH = '/org/freedesktop/DBus';
const BUS_DAEMON_INTERFACE_NAME = 'org.freedesktop.DBus';
const REQUEST_NAME_METHOD = 'RequestName';
const GET_NAME_OWNER_METHOD = 'GetNameOwner';
/** RequestName's flags and its "the name has another owner" reply, from the D-Bus specification. */
const REQUEST_NAME_REPLACE_EXISTING_FLAG = 0x2;
const REQUEST_NAME_DO_NOT_QUEUE_FLAG = 0x4;
const REQUEST_NAME_REPLY_EXISTS = 3;
const INTROSPECTABLE_INTERFACE_NAME = 'org.freedesktop.DBus.Introspectable';
const INTROSPECT_METHOD = 'Introspect';
const UNKNOWN_METHOD_ERROR_NAME = 'org.freedesktop.DBus.Error.UnknownMethod';
/** A method the interface does not have. */
const MISSING_METHOD_NAME = 'NoSuchMethod';
/** The budget for reporting a vanished caller, and how long the count must then stay put. */
const VANISH_REPORT_TIMEOUT_MS = 2000;
const VANISH_REPORTED_ONCE_WINDOW_MS = 1000;
const STATE_POLL_INTERVAL_MS = 20;
const STRING_REPLY_TYPE = new GLib.VariantType('(s)');
const NAME_OWNER_REPLY_TYPE = new GLib.VariantType('(s)');
const REQUEST_NAME_REPLY_TYPE = new GLib.VariantType('(u)');
const SAMPLE_ARRIVAL = 'Sample';
const REPLY_ARRIVAL = 'reply';

/** The program under test; run-sampler-program.js sets it from its first argument. */
let samplerProgramPath = null;
/** Every copy of the program a row started that has not yet been seen to exit. */
const runningPrograms = new Set();

/**
 * Sets the program the rows start.
 *
 * @param {string|undefined} programPath - The path run-sampler-program.js was given.
 * @returns {void}
 * @throws {Error} When the path is missing or is not an executable file.
 */
export function setSamplerProgramPath(programPath) {
    if (!programPath || !GLib.file_test(programPath, GLib.FileTest.IS_EXECUTABLE))
        throw new Error(`no executable sampler program at ${programPath}`);
    samplerProgramPath = programPath;
}

/**
 * Starts a copy of the program on the private bus and starts waiting for its exit.
 *
 * @param {string[]} programArguments - The program's arguments.
 * @returns {{subprocess: Gio.Subprocess, processId: string, hasExited: boolean, exitStatus: number|null}} The copy;
 *     hasExited and exitStatus (null when it was killed by a signal) are filled in when it exits.
 */
function spawnProgram(programArguments) {
    if (samplerProgramPath === null)
        throw new Error('no sampler program was given to the runner');
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    launcher.setenv(SESSION_BUS_ADDRESS_VARIABLE, requirePrivateBusAddress(), true);
    const subprocess = launcher.spawnv([samplerProgramPath, ...programArguments]);
    const program = {subprocess, processId: subprocess.get_identifier(), hasExited: false, exitStatus: null};
    runningPrograms.add(program);
    subprocess.wait_async(null, (_subprocess, result) => {
        try {
            subprocess.wait_finish(result);
        } catch (error) {
            // The wait failed, so the exit was not seen: the copy stays in runningPrograms and the last row fails.
            printerr(`waiting for program ${program.processId} failed: ${error.message}`);
            return;
        }
        program.hasExited = true;
        program.exitStatus = subprocess.get_if_exited() ? subprocess.get_exit_status() : null;
        runningPrograms.delete(program);
    });
    return program;
}

/**
 * Stops a copy of the program: SIGTERM, then SIGKILL if it outlives PROGRAM_EXIT_TIMEOUT_MS.
 *
 * @param {{subprocess: Gio.Subprocess, processId: string, hasExited: boolean}} program - From spawnProgram.
 * @returns {Promise<void>}
 * @throws {Error} When it has not exited even after SIGKILL.
 */
async function stopProgram(program) {
    if (program.hasExited)
        return;
    program.subprocess.send_signal(TERMINATE_SIGNAL);
    if (await waitUntil(() => program.hasExited, PROGRAM_EXIT_TIMEOUT_MS))
        return;
    program.subprocess.force_exit();
    if (!await waitUntil(() => program.hasExited, PROGRAM_EXIT_TIMEOUT_MS))
        throw new Error(`program ${program.processId} did not exit after SIGKILL`);
}

/**
 * Follows who owns the bus name, as a client of it does.
 *
 * @param {Gio.DBusConnection} connection - The watcher's connection.
 * @param {(ownerName: string) => void} [onAppeared] - Called in the name-appeared handler itself.
 * @returns {{ownerName: string|null, isKnown: boolean, stop: () => void}} The owner's unique name, or null while
 *     the name has none; isKnown turns true at the watcher's first answer.
 */
function watchBusName(connection, onAppeared = () => {}) {
    const watch = {ownerName: null, isKnown: false};
    const watcherId = Gio.bus_watch_name_on_connection(connection, RESOURCE_PULSE_BUS_NAME,
        Gio.BusNameWatcherFlags.NONE, (_connection, _name, ownerName) => {
            watch.ownerName = ownerName;
            watch.isKnown = true;
            onAppeared(ownerName);
        }, () => {
            watch.ownerName = null;
            watch.isKnown = true;
        });
    watch.stop = () => Gio.bus_unwatch_name(watcherId);
    return watch;
}

/**
 * Waits until the bus name has no owner, so that a row's watcher cannot mistake the copy a row before left for its
 * own.
 *
 * @param {{ownerName: string|null, isKnown: boolean}} watch - From watchBusName.
 * @returns {Promise<void>}
 * @throws {Error} When the name is still owned after NAME_FREED_TIMEOUT_MS.
 */
async function waitForFreeName(watch) {
    if (!await waitUntil(() => watch.isKnown && watch.ownerName === null, NAME_FREED_TIMEOUT_MS))
        throw new Error(`${RESOURCE_PULSE_BUS_NAME} still has an owner (${watch.ownerName}) before the row starts`);
}

/**
 * Starts the program, waits for it to own the name, runs a row against it, and stops it and closes every
 * connection the row opened, whatever happens.
 *
 * @param {string[]} programArguments - The program's arguments.
 * @param {(fixture: object) => Promise<void>} body - The row; gets {program, ownerName, openClient}.
 * @returns {Promise<void>}
 */
async function withServingProgram(programArguments, body) {
    const watcherConnection = openPrivateBusConnection();
    const clientConnections = [];
    const watch = watchBusName(watcherConnection);
    let program = null;
    try {
        await waitForFreeName(watch);
        program = spawnProgram(programArguments);
        const servingProgram = program;
        await waitUntil(() => watch.ownerName !== null || servingProgram.hasExited, NAME_OWNED_TIMEOUT_MS);
        if (watch.ownerName === null) {
            throw new Error(`the program never owned ${RESOURCE_PULSE_BUS_NAME} ` +
                `(exited: ${program.hasExited}, status ${program.exitStatus})`);
        }
        await body({
            program,
            ownerName: watch.ownerName,
            openClient: () => {
                const clientConnection = openPrivateBusConnection();
                clientConnections.push(clientConnection);
                return clientConnection;
            },
        });
    } finally {
        watch.stop();
        if (program !== null)
            await stopProgram(program);
        for (const connection of [...clientConnections, watcherConnection]) {
            if (!connection.is_closed())
                connection.close_sync(null);
        }
    }
}

/**
 * Calls a method and resolves with its reply.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @param {{destination: string, objectPath: string, interfaceName: string, methodName: string,
 *     parameters?: GLib.Variant|null, replyType?: GLib.VariantType|null, onReply?: (reply: GLib.Variant) => void}} call
 *     - The call; onReply runs inside the reply's own callback, so the arrival it records is in arrival order.
 * @returns {Promise<GLib.Variant>} The reply.
 */
function callMethod(connection, {destination, objectPath, interfaceName, methodName, parameters = null,
    replyType = null, onReply = () => {}}) {
    return new Promise((resolve, reject) => {
        connection.call(destination, objectPath, interfaceName, methodName, parameters, replyType,
            Gio.DBusCallFlags.NONE, CALL_TIMEOUT_MS, null, (callingConnection, result) => {
                let reply;
                try {
                    reply = callingConnection.call_finish(result);
                } catch (error) {
                    reject(error);
                    return;
                }
                onReply(reply);
                resolve(reply);
            });
    });
}

/**
 * Calls a method of the program's interface by its bus name.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @param {string} methodName - The method.
 * @param {object} [options] - replyType and onReply, as callMethod takes them.
 * @returns {Promise<GLib.Variant>} The reply.
 */
function callProgramMethod(connection, methodName, options = {}) {
    return callMethod(connection, {
        destination: RESOURCE_PULSE_BUS_NAME,
        objectPath: RESOURCE_PULSE_OBJECT_PATH,
        interfaceName: RESOURCE_PULSE_INTERFACE_NAME,
        methodName,
        ...options,
    });
}

/**
 * Reads the JSON text of a one-string reply.
 *
 * @param {GLib.Variant} reply - A reply of type (s).
 * @returns {object} The parsed JSON.
 */
function parseStringReply(reply) {
    const [text] = reply.deepUnpack();
    return JSON.parse(text);
}

/**
 * Calls GetState and parses its JSON.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @returns {Promise<{sequence: number, vanishedCallers: number}>} The placeholder's state.
 */
async function fetchState(connection) {
    return parseStringReply(await callProgramMethod(connection, GET_STATE_METHOD_NAME,
        {replyType: STRING_REPLY_TYPE}));
}

/**
 * Asks the bus who owns the program's name.
 *
 * @param {Gio.DBusConnection} connection - The caller.
 * @returns {Promise<string>} The owner's unique name.
 */
async function fetchNameOwner(connection) {
    const reply = await callMethod(connection, {
        destination: BUS_DAEMON_NAME,
        objectPath: BUS_DAEMON_OBJECT_PATH,
        interfaceName: BUS_DAEMON_INTERFACE_NAME,
        methodName: GET_NAME_OWNER_METHOD,
        parameters: new GLib.Variant('(s)', [RESOURCE_PULSE_BUS_NAME]),
        replyType: NAME_OWNER_REPLY_TYPE,
    });
    const [ownerName] = reply.deepUnpack();
    return ownerName;
}

/**
 * Resolves after a delay, running the main loop meanwhile.
 *
 * @param {number} delayMs - How long to wait.
 * @returns {Promise<void>}
 */
function delay(delayMs) {
    return new Promise(resolve => {
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, delayMs, () => {
            resolve();
            return GLib.SOURCE_REMOVE;
        });
    });
}

/**
 * Checks the order of Samples and state replies as one connection received them: a reply carrying sequence N must
 * come after Sample N (no Sample above N before it) and before Sample N+1 (the first Sample after it is N+1).
 *
 * @param {Array<{kind: string, sequence: number}>} arrivals - Samples and replies, in arrival order.
 * @returns {{replyCount: number, sampleCount: number, violationCount: number, violations: string[]}} The counts,
 *     and the first REPORTED_VIOLATION_COUNT violations.
 */
function checkReplyOrder(arrivals) {
    // Walk backwards once to know, for each arrival, the sequence of the first Sample after it.
    const nextSampleSequenceAfter = new Array(arrivals.length).fill(null);
    let nextSampleSequence = null;
    for (let index = arrivals.length - 1; index >= 0; index--) {
        nextSampleSequenceAfter[index] = nextSampleSequence;
        if (arrivals[index].kind === SAMPLE_ARRIVAL)
            nextSampleSequence = arrivals[index].sequence;
    }
    const violations = [];
    let highestSampleSequence = null;
    let replyCount = 0;
    let sampleCount = 0;
    arrivals.forEach(({kind, sequence}, index) => {
        if (kind === SAMPLE_ARRIVAL) {
            sampleCount++;
            highestSampleSequence = Math.max(highestSampleSequence ?? sequence, sequence);
            return;
        }
        replyCount++;
        if (highestSampleSequence !== null && highestSampleSequence > sequence)
            violations.push(`reply ${sequence} arrived after Sample ${highestSampleSequence}`);
        const followingSample = nextSampleSequenceAfter[index];
        if (followingSample !== null && followingSample !== sequence + 1)
            violations.push(`reply ${sequence} was followed by Sample ${followingSample}`);
    });
    return {
        replyCount,
        sampleCount,
        violationCount: violations.length,
        violations: violations.slice(0, REPORTED_VIOLATION_COUNT),
    };
}

/**
 * Describes an interface as names and signatures, to compare two introspections of it.
 *
 * @param {Gio.DBusInterfaceInfo|null} interfaceInfo - The interface, or null when the node lacks it.
 * @returns {object|null} Its methods, signals and properties, or null.
 */
function describeInterface(interfaceInfo) {
    if (interfaceInfo === null)
        return null;
    return {
        methods: interfaceInfo.methods.map(methodInfo => ({
            name: methodInfo.name,
            inArguments: methodInfo.in_args.map(argumentInfo => argumentInfo.signature),
            outArguments: methodInfo.out_args.map(argumentInfo => argumentInfo.signature),
        })),
        signals: interfaceInfo.signals.map(signalInfo => ({
            name: signalInfo.name,
            arguments: signalInfo.args.map(argumentInfo => argumentInfo.signature),
        })),
        properties: interfaceInfo.properties.map(propertyInfo => propertyInfo.name),
    };
}

test('program: a state reply carrying sequence N arrives after Sample N and before Sample N+1', () =>
    withServingProgram([TICK_INTERVAL_FLAG, String(FAST_TICK_INTERVAL_MS)], async ({ownerName, openClient}) => {
        const clientConnection = openClient();
        const arrivals = [];
        const subscriptionId = clientConnection.signal_subscribe(ownerName, RESOURCE_PULSE_INTERFACE_NAME,
            SAMPLE_SIGNAL_NAME, RESOURCE_PULSE_OBJECT_PATH, null, Gio.DBusSignalFlags.NONE, (...signalArguments) => {
                const [sampleText] = signalArguments.at(-1).deepUnpack();
                arrivals.push({kind: SAMPLE_ARRIVAL, sequence: JSON.parse(sampleText).sequence});
            });
        try {
            // A round trip first, so the subscription is in place on the bus before anything is recorded.
            await fetchState(clientConnection);
            arrivals.length = 0;
            const deadlineUsec = GLib.get_monotonic_time() + ORDER_RUN_DURATION_MS * 1000;
            const recordReply = reply => arrivals.push({kind: REPLY_ARRIVAL, sequence: parseStringReply(reply).sequence});
            while (GLib.get_monotonic_time() < deadlineUsec) {
                // One call in flight at a time, as a client asks.
                await callProgramMethod(clientConnection, GET_STATE_METHOD_NAME,
                    {replyType: STRING_REPLY_TYPE, onReply: recordReply});
            }
        } finally {
            clientConnection.signal_unsubscribe(subscriptionId);
        }
        const verdict = checkReplyOrder(arrivals);
        print(`#   order row: ${verdict.replyCount} replies, ${verdict.sampleCount} Samples, ` +
            `${verdict.violationCount} violations`);
        assertEqual({
            hasEnoughReplies: verdict.replyCount >= MIN_ORDER_REPLY_COUNT,
            hasEnoughSamples: verdict.sampleCount >= MIN_ORDER_SAMPLE_COUNT,
            violationCount: verdict.violationCount,
            violations: verdict.violations,
        }, {hasEnoughReplies: true, hasEnoughSamples: true, violationCount: 0, violations: []},
        `${verdict.replyCount} replies, ${verdict.sampleCount} Samples`);
    }));

test(`program: a call made the instant the name appears is answered, ${START_COUNT} starts out of ${START_COUNT}`,
    async () => {
        const watcherConnection = openPrivateBusConnection();
        const outcomes = [];
        /** The start under way: its outcome is set once, by the call's answer or failure. */
        let currentStart = {outcome: null};
        // The call goes out from the name-appeared handler itself, as a client's first GetState does.
        const watch = watchBusName(watcherConnection, () => {
            const appearedStart = currentStart;
            fetchState(watcherConnection)
                .then(() => {
                    appearedStart.outcome ??= 'answered';
                })
                .catch(error => {
                    appearedStart.outcome ??= error.message;
                });
        });
        try {
            for (let startNumber = 1; startNumber <= START_COUNT; startNumber++) {
                // Each start waits for the one before it to end.
                await waitForFreeName(watch);
                const thisStart = {outcome: null};
                currentStart = thisStart;
                const program = spawnProgram([]);
                try {
                    await waitUntil(() => thisStart.outcome !== null || program.hasExited,
                        NAME_OWNED_TIMEOUT_MS + CALL_TIMEOUT_MS);
                } finally {
                    await stopProgram(program);
                }
                outcomes.push(thisStart.outcome ??
                    `start ${startNumber}: no answer, the program exited with status ${program.exitStatus}`);
            }
        } finally {
            watch.stop();
            watcherConnection.close_sync(null);
        }
        const failures = outcomes.filter(outcome => outcome !== 'answered');
        assertEqual({answeredCount: outcomes.length - failures.length, failures: failures.slice(0, 3)},
            {answeredCount: START_COUNT, failures: []});
    });

test('program: a second copy exits 1 and the first still owns the name', () =>
    withServingProgram([], async ({program, ownerName, openClient}) => {
        const secondCopy = spawnProgram([]);
        try {
            const didSecondExit = await waitUntil(() => secondCopy.hasExited, PROGRAM_EXIT_TIMEOUT_MS);
            const clientConnection = openClient();
            const ownerAfterSecond = await fetchNameOwner(clientConnection);
            const state = await fetchState(clientConnection);
            assertEqual({
                didSecondExit,
                secondExitStatus: secondCopy.exitStatus,
                ownerAfterSecond,
                isFirstRunning: !program.hasExited,
                doesFirstAnswer: Number.isInteger(state.sequence),
            }, {
                didSecondExit: true,
                secondExitStatus: NAME_HELD_EXIT_STATUS,
                ownerAfterSecond: ownerName,
                isFirstRunning: true,
                doesFirstAnswer: true,
            });
        } finally {
            await stopProgram(secondCopy);
        }
    }));

test('program: an unknown method is answered with org.freedesktop.DBus.Error.UnknownMethod', () =>
    withServingProgram([], async ({openClient}) => {
        let remoteErrorName = 'no error';
        try {
            await callProgramMethod(openClient(), MISSING_METHOD_NAME);
        } catch (error) {
            // A call left unanswered ends in a local time-out after CALL_TIMEOUT_MS, which has no remote name.
            remoteErrorName = Gio.DBusError.get_remote_error(error) ?? `not a remote error: ${error.message}`;
        }
        assertEqual(remoteErrorName, UNKNOWN_METHOD_ERROR_NAME);
    }));

test('program: Introspect returns the interface with its three methods and its signal', () =>
    withServingProgram([], async ({openClient}) => {
        const reply = await callMethod(openClient(), {
            destination: RESOURCE_PULSE_BUS_NAME,
            objectPath: RESOURCE_PULSE_OBJECT_PATH,
            interfaceName: INTROSPECTABLE_INTERFACE_NAME,
            methodName: INTROSPECT_METHOD,
            replyType: STRING_REPLY_TYPE,
        });
        const [introspectionXml] = reply.deepUnpack();
        const programNode = Gio.DBusNodeInfo.new_for_xml(introspectionXml);
        const protocolInterface = describeInterface(
            Gio.DBusNodeInfo.new_for_xml(RESOURCE_PULSE_INTERFACE_XML).lookup_interface(RESOURCE_PULSE_INTERFACE_NAME));
        assertEqual({
            interfaceNames: programNode.interfaces.map(interfaceInfo => interfaceInfo.name).sort(),
            programInterface: describeInterface(programNode.lookup_interface(RESOURCE_PULSE_INTERFACE_NAME)),
            protocolMethodCount: protocolInterface.methods.length,
            protocolSignalCount: protocolInterface.signals.length,
            introspectable: describeInterface(programNode.lookup_interface(INTROSPECTABLE_INTERFACE_NAME)),
        }, {
            interfaceNames: [INTROSPECTABLE_INTERFACE_NAME, RESOURCE_PULSE_INTERFACE_NAME].sort(),
            programInterface: protocolInterface,
            protocolMethodCount: 3,
            protocolSignalCount: 1,
            introspectable: {
                methods: [{name: INTROSPECT_METHOD, inArguments: [], outArguments: ['s']}],
                signals: [],
                properties: [],
            },
        });
    }));

test('program: the name was asked for with DO_NOT_QUEUE only', () =>
    withServingProgram([], async ({ownerName, openClient}) => {
        const helperConnection = openClient();
        // With REPLACE_EXISTING the helper takes the name from any owner that asked with ALLOW_REPLACEMENT.
        const reply = await callMethod(helperConnection, {
            destination: BUS_DAEMON_NAME,
            objectPath: BUS_DAEMON_OBJECT_PATH,
            interfaceName: BUS_DAEMON_INTERFACE_NAME,
            methodName: REQUEST_NAME_METHOD,
            parameters: new GLib.Variant('(su)', [RESOURCE_PULSE_BUS_NAME,
                REQUEST_NAME_REPLACE_EXISTING_FLAG | REQUEST_NAME_DO_NOT_QUEUE_FLAG]),
            replyType: REQUEST_NAME_REPLY_TYPE,
        });
        const [requestNameReply] = reply.deepUnpack();
        assertEqual({requestNameReply, ownerAfterRequest: await fetchNameOwner(helperConnection)},
            {requestNameReply: REQUEST_NAME_REPLY_EXISTS, ownerAfterRequest: ownerName});
    }));

test('program: a caller that leaves the bus is reported once', () =>
    withServingProgram([], async ({openClient}) => {
        const leavingConnection = openClient();
        const observerConnection = openClient();
        await callProgramMethod(leavingConnection, WATCH_DETAIL_METHOD_NAME);
        const countBeforeLeaving = (await fetchState(observerConnection)).vanishedCallers;
        leavingConnection.close_sync(null);
        const deadlineUsec = GLib.get_monotonic_time() + VANISH_REPORT_TIMEOUT_MS * 1000;
        let countWhenReported = (await fetchState(observerConnection)).vanishedCallers;
        while (countWhenReported < 1 && GLib.get_monotonic_time() < deadlineUsec) {
            await delay(STATE_POLL_INTERVAL_MS);
            countWhenReported = (await fetchState(observerConnection)).vanishedCallers;
        }
        const isReportedInTime = countWhenReported >= 1 && GLib.get_monotonic_time() <= deadlineUsec;
        await delay(VANISH_REPORTED_ONCE_WINDOW_MS);
        const countAfterWindow = (await fetchState(observerConnection)).vanishedCallers;
        assertEqual({countBeforeLeaving, isReportedInTime, countWhenReported, countAfterWindow},
            {countBeforeLeaving: 0, isReportedInTime: true, countWhenReported: 1, countAfterWindow: 1});
    }));

test('program: every copy a row started has exited', () => {
    assertEqual([...runningPrograms].map(program => program.processId), []);
});
