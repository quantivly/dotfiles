//! Where the sampler reads, relative to its fs root, and how it joins paths: as GLib's
//! `build_filenamev` joins the paths `service/sampler.js` builds, an empty segment dropped.

use std::path::{Path, PathBuf};

pub(super) const PROC_STAT_PATH: &str = "proc/stat";
pub(super) const PROC_MEMINFO_PATH: &str = "proc/meminfo";
pub(super) const PROC_SWAPS_PATH: &str = "proc/swaps";
pub(super) const PROC_SELF_STATUS_PATH: &str = "proc/self/status";
pub(super) const CPU_PRESSURE_PATH: &str = "proc/pressure/cpu";
pub(super) const MEMORY_PRESSURE_PATH: &str = "proc/pressure/memory";
pub(super) const IO_PRESSURE_PATH: &str = "proc/pressure/io";
pub(super) const BLOCK_DEVICES_PATH: &str = "sys/block";
pub(super) const CORE_PMU_CPUS_PATH: &str = "sys/devices/cpu_core/cpus";
pub(super) const ATOM_PMU_CPUS_PATH: &str = "sys/devices/cpu_atom/cpus";
pub(super) const CPU_DEVICES_PATH: &str = "sys/devices/system/cpu";
pub(super) const CGROUP_ROOT_PATH: &str = "sys/fs/cgroup";

/// A zram device's statistics file, in its `/sys/block` directory.
pub(super) const ZRAM_MM_STAT_FILE: &str = "mm_stat";
/// A CPU's capacity file, in its `cpu<N>` directory.
pub(super) const CPU_CAPACITY_FILE: &str = "cpu_capacity";
pub(super) const CGROUP_CPU_STAT_FILE: &str = "cpu.stat";
pub(super) const CGROUP_MEMORY_CURRENT_FILE: &str = "memory.current";
pub(super) const CGROUP_MEMORY_STAT_FILE: &str = "memory.stat";

/// A path relative to `base`, or `base` itself for an empty one, never with a trailing separator
/// (`joinPath(base, relativePath)`: GLib drops an empty segment, where `Path::join` would add `/`).
pub(super) fn join_under(base: &Path, relative_path: &str) -> PathBuf {
    if relative_path.is_empty() {
        base.to_path_buf()
    } else {
        base.join(relative_path)
    }
}

/// Two relative paths joined (`joinPath(parent, child)`): the child alone under the empty path,
/// which stands for the cgroup root.
pub(super) fn join_relative(parent_path: &str, child_path: &str) -> String {
    match (parent_path.is_empty(), child_path.is_empty()) {
        (true, _) => child_path.to_string(),
        (false, true) => parent_path.to_string(),
        (false, false) => format!("{parent_path}/{child_path}"),
    }
}
