//! The app scan (`_runAppScan`, `_scanApps`, `_rankingInputs`, `_dropRankingAfterFailure`): lists
//! and reads the cgroup tree, logs its failures as one line, and ranks the apps against the
//! previous scan.

use std::collections::{HashMap, HashSet};

use super::app_names::group_of_cgroup;
use super::cgroup_tree::{CgroupReadFailures, CgroupTree, ROOT_CGROUP_RELATIVE_PATH};
use super::paths::{join_under, CGROUP_ROOT_PATH};
use super::snapshot::Snapshot;
use super::Sampler;
use crate::apps::{counter_delta_usec, rank_apps, AppRanking, RankingScan};
use crate::cadence::ScanReason;
use crate::caught_panic::catching_panic;
use crate::insertion_ordered_map::InsertionOrderedMap;

/// The template key of a failed scan's journal line.
const APP_SCAN_FAILURE_LOG_KEY: &str = "app scan failed";
/// The template key of the one line a scan's cgroup failures are logged as.
const CGROUP_READ_FAILURES_LOG_KEY: &str = "cannot read cgroups";

/// What one scan read and keeps as the next scan's baseline (gjs `currentScan`).
pub(super) struct AppScanReadings {
    /// The monotonic clock when the scan began.
    pub(super) taken_at_usec: u64,
    root_usage_usec: Option<u64>,
    parent_usage_usec_by_path: InsertionOrderedMap<u64>,
    usage_usec_by_cgroup: InsertionOrderedMap<u64>,
    /// The parents whose every leaf this scan knows (see [`fully_accounted_parent_paths`]).
    fully_accounted_parent_paths: HashSet<String>,
}

/// What the ranking needs from this scan besides the readings it keeps.
struct RankingInputs {
    current_scan: AppScanReadings,
    parent_of_leaf: HashMap<String, String>,
    memory_bytes_by_cgroup: InsertionOrderedMap<u64>,
    is_every_parent_fully_listed: bool,
}

/// The time between two scans, in microseconds: `current.takenAtUsec - previous.takenAtUsec`, as
/// the double gjs computes, a negative one included (a clock that went backwards). The difference
/// of two `u64` is exact in `i128` and fits an `i64` unless the readings are 2^63 µs apart; it is
/// the same number gjs's subtraction gives for every reading below 2^53 µs (285 years).
fn elapsed_usec_between(later_usec: u64, earlier_usec: u64) -> i64 {
    let difference_usec = i128::from(later_usec) - i128::from(earlier_usec);
    i64::try_from(difference_usec).unwrap_or(if difference_usec > 0 {
        i64::MAX
    } else {
        i64::MIN
    })
}

/// The root cgroup's CPU delta between two scans (`rootCpuDeltaUsec`): the plain difference of the
/// two readings as doubles, with no went-backwards rule, as gjs has it; `None` when either scan
/// could not read the root.
fn root_cpu_delta_usec(
    previous_scan: Option<&AppScanReadings>,
    current_scan: &AppScanReadings,
) -> Option<f64> {
    let previous_usec = previous_scan?.root_usage_usec?;
    let current_usec = current_scan.root_usage_usec?;
    Some(current_usec as f64 - previous_usec as f64)
}

/// Each scanned parent's CPU delta, for the parents read in both scans, in this scan's order
/// (`parentCpuDeltasUsec`). A parent this scan could not list has leaves it cannot see, whose CPU
/// would read as short jobs (or, the parent left out, as kernel): so unless every parent was listed
/// the map is empty and the ranking ranks neither.
fn parent_cpu_deltas_usec(
    previous_scan: Option<&AppScanReadings>,
    current_scan: &AppScanReadings,
    is_every_parent_fully_listed: bool,
) -> InsertionOrderedMap<f64> {
    let mut deltas_usec = InsertionOrderedMap::new();
    let Some(previous_scan) = previous_scan.filter(|_| is_every_parent_fully_listed) else {
        return deltas_usec;
    };
    for (parent_path, &current_usec) in current_scan.parent_usage_usec_by_path.iter() {
        if let Some(&previous_usec) = previous_scan.parent_usage_usec_by_path.get(parent_path) {
            deltas_usec.insert(parent_path, counter_delta_usec(previous_usec, current_usec));
        }
    }
    deltas_usec
}

