//! `ServiceFace`'s rows: the rows of `gnome-shell/tests/service-dbus.test.js` that have a
//! counterpart without a bus. A publish is `next_sample`, `GetState` is `state_text`, and a caller
//! whose connection closed is `drop_sender`. The rows that read the state hand it the snapshot and
//! the histories (`state_text_from_parts`), as the gjs rows push them on a fake sampler; one more
//! row holds `state_text` to the real sampler's own, over a fixture root.
//!
//! Not ported here: the last row, whose subject is the bus (an object exported, then unexported):
//! it is carried by the program's rows on a private bus (`tests/carried-rows-exempt.txt`).

use super::*;
use crate::apps::{AppRanking, CpuRankEntry, MemoryRankEntry};
use crate::memory::{MemoryUsage, SwapSummary};
use crate::ports::{Clock, FileSystemLister, FileSystemReader};
use crate::sampler::{AppendedHistory, ClusterPercents, PressureAvg10, SamplerPorts};
use serde_json::{json, Value};
use std::cell::Cell;
use std::num::NonZeroUsize;
use std::path::{Path, PathBuf};
use std::rc::Rc;

const SERVICE_STARTED_AT_USEC: u64 = 1_794_000_000_000_000;
const SAMPLED_AT_USEC: u64 = 1_794_000_002_000_000;
/// How much later a second publish happens, in real microseconds.
const LATER_PUBLISH_OFFSET_USEC: u64 = 2_000_000;
const FIRST_TICK_USEC: u64 = 100_000_000;
const HISTORY_CAPACITY: usize = 150;
const CLOCK_LABEL: &str = "14:02";
/// The first sender of a row, and the second: unique bus names look like this.
const FIRST_SENDER: &str = ":1.10";
const SECOND_SENDER: &str = ":1.11";

/// A clock a row moves, shared with the sampler that reads it.
struct SharedClock {
    monotonic_usec: Rc<Cell<u64>>,
}

impl Clock for SharedClock {
    /// The time the row set.
    fn monotonic_usec(&self) -> u64 {
        self.monotonic_usec.get()
    }

    /// The same label always.
    fn clock_label(&self) -> Result<String, String> {
        Ok(CLOCK_LABEL.to_string())
    }
}

/// The fixture roots the gjs rows read.
fn fixture_root(root_name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../gnome-shell/tests/fixtures")
        .join(root_name)
}

/// A sampler over `root-a` on a clock the row moves, and that clock.
fn fixture_sampler() -> (Sampler, Rc<Cell<u64>>) {
    let monotonic_usec = Rc::new(Cell::new(FIRST_TICK_USEC));
    let ports = SamplerPorts {
        reader: Box::new(FileSystemReader),
        lister: Box::new(FileSystemLister),
        clock: Box::new(SharedClock {
            monotonic_usec: Rc::clone(&monotonic_usec),
        }),
        resolve_app_name: Box::new(|_| None),
        log: Box::new(|_| {}),
    };
    let mut sampler = Sampler::new(fixture_root("root-a"), ports);
    sampler.initialize();
    (sampler, monotonic_usec)
}

/// A service face with no watch, started at the row's start time.
fn new_face() -> ServiceFace {
    ServiceFace::new(SERVICE_STARTED_AT_USEC)
}

/// A text parsed as JSON.
fn parsed(text: &str) -> Value {
    serde_json::from_str(text).unwrap()
}

/// `TICK_SNAPSHOT` of `service-dbus.test.js`: a snapshot with every field set.
fn tick_snapshot() -> Snapshot {
    let editor_cpu = CpuRankEntry {
        group_key: "app:org.example.Editor".to_string(),
        name: "Editor".to_string(),
        cpu_percent: 31.0,
    };
    let editor_memory = MemoryRankEntry {
        group_key: "app:org.example.Editor".to_string(),
        name: "Editor".to_string(),
        memory_bytes: 2_000_000_000.0,
    };
    Snapshot {
        taken_at_usec: Some(123_000_000),
        taken_at_clock_label: Some("14:02".to_string()),
        cpu_busy_percent: Some(50.0),
        cpu_clusters: Some(ClusterPercents {
            performance_percent: Some(60.0),
            efficiency_percent: Some(20.0),
        }),
        memory: Some(MemoryUsage {
            used_bytes: 8_000_000_000.0,
            total_bytes: 32_000_000_000.0,
        }),
        swap: Some(SwapSummary {
            zram_used_bytes: 0.0,
            zram_ram_bytes: 0.0,
            disk_bytes: 0.0,
        }),
        pressure_avg10: PressureAvg10 {
            cpu: Some(0.5),
            memory: Some(0.0),
            io: Some(0.0),
        },
        apps: Some(AppRanking {
            top_cpu: Some(editor_cpu.clone()),
            top_memory: Some(editor_memory.clone()),
            cpu_ranking: vec![editor_cpu],
            memory_ranking: vec![editor_memory],
        }),
        is_complete: true,
    }
}

