// The cockpit monitor rule: which monitor shows the cockpit, and the pure half of reading Mutter's DisplayConfig so the
// config's vendor and product can be matched to Main.layoutManager.monitors. Pure: no Gio, GLib or Shell import.

/** Position of the (connector, vendor, product, serial) tuple inside a monitor entry of GetCurrentState. */
const MONITOR_SPEC_INDEX = 0;
/** Position of the monitors array in GetCurrentState's reply `(serial, monitors, logical_monitors, properties)`. */
const STATE_MONITORS_INDEX = 1;
/** Position of the logical monitors array in the same reply. */
const STATE_LOGICAL_MONITORS_INDEX = 2;
/** Positions of x and y inside a logical monitor tuple `(x, y, scale, transform, is_primary, monitors, properties)`. */
const LOGICAL_X_INDEX = 0;
const LOGICAL_Y_INDEX = 1;
/** Position of the list of (connector, vendor, product, serial) tuples a logical monitor shows. */
const LOGICAL_MONITOR_SPECS_INDEX = 5;

/**
 * Chooses the cockpit monitor: the one whose vendor and product both equal the rule's (case-sensitive) when a rule is
 * given and one matches; else the only monitor when there is one; else the largest non-primary monitor by
 * width x height (ties go to the lowest index). Null when there are no monitors, or several and all primary.
 *
 * @param {object} options - The inputs.
 * @param {Array<{index: number, x: number, y: number, width: number, height: number, isPrimary: boolean,
 *     vendor: (string|null), product: (string|null)}>} options.monitors - The monitors, vendor and product null when
 *     unknown.
 * @param {({vendor: string, product: string}|null)} options.rule - The config's monitor rule, or null.
 * @returns {(number|null)} The chosen monitor's `index`, or null.
 */
export function chooseCockpitMonitorIndex({monitors, rule}) {
    if (monitors.length === 0)
        return null;
    if (rule) {
        const named = monitors.find(monitor => monitor.vendor === rule.vendor && monitor.product === rule.product);
        if (named)
            return named.index;
    }
    if (monitors.length === 1)
        return monitors[0].index;
    let largest = null;
    monitors.filter(monitor => !monitor.isPrimary).forEach(monitor => {
        const isLarger = largest === null || monitor.width * monitor.height > largest.width * largest.height ||
            (monitor.width * monitor.height === largest.width * largest.height && monitor.index < largest.index);
        if (isLarger)
            largest = monitor;
    });
    return largest === null ? null : largest.index;
}

/**
 * Reads the monitors' identities out of `org.gnome.Mutter.DisplayConfig.GetCurrentState`'s reply, as
 * GLib.Variant.deepUnpack() gives it: `(serial, monitors, logical_monitors, properties)`. It reads only
 * `state[1][i][0]`, the monitor's `(connector, vendor, product, serial)` tuple, and ignores the serial and every mode.
 * The tuple layout is from the D-Bus interface and a capture on the laptop; the glue task's builder verifies it in the
 * nested shell. Anything that does not fit the shape gives an empty list.
 *
 * @param {*} currentState - The unpacked GetCurrentState reply.
 * @returns {Array<{connector: string, vendor: string, product: string}>} One descriptor per monitor, in reply order.
 */
export function monitorDescriptorsFromDisplayConfig(currentState) {
    if (!Array.isArray(currentState) || !Array.isArray(currentState[STATE_MONITORS_INDEX]))
        return [];
    return currentState[STATE_MONITORS_INDEX].flatMap(monitorEntry => {
        const spec = Array.isArray(monitorEntry) ? monitorEntry[MONITOR_SPEC_INDEX] : null;
        if (!Array.isArray(spec) || spec.length < 3)
            return [];
        const [connector, vendor, product] = spec;
        return [{connector, vendor, product}];
    });
}

/**
 * Fills each layout monitor's vendor and product from the descriptor of the logical monitor at the same x and y; a
 * logical monitor showing several connectors (mirroring) uses its first. Reads `x`, `y` and the connector list of each
 * logical monitor tuple `(x, y, scale, transform, is_primary, [(connector, vendor, product, serial)…], properties)`.
 *
 * @param {object} options - The inputs.
 * @param {Array<{index: number, x: number, y: number}>} options.monitors - Main.layoutManager.monitors, as plain objects.
 * @param {Array<Array>} options.logicalMonitors - GetCurrentState's unpacked logical_monitors (element 2).
 * @param {Array<{connector: string, vendor: string, product: string}>} options.descriptors - From
 *     monitorDescriptorsFromDisplayConfig.
 * @returns {Array<object>} The `monitors`, each with `vendor` and `product` set, null when no logical monitor sits at
 *     its position or its connector has no descriptor.
 */
