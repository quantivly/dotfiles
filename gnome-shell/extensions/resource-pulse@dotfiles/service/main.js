// The sampler service's entry point: `gjs -m service/main.js`, run by systemd/resource-pulse.service (Type=dbus), and
// by the tests on a private bus. It owns lib/protocol.js's bus name on the session bus, serves a ServiceSampler there
// (service/dbusService.js), and runs until SIGTERM or SIGINT (a stop) or until it loses the name.
//
// - The object is exported when the bus connection is up, before the name is requested, so a client that sees the
//   name can call it at once; systemd counts the unit started at the same moment. Sampling starts once the name is
//   owned.
// - The name is requested without queueing: a second copy that finds it taken exits 1 at once rather than waiting.
// - Every shutdown destroys the sampler, never only stops it: a stopped sampler still scans on a watch start.
// - Exit status: 0 for a signal, or for losing the name once owned (the bus connection closed: the session ended);
//   1 when the name was never owned, or the object could not be exported.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GLibUnix from 'gi://GLibUnix';
import System from 'system';

import {LOG_PREFIX} from '../lib/constants.js';
import {describeErrorWithStack} from '../lib/errorLog.js';
import {PROTOCOL_VERSION, RESOURCE_PULSE_BUS_NAME} from '../lib/protocol.js';
import {runEveryStep} from '../lib/teardown.js';
import {ResourcePulseDBusService} from './dbusService.js';
import {ServiceSampler} from './sampler.js';

const SIGINT_NUMBER = 2;
const SIGTERM_NUMBER = 15;
const SHUTDOWN_SIGNAL_NAMES_BY_NUMBER = new Map([[SIGTERM_NUMBER, 'SIGTERM'], [SIGINT_NUMBER, 'SIGINT']]);
const EXIT_STATUS_SUCCESS = 0;
const EXIT_STATUS_FAILURE = 1;

/** One run of the service: the sampler, its D-Bus face, the bus name and the main loop, and their shutdown. */
class ResourcePulseServiceProcess {
    constructor() {
        this._serviceStartedAtUsec = GLib.get_real_time();
        this._mainLoop = new GLib.MainLoop(null, false);
        this._sampler = null;
        this._dbusService = null;
        this._busOwnerId = null;
        this._signalSourceIds = [];
        this._hasOwnedName = false;
        this._isShuttingDown = false;
        this._exitStatus = EXIT_STATUS_SUCCESS;
    }

    /**
     * Runs the service until it shuts down.
     *
     * @returns {number} The process exit status.
     */
    run() {
        this._sampler = new ServiceSampler();
        this._sampler.initialize();
        for (const [signalNumber, signalName] of SHUTDOWN_SIGNAL_NAMES_BY_NUMBER) {
            this._signalSourceIds.push(GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signalNumber, () => {
                this._shutDown(`received ${signalName}`, EXIT_STATUS_SUCCESS);
                return GLib.SOURCE_CONTINUE;
            }));
        }
        this._busOwnerId = Gio.bus_own_name(Gio.BusType.SESSION, RESOURCE_PULSE_BUS_NAME,
            Gio.BusNameOwnerFlags.DO_NOT_QUEUE,
            connection => this._onBusAcquired(connection),
            () => this._onNameAcquired(),
            () => this._onNameLost());
        this._mainLoop.run();
        return this._exitStatus;
    }

    /**
     * Exports the object on the new connection, before the name is requested.
     *
     * @param {Gio.DBusConnection} connection - The session bus connection.
     * @returns {void}
     */
    _onBusAcquired(connection) {
        try {
            this._dbusService = new ResourcePulseDBusService(this._sampler, connection,
                {serviceStartedAtUsec: this._serviceStartedAtUsec});
        } catch (error) {
            const errorText = describeErrorWithStack(error);
            this._shutDown(`cannot export the D-Bus object: ${errorText}`, EXIT_STATUS_FAILURE);
        }
    }

    /**
     * Starts sampling once the name is owned; the sampler's first tick runs at once.
     *
     * @returns {void}
     */
    _onNameAcquired() {
        if (this._isShuttingDown)
            return;
        this._hasOwnedName = true;
        this._sampler.start();
        console.log(`${LOG_PREFIX} serving ${RESOURCE_PULSE_BUS_NAME} (protocol ${PROTOCOL_VERSION})`);
    }

    /**
     * Shuts down when the name is lost: a failure if it was never owned (another copy holds it, or there is no bus),
     * and the end of the session if it was (it is not given up to anyone, so only a closed connection loses it).
     *
     * @returns {void}
     */
    _onNameLost() {
        if (this._hasOwnedName)
            this._shutDown(`lost ${RESOURCE_PULSE_BUS_NAME}: the bus connection closed`, EXIT_STATUS_SUCCESS);
        else
            this._shutDown(`cannot own ${RESOURCE_PULSE_BUS_NAME}: another copy holds it, or there is no session bus`,
                EXIT_STATUS_FAILURE);
    }

    /**
     * Stops everything once: the signal handlers, the D-Bus face, the sampler (destroyed, never only stopped) and
     * the name, each whatever the others throw; then quits the main loop.
     *
     * @param {string} reason - Why, for the journal.
     * @param {number} exitStatus - The status the process will exit with.
     * @returns {void}
     */
    _shutDown(reason, exitStatus) {
        if (this._isShuttingDown)
            return;
        this._isShuttingDown = true;
        this._exitStatus = exitStatus;
        const logLine = `${LOG_PREFIX} shutting down: ${reason}`;
        if (exitStatus === EXIT_STATUS_SUCCESS)
            console.log(logLine);
        else
            console.error(logLine);
        runEveryStep([
            {name: 'remove the signal handlers', run: () => this._removeSignalSources()},
            {name: 'destroy the D-Bus face', run: () => this._dbusService?.destroy()},
            {name: 'destroy the sampler', run: () => this._sampler?.destroy()},
            {name: 'release the bus name', run: () => this._releaseBusName()},
        ], (stepName, error) => {
            const errorText = describeErrorWithStack(error);
            console.error(`${LOG_PREFIX} shutdown: ${stepName} failed: ${errorText}`);
        });
        this._mainLoop.quit();
    }

    /**
     * Removes the SIGTERM and SIGINT handlers.
     *
     * @returns {void}
     */
    _removeSignalSources() {
        const signalSourceIds = this._signalSourceIds;
        this._signalSourceIds = [];
        for (const signalSourceId of signalSourceIds)
            GLib.source_remove(signalSourceId);
    }

    /**
     * Releases the bus name, once owned. A copy that never owned it leaves it alone: Gio.bus_unown_name would ask the
     * bus to release a name another copy holds, and GLib warns at the refusal (measured: "Unexpected reply 3 when
     * releasing name"). The process exits next, and the bus drops its pending request with its connection.
     *
     * @returns {void}
     */
    _releaseBusName() {
        if (this._busOwnerId === null || !this._hasOwnedName)
            return;
        Gio.bus_unown_name(this._busOwnerId);
        this._busOwnerId = null;
    }
}

const exitStatus = new ResourcePulseServiceProcess().run();
System.exit(exitStatus);
