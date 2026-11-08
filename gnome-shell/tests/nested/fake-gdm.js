// Test double for scripts/resource-pulse-nested.sh: owns org.gnome.DisplayManager on the nested run's FAKE system
// bus only, so the nested shell's LoginManager.canLock() is true and it builds a ScreenShield as the live one does.
// It connects to the address given as ARGV[0] only when that is exactly the fake system bus of the run named by
// RESOURCE_PULSE_NESTED_DIR, and refuses any other bus, so it can never answer on the real one.
// Usage (inside a run's environment): gjs -m fake-gdm.js unix:path=<run dir>/bus/system.sock
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

/** Set by scripts/resource-pulse-nested.sh to the run directory, in the nested processes' environment only. */
const NESTED_RUN_DIR_VARIABLE = 'RESOURCE_PULSE_NESTED_DIR';
/** Where the fake system bus listens, relative to the run directory. */
const FAKE_SYSTEM_BUS_SOCKET_RELATIVE_PATH = 'bus/system.sock';
const FAKE_GDM_VERSION = '50.0';
const MANAGER_OBJECT_PATH = '/org/gnome/DisplayManager/Manager';
const MANAGER_BUS_NAME = 'org.gnome.DisplayManager';
const MANAGER_INTERFACE_XML = `
<node>
  <interface name="org.gnome.DisplayManager.Manager">
    <method name="RegisterSession"/>
    <method name="RegisterDisplay"/>
    <property name="Version" type="s" access="read"/>
  </interface>
</node>`;

const [fakeSystemBusAddress] = ARGV;
const nestedRunDir = GLib.getenv(NESTED_RUN_DIR_VARIABLE);
const runFakeSystemBusAddress = nestedRunDir ? `unix:path=${nestedRunDir}/${FAKE_SYSTEM_BUS_SOCKET_RELATIVE_PATH}` : null;
if (runFakeSystemBusAddress === null || fakeSystemBusAddress !== runFakeSystemBusAddress)
    throw new Error(`refusing to connect to anything but the fake system bus of this run, got: ${fakeSystemBusAddress}`);

const connection = Gio.DBusConnection.new_for_address_sync(fakeSystemBusAddress,
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, null, null);
const managerImplementation = {
    get Version() {
        return FAKE_GDM_VERSION;
    },
    RegisterSession() {
        print('fake-gdm: RegisterSession called');
    },
    RegisterDisplay() {
        print('fake-gdm: RegisterDisplay called');
    },
};
const exportedManager = Gio.DBusExportedObject.wrapJSObject(MANAGER_INTERFACE_XML, managerImplementation);
exportedManager.export(connection, MANAGER_OBJECT_PATH);
Gio.bus_own_name_on_connection(connection, MANAGER_BUS_NAME, Gio.BusNameOwnerFlags.NONE,
    () => print(`fake-gdm: owns ${MANAGER_BUS_NAME}`), () => print(`fake-gdm: lost ${MANAGER_BUS_NAME}`));
const mainLoop = new GLib.MainLoop(null, false);
connection.connect('closed', () => mainLoop.quit());
mainLoop.run();
