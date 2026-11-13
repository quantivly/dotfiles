//! Parsers for `/proc` and `/sys` text; the gjs original is `lib/procParsers.js`.

use std::collections::{BTreeMap, HashMap};

use super::{
    is_blank, is_js_line_terminator, is_js_whitespace, parse_all_digits, skip_whitespace_run,
    split_into_fields, take_digit_run, BYTES_PER_KIB,
};

/// The label of `/proc/stat`'s all-CPU line.
const AGGREGATE_CPU_LABEL: &str = "cpu";
/// The prefix of a per-CPU line's label, followed by the CPU's index.
const PER_CPU_LABEL_PREFIX: &str = "cpu";
/// The counters a `cpu` line needs at least; older kernels omit the trailing ones, which count as 0.
const CPU_TIMES_MIN_COUNTER_COUNT: usize = 4;
/// The unit suffix of a `/proc/meminfo` value counted in kibibytes.
const MEMINFO_KIB_UNIT: &str = "kB";
/// The key `/proc/<pid>/status` puts before the UIDs.
const UID_LINE_PREFIX: &str = "Uid:";
/// What starts a pressure file's `some` line.
const PRESSURE_SOME_KEYWORD: &str = "some";
/// The key whose value the sampler reads on a pressure line.
const PRESSURE_AVG10_KEY: &str = "avg10=";
/// Which `mm_stat` field is the uncompressed bytes stored (0-based).
const ZRAM_MM_STAT_STORED_FIELD_INDEX: usize = 0;
/// Which `mm_stat` field is the RAM in use: `mem_used_total`, not `compr_data_size`.
const ZRAM_MM_STAT_RAM_FIELD_INDEX: usize = 2;
/// How many fields an `mm_stat` needs at least.
const ZRAM_MM_STAT_MIN_FIELD_COUNT: usize = 3;
/// The `/proc/swaps` column holding a swap area's file name.
const PROC_SWAPS_FILENAME_COLUMN: &str = "Filename";
/// The `/proc/swaps` column holding the swap in use, in kibibytes.
const PROC_SWAPS_USED_KIB_COLUMN: &str = "Used";

/// One `cpu`/`cpuN` line's counters, in clock ticks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CpuTimes {
    pub user: u64,
    pub nice: u64,
    pub system: u64,
    pub idle: u64,
    pub iowait: u64,
    pub irq: u64,
    pub softirq: u64,
    pub steal: u64,
    pub guest: u64,
    pub guest_nice: u64,
}

/// What `/proc/stat` holds that the sampler reads.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProcStat {
    /// The all-CPU line; `None` when absent or malformed.
    pub aggregate: Option<CpuTimes>,
    /// Each CPU's line, by its index.
    pub per_cpu: BTreeMap<u32, CpuTimes>,
}

/// `/sys/block/zramN/mm_stat`'s two fields the sampler reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ZramMmStat {
    /// Uncompressed bytes stored (field 1).
    pub stored_bytes: u64,
    /// RAM actually used (field 3, `mem_used_total`).
    pub ram_bytes: u64,
}

/// One active swap area of `/proc/swaps`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SwapArea {
    pub filename: String,
    pub used_bytes: u64,
}

/// `parseNonNegativeIntegers`: every field as a number, or `None` when any is not made of digits
/// alone (or does not fit a `u64`).
fn parse_non_negative_integers(fields: &[&str]) -> Option<Vec<u64>> {
    fields.iter().map(|field| parse_all_digits(field)).collect()
}

/// Parses one `cpu`/`cpuN` line's counters; `None` when any is malformed or fewer than four
/// are there. Counters beyond the tenth are checked and ignored.
fn parse_cpu_times(counter_fields: &[&str]) -> Option<CpuTimes> {
    let counters = parse_non_negative_integers(counter_fields)?;
    if counters.len() < CPU_TIMES_MIN_COUNTER_COUNT {
        return None;
    }
    let counter_at = |index: usize| counters.get(index).copied().unwrap_or(0);
    Some(CpuTimes {
        user: counter_at(0),
        nice: counter_at(1),
        system: counter_at(2),
        idle: counter_at(3),
        iowait: counter_at(4),
        irq: counter_at(5),
        softirq: counter_at(6),
        steal: counter_at(7),
        guest: counter_at(8),
        guest_nice: counter_at(9),
    })
}

