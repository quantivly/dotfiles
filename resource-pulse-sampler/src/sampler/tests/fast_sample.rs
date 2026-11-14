//! The fast sample: CPU, the clusters, memory, swap, pressure, the histories and the clock label.

use std::cell::{Cell, RefCell};
use std::path::Path;
use std::rc::Rc;

use super::*;
use crate::constants::{CARD_HISTORY_SAMPLES, ERROR_LOG_REPEAT_INTERVAL_USEC, LOG_PREFIX};
use crate::memory::{MemoryUsage, SwapSummary};
use crate::sampler::{AppendedHistory, ClusterPercents, PressureAvg10};

const BYTES_PER_KIB: f64 = 1024.0;
const FIXTURE_MEMORY_USED_KIB: f64 = 20_000_000.0;
/// root-a's memory used fraction: 20,000,000 KiB of 32,000,000 KiB.
const FIXTURE_MEMORY_USED_FRACTION: f64 = 0.625;
/// root-a's /dev/zram0 Used (1,600,000 KiB), above its orig_data_size of 1,536,000,000 B; /swap.img
/// Used is 0.
const FIXTURE_ZRAM_SWAP_USED_BYTES: f64 = 1_600_000.0 * BYTES_PER_KIB;
const FIXTURE_ZRAM_RAM_BYTES: f64 = 400_000_000.0;
/// root-swap-disk's zram0 mm_stat mem_used_total: the only zram device its /proc/swaps lists.
const SWAP_DISK_ZRAM0_RAM_BYTES: f64 = 209_715_200.0;
const BLOCK_DEVICES_SUFFIX: &str = "/sys/block";

/// Ticks root-a and then root-b, two seconds apart (gjs `tickRootAThenRootB`); the second publish.
fn tick_root_a_then_root_b(test_sampler: &mut TestSampler) -> Vec<Publish> {
    test_sampler.sampler.set_fs_root(fixture_root("root-a"));
    let first = test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    test_sampler.sampler.set_fs_root(fixture_root("root-b"));
    let second = test_sampler.sampler.run_tick(1);
    vec![first, second]
}

/// row: service sampler: root-a then root-b gives CPU 60% with P 80 and E 40, complete
#[test]
fn root_a_then_root_b_gives_cpu_60_with_p_80_and_e_40_complete() {
    let mut test_sampler = SamplerSetup::at_fixture("root-a").build();
    test_sampler.sampler.initialize();
    tick_root_a_then_root_b(&mut test_sampler);
    let snapshot = test_sampler.sampler.latest_snapshot().unwrap();
    // The history holds fractions, and the first sample is a gap (None), never 0.
    assert_eq!(snapshot.cpu_busy_percent, Some(60.0));
    assert_eq!(
        snapshot.cpu_clusters,
        Some(ClusterPercents {
            performance_percent: Some(80.0),
            efficiency_percent: Some(40.0),
        })
    );
    assert!(snapshot.is_complete);
    assert_eq!(
        test_sampler.sampler.cpu_history().values(),
        [None, Some(0.6)]
    );
}

/// row: service sampler: the first tick is no data for CPU, never 0%, while memory is present
#[test]
fn the_first_tick_is_no_data_for_cpu_never_0_while_memory_is_present() {
    let mut test_sampler = SamplerSetup::at_fixture("root-a").build();
    test_sampler.sampler.initialize();
    let label_before = test_sampler
        .sampler
        .last_good_clock_label()
        .map(str::to_string);
    test_sampler.sampler.run_tick(0);
    let snapshot = test_sampler.sampler.latest_snapshot().unwrap();
    assert_eq!(
        (
            snapshot.cpu_busy_percent,
            snapshot.cpu_clusters,
            snapshot.memory.is_some(),
            snapshot.is_complete,
            label_before,
            test_sampler.sampler.last_good_clock_label(),
        ),
        (None, None, true, true, None, Some(FIXTURE_CLOCK_LABEL))
    );
}

