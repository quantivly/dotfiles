//! The cgroup tree: which parents and leaves a scan finds, in what order, and what it does when a
//! listing or a read fails or finds a cgroup gone.

use super::*;
use crate::apps::{AppRanking, MemoryRankEntry};
use crate::constants::{ERROR_LOG_REPEAT_INTERVAL_USEC, KERNEL_LABEL, SHORT_JOBS_LABEL};

const HERDR_LEAF_NAME: &str = "herdr-server.service";
const DOCKER_LEAF_NAME: &str = "docker-abc.scope";
/// Generated leaves whose cpu.stat cannot be read: far more than one journal line each could be
/// allowed.
const FAILING_LEAF_COUNT: usize = 109;

/// A memory ranking entry.
fn memory_entry(group_key: &str, name: &str, memory_bytes: f64) -> MemoryRankEntry {
    MemoryRankEntry {
        group_key: group_key.to_string(),
        name: name.to_string(),
        memory_bytes,
    }
}

/// The real reader, except that a path with a given ending fails as given.
struct FailingEndingsReader {
    failure_by_path_ending: Vec<(String, ReadFailure)>,
}

impl FileReader for FailingEndingsReader {
    /// The failure set for the path's ending, else the real reader's text.
    fn read_to_text(&self, path: &Path) -> Result<String, ReadFailure> {
        let path_text = path.to_string_lossy();
        for (path_ending, failure) in &self.failure_by_path_ending {
            if path_text.ends_with(path_ending.as_str()) {
                return Err(failure.clone());
            }
        }
        FileSystemReader.read_to_text(path)
    }
}

/// row: service sampler: the app scan skips units that never host an app (.mount, .socket), at both depths
#[test]
fn the_app_scan_skips_units_that_never_host_an_app_at_both_depths() {
    // boot.mount (5 MB, in system.slice) and example.socket (9 MB, in a sub-slice) would each top
    // memory if scanned.
    let mut test_sampler = SamplerSetup::at_fixture("root-unit-types").build();
    test_sampler.sampler.run_tick(0);
    let apps = test_sampler
        .sampler
        .latest_snapshot()
        .unwrap()
        .apps
        .clone()
        .unwrap();
    assert_eq!(
        apps.top_memory,
        Some(memory_entry(
            "unit:example-daemon",
            "example-daemon",
            1_000_000.0
        ))
    );
}

/// row: service sampler: a cgroup that vanished mid-scan is skipped in both rankings and the scan succeeds
#[test]
fn a_cgroup_that_vanished_mid_scan_is_skipped_in_both_rankings_and_the_scan_succeeds() {
    // The fixtures carry no parent cpu.stat, so neither kernel nor short jobs is ranked and Chromium
    // tops CPU too. Memory names real apps only: Chromium's 4.0 GB tops Chrome 2×0.5, GNOME Shell 0.3
    // and docker 0.3. Had herdr been kept, it would top both rankings.
    let (top_cpu, top_memory, logged) = scan_twice("root-vanished");
    assert_eq!(
        (top_cpu, top_memory, logged),
        (
            Some(cpu_entry(
                "app:org.chromium.Chromium",
                "Chromium",
                16.666666666666664
            )),
            Some(memory_entry(
                "app:org.chromium.Chromium",
                "Chromium",
                4_000_000_000.0
            )),
            vec![]
        )
    );
}

/// row: service sampler: a leaf whose file is gone with ENODEV (a scope that exited mid-read) is skipped silently, like ENOENT; any other read error is logged
#[test]
fn a_leaf_whose_file_is_gone_with_enodev_is_skipped_silently_like_enoent_any_other_read_error_is_logged(
) {
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_reader(FailingEndingsReader {
            failure_by_path_ending: vec![
                (
                    format!("{HERDR_LEAF_NAME}/memory.current"),
                    ReadFailure::NoSuchDevice,
                ),
                (
                    format!("{DOCKER_LEAF_NAME}/cpu.stat"),
                    ReadFailure::Other(FILE_DENIED_TEXT.to_string()),
                ),
            ],
        })
        .build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    // Without herdr's 15 GB, Chromium's 4 GB tops memory.
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
                "cannot read 1 cgroups, first: {SYSTEM_SLICE}/{DOCKER_LEAF_NAME}: {FILE_DENIED_TEXT}"
            ))]
        )
    );
}

