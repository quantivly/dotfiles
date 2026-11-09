// lib/protocol.js: the names and the interface the service and the extension share, and the JSON both sides speak.
// The parsers are skew-tolerant: a reader ignores fields it does not know, and a field that is missing or of the
// wrong type is null for that field alone.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {test, assertEqual} from './harness.js';
import {
    PROTOCOL_VERSION, RESOURCE_PULSE_BUS_NAME, RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_INTERFACE_XML,
    RESOURCE_PULSE_OBJECT_PATH, buildSamplePayload, buildStatePayload, parseSamplePayload, parseStatePayload,
} from '../extensions/resource-pulse@dotfiles/lib/protocol.js';
// The member names are read through the namespace, so a missing export fails its row rather than the whole run.
import * as protocolModule from '../extensions/resource-pulse@dotfiles/lib/protocol.js';
import {ServiceSampler} from '../extensions/resource-pulse@dotfiles/service/sampler.js';
import {CARD_HISTORY_SAMPLES} from '../extensions/resource-pulse@dotfiles/lib/constants.js';

const [TEST_FILE_PATH] = GLib.filename_from_uri(import.meta.url);
const FIXTURES_DIRECTORY = GLib.build_filenamev([GLib.path_get_dirname(TEST_FILE_PATH), 'fixtures']);
/** Far enough apart that the fixture sampler's second tick also runs its warm-up scan, so it ranks apps. */
const FIXTURE_TICK_SPACING_USEC = 6_000_000;
const FIXTURE_CLOCK_LABEL = '14:02';
const SERVICE_STARTED_AT_USEC = 1_794_000_000_000_000;
const SAMPLED_AT_USEC = 1_794_000_002_000_000;
/** Real time of the latest publish, as GetState reports it: a little after SAMPLED_AT_USEC, so the two never mix. */
const LATEST_SAMPLED_AT_USEC = 1_794_000_004_000_000;
const SEQUENCE = 7;

