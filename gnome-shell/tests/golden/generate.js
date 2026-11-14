// Writes the golden files: what a client of the gjs Resource Pulse service receives for each scenario, so the compiled
// sampler can be held to the same values (resource-pulse-sampler/tests/golden.rs). Run ONLY on a private message bus,
// with a fixed English locale chosen by the caller:
//   LC_ALL=C.UTF-8 RESOURCE_PULSE_TEST_BUS_DIR=<dir> dbus-run-session --config-file=<a bus listening in dir> -- \
//       gjs -m gnome-shell/tests/golden/generate.js [--check] [--scenarios-dir D] [--expected-dir D]
// scripts/test-resource-pulse-sampler.sh runs it that way. It refuses any other bus (requirePrivateBusAddress), runs the
// REAL ServiceSampler and the REAL ResourcePulseDBusService over the fixture roots under ../fixtures, never calls the
// sampler's start() (it drives runTick and setDetailWatched itself, with the clock, the clock label and the app names
// the scenario file gives), and writes only under its expected directory.
//
// A scenario file is {description, serviceStartedAtUsec, appNames: {desktopId: name}, steps: [...]}; a step is
//   {tick: {fsRoot, monotonicUsec, realUsec, clockLabel}}   one runTick, over the fixture root fsRoot;
//   {watchDetail: true, fsRoot, monotonicUsec, realUsec}    a watch starts (the root is what its scan reads);
//   {watchDetail: false}                                    the watch ends.
// An expected file is {samples: [every Sample a second connection received, parsed], state: GetState's reply, parsed}.
//
// Without --check it writes one expected file per scenario and exits 0. With --check it writes nothing and exits
//   0  when every committed expected file is what the gjs sampler produces now,
//   1  when one differs, is missing, or has no scenario (each named on a GOLDEN-CHECK line),
//   2  when it could not run (not a private bus, a scenario it cannot read, a bus that did not deliver): never a pass.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {openPrivateBusConnection, requirePrivateBusAddress, waitUntil} from '../privateBus.js';
import {ServiceSampler} from '../../extensions/resource-pulse@dotfiles/service/sampler.js';
import {ResourcePulseDBusService} from '../../extensions/resource-pulse@dotfiles/service/dbusService.js';
import {
    GET_STATE_METHOD_NAME, RESOURCE_PULSE_INTERFACE_NAME, RESOURCE_PULSE_OBJECT_PATH, SAMPLE_SIGNAL_NAME,
} from '../../extensions/resource-pulse@dotfiles/lib/protocol.js';

const EXIT_CODE_CHECK_DIFFERS = 1;
const EXIT_CODE_COULD_NOT_RUN = 2;
const CHECK_FLAG = '--check';
const SCENARIOS_DIRECTORY_FLAG = '--scenarios-dir';
const EXPECTED_DIRECTORY_FLAG = '--expected-dir';
const SCENARIO_FILE_SUFFIX = '.json';
const GET_STATE_TIMEOUT_MS = 2000;
const SAMPLE_DELIVERY_TIMEOUT_MS = 5000;
const STATE_REPLY_TYPE = new GLib.VariantType('(s)');
const JSON_INDENT_SPACES = 2;
const [GENERATOR_PATH] = GLib.filename_from_uri(import.meta.url);
const GOLDEN_DIRECTORY = GLib.path_get_dirname(GENERATOR_PATH);
const DEFAULT_SCENARIOS_DIRECTORY = GLib.build_filenamev([GOLDEN_DIRECTORY, 'scenarios']);
const DEFAULT_EXPECTED_DIRECTORY = GLib.build_filenamev([GOLDEN_DIRECTORY, 'expected']);
const FIXTURES_DIRECTORY = GLib.build_filenamev([GLib.path_get_dirname(GOLDEN_DIRECTORY), 'fixtures']);

/**
 * Reads the command line.
 *
 * @param {string[]} commandLine - The arguments after the script's name.
 * @returns {{isCheck: boolean, scenariosDirectory: string, expectedDirectory: string}} The options.
 * @throws {Error} On a flag it does not know, or a flag missing its value.
 */
function parseCommandLine(commandLine) {
    const options = {
        isCheck: false, scenariosDirectory: DEFAULT_SCENARIOS_DIRECTORY, expectedDirectory: DEFAULT_EXPECTED_DIRECTORY,
    };
    for (let index = 0; index < commandLine.length; index++) {
        const flag = commandLine[index];
        if (flag === CHECK_FLAG) {
            options.isCheck = true;
        } else if (flag === SCENARIOS_DIRECTORY_FLAG || flag === EXPECTED_DIRECTORY_FLAG) {
            index += 1;
            if (index >= commandLine.length)
                throw new Error(`${flag} needs a directory`);
            const optionName = flag === SCENARIOS_DIRECTORY_FLAG ? 'scenariosDirectory' : 'expectedDirectory';
            options[optionName] = commandLine[index];
        } else {
            throw new Error(`unknown argument ${flag}`);
        }
    }
    return options;
}

