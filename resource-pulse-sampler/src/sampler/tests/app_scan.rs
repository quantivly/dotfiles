//! The app scan and its ranking inputs: the deltas, the real time between scans, kernel and short
//! jobs, names and their cache, and a scan or a sample that fails.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::rc::Rc;

use super::*;
use crate::apps::{AppGroup, AppRanking, MemoryRankEntry};
use crate::cadence::ScanReason;
use crate::constants::{KERNEL_LABEL, LOG_PREFIX, SHORT_JOBS_LABEL};
use crate::quiet_panics::QuietPanics;
use crate::sampler::app_names::{group_of_cgroup, MAX_CACHED_DESKTOP_IDS};
use crate::sampler::{AppendedHistory, PressureAvg10};

const CHROME_DESKTOP_ID: &str = "com.google.Chrome.desktop";
const CHROMIUM_DESKTOP_ID: &str = "org.chromium.Chromium.desktop";
/// root-a's memory used fraction: 20,000,000 KiB of 32,000,000 KiB.
const FIXTURE_MEMORY_USED_FRACTION: f64 = 0.625;

/// A memory ranking entry.
fn memory_entry(group_key: &str, name: &str, memory_bytes: f64) -> MemoryRankEntry {
    MemoryRankEntry {
        group_key: group_key.to_string(),
        name: name.to_string(),
        memory_bytes,
    }
}

/// row: service sampler: app scans root-a → root-b rank herdr agents top for CPU (50%) and memory (15 GB)
#[test]
fn app_scans_root_a_to_root_b_rank_herdr_agents_top_for_cpu_and_memory() {
    let (top_cpu, top_memory, logged) = scan_twice("root-b");
    assert_eq!(
        (top_cpu, top_memory, logged),
        (
            Some(cpu_entry("unit:herdr-server", "herdr agents", 50.0)),
            Some(memory_entry(
                "unit:herdr-server",
                "herdr agents",
                15_000_000_000.0
            )),
            vec![]
        )
    );
}

/// row: service sampler: app CPU divides by the real time between scans, not the nominal interval
#[test]
fn app_cpu_divides_by_the_real_time_between_scans_not_the_nominal_interval() {
    // The second scan runs 12 s after the first: herdr's 6 s of CPU over 12 s × 2 CPUs is 25%.
    let mut test_sampler = SamplerSetup::at_fixture("root-a").build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(2 * APP_SCAN_SPACING_USEC);
    test_sampler.sampler.set_fs_root(fixture_root("root-b"));
    test_sampler.sampler.run_tick(1);
    let apps = test_sampler
        .sampler
        .latest_snapshot()
        .unwrap()
        .apps
        .clone()
        .unwrap();
    assert_eq!(
        apps.top_cpu,
        Some(cpu_entry("unit:herdr-server", "herdr agents", 25.0))
    );
}

/// row: service sampler: two Chrome scopes are one app (one group key, one name)
#[test]
fn two_chrome_scopes_are_one_app() {
    let groups: Vec<AppGroup> = [
        "app-com.google.Chrome-2.scope",
        "app-com.google.Chrome-3.scope",
    ]
    .iter()
    .map(|leaf_name| group_of_cgroup(&format!("{APP_SLICE}/{leaf_name}"), &mut |_| None))
    .collect();
    assert_eq!(
        (&groups[0], groups[0].group_key == groups[1].group_key),
        (
            &AppGroup {
                group_key: "app:com.google.Chrome".to_string(),
                name: "Chrome".to_string(),
            },
            true
        )
    );
}

/// row: service sampler: kernel (the root beyond its scanned parents) and short jobs (the parents beyond their leaves) each top CPU when theirs is the biggest share
#[test]
fn kernel_and_short_jobs_each_top_cpu_when_theirs_is_the_biggest_share() {
    // The parents spend 1,000,000 µs. A root delta of 3,000,000 leaves kernel 2,000,000 (50%); one of
    // 1,100,000 leaves kernel 100,000 (2.5%), and short jobs' 400,000 (10%) tops Editor's 300,000.
    let kernel_heavy = top_cpu_after_two_scans(
        &with_counters(&steady_deltas_usec(), &[(ROOT_CGROUP_KEY, 3_000_000)]),
        TwoScanOptions::default(),
    );
    let short_jobs_heavy = top_cpu_after_two_scans(
        &with_counters(&steady_deltas_usec(), &[(ROOT_CGROUP_KEY, 1_100_000)]),
        TwoScanOptions::default(),
    );
    assert_eq!(
        (
            kernel_heavy.0,
            short_jobs_heavy.0,
            kernel_heavy.1,
            short_jobs_heavy.1
        ),
        (
            Some(cpu_entry("pseudo:kernel", KERNEL_LABEL, 50.0)),
            Some(cpu_entry("pseudo:short-jobs", SHORT_JOBS_LABEL, 10.0)),
            vec![],
            vec![]
        )
    );
}