/// row: service sampler: a leaf inside a sub-slice is found, and at or under 64 MiB it is uncorrected
#[test]
fn a_leaf_inside_a_sub_slice_is_found_and_at_or_under_64_mib_it_is_uncorrected() {
    // The leaf sits in system.slice/system-example.slice/, so a scan that does not descend into a
    // sub-slice finds nothing. Its memory.stat says all 1,000,000 bytes are page cache; reading it
    // would rank it at 0 bytes.
    let mut test_sampler = SamplerSetup::at_fixture("root-small-leaf").build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    let apps = test_sampler
        .sampler
        .latest_snapshot()
        .unwrap()
        .apps
        .clone()
        .unwrap();
    assert_eq!(
        apps.top_memory,
        Some(memory_entry(
            "unit:example-tool",
            "example-tool",
            1_000_000.0
        ))
    );
}

/// row: service sampler: the app scan reads cpu.stat of the root, of app, session and background slices under user@<uid>.service and of system.slice, and of each leaf
#[test]
fn the_app_scan_reads_cpu_stat_of_the_root_of_the_scanned_parents_and_of_each_leaf() {
    let tree = fake_tree_with_sample_files();
    write_cgroup_counters(&tree, &first_scan_counters_usec());
    let mut test_sampler = SamplerSetup::on_tree(&tree).build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    let cgroup_root = Path::new(FAKE_ROOT_PATH).join(CGROUP_ROOT_RELATIVE_PATH);
    let mut cpu_stat_paths_read: Vec<String> = tree
        .read_paths()
        .iter()
        .filter(|path| path.ends_with("cpu.stat"))
        .filter_map(|path| path.strip_prefix(&cgroup_root).ok())
        .map(|relative_path| relative_path.display().to_string())
        .collect();
    cpu_stat_paths_read.sort();
    let mut expected_cpu_stat_paths: Vec<String> = first_scan_counters_usec()
        .keys()
        .map(|cgroup_path| super::super::paths::join_relative(cgroup_path, "cpu.stat"))
        .collect();
    expected_cpu_stat_paths.sort();
    assert_eq!(cpu_stat_paths_read, expected_cpu_stat_paths);
}

const DEMO_DAEMON_LEAF_NAME: &str = "snap.demo.daemon.service";
const DEMO_GUI_LEAF_NAME: &str = "snap.demo.gui-11111111-2222-3333-4444-555555555555.scope";
const DEMO_GROUP_KEY: &str = "snap:demo";
const DEMO_GUI_DESKTOP_ID: &str = "demo_gui.desktop";
const DEMO_APP_NAME: &str = "Demo";
const DEMO_UNIT_NAME: &str = "demo";

/// Counters for leaves under app.slice, each at 0, with the root and app.slice.
fn app_slice_leaf_counters(leaf_names: &[&str]) -> CounterSet {
    let mut usage_usec_by_cgroup = counters(&[(ROOT_CGROUP_KEY, 0), (APP_SLICE, 0)]);
    for leaf_name in leaf_names {
        usage_usec_by_cgroup.insert(format!("{APP_SLICE}/{leaf_name}"), 0);
    }
    usage_usec_by_cgroup
}

/// Scans an in-memory tree under app.slice twice, two seconds apart, with app.slice listing its
/// children in the given order, and returns the memory ranking's entry for a group (gjs
/// `memoryEntryOfGroupAfterTwoScans`).
fn memory_entry_of_group_after_two_scans(
    leaf_names: &[&str],
    group_key: &str,
    resolve_app_name: impl FnMut(&str) -> Option<String> + 'static,
) -> Option<MemoryRankEntry> {
    let tree = fake_tree_with_sample_files();
    write_cgroup_counters(&tree, &app_slice_leaf_counters(leaf_names));
    let mut test_sampler = SamplerSetup::on_tree(&tree)
        .with_lister(ListingChildrenInOrder::new(&tree, APP_SLICE, leaf_names))
        .with_resolve_app_name(resolve_app_name)
        .build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    test_sampler.sampler.run_tick(1);
    let apps = test_sampler
        .sampler
        .latest_snapshot()
        .unwrap()
        .apps
        .clone()
        .unwrap();
    apps.memory_ranking
        .into_iter()
        .find(|entry| entry.group_key == group_key)
}