export function matchDescriptorsToMonitors({monitors, logicalMonitors, descriptors}) {
    return monitors.map(monitor => {
        const logicalMonitor = logicalMonitors.find(candidate =>
            candidate[LOGICAL_X_INDEX] === monitor.x && candidate[LOGICAL_Y_INDEX] === monitor.y);
        const shownSpecs = logicalMonitor ? logicalMonitor[LOGICAL_MONITOR_SPECS_INDEX] : null;
        const firstConnector = Array.isArray(shownSpecs) && shownSpecs.length > 0 ? shownSpecs[0][0] : null;
        const descriptor = descriptors.find(candidate => candidate.connector === firstConnector);
        return {...monitor, vendor: descriptor ? descriptor.vendor : null, product: descriptor ? descriptor.product : null};
    });
}

/**
 * The logical monitors of GetCurrentState's unpacked reply that matchDescriptorsToMonitors can read: tuples whose list
 * of shown monitors holds tuples. Anything else (a reply of an unexpected shape, or none) gives none, never a throw.
 *
 * @param {*} currentState - The unpacked GetCurrentState reply, or null when there is none.
 * @returns {Array<Array>} The readable logical monitors, in reply order.
 */
function readableLogicalMonitors(currentState) {
    const logicalMonitors = Array.isArray(currentState) ? currentState[STATE_LOGICAL_MONITORS_INDEX] : null;
    if (!Array.isArray(logicalMonitors))
        return [];
    return logicalMonitors.filter(logicalMonitor => Array.isArray(logicalMonitor) &&
        Array.isArray(logicalMonitor[LOGICAL_MONITOR_SPECS_INDEX]) &&
        logicalMonitor[LOGICAL_MONITOR_SPECS_INDEX].every(Array.isArray));
}

/**
 * The layout's monitor rule as chooseCockpitMonitorIndex takes it: one that names both a vendor and a product, or none.
 * A rule naming neither (lib/cockpitProtocol.js parseMonitorRule reads a missing one so) would otherwise match the
 * first monitor DisplayConfig left unidentified, whose vendor and product are null too.
 *
 * @param {{vendor: string|null, product: string|null}|null} monitorRule - The layout's monitor rule.
 * @returns {{vendor: string, product: string}|null} The rule, or null for none.
 */
function completeMonitorRule(monitorRule) {
    const isComplete = typeof monitorRule?.vendor === 'string' && typeof monitorRule?.product === 'string';
    return isComplete ? {vendor: monitorRule.vendor, product: monitorRule.product} : null;
}

/**
 * The cockpit monitor, from the shell's monitors, DisplayConfig's last answer and the layout's rule: each monitor is
 * identified by the DisplayConfig descriptor at its position (matchDescriptorsToMonitors), then chosen
 * (chooseCockpitMonitorIndex). With no answer yet, or one of an unexpected shape, no monitor is identified and the rule
 * falls back: the only monitor, else the largest non-primary. Undocked to the primary alone, that is the primary.
 *
 * @param {object} options - The inputs.
 * @param {Array<{index: number, x: number, y: number, width: number, height: number, isPrimary: boolean}>}
 *     options.monitors - Main.layoutManager.monitors, as plain objects.
 * @param {*} options.displayConfigState - DisplayConfig's unpacked GetCurrentState reply, or null for none.
 * @param {{vendor: string|null, product: string|null}|null} options.monitorRule - The layout's monitor rule.
 * @returns {number|null} The cockpit monitor's index, or null when there is none (no monitor).
 */
export function cockpitMonitorIndexFor({monitors, displayConfigState, monitorRule}) {
    const descriptors = monitorDescriptorsFromDisplayConfig(displayConfigState);
    const logicalMonitors = readableLogicalMonitors(displayConfigState);
    const identifiedMonitors = matchDescriptorsToMonitors({monitors, logicalMonitors, descriptors});
    return chooseCockpitMonitorIndex({monitors: identifiedMonitors, rule: completeMonitorRule(monitorRule)});
}
