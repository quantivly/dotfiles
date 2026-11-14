//! The fast sample (`_takeFastSample` and the readers it calls): `/proc/stat`, `meminfo`, `swaps`,
//! the zram devices `swaps` lists and the three pressure files, worked into every snapshot field but
//! the apps. Everything that can fail (the clock label included) runs here, before any state other
//! than the rate-limited log changes.

use std::collections::HashMap;
use std::path::Path;

use super::paths::{
    join_under, BLOCK_DEVICES_PATH, CPU_PRESSURE_PATH, IO_PRESSURE_PATH, MEMORY_PRESSURE_PATH,
    PROC_MEMINFO_PATH, PROC_STAT_PATH, PROC_SWAPS_PATH, ZRAM_MM_STAT_FILE,
};
use super::snapshot::{ClusterPercents, PressureAvg10, Snapshot};
use super::Sampler;
use crate::cpu::{cluster_busy_fraction, cpu_busy_fraction};
use crate::memory::{
    memory_usage, swap_summary, zram_swap_device_names, MemoryUsage, SwapSummary, ZramDevice,
};
use crate::parsers::proc::{
    parse_meminfo, parse_pressure_some_avg10, parse_proc_stat, parse_proc_swaps,
    parse_zram_mm_stat, ProcStat, SwapArea,
};

/// The percentage a whole fraction is.
const PERCENT_SCALE: f64 = 100.0;

/// A fast sample: the snapshot without apps, and the `/proc/stat` reading to keep as the next CPU
/// baseline.
pub(super) struct FastSample {
    pub(super) snapshot_without_apps: Snapshot,
    pub(super) proc_stat: Option<ProcStat>,
}

/// The parts the fast tick's files give.
struct FastTickParts {
    proc_stat: Option<ProcStat>,
    memory: Option<MemoryUsage>,
    swap: Option<SwapSummary>,
    pressure_avg10: PressureAvg10,
}

/// `parseUsableProcStat`: `/proc/stat` parsed, `None` without an aggregate `cpu` line.
pub(super) fn parse_usable_proc_stat(text: &str) -> Option<ProcStat> {
    let proc_stat = parse_proc_stat(text);
    proc_stat.aggregate.is_some().then_some(proc_stat)
}

/// `Math.min(1, Math.max(0, fraction))`: a NaN stays NaN and -0 becomes +0, as in JavaScript, where
/// `f64::clamp` would keep -0.
fn clamp_to_unit_interval_as_javascript(fraction: f64) -> f64 {
    if fraction.is_nan() {
        return fraction;
    }
    if fraction > 1.0 {
        1.0
    } else if fraction > 0.0 {
        fraction
    } else {
        0.0
    }
}

/// A busy fraction as a percentage, clamped to 0 to 100 (`fractionToPercent`): `/proc/stat`'s iowait
/// can step backwards, which can push a raw fraction just outside 0 to 1.
fn fraction_to_percent(fraction: Option<f64>) -> Option<f64> {
    fraction.map(|fraction| clamp_to_unit_interval_as_javascript(fraction) * PERCENT_SCALE)
}

impl Sampler {
    /// Reads the fast tick's files and works out every snapshot field but the apps.
    ///
    /// Returns
    /// -------
    /// The sample, or the text of what failed: only the clock label can fail without a panic.
    pub(super) fn take_fast_sample(&mut self) -> Result<FastSample, String> {
        let taken_at_usec = self.clock.monotonic_usec();
        let parts = self.read_fast_tick_files();
        let cpu_busy_percent = match (&self.previous_proc_stat, &parts.proc_stat) {
            (Some(previous_proc_stat), Some(proc_stat)) => fraction_to_percent(cpu_busy_fraction(
                previous_proc_stat.aggregate.as_ref(),
                proc_stat.aggregate.as_ref(),
            )),
            _ => None,
        };
        let taken_at_clock_label = self.clock.clock_label()?;
        let cpu_clusters = match (cpu_busy_percent, &self.previous_proc_stat, &parts.proc_stat) {
            (Some(_), Some(previous_proc_stat), Some(proc_stat)) => {
                self.cluster_percents(previous_proc_stat, proc_stat)
            }
            _ => None,
        };
        let pressure = parts.pressure_avg10;
        let is_complete = parts.proc_stat.is_some()
            && parts.memory.is_some()
            && parts.swap.is_some()
            && pressure.cpu.is_some()
            && pressure.memory.is_some()
            && pressure.io.is_some();
        let snapshot_without_apps = Snapshot {
            taken_at_usec: Some(taken_at_usec),
            taken_at_clock_label: Some(taken_at_clock_label),
            cpu_busy_percent,
            cpu_clusters,
            memory: parts.memory,
            swap: parts.swap,
            pressure_avg10: pressure,
            apps: None,
            is_complete,
        };
        Ok(FastSample {
            snapshot_without_apps,
            proc_stat: parts.proc_stat,
        })
    }

