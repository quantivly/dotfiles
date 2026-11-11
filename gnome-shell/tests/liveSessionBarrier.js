// The barrier between the plain-gjs rows and the owner's live session. run.js imports it first, so it runs before any
// test module is evaluated, and the rows then run only in a process STARTED with the session and the system bus
// addresses naming a bus that cannot exist, and the config home (XDG_CONFIG_HOME) naming a directory that cannot
// exist. So a fake a row leaves out (an injected connection, link, config home or herdr socket path, as a mutant
// removes one) falls through to nothing: never to the owner's session bus, where Mutter and the cockpit service
// answer, and never to herdr's socket under ~/.config, where a focus request moves the owner's panes. The variables
// are set, never unset: an unset session address falls back to $XDG_RUNTIME_DIR/bus, the live one, and an unset
// config home to ~/.config. GIO's starter bus is one of the two buses (by DBUS_STARTER_BUS_TYPE), so they cover it.
// The state home and the home directory are left alone: the service only reads under them (the hspawn registry; the
// transcripts and ~/.ssh/sockets), and every row injects its own.
//
// Setting them inside this process would come too late, measured (gjs 1.88, GLib 2.88, under strace): before its first
// line of JavaScript, gjs has connected to the session bus (GVfs's GDaemonVfs, which takes the process's shared session
// connection, so Gio.bus_get hands that live connection back whatever the variables say afterwards) and, from a worker
// thread, to the system bus (GLib's memory monitor). So a runner started without the barrier starts itself again with
// it, waits, and exits with that run's status; it evaluates no test module itself. Those two startup connections of
// the first process are gjs's own, made before any code here runs; start the runner with the barrier's variables
// already set to avoid them too. The restart passes on the entry and its arguments but not gjs's own options (-I,
// --coverage-prefix and the like): no caller of the runner passes one.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import System from 'system';

/** A socket under /dev/null, which is not a directory: none can ever exist there, and a connect fails at once. */
const UNREACHABLE_BUS_ADDRESS = 'unix:path=/dev/null/resource-pulse-plain-gjs-rows-have-no-bus';
/** A directory under /dev/null: none can ever exist there, so nothing (herdr's socket included) is under it. */
const UNREACHABLE_CONFIG_HOME = '/dev/null/resource-pulse-plain-gjs-rows-have-no-config-home';
/**
 * The variables the barrier sets, each with its value: the buses' addresses GIO reads, and the config home GLib reads
 * (the service's default for herdr's socket is under it).
 */
const BARRED_VALUES_BY_VARIABLE_NAME = Object.freeze({
    DBUS_SESSION_BUS_ADDRESS: UNREACHABLE_BUS_ADDRESS,
    DBUS_SYSTEM_BUS_ADDRESS: UNREACHABLE_BUS_ADDRESS,
    XDG_CONFIG_HOME: UNREACHABLE_CONFIG_HOME,
});
/** Set in the runner started again, so one that can still reach the live session stops rather than start another. */
const RESTARTED_BEHIND_BARRIER_VARIABLE_NAME = 'RESOURCE_PULSE_RESTARTED_BEHIND_LIVE_SESSION_BARRIER';
const RESTARTED_BEHIND_BARRIER_VALUE = '1';
/** The binary of the running gjs, so the runner starts again under the same one. */
const RUNNING_BINARY_LINK_PATH = '/proc/self/exe';
const MODULE_FLAG = '-m';
/** As run.js's: "could not run", never a pass. */
const EXIT_CODE_HARNESS_ERROR = 2;

/**
 * Says whether this process was given every variable the barrier sets at the barrier's value.
 *
 * @returns {boolean} True when each variable of BARRED_VALUES_BY_VARIABLE_NAME has its value.
 */
function isEveryLiveDefaultBarred() {
    return Object.entries(BARRED_VALUES_BY_VARIABLE_NAME)
        .every(([variableName, barredValue]) => GLib.getenv(variableName) === barredValue);
}

/**
 * Starts the runner again, under the same gjs, with the same entry and arguments and every variable the barrier sets
 * at its value, inheriting this process's standard input, output and error; waits for it.
 *
 * @returns {number} Its exit status, or EXIT_CODE_HARNESS_ERROR when it could not be started or did not exit itself.
 */
function runAgainBehindBarrier() {
    const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.STDIN_INHERIT});
    for (const [variableName, barredValue] of Object.entries(BARRED_VALUES_BY_VARIABLE_NAME))
        launcher.setenv(variableName, barredValue, true);
    launcher.setenv(RESTARTED_BEHIND_BARRIER_VARIABLE_NAME, RESTARTED_BEHIND_BARRIER_VALUE, true);
    let restartedRunner;
    try {
        const gjsBinaryPath = GLib.file_read_link(RUNNING_BINARY_LINK_PATH);
        restartedRunner = launcher.spawnv([gjsBinaryPath, MODULE_FLAG, System.programPath, ...System.programArgs]);
        restartedRunner.wait(null);
    } catch (error) {
        printerr(`harness error: cannot start the runner again behind the live-session barrier: ${error.message}`);
        return EXIT_CODE_HARNESS_ERROR;
    }
    return restartedRunner.get_if_exited() ? restartedRunner.get_exit_status() : EXIT_CODE_HARNESS_ERROR;
}

/**
 * Lets the rows run in this process only when it was started behind the barrier; otherwise runs them again behind it
 * and exits with that run's status. A runner already started again that still finds the live session reachable (a bus
 * or the config home unbarred) exits 2.
 *
 * @returns {void}
 */
function runOnlyBehindBarrier() {
    if (isEveryLiveDefaultBarred())
        return;
    if (GLib.getenv(RESTARTED_BEHIND_BARRIER_VARIABLE_NAME) === RESTARTED_BEHIND_BARRIER_VALUE) {
        printerr('harness error: the runner started again behind the live-session barrier can still reach the live ' +
            'session (a bus or the config home)');
        System.exit(EXIT_CODE_HARNESS_ERROR);
    }
    System.exit(runAgainBehindBarrier());
}

runOnlyBehindBarrier();
