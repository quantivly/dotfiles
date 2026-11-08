// Test double for scripts/resource-pulse-nested.sh: owns org.gnome.DisplayManager on the nested run's FAKE system
// bus only, so the nested shell's LoginManager.canLock() is true and it builds a ScreenShield as the live one does.
// It connects to the address given as ARGV[0] and refuses any other bus, so it can never answer on the real one.
// Usage: gjs -m fake-gdm.js unix:abstract=rp-nested-system-<run suffix>
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

const FAKE_SYSTEM_BUS_ADDRESS_PREFIX = 'unix:abstract=rp-nested-system-';
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
if (!fakeSystemBusAddress?.startsWith(FAKE_SYSTEM_BUS_ADDRESS_PREFIX))
    throw new Error(`refusing to connect to anything but the fake system bus, got: ${fakeSystemBusAddress}`);

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
