// Naming, grouping and ranking apps from systemd cgroup leaves. Pure logic: no file IO.
import {KERNEL_AND_OTHER_LABEL, UNIT_DISPLAY_ALIASES} from './constants.js';

const SYSTEMD_HEX_ESCAPE_PATTERN = /\\x([0-9a-fA-F]{2})/g;
const HEX_RADIX = 16;
const PERCENT_SCALE = 100;
/** `app-[<launcher>-]<appId>-<digits>.scope`; the launcher is optional and from a closed set. */
const APP_SCOPE_PATTERN = /^app-(?:(?:gnome|flatpak|kde|dbus|systemd)-)?(.+)-\d+\.scope$/;
const APP_SCOPE_LAUNCHER_PATTERN = /^app-(?:gnome|flatpak|kde|dbus|systemd)-(.+)-\d+\.scope$/;
const SNAP_PATTERN = /^snap\.([^.]+)\./;
const DOCKER_SCOPE_PATTERN = /^docker-.*\.scope$/;
const UNIT_PATTERN = /^(.+?)(?:@.*)?\.(?:service|scope)$/;
const DOCKER_NAME = 'docker';

/**
 * Turns systemd's `\xNN` escapes (every one) back into the characters they stand for.
 *
 * @param {string} name - a cgroup leaf name.
 * @returns {string} The unescaped name.
 */
export function unescapeSystemdName(name) {
    return name.replace(SYSTEMD_HEX_ESCAPE_PATTERN,
        (_match, hexDigits) => String.fromCharCode(parseInt(hexDigits, HEX_RADIX)));
}

/**
 * Classifies a cgroup leaf and names the group it belongs to.
 *
 * @param {string} leafName - the cgroup leaf directory name (a `.slice` is never a leaf).
 * @returns {{groupKey: string, kind: string, appId?: string, fallbackName: string}} The description.
 */
export function describeCgroup(leafName) {
    const name = unescapeSystemdName(leafName);
    const appMatch = name.match(APP_SCOPE_LAUNCHER_PATTERN) ?? name.match(APP_SCOPE_PATTERN);
    if (appMatch) {
        const appId = appMatch[1];
        return {groupKey: `app:${appId}`, kind: 'app', appId, fallbackName: capitaliseLastSegment(appId)};
    }
    const snapMatch = name.match(SNAP_PATTERN);
    if (snapMatch)
        return {groupKey: `snap:${snapMatch[1]}`, kind: 'snap', fallbackName: snapMatch[1]};
    if (DOCKER_SCOPE_PATTERN.test(name))
        return {groupKey: `docker:${DOCKER_NAME}`, kind: 'docker', fallbackName: DOCKER_NAME};
    const unitMatch = name.match(UNIT_PATTERN);
    const unitName = unitMatch ? unitMatch[1] : name;
    const displayName = Object.hasOwn(UNIT_DISPLAY_ALIASES, unitName) ? UNIT_DISPLAY_ALIASES[unitName] : unitName;
    return {groupKey: `unit:${unitName}`, kind: 'unit', fallbackName: displayName};
}

/**
 * Capitalises the last dot-separated segment of an application id.
 *
 * @param {string} appId - for example 'org.chromium.Chromium'.
 * @returns {string} For example 'Chromium'.
 */
function capitaliseLastSegment(appId) {
    const lastSegment = appId.split('.').pop();
    return lastSegment.charAt(0).toUpperCase() + lastSegment.slice(1);
}

/**
 * Picks the name to show for a described cgroup.
 *
 * @param {{kind: string, appId?: string, fallbackName: string}} description - from describeCgroup.
 * @param {(desktopId: string) => string|null} resolveAppName - looks up a `.desktop` id's real name.
 * @returns {string} The display name.
 */
export function displayNameFor(description, resolveAppName) {
    if (description.kind !== 'app')
        return description.fallbackName;
    return resolveAppName(`${description.appId}.desktop`) || description.fallbackName;
}

/**
 * Adds an amount to a group's running total in a Map.
 *
 * @param {Map<string, {name: string, value: number}>} totals - totals by group key.
 * @param {{groupKey: string, name: string}} group - the group to add to.
 * @param {number} amount - what to add.
 */
