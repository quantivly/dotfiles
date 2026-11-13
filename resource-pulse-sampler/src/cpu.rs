//! CPU arithmetic, ported from `lib/cpu.js`: busy fractions from two samples of `/proc/stat`
//! counters, the kernel CPU-list syntax, and the split into performance and efficiency cores.
//!
//! The gjs numbers are doubles throughout, so every counter becomes an `f64` before the first
//! arithmetic on it and each expression is written in the order the JavaScript writes it:
//! floating-point sums depend on that order, and a counter that went backwards gives a negative
//! delta here exactly as it does there.

use std::collections::BTreeMap;
use std::fmt;

use crate::constants::PERFORMANCE_CAPACITY_RATIO;
use crate::parsers::is_js_whitespace;
use crate::parsers::parse_all_digits;
use crate::parsers::proc::CpuTimes;

/// The highest CPU number a kernel CPU list may name. No kernel has such a CPU (it builds with
/// at most 8192); the gjs `parseCpuList` has no limit and would build a list of billions of
/// numbers for a range such as `0-4000000000`, where this refuses it.
const MAX_CPU_NUMBER_IN_LIST: u64 = 65_535;

/// A kernel CPU list that [`parse_cpu_list`] cannot read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CpuListError {
    /// A part that is neither a number nor a `first-last` range of numbers (the gjs `Error`).
    UnparseablePart(String),
    /// A part naming a CPU above [`MAX_CPU_NUMBER_IN_LIST`], which no kernel has.
    CpuNumberTooLarge(String),
}

impl fmt::Display for CpuListError {
    /// The gjs message for an unparseable part, and its own for a number out of range.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnparseablePart(part) => {
                write!(formatter, "unparseable CPU list part \"{part}\"")
            }
            Self::CpuNumberTooLarge(part) => {
                write!(
                    formatter,
                    "CPU list part \"{part}\" names a CPU above {MAX_CPU_NUMBER_IN_LIST}"
                )
            }
        }
    }
}

impl std::error::Error for CpuListError {}

/// Where cluster information may come from (the gjs `buildClusterMap` argument).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClusterMapInput {
    /// CPUs of the `cpu_core` PMU.
    pub core_pmu_cpus: Vec<u32>,
    /// CPUs of the `cpu_atom` PMU.
    pub atom_pmu_cpus: Vec<u32>,
    /// `cpu_capacity` per CPU.
    pub capacities: BTreeMap<u32, u64>,
    /// Number of CPUs.
    pub cpu_count: u32,
}

/// Which CPUs are performance cores and which efficiency cores.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClusterMap {
    /// The performance cluster, in the order the source lists it.
    pub performance_cpus: Vec<u32>,
    /// The efficiency cluster, in the order the source lists it.
    pub efficiency_cpus: Vec<u32>,
}

/// Sums the counters that make up wall-clock CPU time, as `totalTicks` does. `guest` and
/// `guest_nice` are excluded because the kernel already counts them inside `user` and `nice`.
fn total_ticks(times: &CpuTimes) -> f64 {
    times.user as f64
        + times.nice as f64
        + times.system as f64
        + times.idle as f64
        + times.iowait as f64
        + times.irq as f64
        + times.softirq as f64
        + times.steal as f64
}

/// Idle ticks: `iowait` is the CPU waiting with nothing to run, so it is idle.
fn idle_ticks(times: &CpuTimes) -> f64 {
    times.idle as f64 + times.iowait as f64
}

/// Busy fraction between two samples of one CPU line.
///
/// Parameters
/// ----------
/// previous, current
///     The earlier and the later counters; `None` when a sample is missing (the first one).
///
/// Returns
/// -------
/// `None` when a sample is missing or no ticks elapsed (or the total went backwards); otherwise
/// the fraction, which a counter that went backwards can push outside 0 to 1, as in gjs.
pub fn cpu_busy_fraction(previous: Option<&CpuTimes>, current: Option<&CpuTimes>) -> Option<f64> {
    let (previous, current) = (previous?, current?);
    let total_delta = total_ticks(current) - total_ticks(previous);
    // `!(totalDelta > 0)`: written with a comparison that is false for NaN as well.
    if total_delta.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater) {
        return None;
    }
    let idle_delta = idle_ticks(current) - idle_ticks(previous);
    Some((total_delta - idle_delta) / total_delta)
}

