//! A detail watch: the watched cadence, and the scan and publish a watch start makes outside the
//! tick (`set_detail_watched`, gjs `setDetailWatched` and `_scanForWatchStart`).

use super::*;
use crate::cadence::ScanReason;

/// The last tick `SamplerPastItsWarmUp` runs: ticks 0 (first scan), 1 (warm-up scan), 2 and 3 (no
/// scan).
const WARM_UP_SETUP_LAST_TICK: u64 = 3;
/// 150 ms: well inside the shortest window a CPU ranking may cover (1 s).
const WITHIN_CPU_RANKING_WINDOW_USEC: u64 = 150_000;

/// A sampler on root-a that counts its app scans and records what it publishes, run through ticks 0
/// to 3: the first scan, the warm-up scan, then two quiet ticks (gjs `makeSamplerPastItsWarmUp`).
/// What a listener would hear is what `run_tick` and `set_detail_watched` return.
struct SamplerPastItsWarmUp {
    test_sampler: TestSampler,
    scan_count: Rc<Cell<u64>>,
    published: Vec<Publish>,
}

impl SamplerPastItsWarmUp {
    fn new() -> SamplerPastItsWarmUp {
        let scan_count = Rc::new(Cell::new(0));
        let test_sampler = SamplerSetup::at_fixture("root-a")
            .with_reader(ScanSpottingReader {
                scan_count: Rc::clone(&scan_count),
            })
            .build();
        let mut past_warm_up = SamplerPastItsWarmUp {
            test_sampler,
            scan_count,
            published: Vec::new(),
        };
        past_warm_up.test_sampler.sampler.initialize();
        for tick_number in 0..=WARM_UP_SETUP_LAST_TICK {
            past_warm_up.tick(tick_number);
        }
        past_warm_up
    }

    /// Moves the clock two seconds on and runs a tick, recording its publish.
    fn tick(&mut self, tick_number: u64) {
        self.test_sampler.advance_clock(SAMPLE_SPACING_USEC);
        let publish = self.test_sampler.sampler.run_tick(tick_number);
        self.published.push(publish);
    }

    /// Starts or ends a watch, recording what it publishes.
    fn set_detail_watched(&mut self, is_watched: bool) {
        if let Some(publish) = self.test_sampler.sampler.set_detail_watched(is_watched) {
            self.published.push(publish);
        }
    }

    /// [scans, publishes] so far.
    fn counts(&self) -> (u64, usize) {
        (self.scan_count.get(), self.published.len())
    }
}

/// row: service sampler: watched from before the first tick, it scans at tick 0 (first), 1 (warm-up), 11 and 21
#[test]
fn watched_from_before_the_first_tick_it_scans_at_tick_0_1_11_and_21() {
    // A watch started before any tick does not scan at once: the first tick scans anyway.
    assert_eq!(
        super::cadence::scan_ticks_and_reasons(true, 25),
        [
            (Some(0), ScanReason::First),
            (Some(1), ScanReason::WarmUp),
            (Some(11), ScanReason::Interval),
            (Some(21), ScanReason::Interval),
        ]
    );
}

/// row: service sampler: a watch start scans at once and publishes the latest fast-tick values with the new ranking, appending no history
#[test]
fn a_watch_start_scans_at_once_and_publishes_the_latest_fast_tick_values_with_the_new_ranking() {
    let mut past_warm_up = SamplerPastItsWarmUp::new();
    let last_tick_snapshot = past_warm_up
        .test_sampler
        .sampler
        .latest_snapshot()
        .unwrap()
        .clone();
    let history_length_before = past_warm_up
        .test_sampler
        .sampler
        .cpu_history()
        .values()
        .len();
    let (scans_before, published_before) = past_warm_up.counts();
    // The last scan ran at tick 1 (4 s); against root-b 6 s later, herdr's 6 s of CPU on 2 CPUs is
    // 50%.
    past_warm_up.test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    past_warm_up
        .test_sampler
        .sampler
        .set_fs_root(fixture_root("root-b"));
    past_warm_up.set_detail_watched(true);
    let reveal = past_warm_up.published.last().unwrap().clone();
    let sampler = &past_warm_up.test_sampler.sampler;
    let (scans_after, published_after) = past_warm_up.counts();
    assert_eq!(
        (
            published_after - published_before,
            scans_after - scans_before,
            sampler.last_app_scan_reason(),
            reveal.appended_history,
            sampler.cpu_history().values().len() - history_length_before,
        ),
        (1, 1, Some(ScanReason::WatchStart), None, 0)
    );
    assert_eq!(
        Snapshot {
            apps: None,
            ..reveal.snapshot.clone()
        },
        Snapshot {
            apps: None,
            ..last_tick_snapshot
        }
    );
    assert_eq!(
        reveal
            .snapshot
            .apps
            .as_ref()
            .and_then(|apps| apps.top_cpu.clone()),
        Some(cpu_entry("unit:herdr-server", "herdr agents", 50.0))
    );
    assert_eq!(sampler.latest_snapshot(), Some(&reveal.snapshot));
}

