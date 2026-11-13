//! Parsers for cgroup v2 files; the gjs original is `lib/cgroupParsers.js`.

use super::{is_blank, is_js_line_terminator, skip_whitespace_run, take_digit_run};

/// The `cpu.stat` key holding cumulative CPU microseconds.
const USAGE_USEC_KEY: &str = "usage_usec";
/// The `memory.stat` key counting active page cache, in bytes.
const ACTIVE_FILE_KEY: &str = "active_file";
/// The `memory.stat` key counting inactive page cache, in bytes.
const INACTIVE_FILE_KEY: &str = "inactive_file";

/// Every position in `text` where `^` matches under JavaScript's `m` flag: the start, and after
/// each line terminator.
fn line_start_tails(text: &str) -> impl Iterator<Item = &str> {
    let after_terminators = text
        .char_indices()
        .filter(|(_, character)| is_js_line_terminator(*character))
        .map(|(index, character)| index + character.len_utf8());
    std::iter::once(0)
        .chain(after_terminators)
        .filter_map(|start| text.get(start..))
}

/// `^<key>\s+(\d+)$` under the `m` flag, at the start of `tail`: the number, `None` when the
/// pattern does not match here or the number does not fit a `u64`. `\s+` may run across line
/// terminators, and `$` is the end of the text or the character before a line terminator.
fn match_counter_at_line_start(tail: &str, key: &str) -> Option<u64> {
    let after_key = tail.strip_prefix(key)?;
    let value_run = take_digit_run(skip_whitespace_run(after_key)?);
    let at_line_end = value_run
        .rest
        .chars()
        .next()
        .is_none_or(is_js_line_terminator);
    if value_run.digit_count == 0 || !at_line_end {
        return None;
    }
    value_run.value
}

/// The number of the first line of `text` that is `<key>`, whitespace, digits (`RegExp.exec`
/// with the `m` flag); `None` when none is.
fn find_counter(text: &str, key: &str) -> Option<u64> {
    line_start_tails(text).find_map(|tail| match_counter_at_line_start(tail, key))
}

/// Reads `usage_usec` (cumulative CPU microseconds) from a cgroup `cpu.stat`.
pub fn parse_cpu_stat_usage_usec(text: &str) -> Option<u64> {
    find_counter(text, USAGE_USEC_KEY)
}

/// `active_file + inactive_file` of a cgroup `memory.stat`, in bytes; `None` when either is
/// absent or the sum does not fit a `u64`.
pub fn parse_memory_stat_reclaimable_bytes(text: &str) -> Option<u64> {
    let active_file_bytes = find_counter(text, ACTIVE_FILE_KEY)?;
    let inactive_file_bytes = find_counter(text, INACTIVE_FILE_KEY)?;
    active_file_bytes.checked_add(inactive_file_bytes)
}

/// Parses a file holding one integer, such as `memory.current`; `None` for anything else
/// (`max`, an empty file).
pub fn parse_single_number(text: &str) -> Option<u64> {
    let value_run = take_digit_run(text.trim_start_matches(super::is_js_whitespace));
    if value_run.digit_count == 0 || !is_blank(value_run.rest) {
        return None;
    }
    value_run.value
}