/// row: service sampler: a new leaf counts its whole usage when its parent was listed in the previous scan
#[test]
fn a_new_leaf_counts_its_whole_usage_when_its_parent_was_listed_in_the_previous_scan() {
    // Builder appears between the scans with 1,500,000 µs (37.5%); its parent's previous listing
    // proves it is new.
    let (top_cpu, _, _) = top_cpu_after_two_scans(
        &with_counters(
            &steady_deltas_usec(),
            &[
                (APP_SLICE, APP_SLICE_DELTA_WITH_BUILDER_USEC),
                (BUILDER_LEAF, BUILDER_USAGE_USEC),
                (ROOT_CGROUP_KEY, 2_600_000),
            ],
        ),
        TwoScanOptions::default(),
    );
    assert_eq!(
        top_cpu,
        Some(cpu_entry("app:org.example.Builder", "Builder", 37.5))
    );
}

/// row: service sampler: a VM's leaf under machine.slice (a top-level slice, like system.slice) is scanned and ranks under its own name, not as kernel (ruling R22)
#[test]
fn a_vm_leaf_under_machine_slice_is_scanned_and_ranks_under_its_own_name_not_as_kernel() {
    // The VM spends 1,600,000 µs (40%) and its slice nothing beyond it; the root spends 100,000 beyond
    // every parent (kernel, 2.5%). Were machine.slice not scanned, its whole Δ would read as kernel.
    let (top_cpu, logged, _) = top_cpu_after_two_scans(
        &with_counters(
            &steady_deltas_usec(),
            &[
                (MACHINE_SLICE, VM_DELTA_USEC),
                (VM_LEAF, VM_DELTA_USEC),
                (
                    ROOT_CGROUP_KEY,
                    STEADY_PARENTS_DELTA_USEC + VM_DELTA_USEC + KERNEL_ONLY_DELTA_USEC,
                ),
            ],
        ),
        TwoScanOptions {
            first_scan_counters_usec: with_counters(
                &first_scan_counters_usec(),
                &[(MACHINE_SLICE, 1_000_000), (VM_LEAF, 900_000)],
            ),
            ..TwoScanOptions::default()
        },
    );
    assert_eq!(
        (top_cpu, logged),
        (
            Some(cpu_entry(&format!("unit:{VM_NAME}"), VM_NAME, 40.0)),
            vec![]
        )
    );
}

/// row: service sampler: a slice that a `systemd-run --user --slice=` job made under user@<uid>.service is scanned like app.slice, so the job ranks under its own name, not as kernel (ruling R22)
#[test]
fn a_slice_that_a_systemd_run_job_made_under_the_user_manager_is_scanned_like_app_slice() {
    // The job spends 1,200,000 µs (30%); kernel is 100,000 (2.5%). Were build.slice not scanned,
    // kernel would be 1,300,000 µs, 32.5%.
    let (top_cpu, logged, _) = top_cpu_after_two_scans(
        &with_counters(
            &steady_deltas_usec(),
            &[
                (BUILD_SLICE, BUILD_JOB_DELTA_USEC),
                (BUILD_JOB_LEAF, BUILD_JOB_DELTA_USEC),
                (
                    ROOT_CGROUP_KEY,
                    STEADY_PARENTS_DELTA_USEC + BUILD_JOB_DELTA_USEC + KERNEL_ONLY_DELTA_USEC,
                ),
            ],
        ),
        TwoScanOptions {
            first_scan_counters_usec: with_counters(
                &first_scan_counters_usec(),
                &[(BUILD_SLICE, 1_000_000), (BUILD_JOB_LEAF, 900_000)],
            ),
            ..TwoScanOptions::default()
        },
    );
    assert_eq!(
        (top_cpu, logged),
        (
            Some(cpu_entry(
                &format!("unit:{BUILD_JOB_NAME}"),
                BUILD_JOB_NAME,
                30.0
            )),
            vec![]
        )
    );
}