/// row: service sampler: a watch start inside the reveal cooldown does not scan; the warm-up follows on the next tick; unwatching only changes the cadence
#[test]
fn a_watch_start_inside_the_reveal_cooldown_does_not_scan_the_warm_up_follows_on_the_next_tick() {
    let mut past_warm_up = SamplerPastItsWarmUp::new();
    past_warm_up.set_detail_watched(true);
    let after_first_watch_start = past_warm_up.counts();
    let apps_after_first_watch_start = past_warm_up
        .test_sampler
        .sampler
        .latest_snapshot()
        .unwrap()
        .apps
        .clone();
    past_warm_up.set_detail_watched(false);
    let after_unwatch = past_warm_up.counts();
    let is_ranking_kept_after_unwatch = past_warm_up
        .test_sampler
        .sampler
        .latest_snapshot()
        .unwrap()
        .apps
        == apps_after_first_watch_start;
    past_warm_up.set_detail_watched(true);
    let after_watch_start_in_cooldown = past_warm_up.counts();
    past_warm_up.tick(WARM_UP_SETUP_LAST_TICK + 1);
    let reason_of_next_tick_scan = past_warm_up.test_sampler.sampler.last_app_scan_reason();
    let after_next_tick = past_warm_up.counts();
    past_warm_up.tick(WARM_UP_SETUP_LAST_TICK + 2);
    let after_second_tick = past_warm_up.counts();
    // Two ticks (REVEAL_SCAN_COOLDOWN_TICKS) after the watch-start scan, made after tick 3, a watch
    // start scans again.
    past_warm_up.set_detail_watched(false);
    past_warm_up.set_detail_watched(true);
    let after_cooled_watch_start = past_warm_up.counts();
    let (scans_at_start, publishes_at_start) = after_first_watch_start;
    assert_eq!(
        (
            after_unwatch,
            is_ranking_kept_after_unwatch,
            after_watch_start_in_cooldown,
            reason_of_next_tick_scan,
            after_next_tick,
            after_second_tick,
            after_cooled_watch_start,
        ),
        (
            after_first_watch_start,
            true,
            after_first_watch_start,
            Some(ScanReason::WarmUp),
            (scans_at_start + 1, publishes_at_start + 1),
            (scans_at_start + 1, publishes_at_start + 2),
            (scans_at_start + 2, publishes_at_start + 3),
        )
    );
}