/// The parents whose every leaf this scan knows: listed completely, and each leaf read or seen to
/// vanish (`fullyAccountedParentPaths`). The next scan counts a new leaf in full only under one of
/// these. A leaf that exists but could not be read is missing from this scan's readings, so in the
/// next it would look new and count its whole lifetime's usage: its parent is left out, its leaves
/// are skipped next time, and their CPU stays in short jobs.
fn fully_accounted_parent_paths(
    cgroup_tree: &CgroupTree,
    unread_leaf_paths: &[String],
) -> HashSet<String> {
    let parents_with_unread_leaves: HashSet<&String> = unread_leaf_paths
        .iter()
        .filter_map(|leaf_path| cgroup_tree.parent_of_leaf.get(leaf_path))
        .collect();
    cgroup_tree
        .fully_listed_parent_paths
        .iter()
        .filter(|parent_path| !parents_with_unread_leaves.contains(parent_path))
        .cloned()
        .collect()
}

impl Sampler {
    /// Records a scan in the cadence, then scans. A scan that fails drops the ranking; it still
    /// counts as a scan for the cadence, so a lasting failure costs one scan per interval, never one
    /// per tick.
    pub(super) fn run_app_scan(&mut self, reason: ScanReason, tick_number: u64, sample: &Snapshot) {
        self.record_app_scan_in_cadence(reason, tick_number, sample);
        if let Err(failure_text) = catching_panic(|| self.scan_apps()) {
            self.drop_ranking_after_failure(&failure_text);
        }
    }

    /// Drops the last ranking and its baseline after a scan failed, so the next snapshot carries no
    /// apps rather than a ranking from before the failure, then logs the failure.
    fn drop_ranking_after_failure(&mut self, failure_text: &str) {
        self.previous_app_scan = None;
        self.latest_app_ranking = None;
        self.log_rate_limited(
            &format!("app scan failed: {failure_text}"),
            APP_SCAN_FAILURE_LOG_KEY,
        );
    }

    /// Scans the app cgroups once and ranks them: lists the leaves under the scanned parents, reads
    /// `cpu.stat` of the root and of each parent, reads each leaf, logs the failures as one line, and
    /// hands the ranking everything it needs for kernel and short jobs.
    fn scan_apps(&mut self) {
        let taken_at_usec = self.clock.monotonic_usec();
        let cgroup_root_path = join_under(&self.fs_root, CGROUP_ROOT_PATH);
        let mut failures = CgroupReadFailures::default();
        let cgroup_tree = self.list_cgroup_tree(&cgroup_root_path, &mut failures);
        let root_usage_usec = self.read_cgroup_usage_usec(
            &cgroup_root_path,
            ROOT_CGROUP_RELATIVE_PATH,
            &mut failures,
        );
        let parent_usage_usec_by_path = self.read_parent_usage(
            &cgroup_root_path,
            &cgroup_tree.parent_relative_paths,
            &mut failures,
        );
        let leaf_readings = self.read_cgroup_leaves(
            &cgroup_root_path,
            &cgroup_tree.leaf_relative_paths,
            &mut failures,
        );
        if let Some(failures_line) = failures.describe() {
            self.log_rate_limited(&failures_line, CGROUP_READ_FAILURES_LOG_KEY);
        }
        let current_scan = AppScanReadings {
            taken_at_usec,
            root_usage_usec,
            parent_usage_usec_by_path,
            usage_usec_by_cgroup: leaf_readings.usage_usec_by_cgroup,
            fully_accounted_parent_paths: fully_accounted_parent_paths(
                &cgroup_tree,
                &leaf_readings.unread_leaf_paths,
            ),
        };
        let is_every_parent_fully_listed = cgroup_tree.is_every_parent_fully_listed;
        let ranking_inputs = RankingInputs {
            current_scan,
            parent_of_leaf: cgroup_tree.parent_of_leaf,
            memory_bytes_by_cgroup: leaf_readings.memory_bytes_by_cgroup,
            is_every_parent_fully_listed,
        };
        let (ranking, current_scan) = self.rank_against_previous_scan(ranking_inputs);
        self.previous_app_scan = Some(current_scan);
        self.latest_app_ranking = Some(ranking);
    }

