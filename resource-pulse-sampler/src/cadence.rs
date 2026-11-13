//! When the service scans the cgroup tree, ported from `lib/cadence.js`.

use crate::constants::{
    APP_SCAN_INTERVAL_SECONDS, APP_SCAN_UNWATCHED_INTERVAL_SECONDS, BURST_COOLDOWN_TICKS,
    BURST_CPU_RISE_POINTS, REVEAL_SCAN_COOLDOWN_TICKS, SAMPLE_INTERVAL_SECONDS,
};

/// Ticks between scans while a detail watch is held. Divided in `f64`, as `cadence.js` does, so
/// an inexact division of two constants compares exactly as it does there.
const WATCHED_INTERVAL_TICKS: f64 =
    APP_SCAN_INTERVAL_SECONDS as f64 / SAMPLE_INTERVAL_SECONDS as f64;
/// Ticks between scans while no detail watch is held.
const UNWATCHED_INTERVAL_TICKS: f64 =
    APP_SCAN_UNWATCHED_INTERVAL_SECONDS as f64 / SAMPLE_INTERVAL_SECONDS as f64;

/// Why a scan ran: `decideAppScan`'s `reason` strings, `'first'`, `'interval'`, `'burst'`,
/// `'watch-start'` and `'warm-up'`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanReason {
    First,
    Interval,
    Burst,
    WatchStart,
    WarmUp,
}

/// What `decideAppScan` reads. A `None` is the JavaScript `null`: never scanned, or no data.
#[derive(Debug, Clone, PartialEq)]
pub struct CadenceState {
    pub is_watched: bool,
    pub watch_started_this_tick: bool,
    pub ticks_since_last_scan: Option<f64>,
    pub warm_up_pending: bool,
    pub ticks_since_triggered_scan: Option<f64>,
    pub cpu_busy_percent_now: Option<f64>,
    pub cpu_busy_percent_at_last_scan: Option<f64>,
    pub pressure_bands_now: Vec<Option<f64>>,
    pub pressure_bands_at_last_scan: Vec<Option<f64>>,
}

/// Whether a cooldown measured in ticks since the last triggered scan has run out
/// (`hasCooledDown`). No triggered scan ever, `None`, is a cooldown that has run out; a NaN
/// count is not `None` and compares false, so it has not.
fn has_cooled_down(ticks_since_triggered_scan: Option<f64>, cooldown_ticks: u64) -> bool {
    ticks_since_triggered_scan.is_none_or(|ticks| ticks >= cooldown_ticks as f64)
}

/// Whether CPU busy rose by the burst threshold since the last scan (`hasCpuBurst`). No data on
/// either side never bursts.
fn has_cpu_burst(state: &CadenceState) -> bool {
    match (
        state.cpu_busy_percent_now,
        state.cpu_busy_percent_at_last_scan,
    ) {
        (Some(now), Some(at_last_scan)) => now - at_last_scan >= BURST_CPU_RISE_POINTS as f64,
        _ => false,
    }
}

/// Whether any pressure meter's band rose since the last scan (`hasPressureBurst`). The bands
/// are paired by index over the current bands; a band with no data on either side, or none at
/// that index at the last scan, never bursts.
fn has_pressure_burst(state: &CadenceState) -> bool {
    state
        .pressure_bands_now
        .iter()
        .enumerate()
        .any(
            |(index, band_now)| match (band_now, state.pressure_bands_at_last_scan.get(index)) {
                (Some(now), Some(Some(at_last_scan))) => now > at_last_scan,
                _ => false,
            },
        )
}

/// Whether a burst may start a scan now (`burstAllowed`): a detail watch is held and no
/// triggered scan is recent enough to hold the burst cooldown.
fn is_burst_allowed(state: &CadenceState) -> bool {
    state.is_watched && has_cooled_down(state.ticks_since_triggered_scan, BURST_COOLDOWN_TICKS)
}