    /// Reads and parses `/proc/stat`, `meminfo`, `swaps`, the three pressure files and the `mm_stat`
    /// of each zram device that `swaps` lists, in that order. Any failed read or parse is logged and
    /// gives its part no data.
    fn read_fast_tick_files(&mut self) -> FastTickParts {
        let fs_root = self.fs_root.clone();
        let meminfo_path = join_under(&fs_root, PROC_MEMINFO_PATH);
        let proc_stat = self.read_and_parse(
            &join_under(&fs_root, PROC_STAT_PATH),
            parse_usable_proc_stat,
        );
        let meminfo = self.read_and_parse(&meminfo_path, |text| Some(parse_meminfo(text)));
        let swap_areas =
            self.read_and_parse(&join_under(&fs_root, PROC_SWAPS_PATH), parse_proc_swaps);
        let zram_devices = match &swap_areas {
            Some(swap_areas) => self.read_zram_swap_devices(&fs_root, swap_areas),
            None => None,
        };
        let pressure_avg10 = PressureAvg10 {
            cpu: self.read_and_parse(
                &join_under(&fs_root, CPU_PRESSURE_PATH),
                parse_pressure_some_avg10,
            ),
            memory: self.read_and_parse(
                &join_under(&fs_root, MEMORY_PRESSURE_PATH),
                parse_pressure_some_avg10,
            ),
            io: self.read_and_parse(
                &join_under(&fs_root, IO_PRESSURE_PATH),
                parse_pressure_some_avg10,
            ),
        };
        let memory = meminfo.and_then(|meminfo| self.memory_usage_or_log(&meminfo, &meminfo_path));
        let swap = match (&swap_areas, &zram_devices) {
            (Some(swap_areas), Some(zram_devices)) => Some(swap_summary(swap_areas, zram_devices)),
            _ => None,
        };
        FastTickParts {
            proc_stat,
            memory,
            swap,
            pressure_avg10,
        }
    }

    /// Memory in use from a parsed `meminfo`, logging when it lacks `MemTotal` or `MemAvailable`
    /// (`_requirePart`).
    fn memory_usage_or_log(
        &mut self,
        meminfo: &HashMap<String, u64>,
        meminfo_path: &Path,
    ) -> Option<MemoryUsage> {
        let memory = memory_usage(meminfo);
        if memory.is_none() {
            let path_text = meminfo_path.display();
            self.log_once_per_interval(&format!(
                "cannot find MemTotal and MemAvailable in {path_text}"
            ));
        }
        memory
    }

    /// The `mm_stat` of each zram device that is a swap area, by the name `/proc/swaps` gives it;
    /// `/sys/block` is never listed. Empty without zram swap; `None` when any device could not be
    /// read or parsed (logged), the devices after it unread.
    fn read_zram_swap_devices(
        &mut self,
        fs_root: &Path,
        swap_areas: &[SwapArea],
    ) -> Option<Vec<ZramDevice>> {
        let mut zram_devices = Vec::new();
        for device_name in zram_swap_device_names(swap_areas) {
            let mm_stat_path = join_under(fs_root, BLOCK_DEVICES_PATH)
                .join(&device_name)
                .join(ZRAM_MM_STAT_FILE);
            let mm_stat = self.read_and_parse(&mm_stat_path, parse_zram_mm_stat)?;
            zram_devices.push(ZramDevice::from_mm_stat(device_name, mm_stat));
        }
        Some(zram_devices)
    }

    /// Busy percent of each core type between two `/proc/stat` readings; `None` on a single-cluster
    /// machine.
    fn cluster_percents(
        &self,
        previous_proc_stat: &ProcStat,
        proc_stat: &ProcStat,
    ) -> Option<ClusterPercents> {
        let cluster_map = self.cluster_map.as_ref()?;
        let busy_percent_of = |cpus: &[u32]| {
            fraction_to_percent(cluster_busy_fraction(
                &previous_proc_stat.per_cpu,
                &proc_stat.per_cpu,
                cpus,
            ))
        };
        Some(ClusterPercents {
            performance_percent: busy_percent_of(&cluster_map.performance_cpus),
            efficiency_percent: busy_percent_of(&cluster_map.efficiency_cpus),
        })
    }
}
