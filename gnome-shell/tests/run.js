// Entry point: gjs -m gnome-shell/tests/run.js
// Every test file is imported by a STATIC list, so a missing file is an import
// error and never a silently smaller run.
import GLib from 'gi://GLib';
import {runAll} from './harness.js';
import './harness.test.js';
import './jsonFields.test.js';
import './parsers.test.js';
import './math.test.js';
import './apps.test.js';
import './format.test.js';
import './cadence.test.js';
import './wiring.test.js';
import './visibility.test.js';
import './protocol.test.js';
import './cockpitProtocol.test.js';
import './cockpitConfig.test.js';
import './nameGuard.test.js';
import './sessions.test.js';
import './network.test.js';
import './mounts.test.js';
import './service-sampler.test.js';
import './client.test.js';
import './graph.test.js';
import './lifecycle.test.js';
import './nestedHarness.test.js';
import './imports.test.js';

const EXIT_CODE_TEST_FAILURE = 1;
const EXIT_CODE_HARNESS_ERROR = 2;

const mainLoop = new GLib.MainLoop(null, false);
let exitCode = 0;

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
