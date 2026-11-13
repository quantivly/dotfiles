//! Every tunable and protocol name the sampler shares with the gjs side, named
//! as `lib/constants.js` and `lib/protocol.js` name them. The state table's
//! `sampler-constants.js` row compares each one with the JavaScript.

/// Seconds between CPU, memory and pressure samples.
pub const SAMPLE_INTERVAL_SECONDS: u64 = 2;
/// Seconds between per-app scans while a detail watch is held.
pub const APP_SCAN_INTERVAL_SECONDS: u64 = 20;
/// Seconds between per-app scans with no detail watch held.
pub const APP_SCAN_UNWATCHED_INTERVAL_SECONDS: u64 = 60;
/// Points the CPU must rise in one sample to count as a burst.
pub const BURST_CPU_RISE_POINTS: u64 = 15;
/// Ticks a burst scan waits before another may start.
pub const BURST_COOLDOWN_TICKS: u64 = 2;
/// Ticks a reveal scan waits before another may start.
pub const REVEAL_SCAN_COOLDOWN_TICKS: u64 = 2;
/// Shortest window, in seconds, over which a CPU ranking is computed.
pub const MIN_CPU_RANKING_WINDOW_SECONDS: u64 = 1;
/// Unit suffixes an app scan does not descend into.
pub const APP_SCAN_SKIPPED_UNIT_SUFFIXES: [&str; 7] = [
    ".mount",
    ".socket",
    ".swap",
    ".automount",
    ".path",
    ".timer",
    ".device",
];
/// `memory.current` above which a scan also reads `memory.stat` (64 MiB).
pub const APP_MEMORY_STAT_MIN_BYTES: u64 = 64 * 1024 * 1024;
/// Samples kept for the card's history.
pub const CARD_HISTORY_SAMPLES: u64 = 150;
/// Pressure percentages at which the meter's bands change.
pub const PRESSURE_BAND_THRESHOLDS_PERCENT: [u64; 3] = [10, 25, 50];
/// Share of its capacity at which the performance cluster counts as full.
pub const PERFORMANCE_CAPACITY_RATIO: f64 = 0.9;
/// Microseconds before a repeated error is logged again.
pub const ERROR_LOG_REPEAT_INTERVAL_USEC: u64 = 600_000_000;
/// Prefix of every line the service logs.
pub const LOG_PREFIX: &str = "resource-pulse:";
/// Name of the CPU the kernel itself spends.
pub const KERNEL_LABEL: &str = "kernel";
/// Name of the CPU spent by a parent's finished short jobs.
pub const SHORT_JOBS_LABEL: &str = "short jobs";
/// Unit names shown under another name, as (unit, display name) in the
/// JavaScript object's key order.
pub const UNIT_DISPLAY_ALIASES: [(&str, &str); 2] = [
    ("herdr-server", "herdr agents"),
    ("org.gnome.Shell", "GNOME Shell"),
];
/// Apps listed in each ranking.
pub const APP_RANKING_LENGTH: u64 = 10;

/// Version of the D-Bus protocol the Sample and GetState payloads follow.
pub const PROTOCOL_VERSION: u64 = 1;
/// The service's well-known bus name.
pub const RESOURCE_PULSE_BUS_NAME: &str = "io.github.quantivly.dotfiles.ResourcePulse1";
/// The service's interface name (the same as its bus name).
pub const RESOURCE_PULSE_INTERFACE_NAME: &str = RESOURCE_PULSE_BUS_NAME;
/// The service's object path.
pub const RESOURCE_PULSE_OBJECT_PATH: &str = "/io/github/quantivly/dotfiles/ResourcePulse1";
/// Method that returns the whole state.
pub const GET_STATE_METHOD_NAME: &str = "GetState";
/// Method that starts a detail watch.
pub const WATCH_DETAIL_METHOD_NAME: &str = "WatchDetail";
/// Method that ends a detail watch.
pub const UNWATCH_DETAIL_METHOD_NAME: &str = "UnwatchDetail";
/// Signal that carries each sample.
pub const SAMPLE_SIGNAL_NAME: &str = "Sample";