/// Decides whether the app scan runs now (`decideAppScan`), returning the first reason that
/// applies, in this order: first, watch-start, warm-up, burst, interval. `None` is no scan.
///
/// Parameters
/// ----------
/// state
///     What the decision reads. The caller keeps the counters and applies [`arms_warm_up`] and
///     [`is_triggered_scan`] to the reason of each scan it runs.
///
/// Returns
/// -------
/// The reason to scan, or `None` for no scan.
pub fn decide_app_scan(state: &CadenceState) -> Option<ScanReason> {
    let Some(ticks_since_last_scan) = state.ticks_since_last_scan else {
        return Some(ScanReason::First);
    };
    if state.watch_started_this_tick
        && has_cooled_down(state.ticks_since_triggered_scan, REVEAL_SCAN_COOLDOWN_TICKS)
    {
        return Some(ScanReason::WatchStart);
    }
    if state.warm_up_pending {
        return Some(ScanReason::WarmUp);
    }
    if is_burst_allowed(state) && (has_cpu_burst(state) || has_pressure_burst(state)) {
        return Some(ScanReason::Burst);
    }
    let interval_ticks = if state.is_watched {
        WATCHED_INTERVAL_TICKS
    } else {
        UNWATCHED_INTERVAL_TICKS
    };
    (ticks_since_last_scan >= interval_ticks).then_some(ScanReason::Interval)
}

/// Whether a scan of this reason arms a warm-up scan for the next tick (`armsWarmUp`).
///
/// Parameters
/// ----------
/// reason
///     The reason the scan ran, or `None` for no reason.
///
/// Returns
/// -------
/// `true` for first, watch-start and burst; `false` for interval, warm-up and no reason.
pub fn arms_warm_up(reason: Option<ScanReason>) -> bool {
    matches!(
        reason,
        Some(ScanReason::First | ScanReason::WatchStart | ScanReason::Burst)
    )
}