/// row: service sampler: a watch start right after a scan neither scans nor publishes, arms no warm-up, and still switches to the watched cadence
#[test]
fn a_watch_start_right_after_a_scan_neither_scans_nor_publishes_arms_no_warm_up_and_still_switches_cadence(
) {
    // The client already has the ranking that scan published, and a new one over 150 ms would rank
    // noise.
    let scan_count = Rc::new(Cell::new(0));
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_reader(ScanSpottingReader {
            scan_count: Rc::clone(&scan_count),
        })
        .build();
    let mut scan_tick_numbers: Vec<Option<u64>> = Vec::new();
    let mut run_tick_noting_scan = |test_sampler: &mut TestSampler, tick_number: u64| {
        let scan_count_before = scan_count.get();
        test_sampler.advance_clock(SAMPLE_SPACING_USEC);
        test_sampler.sampler.run_tick(tick_number);
        if scan_count.get() > scan_count_before {
            scan_tick_numbers.push(Some(tick_number));
        }
    };
    test_sampler.sampler.initialize();
    for tick_number in 0..=1 {
        run_tick_noting_scan(&mut test_sampler, tick_number);
    }
    test_sampler.advance_clock(WITHIN_CPU_RANKING_WINDOW_USEC);
    let scan_count_before_watch_start = scan_count.get();
    let published_by_watch_start = test_sampler.sampler.set_detail_watched(true);
    let scans_by_watch_start = scan_count.get() - scan_count_before_watch_start;
    for tick_number in 2..=12 {
        run_tick_noting_scan(&mut test_sampler, tick_number);
    }
    // Watched, the next scan is 10 ticks after the warm-up at tick 1 (unwatched it would be 30).
    assert_eq!(
        (
            published_by_watch_start,
            scans_by_watch_start,
            scan_tick_numbers
        ),
        (None, 0, vec![Some(0), Some(1), Some(11)])
    );
}

/// row: service sampler: a warm-up due 150 ms after a watch-start scan waits one tick, then runs
#[test]
fn a_warm_up_due_150_ms_after_a_watch_start_scan_waits_one_tick_then_runs() {
    let mut past_warm_up = SamplerPastItsWarmUp::new();
    past_warm_up.test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    past_warm_up.set_detail_watched(true);
    let (scans_after_watch_start, _) = past_warm_up.counts();
    let scans_since_watch_start = |past_warm_up: &SamplerPastItsWarmUp| {
        (
            past_warm_up.scan_count.get() - scans_after_watch_start,
            past_warm_up.test_sampler.sampler.last_app_scan_reason(),
        )
    };
    past_warm_up
        .test_sampler
        .advance_clock(WITHIN_CPU_RANKING_WINDOW_USEC);
    let publish = past_warm_up
        .test_sampler
        .sampler
        .run_tick(WARM_UP_SETUP_LAST_TICK + 1);
    past_warm_up.published.push(publish);
    let after_short_window_tick = scans_since_watch_start(&past_warm_up);
    past_warm_up.tick(WARM_UP_SETUP_LAST_TICK + 2);
    let after_next_tick = scans_since_watch_start(&past_warm_up);
    assert_eq!(
        (after_short_window_tick, after_next_tick),
        (
            (0, Some(ScanReason::WatchStart)),
            (1, Some(ScanReason::WarmUp))
        )
    );
}

/// row: service sampler: a watch start after a tick whose sample threw publishes nothing, and its no-data snapshot keeps apps null; the next tick that samples carries the ranking
#[test]
fn a_watch_start_after_a_tick_whose_sample_threw_publishes_nothing_and_the_next_tick_carries_the_ranking(
) {
    let is_clock_broken = Rc::new(Cell::new(false));
    let mut test_sampler = SamplerSetup::at_fixture("root-a")
        .with_clock_label(breakable_clock_label(&is_clock_broken))
        .build();
    test_sampler.sampler.initialize();
    for tick_number in 0..=WARM_UP_SETUP_LAST_TICK {
        is_clock_broken.set(tick_number == WARM_UP_SETUP_LAST_TICK);
        test_sampler.advance_clock(SAMPLE_SPACING_USEC);
        test_sampler.sampler.run_tick(tick_number);
    }
    let no_data_snapshot = test_sampler.sampler.latest_snapshot().unwrap().clone();
    let published_by_watch_start = test_sampler.sampler.set_detail_watched(true);
    let after_watch_start = (
        published_by_watch_start,
        test_sampler.sampler.latest_snapshot() == Some(&no_data_snapshot),
        no_data_snapshot.apps.clone(),
    );
    is_clock_broken.set(false);
    test_sampler.advance_clock(SAMPLE_SPACING_USEC);
    test_sampler.sampler.run_tick(WARM_UP_SETUP_LAST_TICK + 1);
    let apps_of_next_tick = test_sampler.sampler.latest_snapshot().unwrap().apps.clone();
    assert_eq!(
        (after_watch_start, apps_of_next_tick.is_some()),
        ((None, true, None), true)
    );
}