/**
 * Reads a whole text file.
 *
 * @param {string} path - The file.
 * @returns {string} Its text.
 * @throws {Error} When it cannot be read.
 */
function readText(path) {
    const [, contents] = GLib.file_get_contents(path);
    return new TextDecoder().decode(contents);
}

/**
 * Lists the scenario file names in a directory, in name order.
 *
 * @param {string} directory - The directory.
 * @returns {string[]} The names that end in .json, without the suffix.
 * @throws {Error} When the directory cannot be listed.
 */
function listJsonStems(directory) {
    const enumerator = Gio.File.new_for_path(directory).enumerate_children('standard::name',
        Gio.FileQueryInfoFlags.NONE, null);
    const stems = [];
    for (let info = enumerator.next_file(null); info !== null; info = enumerator.next_file(null)) {
        const name = info.get_name();
        if (name.endsWith(SCENARIO_FILE_SUFFIX))
            stems.push(name.slice(0, -SCENARIO_FILE_SUFFIX.length));
    }
    enumerator.close(null);
    return stems.sort();
}

/**
 * Reads and checks one scenario file.
 *
 * @param {string} path - The file.
 * @returns {object} The scenario.
 * @throws {Error} When the file is not a scenario of the documented shape.
 */
function readScenario(path) {
    const scenario = JSON.parse(readText(path));
    const hasShape = Number.isSafeInteger(scenario.serviceStartedAtUsec) && Array.isArray(scenario.steps) &&
        scenario.steps.length > 0 && typeof scenario.appNames === 'object' && scenario.appNames !== null;
    if (!hasShape)
        throw new Error(`${path} is not a scenario: it needs serviceStartedAtUsec, appNames and steps`);
    return scenario;
}

/**
 * The fixture root a step reads.
 *
 * @param {string} rootName - A directory under ../fixtures.
 * @returns {string} Its path.
 */
function fixtureRoot(rootName) {
    return GLib.build_filenamev([FIXTURES_DIRECTORY, rootName]);
}

/**
 * Calls GetState on the service from a second connection.
 *
 * @param {Gio.DBusConnection} connection - The client's.
 * @param {string} serviceName - The service connection's unique name.
 * @returns {Promise<string>} The state's JSON text.
 */
function callGetState(connection, serviceName) {
    return new Promise((resolve, reject) => {
        connection.call(serviceName, RESOURCE_PULSE_OBJECT_PATH, RESOURCE_PULSE_INTERFACE_NAME, GET_STATE_METHOD_NAME,
            null, STATE_REPLY_TYPE, Gio.DBusCallFlags.NONE, GET_STATE_TIMEOUT_MS, null, (callingConnection, result) => {
                try {
                    resolve(callingConnection.call_finish(result).deepUnpack()[0]);
                } catch (error) {
                    reject(error);
                }
            });
    });
}

/**
 * Applies one step to the sampler and the clock it reads.
 *
 * @param {object} step - A scenario step.
 * @param {{sampler: ServiceSampler, clock: object, nextTickNumber: number}} run - The run's parts; nextTickNumber is
 *     advanced by a tick.
 * @returns {void}
 * @throws {Error} For a step that is neither a tick nor a watch change.
 */
function applyStep(step, run) {
    const {sampler, clock} = run;
    if (step.tick !== undefined) {
        const {fsRoot, monotonicUsec, realUsec, clockLabel} = step.tick;
        Object.assign(clock, {monotonicUsec, realUsec, clockLabel});
        sampler.fsRoot = fixtureRoot(fsRoot);
        sampler.runTick(run.nextTickNumber++);
    } else if (step.watchDetail === true) {
        Object.assign(clock, {monotonicUsec: step.monotonicUsec, realUsec: step.realUsec});
        sampler.fsRoot = fixtureRoot(step.fsRoot);
        sampler.setDetailWatched(true);
    } else if (step.watchDetail === false) {
        sampler.setDetailWatched(false);
    } else {
        throw new Error(`a step is neither a tick nor a watch change: ${JSON.stringify(step)}`);
    }
}

/**
 * Builds the sampler a scenario runs on: the real ServiceSampler over the first step's root, on the scenario's clock,
 * with its app names, no garbage collection and its log discarded (the golden files hold what a client receives).
 *
 * @param {object} scenario - The scenario.
 * @param {object} clock - {monotonicUsec, realUsec, clockLabel}, which the steps move.
 * @returns {ServiceSampler} The sampler, initialised and never started.
 */
function buildSampler(scenario, clock) {
    const [firstStep] = scenario.steps;
    const firstRoot = (firstStep.tick ?? firstStep).fsRoot;
    const sampler = new ServiceSampler({
        fsRoot: fixtureRoot(firstRoot),
        nowUsec: () => clock.monotonicUsec,
        clockLabel: () => clock.clockLabel,
        resolveAppName: desktopId => Object.hasOwn(scenario.appNames, desktopId) ? scenario.appNames[desktopId] : null,
        collectGarbage: () => {},
        logWriter: () => {},
    });
    sampler.initialize();
    return sampler;
}

