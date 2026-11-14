//! The Rust sampler against the gjs one. For each scenario under `gnome-shell/tests/golden/scenarios/`
//! the Rust `Sampler`, over the same fixture roots with the real reader and lister, the same clock,
//! clock label and app names, and the `ServiceFace` and payload writer, must give what the gjs
//! sampler and service gave, as `generate.js` recorded it in `gnome-shell/tests/golden/expected/`.
//!
//! Equal means equal as parsed JSON: the same keys (none extra, none missing), `null` where `null`,
//! strings equal, and every number the same double bit for bit (`f64::to_bits`). Key order and
//! number spelling do not count. The JSON is parsed by `serde_json` with `float_roundtrip` on, which
//! rounds correctly. If a golden file and the Rust program ever disagree, the expected file, the
//! scenario and this comparison are not to be adjusted to make it pass: find which side differs.

// A failing test should say so loudly: it may unwrap, index a JSON value and panic.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic
)]

use resource_pulse_sampler::ports::{Clock, FileSystemLister, FileSystemReader};
use resource_pulse_sampler::sampler::{Publish, Sampler, SamplerPorts};
use resource_pulse_sampler::service::ServiceFace;
use serde_json::{json, Map, Value};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::rc::Rc;

const SCENARIO_FILE_SUFFIX: &str = ".json";

/// `gnome-shell/tests`, from the crate.
fn gnome_shell_tests_directory() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../gnome-shell/tests")
}

fn scenarios_directory() -> PathBuf {
    gnome_shell_tests_directory().join("golden/scenarios")
}

fn expected_directory() -> PathBuf {
    gnome_shell_tests_directory().join("golden/expected")
}

fn fixtures_directory() -> PathBuf {
    gnome_shell_tests_directory().join("fixtures")
}

/// The clock the steps move, shared with the sampler that reads it.
struct ScenarioClock {
    monotonic_usec: Rc<Cell<u64>>,
    clock_label: Rc<RefCell<String>>,
}

impl Clock for ScenarioClock {
    /// The time the latest step set.
    fn monotonic_usec(&self) -> u64 {
        self.monotonic_usec.get()
    }

    /// The label the latest tick set.
    fn clock_label(&self) -> Result<String, String> {
        Ok(self.clock_label.borrow().clone())
    }
}

/// One step of a scenario file.
enum Step {
    /// One tick over `fs_root`.
    Tick {
        fs_root: String,
        monotonic_usec: u64,
        real_usec: u64,
        clock_label: String,
    },
    /// A watch starts; its scan reads `fs_root`.
    WatchStarts {
        fs_root: String,
        monotonic_usec: u64,
        real_usec: u64,
    },
    /// The watch ends.
    WatchEnds,
}

/// A scenario file, read.
struct Scenario {
    service_started_at_usec: u64,
    app_names: HashMap<String, String>,
    steps: Vec<Step>,
}

/// A text field of a JSON object.
fn text_field(object: &Value, name: &str) -> String {
    object[name]
        .as_str()
        .unwrap_or_else(|| panic!("{name} is not text in {object}"))
        .to_string()
}

/// A whole-number field of a JSON object.
fn integer_field(object: &Value, name: &str) -> u64 {
    object[name]
        .as_u64()
        .unwrap_or_else(|| panic!("{name} is not a whole number in {object}"))
}

/// One step, as the scenario file's documentation in `generate.js` describes it.
fn parse_step(step: &Value) -> Step {
    if let Some(tick) = step.get("tick") {
        return Step::Tick {
            fs_root: text_field(tick, "fsRoot"),
            monotonic_usec: integer_field(tick, "monotonicUsec"),
            real_usec: integer_field(tick, "realUsec"),
            clock_label: text_field(tick, "clockLabel"),
        };
    }
    match step.get("watchDetail").and_then(Value::as_bool) {
        Some(true) => Step::WatchStarts {
            fs_root: text_field(step, "fsRoot"),
            monotonic_usec: integer_field(step, "monotonicUsec"),
            real_usec: integer_field(step, "realUsec"),
        },
        Some(false) => Step::WatchEnds,
        None => panic!("a step is neither a tick nor a watch change: {step}"),
    }
}