/// Quotes `text` as a JSON string, escaping what JSON requires.
fn json_string(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    for character in text.chars() {
        match character {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            control if (control as u32) < 0x20 => {
                quoted.push_str(&format!("\\u{:04x}", control as u32))
            }
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

/// Renders a list of numbers as compact JSON.
fn json_number_list(numbers: &[u64]) -> String {
    let rendered: Vec<String> = numbers.iter().map(u64::to_string).collect();
    format!("[{}]", rendered.join(","))
}

/// Renders a list of strings as compact JSON.
fn json_string_list(texts: &[&str]) -> String {
    let rendered: Vec<String> = texts.iter().map(|text| json_string(text)).collect();
    format!("[{}]", rendered.join(","))
}

/// Renders (key, value) pairs as compact JSON: a list of two-element lists.
fn json_pair_list(pairs: &[(&str, &str)]) -> String {
    let rendered: Vec<String> = pairs
        .iter()
        .map(|(key, value)| format!("[{},{}]", json_string(key), json_string(value)))
        .collect();
    format!("[{}]", rendered.join(","))
}

/// One `NAME=value` line per constant, for `--print-constants`: a scalar and a
/// string as they are, a list or a map as compact JSON.
pub fn constant_lines() -> Vec<String> {
    vec![
        format!("SAMPLE_INTERVAL_SECONDS={SAMPLE_INTERVAL_SECONDS}"),
        format!("APP_SCAN_INTERVAL_SECONDS={APP_SCAN_INTERVAL_SECONDS}"),
        format!("APP_SCAN_UNWATCHED_INTERVAL_SECONDS={APP_SCAN_UNWATCHED_INTERVAL_SECONDS}"),
        format!("BURST_CPU_RISE_POINTS={BURST_CPU_RISE_POINTS}"),
        format!("BURST_COOLDOWN_TICKS={BURST_COOLDOWN_TICKS}"),
        format!("REVEAL_SCAN_COOLDOWN_TICKS={REVEAL_SCAN_COOLDOWN_TICKS}"),
        format!("MIN_CPU_RANKING_WINDOW_SECONDS={MIN_CPU_RANKING_WINDOW_SECONDS}"),
        format!(
            "APP_SCAN_SKIPPED_UNIT_SUFFIXES={}",
            json_string_list(&APP_SCAN_SKIPPED_UNIT_SUFFIXES)
        ),
        format!("APP_MEMORY_STAT_MIN_BYTES={APP_MEMORY_STAT_MIN_BYTES}"),
        format!("CARD_HISTORY_SAMPLES={CARD_HISTORY_SAMPLES}"),
        format!(
            "PRESSURE_BAND_THRESHOLDS_PERCENT={}",
            json_number_list(&PRESSURE_BAND_THRESHOLDS_PERCENT)
        ),
        format!("PERFORMANCE_CAPACITY_RATIO={PERFORMANCE_CAPACITY_RATIO}"),
        format!("ERROR_LOG_REPEAT_INTERVAL_USEC={ERROR_LOG_REPEAT_INTERVAL_USEC}"),
        format!("LOG_PREFIX={LOG_PREFIX}"),
        format!("KERNEL_LABEL={KERNEL_LABEL}"),
        format!("SHORT_JOBS_LABEL={SHORT_JOBS_LABEL}"),
        format!(
            "UNIT_DISPLAY_ALIASES={}",
            json_pair_list(&UNIT_DISPLAY_ALIASES)
        ),
        format!("APP_RANKING_LENGTH={APP_RANKING_LENGTH}"),
        format!("PROTOCOL_VERSION={PROTOCOL_VERSION}"),
        format!("RESOURCE_PULSE_BUS_NAME={RESOURCE_PULSE_BUS_NAME}"),
        format!("RESOURCE_PULSE_INTERFACE_NAME={RESOURCE_PULSE_INTERFACE_NAME}"),
        format!("RESOURCE_PULSE_OBJECT_PATH={RESOURCE_PULSE_OBJECT_PATH}"),
        format!("GET_STATE_METHOD_NAME={GET_STATE_METHOD_NAME}"),
        format!("WATCH_DETAIL_METHOD_NAME={WATCH_DETAIL_METHOD_NAME}"),
        format!("UNWATCH_DETAIL_METHOD_NAME={UNWATCH_DETAIL_METHOD_NAME}"),
        format!("SAMPLE_SIGNAL_NAME={SAMPLE_SIGNAL_NAME}"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every printed line is `NAME=value` and no name repeats.
    #[test]
    fn constant_lines_are_unique_name_value_pairs() {
        let lines = constant_lines();
        let mut names: Vec<&str> = lines
            .iter()
            .filter_map(|line| line.split_once('='))
            .map(|(name, _)| name)
            .collect();
        assert_eq!(names.len(), lines.len());
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), lines.len());
    }

    /// A string list and a pair list print as JSON that serde_json reads back.
    #[test]
    fn lists_print_as_json_that_round_trips() {
        let suffixes: Vec<String> =
            serde_json::from_str(&json_string_list(&APP_SCAN_SKIPPED_UNIT_SUFFIXES)).unwrap();
        assert_eq!(suffixes, APP_SCAN_SKIPPED_UNIT_SUFFIXES);
        let pairs: Vec<(String, String)> =
            serde_json::from_str(&json_pair_list(&UNIT_DISPLAY_ALIASES)).unwrap();
        assert_eq!(pairs.len(), UNIT_DISPLAY_ALIASES.len());
        assert_eq!(json_string("a\"b\\c\n"), "\"a\\\"b\\\\c\\u000a\"");
    }
}