/// row: service sampler: memory used is MemTotal − MemAvailable in bytes, and its history is the used fraction
#[test]
fn memory_used_is_memtotal_minus_memavailable_in_bytes_and_its_history_is_the_used_fraction() {
    let mut test_sampler = SamplerSetup::at_fixture("root-a").build();
    test_sampler.sampler.run_tick(0);
    assert_eq!(
        test_sampler.sampler.latest_snapshot().unwrap().memory,
        Some(MemoryUsage {
            used_bytes: FIXTURE_MEMORY_USED_KIB * BYTES_PER_KIB,
            total_bytes: 32_768_000_000.0,
        })
    );
    assert_eq!(
        test_sampler.sampler.memory_history().values(),
        [Some(FIXTURE_MEMORY_USED_FRACTION)]
    );
}

/// row: service sampler: swap comes from /proc/swaps, so zram holding more swap than orig_data_size shows no disk swap
///
/// The gjs row also checks the card's text, `1.5 GiB (0.4 in RAM)`, which `lib/format.js` writes in
/// the shell from these same three numbers; the sampler publishes the numbers only.
#[test]
fn swap_comes_from_proc_swaps_so_zram_holding_more_swap_than_orig_data_size_shows_no_disk_swap() {
    let mut test_sampler = SamplerSetup::at_fixture("root-a").build();
    test_sampler.sampler.run_tick(0);
    assert_eq!(
        test_sampler.sampler.latest_snapshot().unwrap().swap,
        Some(SwapSummary {
            zram_used_bytes: FIXTURE_ZRAM_SWAP_USED_BYTES,
            zram_ram_bytes: FIXTURE_ZRAM_RAM_BYTES,
            disk_bytes: 0.0,
        })
    );
}

/// row: service sampler: swap on disk is real disk Used, and a zram device that is not swap (zram1) adds no "in RAM"
///
/// root-swap-disk: /dev/zram0 1 GiB used with 200 MiB of RAM, /swap.img 0.5 GiB used, and a zram1
/// that is not in /proc/swaps whose 300 MiB of RAM must not count. The gjs row's card text
/// (`1.0 GiB (0.2 in RAM) + 0.5 on disk`) is the shell's, from these numbers.
#[test]
fn swap_on_disk_is_real_disk_used_and_a_zram_device_that_is_not_swap_adds_no_in_ram() {
    let mut test_sampler = SamplerSetup::at_fixture("root-swap-disk").build();
    test_sampler.sampler.run_tick(0);
    assert_eq!(
        test_sampler.sampler.latest_snapshot().unwrap().swap,
        Some(SwapSummary {
            zram_used_bytes: 1_048_576.0 * BYTES_PER_KIB,
            zram_ram_bytes: SWAP_DISK_ZRAM0_RAM_BYTES,
            disk_bytes: 524_288.0 * BYTES_PER_KIB,
        })
    );
}

/// The real reader, recording each path read under `/sys/block/`, relative to the fs root.
struct BlockDeviceRecordingReader {
    fs_root: PathBuf,
    block_device_paths_read: Rc<RefCell<Vec<String>>>,
}

impl FileReader for BlockDeviceRecordingReader {
    fn read_to_text(&self, path: &Path) -> Result<String, ReadFailure> {
        if path
            .to_string_lossy()
            .contains(&format!("{BLOCK_DEVICES_SUFFIX}/"))
        {
            let relative_path = path.strip_prefix(&self.fs_root).unwrap();
            self.block_device_paths_read
                .borrow_mut()
                .push(relative_path.display().to_string());
        }
        FileSystemReader.read_to_text(path)
    }
}

/// The real lister, refusing and recording every listing of `/sys/block`.
struct BlockDeviceRefusingLister {
    block_device_listings: Rc<RefCell<Vec<PathBuf>>>,
}

impl DirectoryLister for BlockDeviceRefusingLister {
    fn subdirectory_names(&self, path: &Path) -> Result<Vec<String>, ReadFailure> {
        if path.to_string_lossy().ends_with(BLOCK_DEVICES_SUFFIX) {
            self.block_device_listings
                .borrow_mut()
                .push(path.to_path_buf());
            return Err(ReadFailure::Other(
                "the fast tick must not list /sys/block".to_string(),
            ));
        }
        FileSystemLister.subdirectory_names(path)
    }
}