/// row: service sampler: app scan: a group takes the name of its first leaf in name order, whatever order the directory lists them in
#[test]
fn a_group_takes_the_name_of_its_first_leaf_in_name_order_whatever_order_the_directory_lists_them_in(
) {
    // The daemon leaf has no desktop id, so it is named 'demo'; the gui scope resolves to 'Demo'.
    // Name order puts the daemon first, so the group is 'demo' however the directory lists them.
    let resolve_app_name =
        |desktop_id: &str| (desktop_id == DEMO_GUI_DESKTOP_ID).then(|| DEMO_APP_NAME.to_string());
    let leaves_in_name_order = [DEMO_DAEMON_LEAF_NAME, DEMO_GUI_LEAF_NAME];
    let leaves_in_reverse_order = [DEMO_GUI_LEAF_NAME, DEMO_DAEMON_LEAF_NAME];
    let names_by_listing_order: Vec<Option<String>> =
        [&leaves_in_name_order, &leaves_in_reverse_order]
            .iter()
            .map(|leaf_names| {
                memory_entry_of_group_after_two_scans(
                    &leaf_names[..],
                    DEMO_GROUP_KEY,
                    resolve_app_name,
                )
                .map(|entry| entry.name)
            })
            .collect();
    assert_eq!(
        names_by_listing_order,
        [
            Some(DEMO_UNIT_NAME.to_string()),
            Some(DEMO_UNIT_NAME.to_string())
        ]
    );
}

/// row: service sampler: app scan: name order is JavaScript default string order
#[test]
fn name_order_is_javascript_default_string_order() {
    // Default order compares UTF-16 code units: uppercase before '_' before lowercase.
    let leaf_names_in_listing_order = ["a.service", "B.service", "_c.service"];
    let tree = fake_tree_with_sample_files();
    write_cgroup_counters(
        &tree,
        &app_slice_leaf_counters(&leaf_names_in_listing_order),
    );
    let mut test_sampler = SamplerSetup::on_tree(&tree)
        .with_lister(ListingChildrenInOrder::new(
            &tree,
            APP_SLICE,
            &leaf_names_in_listing_order,
        ))
        .build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    let app_slice_path = Path::new(FAKE_ROOT_PATH)
        .join(CGROUP_ROOT_RELATIVE_PATH)
        .join(APP_SLICE);
    let leaf_names_in_read_order: Vec<String> = tree
        .read_paths()
        .iter()
        .filter(|path| path.to_string_lossy().ends_with(".service/cpu.stat"))
        .filter_map(|path| path.strip_prefix(&app_slice_path).ok())
        .filter_map(|relative_path| relative_path.components().next())
        .map(|component| component.as_os_str().to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        leaf_names_in_read_order,
        ["B.service", "_c.service", "a.service"]
    );
}

/// row: service sampler: a new leaf whose parent could not be listed in the previous scan is skipped, so its CPU is counted as short jobs, and the failed listing is logged
#[test]
fn a_new_leaf_whose_parent_could_not_be_listed_in_the_previous_scan_is_skipped_so_its_cpu_is_counted_as_short_jobs(
) {
    // Editor and Builder are both unlisted in the first scan, so neither can prove itself new:
    // app.slice's whole 1,900,000 µs, plus the other parents' 300,000 beyond their leaves, is short
    // jobs (2,200,000 of 4,000,000).
    let app_slice_directory = cgroup_relative_path(APP_SLICE);
    let cleared_directory = app_slice_directory.clone();
    let (top_cpu, logged, _) = top_cpu_after_two_scans(
        &with_counters(
            &steady_deltas_usec(),
            &[
                (APP_SLICE, APP_SLICE_DELTA_WITH_BUILDER_USEC),
                (BUILDER_LEAF, BUILDER_USAGE_USEC),
                (ROOT_CGROUP_KEY, 2_600_000),
            ],
        ),
        TwoScanOptions {
            before_first_scan: Box::new(move |tree| {
                tree.fail_with(
                    &app_slice_directory,
                    ReadFailure::Other(DIRECTORY_DENIED_TEXT.to_string()),
                )
            }),
            before_second_scan: Box::new(move |tree| tree.clear_failure(&cleared_directory)),
            ..TwoScanOptions::default()
        },
    );
    let top_cpu = top_cpu.unwrap();
    assert_eq!(
        (top_cpu.name.as_str(), top_cpu.cpu_percent, logged),
        (
            SHORT_JOBS_LABEL,
            2_200_000.0 / 4_000_000.0 * 100.0,
            vec![logged_line(&format!(
                "cannot read 1 cgroups, first: {APP_SLICE}: {DIRECTORY_DENIED_TEXT}"
            ))]
        )
    );
}