/// `TICK_SNAPSHOT`'s JSON, as `service-dbus.test.js` expects it back.
fn tick_snapshot_json() -> Value {
    json!({
        "takenAtUsec": 123_000_000,
        "takenAtClockLabel": "14:02",
        "cpuBusyPercent": 50,
        "cpuClusters": {"performancePercent": 60, "efficiencyPercent": 20},
        "memory": {"usedBytes": 8_000_000_000_u64, "totalBytes": 32_000_000_000_u64},
        "swap": {"zramUsedBytes": 0, "zramRamBytes": 0, "diskBytes": 0},
        "pressureAvg10": {"cpu": 0.5, "memory": 0, "io": 0},
        "apps": {
            "topCpu": {"groupKey": "app:org.example.Editor", "name": "Editor", "cpuPercent": 31},
            "topMemory": {"groupKey": "app:org.example.Editor", "name": "Editor", "memoryBytes": 2_000_000_000_u64},
            "cpuRanking": [{"groupKey": "app:org.example.Editor", "name": "Editor", "cpuPercent": 31}],
            "memoryRanking": [{"groupKey": "app:org.example.Editor", "name": "Editor", "memoryBytes": 2_000_000_000_u64}],
        },
        "isComplete": true,
    })
}

/// What a watch start's reveal publishes in `service-dbus.test.js`: the tick's values with a new
/// top CPU entry.
fn reveal_snapshot() -> Snapshot {
    let mut snapshot = tick_snapshot();
    if let Some(apps) = snapshot.apps.as_mut() {
        apps.top_cpu = Some(CpuRankEntry {
            group_key: "herdr-server".to_string(),
            name: "herdr agents".to_string(),
            cpu_percent: 40.0,
        });
    }
    snapshot
}

/// `REVEAL_SNAPSHOT`'s JSON.
fn reveal_snapshot_json() -> Value {
    let mut snapshot = tick_snapshot_json();
    snapshot["apps"]["topCpu"] =
        json!({"groupKey": "herdr-server", "name": "herdr agents", "cpuPercent": 40});
    snapshot
}

/// A history holding these values, oldest first.
fn history_of(values: &[Option<f64>]) -> RingBuffer {
    let mut history = RingBuffer::new(NonZeroUsize::new(HISTORY_CAPACITY).unwrap());
    for value in values {
        history.push(*value);
    }
    history
}

/// row: service D-Bus: before any sample GetState answers protocol 1, sequence 0, the start time and the histories
#[test]
fn before_any_sample_get_state_answers_protocol_1_sequence_0_the_start_time_and_the_histories() {
    let face = new_face();
    let cpu_history = history_of(&[Some(0.25), None]);
    let memory_history = history_of(&[Some(0.5), Some(0.6)]);
    assert_eq!(
        parsed(&face.state_text_from_parts(None, &cpu_history, &memory_history)),
        json!({
            "protocol": 1,
            "snapshot": null,
            "histories": {"cpu": [0.25, null], "memory": [0.5, 0.6]},
            "serviceStartedAtUsec": SERVICE_STARTED_AT_USEC,
            "latestSampledAtUsec": null,
            "sequence": 0,
        })
    );
}