/// The real lister, panicking while the flag is set: a broken port, as gjs row's lister that breaks
/// its contract (it returns no array, and the scan throws on it).
struct BreakableLister {
    is_listing_broken: Rc<Cell<bool>>,
}

impl DirectoryLister for BreakableLister {
    /// Panics while broken; lists as the real lister otherwise.
    fn subdirectory_names(&self, path: &Path) -> Result<Vec<String>, ReadFailure> {
        if self.is_listing_broken.get() {
            panic!("lister exploded");
        }
        FileSystemLister.subdirectory_names(path)
    }
}

/// row: service sampler: a scan that throws is logged, drops the ranking, and never costs the tick its sample
#[test]
fn a_scan_that_throws_is_logged_drops_the_ranking_and_never_costs_the_tick_its_sample() {
    let quiet_panics = QuietPanics::on_this_thread();
    let is_listing_broken = Rc::new(Cell::new(false));
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_lister(BreakableLister {
            is_listing_broken: Rc::clone(&is_listing_broken),
        })
        .build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    test_sampler.sampler.run_tick(1);
    let apps_before_the_failure = test_sampler.sampler.latest_snapshot().unwrap().apps.clone();
    is_listing_broken.set(true);
    let history_length_before = test_sampler.sampler.cpu_history().values().len();
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    test_sampler
        .sampler
        .run_tick(FIRST_UNWATCHED_INTERVAL_SCAN_TICK);
    // The panics this row makes on purpose are over: a failing assertion below must print its message.
    drop(quiet_panics);
    let logged = test_sampler.logged();
    assert_eq!(
        (
            apps_before_the_failure.is_some(),
            test_sampler.sampler.cpu_history().values().len() - history_length_before,
            test_sampler.sampler.latest_snapshot().unwrap().apps.clone(),
            logged.len(),
            logged[0].starts_with(&format!("{LOG_PREFIX} app scan failed: ")),
        ),
        (true, 1, None, 1, true)
    );
}

/// row: service sampler: app names are looked up once per desktop id and kept across scans, misses included
#[test]
fn app_names_are_looked_up_once_per_desktop_id_and_kept_across_scans_misses_included() {
    let look_up_counts_by_desktop_id = Rc::new(RefCell::new(HashMap::<String, u64>::new()));
    let counts = Rc::clone(&look_up_counts_by_desktop_id);
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_resolve_app_name(move |desktop_id: &str| {
            *counts
                .borrow_mut()
                .entry(desktop_id.to_string())
                .or_insert(0) += 1;
            (desktop_id == CHROME_DESKTOP_ID).then(|| "Google Chrome".to_string())
        })
        .build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(APP_SCAN_SPACING_USEC);
    test_sampler.sampler.run_tick(1);
    // Two Chrome scopes and a Chromium scope, named in both scans: one lookup per desktop id in all.
    let mut look_up_counts: Vec<(String, u64)> = look_up_counts_by_desktop_id
        .borrow()
        .clone()
        .into_iter()
        .collect();
    look_up_counts.sort();
    assert_eq!(
        look_up_counts,
        [
            (CHROME_DESKTOP_ID.to_string(), 1),
            (CHROMIUM_DESKTOP_ID.to_string(), 1)
        ]
    );
}

/// row: service sampler: a name lookup that throws is logged once, and the scan goes on with the name the unit gives
#[test]
fn a_name_lookup_that_throws_is_logged_once_and_the_scan_goes_on_with_the_name_the_unit_gives() {
    let quiet_panics = QuietPanics::on_this_thread();
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_resolve_app_name(|desktop_id: &str| {
            if desktop_id == CHROMIUM_DESKTOP_ID {
                panic!("desktop file unreadable");
            }
            None
        })
        .build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(APP_SCAN_SPACING_USEC);
    test_sampler
        .sampler
        .set_fs_root(fixture_root("root-vanished"));
    test_sampler.sampler.run_tick(1);
    // The panics this row makes on purpose are over: a failing assertion below must print its message.
    drop(quiet_panics);
    // root-vanished has no herdr, so Chromium tops memory, by the name its scope gives.
    let top_memory_name = test_sampler
        .sampler
        .latest_snapshot()
        .and_then(|snapshot| snapshot.apps.as_ref())
        .and_then(|apps| apps.top_memory.as_ref())
        .map(|entry| entry.name.clone());
    assert_eq!(
        (top_memory_name.as_deref(), test_sampler.logged()),
        (
            Some("Chromium"),
            vec![logged_line(&format!(
                "cannot look up {CHROMIUM_DESKTOP_ID}: desktop file unreadable"
            ))]
        )
    );
}

