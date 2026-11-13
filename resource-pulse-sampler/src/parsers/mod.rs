//! Pure parsers for `/proc`, `/sys` and cgroup text, ported from
//! `lib/procParsers.js` and `lib/cgroupParsers.js`. A text that cannot be parsed is `None`
//! (or an empty collection where the gjs parser returns one), never a guess and never a panic.
//!
//! The gjs parsers match with JavaScript regular expressions, and JavaScript and Rust disagree
//! about what a few of their pieces mean; the helpers here are the JavaScript meanings:
//!
//! - `\s` and `String.prototype.trim` use [`is_js_whitespace`], which is not
//!   [`char::is_whitespace`] (see there);
//! - `\d` is `0-9` only, which is [`char::is_ascii_digit`];
//! - `^` and `$` under the `m` flag are bounded by [`is_js_line_terminator`], which is four
//!   characters, not the `\n` and `\r\n` of [`str::lines`].
//!
//! One deliberate difference from the gjs parsers: a field too large for the integer a parser
//! returns reads as no data, exactly as that parser treats a field that is not a number, and so
//! does a sum or a kB-to-bytes product that would overflow. It is never wrapped and never
//! saturated. The gjs parsers return a double there. For a `u32` field (a UID, a CPU index)
//! between 2^32 and 2^53 the gjs holds the number exactly, so that is a difference too; neither can
//! exist on Linux. Above 2^53 the gjs's `memory.stat` sum rounds twice where Rust's rounds once
//! (8 PiB of page cache, unreachable). The kernel's counters are 64-bit, so no text from the
//! kernel can reach any of these.

pub mod cgroup;
pub mod proc;

#[cfg(test)]
mod tests;

/// Bytes in one kibibyte, the unit `/proc/meminfo` and `/proc/swaps` count in.
pub(crate) const BYTES_PER_KIB: u64 = 1024;
/// The radix of every number these files hold.
const DECIMAL_RADIX: u32 = 10;

/// Whether JavaScript's `\s` (and `String.prototype.trim`) treats `character` as whitespace.
///
/// Differs from [`char::is_whitespace`] in two characters: U+0085 (next line) is whitespace to
/// Rust and not to JavaScript, and U+FEFF (byte order mark) is whitespace to JavaScript and not
/// to Rust.
pub(crate) fn is_js_whitespace(character: char) -> bool {
    const BYTE_ORDER_MARK: char = '\u{feff}';
    const NEXT_LINE: char = '\u{85}';
    character == BYTE_ORDER_MARK || (character != NEXT_LINE && character.is_whitespace())
}

/// Whether JavaScript's `.` refuses `character`, and `^` and `$` under the `m` flag treat it as a
/// line boundary: `\n`, `\r`, U+2028 and U+2029, each on its own (so `\r\n` is two).
pub(crate) fn is_js_line_terminator(character: char) -> bool {
    matches!(character, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// Whether `text` is empty or holds only JavaScript whitespace (`/^\s*$/`).
pub(crate) fn is_blank(text: &str) -> bool {
    text.trim_start_matches(is_js_whitespace).is_empty()
}

/// `text.trim().split(/\s+/)`: the fields of a line. An empty or blank line is one empty field,
/// as in JavaScript, never no fields.
pub(crate) fn split_into_fields(text: &str) -> Vec<&str> {
    let mut fields: Vec<&str> = text
        .split(is_js_whitespace)
        .filter(|field| !field.is_empty())
        .collect();
    if fields.is_empty() {
        fields.push("");
    }
    fields
}

/// What `\s+` leaves of `text` when it matches at the start: `None` when `text` does not start
/// with whitespace.
pub(crate) fn skip_whitespace_run(text: &str) -> Option<&str> {
    let rest = text.trim_start_matches(is_js_whitespace);
    (rest.len() < text.len()).then_some(rest)
}

/// A run of ASCII digits at the start of a text, as `\d*` would match it.
pub(crate) struct DigitRun<'text> {
    /// How many digits there were; 0 means `\d+` does not match here.
    pub(crate) digit_count: usize,
    /// The digits' value, or `None` when it does not fit a `u64`.
    pub(crate) value: Option<u64>,
    /// The text after the digits.
    pub(crate) rest: &'text str,
}

/// Takes the longest run of ASCII digits from the start of `text`.
pub(crate) fn take_digit_run(text: &str) -> DigitRun<'_> {
    let rest = text.trim_start_matches(|character: char| character.is_ascii_digit());
    let digits = text.chars().take_while(char::is_ascii_digit);
    let mut digit_count = 0;
    let mut value = Some(0_u64);
    for digit in digits.filter_map(|character| character.to_digit(DECIMAL_RADIX)) {
        digit_count += 1;
        value = value
            .and_then(|so_far| so_far.checked_mul(u64::from(DECIMAL_RADIX)))
            .and_then(|scaled| scaled.checked_add(u64::from(digit)));
    }
    DigitRun {
        digit_count,
        value,
        rest,
    }
}

/// `/^\d+$/` and `parseInt`: the value of a field made only of ASCII digits, `None` for anything
/// else (`1e3`, `0x10`, `+5`, `-1`, an empty field) and for a value too large for a `u64`.
pub(crate) fn parse_all_digits(field: &str) -> Option<u64> {
    let run = take_digit_run(field);
    if run.digit_count == 0 || !run.rest.is_empty() {
        return None;
    }
    run.value
}

/// Whether `text` is a non-empty run of ASCII digits and nothing else (`/^\d+$/`).
pub(crate) fn is_ascii_digit_run(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|character| character.is_ascii_digit())
}
