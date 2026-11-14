//! The JSON text of a `Sample` signal and of the `GetState` reply, ported from `buildSamplePayload`
//! and `buildStatePayload` in `lib/protocol.js`.
//!
//! The writer is hand-written, because the shape is fixed and the state's text is itself contract:
//! `gnome-status` cuts it as text, from the part before `"snapshot":`, so the state is compact and
//! writes `protocol`, the two times and the sequence before the snapshot. Every field is written
//! explicitly, in the order of `service/sampler.js`'s `Snapshot` typedef.
//!
//! Numbers: a whole number is written as plain digits (no fraction, no exponent, no sign unless
//! negative), a negative zero as `0`, a number that is not finite as `null` (as `JSON.stringify`
//! writes it), and any other number with the fewest digits that a correctly rounding parser reads
//! back as the same double. An integer field is written from the integer, never through a float.
//! The spelling need not be JavaScript's, only the value.

use crate::apps::{AppRanking, CpuRankEntry, MemoryRankEntry};
use crate::constants::PROTOCOL_VERSION;
use crate::history::RingBuffer;
use crate::memory::{MemoryUsage, SwapSummary};
use crate::sampler::{AppendedHistory, ClusterPercents, PressureAvg10, Publish, Snapshot};
use std::fmt::Write as _;

/// The text of a control character below U+0020 that JSON has no short escape for: `\u00XX`.
const UNICODE_ESCAPE_DIGITS: usize = 4;
/// The first code point JSON allows in a string without an escape.
const FIRST_UNESCAPED_CODE_POINT: char = ' ';

/// The JSON of one Sample signal (`buildSamplePayload`): the sequence and the real time of the
/// publish, the snapshot, and what the publish appended to the histories (`null` for a reveal).
pub fn sample_payload(publish: &Publish, sequence: u64, sampled_at_usec: u64) -> String {
    let mut text = String::new();
    let mut object = ObjectWriter::open(&mut text);
    object.key("sequence");
    push_integer(object.text, sequence);
    object.key("sampledAtUsec");
    push_integer(object.text, sampled_at_usec);
    object.key("snapshot");
    push_snapshot(object.text, &publish.snapshot);
    object.key("appendedHistory");
    match &publish.appended_history {
        Some(appended_history) => push_appended_history(object.text, appended_history),
        None => push_null(object.text),
    }
    object.close();
    text
}

/// Everything `GetState` answers from: the latest snapshot (`None` before the first publish), both
/// histories, and the service's own times and sequence.
pub struct PublishedState<'a> {
    /// The sampler's latest snapshot, or `None` before the first.
    pub snapshot: Option<&'a Snapshot>,
    /// The CPU busy fractions, oldest first.
    pub cpu_history: &'a RingBuffer,
    /// The memory used fractions, oldest first.
    pub memory_history: &'a RingBuffer,
    /// Real time the service started, in microseconds.
    pub service_started_at_usec: u64,
    /// Real time of the latest publish, in microseconds; `None` before the first.
    pub latest_sampled_at_usec: Option<u64>,
    /// The sequence of the latest Sample sent; 0 before the first.
    pub sequence: u64,
}

/// The JSON `GetState` returns (`buildStatePayload`): `protocol`, the two times and the sequence,
/// then the snapshot, then both histories.
pub fn state_payload(state: &PublishedState) -> String {
    let mut text = String::new();
    let mut object = ObjectWriter::open(&mut text);
    object.key("protocol");
    push_integer(object.text, PROTOCOL_VERSION);
    object.key("serviceStartedAtUsec");
    push_integer(object.text, state.service_started_at_usec);
    object.key("latestSampledAtUsec");
    push_optional_integer(object.text, state.latest_sampled_at_usec);
    object.key("sequence");
    push_integer(object.text, state.sequence);
    object.key("snapshot");
    match state.snapshot {
        Some(snapshot) => push_snapshot(object.text, snapshot),
        None => push_null(object.text),
    }
    object.key("histories");
    push_histories(object.text, state);
    object.close();
    text
}

/// An object under construction: the braces and the commas between its fields.
struct ObjectWriter<'a> {
    /// The text being written; a field's value is pushed here straight after `key`.
    text: &'a mut String,
    has_fields: bool,
}

impl<'a> ObjectWriter<'a> {
    /// Starts an object.
    fn open(text: &'a mut String) -> Self {
        text.push('{');
        Self {
            text,
            has_fields: false,
        }
    }

