// The barrier between the plain-gjs rows and the live message buses. run.js imports it first, so it runs before any
// test module is evaluated, and the rows then run only in a process STARTED with the session and the system bus
// addresses naming a bus that cannot exist: a fake a row leaves out (an injected connection or link, as a mutant
// removes one) falls through to no bus at all, never to the owner's session bus, where Mutter and the cockpit service
// answer. The variables are set, never unset: an unset session address falls back to $XDG_RUNTIME_DIR/bus, the live
// one. GIO's starter bus is one of the two (by DBUS_STARTER_BUS_TYPE), so they cover it.
//
// Setting them inside this process would come too late, measured (gjs 1.88, GLib 2.88, under strace): before its first
// line of JavaScript, gjs has connected to the session bus (GVfs's GDaemonVfs, which takes the process's shared session
// connection, so Gio.bus_get hands that live connection back whatever the variables say afterwards) and, from a worker
// thread, to the system bus (GLib's memory monitor). So a runner started without the barrier starts itself again with
// it, waits, and exits with that run's status; it evaluates no test module itself. Those two startup connections of
// the first process are gjs's own, made before any code here runs; start the runner with the barrier's variables
// already set to avoid them too.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import System from 'system';

/** A socket under /dev/null, which is not a directory: none can ever exist there, and a connect fails at once. */
const UNREACHABLE_BUS_ADDRESS ='unix:path=/dev/null/resource-pulse-plain-gjs-rows-have-no-bus';
/** The variables GIO reads the session and the system bus's addresses from. */
const BUS_ADDRESS_VARIABLE_NAMES = Object.freeze(['DBUS_SESSION_BUS_ADDRESS', 'DBUS_SYSTEM_BUS_ADDRESS']);
/** Set in the runner started again, so one that still finds a bus reachable stops rather than start another. */
const RESTARTED_BEHIND_BARRIER_VARIABLE_NAME = 'RESOURCE_PULSE_RESTARTED_BEHIND_BUS_BARRIER';
const RESTARTED_BEHIND_BARRIER_VALUE = '1';
/** The binary of the running gjs, so the runner starts again under the same one. */
const RUNNING_BINARY_LINK_PATH = '/proc/self/exe';
const MODULE_FLAG = '-m';
/** As run.js's: "could not run", never a pass. */
const EXIT_CODE_HARNESS_ERROR = 2;

/**
 * Says whether this process was given every bus address as the barrier's.
 *
 * @returns {boolean} True when each variable names UNREACHABLE_BUS_ADDRESS.
 */
function isEveryBusBarred() {
    return BUS_ADDRESS_VARIABLE_NAMES.every(variableName => GLib.getenv(variableName) === UNREACHABLE_BUS_ADDRESS);
}

/**
 * Starts the runner again, under the same gjs, with the same entry and arguments and every bus address the barrier's,
 * inheriting this process's standard streams; waits for it.
 *
 * @returns {number} Its exit status, or EXIT_CODE_HARNESS_ERROR when it could not be started or did not exit itself.
 */
function runAgainBehindBarrier() {
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
    for (const variableName of BUS_ADDRESS_VARIABLE_NAMES)
        launcher.setenv(variableName, UNREACHABLE_BUS_ADDRESS, true);
    launcher.setenv(RESTARTED_BEHIND_BARRIER_VARIABLE_NAME, RESTARTED_BEHIND_BARRIER_VALUE, true);
    let restartedRunner;
    try {
        const gjsBinaryPath = GLib.file_read_link(RUNNING_BINARY_LINK_PATH);
        restartedRunner = launcher.spawnv([gjsBinaryPath, MODULE_FLAG, System.programPath, ...System.programArgs]);
        restartedRunner.wait(null);
    } catch (error) {
        printerr(`harness error: cannot start the runner again behind the bus barrier: ${error.message}`);
        return EXIT_CODE_HARNESS_ERROR;
    }
    return restartedRunner.get_if_exited() ? restartedRunner.get_exit_status() : EXIT_CODE_HARNESS_ERROR;
}

/**
 * Lets the rows run in this process only when it was started behind the barrier; otherwise runs them again behind it
 * and exits with that run's status. A runner already started again that still finds a bus reachable exits 2.
 *
 * @returns {void}
 */
function runOnlyBehindBarrier() {
    if (isEveryBusBarred())
        return;
    if (GLib.getenv(RESTARTED_BEHIND_BARRIER_VARIABLE_NAME) === RESTARTED_BEHIND_BARRIER_VALUE) {
        printerr('harness error: the runner started again behind the bus barrier can still reach a bus');
        System.exit(EXIT_CODE_HARNESS_ERROR);
    }
    System.exit(runAgainBehindBarrier());
}

runOnlyBehindBarrier();
