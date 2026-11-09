// Naming, grouping and ranking apps from systemd cgroup leaves. Pure logic: no file IO.
import {KERNEL_LABEL, SHORT_JOBS_LABEL, UNIT_DISPLAY_ALIASES} from './constants.js';

const SYSTEMD_HEX_ESCAPE_PATTERN = /\\x([0-9a-fA-F]{2})/g;
const HEX_RADIX = 16;
const PERCENT_SCALE = 100;
/** `app-[<launcher>-]<appId>-<digits>.scope`; the launcher is optional and from a closed set. */
const APP_SCOPE_PATTERN = /^app-(?:(?:gnome|flatpak|kde|dbus|systemd)-)?(.+)-\d+\.scope$/;
const APP_SCOPE_LAUNCHER_PATTERN = /^app-(?:gnome|flatpak|kde|dbus|systemd)-(.+)-\d+\.scope$/;
const SNAP_PATTERN = /^snap\.([^.]+)\./;
/** `snap.<snap>.<app>[-<uuid>].scope|service`: the app is what `<snap>_<app>.desktop` is named after. */
const SNAP_UNIT_PATTERN =
    /^snap\.([^.]+)\.([^.]+?)(?:-[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})?\.(?:scope|service)$/;
const DOCKER_SCOPE_PATTERN = /^docker-.*\.scope$/;
const UNIT_PATTERN = /^(.+?)(?:@.*)?\.(?:service|scope)$/;
const DOCKER_NAME = 'docker';
const GNOME_SETTINGS_DAEMON_PREFIX = 'org.gnome.SettingsDaemon.';
const SETTINGS_DAEMON_SHORT_PREFIX = 'gsd-';
/** A unit named like `<tld>.<vendor>.<Product>...` is reverse-DNS; the first two segments carry no information. */
const REVERSE_DNS_TOP_LEVEL_DOMAINS = ['org', 'com', 'net', 'io'];
const REVERSE_DNS_VENDOR_SEGMENT_COUNT = 2;
const PSEUDO_KERNEL_GROUP_KEY = 'pseudo:kernel';
const PSEUDO_SHORT_JOBS_GROUP_KEY = 'pseudo:short-jobs';

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
 * Names a service unit for display: a configured alias, `gsd-<x>` for a GNOME settings daemon, the name minus its
 * first two segments for any other reverse-DNS unit, else the unit name itself.
 *
 * @param {string} unitName - the unit name without its suffix or instance.
 * @returns {string} The display name.
 */
function displayNameOfUnit(unitName) {
    if (Object.hasOwn(UNIT_DISPLAY_ALIASES, unitName))
        return UNIT_DISPLAY_ALIASES[unitName];
    if (unitName.startsWith(GNOME_SETTINGS_DAEMON_PREFIX))
        return SETTINGS_DAEMON_SHORT_PREFIX + unitName.slice(GNOME_SETTINGS_DAEMON_PREFIX.length).toLowerCase();
    const segments = unitName.split('.');
    const isReverseDns = REVERSE_DNS_TOP_LEVEL_DOMAINS.includes(segments[0]) &&
        segments.length > REVERSE_DNS_VENDOR_SEGMENT_COUNT;
    if (isReverseDns)
        return segments.slice(REVERSE_DNS_VENDOR_SEGMENT_COUNT).join('.');
    return unitName;
}

/**
 * Classifies a cgroup leaf and names the group it belongs to.
 *
 * @param {string} leafName - the cgroup leaf directory name (a `.slice` is never a leaf).
 * @returns {{groupKey: string, kind: string, appId?: string, snapName?: string, snapAppName?: string,
 *     fallbackName: string}} The description.
 */