    /// Starts the next field: its separator, its name and the colon.
    fn key(&mut self, name: &str) {
        if self.has_fields {
            self.text.push(',');
        }
        self.has_fields = true;
        push_string(self.text, name);
        self.text.push(':');
    }

    /// Ends the object.
    fn close(self) {
        self.text.push('}');
    }
}

/// Writes a snapshot, field by field in the typedef's order (`Snapshot` in `service/sampler.js`).
fn push_snapshot(text: &mut String, snapshot: &Snapshot) {
    let mut object = ObjectWriter::open(text);
    object.key("takenAtUsec");
    push_optional_integer(object.text, snapshot.taken_at_usec);
    object.key("takenAtClockLabel");
    match &snapshot.taken_at_clock_label {
        Some(label) => push_string(object.text, label),
        None => push_null(object.text),
    }
    object.key("cpuBusyPercent");
    push_optional_number(object.text, snapshot.cpu_busy_percent);
    object.key("cpuClusters");
    match &snapshot.cpu_clusters {
        Some(clusters) => push_cpu_clusters(object.text, clusters),
        None => push_null(object.text),
    }
    object.key("memory");
    match &snapshot.memory {
        Some(memory) => push_memory(object.text, memory),
        None => push_null(object.text),
    }
    object.key("swap");
    match &snapshot.swap {
        Some(swap) => push_swap(object.text, swap),
        None => push_null(object.text),
    }
    object.key("pressureAvg10");
    push_pressure(object.text, &snapshot.pressure_avg10);
    object.key("apps");
    match &snapshot.apps {
        Some(apps) => push_app_ranking(object.text, apps),
        None => push_null(object.text),
    }
    object.key("isComplete");
    push_boolean(object.text, snapshot.is_complete);
    object.close();
}

/// Writes the busy percent of each core type.
fn push_cpu_clusters(text: &mut String, clusters: &ClusterPercents) {
    let mut object = ObjectWriter::open(text);
    object.key("performancePercent");
    push_optional_number(object.text, clusters.performance_percent);
    object.key("efficiencyPercent");
    push_optional_number(object.text, clusters.efficiency_percent);
    object.close();
}

/// Writes the memory in use and the memory total.
fn push_memory(text: &mut String, memory: &MemoryUsage) {
    let mut object = ObjectWriter::open(text);
    object.key("usedBytes");
    push_number(object.text, memory.used_bytes);
    object.key("totalBytes");
    push_number(object.text, memory.total_bytes);
    object.close();
}

/// Writes the swap in use on zram, the RAM zram takes, and the swap on disk.
fn push_swap(text: &mut String, swap: &SwapSummary) {
    let mut object = ObjectWriter::open(text);
    object.key("zramUsedBytes");
    push_number(object.text, swap.zram_used_bytes);
    object.key("zramRamBytes");
    push_number(object.text, swap.zram_ram_bytes);
    object.key("diskBytes");
    push_number(object.text, swap.disk_bytes);
    object.close();
}

/// Writes the three pressure percentages.
fn push_pressure(text: &mut String, pressure: &PressureAvg10) {
    let mut object = ObjectWriter::open(text);
    object.key("cpu");
    push_optional_number(object.text, pressure.cpu);
    object.key("memory");
    push_optional_number(object.text, pressure.memory);
    object.key("io");
    push_optional_number(object.text, pressure.io);
    object.close();
}

/// Writes an app ranking: the two winners and the two lists.
fn push_app_ranking(text: &mut String, ranking: &AppRanking) {
    let mut object = ObjectWriter::open(text);
    object.key("topCpu");
    match &ranking.top_cpu {
        Some(entry) => push_cpu_entry(object.text, entry),
        None => push_null(object.text),
    }
    object.key("topMemory");
    match &ranking.top_memory {
        Some(entry) => push_memory_entry(object.text, entry),
        None => push_null(object.text),
    }
    object.key("cpuRanking");
    push_array(object.text, &ranking.cpu_ranking, push_cpu_entry);
    object.key("memoryRanking");
    push_array(object.text, &ranking.memory_ranking, push_memory_entry);
    object.close();
}

/// Writes one entry of the CPU ranking.
fn push_cpu_entry(text: &mut String, entry: &CpuRankEntry) {
    let mut object = ObjectWriter::open(text);
    object.key("groupKey");
    push_string(object.text, &entry.group_key);
    object.key("name");
    push_string(object.text, &entry.name);
    object.key("cpuPercent");
    push_number(object.text, entry.cpu_percent);
    object.close();
}