/// row: service sampler: a scan in which a parent cannot be listed ranks neither kernel nor short jobs
#[test]
fn a_scan_in_which_a_parent_cannot_be_listed_ranks_neither_kernel_nor_short_jobs() {
    // Its leaves are unknown, so its whole delta would read as short jobs (here 700,000 µs, 17.5%)
    // and top the ranking. Withheld, GNOME Shell's 200,000 (5%) tops it.
    let (top_cpu, _, _) = top_cpu_after_two_scans(
        &with_counters(&steady_deltas_usec(), &[(ROOT_CGROUP_KEY, 1_100_000)]),
        TwoScanOptions {
            before_second_scan: Box::new(|tree| {
                tree.fail_with(
                    &cgroup_relative_path(APP_SLICE),
                    ReadFailure::Other(DIRECTORY_DENIED_TEXT.to_string()),
                )
            }),
            ..TwoScanOptions::default()
        },
    );
    assert_eq!(
        top_cpu,
        Some(cpu_entry("unit:org.gnome.Shell", "GNOME Shell", 5.0))
    );
}

/// row: service sampler: a scanned parent that does not exist (systemd removes an empty slice) counts as listed, so kernel and short jobs still rank
#[test]
fn a_scanned_parent_that_does_not_exist_counts_as_listed_so_kernel_and_short_jobs_still_rank() {
    // No background.slice in either scan: the other parents spend 900,000 µs, so kernel is 2,100,000
    // of 4,000,000.
    let (top_cpu, logged, _) = top_cpu_after_two_scans(
        &with_counters(
            &without_cgroup(&steady_deltas_usec(), BACKGROUND_SLICE),
            &[(ROOT_CGROUP_KEY, 3_000_000)],
        ),
        TwoScanOptions {
            first_scan_counters_usec: without_cgroup(&first_scan_counters_usec(), BACKGROUND_SLICE),
            ..TwoScanOptions::default()
        },
    );
    assert_eq!(
        (top_cpu, logged),
        (
            Some(cpu_entry(
                "pseudo:kernel",
                KERNEL_LABEL,
                2_100_000.0 / 4_000_000.0 * 100.0
            )),
            vec![]
        )
    );
}

/// row: service sampler: user.slice and user-<uid>.slice are never scanned parents: neither cpu.stat is read, and kernel is the root beyond the slices under them, never beyond those twice (ruling R22)
#[test]
fn user_slice_and_user_uid_slice_are_never_scanned_parents() {
    // As on a real machine, user.slice and user-1000.slice carry the Δ of everything under them: the
    // user slices' 700,000 µs and a login session's 50,000. Kernel is 3,000,000 − the parents'
    // 1,000,000: 50%.
    let (top_cpu, logged, scanned_tree) = top_cpu_after_two_scans(
        &with_counters(
            &steady_deltas_usec(),
            &[
                (USER_SLICE, USER_SLICE_DELTA_USEC),
                (USER_1000_SLICE, USER_SLICE_DELTA_USEC),
                (ROOT_CGROUP_KEY, 3_000_000),
            ],
        ),
        TwoScanOptions {
            first_scan_counters_usec: with_counters(
                &first_scan_counters_usec(),
                &[(USER_SLICE, 5_000_000), (USER_1000_SLICE, 5_000_000)],
            ),
            ..TwoScanOptions::default()
        },
    );
    let user_slice_cpu_stat_reads: Vec<PathBuf> = scanned_tree
        .read_paths()
        .into_iter()
        .filter(|path| {
            [USER_SLICE, USER_1000_SLICE].iter().any(|slice_path| {
                path.to_string_lossy()
                    .ends_with(&format!("/{slice_path}/cpu.stat"))
            })
        })
        .collect();
    assert_eq!(
        (top_cpu, user_slice_cpu_stat_reads, logged),
        (
            Some(cpu_entry("pseudo:kernel", KERNEL_LABEL, 50.0)),
            vec![],
            vec![]
        )
    );
}