export function describeCgroup(leafName) {
    // The launcher is matched on the still-escaped name: `app-gnome\x2dcalculator-1.scope` is the app
    // `gnome-calculator`, not the app `calculator` launched by gnome.
    const appMatch = leafName.match(APP_SCOPE_LAUNCHER_PATTERN) ?? leafName.match(APP_SCOPE_PATTERN);
    if (appMatch) {
        const appId = unescapeSystemdName(appMatch[1]);
        return {groupKey: `app:${appId}`, kind: 'app', appId, fallbackName: capitaliseLastSegment(appId)};
    }
    const name = unescapeSystemdName(leafName);
    const snapMatch = name.match(SNAP_PATTERN);
    if (snapMatch) {
        const snapName = snapMatch[1];
        const snapAppName = name.match(SNAP_UNIT_PATTERN)?.[2] ?? snapName;
        return {groupKey: `snap:${snapName}`, kind: 'snap', snapName, snapAppName, fallbackName: snapName};
    }
    if (DOCKER_SCOPE_PATTERN.test(name))
        return {groupKey: `docker:${DOCKER_NAME}`, kind: 'docker', fallbackName: DOCKER_NAME};
    const unitMatch = name.match(UNIT_PATTERN);
    const unitName = unitMatch ? unitMatch[1] : name;
    return {groupKey: `unit:${unitName}`, kind: 'unit', fallbackName: displayNameOfUnit(unitName)};
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
 * Picks the name to show for a described cgroup. An app is looked up as `<appId>.desktop` and a snap as
 * `<snap>_<app>.desktop`; every other kind keeps its fallback name.
 *
 * @param {{kind: string, appId?: string, snapName?: string, snapAppName?: string, fallbackName: string}} description -
 *     from describeCgroup.
 * @param {(desktopId: string) => string|null} resolveAppName - looks up a `.desktop` id's real name.
 * @returns {string} The display name.
 */
export function displayNameFor(description, resolveAppName) {
    if (description.kind === 'app')
        return resolveAppName(`${description.appId}.desktop`) || description.fallbackName;
    if (description.kind === 'snap')
        return resolveAppName(`${description.snapName}_${description.snapAppName}.desktop`) || description.fallbackName;
    return description.fallbackName;
}

/**
 * Adds an amount to a group's running total in a Map.
 *
 * @param {Map<string, {groupKey: string, name: string, value: number}>} totals - totals by group key.
 * @param {{groupKey: string, name: string}} group - the group to add to.
 * @param {number} amount - what to add.
 */
function addToGroup(totals, group, amount) {
    const entry = totals.get(group.groupKey) ?? {groupKey: group.groupKey, name: group.name, value: 0};
    entry.value += amount;
    totals.set(group.groupKey, entry);
}

/**
 * Picks the entry with the largest value; equal values go to the name that sorts first, so the
 * answer never depends on Map insertion order.
 *
 * @param {Iterable<{groupKey: string, name: string, value: number}>} entries - candidates.
 * @returns {{groupKey: string, name: string, value: number}|null} The winner, or null when there are none.
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
 * Works out one leaf's CPU delta since the previous scan.
 *
 * @param {object} scan - rankApps' input.
 * @param {string} cgroupPath - the leaf.
 * @param {number} currentUsec - its usage_usec now.
 * @returns {number|null} The delta, or null when the leaf cannot be counted: it is new and its parent was not
 *     listed in the previous scan, so it may be old and merely unlisted.
 */
function leafCpuDeltaUsec(scan, cgroupPath, currentUsec) {
    if (scan.previousUsageUsec.has(cgroupPath)) {
        const previousUsec = scan.previousUsageUsec.get(cgroupPath);
        // A counter that went backwards is a unit recreated at the same path: all of its usage is new.
        return currentUsec >= previousUsec ? currentUsec - previousUsec : currentUsec;
    }
    // A new leaf ran for less than one interval; it counts in full, but only when its parent's listing proves the
    // leaf did not exist before (otherwise a failed listing would turn every old leaf into a full-lifetime burst).
    return scan.parentsListedPreviously.has(scan.parentOfLeaf.get(cgroupPath)) ? currentUsec : null;
}

/**
 * Says whether kernel and short jobs can be computed: every parent of a scanned leaf has a delta, and there is at
 * least one. With no parents read, "root minus zero parents" would name the whole machine as kernel.
 *
 * @param {object} scan - rankApps' input.
 * @returns {boolean} True when the parent deltas are complete.
 */
function hasCompleteParentDeltas(scan) {
    if (scan.parentCpuDeltaUsec.size === 0)
        return false;
    return [...new Set(scan.parentOfLeaf.values())].every(parentPath => scan.parentCpuDeltaUsec.has(parentPath));
}

/**
 * Computes the CPU of what no leaf accounts for, in microseconds.
 *
 * @param {object} scan - rankApps' input.
 * @param {Map<string, number>} leafDeltaByParent - Σ of the counted leaf deltas, by parent path.
 * @returns {{kernelUsec: number|null, shortJobsUsec: number}|null} Null when the parent deltas are incomplete;
 *     kernelUsec is null without a root delta.
 */
function unattributedCpuUsec(scan, leafDeltaByParent) {
    if (!hasCompleteParentDeltas(scan))
        return null;
    let parentDeltaTotalUsec = 0;
    let shortJobsUsec = 0;
    for (const [parentPath, parentDeltaUsec] of scan.parentCpuDeltaUsec) {
        parentDeltaTotalUsec += parentDeltaUsec;
        // Read skew can put the leaves above the parent; that is no negative job.
        shortJobsUsec += Math.max(0, parentDeltaUsec - (leafDeltaByParent.get(parentPath) ?? 0));
    }
    const kernelUsec = scan.rootCpuDeltaUsec === null ? null : Math.max(0, scan.rootCpuDeltaUsec - parentDeltaTotalUsec);
    return {kernelUsec, shortJobsUsec};
}

/**
 * Ranks apps by CPU (share of the whole machine) and by memory. "kernel" (the root cgroup's CPU no scanned parent
 * slice accounts for) and "short jobs" (what the parents spent beyond their live leaves: units that started and
 * ended between two scans) are candidates for CPU only; the memory half names real apps only, by the owner's
 * decision. Both are ranked only when every parent of a scanned leaf has a delta (and at least one does).
 *
 * @param {object} scan - the inputs.
 * @param {Map<string, number>} scan.previousUsageUsec - cpu.stat usage_usec by cgroup, last scan.
 * @param {Map<string, number>} scan.currentUsageUsec - the same, this scan.
 * @param {Map<string, number>} scan.memoryBytesByCgroup - non-cache memory by cgroup.
 * @param {number} scan.elapsedUsec - time between the two readings.
 * @param {number} scan.cpuCount - CPUs counted as 100%.
 * @param {number|null} scan.rootCpuDeltaUsec - the root cgroup's usage_usec delta, if known.
 * @param {Map<string, string>} [scan.parentOfLeaf] - the parent slice path of each scanned leaf.
 * @param {Set<string>} [scan.parentsListedPreviously] - parents whose leaves were listed in the previous scan.
 * @param {Map<string, number>} [scan.parentCpuDeltaUsec] - usage_usec delta of each parent read in both scans.
 * @param {(cgroupPath: string) => {groupKey: string, name: string}} scan.nameOfCgroup - grouping and naming.
 * @returns {{topCpu: {groupKey: string, name: string, cpuPercent: number}|null,
 *     topMemory: {groupKey: string, name: string, memoryBytes: number}|null}} The two winners; topCpu is null when
 *     nothing has a delta.
 */
export function rankApps(scan) {
    const rankingScan = {
        parentOfLeaf: new Map(), parentsListedPreviously: new Set(), parentCpuDeltaUsec: new Map(), ...scan,
    };
    const cpuDeltaByGroup = new Map();
    const leafDeltaByParent = new Map();
    for (const [cgroupPath, currentUsec] of rankingScan.currentUsageUsec) {
        const deltaUsec = leafCpuDeltaUsec(rankingScan, cgroupPath, currentUsec);
        if (deltaUsec === null)
            continue;
        const parentPath = rankingScan.parentOfLeaf.get(cgroupPath);
        leafDeltaByParent.set(parentPath, (leafDeltaByParent.get(parentPath) ?? 0) + deltaUsec);
        addToGroup(cpuDeltaByGroup, rankingScan.nameOfCgroup(cgroupPath), deltaUsec);
    }
    const memoryByGroup = new Map();
    for (const [cgroupPath, memoryBytes] of rankingScan.memoryBytesByCgroup)
        addToGroup(memoryByGroup, rankingScan.nameOfCgroup(cgroupPath), memoryBytes);
    const unattributed = unattributedCpuUsec(rankingScan, leafDeltaByParent);
    if (unattributed !== null) {
        if (unattributed.kernelUsec !== null)
            addToGroup(cpuDeltaByGroup, {groupKey: PSEUDO_KERNEL_GROUP_KEY, name: KERNEL_LABEL}, unattributed.kernelUsec);
        addToGroup(cpuDeltaByGroup, {groupKey: PSEUDO_SHORT_JOBS_GROUP_KEY, name: SHORT_JOBS_LABEL},
            unattributed.shortJobsUsec);
    }

    const canRankCpu = rankingScan.elapsedUsec > 0 && rankingScan.cpuCount > 0;
    const topCpuEntry = canRankCpu ? pickLargest(cpuDeltaByGroup.values()) : null;
    const topMemoryEntry = pickLargest(memoryByGroup.values());
    const machineCapacityUsec = rankingScan.elapsedUsec * rankingScan.cpuCount;
    return {
        topCpu: topCpuEntry && {
            groupKey: topCpuEntry.groupKey, name: topCpuEntry.name,
            cpuPercent: topCpuEntry.value / machineCapacityUsec * PERCENT_SCALE,
        },
        topMemory: topMemoryEntry && {
            groupKey: topMemoryEntry.groupKey, name: topMemoryEntry.name, memoryBytes: topMemoryEntry.value,
        },
    };
}
