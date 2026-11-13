//! Memory and swap arithmetic, ported from `lib/memory.js`. Byte counts become `f64` before the
//! first arithmetic on them, as they are doubles in gjs, so a difference may go negative.

use std::collections::HashMap;

use crate::parsers::proc::{SwapArea, ZramMmStat};

/// What a zram swap area's file name starts with.
const ZRAM_SWAP_AREA_PREFIX: &str = "/dev/";
/// What a zram device's name starts with, before its number.
const ZRAM_DEVICE_NAME_PREFIX: &str = "zram";
/// The `/proc/meminfo` field holding all memory.
const MEM_TOTAL_FIELD: &str = "MemTotal";
/// The `/proc/meminfo` field holding the kernel's estimate of memory available to programs.
const MEM_AVAILABLE_FIELD: &str = "MemAvailable";

/// One zram device's `mm_stat`, with its `/sys/block` name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ZramDevice {
    /// The device's name in `/sys/block`, such as `zram0`.
    pub device_name: String,
    /// Uncompressed bytes stored.
    pub stored_bytes: u64,
    /// RAM the device takes.
    pub ram_bytes: u64,
}

impl ZramDevice {
    /// A device made of its name and the two fields the sampler reads of its `mm_stat`.
    pub fn from_mm_stat(device_name: String, mm_stat: ZramMmStat) -> Self {
        Self {
            device_name,
            stored_bytes: mm_stat.stored_bytes,
            ram_bytes: mm_stat.ram_bytes,
        }
    }
}

/// Memory in use and the total, in bytes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MemoryUsage {
    /// `MemTotal - MemAvailable`; negative when the kernel reports more available than total.
    pub used_bytes: f64,
    /// `MemTotal`.
    pub total_bytes: f64,
}

/// Swap in use, split between compressed zram and real disk.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SwapSummary {
    /// Swap in use on `/dev/zram*` areas.
    pub zram_used_bytes: f64,
    /// The RAM those same devices take (a zram device that is not a swap area adds nothing).
    pub zram_ram_bytes: f64,
    /// Swap in use on every other area.
    pub disk_bytes: f64,
}

/// Names the zram devices that are swap areas, as `/sys/block` names them.
///
/// Returns
/// -------
/// For example `["zram0"]`, in `/proc/swaps` order, a repeated area repeated; empty without zram
/// swap.
pub fn zram_swap_device_names(swap_areas: &[SwapArea]) -> Vec<String> {
    swap_areas
        .iter()
        .filter_map(|swap_area| zram_device_name(&swap_area.filename))
        .map(str::to_string)
        .collect()
}

/// The `/sys/block` name of a `/proc/swaps` file name that is exactly `/dev/zram<digits>`
/// (`/^\/dev\/(zram\d+)$/`, which has no `m` flag, so `$` is the end of the text and a trailing
/// newline does not match), `None` for any other file name.
fn zram_device_name(filename: &str) -> Option<&str> {
    let device_name = filename.strip_prefix(ZRAM_SWAP_AREA_PREFIX)?;
    let digits = device_name.strip_prefix(ZRAM_DEVICE_NAME_PREFIX)?;
    let has_only_ascii_digits = !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit());
    has_only_ascii_digits.then_some(device_name)
}

/// Memory in use, as the kernel's own estimate: `MemTotal - MemAvailable`.
///
/// Returns
/// -------
/// `None` when either field is missing.
pub fn memory_usage(meminfo: &HashMap<String, u64>) -> Option<MemoryUsage> {
    let total_bytes = *meminfo.get(MEM_TOTAL_FIELD)? as f64;
    let available_bytes = *meminfo.get(MEM_AVAILABLE_FIELD)? as f64;
    Some(MemoryUsage {
        used_bytes: total_bytes - available_bytes,
        total_bytes,
    })
}