/// row: service sampler: a scan that cannot list where its parents are (the cgroup root, or the user's manager) ranks neither kernel nor short jobs, and logs it: kernel never absorbs a parent it could not find (R1, ruling R22)
#[test]
fn a_scan_that_cannot_list_where_its_parents_are_ranks_neither_kernel_nor_short_jobs_and_logs_it() {
    // A root Δ of 3,000,000 µs. With the root unlisted system.slice is not found, and kernel would
    // read 3,000,000 − 700,000 (57.5%); with the manager unlisted the user's slices are not, and it
    // would read 67.5%.
    let scan_with_unlistable = |directory_relative_path: &str| {
        let unlistable_directory = cgroup_relative_path(directory_relative_path);
        let (top_cpu, logged, _) = top_cpu_after_two_scans(
            &with_counters(&steady_deltas_usec(), &[(ROOT_CGROUP_KEY, 3_000_000)]),
            TwoScanOptions {
                before_second_scan: Box::new(move |tree| {
                    tree.fail_with(
                        &unlistable_directory,
                        ReadFailure::Other(DIRECTORY_DENIED_TEXT.to_string()),
                    )
                }),
                ..TwoScanOptions::default()
            },
        );
        (top_cpu, logged)
    };
    assert_eq!(
        scan_with_unlistable(ROOT_CGROUP_KEY),
        (
            Some(cpu_entry("app:org.example.Editor", "Editor", 7.5)),
            vec![logged_line(&format!(
                "cannot read 1 cgroups, first: the cgroup root: {DIRECTORY_DENIED_TEXT}"
            ))]
        )
    );
    assert_eq!(
        scan_with_unlistable(USER_SERVICE_PATH),
        (
            Some(cpu_entry("unit:example-daemon", "example-daemon", 2.5)),
            vec![logged_line(&format!(
                "cannot read 1 cgroups, first: {USER_SERVICE_PATH}: {DIRECTORY_DENIED_TEXT}"
            ))]
        )
    );
}

/// row: service sampler: a long-lived leaf that could not be read in one scan is not counted at its whole lifetime when it reads again: its CPU goes to short jobs
#[test]
fn a_long_lived_leaf_that_could_not_be_read_in_one_scan_is_not_counted_at_its_whole_lifetime() {
    // Editor has run for an hour. Denied in the first scan, it would look new in the second, under a
    // parent listed in the first, and count 3,600,300,000 µs: about 90,000% of the machine.
    let editor_cpu_stat_path = format!("{}/cpu.stat", cgroup_relative_path(EDITOR_LEAF));
    let cleared_path = editor_cpu_stat_path.clone();
    let (top_cpu, logged, _) = top_cpu_after_two_scans(
        &with_counters(&steady_deltas_usec(), &[(ROOT_CGROUP_KEY, 1_100_000)]),
        TwoScanOptions {
            first_scan_counters_usec: with_counters(
                &first_scan_counters_usec(),
                &[(EDITOR_LEAF, LONG_LIVED_LEAF_USAGE_USEC)],
            ),
            before_first_scan: Box::new(move |tree| {
                tree.fail_with(
                    &editor_cpu_stat_path,
                    ReadFailure::Other(FILE_DENIED_TEXT.to_string()),
                )
            }),
            before_second_scan: Box::new(move |tree| tree.clear_failure(&cleared_path)),
            ..TwoScanOptions::default()
        },
    );
    // app.slice's 400,000 µs (Editor's 300,000 among them), plus the other parents' 300,000 beyond
    // their leaves.
    assert_eq!(
        (top_cpu, logged),
        (
            Some(cpu_entry(
                "pseudo:short-jobs",
                SHORT_JOBS_LABEL,
                700_000.0 / 4_000_000.0 * 100.0
            )),
            vec![logged_line(&format!(
                "cannot read 1 cgroups, first: {EDITOR_LEAF}: {FILE_DENIED_TEXT}"
            ))]
        )
    );
}