/// row: service sampler: only the zram devices /proc/swaps lists are read, and /sys/block is never listed
#[test]
fn only_the_zram_devices_proc_swaps_lists_are_read_and_sys_block_is_never_listed() {
    let block_device_paths_read = Rc::new(RefCell::new(Vec::new()));
    let block_device_listings = Rc::new(RefCell::new(Vec::new()));
    let mut test_sampler = SamplerSetup::at_fixture("root-swap-disk")
        .with_reader(BlockDeviceRecordingReader {
            fs_root: fixture_root("root-swap-disk"),
            block_device_paths_read: Rc::clone(&block_device_paths_read),
        })
        .with_lister(BlockDeviceRefusingLister {
            block_device_listings: Rc::clone(&block_device_listings),
        })
        .build();
    test_sampler.sampler.run_tick(0);
    let zram_ram_bytes = test_sampler
        .sampler
        .latest_snapshot()
        .unwrap()
        .swap
        .map(|swap| swap.zram_ram_bytes);
    assert_eq!(
        *block_device_paths_read.borrow(),
        ["sys/block/zram0/mm_stat"]
    );
    assert_eq!(*block_device_listings.borrow(), Vec::<PathBuf>::new());
    assert_eq!(zram_ram_bytes, Some(SWAP_DISK_ZRAM0_RAM_BYTES));
}

/// row: service sampler: an unreadable /proc/swaps is swap no data (logged), while memory stays
///
/// The gjs row's card text for it, `no data`, is the shell's, from the null swap.
#[test]
fn an_unreadable_proc_swaps_is_swap_no_data_logged_while_memory_stays() {
    let mut test_sampler = SamplerSetup::at_fixture("root-no-swaps").build();
    test_sampler.sampler.run_tick(0);
    let snapshot = test_sampler.sampler.latest_snapshot().unwrap();
    assert_eq!(
        (
            snapshot.swap,
            snapshot.memory.is_some(),
            snapshot.is_complete,
            test_sampler
                .logged()
                .iter()
                .any(|line| line.contains("proc/swaps")),
        ),
        (None, true, false, true)
    );
}

/// row: service sampler: PSI cpu some avg10 is 12.5, memory and io 0
#[test]
fn psi_cpu_some_avg10_is_12_5_memory_and_io_0() {
    let mut test_sampler = SamplerSetup::at_fixture("root-a").build();
    test_sampler.sampler.run_tick(0);
    assert_eq!(
        test_sampler
            .sampler
            .latest_snapshot()
            .unwrap()
            .pressure_avg10,
        PressureAvg10 {
            cpu: Some(12.5),
            memory: Some(0.0),
            io: Some(0.0),
        }
    );
}

/// row: service sampler: without /proc/pressure every pressure is null, memory stays, the sample is incomplete
#[test]
fn without_proc_pressure_every_pressure_is_null_memory_stays_the_sample_is_incomplete() {
    let mut test_sampler = SamplerSetup::at_fixture("root-no-psi").build();
    test_sampler.sampler.run_tick(0);
    let snapshot = test_sampler.sampler.latest_snapshot().unwrap();
    assert_eq!(
        (
            snapshot.pressure_avg10,
            snapshot.memory.is_some(),
            snapshot.is_complete
        ),
        (PressureAvg10::default(), true, false)
    );
}

/// row: service sampler: a missing /proc/stat nulls CPU and logs once per 10 minutes, prefixed
#[test]
fn a_missing_proc_stat_nulls_cpu_and_logs_once_per_10_minutes_prefixed() {
    let mut test_sampler = SamplerSetup::at_fixture("root-a").build();
    test_sampler.sampler.initialize();
    test_sampler
        .sampler
        .set_fs_root(fixture_root("root-no-stat"));
    test_sampler.sampler.run_tick(0);
    let snapshot = test_sampler.sampler.latest_snapshot().unwrap().clone();
    let logged_after_first = test_sampler.logged().len();
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    test_sampler.sampler.run_tick(1);
    let logged_inside_interval = test_sampler.logged().len();
    test_sampler
        .now_usec
        .set(ERROR_LOG_REPEAT_INTERVAL_USEC + 1);
    test_sampler.sampler.run_tick(2);
    let logged = test_sampler.logged();
    assert_eq!(
        (
            snapshot.cpu_busy_percent,
            snapshot.is_complete,
            logged_after_first,
            logged_inside_interval,
            logged.len(),
            logged
                .iter()
                .all(|line| line.starts_with(&format!("{LOG_PREFIX} "))),
        ),
        (None, false, 1, 1, 2, true)
    );
}

