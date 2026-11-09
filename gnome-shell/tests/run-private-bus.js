// Entry point for the rows that need a message bus, run ONLY on a private one:
//   RESOURCE_PULSE_TEST_BUS_DIR=<dir> dbus-run-session --config-file=<a bus listening in dir> -- \
//       gjs -m gnome-shell/tests/run-private-bus.js
// scripts/test-resource-pulse.sh does exactly that. Before any row runs it checks that the session bus is that private
// one (requirePrivateBusAddress) and exits 2 otherwise, so it can never reach the live session bus. Its test files
// are imported by a STATIC list, as in run.js, and it prints the same one anchored JS-TALLY line.
import GLib from 'gi://GLib';
import {runAll} from './harness.js';
import {requirePrivateBusAddress} from './service-dbus.test.js';
import './client-dbus.test.js';

const EXIT_CODE_TEST_FAILURE = 1;
const EXIT_CODE_HARNESS_ERROR = 2;

let exitCode = 0;
try {
    requirePrivateBusAddress();
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
