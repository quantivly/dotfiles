// Entry point for the compiled sampler's rows, run ONLY on a private message bus:
//   RESOURCE_PULSE_TEST_BUS_DIR=<dir> dbus-run-session --config-file=<a bus listening in dir> -- \
//       gjs -m gnome-shell/tests/run-sampler-program.js <path to resource-pulse-sampler>
// scripts/test-resource-pulse-sampler.sh does exactly that. Before any row runs it checks that the session bus is that
// private one (requirePrivateBusAddress) and that it was given an executable program, and exits 2 otherwise, so it
// can never start the program on the live session bus. It imports its one test file statically, as run.js does,
// and prints the same one anchored JS-TALLY line.
import GLib from 'gi://GLib';
import {runAll} from './harness.js';
import {requirePrivateBusAddress} from './privateBus.js';
import {setSamplerProgramPath} from './sampler-program-dbus.test.js';

const EXIT_CODE_TEST_FAILURE = 1;
const EXIT_CODE_HARNESS_ERROR = 2;

let exitCode = 0;
try {
    requirePrivateBusAddress();
    setSamplerProgramPath(ARGV[0]);
} catch (error) {
    printerr(`harness error: ${error.message}`);
    imports.system.exit(EXIT_CODE_HARNESS_ERROR);
}

const mainLoop = new GLib.MainLoop(null, false);
runAll()
    .then(({passCount, failCount, rows}) => {
        rows.forEach(row => print(row));
        print(`JS-TALLY pass=${passCount} fail=${failCount}`);
        if (failCount > 0)
            exitCode = EXIT_CODE_TEST_FAILURE;
    })
    .catch(error => {
        printerr(`harness error: ${error.message}`);
        exitCode = EXIT_CODE_HARNESS_ERROR;
    })
    .finally(() => mainLoop.quit());

mainLoop.run();
imports.system.exit(exitCode);