/// The real reader, panicking while the flag is set: gjs's row makes the sample throw through a
/// getter of `fsRoot` that throws.
struct BreakableReader {
    is_reading_broken: Rc<Cell<bool>>,
}

impl FileReader for BreakableReader {
    /// Panics while broken; reads as the real reader otherwise.
    fn read_to_text(&self, path: &Path) -> Result<String, ReadFailure> {
        if self.is_reading_broken.get() {
            panic!("fsRoot exploded");
        }
        FileSystemReader.read_to_text(path)
    }
}

/// row: service sampler: a throwing sample publishes an all-null, incomplete snapshot and a gap in both histories
#[test]
fn a_throwing_sample_publishes_an_all_null_incomplete_snapshot_and_a_gap_in_both_histories() {
    let quiet_panics = QuietPanics::on_this_thread();
    let clock_labels = Rc::new(RefCell::new(VecDeque::from([
        FIXTURE_CLOCK_LABEL.to_string(),
        LATER_CLOCK_LABEL.to_string(),
    ])));
    let is_reading_broken = Rc::new(Cell::new(false));
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_reader(BreakableReader {
            is_reading_broken: Rc::clone(&is_reading_broken),
        })
        .with_clock_label(Box::new(move || {
            clock_labels
                .borrow_mut()
                .pop_front()
                .ok_or_else(|| "no label left".to_string())
        }))
        .build();
    test_sampler.sampler.run_tick(0);
    // A ranking is on hand, so the no-data snapshot's apps: None is a choice, not an accident.
    let ranking = test_sampler.sampler.latest_snapshot().unwrap().apps.clone();
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    is_reading_broken.set(true);
    let publish = test_sampler.sampler.run_tick(1);
    // The panics this row makes on purpose are over: a failing assertion below must print its message.
    drop(quiet_panics);
    let logged = test_sampler.logged();
    let snapshot = &publish.snapshot;
    assert!(ranking.is_some());
    assert_eq!(
        (
            snapshot.cpu_busy_percent,
            snapshot.cpu_clusters,
            snapshot.memory,
            snapshot.swap,
            snapshot.pressure_avg10,
            snapshot.apps.clone(),
            snapshot.is_complete,
        ),
        (
            None,
            None,
            None,
            None,
            PressureAvg10::default(),
            None,
            false
        )
    );
    assert_eq!(
        (
            snapshot.taken_at_usec,
            snapshot.taken_at_clock_label.as_deref(),
            publish.appended_history,
            Some(snapshot) == test_sampler.sampler.latest_snapshot(),
        ),
        (
            Some(SAMPLE_SPACING_USEC),
            Some(LATER_CLOCK_LABEL),
            Some(AppendedHistory {
                cpu: None,
                memory: None,
            }),
            true
        )
    );
    assert_eq!(
        (
            test_sampler.sampler.cpu_history().values(),
            test_sampler.sampler.memory_history().values(),
            test_sampler.sampler.last_good_clock_label(),
            logged.len(),
            logged[0].contains("fsRoot exploded"),
        ),
        (
            vec![None, None],
            vec![Some(FIXTURE_MEMORY_USED_FRACTION), None],
            Some(FIXTURE_CLOCK_LABEL),
            1,
            true
        )
    );
}

/// How many leaves the large-tree row scans.
const LARGE_TREE_LEAF_COUNT: u64 = 5_000;
/// What a large-tree leaf spends between the scans per unit of its index plus one.
const LARGE_TREE_LEAF_DELTA_STEP_USEC: u64 = 10;
/// What a large-tree leaf holds per unit of its index plus one.
const LARGE_TREE_LEAF_MEMORY_STEP_BYTES: u64 = 1_000;
/// What the root spends beyond app.slice between the scans.
const LARGE_TREE_KERNEL_DELTA_USEC: u64 = 100;

/// A large-tree leaf's path under app.slice.
fn large_tree_leaf_path(leaf_index: u64) -> String {
    format!("{APP_SLICE}/app-org.example.App{leaf_index:04}-1.scope")
}