/// Writes one entry of the memory ranking.
fn push_memory_entry(text: &mut String, entry: &MemoryRankEntry) {
    let mut object = ObjectWriter::open(text);
    object.key("groupKey");
    push_string(object.text, &entry.group_key);
    object.key("name");
    push_string(object.text, &entry.name);
    object.key("memoryBytes");
    push_number(object.text, entry.memory_bytes);
    object.close();
}

/// Writes what a fast tick appended to the two histories.
fn push_appended_history(text: &mut String, appended_history: &AppendedHistory) {
    let mut object = ObjectWriter::open(text);
    object.key("cpu");
    push_optional_number(object.text, appended_history.cpu);
    object.key("memory");
    push_optional_number(object.text, appended_history.memory);
    object.close();
}

/// Writes both histories, each oldest first, a gap as `null`.
fn push_histories(text: &mut String, state: &PublishedState) {
    let mut object = ObjectWriter::open(text);
    object.key("cpu");
    push_array(
        object.text,
        &state.cpu_history.values(),
        push_optional_number_ref,
    );
    object.key("memory");
    push_array(
        object.text,
        &state.memory_history.values(),
        push_optional_number_ref,
    );
    object.close();
}

/// Writes a list: its brackets, and each item by `push_item`, with commas between.
fn push_array<T>(text: &mut String, items: &[T], push_item: fn(&mut String, &T)) {
    text.push('[');
    for (index, item) in items.iter().enumerate() {
        if index > 0 {
            text.push(',');
        }
        push_item(text, item);
    }
    text.push(']');
}

/// Writes `null`.
fn push_null(text: &mut String) {
    text.push_str("null");
}

/// Writes `true` or `false`.
fn push_boolean(text: &mut String, value: bool) {
    text.push_str(if value { "true" } else { "false" });
}

/// Writes an integer from the integer: every digit, no float on the way.
fn push_integer(text: &mut String, value: u64) {
    // Writing to a `String` cannot fail.
    let _ = write!(text, "{value}");
}

/// Writes an integer, or `null` for `None`.
fn push_optional_integer(text: &mut String, value: Option<u64>) {
    match value {
        Some(integer) => push_integer(text, integer),
        None => push_null(text),
    }
}

/// The text a number is written as (see the module documentation), for the checks that hold the
/// writer to the values the gjs sampler produced.
pub fn number_text(value: f64) -> String {
    let mut text = String::new();
    push_number(&mut text, value);
    text
}

/// Writes a number as the module documentation says: plain digits for a whole number, `0` for a
/// negative zero, `null` when not finite, else the shortest digits that read back as the same
/// double. Rust's `Display` for `f64` is exactly that: shortest round-trip digits, never an
/// exponent, and no fraction for a whole value.
fn push_number(text: &mut String, value: f64) {
    if !value.is_finite() {
        push_null(text);
    } else if value == 0.0 {
        // Both zeros: `Display` would write a negative zero as `-0`.
        text.push('0');
    } else {
        let _ = write!(text, "{value}");
    }
}

/// Writes a number, or `null` for `None`.
fn push_optional_number(text: &mut String, value: Option<f64>) {
    match value {
        Some(number) => push_number(text, number),
        None => push_null(text),
    }
}

/// `push_optional_number` for a list item, whose writer receives a reference.
fn push_optional_number_ref(text: &mut String, value: &Option<f64>) {
    push_optional_number(text, *value);
}

/// Writes a string between quotes, escaping what JSON requires: the quote, the backslash and every
/// control character below U+0020 (short forms where JSON has them, `\u00XX` otherwise). Everything
/// else is written as it is, as UTF-8.
fn push_string(text: &mut String, value: &str) {
    text.push('"');
    for character in value.chars() {
        match character {
            '"' => text.push_str("\\\""),
            '\\' => text.push_str("\\\\"),
            '\n' => text.push_str("\\n"),
            '\r' => text.push_str("\\r"),
            '\t' => text.push_str("\\t"),
            '\u{8}' => text.push_str("\\b"),
            '\u{c}' => text.push_str("\\f"),
            control if control < FIRST_UNESCAPED_CODE_POINT => {
                let _ = write!(
                    text,
                    "\\u{:0width$x}",
                    u32::from(control),
                    width = UNICODE_ESCAPE_DIGITS
                );
            }
            other => text.push(other),
        }
    }
    text.push('"');
}

#[cfg(test)]
mod tests;