/** A snapshot with every field set, in the Snapshot typedef's order (service/sampler.js). */
const FULL_SNAPSHOT = {
    takenAtUsec: 123_000_000,
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
const HISTORIES = {cpu: [0.25, null, 0.5], memory: [0.6, 0.61, null]};
const APPENDED_HISTORY = {cpu: 0.5, memory: null};

/**
 * Builds the state payload of FULL_SNAPSHOT and HISTORIES.
 *
 * @returns {string} The JSON.
 */
function fullStatePayload() {
    return buildStatePayload({
        snapshot: FULL_SNAPSHOT, histories: HISTORIES, serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
        latestSampledAtUsec: LATEST_SAMPLED_AT_USEC, sequence: SEQUENCE,
    });
}

/**
 * Builds the sample payload of FULL_SNAPSHOT and APPENDED_HISTORY.
 *
 * @returns {string} The JSON.
 */
function fullSamplePayload() {
    return buildSamplePayload({
        snapshot: FULL_SNAPSHOT, appendedHistory: APPENDED_HISTORY, sequence: SEQUENCE, sampledAtUsec: SAMPLED_AT_USEC,
    });
}

/**
 * Parses a payload as plain JSON, applies an edit to the object, and serializes it again: a payload as another
 * version of the service might send it.
 *
 * @param {string} payload - A built payload.
 * @param {(payloadObject: object) => void} editPayload - Changes the parsed object in place.
 * @returns {string} The edited JSON.
 */
function editedPayload(payload, editPayload) {
    const payloadObject = JSON.parse(payload);
    editPayload(payloadObject);
    return JSON.stringify(payloadObject);
}

/**
 * A snapshot the real ServiceSampler publishes: root-a, then root-b six seconds later, so it has a CPU delta, both
 * clusters, memory, swap, pressure and an app ranking.
 *
 * @returns {object} The sampler's latest snapshot.
 */
function realSamplerSnapshot() {
    const clock = {nowUsec: 0};
    const sampler = new ServiceSampler({
        fsRoot: GLib.build_filenamev([FIXTURES_DIRECTORY, 'root-a']),
        nowUsec: () => clock.nowUsec,
        clockLabel: () => FIXTURE_CLOCK_LABEL,
        resolveAppName: () => null,
        collectGarbage: () => {},
        logWriter: () => {},
    });
    sampler.initialize();
    sampler.runTick(0);
    clock.nowUsec += FIXTURE_TICK_SPACING_USEC;
    sampler.fsRoot = GLib.build_filenamev([FIXTURES_DIRECTORY, 'root-b']);
    sampler.runTick(1);
    const snapshot = sampler.latestSnapshot;
    sampler.destroy();
    return snapshot;
}

test('protocol: version 1, and the bus name, interface, object path and member names of the design', () => {
    assertEqual({
        version: PROTOCOL_VERSION,
        busName: RESOURCE_PULSE_BUS_NAME,
        interfaceName: RESOURCE_PULSE_INTERFACE_NAME,
        objectPath: RESOURCE_PULSE_OBJECT_PATH,
        sampleSignal: [protocolModule.SAMPLE_SIGNAL_NAME, protocolModule.SAMPLE_SIGNAL_SIGNATURE],
        methods: [protocolModule.GET_STATE_METHOD_NAME, protocolModule.WATCH_DETAIL_METHOD_NAME,
            protocolModule.UNWATCH_DETAIL_METHOD_NAME],
    }, {
        version: 1,
        busName: 'io.github.quantivly.dotfiles.ResourcePulse1',
        interfaceName: 'io.github.quantivly.dotfiles.ResourcePulse1',
        objectPath: '/io/github/quantivly/dotfiles/ResourcePulse1',
        sampleSignal: ['Sample', '(s)'],
        methods: ['GetState', 'WatchDetail', 'UnwatchDetail'],
    });
});

test('protocol: the interface XML declares GetState() → s, WatchDetail(), UnwatchDetail() and Sample(s)', () => {
    const interfaceInfo = Gio.DBusNodeInfo.new_for_xml(RESOURCE_PULSE_INTERFACE_XML)
        .lookup_interface(RESOURCE_PULSE_INTERFACE_NAME);
    const signaturesOf = argumentInfos => argumentInfos.map(argumentInfo => argumentInfo.signature);
    const methods = interfaceInfo.methods.map(methodInfo =>
        `${methodInfo.name}(${signaturesOf(methodInfo.in_args)})→(${signaturesOf(methodInfo.out_args)})`);
    const signals = interfaceInfo.signals.map(signalInfo => `${signalInfo.name}(${signaturesOf(signalInfo.args)})`);
    assertEqual({methods, signals, properties: interfaceInfo.properties.length}, {
        methods: ['GetState()→(s)', 'WatchDetail()→()', 'UnwatchDetail()→()'],
        signals: ['Sample(s)'],
        properties: 0,
    });
});

test('protocol: a state payload round-trips, with protocol 1', () => {
    assertEqual(parseStatePayload(fullStatePayload()), {
        protocol: 1,
        snapshot: FULL_SNAPSHOT,
        histories: HISTORIES,
        serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
        latestSampledAtUsec: LATEST_SAMPLED_AT_USEC,
        sequence: SEQUENCE,
    });
});

test('protocol: a state payload before the first sample round-trips with a null snapshot and sample time, sequence 0',
    () => {
        const payload = buildStatePayload({
            snapshot: null, histories: {cpu: [], memory: []}, serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
            latestSampledAtUsec: null, sequence: 0,
        });
        assertEqual(parseStatePayload(payload), {
            protocol: 1, snapshot: null, histories: {cpu: [], memory: []},
            serviceStartedAtUsec: SERVICE_STARTED_AT_USEC, latestSampledAtUsec: null, sequence: 0,
        });
    });

test('protocol: GetState\'s latestSampledAtUsec comes before the snapshot, so a shell finds the top-level one first',
    () => {
        // gnome-status reads it out of gdbus's text with a pattern, taking the first match; a nested field of the
        // same name in a later service could only come after it.
        const payload = fullStatePayload();
        const latestSampledAtOffset = payload.indexOf('"latestSampledAtUsec":');
        const snapshotOffset = payload.indexOf('"snapshot":');
        assertEqual({isPresent: latestSampledAtOffset >= 0, isBeforeSnapshot: latestSampledAtOffset < snapshotOffset},
            {isPresent: true, isBeforeSnapshot: true});
    });

test('protocol: a sample payload round-trips', () => {
    assertEqual(parseSamplePayload(fullSamplePayload()), {
        snapshot: FULL_SNAPSHOT, appendedHistory: APPENDED_HISTORY, sequence: SEQUENCE, sampledAtUsec: SAMPLED_AT_USEC,
    });
});

test('protocol: a watch-start reveal sample carries appendedHistory null, so the client appends nothing', () => {
    const payload = buildSamplePayload({
        snapshot: FULL_SNAPSHOT, appendedHistory: null, sequence: SEQUENCE, sampledAtUsec: SAMPLED_AT_USEC,
    });
    assertEqual({wire: JSON.parse(payload).appendedHistory, parsed: parseSamplePayload(payload).appendedHistory},
        {wire: null, parsed: null});
});

test('protocol: a snapshot the real ServiceSampler publishes round-trips field for field', () => {
    const snapshot = realSamplerSnapshot();
    const payload = buildSamplePayload({
        snapshot, appendedHistory: APPENDED_HISTORY, sequence: SEQUENCE, sampledAtUsec: SAMPLED_AT_USEC,
    });
    const hasEveryPart = [snapshot.cpuBusyPercent, snapshot.cpuClusters, snapshot.memory, snapshot.swap,
        snapshot.apps?.topCpu, snapshot.apps?.topMemory].every(part => part !== null && part !== undefined);
    assertEqual({hasEveryPart, parsed: parseSamplePayload(payload).snapshot}, {hasEveryPart: true, parsed: snapshot});
});

test('protocol skew: unknown top-level and nested fields are ignored in a state payload', () => {
    const payloadWithExtras = editedPayload(fullStatePayload(), payloadObject => {
        payloadObject.futureTopLevel = {anything: [1, 2]};
        payloadObject.snapshot.futureSnapshotField = 'x';
        payloadObject.snapshot.memory.futureBytes = 5;
        payloadObject.snapshot.apps.topCpu.futureScore = 2;
        payloadObject.histories.futureHistory = [0.1];
    });
    assertEqual(parseStatePayload(payloadWithExtras), parseStatePayload(fullStatePayload()));
});

test('protocol skew: unknown top-level and nested fields are ignored in a sample payload', () => {
    const payloadWithExtras = editedPayload(fullSamplePayload(), payloadObject => {
        payloadObject.futureTopLevel = 3;
        payloadObject.snapshot.pressureAvg10.futurePressure = 9;
        payloadObject.appendedHistory.futureFraction = 0.3;
    });
    assertEqual(parseSamplePayload(payloadWithExtras), parseSamplePayload(fullSamplePayload()));
});

test('protocol skew: a missing snapshot.swap gives swap: null, and every other field intact', () => {
    const payloadWithoutSwap = editedPayload(fullSamplePayload(), payloadObject => {
        delete payloadObject.snapshot.swap;
    });
    assertEqual(parseSamplePayload(payloadWithoutSwap), {
        snapshot: {...FULL_SNAPSHOT, swap: null},
        appendedHistory: APPENDED_HISTORY,
        sequence: SEQUENCE,
        sampledAtUsec: SAMPLED_AT_USEC,
    });
});

test('protocol skew: a mistyped field is null for that field only (a history value is a gap)', () => {
    const mistypedState = editedPayload(fullStatePayload(), payloadObject => {
        payloadObject.sequence = '7';
        payloadObject.snapshot.memory.usedBytes = 'lots';
        payloadObject.snapshot.cpuClusters.efficiencyPercent = true;
        payloadObject.snapshot.apps.topMemory = 'herdr';
        payloadObject.histories.cpu = [0.25, 'x', 0.5];
        payloadObject.histories.memory = 'none';
    });
    assertEqual(parseStatePayload(mistypedState), {
        protocol: 1,
        snapshot: {
            ...FULL_SNAPSHOT,
            cpuClusters: {performancePercent: 41, efficiencyPercent: null},
            memory: null,
            apps: {topCpu: FULL_SNAPSHOT.apps.topCpu, topMemory: null},
        },
        histories: {cpu: [0.25, null, 0.5], memory: null},
        serviceStartedAtUsec: SERVICE_STARTED_AT_USEC,
        latestSampledAtUsec: LATEST_SAMPLED_AT_USEC,
        sequence: null,
    });
});

test('protocol skew: a state payload without latestSampledAtUsec (an older service), or with one that is not a ' +
    'finite number, reads it as null and every other field intact', () => {
    const editedLatestSampledAtValues = {absent: undefined, text: 'soon', flag: true, list: [1]};
    const parsedStates = Object.fromEntries(Object.entries(editedLatestSampledAtValues).map(([caseName, value]) => {
        const statePayload = editedPayload(fullStatePayload(), payloadObject => {
            if (value === undefined)
                delete payloadObject.latestSampledAtUsec;
            else
                payloadObject.latestSampledAtUsec = value;
        });
        return [caseName, parseStatePayload(statePayload)];
    }));
    const expectedState = {...parseStatePayload(fullStatePayload()), latestSampledAtUsec: null};
    assertEqual(parsedStates, Object.fromEntries(Object.keys(editedLatestSampledAtValues).map(caseName =>
        [caseName, expectedState])));
});

test('protocol skew: an app entry without a groupKey is null, so two such entries never read as one app', () => {
    // lib/format.js shows the two halves of "heaviest" as one app when their groupKeys are equal, and two keys made
    // null would be equal.
    const payloadWithoutGroupKeys = editedPayload(fullSamplePayload(), payloadObject => {
        delete payloadObject.snapshot.apps.topCpu.groupKey;
        delete payloadObject.snapshot.apps.topMemory.groupKey;
    });
    assertEqual(parseSamplePayload(payloadWithoutGroupKeys).snapshot.apps, {topCpu: null, topMemory: null});
});

test('protocol skew: a sequence or protocol that is not a whole number of zero or more is null', () => {
    // The client takes a lower sequence for a service restart, so a negative or fractional one must not pass.
    const notWholeCounts = [-3, 2.5, '7', null];
    const parsedCounts = notWholeCounts.map(count => {
        const statePayload = editedPayload(fullStatePayload(), payloadObject => {
            payloadObject.sequence = count;
            payloadObject.protocol = count;
        });
        const samplePayload = editedPayload(fullSamplePayload(), payloadObject => {
            payloadObject.sequence = count;
        });
        const state = parseStatePayload(statePayload);
        return [state.sequence, state.protocol, parseSamplePayload(samplePayload).sequence];
    });
    assertEqual(parsedCounts, notWholeCounts.map(() => [null, null, null]));
});

test('protocol skew: a negative byte count or percentage is null for its own field (a ranked app as a whole)', () => {
    const negativePayload = editedPayload(fullSamplePayload(), payloadObject => {
        payloadObject.snapshot.cpuBusyPercent = -2;
        payloadObject.snapshot.cpuClusters.performancePercent = -1;
        payloadObject.snapshot.memory.usedBytes = -1;
        payloadObject.snapshot.swap.diskBytes = -5;
        payloadObject.snapshot.pressureAvg10.io = -0.5;
        payloadObject.snapshot.apps.topCpu.cpuPercent = -1;
        payloadObject.snapshot.apps.topMemory.memoryBytes = -1;
    });
    assertEqual(parseSamplePayload(negativePayload).snapshot, {
        ...FULL_SNAPSHOT,
        cpuBusyPercent: null,
        cpuClusters: {performancePercent: null, efficiencyPercent: 6},
        memory: null,
        swap: null,
        pressureAvg10: {cpu: 1.5, memory: 0, io: null},
        apps: {topCpu: null, topMemory: null},
    });
});

test('protocol skew: a history fraction outside 0–1 is a gap, in GetState\'s histories and Sample\'s appended', () => {
    const stateWithOutOfRangeFractions = editedPayload(fullStatePayload(), payloadObject => {
        payloadObject.histories.cpu = [-0.1, 0, 0.5, 1, 1.5];
    });
    const sampleWithOutOfRangeFractions = editedPayload(fullSamplePayload(), payloadObject => {
        payloadObject.appendedHistory = {cpu: 1.01, memory: -0.01};
    });
    assertEqual({
        histories: parseStatePayload(stateWithOutOfRangeFractions).histories,
        appendedHistory: parseSamplePayload(sampleWithOutOfRangeFractions).appendedHistory,
    }, {
        histories: {cpu: [null, 0, 0.5, 1, null], memory: HISTORIES.memory},
        appendedHistory: {cpu: null, memory: null},
    });
});

test('protocol skew: a history longer than CARD_HISTORY_SAMPLES keeps only its newest values', () => {
    const extraSampleCount = 50;
    const longHistoryLength = CARD_HISTORY_SAMPLES + extraSampleCount;
    const longHistory = Array.from({length: longHistoryLength}, (_, index) => (index % 100) / 100);
    const shortHistory = longHistory.slice(0, 3);
    const payload = buildStatePayload({
        snapshot: null, histories: {cpu: longHistory, memory: shortHistory},
        serviceStartedAtUsec: SERVICE_STARTED_AT_USEC, sequence: SEQUENCE,
    });
    assertEqual(parseStatePayload(payload).histories,
        {cpu: longHistory.slice(-CARD_HISTORY_SAMPLES), memory: shortHistory});
});

test('protocol skew: raw JSON numbers out of range (1e999, -1e999, a sequence past 2^53) are null', () => {
    // JSON.stringify cannot write these, so they are spliced into the text; each splice is checked to have landed.
    const textEdits = [
        ['sample', `"sequence":${SEQUENCE}`, '"sequence":99999999999999999999'],
        ['sample', `"sampledAtUsec":${SAMPLED_AT_USEC}`, '"sampledAtUsec":1e999'],
        ['sample', '"cpuBusyPercent":23.5', '"cpuBusyPercent":1e999'],
        ['state', `"serviceStartedAtUsec":${SERVICE_STARTED_AT_USEC}`, '"serviceStartedAtUsec":-1e999'],
        ['state', '"cpu":[0.25,null,0.5]', '"cpu":[1e999,null,0.5]'],
    ];
    const rawTexts = {sample: fullSamplePayload(), state: fullStatePayload()};
    const missedSplices = [];
    for (const [payloadKind, originalText, rawText] of textEdits) {
        if (!rawTexts[payloadKind].includes(originalText))
            missedSplices.push(originalText);
        rawTexts[payloadKind] = rawTexts[payloadKind].replace(originalText, rawText);
    }
    const sample = parseSamplePayload(rawTexts.sample);
    const state = parseStatePayload(rawTexts.state);
    assertEqual({
        missedSplices,
        sequence: sample.sequence,
        sampledAtUsec: sample.sampledAtUsec,
        cpuBusyPercent: sample.snapshot.cpuBusyPercent,
        serviceStartedAtUsec: state.serviceStartedAtUsec,
        cpuHistory: state.histories.cpu,
    }, {
        missedSplices: [],
        sequence: null,
        sampledAtUsec: null,
        cpuBusyPercent: null,
        serviceStartedAtUsec: null,
        cpuHistory: [null, null, 0.5],
    });
});

test('protocol skew: a missing snapshot, histories or appendedHistory gives null, never a throw', () => {
    const stateWithoutParts = editedPayload(fullStatePayload(), payloadObject => {
        delete payloadObject.snapshot;
        delete payloadObject.histories;
    });
    const sampleWithoutParts = editedPayload(fullSamplePayload(), payloadObject => {
        delete payloadObject.appendedHistory;
        payloadObject.snapshot = 'not a snapshot';
    });
    assertEqual({state: parseStatePayload(stateWithoutParts), sample: parseSamplePayload(sampleWithoutParts)}, {
        state: {
            protocol: 1, snapshot: null, histories: {cpu: null, memory: null},
            serviceStartedAtUsec: SERVICE_STARTED_AT_USEC, latestSampledAtUsec: LATEST_SAMPLED_AT_USEC,
            sequence: SEQUENCE,
        },
        sample: {snapshot: null, appendedHistory: null, sequence: SEQUENCE, sampledAtUsec: SAMPLED_AT_USEC},
    });
});

test('protocol skew: "not json", a JSON non-object and a non-string all parse to null', () => {
    const unparseableInputs = ['not json', '[1, 2]', '42', 'null', '"text"', '', undefined, null];
    assertEqual({
        state: unparseableInputs.map(input => parseStatePayload(input)),
        sample: unparseableInputs.map(input => parseSamplePayload(input)),
    }, {
        state: unparseableInputs.map(() => null),
        sample: unparseableInputs.map(() => null),
    });
});