/// Writes a large-tree leaf's cpu.stat and memory.current.
fn write_large_tree_leaf(tree: &FakeFileTree, leaf_index: u64, usage_usec: u64) {
    let leaf_directory = cgroup_relative_path(&large_tree_leaf_path(leaf_index));
    let memory_bytes = (leaf_index + 1) * LARGE_TREE_LEAF_MEMORY_STEP_BYTES;
    tree.write_file(
        &format!("{leaf_directory}/cpu.stat"),
        &format!("usage_usec {usage_usec}\n"),
    );
    tree.write_file(
        &format!("{leaf_directory}/memory.current"),
        &format!("{memory_bytes}\n"),
    );
}

/// The large-tree name lookup: even-numbered apps have a name, odd ones are misses.
fn large_tree_app_name(desktop_id: &str) -> Option<String> {
    let index_text = desktop_id
        .strip_prefix("org.example.App")?
        .strip_suffix(".desktop")?;
    let leaf_index: u64 = index_text.parse().ok()?;
    leaf_index
        .is_multiple_of(2)
        .then(|| format!("Even App {leaf_index}"))
}

/// sampler: 5,000 leaves scan and publish ten entries, and the name cache holds at most 4,096 ids
///
/// Two scans of 5,000 app scopes under app.slice, each with its own desktop id, two seconds apart.
/// Expected values: the gjs `ServiceSampler` run through the same tree and ticks (the task's
/// `new-rows.js`, row B), which publishes the same ten entries each way; gjs's cache has no bound
/// (5,000 ids, each looked up once), this one holds at most [`MAX_CACHED_DESKTOP_IDS`].
#[test]
fn five_thousand_leaves_scan_and_publish_ten_entries_and_the_name_cache_holds_at_most_4096_ids() {
    let tree = fake_tree_with_sample_files();
    let first_app_slice_usage_usec = 1_000_000_000;
    write_cgroup_counters(
        &tree,
        &counters(&[
            (ROOT_CGROUP_KEY, 1_000_000_000),
            (APP_SLICE, first_app_slice_usage_usec),
        ]),
    );
    let mut leaf_delta_total_usec = 0;
    for leaf_index in 0..LARGE_TREE_LEAF_COUNT {
        write_large_tree_leaf(&tree, leaf_index, leaf_index * 1_000);
        leaf_delta_total_usec += (leaf_index + 1) * LARGE_TREE_LEAF_DELTA_STEP_USEC;
    }
    let mut test_sampler = SamplerSetup::on_tree(&tree)
        .with_resolve_app_name(large_tree_app_name)
        .build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    for leaf_index in 0..LARGE_TREE_LEAF_COUNT {
        let usage_usec = leaf_index * 1_000 + (leaf_index + 1) * LARGE_TREE_LEAF_DELTA_STEP_USEC;
        write_large_tree_leaf(&tree, leaf_index, usage_usec);
    }
    write_cgroup_counters(
        &tree,
        &counters(&[
            (
                ROOT_CGROUP_KEY,
                1_000_000_000 + leaf_delta_total_usec + LARGE_TREE_KERNEL_DELTA_USEC,
            ),
            (
                APP_SLICE,
                first_app_slice_usage_usec + leaf_delta_total_usec,
            ),
        ]),
    );
    test_sampler.sampler.run_tick(1);
    let apps = test_sampler
        .sampler
        .latest_snapshot()
        .unwrap()
        .apps
        .clone()
        .unwrap();
    let expected_cpu_percents = [
        1.25,
        1.24975,
        1.2494999999999998,
        1.24925,
        1.2489999999999999,
        1.24875,
        1.2485,
        1.24825,
        1.248,
        1.2477500000000001,
    ];
    let expected_name = |leaf_index: u64| {
        large_tree_app_name(&format!("org.example.App{leaf_index:04}.desktop"))
            .unwrap_or_else(|| format!("App{leaf_index:04}"))
    };
    let expected_cpu_ranking: Vec<CpuRankEntry> = (0..10)
        .zip(expected_cpu_percents)
        .map(|(rank, cpu_percent)| {
            let leaf_index = LARGE_TREE_LEAF_COUNT - 1 - rank;
            let group_key = format!("app:org.example.App{leaf_index:04}");
            cpu_entry(&group_key, &expected_name(leaf_index), cpu_percent)
        })
        .collect();
    let expected_memory_ranking: Vec<MemoryRankEntry> = (0..10)
        .map(|rank| {
            let leaf_index = LARGE_TREE_LEAF_COUNT - 1 - rank;
            let group_key = format!("app:org.example.App{leaf_index:04}");
            let memory_bytes = ((leaf_index + 1) * LARGE_TREE_LEAF_MEMORY_STEP_BYTES) as f64;
            memory_entry(&group_key, &expected_name(leaf_index), memory_bytes)
        })
        .collect();
    assert_eq!(apps.cpu_ranking, expected_cpu_ranking);
    assert_eq!(apps.memory_ranking, expected_memory_ranking);
    assert_eq!(test_sampler.logged(), Vec::<String>::new());
    let cached_desktop_id_count = test_sampler.sampler.app_names.cached_desktop_id_count();
    assert!(
        (1..=MAX_CACHED_DESKTOP_IDS).contains(&cached_desktop_id_count),
        "{cached_desktop_id_count} ids cached"
    );
}