/// row: service sampler: without a uid (unreadable /proc/self/status) neither kernel nor short jobs is ranked, so kernel never absorbs the user session
#[test]
fn without_a_uid_neither_kernel_nor_short_jobs_is_ranked_so_kernel_never_absorbs_the_user_session()
{
    // Only system.slice is scanned: kernel would be 3,000,000 − 300,000 µs (67.5%), the user
    // session's CPU included.
    let (top_cpu, logged, _) = top_cpu_after_two_scans(
        &with_counters(&steady_deltas_usec(), &[(ROOT_CGROUP_KEY, 3_000_000)]),
        TwoScanOptions {
            before_initialize: Box::new(|tree| {
                tree.fail_with(
                    "proc/self/status",
                    ReadFailure::Other(FILE_DENIED_TEXT.to_string()),
                )
            }),
            ..TwoScanOptions::default()
        },
    );
    assert_eq!(
        (
            top_cpu,
            logged.iter().any(|line| line.contains("proc/self/status"))
        ),
        (
            Some(cpu_entry(
                "unit:example-daemon",
                "example-daemon",
                100_000.0 / 4_000_000.0 * 100.0
            )),
            true
        )
    );
}

/// Name of the generated cgroup leaf at an index, zero-padded so the names sort as the indices do.
fn generated_leaf_name(leaf_index: usize) -> String {
    format!("generated-{leaf_index:03}.service")
}

/// row: service sampler: 109 cgroups failing with one error log one line per 10 minutes, naming the count and the first path
#[test]
fn cgroups_failing_with_one_error_log_one_line_per_10_minutes_naming_the_count_and_the_first_path()
{
    let tree = fake_tree_with_sample_files();
    let failing_leaf_paths: Vec<String> = (0..FAILING_LEAF_COUNT)
        .map(|leaf_index| format!("{SYSTEM_SLICE}/{}", generated_leaf_name(leaf_index)))
        .collect();
    let mut usage_usec_by_cgroup =
        counters(&[(ROOT_CGROUP_KEY, 1_000_000), (SYSTEM_SLICE, 1_000_000)]);
    for leaf_path in &failing_leaf_paths {
        usage_usec_by_cgroup.insert(leaf_path.clone(), LONG_LIVED_LEAF_USAGE_USEC);
    }
    write_cgroup_counters(&tree, &usage_usec_by_cgroup);
    let cpu_stat_of = |leaf_path: &str| format!("{}/cpu.stat", cgroup_relative_path(leaf_path));
    for leaf_path in &failing_leaf_paths {
        tree.fail_with(
            &cpu_stat_of(leaf_path),
            ReadFailure::Other(FILE_DENIED_TEXT.to_string()),
        );
    }
    let mut test_sampler = SamplerSetup::on_tree(&tree).build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    let lines_after_first_scan = test_sampler.logged();
    // The warm-up scan, 2 s later: another count and another first path, the same template. The leaf
    // that reads again has an hour of CPU and spent none since; counted as new, it would top CPU at
    // about 90,000%.
    tree.clear_failure(&cpu_stat_of(&failing_leaf_paths[0]));
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    test_sampler.sampler.run_tick(1);
    let line_count_after_second_scan = test_sampler.logged().len();
    let top_cpu_percent_after_second_scan = test_sampler
        .sampler
        .latest_snapshot()
        .and_then(|snapshot| snapshot.apps.as_ref())
        .and_then(|apps| apps.top_cpu.as_ref())
        .map(|entry| entry.cpu_percent);
    test_sampler
        .now_usec
        .set(ERROR_LOG_REPEAT_INTERVAL_USEC + SAMPLE_SPACING_USEC);
    test_sampler
        .sampler
        .run_tick(FIRST_UNWATCHED_INTERVAL_SCAN_TICK);
    assert_eq!(
        (
            lines_after_first_scan,
            line_count_after_second_scan,
            top_cpu_percent_after_second_scan,
            test_sampler.logged().last().cloned(),
        ),
        (
            vec![logged_line(&format!(
                "cannot read {FAILING_LEAF_COUNT} cgroups, first: {}: {FILE_DENIED_TEXT}",
                failing_leaf_paths[0]
            ))],
            1,
            Some(0.0),
            Some(logged_line(&format!(
                "cannot read {} cgroups, first: {}: {FILE_DENIED_TEXT}",
                FAILING_LEAF_COUNT - 1,
                failing_leaf_paths[1]
            ))),
        )
    );
}