/// Reads a scenario file.
fn read_scenario(scenario_name: &str) -> Scenario {
    let path = scenarios_directory().join(format!("{scenario_name}{SCENARIO_FILE_SUFFIX}"));
    let text =
        fs::read_to_string(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let document: Value = serde_json::from_str(&text).unwrap();
    let app_names = document["appNames"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(desktop_id, name)| (desktop_id.clone(), name.as_str().unwrap().to_string()))
        .collect();
    Scenario {
        service_started_at_usec: integer_field(&document, "serviceStartedAtUsec"),
        app_names,
        steps: document["steps"]
            .as_array()
            .unwrap()
            .iter()
            .map(parse_step)
            .collect(),
    }
}

/// The root the first step reads.
fn first_fs_root(steps: &[Step]) -> &str {
    match steps.first() {
        Some(Step::Tick { fs_root, .. } | Step::WatchStarts { fs_root, .. }) => fs_root,
        _ => panic!("a scenario starts with a tick or a watch start"),
    }
}

/// Everything a scenario's run holds while its steps are applied.
struct Run {
    sampler: Sampler,
    face: ServiceFace,
    monotonic_usec: Rc<Cell<u64>>,
    clock_label: Rc<RefCell<String>>,
    next_tick_number: u64,
    samples: Vec<Value>,
}

impl Run {
    /// The sampler and face of a scenario, initialised and never given a timer.
    fn start(scenario: &Scenario) -> Run {
        let monotonic_usec = Rc::new(Cell::new(0));
        let clock_label = Rc::new(RefCell::new(String::new()));
        let app_names = scenario.app_names.clone();
        let ports = SamplerPorts {
            reader: Box::new(FileSystemReader),
            lister: Box::new(FileSystemLister),
            clock: Box::new(ScenarioClock {
                monotonic_usec: Rc::clone(&monotonic_usec),
                clock_label: Rc::clone(&clock_label),
            }),
            resolve_app_name: Box::new(move |desktop_id| app_names.get(desktop_id).cloned()),
            log: Box::new(|_| {}),
        };
        let first_root = fixtures_directory().join(first_fs_root(&scenario.steps));
        let mut sampler = Sampler::new(first_root, ports);
        sampler.initialize();
        Run {
            sampler,
            face: ServiceFace::new(scenario.service_started_at_usec),
            monotonic_usec,
            clock_label,
            next_tick_number: 0,
            samples: Vec::new(),
        }
    }

    /// Numbers a publish and records the Sample's JSON, parsed.
    fn record_sample(&mut self, publish: &Publish, real_usec: u64) {
        let text = self.face.next_sample(publish, real_usec);
        self.samples.push(serde_json::from_str(&text).unwrap());
    }

    /// Applies one step as the generator does: the clock first, then the root, then the call.
    fn apply(&mut self, step: &Step) {
        match step {
            Step::Tick {
                fs_root,
                monotonic_usec,
                real_usec,
                clock_label,
            } => {
                self.monotonic_usec.set(*monotonic_usec);
                *self.clock_label.borrow_mut() = clock_label.clone();
                self.sampler.set_fs_root(fixtures_directory().join(fs_root));
                let publish = self.sampler.run_tick(self.next_tick_number);
                self.next_tick_number += 1;
                self.record_sample(&publish, *real_usec);
            }
            Step::WatchStarts {
                fs_root,
                monotonic_usec,
                real_usec,
            } => {
                self.monotonic_usec.set(*monotonic_usec);
                self.sampler.set_fs_root(fixtures_directory().join(fs_root));
                if let Some(publish) = self.sampler.set_detail_watched(true) {
                    self.record_sample(&publish, *real_usec);
                }
            }
            Step::WatchEnds => {
                let publish = self.sampler.set_detail_watched(false);
                assert!(publish.is_none(), "ending a watch publishes nothing");
            }
        }
    }
}

/// What the Rust sampler, face and writer give for a scenario, in the shape of an expected file.
fn run_scenario(scenario_name: &str) -> Value {
    let scenario = read_scenario(scenario_name);
    let mut run = Run::start(&scenario);
    for step in &scenario.steps {
        run.apply(step);
    }
    let state: Value = serde_json::from_str(&run.face.state_text(&run.sampler)).unwrap();
    json!({"samples": run.samples, "state": state})
}

/// The expected file of a scenario, parsed.
fn read_expected(scenario_name: &str) -> Value {
    let path = expected_directory().join(format!("{scenario_name}{SCENARIO_FILE_SUFFIX}"));
    let text =
        fs::read_to_string(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    serde_json::from_str(&text).unwrap()
}

/// Two numbers are equal when they are the same whole number, or the same double bit for bit.
fn is_same_number(expected: &serde_json::Number, actual: &serde_json::Number) -> bool {
    match (
        expected.as_u64(),
        actual.as_u64(),
        expected.as_i64(),
        actual.as_i64(),
    ) {
        (Some(expected_whole), Some(actual_whole), _, _) => expected_whole == actual_whole,
        (_, _, Some(expected_whole), Some(actual_whole)) => expected_whole == actual_whole,
        _ => match (expected.as_f64(), actual.as_f64()) {
            (Some(expected_double), Some(actual_double)) => {
                expected_double.to_bits() == actual_double.to_bits()
            }
            _ => false,
        },
    }
}

/// Every difference between two values, each as `path: what`, none when they are equal in the
/// sense of the module documentation.
fn differences(expected: &Value, actual: &Value) -> Vec<String> {
    let mut found = Vec::new();
    collect_differences("$", expected, actual, &mut found);
    found
}

fn collect_differences(path: &str, expected: &Value, actual: &Value, found: &mut Vec<String>) {
    match (expected, actual) {
        (Value::Object(expected_fields), Value::Object(actual_fields)) => {
            collect_object_differences(path, expected_fields, actual_fields, found);
        }
        (Value::Array(expected_items), Value::Array(actual_items)) => {
            if expected_items.len() != actual_items.len() {
                found.push(format!(
                    "{path}: {} items expected, {} given",
                    expected_items.len(),
                    actual_items.len()
                ));
            }
            for (index, (expected_item, actual_item)) in
                expected_items.iter().zip(actual_items).enumerate()
            {
                collect_differences(
                    &format!("{path}[{index}]"),
                    expected_item,
                    actual_item,
                    found,
                );
            }
        }
        (Value::Number(expected_number), Value::Number(actual_number)) => {
            if !is_same_number(expected_number, actual_number) {
                found.push(format!(
                    "{path}: {expected_number} expected, {actual_number} given"
                ));
            }
        }
        (expected_leaf, actual_leaf) if expected_leaf == actual_leaf => {}
        _ => found.push(format!("{path}: {expected} expected, {actual} given")),
    }
}

/// The differences of two objects: keys missing, keys extra, and each shared key's value.
fn collect_object_differences(
    path: &str,
    expected_fields: &Map<String, Value>,
    actual_fields: &Map<String, Value>,
    found: &mut Vec<String>,
) {
    for (key, expected_value) in expected_fields {
        match actual_fields.get(key) {
            Some(actual_value) => collect_differences(
                &format!("{path}.{key}"),
                expected_value,
                actual_value,
                found,
            ),
            None => found.push(format!("{path}.{key}: missing")),
        }
    }
    for key in actual_fields
        .keys()
        .filter(|key| !expected_fields.contains_key(*key))
    {
        found.push(format!("{path}.{key}: extra"));
    }
}

/// Fails, naming every difference, when the Rust run of a scenario is not its expected file.
fn assert_scenario_matches_expected(scenario_name: &str) {
    let found = differences(&read_expected(scenario_name), &run_scenario(scenario_name));
    assert!(
        found.is_empty(),
        "{scenario_name}: {} differences from the gjs sampler's file, the first ten:\n{}",
        found.len(),
        found
            .iter()
            .take(10)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}

/// One test per scenario, so a failure names the scenario; `SCENARIOS_WITH_A_TEST` is what
/// `every_scenario_and_every_expected_file_has_a_test` holds the directories to.
macro_rules! golden_scenarios {
    ($($test_name:ident => $scenario_name:literal),+ $(,)?) => {
        const SCENARIOS_WITH_A_TEST: &[&str] = &[$($scenario_name),+];
        $(
            #[test]
            fn $test_name() {
                assert_scenario_matches_expected($scenario_name);
            }
        )+
    };
}

golden_scenarios! {
    golden_a_then_b => "a-then-b",
    golden_bad_pmu => "bad-pmu",
    golden_no_psi => "no-psi",
    golden_no_stat => "no-stat",
    golden_no_swaps => "no-swaps",
    golden_small_leaf => "small-leaf",
    golden_snap_units_resolve_to_different_names => "snap-units-resolve-to-different-names",
    golden_swap_disk => "swap-disk",
    golden_unit_name_with_e_acute => "unit-name-with-e-acute",
    golden_unit_types => "unit-types",
    golden_vanished => "vanished",
    golden_watch_around_a_burst => "watch-around-a-burst",
    golden_moving_counters => "moving-counters",
    golden_one_cluster_offline => "one-cluster-offline",
    golden_ranking_ties_and_truncation => "ranking-ties-and-truncation",
    golden_memory_gap => "memory-gap",
    golden_two_reveals => "two-reveals",
    golden_history_wraps => "history-wraps",
    golden_no_cgroup_directory => "no-cgroup-directory",
    golden_single_cluster => "single-cluster",
    golden_partly_null_pressure => "partly-null-pressure",
    golden_performance_cluster_offline => "performance-cluster-offline",
    golden_watch_inside_the_reveal_cooldown => "watch-inside-the-reveal-cooldown",
}

/// The names of the `.json` files in a directory, without the suffix.
fn json_file_stems(directory: &Path) -> BTreeSet<String> {
    fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("{}: {error}", directory.display()))
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter_map(|name| name.strip_suffix(SCENARIO_FILE_SUFFIX).map(str::to_string))
        .collect()
}

/// A scenario without an expected file, an expected file without a scenario, or either without a
/// test above, fails here.
#[test]
fn every_scenario_and_every_expected_file_has_a_test() {
    let scenarios = json_file_stems(&scenarios_directory());
    let expected = json_file_stems(&expected_directory());
    let tested: BTreeSet<String> = SCENARIOS_WITH_A_TEST
        .iter()
        .map(|name| name.to_string())
        .collect();
    assert_eq!(
        scenarios, expected,
        "the scenarios and the expected files differ"
    );
    assert_eq!(scenarios, tested, "the scenarios and the tests differ");
}

/// A recorded run of `a-then-b`, to damage in the rows below.
fn recorded_run() -> Value {
    read_expected("a-then-b")
}

#[test]
fn the_comparison_accepts_a_value_that_differs_only_in_key_order_and_number_spelling() {
    let expected: Value = serde_json::from_str(r#"{"a":1,"b":0.5,"c":[1e2,null]}"#).unwrap();
    let actual: Value = serde_json::from_str(r#"{"c":[100.0,null],"b":0.50,"a":1}"#).unwrap();
    assert_eq!(differences(&expected, &actual), Vec::<String>::new());
}

#[test]
fn the_comparison_fails_for_a_number_one_bit_off() {
    let mut damaged = recorded_run();
    let original = damaged["state"]["snapshot"]["pressureAvg10"]["cpu"]
        .as_f64()
        .unwrap();
    damaged["state"]["snapshot"]["pressureAvg10"]["cpu"] =
        json!(f64::from_bits(original.to_bits() + 1));
    let found = differences(&recorded_run(), &damaged);
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(
        found[0].starts_with("$.state.snapshot.pressureAvg10.cpu: "),
        "{found:?}"
    );
}

#[test]
fn the_comparison_fails_for_a_missing_key_and_for_an_extra_one() {
    let mut damaged = recorded_run();
    let removed = damaged["samples"][0]["snapshot"]
        .as_object_mut()
        .unwrap()
        .remove("isComplete");
    assert!(removed.is_some());
    damaged["state"]
        .as_object_mut()
        .unwrap()
        .insert("surprise".to_string(), json!(1));
    let found = differences(&recorded_run(), &damaged);
    assert_eq!(
        found,
        [
            "$.samples[0].snapshot.isComplete: missing",
            "$.state.surprise: extra"
        ]
    );
}

#[test]
fn the_comparison_fails_for_a_null_in_a_values_place_and_a_value_in_a_nulls() {
    let mut damaged = recorded_run();
    damaged["state"]["snapshot"]["memory"]["usedBytes"] = Value::Null;
    damaged["samples"][0]["snapshot"]["cpuBusyPercent"] = json!(0.5);
    let found = differences(&recorded_run(), &damaged);
    assert_eq!(found.len(), 2, "{found:?}");
    assert!(found
        .iter()
        .any(|line| line.starts_with("$.state.snapshot.memory.usedBytes: ")));
    assert!(found
        .iter()
        .any(|line| line.starts_with("$.samples[0].snapshot.cpuBusyPercent: ")));
}

#[test]
fn the_comparison_fails_for_a_string_a_list_length_and_a_whole_number_that_differ() {
    let mut damaged = recorded_run();
    damaged["samples"][1]["snapshot"]["takenAtClockLabel"] = json!("14:03");
    damaged["state"]["histories"]["cpu"]
        .as_array_mut()
        .unwrap()
        .pop();
    damaged["state"]["sequence"] = json!(4);
    let found = differences(&recorded_run(), &damaged);
    assert_eq!(found.len(), 3, "{found:?}");
}

/// Every number in every golden file survives a write and a parse with the same bits: the writer's
/// rule, held to the values the gjs sampler really produced.
#[test]
fn every_number_in_every_golden_file_survives_the_writers_text_with_the_same_bits() {
    let mut checked_count = 0;
    for scenario_name in json_file_stems(&expected_directory()) {
        let mut numbers = Vec::new();
        collect_numbers(&read_expected(&scenario_name), &mut numbers);
        for number in numbers {
            let written = resource_pulse_sampler::payload::number_text(number);
            let read_back: Value = serde_json::from_str(&written).unwrap();
            assert_eq!(
                read_back.as_f64().map(f64::to_bits),
                Some(number.to_bits()),
                "{scenario_name}: {number:?} written as {written}"
            );
            checked_count += 1;
        }
    }
    assert!(
        checked_count > 100,
        "only {checked_count} numbers were checked"
    );
}

/// Every number in a value, as a double.
fn collect_numbers(value: &Value, numbers: &mut Vec<f64>) {
    match value {
        Value::Number(number) => numbers.extend(number.as_f64()),
        Value::Array(items) => items.iter().for_each(|item| collect_numbers(item, numbers)),
        Value::Object(fields) => fields
            .values()
            .for_each(|field| collect_numbers(field, numbers)),
        Value::Null | Value::Bool(_) | Value::String(_) => {}
    }
}