/// `/^cpu(\d+)$/`: the CPU index in a per-CPU label; `None` for any other label, and for an
/// index too large for a `u32`.
fn parse_per_cpu_label(label: &str) -> Option<u32> {
    let index_text = label.strip_prefix(PER_CPU_LABEL_PREFIX)?;
    u32::try_from(parse_all_digits(index_text)?).ok()
}

/// Parses `/proc/stat`: the `cpu` line and each `cpuN` line, whitespace-separated, other lines
/// ignored. A malformed line is no data for that line only; a later `cpu` line replaces an
/// earlier one, malformed or not, and a later `cpuN` line replaces an earlier one only when it
/// parses.
pub fn parse_proc_stat(text: &str) -> ProcStat {
    let mut parsed = ProcStat::default();
    for line in text.split('\n') {
        let fields = split_into_fields(line);
        let Some((label, counter_fields)) = fields.split_first() else {
            continue;
        };
        if *label == AGGREGATE_CPU_LABEL {
            parsed.aggregate = parse_cpu_times(counter_fields);
        } else if let Some(cpu_index) = parse_per_cpu_label(label) {
            if let Some(times) = parse_cpu_times(counter_fields) {
                parsed.per_cpu.insert(cpu_index, times);
            }
        }
    }
    parsed
}

/// The part of `MEMINFO_LINE_PATTERN` after the value, `(?:\s+(kB))?\s*$`: an optional unit (some
/// whitespace, then `kB`) and then only whitespace to the end of the line. `Some(true)` when the
/// tail has the `kB` unit, `Some(false)` when it is empty or only whitespace, and `None` when the
/// pattern cannot match it: anything else, or a `kB` not set apart from the value by whitespace.
fn parse_meminfo_unit_tail(tail: &str) -> Option<bool> {
    match skip_whitespace_run(tail) {
        None => tail.is_empty().then_some(false),
        Some(after_gap) => match after_gap.strip_prefix(MEMINFO_KIB_UNIT) {
            Some(after_unit) => is_blank(after_unit).then_some(true),
            None => after_gap.is_empty().then_some(false),
        },
    }
}

/// `/^([^:\s]+):\s+(\d+)(?:\s+(kB))?\s*$/`: a meminfo line's name and value in bytes (or a bare
/// count when it has no unit). `None` when the line is not of that shape, and when the value
/// does not fit a `u64`.
fn parse_meminfo_line(line: &str) -> Option<(&str, u64)> {
    let after_name = line.trim_start_matches(|c: char| c != ':' && !is_js_whitespace(c));
    let (name, _) = line.split_at_checked(line.len() - after_name.len())?;
    if name.is_empty() {
        return None;
    }
    let after_colon = after_name.strip_prefix(':')?;
    let value_run = take_digit_run(skip_whitespace_run(after_colon)?);
    if value_run.digit_count == 0 {
        return None;
    }
    let has_kib_unit = parse_meminfo_unit_tail(value_run.rest)?;
    let count = value_run.value?;
    let value = if has_kib_unit {
        count.checked_mul(BYTES_PER_KIB)?
    } else {
        count
    };
    Some((name, value))
}

/// Parses `/proc/meminfo`, converting kB values to bytes. A line of another shape, or whose
/// value does not fit a `u64`, is skipped; a later line for a name replaces an earlier one.
pub fn parse_meminfo(text: &str) -> HashMap<String, u64> {
    text.split('\n')
        .filter_map(parse_meminfo_line)
        .map(|(name, value)| (name.to_string(), value))
        .collect()
}

/// Whether `character` is a JavaScript word character (`\w`, which is ASCII only), for `\b`.
fn is_js_word_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '_'
}

/// `(\d+(?:\.\d+)?)` at the start of `characters`: the number it spells, `None` when no digit
/// starts it.
fn parse_pressure_number(characters: &[char]) -> Option<f64> {
    let integer_part: String = characters
        .iter()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    if integer_part.is_empty() {
        return None;
    }
    let after_integer = characters.get(integer_part.len()..)?;
    let fraction_digits: String = after_integer
        .iter()
        .skip(1)
        .take_while(|c| c.is_ascii_digit())
        .collect();
    let has_fraction = after_integer.first() == Some(&'.') && !fraction_digits.is_empty();
    let number_text = if has_fraction {
        format!("{integer_part}.{fraction_digits}")
    } else {
        integer_part
    };
    // Digits and one point always parse; a failure here would be no data, as for any non-number.
    number_text.parse::<f64>().ok()
}

