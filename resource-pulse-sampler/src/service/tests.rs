//! `ServiceFace`'s rows: the rows of `gnome-shell/tests/service-dbus.test.js` that have a
//! counterpart without a bus. A publish is `next_sample`, `GetState` is `state_text`, and a caller
//! whose connection closed is `drop_sender`. The sampler is the real one, over the fixture roots, on
//! a clock the row sets.
//!
//! Not ported here: the last row, whose subject is the bus (an object exported, then unexported):
//! it is carried by the program's rows on a private bus (`tests/carried-rows-exempt.txt`).

use super::*;
use crate::ports::{Clock, FileSystemLister, FileSystemReader};
use crate::sampler::SamplerPorts;
use serde_json::{json, Value};
use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

const SERVICE_STARTED_AT_USEC: u64 = 1_794_000_000_000_000;
const SAMPLED_AT_USEC: u64 = 1_794_000_002_000_000;
/// How much later a second publish happens, in real microseconds.
const LATER_PUBLISH_OFFSET_USEC: u64 = 2_000_000;
const FIRST_TICK_USEC: u64 = 100_000_000;
const TICK_SPACING_USEC: u64 = 2_000_000;
/// A watch 1.5 s after the second tick: past the CPU ranking window, so its scan reveals.
const WATCH_AFTER_SECOND_TICK_USEC: u64 = 1_500_000;
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

/// row: service D-Bus: before any sample GetState answers protocol 1, sequence 0, the start time and the histories
///
/// The gjs row pushes history values by hand on a fake sampler; the real sampler holds history only
/// after a tick, so this one answers empty histories, and the histories' text is pinned by the
/// payload rows and the golden files.
#[test]
fn before_any_sample_get_state_answers_protocol_1_sequence_0_the_start_time_and_the_histories() {
    let (sampler, _) = fixture_sampler();
    let face = new_face();
    assert_eq!(
        parsed(&face.state_text(&sampler)),
        json!({
            "protocol": 1,
            "snapshot": null,
            "histories": {"cpu": [], "memory": []},
            "serviceStartedAtUsec": SERVICE_STARTED_AT_USEC,
            "latestSampledAtUsec": null,
            "sequence": 0,
        })
    );
}

/// row: service D-Bus: each publish sends one Sample (sequence from 1; a reveal appends nothing), and GetState follows
#[test]
fn each_publish_sends_one_sample_sequence_from_1_a_reveal_appends_nothing_and_get_state_follows() {
    let (mut sampler, clock) = fixture_sampler();
    let mut face = new_face();
    let tick_publish = sampler.run_tick(0);
    let first_text = face.next_sample(&tick_publish, SAMPLED_AT_USEC);
    sampler.set_fs_root(fixture_root("root-b"));
    clock.set(FIRST_TICK_USEC + TICK_SPACING_USEC);
    let second_tick_publish = sampler.run_tick(1);
    let second_text = face.next_sample(&second_tick_publish, SAMPLED_AT_USEC);
    clock.set(FIRST_TICK_USEC + TICK_SPACING_USEC + WATCH_AFTER_SECOND_TICK_USEC);
    let reveal_publish = sampler.set_detail_watched(true).unwrap();
    let reveal_text = face.next_sample(&reveal_publish, SAMPLED_AT_USEC);

    let [first, second, reveal] =
        [&first_text, &second_text, &reveal_text].map(|text| parsed(text));
    let state = parsed(&face.state_text(&sampler));
    assert_eq!(
        [
            first["sequence"].clone(),
            second["sequence"].clone(),
            reveal["sequence"].clone()
        ],
        [json!(1), json!(2), json!(3)]
    );
    assert!(first["appendedHistory"].is_object());
    assert!(second["appendedHistory"].is_object());
    assert_eq!(reveal["appendedHistory"], Value::Null);
    assert_eq!(state["sequence"], json!(3));
    assert_eq!(state["snapshot"], reveal["snapshot"]);
    // The reveal appended nothing: two ticks, two history values.
    assert_eq!(state["histories"]["cpu"].as_array().map(Vec::len), Some(2));
    assert_eq!(
        state["histories"]["memory"].as_array().map(Vec::len),
        Some(2)
    );
}

/// row: service D-Bus: GetState's latestSampledAtUsec is the real time of the latest publish, a reveal's included
#[test]
fn get_state_latest_sampled_at_usec_is_the_real_time_of_the_latest_publish_a_reveals_included() {
    let (mut sampler, clock) = fixture_sampler();
    let mut face = new_face();
    let tick_publish = sampler.run_tick(0);
    face.next_sample(&tick_publish, SAMPLED_AT_USEC);
    let after_tick = parsed(&face.state_text(&sampler))["latestSampledAtUsec"].clone();
    sampler.run_tick(1);
    clock.set(FIRST_TICK_USEC + TICK_SPACING_USEC + WATCH_AFTER_SECOND_TICK_USEC);
    let reveal_publish = sampler.set_detail_watched(true).unwrap();
    let reveal_real_usec = SAMPLED_AT_USEC + LATER_PUBLISH_OFFSET_USEC;
    face.next_sample(&reveal_publish, reveal_real_usec);
    let after_reveal = parsed(&face.state_text(&sampler))["latestSampledAtUsec"].clone();
    assert_eq!(
        (after_tick, after_reveal),
        (json!(SAMPLED_AT_USEC), json!(reveal_real_usec))
    );
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
    face.add_watch(FIRST_SENDER);
    let unwatch_beside_a_watch = face.remove_watch(SECOND_SENDER);
    let no_change = WatchChange {
        any_watch_changed: false,
        sender_has_watches: false,
        sender_had_watches: false,
    };
    assert_eq!(
        (
            lone_unwatch,
            unwatch_beside_a_watch,
            face.detail_watch_count()
        ),
        (no_change, no_change, 1)
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