/// Swap in use, split between compressed zram and real disk, from each swap area's own `Used`.
/// zram's share is never derived from its `orig_data_size`: that leaves out same-filled pages
/// and slot use, so it under-counts zram and turned the difference into swap "on disk" that did
/// not exist.
pub fn swap_summary(swap_areas: &[SwapArea], zram_devices: &[ZramDevice]) -> SwapSummary {
    let mut zram_used_bytes = 0.0_f64;
    let mut disk_bytes = 0.0_f64;
    for swap_area in swap_areas {
        match zram_device_name(&swap_area.filename) {
            Some(_) => zram_used_bytes += swap_area.used_bytes as f64,
            None => disk_bytes += swap_area.used_bytes as f64,
        }
    }
    let swap_device_names = zram_swap_device_names(swap_areas);
    let zram_ram_bytes = zram_devices
        .iter()
        .filter(|zram_device| swap_device_names.contains(&zram_device.device_name))
        .fold(0.0_f64, |sum, zram_device| {
            sum + zram_device.ram_bytes as f64
        });
    SwapSummary {
        zram_used_bytes,
        zram_ram_bytes,
        disk_bytes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KIB: u64 = 1024;
    const GIB: u64 = 1024 * 1024 * 1024;

    /// A `/proc/swaps` row as `parse_proc_swaps` returns it.
    fn swap_area(filename: &str, used_bytes: u64) -> SwapArea {
        SwapArea {
            filename: filename.to_string(),
            used_bytes,
        }
    }

    /// A zram device with the given RAM cost.
    fn zram_device(device_name: &str, stored_bytes: u64, ram_bytes: u64) -> ZramDevice {
        ZramDevice {
            device_name: device_name.to_string(),
            stored_bytes,
            ram_bytes,
        }
    }

    /// A summary of three whole numbers of bytes.
    fn summary(zram_used: u64, zram_ram: u64, disk: u64) -> SwapSummary {
        SwapSummary {
            zram_used_bytes: zram_used as f64,
            zram_ram_bytes: zram_ram as f64,
            disk_bytes: disk as f64,
        }
    }

    /// A meminfo map of the given fields.
    fn meminfo_of(fields: &[(&str, u64)]) -> HashMap<String, u64> {
        fields
            .iter()
            .map(|(name, value)| (name.to_string(), *value))
            .collect()
    }

    /// row: memory used = MemTotal - MemAvailable, not MemTotal - MemFree
    #[test]
    fn memory_used_is_mem_total_minus_mem_available_not_mem_free() {
        let meminfo = meminfo_of(&[
            ("MemTotal", 32_000_000 * KIB),
            ("MemFree", 1_000_000 * KIB),
            ("MemAvailable", 12_000_000 * KIB),
        ]);
        let usage = memory_usage(&meminfo).unwrap();
        assert_eq!(usage.used_bytes, (20_000_000 * KIB) as f64);
    }

    /// row: memory without MemAvailable is no data
    #[test]
    fn memory_without_mem_available_is_no_data() {
        let meminfo = meminfo_of(&[("MemTotal", 1), ("MemFree", 1)]);
        assert_eq!(memory_usage(&meminfo), None);
    }

    /// No total is no data either; a total of zero is data; more available than total is a
    /// negative use, as in gjs (`memoryUsage` run under gjs gives -20 for 10 and 30), and a
    /// total above 2^53 is rounded to the nearest double exactly as the gjs number is.
    #[test]
    fn memory_usage_at_the_edges() {
        assert_eq!(memory_usage(&meminfo_of(&[("MemAvailable", 1)])), None);
        let zero = memory_usage(&meminfo_of(&[("MemTotal", 0), ("MemAvailable", 0)])).unwrap();
        assert_eq!((zero.used_bytes, zero.total_bytes), (0.0, 0.0));
        let negative =
            memory_usage(&meminfo_of(&[("MemTotal", 10), ("MemAvailable", 30)])).unwrap();
        assert_eq!((negative.used_bytes, negative.total_bytes), (-20.0, 10.0));
        let huge = memory_usage(&meminfo_of(&[
            ("MemTotal", u64::MAX),
            ("MemAvailable", 9_007_199_254_740_993),
        ]))
        .unwrap();
        assert_eq!(huge.used_bytes, 18_437_736_874_454_810_000.0);
        assert_eq!(huge.total_bytes, 18_446_744_073_709_552_000.0);
    }

    /// row: swap: zram's share is the Used of its /dev/zram* areas, so an idle disk area is no disk swap
    #[test]
    fn swap_zram_share_is_the_used_of_its_dev_zram_areas_so_an_idle_disk_area_is_no_disk_swap() {
        // The gjs row uses 1.6, 1.4 and 0.4 GiB, fractional bytes; the parsers return whole ones.
        // Expected values: `swapSummary` run under gjs on these same whole-byte inputs.
        let zram_used = 1_717_986_918;
        let zram_stored = 1_503_238_553;
        let zram_ram = 429_496_729;
        let areas = [
            swap_area("/swap.img", 0),
            swap_area("/dev/zram0", zram_used),
        ];
        let devices = [zram_device("zram0", zram_stored, zram_ram)];
        assert_eq!(
            swap_summary(&areas, &devices),
            summary(zram_used, zram_ram, 0)
        );
    }

    /// row: swap on disk is the Used of every area that is not zram, summed
    #[test]
    fn swap_on_disk_is_the_used_of_every_area_that_is_not_zram_summed() {
        // Expected values: `swapSummary` run under gjs on these same inputs.
        let areas = [
            swap_area("/swap.img", GIB / 2),
            swap_area("/dev/zram0", GIB),
            swap_area("/dev/nvme0n1p3", GIB / 4),
        ];
        let devices = [zram_device("zram0", GIB, GIB / 4)];
        assert_eq!(
            swap_summary(&areas, &devices),
            summary(GIB, GIB / 4, GIB / 4 * 3)
        );
    }

    /// row: swap: a zram device that is not a swap area (no /proc/swaps row) adds nothing to "in RAM"
    #[test]
    fn swap_a_zram_device_that_is_not_a_swap_area_adds_nothing_to_in_ram() {
        // Expected values: `swapSummary` run under gjs on these same inputs.
        let areas = [swap_area("/dev/zram0", GIB)];
        let devices = [
            zram_device("zram0", GIB, GIB / 4),
            zram_device("zram1", 2 * GIB, GIB / 2),
        ];
        assert_eq!(swap_summary(&areas, &devices), summary(GIB, GIB / 4, 0));
    }

    /// row: swap: no zram swap area puts everything on disk; no area at all is nothing used
    #[test]
    fn swap_no_zram_swap_area_puts_everything_on_disk_no_area_at_all_is_nothing_used() {
        // Expected values: `swapSummary` run under gjs on these same inputs.
        assert_eq!(
            swap_summary(&[swap_area("/swap.img", GIB)], &[]),
            summary(0, 0, GIB)
        );
        assert_eq!(swap_summary(&[], &[]), summary(0, 0, 0));
    }

    /// A repeated swap area is summed twice and a repeated device counts twice, as in gjs, and
    /// a sum past 2^53 rounds as a double sum does. Expected values are `swapSummary` under gjs.
    #[test]
    fn swap_summary_sums_repeats_and_rounds_like_doubles() {
        let areas = [
            swap_area("/dev/zram0", 5),
            swap_area("/dev/zram0", 7),
            swap_area("/x", 3),
        ];
        let devices = [
            zram_device("zram0", 0, 2),
            zram_device("zram0", 0, 4),
            zram_device("zram9", 0, 100),
        ];
        assert_eq!(swap_summary(&areas, &devices), summary(12, 6, 3));
        let past_two_to_the_53 = [
            swap_area("/a", 9_007_199_254_740_993),
            swap_area("/b", 1),
            swap_area("/c", 1),
        ];
        assert_eq!(
            swap_summary(&past_two_to_the_53, &[]).disk_bytes,
            9_007_199_254_740_992.0
        );
    }

    /// Only `/dev/zram<digits>` exactly is a zram swap area: not a bare `/dev/zram`, a trailing
    /// newline, a letter, a trailing letter, a missing leading slash, or a non-ASCII digit.
    /// Names keep `/proc/swaps` order and repeats. Expected values are `zramSwapDeviceNames`
    /// under gjs.
    #[test]
    fn zram_swap_device_names_takes_only_exact_zram_areas_in_order() {
        let filenames = [
            "/dev/zram0",
            "/swap.img",
            "/dev/zram10",
            "/dev/zram0",
            "/dev/zram",
            "/dev/zram0\n",
            "/dev/zramX",
            "/dev/zram1x",
            "dev/zram2",
            "/dev/zram\u{663}",
        ];
        let areas: Vec<SwapArea> = filenames.iter().map(|name| swap_area(name, 1)).collect();
        assert_eq!(
            zram_swap_device_names(&areas),
            vec!["zram0", "zram10", "zram0"]
        );
        assert_eq!(zram_swap_device_names(&[]), Vec::<String>::new());
    }
}
