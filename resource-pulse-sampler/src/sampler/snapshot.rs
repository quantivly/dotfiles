//! What one tick publishes: the snapshot (`service/sampler.js`'s `Snapshot` typedef, its nine fields
//! in that order) and the values the tick appended to the histories.

use crate::apps::AppRanking;
use crate::memory::{MemoryUsage, SwapSummary};

/// One sample, as the gjs sampler hands its listeners and the protocol carries it. Every number is
/// the double the gjs sampler computes; `None` is its `null`.
#[derive(Debug, Clone, PartialEq)]
pub struct Snapshot {
    /// The monotonic clock when the sample began; `None` only in a no-data snapshot whose clock
    /// could not be read.
    pub taken_at_usec: Option<u64>,
    /// Wall-clock `HH:MM` of the sample; `None` only in a no-data snapshot whose label could not be
    /// read.
    pub taken_at_clock_label: Option<String>,
    /// Whole-machine CPU busy, 0 to 100; `None` on the first sample (no delta yet) and when
    /// `/proc/stat` could not be read.
    pub cpu_busy_percent: Option<f64>,
    /// Busy percent per core type; `None` on a single-cluster machine and whenever
    /// `cpu_busy_percent` is.
    pub cpu_clusters: Option<ClusterPercents>,
    /// `MemTotal - MemAvailable`, and `MemTotal`.
    pub memory: Option<MemoryUsage>,
    /// Swap in use on zram (and the RAM those devices take) and on every other area.
    pub swap: Option<SwapSummary>,
    /// PSI `some avg10` percents.
    pub pressure_avg10: PressureAvg10,
    /// The latest app scan's ranking; `None` before the first and after a scan that failed.
    pub apps: Option<AppRanking>,
    /// Whether every read and parse of this sample succeeded. A first sample's missing CPU delta is
    /// not a failure; a no-data snapshot is never complete.
    pub is_complete: bool,
}

/// Busy percent of each core type.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ClusterPercents {
    pub performance_percent: Option<f64>,
    pub efficiency_percent: Option<f64>,
}

/// PSI `some avg10` of each resource, `None` for no data.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct PressureAvg10 {
    pub cpu: Option<f64>,
    pub memory: Option<f64>,
    pub io: Option<f64>,
}

/// What a fast tick appended to the two histories (`None` for a gap).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AppendedHistory {
    /// The CPU busy fraction, 0 to 1.
    pub cpu: Option<f64>,
    /// The memory used fraction, 0 to 1.
    pub memory: Option<f64>,
}

/// What the gjs sampler hands each listener at once: a snapshot, and what a fast tick appended to
/// the histories (`None` for a watch start's snapshot, which appends nothing).
#[derive(Debug, Clone, PartialEq)]
pub struct Publish {
    pub snapshot: Snapshot,
    pub appended_history: Option<AppendedHistory>,
}

impl Snapshot {
    /// The snapshot of a sample that failed (`_publishNoDataSnapshot`): every number `None`, no apps,
    /// incomplete, with whatever time and label could still be read.
    pub(super) fn no_data(
        taken_at_usec: Option<u64>,
        taken_at_clock_label: Option<String>,
    ) -> Snapshot {
        Snapshot {
            taken_at_usec,
            taken_at_clock_label,
            cpu_busy_percent: None,
            cpu_clusters: None,
            memory: None,
            swap: None,
            pressure_avg10: PressureAvg10::default(),
            apps: None,
            is_complete: false,
        }
    }
}
