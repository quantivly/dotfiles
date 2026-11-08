import {PERFORMANCE_CAPACITY_RATIO} from './constants.js';

/**
 * Sums the counters that make up wall-clock CPU time. guest and guestNice are
 * excluded because the kernel already counts them inside user and nice.
 *
 * @param {object} times - CpuTimes.
 * @returns {number} Total ticks.
 */
function totalTicks(times) {
    return times.user + times.nice + times.system + times.idle + times.iowait +
        times.irq + times.softirq + times.steal;
}

/**
 * Idle ticks: iowait is the CPU waiting with nothing to run, so it is idle.
 *
 * @param {object} times - CpuTimes.
 * @returns {number} Idle ticks.
 */
function idleTicks(times) {
    return times.idle + times.iowait;
}

/**
 * Busy fraction between two samples of one CPU line.
 *
 * @param {object|null} previous - Earlier CpuTimes, or null on the first sample.
 * @param {object|null} current - Later CpuTimes.
 * @returns {number|null} 0..1, or null when there is no usable delta.
 */
export function cpuBusyFraction(previous, current) {
    if (!previous || !current)
        return null;
    const totalDelta = totalTicks(current) - totalTicks(previous);
    if (!(totalDelta > 0))
        return null;
    const idleDelta = idleTicks(current) - idleTicks(previous);
    return (totalDelta - idleDelta) / totalDelta;
}

/**
 * Busy fraction of a group of CPUs, from summed deltas. CPUs missing from
 * either map (offline CPUs have no line) are skipped.
 *
 * @param {Map<number, object>} previousPerCpu - Earlier per-CPU times.
 * @param {Map<number, object>} currentPerCpu - Later per-CPU times.
 * @param {number[]} cpus - CPU numbers in the group.
 * @returns {number|null} 0..1, or null when no CPU is present or nothing elapsed.
 */
export function clusterBusyFraction(previousPerCpu, currentPerCpu, cpus) {
    let totalDelta = 0;
    let idleDelta = 0;
    let presentCount = 0;
    for (const cpu of cpus) {
        const previous = previousPerCpu.get(cpu);
        const current = currentPerCpu.get(cpu);
        if (!previous || !current)
            continue;
        presentCount++;
        totalDelta += totalTicks(current) - totalTicks(previous);
        idleDelta += idleTicks(current) - idleTicks(previous);
    }
    if (presentCount === 0 || !(totalDelta > 0))
        return null;
    return (totalDelta - idleDelta) / totalDelta;
}

/**
 * Parses a kernel CPU list such as "0-3,6,8-9".
 *
 * @param {string} text - File contents.
 * @returns {number[]} CPU numbers in listed order.
 * @throws {Error} When a part is not a number or range.
 */
export function parseCpuList(text) {
    const trimmed = text.trim();
    if (trimmed === '')
        return [];
    const cpus = [];
    for (const part of trimmed.split(',')) {
        const match = /^(\d+)(?:-(\d+))?$/.exec(part.trim());
        if (!match)
            throw new Error(`unparseable CPU list part "${part}"`);
        const first = Number(match[1]);
        const last = match[2] === undefined ? first : Number(match[2]);
        for (let cpu = first; cpu <= last; cpu++)
            cpus.push(cpu);
    }
    return cpus;
}

/**
 * Splits CPUs into performance and efficiency clusters. Prefers the hybrid
 * PMU lists, then cpu_capacity (P = at least PERFORMANCE_CAPACITY_RATIO of the
 * maximum, so 1024 and 1005 stay together).
 *
 * @param {object} sources - Where cluster information may come from.
 * @param {number[]} sources.corePmuCpus - CPUs of cpu_core PMU.
 * @param {number[]} sources.atomPmuCpus - CPUs of cpu_atom PMU.
 * @param {Map<number, number>} sources.capacities - cpu_capacity per CPU.
 * @param {number} sources.cpuCount - Number of CPUs.
 * @returns {{performanceCpus: number[], efficiencyCpus: number[]}|null} Null for a single-cluster machine.
 */
export function buildClusterMap({corePmuCpus, atomPmuCpus, capacities, cpuCount}) {
    if (corePmuCpus.length > 0 && atomPmuCpus.length > 0)
        return {performanceCpus: corePmuCpus, efficiencyCpus: atomPmuCpus};
    if (capacities.size === 0)
        return null;
    const maxCapacity = Math.max(...capacities.values());
    const performanceCpus = [];
    const efficiencyCpus = [];
    for (let cpu = 0; cpu < cpuCount; cpu++) {
        const capacity = capacities.get(cpu);
        if (capacity === undefined)
            continue;
        if (capacity >= PERFORMANCE_CAPACITY_RATIO * maxCapacity)
            performanceCpus.push(cpu);
        else
            efficiencyCpus.push(cpu);
    }
    if (efficiencyCpus.length === 0)
        return null;
    return {performanceCpus, efficiencyCpus};
}