function addToGroup(totals, group, amount) {
    const entry = totals.get(group.groupKey) ?? {name: group.name, value: 0};
    entry.value += amount;
    totals.set(group.groupKey, entry);
}

/**
 * Picks the entry with the largest value; equal values go to the name that sorts first, so the
 * answer never depends on Map insertion order.
 *
 * @param {Array<{name: string, value: number}>} entries - candidates.
 * @returns {{name: string, value: number}|null} The winner, or null when there are none.
 */
function pickLargest(entries) {
    let best = null;
    for (const entry of entries) {
        const beatsBest = best === null || entry.value > best.value ||
            (entry.value === best.value && entry.name < best.name);
        if (beatsBest)
            best = entry;
    }
    return best;
}

/**
 * Ranks apps by CPU (share of the whole machine) and by memory, with "kernel & other" as a pseudo-app.
 * A cgroup missing from the previous reading has no delta: it is left out of CPU, kept for memory.
 *
 * @param {object} scan - the inputs.
 * @param {Map<string, number>} scan.previousUsageUsec - cpu.stat usage_usec by cgroup, last scan.
 * @param {Map<string, number>} scan.currentUsageUsec - the same, this scan.
 * @param {Map<string, number>} scan.memoryBytesByCgroup - non-cache memory by cgroup.
 * @param {number} scan.elapsedUsec - time between the two readings.
 * @param {number} scan.cpuCount - CPUs counted as 100%.
 * @param {number|null} scan.rootCpuDeltaUsec - the root cgroup's usage_usec delta, if known.
 * @param {number|null} scan.memoryUsedBytes - machine memory used, if known.
 * @param {(cgroupPath: string) => {groupKey: string, name: string}} scan.nameOfCgroup - grouping and naming.
 * @returns {{topCpu: {name: string, cpuPercent: number}|null, topMemory: {name: string, memoryBytes: number}|null}}
 *     The two winners; topCpu is null when nothing has a delta.
 */
export function rankApps(scan) {
    const cpuDeltaByGroup = new Map();
    let leafDeltaTotalUsec = 0;
    for (const [cgroupPath, currentUsec] of scan.currentUsageUsec) {
        if (!scan.previousUsageUsec.has(cgroupPath))
            continue;
        // A counter that went backwards (cgroup recreated) is no usage, never negative usage.
        const deltaUsec = Math.max(0, currentUsec - scan.previousUsageUsec.get(cgroupPath));
        leafDeltaTotalUsec += deltaUsec;
        addToGroup(cpuDeltaByGroup, scan.nameOfCgroup(cgroupPath), deltaUsec);
    }
    const memoryByGroup = new Map();
    let appMemoryTotalBytes = 0;
    for (const [cgroupPath, memoryBytes] of scan.memoryBytesByCgroup) {
        appMemoryTotalBytes += memoryBytes;
        addToGroup(memoryByGroup, scan.nameOfCgroup(cgroupPath), memoryBytes);
    }
    if (scan.rootCpuDeltaUsec !== null)
        cpuDeltaByGroup.set(KERNEL_AND_OTHER_LABEL, {
            name: KERNEL_AND_OTHER_LABEL, value: Math.max(0, scan.rootCpuDeltaUsec - leafDeltaTotalUsec),
        });
    if (scan.memoryUsedBytes !== null)
        memoryByGroup.set(KERNEL_AND_OTHER_LABEL, {
            name: KERNEL_AND_OTHER_LABEL, value: Math.max(0, scan.memoryUsedBytes - appMemoryTotalBytes),
        });

    const topCpuEntry = scan.elapsedUsec > 0 && scan.cpuCount > 0 ? pickLargest(cpuDeltaByGroup.values()) : null;
    const topMemoryEntry = pickLargest(memoryByGroup.values());
    const machineCapacityUsec = scan.elapsedUsec * scan.cpuCount;
    return {
        topCpu: topCpuEntry && {
            name: topCpuEntry.name, cpuPercent: topCpuEntry.value / machineCapacityUsec * PERCENT_SCALE,
        },
        topMemory: topMemoryEntry && {name: topMemoryEntry.name, memoryBytes: topMemoryEntry.value},
    };
}