/// `/^some\s.*\bavg10=(\d+(?:\.\d+)?)/` on one line: the value after the LAST `avg10=` that
/// follows the `some` keyword and a whitespace character, with only characters `.` accepts
/// (not a line terminator) between, and a non-word character before it.
fn parse_some_line_avg10(line: &str) -> Option<f64> {
    let after_keyword = line.strip_prefix(PRESSURE_SOME_KEYWORD)?;
    let mut characters = after_keyword.chars();
    let separator = characters.next().filter(|c| is_js_whitespace(*c))?;
    // The separator is kept so that `\b` can look at it before a value at the very start.
    let reachable: Vec<char> = std::iter::once(separator)
        .chain(characters.take_while(|c| !is_js_line_terminator(*c)))
        .collect();
    let key: Vec<char> = PRESSURE_AVG10_KEY.chars().collect();
    (1..reachable.len())
        .filter(|&position| {
            reachable
                .get(position - 1)
                .is_some_and(|before| !is_js_word_character(*before))
        })
        .filter_map(|position| reachable.get(position..)?.strip_prefix(key.as_slice()))
        .filter_map(parse_pressure_number)
        .next_back()
}

/// Parses a `/proc/pressure/*` file's `some` line avg10 (percent); the first line that
/// matches, `None` when none does.
pub fn parse_pressure_some_avg10(text: &str) -> Option<f64> {
    text.split('\n').find_map(parse_some_line_avg10)
}

/// Parses `/sys/block/zramN/mm_stat`: the uncompressed bytes stored (field 1) and the RAM in use
/// (field 3). `None` when any field is not a number or fewer than three are there.
pub fn parse_zram_mm_stat(text: &str) -> Option<ZramMmStat> {
    let fields = parse_non_negative_integers(&split_into_fields(text))?;
    if fields.len() < ZRAM_MM_STAT_MIN_FIELD_COUNT {
        return None;
    }
    Some(ZramMmStat {
        stored_bytes: *fields.get(ZRAM_MM_STAT_STORED_FIELD_INDEX)?,
        ram_bytes: *fields.get(ZRAM_MM_STAT_RAM_FIELD_INDEX)?,
    })
}

/// One `/proc/swaps` row as a swap area; `None` when it does not have one field per header
/// column or its Used column is not a number (or its bytes do not fit a `u64`).
fn parse_swap_row(
    row_line: &str,
    column_count: usize,
    filename_index: usize,
    used_kib_index: usize,
) -> Option<SwapArea> {
    let fields = split_into_fields(row_line);
    if fields.len() != column_count {
        return None;
    }
    let used_kib = parse_all_digits(fields.get(used_kib_index)?)?;
    Some(SwapArea {
        filename: (*fields.get(filename_index)?).to_string(),
        used_bytes: used_kib.checked_mul(BYTES_PER_KIB)?,
    })
}

/// Parses `/proc/swaps`: a header naming the columns, then one row per active swap area, columns
/// separated by runs of whitespace (the kernel escapes whitespace in a file name). An empty list
/// when no area is active; `None` when the header has no `Filename` or no `Used` column, or any
/// row is malformed.
pub fn parse_proc_swaps(text: &str) -> Option<Vec<SwapArea>> {
    let mut lines = text.split('\n');
    let column_names = split_into_fields(lines.next().unwrap_or_default());
    let filename_index = column_names
        .iter()
        .position(|name| *name == PROC_SWAPS_FILENAME_COLUMN)?;
    let used_kib_index = column_names
        .iter()
        .position(|name| *name == PROC_SWAPS_USED_KIB_COLUMN)?;
    lines
        .filter(|row_line| !is_blank(row_line))
        .map(|row_line| {
            parse_swap_row(row_line, column_names.len(), filename_index, used_kib_index)
        })
        .collect()
}

/// `/^Uid:\s+(\d+)/` on one line: the first number after the key; `None` when the line is
/// another one, and when the number does not fit a `u32`.
fn parse_uid_line(line: &str) -> Option<u32> {
    let after_key = line.strip_prefix(UID_LINE_PREFIX)?;
    let value_run = take_digit_run(skip_whitespace_run(after_key)?);
    u32::try_from(value_run.value?)
        .ok()
        .filter(|_| value_run.digit_count > 0)
}

/// Parses the real UID from `/proc/<pid>/status`: the first field of the first `Uid:` line that
/// has one.
pub fn parse_uid(status_text: &str) -> Option<u32> {
    status_text.split('\n').find_map(parse_uid_line)
}
