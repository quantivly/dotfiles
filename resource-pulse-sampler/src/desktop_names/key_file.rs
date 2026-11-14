//! The part of `GKeyFile` (`glib/gkeyfile.c`) that decides whether a `.desktop` file loads and
//! what its `[Desktop Entry]` group holds, on bytes, as GLib reads them.

use std::collections::HashMap;

/// The only group the entry's keys are read from, and the one the first group must be.
const DESKTOP_ENTRY_GROUP: &[u8] = b"Desktop Entry";
const ENCODING_KEY: &[u8] = b"Encoding";
const ENCODING_UTF8: &[u8] = b"UTF-8";
const TRUE_TEXTS: [&str; 2] = ["true", "1"];
/// The longest UTF-8 sequence, in bytes.
const MAX_UTF8_SEQUENCE_BYTES: usize = 4;

/// A value that is not a good string: not UTF-8, or with an escape GLib refuses.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct BadValue;

/// The keys of the `Desktop Entry` group of a file that parsed, each with the raw text after
/// its `=` (leading blanks dropped), up to a NUL.
pub(super) struct DesktopEntry {
    values: HashMap<Vec<u8>, Vec<u8>>,
}

/// `g_ascii_isspace`: space, tab, newline, vertical tab, form feed, carriage return.
fn is_ascii_blank(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r')
}

fn skip_blanks(text: &[u8]) -> &[u8] {
    let blanks = text
        .iter()
        .take_while(|&&byte| is_ascii_blank(byte))
        .count();
    text.get(blanks..).unwrap_or_default()
}

/// What parsing has seen so far.
#[derive(Default)]
struct Parser {
    start_group: Option<Vec<u8>>,
    current_group: Option<Vec<u8>>,
    values: HashMap<Vec<u8>, Vec<u8>>,
}

/// `g_key_file_load_from_data` followed by the start-group check of `load_from_keyfile`:
/// the entry of a file that parses whole and whose first group is `Desktop Entry`, else `None`.
pub(super) fn parse_desktop_entry(bytes: &[u8]) -> Option<DesktopEntry> {
    let mut parser = Parser::default();
    let mut segments = bytes.split(|&byte| byte == b'\n').peekable();
    while let Some(segment) = segments.next() {
        let ends_with_newline = segments.peek().is_some();
        // One carriage return before a newline goes with it; at the end of the data it stays.
        let line = match segment.split_last() {
            Some((b'\r', before)) if ends_with_newline => before,
            _ => segment,
        };
        // GLib handles a line as a C string: everything after a NUL is out of sight.
        let visible = line.split(|&byte| byte == 0).next().unwrap_or_default();
        parser.parse_line(visible)?;
    }
    if parser.start_group.as_deref() != Some(DESKTOP_ENTRY_GROUP) {
        return None;
    }
    Some(DesktopEntry {
        values: parser.values,
    })
}

impl Parser {
    /// `g_key_file_parse_line`: `None` for a line GLib refuses.
    fn parse_line(&mut self, line: &[u8]) -> Option<()> {
        let line = skip_blanks(line);
        if line.is_empty() || line.first() == Some(&b'#') {
            return Some(());
        }
        if let Some(group_name) = group_name_of(line) {
            return self.enter_group(group_name);
        }
        let equals = line.iter().position(|&byte| byte == b'=')?;
        if equals == 0 {
            return None;
        }
        self.add_key_value(line, equals)
    }

    /// `g_key_file_parse_group`: a group that is named validly, new or not, becomes current.
    fn enter_group(&mut self, name: &[u8]) -> Option<()> {
        if name.is_empty()
            || name
                .iter()
                .any(|&byte| matches!(byte, b'[' | b']' | 0..=0x1f | 0x7f))
        {
            return None;
        }
        if self.start_group.is_none() {
            self.start_group = Some(name.to_vec());
        }
        self.current_group = Some(name.to_vec());
        Some(())
    }