/// Busy fraction of a group of CPUs, from summed deltas. CPUs missing from either map (offline
/// CPUs have no line) are skipped; a CPU listed twice counts twice, as in gjs.
///
/// Returns
/// -------
/// `None` when no CPU of the group is present or nothing elapsed.
pub fn cluster_busy_fraction(
    previous: &BTreeMap<u32, CpuTimes>,
    current: &BTreeMap<u32, CpuTimes>,
    cpus: &[u32],
) -> Option<f64> {
    let mut total_delta = 0.0_f64;
    let mut idle_delta = 0.0_f64;
    let mut present_count = 0_u64;
    for cpu in cpus {
        let (Some(previous_times), Some(current_times)) = (previous.get(cpu), current.get(cpu))
        else {
            continue;
        };
        present_count += 1;
        total_delta += total_ticks(current_times) - total_ticks(previous_times);
        idle_delta += idle_ticks(current_times) - idle_ticks(previous_times);
    }
    if present_count == 0 || total_delta.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater) {
        return None;
    }
    Some((total_delta - idle_delta) / total_delta)
}

/// Reads one CPU number of a CPU list: ASCII digits only, no sign, within the kernel's range.
fn parse_cpu_number(digits: &str, whole_part: &str) -> Result<u32, CpuListError> {
    let is_digits = !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit());
    if !is_digits {
        return Err(CpuListError::UnparseablePart(whole_part.to_string()));
    }
    // All digits, so a failure to read them as a u64 means a number beyond any kernel's.
    let value = parse_all_digits(digits).filter(|&value| value <= MAX_CPU_NUMBER_IN_LIST);
    value
        .and_then(|value| u32::try_from(value).ok())
        .ok_or_else(|| CpuListError::CpuNumberTooLarge(whole_part.to_string()))
}

/// Parses a kernel CPU list such as `0-3,6,8-9`: `/^(\d+)(?:-(\d+))?$/` on each trimmed part.
///
/// Returns
/// -------
/// The CPU numbers in listed order; empty for an empty or blank text, and for a range whose
/// last number is below its first (`3-1`), as in gjs.
///
/// Errors
/// ------
/// [`CpuListError`] where the gjs function throws: a part that is not a number or a range.
pub fn parse_cpu_list(text: &str) -> Result<Vec<u32>, CpuListError> {
    let trimmed = text.trim_matches(is_js_whitespace);
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    let mut cpus = Vec::new();
    for part in trimmed.split(',') {
        let part = part.trim_matches(is_js_whitespace);
        let (first_digits, last_digits) = part.split_once('-').unwrap_or((part, part));
        let first = parse_cpu_number(first_digits, part)?;
        let last = parse_cpu_number(last_digits, part)?;
        cpus.extend(first..=last);
    }
    Ok(cpus)
}