/// sampler: a tick whose scan panics publishes no data for the ranking, logs once, and the next tick runs
///
/// root-a's first and warm-up scans, then the interval scan at tick 31 with a lister that panics:
/// that tick publishes its sample with no ranking and logs one line; tick 32 publishes as usual
/// with nothing more logged; once the lister works again the next interval scan (tick 61) starts
/// afresh, with no CPU ranking, since the failed scan dropped the baseline. Expected values: the gjs
/// `ServiceSampler` through the same ticks with a lister that breaks its contract (the task's
/// `new-rows.js`, row C).
#[test]
fn a_tick_whose_scan_panics_publishes_no_data_for_the_ranking_logs_once_and_the_next_tick_runs() {
    let quiet_panics = QuietPanics::on_this_thread();
    let is_listing_broken = Rc::new(Cell::new(false));
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_lister(BreakableLister {
            is_listing_broken: Rc::clone(&is_listing_broken),
        })
        .build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    test_sampler.sampler.run_tick(1);
    is_listing_broken.set(true);
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    let failed_scan_publish = test_sampler
        .sampler
        .run_tick(FIRST_UNWATCHED_INTERVAL_SCAN_TICK);
    // The panics this row makes on purpose are over: a failing assertion below must print its message.
    drop(quiet_panics);
    let logged_after_failure = test_sampler.logged();
    assert_eq!(
        (
            failed_scan_publish.snapshot.apps.clone(),
            logged_after_failure.len(),
            logged_after_failure[0].starts_with(&format!("{LOG_PREFIX} app scan failed: ")),
            test_sampler.sampler.last_app_scan_reason(),
        ),
        (None, 1, true, Some(ScanReason::Interval))
    );
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    let next_publish = test_sampler
        .sampler
        .run_tick(FIRST_UNWATCHED_INTERVAL_SCAN_TICK + 1);
    assert_eq!(
        (
            next_publish.snapshot.apps.clone(),
            next_publish.snapshot.is_complete,
            next_publish.appended_history,
            test_sampler.logged().len(),
        ),
        (
            None,
            true,
            Some(AppendedHistory {
                cpu: None,
                memory: Some(FIXTURE_MEMORY_USED_FRACTION),
            }),
            1
        )
    );
    is_listing_broken.set(false);
    let next_interval_scan_tick = FIRST_UNWATCHED_INTERVAL_SCAN_TICK + 30;
    for tick_number in [next_interval_scan_tick - 1, next_interval_scan_tick] {
        test_sampler.advance_clock(SAMPLE_SPACING_USEC);
        test_sampler.sampler.run_tick(tick_number);
    }
    let fresh_ranking = test_sampler.sampler.latest_snapshot().unwrap().apps.clone();
    assert_eq!(
        fresh_ranking,
        Some(AppRanking {
            top_cpu: None,
            top_memory: Some(memory_entry(
                "unit:herdr-server",
                "herdr agents",
                15_000_000_000.0
            )),
            cpu_ranking: vec![],
            memory_ranking: vec![
                memory_entry("unit:herdr-server", "herdr agents", 15_000_000_000.0),
                memory_entry("app:org.chromium.Chromium", "Chromium", 4_000_000_000.0),
                memory_entry("app:com.google.Chrome", "Chrome", 1_000_000_000.0),
                memory_entry("unit:org.gnome.Shell", "GNOME Shell", 300_000_000.0),
                memory_entry("docker:docker", "docker", 300_000_000.0),
            ],
        })
    );
    assert_eq!(
        (
            test_sampler.sampler.last_app_scan_reason(),
            test_sampler.logged().len()
        ),
        (Some(ScanReason::Interval), 1)
    );
}