/// Whether a scan of this reason counts toward the watch-start and burst cooldowns
/// (`isTriggeredScan`).
///
/// Parameters
/// ----------
/// reason
///     The reason the scan ran, or `None` for no reason.
///
/// Returns
/// -------
/// `true` for watch-start and burst.
pub fn is_triggered_scan(reason: Option<ScanReason>) -> bool {
    matches!(reason, Some(ScanReason::WatchStart | ScanReason::Burst))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pressure::pressure_band;

    const WATCHED_INTERVAL_TICKS_EXPECTED: f64 = 10.0;
    const UNWATCHED_INTERVAL_TICKS_EXPECTED: f64 = 30.0;
    const CALM_BANDS: [Option<f64>; 3] = [Some(0.0), Some(0.0), Some(0.0)];
    const SETTLED_TICKS: f64 = 5.0;
    const REVEAL_COOLDOWN: f64 = REVEAL_SCAN_COOLDOWN_TICKS as f64;
    const BURST_COOLDOWN: f64 = BURST_COOLDOWN_TICKS as f64;

    /// A state in which nothing is due: watched, mid-interval, steady load, settled cooldowns
    /// (`quietState` of `cadence.test.js`).
    fn quiet_state() -> CadenceState {
        CadenceState {
            is_watched: true,
            watch_started_this_tick: false,
            ticks_since_last_scan: Some(3.0),
            warm_up_pending: false,
            ticks_since_triggered_scan: Some(SETTLED_TICKS),
            cpu_busy_percent_now: Some(40.0),
            cpu_busy_percent_at_last_scan: Some(40.0),
            pressure_bands_now: CALM_BANDS.to_vec(),
            pressure_bands_at_last_scan: CALM_BANDS.to_vec(),
        }
    }

    fn bands(values: [Option<f64>; 3]) -> Vec<Option<f64>> {
        values.to_vec()
    }

    /// row: cadence: the intervals are derived from the seconds constants
    #[test]
    fn intervals_are_derived_from_the_seconds_constants() {
        assert_eq!(
            [WATCHED_INTERVAL_TICKS, UNWATCHED_INTERVAL_TICKS],
            [
                WATCHED_INTERVAL_TICKS_EXPECTED,
                UNWATCHED_INTERVAL_TICKS_EXPECTED
            ]
        );
    }

    /// row: cadence: a quiet state does not scan
    #[test]
    fn a_quiet_state_does_not_scan() {
        assert_eq!(decide_app_scan(&quiet_state()), None);
    }

    /// row: cadence: with no scan yet, scan with reason first
    #[test]
    fn with_no_scan_yet_scan_with_reason_first() {
        let state = CadenceState {
            ticks_since_last_scan: None,
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::First));
    }

    /// row: cadence: first beats watch-start
    #[test]
    fn first_beats_watch_start() {
        let state = CadenceState {
            ticks_since_last_scan: None,
            watch_started_this_tick: true,
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::First));
    }

    /// row: cadence: watched interval scans at 10 ticks
    #[test]
    fn watched_interval_scans_at_10_ticks() {
        let state = CadenceState {
            ticks_since_last_scan: Some(WATCHED_INTERVAL_TICKS_EXPECTED),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::Interval));
    }

    /// row: cadence: watched interval does not scan at 9 ticks
    #[test]
    fn watched_interval_does_not_scan_at_9_ticks() {
        let state = CadenceState {
            ticks_since_last_scan: Some(WATCHED_INTERVAL_TICKS_EXPECTED - 1.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: unwatched interval scans at 30 ticks
    #[test]
    fn unwatched_interval_scans_at_30_ticks() {
        let state = CadenceState {
            is_watched: false,
            ticks_since_last_scan: Some(UNWATCHED_INTERVAL_TICKS_EXPECTED),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::Interval));
    }

    /// row: cadence: unwatched interval does not scan at 29 ticks
    #[test]
    fn unwatched_interval_does_not_scan_at_29_ticks() {
        let state = CadenceState {
            is_watched: false,
            ticks_since_last_scan: Some(UNWATCHED_INTERVAL_TICKS_EXPECTED - 1.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: unwatched does not scan at the watched interval
    #[test]
    fn unwatched_does_not_scan_at_the_watched_interval() {
        let state = CadenceState {
            is_watched: false,
            ticks_since_last_scan: Some(WATCHED_INTERVAL_TICKS_EXPECTED),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: a watch starting scans at once
    #[test]
    fn a_watch_starting_scans_at_once() {
        let state = CadenceState {
            watch_started_this_tick: true,
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::WatchStart));
    }

    /// row: cadence: a watch starting with no triggered scan yet scans
    #[test]
    fn a_watch_starting_with_no_triggered_scan_yet_scans() {
        let state = CadenceState {
            watch_started_this_tick: true,
            ticks_since_triggered_scan: None,
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::WatchStart));
    }

    /// row: cadence: a watch starting inside the reveal cooldown does not scan
    #[test]
    fn a_watch_starting_inside_the_reveal_cooldown_does_not_scan() {
        let state = CadenceState {
            watch_started_this_tick: true,
            ticks_since_triggered_scan: Some(REVEAL_COOLDOWN - 1.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: a watch starting at the end of the reveal cooldown scans
    #[test]
    fn a_watch_starting_at_the_end_of_the_reveal_cooldown_scans() {
        let state = CadenceState {
            watch_started_this_tick: true,
            ticks_since_triggered_scan: Some(REVEAL_COOLDOWN),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::WatchStart));
    }

    /// row: cadence: a pending warm-up scans with reason warm-up
    #[test]
    fn a_pending_warm_up_scans_with_reason_warm_up() {
        let state = CadenceState {
            warm_up_pending: true,
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::WarmUp));
    }

    /// row: cadence: a pending warm-up scans when unwatched too
    #[test]
    fn a_pending_warm_up_scans_when_unwatched_too() {
        let state = CadenceState {
            warm_up_pending: true,
            is_watched: false,
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::WarmUp));
    }

    /// row: cadence: watch-start beats warm-up
    #[test]
    fn watch_start_beats_warm_up() {
        let state = CadenceState {
            watch_started_this_tick: true,
            warm_up_pending: true,
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::WatchStart));
    }

    /// row: cadence: a watch starting inside the reveal cooldown with a warm-up pending falls through to warm-up
    #[test]
    fn a_watch_starting_inside_the_reveal_cooldown_with_a_warm_up_pending_falls_through_to_warm_up()
    {
        let state = CadenceState {
            watch_started_this_tick: true,
            warm_up_pending: true,
            ticks_since_triggered_scan: Some(REVEAL_COOLDOWN - 1.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::WarmUp));
    }

    /// row: cadence: warm-up beats burst
    #[test]
    fn warm_up_beats_burst() {
        let state = CadenceState {
            warm_up_pending: true,
            cpu_busy_percent_now: Some(90.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::WarmUp));
    }

    /// row: cadence: burst beats interval
    #[test]
    fn burst_beats_interval() {
        let state = CadenceState {
            ticks_since_last_scan: Some(WATCHED_INTERVAL_TICKS_EXPECTED),
            cpu_busy_percent_now: Some(90.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::Burst));
    }

    /// row: cadence: CPU 40 to 55 bursts when watched
    #[test]
    fn cpu_40_to_55_bursts_when_watched() {
        let state = CadenceState {
            cpu_busy_percent_at_last_scan: Some(40.0),
            cpu_busy_percent_now: Some(55.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::Burst));
    }

    /// row: cadence: CPU 40 to 54 does not burst
    #[test]
    fn cpu_40_to_54_does_not_burst() {
        let state = CadenceState {
            cpu_busy_percent_at_last_scan: Some(40.0),
            cpu_busy_percent_now: Some(54.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: unwatched never bursts on CPU
    #[test]
    fn unwatched_never_bursts_on_cpu() {
        let state = CadenceState {
            is_watched: false,
            cpu_busy_percent_at_last_scan: Some(0.0),
            cpu_busy_percent_now: Some(100.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: a null CPU value now never bursts
    ///
    /// The last-scan value is one that a missing value read as zero would turn into a huge rise.
    #[test]
    fn a_null_cpu_value_now_never_bursts() {
        let state = CadenceState {
            cpu_busy_percent_now: None,
            cpu_busy_percent_at_last_scan: Some(-100.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: a null CPU value at the last scan never bursts
    #[test]
    fn a_null_cpu_value_at_the_last_scan_never_bursts() {
        let state = CadenceState {
            cpu_busy_percent_at_last_scan: None,
            cpu_busy_percent_now: Some(100.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: a pressure band rising 1 to 2 bursts
    #[test]
    fn a_pressure_band_rising_1_to_2_bursts() {
        let state = CadenceState {
            pressure_bands_at_last_scan: bands([Some(0.0), Some(1.0), Some(0.0)]),
            pressure_bands_now: bands([Some(0.0), Some(2.0), Some(0.0)]),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::Burst));
    }

    /// row: cadence: a pressure band falling does not burst
    #[test]
    fn a_pressure_band_falling_does_not_burst() {
        let state = CadenceState {
            pressure_bands_at_last_scan: bands([Some(0.0), Some(2.0), Some(0.0)]),
            pressure_bands_now: bands([Some(0.0), Some(1.0), Some(0.0)]),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: a pressure band staying does not burst
    #[test]
    fn a_pressure_band_staying_does_not_burst() {
        let steady = bands([Some(1.0), Some(1.0), Some(1.0)]);
        let state = CadenceState {
            pressure_bands_at_last_scan: steady.clone(),
            pressure_bands_now: steady,
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: a null pressure band now never bursts
    ///
    /// Band -1 at the last scan: a missing band read as zero would be above it.
    #[test]
    fn a_null_pressure_band_now_never_bursts() {
        let state = CadenceState {
            pressure_bands_at_last_scan: bands([Some(-1.0), Some(0.0), Some(0.0)]),
            pressure_bands_now: bands([None, Some(0.0), Some(0.0)]),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: a null pressure band at the last scan never bursts
    #[test]
    fn a_null_pressure_band_at_the_last_scan_never_bursts() {
        let state = CadenceState {
            pressure_bands_at_last_scan: bands([None, Some(0.0), Some(0.0)]),
            pressure_bands_now: bands([Some(3.0), Some(0.0), Some(0.0)]),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: unwatched never bursts on pressure
    #[test]
    fn unwatched_never_bursts_on_pressure() {
        let state = CadenceState {
            is_watched: false,
            pressure_bands_at_last_scan: bands([Some(0.0), Some(0.0), Some(0.0)]),
            pressure_bands_now: bands([Some(0.0), Some(0.0), Some(3.0)]),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: no burst inside the burst cooldown
    #[test]
    fn no_burst_inside_the_burst_cooldown() {
        let state = CadenceState {
            cpu_busy_percent_now: Some(90.0),
            ticks_since_triggered_scan: Some(BURST_COOLDOWN - 1.0),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), None);
    }

    /// row: cadence: a burst is allowed at the end of the burst cooldown
    #[test]
    fn a_burst_is_allowed_at_the_end_of_the_burst_cooldown() {
        let state = CadenceState {
            cpu_busy_percent_now: Some(90.0),
            ticks_since_triggered_scan: Some(BURST_COOLDOWN),
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::Burst));
    }

    /// row: cadence: a burst is allowed with no triggered scan yet
    #[test]
    fn a_burst_is_allowed_with_no_triggered_scan_yet() {
        let state = CadenceState {
            cpu_busy_percent_now: Some(90.0),
            ticks_since_triggered_scan: None,
            ..quiet_state()
        };
        assert_eq!(decide_app_scan(&state), Some(ScanReason::Burst));
    }

    /// The reasons of the two reason rows, in their order, with the missing reason last.
    const REASONS_AND_NONE: [Option<ScanReason>; 6] = [
        Some(ScanReason::First),
        Some(ScanReason::WatchStart),
        Some(ScanReason::Burst),
        Some(ScanReason::Interval),
        Some(ScanReason::WarmUp),
        None,
    ];

    /// row: cadence: armsWarmUp is true for first, watch-start and burst only
    #[test]
    fn arms_warm_up_is_true_for_first_watch_start_and_burst_only() {
        let armed: Vec<bool> = REASONS_AND_NONE.into_iter().map(arms_warm_up).collect();
        assert_eq!(armed, vec![true, true, true, false, false, false]);
    }

    /// row: cadence: isTriggeredScan is true for watch-start and burst only
    #[test]
    fn is_triggered_scan_is_true_for_watch_start_and_burst_only() {
        let triggered: Vec<bool> = REASONS_AND_NONE
            .into_iter()
            .map(is_triggered_scan)
            .collect();
        assert_eq!(triggered, vec![false, true, true, false, false, false]);
    }

    /// row: cadence: pressureBandIndex follows the band thresholds and passes no data through
    ///
    /// `pressureBandIndex` only returns `pressureBand`, so this is `pressure_band` itself.
    #[test]
    fn pressure_band_index_follows_the_band_thresholds_and_passes_no_data_through() {
        let inputs = [
            Some(0.0),
            Some(9.9),
            Some(10.0),
            Some(24.9),
            Some(25.0),
            Some(49.9),
            Some(50.0),
            Some(100.0),
            None,
        ];
        let bands: Vec<Option<u8>> = inputs.into_iter().map(pressure_band).collect();
        let expected = [0, 0, 1, 1, 2, 2, 3, 3].map(Some).into_iter().chain([None]);
        assert_eq!(bands, expected.collect::<Vec<_>>());
    }

    /// `decideAppScan` run under gjs on the states that are not ordinary numbers: a NaN counter
    /// is not null and compares false, so no cooldown is out and no interval is due; a NaN or
    /// equal-infinity CPU pair never bursts; an infinite rise does; bands are compared by index
    /// over the current bands, a missing index on either side never bursts, a NaN band never does.
    #[test]
    fn states_with_values_that_are_not_ordinary_numbers_decide_as_gjs_does() {
        let cases: [(CadenceState, Option<ScanReason>); 11] = [
            (
                CadenceState {
                    ticks_since_last_scan: Some(f64::NAN),
                    ..quiet_state()
                },
                None,
            ),
            (
                CadenceState {
                    watch_started_this_tick: true,
                    ticks_since_triggered_scan: Some(f64::NAN),
                    ..quiet_state()
                },
                None,
            ),
            (
                CadenceState {
                    cpu_busy_percent_now: Some(90.0),
                    ticks_since_triggered_scan: Some(f64::NAN),
                    ..quiet_state()
                },
                None,
            ),
            (
                CadenceState {
                    cpu_busy_percent_now: Some(f64::NAN),
                    ..quiet_state()
                },
                None,
            ),
            (
                CadenceState {
                    cpu_busy_percent_now: Some(f64::INFINITY),
                    cpu_busy_percent_at_last_scan: Some(f64::INFINITY),
                    ..quiet_state()
                },
                None,
            ),
            (
                CadenceState {
                    cpu_busy_percent_now: Some(f64::INFINITY),
                    ..quiet_state()
                },
                Some(ScanReason::Burst),
            ),
            (
                CadenceState {
                    pressure_bands_at_last_scan: vec![Some(0.0)],
                    pressure_bands_now: bands([Some(0.0), Some(3.0), Some(3.0)]),
                    ..quiet_state()
                },
                None,
            ),
            (
                CadenceState {
                    pressure_bands_at_last_scan: vec![Some(0.0); 4],
                    ..quiet_state()
                },
                None,
            ),
            (
                CadenceState {
                    pressure_bands_now: vec![],
                    ..quiet_state()
                },
                None,
            ),
            (
                CadenceState {
                    pressure_bands_now: bands([Some(f64::NAN), Some(0.0), Some(0.0)]),
                    ..quiet_state()
                },
                None,
            ),
            (
                CadenceState {
                    is_watched: false,
                    ticks_since_last_scan: Some(f64::INFINITY),
                    ..quiet_state()
                },
                Some(ScanReason::Interval),
            ),
        ];
        for (index, (state, expected)) in cases.iter().enumerate() {
            assert_eq!(decide_app_scan(state), *expected, "case {index}");
        }
    }
}