    /// `g_key_file_parse_key_value_pair` for a line whose first `=` is at `equals`.
    fn add_key_value(&mut self, line: &[u8], equals: usize) -> Option<()> {
        let current_group = self.current_group.as_ref()?;
        let before_equals = line.get(..equals)?;
        let key_length = before_equals
            .iter()
            .rposition(|&byte| !is_ascii_blank(byte))?
            + 1;
        let key = before_equals.get(..key_length)?;
        if !is_key_name(key) {
            return None;
        }
        let value = skip_blanks(line.get(equals + 1..)?);
        let is_in_start_group = self.start_group.as_ref() == Some(current_group);
        if is_in_start_group && key == ENCODING_KEY && !value.eq_ignore_ascii_case(ENCODING_UTF8) {
            return None;
        }
        if current_group.as_slice() == DESKTOP_ENTRY_GROUP {
            self.values.insert(key.to_vec(), value.to_vec());
        }
        Some(())
    }
}

/// `g_key_file_line_is_group`: the name of a `[group]` line, with only blanks after its `]`.
fn group_name_of(line: &[u8]) -> Option<&[u8]> {
    let after_bracket = line.strip_prefix(b"[")?;
    let closing = after_bracket.iter().position(|&byte| byte == b']')?;
    let trailing = after_bracket.get(closing + 1..)?;
    if trailing.iter().any(|&byte| byte != b' ' && byte != b'\t') {
        return None;
    }
    after_bracket.get(..closing)
}

/// The character at the start of `bytes`, when those bytes begin with a valid UTF-8 one.
fn first_character(bytes: &[u8]) -> Option<char> {
    (1..=MAX_UTF8_SEQUENCE_BYTES.min(bytes.len()))
        .find_map(|length| std::str::from_utf8(bytes.get(..length)?).ok())
        .and_then(|text| text.chars().next())
}

/// `g_key_file_is_key_name`: a non-empty name with no edge blank, and after it at most a
/// `[locale]` of letters, digits and `-_.@` that ends the key.
fn is_key_name(key: &[u8]) -> bool {
    let name_length = key
        .iter()
        .position(|&byte| matches!(byte, b'=' | b'[' | b']' | 0))
        .unwrap_or(key.len());
    if name_length == 0 || key.first() == Some(&b' ') || key.get(name_length - 1) == Some(&b' ') {
        return false;
    }
    let Some(after_name) = key.get(name_length..) else {
        return false;
    };
    let Some(locale_part) = after_name.strip_prefix(b"[") else {
        return after_name.is_empty();
    };
    let mut position = 0;
    while let Some(&byte) = locale_part.get(position) {
        if byte == 0 {
            break;
        }
        let Some(character) = first_character(locale_part.get(position..).unwrap_or_default())
        else {
            break;
        };
        if !(character.is_alphanumeric() || matches!(character, '-' | '_' | '.' | '@')) {
            break;
        }
        position += character.len_utf8();
    }
    locale_part.get(position..) == Some(b"]")
}

impl DesktopEntry {
    /// `g_key_file_get_string`: `Ok(None)` when the key is absent, `Err` for a value that is
    /// not UTF-8 or has a bad escape.
    pub(super) fn string(&self, key: &str) -> Result<Option<String>, BadValue> {
        let Some(raw) = self.values.get(key.as_bytes()) else {
            return Ok(None);
        };
        let text = std::str::from_utf8(raw).map_err(|_| BadValue)?;
        unescape(text).map(Some)
    }

    /// `g_key_file_get_boolean`: true for `true` or `1` (trailing blanks allowed), and false for
    /// anything else, an absent key or a value that is no boolean included.
    pub(super) fn boolean(&self, key: &str) -> bool {
        let Some(raw) = self.values.get(key.as_bytes()) else {
            return false;
        };
        let text = String::from_utf8_lossy(raw);
        let trimmed = text.trim_end_matches(|character: char| {
            character.is_ascii() && is_ascii_blank(character as u8)
        });
        TRUE_TEXTS.contains(&trimmed)
    }
}

/// `parse_value_as_string`: `\s` `\n` `\t` `\r` `\\` are the only escapes.
fn unescape(text: &str) -> Result<String, BadValue> {
    let mut unescaped = String::with_capacity(text.len());
    let mut characters = text.chars();
    while let Some(character) = characters.next() {
        if character != '\\' {
            unescaped.push(character);
            continue;
        }
        match characters.next() {
            Some('s') => unescaped.push(' '),
            Some('n') => unescaped.push('\n'),
            Some('t') => unescaped.push('\t'),
            Some('r') => unescaped.push('\r'),
            Some('\\') => unescaped.push('\\'),
            _ => return Err(BadValue),
        }
    }
    Ok(unescaped)
}
