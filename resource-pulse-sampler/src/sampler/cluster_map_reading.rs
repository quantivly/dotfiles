//! Which CPUs are performance and which efficiency cores, read once at `initialize`: the hybrid PMU
//! lists, else each CPU's `cpu_capacity` (`_readClusterMap` and the readers it calls).

use std::collections::BTreeMap;
use std::path::Path;

use super::paths::{
    join_under, ATOM_PMU_CPUS_PATH, CORE_PMU_CPUS_PATH, CPU_CAPACITY_FILE, CPU_DEVICES_PATH,
};
use super::Sampler;
use crate::cpu::{
    build_cluster_map, parse_cpu_list, ClusterMap, ClusterMapInput, MAX_CPU_NUMBER_IN_LIST,
};
use crate::parsers::cgroup::parse_single_number;
use crate::parsers::{is_ascii_digit_run, parse_all_digits};
use crate::ports::ReadFailure;

/// What a CPU's device directory is called before its number (`/^cpu(\d+)$/`).
const CPU_DEVICE_NAME_PREFIX: &str = "cpu";

/// The CPU number of a `cpu<N>` device directory: `N` when the rest of the name is ASCII digits and
/// `N` is at most [`MAX_CPU_NUMBER_IN_LIST`], as a CPU list's numbers are. `None` for any other name,
/// and for a number above the bound, which no kernel has: the gjs sampler would take such a number,
/// and `build_cluster_map` would then walk every CPU number below it.
fn cpu_number_of_device_name(device_name: &str) -> Option<u32> {
    let digits = device_name.strip_prefix(CPU_DEVICE_NAME_PREFIX)?;
    if !is_ascii_digit_run(digits) {
        return None;
    }
    let cpu_number = parse_all_digits(digits).filter(|&number| number <= MAX_CPU_NUMBER_IN_LIST)?;
    u32::try_from(cpu_number).ok()
}

impl Sampler {
    /// The cluster map: the hybrid PMU lists when both name CPUs, else `cpu_capacity`. `None` for a
    /// single-cluster machine.
    pub(super) fn read_cluster_map(&mut self, fs_root: &Path) -> Option<ClusterMap> {
        let core_pmu_cpus = self.read_pmu_cpu_list(&join_under(fs_root, CORE_PMU_CPUS_PATH));
        let atom_pmu_cpus = self.read_pmu_cpu_list(&join_under(fs_root, ATOM_PMU_CPUS_PATH));
        let has_hybrid_pmu = !core_pmu_cpus.is_empty() && !atom_pmu_cpus.is_empty();
        let capacities = if has_hybrid_pmu {
            BTreeMap::new()
        } else {
            self.read_cpu_capacities(fs_root)
        };
        // The capacity fallback walks CPUs 0..cpu_count-1, so cpu_count is one past the highest CPU
        // with a capacity. The highest is at most MAX_CPU_NUMBER_IN_LIST, so the addition cannot
        // overflow; were it to, no CPU is walked.
        let highest_cpu_number = capacities.keys().next_back().copied();
        let cpu_count = highest_cpu_number
            .and_then(|cpu_number| cpu_number.checked_add(1))
            .unwrap_or(0);
        build_cluster_map(ClusterMapInput {
            core_pmu_cpus,
            atom_pmu_cpus,
            capacities,
            cpu_count,
        })
    }

    /// A PMU CPU list. A missing list is normal (no hybrid cores); an unreadable or malformed one is
    /// logged. Either way it counts as empty, so the caller falls back to `cpu_capacity`.
    fn read_pmu_cpu_list(&mut self, path: &Path) -> Vec<u32> {
        let cpu_list_text = match self.reader.read_to_text(path) {
            Ok(cpu_list_text) => cpu_list_text,
            Err(ReadFailure::NotFound) => return Vec::new(),
            Err(failure) => {
                self.log_read_failure(path, &failure);
                return Vec::new();
            }
        };
        parse_cpu_list(&cpu_list_text).unwrap_or_else(|cpu_list_error| {
            let path_text = path.display();
            self.log_rate_limited(
                &format!("cannot parse {path_text}: {cpu_list_error}"),
                &format!("cannot parse {path_text}"),
            );
            Vec::new()
        })
    }

    /// Each CPU's `cpu_capacity`, by CPU number. A CPU without one is normal (most non-hybrid machines
    /// have none). Empty when the CPU devices cannot be listed, which is logged.
    fn read_cpu_capacities(&mut self, fs_root: &Path) -> BTreeMap<u32, u64> {
        let cpu_devices_path = join_under(fs_root, CPU_DEVICES_PATH);
        let device_names = match self.lister.subdirectory_names(&cpu_devices_path) {
            Ok(device_names) => device_names,
            Err(failure) => {
                let path_text = cpu_devices_path.display();
                let failure_text = failure.directory_failure_text(&cpu_devices_path);
                self.log_rate_limited(
                    &format!("cannot list {path_text}: {failure_text}"),
                    &format!("cannot list {path_text}"),
                );
                return BTreeMap::new();
            }
        };
        let mut capacities = BTreeMap::new();
        for device_name in device_names {
            let Some(cpu_number) = cpu_number_of_device_name(&device_name) else {
                continue;
            };
            let capacity_path = cpu_devices_path.join(&device_name).join(CPU_CAPACITY_FILE);
            if let Some(capacity) = self.read_cpu_capacity(&capacity_path) {
                capacities.insert(cpu_number, capacity);
            }
        }
        capacities
    }

    /// One CPU's `cpu_capacity`. A missing file is normal; an unreadable or malformed one is logged.
    fn read_cpu_capacity(&mut self, capacity_path: &Path) -> Option<u64> {
        match self.reader.read_to_text(capacity_path) {
            Ok(capacity_text) => {
                self.parse_or_log(&capacity_text, capacity_path, parse_single_number)
            }
            Err(ReadFailure::NotFound) => None,
            Err(failure) => {
                self.log_read_failure(capacity_path, &failure);
                None
            }
        }
    }
}