/// Splits CPUs into performance and efficiency clusters. Prefers the hybrid PMU lists, then
/// `cpu_capacity` (performance = at least `PERFORMANCE_CAPACITY_RATIO` of the maximum, so 1024
/// and 1005 stay together).
///
/// Returns
/// -------
/// `None` for a single-cluster machine.
pub fn build_cluster_map(input: ClusterMapInput) -> Option<ClusterMap> {
    if !input.core_pmu_cpus.is_empty() && !input.atom_pmu_cpus.is_empty() {
        return Some(ClusterMap {
            performance_cpus: input.core_pmu_cpus,
            efficiency_cpus: input.atom_pmu_cpus,
        });
    }
    let max_capacity = input.capacities.values().copied().max()? as f64;
    let performance_floor = PERFORMANCE_CAPACITY_RATIO * max_capacity;
    let mut performance_cpus = Vec::new();
    let mut efficiency_cpus = Vec::new();
    for cpu in 0..input.cpu_count {
        let Some(&capacity) = input.capacities.get(&cpu) else {
            continue;
        };
        if capacity as f64 >= performance_floor {
            performance_cpus.push(cpu);
        } else {
            efficiency_cpus.push(cpu);
        }
    }
    if efficiency_cpus.is_empty() {
        return None;
    }
    Some(ClusterMap {
        performance_cpus,
        efficiency_cpus,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The tolerance the gjs rows compare fractions with.
    const CLOSE_ENOUGH: f64 = 1e-9;

    /// A `CpuTimes` with the fields these tests care about; the rest are zero.
    fn times(user: u64, system: u64, idle: u64, iowait: u64) -> CpuTimes {
        CpuTimes {
            user,
            system,
            idle,
            iowait,
            ..CpuTimes::default()
        }
    }

    /// A per-CPU map of the given lines.
    fn per_cpu(lines: &[(u32, CpuTimes)]) -> BTreeMap<u32, CpuTimes> {
        lines.iter().copied().collect()
    }

    /// A cluster-map input with no PMU lists and these capacities.
    fn capacity_input(capacities: &[(u32, u64)], cpu_count: u32) -> ClusterMapInput {
        ClusterMapInput {
            core_pmu_cpus: Vec::new(),
            atom_pmu_cpus: Vec::new(),
            capacities: capacities.iter().copied().collect(),
            cpu_count,
        }
    }

    /// Asserts a fraction is present and within [`CLOSE_ENOUGH`] of `expected`.
    fn assert_close(actual: Option<f64>, expected: f64) {
        let actual = actual.unwrap();
        assert!(
            (actual - expected).abs() < CLOSE_ENOUGH,
            "{actual} is not close to {expected}"
        );
    }

    /// The clusters of a map, or `None`.
    fn clusters(map: Option<ClusterMap>) -> Option<(Vec<u32>, Vec<u32>)> {
        map.map(|map| (map.performance_cpus, map.efficiency_cpus))
    }

    /// row: CPU busy excludes guest from the total (counting it gives 64%)
    #[test]
    fn cpu_busy_excludes_guest_from_the_total_counting_it_gives_64_percent() {
        let previous = CpuTimes {
            guest: 50,
            ..times(100, 100, 700, 100)
        };
        let current = CpuTimes {
            guest: 80,
            ..times(200, 150, 800, 100)
        };
        assert_close(cpu_busy_fraction(Some(&previous), Some(&current)), 0.6);
    }

    /// row: iowait counts as idle (counting it busy gives 67%)
    #[test]
    fn iowait_counts_as_idle_counting_it_busy_gives_67_percent() {
        let busy = cpu_busy_fraction(Some(&times(0, 0, 0, 0)), Some(&times(50, 0, 50, 50)));
        assert_close(busy, 1.0 / 3.0);
    }

    /// row: first sample is no data, not 0
    #[test]
    fn first_sample_is_no_data_not_0() {
        assert_eq!(cpu_busy_fraction(None, Some(&times(1, 1, 1, 1))), None);
        assert_eq!(cpu_busy_fraction(Some(&times(1, 1, 1, 1)), None), None);
    }

    /// row: no delta is no data, not NaN
    #[test]
    fn no_delta_is_no_data_not_nan() {
        let same = times(1, 1, 1, 1);
        assert_eq!(cpu_busy_fraction(Some(&same), Some(&same)), None);
    }

    /// Every counter of the total takes part, except `guest` and `guest_nice`: from zero to
    /// 1, 2, 3, 4, 5, 6, 7, 8, 9 and 10 in field order, 27 of 36 ticks are busy. Expected value:
    /// `cpuBusyFraction` run under gjs, 0.75.
    #[test]
    fn every_counter_but_guest_and_guest_nice_is_in_the_total() {
        let current = CpuTimes {
            user: 1,
            nice: 2,
            system: 3,
            idle: 4,
            iowait: 5,
            irq: 6,
            softirq: 7,
            steal: 8,
            guest: 9,
            guest_nice: 10,
        };
        let busy = cpu_busy_fraction(Some(&CpuTimes::default()), Some(&current));
        assert_eq!(busy, Some(0.75));
    }

    /// A total that went backwards is no data; an idle counter that outruns the total (another
    /// counter went backwards) gives a negative fraction, and one that fell gives more than 1.
    /// Expected values are `cpuBusyFraction` run under gjs: null, -1 and 2.
    #[test]
    fn counters_that_went_backwards_give_no_data_or_a_fraction_outside_0_to_1() {
        let backwards = cpu_busy_fraction(Some(&times(10, 10, 10, 0)), Some(&times(5, 5, 5, 0)));
        assert_eq!(backwards, None);
        let negative = cpu_busy_fraction(Some(&times(10, 0, 0, 0)), Some(&times(5, 0, 10, 0)));
        assert_eq!(negative, Some(-1.0));
        let above_one = cpu_busy_fraction(Some(&times(0, 0, 20, 0)), Some(&times(20, 0, 10, 0)));
        assert_eq!(above_one, Some(2.0));
    }

    /// row: a cluster uses only the CPUs present (offline CPUs have no line)
    #[test]
    fn a_cluster_uses_only_the_cpus_present_offline_cpus_have_no_line() {
        let previous = per_cpu(&[(0, times(0, 0, 0, 0)), (1, times(0, 0, 0, 0))]);
        let current = per_cpu(&[(0, times(30, 0, 70, 0)), (1, times(10, 0, 90, 0))]);
        // 40 busy of 200 total; dividing by all four listed CPUs would give 0.1.
        assert_close(
            cluster_busy_fraction(&previous, &current, &[0, 1, 2, 3]),
            0.2,
        );
    }

    /// row: a cluster sums deltas rather than averaging fractions
    #[test]
    fn a_cluster_sums_deltas_rather_than_averaging_fractions() {
        let previous = per_cpu(&[(0, times(0, 0, 0, 0)), (1, times(0, 0, 0, 0))]);
        let current = per_cpu(&[(0, times(10, 0, 0, 0)), (1, times(0, 0, 90, 0))]);
        // 10 busy of 100 total = 0.1; averaging 1.0 and 0.0 would give 0.5.
        assert_close(cluster_busy_fraction(&previous, &current, &[0, 1]), 0.1);
    }

    /// row: a cluster with no CPU present is null
    #[test]
    fn a_cluster_with_no_cpu_present_is_null() {
        let empty = BTreeMap::new();
        assert_eq!(cluster_busy_fraction(&empty, &empty, &[0, 1]), None);
    }

    /// A CPU that appears or vanishes between two samples is skipped, a CPU listed twice counts
    /// twice, and a cluster whose total went backwards is no data. Expected values are
    /// `clusterBusyFraction` run under gjs: 0.3, null and null.
    #[test]
    fn cpu_a_cpu_that_appears_or_vanishes_between_two_samples_gives_a_number_or_no_data_never_a_panic(
    ) {
        let sample_of_cpu_0 = per_cpu(&[(0, times(0, 0, 0, 0))]);
        let sample_of_cpu_1 = per_cpu(&[(1, times(30, 0, 70, 0))]);
        let later_sample_of_cpu_0 = per_cpu(&[(0, times(30, 0, 70, 0))]);
        let empty = BTreeMap::new();
        // Appeared: CPU 1 has a line only in the later sample.
        assert_eq!(
            cluster_busy_fraction(&sample_of_cpu_0, &sample_of_cpu_1, &[0, 1]),
            None
        );
        // Vanished: CPU 0 had a line only in the earlier sample.
        assert_eq!(
            cluster_busy_fraction(&sample_of_cpu_0, &sample_of_cpu_1, &[0]),
            None
        );
        assert_eq!(
            cluster_busy_fraction(&sample_of_cpu_1, &sample_of_cpu_0, &[0, 1]),
            None
        );
        // Empty on either side, and an empty list of CPUs.
        assert_eq!(
            cluster_busy_fraction(&empty, &later_sample_of_cpu_0, &[0]),
            None
        );
        assert_eq!(cluster_busy_fraction(&sample_of_cpu_0, &empty, &[0]), None);
        assert_eq!(
            cluster_busy_fraction(&sample_of_cpu_0, &later_sample_of_cpu_0, &[]),
            None
        );
        // One CPU present among absent ones still gives its own fraction, listed twice or once.
        let twice = cluster_busy_fraction(&sample_of_cpu_0, &later_sample_of_cpu_0, &[0, 0]);
        assert_eq!(twice, Some(0.3));
        let once_among_absent =
            cluster_busy_fraction(&sample_of_cpu_0, &later_sample_of_cpu_0, &[7, 0, 9]);
        assert_eq!(once_among_absent, Some(0.3));
        let backwards = per_cpu(&[(0, times(5, 0, 5, 0))]);
        let before_backwards = per_cpu(&[(0, times(10, 0, 10, 0))]);
        assert_eq!(
            cluster_busy_fraction(&before_backwards, &backwards, &[0]),
            None
        );
    }

    /// row: parseCpuList handles ranges and singles
    #[test]
    fn parse_cpu_list_handles_ranges_and_singles() {
        assert_eq!(parse_cpu_list("0-3,6,8-9\n"), Ok(vec![0, 1, 2, 3, 6, 8, 9]));
    }

    /// row: parseCpuList of an empty file is empty
    #[test]
    fn parse_cpu_list_of_an_empty_file_is_empty() {
        assert_eq!(parse_cpu_list("\n"), Ok(vec![]));
    }

    /// What the gjs `parseCpuList` returns or throws for texts at its edges, run under gjs: a
    /// reversed range is empty, a single-CPU range is one CPU, spaces around parts are trimmed,
    /// and an empty part, a sign, a letter, a hex number, a second dash and a dangling dash
    /// throw.
    #[test]
    fn parse_cpu_list_edges_match_the_gjs_function() {
        assert_eq!(parse_cpu_list("3-1"), Ok(vec![]));
        assert_eq!(parse_cpu_list("0-0"), Ok(vec![0]));
        assert_eq!(parse_cpu_list(" 0 , 1 "), Ok(vec![0, 1]));
        assert_eq!(parse_cpu_list("\u{2028}"), Ok(vec![]));
        // Each text, and the part the error names (the text itself, but for the empty parts).
        let unparseable_texts = [
            ("0,,1", ""),
            ("1-2-3", "1-2-3"),
            ("-1", "-1"),
            ("+1", "+1"),
            ("0 -1", "0 -1"),
            ("0,", ""),
            ("a", "a"),
            ("0x1", "0x1"),
            ("1-", "1-"),
        ];
        for (text, named_part) in unparseable_texts {
            assert_eq!(
                parse_cpu_list(text),
                Err(CpuListError::UnparseablePart(named_part.to_string())),
                "{text:?}"
            );
        }
    }

    /// Where Rust refuses what gjs would try: a CPU number above any kernel's. The gjs function
    /// would build a list of billions of numbers for `0-4000000000`; this is the one place the
    /// two differ, and it is an error here, never an allocation or a panic.
    #[test]
    fn parse_cpu_list_refuses_a_cpu_number_no_kernel_has() {
        for too_large in ["0-4000000000", "65536", "99999999999999999999999"] {
            assert_eq!(
                parse_cpu_list(too_large),
                Err(CpuListError::CpuNumberTooLarge(too_large.to_string())),
                "{too_large:?}"
            );
        }
        assert_eq!(parse_cpu_list("65535"), Ok(vec![65_535]));
    }

    /// row: cluster map: hybrid PMU wins
    #[test]
    fn cluster_map_hybrid_pmu_wins() {
        let input = ClusterMapInput {
            core_pmu_cpus: vec![0, 1, 2, 3],
            atom_pmu_cpus: vec![4, 5, 6, 7],
            capacities: BTreeMap::new(),
            cpu_count: 8,
        };
        assert_eq!(
            clusters(build_cluster_map(input)),
            Some((vec![0, 1, 2, 3], vec![4, 5, 6, 7]))
        );
    }

    /// row: cluster map: capacity fallback keeps 1024 and 1005 together
    #[test]
    fn cluster_map_capacity_fallback_keeps_1024_and_1005_together() {
        let capacities = [
            (0, 1024),
            (1, 1024),
            (2, 1005),
            (3, 1005),
            (4, 676),
            (5, 676),
            (6, 676),
            (7, 676),
        ];
        assert_eq!(
            clusters(build_cluster_map(capacity_input(&capacities, 8))),
            Some((vec![0, 1, 2, 3], vec![4, 5, 6, 7]))
        );
    }

    /// row: cluster map: equal capacities give a single cluster (null)
    #[test]
    fn cluster_map_equal_capacities_give_a_single_cluster_null() {
        let capacities = [(0, 1024), (1, 1024), (2, 1024), (3, 1024)];
        assert_eq!(build_cluster_map(capacity_input(&capacities, 4)), None);
    }

    /// row: cluster map: no PMU and no capacities is null
    #[test]
    fn cluster_map_no_pmu_and_no_capacities_is_null() {
        assert_eq!(build_cluster_map(capacity_input(&[], 4)), None);
    }

    /// Where the capacity fallback's edges are, expected values from `buildClusterMap` under
    /// gjs: one PMU list alone does not count; a capacity at exactly 0.9 of the maximum is a
    /// performance core (1000 and 900) and one below is not; CPUs at or past `cpu_count` and
    /// CPUs without a capacity are left out; all-zero capacities are one cluster.
    #[test]
    fn cluster_map_capacity_fallback_edges_match_the_gjs_function() {
        let core_list_alone = ClusterMapInput {
            core_pmu_cpus: vec![0, 1],
            ..capacity_input(&[(0, 10), (1, 5)], 2)
        };
        assert_eq!(
            clusters(build_cluster_map(core_list_alone)),
            Some((vec![0], vec![1]))
        );
        let at_the_ratio = capacity_input(&[(0, 1000), (1, 900), (2, 899)], 3);
        assert_eq!(
            clusters(build_cluster_map(at_the_ratio)),
            Some((vec![0, 1], vec![2]))
        );
        let count_short = capacity_input(&[(0, 10), (1, 5), (2, 5)], 2);
        assert_eq!(
            clusters(build_cluster_map(count_short)),
            Some((vec![0], vec![1]))
        );
        let count_long = capacity_input(&[(0, 10), (1, 5)], 5);
        assert_eq!(
            clusters(build_cluster_map(count_long)),
            Some((vec![0], vec![1]))
        );
        let with_a_gap = capacity_input(&[(0, 10), (2, 5)], 3);
        assert_eq!(
            clusters(build_cluster_map(with_a_gap)),
            Some((vec![0], vec![2]))
        );
        assert_eq!(
            build_cluster_map(capacity_input(&[(0, 0), (1, 0)], 2)),
            None
        );
        // 0.9 * 1005 is 904.5: 904 is below it, 905 is not.
        let below_905 = capacity_input(&[(0, 1005), (1, 904)], 2);
        assert_eq!(
            clusters(build_cluster_map(below_905)),
            Some((vec![0], vec![1]))
        );
        assert_eq!(
            build_cluster_map(capacity_input(&[(0, 1005), (1, 905)], 2)),
            None
        );
    }
}