/// row: service D-Bus: each publish sends one Sample (sequence from 1; a reveal appends nothing), and GetState follows
#[test]
fn each_publish_sends_one_sample_sequence_from_1_a_reveal_appends_nothing_and_get_state_follows() {
    let mut face = new_face();
    let mut cpu_history = history_of(&[]);
    let mut memory_history = history_of(&[]);
    let tick_publish = Publish {
        snapshot: tick_snapshot(),
        appended_history: Some(AppendedHistory {
            cpu: Some(0.5),
            memory: Some(0.25),
        }),
    };
    // As the sampler does: a tick appends to the histories before it publishes, a reveal does not.
    cpu_history.push(Some(0.5));
    memory_history.push(Some(0.25));
    let tick_text = face.next_sample(&tick_publish, SAMPLED_AT_USEC);
    let reveal_publish = Publish {
        snapshot: reveal_snapshot(),
        appended_history: None,
    };
    let reveal_text = face.next_sample(&reveal_publish, SAMPLED_AT_USEC);
    let reveal_snapshot_value = reveal_snapshot();
    let state_text =
        face.state_text_from_parts(Some(&reveal_snapshot_value), &cpu_history, &memory_history);
    assert_eq!(
        (
            parsed(&tick_text),
            parsed(&reveal_text),
            parsed(&state_text)
        ),
        (
            json!({
                "snapshot": tick_snapshot_json(),
                "appendedHistory": {"cpu": 0.5, "memory": 0.25},
                "sequence": 1,
                "sampledAtUsec": SAMPLED_AT_USEC,
            }),
            json!({
                "snapshot": reveal_snapshot_json(),
                "appendedHistory": null,
                "sequence": 2,
                "sampledAtUsec": SAMPLED_AT_USEC,
            }),
            json!({
                "protocol": 1,
                "snapshot": reveal_snapshot_json(),
                "histories": {"cpu": [0.5], "memory": [0.25]},
                "serviceStartedAtUsec": SERVICE_STARTED_AT_USEC,
                "latestSampledAtUsec": SAMPLED_AT_USEC,
                "sequence": 2,
            })
        )
    );
}

/// row: service D-Bus: GetState's latestSampledAtUsec is the real time of the latest publish, a reveal's included
#[test]
fn get_state_latest_sampled_at_usec_is_the_real_time_of_the_latest_publish_a_reveals_included() {
    let mut face = new_face();
    let (cpu_history, memory_history) = (history_of(&[]), history_of(&[]));
    let latest_sampled_at_usec = |face: &ServiceFace| {
        parsed(&face.state_text_from_parts(None, &cpu_history, &memory_history))
            ["latestSampledAtUsec"]
            .clone()
    };
    let tick_publish = Publish {
        snapshot: tick_snapshot(),
        appended_history: Some(AppendedHistory {
            cpu: Some(0.5),
            memory: Some(0.25),
        }),
    };
    let reveal_publish = Publish {
        snapshot: reveal_snapshot(),
        appended_history: None,
    };
    let reveal_real_usec = SAMPLED_AT_USEC + LATER_PUBLISH_OFFSET_USEC;
    face.next_sample(&tick_publish, SAMPLED_AT_USEC);
    let after_tick = latest_sampled_at_usec(&face);
    face.next_sample(&reveal_publish, reveal_real_usec);
    let after_reveal = latest_sampled_at_usec(&face);
    assert_eq!(
        (after_tick, after_reveal),
        (json!(SAMPLED_AT_USEC), json!(reveal_real_usec))
    );
}

/// `state_text` reads the sampler's snapshot and both histories (and not the other way round):
/// after a tick over a fixture, it writes what `state_text_from_parts` writes for the sampler's own.
#[test]
fn state_text_is_the_state_of_the_samplers_snapshot_and_histories() {
    let (mut sampler, _) = fixture_sampler();
    let mut face = new_face();
    let publish = sampler.run_tick(0);
    face.next_sample(&publish, SAMPLED_AT_USEC);
    let from_sampler = face.state_text(&sampler);
    let from_parts = face.state_text_from_parts(
        sampler.latest_snapshot(),
        sampler.cpu_history(),
        sampler.memory_history(),
    );
    let state = parsed(&from_sampler);
    assert_eq!(from_sampler, from_parts);
    // root-a's first tick: no CPU yet (a gap), memory 20,000,000 of 32,000,000 KiB.
    assert_eq!(
        state["histories"],
        json!({"cpu": [null], "memory": [0.625]})
    );
    assert_eq!(state["snapshot"]["takenAtUsec"], json!(FIRST_TICK_USEC));
}

/// row: service D-Bus: a caller that closes its connection holding a watch loses it: setDetailWatched(false) in 2 s
///
/// The bus's own part, the name vanishing within 2 s, is the program's (task 13); this is what the
/// face does when told the caller is gone.
#[test]
fn a_caller_that_closes_its_connection_holding_a_watch_loses_it_set_detail_watched_false() {
    let mut face = new_face();
    let watch_taken = face.add_watch(FIRST_SENDER);
    let after_vanishing = face.drop_sender(FIRST_SENDER);
    assert_eq!(
        (watch_taken, after_vanishing),
        (
            WatchChange {
                any_watch_changed: true,
                sender_has_watches: true,
                sender_had_watches: false
            },
            WatchChange {
                any_watch_changed: true,
                sender_has_watches: false,
                sender_had_watches: true
            }
        )
    );
}

