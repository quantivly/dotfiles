//! Which ticks scan, and why (`lib/cadence.js` driven through the sampler).

use super::*;
use crate::cadence::ScanReason;

/// Runs ticks 0 to `last_tick_number` two seconds apart, a watch held from before the first tick or
/// not, and gives each scan's tick and reason; a scan outside a tick has tick `None` (gjs
/// `scanTicksAndReasons`).
pub(super) fn scan_ticks_and_reasons(
    is_watched: bool,
    last_tick_number: u64,
) -> Vec<(Option<u64>, ScanReason)> {
    let scan_count = Rc::new(Cell::new(0));
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_reader(ScanSpottingReader {
            scan_count: Rc::clone(&scan_count),
        })
        .build();
    let mut scans = Vec::new();
    test_sampler.sampler.initialize();
    test_sampler.sampler.set_detail_watched(is_watched);
    if let (1.., Some(reason)) = (
        scan_count.get(),
        test_sampler.sampler.last_app_scan_reason(),
    ) {
        scans.push((None, reason));
    }
    for tick_number in 0..=last_tick_number {
        let scan_count_before = scan_count.get();
        test_sampler.advance_clock(SAMPLE_SPACING_USEC);
        test_sampler.sampler.run_tick(tick_number);
        if scan_count.get() > scan_count_before {
            scans.push((
                Some(tick_number),
                test_sampler.sampler.last_app_scan_reason().unwrap(),
            ));
        }
    }
    scans
}

/// row: service sampler: unwatched, a fresh sampler scans at tick 0 (first), 1 (warm-up) and 31, and no other
#[test]
fn unwatched_a_fresh_sampler_scans_at_tick_0_1_and_31_and_no_other() {
    assert_eq!(
        scan_ticks_and_reasons(false, FIRST_UNWATCHED_INTERVAL_SCAN_TICK + 4),
        [
            (Some(0), ScanReason::First),
            (Some(1), ScanReason::WarmUp),
            (
                Some(FIRST_UNWATCHED_INTERVAL_SCAN_TICK),
                ScanReason::Interval
            ),
        ]
    );
}