/**
 * Runs one scenario through the real sampler and service and records what a second connection received.
 *
 * @param {object} scenario - The scenario.
 * @returns {Promise<{samples: object[], state: object}>} Every Sample, parsed, and GetState's reply, parsed.
 * @throws {Error} When the samples do not all arrive, or a call fails.
 */
async function runScenario(scenario) {
    const clock = {monotonicUsec: 0, realUsec: 0, clockLabel: ''};
    const sampler = buildSampler(scenario, clock);
    const serviceConnection = openPrivateBusConnection();
    const clientConnection = openPrivateBusConnection();
    let service = null;
    try {
        service = new ResourcePulseDBusService(sampler, serviceConnection,
            {serviceStartedAtUsec: scenario.serviceStartedAtUsec, nowRealUsec: () => clock.realUsec});
        const serviceName = serviceConnection.get_unique_name();
        const sampleTexts = [];
        clientConnection.signal_subscribe(serviceName, RESOURCE_PULSE_INTERFACE_NAME, SAMPLE_SIGNAL_NAME,
            RESOURCE_PULSE_OBJECT_PATH, null, Gio.DBusSignalFlags.NONE,
            (...signalArguments) => sampleTexts.push(signalArguments.at(-1).deepUnpack()[0]));
        // A round trip first, so the subscription is in place on the bus before anything is published.
        await callGetState(clientConnection, serviceName);
        const run = {sampler, clock, nextTickNumber: 0};
        scenario.steps.forEach(step => applyStep(step, run));
        // The reply follows every signal the service sent before it, so each Sample is on its way by now.
        const state = JSON.parse(await callGetState(clientConnection, serviceName));
        const didAllArrive = await waitUntil(() => sampleTexts.length >= state.sequence, SAMPLE_DELIVERY_TIMEOUT_MS);
        if (!didAllArrive || sampleTexts.length !== state.sequence)
            throw new Error(`${sampleTexts.length} Samples arrived, and the state says ${state.sequence}`);
        return {samples: sampleTexts.map(text => JSON.parse(text)), state};
    } finally {
        service?.destroy();
        for (const connection of [clientConnection, serviceConnection]) {
            if (!connection.is_closed())
                connection.close_sync(null);
        }
    }
}

/**
 * The text of an expected file.
 *
 * @param {{samples: object[], state: object}} recording - What runScenario recorded.
 * @returns {string} Indented JSON and a final newline.
 */
function expectedFileText(recording) {
    return `${JSON.stringify(recording, null, JSON_INDENT_SPACES)}\n`;
}

/**
 * Writes or checks every scenario's expected file.
 *
 * @param {object} options - parseCommandLine's result.
 * @returns {Promise<number>} The exit code.
 */
async function generateAll(options) {
    const scenarioNames = listJsonStems(options.scenariosDirectory);
    if (scenarioNames.length === 0)
        throw new Error(`no scenario in ${options.scenariosDirectory}`);
    const differing = [];
    for (const scenarioName of scenarioNames) {
        const scenario = readScenario(GLib.build_filenamev([options.scenariosDirectory, `${scenarioName}.json`]));
        const text = expectedFileText(await runScenario(scenario));
        const expectedPath = GLib.build_filenamev([options.expectedDirectory, `${scenarioName}.json`]);
        if (!options.isCheck) {
            GLib.file_set_contents(expectedPath, text);
        } else if (!GLib.file_test(expectedPath, GLib.FileTest.IS_REGULAR) || readText(expectedPath) !== text) {
            differing.push(`${scenarioName}: the committed expected file is missing or differs`);
        }
    }
    if (options.isCheck) {
        const orphans = listJsonStems(options.expectedDirectory).filter(name => !scenarioNames.includes(name));
        orphans.forEach(name => differing.push(`${name}: an expected file with no scenario`));
    }
    differing.forEach(line => print(`GOLDEN-CHECK differs: ${line}`));
    if (differing.length > 0)
        return EXIT_CODE_CHECK_DIFFERS;
    print(options.isCheck ? `GOLDEN-CHECK ok: ${scenarioNames.length} scenarios` :
        `GOLDEN-WROTE: ${scenarioNames.length} scenarios`);
    return 0;
}

let exitCode = EXIT_CODE_COULD_NOT_RUN;
let options = null;
try {
    options = parseCommandLine(ARGV);
    requirePrivateBusAddress();
} catch (error) {
    printerr(`could not run: ${error.message}`);
    imports.system.exit(EXIT_CODE_COULD_NOT_RUN);
}

const mainLoop = new GLib.MainLoop(null, false);
generateAll(options)
    .then(code => {
        exitCode = code;
    })
    .catch(error => {
        printerr(`could not run: ${error.message}`);
        exitCode = EXIT_CODE_COULD_NOT_RUN;
    })
    .finally(() => mainLoop.quit());
mainLoop.run();
imports.system.exit(exitCode);