/// row: service sampler: a tick whose clock label throws publishes no label, and "no data since" keeps the last good one
#[test]
fn a_tick_whose_clock_label_throws_publishes_no_label_and_no_data_since_keeps_the_last_good_one() {
    let is_clock_broken = Rc::new(Cell::new(false));
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_clock_label(breakable_clock_label(&is_clock_broken))
        .build();
    test_sampler.sampler.run_tick(0);
    is_clock_broken.set(true);
    test_sampler.sampler.run_tick(1);
    let snapshot = test_sampler.sampler.latest_snapshot().unwrap();
    assert_eq!(
        (
            snapshot.taken_at_clock_label.as_deref(),
            snapshot.is_complete,
            snapshot.memory,
            test_sampler.sampler.last_good_clock_label(),
        ),
        (None, false, None, Some(FIXTURE_CLOCK_LABEL))
    );
}

/// row: service sampler: each history keeps the newest CARD_HISTORY_SAMPLES fast ticks, a gap included
#[test]
fn each_history_keeps_the_newest_card_history_samples_fast_ticks_a_gap_included() {
    let is_clock_broken = Rc::new(Cell::new(true));
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_clock_label(breakable_clock_label(&is_clock_broken))
        .build();
    test_sampler.sampler.run_tick(0);
    let histories_after_gap = (
        test_sampler.sampler.cpu_history().values(),
        test_sampler.sampler.memory_history().values(),
    );
    is_clock_broken.set(false);
    run_ticks(&mut test_sampler, 1..=CARD_HISTORY_SAMPLES);
    let memory_values = test_sampler.sampler.memory_history().values();
    let history_length = usize::try_from(CARD_HISTORY_SAMPLES).unwrap();
    assert_eq!(histories_after_gap, (vec![None], vec![None]));
    assert_eq!(
        (
            test_sampler.sampler.cpu_history().values().len(),
            memory_values.len(),
            memory_values
                .iter()
                .all(|value| *value == Some(FIXTURE_MEMORY_USED_FRACTION)),
        ),
        (history_length, history_length, true)
    );
}

/// row: service sampler: a fast tick hands listeners the history values it appended
#[test]
fn a_fast_tick_hands_listeners_the_history_values_it_appended() {
    let mut test_sampler = SamplerSetup::at_fixture("root-a").build();
    test_sampler.sampler.initialize();
    let publishes = tick_root_a_then_root_b(&mut test_sampler);
    let appended_histories: Vec<Option<AppendedHistory>> = publishes
        .iter()
        .map(|publish| publish.appended_history)
        .collect();
    // root-b holds as much memory as root-a.
    assert_eq!(
        appended_histories,
        [
            Some(AppendedHistory {
                cpu: None,
                memory: Some(FIXTURE_MEMORY_USED_FRACTION),
            }),
            Some(AppendedHistory {
                cpu: Some(0.6),
                memory: Some(FIXTURE_MEMORY_USED_FRACTION),
            }),
        ]
    );
}

/// row: service sampler: an unparseable PMU list falls back to cpu_capacity and is logged, not thrown
#[test]
fn an_unparseable_pmu_list_falls_back_to_cpu_capacity_and_is_logged_not_thrown() {
    let mut test_sampler = SamplerSetup::at_fixture("root-bad-pmu").build();
    test_sampler.sampler.initialize();
    tick_root_a_then_root_b(&mut test_sampler);
    let logged = test_sampler.logged();
    assert_eq!(
        (
            test_sampler.sampler.latest_snapshot().unwrap().cpu_clusters,
            logged.len(),
            logged[0].starts_with(LOG_PREFIX),
            logged[0].contains("cpu_core/cpus"),
        ),
        (
            Some(ClusterPercents {
                performance_percent: Some(80.0),
                efficiency_percent: Some(40.0),
            }),
            1,
            true,
            true,
        )
    );
}