/// sampler: a "no such device" read is a vanished cgroup, silent; any other failure is counted
///
/// Each failure handed in through the reader or the lister: a leaf's memory.current and a parent's
/// cpu.stat with no such device, a leaf's cpu.stat not found, machine.slice's listing with no such
/// device (each silent: the cgroup is gone), and a leaf's cpu.stat denied (counted, and the one line
/// logged, once per interval). Expected values: the gjs `ServiceSampler` run through the same tree,
/// ticks and failures (the task's `new-rows.js`, row A).
#[test]
fn a_no_such_device_read_is_a_vanished_cgroup_silent_any_other_failure_is_counted() {
    let tree = fake_tree_with_sample_files();
    let first_counters = counters(&[
        (ROOT_CGROUP_KEY, 10_000_000),
        (APP_SLICE, 1_000_000),
        (SESSION_SLICE, 1_000_000),
        (BACKGROUND_SLICE, 1_000_000),
        (SYSTEM_SLICE, 1_000_000),
        (MACHINE_SLICE, 1_000_000),
        (VM_LEAF, 500_000),
        (EDITOR_LEAF, 500_000),
        (BUILDER_LEAF, 500_000),
        (SHELL_LEAF, 500_000),
        (DAEMON_LEAF, 500_000),
    ]);
    write_cgroup_counters(&tree, &first_counters);
    let in_cgroup = |cgroup_path: &str, file_name: &str| {
        format!("{}/{file_name}", cgroup_relative_path(cgroup_path))
    };
    tree.fail_with(
        &in_cgroup(EDITOR_LEAF, "memory.current"),
        ReadFailure::NoSuchDevice,
    );
    tree.fail_with(&in_cgroup(SHELL_LEAF, "cpu.stat"), ReadFailure::NotFound);
    tree.fail_with(
        &in_cgroup(DAEMON_LEAF, "cpu.stat"),
        ReadFailure::Other(FILE_DENIED_TEXT.to_string()),
    );
    tree.fail_with(
        &in_cgroup(BACKGROUND_SLICE, "cpu.stat"),
        ReadFailure::NoSuchDevice,
    );
    tree.fail_with(
        &cgroup_relative_path(MACHINE_SLICE),
        ReadFailure::NoSuchDevice,
    );
    let mut test_sampler = SamplerSetup::on_tree(&tree).build();
    test_sampler.sampler.initialize();
    test_sampler.sampler.run_tick(0);
    let daemon_line = logged_line(&format!(
        "cannot read 1 cgroups, first: {DAEMON_LEAF}: {FILE_DENIED_TEXT}"
    ));
    let builder_memory = memory_entry("app:org.example.Builder", "Builder", 1_000_000.0);
    assert_eq!(test_sampler.logged(), std::slice::from_ref(&daemon_line));
    assert_eq!(
        test_sampler.sampler.latest_snapshot().unwrap().apps,
        Some(AppRanking {
            top_cpu: None,
            top_memory: Some(builder_memory.clone()),
            cpu_ranking: vec![],
            memory_ranking: vec![builder_memory.clone()],
        })
    );
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    write_cgroup_counters(
        &tree,
        &with_counters(
            &first_counters,
            &[
                (ROOT_CGROUP_KEY, 13_000_000),
                (APP_SLICE, 1_700_000),
                (SESSION_SLICE, 1_200_000),
                (SYSTEM_SLICE, 1_300_000),
                (MACHINE_SLICE, 1_100_000),
                (VM_LEAF, 550_000),
                (EDITOR_LEAF, 800_000),
                (BUILDER_LEAF, 900_000),
                (SHELL_LEAF, 700_000),
                (DAEMON_LEAF, 600_000),
            ],
        ),
    );
    test_sampler.sampler.run_tick(1);
    let kernel = cpu_entry("pseudo:kernel", KERNEL_LABEL, 42.5);
    assert_eq!(test_sampler.logged(), [daemon_line]);
    assert_eq!(
        test_sampler.sampler.latest_snapshot().unwrap().apps,
        Some(AppRanking {
            top_cpu: Some(kernel.clone()),
            top_memory: Some(builder_memory.clone()),
            cpu_ranking: vec![
                kernel,
                cpu_entry("pseudo:short-jobs", SHORT_JOBS_LABEL, 22.5),
                cpu_entry("app:org.example.Builder", "Builder", 10.0),
            ],
            memory_ranking: vec![builder_memory],
        })
    );
}