    /// Ranks this scan's readings against the previous scan's (`_rankingInputs` and `rankApps`).
    /// Every input is passed explicitly: none defaults to empty, which would silently drop kernel and
    /// short jobs.
    ///
    /// The previous scan is taken out here, its maps moved into the ranking's input rather than
    /// copied, and this scan's usage map is moved back out afterwards to be the next scan's previous
    /// one. Were the ranking to panic, the catch around the scan would find the previous scan gone,
    /// which is the state gjs's `_dropRankingAfterFailure` leaves: so nothing is half-written.
    fn rank_against_previous_scan(
        &mut self,
        inputs: RankingInputs,
    ) -> (AppRanking, AppScanReadings) {
        let previous_scan = self.previous_app_scan.take();
        let current_scan = inputs.current_scan;
        // The real time between the two scans, never the nominal interval: ticks can run late.
        let elapsed_usec = previous_scan.as_ref().map_or(0, |previous_scan| {
            elapsed_usec_between(current_scan.taken_at_usec, previous_scan.taken_at_usec)
        });
        let root_cpu_delta_usec = root_cpu_delta_usec(previous_scan.as_ref(), &current_scan);
        let parent_cpu_delta_usec = parent_cpu_deltas_usec(
            previous_scan.as_ref(),
            &current_scan,
            inputs.is_every_parent_fully_listed,
        );
        // A new leaf counts in full only when its parent's listing in the previous scan proves it did
        // not exist then; one whose parent's previous listing failed is skipped (it may be an old
        // leaf merely unlisted), so its CPU stays inside its parent's delta, as short jobs.
        let (previous_usage_usec, parents_listed_previously) = previous_scan
            .map(|previous_scan| {
                (
                    previous_scan.usage_usec_by_cgroup,
                    previous_scan.fully_accounted_parent_paths,
                )
            })
            .unwrap_or_default();
        let AppScanReadings {
            taken_at_usec,
            root_usage_usec,
            parent_usage_usec_by_path,
            usage_usec_by_cgroup,
            fully_accounted_parent_paths,
        } = current_scan;
        let ranking_scan = RankingScan {
            previous_usage_usec,
            current_usage_usec: usage_usec_by_cgroup,
            memory_bytes_by_cgroup: inputs.memory_bytes_by_cgroup,
            elapsed_usec,
            cpu_count: self.cpu_count.unwrap_or(0),
            root_cpu_delta_usec,
            parent_of_leaf: inputs.parent_of_leaf,
            parents_listed_previously,
            parent_cpu_delta_usec,
        };
        let app_names = &mut self.app_names;
        let error_log = &mut self.error_log;
        let clock = self.clock.as_ref();
        let ranking = rank_apps(&ranking_scan, &mut |cgroup_path| {
            group_of_cgroup(cgroup_path, &mut |desktop_id| {
                app_names.look_up(desktop_id, error_log, clock)
            })
        });
        let current_scan = AppScanReadings {
            taken_at_usec,
            root_usage_usec,
            parent_usage_usec_by_path,
            usage_usec_by_cgroup: ranking_scan.current_usage_usec,
            fully_accounted_parent_paths,
        };
        (ranking, current_scan)
    }
}
