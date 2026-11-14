//! What `lib/cadence.js`'s `decideAppScan` reads, kept between ticks, and the decision at a tick
//! (`_cadenceState`, `_scanAppsIfDue`, `_isCpuRankingWindowTooShort`, `_recordAppScanInCadence`).
//! Ticks since a scan are a difference of tick numbers, in `f64` as gjs computes it: never an
//! unsigned subtraction, which a tick number that went backwards would underflow.

use super::snapshot::{PressureAvg10, Snapshot};
use super::Sampler;
use crate::cadence::{arms_warm_up, decide_app_scan, is_triggered_scan, CadenceState, ScanReason};
use crate::constants::MIN_CPU_RANKING_WINDOW_SECONDS;
use crate::pressure::pressure_band;

const USEC_PER_SECOND: u64 = 1_000_000;
/// The shortest time a CPU ranking may cover.
const MIN_CPU_RANKING_WINDOW_USEC: u64 = MIN_CPU_RANKING_WINDOW_SECONDS * USEC_PER_SECOND;
/// The reasons a tick puts off by one tick when the previous scan is less than
/// [`MIN_CPU_RANKING_WINDOW_USEC`] old: a warm-up exists only to sharpen the CPU ranking, which over
/// so short a window would be noise. It stays pending.
const WINDOW_DEFERRED_SCAN_REASONS: [ScanReason; 1] = [ScanReason::WarmUp];

/// The cadence's memory between ticks; `None` is gjs's `null` (never, or no data).
pub(super) struct CadenceBookkeeping {
    pub(super) is_detail_watched: bool,
    /// The latest tick run; a watch start decides as of it.
    pub(super) latest_tick_number: Option<u64>,
    last_app_scan_tick_number: Option<u64>,
    last_triggered_scan_tick_number: Option<u64>,
    is_warm_up_pending: bool,
    pub(super) last_app_scan_reason: Option<ScanReason>,
    cpu_busy_percent_at_last_scan: Option<f64>,
    pressure_bands_at_last_scan: Vec<Option<f64>>,
}

impl Default for CadenceBookkeeping {
    /// Nothing scanned yet, no watch held, and no-data pressure bands at the "last scan".
    fn default() -> Self {
        CadenceBookkeeping {
            is_detail_watched: false,
            latest_tick_number: None,
            last_app_scan_tick_number: None,
            last_triggered_scan_tick_number: None,
            is_warm_up_pending: false,
            last_app_scan_reason: None,
            cpu_busy_percent_at_last_scan: None,
            pressure_bands_at_last_scan: pressure_bands_of(&PressureAvg10::default()),
        }
    }
}

/// The cpu, memory and io pressure bands of a sample, in `lib/cadence.js`'s order, each `None` for
/// no data (`pressureBandsOf`).
fn pressure_bands_of(pressure_avg10: &PressureAvg10) -> Vec<Option<f64>> {
    [pressure_avg10.cpu, pressure_avg10.memory, pressure_avg10.io]
        .into_iter()
        .map(|avg10_percent| pressure_band(avg10_percent).map(f64::from))
        .collect()
}

/// Ticks since an earlier tick (`ticksSince`): `tick - earlier` as the double gjs computes, negative
/// when the tick number went backwards; `None` for never.
fn ticks_since(earlier_tick_number: Option<u64>, tick_number: u64) -> Option<f64> {
    earlier_tick_number.map(|earlier_tick_number| tick_number as f64 - earlier_tick_number as f64)
}

impl Sampler {
    /// The state `decideAppScan` reads, at a tick and for a sample.
    pub(super) fn cadence_state(
        &self,
        tick_number: u64,
        sample: &Snapshot,
        watch_started_this_tick: bool,
    ) -> CadenceState {
        let cadence = &self.cadence;
        CadenceState {
            is_watched: cadence.is_detail_watched,
            watch_started_this_tick,
            ticks_since_last_scan: ticks_since(cadence.last_app_scan_tick_number, tick_number),
            warm_up_pending: cadence.is_warm_up_pending,
            ticks_since_triggered_scan: ticks_since(
                cadence.last_triggered_scan_tick_number,
                tick_number,
            ),
            cpu_busy_percent_now: sample.cpu_busy_percent,
            cpu_busy_percent_at_last_scan: cadence.cpu_busy_percent_at_last_scan,
            pressure_bands_now: pressure_bands_of(&sample.pressure_avg10),
            pressure_bands_at_last_scan: cadence.pressure_bands_at_last_scan.clone(),
        }
    }

    /// Runs the app scan when the cadence says one is due at this tick. A warm-up due less than
    /// [`MIN_CPU_RANKING_WINDOW_USEC`] after the previous scan waits a tick: nothing is recorded, so
    /// it is still pending at the next.
    pub(super) fn scan_apps_if_due(&mut self, tick_number: u64, sample: &Snapshot) {
        let Some(reason) = decide_app_scan(&self.cadence_state(tick_number, sample, false)) else {
            return;
        };
        let is_deferred_for_its_window = WINDOW_DEFERRED_SCAN_REASONS.contains(&reason)
            && self.is_cpu_ranking_window_too_short(sample.taken_at_usec);
        if is_deferred_for_its_window {
            return;
        }
        self.run_app_scan(reason, tick_number, sample);
    }

    /// Whether a scan now would rank CPU over less than [`MIN_CPU_RANKING_WINDOW_USEC`]. With no
    /// previous scan to diff against, a scan is only a baseline, so its window does not matter. A
    /// time that could not be read counts as too short, as gjs's `null - takenAtUsec` is negative.
    pub(super) fn is_cpu_ranking_window_too_short(&self, now_usec: Option<u64>) -> bool {
        let Some(previous_scan) = &self.previous_app_scan else {
            return false;
        };
        now_usec.is_none_or(|now_usec| {
            let window_usec = i128::from(now_usec) - i128::from(previous_scan.taken_at_usec);
            window_usec < i128::from(MIN_CPU_RANKING_WINDOW_USEC)
        })
    }

    /// Notes a scan for the cadence: when it ran, whether it arms a warm-up and starts the cooldowns,
    /// and the CPU and pressure a later burst is measured against.
    pub(super) fn record_app_scan_in_cadence(
        &mut self,
        reason: ScanReason,
        tick_number: u64,
        sample: &Snapshot,
    ) {
        let cadence = &mut self.cadence;
        cadence.last_app_scan_tick_number = Some(tick_number);
        if is_triggered_scan(Some(reason)) {
            cadence.last_triggered_scan_tick_number = Some(tick_number);
        }
        cadence.is_warm_up_pending = arms_warm_up(Some(reason));
        cadence.last_app_scan_reason = Some(reason);
        cadence.cpu_busy_percent_at_last_scan = sample.cpu_busy_percent;
        cadence.pressure_bands_at_last_scan = pressure_bands_of(&sample.pressure_avg10);
    }
}
