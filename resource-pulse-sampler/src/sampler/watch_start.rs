//! A watch start's own scan, outside the tick (`_scanForWatchStart`).

use super::snapshot::{Publish, Snapshot};
use super::Sampler;
use crate::cadence::{decide_app_scan, ScanReason};
use crate::caught_panic::value_or_none;

/// The scan reasons a watch start acts on at once, outside the tick. A warm-up, burst or interval
/// scan is paced by the ticks: run here, a warm-up would follow the watch-start scan by milliseconds
/// (a CPU window of almost nothing), and rapid cover and uncover would scan inside the reveal
/// cooldown. Before the first tick there is nothing to reveal, and that tick scans anyway.
const WATCH_START_SCAN_REASONS: [ScanReason; 1] = [ScanReason::WatchStart];

impl Sampler {
    /// A watch start's decision, outside the tick, as of the latest tick: a watch-start scan (the
    /// reveal cooldown lives in `decide_app_scan`) runs at once, and a snapshot of the latest fast
    /// tick's values with the new ranking is published, without touching the histories.
    ///
    /// It does not scan less than the CPU ranking window after the last scan: the client already has
    /// that ranking, so nothing is published and no warm-up is armed. After a tick that had no data
    /// it scans but publishes nothing, since there are no fast-tick values to reuse and a no-data
    /// snapshot keeps its apps `None`; the next tick that samples carries the ranking.
    pub(super) fn scan_for_watch_start(&mut self) -> Option<Publish> {
        let latest_tick_number = self.cadence.latest_tick_number?;
        let latest_snapshot = self.latest_snapshot.clone()?;
        let clock = self.clock.as_ref();
        let now_usec = value_or_none(|| clock.monotonic_usec())?;
        if self.is_cpu_ranking_window_too_short(Some(now_usec)) {
            return None;
        }
        let cadence_state = self.cadence_state(latest_tick_number, &latest_snapshot, true);
        let reason = decide_app_scan(&cadence_state)
            .filter(|reason| WATCH_START_SCAN_REASONS.contains(reason))?;
        self.run_app_scan(reason, latest_tick_number, &latest_snapshot);
        if self.is_latest_snapshot_no_data {
            return None;
        }
        let reveal_snapshot = Snapshot {
            apps: self.latest_app_ranking.clone(),
            ..latest_snapshot
        };
        self.latest_snapshot = Some(reveal_snapshot.clone());
        Some(Publish {
            snapshot: reveal_snapshot,
            appended_history: None,
        })
    }
}
