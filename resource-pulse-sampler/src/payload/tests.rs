//! The writer's rules, pinned: the text of each payload against `lib/protocol.js`'s own output, the
//! state's text as contract, and how numbers and strings are written.
//!
//! The literal payload texts are `buildSamplePayload` and `buildStatePayload` run under gjs on the
//! same values (`TICK_SNAPSHOT` of `service-dbus.test.js`, with a fractional percent and a null
//! pressure added, and a no-data snapshot).

use super::*;
use crate::apps::{AppRanking, CpuRankEntry, MemoryRankEntry};
use crate::memory::{MemoryUsage, SwapSummary};
use crate::sampler::{AppendedHistory, ClusterPercents, PressureAvg10};
use crate::test_support::history_of;

const SEQUENCE: u64 = 1;
const SAMPLED_AT_USEC: u64 = 1_794_000_002_000_000;
const SERVICE_STARTED_AT_USEC: u64 = 1_794_000_000_000_000;

/// The gjs text of a Sample holding `tick_snapshot`, sequence 1, and an appended history.
const GJS_TICK_SAMPLE_TEXT: &str = r#"{"sequence":1,"sampledAtUsec":1794000002000000,"snapshot":{"takenAtUsec":123000000,"takenAtClockLabel":"14:02","cpuBusyPercent":50,"cpuClusters":{"performancePercent":60.5,"efficiencyPercent":20},"memory":{"usedBytes":8000000000,"totalBytes":32000000000},"swap":{"zramUsedBytes":0,"zramRamBytes":0,"diskBytes":0},"pressureAvg10":{"cpu":0.5,"memory":0,"io":null},"apps":{"topCpu":{"groupKey":"app:org.example.Editor","name":"Editor","cpuPercent":31.25},"topMemory":{"groupKey":"app:org.example.Editor","name":"Editor","memoryBytes":2000000000},"cpuRanking":[{"groupKey":"app:org.example.Editor","name":"Editor","cpuPercent":31.25}],"memoryRanking":[{"groupKey":"app:org.example.Editor","name":"Editor","memoryBytes":2000000000}]},"isComplete":true},"appendedHistory":{"cpu":0.5,"memory":0.25}}"#;
/// The gjs text of a reveal's Sample of a no-data snapshot, sequence 2: nothing appended.
const GJS_NO_DATA_REVEAL_SAMPLE_TEXT: &str = r#"{"sequence":2,"sampledAtUsec":1794000004000000,"snapshot":{"takenAtUsec":null,"takenAtClockLabel":null,"cpuBusyPercent":null,"cpuClusters":null,"memory":null,"swap":null,"pressureAvg10":{"cpu":null,"memory":null,"io":null},"apps":null,"isComplete":false},"appendedHistory":null}"#;
/// The gjs text of GetState before any sample, with a gap in the CPU history.
const GJS_STATE_BEFORE_ANY_SAMPLE_TEXT: &str = r#"{"protocol":1,"serviceStartedAtUsec":1794000000000000,"latestSampledAtUsec":null,"sequence":0,"snapshot":null,"histories":{"cpu":[0.25,null],"memory":[0.5,0.6]}}"#;
/// The gjs text of GetState after two publishes, with empty histories.
const GJS_STATE_WITH_SNAPSHOT_TEXT: &str = r#"{"protocol":1,"serviceStartedAtUsec":1794000000000000,"latestSampledAtUsec":1794000004000000,"sequence":2,"snapshot":{"takenAtUsec":123000000,"takenAtClockLabel":"14:02","cpuBusyPercent":50,"cpuClusters":{"performancePercent":60.5,"efficiencyPercent":20},"memory":{"usedBytes":8000000000,"totalBytes":32000000000},"swap":{"zramUsedBytes":0,"zramRamBytes":0,"diskBytes":0},"pressureAvg10":{"cpu":0.5,"memory":0,"io":null},"apps":{"topCpu":{"groupKey":"app:org.example.Editor","name":"Editor","cpuPercent":31.25},"topMemory":{"groupKey":"app:org.example.Editor","name":"Editor","memoryBytes":2000000000},"cpuRanking":[{"groupKey":"app:org.example.Editor","name":"Editor","cpuPercent":31.25}],"memoryRanking":[{"groupKey":"app:org.example.Editor","name":"Editor","memoryBytes":2000000000}]},"isComplete":true},"histories":{"cpu":[],"memory":[]}}"#;