/// row: service D-Bus: a caller holding two watches that vanishes drops both: setDetailWatched(false), count 0
#[test]
fn a_caller_holding_two_watches_that_vanishes_drops_both_set_detail_watched_false_count_0() {
    let mut face = new_face();
    let first_watch = face.add_watch(FIRST_SENDER);
    let second_watch = face.add_watch(FIRST_SENDER);
    let count_while_watched = face.detail_watch_count();
    let after_vanishing = face.drop_sender(FIRST_SENDER);
    assert_eq!(
        (
            first_watch.any_watch_changed,
            second_watch.any_watch_changed,
            count_while_watched,
            after_vanishing.any_watch_changed,
            after_vanishing.sender_has_watches,
            face.detail_watch_count()
        ),
        (true, false, 2, true, false, 0)
    );
}

/// row: service D-Bus: two watches from one caller need two unwatches
#[test]
fn two_watches_from_one_caller_need_two_unwatches() {
    let mut face = new_face();
    let changes = [
        face.add_watch(FIRST_SENDER),
        face.add_watch(FIRST_SENDER),
        face.remove_watch(FIRST_SENDER),
        face.remove_watch(FIRST_SENDER),
    ];
    let sampler_is_told: Vec<bool> = changes
        .iter()
        .map(|change| change.any_watch_changed)
        .collect();
    let caller_holds_watches: Vec<bool> = changes
        .iter()
        .map(|change| change.sender_has_watches)
        .collect();
    // Heard by the sampler: watched at the first, unwatched at the last; nothing in between.
    assert_eq!(sampler_is_told, [true, false, false, true]);
    assert_eq!(caller_holds_watches, [true, true, true, false]);
}

/// row: service D-Bus: UnwatchDetail from a caller holding no watch is a no-op, not an error
#[test]
fn unwatch_detail_from_a_caller_holding_no_watch_is_a_no_op_not_an_error() {
    let mut face = new_face();
    let lone_unwatch = face.remove_watch(SECOND_SENDER);
    let watch_taken = face.add_watch(FIRST_SENDER);
    let unwatch_beside_a_watch = face.remove_watch(SECOND_SENDER);
    let no_change = WatchChange {
        any_watch_changed: false,
        sender_has_watches: false,
        sender_had_watches: false,
    };
    // The sampler is told once, of the one watch: the idle caller's unwatches say nothing.
    assert_eq!(
        (
            lone_unwatch,
            watch_taken.any_watch_changed,
            unwatch_beside_a_watch,
            face.detail_watch_count()
        ),
        (no_change, true, no_change, 1)
    );
}

/// row: service D-Bus: one caller vanishing leaves another's watch, and the sampler hears only changes
#[test]
fn one_caller_vanishing_leaves_anothers_watch_and_the_sampler_hears_only_changes() {
    let mut face = new_face();
    let first_watch = face.add_watch(FIRST_SENDER);
    let second_watch = face.add_watch(SECOND_SENDER);
    let count_with_both = face.detail_watch_count();
    let vanishing = face.drop_sender(FIRST_SENDER);
    let count_after_vanishing = face.detail_watch_count();
    let last_unwatch = face.remove_watch(SECOND_SENDER);
    assert_eq!(
        (
            first_watch.any_watch_changed,
            second_watch.any_watch_changed,
            count_with_both,
            vanishing.any_watch_changed,
            vanishing.sender_has_watches,
            count_after_vanishing,
            last_unwatch.any_watch_changed
        ),
        (true, false, 2, false, false, 1, true)
    );
}

#[test]
fn dropping_a_sender_that_holds_no_watch_changes_nothing() {
    let mut face = new_face();
    face.add_watch(FIRST_SENDER);
    let dropped = face.drop_sender(SECOND_SENDER);
    assert_eq!(
        (
            dropped.any_watch_changed,
            dropped.sender_had_watches,
            face.detail_watch_count()
        ),
        (false, false, 1)
    );
}

#[test]
fn the_sequence_moves_on_for_every_publish_even_one_nobody_receives() {
    let (mut sampler, _) = fixture_sampler();
    let mut face = new_face();
    let publish = sampler.run_tick(0);
    let sequences: Vec<Value> = (0..3)
        .map(|_| parsed(&face.next_sample(&publish, SAMPLED_AT_USEC))["sequence"].clone())
        .collect();
    assert_eq!(sequences, [json!(1), json!(2), json!(3)]);
}
