//! Publishing a tick: the histories, the latest snapshot and the last good clock label
//! (`_publishTickSnapshot`, `_recordHistory`, `_publishNoDataSnapshot`).

use super::snapshot::{AppendedHistory, Publish, Snapshot};
use super::{Sampler, PERCENT_SCALE, SAMPLE_FAILURE_LOG_KEY};
use crate::caught_panic::value_or_none;

impl Sampler {
    /// Publishes a fast tick's snapshot: appends it to the histories and makes it the latest.
    pub(super) fn publish_tick_snapshot(&mut self, snapshot: Snapshot) -> Publish {
        let appended_history = self.record_history(&snapshot);
        self.latest_snapshot = Some(snapshot.clone());
        Publish {
            snapshot,
            appended_history: Some(appended_history),
        }
    }

    /// Publishes the no-data state after a sample failed: an all-`None`, incomplete snapshot and a gap
    /// in both histories, so no surface goes on showing the last good numbers as live. The failure is
    /// logged last, as gjs logs it after its listeners have heard. The last good clock label is left
    /// alone (the snapshot has no data), so "no data since" still names the last good sample.
    pub(super) fn publish_no_data_snapshot(&mut self, failure_message: &str) -> Publish {
        let clock = self.clock.as_ref();
        let taken_at_usec = value_or_none(|| clock.monotonic_usec());
        let taken_at_clock_label = value_or_none(|| clock.clock_label()).and_then(Result::ok);
        self.is_latest_snapshot_no_data = true;
        let publish =
            self.publish_tick_snapshot(Snapshot::no_data(taken_at_usec, taken_at_clock_label));
        self.log_rate_limited(failure_message, SAMPLE_FAILURE_LOG_KEY);
        publish
    }

    /// Appends a snapshot's CPU and memory fractions to the histories (`None` for a gap), and names
    /// it the last good sample when it has CPU or memory data.
    fn record_history(&mut self, snapshot: &Snapshot) -> AppendedHistory {
        let memory_fraction = snapshot
            .memory
            .filter(|memory| memory.total_bytes > 0.0)
            .map(|memory| memory.used_bytes / memory.total_bytes);
        let appended_history = AppendedHistory {
            cpu: snapshot
                .cpu_busy_percent
                .map(|cpu_busy_percent| cpu_busy_percent / PERCENT_SCALE),
            memory: memory_fraction,
        };
        self.cpu_history.push(appended_history.cpu);
        self.memory_history.push(appended_history.memory);
        if snapshot.cpu_busy_percent.is_some() || snapshot.memory.is_some() {
            self.last_good_clock_label = snapshot.taken_at_clock_label.clone();
        }
        appended_history
    }
}