/// The text of a name written as a JSON string.
fn string_text(value: &str) -> String {
    let mut text = String::new();
    push_string(&mut text, value);
    text
}

/// What `serde_json` (rounding correctly) reads a number text back as.
fn parsed_bits(number_text: &str) -> u64 {
    let parsed: serde_json::Value = serde_json::from_str(number_text).unwrap();
    parsed.as_f64().unwrap().to_bits()
}

fn editor_cpu_entry() -> CpuRankEntry {
    CpuRankEntry {
        group_key: "app:org.example.Editor".to_string(),
        name: "Editor".to_string(),
        cpu_percent: 31.25,
    }
}

fn editor_memory_entry() -> MemoryRankEntry {
    MemoryRankEntry {
        group_key: "app:org.example.Editor".to_string(),
        name: "Editor".to_string(),
        memory_bytes: 2_000_000_000.0,
    }
}

/// `TICK_SNAPSHOT` of `service-dbus.test.js`, with 60.5 and 31.25 for fractions and a null `io`.
fn tick_snapshot() -> Snapshot {
    Snapshot {
        taken_at_usec: Some(123_000_000),
        taken_at_clock_label: Some("14:02".to_string()),
        cpu_busy_percent: Some(50.0),
        cpu_clusters: Some(ClusterPercents {
            performance_percent: Some(60.5),
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
            io: None,
        },
        apps: Some(AppRanking {
            top_cpu: Some(editor_cpu_entry()),
            top_memory: Some(editor_memory_entry()),
            cpu_ranking: vec![editor_cpu_entry()],
            memory_ranking: vec![editor_memory_entry()],
        }),
        is_complete: true,
    }
}

fn no_data_snapshot() -> Snapshot {
    Snapshot {
        taken_at_usec: None,
        taken_at_clock_label: None,
        cpu_busy_percent: None,
        cpu_clusters: None,
        memory: None,
        swap: None,
        pressure_avg10: PressureAvg10::default(),
        apps: None,
        is_complete: false,
    }
}

/// The text of the state of a service with the given snapshot and histories.
fn state_text_of(
    snapshot: Option<&Snapshot>,
    cpu: &[Option<f64>],
    memory: &[Option<f64>],
    latest_sampled_at_usec: Option<u64>,
    sequence: u64,
) -> String {
    state_payload(&PublishedState {
        snapshot,
        cpu_history: &history_of(cpu),
        memory_history: &history_of(memory),
        service_started_at_usec: SERVICE_STARTED_AT_USEC,
        latest_sampled_at_usec,
        sequence,
    })
}

#[test]
fn a_sample_with_every_field_is_written_as_lib_protocol_js_writes_it() {
    let publish = Publish {
        snapshot: tick_snapshot(),
        appended_history: Some(AppendedHistory {
            cpu: Some(0.5),
            memory: Some(0.25),
        }),
    };
    assert_eq!(
        sample_payload(&publish, SEQUENCE, SAMPLED_AT_USEC),
        GJS_TICK_SAMPLE_TEXT
    );
}

#[test]
fn a_reveal_of_a_no_data_snapshot_is_written_with_nulls_and_no_appended_history() {
    let publish = Publish {
        snapshot: no_data_snapshot(),
        appended_history: None,
    };
    assert_eq!(
        sample_payload(&publish, 2, 1_794_000_004_000_000),
        GJS_NO_DATA_REVEAL_SAMPLE_TEXT
    );
}

#[test]
fn the_state_before_any_sample_has_a_null_snapshot_and_a_gap_in_its_history() {
    let text = state_text_of(None, &[Some(0.25), None], &[Some(0.5), Some(0.6)], None, 0);
    assert_eq!(text, GJS_STATE_BEFORE_ANY_SAMPLE_TEXT);
}

#[test]
fn the_state_after_publishes_carries_the_snapshot_and_the_latest_sampled_time() {
    let snapshot = tick_snapshot();
    let text = state_text_of(Some(&snapshot), &[], &[], Some(1_794_000_004_000_000), 2);
    assert_eq!(text, GJS_STATE_WITH_SNAPSHOT_TEXT);
}

/// The state's text is contract: gnome-status cuts it as text, from the part before `"snapshot":`.
#[test]
fn payload_the_state_is_compact_with_its_four_top_level_numbers_before_the_snapshot_as_plain_digits(
) {
    let snapshot = tick_snapshot();
    for (latest, latest_text) in [
        (Some(1_794_000_004_000_000_u64), "1794000004000000"),
        (None, "null"),
    ] {
        let text = state_text_of(Some(&snapshot), &[Some(0.5)], &[Some(0.25)], latest, 7);
        let (before_snapshot, _) = text.split_once(r#""snapshot":"#).unwrap();
        let expected_prefix = format!(
            r#"{{"protocol":1,"serviceStartedAtUsec":{SERVICE_STARTED_AT_USEC},"latestSampledAtUsec":{latest_text},"sequence":7,"#
        );
        assert_eq!(before_snapshot, expected_prefix);
        assert!(
            !text.contains(char::is_whitespace),
            "the state is compact: {text}"
        );
    }
}

#[test]
fn the_snapshots_keys_are_in_the_typedefs_order() {
    let text = sample_payload(
        &Publish {
            snapshot: tick_snapshot(),
            appended_history: None,
        },
        SEQUENCE,
        SAMPLED_AT_USEC,
    );
    let key_order = [
        r#""sequence":"#,
        r#""sampledAtUsec":"#,
        r#""snapshot":"#,
        r#""takenAtUsec":"#,
        r#""takenAtClockLabel":"#,
        r#""cpuBusyPercent":"#,
        r#""cpuClusters":"#,
        r#""memory":"#,
        r#""swap":"#,
        r#""pressureAvg10":"#,
        r#""apps":"#,
        r#""isComplete":"#,
        r#""appendedHistory":"#,
    ];
    let positions: Vec<usize> = key_order
        .iter()
        .map(|key| text.find(key).unwrap())
        .collect();
    let mut sorted_positions = positions.clone();
    sorted_positions.sort_unstable();
    assert_eq!(positions, sorted_positions, "keys out of order in {text}");
}

#[test]
fn a_whole_number_is_plain_digits_with_no_fraction_exponent_or_plus_sign() {
    let cases = [
        (0.0, "0"),
        (1.0, "1"),
        (-12.0, "-12"),
        (20_480_000_000.0, "20480000000"),
        (9_007_199_254_740_993.0, "9007199254740992"),
        (1e21, "1000000000000000000000"),
    ];
    for (value, expected) in cases {
        assert_eq!(number_text(value), expected);
    }
    let largest = number_text(f64::MAX);
    assert!(
        largest.bytes().all(|byte| byte.is_ascii_digit()),
        "{largest}"
    );
    assert_eq!(parsed_bits(&largest), f64::MAX.to_bits());
}

#[test]
fn payload_a_negative_zero_is_written_as_0() {
    assert_eq!(number_text(-0.0), "0");
    let publish = Publish {
        snapshot: Snapshot {
            cpu_busy_percent: Some(-0.0),
            ..no_data_snapshot()
        },
        appended_history: Some(AppendedHistory {
            cpu: Some(-0.0),
            memory: None,
        }),
    };
    let text = sample_payload(&publish, SEQUENCE, SAMPLED_AT_USEC);
    assert!(!text.contains("-0"), "no negative zero anywhere: {text}");
    let state = state_text_of(None, &[Some(-0.0)], &[], None, 0);
    assert!(!state.contains("-0"), "{state}");
}

#[test]
fn a_number_that_is_not_finite_is_written_null_as_javascript_writes_it() {
    for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        assert_eq!(number_text(value), "null");
    }
}

#[test]
fn a_fractional_number_is_read_back_as_exactly_the_same_double() {
    let values = [
        0.5,
        0.1,
        1.0 / 3.0,
        0.300_000_000_000_000_04,
        12.5,
        31.25,
        1e-7,
        5e-324,
        f64::MIN_POSITIVE,
        123_456_789.123_456_79,
        0.999_999_999_999_999_9,
        f64::EPSILON,
        -2.5,
    ];
    for value in values {
        let text = number_text(value);
        assert!(
            !text.contains(['e', 'E', '+']),
            "{value:?} is written with an exponent: {text}"
        );
        assert_eq!(parsed_bits(&text), value.to_bits(), "{value:?} as {text}");
    }
}

#[test]
fn an_integer_field_is_written_from_the_integer_never_through_a_float() {
    let publish = Publish {
        snapshot: Snapshot {
            taken_at_usec: Some(u64::MAX),
            ..no_data_snapshot()
        },
        appended_history: None,
    };
    let sample = sample_payload(&publish, u64::MAX - 1, u64::MAX);
    assert!(
        sample.starts_with(
            r#"{"sequence":18446744073709551614,"sampledAtUsec":18446744073709551615,"#
        ),
        "{sample}"
    );
    assert!(sample.contains(r#""takenAtUsec":18446744073709551615,"#));
    let state = state_payload(&PublishedState {
        snapshot: None,
        cpu_history: &history_of(&[]),
        memory_history: &history_of(&[]),
        service_started_at_usec: u64::MAX,
        latest_sampled_at_usec: Some(u64::MAX - 2),
        sequence: u64::MAX - 1,
    });
    assert!(state.starts_with(
        r#"{"protocol":1,"serviceStartedAtUsec":18446744073709551615,"latestSampledAtUsec":18446744073709551613,"sequence":18446744073709551614,"#
    ));
}

#[test]
fn a_name_is_escaped_as_json_requires_and_parses_back_to_itself() {
    let control_characters: String = (0_u8..0x20).map(char::from).collect();
    let names = [
        "plain".to_string(),
        r#"quote " here"#.to_string(),
        r"back \ slash".to_string(),
        control_characters,
        "del \u{7f} and café and 日本 and \u{2028}".to_string(),
        "astral \u{1F600} and \u{10FFFF}".to_string(),
        String::new(),
    ];
    for name in &names {
        let text = string_text(name);
        assert!(
            !text.chars().any(|character| character < ' '),
            "a raw control character in {text:?}"
        );
        let parsed: String = serde_json::from_str(&text).unwrap();
        assert_eq!(&parsed, name, "{name:?} written as {text}");
    }
    assert_eq!(string_text("a\"b\\c\n"), r#""a\"b\\c\n""#);
    assert_eq!(string_text("\u{1}"), r#""\u0001""#);
}

#[test]
fn a_ranked_app_with_awkward_characters_in_its_name_survives_the_whole_payload() {
    let awkward_name = "caf\u{e9} \"x\" \\ \t \u{1F600}";
    let mut snapshot = tick_snapshot();
    snapshot.apps = Some(AppRanking {
        top_cpu: Some(CpuRankEntry {
            name: awkward_name.to_string(),
            ..editor_cpu_entry()
        }),
        ..AppRanking::default()
    });
    let text = sample_payload(
        &Publish {
            snapshot,
            appended_history: None,
        },
        SEQUENCE,
        SAMPLED_AT_USEC,
    );
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(
        parsed["snapshot"]["apps"]["topCpu"]["name"].as_str(),
        Some(awkward_name)
    );
}
