//! Reading the cgroups an app scan lists (`_readCgroupUsageUsec`, `_readParentUsage`,
//! `_readCgroupLeaves`, `readCgroupLeaf`): `usage_usec` of the root and of each parent, and each
//! leaf's CPU and memory net of page cache.

use std::path::Path;

use super::cgroup_tree::CgroupReadFailures;
use super::paths::{
    join_relative, join_under, CGROUP_CPU_STAT_FILE, CGROUP_MEMORY_CURRENT_FILE,
    CGROUP_MEMORY_STAT_FILE,
};
use super::Sampler;
use crate::constants::APP_MEMORY_STAT_MIN_BYTES;
use crate::insertion_ordered_map::InsertionOrderedMap;
use crate::parsers::cgroup::{
    parse_cpu_stat_usage_usec, parse_memory_stat_reclaimable_bytes, parse_single_number,
};
use crate::ports::FileReader;

/// What a parent's or the root's `cpu.stat` failure reads as when it parses to nothing.
const NO_USAGE_USEC_LINE_TEXT: &str = "no usage_usec line";

/// Every leaf a scan read, in the order listed.
pub(super) struct LeafReadings {
    pub(super) usage_usec_by_cgroup: InsertionOrderedMap<u64>,
    /// Memory net of page cache.
    pub(super) memory_bytes_by_cgroup: InsertionOrderedMap<u64>,
    /// The leaves that exist but could not be read.
    pub(super) unread_leaf_paths: Vec<String>,
}

/// One leaf's readings.
struct LeafReading {
    usage_usec: u64,
    memory_bytes: u64,
}

/// Why a leaf could not be read.
enum LeafReadFailure {
    /// Its cgroup is gone: skipped silently.
    Vanished,
    /// Anything else, with the text gjs logs for it: counted, and the leaf is unread.
    Counted(String),
}

/// A file of a leaf read and parsed; a failed read is vanished or counted, an unparseable file
/// counted as `cannot parse <path>`.
fn read_leaf_file<Parsed>(
    reader: &dyn FileReader,
    path: &Path,
    parse: impl FnOnce(&str) -> Option<Parsed>,
) -> Result<Parsed, LeafReadFailure> {
    let text = reader.read_to_text(path).map_err(|failure| {
        if failure.is_vanished() {
            LeafReadFailure::Vanished
        } else {
            LeafReadFailure::Counted(failure.file_failure_text(path))
        }
    })?;
    parse(&text).ok_or_else(|| LeafReadFailure::Counted(format!("cannot parse {}", path.display())))
}

/// One leaf's CPU usage and its memory net of page cache. `memory.stat` is read only when
/// `memory.current` exceeds `APP_MEMORY_STAT_MIN_BYTES`; a smaller leaf is ranked uncorrected.
///
/// The memory net of page cache is gjs's `Math.max(0, current - reclaimable)`, here a `u64`
/// `saturating_sub` that the ranking converts to `f64`. The two agree for every count below 2^53
/// bytes (8 PiB): gjs's doubles hold such counts exactly, so its subtraction is exact, a negative
/// difference becomes 0 in both, and an exact difference converts to the same double.
fn read_cgroup_leaf(
    reader: &dyn FileReader,
    leaf_path: &Path,
) -> Result<LeafReading, LeafReadFailure> {
    let usage_usec = read_leaf_file(
        reader,
        &leaf_path.join(CGROUP_CPU_STAT_FILE),
        parse_cpu_stat_usage_usec,
    )?;
    let memory_current_bytes = read_leaf_file(
        reader,
        &leaf_path.join(CGROUP_MEMORY_CURRENT_FILE),
        parse_single_number,
    )?;
    if memory_current_bytes <= APP_MEMORY_STAT_MIN_BYTES {
        return Ok(LeafReading {
            usage_usec,
            memory_bytes: memory_current_bytes,
        });
    }
    let reclaimable_bytes = read_leaf_file(
        reader,
        &leaf_path.join(CGROUP_MEMORY_STAT_FILE),
        parse_memory_stat_reclaimable_bytes,
    )?;
    Ok(LeafReading {
        usage_usec,
        memory_bytes: memory_current_bytes.saturating_sub(reclaimable_bytes),
    })
}

impl Sampler {
    /// One cgroup's `usage_usec`. A vanished cgroup is silent; any other failure is counted.
    pub(super) fn read_cgroup_usage_usec(
        &self,
        cgroup_root_path: &Path,
        cgroup_relative_path: &str,
        failures: &mut CgroupReadFailures,
    ) -> Option<u64> {
        let cpu_stat_relative_path = join_relative(cgroup_relative_path, CGROUP_CPU_STAT_FILE);
        let cpu_stat_path = join_under(cgroup_root_path, &cpu_stat_relative_path);
        let cpu_stat_text = match self.reader.read_to_text(&cpu_stat_path) {
            Ok(cpu_stat_text) => cpu_stat_text,
            Err(failure) => {
                if !failure.is_vanished() {
                    failures.note(
                        &cpu_stat_relative_path,
                        failure.file_failure_text(&cpu_stat_path),
                    );
                }
                return None;
            }
        };
        let usage_usec = parse_cpu_stat_usage_usec(&cpu_stat_text);
        if usage_usec.is_none() {
            failures.note(&cpu_stat_relative_path, NO_USAGE_USEC_LINE_TEXT.to_string());
        }
        usage_usec
    }

    /// Each scanned parent's `usage_usec`, in the parents' order; a parent that could not be read is
    /// absent.
    pub(super) fn read_parent_usage(
        &self,
        cgroup_root_path: &Path,
        parent_relative_paths: &[String],
        failures: &mut CgroupReadFailures,
    ) -> InsertionOrderedMap<u64> {
        let mut usage_usec_by_parent_path = InsertionOrderedMap::new();
        for parent_relative_path in parent_relative_paths {
            if let Some(usage_usec) =
                self.read_cgroup_usage_usec(cgroup_root_path, parent_relative_path, failures)
            {
                usage_usec_by_parent_path.insert(parent_relative_path, usage_usec);
            }
        }
        usage_usec_by_parent_path
    }

    /// Reads every leaf. A leaf with any failed read is skipped from both rankings: silently when its
    /// cgroup vanished between listing and reading, counted (and returned as unread) otherwise.
    pub(super) fn read_cgroup_leaves(
        &self,
        cgroup_root_path: &Path,
        leaf_relative_paths: &[String],
        failures: &mut CgroupReadFailures,
    ) -> LeafReadings {
        let mut leaf_readings = LeafReadings {
            usage_usec_by_cgroup: InsertionOrderedMap::new(),
            memory_bytes_by_cgroup: InsertionOrderedMap::new(),
            unread_leaf_paths: Vec::new(),
        };
        for leaf_relative_path in leaf_relative_paths {
            let leaf_path = join_under(cgroup_root_path, leaf_relative_path);
            match read_cgroup_leaf(self.reader.as_ref(), &leaf_path) {
                Ok(leaf_reading) => {
                    leaf_readings
                        .usage_usec_by_cgroup
                        .insert(leaf_relative_path, leaf_reading.usage_usec);
                    leaf_readings
                        .memory_bytes_by_cgroup
                        .insert(leaf_relative_path, leaf_reading.memory_bytes);
                }
                Err(LeafReadFailure::Vanished) => {}
                Err(LeafReadFailure::Counted(failure_text)) => {
                    failures.note(leaf_relative_path, failure_text);
                    leaf_readings
                        .unread_leaf_paths
                        .push(leaf_relative_path.clone());
                }
            }
        }
        leaf_readings
    }
}
